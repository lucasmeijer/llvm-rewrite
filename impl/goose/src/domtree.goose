// Dominator and post-dominator trees, with LLVM's incremental updates.
// Ports:
//   llvm/include/llvm/Support/GenericDomTreeConstruction.h  SemiNCAInfo: runDFS, runSemiNCA, FindRoots,
//       RemoveRedundantRoots, CalculateFromScratch, attachNewSubtree, reattachExistingSubtree, InsertEdge,
//       InsertReachable, InsertUnreachable, ComputeUnreachableDominators, DeleteEdge, DeleteReachable,
//       HasProperSupport, DeleteUnreachable, UpdateRootsBeforeInsertion, UpdateRootsAfterUpdate, ApplyUpdates
//   llvm/include/llvm/Support/GenericDomTree.h  DomTreeNodeBase (FirstChild/Sibling child list, setIDom,
//       UpdateLevel), dominates (SlowQueries, DFS numbers), findNearestCommonDominator, updateDFSNumbers,
//       addNewBlock, changeImmediateDominator, eraseNode, splitBlock (Split<>), applyUpdates
//   llvm/include/llvm/Support/CFGUpdate.h  LegalizeUpdates
//   llvm/include/llvm/Support/CFGDiff.h  GraphDiff (the batch-update CFG snapshot)
// The tree's child order is LLVM's: nodes are appended to their idom's child list when created or re-parented,
// the DFS visits successors in order (reversed onto a LIFO worklist) and predecessors in use-list order, and the
// bucket queue of InsertReachable is libstdc++'s binary heap, so updates produce the same tree as opt.
// Usage (DESIGN.md §8.5): dt_get computes a tree; passes that change the CFG either apply updates
// (dt_apply_updates, or the DomTreeUpdater in dtu.goose) and return a preserved set that keeps the tree, or
// drop it.
import std;
import ir;
import irutil;

let DT_DOM = 0;
let DT_POST = 1;
let DT_VROOT: i32 = -2;      // the post-dominator tree's virtual exit node (LLVM's nullptr block)

// cfg::UpdateKind
let DT_INSERT: i32 = 0;
let DT_DELETE: i32 = 1;
struct DTUpdate { kind: i32, from: i32, to: i32 }

// One record per (block index, tree kind): index = block index * 2 + kind. Valid iff epoch matches the tree's.
struct DTNode { epoch: i32, idom: i32, first: i32, last: i32, next: i32, prev: i32, level: i32, dfs_in: u32, dfs_out: u32 }
// One record per (function glob index, tree kind). The virtual root's children and DFS numbers live here.
// nodes_size mirrors DomTreeNodes.size() (indexed by block number + 1), which ApplyUpdates' threshold reads.
struct DTHead { epoch: i32, valid: bool, root: i32, vfirst: i32, vlast: i32, roots_at: i32, nroots: i32, roots_cap: i32,
                dfs_valid: bool, slow: i32, nodes_size: i32, vdfs_in: u32, vdfs_out: u32 }

var dt_nodes: DTNode[>..];
var dt_heads: DTHead[>..];
var dt_roots_pool: i32[>..];
var dt_next_epoch: i32 = 1;

let DT_NONUM: u32 = 0xFFFFFFFF;

// Index computations never grow the tables (Goose evaluates `a[f()]`'s bounds before f runs); dt_grow does.
fn dt_head_idx(fv: i32, t: i64) -> i64 { (glob_of(fv) as i64) * 2 + t }
fn dt_node_idx(bv: i32, t: i64) -> i64 { (block_of(bv) as i64) * 2 + t }
fn dt_grow() {
    while dt_heads.len < globs.len * 2 {
        dt_heads.push(DTHead { epoch: 0, valid: false, root: -1, vfirst: -1, vlast: -1, roots_at: 0, nroots: 0, roots_cap: 0,
                               dfs_valid: false, slow: 0, nodes_size: 0, vdfs_in: DT_NONUM, vdfs_out: DT_NONUM });
    }
    while dt_nodes.len < blocks.len * 2 {
        dt_nodes.push(DTNode { epoch: 0, idom: -1, first: -1, last: -1, next: -1, prev: -1, level: 0, dfs_in: DT_NONUM, dfs_out: DT_NONUM });
    }
}

fn dt_valid(fv: i32, t: i64) -> bool { let k = dt_head_idx(fv, t); return k < dt_heads.len && dt_heads[k].valid; }
fn dt_invalidate(fv: i32, t: i64) { let k = dt_head_idx(fv, t); if k < dt_heads.len { dt_heads[k].valid = false; } }

// ---------------------------------------------------------------------------------------------
// The tree being worked on. Every public entry point sets these two first; the t_* helpers use them.

var cf: i32 = -1;       // function
var ct: i64 = 0;        // DT_DOM / DT_POST

fn dt_focus(fv: i32, t: i64) { cf = fv; ct = t; dt_grow(); }
fn hk0() -> i64 { dt_head_idx(cf, ct) }
fn is_post() -> bool { ct == DT_POST }

// DT.getNode(BB) != nullptr. n may be DT_VROOT; -1 is "no node".
fn t_has(n: i32) -> bool {
    if n == DT_VROOT { return ct == DT_POST && dt_heads[hk0()].root == DT_VROOT; }
    if n < 0 { return false; }
    let k = dt_node_idx(n, ct);
    return k < dt_nodes.len && dt_nodes[k].epoch == dt_heads[hk0()].epoch;
}
fn t_idom(n: i32) -> i32 { if n == DT_VROOT { -1 } else { dt_nodes[dt_node_idx(n, ct)].idom } }
fn t_level(n: i32) -> i32 { if n == DT_VROOT { 0 } else { dt_nodes[dt_node_idx(n, ct)].level } }
fn t_first(n: i32) -> i32 { if n == DT_VROOT { dt_heads[hk0()].vfirst } else { dt_nodes[dt_node_idx(n, ct)].first } }
fn t_last(n: i32) -> i32 { if n == DT_VROOT { dt_heads[hk0()].vlast } else { dt_nodes[dt_node_idx(n, ct)].last } }
fn t_next(n: i32) -> i32 { dt_nodes[dt_node_idx(n, ct)].next }
fn t_set_first(n: i32, c: i32) { if n == DT_VROOT { dt_heads[hk0()].vfirst = c; } else { dt_nodes[dt_node_idx(n, ct)].first = c; } }
fn t_set_last(n: i32, c: i32) { if n == DT_VROOT { dt_heads[hk0()].vlast = c; } else { dt_nodes[dt_node_idx(n, ct)].last = c; } }
fn t_dfs_in(n: i32) -> u32 { if n == DT_VROOT { dt_heads[hk0()].vdfs_in } else { dt_nodes[dt_node_idx(n, ct)].dfs_in } }
fn t_dfs_out(n: i32) -> u32 { if n == DT_VROOT { dt_heads[hk0()].vdfs_out } else { dt_nodes[dt_node_idx(n, ct)].dfs_out } }
fn t_set_dfs_in(n: i32, x: u32) { if n == DT_VROOT { dt_heads[hk0()].vdfs_in = x; } else { dt_nodes[dt_node_idx(n, ct)].dfs_in = x; } }
fn t_set_dfs_out(n: i32, x: u32) { if n == DT_VROOT { dt_heads[hk0()].vdfs_out = x; } else { dt_nodes[dt_node_idx(n, ct)].dfs_out = x; } }
fn t_invalidate_dfs() { dt_heads[hk0()].dfs_valid = false; }

