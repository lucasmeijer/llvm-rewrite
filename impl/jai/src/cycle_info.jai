// CycleInfo: the cycle forest of a function (also irreducible cycles).
// Port of llvm/include/llvm/ADT/GenericCycleImpl.h and GenericCycleInfo.h (GenericCycleInfoCompute::run/dfs,
// moveTopLevelCycleToNewParent, print) and llvm/lib/Analysis/CycleAnalysis.cpp (printer and verifier passes).
//
// A cycle is a row of `Cycle_Info.cycles` (Cycle_Id = row index). `blocks` is the SetVector (insertion order),
// `entries` the entry list ([0] = header), `children` the child vector, `top` the TopLevelCycle pointer.

Cycle_Id :: u32;

Cycle_Row :: struct {
    parent: Cycle_Id = NONE;
    top: Cycle_Id = NONE;
    depth: u32;
    entries: [..] Value_Id;
    blocks: [..] Value_Id;
    children: [..] Cycle_Id;
}

Cycle_Info :: struct {
    fn: Value_Id = NONE;
    cycles: [..] Cycle_Row;
    top_level: [..] Cycle_Id;
    block_map: Table(Value_Id, Cycle_Id);   // innermost cycle of a block
}

ci_free :: (ci: *Cycle_Info) {
    for * ci.cycles { array_free(it.entries); array_free(it.blocks); array_free(it.children); }
    array_free(ci.cycles); array_free(ci.top_level); deinit(*ci.block_map);
    free(ci);
}

ci_cycle_for :: (ci: *Cycle_Info, b: Value_Id) -> Cycle_Id {
    found, c := table_find(*ci.block_map, b);
    if found return c;
    return NONE;
}
ci_header :: inline (ci: *Cycle_Info, c: Cycle_Id) -> Value_Id { return ci.cycles[c].entries[0]; }
ci_is_entry :: (ci: *Cycle_Info, c: Cycle_Id, b: Value_Id) -> bool {
    for ci.cycles[c].entries if it == b return true;
    return false;
}
// contains(const GenericCycle *C): C is this cycle or a descendant
ci_contains_cycle :: (ci: *Cycle_Info, c: Cycle_Id, inner: Cycle_Id) -> bool {
    while inner != NONE {
        if inner == c return true;
        inner = ci.cycles[inner].parent;
    }
    return false;
}
ci_contains :: (ci: *Cycle_Info, c: Cycle_Id, b: Value_Id) -> bool {
    return ci_contains_cycle(ci, c, ci_cycle_for(ci, b));
}

