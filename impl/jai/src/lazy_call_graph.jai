// LazyCallGraph: a port of llvm/lib/Analysis/LazyCallGraph.cpp and llvm/include/llvm/Analysis/LazyCallGraph.h
// (Node::populateSlow, the entry edges, buildRefSCCs / buildSCCs / buildGenericSCCs (Tarjan over the ref graph, then
// over the call edges inside each RefSCC), visitReferences, every incremental update of RefSCC (switchInternalEdgeToCall
// with updatePostorderSequenceForEdgeInsertion, switchInternalEdgeToRef, switchTrivialInternalEdgeToRef,
// switchOutgoingEdgeTo{Call,Ref}, insertInternalRefEdge, insertOutgoingEdge, insertIncomingRefEdge,
// removeOutgoingEdge, removeInternalRefEdges, insertTrivial{Call,Ref}Edge, replaceNodeFunction), markDeadFunction,
// removeDeadFunctions, addSplitFunction, addSplitRefRecursiveFunctions and LazyCallGraphPrinterPass (print-lcg).
//
// Data-oriented: nodes, SCCs and RefSCCs are rows of `lcg.nodes` / `lcg.sccs` / `lcg.rcs` addressed by s32 ids (LLVM's
// bump-allocated objects, whose pointers stay valid for the life of the graph; ids are never reused either). An edge is
// (node id, call?) with -1 for a null edge; `lcg_edge_ok` is Edge::operator bool (non-null and the node not dead).
// SCCMap is `scc_of` indexed by node id, an SCC's index in its RefSCC (SCCIndices) is the SCC row's `idx`, a RefSCC's
// index in the postorder list (RefSCCIndices) the RefSCC row's `pidx`. The graph is the module analysis
// LazyCallGraphAnalysis: `lcg` (null when not cached; lcg_get() = AM.getResult, lcg_invalidate()).

Lcg_Edge :: struct {
    node: s32 = -1;
    call: bool;
}
Lcg_Edges :: struct {   // EdgeSequence
    edges: [..] Lcg_Edge;
    index: Table(s32, s32);   // EdgeIndexMap
}
Lcg_Node :: struct {
    f: Value_Id;
    dead: bool;        // G == nullptr
    populated: bool;   // Edges.has_value()
    dfs: s32;
    low: s32;
    seq: Lcg_Edges;
}
Lcg_Scc :: struct {
    rc: s32 = -1;      // OuterRefSCC
    nodes: [..] s32;
    idx: s32;          // SCCIndices[this] in its RefSCC
}
Lcg_Ref_Scc :: struct {
    dead: bool;        // G == nullptr
    sccs: [..] s32;
    pidx: s32 = -1;    // RefSCCIndices[this]
}
Lazy_Call_Graph :: struct {
    nodes: [..] Lcg_Node;
    node_map: Table(Value_Id, s32);
    entry: Lcg_Edges;
    sccs: [..] Lcg_Scc;
    scc_of: [..] s32;          // SCCMap (by node id; -1 = none)
    rcs: [..] Lcg_Ref_Scc;
    postorder: [..] s32;       // PostOrderRefSCCs
    lib_functions: [..] Value_Id;   // SmallSetVector
}

lcg: *Lazy_Call_Graph;

lcg_node :: inline (n: s32) -> *Lcg_Node { return *lcg.nodes[n]; }
lcg_scc :: inline (c: s32) -> *Lcg_Scc { return *lcg.sccs[c]; }
lcg_rc :: inline (r: s32) -> *Lcg_Ref_Scc { return *lcg.rcs[r]; }
lcg_edge_ok :: inline (e: Lcg_Edge) -> bool { return e.node >= 0 && !lcg.nodes[e.node].dead; }
lcg_fn :: inline (n: s32) -> Value_Id { return lcg.nodes[n].f; }

// lookupSCC / lookupRefSCC / lookup
lcg_lookup_scc :: (n: s32) -> s32 { if n < 0 || n >= lcg.scc_of.count return -1; return lcg.scc_of[n]; }
lcg_lookup_rc :: (n: s32) -> s32 { c := lcg_lookup_scc(n); if c < 0 return -1; return lcg.sccs[c].rc; }
lcg_lookup :: (f: Value_Id) -> s32 { found, n := table_find(*lcg.node_map, f); if found return n; return -1; }
lcg_set_scc :: (n: s32, c: s32) {
    while lcg.scc_of.count <= n array_add(*lcg.scc_of, -1);
    lcg.scc_of[n] = c;
}

// EdgeSequence helpers
lcg_seq :: inline (n: s32) -> *Lcg_Edges { return *lcg.nodes[n].seq; }
lcg_seq_lookup :: (s: *Lcg_Edges, target: s32) -> s32 {   // index of a live edge to target, -1 if none (EdgeSequence::lookup)
    found, i := table_find(*s.index, target);
    if !found return -1;
    if !lcg_edge_ok(s.edges[i]) return -1;
    return i;
}
lcg_seq_insert_internal :: (s: *Lcg_Edges, target: s32, call: bool) {   // insertEdgeInternal
    if !table_contains(*s.index, target) table_set(*s.index, target, cast(s32) s.edges.count);
    array_add(*s.edges, .{target, call});
}
lcg_seq_set_kind :: (s: *Lcg_Edges, target: s32, call: bool) {
    found, i := table_find(*s.index, target);
    s.edges[i].call = call;
}
lcg_seq_remove_internal :: (s: *Lcg_Edges, target: s32) -> bool {
    found, i := table_find(*s.index, target);
    if !found return false;
    s.edges[i] = .{};
    table_remove(*s.index, target);
    return true;
}
// static addEdge
lcg_add_edge :: (s: *Lcg_Edges, target: s32, call: bool) {
    if table_contains(*s.index, target) return;
    table_set(*s.index, target, cast(s32) s.edges.count);
    array_add(*s.edges, .{target, call});
}
lcg_seq_empty :: (s: *Lcg_Edges) -> bool { for s.edges if lcg_edge_ok(it) return false; return true; }

