// WinEHPrepare: a port of llvm/lib/CodeGen/WinEHPrepare.cpp, the IR side that opt's "win-eh-prepare"
// (WinEHPreparePass) runs: removeUnreachableBlocks, colorFunclets, cloneCommonBlocks, demotePHIsOnFunclets
// (insertPHILoads / insertPHIStores / replaceUseWithLoad), removeImplausibleInstructions, cleanupPreparedFunclets.
// The EH state numbering (calculateWinCXXEHStateNumbers etc.) only feeds the MachineFunction and is not ported.
//
// Address order: cloneCommonBlocks rewrites the out-of-funclet uses of the cloned values while iterating the
// ValueToValueMapTy (a DenseMap keyed by pointer). With more than one value to rewrite the order of the SSAUpdater
// PHIs would depend on the heap, so that case fails loudly.

weh_cl: struct {
    disable_demotion: bool;          // -disable-demotion
    disable_cleanups: bool;          // -disable-cleanups
    demote_catchswitch_only: bool;   // -demote-catchswitch-only
};

weh_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    if name == {
        case "disable-demotion"; weh_cl.disable_demotion = pb(name, value, has_value);
        case "disable-cleanups"; weh_cl.disable_cleanups = pb(name, value, has_value);
        case "demote-catchswitch-only"; weh_cl.demote_catchswitch_only = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

Weh :: struct {
    f: Value_Id;
    personality: Eh_Personality;
    // BlockColors: DenseMap<BasicBlock *, ColorVector> (lookups only)
    color_idx: Table(Value_Id, s64);
    colors: [..] [..] Value_Id;
    // FuncletBlocks: MapVector<BasicBlock *, std::vector<BasicBlock *>>
    funclet_keys: [..] Value_Id;
    funclet_idx: Table(Value_Id, s64);
    funclet_blocks: [..] [..] Value_Id;
}

// BlockColors[BB] (creates an empty entry)
weh_colors :: (w: *Weh, bb: Value_Id) -> s64 {
    found, k := table_find(*w.color_idx, bb);
    if found return k;
    e: [..] Value_Id; e.allocator = temp;
    array_add(*w.colors, e);
    table_set(*w.color_idx, bb, w.colors.count - 1);
    return w.colors.count - 1;
}
// FuncletBlocks[Color]
weh_funclet :: (w: *Weh, pad: Value_Id) -> s64 {
    found, k := table_find(*w.funclet_idx, pad);
    if found return k;
    e: [..] Value_Id; e.allocator = temp;
    array_add(*w.funclet_blocks, e);
    array_add(*w.funclet_keys, pad);
    table_set(*w.funclet_idx, pad, w.funclet_blocks.count - 1);
    return w.funclet_blocks.count - 1;
}

win_eh_prepare_run :: (f: Value_Id) -> Preserved {
    if !glob(f).has_personality return PRESERVE_ALL;
    w: Weh;
    w.f = f;
    w.color_idx.allocator = temp; w.colors.allocator = temp;
    w.funclet_keys.allocator = temp; w.funclet_idx.allocator = temp; w.funclet_blocks.allocator = temp;
    w.personality = classify_eh_personality(fn_personality(f));
    if !is_scoped_eh_personality(w.personality) return PRESERVE_ALL;
    if weh_prepare_explicit_eh(*w) { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}

// WinEHPrepareImpl::colorFunclets
weh_color_funclets :: (w: *Weh) {
    t: Table(Value_Id, [..] Value_Id); t.allocator = temp;
    color_eh_funclets(w.f, *t);
    table_reset(*w.color_idx); w.colors.count = 0;
    table_reset(*w.funclet_idx); w.funclet_keys.count = 0; w.funclet_blocks.count = 0;
    for bb: fn_blocks(w.f) {
        k := weh_colors(w, bb);
        found, cv := table_find(*t, bb);
        if found for cv array_add(*w.colors[k], it);
        for c: w.colors[k] {
            fk := weh_funclet(w, c);
            array_add(*w.funclet_blocks[fk], bb);
        }
    }
}

// WinEHPrepareImpl::prepareExplicitEH
weh_prepare_explicit_eh :: (w: *Weh) -> bool {
    changed := remove_unreachable_blocks(w.f, null);
    weh_color_funclets(w);
    changed |= weh_clone_common_blocks(w);
    if !weh_cl.disable_demotion changed |= weh_demote_phis_on_funclets(w, weh_cl.demote_catchswitch_only);
    if !weh_cl.disable_cleanups {
        changed |= weh_remove_implausible_instructions(w);
        changed |= weh_cleanup_prepared_funclets(w);
    }
    return changed;
}

// CatchReturnInst::getCatchSwitchParentPad
weh_catchret_parent_pad :: (cr: Value_Id) -> Value_Id {
    cp := op(cr, 0);
    cs := op(cp, nops(cp) - 1);
    return op(cs, 0);
}

// WinEHPrepareImpl::cloneCommonBlocks
weh_clone_common_blocks :: (w: *Weh) -> bool {
    changed := false;
    f := w.f;
    for fi: 0..w.funclet_keys.count - 1 {
        pad_bb := w.funclet_keys[fi];
        token := ifx pad_bb == fn_entry(f) then const_token_none() else block_first_non_phi(pad_bb);

        Pair :: struct { old: Value_Id; new: Value_Id; }
        orig2clone: [..] Pair; orig2clone.allocator = temp;
        vm: Value_Map; vmap_init(*vm);
        cloned_insts: [..] Pair; cloned_insts.allocator = temp;   // the instruction entries of VMap, in clone order
        snapshot: [..] Value_Id; snapshot.allocator = temp;
        for w.funclet_blocks[fi] array_add(*snapshot, it);
        for bb: snapshot {
            if w.colors[weh_colors(w, bb)].count == 1 continue;
            before_count := cloned_insts.count;
            cbb := clone_basic_block(bb, *vm, tconcat(".for.", vname(pad_bb)), NONE, map_atoms = true);
            ci := block_first(cbb);
            for i: block_insts(bb) { array_add(*cloned_insts, .{i, ci}); ci = inst_next(ci); }
            fn_insert_detached_block_after(f, bb, cbb);
            vmap_set(*vm, bb, cbb);
            array_add(*orig2clone, .{bb, cbb});
        }
        if orig2clone.count == 0 continue;
        changed = true;

        for m: orig2clone {
            array_add(*w.funclet_blocks[fi], m.new);
            nk := weh_colors(w, m.new);
            array_add(*w.colors[nk], pad_bb);
            fb := *w.funclet_blocks[fi];
            for < k: 0..fb.count - 1 if fb.*[k] == m.old array_ordered_remove_by_index(fb, k);
            oc := *w.colors[weh_colors(w, m.old)];
            for < k: 0..oc.count - 1 if oc.*[k] == pad_bb array_ordered_remove_by_index(oc, k);
        }

        for bb: w.funclet_blocks[fi] for i: block_insts(bb)
            remap_instruction(*vm, i, RF_IGNORE_MISSING_LOCALS | RF_NO_MODULE_LEVEL_CHANGES);

        // catchrets targeting cloned blocks
        preds: [..] Value_Id; preds.allocator = temp;
        fixups: [..] Value_Id; fixups.allocator = temp;
        for m: orig2clone {
            fixups.count = 0;
            block_predecessors(m.old, *preds);
            for p: preds {
                t := block_terminator(p);
                if inst_op(t) == .CATCHRET && weh_catchret_parent_pad(t) == token array_add(*fixups, t);
            }
            for cr: fixups set_successor(cr, 0, m.new);
        }

        // UpdatePHIOnClonedBlock
        update_phi :: (w: *Weh, pn: Value_Id, is_old: bool, token: Value_Id, pad_bb: Value_Id) {
            n := nops(pn);
            rm := NewArray(n, bool,, temp);
            for k: 0..cast(s64) n - 1 {
                ib := phi_block(pn, cast(u32) k);
                t := block_terminator(ib);
                targets: bool;
                if inst_op(t) == .CATCHRET targets = weh_catchret_parent_pad(t) == token;
                else targets = w.colors[weh_colors(w, ib)][0] == pad_bb;
                rm[k] = is_old == targets;
            }
            phi_remove_incoming_if(pn, (p: Value_Id, idx: u32, data: *void) -> bool {
                return (cast(*bool) data)[idx];
            }, rm.data, false);
        }
        for m: orig2clone {
            for i: block_insts(m.old) { if inst_op(i) != .PHI break; update_phi(w, i, true, token, pad_bb); }
            for i: block_insts(m.new) { if inst_op(i) != .PHI break; update_phi(w, i, false, token, pad_bb); }
        }

        succs: [..] Value_Id; succs.allocator = temp;
        for m: orig2clone {
            block_successors(m.new, *succs);
            for sb: succs {
                for pn: block_insts(sb) {
                    if inst_op(pn) != .PHI break;
                    idx := phi_block_index(pn, m.old);
                    if idx == -1 break;
                    iv := phi_value(pn, cast(u32) idx);
                    if vkind(iv) == .INST {
                        found, nv := vmap_find(*vm, iv);
                        if found iv = nv;
                    }
                    phi_add_incoming(pn, iv, m.new);
                }
            }
        }

        // uses of cloned values outside the funclet: an SSAUpdater per value, in VMap order (= heap order). The
        // result only depends on that order when two values get PHIs (name suffixes come from one counter, PHIs
        // go to the front of their block); that case fails loudly below.
        uses: [..] Use_Id; uses.allocator = temp;
        phi_owners: [..] Value_Id; phi_owners.allocator = temp;   // per inserted PHI: the value it was made for
        all_phis: [..] Value_Id; all_phis.allocator = temp;
        for c: cloned_insts {
            old_i := c.old;
            uses.count = 0;
            u := ir.v_first_use[old_i];
            while u != NONE {
                user_bb := inst_block(ir.u_user[u]);
                cv := w.colors[weh_colors(w, user_bb)];
                if cv.count > 1 || cv[0] != pad_bb array_add(*uses, u);
                u = ir.u_next[u];
            }
            if uses.count == 0 continue;
            s: Ssa_Updater;
            ssa_init(*s, vtype(old_i), vname(old_i));
            s.inserted_phis = *all_phis;
            ssa_add_available(*s, inst_block(old_i), old_i);
            ssa_add_available(*s, inst_block(c.new), c.new);
            while uses.count {
                uu := pop(*uses);
                // SSAUpdater::RewriteUseAfterInsertions
                user := ir.u_user[uu];
                v: Value_Id;
                if inst_op(user) == .PHI v = ssa_value_at_end(*s, ir.u_aux[uu]);
                else v = ssa_value_at_end(*s, inst_block(user));
                use_set(uu, v);
            }
            while phi_owners.count < all_phis.count array_add(*phi_owners, old_i);
        }
        for pi: 0..all_phis.count - 1 for qi: 0..all_phis.count - 1 {
            if phi_owners[pi] == phi_owners[qi] continue;
            if vname(phi_owners[pi]).count || vname(phi_owners[qi]).count || inst_block(all_phis[pi]) == inst_block(all_phis[qi])
                fatal("win-eh-prepare: SSAUpdater PHIs for more than one cloned value; LLVM makes them in ValueToValueMapTy (pointer) order, which depends on heap addresses");
        }
    }
    return changed;
}

// WinEHPrepareImpl::demotePHIsOnFunclets
weh_demote_phis_on_funclets :: (w: *Weh, catchswitch_only: bool) -> bool {
    changed := false;
    phis: [..] Value_Id; phis.allocator = temp;
    bb_next := fn_entry(w.f);
    while bb_next != NONE {
        bb := bb_next;
        bb_next = block(bb).next;
        if !block_is_eh_pad(bb) continue;
        for :early_inc pn: block_insts(bb) {
            if inst_op(pn) != .PHI break;
            if catchswitch_only {
                is_cs_bb := inst_op(block_first_non_phi(bb)) == .CATCHSWITCH;
                has_incoming_cs := false;
                for k: 0..cast(s64) nops(pn) - 1 {
                    fnp := block_first_non_phi(phi_block(pn, cast(u32) k));
                    if fnp != NONE && inst_op(fnp) == .CATCHSWITCH { has_incoming_cs = true; break; }
                }
                if !is_cs_bb && !has_incoming_cs break;
            }
            changed = true;
            slot := weh_insert_phi_loads(w, pn);
            if slot != NONE weh_insert_phi_stores(w, pn, slot);
            array_add(*phis, pn);
        }
    }
    for pn: phis {
        replace_all_uses_with(pn, const_poison(vtype(pn)));
        erase_inst_with_metadata(pn);
    }
    return changed;
}

// new AllocaInst(Ty, DL->getAllocaAddrSpace(), nullptr, Name, F.getEntryBlock().begin())
weh_new_spill_slot :: (w: *Weh, ty: Type_Id, name: string) -> Value_Id {
    a := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
    set_op(a, 0, const_int(ir.t_i32, 1));
    inst(a).ty2 = ty;
    inst(a).addrspace = dl.alloca_as;
    inst(a).align = dl_pref_align(ty);
    entry := fn_entry(w.f);
    insert_at_position(a, entry, block_first(entry), true);
    set_name(a, tconcat(name, ".wineh.spillslot"));
    return a;
}
// new LoadInst(Ty, Ptr, Name, InsertBefore)
weh_new_load :: (ty: Type_Id, ptr: Value_Id, name: string, bb: Value_Id, pt: Value_Id, head: bool) -> Value_Id {
    l := new_inst(.LOAD, ty, 1);
    set_op(l, 0, ptr);
    inst(l).align = dl_abi_align(ty);
    insert_at_position(l, bb, pt, head);
    set_name(l, tconcat(name, ".wineh.reload"));
    return l;
}

// WinEHPrepareImpl::insertPHILoads
weh_insert_phi_loads :: (w: *Weh, pn: Value_Id) -> Value_Id {
    phi_bb := inst_block(pn);
    ehpad := block_first_non_phi(phi_bb);
    if !is_terminator(inst_op(ehpad)) {
        slot := weh_new_spill_slot(w, vtype(pn), vname(pn));
        v := weh_new_load(vtype(pn), slot, vname(pn), phi_bb, block_first_insertion_pt(phi_bb), true);
        replace_all_uses_with(pn, v);
        return slot;
    }
    slot: Value_Id = NONE;
    Load :: struct { bb: Value_Id; v: Value_Id; }
    loads: [..] Load; loads.allocator = temp;
    u := ir.v_first_use[pn];
    while u != NONE {
        nx := ir.u_next[u];
        user := ir.u_user[u];
        if !(inst_op(user) == .PHI && block_is_eh_pad(inst_block(user))) weh_replace_use_with_load(w, pn, u, *slot, *loads);
        u = nx;
    }
    return slot;
}

// WinEHPrepareImpl::insertPHIStores / insertPHIStore
weh_insert_phi_stores :: (w: *Weh, orig: Value_Id, slot: Value_Id) {
    Item :: struct { bb: Value_Id; v: Value_Id; }
    wl: [..] Item; wl.allocator = temp;
    array_add(*wl, .{inst_block(orig), orig});
    insert_store :: (pred: Value_Id, v: Value_Id, slot: Value_Id, wl: *[..] Item) {
        if block_is_eh_pad(pred) && is_terminator(inst_op(block_first_non_phi(pred))) {
            array_add(wl, .{pred, v});
            return;
        }
        s := new_inst(.STORE, ir.t_void, 2);
        set_op(s, 0, v); set_op(s, 1, slot);
        inst(s).align = dl_abi_align(vtype(v));
        t := block_terminator(pred);
        insert_at_position(s, pred, t, false);
    }
    preds: [..] Value_Id; preds.allocator = temp;
    while wl.count {
        item := pop(*wl);
        pn := item.v;
        if vkind(pn) == .INST && inst_op(pn) == .PHI && inst_block(pn) == item.bb {
            for k: 0..cast(s64) nops(pn) - 1 {
                pv := phi_value(pn, cast(u32) k);
                if vkind(pv) == .C_UNDEF || vkind(pv) == .C_POISON continue;
                insert_store(phi_block(pn, cast(u32) k), pv, slot, *wl);
            }
        } else {
            block_predecessors(item.bb, *preds);
            for p: preds insert_store(p, item.v, slot, *wl);
        }
    }
}

// WinEHPrepareImpl::replaceUseWithLoad
weh_replace_use_with_load :: (w: *Weh, v: Value_Id, u: Use_Id, slot: *Value_Id, loads: *[..] $L) {
    if slot.* == NONE slot.* = weh_new_spill_slot(w, vtype(v), vname(v));
    user := ir.u_user[u];
    if inst_op(user) == .PHI {
        incoming := ir.u_aux[u];
        cr := block_terminator(incoming);
        if inst_op(cr) == .CATCHRET {
            phi_bb := inst_block(user);
            nb := split_edge(incoming, phi_bb, null, null);
            go := block_terminator(incoming);
            assert(inst_op(go) == .BR && nops(go) == 1);
            inst_unlink(go);
            inst_unlink(cr);
            block_append_inst(incoming, cr);
            block_append_inst(nb, go);
            set_successor(go, 0, phi_bb);
            set_successor(cr, 0, nb);
            nk := weh_colors(w, nb);
            pk := weh_colors(w, phi_bb);
            w.colors[nk].count = 0;
            for w.colors[pk] array_add(*w.colors[nk], it);
            for c: w.colors[pk] array_add(*w.funclet_blocks[weh_funclet(w, c)], nb);
            incoming = nb;
        }
        ld: Value_Id = NONE;
        for loads.* if it.bb == incoming { ld = it.v; break; }
        if ld == NONE {
            t := block_terminator(incoming);
            ld = weh_new_load(vtype(v), slot.*, vname(v), incoming, t, false);
            array_add(loads, .{incoming, ld});
        }
        use_set(u, ld);
    } else {
        ld := weh_new_load(vtype(v), slot.*, vname(v), inst_block(user), user, false);
        use_set(u, ld);
    }
}

// WinEHPrepareImpl::removeImplausibleInstructions
weh_remove_implausible_instructions :: (w: *Weh) -> bool {
    changed := false;
    for fi: 0..w.funclet_keys.count - 1 {
        pad_bb := w.funclet_keys[fi];
        first := block_first_non_phi(pad_bb);
        fop := inst_op(first);
        funclet_pad := ifx fop == .CATCHPAD || fop == .CLEANUPPAD then first else NONE;
        catch_pad := ifx fop == .CATCHPAD then first else NONE;
        cleanup_pad := ifx fop == .CLEANUPPAD then first else NONE;
        for bb: w.funclet_blocks[fi] {
            for i: block_insts(bb) {
                if !is_call_base(i) continue;
                bundle_op: Value_Id = NONE;
                bk := call_bundle_index(i, "funclet");
                if bk >= 0 { b, e := call_bundle_range(i, cast(u32) bk); bundle_op = op(i, b); }
                if bundle_op == funclet_pad continue;
                callee := strip_pointer_casts(call_callee(i));
                if vkind(call_callee(i)) == .INLINE_ASM ||
                   (vkind(callee) == .FUNCTION && glob(callee).intrinsic && call_does_not_throw(i)) continue;
                changed = true;
                if inst_op(i) == .INVOKE {
                    remove_unwind_edge(bb, null);
                    ci := inst_prev(block_terminator(bb));
                    change_to_unreachable(ci, false, null);
                } else {
                    change_to_unreachable(i, false, null);
                }
                break;
            }
            ti := block_terminator(bb);
            top := inst_op(ti);
            unreachable_ret := top == .RET && funclet_pad != NONE;
            unreachable_catchret := top == .CATCHRET && op(ti, 0) != catch_pad;
            unreachable_cleanupret := top == .CLEANUPRET && op(ti, 0) != cleanup_pad;
            if unreachable_ret || unreachable_catchret || unreachable_cleanupret {
                changed = true;
                change_to_unreachable(ti, false, null);
            } else if top == .INVOKE {
                if w.personality == .MSVC_CXX && cleanup_pad != NONE {
                    changed = true;
                    remove_unwind_edge(bb, null);
                }
            }
        }
    }
    return changed;
}

// WinEHPrepareImpl::cleanupPreparedFunclets
weh_cleanup_prepared_funclets :: (w: *Weh) -> bool {
    changed := false;
    bb := fn_entry(w.f);
    while bb != NONE {
        nx := block(bb).next;
        changed |= simplify_instructions_in_block(bb, false);
        changed |= constant_fold_terminator(bb, true, null);
        changed |= merge_block_into_predecessor(bb, null, null, null);
        bb = nx;
    }
    changed |= remove_unreachable_blocks(w.f, null);
    return changed;
}
