// MemorySSAUpdater: port of the removal part of llvm/lib/Analysis/MemorySSAUpdater.cpp (removeMemoryAccess,
// tryRemoveTrivialPhi, recursePhi, onlySingleValue) and of MemorySSA::removeFromLookups /
// MemorySSA::removeFromLists (llvm/lib/Analysis/MemorySSA.cpp). Insertion (createMemoryAccess*, insertUse,
// insertDef with phi placement), moves, block removal and the clone updates are not ported yet (LICM, DSE,
// MemCpyOpt and the loop passes need them; add them here).
//
// A deleted access gets kind MAK_DEAD (ids are never reused), so WeakVH-style lists can test msu_is_dead.
// TrackingVH-style lists follow msu_repl (the access a MemoryAccess was RAUW'd with).
import std;
import ir;
import irutil;
import memoryssa;

let MAK_DEAD: u8 = 4;

// NonOptPhis: phis the updater must not optimize (filled by insertDef in LLVM; empty for now)
var msu_repl: i32[>..<];

fn msu_is_dead(a: i32) -> bool { macc[a].kind == MAK_DEAD }

fn msu_set_repl(a: i32, nw: i32) {
    while msu_repl.len < macc.len { msu_repl.push(-1); }
    msu_repl[a] = nw;
}
// TrackingVH: follow RAUWs
fn msu_track(a0: i32) -> i32 {
    var a = a0;
    while (a as i64) < msu_repl.len && msu_repl[a] >= 0 { a = msu_repl[a]; }
    return a;
}
fn msu_reset() { msu_repl.clear(); }

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
    msu_set_repl(a, nw);
    while macc[a].first_use >= 0 { msu_use_set(macc[a].first_use, nw); }
}

// MemorySSA::removeFromLookups
fn mssa_remove_from_lookups(a: i32) {
    if macc[a].kind != MAK_PHI { ma_set_def(a, -1); }
    // getWalker()->invalidateInfo(MA)
    if macc[a].kind != MAK_USE && macc[a].kind != MAK_PHI { ma_reset_optimized(a); }
    let key = if macc[a].kind == MAK_PHI { macc[a].bb } else { macc[a].inst };
    if mssa_access_of(key) == a { mv_set(key, -1); }
}

// MemorySSA::removeFromLists(MA, ShouldDelete = true)
fn mssa_remove_from_lists(a: i32) {
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
    // deleting the access drops its operands
    if macc[a].kind == MAK_PHI {
        for k in mphi_n(a) { mu_unlink(mphi_u[(macc[a].pat as i64) + k]); }
    } else {
        if macc[a].u0 >= 0 { mu_unlink(macc[a].u0); }
        if macc[a].u1 >= 0 { mu_unlink(macc[a].u1); }
    }
    macc[a].kind = MAK_DEAD;
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

// MemorySSAUpdater::removeMemoryAccess(MA, OptimizePhis)
recursive fn msu_remove_memory_access(a: i32, optimize_phis: bool) {
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
        msu_set_repl(a, new_def);
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
    // WeakVH list, popped from the back
    while msu_check.len > mark {
        let p = msu_check.pop();
        if !msu_is_dead(p) { msu_try_remove_trivial_phi(p); }
    }
}

// removeMemoryAccess(const Instruction *I, OptimizePhis)
fn msu_remove_inst_access(i: i32, optimize_phis: bool) {
    let a = mssa_access_of(i);
    if a >= 0 { msu_remove_memory_access(a, optimize_phis); }
}

// MemorySSAUpdater::tryRemoveTrivialPhi(Phi)
recursive fn msu_try_remove_trivial_phi(p: i32) -> i32 {
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

// MemorySSAUpdater::recursePhi
recursive fn msu_recurse_phi(p: i32) -> i32 {
    if p < 0 { return -1; }
    let mark = msu_stack.len;
    var u = macc[p].first_use;
    while u >= 0 { msu_stack.push(muses[u].user); u = muses[u].next; }
    let n = msu_stack.len;
    var k = mark;
    while k < n {
        let x = msu_track(msu_stack[k]);
        if x >= 0 && !msu_is_dead(x) && macc[x].kind == MAK_PHI { msu_try_remove_trivial_phi(x); }
        k++;
    }
    msu_stack.resize(mark);
    return msu_track(p);
}
var msu_stack: i32[>..<];
var msu_check: i32[>..<];
