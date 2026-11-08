// LoopDeletion: llvm/lib/Transforms/Scalar/LoopDeletion.cpp (complete), and the LoopUtils it needs:
// deleteDeadLoop and breakLoopBackedge (llvm/lib/Transforms/Utils/LoopUtils.cpp), containsIrreducibleCFG
// (llvm/include/llvm/Analysis/CFG.h) on a LoopBlocksRPO (llvm/include/llvm/Analysis/LoopIterator.h).

ld_opts: struct {
    enable_symbolic_execution := true;   // -loop-deletion-enable-symbolic-execution
};

Ld_Result :: enum u8 { UNMODIFIED; MODIFIED; DELETED; }
ld_merge :: (a: Ld_Result, b: Ld_Result) -> Ld_Result {
    if a == .DELETED || b == .DELETED return .DELETED;
    if a == .MODIFIED || b == .MODIFIED return .MODIFIED;
    return .UNMODIFIED;
}

// containsIrreducibleCFG(RPOTraversal, LI): a visited successor that is not the header of a loop containing the node
contains_irreducible_cfg_rpo :: (li: *Loop_Info, rpo: [] Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for node: rpo {
        table_set(*visited, node, true);
        succs.count = 0;
        block_successors(node, *succs);
        for s: succs {
            if !table_contains(*visited, s) continue;
            proper := false;
            lp := li_loop_for(li, node);
            while lp != NONE {
                if li_header(li, lp) == s { proper = true; break; }
                lp = li_parent(li, lp);
            }
            if !proper return true;
        }
    }
    return false;
}

// hasMustProgress(L): llvm.loop.mustprogress
li_has_must_progress :: (l: Loop_Id) -> bool { return li_boolean_loop_attribute(l, "llvm.loop.mustprogress"); }
// Function::mustProgress
fn_must_progress :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .MustProgress) || fn_has_fn_attr(f, .WillReturn); }

// isLoopDead
ld_is_loop_dead :: (li: *Loop_Info, l: Loop_Id, exiting: [] Value_Id, exit_block: Value_Id, changed: *bool, preheader: Value_Id) -> bool {
    all_entries_invariant := true;
    all_outgoing_values_same := true;
    if exit_block != NONE {
        for p: block_insts(exit_block) {
            if inst_op(p) != .PHI break;
            incoming := phi_incoming_for_block(p, exiting[0]);
            for k: 1..exiting.count-1 {
                if incoming != phi_incoming_for_block(p, exiting[k]) { all_outgoing_values_same = false; break; }
            }
            if !all_outgoing_values_same break;
            if is_inst(incoming) {
                if !li_make_loop_invariant(li, l, incoming, changed, block_terminator(preheader), null) {
                    all_entries_invariant = false;
                    break;
                }
            }
        }
    }
    if !all_entries_invariant || !all_outgoing_values_same return false;
    for b: li_blocks(li, l) for i: block_insts(b) {
        if may_have_side_effects(i) && !inst_is_droppable(i) return false;
    }
    if fn_must_progress(li.fn) return true;
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    if contains_irreducible_cfg_rpo(li, rpo) return false;
    work: [..] Loop_Id; work.allocator = temp;
    array_add(*work, l);
    while work.count {
        cur := pop(*work);
        if li_has_must_progress(cur) continue;
        s := sc_get_constant_max_backedge_taken_count(cur);
        if sc_is_cnc(s) return false;
        for li_subloops(li, cur) array_add(*work, it);
    }
    return true;
}

// User::isDroppable
inst_is_droppable :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_ASSUME || id == IID_PSEUDOPROBE || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL;
}

// isLoopNeverExecuted
ld_is_loop_never_executed :: (li: *Loop_Info, l: Loop_Id) -> bool {
    ph := li_loop_preheader(li, l);
    if ph == block_fn_entry(ph) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(ph, *preds);
    for pred: preds {
        t := block_terminator(pred);
        if t == NONE || inst_op(t) != .CONDBR || vkind(op(t, 0)) != .C_INT return false;
        taken := get_successor(t, 0); not_taken := get_successor(t, 1);
        if const_int_zext(op(t, 0)) == 0 { x := taken; taken = not_taken; not_taken = x; }
        if taken == ph return false;
    }
    return true;
}
block_fn_entry :: (b: Value_Id) -> Value_Id { return glob(block_fn(b)).first_block; }

