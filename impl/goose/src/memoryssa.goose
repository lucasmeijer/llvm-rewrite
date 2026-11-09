// MemorySSA: port of llvm/lib/Analysis/MemorySSA.cpp (buildMemorySSA, createNewAccess, placePHINodes with the
// forward IDF, renamePass, markUnreachableAsLiveOnEntry, OptimizeUses, ClobberWalker with tryOptimizePhi,
// CachingWalker::getClobberingMemoryAccess, MemorySSA::dominates/locallyDominates, the access printers and the
// print<memoryssa> / print<memoryssa-walker> passes) and the upward_defs_iterator of MemorySSA.h (with
// PHITransAddr, phitrans.goose).
//
// Data layout: memory accesses are ids into macc (LiveOnEntry is access 0). Per-block access lists and defs
// lists are intrusive (prev/next, dprev/dnext); block and instruction -> access maps are value-id indexed with
// a build epoch, so building for another function never clears memory. MemoryPhi operands are runs in
// mphi_v/mphi_b (copied to a bigger run when full). One MemorySSA at a time (the function in mssa_fn).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import domtree;
import pm;
import vt;
import printer;
import flags;
import memloc;
import aautil;
import aa;
import phitrans;

let MAK_LIVE: u8 = 0;
let MAK_DEF: u8 = 1;
let MAK_USE: u8 = 2;
let MAK_PHI: u8 = 3;
let MSSA_INVALID_ID: i32 = -1;

// def/opt cache the values of operand 0 (defining access) and operand 1 (MemoryDef's optimized access); the
// operands themselves are uses (u0, u1) in muses with intrusive use lists exactly like IR Use::set (a new use
// goes to the head of the value's list), so iterating the users of an access matches LLVM's order.
struct MAcc { kind: u8, id: i32, inst: i32, bb: i32, def: i32, opt: i32, opt_id: i32,
              prev: i32, next: i32, dprev: i32, dnext: i32, pat: i32, pn: i32, pcap: i32, num: i32,
              u0: i32, u1: i32, first_use: i32, vh: i32 }
var macc: MAcc[>..<];
var mphi_v: i32[>..<];
var mphi_b: i32[>..<];
var mphi_u: i32[>..<];

// Uses of memory accesses: slot 0/1 = operand 0/1 of a MemoryUse/Def, k >= 0 for a MemoryPhi's operand k (-1 = none)
struct MUse { val: i32, user: i32, next: i32, prev: i32, slot: i32 }
var muses: MUse[>..<];

fn mu_new(user: i32, slot: i32) -> i32 {
    let u = muses.len as i32;
    muses.push(MUse { val: -1, user: user, next: -1, prev: -1, slot: slot });
    return u;
}
fn mu_unlink(u: i32) {
    let v = muses[u].val;
    if v < 0 { return; }
    let p = muses[u].prev;
    let n = muses[u].next;
    if p >= 0 { muses[p].next = n; } else { macc[v].first_use = n; }
    if n >= 0 { muses[n].prev = p; }
    muses[u].val = -1;
    muses[u].next = -1;
    muses[u].prev = -1;
}
// Use::set
fn mu_set(u: i32, v: i32) {
    mu_unlink(u);
    muses[u].val = v;
    if v < 0 { return; }
    let h = macc[v].first_use;
    muses[u].next = h;
    muses[u].prev = -1;
    if h >= 0 { muses[h].prev = u; }
    macc[v].first_use = u;
}
// users of an access, in use-list order
fn mssa_first_use(a: i32) -> i32 { macc[a].first_use }
fn mssa_use_next(u: i32) -> i32 { muses[u].next }
fn mssa_use_user(u: i32) -> i32 { muses[u].user }
fn mssa_use_slot(u: i32) -> i32 { muses[u].slot }

struct MBlk { first: i32, last: i32, dfirst: i32, dlast: i32, numvalid: bool }
var mb_stamp: i32[>..];
var mb: MBlk[>..];
var mv_stamp: i32[>..];
var mv_acc: i32[>..];
var mssa_epoch: i32 = 0;
var mssa_fn: i32 = -1;
var mssa_next_id: i32 = 0;
var mssa_optimized: bool = false;

fn mssa_valid(fv: i32) -> bool { mssa_fn == fv && fv >= 0 }
fn mssa_invalidate(fv: i32) { if mssa_fn == fv { mssa_fn = -1; } }
fn mssa_invalidate_all() { mssa_fn = -1; }

fn mssa_max_check_limit() -> i64 { flag_int("memssa-check-limit", 100) }

// ---------------------------------------------------------------------------------------------
// Maps

fn mb_ensure(bv: i32) {
    let n = (bv as i64) + 1;
    while mb_stamp.len < n { mb_stamp.push(0); mb.push(MBlk { first: -1, last: -1, dfirst: -1, dlast: -1, numvalid: false }); }
    if mb_stamp[bv] != mssa_epoch {
        mb_stamp[bv] = mssa_epoch;
        mb[bv] = MBlk { first: -1, last: -1, dfirst: -1, dlast: -1, numvalid: false };
    }
}
fn mb_first(bv: i32) -> i32 { if (bv as i64) < mb_stamp.len && mb_stamp[bv] == mssa_epoch { mb[bv].first } else { -1 } }
fn mb_last(bv: i32) -> i32 { if (bv as i64) < mb_stamp.len && mb_stamp[bv] == mssa_epoch { mb[bv].last } else { -1 } }
fn mb_dlast(bv: i32) -> i32 { if (bv as i64) < mb_stamp.len && mb_stamp[bv] == mssa_epoch { mb[bv].dlast } else { -1 } }

// MemorySSA::getMemoryAccess(I or BB): -1 if none
fn mssa_access_of(v: i32) -> i32 {
    if (v as i64) < mv_stamp.len && mv_stamp[v] == mssa_epoch { return mv_acc[v]; }
    return -1;
}
fn mv_set(v: i32, a: i32) {
    let n = (v as i64) + 1;
    while mv_stamp.len < n { mv_stamp.push(0); mv_acc.push(-1); }
    mv_stamp[v] = mssa_epoch;
    mv_acc[v] = a;
}

