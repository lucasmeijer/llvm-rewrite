// cl::opt flags of the Layer-1b passes ported by jai_extras_b (cfg-structurize, scalarizer, lower-matrix,
// utility, analysis-misc). Each pass file keeps its own variables; this is the parser.

extras_b_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "max-booleans-in-control-flow-hub"; ule_max_booleans_in_control_flow_hub = smisc_int(name, value, has_value);
        case "structurizecfg-skip-uniform-regions";
            scz_force_skip_uniform_regions_given = true;
            scz_force_skip_uniform_regions = smisc_bool(name, value, has_value);
        case "structurizecfg-relaxed-uniform-regions"; smisc_bool(name, value, has_value);   // read only with skip-uniform-regions
        case "print-region-style";
            if value == {
                case "none"; ri_print_style = 0;
                case "bb"; ri_print_style = 1;
                case "rn"; ri_print_style = 2;
                case; fatal(tprint("opt: invalid value '%' for -print-region-style", value));
            }
        case "structurizecfg-guess-address-order"; scz_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case "structurizecfg-trace"; scz_trace = true;   // debugging aid (ours)
        case "verify-region-info"; ri_verify_region_info = smisc_bool(name, value, has_value);
        case "strip-global-constants"; strip_global_constants = smisc_bool(name, value, has_value);
        case "rename-exclude-function-prefixes"; mr_cl.exclude_function_prefixes = copy_string(value);
        case "rename-exclude-alias-prefixes"; mr_cl.exclude_alias_prefixes = copy_string(value);
        case "rename-exclude-global-prefixes"; mr_cl.exclude_global_prefixes = copy_string(value);
        case "rename-exclude-struct-prefixes"; mr_cl.exclude_struct_prefixes = copy_string(value);
        case "rename-only-inst"; mr_cl.only_inst = smisc_bool(name, value, has_value);
        case "normalize-guess-address-order"; irn_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case "strip-dead-debug-info-guess-address-order"; sddi_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case "enable-detailed-function-properties"; fpi_detailed = smisc_bool(name, value, has_value);
        case "big-basic-block-instruction-threshold"; fpi_big_bb_threshold = smisc_int(name, value, has_value);
        case "medium-basic-block-instruction-threshold"; fpi_medium_bb_threshold = smisc_int(name, value, has_value);
        case "call-with-many-arguments-threshold"; fpi_many_args_threshold = smisc_int(name, value, has_value);
        case "stack-safety-guess-address-order"; ss_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case "ir2vec-vocab-path"; ir2vec_vocab_path = copy_string(value);
        case "ir2vec-opc-weight"; ir2vec_opc_weight = extras_b_float(name, value);
        case "ir2vec-type-weight"; ir2vec_type_weight = extras_b_float(name, value);
        case "ir2vec-arg-weight"; ir2vec_arg_weight = extras_b_float(name, value);
        case "ir2vec-kind";
            if value == {
                case "symbolic"; ir2vec_flow_aware = false;
                case "flow-aware"; ir2vec_flow_aware = true;
                case; fatal(tprint("opt: Cannot find option named '%'!", value));
            }
        case; return false;
    }
    return true;
}

// cl::parser<float>: parseDouble, then (float)
extras_b_float :: (name: string, value: string) -> float32 {
    cs := temp_c_string(value);
    end: *u8;
    d := ir2vec_strtod(cs, *end);
    if value.count == 0 || end != cs + value.count fatal(tprint("opt: for the --% option: '%' value invalid for floating point argument!", name, value));
    return cast(float32) d;
}
