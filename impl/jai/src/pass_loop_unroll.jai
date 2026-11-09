// LoopUnroll: the loop-unroll (function pass) and loop-unroll-full (loop pass) passes.
// Port of llvm/lib/Transforms/Scalar/LoopUnrollPass.cpp (gatherUnrollingPreferences, analyzeLoopUnrollCost,
// UnrollCostEstimator, UnrollPragmaInfo, shouldPragmaUnroll / shouldFullUnroll / shouldPartialUnroll,
// computeUnrollCount, tryToUnrollLoop, LoopFullUnrollPass::run, LoopUnrollPass::run, the cl::opts),
// llvm/lib/Analysis/LoopUnrollAnalyzer.cpp (UnrolledInstAnalyzer), the unrolling/peeling preferences of the targets
// (TargetTransformInfoImplBase: none; BasicTTIImplBase::getUnrollingPreferences / getPeelingPreferences, which
// X86TTIImpl inherits; the scheduling model's LoopMicroOpBufferSize comes from gen_x86_sched.jai) and
// CodeMetrics::analyzeBasicBlock with a loop (llvm/lib/Analysis/CodeMetrics.cpp: convergence kinds).
//
// The transformation itself is in loop_unroll_utils.jai (UnrollLoop), loop_unroll_runtime.jai (runtime remainder)
// and loop_peel.jai (peeling). Optimization remarks are not emitted (no -pass-remarks support).

// ---------------------------------------------------------------- cl::opts (with getNumOccurrences)

Lu_Opt :: struct { v: s64; given: bool; }
lu_cl: struct {
    forget_scev_loop_unroll: Lu_Opt;                     // -forget-scev-loop-unroll (false)
    unroll_threshold: Lu_Opt;                             // -unroll-threshold
    unroll_optsize_threshold: Lu_Opt;                     // -unroll-optsize-threshold (0)
    unroll_partial_threshold: Lu_Opt;
    unroll_max_percent_threshold_boost := Lu_Opt.{400, false};
    unroll_max_iteration_count_to_analyze := Lu_Opt.{10, false};
    unroll_count: Lu_Opt;
    unroll_max_count: Lu_Opt;
    unroll_full_max_count: Lu_Opt;
    unroll_allow_partial: Lu_Opt;
    unroll_allow_remainder: Lu_Opt;
    unroll_runtime: Lu_Opt;
    unroll_max_upperbound := Lu_Opt.{8, false};
    pragma_unroll_threshold := Lu_Opt.{16 * 1024, false};
    flat_loop_tripcount_threshold := Lu_Opt.{5, false};
    unroll_remainder: Lu_Opt;
    unroll_revisit_child_loops: Lu_Opt;
    unroll_threshold_aggressive := Lu_Opt.{300, false};
    unroll_threshold_default := Lu_Opt.{150, false};
    pragma_unroll_full_max_iterations := Lu_Opt.{1_000_000, false};
    // LoopUnroll.cpp
    unroll_runtime_epilog: Lu_Opt;
    unroll_verify_domtree: Lu_Opt;
    unroll_verify_loopinfo: Lu_Opt;
    unroll_add_parallel_reductions: Lu_Opt;
    // LoopUnrollRuntime.cpp
    unroll_runtime_multi_exit: Lu_Opt;
    unroll_runtime_other_exit_predictable: Lu_Opt;
    // LoopPeel.cpp
    unroll_peel_count: Lu_Opt;
    unroll_allow_peeling := Lu_Opt.{1, false};
    unroll_allow_loop_nests_peeling: Lu_Opt;
    unroll_peel_max_count := Lu_Opt.{7, false};
    unroll_force_peel_count: Lu_Opt;
    disable_advanced_peeling: Lu_Opt;
    enable_peeling_for_iv: Lu_Opt;
    // BasicTTIImpl.cpp
    partial_unrolling_threshold: Lu_Opt;
};
LU_BOOL :: 0; LU_UINT :: 1;
Lu_Cl_Row :: struct { name: string; kind: u8; p: *Lu_Opt; }
lu_cl_rows :: () -> [] Lu_Cl_Row {
    rows := NewArray(35, Lu_Cl_Row,, allocator = temp);
    rows[0] = .{"forget-scev-loop-unroll", LU_BOOL, *lu_cl.forget_scev_loop_unroll};
    rows[1] = .{"unroll-threshold", LU_UINT, *lu_cl.unroll_threshold};
    rows[2] = .{"unroll-optsize-threshold", LU_UINT, *lu_cl.unroll_optsize_threshold};
    rows[3] = .{"unroll-partial-threshold", LU_UINT, *lu_cl.unroll_partial_threshold};
    rows[4] = .{"unroll-max-percent-threshold-boost", LU_UINT, *lu_cl.unroll_max_percent_threshold_boost};
    rows[5] = .{"unroll-max-iteration-count-to-analyze", LU_UINT, *lu_cl.unroll_max_iteration_count_to_analyze};
    rows[6] = .{"unroll-count", LU_UINT, *lu_cl.unroll_count};
    rows[7] = .{"unroll-max-count", LU_UINT, *lu_cl.unroll_max_count};
    rows[8] = .{"unroll-full-max-count", LU_UINT, *lu_cl.unroll_full_max_count};
    rows[9] = .{"unroll-allow-partial", LU_BOOL, *lu_cl.unroll_allow_partial};
    rows[10] = .{"unroll-allow-remainder", LU_BOOL, *lu_cl.unroll_allow_remainder};
    rows[11] = .{"unroll-runtime", LU_BOOL, *lu_cl.unroll_runtime};
    rows[12] = .{"unroll-max-upperbound", LU_UINT, *lu_cl.unroll_max_upperbound};
    rows[13] = .{"pragma-unroll-threshold", LU_UINT, *lu_cl.pragma_unroll_threshold};
    rows[14] = .{"flat-loop-tripcount-threshold", LU_UINT, *lu_cl.flat_loop_tripcount_threshold};
    rows[15] = .{"unroll-remainder", LU_BOOL, *lu_cl.unroll_remainder};
    rows[16] = .{"unroll-revisit-child-loops", LU_BOOL, *lu_cl.unroll_revisit_child_loops};
    rows[17] = .{"unroll-threshold-aggressive", LU_UINT, *lu_cl.unroll_threshold_aggressive};
    rows[18] = .{"unroll-threshold-default", LU_UINT, *lu_cl.unroll_threshold_default};
    rows[19] = .{"pragma-unroll-full-max-iterations", LU_UINT, *lu_cl.pragma_unroll_full_max_iterations};
    rows[20] = .{"unroll-runtime-epilog", LU_BOOL, *lu_cl.unroll_runtime_epilog};
    rows[21] = .{"unroll-verify-domtree", LU_BOOL, *lu_cl.unroll_verify_domtree};
    rows[22] = .{"unroll-verify-loopinfo", LU_BOOL, *lu_cl.unroll_verify_loopinfo};
    rows[23] = .{"unroll-add-parallel-reductions", LU_BOOL, *lu_cl.unroll_add_parallel_reductions};
    rows[24] = .{"unroll-runtime-multi-exit", LU_BOOL, *lu_cl.unroll_runtime_multi_exit};
    rows[25] = .{"unroll-runtime-other-exit-predictable", LU_BOOL, *lu_cl.unroll_runtime_other_exit_predictable};
    rows[26] = .{"unroll-peel-count", LU_UINT, *lu_cl.unroll_peel_count};
    rows[27] = .{"unroll-allow-peeling", LU_BOOL, *lu_cl.unroll_allow_peeling};
    rows[28] = .{"unroll-allow-loop-nests-peeling", LU_BOOL, *lu_cl.unroll_allow_loop_nests_peeling};
    rows[29] = .{"unroll-peel-max-count", LU_UINT, *lu_cl.unroll_peel_max_count};
    rows[30] = .{"unroll-force-peel-count", LU_UINT, *lu_cl.unroll_force_peel_count};
    rows[31] = .{"disable-advanced-peeling", LU_BOOL, *lu_cl.disable_advanced_peeling};
    rows[32] = .{"enable-peeling-for-iv", LU_BOOL, *lu_cl.enable_peeling_for_iv};
    rows[33] = .{"partial-unrolling-threshold", LU_UINT, *lu_cl.partial_unrolling_threshold};
    rows[34] = .{"unroll-and-jam", LU_BOOL, null};   // placeholder: never matches (the name has no leading -)
    return rows;
}
// called from parse_cl_opt
unroll_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    for lu_cl_rows() {
        if it.p == null || it.name != name continue;
        if it.kind == LU_BOOL {
            if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" it.p.v = 1;
            else if value == "false" || value == "0" || value == "FALSE" || value == "False" it.p.v = 0;
            else fatal("invalid boolean value '%' for option -%", value, name);
        } else {
            if !has_value fatal("option -% needs a value", name);
            v, ok := string_to_int(value);
            if !ok || v < 0 || v > 0xFFFF_FFFF fatal("invalid unsigned value '%' for option -%", value, name);
            it.p.v = v;
        }
        it.p.given = true;
        return true;
    }
    return false;
}
lu_u32 :: inline (o: Lu_Opt) -> u32 { return cast,trunc(u32) o.v; }

