// Dominator and post-dominator trees.
// Port of llvm/include/llvm/Support/GenericDomTree.h (DomTreeNodeBase, DominatorTreeBase: createNode, eraseNode,
// findNearestCommonDominator, dominates, updateDFSNumbers, print), llvm/include/llvm/Support/
// GenericDomTreeConstruction.h (SemiNCAInfo: runDFS, runSemiNCA, FindRoots, RemoveRedundantRoots,
// CalculateFromScratch, InsertEdge/InsertReachable/InsertUnreachable, DeleteEdge/DeleteReachable/DeleteUnreachable,
// ApplyUpdates), llvm/include/llvm/Support/CFGDiff.h (GraphDiff) and llvm/include/llvm/Support/CFGUpdate.h
// (LegalizeUpdates), and llvm/include/llvm/Support/GenericIteratedDominanceFrontier.h (IDFCalculator).
//
// One Dom_Tree serves both directions; `post` selects the post-dominator behaviour (IsPostDom). Tree nodes are rows
// of `nodes` (s32 indices, -1 = null); the children of a node are an intrusive singly linked list in insertion order
// (FirstChild/Sibling/AppendPtr in LLVM), which is what makes child order, and therefore printing and every pass that
// walks the tree, match LLVM. The post-dominator virtual root is the node of block NONE.

Dom_Node :: struct {
    block: Value_Id;     // NONE: post-dominator virtual root
    idom: s32 = -1;
    first_child: s32 = -1;
    last_child: s32 = -1;
    sibling: s32 = -1;
    level: u32;
    dfs_in: u32 = 0xFFFF_FFFF;
    dfs_out: u32 = 0xFFFF_FFFF;
}

Dom_Tree :: struct {
    post: bool;
    fn: Value_Id = NONE;
    nodes: [..] Dom_Node;
    node_of: Table(Value_Id, s32);
    roots: [..] Value_Id;
    root_node: s32 = -1;
    dfs_valid: bool;
    slow_queries: u32;
    vec_size: u32;       // DomTreeNodes.size()
}

// ---------------------------------------------------------------- block numbers (Function::NextBlockNum)

// LLVM numbers blocks as they are inserted into a function (BasicBlock::Number, Function::NextBlockNum);
// DomTreeNodes is a vector indexed by number + 1 whose size ApplyUpdates compares with the number of updates.
// LLParser creates a block at its first mention (a forward reference from an operand, or its label), so the
// first time a function's numbers are needed we replay that order: blocks in layout order, and before each one the
// blocks its instructions name, in operand order. Blocks created later get the next number (note_block_created).
block_numbers: Table(Value_Id, u32);
fn_next_block_num: Table(Value_Id, u32);

ensure_block_numbers :: (f: Value_Id) {
    if table_contains(*fn_next_block_num, f) return;
    n: u32 = 0;
    num :: (b: Value_Id, n: *u32) {
        if table_contains(*block_numbers, b) return;
        table_set(*block_numbers, b, n.*);
        n.* += 1;
    }
    for b: fn_blocks(f) {
        num(b, *n);
        for i: block_insts(b) {
            k := nops(i);
            if k > 0 for o: 0..k-1 {
                v := op(i, o);
                if v != NONE && vkind(v) == .BLOCK && block(v).parent == f num(v, *n);
                if inst_op(i) == .PHI num(phi_block(i, o), *n);
            }
        }
    }
    table_set(*fn_next_block_num, f, n);
}
note_block_created :: (f: Value_Id, b: Value_Id) {
    found, n := table_find(*fn_next_block_num, f);
    if !found return;
    table_set(*block_numbers, b, n);
    table_set(*fn_next_block_num, f, n + 1);
}
block_number :: (b: Value_Id) -> u32 {
    ensure_block_numbers(block_fn(b));
    found, n := table_find(*block_numbers, b);
    assert(found);
    return n;
}

// ---------------------------------------------------------------- node API

dt_node :: inline (dt: *Dom_Tree, b: Value_Id) -> s32 {
    found, n := table_find(*dt.node_of, b);
    if found return n;
    return -1;
}
dt_level :: inline (dt: *Dom_Tree, n: s32) -> u32 { return dt.nodes[n].level; }
dt_idom :: inline (dt: *Dom_Tree, n: s32) -> s32 { return dt.nodes[n].idom; }
dt_block :: inline (dt: *Dom_Tree, n: s32) -> Value_Id { return dt.nodes[n].block; }
dt_idom_block :: (dt: *Dom_Tree, b: Value_Id) -> Value_Id {
    n := dt_node(dt, b);
    if n < 0 return NONE;
    i := dt.nodes[n].idom;
    if i < 0 return NONE;
    return dt.nodes[i].block;
}
dt_is_virtual_root :: inline (dt: *Dom_Tree, n: s32) -> bool { return dt.post && dt.nodes[n].block == NONE; }

dt_add_child :: (dt: *Dom_Tree, p: s32, c: s32) {
    if dt.nodes[p].last_child < 0 dt.nodes[p].first_child = c;
    else dt.nodes[dt.nodes[p].last_child].sibling = c;
    dt.nodes[p].last_child = c;
}
dt_remove_child :: (dt: *Dom_Tree, p: s32, c: s32) {
    prev: s32 = -1;
    it := dt.nodes[p].first_child;
    while it != c { assert(it >= 0, "Not in immediate dominator children list!"); prev = it; it = dt.nodes[it].sibling; }
    nx := dt.nodes[c].sibling;
    if prev < 0 dt.nodes[p].first_child = nx; else dt.nodes[prev].sibling = nx;
    if nx < 0 dt.nodes[p].last_child = prev;
    dt.nodes[c].sibling = -1;
}

// DomTreeNodeBase::UpdateLevel
dt_update_level :: (dt: *Dom_Tree, n: s32) {
    if dt.nodes[n].level == dt.nodes[dt.nodes[n].idom].level + 1 return;
    stack: [..] s32; stack.allocator = temp;
    array_add(*stack, n);
    while stack.count {
        cur := pop(*stack);
        dt.nodes[cur].level = dt.nodes[dt.nodes[cur].idom].level + 1;
        c := dt.nodes[cur].first_child;
        while c >= 0 {
            if dt.nodes[c].level != dt.nodes[dt.nodes[c].idom].level + 1 array_add(*stack, c);
            c = dt.nodes[c].sibling;
        }
    }
}
// DomTreeNodeBase::setIDom
dt_set_idom :: (dt: *Dom_Tree, n: s32, new_idom: s32) {
    old := dt.nodes[n].idom;
    if old == new_idom return;
    dt_remove_child(dt, old, n);
    dt.nodes[n].idom = new_idom;
    dt_add_child(dt, new_idom, n);
    dt_update_level(dt, n);
}

