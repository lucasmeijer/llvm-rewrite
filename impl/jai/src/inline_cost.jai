// The inline cost model: a port of llvm/lib/Analysis/InlineCost.cpp (CallAnalyzer with the InlineCostCallAnalyzer
// callbacks: every visit*, analyzeBlock, analyze, updateThreshold, finalizeAnalysis, the SROA / load-elimination
// bookkeeping; getCallsiteCost, getInlineCost, getAttributeBasedInliningDecision, getInliningCostEstimate,
// isInlineViable, getInlineParams, functionsHaveCompatibleAttributes, the cl::opts), of the TargetTransformInfo
// inlining hooks (TargetTransformInfoImpl.h / BasicTTIImpl.h: thresholds, getFPOpCost,
// getEstimatedNumberOfCaseClusters with TargetLoweringBase::isSuitableForJumpTable / isSuitableForBitTests,
// X86TTIImpl::areInlineCompatible), CodeMetrics::collectEphemeralValues(Function) and
// TargetLibraryInfo::areInlineCompatible.
//
// CallAnalyzer is a base class with two subclasses in LLVM; only InlineCostCallAnalyzer matters here
// (InlineCostFeaturesAnalyzer serves the ML advisor), so the virtual on* callbacks are plain procedures.
// Not ported: the cost-benefit analysis (needs a profile summary: fails loudly when it would be enabled),
// -print-instruction-comments / print<inline-cost>.

ic_opts: struct {
    default_threshold: s64 = 225;          // -inlinedefault-threshold
    ignore_tti_inline_compatible := false; // -ignore-tti-inline-compatible
    inline_threshold: s64 = 225;           // -inline-threshold
    inline_threshold_given := false;
    hint_threshold: s64 = 325;             // -inlinehint-threshold
    cold_callsite_threshold: s64 = 45;     // -inline-cold-callsite-threshold
    cold_threshold: s64 = 45;              // -inlinecold-threshold
    cold_threshold_given := false;
    hot_callsite_threshold: s64 = 3000;    // -hot-callsite-threshold
    locally_hot_callsite_threshold: s64 = 525;   // -locally-hot-callsite-threshold
    locally_hot_given := false;
    cold_callsite_rel_freq: s64 = 2;       // -cold-callsite-rel-freq
    hot_callsite_rel_freq: u64 = 60;       // -hot-callsite-rel-freq
    instr_cost: s64 = 5;                   // -inline-instr-cost
    inline_asm_instr_cost: s64 = 0;        // -inline-asm-instr-cost
    mem_access_cost: s64 = 0;              // -inline-memaccess-cost
    call_penalty: s64 = 25;                // -inline-call-penalty
    stack_size_threshold: u64 = 0xFFFF_FFFF_FFFF_FFFF;   // -inline-max-stacksize
    stack_size_given := false;
    recur_stack_size_threshold: u64 = 1024;   // -recursive-inline-max-stacksize
    compute_full_inline_cost := false;     // -inline-cost-full
    caller_superset_nobuiltin := true;     // -inline-caller-superset-nobuiltin
    disable_gep_const_evaluation := false; // -disable-gep-const-evaluation
    inline_all_viable_calls := false;      // -inline-all-viable-calls
    min_jump_table_entries: u64 = 4;       // -min-jump-table-entries (TargetLoweringBase.cpp)
    max_jump_table_size: u64 = 0xFFFF_FFFF;   // -max-jump-table-size
    jump_table_density: u64 = 10;          // -jump-table-density
    optsize_jump_table_density: u64 = 40;  // -optsize-jump-table-density
    min_bit_test_cmps: u64 = 2;            // -min-bit-test-cmps
};

IC_OPT_SIZE_THRESHOLD :: 50;
IC_OPT_MIN_SIZE_THRESHOLD :: 5;
IC_OPT_AGGRESSIVE_THRESHOLD :: 250;
IC_INDIRECT_CALL_THRESHOLD :: 100;
IC_LOOP_PENALTY :: 25;
IC_COLDCC_PENALTY :: 2000;
IC_MAX_SIMPLIFIED_DYNAMIC_ALLOCA :: 65536;
IC_LAST_CALL_TO_STATIC_BONUS :: 15000;
INT_MIN32 :: -2147483648;
INT_MAX32 :: 2147483647;

// InlineParams (std::optional<int> fields: has_* flags)
Inline_Params :: struct {
    default_threshold: s64 = -1;
    hint_threshold: s64; has_hint: bool;
    opt_size_hint_threshold: s64; has_opt_size_hint: bool;
    cold_threshold: s64; has_cold: bool;
    opt_size_threshold: s64; has_opt_size: bool;
    opt_min_size_threshold: s64; has_opt_min_size: bool;
    hot_callsite_threshold: s64; has_hot_callsite: bool;
    locally_hot_callsite_threshold: s64; has_locally_hot: bool;
    cold_callsite_threshold: s64; has_cold_callsite: bool;
    compute_full_inline_cost: bool;
    enable_deferral: bool; has_enable_deferral: bool;
    allow_recursive_call := false;
}

// getInlineParams(Threshold)
get_inline_params_t :: (threshold: s64) -> Inline_Params {
    p: Inline_Params;
    p.default_threshold = ifx ic_opts.inline_threshold_given then ic_opts.inline_threshold else threshold;
    p.hint_threshold = ic_opts.hint_threshold; p.has_hint = true;
    p.opt_size_hint_threshold = ic_opts.hint_threshold; p.has_opt_size_hint = true;
    p.hot_callsite_threshold = ic_opts.hot_callsite_threshold; p.has_hot_callsite = true;
    if ic_opts.locally_hot_given { p.locally_hot_callsite_threshold = ic_opts.locally_hot_callsite_threshold; p.has_locally_hot = true; }
    p.cold_callsite_threshold = ic_opts.cold_callsite_threshold; p.has_cold_callsite = true;
    if !ic_opts.inline_threshold_given {
        p.opt_min_size_threshold = IC_OPT_MIN_SIZE_THRESHOLD; p.has_opt_min_size = true;
        p.opt_size_threshold = IC_OPT_SIZE_THRESHOLD; p.has_opt_size = true;
        p.cold_threshold = ic_opts.cold_threshold; p.has_cold = true;
    } else if ic_opts.cold_threshold_given {
        p.cold_threshold = ic_opts.cold_threshold; p.has_cold = true;
    }
    return p;
}
// getInlineParams()
get_inline_params :: () -> Inline_Params { return get_inline_params_t(ic_opts.default_threshold); }
// getInlineParamsFromOptLevel
get_inline_params_from_opt_level :: (opt_level: u32) -> Inline_Params {
    p := get_inline_params_t(ifx opt_level > 2 then cast(s64) IC_OPT_AGGRESSIVE_THRESHOLD else ic_opts.default_threshold);
    if opt_level > 2 { p.locally_hot_callsite_threshold = ic_opts.locally_hot_callsite_threshold; p.has_locally_hot = true; }
    return p;
}

// InlineCost
Inline_Cost :: struct {
    cost: s64;
    threshold: s64;
    static_bonus: s64;
    reason: string;
}
IC_ALWAYS_COST :: INT_MIN32;
IC_NEVER_COST :: INT_MAX32;
inline_cost_get :: (cost: s64, threshold: s64, bonus: s64 = 0) -> Inline_Cost { return .{cost, threshold, bonus, ""}; }
inline_cost_always :: (reason: string) -> Inline_Cost { return .{IC_ALWAYS_COST, 0, 0, reason}; }
inline_cost_never :: (reason: string) -> Inline_Cost { return .{IC_NEVER_COST, 0, 0, reason}; }
ic_is_always :: (c: Inline_Cost) -> bool { return c.cost == IC_ALWAYS_COST; }
ic_is_never :: (c: Inline_Cost) -> bool { return c.cost == IC_NEVER_COST; }
ic_bool :: (c: Inline_Cost) -> bool { return c.cost < c.threshold; }   // explicit operator bool
ic_cost_delta :: (c: Inline_Cost) -> s64 { return c.threshold - c.cost; }