UNROLL_NO_THRESHOLD :: cast(u32) 0xFFFF_FFFF;

// TargetTransformInfo::UnrollingPreferences
Unroll_Prefs :: struct {
    threshold: u32;
    max_percent_threshold_boost: u32;
    opt_size_threshold: u32;
    partial_threshold: u32;
    partial_opt_size_threshold: u32;
    count: u32;
    default_unroll_runtime_count: u32;
    max_count: u32;
    max_upper_bound: u32;
    full_unroll_max_count: u32;
    be_insns: u32;
    partial: bool;
    runtime: bool;
    allow_remainder: bool;
    unroll_remainder: bool;
    allow_expensive_trip_count: bool;
    force: bool;
    upper_bound: bool;
    unroll_and_jam: bool;
    unroll_and_jam_inner_loop_threshold: u32;
    max_iterations_count_to_analyze: u32;
    scev_expansion_budget: u32;
    runtime_unroll_multi_exit: bool;
    add_additional_accumulators: bool;
}
// TargetTransformInfo::PeelingPreferences
Peel_Prefs :: struct {
    peel_count: u32;
    allow_peeling: bool;
    allow_loop_nests_peeling: bool;
    peel_profiled_iterations: bool;
    peel_last: bool;
}

// Optional parameters of tryToUnrollLoop / LoopUnrollOptions (has_x = the optional is set)
Unroll_Options :: struct {
    has_count: bool; count: u32;
    has_threshold: bool; threshold: u32;
    has_partial: bool; partial: bool;
    has_runtime: bool; runtime: bool;
    has_upper_bound: bool; upper_bound: bool;
    has_peeling: bool; peeling: bool;
    has_profile_peeling: bool; profile_peeling: bool;
    has_full_unroll_max_count: bool; full_unroll_max_count: u32;
}

// X86 scheduling model of the TuneCPU (MCSchedModel::LoopMicroOpBufferSize; unknown CPU = MCSchedModel::Default)
x86_loop_micro_op_buffer_size :: (t: *Tti) -> u32 {
    for X86_SCHED if it.cpu == t.xl.tune_cpu return it.loop_micro_op_buffer_size;
    return 0;
}

// TTI.getUnrollingPreferences(L, SE, UP, ORE)
tti_get_unrolling_preferences :: (t: *Tti, li: *Loop_Info, l: Loop_Id, up: *Unroll_Prefs) {
    if t.kind != .X86 return;   // TargetTransformInfoImplBase: nothing
    // BasicTTIImplBase::getUnrollingPreferences
    max_ops: u32;
    if lu_cl.partial_unrolling_threshold.given max_ops = lu_u32(lu_cl.partial_unrolling_threshold);
    else {
        b := x86_loop_micro_op_buffer_size(t);
        if b > 0 max_ops = b;
        else return;
    }
    for bb: li_blocks(li, l) for i: block_insts(bb) {
        o := inst_op(i);
        if o == .CALL || o == .INVOKE {
            f := call_called_function(i);
            if f != NONE && !tti_is_lowered_to_call(f) continue;
            return;
        }
    }
    up.partial = true; up.runtime = true; up.upper_bound = true;
    up.partial_threshold = max_ops;
    up.opt_size_threshold = 0;
    up.partial_opt_size_threshold = 0;
    up.be_insns = 2;
}
// TTI.getPeelingPreferences(L, SE, PP)
tti_get_peeling_preferences :: (t: *Tti, pp: *Peel_Prefs) {
    if t.kind != .X86 return;
    pp.peel_count = 0;
    pp.allow_peeling = true;
    pp.allow_loop_nests_peeling = false;
    pp.peel_profiled_iterations = true;
}

// gatherUnrollingPreferences (PSI and BFI are never available here: shouldOptimizeForSize is false)
gather_unrolling_preferences :: (li: *Loop_Info, l: Loop_Id, t: *Tti, opt_level: s64, o: *Unroll_Options) -> Unroll_Prefs {
    up: Unroll_Prefs;
    up.threshold = ifx opt_level > 2 then lu_u32(lu_cl.unroll_threshold_aggressive) else lu_u32(lu_cl.unroll_threshold_default);
    up.max_percent_threshold_boost = 400;
    up.opt_size_threshold = lu_u32(lu_cl.unroll_optsize_threshold);
    up.partial_threshold = 150;
    up.partial_opt_size_threshold = lu_u32(lu_cl.unroll_optsize_threshold);
    up.count = 0;
    up.default_unroll_runtime_count = 8;
    up.max_count = 0xFFFF_FFFF;
    up.max_upper_bound = lu_u32(lu_cl.unroll_max_upperbound);
    up.full_unroll_max_count = 0xFFFF_FFFF;
    up.be_insns = 2;
    up.partial = false;
    up.runtime = false;
    up.allow_remainder = true;
    up.unroll_remainder = false;
    up.allow_expensive_trip_count = false;
    up.force = false;
    up.upper_bound = false;
    up.unroll_and_jam = false;
    up.unroll_and_jam_inner_loop_threshold = 60;
    up.max_iterations_count_to_analyze = lu_u32(lu_cl.unroll_max_iteration_count_to_analyze);
    up.scev_expansion_budget = cast(u32) scev_cheap_expansion_budget;
    up.runtime_unroll_multi_exit = false;
    up.add_additional_accumulators = false;

    tti_get_unrolling_preferences(t, li, l, *up);

    f := li.fn;
    opt_for_size := fn_has_opt_size(f);   // || shouldOptimizeForSize(Header, PSI = null, BFI = null) = false
    if opt_for_size {
        up.threshold = up.opt_size_threshold;
        up.partial_threshold = up.partial_opt_size_threshold;
        up.max_percent_threshold_boost = 100;
    }
    if lu_cl.unroll_threshold.given up.threshold = lu_u32(lu_cl.unroll_threshold);
    if lu_cl.unroll_partial_threshold.given up.partial_threshold = lu_u32(lu_cl.unroll_partial_threshold);
    if lu_cl.unroll_max_percent_threshold_boost.given up.max_percent_threshold_boost = lu_u32(lu_cl.unroll_max_percent_threshold_boost);
    if lu_cl.unroll_max_count.given up.max_count = lu_u32(lu_cl.unroll_max_count);
    if lu_cl.unroll_max_upperbound.given up.max_upper_bound = lu_u32(lu_cl.unroll_max_upperbound);
    if lu_cl.unroll_full_max_count.given up.full_unroll_max_count = lu_u32(lu_cl.unroll_full_max_count);
    if lu_cl.unroll_allow_partial.given up.partial = lu_cl.unroll_allow_partial.v != 0;
    if lu_cl.unroll_allow_remainder.given up.allow_remainder = lu_cl.unroll_allow_remainder.v != 0;
    if lu_cl.unroll_runtime.given up.runtime = lu_cl.unroll_runtime.v != 0;
    if lu_cl.unroll_max_upperbound.v == 0 up.upper_bound = false;
    if lu_cl.unroll_remainder.given up.unroll_remainder = lu_cl.unroll_remainder.v != 0;
    if lu_cl.unroll_max_iteration_count_to_analyze.given up.max_iterations_count_to_analyze = lu_u32(lu_cl.unroll_max_iteration_count_to_analyze);

    if o.has_threshold { up.threshold = o.threshold; up.partial_threshold = o.threshold; }
    if o.has_count up.count = o.count;
    if o.has_partial up.partial = o.partial;
    if o.has_runtime up.runtime = o.runtime;
    if o.has_upper_bound up.upper_bound = o.upper_bound;
    if o.has_full_unroll_max_count up.full_unroll_max_count = o.full_unroll_max_count;
    return up;
}

