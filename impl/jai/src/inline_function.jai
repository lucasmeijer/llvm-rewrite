// Inlining a call site: a port of llvm/lib/Transforms/Utils/InlineFunction.cpp (InlineFunction, CanInlineCallSite,
// InlineFunctionImpl and its helpers: LandingPadInliningInfo, getUnwindDestToken(Helper),
// HandleCallsInBlockInlinedThroughInvoke, HandleInlinedLandingPad, HandleInlinedEHPad, PropagateCallSiteMetadata,
// PropagateInlinedFromMetadata, PropagateOperandBundles, ScopedAliasMetadataDeepCloner, AddAliasScopeMetadata,
// AddParamAndFnBasicAttributes, AddReturnAttributes, AddAlignmentAssumptions, HandleByValArgument(Init),
// hasLifetimeMarkers, allocaWouldBeStaticInEntry, inlineDebugLoc, fixupLineNumbers, updateCallerBFI,
// propagateAllocTokenMetadata), of PruningFunctionCloner / CloneAndPruneIntoFromInst / CloneAndPruneFunctionInto
// from llvm/lib/Transforms/Utils/CloneFunction.cpp, of changeToInvokeAndSplitBasicBlock (Local.cpp),
// DebugLoc::appendInlinedAt (DebugLoc.cpp), updateLoopMetadataDebugLocations (DebugInfo.cpp) and
// AttributeFuncs::areInlineCompatible / mergeAttributesForInlining (Attributes.cpp with the Attributes.td rules).
//
// The ValueToValueMapTy of the inliner is a tracking Value_Map (value_mapper.jai): its values follow RAUW and become
// NONE when erased, like WeakTrackingVH. ClonedCodeInfo::OperandBundleCallSites (WeakTrackingVHs) is another
// tracking map keyed by the original call.
//
// Also updateCallProfile / updateProfileCallee (ProfileSummaryInfo in psi.jai), scaleProfData (ProfDataUtils.cpp),
// PGOIndirectCallVisitor::tryGetVTableInstruction and Function::setEntryCount.
//
// Not ported (fail loudly when reached): memprof metadata (!memprof / !callsite) propagation, assignment tracking
// (DIAssignID), strictfp hosts
// (constrained-intrinsic cloning), ObjC ARC attached calls (inlineRetainOrClaimRVCalls), PGO contextual profiles.

if_opts: struct {
    enable_noalias_to_md_conversion := true;       // -enable-noalias-to-md-conversion
    use_noalias_intrinsic := true;                 // -use-noalias-intrinsic-during-inlining
    preserve_alignment_assumptions := false;       // -preserve-alignment-assumptions-during-inlining
    attribute_window: s64 = 4;                     // -max-inst-checked-for-throw-during-inlining
};

// ClonedCodeInfo
Cloned_Code_Info :: struct {
    contains_calls: bool;
    contains_memprof: bool;
    contains_dynamic_allocas: bool;
    orig_vmap: Table(Value_Id, Value_Id);   // OrigVMap (plain pointers)
    bundle_calls: Value_Map;                 // OperandBundleCallSites as a tracking map: original call -> clone
    bundle_order: [..] Value_Id;             // ... in push order
    originally_indirect: [..] Value_Id;      // OriginallyIndirectCalls (SmallSetVector of the clones)
}
cci_init :: (c: *Cloned_Code_Info) {
    c.orig_vmap.allocator = temp; c.bundle_order.allocator = temp; c.originally_indirect.allocator = temp;
    vmap_init(*c.bundle_calls);
    vmap_track_begin(*c.bundle_calls);
}
cci_done :: (c: *Cloned_Code_Info) { vmap_track_end(*c.bundle_calls); }
cci_is_simplified :: (c: *Cloned_Code_Info, from: Value_Id, to: Value_Id) -> bool {
    found, v := table_find(*c.orig_vmap, from);
    return (ifx found then v else NONE) != to;
}
cci_indirect_contains :: (c: *Cloned_Code_Info, v: Value_Id) -> bool { for c.originally_indirect if it == v return true; return false; }
cci_indirect_remove :: (c: *Cloned_Code_Info, v: Value_Id) -> bool {
    for c.originally_indirect if it == v { array_ordered_remove_by_index(*c.originally_indirect, it_index); return true; }
    return false;
}
cci_indirect_insert :: (c: *Cloned_Code_Info, v: Value_Id) { if !cci_indirect_contains(c, v) array_add(*c.originally_indirect, v); }

// InlineFunctionInfo
Inline_Function_Info :: struct {
    use_assumption_cache: bool;   // GetAssumptionCache given
    psi: *Psi;
    caller_bfi: *Bfi;
    callee_bfi: *Bfi;
    update_profile := true;
    static_allocas: [..] Value_Id;
    inlined_call_sites: [..] Value_Id;
    convergence_control_token: Value_Id = NONE;
    call_site_eh_pad: Value_Id = NONE;
}
ifi_reset :: (ifi: *Inline_Function_Info) {
    ifi.static_allocas.allocator = temp; ifi.static_allocas.count = 0;
    ifi.inlined_call_sites.allocator = temp; ifi.inlined_call_sites.count = 0;
    ifi.convergence_control_token = NONE;
    ifi.call_site_eh_pad = NONE;
}

// InlineResult: an empty reason is success
Inline_Result :: struct { ok: bool; reason: string; }
ir_success :: () -> Inline_Result { return .{true, ""}; }
ir_failure :: (r: string) -> Inline_Result { return .{false, r}; }

// ---------------------------------------------------------------- small IR helpers

// BasicBlock::replaceAllUsesWith(New) (Value::doRAUW for a block: uses, then the successors' phis)
block_rauw :: (old: Value_Id, new: Value_Id) {
    replace_all_uses_with(old, new);
    block_replace_successors_phi_uses_with(old, old, new);
}
// BasicBlock::hasAddressTaken: a blockaddress uses the block
block_has_address_taken_any :: (b: Value_Id) -> bool {
    u := ir.v_first_use[b];
    while u != NONE { if vkind(ir.u_user[u]) == .C_BLOCKADDR return true; u = ir.u_next[u]; }
    return false;
}
// CallBase::getOperandBundle(tag): the bundle index or -1
call_bundle_index :: (c: Value_Id, tag: string) -> s64 {
    n := call_num_bundles(c);
    for k: 0..cast(s64) n - 1 if call_bundle_tag(c, cast(u32) k) == tag return k;
    return -1;
}
// CallBase::setDoesNotThrow
call_set_does_not_throw :: (c: Value_Id) {
    l := inst(c).attrs;
    a: Attr; a.kind = .NoUnwind; a.ty = NONE;
    inst(c).attrs = attr_list_with_fn(l, attr_set_with(attr_list_fn(l), a));
}
// ---------------------------------------------------------------- CloneFunction.cpp: pruning cloner

Pruning_Cloner :: struct {
    new_fn: Value_Id;
    old_fn: Value_Id;
    vm: *Value_Map;
    suffix: string;
    info: *Cloned_Code_Info;
    host_strictfp: bool;
}

// PruningFunctionCloner::CloneBlock
pfc_clone_block :: (p: *Pruning_Cloner, bb: Value_Id, starting: Value_Id, to_clone: *[..] Value_Id) {
    existing := vmap_lookup(p.vm, bb);
    if existing != NONE return;
    nb := create_block(p.new_fn, "");
    if vname(bb).count set_name(nb, tconcat(vname(bb), p.suffix));
    vmap_set(p.vm, bb, nb);
    if block_has_address_taken_any(bb) {
        old_ba := const_blockaddr(p.old_fn, bb);
        vmap_set(p.vm, old_ba, const_blockaddr(p.new_fn, nb));
    }
    has_calls := false; has_dynamic := false; has_static := false; has_memprof := false;
    dbg_cursor := starting;
    clone_dbg_to_here :: (nw: Value_Id, ii: Value_Id, cursor: *Value_Id) {
        recs: [..] u32; recs.allocator = temp;
        while cursor.* != ii {
            c := cursor.*;
            if inst(c).records clone_debug_info_from(nw, c, inst(c).records, *recs);
            cursor.* = inst(c).next;
        }
        if inst(ii).records clone_debug_info_from(nw, ii, inst(ii).records, *recs);
        cursor.* = inst(ii).next;
    }
    term := block_terminator(bb);
    ii := starting;
    while ii != NONE && ii != term {
        nx := inst(ii).next;
        defer ii = nx;
        if call_iid(ii) == IID_FAKE_USE continue;
        if p.host_strictfp fatal("inline: inlining into a strictfp function (constrained intrinsics) is not implemented yet");
        nw := inst_clone(ii);
        block_append_inst(nb, nw);
        if inst_op(nw) != .PHI {
            remap_instruction(p.vm, nw, RF_NO_MODULE_LEVEL_CHANGES);
            v := cfo_instruction(nw);
            if v != NONE && is_instruction_trivially_dead(nw) {
                vmap_set(p.vm, ii, v);
                erase_inst(nw);
                continue;
            }
        }
        if is_call_base(ii) && call_is_indirect(ii) cci_indirect_insert(p.info, nw);
        if vname(ii).count set_name(nw, tconcat(vname(ii), p.suffix));
        vmap_set(p.vm, ii, nw);
        if inst_op(ii) == .CALL && !is_debug_or_pseudo_inst(ii) {
            has_calls = true;
            has_memprof |= get_metadata(ii, md_fixed("memprof")) != NONE;
            has_memprof |= get_metadata(ii, md_fixed("callsite")) != NONE;
        }
        clone_dbg_to_here(nw, ii, *dbg_cursor);
        table_set(*p.info.orig_vmap, ii, nw);
        if is_call_base(ii) && call_num_bundles(ii) > 0 { vmap_set(*p.info.bundle_calls, ii, nw); array_add(*p.info.bundle_order, ii); }
        if inst_op(ii) == .ALLOCA {
            if vkind(op(ii, 0)) == .C_INT has_static = true; else has_dynamic = true;
        }
    }
    old_ti := term;
    done := false;
    if inst_op(old_ti) == .CONDBR {
        cond := op(old_ti, 0);
        c: Value_Id = NONE;
        if vkind(cond) == .C_INT c = cond;
        if c == NONE {
            v := vmap_lookup(p.vm, cond);
            if v != NONE && vkind(v) == .C_INT c = v;
        }
        if c != NONE {
            dest := get_successor(old_ti, ifx is_null_value(c) then cast(u32) 1 else 0);
            nbi := create_br(dest);
            block_append_inst(nb, nbi);
            copy_debug_loc(nbi, old_ti);
            vmap_set(p.vm, old_ti, nbi);
            array_add(to_clone, dest);
            done = true;
        }
    } else if inst_op(old_ti) == .SWITCH {
        cond := op(old_ti, 0);
        c: Value_Id = NONE;
        if vkind(cond) == .C_INT c = cond;
        if c == NONE {
            v := vmap_lookup(p.vm, cond);
            if v != NONE && vkind(v) == .C_INT c = v;
        }
        if c != NONE {
            dest := switch_find_case_dest(old_ti, c);
            nbi := create_br(dest);
            block_append_inst(nb, nbi);
            copy_debug_loc(nbi, old_ti);
            vmap_set(p.vm, old_ti, nbi);
            array_add(to_clone, dest);
            done = true;
        }
    }
    if !done {
        nw := inst_clone(old_ti);
        if vname(old_ti).count set_name_unlinked(nw, tconcat(vname(old_ti), p.suffix));
        block_append_inst(nb, nw);
        if vname(nw).count ic_reinsert_name(nw);
        clone_dbg_to_here(nw, old_ti, *dbg_cursor);
        vmap_set(p.vm, old_ti, nw);
        table_set(*p.info.orig_vmap, old_ti, nw);
        if is_call_base(old_ti) && call_num_bundles(old_ti) > 0 { vmap_set(*p.info.bundle_calls, old_ti, nw); array_add(*p.info.bundle_order, old_ti); }
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for succs array_add(to_clone, it);
    } else {
        clone_dbg_to_here(block_terminator(nb), old_ti, *dbg_cursor);
    }
    p.info.contains_calls |= has_calls;
    p.info.contains_memprof |= has_memprof;
    p.info.contains_dynamic_allocas |= has_dynamic;
    p.info.contains_dynamic_allocas |= has_static && bb != fn_entry(block_fn(bb));
}
// setName on an unlinked instruction (stored; the symbol table sees it when linked)
set_name_unlinked :: (i: Value_Id, n: string) { ir.v_name[i] = intern_str(n); }
// CloneAndPruneIntoFromInst(NewFunc, OldFunc, StartingInst = entry, VMap, ModuleLevelChanges = false, Returns, Suffix,
// CodeInfo)
clone_and_prune_function_into :: (new_fn: Value_Id, old_fn: Value_Id, vm: *Value_Map, returns: *[..] Value_Id, suffix: string, info: *Cloned_Code_Info) {
    p: Pruning_Cloner;
    p.new_fn = new_fn; p.old_fn = old_fn; p.vm = vm; p.suffix = suffix; p.info = info;
    p.host_strictfp = fn_has_fn_attr(new_fn, .StrictFP);
    starting_bb := fn_entry(old_fn);
    starting_inst := block_first(starting_bb);
    work: [..] Value_Id; work.allocator = temp;
    pfc_clone_block(*p, starting_bb, starting_inst, *work);
    while work.count {
        bb := pop(*work);
        pfc_clone_block(*p, bb, block_first(bb), *work);
    }
    phi_to_resolve: [..] Value_Id; phi_to_resolve.allocator = temp;
    old_blocks: [..] Value_Id; old_blocks.allocator = temp;
    for b: fn_blocks(old_fn) array_add(*old_blocks, b);
    for bi: old_blocks {
        v := vmap_lookup(vm, bi);
        if v == NONE || vkind(v) != .BLOCK continue;
        nb := v;
        // NewBB->moveBefore(NewFunc->end())
        fn_unlink_block(new_fn, nb);
        fn_append_block(new_fn, nb);
        for pn: block_insts(bi) {
            if inst_op(pn) != .PHI break;
            mv := vmap_lookup(vm, pn);
            if mv != NONE && vkind(mv) == .INST && inst_op(mv) == .PHI array_add(*phi_to_resolve, pn);
            else break;
        }
        remap_instruction(vm, block_terminator(nb), RF_NO_MODULE_LEVEL_CHANGES);
    }
    phino := 0;
    while phino < phi_to_resolve.count {
        opn := phi_to_resolve[phino];
        num_preds := nops(opn);
        old_bb := inst_block(opn);
        nb := vmap_lookup(vm, old_bb);
        while phino < phi_to_resolve.count && inst_block(phi_to_resolve[phino]) == old_bb {
            opn = phi_to_resolve[phino];
            pn := vmap_lookup(vm, opn);
            pred := cast(s64) num_preds - 1;
            while pred >= 0 {
                defer pred -= 1;
                mb := vmap_lookup(vm, phi_block(pn, cast(u32) pred));
                if mb != NONE && vkind(mb) == .BLOCK {
                    inval := map_value(vm, op(pn, cast(u32) pred), RF_NO_MODULE_LEVEL_CHANGES);
                    set_op(pn, cast(u32) pred, inval);
                    phi_set_block(pn, cast(u32) pred, mb);
                    continue;
                }
                phi_remove_incoming(pn, cast(u32) pred, false);
            }
            phino += 1;
        }
        pn := block_first(nb);
        npreds := block_num_predecessors(nb);
        if npreds != nops(pn) {
            pred_count: Table(Value_Id, s64); pred_count.allocator = temp;
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(nb, *preds);
            for preds { c := table_find_pointer(*pred_count, it); if c c.* += 1; else table_set(*pred_count, it, 1); }
            x := block_first(nb);
            while x != NONE && inst_op(x) == .PHI {
                seen: Table(Value_Id, s64); seen.allocator = temp;
                // removeIncomingValueIf(pred, DeletePHIIfEmpty = false): backwards, each removal moves the last entry
                // into the hole (so the predicate sees every original entry once, in decreasing index order)
                n := cast(s64) nops(x);
                idx := n;
                while idx > 0 {
                    idx -= 1;
                    ib := phi_block(x, cast(u32) idx);
                    pc := table_find_pointer(*pred_count, ib);
                    rm := true;
                    if pc {
                        sp := table_find_pointer(*seen, ib);
                        sc: s64 = ifx sp then sp.* else 0;
                        if sc < pc.* { table_set(*seen, ib, sc + 1); rm = false; }
                    }
                    if !rm {
                        continue;
                    }
                    last := n - 1;
                    if idx != last {
                        set_op(x, cast(u32) idx, op(x, cast(u32) last));
                        ir.u_aux[ir.v_ops[x] + cast(u32) idx] = ir.u_aux[ir.v_ops[x] + cast(u32) last];
                    }
                    set_op(x, cast(u32) last, NONE);
                    ir.u_aux[ir.v_ops[x] + cast(u32) last] = NONE;
                    n -= 1;
                }
                ir.v_nops[x] = cast(u32) n;

                x = inst(x).next;
            }
        }
        pn = block_first(nb);
        if nops(pn) == 0 {
            x := block_first(nb);
            oi := block_first(old_bb);
            while x != NONE && inst_op(x) == .PHI {
                nxt := inst(x).next;
                nv := const_poison(vtype(x));
                replace_all_uses_with(x, nv);
                vmap_set(vm, oi, nv);
                erase_inst(x);
                oi = inst(oi).next;
                x = nxt;
            }
        }
    }
    // drop return attributes incompatible with the callee's return type while simplifying
    attrs := glob(new_fn).attrs;
    incompatible_ret := attr_set_type_incompatible(fn_ret_type(old_fn), attr_list_ret(attrs));
    if incompatible_ret != attr_list_ret(attrs) {
        ps := ifx attrs == 0 then .[] else ir.attr_lists[attrs].params;
        glob(new_fn).attrs = attr_list_get(attr_list_fn(attrs), incompatible_ret, ps);
    }
    q: Simplify_Query; q.have_tli = false;
    for bb: old_blocks for i: block_insts(bb) {
        ni := vmap_lookup(vm, i);
        if ni == NONE || vkind(ni) != .INST continue;
        v := simplify_instruction(ni, q);
        if v != NONE {
            replace_all_uses_with(ni, v);
            if is_instruction_trivially_dead(ni) erase_inst(ni);
            else vmap_set(vm, i, ni);
        }
    }
    glob(new_fn).attrs = attrs;
    begin := vmap_lookup(vm, starting_bb);
    b := begin;
    while b != NONE {
        for i: block_insts(b) remap_dbg_record_range(vm, i, RF_NO_MODULE_LEVEL_CHANGES);
        b = block(b).next;
    }
    b = begin;
    while b != NONE {
        nxt := block(b).next;
        constant_fold_terminator(b, false, null);
        b = nxt;
    }
    {
        reachable: Table(Value_Id, bool); reachable.allocator = temp;
        wl: [..] Value_Id; wl.allocator = temp;
        array_add(*wl, begin);
        succs: [..] Value_Id; succs.allocator = temp;
        while wl.count {
            x := pop(*wl);
            if table_contains(*reachable, x) continue;
            table_set(*reachable, x, true);
            block_successors(x, *succs);
            for succs array_add(*wl, it);
        }
        unreachable: [..] Value_Id; unreachable.allocator = temp;
        b = begin;
        while b != NONE { if !table_contains(*reachable, b) array_add(*unreachable, b); b = block(b).next; }
        if unreachable.count delete_dead_blocks(unreachable, null);
    }
    i := begin;
    while i != NONE {
        t := block_terminator(i);
        if inst_op(t) != .BR { i = block(i).next; continue; }
        dest := get_successor(t, 0);
        if block_single_predecessor(dest) == NONE || block_has_address_taken_any(dest) { i = block(i).next; continue; }
        // BI->eraseFromParent(): its records become the block's trailing records, which the splice at end()
        // then puts in front of Dest's first instruction
        trailing := records_take(t);
        erase_inst(t);
        block_rauw(dest, i);
        // I->splice(I->end(), Dest)
        dfirst := block_first(dest);
        block_move_all_insts_to_end(i, dest);
        if trailing records_prepend(dfirst, trailing);
        block_erase_from_parent(dest);
    }
    i = begin;
    while i != NONE {
        t := block_terminator(i);
        if t != NONE && inst_op(t) == .RET array_add(returns, t);
        i = block(i).next;
    }
}
// removeRetAttrs(AttributeFuncs::typeIncompatible(Ty, AS)) on a return attribute set
attr_set_type_incompatible :: (ty: Type_Id, s: u32) -> u32 {
    if s == 0 return 0;
    kinds: [..] Attr_Kind; kinds.allocator = temp;
    ic_type_incompatible(ty, s, ASK_ALL, *kinds);
    return attr_set_remove_kinds(s, kinds);
}

