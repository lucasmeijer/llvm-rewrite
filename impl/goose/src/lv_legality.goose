// LoopVectorizationLegality and LoopVectorizeHints: port of
// llvm/lib/Transforms/Vectorize/LoopVectorizationLegality.cpp (LoopVectorizeHints, canVectorize and everything it
// calls for inner loops: canVectorizeLoopCFG / LoopNestCFG, canVectorizeWithIfConvert / blockCanBePredicated,
// canVectorizeInstrs / canVectorizeInstr / addInductionPhi, canVectorizeMemory, canVectorizeFPMath,
// isVectorizableEarlyExitLoop (read-only path), isConsecutivePtr, isUniform with
// SCEVAddRecForUniformityRewriter, isUniformMemOp, blockNeedsPredication, canFoldTailByMasking,
// prepareToFoldTailByMasking, collectUnitStridePredicates) and of llvm/include/llvm/Transforms/Vectorize/
// LoopVectorizationLegality.h; isDereferenceableAndAlignedInLoop and isReadOnlyLoop (llvm/lib/Analysis/Loads.cpp).
// Not ported (fail loudly): outer loops (VPlan-native path), histograms (-enable-histogram-loop-vectorization),
// canUncountableExitConditionLoadBeMoved (early exits with side effects), VFDatabase mappings.
//
// One legality instance at a time (the loop being processed), in `lvl_*` globals; the hints are `lvh_*`.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import gen_attrs;
import datalayout;
import pm;
import apint;
import vt;
import poison;
import assume;
import knownbits;
import speculate;
import domtree;
import loopinfo;
import loop_md;
import scev;
import scev_create;
import scev_eval;
import scev_lt;
import scev_btc;
import scev_guards;
import scev_range;
import scev_pred;
import pse;
import laa;
import tti;
import tti_vec;
import tti_x86_vec;
import vecutils;
import iv_descriptors;

fn lvx_unported(what: const u8[:]) { fatal(str("loop-vectorize: ", what, " is not supported yet")); }

// ---------------------------------------------------------------------------------------------
// LoopVectorizeHints

let FK_UNDEFINED: i64 = -1; let FK_DISABLED: i64 = 0; let FK_ENABLED: i64 = 1;
let SK_UNSPECIFIED: i64 = -1; let SK_FIXED_WIDTH_ONLY: i64 = 0; let SK_PREFER_SCALABLE: i64 = 1; let SK_ALWAYS_SCALABLE: i64 = 2;

var lvh_l: i32 = -1;
var lvh_width: i64 = 0;
var lvh_interleave: i64 = 0;
var lvh_force: i64 = -1;
var lvh_is_vectorized: i64 = 0;
var lvh_predicate: i64 = -1;
var lvh_scalable: i64 = -1;
var lvh_potentially_unsafe: bool = false;

// -force-vector-width (VectorizerParams::VectorizationFactor): the fixed width, 0 when not given
fn lv_force_vector_width() -> i64 {
    if !flag_given("force-vector-width") { return 0; }
    let s = flag_str("force-vector-width");
    if starts_with(s, "vscale") { lvx_unported("a scalable -force-vector-width"); }
    return flag_int("force-vector-width", 0);
}
fn lv_force_vector_interleave() -> i64 { flag_int("force-vector-interleave", 0) }

fn lvh_validate(kind: i64, v: i64) -> bool {
    let pow2 = v > 0 && (v & (v - 1)) == 0;
    if kind == 0 { return pow2 && v <= 64; }
    if kind == 1 { return pow2 && v <= 16; }
    if kind == 2 { return v <= 1; }
    return v == 0 || v == 1;
}

// setHint(Name, Arg)
fn lvh_set_hint(name: const u8[:], arg: i32) {
    if !starts_with(name, "llvm.loop.") { return; }
    let n = name[10..];
    if arg < 0 || mds[arg].kind != MK_VALUE { return; }
    let c = mds[arg].extra;
    if !is_cint(c) { return; }
    let a = ci_ap(c);
    if !ap_fits_u64(a) { return; }
    let v = (a.lo & 0xFFFFFFFF) as i64;
    let names: const u8[:][6] = ["vectorize.width", "interleave.count", "vectorize.enable", "isvectorized",
                                 "vectorize.predicate.enable", "vectorize.scalable.enable"];
    for k in 6 {
        if n == names[k] {
            if lvh_validate(k, v) {
                if k == 0 { lvh_width = v; }
                else if k == 1 { lvh_interleave = v; }
                else if k == 2 { lvh_force = v; }
                else if k == 3 { lvh_is_vectorized = v; }
                else if k == 4 { lvh_predicate = v; }
                else { lvh_scalable = v; }
            }
            break;
        }
    }
}

