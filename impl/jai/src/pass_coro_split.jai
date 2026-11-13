// CoroSplit: splits a pre-split coroutine into the ramp function and its resume / destroy / cleanup clones (switch
// ABI) or one continuation per suspend point (retcon, retcon.once, async ABIs), and adds the new functions to the
// LazyCallGraph. Also CoroAnnotationElide (calls marked coro_elide_safe to a ".noalloc" variant, then inlined).
// Ported from llvm/lib/Transforms/Coroutines/CoroSplit.cpp, CoroCloner.h (BaseCloner / SwitchCloner as one struct
// with a `kind`) and CoroAnnotationElide.cpp. Frame building is in coro_frame.jai / coro_spill.jai.

Coro_Clone_Kind :: enum u8 { SWITCH_RESUME; SWITCH_UNWIND; SWITCH_CLEANUP; CONTINUATION; ASYNC; }

Coro_Cloner :: struct {
    orig_f: Value_Id;
    suffix: string;
    shape: *Coro_Shape;
    kind: Coro_Clone_Kind;
    b: Irb;
    vm: Value_Map;
    new_f: Value_Id = NONE;
    new_frame_ptr: Value_Id = NONE;
    active_suspend: Value_Id = NONE;
}

cc_is_switch_destroy_function :: (c: *Coro_Cloner) -> bool { return c.kind == .SWITCH_UNWIND || c.kind == .SWITCH_CLEANUP; }
cc_map :: (c: *Coro_Cloner, v: Value_Id) -> Value_Id { return vmap_lookup(*c.vm, v); }

// ---------------------------------------------------------------- coro.await.suspend lowering

// lowerAwaitSuspend
coro_lower_await_suspend :: (b: *Irb, cb: Value_Id, shape: *Coro_Shape) {
    wrapper := call_arg(cb, 2);
    awaiter := call_arg(cb, 0);
    frame_ptr := call_arg(cb, 1);
    irb_set_before(b, cb);
    new_attrs := attr_list_with_set_at(inst(cb).attrs, 2, 0);   // removeParamAttributes(2)
    new_call: Value_Id;
    if inst_op(cb) == .INVOKE {
        inv := coro_create_invoke(wrapper, get_successor(cb, 0), get_successor(cb, 1), .[awaiter, frame_ptr], cb);
        irb_insert(b, inv);
        inst(inv).cc = inst(cb).cc;
        inst(inv).attrs = new_attrs;
        set_metadata(inv, MDK_DBG, get_metadata(cb, MDK_DBG));
        new_call = inv;
    } else {
        call := irb_call(b, wrapper, .[awaiter, frame_ptr]);
        inst(call).attrs = new_attrs;
        set_metadata(call, MDK_DBG, get_metadata(cb, MDK_DBG));
        new_call = call;
    }
    if call_iid(cb) == IID_CORO_AWAIT_SUSPEND_HANDLE {
        if inst_op(cb) == .INVOKE {
            nd := get_successor(cb, 0);
            irb_set_at(b, nd, block_first_insertion_pt(nd), true);
        }
        resume_addr := coro_make_subfn_call(new_call, CORO_SUBFN_RESUME, ifx b.pt != NONE then b.pt else fatal_none("coro-split: await.suspend.handle at a block end"));
        rty := type_func(ir.t_void, .[ir.t_ptr], false);
        rc := new_inst(.CALL, ir.t_void, 2);
        inst(rc).ty2 = rty;
        set_op(rc, 0, new_call); set_op(rc, 1, resume_addr);
        irb_insert(b, rc);
        array_add(*shape.symmetric_transfers, rc);
        new_call = rc;
    }
    coro_rauw(cb, new_call);
    coro_erase(cb);
}
fatal_none :: (msg: string) -> Value_Id { fatal(msg); return NONE; }

// an unlinked invoke of `callee` with `from`'s operand bundles (InvokeInst::Create + the bundle copy)
coro_create_invoke :: (callee: Value_Id, normal: Value_Id, unwind: Value_Id, args: [] Value_Id, from: Value_Id) -> Value_Id {
    if call_num_bundles(from) != 0 fatal("coro-split: lowering an invoke of coro.await.suspend with operand bundles is not supported yet");
    fty := glob(callee).value_type;
    i := new_inst(.INVOKE, func_ret(fty), cast(u32)(args.count + 3));
    inst(i).ty2 = fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, normal);
    set_op(i, cast(u32) args.count + 1, unwind);
    set_op(i, cast(u32) args.count + 2, callee);
    return i;
}

// lowerAwaitSuspends
coro_lower_await_suspends :: (f: Value_Id, shape: *Coro_Shape) {
    b: Irb;
    for shape.coro_await_suspends coro_lower_await_suspend(*b, it, shape);
}

// ---------------------------------------------------------------- coro.end replacement

// maybeFreeRetconStorage
coro_maybe_free_retcon_storage :: (b: *Irb, shape: *Coro_Shape, frame_ptr: Value_Id) {
    if shape.rc_is_frame_inline_in_storage return;
    coro_emit_dealloc(shape, b, frame_ptr);
}
// createSwitchDestroyPtr / createSwitchIndexPtr
coro_create_switch_destroy_ptr :: (shape: *Coro_Shape, b: *Irb, frame_ptr: Value_Id) -> Value_Id {
    return irb_inbounds_ptr_add(b, frame_ptr, const_int(ir.t_i64, shape.sw_destroy_offset), "destroy.addr");
}
coro_create_switch_index_ptr :: (shape: *Coro_Shape, b: *Irb, frame_ptr: Value_Id) -> Value_Id {
    return irb_inbounds_ptr_add(b, frame_ptr, const_int(ir.t_i64, shape.sw_index_offset), "index.addr");
}

// replaceSwitchResumeCoroFree
coro_replace_switch_resume_coro_free :: (shape: *Coro_Shape, resume: Value_Id, cleanup: Value_Id) {
    frame_ptr := fn_arg(resume, 0);
    eb: Irb; irb_set_before(*eb, block_terminator(fn_entry(resume)));
    destroy_addr := coro_create_switch_destroy_ptr(shape, *eb, frame_ptr);
    destroy_fn := irb_load(*eb, ir.t_ptr, destroy_addr, dl_abi_align(ir.t_ptr), false, "destroy");
    cleanup_fn := irb_pointer_bitcast_or_addrspacecast(*eb, cleanup, vtype(destroy_fn));
    is_elided := irb_icmp(*eb, ICMP_EQ, destroy_fn, cleanup_fn, "is.elided");
    frees: [..] Value_Id; frees.allocator = temp;
    u := ir.v_first_use[frame_ptr];
    while u != NONE { usr := ir.u_user[u]; u = ir.u_next[u]; if is_inst(usr) && call_iid(usr) == IID_CORO_FREE array_add(*frees, usr); }
    for cf: frees {
        b: Irb; irb_set_before(*b, cf);
        repl := irb_select(*b, is_elided, const_null(vtype(cf)), frame_ptr, "coro.free");
        coro_rauw(cf, repl);
        coro_erase(cf);
    }
}

// replaceCoroEndAsync: true if the coro.end block needs the cleanup
coro_replace_coro_end_async :: (e: Value_Id) -> bool {
    b: Irb; irb_set_before(*b, e);
    if call_iid(e) != IID_CORO_END_ASYNC { irb_insert(*b, new_inst(.RET, ir.t_void, 0)); return true; }
    mt := coro_async_end_must_tail_fn(e);
    if mt == NONE { irb_insert(*b, new_inst(.RET, ir.t_void, 0)); return true; }
    end_block := inst_block(e);
    mt_block := block_single_predecessor(end_block);
    assert(mt_block != NONE, "Must have a single predecessor block");
    mt_call := inst_prev(block_terminator(mt_block));
    // CoroEndBlock->splice(End, MustTailCallFuncBlock, MustTailCall)
    inst_move_before(mt_call, e);
    irb_set_before(*b, e);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));
    bb := inst_block(e);
    split_basic_block(bb, e, "");
    coro_erase(block_terminator(bb));
    ifi: Inline_Function_Info; ifi_reset(*ifi);
    r := inline_function(mt_call, *ifi, false, null, true, false);
    if !r.ok fatal("internal: coro-split: expected inlining of the coro.end.async must-tail call to succeed");
    return false;
}

