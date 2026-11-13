// The manifest/cleanup side of llvm/lib/Transforms/IPO/Attributor.cpp: changeUseAfterManifest / changeAfterManifest
// and the other after-manifest registrations, cleanupIR, identifyDeadInternalFunctions,
// isValidFunctionSignatureRewrite / registerFunctionSignatureRewrite / rewriteFunctionSignatures,
// createShallowWrapper, internalizeFunctions, the CallGraphUpdater (llvm/lib/Transforms/Utils/CallGraphUpdater.cpp)
// steps the passes need, and AAIndirectCallInfo's specialization with isLegalToPromote / promoteCall
// (llvm/lib/Transforms/Utils/CallPromotionUtils.cpp).

// changeUseAfterManifest
atr_change_use_after_manifest :: (u: Use_Id, nv: Value_Id) -> bool {
    found, k := table_find(*atr.to_be_changed_uses_idx, u);
    if found {
        v := atr.to_be_changed_uses[k][1];
        if v != NONE && (atr_strip_pointer_casts(v) == atr_strip_pointer_casts(nv) || is_undef_value(v)) return false;
        atr.to_be_changed_uses[k][1] = nv;
        return true;
    }
    array_add(*atr.to_be_changed_uses, .[u, nv]);
    table_set(*atr.to_be_changed_uses_idx, u, atr.to_be_changed_uses.count - 1);
    return true;
}
// changeAfterManifest
atr_change_after_manifest :: (p: Irp, nv: Value_Id, change_droppable := true) -> bool {
    if irp_kind(p) == .CALL_SITE_ARGUMENT {
        cb := irp_ctx_i(p);
        return atr_change_use_after_manifest(op_use(cb, cast(u32) irp_cs_arg_no(p)), nv);
    }
    v := irp_assoc_value(p);
    found, k := table_find(*atr.to_be_changed_values_idx, v);
    if found {
        cur := atr.to_be_changed_values[k][1];
        if cur != NONE && (atr_strip_pointer_casts(cur) == atr_strip_pointer_casts(nv) || is_undef_value(cur)) return false;
        atr.to_be_changed_values[k][1] = nv;
        atr.to_be_changed_values[k][2] = cast(u32) change_droppable;
        return true;
    }
    array_add(*atr.to_be_changed_values, .[v, nv, cast(u32) change_droppable]);
    table_set(*atr.to_be_changed_values_idx, v, atr.to_be_changed_values.count - 1);
    return true;
}
atr_set_insert :: (l: *[..] Value_Id, v: Value_Id) { for l.* if it == v return; array_add(l, v); }
atr_change_to_unreachable_after_manifest :: (x: Value_Id) { atr_set_insert(*atr.to_unreachable, x); }
atr_register_invoke_with_dead_successor :: (ii: Value_Id) { atr_set_insert(*atr.invoke_dead_succ, ii); }
atr_delete_inst_after_manifest :: (x: Value_Id) { atr_set_insert(*atr.deleted_insts, x); }
atr_delete_block_after_manifest :: (bb: Value_Id) { atr_set_insert(*atr.deleted_blocks, bb); }
atr_delete_fn_after_manifest :: (f: Value_Id) { if atr.delete_fns atr_set_insert(*atr.deleted_fns, f); }
atr_register_manifest_added_block :: (bb: Value_Id) { table_set(*atr.manifest_added_blocks, bb, true); }

// a WeakVH that is still an instruction (erased instructions null their handles)
atr_alive_inst :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .INST && inst(v).parent != NONE; }

// ---------------------------------------------------------------- remarks

atr_emit_remark_inst :: (x: Value_Id, name: string, msg: string) {
    // remarks are not emitted (no -pass-remarks support)
}
atr_emit_ub_remark :: (x: Value_Id) { atr_emit_remark_inst(x, "UndefinedBehavior", ""); }

// ---------------------------------------------------------------- signature rewrites

// isValidFunctionSignatureRewrite
atr_is_valid_function_signature_rewrite :: (arg: Value_Id, types: [] Type_Id) -> bool {
    if !atr.rewrite_signatures return false;
    f := arg_parent(arg);
    if func_vararg(glob(f).value_type) return false;
    l := glob(f).attrs;
    if attr_list_has_somewhere(l, .Nest) || attr_list_has_somewhere(l, .StructRet) || attr_list_has_somewhere(l, .InAlloca) || attr_list_has_somewhere(l, .Preallocated) return false;
    uai := false;
    ok := true;
    for cb: atr_call_sites_of(f, true, NONE, *uai, *ok, true) {
        // CallSiteCanBeChanged
        cf := acs_called_function(acs);
        if cf == NONE || vtype(cb) != fn_ret_type(cf) || vtype(call_callee(cb)) != vtype(f) || acs_num_args(acs) != fn_nargs(f) || acs_is_callback(acs) || call_is_must_tail(cb) { ok = false; break; }
    }
    if !ok return false;
    for ci: atr_opcode_insts(f, .[.CALL]) if call_is_must_tail(ci) return false;
    return true;
}
attr_list_has_somewhere :: (l: u32, k: Attr_Kind) -> bool {
    if attr_set_has(attr_list_fn(l), k) || attr_set_has(attr_list_ret(l), k) return true;
    if l == 0 return false;
    for ir.attr_lists[l].params if attr_set_has(it, k) return true;
    return false;
}
// registerFunctionSignatureRewrite
atr_register_function_signature_rewrite :: (arg: Value_Id, types: [] Type_Id, repair: u8) -> bool {
    ari: Arg_Replacement;
    for types array_add(*ari.types, it);
    ari.repair = repair;
    return atr_register_function_signature_rewrite_ari(arg, ari);
}
atr_register_function_signature_rewrite_ari :: (arg: Value_Id, ari: Arg_Replacement) -> bool {
    f := arg_parent(arg);
    aris := table_find_pointer(*atr.arg_replacements, f);
    if !aris {
        n: [..] Arg_Replacement;
        for 0..cast(s64) fn_nargs(f) - 1 { e: Arg_Replacement; array_add(*n, e); }
        table_set(*atr.arg_replacements, f, n);
        array_add(*atr.arg_replacement_order, f);
        aris = table_find_pointer(*atr.arg_replacements, f);
    }
    cur := *aris.*[arg_no(arg)];
    if cur.present && cur.types.count <= ari.types.count return false;
    cur.* = ari;
    cur.present = true;
    return true;
}

