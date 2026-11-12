// GlobalOpt: port of llvm/lib/Transforms/IPO/GlobalOpt.cpp and llvm/lib/Transforms/Utils/Evaluator.cpp
// (GlobalStatus and CtorUtils are in ipo_globals.goose).
// Target hooks on X86 / without a target: canHaveNonUndefGlobalInitializerInAddressSpace is `AS == 0`,
// useColdCCForColdCall is false (coldcc only with -enable-coldcc-stress-test, so no BlockFrequencyInfo is
// needed), useFastCCForInternalCall compares the EGPR feature of every caller (true without a target),
// isMultiversionedFunction is false (OptimizeNonTrivialIFuncs never changes anything, so it is not ported).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import gen_dwarf;
import intrinsics;
import datalayout;
import analyses;
import flags;
import pm;
import vt;
import cfold;
import constfold;
import knownbits;
import memintr;
import memorybuiltins;
import local;
import dinfo;
import dbgutil;
import mem2reg;
import salvage;
import domtree;
import cfgutil;
import tli;
import tti;
import sccp;
import ipoutil;
import ipo_globals;
import ipo_args;
import inliner;
import instsimplify;
import ic;
import ic_loadstorealloca;
import parser;
import passmgr;
import apint;
import evaluator;
import autoupgrade;
import memloc;
import loads;
import tti_x86;