// ---------------------------------------------------------------- EH handling

// LandingPadInliningInfo
Lpad_Info :: struct {
    outer_resume_dest: Value_Id;
    inner_resume_dest: Value_Id = NONE;
    caller_lpad: Value_Id;
    inner_eh_values_phi: Value_Id = NONE;
    unwind_dest_phi_values: [..] Value_Id;
}
lpi_init :: (l: *Lpad_Info, ii: Value_Id) {
    l.outer_resume_dest = invoke_unwind_dest(ii);
    l.unwind_dest_phi_values.allocator = temp;
    invoke_bb := inst_block(ii);
    x := block_first(l.outer_resume_dest);
    while inst_op(x) == .PHI {
        array_add(*l.unwind_dest_phi_values, phi_incoming_value_for_block(x, invoke_bb));
        x = inst(x).next;
    }
    l.caller_lpad = x;
}
lpi_add_incoming_phi_values_for_into :: (l: *Lpad_Info, src: Value_Id, dest: Value_Id) {
    x := block_first(dest);
    for v: l.unwind_dest_phi_values {
        phi_add_incoming(x, v, src);
        x = inst(x).next;
    }
}
// getInnerResumeDest
lpi_get_inner_resume_dest :: (l: *Lpad_Info) -> Value_Id {
    if l.inner_resume_dest != NONE return l.inner_resume_dest;
    split_point := inst(l.caller_lpad).next;
    l.inner_resume_dest = split_basic_block(l.outer_resume_dest, split_point, tconcat(vname(l.outer_resume_dest), ".body"));
    insert_point := block_first(l.inner_resume_dest);
    x := block_first(l.outer_resume_dest);
    for 0..l.unwind_dest_phi_values.count-1 {
        outer := x;
        inner := create_phi(vtype(outer), 2);
        inst_insert_before(inner, insert_point);
        set_name(inner, tconcat(vname(outer), ".lpad-body"));
        replace_all_uses_with(outer, inner);
        phi_add_incoming(inner, outer, l.outer_resume_dest);
        x = inst(x).next;
    }
    l.inner_eh_values_phi = create_phi(vtype(l.caller_lpad), 2);
    inst_insert_before(l.inner_eh_values_phi, insert_point);
    set_name(l.inner_eh_values_phi, "eh.lpad-body");
    replace_all_uses_with(l.caller_lpad, l.inner_eh_values_phi);
    phi_add_incoming(l.inner_eh_values_phi, l.caller_lpad, l.outer_resume_dest);
    return l.inner_resume_dest;
}
// forwardResume
lpi_forward_resume :: (l: *Lpad_Info, ri: Value_Id) {
    dest := lpi_get_inner_resume_dest(l);
    src := inst_block(ri);
    bi := create_br(dest);
    block_append_inst(src, bi);
    copy_debug_loc(bi, ri);
    lpi_add_incoming_phi_values_for_into(l, src, dest);
    phi_add_incoming(l.inner_eh_values_phi, op(ri, 0), src);
    erase_inst(ri);
}

// getParentPad
// getParentPad: operand 0 of a catchswitch, the last operand of a catchpad / cleanuppad (FuncletPadInst)
eh_parent_pad :: (pad: Value_Id) -> Value_Id { if inst_op(pad) == .CATCHSWITCH return op(pad, 0); return op(pad, nops(pad) - 1); }

Unwind_Memo :: struct { map: Table(Value_Id, Value_Id); }   // DenseMap<Instruction *, Value *>; NONE = nullptr
um_find :: (m: *Unwind_Memo, k: Value_Id) -> (bool, Value_Id) { f, v := table_find(*m.map, k); return f, v; }
um_set :: (m: *Unwind_Memo, k: Value_Id, v: Value_Id) { table_set(*m.map, k, v); }
is_token_none :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_TOKEN_NONE; }
token_none :: () -> Value_Id { return const_token_none(); }

// getUnwindDestTokenHelper
get_unwind_dest_token_helper :: (eh_pad: Value_Id, memo: *Unwind_Memo) -> Value_Id {
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, eh_pad);
    while worklist.count {
        cur := pop(*worklist);
        token: Value_Id = NONE;
        if inst_op(cur) == .CATCHSWITCH {
            if (inst(cur).flags & F_HAS_UNWIND) != 0 {
                token = block_first_non_phi(catchswitch_unwind_dest(cur));
            } else {
                for hb: catchswitch_handlers(cur) {
                    if token != NONE break;
                    catch_pad := block_first_non_phi(hb);
                    u := ir.v_first_use[catch_pad];
                    while u != NONE {
                        child := ir.u_user[u];
                        u = ir.u_next[u];
                        if !(vkind(child) == .INST && (inst_op(child) == .CLEANUPPAD || inst_op(child) == .CATCHSWITCH)) continue;
                        found, cdt := um_find(memo, child);
                        if !found { array_add(*worklist, child); continue; }
                        if cdt == NONE continue;
                        if is_token_none(cdt) { token = cdt; break; }
                    }
                }
            }
        } else {
            u := ir.v_first_use[cur];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if vkind(usr) != .INST continue;
                if inst_op(usr) == .CLEANUPRET {
                    if nops(usr) >= 2 token = block_first_non_phi(op(usr, 1));
                    else token = token_none();
                    break;
                }
                cdt: Value_Id;
                if inst_op(usr) == .INVOKE {
                    cdt = block_first_non_phi(invoke_unwind_dest(usr));
                } else if inst_op(usr) == .CLEANUPPAD || inst_op(usr) == .CATCHSWITCH {
                    found, m := um_find(memo, usr);
                    if !found { array_add(*worklist, usr); continue; }
                    cdt = m;
                    if cdt == NONE continue;
                } else continue;
                if vkind(cdt) == .INST && eh_parent_pad(cdt) == cur continue;
                token = cdt;
                break;
            }
        }
        if token == NONE continue;
        unwind_parent: Value_Id = NONE;
        if vkind(token) == .INST unwind_parent = eh_parent_pad(token);
        exited := false;
        ex := cur;
        while ex != NONE && ex != unwind_parent {
            nx := eh_parent_pad(ex);
            if inst_op(ex) != .CATCHPAD {
                um_set(memo, ex, token);
                exited |= ex == eh_pad;
            }
            ex = ifx vkind(nx) == .INST then nx else NONE;
        }
        if exited return token;
    }
    return NONE;
}
// getUnwindDestToken
get_unwind_dest_token :: (eh_pad_in: Value_Id, memo: *Unwind_Memo) -> Value_Id {
    eh_pad := eh_pad_in;
    if inst_op(eh_pad) == .CATCHPAD eh_pad = op(eh_pad, 0);   // getCatchSwitch
    found, m := um_find(memo, eh_pad);
    if found return m;
    token := get_unwind_dest_token_helper(eh_pad, memo);
    if token != NONE return token;
    um_set(memo, eh_pad, NONE);
    last_useless := eh_pad;
    anc := eh_parent_pad(eh_pad);
    while vkind(anc) == .INST {
        defer anc = eh_parent_pad(anc);
        if inst_op(anc) == .CATCHPAD continue;
        af, am := um_find(memo, anc);
        if !af token = get_unwind_dest_token_helper(anc, memo);
        else token = am;
        if token != NONE break;
        last_useless = anc;
        um_set(memo, last_useless, NONE);
    }
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, last_useless);
    while worklist.count {
        useless := pop(*worklist);
        mf, mm := um_find(memo, useless);
        if mf && mm != NONE continue;
        um_set(memo, useless, token);
        if inst_op(useless) == .CATCHSWITCH {
            for hb: catchswitch_handlers(useless) {
                cp := block_first_non_phi(hb);
                u := ir.v_first_use[cp];
                while u != NONE {
                    usr := ir.u_user[u];
                    u = ir.u_next[u];
                    if vkind(usr) == .INST && (inst_op(usr) == .CATCHSWITCH || inst_op(usr) == .CLEANUPPAD) array_add(*worklist, usr);
                }
            }
        } else {
            u := ir.v_first_use[useless];
            while u != NONE {
                usr := ir.u_user[u];
                u = ir.u_next[u];
                if vkind(usr) == .INST && (inst_op(usr) == .CATCHSWITCH || inst_op(usr) == .CLEANUPPAD) array_add(*worklist, usr);
            }
        }
    }
    return token;
}
// CatchSwitchInst accessors: [parent, unwind dest?, handlers...]
catchswitch_handlers :: (cs: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    start: u32 = ifx (inst(cs).flags & F_HAS_UNWIND) != 0 then cast(u32) 2 else 1;
    for k: start..nops(cs)-1 array_add(*r, op(cs, k));
    return r;
}

// changeToInvokeAndSplitBasicBlock(CI, UnwindEdge, DTU = nullptr)
change_to_invoke_and_split_basic_block :: (ci: Value_Id, unwind_edge: Value_Id) -> Value_Id {
    bb := inst_block(ci);
    split := split_basic_block(bb, ci, tconcat(vname(ci), ".noexc"));
    erase_inst(block_last(bb));
    n := nops(ci);   // [args, bundle inputs, callee]
    ii := new_inst(.INVOKE, vtype(ci), n + 2);
    for k: 0..cast(s64) n - 2 set_op(ii, cast(u32) k, op(ci, cast(u32) k));
    set_op(ii, n - 1, split); set_op(ii, n, unwind_edge); set_op(ii, n + 1, op(ci, n - 1));
    src := inst(ci); dst := inst(ii);
    dst.ty2 = src.ty2; dst.cc = src.cc; dst.attrs = src.attrs;
    if src.nidx > 0 {
        dst.idx = cast(u32) ir.u32_pool.count; dst.nidx = src.nidx;
        for k: 0..cast(s64) src.nidx * 3 - 1 array_add(*ir.u32_pool, ir.u32_pool[src.idx + cast(u32) k]);
    }
    block_append_inst(bb, ii);
    if vname(ci).count set_name(ii, vname(ci));
    copy_debug_loc(ii, ci);
    prof := md_fixed("prof");
    set_metadata(ii, prof, get_metadata(ci, prof));
    rauw_with_metadata(ci, ii);
    erase_inst_with_metadata(block_first(split));
    return split;
}

