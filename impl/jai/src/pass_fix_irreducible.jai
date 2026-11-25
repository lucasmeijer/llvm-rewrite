// FixIrreduciblePass: a port of llvm/lib/Transforms/Utils/FixIrreducible.cpp (complete; the ControlFlowHub,
// SplitCallBrEdge and the CycleInfo updates are in control_flow_utils.jai).

// std::partition (libstdc++'s bidirectional __partition: the order of both halves is what LLVM's build produces)
fi_partition :: (v: [] Loop_Id, pred: (l: Loop_Id, data: *void) -> bool, data: *void) -> s64 {
    first := 0; last := v.count;
    while true {
        while true {
            if first == last return first;
            if pred(v[first], data) first += 1;
            else break;
        }
        last -= 1;
        while true {
            if first == last return first;
            if !pred(v[last], data) last -= 1;
            else break;
        }
        v[first], v[last] = v[last], v[first];
        first += 1;
    }
    return first;
}

// reconnectChildLoops
fi_reconnect_child_loops :: (li: *Loop_Info, parent_loop: Loop_Id, new_loop: Loop_Id, old_header: Value_Id) {
    candidates := ifx parent_loop != NONE then *li.loops[parent_loop].subloops else *li.top_level;
    Ctx :: struct { li: *Loop_Info; new_loop: Loop_Id; }
    ctx := Ctx.{li, new_loop};
    pred :: (l: Loop_Id, data: *void) -> bool {
        c := cast(*Ctx) data;
        return c.new_loop == l || !li_contains(c.li, c.new_loop, li_header(c.li, l));
    }
    first_child := fi_partition(candidates.*, pred, *ctx);
    child_loops: [..] Loop_Id; child_loops.allocator = temp;
    for k: first_child..candidates.count - 1 array_add(*child_loops, candidates.*[k]);
    candidates.count = first_child;
    for child: child_loops {
        if li_header(li, child) == old_header {
            for bb: li.loops[child].blocks {
                if li_loop_for(li, bb) != child continue;
                li_change_loop_for(li, bb, new_loop);
            }
            grand: [..] Loop_Id; grand.allocator = temp;
            for li.loops[child].subloops array_add(*grand, it);
            li.loops[child].subloops.count = 0;
            for g: grand {
                li.loops[g].parent = NONE;
                li_add_child_loop(li, new_loop, g);
            }
            li_destroy(li, child);
            continue;
        }
        li.loops[child].parent = NONE;
        li_add_child_loop(li, new_loop, child);
    }
}

// updateLoopInfo
fi_update_loop_info :: (li: *Loop_Info, ci: *Cycle_Info, c: Cycle_Id, guard_blocks: [] Value_Id) {
    cycle_header := ci_header(ci, c);
    parent_loop := li_loop_for(li, cycle_header);
    if parent_loop != NONE && li_header(li, parent_loop) == cycle_header parent_loop = li_parent(li, parent_loop);
    new_loop := li_alloc_loop(li);
    if parent_loop != NONE li_add_child_loop(li, parent_loop, new_loop);
    else li_add_top_level_loop(li, new_loop);
    for g: guard_blocks li_add_basic_block_to_loop(li, new_loop, g);
    for bb: ci.cycles[c].blocks {
        li_add_block_entry(li, new_loop, bb);
        if li_loop_for(li, bb) == parent_loop li_change_loop_for(li, bb, new_loop);
    }
    fi_reconnect_child_loops(li, parent_loop, new_loop, cycle_header);
}

