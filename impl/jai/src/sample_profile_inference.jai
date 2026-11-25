// Profile inference ("profi"): ported from llvm/lib/Transforms/Utils/SampleProfileInference.cpp (MinCostMaxFlow,
// FlowAdjuster, initializeNetwork, assignBlockCosts, assignJumpCosts, extractWeights, applyFlowInference) and
// llvm/include/llvm/Transforms/Utils/SampleProfileInference.h (SampleProfileInference<Function>::apply,
// createFlowFunction), with findUnlikelyJumps from llvm/lib/Transforms/IPO/SampleProfile.cpp.

PROFI_INF : s64 : 1 << 50;
PROFI_COST_UNLIKELY : s64 : 1 << 30;
PROFI_MAX_DFS_CALLS :: 10;

Profi_Params :: struct {
    even_flow_distribution: bool;
    rebalance_unknown: bool;
    join_islands: bool;
    cost_block_inc: s64;
    cost_block_dec: s64;
    cost_block_zero_inc: s64;
    cost_block_entry_inc: s64;
    cost_block_entry_dec: s64;
    cost_block_unknown_inc: s64;
    // the jump costs are never set from the command line (0)
    cost_jump_inc: s64;
    cost_jump_ft_inc: s64;
    cost_jump_dec: s64;
    cost_jump_ft_dec: s64;
    cost_jump_unknown_inc: s64;
    cost_jump_unknown_ft_inc: s64;
}

Flow_Block :: struct {
    index: u64;
    weight: u64;
    has_unknown_weight := true;
    is_unlikely: bool;
    flow: u64;
    succ_jumps: [..] s64;   // indices into Flow_Function.jumps
    pred_jumps: [..] s64;
}
Flow_Jump :: struct {
    source: u64;
    target: u64;
    weight: u64;
    has_unknown_weight := true;
    is_unlikely: bool;
    flow: u64;
}
Flow_Function :: struct {
    blocks: [..] Flow_Block;
    jumps: [..] Flow_Jump;
    entry: u64;
}
fb_is_entry :: (b: *Flow_Block) -> bool { return b.pred_jumps.count == 0; }
fb_is_exit :: (b: *Flow_Block) -> bool { return b.succ_jumps.count == 0; }

// ---------------------------------------------------------------- MinCostMaxFlow

Mcmf_Node :: struct {
    distance: s64;
    parent_node: u64;
    parent_edge_index: u64;
    taken: bool;
    frac_flow: float64;
    int_flow: u64;
    discovery: u64;
    finish: u64;
    num_calls: u64;
}
Mcmf_Edge :: struct {
    cost: s64;
    capacity: s64;
    flow: s64;
    dst: u64;
    rev_edge_index: u64;
    on_shortest_path: bool;
    augmented_flow: u64;
}
Mcmf_Ref :: struct { src: u64; k: u64; }   // an Edge * of AugmentingEdges
Mcmf :: struct {
    params: *Profi_Params;
    nodes: [..] Mcmf_Node;
    edges: [..] [..] Mcmf_Edge;
    source: u64;
    target: u64;
    augmenting: [..] [..] Mcmf_Ref;
}

