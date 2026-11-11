// ControlHeightReductionPass (llvm/lib/Transforms/Instrumentation/ControlHeightReduction.cpp), `chr` in default<O3>:
// only the early exit of ControlHeightReductionPass::run (no cached profile summary: nothing to do). With a profile
// summary the transformation would run; it is not ported and fails loudly.
chr_run :: (f: Value_Id) -> Preserved {
    if !psi_has_profile_summary() return PRESERVE_ALL;
    fatal("chr: ControlHeightReduction with a profile summary is not implemented yet");
    return PRESERVE_NONE;
}
