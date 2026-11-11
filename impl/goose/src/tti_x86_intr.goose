// The X86 cost model, part 3: intrinsic costs. Ports
//   llvm/lib/Target/X86/X86TargetTransformInfo.cpp  (getIntrinsicInstrCost and its tables)
//   llvm/include/llvm/CodeGen/BasicTTIImpl.h        (getIntrinsicInstrCost, getTypeBasedIntrinsicInstrCost)
//   llvm/include/llvm/Analysis/TargetTransformInfoImpl.h (TargetTransformInfoImplBase::getIntrinsicInstrCost)
//   llvm/lib/Analysis/TargetTransformInfo.cpp       (IntrinsicCostAttributes)
//
// IntrinsicCostAttributes live in a global table (ica_tab, with their argument values and types in ica_vals /
// ica_tys) because these functions are mutually recursive; ica_mark/ica_release bracket the temporary ones.
// VP intrinsics are not ported (fail loudly).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import gen_x86target;
import gen_x86costs;
import x86_lower;
import tti_x86;
import tti_x86_vec;
import intrinsics;
import datalayout;
import apint;
import pm;

struct Ica {
    id: i32,
    ret: i32,
    fmf: u8,
    inst: i32,       // the IntrinsicInst or -1
    scost: i64,      // ScalarizationCost (TTI_INVALID: not given)
    args: i32,       // run in ica_vals (nargs = 0: type-based only)
    nargs: i32,
    tys: i32,        // run in ica_tys
    ntys: i32,
}
var ica_tab: Ica[>..<] = [];
var ica_vals: i32[>..<] = [];
var ica_tys: i32[>..<] = [];

fn ica_mark() -> i64 { ica_tab.len }
fn ica_release(m: i64) {
    if m >= ica_tab.len { return; }
    let a = ica_tab[m].args;
    let t = ica_tab[m].tys;
    ica_tab.resize(m, Ica { id: 0, ret: 0, fmf: 0, inst: -1, scost: 0, args: 0, nargs: 0, tys: 0, ntys: 0 });
    ica_vals.resize(a as i64, 0);
    ica_tys.resize(t as i64, 0);
}
fn ica_new(id: i64, ret: i32, fmf: u8, inst: i32, scost: i64) -> i64 {
    ica_tab.push(Ica { id: id as i32, ret: ret, fmf: fmf, inst: inst, scost: scost, args: ica_vals.len as i32, nargs: 0,
                       tys: ica_tys.len as i32, ntys: 0 });
    return ica_tab.len - 1;
}
// arguments and types must be added right after ica_new (runs are contiguous)
fn ica_add_arg(ic: i64, v: i32) { ica_vals.push(v); ica_tab[ic].nargs += 1; }
fn ica_add_type(ic: i64, t: i32) { ica_tys.push(t); ica_tab[ic].ntys += 1; }
fn ica_arg(ic: i64, k: i64) -> i32 { ica_vals[ica_tab[ic].args as i64 + k] }
fn ica_ty(ic: i64, k: i64) -> i32 { ica_tys[ica_tab[ic].tys as i64 + k] }
fn ica_type_based(ic: i64) -> bool { ica_tab[ic].nargs == 0 }
fn ica_skip_scalarization(ic: i64) -> bool { tc_valid(ica_tab[ic].scost) }
// a copy with other (id, return type, types, scalarization cost), no arguments
fn ica_types_only(id: i32, ret: i32, src: i64, fmf: u8, inst: i32, scost: i64) -> i64 {
    let ic = ica_new(id, ret, fmf, inst, scost);
    for k in ica_tab[src].ntys { ica_add_type(ic, ica_ty(src, k as i64)); }
    return ic;
}

// IntrinsicCostAttributes(Id, CallBase, ScalarizationCost = Invalid, TypeBasedOnly)
fn ica_from_call(c: i32, type_based_only: bool) -> i64 {
    let ic = ica_new(inst_iid(c), vals[c].ty, inst_fmf(c), c, TTI_INVALID);
    if !type_based_only { for k in cb_nargs(c) { ica_add_arg(ic, cb_arg(c, k)); } }
    let f = called_function(c);
    let ft = func_type(f);
    for k in ty_fn_nparams(ft) { ica_add_type(ic, ty_fn_param(ft, k)); }
    return ic;
}

// isVectorizedTy / getContainedTypes / getVectorizedTypeVF
fn tt_is_vectorized_ty(t: i32) -> bool {
    if ty_is_vector(t) { return true; }
    if ty_is_struct(t) && ty_count(t) > 0 {
        let e0 = ty_field(t, 0);
        if !ty_is_vector(e0) { return false; }
        for k in ty_count(t) {
            let e = ty_field(t, k);
            if !ty_is_vector(e) || ty_count(e) != ty_count(e0) || ty_kind(e) != ty_kind(e0) { return false; }
        }
        return true;
    }
    return false;
}
fn tt_vectorized_vf(t: i32) -> i64 { if ty_is_vector(t) { ty_count(t) } else { ty_count(ty_field(t, 0)) } }
fn tt_ncontained(t: i32) -> i64 { if ty_is_struct(t) { ty_count(t) } else { 1 } }
fn tt_contained(t: i32, k: i64) -> i32 { if ty_is_struct(t) { ty_field(t, k) } else { t } }
// toScalarizedTy
fn tt_to_scalarized(t: i32) -> i32 {
    if ty_is_vector(t) { return ty_elem(t); }
    if ty_is_struct(t) {
        let at = ints.len as i32;
        for k in ty_count(t) { ints.push(ty_elem(ty_field(t, k))); }
        return ty_struct_run(at, ty_count(t), false);
    }
    return t;
}
fn tt_struct2(a: i32, b: i32) -> i32 {
    let at = ints.len as i32;
    ints.push(a);
    ints.push(b);
    return ty_struct_run(at, 2, false);
}
// CallBase::getParamAlign(k).valueOrOne()
fn tt_param_align(c: i32, k: i64) -> i64 {
    var a = aset_int_tti(alist_param(insts[inst_of(c)].attrs, k), AK_Alignment);
    if a == 0 {
        let f = called_function(c);
        if f >= 0 { a = aset_int_tti(alist_param(globs[glob_of(f)].attrs, k), AK_Alignment); }
    }
    return if a == 0 { 1 } else { a as i64 };
}
fn aset_int_tti(s: i32, kind: i64) -> u64 { let a = aset_find(s, kind); if a < 0 { 0 } else { attrs[a].i1 } }

