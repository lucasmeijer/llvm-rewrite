// cl::opt flags of the Layer-1b passes ported by jai_extras_d (load-store-vectorizer, codegen-ir-misc,
// sandbox-vectorizer). Each pass file keeps its own variables; this is the parser.

extras_d_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "load-store-vectorizer-guess-address-order"; lsv_guess_address_order = smisc_bool(name, value, has_value);   // ours
        case; return false;
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