// rewriteFunctionSignatures
atr_rewrite_function_signatures :: (modified: *[..] Value_Id) -> bool {
    changed := ATR_UNCHANGED;
    atr_check_rewrite_order_independent();
    for old_fn: atr.arg_replacement_order {
        if !atr_fn_in_set(old_fn) continue;
        dead := false;
        for atr.deleted_fns if it == old_fn { dead = true; break; }
        if dead continue;
        aris := table_find_pointer(*atr.arg_replacements, old_fn).*;
        new_types: [..] Type_Id; new_types.allocator = temp;
        new_attrs: [..] u32; new_attrs.allocator = temp;
        old_list := glob(old_fn).attrs;
        for k: 0..cast(s64) fn_nargs(old_fn) - 1 {
            if aris[k].present {
                for aris[k].types { array_add(*new_types, it); array_add(*new_attrs, 0); }
            } else {
                array_add(*new_types, vtype(fn_arg(old_fn, cast(u32) k)));
                array_add(*new_attrs, attr_list_param(old_list, cast(u32) k));
            }
        }
        largest: u64 = 0;
        for new_types if is_vector_type(it) largest = max(largest, dl_type_size_bits(it));
        old_ty := glob(old_fn).value_type;
        nfty := type_func(func_ret(old_ty), new_types, func_vararg(old_ty));
        new_fn := ipo_fn_create(nfty, glob(old_fn).linkage, glob(old_fn).addrspace);
        array_add(*atr.functions, new_fn);
        table_set(*atr.fn_set, new_fn, true);
        ipo_fn_insert_before(new_fn, old_fn);
        gv_take_name(new_fn, old_fn);
        ipo_fn_copy_attributes_from(new_fn, old_fn);
        sp := get_metadata(old_fn, MDK_DBG);
        if sp != NONE { set_metadata(new_fn, MDK_DBG, sp); set_metadata(old_fn, MDK_DBG, NONE); }
        glob(new_fn).attrs = attr_list_get(attr_list_fn(old_list), attr_list_ret(old_list), new_attrs);
        ipo_update_min_legal_vector_width_attr(new_fn, largest);
        me := fn_memory_effects(new_fn);
        if me_does_access_arg_pointees(me) {
            all := true;
            for t: new_types {
                if !is_ptr_or_ptr_vector(t) continue;
                if !attr_set_has(attr_list_param(glob(new_fn).attrs, cast(u32) it_index), .ReadNone) { all = false; break; }
            }
            if all fn_set_memory_effects(new_fn, me_without_loc(me, LOC_ARG));
        }
        ipo_fn_splice_body(new_fn, old_fn);
        // the call sites
        pairs: [..] [2] Value_Id; pairs.allocator = temp;
        uai := false;
        ok := true;
        for old_cb: atr_call_sites_of(old_fn, true, NONE, *uai, *ok, true) {
            old_cl := inst(old_cb).attrs;
            args: [..] Value_Id; args.allocator = temp;
            arg_attrs: [..] u32; arg_attrs.allocator = temp;
            for k: 0..aris.count - 1 {
                if aris[k].present {
                    n0 := args.count;
                    if aris[k].repair == ARI_PRIV {
                        priv_create_replacement_values(aris[k].priv_align, aris[k].priv_ty, old_cb, call_arg(old_cb, cast(u32) k), *args);
                    }
                    if args.count - n0 != aris[k].types.count fatal("internal: attributor: the call site repair did not provide all operands");
                    for aris[k].types array_add(*arg_attrs, 0);
                } else {
                    array_add(*args, call_arg(old_cb, cast(u32) k));
                    array_add(*arg_attrs, attr_list_param(old_cl, cast(u32) k));
                }
            }
            ncb := ipo_create_call_like(old_cb, nfty, new_fn, args, old_cb);
            if inst_op(old_cb) == .CALL inst(ncb).flags = inst(old_cb).flags & ((cast(u32) 3) << TAIL_SHIFT);
            ipo_copy_prof_dbg(ncb, old_cb);
            inst(ncb).cc = inst(old_cb).cc;
            take_name(ncb, old_cb);
            inst(ncb).attrs = attr_list_get(attr_list_fn(old_cl), attr_list_ret(old_cl), arg_attrs);
            ipo_update_min_legal_vector_width_attr(inst_fn(old_cb), largest);
            array_add(*pairs, .[old_cb, ncb]);
        }
        if !ok fatal("internal: attributor: assumed call site replacement to succeed");
        // rewire the arguments
        nk: u32 = 0;
        for k: 0..aris.count - 1 {
            oa := fn_arg(old_fn, cast(u32) k);
            if aris[k].present {
                if aris[k].repair == ARI_PRIV priv_callee_repair(*aris[k], new_fn, nk);
                if aris[k].types.count == 0 rauw_with_metadata(oa, const_poison(vtype(oa)));
                nk += cast(u32) aris[k].types.count;
            } else {
                na := fn_arg(new_fn, nk);
                take_name(na, oa);
                rauw_with_metadata(oa, na);
                nk += 1;
            }
        }
        for pr: pairs {
            atr_set_insert(modified, inst_fn(pr[0]));
            rauw_with_metadata(pr[0], pr[1]);
            erase_inst_with_metadata(pr[0]);
        }
        // the blockaddresses of the moved blocks follow them (BlockAddress::getFunction is the block's parent)
        ba: [..] Use_Id; ba.allocator = temp;
        u := ir.v_first_use[old_fn];
        while u != NONE { if vkind(ir.u_user[u]) == .C_BLOCKADDR array_add(*ba, u); u = ir.u_next[u]; }
        if ba.count {
            all_ba := true;
            u = ir.v_first_use[old_fn];
            while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR all_ba = false; u = ir.u_next[u]; }
            if !all_ba fatal("attributor: a rewritten function with blockaddresses and other uses is not supported yet");
            replace_all_uses_with(old_fn, new_fn);
        }
        // CGUpdater.replaceFunctionWith(*OldFn, *NewFn)
        atr_replace_function_with(old_fn, new_fn);
        for modified.* if it == old_fn { array_ordered_remove_by_index(modified, it_index); atr_set_insert(modified, new_fn); break; }
        changed = ATR_CHANGED;
    }
    return changed;
}
// ArgumentReplacementMap is a DenseMap<Function *, ...> iterated in pointer-hash order. The order only shows when
// two privatizing rewrites create the "<ptr>.b<offset>" pointers in the same caller (name uniquing).
atr_check_rewrite_order_independent :: () {
    if atr.arg_replacement_order.count < 2 return;
    callers: Table(Value_Id, Value_Id); callers.allocator = temp;
    for f: atr.arg_replacement_order {
        aris := table_find_pointer(*atr.arg_replacements, f).*;
        priv := false;
        for aris if it.present && it.repair == ARI_PRIV && it.types.count > 1 priv = true;
        if !priv continue;
        u := ir.v_first_use[f];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) {
                c := inst_fn(usr);
                found, other := table_find(*callers, c);
                if found && other != f fatal("attributor: several signature rewrites with call sites in one function (DenseMap order) are not supported yet");
                table_set(*callers, c, f);
            }
            u = ir.u_next[u];
        }
    }
}