// HandleCallsInBlockInlinedThroughInvoke
handle_calls_in_block_inlined_through_invoke :: (bb: Value_Id, unwind_edge: Value_Id, info: *Cloned_Code_Info, memo: *Unwind_Memo) -> Value_Id {
    for :early_inc i: block_insts(bb) {
        if inst_op(i) != .CALL || call_does_not_throw(i) continue;
        f := call_called_function(i);
        if f != NONE && (fn_iid(f) == IID_EXPERIMENTAL_DEOPTIMIZE || fn_iid(f) == IID_EXPERIMENTAL_GUARD) continue;
        fb := call_bundle_index(i, "funclet");
        if fb >= 0 {
            bs, be := call_bundle_range(i, cast(u32) fb);
            pad := op(i, bs);
            token := get_unwind_dest_token(pad, memo);
            if token != NONE && !is_token_none(token) continue;
        }
        was_indirect := cci_indirect_remove(info, i);
        change_to_invoke_and_split_basic_block(i, unwind_edge);
        if was_indirect cci_indirect_insert(info, block_terminator(bb));
        return bb;
    }
    return NONE;
}

// HandleInlinedLandingPad
handle_inlined_landing_pad :: (ii: Value_Id, first_new_block: Value_Id, info: *Cloned_Code_Info) {
    invoke_dest := invoke_unwind_dest(ii);
    caller := block_fn(first_new_block);
    lp: Lpad_Info;
    lpi_init(*lp, ii);
    inlined_lpads: [..] Value_Id; inlined_lpads.allocator = temp;
    b := first_new_block;
    while b != NONE {
        t := block_terminator(b);
        if t != NONE && inst_op(t) == .INVOKE {
            l := block_first_non_phi(invoke_unwind_dest(t));
            found := false;
            for inlined_lpads if it == l found = true;
            if !found array_add(*inlined_lpads, l);
        }
        b = block(b).next;
    }
    // SmallPtrSet iteration: insertion order is what a small set with these few entries gives; with more than the
    // inline capacity (16) LLVM iterates in hash order
    if inlined_lpads.count > 16 fatal("inline: more than 16 inlined landing pads (SmallPtrSet iteration order) is not supported yet");
    outer := lp.caller_lpad;
    for il: inlined_lpads {
        on := nops(outer);
        for k: 0..cast(s64) on - 1 landingpad_add_clause(il, op(outer, cast(u32) k), landingpad_clause_is_filter(outer, cast(u32) k));
        if (inst(outer).flags & F_CLEANUP) != 0 inst(il).flags |= F_CLEANUP;
    }
    memo: Unwind_Memo; memo.map.allocator = temp;
    b = first_new_block;
    while b != NONE {
        if info.contains_calls {
            nb := handle_calls_in_block_inlined_through_invoke(b, lp.outer_resume_dest, info, *memo);
            if nb != NONE lpi_add_incoming_phi_values_for_into(*lp, nb, lp.outer_resume_dest);
        }
        t := block_terminator(b);
        if t != NONE && inst_op(t) == .RESUME lpi_forward_resume(*lp, t);
        b = block(b).next;
    }
    block_remove_predecessor(invoke_dest, inst_block(ii));
}
landingpad_clause_is_filter :: (lp: Value_Id, k: u32) -> bool { return ir.u32_pool[inst(lp).idx + k] != 0; }
// LandingPadInst::addClause
landingpad_add_clause :: (lp: Value_Id, c: Value_Id, is_filter: bool) {
    n := nops(lp);
    add_op(lp, c);
    // the clause kinds live in ir.u32_pool[idx ..]: copy them to a new run with one more entry
    r := inst(lp);
    old := r.idx;
    r.idx = cast(u32) ir.u32_pool.count;
    for k: 0..cast(s64) n - 1 array_add(*ir.u32_pool, ir.u32_pool[old + cast(u32) k]);
    array_add(*ir.u32_pool, ifx is_filter then cast(u32) 1 else 0);
}

// HandleInlinedEHPad
handle_inlined_eh_pad :: (ii: Value_Id, first_new_block: Value_Id, info: *Cloned_Code_Info) {
    unwind_dest := invoke_unwind_dest(ii);
    invoke_bb := inst_block(ii);
    vals: [..] Value_Id; vals.allocator = temp;
    for pn: block_insts(unwind_dest) { if inst_op(pn) != .PHI break; array_add(*vals, phi_incoming_value_for_block(pn, invoke_bb)); }
    update_phis :: (unwind_dest: Value_Id, vals: [] Value_Id, src: Value_Id) {
        x := block_first(unwind_dest);
        for v: vals { phi_add_incoming(x, v, src); x = inst(x).next; }
    }
    memo: Unwind_Memo; memo.map.allocator = temp;
    b := first_new_block;
    while b != NONE {
        defer b = block(b).next;
        t := block_terminator(b);
        if t != NONE && inst_op(t) == .CLEANUPRET && nops(t) < 2 {
            cleanup_pad := op(t, 0);
            ncr := new_inst(.CLEANUPRET, ir.t_void, 2);
            set_op(ncr, 0, cleanup_pad); set_op(ncr, 1, unwind_dest);
            inst_insert_before(ncr, t);
            erase_inst(t);
            update_phis(unwind_dest, vals, b);
            um_set(*memo, cleanup_pad, token_none());
        }
        i := block_first_non_phi(b);
        if i == NONE || !is_eh_pad(i) continue;
        replacement: Value_Id = NONE;
        if inst_op(i) == .CATCHSWITCH {
            if (inst(i).flags & F_HAS_UNWIND) == 0 {
                token: Value_Id;
                pp := op(i, 0);
                if vkind(pp) == .INST {
                    token = get_unwind_dest_token(pp, *memo);
                    if token != NONE && !is_token_none(token) continue;
                } else token = token_none();
                handlers := catchswitch_handlers(i);
                ncs := new_inst(.CATCHSWITCH, vtype(i), cast(u32)(2 + handlers.count));
                inst(ncs).flags |= F_HAS_UNWIND;
                set_op(ncs, 0, pp); set_op(ncs, 1, unwind_dest);
                for h, hk: handlers set_op(ncs, cast(u32)(2 + hk), h);
                inst_insert_before(ncs, i);
                if vname(i).count set_name(ncs, vname(i));
                um_set(*memo, ncs, token);
                replacement = ncs;
            }
        }
        if replacement != NONE {
            take_name(replacement, i);
            replace_all_uses_with(i, replacement);
            erase_inst(i);
            update_phis(unwind_dest, vals, b);
        }
    }
    if info.contains_calls {
        b = first_new_block;
        while b != NONE {
            nb := handle_calls_in_block_inlined_through_invoke(b, unwind_dest, info, *memo);
            if nb != NONE update_phis(unwind_dest, vals, nb);
            b = block(b).next;
        }
    }
    block_remove_predecessor(unwind_dest, invoke_bb);
}

// ---------------------------------------------------------------- metadata propagation

// PropagateCallSiteMetadata
propagate_call_site_metadata :: (cb: Value_Id, start: Value_Id) {
    k_mpla := md_fixed("llvm.mem.parallel_loop_access");
    k_ag := md_fixed("llvm.access.group");
    k_as := md_fixed("alias.scope");
    k_na := md_fixed("noalias");
    mpla := get_metadata(cb, k_mpla);
    ag := get_metadata(cb, k_ag);
    as := get_metadata(cb, k_as);
    na := get_metadata(cb, k_na);
    if mpla == NONE && ag == NONE && as == NONE && na == NONE return;
    b := start;
    while b != NONE {
        for i: block_insts(b) {
            if !may_read_or_write_memory(i) continue;
            if mpla != NONE {
                mpla = md_concatenate(get_metadata(i, k_mpla), mpla);
                set_metadata(i, k_mpla, mpla);
            }
            if ag != NONE set_metadata(i, k_ag, unite_access_groups(get_metadata(i, k_ag), ag));
            if as != NONE set_metadata(i, k_as, md_concatenate(get_metadata(i, k_as), as));
            if na != NONE set_metadata(i, k_na, md_concatenate(get_metadata(i, k_na), na));
        }
        b = block(b).next;
    }
}
// uniteAccessGroups (LoopInfo.cpp)
unite_access_groups :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE return b;
    if b == NONE return a;
    groups: [..] Md_Id; groups.allocator = temp;
    add_group :: (groups: *[..] Md_Id, ag: Md_Id) {
        // an access group is a distinct node without operands; a list is a tuple of groups
        if md_nops(ag) == 0 { for groups.* if it == ag return; array_add(groups, ag); return; }
        for k: 0..cast(s64) md_nops(ag) - 1 {
            g := md_op(ag, cast(u32) k);
            found := false;
            for groups.* if it == g found = true;
            if !found array_add(groups, g);
        }
    }
    add_group(*groups, a);
    add_group(*groups, b);
    if groups.count == 1 return groups[0];
    return md_tuple(groups, false);
}

// PropagateInlinedFromMetadata
propagate_inlined_from_metadata :: (cb: Value_Id, called_name: string, caller_name: string, start: Value_Id) {
    k_srcloc := md_kind_id("srcloc");
    loc: u64 = 0;
    sm := get_metadata(cb, k_srcloc);
    if sm != NONE && md_nops(sm) > 0 {
        o := md_op(sm, 0);
        if o != NONE && ir.mds[o].kind == .VALUE && vkind(ir.mds[o].value) == .C_INT loc = const_int_zext(ir.mds[o].value);
    }
    k_if := md_kind_id("inlined.from");
    make_int :: (v: u64) -> Md_Id { return md_value(const_int(type_int(64), v)); }
    b := start;
    while b != NONE {
        for i: block_insts(b) {
            if inst_op(i) != .CALL || get_metadata(i, k_srcloc) == NONE continue;
            callee := call_called_function(i);
            if callee == NONE || (!fn_has_str_attr(callee, "dontcall-error") && !fn_has_str_attr(callee, "dontcall-warn")) continue;
            ops: [..] Md_Id; ops.allocator = temp;
            ex := get_metadata(i, k_if);
            if ex != NONE { for k: 0..cast(s64) md_nops(ex) - 1 array_add(*ops, md_op(ex, cast(u32) k)); }
            else { array_add(*ops, md_string(called_name)); array_add(*ops, make_int(0)); }
            array_add(*ops, md_string(caller_name));
            array_add(*ops, make_int(loc));
            set_metadata(i, k_if, md_tuple(ops, false));
        }
        b = block(b).next;
    }
}

// PropagateOperandBundles(InlinedBB, CallSiteEHPad)
propagate_operand_bundles :: (bb: Value_Id, eh_pad: Value_Id) {
    for :early_inc i: block_insts(bb) {
        if !is_call_base(i) continue;
        if call_bundle_index(i, "funclet") >= 0 continue;
        cf := strip_pointer_casts(call_callee(i));
        if vkind(cf) == .FUNCTION && glob(cf).intrinsic && call_does_not_throw(i) && !begins_with(vname(cf), "llvm.objc.") continue;
        ni := call_add_bundle(i, "funclet", .[eh_pad]);
        inst_insert_before(ni, i);
        take_name(ni, i);
        replace_all_uses_with(i, ni);
        erase_inst(i);
    }
}
// CallBase::Create(CB, Bundles + {tag, inputs}) (unlinked)
call_add_bundle :: (c: Value_Id, tag: string, inputs: [] Value_Id) -> Value_Id {
    n := nops(c);
    o := inst_op(c);
    tail := call_non_data_operands(c);   // callee (and dests)
    nc := new_inst(o, vtype(c), n + cast(u32) inputs.count);
    src := inst(c).*;
    r := inst(nc);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    data := n - tail;
    for k: 0..cast(s64) data - 1 set_op(nc, cast(u32) k, op(c, cast(u32) k));
    for v, k: inputs set_op(nc, data + cast(u32) k, v);
    for k: 0..cast(s64) tail - 1 set_op(nc, data + cast(u32) inputs.count + cast(u32) k, op(c, data + cast(u32) k));
    nb := src.nidx;
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = nb + 1;
    for x: 0..cast(s64) nb * 3 - 1 array_add(*ir.u32_pool, ir.u32_pool[src.idx + cast(u32) x]);
    array_add(*ir.u32_pool, bundle_tag_id(tag)); array_add(*ir.u32_pool, data); array_add(*ir.u32_pool, data + cast(u32) inputs.count);
    copy_metadata(nc, c);
    return nc;
}

// ScopedAliasMetadataDeepCloner
Sa_Cloner :: struct { md: [..] Md_Id; map: Table(Md_Id, Md_Id); }
sa_cloner_init :: (s: *Sa_Cloner, f: Value_Id) {
    s.md.allocator = temp; s.map.allocator = temp;
    ins :: (s: *Sa_Cloner, m: Md_Id) -> bool { for s.md if it == m return false; array_add(*s.md, m); return true; }
    k_as := md_fixed("alias.scope");
    k_na := md_fixed("noalias");
    for i: fn_insts(f) {
        m := get_metadata(i, k_as); if m != NONE ins(s, m);
        m = get_metadata(i, k_na); if m != NONE ins(s, m);
        if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL ins(s, cast(Md_Id) ir.v_aux[call_arg(i, 0)]);
    }
    // addRecursiveMetadataUses
    queue: [..] Md_Id; queue.allocator = temp;
    for s.md array_add(*queue, it);
    while queue.count {
        m := pop(*queue);
        for k: 0..cast(s64) md_nops(m) - 1 {
            o := md_op(m, cast(u32) k);
            if md_is_node(o) && ins(s, o) array_add(*queue, o);
        }
    }
}
// clone(): the new nodes are uniqued tuples with the mapped operands; temporaries resolve in order, so a node whose
// operand is a later node of the set is built after that one (the temporary RAUW makes LLVM's result the same)
sa_cloner_clone :: (s: *Sa_Cloner) {
    if s.md.count == 0 return;
    // LLVM builds each node with MDNode::get over temporaries and RAUWs the temporary; the final nodes are the
    // uniqued (or distinct-cloned for self references) structures. Build them in dependency order.
    done: Table(Md_Id, bool); done.allocator = temp;
    build :: (s: *Sa_Cloner, m: Md_Id, done: *Table(Md_Id, bool), depth: s64) -> Md_Id {
        found, r := table_find(*s.map, m);
        if found return r;
        if depth > 64 fatal("inline: cyclic scoped-alias metadata is not supported yet");
        in_set := false;
        for s.md if it == m in_set = true;
        if !in_set return m;
        // a self-referential (distinct) scope or domain: the clone is a new distinct node with the self reference
        if ir.mds[m].distinct {
            ops: [..] Md_Id; ops.allocator = temp;
            for k: 0..cast(s64) md_nops(m) - 1 array_add(*ops, md_op(m, cast(u32) k));
            n := md_tuple(ops, true);
            table_set(*s.map, m, n);
            for k: 0..cast(s64) md_nops(m) - 1 {
                o := md_op(m, cast(u32) k);
                nv: Md_Id;
                if o == m nv = n;
                else if md_is_node(o) nv = build(s, o, done, depth + 1);
                else nv = o;
                ir.md_ops[ir.mds[n].ops + cast(u32) k] = nv;
            }
            return n;
        }
        ops: [..] Md_Id; ops.allocator = temp;
        for k: 0..cast(s64) md_nops(m) - 1 {
            o := md_op(m, cast(u32) k);
            if md_is_node(o) array_add(*ops, build(s, o, done, depth + 1)); else array_add(*ops, o);
        }
        if ir.mds[m].kind != .TUPLE fatal("inline: scoped-alias metadata that is not a tuple is not supported yet");
        n := md_tuple(ops, false);
        table_set(*s.map, m, n);
        return n;
    }
    for s.md build(s, it, *done, 0);
}
sa_cloner_remap :: (s: *Sa_Cloner, start: Value_Id) {
    if s.map.count == 0 return;
    k_as := md_fixed("alias.scope");
    k_na := md_fixed("noalias");
    b := start;
    while b != NONE {
        for i: block_insts(b) {
            m := get_metadata(i, k_as);
            if m != NONE { f, nm := table_find(*s.map, m); if f set_metadata(i, k_as, nm); }
            m = get_metadata(i, k_na);
            if m != NONE { f, nm := table_find(*s.map, m); if f set_metadata(i, k_na, nm); }
            if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL {
                sl := cast(Md_Id) ir.v_aux[call_arg(i, 0)];
                f, nm := table_find(*s.map, sl);
                if f set_op(i, 0, md_as_value(nm));
            }
        }
        b = block(b).next;
    }
}