// LoopVectorizeHints(L, InterleaveOnlyWhenForced, ORE, TTI)
fn lvh_init(l: i32, interleave_only_when_forced: bool) {
    lvh_l = l;
    lvh_width = lv_force_vector_width();
    lvh_interleave = if interleave_only_when_forced { 1 } else { 0 };
    lvh_force = FK_UNDEFINED;
    lvh_is_vectorized = 0;
    lvh_predicate = FK_UNDEFINED;
    lvh_scalable = SK_UNSPECIFIED;
    lvh_potentially_unsafe = false;
    // getHintsFromMetadata
    let id = loop_id(l);
    if id >= 0 {
        for k in 1..(mds[id].nops as i64) {
            let o = md_op(id, k);
            if o < 0 { continue; }
            if md_is_node(o) {
                if mds[o].nops == 0 { continue; }
                let s = md_op(o, 0);
                if s < 0 || mds[s].kind != MK_STRING { continue; }
                if mds[o].nops == 2 { lvh_set_hint(sbytes(mds[s].extra), md_op(o, 1)); }
            }
        }
    }
    if flag_given("force-vector-interleave") { lvh_interleave = lv_force_vector_interleave(); }
    if lvh_scalable == SK_UNSPECIFIED {
        // TTI->enableScalableVectorization(): false on X86 and NoTTI
        lvh_scalable = SK_FIXED_WIDTH_ONLY;
        if lvh_width != 0 { lvh_scalable = SK_FIXED_WIDTH_ONLY; }
    }
    if flag_given("scalable-vectorization") {
        let s = flag_str("scalable-vectorization");
        if s == "off" { lvh_scalable = SK_FIXED_WIDTH_ONLY; }
        else { lvx_unported("-scalable-vectorization"); }
    }
    if lvh_scalable == SK_UNSPECIFIED { lvh_scalable = SK_FIXED_WIDTH_ONLY; }
    if lvh_is_vectorized != 1 {
        lvh_is_vectorized = if lvh_get_width() == 1 && lvh_get_interleave() == 1 { 1 } else { 0 };
    }
}
fn lvh_get_width() -> i64 {
    if lvh_scalable == SK_PREFER_SCALABLE || lvh_scalable == SK_ALWAYS_SCALABLE {
        if lvh_width != 0 { lvx_unported("scalable vectorization factors"); }
    }
    return lvh_width;
}
fn lvh_get_interleave() -> i64 {
    if lvh_interleave != 0 { return lvh_interleave; }
    if (has_unroll_transformation(lvh_l) & TM_DISABLE) != 0 { return 1; }
    return 0;
}
fn lvh_get_force() -> i64 {
    if lvh_force == FK_UNDEFINED && lmd_disable_all_transforms(lvh_l) { return FK_DISABLED; }
    return lvh_force;
}
// allowVectorization(F, L, VectorizeOnlyWhenForced)
fn lvh_allow_vectorization(vectorize_only_when_forced: bool) -> bool {
    if lvh_get_force() == FK_DISABLED { return false; }
    if vectorize_only_when_forced && lvh_get_force() != FK_ENABLED { return false; }
    if lvh_is_vectorized == 1 { return false; }
    return true;
}
// allowReordering
fn lvh_allow_reordering() -> bool {
    return flag_bool("hints-allow-reordering", true) && (lvh_get_force() == FK_ENABLED || lvh_get_width() > 1);
}
fn lvh_is_potentially_unsafe() -> bool { lvh_get_force() != FK_ENABLED && lvh_potentially_unsafe }

// ---------------------------------------------------------------------------------------------
// LoopVectorizationLegality state

var lvl_l: i32 = -1;
var lvl_fv: i32 = -1;
var lvl_pse: i32 = -1;
var lvl_allow_rt_scev: bool = true;
var lvl_ind_phis: i32[>..<];      // Inductions (MapVector: insertion order)
var lvl_ind_desc: i32[>..<];
var lvl_ind_map = hm_new();       // phi -> index into lvl_ind_phis
var lvl_ind_casts = hm_new();     // InductionCastsToIgnore
var lvl_rdx_phis: i32[>..<];      // Reductions (MapVector)
var lvl_rdx_desc: i32[>..<];
var lvl_rdx_map = hm_new();
var lvl_fors: i32[>..<];          // FixedOrderRecurrences (SmallPtrSet; kept in insertion order)
var lvl_fors_set = hm_new();
var lvl_primary: i32 = -1;
var lvl_widest_ind_ty: i32 = -1;
var lvl_cond_ops = hm_new();      // ConditionallyExecutedOps
var lvl_tail_ops = hm_new();      // TailFoldedMaskedOp
var lvl_exact_fp: i32 = -1;       // Requirements->getExactFPInst()
var lvl_vec_call_variants: bool = false;
var lvl_uncountable: i64 = 0;     // UncountableExitTrait: 0 None, 1 ReadOnly, 2 ReadWrite
var lvl_countable_exiting: i32[>..<];
var lvl_lai_valid: bool = false;

fn lvl_reset(l: i32, pse: i32, allow_rt_scev: bool) {
    lvl_l = l;
    lvl_fv = block_func(loop_header(l));
    lvl_pse = pse;
    lvl_allow_rt_scev = allow_rt_scev;
    lvl_ind_phis.clear(); lvl_ind_desc.clear(); hm_clear(lvl_ind_map); hm_clear(lvl_ind_casts);
    lvl_rdx_phis.clear(); lvl_rdx_desc.clear(); hm_clear(lvl_rdx_map);
    lvl_fors.clear(); hm_clear(lvl_fors_set);
    lvl_primary = -1;
    lvl_widest_ind_ty = -1;
    hm_clear(lvl_cond_ops); hm_clear(lvl_tail_ops);
    lvl_exact_fp = -1;
    lvl_vec_call_variants = false;
    lvl_uncountable = 0;
    lvl_countable_exiting.clear();
    lvl_lai_valid = false;
}

fn lvl_add_exact_fp(i: i32) { if i >= 0 && lvl_exact_fp < 0 { lvl_exact_fp = i; } }