// ---------------------------------------------------------------- UnrolledInstAnalyzer (LoopUnrollAnalyzer.cpp)

Simplified_Address :: struct { base: Value_Id; offset: APInt; }
Unrolled_Inst_Analyzer :: struct {
    iteration_number: Scev_Id;
    simplified_values: *Table(Value_Id, Value_Id);
    simplified_addresses: Table(Value_Id, Simplified_Address);
    li: *Loop_Info;
    l: Loop_Id;
}
uia_lookup :: (a: *Unrolled_Inst_Analyzer, v: Value_Id) -> Value_Id {
    found, r := table_find(a.simplified_values, v);
    if found return r;
    return NONE;
}
// simplifyInstWithSCEV
uia_simplify_inst_with_scev :: (a: *Unrolled_Inst_Analyzer, i: Value_Id) -> bool {
    if !sc_is_scevable(vtype(i)) return false;
    s := sc_get_scev(i);
    if sc_is_const(s) { table_set(a.simplified_values, i, sc_value(s)); return true; }
    if !sc_is_zero(a.iteration_number) && sc_is_loop_invariant(s, a.l) return true;
    if sc_kind(s) != .ADDREC || sc_loop(s) != a.l return false;
    value_at_iteration := evaluate_at_iteration(s, a.iteration_number);
    if sc_is_const(value_at_iteration) { table_set(a.simplified_values, i, sc_value(value_at_iteration)); return true; }
    base := sc_get_pointer_base(s);
    if sc_kind(base) != .UNKNOWN return false;
    ok, offset := sc_compute_constant_difference(value_at_iteration, base);
    if !ok return false;
    table_set(*a.simplified_addresses, i, .{sc_value(base), offset});
    return false;
}
// visit(I): the InstVisitor dispatch (visitLoad, visitBinaryOperator, visitCastInst, visitCmpInst, visitPHINode,
// everything else visitInstruction)
uia_visit :: (a: *Unrolled_Inst_Analyzer, i: Value_Id) -> bool {
    o := inst_op(i);
    if o >= .ADD && o <= .XOR {
        // visitBinaryOperator
        lhs := op(i, 0); rhs := op(i, 1);
        if !is_constant_kind(vkind(lhs)) { s := uia_lookup(a, lhs); if s != NONE lhs = s; }
        if !is_constant_kind(vkind(rhs)) { s := uia_lookup(a, rhs); if s != NONE rhs = s; }
        q: Simplify_Query; q.have_tli = false;
        sv: Value_Id;
        if is_fp_math_inst(i) sv = simplify_binop_fmf(o, lhs, rhs, inst_fmf(i), q);
        else sv = simplify_binop(o, lhs, rhs, q);
        if sv != NONE { table_set(a.simplified_values, i, sv); return true; }
        return uia_simplify_inst_with_scev(a, i);
    }
    if o == .LOAD return uia_visit_load(a, i);
    if o >= .TRUNC && o <= .ADDRSPACECAST {
        // visitCastInst
        x := op(i, 0);
        s := uia_lookup(a, x);
        if s != NONE x = s;
        if cast_inst_cast_is_valid(o, vtype(x), vtype(i)) {
            q: Simplify_Query; q.have_tli = false;
            v := simplify_cast_inst(o, x, vtype(i), q);
            if v != NONE { table_set(a.simplified_values, i, v); return true; }
        }
        return uia_simplify_inst_with_scev(a, i);
    }
    if o == .ICMP || o == .FCMP {
        // visitCmpInst
        lhs := op(i, 0); rhs := op(i, 1);
        if !is_constant_kind(vkind(lhs)) { s := uia_lookup(a, lhs); if s != NONE lhs = s; }
        if !is_constant_kind(vkind(rhs)) { s := uia_lookup(a, rhs); if s != NONE rhs = s; }
        pred := inst(i).pred;
        if !is_constant_kind(vkind(lhs)) && !is_constant_kind(vkind(rhs)) && !cmp_is_signed(pred) {
            fl, la := table_find(*a.simplified_addresses, lhs);
            if fl {
                fr, ra := table_find(*a.simplified_addresses, rhs);
                if fr && la.base == ra.base {
                    res := ap_icmp_compare(la.offset, ra.offset, pred);
                    table_set(a.simplified_values, i, const_bool_of_type(vtype(i), res));
                    return true;
                }
            }
        }
        q: Simplify_Query; q.have_tli = false;
        v := simplify_cmp_inst(pred, false, lhs, rhs, q);
        if v != NONE { table_set(a.simplified_values, i, v); return true; }
        return uia_simplify_inst_with_scev(a, i);
    }
    if o == .PHI {
        if uia_simplify_inst_with_scev(a, i) return true;
        return inst_block(i) == li_header(a.li, a.l);
    }
    return uia_simplify_inst_with_scev(a, i);
}
// visitLoad
uia_visit_load :: (a: *Unrolled_Inst_Analyzer, i: Value_Id) -> bool {
    addr := op(i, 0);
    found, sa := table_find(*a.simplified_addresses, addr);
    if !found return false;
    gv := sa.base;
    if vkind(gv) != .GLOBAL_VAR || !gv_has_definitive_initializer(gv) || !glob(gv).is_const return false;
    res := cfo_load_from_const(gv_initializer(gv), vtype(i), sa.offset);
    if res == NONE return false;
    table_set(a.simplified_values, i, res);
    return true;
}
// CastInst::castIsValid(op, SrcTy, DstTy)
cast_inst_cast_is_valid :: (opc: Opcode, st: Type_Id, dt: Type_Id) -> bool {
    if !is_first_class(st) || !is_first_class(dt) || is_aggregate(st) || is_aggregate(dt) return false;
    // ElementCount: (count, scalable); scalars are (0, fixed)
    ec_eq :: (a: Type_Id, b: Type_Id) -> bool {
        ca: u64 = 0; cb: u64 = 0;
        if is_vector_type(a) ca = type_count(a);
        if is_vector_type(b) cb = type_count(b);
        return ca == cb && (type_kind(a) == .SVECTOR) == (type_kind(b) == .SVECTOR);
    }
    s := scalar_type(st); d := scalar_type(dt);
    sbits := ifx is_int_type(s) || is_fp_type(s) then type_bits(s) else 0;
    dbits := ifx is_int_type(d) || is_fp_type(d) then type_bits(d) else 0;
    if opc == {
        case .TRUNC; return is_int_type(s) && is_int_type(d) && ec_eq(st, dt) && sbits > dbits;
        case .ZEXT; #through;
        case .SEXT; return is_int_type(s) && is_int_type(d) && ec_eq(st, dt) && sbits < dbits;
        case .FPTRUNC; return is_fp_type(s) && is_fp_type(d) && ec_eq(st, dt) && sbits > dbits;
        case .FPEXT; return is_fp_type(s) && is_fp_type(d) && ec_eq(st, dt) && sbits < dbits;
        case .UITOFP; #through;
        case .SITOFP; return is_int_type(s) && is_fp_type(d) && ec_eq(st, dt);
        case .FPTOUI; #through;
        case .FPTOSI; return is_fp_type(s) && is_int_type(d) && ec_eq(st, dt);
        case .PTRTOADDR; #through;
        case .PTRTOINT; return ec_eq(st, dt) && is_ptr_type(s) && is_int_type(d);
        case .INTTOPTR; return ec_eq(st, dt) && is_int_type(s) && is_ptr_type(d);
        case .BITCAST; return cast_is_valid(opc, st, dt);
        case .ADDRSPACECAST;
            if !is_ptr_type(s) || !is_ptr_type(d) return false;
            if ptr_addrspace(s) == ptr_addrspace(d) return false;
            return ec_eq(st, dt);
    }
    return false;
}
// ICmpInst::compare(LHS, RHS, Pred) (an equality or unsigned/signed integer predicate on two APInts)
ap_icmp_compare :: (a: APInt, b: APInt, pred: u8) -> bool {
    if pred == ICMP_EQ return ap_eq(a, b);
    if pred == ICMP_NE return !ap_eq(a, b);
    if pred == ICMP_UGT return ap_ugt(a, b);
    if pred == ICMP_UGE return !ap_ult(a, b);
    if pred == ICMP_ULT return ap_ult(a, b);
    if pred == ICMP_ULE return !ap_ugt(a, b);
    if pred == ICMP_SGT return ap_sgt(a, b);
    if pred == ICMP_SGE return !ap_slt(a, b);
    if pred == ICMP_SLT return ap_slt(a, b);
    if pred == ICMP_SLE return !ap_sgt(a, b);
    fatal("internal: ICmpInst::compare with a non-integer predicate");
    return false;
}
// ConstantInt::getBool(Ty, V)
const_bool_of_type :: (t: Type_Id, b: bool) -> Value_Id {
    return cf_int(t, ap_from_u64(type_bits(scalar_type(t)), ifx b then cast(u64) 1 else 0));
}

