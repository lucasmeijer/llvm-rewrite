// LoopSimplify: canonical loop form (preheader, single backedge, dedicated exits).
// Port of llvm/lib/Transforms/Utils/LoopSimplify.cpp (placeSplitBlockCarefully, InsertPreheaderForLoop,
// separateNestedLoop, insertUniqueBackedgeBlock, simplifyOneLoop, simplifyLoop, LoopSimplifyPass), with
// formDedicatedExitBlocks (LoopUtils.cpp), Loop::makeLoopInvariant (LoopInfo.cpp), changeToUnreachable (Local.cpp)
// and isSafeToSpeculativelyExecute (ValueTracking.cpp, without loads).
//
// ScalarEvolution is never cached in this implementation, so the SE calls are omitted.

// placeSplitBlockCarefully
place_split_block_carefully :: (li: *Loop_Info, nb: Value_Id, split_preds: [] Value_Id, l: Loop_Id) {
    prev := block(nb).prev;
    for split_preds if it == prev return;
    found: Value_Id = NONE;
    for p: split_preds {
        nx := block(p).next;
        if nx != NONE && li_contains(li, l, nx) { found = p; break; }
    }
    if found == NONE found = split_preds[0];
    f := block_fn(nb);
    fn_unlink_block(f, nb);
    fn_insert_block_after(f, found, nb);
}

// InsertPreheaderForLoop
insert_preheader_for_loop :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, mssau: *Mssa_Updater, preserve_lcssa: bool) -> Value_Id {
    header := li_header(li, l);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(header, *preds);
    outside: [..] Value_Id; outside.allocator = temp;
    for p: preds {
        if li_contains(li, l, p) continue;
        if inst_op(block_terminator(p)) == .INDIRECTBR return NONE;
        array_add(*outside, p);
    }
    ph := split_block_predecessors(header, outside, ".preheader", dt, li, mssau, preserve_lcssa);
    if ph == NONE return NONE;
    place_split_block_carefully(li, ph, outside, l);
    return ph;
}

// addBlockAndPredsToSet
add_block_and_preds_to_set :: (input: Value_Id, stop: Value_Id, set: *Table(Value_Id, bool)) {
    work: [..] Value_Id; work.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    array_add(*work, input);
    while work.count {
        b := pop(*work);
        if table_contains(set, b) continue;
        table_set(set, b, true);
        if b != stop {
            block_predecessors(b, *preds);
            for preds array_add(*work, it);
        }
    }
}

// simplifyInstruction(PN, {DL, nullptr, DT, AC})
ls_simplify_phi :: (pn: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache) -> Value_Id {
    q: Simplify_Query;
    q.dt = dt; q.ac = ac; q.have_tli = false;
    return simplify_instruction(pn, sq_with_instruction(q, pn));
}

// findPHIToPartitionLoops
find_phi_to_partition_loops :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, ac: *Assumption_Cache) -> Value_Id {
    i := block_first(li_header(li, l));
    while i != NONE && inst_op(i) == .PHI {
        pn := i;
        i = inst_next(i);
        v := ls_simplify_phi(pn, dt, ac);
        if v != NONE {
            rauw_with_metadata(pn, v);
            erase_inst_with_metadata(pn);
            continue;
        }
        n := nops(pn);
        for k: 0..n-1 if phi_value(pn, k) == pn && li_contains(li, l, phi_block(pn, k)) return pn;
    }
    return NONE;
}

