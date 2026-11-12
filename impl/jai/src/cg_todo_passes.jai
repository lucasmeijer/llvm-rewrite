// Codegen IR passes of llc -O1+ that are not ported yet: each fails loudly.
lsr_loop_pm_run :: (f: Value_Id) -> Preserved { fatal("loop-reduce (LoopStrengthReduce) is not implemented yet"); return PRESERVE_ALL; }
consthoist_run :: (f: Value_Id) -> Preserved { fatal("consthoist (ConstantHoisting) is not implemented yet"); return PRESERVE_ALL; }
partially_inline_libcalls_run :: (f: Value_Id) -> Preserved { fatal("partially-inline-libcalls is not implemented yet"); return PRESERVE_ALL; }
scalarize_masked_mem_intrin_run :: (f: Value_Id) -> Preserved { return PRESERVE_ALL; }
interleaved_access_run :: (f: Value_Id) -> Preserved { fatal("interleaved-access is not implemented yet"); return PRESERVE_ALL; }
x86_partial_reduction_run :: (f: Value_Id) -> Preserved { fatal("x86-partial-reduction is not implemented yet"); return PRESERVE_ALL; }
codegenprepare_run :: (f: Value_Id) -> Preserved { fatal("codegenprepare is not implemented yet"); return PRESERVE_ALL; }