fn go_fail(what: const u8[:]) { fatal(str("GlobalOpt: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Small helpers

// V->users() as a list in use-list order (a blockaddress is not a user of its function)
fn go_users(v: i32, out: i32[>..<]&) {
    var u = first_use(v);
    while u >= 0 { let us = uses[u].user; if vals[us].kind != VK_BLOCKADDR { out.push(us); } u = use_next(u); }
}
fn go_is_load(v: i32) -> bool { is_inst(v) && iop(v) == OP_LOAD }
fn go_is_store(v: i32) -> bool { is_inst(v) && iop(v) == OP_STORE }
fn go_is_simple(i: i32) -> bool { !inst_is_volatile(i) && insts[inst_of(i)].ord == 0 }
fn go_log2a(a: i64) -> u8 { var k: u8 = 0; while (1 << k) < a { k++; } return k + 1; }
fn go_align_of(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) }; }
// new LoadInst(Ty, Ptr, Name, false, Align, Order, SSID, InsertBefore)
fn go_new_load(ty: i32, ptr: i32, name: const u8[:], align: i64, ord: u8, ss: i32, before: i32) -> i32 {
    let i = create_inst(OP_LOAD, ty, [ptr]);
    insts[inst_of(i)].align = go_log2a(align);
    insts[inst_of(i)].ord = ord;
    insts[inst_of(i)].ss = ss;
    inst_insert_before(i, before);
    if name.len > 0 { set_name(i, name); }
    return i;
}
// new StoreInst(Val, Ptr, false, Align, Order, SSID, InsertBefore)
fn go_new_store(v: i32, ptr: i32, align: i64, ord: u8, ss: i32, before: i32) -> i32 {
    let i = create_inst(OP_STORE, T_VOID, [v, ptr]);
    insts[inst_of(i)].align = go_log2a(align);
    insts[inst_of(i)].ord = ord;
    insts[inst_of(i)].ss = ss;
    inst_insert_before(i, before);
    return i;
}
fn go_copy_dbg(dst: i32, src: i32) {
    let d = inst_get_md(src, 0);
    if d >= 0 { inst_set_md(dst, 0, d); } else { inst_erase_md(dst, 0); }
}
// the name of v with a suffix, for a new value's name
fn go_name_plus(v: i32, suffix: const u8[:], out: u8[>..]&) { out.append(val_name(v)); out.append(suffix); }
// Instruction::eraseFromParent for a pass-level erase
fn go_erase(i: i32) { inst_erase_from_parent(i); }
// GEPOperator::hasAllConstantIndices
fn go_gep_all_constant(g: i32) -> bool {
    for k in 1..nops(g) { if !is_cint(op(g, k)) && !(is_constant(op(g, k)) && vals[op(g, k)].kind == VK_CDVECTOR) { if vals[op(g, k)].kind != VK_CINT { return false; } } }
    return true;
}
fn go_is_bitcast_op(v: i32) -> bool { opcode_of(v) == OP_BITCAST }
fn go_is_asc_op(v: i32) -> bool { opcode_of(v) == OP_ADDRSPACECAST }
fn go_is_gep_op(v: i32) -> bool { opcode_of(v) == OP_GEP }
// getLoadStorePointerOperand
fn go_ls_ptr(v: i32) -> i32 {
    if go_is_load(v) { return op(v, 0); }
    if go_is_store(v) { return op(v, 1); }
    return -1;
}
fn go_ls_type(v: i32) -> i32 { if go_is_load(v) { vals[v].ty as i32 } else { vals[op(v, 0)].ty as i32 } }
// isAllocationFn(V, GetTLI)
fn go_is_allocation_fn(v: i32) -> bool {
    if !is_inst(v) || !is_callbase(v) { return false; }
    tli_cur_fn = inst_func(v);
    if mb_alloc_data(v, MB_ANY) >= 0 { return true; }
    return (call_alloc_kind(v) & (AFK_ALLOC | AFK_REALLOC)) != 0;
}
fn go_func_null_defined(f: i32) -> bool { null_pointer_is_defined(f, 0) }
fn x86_has_egpr() -> bool {
    let k = x86_feature_index("egpr");
    if k < 0 { return false; }
    return ((x86_bits[k / 64] >> ((k % 64) as u64)) & 1) != 0;
}

// RecursivelyDeleteTriviallyDeadInstructionsPermissive
fn go_rdtdi_permissive(list: i32[>..<]&) -> bool {
    var alive: i64 = 0;
    var keep: i32[>..<] = [];
    for d in list {
        if is_dead(d) || !is_inst(d) || !is_instruction_trivially_dead(d) { alive++; } else { keep.push(d); }
    }
    if alive == list.len { return false; }
    recursively_delete_trivially_dead(keep);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Leak-checker roots and cleanup of users

// isLeakCheckerRoot
fn go_is_leak_checker_root(gv: i32) -> bool {
    if gv_linkage(gv) == LK_PRIVATE { return false; }
    var tys: i32[>..<] = [];
    tys.push(globs[glob_of(gv)].vty);
    var limit = 20;
    loop {
        let t = tys.pop();
        let k = ty_kind(t);
        if k == TK_PTR { return true; }
        if k == TK_FVEC || k == TK_SVEC { if ty_kind(ty_elem(t)) == TK_PTR { return true; } }
        else if k == TK_ARRAY { tys.push(ty_elem(t)); }
        else if k == TK_STRUCT {
            if ty_is_opaque_struct(t) { return true; }
            for e in ty_count(t) {
                let it = ty_field(t, e);
                let ik = ty_kind(it);
                if ik == TK_PTR { return true; }
                if ik == TK_STRUCT || ik == TK_ARRAY || ik == TK_FVEC || ik == TK_SVEC { tys.push(it); }
            }
        }
        limit--;
        if limit == 0 { return true; }
        if tys.len == 0 { break; }
    }
    return false;
}
fn ty_is_opaque_struct(t: i32) -> bool { ty_kind(t) == TK_STRUCT && (types[t].flags & TF_OPAQUE) != 0 }

// IsSafeComputationToRemove
fn go_is_safe_computation_to_remove(v0: i32) -> bool {
    var v = v0;
    loop {
        if is_constant(v) { return true; }
        if !has_one_use(v) { return false; }
        if go_is_load(v) || (is_inst(v) && iop(v) == OP_INVOKE) || is_arg(v) || ig_is_gv(v) { return false; }
        if go_is_allocation_fn(v) { return true; }
        if inst_may_have_side_effects(v) { return false; }
        if iop(v) == OP_GEP {
            for k in 1..nops(v) { if !is_constant(op(v, k)) { return false; } }
        } else if nops(v) != 1 {
            return false;
        }
        v = op(v, 0);
    }
    return false;
}

// CleanupPointerRootUsers
fn go_cleanup_pointer_root_users(gv: i32) -> bool {
    var changed = false;
    var dead_i: i32[>..<] = [];
    var dead_s: i32[>..<] = [];
    var wl: i32[>..<] = [];
    go_users(gv, wl);
    while wl.len > 0 {
        let u = wl.pop();
        if go_is_store(u) {
            let v = op(u, 0);
            if is_constant(v) { changed = true; go_erase(u); }
            else if is_inst(v) { if has_one_use(v) { dead_i.push(v); dead_s.push(u); } }
        } else if is_inst(u) && iop(u) == OP_CALL && mi_is_memset(u) {
            let v = cb_arg(u, 1);
            if is_constant(v) { changed = true; go_erase(u); }
            else if is_inst(v) { if has_one_use(v) { dead_i.push(v); dead_s.push(u); } }
        } else if is_inst(u) && iop(u) == OP_CALL && mi_is_mem_transfer(u) {
            let src = mi_source(u);
            if vals[src].kind == VK_GVAR && globs[glob_of(src)].is_const != 0 { changed = true; go_erase(u); }
            else if is_inst(src) { if has_one_use(src) { dead_i.push(src); dead_s.push(u); } }
        } else if vals[u].kind == VK_CEXPR {
            if cexpr_op(u) == OP_GEP { go_users(u, wl); }
        }
    }
    for k in dead_i.len {
        let inst0 = dead_i[k];
        let store = dead_s[k];
        if is_dead(inst0) || is_dead(store) { continue; }
        if go_is_safe_computation_to_remove(inst0) {
            go_erase(store);
            var i = inst0;
            loop {
                if go_is_allocation_fn(i) { break; }
                let j = op(i, 0);
                if !is_inst(j) { break; }
                go_erase(i);
                i = j;
            }
            go_erase(i);
            changed = true;
        }
    }
    sc_remove_dead_constant_users(gv);
    return changed;
}

// CleanupConstantGlobalUsers
fn go_cleanup_constant_global_users(gv: i32) -> bool {
    let init = ig_init(gv);
    var wl: i32[>..<] = [];
    go_users(gv, wl);
    var visited = hm_new();
    var changed = false;
    var maybe_dead: i32[>..<] = [];
    while wl.len > 0 {
        let u = wl.pop();
        if hm_has(visited, u as u64) { continue; }
        hm_put(visited, u as u64, 1);
        if is_dead(u) { continue; }
        let o = opcode_of(u);
        if o == OP_BITCAST { go_users(u, wl); }
        if o == OP_ADDRSPACECAST { go_users(u, wl); }
        else if o == OP_GEP { go_users(u, wl); }
        else if go_is_load(u) {
            let ty: i32 = vals[u].ty;
            let res = cf_fold_load_from_uniform(init, ty);
            if res >= 0 {
                rauw(u, res);
                go_erase_track(u, maybe_dead);
                changed = true;
                continue;
            }
            var p = strip_and_accumulate_offsets(op(u, 0), true, false, false);
            let off = vt_off;
            if is_inst(p) && inst_iid(p) == IID_threadlocal_address { p = cb_arg(p, 0); }
            if p == gv {
                let v = cf_fold_load_from_const(init, ty, off);
                if v >= 0 {
                    rauw(u, v);
                    go_erase_track(u, maybe_dead);
                    changed = true;
                }
            }
        } else if go_is_store(u) {
            go_erase_track(u, maybe_dead);
            changed = true;
        } else if is_inst(u) && iop(u) == OP_CALL && mi_is_mem_intrinsic(u) {
            if get_underlying_object(cb_arg(u, 0), 10) == gv { go_erase_track(u, maybe_dead); changed = true; }
        } else if is_inst(u) && is_callbase(u) && inst_iid(u) == IID_threadlocal_address {
            go_users(u, wl);
        }
    }
    if go_rdtdi_permissive(maybe_dead) { changed = true; }
    sc_remove_dead_constant_users(gv);
    return changed;
}
fn go_erase_track(i: i32, maybe_dead: i32[>..<]&) {
    for k in nops(i) { let o = op(i, k); if o >= 0 && is_inst(o) { maybe_dead.push(o); } }
    go_erase(i);
}

// ---------------------------------------------------------------------------------------------
// Global SRA

// collectSRATypes: parts as parallel arrays (offset, type, initializer, loaded, stored)
var sra_off: i64[>..<];
var sra_ty: i32[>..<];
var sra_init: i32[>..<];
var sra_loaded: bool[>..<];
var sra_stored: bool[>..<];
fn go_collect_sra_types(gv: i32) -> bool {
    sra_off.clear(); sra_ty.clear(); sra_init.clear(); sra_loaded.clear(); sra_stored.clear();
    var wl: i32[>..<] = [];      // use ids
    var visited = hm_new();
    go_append_uses(gv, wl, visited);
    while wl.len > 0 {
        let u = wl.pop();
        let v = uses[u].user;
        if go_is_bitcast_op(v) || go_is_asc_op(v) || (go_is_gep_op(v) && go_gep_all_constant(v)) {
            go_append_uses(v, wl, visited);
            continue;
        }
        let ptr0 = go_ls_ptr(v);
        if ptr0 >= 0 {
            if go_is_store(v) && u == vals[v].ops { return false; }
            let ptr = strip_and_accumulate_offsets(ptr0, true, false, false);
            let off = vt_off;
            if ptr != gv || off < 0 { return false; }
            let ty = go_ls_type(v);
            var idx: i64 = -1;
            for k in sra_off.len { if sra_off[k] == off { idx = k; } }
            var inserted = false;
            if idx < 0 {
                idx = sra_off.len;
                sra_off.push(off); sra_ty.push(ty); sra_init.push(-1); sra_loaded.push(false); sra_stored.push(false);
                inserted = true;
            }
            if ty != sra_ty[idx] { return false; }
            if inserted {
                let c = cf_fold_load_from_const(ig_init(gv), ty, off);
                if c < 0 { return false; }
                sra_init[idx] = c;
            }
            if ty_contains_scalable(ty) { return false; }
            if go_is_load(v) { sra_loaded[idx] = true; }
            if go_is_store(v) {
                let sc = op(v, 0);
                if !is_constant(sc) || sra_init[idx] != sc { sra_stored[idx] = true; }
            }
            continue;
        }
        if is_constant(v) {
            if !ig_is_safe_to_destroy_constant(v) { return false; }
            continue;
        }
        return false;
    }
    return true;
}
fn go_append_uses(v: i32, wl: i32[>..<]&, visited: HMap&) {
    var u = first_use(v);
    while u >= 0 {
        if !hm_has(visited, u as u64) { hm_put(visited, u as u64, 1); wl.push(u); }
        u = use_next(u);
    }
}
// SRAGlobal(GV, DL): the first new global or -1
fn go_sra_global(gv: i32) -> i32 {
    if !go_collect_sra_types(gv) || sra_off.len == 0 { return -1; }
    if sra_off.len == 1 && sra_ty[0] == globs[glob_of(gv)].vty { return -1; }
    var nparts = 0;
    for k in sra_off.len { if sra_loaded[k] && sra_stored[k] { nparts++; } }
    if nparts > 16 { return -1; }
    // sort by offset
    var order: i64[>..<] = [];
    for k in sra_off.len { order.push(k); }
    var i: i64 = 1;
    while i < order.len {
        let x = order[i];
        var j = i - 1;
        while j >= 0 && sra_off[order[j]] > sra_off[x] { order[j + 1] = order[j]; j--; }
        order[j + 1] = x;
        i++;
    }
    var end: i64 = 0;
    for k in order {
        if sra_off[k] < end { return -1; }
        end = sra_off[k] + dl_alloc_size(sra_ty[k]);
    }
    if end > dl_alloc_size(globs[glob_of(gv)].vty) { return -1; }
    if ig_get_md(gv, 0) >= 0 { go_fail("SRA of a global with debug info (transferSRADebugInfo)"); }
    let g = glob_of(gv);
    let start_align = if globs[g].align != 0 { 1 << (globs[g].align - 1) } else { dl_align(globs[g].vty, true) };
    var new_globals: i32[>..<] = [];     // parallel to sra_off
    for k in sra_off.len { new_globals.push(-1); }
    var suffix: i64 = 0;
    var first: i32 = -1;
    for k in order {
        let ngv = ig_new_gvar(globs[g].module, sra_ty[k], false, LK_INTERNAL, sra_init[k], globs[g].tls, ptr_as(vals[gv].ty));
        ig_insert_global_before(ngv, gv);
        var nm: u8[>..] = [];
        nm.append(val_name(gv));
        nm.push('.');
        format(nm, suffix);
        suffix++;
        set_name(ngv, nm);
        ig_copy_attributes_from(ngv, gv);
        new_globals[k] = ngv;
        if first < 0 { first = ngv; }
        // commonAlignment(StartAlignment, OffsetForTy)
        var na = start_align;
        let off = sra_off[k];
        if off != 0 { let lowbit = off & (-off); if lowbit < na { na = lowbit; } }
        globs[glob_of(ngv)].align = go_log2a(na);
    }
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var dead: i32[>..<] = [];
    go_append_users_once(gv, wl, visited);
    while wl.len > 0 {
        let v = wl.pop();
        if go_is_bitcast_op(v) || go_is_asc_op(v) || go_is_gep_op(v) {
            go_append_users_once(v, wl, visited);
            if is_inst(v) { dead.push(v); }
            continue;
        }
        let ptr0 = go_ls_ptr(v);
        if ptr0 >= 0 {
            let ptr = strip_and_accumulate_offsets(ptr0, true, false, false);
            let off = vt_off;
            var ngv: i32 = -1;
            for k in sra_off.len { if sra_off[k] == off { ngv = new_globals[k]; } }
            if ptr != gv || ngv < 0 { fatal("internal: globalopt SRA: unexpected access"); }
            let pref = dl_align(go_ls_type(v), false);
            let na = ic::lsa_get_or_enforce_known_alignment(ngv, pref, v);
            if go_is_load(v) { set_op(v, 0, ngv); } else { set_op(v, 1, ngv); }
            insts[inst_of(v)].align = go_log2a(na);
            continue;
        }
    }
    recursively_delete_trivially_dead(dead);
    sc_remove_dead_constant_users(gv);
    ig_erase_global(gv, false);
    // NewGlobals.begin(): DenseMap<uint64_t, ...> iteration order; only "non-null" matters to the caller
    return first;
}
fn go_append_users_once(v: i32, wl: i32[>..<]&, visited: HMap&) {
    var u = first_use(v);
    while u >= 0 {
        let us = uses[u].user;
        if !hm_has(visited, us as u64) { hm_put(visited, us as u64, 1); wl.push(us); }
        u = use_next(u);
    }
}

// ---------------------------------------------------------------------------------------------
// Stored-once pointer globals

// AllUsesOfValueWillTrapIfNull(V, PHIs)
recursive fn go_all_uses_trap_if_null(v: i32, phis: i32[>..<]&) -> bool {
    var u = first_use(v);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if is_inst(us) {
            if go_func_null_defined(inst_func(us)) { return false; }
        }
        if go_is_load(us) {
        } else if go_is_store(us) {
            if op(us, 0) == v { return false; }
        } else if is_inst(us) && (iop(us) == OP_CALL || iop(us) == OP_INVOKE) {
            if cb_callee(us) != v { return false; }
        } else if is_inst(us) && iop(us) == OP_ADDRSPACECAST {
            if !go_all_uses_trap_if_null(us, phis) { return false; }
        } else if is_inst(us) && iop(us) == OP_GEP {
            if !go_all_uses_trap_if_null(us, phis) { return false; }
        } else if is_inst(us) && iop(us) == OP_PHI {
            if position(phis, us) < 0 {
                phis.push(us);
                if !go_all_uses_trap_if_null(us, phis) { return false; }
            }
        } else if is_inst(us) && iop(us) == OP_ICMP && !pred_is_signed(insts[inst_of(us)].pred as i64) &&
                  go_is_load(op(us, 0)) && vals[op(us, 1)].kind == VK_CNULL {
        } else {
            return false;
        }
    }
    return true;
}
// allUsesOfLoadedValueWillTrapIfNull(GV)
fn go_all_uses_of_loaded_value_trap_if_null(gv: i32) -> bool {
    var wl: i32[>..<] = [];
    wl.push(gv);
    while wl.len > 0 {
        let p = wl.pop();
        var u = first_use(p);
        while u >= 0 {
            let us = uses[u].user;
            u = use_next(u);
            if go_is_load(us) {
                if !go_is_simple(us) { return false; }
                var phis: i32[>..<] = [];
                if !go_all_uses_trap_if_null(us, phis) { return false; }
            } else if go_is_store(us) {
                if !go_is_simple(us) { return false; }
                if op(us, 1) != p { return false; }
            } else if vals[us].kind == VK_CEXPR {
                if strip_pointer_casts(us) != gv { return false; }
                wl.push(us);
            } else {
                return false;
            }
        }
    }
    return true;
}
// allUsesOfLoadAndStores(GV, Uses)
fn go_all_uses_of_load_and_stores(gv: i32, out: i32[>..<]&) {
    var wl: i32[>..<] = [];
    wl.push(gv);
    while wl.len > 0 {
        let p = wl.pop();
        var u = first_use(p);
        while u >= 0 {
            let us = uses[u].user;
            u = use_next(u);
            if vals[us].kind == VK_CEXPR { wl.push(us); continue; }
            out.push(us);
        }
    }
}
// OptimizeAwayTrappingUsesOfValue(V, NewV)
recursive fn go_optimize_away_trapping_uses_of_value(v: i32, nv: i32) -> bool {
    var changed = false;
    var u = first_use(v);
    while u >= 0 {
        let i = uses[u].user;
        u = use_next(u);
        if go_func_null_defined(inst_func(i)) { return false; }
        if go_is_load(i) {
            set_op(i, 0, nv);
            changed = true;
        } else if go_is_store(i) {
            if op(i, 1) == v { set_op(i, 1, nv); changed = true; }
        } else if iop(i) == OP_CALL || iop(i) == OP_INVOKE {
            if cb_callee(i) == v {
                set_op(i, nops(i) - 1, nv);
                changed = true;
                var passed = false;
                for k in cb_nargs(i) { if cb_arg(i, k) == v { passed = true; set_op(i, k, nv); } }
                if passed { u = first_use(v); }
            }
        } else if iop(i) == OP_ADDRSPACECAST {
            if go_optimize_away_trapping_uses_of_value(i, ce_cast(OP_ADDRSPACECAST, nv, vals[i].ty)) { changed = true; }
            if first_use(i) < 0 { changed = true; go_erase(i); }
        } else if iop(i) == OP_GEP {
            var all = true;
            for k in 1..nops(i) { if !is_constant(op(i, k)) { all = false; break; } }
            if all {
                let c = go_gep_const(i, nv);
                if go_optimize_away_trapping_uses_of_value(i, c) { changed = true; }
            }
            if first_use(i) < 0 { changed = true; go_erase(i); }
        }
    }
    return changed;
}
// OptimizeAwayTrappingUsesOfLoads(GV, LV)
fn go_optimize_away_trapping_uses_of_loads(gv: i32, lv: i32) -> bool {
    var changed = false;
    var all_gone = true;
    var us: i32[>..<] = [];
    go_users(gv, us);
    for gu in us {
        if is_dead(gu) { continue; }
        if go_is_load(gu) {
            if go_optimize_away_trapping_uses_of_value(gu, lv) { changed = true; }
            if first_use(gu) < 0 { go_erase(gu); changed = true; }
            else { all_gone = false; }
        } else if go_is_store(gu) {
        } else {
            all_gone = false;
        }
    }
    if all_gone {
        if go_is_leak_checker_root(gv) {
            if go_cleanup_pointer_root_users(gv) { changed = true; }
        } else {
            changed = true;
            go_cleanup_constant_global_users(gv);
        }
        if first_use(gv) < 0 {
            changed = true;
            ig_erase_global(gv, false);
        }
    }
    return changed;
}
// ConstantPropUsersOf(V)
fn go_constant_prop_users_of(v: i32) {
    var u = first_use(v);
    while u >= 0 {
        let i = uses[u].user;
        u = use_next(u);
        if !is_inst(i) { continue; }
        tli_cur_fn = inst_func(i);
        let c = ic::ic_constant_fold_instruction(i);
        if c >= 0 {
            rauw(i, c);
            while u >= 0 && uses[u].user == i { u = use_next(u); }
            if is_instruction_trivially_dead(i) { go_erase(i); }
        }
    }
}
// OptimizeGlobalAddressOfAllocation(GV, CI, AllocSize, InitVal)
fn go_optimize_global_address_of_allocation(gv: i32, ci: i32, alloc_size: i64, init_val: i32) -> i32 {
    let g = glob_of(gv);
    let m = globs[g].module;
    let gt = ty_array(T_I8, alloc_size);
    let ngv = ig_new_gvar(m, gt, false, LK_INTERNAL, c_undef(gt), globs[g].tls, 0);
    ig_insert_global_before(ngv, -1);
    var nm: u8[>..] = [];
    go_name_plus(gv, ".body", nm);
    set_name(ngv, nm);
    if vals[init_val].kind != VK_UNDEF && vals[init_val].kind != VK_POISON {
        // IRBuilder<> Builder(CI->getNextNode()); Builder.CreateMemSet(NewGV, InitVal, AllocSize, std::nullopt)
        let next = inst_next(ci);
        let f = au_get_declaration(IID_memset, [ty_ptr(0), T_I64]);
        let fty = globs[glob_of(f)].vty;
        let c = create_inst(OP_CALL, T_VOID, [ngv, init_val, c_int(T_I64, alloc_size), c_false(), f]);
        insts[inst_of(c)].ty2 = fty;
        inst_insert_before(c, next);
        let d = inst_get_md(next, 0);
        if d >= 0 { inst_set_md(c, 0, d); }
    }
    rauw(ci, ngv);
    // InitBool: not in the module until used
    let ib = ig_new_gvar(m, T_I1, false, LK_INTERNAL, c_false(), globs[g].tls, ptr_as(vals[gv].ty));
    var ibname: u8[>..] = [];
    go_name_plus(gv, ".init", ibname);
    vals[ib].name = intern(ibname);   // the name is set in the module's table when inserted
    var ib_used = false;
    var guses: i32[>..<] = [];
    go_all_uses_of_load_and_stores(gv, guses);
    for u in guses {
        if go_is_store(u) {
            let b = c_bool_val(vals[op(u, 0)].kind != VK_CNULL);
            let nsi = go_new_store(b, ib, 1, insts[inst_of(u)].ord, insts[inst_of(u)].ss, u);
            go_copy_dbg(nsi, u);
            go_erase(u);
            continue;
        }
        let li = u;
        while first_use(li) >= 0 {
            let lu = first_use(li);
            let ici = uses[lu].user;
            if !(is_inst(ici) && iop(ici) == OP_ICMP) { use_set(lu, ngv); continue; }
            var lv = go_new_load(T_I1, ib, "", 1, insts[inst_of(li)].ord, insts[inst_of(li)].ss, li);
            var lvn: u8[>..] = [];
            lvn.append(sbytes(vals[ib].name));
            lvn.append(".val");
            set_name(lv, lvn);
            go_copy_dbg(lv, li);
            ib_used = true;
            let p = insts[inst_of(ici)].pred as i64;
            if p == P_ULT { lv = c_false(); }
            else if p == P_UGE { lv = c_true(); }
            else if p == P_ULE || p == P_EQ {
                let n = create_inst(OP_XOR, T_I1, [lv, c_true()]);
                inst_insert_before(n, ici);
                set_name(n, "notinit");
                go_copy_dbg(n, ici);
                lv = n;
            } else if p == P_NE || p == P_UGT {
            } else { fatal("internal: globalopt: unknown icmp predicate"); }
            rauw(ici, lv);
            go_erase(ici);
        }
        go_erase(li);
    }
    if !ib_used {
        while first_use(ib) >= 0 { go_erase(uses[first_use(ib)].user); }
        let sv = vals[ib].name;
        vals[ib].name = -1;
        drop_all_refs(ib);
        val_set_dead(ib);
        let _ = sv;
    } else {
        let nmv = vals[ib].name;
        vals[ib].name = -1;
        ig_insert_global_before(ib, gv);
        set_name(ib, sbytes(nmv));
    }
    ig_erase_global(gv, false);
    go_erase(ci);
    go_constant_prop_users_of(ngv);
    return ngv;
}
fn c_bool_val(b: bool) -> i32 { if b { c_true() } else { c_false() } }
// valueIsOnlyUsedLocallyOrStoredToOneGlobal(CI, GV)
fn go_value_only_used_locally(ci: i32, gv: i32) -> bool {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    wl.push(ci);
    while wl.len > 0 {
        let v = wl.pop();
        if hm_has(visited, v as u64) { continue; }
        hm_put(visited, v as u64, 1);
        var u = first_use(v);
        while u >= 0 {
            let us = uses[u].user;
            u = use_next(u);
            if go_is_load(us) || (is_inst(us) && (iop(us) == OP_ICMP || iop(us) == OP_FCMP)) { continue; }
            if go_is_store(us) {
                if op(us, 0) == v && strip_pointer_casts(op(us, 1)) != gv { return false; }
                continue;
            }
            if is_inst(us) && iop(us) == OP_GEP { wl.push(us); continue; }
            return false;
        }
    }
    return true;
}
// tryToOptimizeStoreOfAllocationToGlobal(GV, CI)
fn go_try_optimize_store_of_allocation(gv: i32, ci: i32) -> bool {
    tli_cur_fn = inst_func(ci);
    if !is_removable_alloc(ci) { return false; }
    let init_val = mb_initial_value_of_allocation(ci, T_I8);
    if init_val < 0 { return false; }
    let ok, size = mb_get_object_size(ci, 0, false, false, false);
    if !ok { return false; }
    if size >= 2048 { return false; }
    if !go_all_uses_of_loaded_value_trap_if_null(gv) { return false; }
    if !go_value_only_used_locally(ci, gv) { return false; }
    go_optimize_global_address_of_allocation(gv, ci, size as! i64, init_val);
    return true;
}
// optimizeOnceStoredGlobal(GV, StoredOnceVal)
fn go_optimize_once_stored_global(gv: i32, sov: i32) -> bool {
    let init = ig_init(gv);
    if ty_kind(vals[init].ty) == TK_PTR && is_null_value(init) && ty_kind(vals[sov].ty) == TK_PTR &&
       !null_pointer_is_defined(-1, ptr_as(vals[init].ty)) {
        if is_constant(sov) {
            if go_optimize_away_trapping_uses_of_loads(gv, sov) { return true; }
        } else if go_is_allocation_fn(sov) {
            if is_inst(sov) && iop(sov) == OP_CALL {
                if go_try_optimize_store_of_allocation(gv, sov) { return true; }
            }
        }
    }
    return false;
}

// TryToShrinkGlobalToBoolean(GV, OtherVal)
fn go_try_shrink_to_bool(gv: i32, other: i32) -> bool {
    let g = glob_of(gv);
    let elt = globs[g].vty;
    if elt == T_I1 || ty_is_fp(elt) || ty_kind(elt) == TK_PTR || ty_kind(elt) == TK_FVEC || ty_kind(elt) == TK_SVEC { return false; }
    var u = first_use(gv);
    while u >= 0 {
        let us = uses[u].user;
        if !go_is_load(us) && !go_is_store(us) { return false; }
        if go_ls_type(us) != elt { return false; }
        u = use_next(u);
    }
    let m = globs[g].module;
    let ngv = ig_new_gvar(m, T_I1, false, LK_INTERNAL, c_false(), globs[g].tls, ptr_as(vals[gv].ty));
    var nm: u8[>..] = [];
    go_name_plus(gv, ".b", nm);
    vals[ngv].name = -1;
    ig_copy_attributes_from(ngv, gv);
    ig_insert_global_before(ngv, gv);
    set_name(ngv, nm);
    let init_val = ig_init(gv);
    var gvs: i32[>..<] = [];
    let gg = globs[g];
    for k in gg.nmd { if md_att[gg.md + 2 * k] == 0 { gvs.push(md_att[gg.md + 2 * k + 1]); } }
    var is_one_zero = false;
    var emit_one_or_zero = true;
    if vals[other].kind == VK_CINT && ap_active_bits(ap_from_cint(other)) <= 64 {
        is_one_zero = is_null_value(init_val) && cint_lo(other) == 1 && ap_active_bits(ap_from_cint(other)) == 1;
        if vals[init_val].kind == VK_CINT && ap_active_bits(ap_from_cint(init_val)) <= 64 {
            let vi = ap_zext64(ap_from_cint(init_val));
            let vo = ap_zext64(ap_from_cint(other));
            let vm = vo - vi;
            for gve in gvs {
                let dgv = md_op(gve, di_field_index(DIK_GLOBALVAREXPR, "var"));
                let e = md_op(gve, di_field_index(DIK_GLOBALVAREXPR, "expr"));
                let size = dl_alloc_size(T_I1);
                var ops: i64[>..<] = [];
                ops.push(0x94); ops.push(size); ops.push(0x10); ops.push(vm as! i64);
                ops.push(0x1e); ops.push(0x10); ops.push(vi as! i64); ops.push(0x22);
                let ne = go_prepend_opcodes(e, ops, true);
                let ngve = md_get(MK_DI, DIK_GLOBALVAREXPR as i32, go_gve_ops(dgv, ne), false);
                glob_add_md(ngv, 0, ngve);
            }
            emit_one_or_zero = false;
        }
    }
    if emit_one_or_zero { for x in gvs { glob_add_md(ngv, 0, x); } }
    while first_use(gv) >= 0 {
        let ui = uses[first_use(gv)].user;
        if go_is_store(ui) {
            let storing_other = op(ui, 0) == other;
            var store_val: i32 = -1;
            if storing_other || op(ui, 0) == init_val {
                store_val = c_int(T_I1, if storing_other { 1 } else { 0 });
            } else {
                let sv = op(ui, 0);
                if go_is_load(sv) {
                    var lnm: u8[>..] = [];
                    go_name_plus(sv, ".b", lnm);
                    store_val = go_new_load(T_I1, ngv, lnm, 1, insts[inst_of(sv)].ord, insts[inst_of(sv)].ss, sv);
                    go_copy_dbg(store_val, sv);
                } else {
                    store_val = op(sv, 0);
                }
            }
            let nsi = go_new_store(store_val, ngv, 1, insts[inst_of(ui)].ord, insts[inst_of(ui)].ss, ui);
            go_copy_dbg(nsi, ui);
        } else {
            let li = ui;
            var lnm: u8[>..] = [];
            go_name_plus(li, ".b", lnm);
            let nli = go_new_load(T_I1, ngv, lnm, 1, insts[inst_of(li)].ord, insts[inst_of(li)].ss, li);
            var nsi: i32 = -1;
            if is_one_zero {
                nsi = create_inst(OP_ZEXT, vals[li].ty, [nli]);
                inst_insert_before(nsi, li);
            } else {
                nsi = create_inst(OP_SELECT, vals[li].ty, [nli, other, init_val]);
                inst_insert_before(nsi, li);
                if fn_has_profile_data(inst_func(nsi)) { go_fail("explicitly unknown branch weights in a profiled function"); }
            }
            ig_take_name(nsi, li);
            go_copy_dbg(nli, li);
            go_copy_dbg(nsi, li);
            rauw(li, nsi);
        }
        go_erase(ui);
    }
    ig_take_name(ngv, gv);
    ig_erase_global(gv, false);
    return true;
}
fn go_gve_ops(var_: i32, expr: i32) -> i32[>..<] {
    var opsv: i32[>..<] = [];
    di_init();
    let n = dik_count[DIK_GLOBALVAREXPR] as i64;
    for k in n { opsv.push(-1); }
    opsv[di_field_index(DIK_GLOBALVAREXPR, "var")] = var_;
    opsv[di_field_index(DIK_GLOBALVAREXPR, "expr")] = expr;
    return opsv;
}
// DIExpression::prependOpcodes(Expr, Ops, StackValue)
fn go_prepend_opcodes(e: i32, ops: i64[>..<]&, stack_value0: bool) -> i32 {
    var stack_value = stack_value0;
    if ops.len == 0 { stack_value = false; }
    let n = diexpr_nelems(e);
    var k: i64 = 0;
    while k < n {
        let o = diexpr_elem(e, k);
        if stack_value {
            if o == 0x9f { stack_value = false; }
            else if o == DW_OP_LLVM_fragment { ops.push(0x9f); stack_value = false; }
        }
        let sz = diexpr_op_size(o);
        for j in sz { ops.push(diexpr_elem(e, k + j)); }
        k += sz;
    }
    if stack_value { ops.push(0x9f); }
    return du_expr(ops);
}

// deleteIfDead(GV, NotDiscardableComdats, DeleteFnCallback)
var go_not_discardable_comdats: i32[>..<];
var go_ndc_set = hm_new();
fn go_delete_if_dead(gv: i32) -> bool {
    sc_remove_dead_constant_users(gv);
    if !gv_is_discardable_if_unused(gv) && !ig_is_declaration(gv) { return false; }
    let c = ig_comdat(gv);
    if c >= 0 && !gv_has_local_linkage(gv) && hm_has(go_ndc_set, c as u64) { return false; }
    var dead = false;
    if vals[gv].kind == VK_FUNC {
        dead = (ig_is_declaration(gv) && ig_use_empty(gv)) || fn_is_def_trivially_dead(gv);
    } else {
        dead = first_use(gv) < 0;
    }
    if !dead { return false; }
    if vals[gv].kind == VK_FUNC { invalidate_function(gv, PA_NONE); }
    ig_salvage_debug_info_global(gv);
    ig_erase_global(gv, true);
    return true;
}
// ReplaceableMetadataImpl::SalvageDebugInfo(GV): debug-info nodes (DINode) using the global get poison
fn ig_salvage_debug_info_global(gv: i32) {
    let vm = ig_find_vam(gv);
    if vm < 0 { return; }
    var p: i32 = -1;
    for k in mds.len {
        let n = mds[k];
        if n.kind as i64 != MK_DI { continue; }
        for q in n.nops as i64 {
            if md_ops[(n.ops as i64) + q] == vm {
                if p < 0 { p = md_value(c_poison(vals[gv].ty)); }
                md_ops[(n.ops as i64) + q] = p;
            }
        }
    }
}

// isPointerValueDeadOnEntryToFunction(F, GV)
fn go_is_pointer_value_dead_on_entry(f: i32, gv: i32) -> bool {
    var loads: i32[>..<] = [];
    var stores: i32[>..<] = [];
    var u = first_use(gv);
    while u >= 0 {
        let i = uses[u].user;
        u = use_next(u);
        if !is_inst(i) { return false; }
        if go_is_load(i) { loads.push(i); }
        else if go_is_store(i) { stores.push(i); }
        else { return false; }
    }
    if loads.len * stores.len > 100 { return false; }
    dt_get(f, DT_DOM);
    for l in loads {
        let lty: i32 = vals[l].ty;
        var any = false;
        for s in stores {
            let sty: i32 = vals[op(s, 0)].ty;
            if dt_value_dominates_inst(s, l) && dl_store_size(lty) <= dl_store_size(sty) { any = true; break; }
        }
        if !any { return false; }
    }
    return true;
}
// forwardStoredOnceStore(GV, StoredOnceStore)
fn go_forward_stored_once_store(gv: i32, sos: i32) -> bool {
    let sov = op(sos, 0);
    if !is_constant(sov) { return false; }
    let f = inst_func(sos);
    var loads: i32[>..<] = [];
    var u = first_use(gv);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if go_is_load(us) && inst_func(us) == f && vals[us].ty == vals[sov].ty && go_is_simple(us) { loads.push(us); }
    }
    var changed = false;
    if loads.len > 0 {
        dt_get(f, DT_DOM);
        for li in loads {
            if dt_value_dominates_inst(sos, li) {
                rauw(li, sov);
                go_erase(li);
                changed = true;
            }
        }
    }
    return changed;
}

