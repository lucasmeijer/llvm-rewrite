// cl::opt flags of the L1.scalar-misc passes (each pass file keeps its option struct; this is the parser).

smisc_bool :: (name: string, value: string, has_value: bool) -> bool {
    if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
    if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
    fatal(tprint("opt: invalid boolean value '%' for -%", value, name));
    return false;
}
smisc_int :: (name: string, value: string, has_value: bool) -> s64 {
    if !has_value fatal(tprint("opt: option -% needs a value", name));
    v, ok := string_to_int(value);
    if !ok fatal(tprint("opt: invalid integer value '%' for -%", value, name));
    return v;
}

scalar_misc_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "likely-branch-weight"; le_cl.likely_branch_weight = cast(u32) smisc_int(name, value, has_value);
        case "unlikely-branch-weight"; le_cl.unlikely_branch_weight = cast(u32) smisc_int(name, value, has_value);
        case "float2int-max-integer-bw"; f2i_cl.max_integer_bw = cast(u32) smisc_int(name, value, has_value);
        case "tre-disable-entrycount-recompute"; tre_cl.disable_entrycount_recompute = smisc_bool(name, value, has_value);
        case "spec-exec-max-speculation-cost"; se_cl.max_speculation_cost = smisc_int(name, value, has_value);
        case "spec-exec-max-not-hoisted"; se_cl.max_not_hoisted = smisc_int(name, value, has_value);
        case "spec-exec-only-if-divergent-target"; se_cl.only_if_divergent_target = smisc_bool(name, value, has_value);
        case "callsite-splitting-duplication-threshold"; css_cl.duplication_threshold = smisc_int(name, value, has_value);
        case "disable-lower-comment-string"; lower_comment_string_cl.disable = smisc_bool(name, value, has_value);
        case "sink-freq-percent-threshold"; ls_cl.sink_freq_percent_threshold = smisc_int(name, value, has_value);
        case "max-uses-for-sinking"; ls_cl.max_uses_for_sinking = smisc_int(name, value, has_value);
        case "jump-table-to-switch-size-threshold"; jtts_cl.size_threshold = smisc_int(name, value, has_value);
        case "jump-table-to-switch-function-size-threshold"; jtts_cl.function_size_threshold = smisc_int(name, value, has_value);
        case "move-auto-init-threshold"; mai_cl.threshold = smisc_int(name, value, has_value);
        case "cvp-max-functions-per-value"; clv_cl.max_functions_per_value = smisc_int(name, value, has_value);
        case "disable-i2p-p2i-opt"; disable_i2p_p2i_opt = smisc_bool(name, value, has_value);
        case "instcombine-code-sinking"; opts.instcombine_code_sinking = smisc_bool(name, value, has_value);
        case "instcombine-simplify-vector-elts-depth"; ic_simplify_demanded_vector_elts_depth_limit = cast(u32) smisc_int(name, value, has_value);
        case "instcombine-verify-known-bits"; ic_verify_known_bits = smisc_bool(name, value, has_value);
        case "relocation-model";
            if value == {
                case "static"; reloc_model_cl.model = RELOC_STATIC;
                case "pic"; reloc_model_cl.model = RELOC_PIC;
                case "dynamic-no-pic"; reloc_model_cl.model = RELOC_DYNAMIC_NO_PIC;
                case; fatal(tprint("opt: -relocation-model=% is not supported yet", value));
            }
        case; return false;
    }
    return true;
}

// cl::opt<unsigned/int> of these passes given as `-name value` (a value-required option takes the next argument)
scalar_misc_takes_value :: (a: string) -> bool {
    n := a;
    if begins_with(n, "--") n = slice(n, 2, n.count - 2); else if begins_with(n, "-") n = slice(n, 1, n.count - 1); else return false;
    for string.["likely-branch-weight", "unlikely-branch-weight", "float2int-max-integer-bw", "spec-exec-max-speculation-cost",
                "spec-exec-max-not-hoisted", "callsite-splitting-duplication-threshold",
                "sink-freq-percent-threshold", "max-uses-for-sinking",
                "jump-table-to-switch-size-threshold", "jump-table-to-switch-function-size-threshold", "move-auto-init-threshold", "cvp-max-functions-per-value"] if n == it return true;
    return false;
}
