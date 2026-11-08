// InstCombine calls: port of llvm/lib/Transforms/InstCombine/InstCombineCalls.cpp (visitCallInst and its
// static helpers in file order: foldCttzCtlz, foldCtpop, simplifyNeonTbl, removeTriviallyEmptyRange,
// visitVAEndInst, canonicalizeConstantArg0ToArg1, foldIntrinsicWithOverflowCommon, foldIntrinsicIsFPClass,
// getKnownSign(OrZero), moveAddAfterMinMax, matchSAddSubSat, foldClampRangeOfTwo, reassociateMinMax*,
// factorizeMinMaxTree, foldShuffledIntrinsicOperands, foldReversedIntrinsicOperands, foldBitOrderCrossLogicOp,
// foldIdempotentBinaryIntrinsicRecurrence, simplifyReductionOperand, foldMinimumOverTrailingOrLeadingZeroCount,
// foldIntrinsicUsingDistributiveLaws, foldNeonShift; visitFenceInst, visitInvokeInst, visitCallBrInst).
// The memory-intrinsic and visitCallBase parts are in ic_visit_misc.goose / here (see visit_call_base).
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import pm;
import vt;
import knownbits;
import fpclass;
import implied;
import assume;
import overflow;
import constfold;
import cfold;
import constrange;
import instsimplify;
import speculate;
import instident;
import autoupgrade;
import apint;
import apfloat;
import fpu;
import ic;
import ic_builder;
import ic_common;
import ic_compares;
import ic_andorxor;
import ic_demanded;
import ic_demanded_elts;
import ic_muldivrem;
import ic_casts;
import ic_loadstorealloca;
import memloc;
import aa;
import loads;
import memorybuiltins;
import ic_combining;
import ic_vectorops;
import ic_visit_misc;

// ---------------------------------------------------------------------------------------------
// Builder helpers with an FMFSource (IRBuilder Create*Intrinsic(..., FMFSource), CreateFNegFMF, ...)

// Intrinsic::getOrInsertDeclaration(M, ID, Tys)
fn icx_decl(id: i64, ov: const i32[:]) -> i32 { au_get_declaration(id, ov) }

// CallInst::Create(F, Args): no attributes, metadata or flags
fn icx_new_call(f: i32, argsv: const i32[:]) -> i32 {
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    return iv;
}
// CallInst::Create(II->getCalledFunction(), Args)
fn icx_new_call_same(ii: i32, argsv: const i32[:]) -> i32 { icx_new_call(cb_callee(ii), argsv) }

// IRBuilder::CreateCall(F, Args, Name) (FPMathOperator calls get the builder's flags)
fn icx_call(f: i32, argsv: const i32[:], name: const u8[:]) -> i32 {
    let c = icx_new_call(f, argsv);
    if is_fp_math_operator(c) { insts[inst_of(c)].fmf = icb_fmf; }
    return icb_insert(c, name);
}

// createCallHelper with an FMFSource
fn icx_call_fmf(f: i32, argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let c = icx_new_call(f, argsv);
    if is_fp_math_operator(c) { insts[inst_of(c)].fmf = fmf; }
    return icb_insert(c, name);
}

// CreateUnaryIntrinsic / CreateBinaryIntrinsic with an FMFSource: the declaration is inserted before folding
fn icx_unary_intrinsic_f(id: i64, a: i32, fmf: u8, name: const u8[:]) -> i32 {
    let f = icx_decl(id, [vals[a].ty]);
    let r = tf_intrinsic(id, [a], ty_fn_ret(globs[glob_of(f)].vty));
    if r >= 0 { return r; }
    return icx_call_fmf(f, [a], fmf, name);
}
fn icx_binary_intrinsic_f(id: i64, a: i32, b: i32, fmf: u8, name: const u8[:]) -> i32 {
    let f = icx_decl(id, [vals[a].ty]);
    let r = tf_intrinsic(id, [a, b], ty_fn_ret(globs[glob_of(f)].vty));
    if r >= 0 { return r; }
    return icx_call_fmf(f, [a, b], fmf, name);
}
fn icx_unary_intrinsic(id: i64, a: i32, name: const u8[:]) -> i32 { icx_unary_intrinsic_f(id, a, icb_fmf, name) }
fn icx_binary_intrinsic(id: i64, a: i32, b: i32, name: const u8[:]) -> i32 { icx_binary_intrinsic_f(id, a, b, icb_fmf, name) }

// CreateIntrinsic(ID, OverloadTypes, Args, FMFSource, Name): folds first, declares only when it creates
fn icx_intrinsic_f(id: i64, ov: const i32[:], argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let rty = ty_fn_ret(intr_get_type(id, ov));
    let r = tf_intrinsic(id, argsv, rty);
    if r >= 0 { return r; }
    return icx_call_fmf(icx_decl(id, ov), argsv, fmf, name);
}
// CreateIntrinsic(RetTy, ID, Args, FMFSource, Name): the overload types come from the signature match
fn icx_intrinsic_rt_f(rty: i32, id: i64, argsv: const i32[:], fmf: u8, name: const u8[:]) -> i32 {
    let r = tf_intrinsic(id, argsv, rty);
    if r >= 0 { return r; }
    var ats: i32[>..<] = [];
    for a in argsv { ats.push(vals[a].ty); }
    let f = intr_decl_for_signature(id, rty, ats);
    return icx_call_fmf(f, argsv, fmf, name);
}
fn icx_intrinsic_rt(rty: i32, id: i64, argsv: const i32[:], name: const u8[:]) -> i32 { icx_intrinsic_rt_f(rty, id, argsv, icb_fmf, name) }

// Intrinsic::getOrInsertDeclaration(M, ID, RetTy, ArgTys): find the overload types by matching the signature
fn intr_decl_for_signature(id: i64, rty: i32, ats: const i32[:]) -> i32 {
    let at = ints.len as i32;
    ints.push(rty);
    for t in ats { ints.push(t); }
    let fty = ty_func_run(at, ats.len + 1, false);
    if !intr_signature_valid(id, fty) { fatal("internal: intrinsic signature does not match"); }
    var tys: i32[>..<] = [];
    for t in otys { tys.push(t); }
    return icx_decl(id, tys);
}

// UnaryOperator::CreateFNegFMF(V, FMFSource) (unattached)
fn icx_new_fneg(v: i32, fmf: u8) -> i32 {
    let i = create_inst(OP_FNEG, vals[v].ty, [v]);
    insts[inst_of(i)].fmf = fmf;
    return i;
}
// BinaryOperator::CreateF<op>FMF(A, B, FMFSource) (unattached)
fn icx_new_fbinop(o: i64, a: i32, b: i32, fmf: u8) -> i32 {
    let i = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(i)].fmf = fmf;
    return i;
}
// IRBuilder::CreateFNegFMF(V, FMFSource, Name)
fn icx_fneg(v: i32, fmf: u8, name: const u8[:]) -> i32 {
    if is_constant(v) { let r = cf_fold_unary(OP_FNEG, v); if r >= 0 { return r; } }
    return icb_insert(icx_new_fneg(v, fmf), name);
}
// IRBuilder::CreateF<op>(A, B, FMFSource, Name) (no constrained FP)
fn icx_fbinop(o: i64, a: i32, b: i32, fmf: u8, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_fold_binop_operands(o, a, b);
        if r >= 0 { return r; }
    }
    return icb_insert(icx_new_fbinop(o, a, b, fmf), name);
}
fn icx_fabs(v: i32, fmf: u8) -> i32 { icx_unary_intrinsic_f(IID_fabs, v, fmf, "") }
fn icx_copysign(a: i32, b: i32, fmf: u8) -> i32 { icx_binary_intrinsic_f(IID_copysign, a, b, fmf, "") }
// IRBuilder::CreateLdexp(Src, Exp, FMFSource, Name): CreateIntrinsic(ldexp, {Src->getType(), Exp->getType()}, ...)
fn icx_ldexp(src: i32, e: i32, fmf: u8, name: const u8[:]) -> i32 { icx_intrinsic_f(IID_ldexp, [vals[src].ty, vals[e].ty], [src, e], fmf, name) }
fn icx_fmf(i: i32) -> u8 { insts[inst_of(i)].fmf }

// IRBuilder::CreateSelectWithUnknownProfile(C, T, F, PassName)
fn icx_select_unknown_prof(c: i32, t: i32, f: i32, name: const u8[:]) -> i32 {
    let s = icb_select(c, t, f, name, -1);
    if is_inst(s) && iop(s) == OP_SELECT { ic_set_unknown_branch_weights_if_profiled(s); }
    return s;
}

// IRBuilder::CreateVectorReverse(V)
fn icx_vector_reverse(v: i32, name: const u8[:]) -> i32 {
    let ty = vals[v].ty;
    if ty_kind(ty) == TK_FVEC {
        let n = ty_count(ty);
        var mask: i32[>..<] = [];
        for k in n { mask.push((n - 1 - k) as i32); }
        return icb_shuffle1(v, mask, name);
    }
    return icb_intrinsic(IID_vector_reverse, [ty], [v], name);
}

// Instruction::addRetAttr / CallBase::addRetAttr / removeRetAttr on a call site
fn icx_set_ret_attr(ci: i32, a: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in 0..max(n, 2) {
        var s: i32 = 0;
        if j < n { s = alist_runs[alists[l].at + j]; }
        if j == 1 { s = aset_with(s, a); }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}
fn icx_ret_has_attr(ci: i32, kind: i64) -> bool { call_ret_has_attr(ci, kind) }
// CallBase::getRetAlign(): the call site's, else the callee's
fn icx_ret_align(ci: i32) -> u64 {
    var ex = aset_int(alist_ret(insts[inst_of(ci)].attrs), AK_Alignment);
    if ex == 0 {
        let cf = called_function(ci);
        if cf >= 0 { ex = aset_int(alist_ret(globs[glob_of(cf)].attrs), AK_Alignment); }
    }
    return ex;
}

fn icx_is_pow2_u64(x: u64) -> bool { x != 0 && (x & (x - 1)) == 0 }
fn icx_log2_u64(x: u64) -> i64 { var k: i64 = 0; var y = x; while y > 1 { y = y >> 1; k++; } return k; }

// m_FAbs(m_Value(X)), m_CopySign, m_FPExt, m_VecReverse
fn m_fabs_x(v: i32) -> i32 { if m_intrinsic(v, IID_fabs) { op(v, 0) } else { -1 } }
fn m_fpext_x(v: i32) -> i32 { if is_inst_op(v, OP_FPEXT) { op(v, 0) } else { -1 } }
fn m_vec_reverse_x(v: i32) -> i32 { if m_intrinsic(v, IID_vector_reverse) { op(v, 0) } else { -1 } }
fn m_fneg_x(v: i32) -> i32 { m_fneg(v) }

// ---------------------------------------------------------------------------------------------
// Static helpers, in file order

// foldCttzCtlz(II, IC)
fn fold_cttz_ctlz(ii: i32) -> i32 {
    let is_tz = call_iid(ii) == IID_cttz;
    let op0 = cb_arg(ii, 0);
    let op1 = cb_arg(ii, 1);
    let ty = vals[ii].ty;
    if m_intrinsic(op0, IID_bitreverse) {
        let f = icx_decl(if is_tz { IID_ctlz } else { IID_cttz }, [ty]);
        return icx_new_call(f, [op(op0, 0), op1]);
    }
    if is_int_ty1(ty) {
        if m_zero(op1) { return ic_new_not(op0); }
        return ic_replace_inst_uses_with(ii, c_null(ty));
    }
    if has_one_use(ii) && m_zero(op1) {
        let u = uses[vals[ii].first_use].user;
        if is_inst(u) && is_shift_op(iop(u)) && op(u, 1) == ii {
            return icx_new_call_same(ii, [op0, c_true()]);
        }
    }
    if is_tz {
        let x0 = m_neg(op0);
        if x0 >= 0 { return icx_new_call_same(ii, [x0, op1]); }
        if bo(op0, OP_AND) {
            for k in 2 {
                let x = m_neg(op(op0, k));
                if x >= 0 && op(op0, 1 - k) == x { return icx_new_call_same(ii, [x, op1]); }
            }
        }
        if one_use(op0) && is_inst_op(op0, OP_SEXT) {
            let zx = icb_zext(op(op0, 0), ty, "");
            let r = icx_binary_intrinsic(IID_cttz, zx, op1, "");
            return ic_replace_inst_uses_with(ii, r);
        }
        if one_use(op0) && is_inst_op(op0, OP_ZEXT) && m_one(op1) {
            let c = icx_binary_intrinsic(IID_cttz, op(op0, 0), c_true(), "");
            let zx = icb_zext(c, ty, "");
            return ic_replace_inst_uses_with(ii, zx);
        }
        let spf = match_select_pattern_v(op0, 0);
        if spf == SPF_ABS || spf == SPF_NABS { return icx_new_call_same(ii, [sp_lhs, op1]); }
        if m_intrinsic(op0, IID_abs) { return icx_new_call_same(ii, [op(op0, 0), op1]); }
        if bo(op0, OP_SHL) && is_imm_c(op(op0, 0)) && m_one(op1) {
            let cc = icx_binary_intrinsic(IID_cttz, op(op0, 0), op1, "");
            return ic_new_binop(OP_ADD, cc, op(op0, 1));
        }
        if bo(op0, OP_LSHR) && op_exact(op0) && is_imm_c(op(op0, 0)) && m_one(op1) {
            let cc = icx_binary_intrinsic(IID_cttz, op(op0, 0), op1, "");
            return ic_new_binop(OP_SUB, cc, op(op0, 1));
        }
        if bo(op0, OP_ADD) && bo(op(op0, 0), OP_LSHR) && m_all_ones(op(op(op0, 0), 0)) && m_one(op(op0, 1)) {
            let w = c_int_ty(ty, ty_scalar_bits(ty) as u64);
            return ic_new_binop(OP_SUB, w, op(op(op0, 0), 1));
        }
    } else {
        if bo(op0, OP_LSHR) && is_imm_c(op(op0, 0)) && m_one(op1) {
            let cc = icx_binary_intrinsic(IID_ctlz, op(op0, 0), op1, "");
            return ic_new_binop(OP_ADD, cc, op(op0, 1));
        }
        if bo(op0, OP_SHL) && op_nuw(op0) && is_imm_c(op(op0, 0)) && m_one(op1) {
            let cc = icx_binary_intrinsic(IID_ctlz, op(op0, 0), op1, "");
            return ic_new_binop(OP_SUB, cc, op(op0, 1));
        }
        if has_one_use(op0) {
            let x = icx_match_not_and_dec(op0);
            if x >= 0 {
                let bw = ty_scalar_bits(ty);
                let fz = c_false();
                let cz = icb_intrinsic(IID_cttz, [ty], [x, fz], "");
                let r = icb_sub(c_int_ty(ty, bw as u64), cz, "");
                return ic_replace_inst_uses_with(ii, r);
            }
        }
    }
    let r = try_get_log2(op0, m_one(op1));
    if r >= 0 {
        if is_tz { return ic_replace_inst_uses_with(ii, r); }
        let rt = vals[r].ty;
        let b = ic_new_binop(OP_SUB, c_int_ty(rt, (ty_scalar_bits(rt) - 1) as u64), r);
        set_nsw(b, true);
        set_nuw(b, true);
        return b;
    }
    kb_cxt = ii;
    let known = kb_compute_all(op0, 0);
    let possible = if is_tz { kb_max_tz(known) } else { kb_max_lz(known) };
    let definite = if is_tz { kb_min_tz(known) } else { kb_min_lz(known) };
    if possible == definite { return ic_replace_inst_uses_with(ii, c_int_ty(vals[op0].ty, definite as u64)); }
    var nz = !ap_is_zero(known.o);
    if !nz { kb_cxt = ii; nz = is_known_non_zero(op0, 0); }
    if nz && !m_one(cb_arg(ii, 1)) { return icx_new_call_same(ii, [op0, c_true()]); }
    let bw = ty_scalar_bits(vals[op0].ty);
    if bw != 1 && !icx_ret_has_attr(ii, AK_Range) && inst_get_md(ii, md_kind_id("range")) < 0 {
        let cr = rg_new(ap_u64(definite as u64, bw), ap_u64((possible + 1) as u64, bw));
        icx_set_ret_attr(ii, rg_attr(cr));
        return ii;
    }
    return -1;
}
// m_c_And(m_Not(m_Value(X)), m_Add(m_Deferred(X), m_AllOnes())): X or -1
fn icx_match_not_and_dec(v: i32) -> i32 {
    if !bo(v, OP_AND) { return -1; }
    for k in 2 {
        let x = m_not(op(v, k));
        if x >= 0 {
            let o = op(v, 1 - k);
            if bo(o, OP_ADD) && op(o, 0) == x && m_all_ones(op(o, 1)) { return x; }
        }
    }
    return -1;
}

// foldCtpop(II, IC)
fn fold_ctpop(ii: i32) -> i32 {
    let ty = vals[ii].ty;
    let bw = ty_scalar_bits(ty);
    let op0 = cb_arg(ii, 0);
    if m_intrinsic(op0, IID_bitreverse) || m_intrinsic(op0, IID_bswap) { return icx_new_call_same(ii, [op(op0, 0)]); }
    if (m_intrinsic(op0, IID_fshl) || m_intrinsic(op0, IID_fshr)) && op(op0, 0) == op(op0, 1) {
        return icx_new_call_same(ii, [op(op0, 0)]);
    }
    if has_one_use(op0) && bo(op0, OP_OR) {
        for k in 2 {
            let x = op(op0, k);
            let n = m_neg(op(op0, 1 - k));
            if n >= 0 && n == x {
                let fz = c_false();
                let cz = icb_intrinsic(IID_cttz, [ty], [x, fz], "");
                let r = icb_sub(c_int_ty(ty, bw as u64), cz, "");
                return ic_replace_inst_uses_with(ii, r);
            }
        }
    }
    let x = icx_match_not_and_dec(op0);
    if x >= 0 { return icx_new_call(icx_decl(IID_cttz, [ty]), [x, get_false(T_I1)]); }
    if one_use(op0) && is_inst_op(op0, OP_ZEXT) {
        let np = icx_unary_intrinsic(IID_ctpop, op(op0, 0), "");
        return ic_new_cast(OP_ZEXT, np, ty);
    }
    kb_cxt = ii;
    let known = kb_compute_all(op0, 0);
    let nz = ap_not(known.z);
    if ap_is_pow2(nz) { return ic_new_binop(OP_LSHR, op0, c_int_ty(ty, ap_exact_log2(nz) as u64)); }
    kb_cxt = -1;
    if is_known_pow2(op0, true, 0) {
        return ic_new_cast(OP_ZEXT, icb_icmp(P_NE, op0, c_null(ty), ""), ty);
    }
    if bw != 1 {
        let has_old = call_range(ii);
        let old = if has_old { vt_cr } else { rg_full(bw) };
        var lower = kb_min_pop(known);
        let upper = kb_max_pop(known) + 1;
        if lower == 0 && rg_contains_ap(old, ap_zero(bw)) {
            kb_cxt = ii;
            if is_known_non_zero(op0, 0) { lower = 1; }
        }
        var range = rg_new(ap_u64(lower as u64, bw), ap_u64(upper as u64, bw));
        range = rg_intersect_t(range, old, RG_UNSIGNED);
        if !rg_eq(range, old) {
            icx_set_ret_attr(ii, rg_attr(range));
            return ii;
        }
    }
    return -1;
}

// simplifyNeonTbl(II, IC, IsExtension)
fn simplify_neon_tbl(ii: i32, is_ext: bool) -> i32 {
    let na = cb_nargs(ii);
    let c = cb_arg(ii, na - 1);
    if !is_constant(c) { return -1; }
    let rty = vals[ii].ty;
    let nidx = ty_count(rty);
    if !(ty_is_int(ty_scalar(rty)) && ty_bits(ty_scalar(rty)) == 8) || (nidx != 8 && nidx != 16) { return -1; }
    let start: i64 = if is_ext { 1 } else { 0 };
    let sty = vals[cb_arg(ii, start)].ty;
    let per = ty_count(sty);
    if nidx > per { return -1; }
    let nsrc = na - 1 - start;
    var slots: i32[2] = [-1, -1];
    var nslots: i64 = 0;
    var shops: i32[2] = [c_poison(sty), c_poison(sty)];
    var idx: i32[>..<] = [];
    for k in nidx {
        let e = c_aggregate_element(c, k);
        if e < 0 || (!is_undef_or_poison(e) && vals[e].kind != VK_CINT) { return -1; }
        if is_undef_or_poison(e) { idx.push(-1); continue; }
        let index = ap_zext64(ci_ap(e));
        var si = (index / (per as u64)) as i64;
        var sei = (index % (per as u64)) as i64;
        var so: i32 = -1;
        if si >= nsrc {
            si = nsrc;
            if is_ext { so = cb_arg(ii, 0); sei = k; } else { so = c_null(sty); sei = 0; }
        } else {
            so = cb_arg(ii, si + start);
        }
        if ty_count(vals[so].ty) != per { return -1; }
        var slot: i64 = -1;
        for s in nslots { if slots[s] == so { slot = s; } }
        if slot < 0 {
            if nslots == 2 { return -1; }
            slot = nslots;
            slots[slot] = so;
            shops[slot] = so;
            nslots++;
        }
        idx.push((slot * per + sei) as i32);
    }
    let sh = icb_shuffle(shops[0], shops[1], idx, "");
    return ic_replace_inst_uses_with(ii, sh);
}

// removeTriviallyEmptyRange(EndI, IC, IsStart). kind: 0 = lifetime.start, 1 = va_start/va_copy (visitVAEndInst)
fn remove_trivially_empty_range(endi: i32, kind: i64) -> bool {
    let eid = call_iid(endi);
    var x = inst_prev(endi);
    while x >= 0 {
        let id = inst_iid(x);
        if id != 0 {
            if is_debug_or_pseudo_inst(x) || id == eid { x = inst_prev(x); continue; }
            var is_start = false;
            if kind == 0 { is_start = id == IID_lifetime_start; }
            else { is_start = id == IID_va_start || (id == IID_va_copy && cb_arg(endi, 0) != cb_arg(x, 1)); }
            if is_start {
                var same = true;
                for k in cb_nargs(endi) { if cb_arg(endi, k) != cb_arg(x, k) { same = false; } }
                if same {
                    ic_erase(x);
                    ic_erase(endi);
                    return true;
                }
                x = inst_prev(x);
                continue;
            }
        }
        break;
    }
    return false;
}

// visitVAEndInst(I)
fn visit_va_end(i: i32) -> i32 {
    remove_trivially_empty_range(i, 1);
    return -1;
}

// canonicalizeConstantArg0ToArg1(Call)
fn canonicalize_constant_arg0_to_arg1(ci: i32) -> i32 {
    let a0 = cb_arg(ci, 0);
    let a1 = cb_arg(ci, 1);
    if is_constant(a0) && !is_constant(a1) {
        set_op(ci, 0, a1);
        set_op(ci, 1, a0);
        let l = insts[inst_of(ci)].attrs;
        let lhs = alist_param(l, 0);
        let rhs = alist_param(l, 1);
        let n = if l == 0 { 0 } else { alists[l].n as i64 };
        var sets: i32[>..<] = [];
        for j in 0..max(n, 4) {
            var s: i32 = 0;
            if j < n { s = alist_runs[alists[l].at + j]; }
            if j == 2 { s = rhs; }
            if j == 3 { s = lhs; }
            sets.push(s);
        }
        insts[inst_of(ci)].attrs = alist_get(sets);
        return ci;
    }
    return -1;
}

// createOverflowTuple(II, Result, Overflow)
fn create_overflow_tuple(ii: i32, res: i32, ovf: i32) -> i32 {
    let st = vals[ii].ty;
    let s = c_aggregate(st, [c_poison(vals[res].ty), ovf]);
    return ic_new_insertvalue(s, res, 0);
}
fn ic_new_insertvalue(agg: i32, v: i32, idx: i64) -> i32 {
    let iv = create_inst(OP_INSERTVALUE, vals[agg].ty, [agg, v]);
    let ii = inst_of(iv);
    insts[ii].aux = ints.len as i32;
    insts[ii].naux = 1;
    ints.push(idx as i32);
    return iv;
}

// WithOverflowInst::getBinaryOp / isSigned
fn icx_wo_binop(id: i32) -> i64 {
    if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow { return OP_ADD; }
    if id == IID_usub_with_overflow || id == IID_ssub_with_overflow { return OP_SUB; }
    return OP_MUL;
}
fn icx_wo_signed(id: i32) -> bool { id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow }

// foldIntrinsicWithOverflowCommon(II)
fn fold_intrinsic_with_overflow_common(ii: i32) -> i32 {
    let id = call_iid(ii);
    let o = icx_wo_binop(id);
    let signed = icx_wo_signed(id);
    let ok, res, ovf = optimize_overflow_check(o, signed, cb_arg(ii, 0), cb_arg(ii, 1), ii);
    if ok { return create_overflow_tuple(ii, res, ovf); }
    var u = vals[ii].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if !(is_inst_op(us, OP_EXTRACTVALUE) && insts[inst_of(us)].naux == 1 && ints[insts[inst_of(us)].aux] == 1) { continue; }
        // AC.assumptionsFor(U)
        kb_cxt = ii;
        if !ac_ready() { continue; }
        for k in ac_val.len {
            if ac_val[k] != us { continue; }
            let a = ac_asm[k];
            if is_dead(a) { continue; }
            let nv = m_not(cb_arg(a, 0));
            if nv != us { continue; }
            let save = vt_allow_ephemerals;
            vt_allow_ephemerals = true;
            let save_dt = sq_no_dt;
            sq_no_dt = true;
            let valid = valid_assume_for_context(a, ii);
            sq_no_dt = save_dt;
            vt_allow_ephemerals = save;
            if !valid { continue; }
            let r = icb_binop(o, cb_arg(ii, 0), cb_arg(ii, 1), "");
            ic_take_name(r, ii);
            if is_inst(r) { if signed { set_nsw(r, true); } else { set_nuw(r, true); } }
            return create_overflow_tuple(ii, r, get_false(vals[us].ty));
        }
    }
    return -1;
}

