// MemorySSAUpdater: port of llvm/lib/Analysis/MemorySSAUpdater.cpp (the marker-based SSA updater:
// getPreviousDef / getPreviousDefInBlock / getPreviousDefFromEnd / getPreviousDefRecursive, recursePhi,
// tryRemoveTrivialPhi(s), insertUse, insertDef, fixupDefs; CFG updates: removeEdge, removeDuplicatePhiEdgesBetween,
// applyUpdates, applyInsertUpdates, wireOldPredecessorsToNewImmediatePredecessor,
// updatePhisWhenInsertingUniqueBackedgeBlock, removeBlocks, changeToUnreachable; moves: moveTo, moveBefore,
// moveAfter, moveToPlace, moveAllAccesses, moveAllAfterSpliceBlocks, moveAllAfterMergeBlocks; removeMemoryAccess;
// createMemoryAccessInBB / Before / After; cloning: cloneUsesAndDefs, getNewDefiningAccessForClone,
// updateForClonedBlockIntoPred) and of the MemorySSA mutation API of llvm/lib/Analysis/MemorySSA.cpp
// (insertIntoListsForBlock, insertIntoListsBefore, prepareForMoveTo, moveTo (both), createDefinedAccess,
// removeFromLookups, removeFromLists, verifyMemorySSA with verifyOrderingDominationAndDefUses,
// verifyDominationNumbers and verifyPrevDefInPhis) and MemoryPhi's unorderedDeleteIncoming* (MemorySSA.h).
// Not ported (fail loudly): updateForClonedLoop, updateExitBlocksForClonedLoop.
//
// Value handles (TrackingVH follows RAUW, WeakVH is nulled on deletion) are records in msu_vhs with an intrusive
// list per access (MAcc.vh). They live only inside one public updater call: msu_enter/msu_leave bracket every
// entry point and the outermost leave releases them all (LLVM's handles are locals of these calls too, except
// InsertedPHIs, which is cleared at the start of insertUse/insertDef, its only readers).
// A deleted access gets kind MAK_DEAD (ids are never reused).
//
// Recursion (getPreviousDefRecursive <-> tryRemoveTrivialPhi <-> removeMemoryAccess <-> recursePhi) keeps its
// vectors as runs on global stacks (msu_preds, msu_ops, msu_stack, msu_check) with a mark.
import std;
import ir;
import irutil;
import domtree;
import flags;
import memloc;
import aautil;
import aa;
import memoryssa;

let MAK_DEAD: u8 = 4;

// MemorySSA::InsertionPlace
let MSP_BEGINNING: i64 = 0;
let MSP_END: i64 = 1;
let MSP_BEFORE_TERMINATOR: i64 = 2;

fn msu_is_dead(a: i32) -> bool { macc[a].kind == MAK_DEAD }

// ---------------------------------------------------------------------------------------------
// Private stamped sets and maps keyed by block or access ids

let MS_N: i64 = 6;
let MS_VISITED: i64 = 0;   // VisitedBlocks
let MS_CACHE: i64 = 1;     // CachedPreviousDef (block -> TrackingVH)
let MS_NONOPT: i64 = 2;    // NonOptPhis
let MS_SEEN: i64 = 3;      // fixupDefs' Seen
let MS_TMP: i64 = 4;
let MS_TMP2: i64 = 5;
var ms_stamp: i32[>..];
var ms_val: i32[>..];
var ms_epoch: i32[6] = [1; 6];

fn ms_clear(s: i64) { ms_epoch[s] += 1; }
fn ms_has(s: i64, k: i32) -> bool { let i = (k as i64) * MS_N + s; i < ms_stamp.len && ms_stamp[i] == ms_epoch[s] }
fn ms_set(s: i64, k: i32, v: i32) {
    let i = (k as i64) * MS_N + s;
    while ms_stamp.len <= i { ms_stamp.push(0); ms_val.push(-1); }
    ms_stamp[i] = ms_epoch[s];
    ms_val[i] = v;
}
fn ms_add(s: i64, k: i32) -> bool { if ms_has(s, k) { return false; } ms_set(s, k, 0); return true; }
fn ms_del(s: i64, k: i32) { let i = (k as i64) * MS_N + s; if i < ms_stamp.len { ms_stamp[i] = 0; } }
fn ms_get(s: i64, k: i32) -> i32 { if ms_has(s, k) { ms_val[(k as i64) * MS_N + s] } else { -1 } }

// ---------------------------------------------------------------------------------------------
// Value handles

struct MVH { a: i32, tracking: bool, next: i32, prev: i32 }
var msu_vhs: MVH[>..<];
var msu_depth: i32 = 0;
var msu_inserted: i32[>..<];     // InsertedPHIs (WeakVH handles)

fn vh_link(h: i32, a: i32) {
    msu_vhs[h].a = a;
    msu_vhs[h].prev = -1;
    msu_vhs[h].next = -1;
    if a < 0 { return; }
    let f = macc[a].vh;
    msu_vhs[h].next = f;
    if f >= 0 { msu_vhs[f].prev = h; }
    macc[a].vh = h;
}
fn vh_unlink(h: i32) {
    let a = msu_vhs[h].a;
    if a < 0 { return; }
    let p = msu_vhs[h].prev;
    let n = msu_vhs[h].next;
    if p >= 0 { msu_vhs[p].next = n; } else { macc[a].vh = n; }
    if n >= 0 { msu_vhs[n].prev = p; }
    msu_vhs[h].a = -1;
    msu_vhs[h].next = -1;
    msu_vhs[h].prev = -1;
}
fn vh_new(a: i32, tracking: bool) -> i32 {
    let h = msu_vhs.len as i32;
    msu_vhs.push(MVH { a: -1, tracking: tracking, next: -1, prev: -1 });
    vh_link(h, a);
    return h;
}
fn vh_get(h: i32) -> i32 { msu_vhs[h].a }

// ValueHandleBase::ValueIsRAUWd: TrackingVHs follow, WeakVHs stay
fn vh_rauw(a: i32, nw: i32) {
    var h = macc[a].vh;
    while h >= 0 {
        let n = msu_vhs[h].next;
        if msu_vhs[h].tracking { vh_unlink(h); vh_link(h, nw); }
        h = n;
    }
}
// ValueHandleBase::ValueIsDeleted
fn vh_deleted(a: i32) {
    while macc[a].vh >= 0 { vh_unlink(macc[a].vh); }
}

fn msu_enter() { msu_depth++; }
fn msu_leave() {
    msu_depth--;
    if msu_depth > 0 { return; }
    for h in msu_vhs.len { vh_unlink(h as i32); }
    msu_vhs.clear();
    msu_inserted.clear();
}
// A pass starts using the updater
fn msu_reset() {
    msu_depth = 0;
    for h in msu_vhs.len { vh_unlink(h as i32); }
    msu_vhs.clear();
    msu_inserted.clear();
    ms_clear(MS_NONOPT);
}

// ---------------------------------------------------------------------------------------------
// Operand updates

// Use::set on a MemoryAccess operand, keeping the cached operand values (def / opt / phi incoming) in sync
fn msu_use_set(u: i32, v: i32) {
    let user = muses[u].user;
    let slot = muses[u].slot;
    if macc[user].kind == MAK_PHI {
        mphi_v[(macc[user].pat as i64) + (slot as i64)] = v;
    } else if slot == 0 {
        macc[user].def = v;
    } else {
        macc[user].opt = v;
    }
    mu_set(u, v);
}