// separateNestedLoop
separate_nested_loop :: (li: *Loop_Info, l: Loop_Id, preheader: Value_Id, dt: *Dom_Tree, preserve_lcssa: bool,
                         ac: *Assumption_Cache, mssau: *Mssa_Updater) -> Loop_Id {
    if preheader == NONE return NONE;
    for b: li_blocks(li, l) for i: block_insts(b) {
        if is_call_base(i) && call_has_fn_attr(i, .Convergent) return NONE;
    }
    header := li_header(li, l);
    pn := find_phi_to_partition_loops(li, l, dt, ac);
    if pn == NONE return NONE;
    outer_preds: [..] Value_Id; outer_preds.allocator = temp;
    n := nops(pn);
    for k: 0..n-1 {
        if phi_value(pn, k) != pn || !li_contains(li, l, phi_block(pn, k)) {
            if inst_op(block_terminator(phi_block(pn, k))) == .INDIRECTBR return NONE;
            array_add(*outer_preds, phi_block(pn, k));
        }
    }
    pse_forget_loop(l);   // if (SE) SE->forgetLoop(L)
    nb := split_block_predecessors(header, outer_preds, ".outer", dt, li, mssau, preserve_lcssa);
    place_split_block_carefully(li, nb, outer_preds, l);

    new_outer := li_alloc_loop(li);
    parent := li_parent(li, l);
    if parent != NONE li_replace_child_loop_with(li, parent, l, new_outer);
    else li_change_top_level_loop(li, l, new_outer);
    li_add_child_loop(li, new_outer, l);
    for k: 0..li_num_blocks(li, l)-1 li_add_block_entry(li, new_outer, li.loops[l].blocks[k]);
    li_move_to_header(li, l, header);

    blocks_in_l: Table(Value_Id, bool); blocks_in_l.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(header, *preds);
    for p: preds if dt_dominates(dt, header, p) add_block_and_preds_to_set(p, header, *blocks_in_l);

    {
        k := 0;
        while k < li.loops[l].subloops.count {
            s := li.loops[l].subloops[k];
            if table_contains(*blocks_in_l, li_header(li, s)) { k += 1; continue; }
            li_remove_child_loop(li, l, s);
            li_add_child_loop(li, new_outer, s);
        }
    }
    outer_blocks: [..] Value_Id; outer_blocks.allocator = temp;
    array_add(*outer_blocks, nb);
    {
        k := 0;
        while k < li.loops[l].blocks.count {
            b := li.loops[l].blocks[k];
            if !table_contains(*blocks_in_l, b) {
                li_remove_block_from_loop(li, l, b);
                if li_loop_for(li, b) == l {
                    li_change_loop_for(li, b, new_outer);
                    array_add(*outer_blocks, b);
                }
                continue;
            }
            k += 1;
        }
    }
    form_dedicated_exit_blocks(li, l, dt, mssau, preserve_lcssa);
    if preserve_lcssa form_lcssa(li, l, dt);
    return new_outer;
}

// insertUniqueBackedgeBlock
insert_unique_backedge_block :: (li: *Loop_Info, l: Loop_Id, preheader: Value_Id, dt: *Dom_Tree, mssau: *Mssa_Updater) -> Value_Id {
    header := li_header(li, l);
    f := block_fn(header);
    if preheader == NONE return NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(header, *preds);
    backedge_blocks: [..] Value_Id; backedge_blocks.allocator = temp;
    for p: preds {
        if inst_op(block_terminator(p)) == .INDIRECTBR return NONE;
        if p != preheader array_add(*backedge_blocks, p);
    }
    be := create_block(f, tprint("%.backedge", vname(header)));
    bet := create_br(header);
    block_append_inst(be, bet);
    copy_debug_loc(bet, block_first_non_phi(header));
    // F->splice(++BackedgeBlocks.back(), BEBlock)
    fn_unlink_block(f, be);
    fn_insert_block_after(f, backedge_blocks[backedge_blocks.count - 1], be);

    i := block_first(header);
    while i != NONE && inst_op(i) == .PHI {
        pn := i;
        i = inst_next(i);
        np := create_phi(vtype(pn), cast(u32) backedge_blocks.count);
        insert_before_named(np, bet, tprint("%.be", vname(pn)));
        preheader_idx: u32 = 0xFFFF_FFFF;
        has_unique := true;
        unique: Value_Id = NONE;
        n := nops(pn);
        for k: 0..n-1 {
            ib := phi_block(pn, k);
            iv := phi_value(pn, k);
            if ib == preheader preheader_idx = k;
            else {
                phi_add_incoming(np, iv, ib);
                if has_unique {
                    if unique == NONE unique = iv;
                    else if unique != iv has_unique = false;
                }
            }
        }
        assert(preheader_idx != 0xFFFF_FFFF, "PHI has no preheader entry??");
        if preheader_idx != 0 {
            phi_set_value(pn, 0, phi_value(pn, preheader_idx));
            phi_set_block(pn, 0, phi_block(pn, preheader_idx));
        }
        phi_remove_incoming_if(pn, (p: Value_Id, idx: u32, d: *void) -> bool { return idx != 0; }, null, false);
        phi_add_incoming(pn, np, be);
        if has_unique {
            rauw_with_metadata(np, unique);
            erase_inst_with_metadata(np);
        }
    }
    loop_md: Md_Id = NONE;
    for b: backedge_blocks {
        t := block_terminator(b);
        if loop_md == NONE loop_md = get_metadata(t, MD_LOOP_KIND);
        set_metadata(t, MD_LOOP_KIND, NONE);
        replace_successor_with(t, header, be);
    }
    set_metadata(bet, MD_LOOP_KIND, loop_md);
    li_add_basic_block_to_loop(li, l, be);
    dt_split_block(dt, be);
    if mssau mssau_update_phis_when_inserting_unique_backedge_block(mssau, header, preheader, be);
    return be;
}

