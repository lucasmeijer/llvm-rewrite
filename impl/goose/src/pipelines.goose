// The default optimization pipelines: `-O0`..`-O3` and `-passes='default<O#>'`.
// Port of llvm/lib/Passes/PassBuilderPipelines.cpp: PipelineTuningOptions (with opt's NewPMDriver overrides and
// PassBuilder.cpp's setupOptionsForPipelineAlias), buildPerModuleDefaultPipeline, buildModuleSimplificationPipeline,
// buildInlinerPipeline (ModuleInlinerWrapperPass), buildModuleInlinerPipeline, buildFunctionSimplificationPipeline,
// buildO1FunctionSimplificationPipeline, addVectorPasses, buildModuleOptimizationPipeline, buildO0DefaultPipeline
// (with buildCoroWrapper) and the cl::opts of PassBuilderPipelines.cpp. Phase is always ThinOrFullLTOPhase::None,
// there is no PGOOptions, and every extension point (invoke*EPCallbacks) is empty: opt registers no callbacks
// without plugins / -passes-ep-* options. Os / Oz fail like parseOptLevel.
//
// The pipeline is built as PNode trees (passmgr.goose, DESIGN.md §9). Leaf passes are created from the name LLVM's
// printPipeline prints for them, through the textual parser, so `-goose-print-pipeline` can be diffed against
// `opt -print-pipeline-passes`; constructor arguments printPipeline does not show are set on the node afterwards
// (LoopFullUnrollPass's level, TailCallElimPass's UpdateFunctionEntryCount, VectorCombinePass's TryEarlyFoldsOnly,
// AlwaysInlinerPass's InsertLifetimeIntrinsics, the ModuleInlinerWrapperPass's InlineParams). The structures with
// no textual form are their own node kinds: PK_MODULE with required = false (ModuleInlinerWrapperPass, counted by
// -opt-bisect-limit as "inliner-ml-advisor-release"), PK_EXTRA (ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch>
// with its simple-loop-unswitch inside), PK_CORO_COND (CoroConditionalWrapper).
import std;
import ir;
import flags;
import passmgr;
import loop_unroll_pass;

// PipelineTuningOptions after NewPMDriver (PTO.LoopUnrolling = !DisableLoopUnrolling, PTO.LoopFusion =
// EnableLoopFusion) and setupOptionsForPipelineAlias (LoopVectorization / SLPVectorization = level >= O2).
var pto_loop_interleaving: bool = true;
var pto_loop_vectorization: bool = true;
var pto_slp_vectorization: bool = false;
var pto_loop_unrolling: bool = true;
var pto_loop_interchange: bool = false;
var pto_loop_fusion: bool = false;
var pto_call_graph_profile: bool = true;
var pto_merge_functions: bool = false;
var pto_eager_inv: bool = true;
var pto_devirt_spec: bool = false;

fn pb_init_pto(level: i64) {
    pto_loop_interleaving = true;
    pto_loop_vectorization = level >= 2;
    pto_slp_vectorization = level >= 2;
    pto_loop_unrolling = !flag_bool("disable-loop-unrolling", false);
    pto_loop_interchange = flag_bool("enable-loopinterchange", true);
    pto_loop_fusion = flag_bool("enable-loopfusion", false);
    pto_call_graph_profile = true;
    pto_merge_functions = flag_bool("enable-merge-functions", false);
    pto_eager_inv = flag_bool("eagerly-invalidate-analyses", true);
    pto_devirt_spec = flag_bool("enable-devirtualize-speculatively", false);
}

fn pb_unsupported(what: const u8[:]) {
    perr_pipeline(str("default pipeline: ", what, " is not implemented yet in the Goose opt"));
}