// TargetTransformInfoImplBase::getIntrinsicInstrCost
fn base_intrinsic_cost(id: i32, rt: i32) -> i64 {
    let zero: const i32[] = [IID_allow_runtime_check, IID_allow_ubsan_check, IID_annotation, IID_assume,
        IID_sideeffect, IID_pseudoprobe, IID_arithmetic_fence, IID_dbg_assign, IID_dbg_declare, IID_dbg_value,
        IID_dbg_label, IID_invariant_start, IID_invariant_end, IID_launder_invariant_group,
        IID_strip_invariant_group, IID_is_constant, IID_lifetime_start, IID_lifetime_end,
        IID_experimental_noalias_scope_decl, IID_objectsize, IID_ptr_annotation, IID_var_annotation,
        IID_experimental_gc_result, IID_experimental_gc_relocate, IID_coro_alloc, IID_coro_begin,
        IID_coro_begin_custom_abi, IID_coro_dead, IID_coro_id, IID_coro_id_async, IID_coro_id_retcon,
        IID_coro_id_retcon_once, IID_coro_noop, IID_coro_free, IID_coro_end, IID_coro_frame, IID_coro_size,
        IID_coro_align, IID_coro_suspend, IID_coro_subfn_addr, IID_threadlocal_address,
        IID_experimental_widenable_condition, IID_ssa_copy];
    for z in zero { if z == id { return 0; } }
    if id == IID_bswap && !ty_is_vector(rt) {
        let b = dl_size_bits(rt);
        if b <= 0 || (b & (b - 1)) != 0 { return TTI_INVALID; }
    }
    return 1;
}

fn tt_is_target_intrinsic(id: i32) -> bool { id > IID_xray_typedevent }
fn tt_is_vp_intrinsic(id: i32) -> bool {
    if id <= 0 || tt_is_target_intrinsic(id) { return false; }
    let n = intr_name(id as i64);
    return starts_with(n, "llvm.vp.") || starts_with(n, "llvm.experimental.vp.");
}

// ---------------------------------------------------------------- X86TTIImpl::getIntrinsicInstrCost

recursive fn x86_intrinsic_cost(ic: i64, kind: i64) -> i64 {
    let rt = ica_tab[ic].ret;
    var opty = rt;
    let id = ica_tab[ic].id;
    var isd = XISD_DELETED_NODE;
    if id == IID_abs { isd = XISD_ABS; }
    else if id == IID_bitreverse { isd = XISD_BITREVERSE; }
    else if id == IID_bswap { isd = XISD_BSWAP; }
    else if id == IID_ctlz { isd = XISD_CTLZ; }
    else if id == IID_ctpop { isd = XISD_CTPOP; }
    else if id == IID_cttz { isd = XISD_CTTZ; }
    else if id == IID_fshl || id == IID_fshr {
        isd = XISD_FSHL;
        if !ica_type_based(ic) && ica_arg(ic, 0) == ica_arg(ic, 1) {
            isd = if id == IID_fshl { XISD_ROTL } else { XISD_ROTR };
            let a = ica_arg(ic, 2);
            if a >= 0 && tt_match_apint_allow_poison(a) { isd = XISD_X86_VROTLI; }
        }
    }
    else if id == IID_lrint || id == IID_llrint {
        return x86_cast_cost(OP_FPTOSI, rt, ica_ty(ic, 0), 0, kind, -1);
    }
    else if id == IID_maxnum || id == IID_minnum { isd = XISD_FMAXNUM; }
    else if id == IID_sadd_sat { isd = XISD_SADDSAT; }
    else if id == IID_smax { isd = XISD_SMAX; }
    else if id == IID_smin { isd = XISD_SMIN; }
    else if id == IID_ssub_sat { isd = XISD_SSUBSAT; }
    else if id == IID_uadd_sat { isd = XISD_UADDSAT; }
    else if id == IID_umax { isd = XISD_UMAX; }
    else if id == IID_umin { isd = XISD_UMIN; }
    else if id == IID_usub_sat { isd = XISD_USUBSAT; }
    else if id == IID_sqrt { isd = XISD_FSQRT; }
    else if id == IID_sadd_with_overflow || id == IID_ssub_with_overflow { isd = XISD_SADDO; opty = ty_field(rt, 0); }
    else if id == IID_uadd_with_overflow || id == IID_usub_with_overflow { isd = XISD_UADDO; opty = ty_field(rt, 0); }
    else if id == IID_smul_with_overflow { isd = XISD_SMULO; opty = ty_field(rt, 0); }
    else if id == IID_umul_with_overflow { isd = XISD_UMULO; opty = ty_field(rt, 0); }
    if isd != XISD_DELETED_NODE {
        let ltc, mty = x86_legalize(opty);
        if ((isd == XISD_CTTZ && !xst_hasBMI()) || (isd == XISD_CTLZ && !xst_hasLZCNT())) && !mvt_is_vec(mty) &&
           !ica_type_based(ic) {
            let c = ica_arg(ic, 1);
            if vals[c].kind == VK_CINT && ap_is_all_ones(ci_ap(c)) {
                isd = if isd == XISD_CTTZ { XISD_CTTZ_ZERO_POISON } else { XISD_CTLZ_ZERO_POISON };
            }
        }
        if isd == XISD_FSQRT && kind == TCK_CODE_SIZE { return ltc; }
        let tabs: i32[25] = [XCT_I_GLMCostTbl, XCT_I_SLMCostTbl, XCT_I_AVX512VBMI2CostTbl, XCT_I_AVX512BITALGCostTbl,
            XCT_I_AVX512VPOPCNTDQCostTbl, XCT_I_GFNICostTbl, XCT_I_AVX512CDCostTbl, XCT_I_AVX512BWCostTbl,
            XCT_I_AVX512CostTbl, XCT_I_XOPCostTbl, XCT_I_AVX2CostTbl, XCT_I_AVX1CostTbl, XCT_I_SSE42CostTbl,
            XCT_I_SSE41CostTbl, XCT_I_SSSE3CostTbl, XCT_I_SSE2CostTbl, XCT_I_SSE1CostTbl, XCT_I_BMI64CostTbl,
            XCT_I_BMI32CostTbl, XCT_I_LZCNT64CostTbl, XCT_I_LZCNT32CostTbl, XCT_I_POPCNT64CostTbl,
            XCT_I_POPCNT32CostTbl, XCT_I_X64CostTbl, XCT_I_X86CostTbl];
        let bmi = xst_hasBMI();
        let lzc = xst_hasLZCNT();
        let pop = xst_hasPOPCNT();
        let is64 = x86_is64();
        let on: bool[25] = [x86_glm_divsqrt(), x86_slm_arith(), xst_hasVBMI2(), xst_hasBITALG(), xst_hasVPOPCNTDQ(),
            xst_hasGFNI(), xst_hasCDI(), x86_bwi(), x86_avx512(), x86_xop(), x86_avx2(), x86_avx(), x86_sse42(),
            x86_sse41(), x86_ssse3(), x86_sse2(), x86_sse1(), bmi && is64, bmi, lzc && is64, lzc, pop && is64, pop,
            is64, true];
        for k in 25 {
            if !on[k] { continue; }
            let r = xc1(tabs[k], isd, mty, kind);
            if r >= 0 {
                // adjustTableCost
                if (isd == XISD_FMAXNUM || isd == XISD_FMINNUM) && (ica_tab[ic].fmf & FMF_NNAN) != 0 { return ltc; }
                if !mvt_is_vec(mty) && mvt_is_int(mty) && isd == XISD_BSWAP && xst_hasMOVBE() && xst_hasFastMOVBE() {
                    let ii = ica_tab[ic].inst;
                    if ii >= 0 {
                        let fu = vals[ii].first_use;
                        if fu >= 0 && uses[fu].next < 0 && is_inst_op(uses[fu].user, OP_STORE) { return TCC_FREE; }
                        let l = op(ii, 0);
                        if is_inst_op(l, OP_LOAD) && tt_has_one_use(l) { return TCC_FREE; }
                    }
                }
                return tc_mul(ltc, r);
            }
        }
        if ica_type_based(ic) && (id == IID_fshl || id == IID_fshr) {
            let ct = tt_with_bits(rt, 1);
            var c: i64 = 0;
            c = tc_add(c, x86_arith0(OP_OR, rt, kind));
            c = tc_add(c, x86_arith0(OP_SUB, rt, kind));
            c = tc_add(c, x86_arith0(OP_SHL, rt, kind));
            c = tc_add(c, x86_arith0(OP_LSHR, rt, kind));
            c = tc_add(c, x86_arith0(OP_AND, rt, kind));
            c = tc_add(c, x86_cmpsel_cost(OP_ICMP, rt, ct, 32, kind, 0, 0, -1));
            c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, 32, kind, 0, 0, -1));
            return c;
        }
    }
    return bt_intrinsic_cost(ic, kind);
}

