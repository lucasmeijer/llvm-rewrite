// LazyCallGraph: port of llvm/lib/Analysis/LazyCallGraph.cpp and llvm/include/llvm/Analysis/LazyCallGraph.h:
// Node::populateSlow, the entry edges, buildRefSCCs / buildSCCs / buildGenericSCCs, visitReferences, the
// incremental RefSCC updates (switchInternalEdgeToCall with updatePostorderSequenceForEdgeInsertion,
// switchInternalEdgeToRef, switchTrivialInternalEdgeToRef, switchOutgoingEdgeTo{Call,Ref}, insertInternalRefEdge,
// insertOutgoingEdge, insertIncomingRefEdge, removeOutgoingEdge, removeInternalRefEdges,
// insertTrivial{Call,Ref}Edge, replaceNodeFunction), markDeadFunction, removeDeadFunctions, isParentOf /
// isAncestorOf, and LazyCallGraphPrinterPass / LazyCallGraphDOTPrinterPass (print-lcg, print-lcg-dot).
// Not ported (no caller): addSplitFunction, addSplitRefRecursiveFunctions (coroutine splitting).
//
// Data-oriented: nodes, SCCs and RefSCCs are ids into lcg_nodes / lcg_sccs / lcg_rcs (LLVM's bump-allocated
// objects; ids are never reused while the graph lives). Every vector (a node's edges, an SCC's nodes, a
// RefSCC's SCCs, PostOrderRefSCCs) is an ivec handle. An edge is an i32 `node * 2 + call`, -1 = null edge;
// lcg_edge_ok is Edge::operator bool (non-null, target not dead). EdgeIndexMap is one hash map keyed by
// (source node, target node) (source -1 = the entry edges); SCCMap is `lcg_scc_of` by node id; SCCIndices is
// the SCC's `idx` field (the index in its RefSCC), RefSCCIndices the RefSCC's `pidx`.
// The graph is the module analysis LazyCallGraphAnalysis: `lcg_valid` while cached; lcg_get(m) =
// AM.getResult, lcg_invalidate() drops it.
import std;
import ir;
import irutil;
import instinfo;
import flags;
import tli;
import scev;
import ivec;

struct LcgNode { f: i32, dead: bool, populated: bool, dfs: i32, low: i32, edges: i32 }
struct LcgScc { rc: i32, nodes: i32, idx: i32 }
struct LcgRc { dead: bool, sccs: i32, pidx: i32 }

var lcg_valid: bool = false;
var lcg_module: i32 = -1;
var lcg_nodes: LcgNode[>..];
var lcg_sccs: LcgScc[>..];
var lcg_rcs: LcgRc[>..];
var lcg_scc_of: i32[>..];          // SCCMap by node (-1 = none)
var lcg_node_map = hm_new();       // NodeMap: function value id -> node
var lcg_eidx = hm_new();           // EdgeIndexMap: (source node or -1, target node) -> index
var lcg_entry: i32 = -1;           // EntryEdges (ivec)
var lcg_postorder: i32 = -1;       // PostOrderRefSCCs (ivec)
var lcg_lib_fns: i32[>..];         // LibFunctions (SmallSetVector)

fn lcg_e_node(e: i32) -> i32 { e >> 1 }
fn lcg_e_call(e: i32) -> bool { (e & 1) != 0 }
fn lcg_mk_edge(n: i32, call: bool) -> i32 { n * 2 + (if call { 1 } else { 0 }) }
fn lcg_edge_ok(e: i32) -> bool { e >= 0 && !lcg_nodes[e >> 1].dead }
fn lcg_fn(n: i32) -> i32 { lcg_nodes[n].f }
fn lcg_edges(n: i32) -> i32 { lcg_nodes[n].edges }

fn lcg_invalidate() {
    lcg_valid = false;
    lcg_module = -1;
    lcg_nodes.resize(0);
    lcg_sccs.resize(0);
    lcg_rcs.resize(0);
    lcg_scc_of.resize(0);
    hm_clear(lcg_node_map);
    hm_clear(lcg_eidx);
    lcg_lib_fns.resize(0);
    iv_reset();
    lcg_entry = -1;
    lcg_postorder = -1;
}

// lookupSCC / lookupRefSCC / lookup
fn lcg_lookup_scc(n: i32) -> i32 { if n < 0 || (n as i64) >= lcg_scc_of.len { -1 } else { lcg_scc_of[n] } }
fn lcg_lookup_rc(n: i32) -> i32 { let c = lcg_lookup_scc(n); if c < 0 { -1 } else { lcg_sccs[c].rc } }
fn lcg_lookup(f: i32) -> i32 { hm_get(lcg_node_map, (f as i64) as u64, -1) as i32 }
fn lcg_set_scc(n: i32, c: i32) {
    while lcg_scc_of.len <= (n as i64) { lcg_scc_of.push(-1); }
    lcg_scc_of[n] = c;
}

// LazyCallGraph::get(F)
fn lcg_get_node(f: i32) -> i32 {
    let n = lcg_lookup(f);
    if n >= 0 { return n; }
    let id = lcg_nodes.len as i32;
    lcg_nodes.push(LcgNode { f: f, dead: false, populated: false, dfs: 0, low: 0, edges: iv_new() });
    hm_put(lcg_node_map, (f as i64) as u64, id as i64);
    return id;
}

fn lcg_is_lib_function(f: i32) -> bool { for x in lcg_lib_fns { if x == f { return true; } } return false; }

// ---------------------------------------------------------------------------------------------
// EdgeSequence