// queries
fn lvl_ind_of(phi: i32) -> i32 { let k = hm_get(lvl_ind_map, phi as u64, -1); if k < 0 { -1 } else { lvl_ind_desc[k] } }
fn lvl_rdx_of(phi: i32) -> i32 { let k = hm_get(lvl_rdx_map, phi as u64, -1); if k < 0 { -1 } else { lvl_rdx_desc[k] } }
fn lvl_is_induction_phi(v: i32) -> bool { v >= 0 && hm_has(lvl_ind_map, v as u64) }
fn lvl_is_casted_induction_variable(v: i32) -> bool { v >= 0 && is_inst(v) && hm_has(lvl_ind_casts, v as u64) }
fn lvl_is_induction_variable(v: i32) -> bool { lvl_is_induction_phi(v) || lvl_is_casted_induction_variable(v) }
fn lvl_is_reduction_variable(v: i32) -> bool { v >= 0 && hm_has(lvl_rdx_map, v as u64) }
fn lvl_is_fixed_order_recurrence(v: i32) -> bool { v >= 0 && hm_has(lvl_fors_set, v as u64) }
fn lvl_has_uncountable_early_exit() -> bool { lvl_uncountable != 0 }
fn lvl_has_uncountable_exit_with_side_effects() -> bool { lvl_uncountable == 2 }
// isMaskRequired / ConditionallyExecutedOps.contains
fn lvl_is_masked_op(i: i32) -> bool { hm_has(lvl_cond_ops, i as u64) || hm_has(lvl_tail_ops, i as u64) }
// getMaxSafeVectorWidthInBits
fn lvl_max_safe_vector_width_bits() -> u64 { mdc_max_safe_width }
// isSafeForAnyVectorWidth
fn lvl_is_safe_for_any_vector_width() -> bool { mdc_max_safe_width == 0xFFFFFFFF && !lvl_has_rt_need_unknown() }
fn lvl_has_rt_need_unknown() -> bool { false }
// getRuntimePointerChecking()->Need
fn lvl_rt_need() -> bool { rpc_need }
// LAI->isInvariant
fn lvl_is_invariant(v: i32) -> bool { lai_is_invariant(v) }

// getInductionIntegerTy / getWiderInductionTy
fn lv_induction_int_ty(t: i32) -> i32 {
    if ty_kind(t) == TK_PTR { return ty_int(dl_ptr(ty_bits(t)).bits); }
    if ty_bits(ty_scalar(t)) < 32 { return ty_int(32); }
    return t;
}
fn lv_wider_induction_ty(t0: i32, t1: i32) -> i32 {
    let a = lv_induction_int_ty(t0);
    let b = lv_induction_int_ty(t1);
    return if ty_bits(a) > ty_bits(b) { a } else { b };
}

// addInductionPhi
fn lvl_add_induction_phi(phi: i32, d: i32) {
    if hm_has(lvl_ind_map, phi as u64) {
        lvl_ind_desc[hm_get(lvl_ind_map, phi as u64, 0)] = d;
    } else {
        hm_put(lvl_ind_map, phi as u64, lvl_ind_phis.len);
        lvl_ind_phis.push(phi);
        lvl_ind_desc.push(d);
    }
    if ind_descs[d].casts_n > 0 { hm_put(lvl_ind_casts, ind_cast(d, 0) as u64, 1); }
    let t = vals[phi].ty;
    if ty_is_int(t) || ty_kind(t) == TK_PTR {
        if lvl_widest_ind_ty < 0 { lvl_widest_ind_ty = lv_induction_int_ty(t); }
        else { lvl_widest_ind_ty = lv_wider_induction_ty(t, lvl_widest_ind_ty); }
    }
    let cs = ind_const_step(d);
    let sv = ind_descs[d].start;
    if ind_descs[d].kind == IK_INT && cs >= 0 && ap_is_one(ci_ap(cs)) && is_constant(sv) && is_null_value(sv) {
        if lvl_primary < 0 || t == lvl_widest_ind_ty { lvl_primary = phi; }
    }
}

// ---------------------------------------------------------------------------------------------
// isDereferenceableAndAlignedInLoop / isReadOnlyLoop (Loads.cpp)

// isDereferenceableAndAlignedPointerViaAssumption with the loop's CheckSize: AccessSize <=u ArgValue under guards
fn lv_deref_via_assumption_scev(v: i32, align: i64, size_scev: i32, guards: i32, cxt: i32) -> bool {
    let save_cxt = kb_cxt;
    kb_cxt = cxt;
    let save_ac = sq_no_ac;
    sq_no_ac = false;
    let ready = ac_ready();
    sq_no_ac = save_ac;
    kb_cxt = save_cxt;
    if !ready { return false; }
    let can_free = spec_can_be_freed(v);
    var aligned = pointer_alignment(v) >= align;
    var derefable = false;
    for k in ac_val.len {
        if ac_val[k] != v || ac_idx[k] < 0 { continue; }
        let a = ac_asm[k];
        if a < 0 || is_dead(a) { continue; }
        let bi = ac_idx[k] as i64;
        let tag = bundle_tag_name(a, bi);
        let b0 = cb_bundle_begin(a, bi);
        let n = cb_bundle_count(a, bi);
        let is_align = tag == "align";
        let is_deref = tag == "dereferenceable";
        if n < 1 || op(a, b0) != v { continue; }
        if !is_align && !is_deref { continue; }
        var argv: u64 = 0;
        var argval: i32 = -1;
        if n > 1 {
            argv = if is_align { 1 } else { 0 };
            let c = op(a, b0 + 1);
            argval = c;
            argv = if vals[c].kind == VK_CINT { ap_zext64(ci_ap(c)) } else { argv };
            if is_align && n > 2 {
                let c2 = op(a, b0 + 2);
                let off: u64 = if vals[c2].kind == VK_CINT { ap_zext64(ci_ap(c2)) } else { 1 };
                let x = argv | off;
                argv = x & (~x + 1);
            }
        }
        if !spec_valid_assume_for_context(a, cxt) { continue; }
        if is_align {
            if argv >= align as u64 { aligned = true; }
        } else {
            if !derefable && (!can_free || spec_will_not_free_between(a, cxt)) {
                if argval < 0 { lvx_unported("a dereferenceable assumption without a size"); }
                let lhs = sc_apply_loop_guards_g(size_scev, guards);
                let rhs = sc_apply_loop_guards_g(sc_get_scev(argval), guards);
                if sc_is_known_predicate(P_ULE, lhs, rhs) { derefable = true; }
            }
        }
        if aligned && derefable { return true; }
    }
    return false;
}