// replaceFallthroughCoroEnd
coro_replace_fallthrough_coro_end :: (e: Value_Id, shape: *Coro_Shape, frame_ptr: Value_Id, in_ramp: bool) {
    b: Irb; irb_set_before(*b, e);
    if shape.abi == {
      case .SWITCH;
        if in_ramp return;
        irb_insert(*b, new_inst(.RET, ir.t_void, 0));
      case .ASYNC;
        if !coro_replace_coro_end_async(e) return;
      case .RETCON_ONCE;
        coro_maybe_free_retcon_storage(*b, shape, frame_ptr);
        rt := func_ret(coro_resume_function_type(shape));
        if !coro_end_has_results(e) {
            irb_insert(*b, new_inst(.RET, ir.t_void, 0));
        } else {
            results := coro_end_results(e);
            nr := call_arg_count(results);
            if type_kind(rt) == .STRUCT {
                rv := const_poison(rt);
                for k: 0..cast(s64) nr - 1 rv = irb_insert_value(*b, rv, call_arg(results, cast(u32) k), .[cast(u32) k]);
                coro_create_ret(*b, rv);
            } else if nr == 0 {
                irb_insert(*b, new_inst(.RET, ir.t_void, 0));
            } else {
                coro_create_ret(*b, call_arg(results, 0));
            }
            coro_rauw(results, const_token_none());
            coro_erase(results);
        }
      case .RETCON;
        coro_maybe_free_retcon_storage(*b, shape, frame_ptr);
        rt := func_ret(coro_resume_function_type(shape));
        is_struct := type_kind(rt) == .STRUCT;
        cont_ty := ifx is_struct then type_sub(rt, 0) else rt;
        rv := const_null(cont_ty);
        if is_struct rv = irb_insert_value(*b, const_poison(rt), rv, .[0]);
        coro_create_ret(*b, rv);
    }
    bb := inst_block(e);
    split_basic_block(bb, e, "");
    coro_erase(block_terminator(bb));
}
coro_create_ret :: (b: *Irb, v: Value_Id) -> Value_Id {
    r := new_inst(.RET, ir.t_void, 1);
    set_op(r, 0, v);
    return irb_insert(b, r);
}

// markCoroutineAsDone
coro_mark_coroutine_as_done :: (b: *Irb, shape: *Coro_Shape, frame_ptr: Value_Id) {
    irb_store(b, const_null(ir.t_ptr), frame_ptr, dl_abi_align(ir.t_ptr));
    if shape.sw_has_unwind_coro_end && shape.sw_has_final_suspend {
        iv := coro_shape_index(shape, cast(u64) shape.coro_suspends.count - 1);
        fi := coro_create_switch_index_ptr(shape, b, frame_ptr);
        irb_store(b, iv, fi, dl_abi_align(shape.sw_index_type));
    }
}

// replaceUnwindCoroEnd
coro_replace_unwind_coro_end :: (e: Value_Id, shape: *Coro_Shape, frame_ptr: Value_Id, in_ramp: bool) {
    b: Irb; irb_set_before(*b, e);
    if shape.abi == {
      case .SWITCH;
        coro_mark_coroutine_as_done(*b, shape, frame_ptr);
        if in_ramp return;
      case .ASYNC;
      case .RETCON; #through;
      case .RETCON_ONCE;
        coro_maybe_free_retcon_storage(*b, shape, frame_ptr);
    }
    k := call_bundle_index(e, "funclet");
    if k >= 0 {
        bb, _ := call_bundle_range(e, cast(u32) k);
        from_pad := op(e, bb);
        cr := new_inst(.CLEANUPRET, ir.t_void, 1);
        set_op(cr, 0, from_pad);
        irb_insert(*b, cr);
        split_basic_block(inst_block(e), e, "");
        coro_erase(block_terminator(inst_block(cr)));
    }
}

// replaceCoroEnd
coro_replace_coro_end :: (e: Value_Id, shape: *Coro_Shape, frame_ptr: Value_Id, in_ramp: bool) {
    if coro_end_is_unwind(e) coro_replace_unwind_coro_end(e, shape, frame_ptr, in_ramp);
    else coro_replace_fallthrough_coro_end(e, shape, frame_ptr, in_ramp);
    coro_erase(e);
}

// ---------------------------------------------------------------- BaseCloner

// BaseCloner::handleFinalSuspend
cc_handle_final_suspend :: (c: *Coro_Cloner) {
    shape := c.shape;
    if cc_is_switch_destroy_function(c) && shape.sw_has_unwind_coro_end return;
    sw := cc_map(c, shape.sw_resume_switch);
    last := switch_num_cases(sw) - 1;
    resume_bb := sw_case_dest(sw, last);
    sw_remove_case(sw, last);
    if cc_is_switch_destroy_function(c) {
        old_bb := inst_block(sw);
        new_bb := split_basic_block(old_bb, sw, "Switch");
        irb_set_before(*c.b, block_terminator(old_bb));
        if fn_has_fn_attr(c.new_f, .CoroDestroyOnlyWhenComplete) {
            irb_insert(*c.b, create_br(resume_bb));
        } else {
            ld := irb_load(*c.b, ir.t_ptr, c.new_frame_ptr, dl_abi_align(ir.t_ptr));
            cond := irb_icmp(*c.b, ICMP_EQ, ld, const_null(ir.t_ptr));   // CreateIsNull
            irb_insert(*c.b, create_cond_br(cond, resume_bb, new_bb));
        }
        coro_erase(block_terminator(old_bb));
    }
}

// getFunctionTypeFromAsyncSuspend
coro_function_type_from_async_suspend :: (susp: Value_Id) -> Type_Id {
    st := vtype(susp);
    ps: [..] Type_Id; ps.allocator = temp;
    for k: 0..cast(s64) type_nsub(st) - 1 array_add(*ps, type_sub(st, cast(u32) k));
    return type_func(ir.t_void, ps, false);
}

// createCloneDeclaration: inserted before `insert_before` (NONE = at the end of the module)
coro_create_clone_declaration :: (orig_f: Value_Id, shape: *Coro_Shape, suffix: string, insert_before: Value_Id, active: Value_Id) -> Value_Id {
    fty := ifx shape.abi != .ASYNC then coro_resume_function_type(shape) else coro_function_type_from_async_suspend(active);
    nf := new_function(fty, "", glob(orig_f).addrspace);
    gv_set_linkage(nf, .INTERNAL);
    if insert_before == NONE array_add(*ir.m_functions, nf);
    else {
        idx := -1;
        for ir.m_functions if it == insert_before { idx = it_index; break; }
        assert(idx >= 0);
        array_insert_at(*ir.m_functions, nf, idx);
    }
    set_name(nf, tconcat(vname(orig_f), suffix));
    return nf;
}

// BaseCloner::replaceRetconOrAsyncSuspendUses
cc_replace_retcon_or_async_suspend_uses :: (c: *Coro_Cloner) {
    ns := cc_map(c, c.active_suspend);
    if !has_uses(ns) return;
    args: [..] Value_Id; args.allocator = temp;
    start: u32 = ifx c.shape.abi == .ASYNC then cast(u32) 0 else 1;
    na := glob(c.new_f).nargs;
    for k: start..na - 1 array_add(*args, fn_arg(c.new_f, k));
    if type_kind(vtype(ns)) != .STRUCT {
        assert(args.count == 1);
        coro_rauw(ns, args[0]);
        return;
    }
    u := ir.v_first_use[ns];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) || inst_op(usr) != .EXTRACTVALUE || inst(usr).nidx != 1 continue;
        idx := inst_indices(usr)[0];
        coro_rauw(usr, args[idx]);
        coro_erase(usr);
    }
    if !has_uses(ns) return;
    aggr := const_poison(vtype(ns));
    for args aggr = irb_insert_value(*c.b, aggr, it, .[cast(u32) it_index]);
    coro_rauw(ns, aggr);
}

