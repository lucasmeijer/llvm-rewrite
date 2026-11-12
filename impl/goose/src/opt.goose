// opt: parse, run the -passes= pipeline, print. Command line follows LLVM's opt.
import std;
import os;
import ir;
import parser;
import printer;
import flags;
import passmgr;
import layoutstats;
import tli;
import triple;

fn main() {
    let av = args();
    var input: u8[>..] = [];
    var output: u8[>..] = [];
    var pipeline: u8[>..] = [];
    var have_pipeline = false;
    var emit_text = false;
    var disable_output = false;
    var layout_stats = false;
    var march: u8[>..] = [];
    var i = 1;
    while i < av.len {
        var a = av[i];
        // opt accepts --x as well as -x
        if starts_with(a, "--") && a.len > 2 { a = a[1..]; }
        if a == "-S" { emit_text = true; }
        else if a == "-f" { }   // -f: write binary output to a terminal (no effect on -S)
        else if a == "-disable-output" { disable_output = true; }
        else if a == "-goose-layout-stats" { layout_stats = true; }
        else if a == "-o" { i++; if i < av.len { output.clear(); output.append(av[i]); } }
        else if starts_with(a, "-o=") { output.clear(); output.append(a[3..]); }
        else if starts_with(a, "-passes=") {
            if have_pipeline { write_stderr("opt: -passes may only be given once\n"); exit(1); }
            pipeline.append(a[8..]);
            have_pipeline = true;
        }
        else if a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" || a == "-Os" || a == "-Oz" {
            write_stderr(str("opt: optimization pipelines are not implemented yet (", a, ")\n"));
            exit(1);
        }
        else if starts_with(a, "-data-layout=") { cl_datalayout.append(a[13..]); }
        else if a == "-data-layout" { i++; if i < av.len { cl_datalayout.clear(); cl_datalayout.append(av[i]); } }
        // codegen's -march: only read when opt creates a TargetMachine (the module triple names an architecture)
        else if starts_with(a, "-march=") { march.clear(); march.append(a[7..]); }
        else if starts_with(a, "-mtriple=") { triple_normalize(a[9..], cl_mtriple); }
        else if a == "-mtriple" { i++; if i < av.len { triple_normalize(av[i], cl_mtriple); } }
        // cl::opt<std::string> (ValueRequired): "-aa-pipeline basic-aa" takes the next argument
        else if a == "-aa-pipeline" { i++; if i < av.len { flag_set("aa-pipeline", av[i]); } }
        // cl::list<std::string> / cl::opt<std::string>: "-x v" takes the next argument (Internalize.cpp)
        else if a == "-internalize-public-api-list" || a == "-internalize-public-api-file" { i++; if i < av.len { flag_set(a[1..], av[i]); } }
        // TargetLibraryInfo options (optdriver.cpp): cl::list, "-x=v" or "-x v"
        else if a == "-disable-simplify-libcalls" { tli_cl_disable_all = true; }
        else if starts_with(a, "-disable-builtin=") { tli_cl_disable.append(a[17..]); tli_cl_disable.push('\n'); }
        else if a == "-disable-builtin" { i++; if i < av.len { tli_cl_disable.append(av[i]); tli_cl_disable.push('\n'); } }
        else if starts_with(a, "-enable-builtin=") { tli_cl_enable.append(a[16..]); tli_cl_enable.push('\n'); }
        else if a == "-enable-builtin" { i++; if i < av.len { tli_cl_enable.append(av[i]); tli_cl_enable.push('\n'); } }
        else if starts_with(a, "-mattr=") {
            // cl::list, CommaSeparated; SubtargetFeatures::AddFeature lowercases and adds a missing '+'
            var st: i64 = 7;
            for j in 7..a.len + 1 {
                if j < a.len && a[j] != ',' { continue; }
                let f = a[st..j];
                st = j + 1;
                if f.len == 0 { continue; }
                if cl_mattr.len > 0 { cl_mattr.push(','); }
                if f[0] != '+' && f[0] != '-' { cl_mattr.push('+'); }
                for c in f { cl_mattr.push(if c >= 'A' && c <= 'Z' { c + 32 } else { c }); }
            }
        }
        else if starts_with(a, "-mcpu=") { cl_mcpu.append(a[6..]); }
        else if starts_with(a, "-opt-bisect-limit=") {
            let v, ok = parse_int(a[18..]);
            if !ok { write_stderr("opt: invalid -opt-bisect-limit\n"); exit(1); }
            bisect_limit = v;
        }
        else if starts_with(a, "-") && a.len > 1 {
            let eq = find(a, "=");
            let name = if eq < 0 { a[1..] } else { a[1..eq] };
            let value = if eq < 0 { "" } else { a[eq + 1..] };
            if !flag_known(name) {
                write_stderr(str("opt: unsupported option '", av[i], "'\n"));
                exit(1);
            }
            // a cl::opt with a value (not a bool) also takes "-x v"
            if eq < 0 && flag_takes_value(name) && i + 1 < av.len { i++; flag_set(name, av[i]); }
            else { flag_set(name, value); }
        }
        else { input.clear(); input.append(a); }
        i++;
    }
    if !emit_text && !disable_output { write_stderr("opt: only textual output (-S) is supported\n"); exit(1); }
    if input.len == 0 { write_stderr("opt: no input file\n"); exit(1); }
    // Constants.cpp's splat cl::opts: they decide how the parser already builds splat constants
    cl_ci_fixed_splat = flag_bool("use-constant-int-for-fixed-length-splat", false);
    cl_ci_scalable_splat = flag_bool("use-constant-int-for-scalable-splat", false);
    init_ir();
    parse_module(input);
    // optdriver.cpp: -strip-debug runs StripDebugInfo right after parsing
    if flag_bool("strip-debug", false) { strip_debug_info(); }
    // -mtriple overrides the module's triple (M->setTargetTriple(Triple::normalize(TargetTriple)))
    if cl_mtriple.len > 0 { modules[cur_module].triple = intern(cl_mtriple); }
    if march.len > 0 && modules[cur_module].triple >= 0 {
        let ts = sbytes(modules[cur_module].triple);
        let e = find(ts, "-");
        let arch = if e < 0 { ts } else { ts[..e] };
        if arch.len > 0 && arch != "unknown" { write_stderr("opt: -march with a target triple is not supported yet\n"); exit(1); }
    }
    set_function_attributes(cur_module);
    var tli_err: u8[>..] = [];
    tli_check_cl_builtins(tli_err);
    if tli_err.len > 0 { write_stderr(str("opt: ", tli_err, "\n")); exit(1); }
    if have_pipeline {
        let root = parse_pass_pipeline(pipeline);
        run_pipeline(root, cur_module);
    }
    if errbuf.len > 0 { write_stderr(errbuf); }
    if layout_stats { layout_stats_print(); }
    if disable_output { return; }
    print_module(cur_module);
    if output.len == 0 || output == "-" { write_stdout(out); }
    else if !write_file(output, out) { write_stderr("opt: cannot write output\n"); exit(1); }
}

