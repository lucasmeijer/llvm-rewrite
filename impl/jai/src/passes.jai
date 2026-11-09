// Pass infrastructure: textual pipelines, the pass registry, pass and analysis managers, opt's command line.
// Ported from llvm/lib/Passes/PassBuilder.cpp (parsePipelineText, parsePassPipeline, parseModulePass,
// parseFunctionPass, the auto-wrapping of a pipeline whose first pass isn't a module pass), llvm/include/llvm/IR/
// PassManager.h (PreservedAnalyses, ModuleToFunctionPassAdaptor: declarations are skipped, analyses invalidated per
// function), llvm/lib/Passes/StandardInstrumentations.cpp (OptNoneInstrumentation, OptPassGateInstrumentation) and
// llvm/lib/IR/OptBisect.cpp (-opt-bisect-limit).
//
// No OOP: a parsed pipeline is a flat array of Pass_Node rows (a tree through first_child/next), every pass is a
// Pass_Kind enum value, and running a pass is a `switch` in run_function_pass (see DESIGN.md "Pass infrastructure"
// and "How to add a pass").

// ---------------------------------------------------------------- analyses

Analysis_Kind :: enum u8 { DOMTREE; POSTDOMTREE; DEMANDED_BITS; ASSUMPTIONS; MEMORYSSA; LOOPS; CYCLES; SCEV; LVI; BPI; BFI; LAST_RUN_TRACKING; EPHEMERAL_VALUES; SHOULD_NOT_RUN; }
ANALYSIS_NAMES :: string.["domtree", "postdomtree", "demanded-bits", "assumptions", "memoryssa", "loops", "cycles", "scalar-evolution", "lazy-value-info", "branch-prob", "block-freq", "last-run-tracking", "ephemerals", "should-not-run-function-passes"];

// PreservedAnalyses. `cfg` = preserveSet<CFGAnalyses>().
Preserved :: struct {
    all: bool;
    cfg: bool;
    mask: u32;
    all_fn: bool;    // preserveSet<AllAnalysesOn<Function>>
    all_scc: bool;   // preserveSet<AllAnalysesOn<LazyCallGraph::SCC>>
    lcg: bool;       // preserve<LazyCallGraphAnalysis>
}
PRESERVE_ALL :: Preserved.{all = true};
PRESERVE_NONE :: Preserved.{};
preserve :: (pa: *Preserved, k: Analysis_Kind) { pa.mask |= (cast(u32) 1) << cast(u32) k; }
preserved_cfg :: () -> Preserved { pa: Preserved; pa.cfg = true; return pa; }
is_preserved :: (pa: Preserved, k: Analysis_Kind) -> bool { return pa.all || (pa.mask & ((cast(u32) 1) << cast(u32) k)) != 0; }

// Whether a cached result survives (Result::invalidate). DominatorTree/PostDominatorTree are CFG analyses.
analysis_survives :: (k: Analysis_Kind, pa: Preserved) -> bool {
    if is_preserved(pa, k) return true;
    if pa.all_fn return true;   // every Analysis_Kind is a function analysis
    if k == .DOMTREE || k == .POSTDOMTREE || k == .LOOPS || k == .CYCLES || k == .BPI || k == .BFI return pa.cfg;
    return false;
}

// FunctionAnalysisManager: the cached results of one function (heap-allocated, freed on invalidation).
Fn_Analyses :: struct {
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    db: *Demanded_Bits;
    ac: *Assumption_Cache;
    mssa: *Memory_SSA;
    li: *Loop_Info;
    ci: *Cycle_Info;
    se: *Scev_State;   // ScalarEvolution (scev_print.jai get_scev)
    lvi: *Lvi;         // LazyValueInfo (lazy_value_info.jai)
    bpi: *Bpi;         // BranchProbabilityInfo (branch_prob.jai)
    bfi: *Bfi;         // BlockFrequencyInfo (block_freq.jai)
    // LastRunTrackingAnalysis (LastRunTrackingAnalysis.cpp): its TrackedPasses map. InstCombine is the only pass that
    // uses it and calls update() without options, so the map is "empty" or "{InstCombine: no check}".
    lrt_instcombine: bool;
    eph: *Eph_Cache;   // EphemeralValuesAnalysis (inline_cost.jai)
    should_not_run: bool;   // ShouldNotRunFunctionPassesAnalysis (an empty result; default invalidate())
}
fam: Table(Value_Id, Fn_Analyses);

fam_entry :: (f: Value_Id) -> *Fn_Analyses {
    e := table_find_pointer(*fam, f);
    if e return e;
    blank: Fn_Analyses;
    table_set(*fam, f, blank);
    return table_find_pointer(*fam, f);
}

// AM.getResult<DominatorTreeAnalysis>(F)
get_domtree :: (f: Value_Id) -> *Dom_Tree {
    e := fam_entry(f);
    if !e.dt {
        e.dt = dt_new(false);
        dt_recalculate(e.dt, f);
    }
    return e.dt;
}
// AM.getResult<PostDominatorTreeAnalysis>(F)
get_postdomtree :: (f: Value_Id) -> *Dom_Tree {
    e := fam_entry(f);
    if !e.pdt {
        e.pdt = dt_new(true);
        dt_recalculate(e.pdt, f);
    }
    return e.pdt;
}
// AM.getCachedResult<...>(F)
cached_domtree :: (f: Value_Id) -> *Dom_Tree { e := table_find_pointer(*fam, f); if e return e.dt; return null; }
cached_postdomtree :: (f: Value_Id) -> *Dom_Tree { e := table_find_pointer(*fam, f); if e return e.pdt; return null; }
// AM.getResult<DemandedBitsAnalysis>(F) (DemandedBitsAnalysis::run also requests AssumptionAnalysis and DominatorTree)
get_demanded_bits :: (f: Value_Id) -> *Demanded_Bits {
    e := fam_entry(f);
    if !e.db {
        dt := get_domtree(f);
        e = fam_entry(f);
        ac := get_assumption_cache(f);
        e = fam_entry(f);
        e.db = New(Demanded_Bits);
        e.db.fn = f;
        e.db.dt = dt;
        e.db.ac = ac;
    }
    return e.db;
}

// AM.getResult<LoopAnalysis>(F): LoopAnalysis::run gets the DominatorTree and analyzes it
get_loop_info :: (f: Value_Id) -> *Loop_Info {
    e := fam_entry(f);
    if !e.li {
        dt := get_domtree(f);
        li := li_new(f);
        li_analyze(li, dt);
        e = fam_entry(f);
        e.li = li;
    }
    return e.li;
}
cached_loop_info :: (f: Value_Id) -> *Loop_Info { e := table_find_pointer(*fam, f); if e return e.li; return null; }
// AM.getResult<CycleAnalysis>(F)
get_cycle_info :: (f: Value_Id) -> *Cycle_Info {
    e := fam_entry(f);
    if !e.ci e.ci = ci_compute(f);
    return e.ci;
}
cached_cycle_info :: (f: Value_Id) -> *Cycle_Info { e := table_find_pointer(*fam, f); if e return e.ci; return null; }

// AM.getResult<AssumptionAnalysis>(F)
get_assumption_cache :: (f: Value_Id) -> *Assumption_Cache {
    e := fam_entry(f);
    if !e.ac {
        // AssumptionAnalysis::run asks for the function's TTI (which creates its subtarget)
        if tti_is_x86_triple(ir.triple) tti_get(f);
        e.ac = ac_build(f);
    }
    return e.ac;
}
// AM.getResult<LazyValueAnalysis>(F) (LazyValueAnalysis::run requests the AssumptionCache)
get_lvi :: (f: Value_Id) -> *Lvi {
    e := fam_entry(f);
    if !e.lvi {
        ac := get_assumption_cache(f);
        e = fam_entry(f);
        e.lvi = lvi_new(f, ac);
    }
    return e.lvi;
}
// AM.getResult<BranchProbabilityAnalysis>(F): LoopAnalysis, TargetLibraryAnalysis, DominatorTree, PostDominatorTree
get_bpi :: (f: Value_Id) -> *Bpi {
    e := fam_entry(f);
    if !e.bpi {
        li := get_loop_info(f);
        dt := get_domtree(f);
        pdt := get_postdomtree(f);
        b := bpi_calculate(f, li, dt, pdt);
        e = fam_entry(f);
        e.bpi = b;
    }
    return e.bpi;
}
cached_bpi :: (f: Value_Id) -> *Bpi { e := table_find_pointer(*fam, f); if e return e.bpi; return null; }
// AM.getResult<BlockFrequencyAnalysis>(F): BranchProbabilityAnalysis, LoopAnalysis
get_bfi :: (f: Value_Id) -> *Bfi {
    e := fam_entry(f);
    if !e.bfi {
        bpi := get_bpi(f);
        li := get_loop_info(f);
        b := bfi_calculate(f, bpi, li);
        e = fam_entry(f);
        e.bfi = b;
    }
    return e.bfi;
}
cached_bfi :: (f: Value_Id) -> *Bfi { e := table_find_pointer(*fam, f); if e return e.bfi; return null; }
cached_lvi :: (f: Value_Id) -> *Lvi { e := table_find_pointer(*fam, f); if e return e.lvi; return null; }
cached_assumption_cache :: (f: Value_Id) -> *Assumption_Cache { e := table_find_pointer(*fam, f); if e return e.ac; return null; }

dt_new :: (post: bool) -> *Dom_Tree {
    dt := New(Dom_Tree);
    dt.post = post;
    return dt;
}
dt_free :: (dt: *Dom_Tree) {
    array_free(dt.nodes); array_free(dt.roots); deinit(*dt.node_of); array_free(dt.node_dense);
    free(dt);
}