// getStringFnAttrAsInt(CB, Kind): the call site's string attribute, else the callee's
call_str_fn_attr_as_int :: (cb: Value_Id, key: string) -> (bool, s64) {
    a: *Attr = null;
    for * attr_set_items(attr_list_fn(inst(cb).attrs)) if it.kind == .STRING_ATTR && it.key == key { a = it; break; }
    if !a {
        f := call_called_operand_fn(cb);
        if f != NONE a = fn_find_str_attr(f, key);
    }
    if !a return false, 0;
    ok, v := str_as_int10(a.val); return ok, v;
}
fn_str_attr_as_int :: (f: Value_Id, key: string) -> (bool, s64) {
    a := fn_find_str_attr(f, key);
    if !a return false, 0;
    ok, v := str_as_int10(a.val); return ok, v;
}
// StringRef::getAsInteger(10, int): the whole string, optional sign, fits an int
str_as_int10 :: (s: string) -> (bool, s64) {
    if s.count == 0 return false, 0;
    neg := false;
    t := s;
    if t[0] == #char "-" { neg = true; t = slice(t, 1, t.count - 1); }
    if t.count == 0 return false, 0;
    v: s64 = 0;
    for c: cast([] u8) t {
        if c < #char "0" || c > #char "9" return false, 0;
        v = v * 10 + cast(s64)(c - #char "0");
        if v > 0x8000_0000 return false, 0;
    }
    if neg v = -v;
    if v < INT_MIN32 || v > INT_MAX32 return false, 0;
    return true, v;
}


// ---------------------------------------------------------------- TargetTransformInfo inlining hooks

tti_inlining_threshold_multiplier :: (t: *Tti) -> s64 { return 1; }
tti_adjust_inlining_threshold :: (t: *Tti, cb: Value_Id) -> s64 { return 0; }
tti_inliner_vector_bonus_percent :: (t: *Tti) -> s64 { return 150; }
tti_inlining_last_call_to_static_bonus :: (t: *Tti) -> s64 { return IC_LAST_CALL_TO_STATIC_BONUS; }
tti_caller_alloca_cost :: (t: *Tti, cb: Value_Id, ai: Value_Id) -> s64 { return 0; }
tti_inline_call_penalty :: (t: *Tti, f: Value_Id, call: Value_Id, default_penalty: s64) -> s64 { return default_penalty; }
// getFPOpCost
tti_fp_op_cost :: (t: *Tti, ty: Type_Id) -> Cost {
    if t.kind != .X86 return TCC_BASIC;
    st := *t.xl;
    ok, e := x86_value_type(st, ty, true);
    if ok && evt_is_simple(e) && is_op_legal_or_custom_or_promote(st, ISD_FADD, e.m) return TCC_BASIC;
    return TCC_EXPENSIVE;
}
// getEstimatedNumberOfCaseClusters: (clusters, jump table size)
tti_estimated_number_of_case_clusters :: (t: *Tti, sw: Value_Id) -> (u32, u32) {
    n := (nops(sw) - 2);
    if t.kind != .X86 return n, 0;
    st := *t.xl;
    f := inst_fn(sw);
    jt_allowed := !fn_str_attr_bool(f, "no-jump-tables") &&
                  !(xs_has(st, X86F_FeatureRetpolineIndirectBranches) || xs_has(st, X86F_FeatureLVIControlFlowIntegrity)) &&
                  (is_op_legal_or_custom(st, ISD_BR_JT, MVT_Other) || is_op_legal_or_custom(st, ISD_BRIND, MVT_Other));
    idx_bits := cast(u64) dl_index_size_bits(0);
    if n < 1 || (!jt_allowed && idx_bits < n) return n, 0;
    first := const_ap(ir.u_aux[ir.v_ops[sw] + 2]);
    max_v := first; min_v := first;
    for k: 2..nops(sw)-1 {
        cv := const_ap(ir.u_aux[ir.v_ops[sw] + k]);
        if ap_sgt(cv, max_v) max_v = cv;
        if ap_slt(cv, min_v) min_v = cv;
    }
    range_val := ap_sub(max_v, min_v);
    rng: u64 = ap_limited_value(range_val, 0xFFFF_FFFF_FFFF_FFFE) + 1;
    if n <= idx_bits {
        // isSuitableForBitTests over the DestMap (iteration order does not matter: counts only)
        dests: [..] Value_Id; dests.allocator = temp;
        counts: [..] u32; counts.allocator = temp;
        for k: 2..nops(sw)-1 {
            d := op(sw, k);
            found := false;
            for dests if it == d { counts[it_index] += 1; found = true; break; }
            if !found { array_add(*dests, d); array_add(*counts, 1); }
        }
        if rng <= idx_bits {
            num_dests := dests.count;
            num_cmps: u32 = 0; max_entry: u32 = 0;
            for counts { num_cmps += it; if it > max_entry max_entry = it; }
            if max_entry >= ic_opts.min_bit_test_cmps {
                if (num_dests == 1 && num_cmps >= 3) || (num_dests == 2 && num_cmps >= 5) || (num_dests == 3 && num_cmps >= 6) return 1, 0;
            }
        }
    }
    if jt_allowed {
        if n < 2 || n < ic_opts.min_jump_table_entries return n, 0;
        // isSuitableForJumpTable (shouldOptimizeForSize without a profile: hasOptSize)
        opt_for_size := fn_has_opt_size(f);
        min_density := ifx opt_for_size then ic_opts.optsize_jump_table_density else ic_opts.jump_table_density;
        if (opt_for_size || rng <= ic_opts.max_jump_table_size) && (cast(u64) n * 100 >= rng * min_density) return 1, cast(u32) rng;
    }
    return n, 0;
}
ap_limited_value :: (a: APInt, limit: u64) -> u64 {
    if ap_active_bits(a) > 64 return limit;
    v := ap_zext_value(a);
    return ifx v > limit then limit else v;
}
// areInlineCompatible
tti_are_inline_compatible :: (caller: Value_Id, callee: Value_Id) -> bool {
    if ir.triple.count == 0 || !tti_is_x86_triple(ir.triple) {
        // TargetTransformInfoImplBase: equal target-cpu and target-features attributes
        eq :: (a: Value_Id, b: Value_Id, key: string) -> bool {
            x := fn_find_str_attr(a, key); y := fn_find_str_attr(b, key);
            if !x && !y return true;
            if !x || !y return false;
            return x.val == y.val;
        }
        return eq(caller, callee, "target-cpu") && eq(caller, callee, "target-features");
    }
    cs := *tti_get(caller).xl;
    es := *tti_get(callee).xl;
    rc: [X86_FEATURE_WORDS] u64;
    re: [X86_FEATURE_WORDS] u64;
    for k: 0..X86_FEATURE_WORDS-1 { rc[k] = cs.feat[k]; re[k] = es.feat[k]; }
    for f: X86_INLINE_IGNORE_FEATURES {
        rc[f / 64] &= ~((cast(u64) 1) << cast(u64)(f % 64));
        re[f / 64] &= ~((cast(u64) 1) << cast(u64)(f % 64));
    }
    for k: 0..X86_FEATURE_WORDS-1 if (rc[k] & re[k]) != re[k] return false;
    same := true;
    for k: 0..X86_FEATURE_WORDS-1 if rc[k] != re[k] same = false;
    if same && st_useAVX512Regs(cs) == st_useAVX512Regs(es) return true;
    for i: fn_insts(callee) {
        if !is_call_base(i) continue;
        if vkind(call_callee(i)) == .INLINE_ASM || call_iid_any(i) != NOT_INTRINSIC continue;
        simple := true;
        for k: 0..cast(s64) call_num_args(i) - 1 { t := vtype(call_arg(i, cast(u32) k)); if is_vector_type(t) || type_kind(t) == .STRUCT || type_kind(t) == .ARRAY simple = false; }
        rt := vtype(i);
        if type_kind(rt) != .VOID && (is_vector_type(rt) || type_kind(rt) == .STRUCT || type_kind(rt) == .ARRAY) simple = false;
        if simple continue;
        fatal("inline: X86TTIImpl::areTypesABICompatible (vector/aggregate call types with differing target features) is not implemented yet");
    }
    return true;
}
// The X86 features marked InlineIgnore in llvm/lib/Target/X86/X86.td (extracted from X86.td)
X86_INLINE_IGNORE_FEATURES :: s64.[
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
    X86F_TuningPreferLegacySetCC, X86F_ProcIntelAtom,
];

// TargetLibraryInfo::areInlineCompatible(CalleeTLI, AllowCallerSuperset)
tli_are_inline_compatible :: (caller: *Tli, callee: *Tli, allow_superset: bool) -> bool {
    for k: 0..NUM_LIB_FUNCS-1 {
        if !allow_superset { if caller.override_unavailable[k] != callee.override_unavailable[k] return false; }
        else if callee.override_unavailable[k] && !caller.override_unavailable[k] return false;
    }
    return true;
}

// ---------------------------------------------------------------- CallAnalyzer

Base_Offset :: struct { base: Value_Id = NONE; offset: APInt; }

Call_Analyzer :: struct {
    f: Value_Id;                 // the callee
    call: Value_Id;              // CandidateCall
    tti: *Tti;
    params: Inline_Params;
    // CallAnalyzer state
    is_caller_recursive: bool;
    is_recursive_call: bool;
    exposes_returns_twice: bool;
    has_dynamic_alloca: bool;
    contains_no_duplicate_call: bool;
    has_return: bool;
    has_indirect_br: bool;
    has_uninlineable_intrinsic: bool;
    inits_varg_args: bool;
    allocated_size: u64;
    num_instructions: u32;
    num_inline_asm_instructions: u32;
    num_vector_instructions: u32;
    simplified: Table(Value_Id, Value_Id);
    sroa_arg_values: Table(Value_Id, Value_Id);
    enabled_sroa: Table(Value_Id, bool);
    const_offset_ptrs: Table(Value_Id, Base_Offset);
    dead_blocks: Table(Value_Id, bool);
    known_successors: Table(Value_Id, Value_Id);
    enable_load_elimination := true;
    allow_recursive_call: bool;
    load_addr_set: Table(Value_Id, bool);
    num_constant_args: u32;
    num_constant_offset_ptr_args: u32;
    num_alloca_args: u32;
    num_constant_ptr_cmps: u32;
    num_constant_ptr_diffs: u32;
    num_instructions_simplified: u32;
    // InlineCostCallAnalyzer state
    compute_full_inline_cost: bool;
    load_elimination_cost: s64;
    vector_bonus: s64;
    single_bb_bonus: s64;
    threshold: s64;
    static_bonus_applied: s64;
    boost_indirect_calls: bool;
    ignore_threshold: bool;
    cost: s64;
    cost_at_bb_start: s64;
    decided_by_cost_threshold: bool;
    decided_by_cost_benefit: bool;
    single_bb := true;
    sroa_cost_savings: u64;
    sroa_cost_savings_lost: u64;
    sroa_arg_costs: Table(Value_Id, s64);
}

cax_new :: (callee: Value_Id, call: Value_Id, params: Inline_Params, boost_indirect: bool, ignore_threshold: bool) -> *Call_Analyzer {
    ca := New(Call_Analyzer,, allocator = temp);
    ca.f = callee; ca.call = call;
    ca.tti = tti_get(callee);
    ca.params = params;
    ca.simplified.allocator = temp; ca.sroa_arg_values.allocator = temp; ca.enabled_sroa.allocator = temp;
    ca.const_offset_ptrs.allocator = temp; ca.dead_blocks.allocator = temp; ca.known_successors.allocator = temp;
    ca.load_addr_set.allocator = temp; ca.sroa_arg_costs.allocator = temp;
    ca.enable_load_elimination = true;
    ca.single_bb = true;
    // isCostBenefitAnalysisEnabled: false without a profile summary
    ca.compute_full_inline_cost = ic_opts.compute_full_inline_cost || params.compute_full_inline_cost;
    ca.threshold = params.default_threshold;
    ca.boost_indirect_calls = boost_indirect;
    ca.ignore_threshold = ignore_threshold;
    ca.allow_recursive_call = params.allow_recursive_call;
    return ca;
}

// addCost
cax_add_cost :: (ca: *Call_Analyzer, inc_in: s64) {
    inc := clamp(inc_in, INT_MIN32, INT_MAX32);
    ca.cost = clamp(inc + ca.cost, INT_MIN32, INT_MAX32);
}

// getSimplifiedValue<T> for a Constant T (and its kinds) / getDirectOrSimplifiedValue<T>
Want :: enum u8 { CONSTANT; CONSTANT_INT; FUNCTION; }
cax_is :: (v: Value_Id, w: Want) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if w == {
        case .CONSTANT; return is_constant_kind(k);
        case .CONSTANT_INT; return k == .C_INT && !is_vector_type(vtype(v)) && type_kind(vtype(v)) == .INT;
        case .FUNCTION; return k == .FUNCTION;
    }
    return false;
}
cax_simplified :: (ca: *Call_Analyzer, v: Value_Id, w: Want) -> Value_Id {
    found, s := table_find(*ca.simplified, v);
    if !found || s == NONE return NONE;
    if cax_is(s, w) return s;
    return NONE;
}
cax_direct_or_simplified :: (ca: *Call_Analyzer, v: Value_Id, w: Want) -> Value_Id {
    if cax_is(v, w) return v;
    return cax_simplified(ca, v, w);
}
cax_simplified_unchecked :: (ca: *Call_Analyzer, v: Value_Id) -> Value_Id {
    found, s := table_find(*ca.simplified, v);
    if found return s;
    return NONE;
}
cax_sroa_arg_for :: (ca: *Call_Analyzer, v: Value_Id) -> Value_Id {
    found, a := table_find(*ca.sroa_arg_values, v);
    if !found || !table_contains(*ca.enabled_sroa, a) return NONE;
    return a;
}
cax_lookup_offset :: (ca: *Call_Analyzer, v: Value_Id) -> Base_Offset {
    found, bo := table_find(*ca.const_offset_ptrs, v);
    if found return bo;
    r: Base_Offset;
    return r;
}
// onDisableSROA
cax_on_disable_sroa :: (ca: *Call_Analyzer, arg: Value_Id) {
    found, c := table_find(*ca.sroa_arg_costs, arg);
    if !found return;
    cax_add_cost(ca, c);
    ca.sroa_cost_savings -= cast(u64) c;
    ca.sroa_cost_savings_lost += cast(u64) c;
    table_remove(*ca.sroa_arg_costs, arg);
}
cax_disable_load_elimination :: (ca: *Call_Analyzer) {
    if ca.enable_load_elimination {
        cax_add_cost(ca, ca.load_elimination_cost);
        ca.load_elimination_cost = 0;
        ca.enable_load_elimination = false;
    }
}
cax_disable_sroa_for_arg :: (ca: *Call_Analyzer, arg: Value_Id) {
    cax_on_disable_sroa(ca, arg);
    table_remove(*ca.enabled_sroa, arg);
    cax_disable_load_elimination(ca);
}
cax_disable_sroa :: (ca: *Call_Analyzer, v: Value_Id) {
    a := cax_sroa_arg_for(ca, v);
    if a != NONE cax_disable_sroa_for_arg(ca, a);
}
// handleSROA
cax_handle_sroa :: (ca: *Call_Analyzer, v: Value_Id, do_not_disable: bool) -> bool {
    a := cax_sroa_arg_for(ca, v);
    if a != NONE {
        if do_not_disable {
            p := table_find_pointer(*ca.sroa_arg_costs, a);
            p.* += ic_opts.instr_cost;
            ca.sroa_cost_savings += cast(u64) ic_opts.instr_cost;
            return true;
        }
        cax_disable_sroa_for_arg(ca, a);
    }
    return false;
}
cax_on_call_penalty :: (ca: *Call_Analyzer) { cax_add_cost(ca, ic_opts.call_penalty); }

