// llc: textual IR in; with -stop-before=x86-isel the IR that reaches instruction selection out (llvm/tools/llc).
// The tool is opt's program with a different entry point: everything opt loads is loaded here too, and the
// codegen IR pipeline lives in codegen_pipeline.jai (loaded by opt.jai, so that opt's -passes= can name the
// same passes).
LLC_TOOL :: true;
#load "opt.jai";