// getValueOnFirstIteration
ld_value_on_first_iteration :: (v: Value_Id, cache: *Table(Value_Id, Value_Id), q: Simplify_Query) -> Value_Id {
    if !is_inst(v) return v;
    found, existing := table_find(cache, v);
    if found return existing;
    first: Value_Id = NONE;
    o := inst_op(v);
    if is_binary_op(o) {
        lhs := ld_value_on_first_iteration(op(v, 0), cache, q);
        rhs := ld_value_on_first_iteration(op(v, 1), cache, q);
        first = simplify_binop(o, lhs, rhs, q);
    } else if o == .ICMP {
        lhs := ld_value_on_first_iteration(op(v, 0), cache, q);
        rhs := ld_value_on_first_iteration(op(v, 1), cache, q);
        first = simplify_icmp_inst(inst_pred(v), false, lhs, rhs, q);   // getPredicate(): no samesign
    } else if o == .SELECT {
        c := ld_value_on_first_iteration(op(v, 0), cache, q);
        if vkind(c) == .C_INT && !is_vector_type(vtype(c)) {
            selected := ifx ap_is_all_ones(const_ap(c)) then op(v, 1) else op(v, 2);
            first = ld_value_on_first_iteration(selected, cache, q);
        }
    }
    if first == NONE first = v;
    table_set(cache, v, first);
    return first;
}

// canProveExitOnFirstIteration
ld_can_prove_exit_on_first_iteration :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    if !ld_opts.enable_symbolic_execution return false;
    predecessor := li_loop_predecessor(li, l);
    latch := li_loop_latch(li, l);
    if predecessor == NONE || latch == NONE return false;
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    if contains_irreducible_cfg_rpo(li, rpo) return false;
    header := li_header(li, l);
    live_blocks: Table(Value_Id, bool); live_blocks.allocator = temp;
    live_edges: Table(u64, bool); live_edges.allocator = temp;
    edge_key :: (a: Value_Id, b: Value_Id) -> u64 { return ((cast(u64) a) << 32) | cast(u64) b; }
    table_set(*live_blocks, header, true);
    mark_live_edge :: (live_blocks: *Table(Value_Id, bool), live_edges: *Table(u64, bool), from: Value_Id, to: Value_Id) {
        table_set(live_blocks, to, true);
        table_set(live_edges, edge_key(from, to), true);
    }
    succs: [..] Value_Id; succs.allocator = temp;
    mark_all_successors_live :: (live_blocks: *Table(Value_Id, bool), live_edges: *Table(u64, bool), succs: *[..] Value_Id, bb: Value_Id) {
        succs.count = 0;
        block_successors(bb, succs);
        for succs.* mark_live_edge(live_blocks, live_edges, bb, it);
    }
    first_iter: Table(Value_Id, Value_Id); first_iter.allocator = temp;
    q: Simplify_Query;   // SimplifyQuery(DL)
    q.have_tli = false;
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: rpo {
        if !table_contains(*live_blocks, bb) continue;
        if li_loop_for(li, bb) != l { mark_all_successors_live(*live_blocks, *live_edges, *succs, bb); continue; }
        for pn: block_insts(bb) {
            if inst_op(pn) != .PHI break;
            if !is_int_type(vtype(pn)) continue;
            // GetSoleInputOnFirstIteration
            incoming: Value_Id = NONE;
            if bb == header incoming = phi_incoming_for_block(pn, predecessor);
            else {
                only: Value_Id = NONE;
                two := false;
                preds.count = 0;
                block_predecessors(bb, *preds);
                for p: preds {
                    if !table_contains(*live_edges, edge_key(p, bb)) continue;
                    inc := phi_incoming_for_block(pn, p);
                    if vkind(inc) == .C_POISON continue;
                    if only != NONE && only != inc { two = true; break; }
                    only = inc;
                }
                if !two incoming = ifx only != NONE then only else const_poison(vtype(pn));
            }
            if incoming != NONE && dt_dominates_inst(dt, incoming, block_terminator(bb)) {
                fv := ld_value_on_first_iteration(incoming, *first_iter, q);
                table_set(*first_iter, pn, fv);
            }
        }
        term := block_terminator(bb);
        if inst_op(term) == .CONDBR {
            cond := op(term, 0);
            if_true := get_successor(term, 0); if_false := get_successor(term, 1);
            if !is_inst(cond) || inst_op(cond) != .ICMP || !is_int_type(vtype(cond)) {
                mark_all_successors_live(*live_blocks, *live_edges, *succs, bb);
                continue;
            }
            known := ld_value_on_first_iteration(cond, *first_iter, q);
            if known == cond { mark_all_successors_live(*live_blocks, *live_edges, *succs, bb); continue; }
            if vkind(known) == .C_UNDEF || vkind(known) == .C_POISON {
                if li_contains(li, l, if_true) && li_contains(li, l, if_false) mark_live_edge(*live_blocks, *live_edges, bb, if_true);
                continue;
            }
            if vkind(known) != .C_INT { mark_all_successors_live(*live_blocks, *live_edges, *succs, bb); continue; }
            if ap_is_all_ones(const_ap(known)) mark_live_edge(*live_blocks, *live_edges, bb, if_true);
            else mark_live_edge(*live_blocks, *live_edges, bb, if_false);
        } else if inst_op(term) == .SWITCH {
            sv := ld_value_on_first_iteration(op(term, 0), *first_iter, q);
            if vkind(sv) != .C_INT { mark_all_successors_live(*live_blocks, *live_edges, *succs, bb); continue; }
            mark_live_edge(*live_blocks, *live_edges, bb, switch_find_case_dest(term, sv));
        } else {
            mark_all_successors_live(*live_blocks, *live_edges, *succs, bb);
        }
    }
    return !table_contains(*live_edges, edge_key(latch, header));
}