// accumulateGEPOffset
cax_accumulate_gep_offset :: (ca: *Call_Analyzer, gep: Value_Id, offset: *APInt) -> bool {
    width := dl_index_type_size_bits(vtype(gep));
    ty := opr_gep_source_type(gep);
    n := nops(gep);
    for k: 1..cast(s64) n - 1 {
        idx := op(gep, cast(u32) k);
        c := cax_direct_or_simplified(ca, idx, .CONSTANT_INT);
        if c == NONE return false;
        // gep_type_iterator: index 1 strides over the source type, later ones step into it
        if ap_is_zero(const_ap(c)) { if k > 1 ty = gep_step_type(ty, c); continue; }
        if k > 1 && type_kind(ty) == .STRUCT {
            ei := cast(u32) const_int_zext(c);
            offset.* = ap_add(offset.*, ap_from_u64(width, dl_struct_offset(ty, ei)));
            ty = type_sub(ty, ei);
            continue;
        }
        elem := ifx k == 1 then ty else type_elem(ty);
        stride := ifx k > 1 && is_vector_type(ty) then dl_type_store_size(elem) else dl_type_alloc_size(elem);
        offset.* = ap_add(offset.*, ap_mul(ap_sext_or_trunc(const_ap(c), width), ap_from_u64(width, stride)));
        if k > 1 ty = elem;
    }
    return true;
}
// the type gep_type_iterator moves to after index c from aggregate ty
gep_step_type :: (ty: Type_Id, c: Value_Id) -> Type_Id {
    if type_kind(ty) == .STRUCT return type_sub(ty, cast(u32) const_int_zext(c));
    return type_elem(ty);
}

// isGEPFree
cax_is_gep_free :: (ca: *Call_Analyzer, gep: Value_Id) -> bool {
    ops: [..] Value_Id; ops.allocator = temp;
    array_add(*ops, op(gep, 0));
    for k: 1..cast(s64) nops(gep) - 1 {
        o := op(gep, cast(u32) k);
        s := cax_simplified(ca, o, .CONSTANT);
        array_add(*ops, ifx s != NONE then s else o);
    }
    return tti_instruction_cost_ops(ca.tti, gep, ops, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}

cax_visit_alloca :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    cax_disable_sroa(ca, op(i, 0));
    size_op := op(i, 0);
    is_array := !(vkind(size_op) == .C_INT && const_int_zext(size_op) == 1 && !is_vector_type(vtype(size_op)));
    if is_array {
        s := cax_simplified(ca, size_op, .CONSTANT);
        if s != NONE && vkind(s) == .C_INT {
            ty := inst(i).ty2;
            n := ap_limited_value(const_ap(s), 0xFFFF_FFFF_FFFF_FFFF);
            ca.allocated_size, _ = saturating_multiply_add(n, dl_type_alloc_size(ty), ca.allocated_size);
            if ca.allocated_size > IC_MAX_SIMPLIFIED_DYNAMIC_ALLOCA ca.has_dynamic_alloca = true;
            return false;
        }
    }
    if alloca_is_static(i) {
        ok, size := alloca_allocation_size(i);
        ca.allocated_size = saturating_add_u64(ifx ok then size else 0, ca.allocated_size);
    } else ca.has_dynamic_alloca = true;
    return false;
}
saturating_add_u64 :: (a: u64, b: u64) -> u64 { r := a + b; if r < a return 0xFFFF_FFFF_FFFF_FFFF; return r; }
cax_visit_phi :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    zero := ap_zero(dl_index_size_bits(0));
    check_sroa := is_ptr_type(vtype(i));
    first_c: Value_Id = NONE;
    first_bo: Base_Offset; first_bo.offset = zero;
    first_v: Value_Id = NONE;
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        pred := phi_block(i, cast(u32) k);
        if table_contains(*ca.dead_blocks, pred) continue;
        fk, ks := table_find(*ca.known_successors, pred);
        if fk && ks != NONE && ks != inst_block(i) continue;
        v := op(i, cast(u32) k);
        if v == i continue;
        c := cax_direct_or_simplified(ca, v, .CONSTANT);
        bo: Base_Offset; bo.offset = zero;
        if c == NONE && check_sroa bo = cax_lookup_offset(ca, v);
        if c == NONE && bo.base == NONE return true;
        if first_c != NONE {
            if first_c == c continue;
            return true;
        }
        if first_v != NONE {
            if first_bo.base == bo.base && bo_offset_eq(first_bo.offset, bo.offset) continue;
            return true;
        }
        if c != NONE { first_c = c; continue; }
        first_v = v;
        first_bo = bo;
    }
    if first_c != NONE { table_set(*ca.simplified, i, first_c); return true; }
    if first_bo.base != NONE {
        table_set(*ca.const_offset_ptrs, i, first_bo);
        a := cax_sroa_arg_for(ca, first_v);
        if a != NONE table_set(*ca.sroa_arg_values, i, a);
    }
    return true;
}
// std::pair<Value *, APInt> == (APInt operator== asserts equal widths; a default pair has a 1-bit zero)
bo_offset_eq :: (a: APInt, b: APInt) -> bool {
    if a.bits != b.bits return ap_is_zero(a) && ap_is_zero(b);
    return ap_eq(a, b);
}

// canFoldInboundsGEP
cax_can_fold_inbounds_gep :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    bo := cax_lookup_offset(ca, op(i, 0));
    if bo.base == NONE return false;
    off := bo.offset;
    if !cax_accumulate_gep_offset(ca, i, *off) return false;
    bo.offset = off;
    table_set(*ca.const_offset_ptrs, i, bo);
    return true;
}
cax_visit_gep :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    sroa_arg := cax_sroa_arg_for(ca, op(i, 0));
    is_gep_offset_constant :: (ca: *Call_Analyzer, g: Value_Id) -> bool {
        for k: 1..cast(s64) nops(g) - 1 if cax_direct_or_simplified(ca, op(g, cast(u32) k), .CONSTANT) == NONE return false;
        return true;
    }
    if !ic_opts.disable_gep_const_evaluation if cax_simplify_instruction(ca, i) return true;
    if (((inst(i).flags & F_INBOUNDS) != 0 && cax_can_fold_inbounds_gep(ca, i)) || is_gep_offset_constant(ca, i)) {
        if sroa_arg != NONE table_set(*ca.sroa_arg_values, i, sroa_arg);
        return true;
    }
    if sroa_arg != NONE cax_disable_sroa_for_arg(ca, sroa_arg);
    return cax_is_gep_free(ca, i);
}