// DominatorTreeBase::createNode
dt_create_node :: (dt: *Dom_Tree, b: Value_Id, idom: s32 = -1) -> s32 {
    nd: Dom_Node;
    nd.block = b;
    nd.idom = idom;
    nd.level = ifx idom >= 0 then dt.nodes[idom].level + 1 else 0;
    id := cast(s32) dt.nodes.count;
    array_add(*dt.nodes, nd);
    table_set(*dt.node_of, b, id);
    // getNodeIndexForInsert: resize to max(getMaxBlockNumber(), Idx + 1) when Idx doesn't fit
    ensure_block_numbers(dt.fn);
    idx: u32 = ifx b == NONE then 0 else block_number(b) + 1;
    if idx >= dt.vec_size {
        _, mx := table_find(*fn_next_block_num, dt.fn);
        dt.vec_size = max(mx, idx + 1);
    }
    if idom >= 0 dt_add_child(dt, idom, id);
    return id;
}

// DominatorTreeBase::eraseNode
dt_erase_node :: (dt: *Dom_Tree, b: Value_Id) {
    n := dt_node(dt, b);
    assert(n >= 0, "Removing node that isn't in dominator tree.");
    assert(dt.nodes[n].first_child < 0, "Node is not a leaf node.");
    dt.dfs_valid = false;
    if dt.nodes[n].idom >= 0 dt_remove_child(dt, dt.nodes[n].idom, n);
    table_remove(*dt.node_of, b);
    if !dt.post return;
    for dt.roots if it == b {
        dt.roots[it_index] = dt.roots[dt.roots.count - 1];
        dt.roots.count -= 1;
        break;
    }
}

dt_reset :: (dt: *Dom_Tree) {
    dt.nodes.count = 0;
    table_reset(*dt.node_of);
    dt.roots.count = 0;
    dt.root_node = -1;
    dt.dfs_valid = false;
    dt.slow_queries = 0;
    dt.vec_size = 0;
}

dt_entry :: (dt: *Dom_Tree) -> Value_Id { return fn_entry(dt.fn); }

// findNearestCommonDominator(A, B)
dt_find_nca :: (dt: *Dom_Tree, a: Value_Id, b: Value_Id) -> Value_Id {
    if !dt.post {
        e := dt_entry(dt);
        if a == e || b == e return e;
    }
    na := dt_node(dt, a); nb := dt_node(dt, b);
    assert(na >= 0 && nb >= 0, "findNearestCommonDominator: blocks must be in the tree");
    while na != nb {
        if dt.nodes[na].level < dt.nodes[nb].level { t := na; na = nb; nb = t; }
        na = dt.nodes[na].idom;
    }
    return dt.nodes[na].block;
}

// updateDFSNumbers
dt_update_dfs_numbers :: (dt: *Dom_Tree) {
    if dt.dfs_valid { dt.slow_queries = 0; return; }
    root := dt.root_node;
    if root < 0 return;
    Frame :: struct { n: s32; child: s32; }
    stack: [..] Frame; stack.allocator = temp;
    array_add(*stack, .{root, dt.nodes[root].first_child});
    num: u32 = 0;
    dt.nodes[root].dfs_in = num; num += 1;
    while stack.count {
        top := *stack[stack.count - 1];
        if top.child < 0 {
            dt.nodes[top.n].dfs_out = num;
            stack.count -= 1;
        } else {
            c := top.child;
            top.child = dt.nodes[c].sibling;
            array_add(*stack, .{c, dt.nodes[c].first_child});
            dt.nodes[c].dfs_in = num; num += 1;
        }
    }
    dt.slow_queries = 0;
    dt.dfs_valid = true;
}

// dominates(const DomTreeNodeBase *A, const DomTreeNodeBase *B)
dt_dominates_nodes :: (dt: *Dom_Tree, a: s32, b: s32) -> bool {
    if b == a return true;
    if b < 0 return true;
    if a < 0 return false;
    if dt.nodes[b].idom == a return true;
    if dt.nodes[a].idom == b return false;
    if dt.nodes[a].level >= dt.nodes[b].level return false;
    if dt.dfs_valid return dt.nodes[b].dfs_in >= dt.nodes[a].dfs_in && dt.nodes[b].dfs_out <= dt.nodes[a].dfs_out;
    dt.slow_queries += 1;
    if dt.slow_queries > 32 {
        dt_update_dfs_numbers(dt);
        return dt.nodes[b].dfs_in >= dt.nodes[a].dfs_in && dt.nodes[b].dfs_out <= dt.nodes[a].dfs_out;
    }
    // dominatedBySlowTreeWalk
    alevel := dt.nodes[a].level;
    while true {
        i := dt.nodes[b].idom;
        if i < 0 || dt.nodes[i].level < alevel break;
        b = i;
    }
    return b == a;
}
dt_dominates :: (dt: *Dom_Tree, a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    return dt_dominates_nodes(dt, dt_node(dt, a), dt_node(dt, b));
}
dt_properly_dominates :: (dt: *Dom_Tree, a: Value_Id, b: Value_Id) -> bool {
    if a == b return false;
    return dt_dominates_nodes(dt, dt_node(dt, a), dt_node(dt, b));
}
dt_is_reachable_from_entry :: (dt: *Dom_Tree, b: Value_Id) -> bool { return dt_node(dt, b) >= 0; }

// ---------------------------------------------------------------- GraphDiff / LegalizeUpdates

Dom_Update :: struct { insert: bool; from: Value_Id; to: Value_Id; }

Graph_Diff :: struct {
    // per node: DI[0] (deleted) and DI[1] (inserted) children
    succ: Table(Value_Id, s32);   // -> index into lists
    pred: Table(Value_Id, s32);
    lists: [..] [2][..] Value_Id;
    reverse_applied: bool;
    legalized: [..] Dom_Update;
}