// MDBuilder::createAnonymousAliasScopeDomain / createAnonymousAliasScope (createAnonymousAARoot)
md_anonymous_aa_root :: (name: string, extra: Md_Id) -> Md_Id {
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, NONE);
    if extra != NONE array_add(*ops, extra);
    if name.count array_add(*ops, md_string(name));
    root := md_tuple(ops, true);
    ir.md_ops[ir.mds[root].ops] = root;
    return root;
}

// AddAliasScopeMetadata
add_alias_scope_metadata :: (cb: Value_Id, vm: *Value_Map, callee_aar: *Aa_Results, info: *Cloned_Code_Info) {
    if !if_opts.enable_noalias_to_md_conversion return;
    called := call_called_function(cb);
    noalias_args: [..] Value_Id; noalias_args.allocator = temp;
    for k: 0..cast(s64) glob(called).nargs - 1 {
        a := fn_arg(called, cast(u32) k);
        if call_param_has_attr(cb, cast(u32) k, .NoAlias) && has_uses(a) array_add(*noalias_args, a);
    }
    if noalias_args.count == 0 return;
    dt := dt_new(false);
    dt_recalculate(dt, called);
    defer dt_free(dt);
    new_scopes: Table(Value_Id, Md_Id); new_scopes.allocator = temp;
    new_domain := md_anonymous_aa_root(vname(called), NONE);
    for a, i: noalias_args {
        name := ifx vname(a).count then tprint("%1: %3%2", vname(called), vname(a), "%") else tprint("%: argument %", vname(called), i);
        scope := md_anonymous_aa_root(name, new_domain);
        table_set(*new_scopes, a, scope);
        if if_opts.use_noalias_intrinsic {
            list := md_tuple(.[scope], false);
            b: Irb; irb_set_before(*b, cb);
            f := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL, .[]);
            irb_call(*b, f, .[md_as_value(list)]);
        }
    }
    k_na := md_fixed("noalias");
    k_as := md_fixed("alias.scope");
    for nv, i: vm.map {
        if vkind(i) != .INST continue;
        if nv == NONE continue;
        ni := nv;
        if vkind(ni) != .INST || cci_is_simplified(info, i, ni) continue;
        is_arg_mem_only_call := false; is_func_call := false;
        ptr_args: [..] Value_Id; ptr_args.allocator = temp;
        o := inst_op(i);
        if o == .LOAD array_add(*ptr_args, op(i, 0));
        else if o == .STORE array_add(*ptr_args, op(i, 1));
        else if o == .VAARG array_add(*ptr_args, op(i, 0));
        else if o == .CMPXCHG array_add(*ptr_args, op(i, 0));
        else if o == .ATOMICRMW array_add(*ptr_args, op(i, 0));
        else if is_call_base(i) {
            if call_memory_effects(i) == ME_NONE continue;
            is_func_call = true;
            if callee_aar {
                me := aa_memory_effects_call(aa_query_new(callee_aar), i);
                if me_only_accesses_inaccessible_mem(me) continue;
                if me_only_accesses_arg_pointees(me) is_arg_mem_only_call = true;
            }
            for k: 0..cast(s64) call_num_args(i) - 1 {
                a := call_arg(i, cast(u32) k);
                if is_ptr_type(vtype(a)) array_add(*ptr_args, a);
            }
        }
        if ptr_args.count == 0 && !is_func_call continue;
        obj_set: [..] Value_Id; obj_set.allocator = temp;
        for v: ptr_args {
            objs: [..] Value_Id; objs.allocator = temp;
            get_underlying_objects(v, *objs);
            for x: objs { f := false; for obj_set if it == x f = true; if !f array_add(*obj_set, x); }
        }
        requires_no_capture_before := false; uses_aliasing_ptr := false; uses_unknown := false;
        for v: obj_set {
            k := vkind(v);
            if k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_DATA && is_vector_type(vtype(v)) || k == .C_UNDEF || k == .C_POISON continue;
            if k == .ARGUMENT { if !call_param_has_attr(cb, arg_no(v), .NoAlias) uses_aliasing_ptr = true; }
            else uses_aliasing_ptr = true;
            if is_escape_source(v) requires_no_capture_before = true;
            else if k != .ARGUMENT && !is_identified_object(v) uses_unknown = true;
        }
        if uses_unknown continue;
        if is_func_call && !is_arg_mem_only_call requires_no_capture_before = true;
        noaliases: [..] Md_Id; noaliases.allocator = temp;
        for a: noalias_args {
            in_set := false;
            for obj_set if it == a in_set = true;
            if in_set continue;
            if !requires_no_capture_before || pointer_may_be_captured_before(a, false, i, dt, false, CC_PROVENANCE) == CC_NONE {
                found, sc := table_find(*new_scopes, a);
                array_add(*noaliases, sc);
            }
        }
        if noaliases.count set_metadata(ni, k_na, md_concatenate(get_metadata(ni, k_na), md_tuple(noaliases, false)));
        can_add_scopes := !uses_aliasing_ptr;
        if can_add_scopes && is_func_call can_add_scopes = is_arg_mem_only_call;
        scopes: [..] Md_Id; scopes.allocator = temp;
        if can_add_scopes for a: noalias_args {
            in_set := false;
            for obj_set if it == a in_set = true;
            if in_set { found, sc := table_find(*new_scopes, a); array_add(*scopes, sc); }
        }
        if scopes.count set_metadata(ni, k_as, md_concatenate(get_metadata(ni, k_as), md_tuple(scopes, false)));
    }
}
me_only_accesses_inaccessible_mem :: (me: u64) -> bool { return me_without_loc(me, LOC_INACCESSIBLE) == 0; }

// MayContainThrowingOrExitingCallAfterCB
may_contain_throwing_or_exiting_call_after_cb :: (begin: Value_Id, end: Value_Id) -> bool {
    return !is_guaranteed_to_transfer_execution_range(inst(begin).next, end, cast(u32)(if_opts.attribute_window + 1));
}

// AddParamAndFnBasicAttributes
add_param_and_fn_basic_attributes :: (cb: Value_Id, vm: *Value_Map, info: *Cloned_Code_Info) {
    called := call_called_function(cb);
    nargs := call_num_args(cb);
    valid_obj := NewArray(nargs, u32,, allocator = temp);
    valid_exact := NewArray(nargs, u32,, allocator = temp);
    has_attr := false;
    EXACT :: Attr_Kind.[.Dereferenceable, .DereferenceableOrNull, .NonNull, .NoFPClass, .Alignment, .Range];
    for k: 0..cast(s64) nargs - 1 {
        ob: [..] Attr; ob.allocator = temp;
        if call_param_has_attr(cb, cast(u32) k, .ReadNone) { a: Attr; a.kind = .ReadNone; a.ty = NONE; array_add(*ob, a); }
        if call_param_has_attr(cb, cast(u32) k, .ReadOnly) { a: Attr; a.kind = .ReadOnly; a.ty = NONE; array_add(*ob, a); }
        ex: [..] Attr; ex.allocator = temp;
        for ak: EXACT {
            at := call_param_attr_any(cb, cast(u32) k, ak);
            if at array_add(*ex, at.*);
        }
        valid_obj[k] = attr_set_get(ob);
        valid_exact[k] = attr_set_get(ex);
        has_attr |= valid_obj[k] != 0;
        has_attr |= valid_exact[k] != 0;
    }
    if !has_attr return;
    for inner: fn_insts(called) {
        if !is_call_base(inner) continue;
        nic := vmap_lookup(vm, inner);
        if nic == NONE || vkind(nic) != .INST || !is_call_base(nic) continue;
        if cci_is_simplified(info, inner, nic) continue;
        al := inst(nic).attrs;
        for k: 0..cast(s64) call_num_args(inner) - 1 {
            ii := cast(u32) k;
            if attr_set_has(attr_list_param(al, ii), .ByVal) || call_param_has_attr(nic, ii, .ByVal) continue;
            if pm_imm_constant(call_arg(nic, ii)) continue;
            a := call_arg(inner, ii);
            argno: u32;
            if vkind(a) == .ARGUMENT {
                argno = arg_no(a);
                nab: [..] Attr; nab.allocator = temp;
                for attr_set_items(valid_exact[argno]) array_add(*nab, it);
                existing := attr_list_param(al, ii);
                remove_kind :: (nab: *[..] Attr, k: Attr_Kind) { for nab.* if it.kind == k { array_ordered_remove_by_index(nab, it_index); return; } }
                find_kind :: (nab: [] Attr, k: Attr_Kind) -> *Attr { for * nab if it.kind == k return it; return null; }
                ival_of :: (s: u32, k: Attr_Kind) -> u64 { a := attr_set_find(s, k); if a return a.ival; return 0; }
                nab_ival :: (nab: [] Attr, k: Attr_Kind) -> u64 { for nab if it.kind == k return it.ival; return 0; }
                if ival_of(existing, .Dereferenceable) > nab_ival(nab, .Dereferenceable) remove_kind(*nab, .Dereferenceable);
                if ival_of(existing, .DereferenceableOrNull) > nab_ival(nab, .DereferenceableOrNull) remove_kind(*nab, .DereferenceableOrNull);
                ea := ival_of(existing, .Alignment); na := nab_ival(nab, .Alignment);
                if (ifx ea == 0 then cast(u64) 1 else ea) > (ifx na == 0 then cast(u64) 1 else na) remove_kind(*nab, .Alignment);
                er := attr_set_find(existing, .Range);
                if er {
                    nr := find_kind(nab, .Range);
                    if nr {
                        comb := cr_intersect(attr_range(er), attr_range(nr));
                        remove_kind(*nab, .Range);
                        array_add(*nab, attr_from_range(comb));
                    }
                }
                enf := cast(u32) ival_of(existing, .NoFPClass);
                if enf != 0 {
                    cur := cast(u32) nab_ival(nab, .NoFPClass);
                    remove_kind(*nab, .NoFPClass);
                    array_add(*nab, attr_nofpclass(enf | cur));
                }
                al = attr_list_with_param(al, ii, attr_set_merge(attr_list_param(al, ii), attr_set_get(nab)));
            } else if is_ptr_type(vtype(call_arg(nic, ii))) {
                uv := get_underlying_object(call_arg(inner, ii));
                if vkind(uv) != .ARGUMENT continue;
                argno = arg_no(uv);
            } else continue;
            al = attr_list_with_param(al, ii, attr_set_merge(attr_list_param(al, ii), valid_obj[argno]));
            ps := attr_list_param(al, ii);
            if attr_set_has(ps, .ReadOnly) && attr_set_has(ps, .WriteOnly) {
                a: Attr; a.kind = .ReadNone; a.ty = NONE;
                al = attr_list_with_param(al, ii, attr_set_with(ps, a));
            }
            ps = attr_list_param(al, ii);
            if attr_set_has(ps, .ReadNone) {
                ps = attr_set_remove(attr_set_remove(ps, .ReadOnly), .WriteOnly);
                al = attr_list_with_param(al, ii, ps);
            }
            ps = attr_list_param(al, ii);
            if attr_set_has(ps, .ReadOnly) || attr_set_has(ps, .ReadNone) al = attr_list_with_param(al, ii, attr_set_remove(ps, .Writable));
        }
        inst(nic).attrs = al;
    }
}
// CallBase::getParamAttr(ArgNo, Kind): the call-site attribute, else the called Function's (getParamAttrOnCalledFunction)
call_param_attr_any :: (c: Value_Id, k: u32, kind: Attr_Kind) -> *Attr {
    a := attr_set_find(attr_list_param(inst(c).attrs, k), kind);
    if a return a;
    f := call_called_operand_fn(c);
    if f != NONE return attr_set_find(attr_list_param(glob(f).attrs, k), kind);
    return null;
}
attr_from_range :: (r: Const_Range) -> Attr {
    a: Attr; a.kind = .Range; a.ty = NONE; a.ival = r.lo.bits;
    lw := ap_words(r.lo); hw := ap_words(r.hi);
    lo := NewArray(lw.count, u64,, allocator = temp); for lw lo[it_index] = it;
    hi := NewArray(hw.count, u64,, allocator = temp); for hw hi[it_index] = it;
    a.lo = lo; a.hi = hi;
    return a;
}

