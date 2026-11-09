// EntryExitInstrumenter: port of llvm/lib/Transforms/Utils/EntryExitInstrumenter.cpp (insertCall, runOnFunction,
// EntryExitInstrumenterPass::run). Parameters: ee-instrument<> / ee-instrument<post-inline>. insertCall's
// AIX __mcount, RISC-V/AArch64/LoongArch and SystemZ variants fail loudly (x86-64 target only).

ee_new_call :: (fty: Type_Id, callee: Value_Id, args: [] Value_Id, bb: Value_Id, pos: Value_Id, head: bool, dloc: Md_Id) -> Value_Id {
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, callee);
    insert_at_position(i, bb, pos, head);
    if dloc != NONE set_metadata(i, 0, dloc);
    return i;
}

ee_insert_call :: (cur_fn: Value_Id, func: string, bb: Value_Id, pos: Value_Id, head: bool, dloc: Md_Id) {
    ptr := type_ptr(dl.program_as);
    if func == "mcount" || func == ".mcount" || func == "llvm.arm.gnu.eabi.mcount" || func == "\x01_mcount" ||
       func == "\x01mcount" || func == "__mcount" || func == "_mcount" || func == "__cyg_profile_func_enter_bare" {
        t := ir.triple;
        if find_index_from_left(t, "-aix") >= 0 || begins_with(t, "riscv") || begins_with(t, "aarch64") || begins_with(t, "arm64") ||
           begins_with(t, "loongarch") || begins_with(t, "s390x") || begins_with(t, "systemz")
            fatal("ee-instrument: the % variant of '%' is not implemented yet", t, func);
        fty := type_func(ir.t_void, .[], false);
        fnv := get_or_insert_function(func, fty);
        ee_new_call(fty, fnv, .[], bb, pos, head, dloc);
        return;
    }
    if func == "__cyg_profile_func_enter" || func == "__cyg_profile_func_exit" {
        fty := type_func(ir.t_void, .[ptr, ptr], false);
        fnv := get_or_insert_function(func, fty);
        ra_fn := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.returnaddress"), .[ptr]);
        ret_addr := ee_new_call(glob(ra_fn).value_type, ra_fn, .[const_int(ir.t_i32, 0)], bb, pos, head, dloc);
        ee_new_call(fty, fnv, .[cur_fn, ret_addr], bb, pos, head, dloc);
        return;
    }
    fatal("Unknown instrumentation function: '%'", func);
}

ee_instrument_run :: (f: Value_Id, name: string) -> Preserved {
    post_inlining := false;
    if name == "ee-instrument<post-inline>" post_inlining = true;
    else if name != "ee-instrument<>" && name != "ee-instrument" fatal("invalid pass pipeline: invalid EntryExitInstrumenter parameter in '%'", name);
    if fn_has_fn_attr(f, .Naked) return PRESERVE_ALL;
    if glob(f).linkage == .AVAILABLE_EXTERNALLY return PRESERVE_ALL;
    entry_attr := ifx post_inlining then "instrument-function-entry-inlined" else "instrument-function-entry";
    exit_attr := ifx post_inlining then "instrument-function-exit-inlined" else "instrument-function-exit";
    entry_func, exit_func: string;
    a := fn_find_str_attr(f, entry_attr); if a entry_func = a.val;
    a = fn_find_str_attr(f, exit_attr); if a exit_func = a.val;
    changed := false;
    sp := fn_subprogram(f);
    if entry_func.count {
        dl: Md_Id = NONE;
        if sp != NONE dl = di_location_get(di_int(sp, 1), 0, sp, NONE);   // SP->getScopeLine()
        entry := fn_entry(f);
        ee_insert_call(f, entry_func, entry, block_first_insertion_pt(entry), true, dl);
        changed = true;
        fn_remove_str_attr(f, entry_attr);
    }
    if exit_func.count {
        for bb: fn_blocks(f) {
            t := block_terminator(bb);
            if t == NONE || inst_op(t) != .RET continue;
            ci := block_terminating_must_tail_call(bb);
            if ci != NONE t = ci;
            dl := get_metadata(t, 0);
            if dl == NONE && sp != NONE dl = di_location_get(0, 0, sp, NONE);
            ee_insert_call(f, exit_func, bb, t, false, dl);
            changed = true;
        }
        fn_remove_str_attr(f, exit_attr);
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
