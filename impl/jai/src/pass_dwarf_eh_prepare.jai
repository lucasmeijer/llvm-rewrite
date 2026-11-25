// dwarf-eh-prepare as an opt pass: a port of llvm/lib/CodeGen/DwarfEHPrepare.cpp (DwarfEHPreparePass::run,
// prepareDwarfEH, InsertUnwindResumeCalls, GetExceptionObject, pruneUnreachableResumes).
// The rewind function of an x86 target is RTLIB::UNWIND_RESUME = _Unwind_Resume with the C calling convention
// (isTargetEHABICompatible is an ARM property). llc's pipeline still uses the guard in cg_misc_passes.jai.

// DwarfEHPreparePass::run
dwarf_eh_prepare_opt_run :: (f: Value_Id) -> Preserved {
    if tti_get(f).kind != .X86 fatal("dwarf-eh-prepare: a target machine (x86 target triple) is required");
    dt := cached_domtree(f);
    // MAMProxy.getCachedResult<LibcallLoweringModuleAnalysis>: LLVMContext::emitError, then nothing changes
    if !libcall_lowering_info_cached fatal("'LibcallLoweringModuleAnalysis' analysis required");
    if cg_tm_opt_level != 0 && !dt dt = get_domtree(f);   // OptLevel != None: getResult<DominatorTreeAnalysis>
    if ir_triple_is_windows_msvc() fatal("dwarf-eh-prepare: Windows MSVC targets are not supported yet");
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    changed := deh_insert_unwind_resume_calls(f, ifx dt then *dtu else null);
    if dt dtu_flush(*dtu);   // ~DomTreeUpdater
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}

ir_triple_is_windows_msvc :: () -> bool {
    t := ir.triple;
    if opts.mtriple.count t = opts.mtriple;
    return contains(t, "windows") && !contains(t, "gnu") && !contains(t, "cygnus");
}

// GetExceptionObject
deh_get_exception_object :: (ri: Value_Id) -> Value_Id {
    v := op(ri, 0);
    exn: Value_Id = NONE;
    sel_load: Value_Id = NONE;
    exc_ivi: Value_Id = NONE;
    erase_ivis := false;
    sel_ivi := ifx is_inst(v) && inst_op(v) == .INSERTVALUE then v else NONE;
    if sel_ivi != NONE {
        idx := inst_indices(sel_ivi);
        if idx.count == 1 && idx[0] == 1 {
            e := op(sel_ivi, 0);
            if is_inst(e) && inst_op(e) == .INSERTVALUE {
                exc_ivi = e;
                k := vkind(op(e, 0));
                ei := inst_indices(e);
                if (k == .C_UNDEF || k == .C_POISON) && ei.count == 1 && ei[0] == 0 {
                    exn = op(e, 1);
                    s := op(sel_ivi, 1);
                    if is_inst(s) && inst_op(s) == .LOAD sel_load = s;
                    erase_ivis = true;
                }
            }
        }
    }
    if exn == NONE exn = insert_before_named(create_extract_value(op(ri, 0), .[0]), ri, "exn.obj");
    erase_inst_with_metadata(ri);
    if erase_ivis {
        if !has_uses(sel_ivi) erase_inst_with_metadata(sel_ivi);
        if !has_uses(exc_ivi) erase_inst_with_metadata(exc_ivi);
        if sel_load != NONE && !has_uses(sel_load) erase_inst_with_metadata(sel_load);
    }
    return exn;
}

// pruneUnreachableResumes
deh_prune_unreachable_resumes :: (f: Value_Id, resumes: *[..] Value_Id, lpads: [] Value_Id, dtu: *Dtu) -> s64 {
    reachable := NewArray(resumes.count, bool,, allocator = temp);
    all := true;
    for ri, k: resumes.* {
        for lp: lpads if is_potentially_reachable_inst(lp, ri, dtu_get_dom_tree(dtu)) { reachable[k] = true; break; }
        if !reachable[k] all = false;
    }
    if all return resumes.count;
    left := 0;
    tti := tti_get(f);
    for ri, k: resumes.* {
        if reachable[k] { resumes.*[left] = ri; left += 1; continue; }
        bb := inst_block(ri);
        insert_before_named(new_inst(.UNREACHABLE, ir.t_void, 0), ri, "");
        erase_inst_with_metadata(ri);
        // simplifyCFG(BB, *TTI, DTU) with default SimplifyCFGOptions
        o: Scfg_Options;
        s: Scfg; s.tti = tti; s.dtu = dtu; s.opts = *o;
        simplify_cfg_block(*s, bb);
    }
    resumes.count = left;
    return left;
}

// InsertUnwindResumeCalls
deh_insert_unwind_resume_calls :: (f: Value_Id, dtu: *Dtu) -> bool {
    resumes: [..] Value_Id; resumes.allocator = temp;
    lpads: [..] Value_Id; lpads.allocator = temp;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .RESUME array_add(*resumes, t);
        lp := block_landing_pad_inst(bb);
        if lp != NONE && (inst(lp).flags & F_CLEANUP) array_add(*lpads, lp);
    }
    if !resumes.count return false;
    pers := classify_eh_personality(fn_personality(f));
    if is_scoped_eh_personality(pers) return false;
    left := resumes.count;
    if cg_tm_opt_level != 0 left = deh_prune_unreachable_resumes(f, *resumes, lpads, dtu);
    if left == 0 return true;

    // RTLIB::UNWIND_RESUME: void (ptr)
    fty := type_func(ir.t_void, .[type_ptr(0)], false);
    callee := module_get_or_insert_function("_Unwind_Resume", fty);
    make_call :: (callee: Value_Id, fty: Type_Id, arg: Value_Id, bb: Value_Id, f: Value_Id) {
        ci := new_inst(.CALL, ir.t_void, 2);
        inst(ci).ty2 = fty;
        set_op(ci, 0, arg);
        set_op(ci, 1, callee);
        block_append_inst(bb, ci);
        // a DILocation(0, 0, SP) when the rewind function has a subprogram
        if vkind(callee) == .FUNCTION && is_di(get_metadata(callee, 0), .SUBPROGRAM) {
            sp := get_metadata(f, 0);
            if is_di(sp, .SUBPROGRAM) set_metadata(ci, 0, di_get(.LOCATION, false, .[sp, NONE], .[0, 0, 0, 0, 0]));
        }
        inst(ci).cc = CC_C;
        call_add_fn_attr(ci, .NoReturn);   // setDoesNotReturn
        block_append_inst(bb, new_inst(.UNREACHABLE, ir.t_void, 0));
    }
    if left == 1 {
        ri := resumes[0];
        bb := inst_block(ri);
        exn := deh_get_exception_object(ri);
        make_call(callee, fty, exn, bb, f);
        return true;
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    unwind_bb := create_block(f, "unwind_resume");
    pn := create_phi(type_ptr(0), cast(u32) left);
    block_append_inst(unwind_bb, pn);
    set_name(pn, "exn.obj");
    for ri: resumes {
        parent := inst_block(ri);
        block_append_inst(parent, create_br(unwind_bb));
        array_add(*updates, .{true, parent, unwind_bb});
        exn := deh_get_exception_object(ri);
        phi_add_incoming(pn, exn, parent);
    }
    make_call(callee, fty, pn, unwind_bb, f);
    if dtu dtu_apply(dtu, updates);
    return true;
}
