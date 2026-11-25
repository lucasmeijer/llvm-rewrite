// sjlj-eh-prepare: a port of llvm/lib/CodeGen/SjLjEHPrepare.cpp (SjLjEHPreparePass::run, SjLjEHPrepareImpl:
// doInitialization, runOnFunction, setupEntryBlockAndCallSites, lowerIncomingArguments, lowerAcrossUnwindEdges,
// setupFunctionContext, substituteLPadValues, insertCallSiteStore). DataTy is i32: x86 keeps
// TargetMachine::DefaultSjLjDataSize, and without a target the default is used too.

Sjlj :: struct {
    data_ty: Type_Id;
    double_under_data_ty: Type_Id;
    double_under_jbuf_ty: Type_Id;
    fctx_ty: Type_Id;
    register_fn: Value_Id; register_fty: Type_Id;
    unregister_fn: Value_Id;
    setup_dispatch_fn: Value_Id;
    frame_addr_fn: Value_Id;
    stack_addr_fn: Value_Id;
    stack_restore_fn: Value_Id;
    lsda_addr_fn: Value_Id;
    call_site_fn: Value_Id;
    func_ctx_fn: Value_Id;
    func_ctx: Value_Id;
}

sjlj_eh_prepare_run :: (f: Value_Id) -> Preserved {
    s: Sjlj;
    // doInitialization
    s.data_ty = ir.t_i32;
    s.double_under_data_ty = type_array(4, s.data_ty);
    s.double_under_jbuf_ty = type_array(5, ir.t_ptr);
    s.fctx_ty = type_literal_struct(.[ir.t_ptr, s.data_ty, s.double_under_data_ty, ir.t_ptr, ir.t_ptr, s.double_under_jbuf_ty], false);
    // runOnFunction
    s.register_fty = type_func(ir.t_void, .[ir.t_ptr], false);
    s.register_fn = module_get_or_insert_function("_Unwind_SjLj_Register", s.register_fty);
    s.unregister_fn = module_get_or_insert_function("_Unwind_SjLj_Unregister", s.register_fty);
    alloca_ptr := type_ptr(dl.alloca_as);
    s.frame_addr_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.frameaddress"), .[alloca_ptr]);
    s.stack_addr_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.stacksave"), .[alloca_ptr]);
    s.stack_restore_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.stackrestore"), .[alloca_ptr]);
    s.setup_dispatch_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.eh.sjlj.setup.dispatch"));
    s.lsda_addr_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.eh.sjlj.lsda"));
    s.call_site_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.eh.sjlj.callsite"));
    s.func_ctx_fn = get_or_insert_intrinsic_declaration(iid_by_name("llvm.eh.sjlj.functioncontext"));
    if !sjlj_setup_entry_block_and_call_sites(*s, f) return PRESERVE_ALL;
    return PRESERVE_NONE;
}

// CallInst::Create(Callee, Args, "", InsertBefore) / IRBuilder::CreateCall
sjlj_call :: (callee: Value_Id, args: [] Value_Id) -> Value_Id {
    fty := glob(callee).value_type;
    c := new_inst(.CALL, func_ret(fty), cast(u32) args.count + 1);
    inst(c).ty2 = fty;
    for args set_op(c, cast(u32) it_index, it);
    set_op(c, cast(u32) args.count, callee);
    inst(c).cc = glob(callee).cc;
    return c;
}
sjlj_gep2 :: (b: *Irb, ty: Type_Id, p: Value_Id, i0: u64, i1: u64, name: string) -> Value_Id {
    return irb_gep(b, ty, p, .[const_int(ir.t_i32, i0), const_int(ir.t_i32, i1)], name);
}

// insertCallSiteStore
sjlj_insert_call_site_store :: (s: *Sjlj, i: Value_Id, number: s64) {
    b: Irb; irb_set_before(*b, i);
    cs := irb_gep(*b, s.fctx_ty, s.func_ctx, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, 1)], "call_site");
    irb_store(*b, const_int(s.data_ty, cast,no_check(u64) number), cs, dl_abi_align(s.data_ty), true);
}

// MarkBlocksLiveIn: BB and everything that reaches it (inverse_depth_first)
sjlj_mark_blocks_live_in :: (bb: Value_Id, live: *Table(Value_Id, bool)) {
    if table_contains(live, bb) return;
    table_set(live, bb, true);
    work: [..] Value_Id; work.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    array_add(*work, bb); table_set(*seen, bb, true);
    preds: [..] Value_Id; preds.allocator = temp;
    while work.count {
        x := pop(*work);
        table_set(live, x, true);
        block_predecessors(x, *preds);
        for preds if !table_contains(*seen, it) { table_set(*seen, it, true); array_add(*work, it); }
    }
}