// ---------------------------------------------------------------- analyzeLoopUnrollCost

Estimated_Unroll_Cost :: struct { unrolled_cost: u32; rolled_dynamic_cost: u32; }

// returns (ok, cost)
analyze_loop_unroll_cost :: (li: *Loop_Info, l: Loop_Id, trip_count: u32, dt: *Dom_Tree, eph: *Table(Value_Id, bool),
                             t: *Tti, max_unrolled_loop_size: u32, max_iterations_count_to_analyze: u32) -> (bool, Estimated_Unroll_Cost) {
    none: Estimated_Unroll_Cost;
    if !li_is_innermost(li, l) return false, none;
    if trip_count == 0 || trip_count > max_iterations_count_to_analyze return false, none;

    bb_worklist: [..] Value_Id; bb_worklist.allocator = temp;          // SmallSetVector
    bb_in: Table(Value_Id, bool); bb_in.allocator = temp;
    exit_worklist: [..] [2] Value_Id; exit_worklist.allocator = temp;   // SmallSetVector of pairs
    simplified_values: Table(Value_Id, Value_Id); simplified_values.allocator = temp;
    simplified_input_values: [..] [2] Value_Id; simplified_input_values.allocator = temp;
    unrolled_cost: Cost = 0;
    rolled_dynamic_cost: Cost = 0;
    // InstCostMap: (instruction, iteration) -> IsFree | IsCounted << 1
    inst_cost_map: Table(u64, u8); inst_cost_map.allocator = temp;
    cost_worklist: [..] Value_Id; cost_worklist.allocator = temp;
    phi_used_list: [..] Value_Id; phi_used_list.allocator = temp;
    f := li.fn;
    cost_kind := ifx fn_has_min_size(f) then TCK_CODE_SIZE else TCK_SIZE_AND_LATENCY;
    header := li_header(li, l);
    latch := li_loop_latch(li, l);

    key :: (i: Value_Id, it: s64) -> u64 { return ((cast(u64) i) << 32) | cast(u64) cast,trunc(u32) it; }

    // AddCostRecursively
    add_cost_recursively :: (root: Value_Id, iteration_in: s64, ctx: *Cost_Ctx) {
        iteration := iteration_in;
        array_add(ctx.cost_worklist, root);
        while true {
            while ctx.cost_worklist.count {
                i := pop(ctx.cost_worklist);
                p := table_find_pointer(ctx.inst_cost_map, key(i, iteration));
                if !p continue;
                if p.* & 2 continue;
                p.* |= 2;
                if is_phi(i) && inst_block(i) == ctx.header {
                    if iteration == 0 continue;
                    opi := phi_incoming_value_for_block(i, ctx.latch);
                    if is_inst(opi) && li_contains_inst(ctx.li, ctx.l, opi) array_add(ctx.phi_used_list, opi);
                    continue;
                }
                if !(p.* & 1) {
                    n := nops(i);
                    ops := NewArray(n, Value_Id,, allocator = temp);
                    for k: 0..cast(s64) n - 1 {
                        o := op(i, cast(u32) k);
                        found, r := table_find(ctx.simplified_values, o);
                        ops[k] = ifx found && r != NONE then r else o;
                    }
                    ctx.unrolled_cost.* = cost_add(ctx.unrolled_cost.*, tti_instruction_cost_ops(ctx.t, i, ops, ctx.cost_kind));
                }
                n := nops(i);
                for k: 0..cast(s64) n - 1 {
                    o := op(i, cast(u32) k);
                    if !is_inst(o) || !li_contains_inst(ctx.li, ctx.l, o) continue;
                    array_add(ctx.cost_worklist, o);
                }
            }
            if ctx.phi_used_list.count == 0 break;
            for ctx.phi_used_list.* array_add(ctx.cost_worklist, it);
            ctx.phi_used_list.count = 0;
            iteration -= 1;
        }
    }
    ctx: Cost_Ctx;
    ctx.cost_worklist = *cost_worklist; ctx.phi_used_list = *phi_used_list; ctx.inst_cost_map = *inst_cost_map;
    ctx.simplified_values = *simplified_values; ctx.unrolled_cost = *unrolled_cost; ctx.t = t; ctx.cost_kind = cost_kind;
    ctx.li = li; ctx.l = l; ctx.header = header; ctx.latch = latch;

    preheader := li_loop_preheader(li, l);
    iteration: u32 = 0;
    while iteration < trip_count {
        defer iteration += 1;
        for i: block_insts(header) {
            if !is_phi(i) break;
            v := phi_incoming_value_for_block(i, ifx iteration == 0 then preheader else latch);
            if iteration != 0 {
                found, r := table_find(*simplified_values, v);
                if found v = r;
            }
            array_add(*simplified_input_values, .[i, v]);
        }
        table_reset(*simplified_values);
        while simplified_input_values.count {
            e := pop(*simplified_input_values);
            if !table_contains(*simplified_values, e[0]) table_set(*simplified_values, e[0], e[1]);
        }
        an: Unrolled_Inst_Analyzer;
        an.iteration_number = sc_get_constant(ap_from_u64(64, iteration));
        an.simplified_values = *simplified_values;
        an.simplified_addresses.allocator = temp;
        an.li = li; an.l = l;

        bb_worklist.count = 0; table_reset(*bb_in);
        array_add(*bb_worklist, header); table_set(*bb_in, header, true);
        idx := 0;
        while idx != bb_worklist.count {
            bb := bb_worklist[idx];
            idx += 1;
            for i: block_insts(bb) {
                if table_contains(eph, i) continue;
                rolled_dynamic_cost = cost_add(rolled_dynamic_cost, tti_instruction_cost(t, i, cost_kind));
                is_free := uia_visit(*an, i);
                table_set(*inst_cost_map, key(i, iteration), ifx is_free then cast(u8) 1 else 0);
                if is_free continue;
                if inst_op(i) == .CALL {
                    callee := call_called_function(i);
                    if callee == NONE || tti_is_lowered_to_call(callee) return false, none;
                }
                if may_have_side_effects(i) add_cost_recursively(i, iteration, *ctx);
                if unrolled_cost > max_unrolled_loop_size return false, none;
            }
            ti := block_terminator(bb);
            get_simplified_constant :: (v_in: Value_Id, sv: *Table(Value_Id, Value_Id)) -> Value_Id {
                v := v_in;
                found, r := table_find(sv, v);
                if found v = r;
                if v != NONE && is_constant_kind(vkind(v)) return v;
                return NONE;
            }
            known_succ: Value_Id = NONE;
            if inst_op(ti) == .CONDBR {
                sc := get_simplified_constant(op(ti, 0), *simplified_values);
                if sc != NONE {
                    if vkind(sc) == .C_UNDEF || vkind(sc) == .C_POISON known_succ = get_successor(ti, 0);
                    else if vkind(sc) == .C_INT known_succ = get_successor(ti, ifx ap_is_zero(const_ap(sc)) then cast(u32) 1 else 0);
                }
            } else if inst_op(ti) == .SWITCH {
                sc := get_simplified_constant(sw_cond(ti), *simplified_values);
                if sc != NONE {
                    if vkind(sc) == .C_UNDEF || vkind(sc) == .C_POISON known_succ = get_successor(ti, 0);
                    else if vkind(sc) == .C_INT known_succ = switch_find_case_dest(ti, sc);
                }
            }
            add_exit :: (w: *[..] [2] Value_Id, a: Value_Id, b: Value_Id) {
                for w.* if it[0] == a && it[1] == b return;
                array_add(w, .[a, b]);
            }
            if known_succ != NONE {
                if li_contains(li, l, known_succ) {
                    if !table_contains(*bb_in, known_succ) { table_set(*bb_in, known_succ, true); array_add(*bb_worklist, known_succ); }
                } else add_exit(*exit_worklist, bb, known_succ);
                continue;
            }
            ns := num_successors(ti);
            for k: 0..cast(s64) ns - 1 {
                succ := get_successor(ti, cast(u32) k);
                if li_contains(li, l, succ) {
                    if !table_contains(*bb_in, succ) { table_set(*bb_in, succ, true); array_add(*bb_worklist, succ); }
                } else add_exit(*exit_worklist, bb, succ);
            }
            add_cost_recursively(ti, iteration, *ctx);
        }
        if unrolled_cost == rolled_dynamic_cost return false, none;
    }
    while exit_worklist.count {
        e := pop(*exit_worklist);
        exiting_bb := e[0]; exit_bb := e[1];
        for pn: block_insts(exit_bb) {
            if !is_phi(pn) break;
            o := phi_incoming_value_for_block(pn, exiting_bb);
            if is_inst(o) && li_contains_inst(li, l, o) add_cost_recursively(o, trip_count - 1, *ctx);
        }
    }
    r: Estimated_Unroll_Cost;
    r.unrolled_cost = cast,trunc(u32) unrolled_cost;
    r.rolled_dynamic_cost = cast,trunc(u32) rolled_dynamic_cost;
    return true, r;
}
Cost_Ctx :: struct {
    cost_worklist: *[..] Value_Id;
    phi_used_list: *[..] Value_Id;
    inst_cost_map: *Table(u64, u8);
    simplified_values: *Table(Value_Id, Value_Id);
    unrolled_cost: *Cost;
    t: *Tti;
    cost_kind: s64;
    li: *Loop_Info;
    l: Loop_Id;
    header: Value_Id;
    latch: Value_Id;
}