// Value::replaceAllUsesWith on a MemoryAccess
fn msu_rauw(a: i32, nw: i32) {
    vh_rauw(a, nw);
    while macc[a].first_use >= 0 { msu_use_set(macc[a].first_use, nw); }
}

// MemoryPhi::getBasicBlockIndex
fn mphi_block_index(p: i32, bb: i32) -> i64 {
    for i in mphi_n(p) { if mphi_blk(p, i) == bb { return i; } }
    return -1;
}
// MemoryPhi::getIncomingValueForBlock
fn mphi_value_for_block(p: i32, bb: i32) -> i32 {
    let i = mphi_block_index(p, bb);
    if i < 0 { fatal("internal: MemoryPhi: invalid basic block argument"); }
    return mphi_val(p, i);
}
// MemoryPhi::unorderedDeleteIncoming(I)
fn mphi_unordered_delete_incoming(p: i32, i: i64) {
    let e = mphi_n(p);
    if e < 2 { fatal("internal: MemoryPhi: cannot remove the last incoming value"); }
    mphi_set_val(p, i, mphi_val(p, e - 1));
    mphi_set_blk(p, i, mphi_blk(p, e - 1));
    let at = (macc[p].pat as i64) + e - 1;
    mphi_v[at] = -1;
    mu_set(mphi_u[at], -1);
    mphi_b[at] = -1;
    macc[p].pn -= 1;
}
// unorderedDeleteIncomingBlock(BB)
fn mphi_unordered_delete_incoming_block(p: i32, bb: i32) {
    var i: i64 = 0;
    while i < mphi_n(p) {
        if mphi_blk(p, i) == bb { mphi_unordered_delete_incoming(p, i); continue; }
        i++;
    }
}
// MemoryAccess::dropAllReferences
fn ma_drop_all_references(a: i32) {
    if macc[a].kind == MAK_PHI {
        for k in mphi_n(a) { let at = (macc[a].pat as i64) + k; mphi_v[at] = -1; mu_set(mphi_u[at], -1); }
    } else {
        if macc[a].u0 >= 0 { macc[a].def = -1; mu_set(macc[a].u0, -1); }
        if macc[a].u1 >= 0 { macc[a].opt = -1; mu_set(macc[a].u1, -1); }
    }
}

// ---------------------------------------------------------------------------------------------
// MemorySSA mutation API

// MemorySSA::removeFromLookups
fn mssa_remove_from_lookups(a: i32) {
    if macc[a].kind != MAK_PHI { ma_set_def(a, -1); }
    // getWalker()->invalidateInfo(MA)
    if macc[a].kind != MAK_USE && macc[a].kind != MAK_PHI { ma_reset_optimized(a); }
    let key = if macc[a].kind == MAK_PHI { macc[a].bb } else { macc[a].inst };
    if mssa_access_of(key) == a { mv_set(key, -1); }
}

// MemorySSA::removeFromLists(MA, ShouldDelete)
fn mssa_remove_from_lists_x(a: i32, should_delete: bool) {
    let bv = macc[a].bb;
    if macc[a].kind != MAK_USE {
        let p = macc[a].dprev;
        let n = macc[a].dnext;
        if p >= 0 { macc[p].dnext = n; } else { mb[bv].dfirst = n; }
        if n >= 0 { macc[n].dprev = p; } else { mb[bv].dlast = p; }
        macc[a].dprev = -1;
        macc[a].dnext = -1;
    }
    mssa_erase_from_access_list(bv, a);
    macc[a].prev = -1;
    macc[a].next = -1;
    if mb[bv].first < 0 { mb[bv].numvalid = false; }
    if !should_delete { return; }
    // deleting the access drops its operands and nulls its WeakVHs
    vh_deleted(a);
    if macc[a].kind == MAK_PHI {
        for k in mphi_n(a) { mu_unlink(mphi_u[(macc[a].pat as i64) + k]); }
    } else {
        if macc[a].u0 >= 0 { mu_unlink(macc[a].u0); }
        if macc[a].u1 >= 0 { mu_unlink(macc[a].u1); }
    }
    macc[a].kind = MAK_DEAD;
}
fn mssa_remove_from_lists(a: i32) { mssa_remove_from_lists_x(a, true); }

// access-list helpers: insert a before b (b = -1: at the end)
fn ml_insert_before(bv: i32, a: i32, b: i32) {
    mb_ensure(bv);
    if b < 0 {
        let l = mb[bv].last;
        macc[a].prev = l;
        macc[a].next = -1;
        if l >= 0 { macc[l].next = a; } else { mb[bv].first = a; }
        mb[bv].last = a;
        return;
    }
    let p = macc[b].prev;
    macc[a].prev = p;
    macc[a].next = b;
    macc[b].prev = a;
    if p >= 0 { macc[p].next = a; } else { mb[bv].first = a; }
}
fn md_insert_before(bv: i32, a: i32, b: i32) {
    mb_ensure(bv);
    if b < 0 {
        let l = mb[bv].dlast;
        macc[a].dprev = l;
        macc[a].dnext = -1;
        if l >= 0 { macc[l].dnext = a; } else { mb[bv].dfirst = a; }
        mb[bv].dlast = a;
        return;
    }
    let p = macc[b].dprev;
    macc[a].dprev = p;
    macc[a].dnext = b;
    macc[b].dprev = a;
    if p >= 0 { macc[p].dnext = a; } else { mb[bv].dfirst = a; }
}
fn mb_dfirst(bv: i32) -> i32 { if (bv as i64) < mb_stamp.len && mb_stamp[bv] == mssa_epoch { mb[bv].dfirst } else { -1 } }

// MemorySSA::insertIntoListsForBlock(NewAccess, BB, Point)
fn mssa_insert_into_lists_for_block(a: i32, bv: i32, point: i64) {
    mb_ensure(bv);
    if point == MSP_BEGINNING {
        if macc[a].kind == MAK_PHI {
            ml_insert_before(bv, a, mb[bv].first);
            md_insert_before(bv, a, mb[bv].dfirst);
        } else {
            var ai = mb[bv].first;
            while ai >= 0 && macc[ai].kind == MAK_PHI { ai = macc[ai].next; }
            ml_insert_before(bv, a, ai);
            if macc[a].kind != MAK_USE {
                var di = mb[bv].dfirst;
                while di >= 0 && macc[di].kind == MAK_PHI { di = macc[di].dnext; }
                md_insert_before(bv, a, di);
            }
        }
    } else {
        ml_insert_before(bv, a, -1);
        if macc[a].kind != MAK_USE { md_insert_before(bv, a, -1); }
    }
    mb[bv].numvalid = false;
}

// MemorySSA::insertIntoListsBefore(What, BB, InsertPt): InsertPt = an access of BB's list, -1 = end()
fn mssa_insert_into_lists_before(a: i32, bv: i32, insert_pt: i32) {
    mb_ensure(bv);
    ml_insert_before(bv, a, insert_pt);
    if macc[a].kind != MAK_USE {
        if insert_pt < 0 {
            md_insert_before(bv, a, -1);
        } else if macc[insert_pt].kind == MAK_DEF {
            md_insert_before(bv, a, insert_pt);
        } else {
            var x = insert_pt;
            while x >= 0 && macc[x].kind != MAK_DEF { x = macc[x].next; }
            md_insert_before(bv, a, x);
        }
    }
    mb[bv].numvalid = false;
}