// formDedicatedExitBlocks (LoopUtils.cpp)
form_dedicated_exit_blocks :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, mssau: *Mssa_Updater, preserve_lcssa: bool) -> bool {
    changed := false;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    in_loop: [..] Value_Id; in_loop.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    k := 0;
    while k < li.loops[l].blocks.count {
        b := li.loops[l].blocks[k];
        k += 1;
        block_successors(b, *succs);
        for s: succs {
            if li_contains(li, l, s) continue;
            if table_contains(*visited, s) continue;
            table_set(*visited, s, true);
            // RewriteExit
            in_loop.count = 0;
            dedicated := true;
            bail := false;
            block_predecessors(s, *preds);
            for p: preds {
                if li_contains(li, l, p) {
                    if inst_op(block_terminator(p)) == .INDIRECTBR { bail = true; break; }
                    array_add(*in_loop, p);
                } else dedicated = false;
            }
            if bail || dedicated continue;
            split_block_predecessors(s, in_loop, ".loopexit", dt, li, mssau, preserve_lcssa);
            changed = true;
        }
    }
    return changed;
}

// changeToUnreachable(I, PreserveLCSSA, DTU = nullptr, MSSAU)
change_to_unreachable :: (i: Value_Id, preserve_lcssa: bool, mssau: *Mssa_Updater) -> u32 {
    bb := inst_block(i);
    if mssau mssau_change_to_unreachable(mssau, i);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for succs block_remove_predecessor(it, bb, preserve_lcssa);
    ui := new_inst(.UNREACHABLE, ir.t_void, 0);
    insert_at_position(ui, bb, i, false);
    copy_debug_loc(ui, i);
    removed: u32 = 0;
    x := i;
    while x != NONE {
        nx := inst_next(x);
        if has_uses(x) rauw_with_metadata(x, const_poison(vtype(x)));
        if inst(x).records {
            if nx == NONE { while inst(x).records dbgr_erase(inst(x).records); }   // trailing: flushTerminatorDbgRecords
        }
        erase_inst_with_metadata(x);
        removed += 1;
        x = nx;
    }
    return removed;
}

// isSafeToSpeculativelyExecute(I) (no context, IgnoreUBImplyingAttrs = true by default; loads are not handled)
is_safe_to_speculatively_execute :: (i: Value_Id, ignore_ub_implying_attrs := true) -> bool {
    opc := inst_op(i);
    if opc == {
        case .UDIV; #through;
        case .UREM;
            ok, v := pm_apint(op(i, 1));
            if ok return !ap_is_zero(v);
            return false;
        case .SDIV; #through;
        case .SREM;
            ok, d := pm_apint(op(i, 1));
            if !ok return false;
            if ap_is_zero(d) return false;
            if !ap_is_all_ones(d) return true;
            okn, nn := pm_apint(op(i, 0));
            if okn return !ap_is_min_signed(nn);
            return false;
        case .LOAD;
            fatal("isSafeToSpeculativelyExecute of a load (isDereferenceableAndAlignedPointer) is not implemented yet");
        case .CALL;
            callee := call_called_function(i);
            if callee == NONE || !fn_has_fn_attr(callee, .Speculatable) return false;
            return ignore_ub_implying_attrs || !call_has_ub_implying_attrs(i);
        case .VAARG; #through;
        case .ALLOCA; #through;
        case .INVOKE; #through;
        case .CALLBR; #through;
        case .PHI; #through;
        case .STORE; #through;
        case .RET; #through;
        case .BR; #through;
        case .CONDBR; #through;
        case .INDIRECTBR; #through;
        case .SWITCH; #through;
        case .UNREACHABLE; #through;
        case .FENCE; #through;
        case .ATOMICRMW; #through;
        case .CMPXCHG; #through;
        case .LANDINGPAD; #through;
        case .RESUME; #through;
        case .CATCHSWITCH; #through;
        case .CATCHPAD; #through;
        case .CATCHRET; #through;
        case .CLEANUPPAD; #through;
        case .CLEANUPRET;
            return false;
    }
    return true;
}