// AAPrivatizablePtrArgument's FnRepairCB
priv_callee_repair :: (ari: *Arg_Replacement, new_fn: Value_Id, argno: u32) {
    entry := fn_entry(new_fn);
    ip := block_first_insertion_pt(entry);
    as := dl_alloca_addrspace();
    ai := new_inst(.ALLOCA, type_ptr(as), 1);
    set_op(ai, 0, const_int(ir.t_i32, 1));
    inst(ai).ty2 = ari.priv_ty;
    inst(ai).addrspace = as;
    inst(ai).align = dl_pref_align(ari.priv_ty);
    insert_at_position(ai, entry, ip, false);
    set_name(ai, tconcat(vname(ari.priv_arg), ".priv"));
    priv_create_initialization(ari.priv_ty, ai, new_fn, argno, ip);
    repl := ai;
    if vtype(ai) != vtype(ari.priv_arg) {
        c := create_cast(.ADDRSPACECAST, ai, vtype(ari.priv_arg));
        inst_insert_before(c, ip);
        repl = c;
    }
    rauw_with_metadata(ari.priv_arg, repl);
    for ari.tail_calls inst(it).flags &= ~((cast(u32) 3) << TAIL_SHIFT);
}

// ---------------------------------------------------------------- CallGraphUpdater

atr_cg_dead_functions: [..] Value_Id;
atr_cg_replaced: Table(Value_Id, bool);
atr_cgscc_replaced: [..] [2] Value_Id;   // (old, new) for the CGSCC pass to substitute in the call graph

// CallGraphUpdater::removeFunction
atr_cg_remove_function :: (f: Value_Id) {
    fn_delete_body(f);
    gv_set_linkage(f, .EXTERNAL);
    array_add(*atr_cg_dead_functions, f);
}
// CallGraphUpdater::replaceFunctionWith
atr_replace_function_with :: (old_fn: Value_Id, new_fn: Value_Id) {
    remove_dead_constant_users(old_fn);
    table_set(*atr_cg_replaced, old_fn, true);
    if !atr.is_module_pass array_add(*atr_cgscc_replaced, .[old_fn, new_fn]);
    atr_cg_remove_function(old_fn);
}
// CallGraphUpdater::finalize (the destructor)
atr_finish_deleted_functions :: () {
    for f: atr_cg_dead_functions {
        remove_dead_constant_users(f);
        md_as_value_deleted(f, false);
        replace_non_metadata_uses_with(f, const_poison(vtype(f)));
        gv_erase_from_parent(f);
    }
    atr_cg_dead_functions.count = 0;
    table_reset(*atr_cg_replaced);
}

// ---------------------------------------------------------------- cleanupIR