// MemorySSA::prepareForMoveTo
fn mssa_prepare_for_move_to(a: i32, bv: i32) {
    mssa_remove_from_lists_x(a, false);
    if macc[a].kind == MAK_DEF { ma_reset_optimized(a); }
    macc[a].bb = bv;
}
// MemorySSA::moveTo(MemoryUseOrDef *What, BB, AccessList::iterator Where)
fn mssa_move_to_before(a: i32, bv: i32, where: i32) {
    mssa_prepare_for_move_to(a, bv);
    mssa_insert_into_lists_before(a, bv, where);
}
// MemorySSA::moveTo(MemoryAccess *What, BB, InsertionPlace Point)
fn mssa_move_to_place(a: i32, bv: i32, point: i64) {
    if macc[a].kind == MAK_PHI {
        if point != MSP_BEGINNING { fatal("internal: MemorySSA: can only move a Phi at the beginning of the block"); }
        if mssa_access_of(macc[a].bb) == a { mv_set(macc[a].bb, -1); }
        if mssa_access_of(bv) >= 0 { fatal("internal: MemorySSA: cannot move a Phi to a block that already has one"); }
        mv_set(bv, a);
    }
    mssa_prepare_for_move_to(a, bv);
    mssa_insert_into_lists_for_block(a, bv, point);
}

// MemorySSA::createDefinedAccess(I, Definition, Template, CreationMustSucceed); template_kind = MAK_DEF/MAK_USE
// or -1 (no template)
fn mssa_create_defined_access(i: i32, definition: i32, template_kind: i64, must_succeed: bool) -> i32 {
    let q = aq_push(CA_SIMPLE);
    let a = mssa_create_new_access_t(i, q, template_kind);
    aq_pop(q);
    if a < 0 {
        if must_succeed { fatal("internal: MemorySSA: tried to create a memory access for a non-memory touching instruction"); }
        return -1;
    }
    if definition >= 0 && macc[definition].kind == MAK_USE { fatal("internal: MemorySSA: a use cannot be a defining access"); }
    ma_set_def(a, definition);
    return a;
}

// ---------------------------------------------------------------------------------------------
// The SSA updater

var msu_preds: i32[>..<];      // predecessor runs
var msu_ops: i32[>..<];        // PhiOps runs (TrackingVH handles)
var msu_stack: i32[>..<];      // recursePhi's Uses runs (TrackingVH handles)
var msu_check: i32[>..<];      // removeMemoryAccess's PhisToCheck / PhisToOptimize runs

fn msu_collect_preds(bv: i32) { each_pred(bv) { p => msu_preds.push(p); }; }

// BasicBlock::getUniquePredecessor
fn msu_unique_pred(bv: i32) -> i32 {
    var r: i32 = -1;
    var bad = false;
    each_pred(bv) { p => if r < 0 { r = p; } else if r != p { bad = true; } };
    return if bad { -1 } else { r };
}

fn msu_reachable(bv: i32) -> bool { dt_has_node(DT_DOM, bv) }

// CachedPreviousDef.insert({BB, Result}): no overwrite
fn msu_cache_insert(bv: i32, a: i32) { if !ms_has(MS_CACHE, bv) { ms_set(MS_CACHE, bv, vh_new(a, true)); } }

// getPreviousDefRecursive(BB, CachedPreviousDef)
recursive fn msu_prev_def_recursive(bv: i32) -> i32 {
    if ms_has(MS_CACHE, bv) { return vh_get(ms_get(MS_CACHE, bv)); }
    if !msu_reachable(bv) { return mssa_live(); }
    let up = msu_unique_pred(bv);
    if up >= 0 {
        ms_add(MS_VISITED, bv);
        let r = msu_prev_def_from_end(up);
        msu_cache_insert(bv, r);
        return r;
    }
    if ms_has(MS_VISITED, bv) {
        let r = mssa_create_phi(bv);
        msu_cache_insert(bv, r);
        return r;
    }
    ms_add(MS_VISITED, bv);
    let pmark = msu_preds.len;
    msu_collect_preds(bv);
    let np = msu_preds.len - pmark;
    let omark = msu_ops.len;
    var unique = true;
    var single: i32 = -1;
    for k in np {
        let p = msu_preds[pmark + k];
        if msu_reachable(p) {
            let inc = msu_prev_def_from_end(p);
            if single < 0 { single = inc; } else if inc != single { unique = false; }
            let h = vh_new(inc, true);
            msu_ops.push(h);
        } else {
            let h = vh_new(mssa_live(), true);
            msu_ops.push(h);
        }
    }
    var phi = mssa_access_of(bv);
    if phi >= 0 && macc[phi].kind != MAK_PHI { phi = -1; }
    var result = msu_try_remove_trivial_phi_ops(phi, omark, np);
    if result == phi && unique && single >= 0 {
        if phi >= 0 {
            if mphi_n(phi) != 0 { fatal("internal: MemorySSAUpdater: expected empty Phi"); }
            msu_rauw(phi, single);
            msu_remove_memory_access(phi, false);
        }
        result = single;
    } else if result == phi && !(unique && single >= 0) {
        if phi < 0 { phi = mssa_create_phi(bv); }
        if mphi_n(phi) != 0 {
            var same = mphi_n(phi) == np;
            if same { for k in np { if mphi_val(phi, k) != vh_get(msu_ops[omark + k]) { same = false; } } }
            if !same {
                if mphi_n(phi) < np { fatal("internal: MemorySSAUpdater: phi operand count mismatch"); }
                for k in np { mphi_set_val(phi, k, vh_get(msu_ops[omark + k])); }
                for k in np { mphi_set_blk(phi, k, msu_preds[pmark + k]); }
            }
        } else {
            for k in np { mphi_add_incoming(phi, vh_get(msu_ops[omark + k]), msu_preds[pmark + k]); }
            let h = vh_new(phi, false);
            msu_inserted.push(h);
        }
        result = phi;
    }
    ms_del(MS_VISITED, bv);
    msu_cache_insert(bv, result);
    msu_ops.resize(omark);
    msu_preds.resize(pmark);
    return result;
}

// getPreviousDefFromEnd(BB, CachedPreviousDef)
recursive fn msu_prev_def_from_end(bv: i32) -> i32 {
    let d = mb_dlast(bv);
    if d >= 0 {
        msu_cache_insert(bv, d);
        return d;
    }
    return msu_prev_def_recursive(bv);
}

// getPreviousDefInBlock(MA)
fn msu_prev_def_in_block(a: i32) -> i32 {
    let bv = macc[a].bb;
    if mb_dfirst(bv) < 0 { return -1; }
    if macc[a].kind != MAK_USE { return macc[a].dprev; }
    var x = macc[a].prev;
    while x >= 0 {
        if macc[x].kind != MAK_USE { return x; }
        x = macc[x].prev;
    }
    return -1;
}

// getPreviousDef(MA): a fresh CachedPreviousDef
fn msu_prev_def(a: i32) -> i32 {
    let l = msu_prev_def_in_block(a);
    if l >= 0 { return l; }
    ms_clear(MS_CACHE);
    return msu_prev_def_recursive(macc[a].bb);
}

// recursePhi(Phi)
recursive fn msu_recurse_phi(p: i32) -> i32 {
    if p < 0 { return -1; }
    let res = vh_new(p, true);
    let mark = msu_stack.len;
    var u = macc[p].first_use;
    while u >= 0 { let h = vh_new(muses[u].user, true); msu_stack.push(h); u = muses[u].next; }
    let n = msu_stack.len;
    var k = mark;
    while k < n {
        let x = vh_get(msu_stack[k]);
        if x >= 0 && macc[x].kind == MAK_PHI { msu_try_remove_trivial_phi(x); }
        k++;
    }
    msu_stack.resize(mark);
    return vh_get(res);
}