// DomTreeNodeBase::addChild / removeChild
fn t_add_child(p: i32, c: i32) {
    let ck = dt_node_idx(c, ct);
    let last = t_last(p);
    dt_nodes[ck].prev = last;
    dt_nodes[ck].next = -1;
    if last >= 0 { dt_nodes[dt_node_idx(last, ct)].next = c; } else { t_set_first(p, c); }
    t_set_last(p, c);
}
fn t_remove_child(p: i32, c: i32) {
    let ck = dt_node_idx(c, ct);
    let pv = dt_nodes[ck].prev;
    let nx = dt_nodes[ck].next;
    if pv >= 0 { dt_nodes[dt_node_idx(pv, ct)].next = nx; } else { t_set_first(p, nx); }
    if nx >= 0 { dt_nodes[dt_node_idx(nx, ct)].prev = pv; } else { t_set_last(p, pv); }
    dt_nodes[ck].prev = -1;
    dt_nodes[ck].next = -1;
}

// DominatorTreeBase::createNode(BB, IDom): idom is a block, DT_VROOT or -1 (a root node).
fn t_create_node(bb: i32, idom: i32) {
    dt_grow();
    let h = hk0();
    // getNodeIndexForInsert: DomTreeNodes grows to max(getMaxNumber, Idx + 1)
    let idx: i64 = if bb == DT_VROOT { 0 } else { block_number(bb) as i64 + 1 };
    if idx >= dt_heads[h].nodes_size as i64 {
        let mx = func_max_block_number(cf) as i64;
        dt_heads[h].nodes_size = (if mx > idx + 1 { mx } else { idx + 1 }) as i32;
    }
    let lvl: i32 = if idom == -1 { 0 } else { t_level(idom) + 1 };
    if bb == DT_VROOT {
        dt_heads[h].vfirst = -1;
        dt_heads[h].vlast = -1;
        dt_heads[h].vdfs_in = DT_NONUM;
        dt_heads[h].vdfs_out = DT_NONUM;
        return;
    }
    let k = dt_node_idx(bb, ct);
    dt_nodes[k] = DTNode { epoch: dt_heads[h].epoch, idom: idom, first: -1, last: -1, next: -1, prev: -1, level: lvl, dfs_in: DT_NONUM, dfs_out: DT_NONUM };
    if idom != -1 { t_add_child(idom, bb); }
}

// DomTreeNodeBase::UpdateLevel
fn t_update_level(n: i32) {
    let id = t_idom(n);
    if t_level(n) == t_level(id) + 1 { return; }
    var ws: i32[>..<] = [];
    ws.push(n);
    while ws.len > 0 {
        let cur = ws.pop();
        let cl = t_level(t_idom(cur)) + 1;
        dt_nodes[dt_node_idx(cur, ct)].level = cl;
        var c = t_first(cur);
        while c >= 0 {
            if t_level(c) != cl + 1 { ws.push(c); }
            c = t_next(c);
        }
    }
}

// DomTreeNodeBase::setIDom
fn t_set_idom(n: i32, nid: i32) {
    let old = t_idom(n);
    if old == nid { return; }
    t_remove_child(old, n);
    dt_nodes[dt_node_idx(n, ct)].idom = nid;
    t_add_child(nid, n);
    t_update_level(n);
}

// Roots: a run in dt_roots_pool, copied to a bigger run when it grows.
fn t_nroots() -> i64 { dt_heads[hk0()].nroots as i64 }
fn t_root_at(k: i64) -> i32 { dt_roots_pool[dt_heads[hk0()].roots_at + k] }
fn t_roots_contains(b: i32) -> bool { for k in t_nroots() { if t_root_at(k) == b { return true; } } return false; }
fn t_roots_set(rs: const i32[:]) {
    let h = hk0();
    dt_heads[h].roots_at = dt_roots_pool.len as i32;
    dt_heads[h].nroots = rs.len as i32;
    dt_heads[h].roots_cap = rs.len as i32;
    for r in rs { dt_roots_pool.push(r); }
}
fn t_roots_push(b: i32) {
    let h = hk0();
    let n = dt_heads[h].nroots;
    if n == dt_heads[h].roots_cap {
        let at = dt_heads[h].roots_at;
        let nat = dt_roots_pool.len as i32;
        for k in n { dt_roots_pool.push(dt_roots_pool[at + k]); }
        for k in n + 4 { dt_roots_pool.push(-1); }
        dt_heads[h].roots_at = nat;
        dt_heads[h].roots_cap = n * 2 + 4;
    }
    dt_roots_pool[dt_heads[h].roots_at + n] = b;
    dt_heads[h].nroots = n + 1;
}
// find + swap with back + pop_back (eraseNode)
fn t_roots_swap_remove(b: i32) {
    let h = hk0();
    let at = dt_heads[h].roots_at as i64;
    let n = dt_heads[h].nroots as i64;
    for k in n {
        if dt_roots_pool[at + k] == b {
            dt_roots_pool[at + k] = dt_roots_pool[at + n - 1];
            dt_heads[h].nroots = (n - 1) as i32;
            return;
        }
    }
}

// DominatorTreeBase::reset (and Parent kept): a new epoch invalidates every node.
fn t_reset() {
    let h = hk0();
    dt_heads[h].epoch = dt_next_epoch;
    dt_next_epoch++;
    dt_heads[h].valid = true;
    dt_heads[h].root = -1;
    dt_heads[h].vfirst = -1;
    dt_heads[h].vlast = -1;
    dt_heads[h].nroots = 0;
    dt_heads[h].roots_cap = 0;
    dt_heads[h].dfs_valid = false;
    dt_heads[h].slow = 0;
    dt_heads[h].nodes_size = 0;
}

// DominatorTreeBase::eraseNode (the node must be a leaf).
fn t_erase_node(bb: i32) {
    if t_first(bb) >= 0 { fatal("internal: dominator tree eraseNode of a node that is not a leaf"); }
    t_invalidate_dfs();
    let id = t_idom(bb);
    if id != -1 { t_remove_child(id, bb); }
    dt_nodes[dt_node_idx(bb, ct)].epoch = 0;
    if is_post() { t_roots_swap_remove(bb); }
}

