// ADCE: port of llvm/lib/Transforms/Scalar/ADCE.cpp (AggressiveDeadCodeElimination).
// Debug-info parts (AliveScopes, dbg records, salvageDebugInfo) have nothing to act on until debug records are
// parsed; the !dbg scopes of live instructions only matter for dropping dbg records.

Adce_Block :: struct {
    live: bool;
    has_live_phis: bool;
    cf_live: bool;
    post_order: u32;
}

Adce :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    info: Table(Value_Id, Adce_Block);
    live: Table(Value_Id, bool);
    worklist: [..] Value_Id;
    // SmallSetVector<BasicBlock*> BlocksWithDeadTerminators
    dead_term_blocks: [..] Value_Id;
    dead_term_set: Table(Value_Id, bool);
    // SmallPtrSet<BasicBlock*> NewLiveBlocks (only iterated through the IDF calculator, as a set)
    new_live: [..] Value_Id;
    new_live_set: Table(Value_Id, bool);
}

adce_binfo :: (a: *Adce, b: Value_Id) -> *Adce_Block {
    p := table_find_pointer(*a.info, b);
    if p return p;
    e: Adce_Block;
    table_set(*a.info, b, e);
    return table_find_pointer(*a.info, b);
}
adce_is_live :: (a: *Adce, i: Value_Id) -> bool { return table_contains(*a.live, i); }

adce_new_live :: (a: *Adce, b: Value_Id) {
    if table_contains(*a.new_live_set, b) return;
    table_set(*a.new_live_set, b, true);
    array_add(*a.new_live, b);
}
adce_dead_term_remove :: (a: *Adce, b: Value_Id) {
    if !table_contains(*a.dead_term_set, b) return;
    table_remove(*a.dead_term_set, b);
    for a.dead_term_blocks if it == b { array_ordered_remove_by_index(*a.dead_term_blocks, it_index); break; }
}

adce_is_instruments_constant :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    callee := call_called_function(i);
    if callee == NONE return false;
    // getInstrProfValueProfFuncName()
    if vname(callee) != "__llvm_profile_instrument_target" return false;
    return is_constant_kind(vkind(call_arg(i, 0)));
}

adce_is_always_live :: (i: Value_Id) -> bool {
    if is_eh_pad(i) || may_have_side_effects(i) {
        if adce_is_instruments_constant(i) return false;
        return true;
    }
    opc := inst_op(i);
    if !is_terminator(opc) return false;
    if opts.adce_remove_control_flow && (opc == .BR || opc == .CONDBR || opc == .SWITCH) return false;
    return true;
}

adce_mark_live_block :: (a: *Adce, b: Value_Id) {
    bi := adce_binfo(a, b);
    if bi.live return;
    bi.live = true;
    if !bi.cf_live {
        bi.cf_live = true;
        adce_new_live(a, b);
    }
    l := block(b).last;
    if l != NONE && inst_op(l) == .BR adce_mark_live(a, l);
}

adce_mark_live :: (a: *Adce, i: Value_Id) {
    if table_contains(*a.live, i) return;
    table_set(*a.live, i, true);
    array_add(*a.worklist, i);
    b := inst_block(i);
    if i == block(b).last {
        adce_dead_term_remove(a, b);
        if inst_op(i) != .BR {
            n := num_successors(i);
            if n > 0 for k: 0..n-1 adce_mark_live_block(a, get_successor(i, k));
        }
    }
    adce_mark_live_block(a, b);
}

adce_mark_phi_live :: (a: *Adce, p: Value_Id) {
    b := inst_block(p);
    bi := adce_binfo(a, b);
    if bi.has_live_phis return;
    bi.has_live_phis = true;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(b, *preds);
    for pb: preds {
        pi := adce_binfo(a, pb);
        if !pi.cf_live {
            pi.cf_live = true;
            adce_new_live(a, pb);
        }
    }
}

adce_initialize :: (a: *Adce) {
    for fn_insts(a.f) if adce_is_always_live(it) adce_mark_live(a, it);
    if !opts.adce_remove_control_flow return;
    if !opts.adce_remove_loops {
        backedges: [..] Block_Edge; backedges.allocator = temp;
        find_function_backedges(a.f, *backedges);
        for backedges adce_mark_live(a, block_terminator(it.from));
    }
    // Mark blocks live if there is no path from the block to a return of the function (children of the PDT root
    // that aren't returns; all of their post-dominated blocks).
    pdt := a.pdt;
    c := pdt.nodes[pdt.root_node].first_child;
    while c >= 0 {
        bb := pdt.nodes[c].block;
        if inst_op(block(bb).last) != .RET {
            // depth_first(PDTChild): preorder over the tree
            stack: [..] s32; stack.allocator = temp;
            array_add(*stack, c);
            while stack.count {
                n := pop(*stack);
                adce_mark_live(a, block(pdt.nodes[n].block).last);
                kids: [..] s32; kids.allocator = temp;
                k := pdt.nodes[n].first_child;
                while k >= 0 { array_add(*kids, k); k = pdt.nodes[k].sibling; }
                j := kids.count;
                while j > 0 { j -= 1; array_add(*stack, kids[j]); }
            }
        }
        c = pdt.nodes[c].sibling;
    }
    entry := fn_entry(a.f);
    adce_binfo(a, entry).live = true;
    if inst_op(block(entry).last) == .BR adce_mark_live(a, block(entry).last);
    for b: fn_blocks(a.f) {
        if !adce_is_live(a, block(b).last) {
            if !table_contains(*a.dead_term_set, b) {
                table_set(*a.dead_term_set, b, true);
                array_add(*a.dead_term_blocks, b);
            }
        }
    }
}