// breakBackedgeIfNotTaken
ld_break_backedge_if_not_taken :: (lar: *Loop_Std_Results, l: Loop_Id) -> Ld_Result {
    li := lar.li;
    if li_loop_latch(li, l) == NONE return .UNMODIFIED;
    btc_max := sc_get_constant_max_backedge_taken_count(l);
    if !sc_is_zero(btc_max) {
        btc := sc_get_backedge_taken_count(l);
        if !sc_is_zero(btc) {
            if !sc_is_cnc(btc) && sc_is_known_non_zero(btc) return .UNMODIFIED;
            if !ld_can_prove_exit_on_first_iteration(li, l, lar.dt) return .UNMODIFIED;
        }
    }
    break_loop_backedge(l, lar.dt, li, lar.mssa);
    return .DELETED;
}

// deleteLoopIfDead
ld_delete_loop_if_dead :: (lar: *Loop_Std_Results, l: Loop_Id) -> Ld_Result {
    li := lar.li;
    preheader := li_loop_preheader(li, l);
    if preheader == NONE || !li_has_dedicated_exits(li, l) return .UNMODIFIED;
    exit_block := li_unique_exit_block(li, l);
    if exit_block != NONE && block_is_eh_pad(exit_block) return .UNMODIFIED;
    if exit_block != NONE && ld_is_loop_never_executed(li, l) {
        sc_forget_loop(l);
        for p: block_insts(exit_block) {
            if inst_op(p) != .PHI break;
            n := nops(p);
            if n > 0 for k: 0..n-1 phi_set_value(p, k, const_poison(vtype(p)));
        }
        delete_dead_loop(l, lar.dt, true, li, lar.mssa);
        return .DELETED;
    }
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    if exit_block == NONE && !li_has_no_exit_blocks(li, l) return .UNMODIFIED;
    changed := false;
    if !ld_is_loop_dead(li, l, exiting, exit_block, *changed, preheader)
        return ifx changed then Ld_Result.MODIFIED else .UNMODIFIED;
    delete_dead_loop(l, lar.dt, true, li, lar.mssa);
    return .DELETED;
}

// LoopDeletionPass::run
loop_deletion_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    result := ld_delete_loop_if_dead(lar, l);
    if result != .DELETED result = ld_merge(result, ld_break_backedge_if_not_taken(lar, l));
    if result == .UNMODIFIED return PRESERVE_ALL;
    if result == .DELETED lpm_mark_loop_as_deleted(u, l);
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}