// AddReturnAttributes
add_return_attributes :: (cb: Value_Id, vm: *Value_Map, info: *Cloned_Code_Info) {
    ub := identify_valid_ub_generating_attributes(cb);
    pg := identify_valid_poison_generating_attributes(cb);
    if ub.count == 0 && pg.count == 0 return;
    called := call_called_function(cb);
    for bb: fn_blocks(called) {
        ri := block_terminator(bb);
        if ri == NONE || inst_op(ri) != .RET || nops(ri) == 0 continue;
        rv := op(ri, 0);
        if !(vkind(rv) == .INST && is_call_base(rv)) continue;
        nrv := vmap_lookup(vm, rv);
        if nrv == NONE || vkind(nrv) != .INST || !is_call_base(nrv) continue;
        if cci_is_simplified(info, rv, nrv) continue;
        if inst_block(ri) != inst_block(rv) || may_contain_throwing_or_exiting_call_after_cb(rv, ri) continue;
        vub := identify_valid_ub_generating_attributes(cb);
        vpg := identify_valid_poison_generating_attributes(cb);
        al := inst(nrv).attrs;
        rs := attr_list_ret(al);
        get_ival :: (s: u32, k: Attr_Kind) -> u64 { a := attr_set_find(s, k); if a return a.ival; return 0; }
        list_ival :: (l: [] Attr, k: Attr_Kind) -> u64 { for l if it.kind == k return it.ival; return 0; }
        remove_kind :: (l: *[..] Attr, k: Attr_Kind) { for l.* if it.kind == k { array_ordered_remove_by_index(l, it_index); return; } }
        find_kind :: (l: [] Attr, k: Attr_Kind) -> *Attr { for * l if it.kind == k return it; return null; }
        if list_ival(vub, .Dereferenceable) < get_ival(rs, .Dereferenceable) remove_kind(*vub, .Dereferenceable);
        if list_ival(vub, .DereferenceableOrNull) < get_ival(rs, .DereferenceableOrNull) remove_kind(*vub, .DereferenceableOrNull);
        // AttributeList::addRetAttributes(B): existing attributes win for kinds both have (AttrBuilder::merge of the old set
        // with the new: the new overrides? -- addRetAttributes merges B into the existing set, B's attributes override)
        new_rs := attr_set_merge(rs, attr_set_get(vub));
        pa := get_ival(rs, .Alignment); va := list_ival(vpg, .Alignment);
        if (ifx va == 0 then cast(u64) 1 else va) < (ifx pa == 0 then cast(u64) 1 else pa) remove_kind(*vpg, .Alignment);
        if vpg.count {
            cbr := find_kind(vpg, .Range);
            if cbr {
                nr := attr_set_find(rs, .Range);
                if nr {
                    comb := cr_intersect(attr_range(cbr), attr_range(nr));
                    remove_kind(*vpg, .Range);
                    array_add(*vpg, attr_from_range(comb));
                }
            }
            cnf := find_kind(vpg, .NoFPClass);
            if cnf && attr_set_has(rs, .NoFPClass) {
                m := cast(u32) cnf.ival | cast(u32) attr_set_find(rs, .NoFPClass).ival;
                remove_kind(*vpg, .NoFPClass);
                array_add(*vpg, attr_nofpclass(m));
            }
            if call_has_ret_attr(cb, .NoUndef) || (value_has_one_use(rv) && !call_has_ret_attr(rv, .NoUndef))
                new_rs = attr_set_merge(new_rs, attr_set_get(vpg));
        }
        ps := ifx al == 0 then .[] else ir.attr_lists[al].params;
        inst(nrv).attrs = attr_list_get(attr_list_fn(al), new_rs, ps);
    }
}
// IdentifyValidUBGeneratingAttributes
identify_valid_ub_generating_attributes :: (cb: Value_Id) -> [..] Attr {
    r: [..] Attr; r.allocator = temp;
    d := call_ret_deref_bytes(cb, .Dereferenceable);
    if d { a: Attr; a.kind = .Dereferenceable; a.ty = NONE; a.ival = d; array_add(*r, a); }
    d = call_ret_deref_bytes(cb, .DereferenceableOrNull);
    if d { a: Attr; a.kind = .DereferenceableOrNull; a.ty = NONE; a.ival = d; array_add(*r, a); }
    if call_has_ret_attr(cb, .NoAlias) { a: Attr; a.kind = .NoAlias; a.ty = NONE; array_add(*r, a); }
    if call_has_ret_attr(cb, .NoUndef) { a: Attr; a.kind = .NoUndef; a.ty = NONE; array_add(*r, a); }
    return r;
}
// IdentifyValidPoisonGeneratingAttributes
identify_valid_poison_generating_attributes :: (cb: Value_Id) -> [..] Attr {
    r: [..] Attr; r.allocator = temp;
    if call_has_ret_attr(cb, .NonNull) { a: Attr; a.kind = .NonNull; a.ty = NONE; array_add(*r, a); }
    al := call_ret_attr(cb, .Alignment);
    if al { a: Attr; a.kind = .Alignment; a.ty = NONE; a.ival = al.ival; array_add(*r, a); }
    ok, rng := call_range(cb);
    if ok array_add(*r, attr_from_range(rng));
    nf := call_ret_attr(cb, .NoFPClass);
    if nf array_add(*r, attr_nofpclass(fpc_ret_no_fp_class(cb)));
    return r;
}
// CallBase::getRetDereferenceableBytes / ...OrNull: the call site's, else the callee's
call_ret_deref_bytes :: (cb: Value_Id, k: Attr_Kind) -> u64 {
    a := call_ret_attr(cb, k);
    if a return a.ival;
    return 0;
}

// updateCallProfile
update_call_profile :: (callee: Value_Id, vm: *Value_Map, callee_entry_count: u64, call: Value_Id, psi: *Psi, caller_bfi: *Bfi) {
    if callee_entry_count < 1 return;
    ok, site := false, cast(u64) 0;
    if psi ok, site = psi_profile_count(psi, call, caller_bfi);
    call_count := min(ifx ok then site else 0, callee_entry_count);
    update_profile_callee(callee, -cast,no_check(s64) call_count, vm);
}
// updateProfileCallee(Callee, EntryDelta, VMap)
update_profile_callee :: (callee: Value_Id, entry_delta: s64, vm: *Value_Map) {
    ok, callee_count := function_entry_count(callee);
    if !ok return;
    new_entry_count: u64 = ifx entry_delta < 0 && cast,no_check(u64) (-entry_delta) > callee_count then 0 else callee_count + cast,no_check(u64) entry_delta;
    update_vtable_prof_weight :: (cb: Value_Id, s: u64, t: u64) {
        vptr := try_get_vtable_instruction(cb);
        if vptr != NONE scale_prof_data(vptr, s, t);
    }
    // CallInst/InvokeInst::updateProfWeight
    update_prof_weight :: (cb: Value_Id, s: u64, t: u64) { if t != 0 scale_prof_data(cb, s, t); }
    if vm {
        clone_entry_count := callee_count - new_entry_count;
        for v, k: vm.map {
            if vkind(k) != .INST || v == NONE || vkind(v) != .INST continue;
            if (inst_op(k) == .CALL && inst_op(v) == .CALL) || (inst_op(k) == .INVOKE && inst_op(v) == .INVOKE) {
                update_prof_weight(v, clone_entry_count, callee_count);
                update_vtable_prof_weight(v, clone_entry_count, callee_count);
            }
        }
    }
    if entry_delta != 0 {
        fn_set_entry_count(callee, new_entry_count);
        for bb: fn_blocks(callee) {
            if vm && !vmap_contains(vm, bb) continue;
            for i: block_insts(bb) {
                if inst_op(i) != .CALL && inst_op(i) != .INVOKE continue;
                update_prof_weight(i, new_entry_count, callee_count);
                update_vtable_prof_weight(i, new_entry_count, callee_count);
            }
        }
    }
}
// Function::setEntryCount(Count): MDBuilder::createFunctionEntryCount with the import GUIDs kept (sorted)
fn_set_entry_count :: (f: Value_Id, count: u64) {
    kind := md_fixed("prof");
    old := get_metadata(f, kind);
    guids: [..] u64; guids.allocator = temp;
    if old != NONE && md_nops(old) > 0 {
        s := md_op(old, 0);
        if s != NONE && ir.mds[s].kind == .STRING && ir.mds[s].str == "function_entry_count" {
            for k: 2..cast(s64) md_nops(old) - 1 {
                g := const_int_zext(md_const_int_op(old, cast(u32) k));
                dup := false;
                for guids if it == g { dup = true; break; }
                if !dup array_add(*guids, g);
            }
        }
    }
    // llvm::sort
    for a: 1..guids.count - 1 {
        x := guids[a]; b := a - 1;
        while b >= 0 && guids[b] > x { guids[b + 1] = guids[b]; b -= 1; }
        guids[b + 1] = x;
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("function_entry_count"));
    array_add(*ops, md_value(const_int(ir.t_i64, count)));
    for guids array_add(*ops, md_value(const_int(ir.t_i64, it)));
    set_metadata(f, kind, md_tuple(ops, false));
}
// PGOIndirectCallVisitor::tryGetVTableInstruction
try_get_vtable_instruction :: (cb: Value_Id) -> Value_Id {
    callee := call_callee(cb);
    // CallBase::isIndirectCall
    if is_const(callee) || vkind(callee) == .INLINE_ASM return NONE;
    if vkind(callee) != .INST || inst_op(callee) != .LOAD return NONE;
    vt := strip_in_bounds_constant_offsets(op(callee, 0));
    if vt != NONE && vkind(vt) == .INST return vt;
    return NONE;
}
// scaleProfData(I, S, T)
scale_prof_data :: (i: Value_Id, s: u64, t: u64) {
    kind := md_fixed("prof");
    pd := get_metadata(i, kind);
    if pd == NONE || md_nops(pd) == 0 return;
    nm := md_op(pd, 0);
    if nm == NONE || ir.mds[nm].kind != .STRING return;
    name := ir.mds[nm].str;
    if name != "branch_weights" && name != "VP" return;
    // hasCountTypeMD
    is_vp := md_nops(pd) >= 5;
    is_bw := prof_is_branch_weight_md(pd);
    if !(name == "VP" && is_vp) && !((vkind(i) == .INST && is_call_base(i)) && !(name == "branch_weights" && is_bw)) return;
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, nm);
    W :: 128;
    aps := ap_from_u64(W, s); apt := ap_from_u64(W, t);
    if name == "branch_weights" && md_nops(pd) > 0 {
        off: u32 = ifx prof_has_branch_weight_origin(pd) then cast(u32) 2 else 1;
        val := ap_mul(ap_from_u64(W, const_int_zext(md_const_int_op(pd, off))), aps);
        array_add(*ops, md_value(const_int(ir.t_i32, ap_limited_value(ap_udiv(val, apt), 0xFFFF_FFFF))));
    } else if name == "VP" {
        idx: u32 = 1;
        while idx < md_nops(pd) {
            array_add(*ops, md_op(pd, idx));
            count := const_int_zext(md_const_int_op(pd, idx + 1));
            if count == 0xFFFF_FFFF_FFFF_FFFF {
                array_add(*ops, md_op(pd, idx + 1));
            } else {
                val := ap_mul(ap_from_u64(W, count), aps);
                array_add(*ops, md_value(const_int(ir.t_i64, ap_limited_value(ap_udiv(val, apt), 0xFFFF_FFFF_FFFF_FFFF))));
            }
            idx += 2;
        }
    }
    set_metadata(i, kind, md_tuple(ops, false));
}

// AddAlignmentAssumptions
add_alignment_assumptions :: (cb: Value_Id, ifi: *Inline_Function_Info) {
    if !if_opts.preserve_alignment_assumptions || !ifi.use_assumption_cache return;
    caller := inst_fn(cb);
    ac := get_assumption_cache(caller);
    dt: *Dom_Tree = null;
    called := call_called_function(cb);
    for k: 0..cast(s64) glob(called).nargs - 1 {
        a := fn_arg(called, cast(u32) k);
        if !is_ptr_type(vtype(a)) || arg_has_pass_pointee_by_value_copy(a) || !has_uses(a) continue;
        alp := attr_set_find(arg_attrs(a), .Alignment);
        if !alp continue;
        // a copy: the pointer into ir.attr_pool dangles once the assume declaration below adds attribute sets
        al_ival := alp.ival;
        if !dt { dt = dt_new(false); dt_recalculate(dt, caller); }
        av := call_arg(cb, arg_no(a));
        if get_known_alignment(av, cb, ac, dt) >= al_ival continue;
        // IRBuilder<>(&CB).CreateAlignmentAssumption(DL, ArgVal, Alignment)
        f := get_or_insert_intrinsic_declaration(IID_ASSUME, .[]);
        i := new_inst(.CALL, ir.t_void, 4);
        inst(i).ty2 = glob(f).value_type;
        set_op(i, 0, get_true(ir.t_i1));
        set_op(i, 1, av);
        set_op(i, 2, const_int(ir.t_i64, al_ival));
        set_op(i, 3, f);
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
        array_add(*ir.u32_pool, bundle_tag_id("align")); array_add(*ir.u32_pool, 1); array_add(*ir.u32_pool, 3);
        b: Irb; irb_set_before(*b, cb);
        irb_insert(*b, i);
        ac_register_assumption(ac, i);
    }
    if dt dt_free(dt);
}

// HandleByValArgument
handle_byval_argument :: (byval_ty: Type_Id, arg: Value_Id, the_call: Value_Id, called: Value_Id, ifi: *Inline_Function_Info, byval_align: u64) -> Value_Id {
    caller := inst_fn(the_call);
    if fn_only_reads_memory(called) {
        if byval_align <= 1 return arg;
        ac := ifx ifi.use_assumption_cache then get_assumption_cache(caller) else null;
        if get_or_enforce_known_alignment(arg, byval_align, the_call, ac, null) >= byval_align return arg;
    }
    alignment := dl_pref_align(byval_ty);
    if byval_align > alignment alignment = byval_align;
    na := create_alloca_unlinked(byval_ty, cast(u32) ir.types[vtype(arg)].a, alignment);
    set_name_unlinked(na, vname(arg));
    entry := fn_entry(caller);
    insert_at_position(na, entry, block_first(entry), true);
    if vname(na).count ic_reinsert_name(na);
    array_add(*ifi.static_allocas, na);
    return na;
}
// new AllocaInst(Ty, AddrSpace, nullptr, Align, "") (unlinked)
create_alloca_unlinked :: (ty: Type_Id, addrspace: u32, align: u64) -> Value_Id {
    a := new_inst(.ALLOCA, type_ptr(addrspace), 1);
    set_op(a, 0, const_int(ir.t_i32, 1));
    inst(a).ty2 = ty;
    inst(a).addrspace = addrspace;
    inst_set_align(a, align);
    return a;
}
// HandleByValArgumentInit
handle_byval_argument_init :: (byval_ty: Type_Id, dst: Value_Id, src: Value_Id, src_align: u64, insert_block: Value_Id, ifi: *Inline_Function_Info, called: Value_Id) {
    b: Irb; irb_set_at_stable(*b, insert_block, block_first(insert_block), true);
    size := const_int(type_int(64), dl_type_store_size(byval_ty));
    dst_align := pointer_alignment(dst);
    ci := irb_memcpy(*b, dst, dst_align, src, src_align, size, false);
    if get_metadata(ci, 0) == NONE && fn_subprogram(block_fn(insert_block)) != NONE {
        sp := fn_subprogram(called);
        if sp != NONE set_metadata(ci, 0, di_location_get(0, 0, sp, NONE));
    }
}
fn_subprogram :: (f: Value_Id) -> Md_Id { return get_metadata(f, 0); }

// isUsedByLifetimeMarker / hasLifetimeMarkers
is_used_by_lifetime_marker :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        if vkind(usr) == .INST { id := call_iid(usr); if id == IID_LIFETIME_START || id == IID_LIFETIME_END return true; }
        u = ir.u_next[u];
    }
    return false;
}
has_lifetime_markers :: (ai: Value_Id) -> bool {
    // getType() == PointerType::get(Ctx, AS): always true with opaque pointers
    return is_used_by_lifetime_marker(ai);
}
// allocaWouldBeStaticInEntry
alloca_would_be_static_in_entry :: (ai: Value_Id) -> bool {
    return is_constant_kind(vkind(op(ai, 0))) && !alloca_is_used_with_inalloca(ai);
}
alloca_is_used_with_inalloca :: (ai: Value_Id) -> bool { return (inst(ai).flags & F_INALLOCA) != 0; }

// ---------------------------------------------------------------- debug locations