mcmf_init :: (n: *Mcmf, count: u64, source: u64, sink: u64) {
    n.source = source; n.target = sink;
    n.nodes.allocator = temp; n.edges.allocator = temp; n.augmenting.allocator = temp;
    array_resize(*n.nodes, cast(s64) count);
    array_resize(*n.edges, cast(s64) count);
    for * n.edges it.allocator = temp;
    if n.params.even_flow_distribution {
        array_resize(*n.augmenting, cast(s64) count);
        for * n.augmenting it.allocator = temp;
    }
}
mcmf_add_edge :: (n: *Mcmf, src: u64, dst: u64, capacity: s64, cost: s64) {
    se: Mcmf_Edge; se.dst = dst; se.cost = cost; se.capacity = capacity; se.flow = 0; se.rev_edge_index = cast(u64) n.edges[dst].count;
    de: Mcmf_Edge; de.dst = src; de.cost = -cost; de.capacity = 0; de.flow = 0; de.rev_edge_index = cast(u64) n.edges[src].count;
    array_add(*n.edges[src], se);
    array_add(*n.edges[dst], de);
}
mcmf_add_edge_inf :: (n: *Mcmf, src: u64, dst: u64, cost: s64) { mcmf_add_edge(n, src, dst, PROFI_INF, cost); }
mcmf_get_flow :: (n: *Mcmf, src: u64, dst: u64) -> s64 {
    f: s64 = 0;
    for n.edges[src] if it.dst == dst f += it.flow;
    return f;
}
mcmf_run :: (n: *Mcmf) {
    while mcmf_find_augmenting_path(n) {
        path_cap := mcmf_path_capacity(n);
        while path_cap > 0 {
            progress := false;
            if n.params.even_flow_distribution {
                mcmf_identify_shortest_edges(n, path_cap);
                order := mcmf_find_augmenting_dag(n);
                progress = mcmf_augment_flow_along_dag(n, order);
                path_cap = mcmf_path_capacity(n);
            }
            if !progress {
                mcmf_augment_flow_along_path(n, path_cap);
                path_cap = 0;
            }
        }
    }
}
mcmf_path_capacity :: (n: *Mcmf) -> u64 {
    cap: u64 = cast(u64) PROFI_INF;
    now := n.target;
    while now != n.source {
        pred := n.nodes[now].parent_node;
        e := *n.edges[pred][n.nodes[now].parent_edge_index];
        ec := cast(u64) (e.capacity - e.flow);
        if ec < cap cap = ec;
        now = pred;
    }
    return cap;
}
mcmf_find_augmenting_path :: (n: *Mcmf) -> bool {
    for * n.nodes { it.distance = PROFI_INF; it.parent_node = 0xFFFF_FFFF_FFFF_FFFF; it.parent_edge_index = 0xFFFF_FFFF_FFFF_FFFF; it.taken = false; }
    queue: [..] u64; queue.allocator = temp;
    qh := 0;
    array_add(*queue, n.source);
    n.nodes[n.source].distance = 0;
    n.nodes[n.source].taken = true;
    while qh < queue.count {
        src := queue[qh]; qh += 1;
        n.nodes[src].taken = false;
        if !n.params.even_flow_distribution && n.nodes[n.target].distance == 0 break;
        if n.nodes[src].distance > n.nodes[n.target].distance continue;
        for idx: 0..n.edges[src].count - 1 {
            e := *n.edges[src][idx];
            if e.flow < e.capacity {
                dst := e.dst;
                nd := n.nodes[src].distance + e.cost;
                if n.nodes[dst].distance > nd {
                    n.nodes[dst].distance = nd;
                    n.nodes[dst].parent_node = src;
                    n.nodes[dst].parent_edge_index = cast(u64) idx;
                    if !n.nodes[dst].taken { array_add(*queue, dst); n.nodes[dst].taken = true; }
                }
            }
        }
    }
    return n.nodes[n.target].distance != PROFI_INF;
}
mcmf_augment_flow_along_path :: (n: *Mcmf, cap: u64) {
    now := n.target;
    while now != n.source {
        pred := n.nodes[now].parent_node;
        e := *n.edges[pred][n.nodes[now].parent_edge_index];
        r := *n.edges[now][e.rev_edge_index];
        e.flow += cast(s64) cap;
        r.flow -= cast(s64) cap;
        now = pred;
    }
}
mcmf_find_augmenting_dag :: (n: *Mcmf) -> [..] u64 {
    St :: struct { node: u64; edge: u64; }
    stack: [..] St; stack.allocator = temp;
    order: [..] u64; order.allocator = temp;
    for * n.nodes { it.discovery = 0; it.finish = 0; it.num_calls = 0; it.taken = false; }
    time: u64 = 0;
    n.nodes[n.target].taken = true;
    array_add(*stack, .{n.source, 0});
    time += 1; n.nodes[n.source].discovery = time;
    while stack.count {
        top := *stack[stack.count - 1];
        node := top.node; ei := top.edge;
        if ei < cast(u64) n.edges[node].count {
            e := *n.edges[node][ei];
            d := *n.nodes[e.dst];
            top.edge += 1;
            if e.on_shortest_path {
                if d.discovery == 0 && d.num_calls < PROFI_MAX_DFS_CALLS {
                    time += 1; d.discovery = time;
                    array_add(*stack, .{e.dst, 0});
                    d.num_calls += 1;
                } else if d.taken && d.finish != 0 {
                    n.nodes[node].taken = true;
                }
            }
        } else {
            stack.count -= 1;
            if !n.nodes[node].taken n.nodes[node].discovery = 0;
            else {
                time += 1; n.nodes[node].finish = time;
                if node != n.source n.nodes[stack[stack.count - 1].node].taken = true;
                array_add(*order, node);
            }
        }
    }
    a := 0; b := order.count - 1;
    while a < b { t := order[a]; order[a] = order[b]; order[b] = t; a += 1; b -= 1; }
    for src: order {
        n.augmenting[src].count = 0;
        for * e, k: n.edges[src] {
            dst := e.dst;
            if e.on_shortest_path && n.nodes[src].taken && n.nodes[dst].taken && n.nodes[dst].finish < n.nodes[src].finish
                array_add(*n.augmenting[src], .{src, cast(u64) k});
        }
    }
    return order;
}
mcmf_edge_of :: (n: *Mcmf, r: Mcmf_Ref) -> *Mcmf_Edge { return *n.edges[r.src][r.k]; }
mcmf_augment_flow_along_dag :: (n: *Mcmf, order: [] u64) -> bool {
    for src: order {
        n.nodes[src].frac_flow = 0;
        n.nodes[src].int_flow = 0;
        for r: n.augmenting[src] mcmf_edge_of(n, r).augmented_flow = 0;
    }
    max_flow: u64 = cast(u64) PROFI_INF;
    n.nodes[n.source].frac_flow = 1.0;
    for src: order {
        degree := cast(u64) n.augmenting[src].count;
        for r: n.augmenting[src] {
            e := mcmf_edge_of(n, r);
            ef := n.nodes[src].frac_flow / cast(float64) degree;
            n.nodes[e.dst].frac_flow += ef;
            if e.capacity == PROFI_INF continue;
            mi := f64_to_u64(cast(float64) (e.capacity - e.flow) / ef);
            if mi < max_flow max_flow = mi;
        }
    }
    if max_flow == 0 return false;
    n.nodes[n.source].int_flow = max_flow;
    for src: order {
        if src == n.target break;
        degree := cast(u64) n.augmenting[src].count;
        succ_flow := (n.nodes[src].int_flow + degree - 1) / degree;
        for r: n.augmenting[src] {
            e := mcmf_edge_of(n, r);
            dst := e.dst;
            ef := min(n.nodes[src].int_flow, succ_flow);
            ef = min(ef, cast(u64) (e.capacity - e.flow));
            n.nodes[dst].int_flow += ef;
            n.nodes[src].int_flow -= ef;
            e.augmented_flow += ef;
        }
    }
    n.nodes[n.target].int_flow = 0;
    idx := order.count - 1;
    while idx > 0 {
        src := order[idx - 1];
        for r: n.augmenting[src] {
            e := mcmf_edge_of(n, r);
            dst := e.dst;
            if n.nodes[dst].int_flow == 0 continue;
            ef := min(n.nodes[dst].int_flow, e.augmented_flow);
            n.nodes[dst].int_flow -= ef;
            n.nodes[src].int_flow += ef;
            e.augmented_flow -= ef;
        }
        idx -= 1;
    }
    saturated := false;
    for src: order {
        for r: n.augmenting[src] {
            e := mcmf_edge_of(n, r);
            rev := *n.edges[e.dst][e.rev_edge_index];
            e.flow += cast(s64) e.augmented_flow;
            rev.flow -= cast(s64) e.augmented_flow;
            if e.capacity == e.flow && e.augmented_flow > 0 saturated = true;
        }
    }
    return saturated;
}
mcmf_identify_shortest_edges :: (n: *Mcmf, path_cap: u64) {
    min_cap := max(path_cap / 2, 1);
    tdist := n.nodes[n.target].distance;
    for src: 0..n.nodes.count - 1 {
        if n.nodes[src].distance > tdist continue;
        for * e: n.edges[src] {
            dst := e.dst;
            e.on_shortest_path = cast(u64) src != n.target && dst != n.source && n.nodes[dst].distance <= tdist &&
                n.nodes[dst].distance == n.nodes[src].distance + e.cost && e.capacity > e.flow &&
                cast(u64) (e.capacity - e.flow) >= min_cap;
        }
    }
}
// a double -> uint64_t conversion
f64_to_u64 :: (v: float64) -> u64 {
    if v >= 9223372036854775808.0 return (cast(u64) (v - 9223372036854775808.0)) + 0x8000_0000_0000_0000;
    if v <= 0 return 0;
    return cast(u64) v;
}