// ---------------------------------------------------------------- LoopUtils.cpp

// deleteDeadLoop(L, DT, SE, LI, MSSA). `with_se`: the global `se` is the loop's ScalarEvolution.
delete_dead_loop :: (l: Loop_Id, dt: *Dom_Tree, with_se: bool, li: *Loop_Info, mssa: *Memory_SSA) {
    preheader := li_loop_preheader(li, l);
    assert(preheader != NONE, "Preheader should exist!");
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    if mssa { mssau_storage.mssa = mssa; mssau = *mssau_storage; }
    if with_se {
        sc_forget_loop(l);
        sc_forget_block_and_loop_dispositions();
    }
    old_term := block_terminator(preheader);
    b: Irb;
    irb_set_before(*b, old_term);
    header := li_header(li, l);
    exit_block := li_unique_exit_block(li, l);
    dtu: Dtu;
    dtu.dt = dt;
    if exit_block != NONE {
        irb_insert(*b, create_cond_br(const_false(), header, exit_block));
        erase_inst(old_term);
        for p: block_insts(exit_block) {
            if inst_op(p) != .PHI break;
            phi_set_block(p, 0, preheader);
            not_zero :: (p: Value_Id, idx: u32, data: *void) -> bool { return idx != 0; }
            phi_remove_incoming_if(p, not_zero, null, false);
        }
        if dt {
            up := Dom_Update.[.{true, preheader, exit_block}];
            dtu_apply(*dtu, up);
            if mssa {
                mssau_apply_updates(mssau, up, dt, false);
                if mssa_opts.verify mssa_verify(mssa);
            }
        }
        irb_set_before(*b, block_terminator(preheader));
        irb_insert(*b, create_br(exit_block));
        erase_inst(block_terminator(preheader));
    } else {
        irb_set_before(*b, old_term);
        irb_insert(*b, new_inst(.UNREACHABLE, ir.t_void, 0));
        erase_inst(block_terminator(preheader));
    }
    if dt {
        up := Dom_Update.[.{false, preheader, header}];
        dtu_apply(*dtu, up);
        if mssa {
            mssau_apply_updates(mssau, up, dt, false);
            dead: [..] Value_Id; dead.allocator = temp;
            for li_blocks(li, l) array_add(*dead, it);
            mssau_remove_blocks(mssau, dead);
            if mssa_opts.verify mssa_verify(mssa);
        }
    }
    // uses outside the loop (only in unreachable code) become poison; one debug record per variable moves to the exit
    seen_vars: Table(string, bool); seen_vars.allocator = temp;
    dead_records: [..] u32; dead_records.allocator = temp;
    for bb: li_blocks(li, l) for i: block_insts(bb) {
        u := ir.v_first_use[i];
        while u != NONE {
            nx := ir.u_next[u];
            usr := ir.u_user[u];
            if !(is_inst(usr) && li_contains(li, l, inst_block(usr))) use_set(u, const_poison(vtype(i)));
            u = nx;
        }
        if exit_block != NONE {
            r := inst(i).records;
            while r != 0 {
                nr := dbgr(r).next;
                if dbgr(r).kind != .LABEL {
                    key := dbg_variable_key(r, true);
                    if !table_contains(*seen_vars, key) {
                        table_set(*seen_vars, key, true);
                        dbgr_erase(r);   // removeFromParent
                        array_add(*dead_records, r);
                    }
                }
                r = nr;
            }
        }
    }
    if exit_block != NONE && dead_records.count {
        pt := block_first_insertion_pt(exit_block);
        assert(pt != NONE, "There should be a non-PHI instruction in exit block");
        // inserted one by one at the head of pt's records, in reverse: the original order, before pt's records
        for < dead_records {
            dbgr(it).next = inst(pt).records;
            dbgr(it).owner = pt;
            inst(pt).records = it;
        }
    }
    for bb: li_blocks(li, l) for i: block_insts(bb) drop_all_references(i);
    if mssa && mssa_opts.verify mssa_verify(mssa);
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, l) array_add(*blocks, it);
    for bb: blocks {
        li_remove_block(li, bb);
        erase_dead_block(bb);
    }
    parent := li_parent(li, l);
    if parent != NONE li_remove_child_loop(li, parent, l);
    else li_remove_top_level_loop(li, l);
    li_destroy_recursive(li, l);
}