fn ma_new(kind: u8, inst: i32, bb0: i32) -> i32 {
    let a = macc.len as i32;
    macc.push(MAcc { kind: kind, id: 0, inst: inst, bb: bb0, def: -1, opt: -1, opt_id: MSSA_INVALID_ID,
                     prev: -1, next: -1, dprev: -1, dnext: -1, pat: 0, pn: 0, pcap: 0, num: 0,
                     u0: -1, u1: -1, first_use: -1, vh: -1 });
    if kind != MAK_PHI {
        macc[a].u0 = mu_new(a, 0);
        if kind != MAK_USE { macc[a].u1 = mu_new(a, 1); }
    }
    return a;
}

fn ma_is_def(a: i32) -> bool { let k = macc[a].kind; k == MAK_DEF || k == MAK_LIVE }
fn ma_is_use_or_def(a: i32) -> bool { let k = macc[a].kind; k != MAK_PHI }
fn mssa_live() -> i32 { 0 }
fn mssa_is_live(a: i32) -> bool { a == 0 }

// MemoryUseOrDef::getDefiningAccess
fn ma_def(a: i32) -> i32 { macc[a].def }
// setDefiningAccess(DMA, Optimized = false)
fn ma_set_def(a: i32, d: i32) { macc[a].def = d; mu_set(macc[a].u0, d); }
// setOptimized
fn ma_set_optimized(a: i32, d: i32) {
    if macc[a].kind == MAK_USE { macc[a].opt_id = macc[d].id; macc[a].def = d; mu_set(macc[a].u0, d); }
    else { macc[a].opt = d; mu_set(macc[a].u1, d); macc[a].opt_id = macc[d].id; }
}
fn ma_is_optimized(a: i32) -> bool {
    if macc[a].kind == MAK_USE { let d = macc[a].def; return d >= 0 && macc[a].opt_id == macc[d].id; }
    let o = macc[a].opt;
    return o >= 0 && macc[a].opt_id == macc[o].id;
}
fn ma_get_optimized(a: i32) -> i32 { if macc[a].kind == MAK_USE { macc[a].def } else { macc[a].opt } }
fn ma_reset_optimized(a: i32) {
    macc[a].opt_id = MSSA_INVALID_ID;
    if macc[a].kind != MAK_USE { macc[a].opt = -1; mu_set(macc[a].u1, -1); }
}

// MemoryPhi operands
fn mphi_n(p: i32) -> i64 { macc[p].pn as i64 }
fn mphi_val(p: i32, k: i64) -> i32 { mphi_v[(macc[p].pat as i64) + k] }
fn mphi_blk(p: i32, k: i64) -> i32 { mphi_b[(macc[p].pat as i64) + k] }
// MemoryPhi::setIncomingValue / setIncomingBlock
fn mphi_set_val(p: i32, k: i64, v: i32) { let at = (macc[p].pat as i64) + k; mphi_v[at] = v; mu_set(mphi_u[at], v); }
fn mphi_set_blk(p: i32, k: i64, b: i32) { mphi_b[(macc[p].pat as i64) + k] = b; }
fn mphi_add_incoming(p: i32, v: i32, b: i32) {
    let n = macc[p].pn as i64;
    if n == (macc[p].pcap as i64) {
        let ncap = max(n + n / 2, 2);
        // growHungoffUses: the new uses are set in operand order (pushed at the heads), then the old ones zapped
        let oat = macc[p].pat as i64;
        let nat = mphi_v.len;
        for k in n {
            let nu = mu_new(p, k as i32);
            mphi_v.push(mphi_v[oat + k]);
            mphi_b.push(mphi_b[oat + k]);
            mphi_u.push(nu);
            mu_set(nu, mphi_v[oat + k]);
        }
        for k in ncap - n { mphi_v.push(-1); mphi_b.push(-1); mphi_u.push(mu_new(p, (n + k) as i32)); }
        var k = n;
        while k > 0 { k--; mu_unlink(mphi_u[oat + k]); }
        macc[p].pat = nat as i32;
        macc[p].pcap = ncap as i32;
    }
    let at = (macc[p].pat as i64) + n;
    mphi_v[at] = v;
    mphi_b[at] = b;
    mu_set(mphi_u[at], v);
    macc[p].pn += 1;
}

// ---------------------------------------------------------------------------------------------
// Access lists

fn mssa_append(bv: i32, a: i32) {
    mb_ensure(bv);
    let l = mb[bv].last;
    macc[a].prev = l;
    macc[a].next = -1;
    if l >= 0 { macc[l].next = a; } else { mb[bv].first = a; }
    mb[bv].last = a;
    mb[bv].numvalid = false;
}
fn mssa_append_def(bv: i32, a: i32) {
    mb_ensure(bv);
    let l = mb[bv].dlast;
    macc[a].dprev = l;
    macc[a].dnext = -1;
    if l >= 0 { macc[l].dnext = a; } else { mb[bv].dfirst = a; }
    mb[bv].dlast = a;
}
fn mssa_push_front(bv: i32, a: i32) {
    mb_ensure(bv);
    let f = mb[bv].first;
    macc[a].next = f;
    macc[a].prev = -1;
    if f >= 0 { macc[f].prev = a; } else { mb[bv].last = a; }
    mb[bv].first = a;
    let d = mb[bv].dfirst;
    macc[a].dnext = d;
    macc[a].dprev = -1;
    if d >= 0 { macc[d].dprev = a; } else { mb[bv].dlast = a; }
    mb[bv].dfirst = a;
    mb[bv].numvalid = false;
}
fn mssa_erase_from_access_list(bv: i32, a: i32) {
    let p = macc[a].prev;
    let n = macc[a].next;
    if p >= 0 { macc[p].next = n; } else { mb[bv].first = n; }
    if n >= 0 { macc[n].prev = p; } else { mb[bv].last = p; }
}

// ---------------------------------------------------------------------------------------------
// Construction

// isOrdered
fn mssa_is_ordered(i: i32) -> bool {
    let o = iop(i);
    if o == OP_STORE || o == OP_LOAD { return !ldst_is_unordered(i); }
    return false;
}

// isUseTriviallyOptimizableToLiveOnEntry
fn mssa_use_trivially_live_on_entry(i: i32, q: i32) -> bool {
    if inst_get_md(i, MDK_INVARIANT_LOAD) >= 0 { return true; }
    if iop(i) == OP_LOAD { return !mr_is_mod(aa_mod_ref_mask(ml_get(i), q, false)); }
    return false;
}

fn mssa_ignored_intrinsic(i: i32) -> bool {
    let id = inst_iid(i);
    return id != 0 && (id == IID_allow_runtime_check || id == IID_allow_ubsan_check || id == IID_assume ||
        id == IID_experimental_noalias_scope_decl || id == IID_pseudoprobe);
}