// BaseCloner::replaceCoroSuspends
cc_replace_coro_suspends :: (c: *Coro_Cloner) {
    if c.shape.abi != .SWITCH return;
    res := const_int(ir.t_i8, ifx cc_is_switch_destroy_function(c) then cast(u64) 1 else 0);
    for cs: c.shape.coro_suspends {
        if cs == c.active_suspend continue;
        m := cc_map(c, cs);
        coro_rauw(m, res);
        coro_erase(m);
    }
}

// BaseCloner::replaceCoroEnds
cc_replace_coro_ends :: (c: *Coro_Cloner) {
    for ce: c.shape.coro_ends coro_replace_coro_end(cc_map(c, ce), c.shape, c.new_frame_ptr, false);
}

// BaseCloner::replaceCoroIsInRamp
cc_replace_coro_is_in_ramp :: (c: *Coro_Cloner) {
    for ii: c.shape.coro_is_in_ramp_insts {
        m := cc_map(c, ii);
        coro_rauw(m, const_int(ir.t_i1, 0));
        coro_erase(m);
    }
}

// replaceSwiftErrorOps(F, Shape, VMap)
coro_replace_swift_error_ops :: (f: Value_Id, shape: *Coro_Shape, vm: *Value_Map) {
    if shape.abi == .ASYNC && shape.coro_suspends.count == 0 return;
    cached: Value_Id = NONE;
    get_slot :: (f: Value_Id, vt: Type_Id, cached: *Value_Id) -> Value_Id {
        if cached.* != NONE return cached.*;
        na := glob(f).nargs;
        for k: 0..cast(s64) na - 1 if fn_has_param_attr(f, cast(u32) k, .SwiftError) { cached.* = fn_arg(f, cast(u32) k); return cached.*; }
        entry := fn_entry(f);
        b: Irb; irb_set_at(*b, entry, block_first_non_phi_or_dbg(entry), false);
        a := new_inst(.ALLOCA, ir.t_ptr, 1);
        inst(a).ty2 = vt;
        set_op(a, 0, const_int(ir.t_i32, 1));
        inst(a).addrspace = dl_alloca_addrspace();
        inst(a).align = dl_pref_align(vt);
        inst(a).flags |= F_SWIFTERR;
        irb_insert(*b, a);
        cached.* = a;
        return a;
    }
    for op_i: shape.swift_error_ops {
        mapped := ifx vm then vmap_lookup(vm, op_i) else op_i;
        b: Irb; irb_set_before(*b, mapped);
        result: Value_Id;
        if call_arg_count(op_i) == 0 {
            vt := vtype(op_i);
            slot := get_slot(f, vt, *cached);
            result = irb_load(*b, vt, slot, dl_abi_align(vt));
        } else {
            v := call_arg(mapped, 0);
            slot := get_slot(f, vtype(v), *cached);
            irb_store(*b, v, slot, dl_abi_align(vtype(v)));
            result = slot;
        }
        coro_rauw(mapped, result);
        coro_erase(mapped);
    }
    if vm == null shape.swift_error_ops.count = 0;
}

// collectDbgVariableRecords
coro_collect_dbg_variable_records :: (f: Value_Id) -> [..] u32 {
    r: [..] u32; r.allocator = temp;
    for i: fn_insts(f) {
        x := inst(i).records;
        while x != 0 { if dbgr(x).kind != .LABEL array_add(*r, x); x = dbgr(x).next; }
    }
    return r;
}

// BaseCloner::salvageDebugInfo
cc_salvage_debug_info :: (c: *Coro_Cloner) {
    recs := coro_collect_dbg_variable_records(c.new_f);
    if recs.count == 0 return;
    a2a: Table(Value_Id, Value_Id); a2a.allocator = temp;
    use_entry_value := coro_triple_is_arch64();
    for recs coro_salvage_debug_info(*a2a, it, use_entry_value);
    dt := dt_new(false); dt_recalculate(dt, c.new_f);
    defer dt_free(dt);
    entry := fn_entry(c.new_f);
    unreachable_block :: (dt: *Dom_Tree, entry: Value_Id, bb: Value_Id) -> bool { return !is_potentially_reachable_block(entry, bb, dt); }
    for r: recs {
        if dbgr(r).owner == NONE continue;
        if unreachable_block(dt, entry, inst_block(dbgr(r).owner)) { dbgr_erase(r); continue; }
        vals: [..] Value_Id; vals.allocator = temp;
        dbgr_location_ops(r, *vals);
        if vals.count && is_inst(vals[0]) && inst_op(vals[0]) == .ALLOCA {
            uses := 0;
            u := ir.v_first_use[vals[0]];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if is_inst(usr) && inst_op(usr) != .ALLOCA && !unreachable_block(dt, entry, inst_block(usr)) uses += 1;
            }
            if uses == 0 dbgr_erase(r);
        }
    }
}
// Triple::isArch64Bit of the module triple
coro_triple_is_arch64 :: () -> bool {
    t := triple_parse(ir.triple);
    return triple_is_arch_64bit(*t);
}

// BaseCloner::replaceEntryBlock
cc_replace_entry_block :: (c: *Coro_Cloner) {
    shape := c.shape;
    entry := cc_map(c, shape.alloca_spill_block);
    old_entry := fn_entry(c.new_f);
    set_name(entry, tconcat("entry", c.suffix));
    block_move_before(entry, old_entry);
    coro_erase(block_terminator(entry));
    assert(has_one_use(entry));
    br := ir.u_user[ir.v_first_use[entry]];
    irb_set_before(*c.b, br);
    irb_insert(*c.b, new_inst(.UNREACHABLE, ir.t_void, 0));
    coro_erase(br);
    irb_set_end(*c.b, entry);
    if shape.abi == .SWITCH {
        sw_bb := cc_map(c, shape.sw_resume_entry_block);
        irb_insert(*c.b, create_br(sw_bb));
        block_move_after(sw_bb, entry);
    } else {
        mcs := cc_map(c, c.active_suspend);
        nb := inst_next(mcs);
        assert(inst_op(nb) == .BR);
        irb_insert(*c.b, create_br(get_successor(nb, 0)));
    }
    f := c.new_f;
    dt := dt_new(false); dt_recalculate(dt, f);
    defer dt_free(dt);
    for :early_inc i: fn_insts(f) {
        if inst_op(i) != .ALLOCA || !has_uses(i) continue;
        if dt_is_reachable_from_entry(dt, inst_block(i)) || vkind(op(i, 0)) != .C_INT continue;
        inst_unlink(i);
        insert_at_position(i, entry, block_first_insertion_pt(entry), true);
    }
}

// BaseCloner::deriveNewFramePointer
cc_derive_new_frame_pointer :: (c: *Coro_Cloner) -> Value_Id {
    shape := c.shape;
    if shape.abi == {
      case .SWITCH; return fn_arg(c.new_f, 0);
      case .ASYNC;
        idx := coro_async_suspend_storage_arg_index(c.active_suspend) & 0xff;
        callee_ctx := fn_arg(c.new_f, idx);
        proj := coro_async_suspend_projection_fn(c.active_suspend);
        dl := get_metadata(cc_map(c, c.active_suspend), MDK_DBG);
        caller_ctx := irb_call(*c.b, proj, .[callee_ctx]);
        inst(caller_ctx).cc = glob(proj).cc;
        set_metadata(caller_ctx, MDK_DBG, dl);
        fpa := irb_inbounds_ptr_add(*c.b, caller_ctx, const_int(ir.t_i64, shape.as_frame_offset), "async.ctx.frameptr");
        ifi: Inline_Function_Info; ifi_reset(*ifi);
        r := inline_function(caller_ctx, *ifi, false, null, true, false);
        assert(r.ok);
        return fpa;
      case .RETCON; #through;
      case .RETCON_ONCE;
        ns := fn_arg(c.new_f, 0);
        if shape.rc_is_frame_inline_in_storage return ns;
        return irb_load(*c.b, ir.t_ptr, ns, dl_abi_align(ir.t_ptr));
    }
    return NONE;
}

