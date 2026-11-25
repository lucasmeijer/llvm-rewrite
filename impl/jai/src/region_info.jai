// RegionInfo: single-entry single-exit regions. A port of llvm/include/llvm/Analysis/RegionInfoImpl.h,
// llvm/lib/Analysis/RegionInfo.cpp (RegionInfoAnalysis, RegionInfoPrinterPass, -print-region-style),
// llvm/include/llvm/Analysis/RegionIterator.h (RNSuccIterator, the element and block iterators) and the
// DominanceFrontier it is built from (llvm/include/llvm/Analysis/DominanceFrontierImpl.h; only membership is
// queried, so the frontier sets are computed by the equivalent Cytron walk).
//
// Regions and region nodes are rows: a Region_Id names a region (RegionBase), a Rn_Id a region node. A region's own
// node (Region derives from RegionNode) is `regions[r].node`; basic-block nodes are created lazily per region
// (BBNodeMap = `bb_nodes`), like getBBNode. Node identity is the Rn_Id, as LLVM compares node pointers.
// RegionInfo keeps the DominatorTree it was built with and reads it in `contains`, exactly like LLVM, so a pass that
// updates the tree (StructurizeCFG) sees the updated regions.

Region_Id :: s32;
Rn_Id :: s32;

Region_Row :: struct {
    entry: Value_Id;
    exit: Value_Id = NONE;          // NONE: the top-level region (<Function Return>)
    parent: Region_Id = -1;
    children: [..] Region_Id;
    node: Rn_Id;
    bb_nodes: Table(Value_Id, Rn_Id);
}
Rn_Row :: struct {
    sub: bool;          // isSubRegion
    region: Region_Id;  // the region itself (sub) or the parent region (basic block)
    bb: Value_Id;       // the block (basic-block nodes)
}

Region_Info :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    df_list: Table(Value_Id, [..] Value_Id);   // DominanceFrontier: block -> frontier (no particular order)
    df_member: Table(u64, bool);               // (block << 32) | frontier block
    regions: [..] Region_Row;
    nodes: [..] Rn_Row;
    bb_to_region: Table(Value_Id, Region_Id);
    top: Region_Id;
}

ri_print_style: s64 = 0;   // -print-region-style: 0 none, 1 bb, 2 rn
ri_verify_region_info := false;   // -verify-region-info (fatal errors on broken regions only)

ri_region :: inline (ri: *Region_Info, r: Region_Id) -> *Region_Row { return *ri.regions[r]; }
rn_entry :: (ri: *Region_Info, n: Rn_Id) -> Value_Id {
    nr := ri.nodes[n];
    if nr.sub return ri.regions[nr.region].entry;
    return nr.bb;
}
// RegionNode::getParent
rn_parent :: (ri: *Region_Info, n: Rn_Id) -> Region_Id {
    nr := ri.nodes[n];
    if nr.sub return ri.regions[nr.region].parent;
    return nr.region;
}

ri_new_region :: (ri: *Region_Info, entry: Value_Id, exit: Value_Id, parent: Region_Id = -1) -> Region_Id {
    r := cast(Region_Id) ri.regions.count;
    row: Region_Row;
    row.entry = entry; row.exit = exit; row.parent = parent;
    row.children.allocator = temp;
    row.bb_nodes.allocator = temp;
    n := cast(Rn_Id) ri.nodes.count;
    array_add(*ri.nodes, .{true, r, NONE});
    row.node = n;
    array_add(*ri.regions, row);
    return r;
}

// RegionBase::contains(const BlockT *B)
ri_contains :: (ri: *Region_Info, r: Region_Id, bb: Value_Id) -> bool {
    if dt_node(ri.dt, bb) < 0 return false;
    entry := ri.regions[r].entry; exit := ri.regions[r].exit;
    if exit == NONE return true;
    return dt_dominates(ri.dt, entry, bb) && !(dt_dominates(ri.dt, exit, bb) && dt_dominates(ri.dt, entry, exit));
}
// RegionBase::contains(const RegionT *SubRegion)
ri_contains_region :: (ri: *Region_Info, r: Region_Id, sub: Region_Id) -> bool {
    if sub < 0 return false;
    if ri.regions[sub].exit == NONE return ri.regions[r].exit == NONE;
    return ri_contains(ri, r, ri.regions[sub].entry) &&
           (ri_contains(ri, r, ri.regions[sub].exit) || ri.regions[r].exit == ri.regions[sub].exit);
}
ri_is_top_level :: inline (ri: *Region_Info, r: Region_Id) -> bool { return ri.regions[r].exit == NONE; }

