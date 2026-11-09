// GlobalOpt (in progress)
// Ported from llvm/lib/Transforms/IPO/GlobalOpt.cpp.

Global_Opt :: struct { dummy: s64; }
go_ctor_should_remove :: (go: *Global_Opt, prio: u32, f: Value_Id) -> bool { fatal("globalopt: not implemented"); return false; }
global_opt_run :: () -> Preserved { fatal("globalopt is not implemented yet"); return PRESERVE_ALL; }

globals_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    parse_int :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok := string_to_int(value);
        if !ok fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == "enable-vfe" { gdce_opts.enable_vfe = parse_bool(name, value, has_value); return true; }
    if name == "avail-extern-to-local" { eae_opts.convert_to_local = parse_bool(name, value, has_value); return true; }
    if name == "avail-extern-gv-in-addrspace-to-local" { eae_opts.gv_in_addrspace_to_local = parse_int(name, value, has_value); return true; }
    if internalize_parse_cl_opt(name, value, has_value) return true;
    return false;
}
