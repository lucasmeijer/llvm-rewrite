// cl::opt flags of the Layer-1b passes ported by jai_extras_d (load-store-vectorizer, codegen-ir-misc,
// sandbox-vectorizer). Each pass file keeps its own variables; this is the parser.

extras_d_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "load-store-vectorizer-guess-address-order"; lsv_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case "consthoist-with-block-frequency"; ch_cl.with_block_frequency = smisc_bool(name, value, has_value);
        case "consthoist-gep"; ch_cl.gep = smisc_bool(name, value, has_value);
        case "consthoist-min-num-to-rebase"; ch_cl.min_num_to_rebase = cast(u64) smisc_int(name, value, has_value);
        case "assume-default-is-flat-addrspace"; ias_cl.assume_default_is_flat = smisc_bool(name, value, has_value);
        case "expand-fp-convert-bits"; eii_cl.fp_convert_bits = cast(u64) smisc_int(name, value, has_value);
        case "expand-div-rem-bits"; eii_cl.div_rem_bits = cast(u64) smisc_int(name, value, has_value);
        case "enable-global-merge"; gm_cl.enable = smisc_bool(name, value, has_value);
        case "global-merge-group-by-use"; gm_cl.group_by_use = smisc_bool(name, value, has_value);
        case "global-merge-ignore-single-use"; gm_cl.ignore_single_use = smisc_bool(name, value, has_value);
        case;
            if gm_parse_legacy_only(name) return true;   // read only by the legacy GlobalMerge pass
            return false;
    }
    return true;
}

// value-required options written `-name value` (cl::opt<std::string> / cl::opt<unsigned> take the next argument)
extras_d_takes_value :: (a: string) -> bool {
    n := a;
    if begins_with(n, "--") n = slice(n, 2, n.count - 2);
    else if begins_with(n, "-") n = slice(n, 1, n.count - 1);
    else return false;
    return n == "mcpu" || n == "expand-div-rem-bits" || n == "expand-fp-convert-bits";
}
