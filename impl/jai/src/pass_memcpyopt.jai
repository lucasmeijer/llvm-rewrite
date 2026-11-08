// MemCpyOpt: a port of llvm/lib/Transforms/Scalar/MemCpyOptimizer.cpp (in progress)
mco_opts: struct {
    enable_without_libcalls := false;   // -enable-memcpyopt-without-libcalls
};
MCO_CL_OPT_COUNT :: 1;
add_mco_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"enable-memcpyopt-without-libcalls", .BOOL, *mco_opts.enable_without_libcalls, null, null};
}
memcpyopt_run :: (f: Value_Id) -> Preserved { fatal("memcpyopt is not implemented yet"); return PRESERVE_ALL; }
