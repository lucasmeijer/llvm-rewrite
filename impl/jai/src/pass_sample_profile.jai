// The sample profile loader (`sample-profile`, SampleProfileLoaderPass).
// Ported from llvm/lib/Transforms/IPO/SampleProfile.cpp (SampleProfileLoader, GUIDToFuncNameMapper,
// updateIDTMetaData, doesHistoryAllowICP), llvm/include/llvm/Transforms/Utils/SampleProfileLoaderBaseImpl.h (block
// weights, equivalence classes, propagation, PseudoProbeManager, buildTopDownFuncOrder),
// llvm/lib/Transforms/Utils/SampleProfileLoaderBaseUtil.cpp (callsiteIsHot, SampleCoverageTracker),
// llvm/include/llvm/Transforms/IPO/ProfiledCallGraph.h (ProfiledCallGraph) and llvm/include/llvm/ADT/SCCIterator.h
// (scc_iterator, scc_member_iterator) for the profiled call graph order.
//
// Optimization remarks are not emitted (nothing in the IR depends on them).

sp_opts: struct {
    file: string;                                   // -sample-profile-file
    remapping_file: string;                         // -sample-profile-remapping-file
    salvage_stale_profile := false; salvage_stale_profile_given := false;
    salvage_unused_profile := false; salvage_unused_profile_given := false;
    report_profile_staleness := false;
    persist_profile_staleness := false;
    profile_sample_accurate := false;
    profile_sample_block_accurate := false;
    profile_accurate_for_symsinlist := true;
    merge_inlinee := true;                          // -sample-profile-merge-inlinee
    top_down_load := true;                          // -sample-profile-top-down-load
    use_profiled_call_graph := true; use_profiled_call_graph_given := false;
    profile_size_inline := false; profile_size_inline_given := false;   // -sample-profile-inline-size
    disable_sample_loader_inlining := false; disable_sample_loader_inlining_given := false;
    sort_profiled_scc := true;                      // -sort-profiled-scc-member
    inline_growth_limit: s64 = 12;                  // -sample-profile-inline-growth-limit
    inline_limit_min: s64 = 100; inline_limit_min_given := false;
    inline_limit_max: s64 = 10000; inline_limit_max_given := false;
    hot_inline_threshold: s64 = 3000;               // -sample-profile-hot-inline-threshold
    cold_inline_threshold: s64 = 45;                // -sample-profile-cold-inline-threshold
    icp_relative_hotness: u64 = 25;
    icp_relative_hotness_skip: u64 = 1;
    hot_func_cutoff_for_staleness_error: s64 = 800000;
    min_functions_for_staleness_error: u64 = 50;
    percent_mismatch_for_staleness_error: u64 = 80;
    prioritized_inline := false; prioritized_inline_given := false;     // -sample-profile-prioritized-inline
    use_preinliner := false; use_preinliner_given := false;
    recursive_inline := false; recursive_inline_given := false;
    remove_probe := false;                          // -sample-profile-remove-probe
    inline_replay: string;                          // -sample-profile-inline-replay
    inline_replay_scope_module := false;            // -sample-profile-inline-replay-scope
    inline_replay_fallback: u8 = 0;                 // Original, AlwaysInline, NeverInline
    inline_replay_format: u8 = 3;                   // Line, LineColumn, LineDiscriminator, LineColumnDiscriminator
    icp_max_prom: u32 = 3;                          // -sample-profile-icp-max-prom
    overwrite_existing_weights := false;
    annotate_inline_phase := false;
    // SampleProfileLoaderBaseUtil.cpp
    max_propagate_iterations: u32 = 100;
    record_coverage: u32 = 0;
    sample_coverage: u32 = 0;
    no_warn_sample_unused := false;
    use_profi := false; use_profi_given := false;   // -sample-profile-use-profi
    // SampleProfReader.cpp
    profile_isfs := false;
    // ProfileSummaryBuilder.cpp
    contextless_summary := false; contextless_summary_given := false;   // -profile-summary-contextless
    // SampleProfileInference.cpp
    profi_even_flow_distribution := true;           // -sample-profile-even-flow-distribution
    profi_rebalance_unknown := true;                // -sample-profile-rebalance-unknown
    profi_join_islands := true;                     // -sample-profile-join-islands
    profi_cost_block_inc: u32 = 10;
    profi_cost_block_dec: u32 = 20;
    profi_cost_block_entry_inc: u32 = 40;
    profi_cost_block_entry_dec: u32 = 10;
    profi_cost_block_zero_inc: u32 = 11;
    profi_cost_block_unknown_inc: u32 = 0;
    // BlockFrequencyInfoImpl.cpp (set by the loader for CS / probe profiles)
    use_iterative_bfi_inference := false; use_iterative_bfi_inference_given := false;
    // MachineBlockPlacement.cpp
    ext_tsp_block_placement := false; ext_tsp_block_placement_given := false;
    // SampleProfileProbe.cpp
    verify_pseudo_probe := false;
    update_pseudo_probe := true;
};

sp_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    o := *sp_opts;
    b :: () -> bool #expand { return smisc_bool(name, value, has_value); }
    i :: () -> s64 #expand { return smisc_int(name, value, has_value); }
    if name == {
        case "sample-profile-file"; o.file = copy_string(prof_str(name, value, has_value));
        case "sample-profile-remapping-file"; o.remapping_file = copy_string(prof_str(name, value, has_value));
        case "salvage-stale-profile"; o.salvage_stale_profile = b(); o.salvage_stale_profile_given = true;
        case "salvage-unused-profile"; o.salvage_unused_profile = b(); o.salvage_unused_profile_given = true;
        case "report-profile-staleness"; o.report_profile_staleness = b();
        case "persist-profile-staleness"; o.persist_profile_staleness = b();
        case "profile-sample-accurate"; o.profile_sample_accurate = b();
        case "profile-sample-block-accurate"; o.profile_sample_block_accurate = b();
        case "profile-accurate-for-symsinlist"; o.profile_accurate_for_symsinlist = b();
        case "sample-profile-merge-inlinee"; o.merge_inlinee = b();
        case "sample-profile-top-down-load"; o.top_down_load = b();
        case "use-profiled-call-graph"; o.use_profiled_call_graph = b(); o.use_profiled_call_graph_given = true;
        case "sample-profile-inline-size"; o.profile_size_inline = b(); o.profile_size_inline_given = true;
        case "disable-sample-loader-inlining"; o.disable_sample_loader_inlining = b(); o.disable_sample_loader_inlining_given = true;
        case "sort-profiled-scc-member"; o.sort_profiled_scc = b();
        case "sample-profile-inline-growth-limit"; o.inline_growth_limit = i();
        case "sample-profile-inline-limit-min"; o.inline_limit_min = i(); o.inline_limit_min_given = true;
        case "sample-profile-inline-limit-max"; o.inline_limit_max = i(); o.inline_limit_max_given = true;
        case "sample-profile-hot-inline-threshold"; o.hot_inline_threshold = i();
        case "sample-profile-cold-inline-threshold"; o.cold_inline_threshold = i();
        case "sample-profile-icp-relative-hotness"; o.icp_relative_hotness = cast(u64) i();
        case "sample-profile-icp-relative-hotness-skip"; o.icp_relative_hotness_skip = cast(u64) i();
        case "hot-func-cutoff-for-staleness-error"; o.hot_func_cutoff_for_staleness_error = i();
        case "min-functions-for-staleness-error"; o.min_functions_for_staleness_error = cast(u64) i();
        case "precent-mismatch-for-staleness-error"; o.percent_mismatch_for_staleness_error = cast(u64) i();
        case "sample-profile-prioritized-inline"; o.prioritized_inline = b(); o.prioritized_inline_given = true;
        case "sample-profile-use-preinliner"; o.use_preinliner = b(); o.use_preinliner_given = true;
        case "sample-profile-recursive-inline"; o.recursive_inline = b(); o.recursive_inline_given = true;
        case "sample-profile-remove-probe"; o.remove_probe = b();
        case "sample-profile-inline-replay"; o.inline_replay = copy_string(prof_str(name, value, has_value));
        case "sample-profile-inline-replay-scope";
            if value == "Function" o.inline_replay_scope_module = false;
            else if value == "Module" o.inline_replay_scope_module = true;
            else fatal("invalid value '%' for -sample-profile-inline-replay-scope", value);
        case "sample-profile-inline-replay-fallback";
            if value == "Original" o.inline_replay_fallback = 0;
            else if value == "AlwaysInline" o.inline_replay_fallback = 1;
            else if value == "NeverInline" o.inline_replay_fallback = 2;
            else fatal("invalid value '%' for -sample-profile-inline-replay-fallback", value);
        case "sample-profile-inline-replay-format";
            if value == "Line" o.inline_replay_format = 0;
            else if value == "LineColumn" o.inline_replay_format = 1;
            else if value == "LineDiscriminator" o.inline_replay_format = 2;
            else if value == "LineColumnDiscriminator" o.inline_replay_format = 3;
            else fatal("invalid value '%' for -sample-profile-inline-replay-format", value);
        case "sample-profile-icp-max-prom"; o.icp_max_prom = cast(u32) i();
        case "overwrite-existing-weights"; o.overwrite_existing_weights = b();
        case "annotate-sample-profile-inline-phase"; o.annotate_inline_phase = b();
        case "sample-profile-max-propagate-iterations"; o.max_propagate_iterations = cast(u32) i();
        case "sample-profile-check-record-coverage"; o.record_coverage = cast(u32) i();
        case "sample-profile-check-sample-coverage"; o.sample_coverage = cast(u32) i();
        case "no-warn-sample-unused"; o.no_warn_sample_unused = b();
        case "sample-profile-use-profi"; o.use_profi = b(); o.use_profi_given = true;
        case "profile-isfs"; o.profile_isfs = b();
        case "profile-summary-contextless"; o.contextless_summary = b(); o.contextless_summary_given = true;
        case "sample-profile-even-flow-distribution"; o.profi_even_flow_distribution = b();
        case "sample-profile-rebalance-unknown"; o.profi_rebalance_unknown = b();
        case "sample-profile-join-islands"; o.profi_join_islands = b();
        case "sample-profile-profi-cost-block-inc"; o.profi_cost_block_inc = cast(u32) i();
        case "sample-profile-profi-cost-block-dec"; o.profi_cost_block_dec = cast(u32) i();
        case "sample-profile-profi-cost-block-entry-inc"; o.profi_cost_block_entry_inc = cast(u32) i();
        case "sample-profile-profi-cost-block-entry-dec"; o.profi_cost_block_entry_dec = cast(u32) i();
        case "sample-profile-profi-cost-block-zero-inc"; o.profi_cost_block_zero_inc = cast(u32) i();
        case "sample-profile-profi-cost-block-unknown-inc"; o.profi_cost_block_unknown_inc = cast(u32) i();
        case "use-iterative-bfi-inference"; o.use_iterative_bfi_inference = b(); o.use_iterative_bfi_inference_given = true;
        case "enable-ext-tsp-block-placement"; o.ext_tsp_block_placement = b(); o.ext_tsp_block_placement_given = true;
        case "verify-pseudo-probe"; o.verify_pseudo_probe = b();
        case "update-pseudo-probe"; o.update_pseudo_probe = b();
        case "sample-profile-lazy-load-name-table"; b();
        // MisExpect.cpp: only diagnostics (warnings / remarks), the IR does not change
        case "pgo-warn-misexpect"; b();
        case "misexpect-tolerance"; i();
        // CodeGen/CommandFlags.cpp: a TargetMachine option; SampleProfileProbePass does not use it
        case "function-sections"; b();
        case "available-load-scan-limit"; def_max_insts_to_scan = cast(u32) i();   // Loads.cpp
        case; return false;
    }
    return true;
}
sp_takes_value :: (n: string) -> bool {
    for string.["sample-profile-file", "sample-profile-remapping-file", "sample-profile-inline-replay",
                "sample-profile-icp-max-prom", "sample-profile-inline-growth-limit", "sample-profile-inline-limit-min",
                "sample-profile-inline-limit-max", "sample-profile-hot-inline-threshold", "sample-profile-cold-inline-threshold",
                "sample-profile-max-propagate-iterations", "min-functions-for-staleness-error"] if n == it return true;
    return false;
}

