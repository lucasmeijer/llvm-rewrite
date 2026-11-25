// The PassRegistry.def names that had no row in PASS_TABLE (NOTES.md "Pass registry gaps"): pipeline callbacks,
// no-op / marker analyses behind require<>, invalidate<all>, the IR printers `print` (PrintModulePass,
// PrintFunctionPass, PrintLoopPass), and small test passes. Larger ports live in their own pass_*.jai files and are
// dispatched from here too, so that passes.jai only needs four Pass_Kind values (GAP_MODULE, GAP_FUNCTION, GAP_LOOP,
// GAP_CGSCC) and one table lookup.
//
// Ported from llvm/lib/Passes/PassRegistry.def + PassBuilder.cpp (the *_CALLBACK parsers, parseOptLevelParam,
// parseFunctionSimplificationPipelineOptions, parseInstCountOptions, TriggerVerifierErrorPass),
// llvm/lib/IRPrinter/IRPrintingPasses.cpp, llvm/lib/Analysis/LoopInfo.cpp (printLoop),
// llvm/lib/Transforms/Utils/{HelloWorld,CountVisits,TriggerCrashPass}.cpp, llvm/lib/Analysis/InstCount.cpp,
// llvm/include/llvm/Transforms/Utils/ExtraPassManager.h.

Gap_Kind :: enum u8 {
    NONE;
    CALLBACK;            // *-callbacks<O#>: opt registers no extension-point callbacks without -passes-ep-* / plugins
    NO_OP;               // require<no-op-*>, require<pass-instrumentation>, require<fam-proxy>, analyses that change no IR
    INVALIDATE_ALL;      // InvalidateAllAnalysesPass: PreservedAnalyses::none()
    PRINT_IR;            // PrintModulePass / PrintFunctionPass / PrintLoopPass (to errs(), empty banner)
    HELLOWORLD;          // HelloWorldPass
    INSTCOUNT;           // InstCountPass: statistics only (-stats is not supported, so nothing to print)
    EXTRA_VECTOR_PASSES; // ExtraFunctionPassManager<ShouldRunExtraVectorPasses> parsed from text: empty
    REQUIRE_VERIFY_FN;   // RequireAnalysisPass<VerifierAnalysis, Function>: verifyFunction(F, &dbgs())
    REQUIRE_EXTRA_UNSWITCH;   // require<should-run-extra-simple-loop-unswitch> (a loop marker analysis)
    TRIGGER_CRASH;       // TriggerCrash{Module,Function}Pass: abort()
    TRIGGER_VERIFIER_ERROR;
    FUNCTION_SIMPLIFICATION;   // function-simplification<O#>: buildFunctionSimplificationPipeline (expanded at parse time)
    INLINER_WRAPPER_NO_MANDATORY_FIRST;
    // registry_printers.jai
    PRINT_CFG_SCCS; PRINT_DOMFRONTIER; PRINT_STACK_LIFETIME; PRINT_INLINE_COST;
    PRINT_MODULE_DEBUGINFO;   // debug_info_finder.jai
    // registry_small_passes.jai
    STRIP_GC_RELOCATES; FLATTEN_CFG;
    // assume_builder.jai
    ASSUME_BUILDER; ASSUME_SIMPLIFY;
    DWARF_EH_PREPARE;   // pass_dwarf_eh_prepare.jai
}

Gap_Info :: struct {
    name: string;
    level: Pass_Level;
    kind: Pass_Kind;
    required: bool;
    analysis: Analysis_Kind;
    gap: Gap_Kind;
}

// The rows are appended to pass_table (passes.jai lookup_pass); pass_gap_kinds[i] is the Gap_Kind of pass_table[i].
pass_gap_kinds: [..] Gap_Kind;
gap_table_init :: () {
    while pass_gap_kinds.count < pass_table.count array_add(*pass_gap_kinds, .NONE);
    for GAP_PASS_TABLE {
        array_add(*pass_table, .{it.name, it.level, it.kind, it.required, it.analysis});
        array_add(*pass_gap_kinds, it.gap);
    }
}
pass_gap :: (p: *Pass_Info) -> Gap_Kind {
    i := p - pass_table.data;
    if i < 0 || i >= pass_gap_kinds.count return .NONE;
    return pass_gap_kinds[i];
}

