// opt: parse, (run passes), print. Command line follows LLVM's opt.
import std;
import os;
import ir;
import parser;
import printer;

fn main() {
    let av = args();
    var input: u8[>..] = [];
    var output: u8[>..] = [];
    var emit_text = false;
    var i = 1;
    while i < av.len {
        let a = av[i];
        if a == "-S" { emit_text = true; }
        else if a == "-o" { i++; if i < av.len { output.clear(); output.append(av[i]); } }
        else if starts_with(a, "-o=") { output.clear(); output.append(a[3..]); }
        else if starts_with(a, "-passes=") || a == "-O0" || a == "-O1" || a == "-O2" || a == "-O3" || starts_with(a, "-opt-bisect-limit") {
            write_stderr(str("opt: passes are not implemented yet (", a, ")\n"));
            exit(1);
        }
        else if starts_with(a, "-") && a.len > 1 {
            write_stderr(str("opt: unsupported option '", a, "'\n"));
            exit(1);
        }
        else { input.clear(); input.append(a); }
        i++;
    }
    if !emit_text { write_stderr("opt: only textual output (-S) is supported\n"); exit(1); }
    if input.len == 0 { write_stderr("opt: no input file\n"); exit(1); }
    init_ir();
    parse_module(input);
    print_module(cur_module);
    if output.len == 0 || output == "-" { write_stdout(out); }
    else if !write_file(output, out) { write_stderr("opt: cannot write output\n"); exit(1); }
}