// identifyDeadInternalFunctions
atr_identify_dead_internal_functions :: () {
    if !atr.delete_fns return;
    internal: [..] Value_Id; internal.allocator = temp;
    for f: atr.functions {
        if !gv_has_local_linkage(f) continue;
        if !atr.is_module_pass && tli_is_lib_func(f) continue;
        array_add(*internal, f);
    }
    live: Table(Value_Id, bool); live.allocator = temp;
    found_live := true;
    while found_live {
        found_live = false;
        for * f: internal {
            if f.* == NONE continue;
            uai := false;
            ok := true;
            for cb: atr_call_sites_of(f.*, true, NONE, *uai, *ok) {
                callee := inst_fn(cb);
                good := false;
                for atr.deleted_fns if it == callee { good = true; break; }
                if !good good = atr_fn_in_set(callee) && gv_has_local_linkage(callee) && !table_contains(*live, callee);
                if !good { ok = false; break; }
            }
            if ok continue;
            table_set(*live, f.*, true);
            f.* = NONE;
            found_live = true;
        }
    }
    for internal if it != NONE atr_set_insert(*atr.deleted_fns, it);
}
// TLI->getLibFunc(F, LF)
tli_is_lib_func :: (f: Value_Id) -> bool {
    ok, _ := tli_lookup_fn(f);
    return ok;
}

atr_cleanup_ir :: () -> bool {
    dead_insts: [..] Value_Id; dead_insts.allocator = temp;
    terminators_to_fold: [..] Value_Id; terminators_to_fold.allocator = temp;
    is_to_be_deleted :: (x: Value_Id) -> bool { for atr.deleted_insts if it == x return true; return false; }
    replace_use :: (u: Use_Id, nv_in: Value_Id, dead_insts: *[..] Value_Id, terminators_to_fold: *[..] Value_Id) {
        old := ir.u_val[u];
        nv := nv_in;
        while true {
            found, k := table_find(*atr.to_be_changed_values_idx, nv);
            if !found break;
            e := atr.to_be_changed_values[k][1];
            if e == NONE break;
            nv = e;
        }
        user := ir.u_user[u];
        ui := ifx is_inst(user) then user else NONE;
        if ui != NONE && inst_op(ui) == .RET {
            ci := atr_strip_pointer_casts(old);
            if is_inst(ci) && inst_op(ci) == .CALL && call_is_must_tail(ci) && !is_to_be_deleted(ci) return;
            if vkind(nv) != .ARGUMENT {
                f := inst_fn(ui);
                for k: 0..cast(s64) fn_nargs(f) - 1 tre_fn_remove_param_attr(f, cast(u32) k, .Returned);
            }
        }
        use_set(u, nv);
        if is_inst(old) {
            atr_set_insert(*atr.cg_modified, inst_fn(old));
            if !is_phi(old) && !is_to_be_deleted(old) && atr_is_trivially_dead(old) array_add(dead_insts, old);
        }
        if is_undef_value(nv) && irp_is_call(user) {
            if call_is_arg_operand(user, u) {
                idx := use_arg_no(u);
                call_remove_param_attr(user, idx, .NoUndef);
                callee := call_callee(user);
                if vkind(callee) == .FUNCTION && fn_nargs(callee) > idx tre_fn_remove_param_attr(callee, idx, .NoUndef);
            }
        }
        if is_constant_kind(vkind(nv)) && ui != NONE && inst_op(ui) == .CONDBR {
            if is_undef_value(nv) atr_change_to_unreachable_after_manifest(ui);
            else array_add(terminators_to_fold, ui);
        }
    }
    for e: atr.to_be_changed_uses replace_use(e[0], e[1], *dead_insts, *terminators_to_fold);
    k := 0;
    while k < atr.to_be_changed_values.count {
        e := atr.to_be_changed_values[k];
        k += 1;
        old := e[0]; nv := e[1]; done := e[2] != 0;
        uses: [..] Use_Id; uses.allocator = temp;
        u := ir.v_first_use[old];
        while u != NONE {
            if done || !is_droppable_user(ir.u_user[u]) array_add(*uses, u);
            u = ir.u_next[u];
        }
        for x: uses {
            usr := ir.u_user[x];
            if is_inst(usr) && !atr_is_run_on(inst_fn(usr)) continue;
            replace_use(x, nv, *dead_insts, *terminators_to_fold);
        }
    }
    for ii: atr.invoke_dead_succ {
        if !atr_alive_inst(ii) || inst_op(ii) != .INVOKE continue;
        unwind_dead := call_has_fn_attr(ii, .NoUnwind);
        normal_dead := call_has_fn_attr(ii, .NoReturn);
        invoke2call := !dead_may_catch_asynchronous_exceptions(inst_fn(ii));
        bb := inst_block(ii);
        normal := invoke_normal_dest(ii);
        if unwind_dead {
            next_ip := block_first(normal);
            if invoke2call {
                change_to_call(ii, null);
                next_ip = block_terminator(bb);
            }
            if normal_dead atr_change_to_unreachable_after_manifest(next_ip);
        } else {
            if block_unique_predecessor(normal) == NONE normal = split_block_predecessors(normal, .[bb], ".dead", null, null);
            atr_change_to_unreachable_after_manifest(block_first(normal));
        }
    }
    for t: terminators_to_fold {
        atr_set_insert(*atr.cg_modified, inst_fn(t));
        constant_fold_terminator(inst_block(t), false, null);
    }
    for x: atr.to_unreachable {
        if !atr_alive_inst(x) continue;
        atr_set_insert(*atr.cg_modified, inst_fn(x));
        change_to_unreachable(x, false, null);
    }
    for x: atr.deleted_insts {
        if !atr_alive_inst(x) continue;
        drop_droppable_uses(x);
        atr_set_insert(*atr.cg_modified, inst_fn(x));
        if type_kind(vtype(x)) != .VOID rauw_with_metadata(x, const_undef(vtype(x)));
        if !is_phi(x) && atr_is_trivially_dead(x) array_add(*dead_insts, x);
        else erase_inst_with_metadata(x);
    }
    live_dead: [..] Value_Id; live_dead.allocator = temp;
    for dead_insts if atr_alive_inst(it) array_add(*live_dead, it);
    had_dead_insts := live_dead.count != 0;
    atr_recursively_delete_trivially_dead_instructions(*live_dead);
    if atr.deleted_blocks.count {
        bbs: [..] Value_Id; bbs.allocator = temp;
        for bb: atr.deleted_blocks {
            atr_set_insert(*atr.cg_modified, block_fn(bb));
            if table_contains(*atr.manifest_added_blocks, bb) continue;
            array_add(*bbs, bb);
        }
        atr_detach_dead_blocks(bbs);
    }
    atr_identify_dead_internal_functions();
    changed := atr_rewrite_function_signatures(*atr.cg_modified);
    for f: atr.deleted_fns {
        if !atr_fn_in_set(f) continue;
        atr_cg_remove_function(f);
    }
    if atr.to_be_changed_uses.count changed = ATR_CHANGED;
    if atr.to_unreachable.count changed = ATR_CHANGED;
    if atr.deleted_fns.count changed = ATR_CHANGED;
    if atr.deleted_blocks.count changed = ATR_CHANGED;
    if atr.deleted_insts.count changed = ATR_CHANGED;
    if atr.invoke_dead_succ.count changed = ATR_CHANGED;
    if had_dead_insts changed = ATR_CHANGED;
    return changed;
}