// tryRemoveTrivialPhi(Phi): over the phi's own operands
recursive fn msu_try_remove_trivial_phi(p: i32) -> i32 {
    if ms_has(MS_NONOPT, p) { return p; }
    var same: i32 = -1;
    for k in mphi_n(p) {
        let v = mphi_val(p, k);
        if v == p || v == same { continue; }
        if same >= 0 { return p; }
        same = v;
    }
    if same < 0 { return mssa_live(); }
    msu_rauw(p, same);
    msu_remove_memory_access(p, false);
    return msu_recurse_phi(same);
}

// tryRemoveTrivialPhi(Phi, Operands) over the TrackingVH run msu_ops[base, base + n); phi may be -1 (nullptr)
recursive fn msu_try_remove_trivial_phi_ops(p: i32, base: i64, n: i64) -> i32 {
    if p >= 0 && ms_has(MS_NONOPT, p) { return p; }
    var same: i32 = -1;
    for k in n {
        let v = vh_get(msu_ops[base + k]);
        if v == p || v == same { continue; }
        if same >= 0 { return p; }
        same = v;
    }
    if same < 0 { return mssa_live(); }
    if p >= 0 {
        msu_rauw(p, same);
        msu_remove_memory_access(p, false);
    }
    return msu_recurse_phi(same);
}

// tryRemoveTrivialPhis(ArrayRef<WeakVH>) over handles hs[from..]
fn msu_try_remove_trivial_phis(hs: const i32[:]) {
    for h in hs {
        let p = vh_get(h);
        if p >= 0 && macc[p].kind == MAK_PHI { msu_try_remove_trivial_phi(p); }
    }
}

// MemorySSAUpdater::removeMemoryAccess(MA, OptimizePhis)
recursive fn msu_remove_memory_access(a: i32, optimize_phis: bool) {
    msu_enter();
    if mssa_is_live(a) { fatal("internal: MemorySSAUpdater: trying to remove the live on entry def"); }
    var new_def: i32 = -1;
    if macc[a].kind == MAK_PHI {
        new_def = msu_only_single_value(a);
        if new_def < 0 && macc[a].first_use >= 0 { fatal("internal: MemorySSAUpdater: can't delete this memory phi"); }
    } else {
        new_def = ma_def(a);
    }
    let mark = msu_check.len;     // SmallSetVector<MemoryPhi *> PhisToCheck: a run on msu_check
    if macc[a].kind != MAK_USE && macc[a].first_use >= 0 {
        vh_rauw(a, new_def);
        if new_def == a { fatal("internal: MemorySSAUpdater: going into an infinite loop"); }
        while macc[a].first_use >= 0 {
            let u = macc[a].first_use;
            let user = muses[u].user;
            if macc[user].kind != MAK_PHI { ma_reset_optimized(user); }
            if optimize_phis && macc[user].kind == MAK_PHI {
                var seen = false;
                for j in mark..msu_check.len { if msu_check[j] == user { seen = true; } }
                if !seen { msu_check.push(user); }
            }
            msu_use_set(u, new_def);
        }
    }
    mssa_remove_from_lookups(a);
    mssa_remove_from_lists(a);
    // PhisToOptimize: WeakVHs, popped from the back
    for j in mark..msu_check.len { let h = vh_new(msu_check[j], false); msu_check[j] = h; }
    while msu_check.len > mark {
        let h = msu_check.pop();
        let p = vh_get(h);
        if p >= 0 { msu_try_remove_trivial_phi(p); }
    }
    msu_leave();
}

// removeMemoryAccess(const Instruction *I, OptimizePhis)
fn msu_remove_inst_access(i: i32, optimize_phis: bool) {
    let a = mssa_access_of(i);
    if a >= 0 { msu_remove_memory_access(a, optimize_phis); }
}

// onlySingleValue(MP)
fn msu_only_single_value(p: i32) -> i32 {
    var r: i32 = -1;
    for k in mphi_n(p) {
        let v = mphi_val(p, k);
        if r < 0 { r = v; } else if r != v { return -1; }
    }
    return r;
}

// MSSA->renamePass(BB, IncomingVal, Visited): SkipVisited and RenameAllUses
fn msu_rename_pass_from(bv: i32, incoming: i32) {
    mssa_rename_pass(mssa_fn, bv, incoming, true, true);
}

// insertUse(MU, RenameUses)
fn msu_insert_use(mu: i32, rename_uses: bool) {
    msu_enter();
    ms_clear(MS_VISITED);
    msu_inserted.clear();
    let d = msu_prev_def(mu);
    ma_set_def(mu, d);
    if rename_uses && msu_inserted.len > 0 {
        ss_clear(SS_MSSA4);
        let start = macc[mu].bb;
        var fd = mb_dfirst(start);
        if fd >= 0 {
            if macc[fd].kind == MAK_DEF { fd = ma_def(fd); }
            msu_rename_pass_from(start, fd);
        }
        for k in msu_inserted.len {
            let p = vh_get(msu_inserted[k]);
            if p >= 0 { msu_rename_pass_from(macc[p].bb, -1); }
        }
    }
    msu_leave();
}

// setMemoryPhiValueForBlock(MP, BB, NewDef)
fn msu_set_phi_value_for_block(mp: i32, bb: i32, nd: i32) {
    var i = mphi_block_index(mp, bb);
    if i < 0 { fatal("internal: MemorySSAUpdater: should have found the basic block in the phi"); }
    while i < mphi_n(mp) {
        if mphi_blk(mp, i) != bb { break; }
        mphi_set_val(mp, i, nd);
        i++;
    }
}

fn msu_in_inserted(p: i32) -> bool {
    for h in msu_inserted { if vh_get(h) == p { return true; } }
    return false;
}