// updateDFSNumbers
fn t_update_dfs_numbers() {
    let h = hk0();
    if dt_heads[h].dfs_valid { dt_heads[h].slow = 0; return; }
    let root = dt_heads[h].root;
    if root == -1 { return; }
    var sn: i32[>..<] = [];
    var sc: i32[>..<] = [];
    var num: u32 = 0;
    sn.push(root);
    sc.push(t_first(root));
    t_set_dfs_in(root, num);
    num++;
    while sn.len > 0 {
        let top = sn.len - 1;
        let n = sn[top];
        let c = sc[top];
        if c < 0 {
            t_set_dfs_out(n, num);
            sn.pop();
            sc.pop();
        } else {
            sc[top] = t_next(c);
            sn.push(c);
            sc.push(t_first(c));
            t_set_dfs_in(c, num);
            num++;
        }
    }
    dt_heads[h].slow = 0;
    dt_heads[h].dfs_valid = true;
}

fn t_dominated_by(b: i32, a: i32) -> bool { t_dfs_in(b) >= t_dfs_in(a) && t_dfs_out(b) <= t_dfs_out(a) }

// dominates(const DomTreeNodeBase *A, const DomTreeNodeBase *B); -1 = null node.
fn t_dominates_nodes(a: i32, b: i32) -> bool {
    if b == a { return true; }
    if b == -1 { return true; }
    if a == -1 { return false; }
    if t_idom(b) == a { return true; }
    if t_idom(a) == b { return false; }
    if t_level(a) >= t_level(b) { return false; }
    let h = hk0();
    if dt_heads[h].dfs_valid { return t_dominated_by(b, a); }
    dt_heads[h].slow += 1;
    if dt_heads[h].slow > 32 {
        t_update_dfs_numbers();
        return t_dominated_by(b, a);
    }
    // dominatedBySlowTreeWalk
    let al = t_level(a);
    var x = b;
    loop {
        let id = t_idom(x);
        if id == -1 || t_level(id) < al { break; }
        x = id;
    }
    return x == a;
}
fn t_node(bb: i32) -> i32 { if t_has(bb) { bb } else { -1 } }

// findNearestCommonDominator(A, B) for blocks in the tree; may return DT_VROOT for post-dominators.
fn t_find_ncd(a: i32, b: i32) -> i32 {
    if !is_post() {
        let e = func_entry(cf);
        if a == e || b == e { return e; }
    }
    var na = a;
    var nb = b;
    while na != nb {
        if t_level(na) < t_level(nb) { let tmp = na; na = nb; nb = tmp; }
        na = t_idom(na);
    }
    return na;
}

// ---------------------------------------------------------------------------------------------
// GraphDiff: the CFG snapshot an incremental batch update walks (CFGDiff.h). Three instances can be alive at once:
// 0 = the PreViewCFG of a DT batch update, 1 = its PostViewCFG (applyUpdates(Updates, PostViewUpdates)), 2 = a
// GraphDiff of a client (MemorySSAUpdater::applyInsertUpdates). Per (block, instance, map, kind) a stack of
// children: map 0 = Succ, 1 = Pred; kind 0 = DI[0] deleted, 1 = DI[1] inserted. The item pool is shared (items are
// immutable; popping moves a head), so "PreViewCFG = *PostViewCFG" is gd_pre_is_post (instance 0 reads instance 1).

struct GDItem { child: i32, prev: i32 }
var gd_items: GDItem[>..<];
var gd_head: i32[>..];
var gd_stamp: i32[>..];
var gd_epochs: i32[3] = [0; 3];
var gd_next_epoch: i32 = 0;
var gd_invs: bool[3] = [false; 3];        // InverseGraph (post-dominators)
var gd_revs: bool[3] = [false; 3];        // UpdatedAreReverseApplied
var gd_upds: DTUpdate[>..<];    // LegalizedUpdates of instance 0 (popped from the back)
var gd_upds1: DTUpdate[>..<];   // LegalizedUpdates of instance 1
var gd_pre_is_post: bool = false;
var gd_has_post: bool = false;  // BUI->PostViewCFG != nullptr

fn gd_real(inst: i64) -> i64 { if inst == 0 && gd_pre_is_post { 1 } else { inst } }
fn gd_key(inst: i64, n: i32, m: i64, ins: i64) -> i64 { (block_of(n) as i64) * 12 + inst * 4 + m * 2 + ins }
fn gd_top(inst: i64, key: i64) -> i32 { if key < gd_stamp.len && gd_stamp[key] == gd_epochs[inst] { gd_head[key] } else { -1 } }
fn gd_push(inst: i64, key: i64, c: i32) {
    while gd_stamp.len <= key { gd_stamp.push(0); gd_head.push(-1); }
    let top = gd_top(inst, key);
    let id = gd_items.len as i32;
    gd_items.push(GDItem { child: c, prev: top });
    gd_stamp[key] = gd_epochs[inst];
    gd_head[key] = id;
}
fn gd_pop(inst: i64, key: i64) {
    let top = gd_top(inst, key);
    if top < 0 { fatal("internal: GraphDiff pop of an empty list"); }
    gd_head[key] = gd_items[top].prev;
}

struct LOp { from: i32, to: i32, idx: i32, delta: i32 }

// cfg::LegalizeUpdates(AllUpdates, Result, InverseGraph, ReverseResultOrder = false)
fn legalize_updates(ups: const DTUpdate[:], inverse: bool, out: DTUpdate[>..<]&) {
    var ops: LOp[>..<] = [];
    for u, i in ups {
        let f = if inverse { u.to } else { u.from };
        let t = if inverse { u.from } else { u.to };
        ops.push(LOp { from: f, to: t, idx: i as i32, delta: if u.kind == DT_INSERT { 1 } else { -1 } });
    }
    sort(ops) { a, b => if a.from != b.from { a.from < b.from } else if a.to != b.to { a.to < b.to } else { a.idx < b.idx } };
    var res: LOp[>..<] = [];
    var i: i64 = 0;
    while i < ops.len {
        var j = i;
        var sum: i32 = 0;
        while j < ops.len && ops[j].from == ops[i].from && ops[j].to == ops[i].to { sum += ops[j].delta; j++; }
        if sum != 0 { res.push(LOp { from: ops[i].from, to: ops[i].to, idx: ops[j - 1].idx, delta: sum }); }
        i = j;
    }
    // Ordered by the index of each edge's last update, descending (so popping from the back applies them in order).
    sort(res) { a, b => a.idx > b.idx };
    out.clear();
    for r in res { out.push(DTUpdate { kind: if r.delta > 0 { DT_INSERT } else { DT_DELETE }, from: r.from, to: r.to }); }
}

// GraphDiff(Updates, ReverseApplyUpdates) as instance inst (2 = a client's GraphDiff<BasicBlock *>)
fn gd_init(inst: i64, ups: const DTUpdate[:], inverse: bool, reverse_apply: bool) {
    gd_next_epoch++;
    gd_epochs[inst] = gd_next_epoch;
    if inst == 0 { gd_pre_is_post = false; }
    gd_invs[inst] = inverse;
    gd_revs[inst] = reverse_apply;
    var lu: DTUpdate[>..<] = [];
    legalize_updates(ups, inverse, lu);
    for u in lu {
        let ins: i64 = if (u.kind == DT_INSERT) == !reverse_apply { 1 } else { 0 };
        gd_push(inst, gd_key(inst, u.from, 0, ins), u.to);
        gd_push(inst, gd_key(inst, u.to, 1, ins), u.from);
    }
    if inst == 0 { gd_upds.clear(); for u in lu { gd_upds.push(u); } }
    else if inst == 1 { gd_upds1.clear(); for u in lu { gd_upds1.push(u); } }
}

