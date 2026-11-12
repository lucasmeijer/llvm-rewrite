// LoopInfo: natural loops of a function.
// Port of llvm/include/llvm/Support/GenericLoopInfo.h and GenericLoopInfoImpl.h (LoopBase, LoopInfoBase:
// analyze = discoverAndMapSubloop + PopulateLoopsDFS, the exit/latch/preheader queries, the update API, print)
// and llvm/lib/Analysis/LoopInfo.cpp (Loop::getLoopID, isAnnotatedParallel, isLoopSimplifyForm, isLCSSAForm,
// LoopInfo::erase, LoopPrinterPass).
//
// Data-oriented: a loop is a row of `Loop_Info.loops` (Loop_Id = row index, never reused); the block vector and
// subloop vector are per-row arrays in LLVM's order (Blocks[0] is the header). LLVM's per-loop DenseBlockSet is
// one table keyed by (loop, block) (`li_contains`), the BBMap (innermost loop of a block) is `loop_of`.

Loop_Id :: u32;

Loop_Row :: struct {
    parent: Loop_Id = NONE;
    blocks: [..] Value_Id;      // Blocks: [0] = header, then RPO when computed by analyze
    subloops: [..] Loop_Id;     // SubLoops, program order
    dead: bool;                 // destroyed (LoopInfo::erase / destroy); the id stays valid for comparisons
}

Loop_Info :: struct {
    fn: Value_Id = NONE;
    loops: [..] Loop_Row;
    top_level: [..] Loop_Id;    // TopLevelLoops: reverse program order after analyze
    loop_of: Table(Value_Id, Loop_Id);
    member: Table(u64, bool);   // DenseBlockSet of every loop: key (loop << 32) | block
}

li_key :: inline (l: Loop_Id, b: Value_Id) -> u64 { return ((cast(u64) l) << 32) | cast(u64) b; }

li_new :: (f: Value_Id) -> *Loop_Info {
    li := New(Loop_Info);
    li.fn = f;
    return li;
}
li_free :: (li: *Loop_Info) {
    for * li.loops { array_free(it.blocks); array_free(it.subloops); }
    array_free(li.loops); array_free(li.top_level);
    deinit(*li.loop_of); deinit(*li.member);
    free(li);
}

// ---------------------------------------------------------------- basic accessors

li_loop :: inline (li: *Loop_Info, l: Loop_Id) -> *Loop_Row { return *li.loops[l]; }
li_header :: inline (li: *Loop_Info, l: Loop_Id) -> Value_Id { return li.loops[l].blocks[0]; }
li_parent :: inline (li: *Loop_Info, l: Loop_Id) -> Loop_Id { return li.loops[l].parent; }
li_blocks :: inline (li: *Loop_Info, l: Loop_Id) -> [] Value_Id { return li.loops[l].blocks; }
li_subloops :: inline (li: *Loop_Info, l: Loop_Id) -> [] Loop_Id { return li.loops[l].subloops; }
li_num_blocks :: inline (li: *Loop_Info, l: Loop_Id) -> int { return li.loops[l].blocks.count; }
li_is_innermost :: inline (li: *Loop_Info, l: Loop_Id) -> bool { return li.loops[l].subloops.count == 0; }
li_is_outermost :: inline (li: *Loop_Info, l: Loop_Id) -> bool { return li.loops[l].parent == NONE; }

// getLoopDepth: 1 for top-level loops
li_depth :: (li: *Loop_Info, l: Loop_Id) -> u32 {
    d: u32 = 1;
    p := li.loops[l].parent;
    while p != NONE { d += 1; p = li.loops[p].parent; }
    return d;
}
li_outermost :: (li: *Loop_Info, l: Loop_Id) -> Loop_Id {
    while li.loops[l].parent != NONE l = li.loops[l].parent;
    return l;
}