// isDereferenceableAndAlignedPointer(V, Alignment, Size, SimplifyQuery(DL, DT, AC, CtxI))
fn lv_deref_aligned_ptr(v: i32, align: i64, size: AP, cxt: i32) -> bool {
    spec_use_dt = true;
    spec_use_ac = true;
    spec_cxt = cxt;
    spec_visited.clear();
    let r = spec_deref_aligned(v, align, size, 16);
    spec_use_dt = false;
    spec_use_ac = false;
    spec_cxt = -1;
    return r;
}

fn lv_ld_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << ((a - 1) as i64) }; }

// isDereferenceableAndAlignedInLoop(LI, L, SE, DT, AC, Predicates)
fn lv_deref_aligned_in_loop(li: i32, l: i32, preds: bool) -> bool {
    let ptr = op(li, 0);
    let ptr_scev = sc_get_scev(ptr);
    let iw = dl_ptr(ty_bits(vals[ptr].ty)).idx;
    let esz = ap_u64(dl_store_size(vals[li].ty) as u64, iw);
    let align = lv_ld_align(li);
    if ivd_loop_invariant(l, ptr) {
        return lv_deref_aligned_ptr(ptr, align, esz, first_non_phi(loop_header(l)));
    }
    let esz_scev = sc_get_constant(esz);
    // isDereferenceableAndAlignedInLoop(PtrSCEV, ...)
    if !sc_is_addrec(ptr_scev) || sc_loop(ptr_scev) != l || !sc_is_affine(ptr_scev) { return false; }
    let step = sc_get_step_recurrence(ptr_scev);
    if !sc_is_const(step) { return false; }
    if !ap_is_zero(ap_urem(esz, ap_u64(align as u64, esz.w as i64))) { return false; }
    if ap_ugt(esz, ap_abs(sc_ap(step))) { return false; }
    var max_be: i32 = -1;
    var be: i32 = -1;
    if preds {
        let m = sc_out_preds.len;
        max_be = sc_get_predicated_btc(l, BTC_SYMBOLIC_MAX);
        be = sc_get_predicated_btc(l, BTC_EXACT);
        sc_out_preds.resize(m);
    } else {
        max_be = sc_get_backedge_taken_count(l, BTC_SYMBOLIC_MAX);
        be = sc_get_backedge_taken_count(l, BTC_EXACT);
    }
    if sc_is_cnc(max_be) { return false; }
    // getStartAndEndForAccess with this function's LoopGuards optional (laa.goose keeps it in lai_guards)
    let sl = lai_l; let sf = lai_fv; let sg = lai_guards;
    lai_l = l; lai_fv = block_func(loop_header(l)); lai_guards = -1;
    let a_start, a_end = laa_start_end_for_access(l, ptr_scev, esz_scev, be, max_be, false);
    var guards = lai_guards;
    lai_l = sl; lai_fv = sf; lai_guards = sg;
    if sc_is_cnc(a_start) || sc_is_cnc(a_end) { return false; }
    let diff = sc_get_minus(a_end, a_start, 0, 0);
    if sc_is_cnc(diff) { return false; }
    if guards < 0 { guards = sc_loop_guards_collect(sc_loop(ptr_scev)); }
    let max_diff = sc_get_unsigned_range_max(sc_apply_loop_guards_g(diff, guards));
    var base: i32 = -1;
    var asize = max_diff;
    var asize_scev: i32 = -1;
    if sc_is_unknown(a_start) {
        base = sc_value(a_start);
        asize_scev = diff;
    } else if sc_kind(a_start) == SC_ADD {
        if sc_nops(a_start) != 2 { return false; }
        let off = sc_op(a_start, 0);
        let nb = sc_op(a_start, 1);
        if !sc_is_const(off) || !sc_is_unknown(nb) { return false; }
        let oa = sc_ap(off);
        if ap_is_neg(oa) { return false; }
        if !ap_is_zero(ap_urem(oa, ap_u64(align as u64, oa.w as i64))) { return false; }
        let s, ov = ap_uadd_ov(max_diff, oa);
        if ov { return false; }
        asize = s;
        asize_scev = sc_add(diff, off);
        base = sc_value(nb);
    } else {
        return false;
    }
    var cxt = first_non_phi(loop_header(l));
    let lp = loop_predecessor(l);
    if lp >= 0 {
        let t = block_terminator(lp);
        if iop(t) == OP_BR || iop(t) == OP_CONDBR { cxt = t; }
    }
    if lv_deref_via_assumption_scev(base, align, asize_scev, guards, cxt) { return true; }
    return lv_deref_aligned_ptr(base, align, asize, cxt);
}