// Instruction::dropDroppableUses
drop_droppable_uses :: (x: Value_Id) {
    us: [..] Use_Id; us.allocator = temp;
    u := ir.v_first_use[x];
    while u != NONE { if is_droppable_user(ir.u_user[u]) array_add(*us, u); u = ir.u_next[u]; }
    for us drop_droppable_use(it);
}

// ---------------------------------------------------------------- the CGSCC pass's call graph updates

atr_cgscc_update :: (c_in: s32, ur: *Cgscc_Ur) -> s32 {
    c := c_in;
    for pr: atr_cgscc_replaced {
        n := lcg_lookup(pr[0]);
        if n >= 0 lcg_replace_node_function(n, pr[1]);
    }
    atr_cgscc_replaced.count = 0;
    for f: atr.cg_modified {
        if !atr_fn_in_set(f) continue;
        dead := false;
        for atr.deleted_fns if it == f { dead = true; break; }
        if dead continue;
        n := lcg_lookup(f);
        if n < 0 continue;
        c = update_cg_and_am_for_pass(c, n, ur, false);
    }
    for f: atr_cg_dead_functions {
        remove_dead_constant_users(f);
        md_as_value_deleted(f, false);
        replace_non_metadata_uses_with(f, const_poison(vtype(f)));
        { table_remove(*fam, f); ac_virtual_clear(f); }
        gv_erase_from_parent(f);
    }
    atr_cg_dead_functions.count = 0;
    table_reset(*atr_cg_replaced);
    return c;
}

// ---------------------------------------------------------------- wrappers and internalization

