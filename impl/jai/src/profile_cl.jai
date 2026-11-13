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
                "memprof-debug-func", "memprof-debug-min", "memprof-debug-max", "memprof-runtime-default-options"] if n == it return true;
    return false;
}
