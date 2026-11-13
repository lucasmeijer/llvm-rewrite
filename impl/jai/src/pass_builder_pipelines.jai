// The default optimization pipelines (`-O1`/`-O2`/`-O3`, `-passes='default<O#>'`, `default<O0>`) and the LTO
// pipelines (`lto-pre-link<O#>`, `lto<O#>`, `thinlto-pre-link<O#>`, `thinlto<O#>`).
// Port of llvm/lib/Passes/PassBuilderPipelines.cpp: PipelineTuningOptions' defaults, buildPerModuleDefaultPipeline,
// buildLTOPreLinkDefaultPipeline, buildLTODefaultPipeline, buildThinLTOPreLinkDefaultPipeline,
// buildThinLTODefaultPipeline, addRequiredLTOPreLinkPasses,
// buildModuleSimplificationPipeline, buildInlinerPipeline (ModuleInlinerWrapperPass), buildModuleInlinerPipeline,
// buildFunctionSimplificationPipeline, buildO1FunctionSimplificationPipeline, buildModuleOptimizationPipeline,
// addVectorPasses, buildO0DefaultPipeline (with buildCoroWrapper), and setupOptionsForPipelineAlias (PassBuilder.cpp).
// The ThinOrFullLTOPhase is `pb_phase` (set by the entry point that builds the pipeline; LLVM passes it down as a
// parameter), there is no PGOOptions, and every extension point is empty (opt registers no callbacks without
// plugins / -passes-ep-* options).
//
// The pipeline is built as Pass_Node rows (DESIGN.md "Pass infrastructure"). Leaf passes are created from the name
// LLVM's printPipeline prints for them (so `-jai-print-pipeline` can be diffed against `opt -print-pipeline-passes`);
// parameters printPipeline does not show are set on the node afterwards (`opt_level`, `only_when_forced`,
// `no_entry_count_update`, `no_lifetime`). Structural nodes that have no textual form are built directly:
// INLINER_WRAPPER (ModuleInlinerWrapperPass), EXTRA_LOOP_UNSWITCH (ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch>
// with its simple-loop-unswitch inside) and CORO_COND (CoroConditionalWrapper).

// OptimizationLevel (only O0..O3 can be named; Os/Oz were removed from the pass builder)
Opt_Level :: struct { speed: s32; size: s32; }

// ThinOrFullLTOPhase
Lto_Phase :: enum u8 { NONE; THIN_PRE_LINK; THIN_POST_LINK; FULL_PRE_LINK; FULL_POST_LINK; }
pb_phase: Lto_Phase;
is_lto_pre_link :: () -> bool { return pb_phase == .THIN_PRE_LINK || pb_phase == .FULL_PRE_LINK; }
is_lto_post_link :: () -> bool { return pb_phase == .THIN_POST_LINK || pb_phase == .FULL_POST_LINK; }
pb_rotate :: (check_exit_count: bool) -> string {
    return tprint("loop-rotate<header-duplication;%;%>", ifx is_lto_pre_link() then "prepare-for-lto" else "no-prepare-for-lto",
                  ifx check_exit_count then "check-exit-count" else "no-check-exit-count");
}

// PipelineTuningOptions (PipelineTuningOptions::PipelineTuningOptions + opt's NewPMDriver overrides)
Pipeline_Tuning :: struct {
    loop_interleaving := true;
    loop_vectorization := true;
    slp_vectorization := false;
    loop_unrolling := true;          // opt: !DisableLoopUnrolling
    loop_interchange := true;        // EnableLoopInterchange (-enable-loopinterchange)
    loop_fusion := false;            // opt: -enable-loopfusion
    call_graph_profile := true;
    merge_functions := false;        // EnableMergeFunctions (-enable-merge-functions)
    inliner_threshold: s64 = -1;
    eagerly_invalidate_analyses := true;   // -eagerly-invalidate-analyses
    devirtualize_speculatively := false;   // -enable-devirtualize-speculatively
}
pto: Pipeline_Tuning;

// The cl::opts of PassBuilderPipelines.cpp (and opt's -disable-loop-unrolling / -enable-loopfusion)
pb_cl: struct {
    enable_module_inliner := false;           // -enable-module-inliner
    mandatory_inlining_first := false;        // -mandatory-inlining-first
    enable_post_pgo_loop_rotation := true;
    enable_global_analyses := true;           // -enable-global-analyses
    enable_partial_inlining := false;         // -enable-partial-inlining
    extra_vectorizer_passes := false;         // -extra-vectorizer-passes
    enable_newgvn := false;                   // -enable-newgvn
    enable_unroll_and_jam := false;           // -enable-unroll-and-jam
    enable_loop_flatten := false;             // -enable-loop-flatten
    enable_instrumentor := false;             // -enable-instrumentor
    enable_dfa_jump_thread := true;           // -enable-dfa-jump-thread
    enable_hot_cold_split := false;           // -hot-cold-split
    enable_ir_outliner := false;              // -ir-outliner
    enable_gvn_hoist := false;                // -enable-gvn-hoist
    enable_gvn_sink := false;                 // -enable-gvn-sink
    enable_jump_table_to_switch := true;      // -enable-jump-table-to-switch
    enable_chr := true;                       // -enable-chr
    enable_matrix := false;                   // -enable-matrix
    enable_merge_icmps := true;               // -enable-mergeicmps
    enable_constraint_elimination := true;    // -enable-constraint-elimination
    attributor_run := "none";                 // -attributor-enable
    enable_loop_versioning_licm := false;     // -enable-loop-versioning-licm
    opt_pipeline_trigger_crash := false;      // -opt-pipeline-trigger-crash
}