// createNewAccess (no template)
fn mssa_create_new_access(i: i32, q: i32) -> i32 { mssa_create_new_access_t(i, q, -1) }

// createNewAccess(I, AA, Template): template_kind = MAK_DEF / MAK_USE of the template access, -1 = none
fn mssa_create_new_access_t(i: i32, q: i32, template_kind: i64) -> i32 {
    if mssa_ignored_intrinsic(i) { return -1; }
    if !inst_may_read_memory(i) && !inst_may_write_memory(i) { return -1; }
    var is_def = false;
    var is_use = false;
    if template_kind >= 0 {
        is_def = template_kind == (MAK_DEF as i64);
        is_use = template_kind == (MAK_USE as i64);
    } else {
        let mr = aa_inst_loc_mr(i, ml_none(), q);
        is_def = mr_is_mod(mr) || mssa_is_ordered(i);
        is_use = mr_is_ref(mr);
    }
    if !is_def && !is_use { return -1; }
    var a: i32 = -1;
    if is_def {
        a = ma_new(MAK_DEF, i, inst_parent(i));
        macc[a].id = mssa_next_id;
        mssa_next_id++;
    } else {
        a = ma_new(MAK_USE, i, inst_parent(i));
        if mssa_use_trivially_live_on_entry(i, q) { ma_set_optimized(a, mssa_live()); }
    }
    mv_set(i, a);
    return a;
}

fn mssa_create_phi(bv: i32) -> i32 {
    let p = ma_new(MAK_PHI, -1, bv);
    macc[p].id = mssa_next_id;
    mssa_next_id++;
    mssa_push_front(bv, p);
    mv_set(bv, p);
    return p;
}

// ForwardIDFCalculator::calculate over DefiningBlocks (no live-in pruning); SS_MSSA = defining-blocks set,
// SS_MSSA2 = VisitedPQ, SS_MSSA3 = VisitedWorklist. use_gd: ForwardIDFCalculator(DT, GD) whose children come from
// GraphDiff instance gd_inst (successors reversed, then the snapshot's deletions/insertions; CFGDiff.h).
fn mssa_idf(fv: i32, defs: const i32[:], out: i32[>..<]&, use_gd: bool, gd_inst: i64) {
    ss_clear(SS_MSSA);
    for d in defs { ss_add(SS_MSSA, d); }
    ss_clear(SS_MSSA2);
    ss_clear(SS_MSSA3);
    var kids: i32[>..<] = [];
    dt_update_dfs_numbers(fv, DT_DOM);
    var pq: i64[>..<] = [];
    var pqb: i32[>..<] = [];
    fn pq_push(bv: i32) {
        let lvl = dt_level(DT_DOM, bv) as i64;
        let dfs = dt_dfs_in(fv, DT_DOM, bv) as i64;
        let idx = pqb.len as i64;
        if lvl >= (1 << 20) || dfs >= (1 << 21) || idx >= (1 << 21) { fatal("MemorySSA: function too large for the IDF priority key"); }
        pqb.push(bv);
        heap_push(pq, (((1 << 20) - 1 - lvl) << 42) | (((1 << 21) - 1 - dfs) << 21) | idx);
    }
    for bb in defs {
        if dt_has_node(DT_DOM, bb) { pq_push(bb); ss_add(SS_MSSA3, bb); }
    }
    var wl: i32[>..<] = [];
    while pq.len > 0 {
        let top = heap_pop(pq);
        let root = pqb[top & 0x1FFFFF];
        let root_level = dt_level(DT_DOM, root);
        wl.push(root);
        while wl.len > 0 {
            let n = wl.pop();
            kids.clear();
            if use_gd { gd_children(gd_inst, n, false, kids); }
            else {
                let t = block_terminator(n);
                if t >= 0 { for k in term_nsucc(t) { kids.push(term_succ(t, k)); } }
            }
            for s in kids {
                if dt_level(DT_DOM, s) > root_level { continue; }
                if !ss_add(SS_MSSA2, s) { continue; }
                out.push(s);
                if !ss_has(SS_MSSA, s) { pq_push(s); }
            }
            var c = dt_first_child(fv, DT_DOM, n);
            while c >= 0 {
                if ss_add(SS_MSSA3, c) { wl.push(c); }
                c = dt_next_sibling(DT_DOM, c);
            }
        }
    }
}

// renameBlock(BB, IncomingVal, RenameAllUses)
fn mssa_rename_block(bv: i32, incoming0: i32, rename_all: bool) -> i32 {
    var incoming = incoming0;
    var a = mb_first(bv);
    while a >= 0 {
        if ma_is_use_or_def(a) {
            if macc[a].def < 0 || rename_all { ma_set_def(a, incoming); }
            if macc[a].kind == MAK_DEF { incoming = a; }
        } else {
            incoming = a;
        }
        a = macc[a].next;
    }
    return incoming;
}

// renameSuccessorPhis(BB, IncomingVal, RenameAllUses)
fn mssa_rename_successor_phis(bv: i32, incoming: i32, rename_all: bool) {
    let t = block_terminator(bv);
    if t < 0 { return; }
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        let f = mb_first(s);
        if f < 0 || macc[f].kind != MAK_PHI { continue; }
        if rename_all {
            var done = false;
            for i in mphi_n(f) { if mphi_blk(f, i) == bv { mphi_set_val(f, i, incoming); done = true; } }
            if !done { fatal("internal: MemorySSA: incomplete phi during partial rename"); }
        } else {
            mphi_add_incoming(f, incoming, bv);
        }
    }
}

// renamePass(Root, IncomingVal, Visited, SkipVisited, RenameAllUses); Visited = SS_MSSA4 (the caller clears it)
fn mssa_rename_pass(fv: i32, root: i32, incoming0: i32, skip_visited: bool, rename_all: bool) {
    let already = !ss_add(SS_MSSA4, root);
    if skip_visited && already { return; }
    var incoming = mssa_rename_block(root, incoming0, rename_all);
    mssa_rename_successor_phis(root, incoming, rename_all);
    var st_node: i32[>..<] = [];
    var st_child: i32[>..<] = [];
    var st_inc: i32[>..<] = [];
    st_node.push(root);
    st_child.push(dt_first_child(fv, DT_DOM, root));
    st_inc.push(incoming);
    while st_node.len > 0 {
        let top = st_node.len - 1;
        let child = st_child[top];
        incoming = st_inc[top];
        if child < 0 {
            st_node.pop();
            st_child.pop();
            st_inc.pop();
        } else {
            st_child[top] = dt_next_sibling(DT_DOM, child);
            let av = !ss_add(SS_MSSA4, child);
            if skip_visited && av {
                let d = mb_dlast(child);
                if d >= 0 { incoming = d; }
            } else {
                incoming = mssa_rename_block(child, incoming, rename_all);
            }
            mssa_rename_successor_phis(child, incoming, rename_all);
            st_node.push(child);
            st_child.push(dt_first_child(fv, DT_DOM, child));
            st_inc.push(incoming);
        }
    }
}