fn lcg_seq_of(src: i32) -> i32 { if src < 0 { lcg_entry } else { lcg_nodes[src].edges } }
fn lcg_eidx_get(src: i32, t: i32) -> i64 { hm_get(lcg_eidx, hk2(src, t), -1) }
// EdgeSequence::lookup: index of a live edge to t, -1 if none
fn lcg_seq_lookup(src: i32, t: i32) -> i64 {
    let i = lcg_eidx_get(src, t);
    if i < 0 { return -1; }
    if !lcg_edge_ok(iv_get(lcg_seq_of(src), i)) { return -1; }
    return i;
}
fn lcg_has_edge(src: i32, t: i32) -> bool { lcg_seq_lookup(src, t) >= 0 }
fn lcg_edge_is_call(src: i32, t: i32) -> bool { let i = lcg_seq_lookup(src, t); i >= 0 && lcg_e_call(iv_get(lcg_seq_of(src), i)) }
// insertEdgeInternal
fn lcg_insert_edge_internal(src: i32, t: i32, call: bool) {
    let s = lcg_seq_of(src);
    if !hm_has(lcg_eidx, hk2(src, t)) { hm_put(lcg_eidx, hk2(src, t), iv_len(s)); }
    iv_push(s, lcg_mk_edge(t, call));
}
// setEdgeKind
fn lcg_set_edge_kind(src: i32, t: i32, call: bool) {
    let i = lcg_eidx_get(src, t);
    iv_set(lcg_seq_of(src), i, lcg_mk_edge(t, call));
}
// removeEdgeInternal
fn lcg_remove_edge_internal(src: i32, t: i32) -> bool {
    let i = lcg_eidx_get(src, t);
    if i < 0 { return false; }
    iv_set(lcg_seq_of(src), i, -1);
    hm_del(lcg_eidx, hk2(src, t));
    return true;
}
// static addEdge
fn lcg_add_edge(src: i32, t: i32, call: bool) {
    if hm_has(lcg_eidx, hk2(src, t)) { return; }
    let s = lcg_seq_of(src);
    hm_put(lcg_eidx, hk2(src, t), iv_len(s));
    iv_push(s, lcg_mk_edge(t, call));
}
fn lcg_seq_empty(src: i32) -> bool {
    let s = lcg_seq_of(src);
    let n = iv_len(s);
    for k in n { if lcg_edge_ok(iv_get(s, k)) { return false; } }
    return true;
}
// Next live edge (iterator) / live call edge (call_iterator) at or after k; returns the length at the end.
fn lcg_next_edge(s: i32, k: i64) -> i64 {
    var i = k;
    let n = iv_len(s);
    while i < n && !lcg_edge_ok(iv_get(s, i)) { i++; }
    return i;
}
fn lcg_next_call(s: i32, k: i64) -> i64 {
    var i = k;
    let n = iv_len(s);
    while i < n && (!lcg_edge_ok(iv_get(s, i)) || !lcg_e_call(iv_get(s, i))) { i++; }
    return i;
}

// ---------------------------------------------------------------------------------------------
// Construction

// visitReferences: `out` gets the functions found, in callback order. `visited` holds value ids.
fn lcg_visit_references(worklist: i32[>..<]&, visited: HMap&, out: i32[>..<]&) {
    while worklist.len > 0 {
        let c = worklist.pop();
        let k = vals[c].kind;
        if k == VK_FUNC {
            if !func_is_decl(c) { out.push(c); }
            continue;
        }
        if k == VK_BLOCKADDR { continue; }
        let n = nops(c);
        for j in n {
            let o = op(c, j);
            if o < 0 { continue; }
            let key = (o as i64) as u64;
            if hm_has(visited, key) { continue; }
            hm_put(visited, key, 1);
            worklist.push(o);
        }
    }
}

// The constant operands of I (I.operand_values() filtered by isa<Constant>), pushed when first visited.
fn lcg_push_const_operands(i: i32, worklist: i32[>..<]&, visited: HMap&) {
    let n = nops(i);
    for k in n {
        let o = op(i, k);
        if o < 0 || !is_constant(o) { continue; }
        let key = (o as i64) as u64;
        if hm_has(visited, key) { continue; }
        hm_put(visited, key, 1);
        worklist.push(o);
    }
}

// Node::populate / populateSlow
fn lcg_populate(n: i32) {
    if lcg_nodes[n].populated { return; }
    lcg_nodes[n].populated = true;
    let f = lcg_nodes[n].f;
    var worklist: i32[>..<] = [];
    var visited = hm_new();
    var callees = hm_new();
    each_inst(f) { i =>
        if is_callbase(i) {
            let callee = called_function(i);
            if callee >= 0 && !func_is_decl(callee) && !hm_has(callees, (callee as i64) as u64) {
                hm_put(callees, (callee as i64) as u64, 1);
                hm_put(visited, (callee as i64) as u64, 1);
                let t = lcg_get_node(callee);
                lcg_add_edge(n, t, true);
            }
        }
        lcg_push_const_operands(i, worklist, visited);
    };
    var refs: i32[>..<] = [];
    lcg_visit_references(worklist, visited, refs);
    for r in refs { let t = lcg_get_node(r); lcg_add_edge(n, t, false); }
    for k in lcg_lib_fns.len {
        let lf = lcg_lib_fns[k];
        if hm_has(visited, (lf as i64) as u64) { continue; }
        let t = lcg_get_node(lf);
        lcg_add_edge(n, t, false);
    }
}

fn lcg_has_local_linkage(v: i32) -> bool { let l = globs[glob_of(v)].linkage as i64; l == LK_INTERNAL || l == LK_PRIVATE }

// LazyCallGraph::LazyCallGraph(Module &M, GetTLI). isKnownLibFunction: TLI.getLibFunc (no vector libraries).
fn lcg_build(m: i32) {
    lcg_invalidate();
    lcg_valid = true;
    lcg_module = m;
    lcg_entry = iv_new();
    lcg_postorder = iv_new();
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) {
            if tli_get_libfunc(f) >= 0 && !lcg_is_lib_function(f) { lcg_lib_fns.push(f); }
            if !lcg_has_local_linkage(f) { lcg_add_edge(-1, lcg_get_node(f), false); }
        }
        f = globs[glob_of(f)].next;
    }
    var a = modules[m].first_alias;
    while a >= 0 {
        if !lcg_has_local_linkage(a) {
            let al = op(a, 0);
            if al >= 0 && vals[al].kind == VK_FUNC { lcg_add_edge(-1, lcg_get_node(al), false); }
        }
        a = globs[glob_of(a)].next;
    }
    var worklist: i32[>..<] = [];
    var visited = hm_new();
    var g = modules[m].first_gvar;
    while g >= 0 {
        if nops(g) > 0 {
            let init = op(g, 0);
            if init >= 0 && !hm_has(visited, (init as i64) as u64) {
                hm_put(visited, (init as i64) as u64, 1);
                worklist.push(init);
            }
        }
        g = globs[glob_of(g)].next;
    }
    var refs: i32[>..<] = [];
    lcg_visit_references(worklist, visited, refs);
    for r in refs { lcg_add_edge(-1, lcg_get_node(r), false); }
}

// AM.getResult<LazyCallGraphAnalysis>(M)
fn lcg_get(m: i32) { if !lcg_valid || lcg_module != m { lcg_build(m); } }