// getLoopFor(BB): innermost loop containing BB, or NONE
li_loop_for :: (li: *Loop_Info, b: Value_Id) -> Loop_Id {
    found, l := table_find(*li.loop_of, b);
    if found return l;
    return NONE;
}
// getLoopDepth(BB): 0 if not in a loop
li_block_depth :: (li: *Loop_Info, b: Value_Id) -> u32 {
    l := li_loop_for(li, b);
    if l == NONE return 0;
    return li_depth(li, l);
}
li_is_loop_header :: (li: *Loop_Info, b: Value_Id) -> bool {
    l := li_loop_for(li, b);
    return l != NONE && li_header(li, l) == b;
}

// contains(BB): DenseBlockSet lookup
li_contains :: inline (li: *Loop_Info, l: Loop_Id, b: Value_Id) -> bool { return table_contains(*li.member, li_key(l, b)); }
// contains(const LoopT *L): L is this loop or nested in it
li_contains_loop :: (li: *Loop_Info, l: Loop_Id, inner: Loop_Id) -> bool {
    if inner == l return true;
    if inner == NONE return false;
    return li_contains_loop(li, l, li.loops[inner].parent);
}
// contains(Instruction *)
li_contains_inst :: inline (li: *Loop_Info, l: Loop_Id, i: Value_Id) -> bool { return li_contains(li, l, inst_block(i)); }

// changeLoopFor(BB, L): L == NONE removes the mapping
li_change_loop_for :: (li: *Loop_Info, b: Value_Id, l: Loop_Id) {
    if l == NONE table_remove(*li.loop_of, b);
    else table_set(*li.loop_of, b, l);
}

// addBlockEntry
li_add_block_entry :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) {
    array_add(*li.loops[l].blocks, b);
    table_set(*li.member, li_key(l, b), true);
}

li_alloc_loop :: (li: *Loop_Info, header: Value_Id = NONE) -> Loop_Id {
    id := cast(Loop_Id) li.loops.count;
    row: Loop_Row;
    array_add(*li.loops, row);
    if header != NONE li_add_block_entry(li, id, header);   // Loop(BB) constructor
    return id;
}

// ---------------------------------------------------------------- analyze (GenericLoopInfoImpl.h)

// post_order(Entry) over successors, as po_iterator visits them (with a visited set)
cfg_post_order :: (entry: Value_Id, out: *[..] Value_Id) {
    Frame :: struct { b: Value_Id; next: u32; n: u32; }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, entry, true);
    array_add(*stack, .{entry, 0, block_num_successors(entry)});
    while stack.count {
        top := *stack[stack.count - 1];
        if top.next < top.n {
            s := get_successor(block_terminator(top.b), top.next);
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                array_add(*stack, .{s, 0, block_num_successors(s)});
            }
            continue;
        }
        array_add(out, top.b);
        stack.count -= 1;
    }
}

li_discover_and_map_subloop :: (li: *Loop_Info, l: Loop_Id, backedges: [] Value_Id, dt: *Dom_Tree) {
    work: [..] Value_Id; work.allocator = temp;
    for backedges array_add(*work, it);
    preds: [..] Value_Id; preds.allocator = temp;
    header := li_header(li, l);
    while work.count {
        pred_bb := pop(*work);
        sub := li_loop_for(li, pred_bb);
        if sub == NONE {
            if !dt_is_reachable_from_entry(dt, pred_bb) continue;
            li_change_loop_for(li, pred_bb, l);
            if pred_bb == header continue;
            block_predecessors(pred_bb, *preds);
            for preds array_add(*work, it);
        } else {
            sub = li_outermost(li, sub);
            if sub == l continue;
            li.loops[sub].parent = l;
            pred_bb = li_header(li, sub);
            block_predecessors(pred_bb, *preds);
            for preds if li_loop_for(li, it) != sub array_add(*work, it);
        }
    }
}