// codegen::setFunctionAttributes(M, CPU, Features, TuneCPU) as opt does it after parsing: only when the module
// triple names an architecture. -mcpu becomes "target-cpu" (unless present); -mattr is appended to
// "target-features".
fn set_function_attributes(m: i32) {
    if cl_mcpu.len == 0 && cl_mattr.len == 0 { return; }
    let t = modules[m].triple;
    if t < 0 { return; }
    let ts = sbytes(t);
    var e = find(ts, "-");
    let arch = if e < 0 { ts } else { ts[..e] };
    if arch.len == 0 || arch == "unknown" { return; }
    var f = modules[m].first_func;
    while f >= 0 {
        let g = glob_of(f);
        let l = globs[g].attrs;
        let s = alist_fn(l);
        var xs: i32[>..] = [];
        for k in aset_n(s) { xs.push(aset_attr(s, k)); }
        if cl_mcpu.len > 0 && aset_find_str_opt(s, "target-cpu") < 0 { xs.push(attr_str("target-cpu", cl_mcpu, true)); }
        if cl_mattr.len > 0 {
            let old = aset_find_str_opt(s, "target-features");
            var nf: u8[>..] = [];
            if old >= 0 && attrs[old].sval >= 0 && sbytes(attrs[old].sval).len > 0 { nf.append(sbytes(attrs[old].sval)); nf.push(','); }
            nf.append(cl_mattr);
            xs.push(attr_str("target-features", nf, true));
        }
        globs[g].attrs = alist_with_fn(l, aset_get(xs));
        f = globs[g].next;
    }
}

fn aset_find_str_opt(s: i32, key: const u8[:]) -> i32 {
    for k in aset_n(s) {
        let a = aset_attr(s, k);
        if attrs[a].kind == 0 && sbytes(attrs[a].skey) == key { return a; }
    }
    return -1;
}