// The cl::opts of PassBuilderPipelines.cpp whose non-default value adds passes we do not build.
fn pb_check_cl_opts() {
    if flag_given("inline-advisor") || flag_given("enable-ml-inliner") {
        let v = flag_str(if flag_given("enable-ml-inliner") { "enable-ml-inliner" } else { "inline-advisor" });
        if v != "default" { pb_unsupported(str("-enable-ml-inliner=", v)); }
    }
    if flag_bool("enable-partial-inlining", false) { pb_unsupported("partial-inliner (-enable-partial-inlining)"); }
    if flag_bool("extra-vectorizer-passes", false) { pb_unsupported("the extra vector passes (-extra-vectorizer-passes)"); }
    if flag_bool("enable-newgvn", false) { pb_unsupported("newgvn (-enable-newgvn)"); }
    if flag_bool("enable-unroll-and-jam", false) { pb_unsupported("loop-unroll-and-jam (-enable-unroll-and-jam)"); }
    if flag_bool("enable-loop-flatten", false) { pb_unsupported("loop-flatten (-enable-loop-flatten)"); }
    if flag_bool("enable-instrumentor", false) { pb_unsupported("instrumentor (-enable-instrumentor)"); }
    if flag_bool("hot-cold-split", false) { pb_unsupported("hotcoldsplit (-hot-cold-split)"); }
    if flag_bool("ir-outliner", false) { pb_unsupported("iroutliner (-ir-outliner)"); }
    if flag_bool("enable-gvn-hoist", false) { pb_unsupported("gvn-hoist (-enable-gvn-hoist)"); }
    if flag_bool("enable-gvn-sink", false) { pb_unsupported("gvn-sink (-enable-gvn-sink)"); }
    if flag_bool("enable-matrix", false) { pb_unsupported("lower-matrix-intrinsics (-enable-matrix)"); }
    if flag_bool("enable-loop-versioning-licm", false) { pb_unsupported("loop-versioning-licm (-enable-loop-versioning-licm)"); }
    if flag_bool("opt-pipeline-trigger-crash", false) { pb_unsupported("-opt-pipeline-trigger-crash"); }
    if flag_bool("enable-module-inliner", false) { pb_unsupported("the module inliner pipeline (-enable-module-inliner)"); }
    if flag_bool("enable-knowledge-retention", false) { pb_unsupported("assume-simplify (-enable-knowledge-retention)"); }
    if flag_given("attributor-enable") && flag_str("attributor-enable") != "none" { pb_unsupported("the Attributor (-attributor-enable)"); }
    if pto_loop_fusion { pb_unsupported("loop-fusion (-enable-loopfusion)"); }
    if pto_merge_functions { pb_unsupported("mergefunc (-enable-merge-functions)"); }
    if pto_devirt_spec { pb_unsupported("wholeprogramdevirt (-enable-devirtualize-speculatively)"); }
    if flag_given("inline-threshold-pipeline") { pb_unsupported("-inline-threshold-pipeline"); }
}

// ---------------------------------------------------------------------------------------------
// Building blocks

fn pb_last_child(p: i32) -> i32 {
    var c = pnodes[p].first;
    if c < 0 { return -1; }
    while pnodes[c].next >= 0 { c = pnodes[c].next; }
    return c;
}
fn pb_link(p: i32, c: i32) -> i32 {
    link_child(p, pb_last_child(p), c);
    return c;
}

// Adds the passes of pipeline text `text` (LLVM's printed names) to the pass manager node p; returns the last
// node added.
fn pb_add(p: i32, text: const u8[:]) -> i32 {
    var e = parse_pipeline_text(text);
    if e < 0 { fatal(str("internal: default pipeline text '", text, "'")); }
    let k = pnodes[p].kind as i64;
    var last: i32 = -1;
    while e >= 0 {
        var c: i32 = -1;
        if k == PK_MODULE || k == PK_CORO_COND { c = parse_module_elem(e); }
        else if k == PK_FUNCTION || k == PK_CGFN { c = parse_function_elem(e); }
        else if k == PK_LOOP || k == PK_LPM || k == PK_EXTRA { c = parse_loop_elem(e); }
        else if k == PK_CGSCC || k == PK_CGSCC_PM || k == PK_DEVIRT { c = parse_cgscc_elem(e); }
        else { fatal("internal: pb_add on a node without passes"); }
        last = pb_link(p, c);
        e = pelems[e].next;
    }
    return last;
}