// LazyCallGraph::get(F)
lcg_get_node :: (f: Value_Id) -> s32 {
    found, n := table_find(*lcg.node_map, f);
    if found return n;
    nd: Lcg_Node; nd.f = f;
    id := cast(s32) lcg.nodes.count;
    array_add(*lcg.nodes, nd);
    table_set(*lcg.node_map, f, id);
    return id;
}

lcg_is_lib_function :: (f: Value_Id) -> bool { for lcg.lib_functions if it == f return true; return false; }

// I.operand_values() / C->operand_values(): the constant operands that the reference walk follows
Const_Set :: struct { set: Table(Value_Id, bool); }
lcg_visit_operands_of_inst :: (i: Value_Id, worklist: *[..] Value_Id, visited: *Table(Value_Id, bool)) {
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        if o == NONE || !is_constant_kind(vkind(o)) continue;
        if table_contains(visited, o) continue;
        table_set(visited, o, true);
        array_add(worklist, o);
    }
}

// LazyCallGraph::visitReferences: `out` collects the functions found, in callback order
lcg_visit_references :: (worklist: *[..] Value_Id, visited: *Table(Value_Id, bool), out: *[..] Value_Id) {
    while worklist.count {
        c := pop(worklist);
        k := vkind(c);
        if k == .FUNCTION {
            if !is_declaration(c) array_add(out, c);
            continue;
        }
        if k == .C_BLOCKADDR continue;
        n := nops(c);
        for j: 0..cast(s64) n - 1 {
            o := op(c, cast(u32) j);
            if o == NONE continue;
            if table_contains(visited, o) continue;
            table_set(visited, o, true);
            array_add(worklist, o);
        }
    }
}

// Node::populate / populateSlow
lcg_populate :: (n: s32) {
    if lcg.nodes[n].populated return;
    lcg.nodes[n].populated = true;
    f := lcg.nodes[n].f;
    worklist: [..] Value_Id; worklist.allocator = temp;
    callees: Table(Value_Id, bool); callees.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    if !is_declaration(f) for i: fn_insts(f) {
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee != NONE && !is_declaration(callee) && !table_contains(*callees, callee) {
                table_set(*callees, callee, true);
                table_set(*visited, callee, true);
                t := lcg_get_node(callee);
                lcg_add_edge(lcg_seq(n), t, true);
            }
        }
        lcg_visit_operands_of_inst(i, *worklist, *visited);
    }
    refs: [..] Value_Id; refs.allocator = temp;
    lcg_visit_references(*worklist, *visited, *refs);
    for refs { t := lcg_get_node(it); lcg_add_edge(lcg_seq(n), t, false); }
    for lf: lcg.lib_functions {
        if table_contains(*visited, lf) continue;
        t := lcg_get_node(lf);
        lcg_add_edge(lcg_seq(n), t, false);
    }
}

// isKnownLibFunction (no vector library: isKnownVectorFunctionInLibrary is false)
lcg_is_known_lib_function :: (f: Value_Id) -> bool {
    ok, _ := tli_lookup_fn(f);
    return ok;
}

// LazyCallGraph::LazyCallGraph(Module &M, GetTLI)
lcg_build :: () -> *Lazy_Call_Graph {
    g := New(Lazy_Call_Graph);
    saved := lcg;
    lcg = g;
    for f: ir.m_functions {
        if is_declaration(f) continue;
        if lcg_is_known_lib_function(f) {
            found := false;
            for lcg.lib_functions if it == f found = true;
            if !found array_add(*lcg.lib_functions, f);
        }
        if gv_has_local_linkage(f) continue;
        lcg_add_edge(*lcg.entry, lcg_get_node(f), false);
    }
    for a: ir.m_aliases {
        if gv_has_local_linkage(a) continue;
        aliasee := op(a, 0);
        if aliasee != NONE && vkind(aliasee) == .FUNCTION lcg_add_edge(*lcg.entry, lcg_get_node(aliasee), false);
    }
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    for gv: ir.m_globals {
        if !glob(gv).has_init continue;
        init := op(gv, 0);
        if init == NONE || table_contains(*visited, init) continue;
        table_set(*visited, init, true);
        array_add(*worklist, init);
    }
    refs: [..] Value_Id; refs.allocator = temp;
    lcg_visit_references(*worklist, *visited, *refs);
    for refs lcg_add_edge(*lcg.entry, lcg_get_node(it), false);
    lcg = saved;
    return g;
}

gv_has_local_linkage :: (v: Value_Id) -> bool { l := glob(v).linkage; return l == .INTERNAL || l == .PRIVATE; }

// AM.getResult<LazyCallGraphAnalysis>(M)
lcg_get :: () -> *Lazy_Call_Graph {
    if !lcg lcg = lcg_build();
    return lcg;
}
// LazyCallGraph::invalidate returned true: drop the cached graph
lcg_invalidate :: () {
    if !lcg return;
    for * lcg.nodes { array_free(it.seq.edges); deinit(*it.seq.index); }
    for * lcg.sccs array_free(it.nodes);
    for * lcg.rcs array_free(it.sccs);
    array_free(lcg.nodes); deinit(*lcg.node_map); array_free(lcg.entry.edges); deinit(*lcg.entry.index);
    array_free(lcg.sccs); array_free(lcg.scc_of); array_free(lcg.rcs); array_free(lcg.postorder);
    array_free(lcg.lib_functions);
    free(lcg);
    lcg = null;
}