// GenericCycleInfoCompute::run
ci_compute :: (f: Value_Id) -> *Cycle_Info {
    ci := New(Cycle_Info);
    ci.fn = f;
    Dfs_Info :: struct { start: u32; end: u32; }
    dfs: Table(Value_Id, Dfs_Info); dfs.allocator = temp;
    preorder: [..] Value_Id; preorder.allocator = temp;
    // dfs(F, EntryBlock)
    {
        tree_stack: [..] s64; tree_stack.allocator = temp;
        trav: [..] Value_Id; trav.allocator = temp;
        counter: u32 = 0;
        array_add(*trav, fn_entry(f));
        succs: [..] Value_Id; succs.allocator = temp;
        while trav.count {
            b := trav[trav.count - 1];
            info := table_find_pointer(*dfs, b);
            if !info { table_set(*dfs, b, .{}); info = table_find_pointer(*dfs, b); }
            if info.start == 0 {
                counter += 1;
                info.start = counter;
                array_add(*tree_stack, trav.count);
                block_successors(b, *succs);
                for succs array_add(*trav, it);
                array_add(*preorder, b);
            } else {
                if tree_stack[tree_stack.count - 1] == trav.count {
                    info.end = counter;
                    tree_stack.count -= 1;
                }
                trav.count -= 1;
            }
        }
    }
    get_dfs :: (dfs: *Table(Value_Id, Dfs_Info), b: Value_Id) -> Dfs_Info {
        found, d := table_find(dfs, b);
        if found return d;
        return .{};
    }
    is_ancestor :: (a: Dfs_Info, o: Dfs_Info) -> bool { return a.start <= o.start && o.end <= a.end; }

    work: [..] Value_Id; work.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    for < header: preorder {
        cand := get_dfs(*dfs, header);
        block_predecessors(header, *preds);
        for preds if is_ancestor(cand, get_dfs(*dfs, it)) array_add(*work, it);
        if work.count == 0 continue;

        nc := cast(Cycle_Id) ci.cycles.count;
        row: Cycle_Row;
        array_add(*ci.cycles, row);
        ci.cycles[nc].top = nc;
        array_add(*ci.cycles[nc].entries, header);
        array_add(*ci.cycles[nc].blocks, header);
        table_set(*ci.block_map, header, nc);

        process_preds :: (ci: *Cycle_Info, nc: Cycle_Id, b: Value_Id, cand: Dfs_Info, dfs: *Table(Value_Id, Dfs_Info), work: *[..] Value_Id) {
            pl: [..] Value_Id; pl.allocator = temp;
            block_predecessors(b, *pl);
            is_entry := false;
            for pl {
                pd := get_dfs(dfs, it);
                if is_ancestor(cand, pd) array_add(work, it);
                else if pd.start == 0 {}
                else is_entry = true;
            }
            if is_entry array_add(*ci.cycles[nc].entries, b);
        }

        while work.count {
            b := pop(*work);
            if b == header continue;
            bc := ci_cycle_for(ci, b);
            if bc != NONE {
                bp := ci.cycles[bc].top;
                if bp != nc {
                    // moveTopLevelCycleToNewParent(NewCycle, BlockParent)
                    tl := *ci.top_level;
                    for tl.* if it == bp {
                        tl.*[it_index] = tl.*[tl.count - 1];
                        tl.count -= 1;
                        break;
                    }
                    array_add(*ci.cycles[nc].children, bp);
                    ci.cycles[bp].parent = nc;
                    // depth_first(Child): set TopLevelCycle
                    st: [..] Cycle_Id; st.allocator = temp;
                    array_add(*st, bp);
                    while st.count {
                        x := pop(*st);
                        ci.cycles[x].top = nc;
                        for ci.cycles[x].children array_add(*st, it);
                    }
                    for ci.cycles[bp].blocks array_add(*ci.cycles[nc].blocks, it);   // insert_range (all new)
                    entries := ci.cycles[bp].entries;
                    for e: entries process_preds(ci, nc, e, cand, *dfs, *work);
                }
            } else {
                table_set(*ci.block_map, b, nc);
                array_add(*ci.cycles[nc].blocks, b);
                process_preds(ci, nc, b, cand, *dfs, *work);
            }
        }
        array_add(*ci.top_level, nc);
    }
    // fix top-level links and depths
    for t: ci.top_level {
        ci.cycles[t].parent = NONE;
        ci_update_depth(ci, t);
    }
    return ci;
}

ci_update_depth :: (ci: *Cycle_Info, c: Cycle_Id) {
    p := ci.cycles[c].parent;
    ci.cycles[c].depth = ifx p != NONE then ci.cycles[p].depth + 1 else 1;
    for ci.cycles[c].children ci_update_depth(ci, it);
}

// SSAContext::print(const BasicBlock *): the name, or the slot number
ci_block_name :: (b: Value_Id) -> string {
    if vname(b).count return vname(b);
    s := value_as_operand(b);
    if s.count && s[0] == #char "%" return slice(s, 1, s.count - 1);
    return s;
}

ci_print :: (ci: *Cycle_Info, sb: *String_Builder) {
    rec :: (ci: *Cycle_Info, c: Cycle_Id, sb: *String_Builder) {
        r := *ci.cycles[c];
        for 1..r.depth append(sb, "    ");
        print_to_builder(sb, "depth=%: entries(", r.depth);
        for r.entries { if it_index append(sb, " "); append(sb, ci_block_name(it)); }
        append(sb, ")");
        for r.blocks {
            if ci_is_entry(ci, c, it) continue;
            append(sb, " ");
            append(sb, ci_block_name(it));
        }
        append(sb, "\n");
        for r.children rec(ci, it, sb);
    }
    for ci.top_level rec(ci, it, sb);
}

// getTopLevelParentCycle(Block)
ci_top_level_parent :: (ci: *Cycle_Info, b: Value_Id) -> Cycle_Id {
    c := ci_cycle_for(ci, b);
    if c == NONE return NONE;
    return ci.cycles[c].top;
}
// GenericCycle::getExitBlocks: successors outside the cycle, first-seen order over blocks() and their successors
ci_exit_blocks :: (ci: *Cycle_Info, c: Cycle_Id, out: *[..] Value_Id) {
    succs: [..] Value_Id; succs.allocator = temp;
    exits: [..] Value_Id; exits.allocator = temp;
    for b: ci.cycles[c].blocks {
        block_successors(b, *succs);
        for s: succs {
            if ci_contains(ci, c, s) continue;
            dup := false;
            for exits if it == s { dup = true; break; }
            if !dup array_add(*exits, s);
        }
    }
    for exits array_add(out, it);
}