// isReadOnlyLoop: (read only, non-dereferenceable loads into out)
fn lv_is_read_only_loop(l: i32, out: i32[>..<]&) -> bool {
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            if iop(i) == OP_LOAD {
                if !lv_deref_aligned_in_loop(i, l, true) { out.push(i); }
            } else if inst_may_read_memory(i) || inst_may_write_memory(i) || inst_may_throw(i) {
                return false;
            }
            i = inst_next(i);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Legality checks

// isConsecutivePtr(AccessTy, Ptr)
fn lvl_is_consecutive_ptr(at: i32, ptr: i32) -> i64 {
    let sp = lai_pse;
    let sn = laa_no_strides;
    lai_pse = lvl_pse;
    laa_no_strides = !(lvl_lai_valid && lvl_allow_rt_scev);
    let ok, s = laa_get_ptr_stride_assume(at, ptr, lvl_l, lvl_allow_rt_scev, false);
    lai_pse = sp;
    laa_no_strides = sn;
    let stride = if ok { s } else { 0 };
    if stride == 1 || stride == -1 { return stride; }
    return 0;
}

// collectUnitStridePredicates
fn lvl_collect_unit_stride_predicates() {
    if !lvl_allow_rt_scev || !loop_is_innermost(lvl_l) { return; }
    for k in loop_nblocks(lvl_l) {
        var i = block_first(loop_block(lvl_l, k));
        while i >= 0 {
            let p = laa_ldst_ptr(i);
            if p >= 0 { lvl_is_consecutive_ptr(laa_ldst_type(i), p); }
            i = inst_next(i);
        }
    }
}

// SCEVAddRecForUniformityRewriter::rewrite
var lvu_cannot: bool = false;
recursive fn lvu_visit(s: i32, mult: i64, off: i64, l: i32) -> i32 {
    if lvu_cannot || sc_is_loop_invariant(s, l) { return s; }
    let k = sc_kind(s);
    if sc_is_cnc(s) { lvu_cannot = true; return s; }
    if sc_is_unknown(s) {
        lvu_cannot = true;
        return s;
    }
    if sc_is_addrec(s) {
        let ty = sc_ty(s);
        let step = sc_get_step_recurrence(s);
        if !sc_is_loop_invariant(step, l) { lvu_cannot = true; return s; }
        let nstep = sc_mul(step, sc_get_constant_ty(ty, mult as u64, false));
        let soff = sc_mul(step, sc_get_constant_ty(ty, off as u64, false));
        let nstart = sc_add(sc_op(s, 0), soff);
        return sc_addrec2(nstart, nstep, l, 0);
    }
    lvx_unported("SCEVAddRecForUniformityRewriter on this expression kind");
    return s;
}
fn lvu_contains_udiv(s: i32) -> bool {
    var wl: i32[>..<] = [];
    var seen = hm_new();
    wl.push(s);
    while wl.len > 0 {
        let x = wl.pop();
        if !ivd_set_add(seen, x) { continue; }
        if sc_kind(x) == SC_UDIV { return true; }
        for k in sc_nops(x) { wl.push(sc_op(x, k)); }
    }
    return false;
}
fn lvu_rewrite(s: i32, mult: i64, off: i64, l: i32) -> i32 {
    if !lvu_contains_udiv(s) { return SCEV_CNC; }
    lvu_cannot = false;
    let r = lvu_visit(s, mult, off, l);
    if !lvu_cannot { return r; }
    return SCEV_CNC;
}

// isUniform(V, VF): vf = 0 for std::nullopt
fn lvl_is_uniform(v: i32, vf: i64) -> bool {
    if lvl_is_invariant(v) { return true; }
    if vf == 0 { return false; }
    if vf == 1 { return true; }
    if !sc_is_scevable(vals[v].ty) { return false; }
    let s = sc_get_scev(v);
    let first = lvu_rewrite(s, vf, 0, lvl_l);
    if sc_is_cnc(first) { return false; }
    var i = vf - 1;
    while i >= 1 {
        if lvu_rewrite(s, vf, i, lvl_l) != first { return false; }
        i--;
    }
    return true;
}
// isUniformMemOp(I, VF)
fn lvl_is_uniform_mem_op(i: i32, vf: i64) -> bool {
    let p = laa_ldst_ptr(i);
    if p < 0 { return false; }
    return lvl_is_uniform(p, vf) && !lvl_block_needs_predication(inst_parent(i));
}

// blockNeedsPredication
fn lvl_block_needs_predication(bb: i32) -> bool {
    let latch = loop_latch(lvl_l);
    if latch < 0 { return false; }
    if lvl_has_uncountable_early_exit() { return bb == latch; }
    return laa_block_needs_predication(bb, lvl_l);
}

fn lv_is_noalias_scope_decl(i: i32) -> bool { iop(i) == OP_CALL && call_iid(i) == IID_experimental_noalias_scope_decl }
fn lv_has_vfabi_mappings(c: i32) -> bool {
    if iop(c) != OP_CALL { return false; }
    let fv = called_function(c);
    let has = call_has_fn_str_attr(c, "vector-function-abi-variant") || false;
    if has { lvx_unported("vector-function-abi-variant mappings (VFDatabase)"); }
    return false;
}

// blockCanBePredicated(BB, SafePtrs, MaskedOp)
fn lvl_block_can_be_predicated(bb: i32, safe: HMap&, masked: HMap&) -> bool {
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) == OP_CALL && call_iid(i) == IID_assume { hm_put(masked, i as u64, 1); i = inst_next(i); continue; }
        if lv_is_noalias_scope_decl(i) { i = inst_next(i); continue; }
        if iop(i) == OP_CALL && lv_has_vfabi_mappings(i) { hm_put(masked, i as u64, 1); i = inst_next(i); continue; }
        if iop(i) == OP_LOAD {
            if !hm_has(safe, op(i, 0) as u64) { hm_put(masked, i as u64, 1); }
            i = inst_next(i);
            continue;
        }
        if iop(i) == OP_STORE { hm_put(masked, i as u64, 1); i = inst_next(i); continue; }
        if inst_may_read_memory(i) || inst_may_write_memory(i) || inst_may_throw(i) { return false; }
        i = inst_next(i);
    }
    return true;
}