fn input_denormal_is_ieee(fv: i32, ty: i32) -> bool { dm_in(fn_denormal_mode(fv, ty)) == DMK_IEEE }
fn input_denormal_is_daz(fv: i32, ty: i32) -> bool { dm_inputs_are_zero(fn_denormal_mode(fv, ty)) }

// fpclassTestIsFCmp0(Mask, F, Ty): -1 = BAD_FCMP_PREDICATE
fn fpclass_test_is_fcmp0(m: u64, fv: i32, ty: i32) -> i64 {
    let ieee = input_denormal_is_ieee(fv, ty);
    let daz = input_denormal_is_daz(fv, ty);
    if m == FCL_ZERO { return if ieee { P_OEQ } else { -1 }; }
    if m == (FCL_ZERO | FCL_SUBNORMAL) { return if daz { P_OEQ } else { -1 }; }
    if m == (FCL_POSITIVE | FCL_NEG_ZERO) { return if ieee { P_OGE } else { -1 }; }
    if m == (FCL_POSITIVE | FCL_NEG_ZERO | FCL_NEG_SUBNORMAL) { return if daz { P_OGE } else { -1 }; }
    if m == (FCL_POS_SUBNORMAL | FCL_POS_NORMAL | FCL_POS_INF) { return if ieee { P_OGT } else { -1 }; }
    if m == (FCL_NEGATIVE | FCL_POS_ZERO) { return if ieee { P_OLE } else { -1 }; }
    if m == (FCL_NEGATIVE | FCL_POS_ZERO | FCL_POS_SUBNORMAL) { return if daz { P_OLE } else { -1 }; }
    if m == (FCL_NEG_SUBNORMAL | FCL_NEG_NORMAL | FCL_NEG_INF) { return if ieee { P_OLT } else { -1 }; }
    if m == (FCL_POS_NORMAL | FCL_POS_INF) { return if daz { P_OGT } else { -1 }; }
    if m == (FCL_NEG_NORMAL | FCL_NEG_INF) { return if daz { P_OLT } else { -1 }; }
    if m == (FCL_ALL & ~FCL_ZERO & ~FCL_NAN) { return if ieee { P_ONE } else { -1 }; }
    if m == (FCL_ALL & ~(FCL_ZERO | FCL_SUBNORMAL) & ~FCL_NAN) { return if daz { P_ONE } else { -1 }; }
    return -1;
}

// IRBuilder::CreateFCmp + takeName(II) + replaceInstUsesWith(II, ...)
fn icx_replace_with_fcmp(ii: i32, p: i64, a: i32, b: i32) -> i32 {
    let c = icb_fcmp(p, a, b, "");
    ic_take_name(c, ii);
    return ic_replace_inst_uses_with(ii, c);
}

// foldIntrinsicIsFPClass(II)
fn fold_intrinsic_is_fpclass(ii: i32) -> i32 {
    let src0 = cb_arg(ii, 0);
    let src1 = cb_arg(ii, 1);
    let mask = ap_zext64(ci_ap(src1)) & FCL_ALL;
    let is_unordered = (mask & FCL_NAN) == FCL_NAN;
    let is_ordered = (mask & FCL_NAN) == 0;
    let ordered_mask = mask & ~FCL_NAN;
    let ordered_inv = ~ordered_mask & ~FCL_NAN & FCL_ALL;
    let fv = inst_func(ii);
    let is_strict = func_has_fn_attr(fv, AK_StrictFP);
    let s0ty = vals[src0].ty;
    let fn_src = m_fneg(src0);
    if fn_src >= 0 { return icx_new_call_same(ii, [fn_src, c_int_ty(vals[src1].ty, fcl_fneg(mask))]); }
    let fa = m_fabs_x(src0);
    if fa >= 0 { return icx_new_call_same(ii, [fa, c_int_ty(vals[src1].ty, fcl_inverse_fabs(mask))]); }
    if (ordered_mask == FCL_INF || ordered_inv == FCL_INF) && (is_ordered || is_unordered) && !is_strict {
        let inf = cf_fp_inf_ty(s0ty, false);
        var p = if is_unordered { P_UEQ } else { P_OEQ };
        if ordered_inv == FCL_INF { p = if is_unordered { P_UNE } else { P_ONE }; }
        let fabs = icx_fabs(src0, icb_fmf);
        return icx_replace_with_fcmp(ii, p, fabs, inf);
    }
    if (ordered_mask == FCL_POS_INF || ordered_mask == FCL_NEG_INF) && (is_ordered || is_unordered) && !is_strict {
        let inf = cf_fp_inf_ty(s0ty, ordered_mask == FCL_NEG_INF);
        return icx_replace_with_fcmp(ii, if is_unordered { P_UEQ } else { P_OEQ }, src0, inf);
    }
    if (ordered_inv == FCL_POS_INF || ordered_inv == FCL_NEG_INF) && (is_ordered || is_unordered) && !is_strict {
        let inf = cf_fp_inf_ty(s0ty, ordered_inv == FCL_NEG_INF);
        return icx_replace_with_fcmp(ii, if is_unordered { P_UNE } else { P_ONE }, src0, inf);
    }
    if mask == FCL_NAN && !is_strict { return icx_replace_with_fcmp(ii, P_UNO, src0, c_null(s0ty)); }
    if mask == (~FCL_NAN & FCL_ALL) && !is_strict { return icx_replace_with_fcmp(ii, P_ORD, src0, c_null(s0ty)); }
    if !is_strict && (is_ordered || is_unordered) {
        let pt = fpclass_test_is_fcmp0(ordered_mask, fv, s0ty);
        if pt >= 0 {
            return icx_replace_with_fcmp(ii, if is_unordered { pt | 8 } else { pt }, src0, c_null(s0ty));
        }
    }
    kb_cxt = ii;
    let known = known_fp_class(src0, mask, 0, 0);
    if (mask & known.known) != mask {
        set_op(ii, 1, c_int_ty(vals[src1].ty, mask & known.known));
        return ii;
    }
    if mask == known.known { return ic_replace_inst_uses_with(ii, c_int_ty(vals[ii].ty, 1)); }
    return -1;
}
// ConstantFP::getInfinity(Ty, Negative) (splat for vectors)
fn cf_fp_inf_ty(ty: i32, neg: bool) -> i32 {
    let s = cf_fp_inf(ty_scalar(ty), neg);
    if ty_is_vector(ty) { return c_splat(ty, s); }
    return s;
}

// getKnownSign(Op, SQ): -1 = nullopt, 0 = non-negative, 1 = negative
fn get_known_sign(v: i32, cx: i32) -> i64 {
    kb_cxt = cx;
    let k = kb_compute_all(v, 0);
    if kb_is_nonneg(k) { return 0; }
    if kb_is_neg(k) { return 1; }
    if bo(v, OP_SUB) && op_nsw(v) { return implied_by_dom_condition(P_SLT, op(v, 0), op(v, 1), cx); }
    return -1;
}
fn get_known_sign_or_zero(v: i32, cx: i32) -> i64 {
    let s = get_known_sign(v, cx);
    if s >= 0 { return s; }
    if bo(v, OP_SUB) && op_nsw(v) { return implied_by_dom_condition(P_SLE, op(v, 0), op(v, 1), cx); }
    return -1;
}
fn sign_bit_must_be_the_same(a: i32, b: i32, cx: i32) -> bool {
    let k1 = get_known_sign(b, cx);
    if k1 < 0 { return false; }
    let k0 = get_known_sign(a, cx);
    if k0 < 0 { return false; }
    return k0 == k1;
}

// ldexpSaturatingAddIsSafe(FpTy, ExpTy)
fn ldexp_saturating_add_is_safe(fpty: i32, expty: i32) -> bool {
    let kind = fp_kind_ty(fpty);
    if kind == TK_PPC_FP128 { ic_not_ported("ldexpSaturatingAddIsSafe for ppc_fp128"); }
    let ebits = min(ty_scalar_bits(expty), 32);
    let smax = (((1 as u64) << (ebits - 1) as u64) - 1) as i64;
    let smin = -smax - 1;
    let f = fp_fmt(kind);
    // getSmallest: the smallest denormal; getLargest: the largest finite
    let slo, shi = fp_encode(kind, false, 1, 0, 1 - f.bias - (f.p - 1), false);
    let ulo, uhi = fp_scalbn(kind, slo, shi, smax);
    let llo, lhi = fp_largest_bits(kind);
    let dlo, dhi = fp_scalbn(kind, llo, lhi, smin);
    let up = fp_decompose(kind, ulo, uhi);
    let dn = fp_decompose(kind, dlo, dhi);
    return up.cat == FC_INF && dn.cat == FC_ZERO;
}
// APFloat::getLargest(Sem) as bits
fn fp_largest_bits(kind: i64) -> u64, u64 {
    let f = fp_fmt(kind);
    if f.p <= 64 {
        let m: u64 = if f.p == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << f.p as u64) - 1 };
        return fp_encode(kind, false, m, 0, f.bias, false);
    }
    return fp_encode(kind, false, 0xFFFFFFFFFFFFFFFF, ((1 as u64) << (f.p - 64) as u64) - 1, f.bias, false);
}

// moveAddAfterMinMax(II, Builder)
fn move_add_after_min_max(ii: i32) -> i32 {
    let id = call_iid(ii);
    let op0 = cb_arg(ii, 0);
    let op1 = cb_arg(ii, 1);
    if !(one_use(op0) && bo(op0, OP_ADD) && has_apint(op(op0, 1))) || !has_apint(op1) { return -1; }
    let x = op(op0, 0);
    let c0 = ap_c(op(op0, 1));
    let c1 = ap_c(op1);
    let signed = id == IID_smax || id == IID_smin;
    if (signed && !op_nsw(op0)) || (!signed && !op_nuw(op0)) { return -1; }
    let cdiff = ap_sub(c1, c0);
    let nmc = c_int_ap(vals[ii].ty, cdiff);
    let nmm = icx_binary_intrinsic(id, x, nmc, "");
    let r = ic_new_binop(OP_ADD, nmm, op(op0, 1));
    if signed { set_nsw(r, true); } else { set_nuw(r, true); }
    return r;
}

// matchSAddSubSat(MinMax1)
fn match_sadd_sub_sat(mm1: i32) -> i32 {
    let ty = vals[mm1].ty;
    var mm2: i32 = -1;
    var addsub: i32 = -1;
    var minv: i32 = -1;
    var maxv: i32 = -1;
    if m_intrinsic(mm1, IID_smin) && is_inst(op(mm1, 0)) && has_apint(op(mm1, 1)) {
        mm2 = op(mm1, 0);
        maxv = op(mm1, 1);
        if !(m_intrinsic(mm2, IID_smax) && is_binop_inst(op(mm2, 0)) && has_apint(op(mm2, 1))) { return -1; }
        addsub = op(mm2, 0);
        minv = op(mm2, 1);
    } else if m_intrinsic(mm1, IID_smax) && is_inst(op(mm1, 0)) && has_apint(op(mm1, 1)) {
        mm2 = op(mm1, 0);
        minv = op(mm1, 1);
        if !(m_intrinsic(mm2, IID_smin) && is_binop_inst(op(mm2, 0)) && has_apint(op(mm2, 1))) { return -1; }
        addsub = op(mm2, 0);
        maxv = op(mm2, 1);
    } else {
        return -1;
    }
    let mx = ap_c(maxv);
    let mn = ap_c(minv);
    let mx1 = ap_inc(mx);
    if !ap_is_pow2(mx1) || !ap_eq(ap_neg(mn), mx1) { return -1; }
    let nbw = ap_log2(mx1) + 1;
    if !should_change_type_w(ty_scalar_bits(ty), nbw) { return -1; }
    if !has_one_use(mm2) || !has_one_use(addsub) { return -1; }
    let nty = ty_with_new_bits(ty, nbw);
    var iid: i64 = 0;
    if iop(addsub) == OP_ADD { iid = IID_sadd_sat; } else if iop(addsub) == OP_SUB { iid = IID_ssub_sat; } else { return -1; }
    kb_cxt = addsub;
    if compute_max_significant_bits(op(addsub, 0), addsub) > nbw || compute_max_significant_bits(op(addsub, 1), addsub) > nbw { return -1; }
    let at = icb_trunc(op(addsub, 0), nty, "");
    let bt = icb_trunc(op(addsub, 1), nty, "");
    let sat = icb_intrinsic(iid, [nty], [at, bt], "");
    return ic_new_cast(OP_SEXT, sat, ty);
}
// Type::getWithNewBitWidth
fn ty_with_new_bits(ty: i32, w: i64) -> i32 {
    if ty_is_vector(ty) { return ty_vector(ty_int(w), ty_count(ty), ty_kind(ty) == TK_SVEC); }
    return ty_int(w);
}
// ComputeMaxSignificantBits(V, CxtI)
fn compute_max_significant_bits(v: i32, cx: i32) -> i64 {
    kb_cxt = cx;
    let n = num_sign_bits(v, 0);
    return ty_scalar_bits(vals[v].ty) - n + 1;
}

// foldClampRangeOfTwo(II, Builder)
fn fold_clamp_range_of_two(ii: i32) -> i32 {
    let i0 = cb_arg(ii, 0);
    let i1 = cb_arg(ii, 1);
    if !has_apint(i1) || !has_one_use(i0) { return -1; }
    let c1 = ap_c(i1);
    var p: i64 = -1;
    var x: i32 = -1;
    var c0v: i32 = -1;
    let id = call_iid(ii);
    let inner: i32 = if id == IID_smax { IID_smin } else if id == IID_smin { IID_smax } else if id == IID_umax { IID_umin } else { IID_umax };
    if m_intrinsic(i0, inner) && has_apint(op(i0, 1)) {
        x = op(i0, 0);
        c0v = op(i0, 1);
        let c0 = ap_c(c0v);
        if id == IID_smax && ap_eq(c0, ap_inc(c1)) { p = P_SGT; }
        if id == IID_smin && ap_eq(c1, ap_inc(c0)) { p = P_SLT; }
        if id == IID_umax && ap_eq(c0, ap_inc(c1)) { p = P_UGT; }
        if id == IID_umin && ap_eq(c1, ap_inc(c0)) { p = P_ULT; }
    }
    if p < 0 { return -1; }
    let cmp = icb_icmp(p, x, i1, "");
    return ic_new_select(cmp, c_int_ap(vals[ii].ty, ap_c(c0v)), i1);
}

// reassociateMinMaxWithConstants(II, Builder, SQ)
fn reassociate_min_max_with_constants(ii: i32) -> i32 {
    let id = call_iid(ii);
    let lhs = cb_arg(ii, 0);
    let lid = inst_iid(lhs);
    if !is_minmax_iid(lid) { return -1; }
    let c0 = op(lhs, 1);
    let c1 = cb_arg(ii, 1);
    if !is_imm_c(c0) || !is_imm_c(c1) { return -1; }
    if lid != id {
        if !((id == IID_umax && lid == IID_smax) || (id == IID_smin && lid == IID_umin)) { return -1; }
        kb_cxt = ii;
        if !(is_known_non_negative_v(c0, ii) && is_known_non_negative_v(c1, ii)) { return -1; }
    }
    let condc = icb_icmp(minmax_pred(id), c0, c1, "");
    let nc = icb_select(condc, c0, c1, "", -1);
    return icx_intrinsic_rt(vals[ii].ty, lid, [op(lhs, 0), nc], "");
}

// reassociateMinMaxWithConstantInOperand(II, Builder)
fn reassociate_min_max_with_constant_in_operand(ii: i32) -> i32 {
    // m_c_MaxOrMin(m_OneUse(m_CombineAnd(m_Instruction(Inner), m_MaxOrMin(m_Value(X), m_ImmConstant(C)))), m_Value(Y))
    if !m_max_or_min(ii) { return -1; }
    var inner: i32 = -1;
    var x: i32 = -1;
    var c: i32 = -1;
    var y: i32 = -1;
    for k in 2 {
        let a = op(ii, k);
        if one_use(a) && is_inst(a) && m_max_or_min(a) && is_imm_c(op(a, 1)) {
            inner = a; x = op(a, 0); c = op(a, 1); y = op(ii, 1 - k);
            break;
        }
    }
    if inner < 0 { return -1; }
    let id = call_iid(ii);
    if inst_iid(inner) != id || is_imm_c(x) || is_imm_c(y) { return -1; }
    let mm = icx_decl(id, [vals[ii].ty]);
    let ni = icx_binary_intrinsic(id, x, y, "");
    ic_take_name(ni, inner);
    return icx_new_call(mm, [ni, c]);
}

// factorizeMinMaxTree(II)
fn factorize_min_max_tree(ii: i32) -> i32 {
    let lhs = cb_arg(ii, 0);
    let rhs = cb_arg(ii, 1);
    let id = call_iid(ii);
    if inst_iid(lhs) != id || inst_iid(rhs) != id || (!has_one_use(lhs) && !has_one_use(rhs)) { return -1; }
    let a = op(lhs, 0);
    let b = op(lhs, 1);
    let c = op(rhs, 0);
    let d = op(rhs, 1);
    var mmop: i32 = -1;
    var third: i32 = -1;
    if has_one_use(lhs) {
        if d == a || c == a { mmop = rhs; third = b; }
        else if d == b || c == b { mmop = rhs; third = a; }
    } else {
        if d == a || d == b { mmop = lhs; third = c; }
        else if c == a || c == b { mmop = lhs; third = d; }
    }
    if mmop < 0 || third < 0 { return -1; }
    return icx_new_call(icx_decl(id, [vals[ii].ty]), [mmop, third]);
}

// isVectorIntrinsicWithScalarOpAtArg(ID, ScalarOpdIdx, TTI = nullptr) (VectorUtils.cpp)
fn is_vector_intrinsic_with_scalar_op_at_arg(id: i32, k: i64) -> bool {
    if intr_vp_length_param_pos(id) == k { return true; }
    if id == IID_abs || id == IID_ctlz || id == IID_cttz || id == IID_is_fpclass || id == IID_powi || id == IID_vector_extract { return k == 1; }
    if id == IID_smul_fix || id == IID_smul_fix_sat || id == IID_umul_fix || id == IID_umul_fix_sat ||
       id == IID_vector_splice_left || id == IID_vector_splice_right { return k == 2; }
    if id == IID_experimental_vp_splice { return k == 2 || k == 4; }
    if id == IID_experimental_vp_strided_load { return k == 0 || k == 1; }
    if id == IID_loop_dependence_war_mask { return true; }
    return false;
}
// VPIntrinsic::getVectorLengthParamPos: only the intrinsics isTriviallyVectorizable accepts reach here
fn intr_vp_length_param_pos(id: i32) -> i64 {
    let nm = intr_name(id as i64);
    if starts_with(nm, "llvm.vp.") || starts_with(nm, "llvm.experimental.vp.") { ic_not_ported("VPIntrinsic::getVectorLengthParamPos"); }
    return -1;
}

// Function::isSpeculatable
fn fn_is_speculatable(f: i32) -> bool { f >= 0 && func_has_fn_attr(f, AK_Speculatable) }

// foldShuffledIntrinsicOperands(II)
fn fold_shuffled_intrinsic_operands(ii: i32) -> i32 {
    let id = call_iid(ii);
    if !ty_is_vector(vals[ii].ty) || !is_trivially_vectorizable(id) || !fn_is_speculatable(called_function(ii)) { return -1; }
    let na = cb_nargs(ii);
    var nonconst: i64 = -1;
    for k in na {
        let a = cb_arg(ii, k);
        if !(is_constant(a) || is_vector_intrinsic_with_scalar_op_at_arg(id, k)) { nonconst = k; break; }
    }
    if nonconst < 0 { return -1; }
    let sh = cb_arg(ii, nonconst);
    if !(is_inst_op(sh, OP_SHUFFLEVECTOR) && vals[op(sh, 1)].kind == VK_POISON) { return -1; }
    let x0 = op(sh, 0);
    var any_one_use = false;
    for k in na { let a = cb_arg(ii, k); if one_use(a) && is_inst_op(a, OP_SHUFFLEVECTOR) { any_one_use = true; } }
    if !any_one_use { return -1; }
    let srcty = vals[x0].ty;
    var newargs: i32[>..<] = [];
    for k in na {
        let a = cb_arg(ii, k);
        if is_vector_intrinsic_with_scalar_op_at_arg(id, k) { newargs.push(a); }
        else if is_inst_op(a, OP_SHUFFLEVECTOR) && vals[op(a, 1)].kind == VK_POISON && icx_same_mask(a, sh) && vals[op(a, 0)].ty == srcty {
            newargs.push(op(a, 0));
        } else if is_imm_c(a) {
            var mask: i32[>..<] = [];
            for j in sde_mask_len(sh) { mask.push(sde_mask_at(sh, j) as i32); }
            let sc = unshuffle_constant(mask, a, srcty);
            if sc < 0 { return -1; }
            newargs.push(sc);
        } else {
            return -1;
        }
    }
    let fmf: u8 = if is_fp_math_operator(ii) { icx_fmf(ii) } else { icb_fmf };
    let resty = ty_vector(ty_scalar(vals[ii].ty), ty_count(srcty), ty_kind(srcty) == TK_SVEC);
    let ni = icx_intrinsic_rt_f(resty, id, newargs, fmf, "");
    var mask: i32[>..<] = [];
    for j in sde_mask_len(sh) { mask.push(sde_mask_at(sh, j) as i32); }
    return ic_new_shuffle1(ni, mask);
}
fn icx_same_mask(a: i32, b: i32) -> bool {
    let n = sde_mask_len(a);
    if n != sde_mask_len(b) { return false; }
    for j in n { if sde_mask_at(a, j) != sde_mask_at(b, j) { return false; } }
    return true;
}