// insertDef(MD, RenameUses)
fn msu_insert_def(md: i32, rename_uses: bool) {
    msu_enter();
    let fv = mssa_fn;
    if !msu_reachable(macc[md].bb) {
        ma_set_def(md, mssa_live());
        msu_leave();
        return;
    }
    ms_clear(MS_VISITED);
    msu_inserted.clear();
    let def_before = msu_prev_def(md);
    var same_block = false;
    if macc[def_before].bb == macc[md].bb && !(macc[def_before].kind == MAK_PHI && msu_in_inserted(def_before)) {
        same_block = true;
    }
    if same_block {
        // DefBefore->replaceUsesWithIf(MD, [](Use &U) { !isa<MemoryUse>(U.getUser()) && U.getUser() != MD })
        var u = macc[def_before].first_use;
        while u >= 0 {
            let nu = muses[u].next;
            let usr = muses[u].user;
            if macc[usr].kind != MAK_USE && usr != md { msu_use_set(u, md); }
            u = nu;
        }
    }
    ma_set_def(md, def_before);
    var fixup: i32[>..<] = [];       // FixupList (WeakVH)
    for h in msu_inserted { fixup.push(vh_new(vh_get(h), false)); }
    var existing: i32[>..<] = [];    // ExistingPhis (SmallSet<WeakVH, 8>, in insertion order)
    var new_phi_index = msu_inserted.len;
    if !same_block {
        var defb: i32[>..<] = [];
        ms_clear(MS_TMP);
        ms_add(MS_TMP, macc[md].bb);
        defb.push(macc[md].bb);
        for h in msu_inserted {
            let p = vh_get(h);
            if p >= 0 && macc[p].kind == MAK_PHI && ms_add(MS_TMP, macc[p].bb) { defb.push(macc[p].bb); }
        }
        var idf: i32[>..<] = [];
        mssa_idf(fv, defb, idf, false, 0);
        var new_inserted: i32[>..<] = [];
        for bb in idf {
            var mp = mssa_access_of(bb);
            if mp < 0 {
                mp = mssa_create_phi(bb);
                new_inserted.push(mp);
            } else {
                var dup = false;
                for h in existing { if vh_get(h) == mp { dup = true; } }
                if !dup { existing.push(vh_new(mp, false)); }
            }
            ms_add(MS_NONOPT, mp);
        }
        for mp in new_inserted {
            let bb = macc[mp].bb;
            let pmark = msu_preds.len;
            msu_collect_preds(bb);
            let np = msu_preds.len - pmark;
            for k in np {
                let p = msu_preds[pmark + k];
                ms_clear(MS_CACHE);
                let d = msu_prev_def_from_end(p);
                mphi_add_incoming(mp, d, p);
            }
            msu_preds.resize(pmark);
        }
        new_phi_index = msu_inserted.len;
        for mp in new_inserted {
            msu_inserted.push(vh_new(mp, false));
            fixup.push(vh_new(mp, false));
        }
        fixup.push(vh_new(md, false));
    }
    let new_phi_index_end = msu_inserted.len;
    msu_fixup_defs(fixup);
    if new_phi_index_end != msu_inserted.len { fatal("internal: MemorySSAUpdater: should not insert new phis during fixupDefs()"); }
    if new_phi_index_end > new_phi_index {
        var hs: i32[>..<] = [];
        for k in new_phi_index..new_phi_index_end { hs.push(msu_inserted[k]); }
        msu_try_remove_trivial_phis(hs);
    }
    if rename_uses {
        ss_clear(SS_MSSA4);
        let start = macc[md].bb;
        var fd = mb_dfirst(start);
        if macc[fd].kind == MAK_DEF { fd = ma_def(fd); }
        msu_rename_pass_from(start, fd);
        for k in msu_inserted.len {
            let p = vh_get(msu_inserted[k]);
            if p >= 0 && macc[p].kind == MAK_PHI { msu_rename_pass_from(macc[p].bb, -1); }
        }
        for h in existing {
            let p = vh_get(h);
            if p >= 0 && macc[p].kind == MAK_PHI { msu_rename_pass_from(macc[p].bb, -1); }
        }
    }
    msu_leave();
}

// fixupDefs(const SmallVectorImpl<WeakVH> &Vars)
fn msu_fixup_defs(vars: const i32[:]) {
    ms_clear(MS_SEEN);
    var wl: i32[>..<] = [];
    for h in vars {
        let nd = vh_get(h);
        if nd < 0 { continue; }
        if macc[nd].kind == MAK_PHI { ms_del(MS_NONOPT, nd); }
        let nx = macc[nd].dnext;
        if nx >= 0 {
            ma_set_def(nx, nd);
            continue;
        }
        let nb = macc[nd].bb;
        for k in block_nsucc(nb) {
            let s = block_succ(nb, k);
            let mp = mssa_access_of(s);
            if mp >= 0 { msu_set_phi_value_for_block(mp, nb, nd); } else { wl.push(s); }
        }
        while wl.len > 0 {
            let fb = wl.pop();
            let fd = mb_dfirst(fb);
            if fd >= 0 {
                if macc[fd].kind == MAK_PHI { fatal("internal: MemorySSAUpdater: should have already handled phi nodes"); }
                ma_set_def(fd, nd);
                continue;
            }
            for k in block_nsucc(fb) {
                let s = block_succ(fb, k);
                let mp = mssa_access_of(s);
                if mp >= 0 { msu_set_phi_value_for_block(mp, fb, nd); }
                else {
                    if !ms_add(MS_SEEN, s) { continue; }
                    wl.push(s);
                }
            }
        }
    }
}

// removeEdge(From, To)
fn msu_remove_edge(from: i32, to: i32) {
    msu_enter();
    let mp = mssa_access_of(to);
    if mp >= 0 {
        mphi_unordered_delete_incoming_block(mp, from);
        msu_try_remove_trivial_phi(mp);
    }
    msu_leave();
}

// removeDuplicatePhiEdgesBetween(From, To)
fn msu_remove_duplicate_phi_edges_between(from: i32, to: i32) {
    msu_enter();
    let mp = mssa_access_of(to);
    if mp >= 0 {
        var found = false;
        var i: i64 = 0;
        while i < mphi_n(mp) {
            if mphi_blk(mp, i) == from {
                if found { mphi_unordered_delete_incoming(mp, i); continue; }
                found = true;
            }
            i++;
        }
        msu_try_remove_trivial_phi(mp);
    }
    msu_leave();
}

// applyUpdates(Updates, DT, UpdateDT)
fn msu_apply_updates(fv: i32, ups: const DTUpdate[:], update_dt: bool) {
    msu_enter();
    var dels: DTUpdate[>..<] = [];
    var rev_dels: DTUpdate[>..<] = [];
    var ins: DTUpdate[>..<] = [];
    for u in ups {
        if u.kind == DT_INSERT { ins.push(u); }
        else {
            dels.push(u);
            rev_dels.push(DTUpdate { kind: DT_INSERT, from: u.from, to: u.to });
        }
    }
    if dels.len > 0 {
        if ins.len > 0 {
            if !update_dt {
                var empty: DTUpdate[>..<] = [];
                dt_apply_updates_post_view(fv, DT_DOM, empty, rev_dels);
            } else {
                dt_apply_updates_post_view(fv, DT_DOM, ups, rev_dels);
            }
            gd_init(2, rev_dels, false, false);
            msu_apply_insert_updates_gd(fv, ins);
            dt_apply_updates(fv, DT_DOM, dels);
        } else {
            if update_dt { dt_apply_updates(fv, DT_DOM, dels); }
        }
    } else {
        if update_dt { dt_apply_updates(fv, DT_DOM, ups); }
        var empty: DTUpdate[>..<] = [];
        gd_init(2, empty, false, false);
        msu_apply_insert_updates_gd(fv, ins);
    }
    for u in dels { msu_remove_edge(u.from, u.to); }
    msu_leave();
}

// applyInsertUpdates(Updates, DT): with an empty GraphDiff
fn msu_apply_insert_updates(fv: i32, ups: const DTUpdate[:]) {
    msu_enter();
    var empty: DTUpdate[>..<] = [];
    gd_init(2, empty, false, false);
    msu_apply_insert_updates_gd(fv, ups);
    msu_leave();
}

// GetLastDef in applyInsertUpdates (GraphDiff instance 2)
fn msu_get_last_def(bv0: i32) -> i32 {
    var bv = bv0;
    var ch: i32[>..<] = [];
    loop {
        let d = mb_dlast(bv);
        if d >= 0 { return d; }
        gd_children(2, bv, true, ch);
        let count = min(ch.len, 2);
        if count != 1 {
            if !dt_has_node(DT_DOM, bv) { return mssa_live(); }
            let id = dt_idom(DT_DOM, bv);
            if id >= 0 && id != bv { bv = id; continue; }
            return mssa_live();
        } else {
            if !dt_has_node(DT_DOM, bv) { return mssa_live(); }
            bv = ch[0];
        }
    }
    return mssa_live();
}

struct MPredInfo { bb: i32, added_at: i32, nadded: i32, prev_at: i32, nprev: i32, removed: bool }
struct MEdgeCount { from: i32, to: i32, n: i32 }