// processInternalGlobal(GV, GS)
fn go_process_internal_global(gv0: i32) -> bool {
    var gv = gv0;
    let g = glob_of(gv);
    let vty = globs[g].vty;
    let af = gs.accessing_function;
    if !gs.multiple_accessing && af >= 0 && ty_is_single_value(vty) && ptr_as(vals[gv].ty) == dl_alloca_addr_space &&
       globs[g].ext_init == 0 && fn_has(af, 0, AK_NoRecurse) && go_is_pointer_value_dead_on_entry(af, gv) {
        let first_i = block_first(func_entry(af));
        let ai = create_inst(OP_ALLOCA, ty_ptr(dl_alloca_addr_space), [c_int(T_I32, 1)]);
        insts[inst_of(ai)].ty2 = vty;
        insts[inst_of(ai)].align = go_log2a(dl_align(vty, false));
        inst_insert_before_head(ai, first_i);
        set_name(ai, val_name(gv));
        // DebugLoc::getCompilerGenerated(): no location in the IR
        if !(vals[ig_init(gv)].kind == VK_UNDEF || vals[ig_init(gv)].kind == VK_POISON) {
            let si = create_inst(OP_STORE, T_VOID, [ig_init(gv), ai]);
            insts[inst_of(si)].align = go_log2a(dl_align(vals[ig_init(gv)].ty, true));
            inst_insert_before_head(si, first_i);
        }
        ig_rauw(gv, ai);
        ig_erase_global(gv, false);
        return true;
    }
    var changed = false;
    if !gs.is_loaded {
        if go_is_leak_checker_root(gv) { changed = go_cleanup_pointer_root_users(gv); }
        else { changed = go_cleanup_constant_global_users(gv); }
        if first_use(gv) < 0 {
            ig_erase_global(gv, false);
            changed = true;
        }
        return changed;
    }
    if gs.stored_type <= GS_INITIALIZER_STORED {
        if gs.ordering == 0 {
            globs[g].is_const = 1;
            changed = true;
        }
        if go_cleanup_constant_global_users(gv) { changed = true; }
        if first_use(gv) < 0 {
            ig_erase_global(gv, false);
            return true;
        }
    }
    if !ty_is_single_value(vals[ig_init(gv)].ty) {
        if go_sra_global(gv) >= 0 { return true; }
    }
    let sov = gs_stored_once_value();
    if gs.stored_type == GS_STORED_ONCE && sov >= 0 {
        let can_init = ptr_as(vals[gv].ty) == 0;
        let sovc = if is_constant(sov) { sov } else { -1 };
        let init = ig_init(gv);
        if sovc >= 0 && (vals[init].kind == VK_UNDEF || vals[init].kind == VK_POISON) &&
           dl_alloc_size(vals[sovc].ty) == dl_alloc_size(globs[glob_of(gv)].vty) && can_init {
            if vals[sovc].ty == globs[glob_of(gv)].vty {
                ig_set_initializer(gv, sovc);
            } else {
                let og = glob_of(gv);
                let ngv = ig_new_gvar(globs[og].module, vals[sovc].ty, globs[og].is_const != 0, gv_linkage(gv), sovc, globs[og].tls, ptr_as(vals[gv].ty));
                ig_insert_global_before(ngv, gv);
                ig_take_name(ngv, gv);
                ig_copy_attributes_from(ngv, gv);
                ig_rauw(gv, ngv);
                ig_erase_global(gv, false);
                gv = ngv;
            }
            go_cleanup_constant_global_users(gv);
            if first_use(gv) < 0 { ig_erase_global(gv, false); }
            return true;
        }
        let num_stores = gs.num_stores;
        let sos = gs.stored_once_store;
        let ordering = gs.ordering;
        if go_optimize_once_stored_global(gv, sov) { return true; }
        if num_stores == 1 {
            if go_forward_stored_once_store(gv, sos) { return true; }
        }
        let init2 = ig_init(gv);
        if sovc >= 0 && ordering == 0 && (!(vals[init2].kind == VK_UNDEF || vals[init2].kind == VK_POISON) || can_init) {
            if go_try_shrink_to_bool(gv, sovc) { return true; }
        }
    }
    return changed;
}
fn ty_is_single_value(t: i32) -> bool {
    let k = ty_kind(t);
    return !(k == TK_STRUCT || k == TK_ARRAY || k == TK_VOID || k == TK_LABEL || k == TK_METADATA || k == TK_FUNC || k == TK_TOKEN);
}