// Attributor::createShallowWrapper
atr_create_shallow_wrapper :: (f: Value_Id) {
    if is_declaration(f) fatal("attributor: cannot create a shallow wrapper around a declaration");
    ft := glob(f).value_type;
    name := copy_string(vname(f),, temp);
    set_name(f, "");   // the inside function becomes anonymous
    w := new_function(ft, "", glob(f).addrspace);
    glob(w).linkage = glob(f).linkage;
    ipo_fn_insert_before(w, f);
    set_name(w, name);
    gv_set_linkage(f, .INTERNAL);
    replace_all_uses_with(f, w);
    glob(w).comdat = glob(f).comdat;
    glob(f).comdat = -1;
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(f, *mds);
    for mds add_metadata(w, it.kind, it.md);
    glob(w).attrs = glob(f).attrs;
    entry := create_block(w, "entry");
    args: [..] Value_Id; args.allocator = temp;
    for k: 0..cast(s64) fn_nargs(w) - 1 {
        a := fn_arg(w, cast(u32) k);
        array_add(*args, a);
        if vname(fn_arg(f, cast(u32) k)).count set_name(a, vname(fn_arg(f, cast(u32) k)));
    }
    ci := create_call_fn(f, args);
    block_append_inst(entry, ci);
    call_set_tail_kind(ci, TCK_TAIL);
    call_add_fn_attr(ci, Attr_Kind.NoInline);
    ret: Value_Id;
    if vtype(ci) == ir.t_void ret = new_inst(.RET, ir.t_void, 0);
    else { ret = new_inst(.RET, ir.t_void, 1); set_op(ret, 0, ci); }
    block_append_inst(entry, ret);
}
// CallGraphUpdater::reanalyzeFunction (a no-op without a lazy call graph)
atr_cg_reanalyze_function :: (f: Value_Id) {
    if !atr.is_module_pass fatal("attributor: -attributor-allow-deep-wrappers in the CGSCC pass is not supported yet");
}
// runAttributorOnFunctions' AllowDeepWrapper step: internalize the non-exact definitions
atr_internalize_non_exact_functions :: () {
    is_interposable_linkage :: (l: Linkage) -> bool { return l == .WEAK_ANY || l == .LINKONCE_ANY || l == .COMMON || l == .EXTERN_WEAK; }
    n := atr.functions.count;
    for k: 0..n - 1 {
        f := atr.functions[k];
        if is_declaration(f) || gv_is_definition_exact(f) || !has_uses(f) || is_interposable_linkage(glob(f).linkage) continue;
        // internalizeFunction(F): isInternalizable
        if gv_has_local_linkage(f) fatal("attributor: could not internalize function");
        vm: Value_Map; vmap_init(*vm);
        nf := clone_function(f, *vm, tprint("%.internalized", vname(f)), f);
        gv_set_visibility(nf, 0);
        gv_set_linkage(nf, .PRIVATE);
        glob(nf).dso_local = true;
        // replaceUsesWithIf(not a call from an internalized function)
        us: [..] Use_Id; us.allocator = temp;
        u := ir.v_first_use[f];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && is_call_base(usr) && inst_fn(usr) != f array_add(*us, u);
            u = ir.u_next[u];
        }
        for us use_set(it, nf);
        array_add(*atr.functions, nf);
        table_set(*atr.fn_set, nf, true);
        atr_replace_function_with(f, nf);
        // CGUpdater.reanalyzeFunction of the callers
        u = ir.v_first_use[nf];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && is_call_base(usr) atr_cg_reanalyze_function(inst_fn(usr));
            u = ir.u_next[u];
        }
    }
}
// Function::hasAddressTaken(nullptr, IgnoreCallbackUses=false, IgnoreAssumeLikeCalls=true, IgnoreLLVMUsed=true,
// IgnoreARCAttachedCall=false, IgnoreCastedDirectCall=true)
fn_has_address_taken_for_attributor :: (f: Value_Id) -> bool {
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if vkind(usr) == .C_BLOCKADDR continue;   // a blockaddress has no operands in LLVM 23: not a use of its function
        if !(is_inst(usr) && is_call_base(usr)) {
            o := opr_code(usr);
            is_cast := o == .BITCAST || o == .ADDRSPACECAST;
            if is_cast {
                all_assume_like := true;
                x := ir.v_first_use[usr];
                while x != NONE {
                    uu := ir.u_user[x];
                    if !(is_inst(uu) && is_assume_like_intrinsic(uu)) { all_assume_like = false; break; }
                    x = ir.u_next[x];
                }
                if all_assume_like continue;
            }
            if has_uses(usr) {
                fuu := usr;
                if is_cast && num_uses(usr) == 1 && has_uses(ir.u_user[ir.v_first_use[usr]]) fuu = ir.u_user[ir.v_first_use[usr]];
                all_used := true;
                x := ir.v_first_use[fuu];
                while x != NONE {
                    uu := ir.u_user[x];
                    if !(vkind(uu) == .GLOBAL_VAR && (vname(uu) == "llvm.compiler.used" || vname(uu) == "llvm.used")) { all_used = false; break; }
                    x = ir.u_next[x];
                }
                if all_used continue;
            }
            return true;
        }
        if is_assume_like_intrinsic(usr) continue;
        if opno_of(u) != nops(usr) - 1 return true;
    }
    return false;
}

// ---------------------------------------------------------------- printers

atr_print_dependencies :: () { fatal("attributor: -attributor-print-dep is not supported yet"); }
atr_dump_dependency_graph :: () { fatal("attributor: -attributor-dump-dep-graph is not supported yet"); }
atr_call_graph_populate_all :: () { fatal("attributor: -attributor-print-call-graph is not supported yet"); }
atr_call_graph_print :: () {}

// AAIndirectCallInfo's specialization manifest
// ---------------------------------------------------------------- indirect call specialization