// ---------------------------------------------------------------- FlowAdjuster

PROFI_ANY_EXIT : u64 : 0xFFFF_FFFF_FFFF_FFFF;
PROFI_MIN_BASE_DISTANCE : u64 : 10000;

fa_find_reachable :: (f: *Flow_Function, src_in: u64, visited: [] bool) {
    if visited[src_in] return;
    queue: [..] u64; queue.allocator = temp;
    qh := 0;
    array_add(*queue, src_in);
    visited[src_in] = true;
    while qh < queue.count {
        src := queue[qh]; qh += 1;
        for j: f.blocks[src].succ_jumps {
            jump := *f.jumps[j];
            if jump.flow > 0 && !visited[jump.target] { array_add(*queue, jump.target); visited[jump.target] = true; }
        }
    }
}
fa_jump_distance :: (f: *Flow_Function, j: s64) -> s64 {
    jump := *f.jumps[j];
    if jump.is_unlikely return PROFI_COST_UNLIKELY;
    nb := cast(u64) f.blocks.count;
    base := max(PROFI_MIN_BASE_DISTANCE, min(f.blocks[f.entry].flow, cast(u64) PROFI_COST_UNLIKELY / (2 * (nb + 1))));
    if jump.flow > 0 return cast(s64) (base + base / jump.flow);
    return cast(s64) (2 * base * (nb + 1));
}
// findShortestPath(Source, Target): Dijkstra with a std::set<(distance, node)> queue
fa_find_shortest_path :: (f: *Flow_Function, source: u64, target_in: u64) -> [..] s64 {
    result: [..] s64; result.allocator = temp;
    target := target_in;
    if source == target return result;
    if fb_is_exit(*f.blocks[source]) && target == PROFI_ANY_EXIT return result;
    nb := f.blocks.count;
    dist := NewArray(nb, s64,, allocator = temp);
    parent := NewArray(nb, s64,, allocator = temp);
    for * dist it.* = PROFI_INF;
    for * parent it.* = -1;
    dist[source] = 0;
    Q :: struct { d: u64; n: u64; }
    queue: [..] Q; queue.allocator = temp;   // kept sorted
    q_less :: (a: Q, b: Q) -> bool { return a.d < b.d || (a.d == b.d && a.n < b.n); }
    q_insert :: (q: *[..] Q, x: Q) {
        k := 0;
        while k < q.count && q_less(q.*[k], x) k += 1;
        if k < q.count && q.*[k].d == x.d && q.*[k].n == x.n return;
        array_insert_at(q, x, k);
    }
    q_erase :: (q: *[..] Q, x: Q) { for q.* if it.d == x.d && it.n == x.n { array_ordered_remove_by_index(q, it_index); return; } }
    q_insert(*queue, .{0, source});
    while queue.count {
        src := queue[0].n;
        array_ordered_remove_by_index(*queue, 0);
        if src == target || (fb_is_exit(*f.blocks[src]) && target == PROFI_ANY_EXIT) break;
        for j: f.blocks[src].succ_jumps {
            dst := f.jumps[j].target;
            jd := fa_jump_distance(f, j);
            if dist[dst] > dist[src] + jd {
                q_erase(*queue, .{cast(u64) dist[dst], dst});
                dist[dst] = dist[src] + jd;
                parent[dst] = j;
                q_insert(*queue, .{cast(u64) dist[dst], dst});
            }
        }
    }
    if target == PROFI_ANY_EXIT {
        for i: 0..nb - 1 {
            if fb_is_exit(*f.blocks[i]) && parent[i] >= 0 {
                if target == PROFI_ANY_EXIT || dist[target] > dist[i] target = cast(u64) i;
            }
        }
    }
    now := target;
    while now != source {
        array_add(*result, parent[now]);
        now = f.jumps[parent[now]].source;
    }
    a := 0; b := result.count - 1;
    while a < b { t := result[a]; result[a] = result[b]; result[b] = t; a += 1; b -= 1; }
    return result;
}
fa_join_isolated_components :: (f: *Flow_Function) {
    nb := f.blocks.count;
    visited := NewArray(nb, bool,, allocator = temp);
    fa_find_reachable(f, f.entry, visited);
    for i: 0..nb - 1 {
        if f.blocks[i].flow > 0 && !visited[i] {
            fwd := fa_find_shortest_path(f, f.entry, cast(u64) i);
            bwd := fa_find_shortest_path(f, cast(u64) i, PROFI_ANY_EXIT);
            path: [..] s64; path.allocator = temp;
            for fwd array_add(*path, it);
            for bwd array_add(*path, it);
            f.blocks[f.entry].flow += 1;
            for j: path {
                f.jumps[j].flow += 1;
                f.blocks[f.jumps[j].target].flow += 1;
                fa_find_reachable(f, f.jumps[j].target, visited);
            }
        }
    }
}
fa_ignore_jump :: (f: *Flow_Function, src_block: s64, dst_block: s64, j: s64) -> bool {
    jump := *f.jumps[j];
    if jump.is_unlikely && jump.flow == 0 return true;
    js := cast(s64) jump.source; jt := cast(s64) jump.target;
    if dst_block >= 0 && jt == dst_block return false;
    if !f.blocks[jt].has_unknown_weight && js == src_block return true;
    if !f.blocks[jt].has_unknown_weight && f.blocks[jt].flow == 0 return true;
    return false;
}
fa_can_rebalance_at_root :: (f: *Flow_Function, b: s64) -> bool {
    blk := *f.blocks[b];
    if blk.has_unknown_weight || blk.flow == 0 return false;
    for j: blk.succ_jumps if f.blocks[f.jumps[j].target].has_unknown_weight return true;
    return false;
}
fa_find_unknown_subgraph :: (f: *Flow_Function, src: s64, known: *[..] s64, unknown: *[..] s64) {
    visited := NewArray(f.blocks.count, bool,, allocator = temp);
    queue: [..] s64; queue.allocator = temp;
    qh := 0;
    array_add(*queue, src);
    visited[src] = true;
    while qh < queue.count {
        b := queue[qh]; qh += 1;
        for j: f.blocks[b].succ_jumps {
            if fa_ignore_jump(f, src, -1, j) continue;
            dst := cast(s64) f.jumps[j].target;
            if visited[dst] continue;
            visited[dst] = true;
            if !f.blocks[dst].has_unknown_weight array_add(known, dst);
            else { array_add(*queue, dst); array_add(unknown, dst); }
        }
    }
}
fa_can_rebalance_subgraph :: (f: *Flow_Function, src: s64, known: [] s64, unknown: [] s64) -> (bool, s64) {
    if unknown.count == 0 return false, -1;
    if known.count > 1 return false, -1;
    dst: s64 = ifx known.count == 0 then -1 else known[0];
    for b: unknown {
        blk := *f.blocks[b];
        if blk.succ_jumps.count == 0 {
            if dst >= 0 return false, -1;
            continue;
        }
        ignored := 0;
        for j: blk.succ_jumps if fa_ignore_jump(f, src, dst, j) ignored += 1;
        if ignored == blk.succ_jumps.count return false, -1;
    }
    return true, dst;
}
fa_is_acyclic_subgraph :: (f: *Flow_Function, src: s64, dst: s64, unknown: *[..] s64) -> bool {
    indeg := NewArray(f.blocks.count, u64,, allocator = temp);
    fill :: (f: *Flow_Function, src: s64, dst: s64, b: s64, indeg: [] u64) {
        for j: f.blocks[b].succ_jumps {
            if fa_ignore_jump(f, src, dst, j) continue;
            indeg[f.jumps[j].target] += 1;
        }
    }
    fill(f, src, dst, src, indeg);
    for unknown.* fill(f, src, dst, it, indeg);
    if indeg[src] > 0 return false;
    order: [..] s64; order.allocator = temp;
    queue: [..] s64; queue.allocator = temp;
    qh := 0;
    array_add(*queue, src);
    while qh < queue.count {
        b := queue[qh]; qh += 1;
        if dst >= 0 && b == dst break;
        if f.blocks[b].has_unknown_weight && b != src array_add(*order, b);
        for j: f.blocks[b].succ_jumps {
            if fa_ignore_jump(f, src, dst, j) continue;
            d := f.jumps[j].target;
            indeg[d] -= 1;
            if indeg[d] == 0 array_add(*queue, cast(s64) d);
        }
    }
    if unknown.count != order.count return false;
    unknown.count = 0;
    for order array_add(unknown, it);
    return true;
}
fa_rebalance_block :: (f: *Flow_Function, src: s64, dst: s64, b: s64, block_flow_in: u64) {
    block_flow := block_flow_in;
    degree: u64 = 0;
    for j: f.blocks[b].succ_jumps if !fa_ignore_jump(f, src, dst, j) degree += 1;
    if dst < 0 && degree == 0 return;
    succ_flow := (block_flow + degree - 1) / degree;
    for j: f.blocks[b].succ_jumps {
        if fa_ignore_jump(f, src, dst, j) continue;
        fl := min(succ_flow, block_flow);
        f.jumps[j].flow = fl;
        block_flow -= fl;
    }
}
fa_rebalance_unknown_subgraph :: (f: *Flow_Function, src: s64, dst: s64, unknown: [] s64) {
    block_flow: u64 = 0;
    for j: f.blocks[src].succ_jumps {
        if fa_ignore_jump(f, src, dst, j) continue;
        block_flow += f.jumps[j].flow;
    }
    fa_rebalance_block(f, src, dst, src, block_flow);
    for b: unknown {
        bf: u64 = 0;
        for j: f.blocks[b].pred_jumps bf += f.jumps[j].flow;
        f.blocks[b].flow = bf;
        fa_rebalance_block(f, src, dst, b, bf);
    }
}
fa_rebalance_unknown_subgraphs :: (f: *Flow_Function) {
    for src: 0..f.blocks.count - 1 {
        if !fa_can_rebalance_at_root(f, src) continue;
        unknown: [..] s64; unknown.allocator = temp;
        known: [..] s64; known.allocator = temp;
        fa_find_unknown_subgraph(f, src, *known, *unknown);
        ok, dst := fa_can_rebalance_subgraph(f, src, known, unknown);
        if !ok continue;
        if !fa_is_acyclic_subgraph(f, src, dst, *unknown) continue;
        fa_rebalance_unknown_subgraph(f, src, dst, unknown);
    }
}