// createModuleToFunctionPassAdaptor(FPM, EagerlyInvalidate)
fn pb_function_adaptor(mpm: i32, eager: bool) -> i32 {
    let n = new_pnode(PK_FUNCTION, 0, if eager { 1 } else { 0 }, true, intern(if eager { "function<eager-inv>" } else { "function" }));
    return pb_link(mpm, n);
}
// createFunctionToLoopPassAdaptor(LPM, UseMemorySSA)
fn pb_loop_adaptor(fpm: i32, mssa: bool) -> i32 {
    let n = new_loop_adaptor(mssa, intern(if mssa { "loop-mssa" } else { "loop" }));
    return pb_link(fpm, n);
}
fn pb_end_loop_adaptor(ad: i32) { check_loop_nest_mode(ad); }

// SimplifyCFGPass::printPipeline of the SimplifyCFGOptions the pipelines construct
struct PbScfg { fwd: bool, range: bool, arith: bool, lookup: bool, keep_loops: bool, hoist: bool, hoist_ldst: bool,
                sink: bool, spec_unpred: bool }
fn pb_scfg_default() -> PbScfg {
    PbScfg { fwd: false, range: false, arith: false, lookup: false, keep_loops: true, hoist: false, hoist_ldst: false,
             sink: false, spec_unpred: false }
}
// SimplifyCFGOptions().convertSwitchRangeToICmp(true)
fn pb_scfg_range() -> PbScfg { var o = pb_scfg_default(); o.range = true; return o; }
fn pb_opt(b: bool, s: const u8[:]) -> u8[] { if b { str(s) } else { str("no-", s) } }
fn pb_simplifycfg(o: PbScfg) -> u8[] {
    return str("simplifycfg<bonus-inst-threshold=1;", pb_opt(o.fwd, "forward-switch-cond"), ";",
        pb_opt(o.range, "switch-range-to-icmp"), ";", pb_opt(o.arith, "switch-to-arithmetic"), ";",
        pb_opt(o.lookup, "switch-to-lookup"), ";", pb_opt(o.keep_loops, "keep-loops"), ";",
        pb_opt(o.hoist, "hoist-common-insts"), ";", pb_opt(o.hoist_ldst, "hoist-loads-stores-with-cond-faulting"), ";",
        pb_opt(o.sink, "sink-common-insts"), ";speculate-blocks;simplify-cond-branch;",
        pb_opt(o.spec_unpred, "speculate-unpredictables"), ">");
}
let PB_INSTCOMBINE = "instcombine<max-iterations=1;no-verify-fixpoint>";

// LICMPass(PTO.LicmMssaOptCap, PTO.LicmMssaNoAccForPromotionCap, AllowSpeculation)
fn pb_licm(spec: bool) -> const u8[:] { if spec { "licm<allowspeculation>" } else { "licm<no-allowspeculation>" } }

// LoopFullUnrollPass(Level, OnlyWhenForced = !PTO.LoopUnrolling, PTO.ForgetAllSCEVInLoopUnroll)
fn pb_loop_unroll_full(lpm: i32, level: i64) {
    let n = pb_add(lpm, "loop-unroll-full");
    pnodes[n].arg = 0x100 | (level as i32) | (if pto_loop_unrolling { 0 } else { 0x10 });
}
// LoopUnrollPass(LoopUnrollOptions(Level, OnlyWhenForced = !PTO.LoopUnrolling, PTO.ForgetAllSCEVInLoopUnroll))
fn pb_loop_unroll(fpm: i32, level: i64) {
    let n = pb_add(fpm, str("loop-unroll<O", level, ">"));
    lu_opt_table[pnodes[n].arg].only_when_forced = !pto_loop_unrolling;
}
// TailCallElimPass(UpdateFunctionEntryCount = isInstrumentedPGOUse()): false without PGO
fn pb_tailcallelim(fpm: i32) {
    let n = pb_add(fpm, "tailcallelim");
    pnodes[n].arg = 1;
}

// ---------------------------------------------------------------------------------------------
// The function simplification pipelines