// simplifyCmpInstForRecCall
cax_simplify_cmp_inst_for_rec_call :: (ca: *Call_Analyzer, cmp: Value_Id) -> bool {
    if vkind(op(cmp, 0)) != .ARGUMENT || !is_constant_kind(vkind(op(cmp, 1))) return false;
    cmp_op := op(cmp, 0);
    if inst_fn(ca.call) != ca.f return false;
    call_bb := inst_block(ca.call);
    pred := block_single_predecessor(call_bb);
    if pred == NONE return false;
    br := block_terminator(pred);
    if br == NONE || inst_op(br) != .CONDBR || op(br, 0) != cmp return false;
    arg_found := false;
    func_arg: Value_Id = NONE; call_arg_v: Value_Id = NONE;
    num := min(cast(s64) glob(ca.f).nargs, cast(s64) call_num_args(ca.call));
    for k: 0..num - 1 {
        func_arg = fn_arg(ca.f, cast(u32) k);
        call_arg_v = call_arg(ca.call, cast(u32) k);
        if func_arg == cmp_op && call_arg_v != cmp_op { arg_found = true; break; }
    }
    if !arg_found return false;
    q: Simplify_Query; q.have_tli = false;
    q.cxt = ifx vkind(call_arg_v) == .INST then call_arg_v else NONE;
    cc: Cond_Context;
    cc.cond = cmp;
    cc.invert = call_bb != get_successor(br, 0);
    cc.affected.allocator = temp;
    array_add(*cc.affected, func_arg);
    q.cc = *cc;
    s := simplify_instruction_with_operands(cmp, .[call_arg_v, op(cmp, 1)], q);
    if s != NONE && vkind(s) == .C_INT && !is_vector_type(vtype(s)) {
        one := const_int_zext(s) == 1;
        zero := const_int_zext(s) == 0;
        if (one && cc.invert) || (zero && !cc.invert) {
            table_set(*ca.simplified, cmp, s);
            return true;
        }
    }
    return false;
}

// simplifyInstruction: every operand constant (directly or simplified), then ConstantFoldInstOperands
cax_simplify_instruction :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    cops: [..] Value_Id; cops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        c := cax_direct_or_simplified(ca, op(i, cast(u32) k), .CONSTANT);
        if c == NONE return false;
        array_add(*cops, c);
    }
    c := cfo_inst_operands(i, cops);
    if c == NONE return false;
    table_set(*ca.simplified, i, c);
    return true;
}
cax_simplify_intrinsic_call_is_constant :: (ca: *Call_Analyzer, cb: Value_Id) -> bool {
    c := cax_direct_or_simplified(ca, call_arg(cb, 0), .CONSTANT);
    rt := func_ret(inst(cb).ty2);
    table_set(*ca.simplified, cb, const_int(rt, ifx c != NONE then cast(u64) 1 else 0));
    return true;
}
cax_simplify_intrinsic_call_object_size :: (ca: *Call_Analyzer, cb: Value_Id) -> bool {
    a3 := call_arg(cb, 3);
    if vkind(a3) == .C_INT && const_int_zext(a3) == 1 return false;
    v := lower_object_size_call(cb, null, true);
    if v != NONE && is_constant_kind(vkind(v)) { table_set(*ca.simplified, cb, v); return true; }
    return false;
}
cax_visit_bitcast :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_simplify_instruction(ca, i) return true;
    bo := cax_lookup_offset(ca, op(i, 0));
    if bo.base != NONE table_set(*ca.const_offset_ptrs, i, bo);
    a := cax_sroa_arg_for(ca, op(i, 0));
    if a != NONE table_set(*ca.sroa_arg_values, i, a);
    return true;
}
cax_visit_ptrtoint :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_simplify_instruction(ca, i) return true;
    int_size := type_scalar_size_bits(vtype(i));
    as := cast(u32) ir.types[scalar_type(vtype(op(i, 0)))].a;
    if int_size == dl_ptr_size_bits_as(as) {
        bo := cax_lookup_offset(ca, op(i, 0));
        if bo.base != NONE table_set(*ca.const_offset_ptrs, i, bo);
    }
    a := cax_sroa_arg_for(ca, op(i, 0));
    if a != NONE table_set(*ca.sroa_arg_values, i, a);
    return tti_instruction_cost(ca.tti, i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}
cax_visit_inttoptr :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_simplify_instruction(ca, i) return true;
    o := op(i, 0);
    int_size := type_scalar_size_bits(vtype(o));
    if int_size <= dl_type_size_bits(vtype(i)) {
        bo := cax_lookup_offset(ca, o);
        if bo.base != NONE table_set(*ca.const_offset_ptrs, i, bo);
    }
    a := cax_sroa_arg_for(ca, o);
    if a != NONE table_set(*ca.sroa_arg_values, i, a);
    return tti_instruction_cost(ca.tti, i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}
cax_visit_cast :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_simplify_instruction(ca, i) return true;
    cax_disable_sroa(ca, op(i, 0));
    o := inst_op(i);
    if o == .FPTRUNC || o == .FPEXT || o == .UITOFP || o == .SITOFP || o == .FPTOUI || o == .FPTOSI {
        if tti_fp_op_cost(ca.tti, vtype(i)) == TCC_EXPENSIVE cax_on_call_penalty(ca);
    }
    return tti_instruction_cost(ca.tti, i, TCK_SIZE_AND_LATENCY) == TCC_FREE;
}
type_scalar_size_bits :: (t: Type_Id) -> u64 { return dl_type_size_bits(scalar_type(t)); }
dl_ptr_size_bits_as :: (as: u32) -> u64 { return dl_ptr_spec(as).bits; }

// isKnownNonNullInCallee
cax_is_known_non_null_in_callee :: (ca: *Call_Analyzer, v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT && call_param_has_attr(ca.call, arg_no(v), .NonNull) return true;
    if table_contains(*ca.sroa_arg_values, v) return true;
    return false;
}
// allowSizeGrowth
cax_allow_size_growth :: (call: Value_Id) -> bool {
    if inst_op(call) == .INVOKE {
        t := block_terminator(invoke_normal_dest(call));
        if t != NONE && inst_op(t) == .UNREACHABLE return false;
    } else {
        t := block_terminator(inst_block(call));
        if t != NONE && inst_op(t) == .UNREACHABLE return false;
    }
    return true;
}
// isColdCallSite (no profile summary: BFI relative to the caller's entry)
cax_is_cold_call_site :: (call: Value_Id, caller_bfi: *Bfi) -> bool {
    if !caller_bfi return false;
    site_freq := bfi_get_block_freq(caller_bfi, inst_block(call));
    entry_freq := bfi_get_block_freq(caller_bfi, fn_entry(inst_fn(call)));
    // BlockFrequency * BranchProbability(ColdCallSiteRelFreq, 100)
    p := bp_make(cast(u64) ic_opts.cold_callsite_rel_freq, 100);
    return site_freq < bf_mul_prob(entry_freq, p);
}
// getHotCallSiteThreshold (no profile summary)
cax_hot_call_site_threshold :: (ca: *Call_Analyzer, call: Value_Id, caller_bfi: *Bfi) -> (bool, s64) {
    if !caller_bfi || !ca.params.has_locally_hot return false, 0;
    site := bfi_get_block_freq(caller_bfi, inst_block(call));
    entry := bfi_get_entry_freq(caller_bfi);
    hi, lo := mul_u64_128(entry, ic_opts.hot_callsite_rel_freq);
    if hi != 0 return false, 0;   // BlockFrequency::mul overflow: no limit
    if site >= lo return true, ca.params.locally_hot_callsite_threshold;
    return false, 0;
}
bfi_get_entry_freq :: (b: *Bfi) -> u64 { return bfi_get_block_freq(b, fn_entry(b.f)); }

// isSoleCallToLocalFunction
is_sole_call_to_local_function :: (cb: Value_Id, callee: Value_Id) -> bool {
    return gv_has_local_linkage(callee) && const_has_n_live_uses(callee, 1) && call_called_function(cb) == callee;
}
// Constant::hasNLiveUses (hasOneLiveUse = 1, hasZeroLiveUses = 0)
const_has_n_live_uses :: (f: Value_Id, n: s64) -> bool {
    count := 0;
    u := ir.v_first_use[f];
    while u != NONE {
        usr := ir.u_user[u];
        if !(is_constant_kind(vkind(usr)) && !is_global_value(vkind(usr)) && constant_is_dead(usr)) {
            count += 1;
            if count > n return false;
        }
        u = ir.u_next[u];
    }
    return count == n;
}
// Constant::isConstantUsed negation: no live users (recursively through constant users)
constant_is_dead :: (c: Value_Id) -> bool {
    u := ir.v_first_use[c];
    while u != NONE {
        usr := ir.u_user[u];
        if !is_constant_kind(vkind(usr)) || is_global_value(vkind(usr)) return false;
        if !constant_is_dead(usr) return false;
        u = ir.u_next[u];
    }
    return true;
}

// updateThreshold
cax_update_threshold :: (ca: *Call_Analyzer) {
    call := ca.call;
    if !cax_allow_size_growth(call) { ca.threshold = 0; return; }
    caller := inst_fn(call);
    min_if :: (a: s64, has: bool, b: s64) -> s64 { return ifx has then min(a, b) else a; }
    max_if :: (a: s64, has: bool, b: s64) -> s64 { return ifx has then max(a, b) else a; }
    single_bb_bonus_percent: s64 = 50;
    vector_bonus_percent := tti_inliner_vector_bonus_percent(ca.tti);
    last_call_to_static_bonus := tti_inlining_last_call_to_static_bonus(ca.tti);
    p := *ca.params;
    if fn_has_min_size(caller) {
        ca.threshold = min_if(ca.threshold, p.has_opt_min_size, p.opt_min_size_threshold);
        single_bb_bonus_percent = 0;
        vector_bonus_percent = 0;
    } else if fn_has_opt_size(caller) ca.threshold = min_if(ca.threshold, p.has_opt_size, p.opt_size_threshold);
    if !fn_has_min_size(caller) {
        has_hint := ifx fn_has_opt_size(caller) then p.has_opt_size_hint else p.has_hint;
        hint := ifx fn_has_opt_size(caller) then p.opt_size_hint_threshold else p.hint_threshold;
        if fn_has_fn_attr(ca.f, .InlineHint) ca.threshold = max_if(ca.threshold, has_hint, hint);
        caller_bfi := get_bfi(caller);
        hot_ok, hot := cax_hot_call_site_threshold(ca, call, caller_bfi);
        if !fn_has_opt_size(caller) && hot_ok {
            ca.threshold = hot;
        } else if cax_is_cold_call_site(call, caller_bfi) {
            single_bb_bonus_percent = 0; vector_bonus_percent = 0; last_call_to_static_bonus = 0;
            ca.threshold = min_if(ca.threshold, p.has_cold_callsite, p.cold_callsite_threshold);
        }
    }
    ca.threshold += tti_adjust_inlining_threshold(ca.tti, call);
    ca.threshold *= tti_inlining_threshold_multiplier(ca.tti);
    ca.single_bb_bonus = ca.threshold * single_bb_bonus_percent / 100;
    ca.vector_bonus = ca.threshold * vector_bonus_percent / 100;
    if is_sole_call_to_local_function(call, ca.f) {
        cax_add_cost(ca, -last_call_to_static_bonus);
        ca.static_bonus_applied = last_call_to_static_bonus;
    }
}

