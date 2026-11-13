// Command-line options of the profile family: AddDiscriminators, the sample profile loader, IR PGO instrumentation,
// InstrProfiling lowering and the MemProf passes (their cl::opts live in the LLVM file named next to each option).

profile_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "no-discriminators"; add_discriminators_cl.no_discriminators = smisc_bool(name, value, has_value);   // AddDiscriminators.cpp
        case "enable-fs-discriminator";   // Support/Discriminator.h (MIRFSDiscriminator)
            if smisc_bool(name, value, has_value) fatal("unsupported option '-enable-fs-discriminator' (flow-sensitive discriminators are not ported)");
        case; return false;
    }
    return true;
}