// Loop::isLoopInvariant(V)
li_is_loop_invariant :: (li: *Loop_Info, l: Loop_Id, v: Value_Id) -> bool {
    if !is_inst(v) return true;
    return !li_contains(li, l, inst_block(v));
}

// Loop::makeLoopInvariant(Instruction *I, Changed, InsertPt, MSSAU, SE)
li_make_loop_invariant :: (li: *Loop_Info, l: Loop_Id, v: Value_Id, changed: *bool, insert_pt: Value_Id, mssau: *Mssa_Updater) -> bool {
    if !is_inst(v) return true;
    i := v;
    original_parent := inst_block(i);
    if li_is_loop_invariant(li, l, i) return true;
    // isSafeToSpeculativelyExecute(I) then mayReadFromMemory(): a speculatable load would still be rejected
    if may_read_from_memory(i) return false;
    if !is_safe_to_speculatively_execute(i) return false;
    if is_eh_pad(i) return false;
    pt := insert_pt;
    if pt == NONE {
        ph := li_loop_preheader(li, l);
        if ph == NONE return false;
        pt = block_terminator(ph);
    }
    n := nops(i);
    if n > 0 for k: 0..n-1 if !li_make_loop_invariant(li, l, op(i, k), changed, pt, mssau) return false;
    inst_move_before(i, pt);
    if mssau fatal("Loop::makeLoopInvariant with MemorySSA (MSSAU->moveToPlace) is not implemented yet");
    keep_prof := original_parent == li_header(li, l);
    drop_ub_implying_attrs_and_unknown_metadata(i, keep_prof);
    if !keep_prof && inst_op(i) == .SELECT set_explicitly_unknown_branch_weights_if_profiled(i, "LoopInfo");
    pse_forget_block_and_loop_dispositions(i);   // if (SE) SE->forgetBlockAndLoopDispositions(I)
    changed.* = true;
    return true;
}

// Function::getEntryCount(): the "function_entry_count" of the function's !prof (-1 = none)
fn_entry_count :: (f: Value_Id) -> (bool, u64) {
    md := get_metadata(f, md_kind_id("prof"));
    if md == NONE || md_nops(md) < 1 return false, 0;
    s := md_op(md, 0);
    if s == NONE || ir.mds[s].kind != .STRING || ir.mds[s].str != "function_entry_count" return false, 0;
    c := md_const_int_op(md, 1);
    v := const_int_zext(c);
    if v == 0xFFFF_FFFF_FFFF_FFFF return false, 0;
    return true, v;
}
// setExplicitlyUnknownBranchWeightsIfProfiled (ProfDataUtils.cpp)
set_explicitly_unknown_branch_weights_if_profiled :: (i: Value_Id, pass_name: string) {
    ok, ec := fn_entry_count(block_fn(inst_block(i)));
    if !ok || ec == 0 return;
    ops: [2] Md_Id;
    ops[0] = md_string("unknown");
    ops[1] = md_string(pass_name);
    set_metadata(i, md_kind_id("prof"), md_tuple(ops, false));
}
// extractBranchWeights(I, TrueVal, FalseVal)
extract_branch_weights_2 :: (i: Value_Id) -> (bool, u64, u64) {
    md, w := branch_weights_of(i);
    if md == NONE || w.count > 2 return false, 0, 0;
    return true, w[0], w[1];
}
// setFittedBranchWeights(I, Weights, IsExpected = false, ElideAllZero = true)
set_fitted_branch_weights :: (i: Value_Id, w: [] u64) {
    mx: u64 = 0;
    for w if it > mx mx = it;
    fit := NewArray(w.count, u32,, allocator = temp);
    if mx > 0xFFFF_FFFF {
        lz := 0; x := mx; while (x & 0x8000_0000_0000_0000) == 0 { x <<= 1; lz += 1; }
        off := 32 - lz;
        for w fit[it_index] = cast(u32) (it >> cast(u64) off);
    } else for w fit[it_index] = cast(u32) it;
    all_zero := true;
    for fit if it != 0 all_zero = false;
    if all_zero { set_metadata(i, md_kind_id("prof"), NONE); return; }   // ElideAllZeroBranchWeights
    set_branch_weights(i, fit);
}