ri_get_region_for :: (ri: *Region_Info, bb: Value_Id) -> Region_Id {
    found, r := table_find(*ri.bb_to_region, bb);
    if found return r;
    return -1;
}
ri_set_region_for :: (ri: *Region_Info, bb: Value_Id, r: Region_Id) { table_set(*ri.bb_to_region, bb, r); }

// getSubRegionNode
ri_get_sub_region_node :: (ri: *Region_Info, this: Region_Id, bb: Value_Id) -> Region_Id {
    r := ri_get_region_for(ri, bb);
    if r < 0 || r == this return -1;
    while ri_contains_region(ri, this, ri.regions[r].parent) && ri.regions[r].parent != this r = ri.regions[r].parent;
    if ri.regions[r].entry != bb return -1;
    return r;
}
// getBBNode
ri_get_bb_node :: (ri: *Region_Info, r: Region_Id, bb: Value_Id) -> Rn_Id {
    found, n := table_find(*ri.regions[r].bb_nodes, bb);
    if found return n;
    n = cast(Rn_Id) ri.nodes.count;
    array_add(*ri.nodes, .{false, r, bb});
    table_set(*ri.regions[r].bb_nodes, bb, n);
    return n;
}
// getNode(BB)
ri_get_node :: (ri: *Region_Info, r: Region_Id, bb: Value_Id) -> Rn_Id {
    c := ri_get_sub_region_node(ri, r, bb);
    if c >= 0 return ri.regions[c].node;
    return ri_get_bb_node(ri, r, bb);
}

// RNSuccIterator<RegionNode *, BasicBlock, Region>: the successor nodes of a node inside its parent region
rn_successors :: (ri: *Region_Info, n: Rn_Id, out: *[..] Rn_Id) {
    out.count = 0;
    parent := rn_parent(ri, n);
    parent_exit := ri.regions[parent].exit;
    nr := ri.nodes[n];
    if nr.sub {
        s := ri.regions[nr.region].exit;
        if s != parent_exit array_add(out, ri_get_node(ri, parent, s));
        return;
    }
    t := block_terminator(nr.bb);
    if t == NONE return;
    k := num_successors(t);
    for i: 0..cast(s64) k - 1 {
        s := get_successor(t, cast(u32) i);
        if s == parent_exit continue;
        array_add(out, ri_get_node(ri, parent, s));
    }
}

// RegionBase::elements(): df_iterator over the region node graph from the entry node
ri_elements :: (ri: *Region_Info, r: Region_Id, out: *[..] Rn_Id) {
    out.count = 0;
    entry := ri_get_node(ri, r, ri.regions[r].entry);
    visited: Table(Rn_Id, bool); visited.allocator = temp;
    Frame :: struct { n: Rn_Id; succs: [..] Rn_Id; next: s64; }
    stack: [..] Frame; stack.allocator = temp;
    push :: (ri: *Region_Info, stack: *[..] Frame, n: Rn_Id) {
        fr: Frame; fr.n = n; fr.succs.allocator = temp;
        rn_successors(ri, n, *fr.succs);
        array_add(stack, fr);
    }
    table_set(*visited, entry, true);
    array_add(out, entry);
    push(ri, *stack, entry);
    while stack.count {
        top := *stack[stack.count - 1];
        pushed := false;
        while top.next < top.succs.count {
            s := top.succs[top.next];
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                array_add(out, s);
                push(ri, *stack, s);
                pushed = true;
                break;
            }
        }
        if !pushed stack.count -= 1;
    }
}