// popUpdateForIncrementalUpdates on the PreViewCFG (instance 0, or 1 when the PreViewCFG is the PostViewCFG)
fn gd_num_updates() -> i64 { if gd_real(0) == 1 { gd_upds1.len } else { gd_upds.len } }
fn gd_pop_update() -> DTUpdate {
    let inst = gd_real(0);
    let u = if inst == 1 { gd_upds1.pop() } else { gd_upds.pop() };
    let ins: i64 = if (u.kind == DT_INSERT) == !gd_revs[inst] { 1 } else { 0 };
    gd_pop(inst, gd_key(inst, u.from, 0, ins));
    gd_pop(inst, gd_key(inst, u.to, 1, ins));
    return u;
}

// GraphDiff::getChildren<InverseEdge>(N) of instance inst: successors reversed or predecessors (use-list order),
// minus the snapshot's deleted children, plus its inserted ones.
fn gd_children(inst0: i64, n: i32, inverse: bool, out: i32[>..<]&) {
    let inst = gd_real(inst0);
    out.clear();
    if !inverse {
        let tm = block_terminator(n);
        if tm >= 0 {
            var k = term_nsucc(tm);
            while k > 0 { k--; out.push(term_succ(tm, k)); }
        }
    } else {
        each_pred(n) { p => out.push(p); };
    }
    let m: i64 = if inverse != gd_invs[inst] { 1 } else { 0 };
    var it = gd_top(inst, gd_key(inst, n, m, 0));
    while it >= 0 {
        let c = gd_items[it].child;
        var w: i64 = 0;
        for r in out.len { if out[r] != c { out[w] = out[r]; w++; } }
        out.resize(w);
        it = gd_items[it].prev;
    }
    let mark = out.len;
    it = gd_top(inst, gd_key(inst, n, m, 1));
    while it >= 0 { out.push(gd_items[it].child); it = gd_items[it].prev; }
    reverse(out[mark..]);
}

// SemiNCAInfo::getChildren<Inversed>(N, BUI): successors (reversed, for a LIFO worklist) or predecessors (in
// use-list order); with a batch update in progress, the PreViewCFG's children.
fn dt_children(n: i32, inverse: bool, bui: bool, out: i32[>..<]&) {
    if bui { gd_children(0, n, inverse, out); return; }
    out.clear();
    if !inverse {
        let tm = block_terminator(n);
        if tm >= 0 {
            var k = term_nsucc(tm);
            while k > 0 { k--; out.push(term_succ(tm, k)); }
        }
    } else {
        each_pred(n) { p => out.push(p); };
    }
}

// ---------------------------------------------------------------------------------------------
// SemiNCAInfo state (one at a time; every `SemiNCAInfo SNCA(BUI)` in LLVM is an sn_clear here). NodeInfos are
// indexed by block index + 1 (0 = the virtual root), cleared in O(1) with an epoch stamp.

struct SInfo { stamp: i32, dfs1: i32, parent: i32, semi: i32, label: i32, idom: i32, rcs: i32 }
var sn_info: SInfo[>..];
var sn_epoch: i32 = 0;
var sn_n2n: i32[>..<];          // NumToNode
var sn_rc_par: i32[>..<];       // ReverseChildren: (parent DFS number, next) pairs
var sn_rc_next: i32[>..<];
var sn_bui: bool = false;       // BatchUpdates != nullptr
var sn_order: i32[>..];         // SuccOrder, by block index (0 = absent), stamped with sn_order_epoch
var sn_order_stamp: i32[>..];
var sn_order_epoch: i32 = 0;

fn sn_clear(bui: bool) {
    sn_epoch++;
    sn_n2n.clear();
    sn_rc_par.clear();
    sn_rc_next.clear();
    sn_bui = bui;
}
// getNodeInfo(BB): the record's index
fn sn_i(n: i32) -> i64 {
    let k: i64 = if n == DT_VROOT { 0 } else { block_of(n) as i64 + 1 };
    while sn_info.len <= k { sn_info.push(SInfo { stamp: 0, dfs1: 0, parent: 0, semi: 0, label: 0, idom: -1, rcs: 0 }); }
    if sn_info[k].stamp != sn_epoch { sn_info[k] = SInfo { stamp: sn_epoch, dfs1: 0, parent: 0, semi: 0, label: 0, idom: -1, rcs: 0 }; }
    return k;
}
fn sn_visited(n: i32) -> bool { let k = sn_i(n); return sn_info[k].dfs1 != 0; }

// runDFS<IsReverse>(V, LastNum, Condition, AttachToNum, SuccOrder)
fn sn_run_dfs<C>(v: i32, last0: i64, attach: i64, is_reverse: bool, with_order: bool) -> i64 {
    var last = last0;
    var wl_n: i32[>..<] = [];
    var wl_p: i32[>..<] = [];
    var ch: i32[>..<] = [];
    wl_n.push(v);
    wl_p.push(attach as i32);
    let vk = sn_i(v);
    sn_info[vk].parent = attach as i32;
    let dir = is_reverse != is_post();
    while wl_n.len > 0 {
        let bb = wl_n.pop();
        let pn = wl_p.pop();
        let k = sn_i(bb);
        sn_rc_par.push(pn);
        sn_rc_next.push(sn_info[k].rcs);
        sn_info[k].rcs = sn_rc_par.len as i32;
        if sn_info[k].dfs1 != 0 { continue; }
        sn_info[k].parent = pn;
        let num = last;
        last++;
        sn_info[k].semi = num as i32;
        sn_info[k].label = num as i32;
        sn_info[k].dfs1 = (num + 1) as i32;
        sn_n2n.push(bb);
        dt_children(bb, dir, sn_bui, ch);
        if with_order && ch.len > 1 { sort(ch) { a, c => sn_order_of(a) < sn_order_of(c) }; }
        for s in ch {
            if C(bb, s) { wl_n.push(s); wl_p.push(num as i32); }
        }
    }
    return last;
}
fn sn_order_of(b: i32) -> i32 {
    let k = block_of(b) as i64;
    if k < sn_order_stamp.len && sn_order_stamp[k] == sn_order_epoch { return sn_order[k]; }
    return 0;
}
fn sn_order_set(b: i32, x: i32) {
    let k = block_of(b) as i64;
    while sn_order_stamp.len <= k { sn_order_stamp.push(0); sn_order.push(0); }
    sn_order_stamp[k] = sn_order_epoch;
    sn_order[k] = x;
}
fn sn_order_has(b: i32) -> bool { let k = block_of(b) as i64; k < sn_order_stamp.len && sn_order_stamp[k] == sn_order_epoch }