// foldReversedIntrinsicOperands(II)
fn fold_reversed_intrinsic_operands(ii: i32) -> i32 {
    let id = call_iid(ii);
    if !ty_is_vector(vals[ii].ty) || !is_trivially_vectorizable(id) { return -1; }
    let na = cb_nargs(ii);
    var any = false;
    for k in na { let a = cb_arg(ii, k); if one_use(a) && m_vec_reverse_x(a) >= 0 { any = true; } }
    if !any { return -1; }
    var newargs: i32[>..<] = [];
    for k in na {
        let a = cb_arg(ii, k);
        let x = m_vec_reverse_x(a);
        if is_vector_intrinsic_with_scalar_op_at_arg(id, k) { newargs.push(a); }
        else if x >= 0 { newargs.push(x); }
        else if is_splat_value(a, 0) { newargs.push(a); }
        else if is_imm_c(a) { newargs.push(icx_vector_reverse(a, "")); }
        else { return -1; }
    }
    let fmf: u8 = if is_fp_math_operator(ii) { icx_fmf(ii) } else { icb_fmf };
    let ni = icx_intrinsic_rt_f(vals[ii].ty, id, newargs, fmf, "");
    return icx_vector_reverse(ni, "");
}

// foldBitOrderCrossLogicOp<IntrID>(V, Builder)
fn fold_bit_order_cross_logic_op(v: i32, id: i64) -> i32 {
    if !(one_use(v) && is_inst(v) && (bo(v, OP_AND) || bo(v, OP_OR) || bo(v, OP_XOR))) { return -1; }
    let x = op(v, 0);
    let y = op(v, 1);
    let o = iop(v);
    let xr = m_intrinsic(x, id as i32);
    let yr = m_intrinsic(y, id as i32);
    if xr && yr { return ic_new_binop(o, op(x, 0), op(y, 0)); }
    if xr && one_use(x) {
        let nr = icx_unary_intrinsic(id, y, "");
        return ic_new_binop(o, op(x, 0), nr);
    }
    if yr && one_use(y) {
        let nr = icx_unary_intrinsic(id, x, "");
        return ic_new_binop(o, nr, op(y, 0));
    }
    return -1;
}

fn is_idempotent_binary_intrinsic(id: i32) -> bool {
    return id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin || id == IID_maximum || id == IID_minimum ||
        id == IID_maximumnum || id == IID_minimumnum || id == IID_maxnum || id == IID_minnum;
}

// foldIdempotentBinaryIntrinsicRecurrence(IC, II)
fn fold_idempotent_binary_intrinsic_recurrence(ii: i32) -> i32 {
    let id = call_iid(ii);
    if !is_idempotent_binary_intrinsic(id) { return -1; }
    // matchSimpleBinaryIntrinsicRecurrence
    if cb_nargs(ii) != 2 || vals[ii].ty != vals[cb_arg(ii, 0)].ty || vals[ii].ty != vals[cb_arg(ii, 1)].ty { return -1; }
    var pn = cb_arg(ii, 0);
    if !is_phi_inst(pn) { pn = cb_arg(ii, 1); }
    if !is_phi_inst(pn) { return -1; }
    if nops(pn) != 2 { return -1; }
    var init: i32 = -1;
    var other: i32 = -1;
    var found: i32 = -1;
    for k in 2 {
        let opn = phi_value(pn, k);
        if inst_iid(opn) != 0 && cb_nargs(opn) + 1 >= 2 {
            let l = op(opn, 0);
            let r = op(opn, 1);
            if l != pn && r != pn { continue; }
            found = opn;
            init = phi_value(pn, 1 - k);
            other = if l == pn { r } else { l };
            break;
        }
    }
    if found != ii { return -1; }
    if !dt_value_dominates_inst(other, pn) { return -1; }
    let r = icx_binary_intrinsic(id, init, other, "");
    if is_inst(r) && is_fp_math_operator(r) { insts[inst_of(r)].fmf = icx_fmf(ii); }
    return r;
}

// simplifyReductionOperand(Arg, CanReorderLanes)
fn simplify_reduction_operand(arg: i32, can_reorder: bool) -> i32 {
    if !can_reorder { return -1; }
    let v = m_vec_reverse_x(arg);
    if v >= 0 { return v; }
    if ty_kind(vals[arg].ty) != TK_FVEC || !is_inst_op(arg, OP_SHUFFLEVECTOR) || !m_undef(op(arg, 1)) || !icx_shuffle_is_single_source(arg) { return -1; }
    let sz = sde_mask_len(arg);
    var used: bool[>..<] = [];
    for k in sz { used.push(false); }
    for k in sz {
        let ix = sde_mask_at(arg, k);
        if ix < 0 || ix >= sz || used[ix] { return -1; }
        used[ix] = true;
    }
    for k in sz { if !used[k] { return -1; } }
    return op(arg, 0);
}

// foldMinimumOverTrailingOrLeadingZeroCount<IntrID>(I0, I1, DL, Builder)
fn fold_minimum_over_tz_lz_count(i0: i32, i1: i32, id: i64) -> i32 {
    if !(one_use(i0) && m_intrinsic(i0, id as i32)) { return -1; }
    let ct1 = op(i0, 0);
    let zu1 = op(i0, 1);
    if one_use(i1) && m_intrinsic(i1, id as i32) {
        return icx_binary_intrinsic(id, icb_or(ct1, op(i1, 0), ""), icb_or(zu1, op(i1, 1), ""), "");
    }
    let bw = ty_scalar_bits(vals[i1].ty);
    // m_CheckedInt(C.ult(BitWidth)): a ConstantInt or a vector whose every element is (no poison)
    if !icx_checked_int_ult(i1, bw) { return -1; }
    let ty = vals[i1].ty;
    let base = if id == IID_cttz { c_int_ty(ty, 1) } else { c_int_ap(ty, ap_smin_val(bw)) };
    let nc = cf_fold_binop_operands(if id == IID_cttz { OP_SHL } else { OP_LSHR }, base, i1);
    return icx_binary_intrinsic(id, icb_or(ct1, nc, ""), get_true(vals[zu1].ty), "");
}
// m_CheckedInt(pred) with pred = C.ult(bw): ConstantInt, or a fixed vector constant whose elements all are
fn icx_checked_int_ult(v: i32, bw: i64) -> bool {
    if vals[v].kind == VK_CINT { return ap_ult_u64(ci_ap(v), bw as u64); }
    if !is_constant(v) || ty_kind(vals[v].ty) != TK_FVEC { return false; }
    let s = splat_value(v, false);
    if s >= 0 { return vals[s].kind == VK_CINT && ap_ult_u64(ci_ap(s), bw as u64); }
    for k in ty_count(vals[v].ty) {
        let e = c_aggregate_element(v, k);
        if e < 0 || vals[e].kind != VK_CINT || !ap_ult_u64(ci_ap(e), bw as u64) { return false; }
    }
    return true;
}

fn left_distributes_over_right_ii(lop: i64, nuw: bool, nsw: bool, rop: i32) -> bool {
    if rop == IID_umax || rop == IID_umin { return (nuw && lop == OP_ADD) || (nuw && lop == OP_SHL); }
    if rop == IID_smax || rop == IID_smin { return nsw && lop == OP_ADD; }
    return false;
}
fn right_distributes_over_left_ii(lop: i64, nuw: bool, nsw: bool, rop: i32) -> bool {
    if ii_opcode_is_commutative(lop) || lop == OP_SHL { return left_distributes_over_right_ii(lop, nuw, nsw, rop); }
    if rop == IID_umax || rop == IID_umin { return nuw && lop == OP_SUB; }
    if rop == IID_smax || rop == IID_smin { return nsw && lop == OP_SUB; }
    return false;
}

// foldIntrinsicUsingDistributiveLaws(II, Builder)
fn fold_intrinsic_using_distributive_laws(ii: i32) -> i32 {
    let lhs = op(ii, 0);
    let rhs = op(ii, 1);
    let top = call_iid(ii);
    // OverflowingBinaryOperator: add/sub/mul/shl instructions or constant expressions
    if !is_overflowing_operator(lhs) || !is_overflowing_operator(rhs) { return -1; }
    if opcode_of(lhs) != opcode_of(rhs) { return -1; }
    if !has_one_use(lhs) || !has_one_use(rhs) { return -1; }
    let inner = opcode_of(lhs);
    let nuw = op_nuw(lhs) && op_nuw(rhs);
    let nsw = op_nsw(lhs) && op_nsw(rhs);
    let a = op(lhs, 0);
    let b = op(lhs, 1);
    var c = op(rhs, 0);
    var d = op(rhs, 1);
    if ii_opcode_is_commutative(inner) && a != c && b != d {
        if a == d || b == c { let t = c; c = d; d = t; } else { return -1; }
    }
    var nb: i32 = -1;
    if a == c && left_distributes_over_right_ii(inner, nuw, nsw, top) {
        let ni = icx_binary_intrinsic(top, b, d, "");
        nb = icb_binop(inner, a, ni, "");
    } else if b == d && right_distributes_over_left_ii(inner, nuw, nsw, top) {
        let ni = icx_binary_intrinsic(top, a, c, "");
        nb = icb_binop(inner, ni, b, "");
    } else {
        return -1;
    }
    // cast<BinaryOperator>: the folder may not fold (both operands can't be constants here)
    set_nuw(nb, nuw);
    set_nsw(nb, nsw);
    return nb;
}
fn is_overflowing_operator(v: i32) -> bool {
    let o = opcode_of(v);
    if !(o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL) { return false; }
    return is_inst(v) || vals[v].kind == VK_CEXPR;
}

// foldNeonShift(II, IC)
fn fold_neon_shift(ii: i32) -> i32 {
    let a0 = cb_arg(ii, 0);
    let sc = cb_arg(ii, 1);
    if !is_constant(sc) { return -1; }
    let eb = ty_scalar_bits(vals[a0].ty);
    var all_pos = true;
    var all_neg = true;
    let fixed = ty_kind(vals[a0].ty) == TK_FVEC;
    let n = if fixed { ty_count(vals[a0].ty) } else { 1 };
    for k in n {
        let e = if fixed { c_aggregate_element(sc, k) } else { sc };
        if e < 0 || vals[e].kind != VK_CINT { return -1; }
        let v = ci_ap(e);
        if ap_is_nonneg(v) {
            all_neg = false;
            if !(all_pos && ap_ult_u64(v, eb as u64)) { return -1; }
        } else {
            all_pos = false;
            if !(all_neg && ap_sgt(v, ap_i64(-eb, v.w as i64))) { return -1; }
        }
    }
    if all_pos { return ic_replace_inst_uses_with(ii, icb_shl(a0, sc, "")); }
    let neg = icb_neg(sc, "", false);
    let id = call_iid(ii);
    let signed = id == IID_arm_neon_vshifts || id == IID_aarch64_neon_sshl;
    let r = if signed { icb_ashr(a0, neg, "", false) } else { icb_lshr(a0, neg, "", false) };
    return ic_replace_inst_uses_with(ii, r);
}

// ShuffleVectorInst::isSingleSource: every mask element picks from one operand
fn icx_shuffle_is_single_source(s: i32) -> bool {
    let n = ty_count(vals[op(s, 0)].ty);
    if sde_mask_len(s) != n { return false; }
    var uses0 = false;
    var uses1 = false;
    for k in n {
        let m = sde_mask_at(s, k);
        if m < 0 { continue; }
        if m < n { uses0 = true; } else { uses1 = true; }
    }
    return !(uses0 && uses1) && (uses0 || uses1);
}

// ---------------------------------------------------------------------------------------------
// visitCallInst for intrinsics (after the generic prologue in visit_call)

fn is_any_mem_intrinsic_id(id: i32) -> bool {
    return id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove || id == IID_memset || id == IID_memset_inline ||
        id == IID_memcpy_element_unordered_atomic || id == IID_memmove_element_unordered_atomic ||
        id == IID_memset_element_unordered_atomic;
}
fn is_any_mem_transfer_id(id: i32) -> bool {
    return id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove || id == IID_memcpy_element_unordered_atomic ||
        id == IID_memmove_element_unordered_atomic;
}
fn is_any_mem_set_id(id: i32) -> bool { id == IID_memset || id == IID_memset_inline || id == IID_memset_element_unordered_atomic }
fn mi_is_atomic(id: i32) -> bool {
    id == IID_memcpy_element_unordered_atomic || id == IID_memmove_element_unordered_atomic || id == IID_memset_element_unordered_atomic
}
// AnyMemIntrinsic::isVolatile: only the non-atomic ones carry an isvolatile operand
fn mi_is_volatile(mi: i32) -> bool {
    if mi_is_atomic(call_iid(mi)) { return false; }
    let v = cb_arg(mi, 3);
    return vals[v].kind == VK_CINT && !ap_is_zero(ci_ap(v));
}

// IsPointerUndefined lambda of visitCallInst
fn mi_pointer_undefined(mi: i32, p: i32) -> bool {
    return vals[p].kind == VK_CNULL && !null_pointer_is_defined(inst_func(mi), ptr_as(vals[p].ty));
}

fn visit_intrinsic(ci: i32) -> i32 {
    let ii = ci;
    let iid = call_iid(ii);
    if is_any_mem_intrinsic_id(iid) {
        let len = cb_arg(ii, 2);
        if vals[len].kind == VK_CINT {
            let nb = ci_ap(len);
            if ap_is_zero(nb) { return ic_erase(ci); }
            if mi_is_atomic(iid) {
                let esz = ap_zext64(ci_ap(cb_arg(ii, 3)));
                if ap_is_neg(nb) || (ap_zext64(nb) % esz != 0) {
                    ic_create_non_terminator_unreachable(ii);
                    return ic_erase(ii);
                }
            }
        }
        if mi_is_volatile(ii) { return -1; }
        if is_any_mem_transfer_id(iid) {
            if strip_ptr_casts(cb_arg(ii, 1)) == strip_ptr_casts(cb_arg(ii, 0)) { return ic_erase(ci); }
        }
        var src_undef = false;
        if is_any_mem_transfer_id(iid) {
            let r = simplify_any_mem_transfer(ii);
            if r >= 0 { return r; }
            src_undef = mi_pointer_undefined(ii, cb_arg(ii, 1));
        } else if is_any_mem_set_id(iid) {
            let r = simplify_any_mem_set(ii);
            if r >= 0 { return r; }
        }
        if src_undef || mi_pointer_undefined(ii, cb_arg(ii, 0)) {
            icb_assumption(icb_is_null(cb_arg(ii, 2), ""));
            return ic_erase(ci);
        }
        if iid == IID_memmove || iid == IID_memmove_element_unordered_atomic {
            let src = strip_ptr_casts(cb_arg(ii, 1));
            if vals[src].kind == VK_GVAR && globs[glob_of(src)].is_const != 0 {
                let mid = if mi_is_atomic(iid) { IID_memcpy_element_unordered_atomic } else { IID_memcpy };
                let f = icx_decl(mid, [vals[cb_arg(ii, 0)].ty, vals[cb_arg(ii, 1)].ty, vals[cb_arg(ii, 2)].ty]);
                icx_set_called_function(ci, f);
                return ii;
            }
        }
    }
    let rty = vals[ii].ty;
    if ty_kind(rty) == TK_FVEC {
        let vw = ty_count(rty);
        let v, pe = ic_simplify_demanded_vector_elts(ii, ap_ones(vw), 0, false);
        if v >= 0 {
            if v != ii { return ic_replace_inst_uses_with(ii, v); }
            return ii;
        }
    }
    if ii_intrinsic_is_commutative(iid) {
        if match_symmetric_pair(op(ii, 0), op(ii, 1)) {
            let a = sp_a;
            let b = sp_b;
            ic_replace_operand(ii, 0, a);
            ic_replace_operand(ii, 1, b);
            drop_poison_generating_annotations(ii);
            drop_ub_implying_attrs_and_md(ii);
            return ii;
        }
        let nc = canonicalize_constant_arg0_to_arg1(ci);
        if nc >= 0 { return nc; }
    }
    if use_empty(ci) && intr_is_constrained_fp(iid) {
        let mark = is_ops.len;
        let n = nops(ci);
        for k in n { is_ops.push(op(ci, k)); }
        let r = simplify_constrained_fp_call(ci, mark, n - 1 - cb_bundle_ops(ci), sq_at(ci));
        is_ops.resize(mark);
        if r >= 0 { return ic_erase(ci); }
    }
    let r = visit_intrinsic_switch(ii, iid);
    if r != -2 { return r; }
    // Try to fold intrinsic into select/phi operands
    if spec_safe(ci, -1, false) {
        for k in cb_nargs(ii) {
            let a = cb_arg(ii, k);
            if is_select_inst(a) {
                let vec_cond = ty_is_vector(vals[op(a, 0)].ty);
                if vec_cond && (!is_not_cross_lane(ii) || !ty_is_vector(rty)) { continue; }
                let both = !ty_is_vector(vals[a].ty) && ty_is_vector(rty);
                let x = fold_op_into_select(ii, a, false, both);
                if x >= 0 { return x; }
            }
            if is_phi_inst(a) {
                let x = fold_op_into_phi(ii, a, false);
                if x >= 0 { return x; }
            }
        }
    }
    let sh = fold_shuffled_intrinsic_operands(ii);
    if sh >= 0 { return sh; }
    let rv = fold_reversed_intrinsic_operands(ii);
    if rv >= 0 { return ic_replace_inst_uses_with(ii, rv); }
    let rr = fold_idempotent_binary_intrinsic_recurrence(ii);
    if rr >= 0 { return ic_replace_inst_uses_with(ii, rr); }
    return visit_call_base(ii);
}

// CallBase::setCalledFunction(F)
fn icx_set_called_function(ci: i32, f: i32) {
    set_op(ci, nops(ci) - 1, f);
    insts[inst_of(ci)].ty2 = globs[glob_of(f)].vty;
}

fn intr_is_constrained_fp(id: i32) -> bool { starts_with(intr_name(id as i64), "llvm.experimental.constrained.") }