fn lcg_create_scc(rc: i32) -> i32 {
    let id = lcg_sccs.len as i32;
    lcg_sccs.push(LcgScc { rc: rc, nodes: iv_new(), idx: -1 });
    return id;
}
fn lcg_create_rc() -> i32 {
    let id = lcg_rcs.len as i32;
    lcg_rcs.push(LcgRc { dead: false, sccs: iv_new(), pidx: -1 });
    return id;
}
fn lcg_scc_size(c: i32) -> i64 { iv_len(lcg_sccs[c].nodes) }
fn lcg_scc_node(c: i32, k: i64) -> i32 { iv_get(lcg_sccs[c].nodes, k) }
fn lcg_rc_size(r: i32) -> i64 { iv_len(lcg_rcs[r].sccs) }
fn lcg_rc_scc(r: i32, k: i64) -> i32 { iv_get(lcg_rcs[r].sccs, k) }

// buildGenericSCCs for buildSCCs: the SCC walk over call edges inside RefSCC `rc`.
fn lcg_build_generic_calls(roots: i32[:], rc: i32) {
    var dfs_n: i32[>..<] = [];
    var dfs_i: i64[>..<] = [];
    var pending: i32[>..<] = [];
    for root in roots {
        if lcg_nodes[root].dfs != 0 { continue; }
        lcg_nodes[root].dfs = 1;
        lcg_nodes[root].low = 1;
        var next_dfs: i32 = 2;
        
        dfs_n.push(root);
        dfs_i.push(lcg_next_call(lcg_edges(root), 0));
        loop {
            var n = dfs_n.pop();
            var i = dfs_i.pop();
            var s = lcg_edges(n);
            while i < iv_len(s) {
                let child = lcg_e_node(iv_get(s, i));
                if lcg_nodes[child].dfs == 0 {
                    dfs_n.push(n);
                    dfs_i.push(i);
                    lcg_nodes[child].dfs = next_dfs;
                    lcg_nodes[child].low = next_dfs;
                    next_dfs++;
                    n = child;
                    
                    s = lcg_edges(n);
                    i = lcg_next_call(s, 0);
                    continue;
                }
                if lcg_nodes[child].dfs == -1 {
                    i = lcg_next_call(s, i + 1);
                    continue;
                }
                if lcg_nodes[child].low < lcg_nodes[n].low { lcg_nodes[n].low = lcg_nodes[child].low; }
                i = lcg_next_call(s, i + 1);
            }
            pending.push(n);
            if lcg_nodes[n].low == lcg_nodes[n].dfs {
                let root_dfs = lcg_nodes[n].dfs;
                // SCCNodes = reverse range from the top of pending down to the first node with a lower DFS number
                var b = pending.len;
                while b > 0 && lcg_nodes[pending[b - 1]].dfs >= root_dfs { b--; }
                var nodes: i32[>..] = [];
                var k = pending.len - 1;
                while k >= b { nodes.push(pending[k]); k--; }
                                    let c = lcg_create_scc(rc);
                    for x in nodes { iv_push(lcg_sccs[c].nodes, x); }
                    iv_push(lcg_rcs[rc].sccs, c);
                    for x in nodes {
                        lcg_nodes[x].dfs = -1;
                        lcg_nodes[x].low = -1;
                        lcg_set_scc(x, c);
                    }
                pending.resize(b);
            }
            if dfs_n.len == 0 { break; }
        }
    }
}

// buildGenericSCCs for buildRefSCCs: the RefSCC walk over all edges from the roots (populating nodes).
fn lcg_build_generic_refs(roots: i32[:]) {
    var dfs_n: i32[>..<] = [];
    var dfs_i: i64[>..<] = [];
    var pending: i32[>..<] = [];
    for root in roots {
        if lcg_nodes[root].dfs != 0 { continue; }
        lcg_nodes[root].dfs = 1;
        lcg_nodes[root].low = 1;
        var next_dfs: i32 = 2;
        lcg_populate(root);
        dfs_n.push(root);
        dfs_i.push(lcg_next_edge(lcg_edges(root), 0));
        loop {
            var n = dfs_n.pop();
            var i = dfs_i.pop();
            var s = lcg_edges(n);
            while i < iv_len(s) {
                let child = lcg_e_node(iv_get(s, i));
                if lcg_nodes[child].dfs == 0 {
                    dfs_n.push(n);
                    dfs_i.push(i);
                    lcg_nodes[child].dfs = next_dfs;
                    lcg_nodes[child].low = next_dfs;
                    next_dfs++;
                    n = child;
                    lcg_populate(n);
                    s = lcg_edges(n);
                    i = lcg_next_edge(s, 0);
                    continue;
                }
                if lcg_nodes[child].dfs == -1 {
                    i = lcg_next_edge(s, i + 1);
                    continue;
                }
                if lcg_nodes[child].low < lcg_nodes[n].low { lcg_nodes[n].low = lcg_nodes[child].low; }
                i = lcg_next_edge(s, i + 1);
            }
            pending.push(n);
            if lcg_nodes[n].low == lcg_nodes[n].dfs {
                let root_dfs = lcg_nodes[n].dfs;
                // SCCNodes = reverse range from the top of pending down to the first node with a lower DFS number
                var b = pending.len;
                while b > 0 && lcg_nodes[pending[b - 1]].dfs >= root_dfs { b--; }
                var nodes: i32[>..] = [];
                var k = pending.len - 1;
                while k >= b { nodes.push(pending[k]); k--; }
                lcg_form_ref_scc(nodes);
                pending.resize(b);
            }
            if dfs_n.len == 0 { break; }
        }
    }
}

// buildRefSCCs' FormSCC callback: createRefSCC, buildSCCs, append to the postorder.
fn lcg_form_ref_scc(nodes: i32[:]) {
    let rc = lcg_create_rc();
    lcg_build_sccs(rc, nodes);
    lcg_rcs[rc].pidx = iv_len(lcg_postorder) as i32;
    iv_push(lcg_postorder, rc);
}

// buildSCCs
fn lcg_build_sccs(rc: i32, nodes: i32[:]) {
    for x in nodes { lcg_nodes[x].dfs = 0; lcg_nodes[x].low = 0; }
    lcg_build_generic_calls(nodes, rc);
    let n = lcg_rc_size(rc);
    for k in n { lcg_sccs[lcg_rc_scc(rc, k)].idx = k as i32; }
}