// Instruction::dropUBImplyingAttrsAndUnknownMetadata(KnownIDs = {prof} if keep_prof)
drop_ub_implying_attrs_and_unknown_metadata :: (i: Value_Id, keep_prof: bool) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    prof := md_kind_id("prof");
    assign := md_kind_id("DIAssignID");
    for all {
        if it.kind == 0 || it.kind == assign continue;
        if keep_prof && it.kind == prof continue;
        set_metadata(i, it.kind, NONE);
    }
    if is_call_base(i) && inst(i).attrs != 0 {
        // removeParamAttrs(ArgNo, UBImplyingAttributes) for every argument, removeRetAttrs
        l := inst(i).attrs;
        strip :: (s: u32) -> u32 {
            r := attr_set_remove(s, .NoUndef);
            r = attr_set_remove(r, .Dereferenceable);
            return attr_set_remove(r, .DereferenceableOrNull);
        }
        params: [..] u32; params.allocator = temp;
        n := call_num_args(i);
        np := ir.attr_lists[l].params.count;
        for k: 0..np-1 {
            s := attr_list_param(l, cast(u32) k);
            array_add(*params, ifx k < cast(s64) n then strip(s) else s);
        }
        inst(i).attrs = attr_list_get(attr_list_fn(l), strip(attr_list_ret(l)), params);
    }
}

// Instruction::hasUBImplyingAttrs (calls): CallBase::isPassingUndefUB for an argument, or a noundef /
// dereferenceable / dereferenceable_or_null return
call_has_ub_implying_attrs :: (c: Value_Id) -> bool {
    n := call_num_args(c);
    if n > 0 for k: 0..n-1 {
        if call_param_has_attr(c, k, .NoUndef) || call_param_has_attr(c, k, .Dereferenceable) ||
           call_param_has_attr(c, k, .DereferenceableOrNull) return true;
    }
    return call_has_ret_attr(c, .NoUndef) || call_has_ret_attr(c, .Dereferenceable) || call_has_ret_attr(c, .DereferenceableOrNull);
}

// simplifyOneLoop
simplify_one_loop :: (li: *Loop_Info, l: Loop_Id, worklist: *[..] Loop_Id, dt: *Dom_Tree, ac: *Assumption_Cache,
                      mssau: *Mssa_Updater, preserve_lcssa: bool) -> bool {
    changed := false;
    preds: [..] Value_Id; preds.allocator = temp;
    while true {   // ReprocessLoop
        k := 0;
        while k < li.loops[l].blocks.count {
            b := li.loops[l].blocks[k];
            k += 1;
            if b == li_header(li, l) continue;
            // SmallPtrSet BadPreds: iteration order of a small set is insertion order
            bad: [..] Value_Id; bad.allocator = temp;
            block_predecessors(b, *preds);
            for p: preds {
                if li_contains(li, l, p) continue;
                dup := false;
                for x: bad if x == p dup = true;
                if !dup array_add(*bad, p);
            }
            if bad.count > 8 fatal("loop-simplify: more than 8 dead predecessors (SmallPtrSet iteration order) is not implemented yet");
            for p: bad {
                change_to_unreachable(block_terminator(p), preserve_lcssa, mssau);
                changed = true;
            }
        }
        exiting: [..] Value_Id; exiting.allocator = temp;
        li_exiting_blocks(li, l, *exiting);
        for eb: exiting {
            t := block_terminator(eb);
            if inst_op(t) != .CONDBR continue;
            c := op(t, 0);
            if vkind(c) == .C_UNDEF || vkind(c) == .C_POISON {
                set_op(t, 0, const_int(vtype(c), xx ifx li_contains(li, l, get_successor(t, 0)) then 0 else 1));
                changed = true;
            }
        }
        preheader := li_loop_preheader(li, l);
        if preheader == NONE {
            preheader = insert_preheader_for_loop(li, l, dt, mssau, preserve_lcssa);
            if preheader != NONE changed = true;
        }
        if form_dedicated_exit_blocks(li, l, dt, mssau, preserve_lcssa) changed = true;

        latch := li_loop_latch(li, l);
        if latch == NONE {
            if li_num_back_edges(li, l) < 8 {
                outer := separate_nested_loop(li, l, preheader, dt, preserve_lcssa, ac, mssau);
                if outer != NONE {
                    array_add(worklist, outer);
                    changed = true;
                    continue;   // goto ReprocessLoop
                }
            }
            latch = insert_unique_backedge_block(li, l, preheader, dt, mssau);
            if latch != NONE changed = true;
        }

        i := block_first(li_header(li, l));
        while i != NONE && inst_op(i) == .PHI {
            pn := i;
            i = inst_next(i);
            v := ls_simplify_phi(pn, dt, ac);
            if v != NONE {
                pse_forget_value(pn);   // if (SE) SE->forgetValue(PN)
                if !preserve_lcssa || li_replacement_preserves_lcssa_form(li, pn, v) {
                    rauw_with_metadata(pn, v);
                    erase_inst_with_metadata(pn);
                    changed = true;
                }
            }
        }

        // HasUniqueExitBlock (over the exiting blocks computed above)
        unique_exit := true;
        {
            ue: Value_Id = NONE;
            succs: [..] Value_Id; succs.allocator = temp;
            for eb: exiting {
                block_successors(eb, *succs);
                for s: succs {
                    if li_contains(li, l, s) continue;
                    if ue == NONE ue = s;
                    else if ue != s { unique_exit = false; break; }
                }
                if !unique_exit break;
            }
        }
        if unique_exit {
            for eb: exiting {
                if block_single_predecessor(eb) == NONE continue;
                bi := block_terminator(eb);
                if inst_op(bi) != .CONDBR continue;
                ci := op(bi, 0);
                if !is_inst(ci) || (inst_op(ci) != .ICMP && inst_op(ci) != .FCMP) || inst_block(ci) != eb continue;
                all_invariant := true;
                any_invariant := false;
                x := block_first(eb);
                while x != bi {
                    cur := x;
                    x = inst_next(x);
                    if cur == ci continue;
                    pt: Value_Id = ifx preheader != NONE then block_terminator(preheader) else NONE;
                    if !li_make_loop_invariant(li, l, cur, *any_invariant, pt, mssau) { all_invariant = false; break; }
                }
                if any_invariant changed = true;
                if !all_invariant continue;
                if !ls_fold_branch_to_common_dest(bi, mssau) continue;
                // the block is now dead: remove it from the loop, the dominator tree and the function
                changed = true;
                li_remove_block(li, eb);
                n := dt_node(dt, eb);
                while dt.nodes[n].first_child >= 0 {
                    c := dt.nodes[n].first_child;
                    dt.dfs_valid = false;
                    dt_set_idom(dt, c, dt.nodes[n].idom);
                }
                dt_erase_node(dt, eb);
                if mssau fatal("loop-simplify: MemorySSAUpdater::removeBlocks is not implemented yet");
                block_remove_predecessor(get_successor(bi, 0), eb, preserve_lcssa);
                block_remove_predecessor(get_successor(bi, 1), eb, preserve_lcssa);
                erase_block_with_insts(eb);
            }
        }
        break;
    }
    return changed;
}

