// AliasSetTracker: port of llvm/lib/Analysis/AliasSetTracker.cpp and llvm/include/llvm/Analysis/AliasSetTracker.h
// (AliasSet::mergeSetIn, addMemoryLocation, addUnknownInst, aliasesMemoryLocation, aliasesUnknownInst,
// AliasSetTracker::removeAliasSet, mergeAliasSetsForMemoryLocation, findAliasSetForUnknownInst, getAliasSetFor,
// add(LoadInst / StoreInst / Instruction) for what LICM's collectPromotionCandidates adds, addUnknown,
// mergeAllAliasSets, addMemoryLocation, collapseForwardingIn, the reference counts) over one BatchAAResults.
// Not ported (fail loudly): add() of va_arg, memset, memtransfer and argmemonly calls (LICM only adds loads and
// stores), print.
//
// One tracker at a time. Alias sets are ids into ast_sets in creation order (the ilist order); a removed set is
// marked dead and skipped. Each set's MemoryLocs and UnknownInsts are runs in a pool, copied to the end when they
// grow.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import flags;
import memloc;
import aa;
import memoryssa;

let AS_NO_ACCESS: u8 = 0;
let AS_REF: u8 = 1;
let AS_MOD: u8 = 2;
let AS_MODREF: u8 = 3;

struct AliasSetRec { fwd: i32, refc: i32, alias_any: bool, access: u8, may: bool,
              ml_at: i32, ml_n: i32, ml_cap: i32, un_at: i32, un_n: i32, un_cap: i32, dead: bool }
var ast_sets: AliasSetRec[>..<];
var ast_mls: ML[>..<];
var ast_unk: i32[>..<];
var ast_total: i64 = 0;          // TotalAliasSetSize
var ast_any: i32 = -1;           // AliasAnyAS
var ast_q: i32 = -1;             // the BatchAAResults
var ast_pm_stamp: i32[>..];      // PointerMap: value id -> alias set
var ast_pm_val: i32[>..];
var ast_pm_epoch: i32 = 1;

fn ast_reset(q: i32) {
    ast_sets.clear();
    ast_mls.clear();
    ast_unk.clear();
    ast_total = 0;
    ast_any = -1;
    ast_q = q;
    ast_pm_epoch++;
}

fn ast_pm_get(v: i32) -> i32 { if (v as i64) < ast_pm_stamp.len && ast_pm_stamp[v] == ast_pm_epoch { ast_pm_val[v] } else { -1 } }
fn ast_pm_set(v: i32, s: i32) {
    while ast_pm_stamp.len <= (v as i64) { ast_pm_stamp.push(0); ast_pm_val.push(-1); }
    ast_pm_stamp[v] = ast_pm_epoch;
    ast_pm_val[v] = s;
}

fn ast_new_set() -> i32 {
    let s = ast_sets.len as i32;
    ast_sets.push(AliasSetRec { fwd: -1, refc: 0, alias_any: false, access: AS_NO_ACCESS, may: false,
                         ml_at: 0, ml_n: 0, ml_cap: 0, un_at: 0, un_n: 0, un_cap: 0, dead: false });
    return s;
}
fn ast_nsets() -> i64 { ast_sets.len }
fn ast_set_live(s: i32) -> bool { !ast_sets[s].dead }
fn ast_ml(s: i32, k: i64) -> ML { ast_mls[(ast_sets[s].ml_at as i64) + k] }
fn ast_nml(s: i32) -> i64 { ast_sets[s].ml_n as i64 }
fn ast_unknown(s: i32, k: i64) -> i32 { ast_unk[(ast_sets[s].un_at as i64) + k] }
fn ast_is_mod(s: i32) -> bool { (ast_sets[s].access & AS_MOD) != 0 }
fn ast_is_ref(s: i32) -> bool { (ast_sets[s].access & AS_REF) != 0 }
fn ast_is_must_alias(s: i32) -> bool { !ast_sets[s].may }
fn ast_is_forwarding(s: i32) -> bool { ast_sets[s].fwd >= 0 }