lcg_create_scc :: (rc: s32, nodes: [] s32) -> s32 {
    c: Lcg_Scc; c.rc = rc;
    for nodes array_add(*c.nodes, it);
    id := cast(s32) lcg.sccs.count;
    array_add(*lcg.sccs, c);
    return id;
}
lcg_create_rc :: () -> s32 {
    r: Lcg_Ref_Scc;
    id := cast(s32) lcg.rcs.count;
    array_add(*lcg.rcs, r);
    return id;
}

// ---------------------------------------------------------------- SCC formation

// Next live edge at or after i (EdgeSequence::iterator / call_iterator advance)
lcg_next_edge :: (n: s32, i: s32, calls_only: bool) -> s32 {
    s := lcg_seq(n);
    j := i;
    while j < s.edges.count {
        e := s.edges[j];
        if lcg_edge_ok(e) && (!calls_only || e.call) return j;
        j += 1;
    }
    return j;
}

Lcg_Dfs_Frame :: struct { n: s32; i: s32; }

// buildGenericSCCs. `ref_mode`: walk every edge (populating nodes first, buildRefSCCs); otherwise call edges only
// (buildSCCs). For every SCC found, `formed` gets the node range (PendingSCCStack.rbegin() up to the root) appended,
// as a slice of the list of all node ranges (starts in `starts`).
lcg_build_generic_sccs :: (roots: [] s32, ref_mode: bool, out_nodes: *[..] s32, out_starts: *[..] s32) {
    dfs_stack: [..] Lcg_Dfs_Frame; dfs_stack.allocator = temp;
    pending: [..] s32; pending.allocator = temp;
    begin :: (n: s32, ref_mode: bool) -> s32 {
        if ref_mode lcg_populate(n);
        return lcg_next_edge(n, 0, !ref_mode);
    }
    for root: roots {
        if lcg.nodes[root].dfs != 0 continue;
        lcg.nodes[root].dfs = 1; lcg.nodes[root].low = 1;
        next_dfs: s32 = 2;
        array_add(*dfs_stack, .{root, begin(root, ref_mode)});
        while dfs_stack.count {
            fr := pop(*dfs_stack);
            n := fr.n; i := fr.i;
            while i < lcg_seq(n).edges.count {
                child := lcg_seq(n).edges[i].node;
                if lcg.nodes[child].dfs == 0 {
                    array_add(*dfs_stack, .{n, i});
                    lcg.nodes[child].dfs = next_dfs; lcg.nodes[child].low = next_dfs;
                    next_dfs += 1;
                    n = child;
                    i = begin(n, ref_mode);
                    continue;
                }
                if lcg.nodes[child].dfs == -1 { i = lcg_next_edge(n, i + 1, !ref_mode); continue; }
                if lcg.nodes[child].low < lcg.nodes[n].low lcg.nodes[n].low = lcg.nodes[child].low;
                i = lcg_next_edge(n, i + 1, !ref_mode);
            }
            array_add(*pending, n);
            if lcg.nodes[n].low != lcg.nodes[n].dfs continue;
            root_dfs := lcg.nodes[n].dfs;
            // range from the top of the pending stack down to (excluding) the first node with a lower DFS number
            k := pending.count - 1;
            while k >= 0 && !(lcg.nodes[pending[k]].dfs < root_dfs) k -= 1;
            array_add(out_starts, cast(s32) out_nodes.count);
            j := pending.count - 1;
            while j > k { array_add(out_nodes, pending[j]); j -= 1; }
            // FormSCC: the callbacks mark the nodes (dfs = low = -1) before the pending stack is cut
            lcg_form_scc_callback(out_nodes, out_starts, ref_mode);
            pending.count = k + 1;
        }
    }
}

// The FormSCC callbacks of buildRefSCCs and buildSCCs. For buildSCCs the nodes are marked here; for buildRefSCCs the
// RefSCC is created by lcg_build_ref_sccs_form (called back here through ref_mode).
lcg_form_rc: s32 = -1;   // the RefSCC buildSCCs is filling (buildSCCs' RC)
lcg_form_scc_callback :: (out_nodes: *[..] s32, out_starts: *[..] s32, ref_mode: bool) {
    start := out_starts.*[out_starts.count - 1];
    range: [..] s32; range.allocator = temp;
    for k: start..out_nodes.count - 1 array_add(*range, out_nodes.*[k]);
    out_nodes.count = start;
    out_starts.count -= 1;
    if ref_mode {
        rc := lcg_create_rc();
        lcg_build_sccs(rc, range);
        lcg.rcs[rc].pidx = cast(s32) lcg.postorder.count;
        array_add(*lcg.postorder, rc);
        return;
    }
    rc := lcg_form_rc;
    c := lcg_create_scc(rc, range);
    array_add(*lcg.rcs[rc].sccs, c);
    for lcg.sccs[c].nodes { lcg.nodes[it].dfs = -1; lcg.nodes[it].low = -1; lcg_set_scc(it, c); }
}

// buildSCCs(RC, Nodes)
lcg_build_sccs :: (rc: s32, nodes: [] s32) {
    for nodes { lcg.nodes[it].dfs = 0; lcg.nodes[it].low = 0; }
    saved := lcg_form_rc;
    lcg_form_rc = rc;
    out_nodes: [..] s32; out_nodes.allocator = temp;
    out_starts: [..] s32; out_starts.allocator = temp;
    lcg_build_generic_sccs(nodes, false, *out_nodes, *out_starts);
    lcg_form_rc = saved;
    for c, i: lcg.rcs[rc].sccs lcg.sccs[c].idx = cast(s32) i;
}

// buildRefSCCs
lcg_build_ref_sccs :: () {
    if lcg_seq_empty(*lcg.entry) || lcg.postorder.count return;
    roots: [..] s32; roots.allocator = temp;
    for lcg.entry.edges if lcg_edge_ok(it) array_add(*roots, it.node);
    out_nodes: [..] s32; out_nodes.allocator = temp;
    out_starts: [..] s32; out_starts.allocator = temp;
    lcg_build_generic_sccs(roots, true, *out_nodes, *out_starts);
}