// substituteLPadValues
sjlj_substitute_lpad_values :: (lpi: Value_Id, exn: Value_Id, sel: Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    u := ir.v_first_use[lpi];
    while u != NONE { array_add(*work, ir.u_user[u]); u = ir.u_next[u]; }
    while work.count {
        v := pop(*work);
        if !is_inst(v) || inst_op(v) != .EXTRACTVALUE continue;
        idx := inst_indices(v);
        if idx.count != 1 continue;
        if idx[0] == 0 replace_all_uses_with(v, exn);
        else if idx[0] == 1 replace_all_uses_with(v, sel);
        if !has_uses(v) erase_inst_with_metadata(v);
    }
    if !has_uses(lpi) return;
    b: Irb;
    nx := inst(sel).next;
    irb_set_at(*b, inst_block(sel), nx, false);
    lv := const_poison(vtype(lpi));
    lv = irb_insert_value(*b, lv, exn, .[0], "lpad.val");
    lv = irb_insert_value(*b, lv, sel, .[1], "lpad.val");
    replace_all_uses_with(lpi, lv);
}

// setupFunctionContext
sjlj_setup_function_context :: (s: *Sjlj, f: Value_Id, lpads: [] Value_Id) {
    entry := fn_entry(f);
    a := create_alloca_unlinked(s.fctx_ty, dl.alloca_as, dl_pref_align(s.fctx_ty));
    insert_at_position(a, entry, block_first(entry), true);   // EntryBB->begin()
    set_name(a, "fn_context");
    s.func_ctx = a;
    for lpi: lpads {
        bb := inst_block(lpi);
        b: Irb;
        ip := block_first_insertion_pt(bb);
        irb_set_at(*b, bb, ip, false);   // the landingpad is skipped: no head bit
        fc_data := sjlj_gep2(*b, s.fctx_ty, s.func_ctx, 0, 2, "__data");
        exc_addr := sjlj_gep2(*b, s.double_under_data_ty, fc_data, 0, 0, "exception_gep");
        exn := irb_load(*b, s.data_ty, exc_addr, dl_abi_align(s.data_ty), true, "exn_val");
        exn = irb_cast(*b, .INTTOPTR, exn, ir.t_ptr);
        sel_addr := sjlj_gep2(*b, s.double_under_data_ty, fc_data, 0, 1, "exn_selector_gep");
        sel := irb_load(*b, s.data_ty, sel_addr, dl_abi_align(s.data_ty), true, "exn_selector_val");
        // CreateTrunc(SelVal, i32): DataTy is i32 already
        sjlj_substitute_lpad_values(lpi, exn, sel);
    }
    b: Irb; irb_set_before(*b, block_terminator(entry));
    pers_ptr := sjlj_gep2(*b, s.fctx_ty, s.func_ctx, 0, 3, "pers_fn_gep");
    irb_store(*b, fn_personality(f), pers_ptr, dl_abi_align(ir.t_ptr), true);
    lsda := irb_insert(*b, sjlj_call(s.lsda_addr_fn, .[]), "lsda_addr");
    lsda_ptr := sjlj_gep2(*b, s.fctx_ty, s.func_ctx, 0, 4, "lsda_gep");
    irb_store(*b, lsda, lsda_ptr, dl_abi_align(ir.t_ptr), true);
}

// lowerIncomingArguments
sjlj_lower_incoming_arguments :: (f: Value_Id) {
    entry := fn_entry(f);
    ip := block_first(entry);
    head := true;   // F.begin()->begin()
    while ip != NONE && inst_op(ip) == .ALLOCA && is_static_alloca(ip) { ip = inst(ip).next; head = false; }
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        if arg_has_attr(a, .SwiftError) continue;
        sel := new_inst(.SELECT, vtype(a), 3);
        set_op(sel, 0, const_int(ir.t_i1, 1));
        set_op(sel, 1, a);
        set_op(sel, 2, const_poison(vtype(a)));
        insert_at_position(sel, entry, ip, head);
        set_name(sel, tconcat(vname(a), ".tmp"));
        replace_all_uses_with(a, sel);
        set_op(sel, 1, a);
    }
}

// lowerAcrossUnwindEdges
sjlj_lower_across_unwind_edges :: (f: Value_Id, invokes: [] Value_Id) {
    entry := fn_entry(f);
    bb := fn_entry(f);
    while bb != NONE {
        i := block_first(bb);
        while i != NONE {
            defer i = inst(i).next;   // the next instruction after the body (a store DemoteRegToStack added is visited)
            if !has_uses(i) continue;
            if has_one_use(i) {
                usr := ir.u_user[ir.v_first_use[i]];
                if inst_block(usr) == bb && inst_op(usr) != .PHI continue;
            }
            if inst_op(i) == .ALLOCA && is_static_alloca(i) continue;
            users: [..] Value_Id; users.allocator = temp;
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u];
                if inst_block(usr) != bb || inst_op(usr) == .PHI array_add(*users, usr);
                u = ir.u_next[u];
            }
            live: Table(Value_Id, bool); live.allocator = temp;
            table_set(*live, bb, true);
            while users.count {
                usr := pop(*users);
                if inst_op(usr) != .PHI sjlj_mark_blocks_live_in(inst_block(usr), *live);
                else for k: 0..cast(s64) nops(usr) - 1 if phi_value(usr, cast(u32) k) == i sjlj_mark_blocks_live_in(phi_block(usr, cast(u32) k), *live);
            }
            spill := false;
            for inv: invokes {
                ub := get_successor(inv, 1);
                if ub != bb && table_contains(*live, ub) { spill = true; break; }
            }
            if spill demote_reg_to_stack(i, block_first(entry), volatile_loads = true, alloca_head = true);
        }
        bb = block(bb).next;
    }
    for inv: invokes {
        ub := get_successor(inv, 1);
        lpi := block_landing_pad_inst(ub);
        phis: [..] Value_Id; phis.allocator = temp;
        p := block_first(ub);
        while p != NONE && inst_op(p) == .PHI { array_add(*phis, p); p = inst(p).next; }
        if !phis.count continue;
        if phis.count > 8 fatal("sjlj-eh-prepare: more than 8 phis in an unwind block: LLVM demotes them in SmallPtrSet (pointer) order");
        for phis demote_phi_to_stack(it, block_first(entry), alloca_head = true);
        // LPI->moveBefore(UnwindBlock->begin())
        inst_unlink(lpi);
        insert_at_position(lpi, ub, block_first(ub), true);
    }
}