// m_APIntAllowPoison: a ConstantInt, or a constant vector splat (poison lanes allowed) of one
fn tt_match_apint_allow_poison(a: i32) -> bool {
    if vals[a].kind == VK_CINT { return true; }
    if is_constant(a) && ty_is_vector(vals[a].ty) {
        let s = splat_value(a, true);
        return s >= 0 && vals[s].kind == VK_CINT;
    }
    return false;
}

// ---------------------------------------------------------------- BasicTTIImplBase::getIntrinsicInstrCost

recursive fn bt_intrinsic_cost(ic: i64, kind: i64) -> i64 {
    let id = ica_tab[ic].id;
    let rt = ica_tab[ic].ret;
    if base_intrinsic_cost(id, rt) == 0 { return 0; }
    if tt_is_target_intrinsic(id) { return TCC_BASIC; }
    if tt_is_vp_intrinsic(id) { x86_np("getIntrinsicInstrCost of VP intrinsics"); }
    if ica_type_based(ic) { return bt_type_based_intrinsic_cost(ic, kind); }
    let ii = ica_tab[ic].inst;
    let fmf = ica_tab[ic].fmf;
    let ret_vec = tt_is_vectorized_ty(rt);
    if id == IID_powi {
        let r = ica_arg(ic, 1);
        if vals[r].kind == VK_CINT && !ty_is_vector(vals[r].ty) {
            let e = ap_sext64(ci_ap(r));
            let opt_size = ii >= 0 && fn_has_attr_tti(inst_func(ii), AK_OptimizeForSize);
            var ea: i64 = if e < 0 { -e } else { e };
            var pc: i64 = 0;
            var x = ea as u64;
            while x != 0 { pc += (x & 1) as i64; x = x >> 1; }
            var lg: i64 = -1;
            var y = ea as u64;
            while y != 0 { lg++; y = y >> 1; }
            if !opt_size || pc + lg < 7 {
                var ab: i64 = 0;
                var z = ea as u64;
                while z != 0 { ab++; z = z >> 1; }
                var c = tc_mul(x86_arith0(OP_FMUL, rt, kind), ab + pc - 2);
                if e < 0 { c = tc_add(c, x86_arith0(OP_FDIV, rt, kind)); }
                return c;
            }
        }
    } else if id == IID_cttz {
        if !ret_vec && (xst_hasBMI() || x86_can_use_cmov() || x86_is64() ||
                        (!ty_is_vector(rt) && tt_scalar_bits(rt) < (if x86_is64() { 64 } else { 32 }))) { return TCC_BASIC; }
    } else if id == IID_ctlz {
        if !ret_vec && (xst_hasLZCNT() || x86_can_use_cmov() || x86_is64()) { return TCC_BASIC; }
    } else if id == IID_memcpy {
        return TCC_EXPENSIVE;
    } else if id == IID_masked_scatter {
        let mask = ica_arg(ic, 2);
        return x86_mem_intrinsic_cost(id, ica_ty(ic, 0), ica_arg(ic, 1), !is_constant(mask), tt_param_align(ii, 1), 0, kind);
    } else if id == IID_masked_gather {
        let mask = ica_arg(ic, 1);
        return x86_mem_intrinsic_cost(id, rt, ica_arg(ic, 0), !is_constant(mask), tt_param_align(ii, 0), 0, kind);
    } else if id == IID_masked_compressstore {
        let data = ica_arg(ic, 0);
        let mask = ica_arg(ic, 2);
        return x86_mem_intrinsic_cost(id, vals[data].ty, -1, !is_constant(mask), tt_param_align(ii, 1), 0, kind);
    } else if id == IID_masked_expandload {
        let mask = ica_arg(ic, 1);
        return x86_mem_intrinsic_cost(id, rt, -1, !is_constant(mask), tt_param_align(ii, 0), 0, kind);
    } else if id == IID_experimental_vp_strided_store || id == IID_experimental_vp_strided_load {
        x86_np("getIntrinsicInstrCost of vp.strided memory intrinsics");
    } else if id == IID_stepvector {
        if ty_kind(rt) == TK_SVEC { return base_intrinsic_cost(id, rt); }
        return TCC_BASIC;
    } else if id == IID_vector_extract {
        if ty_kind(rt) == TK_SVEC { return base_intrinsic_cost(id, rt); }
        let index = ap_zext64(ci_ap(ica_arg(ic, 1))) as i64;
        let m = mk_mark();
        let c = x86_shuffle_cost(SK_EXTRACTSUBVECTOR, rt, vals[ica_arg(ic, 0)].ty, 0, 0, kind, index, rt, -1, -1, 0, -1);
        mk_release(m);
        return c;
    } else if id == IID_vector_insert {
        if ty_kind(vals[ica_arg(ic, 1)].ty) == TK_SVEC { return base_intrinsic_cost(id, rt); }
        let index = ap_zext64(ci_ap(ica_arg(ic, 2))) as i64;
        return x86_shuffle_cost(SK_INSERTSUBVECTOR, rt, vals[ica_arg(ic, 0)].ty, 0, 0, kind, index, vals[ica_arg(ic, 1)].ty,
                                -1, -1, 0, -1);
    } else if id == IID_vector_splice_left || id == IID_vector_splice_right {
        let co = ica_arg(ic, 2);
        if vals[co].kind == VK_CINT {
            let index = ap_zext64(ci_ap(co)) as i64;
            let ix = if id == IID_vector_splice_left { index } else { (-index) & 0xffffffff };
            return x86_shuffle_cost(SK_SPLICE, rt, vals[ica_arg(ic, 0)].ty, 0, 0, kind, ix, rt, -1, -1, 0, -1);
        }
    } else if id == IID_vector_reduce_add || id == IID_vector_reduce_mul || id == IID_vector_reduce_and ||
              id == IID_vector_reduce_or || id == IID_vector_reduce_xor || id == IID_vector_reduce_smax ||
              id == IID_vector_reduce_smin || id == IID_vector_reduce_fmax || id == IID_vector_reduce_fmin ||
              id == IID_vector_reduce_fmaximum || id == IID_vector_reduce_fminimum || id == IID_vector_reduce_umax ||
              id == IID_vector_reduce_umin {
        let m = ica_mark();
        let a = ica_new(id, rt, fmf, ii, 1);
        ica_add_type(a, vals[ica_arg(ic, 0)].ty);
        let c = bt_type_based_intrinsic_cost(a, kind);
        ica_release(m);
        return c;
    } else if id == IID_vector_reduce_fadd || id == IID_vector_reduce_fmul {
        let m = ica_mark();
        let a = ica_new(id, rt, fmf, ii, 1);
        ica_add_type(a, vals[ica_arg(ic, 0)].ty);
        ica_add_type(a, vals[ica_arg(ic, 1)].ty);
        let c = bt_type_based_intrinsic_cost(a, kind);
        ica_release(m);
        return c;
    } else if id == IID_fshl || id == IID_fshr {
        let x = ica_arg(ic, 0);
        let y = ica_arg(ic, 1);
        let z = ica_arg(ic, 2);
        let ox = tti_operand_info(x);
        let oy = tti_operand_info(y);
        let oz = tti_operand_info(z);
        var c: i64 = 0;
        c = tc_add(c, x86_arith0(OP_OR, rt, kind));
        c = tc_add(c, x86_arith_cost(OP_SHL, rt, kind, ox, oi_no_props(oz), -1, -1, 0, -1));
        c = tc_add(c, x86_arith_cost(OP_LSHR, rt, kind, oy, oi_no_props(oz), -1, -1, 0, -1));
        if !oi_is_constant(oz) {
            c = tc_add(c, x86_arith0(OP_SUB, rt, kind));
            let sb = tt_scalar_bits(rt);
            c = tc_add(c, x86_arith_cost(if (sb & (sb - 1)) == 0 { OP_AND } else { OP_UREM }, rt, kind, oz, 2 * 4, -1, -1, 0, -1));
            if x != y {
                let ct = tt_with_bits(rt, 1);
                c = tc_add(c, x86_cmpsel_cost(OP_ICMP, rt, ct, 32, kind, 0, 0, -1));
                c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, 32, kind, 0, 0, -1));
            }
        }
        return c;
    } else if id == IID_experimental_cttz_elts {
        let at = ica_ty(ic, 0);
        // shouldExpandCttzElements is true for x86
        if ty_kind(at) == TK_SVEC { x86_np("getIntrinsicInstrCost of cttz.elts on scalable vectors"); }
        let zp = !ap_is_zero(ci_ap(ica_arg(ic, 1)));
        // getBitWidthForCttzElements (fixed EC): ConstantRange(EC) - ZeroIsPoison
        var ub = ty_count(at);
        if zp { ub = ub - 1; }
        var ab: i64 = 0;
        var x = ub;
        while x > 0 { ab++; x = x >> 1; }
        var ew = tt_scalar_bits(rt);
        if ab < ew { ew = ab; }
        ew = next_pow2_u(ew);
        if ew < 8 { ew = 8; }
        let net = ty_int(ew);
        let nvt = tt_vec(net, ty_count(vals[ica_arg(ic, 0)].ty));
        let m = ica_mark();
        let sv = ica_new(IID_stepvector, nvt, fmf, -1, TTI_INVALID);
        var c = x86_intrinsic_cost(sv, kind);
        c = tc_add(c, x86_arith0(OP_SUB, nvt, kind));
        c = tc_add(c, x86_cast_cost(OP_SEXT, nvt, vals[ica_arg(ic, 0)].ty, 0, kind, -1));
        c = tc_add(c, x86_arith0(OP_AND, nvt, kind));
        let ra = ica_new(IID_vector_reduce_umax, net, fmf, ii, 1);
        ica_add_type(ra, nvt);
        c = tc_add(c, bt_type_based_intrinsic_cost(ra, kind));
        c = tc_add(c, x86_arith0(OP_SUB, net, kind));
        ica_release(m);
        return c;
    } else if id == IID_modf || id == IID_sincos || id == IID_sincospi ||
              id == IID_loop_dependence_war_mask || id == IID_loop_dependence_raw_mask {
        x86_np(str("getIntrinsicInstrCost of ", intr_name(id as i64)));
    } else if id == IID_get_active_lane_mask || id == IID_experimental_vector_match ||
              id == IID_experimental_vector_histogram_add || id == IID_experimental_vector_histogram_uadd_sat ||
              id == IID_experimental_vector_histogram_umax || id == IID_experimental_vector_histogram_umin ||
              id == IID_masked_udiv || id == IID_masked_sdiv || id == IID_masked_urem || id == IID_masked_srem {
        return bt_type_based_intrinsic_cost(ic, kind);
    }
    var sc = TTI_INVALID;
    if ret_vec && ty_kind(tt_contained(rt, 0)) != TK_SVEC {
        sc = 0;
        if ty_kind(rt) != TK_VOID {
            for k in tt_ncontained(rt) { sc = tc_add(sc, x86_scalarization_overhead_all(tt_contained(rt, k), true, false, kind)); }
        }
        sc = tc_add(sc, x86_ica_operands_overhead_filtered(ic, kind));
    }
    let m = ica_mark();
    let a = ica_types_only(id, rt, ic, fmf, ii, sc);
    let c = bt_type_based_intrinsic_cost(a, kind);
    ica_release(m);
    return c;
}