pb_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    b :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == {
        case "enable-loopinterchange"; pto.loop_interchange = b(name, value, has_value);
        case "enable-merge-functions"; pto.merge_functions = b(name, value, has_value);
        case "eagerly-invalidate-analyses"; pto.eagerly_invalidate_analyses = b(name, value, has_value);
        case "enable-devirtualize-speculatively"; pto.devirtualize_speculatively = b(name, value, has_value);
        case "disable-loop-unrolling"; pto.loop_unrolling = !b(name, value, has_value);
        case "enable-loopfusion"; pto.loop_fusion = b(name, value, has_value);
        case "enable-module-inliner"; pb_cl.enable_module_inliner = b(name, value, has_value);
        case "mandatory-inlining-first"; pb_cl.mandatory_inlining_first = b(name, value, has_value);
        case "enable-post-pgo-loop-rotation"; pb_cl.enable_post_pgo_loop_rotation = b(name, value, has_value);
        case "enable-global-analyses"; pb_cl.enable_global_analyses = b(name, value, has_value);
        case "enable-partial-inlining"; pb_cl.enable_partial_inlining = b(name, value, has_value);
        case "extra-vectorizer-passes"; pb_cl.extra_vectorizer_passes = b(name, value, has_value);
        case "enable-newgvn"; pb_cl.enable_newgvn = b(name, value, has_value);
        case "enable-unroll-and-jam"; pb_cl.enable_unroll_and_jam = b(name, value, has_value);
        case "enable-loop-flatten"; pb_cl.enable_loop_flatten = b(name, value, has_value);
        case "enable-instrumentor"; pb_cl.enable_instrumentor = b(name, value, has_value);
        case "enable-dfa-jump-thread"; pb_cl.enable_dfa_jump_thread = b(name, value, has_value);
        case "hot-cold-split"; pb_cl.enable_hot_cold_split = b(name, value, has_value);
        case "ir-outliner"; pb_cl.enable_ir_outliner = b(name, value, has_value);
        case "enable-gvn-hoist"; pb_cl.enable_gvn_hoist = b(name, value, has_value);
        case "enable-gvn-sink"; pb_cl.enable_gvn_sink = b(name, value, has_value);
        case "enable-jump-table-to-switch"; pb_cl.enable_jump_table_to_switch = b(name, value, has_value);
        case "enable-chr"; pb_cl.enable_chr = b(name, value, has_value);
        case "enable-matrix"; pb_cl.enable_matrix = b(name, value, has_value);
        case "enable-mergeicmps"; pb_cl.enable_merge_icmps = b(name, value, has_value);
        case "enable-constraint-elimination"; pb_cl.enable_constraint_elimination = b(name, value, has_value);
        case "enable-loop-versioning-licm"; pb_cl.enable_loop_versioning_licm = b(name, value, has_value);
        case "opt-pipeline-trigger-crash"; pb_cl.opt_pipeline_trigger_crash = b(name, value, has_value);
        case "attributor-enable";
            if !has_value fatal("option -attributor-enable needs a value");
            if value != "none" && value != "full" && value != "light" && value != "module" && value != "module-light" && value != "cgscc" && value != "cgscc-light"
                fatal("invalid value '%' for option -attributor-enable", value);
            pb_cl.attributor_run = value;
        case; return false;
    }
    return true;
}

// parseOptLevel (PassBuilder.cpp)
pb_parse_opt_level :: (s: string) -> bool, Opt_Level {
    if s == "Os" || s == "Oz"
        fatal("The optimization level \"%\" is no longer supported. Use O2 in conjunction with the % attribute instead.", s, ifx s == "Os" then "optsize" else "minsize");
    if s == "O0" return true, .{0, 0};
    if s == "O1" return true, .{1, 0};
    if s == "O2" return true, .{2, 0};
    if s == "O3" return true, .{3, 0};
    return false, .{};
}

// `default<O#>` in a module pipeline: setupOptionsForPipelineAlias, then buildPerModuleDefaultPipeline
pb_parse_default_pipeline :: (mpm: s32, last: *s32, name: string) -> bool {
    if !begins_with(name, "default<") || name[name.count - 1] != #char ">" return false;
    inner := slice(name, 8, name.count - 9);
    ok, level := pb_parse_opt_level(inner);
    if !ok pipeline_error("invalid optimization level '%'", inner);
    pto.loop_vectorization = level.speed >= 2;
    pto.slp_vectorization = level.speed >= 2;
    pb_phase = .NONE;
    build_per_module_default_pipeline(mpm, last, level);
    return true;
}
// The LTO aliases of PassRegistry.def: thinlto-pre-link<O#>, thinlto<O#>, lto-pre-link<O#>, lto<O#>
pb_parse_lto_pipeline :: (mpm: s32, last: *s32, name: string) -> bool {
    if name[name.count - 1] != #char ">" return false;
    prefix: string;
    for string.["thinlto-pre-link<", "thinlto<", "lto-pre-link<", "lto<"] if begins_with(name, it) { prefix = it; break; }
    if !prefix.count return false;
    inner := slice(name, prefix.count, name.count - prefix.count - 1);
    ok, level := pb_parse_opt_level(inner);
    if !ok pipeline_error("invalid optimization level '%'", inner);
    pto.loop_vectorization = level.speed >= 2;
    pto.slp_vectorization = level.speed >= 2;
    if prefix == {
        case "thinlto-pre-link<"; build_thinlto_pre_link_default_pipeline(mpm, last, level);
        case "thinlto<"; build_thinlto_default_pipeline(mpm, last, level);
        case "lto-pre-link<"; pb_phase = .FULL_PRE_LINK; build_per_module_default_pipeline(mpm, last, level);   // PTO.UnifiedLTO is off
        case "lto<"; build_lto_default_pipeline(mpm, last, level);
    }
    pb_phase = .NONE;
    return true;
}
pb_is_unsupported_alias :: (name: string) -> bool {
    return begins_with(name, "fatlto-pre-link<");
}

// ---------------------------------------------------------------- building blocks

// Adds the pass(es) of `text` (pipeline text, LLVM's printed names) to the pass manager node `pm`. Returns the last
// node created (the leaf for a single pass).
pb_add :: (pm: s32, last: *s32, text_in: string) -> s32 {
    text := copy_string(text_in);   // node names slice the text: it must outlive the temporary storage
    e := parse_pipeline_text(text);
    k := pipeline.nodes[pm].kind;
    while e >= 0 {
        if k == {
            case .MODULE_PM; #through;
            case .INLINER_WRAPPER_PM; #through;
            case .CORO_COND; parse_module_pass(pm, last, e);
            case .FUNCTION_ADAPTOR; #through;
            case .CGSCC_FN_ADAPTOR; parse_function_pass(pm, last, e);
            case .LOOP_ADAPTOR; #through;
            case .LOOP_PM; #through;
            case .EXTRA_LOOP_UNSWITCH; parse_loop_pass(pm, last, e);
            case .CGSCC_PM; parse_cgscc_pass(pm, last, e);
            case; fatal("internal: pb_add on a '%' node", pipeline.nodes[pm].name);
        }
        e = pipeline.elems[e].next;
    }
    return cast(s32) (pipeline.nodes.count - 1);
}
pb_node :: (pm: s32, last: *s32, kind: Pass_Kind, name: string) -> s32 {
    n := new_node(kind, null, name);
    link_child(pm, last, n);
    return n;
}
// createModuleToFunctionPassAdaptor(FPM, EagerlyInvalidate)
pb_function_adaptor :: (mpm: s32, last: *s32, eager: bool) -> s32 {
    n := pb_node(mpm, last, .FUNCTION_ADAPTOR, ifx eager then "function<eager-inv>" else "function");
    pipeline.nodes[n].eager_inv = eager;
    return n;
}
// createFunctionToLoopPassAdaptor(LPM, UseMemorySSA)
pb_loop_adaptor :: (fpm: s32, last: *s32, use_mssa: bool) -> s32 {
    n := pb_node(fpm, last, .LOOP_ADAPTOR, ifx use_mssa then "loop-mssa" else "loop");
    pipeline.nodes[n].use_mssa = use_mssa;
    return n;
}