// applyInsertUpdates(Updates, DT, GD) with GD = GraphDiff instance 2. PredMap (a pointer-keyed SmallDenseMap in
// LLVM) is iterated in first-insertion order.
fn msu_apply_insert_updates_gd(fv: i32, ups: const DTUpdate[:]) {
    var pmap: MPredInfo[>..<] = [];
    var pool: i32[>..<] = [];       // the Added / Prev sets of each entry (Added first, built before Prev)
    fn find_pi(b: i32) -> i64 { for k in pmap.len { if pmap[k].bb == b && !pmap[k].removed { return k; } } return -1; }
    // Added sets: collected per block in update order
    var order: i32[>..<] = [];
    for e in ups {
        if find_pi(e.to) < 0 { pmap.push(MPredInfo { bb: e.to, added_at: 0, nadded: 0, prev_at: 0, nprev: 0, removed: false }); order.push(e.to); }
    }
    for k in pmap.len {
        pmap[k].added_at = pool.len as i32;
        for e in ups {
            if e.to != pmap[k].bb { continue; }
            var dup = false;
            for j in pmap[k].nadded { if pool[(pmap[k].added_at as i64) + j] == e.from { dup = true; } }
            if !dup { pool.push(e.from); pmap[k].nadded += 1; }
        }
    }
    var ecount: MEdgeCount[>..<] = [];
    fn edge_count(f: i32, t: i32) -> i64 { for x in ecount { if x.from == f && x.to == t { return x.n; } } return 0; }
    fn edge_inc(f: i32, t: i32) {
        for k in ecount.len { if ecount[k].from == f && ecount[k].to == t { ecount[k].n += 1; return; } }
        ecount.push(MEdgeCount { from: f, to: t, n: 1 });
    }
    fn in_added(k: i64, b: i32) -> bool { for j in pmap[k].nadded { if pool[(pmap[k].added_at as i64) + j] == b { return true; } } return false; }
    var ch: i32[>..<] = [];
    for k in pmap.len {
        let bb = pmap[k].bb;
        pmap[k].prev_at = pool.len as i32;
        gd_children(2, bb, true, ch);
        for pi in ch {
            if !in_added(k, pi) {
                var dup = false;
                for j in pmap[k].nprev { if pool[(pmap[k].prev_at as i64) + j] == pi { dup = true; } }
                if !dup { pool.push(pi); pmap[k].nprev += 1; }
            }
            edge_inc(pi, bb);
        }
    }
    for k in pmap.len {
        if pmap[k].nprev == 0 {
            if pmap[k].nadded != 1 { fatal("internal: MemorySSAUpdater: can only handle adding one predecessor to a new block"); }
            pmap[k].removed = true;
        }
    }
    var bwdr: i32[>..<] = [];        // BlocksWithDefsToReplace
    var inserted: i32[>..<] = [];    // InsertedPhis (WeakVH)
    for e in ups {
        if find_pi(e.to) >= 0 && mssa_access_of(e.to) < 0 { let p = mssa_create_phi(e.to); inserted.push(vh_new(p, false)); }
    }
    var last_added: i32[>..<] = [];
    for k in pmap.len {
        if pmap[k].removed { continue; }
        let bb = pmap[k].bb;
        if pmap[k].nprev == 0 { fatal("internal: MemorySSAUpdater: at least one previous predecessor must exist"); }
        last_added.clear();
        for j in pmap[k].nadded { last_added.push(msu_get_last_def(pool[(pmap[k].added_at as i64) + j])); }
        let np = mssa_access_of(bb);
        if mphi_n(np) > 0 {
            for j in pmap[k].nadded {
                let p = pool[(pmap[k].added_at as i64) + j];
                for c in edge_count(p, bb) { mphi_add_incoming(np, last_added[j], p); }
            }
        } else {
            let p1 = pool[pmap[k].prev_at];
            let def_p1 = msu_get_last_def(p1);
            var insert_phi = false;
            for x in last_added { if def_p1 != x { insert_phi = true; } }
            if !insert_phi {
                msu_rauw(np, def_p1);
                msu_remove_memory_access(np, false);
                continue;
            }
            for j in pmap[k].nadded {
                let p = pool[(pmap[k].added_at as i64) + j];
                for c in edge_count(p, bb) { mphi_add_incoming(np, last_added[j], p); }
            }
            for j in pmap[k].nprev {
                let p = pool[(pmap[k].prev_at as i64) + j];
                for c in edge_count(p, bb) { mphi_add_incoming(np, def_p1, p); }
            }
        }
        // FindNearestCommonDominator(PrevBlockSet)
        var prev_idom = pool[pmap[k].prev_at];
        for j in pmap[k].nprev { prev_idom = dt_find_ncd(DT_DOM, prev_idom, pool[(pmap[k].prev_at as i64) + j]); }
        let new_idom = dt_idom(DT_DOM, bb);
        // GetNoLongerDomBlocks(PrevIDom, NewIDom)
        if prev_idom != new_idom {
            bwdr.push(prev_idom);
            var nxt = prev_idom;
            loop {
                let up = dt_idom(DT_DOM, nxt);
                if up < 0 || up == new_idom { break; }
                bwdr.push(up);
                nxt = up;
            }
        }
    }
    msu_try_remove_trivial_phis(inserted);
    var to_process: i32[>..<] = [];
    for h in inserted { let p = vh_get(h); if p >= 0 && macc[p].kind == MAK_PHI { to_process.push(macc[p].bb); } }
    if to_process.len > 0 {
        var idf: i32[>..<] = [];
        mssa_idf(fv, to_process, idf, true, 2);
        ms_clear(MS_TMP2);       // PhisToFill
        for bb in idf {
            if mssa_access_of(bb) < 0 {
                let p = mssa_create_phi(bb);
                inserted.push(vh_new(p, false));
                ms_add(MS_TMP2, p);
            }
        }
        for bb in idf {
            let p = mssa_access_of(bb);
            if p < 0 { fatal("internal: MemorySSAUpdater: phi must exist"); }
            if !ms_has(MS_TMP2, p) {
                for i in mphi_n(p) { let d = msu_get_last_def(mphi_blk(p, i)); mphi_set_val(p, i, d); }
            } else {
                gd_children(2, bb, true, ch);
                for pi in ch { let d = msu_get_last_def(pi); mphi_add_incoming(p, d, pi); }
            }
        }
    }
    var reset: i32[>..<] = [];
    for bw in bwdr {
        var d = mb_dfirst(bw);
        while d >= 0 {
            let dominating = macc[d].bb;
            reset.clear();
            var u = macc[d].first_use;
            while u >= 0 {
                let nu = muses[u].next;
                let usr = muses[u].user;
                if macc[usr].kind == MAK_PHI {
                    let dominated = mphi_blk(usr, muses[u].slot as i64);
                    if !dt_dominates_block(DT_DOM, dominating, dominated) { msu_use_set(u, msu_get_last_def(dominated)); }
                } else {
                    let dominated = macc[usr].bb;
                    if !dt_dominates_block(DT_DOM, dominating, dominated) {
                        let dp = mssa_access_of(dominated);
                        if dp >= 0 { msu_use_set(u, dp); }
                        else {
                            let id = dt_idom(DT_DOM, dominated);
                            if id < 0 { fatal("internal: MemorySSAUpdater: block must have a valid IDom"); }
                            msu_use_set(u, msu_get_last_def(id));
                        }
                        reset.push(usr);
                    }
                }
                u = nu;
            }
            for x in reset { ma_reset_optimized(x); }
            d = macc[d].dnext;
        }
    }
    msu_try_remove_trivial_phis(inserted);
}

