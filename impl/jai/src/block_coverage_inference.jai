// BlockCoverageInference (pgo-instr-gen -pgo-block-coverage): the minimal set of blocks to instrument for block
// coverage. Ported from llvm/lib/Transforms/Instrumentation/BlockCoverageInference.cpp (findDependencies,
// getReachableAvoiding, shouldInstrumentBlock, getInstrumentedBlocksHash). The BlockSets are SmallSetVectors:
// insertion-ordered arrays here. The graph view and dump are not ported.

Bci :: struct {
    blocks: [..] Value_Id;                 // F's blocks in order
    index: Table(Value_Id, s64);
    pred_deps: [..] [..] Value_Id;         // PredecessorDependencies (by block index)
    succ_deps: [..] [..] Value_Id;         // SuccessorDependencies
}

bci_set_insert :: (s: *[..] Value_Id, b: Value_Id) { for s.* if it == b return; array_add(s, b); }
bci_set_contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }

// depth_first_ext / inverse_depth_first_ext from start, with `visited` pre-seeded (the avoided block)
bci_dfs :: (start: Value_Id, forward: bool, visited: *Table(Value_Id, bool), out: *[..] Value_Id) {
    if table_contains(visited, start) return;
    table_set(visited, start, true);
    if out array_add(out, start);
    stack: [..] Value_Id; stack.allocator = temp;
    array_add(*stack, start);
    tmp: [..] Value_Id; tmp.allocator = temp;
    while stack.count {
        b := pop(*stack);
        tmp.count = 0;
        if forward block_successors(b, *tmp); else block_predecessors(b, *tmp);
        for tmp if !table_contains(visited, it) {
            table_set(visited, it, true);
            if out array_add(out, it);
            array_add(*stack, it);
        }
    }
}

// getReachableAvoiding (the reachable set's order is not observable: it is only queried)
bci_reachable_avoiding :: (start: Value_Id, avoid: Value_Id, forward: bool, reachable: *Table(Value_Id, bool)) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    table_set(*visited, avoid, true);
    if start == avoid return;
    bci_dfs(start, forward, *visited, null);
    for v, k: visited if k != avoid table_set(reachable, k, true);
}

// BlockCoverageInference(F, ForceInstrumentEntry)
bci_init :: (c: *Bci, f: Value_Id, force_instrument_entry: bool) {
    c.blocks.allocator = temp; c.index.allocator = temp; c.pred_deps.allocator = temp; c.succ_deps.allocator = temp;
    for b: fn_blocks(f) { table_set(*c.index, b, c.blocks.count); array_add(*c.blocks, b); }
    n := c.blocks.count;
    array_resize(*c.pred_deps, n); array_resize(*c.succ_deps, n);
    for * c.pred_deps it.allocator = temp;
    for * c.succ_deps it.allocator = temp;
    bci_find_dependencies(c, f, force_instrument_entry);
}

bci_idx :: (c: *Bci, b: Value_Id) -> s64 { _, k := table_find(*c.index, b); return k; }

// findDependencies
bci_find_dependencies :: (c: *Bci, f: Value_Id, force_instrument_entry: bool) {
    if fn_has_fn_attr(f, .NoReturn) || c.blocks.count > 1500 return;
    terminal: [..] Value_Id; terminal.allocator = temp;
    tmp: [..] Value_Id; tmp.allocator = temp;
    for b: c.blocks if num_successors(block_terminator(b)) == 0 array_add(*terminal, b);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    for b: terminal bci_dfs(b, false, *visited, null);
    if visited.count != c.blocks.count return;
    entry := c.blocks[0];
    preds: [..] Value_Id; preds.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for bb, bi: c.blocks {
        from_entry: Table(Value_Id, bool); from_entry.allocator = temp;
        from_terminal: Table(Value_Id, bool); from_terminal.allocator = temp;
        bci_reachable_avoiding(entry, bb, true, *from_entry);
        for t: terminal bci_reachable_avoiding(t, bb, false, *from_terminal);
        preds.count = 0; block_predecessors(bb, *preds);
        super_pred := false;
        for p: preds if table_contains(*from_entry, p) && table_contains(*from_terminal, p) { super_pred = true; break; }
        if !super_pred for p: preds if table_contains(*from_entry, p) bci_set_insert(*c.pred_deps[bi], p);
        succs.count = 0; block_successors(bb, *succs);
        super_succ := false;
        for s: succs if table_contains(*from_entry, s) && table_contains(*from_terminal, s) { super_succ = true; break; }
        if !super_succ for s: succs if table_contains(*from_terminal, s) bci_set_insert(*c.succ_deps[bi], s);
    }
    if force_instrument_entry { c.pred_deps[0].count = 0; c.succ_deps[0].count = 0; }
    adj := NewArray(c.blocks.count, [..] Value_Id,, allocator = temp);
    for * adj it.allocator = temp;
    for bb, bi: c.blocks {
        succs.count = 0; block_successors(bb, *succs);
        for s: succs {
            si := bci_idx(c, s);
            if bci_set_contains(c.succ_deps[bi], s) && bci_set_contains(c.pred_deps[si], bb) {
                bci_set_insert(*adj[bi], s);
                bci_set_insert(*adj[si], bb);
            }
        }
    }
    for bb, bi: c.blocks {
        if adj[bi].count != 1 continue;
        path: [..] Value_Id; path.allocator = temp;
        array_add(*path, bb);
        while true {
            // getNextOnPath
            nb := adj[bci_idx(c, path[path.count - 1])];
            next: Value_Id = NONE;
            if path.count == 1 next = nb[0];
            else if nb.count == 2 next = ifx bci_set_contains(path, nb[0]) then nb[1] else nb[0];
            if next == NONE break;
            bci_set_insert(*path, next);
        }
        for path adj[bci_idx(c, it)].count = 0;
        if c.pred_deps[bci_idx(c, path[0])].count {
            for path if it != path[path.count - 1] c.succ_deps[bci_idx(c, it)].count = 0;
        } else {
            for path if it != path[0] c.pred_deps[bci_idx(c, it)].count = 0;
        }
    }
}

// shouldInstrumentBlock
bci_should_instrument_block :: (c: *Bci, b: Value_Id) -> bool {
    k := bci_idx(c, b);
    return c.pred_deps[k].count == 0 && c.succ_deps[k].count == 0;
}

// getInstrumentedBlocksHash
bci_instrumented_blocks_hash :: (c: *Bci) -> u64 {
    crc: u32 = 0xFFFF_FFFF;
    for b, k: c.blocks {
        if !bci_should_instrument_block(c, b) continue;
        d: [8] u8;
        for j: 0..7 d[j] = cast(u8) ((cast(u64) k >> (j * 8)) & 0xFF);
        crc = jam_crc_update(crc, d);
    }
    return crc;
}