// foldBranchToCommonDest(BI, DTU = nullptr, MSSAU, TTI = nullptr, AC = nullptr, BonusInstThreshold = 1)
// (SimplifyCFG.cpp) for LoopSimplify's exiting blocks; branch weights fail loudly.
ls_fold_branch_to_common_dest :: (bi: Value_Id, mssau: *Mssa_Updater) -> bool {
    bb := inst_block(bi);
    c := op(bi, 0);
    if !is_inst(c) return false;
    co := inst_op(c);
    if !(co == .ICMP || co == .FCMP || is_binary_op(co) || co == .SELECT || co == .TRUNC) return false;
    if inst_block(c) != bb || num_uses(c) != 1 return false;
    if succ_contains(bb, bb) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    chosen: [..] Value_Id; chosen.allocator = temp;
    for p: preds {
        pbi := block_terminator(p);
        if inst_op(pbi) != .CONDBR continue;
        if !safe_to_merge_terminators(bi, pbi) continue;
        ok, _, _, _ := should_fold_cond_branches_to_common_destination(bi, pbi);
        if !ok continue;
        array_add(*chosen, p);
    }
    if chosen.count == 0 return false;
    num_bonus := 0;
    for i: block_insts(bb) {
        if i == c continue;
        if inst_op(i) == .BR || inst_op(i) == .CONDBR continue;
        if call_iid(i) == IID_PSEUDOPROBE continue;
        fatal("loop-simplify: foldBranchToCommonDest with bonus instructions is not implemented yet");
    }
    return perform_branch_to_common_dest_folding(bi, block_terminator(chosen[0]), mssau);
}

// incomingValuesAreCompatible / safeToMergeTerminators
safe_to_merge_terminators :: (si1: Value_Id, si2: Value_Id) -> bool {
    if si1 == si2 return false;
    b1 := inst_block(si1); b2 := inst_block(si2);
    s1: [..] Value_Id; s1.allocator = temp;
    block_successors(b1, *s1);
    s2: [..] Value_Id; s2.allocator = temp;
    block_successors(b2, *s2);
    for s: s2 {
        found := false;
        for s1 if it == s found = true;
        if !found continue;
        for pn: block_insts(s) {
            if inst_op(pn) != .PHI break;
            if phi_incoming_value_for_block(pn, b1) != phi_incoming_value_for_block(pn, b2) return false;
        }
    }
    return true;
}

