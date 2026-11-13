// Command-line options of the profile family: AddDiscriminators, the sample profile loader, IR PGO instrumentation,
// InstrProfiling lowering and the MemProf passes (their cl::opts live in the LLVM file named next to each option).

profile_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "no-discriminators"; add_discriminators_cl.no_discriminators = smisc_bool(name, value, has_value);   // AddDiscriminators.cpp
        case "enable-fs-discriminator";   // Support/Discriminator.h (MIRFSDiscriminator)
            if smisc_bool(name, value, has_value) fatal("unsupported option '-enable-fs-discriminator' (flow-sensitive discriminators are not ported)");
        // MemProfInstrumentation.cpp
        case "memprof-guard-against-version-mismatch"; memprof_cl.insert_version_check = smisc_bool(name, value, has_value);
        case "memprof-instrument-reads"; memprof_cl.instrument_reads = smisc_bool(name, value, has_value);
        case "memprof-instrument-writes"; memprof_cl.instrument_writes = smisc_bool(name, value, has_value);
        case "memprof-instrument-atomics"; memprof_cl.instrument_atomics = smisc_bool(name, value, has_value);
        case "memprof-use-callbacks"; memprof_cl.use_calls = smisc_bool(name, value, has_value);
        case "memprof-memory-access-callback-prefix"; memprof_cl.callback_prefix = copy_string(prof_str(name, value, has_value));
        case "memprof-mapping-scale"; memprof_cl.mapping_scale = smisc_int(name, value, has_value);
        case "memprof-mapping-granularity"; memprof_cl.mapping_granularity = smisc_int(name, value, has_value);
        case "memprof-instrument-stack"; memprof_cl.instrument_stack = smisc_bool(name, value, has_value);
        case "memprof-debug-func"; memprof_cl.debug_func = copy_string(prof_str(name, value, has_value));
        case "memprof-debug-min"; memprof_cl.debug_min = smisc_int(name, value, has_value);
        case "memprof-debug-max"; memprof_cl.debug_max = smisc_int(name, value, has_value);
        case "memprof-histogram"; memprof_cl.histogram = smisc_bool(name, value, has_value);
        case "memprof-runtime-default-options"; memprof_cl.runtime_default_options = copy_string(prof_str(name, value, has_value));
        // InstrProf.cpp
        case "enable-name-compression"; instrprof_cl.do_name_compression = smisc_bool(name, value, has_value);
        case "static-func-full-module-prefix"; instrprof_cl.static_func_full_module_prefix = smisc_bool(name, value, has_value);
        case "static-func-strip-dirname-prefix"; instrprof_cl.static_func_strip_dir_name_prefix = smisc_int(name, value, has_value);
        case "enable-vtable-value-profiling"; instrprof_cl.enable_vtable_value_profiling = smisc_bool(name, value, has_value);
        // InstrProfiling.cpp
        case "profile-correlate";
            if value == "" instrprof_lower_cl.profile_correlate = 0;
            else if value == "debug-info" instrprof_lower_cl.profile_correlate = 1;
            else if value == "binary" instrprof_lower_cl.profile_correlate = 2;
            else fatal("invalid value '%' for -profile-correlate", value);
        case "hash-based-counter-split"; instrprof_lower_cl.hash_based_counter_split = smisc_bool(name, value, has_value);
        case "runtime-counter-relocation"; instrprof_lower_cl.runtime_counter_relocation = smisc_bool(name, value, has_value); instrprof_lower_cl.runtime_counter_relocation_set = true;
        case "vp-static-alloc"; instrprof_lower_cl.vp_static_alloc = smisc_bool(name, value, has_value);
        case "vp-counters-per-site";
            v, ok := string_to_float64(prof_str(name, value, has_value));
            if !ok fatal("invalid value '%' for -vp-counters-per-site", value);
            instrprof_lower_cl.vp_counters_per_site = v;
        case "instrprof-atomic-counter-update-all"; instrprof_lower_cl.atomic_counter_update_all = smisc_bool(name, value, has_value);
        case "verify-atomic-counter-promoted"; instrprof_lower_cl.verify_atomic_promotion = smisc_bool(name, value, has_value);
        case "atomic-counter-update-promoted"; instrprof_lower_cl.atomic_counter_update_promoted = smisc_bool(name, value, has_value);
        case "atomic-first-counter"; instrprof_lower_cl.atomic_first_counter = smisc_bool(name, value, has_value);
        case "conditional-counter-update"; instrprof_lower_cl.conditional_counter_update = smisc_bool(name, value, has_value);
        case "do-counter-promotion"; instrprof_lower_cl.do_counter_promotion = smisc_bool(name, value, has_value); instrprof_lower_cl.do_counter_promotion_set = true;
        case "max-counter-promotions-per-loop"; instrprof_lower_cl.max_promotions_per_loop = smisc_int(name, value, has_value);
        case "max-counter-promotions"; instrprof_lower_cl.max_promotions = smisc_int(name, value, has_value);
        case "speculative-counter-promotion-max-exiting"; instrprof_lower_cl.speculative_max_exiting = smisc_int(name, value, has_value);
        case "speculative-counter-promotion-to-loop"; instrprof_lower_cl.speculative_to_loop = smisc_bool(name, value, has_value);
        case "iterative-counter-promotion"; instrprof_lower_cl.iterative_promotion = smisc_bool(name, value, has_value);
        case "skip-ret-exit-block"; instrprof_lower_cl.skip_ret_exit_block = smisc_bool(name, value, has_value);
        case "sampled-instrumentation"; instrprof_lower_cl.sampled_instr = smisc_bool(name, value, has_value); instrprof_lower_cl.sampled_instr_set = true;
        case "sampled-instr-period"; instrprof_lower_cl.sampled_period = smisc_int(name, value, has_value);
        case "sampled-instr-burst-duration"; instrprof_lower_cl.sampled_burst = smisc_int(name, value, has_value);
        // PGOInstrumentation.cpp
        case "jai-debug-cfgmst"; pgo_debug_mst = true;
        case "disable-vp"; pgo_gen_cl.disable_vp = smisc_bool(name, value, has_value);
        case "do-comdat-renaming"; pgo_gen_cl.do_comdat_renaming = smisc_bool(name, value, has_value);
        case "pgo-instr-select"; pgo_gen_cl.instr_select = smisc_bool(name, value, has_value);
        case "pgo-instr-memop"; pgo_gen_cl.instr_memop = smisc_bool(name, value, has_value);
        case "pgo-instrument-entry"; pgo_gen_cl.instrument_entry = smisc_bool(name, value, has_value);
        case "pgo-instrument-loop-entries"; pgo_gen_cl.instrument_loop_entries = smisc_bool(name, value, has_value);
        case "pgo-function-entry-coverage"; pgo_gen_cl.function_entry_coverage = smisc_bool(name, value, has_value);
        case "pgo-block-coverage"; pgo_gen_cl.block_coverage = smisc_bool(name, value, has_value);
        case "pgo-temporal-instrumentation"; pgo_gen_cl.temporal_instrumentation = smisc_bool(name, value, has_value);
        case "pgo-function-size-threshold"; pgo_gen_cl.function_size_threshold = smisc_int(name, value, has_value);
        case "pgo-critical-edge-threshold"; pgo_gen_cl.critical_edge_threshold = smisc_int(name, value, has_value);
        case "pgo-cold-instrument-entry-threshold"; pgo_gen_cl.cold_instrument_entry_threshold = smisc_int(name, value, has_value);
        case "pgo-treat-unknown-as-cold"; pgo_gen_cl.treat_unknown_as_cold = smisc_bool(name, value, has_value);
        case "pgo-instrument-cold-function-only"; pgo_gen_cl.instrument_cold_function_only = smisc_bool(name, value, has_value);
        case "pgo-memop-optimize-memcmp-bcmp"; pgo_gen_cl.memop_optimize_memcmp_bcmp = smisc_bool(name, value, has_value);
        case; return false;
    }
    return true;
}

prof_str :: (name: string, value: string, has_value: bool) -> string {
    if !has_value fatal("option -% needs a value", name);
    return value;
}

// value options of the profile family that can be written `-name value` (cl::opt<int / string>)
profile_takes_value :: (a: string) -> bool {
    n := a;
    if begins_with(n, "--") n = slice(n, 2, n.count - 2); else if begins_with(n, "-") n = slice(n, 1, n.count - 1); else return false;
    for string.["memprof-memory-access-callback-prefix", "memprof-mapping-scale", "memprof-mapping-granularity",
                "memprof-debug-func", "memprof-debug-min", "memprof-debug-max", "memprof-runtime-default-options",
                "static-func-strip-dirname-prefix", "vp-counters-per-site", "max-counter-promotions-per-loop",
                "max-counter-promotions", "speculative-counter-promotion-max-exiting", "sampled-instr-period",
                "sampled-instr-burst-duration", "pgo-function-size-threshold", "pgo-critical-edge-threshold",
                "pgo-cold-instrument-entry-threshold"] if n == it return true;
    return false;
}