// isLegalToPromote (llvm/lib/Transforms/Utils/CallPromotionUtils.cpp)
atr_is_legal_to_promote :: (cb: Value_Id, callee: Value_Id) -> bool {
    fty := glob(callee).value_type;
    if vtype(cb) != func_ret(fty) && !is_bit_or_noop_pointer_castable(func_ret(fty), vtype(cb)) return false;
    np := func_nparams(fty);
    na := call_arg_count(cb);
    if na != np && !func_vararg(fty) return false;
    k: u32 = 0;
    while k < np {
        if fn_has_param_attr(callee, k, .ByVal) != call_param_has_attr(cb, k, .ByVal) return false;
        if fn_has_param_attr(callee, k, .InAlloca) != call_param_has_attr(cb, k, .InAlloca) return false;
        formal := func_param(fty, k);
        actual := vtype(op(cb, k));
        if formal != actual {
            if !is_bit_or_noop_pointer_castable(actual, formal) return false;
            if call_is_must_tail(cb) {
                if type_kind(formal) != .PTR || type_kind(actual) != .PTR || type_addrspace(formal) != type_addrspace(actual) return false;
            }
        }
        k += 1;
    }
    while k < na {
        if call_param_has_attr(cb, k, .StructRet) return false;
        k += 1;
    }
    return true;
}
// promoteCall (CallPromotionUtils.cpp); returns the cast of the result (RetBitCast) or NONE
atr_promote_call :: (cb: Value_Id, callee: Value_Id) -> Value_Id {
    set_op(cb, nops(cb) - 1, callee);
    set_metadata(cb, md_kind_id("prof"), NONE);
    set_metadata(cb, md_kind_id("callees"), NONE);
    fty := glob(callee).value_type;
    if inst(cb).ty2 == fty return NONE;
    cs_ret := vtype(cb);
    callee_ret := func_ret(fty);
    inst(cb).ty2 = fty;   // mutateFunctionType (also the call's type)
    ir.v_type[cb] = callee_ret;
    attrs := inst(cb).attrs;
    np := func_nparams(fty);
    new_args := NewArray(cast(s64) np, u32,, allocator = temp);
    changed := false;
    for k: 0..cast(s64) np - 1 {
        a := op(cb, cast(u32) k);
        formal := func_param(fty, cast(u32) k);
        ps := attr_list_param(attrs, cast(u32) k);
        if vtype(a) != formal {
            c := create_bit_or_pointer_cast_inst(a, formal);
            inst_insert_before(c, cb);
            set_op(cb, cast(u32) k, c);
            kinds: [..] Attr_Kind; kinds.allocator = temp;
            type_incompatible_kinds(formal, ps, *kinds);
            ps = attr_set_remove_kinds(ps, kinds);
            if attr_set_has(ps, .ByVal) || attr_set_has(ps, .InAlloca) fatal("attributor: promoting a call with a byval/inalloca argument of another type is not supported yet");
            changed = true;
        }
        new_args[k] = ps;
    }
    ra := attr_list_ret(attrs);
    ret_bc: Value_Id = NONE;
    if cs_ret != ir.t_void && cs_ret != callee_ret {
        if inst_op(cb) != .CALL fatal("attributor: promoting an invoke with another return type is not supported yet");
        // createRetBitCast
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[cb];
        while u != NONE { us := ir.u_user[u]; dup := false; for users if it == us dup = true; if !dup array_add(*users, us); u = ir.u_next[u]; }
        ret_bc = create_bit_or_pointer_cast_inst(cb, cs_ret);
        inst_insert_after(ret_bc, cb);
        for users replace_uses_of_with(it, cb, ret_bc);
        kinds: [..] Attr_Kind; kinds.allocator = temp;
        type_incompatible_kinds(callee_ret, ra, *kinds);
        ra = attr_set_remove_kinds(ra, kinds);
        changed = true;
    }
    if changed inst(cb).attrs = attr_list_get(attr_list_fn(attrs), ra, new_args);
    return ret_bc;
}
// Attributor::shouldSpecializeCallSiteForCallee with the AttributorPass IndirectCalleeSpecializationCallback
atr_should_specialize_call_site_for_callee :: (cb: Value_Id, callee: Value_Id) -> bool {
    if !atr_max_spec_given return true;
    if atr_max_spec_per_cb == 0 return false;
    set := table_find_pointer(*atr.specialized, cb);
    if !set { empty: [..] Value_Id; table_set(*atr.specialized, cb, empty); set = table_find_pointer(*atr.specialized, cb); }
    if set.count >= cast(s64) atr_max_spec_per_cb { for set.* if it == callee return true; return false; }
    for set.* if it == callee return true;
    array_add(set, callee);
    return true;
}
// a CallInst::Create(FunctionCallee(CSFT, Callee), CSArgs, Name, InsertBefore)
atr_create_plain_call :: (fty: Type_Id, callee: Value_Id, args: [] Value_Id, name: string, before: Value_Id) -> Value_Id {
    c := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + 1));
    inst(c).ty2 = fty;
    for args set_op(c, cast(u32) it_index, it);
    set_op(c, cast(u32) args.count, callee);
    return insert_before_named(c, before, name);
}
// SplitBlockAndInsertIfThen(Cond, SplitBefore, /*Unreachable=*/false): the new then-block's terminator
atr_split_block_and_insert_if_then :: (cond: Value_Id, split_before: Value_Id) -> Value_Id {
    n := sroa_pending_dt_updates.count;
    tb := split_block_and_insert_if_then_else(cond, split_before, true, false, NONE);
    sroa_pending_dt_updates.count = n;   // no DomTreeUpdater here
    return block_terminator(tb);
}
// AAIndirectCallInfoCallSite::manifest, from "Special handling for the single callee case" on
ici_specialize :: (i: u32, cb: Value_Id) -> bool {
    e := ici_ext(i);
    fp := call_callee(cb);
    if type_addrspace(vtype(fp)) != 0 {
        c := create_cast(.ADDRSPACECAST, fp, type_ptr_as(0));
        fp = insert_before_named(c, cb, tprint("%.as0", vname(call_callee(cb))));
    }
    cb_is_void := vtype(cb) == ir.t_void;
    ip := cb;
    csft := inst(cb).ty2;
    cs_args: [..] Value_Id; cs_args.allocator = temp;
    for k: 0..cast(s64) call_arg_count(cb) - 1 array_add(*cs_args, op(cb, cast(u32) k));
    if e.all_known && e.assumed.count == 1 {
        nc := e.assumed[0];
        if atr_is_legal_to_promote(cb, nc) {
            atr_promote_call(cb, nc);
            return ATR_CHANGED;
        }
        if inst_op(cb) != .CALL fatal("attributor: specializing an indirect invoke is not supported yet");
        new_call := atr_create_plain_call(csft, nc, cs_args, vname(cb), cb);
        if !cb_is_void atr_change_after_manifest(irp_cs_returned(cb), new_call);
        atr_delete_inst_after_manifest(cb);
        return ATR_CHANGED;
    }
    if inst_op(cb) != .CALL fatal("attributor: specializing an indirect invoke is not supported yet");
    any := false;
    all := e.all_known;
    last_cmp: Value_Id = NONE;
    skipped: [..] Value_Id; skipped.allocator = temp;
    New_Call :: struct { c: Value_Id; ret: Value_Id; }
    new_calls: [..] New_Call; new_calls.allocator = temp;
    for nc: e.assumed {
        if !atr_should_specialize_call_site_for_callee(cb, nc) {
            array_add(*skipped, nc);
            all = false;
            continue;
        }
        any = true;
        last_cmp = insert_before_named(create_icmp(ICMP_EQ, fp, nc), ip, "");
        then_ti := atr_split_block_and_insert_if_then(last_cmp, ip);
        cbbb := inst(cb).parent;
        atr_register_manifest_added_block(inst(then_ti).parent);
        atr_register_manifest_added_block(inst(ip).parent);
        split_ti := inst(last_cmp).next;
        else_bb: Value_Id;
        if ip == cb {
            else_bb = create_block(block_fn(cbbb), "", cbbb);
            atr_register_manifest_added_block(else_bb);
            ip = create_br(cbbb);
            block_append_inst(else_bb, ip);
            replace_uses_of_with(split_ti, cbbb, else_bb);
        } else {
            else_bb = inst(ip).parent;
            replace_uses_of_with(then_ti, else_bb, cbbb);
        }
        ret_bc: Value_Id = NONE;
        new_call: Value_Id;
        if atr_is_legal_to_promote(cb, nc) {
            clone := ic_clone_inst(cb);
            inst_insert_before(clone, then_ti);
            ret_bc = atr_promote_call(clone, nc);
            new_call = clone;
        } else {
            new_call = atr_create_plain_call(csft, nc, cs_args, vname(cb), then_ti);
        }
        array_add(*new_calls, .{new_call, ret_bc});
    }
    attach_callee_md :: (c: Value_Id, all_known: bool, skipped: [] Value_Id) -> bool {
        if !all_known return ATR_UNCHANGED;
        ops := NewArray(skipped.count, Md_Id,, allocator = temp);
        for skipped ops[it_index] = md_value(it);
        set_metadata(c, md_kind_id("callees"), md_tuple(ops, false));
        return ATR_CHANGED;
    }
    if !any return attach_callee_md(cb, e.all_known, skipped);
    if all {
        replace_all_uses_with(last_cmp, const_int(ir.t_i1, 1));
        erase_inst(last_cmp);
        u := new_inst(.UNREACHABLE, ir.t_void, 0);
        inst_insert_before(u, ip);
        drop_all_references(ip);
        erase_inst(ip);
    } else {
        clone := ic_clone_inst(cb);
        insert_before_named(clone, ip, vname(cb));
        array_add(*new_calls, .{clone, NONE});
        attach_callee_md(clone, e.all_known, skipped);
    }
    if !cb_is_void {
        phi := create_phi(vtype(cb), cast(u32) new_calls.count);
        insert_before_named(phi, block_first_insertion_pt(inst(cb).parent), tprint("%.phi", vname(cb)));
        for new_calls {
            ret := ifx it.ret != NONE then it.ret else it.c;
            if vtype(ret) == vtype(cb) phi_add_incoming(phi, ret, inst(ret).parent);
            else if vtype(it.c) == ir.t_void phi_add_incoming(phi, const_poison(vtype(cb)), inst(it.c).parent);
            else fatal("attributor: call return should match or be void");
        }
        atr_change_after_manifest(irp_cs_returned(cb), phi);
    }
    atr_delete_inst_after_manifest(cb);
    return ATR_CHANGED;
}
// Value::replaceNonMetadataUsesWith
replace_non_metadata_uses_with :: (v: Value_Id, nv: Value_Id) {
    us: [..] Use_Id; us.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { array_add(*us, u); u = ir.u_next[u]; }
    for us use_set(it, nv);
}