// SimplifyCFGOptions printed by SimplifyCFGPass::printPipeline
Scfg_Pb :: struct {
    forward_switch_cond := false;
    switch_range_to_icmp := false;
    switch_to_arithmetic := false;
    switch_to_lookup := false;
    keep_loops := true;
    hoist_common_insts := false;
    hoist_loads_stores_with_cond_faulting := false;
    sink_common_insts := false;
    speculate_unpredictables := false;
}
pb_simplifycfg :: (o: Scfg_Pb) -> string {
    f :: (b: bool, s: string) -> string { return ifx b then s else tprint("no-%", s); }
    return tprint("simplifycfg<bonus-inst-threshold=1;%;%;%;%;%;%;%;%;speculate-blocks;simplify-cond-branch;%>",
        f(o.forward_switch_cond, "forward-switch-cond"), f(o.switch_range_to_icmp, "switch-range-to-icmp"),
        f(o.switch_to_arithmetic, "switch-to-arithmetic"), f(o.switch_to_lookup, "switch-to-lookup"),
        f(o.keep_loops, "keep-loops"), f(o.hoist_common_insts, "hoist-common-insts"),
        f(o.hoist_loads_stores_with_cond_faulting, "hoist-loads-stores-with-cond-faulting"),
        f(o.sink_common_insts, "sink-common-insts"), f(o.speculate_unpredictables, "speculate-unpredictables"));
}
SCFG_DEFAULT :: Scfg_Pb.{};
SCFG_RANGE :: Scfg_Pb.{switch_range_to_icmp = true};   // SimplifyCFGOptions().convertSwitchRangeToICmp(true)
INSTCOMBINE :: "instcombine<max-iterations=1;no-verify-fixpoint>";

pb_unsupported :: (what: string) {
    fatal("default pipeline: % is not implemented yet", what);
}

// LICMPass(PTO.LicmMssaOptCap, PTO.LicmMssaNoAccForPromotionCap, AllowSpeculation)
pb_licm :: (allow_speculation: bool) -> string {
    return ifx allow_speculation then "licm<allowspeculation>" else "licm<no-allowspeculation>";
}
// LoopFullUnrollPass(Level, OnlyWhenForced = !PTO.LoopUnrolling, PTO.ForgetAllSCEVInLoopUnroll)
pb_loop_unroll_full :: (lpm: s32, last: *s32, level: Opt_Level) {
    n := pb_add(lpm, last, "loop-unroll-full");
    pipeline.nodes[n].opt_level = cast(s8) level.speed;
    pipeline.nodes[n].only_when_forced = !pto.loop_unrolling;
}
// LoopUnrollPass(LoopUnrollOptions(Level, OnlyWhenForced = !PTO.LoopUnrolling, PTO.ForgetAllSCEVInLoopUnroll))
pb_loop_unroll :: (fpm: s32, last: *s32, level: Opt_Level) {
    n := pb_add(fpm, last, tprint("loop-unroll<O%>", level.speed));
    pipeline.nodes[n].opt_level = cast(s8) level.speed;
    pipeline.nodes[n].only_when_forced = !pto.loop_unrolling;
}
// TailCallElimPass(UpdateFunctionEntryCount = isInstrumentedPGOUse()): false without PGO
pb_tailcallelim :: (fpm: s32, last: *s32) {
    n := pb_add(fpm, last, "tailcallelim");
    pipeline.nodes[n].no_entry_count_update = true;
}
// The peephole extension point (invokePeepholeEPCallbacks) is empty.

// ---------------------------------------------------------------- the function simplification pipelines

build_o1_function_simplification_pipeline :: (fpm: s32, last: *s32, level: Opt_Level) {
    pb_add(fpm, last, "sroa<modify-cfg>");
    pb_add(fpm, last, "early-cse<memssa>");
    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, INSTCOMBINE);
    pb_add(fpm, last, "libcalls-shrinkwrap");
    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, "reassociate");

    lpm1_last: s32 = -1;
    lpm1 := pb_loop_adaptor(fpm, last, true);
    pb_add(lpm1, *lpm1_last, "loop-instsimplify");
    pb_add(lpm1, *lpm1_last, "loop-simplifycfg");
    pb_add(lpm1, *lpm1_last, pb_licm(false));
    pb_add(lpm1, *lpm1_last, pb_rotate(false));
    pb_add(lpm1, *lpm1_last, pb_licm(true));
    pb_add(lpm1, *lpm1_last, "simple-loop-unswitch<no-nontrivial;trivial>");
    if pb_cl.enable_loop_flatten pb_unsupported("loop-flatten (-enable-loop-flatten)");

    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, INSTCOMBINE);

    lpm2_last: s32 = -1;
    lpm2 := pb_loop_adaptor(fpm, last, false);
    pb_add(lpm2, *lpm2_last, "loop-idiom");
    pb_add(lpm2, *lpm2_last, "indvars");
    pb_add(lpm2, *lpm2_last, "loop-deletion");
    pb_loop_unroll_full(lpm2, *lpm2_last, level);

    pb_add(fpm, last, "sroa<modify-cfg>");
    pb_add(fpm, last, "memcpyopt");
    pb_add(fpm, last, "sccp");
    pb_add(fpm, last, "bdce");
    pb_add(fpm, last, INSTCOMBINE);
    pb_add(fpm, last, "coro-elide");
    pb_add(fpm, last, "adce");
    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, INSTCOMBINE);
}

