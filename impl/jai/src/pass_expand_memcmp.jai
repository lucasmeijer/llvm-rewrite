// ExpandMemCmpPass (llvm/lib/Transforms/Scalar/ExpandMemCmp.cpp): placeholder until the port; fails loudly when a
// memcmp / bcmp call would be considered for expansion.
expand_memcmp_run :: (f: Value_Id) -> Preserved {
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        c := call_called_function(i);
        if c == NONE continue;
        n := vname(c);
        if n == "memcmp" || n == "bcmp" fatal("expand-memcmp: expanding memcmp/bcmp is not implemented yet");
    }
    return PRESERVE_ALL;
}