// CanSpeculatePointerOp in canVectorizeWithIfConvert
fn lvl_can_speculate_pointer_op(ptr: i32) -> bool {
    var wl: i32[>..<] = [];
    var visited = hm_new();
    wl.push(ptr);
    while wl.len > 0 {
        let cur = wl.pop();
        if !ivd_set_add(visited, cur) { continue; }
        if !is_inst(cur) || !ivd_contains_inst(lvl_l, cur) {
            let lp = loop_predecessor(lvl_l);
            let cxt = if lp >= 0 { block_terminator(lp) } else { -1 };
            // isGuaranteedNotToBePoison(CurrV, AC, CtxI, DT)
            let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
            kb_cxt = cxt; sq_no_dt = false; sq_no_ac = false;
            let ok = is_guaranteed_not_to_be_poison(cur, cxt, 0);
            kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
            if !ok { return false; }
            continue;
        }
        if iop(cur) == OP_LOAD {
            // isGuaranteedNotToBePoison(CurrV, AC)
            let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
            kb_cxt = -1; sq_no_dt = true; sq_no_ac = false;
            let ok = is_guaranteed_not_to_be_poison(cur, -1, 0);
            kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
            if !ok { return false; }
        }
        // isSafeToSpeculativelyExecute(CurrI) (no context, AC, DT, TLI)
        if iop(cur) != OP_PHI && !spec_safe(cur, -1, false) { return false; }
        for k in nops(cur) { wl.push(op(cur, k)); }
    }
    return true;
}

// canVectorizeWithIfConvert
fn lvl_can_vectorize_with_if_convert() -> bool {
    if !flag_bool("enable-if-conversion", true) { return false; }
    let l = lvl_l;
    var safe = hm_new();
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if !lvl_block_needs_predication(bb) {
            var i = block_first(bb);
            while i >= 0 {
                let p = laa_ldst_ptr(i);
                if p >= 0 { hm_put(safe, p as u64, 1); }
                i = inst_next(i);
            }
            continue;
        }
        var i = block_first(bb);
        while i >= 0 {
            if iop(i) == OP_LOAD && !ty_is_vector(vals[i].ty) && !must_suppress_speculation(i) &&
               lvl_can_speculate_pointer_op(op(i, 0)) && lv_deref_aligned_in_loop(i, l, true) {
                hm_put(safe, op(i, 0) as u64, 1);
            }
            i = inst_next(i);
        }
    }
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        let t = block_terminator(bb);
        if iop(t) == OP_SWITCH {
            if loop_is_exiting(l, bb) { return false; }
        } else if iop(t) != OP_BR && iop(t) != OP_CONDBR {
            return false;
        }
        if lvl_block_needs_predication(bb) && !lvl_block_can_be_predicated(bb, safe, lvl_cond_ops) { return false; }
    }
    return true;
}

// canVectorizeLoopCFG (inner loop)
fn lvl_can_vectorize_loop_cfg(lp: i32) -> bool {
    if loop_preheader(lp) < 0 { return false; }
    if loop_num_back_edges(lp) != 1 { return false; }
    let latch = loop_latch(lp);
    if latch >= 0 {
        let t = iop(block_terminator(latch));
        if t != OP_BR && t != OP_CONDBR { return false; }
    }
    return true;
}

// VectorType::isValidElementType
fn lv_valid_elem_ty(t: i32) -> bool { ty_is_int(t) || ty_is_fp(t) || ty_kind(t) == TK_PTR || ty_kind(t) == TK_BYTE }
// canVectorizeTy
fn lv_can_vectorize_ty(t: i32) -> bool {
    if ty_is_struct(t) {
        lvx_unported("struct-typed values in a vectorizable loop");
    }
    return ty_kind(t) == TK_VOID || lv_valid_elem_ty(t);
}