// updateScopeLine(ActiveSuspend, SP)
coro_update_scope_line :: (active: Value_Id, sp: Md_Id) {
    if active == NONE return;
    set_scope_line :: (sp: Md_Id, line: u64) { ir.md_ints[ir.mds[sp].ints + 1] = line; }
    sp_file := di_op(sp, 0);
    loc_file :: (l: Md_Id) -> Md_Id { return discope_file(diloc_scope(l)); }
    nx := inst_next(active);
    if nx == NONE {
        dl := get_metadata(active, MDK_DBG);
        if dl != NONE && sp_file == loc_file(dl) set_scope_line(sp, diloc_line(dl));
        return;
    }
    succ := nx;
    for 0..1 {
        if inst_op(succ) != .BR break;
        succ = block_first_non_phi_or_dbg(get_successor(succ, 0));
    }
    while succ != NONE {
        dl := get_metadata(succ, MDK_DBG);
        if dl == NONE || diloc_line(dl) == 0 { succ = inst_next(succ); continue; }
        if sp_file == loc_file(dl) { set_scope_line(sp, diloc_line(dl)); return; }
        break;
    }
    dl := get_metadata(active, MDK_DBG);
    if dl != NONE && sp_file == loc_file(dl) set_scope_line(sp, diloc_line(dl));
}

// addFramePointerAttrs
coro_add_frame_pointer_attrs :: (attrs: u32, param_index: u32, size: u64, align: u64, no_alias: bool) -> u32 {
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(attr_list_param(attrs, param_index)) array_add(*items, it);
    add :: (items: *[..] Attr, k: Attr_Kind, v: u64 = 0) {
        for * items.* if it.kind == k { it.ival = v; return; }
        a: Attr; a.kind = k; a.ty = NONE; a.ival = v; array_add(items, a);
    }
    add(*items, .NonNull);
    add(*items, .NoUndef);
    if no_alias add(*items, .NoAlias);
    add(*items, .Alignment, align);
    add(*items, .Dereferenceable, size);
    return attr_list_with_set_at(attrs, param_index, attr_set_get(items));
}
coro_add_param_attr_kind :: (attrs: u32, param_index: u32, k: Attr_Kind) -> u32 {
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(attr_list_param(attrs, param_index)) array_add(*items, it);
    for items if it.kind == k return attrs;
    a: Attr; a.kind = k; a.ty = NONE; array_add(*items, a);
    return attr_list_with_set_at(attrs, param_index, attr_set_get(items));
}

// CloneFunctionInto(NewF, OrigF, VMap, LocalChangesOnly, Returns)
coro_clone_function_into :: (nf: Value_Id, f: Value_Id, vm: *Value_Map, returns: *[..] Value_Id) {
    // CloneFunctionAttributesInto
    new_attrs := glob(nf).attrs;
    ipo_fn_copy_attributes_from(nf, f);
    glob(nf).attrs = new_attrs;
    if glob(f).has_personality set_op(nf, 0, map_value(vm, op(f, 0), RF_NONE));
    if glob(f).has_prefix set_op(nf, 1, map_value(vm, op(f, 1), RF_NONE));
    if glob(f).has_prologue set_op(nf, 2, map_value(vm, op(f, 2), RF_NONE));
    old_attrs := glob(f).attrs;
    na := glob(nf).nargs;
    params := NewArray(cast(s64) na, u32,, allocator = temp);
    for k: 0..cast(s64) glob(f).nargs - 1 {
        m := vmap_lookup(vm, fn_arg(f, cast(u32) k));
        if m != NONE && vkind(m) == .ARGUMENT params[arg_no(m)] = attr_list_param(old_attrs, cast(u32) k);
    }
    glob(nf).attrs = attr_list_get(attr_list_fn(old_attrs), attr_list_ret(old_attrs), params);
    if is_declaration(f) return;
    for bb: fn_blocks(f) {
        cbb := clone_basic_block(bb, vm, "", nf);
        vmap_set(vm, bb, cbb);
        if block_has_address_taken(bb) vmap_set(vm, const_blockaddr(f, bb), const_blockaddr(nf, cbb));
        t := block_terminator(cbb);
        if t != NONE && inst_op(t) == .RET array_add(returns, t);
    }
    mm: Fs_Md_Mapper; mm.vm = vm; mm.in_progress.allocator = temp;
    mm.sp = get_metadata(f, MDK_DBG);
    vm.has_md = true;
    fs_premap_metadata(*mm, f, nf);
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(f, *all);
    for all add_metadata(nf, it.kind, fs_map_md(*mm, it.md));
    for bb: fn_blocks(nf) for i: block_insts(bb) {
        remap_instruction(vm, i, RF_NONE);
        remap_dbg_record_range(vm, i, RF_NONE);
    }
    fs_cleanup_retained_nodes(get_metadata(nf, MDK_DBG));
}

// BaseCloner::create
cc_create :: (c: *Coro_Cloner) {
    shape := c.shape;
    orig := c.orig_f;
    nf := c.new_f;
    dummies: [..] Value_Id; dummies.allocator = temp;
    for k: 0..cast(s64) glob(orig).nargs - 1 {
        a := fn_arg(orig, cast(u32) k);
        d := new_inst(.FREEZE, vtype(a), 1);
        set_op(d, 0, const_poison(vtype(a)));
        array_add(*dummies, d);
        vmap_set(*c.vm, a, d);
    }
    returns: [..] Value_Id; returns.allocator = temp;
    saved_vis := glob(nf).visibility; saved_ua := glob(nf).unnamed_addr; saved_dll := glob(nf).dll; saved_link := glob(nf).linkage;
    gv_set_linkage(nf, .EXTERNAL);
    coro_clone_function_into(nf, orig, *c.vm, *returns);
    sp := get_metadata(nf, MDK_DBG);
    if sp != NONE && is_di(sp, .SUBPROGRAM) {
        coro_update_scope_line(c.active_suspend, sp);
        nl := md_string(vname(nf));
        ir.md_ops[ir.mds[sp].ops + 3] = nl;   // replaceLinkageName
        decl := di_op(sp, 6);
        if decl != NONE {
            r := ir.mds[decl];
            ops := NewArray(r.nops, Md_Id,, allocator = temp);
            for k: 0..cast(s64) r.nops - 1 ops[k] = md_op(decl, cast(u32) k);
            ops[3] = nl;
            ints: [] u64; ints.data = ir.md_ints.data + r.ints; ints.count = r.nints;
            ints_copy := array_copy(ints,, allocator = temp);
            ir.md_ops[ir.mds[sp].ops + 6] = di_get(.SUBPROGRAM, false, ops, ints_copy);
        }
    }
    gv_set_linkage(nf, saved_link);
    glob(nf).visibility = saved_vis; glob(nf).unnamed_addr = saved_ua; glob(nf).dll = saved_dll;
    if shape.abi == .SWITCH {
        fsk := md_kind_id("func_sanitize");
        if get_metadata(nf, fsk) != NONE set_metadata(nf, fsk, NONE);
    }
    orig_attrs := glob(nf).attrs;
    new_attrs: u32 = 0;
    if shape.abi == {
      case .SWITCH;
        new_attrs = attr_list_get(attr_list_fn(orig_attrs), 0, .[]);
        new_attrs = coro_add_frame_pointer_attrs(new_attrs, 0, shape.frame_size, shape.frame_align, false);
      case .ASYNC;
        if fn_has_param_attr(orig, shape.as_context_arg_no, .SwiftAsync) {
            idx := coro_async_suspend_storage_arg_index(c.active_suspend);
            new_attrs = coro_add_param_attr_kind(new_attrs, idx & 0xff, .SwiftAsync);
            ss := idx >> 8;
            if ss new_attrs = coro_add_param_attr_kind(new_attrs, ss, .SwiftSelf);
        }
        new_attrs = attr_list_with_fn(new_attrs, attr_list_fn(glob(orig).attrs));
      case .RETCON; #through;
      case .RETCON_ONCE;
        id := coro_shape_id(shape);
        new_attrs = glob(shape.rc_resume_prototype).attrs;
        new_attrs = coro_add_frame_pointer_attrs(new_attrs, 0, coro_retcon_storage_size(id), coro_retcon_storage_align(id), true);
    }
    if shape.abi == .SWITCH || shape.abi == .RETCON_ONCE for returns change_to_unreachable(it, false, null);
    glob(nf).attrs = new_attrs;
    glob(nf).cc = coro_resume_function_cc(shape);
    cc_replace_entry_block(c);
    for rc0: shape.symmetric_transfers {
        rc := cc_map(c, rc0);
        call_set_tail_kind(rc, TCK_MUSTTAIL);   // TTI.supportsTailCallFor: true for every target we build for
        bb := inst_block(rc);
        split_basic_block(bb, inst_next(rc), "");
        irb_set_before(*c.b, block_terminator(bb));
        irb_insert(*c.b, new_inst(.RET, ir.t_void, 0));
        coro_erase(block_terminator(bb));
    }
    irb_set_before(*c.b, block_first(fn_entry(nf)));
    c.new_frame_ptr = cc_derive_new_frame_pointer(c);
    old_fp := cc_map(c, shape.frame_ptr);
    coro_take_name(c.new_frame_ptr, old_fp);
    if vkind(c.new_frame_ptr) == .ARGUMENT { n := vname(old_fp); set_name(old_fp, ""); set_name(c.new_frame_ptr, n); }
    coro_rauw(old_fp, c.new_frame_ptr);
    new_vframe := c.new_frame_ptr;   // CreateBitCast(NewFramePtr, ptr, "vFrame") folds to the frame pointer
    old_vframe := cc_map(c, shape.coro_begin);
    if old_vframe != new_vframe coro_rauw(old_vframe, new_vframe);
    for d: dummies {
        coro_rauw(d, const_poison(vtype(d)));
        drop_all_references(d);
        ir.v_kind[d] = .DEAD;
    }
    if shape.abi == .SWITCH { if shape.sw_has_final_suspend cc_handle_final_suspend(c); }
    else cc_replace_retcon_or_async_suspend_uses(c);
    cc_replace_coro_suspends(c);
    coro_replace_swift_error_ops(c.new_f, shape, *c.vm);
    cc_replace_coro_ends(c);
    cc_replace_coro_is_in_ramp(c);
    cc_salvage_debug_info(c);
}