// ---------------------------------------------------------------- the network

profi_block_costs :: (p: *Profi_Params, b: *Flow_Block) -> (s64, s64) {
    if b.is_unlikely return PROFI_COST_UNLIKELY, PROFI_COST_UNLIKELY;
    inc := p.cost_block_inc; dec := p.cost_block_dec;
    if b.has_unknown_weight { inc = p.cost_block_unknown_inc; dec = 0; }
    else {
        if b.weight == 0 inc = p.cost_block_zero_inc;
        if fb_is_entry(b) { inc = p.cost_block_entry_inc; dec = p.cost_block_entry_dec; }
    }
    return inc, dec;
}
profi_jump_costs :: (p: *Profi_Params, j: *Flow_Jump) -> (s64, s64) {
    if j.is_unlikely return PROFI_COST_UNLIKELY, PROFI_COST_UNLIKELY;
    inc := p.cost_jump_inc; dec := p.cost_jump_dec;
    if j.source + 1 == j.target { inc = p.cost_jump_ft_inc; dec = p.cost_jump_ft_dec; }
    if j.has_unknown_weight {
        if j.source + 1 == j.target inc = p.cost_jump_unknown_ft_inc;
        else inc = p.cost_jump_unknown_inc;
        dec = 0;
    }
    return inc, dec;
}
profi_initialize_network :: (p: *Profi_Params, n: *Mcmf, f: *Flow_Function) {
    nb := cast(u64) f.blocks.count;
    s := 2 * nb; t := s + 1; s1 := s + 2; t1 := s + 3;
    mcmf_init(n, 2 * nb + 4, s1, t1);
    for b: 0..nb - 1 {
        blk := *f.blocks[b];
        bin := 2 * b; bout := 2 * b + 1;
        if fb_is_entry(blk) mcmf_add_edge_inf(n, s, bin, 0);
        else if fb_is_exit(blk) mcmf_add_edge_inf(n, bout, t, 0);
        inc, dec := profi_block_costs(p, blk);
        mcmf_add_edge_inf(n, bin, bout, inc);
        if blk.weight > 0 {
            mcmf_add_edge(n, bout, bin, cast(s64) blk.weight, dec);
            mcmf_add_edge(n, s1, bout, cast(s64) blk.weight, 0);
            mcmf_add_edge(n, bin, t1, cast(s64) blk.weight, 0);
        }
    }
    for * j: f.jumps {
        jin := 2 * j.source + 1;
        jout := 2 * j.target;
        inc, dec := profi_jump_costs(p, j);
        mcmf_add_edge_inf(n, jin, jout, inc);
        if j.weight > 0 {
            mcmf_add_edge(n, jout, jin, cast(s64) j.weight, dec);
            mcmf_add_edge(n, s1, jout, cast(s64) j.weight, 0);
            mcmf_add_edge(n, jin, t1, cast(s64) j.weight, 0);
        }
    }
    mcmf_add_edge_inf(n, t, s, 0);
}
profi_extract_weights :: (n: *Mcmf, f: *Flow_Function) {
    for * j: f.jumps {
        src_out := 2 * j.source + 1;
        dst_in := 2 * j.target;
        aux := mcmf_get_flow(n, src_out, dst_in);
        fl: s64;
        if j.source != j.target fl = cast(s64) j.weight + aux;
        else fl = cast(s64) j.weight + (ifx aux > 0 then aux else 0);
        j.flow = cast(u64) fl;
    }
    inflow := NewArray(f.blocks.count, u64,, allocator = temp);
    outflow := NewArray(f.blocks.count, u64,, allocator = temp);
    for f.jumps { inflow[it.target] += it.flow; outflow[it.source] += it.flow; }
    for * f.blocks it.flow = max(outflow[it_index], inflow[it_index]);
}