// DebugLoc::appendInlinedAt
append_inlined_at :: (dl: Md_Id, inlined_at: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
    locs: [..] Md_Id; locs.allocator = temp;
    last := inlined_at;
    cur := dl;
    while true {
        ia := diloc_inlined_at(cur);
        if ia == NONE break;
        found, f := table_find(cache, ia);
        if found && f != NONE { last = f; break; }
        array_add(*locs, ia);
        cur = ia;
    }
    for < md: locs {
        last = di_get(.LOCATION, true, .[diloc_scope(md), last], .[diloc_line(md), diloc_col(md), 0, 0, 0]);
        table_set(cache, md, last);
    }
    return last;
}
// inlineDebugLoc
inline_debug_loc :: (dl: Md_Id, inlined_at: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
    ia := append_inlined_at(dl, inlined_at, cache);
    return di_location_get(diloc_line(dl), diloc_col(dl), diloc_scope(dl), ia, di_int(dl, 2), di_int(dl, 3), di_int(dl, 4));
}
// updateLoopMetadataDebugLocations(I, Updater = inlineDebugLoc of DILocations)
update_loop_metadata_debug_locations :: (i: Value_Id, inlined_at: Md_Id, cache: *Table(Md_Id, Md_Id)) {
    k_loop := md_fixed("llvm.loop");
    orig := get_metadata(i, k_loop);
    if orig == NONE return;
    updater :: (m: Md_Id, inlined_at: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
        if m != NONE && is_di(m, .LOCATION) return inline_debug_loc(m, inlined_at, cache);
        return m;
    }
    recursive :: (m: Md_Id, inlined_at: Md_Id, cache: *Table(Md_Id, Md_Id)) -> Md_Id {
        if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) < 1 return m;
        o0 := md_op(m, 0);
        if o0 == NONE || ir.mds[o0].kind != .STRING return m;
        updated := false;
        ops: [..] Md_Id; ops.allocator = temp;
        array_add(*ops, o0);
        for k: 1..cast(s64) md_nops(m) - 1 {
            x := md_op(m, cast(u32) k);
            if x == NONE { array_add(*ops, NONE); continue; }
            nx := updater(recursive(x, inlined_at, cache), inlined_at, cache);
            if nx != NONE array_add(*ops, nx);
            updated |= nx != x;
        }
        if updated return md_tuple(ops, false);
        return m;
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, NONE);
    for k: 1..cast(s64) md_nops(orig) - 1 {
        x := md_op(orig, cast(u32) k);
        if x == NONE { array_add(*ops, NONE); continue; }
        nx := updater(recursive(x, inlined_at, cache), inlined_at, cache);
        if nx != NONE array_add(*ops, nx);
    }
    nl := md_tuple(ops, true);
    ir.md_ops[ir.mds[nl].ops] = nl;
    set_metadata(i, k_loop, nl);
}

// fixupLineNumbers
fixup_line_numbers :: (fnv: Value_Id, first: Value_Id, the_call: Value_Id, callee_has_debug_info: bool) {
    call_dl := get_metadata(the_call, 0);
    if call_dl == NONE return;
    // getWithoutAtom
    call_dl = di_location_get(diloc_line(call_dl), diloc_col(call_dl), diloc_scope(call_dl), diloc_inlined_at(call_dl), di_int(call_dl, 2), 0, 0);
    inlined_at := di_get(.LOCATION, true, .[diloc_scope(call_dl), diloc_inlined_at(call_dl)], .[diloc_line(call_dl), diloc_col(call_dl), 0, 0, 0]);
    cache: Table(Md_Id, Md_Id); cache.allocator = temp;
    no_inline_line_tables := fn_has_str_attr(fnv, "no-inline-line-tables");
    b := first;
    while b != NONE {
        for i: block_insts(b) {
            update_loop_metadata_debug_locations(i, inlined_at, *cache);
            done := false;
            if !no_inline_line_tables {
                dl := get_metadata(i, 0);
                if dl != NONE { set_metadata(i, 0, inline_debug_loc(dl, inlined_at, *cache)); done = true; }
            }
            if !done && !(callee_has_debug_info && !no_inline_line_tables) {
                skip := inst_op(i) == .ALLOCA && alloca_would_be_static_in_entry(i);
                if call_iid(i) == IID_PSEUDOPROBE skip = true;
                if !skip set_metadata(i, 0, call_dl);
            }
            r := inst(i).records;
            while r != 0 {
                nx := dbgr(r).next;
                if no_inline_line_tables dbgr(r).dbg = call_dl;
                else dbgr(r).dbg = inline_debug_loc(dbgr(r).dbg, inlined_at, *cache);
                r = nx;
            }
        }
        if no_inline_line_tables for i: block_insts(b) drop_dbg_records(i);
        b = block(b).next;
    }
}

// updateCallerBFI
update_caller_bfi :: (call_site_block: Value_Id, vm: *Value_Map, caller_bfi: *Bfi, callee_bfi: *Bfi, callee_entry: Value_Id) {
    cloned: [..] Value_Id; cloned.allocator = temp;
    for nv, ob: vm.map {
        if vkind(ob) != .BLOCK || nv == NONE continue;
        cb := nv;
        freq := bfi_get_block_freq(callee_bfi, ob);
        seen := false;
        for cloned if it == cb seen = true;
        if seen {
            nf := bfi_get_block_freq(caller_bfi, cb);
            if nf > freq freq = nf;
        } else array_add(*cloned, cb);
        bfi_set_block_freq(caller_bfi, cb, freq);
    }
    entry_clone := vmap_lookup(vm, callee_entry);
    bfi_set_block_freq_and_scale(caller_bfi, entry_clone, bfi_get_block_freq(caller_bfi, call_site_block), cloned);
}
// BlockFrequencyInfo::setBlockFreqAndScale
bfi_set_block_freq_and_scale :: (b: *Bfi, reference: Value_Id, freq: u64, blocks: [] Value_Id) {
    old_freq := bfi_get_block_freq(b, reference);
    // APInt NewFreq(128, Freq); BBFreq * NewFreq / OldFreq
    for bb: blocks {
        if bb == reference continue;
        f := bfi_get_block_freq(b, bb);
        hi, lo := mul_u64_128(f, freq);
        q := div_u128_by_u64(hi, lo, old_freq);
        bfi_set_block_freq(b, bb, q);
    }
    bfi_set_block_freq(b, reference, freq);
}
mul_u64_128 :: (a: u64, b: u64) -> (u64, u64) {
    a0 := a & 0xFFFF_FFFF; a1 := a >> 32;
    b0 := b & 0xFFFF_FFFF; b1 := b >> 32;
    p00 := a0 * b0; p01 := a0 * b1; p10 := a1 * b0; p11 := a1 * b1;
    mid := (p00 >> 32) + (p01 & 0xFFFF_FFFF) + (p10 & 0xFFFF_FFFF);
    lo := (p00 & 0xFFFF_FFFF) | (mid << 32);
    hi := p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    return hi, lo;
}
// (hi:lo) / d truncated to 64 bits (APInt udiv then getLimitedValue)
div_u128_by_u64 :: (hi: u64, lo: u64, d: u64) -> u64 {
    if d == 0 return 0;
    q_hi: u64 = 0; q_lo: u64 = 0; r: u64 = 0;
    for < bit: 0..127 {
        cur: u64 = ifx bit >= 64 then (hi >> cast(u64)(bit - 64)) & 1 else (lo >> cast(u64) bit) & 1;
        top := r >> 63;
        r = (r << 1) | cur;
        if top != 0 || r >= d {
            r -= d;
            if bit >= 64 q_hi |= (cast(u64) 1) << cast(u64)(bit - 64); else q_lo |= (cast(u64) 1) << cast(u64) bit;
        }
    }
    if q_hi != 0 return 0xFFFF_FFFF_FFFF_FFFF;
    return q_lo;
}

// ---------------------------------------------------------------- InlineFunction

// CanInlineCallSite
can_inline_call_site :: (cb: Value_Id, ifi: *Inline_Function_Info) -> Inline_Result {
    if inst_op(cb) == .CALLBR return ir_failure("We don't inline callbr yet.");
    ifi_reset(ifi);
    called := call_called_function(cb);
    if called == NONE || is_declaration(called) return ir_failure("external or indirect");
    ih := get_metadata(cb, md_fixed("inline_history"));
    if ih != NONE {
        for k: 0..cast(s64) md_nops(ih) - 1 {
            o := md_op(ih, cast(u32) k);
            if o != NONE && ir.mds[o].kind == .VALUE && ir.mds[o].value == called return ir_failure("inline history");
        }
    }
    nb := call_num_bundles(cb);
    for k: 0..cast(s64) nb - 1 {
        t := call_bundle_tag(cb, cast(u32) k);
        if t == "deopt" || t == "funclet" || t == "clang.arc.attachedcall" || t == "kcfi" continue;
        if t == "convergencectrl" {
            bs, be := call_bundle_range(cb, cast(u32) k);
            ifi.convergence_control_token = op(cb, bs);
            continue;
        }
        return ir_failure("unsupported operand bundle");
    }
    if call_is_convergent(cb) {
        if ifi.convergence_control_token == NONE && get_convergence_entry(fn_entry(called)) != NONE
            return ir_failure("convergent call needs convergencectrl operand");
    }
    caller := inst_fn(cb);
    if glob(called).gc.count && glob(caller).gc.count && glob(called).gc != glob(caller).gc return ir_failure("incompatible GC");
    called_pers := ifx glob(called).has_personality then strip_pointer_casts(fn_personality(called)) else NONE;
    caller_pers := ifx glob(caller).has_personality then strip_pointer_casts(fn_personality(caller)) else NONE;
    if called_pers != NONE && caller_pers != NONE && called_pers != caller_pers return ir_failure("incompatible personality");
    if caller_pers != NONE {
        pers := classify_eh_personality(caller_pers);
        if is_scoped_eh_personality(pers) {
            fb := call_bundle_index(cb, "funclet");
            if fb >= 0 { bs, be := call_bundle_range(cb, cast(u32) fb); ifi.call_site_eh_pad = op(cb, bs); }
            if ifi.call_site_eh_pad != NONE {
                if pers == .MSVC_CXX {
                    if inst_op(ifi.call_site_eh_pad) == .CLEANUPPAD {
                        for bb: fn_blocks(called) { x := block_first_non_phi(bb); if x != NONE && inst_op(x) == .CATCHSWITCH return ir_failure("catch in cleanup funclet"); }
                    }
                } else if is_asynchronous_eh_personality(pers) {
                    for bb: fn_blocks(called) if block_is_eh_pad(bb) return ir_failure("SEH in cleanup funclet");
                }
            }
        }
    }
    return ir_success();
}
// getConvergenceEntry
get_convergence_entry :: (bb: Value_Id) -> Value_Id {
    x := block_first_non_phi(bb);
    while x != NONE {
        if call_iid(x) == IID_EXPERIMENTAL_CONVERGENCE_ENTRY return x;
        x = inst(x).next;
    }
    return NONE;
}

// InlineFunction(CB, IFI, MergeAttributes, CalleeAAR, InsertLifetime, TrackInlineHistory, ForwardVarArgsTo = null)
inline_function :: (cb: Value_Id, ifi: *Inline_Function_Info, merge_attributes: bool, callee_aar: *Aa_Results, insert_lifetime: bool, track_inline_history: bool) -> Inline_Result {
    r := can_inline_call_site(cb, ifi);
    if r.ok inline_function_impl(cb, ifi, merge_attributes, callee_aar, insert_lifetime, track_inline_history);
    return r;
}

