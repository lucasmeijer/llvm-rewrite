// Build metaprogram for the optimized (LLVM backend) build; build.sh runs it when JAI_BUILD=optimized:
//   jai -quiet build_optimized.jai - <source.jai> <exe name> <output dir>
// Same settings as the command line's `-o` (VERY_OPTIMIZED, no stack traces, no bounds checks). Not split into
// modules: splitting builds ~5x faster in parallel but loses cross-module inlining and runs ~2.4x slower.
#import "Basic";
#import "Compiler";

#run build();

build :: () {
    set_build_options_dc(.{do_output = false});
    args := get_build_options().compile_time_command_line;
    if args.count != 3 {
        compiler_report("usage: jai build_optimized.jai - <source.jai> <exe name> <output dir>");
        return;
    }
    w := compiler_create_workspace(args[1]);
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    options.backend = .LLVM;
    set_optimization(*options, .VERY_OPTIMIZED);
    options.stack_trace = false;
    options.output_executable_name = args[1];
    options.output_path = args[2];
    options.intermediate_path = tprint("%/.build", args[2]);   // per build: concurrent builds don't share .build
    set_build_options(options, w);
    add_build_file(args[0], w);
}