fam_invalidate :: (f: Value_Id, pa: Preserved) {
    e := table_find_pointer(*fam, f);
    if !e return;
    if e.dt && !analysis_survives(.DOMTREE, pa) { dt_free(e.dt); e.dt = null; }
    if e.pdt && !analysis_survives(.POSTDOMTREE, pa) { dt_free(e.pdt); e.pdt = null; }
    if e.db && !analysis_survives(.DEMANDED_BITS, pa) { db_free(e.db); e.db = null; }
    // AssumptionCache::invalidate never invalidates in LLVM; here it is rebuilt, except while a surviving LazyValueInfo
    // holds it (LVI keeps using the same, possibly stale, cache: its affected-value lists are not rescanned)
    if e.ac && !analysis_survives(.ASSUMPTIONS, pa) && !(e.lvi && analysis_survives(.LVI, pa)) { ac_free(e.ac); e.ac = null; }
    if e.li && !analysis_survives(.LOOPS, pa) { li_free(e.li); e.li = null; }
    if e.ci && !analysis_survives(.CYCLES, pa) { ci_free(e.ci); e.ci = null; }
    // a DemandedBits result points at the DominatorTree it was built with
    if e.db && !e.dt { db_free(e.db); e.db = null; }
    // ScalarEvolution::invalidate: not preserved, or DominatorTree / LoopInfo invalidated. (The AssumptionCache
    // never invalidates itself in LLVM; here it is rebuilt, so a surviving ScalarEvolution gets the new one.)
    if e.se && (!analysis_survives(.SCEV, pa) || !e.dt || !e.li) { scev_free(e.se); e.se = null; }
    if e.se && !e.ac { e.ac = ac_build(f); e.se.ac = e.ac; }
    // LazyValueInfo::invalidate: only when not preserved (it holds the never-invalidated AssumptionCache)
    if e.lvi && !analysis_survives(.LVI, pa) { lvi_free(e.lvi); e.lvi = null; }
    // LastRunTrackingInfo has the default invalidate(): kept only when preserved (or all preserved)
    if e.lrt_instcombine && !analysis_survives(.LAST_RUN_TRACKING, pa) e.lrt_instcombine = false;
    if e.lvi && !e.ac { e.ac = ac_build(f); e.lvi.ac = e.ac; }
    if e.bpi && !analysis_survives(.BPI, pa) { bpi_free(e.bpi); e.bpi = null; }
    if e.eph && !analysis_survives(.EPHEMERAL_VALUES, pa) { deinit(*e.eph.set); free(e.eph); e.eph = null; }
    if e.bfi && !analysis_survives(.BFI, pa) { bfi_free(e.bfi); e.bfi = null; }
    if e.should_not_run && !analysis_survives(.SHOULD_NOT_RUN, pa) e.should_not_run = false;
    // MemorySSAAnalysis::Result::invalidate: preserved, and AAManager and DominatorTreeAnalysis survive. AAManager
    // depends on BasicAA's AssumptionCache (never invalidated in LLVM: rebuilt here and re-pointed) and DT, and on
    // SCEVAA's ScalarEvolution.
    if e.mssa && (!analysis_survives(.MEMORYSSA, pa) || !e.dt || (e.mssa.aar.se && !e.se)) { mssa_free(e.mssa); e.mssa = null; }
    if e.mssa && e.mssa.aar.ac && !e.ac { e.ac = ac_build(f); }
    if e.mssa && e.mssa.aar.ac e.mssa.aar.ac = e.ac;
}
fam_require :: (f: Value_Id, k: Analysis_Kind) {
    if k == {
        case .DOMTREE; get_domtree(f);
        case .POSTDOMTREE; get_postdomtree(f);
        case .DEMANDED_BITS; get_demanded_bits(f);
        case .ASSUMPTIONS; get_assumption_cache(f);
        case .MEMORYSSA; get_memoryssa(f);
        case .LOOPS; get_loop_info(f);
        case .CYCLES; get_cycle_info(f);
        case .SCEV; get_scev(f);
        case .LVI; get_lvi(f);
        case .BPI; get_bpi(f);
        case .BFI; get_bfi(f);
        case .LAST_RUN_TRACKING;   // an empty LastRunTrackingInfo: nothing to compute
        case .EPHEMERAL_VALUES; get_eph_cache(f);
        case .SHOULD_NOT_RUN; fam_entry(f).should_not_run = true;
    }
}
fam_invalidate_one :: (f: Value_Id, k: Analysis_Kind) {
    pa := PRESERVE_ALL; pa.all = false;
    pa.mask = ~((cast(u32) 1) << cast(u32) k);
    fam_invalidate(f, pa);
}

// ---------------------------------------------------------------- the registry

Pass_Level :: enum u8 { MODULE; FUNCTION; LOOP; CGSCC; }

Pass_Kind :: enum u8 {
    // structure
    MODULE_PM; FUNCTION_ADAPTOR; LOOP_ADAPTOR; LOOP_PM;
    // analysis utilities (required: they run on optnone functions and don't count for -opt-bisect-limit)
    REQUIRE; INVALIDATE; PRINT_DOMTREE; PRINT_POSTDOMTREE; PRINT_DEMANDED_BITS; NO_OP_FUNCTION; NO_OP_MODULE;
    // transforms
    DCE; ADCE; BDCE; BREAK_CRIT_EDGES; MEM2REG; INSTSIMPLIFY; SROA; INSTCOMBINE;
    // alias analysis (aa.jai)
    AA_EVAL; REQUIRE_GLOBALS_AA; PRINT_MEMORYSSA; PRINT_MEMORYSSA_NO_OPT; PRINT_MEMORYSSA_WALKER; VERIFY_MEMORYSSA;
    // loops (loop_info.jai, cycle_info.jai)
    PRINT_LOOPS; PRINT_CYCLES; LOOP_SIMPLIFY; LCSSA;
    // loop passes (loop_pm.jai)
    NO_OP_LOOP; LOOP_ROTATE; LICM; LNICM; INDVARS; LOOP_DELETION; LOOP_INSTSIMPLIFY; LOOP_SIMPLIFYCFG; LOOP_IDIOM;
    // ScalarEvolution (scev_print.jai)
    PRINT_SCEV; VERIFY_SCEV; PRINT_LOOPNEST; PRINT_IV_USERS; REQUIRE_IV_USERS; PRINT_ACCESS_INFO; LOOP_LOAD_ELIM; LOOP_DISTRIBUTE;
    // TargetTransformInfo (tti.jai)
    PRINT_COST_MODEL;
    // SimplifyCFG (pass_simplifycfg*.jai)
    SIMPLIFYCFG;
    // InferFunctionAttrs (pass_inferattrs.jai)
    INFERATTRS;
    // Debugify (pass_debugify.jai)
    DEBUGIFY; CHECK_DEBUGIFY; REDUNDANT_DBG_INST_ELIM;
    // GVN (pass_gvn.jai)
    GVN;
    // DeadStoreElimination (pass_dse.jai), MemCpyOpt (pass_memcpyopt.jai)
    DSE; MEMCPYOPT;
    // LazyValueInfo (lazy_value_info.jai), CorrelatedValuePropagation (pass_cvp.jai), JumpThreading (pass_jump_threading.jai)
    PRINT_LVI; CVP; JUMP_THREADING;
    // BranchProbabilityInfo (branch_prob.jai), BlockFrequencyInfo (block_freq.jai)
    PRINT_BPI; PRINT_BFI;
    // Reassociate (pass_reassociate.jai)
    REASSOCIATE;
    // ConstraintElimination (pass_constraint_elimination.jai)
    CONSTRAINT_ELIMINATION;
    // AggressiveInstCombine (pass_aggressive_instcombine.jai, aic_trunc.jai)
    AGGRESSIVE_INSTCOMBINE;
    // VectorCombine (pass_vector_combine.jai)
    VECTOR_COMBINE;
    // SLPVectorizer (slp_*.jai)
    SLP_VECTORIZER;
    // LoopUnroll (pass_loop_unroll.jai)
    LOOP_UNROLL; LOOP_UNROLL_FULL;
    // LoopVectorize (lv_pass.jai)
    LOOP_VECTORIZE;
    // SimpleLoopUnswitch (pass_simple_loop_unswitch.jai)
    SIMPLE_LOOP_UNSWITCH;
    // CGSCC pass manager (cgscc_pm.jai), LazyCallGraph (lazy_call_graph.jai)
    CGSCC_ADAPTOR; CGSCC_PM; CGSCC_FN_ADAPTOR; DEVIRT; NO_OP_CGSCC; PRINT_LCG; REQUIRE_LCG; INVALIDATE_LCG;
    // FunctionAttrs (pass_function_attrs.jai)
    FUNCTION_ATTRS; RPO_FUNCTION_ATTRS; NORECURSE_LTO_INFERENCE;
    // Inliner (pass_inliner.jai), AlwaysInliner (pass_always_inliner.jai)
    INLINE; ALWAYS_INLINE; MODULE_INLINE; INLINER_WRAPPER;
    // ProfileSummaryAnalysis (require<profile-summary>)
    REQUIRE_PROFILE_SUMMARY;
    // IPO: GlobalOpt, GlobalDCE, ConstantMerge, StripDeadPrototypes, EliminateAvailableExternally, Internalize,
    // DeadArgumentElimination, ArgumentPromotion (pass_global_opt.jai, pass_global_dce.jai, ...)
    GLOBAL_OPT; GLOBAL_DCE; CONSTANT_MERGE; STRIP_DEAD_PROTOTYPES; ELIM_AVAIL_EXTERN; INTERNALIZE; DEAD_ARG_ELIM; ARG_PROMOTION; ASSIGN_GUID;
    // L1.scalar-misc (pass_lower_expect.jai, ...; options in scalar_misc_cl.jai)
    LOWER_EXPECT; LOWER_CONSTANT_INTRINSICS; INFER_ALIGNMENT; DIV_REM_PAIRS; FLOAT2INT; SINK; TAILCALLELIM; MLDST_MOTION; SPECULATIVE_EXECUTION; CALLSITE_SPLITTING;
    // the rest of the -O2 pipeline's small passes (pass_coroutines.jai, pass_openmp_opt.jai, pass_remark_only.jai, pass_misc_module.jai, ...)
    CORO_EARLY; CORO_CLEANUP; CORO_ELIDE; CORO_SPLIT; CORO_ANNOTATION_ELIDE; OPENMP_OPT; OPENMP_OPT_CGSCC;
    ANNOTATION2METADATA; ANNOTATION_REMARKS; FORCEATTRS; MEMPROF_REMOVE_INFO; RECOMPUTE_GLOBALSAA; LOWER_COMMENT_STRING;
    INJECT_TLI_MAPPINGS; EE_INSTRUMENT; REL_LOOKUP_TABLE_CONVERTER; CG_PROFILE; ALLOC_TOKEN;
}

Pass_Info :: struct {
    name: string;
    level: Pass_Level;
    kind: Pass_Kind;
    required: bool;
    analysis: Analysis_Kind;   // REQUIRE / INVALIDATE
}

