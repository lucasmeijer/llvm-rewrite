// LoopUnroll: the loop-unroll (function pass) and loop-unroll-full (loop pass) passes.
// Port of llvm/lib/Transforms/Scalar/LoopUnrollPass.cpp (gatherUnrollingPreferences, analyzeLoopUnrollCost,
// UnrollCostEstimator, UnrollPragmaInfo, getFullUnrollBoostingFactor, shouldPragmaUnroll, shouldFullUnroll,
// shouldPartialUnroll, computeUnrollCount, tryToUnrollLoop, LoopFullUnrollPass::run, LoopUnrollPass::run and
// the cl::opts), llvm/lib/Analysis/LoopUnrollAnalyzer.cpp (UnrolledInstAnalyzer), the targets' unrolling and
// peeling preferences (llvm/include/llvm/CodeGen/BasicTTIImpl.h getUnrollingPreferences /
// getPeelingPreferences, which X86TTIImpl inherits; the scheduling model's LoopMicroOpBufferSize is
// gen_x86sched.goose; TargetTransformInfoImplBase leaves both unchanged) and
// llvm/lib/Analysis/CodeMetrics.cpp (collectEphemeralValues(Loop), analyzeBasicBlock with a loop).
//
// The transformation is loop_unroll.goose (UnrollLoop), loop_unroll_runtime.goose (runtime remainder) and
// loop_peel.goose (peeling). Optimization remarks are not emitted (no -pass-remarks support).
// Not ported (fail loudly): -forget-scev-loop-unroll (forgetAllLoops), profile-guided size optimization
// (ProfileSummaryInfo is never cached), UniformityInfo (only targets with branch divergence have it).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import analyses;
import flags;
import apint;
import pm;
import cfold;
import constfold;
import local;
import instsimplify;
import vt;
import assume;
import domtree;
import loopinfo;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import lpm;
import tti;
import tti_x86;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_pred;
import scev_range;
import scev_update;
import looprotate;
import bfi;
import loop_md;
import loop_unroll;
import loop_peel;

fn lu_not_ported(what: const u8[:]) { fatal(str("LoopUnroll: ", what, " is not ported yet")); }

let LU_UINT_MAX: i64 = 0xFFFFFFFF;
let LUR_UNMODIFIED: i64 = 0;
let LUR_PARTIAL: i64 = 1;
let LUR_FULL: i64 = 2;

// cl::opt<unsigned>: the value as an unsigned 32-bit number
fn lu_flag_uint(name: const u8[:], dflt: i64) -> i64 { flag_int(name, dflt) & LU_UINT_MAX }

// TargetTransformInfo::UnrollingPreferences
struct UnrollPrefs {
    threshold: i64, max_pct_boost: i64, opt_size_threshold: i64, partial_threshold: i64,
    partial_opt_size_threshold: i64, count: i64, default_runtime_count: i64, max_count: i64,
    max_upper_bound: i64, full_unroll_max_count: i64, be_insns: i64,
    partial: bool, runtime: bool, allow_remainder: bool, unroll_remainder: bool,
    allow_expensive_trip_count: bool, force: bool, upper_bound: bool, unroll_and_jam: bool,
    unroll_and_jam_inner_threshold: i64, max_iter_to_analyze: i64, scev_budget: i64,
    runtime_multi_exit: bool, add_accumulators: bool,
}

// The pass's options (LoopUnrollOptions / LoopFullUnrollPass); tri-state optionals are -1 = none, 0, 1.
struct LUOpts { opt_level: i64, only_when_forced: bool, forget_scev: bool, allow_partial: i64, allow_peeling: i64,
                allow_runtime: i64, allow_upper_bound: i64, allow_profile_peeling: i64, full_unroll_max_count: i64 }

var lu_opt_table: LUOpts[>..];

// BasicTTIImplBase::getUnrollingPreferences (X86TTIImpl); NoTTIImpl leaves UnrollPrefs unchanged.
fn tti_get_unrolling_preferences(l: i32, up: UnrollPrefs&) {
    if tti_kind != TTI_X86 { return; }
    var max_ops: i64 = 0;
    if flag_given("partial-unrolling-threshold") { max_ops = lu_flag_uint("partial-unrolling-threshold", 0); }
    else {
        let b = x86_loop_micro_op_buffer_size();
        if b > 0 { max_ops = b; } else { return; }
    }
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            let o = iop(i);
            if o == OP_CALL || o == OP_INVOKE {
                let f = called_function(i);
                if f >= 0 && !tti_is_lowered_to_call(f) { i = inst_next(i); continue; }
                return;
            }
            i = inst_next(i);
        }
    }
    up.partial = true;
    up.runtime = true;
    up.upper_bound = true;
    up.partial_threshold = max_ops;
    up.opt_size_threshold = 0;
    up.partial_opt_size_threshold = 0;
    up.be_insns = 2;
}

