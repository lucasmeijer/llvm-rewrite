// Small analysis printers from the registry gaps (NOTES.md "Pass registry gaps"):
//   print<cfg-sccs>      llvm/lib/Analysis/CFGSCCPrinter.cpp (scc_iterator<Function *>)
//   print<domfrontier>   llvm/lib/Analysis/DominanceFrontier.cpp, llvm/include/llvm/Analysis/DominanceFrontierImpl.h

// CFGSCCPrinterPass::run
print_cfg_sccs_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "SCCs for Function % in PostOrder:", vname(f));
    sccs: [..] [..] Value_Id; sccs.allocator = temp;
    cfg_sccs(fn_entry(f), *sccs);   // branch_prob.jai: scc_iterator order, each SCC in pop order
    for scc, k: sccs {
        print_to_builder(*sb, "\nSCC #%: ", k + 1);
        for scc {
            if it_index > 0 append(*sb, ", ");
            append(*sb, value_as_operand(it));
        }
        // scc_iterator::hasCycle: a single node is a cycle if it is its own successor
        if scc.count == 1 {
            t := block_terminator(scc[0]);
            self := false;
            if t != NONE for i: 0..cast(s64) num_successors(t) - 1 if get_successor(t, cast(u32) i) == scc[0] self = true;
            if self append(*sb, " (Has self-loop).");
        }
    }
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// DominanceFrontierPrinterPass::run: getResult<DominanceFrontierAnalysis> = DominanceFrontierBase::analyze(DT), then
// print. Frontiers is a std::map<BasicBlock *, SetVector<BasicBlock *>>, printed in pointer order: with more than one
// entry we fail loudly unless -domfrontier-guess-address-order (guess: block order in the function).
domfrontier_guess_address_order := false;

print_domfrontier_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    Frontier :: struct { b: Value_Id; set: [..] Value_Id; }
    fr: [..] Frontier; fr.allocator = temp;
    index: Table(Value_Id, s64); index.allocator = temp;
    frontier_of :: (fr: *[..] Frontier, index: *Table(Value_Id, s64), b: Value_Id) -> *[..] Value_Id {
        found, i := table_find(index, b);
        if !found {
            e: Frontier; e.b = b; e.set.allocator = temp;
            array_add(fr, e);
            i = fr.count - 1;
            table_set(index, b, i);
        }
        return *fr.*[i].set;
    }
    set_insert :: (s: *[..] Value_Id, b: Value_Id) { for s.* if it == b return; array_add(s, b); }

    Work :: struct { bb: Value_Id; parent_bb: Value_Id; node: s32; parent_node: s32; }
    root := dt.root_node;
    work: [..] Work; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, .{dt_block(dt, root), NONE, root, -1});
    while work.count {
        cur := work[work.count - 1];
        if cur.bb != NONE && !table_contains(*visited, cur.bb) {
            table_set(*visited, cur.bb, true);
            s := frontier_of(*fr, *index, cur.bb);
            t := block_terminator(cur.bb);
            if t != NONE for i: 0..cast(s64) num_successors(t) - 1 {
                child := get_successor(t, cast(u32) i);
                if dt_idom(dt, dt_node(dt, child)) != cur.node set_insert(s, child);
            }
        }
        visit_child := false;
        c := dt.nodes[cur.node].first_child;
        while c >= 0 {
            cb := dt_block(dt, c);
            if !table_contains(*visited, cb) {
                array_add(*work, .{cb, cur.bb, c, cur.node});
                visit_child = true;
            }
            c = dt.nodes[c].sibling;
        }
        if !visit_child {
            if root == cur.node break;
            work.count -= 1;
            if cur.parent_bb == NONE continue;
            s := frontier_of(*fr, *index, cur.bb);
            ps := frontier_of(*fr, *index, cur.parent_bb);
            // iterate by index: ps may be s's neighbour in `fr`, but the set arrays are separate
            for k: 0..s.count - 1 {
                x := s.*[k];
                if !dt_dominates_nodes_proper(dt, cur.parent_node, dt_node(dt, x)) set_insert(ps, x);
            }
        }
    }
    if fr.count > 1 && !domfrontier_guess_address_order
        fatal("print<domfrontier>: LLVM prints the frontiers in BasicBlock pointer order (std::map); use -domfrontier-guess-address-order to guess block order");
    order: [..] s64; order.allocator = temp;
    for b: fn_blocks(f) { found, i := table_find(*index, b); if found array_add(*order, i); }
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "DominanceFrontier for function: %\n", vname(f));
    for i: order {
        e := *fr[i];
        print_to_builder(*sb, "  DomFrontier for BB % is:\t", value_as_operand(e.b));
        for e.set { append(*sb, " "); append(*sb, value_as_operand(it)); }
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// DominatorTreeBase::properlyDominates(const DomTreeNodeBase *A, const DomTreeNodeBase *B)
dt_dominates_nodes_proper :: (dt: *Dom_Tree, a: s32, b: s32) -> bool {
    if a < 0 || b < 0 return false;
    if a == b return false;
    return dt_dominates_nodes(dt, a, b);
}

registry_printers_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "domfrontier-guess-address-order" { domfrontier_guess_address_order = !has_value || value == "true" || value == "1"; return true; }
    return false;
}