coro_cloner_init :: (c: *Coro_Cloner, orig: Value_Id, suffix: string, shape: *Coro_Shape, kind: Coro_Clone_Kind) {
    c.orig_f = orig; c.suffix = suffix; c.shape = shape; c.kind = kind;
    vmap_init(*c.vm);
}

// SwitchCloner::createClone
coro_switch_create_clone :: (f: Value_Id, suffix: string, shape: *Coro_Shape, kind: Coro_Clone_Kind) -> Value_Id {
    c: Coro_Cloner;
    coro_cloner_init(*c, f, suffix, shape, kind);
    vmap_track_begin(*c.vm);
    defer vmap_track_end(*c.vm);
    c.new_f = coro_create_clone_declaration(f, shape, suffix, NONE, NONE);
    cc_create(*c);
    if kind == .SWITCH_CLEANUP coro_elide_coro_free(c.new_frame_ptr);
    return c.new_f;
}
// BaseCloner::createClone (continuations)
coro_base_create_clone :: (f: Value_Id, suffix: string, shape: *Coro_Shape, nf: Value_Id, active: Value_Id) -> Value_Id {
    c: Coro_Cloner;
    coro_cloner_init(*c, f, suffix, shape, ifx shape.abi == .ASYNC then Coro_Clone_Kind.ASYNC else .CONTINUATION);
    vmap_track_begin(*c.vm);
    defer vmap_track_end(*c.vm);
    c.new_f = nf;
    c.active_suspend = active;
    cc_create(*c);
    return nf;
}

// ---------------------------------------------------------------- frame size, no-suspend coroutines, suspend simplification

// updateAsyncFuncPointerContextSize
coro_update_async_func_pointer_context_size :: (shape: *Coro_Shape) {
    gv := shape.as_async_func_pointer;
    s := gv_initializer(gv);
    rel := op(s, 0);
    osz := op(s, 1);
    nsz := const_int(vtype(osz), shape.as_context_size);
    gv_set_initializer(gv, const_aggregate(.C_STRUCT, vtype(s), .[rel, nsz]));
}
// replaceFrameSizeAndAlignment
coro_replace_frame_size_and_alignment :: (shape: *Coro_Shape) {
    if shape.abi == .ASYNC coro_update_async_func_pointer_context_size(shape);
    for ca: shape.coro_aligns { coro_rauw(ca, const_int(vtype(ca), shape.frame_align)); coro_erase(ca); }
    if shape.coro_sizes.count == 0 return;
    size_intrin := shape.coro_sizes[shape.coro_sizes.count - 1];
    sc := const_int(vtype(size_intrin), shape.frame_size);
    for cs: shape.coro_sizes { coro_rauw(cs, sc); coro_erase(cs); }
}

// postSplitCleanup
coro_post_split_cleanup :: (f: Value_Id) { remove_unreachable_blocks(f, null); }

// handleNoSuspendCoroutine
coro_handle_no_suspend_coroutine :: (shape: *Coro_Shape) {
    cb := shape.coro_begin;
    if shape.abi == .SWITCH {
        alloc := coro_id_coro_alloc(coro_shape_id(shape));
        if alloc != NONE {
            coro_elide_coro_free(cb);
            b: Irb; irb_set_before(*b, alloc);
            frame_ty := type_array(shape.frame_size, ir.t_i8);
            fr := new_inst(.ALLOCA, ir.t_ptr, 1);
            inst(fr).ty2 = frame_ty;
            set_op(fr, 0, const_int(ir.t_i32, 1));
            inst(fr).addrspace = dl_alloca_addrspace();
            inst(fr).align = dl_pref_align(frame_ty);
            irb_insert(*b, fr, tconcat(vname(inst_fn(alloc)), ".Frame"));
            inst(fr).align = shape.frame_align;
            coro_rauw(alloc, const_int(ir.t_i1, 0));
            coro_erase(alloc);
            coro_rauw(cb, fr);
        } else coro_rauw(cb, coro_begin_mem(cb));
    } else coro_rauw(cb, const_poison(vtype(cb)));
    coro_erase(cb);
    shape.coro_begin = NONE;
}