// gatherUnrollingPreferences(L, SE, TTI, BFI, PSI, ORE, OptLevel, UserThreshold, UserCount, UserAllowPartial,
// UserRuntime, UserUpperBound, UserFullUnrollMaxCount); optionals: -1 = none
fn gather_unrolling_preferences(l: i32, opt_level: i64, user_threshold: i64, user_count: i64, user_partial: i64,
                                user_runtime: i64, user_upper_bound: i64, user_full_max: i64) -> UnrollPrefs {
    var up = UnrollPrefs {
        threshold: if opt_level > 2 { lu_flag_uint("unroll-threshold-aggressive", 300) } else { lu_flag_uint("unroll-threshold-default", 150) },
        max_pct_boost: 400, opt_size_threshold: lu_flag_uint("unroll-optsize-threshold", 0), partial_threshold: 150,
        partial_opt_size_threshold: lu_flag_uint("unroll-optsize-threshold", 0), count: 0, default_runtime_count: 8,
        max_count: LU_UINT_MAX, max_upper_bound: lu_flag_uint("unroll-max-upperbound", 8), full_unroll_max_count: LU_UINT_MAX,
        be_insns: 2, partial: false, runtime: false, allow_remainder: true, unroll_remainder: false,
        allow_expensive_trip_count: false, force: false, upper_bound: false, unroll_and_jam: false,
        unroll_and_jam_inner_threshold: 60, max_iter_to_analyze: lu_flag_uint("unroll-max-iteration-count-to-analyze", 10),
        scev_budget: lu_flag_uint("scev-cheap-expansion-budget", 4), runtime_multi_exit: false, add_accumulators: false,
    };
    tti_get_unrolling_preferences(l, up);
    let fv = block_func(loop_header(l));
    // shouldOptimizeForSize(Header, PSI, BFI): false without a cached ProfileSummaryInfo
    let opt_for_size = func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize);
    if opt_for_size {
        up.threshold = up.opt_size_threshold;
        up.partial_threshold = up.partial_opt_size_threshold;
        up.max_pct_boost = 100;
    }
    if flag_given("unroll-threshold") { up.threshold = lu_flag_uint("unroll-threshold", 0); }
    if flag_given("unroll-partial-threshold") { up.partial_threshold = lu_flag_uint("unroll-partial-threshold", 0); }
    if flag_given("unroll-max-percent-threshold-boost") { up.max_pct_boost = lu_flag_uint("unroll-max-percent-threshold-boost", 400); }
    if flag_given("unroll-max-count") { up.max_count = lu_flag_uint("unroll-max-count", 0); }
    if flag_given("unroll-max-upperbound") { up.max_upper_bound = lu_flag_uint("unroll-max-upperbound", 8); }
    if flag_given("unroll-full-max-count") { up.full_unroll_max_count = lu_flag_uint("unroll-full-max-count", 0); }
    if flag_given("unroll-allow-partial") { up.partial = flag_bool("unroll-allow-partial", false); }
    if flag_given("unroll-allow-remainder") { up.allow_remainder = flag_bool("unroll-allow-remainder", false); }
    if flag_given("unroll-runtime") { up.runtime = flag_bool("unroll-runtime", false); }
    if lu_flag_uint("unroll-max-upperbound", 8) == 0 { up.upper_bound = false; }
    if flag_given("unroll-remainder") { up.unroll_remainder = flag_bool("unroll-remainder", false); }
    if flag_given("unroll-max-iteration-count-to-analyze") { up.max_iter_to_analyze = lu_flag_uint("unroll-max-iteration-count-to-analyze", 10); }
    if user_threshold >= 0 { up.threshold = user_threshold; up.partial_threshold = user_threshold; }
    if user_count >= 0 { up.count = user_count; }
    if user_partial >= 0 { up.partial = user_partial != 0; }
    if user_runtime >= 0 { up.runtime = user_runtime != 0; }
    if user_upper_bound >= 0 { up.upper_bound = user_upper_bound != 0; }
    if user_full_max >= 0 { up.full_unroll_max_count = user_full_max; }
    return up;
}

// ---------------------------------------------------------------------------------------------
// CodeMetrics

var cm_eph = hm_new();          // EphValues
var cm_visited = hm_new();
fn cm_is_eph(v: i32) -> bool { hm_has(cm_eph, v as u64) }