fn ast_ml_push(s: i32, l: ML) {
    let n = ast_sets[s].ml_n as i64;
    if n == (ast_sets[s].ml_cap as i64) {
        let at = ast_sets[s].ml_at as i64;
        let nat = ast_mls.len;
        let ncap = max(n * 2, 4);
        for k in n { ast_mls.push(ast_mls[at + k]); }
        for k in ncap - n { ast_mls.push(ml_null()); }
        ast_sets[s].ml_at = nat as i32;
        ast_sets[s].ml_cap = ncap as i32;
    }
    ast_mls[(ast_sets[s].ml_at as i64) + n] = l;
    ast_sets[s].ml_n += 1;
}
fn ast_unk_push(s: i32, i: i32) {
    let n = ast_sets[s].un_n as i64;
    if n == (ast_sets[s].un_cap as i64) {
        let at = ast_sets[s].un_at as i64;
        let nat = ast_unk.len;
        let ncap = max(n * 2, 4);
        for k in n { ast_unk.push(ast_unk[at + k]); }
        for k in ncap - n { ast_unk.push(-1); }
        ast_sets[s].un_at = nat as i32;
        ast_sets[s].un_cap = ncap as i32;
    }
    ast_unk[(ast_sets[s].un_at as i64) + n] = i;
    ast_sets[s].un_n += 1;
}

fn ast_add_ref(s: i32) { ast_sets[s].refc += 1; }
recursive fn ast_drop_ref(s: i32) {
    ast_sets[s].refc -= 1;
    if ast_sets[s].refc == 0 { ast_remove_alias_set(s); }
}
// AliasSetTracker::removeAliasSet
recursive fn ast_remove_alias_set(s: i32) {
    let f = ast_sets[s].fwd;
    if f >= 0 {
        ast_drop_ref(f);
        ast_sets[s].fwd = -1;
    } else {
        ast_total -= ast_sets[s].ml_n as i64;
    }
    ast_sets[s].dead = true;
    if s == ast_any { ast_any = -1; }
}

fn ast_must_alias(a: ML, b: ML) -> bool { ar_k(aa_alias(a, b, ast_q, -1)) == AR_MUST }

// AliasSet::mergeSetIn(AS, AST, BatchAA): merge b into a
fn ast_merge_set_in(a: i32, b: i32) {
    ast_sets[a].access |= ast_sets[b].access;
    ast_sets[a].may = ast_sets[a].may || ast_sets[b].may;
    if !ast_sets[a].may {
        var any = false;
        for i in ast_nml(a) {
            for j in ast_nml(b) { if ast_must_alias(ast_ml(a, i), ast_ml(b, j)) { any = true; break; } }
            if any { break; }
        }
        if !any { ast_sets[a].may = true; }
    }
    if ast_sets[a].ml_n == 0 {
        // std::swap(MemoryLocs, AS.MemoryLocs)
        let at = ast_sets[a].ml_at; let n = ast_sets[a].ml_n; let cap = ast_sets[a].ml_cap;
        ast_sets[a].ml_at = ast_sets[b].ml_at; ast_sets[a].ml_n = ast_sets[b].ml_n; ast_sets[a].ml_cap = ast_sets[b].ml_cap;
        ast_sets[b].ml_at = at; ast_sets[b].ml_n = n; ast_sets[b].ml_cap = cap;
    } else {
        for j in ast_nml(b) { ast_ml_push(a, ast_ml(b, j)); }
        ast_sets[b].ml_n = 0;
    }
    let b_had_unknown = ast_sets[b].un_n > 0;
    if ast_sets[a].un_n == 0 {
        if b_had_unknown {
            let at = ast_sets[a].un_at; let n = ast_sets[a].un_n; let cap = ast_sets[a].un_cap;
            ast_sets[a].un_at = ast_sets[b].un_at; ast_sets[a].un_n = ast_sets[b].un_n; ast_sets[a].un_cap = ast_sets[b].un_cap;
            ast_sets[b].un_at = at; ast_sets[b].un_n = n; ast_sets[b].un_cap = cap;
            ast_add_ref(a);
        }
    } else if b_had_unknown {
        for j in ast_sets[b].un_n as i64 { ast_unk_push(a, ast_unknown(b, j)); }
        ast_sets[b].un_n = 0;
    }
    ast_sets[b].fwd = a;
    ast_add_ref(a);
    if b_had_unknown { ast_drop_ref(b); }
}