// isInstructionTriviallyDead(I) without a TargetLibraryInfo
atr_is_trivially_dead :: (i: Value_Id) -> bool { return !has_uses(i) && would_instruction_be_trivially_dead(i, false); }
// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts) (TLI = nullptr): every listed instruction is deleted
atr_recursively_delete_trivially_dead_instructions :: (dead: *[..] Value_Id) {
    while dead.count {
        i := pop(dead);
        if !atr_alive_inst(i) continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && atr_is_trivially_dead(o) array_add(dead, o);
        }
        erase_inst_with_metadata(i);
    }
}

// detachDeadBlocks(BBs, nullptr, false) keeping the debug records of the erased instructions (eraseFromParent moves
// them to the next instruction, finally to the new unreachable)
atr_detach_dead_blocks :: (bbs: [] Value_Id) {
    for bb: bbs {
        f := block_first_non_phi(bb);
        if f != NONE && (inst_op(f) == .CATCHPAD || inst_op(f) == .CLEANUPPAD) {
            rets: [..] Value_Id; rets.allocator = temp;
            u := ir.v_first_use[f];
            while u != NONE {
                user := ir.u_user[u];
                if is_inst(user) && (inst_op(user) == .CATCHRET || inst_op(user) == .CLEANUPRET) atr_set_insert(*rets, inst_block(user));
                u = ir.u_next[u];
            }
            for rets atr_empty_and_detach_block(it);
        }
        atr_empty_and_detach_block(bb);
    }
}
atr_empty_and_detach_block :: (bb: Value_Id) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs block_remove_predecessor(s, bb, false);
    recs: [..] u32; recs.allocator = temp;
    while block_last(bb) != NONE {
        i := block_last(bb);
        r := inst(i).records;
        inst(i).records = 0;
        if r != 0 array_add(*recs, r);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        erase_inst_with_metadata(i);
    }
    u := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(bb, u);
    for < recs attach_records_before(u, it);
}