// Add a row here (and a case in run_function_pass) to register a pass. Names are the PassRegistry.def names.
PASS_TABLE :: Pass_Info.[
    .{"no-op-module", .MODULE, .NO_OP_MODULE, false, .DOMTREE},
    .{"no-op-function", .FUNCTION, .NO_OP_FUNCTION, false, .DOMTREE},
    .{"dce", .FUNCTION, .DCE, false, .DOMTREE},
    .{"adce", .FUNCTION, .ADCE, false, .DOMTREE},
    .{"bdce", .FUNCTION, .BDCE, false, .DOMTREE},
    .{"reassociate", .FUNCTION, .REASSOCIATE, false, .DOMTREE},
    .{"constraint-elimination", .FUNCTION, .CONSTRAINT_ELIMINATION, false, .DOMTREE},
    .{"aggressive-instcombine", .FUNCTION, .AGGRESSIVE_INSTCOMBINE, false, .DOMTREE},
    .{"vector-combine", .FUNCTION, .VECTOR_COMBINE, false, .DOMTREE},
    .{"slp-vectorizer", .FUNCTION, .SLP_VECTORIZER, false, .DOMTREE},
    .{"break-crit-edges", .FUNCTION, .BREAK_CRIT_EDGES, false, .DOMTREE},
    .{"mem2reg", .FUNCTION, .MEM2REG, false, .DOMTREE},
    .{"sroa", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<preserve-cfg>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<modify-cfg>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<aggregate-to-vector>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<preserve-cfg;aggregate-to-vector>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<modify-cfg;aggregate-to-vector>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<aggregate-to-vector;preserve-cfg>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"sroa<aggregate-to-vector;modify-cfg>", .FUNCTION, .SROA, false, .DOMTREE},
    .{"debugify", .MODULE, .DEBUGIFY, false, .DOMTREE},
    .{"check-debugify", .MODULE, .CHECK_DEBUGIFY, false, .DOMTREE},
    .{"redundant-dbg-inst-elim", .FUNCTION, .REDUNDANT_DBG_INST_ELIM, false, .DOMTREE},
    .{"require<verify>", .MODULE, .NO_OP_MODULE, true, .DOMTREE},   // the verifier finds nothing on valid IR
    .{"instsimplify", .FUNCTION, .INSTSIMPLIFY, false, .DOMTREE},
    .{"gvn", .FUNCTION, .GVN, false, .DOMTREE},   // also gvn<...> (lookup_pass)
    .{"dse", .FUNCTION, .DSE, false, .DOMTREE},
    .{"memcpyopt", .FUNCTION, .MEMCPYOPT, false, .DOMTREE},
    .{"instcombine", .FUNCTION, .INSTCOMBINE, false, .DOMTREE},
    .{"simplifycfg", .FUNCTION, .SIMPLIFYCFG, false, .DOMTREE},   // also simplifycfg<...> (lookup_pass)   // also instcombine<...> (lookup_pass)
    .{"verify", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},   // VerifierPass (module & function): nothing to report on valid IR
    .{"require<assumptions>", .FUNCTION, .REQUIRE, true, .ASSUMPTIONS},
    .{"invalidate<assumptions>", .FUNCTION, .INVALIDATE, true, .ASSUMPTIONS},
    .{"print<domtree>", .FUNCTION, .PRINT_DOMTREE, true, .DOMTREE},
    .{"print<postdomtree>", .FUNCTION, .PRINT_POSTDOMTREE, true, .DOMTREE},
    .{"print<demanded-bits>", .FUNCTION, .PRINT_DEMANDED_BITS, true, .DOMTREE},
    .{"print<cost-model>", .FUNCTION, .PRINT_COST_MODEL, true, .DOMTREE},
    .{"require<domtree>", .FUNCTION, .REQUIRE, true, .DOMTREE},
    .{"require<last-run-tracking>", .FUNCTION, .REQUIRE, true, .LAST_RUN_TRACKING},
    .{"invalidate<last-run-tracking>", .FUNCTION, .INVALIDATE, true, .LAST_RUN_TRACKING},
    .{"require<postdomtree>", .FUNCTION, .REQUIRE, true, .POSTDOMTREE},
    .{"require<demanded-bits>", .FUNCTION, .REQUIRE, true, .DEMANDED_BITS},
    .{"invalidate<domtree>", .FUNCTION, .INVALIDATE, true, .DOMTREE},
    .{"invalidate<postdomtree>", .FUNCTION, .INVALIDATE, true, .POSTDOMTREE},
    .{"invalidate<demanded-bits>", .FUNCTION, .INVALIDATE, true, .DEMANDED_BITS},
    .{"aa-eval", .FUNCTION, .AA_EVAL, false, .DOMTREE},
    .{"require<globals-aa>", .MODULE, .REQUIRE_GLOBALS_AA, true, .DOMTREE},
    .{"require<profile-summary>", .MODULE, .REQUIRE_PROFILE_SUMMARY, true, .DOMTREE},
    .{"inferattrs", .MODULE, .INFERATTRS, false, .DOMTREE},
    .{"print<memoryssa>", .FUNCTION, .PRINT_MEMORYSSA, true, .DOMTREE},
    .{"print<memoryssa><no-ensure-optimized-uses>", .FUNCTION, .PRINT_MEMORYSSA_NO_OPT, true, .DOMTREE},
    .{"print<memoryssa-walker>", .FUNCTION, .PRINT_MEMORYSSA_WALKER, true, .DOMTREE},
    .{"verify<memoryssa>", .FUNCTION, .VERIFY_MEMORYSSA, true, .MEMORYSSA},
    .{"require<memoryssa>", .FUNCTION, .REQUIRE, true, .MEMORYSSA},
    .{"invalidate<memoryssa>", .FUNCTION, .INVALIDATE, true, .MEMORYSSA},
    .{"print<loops>", .FUNCTION, .PRINT_LOOPS, true, .LOOPS},
    .{"loop-simplify", .FUNCTION, .LOOP_SIMPLIFY, false, .DOMTREE},
    .{"lcssa", .FUNCTION, .LCSSA, false, .DOMTREE},
    .{"no-op-loop", .LOOP, .NO_OP_LOOP, false, .DOMTREE},
    .{"loop-rotate", .LOOP, .LOOP_ROTATE, false, .DOMTREE},
    .{"licm", .LOOP, .LICM, false, .DOMTREE},
    .{"lnicm", .LOOP, .LNICM, false, .DOMTREE},   // a LoopNest pass
    .{"indvars", .LOOP, .INDVARS, false, .DOMTREE},
    .{"loop-deletion", .LOOP, .LOOP_DELETION, false, .DOMTREE},
    .{"loop-instsimplify", .LOOP, .LOOP_INSTSIMPLIFY, false, .DOMTREE},
    .{"loop-simplifycfg", .LOOP, .LOOP_SIMPLIFYCFG, false, .DOMTREE},
    .{"loop-idiom", .LOOP, .LOOP_IDIOM, false, .DOMTREE},
    .{"loop-unroll", .FUNCTION, .LOOP_UNROLL, false, .DOMTREE},   // also loop-unroll<...> (lookup_pass)
    .{"loop-unroll-full", .LOOP, .LOOP_UNROLL_FULL, false, .DOMTREE},
    .{"loop-vectorize", .FUNCTION, .LOOP_VECTORIZE, false, .DOMTREE},   // also loop-vectorize<...> (lookup_pass)
    .{"simple-loop-unswitch", .LOOP, .SIMPLE_LOOP_UNSWITCH, false, .DOMTREE},   // also simple-loop-unswitch<...>
    .{"print<cycles>", .FUNCTION, .PRINT_CYCLES, true, .CYCLES},
    .{"require<loops>", .FUNCTION, .REQUIRE, true, .LOOPS},
    .{"require<cycles>", .FUNCTION, .REQUIRE, true, .CYCLES},
    .{"invalidate<loops>", .FUNCTION, .INVALIDATE, true, .LOOPS},
    .{"invalidate<cycles>", .FUNCTION, .INVALIDATE, true, .CYCLES},
    // LoopVerifierPass / CycleInfoVerifierPass: assertions only in a release build (getResult and nothing else)
    .{"verify<loops>", .FUNCTION, .REQUIRE, true, .LOOPS},
    // TargetIRAnalysis / TargetLibraryAnalysis: no cached state here
    .{"require<target-ir>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    // AAManager: BasicAA requests the AssumptionCache, DominatorTree and TLI (no other state)
    .{"require<aa>", .FUNCTION, .REQUIRE, true, .DOMTREE},
    // OptimizationRemarkEmitterAnalysis: computes BlockFrequencyInfo only when remarks are enabled
    .{"require<opt-remark-emit>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    .{"require<target-lib-info>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    // PhiValuesAnalysis: no pass or analysis we have consumes it (BasicAA and MemDep stopped using it)
    .{"require<phi-values>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    // MemoryDependenceAnalysis: a lazily filled cache; no pass we have consumes a cached result (GVN requests its own)
    .{"require<memdep>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    .{"verify<cycles>", .FUNCTION, .REQUIRE, true, .CYCLES},
    .{"print<scalar-evolution>", .FUNCTION, .PRINT_SCEV, true, .SCEV},
    .{"print<loopnest>", .LOOP, .PRINT_LOOPNEST, true, .SCEV},
    .{"print<iv-users>", .LOOP, .PRINT_IV_USERS, true, .SCEV},
    .{"require<iv-users>", .LOOP, .REQUIRE_IV_USERS, true, .SCEV},
    .{"print<access-info>", .FUNCTION, .PRINT_ACCESS_INFO, true, .SCEV},
    .{"loop-load-elim", .FUNCTION, .LOOP_LOAD_ELIM, false, .SCEV},
    .{"loop-distribute", .FUNCTION, .LOOP_DISTRIBUTE, false, .SCEV},
    .{"verify<scalar-evolution>", .FUNCTION, .VERIFY_SCEV, true, .SCEV},
    .{"require<scalar-evolution>", .FUNCTION, .REQUIRE, true, .SCEV},
    .{"invalidate<scalar-evolution>", .FUNCTION, .INVALIDATE, true, .SCEV},
    .{"print<lazy-value-info>", .FUNCTION, .PRINT_LVI, true, .LVI},
    .{"require<lazy-value-info>", .FUNCTION, .REQUIRE, true, .LVI},
    .{"invalidate<lazy-value-info>", .FUNCTION, .INVALIDATE, true, .LVI},
    .{"correlated-propagation", .FUNCTION, .CVP, false, .DOMTREE},
    .{"jump-threading", .FUNCTION, .JUMP_THREADING, false, .DOMTREE},
    .{"print<branch-prob>", .FUNCTION, .PRINT_BPI, true, .BPI},
    .{"require<branch-prob>", .FUNCTION, .REQUIRE, true, .BPI},
    .{"invalidate<branch-prob>", .FUNCTION, .INVALIDATE, true, .BPI},
    .{"print<block-freq>", .FUNCTION, .PRINT_BFI, true, .BFI},
    .{"require<block-freq>", .FUNCTION, .REQUIRE, true, .BFI},
    .{"invalidate<block-freq>", .FUNCTION, .INVALIDATE, true, .BFI},
    .{"no-op-cgscc", .CGSCC, .NO_OP_CGSCC, false, .DOMTREE},
    .{"print-lcg", .MODULE, .PRINT_LCG, true, .DOMTREE},
    .{"require<lcg>", .MODULE, .REQUIRE_LCG, true, .DOMTREE},
    .{"invalidate<lcg>", .MODULE, .INVALIDATE_LCG, true, .DOMTREE},
    .{"function-attrs", .CGSCC, .FUNCTION_ATTRS, false, .DOMTREE},   // also function-attrs<skip-non-recursive-function-attrs>
    .{"rpo-function-attrs", .MODULE, .RPO_FUNCTION_ATTRS, false, .DOMTREE},
    .{"norecurse-lto-inference", .MODULE, .NORECURSE_LTO_INFERENCE, false, .DOMTREE},
    .{"inline", .CGSCC, .INLINE, false, .DOMTREE},   // also inline<only-mandatory>
    .{"always-inline", .MODULE, .ALWAYS_INLINE, false, .DOMTREE},
    .{"module-inline", .MODULE, .MODULE_INLINE, false, .DOMTREE},
    .{"inliner-wrapper", .MODULE, .INLINER_WRAPPER, false, .DOMTREE},
    .{"globalopt", .MODULE, .GLOBAL_OPT, false, .DOMTREE},
    .{"globaldce", .MODULE, .GLOBAL_DCE, false, .DOMTREE},   // also globaldce<vfe-linkage-unit-visibility>
    .{"constmerge", .MODULE, .CONSTANT_MERGE, false, .DOMTREE},
    .{"strip-dead-prototypes", .MODULE, .STRIP_DEAD_PROTOTYPES, false, .DOMTREE},
    .{"elim-avail-extern", .MODULE, .ELIM_AVAIL_EXTERN, false, .DOMTREE},
    .{"internalize", .MODULE, .INTERNALIZE, false, .DOMTREE},   // also internalize<preserve-gv=...>
    .{"deadargelim", .MODULE, .DEAD_ARG_ELIM, false, .DOMTREE},
    .{"argpromotion", .CGSCC, .ARG_PROMOTION, false, .DOMTREE},
    .{"assign-guid", .MODULE, .ASSIGN_GUID, false, .DOMTREE},
    // L1.scalar-misc
    .{"lower-expect", .FUNCTION, .LOWER_EXPECT, false, .DOMTREE},
    .{"lower-constant-intrinsics", .FUNCTION, .LOWER_CONSTANT_INTRINSICS, false, .DOMTREE},
    .{"infer-alignment", .FUNCTION, .INFER_ALIGNMENT, false, .DOMTREE},
    .{"div-rem-pairs", .FUNCTION, .DIV_REM_PAIRS, false, .DOMTREE},
    .{"float2int", .FUNCTION, .FLOAT2INT, false, .DOMTREE},
    .{"sink", .FUNCTION, .SINK, false, .DOMTREE},
    .{"tailcallelim", .FUNCTION, .TAILCALLELIM, false, .DOMTREE},
    .{"mldst-motion", .FUNCTION, .MLDST_MOTION, false, .DOMTREE},   // also mldst-motion<...>
    .{"speculative-execution", .FUNCTION, .SPECULATIVE_EXECUTION, false, .DOMTREE},   // also speculative-execution<...>
    .{"callsite-splitting", .FUNCTION, .CALLSITE_SPLITTING, false, .DOMTREE},
    .{"coro-early", .MODULE, .CORO_EARLY, true, .DOMTREE},
    .{"coro-cleanup", .MODULE, .CORO_CLEANUP, true, .DOMTREE},
    .{"coro-elide", .FUNCTION, .CORO_ELIDE, true, .DOMTREE},
    .{"coro-split", .CGSCC, .CORO_SPLIT, true, .DOMTREE},   // also coro-split<reuse-storage>
    .{"coro-annotation-elide", .CGSCC, .CORO_ANNOTATION_ELIDE, false, .DOMTREE},
    .{"openmp-opt", .MODULE, .OPENMP_OPT, false, .DOMTREE},
    .{"openmp-opt-cgscc", .CGSCC, .OPENMP_OPT_CGSCC, false, .DOMTREE},
    .{"annotation2metadata", .MODULE, .ANNOTATION2METADATA, false, .DOMTREE},
    .{"annotation-remarks", .FUNCTION, .ANNOTATION_REMARKS, true, .DOMTREE},
    .{"forceattrs", .MODULE, .FORCEATTRS, false, .DOMTREE},
    .{"memprof-remove-attributes", .MODULE, .MEMPROF_REMOVE_INFO, false, .DOMTREE},
    .{"recompute-globalsaa", .MODULE, .RECOMPUTE_GLOBALSAA, false, .DOMTREE},
    .{"lower-comment-string", .MODULE, .LOWER_COMMENT_STRING, true, .DOMTREE},
    .{"inject-tli-mappings", .FUNCTION, .INJECT_TLI_MAPPINGS, false, .DOMTREE},
    .{"rel-lookup-table-converter", .MODULE, .REL_LOOKUP_TABLE_CONVERTER, false, .DOMTREE},
    .{"cg-profile", .MODULE, .CG_PROFILE, false, .DOMTREE},   // also cg-profile<in-lto-post-link>
    .{"alloc-token", .MODULE, .ALLOC_TOKEN, true, .DOMTREE},
    .{"ee-instrument", .FUNCTION, .EE_INSTRUMENT, true, .DOMTREE},   // also ee-instrument<...>
    // AAManager keeps no state here (aa_results_for builds the result per query)
    .{"invalidate<aa>", .FUNCTION, .NO_OP_FUNCTION, true, .DOMTREE},
    .{"require<should-not-run-function-passes>", .FUNCTION, .REQUIRE, true, .SHOULD_NOT_RUN},
    .{"invalidate<should-not-run-function-passes>", .FUNCTION, .INVALIDATE, true, .SHOULD_NOT_RUN},
    // ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch> parsed from text is empty (its printPipeline drops the
    // inner simple-loop-unswitch that -O2 puts into it), so this textual form is a no-op (a required pass)
    .{"extra-simple-loop-unswitch-passes", .LOOP, .NO_OP_LOOP, true, .DOMTREE},
];

// Passes LLVM has that we don't: recognised so that the error says "not implemented" rather than "unknown".
pass_table: [..] Pass_Info;   // PASS_TABLE copied into memory, so that pointers to rows stay valid
lookup_pass :: (name: string) -> *Pass_Info {
    if pass_table.count == 0 for PASS_TABLE array_add(*pass_table, it);
    for * pass_table if it.name == name return it;
    if begins_with(name, "instcombine<") return lookup_pass("instcombine");
    if begins_with(name, "gvn<") && name[name.count - 1] == #char ">" return lookup_pass("gvn");
    if begins_with(name, "simplifycfg<") && name[name.count - 1] == #char ">" return lookup_pass("simplifycfg");
    // passes whose parameters are parsed by the pass itself (LOOP_PASS_WITH_PARAMS)
    if begins_with(name, "loop-rotate<") && name[name.count - 1] == #char ">" return lookup_pass("loop-rotate");
    if begins_with(name, "licm<") && name[name.count - 1] == #char ">" return lookup_pass("licm");
    if begins_with(name, "print<access-info><") && name[name.count - 1] == #char ">" return lookup_pass("print<access-info>");
    if begins_with(name, "lnicm<") && name[name.count - 1] == #char ">" return lookup_pass("lnicm");
    if begins_with(name, "loop-unroll<") && name[name.count - 1] == #char ">" return lookup_pass("loop-unroll");
    if begins_with(name, "loop-vectorize<") && name[name.count - 1] == #char ">" return lookup_pass("loop-vectorize");
    if begins_with(name, "simple-loop-unswitch<") && name[name.count - 1] == #char ">" return lookup_pass("simple-loop-unswitch");
    if begins_with(name, "function-attrs<") && name[name.count - 1] == #char ">" return lookup_pass("function-attrs");
    if begins_with(name, "inline<") && name[name.count - 1] == #char ">" return lookup_pass("inline");
    if begins_with(name, "globaldce<") && name[name.count - 1] == #char ">" return lookup_pass("globaldce");
    if begins_with(name, "internalize<") && name[name.count - 1] == #char ">" return lookup_pass("internalize");
    if begins_with(name, "mldst-motion<") && name[name.count - 1] == #char ">" return lookup_pass("mldst-motion");
    if begins_with(name, "speculative-execution<") && name[name.count - 1] == #char ">" return lookup_pass("speculative-execution");
    if name == "coro-split<reuse-storage>" || name == "coro-split<>" return lookup_pass("coro-split");
    if name == "cg-profile<in-lto-post-link>" || name == "cg-profile<>" return lookup_pass("cg-profile");
    if begins_with(name, "ee-instrument<") && name[name.count - 1] == #char ">" return lookup_pass("ee-instrument");
    return null;
}

// ---------------------------------------------------------------- pipeline text

Pipeline_Element :: struct {
    name: string;
    first_child: s32 = -1;
    next: s32 = -1;
    has_children: bool;   // `name(...)` even if empty
}

Pass_Node :: struct {
    kind: Pass_Kind;
    info: *Pass_Info;      // null for MODULE_PM / FUNCTION_ADAPTOR
    name: string;
    first_child: s32 = -1;
    next: s32 = -1;
    use_mssa: bool;        // LOOP_ADAPTOR: loop-mssa(...)
    count: s32;            // DEVIRT: devirt<N>
    eager_inv: bool;       // CGSCC_FN_ADAPTOR / FUNCTION_ADAPTOR: function<eager-inv>(...)
    no_rerun: bool;        // CGSCC_FN_ADAPTOR: function<no-rerun>(...) skips functions with a cached ShouldNotRunFunctionPassesAnalysis
}

pipeline: struct {
    elems: [..] Pipeline_Element;
    nodes: [..] Pass_Node;
};

pipeline_error :: (fmt: string, args: .. Any) {
    msg := tprint(fmt, ..args);
    fatal("invalid pass pipeline: %", msg);
}

// PassBuilder::parsePipelineText: elements separated by ',', nesting with '(' ')'. Returns the first element of
// the top-level list.
parse_pipeline_text :: (text: string) -> s32 {
    Frame :: struct { first: s32; last: s32; parent: s32; }
    stack: [..] Frame; stack.allocator = temp;
    array_add(*stack, .{-1, -1, -1});
    pos := 0;
    append_elem :: (stack: *[..] Frame, name: string) -> s32 {
        e: Pipeline_Element; e.name = name;
        id := cast(s32) pipeline.elems.count;
        array_add(*pipeline.elems, e);
        top := *stack.*[stack.count - 1];
        if top.last >= 0 pipeline.elems[top.last].next = id; else top.first = id;
        top.last = id;
        return id;
    }
    while true {
        // find_first_of(",()")
        end := pos;
        while end < text.count && text[end] != #char "," && text[end] != #char "(" && text[end] != #char ")" end += 1;
        name := slice(text, pos, end - pos);
        id := append_elem(*stack, name);
        if end == text.count {
            pos = end;
            break;
        }
        c := text[end];
        pos = end + 1;
        if c == #char "(" {
            pipeline.elems[id].has_children = true;
            array_add(*stack, .{-1, -1, id});
            continue;
        }
        if c == #char "," continue;
        // ')': close as many levels as there are ')'
        while true {
            if stack.count <= 1 pipeline_error("unbalanced ')' in '%'", text);
            fr := pop(*stack);
            pipeline.elems[fr.parent].first_child = fr.first;
            if pos < text.count && text[pos] == #char ")" { pos += 1; continue; }
            break;
        }
        if pos == text.count break;
        if text[pos] != #char "," pipeline_error("expected ',' after ')' in '%'", text);
        pos += 1;
    }
    if stack.count != 1 pipeline_error("unbalanced '(' in '%'", text);
    for pipeline.elems if it.name.count == 0 && !it.has_children pipeline_error("empty pass name in '%'", text);
    return stack[0].first;
}

is_module_pass_name :: (name: string) -> bool {
    if name == "module" return true;
    if name == "function" || begins_with(name, "function<") return true;   // still a module-level element
    if name == "cgscc" return true;
    if name == "loop" || name == "loop-mssa" return false;
    p := lookup_pass(name);
    return p != null && p.level == .MODULE;
}

// parseFunctionPipelineName: function, function<eager-inv;no-rerun> (any order) -> (ok, eager-inv, no-rerun)
parse_function_pipeline_name :: (name_in: string) -> (bool, bool, bool) {
    if !begins_with(name_in, "function") return false, false, false;
    name := slice(name_in, 8, name_in.count - 8);
    if name.count == 0 return true, false, false;
    if name[0] != #char "<" || name[name.count - 1] != #char ">" return false, false, false;
    name = slice(name, 1, name.count - 2);
    eager, no_rerun := false;
    while name.count {
        k := find_index_from_left(name, #char ";");
        front := ifx k >= 0 then slice(name, 0, k) else name;
        name = ifx k >= 0 then slice(name, k + 1, name.count - k - 1) else "";
        if front == "eager-inv" eager = true;
        else if front == "no-rerun" no_rerun = true;
        else return false, false, false;
    }
    return true, eager, no_rerun;
}

// parseDevirtPassName: devirt<N>, N >= 0
parse_devirt_pass_name :: (name: string) -> (bool, s32) {
    if !begins_with(name, "devirt<") || name[name.count - 1] != #char ">" return false, 0;
    inner := slice(name, 7, name.count - 8);
    if inner.count == 0 return false, 0;
    v, ok, rest := string_to_int(inner);
    if !ok || rest.count != 0 || v < 0 return false, 0;
    return true, cast(s32) v;
}

// isCGSCCPassName
is_cgscc_pass_name :: (name: string) -> bool {
    if name == "cgscc" || name == "function" || begins_with(name, "function<") return true;
    ok, _ := parse_devirt_pass_name(name);
    if ok return true;
    p := lookup_pass(name);
    return p != null && p.level == .CGSCC;
}

// parseCGSCCPass: one element inside a cgscc pipeline
parse_cgscc_pass :: (cgpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "cgscc" {
            inner := new_node(.CGSCC_PM, null, "cgscc");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_cgscc_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            link_child(cgpm, last, inner);
            return;
        }
        okf, eager, no_rerun := parse_function_pipeline_name(el.name);
        if okf {
            fa := new_node(.CGSCC_FN_ADAPTOR, null, el.name);
            pipeline.nodes[fa].eager_inv = eager;
            pipeline.nodes[fa].no_rerun = no_rerun;
            flast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_function_pass(fa, *flast, c); c = pipeline.elems[c].next; }
            link_child(cgpm, last, fa);
            return;
        }
        ok, n := parse_devirt_pass_name(el.name);
        if ok {
            dv := new_node(.DEVIRT, null, el.name);
            pipeline.nodes[dv].count = n;
            inner := new_node(.CGSCC_PM, null, "cgscc");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_cgscc_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            dlast: s32 = -1;
            link_child(dv, *dlast, inner);
            link_child(cgpm, last, dv);
            return;
        }
        fatal("invalid use of '%' pass as cgscc pipeline", el.name);
    }
    p := lookup_pass(el.name);
    if p == null || p.level == .MODULE unknown_pass(el.name);
    if p.level == .CGSCC { link_child(cgpm, last, new_node(p.kind, p, el.name)); return; }
    // createCGSCCToFunctionPassAdaptor(CREATE_PASS) (a loop pass: of createFunctionToLoopPassAdaptor(CREATE_PASS))
    fa := new_node(.CGSCC_FN_ADAPTOR, null, "function");
    flast: s32 = -1;
    parse_function_pass(fa, *flast, e);
    link_child(cgpm, last, fa);
}

new_node :: (kind: Pass_Kind, info: *Pass_Info, name: string) -> s32 {
    n: Pass_Node; n.kind = kind; n.info = info; n.name = name;
    id := cast(s32) pipeline.nodes.count;
    array_add(*pipeline.nodes, n);
    return id;
}
link_child :: (parent: s32, last: *s32, child: s32) {
    if last.* >= 0 pipeline.nodes[last.*].next = child; else pipeline.nodes[parent].first_child = child;
    last.* = child;
}

unknown_pass :: (name: string) {
    if name == "machine-function"
        fatal("pass pipeline: '%' pass managers are not supported yet", name);
    fatal("unknown pass name '%' (not implemented in the Jai opt yet)", name);
}

// parseFunctionPass: one element inside a function pipeline
parse_function_pass :: (fpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "function" {
            // a nested FunctionPassManager: its passes run in order with invalidation after each, and it preserves
            // all function analyses itself, so it is the same as its passes inlined into this pipeline
            c := el.first_child;
            while c >= 0 { parse_function_pass(fpm, last, c); c = pipeline.elems[c].next; }
            return;
        }
        if el.name == "loop" || el.name == "loop-mssa" {
            la := new_node(.LOOP_ADAPTOR, null, el.name);
            pipeline.nodes[la].use_mssa = el.name == "loop-mssa";
            llast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_loop_pass(la, *llast, c); c = pipeline.elems[c].next; }
            link_child(fpm, last, la);
            return;
        }
        unknown_pass(el.name);
    }
    p := lookup_pass(el.name);
    if p == null || p.level == .MODULE unknown_pass(el.name);
    if p.level == .LOOP {
        // createFunctionToLoopPassAdaptor(CREATE_PASS, /*UseMemorySSA=*/false)
        la := new_node(.LOOP_ADAPTOR, null, "loop");
        llast: s32 = -1;
        link_child(la, *llast, new_node(p.kind, p, el.name));
        link_child(fpm, last, la);
        return;
    }
    link_child(fpm, last, new_node(p.kind, p, el.name));
}