// CodeMetrics::collectEphemeralValues(L, AC, EphValues)
fn cm_collect_ephemeral_values(l: i32) {
    hm_clear(cm_eph);
    hm_clear(cm_visited);
    var wl: i32[>..<] = [];
    fn append_spec_operands(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            if hm_has(cm_visited, o as u64) { continue; }
            hm_put(cm_visited, o as u64, 1);
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    var asms: i32[>..<] = [];
    ac_assumptions(block_func(loop_header(l)), asms);
    for a in asms {
        if !loop_contains(l, inst_parent(a)) { continue; }
        if !hm_has(cm_eph, a as u64) { hm_put(cm_eph, a as u64, 1); append_spec_operands(a); }
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !hm_has(cm_eph, uses[u].user as u64) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        hm_put(cm_eph, v as u64, 1);
        append_spec_operands(v);
    }
}

let CK_NONE: i64 = 0;
let CK_CONTROLLED: i64 = 1;
let CK_EXTENDED_LOOP: i64 = 2;
let CK_UNCONTROLLED: i64 = 3;

struct CodeMetricsInfo { num_insts: i64, num_inline_candidates: i64, not_duplicatable: bool, convergence: i64, num_calls: i64 }

fn cm_is_convergence_control(i: i32) -> bool { lr_is_convergence_control(i) }
// extendsConvergenceOutsideLoop(I, L)
fn cm_extends_convergence_outside_loop(i: i32, l: i32) -> bool {
    if l < 0 || !cm_is_convergence_control(i) { return false; }
    var u = vals[i].first_use;
    while u >= 0 { if !loop_contains(l, inst_parent(uses[u].user)) { return true; } u = uses[u].next; }
    return false;
}
// CodeMetrics::analyzeBasicBlock(BB, TTI, EphValues, PrepareForLTO, L)
fn cm_analyze_basic_block(cm: CodeMetricsInfo&, bb: i32, prepare_for_lto: bool, l: i32) {
    var i = block_first(bb);
    while i >= 0 {
        if cm_is_eph(i) { i = inst_next(i); continue; }
        if is_callbase(i) {
            let f = called_function(i);
            if f >= 0 {
                let lowered = tti_is_lowered_to_call(f);
                let internal = globs[glob_of(f)].linkage as i64 == LK_INTERNAL;
                if !call_has_fn_attr(i, AK_NoInline) && lowered && ((internal && lr_has_one_live_use(f)) || prepare_for_lto) {
                    cm.num_inline_candidates += 1;
                }
                if lowered { cm.num_calls += 1; }
            } else if vals[cb_callee(i)].kind != VK_INLINEASM { cm.num_calls += 1; }
        }
        if vals[i].ty == T_TOKEN && !cm_is_convergence_control(i) && lr_used_outside_block(i, bb) { cm.not_duplicatable = true; }
        if is_callbase(i) {
            if call_has_fn_attr(i, AK_NoDuplicate) { cm.not_duplicatable = true; }
            if cm.convergence <= CK_CONTROLLED && call_has_fn_attr(i, AK_Convergent) {
                if cm_is_convergence_control(i) || cb_convergence_control_token(i) >= 0 {
                    if cm_extends_convergence_outside_loop(i, l) { cm.convergence = CK_EXTENDED_LOOP; }
                    else { cm.convergence = CK_CONTROLLED; }
                } else {
                    cm.convergence = CK_UNCONTROLLED;
                }
            }
        }
        cm.num_insts = tc_add(cm.num_insts, tti_instruction_cost(i, TCK_CODE_SIZE));
        i = inst_next(i);
    }
    if iop(block_terminator(bb)) == OP_INDIRECTBR { cm.not_duplicatable = true; }
}

// UnrollCostEstimator
struct UnrollCostEst { loop_size: i64, not_duplicatable: bool, num_inline_candidates: i64, convergence: i64, convergence_allows_runtime: bool }

fn uce_new(l: i32, be_insns: i64, tc_uniform: bool) -> UnrollCostEst {
    var cm = CodeMetricsInfo { num_insts: 0, num_inline_candidates: 0, not_duplicatable: false, convergence: CK_NONE, num_calls: 0 };
    for k in loop_nblocks(l) { cm_analyze_basic_block(cm, loop_block(l, k), false, l); }
    var u = UnrollCostEst { loop_size: cm.num_insts, not_duplicatable: cm.not_duplicatable, num_inline_candidates: cm.num_inline_candidates,
                  convergence: cm.convergence, convergence_allows_runtime: false };
    u.convergence_allows_runtime = (cm.convergence != CK_UNCONTROLLED && get_loop_convergence_heart(l) < 0) || tc_uniform;
    if tc_valid(u.loop_size) && u.loop_size < be_insns + 1 { u.loop_size = be_insns + 1; }
    return u;
}
fn uce_can_unroll(u: UnrollCostEst) -> bool {
    if u.convergence == CK_EXTENDED_LOOP { return false; }
    if !tc_valid(u.loop_size) { return false; }
    if u.not_duplicatable { return false; }
    return true;
}
// getUnrolledLoopSize(UnrollPrefs, CountOverwrite)
fn uce_unrolled_size(u: UnrollCostEst, up: UnrollPrefs, count_overwrite: i64) -> i64 {
    let ls = u.loop_size & LU_UINT_MAX;
    let c = if count_overwrite != 0 { count_overwrite } else { up.count };
    return ((ls - up.be_insns) & LU_UINT_MAX) * c + up.be_insns;
}

// ---------------------------------------------------------------------------------------------
// UnrolledInstAnalyzer (LoopUnrollAnalyzer.cpp) and analyzeLoopUnrollCost

var ua_simplified = hm_new();   // SimplifiedValues: value -> value
var ua_addr = hm_new();         // SimplifiedAddresses: value -> index into ua_addrs
struct UASAddr { base: i32, off: AP }
var ua_addrs: UASAddr[>..<];
var ua_iter: i32 = -1;          // IterationNumber (a SCEV constant)
var ua_l: i32 = -1;

fn ua_lookup(v: i32) -> i32 { hm_get(ua_simplified, v as u64, -1) as i32 }

// simplifyInstWithSCEV
fn ua_simplify_inst_with_scev(i: i32) -> bool {
    if !sc_is_scevable(vals[i].ty) { return false; }
    let s = sc_get_scev(i);
    if sc_is_const(s) { hm_put(ua_simplified, i as u64, sc_value(s) as i64); return true; }
    if !sc_is_zero(ua_iter) && sc_is_loop_invariant(s, ua_l) { return true; }
    if !sc_is_addrec(s) || sc_loop(s) != ua_l { return false; }
    let vai = sc_evaluate_at_iteration(s, ua_iter);
    if sc_is_const(vai) { hm_put(ua_simplified, i as u64, sc_value(vai) as i64); return true; }
    let base = sc_get_pointer_base(s);
    if !sc_is_unknown(base) { return false; }
    let ok, off = sc_compute_constant_difference(vai, base);
    if !ok { return false; }
    let j = ua_addrs.len;
    ua_addrs.push(UASAddr { base: sc_value(base), off: off });
    hm_put(ua_addr, i as u64, j as i64);
    return false;
}
fn ua_simple_operand(v: i32) -> i32 {
    if is_constant(v) { return v; }
    let s = ua_lookup(v);
    return if s >= 0 { s } else { v };
}
fn ua_simplify_query_begin() -> bool, bool, bool, bool {
    let a = sq_no_dt; let b = sq_no_ac; let c = sq_no_tli; let d = dc_active;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; dc_active = false;
    return a, b, c, d;
}
fn ua_simplify_query_end(a: bool, b: bool, c: bool, d: bool) { sq_no_dt = a; sq_no_ac = b; sq_no_tli = c; dc_active = d; }

// CastInst::castIsValid(Op, SrcTy, DstTy)
recursive fn lu_prim_bits(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_INT || k == TK_BYTE { return ty_bits(t); }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    if k == TK_X86_AMX { return 8192; }
    if k == TK_FVEC || k == TK_SVEC { return ty_count(t) * lu_prim_bits(ty_elem(t)); }
    return 0;
}
fn cast_is_valid(o: i64, src: i32, dst: i32) -> bool {
    if !ty_is_first_class(src) || !ty_is_first_class(dst) || ty_is_aggregate(src) || ty_is_aggregate(dst) { return false; }
    let sv = ty_is_vector(src);
    let dv = ty_is_vector(dst);
    let ss = lu_prim_bits(ty_scalar(src));
    let ds = lu_prim_bits(ty_scalar(dst));
    let sec: i64 = if sv { ty_count(src) * (if ty_kind(src) == TK_SVEC { -1 } else { 1 }) } else { 0 };
    let dec: i64 = if dv { ty_count(dst) * (if ty_kind(dst) == TK_SVEC { -1 } else { 1 }) } else { 0 };
    let si = ty_is_int(ty_scalar(src));
    let di = ty_is_int(ty_scalar(dst));
    let sf = ty_is_fp(ty_scalar(src));
    let df = ty_is_fp(ty_scalar(dst));
    let sp = ty_kind(ty_scalar(src)) == TK_PTR;
    let dp = ty_kind(ty_scalar(dst)) == TK_PTR;
    if o == OP_TRUNC { return si && di && sec == dec && ss > ds; }
    if o == OP_ZEXT || o == OP_SEXT { return si && di && sec == dec && ss < ds; }
    if o == OP_FPTRUNC { return sf && df && sec == dec && ss > ds; }
    if o == OP_FPEXT { return sf && df && sec == dec && ss < ds; }
    if o == OP_UITOFP || o == OP_SITOFP { return si && df && sec == dec; }
    if o == OP_FPTOUI || o == OP_FPTOSI { return sf && di && sec == dec; }
    if o == OP_PTRTOADDR || o == OP_PTRTOINT { if sec != dec { return false; } return sp && di; }
    if o == OP_INTTOPTR { if sec != dec { return false; } return si && dp; }
    if o == OP_BITCAST {
        let sb = ty_kind(ty_scalar(src)) == TK_BYTE;
        let db = ty_kind(ty_scalar(dst)) == TK_BYTE;
        if (sp && db) || (sb && dp) { return true; }
        if sp != dp { return false; }
        if !sp { return lu_prim_bits(src) == lu_prim_bits(dst) && (ty_kind(src) == TK_SVEC) == (ty_kind(dst) == TK_SVEC); }
        if ty_bits(ty_scalar(src)) != ty_bits(ty_scalar(dst)) { return false; }
        if sv && dv { return sec == dec; }
        if sv { return sec == 1; }
        if dv { return dec == 1; }
        return true;
    }
    if o == OP_ADDRSPACECAST {
        if !sp || !dp { return false; }
        if ty_bits(ty_scalar(src)) == ty_bits(ty_scalar(dst)) { return false; }
        return sec == dec;
    }
    return false;
}

// UnrolledInstAnalyzer::visit(I): true if the instruction is free after unrolling
fn ua_visit(i: i32) -> bool {
    let o = iop(i);
    if o == OP_LOAD {
        let ap = op(i, 0);
        let j = hm_get(ua_addr, ap as u64, -1);
        if j < 0 { return false; }
        let gv = ua_addrs[j].base;
        if vals[gv].kind != VK_GVAR || !gv_has_definitive_initializer(gv) || globs[glob_of(gv)].is_const == 0 { return false; }
        let off = ua_addrs[j].off;
        if ap_sig_bits(off) > 64 { lu_not_ported("loads at offsets wider than 64 bits"); }
        let r = cf_fold_load_from_const(op(gv, 0), vals[i].ty, ap_sext64(off));
        if r < 0 { return false; }
        hm_put(ua_simplified, i as u64, r as i64);
        return true;
    }
    if is_binary_op(o) {
        let l = ua_simple_operand(op(i, 0));
        let r = ua_simple_operand(op(i, 1));
        let a, b, c, d = ua_simplify_query_begin();
        let q = sq_new(-1);
        let sv = if is_fp_math_operator(i) { simplify_binop_fmf(o, l, r, inst_fmf(i), q, RECURSION_LIMIT) } else { simplify_binop(o, l, r, q, RECURSION_LIMIT) };
        ua_simplify_query_end(a, b, c, d);
        if sv >= 0 { hm_put(ua_simplified, i as u64, sv as i64); return true; }
        return ua_simplify_inst_with_scev(i);
    }
    if is_cast_op(o) || o == OP_PTRTOADDR {
        var x = op(i, 0);
        let s = ua_lookup(x);
        if s >= 0 { x = s; }
        if cast_is_valid(o, vals[x].ty, vals[i].ty) {
            let a, b, c, d = ua_simplify_query_begin();
            let v = simplify_cast(o, x, vals[i].ty, sq_new(-1), RECURSION_LIMIT);
            ua_simplify_query_end(a, b, c, d);
            if v >= 0 { hm_put(ua_simplified, i as u64, v as i64); return true; }
        }
        return ua_simplify_inst_with_scev(i);
    }
    if o == OP_ICMP || o == OP_FCMP {
        let l = ua_simple_operand(op(i, 0));
        let r = ua_simple_operand(op(i, 1));
        let p = inst_cmp_pred(i);
        if !is_constant(l) && !is_constant(r) && !(o == OP_ICMP && (p & 0xFF) >= 38 && (p & 0xFF) <= 41) {
            let jl = hm_get(ua_addr, l as u64, -1);
            if jl >= 0 {
                let jr = hm_get(ua_addr, r as u64, -1);
                if jr >= 0 && ua_addrs[jl].base == ua_addrs[jr].base {
                    let res = ap_icmp(ua_addrs[jl].off, ua_addrs[jr].off, p & 0xFF);
                    hm_put(ua_simplified, i as u64, c_int(vals[i].ty, if res { 1 } else { 0 }) as i64);
                    return true;
                }
            }
        }
        let a, b, c, d = ua_simplify_query_begin();
        let v = simplify_cmp(p, l, r, sq_new(-1), RECURSION_LIMIT);
        ua_simplify_query_end(a, b, c, d);
        if v >= 0 { hm_put(ua_simplified, i as u64, v as i64); return true; }
        return ua_simplify_inst_with_scev(i);
    }
    if o == OP_PHI {
        if ua_simplify_inst_with_scev(i) { return true; }
        return inst_parent(i) == loop_header(ua_l);
    }
    return ua_simplify_inst_with_scev(i);
}
// CmpInst::getPredicate with samesign (as InstSimplify takes it)
fn inst_cmp_pred(i: i32) -> i64 {
    var p = insts[inst_of(i)].pred as i64;
    if iop(i) == OP_ICMP && has_flag(i, FL_SAMESIGN) { p |= CP_SAMESIGN; }
    return p;
}

var ac_cost_map = hm_new();      // InstCostMap: (inst, iteration) -> bit 0 IsFree, bit 1 IsCounted

fn lu_cost_key(i: i32, it: i64) -> u64 { ((i as u64) << 24) | ((it as u64) & 0xFFFFFF) }

// analyzeLoopUnrollCost: (ok, UnrolledCost, RolledDynamicCost)
fn analyze_loop_unroll_cost(l: i32, trip_count: i64, max_size: i64, max_iters: i64) -> bool, i64, i64 {
    if !loop_is_innermost(l) { return false, 0, 0; }
    if trip_count == 0 || trip_count > max_iters { return false, 0, 0; }
    let fv = block_func(loop_header(l));
    let kind = if func_has_fn_attr(fv, AK_MinSize) { TCK_CODE_SIZE } else { TCK_SIZE_AND_LATENCY };
    var bbwl: i32[>..<] = [];
    var exw_a: i32[>..<] = [];
    var exw_b: i32[>..<] = [];
    var in_a: i32[>..<] = [];
    var in_b: i32[>..<] = [];
    var unrolled: i64 = 0;
    var rolled: i64 = 0;
    hm_clear(ac_cost_map);
    hm_clear(ua_simplified);
    var cost_wl: i32[>..<] = [];
    var phi_used: i32[>..<] = [];
    let header = loop_header(l);
    let latch = loop_latch(l);
    let preheader = loop_preheader(l);
    fn add_cost_recursively(root: i32, it0: i64) {
        cost_wl.push(root);
        var it = it0;
        loop {
            loop {
                let i = cost_wl.pop();
                let key = lu_cost_key(i, it);
                let st = hm_get(ac_cost_map, key, -1);
                if st >= 0 && (st & 2) == 0 {
                    hm_put(ac_cost_map, key, st | 2);
                    var skip = false;
                    if iop(i) == OP_PHI && inst_parent(i) == header {
                        skip = true;
                        if it != 0 {
                            let opi = phi_value_for_block(i, latch);
                            if is_inst(opi) && loop_contains(l, inst_parent(opi)) { phi_used.push(opi); }
                        }
                    }
                    if !skip {
                        if (st & 1) == 0 {
                            tti_ovr_ops.clear();
                            for k in nops(i) {
                                let o = op(i, k);
                                let s = ua_lookup(o);
                                tti_ovr_ops.push(if s >= 0 { s } else { o });
                            }
                            tti_ovr_inst = i;
                            unrolled = tc_add(unrolled, tti_instruction_cost(i, kind));
                            tti_ovr_inst = -1;
                        }
                        for k in nops(i) {
                            let o = op(i, k);
                            if !is_inst(o) || !loop_contains(l, inst_parent(o)) { continue; }
                            cost_wl.push(o);
                        }
                    }
                }
                if cost_wl.len == 0 { break; }
            }
            if phi_used.len == 0 { break; }
            for x in phi_used { cost_wl.push(x); }
            phi_used.clear();
            it -= 1;
        }
    }
    for iter in trip_count {
        var p = block_first(header);
        while p >= 0 && iop(p) == OP_PHI {
            var v = phi_value_for_block(p, if iter == 0 { preheader } else { latch });
            if iter != 0 { let s = ua_lookup(v); if s >= 0 { v = s; } }
            in_a.push(p);
            in_b.push(v);
            p = inst_next(p);
        }
        hm_clear(ua_simplified);
        while in_a.len > 0 {
            let a = in_a.pop();
            let b = in_b.pop();
            if !hm_has(ua_simplified, a as u64) { hm_put(ua_simplified, a as u64, b as i64); }
        }
        hm_clear(ua_addr);
        ua_addrs.clear();
        ua_iter = sc_get_constant(ap_u64(iter as u64, 64));
        ua_l = l;
        bbwl.clear();
        bbwl.push(header);
        var idx: i64 = 0;
        while idx < bbwl.len {
            let bb = bbwl[idx];
            idx++;
            var i = block_first(bb);
            while i >= 0 {
                if cm_is_eph(i) { i = inst_next(i); continue; }
                rolled = tc_add(rolled, tti_instruction_cost(i, kind));
                let is_free = ua_visit(i);
                hm_put(ac_cost_map, lu_cost_key(i, iter), if is_free { 1 } else { 0 });
                if is_free { i = inst_next(i); continue; }
                if iop(i) == OP_CALL {
                    let f = called_function(i);
                    if f < 0 || tti_is_lowered_to_call(f) { return false, 0, 0; }
                }
                if inst_may_have_side_effects(i) { add_cost_recursively(i, iter); }
                if unrolled > max_size { return false, 0, 0; }
                i = inst_next(i);
            }
            let ti = block_terminator(bb);
            var known: i32 = -1;
            if iop(ti) == OP_CONDBR {
                let sc = lu_simplified_constant(op(ti, 0));
                if sc >= 0 {
                    if vals[sc].kind == VK_UNDEF || vals[sc].kind == VK_POISON { known = term_succ(ti, 0); }
                    else if vals[sc].kind == VK_CINT { known = term_succ(ti, if cint_is_zero(sc) { 1 } else { 0 }); }
                }
            } else if iop(ti) == OP_SWITCH {
                let sc = lu_simplified_constant(op(ti, 0));
                if sc >= 0 {
                    if vals[sc].kind == VK_UNDEF || vals[sc].kind == VK_POISON { known = term_succ(ti, 0); }
                    else if vals[sc].kind == VK_CINT { known = lu_switch_case_dest(ti, sc); }
                }
            }
            if known >= 0 {
                if loop_contains(l, known) { if position(bbwl, known) < 0 { bbwl.push(known); } }
                else { lu_exit_wl_insert(exw_a, exw_b, bb, known); }
                continue;
            }
            for k in term_nsucc(ti) {
                let s = term_succ(ti, k);
                if loop_contains(l, s) { if position(bbwl, s) < 0 { bbwl.push(s); } }
                else { lu_exit_wl_insert(exw_a, exw_b, bb, s); }
            }
            add_cost_recursively(ti, iter);
        }
        if unrolled == rolled { return false, 0, 0; }
    }
    while exw_a.len > 0 {
        let ebb = exw_a.pop();
        let xbb = exw_b.pop();
        var p = block_first(xbb);
        while p >= 0 && iop(p) == OP_PHI {
            let o = phi_value_for_block(p, ebb);
            if is_inst(o) && loop_contains(l, inst_parent(o)) { add_cost_recursively(o, trip_count - 1); }
            p = inst_next(p);
        }
    }
    return true, unrolled & LU_UINT_MAX, rolled & LU_UINT_MAX;
}
fn lu_exit_wl_insert(a: i32[>..<]&, b: i32[>..<]&, x: i32, y: i32) {
    for k in a.len { if a[k] == x && b[k] == y { return; } }
    a.push(x);
    b.push(y);
}
fn lu_simplified_constant(v0: i32) -> i32 {
    var v = v0;
    let s = ua_lookup(v);
    if s >= 0 { v = s; }
    return if is_constant(v) { v } else { -1 };
}
// SwitchInst::findCaseValue(C)->getCaseSuccessor()
fn lu_switch_case_dest(sw: i32, c: i32) -> i32 {
    let n = (nops(sw) - 2) / 2;
    for k in n { if op(sw, 2 + 2 * k) == c { return op(sw, 3 + 2 * k); } }
    return op(sw, 1);
}

// ---------------------------------------------------------------------------------------------
// Pragmas and count computation

struct UnrollPragma { user_unroll_count: bool, pragma_full: bool, pragma_count: i64, pragma_enable: bool, pragma_runtime_disable: bool, explicit_unroll: bool }

fn unroll_count_pragma_value(l: i32) -> i64 {
    let md = lmd_unroll_md(l, "llvm.loop.unroll.count");
    if md < 0 { return 0; }
    let o = md_op(md, 1);
    return (ap_zext64(ci_ap(mds[o].extra)) as i64) & LU_UINT_MAX;
}
fn pinfo_new(l: i32) -> UnrollPragma {
    var p = UnrollPragma { user_unroll_count: flag_given("unroll-count"), pragma_full: lmd_unroll_md(l, "llvm.loop.unroll.full") >= 0,
                    pragma_count: unroll_count_pragma_value(l), pragma_enable: lmd_unroll_md(l, "llvm.loop.unroll.enable") >= 0,
                    pragma_runtime_disable: lmd_unroll_md(l, "llvm.loop.unroll.runtime.disable") >= 0, explicit_unroll: false };
    p.explicit_unroll = p.pragma_count > 0 || p.pragma_full || p.pragma_enable || p.user_unroll_count;
    return p;
}

// getFullUnrollBoostingFactor
fn full_unroll_boosting_factor(unrolled: i64, rolled: i64, max_boost: i64) -> i64 {
    if rolled >= LU_UINT_MAX / 100 { return 100; }
    if unrolled != 0 { let b = (100 * rolled) / unrolled; return if b < max_boost { b } else { max_boost }; }
    return max_boost;
}

// shouldPragmaUnroll: -1 = std::nullopt
fn should_pragma_unroll(l: i32, pi: UnrollPragma, trip_multiple: i64, trip_count: i64, max_trip_count: i64, u: UnrollCostEst, up: UnrollPrefs) -> i64 {
    if pi.user_unroll_count {
        let uc = lu_flag_uint("unroll-count", 0);
        if up.allow_remainder && uce_unrolled_size(u, up, uc) < up.threshold { return uc; }
    }
    if pi.pragma_count > 0 {
        if up.allow_remainder || (trip_multiple % pi.pragma_count == 0) { return pi.pragma_count; }
    }
    if pi.pragma_full {
        if trip_count != 0 {
            if trip_count > lu_flag_uint("pragma-unroll-full-max-iterations", 1000000) { return -1; }
            return trip_count;
        }
    }
    if pi.pragma_enable && trip_count == 0 && max_trip_count != 0 && max_trip_count <= up.max_upper_bound { return max_trip_count; }
    return -1;
}

// shouldFullUnroll: -1 = std::nullopt
fn should_full_unroll(l: i32, full_tc: i64, u: UnrollCostEst, up: UnrollPrefs) -> i64 {
    if full_tc > up.full_unroll_max_count { return -1; }
    let us = uce_unrolled_size(u, up, full_tc);
    if us < up.threshold { return full_tc; }
    let maxsz = ((up.threshold * up.max_pct_boost) & LU_UINT_MAX) / 100;
    let ok, unrolled, rolled = analyze_loop_unroll_cost(l, full_tc, maxsz, up.max_iter_to_analyze);
    if ok {
        let boost = full_unroll_boosting_factor(unrolled, rolled, up.max_pct_boost);
        let bt = ((up.threshold * boost) & LU_UINT_MAX) / 100;
        if unrolled < bt { return full_tc; }
    }
    return -1;
}

// shouldPartialUnroll: -1 = std::nullopt
fn should_partial_unroll(loop_size: i64, trip_count: i64, u: UnrollCostEst, up: UnrollPrefs) -> i64 {
    if trip_count == 0 { return -1; }
    if !up.partial { return 0; }
    var count = up.count;
    if count == 0 { count = trip_count; }
    if up.partial_threshold != LU_UINT_MAX {
        if uce_unrolled_size(u, up, count) > up.partial_threshold {
            let pt = if up.partial_threshold > up.be_insns + 1 { up.partial_threshold } else { up.be_insns + 1 };
            count = ((pt - up.be_insns) & LU_UINT_MAX) / ((loop_size - up.be_insns) & LU_UINT_MAX);
        }
        if count > up.max_count { count = up.max_count; }
        while count != 0 && trip_count % count != 0 { count--; }
        if up.allow_remainder && count <= 1 {
            count = up.default_runtime_count;
            while count != 0 && uce_unrolled_size(u, up, count) > up.partial_threshold { count = count >> 1; }
        }
        if count < 2 { count = 0; }
    } else {
        count = trip_count;
    }
    if count > up.max_count { count = up.max_count; }
    return count;
}

// computeUnrollCount (writes UnrollPrefs.Count; PeelPrefs may get a peel count)
fn compute_unroll_count(l: i32, trip_count: i64, max_trip_count: i64, max_or_zero: bool, trip_multiple: i64, u: UnrollCostEst, up: UnrollPrefs&, pp: PeelPrefs&) {
    let loop_size = u.loop_size & LU_UINT_MAX;
    let pi = pinfo_new(l);
    if pp.peel_count != 0 {
        if flag_given("unroll-count") { fatal("LLVM ERROR: Cannot specify both explicit peel count and explicit unroll count"); }
        up.count = 1;
        up.runtime = false;
        return;
    }
    if pi.pragma_enable || pi.pragma_count > 0 {
        up.allow_expensive_trip_count = true;
        up.runtime = true;
    }
    let f = should_pragma_unroll(l, pi, trip_multiple, trip_count, max_trip_count, u, up);
    if f >= 0 {
        up.count = f;
        if pi.user_unroll_count || pi.pragma_count > 0 {
            up.allow_expensive_trip_count = true;
            up.force = true;
        }
        return;
    } else {
        if pi.explicit_unroll && trip_count != 0 {
            let pt = lu_flag_uint("pragma-unroll-threshold", 16 * 1024);
            if up.threshold < pt { up.threshold = pt; }
            if up.partial_threshold < pt { up.partial_threshold = pt; }
        }
    }
    if trip_count != 0 {
        let ff = should_full_unroll(l, trip_count, u, up);
        if ff >= 0 { up.count = ff; return; }
    }
    if trip_count == 0 && max_trip_count != 0 && (up.upper_bound || max_or_zero) && max_trip_count <= up.max_upper_bound {
        let ff = should_full_unroll(l, max_trip_count, u, up);
        if ff >= 0 { up.count = ff; return; }
    }
    compute_peel_count(l, loop_size, pp, trip_count, up.threshold);
    if pp.peel_count != 0 {
        up.runtime = false;
        up.count = 1;
        return;
    }
    if trip_count != 0 { up.partial = up.partial || pi.explicit_unroll; }
    let pc = should_partial_unroll(loop_size, trip_count, u, up);
    if pc >= 0 { up.count = pc; return; }
    if pi.pragma_runtime_disable { return; }
    if max_trip_count != 0 && !up.force && max_trip_count <= up.max_upper_bound { return; }
    let fv = block_func(loop_header(l));
    let hp, ec = bf_entry_count(fv);
    if hp {
        let h, ptc = get_loop_estimated_trip_count(l);
        if h {
            if ptc < (lu_flag_uint("flat-loop-tripcount-threshold", 5) as u64) { return; }
            up.allow_expensive_trip_count = true;
        }
    }
    if !up.runtime { return; }
    up.count = up.default_runtime_count;
    while up.count != 0 && uce_unrolled_size(u, up, 0) > up.partial_threshold { up.count = up.count >> 1; }
    if !up.allow_remainder && up.count != 0 && (trip_multiple % up.count) != 0 {
        while up.count != 0 && trip_multiple % up.count != 0 { up.count = up.count >> 1; }
    }
    if up.count > up.max_count { up.count = up.max_count; }
    if max_trip_count != 0 && up.count > max_trip_count { up.count = max_trip_count; }
    if up.count < 2 { up.count = 0; }
}

// tryToUnrollLoop: (result, remainder loop)
fn try_to_unroll_loop(l: i32, preserve_lcssa: bool, opt_level: i64, only_full: bool, only_when_forced: bool, forget_all: bool,
                      p_count: i64, p_threshold: i64, p_partial: i64, p_runtime: i64, p_upper_bound: i64,
                      p_peeling: i64, p_profile_peeling: i64, p_full_max: i64, use_aa: bool) -> i64 {
    let tm = has_unroll_transformation(l);
    if (tm & TM_DISABLE) != 0 { return LUR_UNMODIFIED; }
    let parent = loop_parent(l);
    if parent >= 0 && has_unroll_and_jam_transformation(parent) == TM_FORCED_BY_USER && tm != TM_FORCED_BY_USER { return LUR_UNMODIFIED; }
    if has_unroll_and_jam_transformation(l) == TM_FORCED_BY_USER && tm != TM_FORCED_BY_USER { return LUR_UNMODIFIED; }
    if !loop_is_simplify_form(l) { return LUR_UNMODIFIED; }
    if only_when_forced && (tm & TM_ENABLE) == 0 { return LUR_UNMODIFIED; }
    let fv = block_func(loop_header(l));
    let opt_for_size = func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize);
    var up = gather_unrolling_preferences(l, opt_level, p_threshold, p_count, p_partial, p_runtime, p_upper_bound, p_full_max);
    var pp = gather_peeling_preferences(l, p_peeling, p_profile_peeling, true);
    if up.threshold == 0 && (!up.partial || up.partial_threshold == 0) && !opt_for_size { return LUR_UNMODIFIED; }
    cm_collect_ephemeral_values(l);
    let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
    let u = uce_new(l, up.be_insns, false);
    if !uce_can_unroll(u) { return LUR_UNMODIFIED; }
    let loop_size = u.loop_size & LU_UINT_MAX;
    if opt_for_size { if up.threshold < loop_size + 1 { up.threshold = loop_size + 1; } }
    if u.num_inline_candidates != 0 { return LUR_UNMODIFIED; }
    var trip_count: i64 = 0;
    var trip_multiple: i64 = 1;
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    for eb in exiting {
        let tc = lu_small_constant_trip_count(l, eb);
        if tc != 0 && (trip_count == 0 || tc < trip_count) { trip_count = tc; trip_multiple = tc; }
    }
    if trip_count == 0 {
        var eb = loop_latch(l);
        if eb < 0 || !loop_is_exiting(l, eb) { eb = loop_exiting_block(l); }
        if eb >= 0 { trip_multiple = lu_small_constant_trip_multiple(l, eb); }
    }
    up.allow_remainder = up.allow_remainder && u.convergence_allows_runtime;
    var max_trip_count: i64 = 0;
    var max_or_zero = false;
    if trip_count == 0 {
        max_trip_count = sc_get_small_constant_max_trip_count(l);
        max_or_zero = sc_is_backedge_taken_count_max_or_zero(l);
    }
    compute_unroll_count(l, trip_count, max_trip_count, max_or_zero, trip_multiple, u, up, pp);
    if up.count == 0 { return LUR_UNMODIFIED; }
    up.runtime = up.runtime && u.convergence_allows_runtime;
    if pp.peel_count != 0 {
        let lvm = vmm_new();
        peel_loop(l, pp.peel_count, pp.peel_last, preserve_lcssa, lvm);
        var bbs: i32[>..<] = [];
        for k in loop_nblocks(l) { bbs.push(loop_block(l, k)); }
        simplify_loop_after_unroll(l, true, bbs, false);
        if pp.peel_profiled_iterations { loop_set_already_unrolled(l); }
        return LUR_PARTIAL;
    }
    if only_full && ((trip_count == 0 && max_trip_count == 0) || up.count < trip_count || up.count < max_trip_count) { return LUR_UNMODIFIED; }
    up.runtime = up.runtime && trip_count == 0 && trip_multiple % up.count != 0;
    let orig_loop_id = loop_id(l);
    let pi = pinfo_new(l);
    let ulo = UnrollLoopOpts { count: up.count, force: up.force, allow_expensive_trip_count: up.allow_expensive_trip_count,
                    unroll_remainder: up.unroll_remainder, runtime: up.runtime, forget_all_scev: forget_all,
                    heart: get_loop_convergence_heart(l), scev_budget: up.scev_budget,
                    runtime_multi_exit: up.runtime_multi_exit, add_accumulators: up.add_accumulators };
    let res, rem = unroll_loop(l, ulo, preserve_lcssa, use_aa);
    if res == LUR_UNMODIFIED { return LUR_UNMODIFIED; }
    if rem >= 0 {
        let opts: const u8[:][2] = ["llvm.loop.unroll.followup_all", "llvm.loop.unroll.followup_remainder"];
        let h, rid = make_followup_loop_id(orig_loop_id, opts, "llvm.loop.unroll.", false);
        if h { lmd_set_loop_id(rem, rid); }
    }
    if res != LUR_FULL {
        let opts: const u8[:][2] = ["llvm.loop.unroll.followup_all", "llvm.loop.unroll.followup_unrolled"];
        let h, nid = make_followup_loop_id(orig_loop_id, opts, "llvm.loop.unroll.", false);
        if h {
            lmd_set_loop_id(l, nid);
            return res;
        }
    }
    if res != LUR_FULL && pi.explicit_unroll { loop_set_already_unrolled(l); }
    return res;
}