// cfg::LegalizeUpdates
legalize_updates :: (all: [] Dom_Update, result: *[..] Dom_Update, inverse_graph: bool) {
    Pair :: struct { a: Value_Id; b: Value_Id; }
    pk :: (p: Pair) -> u64 { return ((cast(u64) p.a) << 32) | (cast(u64) p.b); }
    ops: Table(u64, s64); ops.allocator = temp;
    order: [..] Pair; order.allocator = temp;     // DenseMap iteration order doesn't matter: we sort below
    for all {
        from, to := it.from, it.to;
        if inverse_graph { t := from; from = to; to = t; }
        p := Pair.{from, to};
        found, v := table_find(*ops, pk(p));
        if !found { array_add(*order, p); v = 0; }
        table_set(*ops, pk(p), v + ifx it.insert then 1 else -1);
    }
    result.count = 0;
    for p: order {
        _, n := table_find(*ops, pk(p));
        // LLVM asserts n in [-1, 1]; release builds (the oracle) accept unbalanced updates (lazy DomTreeUpdater queues)
        if n == 0 continue;
        array_add(result, .{n > 0, p.a, p.b});
    }
    for all {
        p := ifx !inverse_graph then Pair.{it.from, it.to} else Pair.{it.to, it.from};
        table_set(*ops, pk(p), it_index);
    }
    // sort descending by the index of the last update of the edge (keys are unique)
    key :: (ops: *Table(u64, s64), u: Dom_Update) -> s64 { _, v := table_find(ops, ((cast(u64) u.from) << 32) | (cast(u64) u.to)); return v; }
    for i: 1..result.count-1 {
        x := result.*[i];
        kx := key(*ops, x);
        j := i - 1;
        while j >= 0 && key(*ops, result.*[j]) < kx { result.*[j + 1] = result.*[j]; j -= 1; }
        result.*[j + 1] = x;
    }
}

gd_list :: (gd: *Graph_Diff, map: *Table(Value_Id, s32), n: Value_Id) -> s32 {
    found, i := table_find(map, n);
    if found return i;
    i = cast(s32) gd.lists.count;
    e: [2][..] Value_Id;
    e[0].allocator = temp; e[1].allocator = temp;
    array_add(*gd.lists, e);
    table_set(map, n, i);
    return i;
}

gd_init :: (gd: *Graph_Diff, updates: [] Dom_Update, inverse_graph: bool, reverse_apply: bool) {
    gd.succ.allocator = temp; gd.pred.allocator = temp; gd.lists.allocator = temp; gd.legalized.allocator = temp;
    legalize_updates(updates, *gd.legalized, inverse_graph);
    for gd.legalized {
        is_insert := ifx it.insert == !reverse_apply then 1 else 0;
        si := gd_list(gd, *gd.succ, it.from);
        array_add(*gd.lists[si][is_insert], it.to);
        pi := gd_list(gd, *gd.pred, it.to);
        array_add(*gd.lists[pi][is_insert], it.from);
    }
    gd.reverse_applied = reverse_apply;
}

gd_pop_update :: (gd: *Graph_Diff) -> Dom_Update {
    u := pop(*gd.legalized);
    is_insert := ifx u.insert == !gd.reverse_applied then 1 else 0;
    _, si := table_find(*gd.succ, u.from);
    sl := *gd.lists[si][is_insert];
    assert(sl.*[sl.count - 1] == u.to);
    sl.count -= 1;
    _, pi := table_find(*gd.pred, u.to);
    pl := *gd.lists[pi][is_insert];
    assert(pl.*[pl.count - 1] == u.from);
    pl.count -= 1;
    return u;
}

// ---------------------------------------------------------------- children (SemiNCAInfo::getChildren)

// Batch_Update_Info: BatchUpdateInfo (PreViewCFG, and PostViewCFG for applyUpdates(Updates, PostViewUpdates))
Batch_Update_Info :: struct {
    pre_view: *Graph_Diff;
    post_view: *Graph_Diff;
    is_recalculated: bool;
    num_legalized: s64;
}

// getChildren<Inversed>(N, BUI): Inversed = false: successors in reverse order; true: predecessors in order;
// then the GraphDiff view's deleted children are removed and inserted ones appended.
dt_children :: (dt: *Dom_Tree, n: Value_Id, inversed: bool, bui: *Batch_Update_Info, out: *[..] Value_Id) {
    out.count = 0;
    if !inversed {
        t := block_terminator(n);
        if t != NONE {
            k := num_successors(t);
            while k > 0 { k -= 1; array_add(out, get_successor(t, k)); }
        }
    } else {
        block_predecessors(n, out);
    }
    if bui == null return;
    gd := bui.pre_view;
    map := ifx inversed != dt.post then *gd.pred else *gd.succ;
    found, li := table_find(map, n);
    if !found return;
    for c: gd.lists[li][0] {
        k := 0;
        for out.* if it != c { out.*[k] = it; k += 1; }
        out.count = k;
    }
    for gd.lists[li][1] array_add(out, it);
}

// GraphDiff<BasicBlock *>::getChildren<InverseEdge>(N) of a non-inverted GraphDiff: successors in reverse order
// (InverseEdge = false) or predecessors in order (true), minus the deleted children, plus the inserted ones
gd_children :: (gd: *Graph_Diff, n: Value_Id, inverse_edge: bool, out: *[..] Value_Id) {
    out.count = 0;
    if !inverse_edge {
        t := block_terminator(n);
        if t != NONE {
            k := num_successors(t);
            while k > 0 { k -= 1; array_add(out, get_successor(t, k)); }
        }
    } else block_predecessors(n, out);
    map := ifx inverse_edge then *gd.pred else *gd.succ;
    found, li := table_find(map, n);
    if !found return;
    for c: gd.lists[li][0] {
        k := 0;
        for out.* if it != c { out.*[k] = it; k += 1; }
        out.count = k;
    }
    for gd.lists[li][1] array_add(out, it);
}

// ---------------------------------------------------------------- SemiNCAInfo

Info_Rec :: struct {
    dfs_num_plus1: u32;
    parent: u32;
    semi: u32;
    label: u32;
    idom: Value_Id = NONE;
    rev_children_start: u32;
}

Snca :: struct {
    dt: *Dom_Tree;
    bui: *Batch_Update_Info;
    num_to_node: [..] Value_Id;
    infos: [..] Info_Rec;
    info_of: Table(Value_Id, s32);
    reverse_children: [..] struct { parent: u32; next: u32; };
}

snca_make :: (dt: *Dom_Tree, bui: *Batch_Update_Info) -> Snca {
    s: Snca;
    s.dt = dt; s.bui = bui;
    s.num_to_node.allocator = temp; s.infos.allocator = temp; s.info_of.allocator = temp;
    s.reverse_children.allocator = temp;
    return s;
}
snca_clear :: (s: *Snca) {
    s.num_to_node.count = 0;
    s.infos.count = 0;
    table_reset(*s.info_of);
    s.reverse_children.count = 0;
}
snca_info :: (s: *Snca, b: Value_Id) -> s32 {
    found, i := table_find(*s.info_of, b);
    if found return i;
    i = cast(s32) s.infos.count;
    r: Info_Rec;
    array_add(*s.infos, r);
    table_set(*s.info_of, b, i);
    return i;
}
snca_get_idom :: (s: *Snca, b: Value_Id) -> Value_Id { return s.infos[snca_info(s, b)].idom; }