// applyFlowInference(Func) with the command-line parameters
profi_apply_flow_inference :: (f: *Flow_Function) {
    p: Profi_Params;
    p.even_flow_distribution = sp_opts.profi_even_flow_distribution;
    p.rebalance_unknown = sp_opts.profi_rebalance_unknown;
    p.join_islands = sp_opts.profi_join_islands;
    p.cost_block_inc = sp_opts.profi_cost_block_inc;
    p.cost_block_dec = sp_opts.profi_cost_block_dec;
    p.cost_block_entry_inc = sp_opts.profi_cost_block_entry_inc;
    p.cost_block_entry_dec = sp_opts.profi_cost_block_entry_dec;
    p.cost_block_zero_inc = sp_opts.profi_cost_block_zero_inc;
    p.cost_block_unknown_inc = sp_opts.profi_cost_block_unknown_inc;
    has_samples := false;
    for * f.blocks { if it.weight > 0 has_samples = true; it.flow = it.weight; }
    for * f.jumps { if it.weight > 0 has_samples = true; it.flow = it.weight; }
    if f.blocks.count <= 1 || !has_samples return;
    n: Mcmf;
    n.params = *p;
    profi_initialize_network(*p, *n, f);
    mcmf_run(*n);
    profi_extract_weights(*n, f);
    if p.join_islands fa_join_isolated_components(f);
    if p.rebalance_unknown fa_rebalance_unknown_subgraphs(f);
}