// getSmallConstantTripCount(L, ExitingBlock)
fn lu_small_constant_trip_count(l: i32, eb: i32) -> i64 { sc_constant_trip_count(sc_get_exit_count(l, eb, BTC_EXACT, false)) }
// getSmallConstantTripMultiple(L, ExitingBlock)
fn lu_small_constant_trip_multiple(l: i32, eb: i32) -> i64 { sc_trip_multiple_of_exit_count(l, sc_get_exit_count(l, eb, BTC_EXACT, false)) }

fn lu_check_flags() {
    if flag_bool("forget-scev-loop-unroll", false) { lu_not_ported("-forget-scev-loop-unroll (ScalarEvolution::forgetAllLoops)"); }
    if flag_given("unroll-add-parallel-reductions") && flag_bool("unroll-add-parallel-reductions", false) {
        lu_not_ported("-unroll-add-parallel-reductions (RecurrenceDescriptor::isReductionPHI)");
    }
}

// LoopFullUnrollPass::run
fn loop_full_unroll_pass_run(l: i32, opt_level: i64, only_when_forced: bool, forget_scev: bool) -> u32 {
    lu_check_flags();
    let fv = block_func(loop_header(l));
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    lu_fv = fv;
    let parent = loop_parent(l);
    var old: i32[>..<] = [];
    if parent >= 0 { for k in loop_nsubs(parent) { old.push(loop_sub(parent, k)); } }
    else { for k in li_ntop(fv) { old.push(li_top(fv, k)); } }
    let vm = vmm_mark();
    let r = try_to_unroll_loop(l, true, opt_level, true, only_when_forced, forget_scev, -1, -1, 0, 0, 0, 1, 0, -1, false);
    vmm_release(vm);
    if r == LUR_UNMODIFIED { return PA_ALL; }
    var valid = false;
    var sibs: i32[>..<] = [];
    if parent >= 0 { for k in loop_nsubs(parent) { sibs.push(loop_sub(parent, k)); } }
    else { for k in li_ntop(fv) { sibs.push(li_top(fv, k)); } }
    var keep: i32[>..<] = [];
    for s in sibs {
        if s == l { valid = true; continue; }
        if position(old, s) >= 0 { continue; }
        keep.push(s);
    }
    lpm_add_sibling_loops(keep);
    if !valid { lpm_mark_loop_as_deleted(l); }
    else if flag_bool("unroll-revisit-child-loops", false) {
        var ch: i32[>..<] = [];
        for k in loop_nsubs(l) { ch.push(loop_sub(l, k)); }
        lpm_add_child_loops(ch);
    }
    return lu_loop_pass_preserved();
}
fn lu_loop_pass_preserved() -> u32 { ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV) }