// The DescendCondition lambdas of GenericDomTreeConstruction.h
Descend_Kind :: enum u8 { ALWAYS; UNREACHABLE; BELOW_LEVEL; COLLECT; BELOW_CREATE; }
Edge_To_Node :: struct { from: Value_Id; to: s32; }
Descend :: struct {
    kind: Descend_Kind;
    level: u32;
    edges: *[..] Edge_To_Node;   // UNREACHABLE: DiscoveredConnectingEdges
    affected: *[..] Value_Id;    // COLLECT: AffectedQueue
}

descend :: (s: *Snca, d: *Descend, from: Value_Id, to: Value_Id) -> bool {
    dt := s.dt;
    if d.kind == {
        case .ALWAYS; return true;
        case .UNREACHABLE;
            tn := dt_node(dt, to);
            if tn < 0 return true;
            array_add(d.edges, .{from, tn});
            return false;
        case .BELOW_LEVEL;
            return dt.nodes[dt_node(dt, to)].level > d.level;
        case .COLLECT;
            tn := dt_node(dt, to);
            assert(tn >= 0);
            if dt.nodes[tn].level > d.level return true;
            for d.affected.* if it == to return false;
            array_add(d.affected, to);
            return false;
        case .BELOW_CREATE;
            tn := dt_node(dt, to);
            if tn >= 0 return dt.nodes[tn].level > d.level;
            dt_create_node(dt, to, dt_node(dt, from));
            return true;
    }
    return true;
}

// runDFS<IsReverse>(V, LastNum, Condition, AttachToNum, SuccOrder)
snca_run_dfs :: (s: *Snca, v: Value_Id, last_num_in: u32, d: *Descend, attach_to: u32, reverse := false,
                 succ_order: *Table(Value_Id, u32) = null) -> u32 {
    last_num := last_num_in;
    Item :: struct { b: Value_Id; parent: u32; }
    wl: [..] Item; wl.allocator = temp;
    array_add(*wl, .{v, attach_to});
    s.infos[snca_info(s, v)].parent = attach_to;
    children: [..] Value_Id; children.allocator = temp;
    while wl.count {
        top := pop(*wl);
        bi := snca_info(s, top.b);
        array_add(*s.reverse_children, .{top.parent, s.infos[bi].rev_children_start});
        s.infos[bi].rev_children_start = cast(u32) s.reverse_children.count;
        if s.infos[bi].dfs_num_plus1 != 0 continue;
        s.infos[bi].parent = top.parent;
        num := last_num; last_num += 1;
        s.infos[bi].semi = num; s.infos[bi].label = num;
        s.infos[bi].dfs_num_plus1 = num + 1;
        array_add(*s.num_to_node, top.b);
        direction := reverse != s.dt.post;
        dt_children(s.dt, top.b, direction, s.bui, *children);
        if succ_order && children.count > 1 {
            // llvm::sort by SuccOrder (stable insertion sort; equal keys are equal nodes)
            for i: 1..children.count-1 {
                x := children[i];
                _, kx := table_find(succ_order, x);
                j := i - 1;
                while j >= 0 {
                    _, kj := table_find(succ_order, children[j]);
                    if kj <= kx break;
                    children[j + 1] = children[j]; j -= 1;
                }
                children[j + 1] = x;
            }
        }
        for c: children {
            if !descend(s, d, top.b, c) continue;
            array_add(*wl, .{c, num});
        }
    }
    return last_num;
}

snca_eval :: (s: *Snca, v: u32, last_linked: u32, num_to_info: [] s32, stack: *[..] s32) -> u32 {
    vi := num_to_info[v];
    if s.infos[vi].parent < last_linked return s.infos[vi].label;
    assert(stack.count == 0);
    while true {
        array_add(stack, vi);
        vi = num_to_info[s.infos[vi].parent];
        if s.infos[vi].parent < last_linked break;
    }
    pi := vi;
    plabel := s.infos[pi].label;
    while true {
        vi = pop(stack);
        s.infos[vi].parent = s.infos[pi].parent;
        vlabel := s.infos[vi].label;
        if plabel < vlabel s.infos[vi].label = plabel;
        else plabel = vlabel;
        pi = vi;
        if stack.count == 0 break;
    }
    return s.infos[vi].label;
}

snca_run :: (s: *Snca) {
    n := cast(u32) s.num_to_node.count;
    num_to_info := NewArray(n, s32,, allocator = temp);
    idoms := NewArray(n, u32,, allocator = temp);
    for i: 0..cast(s64)n-1 {
        ii := snca_info(s, s.num_to_node[i]);
        idoms[i] = s.infos[ii].parent;
        num_to_info[i] = ii;
    }
    stack: [..] s32; stack.allocator = temp;
    i := n;
    while i > 1 {
        i -= 1;
        wi := num_to_info[i];
        s.infos[wi].semi = s.infos[wi].parent;
        rc := s.infos[wi].rev_children_start;
        while rc != 0 {
            e := s.reverse_children[rc - 1];
            rc = e.next;
            semi_u := snca_eval(s, e.parent, i + 1, num_to_info, *stack);
            if semi_u < s.infos[wi].semi s.infos[wi].semi = semi_u;
        }
        s.infos[wi].label = s.infos[wi].semi;
    }
    for k: 1..cast(s64)n-1 {
        wi := num_to_info[k];
        widom := idoms[k];
        while widom > s.infos[wi].semi widom = idoms[widom];
        idoms[k] = widom;
        s.infos[wi].idom = s.num_to_node[widom];
    }
}

snca_add_virtual_root :: (s: *Snca) {
    bi := snca_info(s, NONE);
    s.infos[bi].semi = 0; s.infos[bi].label = 0;
    s.infos[bi].dfs_num_plus1 = 1;
    array_add(*s.num_to_node, NONE);
}

has_forward_successors :: (dt: *Dom_Tree, n: Value_Id, bui: *Batch_Update_Info) -> bool {
    c: [..] Value_Id; c.allocator = temp;
    dt_children(dt, n, false, bui, *c);
    return c.count > 0;
}