// postorder_ref_scc_iterator: the first non-empty RefSCC at or after postorder index i (-1 at the end)
lcg_postorder_from :: (i: s64) -> s32 {
    j := i;
    while j < lcg.postorder.count {
        rc := lcg.postorder[j];
        if lcg.rcs[rc].sccs.count != 0 return rc;
        j += 1;
    }
    return -1;
}
lcg_postorder_next :: (rc: s32) -> s32 { return lcg_postorder_from(lcg.rcs[rc].pidx + 1); }

// ---------------------------------------------------------------- queries

lcg_scc_contains_call_to :: (src_c: s32, target_c: s32) -> bool {   // SCC::isParentOf
    if src_c == target_c return false;
    for n: lcg.sccs[src_c].nodes for e: lcg_seq(n).edges
        if lcg_edge_ok(e) && e.call && lcg_lookup_scc(e.node) == target_c return true;
    return false;
}

lcg_rc_find_index :: (c: s32) -> s32 { return lcg.sccs[c].idx; }   // RC->find(C) - RC->begin()

// SCC name as printed by operator<<(raw_ostream &, const SCC &)
lcg_scc_name :: (c: s32) -> string {
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "(");
    nodes := lcg.sccs[c].nodes;
    for n, i: nodes {
        if i > 0 append(*sb, ", ");
        if i > 8 { print_to_builder(*sb, "..., %", vname(lcg_fn(nodes[nodes.count - 1]))); break; }
        append(*sb, vname(lcg_fn(n)));
    }
    append(*sb, ")");
    return builder_to_string(*sb,, allocator = temp);
}

// ---------------------------------------------------------------- incremental updates (RefSCC methods)

// updatePostorderSequenceForEdgeInsertion over a list of ids with an index field. Returns the merge range
// [begin, end) as positions in `list` (an empty range at the target when no cycle forms).
Lcg_Seq_Kind :: enum u8 { SCCS; REF_SCCS; }
lcg_seq_index :: (kind: Lcg_Seq_Kind, x: s32) -> s32 { if kind == .SCCS return lcg.sccs[x].idx; return lcg.rcs[x].pidx; }
lcg_seq_set_index :: (kind: Lcg_Seq_Kind, x: s32, i: s32) { if kind == .SCCS lcg.sccs[x].idx = i; else lcg.rcs[x].pidx = i; }

// std::stable_partition(list[a..b), pred): elements with pred true first
lcg_stable_partition :: (list: *[..] s32, a: s64, b: s64, set: *Table(s32, bool), want_in_set: bool) -> s64 {
    first: [..] s32; first.allocator = temp;
    second: [..] s32; second.allocator = temp;
    for k: a..b-1 {
        x := list.*[k];
        if table_contains(set, x) == want_in_set array_add(*first, x); else array_add(*second, x);
    }
    k := a;
    for first { list.*[k] = it; k += 1; }
    mid := k;
    for second { list.*[k] = it; k += 1; }
    return mid;
}

// switchInternalEdgeToCall. `merged` receives the SCCs merged into the target (MergeCB's argument). Returns
// whether a cycle formed.
lcg_switch_internal_edge_to_call :: (rc: s32, src: s32, tgt: s32, merged: *[..] s32) -> bool {
    src_c := lcg_lookup_scc(src);
    tgt_c := lcg_lookup_scc(tgt);
    if src_c == tgt_c { lcg_seq_set_kind(lcg_seq(src), tgt, true); return false; }
    src_idx := lcg.sccs[src_c].idx;
    tgt_idx := lcg.sccs[tgt_c].idx;
    if tgt_idx < src_idx { lcg_seq_set_kind(lcg_seq(src), tgt, true); return false; }
    sccs := *lcg.rcs[rc].sccs;
    // ComputeSourceConnectedSet
    set: Table(s32, bool); set.allocator = temp;
    table_set(*set, src_c, true);
    for k: src_idx + 1..tgt_idx {
        c := sccs.*[k];
        connected := false;
        for n: lcg.sccs[c].nodes {
            for e: lcg_seq(n).edges if lcg_edge_ok(e) && e.call && table_contains(*set, lcg_lookup_scc(e.node)) { connected = true; break; }
            if connected break;
        }
        if connected table_set(*set, c, true);
    }
    // partition: SCCs not connected to the source first
    source_i := lcg_stable_partition(sccs, src_idx, tgt_idx + 1, *set, false);
    for k: src_idx..tgt_idx lcg.sccs[sccs.*[k]].idx = cast(s32) k;
    mb, me: s64;
    if !table_contains(*set, tgt_c) {
        mb = source_i - 1; me = source_i - 1;
    } else {
        s_idx := source_i;
        t_idx := cast(s64) tgt_idx;
        if s_idx + 1 < t_idx {
            table_reset(*set);
            // ComputeTargetConnectedSet
            table_set(*set, tgt_c, true);
            wl: [..] s32; wl.allocator = temp;
            array_add(*wl, tgt_c);
            while wl.count {
                c := pop(*wl);
                for n: lcg.sccs[c].nodes for e: lcg_seq(n).edges {
                    if !lcg_edge_ok(e) || !e.call continue;
                    ec := lcg_lookup_scc(e.node);
                    if lcg.sccs[ec].rc != rc continue;
                    if lcg.sccs[ec].idx <= s_idx continue;
                    if !table_contains(*set, ec) { table_set(*set, ec, true); array_add(*wl, ec); }
                }
            }
            target_i := lcg_stable_partition(sccs, s_idx + 1, t_idx + 1, *set, true);
            for k: s_idx + 1..t_idx lcg.sccs[sccs.*[k]].idx = cast(s32) k;
            t_idx = target_i - 1;
        }
        mb = s_idx; me = t_idx;
    }
    for k: mb..me-1 array_add(merged, sccs.*[k]);
    if mb == me { lcg_seq_set_kind(lcg_seq(src), tgt, true); return false; }
    for k: mb..me-1 {
        c := sccs.*[k];
        for n: lcg.sccs[c].nodes { array_add(*lcg.sccs[tgt_c].nodes, n); lcg_set_scc(n, tgt_c); }
        lcg.sccs[c].nodes.count = 0;
        lcg.sccs[c].rc = -1;
    }
    off := me - mb;
    for k: me..sccs.count-1 sccs.*[k - off] = sccs.*[k];
    sccs.count -= off;
    for k: mb..sccs.count-1 lcg.sccs[sccs.*[k]].idx -= cast(s32) off;
    lcg_seq_set_kind(lcg_seq(src), tgt, true);
    return true;
}