// InlineFunctionImpl
inline_function_impl :: (cb: Value_Id, ifi: *Inline_Function_Info, merge_attributes: bool, callee_aar: *Aa_Results, insert_lifetime: bool, track_inline_history: bool) {
    orig_bb := inst_block(cb);
    caller := block_fn(orig_bb);
    called := call_called_function(cb);
    eh_pad_for_call_unwinds_locally := false;
    if ifi.call_site_eh_pad != NONE && inst_op(cb) == .CALL {
        memo: Unwind_Memo; memo.map.allocator = temp;
        t := get_unwind_dest_token(ifi.call_site_eh_pad, *memo);
        eh_pad_for_call_unwinds_locally = t != NONE && !is_token_none(t);
    }
    last_block := glob(caller).last_block;
    returns: [..] Value_Id; returns.allocator = temp;
    info: Cloned_Code_Info;
    cci_init(*info);
    defer cci_done(*info);
    if glob(called).gc.count && glob(caller).gc.count == 0 glob(caller).gc = glob(called).gc;
    if glob(called).has_personality {
        cp := strip_pointer_casts(fn_personality(called));
        if !glob(caller).has_personality { glob(caller).has_personality = true; set_op(caller, 0, cp); }
    }
    first_new_block: Value_Id;
    {
        vm: Value_Map;
        vmap_init(*vm);
        vmap_track_begin(*vm);
        defer vmap_track_end(*vm);
        Byval_Init :: struct { dst: Value_Id; src: Value_Id; src_align: u64; ty: Type_Id; }
        byval_inits: [..] Byval_Init; byval_inits.allocator = temp;
        sac: Sa_Cloner;
        sa_cloner_init(*sac, called);
        for k: 0..cast(s64) glob(called).nargs - 1 {
            argno := cast(u32) k;
            actual := call_arg(cb, argno);
            if call_is_byval_arg(cb, argno) {
                bt := call_param_byval_type(cb, argno);
                pal := fn_param_align(called, argno);
                actual = handle_byval_argument(bt, actual, cb, called, ifi, pal);
                if actual != call_arg(cb, argno) array_add(*byval_inits, .{actual, call_arg(cb, argno), call_param_align(cb, argno), bt});
            }
            vmap_set(*vm, fn_arg(called, argno), actual);
        }
        add_alignment_assumptions(cb, ifi);
        if knowledge_retention_enabled() fatal("inline: --enable-knowledge-retention (salvageKnowledge with an AssumptionCache) is not implemented yet");
        clone_and_prune_function_into(caller, called, *vm, *returns, ".i", *info);
        first_new_block = block(last_block).next;
        if call_bundle_index(cb, "clang.arc.attachedcall") >= 0 fatal("inline: ObjC ARC attached calls (inlineRetainOrClaimRVCalls) are not implemented yet");
        if ifi.update_profile {
            if ifi.caller_bfi && ifi.callee_bfi update_caller_bfi(orig_bb, *vm, ifi.caller_bfi, ifi.callee_bfi, fn_entry(called));
            ok, profile := function_entry_count(called);
            if ok update_call_profile(called, *vm, profile, cb, ifi.psi, ifi.caller_bfi);
        }
        for byval_inits handle_byval_argument_init(it.ty, it.dst, it.src, it.src_align, first_new_block, ifi, called);
        pdi := call_bundle_index(cb, "deopt");
        if pdi >= 0 {
            pbs, pbe := call_bundle_range(cb, cast(u32) pdi);
            for orig: info.bundle_order {
                ics := vmap_lookup(*info.bundle_calls, orig);
                if ics == NONE || vkind(ics) != .INST || !is_call_base(ics) continue;
                ni := call_with_merged_deopt(ics, cb, pbs, pbe);
                inst_insert_before(ni, ics);
                if vname(ics).count set_name(ni, vname(ics));   // CallBase::Create(ICS, OpDefs, ICS) takes ICS's name
                replace_all_uses_with(ics, ni);
                vmap_set(*info.bundle_calls, orig, NONE);
                erase_inst(ics);
            }
        }
        fixup_line_numbers(caller, first_new_block, cb, fn_subprogram(called) != NONE);
        if assignment_tracking_enabled() fatal("inline: assignment tracking (DIAssignID) is not implemented yet");
        sa_cloner_clone(*sac);
        sa_cloner_remap(*sac, first_new_block);
        add_alias_scope_metadata(cb, *vm, callee_aar, *info);
        add_return_attributes(cb, *vm, *info);
        add_param_and_fn_basic_attributes(cb, *vm, *info);
        if get_metadata(cb, md_fixed("callsite")) != NONE || info.contains_memprof fatal("inline: memprof metadata propagation is not implemented yet");
        propagate_call_site_metadata(cb, first_new_block);
        propagate_alloc_token_metadata(called, cb, *vm, *info);
        {
            k_ir := md_fixed("implicit.ref");
            mds: [..] Md_Id; mds.allocator = temp;
            a := ir.v_md[called];
            while a != NONE { if ir.attaches[a].kind == k_ir array_add(*mds, ir.attaches[a].md); a = ir.attaches[a].next; }
            for mds add_metadata(caller, k_ir, it);
        }
        propagate_inlined_from_metadata(cb, vname(called), vname(caller), first_new_block);
        if ifi.use_assumption_cache {
            ac := get_assumption_cache(caller);
            b := first_new_block;
            while b != NONE {
                for i: block_insts(b) if call_iid(i) == IID_ASSUME ac_register_assumption(ac, i);
                b = block(b).next;
            }
        }
    }
    if ifi.convergence_control_token != NONE {
        ic := get_convergence_entry(first_new_block);
        if ic != NONE { replace_all_uses_with(ic, ifi.convergence_control_token); erase_inst(ic); }
    }
    {
        entry := fn_entry(caller);
        insert_point := block_first(entry);
        i := block_first(first_new_block);
        while i != NONE {
            ai := i;
            i = inst(i).next;
            if inst_op(ai) != .ALLOCA continue;
            if !has_uses(ai) { erase_inst(ai); continue; }
            if !alloca_would_be_static_in_entry(ai) continue;
            array_add(*ifi.static_allocas, ai);
            while i != NONE && inst_op(i) == .ALLOCA && has_uses(i) && alloca_would_be_static_in_entry(i) {
                array_add(*ifi.static_allocas, i);
                i = inst(i).next;
            }
            // Caller->getEntryBlock().splice(InsertPoint (head bit), FirstNewBlock, AI (no head bit), I (tail bit set))
            {
                dest_recs := records_take(insert_point);
                if i != NONE { plus := records_take(ai); records_prepend(i, plus); }
                x := ai;
                while x != i {
                    nx := inst(x).next;
                    inst_unlink(x);
                    inst_insert_before(x, insert_point);
                    x = nx;
                }
                if dest_recs attach_records_before(insert_point, dest_recs);
            }
        }
    }
    mark_no_unwind := call_does_not_throw(cb);
    vararg_vals: [..] Value_Id; vararg_vals.allocator = temp;
    vararg_attrs: [..] u32; vararg_attrs.allocator = temp;
    np := func_nparams(glob(called).value_type);
    for k: cast(s64) np..cast(s64) call_num_args(cb) - 1 { array_add(*vararg_vals, call_arg(cb, cast(u32) k)); array_add(*vararg_attrs, attr_list_param(inst(cb).attrs, cast(u32) k)); }
    inlined_must_tail := false; inlined_deoptimize := false;
    if info.contains_calls {
        site_tck: u32 = TCK_NONE;
        if inst_op(cb) == .CALL site_tck = call_tail_kind(cb);
        if site_tck == TCK_NOTAIL site_tck = TCK_NONE;
        b := first_new_block;
        while b != NONE {
            for :early_inc ci_: block_insts(b) {
                ci := ci_;
                if inst_op(ci) != .CALL continue;
                if vararg_vals.count && call_is_must_tail(ci) {
                    attrs := inst(ci).attrs;
                    arg_attrs: [..] u32; arg_attrs.allocator = temp;
                    if attrs != 0 || vararg_attrs.count {
                        for k: 0..cast(s64) func_nparams(inst(ci).ty2) - 1 array_add(*arg_attrs, attr_list_param(attrs, cast(u32) k));
                    }
                    for vararg_attrs array_add(*arg_attrs, it);
                    new_attrs := attr_list_get(attr_list_fn(attrs), attr_list_ret(attrs), arg_attrs);
                    na := call_num_args(ci);
                    nci := new_inst(.CALL, vtype(ci), na + cast(u32) vararg_vals.count + 1);
                    inst(nci).ty2 = inst(ci).ty2;
                    for k: 0..cast(s64) na - 1 set_op(nci, cast(u32) k, call_arg(ci, cast(u32) k));
                    for v, k: vararg_vals set_op(nci, na + cast(u32) k, v);
                    set_op(nci, na + cast(u32) vararg_vals.count, call_callee(ci));
                    inst_insert_before_adopt(nci, ci);
                    set_metadata(nci, 0, get_metadata(ci, 0));
                    inst(nci).attrs = new_attrs;
                    inst(nci).cc = inst(ci).cc;
                    rauw_with_metadata(ci, nci);
                    erase_inst(ci);
                    ci = nci;
                }
                cf := call_called_function(ci);
                if cf != NONE inlined_deoptimize |= fn_iid(cf) == IID_EXPERIMENTAL_DEOPTIMIZE;
                child := call_tail_kind(ci);
                if child != TCK_NOTAIL child = min(site_tck, child);
                call_set_tail_kind(ci, child);
                inlined_must_tail |= call_is_must_tail(ci);
                if mark_no_unwind && !call_does_not_throw(ci) call_set_does_not_throw(ci);
            }
            b = block(b).next;
        }
    }
    if (insert_lifetime || fn_has_fn_attr(caller, .PresplitCoroutine)) && ifi.static_allocas.count {
        bld: Irb; irb_set_at_stable(*bld, first_new_block, block_first(first_new_block), true);
        for ai: ifi.static_allocas {
            if (inst(ai).flags & F_SWIFTERROR) != 0 continue;
            if has_lifetime_markers(ai) continue;
            ok, size := alloca_allocation_size(ai);
            if ok && size == 0 continue;
            irb_lifetime(*bld, IID_LIFETIME_START, ai);
            for ri: returns {
                if inlined_must_tail && block_terminating_must_tail_call(inst_block(ri)) != NONE continue;
                if inlined_deoptimize && block_terminating_deoptimize_call(inst_block(ri)) != NONE continue;
                rb: Irb; irb_set_before(*rb, ri);
                irb_lifetime(*rb, IID_LIFETIME_END, ai);
            }
        }
    }
    if info.contains_dynamic_allocas {
        sb: Irb; irb_set_at_stable(*sb, first_new_block, block_first(first_new_block), true);
        saved := irb_intrinsic(*sb, "llvm.stacksave", .[type_ptr(dl_alloca_addrspace())], .[]);
        set_name(saved, "savedstack");
        for ri: returns {
            if inlined_must_tail && block_terminating_must_tail_call(inst_block(ri)) != NONE continue;
            if inlined_deoptimize && block_terminating_deoptimize_call(inst_block(ri)) != NONE continue;
            rb: Irb; irb_set_before(*rb, ri);
            irb_intrinsic(*rb, "llvm.stackrestore", .[vtype(saved)], .[saved]);
        }
    }
    if inst_op(cb) == .INVOKE {
        ud := invoke_unwind_dest(cb);
        fnp := block_first_non_phi(ud);
        if inst_op(fnp) == .LANDINGPAD handle_inlined_landing_pad(cb, first_new_block, *info);
        else handle_inlined_eh_pad(cb, first_new_block, *info);
    }
    if ifi.call_site_eh_pad != NONE {
        b := first_new_block;
        while b != NONE {
            defer b = block(b).next;
            propagate_operand_bundles(b, ifi.call_site_eh_pad);
            t := block_terminator(b);
            if t != NONE && inst_op(t) == .CLEANUPRET && nops(t) < 2 && eh_pad_for_call_unwinds_locally
                change_to_unreachable(t, false, null);
            i := block_first_non_phi(b);
            if i == NONE || !is_eh_pad(i) continue;
            if inst_op(i) == .CATCHSWITCH {
                if is_token_none(op(i, 0)) set_op(i, 0, ifi.call_site_eh_pad);
            } else {
                if is_token_none(op(i, 0)) set_op(i, 0, ifi.call_site_eh_pad);
            }
        }
    }
    if inlined_deoptimize {
        if fn_ret_type(caller) == vtype(cb) {
            k := 0;
            while k < returns.count {
                if block_terminating_deoptimize_call(inst_block(returns[k])) != NONE array_ordered_remove_by_index(*returns, k);
                else k += 1;
            }
        } else {
            normal: [..] Value_Id; normal.allocator = temp;
            new_deopt := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_DEOPTIMIZE, .[fn_ret_type(caller)]);
            for ri: returns {
                deopt_call := block_terminating_deoptimize_call(inst_block(ri));
                if deopt_call == NONE { array_add(*normal, ri); continue; }
                cconv := glob(call_called_function(deopt_call)).cc;
                glob(new_deopt).cc = cconv;
                cur_bb := inst_block(ri);
                erase_inst(ri);
                // CreateCall(NewDeoptIntrinsic, args, bundles) at the end of the block (no debug location)
                nc := ic_clone_inst(deopt_call);
                clear_all_metadata(nc);
                ir.v_type[nc] = fn_ret_type(caller);
                inst(nc).ty2 = glob(new_deopt).value_type;
                inst(nc).flags &= ~((cast(u32) 3) << TAIL_SHIFT);
                set_op(nc, nops(nc) - 1, new_deopt);
                deopt_attrs := inst(deopt_call).attrs;
                erase_inst(deopt_call);
                block_append_inst(cur_bb, nc);
                inst(nc).cc = cconv;
                inst(nc).attrs = deopt_attrs;
                ret := new_inst(.RET, ir.t_void, ifx type_kind(vtype(nc)) == .VOID then cast(u32) 0 else 1);
                if type_kind(vtype(nc)) != .VOID set_op(ret, 0, nc);
                block_append_inst(cur_bb, ret);
                l := inst(nc).attrs;
                if l != 0 {
                    ps := ir.attr_lists[l].params;
                    inst(nc).attrs = attr_list_get(attr_list_fn(l), attr_set_type_incompatible(vtype(nc), attr_list_ret(l)), ps);
                }
            }
            returns = normal;
        }
    }
    if inlined_must_tail {
        normal: [..] Value_Id; normal.allocator = temp;
        for ri: returns if block_terminating_must_tail_call(inst_block(ri)) == NONE array_add(*normal, ri);
        returns = normal;
    }
    if info.contains_calls {
        b := first_new_block;
        while b != NONE {
            for i: block_insts(b) {
                if !is_call_base(i) continue;
                f := call_called_function(i);
                if f != NONE && glob(f).intrinsic continue;
                array_add(*ifi.inlined_call_sites, i);
            }
            b = block(b).next;
        }
    }
    k_ih := md_fixed("inline_history");
    for icb: ifi.inlined_call_sites {
        if track_inline_history || cci_indirect_contains(*info, icb) {
            hist: [..] Md_Id; hist.allocator = temp;
            array_add(*hist, md_value(called));
            h := get_metadata(cb, k_ih);
            if h != NONE for k: 0..cast(s64) md_nops(h) - 1 { o := md_op(h, cast(u32) k); if o != NONE array_add(*hist, o); }
            h = get_metadata(icb, k_ih);
            if h != NONE for k: 0..cast(s64) md_nops(h) - 1 { o := md_op(h, cast(u32) k); if o != NONE array_add(*hist, o); }
            set_metadata(icb, k_ih, md_tuple(hist, false));
        }
    }
    if returns.count == 1 && block(first_new_block).next == NONE {
        // OrigBB->splice(CB.getIterator(), FirstNewBlock, begin, end)
        block_splice_all_before(orig_bb, cb, first_new_block);
        block_erase_from_parent(glob(caller).last_block);
        if inst_op(cb) == .INVOKE {
            nbr := create_br(invoke_normal_dest(cb));
            inst_insert_before(nbr, cb);
            copy_debug_loc(nbr, returns[0]);
        }
        if has_uses(cb) {
            r := returns[0];
            rv := op(r, 0);
            if rv == cb replace_all_uses_with(cb, const_poison(vtype(cb)));
            else rauw_with_metadata(cb, rv);
        }
        erase_inst_with_metadata(cb);
        erase_inst(returns[0]);
        if merge_attributes merge_attributes_for_inlining(caller, called);
        return;
    }
    after_call_bb: Value_Id;
    created_br: Value_Id = NONE;
    if inst_op(cb) == .INVOKE {
        created_br = create_br(invoke_normal_dest(cb));
        inst_insert_before(created_br, cb);
        after_call_bb = split_basic_block(orig_bb, created_br, tconcat(vname(called), ".exit"));
    } else {
        after_call_bb = split_basic_block(orig_bb, cb, tconcat(vname(called), ".exit"));
    }
    if ifi.caller_bfi bfi_set_block_freq(ifi.caller_bfi, after_call_bb, bfi_get_block_freq(ifi.caller_bfi, orig_bb));
    br := block_terminator(orig_bb);
    set_successor(br, 0, first_new_block);
    // Caller->splice(AfterCallBB, Caller, FirstNewBlock, end)
    fn_splice_blocks(caller, after_call_bb, first_new_block);
    rty := fn_ret_type(called);
    phi: Value_Id = NONE;
    if returns.count > 1 {
        if has_uses(cb) {
            phi = create_phi(rty, cast(u32) returns.count);
            inst_insert_before(phi, block_first(after_call_bb));
            if vname(cb).count set_name(phi, vname(cb));
            rauw_with_metadata(cb, phi);
        }
        if phi != NONE for ri: returns phi_add_incoming(phi, op(ri, 0), inst_block(ri));
        loc: Md_Id = NONE;
        for ri: returns {
            bi := create_br(after_call_bb);
            inst_insert_before_adopt(bi, ri);
            loc = get_metadata(ri, 0);
            set_metadata(bi, 0, loc);
            erase_inst(ri);
        }
        if created_br != NONE set_metadata(created_br, 0, loc);
    } else if returns.count {
        if has_uses(cb) {
            rv := op(returns[0], 0);
            if rv == cb replace_all_uses_with(cb, const_poison(vtype(cb)));
            else rauw_with_metadata(cb, rv);
        }
        return_bb := inst_block(returns[0]);
        block_rauw(return_bb, after_call_bb);
        // AfterCallBB->splice(AfterCallBB->begin(), ReturnBB)
        block_splice_all_at_begin(after_call_bb, return_bb);
        if created_br != NONE set_metadata(created_br, 0, get_metadata(returns[0], 0));
        erase_inst(returns[0]);
        block_erase_from_parent(return_bb);
    } else if has_uses(cb) {
        if created_br != NONE set_metadata(created_br, 0, NONE);
        replace_all_uses_with(cb, const_poison(vtype(cb)));
    }
    erase_inst_with_metadata(cb);
    if inlined_must_tail && block_num_predecessors(after_call_bb) == 0 block_erase_from_parent(after_call_bb);
    callee_entry := get_successor(br, 0);
    block_rauw(callee_entry, orig_bb);
    // OrigBB->splice(Br->getIterator(), CalleeEntry)
    block_splice_all_before(orig_bb, br, callee_entry);
    erase_inst(br);
    block_erase_from_parent(callee_entry);
    if phi != NONE {
        q: Simplify_Query; q.have_tli = false;
        if ifi.use_assumption_cache q.ac = get_assumption_cache(caller);
        v := simplify_instruction(phi, q);
        if v != NONE { rauw_with_metadata(phi, v); erase_inst(phi); }
    }
    if merge_attributes merge_attributes_for_inlining(caller, called);
}
// CallBase::Create(ICS, OpDefs) with the parent's deopt inputs prepended to the child's deopt bundle (unlinked)
call_with_merged_deopt :: (ics: Value_Id, parent: Value_Id, pbs: u32, pbe: u32) -> Value_Id {
    di := call_bundle_index(ics, "deopt");
    if di < 0 return ic_clone_inst(ics);
    bs, be := call_bundle_range(ics, cast(u32) di);
    extra := pbe - pbs;
    n := nops(ics);
    o := inst_op(ics);
    nc := new_inst(o, vtype(ics), n + extra);
    src := inst(ics).*;
    r := inst(nc);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    w: u32 = 0;
    for k: 0..cast(s64) bs - 1 { set_op(nc, w, op(ics, cast(u32) k)); w += 1; }
    for k: pbs..pbe-1 { set_op(nc, w, op(parent, k)); w += 1; }
    for k: bs..n-1 { set_op(nc, w, op(ics, k)); w += 1; }
    nb := src.nidx;
    r.idx = cast(u32) ir.u32_pool.count;
    for x: 0..cast(s64) nb - 1 {
        t := ir.u32_pool[src.idx + 3 * cast(u32) x]; b := ir.u32_pool[src.idx + 3 * cast(u32) x + 1]; e := ir.u32_pool[src.idx + 3 * cast(u32) x + 2];
        if x == di { e += extra; }
        else if b >= be { b += extra; e += extra; }
        array_add(*ir.u32_pool, t); array_add(*ir.u32_pool, b); array_add(*ir.u32_pool, e);
    }
    copy_metadata(nc, ics);
    return nc;
}
// IRBuilder(BB, IP): the insertion point's getStableDebugLoc becomes the builder's location
irb_set_at_stable :: (b: *Irb, bb: Value_Id, pt: Value_Id, head: bool) {
    b.bb = bb; b.pt = pt; b.head = head;
    if pt != NONE {
        x := pt;
        if is_debug_or_pseudo_inst(x) && call_iid(x) != IID_PSEUDOPROBE {
            n := inst(x).next;
            while n != NONE && is_debug_or_pseudo_inst(n) n = inst(n).next;
            if n != NONE x = n;
        }
        b.dbg = get_metadata(x, 0);
    }
}
// BasicBlock::splice(Dest, Src, Src->begin(), Src->end()) with spliceDebugInfo's rules for a whole block (First has
// the head bit, Last = end() carries no trailing records here): the records in front of Dest go in front of the
// first moved instruction unless Dest has the head bit. dest = NONE: at the end of the block.
block_splice_whole :: (dest_bb: Value_Id, dest: Value_Id, dest_head: bool, src: Value_Id) {
    first := block_first(src);
    if first == NONE return;
    dest_recs: u32 = 0;
    if dest != NONE dest_recs = records_take(dest);
    x := first;
    while x != NONE {
        nx := inst(x).next;
        inst_unlink(x);
        if dest != NONE inst_insert_before(x, dest); else block_append_inst(dest_bb, x);
        x = nx;
    }
    if dest_recs {
        if dest_head attach_records_before(dest, dest_recs);
        else records_prepend(first, dest_recs);
    }
}
block_splice_all_before :: (dest: Value_Id, pos: Value_Id, src: Value_Id) { block_splice_whole(inst_block(pos), pos, false, src); }
block_splice_all_at_begin :: (dest: Value_Id, src: Value_Id) { block_splice_whole(dest, block_first(dest), true, src); }
block_move_all_insts_to_end :: (dest: Value_Id, src: Value_Id) { block_splice_whole(dest, NONE, false, src); }