build_function_simplification_pipeline :: (fpm: s32, last: *s32, level: Opt_Level) {
    if level.speed == 1 && level.size == 0 { build_o1_function_simplification_pipeline(fpm, last, level); return; }
    pb_add(fpm, last, "sroa<modify-cfg>");
    pb_add(fpm, last, "early-cse<memssa>");
    if knowledge_retention.enabled pb_unsupported("assume-simplify (-enable-knowledge-retention)");
    if pb_cl.enable_gvn_hoist pb_unsupported("gvn-hoist (-enable-gvn-hoist)");
    if pb_cl.enable_gvn_sink pb_unsupported("gvn-sink (-enable-gvn-sink)");
    pb_add(fpm, last, "speculative-execution<only-if-divergent-target>");
    pb_add(fpm, last, "jump-threading");
    pb_add(fpm, last, "correlated-propagation");
    if pb_cl.enable_jump_table_to_switch {
        n := pb_add(fpm, last, "jump-table-to-switch");   // JumpTableToSwitchPass(InLTO = isLTOPostLink(Phase))
        pipeline.nodes[n].in_lto = is_lto_post_link();
    }
    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, INSTCOMBINE);
    pb_add(fpm, last, "aggressive-instcombine");
    pb_add(fpm, last, "libcalls-shrinkwrap");
    pb_tailcallelim(fpm, last);
    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, "reassociate");
    if pb_cl.enable_constraint_elimination pb_add(fpm, last, "constraint-elimination");

    lpm1_last: s32 = -1;
    lpm1 := pb_loop_adaptor(fpm, last, true);
    pb_add(lpm1, *lpm1_last, "loop-instsimplify");
    pb_add(lpm1, *lpm1_last, "loop-simplifycfg");
    pb_add(lpm1, *lpm1_last, pb_licm(false));
    pb_add(lpm1, *lpm1_last, pb_rotate(false));
    pb_add(lpm1, *lpm1_last, pb_licm(true));
    unswitch := ifx level.speed == 3 then "simple-loop-unswitch<nontrivial;trivial>" else "simple-loop-unswitch<no-nontrivial;trivial>";
    pb_add(lpm1, *lpm1_last, unswitch);
    if pb_cl.enable_loop_flatten pb_unsupported("loop-flatten (-enable-loop-flatten)");

    pb_add(fpm, last, pb_simplifycfg(SCFG_RANGE));
    pb_add(fpm, last, INSTCOMBINE);

    lpm2_last: s32 = -1;
    lpm2 := pb_loop_adaptor(fpm, last, false);
    pb_add(lpm2, *lpm2_last, "loop-idiom");
    pb_add(lpm2, *lpm2_last, "indvars");
    {
        // ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch> with SimpleLoopUnswitchPass(NonTrivial = O3)
        extra := pb_node(lpm2, *lpm2_last, .EXTRA_LOOP_UNSWITCH, "extra-simple-loop-unswitch-passes");
        pipeline.nodes[extra].info = lookup_pass("extra-simple-loop-unswitch-passes");
        extra_last: s32 = -1;
        pb_add(extra, *extra_last, unswitch);
    }
    pb_add(lpm2, *lpm2_last, "loop-deletion");
    pb_loop_unroll_full(lpm2, *lpm2_last, level);

    pb_add(fpm, last, "sroa<modify-cfg>");
    vcn := pb_add(fpm, last, "vector-combine");   // VectorCombinePass(TryEarlyFoldsOnly = true)
    pipeline.nodes[vcn].early_folds_only = true;
    pb_add(fpm, last, "mldst-motion<no-split-footer-bb>");
    if pb_cl.enable_newgvn pb_unsupported("newgvn (-enable-newgvn)");
    pb_add(fpm, last, "gvn<>");
    pb_add(fpm, last, "sccp");
    pb_add(fpm, last, "bdce");
    pb_add(fpm, last, INSTCOMBINE);
    if pb_cl.enable_dfa_jump_thread pb_add(fpm, last, "dfa-jump-threading");
    pb_add(fpm, last, "jump-threading");
    pb_add(fpm, last, "correlated-propagation");
    pb_add(fpm, last, "adce");
    pb_add(fpm, last, "memcpyopt");
    pb_add(fpm, last, "dse");
    pb_add(fpm, last, "move-auto-init");
    licm_last: s32 = -1;
    pb_add(pb_loop_adaptor(fpm, last, true), *licm_last, pb_licm(true));
    pb_add(fpm, last, "coro-elide");
    o := SCFG_RANGE;
    o.switch_to_arithmetic = true; o.hoist_common_insts = true; o.sink_common_insts = true;
    pb_add(fpm, last, pb_simplifycfg(o));
    pb_add(fpm, last, INSTCOMBINE);
}

// ---------------------------------------------------------------- the inliner

// buildInlinerPipeline: a ModuleInlinerWrapperPass (INLINER_WRAPPER: its module passes, the CGSCC walk, the late
// module passes)
build_inliner_pipeline :: (mpm: s32, last: *s32, level: Opt_Level) {
    if pto.inliner_threshold != -1 pb_unsupported("PipelineTuningOptions::InlinerThreshold");
    w := pb_node(mpm, last, .INLINER_WRAPPER_PM, "inliner-ml-advisor-release");
    pipeline.nodes[w].info = lookup_pass("inliner-wrapper");
    wlast: s32 = -1;
    if pb_cl.enable_global_analyses {
        pb_add(w, *wlast, "require<globals-aa>");
        pb_add(w, *wlast, "function(invalidate<aa>)");
    }
    pb_add(w, *wlast, "require<profile-summary>");

    // ModuleToPostOrderCGSCCPassAdaptor(DevirtSCCRepeatedPass(PM, MaxDevirtIterations)) (no devirt node for 0)
    ad := pb_node(w, *wlast, .CGSCC_ADAPTOR, "cgscc");
    adlast: s32 = -1;
    holder := ad; holder_last := *adlast;
    dv_last: s32 = -1;
    if inl_opts.max_devirt_iterations != 0 {
        dv := pb_node(ad, *adlast, .DEVIRT, sprint("devirt<%>", inl_opts.max_devirt_iterations));
        pipeline.nodes[dv].count = cast(s32) inl_opts.max_devirt_iterations;
        holder = dv; holder_last = *dv_last;
    }
    cg := pb_node(holder, holder_last, .CGSCC_PM, "cgscc");
    cglast: s32 = -1;
    if pb_cl.mandatory_inlining_first {
        n := pb_add(cg, *cglast, "inline<only-mandatory>");
        pipeline.nodes[n].opt_level = cast(s8) level.speed;
    }
    n := pb_add(cg, *cglast, "inline");
    pipeline.nodes[n].opt_level = cast(s8) level.speed;   // the advisor's getInlineParamsFromOptLevel(Level)

    if pb_cl.attributor_run == "cgscc" || pb_cl.attributor_run == "full" pb_unsupported("attributor-cgscc (-attributor-enable)");
    if pb_cl.attributor_run == "cgscc-light" || pb_cl.attributor_run == "light" pb_unsupported("attributor-light-cgscc (-attributor-enable)");
    pb_add(cg, *cglast, "function-attrs<skip-non-recursive-function-attrs>");
    if level.speed == 3 pb_add(cg, *cglast, "argpromotion");
    if level.speed == 2 || level.speed == 3 pb_add(cg, *cglast, "openmp-opt-cgscc");

    fa := pb_node(cg, *cglast, .CGSCC_FN_ADAPTOR, ifx pto.eagerly_invalidate_analyses then "function<eager-inv;no-rerun>" else "function<no-rerun>");
    pipeline.nodes[fa].eager_inv = pto.eagerly_invalidate_analyses;
    pipeline.nodes[fa].no_rerun = true;
    falast: s32 = -1;
    build_function_simplification_pipeline(fa, *falast, level);

    pb_add(cg, *cglast, "function-attrs");
    pb_add(cg, *cglast, "function(require<should-not-run-function-passes>)");
    if pb_phase != .THIN_PRE_LINK {
        pb_add(cg, *cglast, "coro-split");
        pb_add(cg, *cglast, "coro-annotation-elide");
    }

    // MIWP.addLateModulePass (not printed by printPipeline)
    pipeline.nodes[w].late_first = cast(s32) pipeline.nodes.count;   // the FUNCTION_ADAPTOR created next
    pb_add(w, *wlast, "function(invalidate<should-not-run-function-passes>)");
}