cax_visit_cmp :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    lhs := op(i, 0); rhs := op(i, 1);
    if cax_simplify_instruction(ca, i) return true;
    if cax_simplify_cmp_inst_for_rec_call(ca, i) return true;
    if inst_op(i) == .FCMP return false;
    lb := cax_lookup_offset(ca, lhs);
    if lb.base != NONE {
        rb := cax_lookup_offset(ca, rhs);
        if rb.base != NONE && lb.base == rb.base {
            r := icmp_compare(lb.offset, rb.offset, inst_pred(i));
            table_set(*ca.simplified, i, const_int(vtype(i), ifx r then cast(u64) 1 else 0));
            ca.num_constant_ptr_cmps += 1;
            return true;
        }
    }
    is_implicit_null_check_cmp :: (i: Value_Id) -> bool {
        k := md_kind_id("make.implicit");
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if vkind(usr) == .INST && get_metadata(usr, k) == NONE return false;
            u = ir.u_next[u];
        }
        return true;
    }
    if icmp_is_equality(inst_pred(i)) && vkind(op(i, 1)) == .C_NULL && !is_vector_type(vtype(op(i, 1))) {
        if cax_is_known_non_null_in_callee(ca, op(i, 0)) {
            ne := inst_pred(i) == ICMP_NE;
            table_set(*ca.simplified, i, const_int(vtype(i), ifx ne then cast(u64) 1 else 0));
            return true;
        }
        if is_implicit_null_check_cmp(i) return true;
    }
    return cax_handle_sroa(ca, op(i, 0), vkind(op(i, 1)) == .C_NULL && !is_vector_type(vtype(op(i, 1))));
}
cax_visit_sub :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    lhs := op(i, 0); rhs := op(i, 1);
    lb := cax_lookup_offset(ca, lhs);
    if lb.base != NONE {
        rb := cax_lookup_offset(ca, rhs);
        if rb.base != NONE && lb.base == rb.base {
            cl := const_int_ap(type_int(lb.offset.bits), lb.offset);
            cr := const_int_ap(type_int(rb.offset.bits), rb.offset);
            c := ce_binop(.SUB, cl, cr, 0);
            if c != NONE {
                table_set(*ca.simplified, i, c);
                ca.num_constant_ptr_diffs += 1;
                return true;
            }
        }
    }
    return cax_visit_binary_operator(ca, i);
}
cax_visit_binary_operator :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    lhs := op(i, 0); rhs := op(i, 1);
    cl := cax_direct_or_simplified(ca, lhs, .CONSTANT);
    cr := cax_direct_or_simplified(ca, rhs, .CONSTANT);
    q: Simplify_Query; q.have_tli = false;
    a := ifx cl != NONE then cl else lhs;
    b := ifx cr != NONE then cr else rhs;
    sv: Value_Id;
    if is_fp_math_operator(i) sv = simplify_binop_fmf(inst_op(i), a, b, inst_fmf(i), q);
    else sv = simplify_binop(inst_op(i), a, b, q);
    if sv != NONE && is_constant_kind(vkind(sv)) table_set(*ca.simplified, i, sv);
    if sv != NONE return true;
    cax_disable_sroa(ca, lhs);
    cax_disable_sroa(ca, rhs);
    if is_fp_type(vtype(i)) && tti_fp_op_cost(ca.tti, vtype(i)) == TCC_EXPENSIVE {
        is_fneg, _ := pm_fneg(i);
        if !is_fneg cax_on_call_penalty(ca);
    }
    return false;
}
cax_visit_fneg :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    o := op(i, 0);
    c := cax_direct_or_simplified(ca, o, .CONSTANT);
    q: Simplify_Query; q.have_tli = false;
    sv := simplify_fneg_inst(ifx c != NONE then c else o, inst_fmf(i), q);
    if sv != NONE && is_constant_kind(vkind(sv)) table_set(*ca.simplified, i, sv);
    if sv != NONE return true;
    cax_disable_sroa(ca, o);
    return false;
}
cax_visit_load :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_handle_sroa(ca, op(i, 0), is_simple_load_store(i)) return true;
    if ca.enable_load_elimination {
        p := op(i, 0);
        was := table_contains(*ca.load_addr_set, p);
        if !was table_set(*ca.load_addr_set, p, true);
        if was && is_unordered(i) {
            ca.load_elimination_cost += ic_opts.instr_cost;
            return true;
        }
    }
    cax_add_cost(ca, ic_opts.mem_access_cost);
    return false;
}
cax_visit_store :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_handle_sroa(ca, op(i, 1), is_simple_load_store(i)) return true;
    cax_disable_load_elimination(ca);
    cax_add_cost(ca, ic_opts.mem_access_cost);
    return false;
}
cax_visit_extract_value :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    o := op(i, 0);
    so := cax_simplified_unchecked(ca, o);
    if so != NONE {
        q: Simplify_Query; q.have_tli = false;
        idxs: [..] u32; idxs.allocator = temp;
        for inst_indices(i) array_add(*idxs, it);
        sv := simplify_extract_value_inst(so, idxs, q);
        if sv != NONE { table_set(*ca.simplified, i, sv); return true; }
    }
    return cax_visit_instruction(ca, i);
}
cax_visit_insert_value :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if cax_simplify_instruction(ca, i) return true;
    return cax_visit_instruction(ca, i);
}
// simplifyCallSite
cax_simplify_call_site :: (ca: *Call_Analyzer, f: Value_Id, call: Value_Id) -> bool {
    if !can_constant_fold_call_to(call, f) return false;
    cargs: [..] Value_Id; cargs.allocator = temp;
    for k: 0..cast(s64) call_num_args(call) - 1 {
        c := cax_direct_or_simplified(ca, call_arg(call, cast(u32) k), .CONSTANT);
        if c == NONE return false;
        array_add(*cargs, c);
    }
    c := cfo_call(call, f, cargs);
    if c != NONE { table_set(*ca.simplified, call, c); return true; }
    return false;
}
// isLoweredToCall
cax_is_lowered_to_call :: (ca: *Call_Analyzer, f: Value_Id, call: Value_Id) -> bool {
    t := tli_for(f);
    ok, lf := tli_lookup_fn(f);
    if !ok || !tli_func_has(t, lf) return tti_is_lowered_to_call(f);
    if lf == .memcpy_chk || lf == .memmove_chk || lf == .mempcpy_chk || lf == .memset_chk {
        len := cax_direct_or_simplified(ca, op(call, 2), .CONSTANT_INT);
        objs := cax_direct_or_simplified(ca, op(call, 3), .CONSTANT_INT);
        if len != NONE && objs != NONE && ap_limited_value(const_ap(len), 0xFFFF_FFFF_FFFF_FFFF) <= ap_limited_value(const_ap(objs), 0xFFFF_FFFF_FFFF_FFFF) return false;
    }
    return tti_is_lowered_to_call(f);
}
// onLoweredCall
cax_on_lowered_call :: (ca: *Call_Analyzer, f: Value_Id, call: Value_Id, is_indirect: bool) {
    cax_add_cost(ca, cast(s64) call_num_args(call) * ic_opts.instr_cost);
    if is_indirect && ca.boost_indirect_calls {
        p := ca.params;
        p.default_threshold = IC_INDIRECT_CALL_THRESHOLD;
        sub := cax_new(f, call, p, false, false);
        if cax_analyze(sub).ok cax_add_cost(ca, -max(0, sub.threshold - sub.cost));
    } else cax_add_cost(ca, tti_inline_call_penalty(ca.tti, inst_fn(ca.call), call, ic_opts.call_penalty));
}
// onInlineAsm
cax_on_inline_asm :: (ca: *Call_Analyzer, asm: Value_Id) {
    if ic_opts.inline_asm_instr_cost == 0 return;
    strs := inline_asm_collect_strs(asm);
    section_level := 0;
    count := 0;
    for s: strs {
        t := trim(s);
        h := find_index_from_left(t, #char "#");
        if h >= 0 t = slice(t, 0, h);
        if t.count == 0 continue;
        if begins_with(t, ".pushsection") { section_level += 1; continue; }
        if begins_with(t, ".popsection") { section_level -= 1; continue; }
        if begins_with(t, ".") || find_index_from_left(t, #char ":") >= 0 continue;
        if section_level == 0 count += 1;
    }
    ca.num_inline_asm_instructions += cast(u32) count;
    cax_add_cost(ca, count * ic_opts.inline_asm_instr_cost);
}
// InlineAsm::collectAsmStrs: AsmString.split("\n\t", KeepEmpty = false)
inline_asm_collect_strs :: (asm: Value_Id) -> [..] string {
    r: [..] string; r.allocator = temp;
    s := inline_asms[ir.v_aux[asm]].asm_str;
    if s.count == 0 return r;
    start := 0;
    k := 0;
    while k + 1 < s.count {
        if s[k] == #char "\n" && s[k + 1] == #char "\t" {
            if k > start array_add(*r, slice(s, start, k - start));
            k += 2;
            start = k;
            continue;
        }
        k += 1;
    }
    if s.count > start array_add(*r, slice(s, start, s.count - start));
    return r;
}

cax_visit_call_base :: (ca: *Call_Analyzer, call: Value_Id) -> bool {
    // onCallBaseVisitStart
    ok, bonus := call_str_fn_attr_as_int(call, "call-threshold-bonus");
    if ok ca.threshold += bonus;
    ok2, ccost := call_str_fn_attr_as_int(call, "call-inline-cost");
    if ok2 { cax_add_cost(ca, ccost); return true; }
    if call_has_fn_attr(call, .ReturnsTwice) && !fn_has_fn_attr(ca.f, .ReturnsTwice) { ca.exposes_returns_twice = true; return false; }
    if inst_op(call) == .CALL && call_has_fn_attr(call, .NoDuplicate) ca.contains_no_duplicate_call = true;
    if vkind(call_callee(call)) == .INLINE_ASM cax_on_inline_asm(ca, call_callee(call));
    f := call_called_function(call);
    is_indirect := f == NONE;
    if is_indirect {
        f = cax_simplified(ca, call_callee(call), .FUNCTION);
        if f == NONE || glob(f).value_type != inst(call).ty2 {
            cax_add_cost(ca, cast(s64) call_num_args(call) * ic_opts.instr_cost);
            if !call_only_reads_memory(call) cax_disable_load_elimination(ca);
            return cax_visit_instruction(ca, call);
        }
    }
    if cax_simplify_call_site(ca, f, call) return true;
    if call_iid(call) != NOT_INTRINSIC {
        id := call_iid(call);
        if id == IID_LOAD_RELATIVE { cax_add_cost(ca, 3 * ic_opts.instr_cost); return false; }
        if id == IID_MEMSET || id == IID_MEMCPY || id == IID_MEMMOVE { cax_disable_load_elimination(ca); return false; }
        if id == IID_ICALL_BRANCH_FUNNEL || id == IID_LOCALESCAPE { ca.has_uninlineable_intrinsic = true; return false; }
        if id == IID_VASTART { ca.inits_varg_args = true; return false; }
        if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP {
            a := cax_sroa_arg_for(ca, op(call, 0));
            if a != NONE table_set(*ca.sroa_arg_values, call, a);
            return true;
        }
        if id == IID_IS_CONSTANT return cax_simplify_intrinsic_call_is_constant(ca, call);
        if id == IID_OBJECTSIZE return cax_simplify_intrinsic_call_object_size(ca, call);
        if !call_only_reads_memory(call) && !is_assume_like_intrinsic(call) cax_disable_load_elimination(ca);
        return cax_visit_instruction(ca, call);
    }
    if f == inst_fn(call) {
        ca.is_recursive_call = true;
        if !ca.allow_recursive_call return false;
    }
    if cax_is_lowered_to_call(ca, f, call) cax_on_lowered_call(ca, f, call, is_indirect);
    if !(call_only_reads_memory(call) || (is_indirect && fn_only_reads_memory(f))) cax_disable_load_elimination(ca);
    return cax_visit_instruction(ca, call);
}
cax_visit_select :: (ca: *Call_Analyzer, si: Value_Id) -> bool {
    check_sroa := is_ptr_type(vtype(si));
    tv := op(si, 1); fv := op(si, 2);
    tc := cax_direct_or_simplified(ca, tv, .CONSTANT);
    fc := cax_direct_or_simplified(ca, fv, .CONSTANT);
    cc := cax_simplified(ca, op(si, 0), .CONSTANT);
    if cc == NONE {
        if tc == fc && tc != NONE { table_set(*ca.simplified, si, tc); return true; }
        if !check_sroa return cax_visit_instruction(ca, si);
        tb := cax_lookup_offset(ca, tv);
        fb := cax_lookup_offset(ca, fv);
        if tb.base == fb.base && bo_offset_eq(tb.offset, fb.offset) && tb.base != NONE {
            table_set(*ca.const_offset_ptrs, si, tb);
            a := cax_sroa_arg_for(ca, tv);
            if a != NONE table_set(*ca.sroa_arg_values, si, a);
            return true;
        }
        return cax_visit_instruction(ca, si);
    }
    sel: Value_Id = NONE;
    if cf_is_all_ones(cc) sel = tv;
    else if is_null_value(cc) sel = fv;
    if sel == NONE {
        if tc != NONE && fc != NONE {
            c := cf_select(cc, tc, fc);
            if c != NONE { table_set(*ca.simplified, si, c); return true; }
        }
        return cax_visit_instruction(ca, si);
    }
    if is_constant_kind(vkind(sel)) { table_set(*ca.simplified, si, sel); return true; }
    if !check_sroa return true;
    bo := cax_lookup_offset(ca, sel);
    if bo.base != NONE {
        table_set(*ca.const_offset_ptrs, si, bo);
        a := cax_sroa_arg_for(ca, sel);
        if a != NONE table_set(*ca.sroa_arg_values, si, a);
    }
    return true;
}
cax_visit_switch :: (ca: *Call_Analyzer, sw: Value_Id) -> bool {
    if cax_direct_or_simplified(ca, op(sw, 0), .CONSTANT_INT) != NONE return true;
    num_clusters, jt_size := tti_estimated_number_of_case_clusters(ca.tti, sw);
    default_unreachable := switch_default_dest_unreachable(sw);
    // onFinalizeSwitch
    ic := ic_opts.instr_cost;
    if jt_size {
        if !default_unreachable cax_add_cost(ca, 2 * ic);
        cax_add_cost(ca, cast(s64) jt_size * ic + 2 * ic);
        return false;
    }
    if num_clusters <= 3 {
        cax_add_cost(ca, (cast(s64) num_clusters - ifx default_unreachable then cast(s64) 1 else 0) * 2 * ic);
        return false;
    }
    expected := 3 * cast(s64) num_clusters / 2 - 1;
    cax_add_cost(ca, expected * 2 * ic);
    return false;
}
// SwitchInst::defaultDestUnreachable: the default destination's first non-debug instruction is unreachable
switch_default_dest_unreachable :: (sw: Value_Id) -> bool {
    d := op(sw, 1);
    x := block_first(d);
    while x != NONE && is_debug_or_pseudo_inst(x) x = inst(x).next;
    return x != NONE && inst_op(x) == .UNREACHABLE;
}
// visitInstruction
cax_visit_instruction :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    if tti_instruction_cost(ca.tti, i, TCK_SIZE_AND_LATENCY) == TCC_FREE return true;
    for k: 0..cast(s64) nops(i) - 1 cax_disable_sroa(ca, op(i, cast(u32) k));
    return false;
}