// ---------------------------------------------------------------- UnrollCostEstimator

Convergence_Kind :: enum u8 { NONE; CONTROLLED; EXTENDED_LOOP; UNCONTROLLED; }
Unroll_Cost_Estimator :: struct {
    loop_size: Cost;
    not_duplicatable: bool;
    convergence: Convergence_Kind;
    convergence_allows_runtime: bool;
    num_inline_candidates: s64;
}
// isa<ConvergenceControlInst>
is_convergence_control_inst :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_EXPERIMENTAL_CONVERGENCE_LOOP || id == IID_EXPERIMENTAL_CONVERGENCE_ENTRY || id == IID_EXPERIMENTAL_CONVERGENCE_ANCHOR;
}
IID_EXPERIMENTAL_CONVERGENCE_ANCHOR :: #run iid_by_name("llvm.experimental.convergence.anchor");
// CodeMetrics::analyzeBasicBlock(BB, TTI, EphValues, PrepareForLTO = false, L) (only the fields UnrollCostEstimator reads)
cm_analyze_basic_block_loop :: (u: *Unroll_Cost_Estimator, t: *Tti, b: Value_Id, eph: *Table(Value_Id, bool), li: *Loop_Info, l: Loop_Id) {
    for i: block_insts(b) {
        if table_contains(eph, i) continue;
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee != NONE {
                lowered := tti_is_lowered_to_call(callee);
                if !call_has_fn_attr(i, .NoInline) && lowered && glob(callee).linkage == .INTERNAL && fn_has_one_live_use(callee)
                    u.num_inline_candidates += 1;
            }
        }
        if type_kind(vtype(i)) == .TOKEN && !is_convergence_control_inst(i) {
            x := ir.v_first_use[i];
            while x != NONE {
                user := ir.u_user[x];
                ub := inst_block(user);
                if inst_op(user) == .PHI ub = ir.u_aux[x];
                if ub != b { u.not_duplicatable = true; break; }
                x = ir.u_next[x];
            }
        }
        if is_call_base(i) {
            if call_cannot_duplicate(i) u.not_duplicatable = true;
            if u.convergence <= .CONTROLLED && call_has_fn_attr(i, .Convergent) {
                if is_convergence_control_inst(i) || call_convergence_control_token(i) != NONE {
                    // extendsConvergenceOutsideLoop
                    extends := false;
                    if is_convergence_control_inst(i) {
                        x := ir.v_first_use[i];
                        while x != NONE { if !li_contains_inst(li, l, ir.u_user[x]) { extends = true; break; } x = ir.u_next[x]; }
                    }
                    u.convergence = ifx extends then Convergence_Kind.EXTENDED_LOOP else .CONTROLLED;
                } else {
                    u.convergence = .UNCONTROLLED;
                }
            }
        }
        u.loop_size = cost_add(u.loop_size, tti_instruction_cost(t, i, TCK_CODE_SIZE));
    }
    term := block_terminator(b);
    if term != NONE && inst_op(term) == .INDIRECTBR u.not_duplicatable = true;
}
// UnrollCostEstimator::UnrollCostEstimator(L, TTI, EphValues, BEInsns, TripCountIsUniform)
unroll_cost_estimator :: (li: *Loop_Info, l: Loop_Id, t: *Tti, eph: *Table(Value_Id, bool), be_insns: u32, uniform: bool) -> Unroll_Cost_Estimator {
    u: Unroll_Cost_Estimator;
    for bb: li_blocks(li, l) cm_analyze_basic_block_loop(*u, t, bb, eph, li, l);
    u.convergence_allows_runtime = (u.convergence != .UNCONTROLLED && li_loop_convergence_heart(li, l) == NONE) || uniform;
    if u.loop_size != COST_INVALID && u.loop_size < cast(Cost) be_insns + 1 u.loop_size = cast(Cost) be_insns + 1;
    return u;
}
uce_can_unroll :: (u: *Unroll_Cost_Estimator) -> bool {
    if u.convergence == .EXTENDED_LOOP return false;
    if u.loop_size == COST_INVALID return false;
    if u.not_duplicatable return false;
    return true;
}
uce_rolled_loop_size :: (u: *Unroll_Cost_Estimator) -> u32 { return cast,trunc(u32) u.loop_size; }
// getUnrolledLoopSize(UP, CountOverwrite)
uce_unrolled_loop_size :: (u: *Unroll_Cost_Estimator, up: *Unroll_Prefs, count_overwrite: u32 = 0) -> u64 {
    ls := cast,trunc(u32) u.loop_size;
    c := ifx count_overwrite then count_overwrite else up.count;
    return cast(u64) (ls - up.be_insns) * cast(u64) c + up.be_insns;
}