// buildModuleInlinerPipeline (-enable-module-inliner)
build_module_inliner_pipeline :: (mpm: s32, last: *s32, level: Opt_Level) {
    n := pb_add(mpm, last, "module-inline");
    pipeline.nodes[n].opt_level = cast(s8) level.speed;
    fa := pb_function_adaptor(mpm, last, pto.eagerly_invalidate_analyses);
    falast: s32 = -1;
    build_function_simplification_pipeline(fa, *falast, level);
    if pb_phase != .THIN_PRE_LINK {
        pb_add(mpm, last, "cgscc(coro-split)");
        pb_add(mpm, last, "cgscc(coro-annotation-elide)");
    }
}

// ---------------------------------------------------------------- module pipelines

build_module_simplification_pipeline :: (mpm: s32, last: *s32, level: Opt_Level) {
    if pb_phase == .THIN_POST_LINK pb_add(mpm, last, "pgo-icall-prom");   // PGOIndirectCallPromotion(InLTO = true)
    if pb_phase != .THIN_POST_LINK {
    pb_add(mpm, last, "inferattrs");
    pb_add(mpm, last, "coro-early");
    {
        fa := pb_function_adaptor(mpm, last, pto.eagerly_invalidate_analyses);
        l: s32 = -1;
        pb_add(fa, *l, "ee-instrument<>");
        pb_add(fa, *l, "lower-expect");
        pb_add(fa, *l, pb_simplifycfg(SCFG_DEFAULT));
        pb_add(fa, *l, "sroa<modify-cfg>");
        pb_add(fa, *l, "early-cse<>");
        if level.speed == 3 pb_add(fa, *l, "callsite-splitting");
    }
    }
    pb_add(mpm, last, "openmp-opt");
    if pb_cl.attributor_run == "module" || pb_cl.attributor_run == "full" pb_unsupported("attributor (-attributor-enable)");
    if pb_cl.attributor_run == "module-light" || pb_cl.attributor_run == "light" pb_unsupported("attributor-light (-attributor-enable)");
    if pb_phase == .THIN_POST_LINK pb_add(mpm, last, "drop-type-tests<assume>");
    // IPSCCPOptions(AllowFuncSpec = !isLTOPreLink(Phase)); printPipeline does not show it
    ipn := pb_add(mpm, last, "ipsccp");
    pipeline.nodes[ipn].no_func_spec = is_lto_pre_link();
    pb_add(mpm, last, "called-value-propagation");
    pb_add(mpm, last, "globalopt");
    {
        fa := pb_function_adaptor(mpm, last, pto.eagerly_invalidate_analyses);
        l: s32 = -1;
        pb_add(fa, *l, "mem2reg");
        pb_add(fa, *l, INSTCOMBINE);
        pb_add(fa, *l, pb_simplifycfg(SCFG_RANGE));
    }
    // no PGO / contextual profiling: none of the PGO instrumentation passes
    n := pb_add(mpm, last, "always-inline");   // AlwaysInlinerPass(InsertLifetimeIntrinsics = true)
    _ = n;
    if pb_cl.enable_module_inliner build_module_inliner_pipeline(mpm, last, level);
    else build_inliner_pipeline(mpm, last, level);
    pb_add(mpm, last, "deadargelim");
    if pb_phase == .THIN_POST_LINK pb_add(mpm, last, "simplify-type-tests");
    if pb_phase != .THIN_PRE_LINK pb_add(mpm, last, "coro-cleanup");
    pb_add(mpm, last, "globalopt");
    pb_add(mpm, last, "globaldce");
}

