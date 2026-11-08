// Dominator and post-dominator trees.
// Port of llvm/include/llvm/Support/GenericDomTreeConstruction.h (SemiNCAInfo: runDFS, runSemiNCA, FindRoots,
// RemoveRedundantRoots, CalculateFromScratch, attachNewSubtree) and the printing parts of GenericDomTree.h.
// The tree's child order is LLVM's: nodes are created in DFS-number order and appended to their idom's
// children, and the DFS visits successors in order (reversed onto a LIFO worklist) and predecessors in
// reverse use-list order, exactly as LLVM does. Incremental updates (InsertEdge/DeleteEdge) are not ported
// yet: a pass that changes the CFG invalidates the trees and they are recomputed (see DESIGN.md §8.5).
import std;
import ir;
import irutil;

let DT_DOM = 0;
let DT_POST = 1;
let DT_VROOT: i32 = -2;      // the post-dominator tree's virtual exit node (LLVM's nullptr block)

// One record per (block index, tree kind): index = block index * 2 + kind. Valid iff epoch matches the tree's.
struct DTNode { epoch: i32, idom: i32, first: i32, last: i32, next: i32, prev: i32, level: i32 }
// One record per (function glob index, tree kind).
struct DTHead { epoch: i32, valid: bool, root: i32, vfirst: i32, vlast: i32, roots_at: i32, nroots: i32 }

var dt_nodes: DTNode[>..];
var dt_heads: DTHead[>..];
var dt_roots_pool: i32[>..];
var dt_next_epoch: i32 = 1;

fn dt_head_idx(fv: i32, t: i64) -> i64 {
    let k = (glob_of(fv) as i64) * 2 + t;
    while dt_heads.len <= k { dt_heads.push(DTHead { epoch: 0, valid: false, root: -1, vfirst: -1, vlast: -1, roots_at: 0, nroots: 0 }); }
    return k;
}
fn dt_node_idx(bv: i32, t: i64) -> i64 {
    let k = (block_of(bv) as i64) * 2 + t;
    while dt_nodes.len <= k { dt_nodes.push(DTNode { epoch: 0, idom: -1, first: -1, last: -1, next: -1, prev: -1, level: 0 }); }
    return k;
}

fn dt_valid(fv: i32, t: i64) -> bool { dt_heads[dt_head_idx(fv, t)].valid }
fn dt_invalidate(fv: i32, t: i64) { dt_heads[dt_head_idx(fv, t)].valid = false; }

// Is bv in the tree (reachable, for dominators)? DT.getNode(BB) != nullptr.
fn dt_has_node(t: i64, bv: i32) -> bool {
    let f = block_func(bv);
    let e = dt_heads[dt_head_idx(f, t)].epoch;
    return dt_nodes[dt_node_idx(bv, t)].epoch == e;
}
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

