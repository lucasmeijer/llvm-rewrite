// The legacy LoopVectorizationCostModel costs of llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (LLVM 23.1.5):
// getInstructionCost and its helpers (getMemoryInstructionCost, getMemInstScalarizationCost,
// getConsecutiveMemOpCost, getUniformMemOpCost, getGatherScatterCost, getScalarizationOverhead,
// getVectorCallCost, getVectorIntrinsicCost, getDivRemSpeculationCost, shouldConsiderInvariant,
// getPredBlockCostDivisor, useEmulatedMaskMemRefHack, needsExtract / filterExtractingOperands),
// setCostBasedWideningDecision, collectInstsToScalarize / computePredInstDiscount, expectedCost and
// collectNonVectorizedAndSetWideningDecisions.
//
// Costs: InstructionCost is fixed point with CostGranularity 4; an "lc" is the raw Value (4 * the cost), LC_INVALID
// the invalid state (it compares above every valid cost, like InstructionCost's (State, Value) order). TTI answers
// (tti*.goose, plain integer costs with TTI_INVALID) are converted with lcv.
import std;
import os;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import gen_x86target;
import datalayout;
import pm;
import apint;
import speculate;
import loopinfo;
import scev;
import scev_create;
import scev_eval;
import pse;
import laa;
import bfi;
import tti;
import tti_x86;
import tti_vec;
import tti_x86_vec;
import tti_x86_intr;
import iv_descriptors;
import lv_legality;
import lv_interleave;
import lv_cm;
import lv_pass;
import lv_minbw;

let LC_INVALID: i64 = 0x7FFFFFFFFFFFFFFF;
let LC_MAX: i64 = 0x7FFFFFFFFFFFFFFE;    // InstructionCost::getMax()
let LC_MIN: i64 = -0x7FFFFFFFFFFFFFFE;
fn lc_valid(c: i64) -> bool { c != LC_INVALID }
// saturating a + b and a * n
fn lc_sat_add(a: i64, b: i64) -> i64 {
    if b > 0 && a > LC_MAX - b { return LC_MAX; }
    if b < 0 && a < LC_MIN - b { return LC_MIN; }
    return a + b;
}
fn lc_sat_mul(a: i64, n: i64) -> i64 {
    if a == 0 || n == 0 { return 0; }
    let aa = if a < 0 { -a } else { a };
    let an = if n < 0 { -n } else { n };
    if aa > LC_MAX / an { return if (a > 0) == (n > 0) { LC_MAX } else { LC_MIN }; }
    return a * n;
}
// InstructionCost(TTI cost)
fn lcv(c: i64) -> i64 { if !tc_valid(c) { LC_INVALID } else { lc_sat_mul(c, 4) } }
fn lc_add(a: i64, b: i64) -> i64 { if a == LC_INVALID || b == LC_INVALID { LC_INVALID } else { lc_sat_add(a, b) } }
fn lc_sub(a: i64, b: i64) -> i64 { if a == LC_INVALID || b == LC_INVALID { LC_INVALID } else { lc_sat_add(a, -b) } }
// InstructionCost * CostType
fn lc_mul(a: i64, n: i64) -> i64 { if a == LC_INVALID { LC_INVALID } else { lc_sat_mul(a, n) } }
// InstructionCost / CostType (on the raw value)
fn lc_div(a: i64, n: i64) -> i64 { if a == LC_INVALID { LC_INVALID } else { a / n } }
fn lc_min(a: i64, b: i64) -> i64 { if b < a { b } else { a } }
// getValue()
fn lc_value(c: i64) -> i64 { c / 4 }
// InstructionCost::print
fn lc_str(c: i64, out: u8[>..]&) {
    if c == LC_INVALID { out.append("Invalid"); return; }
    let a = if c < 0 { -c } else { c };
    let whole = a / 4;
    var rem = (a % 4) * 100 / 4;
    while rem % 10 == 0 && rem != 0 { rem /= 10; }
    if c < 0 { out.push('-'); }
    format(out, whole);
    if rem != 0 { out.push('.'); format(out, rem); }
}

// ---------------------------------------------------------------------------------------------
// -debug-only=loop-vectorize style tracing (GOOSE_LV_DEBUG=1), for tools/lv_cost_compare.py

var lv_dbg_state: i64 = -1;
fn lv_dbg_on() -> bool {
    if lv_dbg_state < 0 {
        var v: u8[>..] = [];
        lv_dbg_state = if env("GOOSE_LV_DEBUG", v) && v.len > 0 && v[0] != '0' { 1 } else { 0 };
    }
    return lv_dbg_state == 1;
}
fn lv_dbg(s: const u8[:]) { if lv_dbg_on() { write_stderr(s); } }
// "Cost of C for VF V: what"
fn lv_dbg_cost(prefix: const u8[:], c: i64, vf: i64, what: const u8[:]) {
    if !lv_dbg_on() { return; }
    var s: u8[>..] = [];
    s.append(prefix);
    lc_str(c, s);
    s.append(" for VF ");
    format(s, vf);
    s.append(what);
    s.push('\n');
    write_stderr(s);
}
fn lv_dbg_inst_name(i: i32, out: u8[>..]&) {
    out.append(" opcode ");
    format(out, iop(i));
    let n = vals[i].name;
    if n >= 0 { out.append(" %"); out.append(sbytes(n)); }
}

// ---------------------------------------------------------------------------------------------
// TTI queries in the lc domain (CostKind is always TCK_RecipThroughput for the loop vectorizer)