var lu_fv: i32 = -1;

// LoopUnrollPass::run
fn loop_unroll_pass_run(fv: i32, o: LUOpts) -> u32 {
    lu_check_flags();
    tli_cur_fn = fv;
    tti_init_function(fv, globs[glob_of(fv)].module);
    lu_fv = fv;
    li_get(fv);
    if li_ntop(fv) == 0 { return PA_ALL; }
    scev_get(fv);
    dt_get(fv, DT_DOM);
    ls_se = true;
    lcssa_se = true;
    var changed = false;
    var k: i64 = 0;
    while k < li_ntop(fv) {
        if simplify_loop(li_top(fv, k), false) { changed = true; }
        if form_lcssa_recursively(li_top(fv, k)) { changed = true; }
        k++;
    }
    ls_se = false;
    lcssa_se = false;
    // appendLoopsToWorklist(LI, Worklist), popped from the back
    lpm_append_function_loops(fv);
    while !lpm_wl_empty() {
        let l = lpm_wl_pop();
        let vm = vmm_mark();
        let r = try_to_unroll_loop(l, true, o.opt_level, false, o.only_when_forced, o.forget_scev, -1, -1,
                                   o.allow_partial, o.allow_runtime, o.allow_upper_bound, o.allow_peeling,
                                   o.allow_profile_peeling, o.full_unroll_max_count, true);
        vmm_release(vm);
        if r != LUR_UNMODIFIED { changed = true; }
    }
    if !changed { return PA_ALL; }
    return lu_loop_pass_preserved();
}