// collapseForwardingIn(AS): returns the collapsed set (the caller stores it where AS was)
recursive fn ast_collapse(s: i32) -> i32 {
    let f = ast_sets[s].fwd;
    if f < 0 { return s; }
    let nf = ast_collapse(f);
    ast_sets[s].fwd = nf;
    ast_add_ref(nf);
    ast_drop_ref(s);
    return nf;
}

// AliasSet::addMemoryLocation(AST, MemLoc, KnownMustAlias)
fn ast_set_add_ml(s: i32, l: ML, known_must: bool) {
    if !ast_sets[s].may && !known_must {
        var any = false;
        for j in ast_nml(s) { if ast_must_alias(l, ast_ml(s, j)) { any = true; break; } }
        if !any { ast_sets[s].may = true; }
    }
    ast_ml_push(s, l);
    ast_total++;
}

// AliasSet::aliasesMemoryLocation
fn ast_aliases_ml(s: i32, l: ML) -> AR {
    if ast_sets[s].alias_any { return AR { k: AR_MAY as u8, has_off: false, off: 0 }; }
    for j in ast_nml(s) {
        let r = aa_alias(l, ast_ml(s, j), ast_q, -1);
        if ar_k(r) != AR_NO { return r; }
    }
    for j in ast_sets[s].un_n as i64 {
        if mr_any(aa_inst_loc_mr(ast_unknown(s, j), l, ast_q)) { return AR { k: AR_MAY as u8, has_off: false, off: 0 }; }
    }
    return AR { k: AR_NO as u8, has_off: false, off: 0 };
}

// AliasSet::aliasesUnknownInst(Inst, AA)
fn ast_aliases_unknown_inst(s: i32, i: i32) -> i64 {
    if ast_sets[s].alias_any { return MR_MODREF; }
    if !inst_may_read_memory(i) && !inst_may_write_memory(i) { return MR_NO; }
    for j in ast_sets[s].un_n as i64 {
        let u = ast_unknown(s, j);
        if !is_callbase(u) || !is_callbase(i) || mr_any(aa_call_call_mr(u, i, ast_q)) || mr_any(aa_call_call_mr(i, u, ast_q)) {
            return MR_MODREF;
        }
    }
    var mr: i64 = MR_NO;
    for j in ast_nml(s) {
        mr |= aa_inst_loc_mr(i, ast_ml(s, j), ast_q);
        if mr == MR_MODREF { return mr; }
    }
    return mr;
}

// mergeAliasSetsForMemoryLocation(MemLoc, PtrAS, MustAliasAll)
fn ast_merge_for_loc(l: ML, ptr_as: i32) -> i32, bool {
    var found: i32 = -1;
    var must_all = true;
    let n = ast_sets.len;
    for k in n {
        let s = k as i32;
        if ast_sets[s].dead || ast_sets[s].fwd >= 0 { continue; }
        if s != ptr_as {
            let r = ast_aliases_ml(s, l);
            if ar_k(r) == AR_NO { continue; }
            if ar_k(r) != AR_MUST { must_all = false; }
        }
        if found < 0 { found = s; } else { ast_merge_set_in(found, s); }
    }
    return found, must_all;
}

// findAliasSetForUnknownInst(Inst)
fn ast_find_for_unknown(i: i32) -> i32 {
    var found: i32 = -1;
    let n = ast_sets.len;
    for k in n {
        let s = k as i32;
        if ast_sets[s].dead || ast_sets[s].fwd >= 0 || !mr_any(ast_aliases_unknown_inst(s, i)) { continue; }
        if found < 0 { found = s; } else { ast_merge_set_in(found, s); }
    }
    return found;
}