// parseLoopPass: one element inside a loop pipeline
parse_loop_pass :: (lpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "loop" {
            inner := new_node(.LOOP_PM, null, "loop");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_loop_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            link_child(lpm, last, inner);
            return;
        }
        fatal("invalid use of '%' pass as loop pipeline", el.name);
    }
    p := lookup_pass(el.name);
    if p == null || p.level != .LOOP unknown_pass(el.name);
    link_child(lpm, last, new_node(p.kind, p, el.name));
}

// isLoopPassName (UseMemorySSA for licm)
is_loop_pass_name :: (name: string) -> bool, bool {
    if name == "licm" || begins_with(name, "licm<") return true, true;
    if name == "lnicm" || begins_with(name, "lnicm<") return true, true;   // isLoopNestPassName
    p := lookup_pass(name);
    return p != null && p.level == .LOOP, false;
}

// parseModulePass
parse_module_pass :: (mpm: s32, last: *s32, e: s32) {
    el := pipeline.elems[e];
    if el.has_children {
        if el.name == "module" {
            inner := new_node(.MODULE_PM, null, "module");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_module_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            link_child(mpm, last, inner);
            return;
        }
        if el.name == "cgscc" {
            ad := new_node(.CGSCC_ADAPTOR, null, "cgscc");
            alast: s32 = -1;
            inner := new_node(.CGSCC_PM, null, "cgscc");
            ilast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_cgscc_pass(inner, *ilast, c); c = pipeline.elems[c].next; }
            link_child(ad, *alast, inner);
            link_child(mpm, last, ad);
            return;
        }
        okf, eager, no_rerun := parse_function_pipeline_name(el.name);
        if okf {
            if no_rerun pipeline_error("cannot have a no-rerun module to function adaptor");
            fa := new_node(.FUNCTION_ADAPTOR, null, el.name);
            pipeline.nodes[fa].eager_inv = eager;
            flast: s32 = -1;
            c := el.first_child;
            while c >= 0 { parse_function_pass(fa, *flast, c); c = pipeline.elems[c].next; }
            link_child(mpm, last, fa);
            return;
        }
        unknown_pass(el.name);
    }
    p := lookup_pass(el.name);
    if p == null unknown_pass(el.name);
    if p.level == .MODULE { link_child(mpm, last, new_node(p.kind, p, el.name)); return; }
    if p.level == .CGSCC {
        // createModuleToPostOrderCGSCCPassAdaptor(CREATE_PASS)
        ad := new_node(.CGSCC_ADAPTOR, null, "cgscc");
        alast: s32 = -1;
        link_child(ad, *alast, new_node(p.kind, p, el.name));
        link_child(mpm, last, ad);
        return;
    }
    if p.level == .FUNCTION {
        // a function pass in a module pipeline gets its own ModuleToFunctionPassAdaptor
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        link_child(fa, *flast, new_node(p.kind, p, el.name));
        link_child(mpm, last, fa);
        return;
    }
    if p.level == .LOOP {
        // createModuleToFunctionPassAdaptor(createFunctionToLoopPassAdaptor(CREATE_PASS, /*UseMemorySSA=*/false))
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        la := new_node(.LOOP_ADAPTOR, null, "loop");
        llast: s32 = -1;
        link_child(la, *llast, new_node(p.kind, p, el.name));
        link_child(fa, *flast, la);
        link_child(mpm, last, fa);
        return;
    }
    unknown_pass(el.name);
}