add_vector_passes :: (fpm: s32, last: *s32, level: Opt_Level) {
    full_post := pb_phase == .FULL_POST_LINK;
    pb_add(fpm, last, tprint("loop-vectorize<%interleave-forced-only;%vectorize-forced-only;>",
        ifx pto.loop_interleaving then "no-" else "", ifx pto.loop_vectorization then "no-" else ""));
    if !is_lto_pre_link() pb_add(fpm, last, "drop-unnecessary-assumes<drop-deref>");
    pb_add(fpm, last, "infer-alignment");
    if full_post {
        if pb_cl.enable_unroll_and_jam && pto.loop_unrolling pb_unsupported("loop-unroll-and-jam (-enable-unroll-and-jam)");
        pb_loop_unroll(fpm, last, level);
        pb_add(fpm, last, "transform-warning");
        pb_add(fpm, last, "sroa<preserve-cfg;aggregate-to-vector>");
    }
    if !full_post pb_add(fpm, last, "loop-load-elim");
    pb_add(fpm, last, INSTCOMBINE);
    if level.speed > 1 && pb_cl.extra_vectorizer_passes pb_unsupported("extra-vector-passes (-extra-vectorizer-passes)");
    o := SCFG_RANGE;
    o.forward_switch_cond = true; o.switch_to_arithmetic = true; o.switch_to_lookup = true; o.keep_loops = false;
    o.hoist_common_insts = true; o.sink_common_insts = true;
    pb_add(fpm, last, pb_simplifycfg(o));
    if full_post {
        pb_add(fpm, last, "sccp");
        pb_add(fpm, last, INSTCOMBINE);
        pb_add(fpm, last, "bdce");
    }
    if pto.slp_vectorization pb_add(fpm, last, "slp-vectorizer");
    pb_add(fpm, last, "vector-combine");
    if !full_post {
        pb_add(fpm, last, INSTCOMBINE);
        if pb_cl.enable_unroll_and_jam && pto.loop_unrolling pb_unsupported("loop-unroll-and-jam (-enable-unroll-and-jam)");
        pb_loop_unroll(fpm, last, level);
        pb_add(fpm, last, "transform-warning");
        pb_add(fpm, last, "sroa<preserve-cfg;aggregate-to-vector>");
    }
    pb_add(fpm, last, "infer-alignment");
    pb_add(fpm, last, INSTCOMBINE);
    l: s32 = -1;
    pb_add(pb_loop_adaptor(fpm, last, true), *l, pb_licm(true));
    pb_add(fpm, last, "alignment-from-assumptions");
}

build_module_optimization_pipeline :: (mpm: s32, last: *s32, level: Opt_Level) {
    if pb_cl.enable_partial_inlining pb_unsupported("partial-inliner (-enable-partial-inlining)");
    if !is_lto_pre_link() pb_add(mpm, last, "elim-avail-extern");
    pb_add(mpm, last, "rpo-function-attrs");
    if pb_cl.enable_global_analyses pb_add(mpm, last, "recompute-globalsaa");

    fa := pb_function_adaptor(mpm, last, pto.eagerly_invalidate_analyses);
    l: s32 = -1;
    if !is_lto_pre_link() pb_add(fa, *l, "drop-unnecessary-assumes");
    if pb_cl.enable_loop_versioning_licm pb_unsupported("loop-versioning-licm (-enable-loop-versioning-licm)");
    pb_add(fa, *l, "float2int");
    pb_add(fa, *l, "lower-constant-intrinsics");
    if pb_cl.enable_matrix pb_unsupported("lower-matrix-intrinsics (-enable-matrix)");
    if pb_cl.enable_chr && level.speed == 3 pb_add(fa, *l, "chr");
    {
        ll: s32 = -1;
        la := pb_loop_adaptor(fa, *l, false);
        pb_add(la, *ll, pb_rotate(true));
        pb_add(la, *ll, "loop-deletion");
        if pto.loop_interchange pb_add(la, *ll, "loop-interchange");
    }
    if pto.loop_fusion pb_unsupported("loop-fusion (-enable-loopfusion)");
    pb_add(fa, *l, "loop-distribute");
    pb_add(fa, *l, "inject-tli-mappings");
    add_vector_passes(fa, *l, level);
    pb_add(fa, *l, "loop-sink");
    pb_add(fa, *l, "instsimplify");
    pb_add(fa, *l, "div-rem-pairs");
    if pb_cl.enable_merge_icmps pb_add(fa, *l, "mergeicmps");
    pb_add(fa, *l, "expand-memcmp");
    pb_tailcallelim(fa, *l);
    o := SCFG_RANGE;
    o.switch_to_arithmetic = true; o.speculate_unpredictables = true; o.hoist_loads_stores_with_cond_faulting = true;
    pb_add(fa, *l, pb_simplifycfg(o));

    if !is_lto_pre_link() pb_add(mpm, last, "alloc-token");
    if pb_cl.enable_instrumentor pb_unsupported("instrumentor (-enable-instrumentor)");
    if pb_cl.enable_hot_cold_split && !is_lto_pre_link() pb_unsupported("hotcoldsplit (-hot-cold-split)");
    if pb_cl.enable_ir_outliner pb_unsupported("iroutliner (-ir-outliner)");
    pb_add(mpm, last, "globaldce");
    pb_add(mpm, last, "constmerge");
    if pto.merge_functions pb_add(mpm, last, "mergefunc");
    if pto.call_graph_profile && !is_lto_pre_link() pb_add(mpm, last, "cg-profile");   // CGProfilePass(InLTOPostLink): only the symtab of value profiles differs
    if !is_lto_pre_link() pb_add(mpm, last, "rel-lookup-table-converter");
    if pto.devirtualize_speculatively && pb_phase == .NONE pb_unsupported("wholeprogramdevirt (-enable-devirtualize-speculatively)");
    pb_add(mpm, last, "lower-comment-string");
}

build_o0_default_pipeline :: (mpm: s32, last: *s32) {
    pb_add(mpm, last, "function(ee-instrument<>)");
    n := pb_add(mpm, last, "always-inline");   // AlwaysInlinerPass(InsertLifetimeIntrinsics = false)
    pipeline.nodes[n].no_lifetime = true;
    if pto.merge_functions pb_add(mpm, last, "mergefunc");
    if pb_cl.enable_matrix pb_unsupported("lower-matrix-intrinsics (-enable-matrix)");
    // buildCoroWrapper
    cw := pb_node(mpm, last, .CORO_COND, "coro-cond");
    pipeline.nodes[cw].info = lookup_pass("coro-cond");
    cl: s32 = -1;
    pb_add(cw, *cl, "coro-early");
    pb_add(cw, *cl, "cgscc(coro-split)");
    pb_add(cw, *cl, "coro-cleanup");
    pb_add(cw, *cl, "globaldce");
    if !is_lto_pre_link() pb_add(mpm, last, "alloc-token");
    if pb_cl.enable_instrumentor pb_unsupported("instrumentor (-enable-instrumentor)");
    pb_add(mpm, last, "lower-comment-string");
    if is_lto_pre_link() add_required_lto_pre_link_passes(mpm, last);
    pb_add(mpm, last, "function(annotation-remarks)");
}

// addRequiredLTOPreLinkPasses
add_required_lto_pre_link_passes :: (mpm: s32, last: *s32) {
    pb_add(mpm, last, "canonicalize-aliases");
    pb_add(mpm, last, "name-anon-globals");
    pb_add(mpm, last, "assign-guid");
}