// eval(V, LastLinked) with path compression; V is a DFS number.
var sn_estack: i32[>..<];
fn sn_eval(v: i64, last_linked: i64) -> i32 {
    var vi = sn_i(sn_n2n[v]);
    if sn_info[vi].parent as i64 < last_linked { return sn_info[vi].label; }
    loop {
        sn_estack.push(vi as i32);
        vi = sn_i(sn_n2n[sn_info[vi].parent]);
        if (sn_info[vi].parent as i64) < last_linked { break; }
    }
    var pi = vi;
    var plabel = sn_info[pi].label;
    loop {
        vi = sn_estack.pop() as i64;
        sn_info[vi].parent = sn_info[pi].parent;
        let vl = sn_info[vi].label;
        if plabel < vl { sn_info[vi].label = plabel; } else { plabel = vl; }
        pi = vi;
        if sn_estack.len == 0 { break; }
    }
    return sn_info[vi].label;
}

fn sn_run_semi_nca() {
    let next = sn_n2n.len;
    var idoms: i32[>..<] = [];
    var infos: i32[>..<] = [];
    for i in next { let k = sn_i(sn_n2n[i]); infos.push(k as i32); idoms.push(sn_info[k].parent); }
    var i = next - 1;
    while i > 0 {
        let w = infos[i] as i64;
        sn_info[w].semi = sn_info[w].parent;
        var rc = sn_info[w].rcs;
        while rc != 0 {
            let ep = sn_rc_par[rc - 1] as i64;
            rc = sn_rc_next[rc - 1];
            let su = sn_eval(ep, i + 1);
            if su < sn_info[w].semi { sn_info[w].semi = su; }
        }
        sn_info[w].label = sn_info[w].semi;
        i--;
    }
    for j in 1..next {
        let w = infos[j] as i64;
        var wid = idoms[j];
        while wid > sn_info[w].semi { wid = idoms[wid]; }
        idoms[j] = wid;
        sn_info[w].idom = sn_n2n[wid];
    }
}

fn sn_add_virtual_root() {
    let k = sn_i(DT_VROOT);
    sn_info[k].semi = 0;
    sn_info[k].label = 0;
    sn_info[k].dfs1 = 1;
    sn_n2n.push(DT_VROOT);
}

fn has_forward_successors(n: i32, bui: bool) -> bool {
    var ch: i32[>..<] = [];
    dt_children(n, false, bui, ch);
    return ch.len > 0;
}

// FindRoots(DT, BUI)
fn find_roots(bui: bool, roots: i32[>..<]&) {
    roots.clear();
    if !is_post() { roots.push(func_entry(cf)); return; }
    sn_clear(bui);
    sn_add_virtual_root();
    var num: i64 = 1;
    var total: i64 = 0;
    var b = func_first_block(cf);
    while b >= 0 {
        total++;
        if !has_forward_successors(b, bui) {
            roots.push(b);
            num = sn_run_dfs(b, num, 0, false, false) { x, y => true };
        }
        b = block_next(b);
    }
    var nontrivial = false;
    if total + 1 != num {
        nontrivial = true;
        var have_order = false;
        var ch: i32[>..<] = [];
        b = func_first_block(cf);
        while b >= 0 {
            if !sn_visited(b) {
                if !have_order {
                    // InitSuccOrderOnce
                    have_order = true;
                    sn_order_epoch++;
                    var y = func_first_block(cf);
                    while y >= 0 {
                        if !sn_visited(y) {
                            dt_children(y, false, sn_bui, ch);
                            for s in ch { sn_order_set(s, 0); }
                        }
                        y = block_next(y);
                    }
                    var nn: i32 = 0;
                    y = func_first_block(cf);
                    while y >= 0 {
                        nn++;
                        if sn_order_has(y) { sn_order_set(y, nn); }
                        y = block_next(y);
                    }
                }
                let newnum = sn_run_dfs(b, num, num, true, true) { x, y => true };
                let furthest = sn_n2n[newnum - 1];
                roots.push(furthest);
                var k = newnum;
                while k > num {
                    k--;
                    let ik = sn_i(sn_n2n[k]);
                    sn_info[ik] = SInfo { stamp: sn_epoch, dfs1: 0, parent: 0, semi: 0, label: 0, idom: -1, rcs: 0 };
                    sn_n2n.pop();
                }
                num = sn_run_dfs(furthest, num, 0, false, false) { x, y => true };
            }
            b = block_next(b);
        }
    }
    if nontrivial { remove_redundant_roots(bui, roots); }
}

// RemoveRedundantRoots
fn remove_redundant_roots(bui: bool, roots: i32[>..<]&) {
    sn_clear(bui);
    var i: i64 = 0;
    while i < roots.len {
        let r = roots[i];
        if !has_forward_successors(r, bui) { i++; continue; }
        sn_clear(bui);
        let num = sn_run_dfs(r, 0, 0, true, false) { x, y => true };
        var removed = false;
        for x in 1..num {
            if position(roots, sn_n2n[x]) >= 0 {
                roots[i] = roots[roots.len - 1];
                roots.pop();
                removed = true;
                break;
            }
        }
        if !removed { i++; }
    }
}

// getNodeForBlock(BB): create the tree nodes of BB's not-yet-created dominators (top first), then BB's.
fn sn_node_for_block(bb: i32) -> i32 {
    if t_has(bb) { return bb; }
    var chain: i32[>..<] = [];
    var x = bb;
    while !t_has(x) { chain.push(x); let k = sn_i(x); x = sn_info[k].idom; }
    var k = chain.len;
    while k > 0 { k--; t_create_node(chain[k], x); x = chain[k]; }
    return bb;
}

fn sn_attach_new_subtree(attach_to: i32) {
    let k0 = sn_i(sn_n2n[0]);
    sn_info[k0].idom = attach_to;
    for i in sn_n2n.len {
        let w = sn_n2n[i];
        if t_has(w) { continue; }
        let wk = sn_i(w);
        let imm = sn_info[wk].idom;
        let idn = sn_node_for_block(imm);
        t_create_node(w, idn);
    }
}

fn sn_reattach_existing_subtree(attach_to: i32) {
    let k0 = sn_i(sn_n2n[0]);
    sn_info[k0].idom = attach_to;
    for i in sn_n2n.len {
        let n = sn_n2n[i];
        let nk = sn_i(n);
        let nid = sn_info[nk].idom;
        t_set_idom(n, nid);
    }
}

// ---------------------------------------------------------------------------------------------
// CalculateFromScratch(DT, BUI). The PostViewCFG form of applyUpdates is not ported, so the walk always uses
// the real CFG; with a batch update in progress (bui) it only records that the tree was recalculated.

var bui_recalculated: bool = false;