// PassBuilder::parsePassPipeline(MPM, Text): returns the root MODULE_PM node.
parse_pass_pipeline :: (text: string) -> s32 {
    first := parse_pipeline_text(text);
    if first < 0 pipeline_error("empty pipeline");
    root := new_node(.MODULE_PM, null, "module");
    last: s32 = -1;
    name := pipeline.elems[first].name;
    is_loop, loop_mssa := is_loop_pass_name(name);
    if !is_module_pass_name(name) && is_cgscc_pass_name(name) {
        // Pipeline = {{"cgscc", std::move(*Pipeline)}}
        ad := new_node(.CGSCC_ADAPTOR, null, "cgscc");
        alast: s32 = -1;
        inner := new_node(.CGSCC_PM, null, "cgscc");
        ilast: s32 = -1;
        e := first;
        while e >= 0 { parse_cgscc_pass(inner, *ilast, e); e = pipeline.elems[e].next; }
        link_child(ad, *alast, inner);
        link_child(root, *last, ad);
        return root;
    }
    if !is_module_pass_name(name) && is_loop {
        // Pipeline = {{"function", {{UseMemorySSA ? "loop-mssa" : "loop", std::move(*Pipeline)}}}}
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        la := new_node(.LOOP_ADAPTOR, null, ifx loop_mssa then "loop-mssa" else "loop");
        pipeline.nodes[la].use_mssa = loop_mssa;
        llast: s32 = -1;
        e := first;
        while e >= 0 { parse_loop_pass(la, *llast, e); e = pipeline.elems[e].next; }
        link_child(fa, *flast, la);
        link_child(root, *last, fa);
        return root;
    }
    if !is_module_pass_name(name) {
        p := lookup_pass(name);
        if (p == null || p.level != .FUNCTION) && name != "loop" && name != "loop-mssa" unknown_pass(name);
        // Pipeline = {{"function", std::move(*Pipeline)}}
        fa := new_node(.FUNCTION_ADAPTOR, null, "function");
        flast: s32 = -1;
        e := first;
        while e >= 0 { parse_function_pass(fa, *flast, e); e = pipeline.elems[e].next; }
        link_child(root, *last, fa);
        return root;
    }
    e := first;
    while e >= 0 { parse_module_pass(root, *last, e); e = pipeline.elems[e].next; }
    return root;
}