// The switch of visitCallInst. Returns -2 for `break` (continue with the folds after the switch).
fn visit_intrinsic_switch(ii: i32, iid: i32) -> i32 {
    let ci = ii;
    let rty = vals[ii].ty;
    if iid == IID_objectsize {
        ic_not_ported("lowerObjectSizeCall in visitCallInst");
        return -1;
    }
    if iid == IID_abs {
        let iop0 = cb_arg(ii, 0);
        let int_min_poison = is_one_value(cb_arg(ii, 1));
        let x = m_neg(iop0);
        if x >= 0 { return icx_new_call_same(ii, [x, c_bool_ty(T_I1, int_min_poison || op_nsw(iop0))]); }
        if is_select_inst(iop0) {
            for k in 2 {
                let n = m_neg(op(iop0, 1 + k));
                if n >= 0 && op(iop0, 2 - k) == n { return icx_new_call_same(ii, [n, cb_arg(ii, 1)]); }
            }
        }
        if one_use(iop0) && bo(iop0, OP_MUL) {
            for k in 2 {
                let a = op(iop0, 1 - k);
                if m_intrinsic(a, IID_abs) {
                    let xx = op(iop0, k);
                    let y = op(a, 0);
                    let nsw = op_nsw(iop0) && int_min_poison;
                    let xy = icb_mul_nw(xx, y, "", false, nsw);
                    return icx_new_call_same(ii, [xy, cb_arg(ii, 1)]);
                }
            }
        }
        let known = get_known_sign_or_zero(iop0, ii);
        if known >= 0 {
            if known == 0 { return ic_replace_inst_uses_with(ii, iop0); }
            let ng = ic_new_neg(iop0);
            if int_min_poison { set_nsw(ng, true); }
            return ng;
        }
        if one_use(iop0) && is_inst_op(iop0, OP_SEXT) {
            let na = icx_binary_intrinsic(IID_abs, op(iop0, 0), c_false(), "");
            return ic_new_cast(OP_ZEXT, na, rty);
        }
        if bo(iop0, OP_SREM) && has_apint(op(iop0, 1)) && ap_eq_u64(ap_c(op(iop0, 1)), 2) {
            return ic_new_binop(OP_AND, op(iop0, 0), c_int_ty(rty, 1));
        }
        return -2;
    }
    if iid == IID_umin || iid == IID_umax || iid == IID_smax || iid == IID_smin {
        return visit_min_max(ii, iid);
    }
    if iid == IID_scmp {
        let i0 = cb_arg(ii, 0);
        let i1 = cb_arg(ii, 1);
        if bo(i0, OP_SUB) && op_nsw(i0) && m_zero(i1) {
            return ic_replace_inst_uses_with(ci, icx_intrinsic_rt(rty, IID_scmp, [op(i0, 0), op(i0, 1)], ""));
        }
        return -2;
    }
    if iid == IID_bitreverse {
        let a = cb_arg(ii, 0);
        let x = m_zext(a);
        if x >= 0 && is_int_ty1(vals[x].ty) {
            let sb = ap_sign_mask(ty_scalar_bits(rty));
            return ic_new_select(x, c_int_ap(rty, sb), c_null(rty));
        }
        let r = fold_bit_order_cross_logic_op(a, IID_bitreverse);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_bswap {
        let a = cb_arg(ii, 0);
        if one_use(a) && (bo(a, OP_SHL) || bo(a, OP_LSHR)) {
            let x = op(a, 0);
            let y = op(a, 1);
            let bw = ty_scalar_bits(vals[a].ty);
            kb_cxt = ii;
            if masked_value_is_zero(y, ap_low_bits(bw, 3), 0) {
                let ns = icx_unary_intrinsic(IID_bswap, x, "");
                let inv = if iop(a) == OP_SHL { OP_LSHR } else { OP_SHL };
                return ic_new_binop(inv, ns, y);
            }
        }
        kb_cxt = ii;
        let known = kb_compute_all(a, 0);
        let lz = kb_min_lz(known) / 8 * 8;
        let tz = kb_min_tz(known) / 8 * 8;
        let bw = kb_bw(known);
        if bw - lz - tz == 8 {
            if lz > tz {
                let s = ic_new_binop(OP_SHL, a, c_int_ty(vals[a].ty, (lz - tz) as u64));
                set_nuw(s, true);
                return s;
            }
            let s = ic_new_binop(OP_LSHR, a, c_int_ty(vals[a].ty, (tz - lz) as u64));
            set_exact(s, true);
            return s;
        }
        let tx = m_trunc(a);
        if tx >= 0 && m_intrinsic(tx, IID_bswap) {
            let x = op(tx, 0);
            let c = ty_scalar_bits(vals[x].ty) - bw;
            let v = icb_lshr(x, c_int_ty(vals[x].ty, c as u64), "", false);
            return ic_new_cast(OP_TRUNC, v, vals[a].ty);
        }
        let r = fold_bit_order_cross_logic_op(a, IID_bswap);
        if r >= 0 { return r; }
        let b = match_bswap_or_bitreverse(ii, false, true);
        if b >= 0 { return b; }
        return -2;
    }
    if iid == IID_masked_load {
        let v = simplify_masked_load(ii);
        if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
        return -2;
    }
    if iid == IID_masked_store { return simplify_masked_store(ii); }
    if iid == IID_masked_gather { return simplify_masked_gather(ii); }
    if iid == IID_masked_scatter { return simplify_masked_scatter(ii); }
    if iid == IID_launder_invariant_group || iid == IID_strip_invariant_group {
        let sb = simplify_invariant_group_intrinsic(ii);
        if sb >= 0 { return ic_replace_inst_uses_with(ii, sb); }
        return -2;
    }
    if iid == IID_powi {
        let pw = cb_arg(ii, 1);
        let a0 = cb_arg(ii, 0);
        if vals[pw].kind == VK_CINT {
            let p = ci_ap(pw);
            if ap_is_all_ones(p) { return icx_new_fbinop(OP_FDIV, c_fp_from_f64(rty, 1.0), a0, icx_fmf(ii)); }
            if ap_eq_u64(p, 2) { return icx_new_fbinop(OP_FMUL, a0, a0, icx_fmf(ii)); }
            if !ap_get_bit(p, 0) {
                var x = m_fneg(a0);
                if x < 0 { x = m_fabs_x(a0); }
                if x < 0 && m_intrinsic(a0, IID_copysign) { x = op(a0, 0); }
                if x >= 0 { return icx_new_call_same(ii, [x, pw]); }
            }
        }
        if vals[a0].kind == VK_CFP {
            var e = cb_arg(ii, 1);
            let ty = vals[a0].ty;
            if (icx_fmf(ii) & FMF_AFN) != 0 && fp_is_exactly(a0, 2.0) {
                let one = c_fp_from_f64(ty, 1.0);
                if ty_is_vector(ty) { e = icb_vector_splat(ty_with_elem(ty, vals[e].ty), e, ""); }
                let ld = icx_ldexp(one, e, icx_fmf(ii), "");
                return ic_replace_inst_uses_with(ii, ld);
            }
        }
        return -2;
    }
    if iid == IID_cttz || iid == IID_ctlz {
        let r = fold_cttz_ctlz(ii);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_ctpop {
        let r = fold_ctpop(ii);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_fshl || iid == IID_fshr { return visit_funnel_shift(ii, iid); }
    if iid == IID_pdep || iid == IID_pext {
        let m = cb_arg(ii, 1);
        if has_apint(m) {
            let mc = ap_c(m);
            if ap_is_shifted_mask(mc) {
                let midx = ap_countr_zero(mc);
                let inp = cb_arg(ii, 0);
                let sa = c_int_ty(rty, midx as u64);
                if iid == IID_pdep {
                    let sh = icb_shl(inp, sa, "");
                    return ic_replace_inst_uses_with(ii, icb_and(sh, m, ""));
                }
                let mk = icb_and(inp, m, "");
                return ic_replace_inst_uses_with(ii, icb_lshr(mk, sa, "", false));
            }
        }
        return -2;
    }
    if iid == IID_ptrmask {
        let ch, known = simplify_demanded_instruction_bits_k(ii);
        if ch { return ii; }
        var changed = false;
        let a0 = cb_arg(ii, 0);
        if one_use(a0) && m_intrinsic(a0, IID_ptrmask) {
            let nm = icb_and(cb_arg(ii, 1), op(a0, 1), "");
            let ip = op(a0, 0);
            ic_replace_operand(ci, 0, ip);
            ic_replace_operand(ci, 1, nm);
            changed = true;
        }
        if !call_ret_has_attr(ci, AK_NonNull) {
            var nz = kb_is_nonzero(known);
            if !nz { kb_cxt = ii; nz = is_known_non_zero(ii, 0); }
            if nz { icx_set_ret_attr(ci, attr_enum(AK_NonNull)); changed = true; }
        }
        let bw = kb_bw(known);
        let nal = min(32, min(bw - 1, kb_min_tz(known)));
        var ra = icx_ret_align(ci);
        if ra == 0 { ra = 1; }
        if nal > icx_log2_u64(ra) {
            icx_set_ret_attr(ci, attr_int(AK_Alignment, (1 as u64) << nal as u64));
            changed = true;
        }
        if changed { return ci; }
        return -2;
    }
    if iid == IID_uadd_with_overflow || iid == IID_sadd_with_overflow {
        let r = fold_intrinsic_with_overflow_common(ii);
        if r >= 0 { return r; }
        let a0 = cb_arg(ii, 0);
        let a1 = cb_arg(ii, 1);
        let signed = iid == IID_sadd_with_overflow;
        let hasnw = if signed { m_nsw_add_like(a0) } else { m_nuw_add_like(a0) };
        if hasnw && has_apint(op(a0, 1)) && has_apint(a1) {
            let x = op(a0, 0);
            let c0 = ap_c(op(a0, 1));
            let c1 = ap_c(a1);
            let snc, sovf = ap_sadd_ov(c1, c0);
            let unc, uovf = ap_uadd_ov(c1, c0);
            let nc = if signed { snc } else { unc };
            let ovf = if signed { sovf } else { uovf };
            if !ovf {
                return ic_replace_inst_uses_with(ii, icx_binary_intrinsic(iid, x, c_int_ap(vals[a1].ty, nc), ""));
            }
        }
        return -2;
    }
    if iid == IID_umul_with_overflow || iid == IID_smul_with_overflow || iid == IID_usub_with_overflow {
        let r = fold_intrinsic_with_overflow_common(ii);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_ssub_with_overflow {
        let r = fold_intrinsic_with_overflow_common(ii);
        if r >= 0 { return r; }
        let a0 = cb_arg(ii, 0);
        let a1 = cb_arg(ii, 1);
        if is_constant(a1) && is_not_min_signed_value(a1) {
            let nv = ce_neg(a1);
            return ic_replace_inst_uses_with(ii, icx_binary_intrinsic(IID_sadd_with_overflow, a0, nv, ""));
        }
        return -2;
    }
    if iid == IID_uadd_sat || iid == IID_sadd_sat || iid == IID_usub_sat || iid == IID_ssub_sat { return visit_sat(ii, iid); }
    if iid == IID_minnum || iid == IID_maxnum || iid == IID_minimumnum || iid == IID_maximumnum || iid == IID_minimum || iid == IID_maximum {
        return visit_fp_min_max(ii, iid);
    }
    if iid == IID_matrix_multiply { return visit_matrix_multiply(ii, iid); }
    if iid == IID_fmuladd {
        let fmf = icx_fmf(ii);
        let v = simplify_fmul_inst(cb_arg(ii, 0), cb_arg(ii, 1), fmf, ii);
        if v >= 0 { return icx_new_fbinop(OP_FADD, v, cb_arg(ii, 2), fmf); }
        return visit_fma(ii, iid);
    }
    if iid == IID_fma { return visit_fma(ii, iid); }
    if iid == IID_copysign { return visit_copysign(ii); }
    if iid == IID_fabs {
        let a = cb_arg(ii, 0);
        let x = m_fneg(a);
        if x >= 0 { return ic_replace_inst_uses_with(ci, icx_fabs(x, icx_fmf(ii))); }
        if is_select_inst(a) {
            let cond = op(a, 0);
            let tv = op(a, 1);
            let fv = op(a, 2);
            let ok = if has_one_use(a) { is_constant(tv) || is_constant(fv) } else { is_constant(tv) && is_constant(fv) };
            if ok {
                let f = called_function(ii);
                let at = icx_call(f, [tv], "");
                let af = icx_call(f, [fv], "");
                let si = ic_new_select(cond, at, af);
                insts[inst_of(si)].fmf = (icx_fmf(ii) | icx_fmf(a)) & ~FMF_NSZ;
                return si;
            }
            if m_fneg(tv) == fv { return ic_replace_inst_uses_with(ii, icx_fabs(fv, icx_fmf(ii))); }
            if m_fneg(fv) == tv { return ic_replace_inst_uses_with(ii, icx_fabs(tv, icx_fmf(ii))); }
        }
        if m_intrinsic(cb_arg(ii, 0), IID_copysign) {
            return ic_replace_inst_uses_with(ii, icx_fabs(op(cb_arg(ii, 0), 0), icx_fmf(ii)));
        }
        return visit_rounding(ii, iid);
    }
    if iid == IID_ceil || iid == IID_floor || iid == IID_round || iid == IID_roundeven || iid == IID_nearbyint || iid == IID_rint || iid == IID_trunc {
        return visit_rounding(ii, iid);
    }
    if iid == IID_cos || iid == IID_amdgcn_cos || iid == IID_cosh {
        let src = cb_arg(ii, 0);
        var x = m_fneg(src);
        if x < 0 { x = m_fabs_x(src); }
        if x < 0 && m_intrinsic(src, IID_copysign) { x = op(src, 0); }
        if x >= 0 { return ic_replace_inst_uses_with(ii, icx_unary_intrinsic_f(iid, x, icx_fmf(ii), "")); }
        return -2;
    }
    if iid == IID_sin || iid == IID_amdgcn_sin || iid == IID_sinh || iid == IID_tan || iid == IID_tanh {
        let a = cb_arg(ii, 0);
        if one_use(a) {
            let x = m_fneg(a);
            if x >= 0 {
                let nf = icx_unary_intrinsic_f(iid, x, icx_fmf(ii), "");
                return icx_new_fneg(nf, icx_fmf(ii));
            }
        }
        return -2;
    }
    if iid == IID_ldexp { return visit_ldexp(ii); }
    if iid == IID_ptrauth_auth || iid == IID_ptrauth_resign {
        ic_not_ported("ptrauth auth/resign folding");
        return -1;
    }
    if iid == IID_arm_neon_vtbl1 || iid == IID_arm_neon_vtbl2 || iid == IID_arm_neon_vtbl3 || iid == IID_arm_neon_vtbl4 ||
       iid == IID_aarch64_neon_tbl1 || iid == IID_aarch64_neon_tbl2 || iid == IID_aarch64_neon_tbl3 || iid == IID_aarch64_neon_tbl4 {
        return simplify_neon_tbl(ii, false);
    }
    if iid == IID_arm_neon_vtbx1 || iid == IID_arm_neon_vtbx2 || iid == IID_arm_neon_vtbx3 || iid == IID_arm_neon_vtbx4 ||
       iid == IID_aarch64_neon_tbx1 || iid == IID_aarch64_neon_tbx2 || iid == IID_aarch64_neon_tbx3 || iid == IID_aarch64_neon_tbx4 {
        return simplify_neon_tbl(ii, true);
    }
    if iid == IID_arm_neon_vmulls || iid == IID_arm_neon_vmullu || iid == IID_aarch64_neon_smull || iid == IID_aarch64_neon_umull {
        var a0 = cb_arg(ii, 0);
        var a1 = cb_arg(ii, 1);
        if vals[a0].kind == VK_AGGZERO || vals[a1].kind == VK_AGGZERO { return ic_replace_inst_uses_with(ci, c_null(rty)); }
        let zx = iid == IID_arm_neon_vmullu || iid == IID_aarch64_neon_umull;
        if is_constant(a0) {
            if is_constant(a1) {
                let v0 = icb_int_cast(a0, rty, !zx, "");
                let v1 = icb_int_cast(a1, rty, !zx, "");
                return ic_replace_inst_uses_with(ci, icb_mul(v0, v1, ""));
            }
            let t = a0; a0 = a1; a1 = t;
        }
        if is_constant(a1) {
            let sp = splat_value(a1, false);
            let spv = if sp >= 0 { sp } else if !ty_is_vector(vals[a1].ty) { a1 } else { -1 };
            if spv >= 0 && vals[spv].kind == VK_CINT && ap_is_one(ci_ap(spv)) { return ic_new_int_cast(a0, rty, !zx); }
        }
        return -2;
    }
    if iid == IID_arm_neon_aesd || iid == IID_arm_neon_aese || iid == IID_aarch64_crypto_aesd || iid == IID_aarch64_crypto_aese ||
       iid == IID_aarch64_sve_aesd || iid == IID_aarch64_sve_aese {
        var data = cb_arg(ii, 0);
        var key = cb_arg(ii, 1);
        if !m_zero_int(key) { let t = key; key = data; data = t; }
        if m_zero_int(key) && bo(data, OP_XOR) {
            ic_replace_operand(ii, 0, op(data, 0));
            ic_replace_operand(ii, 1, op(data, 1));
            return ii;
        }
        return -2;
    }
    if iid == IID_arm_neon_vshifts || iid == IID_arm_neon_vshiftu || iid == IID_aarch64_neon_sshl || iid == IID_aarch64_neon_ushl {
        return fold_neon_shift(ii);
    }
    if iid == IID_hexagon_V6_vandvrt || iid == IID_hexagon_V6_vandvrt_128B {
        ic_not_ported("Hexagon vandvrt folding");
        return -1;
    }
    if iid == IID_stackrestore { return visit_stackrestore(ii); }
    if iid == IID_lifetime_end {
        let fv = inst_func(ii);
        if func_has_fn_attr(fv, AK_SanitizeAddress) || func_has_fn_attr(fv, AK_SanitizeMemory) ||
           func_has_fn_attr(fv, AK_SanitizeHWAddress) || func_has_fn_attr(fv, AK_SanitizeMemTag) { return -2; }
        if remove_trivially_empty_range(ii, 0) { return -1; }
        return -2;
    }
    if iid == IID_assume { return visit_assume_case(ii); }
    if iid == IID_experimental_guard { return visit_guard(ii); }
    if iid == IID_vector_insert { return visit_vector_insert(ii); }
    if iid == IID_vector_extract { return visit_vector_extract(ii); }
    if iid == IID_experimental_vp_reverse {
        let vec = cb_arg(ii, 0);
        let mask = cb_arg(ii, 1);
        if !m_all_ones(mask) { return -2; }
        let evl = cb_arg(ii, 2);
        if one_use(vec) && is_inst_op(vec, OP_FNEG) {
            let inner = op(vec, 0);
            if inst_iid(inner) == IID_experimental_vp_reverse && m_all_ones(op(inner, 1)) && op(inner, 2) == evl {
                let nu = create_inst(OP_FNEG, vals[vec].ty, [op(inner, 0)]);
                insts[inst_of(nu)].fmf = icx_fmf(vec);
                var nm: u8[>..] = [];
                nm.append(val_name(vec));
                set_name(nu, nm);
                ic_insert_before_pos(nu, ii);
                return ic_replace_inst_uses_with(ci, nu);
            }
        }
        return -2;
    }
    if iid == IID_vector_reduce_or || iid == IID_vector_reduce_and || iid == IID_vector_reduce_add || iid == IID_vector_reduce_xor ||
       iid == IID_vector_reduce_mul || iid == IID_vector_reduce_umin || iid == IID_vector_reduce_umax ||
       iid == IID_vector_reduce_smin || iid == IID_vector_reduce_smax || iid == IID_vector_reduce_fmax ||
       iid == IID_vector_reduce_fmin || iid == IID_vector_reduce_fadd || iid == IID_vector_reduce_fmul {
        return visit_reduction(ii, iid);
    }
    if iid == IID_is_fpclass {
        let r = fold_intrinsic_is_fpclass(ii);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_threadlocal_address {
        let minal = get_known_alignment(cb_arg(ii, 0), ii);
        var al = icx_ret_align(ii);
        if al == 0 { al = 1; }
        if (minal as u64) > al {
            icx_set_ret_attr(ii, attr_int(AK_Alignment, minal as u64));
            return ii;
        }
        return -2;
    }
    if iid == IID_fptoui_sat || iid == IID_fptosi_sat {
        let r = fold_ito_fpto_i(ii);
        if r >= 0 { return r; }
        return -2;
    }
    if iid == IID_frexp {
        let a = cb_arg(ii, 0);
        if is_inst_op(a, OP_EXTRACTVALUE) && insts[inst_of(a)].naux == 1 && ints[insts[inst_of(a)].aux] == 0 &&
           m_intrinsic(op(a, 0), IID_frexp) {
            var res = icb_insert_value(c_poison(rty), a, [0], "");
            res = icb_insert_value(res, c_null(ty_field(rty, 1)), [1], "");
            return ic_replace_inst_uses_with(ii, res);
        }
        return -2;
    }
    if iid == IID_get_active_lane_mask {
        let o0 = op(ii, 0);
        let o1 = op(ii, 1);
        if m_cint_pred(o0, IP_STRICTLYPOS, false) && has_apint(o1) {
            let opty = vals[o0].ty;
            let c = ap_usub_sat(ap_c(o1), ap_c(o0));
            return ic_replace_inst_uses_with(ii, icx_intrinsic_rt(rty, IID_get_active_lane_mask, [c_null(opty), c_int_ap(opty, c)], ""));
        }
        return -2;
    }
    if iid == IID_experimental_get_vector_length {
        let a0 = cb_arg(ii, 0);
        let bw = max(ty_scalar_bits(vals[a0].ty), ty_scalar_bits(rty));
        kb_cxt = ii;
        let cnt = rg_zext_or_trunc(compute_constant_range_including_known_bits(a0, false, ii), bw);
        var ml = rg_single(ap_zext_or_trunc(ci_ap(cb_arg(ii, 1)), rg_w(cnt)));
        if ap_is_one(ci_ap(cb_arg(ii, 2))) { ml = rg_multiply(ml, vt_vscale_range(inst_func(ii), rg_w(cnt)), 0); }
        if rg_icmp(P_ULE, cnt, ml) { return ic_replace_inst_uses_with(ii, icb_zext_or_trunc(a0, rty, "")); }
        return -1;
    }
    // default: target specific intrinsics
    let tv, handled = target_inst_combine_intrinsic(ii);
    if handled { return tv; }
    return -2;
}

// case Intrinsic::umin / umax / smax / smin (with the fallthroughs)
fn visit_min_max(ii: i32, iid: i32) -> i32 {
    let ci = ii;
    let rty = vals[ii].ty;
    var i0 = cb_arg(ii, 0);
    var i1 = cb_arg(ii, 1);
    if iid == IID_umin {
        if m_one(i1) {
            let cmp = icb_icmp(P_NE, i0, c_null(vals[i0].ty), "");
            return ic_new_cast(OP_ZEXT, cmp, rty);
        }
        let fc = fold_minimum_over_tz_lz_count(i0, i1, IID_cttz);
        if fc >= 0 { return ic_replace_inst_uses_with(ii, fc); }
        let fl = fold_minimum_over_tz_lz_count(i0, i1, IID_ctlz);
        if fl >= 0 { return ic_replace_inst_uses_with(ii, fl); }
    }
    if iid == IID_umin || iid == IID_umax {
        let x = m_zext(i0);
        let y = m_zext(i1);
        if x >= 0 && y >= 0 && (has_one_use(i0) || has_one_use(i1)) && vals[x].ty == vals[y].ty {
            let n = icx_binary_intrinsic(iid, x, y, "");
            return ic_new_cast(OP_ZEXT, n, rty);
        }
        if x >= 0 && is_constant(i1) && has_one_use(i0) {
            let nc = get_lossless_inv_cast(i1, vals[x].ty, OP_ZEXT);
            if nc >= 0 {
                let n = icx_binary_intrinsic(iid, x, nc, "");
                return ic_new_cast(OP_ZEXT, n, rty);
            }
        }
        if iid == IID_umax {
            let r = fold_max_mul_shift(ii, i0, i1);
            if r >= 0 { return r; }
            let r2 = fold_max_mul_shift(ii, i1, i0);
            if r2 >= 0 { return r2; }
        }
    }
    let sx = m_sext(i0);
    let sy = m_sext(i1);
    if sx >= 0 && sy >= 0 && (has_one_use(i0) || has_one_use(i1)) && vals[sx].ty == vals[sy].ty {
        let n = icx_binary_intrinsic(iid, sx, sy, "");
        return ic_new_cast(OP_SEXT, n, rty);
    }
    if sx >= 0 && is_constant(i1) && has_one_use(i0) {
        let nc = get_lossless_inv_cast(i1, vals[sx].ty, OP_SEXT);
        if nc >= 0 {
            let n = icx_binary_intrinsic(iid, sx, nc, "");
            return ic_new_cast(OP_SEXT, n, rty);
        }
    }
    // smax(smin(X, MinC), MaxC) -> smin(smax(X, MaxC), MinC) if MinC s>= MaxC (and the unsigned form)
    if (iid == IID_smax || iid == IID_umax) && one_use(i0) {
        let inner: i32 = if iid == IID_smax { IID_smin } else { IID_umin };
        if m_intrinsic(i0, inner) && has_apint(op(i0, 1)) && has_apint(i1) {
            let minc = ap_c(op(i0, 1));
            let maxc = ap_c(i1);
            let ok = if iid == IID_smax { ap_sgt(minc, maxc) } else { ap_ugt(minc, maxc) };
            if ok {
                let x = op(i0, 0);
                let xt = vals[x].ty;
                let nmax = icx_binary_intrinsic(iid, x, c_int_ap(xt, maxc), "");
                return ic_replace_inst_uses_with(ii, icx_binary_intrinsic(inner, nmax, c_int_ap(xt, minc), ""));
            }
        }
    }
    if (iid == IID_umin || iid == IID_smax) && is_int_ty1(rty) { return ic_new_binop(OP_AND, i0, i1); }
    if (iid == IID_umax || iid == IID_smin) && is_int_ty1(rty) { return ic_new_binop(OP_OR, i0, i1); }
    if iid == IID_smin {
        if one_use(i0) && m_intrinsic(i0, IID_smax) && m_all_ones(op(i0, 1)) && m_one(i1) {
            let x = op(i0, 0);
            return ic_replace_inst_uses_with(ci, icx_intrinsic_rt(rty, IID_scmp, [x, c_null(vals[x].ty)], ""));
        }
    }
    if iid == IID_smax || iid == IID_smin {
        let nx = icx_m_nsw_neg(i0);
        let ny = icx_m_nsw_neg(i1);
        if nx >= 0 && ny >= 0 && (has_one_use(i0) || has_one_use(i1)) {
            let inv = minmax_inverse_iid(iid);
            let im = icx_binary_intrinsic(inv, nx, ny, "");
            let ng = ic_new_neg(im);
            set_nsw(ng, true);
            return ng;
        }
    }
    // (umax X, (xor X, Pow2)) and friends
    var px: i32 = -1;
    if bo(i0, OP_XOR) {
        if op(i0, 0) == i1 { px = op(i0, 1); } else if op(i0, 1) == i1 { px = op(i0, 0); }
    }
    if px < 0 && bo(i1, OP_XOR) {
        if op(i1, 0) == i0 { px = op(i1, 1); } else if op(i1, 1) == i0 { px = op(i1, 0); }
    }
    if px >= 0 {
        kb_cxt = -1;
        if is_known_pow2(px, true, 0) {
            var use_or = iid == IID_smax || iid == IID_umax;
            var use_andn = iid == IID_smin || iid == IID_umin;
            var x = px;
            if iid == IID_smax || iid == IID_smin {
                let ks = get_known_sign(x, ii);
                if ks < 0 { use_or = false; use_andn = false; }
                else if ks == 1 {
                    use_or = !use_or;
                    use_andn = !use_andn;
                    let ty = vals[i0].ty;
                    x = c_int_value(ty, ap_smin_val(ty_scalar_bits(ty)));
                }
            }
            if use_or { return ic_new_binop(OP_OR, i0, x); }
            if use_andn { return ic_new_binop(OP_AND, i0, icb_not(x, "")); }
        }
    }
    let r1 = move_not_after_min_max(iid, i0, i1);
    if r1 >= 0 { return r1; }
    let r2 = move_not_after_min_max(iid, i1, i0);
    if r2 >= 0 { return r2; }
    let ma = move_add_after_min_max(ii);
    if ma >= 0 { return ma; }
    // minmax (X & NegPow2C, Y & NegPow2C) --> minmax(X, Y) & NegPow2C
    if one_use(i0) && bo(i0, OP_AND) && m_cint_pred(op(i0, 1), IP_NEG_POWER2, true) && one_use(i1) && bo(i1, OP_AND) {
        let rhsc = ap_cp(op(i0, 1));
        if m_specific_int_apv(op(i1, 1), rhsc) {
            let mm = icx_binary_intrinsic(iid, op(i0, 0), op(i1, 0), "");
            return ic_new_binop(OP_AND, mm, c_int_ap(rty, rhsc));
        }
    }
    if is_known_negation(i0, i1, false, false) {
        if has_one_use(i0) && !has_one_use(i1) { let t = i0; i0 = i1; i1 = t; }
        let imp = is_known_negation(i0, i1, true, false);
        var abs = icx_binary_intrinsic(IID_abs, i0, c_bool_ty(T_I1, imp), "");
        if iid == IID_smin || iid == IID_umax { abs = icb_neg(abs, "nabs", imp); }
        return ic_replace_inst_uses_with(ci, abs);
    }
    let sel = fold_clamp_range_of_two(ii);
    if sel >= 0 { return sel; }
    let sa = match_sadd_sub_sat(ii);
    if sa >= 0 { return sa; }
    let nm = reassociate_min_max_with_constants(ii);
    if nm >= 0 { return ic_replace_inst_uses_with(ii, nm); }
    let rr = reassociate_min_max_with_constant_in_operand(ii);
    if rr >= 0 { return rr; }
    let ft = factorize_min_max_tree(ii);
    if ft >= 0 { return ft; }
    if has_apint_poison(i1) {
        let rhsc = ap_cp(i1);
        let p = icmp_non_strict_pred(minmax_pred(iid));
        let signed = iid == IID_smax || iid == IID_smin;
        let lcr = compute_constant_range_including_known_bits(i0, signed, ii);
        if !rg_is_full(lcr) {
            if rg_icmp(p, lcr, rg_single(rhsc)) { return ic_replace_inst_uses_with(ii, i0); }
            if rg_icmp(icmp_swapped_pred(p), lcr, rg_single(rhsc)) { return ic_replace_inst_uses_with(ii, c_int_ap(rty, rhsc)); }
        }
    }
    let dv = fold_intrinsic_using_distributive_laws(ii);
    if dv >= 0 { return ic_replace_inst_uses_with(ii, dv); }
    return -2;
}
// m_NSWNeg(m_Value(X))
fn icx_m_nsw_neg(v: i32) -> i32 { if bo(v, OP_SUB) && op_nsw(v) && m_zero_int(op(v, 0)) { op(v, 1) } else { -1 } }
// ICmpInst::getNonStrictPredicate
fn icmp_non_strict_pred(p: i64) -> i64 { match p { 34 => 35, 36 => 37, 38 => 39, 40 => 41, _ => p } }

// foldMaxMulShift lambda of the umax case
fn fold_max_mul_shift(ii: i32, a: i32, b: i32) -> i32 {
    var x: i32 = -1;
    var c: AP = ap_zero(1);
    if bo(a, OP_SHL) && op_nuw(a) && has_apint(op(a, 1)) { x = op(a, 0); c = ap_c(op(a, 1)); }
    else if bo(a, OP_MUL) && op_nuw(a) && has_apint(op(a, 1)) && !ap_is_one(ap_c(op(a, 1))) { x = op(a, 0); c = ap_c(op(a, 1)); }
    else { return -1; }
    if ap_is_zero(c) { return -1; }
    if !(one_use(b) && bo(b, OP_ADD) && op(b, 0) == x && m_one(op(b, 1))) { return -1; }
    let cmp = icb_icmp(P_EQ, x, c_int_ty(vals[x].ty, 0), "");
    let ns = icx_select_unknown_prof(cmp, c_int_ty(vals[x].ty, 1), a, "");
    return ic_replace_inst_uses_with(ii, ns);
}

// moveNotAfterMinMax lambda
fn move_not_after_min_max(iid: i32, x: i32, y: i32) -> i32 {
    if one_use(x) {
        let a = m_not(x);
        if a >= 0 && !is_free_to_invert(a, has_one_use(a)) {
            let noty = get_freely_inverted(y, has_one_use(y), true);
            if noty >= 0 {
                let inv = minmax_inverse_iid(iid);
                let im = icx_binary_intrinsic(inv, a, noty, "");
                return ic_new_not(im);
            }
        }
    }
    return -1;
}

// computeConstantRangeIncludingKnownBits(V, ForSigned, SQ)
fn compute_constant_range_including_known_bits(v: i32, signed: bool, cx: i32) -> CRange {
    kb_cxt = cx;
    let k = kb_compute_all(v, 0);
    let cr1 = rg_from_kb(k, signed);
    kb_cxt = cx;
    let cr2 = compute_constant_range(v, signed, true, 0);
    return rg_intersect_t(cr1, cr2, if signed { RG_SIGNED } else { RG_UNSIGNED });
}

// case Intrinsic::fshl / fshr
fn visit_funnel_shift(ii: i32, iid: i32) -> i32 {
    let ci = ii;
    let op0 = cb_arg(ii, 0);
    let op1 = cb_arg(ii, 1);
    let ty = vals[ii].ty;
    let bw = ty_scalar_bits(ty);
    let shc = cb_arg(ii, 2);
    if is_imm_c(shc) {
        let widthc = c_int_ty(ty, bw as u64);
        let moduloc = cf_fold_binop_operands(OP_UREM, shc, widthc);
        if moduloc < 0 { return -1; }
        if moduloc != shc { return icx_new_call_same(ii, [op0, op1, moduloc]); }
        if iid == IID_fshr {
            kb_cxt = ii;
            if !is_known_non_zero(shc, 0) { return -1; }
            let lsc = ce_binop(OP_SUB, widthc, shc, 0);
            let fshl = icx_decl(IID_fshl, [ty]);
            return icx_new_call(fshl, [op0, op1, lsc]);
        }
        if m_zero_int(op1) || m_undef(op1) { return ic_new_binop(OP_SHL, op0, shc); }
        if m_zero_int(op0) || m_undef(op0) { return ic_new_binop(OP_LSHR, op1, ce_binop(OP_SUB, widthc, shc, 0)); }
        if op0 == op1 && bw == 16 && m_specific_int(shc, 8) {
            return icx_new_call(icx_decl(IID_bswap, [ty]), [op0]);
        }
        let b = match_bswap_or_bitreverse(ii, true, true);
        if b >= 0 { return b; }
        if m_intrinsic(op0, IID_fshl) && op(op0, 0) == op(op0, 1) && has_apint(op(op0, 2)) && has_apint(shc) && op0 == op1 {
            let inner = op(op0, 0);
            let sum = ap_add(ap_c(shc), ap_c(op(op0, 2)));
            let md = ap_urem(sum, ap_u64(bw as u64, sum.w as i64));
            if ap_is_zero(md) { return ic_replace_inst_uses_with(ii, inner); }
            return icx_new_call(cb_callee(op0), [inner, inner, c_int_ap(ty, md)]);
        }
    }
    let ispow2 = icx_is_pow2_u64(bw as u64);
    if op0 == op1 && ispow2 {
        let y = m_neg(cb_arg(ii, 2));
        if y >= 0 {
            let opp = icx_decl(if iid == IID_fshl { IID_fshr } else { IID_fshl }, [ty]);
            return icx_new_call(opp, [op0, op1, y]);
        }
    }
    if iid == IID_fshl && ispow2 && m_zero_int(op1) {
        let a = icb_and(cb_arg(ii, 2), c_int_ty(ty, (bw - 1) as u64), "");
        return ic_new_binop(OP_SHL, op0, a);
    }
    if simplify_demanded_instruction_bits(ii) { return ci; }
    if !ispow2 { return -2; }
    let d = ap_low_bits(bw, icx_log2_ceil(bw as u64));
    icb_set_insert_point(ii);
    let saved = sd_cxt;
    sd_cxt = ii;
    let ch, k = sd_bits(ii, 2, d, 0);
    sd_cxt = saved;
    if ch { return ci; }
    return -2;
}
fn icx_log2_ceil(x: u64) -> i64 { if x <= 1 { 0 } else { icx_log2_u64(x - 1) + 1 } }

// case Intrinsic::uadd_sat / sadd_sat / usub_sat / ssub_sat
fn visit_sat(ii: i32, iid: i32) -> i32 {
    let ty = vals[ii].ty;
    let a0 = cb_arg(ii, 0);
    let a1 = cb_arg(ii, 1);
    let signed = iid == IID_sadd_sat || iid == IID_ssub_sat;
    let bop = if iid == IID_uadd_sat || iid == IID_sadd_sat { OP_ADD } else { OP_SUB };
    let ovr = compute_overflow(bop, signed, a0, a1, ii);
    if ovr == OF_NEVER {
        let b = ic_new_binop(bop, a0, a1);
        if signed { set_nsw(b, true); } else { set_nuw(b, true); }
        return b;
    }
    if ovr == OF_LOW {
        let bw = ty_scalar_bits(ty);
        return ic_replace_inst_uses_with(ii, c_int_ap(ty, if signed { ap_smin_val(bw) } else { ap_zero(bw) }));
    }
    if ovr == OF_HIGH {
        let bw = ty_scalar_bits(ty);
        return ic_replace_inst_uses_with(ii, c_int_ap(ty, if signed { ap_smax_val(bw) } else { ap_ones(bw) }));
    }
    if iid == IID_usub_sat && bo(a0, OP_SUB) && op_nuw(a0) && is_imm_c(op(a0, 0)) && is_imm_c(a1) {
        let nc = icx_binary_intrinsic(IID_usub_sat, op(a0, 0), a1, "");
        let ns = icx_binary_intrinsic(IID_usub_sat, nc, op(a0, 1), "");
        return ic_replace_inst_uses_with(ii, ns);
    }
    if iid == IID_ssub_sat && is_constant(a1) && is_not_min_signed_value(a1) {
        let nv = ce_neg(a1);
        return ic_replace_inst_uses_with(ii, icx_binary_intrinsic(IID_sadd_sat, a0, nv, ""));
    }
    if inst_iid(a0) == iid {
        let other = a0;
        let unsigned = iid == IID_uadd_sat || iid == IID_usub_sat;
        if has_apint(a1) && has_apint(op(other, 1)) {
            let x = op(other, 0);
            let v = ap_c(a1);
            let v2 = ap_c(op(other, 1));
            var nv = ap_zero(v.w as i64);
            if unsigned { nv = ap_uadd_sat(v, v2); }
            else if ap_is_nonneg(v) == ap_is_nonneg(v2) {
                let s, ov = ap_sadd_ov(v, v2);
                if ov { return -2; }
                nv = s;
            } else {
                return -2;
            }
            return ic_replace_inst_uses_with(ii, icx_binary_intrinsic(iid, x, c_int_ap(ty, nv), ""));
        }
    }
    return -2;
}

// FMFSource::intersect(A, B)
fn fmf_intersect(a: i32, b: i32) -> u8 { icx_fmf(a) & icx_fmf(b) }

// case Intrinsic::minnum / maxnum / minimumnum / maximumnum / minimum / maximum
fn visit_fp_min_max(ii: i32, iid: i32) -> i32 {
    let a0 = cb_arg(ii, 0);
    let a1 = cb_arg(ii, 1);
    let x0 = m_fneg(a0);
    let y0 = m_fneg(a1);
    if x0 >= 0 && y0 >= 0 && (has_one_use(a0) || has_one_use(a1)) {
        var nid: i64 = 0;
        if iid == IID_maxnum { nid = IID_minnum; }
        else if iid == IID_minnum { nid = IID_maxnum; }
        else if iid == IID_maximumnum { nid = IID_minimumnum; }
        else if iid == IID_minimumnum { nid = IID_maximumnum; }
        else if iid == IID_maximum { nid = IID_minimum; }
        else { nid = IID_maximum; }
        let nc = icx_binary_intrinsic_f(nid, x0, y0, icx_fmf(ii), "");
        let fneg = icx_new_fneg(nc, 0);
        copy_ir_flags(fneg, ii);
        return fneg;
    }
    if inst_iid(a0) == iid && m_apfloat(a1) >= 0 {
        let m = a0;
        var x: i32 = -1;
        var c2: i32 = -1;
        if m_apfloat(op(m, 1)) >= 0 { x = op(m, 0); c2 = m_apfloat(op(m, 1)); }
        else if m_apfloat(op(m, 0)) >= 0 { x = op(m, 1); c2 = m_apfloat(op(m, 0)); }
        if x >= 0 {
            let c1 = m_apfloat(a1);
            let res = cf_fp_binary_intrinsic(iid, c1, c2);
            if res < 0 { fatal("internal: FP min/max of constants did not fold"); }
            var rc = res;
            if ty_is_vector(vals[a0].ty) { rc = c_splat(vals[a0].ty, res); }
            let v = icx_binary_intrinsic_f(iid, x, rc, fmf_intersect(ii, m), "");
            return ic_replace_inst_uses_with(ii, v);
        }
    }
    let ex = m_fpext_x(a0);
    let ey = m_fpext_x(a1);
    if ex >= 0 && ey >= 0 && (has_one_use(a0) || has_one_use(a1)) && vals[ex].ty == vals[ey].ty {
        var nm: u8[>..] = [];
        nm.append(val_name(ii));
        let nc = icx_binary_intrinsic_f(iid, ex, ey, icx_fmf(ii), nm);
        return ic_new_cast(OP_FPEXT, nc, vals[ii].ty);
    }
    if one_use(a0) && ex >= 0 && is_imm_c(a1) {
        let tc = get_lossless_inv_cast(a1, vals[ex].ty, OP_FPEXT);
        if tc >= 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(ii));
            let nc = icx_binary_intrinsic_f(iid, ex, tc, icx_fmf(ii), nm);
            return ic_new_cast(OP_FPEXT, nc, vals[ii].ty);
        }
    }
    var x: i32 = -1;
    let is_min = iid == IID_minimum || iid == IID_minnum || iid == IID_minimumnum;
    for k in 2 {
        let p0 = if k == 0 { a0 } else { a1 };
        let p1 = if k == 0 { a1 } else { a0 };
        let n = m_fneg(p0);
        if n >= 0 && p1 == n && (has_one_use(p0) || !is_min) { x = n; break; }
    }
    if x >= 0 {
        var r = icx_fabs(x, icx_fmf(ii));
        if is_min { r = icx_fneg(r, icx_fmf(ii), ""); }
        return ic_replace_inst_uses_with(ii, r);
    }
    return -2;
}

// case Intrinsic::matrix_multiply
fn visit_matrix_multiply(ii: i32, iid: i32) -> i32 {
    let a = m_fneg(cb_arg(ii, 0));
    let b = m_fneg(cb_arg(ii, 1));
    if a >= 0 && b >= 0 {
        ic_replace_operand(ii, 0, a);
        ic_replace_operand(ii, 1, b);
        return ii;
    }
    let op0 = op(ii, 0);
    let op1 = op(ii, 1);
    var notneg: i32 = -1;
    var negop: i32 = -1;
    var nk: i64 = 0;
    var ok: i64 = 0;
    let n0 = m_fneg(op0);
    if n0 >= 0 { notneg = n0; negop = op0; nk = 0; ok = 1; }
    else {
        let n1 = m_fneg(op1);
        if n1 >= 0 { notneg = n1; negop = op1; nk = 1; ok = 0; } else { return -2; }
    }
    if !has_one_use(negop) { return -2; }
    let other = op(ii, ok);
    let nc = ty_count(vals[negop].ty);
    let oc = ty_count(vals[other].ty);
    let rc = ty_count(vals[ii].ty);
    if nc > oc && oc < rc {
        let inv = icx_fneg(other, icb_fmf, "");
        ic_replace_operand(ii, nk, notneg);
        ic_replace_operand(ii, ok, inv);
        return ii;
    }
    if nc > rc {
        var na: i32[>..<] = [];
        for k in cb_nargs(ii) { na.push(cb_arg(ii, k)); }
        na[nk] = notneg;
        let nm = icx_intrinsic_rt_f(vals[ii].ty, iid, na, icx_fmf(ii), "");
        return ic_replace_inst_uses_with(ii, icx_fneg(nm, icx_fmf(ii), ""));
    }
    return -2;
}

// simplifyFMulInst(Op0, Op1, FMF, SQ) / simplifyFMAFMul
fn simplify_fmul_inst(a: i32, b: i32, fmf: u8, cx: i32) -> i32 { simplify_fmul(a, b, fmf, sq_at(cx), 3, 0, 0) }
fn simplify_fma_fmul_inst(a: i32, b: i32, fmf: u8, cx: i32) -> i32 { simplify_fma_fmul(a, b, fmf, sq_at(cx), 3, 0, 0) }

// case Intrinsic::fma (and the fmuladd fallthrough)
fn visit_fma(ii: i32, iid: i32) -> i32 {
    let s0 = cb_arg(ii, 0);
    let s1 = cb_arg(ii, 1);
    let s2 = cb_arg(ii, 2);
    let fmf = icx_fmf(ii);
    let x = m_fneg(s0);
    let y = m_fneg(s1);
    if x >= 0 && y >= 0 { return ic_replace_inst_uses_with(ii, icx_intrinsic_f(iid, [vals[ii].ty], [x, y, s2], fmf, "")); }
    let ax = m_fabs_x(s0);
    if ax >= 0 && m_fabs_x(s1) == ax { return ic_replace_inst_uses_with(ii, icx_intrinsic_f(iid, [vals[ii].ty], [ax, ax, s2], fmf, "")); }
    let v = simplify_fma_fmul_inst(s0, s1, fmf, ii);
    if v >= 0 { return icx_new_fbinop(OP_FADD, v, s2, fmf); }
    if m_neg_zero_fp(s2) || (m_pos_zero_fp(s2) && (fmf & FMF_NSZ) != 0) { return icx_new_fbinop(OP_FMUL, s0, s1, fmf); }
    if m_specific_fp(s1, -1.0) { return icx_new_fbinop(OP_FSUB, s2, s0, fmf); }
    return -2;
}

// case Intrinsic::copysign
fn visit_copysign(ii: i32) -> i32 {
    let mag = cb_arg(ii, 0);
    let sign = cb_arg(ii, 1);
    let fmf = icx_fmf(ii);
    kb_cxt = ii;
    let ksb = compute_known_fp_sign_bit(sign, 0);
    if ksb >= 0 {
        let fabs = icx_fabs(mag, fmf);
        if ksb == 1 { return ic_replace_inst_uses_with(ii, icx_fneg(fabs, fmf, "")); }
        return ic_replace_inst_uses_with(ii, fabs);
    }
    if m_intrinsic(sign, IID_copysign) {
        let cs = icx_copysign(mag, op(sign, 1), fmf_intersect(ii, sign));
        return ic_replace_inst_uses_with(ii, cs);
    }
    let mc = m_apfloat(mag);
    if mc >= 0 && cfp_parts(mc).neg {
        let k = fp_kind_ty(vals[mc].ty);
        let lo, hi = fp_with_sign(k, cint_lo(mc), cint_hi(mc), false);
        var pos = c_fp(vals[mc].ty, lo, hi);
        if ty_is_vector(vals[mag].ty) { pos = c_splat(vals[mag].ty, pos); }
        return ic_replace_inst_uses_with(ii, icx_copysign(pos, sign, fmf));
    }
    var x = m_fabs_x(mag);
    if x < 0 { x = m_fneg(mag); }
    if x >= 0 { return ic_replace_inst_uses_with(ii, icx_copysign(x, sign, fmf)); }
    if m_intrinsic(mag, IID_floor) {
        let fa = m_fabs_x(op(mag, 0));
        if fa >= 0 && fa == sign {
            let tr = icx_unary_intrinsic_f(IID_trunc, sign, fmf, "");
            return ic_replace_inst_uses_with(ii, icx_copysign(tr, sign, fmf));
        }
    }
    let sety = ty_scalar(vals[sign].ty);
    if one_use(sign) && is_inst_op(sign, OP_BITCAST) && ic_elementwise_bitcast(sign) && one_use(op(sign, 0)) &&
       is_int_or_int_vec(vals[op(sign, 0)].ty) && fp_has_sign_bit_in_msb(sety) {
        let w = ty_prim_bits(sety);
        icb_set_insert_point(ii);
        let saved = sd_cxt;
        sd_cxt = sign;
        let ch, k = sd_bits(sign, 0, ap_sign_mask(w), 0);
        sd_cxt = saved;
        if ch { return ii; }
    }
    return -2;
}
// APFloat::hasSignBitInMSB: every IEEE-like semantics we support
fn fp_has_sign_bit_in_msb(t: i32) -> bool { ty_kind(t) != TK_PPC_FP128 || true }
fn ty_prim_bits(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    return 128;
}

// case Intrinsic::ceil ... trunc (and the fabs fallthrough)
fn visit_rounding(ii: i32, iid: i32) -> i32 {
    let a = cb_arg(ii, 0);
    if one_use(a) {
        let es = m_fpext_x(a);
        if es >= 0 {
            let n = icx_unary_intrinsic_f(iid, es, icx_fmf(ii), "");
            return ic_new_cast(OP_FPEXT, n, vals[ii].ty);
        }
    }
    return -2;
}

// case Intrinsic::ldexp
fn visit_ldexp(ii: i32) -> i32 {
    let src = cb_arg(ii, 0);
    let ex = cb_arg(ii, 1);
    let fmf = icx_fmf(ii);
    let ce = icx_m_cint64(ex);
    if ce >= 0 {
        let st = ty_scalar(vals[src].ty);
        let kind = fp_kind_ty(st);
        let olo, ohi = fp_from_f64(kind, 1.0);
        let e32 = (ap_zext64(ci_ap(ce)) as! i64) & 0xFFFFFFFF;
        let es = if e32 >= 0x80000000 { e32 - 0x100000000 } else { e32 };
        let slo, shi = fp_scalbn(kind, olo, ohi, es);
        let p = fp_decompose(kind, slo, shi);
        if p.cat != FC_ZERO && p.cat != FC_INF {
            var c = c_fp(st, slo, shi);
            if ty_is_vector(vals[src].ty) { c = c_splat(vals[src].ty, c); }
            return icx_new_fbinop(OP_FMUL, src, c, fmf);
        }
    }
    if one_use(src) && m_intrinsic(src, IID_ldexp) && vals[ex].ty == vals[op(src, 1)].ty {
        let isrc = op(src, 0);
        let iexp = op(src, 1);
        let inner = icx_fmf(src);
        if ldexp_saturating_add_is_safe(vals[ii].ty, vals[ex].ty) &&
           (((fmf & FMF_REASSOC) != 0 && (inner & FMF_REASSOC) != 0) || sign_bit_must_be_the_same(ex, iexp, ii)) {
            let ne = icx_binary_intrinsic(IID_sadd_sat, iexp, ex, "");
            return ic_replace_inst_uses_with(ii, icx_ldexp(isrc, ne, fmf | inner, ""));
        }
    }
    let zs = m_zext(ex);
    if zs >= 0 && ty_scalar_bits(vals[zs].ty) == 1 {
        let s = icb_select(zs, c_fp_from_f64(vals[ii].ty, 2.0), c_fp_from_f64(vals[ii].ty, 1.0), "", -1);
        return icx_new_fbinop(OP_FMUL, src, s, fmf);
    }
    let ss = m_sext(ex);
    if ss >= 0 && ty_scalar_bits(vals[ss].ty) == 1 {
        let s = icb_select(ss, c_fp_from_f64(vals[ii].ty, 0.5), c_fp_from_f64(vals[ii].ty, 1.0), "", -1);
        return icx_new_fbinop(OP_FMUL, src, s, fmf);
    }
    let a1 = cb_arg(ii, 1);
    if one_use(a1) && is_select_inst(a1) {
        let sc = op(a1, 0);
        let sl = op(a1, 1);
        let sr = op(a1, 2);
        var nl: i32 = -1;
        var sel: i32 = -1;
        if m_zero_int(sr) {
            nl = icx_ldexp(src, sl, fmf, "");
            sel = icb_select(sc, nl, src, "", -1);
        } else if m_zero_int(sl) {
            nl = icx_ldexp(src, sr, fmf, "");
            sel = icb_select(sc, src, nl, "", -1);
        }
        if nl >= 0 {
            ic_take_name(sel, ii);
            return ic_replace_inst_uses_with(ii, sel);
        }
    }
    return -2;
}
// m_ConstantInt(uint64_t&): a ConstantInt (or splat) of at most 64 bits; -1 if none
fn icx_m_cint64(v: i32) -> i32 {
    var c = v;
    if vals[v].kind == VK_CINT && ty_is_vector(vals[v].ty) { c = splat_value(v, false); }
    else if vals[v].kind != VK_CINT {
        if !is_constant(v) || !ty_is_vector(vals[v].ty) { return -1; }
        c = splat_value(v, false);
    }
    if c < 0 || vals[c].kind != VK_CINT || ap_active_bits(ci_ap(c)) > 64 { return -1; }
    return c;
}

// case Intrinsic::stackrestore
fn sr_classify(i: i32) -> i64 {
    if is_inst_op(i, OP_ALLOCA) { return 1; }
    if is_inst_op(i, OP_CALL) {
        let id = call_iid(i);
        if id != 0 {
            if id == IID_stackrestore { return 2; }
            if inst_may_have_side_effects(i) { return 3; }
        } else {
            return 3;
        }
    }
    return 0;
}
fn visit_stackrestore(ii: i32) -> i32 {
    let ci = ii;
    let ss = cb_arg(ii, 0);
    if inst_iid(ss) == IID_stacksave && inst_parent(ss) == inst_parent(ii) {
        var bi = inst_next(ss);
        var cannot = false;
        while bi != ii {
            let c = sr_classify(bi);
            if c == 2 { if cb_arg(bi, 0) != ss { cannot = true; } }
            else if c == 1 || c == 3 { cannot = true; }
            if cannot { break; }
            bi = inst_next(bi);
        }
        if !cannot { return ic_erase(ci); }
    }
    let ti = block_last(inst_parent(ii));
    var bi = inst_next(ii);
    var cannot = false;
    while bi != ti {
        let c = sr_classify(bi);
        if c == 2 { return ic_erase(ci); }
        if c == 1 || c == 3 { cannot = true; break; }
        bi = inst_next(bi);
    }
    if !cannot && (iop(ti) == OP_RET || iop(ti) == OP_RESUME) { return ic_erase(ci); }
    return -2;
}

// case Intrinsic::experimental_guard
fn visit_guard(ii: i32) -> i32 {
    var next = inst_next(ii);
    let window = flag_int("guard-widening-window", 3);
    for i in window {
        if !spec_safe(next, -1, false) { break; }
        next = inst_next(next);
    }
    if inst_iid(next) == IID_experimental_guard {
        let nc = cb_arg(next, 0);
        let cc = cb_arg(ii, 0);
        if cc != nc {
            var mv = inst_next(ii);
            while mv != next {
                let t = mv;
                mv = inst_next(mv);
                inst_move_before(t, ii);
            }
            ic_replace_operand(ii, 0, icb_and(cc, nc, ""));
        }
        ic_erase(next);
        return ii;
    }
    return -2;
}

// case Intrinsic::vector_insert
fn visit_vector_insert(ii: i32) -> i32 {
    let vec = cb_arg(ii, 0);
    let sub = cb_arg(ii, 1);
    let idx = cb_arg(ii, 2);
    let dt = vals[ii].ty;
    let vt = vals[vec].ty;
    let st = vals[sub].ty;
    if ty_kind(dt) == TK_FVEC && ty_kind(vt) == TK_FVEC && ty_kind(st) == TK_FVEC {
        let dn = ty_count(dt);
        let vn = ty_count(vt);
        let sn = ty_count(st);
        let idxn = ap_zext64(ci_ap(idx)) as i64;
        if vn == sn { return ic_replace_inst_uses_with(ii, sub); }
        var wm: i32[>..<] = [];
        for i in sn { wm.push(i as i32); }
        for i in sn..vn { wm.push(-1); }
        let ws = icb_shuffle1(sub, wm, "");
        var mask: i32[>..<] = [];
        for i in idxn { mask.push(i as i32); }
        for i in dn..(dn + sn) { mask.push(i as i32); }
        for i in (idxn + sn)..dn { mask.push(i as i32); }
        let sh = icb_shuffle(vec, ws, mask, "");
        return ic_replace_inst_uses_with(ii, sh);
    }
    return -2;
}

// case Intrinsic::vector_extract
fn visit_vector_extract(ii: i32) -> i32 {
    let ci = ii;
    let vec = cb_arg(ii, 0);
    let idx = cb_arg(ii, 1);
    let rt = vals[ii].ty;
    let ei = ap_zext64(ci_ap(idx)) as i64;
    if m_intrinsic(vec, IID_vector_insert) && vals[op(vec, 1)].ty == rt {
        let index = ap_zext64(ci_ap(op(vec, 2))) as i64;
        if ei == index { return ic_replace_inst_uses_with(ci, op(vec, 1)); }
        return ic_replace_operand(ci, 0, op(vec, 0));
    }
    if m_intrinsic(vec, IID_get_active_lane_mask) && vals[op(vec, 1)].kind == VK_CINT && !ty_is_vector(vals[op(vec, 1)].ty) {
        let ub = op(vec, 1);
        let vmin = vscale_range_min(inst_func(ii));
        let sf = if ty_kind(rt) == TK_SVEC { vmin } else { 1 };
        if ap_uge_u64(ci_ap(ub), 0) && (ei * sf) as u64 >= ap_zext64(ci_ap(ub)) { return ic_replace_inst_uses_with(ci, c_null(rt)); }
    }
    if ty_is_vector(rt) && ty_is_vector(vals[vec].ty) {
        let ds = ty_kind(rt) == TK_SVEC;
        let vs = ty_kind(vals[vec].ty) == TK_SVEC;
        if ty_count(rt) == ty_count(vals[vec].ty) && ds == vs {
            ic_replace_inst_uses_with(ci, vec);
            return ic_erase(ci);
        }
        if ds || vs { return -2; }
        var mask: i32[>..<] = [];
        for i in ty_count(rt) { mask.push((ei + i) as i32); }
        return ic_replace_inst_uses_with(ci, icb_shuffle1(vec, mask, ""));
    }
    return -2;
}
// Attributes.getVScaleRangeMin(): 1 without a vscale_range attribute
fn vscale_range_min(fv: i32) -> i64 {
    let a = aset_find(alist_fn(globs[glob_of(fv)].attrs), AK_VScaleRange);
    if a < 0 { return 1; }
    return (attrs[a].i1 >> 32) as i64;
}

// IRBuilder::CreateAndReduce / CreateOrReduce / CreateAddReduce
fn icx_reduce(id: i64, src: i32) -> i32 { icb_intrinsic(id, [vals[src].ty], [src], "") }

// m_ZExtOrSExtOrSelf(m_Value(Vect))
fn m_zext_or_sext_or_self(v: i32) -> i32 { let x = m_zext_or_sext(v); if x >= 0 { x } else { v } }
fn is_vec_of_i1(t: i32) -> bool { ty_is_vector(t) && ty_is_int(ty_scalar(t)) && ty_bits(ty_scalar(t)) == 1 }

// The vector_reduce_* cases (with their fallthroughs)
fn visit_reduction(ii: i32, iid: i32) -> i32 {
    let ci = ii;
    let rty = vals[ii].ty;
    let arg = cb_arg(ii, 0);
    var stage: i64 = 0;
    if iid == IID_vector_reduce_or || iid == IID_vector_reduce_and { stage = 0; }
    else if iid == IID_vector_reduce_add { stage = 1; }
    else if iid == IID_vector_reduce_xor { stage = 2; }
    else if iid == IID_vector_reduce_mul { stage = 3; }
    else if iid == IID_vector_reduce_umin || iid == IID_vector_reduce_umax { stage = 4; }
    else if iid == IID_vector_reduce_smin || iid == IID_vector_reduce_smax { stage = 5; }
    else { stage = 6; }
    if stage == 0 {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let vect = m_zext_or_sext_or_self(arg);
        if ty_kind(vals[vect].ty) == TK_FVEC && ty_scalar(vals[vect].ty) == T_I1 {
            var res = icb_bitcast(vect, ty_int(ty_count(vals[vect].ty)), "");
            if iid == IID_vector_reduce_and { res = icb_icmp(P_EQ, res, c_all_ones(vals[res].ty), ""); }
            else { res = icb_is_not_null(res, ""); }
            if arg != vect { res = icb_cast(iop(arg), res, rty, ""); }
            return ic_replace_inst_uses_with(ci, res);
        }
    }
    if stage <= 1 && iid == IID_vector_reduce_add {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let sp = get_splat_value_v(arg);
        if sp >= 0 {
            if ty_kind(vals[arg].ty) == TK_FVEC {
                let vs = ty_count(vals[arg].ty);
                let sty = vals[sp].ty;
                return ic_new_binop(OP_MUL, sp, c_int_ap(sty, ap_trunc(ap_u64(vs as u64, 64), ty_scalar_bits(sty))));
            }
        }
        let vect = m_zext_or_sext_or_self(arg);
        if ty_kind(vals[vect].ty) == TK_FVEC && ty_scalar(vals[vect].ty) == T_I1 {
            let v = icb_bitcast(vect, ty_int(ty_count(vals[vect].ty)), "");
            var res = icx_unary_intrinsic(IID_ctpop, v, "");
            res = icb_zext_or_trunc(res, rty, "");
            if arg != vect && iop(arg) == OP_SEXT { res = icb_neg(res, "", false); }
            return ic_replace_inst_uses_with(ci, res);
        }
    }
    if stage <= 2 && iid == IID_vector_reduce_xor {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let vect = m_zext_or_sext_or_self(arg);
        if ty_is_vector(vals[vect].ty) && ty_scalar(vals[vect].ty) == T_I1 {
            var res = icx_reduce(IID_vector_reduce_add, vect);
            if arg != vect { res = icb_cast(iop(arg), res, rty, ""); }
            return ic_replace_inst_uses_with(ci, res);
        }
    }
    if stage <= 3 && iid == IID_vector_reduce_mul {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let zv = m_zext(arg);
        let sv = m_sext(arg);
        let is_z = zv >= 0 && is_int_ty1(vals[zv].ty);
        let is_s = sv >= 0 && is_int_ty1(vals[sv].ty) && ty_count(vals[sv].ty) % 2 == 0;
        if is_z || is_s {
            let vect = if is_z { zv } else { sv };
            let res = icx_reduce(IID_vector_reduce_and, vect);
            return ic_new_cast(OP_ZEXT, res, rty);
        }
        if is_int_ty1(vals[arg].ty) { return ic_replace_inst_uses_with(ci, icx_reduce(IID_vector_reduce_and, arg)); }
    }
    if stage <= 4 && (iid == IID_vector_reduce_umin || iid == IID_vector_reduce_umax) {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let vect = m_zext_or_sext_or_self(arg);
        if ty_is_vector(vals[vect].ty) && ty_scalar(vals[vect].ty) == T_I1 {
            var res = icx_reduce(if iid == IID_vector_reduce_umin { IID_vector_reduce_and } else { IID_vector_reduce_or }, vect);
            if arg != vect { res = icb_cast(iop(arg), res, rty, ""); }
            return ic_replace_inst_uses_with(ci, res);
        }
    }
    if stage <= 5 && (iid == IID_vector_reduce_smin || iid == IID_vector_reduce_smax) {
        let no = simplify_reduction_operand(arg, true);
        if no >= 0 { ic_replace_use(vals[ii].ops, no); return ii; }
        let vect = m_zext_or_sext_or_self(arg);
        if ty_is_vector(vals[vect].ty) && ty_scalar(vals[vect].ty) == T_I1 {
            var ext: i64 = -1;
            if arg != vect { ext = iop(arg); }
            let use_and = (iid == IID_vector_reduce_smin) == (ext == OP_ZEXT);
            var res = icx_reduce(if use_and { IID_vector_reduce_and } else { IID_vector_reduce_or }, vect);
            if arg != vect { res = icb_cast(ext, res, rty, ""); }
            return ic_replace_inst_uses_with(ci, res);
        }
    }
    // vector_reduce_fmax / fmin / fadd / fmul (and everything falling through)
    let is_fadd_mul = iid == IID_vector_reduce_fadd || iid == IID_vector_reduce_fmul;
    let can_reorder = !is_fadd_mul || (icx_fmf(ii) & FMF_REASSOC) != 0;
    let ak: i64 = if is_fadd_mul { 1 } else { 0 };
    let a = cb_arg(ii, ak);
    let no = simplify_reduction_operand(a, can_reorder);
    if no >= 0 {
        ic_replace_use(vals[ii].ops + (ak as i32), no);
        return -1;
    }
    return -2;
}

// case Intrinsic::assume
fn visit_assume_case(ii: i32) -> i32 {
    let nb = cb_nbundles(ii);
    for idx in nb {
        let r, done = assume_bundle_fold(ii, idx);
        if done { return r; }
    }
    if cb_nbundles(ii) > 0 { return -2; }
    let c = cb_arg(ii, 0);
    if m_logical_and(c) {
        let a = lg_a; let b = lg_b;
        icb_assumption(a);
        icb_assumption(b);
        return ic_erase(ii);
    }
    let n = m_not(c);
    if n >= 0 && m_logical_or(n) {
        let a = lg_a; let b = lg_b;
        icb_assumption(icb_not(a, ""));
        icb_assumption(icb_not(b, ""));
        return ic_erase(ii);
    }
    if is_inst_op(c, OP_ICMP) && inst_pred(c) == P_NE && m_zero(op(c, 1)) && ty_kind(vals[op(c, 0)].ty) == TK_PTR {
        icb_nonnull_assumption(op(c, 0));
        return ic_erase(ii);
    }
    var align_mask: u64 = 1;
    var a: i32 = -1;
    if n >= 0 && is_inst_op(n, OP_TRUNC) { a = op(n, 0); }
    else if is_inst_op(c, OP_ICMP) && inst_pred(c) == P_EQ && m_zero(op(c, 1)) && bo(op(c, 0), OP_AND) {
        let mc = icx_m_cint64(op(op(c, 0), 1));
        if mc >= 0 { a = op(op(c, 0), 0); align_mask = ap_zext64(ci_ap(mc)); }
    }
    if a >= 0 {
        let p = m_ptrtoint_or_addr(a);
        if icx_is_pow2_u64(align_mask + 1) && p >= 0 {
            icb_alignment_assumption(p, align_mask + 1, -1);
            return ic_erase(ii);
        }
    }
    if (vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty)) || is_undef_or_poison(c) {
        if vals[c].kind != VK_CINT || ap_is_zero(ci_ap(c)) { ic_create_non_terminator_unreachable(ii); }
        return ic_erase(ii);
    }
    if ac_fn >= 0 && ac_fn == inst_func(ii) { ac_update_affected(ii); }
    return -2;
}

// RemoveBundle lambda: erase the assume or drop bundle idx (CallBase::removeOperandBundleAt)
fn assume_remove_bundle(ii: i32, idx: i64) -> i32 {
    if cb_nbundles(ii) == 1 { return ic_erase(ii); }
    return cb_remove_operand_bundle_at(ii, idx);
}

// One operand bundle of an assume (the loop body of `case Intrinsic::assume`): (result, returned)
fn assume_bundle_fold(ii: i32, idx: i64) -> i32, bool {
    let tag = sbytes(cb_bundle_tag(ii, idx));
    let b = cb_bundle_begin(ii, idx);
    let n = cb_bundle_count(ii, idx);
    if tag == "align" {
        // getAssumeAlignInfo
        if n < 2 { return -1, false; }
        let ptr = op(ii, b);
        let ac = op(ii, b + 1);
        if m_constant_int(ac) < 0 { return -1, false; }
        let al = ap_limited(ci_ap(ac), 0xFFFFFFFFFFFFFFFF);
        var off_ptr: i32 = -1;
        var off: i64 = 0;
        var has_off = true;
        if n >= 3 {
            off_ptr = op(ii, b + 2);
            if m_constant_int(off_ptr) >= 0 { off = ap_sext64(ci_ap(off_ptr)); } else { has_off = false; }
        }
        if al == 1 || !icx_is_pow2_u64(al) { return assume_remove_bundle(ii, idx), true; }
        if is_gep_operator(ptr) && gep_max_preserved_alignment(ptr) >= al {
            icb_alignment_assumption(gep_pointer_operand(ptr), al, off_ptr);
            return assume_remove_bundle(ii, idx), true;
        }
        if !has_off { return -1, false; }
        if sd_is_ptr_add(ptr) && has_apint(op(ptr, 1)) {
            let iw = dl_index_width(vals[ptr].ty);
            let pv = ap_sext_or_trunc(ap_c(op(ptr, 1)), iw);
            if ap_num_sign_bits(pv) < pv.w as i64 - 63 { return -1, false; }
            icb_alignment_assumption(op(ptr, 0), al, c_int(T_I64, off - ap_sext64(pv)));
            return assume_remove_bundle(ii, idx), true;
        }
        let uo = get_underlying_object(ptr, 6);
        if uo < 0 || is_arg(uo) { return -1, false; }
        let am = al - 1;
        kb_cxt = ii;
        let kb = kb_compute_all(ptr, 0);
        let w = kb_bw(kb);
        let amk = ap_zext_or_trunc(ap_u64(am, 64), w);
        let offa = ap_zext_or_trunc(ap_u64(off as u64, 64), w);
        if ap_eq(ap_and(kb.z, amk), ap_and(ap_not(offa), amk)) && ap_eq(ap_and(kb.o, amk), ap_and(offa, amk)) {
            return assume_remove_bundle(ii, idx), true;
        }
        return -1, false;
    }
    if tag == "dereferenceable" {
        if n < 2 { return -1, false; }
        let ptr = op(ii, b);
        let cc = op(ii, b + 1);
        if m_constant_int(cc) < 0 { return -1, false; }
        let cnt = ap_limited(ci_ap(cc), 0xFFFFFFFFFFFFFFFF);
        if cnt == 0 || ld_is_dereferenceable_pointer_size(ptr, cnt, ii) { return assume_remove_bundle(ii, idx), true; }
        return -1, false;
    }
    if tag == "ignore" { return assume_remove_bundle(ii, idx), true; }
    if tag == "nonnull" {
        let ptr = op(ii, b);
        kb_cxt = ii;
        if is_known_non_zero(ptr, 0) { return assume_remove_bundle(ii, idx), true; }
        if is_inst_op(ptr, OP_LOAD) {
            let save = vt_allow_ephemerals;
            vt_allow_ephemerals = true;
            let ok = valid_assume_for_context(ii, ptr);
            vt_allow_ephemerals = save;
            if ok {
                let e = md_node_empty();
                inst_set_md(ptr, md_kind_id("nonnull"), e);
                inst_set_md(ptr, md_kind_id("noundef"), e);
                return assume_remove_bundle(ii, idx), true;
            }
        }
        if is_gep_operator(ptr) && (op_flags(ptr) & GEP_INBOUNDS) != 0 && !null_pointer_is_defined(inst_func(ii), ptr_as(vals[ptr].ty)) {
            icb_nonnull_assumption(strip_in_bounds_offsets(ptr));
            return assume_remove_bundle(ii, idx), true;
        }
        return -1, false;
    }
    if tag == "noundef" {
        let v = op(ii, b);
        if is_guaranteed_not_to_be_undef_or_poison_cx(v, ii) { return assume_remove_bundle(ii, idx), true; }
        if is_inst_op(v, OP_LOAD) {
            let save = vt_allow_ephemerals;
            vt_allow_ephemerals = true;
            let ok = valid_assume_for_context(ii, v);
            vt_allow_ephemerals = save;
            if ok {
                inst_set_md(v, md_kind_id("noundef"), md_node_empty());
                return assume_remove_bundle(ii, idx), true;
            }
        }
        return -1, false;
    }
    if tag == "separate_storage" {
        for k in 2 {
            let u = vals[ii].ops + ((b + k) as i32);
            let hint = uses[u].val;
            let uo = get_underlying_object(hint, 0);
            if hint != uo { ic_replace_use(u, uo); }
        }
        return -1, false;
    }
    if tag == "dereferenceable_or_null" || tag == "cold" { return -1, false; }
    return -1, false;
}

fn md_node_empty() -> i32 { md_get(MK_TUPLE, -1, [], false) }

// MDNode metadata operand that is a ConstantInt (mdconst::dyn_extract<ConstantInt>): -1 if not
fn md_const_int_op(m: i32, k: i64) -> i32 {
    if k >= mds[m].nops as i64 { return -1; }
    let o = md_op(m, k);
    if o < 0 || mds[o].kind != MK_VALUE { return -1; }
    let v = mds[o].extra;
    if vals[v].kind != VK_CINT { return -1; }
    return v;
}

// isDereferenceablePointer(V, APInt(64, Count), SQ.getWithInstruction(CxtI)) (InstCombine's SQ: AC and DT)
fn ld_is_dereferenceable_pointer_size(v: i32, cnt: u64, cx: i32) -> bool {
    let sc = spec_cxt;
    let sa = spec_use_ac;
    spec_cxt = cx;
    spec_use_ac = true;
    spec_visited.clear();
    let r = spec_deref_aligned(v, 1, ap_u64(cnt, 64), 16);
    spec_cxt = sc;
    spec_use_ac = sa;
    return r;
}
// isDereferenceablePointer(V, Ty, SQ.getWithInstruction(CxtI))
fn ld_is_dereferenceable_pointer_ty(v: i32, ty: i32, cx: i32) -> bool {
    let sc = spec_cxt;
    let sa = spec_use_ac;
    spec_cxt = cx;
    spec_use_ac = true;
    let r = spec_deref_aligned_ty(v, ty, 1);
    spec_cxt = sc;
    spec_use_ac = sa;
    return r;
}

// getKnownAlignment(V, DL, CxtI, AC, DT)
fn get_known_alignment(v: i32, cx: i32) -> i64 { lsa_get_or_enforce_known_alignment(v, 0, cx) }

// CallBase::getParamAlign(k) (call site, then callee)
fn cb_param_align(ci: i32, k: i64) -> u64 {
    var a = aset_int(alist_param(insts[inst_of(ci)].attrs, k), AK_Alignment);
    if a == 0 {
        let f = called_function(ci);
        if f >= 0 { a = aset_int(alist_param(globs[glob_of(f)].attrs, k), AK_Alignment); }
    }
    return a;
}
// setParamAlignment: replace the align attribute of param k
fn cb_set_param_align(ci: i32, k: i64, al: i64) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let s = aset_with(alist_param(l, k), attr_int(AK_Alignment, al as u64));
    insts[ii].attrs = alist_set_param(l, k, s);
}

// AAMDNodes::adjustForAccess(AccessSize) applied to dst from src's AA metadata
fn icx_set_aa_md_for_access(dst: i32, src: i32, size: u64) {
    let ktbaa = md_kind_id("tbaa");
    let kts = md_kind_id("tbaa.struct");
    var tbaa = inst_get_md(src, ktbaa);
    let m = inst_get_md(src, kts);
    if tbaa < 0 && m >= 0 && mds[m].nops >= 3 {
        let c0 = md_const_int_op(m, 0);
        let c1 = md_const_int_op(m, 1);
        let o2 = md_op(m, 2);
        if c0 >= 0 && ap_is_zero(ci_ap(c0)) && c1 >= 0 && ap_eq(ci_ap(c1), ap_u64(size, ty_bits(vals[c1].ty))) &&
           o2 >= 0 && md_is_node(o2) {
            tbaa = o2;
        }
    }
    if tbaa >= 0 { inst_set_md(dst, ktbaa, tbaa); } else { inst_erase_md(dst, ktbaa); }
    inst_erase_md(dst, kts);
    for nm in ["alias.scope", "noalias", "noalias.addrspace"] { inst_copy_md_kind(dst, src, md_kind_id(nm)); }
}

// hasUndefSource(MI)
fn has_undef_source(mi: i32) -> bool {
    var src = cb_arg(mi, 1);
    while is_inst_op(src, OP_GEP) {
        if !has_one_use(src) { return false; }
        src = op(src, 0);
    }
    return is_inst_op(src, OP_ALLOCA) && has_one_use(src);
}

// MI->setLength(0)
fn mi_set_length_zero(mi: i32) { set_op(mi, 2, c_null(vals[cb_arg(mi, 2)].ty)); }

// SimplifyAnyMemTransfer(MI)
fn simplify_any_mem_transfer(mi: i32) -> i32 {
    let dst_align = get_known_alignment(cb_arg(mi, 0), mi);
    let cda = cb_param_align(mi, 0);
    if cda == 0 || (cda as i64) < dst_align {
        cb_set_param_align(mi, 0, dst_align);
        return mi;
    }
    let src_align = get_known_alignment(cb_arg(mi, 1), mi);
    let csa = cb_param_align(mi, 1);
    if csa == 0 || (csa as i64) < src_align {
        cb_set_param_align(mi, 1, src_align);
        return mi;
    }
    if !icx_mod_set_dest(mi) {
        mi_set_length_zero(mi);
        return mi;
    }
    if has_undef_source(mi) && !mi_is_volatile(mi) {
        mi_set_length_zero(mi);
        return mi;
    }
    let lc = cb_arg(mi, 2);
    if vals[lc].kind != VK_CINT { return -1; }
    let size = ap_limited(ci_ap(lc), 0xFFFFFFFFFFFFFFFF);
    if size > 8 || (size & (size - 1)) != 0 { return -1; }
    let atomic = mi_is_atomic(call_iid(mi));
    if atomic && (cda < size || csa < size) { return -1; }
    let it = ty_int((size << 3) as i64);
    let src = cb_arg(mi, 1);
    let dest = cb_arg(mi, 0);
    let l = icb_aligned_load(it, src, csa as i64, "");
    icx_set_aa_md_for_access(l, mi, size);
    let kpar = md_kind_id("mem.parallel_loop_access");
    let kag = md_kind_id("access_group");
    let lpm = inst_get_md(mi, kpar);
    if lpm >= 0 { inst_set_md(l, kpar, lpm); }
    let agm = inst_get_md(mi, kag);
    if agm >= 0 { inst_set_md(l, kag, agm); }
    let s = icb_aligned_store(l, dest, cda as i64);
    icx_set_aa_md_for_access(s, mi, size);
    if lpm >= 0 { inst_set_md(s, kpar, lpm); }
    if agm >= 0 { inst_set_md(s, kag, agm); }
    let kda = md_kind_id("DIAssignID");
    if inst_get_md(mi, kda) >= 0 { ic_not_ported("SimplifyAnyMemTransfer with DIAssignID"); }
    if !atomic {
        let vol = mi_is_volatile(mi);
        if vol { insts[inst_of(l)].bits |= 1; insts[inst_of(s)].bits |= 1; }
    } else {
        insts[inst_of(l)].ord = 1;
        insts[inst_of(s)].ord = 1;
    }
    mi_set_length_zero(mi);
    return mi;
}

// SimplifyAnyMemSet(MI)
fn simplify_any_mem_set(mi: i32) -> i32 {
    let ka = get_known_alignment(strip_ptr_casts(cb_arg(mi, 0)), mi);
    let msa = cb_param_align(mi, 0);
    if msa == 0 || (msa as i64) < ka {
        cb_set_param_align(mi, 0, ka);
        return mi;
    }
    if !icx_mod_set_dest(mi) {
        mi_set_length_zero(mi);
        return mi;
    }
    let val = cb_arg(mi, 1);
    if vals[val].kind == VK_UNDEF || vals[val].kind == VK_POISON {
        mi_set_length_zero(mi);
        return mi;
    }
    let lc = cb_arg(mi, 2);
    if vals[lc].kind != VK_CINT || vals[val].kind != VK_CINT || ty_is_vector(vals[val].ty) || ty_bits(vals[val].ty) != 8 { return -1; }
    let len = ap_limited(ci_ap(lc), 0xFFFFFFFFFFFFFFFF);
    var al = msa;
    if al == 0 { al = 1; }
    if mi_is_atomic(call_iid(mi)) && al < len { return -1; }
    if len <= 8 && icx_is_pow2_u64(len & 0xFFFFFFFF) {
        let dest = strip_ptr_casts(cb_arg(mi, 0));
        let fill = c_int_ap(ty_int((len * 8) as i64), ap_splat((len * 8) as i64, ci_ap(val)));
        let s = icb_aligned_store(fill, dest, al as i64);
        if mi_is_volatile(mi) { insts[inst_of(s)].bits |= 1; }
        let kda = md_kind_id("DIAssignID");
        if inst_get_md(mi, kda) >= 0 { ic_not_ported("SimplifyAnyMemSet with DIAssignID"); }
        if mi_is_atomic(call_iid(mi)) { insts[inst_of(s)].ord = 1; }
        mi_set_length_zero(mi);
        return mi;
    }
    return -1;
}

// simplifyMaskedLoad(II)
fn simplify_masked_load(ii: i32) -> i32 {
    let lp = cb_arg(ii, 0);
    var al = cb_param_align(ii, 0);
    if al == 0 { al = 1; }
    let mask = cb_arg(ii, 1);
    if icx_m_all_ones_or_poison(mask) {
        let l = icb_aligned_load(vals[ii].ty, lp, al as i64, "unmaskedload");
        inst_copy_all_md(l, ii);
        return l;
    }
    if ld_is_dereferenceable_pointer_ty(lp, vals[ii].ty, ii) {
        let li = icb_aligned_load(vals[ii].ty, lp, al as i64, "unmaskedload");
        inst_copy_all_md(li, ii);
        return icb_select(cb_arg(ii, 1), li, cb_arg(ii, 2), "", -1);
    }
    return -1;
}
// m_AllOnesOrPoison / m_ZeroOrPoison: every element (a splat or each lane) is all-ones/zero or poison
fn icx_m_all_ones_or_poison(v: i32) -> bool { icx_m_elems(v, true) }
fn icx_m_zero_or_poison(v: i32) -> bool { icx_m_elems(v, false) }
fn icx_m_elems(v: i32, ones: bool) -> bool {
    if !is_constant(v) { return false; }
    let t = vals[v].ty;
    let chk = if ones { m_all_ones(v) } else { m_zero_int(v) };
    if chk || vals[v].kind == VK_POISON { return true; }
    if ty_kind(t) != TK_FVEC { return false; }
    for k in ty_count(t) {
        let e = c_aggregate_element(v, k);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT { return false; }
        if ones && !ap_is_all_ones(ci_ap(e)) { return false; }
        if !ones && !ap_is_zero(ci_ap(e)) { return false; }
    }
    return true;
}

// new StoreInst(V, Ptr, false, Alignment) + copyMetadata(II)
fn icx_new_store_md(v: i32, p: i32, al: u64, from: i32) -> i32 {
    let si = create_inst(OP_STORE, T_VOID, [v, p]);
    insts[inst_of(si)].align = icb_align_code(al as i64);
    inst_copy_all_md(si, from);
    return si;
}

// simplifyMaskedStore(II)
fn simplify_masked_store(ii: i32) -> i32 {
    let sp = cb_arg(ii, 1);
    var al = cb_param_align(ii, 1);
    if al == 0 { al = 1; }
    let cm = cb_arg(ii, 2);
    if !is_constant(cm) { return -1; }
    if icx_m_zero_or_poison(cm) { return ic_erase(ii); }
    if icx_m_all_ones_or_poison(cm) { return icx_new_store_md(cb_arg(ii, 0), sp, al, ii); }
    if ty_kind(vals[cm].ty) == TK_SVEC { return -1; }
    let d = possibly_demanded_elts_in_mask(cm);
    let v, pe = ic_simplify_demanded_vector_elts(op(ii, 0), d, 0, false);
    if v >= 0 { return ic_replace_operand(ii, 0, v); }
    return -1;
}
// possiblyDemandedEltsInMask(Mask)
fn possibly_demanded_elts_in_mask(m: i32) -> AP {
    let n = ty_count(vals[m].ty);
    var d = ap_ones(n);
    for k in n {
        let e = c_aggregate_element(m, k);
        if e >= 0 && vals[e].kind == VK_CINT && ap_is_zero(ci_ap(e)) { d = ap_clear_bit(d, k); }
    }
    return d;
}
// maskContainsAllOneOrUndef(Mask)
fn mask_contains_all_one_or_undef(m: i32) -> bool {
    if !is_constant(m) { return false; }
    if m_all_ones(m) || is_undef_or_poison(m) { return true; }
    if ty_kind(vals[m].ty) == TK_SVEC { return false; }
    for k in ty_count(vals[m].ty) {
        let e = c_aggregate_element(m, k);
        if e >= 0 && (is_undef_or_poison(e) || (vals[e].kind == VK_CINT && ap_is_all_ones(ci_ap(e)))) { return true; }
    }
    return false;
}

// simplifyMaskedGather(II)
fn simplify_masked_gather(ii: i32) -> i32 {
    let cm = cb_arg(ii, 1);
    if !is_constant(cm) { return -1; }
    if m_all_ones(cm) {
        let sp = get_splat_value_v(cb_arg(ii, 0));
        if sp >= 0 {
            let vt = vals[ii].ty;
            var al = cb_param_align(ii, 0);
            if al == 0 { al = 1; }
            let l = icb_aligned_load(ty_scalar(vt), sp, al as i64, "load.scalar");
            let sh = icb_vector_splat(vt, l, "broadcast");
            return ic_replace_inst_uses_with(ii, sh);
        }
    }
    return -1;
}

// simplifyMaskedScatter(II)
fn simplify_masked_scatter(ii: i32) -> i32 {
    let cm = cb_arg(ii, 2);
    if !is_constant(cm) { return -1; }
    if icx_m_zero_or_poison(cm) { return ic_erase(ii); }
    let sp = get_splat_value_v(cb_arg(ii, 1));
    if sp >= 0 {
        let sv = get_splat_value_v(cb_arg(ii, 0));
        if sv >= 0 && mask_contains_all_one_or_undef(cm) {
            var al = cb_param_align(ii, 1);
            if al == 0 { al = 1; }
            return icx_new_store_md(sv, sp, al, ii);
        }
        if m_all_ones(cm) {
            var al = cb_param_align(ii, 1);
            if al == 0 { al = 1; }
            let wt = vals[cb_arg(ii, 1)].ty;
            if ty_kind(wt) == TK_SVEC { ic_not_ported("simplifyMaskedScatter of a scalable vector (CreateElementCount)"); }
            let last = c_int(T_I32, ty_count(wt) - 1);
            let ex = icb_extract_element(cb_arg(ii, 0), last, "");
            return icx_new_store_md(ex, sp, al, ii);
        }
    }
    if ty_kind(vals[cm].ty) == TK_SVEC { return -1; }
    let d = possibly_demanded_elts_in_mask(cm);
    let v0, pe0 = ic_simplify_demanded_vector_elts(op(ii, 0), d, 0, false);
    if v0 >= 0 { return ic_replace_operand(ii, 0, v0); }
    let v1, pe1 = ic_simplify_demanded_vector_elts(op(ii, 1), d, 0, false);
    if v1 >= 0 { return ic_replace_operand(ii, 1, v1); }
    return -1;
}

// simplifyInvariantGroupIntrinsic(II, IC)
fn simplify_invariant_group_intrinsic(ii: i32) -> i32 {
    let arg = cb_arg(ii, 0);
    let stripped = strip_ptr_casts(arg);
    var sig = stripped;
    loop {
        let id = inst_iid(sig);
        if id != IID_launder_invariant_group && id != IID_strip_invariant_group { break; }
        sig = strip_ptr_casts(cb_arg(sig, 0));
    }
    if stripped == sig { return -1; }
    let id = call_iid(ii);
    var r = icx_call(icx_decl(id, [vals[sig].ty]), [sig], "");
    if ptr_as(vals[r].ty) != ptr_as(vals[ii].ty) { r = icb_addrspacecast(r, vals[ii].ty, ""); }
    return r;
}

// CallBase::removeOperandBundleAt(CB, Offset): a new unattached call with the other bundles (CallInst::Create(CI, OpB))
fn cb_remove_operand_bundle_at(ci: i32, idx: i64) -> i32 {
    if iop(ci) != OP_CALL { ic_not_ported("removeOperandBundleAt on an invoke/callbr"); }
    let na = cb_nargs(ci);
    var opsv: i32[>..<] = [];
    for k in na { opsv.push(cb_arg(ci, k)); }
    var pairs: i32[>..<] = [];
    for k in cb_nbundles(ci) {
        if k == idx { continue; }
        let b = cb_bundle_begin(ci, k);
        let n = cb_bundle_count(ci, k);
        for j in n { opsv.push(op(ci, b + j)); }
        pairs.push(cb_bundle_tag(ci, k));
        pairs.push(n as i32);
    }
    opsv.push(cb_callee(ci));
    let nc = create_inst(OP_CALL, vals[ci].ty, opsv);
    let ni = inst_of(nc);
    let oi = inst_of(ci);
    insts[ni].ty2 = insts[oi].ty2;
    insts[ni].pred = insts[oi].pred;
    insts[ni].cc = insts[oi].cc;
    insts[ni].fmf = insts[oi].fmf;
    insts[ni].flags = insts[oi].flags;
    insts[ni].attrs = insts[oi].attrs;
    cb_set_bundles(nc, na, pairs, 0);
    let dl = inst_get_md(ci, 0);
    if dl >= 0 { inst_set_md(nc, 0, dl); }
    if vals[ci].name >= 0 { var nm: u8[>..] = []; nm.append(val_name(ci)); set_name(nc, nm); }
    return nc;
}

// IRBuilder::CreateAssumption(True, {Bundle(tag, ops)})
fn icb_assumption_bundle(tag: const u8[:], ops0: const i32[:]) -> i32 {
    let f = icx_decl(IID_assume, []);
    var opsv: i32[>..<] = [];
    opsv.push(c_true());
    for x in ops0 { opsv.push(x); }
    opsv.push(f);
    let ci = create_inst(OP_CALL, T_VOID, opsv);
    insts[inst_of(ci)].ty2 = globs[glob_of(f)].vty;
    let pairs: i32[2] = [intern(tag), ops0.len as i32];
    cb_set_bundles(ci, 1, pairs, 0);
    return icb_insert(ci, "");
}
// IRBuilder::CreateNonnullAssumption(Ptr)
fn icb_nonnull_assumption(p: i32) -> i32 { icb_assumption_bundle("nonnull", [p]) }
// IRBuilder::CreateAlignmentAssumption(DL, Ptr, Alignment, OffsetValue)
fn icb_alignment_assumption(p: i32, al: u64, off: i32) -> i32 {
    let av = c_int(T_I64, al as! i64);
    if off >= 0 { return icb_assumption_bundle("align", [p, av, off]); }
    return icb_assumption_bundle("align", [p, av]);
}

// GEPOperator::getMaxPreservedAlignment(DL)
fn gep_max_preserved_alignment(g: i32) -> u64 {
    var result: u64 = (1 as u64) << 32;
    let n = nops(g);
    var ty = gep_src_ty(g);
    for k in 1..n {
        let idx = op(g, k);
        let opc = if vals[idx].kind == VK_CINT { idx } else { -1 };
        var offset: u64 = 0;
        if k > 1 && ty_is_struct(ty) {
            let fi = (ap_zext64(ap_trunc(ci_ap(opc), min(32, ty_scalar_bits(vals[opc].ty)))) & 0xFFFFFFFF) as i64;
            offset = dl_struct_offset(ty, fi) as u64;
            ty = ty_field(ty, fi);
        } else {
            var stride: i64 = 0;
            if k > 1 { let et = ty_index(ty, 0); stride = dl_gep_stride(ty, et); ty = et; } else { stride = dl_alloc_size(ty); }
            let cnt: u64 = if opc >= 0 { ap_limited(ci_ap(opc), 0xFFFFFFFFFFFFFFFF) } else { 1 };
            offset = (stride as u64) * cnt;
        }
        result = icx_min_align(offset, result);
    }
    return result;
}
// MinAlign(A, B)
fn icx_min_align(a: u64, b: u64) -> u64 { let x = a | b; return x & (~x + 1); }
// commonAlignment(A, Offset)
fn icx_common_alignment(a: u64, off: u64) -> u64 {
    if off == 0 { return a; }
    let lowbit = off & (~off + 1);
    return if lowbit < a { lowbit } else { a };
}
fn gep_pointer_operand(g: i32) -> i32 { op(g, 0) }
fn dl_index_width(pt: i32) -> i64 { dl_ptr(ptr_as(ty_scalar(pt))).idx }

// isGuaranteedNotToBeUndefOrPoison(V, AC, CtxI, DT)
fn is_guaranteed_not_to_be_undef_or_poison_cx(v: i32, cx: i32) -> bool { is_guaranteed_not_to_be_undef_or_poison(v, cx, 0) }

// Value::stripInBoundsOffsets() (stripPointerCastsAndOffsets<PSK_InBounds>)
fn strip_in_bounds_offsets(v0: i32) -> i32 {
    var v = v0;
    if ty_kind(vals[v].ty) != TK_PTR { return v; }
    var visited: i32[>..<] = [];
    visited.push(v);
    loop {
        let o = opcode_of(v);
        if o == OP_GEP {
            if (op_flags(v) & GEP_INBOUNDS) == 0 { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else {
            if is_inst(v) && is_callbase(v) {
                let rv = returned_arg_operand(v);
                if rv >= 0 { v = rv; } else { return v; }
            } else {
                return v;
            }
        }
        for x in visited { if x == v { return v; } }
        visited.push(v);
    }
    return v;
}

// simplifyConstrainedFPCall(Call, Q)
fn simplify_constrained_fp_call(c: i32, mark: i64, n: i64, q: SQ) -> i32 {
    let v = try_constant_fold_call(c, mark, n, q);
    if v >= 0 { return v; }
    return simplify_intrinsic_call(c, mark, n, q);
}

// InstCombiner::targetInstCombineIntrinsic: X86TTIImpl::instCombineIntrinsic for x86 triples (ic_x86.goose).
// Returns (result, handled): handled = the std::optional had a value.
fn target_inst_combine_intrinsic(ii: i32) -> i32, bool {
    let id = call_iid(ii);
    if !intr_is_target_specific(id) { return -1, false; }
    let fv = inst_func(ii);
    let m = globs[glob_of(fv)].module;
    let t = modules[m].triple;
    let ts = if t < 0 { "" } else { sbytes(t) };
    let nm = intr_name(id as i64);
    if ts.len == 0 { return -1, false; }
    if starts_with(ts, "x86_64") || starts_with(ts, "i386") || starts_with(ts, "i686") || starts_with(ts, "i586") ||
       starts_with(ts, "i486") || starts_with(ts, "x86") {
        tti_init_function(fv, m);
        return x86_inst_combine_intrinsic(ii);
    }
    ic_not_ported(str("targetInstCombineIntrinsic for target triple '", ts, "' (", nm, ")"));
    return -1, false;
}

// ---------------------------------------------------------------------------------------------
// visitCallInst (the generic prologue), visitFenceInst, visitInvokeInst, visitCallBrInst

fn visit_call(ci: i32) -> i32 {
    if !use_empty(ci) {
        let mark = is_ops.len;
        let n = nops(ci);
        for k in n { is_ops.push(op(ci, k)); }
        let nb = cb_bundle_ops(ci);
        let v = simplify_call(ci, is_ops[mark + n - 1], mark, n - 1 - nb, sq_at(ci));
        is_ops.resize(mark);
        if v >= 0 { return ic_replace_inst_uses_with(ci, v); }
    }
    let freed = get_freed_operand(ci);
    if freed >= 0 { return visit_free(ci, freed); }
    let fv = inst_func(ci);
    if func_has_fn_attr(fv, AK_NoUnwind) && !call_has_fn_attr(ci, AK_NoUnwind) {
        ic_call_set_does_not_throw(ci);
        return ci;
    }
    let iid = call_iid(ci);
    if iid == 0 { return visit_call_base(ci); }
    return visit_intrinsic(ci);
}

// visitFenceInst(FI)
fn visit_fence(fi: i32) -> i32 {
    let nx = inst_next(fi);
    let nfi = if nx >= 0 && iop(nx) == OP_FENCE { nx } else { -1 };
    if nfi >= 0 && insts[inst_of(fi)].ord == insts[inst_of(nfi)].ord && insts[inst_of(fi)].ss == insts[inst_of(nfi)].ss &&
       fence_same_md_free(fi, nfi) { return ic_erase(fi); }
    if nfi >= 0 && fence_identical_or_stronger(nfi, fi) { return ic_erase(fi); }
    let pv = inst_prev(fi);
    if pv >= 0 && iop(pv) == OP_FENCE && fence_identical_or_stronger(pv, fi) { return ic_erase(fi); }
    return -1;
}
// Instruction::isIdenticalTo for two fences: opcode, ordering, sync scope, and the SubclassOptionalData (none)
fn fence_same_md_free(a: i32, b: i32) -> bool { true }
// isIdenticalOrStrongerFence(FI1, FI2)
fn fence_identical_or_stronger(a: i32, b: i32) -> bool {
    let s1 = insts[inst_of(a)].ss;
    if s1 != insts[inst_of(b)].ss || (s1 != -1 && !(s1 >= 0 && sbytes(s1) == "singlethread")) { return false; }
    return ao_at_least_or_stronger(insts[inst_of(a)].ord as i64, insts[inst_of(b)].ord as i64);
}

fn visit_invoke(ii: i32) -> i32 { visit_call_base(ii) }
fn visit_callbr(ii: i32) -> i32 { visit_call_base(ii) }

// TargetLibraryInfoImpl::isCallingConvCCompatible(CC, TT, FuncTy)
fn is_calling_conv_c_compatible(cc: i64, fty: i32, fv: i32) -> bool {
    if cc == 0 { return true; }
    if cc == 66 || cc == 67 || cc == 68 {
        let m = globs[glob_of(fv)].module;
        let t = modules[m].triple;
        if t >= 0 && (contains(sbytes(t), "-ios") || contains(sbytes(t), "-unknown-ios")) { ic_not_ported("isCallingConvCCompatible on iOS triples"); }
        let rt = ty_fn_ret(fty);
        if ty_kind(rt) != TK_PTR && !ty_is_int(rt) && rt != T_VOID { return false; }
        for k in ty_fn_nparams(fty) {
            let p = ty_fn_param(fty, k);
            if ty_kind(p) != TK_PTR && !ty_is_int(p) { return false; }
        }
        return true;
    }
    return false;
}

// visitCallBase(Call)
fn visit_call_base(ci: i32) -> i32 {
    var changed = ic_annotate_any_alloc_site(ci);
    let nargs = cb_nargs(ci);
    var argnos: i64[>..<] = [];
    for k in nargs {
        let v = cb_arg(ci, k);
        if ty_kind(vals[v].ty) == TK_PTR {
            let deref = aset_int(alist_param(insts[inst_of(ci)].attrs, k), AK_Dereferenceable) > 0;
            if cb_param_has_attr(ci, k, AK_NonNull) || (deref && !null_pointer_is_defined(inst_func(ci), ptr_as(vals[v].ty))) {
                let res = ic_simplify_non_null_operand(v, deref, 0);
                if res >= 0 { ic_replace_operand(ci, k, res); changed = true; }
            } else {
                kb_cxt = ci;
                if is_known_non_zero(v, 0) { argnos.push(k); }
            }
        }
    }
    if argnos.len > 0 {
        for k in argnos { ic_call_add_param_attr(ci, k, attr_enum(AK_NonNull)); }
        changed = true;
    }
    let callee = cb_callee(ci);
    let calleef = if is_func(callee) { callee } else { -1 };
    if (calleef < 0 || globs[glob_of(calleef)].vty != insts[inst_of(ci)].ty2) && transform_const_expr_cast_call(ci) { return -1; }
    if calleef >= 0 {
        if call_is_convergent(ci) && !func_has_fn_attr(calleef, AK_Convergent) && globs[glob_of(calleef)].intrinsic == 0 {
            call_set_not_convergent(ci);
            return ci;
        }
        let fcc = globs[glob_of(calleef)].cc as i64;
        let ccc = insts[inst_of(ci)].cc as i64;
        if fcc != ccc && !(fcc == 0 && is_calling_conv_c_compatible(ccc, insts[inst_of(ci)].ty2, inst_func(ci))) &&
           !(ccc == 0 && is_calling_conv_c_compatible(fcc, globs[glob_of(calleef)].vty, calleef)) && !func_is_decl(calleef) {
            ic_create_non_terminator_unreachable(ci);
            if vals[ci].ty != T_VOID { ic_replace_inst_uses_with(ci, c_poison(vals[ci].ty)); }
            if iop(ci) == OP_CALL { return ic_erase(ci); }
            set_op(ci, nops(ci) - 1, c_null(vals[calleef].ty));
            insts[inst_of(ci)].ty2 = globs[glob_of(calleef)].vty;
            return -1;
        }
    }
    if (vals[callee].kind == VK_CNULL && !null_pointer_is_defined(inst_func(ci), 0)) || vals[callee].kind == VK_UNDEF || vals[callee].kind == VK_POISON {
        if vals[ci].ty != T_VOID { ic_replace_inst_uses_with(ci, c_poison(vals[ci].ty)); }
        if is_terminator(ci) { return -1; }
        ic_create_non_terminator_unreachable(ci);
        return ic_erase(ci);
    }
    if find_init_trampoline(callee) >= 0 { ic_not_ported("transformCallThroughTrampoline"); }
    if is_inst_op(callee, OP_INTTOPTR) && inst_iid(op(callee, 0)) != 0 {
        let pid = inst_iid(op(callee, 0));
        if pid == IID_ptrauth_resign || pid == IID_ptrauth_sign { ic_not_ported("foldPtrAuthIntrinsicCallee"); }
    }
    if vals[callee].kind == VK_PTRAUTH && cb_has_bundle_tag(ci, "ptrauth") { ic_not_ported("foldPtrAuthConstantCallee"); }
    if vals[callee].kind == VK_INLINEASM && !call_has_fn_attr(ci, AK_NoUnwind) {
        if asms[vals[callee].sub].unwind == 0 { ic_call_set_does_not_throw(ci); changed = true; }
    }
    if iop(ci) == OP_CALL {
        let i = try_optimize_call(ci);
        if i >= 0 { return ic_erase(i); }
    }
    if !use_empty(ci) && !call_is_musttail(ci) {
        let ra = returned_arg_operand(ci);
        if ra >= 0 {
            let ct = vals[ci].ty;
            if ty_can_losslessly_bitcast_to(vals[ra].ty, ct) {
                return ic_replace_inst_uses_with(ci, icb_bit_or_pointer_cast(ra, ct, ""));
            }
        }
    }
    let indirect = cb_is_indirect_call(ci);
    let kct = md_kind_id("callee_type");
    if inst_get_md(ci, kct) >= 0 && !indirect { inst_erase_md(ci, kct); changed = true; }
    for k in cb_nbundles(ci) {
        if sbytes(cb_bundle_tag(ci, k)) == "kcfi" && !indirect { return cb_remove_operand_bundle_at(ci, k); }
    }
    if is_removable_alloc(ci) { return visit_alloc_site(ci); }
    if call_iid(ci) == IID_experimental_gc_statepoint {
        // getGCRelocates: gc.relocate users (and those of the landingpad for invokes)
        var u = vals[ci].first_use;
        while u >= 0 {
            if inst_iid(uses[u].user) == IID_experimental_gc_relocate { ic_not_ported("gc.statepoint relocate folding"); }
            u = uses[u].next;
        }
        if iop(ci) == OP_INVOKE { ic_not_ported("gc.statepoint invokes"); }
        for k in cb_nbundles(ci) {
            if sbytes(cb_bundle_tag(ci, k)) == "gc-live" && cb_bundle_count(ci, k) != 0 { ic_not_ported("gc-live bundle shrinking"); }
        }
    }
    return if changed { ci } else { -1 };
}

// CallBase::isIndirectCall
fn cb_is_indirect_call(ci: i32) -> bool {
    let v = cb_callee(ci);
    if is_func(v) || vals[v].kind == VK_INLINEASM { return false; }
    if is_constant(v) && vals[v].kind != VK_CEXPR { return false; }
    return true;
}
fn call_is_musttail(ci: i32) -> bool { iop(ci) == OP_CALL && insts[inst_of(ci)].pred == 2 }
fn call_is_notail(ci: i32) -> bool { iop(ci) == OP_CALL && insts[inst_of(ci)].pred == 3 }
fn call_is_convergent(ci: i32) -> bool { call_has_fn_attr(ci, AK_Convergent) }
// CallBase::setNotConvergent: remove the call site's convergent function attribute
fn call_set_not_convergent(ci: i32) {
    let ii = inst_of(ci);
    let l = insts[ii].attrs;
    let n = if l == 0 { 0 } else { alists[l].n as i64 };
    var sets: i32[>..<] = [];
    for j in n {
        var s = alist_runs[alists[l].at + j];
        if j == 0 { s = aset_without(s, AK_Convergent); }
        sets.push(s);
    }
    insts[ii].attrs = alist_get(sets);
}
// Type::canLosslesslyBitCastTo
fn ty_can_losslessly_bitcast_to(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if !ty_is_first_class(a) || !ty_is_first_class(b) { return false; }
    if ty_is_vector(a) && ty_is_vector(b) { return dl_prim_size_bits(a) == dl_prim_size_bits(b); }
    if ty_kind(a) == TK_PTR && ty_kind(b) == TK_PTR { return ptr_as(a) == ptr_as(b); }
    return false;
}
// Type::getPrimitiveSizeInBits for vectors: count * element bits
fn dl_prim_size_bits(t: i32) -> i64 { if ty_is_vector(t) { ty_count(t) * ty_prim_bits_any(ty_scalar(t)) } else { ty_prim_bits_any(t) } }
fn ty_prim_bits_any(t: i32) -> i64 { if ty_is_int(t) { ty_bits(t) } else if ty_is_fp(t) { ty_prim_bits(t) } else { 0 } }

// findInitTrampoline(Callee)
fn find_init_trampoline(callee0: i32) -> i32 {
    let callee = strip_ptr_casts(callee0);
    if inst_iid(callee) != IID_adjust_trampoline { return -1; }
    let mem = op(callee, 0);
    let a = find_init_trampoline_from_alloca(mem);
    if a >= 0 { return a; }
    return find_init_trampoline_from_bb(callee, mem);
}
fn find_init_trampoline_from_alloca(mem: i32) -> i32 {
    let und = strip_ptr_casts(mem);
    if und != mem && (!has_one_use(und) || uses[vals[und].first_use].user != mem) { return -1; }
    if !is_inst_op(und, OP_ALLOCA) { return -1; }
    var init: i32 = -1;
    var u = vals[mem].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        let id = inst_iid(us);
        if id == 0 { return -1; }
        if id == IID_init_trampoline { if init >= 0 { return -1; } init = us; continue; }
        if id == IID_adjust_trampoline { continue; }
        return -1;
    }
    if init < 0 { return -1; }
    if op(init, 0) != mem { return -1; }
    return init;
}
fn find_init_trampoline_from_bb(adj: i32, mem: i32) -> i32 {
    var x = inst_prev(adj);
    while x >= 0 {
        if inst_iid(x) == IID_init_trampoline && op(x, 0) == mem { return x; }
        if inst_may_write_memory(x) { return -1; }
        x = inst_prev(x);
    }
    return -1;
}

// tryOptimizeCall(CI)
fn try_optimize_call(ci: i32) -> i32 {
    if called_function(ci) < 0 { return -1; }
    if call_is_musttail(ci) || call_is_notail(ci) { return -1; }
    let w = lcs_optimize_call(ci);
    if w >= 0 { return if use_empty(ci) { ci } else { ic_replace_inst_uses_with(ci, w) }; }
    if call_has_fn_str_attr(ci, "modular-format") { ic_not_ported("optimizeModularFormat (modular-format calls)"); }
    return -1;
}

// isAtLeastOrStrongerThan(AO, Other)
fn ao_at_least_or_stronger(a: i64, b: i64) -> bool {
    let t: const u8[:] = "1000000011000000111000001111000011111000111001001111111011111111";
    return t[a * 8 + b] == '1';
}

// AttributeFuncs::typeIncompatible(Ty, AS, ASK): does attribute kind `kind` (in set s) belong to the mask?
// ask: 1 = ASK_SAFE_TO_DROP, 2 = ASK_UNSAFE_TO_DROP, 3 = both
fn attr_type_incompatible(ty: i32, s: i32, kind: i64, ask: i64) -> bool {
    let safe = (ask & 1) != 0;
    let unsafe_ = (ask & 2) != 0;
    if !ty_is_int(ty) && safe && kind == AK_AllocAlign { return true; }
    if !ty_is_int(ty) && ty_kind(ty) != TK_BYTE && unsafe_ && (kind == AK_SExt || kind == AK_ZExt) { return true; }
    if !is_int_or_int_vec(ty) {
        if safe && kind == AK_Range { return true; }
    } else if kind == AK_Range {
        let has, cr = rg_from_range_attr(s);
        if has && rg_w(cr) != ty_scalar_bits(ty) { return true; }
    }
    if ty_kind(ty) != TK_PTR {
        if safe && (kind == AK_NoAlias || kind == AK_NonNull || kind == AK_ReadNone || kind == AK_ReadOnly ||
            kind == AK_Dereferenceable || kind == AK_DereferenceableOrNull || kind == AK_Writable || kind == AK_DeadOnUnwind ||
            kind == AK_Initializes || kind == AK_Captures || kind == AK_DeadOnReturn) { return true; }
        if unsafe_ && (kind == AK_Nest || kind == AK_SwiftError || kind == AK_Preallocated || kind == AK_InAlloca ||
            kind == AK_ByVal || kind == AK_StructRet || kind == AK_ByRef || kind == AK_ElementType || kind == AK_AllocatedPointer) { return true; }
    }
    if !is_ptr_or_ptr_vec(ty) && safe && kind == AK_Alignment { return true; }
    if safe && !nofpclass_compatible_type(ty) && kind == AK_NoFPClass { return true; }
    if ty == T_VOID && safe && kind == AK_NoUndef { return true; }
    return false;
}
// AttrBuilder(S).overlaps(typeIncompatible(Ty, S, ASK))
fn aset_overlaps_incompatible(ty: i32, s: i32, ask: i64) -> bool {
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].skey >= 0 { continue; }
        if attr_type_incompatible(ty, s, attrs[a].kind as i64, ask) { return true; }
    }
    return false;
}
// S.removeAttributes(typeIncompatible(Ty, S, ASK))
fn aset_remove_incompatible(ty: i32, s: i32, ask: i64) -> i32 {
    var xs: i32[>..<] = [];
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].skey < 0 && attr_type_incompatible(ty, s, attrs[a].kind as i64, ask) { continue; }
        xs.push(a);
    }
    return aset_get(xs);
}
fn alist_has_attr_somewhere(l: i32, kind: i64) -> i64 {
    if l == 0 { return -1; }
    for j in alists[l].n as i64 { if aset_has(alist_runs[alists[l].at + j], kind) { return j; } }
    return -1;
}