// moveTo(What, BB, Where): where_place < 0: before access `where` (-1 = end); else the InsertionPlace
fn msu_move_to(what: i32, bv: i32, where: i32, where_place: i64) {
    msu_enter();
    var u = macc[what].first_use;
    while u >= 0 {
        let usr = muses[u].user;
        if macc[usr].kind == MAK_PHI { ms_add(MS_NONOPT, usr); }
        u = muses[u].next;
    }
    msu_rauw(what, ma_def(what));
    if where_place >= 0 { mssa_move_to_place(what, bv, where_place); } else { mssa_move_to_before(what, bv, where); }
    if macc[what].kind == MAK_DEF { msu_insert_def(what, true); } else { msu_insert_use(what, true); }
    ms_clear(MS_NONOPT);
    msu_leave();
}
// moveBefore(What, Where)
fn msu_move_before(what: i32, where: i32) { msu_move_to(what, macc[where].bb, where, -1); }
// moveAfter(What, Where)
fn msu_move_after(what: i32, where: i32) { msu_move_to(what, macc[where].bb, macc[where].next, -1); }
// moveToPlace(What, BB, Where)
fn msu_move_to_place(what: i32, bv: i32, place: i64) {
    if place != MSP_BEFORE_TERMINATOR { msu_move_to(what, bv, -1, place); return; }
    let t = block_terminator(bv);
    let w = if t >= 0 { mssa_access_of(t) } else { -1 };
    if w >= 0 { msu_move_before(what, w); } else { msu_move_to(what, bv, -1, MSP_END); }
}

// moveAllAccesses(From, To, Start)
fn msu_move_all_accesses(from: i32, to: i32, start: i32) {
    if mb_first(from) < 0 { return; }
    if inst_parent(start) != to { fatal("internal: MemorySSAUpdater: incorrect Start instruction"); }
    var first: i32 = -1;
    var i = start;
    while i >= 0 {
        first = mssa_access_of(i);
        if first >= 0 { break; }
        i = inst_next(i);
    }
    if first >= 0 {
        var mud = first;
        while mud >= 0 {
            let nx = macc[mud].next;
            mssa_move_to_place(mud, to, MSP_END);
            mud = nx;
        }
    }
    let d = mb_dfirst(from);
    if d >= 0 && macc[d].kind == MAK_PHI { msu_try_remove_trivial_phi(d); }
}
// moveAllAfterSpliceBlocks(From, To, Start)
fn msu_move_all_after_splice_blocks(from: i32, to: i32, start: i32) {
    msu_enter();
    if mb_first(to) >= 0 { fatal("internal: MemorySSAUpdater: To block is expected to be free of MemoryAccesses"); }
    msu_move_all_accesses(from, to, start);
    for k in block_nsucc(to) {
        let mp = mssa_access_of(block_succ(to, k));
        if mp >= 0 { mphi_set_blk(mp, mphi_block_index(mp, from), to); }
    }
    msu_leave();
}
// moveAllAfterMergeBlocks(From, To, Start)
fn msu_move_all_after_merge_blocks(from: i32, to: i32, start: i32) {
    msu_enter();
    msu_move_all_accesses(from, to, start);
    for k in block_nsucc(from) {
        let mp = mssa_access_of(block_succ(from, k));
        if mp >= 0 { mphi_set_blk(mp, mphi_block_index(mp, from), to); }
    }
    msu_leave();
}

// wireOldPredecessorsToNewImmediatePredecessor(Old, New, Preds, IdenticalEdgesWereMerged)
fn msu_wire_old_preds_to_new_pred(old: i32, nw: i32, preds: const i32[:], identical_merged: bool) {
    msu_enter();
    if mb_first(nw) >= 0 { fatal("internal: MemorySSAUpdater: access list should be null for a new block"); }
    let phi = mssa_access_of(old);
    if phi >= 0 {
        if pred_count(old) == 1 {
            mssa_move_to_place(phi, nw, MSP_BEGINNING);
        } else {
            let np = mssa_create_phi(nw);
            var set: i32[>..<] = [];
            for p in preds { var dup = false; for x in set { if x == p { dup = true; } } if !dup { set.push(p); } }
            var i: i64 = 0;
            while i < mphi_n(phi) {
                let b = mphi_blk(phi, i);
                var k: i64 = -1;
                for j in set.len { if set[j] == b { k = j; break; } }
                if k >= 0 {
                    mphi_add_incoming(np, mphi_val(phi, i), b);
                    if !identical_merged {
                        var w = k;
                        while w + 1 < set.len { set[w] = set[w + 1]; w++; }
                        set.pop();
                    }
                    mphi_unordered_delete_incoming(phi, i);
                    continue;
                }
                i++;
            }
            mphi_add_incoming(phi, np, nw);
            msu_try_remove_trivial_phi(np);
        }
    }
    msu_leave();
}

// updatePhisWhenInsertingUniqueBackedgeBlock(Header, Preheader, BEBlock)
fn msu_update_phis_unique_backedge(header: i32, preheader: i32, be: i32) {
    msu_enter();
    let mp = mssa_access_of(header);
    if mp >= 0 {
        let np = mssa_create_phi(be);
        for i in mphi_n(mp) {
            let ibb = mphi_blk(mp, i);
            let iv = mphi_val(mp, i);
            if ibb != preheader { mphi_add_incoming(np, iv, ibb); }
        }
        let acc = mphi_value_for_block(mp, preheader);
        mphi_set_val(mp, 0, acc);
        mphi_set_blk(mp, 0, preheader);
        var i = mphi_n(mp) - 1;
        while i >= 1 { mphi_unordered_delete_incoming(mp, i); i--; }
        mphi_add_incoming(mp, np, be);
        msu_try_remove_trivial_phi(np);
    }
    msu_leave();
}

// removeBlocks(DeadBlocks)
fn msu_remove_blocks(dead: const i32[:]) {
    msu_enter();
    fn is_dead(b: i32) -> bool { for d in dead { if d == b { return true; } } return false; }
    for bb in dead {
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if is_dead(s) { continue; }
            let mp = mssa_access_of(s);
            if mp >= 0 {
                mphi_unordered_delete_incoming_block(mp, bb);
                msu_try_remove_trivial_phi(mp);
            }
        }
        var a = mb_first(bb);
        while a >= 0 { ma_drop_all_references(a); a = macc[a].next; }
    }
    for bb in dead {
        var a = mb_first(bb);
        while a >= 0 {
            let nx = macc[a].next;
            mssa_remove_from_lookups(a);
            mssa_remove_from_lists(a);
            a = nx;
        }
    }
    msu_leave();
}

// changeToUnreachable(I)
fn msu_change_to_unreachable(i: i32) {
    msu_enter();
    let bb = inst_parent(i);
    var x = i;
    while x >= 0 { let nx = inst_next(x); msu_remove_inst_access(x, false); x = nx; }
    var updated: i32[>..<] = [];
    for k in block_nsucc(bb) {
        let s = block_succ(bb, k);
        msu_remove_duplicate_phi_edges_between(bb, s);
        let mp = mssa_access_of(s);
        if mp >= 0 {
            mphi_unordered_delete_incoming_block(mp, bb);
            updated.push(vh_new(mp, false));
        }
    }
    msu_try_remove_trivial_phis(updated);
    msu_leave();
}