// ---------------------------------------------------------------- loader state

Spl_Inline_Candidate :: struct {
    call: Value_Id;
    callee_samples: *Fs;
    callsite_count: u64;
    distribution: float32;
}

Spl :: struct {
    phase: Lto_Phase;
    disable_inlining: bool;
    use_flattened: bool;
    // SymbolMap: by the MD5 of the name (HashKeyMap); NONE = an ambiguous stripped name
    symbol_map: Table(u64, Value_Id);
    prof_acc_for_syms_in_list: bool;
    names_in_profile: Table(string, bool);
    guids_in_profile: Table(u64, bool);
    not_inlined_info: [..] struct { f: Value_Id; entry_count: u64; };   // notInlinedCallInfo
    outline_samples: Table(string, *Fs);   // OutlineFunctionSamples (keyed by the canonical name)
    guid_to_name: Table(u64, string);      // GUIDToFuncNameMap
    probe_desc: Table(u64, u64);           // PseudoProbeManager: GUID -> CFG hash
    probe_weak: Table(u64, bool);          // GUIDIsWeakSymbol
    has_probe_manager: bool;
    psi: *Psi;
    // per function
    samples: *Fs;
    dil_samples: Table(Md_Id, *Fs);        // DILocation2SampleMap
    block_weights: Table(Value_Id, u64);
    edge_weights: Table(u64, u64);
    visited_blocks: Table(Value_Id, bool);
    visited_edges: Table(u64, bool);
    equiv: Table(Value_Id, Value_Id);
    preds: Table(Value_Id, [..] Value_Id);
    succs: Table(Value_Id, [..] Value_Id);
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    li: *Loop_Info;
    coverage: Table(*Fs, [..] Line_Loc);   // SampleCoverageTracker::SampleCoverage (locations used at least once)
    total_used_samples: u64;
}
spl: Spl;

spl_edge_key :: (a: Value_Id, b: Value_Id) -> u64 { return ((cast(u64) a) << 32) | cast(u64) b; }
spl_bw :: (b: Value_Id) -> u64 { found, v := table_find(*spl.block_weights, b); return ifx found then v else 0; }
spl_set_bw :: (b: Value_Id, w: u64) { table_set(*spl.block_weights, b, w); }
spl_ew :: (a: Value_Id, b: Value_Id) -> u64 { found, v := table_find(*spl.edge_weights, spl_edge_key(a, b)); return ifx found then v else 0; }
spl_set_ew :: (a: Value_Id, b: Value_Id, w: u64) { table_set(*spl.edge_weights, spl_edge_key(a, b), w); }
spl_visited_block :: (b: Value_Id) -> bool { return table_contains(*spl.visited_blocks, b); }
spl_visit_block :: (b: Value_Id) -> bool {   // insert: true when new
    if table_contains(*spl.visited_blocks, b) return false;
    table_set(*spl.visited_blocks, b, true);
    return true;
}
spl_ec :: (b: Value_Id) -> Value_Id { found, v := table_find(*spl.equiv, b); return ifx found then v else NONE; }

sp_fn_str_attr :: (f: Value_Id, key: string) -> string {
    a := fn_find_str_attr(f, key);
    if a return a.val;
    return "";
}
// isa<IntrinsicInst>: only a CallInst (not an invoke or callbr) whose callee is an intrinsic
sp_is_intrinsic_inst :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    f := call_called_function(i);
    return f != NONE && begins_with(vname(f), "llvm.");
}
// skipProfileForFunction
sp_skip_profile_for_function :: (f: Value_Id) -> bool {
    return is_declaration(f) || !fn_has_str_attr(f, "use-sample-profile");
}
sp_fn_guid :: (name: string) -> u64 { return md5_hash_u64(name); }   // Function::getGUIDAssumingExternalLinkage

// clearFunctionData
spl_clear_function_data :: () {
    table_reset(*spl.block_weights);
    table_reset(*spl.edge_weights);
    table_reset(*spl.visited_blocks);
    table_reset(*spl.visited_edges);
    table_reset(*spl.equiv);
    table_reset(*spl.preds);
    table_reset(*spl.succs);
    if spl.dt { dt_free(spl.dt); spl.dt = null; }
    if spl.pdt { dt_free(spl.pdt); spl.pdt = null; }
    if spl.li { li_free(spl.li); spl.li = null; }
    table_reset(*spl.coverage);
    spl.total_used_samples = 0;
}

// ---------------------------------------------------------------- the pass

