// opt: textual IR in, textual IR out (llvm/tools/opt). Passes are added unit by unit.

#load "ir.jai";
#load "gen_attrs.jai";
#load "gen_cc.jai";
#load "gen_intrinsics.jai";
#load "apfloat.jai";
#load "datalayout.jai";
#load "lexer.jai";
#load "parser.jai";
#load "printer.jai";
#load "intrinsics.jai";

main :: () {
    tool_name = "opt";
    args := get_command_line_arguments();
    input := "";
    output := "-";
    passes := "";
    for i: 1..args.count-1 {
        a := args[i];
        if a == "-S" continue;
        if a == "-o" { i += 1; output = args[i]; continue; }
        if begins_with(a, "-passes=") { passes = slice(a, 8, a.count - 8); continue; }
        if begins_with(a, "-") && a != "-" fatal("unsupported option '%'", a);
        input = a;
    }
    if passes.count fatal("unsupported pass pipeline '%' (no passes are implemented yet)", passes);
    if input.count == 0 fatal("no input file");
    src: string;
    ok: bool;
    if input == "-" fatal("reading from stdin is not supported");
    src, ok = read_entire_file(input);
    if !ok fatal("could not open input file '%'", input);
    ir_init();
    ir.module_id = input;
    parse_module(src, input);
    if ir.source_filename.count == 0 && !saw_source_filename ir.source_filename = input;
    text := print_module();
    if output == "-" write_string(text);
    else if !write_entire_file(output, text) fatal("could not write '%'", output);
}

#import "Basic";
#import "File";
#import "String";