// FindRoots(DT, BUI)
find_roots :: (dt: *Dom_Tree, bui: *Batch_Update_Info, roots: *[..] Value_Id) {
    roots.count = 0;
    if !dt.post { array_add(roots, dt_entry(dt)); return; }
    s := snca_make(dt, bui);
    snca_add_virtual_root(*s);
    num: u32 = 1;
    always: Descend;
    total: u32 = 0;
    for fn_blocks(dt.fn) {
        total += 1;
        if !has_forward_successors(dt, it, bui) {
            array_add(roots, it);
            num = snca_run_dfs(*s, it, num, *always, 0);
        }
    }
    has_non_trivial := false;
    if total + 1 != num {
        has_non_trivial = true;
        succ_order: Table(Value_Id, u32); succ_order.allocator = temp;
        have_order := false;
        c: [..] Value_Id; c.allocator = temp;
        for i: fn_blocks(dt.fn) {
            if s.infos[snca_info(*s, i)].dfs_num_plus1 != 0 continue;
            if !have_order {
                have_order = true;
                for node: fn_blocks(dt.fn) {
                    if s.infos[snca_info(*s, node)].dfs_num_plus1 != 0 continue;
                    dt_children(dt, node, false, s.bui, *c);
                    for c if !table_contains(*succ_order, it) table_set(*succ_order, it, 0);
                }
                node_num: u32 = 0;
                for node: fn_blocks(dt.fn) {
                    node_num += 1;
                    if table_contains(*succ_order, node) table_set(*succ_order, node, node_num);
                }
            }
            new_num := snca_run_dfs(*s, i, num, *always, num, true, *succ_order);
            furthest := s.num_to_node[new_num - 1];
            array_add(roots, furthest);
            k := new_num;
            while k > num {
                k -= 1;
                nd := s.num_to_node[k];
                s.infos[snca_info(*s, nd)] = .{};
                s.num_to_node.count -= 1;
            }
            num = snca_run_dfs(*s, furthest, num, *always, 0);
        }
    }
    assert(total + 1 == num, "Everything should have been visited");
    if has_non_trivial remove_redundant_roots(dt, bui, roots);
}

// RemoveRedundantRoots
remove_redundant_roots :: (dt: *Dom_Tree, bui: *Batch_Update_Info, roots: *[..] Value_Id) {
    s := snca_make(dt, bui);
    always: Descend;
    i := 0;
    while i < roots.count {
        root := roots.*[i];
        if !has_forward_successors(dt, root, bui) { i += 1; continue; }
        snca_clear(*s);
        num := snca_run_dfs(*s, root, 0, *always, 0, true);
        removed := false;
        for x: 1..cast(s64)num-1 {
            n := s.num_to_node[x];
            contained := false;
            for roots.* if it == n { contained = true; break; }
            if contained {
                roots.*[i] = roots.*[roots.count - 1];
                roots.count -= 1;
                removed = true;
                break;
            }
        }
        if !removed i += 1;
    }
}

// doFullDFSWalk
snca_full_dfs :: (s: *Snca, dt: *Dom_Tree, d: *Descend) {
    if !dt.post {
        assert(dt.roots.count == 1);
        snca_run_dfs(s, dt.roots[0], 0, d, 0);
        return;
    }
    snca_add_virtual_root(s);
    num: u32 = 1;
    for dt.roots num = snca_run_dfs(s, it, num, d, 0);
}

// getNodeForBlock (iterative)
snca_node_for_block :: (s: *Snca, b: Value_Id) -> s32 {
    dt := s.dt;
    n := dt_node(dt, b);
    if n >= 0 return n;
    chain: [..] Value_Id; chain.allocator = temp;
    cur := b;
    while dt_node(dt, cur) < 0 {
        array_add(*chain, cur);
        cur = snca_get_idom(s, cur);
    }
    parent := dt_node(dt, cur);
    k := chain.count;
    while k > 0 { k -= 1; parent = dt_create_node(dt, chain[k], parent); }
    return parent;
}

// attachNewSubtree
snca_attach_new_subtree :: (s: *Snca, attach_to: s32) {
    dt := s.dt;
    s.infos[snca_info(s, s.num_to_node[0])].idom = dt.nodes[attach_to].block;
    for w: s.num_to_node {
        if dt_node(dt, w) >= 0 continue;
        imm := snca_get_idom(s, w);
        idn := snca_node_for_block(s, imm);
        dt_create_node(dt, w, idn);
    }
}
// reattachExistingSubtree
snca_reattach_existing_subtree :: (s: *Snca, attach_to: s32) {
    dt := s.dt;
    s.infos[snca_info(s, s.num_to_node[0])].idom = dt.nodes[attach_to].block;
    for n: s.num_to_node {
        tn := dt_node(dt, n);
        assert(tn >= 0);
        ni := dt_node(dt, s.infos[snca_info(s, n)].idom);
        dt_set_idom(dt, tn, ni);
    }
}

// CalculateFromScratch
calculate_from_scratch :: (dt: *Dom_Tree, bui: *Batch_Update_Info) {
    f := dt.fn;
    dt_reset(dt);
    dt.fn = f;
    // with a PostViewCFG, PreViewCFG = *PostViewCFG and the post view is used; otherwise the current CFG
    post_bui: *Batch_Update_Info = null;
    if bui && bui.post_view { bui.pre_view = bui.post_view; post_bui = bui; }
    s := snca_make(dt, post_bui);
    find_roots(dt, post_bui, *dt.roots);
    always: Descend;
    snca_full_dfs(*s, dt, *always);
    snca_run(*s);
    if bui bui.is_recalculated = true;
    if dt.roots.count == 0 return;
    root := ifx dt.post then NONE else dt.roots[0];
    dt.root_node = dt_create_node(dt, root);
    snca_attach_new_subtree(*s, dt.root_node);
}

// DominatorTreeBase::recalculate
dt_recalculate :: (dt: *Dom_Tree, f: Value_Id) {
    dt.fn = f;
    dt.node_of.allocator = context.allocator;
    calculate_from_scratch(dt, null);
}

// ---------------------------------------------------------------- incremental updates

is_permutation :: (a: [] Value_Id, b: [] Value_Id) -> bool {
    if a.count != b.count return false;
    for x: b {
        found := false;
        for a if it == x { found = true; break; }
        if !found return false;
    }
    return true;
}

update_roots_before_insertion :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: s32, to: s32) -> bool {
    if !dt_is_virtual_root(dt, dt.nodes[to].idom) return false;
    contained := false;
    for dt.roots if it == dt.nodes[to].block { contained = true; break; }
    if !contained return false;
    calculate_from_scratch(dt, bui);
    return true;
}

update_roots_after_update :: (dt: *Dom_Tree, bui: *Batch_Update_Info) {
    any := false;
    for dt.roots if has_forward_successors(dt, it, bui) { any = true; break; }
    if !any return;
    roots: [..] Value_Id; roots.allocator = temp;
    find_roots(dt, bui, *roots);
    if !is_permutation(dt.roots, roots) calculate_from_scratch(dt, bui);
}

