// The inline cost model: port of llvm/lib/Analysis/InlineCost.cpp (CallAnalyzer and InlineCostCallAnalyzer: every
// visit*, analyzeBlock, analyze, findDeadBlocks, stripAndComputeInBoundsConstantOffsets, updateThreshold,
// isColdCallSite / getHotCallSiteThreshold, costBenefitAnalysis, finalizeAnalysis, the SROA / load-elimination
// bookkeeping; getCallsiteCost, getInlineCost, getInliningCostEstimate, getAttributeBasedInliningDecision,
// isInlineViable, getInlineParams, functionsHaveCompatibleAttributes, the cl::opts), the TargetTransformInfo
// inlining hooks (TargetTransformInfoImpl.h, BasicTTIImpl.h: thresholds, getFPOpCost,
// getEstimatedNumberOfCaseClusters with TargetLoweringBase::isSuitableForJumpTable / isSuitableForBitTests /
// areJTsAllowed, X86TTIImpl::areInlineCompatible, X86TargetLowering::areJTsAllowed), TargetLibraryInfo::
// areInlineCompatible, AttributeFuncs::areInlineCompatible (the CompatRules of llvm/include/llvm/IR/Attributes.td)
// and CodeMetrics::collectEphemeralValues(Function) (llvm/lib/Analysis/CodeMetrics.cpp).
//
// CallAnalyzer is a class hierarchy in LLVM; only InlineCostCallAnalyzer matters here (InlineCostFeaturesAnalyzer
// serves the ML advisor), so its virtual on* callbacks are plain functions. An analyzer is a record on the `cas`
// stack (onLoweredCall runs a nested analyzer for an indirect call that becomes direct); its DenseMaps/Sets are
// one hash map keyed by (analyzer serial, table, value) and its BBWorklist a run on `ca_bbwl`. The analysis
// functions are one recursive cycle and keep no growable locals.
// Not ported: -print-instruction-comments / print<inline-cost> (fail loudly), optimization remarks.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import analyses;
import flags;
import apint;
import pm;
import vt;
import poison;
import knownbits;
import constfold;
import cfold;
import instsimplify;
import memorybuiltins;
import memloc;
import tli;
import tti;
import tti_x86;
import gen_x86costs;
import scev;
import bfi;
import psi;
import loopinfo;
import domtree;
import ipoutil;