GAP_PASS_TABLE :: Gap_Info.[
    // ---- pipeline callbacks (PassBuilder.cpp: MODULE_CALLBACK, MODULE_LTO_CALLBACK, FUNCTION_CALLBACK, ...)
    .{"pipeline-start-callbacks", .MODULE, .GAP_MODULE, true, .DOMTREE, .CALLBACK},
    .{"pipeline-early-simplification-callbacks", .MODULE, .GAP_MODULE, true, .DOMTREE, .CALLBACK},
    .{"optimizer-early-callbacks", .MODULE, .GAP_MODULE, true, .DOMTREE, .CALLBACK},
    .{"optimizer-last-callbacks", .MODULE, .GAP_MODULE, true, .DOMTREE, .CALLBACK},
    .{"peephole-callbacks", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .CALLBACK},
    .{"scalar-optimizer-late-callbacks", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .CALLBACK},
    .{"vectorizer-start-callbacks", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .CALLBACK},
    .{"vectorizer-end-callbacks", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .CALLBACK},
    .{"cgscc-optimizer-late-callbacks", .CGSCC, .GAP_CGSCC, true, .DOMTREE, .CALLBACK},
    .{"late-loop-optimizations-callbacks", .LOOP, .GAP_LOOP, true, .DOMTREE, .CALLBACK},
    .{"loop-optimizer-end-callbacks", .LOOP, .GAP_LOOP, true, .DOMTREE, .CALLBACK},

    // ---- RequireAnalysisPass<...> of analyses whose result changes no IR and that no ported pass reads from the
    // cache (computing them lazily later gives the same results). RequireAnalysisPass is a required pass.
    .{"require<no-op-module>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},
    .{"require<pass-instrumentation>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},
    .{"require<callgraph>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},             // CallGraphAnalysis
    .{"require<inline-advisor>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},        // InlineAdvisorAnalysis: creates no advisor
    .{"require<ir-similarity>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},         // IRSimilarityAnalysis
    .{"require<immutable-module-summary>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},   // opt registers it with no index
    .{"require<runtime-libcall-info>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},  // RuntimeLibraryAnalysis
    .{"require<collector-metadata>", .MODULE, .GAP_MODULE, true, .DOMTREE, .NO_OP},    // CollectorMetadataAnalysis
    .{"require<no-op-cgscc>", .CGSCC, .GAP_CGSCC, true, .DOMTREE, .NO_OP},
    .{"require<fam-proxy>", .CGSCC, .GAP_CGSCC, true, .DOMTREE, .NO_OP},               // FunctionAnalysisManagerCGSCCProxy
    .{"require<pass-instrumentation>", .CGSCC, .GAP_CGSCC, true, .DOMTREE, .NO_OP},
    .{"require<no-op-function>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .NO_OP},
    .{"require<pass-instrumentation>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .NO_OP},
    .{"require<access-info>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .NO_OP},       // LoopAccessInfoManager: per-loop info is computed on demand
    .{"require<should-run-extra-vector-passes>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .NO_OP},   // only read by ExtraFunctionPassManager, empty from text
    .{"require<ephemerals>", .FUNCTION, .REQUIRE, true, .EPHEMERAL_VALUES, .NONE},
    .{"require<verify>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .REQUIRE_VERIFY_FN},
    .{"require<no-op-loop>", .LOOP, .GAP_LOOP, true, .DOMTREE, .NO_OP},
    .{"require<pass-instrumentation>", .LOOP, .GAP_LOOP, true, .DOMTREE, .NO_OP},
    .{"require<should-run-extra-simple-loop-unswitch>", .LOOP, .GAP_LOOP, true, .DOMTREE, .REQUIRE_EXTRA_UNSWITCH},
    .{"no-op-loopnest", .LOOP, .NO_OP_LOOPNEST, false, .DOMTREE, .NONE},

    // ---- InvalidateAllAnalysesPass (not required; the loop version is in parse_loop_pass)
    .{"invalidate<all>", .MODULE, .GAP_MODULE, false, .DOMTREE, .INVALIDATE_ALL},
    .{"invalidate<all>", .CGSCC, .GAP_CGSCC, false, .DOMTREE, .INVALIDATE_ALL},
    .{"invalidate<all>", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .INVALIDATE_ALL},

    // ---- IR printers (PrintModulePass etc. are RequiredPassInfoMixin)
    .{"print", .MODULE, .GAP_MODULE, true, .DOMTREE, .PRINT_IR},
    .{"print", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .PRINT_IR},
    .{"print", .LOOP, .GAP_LOOP, true, .DOMTREE, .PRINT_IR},

    // ---- small passes
    .{"helloworld", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .HELLOWORLD},
    .{"count-visits", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .NO_OP},   // CountVisitsPass: a STATISTIC only
    .{"instcount", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .INSTCOUNT},   // also instcount<pre-opt>
    .{"extra-vector-passes", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .EXTRA_VECTOR_PASSES},
    .{"trigger-crash-module", .MODULE, .GAP_MODULE, false, .DOMTREE, .TRIGGER_CRASH},
    .{"trigger-crash-function", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .TRIGGER_CRASH},
    .{"trigger-verifier-error", .MODULE, .GAP_MODULE, false, .DOMTREE, .TRIGGER_VERIFIER_ERROR},
    .{"trigger-verifier-error", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .TRIGGER_VERIFIER_ERROR},
    .{"function-simplification", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .FUNCTION_SIMPLIFICATION},
    .{"inliner-wrapper-no-mandatory-first", .MODULE, .GAP_MODULE, false, .DOMTREE, .INLINER_WRAPPER_NO_MANDATORY_FIRST},

    // ---- printers (registry_printers.jai; RequiredPassInfoMixin)
    .{"print<cfg-sccs>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .PRINT_CFG_SCCS},
    .{"assume-builder", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .ASSUME_BUILDER},
    .{"assume-simplify", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .ASSUME_SIMPLIFY},
    .{"dwarf-eh-prepare", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .DWARF_EH_PREPARE},
    .{"flatten-cfg", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .FLATTEN_CFG},
    .{"strip-gc-relocates", .FUNCTION, .GAP_FUNCTION, false, .DOMTREE, .STRIP_GC_RELOCATES},
    .{"print<stack-lifetime>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .PRINT_STACK_LIFETIME},   // also <may>, <must>
    .{"print<inline-cost>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .PRINT_INLINE_COST},
    .{"print<module-debuginfo>", .MODULE, .GAP_MODULE, true, .DOMTREE, .PRINT_MODULE_DEBUGINFO},
    .{"print<domfrontier>", .FUNCTION, .GAP_FUNCTION, true, .DOMTREE, .PRINT_DOMFRONTIER},
];

// Name lookup for the rows above that take parameters: `name<params>` -> the row of `name` (parameters are checked
// here the way PassBuilder's parsers do, and parsed again where the pass is built or run).
gap_lookup_parametrized :: (name: string) -> *Pass_Info {
    if name.count == 0 || name[name.count - 1] != #char ">" return null;
    row: *Pass_Info;
    for * pass_table {
        if pass_gap(it) == .NONE || name.count < it.name.count + 2 || !begins_with(name, it.name) || name[it.name.count] != #char "<" continue;
        if !row || it.name.count > row.name.count row = it;   // the longest name: print<stack-lifetime><may>, not print<...>
    }
    if !row return null;
    base := row.name;
    params := slice(name, base.count + 1, name.count - base.count - 2);
    if pass_gap(row) == {
        case .CALLBACK;
            // parsePassParameters(parseOptLevelParam, Name, NAME): "NAME: invalid optimization level '...'"
            ok, _ := pb_parse_opt_level(params);
            if !ok fatal("%: invalid optimization level '%'\nunknown pass name '%'", base, params, name);
        case .FUNCTION_SIMPLIFICATION;
            ok, level := pb_parse_opt_level(params);
            if !ok || level.speed == 0 fatal("invalid function-simplification parameter '%'", params);
        case .INSTCOUNT;
            if params != "pre-opt" && params.count != 0 fatal("invalid InstCountPass pass parameter '%'", params);
        case .PRINT_STACK_LIFETIME;
            rest := params;
            while rest.count {
                k := find_index_from_left(rest, #char ";");
                pn := ifx k >= 0 then slice(rest, 0, k) else rest;
                rest = ifx k >= 0 then slice(rest, k + 1, rest.count - k - 1) else "";
                if pn != "may" && pn != "must" fatal("invalid StackLifetime parameter '%'", pn);
            }
        case; return null;
    }
    return row;
}
// A parametrized gap row used without parameters, where LLVM's parser rejects the empty parameter string.
gap_check_bare_name :: (p: *Pass_Info) {
    g := pass_gap(p);
    if g == .CALLBACK fatal("%: invalid optimization level ''\nunknown pass name '%'", p.name, p.name);
    if g == .FUNCTION_SIMPLIFICATION fatal("invalid function-simplification parameter ''");
}

// parseFunctionPass for rows that expand into a pipeline. Returns true if handled.
gap_parse_function_element :: (fpm: s32, last: *s32, p: *Pass_Info, name: string) -> bool {
    if pass_gap(p) != .FUNCTION_SIMPLIFICATION return false;
    lt := find_index_from_left(name, #char "<");
    ok, level := pb_parse_opt_level(slice(name, lt + 1, name.count - lt - 2));
    // buildFunctionSimplificationPipeline(OL, ThinOrFullLTOPhase::None): a FunctionPassManager, which is the same
    // as its passes inlined into the enclosing function pipeline (see parse_function_pass "function")
    saved := pb_phase; pb_phase = .NONE;
    build_function_simplification_pipeline(fpm, last, level);
    pb_phase = saved;
    return true;
}

// ---------------------------------------------------------------- running

gap_run_module :: (node: *Pass_Node) {
    g := pass_gap(node.info);
    if g == {
        case .CALLBACK; return;
        case .NO_OP; should_run_pass(node, NONE); return;
    }
    if !should_run_pass(node, NONE) return;
    if g == {
        case .INVALIDATE_ALL; mam_invalidate(PRESERVE_NONE);
        case .PRINT_IR;
            // PrintModulePass(errs()): no banner, isFunctionInPrintList("*") (no -filter-print-funcs)
            s := print_module_fresh();
            write_string(s, to_standard_error = true);
        case .PRINT_MODULE_DEBUGINFO; print_module_debuginfo_run();
        case .TRIGGER_CRASH; gap_abort();
        case .TRIGGER_VERIFIER_ERROR;
            // GlobalAlias::create(ptr, 0, internal, "__bad_alias", /*Aliasee=*/nullptr, &M): our IR has no alias
            // without an aliasee
            fatal("trigger-verifier-error (module): an alias without an aliasee is not representable yet");
        case .INLINER_WRAPPER_NO_MANDATORY_FIRST; inliner_wrapper_run(mandatory_first = false);
        case; fatal("internal: '%' is not a module pass", node.name);
    }
}

gap_run_function :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    if pass_gap(node.info) == {
        case .CALLBACK; #through;
        case .NO_OP; #through;
        case .EXTRA_VECTOR_PASSES; #through;   // the marker is abandoned; nothing else caches it
        case .INSTCOUNT; return PRESERVE_ALL;
        case .INVALIDATE_ALL; return PRESERVE_NONE;
        case .REQUIRE_VERIFY_FN;
            // VerifierAnalysis::run(Function &): IsBroken = verifyFunction(F, &dbgs()); not fatal here
            verify_function(f);
            return PRESERVE_ALL;
        case .PRINT_IR;
            // PrintFunctionPass(errs()): OS << Banner << '\n' << static_cast<Value &>(F) (Value::print of a
            // Function initializes all metadata)
            printer_begin_function(f, all_md = true);
            start := W.buf.count;
            print_function(f);
            s := tprint("\n%", slice_of_buf(start));
            W.buf.count = start;
            write_string(s, to_standard_error = true);
            return PRESERVE_ALL;
        case .HELLOWORLD;
            write_string(tprint("%\n", vname(f)), to_standard_error = true);
            return PRESERVE_ALL;
        case .PRINT_CFG_SCCS; return print_cfg_sccs_run(f);
        case .STRIP_GC_RELOCATES; return strip_gc_relocates_run(f);
        case .FLATTEN_CFG; return flatten_cfg_run(f);
        case .ASSUME_BUILDER; return assume_builder_run(f);
        case .DWARF_EH_PREPARE; return dwarf_eh_prepare_opt_run(f);
        case .ASSUME_SIMPLIFY; return assume_simplify_run(f);
        case .PRINT_DOMFRONTIER; return print_domfrontier_run(f);
        case .PRINT_INLINE_COST; return print_inline_cost_run(f);
        case .PRINT_STACK_LIFETIME; return print_stack_lifetime_run(f, node.name);
        case .TRIGGER_CRASH; gap_abort();
        case .TRIGGER_VERIFIER_ERROR;
            // new UnreachableInst(Ctx, BB.getTerminator()->getIterator()) in the entry block
            entry := fn_entry(f);
            u := new_inst(.UNREACHABLE, ir.t_void, 0);
            insert_before_named(u, block_terminator(entry), "");
            return PRESERVE_NONE;
    }
    fatal("internal: '%' is not a function pass", node.name);
    return PRESERVE_NONE;
}

gap_run_loop :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results) -> Preserved {
    if pass_gap(node.info) == {
        case .CALLBACK; #through;
        case .NO_OP; return PRESERVE_ALL;
        case .REQUIRE_EXTRA_UNSWITCH; table_set(*extra_unswitch_marker, l, true); return PRESERVE_ALL;
        case .PRINT_IR; gap_print_loop(lar.li, l); return PRESERVE_ALL;
    }
    fatal("internal: '%' is not a loop pass", node.name);
    return PRESERVE_NONE;
}

gap_run_cgscc :: (node: *Pass_Node) -> Preserved {
    if pass_gap(node.info) == {
        case .CALLBACK; #through;
        case .NO_OP; return PRESERVE_ALL;
        case .INVALIDATE_ALL; return PRESERVE_NONE;
    }
    fatal("internal: '%' is not a cgscc pass", node.name);
    return PRESERVE_NONE;
}

// llvm::printLoop(L, errs(), /*Banner=*/"") (no -print-module-scope / -print-loop-func-scope)
gap_print_loop :: (li: *Loop_Info, l: Loop_Id) {
    f := block_fn(li_header(li, l));
    sb: String_Builder; sb.allocator = temp;
    print_block :: (sb: *String_Builder, f: Value_Id, b: Value_Id) {
        // BasicBlock::print: a fresh SlotTracker of the function
        printer_begin_function(f);
        start := W.buf.count;
        print_basic_block(b, b == fn_entry(f));
        append(sb, slice_of_buf(start));
        W.buf.count = start;
    }
    ph := li_loop_preheader(li, l);
    if ph != NONE {
        append(*sb, "\n; Preheader:");
        print_block(*sb, f, ph);
        append(*sb, "\n; Loop:");
    }
    for li_blocks(li, l) print_block(*sb, f, it);
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(li, l, *exits);
    if exits.count {
        append(*sb, "\n; Exit blocks");
        for exits print_block(*sb, f, it);
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}

gap_abort :: () {
    // abort(): SIGABRT, exit status 134 from a shell (LLVM's signal handler also prints a stack dump)
    write_string("opt: trigger-crash: abort() as requested\n", to_standard_error = true);
    exit(134);
}

// cl::opts of the registry-gap passes
gap_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if registry_printers_parse_cl_opt(name, value, has_value) return true;
    return false;
}