fn pb_o1_function_simplification(fpm: i32, level: i64) {
    pb_add(fpm, "sroa<modify-cfg>");
    pb_add(fpm, "early-cse<memssa>");
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, PB_INSTCOMBINE);
    pb_add(fpm, "libcalls-shrinkwrap");
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, "reassociate");
    let lpm1 = pb_loop_adaptor(fpm, true);
    pb_add(lpm1, "loop-instsimplify");
    pb_add(lpm1, "loop-simplifycfg");
    pb_add(lpm1, pb_licm(false));
    pb_add(lpm1, "loop-rotate<header-duplication;no-prepare-for-lto;no-check-exit-count>");
    pb_add(lpm1, pb_licm(true));
    pb_add(lpm1, "simple-loop-unswitch<no-nontrivial;trivial>");
    pb_end_loop_adaptor(lpm1);
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, PB_INSTCOMBINE);
    let lpm2 = pb_loop_adaptor(fpm, false);
    pb_add(lpm2, "loop-idiom");
    pb_add(lpm2, "indvars");
    pb_add(lpm2, "loop-deletion");
    pb_loop_unroll_full(lpm2, level);
    pb_end_loop_adaptor(lpm2);
    pb_add(fpm, "sroa<modify-cfg>");
    pb_add(fpm, "memcpyopt");
    pb_add(fpm, "sccp");
    pb_add(fpm, "bdce");
    pb_add(fpm, PB_INSTCOMBINE);
    pb_add(fpm, "coro-elide");
    pb_add(fpm, "adce");
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, PB_INSTCOMBINE);
}

fn pb_function_simplification(fpm: i32, level: i64) {
    if level == 1 { pb_o1_function_simplification(fpm, level); return; }
    pb_add(fpm, "sroa<modify-cfg>");
    pb_add(fpm, "early-cse<memssa>");
    pb_add(fpm, "speculative-execution<only-if-divergent-target>");
    pb_add(fpm, "jump-threading");
    pb_add(fpm, "correlated-propagation");
    if flag_bool("enable-jump-table-to-switch", true) { pb_add(fpm, "jump-table-to-switch"); }
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, PB_INSTCOMBINE);
    pb_add(fpm, "aggressive-instcombine");
    pb_add(fpm, "libcalls-shrinkwrap");
    pb_tailcallelim(fpm);
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, "reassociate");
    if flag_bool("enable-constraint-elimination", true) { pb_add(fpm, "constraint-elimination"); }
    let unswitch = if level == 3 { "simple-loop-unswitch<nontrivial;trivial>" } else { "simple-loop-unswitch<no-nontrivial;trivial>" };
    let lpm1 = pb_loop_adaptor(fpm, true);
    pb_add(lpm1, "loop-instsimplify");
    pb_add(lpm1, "loop-simplifycfg");
    pb_add(lpm1, pb_licm(false));
    pb_add(lpm1, "loop-rotate<header-duplication;no-prepare-for-lto;no-check-exit-count>");
    pb_add(lpm1, pb_licm(true));
    pb_add(lpm1, unswitch);
    pb_end_loop_adaptor(lpm1);
    pb_add(fpm, pb_simplifycfg(pb_scfg_range()));
    pb_add(fpm, PB_INSTCOMBINE);
    let lpm2 = pb_loop_adaptor(fpm, false);
    pb_add(lpm2, "loop-idiom");
    pb_add(lpm2, "indvars");
    {
        // ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch> with SimpleLoopUnswitchPass(NonTrivial = O3)
        let ex = pb_link(lpm2, new_pnode(PK_EXTRA, 0, 0, true, intern("extra-simple-loop-unswitch-passes")));
        pb_add(ex, unswitch);
    }
    pb_add(lpm2, "loop-deletion");
    pb_loop_unroll_full(lpm2, level);
    pb_end_loop_adaptor(lpm2);
    pb_add(fpm, "sroa<modify-cfg>");
    let vc = pb_add(fpm, "vector-combine");   // VectorCombinePass(TryEarlyFoldsOnly = true)
    pnodes[vc].arg = 1;
    pb_add(fpm, "mldst-motion<no-split-footer-bb>");
    pb_add(fpm, "gvn<>");
    pb_add(fpm, "sccp");
    pb_add(fpm, "bdce");
    pb_add(fpm, PB_INSTCOMBINE);
    if flag_bool("enable-dfa-jump-thread", true) { pb_add(fpm, "dfa-jump-threading"); }
    pb_add(fpm, "jump-threading");
    pb_add(fpm, "correlated-propagation");
    pb_add(fpm, "adce");
    pb_add(fpm, "memcpyopt");
    pb_add(fpm, "dse");
    pb_add(fpm, "move-auto-init");
    let lp = pb_loop_adaptor(fpm, true);
    pb_add(lp, pb_licm(true));
    pb_end_loop_adaptor(lp);
    pb_add(fpm, "coro-elide");
    var o = pb_scfg_range();
    o.arith = true; o.hoist = true; o.sink = true;
    pb_add(fpm, pb_simplifycfg(o));
    pb_add(fpm, PB_INSTCOMBINE);
}