adce_mark_live_branches_from_control_dependences :: (a: *Adce) {
    if a.dead_term_blocks.count == 0 return;
    bwdt: Table(Value_Id, bool); bwdt.allocator = temp;
    for a.dead_term_blocks table_set(*bwdt, it, true);
    idf: [..] Value_Id; idf.allocator = temp;
    // ReverseIDFCalculator over the PDT; the defining blocks are a SmallPtrSet, whose iteration order only feeds
    // a priority queue keyed by (level, DFSIn).
    idf_calculate(a.pdt, a.new_live, *a.new_live_set, *bwdt, *idf);
    a.new_live.count = 0;
    table_reset(*a.new_live_set);
    for idf adce_mark_live(a, block_terminator(it));
}

adce_mark_live_instructions :: (a: *Adce) {
    while true {
        while a.worklist.count {
            li := pop(*a.worklist);
            n := nops(li);
            if n > 0 for k: 0..n-1 {
                o := op(li, k);
                if is_inst(o) adce_mark_live(a, o);
            }
            if inst_op(li) == .PHI adce_mark_phi_live(a, li);
        }
        adce_mark_live_branches_from_control_dependences(a);
        if a.worklist.count == 0 break;
    }
}

// computeReversePostOrder: inverse post order from every block without successors
adce_compute_reverse_post_order :: (a: *Adce) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    po: u32 = 0;
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: fn_blocks(a.f) {
        if block_num_successors(bb) != 0 continue;
        // inverse_post_order_ext(&BB, Visited): po_iterator over Inverse<BasicBlock*> with an external set
        if table_contains(*visited, bb) continue;
        Frame :: struct { b: Value_Id; preds: [..] Value_Id; next: s64; }
        stack: [..] Frame; stack.allocator = temp;
        table_set(*visited, bb, true);
        fr: Frame; fr.b = bb; fr.preds.allocator = temp; block_predecessors(bb, *fr.preds);
        array_add(*stack, fr);
        while stack.count {
            top := *stack[stack.count - 1];
            if top.next < top.preds.count {
                p := top.preds[top.next];
                top.next += 1;
                if !table_contains(*visited, p) {
                    table_set(*visited, p, true);
                    nf: Frame; nf.b = p; nf.preds.allocator = temp; block_predecessors(p, *nf.preds);
                    array_add(*stack, nf);
                }
                continue;
            }
            adce_binfo(a, top.b).post_order = po;
            po += 1;
            stack.count -= 1;
        }
    }
}

adce_make_unconditional :: (a: *Adce, bb: Value_Id, target: Value_Id) {
    term := block_terminator(bb);
    if inst_op(term) == .BR {
        set_successor(term, 0, target);
        table_set(*a.live, term, true);
        return;
    }
    nt := create_br(target);
    inst_insert_before(nt, term);
    table_set(*a.live, nt, true);
    copy_debug_loc(nt, term);
    drop_all_references(term);
    erase_inst(term);
}

adce_update_dead_regions :: (a: *Adce) -> bool {
    have_po := false;
    changed := false;
    deleted: [..] Dom_Update; deleted.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: a.dead_term_blocks {
        last := block(bb).last;
        if inst_op(last) == .BR { table_set(*a.live, last, true); continue; }
        if !have_po { adce_compute_reverse_post_order(a); have_po = true; }
        preferred: Value_Id = NONE;
        preferred_po: u32 = 0;
        block_successors(bb, *succs);
        for s: succs {
            spo := adce_binfo(a, s).post_order;
            if preferred_po < spo { preferred = s; preferred_po = spo; }
        }
        assert(preferred != NONE && preferred_po > 0, "Failed to find safe successor for dead branch");
        removed: [..] Value_Id; removed.allocator = temp;   // SmallPtrSet: iterated below
        first := true;
        for s: succs {
            if !first || s != preferred {
                block_remove_predecessor(s, bb);
                found := false;
                for removed if it == s { found = true; break; }
                if !found array_add(*removed, s);
            } else first = false;
        }
        adce_make_unconditional(a, bb, preferred);
        for s: removed if s != preferred array_add(*deleted, .{false, bb, s});
        changed = true;
    }
    if deleted.count {
        if a.dt dt_apply_updates(a.dt, deleted);
        dt_apply_updates(a.pdt, deleted);
    }
    return changed;
}

Adce_Changed :: struct { anything: bool; non_debug: bool; control_flow: bool; }

adce_remove_dead_instructions :: (a: *Adce) -> Adce_Changed {
    ch: Adce_Changed;
    ch.control_flow = adce_update_dead_regions(a);
    a.worklist.count = 0;
    for :reverse_early_inc fn_insts(a.f) {
        if adce_is_live(a, it) continue;
        ch.non_debug = true;
        array_add(*a.worklist, it);
    }
    for a.worklist drop_all_references(it);
    for a.worklist erase_inst(it);
    ch.anything = ch.control_flow || a.worklist.count > 0;
    return ch;
}

adce_run :: (f: Value_Id) -> Preserved {
    a: Adce;
    a.f = f;
    a.info.allocator = temp; a.live.allocator = temp; a.worklist.allocator = temp;
    a.dead_term_blocks.allocator = temp; a.dead_term_set.allocator = temp;
    a.new_live.allocator = temp; a.new_live_set.allocator = temp;
    a.dt = cached_domtree(f);
    a.pdt = get_postdomtree(f);
    adce_initialize(*a);
    adce_mark_live_instructions(*a);
    ch := adce_remove_dead_instructions(*a);
    if !ch.anything return PRESERVE_ALL;
    pa: Preserved;
    if !ch.control_flow pa.cfg = true;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .POSTDOMTREE);
    return pa;
}