// markUnreachableAsLiveOnEntry
fn mssa_mark_unreachable(bv: i32) {
    let t = block_terminator(bv);
    if t >= 0 {
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            if !dt_has_node(DT_DOM, s) { continue; }
            let f = mb_first(s);
            if f < 0 || macc[f].kind != MAK_PHI { continue; }
            mphi_add_incoming(f, mssa_live(), bv);
        }
    }
    var a = mb_first(bv);
    while a >= 0 {
        let n = macc[a].next;
        if ma_is_use_or_def(a) { ma_set_def(a, mssa_live()); }
        else { mssa_erase_from_access_list(bv, a); }
        a = n;
    }
}

// MemorySSA::MemorySSA(F, AA, DT) / MemorySSAAnalysis::run
fn mssa_build(fv: i32) {
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    mssa_epoch++;
    mssa_fn = fv;
    mssa_optimized = false;
    macc.clear();
    mphi_v.clear();
    mphi_b.clear();
    mphi_u.clear();
    muses.clear();
    mssa_next_id = 0;
    let entry = func_entry(fv);
    let live = ma_new(MAK_LIVE, -1, entry);
    macc[live].id = mssa_next_id;
    mssa_next_id++;
    let q = aq_push(CA_SIMPLE);
    var defblocks: i32[>..<] = [];
    ss_clear(SS_MSSA);
    var b = func_entry(fv);
    while b >= 0 {
        var has_def = false;
        var i = block_first(b);
        while i >= 0 {
            let a = mssa_create_new_access(i, q);
            if a >= 0 {
                mssa_append(b, a);
                if macc[a].kind == MAK_DEF { has_def = true; mssa_append_def(b, a); }
            }
            i = inst_next(i);
        }
        if has_def { defblocks.push(b); ss_add(SS_MSSA, b); }
        b = block_next(b);
    }
    var idf: i32[>..<] = [];
    mssa_idf(fv, defblocks, idf, false, 0);
    for x in idf { mssa_create_phi(x); }
    ss_clear(SS_MSSA4);
    mssa_rename_pass(fv, entry, live, false, false);
    b = func_entry(fv);
    while b >= 0 {
        if !ss_has(SS_MSSA4, b) { mssa_mark_unreachable(b); }
        b = block_next(b);
    }
    aq_pop(q);
}

// MemorySSAAnalysis: AM.getResult<MemorySSAAnalysis>(F)
fn mssa_get(fv: i32) {
    if mssa_valid(fv) { return; }
    mssa_build(fv);
}

// ---------------------------------------------------------------------------------------------
// Dominance between accesses

fn mssa_renumber_block(bv: i32) {
    var n: i32 = 0;
    var a = mb_first(bv);
    while a >= 0 { n++; macc[a].num = n; a = macc[a].next; }
    mb[bv].numvalid = true;
}

fn mssa_locally_dominates(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if mssa_is_live(b) { return false; }
    if mssa_is_live(a) { return true; }
    let bb = macc[a].bb;
    if !mb[bb].numvalid { mssa_renumber_block(bb); }
    return macc[a].num < macc[b].num;
}

// MemorySSA::dominates(Dominator, Dominatee)
fn mssa_dominates(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if mssa_is_live(b) { return false; }
    if macc[a].bb != macc[b].bb { return dt_dominates_block(DT_DOM, macc[a].bb, macc[b].bb); }
    return mssa_locally_dominates(a, b);
}

// ---------------------------------------------------------------------------------------------
// instructionClobbersQuery

// areLoadsReorderable
fn mssa_loads_reorderable(use_: i32, clob: i32) -> bool {
    let vu = (insts[inst_of(use_)].bits & 1) != 0;
    let vc = (insts[inst_of(clob)].bits & 1) != 0;
    if vu && vc { return false; }
    let seq_cst_use = insts[inst_of(use_)].ord == 7;
    let o = insts[inst_of(clob)].ord;
    // isAtLeastOrStrongerThan(Ordering, Acquire): acquire, acq_rel, seq_cst
    let clob_acquire = o == 4 || o == 6 || o == 7;
    return !(seq_cst_use || clob_acquire);
}

fn mssa_def_clobbers(md: i32, use_loc: ML, use_inst: i32, q: i32) -> bool {
    let di = macc[md].inst;
    let id = inst_iid(di);
    if id != 0 {
        if id == IID_allow_runtime_check || id == IID_allow_ubsan_check || id == IID_invariant_start ||
           id == IID_invariant_end || id == IID_assume || id == IID_experimental_noalias_scope_decl || id == IID_pseudoprobe { return false; }
    }
    if use_inst >= 0 && is_callbase(use_inst) { return mr_is_mod(aa_inst_call_mr(di, use_inst, q)); }
    if iop(di) == OP_LOAD && use_inst >= 0 && iop(use_inst) == OP_LOAD { return !mssa_loads_reorderable(use_inst, di); }
    return mr_is_mod(aa_inst_loc_mr(di, use_loc, q));
}

fn ml_eq(a: ML, b: ML) -> bool {
    a.ptr == b.ptr && a.size == b.size && a.tbaa == b.tbaa && a.tbaa_struct == b.tbaa_struct && a.scope == b.scope &&
    a.noalias == b.noalias && a.noalias_as == b.noalias_as
}

// MemoryLocOrCall(MUD): (is_call, loc)
fn mssa_loc_or_call(a: i32) -> bool, ML {
    let i = macc[a].inst;
    if is_callbase(i) { return true, ml_null(); }
    if iop(i) == OP_FENCE { return false, ml_null(); }
    return false, ml_get(i);
}

// ---------------------------------------------------------------------------------------------
// ClobberWalker

struct DefPath { loc: ML, first: i32, last: i32, prev: i32, cross: bool }
struct TPath { clobber: i32, last_node: i32 }
struct UDE { ma: i32, loc: ML, cross: bool, phi_block: i32 }