// RegionBase::blocks(): df_iterator over the CFG from the entry, with the exit pre-marked visited
ri_blocks :: (ri: *Region_Info, r: Region_Id, out: *[..] Value_Id) {
    out.count = 0;
    entry := ri.regions[r].entry; exit := ri.regions[r].exit;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    Frame :: struct { b: Value_Id; next: u32; n: u32; }
    stack: [..] Frame; stack.allocator = temp;
    table_set(*visited, entry, true);
    if exit != NONE table_set(*visited, exit, true);
    array_add(out, entry);
    array_add(*stack, .{entry, 0, block_num_successors(entry)});
    while stack.count {
        top := *stack[stack.count - 1];
        pushed := false;
        while top.next < top.n {
            s := get_successor(block_terminator(top.b), top.next);
            top.next += 1;
            if !table_contains(*visited, s) {
                table_set(*visited, s, true);
                array_add(out, s);
                array_add(*stack, .{s, 0, block_num_successors(s)});
                pushed = true;
                break;
            }
        }
        if !pushed stack.count -= 1;
    }
}

// getEnteringBlock: find_singleton over the entry's predecessors
ri_entering_block :: (ri: *Region_Info, r: Region_Id) -> Value_Id {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(ri.regions[r].entry, *preds);
    rc: Value_Id = NONE;
    for p: preds {
        if dt_node(ri.dt, p) >= 0 && !ri_contains(ri, r, p) {
            if rc != NONE return NONE;
            rc = p;
        }
    }
    return rc;
}
// getExitingBlock
ri_exiting_block :: (ri: *Region_Info, r: Region_Id) -> Value_Id {
    exit := ri.regions[r].exit;
    if exit == NONE return NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(exit, *preds);
    rc: Value_Id = NONE;
    for p: preds {
        if ri_contains(ri, r, p) {
            if rc != NONE return NONE;
            rc = p;
        }
    }
    return rc;
}
// isSimple
ri_is_simple :: (ri: *Region_Info, r: Region_Id) -> bool {
    return !ri_is_top_level(ri, r) && ri_entering_block(ri, r) != NONE && ri_exiting_block(ri, r) != NONE;
}

// replaceExit / replaceEntry
ri_replace_exit :: (ri: *Region_Info, r: Region_Id, bb: Value_Id) { ri.regions[r].exit = bb; }
ri_replace_entry :: (ri: *Region_Info, r: Region_Id, bb: Value_Id) { ri.regions[r].entry = bb; }

// addSubRegion(SubRegion, moveChildren = false)
ri_add_sub_region :: (ri: *Region_Info, r: Region_Id, sub: Region_Id) {
    ri.regions[sub].parent = r;
    array_add(*ri.regions[r].children, sub);
}

// ---------------------------------------------------------------- DominanceFrontier

ri_df_insert :: (ri: *Region_Info, b: Value_Id, s: Value_Id) {
    key := ((cast(u64) b) << 32) | cast(u64) s;
    if table_contains(*ri.df_member, key) return;
    table_set(*ri.df_member, key, true);
    l := ri_df_list(ri, b);
    array_add(l, s);
}
ri_df_list :: (ri: *Region_Info, b: Value_Id) -> *[..] Value_Id {
    l := table_find_pointer(*ri.df_list, b);
    if l return l;
    nl: [..] Value_Id; nl.allocator = temp;
    table_set(*ri.df_list, b, nl);
    return table_find_pointer(*ri.df_list, b);
}
// DominanceFrontierBase::analyze (forward): the work-list walk of DominanceFrontierImpl.h, with its
// properlyDominates queries (they count as slow queries of the tree, which print<domtree> shows)
ri_compute_dominance_frontier :: (ri: *Region_Info) {
    dt := ri.dt;
    root := dt.root_node;
    Work :: struct { bb: Value_Id; parent_bb: Value_Id; node: s32; parent_node: s32; }
    work: [..] Work; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, .{dt.nodes[root].block, NONE, root, -1});
    succs: [..] Value_Id; succs.allocator = temp;
    while true {
        w := work[work.count - 1];
        if w.bb != NONE && !table_contains(*visited, w.bb) {
            table_set(*visited, w.bb, true);
            ri_df_list(ri, w.bb);
            block_successors(w.bb, *succs);
            for c: succs if dt.nodes[dt_node(dt, c)].idom != w.node ri_df_insert(ri, w.bb, c);
        }
        visit_child := false;
        c := dt.nodes[w.node].first_child;
        while c >= 0 {
            cb := dt.nodes[c].block;
            if !table_contains(*visited, cb) {
                array_add(*work, .{cb, w.bb, c, w.node});
                visit_child = true;
            }
            c = dt.nodes[c].sibling;
        }
        if !visit_child {
            if w.node == root break;
            work.count -= 1;
            if w.parent_bb == NONE { if !work.count break; continue; }
            s := ri_df_list(ri, w.bb).*;
            for x: s {
                xn := dt_node(dt, x);
                if !(w.parent_node != xn && dt_dominates_nodes(dt, w.parent_node, xn)) ri_df_insert(ri, w.parent_bb, x);
            }
        }
        if !work.count break;
    }
}
ri_df_contains :: inline (ri: *Region_Info, b: Value_Id, s: Value_Id) -> bool {
    return table_contains(*ri.df_member, ((cast(u64) b) << 32) | cast(u64) s);
}
ri_df :: (ri: *Region_Info, b: Value_Id) -> [] Value_Id {
    l := table_find_pointer(*ri.df_list, b);
    if l return l.*;
    return .[];
}

