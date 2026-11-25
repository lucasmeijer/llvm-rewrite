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
        case; return false;
    }
    return true;
}