// ---------------------------------------------------------------- pragmas

// getUnrollMetadataForLoop(L, Name)
li_unroll_metadata :: (li: *Loop_Info, l: Loop_Id, name: string) -> Md_Id {
    id := li_loop_id(li, l);
    if id == NONE return NONE;
    return get_unroll_metadata(id, name);
}
// GetUnrollMetadata(LoopID, Name)
get_unroll_metadata :: (loop_id: Md_Id, name: string) -> Md_Id {
    n := md_nops(loop_id);
    if n > 1 for k: 1..n-1 {
        md := md_op(loop_id, k);
        if !md_is_node(md) continue;
        if md_nops(md) == 0 continue;
        s := md_op(md, 0);
        if s == NONE || ir.mds[s].kind != .STRING continue;
        if ir.mds[s].str == name return md;
    }
    return NONE;
}
Unroll_Pragma_Info :: struct {
    user_unroll_count: bool;
    pragma_full_unroll: bool;
    pragma_count: u32;
    pragma_enable_unroll: bool;
    pragma_runtime_unroll_disable: bool;
    explicit_unroll: bool;
}
unroll_pragma_info :: (li: *Loop_Info, l: Loop_Id) -> Unroll_Pragma_Info {
    p: Unroll_Pragma_Info;
    p.user_unroll_count = lu_cl.unroll_count.given;
    p.pragma_full_unroll = li_unroll_metadata(li, l, "llvm.loop.unroll.full") != NONE;
    md := li_unroll_metadata(li, l, "llvm.loop.unroll.count");
    if md != NONE {
        c := ir.mds[md_op(md, 1)].value;
        p.pragma_count = cast,trunc(u32) const_int_zext(c);
    }
    p.pragma_enable_unroll = li_unroll_metadata(li, l, "llvm.loop.unroll.enable") != NONE;
    p.pragma_runtime_unroll_disable = li_unroll_metadata(li, l, "llvm.loop.unroll.runtime.disable") != NONE;
    p.explicit_unroll = p.pragma_count > 0 || p.pragma_full_unroll || p.pragma_enable_unroll || p.user_unroll_count;
    return p;
}

// getFullUnrollBoostingFactor
full_unroll_boosting_factor :: (c: Estimated_Unroll_Cost, max_percent_threshold_boost: u32) -> u32 {
    if c.rolled_dynamic_cost >= 0xFFFF_FFFF / 100 return 100;
    if c.unrolled_cost != 0 return min(100 * c.rolled_dynamic_cost / c.unrolled_cost, max_percent_threshold_boost);
    return max_percent_threshold_boost;
}

// shouldPragmaUnroll: (has value, count)
should_pragma_unroll :: (pinfo: *Unroll_Pragma_Info, trip_multiple: u32, trip_count: u32, max_trip_count: u32, uce: *Unroll_Cost_Estimator, up: *Unroll_Prefs) -> (bool, u32) {
    if pinfo.user_unroll_count {
        if up.allow_remainder && uce_unrolled_loop_size(uce, up, lu_u32(lu_cl.unroll_count)) < up.threshold return true, lu_u32(lu_cl.unroll_count);
    }
    if pinfo.pragma_count > 0 {
        if up.allow_remainder || trip_multiple % pinfo.pragma_count == 0 return true, pinfo.pragma_count;
    }
    if pinfo.pragma_full_unroll {
        if trip_count != 0 {
            if trip_count > lu_u32(lu_cl.pragma_unroll_full_max_iterations) return false, 0;
            return true, trip_count;
        }
    }
    if pinfo.pragma_enable_unroll && trip_count == 0 && max_trip_count != 0 && max_trip_count <= up.max_upper_bound return true, max_trip_count;
    return false, 0;
}

// shouldFullUnroll
should_full_unroll :: (li: *Loop_Info, l: Loop_Id, t: *Tti, dt: *Dom_Tree, eph: *Table(Value_Id, bool), full_unroll_trip_count: u32,
                       uce: *Unroll_Cost_Estimator, up: *Unroll_Prefs) -> (bool, u32) {
    if full_unroll_trip_count > up.full_unroll_max_count return false, 0;
    unrolled_size := uce_unrolled_loop_size(uce, up, full_unroll_trip_count);
    if unrolled_size < up.threshold return true, full_unroll_trip_count;
    ok, c := analyze_loop_unroll_cost(li, l, full_unroll_trip_count, dt, eph, t,
                                      cast,trunc(u32) (cast(u64) up.threshold * up.max_percent_threshold_boost / 100),
                                      up.max_iterations_count_to_analyze);
    if ok {
        boost := full_unroll_boosting_factor(c, up.max_percent_threshold_boost);
        boosted := cast,trunc(u32) (cast(u64) up.threshold * boost / 100);
        if c.unrolled_cost < boosted return true, full_unroll_trip_count;
    }
    return false, 0;
}

// shouldPartialUnroll
should_partial_unroll :: (loop_size: u32, trip_count: u32, uce: *Unroll_Cost_Estimator, up: *Unroll_Prefs) -> (bool, u32) {
    if trip_count == 0 return false, 0;
    if !up.partial return true, 0;
    count := up.count;
    if count == 0 count = trip_count;
    if up.partial_threshold != UNROLL_NO_THRESHOLD {
        if uce_unrolled_loop_size(uce, up, count) > up.partial_threshold {
            count = (max(up.partial_threshold, up.be_insns + 1) - up.be_insns) / (loop_size - up.be_insns);
        }
        if count > up.max_count count = up.max_count;
        while count != 0 && trip_count % count != 0 count -= 1;
        if up.allow_remainder && count <= 1 {
            count = up.default_unroll_runtime_count;
            while count != 0 && uce_unrolled_loop_size(uce, up, count) > up.partial_threshold count >>= 1;
        }
        if count < 2 count = 0;
    } else {
        count = trip_count;
    }
    if count > up.max_count count = up.max_count;
    return true, count;
}