// buildRefSCCs
fn lcg_build_ref_sccs() {
    if lcg_seq_empty(-1) || iv_len(lcg_postorder) > 0 { return; }
    var roots: i32[>..] = [];
    let s = lcg_entry;
    var i = lcg_next_edge(s, 0);
    while i < iv_len(s) { roots.push(lcg_e_node(iv_get(s, i))); i = lcg_next_edge(s, i + 1); }
    lcg_build_generic_refs(roots);
}

// postorder_ref_scc_iterator: the first non-empty RefSCC at or after postorder index k (-1 = end)
fn lcg_postorder_from(k: i64) -> i32 {
    var i = k;
    while i < iv_len(lcg_postorder) {
        let r = iv_get(lcg_postorder, i);
        if lcg_rc_size(r) != 0 { return r; }
        i++;
    }
    return -1;
}
fn lcg_postorder_next(r: i32) -> i32 { lcg_postorder_from((lcg_rcs[r].pidx as i64) + 1) }

// ---------------------------------------------------------------------------------------------
// SCC / RefSCC queries

fn lcg_scc_is_parent_of(c: i32, t: i32) -> bool {
    if c == t { return false; }
    let n = lcg_scc_size(c);
    for k in n {
        let s = lcg_edges(lcg_scc_node(c, k));
        var i = lcg_next_call(s, 0);
        while i < iv_len(s) {
            if lcg_lookup_scc(lcg_e_node(iv_get(s, i))) == t { return true; }
            i = lcg_next_call(s, i + 1);
        }
    }
    return false;
}

fn lcg_scc_is_ancestor_of(c0: i32, t: i32) -> bool {
    if c0 == t { return false; }
    var visited = hm_new();
    var wl: i32[>..<] = [c0];
    hm_put(visited, (c0 as i64) as u64, 1);
    loop {
        let c = wl.pop();
        let n = lcg_scc_size(c);
        for k in n {
            let s = lcg_edges(lcg_scc_node(c, k));
            var i = lcg_next_call(s, 0);
            while i < iv_len(s) {
                let cc = lcg_lookup_scc(lcg_e_node(iv_get(s, i)));
                i = lcg_next_call(s, i + 1);
                if cc < 0 { continue; }
                if cc == t { return true; }
                if !hm_has(visited, (cc as i64) as u64) { hm_put(visited, (cc as i64) as u64, 1); wl.push(cc); }
            }
        }
        if wl.len == 0 { break; }
    }
    return false;
}

fn lcg_rc_is_parent_of(r: i32, t: i32) -> bool {
    if r == t { return false; }
    let nc = lcg_rc_size(r);
    for ci in nc {
        let c = lcg_rc_scc(r, ci);
        let n = lcg_scc_size(c);
        for k in n {
            let s = lcg_edges(lcg_scc_node(c, k));
            var i = lcg_next_edge(s, 0);
            while i < iv_len(s) {
                if lcg_lookup_rc(lcg_e_node(iv_get(s, i))) == t { return true; }
                i = lcg_next_edge(s, i + 1);
            }
        }
    }
    return false;
}

fn lcg_rc_is_ancestor_of(r0: i32, t: i32) -> bool {
    if r0 == t { return false; }
    var visited = hm_new();
    var wl: i32[>..<] = [r0];
    hm_put(visited, (r0 as i64) as u64, 1);
    loop {
        let r = wl.pop();
        let nc = lcg_rc_size(r);
        for ci in nc {
            let c = lcg_rc_scc(r, ci);
            let n = lcg_scc_size(c);
            for k in n {
                let s = lcg_edges(lcg_scc_node(c, k));
                var i = lcg_next_edge(s, 0);
                while i < iv_len(s) {
                    let cr = lcg_lookup_rc(lcg_e_node(iv_get(s, i)));
                    i = lcg_next_edge(s, i + 1);
                    if cr == t { return true; }
                    if cr < 0 || hm_has(visited, (cr as i64) as u64) { continue; }
                    hm_put(visited, (cr as i64) as u64, 1);
                    wl.push(cr);
                }
            }
        }
        if wl.len == 0 { break; }
    }
    return false;
}

// RefSCC::find(C) - begin(): the position of SCC c in its RefSCC
fn lcg_rc_find(r: i32, c: i32) -> i64 { iv_find(lcg_rcs[r].sccs, c) }

// ---------------------------------------------------------------------------------------------
// updatePostorderSequenceForEdgeInsertion. `seq` is the postorder vector, `level` 0 = SCCs of a RefSCC (index
// in LcgScc.idx), 1 = RefSCCs of the graph (index in LcgRc.pidx). The connected sets are value-keyed HMaps.
// Returns the merge range [b, e) (b == e: nothing to merge).

fn lcg_set_index(level: i64, x: i32, i: i64) { if level == 0 { lcg_sccs[x].idx = i as i32; } else { lcg_rcs[x].pidx = i as i32; } }
fn lcg_get_index(level: i64, x: i32) -> i64 { if level == 0 { lcg_sccs[x].idx as i64 } else { lcg_rcs[x].pidx as i64 } }

// std::stable_partition of seq[b, e) by `in_set == first`; returns the partition point.
fn lcg_stable_partition(seq: i32, b: i64, e: i64, set: HMap&, first_in: bool) -> i64 {
    var a: i32[>..<] = [];
    var c: i32[>..<] = [];
    for k in b..e {
        let x = iv_get(seq, k);
        let ins = hm_has(set, (x as i64) as u64);
        if ins == first_in { a.push(x); } else { c.push(x); }
    }
    var p = b;
    for x in a { iv_set(seq, p, x); p++; }
    let mid = p;
    for x in c { iv_set(seq, p, x); p++; }
    return mid;
}