let LV_KIND: i64 = 0;
fn lt_arith(o: i64, ty: i32, oi1: i64, oi2: i64, a0: i32, a1: i32, nargs: i64, cxt: i32) -> i64 {
    if tti_kind != TTI_X86 { return lcv(base_arith_cost(o, ty, LV_KIND, a0, a1)); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_arith_cost(o, ty, LV_KIND, oi1, oi2, a0, a1, nargs, cxt);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
fn lt_arith0(o: i64, ty: i32) -> i64 { lt_arith(o, ty, 0, 0, -1, -1, 0, -1) }
fn lt_cast(o: i64, dst: i32, src: i32, cch: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return lcv(base_cast_cost(o, dst, src)); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_cast_cost(o, dst, src, cch, LV_KIND, i);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
fn lt_cf(o: i64) -> i64 { lcv(tti_cf_cost(o, LV_KIND)) }
fn lt_cmpsel(o: i64, valty: i32, condty: i32, pred: i64, oi1: i64, oi2: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return lcv(1); }
    let p = if pred < 0 { PRED_BAD_ICMP } else { pred };
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_cmpsel_cost(o, valty, condty, p, LV_KIND, oi1, oi2, i);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
fn lt_mem(o: i64, ty: i32, align: i64, as_: i64, opinfo: i64, i: i32) -> i64 {
    if tti_kind != TTI_X86 { return lcv(1); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_memory_op_cost(o, ty, align, as_, LV_KIND, opinfo, i);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
fn lt_shuffle(sk: i64, ty: i32, index: i64) -> i64 { lcv(tv_shuffle(sk, ty, ty, [], LV_KIND, index, -1, -1, -1, 0, -1)) }
// getScalarizationOverhead(Ty, all ones, Insert, Extract, CostKind)
fn lt_scalarization_all(ty: i32, insert: bool, extract: bool) -> i64 {
    if !ty_is_vector(ty) { return 0; }
    if tti_kind != TTI_X86 { return 0; }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_scalarization_overhead_all(ty, insert, extract, LV_KIND);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
// getOperandsScalarizationOverhead(Tys, CostKind)
fn lt_operands_scalarization(tys: const i32[:]) -> i64 {
    if tti_kind != TTI_X86 { return 0; }
    let m = mk_mark();
    let im = ica_mark();
    let c = bt_operands_scalarization_overhead(tys, LV_KIND);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
fn lt_vec_inst(o: i64, ty: i32, index: i64) -> i64 { lcv(tv_vec_inst(o, ty, index, -1, -1, LV_KIND)) }
// getIndexedVectorInstrCostFromEnd
fn lt_vec_inst_from_end(o: i64, ty: i32, index: i64) -> i64 { lt_vec_inst(o, ty, ty_count(ty) - 1 - index) }
// getAddressComputationCost(PtrTy, SE (has_se), Ptr, CostKind); ptr_scev -1 = nullptr
fn lt_address_computation(ptrty: i32, has_se: bool, ptr_scev: i32) -> i64 {
    if tti_kind != TTI_X86 { return 0; }
    if ty_is_vector(ptrty) && has_se && !x86_has(X86F_FeatureAVX2) {
        // isStridedAccess: an AddRec; getConstantStrideStep: a constant step
        if ptr_scev < 0 || !sc_is_addrec(ptr_scev) { return lcv(10); }
        if !sc_is_const(sc_op(ptr_scev, 1)) { return lcv(1); }
    }
    return 0;
}
// getMemIntrinsicInstrCost(MemIntrinsicCostAttributes(IID, DataTy, Ptr, VariableMask, Alignment, AS))
fn lt_mem_intrinsic(id: i32, data: i32, ptr: i32, variable_mask: bool, align: i64, as_: i64) -> i64 {
    if tti_kind != TTI_X86 { return lcv(1); }
    let m = mk_mark();
    let im = ica_mark();
    let c = x86_mem_intrinsic_cost(id, data, ptr, variable_mask, align, as_, LV_KIND);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
// getIntrinsicInstrCost(IntrinsicCostAttributes(ID, RetTy, Tys)) (type-based)
fn lt_intrinsic_types(id: i32, rt: i32, tys: const i32[:], fmf: u8) -> i64 { lcv(tv_intrinsic_types(id, rt, tys, fmf, LV_KIND)) }
// getCallInstrCost: BasicTTIImplBase returns 10, TargetTransformInfoImplBase 1
fn lt_call() -> i64 { if tti_kind == TTI_X86 { lcv(10) } else { lcv(1) } }
// getNumberOfParts
fn lt_number_of_parts(ty: i32) -> i64 {
    if tti_kind != TTI_X86 { return 1; }
    return x86_number_of_parts(ty);
}
// prefersVectorizedAddressing: X86 supportsGather(); the base: true
fn lt_prefers_vectorized_addressing() -> bool { tti_kind != TTI_X86 || x86_supports_gather() }
fn lt_is_legal_masked_scatter(ty: i32) -> bool { tti_kind == TTI_X86 && x86_is_legal_masked_scatter(ty) }

// -force-target-instruction-cost
fn lv_has_forced_cost() -> bool { flag_given("force-target-instruction-cost") }
fn lv_forced_cost() -> i64 { lcv(flag_int("force-target-instruction-cost", 0)) }

// toVectorTy / toVectorizedTy (struct-typed values fail loudly)
fn lv_vec_ty(t: i32, vf: i64) -> i32 {
    if vf == 1 || t == T_VOID || ty_kind(t) == TK_METADATA { return t; }
    if ty_is_struct(t) { vp_unported_cm("struct-typed values in the cost model (toVectorizedTy)"); }
    return ty_vector(t, vf, false);
}
fn lv_maybe_vectorize_type(t: i32, vf: i64) -> i32 { if vf == 1 || !lv_can_vectorize_ty(t) { t } else { lv_vec_ty(t, vf) } }
// CmpInst::makeCmpResultType
fn lvc_cmp_result_type(t: i32) -> i32 { if ty_is_vector(t) { ty_vector(T_I1, ty_count(t), false) } else { T_I1 } }
fn lv_ptr_as(t: i32) -> i64 { types[ty_scalar(t)].n as i64 }

// ---------------------------------------------------------------------------------------------
// cost-model state

var cm_pse: i32 = -1;
var cm_num_pred_stores: i64 = 0;
var cm_pbb = hm_new();              // PredicatedBBsAfterVectorization: (VF, BB)
var cm_its_vfs: i64[>..<];          // VFs with InstsToScalarize computed
var cm_its_cost = hm_new();         // InstsToScalarize: (VF, I) -> cost
var cm_forced_list: i64[>..<];      // ForcedScalars in insertion order: keys (VF, I)
var cm_its_list: i64[>..<];         // InstsToScalarize in insertion order: keys (VF, I)
var cm_ep_allowed: bool = true;     // isEpilogueAllowed()

fn lvc_reset(pse: i32, ep_allowed: bool) {
    cm_pse = pse;
    cm_num_pred_stores = 0;
    hm_clear(cm_pbb); cm_its_vfs.clear(); hm_clear(cm_its_cost); cm_forced_list.clear(); cm_its_list.clear();
    cm_ep_allowed = ep_allowed;
}

fn cm_widening_cost(i: i32, vf: i64) -> i64 {
    let k = cm_key(vf, i);
    if !hm_has(cm_wd_cost, k) { fatal("internal: loop-vectorize: The cost is not calculated"); }
    return hm_get(cm_wd_cost, k, 0);
}
fn cm_is_forced_scalar(i: i32, vf: i64) -> bool { vf > 1 && hm_has(cm_forced, cm_key(vf, i)) }

// getPredBlockCostDivisor(CostKind, BB)
fn cm_pred_block_cost_divisor(bb: i32) -> i64 {
    if !lvl_block_needs_predication(bb) { return 1; }
    let f = inst_func(block_first(bb));
    bfi_get(f);
    let hf = bfi_freq(loop_header(cm_l));
    let bf = bfi_freq(bb);
    if bf == 0 { vp_unported_cm("a zero block frequency in getPredBlockCostDivisor"); }
    let d = (hf as f64) / (bf as f64);
    return (d + 0.5) as i64;
}
// useEmulatedMaskMemRefHack(I, VF)
fn cm_use_emulated_mask_mem_ref_hack(i: i32, vf: i64) -> bool {
    return iop(i) == OP_LOAD || (iop(i) == OP_STORE && cm_num_pred_stores > flag_int("vectorize-num-stores-pred", 1));
}
// needsExtract(V, VF)
fn cm_needs_extract(v: i32, vf: i64) -> bool {
    if vf == 1 || !is_inst(v) || !loop_contains(cm_l, inst_parent(v)) || cm_get_widening_decision(v, vf) == CM_SCALARIZE { return false; }
    var scal_done = false;
    for x in cm_uni_vfs { if x == vf { scal_done = true; } }
    return !scal_done || !cm_is_scalar_after_vectorization(v, vf);
}
// filterExtractingOperands(Ops, VF): the operand types (maybeVectorizeType) of the operands needing extraction
fn cm_extracting_operand_types(i: i32, call_args: bool, vf: i64, tys: i32[>..<]&) {
    let n = if call_args { cb_nargs(i) } else { nops(i) };
    var seen: i32[>..<] = [];
    for k in n {
        let o = op(i, k);
        if is_constant(o) { continue; }
        var dup = false;
        for s in seen { if s == o { dup = true; } }
        if dup { continue; }
        seen.push(o);
        if !cm_needs_extract(o, vf) { continue; }
        tys.push(lv_maybe_vectorize_type(vals[o].ty as i32, vf));
    }
}

// LoopVectorizationCostModel::getScalarizationOverhead(I, VF)
fn cm_scalarization_overhead(i: i32, vf: i64) -> i64 {
    if vf == 1 { return 0; }
    var c: i64 = 0;
    let rt = lv_vec_ty(vals[i].ty as i32, vf);
    let o = iop(i);
    // supportsEfficientVectorElementLoadStore() is false on X86 and the base
    if rt != T_VOID { c = lc_add(c, lt_scalarization_all(rt, true, false)); }
    if o == OP_LOAD && !lt_prefers_vectorized_addressing() { return c; }
    var tys: i32[>..<] = [];
    cm_extracting_operand_types(i, o == OP_CALL, vf, tys);
    return lc_add(c, lt_operands_scalarization(tys));
}

// vputils::isAddressSCEVForCost
fn lv_is_address_scev_for_cost(a: i32, l: i32) -> bool {
    fn affine_ar(s: i32) -> bool { sc_is_addrec(s) && sc_nops(s) == 2 }
    if sc_kind(a) == SC_ADD {
        for k in sc_nops(a) {
            let o = sc_op(a, k);
            if sc_is_loop_invariant(o, l) { continue; }
            if sc_kind(o) == SC_SEXT && affine_ar(sc_op(o, 0)) { continue; }
            if affine_ar(o) { continue; }
            return false;
        }
        return true;
    }
    return sc_is_loop_invariant(a, l) || affine_ar(a);
}
// getAddressAccessSCEV(Ptr, PSE, L): -1 = nullptr
fn cm_address_access_scev(ptr: i32) -> i32 {
    let a = pse_get_scev(cm_pse, ptr);
    return if lv_is_address_scev_for_cost(a, cm_l) { a } else { -1 };
}

// getMemInstScalarizationCost(I, VF)
fn cm_mem_inst_scalarization_cost(i: i32, vf: i64) -> i64 {
    let vt = laa_ldst_type(i);
    let ptr = laa_ldst_ptr(i);
    let as_ = lv_ptr_as(vals[ptr].ty as i32);
    let pty = lv_vec_ty(vals[ptr].ty as i32, vf);
    let ps = cm_address_access_scev(ptr);
    var c = lc_mul(lt_address_computation(pty, true, ps), vf);
    c = lc_add(c, lc_mul(lt_mem(iop(i), ty_scalar(vt), cm_ld_align(i), as_, tti_operand_info(op(i, 0)), -1), vf));
    c = lc_add(c, cm_scalarization_overhead(i, vf));
    if cm_is_predicated_inst(i) {
        c = lc_div(c, cm_pred_block_cost_divisor(inst_parent(i)));
        c = lc_add(c, lt_scalarization_all(ty_vector(T_I1, vf, false), false, true));
        c = lc_add(c, lt_cf(OP_CONDBR));
        if cm_use_emulated_mask_mem_ref_hack(i, vf) { c = lcv(3000000); }
    }
    return c;
}
// getConsecutiveMemOpCost(I, VF, Kind)
fn cm_consecutive_mem_op_cost(i: i32, vf: i64, kind: i64) -> i64 {
    let vt = lv_vec_ty(laa_ldst_type(i), vf);
    let as_ = lv_ptr_as(vals[laa_ldst_ptr(i)].ty as i32);
    let align = cm_ld_align(i);
    var c: i64 = 0;
    if cm_is_mask_required(i) {
        let id = if iop(i) == OP_LOAD { IID_masked_load } else { IID_masked_store };
        c = lc_add(c, lt_mem_intrinsic(id as i32, vt, -1, true, align, as_));
    } else {
        c = lc_add(c, lt_mem(iop(i), vt, align, as_, tti_operand_info(op(i, 0)), i));
    }
    if kind == CM_WIDEN_REVERSE { c = lc_add(c, lt_shuffle(SK_REVERSE, vt, 0)); }
    return c;
}
// getUniformMemOpCost(I, VF)
fn cm_uniform_mem_op_cost(i: i32, vf: i64) -> i64 {
    let vt = laa_ldst_type(i);
    let pty = vals[laa_ldst_ptr(i)].ty as i32;
    let vty = lv_vec_ty(vt, vf);
    let align = cm_ld_align(i);
    let as_ = lv_ptr_as(pty);
    if iop(i) == OP_LOAD {
        return lc_add(lc_add(lt_address_computation(pty, false, -1), lt_mem(OP_LOAD, vt, align, as_, 0, -1)),
                      lt_shuffle(SK_BROADCAST, vty, 0));
    }
    var c = lc_add(lt_address_computation(pty, false, -1), lt_mem(OP_STORE, vt, align, as_, 0, -1));
    if !lvl_is_invariant(op(i, 0)) { c = lc_add(c, lt_vec_inst_from_end(OP_EXTRACTELEMENT, vty, 0)); }
    return c;
}
// getGatherScatterCost(I, VF)
fn cm_gather_scatter_cost(i: i32, vf: i64) -> i64 {
    let vty = lv_vec_ty(laa_ldst_type(i), vf);
    let align = cm_ld_align(i);
    let ptr = laa_ldst_ptr(i);
    var pty = vals[ptr].ty as i32;
    if !lvl_is_uniform(ptr, vf) { pty = lv_vec_ty(pty, vf); }
    let id = if iop(i) == OP_LOAD { IID_masked_gather } else { IID_masked_scatter };
    return lc_add(lt_address_computation(pty, false, -1), lt_mem_intrinsic(id as i32, vty, ptr, cm_is_mask_required(i), align, 0));
}
// canTruncateToMinimalBitwidth(I, VF) (i = -1: not an instruction)
fn cm_can_truncate_to_minimal_bitwidth(i: i32, vf: i64) -> bool {
    if i < 0 || !hm_has(lmb_map, i as u64) { return false; }
    let mb = lmb_lookup(i);
    if iop(i) == OP_TRUNC && ty_bits(ty_scalar(vals[i].ty)) < mb { return false; }
    return vf > 1 && !cm_is_profitable_to_scalarize(i, vf) && !cm_is_scalar_after_vectorization(i, vf);
}
// getMemoryInstructionCost(I, VF)
fn cm_memory_instruction_cost(i: i32, vf: i64) -> i64 {
    if vf == 1 {
        let vt = laa_ldst_type(i);
        let pty = vals[laa_ldst_ptr(i)].ty as i32;
        return lc_add(lt_address_computation(pty, false, -1),
                      lt_mem(iop(i), vt, cm_ld_align(i), lv_ptr_as(pty), tti_operand_info(op(i, 0)), i));
    }
    return cm_widening_cost(i, vf);
}

// getDivRemSpeculationCost(I, VF): (scalarization cost, masked intrinsic cost)
fn cm_div_rem_speculation_cost(i: i32, vf: i64) -> i64, i64 {
    var sc = lc_mul(lt_cf(OP_PHI), vf);
    sc = lc_add(sc, lc_mul(lt_arith0(iop(i), vals[i].ty as i32), vf));
    sc = lc_add(sc, cm_scalarization_overhead(i, vf));
    sc = lc_div(sc, cm_pred_block_cost_divisor(inst_parent(i)));
    let vty = lv_vec_ty(vals[i].ty as i32, vf);
    let mty = lv_vec_ty(T_I1, vf);
    let o = iop(i);
    let id = if o == OP_UDIV { IID_masked_udiv } else if o == OP_SDIV { IID_masked_sdiv } else if o == OP_UREM { IID_masked_urem } else { IID_masked_srem };
    let mc = lt_intrinsic_types(id as i32, vty, [vty, vty, mty], 0);
    return sc, mc;
}
// isDivRemScalarWithPredication(ScalarCost, MaskedCost)
fn cm_is_div_rem_scalar_with_predication(sc: i64, mc: i64) -> bool {
    if flag_given("force-masked-divrem") { return !flag_bool("force-masked-divrem", false); }
    return sc < mc;
}
// isScalarWithPredication(I, VF) for a division or remainder
fn cm_div_rem_is_scalar_with_predication(i: i32, vf: i64) -> bool {
    let sc, mc = cm_div_rem_speculation_cost(i, vf);
    return cm_is_div_rem_scalar_with_predication(sc, mc);
}

// getVectorIntrinsicCost(CI, VF)
fn cm_vector_intrinsic_cost(ci: i32, vf: i64) -> i64 {
    let id = laa_vector_intrinsic_id_for_call(ci);
    if tti_kind != TTI_X86 { return lcv(base_intrinsic_cost(id, lv_maybe_vectorize_type(vals[ci].ty as i32, vf))); }
    let m = mk_mark();
    let im = ica_mark();
    let fmf = if is_fp_math_operator(ci) { inst_fmf(ci) } else { 0 };
    let ii = if call_iid(ci) != 0 { ci } else { -1 };
    let ic = ica_new(id as i64, lv_maybe_vectorize_type(vals[ci].ty as i32, vf), fmf, ii, TTI_INVALID);
    for k in cb_nargs(ci) { ica_add_arg(ic, cb_arg(ci, k)); }
    let ft = func_type(called_function(ci));
    for k in ty_fn_nparams(ft) { ica_add_type(ic, lv_maybe_vectorize_type(ty_fn_param(ft, k), vf)); }
    let c = x86_intrinsic_cost(ic, LV_KIND);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}
// getVectorCallCost(CI, VF)
fn cm_vector_call_cost(ci: i32, vf: i64) -> i64 {
    var c = lc_add(lc_mul(lt_call(), vf), cm_scalarization_overhead(ci, vf));
    if laa_vector_intrinsic_id_for_call(ci) != 0 { c = lc_min(c, cm_vector_intrinsic_cost(ci, vf)); }
    if vf > 1 && lvl_vec_call_variants { vp_unported_cm("vector library variants (getVectorLibraryVariantFor)"); }
    return c;
}

// shouldConsiderInvariant(Op)
recursive fn cm_should_consider_invariant(v: i32) -> bool {
    if !lvl_is_invariant(v) { return false; }
    if !is_inst(v) || !loop_contains(cm_l, inst_parent(v)) { return true; }
    if cm_is_predicated_inst(v) { return false; }
    if iop(v) == OP_PHI && inst_parent(v) == loop_header(cm_l) { return false; }
    for k in nops(v) { if !cm_should_consider_invariant(op(v, k)) { return false; } }
    return true;
}

// isOptimizableIVTruncate(I, VF)
fn cm_is_optimizable_iv_truncate(i: i32, vf: i64) -> bool {
    if !is_inst(i) || iop(i) != OP_TRUNC { return false; }
    let src = lv_vec_ty(vals[op(i, 0)].ty as i32, vf);
    let dst = lv_vec_ty(vals[i].ty as i32, vf);
    let o = op(i, 0);
    if o != lvl_primary && tti_is_truncate_free(src, dst) { return false; }
    return lvl_is_induction_phi(o);
}

// ---------------------------------------------------------------------------------------------
// getInstructionCost(I, VF)

recursive fn cm_instruction_cost(i: i32, vf0: i64) -> i64 {
    var vf = vf0;
    if cm_is_uniform_after_vectorization(i, vf) { vf = 1; }
    if vf > 1 && cm_is_profitable_to_scalarize(i, vf) { return hm_get(cm_its_cost, cm_key(vf, i), 0); }
    if vf > 1 && cm_is_forced_scalar(i, vf) { return lc_mul(cm_instruction_cost(i, 1), vf); }
    var rt = vals[i].ty as i32;
    if cm_can_truncate_to_minimal_bitwidth(i, vf) { rt = ty_int(lmb_lookup(i)); }
    let vty = if cm_is_scalar_after_vectorization(i, vf) { rt } else { lv_vec_ty(rt, vf) };
    if vf > 1 && ty_is_vector(vty) && lt_number_of_parts(vty) == 0 { return LC_INVALID; }
    let o = iop(i);
    if o == OP_GEP { return 0; }
    if o == OP_BR || o == OP_CONDBR {
        if vf > 1 && o == OP_CONDBR && inst_parent(i) != loop_latch(cm_l) &&
           (hm_has(cm_pbb, cm_key(vf, term_succ(i, 0))) || hm_has(cm_pbb, cm_key(vf, term_succ(i, 1)))) {
            return lc_add(lt_scalarization_all(ty_vector(T_I1, vf, false), false, true), lc_mul(lt_cf(OP_CONDBR), vf));
        }
        if inst_parent(i) == loop_latch(cm_l) || vf == 1 { return lt_cf(OP_BR); }
        return 0;
    }
    if o == OP_SWITCH {
        if vf == 1 { return lt_cf(OP_SWITCH); }
        let ct = vals[op(i, 0)].ty as i32;
        return lc_mul(lt_cmpsel(OP_ICMP, lv_vec_ty(ct, vf), lv_vec_ty(T_I1, vf), 32, 0, 0, -1), (nops(i) - 2) / 2);
    }
    if o == OP_PHI {
        if vf > 1 && lvl_is_fixed_order_recurrence(i) { return lt_shuffle(SK_SPLICE, vty, -1); }
        if vf > 1 && inst_parent(i) != loop_header(cm_l) {
            var res_ty = rt;
            // find_singleton header-phi user
            var hu: i32 = -1;
            var multi = false;
            var u = vals[i].first_use;
            while u >= 0 {
                let us = uses[u].user;
                if iop(us) == OP_PHI && inst_parent(us) == loop_header(cm_l) {
                    if hu >= 0 { multi = true; }
                    hu = us;
                }
                u = uses[u].next;
            }
            if multi { hu = -1; }
            if hu >= 0 {
                let d = lvl_rdx_of(hu);
                if d >= 0 && rk_is_any_of(rdx_descs[d].kind) { res_ty = T_I1; }
            }
            return lc_mul(lt_cmpsel(OP_SELECT, lv_vec_ty(res_ty, vf), lv_vec_ty(T_I1, vf), -1, 0, 0, -1), phi_nincoming(i) - 1);
        }
        return lt_cf(OP_PHI);
    }
    if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM {
        if vf > 1 && cm_is_predicated_inst(i) {
            let sc, mc = cm_div_rem_speculation_cost(i, vf);
            return if cm_is_div_rem_scalar_with_predication(sc, mc) { sc } else { mc };
        }
        return cm_arith_instruction_cost(i, vf, vty);
    }
    if o == OP_ADD || o == OP_SUB || o == OP_FADD || o == OP_FSUB || o == OP_MUL || o == OP_FMUL || o == OP_FDIV ||
       o == OP_FREM || o == OP_SHL || o == OP_LSHR || o == OP_ASHR || o == OP_AND || o == OP_OR || o == OP_XOR {
        return cm_arith_instruction_cost(i, vf, vty);
    }
    if o == OP_FNEG { return lt_arith(OP_FNEG, vty, 0, 0, op(i, 0), -1, 1, i); }
    if o == OP_SELECT {
        let cond = op(i, 0);
        let scalar_cond = sc_is_loop_invariant(sc_get_scev(cond), cm_l);
        if !scalar_cond {
            let is_and = m_logical(i, true);
            var x = lg_a;
            var y = lg_b;
            var is_or = false;
            if !is_and { is_or = m_logical(i, false); x = lg_a; y = lg_b; }
            if is_and || is_or {
                return lt_arith(if is_or { OP_OR } else { OP_AND }, vty, tti_operand_info(x), tti_operand_info(y), x, y, 2, i);
            }
        }
        var cty = vals[cond].ty as i32;
        if !scalar_cond { cty = ty_vector(cty, vf, false); }
        var pred: i64 = -1;
        if is_inst(cond) && (iop(cond) == OP_ICMP || iop(cond) == OP_FCMP) { pred = inst_pred(cond); }
        return lt_cmpsel(OP_SELECT, vty, cty, pred, 0, 0, i);
    }
    if o == OP_ICMP || o == OP_FCMP {
        var valty = vals[op(i, 0)].ty as i32;
        if cm_can_truncate_to_minimal_bitwidth(i, vf) { valty = ty_int(lmb_lookup(i)); }
        let vt = lv_vec_ty(valty, vf);
        return lt_cmpsel(o, vt, lvc_cmp_result_type(vt), inst_pred(i), 0, 0, i);
    }
    if o == OP_LOAD || o == OP_STORE {
        if vf > 1 {
            if cm_get_widening_decision(i, vf) == CM_UNKNOWN { fatal("internal: loop-vectorize: CM decision should be taken at this point"); }
            if cm_widening_cost(i, vf) == LC_INVALID { return LC_INVALID; }
        }
        return cm_memory_instruction_cost(i, vf);
    }
    if o == OP_BITCAST && ty_kind(rt) == TK_PTR { return 0; }
    if o == OP_BITCAST || o == OP_ZEXT || o == OP_SEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_FPEXT ||
       o == OP_PTRTOINT || o == OP_INTTOPTR || o == OP_SITOFP || o == OP_UITOFP || o == OP_TRUNC || o == OP_FPTRUNC {
        return cm_cast_instruction_cost(i, vf, vty);
    }
    if o == OP_CALL { return cm_vector_call_cost(i, vf); }
    if o == OP_EXTRACTVALUE { return lcv(tti_instruction_cost(i, LV_KIND)); }
    if o == OP_ALLOCA { return lt_arith0(OP_MUL, rt); }
    if o == OP_FREEZE { return 0; }
    return lt_arith0(OP_MUL, vty);
}

recursive fn cm_arith_instruction_cost(i: i32, vf: i64, vty: i32) -> i64 {
    let o = iop(i);
    // histograms: legality rejects them without -enable-histogram-loop-vectorization (fails loudly there)
    if o == OP_MUL {
        let a = op(i, 0);
        let b = op(i, 1);
        if (ivd_loop_invariant(cm_l, a) && sc_is_one(pse_get_scev(cm_pse, a))) ||
           (ivd_loop_invariant(cm_l, b) && sc_is_one(pse_get_scev(cm_pse, b))) { return 0; }
    }
    // getReductionPatternCost: no in-loop reductions are formed (reductions fail loudly)
    var op2 = op(i, 1);
    if !is_constant(op2) && ivd_loop_invariant(cm_l, op2) && sc_is_scevable(vals[op2].ty as i32) {
        let s = pse_get_scev(cm_pse, op2);
        if sc_is_const(s) { op2 = sc_value(s); }
    }
    var oi2 = tti_operand_info(op2);
    if oi2 / 4 == OK_ANY && cm_should_consider_invariant(op2) { oi2 = OK_UNIFORM * 4 + oi2 % 4; }
    return lt_arith(o, vty, 0, oi2, op(i, 0), op(i, 1), 2, i);
}

recursive fn cm_cast_cch(m: i32, vf: i64) -> i64 {
    if vf == 1 || !loop_contains(cm_l, inst_parent(m)) { return 1; }
    let d = cm_get_widening_decision(m, vf);
    if d == CM_GATHER_SCATTER { return 3; }
    if d == CM_INTERLEAVE { return 4; }
    if d == CM_SCALARIZE || d == CM_WIDEN { return if cm_is_predicated_inst(m) { 2 } else { 1 }; }
    if d == CM_WIDEN_REVERSE { return 5; }
    if d == CM_INVALIDATED { return 0; }
    fatal("internal: loop-vectorize: Instr did not go through cost modelling?");
    return 0;
}
recursive fn cm_cast_instruction_cost(i: i32, vf: i64, vty: i32) -> i64 {
    let o = iop(i);
    var cch: i64 = 0;
    if o == OP_TRUNC || o == OP_FPTRUNC {
        let fu = vals[i].first_use;
        if fu >= 0 && uses[fu].next < 0 {
            let us = uses[fu].user;
            if iop(us) == OP_STORE { cch = cm_cast_cch(us, vf); }
        }
    } else if o == OP_ZEXT || o == OP_SEXT || o == OP_FPEXT {
        let s = op(i, 0);
        if is_inst(s) && iop(s) == OP_LOAD { cch = cm_cast_cch(s, vf); }
    }
    if cm_is_optimizable_iv_truncate(i, vf) { return lt_cast(OP_TRUNC, vals[i].ty as i32, vals[op(i, 0)].ty as i32, cch, i); }
    var src_scalar = vals[op(i, 0)].ty as i32;
    let op0 = op(i, 0);
    let op0i = if is_inst(op0) { op0 } else { -1 };
    if cm_can_truncate_to_minimal_bitwidth(op0i, vf) { src_scalar = ty_int(lmb_lookup(op0i)); }
    let src_vec = if ty_is_vector(vty) { lv_vec_ty(src_scalar, vf) } else { src_scalar };
    if cm_can_truncate_to_minimal_bitwidth(i, vf) {
        // no extend after truncating the users to the minimal bitwidth
        if ty_bits(ty_scalar(vty)) <= ty_bits(ty_scalar(src_vec)) && (o == OP_ZEXT || o == OP_SEXT) { return 0; }
    }
    return lt_cast(o, vty, src_vec, cch, i);
}

// ---------------------------------------------------------------------------------------------
// setCostBasedWideningDecision, collectInstsToScalarize, collectNonVectorizedAndSetWideningDecisions

// setCostBasedWideningDecision(VF)
fn cm_set_cost_based_widening_decision(vf: i64) {
    if vf == 1 { return; }
    let l = cm_l;
    cm_num_pred_stores = 0;
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            if iop(i) == OP_STORE && cm_is_scalar_with_predication_c(i, vf) { cm_num_pred_stores++; }
            i = inst_next(i);
        }
    }
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            let ptr = laa_ldst_ptr(i);
            if ptr < 0 { i = inst_next(i); continue; }
            if lvl_is_uniform_mem_op(i, vf) {
                let gs = if cfg_is_legal_gather_or_scatter(i, vf) { cm_gather_scatter_cost(i, vf) } else { LC_INVALID };
                let sc = cm_uniform_mem_op_cost(i, vf);
                if gs < sc { cm_set_widening_decision(i, vf, CM_GATHER_SCATTER, gs); }
                else { cm_set_widening_decision(i, vf, CM_SCALARIZE, sc); }
                i = inst_next(i);
                continue;
            }
            let d = cm_memory_instruction_can_be_widened_c(i, vf);
            if d != CM_UNKNOWN {
                cm_set_widening_decision(i, vf, d, cm_consecutive_mem_op_cost(i, vf, d));
                i = inst_next(i);
                continue;
            }
            // Choose between Interleaving, Gather/Scatter or Scalarization.
            var icost = LC_INVALID;
            var nacc: i64 = 1;
            let grp = iai_group_of(i);
            if grp >= 0 {
                if cm_get_widening_decision(i, vf) != CM_UNKNOWN { i = inst_next(i); continue; }
                nacc = ig_num_members(grp);
                if cm_interleaved_access_can_be_widened(i, vf) { icost = cm_interleave_group_cost(i, vf); }
            }
            let gs = if cfg_is_legal_gather_or_scatter(i, vf) { lc_mul(cm_gather_scatter_cost(i, vf), nacc) } else { LC_INVALID };
            let sc = lc_mul(cm_mem_inst_scalarization_cost(i, vf), nacc);
            var dec = CM_SCALARIZE;
            var cost = sc;
            if icost <= gs && icost < sc { dec = CM_INTERLEAVE; cost = icost; }
            else if gs < sc { dec = CM_GATHER_SCATTER; cost = gs; }
            if grp >= 0 {
                if dec == CM_SCALARIZE {
                    for x in ig_factor(grp) {
                        let m = ig_member(grp, x);
                        if m >= 0 { cm_set_widening_decision(m, vf, dec, cm_mem_inst_scalarization_cost(m, vf)); }
                    }
                } else {
                    cm_set_group_widening_decision(grp, vf, dec, cost);
                }
            } else {
                cm_set_widening_decision(i, vf, dec, cost);
            }
            i = inst_next(i);
        }
    }
    if lt_prefers_vectorized_addressing() { return; }
    var addr_defs: i32[>..<] = [];
    var addr_set = hm_new();
    for b in loop_nblocks(l) {
        var i = block_first(loop_block(l, b));
        while i >= 0 {
            let p = laa_ldst_ptr(i);
            if p >= 0 && is_inst(p) && ivd_contains_inst(l, p) && cm_get_widening_decision(i, vf) != CM_GATHER_SCATTER {
                if ivd_set_add(addr_set, p) { addr_defs.push(p); }
            }
            i = inst_next(i);
        }
    }
    var wl: i32[>..<] = [];
    for x in addr_defs { wl.push(x); }
    while wl.len > 0 {
        let x = wl.pop();
        for k in nops(x) {
            let o = op(x, k);
            if is_inst(o) && ivd_contains_inst(l, o) && iop(o) != OP_PHI && ivd_set_add(addr_set, o) { addr_defs.push(o); wl.push(o); }
        }
    }
    fn update_mem_op_user_cost(li: i32) {
        var u = vals[li].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if iop(us) != OP_LOAD && iop(us) != OP_STORE { continue; }
            if cm_get_widening_decision(us, vf) != CM_SCALARIZE { continue; }
            cm_set_widening_decision(us, vf, CM_SCALARIZE, cm_mem_inst_scalarization_cost(us, vf));
        }
    }
    for x in addr_defs {
        if iop(x) == OP_LOAD {
            let d = cm_get_widening_decision(x, vf);
            if !cm_is_predicated_inst(x) && (d == CM_WIDEN || d == CM_WIDEN_REVERSE || (!lvl_is_uniform_mem_op(x, vf) && d == CM_SCALARIZE)) {
                cm_set_widening_decision(x, vf, CM_SCALARIZE, lc_mul(cm_memory_instruction_cost(x, 1), vf));
                update_mem_op_user_cost(x);
            } else if iai_is_interleaved(x) {
                // Scalarize all members of this interleaved group when any member is used as an address.
                let grp = iai_group_of(x);
                for xi in ig_factor(grp) {
                    let m = ig_member(grp, xi);
                    if m < 0 { continue; }
                    let c = if hm_has(addr_set, m as u64) { lc_mul(cm_memory_instruction_cost(m, 1), vf) } else { cm_mem_inst_scalarization_cost(m, vf) };
                    cm_set_widening_decision(m, vf, CM_SCALARIZE, c);
                    update_mem_op_user_cost(m);
                }
            }
        } else {
            if iop(x) == OP_PHI && lvl_is_fixed_order_recurrence(x) { continue; }
            if !hm_has(cm_forced, cm_key(vf, x)) { cm_forced_list.push(cm_key(vf, x) as i64); }
            hm_put(cm_forced, cm_key(vf, x), 1);
        }
    }
}

// setWideningDecision(Grp, VF, W, Cost): the insert position gets the whole cost when interleaving
fn cm_set_group_widening_decision(g: i32, vf: i64, w: i64, cost: i64) {
    var ip_cost = cost;
    var other: i64 = 0;
    if w != CM_INTERLEAVE { ip_cost = lc_div(cost, ig_num_members(g)); other = ip_cost; }
    for x in ig_factor(g) {
        let m = ig_member(g, x);
        if m < 0 { continue; }
        cm_set_widening_decision(m, vf, w, if ig_insert_pos(g) == m { ip_cost } else { other });
    }
}
// interleavedAccessCanBeWidened(I, VF)
fn cm_interleaved_access_can_be_widened(i: i32, vf: i64) -> bool {
    let g = iai_group_of(i);
    let st = laa_ldst_type(i);
    if cm_has_irregular_type(st) { return false; }
    fn is_ni(t: i32) -> bool { ty_kind(t) == TK_PTR && dl_is_nonintegral_as(types[t].n as i64) }
    let sni = is_ni(st);
    for x in ig_factor(g) {
        let m = ig_member(g, x);
        if m < 0 { continue; }
        let mt = laa_ldst_type(m);
        let mni = is_ni(mt);
        if mni != sni { return false; }
        if mni && sni && types[st].n != types[mt].n { return false; }
    }
    let pred_mask = cm_block_needs_predication_for_any_reason(inst_parent(i)) && cm_is_mask_required(i);
    let load_gaps = iop(i) == OP_LOAD && ig_requires_scalar_epilogue(g) && !cm_is_epilogue_allowed();
    let store_gaps = iop(i) == OP_STORE && !ig_is_full(g);
    if !pred_mask && !load_gaps && !store_gaps { return true; }
    if ig_is_reverse(g) { return false; }
    return cfg_is_legal_masked_load_or_store(i, vf);
}
// getInterleaveGroupCost(I, VF)
fn cm_interleave_group_cost(i: i32, vf: i64) -> i64 {
    let g = iai_group_of(i);
    let ip = ig_insert_pos(g);
    let vt = laa_ldst_type(ip);
    let vty = lv_vec_ty(vt, vf);
    let as_ = lv_ptr_as(vals[laa_ldst_ptr(ip)].ty as i32);
    let f = ig_factor(g);
    let wide = ty_vector(vt, vf * f, false);
    var idx: i64[>..<] = [];
    for x in f { if ig_member(g, x) >= 0 { idx.push(x); } }
    let gaps = (ig_requires_scalar_epilogue(g) && !cm_is_epilogue_allowed()) || (iop(i) == OP_STORE && !ig_is_full(g));
    var c = lt_interleaved(iop(ip), wide, f, idx, ig_align(g), as_, cm_is_mask_required(i), gaps);
    if ig_is_reverse(g) {
        if cm_is_mask_required(i) { fatal("internal: Reverse masked interleaved access not supported."); }
        c = lc_add(c, lc_mul(lt_shuffle(SK_REVERSE, vty, 0), ig_num_members(g)));
    }
    return c;
}
// TTI.getInterleavedMemoryOpCost(Opcode, WideVecTy, Factor, Indices, Alignment, AS, CostKind, UseMaskForCond, UseMaskForGaps)
fn lt_interleaved(o: i64, wide: i32, factor: i64, idx: const i64[:], align: i64, as_: i64, mask_cond: bool, mask_gaps: bool) -> i64 {
    if tti_kind != TTI_X86 { return lcv(1); }
    let m = mk_mark();
    let im = ica_mark();
    let is = mk_pool.len;
    for x in idx { mk_pool.push(x as i32); }
    let c = x86_interleaved_memory_op_cost(o, wide, factor, is, idx.len, align, as_, LV_KIND, mask_cond, mask_gaps);
    mk_release(m);
    ica_release(im);
    return lcv(c);
}

// isScalarWithPredication with the division cost (lv_cm's version fails loudly for divisions)
fn cm_is_scalar_with_predication_c(i: i32, vf: i64) -> bool {
    let o = iop(i);
    if (o == OP_UDIV || o == OP_SDIV || o == OP_SREM || o == OP_UREM) && cm_is_predicated_inst(i) {
        return cm_div_rem_is_scalar_with_predication(i, vf);
    }
    return cm_is_scalar_with_predication(i, vf);
}
// memoryInstructionCanBeWidened(I, VF): CM_UNKNOWN = std::nullopt
fn cm_memory_instruction_can_be_widened_c(i: i32, vf: i64) -> i64 {
    let stride = lvl_is_consecutive_ptr(laa_ldst_type(i), laa_ldst_ptr(i));
    if stride == 0 { return CM_UNKNOWN; }
    if cm_is_scalar_with_predication_c(i, vf) { return CM_UNKNOWN; }
    if cm_has_irregular_type(laa_ldst_type(i)) { return CM_UNKNOWN; }
    return if stride == 1 { CM_WIDEN } else { CM_WIDEN_REVERSE };
}

// computePredInstDiscount(PredInst, ScalarCosts, VF)
fn cm_compute_pred_inst_discount(pred_inst: i32, vf: i64, keys: i32[>..<]&, costs: i64[>..<]&) -> i64 {
    var discount: i64 = 0;
    var wl: i32[>..<] = [];
    fn can_be_scalarized(i: i32) -> bool {
        if !ivd_has_one_use(i) || inst_parent(pred_inst) != inst_parent(i) || cm_is_scalar_after_vectorization(i, vf) { return false; }
        if cm_is_scalar_with_predication_c(i, vf) { return false; }
        for k in nops(i) { let j = op(i, k); if is_inst(j) && cm_is_uniform_after_vectorization(j, vf) { return false; } }
        return true;
    }
    wl.push(pred_inst);
    while wl.len > 0 {
        let i = wl.pop();
        var seen = false;
        for k in keys { if k == i { seen = true; } }
        if seen { continue; }
        if iop(i) == OP_PHI && lvl_is_fixed_order_recurrence(i) { continue; }
        let vc = cm_instruction_cost(i, vf);
        var sc = lc_mul(cm_instruction_cost(i, 1), vf);
        if cm_is_scalar_with_predication_c(i, vf) && vals[i].ty as i32 != T_VOID {
            sc = lc_add(sc, lt_scalarization_all(lv_vec_ty(vals[i].ty as i32, vf), true, false));
            sc = lc_add(sc, lc_mul(lt_cf(OP_PHI), vf));
        }
        for k in nops(i) {
            let j = op(i, k);
            if !is_inst(j) { continue; }
            if can_be_scalarized(j) { wl.push(j); }
            else if cm_needs_extract(j, vf) { sc = lc_add(sc, lt_scalarization_all(lv_vec_ty(vals[j].ty as i32, vf), false, true)); }
        }
        sc = lc_div(sc, cm_pred_block_cost_divisor(inst_parent(i)));
        discount = lc_add(discount, lc_sub(vc, sc));
        keys.push(i);
        costs.push(sc);
    }
    return discount;
}

// blockNeedsPredicationForAnyReason(BB)
fn cm_block_needs_predication_for_any_reason(bb: i32) -> bool { cm_fold_tail || lvl_block_needs_predication(bb) }

// collectInstsToScalarize(VF)
fn cm_collect_insts_to_scalarize(vf: i64) {
    for x in cm_its_vfs { if x == vf { return; } }
    cm_its_vfs.push(vf);
    for b in loop_nblocks(cm_l) {
        let bb = loop_block(cm_l, b);
        if !cm_block_needs_predication_for_any_reason(bb) { continue; }
        var i = block_first(bb);
        while i >= 0 {
            if cm_is_scalar_with_predication_c(i, vf) {
                var keys: i32[>..<] = [];
                var costs: i64[>..<] = [];
                if !cm_is_scalar_after_vectorization(i, vf) && !cm_use_emulated_mask_mem_ref_hack(i, vf) &&
                   cm_compute_pred_inst_discount(i, vf, keys, costs) >= 0 {
                    for k in keys.len {
                        let key = cm_key(vf, keys[k]);
                        if hm_has(cm_to_scalarize, key) { continue; }
                        hm_put(cm_to_scalarize, key, 1);
                        hm_put(cm_its_cost, key, costs[k]);
                        cm_its_list.push(key as i64);
                    }
                }
                hm_put(cm_pbb, cm_key(vf, bb), 1);
                each_pred(bb) { pb =>
                    let t = block_last(pb);
                    if term_nsucc(t) == 1 && term_succ(t, 0) == bb { hm_put(cm_pbb, cm_key(vf, pb), 1); }
                };
            }
            i = inst_next(i);
        }
    }
}

// collectNonVectorizedAndSetWideningDecisions(VF)
fn cm_collect_non_vectorized_and_set_widening_decisions(vf: i64) {
    if vf == 1 { return; }
    for x in cm_uni_vfs { if x == vf { return; } }
    cm_set_cost_based_widening_decision(vf);
    cm_collect_loop_uniforms(vf);
    cm_collect_loop_scalars(vf);
    cm_collect_insts_to_scalarize(vf);
}

// expectedCost(VF) (only for the scalar VF)
fn cm_expected_cost(vf: i64) -> i64 {
    var c: i64 = 0;
    for b in loop_nblocks(cm_l) {
        let bb = loop_block(cm_l, b);
        var bc: i64 = 0;
        var i = block_first(bb);
        while i >= 0 {
            if hm_has(cm_vals_to_ignore, i as u64) { i = inst_next(i); continue; }
            var ic = cm_instruction_cost(i, vf);
            if lc_valid(ic) && lv_has_forced_cost() { ic = lv_forced_cost(); }
            if lv_dbg_on() {
                var s: u8[>..] = [];
                lv_dbg_inst_name(i, s);
                lv_dbg_cost("LV: Found an estimated cost of ", ic, vf, str(" For instruction:", s));
            }
            bc = lc_add(bc, ic);
            i = inst_next(i);
        }
        c = lc_add(c, lc_div(bc, cm_pred_block_cost_divisor(bb)));
    }
    return c;
}