// shouldFoldCondBranchesToCommonDestination(BI, PBI, TTI = nullptr): (ok, CommonSucc, Opc, InvertPredCond)
should_fold_cond_branches_to_common_destination :: (bi: Value_Id, pbi: Value_Id) -> (bool, Value_Id, Opcode, bool) {
    if get_successor(pbi, 0) == get_successor(bi, 0) return true, get_successor(bi, 0), .OR, false;
    if get_successor(pbi, 1) == get_successor(bi, 1) return true, get_successor(bi, 1), .AND, false;
    if get_successor(pbi, 0) == get_successor(bi, 1) return true, get_successor(bi, 1), .AND, true;
    if get_successor(pbi, 1) == get_successor(bi, 0) return true, get_successor(bi, 0), .OR, true;
    return false, NONE, .AND, false;
}

// Instruction::dropUBImplyingAttrsAndMetadata: drop_ub_implying_attrs_and_metadata (ic_core.jai)

// performBranchToCommonDestFolding(BI, PBI, DTU = nullptr, MSSAU, TTI = nullptr)
perform_branch_to_common_dest_folding :: (bi: Value_Id, pbi: Value_Id, mssau: *Mssa_Updater) -> bool {
    bb := inst_block(bi);
    pred := inst_block(pbi);
    _, common, opc, invert := should_fold_cond_branches_to_common_destination(bi, pbi);
    b: Irb;
    irb_set_before(*b, pbi);
    annotation := get_metadata(block_terminator(bb), md_kind_id("annotation"));
    if annotation != NONE fatal("foldBranchToCommonDest with !annotation metadata is not implemented yet");
    if invert {
        // InvertBranch(PBI, Builder)
        nc := op(pbi, 0);
        if num_uses(nc) == 1 && (is_inst(nc) && (inst_op(nc) == .ICMP || inst_op(nc) == .FCMP)) {
            inst(nc).pred = cmp_inverse(inst(nc).pred);
        } else {
            assert(type_kind(vtype(nc)) == .INT && type_int_width(vtype(nc)) == 1);
            nc = irb_binop(*b, .XOR, nc, const_int(vtype(nc), 1), tprint("%.not", vname(nc)));   // CreateNot
        }
        set_op(pbi, 0, nc);
        condbr_swap_successors(pbi);
    }
    unique_succ := ifx get_successor(pbi, 0) == bb then get_successor(bi, 0) else get_successor(bi, 1);
    // addPredecessorToBlock(UniqueSucc, PredBlock, BB, MSSAU)
    for pn: block_insts(unique_succ) {
        if inst_op(pn) != .PHI break;
        phi_add_incoming(pn, phi_incoming_value_for_block(pn, bb), pred);
    }
    if mssau fatal("foldBranchToCommonDest with MemorySSA is not implemented yet");
    // extractPredSuccWeights
    md_weights: [2] u64;
    have_weights := false;
    {
        ph, pt, pf := extract_branch_weights_2(pbi);
        sh, st, sf := extract_branch_weights_2(bi);
        if ph || sh {
            if !ph { pt = 1; pf = 1; }
            if !sh { st = 1; sf = 1; }
            if get_successor(pbi, 0) == bb {
                md_weights[0] = pt * st;
                md_weights[1] = pf * (sf + st) + pt * sf;
            } else {
                md_weights[0] = pt * (sf + st) + pf * st;
                md_weights[1] = pf * sf;
            }
            have_weights = true;
            set_fitted_branch_weights(pbi, md_weights);
        } else set_metadata(pbi, md_kind_id("prof"), NONE);
    }
    set_successor(pbi, ifx get_successor(pbi, 0) != bb then cast(u32) 1 else 0, unique_succ);
    loop_md := get_metadata(bi, MD_LOOP_KIND);
    if loop_md != NONE set_metadata(pbi, MD_LOOP_KIND, loop_md);
    // cloneInstructionsIntoPredecessorBlockAndUpdateSSAUses
    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    pti := block_terminator(pred);
    cloned: [..] u32; cloned.allocator = temp;
    for bonus: block_insts(bb) {
        if is_terminator(inst_op(bonus)) continue;
        if call_iid(bonus) == IID_PSEUDOPROBE continue;
        nb := inst_clone(bonus);
        nl := get_metadata(nb, 0); pl := get_metadata(pti, 0);
        same := nl == pl || ((nl != NONE) == (pl != NONE) && nl != NONE && diloc_line(nl) == diloc_line(pl) &&
                diloc_col(nl) == diloc_col(pl) && diloc_scope(nl) == diloc_scope(pl) && diloc_inlined_at(nl) == diloc_inlined_at(pl));
        if !same set_metadata(nb, 0, NONE);
        else if nl != NONE && di_int(nl, 3) != 0 fatal("foldBranchToCommonDest: key-instruction atom groups are not implemented yet");
        n := nops(nb);
        if n > 0 for k: 0..n-1 { found, nv := table_find(*vm, op(nb, k)); if found set_op(nb, k, nv); }
        drop_ub_implying_attrs_and_metadata(nb);
        insert_at_position(nb, pred, pti, false);
        if inst(bonus).records {
            clone_debug_info_from(nb, bonus, inst(bonus).records, *cloned);
            remap_dbg_records(cloned, *vm);
        }
        take_name(nb, bonus);
        if vname(nb).count set_name(bonus, tprint("%.old", vname(nb)));
        table_set(*vm, bonus, nb);
        u := ir.v_first_use[bonus];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            if inst_op(user) == .PHI && ir.u_aux[u] != bb use_set(u, nb);
            u = nx;
        }
    }
    ptl := get_metadata(pti, 0);
    if ptl != NONE && di_int(ptl, 3) != 0 fatal("foldBranchToCommonDest: key-instruction atom groups are not implemented yet");
    // PredBlock->getTerminator()->cloneDebugInfoFrom(BB->getTerminator()) + RemapDbgRecord
    if inst(bi).records {
        clone_debug_info_from(block_terminator(pred), bi, inst(bi).records, *cloned);
        remap_dbg_records(cloned, *vm);
    }
    found, bic := table_find(*vm, op(bi, 0));
    if !found bic = op(bi, 0);
    // createLogicalOp(Builder, Opc, PBI->getCondition(), BICond, "or.cond")
    lhs := op(pbi, 0);
    nc: Value_Id;
    if implies_poison(bic, lhs) nc = irb_binop(*b, opc, lhs, bic, "or.cond");
    else if opc == .AND nc = irb_select(*b, lhs, bic, const_int(vtype(lhs), 0), "or.cond");
    else nc = irb_select(*b, lhs, const_int(vtype(lhs), 1), bic, "or.cond");
    set_op(pbi, 0, nc);
    if have_weights && is_inst(nc) && inst_op(nc) == .SELECT set_fitted_branch_weights(nc, md_weights);
    return true;
}

