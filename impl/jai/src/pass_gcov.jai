// GCOVProfiling ("insert-gcov-profiling"): a partial port of llvm/lib/Transforms/Instrumentation/GCOVProfiling.cpp:
// GCOVOptions::getDefault, GCOVProfiler::runOnModule, AddFlushBeforeForkAndExec and the compile-unit loop of
// emitProfileNotes up to the split-DWARF skip. A compile unit that would get coverage (writing its .gcno file, the
// __llvm_gcov_ctr counters and the gcda writeout / reset constructors) fails loudly: not ported yet.

gcov_cl: struct {
    default_version := "0000";   // -default-gcov-version
    atomic_counter: bool;        // -gcov-atomic-counter
};

gcov_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "default-gcov-version";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            gcov_cl.default_version = copy_string(value);
        case "gcov-atomic-counter";
            if !has_value || value == "true" || value == "1" gcov_cl.atomic_counter = true;
            else if value == "false" || value == "0" gcov_cl.atomic_counter = false;
            else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        case; return false;
    }
    return true;
}

// GCOVProfilerPass::run
gcov_run :: () -> Preserved {
    // GCOVOptions::getDefault
    if gcov_cl.default_version.count != 4 fatal("Invalid -default-gcov-version: %", gcov_cl.default_version);
    // GCOVProfiler::runOnModule
    cu_node := named_md_find("llvm.dbg.cu");
    if cu_node < 0 return PRESERVE_ALL;   // (EmitNotes and EmitData are always on by default)
    has_exec_or_fork := gcov_add_flush_before_fork_and_exec();
    // createRegexesFromString(Options.Filter / Exclude): both empty by default
    gcov_emit_profile_notes(cu_node, has_exec_or_fork);
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// AddFlushBeforeForkAndExec
gcov_add_flush_before_fork_and_exec :: () -> bool {
    t: *Tli = null;
    forks: [..] Value_Id; forks.allocator = temp;
    execs: [..] Value_Id; execs.allocator = temp;
    for f: ir.m_functions {
        if !t t = tli_for(f);
        for i: fn_insts(f) {
            if inst_op(i) != .CALL continue;
            callee := call_called_function(i);
            if callee == NONE continue;
            ok, lf := tli_lookup_fn(callee);
            if !ok continue;
            if lf == .fork array_add(*forks, i);
            else if lf == .execl || lf == .execle || lf == .execlp || lf == .execv || lf == .execvp || lf == .execve ||
                    lf == .execvpe || lf == .execvP array_add(*execs, i);
        }
    }
    for c: forks {
        parent := inst_block(c);
        next := inst_next(c);
        ft := type_func(ir.t_i32, .[], false);
        fork_fn := san_get_or_insert_function("__gcov_fork", ft, msan_tli_attr_list(t, .[], true, true));
        set_op(c, nops(c) - 1, fork_fn);
        inst(c).ty2 = ft;
        split_basic_block(parent, next, "");
        set_metadata(block_terminator(parent), 0, get_metadata(c, 0));
    }
    for e: execs {
        parent := inst_block(e);
        next := inst_next(e);
        ft := type_func(ir.t_void, .[], false);
        b: Irb; irb_set_before(*b, e);
        wf: San_Callee; wf.fty = ft; wf.callee = san_get_or_insert_function("llvm_writeout_files", ft);
        san_call(*b, wf, .[]);
        loc := get_metadata(e, 0);
        irb_set_before(*b, next);
        rf: San_Callee; rf.fty = ft; rf.callee = san_get_or_insert_function("llvm_reset_counters", ft);
        rc := san_call(*b, rf, .[]);
        set_metadata(rc, 0, loc);
        split_basic_block(parent, next, "");
        set_metadata(block_terminator(parent), 0, loc);
    }
    return forks.count > 0 || execs.count > 0;
}

// emitProfileNotes: the compile-unit loop
gcov_emit_profile_notes :: (cu_node: s64, has_exec_or_fork: bool) {
    for cu: ir.named_md[cu_node].ops {
        if !is_di(cu, .COMPILE_UNIT) fatal("insert-gcov-profiling: an llvm.dbg.cu operand that is not a DICompileUnit");
        // Skip module skeleton (and module) CUs.
        if di_int(cu, 7) != 0 continue;
        fatal("insert-gcov-profiling: coverage for a compile unit without a DWO id (.gcno notes, counters and the gcda writeout functions of GCOVProfiling.cpp) is not implemented yet");
    }
}