// ---------------------------------------------------------------- construction (RegionInfoBase::calculate)

ri_is_common_dom_frontier :: (ri: *Region_Info, bb: Value_Id, entry: Value_Id, exit: Value_Id) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds if dt_dominates(ri.dt, entry, p) && !dt_dominates(ri.dt, exit, p) return false;
    return true;
}
ri_is_region :: (ri: *Region_Info, entry: Value_Id, exit: Value_Id) -> bool {
    entry_succs := ri_df(ri, entry);
    if !dt_dominates(ri.dt, entry, exit) {
        for s: entry_succs if s != exit && s != entry return false;
        return true;
    }
    for s: entry_succs {
        if s == exit || s == entry continue;
        if !ri_df_contains(ri, exit, s) return false;
        if !ri_is_common_dom_frontier(ri, s, entry, exit) return false;
    }
    for s: ri_df(ri, exit) if dt_properly_dominates(ri.dt, entry, s) && s != exit return false;
    return true;
}
ri_is_trivial_region :: (entry: Value_Id, exit: Value_Id) -> bool {
    n := block_num_successors(entry);
    return n <= 1 && n > 0 && exit == get_successor(block_terminator(entry), 0);
}

ri_compute :: (f: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) -> *Region_Info {
    ri := New(Region_Info,, allocator = temp);
    ri.f = f; ri.dt = dt; ri.pdt = pdt;
    ri.df_list.allocator = temp; ri.df_member.allocator = temp;
    ri.regions.allocator = temp; ri.nodes.allocator = temp; ri.bb_to_region.allocator = temp;
    ri_compute_dominance_frontier(ri);
    ri.top = ri_new_region(ri, fn_entry(f), NONE);

    // scanForRegions: post_order over the dominator tree
    short_cut: Table(Value_Id, Value_Id); short_cut.allocator = temp;
    po: [..] s32; po.allocator = temp;
    {
        Frame :: struct { n: s32; child: s32; }
        stack: [..] Frame; stack.allocator = temp;
        root := dt_node(dt, fn_entry(f));
        array_add(*stack, .{root, dt.nodes[root].first_child});
        while stack.count {
            top := *stack[stack.count - 1];
            if top.child >= 0 {
                c := top.child;
                top.child = dt.nodes[c].sibling;
                array_add(*stack, .{c, dt.nodes[c].first_child});
                continue;
            }
            array_add(*po, top.n);
            stack.count -= 1;
        }
    }
    for dn: po {
        entry := dt.nodes[dn].block;
        // findRegionsWithEntry
        n := dt_node(pdt, entry);
        if n < 0 continue;
        last_region: Region_Id = -1;
        last_exit := entry;
        while true {
            // getNextPostDom
            found, sc := table_find(*short_cut, pdt.nodes[n].block);
            if !found n = pdt.nodes[n].idom;
            else n = pdt.nodes[dt_node(pdt, sc)].idom;
            if n < 0 break;
            exit := pdt.nodes[n].block;
            if exit == NONE break;
            if ri_is_region(ri, entry, exit) {
                // createRegion
                new_region: Region_Id = -1;
                if !ri_is_trivial_region(entry, exit) {
                    new_region = ri_new_region(ri, entry, exit);
                    if !table_contains(*ri.bb_to_region, entry) table_set(*ri.bb_to_region, entry, new_region);
                    // updateStatistics: the STATISTIC increments are compiled out, but `R->isSimple()` is still
                    // evaluated, and its dominance queries count as slow queries of the tree
                    ri_is_simple(ri, new_region);
                }
                if last_region >= 0 {
                    if new_region < 0 fatal("RegionInfo: trivial region around a region");   // LLVM dereferences null
                    ri_add_sub_region(ri, new_region, last_region);
                }
                last_region = new_region;
                last_exit = exit;
            }
            if !dt_dominates(dt, entry, exit) break;
        }
        if last_exit != entry {
            // insertShortCut
            found, e := table_find(*short_cut, last_exit);
            if !found table_set(*short_cut, entry, last_exit);
            else table_set(*short_cut, entry, e);
        }
    }

    // buildRegionsTree(DT->getNode(entry), TopLevelRegion)
    Frame :: struct { n: s32; r: Region_Id; child: s32; }
    stack: [..] Frame; stack.allocator = temp;
    visit :: (ri: *Region_Info, n: s32, region_in: Region_Id) -> Region_Id {
        bb := ri.dt.nodes[n].block;
        region := region_in;
        while bb == ri.regions[region].exit region = ri.regions[region].parent;
        found, existing := table_find(*ri.bb_to_region, bb);
        if !found {
            table_set(*ri.bb_to_region, bb, region);
        } else {
            top := existing;
            while ri.regions[top].parent >= 0 top = ri.regions[top].parent;
            ri_add_sub_region(ri, region, top);
            region = existing;
        }
        return region;
    }
    root := dt_node(dt, fn_entry(f));
    array_add(*stack, .{root, visit(ri, root, ri.top), dt.nodes[root].first_child});
    while stack.count {
        top := *stack[stack.count - 1];
        if top.child >= 0 {
            c := top.child;
            top.child = dt.nodes[c].sibling;
            r := top.r;
            array_add(*stack, .{c, visit(ri, c, r), dt.nodes[c].first_child});
            continue;
        }
        stack.count -= 1;
    }
    return ri;
}