// fixIrreducible
fi_fix_irreducible :: (c: Cycle_Id, ci: *Cycle_Info, dt: *Dom_Tree, li: *Loop_Info) -> bool {
    if ci.cycles[c].entries.count == 1 return false;   // isReducible
    hub: Cfh;
    preds: [..] Value_Id; preds.allocator = temp;
    pl: [..] Value_Id; pl.allocator = temp;
    add_unique :: (o: *[..] Value_Id, b: Value_Id) { for o.* if it == b return; array_add(o, b); }
    header := ci_header(ci, c);
    block_predecessors(header, *pl);
    for p: pl if ci_contains(ci, c, p) add_unique(*preds, p);
    unsupported :: () { fatal("unsupported block terminator: fix-irreducible only supports br and callbr instructions"); }
    for p: preds {
        t := block_terminator(p);
        if inst_op(t) == .BR {
            cfh_add_branch(*hub, p, header);
        } else if inst_op(t) == .CONDBR {
            s0 := ifx get_successor(t, 0) == header then header else NONE;
            s1 := ifx get_successor(t, 1) == header then header else NONE;
            cfh_add_branch(*hub, p, s0, s1);
        } else if inst_op(t) == .CALLBR {
            new_succ: Value_Id = NONE;
            n := num_successors(t);
            for i: 0..n - 1 {
                succ := get_successor(t, i);
                if succ != header continue;
                new_succ = split_call_br_edge(p, succ, i, new_succ, dt, ci, li);
            }
            if new_succ != NONE cfh_add_branch(*hub, new_succ, header);
        } else unsupported();
    }
    preds.count = 0;
    entries: [..] Value_Id; entries.allocator = temp;
    for ci.cycles[c].entries array_add(*entries, it);
    for e: entries {
        block_predecessors(e, *pl);
        for p: pl if !ci_contains(ci, c, p) add_unique(*preds, p);
    }
    for p: preds {
        t := block_terminator(p);
        if inst_op(t) == .BR {
            s0 := get_successor(t, 0);
            if !ci_contains(ci, c, s0) s0 = NONE;
            cfh_add_branch(*hub, p, s0);
        } else if inst_op(t) == .CONDBR {
            s0 := get_successor(t, 0);
            if !ci_contains(ci, c, s0) s0 = NONE;
            s1 := get_successor(t, 1);
            if !ci_contains(ci, c, s1) s1 = NONE;
            cfh_add_branch(*hub, p, s0, s1);
        } else if inst_op(t) == .CALLBR {
            Pair :: struct { succ: Value_Id; target: Value_Id; }
            targets: [..] Pair; targets.allocator = temp;
            n := num_successors(t);
            for i: 0..n - 1 {
                succ := get_successor(t, i);
                if !ci_contains(ci, c, succ) continue;
                existing: Value_Id = NONE;
                for targets if it.succ == succ { existing = it.target; break; }
                new_succ := split_call_br_edge(p, succ, i, existing, dt, ci, li);
                if existing == NONE {
                    cfh_add_branch(*hub, new_succ, succ);
                    array_add(*targets, .{succ, new_succ});
                }
            }
        } else unsupported();
    }
    guard_blocks: [..] Value_Id; guard_blocks.allocator = temp;
    cfh_finalize(*hub, dt, *guard_blocks, "irr");
    if li fi_update_loop_info(li, ci, c, guard_blocks);
    for g: guard_blocks ci_add_block_to_cycle(ci, g, c);
    // setSingleEntry
    ci.cycles[c].entries.count = 0;
    array_add(*ci.cycles[c].entries, guard_blocks[0]);
    return true;
}

fix_irreducible_run :: (f: Value_Id) -> Preserved {
    li := cached_loop_info(f);
    ci := get_cycle_info(f);
    dt := get_domtree(f);
    changed := false;
    tops: [..] Cycle_Id; tops.allocator = temp;
    for ci.top_level array_add(*tops, it);
    for top: tops {
        // depth_first(TopCycle): preorder, children in order
        stack: [..] Cycle_Id; stack.allocator = temp;
        array_add(*stack, top);
        while stack.count {
            c := pop(*stack);
            changed |= fi_fix_irreducible(c, ci, dt, li);
            ch := ci.cycles[c].children;
            for < ch array_add(*stack, it);
        }
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .LOOPS);
    preserve(*pa, .CYCLES);
    preserve(*pa, .DOMTREE);
    return pa;
}