// setupEntryBlockAndCallSites
sjlj_setup_entry_block_and_call_sites :: (s: *Sjlj, f: Value_Id) -> bool {
    returns: [..] Value_Id; returns.allocator = temp;
    invokes: [..] Value_Id; invokes.allocator = temp;
    lpads: [..] Value_Id; lpads.allocator = temp;
    iid_donothing := iid_by_name("llvm.donothing");
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if inst_op(t) == .INVOKE {
            if call_iid(t) == iid_donothing {
                insert_before_named(create_br(get_successor(t, 0)), t, "");
                erase_inst_with_metadata(t);
                continue;
            }
            array_add(*invokes, t);
            array_add_if_unique(*lpads, block_landing_pad_inst(get_successor(t, 1)));
        } else if inst_op(t) == .RET array_add(*returns, t);
    }
    if !invokes.count return false;
    sjlj_lower_incoming_arguments(f);
    sjlj_lower_across_unwind_edges(f, invokes);
    sjlj_setup_function_context(s, f, lpads);
    entry := fn_entry(f);
    b: Irb; irb_set_before(*b, block_terminator(entry));
    jbuf := sjlj_gep2(*b, s.fctx_ty, s.func_ctx, 0, 5, "jbuf_gep");
    fp_ptr := sjlj_gep2(*b, s.double_under_jbuf_ty, jbuf, 0, 0, "jbuf_fp_gep");
    v := irb_insert(*b, sjlj_call(s.frame_addr_fn, .[const_int(ir.t_i32, 0)]), "fp");
    irb_store(*b, v, fp_ptr, dl_abi_align(ir.t_ptr), true);
    sp_ptr := sjlj_gep2(*b, s.double_under_jbuf_ty, jbuf, 0, 2, "jbuf_sp_gep");
    v = irb_insert(*b, sjlj_call(s.stack_addr_fn, .[]), "sp");
    irb_store(*b, v, sp_ptr, dl_abi_align(ir.t_ptr), true);
    irb_insert(*b, sjlj_call(s.setup_dispatch_fn, .[]));
    irb_insert(*b, sjlj_call(s.func_ctx_fn, .[s.func_ctx]));
    reg := irb_insert(*b, sjlj_call(s.register_fn, .[s.func_ctx]));
    call_set_does_not_throw(reg);
    for inv, k: invokes {
        sjlj_insert_call_site_store(s, inv, k + 1);
        insert_before_named(sjlj_call(s.call_site_fn, .[const_int(ir.t_i32, cast(u64) (k + 1))]), inv, "");
    }
    for bb: fn_blocks(f) {
        if bb == entry continue;
        for i: block_insts(bb) if inst_op(i) != .INVOKE && may_throw(i) sjlj_insert_call_site_store(s, i, -1);
    }
    for bb: fn_blocks(f) {
        if bb == entry continue;
        i := block_first(bb);
        while i != NONE {
            nx := inst(i).next;
            is_restore := inst_op(i) == .CALL && call_called_function(i) == s.stack_restore_fn;
            if is_restore || inst_op(i) == .ALLOCA {
                sa := sjlj_call(s.stack_addr_fn, .[]);
                insert_at_position(sa, bb, nx, false);   // insertAfter(I); the name is uniqued on insertion
                set_name(sa, "sp");
                st := new_inst(.STORE, ir.t_void, 2);
                set_op(st, 0, sa); set_op(st, 1, sp_ptr);
                inst(st).align = dl_abi_align(ir.t_ptr);
                inst(st).flags |= F_VOLATILE;
                insert_at_position(st, bb, nx, false);
            }
            i = nx;
        }
    }
    for r: returns {
        ip := r;
        mt := block_terminating_must_tail_call(inst_block(r));
        if mt != NONE ip = mt;
        insert_before_named(sjlj_call(s.unregister_fn, .[s.func_ctx]), ip, "");
    }
    return true;
}