// ---------------------------------------------------------------- command-line options (cl::opt)

Cl_Kind :: enum u8 { BOOL; INT; IGNORED; STRING; TRISTATE; }   // TRISTATE: a bool stored as 0/1 in an s64 that is -1 when not given
Cl_Opt :: struct {
    name: string;
    kind: Cl_Kind;
    b: *bool;
    i: *s64;
    s: *string = null;
}

opts: struct {
    adce_remove_control_flow := true;    // ADCE.cpp -adce-remove-control-flow
    adce_remove_loops := false;          // ADCE.cpp -adce-remove-loops
    opt_bisect_limit: s64 = -1;          // OptBisect.cpp -opt-bisect-limit
    verify_dom_info := false;            // -verify-dom-info (only checks; output unaffected)
    verify_loop_info := false;           // -verify-loop-info (LoopInfo::verify: assertions only in a release build)
    verify_loop_lcssa := false;          // -verify-loop-lcssa (assertions only)
    sroa_skip_mem2reg := false;          // SROA.cpp -sroa-skip-mem2reg
    use_constant_int_for_fixed_length_splat := false;   // Constants.cpp
    use_constant_int_for_scalable_splat := false;       // Constants.cpp
    disable_simplify_libcalls := false;  // opt -disable-simplify-libcalls (TLII.disableAllFunctions)
    mtriple: string;                     // opt -mtriple
    instcombine_code_sinking := true;    // InstructionCombining.cpp -instcombine-code-sinking
    instcombine_lower_dbg_declare := true;   // -instcombine-lower-dbg-declare
    instcombine_max_sink_users: s64 = 32;    // -instcombine-max-sink-users
    instcombine_maxarray_size: s64 = 1024;   // -instcombine-maxarray-size
    instcombine_negator_enabled := true;     // InstCombineNegator.cpp -instcombine-negator-enabled
    disable_last_run_tracking := false;      // LastRunTrackingAnalysis.cpp -disable-last-run-tracking
};
opt_march: string;                       // opt -march
cl_data_layout: string;                  // opt -data-layout (overrides the module's datalayout)

cl_opts :: () -> [] Cl_Opt {
    // pointers into the global `opts`
    list := NewArray(14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT + DBGIFY_CL_OPT_COUNT + LICM_CL_OPT_COUNT + GVN_CL_OPT_COUNT + DSE_CL_OPT_COUNT + MCO_CL_OPT_COUNT + INDVARS_CL_OPT_COUNT + JT_CL_OPT_COUNT + LM_CL_OPT_COUNT, Cl_Opt,, allocator = temp);
    add_indvars_cl_opts(list, list.count - INDVARS_CL_OPT_COUNT - JT_CL_OPT_COUNT - LM_CL_OPT_COUNT);
    add_jt_cl_opts(list, list.count - JT_CL_OPT_COUNT - LM_CL_OPT_COUNT);
    add_lm_cl_opts(list, list.count - LM_CL_OPT_COUNT);
    add_gvn_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT + DBGIFY_CL_OPT_COUNT + LICM_CL_OPT_COUNT);
    add_dbgify_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT);
    add_licm_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT + DBGIFY_CL_OPT_COUNT);
    add_dse_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT + DBGIFY_CL_OPT_COUNT + LICM_CL_OPT_COUNT + GVN_CL_OPT_COUNT);
    add_mco_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT + SCFG_CL_OPT_COUNT + DBGIFY_CL_OPT_COUNT + LICM_CL_OPT_COUNT + GVN_CL_OPT_COUNT + DSE_CL_OPT_COUNT);
    add_tti_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT);
    add_scfg_cl_opts(list, 14 + AA_CL_OPT_COUNT + SCEV_CL_OPT_COUNT + TTI_CL_OPT_COUNT);
    add_aa_cl_opts(list, 14);
    add_scev_cl_opts(list, 14 + AA_CL_OPT_COUNT);
    list[11] = .{"rotation-max-header-size", .INT, null, *lr_opts.rotation_max_header_size, null};
    list[12] = .{"rotation-prepare-for-lto", .BOOL, *lr_opts.rotation_prepare_for_lto, null, null};
    list[13] = .{"enable-loop-header-duplication-at-minsize", .BOOL, *lr_opts.enable_header_dup_at_minsize, null, null};
    list[9] = .{"verify-loop-info", .BOOL, *opts.verify_loop_info, null, null};
    list[10] = .{"verify-loop-lcssa", .BOOL, *opts.verify_loop_lcssa, null, null};
    list[0] = .{"adce-remove-control-flow", .BOOL, *opts.adce_remove_control_flow, null, null};
    list[1] = .{"adce-remove-loops", .BOOL, *opts.adce_remove_loops, null, null};
    list[2] = .{"opt-bisect-limit", .INT, null, *opts.opt_bisect_limit, null};
    list[3] = .{"verify-dom-info", .BOOL, *opts.verify_dom_info, null, null};
    list[4] = .{"sroa-skip-mem2reg", .BOOL, *opts.sroa_skip_mem2reg, null, null};
    list[5] = .{"use-constant-int-for-fixed-length-splat", .BOOL, *opts.use_constant_int_for_fixed_length_splat, null, null};
    list[6] = .{"use-constant-int-for-scalable-splat", .BOOL, *opts.use_constant_int_for_scalable_splat, null, null};
    list[7] = .{"disable-simplify-libcalls", .BOOL, *opts.disable_simplify_libcalls, null, null};
    list[8] = .{"mtriple", .STRING, null, null, *opts.mtriple};
    return list;
}

// LastRunTracking and the L1.loop-misc passes (LoopDeletion, LoopIdiom, LoopLoadElim, LoopDistribute, ...)
LM_CL_OPT_COUNT :: 3 + LIR_CL_OPT_COUNT + LAA_CL_OPT_COUNT + LLE_CL_OPT_COUNT + LDIST_CL_OPT_COUNT + 1;
add_lm_cl_opts :: (list: [] Cl_Opt, base: s64) {
    add_lir_cl_opts(list, base + 3);
    add_laa_cl_opts(list, base + 3 + LIR_CL_OPT_COUNT);
    add_lle_cl_opts(list, base + 3 + LIR_CL_OPT_COUNT + LAA_CL_OPT_COUNT);
    add_ldist_cl_opts(list, base + 3 + LIR_CL_OPT_COUNT + LAA_CL_OPT_COUNT + LLE_CL_OPT_COUNT);
    list[base + 3 + LIR_CL_OPT_COUNT + LAA_CL_OPT_COUNT + LLE_CL_OPT_COUNT + LDIST_CL_OPT_COUNT] = .{"loop-version-annotate-no-alias", .BOOL, *lver_opts.annotate_no_alias, null, null};
    list[base + 0] = .{"disable-last-run-tracking", .BOOL, *opts.disable_last_run_tracking, null, null};
    list[base + 1] = .{"loop-deletion-enable-symbolic-execution", .BOOL, *ld_opts.enable_symbolic_execution, null, null};
    list[base + 2] = .{"enable-loop-simplifycfg-term-folding", .BOOL, *lscfg_opts.enable_term_folding, null, null};
}