fn ic_not_ported(what: const u8[:]) { fatal(str("InlineCost: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// cl::opts and InlineConstants

fn ic_opt(name: const u8[:], dflt: i64) -> i64 { flag_int(name, dflt) }
fn ic_given(name: const u8[:]) -> bool { flag_given(name) }
let IC_OPT_SIZE_THRESHOLD: i64 = 50;
let IC_OPT_MIN_SIZE_THRESHOLD: i64 = 5;
let IC_OPT_AGGRESSIVE_THRESHOLD: i64 = 250;
let IC_INDIRECT_CALL_THRESHOLD: i64 = 100;
let IC_LOOP_PENALTY: i64 = 25;
let IC_COLDCC_PENALTY: i64 = 2000;
let IC_MAX_SIMPLIFIED_DYNAMIC_ALLOCA: u64 = 65536;
let IC_LAST_CALL_TO_STATIC_BONUS: i64 = 15000;
let IC_TOTAL_ALLOCA_SIZE_RECURSIVE_CALLER: u64 = 1024;
let INT_MIN32: i64 = -2147483648;
let INT_MAX32: i64 = 2147483647;
fn w32(x: i64) -> i64 { ((x as! u64) & 0xFFFFFFFF) as! u32 as! i32 as i64 }
fn clamp32(x: i64) -> i64 { if x < INT_MIN32 { INT_MIN32 } else if x > INT_MAX32 { INT_MAX32 } else { x } }

fn ic_instr_cost() -> i64 { ic_opt("inline-instr-cost", 5) }
fn ic_call_penalty() -> i64 { ic_opt("inline-call-penalty", 25) }

// InlineParams: optional fields as (has, value)
struct IParams {
    default_threshold: i64,
    has_hint: bool, hint: i64,
    has_opt_size_hint: bool, opt_size_hint: i64,
    has_cold: bool, cold: i64,
    has_opt_size: bool, opt_size: i64,
    has_opt_min_size: bool, opt_min_size: i64,
    has_hot_cs: bool, hot_cs: i64,
    has_locally_hot_cs: bool, locally_hot_cs: i64,
    has_cold_cs: bool, cold_cs: i64,
    compute_full: bool,
    has_enable_deferral: bool, enable_deferral: bool,
    allow_recursive_call: bool
}
fn ip_empty(t: i64) -> IParams {
    IParams { default_threshold: t, has_hint: false, hint: 0, has_opt_size_hint: false, opt_size_hint: 0, has_cold: false, cold: 0,
              has_opt_size: false, opt_size: 0, has_opt_min_size: false, opt_min_size: 0, has_hot_cs: false, hot_cs: 0,
              has_locally_hot_cs: false, locally_hot_cs: 0, has_cold_cs: false, cold_cs: 0, compute_full: false,
              has_enable_deferral: false, enable_deferral: false, allow_recursive_call: false }
}

// getInlineParams(Threshold)
fn get_inline_params_t(threshold: i64) -> IParams {
    var p = ip_empty(threshold);
    if ic_given("inline-threshold") { p.default_threshold = ic_opt("inline-threshold", 225); }
    p.has_hint = true; p.hint = ic_opt("inlinehint-threshold", 325);
    p.has_opt_size_hint = true; p.opt_size_hint = ic_opt("inlinehint-threshold", 325);
    p.has_hot_cs = true; p.hot_cs = ic_opt("hot-callsite-threshold", 3000);
    if ic_given("locally-hot-callsite-threshold") { p.has_locally_hot_cs = true; p.locally_hot_cs = ic_opt("locally-hot-callsite-threshold", 525); }
    p.has_cold_cs = true; p.cold_cs = ic_opt("inline-cold-callsite-threshold", 45);
    if !ic_given("inline-threshold") {
        p.has_opt_min_size = true; p.opt_min_size = IC_OPT_MIN_SIZE_THRESHOLD;
        p.has_opt_size = true; p.opt_size = IC_OPT_SIZE_THRESHOLD;
        p.has_cold = true; p.cold = ic_opt("inlinecold-threshold", 45);
    } else if ic_given("inlinecold-threshold") {
        p.has_cold = true; p.cold = ic_opt("inlinecold-threshold", 45);
    }
    return p;
}
// getInlineParams()
fn get_inline_params() -> IParams { get_inline_params_t(ic_opt("inlinedefault-threshold", 225)) }
// getInlineParamsFromOptLevel
fn get_inline_params_from_opt_level(lvl: i64) -> IParams {
    var p = get_inline_params_t(if lvl > 2 { IC_OPT_AGGRESSIVE_THRESHOLD } else { ic_opt("inlinedefault-threshold", 225) });
    if lvl > 2 { p.has_locally_hot_cs = true; p.locally_hot_cs = ic_opt("locally-hot-callsite-threshold", 525); }
    return p;
}

// InlineCost: cost, threshold, static bonus; the reason string id (-1 none). Always = INT_MIN, Never = INT_MAX.
struct ICost { cost: i64, threshold: i64, bonus: i64, reason: i32 }
fn icost_get(c: i64, t: i64, b: i64) -> ICost { ICost { cost: c, threshold: t, bonus: b, reason: -1 } }
fn icost_always(r: const u8[:]) -> ICost { ICost { cost: INT_MIN32, threshold: 0, bonus: 0, reason: intern(r) } }
fn icost_never(r: const u8[:]) -> ICost { ICost { cost: INT_MAX32, threshold: 0, bonus: 0, reason: intern(r) } }
fn icost_is_always(c: ICost) -> bool { c.cost == INT_MIN32 }
fn icost_is_never(c: ICost) -> bool { c.cost == INT_MAX32 }
fn icost_bool(c: ICost) -> bool { c.cost < c.threshold }
fn icost_delta(c: ICost) -> i64 { c.threshold - c.cost }

// getStringFnAttrAsInt(Attribute)
fn ic_str_attr_as_int(a: i32) -> bool, i64 {
    if a < 0 || attrs[a].sval < 0 { return false, 0; }
    let s = sbytes(attrs[a].sval);
    if s.len == 0 { return false, 0; }
    var neg = false;
    var k: i64 = 0;
    if s[0] == '-' { neg = true; k = 1; }
    if k >= s.len { return false, 0; }
    var v: i64 = 0;
    while k < s.len {
        let c = s[k];
        if c < '0' || c > '9' { return false, 0; }
        v = v * 10 + ((c - '0') as i64);
        if v > 0x80000000 { return false, 0; }
        k++;
    }
    if neg { v = -v; }
    if v < INT_MIN32 || v > INT_MAX32 { return false, 0; }
    return true, v;
}
// CallBase::getFnAttr(Kind) for a string attribute: the call site's, else the callee's (getCalledOperand)
fn ic_call_str_attr(cb: i32, key: const u8[:]) -> i32 {
    let a = aset_find_str(alist_fn(insts[inst_of(cb)].attrs), key);
    if a >= 0 { return a; }
    let f = cb_callee(cb);
    if is_func(f) { return aset_find_str(alist_fn(func_attrs(f)), key); }
    return -1;
}
fn ic_call_str_int(cb: i32, key: const u8[:]) -> bool, i64 { let a, b = ic_str_attr_as_int(ic_call_str_attr(cb, key)); return a, b; }
fn ic_fn_str_int(f: i32, key: const u8[:]) -> bool, i64 { let a, b = ic_str_attr_as_int(aset_find_str(alist_fn(func_attrs(f)), key)); return a, b; }

// ---------------------------------------------------------------------------------------------
// TargetTransformInfo inlining hooks (all targets here: TargetTransformInfoImplBase / BasicTTIImpl values)

fn tti_inlining_threshold_multiplier() -> i64 { 1 }
fn tti_adjust_inlining_threshold(cb: i32) -> i64 { 0 }
fn tti_inliner_vector_bonus_percent() -> i64 { 150 }
fn tti_inlining_last_call_to_static_bonus() -> i64 { IC_LAST_CALL_TO_STATIC_BONUS }
fn tti_caller_alloca_cost(cb: i32, ai: i32) -> i64 { 0 }
fn tti_inline_call_penalty(f: i32, cb: i32, dflt: i64) -> i64 { dflt }
fn tti_cb_savings_multiplier() -> i64 { 8 }
fn tti_cb_profitable_multiplier() -> i64 { 8 }

// getFPOpCost(Ty) for the subtarget set up by tti_init_function
fn tti_fp_op_cost(ty: i32) -> i64 {
    if tti_kind != TTI_X86 { return TCC_BASIC; }
    // BasicTTIImpl: FADD legal, custom or promoted on the value type
    let e = x86_value_type(ty, true);
    if e == EVT_OTHER || !evt_is_simple(e) { return TCC_EXPENSIVE; }
    let m = evt_to_mvt(e);
    if !x86_mvt_legal(m) { return TCC_EXPENSIVE; }
    let c = mvt_elt(m);
    if c == XE_F32 || c == XE_F64 || c == XE_F80 { return TCC_BASIC; }
    if c == XE_F128 { return TCC_EXPENSIVE; }    // FADD f128 is a LibCall
    x86_np("getFPOpCost of this floating-point type");
    return TCC_EXPENSIVE;
}

// X86TargetLowering::areJTsAllowed
fn tti_jts_allowed(f: i32) -> bool {
    let a = aset_find_str(alist_fn(func_attrs(f)), "no-jump-tables");
    if a >= 0 && attrs[a].sval >= 0 && sbytes(attrs[a].sval) == "true" { return false; }
    if tti_kind == TTI_X86 {
        if x86_has(X86F_FeatureRetpolineIndirectBranches) || x86_has(X86F_FeatureLVIControlFlowIntegrity) { return false; }
    }
    return true;   // BRIND is legal
}

// getEstimatedNumberOfCaseClusters(SI, JTSize, PSI, BFI) -> (clusters, jump table size)
fn tti_case_clusters(sw: i32, with_psi: bool, with_bfi: bool) -> i64, i64 {
    let n = (nops(sw) - 2) / 2;
    if tti_kind != TTI_X86 { return n, 0; }
    let f = inst_func(sw);
    let jt = tti_jts_allowed(f);
    let idx_bits = dl_ptr(0).idx;
    if n < 1 || (!jt && idx_bits < n) { return n, 0; }
    var maxv = ap_from_cint(op(sw, 2));
    var minv = maxv;
    for k in n {
        let cv = ap_from_cint(op(sw, 2 + 2 * k));
        if ap_sgt(cv, maxv) { maxv = cv; }
        if ap_slt(cv, minv) { minv = cv; }
    }
    let rng = ap_limited(ap_sub(maxv, minv), 0xFFFFFFFFFFFFFFFE) + 1;
    if n <= idx_bits {
        // isSuitableForBitTests over the DestMap (counts only)
        var dests: i32[>..<] = [];
        var counts: i64[>..<] = [];
        for k in n {
            let d = op(sw, 3 + 2 * k);
            var found = false;
            for j in dests.len { if dests[j] == d { counts[j] += 1; found = true; break; } }
            if !found { dests.push(d); counts.push(1); }
        }
        if rng <= (idx_bits as u64) {
            let nd = dests.len;
            var ncmp: i64 = 0;
            var maxe: i64 = 0;
            for c in counts { ncmp += c; if c > maxe { maxe = c; } }
            if maxe >= ic_opt("min-bit-test-cmps", 2) {
                if (nd == 1 && ncmp >= 3) || (nd == 2 && ncmp >= 5) || (nd == 3 && ncmp >= 6) { return 1, 0; }
            }
        }
    }
    if jt {
        if n < 2 || n < ic_opt("min-jump-table-entries", 4) { return n, 0; }
        let opt_size = should_optimize_for_size_bb(inst_parent(sw), with_psi, with_bfi);
        let dens = if opt_size { ic_opt("optsize-jump-table-density", 40) } else { ic_opt("jump-table-density", 10) };
        let maxsz = ic_opt("max-jump-table-size", 0xFFFFFFFF) as u64;
        if (opt_size || rng <= maxsz) && ((n as u64) * 100 >= rng * (dens as u64)) { return 1, rng as i64; }
    }
    return n, 0;
}

// The X86 features marked InlineIgnore in llvm/lib/Target/X86/X86.td
let X86_INLINE_IGNORE: const i32[] = [
    X86F_FeatureNOPL, X86F_FeatureX86_64, X86F_FeatureSSEUnalignedMem, X86F_FeatureLAHFSAHF64,
    X86F_TuningPreferMovmskOverVTest, X86F_TuningSlowSHLD, X86F_TuningSlowPMULLD, X86F_TuningSlowPMULLQ,
    X86F_TuningSlowPMADDWD, X86F_TuningSlowUAMem16, X86F_TuningSlowUAMem32, X86F_TuningLEAForSP,
    X86F_TuningSlowDivide32, X86F_TuningSlowDivide64, X86F_TuningPadShortFunctions, X86F_TuningSlowTwoMemOps,
    X86F_TuningSlowIndirectCall, X86F_TuningLEAUsesAG, X86F_TuningSlowLEA, X86F_TuningSlow3OpsLEA,
    X86F_TuningSlowIncDec, X86F_TuningPOPCNTFalseDeps, X86F_TuningLZCNTFalseDeps, X86F_TuningTZCNTFalseDeps,
    X86F_TuningBLSFalseDeps, X86F_TuningMULCFalseDeps, X86F_TuningPERMFalseDeps, X86F_TuningCOMPRESSFalseDeps,
    X86F_TuningEXPANDFalseDeps, X86F_TuningRANGEFalseDeps, X86F_TuningGETMANTFalseDeps, X86F_TuningMULLQFalseDeps,
    X86F_TuningSBBDepBreaking, X86F_TuningFastVariableCrossLaneShuffle, X86F_TuningFastVariablePerLaneShuffle,
    X86F_TuningNoDomainDelay, X86F_TuningNoDomainDelayMov, X86F_TuningNoDomainDelayBlend,
    X86F_TuningNoDomainDelayShuffle, X86F_TuningPreferShiftShuffle, X86F_TuningFastImmVectorShift,
    X86F_TuningInsertVZEROUPPER, X86F_TuningFastScalarFSQRT, X86F_TuningFastVectorFSQRT, X86F_TuningFastLZCNT,
    X86F_TuningFast7ByteNOP, X86F_TuningFast11ByteNOP, X86F_TuningFast15ByteNOP, X86F_TuningFastSHLDRotate,
    X86F_TuningBranchFusion, X86F_TuningMacroFusion, X86F_TuningFastGather, X86F_TuningFastDPWSSD,
    X86F_TuningPreferNoGather, X86F_TuningPreferNoScatter, X86F_TuningPrefer128Bit, X86F_TuningPrefer256Bit,
    X86F_TuningAllowLight256Bit, X86F_TuningPreferMaskRegisters, X86F_TuningFastBEXTR, X86F_TuningFastHorizontalOps,
    X86F_TuningFastScalarShiftMasks, X86F_TuningFastVectorShiftMasks, X86F_TuningFastMOVBE, X86F_TuningFastImm16,
    X86F_TuningUseSLMArithCosts, X86F_TuningUseGLMDivSqrtCosts, X86F_TuningNDDMem, X86F_TuningBranchHint,
    X86F_TuningPreferLegacySetCC,
];

fn ic_fn_str_eq(a: i32, b: i32, key: const u8[:]) -> bool {
    let x = aset_find_str(alist_fn(func_attrs(a)), key);
    let y = aset_find_str(alist_fn(func_attrs(b)), key);
    if x < 0 && y < 0 { return true; }
    if x < 0 || y < 0 { return false; }
    return attrs[x].sval == attrs[y].sval;
}

// CalleeTTI.areInlineCompatible(Caller, Callee)
fn tti_are_inline_compatible(caller: i32, callee: i32) -> bool {
    let m = globs[glob_of(caller)].module;
    tti_init_function(callee, m);
    if tti_kind != TTI_X86 {
        return ic_fn_str_eq(caller, callee, "target-cpu") && ic_fn_str_eq(caller, callee, "target-features");
    }
    var ee: u64[4] = [0, 0, 0, 0];
    for w in 4 { ee[w] = x86_bits[w]; }
    let e512 = x86_use_avx512_regs();
    tti_init_function(caller, m);
    var cc: u64[4] = [0, 0, 0, 0];
    for w in 4 { cc[w] = x86_bits[w]; }
    let c512 = x86_use_avx512_regs();
    tti_init_function(callee, m);
    for f in X86_INLINE_IGNORE {
        let w = (f / 64) as i64;
        let b = (1 as u64) << ((f % 64) as u64);
        cc[w] &= ~b;
        ee[w] &= ~b;
    }
    for w in 4 { if (cc[w] & ee[w]) != ee[w] { return false; } }
    var same = true;
    for w in 4 { if cc[w] != ee[w] { same = false; } }
    if same && c512 == e512 { return true; }
    var ok = true;
    each_inst(callee) { i =>
        if is_callbase(i) {
            let cal = cb_callee(i);
            if !(vals[cal].kind == VK_INLINEASM || call_iid(i) != 0) {
                var simple = true;
                let na = cb_nargs(i);
                for k in na { let t = vals[cb_arg(i, k)].ty; if ty_is_vector(t) || ty_is_aggregate(t) { simple = false; } }
                let rt = vals[i].ty;
                if ty_is_vector(rt) || ty_is_aggregate(rt) { simple = false; }
                if !simple { ok = false; }
            }
        }
    };
    if !ok { ic_not_ported("X86TTIImpl::areTypesABICompatible with vector or aggregate call types"); }
    return true;
}

// TargetLibraryInfo::areInlineCompatible(CalleeTLI, AllowCallerSuperset): the OverrideAsUnavailable sets come
// from the functions' no-builtin(s) attributes
fn ic_tli_unavail(f: i32, lf: i64) -> bool {
    let s = alist_fn(func_attrs(f));
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind != 0 { continue; }
        let key = sbytes(attrs[a].skey);
        if key == "no-builtins" { return true; }
        if starts_with(key, "no-builtin-") && tli_lookup_name(key[11..]) == lf as i32 { return true; }
    }
    return false;
}
fn ic_tli_has_override(f: i32) -> bool {
    let s = alist_fn(func_attrs(f));
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind != 0 { continue; }
        let key = sbytes(attrs[a].skey);
        if key == "no-builtins" || starts_with(key, "no-builtin-") { return true; }
    }
    return false;
}
fn tli_are_inline_compatible(caller: i32, callee: i32, allow_superset: bool) -> bool {
    if !ic_tli_has_override(caller) && !ic_tli_has_override(callee) { return true; }
    let n = TLI_NAMES.len;
    for lf in n {
        let a = ic_tli_unavail(caller, lf);
        let b = ic_tli_unavail(callee, lf);
        if !allow_superset { if a != b { return false; } }
        else if b && !a { return false; }
    }
    return true;
}

// AttributeFuncs::areInlineCompatible: the CompatRules of Attributes.td
fn ic_enum_eq(a: i32, b: i32, kind: i64) -> bool { fn_has(a, 0, kind) == fn_has(b, 0, kind) }
fn ic_attrs_inline_compatible(caller: i32, callee: i32) -> bool {
    for k in [AK_SanitizeAddress, AK_SanitizeThread, AK_SanitizeType, AK_SanitizeMemory, AK_SanitizeHWAddress,
              AK_SanitizeMemTag, AK_SanitizeNumericalStability, AK_SanitizeRealtime, AK_SanitizeRealtimeBlocking,
              AK_SafeStack, AK_ShadowCallStack, AK_NoProfile] {
        if !ic_enum_eq(caller, callee, k) { return false; }
    }
    if !ic_fn_str_eq(caller, callee, "use-sample-profile") { return false; }
    // checkDenormMode: the denormal_fpenv attribute must match
    let da = aset_find(alist_fn(func_attrs(caller)), AK_DenormalFPEnv);
    let db = aset_find(alist_fn(func_attrs(callee)), AK_DenormalFPEnv);
    let dva: u64 = if da >= 0 { attrs[da].i1 } else { 0 };
    let dvb: u64 = if db >= 0 { attrs[db].i1 } else { 0 };
    if dva != dvb { return false; }
    // checkStrictFP: a strictfp caller can't inline a non-strictfp callee
    if fn_has(caller, 0, AK_StrictFP) && !fn_has(callee, 0, AK_StrictFP) { return false; }
    for key in ["sign-return-address", "sign-return-address-key", "branch-protection-pauth-lr"] {
        if !ic_fn_str_eq(caller, callee, key) { return false; }
    }
    return true;
}
fn functions_have_compatible_attributes(caller: i32, callee: i32) -> bool {
    tli_are_inline_compatible(caller, callee, flag_bool("inline-caller-superset-nobuiltin", true)) &&
        ic_attrs_inline_compatible(caller, callee)
}

// getCallsiteCost(TTI, Call, DL)
fn get_callsite_cost(cb: i32) -> i64 {
    var cost: i64 = 0;
    let ic = ic_instr_cost();
    let n = cb_nargs(cb);
    for k in n {
        if cb_is_byval_arg(cb, k) {
            let a = aset_find(alist_param(insts[inst_of(cb)].attrs, k), AK_ByVal);
            var bt: i32 = -1;
            if a >= 0 { bt = attrs[a].ty; }
            if bt < 0 {
                let f = called_function(cb);
                if f >= 0 { let b = aset_find(alist_param(func_attrs(f), k), AK_ByVal); if b >= 0 { bt = attrs[b].ty; } }
            }
            let tsz = dl_size_bits(bt);
            let psz = dl_ptr(ptr_as(vals[cb_arg(cb, k)].ty)).bits;
            var ns = (tsz + psz - 1) / psz;
            if ns > 8 { ns = 8; }
            cost += 2 * ns * ic;
        } else { cost += ic; }
    }
    cost += ic;
    cost += tti_inline_call_penalty(inst_func(cb), cb, ic_call_penalty());
    return if cost > INT_MAX32 { INT_MAX32 } else { cost };
}

// isInlineViable(F) -> (viable, reason)
fn is_inline_viable(f: i32) -> bool, const u8[:] {
    let rt = fn_has(f, 0, AK_ReturnsTwice);
    var b = func_first_block(f);
    while b >= 0 {
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_INDIRECTBR { return false, "contains indirect branches"; }
        if ic_block_address_taken(b) { return false, "blockaddress used"; }
        var i = block_first(b);
        while i >= 0 {
            if is_callbase(i) {
                let callee = called_function(i);
                if callee == f { return false, "recursive call"; }
                if !rt && iop(i) == OP_CALL && call_has_fn_attr(i, AK_ReturnsTwice) { return false, "exposes returns-twice attribute"; }
                if callee >= 0 {
                    let id = func_iid(callee);
                    if id == IID_icall_branch_funnel { return false, "disallowed inlining of @llvm.icall.branch.funnel"; }
                    if id == IID_localescape { return false, "disallowed inlining of @llvm.localescape"; }
                    if id == IID_va_start { return false, "contains VarArgs initialized with va_start"; }
                }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    return true, "";
}
// BasicBlock::hasAddressTaken
fn ic_block_address_taken(b: i32) -> bool { vals[b].first_use >= 0 && ic_block_has_ba_user(b) }
fn ic_block_has_ba_user(b: i32) -> bool {
    var u = vals[b].first_use;
    while u >= 0 { if vals[uses[u].user].kind == VK_BLOCKADDR { return true; } u = uses[u].next; }
    return false;
}

// getAttributeBasedInliningDecision -> 0 none, 1 success, 2 failure (reason)
fn get_attribute_based_inlining_decision(cb: i32, callee: i32) -> i64, const u8[:] {
    if callee < 0 { return 2, "indirect call"; }
    if fn_has(callee, 0, AK_PresplitCoroutine) { return 2, "unsplited coroutine call"; }
    let caller = inst_func(cb);
    if !flag_bool("ignore-tti-inline-compatible", false) && !tti_are_inline_compatible(caller, callee) {
        return 2, "conflicting target features";
    }
    if call_has_fn_attr(cb, AK_AlwaysInline) {
        if aset_has(alist_fn(insts[inst_of(cb)].attrs), AK_NoInline) { return 2, "noinline call site attribute"; }
        let ok, why = is_inline_viable(callee);
        if ok { return 1, ""; }
        return 2, why;
    }
    if !functions_have_compatible_attributes(caller, callee) { return 2, "conflicting attributes"; }
    if fn_has(caller, 0, AK_Flatten) {
        let ok, why = is_inline_viable(callee);
        if ok { return 1, ""; }
        return 2, why;
    }
    if fn_has(caller, 0, AK_OptimizeNone) { return 2, "optnone attribute"; }
    if gv_is_interposable(callee, false) { return 2, "interposable"; }
    if fn_has(callee, 0, AK_NoInline) { return 2, "noinline function attribute"; }
    if aset_has(alist_fn(insts[inst_of(cb)].attrs), AK_NoInline) { return 2, "noinline call site attribute"; }
    if aset_find_str(alist_fn(func_attrs(callee)), "loader-replaceable") >= 0 { return 2, "loader replaceable function attribute"; }
    return 0, "";
}

// ---------------------------------------------------------------------------------------------
// The CallAnalyzer state

struct CAS {
    ser: i32, f: i32, call: i32, caller: i32,
    params: IParams,
    is_caller_recursive: bool, is_recursive_call: bool, exposes_returns_twice: bool, has_dynamic_alloca: bool,
    contains_noduplicate: bool, has_return: bool, has_indirectbr: bool, has_uninlineable_intrinsic: bool,
    inits_varargs: bool, allocated_size: u64, num_instructions: i64, num_vector_instructions: i64,
    enable_load_elim: bool, allow_recursive_call: bool,
    // InlineCostCallAnalyzer
    compute_full: bool, load_elim_cost: i64, vector_bonus: i64, single_bb_bonus: i64, threshold: i64,
    static_bonus: i64, boost_indirect: bool, ignore_threshold: bool, cba_enabled: bool, cost: i64,
    cost_at_bb_start: i64, cold_size: i64, decided_by_cost_threshold: bool, decided_by_cb: bool, single_bb: bool,
    sroa_savings: i64, sroa_lost: i64, with_bfi: bool, with_psi: bool,
    wl_base: i64
}
var cas: CAS[>..<];
var ca_next_ser: i32 = 1;
var cam = hm_new();           // the per-analyzer maps
var ca_bbwl: i32[>..<];       // BBWorklists
var cop_base: i32[>..<];      // ConstantOffsetPtrs records
var cop_off: AP[>..<];

let K_SIMPL: i64 = 0;
let K_SROA: i64 = 1;
let K_SROA_EN: i64 = 2;
let K_COP: i64 = 3;
let K_DEAD: i64 = 4;
let K_KSUCC: i64 = 5;
let K_LOADADDR: i64 = 6;
let K_SROACOST: i64 = 7;
let K_EPH: i64 = 8;
let K_BBWL: i64 = 9;

fn ca_cur() -> i64 { cas.len - 1 }
fn ca_key(k: i64, v: i32) -> u64 { hk2(((cas[ca_cur()].ser as i64) * 16 + k) as i32, v) }
fn ca_get(k: i64, v: i32) -> i32 { hm_get(cam, ca_key(k, v), -1) as i32 }
fn ca_has(k: i64, v: i32) -> bool { hm_has(cam, ca_key(k, v)) }
fn ca_set(k: i64, v: i32, x: i64) { hm_put(cam, ca_key(k, v), x); }
fn ca_del(k: i64, v: i32) { hm_del(cam, ca_key(k, v)); }

// SimplifiedValues
fn ca_simpl(v: i32) -> i32 { ca_get(K_SIMPL, v) }
fn ca_set_simpl(v: i32, x: i32) { ca_set(K_SIMPL, v, x as i64); }
// isa<ConstantInt> (a ConstantByte is not one)
fn ia_is_cint(v: i32) -> bool { v >= 0 && vals[v].kind == VK_CINT && ty_kind(ty_scalar(vals[v].ty)) != TK_BYTE }
// getSimplifiedValue<Constant>
fn ca_simpl_const(v: i32) -> i32 { let s = ca_simpl(v); if s >= 0 && is_constant(s) { s } else { -1 } }
fn ca_simpl_cint(v: i32) -> i32 { let s = ca_simpl(v); if ia_is_cint(s) { s } else { -1 } }
// getDirectOrSimplifiedValue<Constant> / <ConstantInt>
fn ca_dos_const(v: i32) -> i32 { if is_constant(v) { v } else { ca_simpl_const(v) } }
fn ca_dos_cint(v: i32) -> i32 { if ia_is_cint(v) { v } else { ca_simpl_cint(v) } }

// SROAArgValues / EnabledSROAAllocas
fn ca_sroa_arg_or_null(v: i32) -> i32 {
    let a = ca_get(K_SROA, v);
    if a < 0 || !ca_has(K_SROA_EN, a) { return -1; }
    return a;
}
fn ca_set_sroa(v: i32, a: i32) { ca_set(K_SROA, v, a as i64); }

// ConstantOffsetPtrs: (base or -1, offset)
fn ca_cop(v: i32) -> i32, AP {
    let r = ca_get(K_COP, v);
    if r < 0 { return -1, ap_zero(1); }
    return cop_base[r], cop_off[r];
}
fn ca_set_cop(v: i32, base: i32, off: AP) {
    let r = cop_base.len;
    cop_base.push(base);
    cop_off.push(off);
    ca_set(K_COP, v, r);
}
fn ap_same(a: AP, b: AP) -> bool { a.w == b.w && ap_eq(a, b) }

// ---------------------------------------------------------------------------------------------
// Callbacks (InlineCostCallAnalyzer)

fn ca_add_cost(inc0: i64) {
    let c = ca_cur();
    let inc = clamp32(inc0);
    cas[c].cost = clamp32(inc + cas[c].cost);
}
fn ca_on_disable_sroa(a: i32) {
    let k = ca_key(K_SROACOST, a);
    if !hm_has(cam, k) { return; }
    let x = hm_get(cam, k, 0);
    ca_add_cost(x);
    let c = ca_cur();
    cas[c].sroa_savings -= x;
    cas[c].sroa_lost += x;
    hm_del(cam, k);
}
fn ca_on_disable_load_elimination() {
    let c = ca_cur();
    ca_add_cost(cas[c].load_elim_cost);
    cas[c].load_elim_cost = 0;
}
fn ca_on_call_penalty() { ca_add_cost(ic_call_penalty()); }
fn ca_on_mem_access() { ca_add_cost(ic_opt("inline-memaccess-cost", 0)); }
fn ca_on_call_argument_setup(cb: i32) { ca_add_cost(cb_nargs(cb) * ic_instr_cost()); }
fn ca_on_load_relative_intrinsic() { ca_add_cost(3 * ic_instr_cost()); }
fn ca_on_missed_simplification() { ca_add_cost(ic_instr_cost()); }
fn ca_on_load_elimination_opportunity() { let c = ca_cur(); cas[c].load_elim_cost += ic_instr_cost(); }
fn ca_on_initialize_sroa_arg(a: i32) {
    let c = ca_cur();
    let x = tti_caller_alloca_cost(cas[c].call, a);
    cas[c].sroa_savings += x;
    ca_set(K_SROACOST, a, x);
}
fn ca_on_aggregate_sroa_use(a: i32) {
    let k = ca_key(K_SROACOST, a);
    hm_put(cam, k, hm_get(cam, k, 0) + ic_instr_cost());
    let c = ca_cur();
    cas[c].sroa_savings += ic_instr_cost();
}
fn ca_on_finalize_switch(jt_size: i64, nclusters: i64, default_unreachable: bool) {
    let ic = ic_instr_cost();
    if jt_size != 0 {
        if !default_unreachable { ca_add_cost(2 * ic); }
        ca_add_cost(jt_size * ic + 2 * ic);
        return;
    }
    if nclusters <= 3 {
        ca_add_cost((nclusters - (if default_unreachable { 1 } else { 0 })) * 2 * ic);
        return;
    }
    let expected = 3 * nclusters / 2 - 1;
    ca_add_cost(expected * 2 * ic);
}
fn ca_on_inline_asm(asmv: i32) {
    let cost = ic_opt("inline-asm-instr-cost", 0);
    if cost == 0 { return; }
    let s = sbytes(asms[vals[asmv].sub].asm_);
    var level: i64 = 0;
    var count: i64 = 0;
    // collectAsmStrs: split on "\n\t", empty pieces dropped
    var st: i64 = 0;
    var k: i64 = 0;
    while k <= s.len {
        let at_sep = k + 1 < s.len && s[k] == '\n' && s[k + 1] == '\t';
        if k == s.len || at_sep {
            var piece = s[st..k];
            if piece.len > 0 {
                piece = trim(piece);
                let h = find(piece, "#");
                if h >= 0 { piece = piece[..h]; }
                if piece.len > 0 {
                    if starts_with(piece, ".pushsection") { level++; }
                    else if starts_with(piece, ".popsection") { level--; }
                    else if !(starts_with(piece, ".") || find(piece, ":") >= 0) {
                        if level == 0 { count++; }
                    }
                }
            }
            if at_sep { k += 2; st = k; continue; }
        }
        k++;
    }
    ca_add_cost(count * cost);
}
fn ca_on_block_analyzed(bb: i32) {
    let c = ca_cur();
    if cas[c].cba_enabled {
        let ok, pc = bfi_block_profile_count(bb);
        if pc == 0 { cas[c].cold_size += cas[c].cost - cas[c].cost_at_bb_start; }
    }
    let t = block_terminator(bb);
    if cas[c].single_bb && term_nsucc(t) > 1 {
        cas[c].threshold -= cas[c].single_bb_bonus;
        cas[c].single_bb = false;
    }
}
fn ca_should_stop() -> bool {
    let c = ca_cur();
    if cas[c].ignore_threshold || cas[c].compute_full { return false; }
    if cas[c].cost < cas[c].threshold { return false; }
    cas[c].decided_by_cost_threshold = true;
    return true;
}

// isColdCallSite(Call, CallerBFI)
fn ca_is_cold_call_site(cb: i32, with_bfi: bool) -> bool {
    let c = ca_cur();
    if cas[c].with_psi && psi_has_summary { return psi_is_cold_call_site(cb, with_bfi); }
    if !with_bfi { return false; }
    let caller = inst_func(cb);
    bfi_get(caller);
    let cs = bfi_freq(inst_parent(cb));
    let ent = bfi_freq(func_entry(caller));
    // BlockFrequency * BranchProbability(ColdCallSiteRelFreq, 100)
    let lim = bf_scale_by_prob(ent, ic_opt("cold-callsite-rel-freq", 2) as u64, 100);
    return cs < lim;
}
// BranchProbability(N, D) scaling of a frequency: BranchProbability::scale with the normalized numerator
fn bf_scale_by_prob(freq: u64, n: u64, d: u64) -> u64 {
    // BranchProbability(N, D) is stored as N * 2^31 / D (rounded), scale() multiplies with that numerator
    let num = bp_get(n, d) as u64;
    return bp_scale(freq, num);
}
// BranchProbability::scale(Num): (Num * N) >> 31 with 96-bit intermediate (scale<D = 1 << 31>)
fn bp_scale(num: u64, n: u64) -> u64 {
    if n == 0 || num == 0 { return 0; }
    let p = ap_mul(ap_u64(num, 128), ap_u64(n, 128));
    let r = ap_lshr(p, 31);
    return ap_limited(r, 0xFFFFFFFFFFFFFFFF);
}
// getHotCallSiteThreshold(Call, CallerBFI)
fn ca_hot_call_site_threshold(cb: i32, with_bfi: bool) -> bool, i64 {
    let c = ca_cur();
    if cas[c].with_psi && psi_has_summary && psi_is_hot_call_site(cb, with_bfi) { return cas[c].params.has_hot_cs, cas[c].params.hot_cs; }
    if !with_bfi || !cas[c].params.has_locally_hot_cs { return false, 0; }
    let caller = inst_func(cb);
    bfi_get(caller);
    let cs = bfi_freq(inst_parent(cb));
    let ent = bfi_freq(func_entry(caller));
    let lo, hi = ap_mul64(ent, ic_opt("hot-callsite-rel-freq", 60) as u64);
    if hi == 0 && cs >= lo { return true, cas[c].params.locally_hot_cs; }
    return false, 0;
}

// isSoleCallToLocalFunction
fn is_sole_call_to_local_function(cb: i32, callee: i32) -> bool {
    gv_has_local_linkage(callee) && ipo_has_n_live_uses(callee, 1) && callee == called_function(cb)
}

// allowSizeGrowth
fn ca_allow_size_growth(cb: i32) -> bool {
    if iop(cb) == OP_INVOKE {
        let t = block_terminator(invoke_normal_dest(cb));
        if t >= 0 && iop(t) == OP_UNREACHABLE { return false; }
    } else {
        let t = block_terminator(inst_parent(cb));
        if t >= 0 && iop(t) == OP_UNREACHABLE { return false; }
    }
    return true;
}

fn fn_has_min_size(f: i32) -> bool { fn_has(f, 0, AK_MinSize) }

// updateThreshold(Call, Callee)
fn ca_update_threshold(cb: i32, callee: i32) {
    let c = ca_cur();
    if !ca_allow_size_growth(cb) { cas[c].threshold = 0; return; }
    let caller = inst_func(cb);
    let p = cas[c].params;
    var sbb_pct: i64 = 50;
    var vec_pct = tti_inliner_vector_bonus_percent();
    var last_call_bonus = tti_inlining_last_call_to_static_bonus();
    if fn_has_min_size(caller) {
        if p.has_opt_min_size { cas[c].threshold = min(cas[c].threshold, p.opt_min_size); }
        sbb_pct = 0;
        vec_pct = 0;
    } else if fn_has_opt_size(caller) {
        if p.has_opt_size { cas[c].threshold = min(cas[c].threshold, p.opt_size); }
    }
    if !fn_has_min_size(caller) {
        let has_hint = if fn_has_opt_size(caller) { p.has_opt_size_hint } else { p.has_hint };
        let hint = if fn_has_opt_size(caller) { p.opt_size_hint } else { p.hint };
        if fn_has(callee, 0, AK_InlineHint) && has_hint { cas[c].threshold = max(cas[c].threshold, hint); }
        let with_bfi = cas[c].with_bfi;
        let hok, hot = ca_hot_call_site_threshold(cb, with_bfi);
        if !fn_has_opt_size(caller) && hok {
            cas[c].threshold = hot;
        } else if ca_is_cold_call_site(cb, with_bfi) {
            sbb_pct = 0; vec_pct = 0; last_call_bonus = 0;
            if p.has_cold_cs { cas[c].threshold = min(cas[c].threshold, p.cold_cs); }
        } else if cas[c].with_psi {
            if psi_is_function_entry_hot(callee) {
                if has_hint { cas[c].threshold = max(cas[c].threshold, hint); }
            } else if psi_is_function_entry_cold(callee) {
                sbb_pct = 0; vec_pct = 0; last_call_bonus = 0;
                if p.has_cold { cas[c].threshold = min(cas[c].threshold, p.cold); }
            }
        }
    }
    cas[c].threshold = w32(cas[c].threshold + tti_adjust_inlining_threshold(cb));
    cas[c].threshold = w32(cas[c].threshold * tti_inlining_threshold_multiplier());
    cas[c].single_bb_bonus = w32(w32(cas[c].threshold * sbb_pct) / 100);
    cas[c].vector_bonus = w32(w32(cas[c].threshold * vec_pct) / 100);
    if is_sole_call_to_local_function(cb, cas[c].f) {
        ca_add_cost(-last_call_bonus);
        cas[c].static_bonus = last_call_bonus;
    }
}

// onAnalysisStart -> success
fn ca_on_analysis_start() -> bool {
    let c = ca_cur();
    ca_update_threshold(cas[c].call, cas[c].f);
    cas[c].threshold = w32(cas[c].threshold + cas[c].single_bb_bonus + cas[c].vector_bonus);
    ca_add_cost(-get_callsite_cost(cas[c].call));
    if globs[glob_of(cas[c].f)].cc as i64 == 9 { ca_add_cost(IC_COLDCC_PENALTY); }   // CallingConv::Cold
    if cas[c].cost >= cas[c].threshold && !cas[c].compute_full { return false; }
    return true;
}

// isCostBenefitAnalysisEnabled
fn ca_cba_enabled(cb: i32, callee: i32, with_psi: bool, with_bfi: bool) -> bool {
    if !with_psi || !psi_has_summary { return false; }
    if !with_bfi { return false; }
    if ic_given("inline-enable-cost-benefit-analysis") {
        if !flag_bool("inline-enable-cost-benefit-analysis", false) { return false; }
    } else {
        if !psi_has_instrumentation_profile() { return false; }
    }
    let caller = inst_func(cb);
    let eok, ec = fn_entry_count(caller);
    if !eok { return false; }
    if !psi_is_hot_call_site(cb, true) { return false; }
    let fok, fc = fn_entry_count(callee);
    if !fok || fc == 0 { return false; }
    return true;
}

// costBenefitAnalysis: 0 none, 1 true, 2 false
fn ca_cost_benefit_analysis() -> i64 {
    let c = ca_cur();
    if !cas[c].cba_enabled { return 0; }
    if cas[c].threshold == 0 { return 0; }
    let f = cas[c].f;
    let ic = ic_instr_cost() as u64;
    var savings = ap_zero(128);
    var b = func_first_block(f);
    while b >= 0 {
        var cur = ap_zero(128);
        var i = block_first(b);
        while i >= 0 {
            if iop(i) == OP_CONDBR {
                if ca_simpl_cint(op(i, 0)) >= 0 { cur = ap_add_u64(cur, ic); }
            } else if iop(i) == OP_SWITCH {
                if ca_simpl_cint(op(i, 0)) >= 0 { cur = ap_add_u64(cur, ic); }
            } else if ca_has(K_SIMPL, i) { cur = ap_add_u64(cur, ic); }
            i = inst_next(i);
        }
        let ok, pc = bfi_block_profile_count(b);
        cur = ap_mul(cur, ap_u64(pc, 128));
        savings = ap_add(savings, cur);
        b = block_next(b);
    }
    let eok, ec = fn_entry_count(f);
    savings = ap_add_u64(savings, ec / 2);
    savings = ap_udiv(savings, ap_u64(ec, 128));
    let cb = cas[c].call;
    savings = ap_add_u64(savings, get_callsite_cost(cb) as u64);
    let pok, ppc = bfi_block_profile_count(inst_parent(cb));
    savings = ap_mul(savings, ap_u64(ppc, 128));
    var size = cas[c].cost - cas[c].cold_size;
    let allow = ic_opt("inline-size-allowance", 100);
    size = if size > allow { size - allow } else { 1 };
    let sok, sv = ic_call_str_int(cb, "inline-cycle-savings-for-test");
    if sok { savings = ap_u64(sv as! u64, 128); }
    let rok, rv = ic_call_str_int(cb, "inline-runtime-cost-for-test");
    if rok { size = rv; }
    var thr = ap_u64(psi_hot_count_threshold_or_max(), 128);
    thr = ap_mul(thr, ap_u64(size as! u64, 128));
    let smul = if ic_given("inline-savings-multiplier") { ic_opt("inline-savings-multiplier", 8) } else { tti_cb_savings_multiplier() };
    let pmul = if ic_given("inline-savings-profitable-multiplier") { ic_opt("inline-savings-profitable-multiplier", 4) } else { tti_cb_profitable_multiplier() };
    let upper = ap_mul(savings, ap_u64(smul as u64, 128));
    if ap_uge(upper, thr) { return 1; }
    let lower = ap_mul(savings, ap_u64(pmul as u64, 128));
    if ap_ult(lower, thr) { return 2; }
    return 0;
}

// finalizeAnalysis -> success
fn ca_finalize_analysis() -> bool {
    let c = ca_cur();
    let caller = inst_func(cas[c].call);
    if fn_has_min_size(caller) {
        // the callee's loops not headed by a dead block
        let f = cas[c].f;
        li_get(f);
        var nl: i64 = 0;
        for k in li_ntop(f) {
            let l = li_top(f, k);
            if !ca_has(K_DEAD, loop_header(l)) { nl++; }
        }
        ca_add_cost(nl * IC_LOOP_PENALTY);
    }
    if cas[c].num_vector_instructions <= cas[c].num_instructions / 10 { cas[c].threshold -= cas[c].vector_bonus; }
    else if cas[c].num_vector_instructions <= cas[c].num_instructions / 2 { cas[c].threshold -= cas[c].vector_bonus / 2; }
    let cb = cas[c].call;
    let aok, ac = ic_call_str_int(cb, "function-inline-cost");
    if aok { cas[c].cost = ac; }
    let mok, mc = ic_call_str_int(cb, "function-inline-cost-multiplier");
    if mok { cas[c].cost = w32(cas[c].cost * mc); }
    let tok, tv = ic_call_str_int(cb, "function-inline-threshold");
    if tok { cas[c].threshold = tv; }
    let r = ca_cost_benefit_analysis();
    if r != 0 {
        cas[c].decided_by_cb = true;
        return r == 1;
    }
    if cas[c].ignore_threshold { return true; }
    cas[c].decided_by_cost_threshold = true;
    return cas[c].cost < max(1, cas[c].threshold);
}

// ---------------------------------------------------------------------------------------------
// CallAnalyzer helpers

fn ca_disable_sroa_for_arg(a: i32) {
    ca_on_disable_sroa(a);
    ca_del(K_SROA_EN, a);
    ca_disable_load_elimination();
}
fn ca_disable_sroa(v: i32) { let a = ca_sroa_arg_or_null(v); if a >= 0 { ca_disable_sroa_for_arg(a); } }
fn ca_disable_load_elimination() {
    let c = ca_cur();
    if cas[c].enable_load_elim {
        ca_on_disable_load_elimination();
        cas[c].enable_load_elim = false;
    }
}
// handleSROA
fn ca_handle_sroa(v: i32, do_not_disable: bool) -> bool {
    let a = ca_sroa_arg_or_null(v);
    if a >= 0 {
        if do_not_disable { ca_on_aggregate_sroa_use(a); return true; }
        ca_disable_sroa_for_arg(a);
    }
    return false;
}

// accumulateGEPOffset(GEP, Offset) -> (ok, offset)
fn ca_accumulate_gep_offset(g: i32, off0: AP) -> bool, AP {
    var off = off0;
    let w = off.w as i64;
    var t = gep_src_ty(g);
    let n = nops(g);
    for k in 1..n {
        let ix = op(g, k);
        let oc = ca_dos_cint(ix);
        if oc < 0 { return false, off; }
        if k > 1 {
            if ty_is_struct(t) {
                if !cint_is_zero(oc) {
                    let el = ci_val(oc) as i64;
                    off = ap_add(off, ap_u64(dl_struct_offset(t, el) as u64, w));
                }
                t = ty_field(t, ci_val(oc) as i64);
                continue;
            }
            let et = ty_elem(t);
            if !cint_is_zero(oc) {
                let stride = dl_gep_stride(t, et);
                off = ap_add(off, ap_mul(ap_sext_or_trunc(ap_from_cint(oc), w), ap_u64(stride as u64, w)));
            }
            t = et;
        } else {
            if !cint_is_zero(oc) {
                let stride = dl_alloc_size(t);
                off = ap_add(off, ap_mul(ap_sext_or_trunc(ap_from_cint(oc), w), ap_u64(stride as u64, w)));
            }
        }
    }
    return true, off;
}

// isGEPFree: getInstructionCost with the simplified constant indices
fn ca_is_gep_free(g: i32) -> bool {
    tti_ovr_ops.resize(0);
    tti_ovr_ops.push(op(g, 0));
    for k in 1..nops(g) {
        let o = op(g, k);
        let s = ca_simpl_const(o);
        tti_ovr_ops.push(if s >= 0 { s } else { o });
    }
    tti_ovr_inst = g;
    let c = tti_instruction_cost(g, TCK_SIZE_AND_LATENCY);
    tti_ovr_inst = -1;
    return c == TCC_FREE;
}

// simplifyInstruction(I): fold when every operand is (or simplified to) a constant
fn ca_simplify_instruction(i: i32) -> bool {
    let mark = is_ops.len;
    let n = nops(i);
    for k in n {
        let c = ca_dos_const(op(i, k));
        if c < 0 { is_ops.resize(mark); return false; }
        is_ops.push(c);
    }
    let r = cf_fold_inst_operands(i, mark, n, true);
    is_ops.resize(mark);
    if r < 0 { return false; }
    ca_set_simpl(i, r);
    return true;
}

// stripAndComputeInBoundsConstantOffsets(V) -> (offset constant or -1, V)
fn ca_strip_inbounds_offsets(v0: i32) -> i32, i32 {
    var v = v0;
    if ty_kind(vals[v].ty) != TK_PTR { return -1, v; }
    let w = dl_ptr(ptr_as(vals[v].ty)).idx;
    var off = ap_zero(w);
    var visited: i32[>..<] = [v];
    loop {
        if opcode_of(v) == OP_GEP {
            if (gep_flags(v) & GEP_INBOUNDS) == 0 { return -1, v; }
            let ok, o2 = ca_accumulate_gep_offset(v, off);
            if !ok { return -1, v; }
            off = o2;
            v = op(v, 0);
        } else if vals[v].kind == VK_ALIAS {
            if gv_is_interposable(v, true) { break; }
            v = op(v, 0);
        } else { break; }
        var seen = false;
        for x in visited { if x == v { seen = true; } }
        if seen { break; }
        visited.push(v);
    }
    return ap_to_cint(ty_int(w), off), v;
}

// findDeadBlocks(CurrBB, NextBB)
fn ca_is_edge_dead(pred: i32, succ: i32) -> bool {
    if ca_has(K_DEAD, pred) { return true; }
    let ks = ca_get(K_KSUCC, pred);
    return ks >= 0 && ks != succ;
}
fn ca_is_newly_dead(bb: i32) -> bool {
    if ca_has(K_DEAD, bb) { return false; }
    var all = true;
    each_pred(bb) { p => if all && !ca_is_edge_dead(p, bb) { all = false; } };
    return all;
}
fn ca_find_dead_blocks(cur: i32, next: i32) {
    let ns = block_nsucc(cur);
    for k in ns {
        let s = block_succ(cur, k);
        if s == next || !ca_is_newly_dead(s) { continue; }
        var nd: i32[>..<] = [s];
        while nd.len > 0 {
            let d = nd.pop();
            if !ca_has(K_DEAD, d) {
                ca_set(K_DEAD, d, 1);
                let dn = block_nsucc(d);
                for j in dn { let x = block_succ(d, j); if ca_is_newly_dead(x) { nd.push(x); } }
            }
        }
    }
}

// CodeMetrics::collectEphemeralValues(F, AC, EphValues) into K_EPH
fn ca_collect_ephemeral_values(f: i32) {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    fn append_ops(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            let key = (o as i64) as u64;
            if hm_has(visited, key) { continue; }
            hm_put(visited, key, 1);
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    var cell = ia_assumptions_first(f);
    while cell >= 0 {
        let a = ia_ac_val[cell];
        cell = ia_ac_next[cell];
        if is_dead(a) { continue; }
        if !ca_has(K_EPH, a) { ca_set(K_EPH, a, 1); append_ops(a); }
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !ca_has(K_EPH, uses[u].user) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        ca_set(K_EPH, v, 1);
        append_ops(v);
    }
}

// The AssumptionCache of a function: its assumption list in registration order (the scan order of the first
// request, then the assumptions registered by the inliner). Lists are linked cells (head/tail per function).
var ia_ac_head = hm_new();
var ia_ac_tail = hm_new();
var ia_ac_val: i32[>..];
var ia_ac_next: i32[>..];
fn ia_ac_append(f: i32, a: i32) {
    let c = ia_ac_val.len as i32;
    ia_ac_val.push(a);
    ia_ac_next.push(-1);
    let key = (f as i64) as u64;
    let t = hm_get(ia_ac_tail, key, -1) as i32;
    if t >= 0 { ia_ac_next[t] = c; } else { hm_put(ia_ac_head, key, c as i64); }
    hm_put(ia_ac_tail, key, c as i64);
}
// the first cell of f's list (scanning the function on first use); -1 at the end
fn ia_assumptions_first(f: i32) -> i32 {
    let key = (f as i64) as u64;
    if !hm_has(ia_ac_head, key) {
        hm_put(ia_ac_head, key, -1);
        each_inst(f) { i => if inst_iid(i) == IID_assume { ia_ac_append(f, i); } };
    }
    return hm_get(ia_ac_head, key, -1) as i32;
}
// AssumptionCache::registerAssumption (only once the cache exists)
fn ia_register_assumption(f: i32, a: i32) {
    if !hm_has(ia_ac_head, (f as i64) as u64) { return; }
    ia_ac_append(f, a);
}

// ---------------------------------------------------------------------------------------------
// The visitors (InstVisitor dispatch: Base::visitX delegates to the overridden visitBinaryOperator /
// visitCmpInst / visitCastInst / visitCallBase / visitInstruction)

fn ca_visit_alloca(i: i32) -> bool {
    let c = ca_cur();
    ca_disable_sroa(op(i, 0));
    let x = insts[inst_of(i)];
    let at = x.ty2;
    let size_op = op(i, 0);
    // isArrayAllocation: the size operand isn't the constant 1
    let is_array = !(ia_is_cint(size_op) && cint_lo(size_op) == 1 && ap_eq(ap_from_cint(size_op), ap_u64(1, ty_bits(vals[size_op].ty))));
    if is_array {
        let sz = ca_simpl_const(size_op);
        if ia_is_cint(sz) {
            let n = ap_limited(ap_from_cint(sz), 0xFFFFFFFFFFFFFFFF);
            cas[c].allocated_size = sat_mul_add(n, dl_alloc_size(at) as u64, cas[c].allocated_size);
            if cas[c].allocated_size > IC_MAX_SIMPLIFIED_DYNAMIC_ALLOCA { cas[c].has_dynamic_alloca = true; }
            return false;
        }
    }
    if tti_is_static_alloca(i) {
        let sz, known, scal = ml_alloca_size(i);
        let s = if known { sz } else { 0 };
        cas[c].allocated_size = sat_add(s, cas[c].allocated_size);
    } else {
        cas[c].has_dynamic_alloca = true;
    }
    return false;
}
fn sat_add(a: u64, b: u64) -> u64 { let s = a + b; if s < a { 0xFFFFFFFFFFFFFFFF } else { s } }
fn sat_mul_add(a: u64, b: u64, c: u64) -> u64 {
    let lo, hi = ap_mul64(a, b);
    if hi != 0 { return 0xFFFFFFFFFFFFFFFF; }
    return sat_add(lo, c);
}

fn ca_visit_phi(i: i32) -> bool {
    let w = dl_ptr(0).bits;
    let check_sroa = ty_kind(vals[i].ty) == TK_PTR;
    var first_c: i32 = -1;
    var first_base: i32 = -1;
    var first_off = ap_zero(w);
    var first_v: i32 = -1;
    let bb = inst_parent(i);
    let n = nops(i);
    for k in n {
        let pred = phi_block(i, k);
        if ca_has(K_DEAD, pred) { continue; }
        let ks = ca_get(K_KSUCC, pred);
        if ks >= 0 && ks != bb { continue; }
        let v = phi_value(i, k);
        if v == i { continue; }
        let cst = ca_dos_const(v);
        var base: i32 = -1;
        var off = ap_zero(w);
        if cst < 0 && check_sroa { let b2, o2 = ca_cop(v); base = b2; off = o2; }
        if cst < 0 && base < 0 { return true; }
        if first_c >= 0 {
            if first_c == cst { continue; }
            return true;
        }
        if first_v >= 0 {
            if first_base == base && ap_same(first_off, off) { continue; }
            return true;
        }
        if cst >= 0 { first_c = cst; continue; }
        first_v = v;
        first_base = base;
        first_off = off;
    }
    if first_c >= 0 { ca_set_simpl(i, first_c); return true; }
    if first_base >= 0 {
        ca_set_cop(i, first_base, first_off);
        let a = ca_sroa_arg_or_null(first_v);
        if a >= 0 { ca_set_sroa(i, a); }
    }
    return true;
}

fn ca_can_fold_inbounds_gep(i: i32) -> bool {
    let base, off = ca_cop(op(i, 0));
    if base < 0 { return false; }
    let ok, o2 = ca_accumulate_gep_offset(i, off);
    if !ok { return false; }
    ca_set_cop(i, base, o2);
    return true;
}

fn ca_visit_gep(i: i32) -> bool {
    let sroa = ca_sroa_arg_or_null(op(i, 0));
    if !flag_bool("disable-gep-const-evaluation", false) {
        if ca_simplify_instruction(i) { return true; }
    }
    var consts = true;
    for k in 1..nops(i) { if ca_dos_const(op(i, k)) < 0 { consts = false; break; } }
    if (((gep_flags(i) & GEP_INBOUNDS) != 0) && ca_can_fold_inbounds_gep(i)) || consts {
        if sroa >= 0 { ca_set_sroa(i, sroa); }
        return true;
    }
    if sroa >= 0 { ca_disable_sroa_for_arg(sroa); }
    return ca_is_gep_free(i);
}

fn ca_visit_bitcast(i: i32) -> bool {
    if ca_simplify_instruction(i) { return true; }
    let base, off = ca_cop(op(i, 0));
    if base >= 0 { ca_set_cop(i, base, off); }
    let a = ca_sroa_arg_or_null(op(i, 0));
    if a >= 0 { ca_set_sroa(i, a); }
    return true;
}
fn ca_visit_ptrtoint(i: i32) -> bool {
    if ca_simplify_instruction(i) { return true; }
    let isz = ty_bits(ty_scalar(vals[i].ty));
    let as_ = ptr_as(vals[op(i, 0)].ty);
    if isz == dl_ptr(as_).bits {
        let base, off = ca_cop(op(i, 0));
        if base >= 0 { ca_set_cop(i, base, off); }
    }
    let a = ca_sroa_arg_or_null(op(i, 0));
    if a >= 0 { ca_set_sroa(i, a); }
    return tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}
fn ca_visit_inttoptr(i: i32) -> bool {
    if ca_simplify_instruction(i) { return true; }
    let o = op(i, 0);
    let isz = ty_bits(ty_scalar(vals[o].ty));
    if isz <= dl_ptr(ptr_as(vals[i].ty)).bits {
        let base, off = ca_cop(o);
        if base >= 0 { ca_set_cop(i, base, off); }
    }
    let a = ca_sroa_arg_or_null(o);
    if a >= 0 { ca_set_sroa(i, a); }
    return tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}
fn ca_visit_cast(i: i32) -> bool {
    if ca_simplify_instruction(i) { return true; }
    ca_disable_sroa(op(i, 0));
    let o = iop(i);
    if o == OP_FPTRUNC || o == OP_FPEXT || o == OP_UITOFP || o == OP_SITOFP || o == OP_FPTOUI || o == OP_FPTOSI {
        if tti_fp_op_cost(vals[i].ty) == TCC_EXPENSIVE { ca_on_call_penalty(); }
    }
    return tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}

fn ca_is_known_non_null_in_callee(v: i32) -> bool {
    let c = ca_cur();
    if is_arg(v) && cb_param_has_attr(cas[c].call, args_no[vals[v].sub] as i64, AK_NonNull) { return true; }
    if ca_has(K_SROA, v) { return true; }
    return false;
}

// simplifyCmpInstForRecCall
fn ca_simplify_cmp_for_rec_call(i: i32) -> bool {
    let c = ca_cur();
    let cmp_op = op(i, 0);
    if !is_arg(cmp_op) || !is_constant(op(i, 1)) { return false; }
    let cb = cas[c].call;
    if inst_func(cb) != cas[c].f { return false; }
    let call_bb = inst_parent(cb);
    let pred = single_pred(call_bb);
    if pred < 0 { return false; }
    let br = block_terminator(pred);
    if br < 0 || iop(br) != OP_CONDBR || op(br, 0) != i { return false; }
    let f = cas[c].f;
    var found = false;
    var func_arg: i32 = -1;
    var call_arg: i32 = -1;
    let na = min(func_nargs(f), cb_nargs(cb));
    for k in na {
        func_arg = func_arg_v(f, k);
        call_arg = cb_arg(cb, k);
        if func_arg == cmp_op && call_arg != cmp_op { found = true; break; }
    }
    if !found { return false; }
    let invert = call_bb != term_succ(br, 0);
    // SimplifyQuery(DL, CxtI = the call argument if an instruction) with the CondContext of the compare
    let scc = kb_cc_cond;
    let sinv = kb_cc_invert;
    let saff = kb_cc_aff.len;
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cc_cond = i;
    kb_cc_invert = invert;
    let aff_mark = kb_cc_aff.len;
    kb_cc_aff.push(func_arg);
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let mark = is_ops.len;
    is_ops.push(call_arg);
    is_ops.push(op(i, 1));
    let cx = if is_inst(call_arg) { call_arg } else { -1 };
    kb_cxt = cx;
    let r = simplify_inst_with_ops(i, mark, 2, sq_new(cx), RECURSION_LIMIT);
    is_ops.resize(mark);
    kb_cc_aff.resize(aff_mark);
    kb_cc_cond = scc;
    kb_cc_invert = sinv;
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    if ia_is_cint(r) {
        if (cint_lo(r) == 1 && invert) || (cint_is_zero(r) && !invert) {
            ca_set_simpl(i, r);
            return true;
        }
    }
    return false;
}
fn func_arg_v(f: i32, k: i64) -> i32 { func_arg(f, k) }

fn ca_visit_cmp(i: i32) -> bool {
    let l = op(i, 0);
    let r = op(i, 1);
    if ca_simplify_instruction(i) { return true; }
    if ca_simplify_cmp_for_rec_call(i) { return true; }
    if iop(i) == OP_FCMP { return false; }
    let lb, lo = ca_cop(l);
    if lb >= 0 {
        let rb, ro = ca_cop(r);
        if rb >= 0 && lb == rb {
            let res = ap_icmp(lo, ro, inst_pred(i));
            ca_set_simpl(i, c_bool_of_type(vals[i].ty, res));
            return true;
        }
    }
    let p = inst_pred(i);
    if (p == 32 || p == 33) && vals[r].kind == VK_CNULL {
        if ca_is_known_non_null_in_callee(l) {
            ca_set_simpl(i, c_bool_of_type(vals[i].ty, p == 33));
            return true;
        }
        // isImplicitNullCheckCmp: every user carries !make.implicit
        var all = true;
        let mk = md_kind_id("make.implicit");
        var u = vals[i].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if is_inst(us) && inst_get_md(us, mk) < 0 { all = false; }
            u = uses[u].next;
        }
        if all { return true; }
    }
    return ca_handle_sroa(l, vals[r].kind == VK_CNULL);
}
// ConstantInt::getBool(Ty, B) (a vector type gives a splat)
fn c_bool_of_type(t: i32, b: bool) -> i32 {
    let s = if b { c_true() } else { c_false() };
    if ty_is_vector(t) { return c_splat(t, s); }
    return s;
}

recursive fn ca_visit_sub(i: i32) -> bool {
    let l = op(i, 0);
    let r = op(i, 1);
    let lb, lo = ca_cop(l);
    if lb >= 0 {
        let rb, ro = ca_cop(r);
        if rb >= 0 && lb == rb {
            let cl = ap_to_cint(ty_int(lo.w as i64), lo);
            let cr = ap_to_cint(ty_int(ro.w as i64), ro);
            let cs = ce_binop(OP_SUB, cl, cr, 0);
            if cs >= 0 { ca_set_simpl(i, cs); return true; }
        }
    }
    return ca_visit_binop(i);
}

recursive fn ca_visit_binop(i: i32) -> bool {
    let l = op(i, 0);
    let r = op(i, 1);
    let cl = ca_dos_const(l);
    let cr = ca_dos_const(r);
    let a = if cl >= 0 { cl } else { l };
    let b = if cr >= 0 { cr } else { r };
    // simplifyBinOp(..., DL): a SimplifyQuery with only the DataLayout
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    kb_cxt = -1;
    var sv: i32 = -1;
    if is_fp_math_operator(i) { sv = simplify_binop_fmf(iop(i), a, b, insts[inst_of(i)].fmf, sq_new(-1), RECURSION_LIMIT); }
    else { sv = simplify_binop(iop(i), a, b, sq_new(-1), RECURSION_LIMIT); }
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    if sv >= 0 && is_constant(sv) { ca_set_simpl(i, sv); }
    if sv >= 0 { return true; }
    ca_disable_sroa(l);
    ca_disable_sroa(r);
    if ty_is_fp(vals[i].ty) && tti_fp_op_cost(vals[i].ty) == TCC_EXPENSIVE && !ca_is_fneg_pattern(i) { ca_on_call_penalty(); }
    return false;
}
// match(&I, m_FNeg(m_Value())) on a binary operator: fsub -0.0, X (or fsub nsz 0.0, X)
fn ca_is_fneg_pattern(i: i32) -> bool {
    if iop(i) != OP_FSUB { return false; }
    let z = op(i, 0);
    if !is_constant(z) { return false; }
    return m_fneg(i) >= 0;
}

fn ca_visit_fneg(i: i32) -> bool {
    let o = op(i, 0);
    let co = ca_dos_const(o);
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let sv = simplify_fneg(if co >= 0 { co } else { o }, insts[inst_of(i)].fmf, sq_new(-1));
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    if sv >= 0 && is_constant(sv) { ca_set_simpl(i, sv); }
    if sv >= 0 { return true; }
    ca_disable_sroa(o);
    return false;
}

fn ca_visit_load(i: i32) -> bool {
    let c = ca_cur();
    let p = op(i, 0);
    let simple = insts[inst_of(i)].ord == 0 && (insts[inst_of(i)].bits & 1) == 0;
    if ca_handle_sroa(p, simple) { return true; }
    if cas[c].enable_load_elim {
        let had = ca_has(K_LOADADDR, p);
        if !had { ca_set(K_LOADADDR, p, 1); }
        if had && ldst_is_unordered(i) { ca_on_load_elimination_opportunity(); return true; }
    }
    ca_on_mem_access();
    return false;
}
fn ca_visit_store(i: i32) -> bool {
    let p = op(i, 1);
    let simple = insts[inst_of(i)].ord == 0 && (insts[inst_of(i)].bits & 1) == 0;
    if ca_handle_sroa(p, simple) { return true; }
    ca_disable_load_elimination();
    ca_on_mem_access();
    return false;
}

fn ca_visit_extractvalue(i: i32) -> bool {
    let o = op(i, 0);
    let so = ca_simpl(o);
    if so >= 0 {
        let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
        sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
        let sv = simplify_extractvalue(i, so, sq_new(-1));
        sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
        if sv >= 0 { ca_set_simpl(i, sv); return true; }
    }
    return ca_visit_instruction(i);
}
fn ca_visit_insertvalue(i: i32) -> bool {
    if ca_simplify_instruction(i) { return true; }
    return ca_visit_instruction(i);
}

fn ca_visit_select(i: i32) -> bool {
    let check_sroa = ty_kind(vals[i].ty) == TK_PTR;
    let tv = op(i, 1);
    let fv = op(i, 2);
    let tc = ca_dos_const(tv);
    let fc = ca_dos_const(fv);
    let cc = ca_simpl_const(op(i, 0));
    if cc < 0 {
        if tc == fc && tc >= 0 { ca_set_simpl(i, tc); return true; }
        if !check_sroa { return ca_visit_instruction(i); }
        let tb, to = ca_cop(tv);
        let fb, fo = ca_cop(fv);
        if tb == fb && ap_same(to, fo) && tb >= 0 {
            ca_set_cop(i, tb, to);
            let a = ca_sroa_arg_or_null(tv);
            if a >= 0 { ca_set_sroa(i, a); }
            return true;
        }
        return ca_visit_instruction(i);
    }
    var sel: i32 = -1;
    if is_all_ones_value(cc) { sel = tv; } else if is_null_value(cc) { sel = fv; }
    if sel < 0 {
        if tc >= 0 && fc >= 0 {
            let r = cf_select(cc, tc, fc);
            if r >= 0 { ca_set_simpl(i, r); return true; }
        }
        return ca_visit_instruction(i);
    }
    if is_constant(sel) { ca_set_simpl(i, sel); return true; }
    if !check_sroa { return true; }
    let b, o = ca_cop(sel);
    if b >= 0 {
        ca_set_cop(i, b, o);
        let a = ca_sroa_arg_or_null(sel);
        if a >= 0 { ca_set_sroa(i, a); }
    }
    return true;
}

fn ca_visit_switch(i: i32) -> bool {
    let c = ca_cur();
    if ca_dos_cint(op(i, 0)) >= 0 { return true; }
    let ncl, jts = tti_case_clusters(i, cas[c].with_psi, cas[c].with_bfi);
    let dd = first_non_phi(op(i, 1));
    let unreach = dd >= 0 && iop(dd) == OP_UNREACHABLE;
    ca_on_finalize_switch(jts, ncl, unreach);
    return false;
}

fn ca_visit_instruction(i: i32) -> bool {
    if tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) == TCC_FREE { return true; }
    for k in nops(i) { ca_disable_sroa(op(i, k)); }
    return false;
}

// simplifyCallSite(F, Call)
fn ca_simplify_call_site(f: i32, cb: i32) -> bool {
    if !can_constant_fold_call_to(cb, f) { return false; }
    let mark = is_ops.len;
    let n = cb_nargs(cb);
    for k in n {
        let c = ca_dos_const(cb_arg(cb, k));
        if c < 0 { is_ops.resize(mark); return false; }
        is_ops.push(c);
    }
    // ConstantFoldCall(&Call, F, ConstantArgs) without a TargetLibraryInfo
    let stli = sq_no_tli;
    sq_no_tli = true;
    let r = cf_fold_call(cb, f, mark, n, true);
    sq_no_tli = stli;
    is_ops.resize(mark);
    if r >= 0 { ca_set_simpl(cb, r); return true; }
    return false;
}

// isLoweredToCall(F, Call)
fn ca_is_lowered_to_call(f: i32, cb: i32) -> bool {
    let lf = tli_get_libfunc(f);
    tli_cur_fn = f;
    if lf < 0 || !tli_has(lf) { return tti_is_lowered_to_call(f); }
    let nm = TLI_DEFS[lf];
    if nm == "memcpy_chk" || nm == "memmove_chk" || nm == "mempcpy_chk" || nm == "memset_chk" {
        let len = ca_dos_cint(op(cb, 2));
        let osz = ca_dos_cint(op(cb, 3));
        if len >= 0 && osz >= 0 && ap_limited(ap_from_cint(len), 0xFFFFFFFFFFFFFFFF) <= ap_limited(ap_from_cint(osz), 0xFFFFFFFFFFFFFFFF) { return false; }
    }
    return tti_is_lowered_to_call(f);
}

recursive fn ca_visit_call_base(cb: i32) -> bool {
    let c = ca_cur();
    // onCallBaseVisitStart
    let bok, bonus = ic_call_str_int(cb, "call-threshold-bonus");
    if bok { cas[c].threshold = w32(cas[c].threshold + bonus); }
    let cok, ccost = ic_call_str_int(cb, "call-inline-cost");
    if cok { ca_add_cost(ccost); return true; }
    if call_has_fn_attr(cb, AK_ReturnsTwice) && !fn_has(cas[c].f, 0, AK_ReturnsTwice) {
        cas[c].exposes_returns_twice = true;
        return false;
    }
    if iop(cb) == OP_CALL && call_has_fn_attr(cb, AK_NoDuplicate) { cas[c].contains_noduplicate = true; }
    let callee_op = cb_callee(cb);
    if vals[callee_op].kind == VK_INLINEASM { ca_on_inline_asm(callee_op); }
    var f = called_function(cb);
    let indirect = f < 0;
    if indirect {
        let s = ca_simpl(callee_op);
        f = if s >= 0 && is_func(s) { s } else { -1 };
        if f < 0 || globs[glob_of(f)].vty != insts[inst_of(cb)].ty2 {
            ca_on_call_argument_setup(cb);
            if !call_only_reads_memory(cb) { ca_disable_load_elimination(); }
            return ca_visit_instruction(cb);
        }
    }
    if ca_simplify_call_site(f, cb) { return true; }
    let id = if iop(cb) == OP_CALL { call_iid(cb) } else { 0 };
    if id != 0 {
        if id == IID_load_relative { ca_on_load_relative_intrinsic(); return false; }
        if id == IID_memset || id == IID_memcpy || id == IID_memmove { ca_disable_load_elimination(); return false; }
        if id == IID_icall_branch_funnel || id == IID_localescape { cas[c].has_uninlineable_intrinsic = true; return false; }
        if id == IID_va_start { cas[c].inits_varargs = true; return false; }
        if id == IID_launder_invariant_group || id == IID_strip_invariant_group {
            let a = ca_sroa_arg_or_null(op(cb, 0));
            if a >= 0 { ca_set_sroa(cb, a); }
            return true;
        }
        if id == IID_is_constant {
            let cv = ca_dos_const(cb_arg(cb, 0));
            let rt = ty_fn_ret(insts[inst_of(cb)].ty2);
            ca_set_simpl(cb, c_int(rt, if cv >= 0 { 1 } else { 0 }));
            return true;
        }
        if id == IID_objectsize {
            if cint_lo(cb_arg(cb, 3)) == 1 { return false; }
            let v = mb_lower_object_size_call(cb, true);
            if v >= 0 && is_constant(v) { ca_set_simpl(cb, v); return true; }
            return false;
        }
        if !call_only_reads_memory(cb) && !sc_is_assume_like(cb) { ca_disable_load_elimination(); }
        return ca_visit_instruction(cb);
    }
    if f == inst_func(cb) {
        cas[c].is_recursive_call = true;
        if !cas[c].allow_recursive_call { return false; }
    }
    if ca_is_lowered_to_call(f, cb) { ca_on_lowered_call(f, cb, indirect); }
    let c2 = ca_cur();
    if !(call_only_reads_memory(cb) || (indirect && me_only_reads(fn_memory_effects(f)))) { ca_disable_load_elimination(); }
    return ca_visit_instruction(cb);
}

// onLoweredCall
recursive fn ca_on_lowered_call(f: i32, cb: i32, indirect: bool) {
    let c = ca_cur();
    ca_add_cost(cb_nargs(cb) * ic_instr_cost());
    if indirect && cas[c].boost_indirect {
        var p = cas[c].params;
        p.default_threshold = IC_INDIRECT_CALL_THRESHOLD;
        let with_bfi = cas[c].with_bfi;
        let with_psi = cas[c].with_psi;
        ca_push(f, cb, p, with_bfi, with_psi, false, false);
        let ok = ca_analyze();
        let t = cas[ca_cur()].threshold;
        let co = cas[ca_cur()].cost;
        ca_pop();
        // the callee's TTI again (the nested analysis initialized it for its own callee)
        tti_init_function(cas[ca_cur()].f, globs[glob_of(cas[ca_cur()].f)].module);
        if ok { ca_add_cost(-max(0, t - co)); }
    } else {
        ca_add_cost(tti_inline_call_penalty(inst_func(cas[c].call), cb, ic_call_penalty()));
    }
}

recursive fn ca_visit(i: i32) -> bool {
    let o = iop(i);
    if o == OP_ALLOCA { return ca_visit_alloca(i); }
    if o == OP_PHI { return ca_visit_phi(i); }
    if o == OP_GEP { return ca_visit_gep(i); }
    if o == OP_BITCAST { return ca_visit_bitcast(i); }
    if o == OP_PTRTOINT { return ca_visit_ptrtoint(i); }
    if o == OP_INTTOPTR { return ca_visit_inttoptr(i); }
    if is_cast_op(o) || o == OP_PTRTOADDR { return ca_visit_cast(i); }
    if o == OP_ICMP || o == OP_FCMP { return ca_visit_cmp(i); }
    if o == OP_SUB { return ca_visit_sub(i); }
    if is_binary_op(o) { return ca_visit_binop(i); }
    if o == OP_FNEG { return ca_visit_fneg(i); }
    if o == OP_LOAD { return ca_visit_load(i); }
    if o == OP_STORE { return ca_visit_store(i); }
    if o == OP_EXTRACTVALUE { return ca_visit_extractvalue(i); }
    if o == OP_INSERTVALUE { return ca_visit_insertvalue(i); }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { return ca_visit_call_base(i); }
    if o == OP_RET {
        let c = ca_cur();
        let free = !cas[c].has_return;
        cas[c].has_return = true;
        return free;
    }
    if o == OP_BR { return true; }
    if o == OP_CONDBR {
        return ca_dos_cint(op(i, 0)) >= 0 || inst_get_md(i, md_kind_id("make.implicit")) >= 0;
    }
    if o == OP_SELECT { return ca_visit_select(i); }
    if o == OP_SWITCH { return ca_visit_switch(i); }
    if o == OP_INDIRECTBR { cas[ca_cur()].has_indirectbr = true; return false; }
    if o == OP_RESUME || o == OP_CLEANUPRET || o == OP_CATCHRET { return false; }
    if o == OP_UNREACHABLE { return true; }
    return ca_visit_instruction(i);
}

// analyzeBlock -> 0 success, else the failure reason (an interned string id)
recursive fn ca_analyze_block(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 {
        let cur_i = i;
        i = inst_next(i);
        if inst_iid(cur_i) == IID_pseudoprobe { continue; }
        if ca_has(K_EPH, cur_i) { continue; }
        let c = ca_cur();
        cas[c].num_instructions += 1;
        if iop(cur_i) == OP_EXTRACTELEMENT || ty_is_vector(vals[cur_i].ty) { cas[c].num_vector_instructions += 1; }
        if !ca_visit(cur_i) { ca_on_missed_simplification(); }
        let c2 = ca_cur();
        var fail: i32 = -1;
        if cas[c2].is_recursive_call && !cas[c2].allow_recursive_call { fail = intern("recursive"); }
        else if cas[c2].exposes_returns_twice { fail = intern("exposes returns twice"); }
        else if cas[c2].has_dynamic_alloca { fail = intern("dynamic alloca"); }
        else if cas[c2].has_indirectbr { fail = intern("indirect branch"); }
        else if cas[c2].has_uninlineable_intrinsic { fail = intern("uninlinable intrinsic"); }
        else if cas[c2].inits_varargs { fail = intern("varargs"); }
        if fail >= 0 { return fail; }
        if cas[c2].is_caller_recursive && cas[c2].allocated_size > (ic_opt("recursive-inline-max-stacksize", IC_TOTAL_ALLOCA_SIZE_RECURSIVE_CALLER as i64) as u64) {
            return intern("recursive and allocates too much stack space");
        }
        if ca_should_stop() { return intern("Call site analysis is not favorable to inlining."); }
    }
    return -1;
}

// The failure reason of the last analysis (-1 = success)
var ca_fail: i32 = -1;

// CallAnalyzer::analyze -> success; the reason is left in ca_fail
recursive fn ca_analyze() -> bool {
    ca_fail = -1;
    if !ca_on_analysis_start() { ca_fail = intern("high cost"); return false; }
    let c = ca_cur();
    let f = cas[c].f;
    if func_is_decl(f) { return true; }
    let caller = inst_func(cas[c].call);
    // IsCallerRecursive: a call from the caller to itself
    var u = vals[caller].first_use;
    while u >= 0 {
        let us = uses[u].user;
        if is_inst(us) && is_callbase(us) && inst_func(us) == caller { cas[c].is_caller_recursive = true; break; }
        u = uses[u].next;
    }
    let cb = cas[c].call;
    let na = func_nargs(f);
    for k in na {
        let fa = func_arg(f, k);
        let ca_ = cb_arg(cb, k);
        ca_set_simpl(fa, ca_);
        let off, base = ca_strip_inbounds_offsets(ca_);
        if off >= 0 {
            ca_set_cop(fa, base, ap_from_cint(off));
            if is_inst_op(base, OP_ALLOCA) {
                ca_set_sroa(fa, base);
                ca_on_initialize_sroa_arg(base);
                ca_set(K_SROA_EN, base, 1);
            }
        }
    }
    ca_collect_ephemeral_values(f);
    let base = ca_bbwl.len;
    cas[c].wl_base = base;
    let entry = func_entry(f);
    ca_bbwl.push(entry);
    ca_set(K_BBWL, entry, 1);
    var idx = base;
    while idx < ca_bbwl.len {
        if ca_should_stop() { break; }
        let bb = ca_bbwl[idx];
        idx++;
        if block_first(bb) < 0 { continue; }
        cas[ca_cur()].cost_at_bb_start = cas[ca_cur()].cost;
        if ic_block_address_taken(bb) { ca_bbwl.resize(base); ca_fail = intern("blockaddress used"); return false; }
        let r = ca_analyze_block(bb);
        if r >= 0 { ca_bbwl.resize(base); ca_fail = r; return false; }
        let t = block_terminator(bb);
        if iop(t) == OP_CONDBR {
            let sc = ca_simpl_cint(op(t, 0));
            if sc >= 0 {
                let next = term_succ(t, if cint_is_zero(sc) { 1 } else { 0 });
                ca_wl_insert(next);
                ca_set(K_KSUCC, bb, next as i64);
                ca_find_dead_blocks(bb, next);
                continue;
            }
        } else if iop(t) == OP_SWITCH {
            let sc = ca_simpl_cint(op(t, 0));
            if sc >= 0 {
                let next = ca_switch_case_dest(t, sc);
                ca_wl_insert(next);
                ca_set(K_KSUCC, bb, next as i64);
                ca_find_dead_blocks(bb, next);
                continue;
            }
        }
        let ns = term_nsucc(t);
        for k in ns { ca_wl_insert(term_succ(t, k)); }
        ca_on_block_analyzed(bb);
    }
    ca_bbwl.resize(base);
    let c3 = ca_cur();
    if !is_sole_call_to_local_function(cas[c3].call, f) && cas[c3].contains_noduplicate { ca_fail = intern("noduplicate"); return false; }
    var final_t = ic_opt("inline-max-stacksize", -1) as u64;
    if !ic_given("inline-max-stacksize") {
        let aok, av = ic_fn_str_int(caller, "inline-max-stacksize");
        if aok { final_t = (av as! u64); }
    }
    if cas[c3].allocated_size > final_t { ca_fail = intern("stacksize"); return false; }
    let ok = ca_finalize_analysis();
    if !ok { ca_fail = intern("Cost over threshold."); }
    return ok;
}
// SwitchInst::findCaseValue(C)->getCaseSuccessor()
fn ca_switch_case_dest(t: i32, c: i32) -> i32 {
    let n = (nops(t) - 2) / 2;
    for k in n { if op(t, 2 + 2 * k) == c { return op(t, 3 + 2 * k); } }
    return op(t, 1);
}
fn ca_wl_insert(bb: i32) { if !ca_has(K_BBWL, bb) { ca_set(K_BBWL, bb, 1); ca_bbwl.push(bb); } }

// Create an InlineCostCallAnalyzer on the stack
fn ca_push(callee: i32, cb: i32, p: IParams, with_bfi: bool, with_psi: bool, boost: bool, ignore_threshold: bool) {
    let ser = ca_next_ser;
    ca_next_ser++;
    let cba = ca_cba_enabled(cb, callee, with_psi, with_bfi);
    cas.push(CAS {
        ser: ser, f: callee, call: cb, caller: inst_func(cb), params: p,
        is_caller_recursive: false, is_recursive_call: false, exposes_returns_twice: false, has_dynamic_alloca: false,
        contains_noduplicate: false, has_return: false, has_indirectbr: false, has_uninlineable_intrinsic: false,
        inits_varargs: false, allocated_size: 0, num_instructions: 0, num_vector_instructions: 0,
        enable_load_elim: true, allow_recursive_call: p.allow_recursive_call,
        compute_full: flag_bool("inline-cost-full", false) || p.compute_full || cba,
        load_elim_cost: 0, vector_bonus: 0, single_bb_bonus: 0, threshold: p.default_threshold, static_bonus: 0,
        boost_indirect: boost, ignore_threshold: ignore_threshold, cba_enabled: cba, cost: 0, cost_at_bb_start: 0,
        cold_size: 0, decided_by_cost_threshold: false, decided_by_cb: false, single_bb: true, sroa_savings: 0,
        sroa_lost: 0, with_bfi: with_bfi, with_psi: with_psi, wl_base: 0 });
    tti_init_function(callee, globs[glob_of(callee)].module);
}
fn ca_pop() {
    cas.pop();
    if cas.len == 0 {
        hm_clear(cam);
        cop_base.resize(0);
        cop_off.resize(0);
    }
}

// getInlineCost(Call, Callee, Params, ...): with_bfi = GetBFI given, with_psi = a cached PSI
fn get_inline_cost(cb: i32, callee: i32, p: IParams, with_bfi: bool, with_psi: bool) -> ICost {
    if flag_bool("print-instruction-comments", false) { ic_not_ported("-print-instruction-comments"); }
    let d, why = get_attribute_based_inlining_decision(cb, callee);
    if d == 1 { return icost_always("always inline attribute"); }
    if d == 2 { return icost_never(why); }
    if flag_bool("inline-all-viable-calls", false) {
        let ok, w2 = is_inline_viable(callee);
        if ok { return icost_always("Inlining forced by -inline-all-viable-calls"); }
    }
    ca_push(callee, cb, p, with_bfi, with_psi, true, false);
    let ok = ca_analyze();
    let c = ca_cur();
    let by_cb = cas[c].decided_by_cb;
    let by_ct = cas[c].decided_by_cost_threshold;
    let cost = cas[c].cost;
    let thr = cas[c].threshold;
    let bonus = cas[c].static_bonus;
    let fail = ca_fail;
    ca_pop();
    if by_cb {
        if ok { return icost_always("benefit over cost"); }
        return icost_never("cost over benefit");
    }
    if by_ct { return icost_get(cost, thr, bonus); }
    if ok { return icost_always("empty function"); }
    return ICost { cost: INT_MAX32, threshold: 0, bonus: 0, reason: fail };
}

// getInliningCostEstimate(Call, ...): (has, cost)
fn get_inlining_cost_estimate(cb: i32, with_bfi: bool, with_psi: bool) -> bool, i64 {
    var p = ip_empty(0);
    p.compute_full = true;
    p.has_enable_deferral = true;
    p.enable_deferral = true;
    ca_push(called_function(cb), cb, p, with_bfi, with_psi, true, true);
    let ok = ca_analyze();
    let cost = cas[ca_cur()].cost;
    ca_pop();
    if !ok { return false, 0; }
    return true, cost;
}