// LoopInfo::destroy: ~LoopBase destroys the subloops too
li_destroy_recursive :: (li: *Loop_Info, l: Loop_Id) {
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(li, l) array_add(*subs, it);
    for subs li_destroy_recursive(li, it);
    li_destroy(li, l);
}

// BasicBlock::eraseFromParent after dropAllReferences: the instructions (and their debug records) go first
erase_dead_block :: (b: Value_Id) {
    while block_last(b) != NONE {
        i := block_last(b);
        while inst(i).records dbgr_erase(inst(i).records);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));   // users in other dead blocks
        erase_inst_with_metadata(i);
    }
    // ~BasicBlock: a blockaddress of the block becomes inttoptr (i32 1 to ptr)
    u := ir.v_first_use[b];
    while u != NONE {
        nx := ir.u_next[u];
        ba := ir.u_user[u];
        if vkind(ba) == .C_BLOCKADDR {
            replace_all_uses_with(ba, ce_cast(.INTTOPTR, const_int(ir.t_i32, 1), vtype(ba)));
            destroy_constant(ba);
        }
        u = nx;
    }
    if has_uses(b) fatal("loop-deletion: a deleted block is still used");
    f := block_fn(b);
    fn_unlink_block(f, b);
    if vname(b).count set_name(b, "");
    ir.v_kind[b] = .DEAD;
}

// breakLoopBackedge(L, DT, SE, LI, MSSA) with the global `se`
break_loop_backedge :: (l: Loop_Id, dt: *Dom_Tree, li: *Loop_Info, mssa: *Memory_SSA) {
    latch := li_loop_latch(li, l);
    header := li_header(li, l);
    outermost := li_outermost(li, l);
    sc_forget_loop(l);
    sc_forget_block_and_loop_dispositions();
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    if mssa { mssau_storage.mssa = mssa; mssau = *mssau_storage; }
    dtu: Dtu;
    dtu.dt = dt;
    bi := block_terminator(latch);
    done := false;
    if inst_op(bi) == .BR {
        change_to_unreachable(bi, true, mssau, *dtu);
        done = true;
    } else if inst_op(bi) == .CONDBR && li_is_loop_exiting(li, l, latch) {
        exit_idx: u32 = ifx li_contains(li, l, get_successor(bi, 0)) then cast(u32) 1 else 0;
        exit_bb := get_successor(bi, exit_idx);
        block_remove_predecessor(header, latch, true);
        b: Irb;
        irb_set_before(*b, bi);
        nbi := irb_insert(*b, create_br(exit_bb));
        // copyMetadata(*BI, {MD_dbg, MD_annotation})
        set_metadata(nbi, 0, get_metadata(bi, 0));
        a := get_metadata(bi, MD_ANNOTATION_KIND);
        if a != NONE set_metadata(nbi, MD_ANNOTATION_KIND, a);
        erase_inst(bi);
        up := Dom_Update.[.{false, latch, header}];
        dtu_apply(*dtu, up);
        if mssa mssau_apply_updates(mssau, up, dt, false);
        done = true;
    }
    if !done {
        // SplitEdge(Latch, Header, &DT, &LI, MSSAU)
        succ: u32 = 0;
        while get_successor(bi, succ) != header succ += 1;
        o: Crit_Edge_Options;
        o.dt = dt; o.li = li; o.mssau = mssau; o.preserve_lcssa = true;
        backedge_bb: Value_Id;
        if is_critical_edge(bi, succ, false) {
            backedge_bb = split_known_critical_edge(bi, succ, *o);
            if backedge_bb == NONE fatal("loop-deletion: could not split the backedge");
        } else if block_single_predecessor(header) != NONE {
            fatal("loop-deletion: SplitEdge through splitBlockBefore is not implemented yet");
        } else {
            // the latch has a single successor: split it at the bottom
            backedge_bb = split_block(latch, bi, dt, li, mssau);
        }
        change_to_unreachable(block_terminator(backedge_bb), true, mssau, *dtu);
    }
    li_erase(li, l);
    if outermost != l form_lcssa_recursively(li, outermost, dt);
}