// BasicBlock::eraseFromParent of a block that still has instructions (dropAllReferences first)
erase_block_with_insts :: (b: Value_Id) {
    for block_insts(b) drop_all_references(it);
    erase_block(b);
}

// LoopInfo::replacementPreservesLCSSAForm
li_replacement_preserves_lcssa_form :: (li: *Loop_Info, from: Value_Id, to: Value_Id) -> bool {
    if !is_inst(to) return true;
    tl := li_loop_for(li, inst_block(to));
    if tl == NONE return true;
    return li_contains_inst(li, tl, from);
}

// simplifyLoop
simplify_loop :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, ac: *Assumption_Cache, mssau: *Mssa_Updater, preserve_lcssa: bool) -> bool {
    changed := false;
    worklist: [..] Loop_Id; worklist.allocator = temp;
    array_add(*worklist, l);
    idx := 0;
    while idx < worklist.count {
        for li_subloops(li, worklist[idx]) array_add(*worklist, it);
        idx += 1;
    }
    while worklist.count {
        x := pop(*worklist);
        changed |= simplify_one_loop(li, x, *worklist, dt, ac, mssau, preserve_lcssa);
    }
    if changed pse_forget_topmost_loop(l);   // if (Changed && SE) SE->forgetTopmostLoop(L)
    return changed;
}

// LoopSimplifyPass::run
loop_simplify_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    dt := get_domtree(f);
    saved_se := scev_pass_se;
    scev_pass_se = cached_scev(f);   // AM.getCachedResult<ScalarEvolutionAnalysis>(F)
    defer scev_pass_se = saved_se;
    ac := get_assumption_cache(f);
    mssa := cached_memoryssa(f);
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater = null;
    if mssa { mssau_storage.mssa = mssa; mssau = *mssau_storage; }
    changed := false;
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    for tops changed |= simplify_loop(li, it, dt, ac, mssau, false);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    if mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