build_per_module_default_pipeline :: (mpm_outer: s32, last_outer: *s32, level: Opt_Level) {
    // the result is one ModulePassManager added to the outer one (a pass manager is required: not counted)
    mpm := pb_node(mpm_outer, last_outer, .MODULE_PM, "module");
    last: s32 = -1;
    if level.speed == 0 { build_o0_default_pipeline(mpm, *last); return; }
    if pb_phase == .NONE pb_add(mpm, *last, "memprof-remove-attributes");
    pb_add(mpm, *last, "annotation2metadata");
    pb_add(mpm, *last, "forceattrs");
    if pb_cl.opt_pipeline_trigger_crash pb_unsupported("-opt-pipeline-trigger-crash");
    build_module_simplification_pipeline(mpm, *last, level);
    build_module_optimization_pipeline(mpm, *last, level);
    pb_add(mpm, *last, "function(annotation-remarks)");   // addAnnotationRemarksPass
    if is_lto_pre_link() add_required_lto_pre_link_passes(mpm, *last);
}

// buildThinLTOPreLinkDefaultPipeline
build_thinlto_pre_link_default_pipeline :: (mpm_outer: s32, last_outer: *s32, level: Opt_Level) {
    pb_phase = .THIN_PRE_LINK;
    mpm := pb_node(mpm_outer, last_outer, .MODULE_PM, "module");
    last: s32 = -1;
    if level.speed == 0 { build_o0_default_pipeline(mpm, *last); return; }
    pb_add(mpm, *last, "annotation2metadata");
    pb_add(mpm, *last, "forceattrs");
    build_module_simplification_pipeline(mpm, *last, level);
    if pb_cl.enable_partial_inlining pb_unsupported("partial-inliner (-enable-partial-inlining)");
    pb_add(mpm, *last, "function(annotation-remarks)");
    pb_add(mpm, *last, "lower-comment-string");
    add_required_lto_pre_link_passes(mpm, *last);
}

// buildThinLTODefaultPipeline(Level, ImportSummary = nullptr)
build_thinlto_default_pipeline :: (mpm_outer: s32, last_outer: *s32, level: Opt_Level) {
    pb_phase = .THIN_POST_LINK;
    mpm := pb_node(mpm_outer, last_outer, .MODULE_PM, "module");
    last: s32 = -1;
    pb_add(mpm, *last, "memprof-remove-attributes");
    if level.speed == 0 {
        pb_add(mpm, *last, "drop-type-tests<assume>");
        pb_add_coro_wrapper(mpm, *last);
        pb_add(mpm, *last, "alloc-token");
        pb_add(mpm, *last, "elim-avail-extern");
        pb_add(mpm, *last, "globaldce");
        return;
    }
    build_module_simplification_pipeline(mpm, *last, level);
    build_module_optimization_pipeline(mpm, *last, level);
    pb_add(mpm, *last, "function(annotation-remarks)");
}

// buildCoroWrapper
pb_add_coro_wrapper :: (mpm: s32, last: *s32) {
    cw := pb_node(mpm, last, .CORO_COND, "coro-cond");
    pipeline.nodes[cw].info = lookup_pass("coro-cond");
    cl: s32 = -1;
    pb_add(cw, *cl, "coro-early");
    pb_add(cw, *cl, "cgscc(coro-split)");
    pb_add(cw, *cl, "coro-cleanup");
    pb_add(cw, *cl, "globaldce");
}