// Parse `-name`, `--name`, `-name=value`. Returns false if the option isn't known.
parse_cl_opt :: (arg: string) -> bool {
    a := arg;
    if begins_with(a, "--") a = slice(a, 2, a.count - 2); else if begins_with(a, "-") a = slice(a, 1, a.count - 1); else return false;
    name := a; value := ""; has_value := false;
    eq := find_index_from_left(a, #char "=");
    if eq >= 0 { name = slice(a, 0, eq); value = slice(a, eq + 1, a.count - eq - 1); has_value = true; }
    if tli_parse_cl_opt(name, value, has_value) return true;   // tli.jai: -disable-builtin, libcall simplifier options
    if parse_replexitval(name, value, has_value) return true;   // pass_indvars.jai
    if reassociate_parse_cl_opt(name, value, has_value) return true;   // pass_reassociate.jai
    if constraint_elimination_parse_cl_opt(name, value, has_value) return true;   // pass_constraint_elimination.jai
    if aggressive_instcombine_parse_cl_opt(name, value, has_value) return true;   // pass_aggressive_instcombine.jai
    if vector_combine_parse_cl_opt(name, value, has_value) return true;   // pass_vector_combine.jai
    if slp_parse_cl_opt(name, value, has_value) return true;   // slp_utils.jai
    if lv_parse_cl_opt(name, value, has_value) return true;   // lv_pass.jai (LoopVectorize, before the LAA list: -force-vector-*)
    if unroll_parse_cl_opt(name, value, has_value) return true;   // pass_loop_unroll.jai
    if unswitch_parse_cl_opt(name, value, has_value) return true;   // pass_simple_loop_unswitch.jai
    // -mattr is a cl::list (CommaSeparated): repeated options accumulate
    if name == "mattr" && has_value && tti_opts.mattr.count { tti_opts.mattr = sprint("%,%", tti_opts.mattr, value); return true; }
    if ipo_parse_cl_opt(name, value, has_value) return true;   // cgscc_pm.jai, pass_function_attrs.jai, inliner
    if globals_parse_cl_opt(name, value, has_value) return true;   // pass_global_opt.jai, internalize, globaldce, ...
    if scalar_misc_parse_cl_opt(name, value, has_value) return true;   // scalar_misc_cl.jai (L1.scalar-misc passes)
    for cl_opts() {
        if it.name != name continue;
        if it.kind == .BOOL {
            if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" it.b.* = true;
            else if value == "false" || value == "0" || value == "FALSE" || value == "False" it.b.* = false;
            else fatal("invalid boolean value '%' for option -%", value, name);
        } else if it.kind == .TRISTATE {
            if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" it.i.* = 1;
            else if value == "false" || value == "0" || value == "FALSE" || value == "False" it.i.* = 0;
            else fatal("invalid boolean value '%' for option -%", value, name);
        } else if it.kind == .STRING {
            if !has_value fatal("option -% needs a value", name);
            it.s.* = value;
        } else if it.kind == .INT {
            if !has_value fatal("option -% needs a value", name);
            v, ok := string_to_int(value);
            if !ok fatal("invalid integer value '%' for option -%", value, name);
            it.i.* = v;
        }
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- running

bisect_count: s64 = 0;

// ProfileSummaryAnalysis: the module result exists once require<profile-summary> ran (it is never invalidated).
// ProfileSummaryInfo itself is not ported: a pass that would consult a cached PSI of a module that has a profile
// summary fails loudly through psi_check (with no summary every PSI query answers like a null PSI).
psi_cached := false;
psi_has_profile_summary :: () -> bool {
    if !psi_cached return false;
    for * ir.named_md {
        if it.name != "llvm.module.flags" continue;
        for m: it.ops {
            if ir.mds[m].nops < 3 continue;
            k := md_op(m, 1);
            if k != NONE && ir.mds[k].kind == .STRING && (ir.mds[k].str == "ProfileSummary" || ir.mds[k].str == "CSProfileSummary") return true;
        }
    }
    return false;
}
psi_check :: (pass_name: string) {
    if psi_has_profile_summary() fatal("%: a cached ProfileSummaryInfo with a module profile summary (require<profile-summary>) is not implemented yet", pass_name);
}

// The name OptBisect prints: PIC->getPassNameForClassName(ClassName), the registered name without parameters
bisect_pass_name :: (name: string) -> string {
    k := find_index_from_left(name, #char "<");
    if k > 0 return slice(name, 0, k);
    return name;
}

// PassInstrumentation::runBeforePass: every shouldRun callback is called (OptNone, then OptPassGate).
should_run_pass :: (node: *Pass_Node, f: Value_Id) -> bool {
    if node.info && node.info.required return true;
    if node.kind == .LOOP_ADAPTOR return true;   // FunctionToLoopPassAdaptor::isRequired
    run := true;
    // OptNoneInstrumentation
    if f != NONE && attr_set_has(attr_list_fn(glob(f).attrs), .OptimizeNone) run = false;
    // OptPassGateInstrumentation -> OptBisect::shouldRunPass
    if opts.opt_bisect_limit >= 0 {
        bisect_count += 1;
        ok := bisect_count <= opts.opt_bisect_limit;
        desc := ifx f != NONE then vname(f) else "[module]";
        print_stderr("BISECT: %running pass (%) % on %\n", ifx ok then "" else "NOT ", bisect_count, bisect_pass_name(node.name), desc);
        if !ok run = false;
    }
    return run;
}

print_stderr :: (fmt: string, args: .. Any) {
    s := tprint(fmt, ..args);
    write_string(s, to_standard_error = true);
}

run_module_pm :: (n: s32) {
    c := pipeline.nodes[n].first_child;
    while c >= 0 {
        node := *pipeline.nodes[c];
        knowledge_retention_check(node.kind, node.name);
        if node.kind == {
            case .MODULE_PM; run_module_pm(c);
            case .FUNCTION_ADAPTOR; run_function_adaptor(c);
            case .NO_OP_MODULE; should_run_pass(node, NONE);
            case .DEBUGIFY; if should_run_pass(node, NONE) { run_debugify_pass(); lcg_invalidate(); }
            case .CHECK_DEBUGIFY; if should_run_pass(node, NONE) { check_debugify_metadata("", "CheckModuleDebugify"); lcg_invalidate(); }
            case .REQUIRE_GLOBALS_AA; should_run_pass(node, NONE); if !globals_aa globals_aa = globals_aa_compute();
            case .REQUIRE_PROFILE_SUMMARY; should_run_pass(node, NONE); psi_cached = true;
            case .INFERATTRS; if should_run_pass(node, NONE) inferattrs_run_module();
            case .CGSCC_ADAPTOR; mam_invalidate(run_cgscc_adaptor(c));
            case .PRINT_LCG; should_run_pass(node, NONE); lcg_printer_run();
            case .REQUIRE_LCG; should_run_pass(node, NONE); lcg_get();
            case .INVALIDATE_LCG; should_run_pass(node, NONE); lcg_invalidate();
            case .RPO_FUNCTION_ATTRS; if should_run_pass(node, NONE) mam_invalidate(rpo_function_attrs_run());
            case .NORECURSE_LTO_INFERENCE; if should_run_pass(node, NONE) mam_invalidate(norecurse_lto_inference_run());
            case .ALWAYS_INLINE; if should_run_pass(node, NONE) mam_invalidate(always_inliner_run());
            case .MODULE_INLINE; if should_run_pass(node, NONE) mam_invalidate(module_inliner_run());
            case .INLINER_WRAPPER; if should_run_pass(node, NONE) inliner_wrapper_run();
            case .GLOBAL_OPT; if should_run_pass(node, NONE) mam_invalidate(global_opt_run());
            case .GLOBAL_DCE; if should_run_pass(node, NONE) mam_invalidate(global_dce_run(node));
            case .CONSTANT_MERGE; if should_run_pass(node, NONE) mam_invalidate(constant_merge_run());
            case .STRIP_DEAD_PROTOTYPES; if should_run_pass(node, NONE) mam_invalidate(strip_dead_prototypes_run());
            case .ELIM_AVAIL_EXTERN; if should_run_pass(node, NONE) mam_invalidate(elim_avail_extern_run());
            case .INTERNALIZE; if should_run_pass(node, NONE) mam_invalidate(internalize_run(node));
            case .ASSIGN_GUID; if should_run_pass(node, NONE) mam_invalidate(assign_guid_run());
            case .DEAD_ARG_ELIM; if should_run_pass(node, NONE) mam_invalidate(dead_arg_elim_run());
            case .CORO_EARLY; if should_run_pass(node, NONE) mam_invalidate(coro_early_run());
            case .CORO_CLEANUP; if should_run_pass(node, NONE) mam_invalidate(coro_cleanup_run());
            case .OPENMP_OPT; if should_run_pass(node, NONE) mam_invalidate(openmp_opt_run());
            case .ANNOTATION2METADATA; if should_run_pass(node, NONE) mam_invalidate(annotation2metadata_run());
            case .FORCEATTRS; if should_run_pass(node, NONE) mam_invalidate(forceattrs_run());
            case .MEMPROF_REMOVE_INFO; if should_run_pass(node, NONE) mam_invalidate(memprof_remove_info_run());
            case .RECOMPUTE_GLOBALSAA; if should_run_pass(node, NONE) recompute_globalsaa_run();
            case .LOWER_COMMENT_STRING; if should_run_pass(node, NONE) mam_invalidate(lower_comment_string_run());
            case .REL_LOOKUP_TABLE_CONVERTER; if should_run_pass(node, NONE) mam_invalidate(rel_lookup_table_converter_run());
            case .CG_PROFILE; if should_run_pass(node, NONE) mam_invalidate(cg_profile_run());
            case .ALLOC_TOKEN; if should_run_pass(node, NONE) mam_invalidate(alloc_token_run());
            case; fatal("internal: '%' is not a module pass", node.name);
        }
        c = pipeline.nodes[c].next;
    }
}

// MAM.invalidate(M, PA) after a module pass: the LazyCallGraph, and (FunctionAnalysisManagerModuleProxy) every
// function's analyses unless PA preserves AllAnalysesOn<Function>
mam_invalidate :: (pa: Preserved) {
    if pa.all return;
    if !pa.lcg lcg_invalidate();
    if !pa.all_fn for f: ir.m_functions fam_invalidate(f, pa);
    globals_aa = null;
}

// ModuleToFunctionPassAdaptor::run: every defined function in module order
run_function_adaptor :: (n: s32) {
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        i += 1;
        if is_declaration(f) continue;
        c := pipeline.nodes[n].first_child;
        while c >= 0 {
            node := *pipeline.nodes[c];
            if should_run_pass(node, f) {
                pa := run_function_pass(node, f);
                if !pa.all { printer_note_ir_changed(); lcg_invalidate(); }
                fam_invalidate(f, pa);
            }
            reset_temporary_storage();
            c = pipeline.nodes[c].next;
        }
        // ModuleToFunctionPassAdaptor with EagerlyInvalidate: FAM.invalidate(F, PreservedAnalyses::none())
        if pipeline.nodes[n].eager_inv fam_invalidate(f, PRESERVE_NONE);
    }
}

stderr_builder: String_Builder;

run_function_pass :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    knowledge_retention_check(node.kind, node.name);
    if node.kind == {
        case .NO_OP_FUNCTION; return PRESERVE_ALL;
        case .REQUIRE; fam_require(f, node.info.analysis); return PRESERVE_ALL;
        case .INVALIDATE; fam_invalidate_one(f, node.info.analysis); return PRESERVE_ALL;
        case .PRINT_DOMTREE;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "DominatorTree for function: %\n", vname(f));
            dt_print(get_domtree(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_POSTDOMTREE;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "PostDominatorTree for function: %\n", vname(f));
            dt_print(get_postdomtree(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_COST_MODEL; cost_model_printer_run(f); return PRESERVE_ALL;
        case .PRINT_ACCESS_INFO; return access_info_printer_run(f, node.name);
        case .LOOP_LOAD_ELIM; return loop_load_elim_run(f);
        case .LOOP_DISTRIBUTE; return loop_distribute_run(f);
        case .PRINT_DEMANDED_BITS;
            sb: String_Builder; sb.allocator = temp;
            db_print(get_demanded_bits(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .DCE; return dce_run(f);
        case .ADCE; return adce_run(f);
        case .BDCE; return bdce_run(f);
        case .LOWER_EXPECT; return lower_expect_run(f);
        case .LOWER_CONSTANT_INTRINSICS; return lower_constant_intrinsics_run(f);
        case .INFER_ALIGNMENT; return infer_alignment_run(f);
        case .DIV_REM_PAIRS; return div_rem_pairs_run(f);
        case .FLOAT2INT; return float2int_run(f);
        case .SINK; return sink_run(f);
        case .TAILCALLELIM; return tailcallelim_run(f);
        case .MLDST_MOTION; return mldst_motion_run(f, node.name);
        case .SPECULATIVE_EXECUTION; return speculative_execution_run(f, node.name);
        case .CALLSITE_SPLITTING; return callsite_splitting_run(f);
        case .CORO_ELIDE; return coro_elide_run(f);
        case .ANNOTATION_REMARKS; return annotation_remarks_run(f);
        case .INJECT_TLI_MAPPINGS; return inject_tli_mappings_run(f);
        case .EE_INSTRUMENT; return ee_instrument_run(f, node.name);
        case .REASSOCIATE; return reassociate_run(f);
        case .CONSTRAINT_ELIMINATION; return constraint_elimination_run(f);
        case .AGGRESSIVE_INSTCOMBINE; return aggressive_instcombine_run(f);
        case .VECTOR_COMBINE; return vector_combine_run(f);
        case .SLP_VECTORIZER; return slp_vectorizer_run(f);
        case .LOOP_UNROLL; return loop_unroll_run(node, f);
        case .LOOP_VECTORIZE; return loop_vectorize_run(f, node.name);
        case .BREAK_CRIT_EDGES; return break_crit_edges_run(f);
        case .MEM2REG; return mem2reg_run(f);
        case .INSTSIMPLIFY; return instsimplify_run(f);
        case .DSE; return dse_run(f);
        case .MEMCPYOPT; return memcpyopt_run(f);
        case .SROA; return sroa_run(f, node.name);
        case .GVN; return gvn_run(f, node.name);
        case .INSTCOMBINE; return instcombine_run(f, node.name);
        case .REDUNDANT_DBG_INST_ELIM; return redundant_dbg_inst_elim_run(f);
        case .SIMPLIFYCFG; return simplifycfg_run(node, f);
        case .LOOP_ADAPTOR; return run_loop_adaptor(cast(s32) (node - pipeline.nodes.data), f);
        case .AA_EVAL;
            sb: String_Builder; sb.allocator = temp;
            aa_eval_run(f, aa_eval_counts_for(node), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_SCEV; scev_printer_run(f); return PRESERVE_ALL;
        case .VERIFY_SCEV; scev_verifier_run(f); return PRESERVE_ALL;
        case .PRINT_LOOPS;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "Loop info for function '%':\n", vname(f));
            li_print(get_loop_info(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_CYCLES;
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "CycleInfo for function: %\n", vname(f));
            ci_print(get_cycle_info(f), *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
            return PRESERVE_ALL;
        case .LOOP_SIMPLIFY; return loop_simplify_run(f);
        case .LCSSA; return lcssa_run(f);
        case .PRINT_MEMORYSSA; mssa_printer_run(f, true); return PRESERVE_ALL;
        case .PRINT_MEMORYSSA_NO_OPT; mssa_printer_run(f, false); return PRESERVE_ALL;
        case .PRINT_MEMORYSSA_WALKER; mssa_walker_printer_run(f); return PRESERVE_ALL;
        case .VERIFY_MEMORYSSA; mssa_verifier_run(f); return PRESERVE_ALL;
        case .PRINT_LVI; return print_lazy_value_info_run(f);
        case .CVP; return cvp_run(f);
        case .JUMP_THREADING; return jump_threading_run(f);
        case .PRINT_BPI; return print_branch_prob_run(f);
        case .PRINT_BFI; return print_block_freq_run(f);
    }
    fatal("internal: '%' is not a function pass", node.name);
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- opt's main

opt_main :: () {
    tool_name = "opt";
    args := get_command_line_arguments();
    input := "";
    output := "-";
    passes := "";
    disable_output := false;
    have_passes := false;
    i := 1;
    while i < args.count {
        a := args[i];
        i += 1;
        if a == "-S" continue;
        // -f (write binary output to a terminal) and -emulated-tls (a TargetOptions flag of the code generator) do
        // not change what opt's IR passes do
        if a == "-f" || a == "--f" || a == "-emulated-tls" || a == "--emulated-tls" continue;
        if a == "-o" { if i >= args.count fatal("-o needs a file"); output = args[i]; i += 1; continue; }
        // cl::list / value-required options also take their value from the next argument
        if a == "-disable-builtin" || a == "--disable-builtin" || a == "-enable-builtin" || a == "--enable-builtin" ||
           a == "-internalize-public-api-list" || a == "--internalize-public-api-list" ||
           a == "-internalize-public-api-file" || a == "--internalize-public-api-file" {
            if i >= args.count fatal("option % needs a value", a);
            if !parse_cl_opt(tprint("%=%", a, args[i])) fatal("unsupported option '%'", a);
            i += 1;
            continue;
        }
        if scalar_misc_takes_value(a) {   // scalar_misc_cl.jai: integer options written `-name value`
            if i >= args.count fatal("option % needs a value", a);
            if !parse_cl_opt(tprint("%=%", a, args[i])) fatal("unsupported option '%'", a);
            i += 1;
            continue;
        }
        if a == "-mtriple" || a == "--mtriple" { if i >= args.count fatal("-mtriple needs a value"); opts.mtriple = args[i]; i += 1; continue; }
        if a == "-disable-output" || a == "--disable-output" { disable_output = true; continue; }
        if begins_with(a, "-passes=") || begins_with(a, "--passes=") {
            eq := find_index_from_left(a, #char "=");
            passes = slice(a, eq + 1, a.count - eq - 1);
            have_passes = true;
            continue;
        }
        if a == "-passes" || a == "--passes" { if i >= args.count fatal("-passes needs a value"); passes = args[i]; i += 1; have_passes = true; continue; }
        if a == "-data-layout" || a == "--data-layout" { if i >= args.count fatal("-data-layout needs a value"); cl_data_layout = args[i]; i += 1; continue; }
        if begins_with(a, "-march=") || begins_with(a, "--march=") { opt_march = slice(a, find_index_from_left(a, #char "=") + 1, a.count - find_index_from_left(a, #char "=") - 1); continue; }
        if begins_with(a, "-data-layout=") || begins_with(a, "--data-layout=") {
            cl_data_layout = slice(a, find_index_from_left(a, #char "=") + 1, a.count - find_index_from_left(a, #char "=") - 1);
            continue;
        }
        if a == "-aa-pipeline" || a == "--aa-pipeline" { if i >= args.count fatal("-aa-pipeline needs a value"); aa_parse_pipeline(args[i]); i += 1; continue; }
        // -verify-each runs the verifier after every pass; on the valid IR our passes must produce it reports nothing
        // (the harness verifies our output separately)
        if a == "-verify-each" || a == "--verify-each" continue;
        // -run-twice only acts in the legacy PM path of optdriver.cpp; with -passes / -O# (NewPMDriver) it is ignored
        if a == "-run-twice" || a == "--run-twice" continue;
        // -disable-verify: opt does not verify its input and output; we never verify
        if a == "-disable-verify" || a == "--disable-verify" continue;
        // -disable-loop-unrolling sets PipelineTuningOptions::LoopUnrolling, which only -O<n> pipelines read
        if a == "-disable-loop-unrolling" || a == "--disable-loop-unrolling" || begins_with(a, "-disable-loop-unrolling=") || begins_with(a, "--disable-loop-unrolling=") continue;
        if begins_with(a, "-aa-pipeline=") || begins_with(a, "--aa-pipeline=") {
            aa_parse_pipeline(slice(a, find_index_from_left(a, #char "=") + 1, a.count - find_index_from_left(a, #char "=") - 1));
            continue;
        }
        if a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" || a == "-Os" || a == "-Oz"
            fatal("'%' pipelines are not implemented yet (only -passes=<pipeline> with the passes in impl/jai/src/passes.jai)", a);
        if begins_with(a, "-") && a != "-" {
            if parse_cl_opt(a) continue;
            fatal("unsupported option '%'", a);
        }
        input = a;
    }
    root: s32 = -1;
    if have_passes root = parse_pass_pipeline(passes);
    if input.count == 0 fatal("no input file");
    if input == "-" fatal("reading from stdin is not supported");
    src, ok := read_entire_file(input);
    if !ok fatal("could not open input file '%'", input);
    ir_init();
    ir.module_id = input;
    parse_module(src, input);
    if opts.mtriple.count ir.triple = normalize_triple(opts.mtriple);
    // -march only selects the target of the TargetMachine, which opt creates only for a module with a target triple
    if opt_march.count && ir.triple.count fatal("unsupported option '-march=%' (with a target triple)", opt_march);
    if opt_strip_debug strip_debug_info();   // "Strip debug info before running the verifier"
    tti_create_target_machine();
    opt_set_function_attributes();
    if ir.source_filename.count == 0 && !saw_source_filename ir.source_filename = input;
    // NewPMDriver.cpp: -enable-debugify wraps the pipeline in debugify / check-debugify
    dbgify_check_level();
    if dbgify_opts.enable run_debugify_pass();
    if root >= 0 run_module_pm(root);
    if dbgify_opts.enable check_debugify_metadata("", "CheckModuleDebugify");
    defer aa_eval_print_reports();
    if disable_output return;
    text := print_module_fresh();
    if output == "-" write_string(text);
    else if !write_entire_file(output, text) fatal("could not write '%'", output);
}