insert_edge :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: Value_Id, to: Value_Id) {
    from_tn := dt_node(dt, from);
    if from_tn < 0 {
        if !dt.post return;
        vr := dt_node(dt, NONE);
        from_tn = dt_create_node(dt, from, vr);
        array_add(*dt.roots, from);
    }
    dt.dfs_valid = false;
    to_tn := dt_node(dt, to);
    if to_tn < 0 insert_unreachable(dt, bui, from_tn, to);
    else insert_reachable(dt, bui, from_tn, to_tn);
}

insert_reachable :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: s32, to: s32) {
    if dt.post && update_roots_before_insertion(dt, bui, from, to) return;
    fb := dt.nodes[from].block; tb := dt.nodes[to].block;
    ncd_block := ifx fb != NONE && tb != NONE then dt_find_nca(dt, fb, tb) else NONE;
    ncd := dt_node(dt, ncd_block);
    assert(ncd >= 0);
    ncd_level := dt.nodes[ncd].level;
    if ncd_level + 1 >= dt.nodes[to].level return;

    // InsertionInfo: Bucket is a max-heap on level (std::priority_queue with Compare = level <)
    bucket: [..] s32; bucket.allocator = temp;
    visited: Table(s32, bool); visited.allocator = temp;
    affected: [..] s32; affected.allocator = temp;
    unaffected: [..] s32; unaffected.allocator = temp;
    heap_push(dt, *bucket, to);
    table_set(*visited, to, true);
    children: [..] Value_Id; children.allocator = temp;
    while bucket.count {
        tn := heap_pop(dt, *bucket);
        array_add(*affected, tn);
        current_level := dt.nodes[tn].level;
        while true {
            dt_children(dt, dt.nodes[tn].block, dt.post, bui, *children);
            for succ: children {
                stn := dt_node(dt, succ);
                assert(stn >= 0, "Unreachable successor found at reachable insertion");
                sl := dt.nodes[stn].level;
                if sl <= ncd_level + 1 continue;
                if table_contains(*visited, stn) continue;
                table_set(*visited, stn, true);
                if sl > current_level array_add(*unaffected, stn);
                else heap_push(dt, *bucket, stn);
            }
            if unaffected.count == 0 break;
            tn = pop(*unaffected);
        }
    }
    // UpdateInsertion
    for affected dt_set_idom(dt, it, ncd);
    if dt.post update_roots_after_update(dt, bui);
}

// std::priority_queue<TreeNodePtr, SmallVector, Compare{LHS->getLevel() < RHS->getLevel()}>: libstdc++'s
// push_heap/pop_heap, reproduced so that equal-level nodes come out in the same order.
heap_less :: (dt: *Dom_Tree, a: s32, b: s32) -> bool { return dt.nodes[a].level < dt.nodes[b].level; }
heap_push :: (dt: *Dom_Tree, h: *[..] s32, v: s32) {
    array_add(h, v);
    // __push_heap(first, holeIndex = len-1, topIndex = 0, value)
    hole := h.count - 1;
    parent := (hole - 1) / 2;
    while hole > 0 && heap_less(dt, h.*[parent], v) {
        h.*[hole] = h.*[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h.*[hole] = v;
}
heap_pop :: (dt: *Dom_Tree, h: *[..] s32) -> s32 {
    top := h.*[0];
    len := h.count - 1;
    if len > 0 {
        value := h.*[len];
        // __adjust_heap(first, 0, len, value)
        hole := 0;
        second := 0;
        while second < (len - 1) / 2 {
            second = 2 * (second + 1);
            if heap_less(dt, h.*[second], h.*[second - 1]) second -= 1;
            h.*[hole] = h.*[second];
            hole = second;
        }
        if (len & 1) == 0 && second == (len - 2) / 2 {
            second = 2 * (second + 1);
            h.*[hole] = h.*[second - 1];
            hole = second - 1;
        }
        // __push_heap(first, hole, 0, value)
        parent := (hole - 1) / 2;
        while hole > 0 && heap_less(dt, h.*[parent], value) {
            h.*[hole] = h.*[parent];
            hole = parent;
            parent = (hole - 1) / 2;
        }
        h.*[hole] = value;
    }
    h.count = len;
    return top;
}

insert_unreachable :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: s32, to: Value_Id) {
    edges: [..] Edge_To_Node; edges.allocator = temp;
    // ComputeUnreachableDominators
    d: Descend; d.kind = .UNREACHABLE; d.edges = *edges;
    s := snca_make(dt, bui);
    snca_run_dfs(*s, to, 0, *d, 0);
    snca_run(*s);
    snca_attach_new_subtree(*s, from);
    for edges insert_reachable(dt, bui, dt_node(dt, it.from), it.to);
}

delete_edge :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: Value_Id, to: Value_Id) {
    from_tn := dt_node(dt, from);
    if from_tn < 0 return;
    to_tn := dt_node(dt, to);
    if to_tn < 0 return;
    ncd := dt_node(dt, dt_find_nca(dt, from, to));
    if to_tn != ncd {
        dt.dfs_valid = false;
        to_idom := dt.nodes[to_tn].idom;
        if from_tn != to_idom || has_proper_support(dt, bui, to_tn) delete_reachable(dt, bui, from_tn, to_tn);
        else delete_unreachable(dt, bui, to_tn);
    }
    if dt.post update_roots_after_update(dt, bui);
}

delete_reachable :: (dt: *Dom_Tree, bui: *Batch_Update_Info, from: s32, to: s32) {
    to_idom := dt_find_nca(dt, dt.nodes[from].block, dt.nodes[to].block);
    to_idom_tn := dt_node(dt, to_idom);
    assert(to_idom_tn >= 0);
    prev_idom_subtree := dt.nodes[to_idom_tn].idom;
    if prev_idom_subtree < 0 { calculate_from_scratch(dt, bui); return; }
    d: Descend; d.kind = .BELOW_LEVEL; d.level = dt.nodes[to_idom_tn].level;
    s := snca_make(dt, bui);
    snca_run_dfs(*s, to_idom, 0, *d, 0);
    snca_run(*s);
    snca_reattach_existing_subtree(*s, prev_idom_subtree);
}

has_proper_support :: (dt: *Dom_Tree, bui: *Batch_Update_Info, tn: s32) -> bool {
    tnb := dt.nodes[tn].block;
    preds: [..] Value_Id; preds.allocator = temp;
    dt_children(dt, tnb, !dt.post, bui, *preds);
    for pred: preds {
        if dt_node(dt, pred) < 0 continue;
        support := dt_find_nca(dt, tnb, pred);
        if support != tnb return true;
    }
    return false;
}