// processGlobal(GV)
fn go_process_global(gv: i32) -> bool {
    if starts_with(val_name(gv), "llvm.") { return false; }
    if gs_analyze(gv) { return false; }
    var changed = false;
    if !gs.is_compared && !ig_has_global_unnamed_addr(gv) {
        let nu: u8 = if gv_has_local_linkage(gv) { 2 } else { 1 };
        if nu != globs[glob_of(gv)].unnamed {
            globs[glob_of(gv)].unnamed = nu;
            changed = true;
        }
    }
    if !gv_has_local_linkage(gv) { return changed; }
    if vals[gv].kind != VK_GVAR { return changed; }
    if globs[glob_of(gv)].is_const != 0 || !ig_has_init(gv) { return changed; }
    return go_process_internal_global(gv) || changed;
}

// ---------------------------------------------------------------------------------------------
// Functions

// StripAttr / RemoveAttribute(F, A)
fn go_strip_attr(l: i32, kind: i64) -> i32 {
    if l == 0 { return l; }
    for j in alists[l].n as i64 {
        let s = alist_runs[alists[l].at + j];
        if aset_has(s, kind) {
            var sets: i32[>..<] = [];
            for x in alists[l].n as i64 { sets.push(alist_runs[alists[l].at + x]); }
            sets[j] = aset_without(s, [kind]);
            return alist_get(sets);
        }
    }
    return l;
}
fn go_remove_attribute(f: i32, kind: i64) {
    globs[glob_of(f)].attrs = go_strip_attr(globs[glob_of(f)].attrs, kind);
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        u = use_next(u);
        if vals[cb].kind == VK_BLOCKADDR { continue; }
        insts[inst_of(cb)].attrs = go_strip_attr(insts[inst_of(cb)].attrs, kind);
    }
}
// hasChangeableCCImpl(F)
fn go_has_changeable_cc_impl(f: i32) -> bool {
    let cc = globs[glob_of(f)].cc;
    if cc != 0 && cc != 70 { return false; }   // C, X86_ThisCall
    if ty_fn_vararg(globs[glob_of(f)].vty) { return false; }
    var u = first_use(f);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if is_inst(us) && iop(us) == OP_CALL && dae_is_musttail(us) { return false; }
    }
    var b = func_first_block(f);
    while b >= 0 { if dae_terminating_musttail(b) >= 0 { return false; } b = block_next(b); }
    return !ia_has_address_taken(f);
}
var go_ccc = hm_new();      // ChangeableCCCache: function -> 0 / 1
fn go_has_changeable_cc(f: i32) -> bool {
    let c = hm_get(go_ccc, f as u64, -1);
    if c >= 0 { return c == 1; }
    hm_put(go_ccc, f as u64, 0);
    let r = go_has_changeable_cc_impl(f);
    hm_put(go_ccc, f as u64, if r { 1 } else { 0 });
    return r;
}
fn go_ccc_erase(f: i32) { hm_del(go_ccc, f as u64); }
fn go_has_musttail_callers(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 { let cb = uses[u].user; if is_inst(cb) && iop(cb) == OP_CALL && dae_is_musttail(cb) { return true; } u = use_next(u); }
    return false;
}
fn go_has_invoke_callers(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 { let cb = uses[u].user; if is_inst(cb) && iop(cb) == OP_INVOKE { return true; } u = use_next(u); }
    return false;
}
fn go_set_call_sites_cc(f: i32, cc: i32) {
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        u = use_next(u);
        if is_inst(cb) && is_callbase(cb) && cb_callee(cb) == f { insts[inst_of(cb)].cc = cc; }
    }
}
// TTI::useFastCCForInternalCall(F)
fn go_use_fast_cc_for_internal_call(f: i32) -> bool {
    let m = globs[glob_of(f)].module;
    tti_init_function(f, m);
    if tti_kind != TTI_X86 { return true; }
    let has = x86_has_egpr();
    var u = first_use(f);
    while u >= 0 {
        let cb = uses[u].user;
        u = use_next(u);
        if !is_inst(cb) || !is_callbase(cb) || cb_callee(cb) != f { continue; }
        tti_init_function(inst_func(cb), m);
        let h = x86_has_egpr();
        tti_init_function(f, m);
        if h != has { return false; }
    }
    return true;
}