// computeUnrollCount
compute_unroll_count :: (li: *Loop_Info, l: Loop_Id, t: *Tti, dt: *Dom_Tree, ac: *Assumption_Cache, eph: *Table(Value_Id, bool),
                         trip_count: u32, max_trip_count: u32, max_or_zero: bool, trip_multiple: u32,
                         uce: *Unroll_Cost_Estimator, up: *Unroll_Prefs, pp: *Peel_Prefs) {
    loop_size := uce_rolled_loop_size(uce);
    pinfo := unroll_pragma_info(li, l);
    if pp.peel_count {
        if lu_cl.unroll_count.given fatal("Cannot specify both explicit peel count and explicit unroll count");
        up.count = 1;
        up.runtime = false;
        return;
    }
    if pinfo.pragma_enable_unroll || pinfo.pragma_count > 0 {
        up.allow_expensive_trip_count = true;
        up.runtime = true;
    }
    has, factor := should_pragma_unroll(*pinfo, trip_multiple, trip_count, max_trip_count, uce, up);
    if has {
        up.count = factor;
        if pinfo.user_unroll_count || pinfo.pragma_count > 0 {
            up.allow_expensive_trip_count = true;
            up.force = true;
        }
        return;
    } else {
        if pinfo.explicit_unroll && trip_count != 0 {
            up.threshold = max(up.threshold, lu_u32(lu_cl.pragma_unroll_threshold));
            up.partial_threshold = max(up.partial_threshold, lu_u32(lu_cl.pragma_unroll_threshold));
        }
    }
    if trip_count {
        has, factor = should_full_unroll(li, l, t, dt, eph, trip_count, uce, up);
        if has { up.count = factor; return; }
    }
    if !trip_count && max_trip_count && (up.upper_bound || max_or_zero) && max_trip_count <= up.max_upper_bound {
        has, factor = should_full_unroll(li, l, t, dt, eph, max_trip_count, uce, up);
        if has { up.count = factor; return; }
    }
    compute_peel_count(li, l, loop_size, pp, trip_count, dt, t, ac, up.threshold);
    if pp.peel_count {
        up.runtime = false;
        up.count = 1;
        return;
    }
    if trip_count up.partial |= pinfo.explicit_unroll;
    has, factor = should_partial_unroll(loop_size, trip_count, uce, up);
    if has { up.count = factor; return; }

    if pinfo.pragma_runtime_unroll_disable return;
    if max_trip_count && !up.force && max_trip_count <= up.max_upper_bound return;
    if fn_has_profile_data(li.fn) {
        has_tc, ptc := li_loop_estimated_trip_count(li, l);
        if has_tc {
            if ptc < lu_u32(lu_cl.flat_loop_tripcount_threshold) return;
            else up.allow_expensive_trip_count = true;
        }
    }
    if !up.runtime return;
    up.count = up.default_unroll_runtime_count;
    while up.count != 0 && uce_unrolled_loop_size(uce, up) > up.partial_threshold up.count >>= 1;
    if !up.allow_remainder && up.count != 0 && (trip_multiple % up.count) != 0 {
        while up.count != 0 && trip_multiple % up.count != 0 up.count >>= 1;
    }
    if up.count > up.max_count up.count = up.max_count;
    if max_trip_count && up.count > max_trip_count up.count = max_trip_count;
    if up.count < 2 up.count = 0;
}
// Function::hasProfileData is fn_has_profile_data (pass_loop_idiom.jai)

// ---------------------------------------------------------------- tryToUnrollLoop

Loop_Unroll_Result :: enum u8 { UNMODIFIED; PARTIALLY_UNROLLED; FULLY_UNROLLED; }

// ScalarEvolution::getSmallConstantTripCount(L, ExitingBlock)
sc_small_constant_trip_count_exiting :: (l: Loop_Id, exiting: Value_Id) -> u32 {
    ec := sc_get_exit_count(l, exiting);
    return constant_trip_count(ec);
}
// ScalarEvolution::getSmallConstantTripMultiple(L, ExitingBlock)
sc_small_constant_trip_multiple_exiting :: (l: Loop_Id, exiting: Value_Id) -> u32 {
    return sc_get_small_constant_trip_multiple_ec(l, sc_get_exit_count(l, exiting));
}

Unroll_Ctx :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    li: *Loop_Info;
    ac: *Assumption_Cache;
    t: *Tti;
    aa: bool;                    // AAResults passed (loadCSE runs)
}

try_to_unroll_loop :: (c: *Unroll_Ctx, l: Loop_Id, preserve_lcssa: bool, opt_level: s64, only_full_unroll: bool, only_when_forced: bool,
                       forget_all_scev: bool, o: *Unroll_Options) -> Loop_Unroll_Result {
    li := c.li;
    tm := li_has_unroll_transformation(li, l);
    if tm & TM_DISABLE return .UNMODIFIED;
    parent := li_parent(li, l);
    if parent != NONE && li_has_unroll_and_jam_transformation(li, parent) == TM_FORCED_BY_USER &&
       li_has_unroll_transformation(li, l) != TM_FORCED_BY_USER return .UNMODIFIED;
    if li_has_unroll_and_jam_transformation(li, l) == TM_FORCED_BY_USER && li_has_unroll_transformation(li, l) != TM_FORCED_BY_USER
        return .UNMODIFIED;
    if !li_is_loop_simplify_form(li, l) return .UNMODIFIED;
    if only_when_forced && !(tm & TM_ENABLE) return .UNMODIFIED;

    opt_for_size := fn_has_opt_size(c.f);
    up := gather_unrolling_preferences(li, l, c.t, opt_level, o);
    pp := gather_peeling_preferences(li, l, c.t, o.has_peeling, o.peeling, o.has_profile_peeling, o.profile_peeling, true);

    if up.threshold == 0 && (!up.partial || up.partial_threshold == 0) && !opt_for_size return .UNMODIFIED;

    eph: Table(Value_Id, bool); eph.allocator = temp;
    collect_ephemeral_values(li, l, c.ac, *eph);

    sc_get_backedge_taken_count(l);   // const SCEV *BTC = SE.getBackedgeTakenCount(L) (UI is null: unused)
    uce := unroll_cost_estimator(li, l, c.t, *eph, up.be_insns, false);
    if !uce_can_unroll(*uce) return .UNMODIFIED;
    loop_size := uce_rolled_loop_size(*uce);
    if opt_for_size up.threshold = max(up.threshold, loop_size + 1);
    if uce.num_inline_candidates != 0 return .UNMODIFIED;

    trip_count: u32 = 0;
    trip_multiple: u32 = 1;
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    for eb: exiting {
        tc := sc_small_constant_trip_count_exiting(l, eb);
        if tc != 0 && (trip_count == 0 || tc < trip_count) { trip_count = tc; trip_multiple = tc; }
    }
    if trip_count == 0 {
        eb := li_loop_latch(li, l);
        if eb == NONE || !li_is_loop_exiting(li, l, eb) eb = li_exiting_block(li, l);
        if eb != NONE trip_multiple = sc_small_constant_trip_multiple_exiting(l, eb);
    }
    up.allow_remainder &= uce.convergence_allows_runtime;

    max_trip_count: u32 = 0;
    max_or_zero := false;
    if trip_count == 0 {
        max_trip_count = sc_get_small_constant_max_trip_count(l);
        max_or_zero = sc_is_backedge_taken_count_max_or_zero(l);
    }
    compute_unroll_count(li, l, c.t, c.dt, c.ac, *eph, trip_count, max_trip_count, max_or_zero, trip_multiple, *uce, *up, *pp);
    if up.count == 0 return .UNMODIFIED;

    up.runtime &= uce.convergence_allows_runtime;

    if pp.peel_count {
        vm: Value_Map; vmap_init(*vm);
        peel_loop(li, l, pp.peel_count, pp.peel_last, c.dt, c.ac, preserve_lcssa, *vm);
        blocks: [..] Value_Id; blocks.allocator = temp;
        for li_blocks(li, l) array_add(*blocks, it);
        simplify_loop_after_unroll(li, l, true, c.dt, c.ac, c.t, blocks, false);
        if pp.peel_profiled_iterations li_set_loop_already_unrolled(li, l);
        return .PARTIALLY_UNROLLED;
    }

    if only_full_unroll && ((trip_count == 0 && max_trip_count == 0) || up.count < trip_count || up.count < max_trip_count)
        return .UNMODIFIED;

    up.runtime &= trip_count == 0 && trip_multiple % up.count != 0;

    orig_loop_id := li_loop_id(li, l);
    pinfo := unroll_pragma_info(li, l);

    ulo: Unroll_Loop_Options;
    ulo.count = up.count;
    ulo.force = up.force;
    ulo.allow_expensive_trip_count = up.allow_expensive_trip_count;
    ulo.unroll_remainder = up.unroll_remainder;
    ulo.runtime = up.runtime;
    ulo.forget_all_scev = forget_all_scev;
    ulo.heart = li_loop_convergence_heart(li, l);
    ulo.scev_expansion_budget = up.scev_expansion_budget;
    ulo.runtime_unroll_multi_exit = up.runtime_unroll_multi_exit;
    ulo.add_additional_accumulators = up.add_additional_accumulators;
    remainder_loop: Loop_Id = NONE;
    result := unroll_loop(li, l, ulo, c.dt, c.ac, c.t, preserve_lcssa, *remainder_loop, c.aa);
    if result == .UNMODIFIED return .UNMODIFIED;

    if remainder_loop != NONE {
        has, id := make_followup_loop_id(orig_loop_id, .["llvm.loop.unroll.followup_all", "llvm.loop.unroll.followup_remainder"]);
        if has li_set_loop_id(li, remainder_loop, id);
    }
    if result != .FULLY_UNROLLED {
        has, id := make_followup_loop_id(orig_loop_id, .["llvm.loop.unroll.followup_all", "llvm.loop.unroll.followup_unrolled"]);
        if has {
            li_set_loop_id(li, l, id);
            return result;
        }
    }
    if result != .FULLY_UNROLLED && pinfo.explicit_unroll li_set_loop_already_unrolled(li, l);
    return result;
}