// getOperandsScalarizationOverhead(filterConstantAndDuplicatedOperands(Args, ArgTys))
recursive fn x86_ica_operands_overhead_filtered(ic: i64, kind: i64) -> i64 {
    var c: i64 = 0;
    let n = ica_tab[ic].nargs as i64;
    for k in n {
        let v = ica_arg(ic, k);
        if is_constant(v) { continue; }
        var dup = false;
        for j in k { if ica_arg(ic, j) == v { dup = true; } }
        if dup { continue; }
        let t = ica_ty(ic, k);
        let s = ty_scalar(t);
        if !ty_is_int(s) && !ty_is_fp(s) && ty_kind(s) != TK_PTR { continue; }
        if ty_is_vector(t) { c = tc_add(c, x86_scalarization_overhead_all(t, false, true, kind)); }
    }
    return c;
}

fn fn_has_attr_tti(fv: i32, k: i64) -> bool { aset_find(alist_fn(func_attrs(fv)), k) >= 0 }

// getArithmeticReductionInstruction
fn tt_reduction_opcode(id: i32) -> i64 {
    if id == IID_vector_reduce_add { return OP_ADD; }
    if id == IID_vector_reduce_mul { return OP_MUL; }
    if id == IID_vector_reduce_and { return OP_AND; }
    if id == IID_vector_reduce_or { return OP_OR; }
    if id == IID_vector_reduce_xor { return OP_XOR; }
    if id == IID_vector_reduce_fadd { return OP_FADD; }
    return OP_FMUL;
}
// getMinMaxReductionIntrinsicOp
fn tt_minmax_reduction_op(id: i32) -> i32 {
    if id == IID_vector_reduce_smax { return IID_smax; }
    if id == IID_vector_reduce_smin { return IID_smin; }
    if id == IID_vector_reduce_umax { return IID_umax; }
    if id == IID_vector_reduce_umin { return IID_umin; }
    if id == IID_vector_reduce_fmax { return IID_maxnum; }
    if id == IID_vector_reduce_fmin { return IID_minnum; }
    if id == IID_vector_reduce_fmaximum { return IID_maximum; }
    return IID_minimum;
}