lcg_switch_trivial_internal_edge_to_ref :: (src: s32, tgt: s32) { lcg_seq_set_kind(lcg_seq(src), tgt, false); }

// switchInternalEdgeToRef: returns the new SCCs as a range [b, e) of positions in the RefSCC's SCC list
lcg_switch_internal_edge_to_ref :: (rc: s32, src: s32, tgt: s32) -> (s64, s64) {
    old_c := lcg_lookup_scc(tgt);
    lcg_seq_set_kind(lcg_seq(src), tgt, false);
    dfs_stack: [..] Lcg_Dfs_Frame; dfs_stack.allocator = temp;
    pending: [..] s32; pending.allocator = temp;
    new_sccs: [..] s32; new_sccs.allocator = temp;
    worklist: [..] s32; worklist.allocator = temp;
    for lcg.sccs[old_c].nodes array_add(*worklist, it);
    lcg.sccs[old_c].nodes.count = 0;
    for worklist { lcg.nodes[it].dfs = 0; lcg.nodes[it].low = 0; lcg.scc_of[it] = -1; }
    lcg.nodes[tgt].dfs = -1; lcg.nodes[tgt].low = -1;
    array_add(*lcg.sccs[old_c].nodes, tgt);
    lcg_set_scc(tgt, old_c);
    for root: worklist {
        if lcg.nodes[root].dfs != 0 continue;
        lcg.nodes[root].dfs = 1; lcg.nodes[root].low = 1;
        next_dfs: s32 = 2;
        array_add(*dfs_stack, .{root, lcg_next_edge(root, 0, true)});
        while dfs_stack.count {
            fr := pop(*dfs_stack);
            n := fr.n; i := fr.i;
            cleared := false;
            while i < lcg_seq(n).edges.count {
                child := lcg_seq(n).edges[i].node;
                if lcg.nodes[child].dfs == 0 {
                    array_add(*dfs_stack, .{n, i});
                    lcg.nodes[child].dfs = next_dfs; lcg.nodes[child].low = next_dfs;
                    next_dfs += 1;
                    n = child;
                    i = lcg_next_edge(n, 0, true);
                    continue;
                }
                if lcg.nodes[child].dfs == -1 {
                    if lcg_lookup_scc(child) == old_c {
                        old_size := lcg.sccs[old_c].nodes.count;
                        array_add(*lcg.sccs[old_c].nodes, n);
                        for pending array_add(*lcg.sccs[old_c].nodes, it);
                        pending.count = 0;
                        while dfs_stack.count array_add(*lcg.sccs[old_c].nodes, pop(*dfs_stack).n);
                        for k: old_size..lcg.sccs[old_c].nodes.count-1 {
                            m := lcg.sccs[old_c].nodes[k];
                            lcg.nodes[m].dfs = -1; lcg.nodes[m].low = -1;
                            lcg_set_scc(m, old_c);
                        }
                        cleared = true;
                        break;
                    }
                    i = lcg_next_edge(n, i + 1, true);
                    continue;
                }
                if lcg.nodes[child].low < lcg.nodes[n].low lcg.nodes[n].low = lcg.nodes[child].low;
                i = lcg_next_edge(n, i + 1, true);
            }
            if cleared break;
            array_add(*pending, n);
            if lcg.nodes[n].low != lcg.nodes[n].dfs continue;
            root_dfs := lcg.nodes[n].dfs;
            k := pending.count - 1;
            while k >= 0 && !(lcg.nodes[pending[k]].dfs < root_dfs) k -= 1;
            range: [..] s32; range.allocator = temp;
            j := pending.count - 1;
            while j > k { array_add(*range, pending[j]); j -= 1; }
            c := lcg_create_scc(rc, range);
            array_add(*new_sccs, c);
            for m: lcg.sccs[c].nodes { lcg.nodes[m].dfs = -1; lcg.nodes[m].low = -1; lcg_set_scc(m, c); }
            pending.count = k + 1;
        }
    }
    old_idx := cast(s64) lcg.sccs[old_c].idx;
    sccs := *lcg.rcs[rc].sccs;
    // SCCs.insert(SCCs.begin() + OldIdx, NewSCCs)
    tail: [..] s32; tail.allocator = temp;
    for k: old_idx..sccs.count-1 array_add(*tail, sccs.*[k]);
    sccs.count = old_idx;
    for new_sccs array_add(sccs, it);
    for tail array_add(sccs, it);
    for k: old_idx..sccs.count-1 lcg.sccs[sccs.*[k]].idx = cast(s32) k;
    return old_idx, old_idx + new_sccs.count;
}