// OptimizeFunctions(M)
fn go_optimize_functions(m: i32) -> bool {
    var changed = false;
    hm_clear(go_ccc);
    let stress = flag_bool("enable-coldcc-stress-test", false);
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if fn_has(f, 0, AK_Naked) { f = nf; continue; }
        if vals[f].name < 0 && !ig_is_declaration(f) && !gv_has_local_linkage(f) { ig_set_linkage(f, LK_INTERNAL); }
        if go_delete_if_dead(f) { changed = true; f = nf; continue; }
        if !ig_is_declaration(f) {
            tli_cur_fn = f;
            if cu_remove_unreachable_blocks(f) {
                changed = true;
                invalidate_function(f, PA_NONE);
            }
        }
        if go_process_global(f) { changed = true; }
        if !gv_has_local_linkage(f) { f = nf; continue; }
        if gv_may_be_derefined(f) { f = nf; continue; }
        if dae_has_attr_somewhere(f, AK_InAlloca) && !ia_has_address_taken(f) && !go_has_musttail_callers(f) && !ty_fn_vararg(globs[glob_of(f)].vty) {
            go_remove_attribute(f, AK_InAlloca);
            changed = true;
        }
        if dae_has_attr_somewhere(f, AK_Preallocated) {
            if !ia_has_address_taken(f) && !go_has_musttail_callers(f) && !go_has_invoke_callers(f) {
                go_remove_preallocated(f);
                changed = true;
            }
            f = nf;
            continue;
        }
        if go_has_changeable_cc(f) {
            if stress {
                go_ccc_erase(f);
                globs[glob_of(f)].cc = 9;     // CallingConv::Cold
                go_set_call_sites_cc(f, 9);
                changed = true;
            }
        }
        if go_has_changeable_cc(f) {
            if go_use_fast_cc_for_internal_call(f) {
                globs[glob_of(f)].cc = 8;     // CallingConv::Fast
                go_set_call_sites_cc(f, 8);
                changed = true;
            }
        }
        if dae_has_attr_somewhere(f, AK_Nest) && !ia_has_address_taken(f) {
            go_remove_attribute(f, AK_Nest);
            changed = true;
        }
        f = nf;
    }
    return changed;
}