// The source/target connected-set computations for an SCC-level insertion (switchInternalEdgeToCall) and a
// RefSCC-level one (insertIncomingRefEdge).
fn lcg_scc_source_connected(rc: i32, src_c: i32, src_idx: i64, tgt_idx: i64, set: HMap&) {
    hm_put(set, (src_c as i64) as u64, 1);
    for k in src_idx + 1..tgt_idx + 1 {
        let c = lcg_rc_scc(rc, k);
        var connected = false;
        let n = lcg_scc_size(c);
        for j in n {
            if connected { break; }
            let s = lcg_edges(lcg_scc_node(c, j));
            var i = lcg_next_call(s, 0);
            while i < iv_len(s) {
                let ec = lcg_lookup_scc(lcg_e_node(iv_get(s, i)));
                if ec >= 0 && hm_has(set, (ec as i64) as u64) { connected = true; break; }
                i = lcg_next_call(s, i + 1);
            }
        }
        if connected { hm_put(set, (c as i64) as u64, 1); }
    }
}
fn lcg_scc_target_connected(rc: i32, tgt_c: i32, src_idx: i64, set: HMap&) {
    hm_put(set, (tgt_c as i64) as u64, 1);
    var wl: i32[>..<] = [tgt_c];
    loop {
        let c = wl.pop();
        let n = lcg_scc_size(c);
        for j in n {
            let s = lcg_edges(lcg_scc_node(c, j));
            var i = lcg_next_edge(s, 0);
            while i < iv_len(s) {
                let e = iv_get(s, i);
                i = lcg_next_edge(s, i + 1);
                if !lcg_e_call(e) { continue; }
                let ec = lcg_lookup_scc(lcg_e_node(e));
                if lcg_sccs[ec].rc != rc { continue; }
                if (lcg_sccs[ec].idx as i64) <= src_idx { continue; }
                if !hm_has(set, (ec as i64) as u64) { hm_put(set, (ec as i64) as u64, 1); wl.push(ec); }
            }
        }
        if wl.len == 0 { break; }
    }
}
fn lcg_rc_source_connected(src_rc: i32, src_idx: i64, tgt_idx: i64, set: HMap&) {
    hm_put(set, (src_rc as i64) as u64, 1);
    for k in src_idx + 1..tgt_idx + 1 {
        let r = iv_get(lcg_postorder, k);
        var connected = false;
        let nc = lcg_rc_size(r);
        for ci in nc {
            if connected { break; }
            let c = lcg_rc_scc(r, ci);
            let n = lcg_scc_size(c);
            for j in n {
                if connected { break; }
                let s = lcg_edges(lcg_scc_node(c, j));
                var i = lcg_next_edge(s, 0);
                while i < iv_len(s) {
                    let er = lcg_lookup_rc(lcg_e_node(iv_get(s, i)));
                    if er >= 0 && hm_has(set, (er as i64) as u64) { connected = true; break; }
                    i = lcg_next_edge(s, i + 1);
                }
            }
        }
        if connected { hm_put(set, (r as i64) as u64, 1); }
    }
}
fn lcg_rc_target_connected(tgt_rc: i32, src_idx: i64, set: HMap&) {
    hm_put(set, (tgt_rc as i64) as u64, 1);
    var wl: i32[>..<] = [tgt_rc];
    loop {
        let r = wl.pop();
        let nc = lcg_rc_size(r);
        for ci in nc {
            let c = lcg_rc_scc(r, ci);
            let n = lcg_scc_size(c);
            for j in n {
                let s = lcg_edges(lcg_scc_node(c, j));
                var i = lcg_next_edge(s, 0);
                while i < iv_len(s) {
                    let er = lcg_lookup_rc(lcg_e_node(iv_get(s, i)));
                    i = lcg_next_edge(s, i + 1);
                    if (lcg_rcs[er].pidx as i64) <= src_idx { continue; }
                    if !hm_has(set, (er as i64) as u64) { hm_put(set, (er as i64) as u64, 1); wl.push(er); }
                }
            }
        }
        if wl.len == 0 { break; }
    }
}

// level 0: rc is the RefSCC holding both SCCs; level 1: the graph's postorder.
fn lcg_update_postorder(level: i64, rc: i32, src: i32, tgt: i32) -> i64, i64 {
    let seq = if level == 0 { lcg_rcs[rc].sccs } else { lcg_postorder };
    var src_idx = lcg_get_index(level, src);
    var tgt_idx = lcg_get_index(level, tgt);
    var set = hm_new();
    if level == 0 { lcg_scc_source_connected(rc, src, src_idx, tgt_idx, set); }
    else { lcg_rc_source_connected(src, src_idx, tgt_idx, set); }
    let source_i = lcg_stable_partition(seq, src_idx, tgt_idx + 1, set, false);
    for k in src_idx..tgt_idx + 1 { lcg_set_index(level, iv_get(seq, k), k); }
    if !hm_has(set, (tgt as i64) as u64) {
        return source_i - 1, source_i - 1;
    }
    src_idx = source_i;
    if src_idx + 1 < tgt_idx {
        hm_clear(set);
        if level == 0 { lcg_scc_target_connected(rc, tgt, src_idx, set); }
        else { lcg_rc_target_connected(tgt, src_idx, set); }
        let target_i = lcg_stable_partition(seq, src_idx + 1, tgt_idx + 1, set, true);
        for k in src_idx + 1..tgt_idx + 1 { lcg_set_index(level, iv_get(seq, k), k); }
        tgt_idx = target_i - 1;
    }
    return src_idx, tgt_idx;
}

// ---------------------------------------------------------------------------------------------
// RefSCC updates

// switchInternalEdgeToCall. `merged` receives the merged SCCs (the MergeCB argument, before merging).
fn lcg_switch_internal_edge_to_call(rc: i32, sn: i32, tn: i32, merged: i32[>..<]&) -> bool {
    let src_c = lcg_lookup_scc(sn);
    let tgt_c = lcg_lookup_scc(tn);
    if src_c == tgt_c { lcg_set_edge_kind(sn, tn, true); return false; }
    let src_idx = lcg_sccs[src_c].idx;
    let tgt_idx = lcg_sccs[tgt_c].idx;
    if tgt_idx < src_idx { lcg_set_edge_kind(sn, tn, true); return false; }
    let mb, me = lcg_update_postorder(0, rc, src_c, tgt_c);
    let seq = lcg_rcs[rc].sccs;
    for k in mb..me { merged.push(iv_get(seq, k)); }
    if mb == me { lcg_set_edge_kind(sn, tn, true); return false; }
    let tnodes = lcg_sccs[tgt_c].nodes;
    for k in mb..me {
        let c = iv_get(seq, k);
        lcg_sccs[c].idx = -1;
        let cn = lcg_sccs[c].nodes;
        let m = iv_len(cn);
        for j in m { iv_push(tnodes, iv_get(cn, j)); }
        for j in m { lcg_set_scc(iv_get(cn, j), tgt_c); }
        iv_clear(cn);
    }
    let off = me - mb;
    iv_erase_range(seq, mb, me);
    let n = iv_len(seq);
    for k in mb..n { let c = iv_get(seq, k); lcg_sccs[c].idx -= off as i32; }
    lcg_set_edge_kind(sn, tn, true);
    return true;
}