li_insert_into_loop :: (li: *Loop_Info, b: Value_Id) {
    sub := li_loop_for(li, b);
    if sub != NONE && b == li_header(li, sub) {
        p := li.loops[sub].parent;
        if p != NONE array_add(*li.loops[p].subloops, sub);
        else array_add(*li.top_level, sub);
        // reverseBlock(1) and reverse the subloops
        bl := li.loops[sub].blocks;
        i := 1; j := bl.count - 1;
        while i < j { t := bl[i]; bl[i] = bl[j]; bl[j] = t; i += 1; j -= 1; }
        sl := li.loops[sub].subloops;
        i = 0; j = sl.count - 1;
        while i < j { t := sl[i]; sl[i] = sl[j]; sl[j] = t; i += 1; j -= 1; }
        sub = p;
    }
    while sub != NONE {
        li_add_block_entry(li, sub, b);
        sub = li.loops[sub].parent;
    }
}

// LoopInfoBase::analyze
li_analyze :: (li: *Loop_Info, dt: *Dom_Tree) {
    dt_update_dfs_numbers(dt);
    if dt.root_node < 0 return;
    // preorder of the dominator tree (= DFSNumIn order)
    pre: [..] s32; pre.allocator = temp;
    stack: [..] s32; stack.allocator = temp;
    array_add(*stack, dt.root_node);
    while stack.count {
        n := pop(*stack);
        array_add(*pre, n);
        // push children in reverse so the first child is visited first
        first := stack.count;
        c := dt.nodes[n].first_child;
        while c >= 0 { array_add(*stack, c); c = dt.nodes[c].sibling; }
        i := first; j := stack.count - 1;
        while i < j { t := stack[i]; stack[i] = stack[j]; stack[j] = t; i += 1; j -= 1; }
    }
    preds: [..] Value_Id; preds.allocator = temp;
    backedges: [..] Value_Id; backedges.allocator = temp;
    for < k: 0..pre.count-1 {
        node := pre[k];
        header := dt.nodes[node].block;
        backedges.count = 0;
        block_predecessors(header, *preds);
        for preds {
            bn := dt_node(dt, it);
            if bn >= 0 && dt_dominates_nodes(dt, node, bn) array_add(*backedges, it);
        }
        if backedges.count {
            l := li_alloc_loop(li, header);
            li_discover_and_map_subloop(li, l, backedges, dt);
        }
    }
    // PopulateLoopsDFS::traverse
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(dt.nodes[dt.root_node].block, *po);
    for po li_insert_into_loop(li, it);
}

// ---------------------------------------------------------------- queries (GenericLoopInfoImpl.h)

// getExitingBlocks
li_exiting_blocks :: (li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    for b: li.loops[l].blocks {
        t := block_terminator(b);
        if t == NONE continue;
        n := num_successors(t);
        if n > 0 for k: 0..n-1 if !li_contains(li, l, get_successor(t, k)) { array_add(out, b); break; }
    }
}
// getExitingBlock: the single exiting block or NONE
li_exiting_block :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    r: Value_Id = NONE;
    for b: li.loops[l].blocks {
        if li_is_loop_exiting(li, l, b) {
            if r != NONE return NONE;
            r = b;
        }
    }
    return r;
}
// isLoopExiting(BB)
li_is_loop_exiting :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) -> bool {
    t := block_terminator(b);
    if t == NONE return false;
    n := num_successors(t);
    if n > 0 for k: 0..n-1 if !li_contains(li, l, get_successor(t, k)) return true;
    return false;
}
// getExitBlocks (with duplicates)
li_exit_blocks :: (li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    for b: li.loops[l].blocks {
        t := block_terminator(b);
        if t == NONE continue;
        n := num_successors(t);
        if n > 0 for k: 0..n-1 { s := get_successor(t, k); if !li_contains(li, l, s) array_add(out, s); }
    }
}
// getUniqueExitBlocks (skip_latch: getUniqueNonLatchExitBlocks)
li_unique_exit_blocks :: (li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id, skip: Value_Id = NONE) {
    seen: Table(Value_Id, bool); seen.allocator = temp;
    for b: li.loops[l].blocks {
        if b == skip continue;
        t := block_terminator(b);
        if t == NONE continue;
        n := num_successors(t);
        if n > 0 for k: 0..n-1 {
            s := get_successor(t, k);
            if li_contains(li, l, s) || table_contains(*seen, s) continue;
            table_set(*seen, s, true);
            array_add(out, s);
        }
    }
}
// getExitBlock (unique = false) / getUniqueExitBlock (unique = true): find_singleton_nested
li_exit_block_helper :: (li: *Loop_Info, l: Loop_Id, unique: bool) -> (Value_Id, bool) {
    r: Value_Id = NONE;
    for b: li.loops[l].blocks {
        // inner: find_singleton_nested over successors
        inner: Value_Id = NONE;
        t := block_terminator(b);
        if t == NONE continue;
        n := num_successors(t);
        if n > 0 for k: 0..n-1 {
            s := get_successor(t, k);
            if li_contains(li, l, s) continue;
            if inner != NONE {
                if !unique || inner != s return NONE, true;
                continue;
            }
            inner = s;
        }
        if inner == NONE continue;
        if r != NONE {
            if !unique || r != inner return NONE, true;
            continue;
        }
        r = inner;
    }
    return r, false;
}
li_exit_block :: (li: *Loop_Info, l: Loop_Id) -> Value_Id { r := li_exit_block_helper(li, l, false); return r; }
li_unique_exit_block :: (li: *Loop_Info, l: Loop_Id) -> Value_Id { r := li_exit_block_helper(li, l, true); return r; }
li_has_no_exit_blocks :: (li: *Loop_Info, l: Loop_Id) -> bool {
    r, multiple := li_exit_block_helper(li, l, false);
    if multiple return false;
    return r == NONE;
}