// InstVisitor dispatch
cax_visit :: (ca: *Call_Analyzer, i: Value_Id) -> bool {
    o := inst_op(i);
    if o == {
        case .ALLOCA; return cax_visit_alloca(ca, i);
        case .PHI; return cax_visit_phi(ca, i);
        case .GEP; return cax_visit_gep(ca, i);
        case .BITCAST; return cax_visit_bitcast(ca, i);
        case .PTRTOINT; return cax_visit_ptrtoint(ca, i);
        case .INTTOPTR; return cax_visit_inttoptr(ca, i);
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .FPTRUNC; #through; case .FPEXT; #through;
        case .FPTOUI; #through; case .FPTOSI; #through; case .UITOFP; #through; case .SITOFP; #through; case .ADDRSPACECAST; #through;
        case .PTRTOADDR;
            return cax_visit_cast(ca, i);
        case .ICMP; #through; case .FCMP; return cax_visit_cmp(ca, i);
        case .SUB; return cax_visit_sub(ca, i);
        case .ADD; #through; case .FADD; #through; case .FSUB; #through; case .MUL; #through; case .FMUL; #through;
        case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through; case .SREM; #through;
        case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through; case .AND; #through;
        case .OR; #through; case .XOR;
            return cax_visit_binary_operator(ca, i);
        case .FNEG; return cax_visit_fneg(ca, i);
        case .LOAD; return cax_visit_load(ca, i);
        case .STORE; return cax_visit_store(ca, i);
        case .EXTRACTVALUE; return cax_visit_extract_value(ca, i);
        case .INSERTVALUE; return cax_visit_insert_value(ca, i);
        case .CALL; #through; case .INVOKE; #through; case .CALLBR; return cax_visit_call_base(ca, i);
        case .RET; free := !ca.has_return; ca.has_return = true; return free;
        case .BR; return true;
        case .CONDBR; return cax_direct_or_simplified(ca, op(i, 0), .CONSTANT_INT) != NONE || get_metadata(i, md_kind_id("make.implicit")) != NONE;
        case .SELECT; return cax_visit_select(ca, i);
        case .SWITCH; return cax_visit_switch(ca, i);
        case .INDIRECTBR; ca.has_indirect_br = true; return false;
        case .RESUME; return false;
        case .CLEANUPRET; return false;
        case .CATCHRET; return false;
        case .UNREACHABLE; return true;
    }
    return cax_visit_instruction(ca, i);
}

// analyzeBlock
cax_analyze_block :: (ca: *Call_Analyzer, bb: Value_Id, eph: *Table(Value_Id, bool)) -> Inline_Result {
    for i: block_insts(bb) {
        if is_debug_or_pseudo_inst(i) continue;
        if table_contains(eph, i) continue;
        ca.num_instructions += 1;
        if inst_op(i) == .EXTRACTELEMENT || is_vector_type(vtype(i)) ca.num_vector_instructions += 1;
        if cax_visit(ca, i) ca.num_instructions_simplified += 1;
        else cax_add_cost(ca, ic_opts.instr_cost);   // onMissedSimplification
        r := ir_success();
        if ca.is_recursive_call && !ca.allow_recursive_call r = ir_failure("recursive");
        else if ca.exposes_returns_twice r = ir_failure("exposes returns twice");
        else if ca.has_dynamic_alloca r = ir_failure("dynamic alloca");
        else if ca.has_indirect_br r = ir_failure("indirect branch");
        else if ca.has_uninlineable_intrinsic r = ir_failure("uninlinable intrinsic");
        else if ca.inits_varg_args r = ir_failure("varargs");
        if !r.ok return r;
        if ca.is_caller_recursive && ca.allocated_size > ic_opts.recur_stack_size_threshold return ir_failure("recursive and allocates too much stack space");
        if cax_should_stop(ca) return ir_failure("Call site analysis is not favorable to inlining.");
    }
    return ir_success();
}
// shouldStop
cax_should_stop :: (ca: *Call_Analyzer) -> bool {
    if ca.ignore_threshold || ca.compute_full_inline_cost return false;
    if ca.cost < ca.threshold return false;
    ca.decided_by_cost_threshold = true;
    return true;
}