// SampleProfileLoaderPass::run
sample_profile_run :: (file_in: string, remap_in: string, phase: Lto_Phase, disable_inlining: bool, use_flattened: bool) -> Preserved {
    file := ifx file_in.count then file_in else sp_opts.file;
    remap := ifx remap_in.count then remap_in else sp_opts.remapping_file;
    spl.phase = phase;
    spl.disable_inlining = disable_inlining;
    spl.use_flattened = use_flattened;
    lcg_get();
    if !spl_do_initialization(file, remap) return PRESERVE_ALL;
    psi := psi_require();
    if !spl_run_on_module(psi) return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// doInitialization
spl_do_initialization :: (file: string, remap: string) -> bool {
    r := *sp_reader;
    sp_reader_open(file, remap);
    r.skip_flat_prof = spl.phase == .THIN_POST_LINK;
    sp_reader_read();
    if sp_opts.disable_sample_loader_inlining_given spl.disable_inlining = sp_opts.disable_sample_loader_inlining;
    if spl.use_flattened sp_flatten_profiles_in_place();
    spl.prof_acc_for_syms_in_list = sp_opts.profile_accurate_for_symsinlist && r.has_psl && !sp_opts.profile_sample_accurate;
    if spl.prof_acc_for_syms_in_list {
        table_reset(*spl.names_in_profile);
        table_reset(*spl.guids_in_profile);
        for r.name_table {
            if sp_flags.use_md5 table_set(*spl.guids_in_profile, fid_hash(it), true);
            else table_set(*spl.names_in_profile, it.s, true);
        }
    }
    if sp_opts.inline_replay.count fatal("sample-profile: -sample-profile-inline-replay (ReplayInlineAdvisor) is not implemented yet");
    if r.is_cs || r.is_preinlined || r.is_probe_based {
        o := *sp_opts;
        if !o.use_iterative_bfi_inference_given o.use_iterative_bfi_inference = true;
        if !o.use_profi_given o.use_profi = true;
        if !o.ext_tsp_block_placement_given o.ext_tsp_block_placement = true;
        if !o.profile_size_inline_given o.profile_size_inline = true;
        if !o.prioritized_inline_given o.prioritized_inline = true;
        if !o.recursive_inline_given o.recursive_inline = true;
        if r.is_preinlined && !o.use_preinliner_given o.use_preinliner = true;
        if r.is_probe_based {
            if !o.salvage_stale_profile_given o.salvage_stale_profile = true;
            if !o.salvage_unused_profile_given o.salvage_unused_profile = true;
        }
        if !r.is_cs {
            if !o.inline_limit_min_given o.inline_limit_min = 0xFFFF_FFFF;
            if !o.inline_limit_max_given o.inline_limit_max = 0xFFFF_FFFF;
        }
    }
    if r.is_cs sp_context_tracker_init();
    if r.is_probe_based {
        spl_probe_manager_init();
        if !spl.has_probe_manager {
            // "Pseudo-probe-based profile requires SampleProfileProbePass" (a warning)
            print_to_stderr("warning: %: Pseudo-probe-based profile requires SampleProfileProbePass\n", ir.module_id);
            return false;
        }
    }
    if sp_opts.report_profile_staleness || sp_opts.persist_profile_staleness || sp_opts.salvage_stale_profile
        sp_matcher_init();
    return true;
}

// PseudoProbeManager(M)
spl_probe_manager_init :: () {
    spl.has_probe_manager = false;
    k := named_md_find("llvm.pseudo_probe_desc");
    if k < 0 return;
    spl.has_probe_manager = true;
    for m: ir.named_md[k].ops {
        guid := const_int_zext(md_const_int_op(m, 0));
        hash := const_int_zext(md_const_int_op(m, 1));
        if !table_contains(*spl.probe_desc, guid) table_set(*spl.probe_desc, guid, hash);
    }
    for f: ir.m_functions {
        l := glob(f).linkage;
        if l == .WEAK_ANY || l == .WEAK_ODR || l == .EXTERN_WEAK {
            g := sp_fn_guid(sp_canonical_fn_name_of(f));
            if table_contains(*spl.probe_desc, g) table_set(*spl.probe_weak, g, true);
        }
    }
}
// PseudoProbeManager::profileIsValid
spl_profile_is_valid :: (f: Value_Id, fs: *Fs) -> bool {
    found, hash := table_find(*spl.probe_desc, sp_fn_guid(sp_canonical_fn_name_of(f)));
    if glob(f).linkage == .AVAILABLE_EXTERNALLY || !found return !fn_has_str_attr(f, "profile-checksum-mismatch");
    return hash == fs.function_hash;
}

// runOnModule
spl_run_on_module :: (psi: *Psi) -> bool {
    r := *sp_reader;
    // GUIDToFuncNameMapper
    if r.use_md5 {
        for f: ir.m_functions {
            n := vname(f);
            g := sp_fn_guid(n);
            if !table_contains(*spl.guid_to_name, g) table_set(*spl.guid_to_name, g, n);
            c := sp_canonical_fn_name_of(f);
            if c != n { g2 := sp_fn_guid(c); if !table_contains(*spl.guid_to_name, g2) table_set(*spl.guid_to_name, g2, c); }
        }
    }
    spl.psi = psi;
    if module_flag("ProfileSummary") == NONE {
        module_set_flag(1, "ProfileSummary", sp_summary_md(*r.summary));
        psi_refresh();
    }
    if sp_flags.probe_based && spl_reject_high_staleness_profile() return false;
    // the symbol map
    table_reset(*spl.symbol_map);
    orig_names: Table(u64, Value_Id); orig_names.allocator = temp;
    for f: ir.m_functions if vname(f).count table_set(*orig_names, sp_fn_guid(vname(f)), f);
    for f: ir.m_functions {
        orig := vname(f);
        if orig.count == 0 continue;
        table_set(*spl.symbol_map, sp_fn_guid(orig), f);
    }
    for f: ir.m_functions {
        orig := vname(f);
        if orig.count == 0 continue;
        nn := sp_canonical_fn_name_of(f);
        if orig != nn && nn.count {
            g := sp_fn_guid(nn);
            found, other := table_find(*orig_names, g);
            if found && other != f
                fatal("sample-profile: the stripped name '%' of '%' is also the name of a function (the result depends on the symbol table's hash order)", nn, orig);
            ex := table_find_pointer(*spl.symbol_map, g);
            if ex ex.* = NONE; else table_set(*spl.symbol_map, g, f);
            orig = nn;
        }
        if r.remapper_present {
            ok, mapped := sp_remapper_lookup(orig);
            if ok && mapped != orig && mapped.count {
                g := sp_fn_guid(mapped);
                if !table_contains(*spl.symbol_map, g) table_set(*spl.symbol_map, g, f);
            }
        }
    }
    if sp_opts.report_profile_staleness || sp_opts.persist_profile_staleness || sp_opts.salvage_stale_profile
        sp_matcher_run_on_module();
    changed := false;
    order := spl_build_function_order();
    for f: order {
        spl_clear_function_data();
        if spl_run_on_function(f) changed = true;
    }
    if !sp_flags.cs for spl.not_inlined_info update_profile_callee(it.f, cast,no_check(s64) it.entry_count, null);
    if sp_opts.remove_probe && sp_flags.probe_based fatal("sample-profile: -sample-profile-remove-probe is not implemented yet");
    return changed;
}

// ProfileSummaryInfo::refresh
psi_refresh :: () {
    p := *psi_state;
    if p.computed && p.has_summary return;
    p.* = .{};
    psi_get();
}

// rejectHighStalenessProfile
spl_reject_high_staleness_profile :: () -> bool {
    total_hot: u64 = 0;
    mismatched: u64 = 0;
    for fs: sp_reader.profiles {
        found, hash := table_find(*spl.probe_desc, fs_guid(fs));
        if !found continue;
        if !psi_is_hot_count_nth_percentile(spl.psi, sp_opts.hot_func_cutoff_for_staleness_error, fs.total) continue;
        total_hot += 1;
        if hash != fs.function_hash && !table_contains(*spl.probe_weak, fs_guid(fs)) mismatched += 1;
    }
    if total_hot < sp_opts.min_functions_for_staleness_error return false;
    if mismatched * 100 >= total_hot * sp_opts.percent_mismatch_for_staleness_error {
        fatal("%: The input profile significantly mismatches current source code. Please recollect profile to avoid performance regression.", ir.module_id);
    }
    return false;
}

// runOnFunction
spl_run_on_function :: (f: Value_Id) -> bool {
    table_reset(*spl.dil_samples);
    initial_entry_count: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    r := *sp_reader;
    spl.prof_acc_for_syms_in_list = sp_opts.profile_accurate_for_symsinlist && r.has_psl;
    if sp_opts.profile_sample_accurate || fn_has_str_attr(f, "profile-sample-accurate") {
        initial_entry_count = 0;
        spl.prof_acc_for_syms_in_list = false;
    }
    if spl.prof_acc_for_syms_in_list {
        if sp_psl_contains(vname(f)) initial_entry_count = 0;
        canon := sp_canonical_fn_name_of(f);
        if (sp_flags.use_md5 && table_contains(*spl.guids_in_profile, sp_fn_guid(canon))) || (!sp_flags.use_md5 && table_contains(*spl.names_in_profile, canon))
            initial_entry_count = 0xFFFF_FFFF_FFFF_FFFF;
    }
    if !fn_entry_count(f) fn_set_entry_count(f, initial_entry_count);
    if sp_flags.cs spl.samples = sp_ctx_get_base_samples_for(f);
    else {
        spl.samples = sp_get_samples_for(f);
        if !spl.samples {
            canon := sp_canonical_fn_name_of(f);
            found, s := table_find(*spl.outline_samples, canon);
            if found spl.samples = s;
            else if r.remapper_present {
                ok, mapped := sp_remapper_lookup(canon);
                if ok { found2, s2 := table_find(*spl.outline_samples, mapped); if found2 spl.samples = s2; }
            }
        }
    }
    if spl.samples && !fs_empty(spl.samples) return spl_emit_annotations(f);
    return false;
}

// emitAnnotations
spl_emit_annotations :: (f: Value_Id) -> bool {
    changed := false;
    if sp_flags.probe_based {
        if !spl_profile_is_valid(f, spl.samples) {
            if !sp_opts.salvage_stale_profile return false;
        }
    } else {
        if spl_get_function_loc(f) == 0 return false;
    }
    inlined_guids: [..] u64; inlined_guids.allocator = temp;
    if sp_opts.prioritized_inline changed |= spl_inline_hot_functions_with_priority(f, *inlined_guids);
    else changed |= spl_inline_hot_functions(f, *inlined_guids);
    changed |= spl_compute_and_propagate_weights(f, inlined_guids);
    if changed spl_generate_md_prof_metadata(f);
    spl_emit_coverage_remarks(f);
    return changed;
}

// getFunctionLoc
spl_get_function_loc :: (f: Value_Id) -> u32 {
    sp := fn_subprogram(f);
    if sp != NONE return cast(u32) di_int(sp, 0);
    if sp_opts.no_warn_sample_unused return 0;
    print_to_stderr("warning: No debug information found in function %: Function profile not used\n", vname(f));
    return 0;
}

spl_emit_coverage_remarks :: (f: Value_Id) {
    if sp_opts.record_coverage || sp_opts.sample_coverage fatal("sample-profile: -sample-profile-check-*-coverage is not implemented yet");
}

// callsiteIsHot
sp_callsite_is_hot :: (fs: *Fs, psi: *Psi, prof_acc: bool) -> bool {
    if !fs return false;
    if prof_acc return !psi_is_cold_count(psi, fs.total);
    return psi_is_hot_count(psi, fs.total);
}

// ---------------------------------------------------------------- finding samples

// findFunctionSamples (SampleProfileLoader's override)
spl_find_function_samples :: (i: Value_Id) -> *Fs {
    if sp_flags.probe_based {
        ok := sp_extract_probe(i);
        if !ok return null;
    }
    dil := get_metadata(i, 0);
    if dil == NONE return spl.samples;
    found, fs := table_find(*spl.dil_samples, dil);
    if found return fs;
    if sp_flags.cs fs = sp_ctx_get_context_samples_for(dil);
    else fs = fs_find_function_samples(spl.samples, dil, true, sp_reader.func_name_to_prof_name);
    table_set(*spl.dil_samples, dil, fs);
    return fs;
}

// findCalleeFunctionSamples
spl_find_callee_function_samples :: (i: Value_Id) -> *Fs {
    dil := get_metadata(i, 0);
    if dil == NONE return null;
    callee_name := "";
    callee := call_called_function(i);
    if callee != NONE callee_name = vname(callee);
    if sp_flags.cs return sp_ctx_get_callee_context_samples_for(i, callee_name);
    fs := spl_find_function_samples(i);
    if !fs return null;
    return fs_find_function_samples_at(fs, sp_callsite_id(dil), callee_name, true, sp_reader.func_name_to_prof_name);
}

// findIndirectCallFunctionSamples: the targets sorted by entry samples, and Sum
spl_find_indirect_call_function_samples :: (i: Value_Id) -> ([..] *Fs, u64) {
    out: [..] *Fs; out.allocator = temp;
    sum: u64 = 0;
    dil := get_metadata(i, 0);
    if dil == NONE return out, 0;
    fs_less :: (l: *Fs, r: *Fs) -> bool {
        a := fs_head_samples_estimate(l); b := fs_head_samples_estimate(r);
        if a != b return a > b;
        return fs_guid(l) < fs_guid(r);
    }
    sort_fs :: (a: *[..] *Fs) {
        for k: 1..a.count - 1 {
            x := a.*[k]; j := k - 1;
            while j >= 0 && fs_less(x, a.*[j]) { a.*[j + 1] = a.*[j]; j -= 1; }
            a.*[j + 1] = x;
        }
    }
    if sp_flags.cs {
        callees := sp_ctx_get_indirect_callee_context_samples_for(dil);
        if callees.count == 0 return out, sum;
        for callees { sum += fs_head_samples_estimate(it); array_add(*out, it); }
        sort_fs(*out);
        return out, sum;
    }
    fs := spl_find_function_samples(i);
    if !fs return out, 0;
    cs := sp_callsite_id(dil);
    t := fs_find_call_target_map_at(fs, cs);
    if t for t.targets sum += it.count;
    m := fs_find_function_samples_map_at(fs, cs);
    if m {
        if m.callees.count == 0 return out, sum;
        for m.callees { sum += fs_head_samples_estimate(it.fs); array_add(*out, it.fs); }
        sort_fs(*out);
    }
    return out, sum;
}

// getInstWeight (SampleProfileLoader's override)
spl_get_inst_weight :: (i: Value_Id) -> (bool, u64) {
    if sp_flags.probe_based { a, b := spl_get_probe_weight(i); return a, b; }
    dil := get_metadata(i, 0);
    if dil == NONE return false, 0;
    op := inst_op(i);
    if op == .BR || op == .CONDBR || op == .PHI || sp_is_intrinsic_inst(i) return false, 0;
    if !sp_flags.cs && is_call_base(i) && !call_is_indirect(i) && spl_find_callee_function_samples(i) return true, 0;
    a, b := spl_get_inst_weight_impl(i);
    return a, b;
}
// getInstWeightImpl
spl_get_inst_weight_impl :: (i: Value_Id) -> (bool, u64) {
    fs := spl_find_function_samples(i);
    if !fs return false, 0;
    dil := get_metadata(i, 0);
    if dil == NONE return false, 0;
    off := sp_offset(dil);
    disc := diloc_base_discriminator(dil);
    found, r := fs_find_samples_at(fs, off, disc);
    if found spl_coverage_mark(fs, off, disc, r);
    return found, r;
}
// getProbeWeight
spl_get_probe_weight :: (i: Value_Id) -> (bool, u64) {
    ok, p := sp_extract_probe(i);
    if !ok return false, 0;
    fs := spl_find_function_samples(i);
    if !fs return false, 0;
    found, r := fs_find_samples_at(fs, p.id, p.disc);
    if found {
        s := cast(u64) (cast(float32) r * p.factor);
        spl_coverage_mark(fs, p.id, 0, s);
        return true, s;
    }
    return false, 0;
}
// SampleCoverageTracker::markSamplesUsed
spl_coverage_mark :: (fs: *Fs, line: u32, disc: u32, samples: u64) {
    l := table_find_pointer(*spl.coverage, fs);
    if !l { e: [..] Line_Loc; table_set(*spl.coverage, fs, e); l = table_find_pointer(*spl.coverage, fs); }
    for l.* if it.line == line && it.disc == disc return;
    array_add(l, .{line, disc});
    spl.total_used_samples += samples;
}

// getBlockWeight
spl_get_block_weight :: (b: Value_Id) -> (bool, u64) {
    mx: u64 = 0;
    has := false;
    for i: block_insts(b) {
        ok, w := spl_get_inst_weight(i);
        if ok { if w > mx mx = w; has = true; }
    }
    return has, mx;
}

// computeBlockWeights
spl_compute_block_weights :: (f: Value_Id) -> bool {
    changed := false;
    for b: fn_blocks(f) {
        ok, w := spl_get_block_weight(b);
        if ok {
            spl_set_bw(b, w);
            spl_visit_block(b);
            changed = true;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- propagation

// findEquivalencesFor
spl_find_equivalences_for :: (bb1: Value_Id, descendants: [] Value_Id) {
    ec := spl_ec(bb1);
    weight := spl_bw(ec);
    for bb2: descendants {
        is_dom_parent := dt_dominates(spl.pdt, bb2, bb1);
        same_loop := li_loop_for(spl.li, bb1) == li_loop_for(spl.li, bb2);
        if bb1 != bb2 && is_dom_parent && same_loop {
            table_set(*spl.equiv, bb2, ec);
            if spl_visited_block(bb2) spl_visit_block(ec);
            w2 := spl_bw(bb2);
            if w2 > weight weight = w2;
        }
    }
    if ec == fn_entry(block_fn(ec)) spl_set_bw(ec, spl.samples.head + 1);
    else spl_set_bw(ec, weight);
}

// DominatorTreeBase::getDescendants
spl_dt_descendants :: (dt: *Dom_Tree, b: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    n := dt_node(dt, b);
    if n < 0 return;
    wl: [..] s32; wl.allocator = temp;
    array_add(*wl, n);
    while wl.count {
        x := pop(*wl);
        array_add(out, dt.nodes[x].block);
        c := dt.nodes[x].first_child;
        while c >= 0 { array_add(*wl, c); c = dt.nodes[c].sibling; }
    }
}

// findEquivalenceClasses
spl_find_equivalence_classes :: (f: Value_Id) {
    dominated: [..] Value_Id; dominated.allocator = temp;
    for bb1: fn_blocks(f) {
        if table_contains(*spl.equiv, bb1) continue;
        table_set(*spl.equiv, bb1, bb1);
        spl_dt_descendants(spl.dt, bb1, *dominated);
        spl_find_equivalences_for(bb1, dominated);
    }
    for bb: fn_blocks(f) {
        e := spl_ec(bb);
        if bb != e spl_set_bw(bb, spl_bw(e));
    }
}

// visitEdge
spl_visit_edge :: (a: Value_Id, b: Value_Id, num_unknown: *u32, unknown: *[2] Value_Id) -> u64 {
    if !table_contains(*spl.visited_edges, spl_edge_key(a, b)) {
        num_unknown.* += 1;
        unknown.*[0] = a; unknown.*[1] = b;
        return 0;
    }
    return spl_ew(a, b);
}

// propagateThroughEdges
spl_propagate_through_edges :: (f: Value_Id, update_block_count: bool) -> bool {
    changed := false;
    for bb: fn_blocks(f) {
        ec := spl_ec(bb);
        for i: 0..1 {
            total: u64 = 0;
            num_unknown: u32 = 0;
            num_total := 0;
            unknown: [2] Value_Id = .[NONE, NONE];
            self_ref: [2] Value_Id = .[NONE, NONE];
            single: [2] Value_Id = .[NONE, NONE];
            if i == 0 {
                preds := table_find_pointer(*spl.preds, bb);
                num_total = preds.count;
                for p: preds.* {
                    total += spl_visit_edge(p, bb, *num_unknown, *unknown);
                    if p == bb { self_ref[0] = p; self_ref[1] = bb; }
                }
                if num_total == 1 { single[0] = preds.*[0]; single[1] = bb; }
            } else {
                succs := table_find_pointer(*spl.succs, bb);
                num_total = succs.count;
                for s: succs.* total += spl_visit_edge(bb, s, *num_unknown, *unknown);
                if num_total == 1 { single[0] = bb; single[1] = succs.*[0]; }
            }
            if num_unknown <= 1 {
                bbw := spl_bw(ec);
                if num_unknown == 0 {
                    if !spl_visited_block(ec) {
                        if total > bbw { spl_set_bw(ec, total); changed = true; }
                    } else if num_total == 1 && spl_ew(single[0], single[1]) < spl_bw(ec) {
                        spl_set_ew(single[0], single[1], spl_bw(ec));
                        changed = true;
                    }
                } else if num_unknown == 1 && spl_visited_block(ec) {
                    w := ifx bbw >= total then bbw - total else 0;
                    spl_set_ew(unknown[0], unknown[1], w);
                    other_ec := ifx i == 0 then spl_ec(unknown[0]) else spl_ec(unknown[1]);
                    if spl_visited_block(other_ec) && spl_ew(unknown[0], unknown[1]) > spl_bw(other_ec)
                        spl_set_ew(unknown[0], unknown[1], spl_bw(other_ec));
                    table_set(*spl.visited_edges, spl_edge_key(unknown[0], unknown[1]), true);
                    changed = true;
                }
            } else if spl_visited_block(ec) && spl_bw(ec) == 0 {
                if i == 0 {
                    for p: table_find_pointer(*spl.preds, bb).* { spl_set_ew(p, bb, 0); table_set(*spl.visited_edges, spl_edge_key(p, bb), true); }
                } else {
                    for s: table_find_pointer(*spl.succs, bb).* { spl_set_ew(bb, s, 0); table_set(*spl.visited_edges, spl_edge_key(bb, s), true); }
                }
            } else if self_ref[0] != NONE && spl_visited_block(ec) {
                bbw := spl_bw(bb);
                w := ifx bbw >= total then bbw - total else 0;
                spl_set_ew(self_ref[0], self_ref[1], w);
                table_set(*spl.visited_edges, spl_edge_key(self_ref[0], self_ref[1]), true);
                changed = true;
            }
            if update_block_count && total > 0 && spl_visit_block(ec) {
                spl_set_bw(ec, total);
                changed = true;
            }
        }
    }
    return changed;
}

// buildEdges
spl_build_edges :: (f: Value_Id) {
    tmp: [..] Value_Id; tmp.allocator = temp;
    for b1: fn_blocks(f) {
        preds: [..] Value_Id;
        block_predecessors(b1, *tmp);
        for p: tmp { dup := false; for preds if it == p dup = true; if !dup array_add(*preds, p); }
        table_set(*spl.preds, b1, preds);
        succs: [..] Value_Id;
        tmp.count = 0;
        block_successors(b1, *tmp);
        for s: tmp { dup := false; for succs if it == s dup = true; if !dup array_add(*succs, s); }
        table_set(*spl.succs, b1, succs);
        tmp.count = 0;
    }
}

// propagateWeights
spl_propagate_weights :: (f: Value_Id) {
    if sp_opts.use_profi {
        sample_weights: Table(Value_Id, u64); sample_weights.allocator = temp;
        for b: fn_blocks(f) {
            ok, w := spl_get_block_weight(b);
            if ok table_set(*sample_weights, b, w);
        }
        sp_apply_profi(f, *sample_weights);
        return;
    }
    for bb: fn_blocks(f) {
        l := li_loop_for(spl.li, bb);
        if l == NONE continue;
        header := li_header(spl.li, l);
        if header != NONE && spl_bw(bb) > spl_bw(header) spl_set_bw(header, spl_bw(bb));
    }
    changed := true;
    i: u32 = 0;
    while changed && i < sp_opts.max_propagate_iterations { i += 1; changed = spl_propagate_through_edges(f, false); }
    if changed i += 1;   // the failed `I++ < Max` test still increments
    table_reset(*spl.visited_edges);
    changed = true;
    while changed && i < sp_opts.max_propagate_iterations { i += 1; changed = spl_propagate_through_edges(f, false); }
    if changed i += 1;
    changed = true;
    while changed && i < sp_opts.max_propagate_iterations { i += 1; changed = spl_propagate_through_edges(f, true); }
}

// computeAndPropagateWeights
spl_compute_and_propagate_weights :: (f: Value_Id, inlined_guids: [] u64) -> bool {
    changed := inlined_guids.count != 0;
    changed |= spl_compute_block_weights(f);
    if changed {
        // initWeightPropagation
        fn_set_entry_count_with_imports(f, spl.samples.head + 1, inlined_guids);
        if !sp_opts.use_profi {
            spl.dt = dt_new(false); dt_recalculate(spl.dt, f);
            spl.pdt = dt_new(true); dt_recalculate(spl.pdt, f);
            spl.li = li_new(f); li_analyze(spl.li, spl.dt);
            spl_find_equivalence_classes(f);
        }
        spl_build_edges(f);
        spl_propagate_weights(f);
        // finalizeWeightPropagation
        if sp_opts.use_profi {
            e := fn_entry(f);
            if spl_bw(e) > 0 fn_set_entry_count_with_imports(f, spl_bw(e), inlined_guids);
        }
    }
    return changed;
}

// Function::setEntryCount(Count, &Imports): the import GUIDs are replaced by the given set (sorted)
fn_set_entry_count_with_imports :: (f: Value_Id, count: u64, guids_in: [] u64) {
    guids: [..] u64; guids.allocator = temp;
    for guids_in array_add(*guids, it);
    for a: 1..guids.count - 1 {
        x := guids[a]; b := a - 1;
        while b >= 0 && guids[b] > x { guids[b + 1] = guids[b]; b -= 1; }
        guids[b + 1] = x;
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("function_entry_count"));
    array_add(*ops, md_value(const_int(ir.t_i64, count)));
    for guids array_add(*ops, md_value(const_int(ir.t_i64, it)));
    set_metadata(f, md_fixed("prof"), md_tuple(ops, false));
}

// ---------------------------------------------------------------- metadata

// updateIDTMetaData
sp_update_idt_metadata :: (i: Value_Id, call_targets: [] Vp_Data, sum_in: u64) {
    if sp_opts.icp_max_prom == 0 return;
    sum := sum_in;
    vd, _, old_sum := vp_get_value_prof_data(i, IPVK_INDIRECT_CALL_TARGET, sp_opts.icp_max_prom, true);
    // ValueCountMap (a DenseMap; the result is sorted below)
    vcm: [..] Vp_Data; vcm.allocator = temp;
    find :: (m: *[..] Vp_Data, v: u64) -> s64 { for m.* if it.value == v return it_index; return -1; }
    if sum == 0 {
        for vd { k := find(*vcm, it.value); if k >= 0 vcm[k].count = it.count; else array_add(*vcm, it); }
        k := find(*vcm, call_targets[0].value);
        if k < 0 array_add(*vcm, call_targets[0]);
        else { old_sum -= vcm[k].count; vcm[k].count = NOMORE_ICP_MAGICNUM; }
        sum = old_sum;
    } else {
        for vd if it.count == NOMORE_ICP_MAGICNUM { k := find(*vcm, it.value); if k >= 0 vcm[k].count = it.count; else array_add(*vcm, it); }
        for d: call_targets {
            k := find(*vcm, d.value);
            if k < 0 { array_add(*vcm, d); continue; }
            sum -= d.count;
        }
    }
    // sort by (Count, Value) descending
    for a: 1..vcm.count - 1 {
        x := vcm[a]; b := a - 1;
        while b >= 0 && (x.count > vcm[b].count || (x.count == vcm[b].count && x.value > vcm[b].value)) { vcm[b + 1] = vcm[b]; b -= 1; }
        vcm[b + 1] = x;
    }
    max_md := min(cast(u32) vcm.count, sp_opts.icp_max_prom);
    vp_annotate_value_site(i, vcm, sum, IPVK_INDIRECT_CALL_TARGET, max_md);
}

// generateMDProfMetadata
spl_generate_md_prof_metadata :: (f: Value_Id) {
    prof := md_fixed("prof");
    for bb: fn_blocks(f) {
        if spl_bw(bb) {
            for i: block_insts(bb) {
                if inst_op(i) != .CALL && inst_op(i) != .INVOKE continue;
                if call_called_function(i) == NONE {
                    dil := get_metadata(i, 0);
                    if dil == NONE continue;
                    fs := spl_find_function_samples(i);
                    if !fs continue;
                    cs := sp_callsite_id(dil);
                    t := fs_find_call_target_map_at(fs, cs);
                    if !t || t.targets.count == 0 continue;
                    targets := t.targets;
                    if sp_flags.probe_based {
                        ok, p := sp_extract_probe(i);
                        if ok && p.factor < 1 {
                            adj := NewArray(targets.count, Call_Target,, allocator = temp);
                            for targets adj[it_index] = .{it.f, cast(u64) (cast(float32) it.count * p.factor)};
                            targets.data = adj.data; targets.count = adj.count;
                        }
                    }
                    sorted := sp_sort_call_targets(targets);
                    vds := NewArray(sorted.count, Vp_Data,, allocator = temp);
                    for sorted vds[it_index] = .{fid_hash(it.f), it.count};
                    sum: u64 = 0;
                    for targets sum += it.count;
                    if !sp_flags.cs {
                        m := fs_find_function_samples_map_at(fs, cs);
                        if m for m.callees sum += fs_head_samples_estimate(it.fs);
                    }
                    if sum sp_update_idt_metadata(i, vds, sum);
                    else if sp_opts.overwrite_existing_weights set_metadata(i, prof, NONE);
                } else if !sp_is_intrinsic_inst(i) {
                    w := spl_bw(bb);
                    prof_set_branch_weights(i, .[cast,no_check(u32) w], false);
                }
            }
        } else if sp_opts.overwrite_existing_weights || sp_opts.profile_sample_block_accurate {
            for i: block_insts(bb) {
                if inst_op(i) != .CALL && inst_op(i) != .INVOKE continue;
                if call_is_indirect(i) set_metadata(i, prof, NONE);
                else prof_set_branch_weights(i, .[0], false);
            }
        }
        ti := block_terminator(bb);
        ns := num_successors(ti);
        if ns == 1 continue;
        op := inst_op(ti);
        if op != .CONDBR && op != .SWITCH && op != .INDIRECTBR continue;
        weights: [..] u32; weights.allocator = temp;
        max_weight: u64 = 0;
        mult: [..] struct { b: Value_Id; n: u64; }; mult.allocator = temp;
        edge_index: [..] u64; edge_index.allocator = temp;
        mult_of :: (m: *[..] $T, b: Value_Id) -> *T {
            for * m.* if it.b == b return it;
            array_add(m, .{b, 0});
            return *m.*[m.count - 1];
        }
        if sp_opts.use_profi {
            for k: 0..ns - 1 {
                s := get_successor(ti, k);
                e := mult_of(*mult, s);
                array_add(*edge_index, e.n);
                e.n += 1;
            }
        }
        for k: 0..ns - 1 {
            s := get_successor(ti, k);
            weight := spl_ew(bb, s);
            if weight > 0xFFFF_FFFF weight = 0xFFFF_FFFF;
            if !sp_opts.use_profi {
                array_add(*weights, cast(u32) (ifx weight == 0xFFFF_FFFF then weight else weight + 1));
            } else {
                m := mult_of(*mult, s).n;
                w := weight / m;
                if edge_index[k] < weight % m w += 1;
                array_add(*weights, cast(u32) w);
            }
            if weight != 0 && weight > max_weight max_weight = weight;
        }
        has_total, _ := prof_extract_total_weight(ti);
        if max_weight > 0 && (!has_total || sp_opts.overwrite_existing_weights) {
            prof_set_branch_weights(ti, weights, false);
        } else if sp_opts.overwrite_existing_weights {
            set_metadata(ti, prof, NONE);
        }
    }
}

// ---------------------------------------------------------------- inlining

// shouldInlineColdCallee
spl_should_inline_cold_callee :: (cb: Value_Id) -> bool {
    if !sp_opts.profile_size_inline return false;
    callee := call_called_function(cb);
    if callee == NONE return false;
    ic_no_profile_analyses = true;
    cost := get_inline_cost(cb, get_inline_params());
    ic_no_profile_analyses = false;
    if ic_is_never(cost) return false;
    if ic_is_always(cost) return true;
    return cost.cost <= sp_opts.cold_inline_threshold;
}

// shouldInlineCandidate
spl_should_inline_candidate :: (c: *Spl_Inline_Candidate) -> Inline_Cost {
    sample_threshold := sp_opts.cold_inline_threshold;
    if sp_opts.prioritized_inline {
        if c.callsite_count > spl.psi.hot sample_threshold = sp_opts.hot_inline_threshold;   // getHotCountThreshold
        else if !sp_opts.profile_size_inline return inline_cost_never("cold callsite");
    }
    callee := call_called_function(c.call);
    params := get_inline_params();
    params.compute_full_inline_cost = true;
    params.allow_recursive_call = sp_opts.recursive_inline;
    ic_no_profile_analyses = true;
    cost := get_inline_cost_for_callee(c.call, callee, params);
    ic_no_profile_analyses = false;
    if ic_is_never(cost) || ic_is_always(cost) return cost;
    if sp_opts.use_preinliner && c.callee_samples {
        cx := *c.callee_samples.ctx;
        if !(cx.state & CTX_SYNTHETIC) && (cx.attrs & CTX_SHOULD_BE_INLINED) return inline_cost_always("preinliner");
    }
    if !sp_opts.prioritized_inline return inline_cost_get(cost.cost, sp_opts.hot_inline_threshold);
    return inline_cost_get(cost.cost, sample_threshold);
}

// tryInlineCandidate
spl_try_inline_candidate :: (c: *Spl_Inline_Candidate, inlined_call_sites: *[..] Value_Id = null) -> bool {
    if spl.disable_inlining return false;
    cb := c.call;
    cost := spl_should_inline_candidate(c);
    if ic_is_never(cost) return false;
    if !ic_bool(cost) return false;
    caller := inst_fn(cb);
    ifi: Inline_Function_Info;
    ifi.use_assumption_cache = true;
    ifi.update_profile = false;
    r := inline_function(cb, *ifi, true, null, true, false);
    if !r.ok return false;
    fam_invalidate(caller, PRESERVE_NONE);
    table_reset(*spl.dil_samples);
    if inlined_call_sites {
        inlined_call_sites.count = 0;
        for ifi.inlined_call_sites array_add(inlined_call_sites, it);
    }
    if sp_flags.cs sp_ctx_mark_context_samples_inlined(c.callee_samples);
    if c.distribution < 1 {
        for ifi.inlined_call_sites {
            ok, p := sp_extract_probe(it);
            if ok sp_set_probe_distribution_factor(it, p.factor * c.distribution);
        }
    }
    return true;
}

// getInlineCandidate
spl_get_inline_candidate :: (out: *Spl_Inline_Candidate, cb: Value_Id) -> bool {
    if sp_is_intrinsic_inst(cb) return false;
    callee_samples := spl_find_callee_function_samples(cb);
    if !callee_samples return false;
    factor: float32 = 1.0;
    ok, p := sp_extract_probe(cb);
    if ok factor = p.factor;
    count: u64 = 0;
    if callee_samples count = cast(u64) (cast(float32) fs_head_samples_estimate(callee_samples) * factor);
    out.* = .{cb, callee_samples, count, factor};
    return true;
}

Spl_Not_Inlined :: struct { call: Value_Id; fs: *Fs; }   // an entry of a MapVector<CallBase *, const FunctionSamples *>
spl_ni_insert :: (m: *[..] Spl_Not_Inlined, cb: Value_Id, fs: *Fs) { for m.* if it.call == cb return; array_add(m, .{cb, fs}); }
spl_ni_erase :: (m: *[..] Spl_Not_Inlined, cb: Value_Id) { for m.* if it.call == cb { array_ordered_remove_by_index(m, it_index); return; } }
spl_ni_lookup :: (m: *[..] Spl_Not_Inlined, cb: Value_Id) -> *Fs { for m.* if it.call == cb return it.fs; return null; }

// inlineHotFunctions
spl_inline_hot_functions :: (f: Value_Id, inlined_guids: *[..] u64) -> bool {
    local_not_inlined: [..] Spl_Not_Inlined; local_not_inlined.allocator = temp;
    changed := false;
    local_changed := true;
    while local_changed {
        local_changed = false;
        cis: [..] Value_Id; cis.allocator = temp;
        all: [..] Value_Id; all.allocator = temp;
        cold: [..] Value_Id; cold.allocator = temp;
        for bb: fn_blocks(f) {
            hot := false;
            all.count = 0; cold.count = 0;
            for i: block_insts(bb) {
                if !is_call_base(i) || sp_is_intrinsic_inst(i) continue;
                fs := spl_find_callee_function_samples(i);
                if fs {
                    array_add(*all, i);
                    if fs_head_samples_estimate(fs) > 0 || sp_flags.cs spl_ni_insert(*local_not_inlined, i, fs);
                    if sp_callsite_is_hot(fs, spl.psi, spl.prof_acc_for_syms_in_list) hot = true;
                    else if spl_should_inline_cold_callee(i) array_add(*cold, i);
                }
            }
            src := ifx hot then all else cold;
            // CIS.insert(CIS.begin(), ...)
            n := src.count;
            if n {
                old := cis.count;
                array_resize(*cis, old + n);
                k := old - 1;
                while k >= 0 { cis[k + n] = cis[k]; k -= 1; }
                for src cis[it_index] = it;
            }
        }
        for i: cis {
            if vkind(i) == .DEAD continue;
            called := call_called_function(i);
            cand := Spl_Inline_Candidate.{i, spl_ni_lookup(*local_not_inlined, i), 0, 1.0};
            if called == f continue;
            if call_is_indirect(i) {
                targets, sum := spl_find_indirect_call_function_samples(i);
                for fs: targets {
                    sum_origin := sum;
                    if spl.phase == .THIN_PRE_LINK {
                        spl_find_external_inline_candidate(i, fs, inlined_guids, psi_or_comp_hot_count_threshold(spl.psi));
                        continue;
                    }
                    if !sp_callsite_is_hot(fs, spl.psi, spl.prof_acc_for_syms_in_list) continue;
                    cand = .{i, fs, fs_head_samples_estimate(fs), 1.0};
                    if spl_try_promote_and_inline_candidate(f, *cand, sum_origin, *sum) {
                        spl_ni_erase(*local_not_inlined, i);
                        local_changed = true;
                    }
                }
            } else if called != NONE && fn_subprogram(called) != NONE && !is_declaration(called) {
                if spl_try_inline_candidate(*cand) {
                    spl_ni_erase(*local_not_inlined, i);
                    local_changed = true;
                }
            } else if spl.phase == .THIN_PRE_LINK {
                spl_find_external_inline_candidate(i, spl_find_callee_function_samples(i), inlined_guids, psi_or_comp_hot_count_threshold(spl.psi));
            }
        }
        changed |= local_changed;
    }
    if !sp_flags.cs spl_promote_merge_not_inlined_context_samples(local_not_inlined, f);
    return changed;
}

// inlineHotFunctionsWithPriority
spl_inline_hot_functions_with_priority :: (f: Value_Id, inlined_guids: *[..] u64) -> bool {
    queue: [..] Spl_Inline_Candidate; queue.allocator = temp;   // a binary heap (std::priority_queue)
    nc: Spl_Inline_Candidate;
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        if spl_get_inline_candidate(*nc, i) spl_heap_push(*queue, nc);
    }
    size_limit: u64 = cast(u64) fn_instruction_count(f) * cast(u64) sp_opts.inline_growth_limit;
    size_limit = min(size_limit, cast(u64) sp_opts.inline_limit_max);
    size_limit = max(size_limit, cast(u64) sp_opts.inline_limit_min);
    size_limit &= 0xFFFF_FFFF;
    local_not_inlined: [..] Spl_Not_Inlined; local_not_inlined.allocator = temp;
    changed := false;
    while queue.count && cast(u64) fn_instruction_count(f) < size_limit {
        cand := spl_heap_pop(*queue);
        i := cand.call;
        if vkind(i) == .DEAD continue;
        called := call_called_function(i);
        if called == f continue;
        if call_is_indirect(i) {
            targets, sum := spl_find_indirect_call_function_samples(i);
            sum_origin := sum;
            sum = cast(u64) (cast(float32) sum * cand.distribution);
            icp_count: u64 = 0;
            for fs: targets {
                if spl.phase == .THIN_PRE_LINK {
                    spl_find_external_inline_candidate(i, fs, inlined_guids, psi_or_comp_hot_count_threshold(spl.psi));
                    continue;
                }
                distributed := cast(u64) (cast(float32) fs_head_samples_estimate(fs) * cand.distribution);
                if icp_count >= sp_opts.icp_relative_hotness_skip && distributed * 100 < sum_origin * sp_opts.icp_relative_hotness break;
                if !psi_is_hot_count(spl.psi, distributed) break;
                inlined: [..] Value_Id; inlined.allocator = temp;
                cand = .{i, fs, distributed, cand.distribution};
                if spl_try_promote_and_inline_candidate(f, *cand, sum_origin, *sum, *inlined) {
                    for cb: inlined if spl_get_inline_candidate(*nc, cb) spl_heap_push(*queue, nc);
                    icp_count += 1;
                    changed = true;
                } else if !sp_flags.cs {
                    spl_ni_insert(*local_not_inlined, i, fs);
                }
            }
        } else if called != NONE && fn_subprogram(called) != NONE && !is_declaration(called) {
            inlined: [..] Value_Id; inlined.allocator = temp;
            if spl_try_inline_candidate(*cand, *inlined) {
                for cb: inlined if spl_get_inline_candidate(*nc, cb) spl_heap_push(*queue, nc);
                changed = true;
            } else if !sp_flags.cs {
                spl_ni_insert(*local_not_inlined, i, cand.callee_samples);
            }
        } else if spl.phase == .THIN_PRE_LINK {
            spl_find_external_inline_candidate(i, spl_find_callee_function_samples(i), inlined_guids, psi_or_comp_hot_count_threshold(spl.psi));
        }
    }
    if !sp_flags.cs spl_promote_merge_not_inlined_context_samples(local_not_inlined, f);
    return changed;
}

// CandidateComparer: true when l has a lower priority than r
spl_cand_less :: (l: Spl_Inline_Candidate, r: Spl_Inline_Candidate) -> bool {
    if l.callsite_count != r.callsite_count return l.callsite_count < r.callsite_count;
    lcs := l.callee_samples; rcs := r.callee_samples;
    if !lcs || !rcs return lcs != null;
    if lcs.body.count != rcs.body.count return lcs.body.count > rcs.body.count;
    return fs_guid(lcs) < fs_guid(rcs);
}
// std::priority_queue push / pop (std::push_heap / std::pop_heap of libstdc++)
spl_heap_push :: (h: *[..] Spl_Inline_Candidate, c: Spl_Inline_Candidate) {
    array_add(h, c);
    // __push_heap
    hole := h.count - 1;
    parent := (hole - 1) / 2;
    while hole > 0 && spl_cand_less(h.*[parent], c) {
        h.*[hole] = h.*[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h.*[hole] = c;
}
spl_heap_pop :: (h: *[..] Spl_Inline_Candidate) -> Spl_Inline_Candidate {
    top := h.*[0];
    n := h.count;
    if n > 1 {
        // __pop_heap: move the last element out, __adjust_heap(first, 0, len - 1, value)
        value := h.*[n - 1];
        len := n - 1;
        hole := 0;
        child := 0;
        while child < (len - 1) / 2 {
            child = 2 * (child + 1);
            if spl_cand_less(h.*[child], h.*[child - 1]) child -= 1;
            h.*[hole] = h.*[child];
            hole = child;
        }
        if (len & 1) == 0 && child == (len - 2) / 2 {
            child = 2 * (child + 1);
            h.*[hole] = h.*[child - 1];
            hole = child - 1;
        }
        // __push_heap(first, hole, top = 0, value)
        parent := (hole - 1) / 2;
        while hole > 0 && spl_cand_less(h.*[parent], value) {
            h.*[hole] = h.*[parent];
            hole = parent;
            parent = (hole - 1) / 2;
        }
        h.*[hole] = value;
    }
    h.count -= 1;
    return top;
}

// promoteMergeNotInlinedContextSamples
spl_promote_merge_not_inlined_context_samples :: (sites: [] Spl_Not_Inlined, f: Value_Id) {
    for sites {
        i := it.call;
        if vkind(i) == .DEAD continue;
        callee := call_called_function(i);
        if callee == NONE || is_declaration(callee) continue;
        fs := it.fs;
        if fs.total == 0 && fs_head_samples_estimate(fs) == 0 continue;
        if fs.ctx.attrs & CTX_DUPLICATED_INTO_BASE continue;
        if sp_opts.merge_inlinee {
            if fs.head == 0 {
                fs_add_head(fs, fs_head_samples_estimate(fs));
                outline := sp_get_samples_for(callee);
                if !outline {
                    canon := sp_canonical_fn_name_of(callee);
                    found, o := table_find(*spl.outline_samples, canon);
                    if found outline = o;
                    else {
                        outline = fs_new();
                        table_set(*spl.outline_samples, copy_string(canon), outline);
                    }
                }
                fs_merge(outline, fs, 1);
                fs_set_context_synthetic(outline);
            }
        } else {
            found := false;
            for * spl.not_inlined_info if it.f == callee { it.entry_count += fs_head_samples_estimate(fs); found = true; }
            if !found array_add(*spl.not_inlined_info, .{callee, fs_head_samples_estimate(fs)});
        }
    }
}

// findExternalInlineCandidate
spl_find_external_inline_candidate :: (cb: Value_Id, samples: *Fs, inlined_guids: *[..] u64, threshold_in: u64) {
    threshold := threshold_in;
    if !samples return;
    if !sp_flags.cs {
        if sp_opts.use_preinliner threshold = 0;
        sp_find_inlined_functions(samples, inlined_guids, threshold);
        return;
    }
    sp_ctx_find_external_inline_candidate(samples, inlined_guids, threshold);
}
sp_guid_set_add :: (s: *[..] u64, g: u64) { for s.* if it == g return; array_add(s, g); }
spl_symbol_lookup :: (f: Fid) -> Value_Id {
    found, v := table_find(*spl.symbol_map, fid_hash(f));
    if found return v;
    return NONE;
}
// FunctionSamples::findInlinedFunctions
sp_find_inlined_functions :: (fs: *Fs, s: *[..] u64, threshold: u64) {
    if fs.total <= threshold return;
    is_decl :: (f: Value_Id) -> bool { return f == NONE || is_declaration(f); }
    if is_decl(spl_symbol_lookup(fs.ctx.func)) sp_guid_set_add(s, fs_guid(fs));
    for fs.body for t: it.rec.targets {
        if t.count > threshold && is_decl(spl_symbol_lookup(t.f)) sp_guid_set_add(s, fid_hash(t.f));
    }
    for cs: fs.callsites for cs.callees sp_find_inlined_functions(it.fs, s, threshold);
}

// tryPromoteAndInlineCandidate
spl_try_promote_and_inline_candidate :: (f: Value_Id, c: *Spl_Inline_Candidate, sum_origin: u64, sum: *u64, inlined_call_sites: *[..] Value_Id = null) -> bool {
    if spl.disable_inlining return false;
    if sp_opts.icp_max_prom == 0 return false;
    target := spl_symbol_lookup(fs_func(c.callee_samples));
    if target == NONE return false;
    ci := c.call;
    if !sp_does_history_allow_icp(ci, vname(target)) return false;
    if !is_declaration(target) && fn_subprogram(target) != NONE && fn_has_str_attr(target, "use-sample-profile") && target != f && cp_is_legal_to_promote(ci, target) {
        sp_update_idt_metadata(ci, .[.{sp_fn_guid(vname(target)), NOMORE_ICP_MAGICNUM}], 0);
        di := pgo_promote_indirect_call(ci, target, c.callsite_count, sum.*, false);
        if di != NONE {
            sum.* -= c.callsite_count;
            c.call = di;
            if inst_op(di) == .CALL || inst_op(di) == .INVOKE {
                inlined := spl_try_inline_candidate(c, inlined_call_sites);
                if !inlined sp_set_probe_distribution_factor(di, cast(float32) c.callsite_count / cast(float32) sum_origin);
                return inlined;
            }
        }
    }
    return false;
}

// doesHistoryAllowICP
sp_does_history_allow_icp :: (i: Value_Id, candidate: string) -> bool {
    vd := vp_get_value_prof_data(i, IPVK_INDIRECT_CALL_TARGET, sp_opts.icp_max_prom, true);
    if vd.count == 0 return true;
    num_promoted: u32 = 0;
    for vd {
        if it.count != NOMORE_ICP_MAGICNUM continue;
        if it.value == sp_fn_guid(candidate) return false;
        num_promoted += 1;
        if num_promoted == sp_opts.icp_max_prom return false;
    }
    return true;
}

// ---------------------------------------------------------------- function order

// buildFunctionOrder
spl_build_function_order :: () -> [..] Value_Id {
    order: [..] Value_Id; order.allocator = temp;
    if !sp_opts.top_down_load && sp_opts.use_profiled_call_graph
        print_to_stderr("WARNING: -use-profiled-call-graph ignored, should be used together with -sample-profile-top-down-load.\n");
    if !sp_opts.top_down_load {
        if sp_opts.merge_inlinee sp_opts.merge_inlinee = false;
        for f: ir.m_functions if !sp_skip_profile_for_function(f) array_add(*order, f);
        return order;
    }
    if sp_opts.use_profiled_call_graph || (sp_flags.cs && !sp_opts.use_profiled_call_graph_given) {
        pcg := sp_build_profiled_call_graph();
        sccs := pcg_scc_order(pcg);
        for scc: sccs {
            range := scc;
            if sp_opts.sort_profiled_scc range = pcg_scc_member_order(pcg, scc);
            for n: range {
                fn := spl_symbol_lookup(pcg.nodes[n].name);
                if fn != NONE && !sp_skip_profile_for_function(fn) array_add(*order, fn);
            }
        }
        // std::reverse
        a := 0; b := order.count - 1;
        while a < b { t := order[a]; order[a] = order[b]; order[b] = t; a += 1; b -= 1; }
    } else {
        // buildTopDownFuncOrder
        lcg_get();
        lcg_build_ref_sccs();
        for rc: lcg.postorder for c: lcg.rcs[rc].sccs for n: lcg.sccs[c].nodes {
            fn := lcg_fn(n);
            if !sp_skip_profile_for_function(fn) array_add(*order, fn);
        }
        a := 0; b := order.count - 1;
        while a < b { t := order[a]; order[a] = order[b]; order[b] = t; a += 1; b -= 1; }
    }
    return order;
}

// ---------------------------------------------------------------- ProfiledCallGraph

Pcg_Edge :: struct { src: s32; dst: s32; weight: u64; }
Pcg_Node :: struct { name: Fid; edges: [..] Pcg_Edge; }   // edges sorted by the target's name
Pcg :: struct {
    nodes: [..] Pcg_Node;          // 0 = the synthetic root
    by_name: Table(u64, s32);      // ProfiledFunctions
}
pcg_add_function :: (g: *Pcg, name: Fid) {
    h := fid_hash(name);
    if table_contains(*g.by_name, h) return;
    n: Pcg_Node; n.name = name;
    array_add(*g.nodes, n);
    id := cast(s32) (g.nodes.count - 1);
    table_set(*g.by_name, h, id);
    pcg_edge_insert(g, 0, id, 0);
}
// Edges.insert(Edge): (inserted, index)
pcg_edge_insert :: (g: *Pcg, src: s32, dst: s32, w: u64) -> (bool, s64) {
    es := *g.nodes[src].edges;
    k := 0;
    while k < es.count {
        c := fid_cmp(g.nodes[es.*[k].dst].name, g.nodes[dst].name);
        if c == 0 return false, k;
        if c > 0 break;
        k += 1;
    }
    array_insert_at(es, Pcg_Edge.{src, dst, w}, k);
    return true, k;
}
pcg_add_call :: (g: *Pcg, caller: Fid, callee: Fid, w: u64) {
    found, ce := table_find(*g.by_name, fid_hash(callee));
    if !found return;
    _, cr := table_find(*g.by_name, fid_hash(caller));
    inserted, k := pcg_edge_insert(g, cr, ce, w);
    if !inserted g.nodes[cr].edges[k].weight += w;
}
pcg_add_calls :: (g: *Pcg, fs: *Fs) {
    pcg_add_function(g, fs.ctx.func);
    for fs.body for t: it.rec.targets {
        pcg_add_function(g, t.f);
        pcg_add_call(g, fs.ctx.func, t.f, t.count);
    }
    for cs: fs.callsites for cs.callees {
        pcg_add_function(g, it.f);
        pcg_add_call(g, fs.ctx.func, it.f, fs_head_samples_estimate(it.fs));
        pcg_add_calls(g, it.fs);
    }
}
// buildProfiledCallGraph
sp_build_profiled_call_graph :: () -> *Pcg {
    g := New(Pcg,, allocator = temp);
    g.nodes.allocator = temp;
    g.by_name.allocator = temp;
    root: Pcg_Node;
    array_add(*g.nodes, root);
    if sp_flags.cs sp_ctx_add_profiled_calls(g);
    else for sp_reader.profiles pcg_add_calls(g, it);
    for f: ir.m_functions {
        if sp_skip_profile_for_function(f) continue;
        pcg_add_function(g, fid_rep_in_format(sp_canonical_fn_name_of(f)));
    }
    return g;
}

// scc_iterator over the graph from the root: the SCCs in post order (each SCC's nodes in stack pop order)
pcg_scc_order :: (g: *Pcg) -> [..] [..] s32 {
    out: [..] [..] s32; out.allocator = temp;
    visit_num: u32 = 0;
    num := NewArray(g.nodes.count, u32,, allocator = temp);   // 0 = not visited
    node_stack: [..] s32; node_stack.allocator = temp;
    Se :: struct { n: s32; next: s64; min: u32; }
    vs: [..] Se; vs.allocator = temp;
    visit_one :: (n: s32) #expand {
        visit_num += 1;
        num[n] = visit_num;
        array_add(*node_stack, n);
        array_add(*vs, .{n, 0, visit_num});
    }
    visit_one(0);
    while vs.count {
        // DFSVisitChildren
        while true {
            top := *vs[vs.count - 1];
            es := *g.nodes[top.n].edges;
            if top.next >= es.count break;
            child := es.*[top.next].dst;
            top.next += 1;
            if num[child] == 0 { visit_one(child); continue; }
            if top.min > num[child] top.min = num[child];
        }
        visiting := vs[vs.count - 1].n;
        min_num := vs[vs.count - 1].min;
        vs.count -= 1;
        if vs.count && vs[vs.count - 1].min > min_num vs[vs.count - 1].min = min_num;
        if min_num != num[visiting] continue;
        scc: [..] s32; scc.allocator = temp;
        while true {
            x := pop(*node_stack);
            array_add(*scc, x);
            num[x] = 0xFFFF_FFFF;
            if x == visiting break;
        }
        array_add(*out, scc);
    }
    return out;
}

// scc_member_iterator: the SCC's nodes in a top-down order of its maximum weight spanning tree
pcg_scc_member_order :: (g: *Pcg, input: [] s32) -> [..] s32 {
    nodes: [..] s32; nodes.allocator = temp;
    if input.count <= 1 { for input array_add(*nodes, it); return nodes; }
    Info :: struct { group: s32; rank: u32; visited: bool; incoming: [..] u64; }
    info: Table(s32, Info); info.allocator = temp;
    for input { inf: Info; inf.group = it; inf.incoming.allocator = temp; table_set(*info, it, inf); }
    find :: (info: *Table(s32, Info), n: s32) -> s32 {
        i := table_find_pointer(info, n);
        if i.group != n i.group = find(info, i.group);
        return i.group;
    }
    // edges sorted by weight (std::multiset: equal weights keep their insertion order)
    E :: struct { src: s32; k: s64; weight: u64; }
    sorted: [..] E; sorted.allocator = temp;
    for n: input for e, k: g.nodes[n].edges {
        if !table_contains(*info, e.dst) continue;
        x := E.{n, k, e.weight};
        p := sorted.count;
        while p > 0 && sorted[p - 1].weight < x.weight p -= 1;
        array_insert_at(*sorted, x, p);
    }
    ekey :: (e: E) -> u64 { return ((cast(u64) e.src) << 32) | cast(u64) e.k; }
    mst: Table(u64, bool); mst.allocator = temp;
    for e: sorted {
        dst := g.nodes[e.src].edges[e.k].dst;
        g1 := find(*info, e.src); g2 := find(*info, dst);
        if g1 == g2 continue;
        i1 := table_find_pointer(*info, g1); i2 := table_find_pointer(*info, g2);
        if i1.rank < i2.rank i1.group = g2;
        else { i2.group = g1; if i1.rank == i2.rank i1.rank += 1; }
        table_set(*mst, ekey(e), true);
    }
    for e: sorted {
        if !table_contains(*mst, ekey(e)) continue;
        dst := g.nodes[e.src].edges[e.k].dst;
        array_add(*table_find_pointer(*info, dst).incoming, ekey(e));
    }
    queue: [..] s32; queue.allocator = temp;
    qh := 0;
    for e: sorted {
        i := table_find_pointer(*info, e.src);
        if !i.visited && i.incoming.count == 0 { array_add(*queue, e.src); i.visited = true; }
    }
    while qh < queue.count {
        n := queue[qh]; qh += 1;
        array_add(*nodes, n);
        for e, k: g.nodes[n].edges {
            i := table_find_pointer(*info, e.dst);
            if !i continue;
            key := ((cast(u64) n) << 32) | cast(u64) k;
            for i.incoming if it == key { array_ordered_remove_by_index(*i.incoming, it_index); break; }
            if table_contains(*mst, key) && i.incoming.count == 0 array_add(*queue, e.dst);
        }
    }
    a := 0; b := nodes.count - 1;
    while a < b { t := nodes[a]; nodes[a] = nodes[b]; nodes[b] = t; a += 1; b -= 1; }
    return nodes;
}
