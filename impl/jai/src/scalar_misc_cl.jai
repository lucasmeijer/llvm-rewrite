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
        case; return false;
    }
    return true;
}

// cl::opt<unsigned/int> of these passes given as `-name value` (a value-required option takes the next argument)
scalar_misc_takes_value :: (a: string) -> bool {
    n := a;
    if begins_with(n, "--") n = slice(n, 2, n.count - 2); else if begins_with(n, "-") n = slice(n, 1, n.count - 1); else return false;
    for string.["likely-branch-weight", "unlikely-branch-weight", "float2int-max-integer-bw", "spec-exec-max-speculation-cost",
                "spec-exec-max-not-hoisted", "callsite-splitting-duplication-threshold"] if n == it return true;
    return false;
}