// stripAndComputeInBoundsConstantOffsets: (ConstantInt offset or NONE, stripped V)
cax_strip_and_compute_inbounds_constant_offsets :: (ca: *Call_Analyzer, v_in: Value_Id) -> (bool, APInt, Value_Id) {
    v := v_in;
    if !is_ptr_type(vtype(v)) { z: APInt; return false, z, v; }
    as := cast(u32) ir.types[vtype(v)].a;
    width := dl_index_size_bits(as);
    offset := ap_zero(width);
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        if opr_code(v) == .GEP {
            if (opr_flags(v) & F_INBOUNDS) == 0 || !cax_accumulate_gep_offset(ca, v, *offset) { z: APInt; return false, z, v; }
            v = op(v, 0);
        } else if vkind(v) == .ALIAS {
            if gv_is_interposable(v) break;
            v = op(v, 0);
        } else break;
        seen := false;
        for visited if it == v seen = true;
        if seen break;
        array_add(*visited, v);
    }
    // ConstantInt::get(DL.getIndexType(V->getType()), Offset)
    iw := dl_index_type_size_bits(vtype(v));
    return true, ap_sext_or_trunc(offset, iw), v;
}

// findDeadBlocks
cax_find_dead_blocks :: (ca: *Call_Analyzer, curr: Value_Id, next: Value_Id) {
    is_edge_dead :: (ca: *Call_Analyzer, pred: Value_Id, succ: Value_Id) -> bool {
        if table_contains(*ca.dead_blocks, pred) return true;
        f, ks := table_find(*ca.known_successors, pred);
        return f && ks != NONE && ks != succ;
    }
    is_newly_dead :: (ca: *Call_Analyzer, bb: Value_Id) -> bool {
        if table_contains(*ca.dead_blocks, bb) return false;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds if !is_edge_dead(ca, p, bb) return false;
        return true;
    }
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(curr, *succs);
    for succ: succs {
        if succ == next || !is_newly_dead(ca, succ) continue;
        new_dead: [..] Value_Id; new_dead.allocator = temp;
        array_add(*new_dead, succ);
        while new_dead.count {
            dead := pop(*new_dead);
            if table_contains(*ca.dead_blocks, dead) continue;
            table_set(*ca.dead_blocks, dead, true);
            ss: [..] Value_Id; ss.allocator = temp;
            block_successors(dead, *ss);
            for s: ss if is_newly_dead(ca, s) array_add(*new_dead, s);
        }
    }
}

// CodeMetrics::collectEphemeralValues(F, AC, EphValues)
collect_ephemeral_values_fn :: (f: Value_Id, ac: *Assumption_Cache, eph: *Table(Value_Id, bool)) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    append_spec_ops :: (v: Value_Id, visited: *Table(Value_Id, bool), work: *[..] Value_Id) {
        if !is_inst(v) return;
        for k: 0..cast(s64) nops(v) - 1 {
            o := op(v, cast(u32) k);
            if o == NONE || table_contains(visited, o) continue;
            table_set(visited, o, true);
            if is_inst(o) && !may_have_side_effects(o) && !is_terminator(inst_op(o)) array_add(work, o);
        }
    }
    for a: ac.assumes {
        if vkind(a) != .INST continue;
        if table_contains(eph, a) continue;
        table_set(eph, a, true);
        append_spec_ops(a, *visited, *work);
    }
    i := 0;
    while i < work.count {
        v := work[i];
        i += 1;
        all := true;
        u := ir.v_first_use[v];
        while u != NONE { if !table_contains(eph, ir.u_user[u]) { all = false; break; } u = ir.u_next[u]; }
        if !all continue;
        table_set(eph, v, true);
        append_spec_ops(v, *visited, *work);
    }
}

// CallAnalyzer::analyze (with InlineCostCallAnalyzer::onAnalysisStart / onBlock* / finalizeAnalysis)
cax_analyze :: (ca: *Call_Analyzer) -> Inline_Result {
    // onAnalysisStart
    cax_update_threshold(ca);
    ca.threshold += ca.single_bb_bonus + ca.vector_bonus;
    cax_add_cost(ca, -get_callsite_cost(ca.tti, ca.call));
    if glob(ca.f).cc == CC_COLD cax_add_cost(ca, IC_COLDCC_PENALTY);
    if ca.cost >= ca.threshold && !ca.compute_full_inline_cost return ir_failure("high cost");
    f := ca.f;
    if glob(f).first_block == NONE return ir_success();
    caller := inst_fn(ca.call);
    u := ir.v_first_use[caller];
    while u != NONE {
        usr := ir.u_user[u];
        if vkind(usr) == .INST && is_call_base(usr) && inst_fn(usr) == caller { ca.is_caller_recursive = true; break; }
        u = ir.u_next[u];
    }
    for k: 0..cast(s64) glob(f).nargs - 1 {
        fa := fn_arg(f, cast(u32) k);
        cai := call_arg(ca.call, cast(u32) k);
        table_set(*ca.simplified, fa, cai);
        if is_constant_kind(vkind(cai)) ca.num_constant_args += 1;
        ok, off, ptr_arg := cax_strip_and_compute_inbounds_constant_offsets(ca, cai);
        if ok {
            bo: Base_Offset; bo.base = ptr_arg; bo.offset = off;
            table_set(*ca.const_offset_ptrs, fa, bo);
            if vkind(ptr_arg) == .INST && inst_op(ptr_arg) == .ALLOCA {
                table_set(*ca.sroa_arg_values, fa, ptr_arg);
                // onInitializeSROAArg
                c := tti_caller_alloca_cost(ca.tti, ca.call, ptr_arg);
                ca.sroa_cost_savings += cast(u64) c;
                table_set(*ca.sroa_arg_costs, ptr_arg, c);
                table_set(*ca.enabled_sroa, ptr_arg, true);
            }
        }
    }
    ca.num_constant_offset_ptr_args = cast(u32) ca.const_offset_ptrs.count;
    ca.num_alloca_args = cast(u32) ca.sroa_arg_values.count;
    eph: Table(Value_Id, bool); eph.allocator = temp;
    collect_ephemeral_values_fn(f, get_assumption_cache(f), *eph);
    worklist: [..] Value_Id; worklist.allocator = temp;
    in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
    wl_insert :: (wl: *[..] Value_Id, s: *Table(Value_Id, bool), b: Value_Id) { if table_contains(s, b) return; table_set(s, b, true); array_add(wl, b); }
    wl_insert(*worklist, *in_wl, fn_entry(f));
    idx := 0;
    while idx < worklist.count {
        defer idx += 1;
        if cax_should_stop(ca) break;
        bb := worklist[idx];
        if block_first(bb) == NONE continue;
        ca.cost_at_bb_start = ca.cost;
        if block_has_address_taken_any(bb) return ir_failure("blockaddress used");
        r := cax_analyze_block(ca, bb, *eph);
        if !r.ok return r;
        ti := block_terminator(bb);
        if inst_op(ti) == .CONDBR {
            sc := cax_simplified(ca, op(ti, 0), .CONSTANT_INT);
            if sc != NONE {
                nb := get_successor(ti, ifx ap_is_zero(const_ap(sc)) then cast(u32) 1 else 0);
                wl_insert(*worklist, *in_wl, nb);
                table_set(*ca.known_successors, bb, nb);
                cax_find_dead_blocks(ca, bb, nb);
                continue;
            }
        } else if inst_op(ti) == .SWITCH {
            sc := cax_simplified(ca, op(ti, 0), .CONSTANT_INT);
            if sc != NONE {
                nb := switch_find_case_dest_value(ti, sc);
                wl_insert(*worklist, *in_wl, nb);
                table_set(*ca.known_successors, bb, nb);
                cax_find_dead_blocks(ca, bb, nb);
                continue;
            }
        }
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for succs wl_insert(*worklist, *in_wl, it);
        // onBlockAnalyzed
        if ca.single_bb && num_successors(ti) > 1 { ca.threshold -= ca.single_bb_bonus; ca.single_bb = false; }
    }
    if !is_sole_call_to_local_function(ca.call, f) && ca.contains_no_duplicate_call return ir_failure("noduplicate");
    final_stack := ic_opts.stack_size_threshold;
    if !ic_opts.stack_size_given {
        ok, v := fn_str_attr_as_int(caller, "inline-max-stacksize");
        if ok final_stack = cast,no_check(u64) v;
    }
    if ca.allocated_size > final_stack return ir_failure("stacksize");
    return cax_finalize_analysis(ca);
}
// SwitchInst::findCaseValue by value (the simplified condition is a constant equal to a case value)
switch_find_case_dest_value :: (sw: Value_Id, c: Value_Id) -> Value_Id {
    for k: 2..nops(sw)-1 {
        cv := ir.u_aux[ir.v_ops[sw] + k];
        if cv == c || ap_eq(const_ap(cv), const_ap(c)) return op(sw, k);
    }
    return op(sw, 1);
}
// finalizeAnalysis
cax_finalize_analysis :: (ca: *Call_Analyzer) -> Inline_Result {
    caller := inst_fn(ca.call);
    if fn_has_min_size(caller) {
        dt := dt_new(false);
        dt_recalculate(dt, ca.f);
        li := li_new(ca.f);
        li_analyze(li, dt);
        num_loops := 0;
        for l: li.top_level if !table_contains(*ca.dead_blocks, li_header(li, l)) num_loops += 1;
        li_free(li); dt_free(dt);
        cax_add_cost(ca, num_loops * IC_LOOP_PENALTY);
    }
    if ca.num_vector_instructions <= ca.num_instructions / 10 ca.threshold -= ca.vector_bonus;
    else if ca.num_vector_instructions <= ca.num_instructions / 2 ca.threshold -= ca.vector_bonus / 2;
    ok, ac := call_str_fn_attr_as_int(ca.call, "function-inline-cost");
    if ok ca.cost = ac;
    ok2, mult := call_str_fn_attr_as_int(ca.call, "function-inline-cost-multiplier");
    if ok2 ca.cost *= mult;
    ok3, th := call_str_fn_attr_as_int(ca.call, "function-inline-threshold");
    if ok3 ca.threshold = th;
    if ca.ignore_threshold return ir_success();
    ca.decided_by_cost_threshold = true;
    if ca.cost < max(1, ca.threshold) return ir_success();
    return ir_failure("Cost over threshold.");
}