delete_unreachable :: (dt: *Dom_Tree, bui: *Batch_Update_Info, to_tn: s32) {
    if dt.post {
        array_add(*dt.roots, dt.nodes[to_tn].block);
        insert_reachable(dt, bui, dt_node(dt, NONE), to_tn);
        return;
    }
    affected: [..] Value_Id; affected.allocator = temp;
    level := dt.nodes[to_tn].level;
    d: Descend; d.kind = .COLLECT; d.level = level; d.affected = *affected;
    s := snca_make(dt, bui);
    last := snca_run_dfs(*s, dt.nodes[to_tn].block, 0, *d, 0);
    min_node := to_tn;
    for n: affected {
        tn := dt_node(dt, n);
        ncd := dt_node(dt, dt_find_nca(dt, dt.nodes[tn].block, dt.nodes[to_tn].block));
        assert(ncd >= 0);
        if ncd != tn && dt.nodes[ncd].level < dt.nodes[min_node].level min_node = ncd;
    }
    if dt.nodes[min_node].idom < 0 { calculate_from_scratch(dt, bui); return; }
    k := last;
    while k > 0 { k -= 1; dt_erase_node(dt, s.num_to_node[k]); }
    if min_node == to_tn return;
    min_level := dt.nodes[min_node].level;
    prev_idom := dt.nodes[min_node].idom;
    snca_clear(*s);
    d2: Descend; d2.kind = .BELOW_CREATE; d2.level = min_level;
    snca_run_dfs(*s, dt.nodes[min_node].block, 0, *d2, 0);
    snca_run(*s);
    snca_reattach_existing_subtree(*s, prev_idom);
}

// DominatorTreeBase::applyUpdates(Updates) -> DomTreeBuilder::ApplyUpdates(DT, PreViewCFG, nullptr)
dt_apply_updates :: (dt: *Dom_Tree, updates: [] Dom_Update) {
    gd: Graph_Diff;
    gd_init(*gd, updates, dt.post, true);
    n := gd.legalized.count;
    if n == 0 return;
    if n == 1 {
        u := gd_pop_update(*gd);
        if u.insert insert_edge(dt, null, u.from, u.to);
        else delete_edge(dt, null, u.from, u.to);
        return;
    }
    bui: Batch_Update_Info;
    bui.pre_view = *gd;
    bui.num_legalized = n;
    size := dt.vec_size;
    if size <= 100 {
        if bui.num_legalized > size calculate_from_scratch(dt, *bui);
    } else if bui.num_legalized > size / 40 calculate_from_scratch(dt, *bui);
    i := 0;
    while i < bui.num_legalized && !bui.is_recalculated {
        u := gd_pop_update(*gd);
        if u.insert insert_edge(dt, *bui, u.from, u.to);
        else delete_edge(dt, *bui, u.from, u.to);
        i += 1;
    }
}
// DominatorTreeBase::applyUpdates(Updates, PostViewUpdates) -> DomTreeBuilder::ApplyUpdates(DT, PreViewCFG, &PostViewCFG)
dt_apply_updates_post_view :: (dt: *Dom_Tree, updates: [] Dom_Update, post_view_updates: [] Dom_Update) {
    pre_storage: Graph_Diff;
    post: Graph_Diff;
    gd_init(*post, post_view_updates, dt.post, false);
    pre := *post;   // Updates empty: ApplyUpdates(*this, PostViewCFG, &PostViewCFG), one object
    if updates.count {
        all: [..] Dom_Update; all.allocator = temp;
        for updates array_add(*all, it);
        for post_view_updates array_add(*all, it);
        gd_init(*pre_storage, all, dt.post, true);
        pre = *pre_storage;
    }
    n := pre.legalized.count;
    if n == 0 return;
    if n == 1 {
        u := gd_pop_update(pre);
        bui1: Batch_Update_Info;
        bui1.pre_view = *post; bui1.post_view = *post;
        bui1.num_legalized = post.legalized.count;
        if u.insert insert_edge(dt, *bui1, u.from, u.to);
        else delete_edge(dt, *bui1, u.from, u.to);
        return;
    }
    bui: Batch_Update_Info;
    bui.pre_view = pre;
    bui.post_view = *post;
    bui.num_legalized = n;
    size := dt.vec_size;
    if size <= 100 {
        if bui.num_legalized > size calculate_from_scratch(dt, *bui);
    } else if bui.num_legalized > size / 40 calculate_from_scratch(dt, *bui);
    i := 0;
    while i < bui.num_legalized && !bui.is_recalculated {
        u := gd_pop_update(bui.pre_view);
        if u.insert insert_edge(dt, *bui, u.from, u.to);
        else delete_edge(dt, *bui, u.from, u.to);
        i += 1;
    }
}
dt_insert_edge :: (dt: *Dom_Tree, from: Value_Id, to: Value_Id) { insert_edge(dt, null, from, to); }
dt_delete_edge :: (dt: *Dom_Tree, from: Value_Id, to: Value_Id) { delete_edge(dt, null, from, to); }

// addNewBlock(BB, DomBB)
dt_add_new_block :: (dt: *Dom_Tree, b: Value_Id, dom: Value_Id) -> s32 {
    assert(dt_node(dt, b) < 0, "Block already in dominator tree!");
    idn := dt_node(dt, dom);
    assert(idn >= 0);
    dt.dfs_valid = false;
    return dt_create_node(dt, b, idn);
}
// changeImmediateDominator
dt_change_idom :: (dt: *Dom_Tree, b: Value_Id, new_idom: Value_Id) {
    dt.dfs_valid = false;
    dt_set_idom(dt, dt_node(dt, b), dt_node(dt, new_idom));
}

// ---------------------------------------------------------------- printing (DominatorTreeBase::print)