// getPromotedType(Ty)
fn get_promoted_type(t: i32) -> i32 { if ty_is_int(t) && ty_bits(t) < 32 { T_I32 } else { t } }

// CastInst::getCastOpcode(V, SrcIsSigned = false, DestTy, DstIsSigned = false) for the vararg promotions (integers)
fn cast_opcode_unsigned(v: i32, dt: i32) -> i64 {
    let st = vals[v].ty;
    if ty_is_int(st) && ty_is_int(dt) {
        if ty_bits(dt) < ty_bits(st) { return OP_TRUNC; }
        if ty_bits(dt) > ty_bits(st) { return OP_ZEXT; }
        return OP_BITCAST;
    }
    ic_not_ported("CastInst::getCastOpcode for non-integer vararg promotion");
    return OP_BITCAST;
}

// transformConstExprCastCall(Call)
fn transform_const_expr_cast_call(ci: i32) -> bool {
    let callee = strip_ptr_casts(cb_callee(ci));
    if !is_func(callee) { return false; }
    if func_is_decl(callee) { return false; }
    if aset_find_str(alist_fn(func_attrs(callee)), "thunk") >= 0 { return false; }
    if func_has_fn_attr(callee, AK_Naked) { return false; }
    if call_is_musttail(ci) { return false; }
    if iop(ci) == OP_CALLBR { fatal("internal: transformConstExprCastCall on a callbr"); }
    let pal = insts[inst_of(ci)].attrs;
    let ft = globs[glob_of(callee)].vty;
    let oldrt = vals[ci].ty;
    let newrt = ty_fn_ret(ft);
    if oldrt != newrt {
        if ty_is_struct(newrt) { return false; }
        if !ld_is_bit_or_noop_ptr_castable(newrt, oldrt) {
            if !use_empty(ci) { return false; }
        }
        if pal != 0 && !use_empty(ci) {
            if aset_overlaps_incompatible(newrt, alist_ret(pal), 3) { return false; }
        }
        if !use_empty(ci) && iop(ci) == OP_INVOKE {
            let nd = invoke_normal_dest(ci);
            var u = vals[ci].first_use;
            while u >= 0 {
                let us = uses[u].user;
                if is_phi_inst(us) && inst_parent(us) == nd { return false; }
                u = uses[u].next;
            }
        }
    }
    let nact = cb_nargs(ci);
    let np = ty_fn_nparams(ft);
    let ncommon = min(np, nact);
    let cpal = globs[glob_of(callee)].attrs;
    if alist_has_attr_somewhere(cpal, AK_InAlloca) >= 0 || alist_has_attr_somewhere(cpal, AK_Preallocated) >= 0 { return false; }
    for i in ncommon {
        let pt = ty_fn_param(ft, i);
        let at = vals[cb_arg(ci, i)].ty;
        if !ld_is_bit_or_noop_ptr_castable(at, pt) { return false; }
        if aset_overlaps_incompatible(pt, alist_param(pal, i), 2) { return false; }
        if aset_has(alist_param(pal, i), AK_InAlloca) || aset_has(alist_param(pal, i), AK_Preallocated) { return false; }
        if aset_has(alist_param(pal, i), AK_SwiftError) { return false; }
        if aset_has(alist_param(pal, i), AK_ByVal) != aset_has(alist_param(cpal, i), AK_ByVal) { return false; }
    }
    if np < nact && ty_fn_vararg(ft) && pal != 0 {
        let sri = alist_has_attr_somewhere(pal, AK_StructRet);
        if sri >= 0 && sri - 2 >= np { return false; }
    }
    var newargs: i32[>..<] = [];
    var argattrs: i32[>..<] = [];
    let rattrs = aset_remove_incompatible(newrt, alist_ret(pal), 3);
    for i in ncommon {
        let pt = ty_fn_param(ft, i);
        var na = cb_arg(ci, i);
        if vals[na].ty != pt { na = icb_bit_or_pointer_cast(na, pt, ""); }
        newargs.push(na);
        argattrs.push(aset_remove_incompatible(pt, alist_param(pal, i), 1));
    }
    for i in ncommon..np {
        newargs.push(c_null(ty_fn_param(ft, i)));
        argattrs.push(0);
    }
    if np < nact && ty_fn_vararg(ft) {
        for i in np..nact {
            let a = cb_arg(ci, i);
            let pty = get_promoted_type(vals[a].ty);
            var na = a;
            if pty != vals[a].ty { na = icb_cast(cast_opcode_unsigned(a, pty), a, pty, ""); }
            newargs.push(na);
            argattrs.push(alist_param(pal, i));
        }
    }
    if newrt == T_VOID && vals[ci].name >= 0 { set_name(ci, ""); }
    var sets: i32[>..<] = [];
    sets.push(alist_fn(pal));
    sets.push(rattrs);
    for s in argattrs { sets.push(s); }
    let npal = alist_get(sets);
    // the operand bundles
    var bops: i32[>..<] = [];
    var pairs: i32[>..<] = [];
    for k in cb_nbundles(ci) {
        let b = cb_bundle_begin(ci, k);
        let n = cb_bundle_count(ci, k);
        for j in n { bops.push(op(ci, b + j)); }
        pairs.push(cb_bundle_tag(ci, k));
        pairs.push(n as i32);
    }
    var opsv: i32[>..<] = [];
    for a in newargs { opsv.push(a); }
    for b in bops { opsv.push(b); }
    var nc: i32 = -1;
    if iop(ci) == OP_INVOKE {
        opsv.push(invoke_normal_dest(ci));
        opsv.push(invoke_unwind_dest(ci));
        opsv.push(callee);
        nc = create_inst(OP_INVOKE, newrt, opsv);
    } else {
        opsv.push(callee);
        nc = create_inst(OP_CALL, newrt, opsv);
        insts[inst_of(nc)].pred = insts[inst_of(ci)].pred;
    }
    insts[inst_of(nc)].ty2 = ft;
    cb_set_bundles(nc, newargs.len, pairs, 0);
    if is_fp_math_operator(nc) { insts[inst_of(nc)].fmf = icb_fmf; }
    icb_insert(nc, "");
    ic_take_name(nc, ci);
    insts[inst_of(nc)].cc = insts[inst_of(ci)].cc;
    insts[inst_of(nc)].attrs = npal;
    let kp = md_kind_id("prof");
    let pm = inst_get_md(ci, kp);
    if pm >= 0 { inst_set_md(nc, kp, pm); }
    var nv = nc;
    if oldrt != vals[nc].ty && !use_empty(ci) {
        let cst = create_inst(ld_bit_or_pointer_cast_opcode(vals[nc].ty, oldrt), oldrt, [nc]);
        let dl = inst_get_md(ci, 0);
        if dl >= 0 { inst_set_md(cst, 0, dl); }
        // getInsertionPointAfterDef
        var pos: i32 = -1;
        if iop(nc) == OP_INVOKE { pos = first_insertion_pt(invoke_normal_dest(nc)); } else { pos = inst_next(nc); }
        ic_insert_new_before(cst, pos);
        icw_push_users(ci);
        nv = cst;
    }
    if !use_empty(ci) { ic_replace_inst_uses_with(ci, nv); }
    ic_erase(ci);
    return true;
}
// CastInst::CreateBitOrPointerCast opcode
fn ld_bit_or_pointer_cast_opcode(st: i32, dt: i32) -> i64 {
    if ty_kind(ty_scalar(st)) == TK_PTR && ty_is_int(ty_scalar(dt)) { return OP_PTRTOINT; }
    if ty_is_int(ty_scalar(st)) && ty_kind(ty_scalar(dt)) == TK_PTR { return OP_INTTOPTR; }
    return OP_BITCAST;
}

// LibCallSimplifier::optimizeCall(CI, Builder) (simplify_libcalls.goose): -1 = nullptr
fn lcs_optimize_call(ci: i32) -> i32 {
    let f = called_function(ci);
    if ic_maybe_libcall(f) { ic_not_ported("LibCallSimplifier (tryOptimizeCall)"); }
    let id = call_iid(ci);
    if id == IID_pow || id == IID_exp2 || id == IID_log || id == IID_log2 || id == IID_log10 || id == IID_sqrt ||
       id == IID_memset || id == IID_memcpy || id == IID_memmove || id == IID_sin || id == IID_cos {
        ic_not_ported("LibCallSimplifier (intrinsics)");
    }
    return -1;
}

// isModSet(AA->getModRefInfoMask(MI->getDest()))
fn icx_mod_set_dest(mi: i32) -> bool {
    ic_aa_ensure();
    return mr_is_mod(aa_mod_ref_mask_simple(ml_before_or_after(strip_ptr_casts(cb_arg(mi, 0))), false));
}