fn calculate_from_scratch(bui: bool) {
    t_reset();
    // With a PostViewCFG the PreViewCFG becomes it and the walk uses that view; else the real CFG.
    let pbui = bui && gd_has_post;
    if pbui { gd_pre_is_post = true; }
    var roots: i32[>..<] = [];
    find_roots(pbui, roots);
    t_roots_set(roots);
    // doFullDFSWalk
    sn_clear(pbui);
    if !is_post() {
        sn_run_dfs(roots[0], 0, 0, false, false) { x, y => true };
    } else {
        sn_add_virtual_root();
        var num: i64 = 1;
        for r in roots { num = sn_run_dfs(r, num, 0, false, false) { x, y => true }; }
    }
    sn_run_semi_nca();
    if bui { bui_recalculated = true; }
    if roots.len == 0 { return; }
    let root = if is_post() { DT_VROOT } else { roots[0] };
    t_create_node(root, -1);
    dt_heads[hk0()].root = root;
    sn_attach_new_subtree(root);
}

// ---------------------------------------------------------------------------------------------
// Edge insertion

// UpdateRootsBeforeInsertion
fn update_roots_before_insertion(bui: bool, from: i32, to: i32) -> bool {
    if t_idom(to) != DT_VROOT { return false; }
    if !t_roots_contains(to) { return false; }
    calculate_from_scratch(bui);
    return true;
}

// UpdateRootsAfterUpdate
fn update_roots_after_update(bui: bool) {
    var any = false;
    for k in t_nroots() { if has_forward_successors(t_root_at(k), bui) { any = true; break; } }
    if !any { return; }
    var roots: i32[>..<] = [];
    find_roots(bui, roots);
    // isPermutation(DT.Roots, Roots)
    var perm = roots.len == t_nroots();
    if perm {
        for k in t_nroots() { if position(roots, t_root_at(k)) < 0 { perm = false; break; } }
        if perm { for r in roots { if !t_roots_contains(r) { perm = false; break; } } }
    }
    if !perm { calculate_from_scratch(bui); }
}

var dt_mark: i32[>..];          // InsertionInfo::Visited, by block index
var dt_mark_epoch: i32 = 0;
fn mark_insert(b: i32) -> bool {
    let k = block_of(b) as i64;
    while dt_mark.len <= k { dt_mark.push(0); }
    if dt_mark[k] == dt_mark_epoch { return false; }
    dt_mark[k] = dt_mark_epoch;
    return true;
}