// ---------------------------------------------------------------------------------------------
// The inliner: buildInlinerPipeline returns a ModuleInlinerWrapperPass. Its node is a module pass manager that
// bisect counts (required = false), arg = the level + 1 (the InlineAdvisor's getInlineParamsFromOptLevel). Its
// children: the module passes, the CGSCC adaptor, then the late module passes (the last child).
fn pb_inliner_pipeline(mpm: i32, level: i64) {
    let w = pb_link(mpm, new_pnode(PK_MODULE, 0, (level + 1) as i32, false, intern("inliner-ml-advisor-release")));
    if flag_bool("enable-global-analyses", true) {
        pb_add(w, "require<globals-aa>");
        pb_add(w, "function(invalidate<aa>)");
    }
    pb_add(w, "require<profile-summary>");
    // ModuleToPostOrderCGSCCPassAdaptor(DevirtSCCRepeatedPass(MainCGPipeline, MaxDevirtIterations))
    let ad = pb_link(w, new_pnode(PK_CGSCC, 0, 0, true, intern("cgscc")));
    let maxdv = flag_int("max-devirt-iterations", 4);
    var cg = ad;
    if maxdv != 0 {
        cg = pb_link(ad, new_pnode(PK_DEVIRT, 0, maxdv as i32, true, intern(str("devirt<", maxdv, ">"))));
    }
    // MIWP's PM: inline<only-mandatory> first with -mandatory-inlining-first, then the inliner
    if flag_bool("mandatory-inlining-first", false) { pb_add(cg, "inline<only-mandatory>"); }
    pb_add(cg, "inline");
    pb_add(cg, "function-attrs<skip-non-recursive-function-attrs>");
    if level == 3 { pb_add(cg, "argpromotion"); }
    if level == 2 || level == 3 { pb_add(cg, "openmp-opt-cgscc"); }
    let fa = pb_link(cg, new_pnode(PK_CGFN, 1, if pto_eager_inv { 3 } else { 2 }, true,
        intern(if pto_eager_inv { "function<eager-inv;no-rerun>" } else { "function<no-rerun>" })));
    pb_function_simplification(fa, level);
    pb_add(cg, "function-attrs");
    pb_add(cg, "function(require<should-not-run-function-passes>)");
    pb_add(cg, "coro-split");
    pb_add(cg, "coro-annotation-elide");
    // MIWP.addLateModulePass
    pb_add(w, "function(invalidate<should-not-run-function-passes>)");
}

// ---------------------------------------------------------------------------------------------
// Module pipelines