// createMemoryAccessInBB(I, Definition, BB, Point, CreationMustSucceed)
fn msu_create_access_in_bb(i: i32, definition: i32, bv: i32, point: i64, must_succeed: bool) -> i32 {
    let a = mssa_create_defined_access(i, definition, -1, must_succeed);
    if a >= 0 { mssa_insert_into_lists_for_block(a, bv, point); }
    return a;
}
// createMemoryAccessBefore(I, Definition, InsertPt)
fn msu_create_access_before(i: i32, definition: i32, insert_pt: i32) -> i32 {
    let a = mssa_create_defined_access(i, definition, -1, true);
    mssa_insert_into_lists_before(a, macc[insert_pt].bb, insert_pt);
    return a;
}
// createMemoryAccessAfter(I, Definition, InsertPt)
fn msu_create_access_after(i: i32, definition: i32, insert_pt: i32) -> i32 {
    let a = mssa_create_defined_access(i, definition, -1, true);
    mssa_insert_into_lists_before(a, macc[insert_pt].bb, macc[insert_pt].next);
    return a;
}

// ---------------------------------------------------------------------------------------------
// Cloning (LoopRotate): the ValueToValueMapTy is the value map slot msu_vmap of irutil's vm_* maps (value id ->
// value id); PhiToDefMap is MS_TMP (phi access -> access).

var msu_vmap: i64 = 0;
var msu_region: i32 = -1;   // updateForClonedBlockIntoPred: IsInClonedRegion(BB) = BB == region

fn msu_vmap_lookup(v: i32) -> i32 { vm_get(msu_vmap, v, -1) as i32 }

// getNewDefiningAccessForClone(MA, VMap, MPhiMap, MSSA, IsInClonedRegion)
recursive fn msu_new_defining_access_for_clone(a: i32) -> i32 {
    var d = a;
    if macc[a].kind == MAK_DEF || macc[a].kind == MAK_LIVE {
        if mssa_is_live(a) { return a; }
        let di = macc[a].inst;
        if inst_parent(di) != msu_region { return a; }
        let ni = msu_vmap_lookup(di);
        d = if ni >= 0 && is_inst(ni) { mssa_access_of(ni) } else { -1 };
        if d < 0 || macc[d].kind == MAK_USE { d = msu_new_defining_access_for_clone(ma_def(a)); }
    } else {
        if ms_has(MS_TMP, a) { d = ms_get(MS_TMP, a); }
    }
    if d < 0 { fatal("internal: MemorySSAUpdater: defining instruction cannot be nullptr"); }
    return d;
}

// cloneUsesAndDefs(BB, NewBB, VMap, MPhiMap, IsInClonedRegion, CloneWasSimplified)
fn msu_clone_uses_and_defs(bv: i32, nbv: i32, clone_was_simplified: bool) {
    var a = mb_first(bv);
    while a >= 0 {
        let nx = macc[a].next;
        if macc[a].kind != MAK_PHI {
            let ni = msu_vmap_lookup(macc[a].inst);
            if ni >= 0 && is_inst(ni) {
                let tk: i64 = if clone_was_simplified { -1 } else { macc[a].kind as i64 };
                let nd = msu_new_defining_access_for_clone(ma_def(a));
                let na = mssa_create_defined_access(ni, nd, tk, false);
                if na >= 0 { mssa_insert_into_lists_for_block(na, nbv, MSP_END); }
            }
        }
        a = nx;
    }
}

// updateForClonedBlockIntoPred(BB, P1, VM): VM in vm slot vmap
fn msu_update_for_cloned_block_into_pred(bv: i32, p1: i32, vmap: i64) {
    msu_enter();
    msu_vmap = vmap;
    msu_region = bv;
    ms_clear(MS_TMP);
    let mp = mssa_access_of(bv);
    if mp >= 0 { ms_set(MS_TMP, mp, mphi_value_for_block(mp, p1)); }
    msu_clone_uses_and_defs(bv, p1, true);
    msu_leave();
}

// ---------------------------------------------------------------------------------------------
// MemorySSA::verifyMemorySSA (Fast level): fails loudly on an inconsistency. LLVM compiles it out of release
// builds, so nothing here may change any state that output depends on (no DT queries that count slow queries).

fn mv_fail(fv: i32, what: const u8[:]) { fatal(str("MemorySSA verification failed in function ", val_name(fv), ": ", what)); }

// block dominance without touching the tree's query counters
fn mv_dominates_block(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if !dt_has_node(DT_DOM, b) { return true; }
    if !dt_has_node(DT_DOM, a) { return false; }
    var x = b;
    while x >= 0 {
        if x == a { return true; }
        x = dt_idom(DT_DOM, x);
    }
    return false;
}
fn mv_locally_dominates(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if mssa_is_live(b) { return false; }
    if mssa_is_live(a) { return true; }
    var x = macc[a].next;
    while x >= 0 { if x == b { return true; } x = macc[x].next; }
    return false;
}
fn mv_dominates(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if mssa_is_live(b) { return false; }
    if macc[a].bb != macc[b].bb { return mv_dominates_block(macc[a].bb, macc[b].bb); }
    return mv_locally_dominates(a, b);
}
// MemorySSA::dominates(MA, const Use &)
fn mv_dominates_use(a: i32, u: i32) -> bool {
    let usr = muses[u].user;
    if macc[usr].kind == MAK_PHI {
        let ubb = mphi_blk(usr, muses[u].slot as i64);
        if ubb != macc[a].bb { return mv_dominates_block(macc[a].bb, ubb); }
        return true;   // locallyDominates(MA, cast<MemoryAccess>(Use)) casts the use to its value (MA)
    }
    return mv_dominates(a, usr);
}

fn mssa_verify(fv: i32) {
    if !mssa_valid(fv) { return; }
    var actual: i32[>..<] = [];
    var actual_defs: i32[>..<] = [];
    var b = func_entry(fv);
    while b >= 0 {
        actual.clear();
        actual_defs.clear();
        let phi = mssa_access_of(b);
        if phi >= 0 {
            if macc[phi].kind != MAK_PHI || macc[phi].bb != b { mv_fail(fv, "block maps to an access that is not its phi"); }
            actual.push(phi);
            actual_defs.push(phi);
            var u = macc[phi].first_use;
            while u >= 0 { if !mv_dominates_use(phi, u) { mv_fail(fv, "Memory PHI does not dominate it's uses"); } u = muses[u].next; }
        }
        var i = block_first(b);
        while i >= 0 {
            let a = mssa_access_of(i);
            if a >= 0 {
                if macc[a].inst != i || macc[a].bb != b { mv_fail(fv, "access of an instruction is in the wrong place"); }
                actual.push(a);
                if macc[a].kind == MAK_DEF {
                    actual_defs.push(a);
                    var u = macc[a].first_use;
                    while u >= 0 { if !mv_dominates_use(a, u) { mv_fail(fv, "Memory Def does not dominate it's uses"); } u = muses[u].next; }
                }
                if macc[a].def < 0 { mv_fail(fv, "access without a defining access"); }
            }
            i = inst_next(i);
        }
        var n: i64 = 0;
        var x = mb_first(b);
        while x >= 0 {
            if n >= actual.len || actual[n] != x { mv_fail(fv, "not the same accesses in the same order"); }
            if macc[x].bb != b { mv_fail(fv, "access list entry with the wrong block"); }
            n++;
            x = macc[x].next;
        }
        if n != actual.len { mv_fail(fv, "we don't have the same number of accesses in the block as on the access list"); }
        n = 0;
        x = mb_dfirst(b);
        while x >= 0 {
            if n >= actual_defs.len || actual_defs[n] != x { mv_fail(fv, "not the same defs in the same order"); }
            n++;
            x = macc[x].dnext;
        }
        if n != actual_defs.len { mv_fail(fv, "we don't have the same number of defs in the block as on the def list"); }
        b = block_next(b);
    }
}