// IRBuilder::CreateLifetimeStart / CreateLifetimeEnd(Ptr)
irb_lifetime :: (b: *Irb, id: Intrinsic_Id, ptr: Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, .[vtype(ptr)]);
    return irb_call(b, f, .[ptr]);
}

// propagateAllocTokenMetadata
propagate_alloc_token_metadata :: (called: Value_Id, cb: Value_Id, vm: *Value_Map, info: *Cloned_Code_Info) {
    k := md_fixed("alloc_token");
    m := get_metadata(cb, k);
    if m == NONE return;
    calls: [..] Value_Id; calls.allocator = temp;
    for bb: fn_blocks(called) {
        ri := block_terminator(bb);
        if ri == NONE || inst_op(ri) != .RET || nops(ri) == 0 continue;
        // collectPointerReturningCalls
        wl: [..] Value_Id; wl.allocator = temp;
        visited: Table(Value_Id, bool); visited.allocator = temp;
        array_add(*wl, op(ri, 0));
        while wl.count {
            v := pop(*wl);
            if !is_ptr_type(vtype(v)) || table_contains(*visited, v) continue;
            table_set(*visited, v, true);
            if vkind(v) != .INST continue;
            o := inst_op(v);
            if is_call_base(v) array_add(*calls, v);
            else if o == .BITCAST || o == .ADDRSPACECAST array_add(*wl, op(v, 0));
            else if o == .PHI for x: 0..cast(s64) nops(v) - 1 array_add(*wl, op(v, cast(u32) x));
            else if o == .SELECT { array_add(*wl, op(v, 1)); array_add(*wl, op(v, 2)); }
        }
    }
    for oc: calls {
        cc := vmap_lookup(vm, oc);
        if cc == NONE || vkind(cc) != .INST || !is_call_base(cc) continue;
        if cci_is_simplified(info, oc, cc) continue;
        if get_metadata(cc, k) != NONE continue;
        set_metadata(cc, k, m);
    }
}

// ---------------------------------------------------------------- AttributeFuncs (Attributes.cpp, Attributes.td rules)

// hasCompatibleFnAttrs (GET_ATTR_COMPAT_FUNC)
fn_attrs_inline_compatible :: (caller: Value_Id, callee: Value_Id) -> bool {
    eq_kind :: (a: Value_Id, b: Value_Id, k: Attr_Kind) -> bool {
        x := fn_get_fn_attr(a, k); y := fn_get_fn_attr(b, k);
        if !x && !y return true;
        if !x || !y return false;
        return attr_equal(x, y);
    }
    eq_str :: (a: Value_Id, b: Value_Id, key: string) -> bool {
        x := fn_find_str_attr(a, key); y := fn_find_str_attr(b, key);
        if !x && !y return true;
        if !x || !y return false;
        return x.val == y.val;
    }
    for k: Attr_Kind.[.SanitizeAddress, .SanitizeThread, .SanitizeType, .SanitizeMemory, .SanitizeHWAddress, .SanitizeMemTag,
                      .SanitizeNumericalStability, .SanitizeRealtime, .SanitizeRealtimeBlocking, .SafeStack, .ShadowCallStack]
        if !eq_kind(caller, callee, k) return false;
    if !eq_str(caller, callee, "use-sample-profile") return false;
    if !eq_kind(caller, callee, .NoProfile) return false;
    if !check_denorm_mode(caller, callee) return false;
    if fn_has_fn_attr(callee, .StrictFP) && !fn_has_fn_attr(caller, .StrictFP) return false;
    if !eq_str(caller, callee, "sign-return-address") return false;
    if !eq_str(caller, callee, "sign-return-address-key") return false;
    if !eq_str(caller, callee, "branch-protection-pauth-lr") return false;
    return true;
}
fn_find_str_attr :: (f: Value_Id, key: string) -> *Attr {
    fs := attr_list_fn(glob(f).attrs);
    if !attr_set_has(fs, .STRING_ATTR) return null;
    items := attr_set_items(fs);
    for * items if it.kind == .STRING_ATTR && it.key == key return it;
    return null;
}
// checkDenormMode
check_denorm_mode :: (caller: Value_Id, callee: Value_Id) -> bool {
    env :: (f: Value_Id) -> u64 { a := fn_get_fn_attr(f, .DenormalFPEnv); if a return a.ival; return 0; }
    compatible :: (caller: u64, callee: u64) -> bool {
        DYN :: 3;
        co := caller & 0xF; ci := (caller >> 4) & 0xF;
        eo := callee & 0xF; ei := (callee >> 4) & 0xF;
        if (co == eo && ci == ei) || (eo == DYN && ei == DYN) return true;
        if ei == ci && eo == DYN return true;
        if eo == co && ei == DYN return true;
        return false;
    }
    a := env(caller); b := env(callee);
    if compatible(a & 0xFF, b & 0xFF) return compatible((a >> 8) & 0xFF, (b >> 8) & 0xFF);
    return false;
}
// mergeFnAttrs (GET_ATTR_COMPAT_FUNC)
merge_attributes_for_inlining :: (caller: Value_Id, callee: Value_Id) {
    str_true :: (f: Value_Id, key: string) -> bool { a := fn_find_str_attr(f, key); return a != null && a.val == "true"; }
    set_and_str :: (caller: Value_Id, callee: Value_Id, key: string) {
        if str_true(caller, key) && !str_true(callee, key) fn_add_fn_str_attr(caller, key, "false");
    }
    set_or_str :: (caller: Value_Id, callee: Value_Id, key: string) {
        if !str_true(caller, key) && str_true(callee, key) fn_add_fn_str_attr(caller, key, "true");
    }
    set_or_kind :: (caller: Value_Id, callee: Value_Id, k: Attr_Kind) {
        if !fn_has_fn_attr(caller, k) && fn_has_fn_attr(callee, k) fn_add_fn_attr_kind(caller, k);
    }
    set_and_str(caller, callee, "less-precise-fpmad");
    set_and_str(caller, callee, "no-signed-zeros-fp-math");
    set_or_kind(caller, callee, .NoImplicitFloat);
    set_or_str(caller, callee, "no-jump-tables");
    set_or_str(caller, callee, "profile-sample-accurate");
    set_or_kind(caller, callee, .SpeculativeLoadHardening);
    // adjustCallerSSPLevel
    if fn_has_fn_attr(caller, .StackProtect) || fn_has_fn_attr(caller, .StackProtectStrong) || fn_has_fn_attr(caller, .StackProtectReq) {
        remove_ssp :: (f: Value_Id) {
            l := glob(f).attrs;
            s := attr_set_remove(attr_set_remove(attr_set_remove(attr_list_fn(l), .StackProtect), .StackProtectStrong), .StackProtectReq);
            fn_set_attr_list(f, attr_list_with_fn(l, s));
        }
        if fn_has_fn_attr(callee, .StackProtectReq) { remove_ssp(caller); fn_add_fn_attr_kind(caller, .StackProtectReq); }
        else if fn_has_fn_attr(callee, .StackProtectStrong) && !fn_has_fn_attr(caller, .StackProtectReq) { remove_ssp(caller); fn_add_fn_attr_kind(caller, .StackProtectStrong); }
        else if fn_has_fn_attr(callee, .StackProtect) && !fn_has_fn_attr(caller, .StackProtectReq) && !fn_has_fn_attr(caller, .StackProtectStrong) fn_add_fn_attr_kind(caller, .StackProtect);
    }
    // adjustCallerStackProbes
    if !fn_find_str_attr(caller, "probe-stack") {
        a := fn_find_str_attr(callee, "probe-stack");
        if a fn_add_fn_str_attr(caller, "probe-stack", a.val);
    }
    // adjustCallerStackProbeSize
    {
        ca := fn_find_str_attr(callee, "stack-probe-size");
        if ca {
            ra := fn_find_str_attr(caller, "stack-probe-size");
            if ra {
                rs, _ := str_to_u64_auto(ra.val); cs, _2 := str_to_u64_auto(ca.val);
                if rs > cs fn_add_fn_str_attr(caller, "stack-probe-size", ca.val);
            } else fn_add_fn_str_attr(caller, "stack-probe-size", ca.val);
        }
    }
    // adjustMinLegalVectorWidth
    {
        ra := fn_find_str_attr(caller, "min-legal-vector-width");
        if ra {
            ca := fn_find_str_attr(callee, "min-legal-vector-width");
            if ca {
                rw, _ := str_to_u64_auto(ra.val); cw, _2 := str_to_u64_auto(ca.val);
                if rw < cw fn_add_fn_str_attr(caller, "min-legal-vector-width", ca.val);
            } else fn_remove_str_attr(caller, "min-legal-vector-width");
        }
    }
    // adjustNullPointerValidAttr
    if fn_has_fn_attr(callee, .NullPointerIsValid) && !fn_has_fn_attr(caller, .NullPointerIsValid) fn_add_fn_attr_kind(caller, .NullPointerIsValid);
    // setAND<MustProgressAttr>
    if fn_has_fn_attr(caller, .MustProgress) && !fn_has_fn_attr(callee, .MustProgress) {
        l := glob(caller).attrs;
        fn_set_attr_list(caller, attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), .MustProgress)));
    }
}
fn_remove_str_attr :: (f: Value_Id, key: string) {
    l := glob(f).attrs;
    fn_set_attr_list(f, attr_list_with_fn(l, attr_set_remove_str(attr_list_fn(l), key)));
}
// StringRef::getAsInteger(0, V): radix auto-detected (0x, 0b, 0 octal)
str_to_u64_auto :: (s: string) -> (u64, bool) {
    if s.count == 0 return 0, false;
    radix: u64 = 10;
    t := s;
    if begins_with(t, "0x") || begins_with(t, "0X") { radix = 16; t = slice(t, 2, t.count - 2); }
    else if begins_with(t, "0b") || begins_with(t, "0B") { radix = 2; t = slice(t, 2, t.count - 2); }
    else if t.count > 1 && t[0] == #char "0" { radix = 8; t = slice(t, 1, t.count - 1); }
    v: u64 = 0;
    for c: cast([] u8) t {
        d: u64;
        if c >= #char "0" && c <= #char "9" d = cast(u64)(c - #char "0");
        else if c >= #char "a" && c <= #char "z" d = cast(u64)(c - #char "a" + 10);
        else if c >= #char "A" && c <= #char "Z" d = cast(u64)(c - #char "A" + 10);
        else return 0, false;
        if d >= radix return 0, false;
        v = v * radix + d;
    }
    return v, true;
}

// ---------------------------------------------------------------- helpers named after their LLVM counterparts

const_token_none :: () -> Value_Id { return const_simple(.C_TOKEN_NONE, ir.t_token); }
inst_set_align :: (i: Value_Id, a: u64) { inst(i).align = a; }
F_SWIFTERROR :: F_SWIFTERR;
dl_alloca_addrspace :: () -> u32 { return dl.alloca_as; }
knowledge_retention_enabled :: () -> bool { return knowledge_retention.enabled; }
function_entry_count_present :: (f: Value_Id) -> bool { ok, _ := function_entry_count(f); return ok; }
// CallBase::getParamByValType: the call site's byval type, else the callee's
call_param_byval_type :: (c: Value_Id, k: u32) -> Type_Id {
    a := attr_set_find(attr_list_param(inst(c).attrs, k), .ByVal);
    if a return a.ty;
    f := call_called_function(c);
    if f != NONE { b := attr_set_find(attr_list_param(glob(f).attrs, k), .ByVal); if b return b.ty; }
    return NONE;
}
// Function::getParamAlign
fn_param_align :: (f: Value_Id, k: u32) -> u64 { a := attr_set_find(attr_list_param(glob(f).attrs, k), .Alignment); if a return a.ival; return 0; }
// getKnownAlignment(V, DL, CxtI, AC, DT)
get_known_alignment :: (v: Value_Id, cxt: Value_Id, ac: *Assumption_Cache, dt: *Dom_Tree) -> u64 { return get_or_enforce_known_alignment(v, 0, cxt, ac, dt); }
block_num_predecessors :: (b: Value_Id) -> u32 { return cast(u32) block_num_preds(b); }

// Instruction metadata cleared (a fresh CallInst carries none)
clear_all_metadata :: (i: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    for all set_metadata(i, it.kind, NONE);
}
