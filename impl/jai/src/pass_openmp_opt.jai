// OpenMPOpt: the early exit of llvm/lib/Transforms/IPO/OpenMPOpt.cpp (OpenMPOptPass::run, OpenMPOptCGSCCPass::run:
// `if (!containsOpenMP(M)) return PreservedAnalyses::all()`; containsOpenMP = the "openmp" module flag). A module
// with OpenMP fails loudly: the OpenMP optimizations are not ported.

openmp_opt_run :: () -> Preserved {
    if module_get_flag("openmp") == NONE return PRESERVE_ALL;
    fatal("openmp-opt: OpenMP modules are not supported yet");
    return PRESERVE_NONE;
}
openmp_opt_cgscc_run :: (c: s32) -> Preserved {
    if module_get_flag("openmp") == NONE return PRESERVE_ALL;
    fatal("openmp-opt-cgscc: OpenMP modules are not supported yet");
    return PRESERVE_NONE;
}