fn pb_module_simplification(mpm: i32, level: i64) {
    pb_add(mpm, "inferattrs");
    pb_add(mpm, "coro-early");
    {
        let fa = pb_function_adaptor(mpm, pto_eager_inv);
        pb_add(fa, "ee-instrument<>");
        pb_add(fa, "lower-expect");
        pb_add(fa, pb_simplifycfg(pb_scfg_default()));
        pb_add(fa, "sroa<modify-cfg>");
        pb_add(fa, "early-cse<>");
        if level == 3 { pb_add(fa, "callsite-splitting"); }
    }
    pb_add(mpm, "openmp-opt");
    pb_add(mpm, "ipsccp");          // IPSCCPOptions(AllowFuncSpec = !isLTOPreLink(Phase))
    pb_add(mpm, "called-value-propagation");
    pb_add(mpm, "globalopt");
    {
        let fa = pb_function_adaptor(mpm, pto_eager_inv);
        pb_add(fa, "mem2reg");
        pb_add(fa, PB_INSTCOMBINE);
        pb_add(fa, pb_simplifycfg(pb_scfg_range()));
    }
    pb_add(mpm, "always-inline");   // AlwaysInlinerPass(InsertLifetimeIntrinsics = true)
    pb_inliner_pipeline(mpm, level);
    pb_add(mpm, "deadargelim");
    pb_add(mpm, "coro-cleanup");
    pb_add(mpm, "globalopt");
    pb_add(mpm, "globaldce");
}

fn pb_add_vector_passes(fpm: i32, level: i64) {
    pb_add(fpm, str("loop-vectorize<", if pto_loop_interleaving { "no-" } else { "" }, "interleave-forced-only;",
        if pto_loop_vectorization { "no-" } else { "" }, "vectorize-forced-only;>"));
    pb_add(fpm, "drop-unnecessary-assumes<drop-deref>");
    pb_add(fpm, "infer-alignment");
    pb_add(fpm, "loop-load-elim");
    pb_add(fpm, PB_INSTCOMBINE);
    var o = pb_scfg_range();
    o.fwd = true; o.arith = true; o.lookup = true; o.keep_loops = false; o.hoist = true; o.sink = true;
    pb_add(fpm, pb_simplifycfg(o));
    if pto_slp_vectorization { pb_add(fpm, "slp-vectorizer"); }
    pb_add(fpm, "vector-combine");
    pb_add(fpm, PB_INSTCOMBINE);
    pb_loop_unroll(fpm, level);
    pb_add(fpm, "transform-warning");
    pb_add(fpm, "sroa<preserve-cfg;aggregate-to-vector>");
    pb_add(fpm, "infer-alignment");
    pb_add(fpm, PB_INSTCOMBINE);
    let lp = pb_loop_adaptor(fpm, true);
    pb_add(lp, pb_licm(true));
    pb_end_loop_adaptor(lp);
    pb_add(fpm, "alignment-from-assumptions");
}

fn pb_module_optimization(mpm: i32, level: i64) {
    pb_add(mpm, "elim-avail-extern");
    pb_add(mpm, "rpo-function-attrs");
    if flag_bool("enable-global-analyses", true) { pb_add(mpm, "recompute-globalsaa"); }
    let fa = pb_function_adaptor(mpm, pto_eager_inv);
    pb_add(fa, "drop-unnecessary-assumes");
    pb_add(fa, "float2int");
    pb_add(fa, "lower-constant-intrinsics");
    if flag_bool("enable-chr", true) && level == 3 { pb_add(fa, "chr"); }
    {
        let la = pb_loop_adaptor(fa, false);
        pb_add(la, "loop-rotate<header-duplication;no-prepare-for-lto;check-exit-count>");
        pb_add(la, "loop-deletion");
        if pto_loop_interchange { pb_add(la, "loop-interchange"); }
        pb_end_loop_adaptor(la);
    }
    pb_add(fa, "loop-distribute");
    pb_add(fa, "inject-tli-mappings");
    pb_add_vector_passes(fa, level);
    pb_add(fa, "loop-sink");
    pb_add(fa, "instsimplify");
    pb_add(fa, "div-rem-pairs");
    if flag_bool("enable-mergeicmps", true) { pb_add(fa, "mergeicmps"); }
    pb_add(fa, "expand-memcmp");
    pb_tailcallelim(fa);
    var o = pb_scfg_range();
    o.arith = true; o.spec_unpred = true; o.hoist_ldst = true;
    pb_add(fa, pb_simplifycfg(o));
    pb_add(mpm, "alloc-token");
    pb_add(mpm, "globaldce");
    pb_add(mpm, "constmerge");
    if pto_call_graph_profile { pb_add(mpm, "cg-profile"); }
    pb_add(mpm, "rel-lookup-table-converter");
    pb_add(mpm, "lower-comment-string");
}