fn lcg_switch_trivial_internal_edge_to_ref(sn: i32, tn: i32) { lcg_set_edge_kind(sn, tn, false); }

// switchInternalEdgeToRef: returns the range [b, e) of new SCCs in the RefSCC's SCC list.
fn lcg_switch_internal_edge_to_ref(rc: i32, sn: i32, tn: i32) -> i64, i64 {
    let old = lcg_lookup_scc(tn);
    lcg_set_edge_kind(sn, tn, false);
    var dfs_n: i32[>..<] = [];
    var dfs_i: i64[>..<] = [];
    var pending: i32[>..<] = [];
    var new_sccs: i32[>..<] = [];
    let worklist = iv_new();
    iv_swap(worklist, lcg_sccs[old].nodes);
    let wn = iv_len(worklist);
    for k in wn {
        let x = iv_get(worklist, k);
        lcg_nodes[x].dfs = 0;
        lcg_nodes[x].low = 0;
        lcg_scc_of[x] = -1;
    }
    let onodes = lcg_sccs[old].nodes;
    lcg_nodes[tn].dfs = -1;
    lcg_nodes[tn].low = -1;
    iv_push(onodes, tn);
    lcg_set_scc(tn, old);
    for wk in wn {
        let root = iv_get(worklist, wk);
        if lcg_nodes[root].dfs != 0 { continue; }
        lcg_nodes[root].dfs = 1;
        lcg_nodes[root].low = 1;
        var next_dfs: i32 = 2;
        dfs_n.push(root);
        dfs_i.push(lcg_next_call(lcg_edges(root), 0));
        loop {
            var n = dfs_n.pop();
            var i = dfs_i.pop();
            var s = lcg_edges(n);
            var reached_old = false;
            while i < iv_len(s) {
                let child = lcg_e_node(iv_get(s, i));
                if lcg_nodes[child].dfs == 0 {
                    dfs_n.push(n);
                    dfs_i.push(i);
                    lcg_nodes[child].dfs = next_dfs;
                    lcg_nodes[child].low = next_dfs;
                    next_dfs++;
                    n = child;
                    s = lcg_edges(n);
                    i = lcg_next_call(s, 0);
                    continue;
                }
                if lcg_nodes[child].dfs == -1 {
                    if lcg_lookup_scc(child) == old {
                        // everything on the stack connects to the target: it joins the old SCC
                        let old_size = iv_len(onodes);
                        iv_push(onodes, n);
                        for x in pending { iv_push(onodes, x); }
                        pending.resize(0);
                        while dfs_n.len > 0 { iv_push(onodes, dfs_n.pop()); dfs_i.pop(); }
                        let total = iv_len(onodes);
                        for j in old_size..total {
                            let x = iv_get(onodes, j);
                            lcg_nodes[x].dfs = -1;
                            lcg_nodes[x].low = -1;
                            lcg_set_scc(x, old);
                        }
                        reached_old = true;
                        break;
                    }
                    i = lcg_next_call(s, i + 1);
                    continue;
                }
                if lcg_nodes[child].low < lcg_nodes[n].low { lcg_nodes[n].low = lcg_nodes[child].low; }
                i = lcg_next_call(s, i + 1);
            }
            if reached_old { break; }
            pending.push(n);
            if lcg_nodes[n].low == lcg_nodes[n].dfs {
                let root_dfs = lcg_nodes[n].dfs;
                var b = pending.len;
                while b > 0 && lcg_nodes[pending[b - 1]].dfs >= root_dfs { b--; }
                let c = lcg_create_scc(rc);
                var k = pending.len - 1;
                while k >= b { iv_push(lcg_sccs[c].nodes, pending[k]); k--; }
                new_sccs.push(c);
                let m = lcg_scc_size(c);
                for j in m {
                    let x = lcg_scc_node(c, j);
                    lcg_nodes[x].dfs = -1;
                    lcg_nodes[x].low = -1;
                    lcg_set_scc(x, c);
                }
                pending.resize(b);
            }
            if dfs_n.len == 0 { break; }
        }
    }
    let seq = lcg_rcs[rc].sccs;
    let old_idx = lcg_sccs[old].idx as i64;
    let tmp = iv_new();
    for c in new_sccs { iv_push(tmp, c); }
    iv_insert_range(seq, old_idx, tmp, 0, new_sccs.len);
    let n = iv_len(seq);
    for k in old_idx..n { lcg_sccs[iv_get(seq, k)].idx = k as i32; }
    return old_idx, old_idx + new_sccs.len;
}

fn lcg_switch_outgoing_edge_to_call(sn: i32, tn: i32) { lcg_set_edge_kind(sn, tn, true); }
fn lcg_switch_outgoing_edge_to_ref(sn: i32, tn: i32) { lcg_set_edge_kind(sn, tn, false); }
fn lcg_insert_internal_ref_edge(sn: i32, tn: i32) { lcg_insert_edge_internal(sn, tn, false); }
fn lcg_insert_outgoing_edge(sn: i32, tn: i32, call: bool) { lcg_insert_edge_internal(sn, tn, call); }

// insertIncomingRefEdge on RefSCC `rc` (the target's); deleted RefSCCs are pushed to `deleted`.
fn lcg_insert_incoming_ref_edge(rc: i32, sn: i32, tn: i32, deleted: i32[>..<]&) {
    let src_rc = lcg_lookup_rc(sn);
    let mb, me = lcg_update_postorder(1, -1, src_rc, rc);
    var merged: i32[>..] = [];
    var scc_index: i32 = 0;
    for k in mb..me {
        let r = iv_get(lcg_postorder, k);
        let nc = lcg_rc_size(r);
        for ci in nc {
            let c = lcg_rc_scc(r, ci);
            lcg_sccs[c].rc = rc;
            lcg_sccs[c].idx = scc_index;
            scc_index++;
            let n = lcg_scc_size(c);
            for j in n { lcg_set_scc(lcg_scc_node(c, j), c); }
        }
        for ci in nc { merged.push(lcg_rc_scc(r, ci)); }
        iv_clear(lcg_rcs[r].sccs);
        deleted.push(r);
    }
    let own = lcg_rcs[rc].sccs;
    let on = iv_len(own);
    for ci in on { lcg_sccs[iv_get(own, ci)].idx = scc_index; scc_index++; }
    for ci in on { merged.push(iv_get(own, ci)); }
    iv_clear(own);
    for c in merged { iv_push(own, c); }
    for k in mb..me { lcg_rcs[iv_get(lcg_postorder, k)].pidx = -1; }
    let off = me - mb;
    iv_erase_range(lcg_postorder, mb, me);
    let n = iv_len(lcg_postorder);
    for k in mb..n { let r = iv_get(lcg_postorder, k); lcg_rcs[r].pidx -= off as i32; }
    lcg_insert_edge_internal(sn, tn, false);
}