// getCallsiteCost
get_callsite_cost :: (t: *Tti, call: Value_Id) -> s64 {
    cost: s64 = 0;
    ic := ic_opts.instr_cost;
    for k: 0..cast(s64) call_num_args(call) - 1 {
        if call_is_byval_arg(call, cast(u32) k) {
            bt := call_param_byval_type(call, cast(u32) k);
            type_size := dl_type_size_bits(bt);
            as := cast(u32) ir.types[vtype(call_arg(call, cast(u32) k))].a;
            psize := dl_ptr_size_bits_as(as);
            num_stores := (type_size + psize - 1) / psize;
            if num_stores > 8 num_stores = 8;
            cost += 2 * cast(s64) num_stores * ic;
        } else cost += ic;
    }
    cost += ic;
    cost += tti_inline_call_penalty(t, inst_fn(call), call, ic_opts.call_penalty);
    return min(cost, INT_MAX32);
}

// getAttributeBasedInliningDecision: (decided, result)
get_attribute_based_inlining_decision :: (call: Value_Id, callee: Value_Id) -> (bool, Inline_Result) {
    if callee == NONE return true, ir_failure("indirect call");
    if fn_has_fn_attr(callee, .PresplitCoroutine) return true, ir_failure("unsplited coroutine call");
    caller := inst_fn(call);
    if !ic_opts.ignore_tti_inline_compatible && !tti_are_inline_compatible(caller, callee) return true, ir_failure("conflicting target features");
    if call_has_fn_attr(call, .AlwaysInline) {
        if attr_set_has(call_fn_attrs(call), .NoInline) return true, ir_failure("noinline call site attribute");
        v := is_inline_viable(callee);
        if v.ok return true, ir_success();
        return true, ir_failure(v.reason);
    }
    if !(tli_are_inline_compatible(tli_for(caller), tli_for(callee), ic_opts.caller_superset_nobuiltin) && fn_attrs_inline_compatible(caller, callee))
        return true, ir_failure("conflicting attributes");
    if fn_has_fn_attr(caller, .Flatten) {
        v := is_inline_viable(callee);
        if v.ok return true, ir_success();
        return true, ir_failure(v.reason);
    }
    if fn_has_fn_attr(caller, .OptimizeNone) return true, ir_failure("optnone attribute");
    if gv_is_interposable_no_ipa_check(callee) return true, ir_failure("interposable");
    if fn_has_fn_attr(callee, .NoInline) return true, ir_failure("noinline function attribute");
    if call_has_fn_attr(call, .NoInline) return true, ir_failure("noinline call site attribute");
    if fn_find_str_attr(callee, "loader-replaceable") return true, ir_failure("loader replaceable function attribute");
    return false, ir_success();
}
// GlobalValue::isInterposable(CheckNoIPA = false)
gv_is_interposable_no_ipa_check :: (g: Value_Id) -> bool {
    l := glob(g).linkage;
    if l == .WEAK_ANY || l == .LINKONCE_ANY || l == .COMMON || l == .EXTERN_WEAK return true;
    if !glob(g).dso_local && module_semantic_interposition() return true;
    return false;
}

// getInlineCost(Call, Callee, Params, ...)
get_inline_cost :: (call: Value_Id, params: Inline_Params) -> Inline_Cost {
    callee := call_called_function(call);
    decided, r := get_attribute_based_inlining_decision(call, callee);
    if decided {
        if r.ok return inline_cost_always("always inline attribute");
        return inline_cost_never(r.reason);
    }
    if ic_opts.inline_all_viable_calls && is_inline_viable(callee).ok return inline_cost_always("Inlining forced by -inline-all-viable-calls");
    ca := cax_new(callee, call, params, true, false);
    should := cax_analyze(ca);
    if ca.decided_by_cost_threshold return inline_cost_get(ca.cost, ca.threshold, ca.static_bonus_applied);
    if should.ok return inline_cost_always("empty function");
    return inline_cost_never(should.reason);
}

// isInlineViable
is_inline_viable :: (f: Value_Id) -> Inline_Result {
    returns_twice := fn_has_fn_attr(f, .ReturnsTwice);
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .INDIRECTBR return ir_failure("contains indirect branches");
        if block_has_address_taken_any(bb) return ir_failure("blockaddress used");
        for i: block_insts(bb) {
            if !is_call_base(i) continue;
            callee := call_called_function(i);
            if callee == f return ir_failure("recursive call");
            if !returns_twice && inst_op(i) == .CALL && call_has_fn_attr(i, .ReturnsTwice) return ir_failure("exposes returns-twice attribute");
            if callee != NONE {
                id := fn_iid(callee);
                if id == IID_ICALL_BRANCH_FUNNEL return ir_failure("disallowed inlining of @llvm.icall.branch.funnel");
                if id == IID_LOCALESCAPE return ir_failure("disallowed inlining of @llvm.localescape");
                if id == IID_VASTART return ir_failure("contains VarArgs initialized with va_start");
            }
        }
    }
    return ir_success();
}

// operator<<(raw_ostream, const InlineCost &) / inlineCostStr
inline_cost_str :: (c: Inline_Cost) -> string {
    sb: String_Builder; sb.allocator = temp;
    if ic_is_always(c) append(*sb, "(cost=always)");
    else if ic_is_never(c) append(*sb, "(cost=never)");
    else print_to_builder(*sb, "(cost=%, threshold=%)", c.cost, c.threshold);
    if c.reason.count print_to_builder(*sb, ": %", c.reason);
    return builder_to_string(*sb,, allocator = temp);
}

// cl::opts of InlineCost.cpp and the jump-table options of TargetLoweringBase.cpp
inline_cost_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_opt :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    bool_opt :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == {
        case "inlinedefault-threshold"; ic_opts.default_threshold = int_opt(name, value, has_value);
        case "ignore-tti-inline-compatible"; ic_opts.ignore_tti_inline_compatible = bool_opt(name, value, has_value);
        case "inline-threshold"; ic_opts.inline_threshold = int_opt(name, value, has_value); ic_opts.inline_threshold_given = true;
        case "inlinehint-threshold"; ic_opts.hint_threshold = int_opt(name, value, has_value);
        case "inline-cold-callsite-threshold"; ic_opts.cold_callsite_threshold = int_opt(name, value, has_value);
        case "inlinecold-threshold"; ic_opts.cold_threshold = int_opt(name, value, has_value); ic_opts.cold_threshold_given = true;
        case "hot-callsite-threshold"; ic_opts.hot_callsite_threshold = int_opt(name, value, has_value);
        case "locally-hot-callsite-threshold"; ic_opts.locally_hot_callsite_threshold = int_opt(name, value, has_value); ic_opts.locally_hot_given = true;
        case "cold-callsite-rel-freq"; ic_opts.cold_callsite_rel_freq = int_opt(name, value, has_value);
        case "hot-callsite-rel-freq"; ic_opts.hot_callsite_rel_freq = cast(u64) int_opt(name, value, has_value);
        case "inline-instr-cost"; ic_opts.instr_cost = int_opt(name, value, has_value);
        case "inline-asm-instr-cost"; ic_opts.inline_asm_instr_cost = int_opt(name, value, has_value);
        case "inline-memaccess-cost"; ic_opts.mem_access_cost = int_opt(name, value, has_value);
        case "inline-call-penalty"; ic_opts.call_penalty = int_opt(name, value, has_value);
        case "inline-max-stacksize"; ic_opts.stack_size_threshold = cast,no_check(u64) int_opt(name, value, has_value); ic_opts.stack_size_given = true;
        case "recursive-inline-max-stacksize"; ic_opts.recur_stack_size_threshold = cast,no_check(u64) int_opt(name, value, has_value);
        case "inline-cost-full"; ic_opts.compute_full_inline_cost = bool_opt(name, value, has_value);
        case "inline-caller-superset-nobuiltin"; ic_opts.caller_superset_nobuiltin = bool_opt(name, value, has_value);
        case "disable-gep-const-evaluation"; ic_opts.disable_gep_const_evaluation = bool_opt(name, value, has_value);
        case "inline-all-viable-calls"; ic_opts.inline_all_viable_calls = bool_opt(name, value, has_value);
        case "min-jump-table-entries"; ic_opts.min_jump_table_entries = cast(u64) int_opt(name, value, has_value);
        case "max-jump-table-size"; ic_opts.max_jump_table_size = cast(u64) int_opt(name, value, has_value);
        case "jump-table-density"; ic_opts.jump_table_density = cast(u64) int_opt(name, value, has_value);
        case "optsize-jump-table-density"; ic_opts.optsize_jump_table_density = cast(u64) int_opt(name, value, has_value);
        case "min-bit-test-cmps"; ic_opts.min_bit_test_cmps = cast(u64) int_opt(name, value, has_value);
        case "enable-noalias-to-md-conversion"; if_opts.enable_noalias_to_md_conversion = bool_opt(name, value, has_value);
        case "use-noalias-intrinsic-during-inlining"; if_opts.use_noalias_intrinsic = bool_opt(name, value, has_value);
        case "preserve-alignment-assumptions-during-inlining"; if_opts.preserve_alignment_assumptions = bool_opt(name, value, has_value);
        case "max-inst-checked-for-throw-during-inlining"; if_opts.attribute_window = int_opt(name, value, has_value);
        case; return false;
    }
    return true;
}

IID_ICALL_BRANCH_FUNNEL :: #run iid_by_name("llvm.icall.branch.funnel");
IID_LOCALESCAPE :: #run iid_by_name("llvm.localescape");
CC_COLD :: 9;