// hasDedicatedExits
li_has_dedicated_exits :: (li: *Loop_Info, l: Loop_Id) -> bool {
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits);
    preds: [..] Value_Id; preds.allocator = temp;
    for e: exits {
        block_predecessors(e, *preds);
        for preds if !li_contains(li, l, it) return false;
    }
    return true;
}

// BasicBlock::isLegalToHoistInto
block_is_legal_to_hoist_into :: (b: Value_Id) -> bool {
    t := block_terminator(b);
    if t == NONE return true;
    op := inst_op(t);
    return !(op == .CATCHSWITCH || op == .CATCHRET || op == .CLEANUPRET || op == .INVOKE || op == .RESUME || op == .CALLBR);
}

// getLoopPredecessor
li_loop_predecessor :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    out: Value_Id = NONE;
    h := li_header(li, l);
    u := ir.v_first_use[h];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) || !is_terminator(inst_op(user)) continue;
        p := inst(user).parent;
        if !li_contains(li, l, p) {
            if out != NONE && out != p return NONE;
            out = p;
        }
    }
    return out;
}
// getLoopPreheader
li_loop_preheader :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    out := li_loop_predecessor(li, l);
    if out == NONE return NONE;
    if !block_is_legal_to_hoist_into(out) return NONE;
    if block_num_successors(out) != 1 return NONE;
    return out;
}
// getLoopLatch
li_loop_latch :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    latch: Value_Id = NONE;
    h := li_header(li, l);
    u := ir.v_first_use[h];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) || !is_terminator(inst_op(user)) continue;
        p := inst(user).parent;
        if li_contains(li, l, p) {
            if latch != NONE return NONE;
            latch = p;
        }
    }
    return latch;
}
// getLoopLatches (predecessors of the header inside the loop, use-list order, with duplicates)
li_loop_latches :: (li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(li_header(li, l), *preds);
    for preds if li_contains(li, l, it) array_add(out, it);
}
// isLoopLatch(BB)
li_is_loop_latch :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) -> bool {
    if !li_contains(li, l, b) return false;
    return succ_contains(b, li_header(li, l));
}
// getNumBackEdges
li_num_back_edges :: (li: *Loop_Info, l: Loop_Id) -> int {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(li_header(li, l), *preds);
    n := 0;
    for preds if li_contains(li, l, it) n += 1;
    return n;
}
// isLoopSimplifyForm
li_is_loop_simplify_form :: (li: *Loop_Info, l: Loop_Id) -> bool {
    return li_loop_preheader(li, l) != NONE && li_loop_latch(li, l) != NONE && li_has_dedicated_exits(li, l);
}