dt_print :: (dt: *Dom_Tree, sb: *String_Builder) {
    append(sb, "=============================--------------------------------\n");
    append(sb, ifx dt.post then "Inorder PostDominator Tree: " else "Inorder Dominator Tree: ");
    if !dt.dfs_valid print_to_builder(sb, "DFSNumbers invalid: % slow queries.", dt.slow_queries);
    append(sb, "\n");
    if dt.root_node >= 0 {
        Frame :: struct { n: s32; lev: u32; }
        stack: [..] Frame; stack.allocator = temp;
        array_add(*stack, .{dt.root_node, 1});
        kids: [..] s32; kids.allocator = temp;
        while stack.count {
            fr := pop(*stack);
            nd := dt.nodes[fr.n];
            for 1..2 * fr.lev append(sb, " ");
            print_to_builder(sb, "[%] ", fr.lev);
            if nd.block != NONE append(sb, value_as_operand(nd.block));
            else append(sb, " <<exit node>>");
            print_to_builder(sb, " {%,%} [%]\n", nd.dfs_in, nd.dfs_out, nd.level);
            kids.count = 0;
            c := nd.first_child;
            while c >= 0 { array_add(*kids, c); c = dt.nodes[c].sibling; }
            k := kids.count;
            while k > 0 { k -= 1; array_add(*stack, .{kids[k], fr.lev + 1}); }
        }
    }
    append(sb, "Roots: ");
    for dt.roots { append(sb, value_as_operand(it)); append(sb, " "); }
    append(sb, "\n");
}

// ---------------------------------------------------------------- IDFCalculator (GenericIteratedDominanceFrontier.h)

// calculate(IDFBlocks) for the forward (post = false: successors) or reverse (post = true: predecessors) graph,
// with optional live-in filtering. def_blocks / live_in are sets (membership only; order of def_blocks matters for
// the priority queue only through (level, DFSIn), which are unique).
// gd: the GraphDiff of IDFCalculator(DT, GD) (children = GD->getChildren<IsPostDom>(N): forward successors in
// reverse order, then the diff applied); null = the current CFG (children<OrderedNodeTy>: successors in order).
idf_calculate :: (dt: *Dom_Tree, def_blocks: [] Value_Id, def_set: *Table(Value_Id, bool),
                  live_in: *Table(Value_Id, bool), out: *[..] Value_Id, gd: *Graph_Diff = null) {
    Pq_Item :: struct { n: s32; level: u32; dfs_in: u32; }
    less :: (a: Pq_Item, b: Pq_Item) -> bool {   // less_second on (level, DFSIn)
        if a.level != b.level return a.level < b.level;
        return a.dfs_in < b.dfs_in;
    }
    pq: [..] Pq_Item; pq.allocator = temp;
    push :: (pq: *[..] Pq_Item, v: Pq_Item) {
        array_add(pq, v);
        hole := pq.count - 1; parent := (hole - 1) / 2;
        while hole > 0 && less(pq.*[parent], v) { pq.*[hole] = pq.*[parent]; hole = parent; parent = (hole - 1) / 2; }
        pq.*[hole] = v;
    }
    pop_top :: (pq: *[..] Pq_Item) -> Pq_Item {
        top := pq.*[0];
        len := pq.count - 1;
        if len > 0 {
            value := pq.*[len];
            hole := 0; second := 0;
            while second < (len - 1) / 2 {
                second = 2 * (second + 1);
                if less(pq.*[second], pq.*[second - 1]) second -= 1;
                pq.*[hole] = pq.*[second]; hole = second;
            }
            if (len & 1) == 0 && second == (len - 2) / 2 {
                second = 2 * (second + 1);
                pq.*[hole] = pq.*[second - 1]; hole = second - 1;
            }
            parent := (hole - 1) / 2;
            while hole > 0 && less(pq.*[parent], value) { pq.*[hole] = pq.*[parent]; hole = parent; parent = (hole - 1) / 2; }
            pq.*[hole] = value;
        }
        pq.count = len;
        return top;
    }
    dt_update_dfs_numbers(dt);
    worklist: [..] s32; worklist.allocator = temp;
    visited_pq: Table(s32, bool); visited_pq.allocator = temp;
    visited_wl: Table(s32, bool); visited_wl.allocator = temp;
    for b: def_blocks {
        n := dt_node(dt, b);
        if n < 0 continue;
        push(*pq, .{n, dt.nodes[n].level, dt.nodes[n].dfs_in});
        table_set(*visited_wl, n, true);
    }
    succs: [..] Value_Id; succs.allocator = temp;
    while pq.count {
        root := pop_top(*pq);
        root_level := root.level;
        array_add(*worklist, root.n);
        while worklist.count {
            node := pop(*worklist);
            bb := dt.nodes[node].block;
            // ChildrenGetter: children<OrderedNodeTy>: successors (forward) or predecessors (post)
            if gd gd_children(gd, bb, dt.post, *succs);
            else if dt.post block_predecessors(bb, *succs);
            else {
                succs.count = 0;
                t := block_terminator(bb);
                if t != NONE { k := num_successors(t); if k > 0 for i: 0..k-1 array_add(*succs, get_successor(t, i)); }
            }
            for succ: succs {
                sn := dt_node(dt, succ);
                sl := dt.nodes[sn].level;
                if sl > root_level continue;
                if table_contains(*visited_pq, sn) continue;
                table_set(*visited_pq, sn, true);
                sbb := dt.nodes[sn].block;
                if live_in && !table_contains(live_in, sbb) continue;
                array_add(out, sbb);
                if !table_contains(def_set, sbb) push(*pq, .{sn, sl, dt.nodes[sn].dfs_in});
            }
            c := dt.nodes[node].first_child;
            while c >= 0 {
                if !table_contains(*visited_wl, c) { table_set(*visited_wl, c, true); array_add(*worklist, c); }
                c = dt.nodes[c].sibling;
            }
        }
    }
}

// splitBlock(NewBB) = Split<NodeT *>(NewBB) (forward trees; NewBB has a single successor)
dt_split_block :: (dt: *Dom_Tree, nb: Value_Id) {
    if dt.post fatal("PostDominatorTree::splitBlock is not implemented yet");
    t := block_terminator(nb);
    assert(t != NONE && num_successors(t) == 1, "NewBB should have a single successor!");
    succ := get_successor(t, 0);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(nb, *preds);
    sp: [..] Value_Id; sp.allocator = temp;
    block_predecessors(succ, *sp);
    dominates_succ := true;
    for sp {
        if it != nb && !dt_dominates(dt, succ, it) && dt_is_reachable_from_entry(dt, it) { dominates_succ = false; break; }
    }
    idom: Value_Id = NONE;
    i := 0;
    while i < preds.count {
        if dt_is_reachable_from_entry(dt, preds[i]) { idom = preds[i]; break; }
        i += 1;
    }
    if idom == NONE return;
    i += 1;
    while i < preds.count {
        if dt_is_reachable_from_entry(dt, preds[i]) idom = dt_find_nca(dt, idom, preds[i]);
        i += 1;
    }
    nn := dt_add_new_block(dt, nb, idom);
    if dominates_succ {
        dt.dfs_valid = false;
        dt_set_idom(dt, dt_node(dt, succ), nn);
    }
}