var cw_paths: DefPath[>..<];
var cw_limit: i64 = 0;
var cw_q: i32 = -1;                // the BatchAAResults
var cw_query_inst: i32 = -1;       // UpwardsMemoryQuery::Inst
var cw_query_loc: ML;              // StartingLoc
var cw_query_orig: i32 = -1;       // OriginalAccess
var cw_skip_self: bool = false;

// VisitedPhis (DenseSet<UpwardDefsElem>): an open-addressing set with an epoch
struct VKey { ma: i32, loc: ML, cross: bool, stamp: i32 }
var cw_vis: VKey[>..];
var cw_vis_epoch: i32 = 1;
var cw_vis_count: i64 = 0;

fn cw_vis_hash(ma: i32, l: ML, cross: bool) -> u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    fn mix(x: u64) { h = (h ^ x) * 0x100000001b3; h = h ^ (h >> 31); }
    mix(ma as! u64); mix(l.ptr as! u64); mix(l.size); mix(l.tbaa as! u64); mix(l.scope as! u64); mix(l.noalias as! u64);
    mix(if cross { 1 } else { 0 });
    return h;
}
fn cw_vis_clear() { cw_vis_epoch++; cw_vis_count = 0; }
fn cw_vis_insert(ma: i32, l: ML, cross: bool) -> bool {
    if (cw_vis_count + 1) * 2 > cw_vis.len {
        // rehash
        var old: VKey[>..] = [];
        for x in cw_vis { if x.stamp == cw_vis_epoch { old.push(x); } }
        var n = cw_vis.len * 2;
        if n < 64 { n = 64; }
        cw_vis.clear();
        for k in n { cw_vis.push(VKey { ma: -1, loc: ml_null(), cross: false, stamp: 0 }); }
        for x in old {
            var i = (cw_vis_hash(x.ma, x.loc, x.cross) & ((n - 1) as u64)) as i64;
            while cw_vis[i].stamp == cw_vis_epoch { i = (i + 1) & (n - 1); }
            cw_vis[i] = x;
        }
    }
    let n = cw_vis.len;
    var i = (cw_vis_hash(ma, l, cross) & ((n - 1) as u64)) as i64;
    while cw_vis[i].stamp == cw_vis_epoch {
        let x = cw_vis[i];
        if x.ma == ma && ml_eq(x.loc, l) && x.cross == cross { return false; }
        i = (i + 1) & (n - 1);
    }
    cw_vis[i] = VKey { ma: ma, loc: l, cross: cross, stamp: cw_vis_epoch };
    cw_vis_count++;
    return true;
}

// getWalkTarget
fn cw_walk_target(phi: i32) -> i32 {
    var bb = macc[phi].bb;
    loop {
        let id = dt_idom(DT_DOM, bb);
        if id < 0 { break; }
        let d = mb_dlast(id);
        if d >= 0 { return d; }
        bb = id;
    }
    return mssa_live();
}

// BatchAACrossIterationScope + instructionClobbersQuery
fn cw_clobbers(md: i32, loc: ML, cross: bool) -> bool {
    let saved = aqs[cw_q].cross;
    aqs[cw_q].cross = cross;
    let r = mssa_def_clobbers(md, loc, cw_query_inst, cw_q);
    aqs[cw_q].cross = saved;
    return r;
}

// walkToPhiOrClobber(Desc, StopAt, SkipStopAt): (result, is_known_clobber); updates Desc.Last
fn cw_walk_to_phi_or_clobber(pi: i64, stop_at: i32, skip_stop_at: i32) -> i32, bool {
    var limit_reached = false;
    if cw_limit == 0 { cw_limit = 1; limit_reached = true; }
    var cur = cw_paths[pi].last;
    while cur >= 0 {
        cw_paths[pi].last = cur;
        if cur == stop_at || cur == skip_stop_at { return cur, false; }
        if ma_is_def(cur) {
            if mssa_is_live(cur) { return cur, true; }
            cw_limit--;
            if cw_limit == 0 { return cur, true; }
            if cw_clobbers(cur, cw_paths[pi].loc, cw_paths[pi].cross) { return cur, true; }
        }
        cur = if ma_is_use_or_def(cur) { macc[cur].def } else { -1 };
    }
    if limit_reached { cw_limit = 0; }
    return cw_paths[pi].last, false;
}