// isBlockInLCSSAForm / isLCSSAForm / isRecursivelyLCSSAForm
li_block_in_lcssa_form :: (li: *Loop_Info, l: Loop_Id, b: Value_Id, dt: *Dom_Tree, ignore_tokens: bool) -> bool {
    for i: block_insts(b) {
        if ignore_tokens && type_kind(vtype(i)) == .TOKEN continue;
        u := ir.v_first_use[i];
        while u != NONE {
            ui := ir.u_user[u];
            ub := inst_block(ui);
            if inst_op(ui) == .PHI ub = ir.u_aux[u];
            if ub != b && !li_contains(li, l, ub) && dt_is_reachable_from_entry(dt, ub) return false;
            u = ir.u_next[u];
        }
    }
    return true;
}
li_is_lcssa_form :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, ignore_tokens := true) -> bool {
    for li.loops[l].blocks if !li_block_in_lcssa_form(li, l, it, dt, ignore_tokens) return false;
    return true;
}
li_is_recursively_lcssa_form :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, ignore_tokens := true) -> bool {
    for li.loops[l].blocks if !li_block_in_lcssa_form(li, li_loop_for(li, it), it, dt, ignore_tokens) return false;
    return true;
}

// getLoopsInPreorder: top-level loops in forward program order (reverse of the stored order), each followed by
// its nest in preorder
li_loops_in_preorder :: (li: *Loop_Info, out: *[..] Loop_Id) {
    rec :: (li: *Loop_Info, l: Loop_Id, out: *[..] Loop_Id) {
        for li.loops[l].subloops { array_add(out, it); rec(li, it, out); }
    }
    for < li.top_level { array_add(out, it); rec(li, it, out); }
}
// Loop::getLoopsInPreorder (this loop and its nest)
li_loop_nest_preorder :: (li: *Loop_Info, l: Loop_Id, out: *[..] Loop_Id) {
    array_add(out, l);
    for li.loops[l].subloops li_loop_nest_preorder(li, it, out);
}
// getLoopsInReverseSiblingPreorder
li_loops_in_reverse_sibling_preorder :: (li: *Loop_Info, out: *[..] Loop_Id) {
    work: [..] Loop_Id; work.allocator = temp;
    for li.top_level {
        array_add(*work, it);
        while work.count {
            l := pop(*work);
            for s: li.loops[l].subloops array_add(*work, s);
            array_add(out, l);
        }
    }
}

// ---------------------------------------------------------------- updates (GenericLoopInfo.h)