// canVectorizeInstr(I)
fn lvl_can_vectorize_instr(i: i32) -> bool {
    let bb = inst_parent(i);
    let header = loop_header(lvl_l);
    if iop(i) == OP_PHI {
        let t = vals[i].ty;
        if !ty_is_int(t) && !ty_is_fp(t) && ty_kind(t) != TK_PTR { return false; }
        if bb != header { return true; }
        if phi_nincoming(i) != 2 { return false; }
        let rd = rdx_is_reduction_phi(i, lvl_l);
        if rd >= 0 {
            lvl_add_exact_fp(rdx_descs[rd].exact_fp);
            hm_put(lvl_rdx_map, i as u64, lvl_rdx_phis.len);
            lvl_rdx_phis.push(i);
            lvl_rdx_desc.push(rd);
            return true;
        }
        let strided_ok = flag_bool("lv-strided-pointer-ivs", false);
        let id = ind_is_induction_phi(i, lvl_l, lvl_pse, false);
        if id >= 0 && !(!strided_ok && ind_descs[id].kind == IK_PTR && ind_const_step(id) < 0) {
            lvl_add_induction_phi(i, id);
            lvl_add_exact_fp(ind_exact_fp(id));
            return true;
        }
        if rdx_is_fixed_order_recurrence(i, lvl_l) {
            if ivd_set_add(lvl_fors_set, i) { lvl_fors.push(i); }
            return true;
        }
        let id2 = ind_is_induction_phi(i, lvl_l, lvl_pse, true);
        if id2 >= 0 && !(!strided_ok && ind_descs[id2].kind == IK_PTR && ind_const_step(id2) < 0) {
            lvl_add_induction_phi(i, id2);
            return true;
        }
        return false;
    }
    let is_ci = iop(i) == OP_CALL;
    if is_ci {
        let iid = laa_vector_intrinsic_id_for_call(i);
        // VFDatabase::getMappings / isTLIScalarize (no vector library in our opt)
        if iid == 0 && !(called_function(i) >= 0 && lv_has_vfabi_mappings(i)) { return false; }
        for k in cb_nargs(i) {
            if vu_scalar_op_at_arg(iid, k, true) {
                if !sc_is_loop_invariant(pse_get_scev(lvl_pse, cb_arg(i, k)), lvl_l) { return false; }
            }
        }
    }
    // CanWidenInstructionTy
    let t = vals[i].ty;
    var can_widen = true;
    if ty_is_struct(t) {
        lvx_unported("struct-typed values in a vectorizable loop");
    } else {
        can_widen = lv_can_vectorize_ty(t);
    }
    if !can_widen || (is_cast_op(iop(i)) && !lv_valid_elem_ty(vals[op(i, 0)].ty)) || iop(i) == OP_EXTRACTELEMENT { return false; }
    if iop(i) == OP_STORE {
        let st = vals[op(i, 0)].ty;
        if !lv_valid_elem_ty(st) { return false; }
        if inst_get_md(i, md_kind_id("nontemporal")) >= 0 {
            let vt = ty_vector(st, 2, false);
            if !lv_tti_legal_nt_store(vt, lv_ld_align(i)) { return false; }
        }
    } else if iop(i) == OP_LOAD {
        if inst_get_md(i, md_kind_id("nontemporal")) >= 0 {
            let vt = ty_vector(vals[i].ty, 2, false);
            if !lv_tti_legal_nt_load(vt, lv_ld_align(i)) { return false; }
        }
    } else if ty_is_fp(vals[i].ty) && (is_ci || (iop(i) >= OP_ADD && iop(i) <= OP_XOR)) && !ivd_is_fast(i) {
        lvh_potentially_unsafe = true;
    }
    return true;
}

fn lv_tti_legal_nt_store(t: i32, align: i64) -> bool {
    if tti_kind == TTI_X86 { return x86_is_legal_nt_store(t, align); }
    // TargetTransformInfoImplBase::isLegalNTStore: Alignment >= DataSize && isPowerOf2(DataSize)
    let ds = dl_store_size(t);
    return align >= ds && (ds & (ds - 1)) == 0;
}
fn lv_tti_legal_nt_load(t: i32, align: i64) -> bool {
    if tti_kind == TTI_X86 { return x86_is_legal_nt_load(t, align); }
    let ds = dl_store_size(t);
    return align >= ds && (ds & (ds - 1)) == 0;
}

// canVectorizeInstrs
fn lvl_can_vectorize_instrs() -> bool {
    for k in loop_nblocks(lvl_l) {
        var i = block_first(loop_block(lvl_l, k));
        while i >= 0 {
            if !lvl_can_vectorize_instr(i) { return false; }
            i = inst_next(i);
        }
    }
    if lvl_primary < 0 {
        if lvl_ind_phis.len == 0 { return false; }
        if lvl_widest_ind_ty < 0 { return false; }
    }
    if lvl_primary >= 0 && lvl_widest_ind_ty != vals[lvl_primary].ty { lvl_primary = -1; }
    return true;
}

// isVectorizableEarlyExitLoop
fn lvl_is_vectorizable_early_exit_loop() -> bool {
    let l = lvl_l;
    let latch = loop_latch(l);
    if latch < 0 { return false; }
    if lvl_rdx_phis.len != 0 || lvl_fors.len != 0 { return false; }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    var uncountable: i32[>..<] = [];
    for bb in exiting {
        let m = sc_out_preds.len;
        let ec = sc_get_exit_count(l, bb, BTC_EXACT, true);
        sc_out_preds.resize(m);
        if sc_is_cnc(ec) {
            if block_nsucc(bb) != 2 { return false; }
            uncountable.push(bb);
        } else {
            lvl_countable_exiting.push(bb);
        }
    }
    if uncountable.len == 0 { return false; }
    let m = sc_out_preds.len;
    let lec = sc_get_exit_count(l, latch, BTC_EXACT, true);
    sc_out_preds.resize(m);
    if sc_is_cnc(lec) { return false; }
    var side_effects = false;
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            if inst_may_write_memory(i) {
                if iop(i) == OP_STORE && ldst_is_simple_lv(i) { side_effects = true; i = inst_next(i); continue; }
                return false;
            }
            let o = iop(i);
            if !(o == OP_LOAD || o == OP_STORE || o == OP_PHI || o == OP_BR || o == OP_CONDBR) {
                if !spec_safe(i, -1, false) { return false; }
            }
            i = inst_next(i);
        }
    }
    var non_deref: i32[>..<] = [];
    if !side_effects {
        if !lv_is_read_only_loop(l, non_deref) { return false; }
    } else {
        lvx_unported("early-exit loops with side effects (canUncountableExitConditionLoadBeMoved)");
    }
    for li in non_deref {
        if lvl_is_consecutive_ptr(vals[li].ty, op(li, 0)) != 1 { return false; }
    }
    pse_get_symbolic_max_btc(lvl_pse);
    lvl_uncountable = if side_effects { 2 } else { 1 };
    return true;
}
fn ldst_is_simple_lv(i: i32) -> bool { (insts[inst_of(i)].bits & 1) == 0 && insts[inst_of(i)].ord == 0 }