// ---------------------------------------------------------------- BasicTTIImplBase::getTypeBasedIntrinsicInstrCost

// an intrinsic's ISD opcode for the legality check (0: none)
fn tt_intrinsic_isd(id: i32) -> i32 {
    if id == IID_sqrt { return XISD_FSQRT; }
    if id == IID_sin { return XISD_FSIN; }
    if id == IID_cos { return XISD_FCOS; }
    if id == IID_sincos { return XISD_FSINCOS; }
    if id == IID_sincospi { return XISD_FSINCOSPI; }
    if id == IID_modf { return XISD_FMODF; }
    if id == IID_tan { return XISD_FTAN; }
    if id == IID_asin { return XISD_FASIN; }
    if id == IID_acos { return XISD_FACOS; }
    if id == IID_atan { return XISD_FATAN; }
    if id == IID_atan2 { return XISD_FATAN2; }
    if id == IID_sinh { return XISD_FSINH; }
    if id == IID_cosh { return XISD_FCOSH; }
    if id == IID_tanh { return XISD_FTANH; }
    if id == IID_exp { return XISD_FEXP; }
    if id == IID_exp2 { return XISD_FEXP2; }
    if id == IID_exp10 { return XISD_FEXP10; }
    if id == IID_log { return XISD_FLOG; }
    if id == IID_log10 { return XISD_FLOG10; }
    if id == IID_log2 { return XISD_FLOG2; }
    if id == IID_ldexp { return XISD_FLDEXP; }
    if id == IID_fabs { return XISD_FABS; }
    if id == IID_canonicalize { return XISD_FCANONICALIZE; }
    if id == IID_minnum { return XISD_FMINNUM; }
    if id == IID_maxnum { return XISD_FMAXNUM; }
    if id == IID_minimum { return XISD_FMINIMUM; }
    if id == IID_maximum { return XISD_FMAXIMUM; }
    if id == IID_minimumnum { return XISD_FMINIMUMNUM; }
    if id == IID_maximumnum { return XISD_FMAXIMUMNUM; }
    if id == IID_copysign { return XISD_FCOPYSIGN; }
    if id == IID_floor { return XISD_FFLOOR; }
    if id == IID_ceil { return XISD_FCEIL; }
    if id == IID_trunc { return XISD_FTRUNC; }
    if id == IID_nearbyint { return XISD_FNEARBYINT; }
    if id == IID_rint { return XISD_FRINT; }
    if id == IID_lrint { return XISD_LRINT; }
    if id == IID_llrint { return XISD_LLRINT; }
    if id == IID_round { return XISD_FROUND; }
    if id == IID_roundeven { return XISD_FROUNDEVEN; }
    if id == IID_lround { return XISD_LROUND; }
    if id == IID_llround { return XISD_LLROUND; }
    if id == IID_pow { return XISD_FPOW; }
    if id == IID_fma || id == IID_fmuladd { return XISD_FMA; }
    if id == IID_experimental_constrained_fmuladd { return XISD_STRICT_FMA; }
    if id == IID_abs { return XISD_ABS; }
    if id == IID_fshl { return XISD_FSHL; }
    if id == IID_fshr { return XISD_FSHR; }
    if id == IID_smax { return XISD_SMAX; }
    if id == IID_smin { return XISD_SMIN; }
    if id == IID_umax { return XISD_UMAX; }
    if id == IID_umin { return XISD_UMIN; }
    if id == IID_sadd_sat { return XISD_SADDSAT; }
    if id == IID_ssub_sat { return XISD_SSUBSAT; }
    if id == IID_uadd_sat { return XISD_UADDSAT; }
    if id == IID_usub_sat { return XISD_USUBSAT; }
    if id == IID_smul_fix { return XISD_SMULFIX; }
    if id == IID_umul_fix { return XISD_UMULFIX; }
    if id == IID_sadd_with_overflow { return XISD_SADDO; }
    if id == IID_ssub_with_overflow { return XISD_SSUBO; }
    if id == IID_uadd_with_overflow { return XISD_UADDO; }
    if id == IID_usub_with_overflow { return XISD_USUBO; }
    if id == IID_smul_with_overflow { return XISD_SMULO; }
    if id == IID_umul_with_overflow { return XISD_UMULO; }
    if id == IID_fptosi_sat { return XISD_FP_TO_SINT_SAT; }
    if id == IID_fptoui_sat { return XISD_FP_TO_UINT_SAT; }
    if id == IID_ctpop { return XISD_CTPOP; }
    if id == IID_ctlz { return XISD_CTLZ; }
    if id == IID_cttz { return XISD_CTTZ; }
    if id == IID_bswap { return XISD_BSWAP; }
    if id == IID_bitreverse { return XISD_BITREVERSE; }
    if id == IID_ucmp { return XISD_UCMP; }
    if id == IID_scmp { return XISD_SCMP; }
    if id == IID_clmul { return XISD_CLMUL; }
    return 0;
}