// SampleProfileInference<Function>::apply (via SampleProfileLoaderBaseImpl::applyProfi)
sp_apply_profi :: (fn: Value_Id, sample_weights: *Table(Value_Id, u64)) {
    // forward reachable from the entry, backward reachable from an exit
    reach: Table(Value_Id, bool); reach.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    tmp: [..] Value_Id; tmp.allocator = temp;
    array_add(*wl, fn_entry(fn));
    table_set(*reach, fn_entry(fn), true);
    while wl.count {
        b := pop(*wl);
        tmp.count = 0;
        block_successors(b, *tmp);
        for tmp if !table_contains(*reach, it) { table_set(*reach, it, true); array_add(*wl, it); }
    }
    inv: Table(Value_Id, bool); inv.allocator = temp;
    for b: fn_blocks(fn) {
        if num_successors(block_terminator(b)) != 0 continue;
        if table_contains(*inv, b) continue;
        table_set(*inv, b, true);
        array_add(*wl, b);
        while wl.count {
            x := pop(*wl);
            tmp.count = 0;
            block_predecessors(x, *tmp);
            for tmp if !table_contains(*inv, it) { table_set(*inv, it, true); array_add(*wl, it); }
        }
    }
    blocks: [..] Value_Id; blocks.allocator = temp;
    index: Table(Value_Id, s64); index.allocator = temp;
    for b: fn_blocks(fn) {
        if table_contains(*reach, b) && table_contains(*inv, b) { table_set(*index, b, blocks.count); array_add(*blocks, b); }
    }
    table_reset(*spl.block_weights);
    table_reset(*spl.edge_weights);
    has_samples := false;
    for b: blocks {
        found, w := table_find(sample_weights, b);
        if found && w > 0 { has_samples = true; spl_set_bw(b, w); }
    }
    if blocks.count <= 1 || !has_samples return;
    // createFlowFunction
    f: Flow_Function;
    f.blocks.allocator = temp; f.jumps.allocator = temp;
    for b: blocks {
        blk: Flow_Block;
        blk.succ_jumps.allocator = temp; blk.pred_jumps.allocator = temp;
        found, w := table_find(sample_weights, b);
        if found { blk.has_unknown_weight = false; blk.weight = w; }
        blk.index = cast(u64) f.blocks.count;
        array_add(*f.blocks, blk);
    }
    for b: blocks {
        for s: table_find_pointer(*spl.succs, b).* {
            found, si := table_find(*index, s);
            if !found continue;
            _, bi := table_find(*index, b);
            j: Flow_Jump;
            j.source = cast(u64) bi; j.target = cast(u64) si;
            array_add(*f.jumps, j);
        }
    }
    for j, k: f.jumps {
        array_add(*f.blocks[j.source].succ_jumps, k);
        array_add(*f.blocks[j.target].pred_jumps, k);
    }
    // findUnlikelyJumps (SampleProfile.cpp's specialization)
    for * j: f.jumps {
        bb := blocks[j.source];
        succ := blocks[j.target];
        ti := block_terminator(bb);
        succs := table_find_pointer(*spl.succs, bb);
        if succs.count == 2 && succs.*[1] == succ && inst_op(ti) == .INVOKE j.is_unlikely = true;
        sti := block_terminator(succ);
        if num_successors(sti) == 0 && inst_op(sti) == .UNREACHABLE j.is_unlikely = true;
    }
    for k: 0..f.blocks.count - 1 if fb_is_entry(*f.blocks[k]) { f.entry = cast(u64) k; break; }
    e := *f.blocks[f.entry];
    if e.weight == 0 && !e.has_unknown_weight { e.weight = 1; e.has_unknown_weight = false; }
    profi_apply_flow_inference(*f);
    for b, k: blocks spl_set_bw(b, f.blocks[k].flow);
    for j: f.jumps spl_set_ew(blocks[j.source], blocks[j.target], j.flow);
}