// hasCallsInBlockBetween([from, to)): calls other than intrinsics
coro_has_calls_in_block_between :: (from: Value_Id, to: Value_Id) -> bool {
    i := from;
    while i != NONE && i != to {
        if is_call_base(i) && !(inst_op(i) == .CALL && call_iid(i) != NOT_INTRINSIC) return true;
        i = inst_next(i);
    }
    return false;
}
// hasCallsInBlocksBetween
coro_has_calls_in_blocks_between :: (save_bb: Value_Id, res_bb: Value_Id) -> bool {
    set: Table(Value_Id, bool); set.allocator = temp;
    set_list: [..] Value_Id; set_list.allocator = temp;
    add :: (set: *Table(Value_Id, bool), l: *[..] Value_Id, b: Value_Id) { if !table_contains(set, b) { table_set(set, b, true); array_add(l, b); } }
    add(*set, *set_list, save_bb);
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, res_bb);
    preds: [..] Value_Id; preds.allocator = temp;
    while worklist.count {
        bb := pop(*worklist);
        add(*set, *set_list, bb);
        block_predecessors(bb, *preds);
        for p: preds if !table_contains(*set, p) array_add(*worklist, p);
    }
    for bb: set_list {
        if bb == save_bb || bb == res_bb continue;
        if coro_has_calls_in_block_between(block_first_non_phi(bb), NONE) return true;
    }
    return false;
}
// hasCallsBetween
coro_has_calls_between :: (save: Value_Id, rd: Value_Id) -> bool {
    sbb := inst_block(save); rbb := inst_block(rd);
    if sbb == rbb return coro_has_calls_in_block_between(inst_next(save), rd);
    if coro_has_calls_in_block_between(inst_next(save), NONE) return true;
    if coro_has_calls_in_block_between(block_first_non_phi(rbb), rd) return true;
    if coro_has_calls_in_blocks_between(sbb, rbb) return true;
    return false;
}
// simplifySuspendPoint
coro_simplify_suspend_point :: (susp: Value_Id, coro_begin: Value_Id) -> bool {
    prev := inst_prev(susp);
    if prev == NONE {
        pred := block_single_predecessor(inst_block(susp));
        if pred == NONE return false;
        prev = block_terminator(pred);
    }
    if !is_call_base(prev) return false;
    cb := prev;
    callee := strip_pointer_casts(call_callee(cb));
    if !(is_inst(callee) && call_iid(callee) == IID_CORO_SUBFN_ADDR) return false;
    subfn := callee;
    if call_arg(subfn, 0) != coro_begin return false;
    save := coro_suspend_save(susp);
    if coro_has_calls_between(save, cb) return false;
    coro_rauw(susp, call_arg(subfn, 1));
    coro_erase(susp);
    coro_erase(save);
    if inst_op(cb) == .INVOKE {
        br := create_br(get_successor(cb, 0));
        insert_at_position(br, inst_block(cb), cb, false);
    }
    called := call_callee(cb);
    coro_erase(cb);
    if called != subfn && !has_uses(called) && is_inst(called) coro_erase(called);
    if !has_uses(subfn) coro_erase(subfn);
    return true;
}
// simplifySuspendPoints
coro_simplify_suspend_points :: (shape: *Coro_Shape) {
    if shape.abi != .SWITCH return;
    s := *shape.coro_suspends;
    i := 0; n := s.count;
    if n == 0 return;
    changed_final := -1;
    while true {
        si := s.*[i];
        if !coro_suspend_is_final(si) && coro_simplify_suspend_point(si, shape.coro_begin) {
            n -= 1;
            if n == i break;
            s.*[i], s.*[n] = s.*[n], s.*[i];
            if coro_suspend_is_final(s.*[i]) changed_final = i;
            continue;
        }
        i += 1;
        if i == n break;
    }
    s.count = n;
    if changed_final >= 0 && changed_final < n {
        last := s.count - 1;
        s.*[changed_final], s.*[last] = s.*[last], s.*[changed_final];
    }
}

// ---------------------------------------------------------------- SwitchCoroutineSplitter

// createResumeEntryBlock
coro_create_resume_entry_block :: (f: Value_Id, shape: *Coro_Shape) {
    sp := get_metadata(f, MDK_DBG);
    add_debug_labels := sp != NONE && di_op(sp, 5) != NONE && di_int(di_op(sp, 5), 6) == 1;
    new_entry := create_block(f, "resume.entry");
    unreach := create_block(f, "unreachable");
    b: Irb; irb_set_end(*b, new_entry);
    fp := shape.frame_ptr;
    gep_index := coro_create_switch_index_ptr(shape, *b, fp);
    index := irb_load(*b, shape.sw_index_type, gep_index, dl_abi_align(shape.sw_index_type), false, "index");
    sw := create_switch(index, unreach, cast(u32) shape.coro_suspends.count);
    irb_insert(*b, sw);
    shape.sw_resume_switch = sw;
    for susp: shape.coro_suspends {
        k := cast(u64) it_index;
        iv := coro_shape_index(shape, k);
        save := coro_suspend_save(susp);
        irb_set_before(*b, save);
        if coro_suspend_is_final(susp) coro_mark_coroutine_as_done(*b, shape, fp);
        else {
            gi := coro_create_switch_index_ptr(shape, *b, fp);
            irb_store(*b, iv, gi, dl_abi_align(shape.sw_index_type));
        }
        coro_rauw(save, const_token_none());
        coro_erase(save);
        susp_bb := inst_block(susp);
        resume_bb := split_basic_block(susp_bb, susp, tconcat("resume.", tdec(k)));
        landing_bb := split_basic_block(resume_bb, inst_next(susp), tconcat(vname(resume_bb), ".landing"));
        sw_add_case(sw, iv, resume_bb);
        set_successor(block_terminator(susp_bb), 0, landing_bb);
        pn := create_phi(ir.t_i8, 2);
        insert_at_position(pn, landing_bb, block_first(landing_bb), false);
        coro_rauw(susp, pn);
        phi_add_incoming(pn, const_int(ir.t_i8, 0xFF), susp_bb);
        phi_add_incoming(pn, susp, resume_bb);
        if add_debug_labels && get_metadata(susp, MDK_DBG) != NONE
            fatal("coro-split: the __coro_resume_N debug labels are not implemented yet");
    }
    irb_set_end(*b, unreach);
    irb_insert(*b, new_inst(.UNREACHABLE, ir.t_void, 0));
    shape.sw_resume_entry_block = new_entry;
}

// updateCoroFrame
coro_update_coro_frame :: (shape: *Coro_Shape, resume_fn: Value_Id, destroy_fn: Value_Id, cleanup_fn: Value_Id) {
    _, pt, _ := coro_insert_pt_after_frame_ptr(shape);
    b: Irb; irb_set_before(*b, pt);
    irb_store(*b, resume_fn, shape.frame_ptr, dl_abi_align(ir.t_ptr));
    doc := destroy_fn;
    ca := coro_id_coro_alloc(coro_shape_id(shape));
    if ca != NONE doc = irb_select(*b, ca, destroy_fn, cleanup_fn);
    da := irb_inbounds_ptr_add(*b, shape.frame_ptr, const_int(ir.t_i64, shape.sw_destroy_offset), "destroy.addr");
    irb_store(*b, doc, da, dl_abi_align(ir.t_ptr));
}

// setCoroInfo
coro_set_coro_info :: (f: Value_Id, shape: *Coro_Shape, fns: [] Value_Id) {
    arr_ty := type_array(cast(u64) fns.count, vtype(fns[0]));
    c := const_aggregate(.C_ARRAY, arr_ty, fns);
    gv := gv_create(arr_ty, true, .PRIVATE, c, tconcat(vname(f), ".resumers"), NONE, 0, 0);
    set_op(coro_shape_id(shape), 3, gv);
}

// SwitchCoroutineSplitter::split
coro_switch_split :: (f: Value_Id, shape: *Coro_Shape, clones: *[..] Value_Id) {
    coro_create_resume_entry_block(f, shape);
    resume := coro_switch_create_clone(f, ".resume", shape, .SWITCH_RESUME);
    destroy := coro_switch_create_clone(f, ".destroy", shape, .SWITCH_UNWIND);
    cleanup := coro_switch_create_clone(f, ".cleanup", shape, .SWITCH_CLEANUP);
    if shape.sw_has_coro_elide_no_alloc_variant coro_replace_switch_resume_coro_free(shape, resume, cleanup);
    coro_post_split_cleanup(resume);
    coro_post_split_cleanup(destroy);
    coro_post_split_cleanup(cleanup);
    coro_update_coro_frame(shape, resume, destroy, cleanup);
    array_add(clones, resume); array_add(clones, destroy); array_add(clones, cleanup);
    coro_set_coro_info(f, shape, clones.*);
}