// IsGuaranteedLoopInvariant
fn mssa_strip_casts(v0: i32) -> i32 {
    // Value::stripPointerCasts (PSK_ZeroIndices)
    var v = v0;
    var n = 0;
    loop {
        n++;
        if n > 1000 { return v; }
        let o = opcode_of(v);
        if o == OP_GEP {
            var allz = true;
            for k in 1..nops(v) { let x = op(v, k); if !(is_constant(x) && is_null_value(x)) { allz = false; } }
            if !allz { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let x = op(v, 0);
            if ty_kind(vals[x].ty) != TK_PTR { return v; }
            v = x;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else if is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv < 0 { return v; }
            v = rv;
        } else {
            return v;
        }
    }
    return v;
}
fn mssa_loop_invariant_base(p0: i32) -> bool {
    let p = mssa_strip_casts(p0);
    if !is_inst(p) { return true; }
    return iop(p) == OP_ALLOCA;
}
fn mssa_guaranteed_loop_invariant(p0: i32) -> bool {
    let p = mssa_strip_casts(p0);
    if is_inst(p) && func_entry(inst_func(p)) == inst_parent(p) { return true; }
    if opcode_of(p) == OP_GEP {
        var allc = true;
        for k in 1..nops(p) { if !is_constant(op(p, k)) { allc = false; } }
        return mssa_loop_invariant_base(op(p, 0)) && allc;
    }
    return mssa_loop_invariant_base(p);
}

// upward_defs_iterator over the operands of MemoryPhi phi starting at (Loc, cross): element k
fn mssa_upward_def(phi: i32, k: i64, loc: ML, cross: bool) -> UDE {
    var e = UDE { ma: mphi_val(phi, k), loc: loc, cross: cross, phi_block: mphi_blk(phi, k) };
    if loc.ptr >= 0 {
        let pm0 = pta_mark();
        let tr = pta_new(loc.ptr, false);
        let addr = pta_translate_value(tr, macc[phi].bb, mphi_blk(phi, k), true);
        pta_release(pm0);
        if addr >= 0 && addr != e.loc.ptr { e.loc.ptr = addr; }
        if !mssa_guaranteed_loop_invariant(e.loc.ptr) { e.loc.size = LS_BEFORE_OR_AFTER; }
    } else {
        e.cross = true;
    }
    return e;
}

// addSearches
fn cw_add_searches(phi: i32, paused: i32[>..<]&, prior: i64, cross: bool) {
    let loc = cw_paths[prior].loc;
    for k in mphi_n(phi) {
        let e = mssa_upward_def(phi, k, loc, cross);
        paused.push(cw_paths.len as i32);
        cw_paths.push(DefPath { loc: e.loc, first: e.ma, last: e.ma, prev: prior as i32, cross: e.cross });
    }
}

// getBlockingAccess: returns (found, TerminatedPath)
fn cw_get_blocking_access(stop_where: i32, paused: i32[>..<]&, new_paused: i32[>..<]&, terminated: TPath[>..<]&) -> bool, TPath {
    while paused.len > 0 {
        let pi = paused.pop() as i64;
        let node = cw_paths[pi];
        if !cw_vis_insert(node.last, node.loc, node.cross) { continue; }
        var skip_stop: i32 = -1;
        if cw_skip_self && ml_eq(node.loc, cw_query_loc) { skip_stop = cw_query_orig; }
        let res, known = cw_walk_to_phi_or_clobber(pi, stop_where, skip_stop);
        if known {
            let term = TPath { clobber: res, last_node: pi as i32 };
            if !mssa_dominates(res, stop_where) { return true, term; }
            terminated.push(term);
            continue;
        }
        if res == stop_where || res == skip_stop {
            if res != skip_stop { new_paused.push(pi as i32); }
            continue;
        }
        cw_add_searches(res, paused, pi, cw_paths[pi].cross);
    }
    return false, TPath { clobber: -1, last_node: -1 };
}

// MoveDominatedPathToEnd
fn cw_move_dominated_to_end(ps: TPath[>..<]&) {
    var dom: i64 = 0;
    var i: i64 = 1;
    while i < ps.len {
        if !mssa_dominates(ps[i].clobber, ps[dom].clobber) { dom = i; }
        i++;
    }
    let last = ps.len - 1;
    if last != dom { let t = ps[last]; ps[last] = ps[dom]; ps[dom] = t; }
}

// tryOptimizePhi -> PrimaryClobber.Clobber
fn cw_try_optimize_phi(phi: i32, start: i32, loc: ML) -> i32 {
    cw_paths.push(DefPath { loc: loc, first: start, last: phi, prev: -1, cross: false });
    var prior_size = cw_paths.len;
    var paused: i32[>..<] = [];
    var new_paused: i32[>..<] = [];
    var terminated: TPath[>..<] = [];
    cw_add_searches(phi, paused, 0, false);
    var current = phi;
    loop {
        let target = cw_walk_target(current);
        let found, blocker = cw_get_blocking_access(target, paused, new_paused, terminated);
        if found {
            var n = blocker.last_node as i64;
            while n >= 0 && n >= prior_size { n = cw_paths[n].prev as i64; }
            if n < 0 { fatal("internal: MemorySSA tryOptimizePhi found no prior path"); }
            return cw_paths[n].last;
        }
        if new_paused.len == 0 {
            cw_move_dominated_to_end(terminated);
            return terminated[terminated.len - 1].clobber;
        }
        var chain_end: i32 = -1;
        var clobbers: TPath[>..<] = [];
        for p in new_paused {
            let r, known = cw_walk_to_phi_or_clobber(p as i64, -1, -1);
            if known { clobbers.push(TPath { clobber: r, last_node: p }); }
            else { chain_end = r; }
        }
        if terminated.len > 0 {
            if chain_end < 0 {
                var x = target;
                while x >= 0 { chain_end = x; x = if ma_is_use_or_def(x) { macc[x].def } else { -1 }; }
            }
            let chain_bb = macc[chain_end].bb;
            for tp in terminated {
                if dt_dominates_block(DT_DOM, chain_bb, macc[tp.clobber].bb) { clobbers.push(tp); }
            }
        }
        if clobbers.len > 0 {
            cw_move_dominated_to_end(clobbers);
            return clobbers[clobbers.len - 1].clobber;
        }
        prior_size = cw_paths.len;
        paused.clear();
        for p in new_paused { cw_add_searches(chain_end, paused, p as i64, cw_paths[p].cross); }
        new_paused.clear();
        current = chain_end;
    }
    return -1;
}

// ClobberWalker::findClobber(BAA, Start, Q, UpWalkLimit)
fn cw_find_clobber(start: i32) -> i32 {
    if cw_limit == 0 { cw_limit++; }
    var current = start;
    if macc[start].kind == MAK_USE { current = macc[start].def; }
    cw_paths.clear();
    cw_paths.push(DefPath { loc: cw_query_loc, first: current, last: current, prev: -1, cross: false });
    let r, known = cw_walk_to_phi_or_clobber(0, -1, -1);
    if known { cw_paths.clear(); return r; }
    let phi = cw_paths[0].last;
    cw_paths.clear();
    cw_vis_clear();
    let res = cw_try_optimize_phi(phi, current, cw_query_loc);
    cw_paths.clear();
    cw_vis_clear();
    return res;
}

// getInvariantGroupClobberingInstruction
fn mssa_invariant_group_clobber(i: i32) -> i32 {
    if inst_get_md(i, MDK_INVARIANT_GROUP) < 0 || inst_is_volatile(i) { return -1; }
    let o = iop(i);
    if o != OP_LOAD && o != OP_STORE { return -1; }
    let ptr = mssa_strip_casts(if o == OP_LOAD { op(i, 0) } else { op(i, 1) });
    if is_constant(ptr) { return -1; }
    var most = i;
    var u = vals[ptr].first_use;
    while u >= 0 {
        let x = uses[u].user;
        u = uses[u].next;
        if !is_inst(x) || x == i || !dt_value_dominates_inst(x, most) { continue; }
        let xo = iop(x);
        if inst_get_md(x, MDK_INVARIANT_GROUP) >= 0 && (xo == OP_LOAD || xo == OP_STORE) &&
           (if xo == OP_LOAD { op(x, 0) } else { op(x, 1) }) == ptr && !inst_is_volatile(x) {
            most = x;
        }
    }
    return if most == i { -1 } else { most };
}

// ClobberWalkerBase::getClobberingMemoryAccessBase(MA, BAA, UWL, SkipSelf, UseInvariantGroup)
fn mssa_clobbering_access(ma: i32, q: i32, skip_self: bool, use_invariant_group: bool) -> i32 {
    if !ma_is_use_or_def(ma) { return ma; }
    if mssa_is_live(ma) { return ma; }
    let i = macc[ma].inst;
    if use_invariant_group {
        let ci = mssa_invariant_group_clobber(i);
        if ci >= 0 {
            let cma = mssa_access_of(ci);
            if macc[cma].kind == MAK_USE { return macc[cma].def; }
            return cma;
        }
    }
    var is_opt = false;
    if ma_is_optimized(ma) {
        if !skip_self || macc[ma].kind != MAK_DEF { return ma_get_optimized(ma); }
        is_opt = true;
    }
    if !is_callbase(i) && inst_is_fence_like(i) { return ma; }
    cw_q = q;
    cw_query_inst = i;
    cw_query_orig = ma;
    cw_skip_self = false;
    cw_query_loc = if is_callbase(i) { ml_null() } else { ml_get(i) };
    if mssa_use_trivially_live_on_entry(i, q) {
        ma_set_optimized(ma, mssa_live());
        return mssa_live();
    }
    var optimized: i32 = -1;
    if !is_opt {
        let d = macc[ma].def;
        if mssa_is_live(d) { ma_set_optimized(ma, d); return d; }
        optimized = cw_find_clobber(d);
        ma_set_optimized(ma, optimized);
    } else {
        optimized = ma_get_optimized(ma);
    }
    if skip_self && macc[optimized].kind == MAK_PHI && macc[ma].kind == MAK_DEF && cw_limit != 0 {
        cw_skip_self = true;
        return cw_find_clobber(optimized);
    }
    return optimized;
}

// CachingWalker::getClobberingMemoryAccess(MA, BAA): with a fresh MaxCheckLimit
fn mssa_get_clobbering(ma: i32, q: i32) -> i32 {
    cw_limit = mssa_max_check_limit();
    return mssa_clobbering_access(ma, q, false, true);
}

// ClobberWalkerBase::getClobberingMemoryAccessBase(StartingAccess, Loc, BAA, UWL)
fn mssa_clobbering_access_loc(start: i32, loc: ML, q: i32) -> i32 {
    if loc.ptr < 0 { return start; }
    if ma_is_use_or_def(start) {
        if mssa_is_live(start) { return start; }
        let i = macc[start].inst;
        if !is_callbase(i) && inst_is_fence_like(i) { return start; }
    }
    cw_q = q;
    cw_query_inst = -1;
    cw_query_orig = start;
    cw_query_loc = loc;
    cw_skip_self = false;
    return cw_find_clobber(start);
}
fn mssa_get_clobbering_loc(ma: i32, loc: ML, q: i32) -> i32 {
    cw_limit = mssa_max_check_limit();
    return mssa_clobbering_access_loc(ma, loc, q);
}

// ---------------------------------------------------------------------------------------------
// OptimizeUses (ensureOptimizedUses)

struct LSI { key_call: bool, loc: ML, call: i32, stack_epoch: i64, pop_epoch: i64, lower: i64, lower_block: i32,
             last_kill: i64, last_kill_valid: bool }
var mo_lsi: LSI[>..];

// LocStackInfo[UseMLOC] (MemoryLocOrCall equality: calls compare callee and arguments)
fn mo_lsi_find(is_call: bool, loc: ML, call: i32) -> i64 {
    for k in mo_lsi.len {
        let x = mo_lsi[k];
        if x.key_call != is_call { continue; }
        if !is_call {
            if ml_eq(x.loc, loc) { return k; }
            continue;
        }
        let a = x.call;
        if cb_callee(a) != cb_callee(call) { continue; }
        let na = cb_nargs(a);
        if na != cb_nargs(call) { continue; }
        var same = true;
        for j in na { if cb_arg(a, j) != cb_arg(call, j) { same = false; } }
        if same { return k; }
    }
    mo_lsi.push(LSI { key_call: is_call, loc: loc, call: call, stack_epoch: 0, pop_epoch: 0, lower: 0, lower_block: -1,
                      last_kill: 0, last_kill_valid: false });
    return mo_lsi.len - 1;
}

fn mssa_ensure_optimized() {
    if mssa_optimized { return; }
    let fv = mssa_fn;
    let q = aq_push(CA_SIMPLE);
    let max_check = mssa_max_check_limit();
    mo_lsi.clear();
    var stack: i32[>..<] = [];
    stack.push(mssa_live());
    var stack_epoch: i64 = 1;
    var pop_epoch: i64 = 1;
    // depth_first(DT->getRootNode()): preorder, children in order
    var dfs_n: i32[>..<] = [];
    var dfs_c: i32[>..<] = [];
    let root = dt_root(fv, DT_DOM);
    fn visit(bb: i32) {
        if mb_first(bb) < 0 { return; }
        loop {
            let back = macc[stack[stack.len - 1]].bb;
            if dt_dominates_block(DT_DOM, back, bb) { break; }
            while macc[stack[stack.len - 1]].bb == back { stack.pop(); }
            pop_epoch++;
        }
        var a = mb_first(bb);
        while a >= 0 {
            let next = macc[a].next;
            if macc[a].kind != MAK_USE {
                stack.push(a);
                stack_epoch++;
                a = next;
                continue;
            }
            if ma_is_optimized(a) { a = next; continue; }
            let is_call, uloc = mssa_loc_or_call(a);
            let li = mo_lsi_find(is_call, uloc, macc[a].inst);
            if mo_lsi[li].pop_epoch != pop_epoch {
                mo_lsi[li].pop_epoch = pop_epoch;
                mo_lsi[li].stack_epoch = stack_epoch;
                let lb = mo_lsi[li].lower_block;
                if lb >= 0 && lb != bb && !dt_dominates_block(DT_DOM, lb, bb) {
                    mo_lsi[li].lower = 0;
                    mo_lsi[li].lower_block = macc[stack[0]].bb;
                    mo_lsi[li].last_kill_valid = false;
                }
            } else if mo_lsi[li].stack_epoch != stack_epoch {
                mo_lsi[li].pop_epoch = pop_epoch;
                mo_lsi[li].stack_epoch = stack_epoch;
            }
            if !mo_lsi[li].last_kill_valid {
                mo_lsi[li].last_kill = stack.len - 1;
                mo_lsi[li].last_kill_valid = true;
            }
            var upper = stack.len - 1;
            if upper - mo_lsi[li].lower > max_check {
                mo_lsi[li].last_kill_valid = false;
                a = next;
                continue;
            }
            var found = false;
            cw_limit = max_check;
            while upper > mo_lsi[li].lower {
                let s = stack[upper];
                if macc[s].kind == MAK_PHI {
                    let res = mssa_clobbering_access(a, q, false, false);
                    while stack[upper] != res { upper--; }
                    found = true;
                    break;
                }
                let use_inst = macc[a].inst;
                if mssa_def_clobbers(s, if is_call { ml_null() } else { uloc }, use_inst, q) { found = true; break; }
                upper--;
            }
            if found || upper < mo_lsi[li].last_kill {
                ma_set_optimized(a, stack[upper]);
                mo_lsi[li].last_kill = upper;
            } else {
                ma_set_optimized(a, stack[mo_lsi[li].last_kill]);
            }
            mo_lsi[li].lower = stack.len - 1;
            mo_lsi[li].lower_block = bb;
            a = next;
        }
    }
    visit(root);
    dfs_n.push(root);
    dfs_c.push(dt_first_child(fv, DT_DOM, root));
    while dfs_n.len > 0 {
        let top = dfs_n.len - 1;
        let c = dfs_c[top];
        if c < 0 { dfs_n.pop(); dfs_c.pop(); continue; }
        dfs_c[top] = dt_next_sibling(DT_DOM, c);
        visit(c);
        dfs_n.push(c);
        dfs_c.push(dt_first_child(fv, DT_DOM, c));
    }
    aq_pop(q);
    mssa_optimized = true;
}

// ---------------------------------------------------------------------------------------------
// Printing

fn mssa_put_id(out: u8[>..]&, a: i32) {
    if a >= 0 && macc[a].id != 0 { format(out, macc[a].id); } else { out.append("liveOnEntry"); }
}

// MemoryAccess::print
fn mssa_format(out: u8[>..]&, a: i32, fv: i32) {
    let k = macc[a].kind;
    if k == MAK_DEF || k == MAK_LIVE {
        format(out, macc[a].id);
        out.append(" = MemoryDef(");
        mssa_put_id(out, macc[a].def);
        out.push(')');
        if ma_is_optimized(a) { out.append("->"); mssa_put_id(out, macc[a].opt); }
        return;
    }
    if k == MAK_USE {
        out.append("MemoryUse(");
        mssa_put_id(out, macc[a].def);
        out.push(')');
        return;
    }
    format(out, macc[a].id);
    out.append(" = MemoryPhi(");
    for i in mphi_n(a) {
        if i > 0 { out.push(','); }
        out.push('{');
        let b = mphi_blk(a, i);
        if vals[b].name >= 0 { out.append(sbytes(vals[b].name)); }
        else {
            let mark = errbuf.len;
            errs_operand(b, fv, false);
            out.append(errbuf[mark..]);
            errbuf.resize(mark);
        }
        out.push(',');
        let v = mphi_val(a, i);
        if macc[v].id != 0 { format(out, macc[v].id); } else { out.append("liveOnEntry"); }
        out.push('}');
    }
    out.push(')');
}

var mssa_types_scanned: i64 = 0;
var mssa_numbered_structs: bool = false;
fn mssa_have_numbered_structs() -> bool {
    while mssa_types_scanned < types.len {
        let t = types[mssa_types_scanned];
        if t.kind == TK_STRUCT && (t.flags & TF_NAMED) != 0 && t.name < 0 { mssa_numbered_structs = true; }
        mssa_types_scanned++;
    }
    return mssa_numbered_structs;
}

// F->print(OS, &Writer) with the precomputed annotations in pr_annot*
fn mssa_print_function(fv: i32) {
    slots_begin(fv);
    slots_end();
    let md_mark = md_order.len;
    let as_mark = as_order.len;
    // AssemblyWriter: TypePrinter.incorporateTypes(*M); only numbered (unnamed identified) structs depend on it
    if mssa_have_numbered_structs() { type_finder(globs[glob_of(fv)].module); }
    let mark = out.len;
    pr_annot_on = true;
    print_function(fv);
    pr_annot_on = false;
    errbuf.append(out[mark..]);
    out.resize(mark);
    pr_annot_reset();
    while md_order.len > md_mark { mdslot[md_order[md_order.len - 1]] = -1; md_order.resize(md_order.len - 1); }
    while as_order.len > as_mark { asslot[as_order[as_order.len - 1]] = -1; as_order.resize(as_order.len - 1); }
}

fn mssa_annotate(v: i32, text: const u8[:]) { pr_annot_set(v, text); }

// MemorySSAPrinterPass::run
fn mssa_print(fv: i32, ensure_optimized: bool) {
    mssa_get(fv);
    if ensure_optimized { mssa_ensure_optimized(); }
    errs("MemorySSA for function: ");
    errs(val_name(fv));
    errs("\n");
    var line: u8[>..] = [];
    var b = func_entry(fv);
    while b >= 0 {
        let p = mssa_access_of(b);
        if p >= 0 {
            line.clear();
            line.append("; ");
            mssa_format(line, p, fv);
            line.push('\n');
            mssa_annotate(b, line);
        }
        var i = block_first(b);
        while i >= 0 {
            let a = mssa_access_of(i);
            if a >= 0 {
                line.clear();
                line.append("; ");
                mssa_format(line, a, fv);
                line.push('\n');
                mssa_annotate(i, line);
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    mssa_print_function(fv);
}

// MemorySSAWalkerPrinterPass::run
fn mssa_print_walker(fv: i32) {
    mssa_get(fv);
    errs("MemorySSA (walker) for function: ");
    errs(val_name(fv));
    errs("\n");
    let q = aq_push(CA_SIMPLE);
    var line: u8[>..] = [];
    var b = func_entry(fv);
    while b >= 0 {
        let p = mssa_access_of(b);
        if p >= 0 {
            line.clear();
            line.append("; ");
            mssa_format(line, p, fv);
            line.push('\n');
            mssa_annotate(b, line);
        }
        var i = block_first(b);
        while i >= 0 {
            let a = mssa_access_of(i);
            if a >= 0 {
                let c = mssa_get_clobbering(a, q);
                line.clear();
                line.append("; ");
                mssa_format(line, a, fv);
                if c >= 0 {
                    line.append(" - clobbered by ");
                    if mssa_is_live(c) { line.append("liveOnEntry"); } else { mssa_format(line, c, fv); }
                }
                line.push('\n');
                mssa_annotate(i, line);
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    aq_pop(q);
    mssa_print_function(fv);
}