lcg_switch_outgoing_edge_to_call :: (src: s32, tgt: s32) { lcg_seq_set_kind(lcg_seq(src), tgt, true); }
lcg_switch_outgoing_edge_to_ref :: (src: s32, tgt: s32) { lcg_seq_set_kind(lcg_seq(src), tgt, false); }
lcg_insert_internal_ref_edge :: (src: s32, tgt: s32) { lcg_seq_insert_internal(lcg_seq(src), tgt, false); }
lcg_insert_outgoing_edge :: (src: s32, tgt: s32, call: bool) { lcg_seq_insert_internal(lcg_seq(src), tgt, call); }

// insertIncomingRefEdge (on the target's RefSCC `this_rc`): returns the RefSCCs merged away
lcg_insert_incoming_ref_edge :: (this_rc: s32, src: s32, tgt: s32) -> [..] s32 {
    deleted: [..] s32; deleted.allocator = temp;
    source_c := lcg_lookup_rc(src);
    src_idx := cast(s64) lcg.rcs[source_c].pidx;
    tgt_idx := cast(s64) lcg.rcs[this_rc].pidx;
    po := *lcg.postorder;
    rc_has_edge_into :: (rc: s32, set: *Table(s32, bool)) -> bool {
        for c: lcg.rcs[rc].sccs for n: lcg.sccs[c].nodes for e: lcg_seq(n).edges
            if lcg_edge_ok(e) && table_contains(set, lcg_lookup_rc(e.node)) return true;
        return false;
    }
    set: Table(s32, bool); set.allocator = temp;
    table_set(*set, source_c, true);
    for k: src_idx + 1..tgt_idx { r := po.*[k]; if rc_has_edge_into(r, *set) table_set(*set, r, true); }
    source_i := lcg_stable_partition(po, src_idx, tgt_idx + 1, *set, false);
    for k: src_idx..tgt_idx lcg.rcs[po.*[k]].pidx = cast(s32) k;
    mb, me: s64;
    if !table_contains(*set, this_rc) {
        mb = source_i - 1; me = source_i - 1;
    } else {
        s_idx := source_i;
        t_idx := tgt_idx;
        if s_idx + 1 < t_idx {
            table_reset(*set);
            table_set(*set, this_rc, true);
            wl: [..] s32; wl.allocator = temp;
            array_add(*wl, this_rc);
            while wl.count {
                r := pop(*wl);
                for c: lcg.rcs[r].sccs for n: lcg.sccs[c].nodes for e: lcg_seq(n).edges {
                    if !lcg_edge_ok(e) continue;
                    er := lcg_lookup_rc(e.node);
                    if lcg.rcs[er].pidx <= s_idx continue;
                    if !table_contains(*set, er) { table_set(*set, er, true); array_add(*wl, er); }
                }
            }
            target_i := lcg_stable_partition(po, s_idx + 1, t_idx + 1, *set, true);
            for k: s_idx + 1..t_idx lcg.rcs[po.*[k]].pidx = cast(s32) k;
            t_idx = target_i - 1;
        }
        mb = s_idx; me = t_idx;
    }
    merged: [..] s32; merged.allocator = temp;
    scc_index: s32 = 0;
    for k: mb..me-1 {
        r := po.*[k];
        for c: lcg.rcs[r].sccs {
            lcg.sccs[c].rc = this_rc;
            lcg.sccs[c].idx = scc_index; scc_index += 1;
            for n: lcg.sccs[c].nodes lcg_set_scc(n, c);
        }
        for lcg.rcs[r].sccs array_add(*merged, it);
        lcg.rcs[r].sccs.count = 0;
        array_add(*deleted, r);
    }
    for c: lcg.rcs[this_rc].sccs { lcg.sccs[c].idx = scc_index; scc_index += 1; }
    for lcg.rcs[this_rc].sccs array_add(*merged, it);
    lcg.rcs[this_rc].sccs.count = 0;
    for merged array_add(*lcg.rcs[this_rc].sccs, it);
    for k: mb..me-1 lcg.rcs[po.*[k]].pidx = -1;
    off := me - mb;
    for k: me..po.count-1 po.*[k - off] = po.*[k];
    po.count -= off;
    for k: mb..po.count-1 lcg.rcs[po.*[k]].pidx -= cast(s32) off;
    lcg_seq_insert_internal(lcg_seq(src), tgt, false);
    return deleted;
}

lcg_remove_outgoing_edge :: (src: s32, tgt: s32) { lcg_seq_remove_internal(lcg_seq(src), tgt); }