// getAliasSetFor(MemLoc)
fn ast_get_alias_set_for(l: ML) -> i32 {
    var entry = ast_pm_get(l.ptr);
    if entry >= 0 {
        entry = ast_collapse(entry);
        ast_pm_set(l.ptr, entry);
        for j in ast_nml(entry) { if ml_eq(ast_ml(entry, j), l) { return entry; } }
    }
    var s: i32 = -1;
    var must_all = false;
    if ast_any >= 0 {
        s = ast_any;
    } else {
        let f, ma = ast_merge_for_loc(l, entry);
        if f >= 0 { s = f; must_all = ma; }
        else { s = ast_new_set(); must_all = true; }
    }
    ast_set_add_ml(s, l, must_all);
    if entry >= 0 {
        entry = ast_collapse(entry);
        ast_pm_set(l.ptr, entry);
        if entry != s { fatal("internal: AliasSetTracker: memory locations with the same pointer in different alias sets"); }
    } else {
        ast_add_ref(s);
        ast_pm_set(l.ptr, s);
    }
    return s;
}

// mergeAllAliasSets
fn ast_merge_all() -> i32 {
    var vec: i32[>..<] = [];
    for k in ast_sets.len { if !ast_sets[k].dead { vec.push(k as i32); } }
    let a = ast_new_set();
    ast_any = a;
    ast_sets[a].may = true;
    ast_sets[a].access = AS_MODREF;
    ast_sets[a].alias_any = true;
    for cur in vec {
        let f = ast_sets[cur].fwd;
        if f >= 0 {
            ast_sets[cur].fwd = a;
            ast_add_ref(a);
            ast_drop_ref(f);
            continue;
        }
        ast_merge_set_in(a, cur);
    }
    return a;
}

// addMemoryLocation(Loc, E)
fn ast_add_memory_location(l: ML, e: u8) -> i32 {
    let s = ast_get_alias_set_for(l);
    ast_sets[s].access |= e;
    if ast_any < 0 && ast_total > flag_int("alias-set-saturation-threshold", 250) { return ast_merge_all(); }
    return s;
}

// AliasSet::addUnknownInst(I, AA)
fn ast_set_add_unknown(s: i32, i: i32) {
    if ast_sets[s].un_n == 0 { ast_add_ref(s); }
    ast_unk_push(s, i);
    let may_write = inst_may_write_memory(i) && !ast_is_guard(i) &&
        !(vals[i].first_use < 0 && inst_iid(i) == IID_invariant_start);
    ast_sets[s].may = true;
    if !may_write { ast_sets[s].access |= AS_REF; return; }
    ast_sets[s].access = AS_MODREF;
}

// isGuard(I): a call of llvm.experimental.guard
fn ast_is_guard(i: i32) -> bool { inst_iid(i) == IID_experimental_guard }

// addUnknown(Inst)
fn ast_add_unknown(i: i32) {
    let id = inst_iid(i);
    if id == IID_allow_runtime_check || id == IID_allow_ubsan_check || id == IID_assume ||
       id == IID_experimental_noalias_scope_decl || id == IID_sideeffect || id == IID_pseudoprobe { return; }
    if !inst_may_read_memory(i) && !inst_may_write_memory(i) { return; }
    let s = ast_find_for_unknown(i);
    if s >= 0 { ast_set_add_unknown(s, i); return; }
    let ns = ast_new_set();
    ast_set_add_unknown(ns, i);
}

// add(Instruction *I)
fn ast_add_inst(i: i32) {
    let o = iop(i);
    if o == OP_LOAD || o == OP_STORE {
        // isStrongerThanMonotonic(getOrdering())
        if insts[inst_of(i)].ord >= 4 { ast_add_unknown(i); return; }
        ast_add_memory_location(ml_get(i), if o == OP_LOAD { AS_REF } else { AS_MOD });
        return;
    }
    fatal("AliasSetTracker::add of a non-load/store instruction is not ported yet");
}