// OptimizeGlobalVars(M)
fn go_optimize_global_vars(m: i32) -> bool {
    var changed = false;
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        let ng = globs[glob_of(gv)].next;
        if vals[gv].name < 0 && !ig_is_declaration(gv) && !gv_has_local_linkage(gv) { ig_set_linkage(gv, LK_INTERNAL); }
        if ig_has_init(gv) {
            let c = ig_init(gv);
            tli_cur_fn = -1;
            let nc = cf_fold_constant(c);
            if nc != c { ig_set_initializer(gv, nc); }
        }
        if go_delete_if_dead(gv) { changed = true; gv = ng; continue; }
        if go_process_global(gv) { changed = true; }
        gv = ng;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// llvm.used and aliases

// setUsedInitializer(V, Init)
fn go_set_used_initializer(v: i32, init: i32[>..<]&) {
    if init.len == 0 { ig_erase_global(v, false); return; }
    let vt = globs[glob_of(v)].vty;
    let pty = ty_elem(vt);
    var arr: i32[>..<] = [];
    for gvx in init { arr.push(ce_pointer_bitcast_or_addrspacecast(gvx, pty)); }
    // array_pod_sort by the stripped names
    var i: i64 = 1;
    while i < arr.len {
        let x = arr[i];
        var j = i - 1;
        while j >= 0 && go_bytes_gt(val_name(strip_pointer_casts(arr[j])), val_name(strip_pointer_casts(x))) { arr[j + 1] = arr[j]; j--; }
        arr[j + 1] = x;
        i++;
    }
    let aty = ty_array(pty, arr.len);
    let m = globs[glob_of(v)].module;
    module_remove_global(v);
    let nv = ig_new_gvar(m, aty, false, LK_APPENDING, c_aggregate(aty, arr), 0, ptr_as(vals[v].ty));
    module_append_global(nv);
    ig_take_name(nv, v);
    globs[glob_of(nv)].section = intern("llvm.metadata");
    // delete &V
    if first_use(v) >= 0 { fatal("internal: globalopt: llvm.used still has uses"); }
    drop_all_refs(v);
    val_set_dead(v);
}
fn ce_pointer_bitcast_or_addrspacecast(c: i32, t: i32) -> i32 {
    if vals[c].ty == t { return c; }
    if ptr_as(vals[c].ty) != ptr_as(t) { return ce_cast(OP_ADDRSPACECAST, c, t); }
    return ce_cast(OP_BITCAST, c, t);
}
var go_used: i32[>..<];
var go_cused: i32[>..<];
fn go_set_erase(s: i32[>..<]&, v: i32) -> bool {
    let p = position(s, v);
    if p < 0 { return false; }
    var k = p;
    while k + 1 < s.len { s[k] = s[k + 1]; k++; }
    s.pop();
    return true;
}
fn go_set_insert(s: i32[>..<]&, v: i32) -> bool { if position(s, v) >= 0 { return false; } s.push(v); return true; }
fn go_has_use_other_than_llvm_used(ga: i32) -> bool {
    if first_use(ga) < 0 { return false; }
    if !has_one_use(ga) { return true; }
    return position(go_used, ga) < 0 && position(go_cused, ga) < 0;
}
fn go_may_have_other_references(gv: i32) -> bool {
    if !gv_has_local_linkage(gv) { return true; }
    return position(go_used, gv) >= 0 || position(go_cused, gv) >= 0;
}
// hasUsesToReplace(GA, U, RenameTarget): (result, rename target)
fn go_has_uses_to_replace(ga: i32) -> bool, bool {
    if ig_is_weak_for_linker(ga) { return false, false; }
    var ret = false;
    if go_has_use_other_than_llvm_used(ga) { ret = true; }
    if !go_may_have_other_references(ga) { return ret, false; }
    let target = strip_pointer_casts(op(ga, 0));
    if go_may_have_other_references(target) { return ret, false; }
    return true, true;
}
fn go_is_module_local(gv: i32) -> bool {
    return !gv_interposable_linkage(gv) && (globs[glob_of(gv)].dso_local != 0 || ig_is_implicit_dso_local(gv));
}
// OptimizeGlobalAliases(M)
fn go_optimize_global_aliases(m: i32) -> bool {
    var changed = false;
    go_used.clear();
    go_cused.clear();
    let used_v = ig_collect_used(m, false, go_used);
    let cused_v = ig_collect_used(m, true, go_cused);
    // the sets: duplicates collapse
    go_dedup(go_used);
    go_dedup(go_cused);
    for x in go_used { go_set_erase(go_cused, x); }
    var j = modules[m].first_alias;
    while j >= 0 {
        let nj = globs[glob_of(j)].next;
        if vals[j].name < 0 && !gv_has_local_linkage(j) { ig_set_linkage(j, LK_INTERNAL); }
        if go_delete_if_dead(j) { changed = true; j = nj; continue; }
        if !go_is_module_local(j) { j = nj; continue; }
        let aliasee = op(j, 0);
        let target = strip_pointer_casts(aliasee);
        if !ig_is_gv(target) || !go_is_module_local(target) { j = nj; continue; }
        sc_remove_dead_constant_users(target);
        let has, rename = go_has_uses_to_replace(j);
        if !has { j = nj; continue; }
        ig_rauw(j, aliasee);
        changed = true;
        if rename {
            ig_take_name(target, j);
            ig_set_linkage(target, gv_linkage(j));
            globs[glob_of(target)].dso_local = globs[glob_of(j)].dso_local;
            ig_set_visibility(target, globs[glob_of(j)].vis);
            globs[glob_of(target)].dll = globs[glob_of(j)].dll;
            if go_set_erase(go_used, j) { go_set_insert(go_used, target); }
            if go_set_erase(go_cused, j) { go_set_insert(go_cused, target); }
        } else if go_may_have_other_references(j) {
            j = nj;
            continue;
        }
        ig_erase_global(j, false);
        changed = true;
        j = nj;
    }
    if used_v >= 0 { go_set_used_initializer(used_v, go_used); }
    if cused_v >= 0 { go_set_used_initializer(cused_v, go_cused); }
    return changed;
}
fn go_dedup(s: i32[>..<]&) {
    var out: i32[>..<] = [];
    for x in s { if position(out, x) < 0 { out.push(x); } }
    s.clear();
    for x in out { s.push(x); }
}

// ---------------------------------------------------------------------------------------------
// atexit, ifuncs

// FindAtExitLibFunc(M, GetTLI, Func)
fn go_find_atexit_lib_func(m: i32, lf: i64) -> i32 {
    let f0 = modules[m].first_func;
    if f0 < 0 { return -1; }
    tli_cur_fn = f0;
    if !tli_has(lf as i32) { return -1; }
    let fnv = ig_module_function(m, tli_name(lf));
    if fnv < 0 { return -1; }
    tli_cur_fn = fnv;
    let got = tli_get_libfunc(fnv);
    if got < 0 || got as i64 != lf { return -1; }
    return fnv;
}
// IsEmptyAtExitFunction
fn go_is_empty_atexit_function(f: i32) -> bool {
    if ig_is_declaration(f) { return false; }
    var i = block_first(func_entry(f));
    while i >= 0 {
        if iop(i) == OP_CALL && inst_iid(i) == IID_pseudoprobe { i = inst_next(i); continue; }
        if iop(i) == OP_RET { return true; }
        break;
    }
    return false;
}
fn go_optimize_empty_global_atexit_dtors(fnv: i32) -> bool {
    var changed = false;
    var us: i32[>..<] = [];
    go_users(fnv, us);
    for ci in us {
        if !is_inst(ci) || iop(ci) != OP_CALL { continue; }
        let d = strip_pointer_casts(cb_arg(ci, 0));
        if vals[d].kind != VK_FUNC || !go_is_empty_atexit_function(d) { continue; }
        rauw(ci, c_null(vals[ci].ty));
        go_erase(ci);
        changed = true;
    }
    return changed;
}
// hasSideeffectFreeStaticResolution(IF)
fn go_static_resolution(gi: i32) -> i32 {
    if gv_is_interposable(gi, true) { return -1; }
    let r = op(gi, 0);
    if r < 0 { return -1; }
    // getResolverFunction: the resolver stripped of pointer casts and aliases
    let res = go_strip_casts_and_aliases(r);
    if vals[res].kind != VK_FUNC { return -1; }
    if gv_is_interposable(res, true) { return -1; }
    let e = func_entry(res);
    if e < 0 || block_next(e) >= 0 { return -1; }
    var i = block_first(e);
    while i >= 0 { if inst_may_have_side_effects(i) { return -1; } i = inst_next(i); }
    let ret = block_terminator(e);
    if ret < 0 || iop(ret) != OP_RET || nops(ret) == 0 { return -1; }
    let rv = op(ret, 0);
    return if vals[rv].kind == VK_FUNC { rv } else { -1 };
}
fn go_optimize_static_ifuncs(m: i32) -> bool {
    var changed = false;
    var gi = modules[m].first_ifunc;
    while gi >= 0 {
        let callee = go_static_resolution(gi);
        if callee >= 0 && first_use(gi) >= 0 {
            var any_alias = false;
            var u = first_use(gi);
            while u >= 0 { if vals[uses[u].user].kind == VK_ALIAS { any_alias = true; } u = use_next(u); }
            if !ig_is_declaration(callee) || !any_alias {
                ig_rauw(gi, callee);
                changed = true;
            }
        }
        gi = globs[glob_of(gi)].next;
    }
    return changed;
}
fn go_delete_dead_ifuncs(m: i32) -> bool {
    var changed = false;
    var gi = modules[m].first_ifunc;
    while gi >= 0 {
        let ng = globs[glob_of(gi)].next;
        if go_delete_if_dead(gi) { changed = true; }
        gi = ng;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Static constructors

var go_has_first_not_fully_evaluated = false;
var go_first_not_fully_evaluated: i64 = 0;
fn go_ctor_should_remove(prio: i64, f: i32) -> bool {
    if go_has_first_not_fully_evaluated && go_first_not_fully_evaluated != prio { return false; }
    let ok = go_evaluate_static_constructor(f);
    if !ok { go_has_first_not_fully_evaluated = true; go_first_not_fully_evaluated = prio; }
    return ok;
}
// EvaluateStaticConstructor(F)
fn go_evaluate_static_constructor(f: i32) -> bool {
    if ig_is_declaration(f) { return false; }
    tli_cur_fn = f;
    ev_begin();
    let ok, rv = ev_evaluate_function(f, 0, 0);
    let _ = rv;
    if ok {
        for k in ev_mut_gv.len {
            let c = ev_mv_to_constant(ev_mut_mv[k]);
            ig_set_initializer(ev_mut_gv[k], c);
        }
        for gvx in ev_invariants { globs[glob_of(gvx)].is_const = 1; }
    }
    ev_end();
    return ok;
}

// ---------------------------------------------------------------------------------------------
// The driver

fn globalopt_run(m: i32) -> bool {
    var changed = false;
    var local_change = true;
    go_has_first_not_fully_evaluated = false;
    while local_change {
        local_change = false;
        go_not_discardable_comdats.clear();
        hm_clear(go_ndc_set);
        var gv = modules[m].first_gvar;
        while gv >= 0 {
            let c = globs[glob_of(gv)].comdat;
            if c >= 0 && (!gv_is_discardable_if_unused(gv) || first_use(gv) >= 0) { hm_put(go_ndc_set, c as u64, 1); }
            gv = globs[glob_of(gv)].next;
        }
        var f = modules[m].first_func;
        while f >= 0 {
            let c = globs[glob_of(f)].comdat;
            if c >= 0 && !fn_is_def_trivially_dead(f) { hm_put(go_ndc_set, c as u64, 1); }
            f = globs[glob_of(f)].next;
        }
        var ga = modules[m].first_alias;
        while ga >= 0 {
            let c = ig_comdat(ga);
            if c >= 0 && (!gv_is_discardable_if_unused(ga) || first_use(ga) >= 0) { hm_put(go_ndc_set, c as u64, 1); }
            ga = globs[glob_of(ga)].next;
        }
        if go_optimize_functions(m) { local_change = true; }
        if ig_optimize_global_ctors_list(m, 1) { local_change = true; }
        if go_optimize_global_vars(m) { local_change = true; }
        if go_optimize_global_aliases(m) { local_change = true; }
        let cxa = go_find_atexit_lib_func(m, LF_cxa_atexit);
        if cxa >= 0 { if go_optimize_empty_global_atexit_dtors(cxa) { local_change = true; } }
        let ae = go_find_atexit_lib_func(m, LF_atexit);
        if ae >= 0 { if go_optimize_empty_global_atexit_dtors(ae) { local_change = true; } }
        if go_optimize_static_ifuncs(m) { local_change = true; }
        if go_delete_dead_ifuncs(m) { local_change = true; }
        if local_change { changed = true; }
    }
    return changed;
}

fn go_gep_const(i: i32, nv: i32) -> i32 {
    var idxs: i32[>..<] = [];
    for k in 1..nops(i) { idxs.push(op(i, k)); }
    return ce_gep(insts[inst_of(i)].ty2, nv, idxs, 0, -1);
}
// StringRef::compare(A, B) > 0
fn go_bytes_gt(a: const u8[:], b: const u8[:]) -> bool {
    let n = if a.len < b.len { a.len } else { b.len };
    for k in n { if a[k] != b[k] { return a[k] > b[k]; } }
    return a.len > b.len;
}

// Value::stripPointerCastsAndAliases
fn go_strip_casts_and_aliases(v0: i32) -> i32 {
    var v = v0;
    var n = 0;
    loop {
        let s = strip_pointer_casts(v);
        if vals[s].kind == VK_ALIAS && n < 64 { v = op(s, 0); n++; continue; }
        return s;
    }
    return v;
}

// RemovePreallocated(F)
fn go_remove_preallocated(f: i32) {
    go_remove_attribute(f, AK_Preallocated);
    var calls: i32[>..<] = [];
    go_users(f, calls);
    for cb in calls {
        if !is_inst(cb) || !is_callbase(cb) { continue; }
        // the operand bundles without "preallocated"
        var setup: i32 = -1;
        var pairs: i32[>..<] = [];
        var bops: i32[>..<] = [];
        for k in cb_nbundles(cb) {
            let st = cb_bundle_begin(cb, k);
            let n = cb_bundle_count(cb, k);
            if setup < 0 && sbytes(cb_bundle_tag(cb, k)) == "preallocated" { setup = op(cb, st); continue; }
            pairs.push(cb_bundle_tag(cb, k));
            pairs.push(n as i32);
            for j in n { bops.push(op(cb, st + j)); }
        }
        if setup < 0 { fatal("internal: globalopt: no preallocated bundle"); }
        let arg_count = cint_lo(cb_arg(setup, 0)) as! i64;
        // CallBase::Create(CB, OpBundles, CB): same type, callee, arguments, flags, attributes, debug location
        var opsv: i32[>..<] = [];
        for k in cb_nargs(cb) { opsv.push(cb_arg(cb, k)); }
        for x in bops { opsv.push(x); }
        if iop(cb) == OP_INVOKE { opsv.push(invoke_normal_dest(cb)); opsv.push(invoke_unwind_dest(cb)); }
        opsv.push(cb_callee(cb));
        let ncb = create_inst(iop(cb), vals[cb].ty, opsv);
        let ni = inst_of(ncb);
        let oi = inst_of(cb);
        insts[ni].ty2 = insts[oi].ty2;
        cb_set_bundles(ncb, cb_nargs(cb), pairs, 0);
        insts[ni].pred = insts[oi].pred;
        insts[ni].cc = insts[oi].cc;
        insts[ni].fmf = insts[oi].fmf;
        insts[ni].flags = insts[oi].flags;
        insts[ni].attrs = insts[oi].attrs;
        inst_insert_before(ncb, cb);
        if vals[cb].name >= 0 { set_name(ncb, val_name(cb)); }
        go_copy_dbg(ncb, cb);
        rauw(cb, ncb);
        ig_take_name(ncb, cb);
        go_erase(cb);
        // Builder.SetInsertPoint(PreallocatedSetup); CreateStackSave()
        let ss_f = au_get_declaration(IID_stacksave, [ty_ptr(0)]);
        let ssave = create_inst(OP_CALL, ty_ptr(0), [ss_f]);
        insts[inst_of(ssave)].ty2 = globs[glob_of(ss_f)].vty;
        inst_insert_before(ssave, setup);
        go_copy_dbg(ssave, setup);
        // Builder.SetInsertPoint(NewCB->getNextNode()); CreateStackRestore(StackSave)
        let nn = inst_next(ncb);
        let sr_f = au_get_declaration(IID_stackrestore, [ty_ptr(0)]);
        let srest = create_inst(OP_CALL, T_VOID, [ssave, sr_f]);
        insts[inst_of(srest)].ty2 = globs[glob_of(sr_f)].vty;
        inst_insert_before(srest, nn);
        go_copy_dbg(srest, nn);
        var arg_allocas: i32[>..<] = [];
        for k in arg_count { arg_allocas.push(-1); }
        var pa_users: i32[>..<] = [];
        go_users(setup, pa_users);
        for uc in pa_users {
            let idx = cint_lo(cb_arg(uc, 1)) as! i64;
            var repl = arg_allocas[idx];
            if repl < 0 {
                let a = aset_find(alist_fn(insts[inst_of(uc)].attrs), AK_Preallocated);
                let aty = attrs[a].ty;
                let ib = inst_next(setup);
                let ai = create_inst(OP_ALLOCA, ty_ptr(ptr_as(vals[uc].ty)), [c_int(T_I32, 1)]);
                insts[inst_of(ai)].ty2 = aty;
                insts[inst_of(ai)].align = go_log2a(dl_align(aty, false));
                inst_insert_before(ai, ib);
                set_name(ai, "paarg");
                go_copy_dbg(ai, ib);
                arg_allocas[idx] = ai;
                repl = ai;
            }
            rauw(uc, repl);
            go_erase(uc);
        }
        go_erase(setup);
    }
}