fn pb_o0_pipeline(mpm: i32) {
    pb_add(mpm, "function(ee-instrument<>)");
    let ai = pb_add(mpm, "always-inline");   // AlwaysInlinerPass(InsertLifetimeIntrinsics = false)
    pnodes[ai].arg = 1;
    // buildCoroWrapper
    let cw = pb_link(mpm, new_pnode(PK_CORO_COND, 0, 0, true, intern("coro-cond")));
    pb_add(cw, "coro-early");
    pb_add(cw, "cgscc(coro-split)");
    pb_add(cw, "coro-cleanup");
    pb_add(cw, "globaldce");
    pb_add(mpm, "alloc-token");
    pb_add(mpm, "lower-comment-string");
    pb_add(mpm, "function(annotation-remarks)");
}

// `default<On>` (parseModulePass: the per-module aliases): setupOptionsForPipelineAlias, then
// buildPerModuleDefaultPipeline; the result is a nested ModulePassManager (required, not counted).
fn pb_default_pipeline(name: const u8[:]) -> i32 {
    let s = name[8..name.len - 1];
    if s == "Os" || s == "Oz" {
        write_stderr(str("LLVM ERROR: The optimization level \"", s, "\" is no longer supported. Use O2 in conjunction with the ",
            if s == "Os" { "optsize" } else { "minsize" }, " attribute instead.\n"));
        exit(1);
    }
    var level: i64 = -1;
    if s == "O0" { level = 0; } else if s == "O1" { level = 1; } else if s == "O2" { level = 2; } else if s == "O3" { level = 3; }
    if level < 0 { perr_pipeline(str("invalid optimization level '", s, "'")); }
    pb_init_pto(level);
    pb_check_cl_opts();
    let mpm = new_pnode(PK_MODULE, 0, 0, true, intern("module"));
    if level == 0 { pb_o0_pipeline(mpm); return mpm; }
    pb_add(mpm, "memprof-remove-attributes");
    pb_add(mpm, "annotation2metadata");
    pb_add(mpm, "forceattrs");
    pb_module_simplification(mpm, level);
    pb_module_optimization(mpm, level);
    pb_add(mpm, "function(annotation-remarks)");   // addAnnotationRemarksPass
    return mpm;
}

// ---------------------------------------------------------------------------------------------
// -goose-print-pipeline: the pipeline in the format of `opt -print-pipeline-passes` (exact for pipelines built
// here, whose leaf names are LLVM's printed names; the -passes text otherwise).

recursive fn pb_print_children(n: i32, out: u8[>..]&, skip_last: bool) {
    var c = pnodes[n].first;
    var first = true;
    while c >= 0 {
        if skip_last && pnodes[c].next < 0 { break; }
        if !first { out.push(','); }
        first = false;
        pb_print_node(c, out);
        c = pnodes[c].next;
    }
}
recursive fn pb_print_node(n: i32, out: u8[>..]&) {
    let k = pnodes[n].kind as i64;
    let name = sbytes(pnodes[n].name);
    if k == PK_MODULE || k == PK_CGSCC_PM {
        // ModuleInlinerWrapperPass::printPipeline: its module passes and the CGSCC adaptor, not the late passes
        pb_print_children(n, out, k == PK_MODULE && !pnodes[n].required);
        return;
    }
    if k == PK_EXTRA { out.append("extra-simple-loop-unswitch-passes"); return; }
    if k == PK_PASS {
        // DropUnnecessaryAssumesPass::printPipeline does not print DropDereferenceable
        if name == "drop-unnecessary-assumes<drop-deref>" { out.append("drop-unnecessary-assumes"); }
        else { out.append(name); }
        return;
    }
    out.append(name);
    out.push('(');
    pb_print_children(n, out, false);
    out.push(')');
}
fn pb_print_pipeline(root: i32) {
    var out: u8[>..] = [];
    pb_print_node(root, out);
    out.append(",verify\n");
    write_stdout(out);
}