// removeInternalRefEdges: returns the new RefSCCs in postorder (empty when the structure did not change)
lcg_remove_internal_ref_edges :: (this_rc: s32, edges: [] [2] s32) -> [..] s32 {
    result: [..] s32; result.allocator = temp;
    for edges lcg_seq_remove_internal(lcg_seq(it[0]), it[1]);
    all_same := true;
    for edges if !(it[0] == it[1] || lcg_lookup_scc(it[0]) == lcg_lookup_scc(it[1])) { all_same = false; break; }
    if all_same return result;
    post_order_number: s32 = 0;
    worklist: [..] s32; worklist.allocator = temp;
    for c: lcg.rcs[this_rc].sccs {
        for n: lcg.sccs[c].nodes { lcg.nodes[n].dfs = 0; lcg.nodes[n].low = 0; }
        for lcg.sccs[c].nodes array_add(*worklist, it);
    }
    num_nodes := worklist.count;
    dfs_stack: [..] Lcg_Dfs_Frame; dfs_stack.allocator = temp;
    pending: [..] s32; pending.allocator = temp;
    while worklist.count {
        root := pop(*worklist);
        if lcg.nodes[root].dfs != 0 continue;
        lcg.nodes[root].dfs = 1; lcg.nodes[root].low = 1;
        next_dfs: s32 = 2;
        array_add(*dfs_stack, .{root, lcg_next_edge(root, 0, false)});
        while dfs_stack.count {
            fr := pop(*dfs_stack);
            n := fr.n; i := fr.i;
            while i < lcg_seq(n).edges.count {
                child := lcg_seq(n).edges[i].node;
                if lcg.nodes[child].dfs == 0 {
                    array_add(*dfs_stack, .{n, i});
                    lcg.nodes[child].low = next_dfs; lcg.nodes[child].dfs = next_dfs;
                    next_dfs += 1;
                    n = child;
                    i = lcg_next_edge(n, 0, false);
                    continue;
                }
                if lcg.nodes[child].dfs == -1 { i = lcg_next_edge(n, i + 1, false); continue; }
                cl := lcg.nodes[child].low;
                if cl >= 0 && cl < lcg.nodes[n].low lcg.nodes[n].low = cl;
                i = lcg_next_edge(n, i + 1, false);
            }
            array_add(*pending, n);
            if lcg.nodes[n].low != lcg.nodes[n].dfs continue;
            number := post_order_number; post_order_number += 1;
            root_dfs := lcg.nodes[n].dfs;
            k := pending.count - 1;
            while k >= 0 {
                m := pending[k];
                if lcg.nodes[m].dfs < root_dfs break;
                lcg.nodes[m].dfs = -1;
                lcg.nodes[m].low = number;
                k -= 1;
            }
            size := pending.count - 1 - k;
            if size == num_nodes {
                for j: k + 1..pending.count-1 lcg.nodes[pending[j]].low = -1;
                return result;
            }
            pending.count = k + 1;
        }
    }
    for 0..post_order_number-1 array_add(*result, lcg_create_rc());
    idx := cast(s64) lcg.rcs[this_rc].pidx;
    po := *lcg.postorder;
    tail: [..] s32; tail.allocator = temp;
    for k: idx + 1..po.count-1 array_add(*tail, po.*[k]);
    po.count = idx;
    for result array_add(po, it);
    for tail array_add(po, it);
    for k: idx..po.count-1 lcg.rcs[po.*[k]].pidx = cast(s32) k;
    for c: lcg.rcs[this_rc].sccs {
        number := lcg.nodes[lcg.sccs[c].nodes[0]].low;
        for n: lcg.sccs[c].nodes lcg.nodes[n].low = -1;
        r := result[number];
        lcg.sccs[c].idx = cast(s32) lcg.rcs[r].sccs.count;
        array_add(*lcg.rcs[r].sccs, c);
        lcg.sccs[c].rc = r;
    }
    lcg.rcs[this_rc].dead = true;
    lcg.rcs[this_rc].sccs.count = 0;
    lcg.rcs[this_rc].pidx = -1;
    return result;
}

// insertTrivialCallEdge / insertTrivialRefEdge
lcg_insert_trivial_call_edge :: (src: s32, tgt: s32) {
    s := lcg_seq(src);
    found, i := table_find(*s.index, tgt);
    if found { if s.edges[i].call return; s.edges[i].call = true; return; }
    table_set(*s.index, tgt, cast(s32) s.edges.count);
    array_add(*s.edges, .{tgt, true});
}
lcg_insert_trivial_ref_edge :: (src: s32, tgt: s32) {
    s := lcg_seq(src);
    if table_contains(*s.index, tgt) return;
    table_set(*s.index, tgt, cast(s32) s.edges.count);
    array_add(*s.edges, .{tgt, false});
}

// RefSCC::replaceNodeFunction
lcg_replace_node_function :: (n: s32, new_f: Value_Id) {
    old_f := lcg.nodes[n].f;
    lcg.nodes[n].f = new_f;
    table_remove(*lcg.node_map, old_f);
    table_set(*lcg.node_map, new_f, n);
    for lcg.lib_functions if it == old_f {
        array_ordered_remove_by_index(*lcg.lib_functions, it_index);
        array_add(*lcg.lib_functions, new_f);
        break;
    }
}

// markDeadFunction
lcg_mark_dead_function :: (f: Value_Id) {
    n := lcg_lookup(f);
    for * e: lcg_seq(n).edges if lcg_edge_ok(e.*) && e.call e.call = false;
}

// removeDeadFunctions
lcg_remove_dead_functions :: (dead_fs: [] Value_Id) {
    if dead_fs.count == 0 return;
    // DenseMap<RefSCC *, SmallVector<Node *, 1>>: LLVM iterates it in pointer-hash order. The order does not reach
    // the result: each RefSCC is split independently (removeInternalRefEdges inserts the pieces at that RefSCC's own
    // position in PostOrderRefSCCs) and the dead RefSCCs are only cleared. Any fixed order works; we use RefSCC ids.
    rcs: [..] s32; rcs.allocator = temp;
    groups: [..] [..] s32; groups.allocator = temp;
    for f: dead_fs {
        n := lcg_lookup(f);
        rc := lcg_lookup_rc(n);
        pos := -1;
        for rcs if it == rc { pos = it_index; break; }
        if pos < 0 {
            pos = rcs.count;
            array_add(*rcs, rc);
            g: [..] s32; g.allocator = temp;
            array_add(*groups, g);
        }
        array_add(*groups[pos], n);
    }
    // sort by RefSCC id
    for i: 1..rcs.count-1 {
        j := i;
        while j > 0 && rcs[j - 1] > rcs[j] {
            t := rcs[j]; rcs[j] = rcs[j - 1]; rcs[j - 1] = t;
            g := groups[j]; groups[j] = groups[j - 1]; groups[j - 1] = g;
            j -= 1;
        }
    }
    for rc, gi: rcs {
        internal: [..] [2] s32; internal.allocator = temp;
        for dn: groups[gi] {
            for e: lcg_seq(dn).edges {
                if !lcg_edge_ok(e) continue;
                if lcg_lookup_rc(e.node) == rc array_add(*internal, .[dn, e.node]);
                else lcg_remove_outgoing_edge(dn, e.node);
            }
        }
        lcg_remove_internal_ref_edges(rc, internal);
        for dn: groups[gi] {
            drc := lcg_lookup_rc(dn);
            lcg.rcs[drc].sccs.count = 0;
            lcg.rcs[drc].dead = true;
        }
    }
    for f: dead_fs {
        n := lcg_lookup(f);
        lcg_seq_remove_internal(*lcg.entry, n);
        lcg.scc_of[n] = -1;
        table_remove(*lcg.node_map, f);
        lcg.nodes[n].populated = false;
        lcg.nodes[n].seq.edges.count = 0;
        table_reset(*lcg.nodes[n].seq.index);
        lcg.nodes[n].dead = true;
        lcg.nodes[n].f = NONE;
    }
}