// isInvariantStoreOfReduction / isInvariantAddressOfReduction
fn lvl_is_invariant_store_of_reduction(si: i32) -> bool {
    for d in lvl_rdx_desc { if rdx_descs[d].store == si { return true; } }
    return false;
}
fn lvl_is_invariant_address_of_reduction(v: i32) -> bool {
    for d in lvl_rdx_desc {
        let st = rdx_descs[d].store;
        if st < 0 { continue; }
        let a = op(st, 1);
        if v == a || sc_get_scev(v) == sc_get_scev(a) { return true; }
    }
    return false;
}

// canVectorizeMemory
fn lvl_can_vectorize_memory() -> bool {
    lai_compute(lvl_l, false);
    lvl_lai_valid = true;
    if !lai_can_vec_mem {
        if lvl_has_uncountable_exit_with_side_effects() { return false; }
        // canVectorizeIndirectUnsafeDependences
        if flag_bool("enable-histogram-loop-vectorization", false) { lvx_unported("histogram vectorization"); }
        return false;
    }
    if lai_ld_st_inv { return false; }
    if lai_stores_to_inv.len != 0 {
        for si in lai_stores_to_inv {
            if !lvl_is_invariant_store_of_reduction(si) { continue; }
            if lvl_block_needs_predication(inst_parent(si)) { return false; }
            let p = op(si, 1);
            if is_inst(p) && ivd_contains_inst(lvl_l, p) { return false; }
        }
        if lai_st_st_inv {
            var unhandled: i32[>..<] = [];
            for si in lai_stores_to_inv {
                if lvl_is_invariant_store_of_reduction(si) {
                    var keep: i32[>..<] = [];
                    for x in unhandled {
                        let same = x == si || op(x, 1) == op(si, 1) || sc_get_scev(op(x, 1)) == sc_get_scev(op(si, 1));
                        if !(same && vals[op(x, 0)].ty == vals[op(si, 0)].ty) { keep.push(x); }
                    }
                    unhandled.clear();
                    for x in keep { unhandled.push(x); }
                    continue;
                }
                unhandled.push(si);
            }
            if unhandled.len != 0 { return false; }
        }
    }
    // PSE.addPredicate(LAI->getPSE().getPredicate())
    let u = pse_union(lai_pse);
    for k in su_n(u) { pse_add_predicate(lvl_pse, su_get(u, k)); }
    return true;
}

// canVectorizeFPMath(EnableStrictReductions)
fn lvl_can_vectorize_fp_math(strict: bool) -> bool {
    if lvl_exact_fp < 0 || lvh_allow_reordering() { return true; }
    if !strict { return false; }
    for d in lvl_ind_desc { if ind_exact_fp(d) >= 0 { return false; } }
    for d in lvl_rdx_desc {
        if rdx_descs[d].exact_fp >= 0 && !rdx_descs[d].ordered { return false; }
    }
    return true;
}

// canVectorize(UseVPlanNativePath)
fn lvl_can_vectorize() -> bool {
    if !lvl_can_vectorize_loop_cfg(lvl_l) { return false; }
    if !loop_is_innermost(lvl_l) { lvx_unported("outer-loop vectorization (VPlan-native path)"); }
    if loop_nblocks(lvl_l) != 1 && !lvl_can_vectorize_with_if_convert() { return false; }
    if !lvl_can_vectorize_instrs() { return false; }
    if sc_is_cnc(pse_get_backedge_taken_count(lvl_pse)) {
        if loop_exiting_block(lvl_l) >= 0 { return false; }
        if !lvl_is_vectorizable_early_exit_loop() { return false; }
    }
    if !lvl_can_vectorize_memory() { return false; }
    if lvl_uncountable != 0 && lai_stores_to_inv.len != 0 { return false; }
    return true;
}


// canFoldTailByMasking
fn lvl_can_fold_tail_by_masking() -> bool {
    if loop_exiting_block(lvl_l) != loop_latch(lvl_l) { return false; }
    var safe = hm_new();
    var tmp = hm_new();
    for k in loop_nblocks(lvl_l) {
        if !lvl_block_can_be_predicated(loop_block(lvl_l, k), safe, tmp) { return false; }
    }
    return true;
}
// prepareToFoldTailByMasking
fn lvl_prepare_to_fold_tail_by_masking() {
    var safe = hm_new();
    for k in loop_nblocks(lvl_l) { lvl_block_can_be_predicated(loop_block(lvl_l, k), safe, lvl_tail_ops); }
}

// LoopBlocksDFS::perform: the loop's blocks in post order (DFS from the header over in-loop successors)
fn lv_loop_postorder(l: i32, out: i32[>..<]&) {
    out.clear();
    var visited = hm_new();
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    let h = loop_header(l);
    hm_put(visited, h as u64, 1);
    st_b.push(h);
    st_k.push(0);
    while st_b.len > 0 {
        let top = st_b.len - 1;
        let b = st_b[top];
        let k = st_k[top];
        if k < block_nsucc(b) {
            st_k[top] = k + 1;
            let s = block_succ(b, k);
            if loop_contains(l, s) && !hm_has(visited, s as u64) {
                hm_put(visited, s as u64, 1);
                st_b.push(s);
                st_k.push(0);
            }
            continue;
        }
        out.push(b);
        st_b.pop();
        st_k.pop();
    }
}