fn lcg_remove_outgoing_edge(sn: i32, tn: i32) { lcg_remove_edge_internal(sn, tn); }

// removeInternalRefEdges on RefSCC rc; `es` holds (source, target) pairs flattened. New RefSCCs (in postorder)
// go to `result` (empty when the RefSCC stays intact).
fn lcg_remove_internal_ref_edges(rc: i32, es: i32[:], result: i32[>..<]&) {
    var k: i64 = 0;
    while k < es.len { lcg_remove_edge_internal(es[k], es[k + 1]); k += 2; }
    var all_trivial = true;
    k = 0;
    while k < es.len {
        if !(es[k] == es[k + 1] || lcg_lookup_scc(es[k]) == lcg_lookup_scc(es[k + 1])) { all_trivial = false; break; }
        k += 2;
    }
    if all_trivial { return; }
    var post_num: i32 = 0;
    var worklist: i32[>..<] = [];
    let nc = lcg_rc_size(rc);
    for ci in nc {
        let c = lcg_rc_scc(rc, ci);
        let n = lcg_scc_size(c);
        for j in n { let x = lcg_scc_node(c, j); lcg_nodes[x].dfs = 0; lcg_nodes[x].low = 0; }
        for j in n { worklist.push(lcg_scc_node(c, j)); }
    }
    let num_nodes = worklist.len;
    var dfs_n: i32[>..<] = [];
    var dfs_i: i64[>..<] = [];
    var pending: i32[>..<] = [];
    loop {
        let root = worklist.pop();
        if lcg_nodes[root].dfs != 0 {
            if worklist.len == 0 { break; }
            continue;
        }
        lcg_nodes[root].dfs = 1;
        lcg_nodes[root].low = 1;
        var next_dfs: i32 = 2;
        dfs_n.push(root);
        dfs_i.push(lcg_next_edge(lcg_edges(root), 0));
        loop {
            var n = dfs_n.pop();
            var i = dfs_i.pop();
            var s = lcg_edges(n);
            while i < iv_len(s) {
                let child = lcg_e_node(iv_get(s, i));
                if lcg_nodes[child].dfs == 0 {
                    dfs_n.push(n);
                    dfs_i.push(i);
                    lcg_nodes[child].low = next_dfs;
                    lcg_nodes[child].dfs = next_dfs;
                    next_dfs++;
                    n = child;
                    s = lcg_edges(n);
                    i = lcg_next_edge(s, 0);
                    continue;
                }
                if lcg_nodes[child].dfs == -1 { i = lcg_next_edge(s, i + 1); continue; }
                let cl = lcg_nodes[child].low;
                if cl >= 0 && cl < lcg_nodes[n].low { lcg_nodes[n].low = cl; }
                i = lcg_next_edge(s, i + 1);
            }
            pending.push(n);
            if lcg_nodes[n].low != lcg_nodes[n].dfs {
                if dfs_n.len == 0 { break; }
                continue;
            }
            let rnum = post_num;
            post_num++;
            let root_dfs = lcg_nodes[n].dfs;
            var b = pending.len;
            while b > 0 {
                let x = pending[b - 1];
                if lcg_nodes[x].dfs < root_dfs { break; }
                lcg_nodes[x].dfs = -1;
                lcg_nodes[x].low = rnum;
                b--;
            }
            if pending.len - b == num_nodes {
                for j in b..pending.len { lcg_nodes[pending[j]].low = -1; }
                return;
            }
            pending.resize(b);
            if dfs_n.len == 0 { break; }
        }
        if worklist.len == 0 { break; }
    }
    for j in post_num { result.push(lcg_create_rc()); }
    let idx = lcg_rcs[rc].pidx as i64;
    iv_erase_range(lcg_postorder, idx, idx + 1);
    let tmp = iv_new();
    for r in result { iv_push(tmp, r); }
    iv_insert_range(lcg_postorder, idx, tmp, 0, result.len);
    let pn = iv_len(lcg_postorder);
    for j in idx..pn { lcg_rcs[iv_get(lcg_postorder, j)].pidx = j as i32; }
    for ci in nc {
        let c = lcg_rc_scc(rc, ci);
        let scc_num = lcg_nodes[lcg_scc_node(c, 0)].low;
        let n = lcg_scc_size(c);
        for j in n { lcg_nodes[lcg_scc_node(c, j)].low = -1; }
        let r = result[scc_num];
        let si = lcg_rc_size(r);
        iv_push(lcg_rcs[r].sccs, c);
        lcg_sccs[c].idx = si as i32;
        lcg_sccs[c].rc = r;
    }
    lcg_rcs[rc].dead = true;
    lcg_rcs[rc].pidx = -1;
    iv_clear(lcg_rcs[rc].sccs);
}

// insertTrivialCallEdge
fn lcg_insert_trivial_call_edge(sn: i32, tn: i32) {
    let i = lcg_eidx_get(sn, tn);
    let s = lcg_edges(sn);
    if i >= 0 {
        let e = iv_get(s, i);
        if lcg_e_call(e) { return; }
        iv_set(s, i, lcg_mk_edge(lcg_e_node(e), true));
    } else {
        hm_put(lcg_eidx, hk2(sn, tn), iv_len(s));
        iv_push(s, lcg_mk_edge(tn, true));
    }
}
// insertTrivialRefEdge
fn lcg_insert_trivial_ref_edge(sn: i32, tn: i32) {
    if hm_has(lcg_eidx, hk2(sn, tn)) { return; }
    let s = lcg_edges(sn);
    hm_put(lcg_eidx, hk2(sn, tn), iv_len(s));
    iv_push(s, lcg_mk_edge(tn, false));
}