// static getEdgeKind (release build)
lcg_get_edge_kind :: (orig: Value_Id, new_f: Value_Id) -> bool {
    for i: fn_insts(orig) if is_call_base(i) && call_called_function(i) == new_f return true;
    return false;
}

// initNode
lcg_init_node :: (f: Value_Id) -> s32 {
    n := lcg_get_node(f);
    lcg.nodes[n].dfs = -1; lcg.nodes[n].low = -1;
    lcg_populate(n);
    return n;
}

// addSplitFunction
lcg_add_split_function :: (orig: Value_Id, new_f: Value_Id) {
    orig_n := lcg_get_node(orig);
    orig_c := lcg_lookup_scc(orig_n);
    orig_rc := lcg_lookup_rc(orig_n);
    new_n := lcg_init_node(new_f);
    ek := lcg_get_edge_kind(orig, new_f);
    new_c: s32 = -1;
    for e: lcg_seq(new_n).edges {
        if !lcg_edge_ok(e) continue;
        if ek && e.call && lcg_lookup_scc(e.node) == orig_c {
            new_c = orig_c;
            array_add(*lcg.sccs[new_c].nodes, new_n);
            break;
        }
    }
    if new_c < 0 {
        for e: lcg_seq(new_n).edges {
            if !lcg_edge_ok(e) continue;
            if lcg_lookup_rc(e.node) == orig_rc {
                new_c = lcg_create_scc(orig_rc, .[new_n]);
                sccs := *lcg.rcs[orig_rc].sccs;
                insert_index := ifx ek then cast(s64) lcg.sccs[orig_c].idx else sccs.count;
                array_insert_at(sccs, new_c, insert_index);
                for k: insert_index..sccs.count-1 lcg.sccs[sccs.*[k]].idx = cast(s32) k;
                break;
            }
        }
    }
    if new_c < 0 {
        new_rc := lcg_create_rc();
        new_c = lcg_create_scc(new_rc, .[new_n]);
        lcg.sccs[new_c].idx = 0;
        array_add(*lcg.rcs[new_rc].sccs, new_c);
        oi := cast(s64) lcg.rcs[orig_rc].pidx;
        array_insert_at(*lcg.postorder, new_rc, oi);
        for k: oi..lcg.postorder.count-1 lcg.rcs[lcg.postorder[k]].pidx = cast(s32) k;
    }
    lcg_set_scc(new_n, new_c);
    lcg_seq_insert_internal(lcg_seq(orig_n), new_n, ek);
}

// addSplitRefRecursiveFunctions
lcg_add_split_ref_recursive_functions :: (orig: Value_Id, new_fs: [] Value_Id) {
    orig_n := lcg_get_node(orig);
    orig_rc := lcg_lookup_rc(orig_n);
    exists_ref := false;
    for nf: new_fs {
        new_n := lcg_init_node(nf);
        lcg_seq_insert_internal(lcg_seq(orig_n), new_n, false);
        for e: lcg_seq(new_n).edges if lcg_edge_ok(e) && lcg_lookup_rc(e.node) == orig_rc { exists_ref = true; break; }
    }
    new_rc: s32;
    if exists_ref new_rc = orig_rc;
    else {
        new_rc = lcg_create_rc();
        oi := cast(s64) lcg.rcs[orig_rc].pidx;
        array_insert_at(*lcg.postorder, new_rc, oi);
        for k: oi..lcg.postorder.count-1 lcg.rcs[lcg.postorder[k]].pidx = cast(s32) k;
    }
    for nf: new_fs {
        new_n := lcg_get_node(nf);
        c := lcg_create_scc(new_rc, .[new_n]);
        lcg.sccs[c].idx = cast(s32) lcg.rcs[new_rc].sccs.count;
        array_add(*lcg.rcs[new_rc].sccs, c);
        lcg_set_scc(new_n, c);
    }
}

// ---------------------------------------------------------------- print-lcg (LazyCallGraphPrinterPass)

lcg_printer_run :: () {
    g := lcg_get();
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing the call graph for module: %\n\n", ir.module_id);
    for f: ir.m_functions {
        n := lcg_get_node(f);
        lcg_populate(n);
        print_to_builder(*sb, "  Edges in function: %\n", vname(f));
        for e: lcg_seq(n).edges {
            if !lcg_edge_ok(e) continue;
            print_to_builder(*sb, "    % -> %\n", ifx e.call then "call" else "ref ", vname(lcg_fn(e.node)));
        }
        append(*sb, "\n");
    }
    lcg_build_ref_sccs();
    rc := lcg_postorder_from(0);
    while rc >= 0 {
        print_to_builder(*sb, "  RefSCC with % call SCCs:\n", lcg.rcs[rc].sccs.count);
        for c: lcg.rcs[rc].sccs {
            print_to_builder(*sb, "    SCC with % functions:\n", lcg.sccs[c].nodes.count);
            for n: lcg.sccs[c].nodes print_to_builder(*sb, "      %\n", vname(lcg_fn(n)));
        }
        append(*sb, "\n");
        rc = lcg_postorder_next(rc);
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}