// std::priority_queue<TreeNodePtr, SmallVector, Compare(level <)> as libstdc++ implements it.
fn heap_less(a: i32, b: i32) -> bool { t_level(a) < t_level(b) }
fn heap_sift_up(h: i32[>..<]&, hole0: i64, top: i64, v: i32) {
    var hole = hole0;
    var parent = (hole - 1) / 2;
    while hole > top && heap_less(h[parent], v) {
        h[hole] = h[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h[hole] = v;
}
fn bucket_push(h: i32[>..<]&, v: i32) {
    h.push(v);
    heap_sift_up(h, h.len - 1, 0, v);
}
fn bucket_pop(h: i32[>..<]&) -> i32 {
    let top = h[0];
    let len = h.len - 1;
    let v = h[len];
    h[len] = top;
    // __adjust_heap(first, 0, len, v)
    var hole: i64 = 0;
    var second: i64 = 0;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if heap_less(h[second], h[second - 1]) { second--; }
        h[hole] = h[second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        h[hole] = h[second - 1];
        hole = second - 1;
    }
    if len > 0 { heap_sift_up(h, hole, 0, v); }
    h.pop();
    return top;
}

// InsertReachable(DT, BUI, From, To): From may be DT_VROOT.
fn insert_reachable(bui: bool, from: i32, to: i32) {
    if is_post() && update_roots_before_insertion(bui, from, to) { return; }
    let ncd = if from != DT_VROOT && to != DT_VROOT { t_find_ncd(from, to) } else { DT_VROOT };
    let ncd_level = t_level(ncd);
    if ncd_level + 1 >= t_level(to) { return; }
    var bucket: i32[>..<] = [];
    var affected: i32[>..<] = [];
    var unaffected: i32[>..<] = [];
    var ch: i32[>..<] = [];
    dt_mark_epoch++;
    bucket_push(bucket, to);
    mark_insert(to);
    while bucket.len > 0 {
        var tn = bucket_pop(bucket);
        affected.push(tn);
        let cur_level = t_level(tn);
        loop {
            dt_children(tn, is_post(), bui, ch);
            for s in ch {
                if !t_has(s) { fatal("internal: unreachable successor found at reachable insertion"); }
                let sl = t_level(s);
                if sl <= ncd_level + 1 || !mark_insert(s) { continue; }
                if sl > cur_level { unaffected.push(s); } else { bucket_push(bucket, s); }
            }
            if unaffected.len == 0 { break; }
            tn = unaffected.pop();
        }
    }
    // UpdateInsertion
    for x in affected { t_set_idom(x, ncd); }
    if is_post() { update_roots_after_update(bui); }
}

// ComputeUnreachableDominators + InsertUnreachable
fn insert_unreachable(bui: bool, from: i32, to: i32) {
    var dfrom: i32[>..<] = [];
    var dto: i32[>..<] = [];
    sn_clear(bui);
    sn_run_dfs(to, 0, 0, false, false) { x, y =>
        if !t_has(y) { true } else { dfrom.push(x); dto.push(y); false }
    };
    sn_run_semi_nca();
    sn_attach_new_subtree(from);
    for k in dfrom.len { insert_reachable(bui, dfrom[k], dto[k]); }
}

// SemiNCAInfo::InsertEdge(DT, BUI, From, To), in the tree's direction (already swapped for post-dominators).
fn sn_insert_edge(bui: bool, from: i32, to: i32) {
    if !t_has(from) {
        if !is_post() { return; }
        t_create_node(from, DT_VROOT);
        t_roots_push(from);
    }
    t_invalidate_dfs();
    if !t_has(to) { insert_unreachable(bui, from, to); } else { insert_reachable(bui, from, to); }
}

// ---------------------------------------------------------------------------------------------
// Edge deletion

fn has_proper_support(bui: bool, tn: i32) -> bool {
    var ch: i32[>..<] = [];
    dt_children(tn, !is_post(), bui, ch);
    for p in ch {
        if !t_has(p) { continue; }
        if t_find_ncd(tn, p) != tn { return true; }
    }
    return false;
}

fn delete_reachable(bui: bool, from: i32, to: i32) {
    let to_idom = t_find_ncd(from, to);
    let prev = t_idom(to_idom);
    if prev == -1 { calculate_from_scratch(bui); return; }
    let level = t_level(to_idom);
    sn_clear(bui);
    sn_run_dfs(to_idom, 0, 0, false, false) { x, y => t_level(y) > level };
    sn_run_semi_nca();
    sn_reattach_existing_subtree(prev);
}

fn delete_unreachable(bui: bool, to: i32) {
    if is_post() {
        t_roots_push(to);
        insert_reachable(bui, DT_VROOT, to);
        return;
    }
    var affected: i32[>..<] = [];
    let level = t_level(to);
    sn_clear(bui);
    let last = sn_run_dfs(to, 0, 0, false, false) { x, y =>
        if t_level(y) > level { true } else { if position(affected, y) < 0 { affected.push(y); } false }
    };
    var min = to;
    for n in affected {
        let ncd = t_find_ncd(n, to);
        if ncd != n && t_level(ncd) < t_level(min) { min = ncd; }
    }
    if t_idom(min) == -1 { calculate_from_scratch(bui); return; }
    var i = last;
    while i > 0 { i--; t_erase_node(sn_n2n[i]); }
    if min == to { return; }
    let min_level = t_level(min);
    let prev = t_idom(min);
    sn_clear(bui);
    sn_run_dfs(min, 0, 0, false, false) { r, y =>
        if t_has(y) { t_level(y) > min_level } else { t_create_node(y, r); true }
    };
    sn_run_semi_nca();
    sn_reattach_existing_subtree(prev);
}

fn sn_delete_edge(bui: bool, from: i32, to: i32) {
    if !t_has(from) { return; }
    if !t_has(to) { return; }
    let ncd = t_find_ncd(from, to);
    if to != ncd {
        t_invalidate_dfs();
        let to_idom = t_idom(to);
        if from != to_idom || has_proper_support(bui, to) { delete_reachable(bui, from, to); }
        else { delete_unreachable(bui, to); }
    }
    if is_post() { update_roots_after_update(bui); }
}

// ---------------------------------------------------------------------------------------------
// Public API. Blocks are value ids; trees are (function, DT_DOM | DT_POST).

// Ensure the tree is computed (DominatorTreeAnalysis / PostDominatorTreeAnalysis).
fn dt_get(fv: i32, t: i64) {
    dt_grow();
    if !dt_valid(fv, t) { dt_focus(fv, t); calculate_from_scratch(false); }
}
// DominatorTreeBase::recalculate
fn dt_recalculate(fv: i32, t: i64) { dt_focus(fv, t); calculate_from_scratch(false); }

// Is bv in the tree (reachable, for dominators)? DT.getNode(BB) != nullptr.
fn dt_has_node(t: i64, bv: i32) -> bool { dt_focus(block_func(bv), t); return t_has(bv); }
// Immediate dominator: a block, DT_VROOT (post-dominator virtual root) or -1 (root / not in tree).
fn dt_idom(t: i64, bv: i32) -> i32 { if dt_has_node(t, bv) { dt_nodes[dt_node_idx(bv, t)].idom } else { -1 } }
fn dt_level(t: i64, bv: i32) -> i32 { dt_nodes[dt_node_idx(bv, t)].level }
fn dt_root(fv: i32, t: i64) -> i32 { dt_heads[dt_head_idx(fv, t)].root }
fn dt_nroots(fv: i32, t: i64) -> i64 { dt_heads[dt_head_idx(fv, t)].nroots as i64 }
fn dt_root_at(fv: i32, t: i64, k: i64) -> i32 { dt_roots_pool[dt_heads[dt_head_idx(fv, t)].roots_at + k] }
// Children of a node in order; n may be DT_VROOT (then fv names the function).
fn dt_first_child(fv: i32, t: i64, n: i32) -> i32 {
    if n == DT_VROOT { return dt_heads[dt_head_idx(fv, t)].vfirst; }
    return dt_nodes[dt_node_idx(n, t)].first;
}
fn dt_next_sibling(t: i64, n: i32) -> i32 { dt_nodes[dt_node_idx(n, t)].next }
fn dt_dfs_valid(fv: i32, t: i64) -> bool { dt_heads[dt_head_idx(fv, t)].dfs_valid }
fn dt_slow_queries(fv: i32, t: i64) -> i64 { dt_heads[dt_head_idx(fv, t)].slow as i64 }
fn dt_dfs_in(fv: i32, t: i64, n: i32) -> u32 { dt_focus(fv, t); return t_dfs_in(n); }
fn dt_dfs_out(fv: i32, t: i64, n: i32) -> u32 { dt_focus(fv, t); return t_dfs_out(n); }
fn dt_update_dfs_numbers(fv: i32, t: i64) { dt_focus(fv, t); t_update_dfs_numbers(); }

// DominatorTree::dominates(A, B) for blocks: true if A dominates B (reflexive). Unreachable B: true
// (LLVM: "an unreachable block is dominated by anything"); unreachable A: false. Counts slow queries and
// switches to DFS numbers after 32 of them, as LLVM does (visible in print<domtree>).
fn dt_dominates_block(t: i64, a: i32, b: i32) -> bool {
    if a == b { return true; }
    dt_focus(block_func(a), t);
    return t_dominates_nodes(t_node(a), t_node(b));
}
fn dt_properly_dominates_block(t: i64, a: i32, b: i32) -> bool {
    if a == b { return false; }
    dt_focus(block_func(a), t);
    return t_dominates_nodes(t_node(a), t_node(b));
}
// dominates(DomTreeNode *A, DomTreeNode *B) on node handles: a block in the tree, DT_VROOT, or -1 (null).
fn dt_dominates_nodes(fv: i32, t: i64, a: i32, b: i32) -> bool { dt_focus(fv, t); return t_dominates_nodes(a, b); }
// DominatorTree::dominates(const Instruction *Def, const BasicBlock *UseBB)
fn dt_inst_dominates_block(def: i32, ubb: i32) -> bool {
    let dbb = inst_parent(def);
    if !dt_has_node(DT_DOM, ubb) { return true; }
    if !dt_has_node(DT_DOM, dbb) { return false; }
    if dbb == ubb { return false; }
    let o = iop(def);
    // invoke / callbr results are only usable in the normal (default) destination
    if o == OP_INVOKE { return dt_edge_dominates_block(dbb, op(def, nops(def) - 3), ubb); }
    if o == OP_CALLBR { return dt_edge_dominates_block(dbb, op(def, nops(def) - 2 - dt_callbr_nindirect(def)), ubb); }
    return dt_dominates_block(DT_DOM, dbb, ubb);
}
fn dt_callbr_nindirect(t: i32) -> i64 {
    let x = insts[inst_of(t)];
    if x.naux == 0 { return 0; }
    return ints[x.aux + 1] as i64;
}
// DominatorTree::dominates(const BasicBlockEdge &BBE, const BasicBlock *UseBB)
fn dt_edge_dominates_block(start: i32, end: i32, ubb: i32) -> bool {
    if !dt_dominates_block(DT_DOM, end, ubb) { return false; }
    if single_pred(end) >= 0 { return true; }
    var dup = 0;
    var u = vals[end].first_use;
    while u >= 0 {
        let user = uses[u].user;
        u = uses[u].next;
        if vals[user].kind != VK_INST || !is_terminator_op(iop(user)) { continue; }
        let p = insts[inst_of(user)].parent;
        if p == start {
            if dup > 0 { return false; }
            dup++;
            continue;
        }
        if !dt_dominates_block(DT_DOM, end, p) { return false; }
    }
    return true;
}
// DominatorTree::dominates(const Value *Def, const Instruction *User)
fn dt_value_dominates_inst(defv: i32, user: i32) -> bool {
    if !is_inst(defv) { return true; }
    let ubb = inst_parent(user);
    let dbb = inst_parent(defv);
    if !dt_has_node(DT_DOM, ubb) { return true; }
    if !dt_has_node(DT_DOM, dbb) { return false; }
    if defv == user { return false; }
    let o = iop(defv);
    if o == OP_INVOKE || o == OP_CALLBR || iop(user) == OP_PHI { return dt_inst_dominates_block(defv, ubb); }
    if dbb != ubb { return dt_dominates_block(DT_DOM, dbb, ubb); }
    // Def->comesBefore(User)
    var i = inst_next(defv);
    while i >= 0 { if i == user { return true; } i = inst_next(i); }
    return false;
}
// findNearestCommonDominator(A, B); both must be in the tree. May return DT_VROOT for post-dominators.
fn dt_find_ncd(t: i64, a: i32, b: i32) -> i32 { dt_focus(block_func(a), t); return t_find_ncd(a, b); }

// DomTreeBuilder::ApplyUpdates(DT, PreViewCFG = instance 0, PostViewCFG = instance 1 if gd_has_post)
fn dt_apply_gd_updates() {
    let n = gd_num_updates();
    if n == 0 { return; }
    if n == 1 {
        let u = gd_pop_update();
        if !gd_has_post {
            if u.kind == DT_INSERT { sn_insert_edge(false, u.from, u.to); } else { sn_delete_edge(false, u.from, u.to); }
        } else {
            // BatchUpdateInfo BUI(*PostViewCFG, PostViewCFG)
            gd_pre_is_post = true;
            bui_recalculated = false;
            if u.kind == DT_INSERT { sn_insert_edge(true, u.from, u.to); } else { sn_delete_edge(true, u.from, u.to); }
        }
        return;
    }
    bui_recalculated = false;
    let size = dt_heads[hk0()].nodes_size as i64;
    if size <= 100 {
        if n > size { calculate_from_scratch(true); }
    } else if n > size / 40 {
        calculate_from_scratch(true);
    }
    var i: i64 = 0;
    while i < n && !bui_recalculated {
        let u = gd_pop_update();
        if u.kind == DT_INSERT { sn_insert_edge(true, u.from, u.to); } else { sn_delete_edge(true, u.from, u.to); }
        i++;
    }
}

// DominatorTreeBase::applyUpdates(Updates): the CFG already reflects the updates.
fn dt_apply_updates(fv: i32, t: i64, ups: const DTUpdate[:]) {
    dt_focus(fv, t);
    gd_items.clear();     // no GraphDiff outlives a DT update (a client's instance 2 must be dead by now)
    gd_has_post = false;
    gd_init(0, ups, t == DT_POST, true);
    dt_apply_gd_updates();
}

// DominatorTreeBase::applyUpdates(Updates, PostViewUpdates): the DT is updated assuming the CFG after the
// PostViewUpdates is the end state.
fn dt_apply_updates_post_view(fv: i32, t: i64, ups: const DTUpdate[:], post: const DTUpdate[:]) {
    dt_focus(fv, t);
    gd_items.clear();
    gd_has_post = true;
    gd_init(1, post, t == DT_POST, false);
    if ups.len == 0 {
        gd_pre_is_post = true;
        gd_upds.clear();
    } else {
        var all: DTUpdate[>..<] = [];
        for u in ups { all.push(u); }
        for u in post { all.push(u); }
        gd_init(0, all, t == DT_POST, true);
    }
    dt_apply_gd_updates();
    gd_has_post = false;
    gd_pre_is_post = false;
}

// DominatorTreeBase::insertEdge / deleteEdge (DomTreeBuilder::InsertEdge/DeleteEdge swap for post-dominators).
fn dt_insert_edge(fv: i32, t: i64, from: i32, to: i32) {
    dt_focus(fv, t);
    if t == DT_POST { sn_insert_edge(false, to, from); } else { sn_insert_edge(false, from, to); }
}
fn dt_delete_edge(fv: i32, t: i64, from: i32, to: i32) {
    dt_focus(fv, t);
    if t == DT_POST { sn_delete_edge(false, to, from); } else { sn_delete_edge(false, from, to); }
}

// addNewBlock(BB, DomBB)
fn dt_add_new_block(fv: i32, t: i64, bb: i32, dom: i32) {
    dt_focus(fv, t);
    if t_has(bb) { fatal("internal: block already in dominator tree"); }
    t_invalidate_dfs();
    t_create_node(bb, dom);
}
// changeImmediateDominator(BB, NewBB)
fn dt_change_idom(fv: i32, t: i64, bb: i32, nidom: i32) {
    dt_focus(fv, t);
    t_invalidate_dfs();
    t_set_idom(bb, nidom);
}
// eraseNode(BB)
fn dt_erase_node(fv: i32, t: i64, bb: i32) { dt_focus(fv, t); t_erase_node(bb); }

// splitBlock(NewBB): NewBB was split off and has one successor (Split<NodeT*> / Split<Inverse<NodeT*>>).
fn dt_split_block(fv: i32, t: i64, nbb: i32) {
    dt_focus(fv, t);
    var preds: i32[>..<] = [];
    var succ: i32 = -1;
    // children<N>(NewBB) and inverse_children<N>(...), N = NodeT* or Inverse<NodeT*>
    fn fwd(b: i32, out: i32[>..<]&) {
        out.clear();
        if t == DT_POST { each_pred(b) { p => out.push(p); }; }
        else { let tm = block_terminator(b); for k in term_nsucc(tm) { out.push(term_succ(tm, k)); } }
    }
    fn bwd(b: i32, out: i32[>..<]&) {
        out.clear();
        if t == DT_POST { let tm = block_terminator(b); for k in term_nsucc(tm) { out.push(term_succ(tm, k)); } }
        else { each_pred(b) { p => out.push(p); }; }
    }
    var tmp: i32[>..<] = [];
    fwd(nbb, tmp);
    succ = tmp[0];
    bwd(nbb, preds);
    var dominates_succ = true;
    bwd(succ, tmp);
    for p in tmp {
        if p != nbb && !t_dominates_nodes(t_node(succ), t_node(p)) && t_has(p) { dominates_succ = false; break; }
    }
    var nidom: i32 = -1;
    var i: i64 = 0;
    while i < preds.len { if t_has(preds[i]) { nidom = preds[i]; break; } i++; }
    if nidom == -1 { return; }
    i++;
    while i < preds.len { if t_has(preds[i]) { nidom = t_find_ncd(nidom, preds[i]); } i++; }
    t_invalidate_dfs();
    t_create_node(nbb, nidom);
    if dominates_succ { t_invalidate_dfs(); t_set_idom(succ, nbb); }
}

// Every block of the tree in pre-order (depth_first over the tree).
fn dt_each_preorder<F>(fv: i32, t: i64) {
    var stack: i32[>..<] = [];
    let r = dt_root(fv, t);
    if r == -1 { return; }
    stack.push(r);
    while stack.len > 0 {
        let n = stack.pop();
        if n != DT_VROOT { F(n); }
        // push children reversed so they pop in order
        let mark = stack.len;
        var c = dt_first_child(fv, t, n);
        while c >= 0 { stack.push(c); c = dt_next_sibling(t, c); }
        reverse(stack[mark..]);
    }
}