// addBasicBlockToLoop
li_add_basic_block_to_loop :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) {
    li_change_loop_for(li, b, l);
    x := l;
    while x != NONE { li_add_block_entry(li, x, b); x = li.loops[x].parent; }
}
// removeBlockFromLoop (does not touch the block map)
li_remove_block_from_loop :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) {
    bl := *li.loops[l].blocks;
    for bl.* if it == b {
        // std::vector::erase: shift down
        for k: it_index..bl.count-2 bl.*[k] = bl.*[k + 1];
        bl.count -= 1;
        break;
    }
    table_remove(*li.member, li_key(l, b));
}
// LoopInfo::removeBlock: from every loop it is in, and the map
li_remove_block :: (li: *Loop_Info, b: Value_Id) {
    l := li_loop_for(li, b);
    while l != NONE { li_remove_block_from_loop(li, l, b); l = li.loops[l].parent; }
    table_remove(*li.loop_of, b);
}
// moveToHeader
li_move_to_header :: (li: *Loop_Info, l: Loop_Id, b: Value_Id) {
    bl := li.loops[l].blocks;
    if bl[0] == b return;
    for bl if it == b { bl[it_index] = bl[0]; bl[0] = b; return; }
    fatal("internal: moveToHeader: block not in loop");
}
// addChildLoop
li_add_child_loop :: (li: *Loop_Info, l: Loop_Id, child: Loop_Id) {
    li.loops[child].parent = l;
    array_add(*li.loops[l].subloops, child);
}
// removeChildLoop(Child)
li_remove_child_loop :: (li: *Loop_Info, l: Loop_Id, child: Loop_Id) {
    sl := *li.loops[l].subloops;
    for sl.* if it == child {
        for k: it_index..sl.count-2 sl.*[k] = sl.*[k + 1];
        sl.count -= 1;
        break;
    }
    li.loops[child].parent = NONE;
}
// replaceChildLoopWith
li_replace_child_loop_with :: (li: *Loop_Info, l: Loop_Id, old: Loop_Id, new: Loop_Id) {
    for * li.loops[l].subloops if it.* == old { it.* = new; break; }
    li.loops[old].parent = NONE;
    li.loops[new].parent = l;
}
li_add_top_level_loop :: (li: *Loop_Info, l: Loop_Id) { array_add(*li.top_level, l); }
// removeLoop(I)
li_remove_top_level_loop :: (li: *Loop_Info, l: Loop_Id) {
    tl := *li.top_level;
    for tl.* if it == l {
        for k: it_index..tl.count-2 tl.*[k] = tl.*[k + 1];
        tl.count -= 1;
        return;
    }
}
// changeTopLevelLoop
li_change_top_level_loop :: (li: *Loop_Info, old: Loop_Id, new: Loop_Id) {
    for * li.top_level if it.* == old { it.* = new; return; }
}
// destroy: the loop row stays (ids are never reused) but is marked dead
li_destroy :: (li: *Loop_Info, l: Loop_Id) {
    r := *li.loops[l];
    for r.blocks table_remove(*li.member, li_key(l, it));
    r.blocks.count = 0;
    r.subloops.count = 0;
    r.parent = NONE;
    r.dead = true;
}

// LoopInfo::erase (UnloopUpdater for nested loops)
li_erase :: (li: *Loop_Info, unloop: Loop_Id) {
    if li_is_outermost(li, unloop) {
        for b: li.loops[unloop].blocks if li_loop_for(li, b) == unloop li_change_loop_for(li, b, NONE);
        li_remove_top_level_loop(li, unloop);
        while li.loops[unloop].subloops.count {
            sl := li.loops[unloop].subloops;
            c := sl[sl.count - 1];
            li_remove_child_loop(li, unloop, c);
            li_add_top_level_loop(li, c);
        }
        li_destroy(li, unloop);
        return;
    }
    // UnloopUpdater
    uu: Unloop_Updater;
    uu.li = li; uu.unloop = unloop;
    uu.subloop_parents.allocator = temp;
    uu.post.allocator = temp;
    uu_update_block_parents(*uu);
    uu_remove_blocks_from_ancestors(*uu);
    // updateSubloopParents
    while li.loops[unloop].subloops.count {
        sl := li.loops[unloop].subloops;
        sub := sl[sl.count - 1];
        li_remove_child_loop(li, unloop, sub);
        found, p := table_find(*uu.subloop_parents, sub);
        assert(found, "DFS failed to visit subloop");
        if p != NONE li_add_child_loop(li, p, sub);
        else li_add_top_level_loop(li, sub);
    }
    li_remove_child_loop(li, li_parent(li, unloop), unloop);
    li_destroy(li, unloop);
}

Unloop_Updater :: struct {
    li: *Loop_Info;
    unloop: Loop_Id;
    post: [..] Value_Id;                        // LoopBlocksDFS postorder
    subloop_parents: Table(Loop_Id, Loop_Id);
    found_ib: bool;
}