// replaceNodeFunction
fn lcg_replace_node_function(n: i32, nf: i32) {
    let of = lcg_nodes[n].f;
    lcg_nodes[n].f = nf;
    hm_del(lcg_node_map, (of as i64) as u64);
    hm_put(lcg_node_map, (nf as i64) as u64, n as i64);
    for k in lcg_lib_fns.len {
        if lcg_lib_fns[k] == of {
            var rest: i32[>..] = [];
            for x in lcg_lib_fns { if x != of { rest.push(x); } }
            lcg_lib_fns.resize(0);
            for x in rest { lcg_lib_fns.push(x); }
            if !lcg_is_lib_function(nf) { lcg_lib_fns.push(nf); }
            break;
        }
    }
}

// markDeadFunction: turn the dead function's call edges into ref edges
fn lcg_mark_dead_function(f: i32) {
    let n = lcg_lookup(f);
    let s = lcg_edges(n);
    var i = lcg_next_edge(s, 0);
    while i < iv_len(s) {
        let e = iv_get(s, i);
        if lcg_e_call(e) { lcg_set_edge_kind(n, lcg_e_node(e), false); }
        i = lcg_next_edge(s, i + 1);
    }
}

// removeDeadFunctions. The DenseMap<RefSCC *, ...> is walked in first-insertion order (its order does not
// change the result: each dead function is alone in its RefSCC).
fn lcg_remove_dead_functions(dead: i32[:]) {
    if dead.len == 0 { return; }
    var rcs: i32[>..<] = [];
    var rc_nodes: i32[>..<] = [];     // parallel: dead node per entry
    for f in dead {
        let n = lcg_lookup(f);
        rcs.push(lcg_lookup_rc(n));
        rc_nodes.push(n);
    }
    var done: i32[>..<] = [];
    for k in rcs.len {
        let rc = rcs[k];
        var seen = false;
        for d in done { if d == rc { seen = true; } }
        if seen { continue; }
        done.push(rc);
        var internal: i32[>..] = [];
        for j in rcs.len {
            if rcs[j] != rc { continue; }
            let dn = rc_nodes[j];
            let s = lcg_edges(dn);
            var i = lcg_next_edge(s, 0);
            while i < iv_len(s) {
                let t = lcg_e_node(iv_get(s, i));
                i = lcg_next_edge(s, i + 1);
                if lcg_lookup_rc(t) == rc { internal.push(dn); internal.push(t); }
                else { lcg_remove_outgoing_edge(dn, t); }
            }
        }
        var res: i32[>..<] = [];
        lcg_remove_internal_ref_edges(rc, internal, res);
        for j in rcs.len {
            if rcs[j] != rc { continue; }
            let dr = lcg_lookup_rc(rc_nodes[j]);
            iv_clear(lcg_rcs[dr].sccs);
            lcg_rcs[dr].dead = true;
        }
    }
    for f in dead {
        let n = lcg_lookup(f);
        lcg_remove_edge_internal(-1, n);
        lcg_scc_of[n] = -1;
        hm_del(lcg_node_map, (f as i64) as u64);
        iv_clear(lcg_nodes[n].edges);
        lcg_nodes[n].dead = true;
        lcg_nodes[n].f = -1;
    }
}

// ---------------------------------------------------------------------------------------------
// print-lcg / print-lcg-dot

fn lcg_print_node(n: i32) {
    errs("  Edges in function: "); errs(val_name(lcg_fn(n))); errs("\n");
    lcg_populate(n);
    let s = lcg_edges(n);
    var i = lcg_next_edge(s, 0);
    while i < iv_len(s) {
        let e = iv_get(s, i);
        errs("    "); errs(if lcg_e_call(e) { "call" } else { "ref " }); errs(" -> ");
        errs(val_name(lcg_fn(lcg_e_node(e)))); errs("\n");
        i = lcg_next_edge(s, i + 1);
    }
    errs("\n");
}

fn module_identifier(m: i32) -> const u8[:] { if modules[m].module_id >= 0 { sbytes(modules[m].module_id) } else { "" } }

fn lcg_print_pass(m: i32) {
    lcg_get(m);
    errs("Printing the call graph for module: "); errs(module_identifier(m)); errs("\n\n");
    var f = modules[m].first_func;
    while f >= 0 { lcg_print_node(lcg_get_node(f)); f = globs[glob_of(f)].next; }
    lcg_build_ref_sccs();
    var r = lcg_postorder_from(0);
    while r >= 0 {
        errs("  RefSCC with "); errs_int(lcg_rc_size(r)); errs(" call SCCs:\n");
        let nc = lcg_rc_size(r);
        for ci in nc {
            let c = lcg_rc_scc(r, ci);
            errs("    SCC with "); errs_int(lcg_scc_size(c)); errs(" functions:\n");
            let n = lcg_scc_size(c);
            for j in n { errs("      "); errs(val_name(lcg_fn(lcg_scc_node(c, j)))); errs("\n"); }
        }
        errs("\n");
        r = lcg_postorder_next(r);
    }
}

// DOT::EscapeString
fn lcg_dot_escape(s: const u8[:]) {
    var k: i64 = 0;
    while k < s.len {
        let c = s[k];
        if c == '\\' {
            if k + 1 < s.len && (s[k + 1] == 'l' || s[k + 1] == '|' || s[k + 1] == '{' || s[k + 1] == '}') {
                errbuf.push(c);
            } else { errbuf.push('\\'); errbuf.push('\\'); }
        } else if c == '\t' { errbuf.append("  "); }
        else if c == '{' || c == '}' || c == '<' || c == '>' || c == '|' || c == '"' { errbuf.push('\\'); errbuf.push(c); }
        else if c == '\n' { errbuf.append("\\n"); }
        else { errbuf.push(c); }
        k++;
    }
}

fn lcg_print_dot_pass(m: i32) {
    lcg_get(m);
    errs("digraph \""); lcg_dot_escape(module_identifier(m)); errs("\" {\n");
    var f = modules[m].first_func;
    while f >= 0 {
        let n = lcg_get_node(f);
        lcg_populate(n);
        let s = lcg_edges(n);
        var i = lcg_next_edge(s, 0);
        while i < iv_len(s) {
            let e = iv_get(s, i);
            errs("  \""); lcg_dot_escape(val_name(f)); errs("\" -> \""); lcg_dot_escape(val_name(lcg_fn(lcg_e_node(e)))); errs("\"");
            if !lcg_e_call(e) { errs(" [style=dashed,label=\"ref\"]"); }
            errs(";\n");
            i = lcg_next_edge(s, i + 1);
        }
        errs("\n");
        f = globs[glob_of(f)].next;
    }
    errs("}\n");
}