// SwitchCoroutineSplitter::createNoAllocVariant
coro_create_no_alloc_variant :: (f: Value_Id, shape: *Coro_Shape, clones: *[..] Value_Id) -> Value_Id {
    oft := glob(f).value_type;
    ps: [..] Type_Id; ps.allocator = temp;
    for k: 0..cast(s64) func_nparams(oft) - 1 array_add(*ps, func_param(oft, cast(u32) k));
    array_add(*ps, ir.t_ptr);
    nft := type_func(func_ret(oft), ps, func_vararg(oft));
    nf := new_function(nft, "", glob(f).addrspace);
    gv_set_linkage(nf, glob(f).linkage);
    // Function::Create(..., Name) without a module: the name is set when it is inserted below
    vm: Value_Map; vmap_init(*vm);
    vmap_track_begin(*vm);
    defer vmap_track_end(*vm);
    for k: 0..cast(s64) glob(f).nargs - 1 vmap_set(*vm, fn_arg(f, cast(u32) k), fn_arg(nf, cast(u32) k));
    frame_idx := glob(nf).nargs - 1;
    returns: [..] Value_Id; returns.allocator = temp;
    coro_clone_function_into(nf, f, *vm, *returns);
    if shape.coro_begin != NONE {
        ncb := vmap_lookup(*vm, shape.coro_begin);
        coro_elide_coro_free(ncb);
        coro_suppress_coro_allocs(coro_begin_id(ncb));
        coro_rauw(ncb, fn_arg(nf, frame_idx));
        coro_erase(ncb);
    }
    array_add(*ir.m_functions, nf);
    set_name(nf, tconcat(vname(f), ".noalloc"));
    remove_unreachable_blocks(nf, null);
    glob(nf).attrs = coro_add_frame_pointer_attrs(glob(nf).attrs, frame_idx, shape.frame_size, shape.frame_align, false);
    array_add(clones, nf);
    coro_set_coro_info(f, shape, clones.*);
    gv_set_linkage(nf, .INTERNAL);
    return nf;
}

// ---------------------------------------------------------------- retcon / async splitting

// replaceAsyncResumeFunction
coro_replace_async_resume_function :: (susp: Value_Id, continuation: Value_Id) {
    ri := coro_async_suspend_resume_fn(susp);
    b: Irb; irb_set_before(*b, ri);
    v := irb_pointer_bitcast_or_addrspacecast(*b, continuation, ir.t_ptr);
    coro_rauw(ri, v);
    coro_erase(ri);
    set_op(susp, CORO_ASYNC_SUSPEND_RESUME_FUNCTION_ARG, const_poison(ir.t_ptr));
}

// coerceArguments + coro::createMustTailCall
coro_create_must_tail_call :: (loc: Md_Id, mt: Value_Id, args: [] Value_Id, b: *Irb) -> Value_Id {
    fty := glob(mt).value_type;
    call_args: [..] Value_Id; call_args.allocator = temp;
    for k: 0..cast(s64) func_nparams(fty) - 1 {
        pt := func_param(fty, cast(u32) k);
        a := args[k];
        if pt != vtype(a) array_add(*call_args, coro_irb_bit_or_pointer_cast(b, a, pt));
        else array_add(*call_args, a);
    }
    tc := irb_call(b, mt, call_args);
    call_set_tail_kind(tc, TCK_MUSTTAIL);
    set_metadata(tc, MDK_DBG, loc);
    inst(tc).cc = glob(mt).cc;
    return tc;
}
// CreateBitOrPointerCast
coro_irb_bit_or_pointer_cast :: (b: *Irb, v: Value_Id, dt: Type_Id) -> Value_Id {
    st := vtype(v);
    if st == dt return v;
    if is_ptr_type(scalar_type(st)) && is_int_type(scalar_type(dt)) return irb_cast(b, .PTRTOINT, v, dt);
    if is_int_type(scalar_type(st)) && is_ptr_type(scalar_type(dt)) return irb_cast(b, .INTTOPTR, v, dt);
    return irb_cast(b, .BITCAST, v, dt);
}

// AsyncABI::splitCoroutine
coro_async_split :: (f: Value_Id, shape: *Coro_Shape, clones: *[..] Value_Id) {
    coro_fn_remove_fn_attr(f, .NoReturn);
    coro_fn_remove_ret_attr(f, .NoAlias);
    coro_fn_remove_ret_attr(f, .NonNull);
    id := coro_shape_id(shape);
    b: Irb; irb_set_before(*b, id);
    fp := coro_async_id_storage(id);
    fp = coro_irb_bit_or_pointer_cast(*b, fp, ir.t_ptr);
    fp = irb_inbounds_ptr_add(*b, fp, const_int(ir.t_i64, shape.as_frame_offset), "async.ctx.frameptr");
    old_fp := shape.frame_ptr;
    coro_rauw(shape.coro_begin, fp);
    if old_fp == shape.coro_begin shape.frame_ptr = fp;   // TrackingVH
    next_f := coro_next_function(f);
    for susp: shape.coro_suspends {
        idx := it_index;
        suffix := ".resume.";
        pname := vname(coro_async_suspend_projection_fn(susp));
        swift := false;
        if pname == "__swift_async_resume_project_context" { suffix = "TQ"; swift = true; }
        else if pname == "__swift_async_resume_get_context" { suffix = "TY"; swift = true; }
        nm := ifx swift then tconcat(suffix, tdec(cast(u64) idx), "_") else tconcat(suffix, tdec(cast(u64) idx));
        cont := coro_create_clone_declaration(f, shape, nm, next_f, susp);
        array_add(clones, cont);
        sbb := inst_block(susp);
        nsbb := split_basic_block(sbb, susp, "");
        br := block_terminator(sbb);
        ret_bb := create_block(f, "coro.return", nsbb);
        set_successor(br, 0, ret_bb);
        rb: Irb; irb_set_end(*rb, ret_bb);
        mt := coro_async_suspend_must_tail_fn(susp);
        args: [..] Value_Id; args.allocator = temp;
        n := call_arg_count(susp);
        for k: CORO_ASYNC_SUSPEND_MUST_TAIL_CALL_FUNC_ARG + 1..cast(s64) n - 1 array_add(*args, call_arg(susp, cast(u32) k));
        tc := coro_create_must_tail_call(get_metadata(susp, MDK_DBG), mt, args, *rb);
        irb_insert(*rb, new_inst(.RET, ir.t_void, 0));
        ifi: Inline_Function_Info; ifi_reset(*ifi);
        inline_function(tc, *ifi, false, null, true, false);
        coro_replace_async_resume_function(susp, cont);
    }
    for susp: shape.coro_suspends
        coro_base_create_clone(f, tconcat("resume.", tdec(cast(u64) it_index)), shape, clones.*[it_index], susp);
}
// std::next(F.getIterator()) as an insertion position (NONE = end)
coro_next_function :: (f: Value_Id) -> Value_Id {
    for ir.m_functions if it == f { if it_index + 1 < ir.m_functions.count return ir.m_functions[it_index + 1]; return NONE; }
    return NONE;
}

// AnyRetconABI::splitCoroutine
coro_retcon_split :: (f: Value_Id, shape: *Coro_Shape, clones: *[..] Value_Id) {
    coro_fn_remove_fn_attr(f, .NoReturn);
    coro_fn_remove_ret_attr(f, .NoAlias);
    coro_fn_remove_ret_attr(f, .NonNull);
    id := coro_shape_id(shape);
    raw: Value_Id;
    if shape.rc_is_frame_inline_in_storage raw = coro_retcon_storage(id);
    else {
        b: Irb; irb_set_before(*b, id);
        raw = coro_emit_alloc(shape, *b, const_int(ir.t_i64, shape.frame_size));
        raw = irb_bitcast(*b, raw, vtype(shape.coro_begin));
        irb_store(*b, raw, coro_retcon_storage(id), dl_abi_align(vtype(raw)));
    }
    old_fp := shape.frame_ptr;
    coro_rauw(shape.coro_begin, raw);
    if old_fp == shape.coro_begin shape.frame_ptr = raw;   // TrackingVH
    ret_bb: Value_Id = NONE;
    cont_phi: Value_Id = NONE;
    ret_phis: [..] Value_Id; ret_phis.allocator = temp;
    next_f := coro_next_function(f);
    for susp: shape.coro_suspends {
        cont := coro_create_clone_declaration(f, shape, tconcat(".resume.", tdec(cast(u64) it_index)), next_f, NONE);
        array_add(clones, cont);
        sbb := inst_block(susp);
        nsbb := split_basic_block(sbb, susp, "");
        br := block_terminator(sbb);
        if ret_bb == NONE {
            ret_bb = create_block(f, "coro.return", nsbb);
            shape.rc_return_block = ret_bb;
            b: Irb; irb_set_end(*b, ret_bb);
            cont_phi = irb_phi(*b, vtype(cont), cast(u32) shape.coro_suspends.count);
            for rt: coro_retcon_result_types(shape) array_add(*ret_phis, irb_phi(*b, rt, cast(u32) shape.coro_suspends.count));
            rty := func_ret(glob(f).value_type);
            cast_ty := ifx ret_phis.count == 0 then rty else type_sub(rty, 0);
            casted := irb_bitcast(*b, cont_phi, cast_ty);
            rv := casted;
            if ret_phis.count {
                rv = const_poison(rty);
                rv = irb_insert_value(*b, rv, casted, .[0]);
                for p: ret_phis rv = irb_insert_value(*b, rv, p, .[cast(u32) it_index + 1]);
            }
            coro_create_ret(*b, rv);
        }
        set_successor(br, 0, ret_bb);
        phi_add_incoming(cont_phi, cont, sbb);
        for p: ret_phis phi_add_incoming(p, call_arg(susp, cast(u32) it_index), sbb);
    }
    for susp: shape.coro_suspends
        coro_base_create_clone(f, tconcat("resume.", tdec(cast(u64) it_index)), shape, clones.*[it_index], susp);
}