// scalarized fallback of the `default:` case
recursive fn bt_tb_default(ic: i64, kind: i64) -> i64 {
    let id = ica_tab[ic].id;
    let rt = ica_tab[ic].ret;
    let nt = ica_tab[ic].ntys as i64;
    if ty_kind(rt) == TK_SVEC { return TTI_INVALID; }
    for k in nt { if ty_kind(ica_ty(ic, k)) == TK_SVEC { return TTI_INVALID; } }
    let skip = ica_skip_scalarization(ic);
    var sc: i64 = if skip { ica_tab[ic].scost } else { 0 };
    var calls: i64 = 1;
    var srt = rt;
    if ty_is_vector(rt) {
        if !skip { sc = x86_scalarization_overhead_all(rt, true, false, kind); }
        if ty_count(rt) > calls { calls = ty_count(rt); }
        srt = ty_scalar(rt);
    }
    let m = ica_mark();
    let a = ica_new(id, srt, ica_tab[ic].fmf, -1, TTI_INVALID);
    for k in nt {
        let t = ica_ty(ic, k);
        if ty_is_vector(t) {
            if !skip { sc = tc_add(sc, x86_scalarization_overhead_all(t, false, true, kind)); }
            if ty_count(t) > calls { calls = ty_count(t); }
            ica_add_type(a, ty_scalar(t));
        } else {
            ica_add_type(a, t);
        }
    }
    if calls == 1 { ica_release(m); return 1; }
    let scc = x86_intrinsic_cost(a, kind);
    ica_release(m);
    return tc_add(tc_mul(scc, calls), sc);
}