// ---------------------------------------------------------------- the passes

// LoopFullUnrollPass::run (loop-unroll-full)
loop_unroll_full_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    li := lar.li;
    if node.name != "loop-unroll-full" fatal("loop-unroll-full takes no parameters ('%')", node.name);
    parent := li_parent(li, l);
    old_loops: Table(Loop_Id, bool); old_loops.allocator = temp;
    if parent != NONE { for li_subloops(li, parent) table_set(*old_loops, it, true); }
    else { for li.top_level table_set(*old_loops, it, true); }

    c: Unroll_Ctx;
    c.f = lar.fn; c.dt = lar.dt; c.li = li; c.ac = lar.ac; c.t = tti_get(lar.fn); c.aa = false;
    o: Unroll_Options;
    o.has_partial = true; o.partial = false;
    o.has_runtime = true; o.runtime = false;
    o.has_upper_bound = true; o.upper_bound = false;
    o.has_peeling = true; o.peeling = true;
    o.has_profile_peeling = true; o.profile_peeling = false;
    se = lar.se;
    changed := try_to_unroll_loop(*c, l, true, 2, true, false, false, *o) != .UNMODIFIED;
    vh_release_all();
    if !changed return PRESERVE_ALL;

    is_current_valid := false;
    sib: [..] Loop_Id; sib.allocator = temp;
    src := ifx parent != NONE then li_subloops(li, parent) else li.top_level;
    for src {
        if it == l { is_current_valid = true; continue; }
        if table_contains(*old_loops, it) continue;
        array_add(*sib, it);
    }
    lpm_add_sibling_loops(u, li, sib);
    if !is_current_valid lpm_mark_loop_as_deleted(u, l);
    else if lu_cl.unroll_revisit_child_loops.v != 0 {
        ch: [..] Loop_Id; ch.allocator = temp;
        for li_subloops(li, l) array_add(*ch, it);
        lpm_add_child_loops(u, li, ch);
    }
    return loop_pass_preserved();
}

// LoopUnrollPass::run (loop-unroll<...>)
loop_unroll_run :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    opts := parse_loop_unroll_options(node.name);
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    s := get_scev(f);
    t := tti_get(f);
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    saved_se := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved_se;
    se = s;
    changed := false;
    // for (const auto &L : LI): L is a reference to the TopLevelLoops slot, which simplifyLoop may replace
    k := 0;
    while k < li.top_level.count {
        changed |= simplify_loop(li, li.top_level[k], dt, ac, null, false);
        se = s;
        changed |= form_lcssa_recursively(li, li.top_level[k], dt);
        se = s;
        k += 1;
    }
    w: Loop_Worklist; lwl_init(*w);
    append_loops_to_worklist_li(li, *w);
    c: Unroll_Ctx;
    c.f = f; c.dt = dt; c.li = li; c.ac = ac; c.t = t; c.aa = true;
    while !lwl_empty(*w) {
        l := lwl_pop(*w);
        o := opts.o;
        se = s;
        r := try_to_unroll_loop(*c, l, true, opts.opt_level, false, opts.only_when_forced, opts.forget_scev, *o);
        changed |= r != .UNMODIFIED;
    }
    vh_release_all();
    if !changed return PRESERVE_ALL;
    return loop_pass_preserved();
}

Loop_Unroll_Pass_Options :: struct {
    opt_level: s64 = 2;
    only_when_forced: bool;
    forget_scev: bool;
    o: Unroll_Options;
}
// parseLoopUnrollOptions (PassBuilder.cpp)
parse_loop_unroll_options :: (name: string) -> Loop_Unroll_Pass_Options {
    r: Loop_Unroll_Pass_Options;
    if name == "loop-unroll" return r;
    if !begins_with(name, "loop-unroll<") || name[name.count - 1] != #char ">" fatal("unknown pass name '%'", name);
    params := slice(name, 12, name.count - 13);
    while params.count {
        p := params;
        semi := find_index_from_left(params, #char ";");
        if semi >= 0 { p = slice(params, 0, semi); params = slice(params, semi + 1, params.count - semi - 1); }
        else params = "";
        if p == "O0" { r.opt_level = 0; continue; }
        if p == "O1" { r.opt_level = 1; continue; }
        if p == "O2" { r.opt_level = 2; continue; }
        if p == "O3" { r.opt_level = 3; continue; }
        if p == "Os" || p == "Oz" fatal("The optimization level \"%\" is no longer supported. Use O2 in conjunction with the % attribute instead.", p, ifx p == "Os" then "optsize" else "minsize");
        if begins_with(p, "full-unroll-max=") {
            v, ok := string_to_int(slice(p, 16, p.count - 16));
            if !ok fatal("invalid LoopUnrollPass parameter '%'", slice(p, 16, p.count - 16));
            r.o.has_full_unroll_max_count = true; r.o.full_unroll_max_count = cast,trunc(u32) v;
            continue;
        }
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "partial" { r.o.has_partial = true; r.o.partial = enable; }
        else if p == "peeling" { r.o.has_peeling = true; r.o.peeling = enable; }
        else if p == "profile-peeling" { r.o.has_profile_peeling = true; r.o.profile_peeling = enable; }
        else if p == "runtime" { r.o.has_runtime = true; r.o.runtime = enable; }
        else if p == "upperbound" { r.o.has_upper_bound = true; r.o.upper_bound = enable; }
        else fatal("invalid LoopUnrollPass parameter '%'", p);
    }
    return r;
}
