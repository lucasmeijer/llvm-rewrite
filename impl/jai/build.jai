// Build metaprogram for both build modes (build.sh, NOTES.md "Build modes"):
//   jai -quiet build.jai - <x64|optimized> <source.jai> <exe name> <output dir>
// x64:       Jai's x64 backend with the command line's defaults (bounds checks, stack traces), like `jai -x64`.
// optimized: LLVM backend, OPTIMIZED (O2; not VERY_OPTIMIZED: that peaks at ~12.7 GB instead of ~3.7 GB and kept
//            getting OOM-killed on the shared machine, for ~3.5% fewer instructions executed), no stack traces, no
//            bounds checks, no debug info (binary 12 MB instead of 54 MB; profiles still have function names). Not
//            split into modules: splitting builds ~5x faster but loses cross-module inlining and runs ~2.4x slower.
// Both put impl/jai/modules first in the import path: its Default_Allocator (glibc malloc) replaces the
// compiler's (modules/Default_Allocator/module.jai says why).
#import "Basic";
#import "Compiler";

#run build();

build :: () {
    set_build_options_dc(.{do_output = false});
    args := get_build_options().compile_time_command_line;
    if args.count != 4 || (args[0] != "x64" && args[0] != "optimized") {
        compiler_report("usage: jai build.jai - <x64|optimized> <source.jai> <exe name> <output dir>");
        return;
    }
    w := compiler_create_workspace(args[2]);
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);
    if args[0] == "optimized" {
        options.backend = .LLVM;
        set_optimization(*options, .OPTIMIZED, preserve_debug_info = false);
        options.stack_trace = false;
    } else {
        options.backend = .X64;
    }
    paths: [..] string;
    array_add(*paths, tprint("%/modules", #filepath));
    for options.import_path array_add(*paths, it);
    options.import_path = paths;
    options.output_executable_name = args[2];
    options.output_path = args[3];
    options.intermediate_path = tprint("%/.build", args[3]);   // per build: concurrent builds don't share .build
    set_build_options(options, w);
    add_build_file(args[1], w);
}