recursive fn bt_type_based_intrinsic_cost(ic: i64, kind: i64) -> i64 {
    let id = ica_tab[ic].id;
    let rt = ica_tab[ic].ret;
    let nt = ica_tab[ic].ntys as i64;
    let fmf = ica_tab[ic].fmf;
    let scp = ica_tab[ic].scost;
    let skip = ica_skip_scalarization(ic);
    var vecop: i32 = -1;
    if nt > 0 {
        let vi: i64 = if id == IID_vector_reduce_fadd || id == IID_vector_reduce_fmul { 1 } else { 0 };
        let t = ica_ty(ic, vi);
        if ty_is_vector(t) { vecop = t; }
    }
    var single_call: i64 = if kind == TCK_CODE_SIZE { 1 } else { 10 };
    var isd = tt_intrinsic_isd(id);
    if id == IID_lifetime_start || id == IID_lifetime_end || id == IID_sideeffect || id == IID_pseudoprobe ||
       id == IID_arithmetic_fence { return 0; }
    if id == IID_masked_store {
        let t = ica_ty(ic, 0);
        return x86_mem_intrinsic_cost(id, t, -1, true, dl_align(t, true), 0, kind);
    }
    if id == IID_masked_load { return x86_mem_intrinsic_cost(id, rt, -1, true, dl_align(rt, true), 0, kind); }
    if id == IID_experimental_vp_strided_store || id == IID_experimental_vp_strided_load {
        x86_np("getTypeBasedIntrinsicInstrCost of vp.strided memory intrinsics");
    }
    if id == IID_vector_reduce_add || id == IID_vector_reduce_mul || id == IID_vector_reduce_and ||
       id == IID_vector_reduce_or || id == IID_vector_reduce_xor {
        return x86_arith_reduction_cost(tt_reduction_opcode(id), vecop, false, kind);
    }
    if id == IID_vector_reduce_fadd || id == IID_vector_reduce_fmul {
        return x86_arith_reduction_cost(tt_reduction_opcode(id), vecop, (fmf & FMF_REASSOC) == 0, kind);
    }
    if id == IID_vector_reduce_smax || id == IID_vector_reduce_smin || id == IID_vector_reduce_umax ||
       id == IID_vector_reduce_umin || id == IID_vector_reduce_fmax || id == IID_vector_reduce_fmin ||
       id == IID_vector_reduce_fmaximum || id == IID_vector_reduce_fminimum {
        return x86_minmax_reduction_cost(tt_minmax_reduction_op(id), vecop, fmf, kind);
    }
    if id == IID_experimental_vector_match || id == IID_experimental_vector_histogram_add ||
       id == IID_experimental_vector_histogram_uadd_sat || id == IID_experimental_vector_histogram_umax ||
       id == IID_experimental_vector_histogram_umin || id == IID_get_active_lane_mask {
        x86_np(str("getTypeBasedIntrinsicInstrCost of ", intr_name(id as i64)));
    }
    if id == IID_vector_reverse {
        return x86_shuffle_cost(SK_REVERSE, rt, ica_ty(ic, 0), 0, 0, kind, 0, rt, -1, -1, 0, -1);
    }
    if id == IID_experimental_memset_pattern { return TCC_BASIC * 4; }
    if id == IID_fptosi_sat || id == IID_fptoui_sat {
        let sc0, sl = x86_legalize(ica_ty(ic, 0));
        let rc0, rl = x86_legalize(rt);
        if !tc_valid(sc0) || !tc_valid(rc0) { return TTI_INVALID; }
    }
    if id == IID_ctpop { single_call = TCC_EXPENSIVE; }
    if id == IID_masked_udiv || id == IID_masked_sdiv || id == IID_masked_urem || id == IID_masked_srem {
        var uo = OP_UDIV;
        if id == IID_masked_udiv { isd = XISD_MASKED_UDIV; uo = OP_UDIV; }
        if id == IID_masked_sdiv { isd = XISD_MASKED_SDIV; uo = OP_SDIV; }
        if id == IID_masked_urem { isd = XISD_MASKED_UREM; uo = OP_UREM; }
        if id == IID_masked_srem { isd = XISD_MASKED_SREM; uo = OP_SREM; }
        var c = x86_arith0(uo, rt, kind);
        let lc, lt = x86_legalize(rt);
        if !tl_legal_or_custom(isd, lt as i64) {
            let ct = tt_with_elt(rt, ty_int(1));
            c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, PRED_BAD_ICMP, kind, 0, 2 * 4 + 1, -1));
        }
        return c;
    }
    if isd == 0 { return bt_tb_default(ic, kind); }
    let lty = if ty_is_struct(rt) { ty_field(rt, 0) } else { rt };
    let ltc, lt = x86_legalize(lty);
    if tl_legal_or_promote(isd, lt as i64) {
        // isFAbsFree is false for x86
        if tc_valid(ltc) && ltc > 1 { return tc_mul(ltc, 2); }
        return tc_mul(ltc, 1);
    } else if tl_op_custom(isd, lt as i64) {
        return tc_mul(ltc, 2);
    }
    if id == IID_fmuladd {
        return tc_add(x86_arith0(OP_FMUL, rt, kind), x86_arith0(OP_FADD, rt, kind));
    }
    if id == IID_experimental_constrained_fmuladd {
        let m = ica_mark();
        let a = ica_types_only(IID_experimental_constrained_fmul, rt, ic, 0, -1, TTI_INVALID);
        let c1 = x86_intrinsic_cost(a, kind);
        let b = ica_types_only(IID_experimental_constrained_fadd, rt, ic, 0, -1, TTI_INVALID);
        let c2 = x86_intrinsic_cost(b, kind);
        ica_release(m);
        return tc_add(c1, c2);
    }
    if id == IID_smin || id == IID_smax || id == IID_umin || id == IID_umax {
        let ct = tt_with_bits(rt, 1);
        let pred: i64 = if id == IID_umax || id == IID_umin { PRED_ICMP_UGT } else { 38 };
        return tc_add(x86_cmpsel_cost(OP_ICMP, rt, ct, pred, kind, 0, 0, -1), x86_cmpsel_cost(OP_SELECT, rt, ct, pred, kind, 0, 0, -1));
    }
    if id == IID_sadd_with_overflow || id == IID_ssub_with_overflow {
        let sumt = ty_field(rt, 0);
        let ovt = ty_field(rt, 1);
        let o = if id == IID_sadd_with_overflow { OP_ADD } else { OP_SUB };
        var c = x86_arith0(o, sumt, kind);
        c = tc_add(c, tc_mul(x86_cmpsel_cost(OP_ICMP, sumt, ovt, 38, kind, 0, 0, -1), 2));
        c = tc_add(c, x86_arith0(OP_XOR, ovt, kind));
        return c;
    }
    if id == IID_uadd_with_overflow || id == IID_usub_with_overflow {
        let sumt = ty_field(rt, 0);
        let ovt = ty_field(rt, 1);
        let o = if id == IID_uadd_with_overflow { OP_ADD } else { OP_SUB };
        let pred = if id == IID_uadd_with_overflow { PRED_ICMP_ULT } else { PRED_ICMP_UGT };
        return tc_add(x86_arith0(o, sumt, kind), x86_cmpsel_cost(OP_ICMP, sumt, ovt, pred, kind, 0, 0, -1));
    }
    if id == IID_smul_with_overflow || id == IID_umul_with_overflow {
        let mt = ty_field(rt, 0);
        let ovt = ty_field(rt, 1);
        let ext = tt_with_bits(mt, tt_scalar_bits(mt) * 2);
        let signed = id == IID_smul_with_overflow;
        let eo = if signed { OP_SEXT } else { OP_ZEXT };
        var c = tc_mul(x86_cast_cost(eo, ext, mt, 0, kind, -1), 2);
        c = tc_add(c, x86_arith0(OP_MUL, ext, kind));
        c = tc_add(c, tc_mul(x86_cast_cost(OP_TRUNC, mt, ext, 0, kind, -1), 2));
        c = tc_add(c, x86_arith_cost(OP_LSHR, ext, kind, 0, 2 * 4, -1, -1, 0, -1));
        if signed { c = tc_add(c, x86_arith_cost(OP_ASHR, mt, kind, 0, 2 * 4, -1, -1, 0, -1)); }
        c = tc_add(c, x86_cmpsel_cost(OP_ICMP, mt, ovt, PRED_ICMP_NE, kind, 0, 0, -1));
        return c;
    }
    if id == IID_sadd_sat || id == IID_ssub_sat {
        let ct = tt_with_bits(rt, 1);
        let opt = tt_struct2(rt, ct);
        let ovo = if id == IID_sadd_sat { IID_sadd_with_overflow } else { IID_ssub_with_overflow };
        let m = ica_mark();
        let a = ica_new(ovo, opt, fmf, -1, scp);
        ica_add_type(a, rt);
        ica_add_type(a, rt);
        var c = x86_intrinsic_cost(a, kind);
        ica_release(m);
        c = tc_add(c, x86_cmpsel_cost(OP_ICMP, rt, ct, 38, kind, 0, 0, -1));
        c = tc_add(c, tc_mul(x86_cmpsel_cost(OP_SELECT, rt, ct, 38, kind, 0, 0, -1), 2));
        return c;
    }
    if id == IID_uadd_sat || id == IID_usub_sat {
        let ct = tt_with_bits(rt, 1);
        let opt = tt_struct2(rt, ct);
        let ovo = if id == IID_uadd_sat { IID_uadd_with_overflow } else { IID_usub_with_overflow };
        let m = ica_mark();
        let a = ica_new(ovo, opt, fmf, -1, scp);
        ica_add_type(a, rt);
        ica_add_type(a, rt);
        var c = x86_intrinsic_cost(a, kind);
        ica_release(m);
        c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, PRED_BAD_ICMP, kind, 0, 0, -1));
        return c;
    }
    if id == IID_smul_fix || id == IID_umul_fix {
        let ext = tt_with_bits(rt, tt_scalar_bits(rt) * 2);
        let eo = if id == IID_smul_fix { OP_SEXT } else { OP_ZEXT };
        var c = tc_mul(x86_cast_cost(eo, ext, rt, 0, kind, -1), 2);
        c = tc_add(c, x86_arith0(OP_MUL, ext, kind));
        c = tc_add(c, tc_mul(x86_cast_cost(OP_TRUNC, rt, ext, 0, kind, -1), 2));
        c = tc_add(c, x86_arith_cost(OP_LSHR, rt, kind, 0, 2 * 4, -1, -1, 0, -1));
        c = tc_add(c, x86_arith_cost(OP_SHL, rt, kind, 0, 2 * 4, -1, -1, 0, -1));
        c = tc_add(c, x86_arith0(OP_OR, rt, kind));
        return c;
    }
    if id == IID_abs {
        let ct = tt_with_bits(rt, 1);
        var c = x86_cmpsel_cost(OP_ICMP, rt, ct, 38, kind, 0, 0, -1);
        c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, 38, kind, 0, 0, -1));
        c = tc_add(c, x86_arith_cost(OP_SUB, rt, kind, 2 * 4, 0, -1, -1, 0, -1));
        return c;
    }
    if id == IID_fshl || id == IID_fshr {
        let ct = tt_with_bits(rt, 1);
        var c: i64 = 0;
        c = tc_add(c, x86_arith0(OP_OR, rt, kind));
        c = tc_add(c, x86_arith0(OP_SUB, rt, kind));
        c = tc_add(c, x86_arith0(OP_SHL, rt, kind));
        c = tc_add(c, x86_arith0(OP_LSHR, rt, kind));
        let sb = tt_scalar_bits(rt);
        c = tc_add(c, x86_arith_cost(if (sb & (sb - 1)) == 0 { OP_AND } else { OP_UREM }, rt, kind, 0, 2 * 4, -1, -1, 0, -1));
        c = tc_add(c, x86_cmpsel_cost(OP_ICMP, rt, ct, 32, kind, 0, 0, -1));
        c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, 32, kind, 0, 0, -1));
        return c;
    }
    if (id == IID_fptosi_sat || id == IID_fptoui_sat) && nt > 0 {
        let from = ica_ty(ic, 0);
        let signed = id == IID_fptosi_sat;
        let m = ica_mark();
        let a1 = ica_new(IID_minnum, from, 0, -1, TTI_INVALID);
        ica_add_type(a1, from);
        ica_add_type(a1, from);
        var c = x86_intrinsic_cost(a1, kind);
        let a2 = ica_new(IID_maxnum, from, 0, -1, TTI_INVALID);
        ica_add_type(a2, from);
        ica_add_type(a2, from);
        c = tc_add(c, x86_intrinsic_cost(a2, kind));
        ica_release(m);
        c = tc_add(c, x86_cast_cost(if signed { OP_FPTOSI } else { OP_FPTOUI }, rt, from, 0, kind, -1));
        if signed {
            let ct = tt_with_bits(rt, 1);
            c = tc_add(c, x86_cmpsel_cost(OP_FCMP, from, ct, PRED_FCMP_UNO, kind, 0, 0, -1));
            c = tc_add(c, x86_cmpsel_cost(OP_SELECT, rt, ct, PRED_FCMP_UNO, kind, 0, 0, -1));
        }
        return c;
    }
    if id == IID_ucmp || id == IID_scmp {
        let cmpt = ica_ty(ic, 0);
        let ct = tt_with_bits(rt, 1);
        let gt: i64 = if id == IID_ucmp { PRED_ICMP_UGT } else { 38 };
        let lt2: i64 = if id == IID_ucmp { PRED_ICMP_ULT } else { 40 };
        var c = tc_add(x86_cmpsel_cost(OP_ICMP, cmpt, ct, gt, kind, 0, 0, -1), x86_cmpsel_cost(OP_ICMP, cmpt, ct, lt2, kind, 0, 0, -1));
        // preferSelectsOverBooleanArithmetic is false for x86
        c = tc_add(c, tc_mul(x86_cast_cost(OP_ZEXT, rt, ct, 0, kind, -1), 2));
        c = tc_add(c, x86_arith0(OP_SUB, rt, kind));
        return c;
    }
    if id == IID_maximumnum || id == IID_minimumnum {
        let ieee = if id == IID_maximumnum { XISD_FMAXNUM_IEEE } else { XISD_FMINNUM_IEEE };
        if tl_op_legal(ieee, lt as i64) {
            let m = ica_mark();
            let a = ica_new(IID_canonicalize, rt, 0, -1, TTI_INVALID);
            ica_add_type(a, ica_ty(ic, 0));
            let fc = x86_intrinsic_cost(a, kind);
            ica_release(m);
            return tc_add(ltc, tc_mul(fc, 2));
        }
    }
    if id == IID_clmul {
        let bw = tt_scalar_bits(rt);
        let andc = x86_arith0(OP_AND, rt, kind);
        let orc = x86_arith0(OP_OR, rt, kind);
        let xorc = x86_arith0(OP_XOR, rt, kind);
        let mulc = x86_arith0(OP_MUL, rt, kind);
        if bw >= 32 && bw <= 64 && tl_legal_or_custom(XISD_MUL, x86_value_type(rt, false)) {
            return tc_add(tc_add(tc_mul(mulc, 16), tc_mul(andc, 12)), tc_add(tc_mul(xorc, 12), tc_mul(orc, 3)));
        }
        let pbm = tc_add3(andc, mulc, xorc);
        let pbb = tc_add3(andc, x86_cmpsel_cost(OP_SELECT, rt, rt, PRED_BAD_ICMP, kind, 0, 0, -1),
                          x86_cmpsel_cost(OP_ICMP, rt, rt, PRED_ICMP_NE, kind, 0, 0, -1));
        return tc_mul(if pbm < pbb { pbm } else { pbb }, bw);
    }
    if tt_is_vectorized_ty(rt) {
        let nret = tt_ncontained(rt);
        for k in nret { if ty_kind(tt_contained(rt, k)) == TK_SVEC { return TTI_INVALID; } }
        for k in nt { if ty_kind(ica_ty(ic, k)) == TK_SVEC { return TTI_INVALID; } }
        var sc = scp;
        if !skip {
            sc = 0;
            for k in nret { sc = tc_add(sc, x86_scalarization_overhead_all(tt_contained(rt, k), true, false, kind)); }
        }
        var calls = tt_vectorized_vf(rt);
        let m = ica_mark();
        let a = ica_new(id, tt_to_scalarized(rt), fmf, -1, TTI_INVALID);
        for k in nt { let t = ica_ty(ic, k); ica_add_type(a, if ty_is_vector(t) { ty_scalar(t) } else { t }); }
        let scc = x86_intrinsic_cost(a, kind);
        ica_release(m);
        for k in nt {
            let t = ica_ty(ic, k);
            if ty_is_vector(t) {
                if !skip { sc = tc_add(sc, x86_scalarization_overhead_all(t, false, true, kind)); }
                if ty_count(t) > calls { calls = ty_count(t); }
            }
        }
        return tc_add(tc_mul(scc, calls), sc);
    }
    return single_call;
}