// UnloopUpdater::getNearestLoop
uu_get_nearest_loop :: (u: *Unloop_Updater, b: Value_Id, bb_loop: Loop_Id) -> Loop_Id {
    li := u.li;
    un := u.unloop;
    near := bb_loop;
    sub: Loop_Id = NONE;
    if near != un && near != NONE && li_contains_loop(li, un, near) {
        sub = near;
        while li_parent(li, sub) != un sub = li_parent(li, sub);
        found, v := table_find(*u.subloop_parents, sub);
        if !found { table_set(*u.subloop_parents, sub, un); v = un; }
        near = v;
    }
    if block_num_successors(b) == 0 near = NONE;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    for s: succs {
        if s == b continue;
        l := li_loop_for(li, s);
        if l == un u.found_ib = true;
        if l != un && l != NONE && li_contains_loop(li, un, l) {
            if sub != NONE continue;
            _, v := table_find(*u.subloop_parents, l);
            l = v;
        }
        if l == un continue;
        if l != NONE && !li_contains_loop(li, l, un) l = li_parent(li, l);
        if near == un || near == NONE || li_contains_loop(li, near, l) near = l;
    }
    if sub != NONE {
        table_set(*u.subloop_parents, sub, near);
        return bb_loop;
    }
    return near;
}

// UnloopUpdater::updateBlockParents (LoopBlocksTraversal: post-order from the header over blocks whose loop is
// inside Unloop)
uu_update_block_parents :: (u: *Unloop_Updater) {
    li := u.li;
    un := u.unloop;
    if li_num_blocks(li, un) {
        Frame :: struct { b: Value_Id; next: u32; n: u32; }
        seen: Table(Value_Id, bool); seen.allocator = temp;
        stack: [..] Frame; stack.allocator = temp;
        h := li_header(li, un);
        visit :: (u: *Unloop_Updater, seen: *Table(Value_Id, bool), b: Value_Id) -> bool {
            if !li_contains_loop(u.li, u.unloop, li_loop_for(u.li, b)) return false;
            if table_contains(seen, b) return false;
            table_set(seen, b, true);
            return true;
        }
        if visit(u, *seen, h) array_add(*stack, .{h, 0, block_num_successors(h)});
        while stack.count {
            top := *stack[stack.count - 1];
            if top.next < top.n {
                sb := get_successor(block_terminator(top.b), top.next);
                top.next += 1;
                if visit(u, *seen, sb) array_add(*stack, .{sb, 0, block_num_successors(sb)});
                continue;
            }
            b := top.b;
            stack.count -= 1;
            array_add(*u.post, b);
            l := li_loop_for(li, b);
            nl := uu_get_nearest_loop(u, b, l);
            if nl != l li_change_loop_for(li, b, nl);
        }
    }
    changed := u.found_ib;
    while changed {
        changed = false;
        for b: u.post {
            l := li_loop_for(li, b);
            nl := uu_get_nearest_loop(u, b, l);
            if nl != l { li_change_loop_for(li, b, nl); changed = true; }
        }
    }
}

// UnloopUpdater::removeBlocksFromAncestors
uu_remove_blocks_from_ancestors :: (u: *Unloop_Updater) {
    li := u.li;
    un := u.unloop;
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li.loops[un].blocks array_add(*blocks, it);
    for b: blocks {
        outer := li_loop_for(li, b);
        if outer != NONE && li_contains_loop(li, un, outer) {
            while li_parent(li, outer) != un outer = li_parent(li, outer);
            _, v := table_find(*u.subloop_parents, outer);
            outer = v;
        }
        old := li_parent(li, un);
        while old != outer {
            assert(old != NONE, "new loop is not an ancestor of the original");
            li_remove_block_from_loop(li, old, b);
            old = li_parent(li, old);
        }
    }
}

// ---------------------------------------------------------------- loop metadata (LoopInfo.cpp)

MD_LOOP_KIND :: 18;                    // FixedMetadataKinds: llvm.loop
MD_MEM_PARALLEL_LOOP_ACCESS_KIND :: 10;
MD_ACCESS_GROUP_KIND :: 25;