// DominatorTree::dominates(A, B) for blocks: true if A dominates B (reflexive). Unreachable B: true
// (LLVM: "an unreachable block is dominated by anything"); unreachable A: false.
fn dt_dominates_block(t: i64, a: i32, b: i32) -> bool {
    if a == b { return true; }
    if !dt_has_node(t, b) { return true; }
    if !dt_has_node(t, a) { return false; }
    let la = dt_level(t, a);
    var x = b;
    while x >= 0 && dt_level(t, x) > la { x = dt_nodes[dt_node_idx(x, t)].idom; }
    return x == a;
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

// ---------------------------------------------------------------------------------------------
// Construction (SemiNCAInfo::CalculateFromScratch)

var dt_bnum: i32[>..];      // block index -> local number in the function being computed

fn dt_compute(fv: i32, t: i64) {
    let post = t == DT_POST;
    // Number the blocks (BasicBlock::getNumber) and build the CFG in local numbers + 1 (0 = virtual root).
    var blk: i32[>..<] = [];
    blk.push(-1);
    var b = func_first_block(fv);
    while b >= 0 {
        let bi = block_of(b) as i64;
        while dt_bnum.len <= bi { dt_bnum.push(-1); }
        dt_bnum[bi] = blk.len as i32;
        blk.push(b);
        b = block_next(b);
    }
    let n = blk.len;      // nodes 1..n-1 are blocks
    var soff: i32[>..<] = [];
    var sl: i32[>..<] = [];
    var poff: i32[>..<] = [];
    var pl: i32[>..<] = [];
    soff.push(0); poff.push(0);
    soff.push(0); poff.push(0);
    for i in 1..n {
        let bv = blk[i];
        let tm = block_terminator(bv);
        if tm >= 0 { for k in term_nsucc(tm) { sl.push(dt_bnum[block_of(term_succ(tm, k))]); } }
        soff.push(sl.len as i32);
        each_pred(bv) { p => pl.push(dt_bnum[block_of(p)]); };
        poff.push(pl.len as i32);
    }
    fn nsucc(x: i64) -> i64 { (soff[x + 1] - soff[x]) as i64 }

    // SemiNCAInfo state
    var dfs1: i32[>..<] = [];
    var par: i32[>..<] = [];
    var semi: i32[>..<] = [];
    var label: i32[>..<] = [];
    var idom: i32[>..<] = [];      // node (local number), -1 = none
    var rcs: i32[>..<] = [];
    var n2n: i32[>..<] = [];
    var rc_par: i32[>..<] = [];
    var rc_next: i32[>..<] = [];
    fn clear() {
        dfs1.clear(); par.clear(); semi.clear(); label.clear(); idom.clear(); rcs.clear();
        dfs1.resize(n, 0); par.resize(n, 0); semi.resize(n, 0); label.resize(n, 0); idom.resize(n, -1); rcs.resize(n, 0);
        n2n.clear(); rc_par.clear(); rc_next.clear();
    }
    fn reset_info(x: i64) { dfs1[x] = 0; par[x] = 0; semi[x] = 0; label[x] = 0; idom[x] = -1; rcs[x] = 0; }
    var succ_order: i32[>..<] = [];   // node -> order (0 = none)
    var wl_node: i32[>..<] = [];
    var wl_par: i32[>..<] = [];
    var tmp: i32[>..<] = [];

    // runDFS(V, LastNum, AlwaysDescend, AttachToNum, SuccOrder); use_succ: walk successors (else predecessors).
    fn run_dfs(v: i64, last0: i64, attach: i64, use_succ: bool, with_order: bool) -> i64 {
        var last = last0;
        wl_node.clear(); wl_par.clear();
        wl_node.push(v as i32); wl_par.push(attach as i32);
        par[v] = attach as i32;
        while wl_node.len > 0 {
            let bb = wl_node.pop() as i64;
            let pn = wl_par.pop();
            rc_par.push(pn);
            rc_next.push(rcs[bb]);
            rcs[bb] = rc_par.len as i32;
            if dfs1[bb] != 0 { continue; }
            par[bb] = pn;
            let num = last;
            last++;
            semi[bb] = num as i32;
            label[bb] = num as i32;
            dfs1[bb] = (num + 1) as i32;
            n2n.push(bb as i32);
            if use_succ {
                // reverse_if<true>(successors)
                tmp.clear();
                var k = soff[bb + 1] as i64;
                while k > soff[bb] as i64 { k--; tmp.push(sl[k]); }
                if with_order && tmp.len > 1 { sort(tmp) { a, c => succ_order[a] < succ_order[c] }; }
                for s in tmp { wl_node.push(s); wl_par.push(num as i32); }
            } else {
                for k in poff[bb]..poff[bb + 1] { wl_node.push(pl[k]); wl_par.push(num as i32); }
            }
        }
        return last;
    }

    // eval(V, LastLinked) with path compression; NumToInfo[x] is the node n2n[x].
    var estack: i32[>..<] = [];
    fn eval(v: i64, last_linked: i64) -> i32 {
        var vi = n2n[v] as i64;
        if par[vi] as i64 < last_linked { return label[vi]; }
        loop {
            estack.push(vi as i32);
            vi = n2n[par[vi]] as i64;
            if (par[vi] as i64) < last_linked { break; }
        }
        var pi = vi;
        var plabel = label[pi];
        loop {
            vi = estack.pop() as i64;
            par[vi] = par[pi];
            let vl = label[vi];
            if plabel < vl { label[vi] = plabel; } else { plabel = vl; }
            pi = vi;
            if estack.len == 0 { break; }
        }
        return label[vi];
    }

    fn run_semi_nca() {
        let next = n2n.len;
        var idoms: i32[>..<] = [];
        for i in next { idoms.push(par[n2n[i]]); }
        var i = next - 1;
        while i > 0 {
            let w = n2n[i] as i64;
            semi[w] = par[w];
            var rc = rcs[w];
            while rc != 0 {
                let ep = rc_par[rc - 1] as i64;
                rc = rc_next[rc - 1];
                let su = eval(ep, i + 1);
                if su < semi[w] { semi[w] = su; }
            }
            label[w] = semi[w];
            i--;
        }
        for j in 1..next {
            let w = n2n[j] as i64;
            var wid = idoms[j];
            while wid > semi[w] { wid = idoms[wid]; }
            idoms[j] = wid;
            idom[w] = n2n[wid];
        }
    }

    var roots: i32[>..<] = [];
    clear();
    if !post {
        roots.push(1);
        run_dfs(1, 0, 0, true, false);
    } else {
        // FindRoots
        dfs1[0] = 1;
        n2n.push(0);
        var num: i64 = 1;
        var total: i64 = 0;
        for x in 1..n {
            total++;
            if nsucc(x) == 0 {
                roots.push(x as i32);
                num = run_dfs(x, num, 0, false, false);
            }
        }
        var nontrivial = false;
        if total + 1 != num {
            nontrivial = true;
            var have_order = false;
            for x in 1..n {
                if dfs1[x] != 0 { continue; }
                if !have_order {
                    have_order = true;
                    succ_order.resize(n, 0);
                    var mark: bool[>..<] = [];
                    mark.resize(n, false);
                    for y in 1..n {
                        if dfs1[y] == 0 { for k in soff[y]..soff[y + 1] { mark[sl[k]] = true; } }
                    }
                    for y in 1..n { if mark[y] { succ_order[y] = y as i32; } }
                }
                let newnum = run_dfs(x, num, num, true, true);
                let furthest = n2n[newnum - 1];
                roots.push(furthest);
                var k = newnum;
                while k > num { k--; reset_info(n2n[k] as i64); n2n.pop(); }
                num = run_dfs(furthest as i64, num, 0, false, false);
            }
        }
        if nontrivial {
            // RemoveRedundantRoots
            var i: i64 = 0;
            while i < roots.len {
                let r = roots[i] as i64;
                if nsucc(r) == 0 { i++; continue; }
                clear();
                let cnt = run_dfs(r, 0, 0, true, false);
                var removed = false;
                for x in 1..cnt {
                    let nd = n2n[x];
                    if position(roots, nd) >= 0 {
                        roots[i] = roots[roots.len - 1];
                        roots.pop();
                        removed = true;
                        break;
                    }
                }
                if !removed { i++; }
            }
        }
        // doFullDFSWalk
        clear();
        dfs1[0] = 1;
        n2n.push(0);
        var nm: i64 = 1;
        for r in roots { nm = run_dfs(r as i64, nm, 0, false, false); }
    }
    run_semi_nca();

    // Build the tree (CalculateFromScratch: createNode(Root) + attachNewSubtree).
    let epoch = dt_next_epoch;
    dt_next_epoch++;
    let hk = dt_head_idx(fv, t);
    dt_heads[hk].epoch = epoch;
    dt_heads[hk].valid = true;
    dt_heads[hk].vfirst = -1;
    dt_heads[hk].vlast = -1;
    dt_heads[hk].roots_at = dt_roots_pool.len as i32;
    dt_heads[hk].nroots = roots.len as i32;
    for r in roots { dt_roots_pool.push(blk[r]); }
    if roots.len == 0 { dt_heads[hk].root = -1; return; }
    fn make_node(x: i64, parent_node: i32, lvl: i32) {
        let bv = blk[x];
        let k = dt_node_idx(bv, t);
        dt_nodes[k] = DTNode { epoch: epoch, idom: parent_node, first: -1, last: -1, next: -1, prev: -1, level: lvl };
        if parent_node == DT_VROOT {
            let last = dt_heads[hk].vlast;
            dt_nodes[k].prev = last;
            if last >= 0 { dt_nodes[dt_node_idx(last, t)].next = bv; } else { dt_heads[hk].vfirst = bv; }
            dt_heads[hk].vlast = bv;
        } else if parent_node >= 0 {
            let pk = dt_node_idx(parent_node, t);
            let last = dt_nodes[pk].last;
            dt_nodes[k].prev = last;
            if last >= 0 { dt_nodes[dt_node_idx(last, t)].next = bv; } else { dt_nodes[pk].first = bv; }
            dt_nodes[pk].last = bv;
        }
    }
    var lvl: i32[>..<] = [];
    lvl.resize(n, 0);
    if post {
        dt_heads[hk].root = DT_VROOT;
        for x in 1..n2n.len {
            let w = n2n[x] as i64;
            let d = idom[w] as i64;
            lvl[w] = lvl[d] + 1;
            make_node(w, if d == 0 { DT_VROOT } else { blk[d] }, lvl[w]);
        }
    } else {
        dt_heads[hk].root = blk[1];
        make_node(1, -1, 0);
        for x in 1..n2n.len {
            let w = n2n[x] as i64;
            let d = idom[w] as i64;
            lvl[w] = lvl[d] + 1;
            make_node(w, blk[d], lvl[w]);
        }
    }
}

// Ensure the tree is computed (DominatorTreeAnalysis / PostDominatorTreeAnalysis).
fn dt_get(fv: i32, t: i64) {
    if !dt_valid(fv, t) { dt_compute(fv, t); }
}