// getRegionInfo for a function pass: RegionInfoAnalysis on the cached / computed trees
ri_get :: (f: Value_Id) -> *Region_Info {
    dt := get_domtree(f);
    pdt := get_postdomtree(f);
    return ri_compute(f, dt, pdt);
}

// ---------------------------------------------------------------- printing

ri_block_name_str :: (b: Value_Id) -> string {
    if vname(b).count return vname(b);
    return value_as_operand(b);   // printAsOperand(OS, false)
}
ri_name_str :: (ri: *Region_Info, r: Region_Id) -> string {
    en := ri_block_name_str(ri.regions[r].entry);
    ex := ifx ri.regions[r].exit != NONE then ri_block_name_str(ri.regions[r].exit) else "<Function Return>";
    return tconcat(en, " => ", ex);
}
ri_print_region :: (ri: *Region_Info, r: Region_Id, sb: *String_Builder, level: s64) {
    indent :: (sb: *String_Builder, n: s64) { for 1..n append(sb, " "); }
    indent(sb, level * 2);
    print_to_builder(sb, "[%] %\n", level, ri_name_str(ri, r));
    if ri_print_style != 0 {
        indent(sb, level * 2); append(sb, "{\n");
        indent(sb, level * 2 + 2);
        if ri_print_style == 1 {
            bl: [..] Value_Id; bl.allocator = temp;
            ri_blocks(ri, r, *bl);
            for bl { append(sb, vname(it)); append(sb, ", "); }
        } else {
            el: [..] Rn_Id; el.allocator = temp;
            ri_elements(ri, r, *el);
            for el {
                if ri.nodes[it].sub append(sb, ri_name_str(ri, ri.nodes[it].region));
                else append(sb, vname(ri.nodes[it].bb));
                append(sb, ", ");
            }
        }
        append(sb, "\n");
    }
    for ri.regions[r].children ri_print_region(ri, it, sb, level + 1);
    if ri_print_style != 0 { indent(sb, level * 2); append(sb, "} \n"); }
}

// RegionInfoPrinterPass
print_regions_run :: (f: Value_Id) -> Preserved {
    ri := ri_get(f);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Region Tree for function: %\n", vname(f));
    append(*sb, "Region tree:\n");
    ri_print_region(ri, ri.top, *sb, 0);
    append(*sb, "End region tree\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