// ---------------------------------------------------------------- doSplitCoroutine and the pass

// removeCoroEndsFromRampFunction
coro_remove_coro_ends_from_ramp :: (shape: *Coro_Shape) {
    if shape.abi != .SWITCH { for shape.coro_ends coro_replace_coro_end(it, shape, shape.frame_ptr, true); }
    else for shape.coro_ends coro_erase(it);
}
// removeCoroIsInRampFromRampFunction
coro_remove_coro_is_in_ramp_from_ramp :: (shape: *Coro_Shape) {
    for shape.coro_is_in_ramp_insts { coro_rauw(it, const_int(ir.t_i1, 1)); coro_erase(it); }
}
// hasSafeElideCaller
coro_has_safe_elide_caller :: (f: Value_Id) -> bool {
    u := ir.v_first_use[f];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) || !is_call_base(usr) continue;
        caller := inst_parent_fn(usr);
        if caller != NONE && fn_has_fn_attr(caller, .PresplitCoroutine) && call_has_fn_attr(usr, .CoroElideSafe) return true;
    }
    return false;
}

// doSplitCoroutine
coro_do_split_coroutine :: (f: Value_Id, clones: *[..] Value_Id, shape: *Coro_Shape, optimize_frame: bool) {
    coro_lower_await_suspends(f, shape);
    coro_simplify_suspend_points(shape);
    coro_normalize_coroutine(f, shape);
    coro_build_coroutine_frame(f, shape, optimize_frame);
    coro_replace_frame_size_and_alignment(shape);
    no_suspend := shape.coro_suspends.count == 0;
    no_alloc := !no_suspend && shape.abi == .SWITCH && coro_has_safe_elide_caller(f) && !fn_has_fn_attr(f, .NoInline);
    if shape.abi == .SWITCH shape.sw_has_coro_elide_no_alloc_variant = no_alloc;
    if no_suspend coro_handle_no_suspend_coroutine(shape);
    else if shape.abi == {
      case .SWITCH; coro_switch_split(f, shape, clones);
      case .ASYNC; coro_async_split(f, shape, clones);
      case .RETCON; #through;
      case .RETCON_ONCE; coro_retcon_split(f, shape, clones);
    }
    coro_replace_swift_error_ops(f, shape, null);
    a2a: Table(Value_Id, Value_Id); a2a.allocator = temp;
    for coro_collect_dbg_variable_records(f) coro_salvage_debug_info(*a2a, it, false);
    coro_remove_coro_ends_from_ramp(shape);
    coro_remove_coro_is_in_ramp_from_ramp(shape);
    if no_alloc coro_create_no_alloc_variant(f, shape, clones);
}

// updateCallGraphAfterCoroutineSplit
coro_update_call_graph_after_split :: (nd: s32, shape: *Coro_Shape, clones: [] Value_Id, c: s32, ur: *Cgscc_Ur) -> s32 {
    cur := c;
    f := lcg_fn(nd);
    if clones.count {
        if shape.abi == .SWITCH {
            if shape.sw_has_coro_elide_no_alloc_variant {
                lcg_add_split_function(f, clones[2]);
                lcg_add_split_function(f, clones[1]);
                lcg_add_split_function(f, clones[0]);
                for k: 3..clones.count - 1 lcg_add_split_function(f, clones[k]);
            } else for clones lcg_add_split_function(f, it);
        } else lcg_add_split_ref_recursive_functions(f, clones);
        for clones fam_invalidate(it, PRESERVE_NONE);
        cur = update_cg_and_am_for_pass(cur, nd, ur, false);
    }
    coro_post_split_cleanup(f);
    fam_invalidate(f, PRESERVE_NONE);
    cur = update_cg_and_am_for_pass(cur, nd, ur, true);
    return cur;
}

// replacePrepare
coro_replace_prepare :: (prep: Value_Id) {
    cast_fn := call_arg(prep, 0);
    fnv := strip_pointer_casts(cast_fn);
    u := ir.v_first_use[prep];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) || inst_op(usr) != .BITCAST || vtype(usr) != vtype(fnv) continue;
        coro_rauw(usr, fnv);
        coro_erase(usr);
    }
    coro_rauw(prep, cast_fn);
    coro_erase(prep);
    while is_inst(cast_fn) && inst_op(cast_fn) == .BITCAST {
        if has_uses(cast_fn) break;
        nx := op(cast_fn, 0);
        coro_erase(cast_fn);
        cast_fn = nx;
    }
}

// CoroSplitPass::run
coro_split_run_scc :: (node: *Pass_Node, c: s32, ur: *Cgscc_Ur) -> Preserved {
    optimize_frame := contains(node.name, "<reuse-storage>") || node.opt_level > 0;
    prepare_fns: [..] Value_Id; prepare_fns.allocator = temp;
    for name: string.["llvm.coro.prepare.retcon", "llvm.coro.prepare.async"] {
        p := module_get_function(name);
        if p != NONE && has_uses(p) array_add(*prepare_fns, p);
    }
    coroutines: [..] s32; coroutines.allocator = temp;
    for n: lcg.sccs[c].nodes if fn_has_fn_attr(lcg_fn(n), .PresplitCoroutine) array_add(*coroutines, n);
    if coroutines.count == 0 && prepare_fns.count == 0 return PRESERVE_ALL;
    cur := c;
    for nd: coroutines {
        f := lcg_fn(nd);
        remove_unreachable_blocks(f, null);
        shape: Coro_Shape;
        coro_shape_build(*shape, f);
        if shape.coro_begin == NONE continue;
        coro_fn_remove_fn_attr(f, .PresplitCoroutine);   // F.setSplittedCoroutine()
        if coro_is_begin(shape.coro_begin) && call_iid(shape.coro_begin) == IID_CORO_BEGIN_CUSTOM_ABI
            fatal("Custom ABI not found amoung those specified");
        coro_abi_init(*shape);
        clones: [..] Value_Id; clones.allocator = temp;
        coro_do_split_coroutine(f, *clones, *shape, optimize_frame);
        cur = coro_update_call_graph_after_split(nd, *shape, clones, cur, ur);
        if shape.coro_suspends.count {
            pwl_insert(ur.cwl, cur);
            for clones pwl_insert(ur.cwl, lcg_lookup_scc(lcg_get_node(it)));
        } else if shape.abi == .ASYNC pwl_insert(ur.cwl, c);
    }
    for p: prepare_fns {
        u := ir.v_first_use[p];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            coro_replace_prepare(usr);
        }
    }
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- CoroAnnotationElide

coro_annotation_elide_run_scc :: (c: s32) -> Preserved {
    for n: lcg.sccs[c].nodes {
        if module_get_function(tconcat(vname(lcg_fn(n)), ".noalloc")) != NONE
            fatal("coro-annotation-elide: eliding coroutine allocations is not implemented yet");
    }
    return PRESERVE_ALL;
}