// Loop::getLoopID
li_loop_id :: (li: *Loop_Info, l: Loop_Id) -> Md_Id {
    id: Md_Id = NONE;
    latches: [..] Value_Id; latches.allocator = temp;
    li_loop_latches(li, l, *latches);
    for latches {
        t := block_terminator(it);
        md := get_metadata(t, MD_LOOP_KIND);
        if md == NONE return NONE;
        if id == NONE id = md;
        else if md != id return NONE;
    }
    if id == NONE || md_nops(id) == 0 || md_op(id, 0) != id return NONE;
    return id;
}
// findOptionMDForLoopID
find_option_md_for_loop_id :: (loop_id: Md_Id, name: string) -> Md_Id {
    if loop_id == NONE return NONE;
    n := md_nops(loop_id);
    if n > 1 for k: 1..n-1 {
        md := md_op(loop_id, k);
        if !md_is_node(md) || md_nops(md) < 1 continue;
        s := md_op(md, 0);
        if s == NONE || ir.mds[s].kind != .STRING continue;
        if ir.mds[s].str == name return md;
    }
    return NONE;
}

// Loop::isAnnotatedParallel
li_is_annotated_parallel :: (li: *Loop_Info, l: Loop_Id) -> bool {
    desired := li_loop_id(li, l);
    if desired == NONE return false;
    pa := find_option_md_for_loop_id(desired, "llvm.loop.parallel_accesses");
    groups: Table(Md_Id, bool); groups.allocator = temp;
    if pa != NONE {
        n := md_nops(pa);
        if n > 1 for k: 1..n-1 table_set(*groups, md_op(pa, k), true);
    }
    for b: li.loops[l].blocks for i: block_insts(b) {
        if !may_read_or_write_memory(i) continue;
        ag := get_metadata(i, MD_ACCESS_GROUP_KIND);
        if ag != NONE {
            contains := false;
            if md_nops(ag) == 0 contains = table_contains(*groups, ag);
            else for k: 0..md_nops(ag)-1 if table_contains(*groups, md_op(ag, k)) { contains = true; break; }
            if contains continue;
        }
        lid := get_metadata(i, MD_MEM_PARALLEL_LOOP_ACCESS_KIND);
        if lid == NONE return false;
        found := false;
        if md_nops(lid) > 0 for k: 0..md_nops(lid)-1 if md_op(lid, k) == desired { found = true; break; }
        if !found return false;
    }
    return true;
}

// ---------------------------------------------------------------- printing

// LoopBase::print(OS, Verbose = false, PrintNested = true, Depth)
li_print_loop :: (li: *Loop_Info, l: Loop_Id, sb: *String_Builder, depth: u32 = 0) {
    for 1..depth*2 append(sb, " ");
    if li_is_annotated_parallel(li, l) append(sb, "Parallel ");
    print_to_builder(sb, "Loop at depth % containing: ", li_depth(li, l));
    h := li_header(li, l);
    for b: li.loops[l].blocks {
        if it_index append(sb, ",");
        append(sb, value_as_operand(b));
        if b == h append(sb, "<header>");
        if li_is_loop_latch(li, l, b) append(sb, "<latch>");
        if li_is_loop_exiting(li, l, b) append(sb, "<exiting>");
    }
    append(sb, "\n");
    for li.loops[l].subloops li_print_loop(li, it, sb, depth + 2);
}
li_print :: (li: *Loop_Info, sb: *String_Builder) {
    for li.top_level li_print_loop(li, it, sb);
}

// LoopInfoBase::getSmallestCommonLoop
li_smallest_common_loop :: (li: *Loop_Info, a_in: Loop_Id, b_in: Loop_Id) -> Loop_Id {
    a := a_in; b := b_in;
    if a == NONE || b == NONE return NONE;
    depth :: (li: *Loop_Info, l: Loop_Id) -> s64 { d := 0; x := l; while x != NONE { d += 1; x = li.loops[x].parent; } return d; }
    while depth(li, a) > depth(li, b) a = li.loops[a].parent;
    while depth(li, b) > depth(li, a) b = li.loops[b].parent;
    while a != b { a = li.loops[a].parent; b = li.loops[b].parent; }
    return a;
}
