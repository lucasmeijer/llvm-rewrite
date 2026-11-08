// opt: parse, run the -passes= pipeline, print. Command line follows LLVM's opt.
import std;
import os;
import ir;
import parser;
import printer;
import flags;
import passmgr;

fn main() {
    let av = args();
    var input: u8[>..] = [];
    var output: u8[>..] = [];
    var pipeline: u8[>..] = [];
    var have_pipeline = false;
    var emit_text = false;
    var disable_output = false;
    var i = 1;
    while i < av.len {
        var a = av[i];
        // opt accepts --x as well as -x
        if starts_with(a, "--") && a.len > 2 { a = a[1..]; }
        if a == "-S" { emit_text = true; }
        else if a == "-disable-output" { disable_output = true; }
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
            flag_set(name, value);
        }
        else { input.clear(); input.append(a); }
        i++;
    }
    if !emit_text && !disable_output { write_stderr("opt: only textual output (-S) is supported\n"); exit(1); }
    if input.len == 0 { write_stderr("opt: no input file\n"); exit(1); }
    init_ir();
    parse_module(input);
    if have_pipeline {
        let root = parse_pass_pipeline(pipeline);
        run_pipeline(root, cur_module);
    }
    if errbuf.len > 0 { write_stderr(errbuf); }
    if disable_output { return; }
    print_module(cur_module);
    if output.len == 0 || output == "-" { write_stdout(out); }
    else if !write_file(output, out) { write_stderr("opt: cannot write output\n"); exit(1); }
}