// buildLTODefaultPipeline(Level, ExportSummary = nullptr)
build_lto_default_pipeline :: (mpm_outer: s32, last_outer: *s32, level: Opt_Level) {
    pb_phase = .FULL_POST_LINK;
    mpm := pb_node(mpm_outer, last_outer, .MODULE_PM, "module");
    last: s32 = -1;
    pb_add(mpm, *last, "memprof-remove-attributes");
    pb_add(mpm, *last, "cross-dso-cfi");
    if level.speed == 0 {
        pb_add(mpm, *last, "wholeprogramdevirt");
        pb_add(mpm, *last, "lowertypetests");
        pb_add(mpm, *last, "drop-type-tests<assume>");
        pb_add_coro_wrapper(mpm, *last);
        pb_add(mpm, *last, "alloc-token");
        pb_add(mpm, *last, "function(annotation-remarks)");
        return;
    }
    pb_add(mpm, *last, "openmp-opt");   // OpenMPOptPass(FullLTOPostLink)
    pb_add(mpm, *last, "globaldce<vfe-linkage-unit-visibility>");
    pb_add(mpm, *last, "inferattrs");
    if level.speed >= 2 {
        fa := pb_function_adaptor(mpm, *last, pto.eagerly_invalidate_analyses);
        fl: s32 = -1;
        pb_add(fa, *fl, "callsite-splitting");
        pb_add(mpm, *last, "pgo-icall-prom");
        pb_add(mpm, *last, "cgscc(function-attrs,argpromotion,function(sroa<modify-cfg>))");
        pb_add(mpm, *last, "ipsccp");   // AllowFuncSpec = true
        pb_add(mpm, *last, "called-value-propagation");
    }
    pb_add(mpm, *last, "rpo-function-attrs");
    pb_add(mpm, *last, "globalsplit");
    pb_add(mpm, *last, "wholeprogramdevirt");
    pb_add(mpm, *last, "norecurse-lto-inference");
    if level.speed == 1 {
        pb_add(mpm, *last, "lowertypetests");
        pb_add(mpm, *last, "drop-type-tests<assume>");
        pb_add_coro_wrapper(mpm, *last);
        pb_add(mpm, *last, "alloc-token");
        pb_add(mpm, *last, "function(annotation-remarks)");
        return;
    }
    pb_add(mpm, *last, "coro-early");
    pb_add(mpm, *last, "globalopt");
    pb_add(mpm, *last, "function(mem2reg)");
    pb_add(mpm, *last, "constmerge");
    pb_add(mpm, *last, "deadargelim");
    {
        fa := pb_function_adaptor(mpm, *last, pto.eagerly_invalidate_analyses);
        fl: s32 = -1;
        pb_add(fa, *fl, INSTCOMBINE);
        if level.speed >= 2 pb_add(fa, *fl, "aggressive-instcombine");
    }
    pb_add(mpm, *last, "expand-variadics");
    if pb_cl.enable_module_inliner pb_unsupported("module-inline (-enable-module-inliner) in the LTO pipeline");
    {
        // ModuleInlinerWrapperPass(getInlineParamsFromOptLevel(Level), MandatoryFirst = true, ...): no module
        // passes, no devirt wrapper (MaxDevirtIterations = 0)
        w := pb_node(mpm, *last, .INLINER_WRAPPER_PM, "inliner-wrapper");
        pipeline.nodes[w].info = lookup_pass("inliner-wrapper");
        wlast: s32 = -1;
        ad := pb_node(w, *wlast, .CGSCC_ADAPTOR, "cgscc");
        adlast: s32 = -1;
        cg := pb_node(ad, *adlast, .CGSCC_PM, "cgscc");
        cglast: s32 = -1;
        n := pb_add(cg, *cglast, "inline<only-mandatory>");
        pipeline.nodes[n].opt_level = cast(s8) level.speed;
        n = pb_add(cg, *cglast, "inline");
        pipeline.nodes[n].opt_level = cast(s8) level.speed;
    }
    pb_add(mpm, *last, "globalopt");
    pb_add(mpm, *last, "openmp-opt");
    pb_add(mpm, *last, "globaldce<vfe-linkage-unit-visibility>");
    pb_add(mpm, *last, "cgscc(argpromotion,coro-split,coro-annotation-elide)");
    {
        fa := pb_function_adaptor(mpm, *last, pto.eagerly_invalidate_analyses);
        fl: s32 = -1;
        pb_add(fa, *fl, INSTCOMBINE);
        if pb_cl.enable_constraint_elimination pb_add(fa, *fl, "constraint-elimination");
        pb_add(fa, *fl, "jump-threading");
        pb_add(fa, *fl, "sroa<modify-cfg>");
        pb_tailcallelim(fa, *fl);
    }
    pb_add(mpm, *last, "cgscc(function-attrs)");
    if pb_cl.enable_global_analyses {
        pb_add(mpm, *last, "require<globals-aa>");
        pb_add(mpm, *last, "function(invalidate<aa>)");
    }
    // MainFPM is filled first, but cgscc(openmp-opt-cgscc) is added to the MPM before it
    pb_add(mpm, *last, "cgscc(openmp-opt-cgscc)");
    main_fa := pb_function_adaptor(mpm, *last, pto.eagerly_invalidate_analyses);
    ml: s32 = -1;
    {
        ll: s32 = -1;
        pb_add(pb_loop_adaptor(main_fa, *ml, true), *ll, pb_licm(true));
    }
    if pb_cl.enable_newgvn pb_unsupported("newgvn (-enable-newgvn)");
    pb_add(main_fa, *ml, "gvn<>");
    pb_add(main_fa, *ml, "memcpyopt");
    pb_add(main_fa, *ml, "dse");
    pb_add(main_fa, *ml, "move-auto-init");
    pb_add(main_fa, *ml, "mldst-motion<no-split-footer-bb>");
    {
        ll: s32 = -1;
        la := pb_loop_adaptor(main_fa, *ml, false);
        if pb_cl.enable_loop_flatten pb_unsupported("loop-flatten (-enable-loop-flatten)");
        pb_add(la, *ll, "indvars");
        pb_add(la, *ll, "loop-deletion");
        pb_loop_unroll_full(la, *ll, level);
    }
    pb_add(main_fa, *ml, "loop-distribute");
    add_vector_passes(main_fa, *ml, level);
    pb_add(main_fa, *ml, "jump-threading");
    pb_add(mpm, *last, "lowertypetests");
    pb_add(mpm, *last, "drop-type-tests<assume>");
    if pb_cl.enable_hot_cold_split pb_unsupported("hotcoldsplit (-hot-cold-split)");
    {
        fa := pb_function_adaptor(mpm, *last, false);
        fl: s32 = -1;
        pb_add(fa, *fl, "loop-sink");
        pb_add(fa, *fl, "div-rem-pairs");
        if pb_cl.enable_merge_icmps pb_add(fa, *fl, "mergeicmps");
        pb_add(fa, *fl, "expand-memcmp");
        o := SCFG_RANGE;
        o.switch_to_arithmetic = true; o.hoist_common_insts = true; o.speculate_unpredictables = true;
        pb_add(fa, *fl, pb_simplifycfg(o));
    }
    pb_add(mpm, *last, "elim-avail-extern");
    pb_add(mpm, *last, "globaldce<vfe-linkage-unit-visibility>");
    if pto.merge_functions pb_add(mpm, *last, "mergefunc");
    pb_add(mpm, *last, "rel-lookup-table-converter");
    if pto.call_graph_profile pb_add(mpm, *last, "cg-profile");
    pb_add(mpm, *last, "coro-cleanup");
    pb_add(mpm, *last, "alloc-token");
    pb_add(mpm, *last, "function(annotation-remarks)");
}

// ---------------------------------------------------------------- printing (-jai-print-pipeline)

// The node tree in the format of `opt -print-pipeline-passes` (exact only for pipelines built here, whose leaf
// names are LLVM's printed names).
pb_print_pipeline :: (n: s32, sb: *String_Builder) {
    node := *pipeline.nodes[n];
    children :: (n: s32, sb: *String_Builder, stop: s32 = -1) {
        c := pipeline.nodes[n].first_child;
        first := true;
        while c >= 0 && c != stop {
            if !first append(sb, ",");
            first = false;
            pb_print_pipeline(c, sb);
            c = pipeline.nodes[c].next;
        }
    }
    if node.kind == {
        case .MODULE_PM; #through;
        case .CGSCC_PM; children(n, sb);
        case .INLINER_WRAPPER_PM;
            // ModuleInlinerWrapperPass::printPipeline: its MPM, then cgscc(devirt<N>(PM)); the late passes are not
            // printed
            stop: s32 = -1;
            if node.late_first >= 0 stop = node.late_first;
            children(n, sb, stop);
        case .FUNCTION_ADAPTOR; #through;
        case .CGSCC_FN_ADAPTOR; #through;
        case .LOOP_ADAPTOR; #through;
        case .CGSCC_ADAPTOR; #through;
        case .DEVIRT; #through;
        case .CORO_COND;
            name := node.name;
            if node.kind == .FUNCTION_ADAPTOR name = ifx node.eager_inv then "function<eager-inv>" else "function";
            append(sb, name); append(sb, "(");
            children(n, sb);
            append(sb, ")");
        case .EXTRA_LOOP_UNSWITCH;
            append(sb, "extra-simple-loop-unswitch-passes");
        case;
            // DropUnnecessaryAssumesPass::printPipeline does not print DropDereferenceable
            if node.name == "drop-unnecessary-assumes<drop-deref>" append(sb, "drop-unnecessary-assumes");
            else append(sb, node.name);
    }
}
