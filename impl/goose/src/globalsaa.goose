// GlobalsAA (globals-aa): port of llvm/lib/Analysis/GlobalsModRef.cpp (AnalyzeGlobals, AnalyzeUsesOfPointer,
// AnalyzeIndirectGlobalMemory, AnalyzeCallGraph, isNonEscapingGlobalNoAlias(WithLoad), alias, getModRefInfo,
// getModRefInfoForArgument, getMemoryEffects) with the CallGraph it needs (llvm/lib/Analysis/CallGraph.cpp:
// addToCallGraph, populateCallGraphNode, Function::hasAddressTaken) and the Tarjan scc_iterator
// (llvm/include/llvm/ADT/SCCIterator.h), whose SCC order and SCC[0] choice the analysis depends on.
// A module analysis: computed by require<globals-aa>, used by the AA pipeline only when cached (gm_valid).
// Deletion callbacks (value handles) are not ported: the result is only valid while no global or function
// it tracks is erased.
import std;
import ipoutil;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import tli;
import pm;
import vt;
import memloc;

var gm_valid: bool = false;
var gm_module: i32 = -1;
var gm_unknown_local_fns: bool = false;
var gm_unknown_computed: bool = false;   // the value AnalyzeGlobals computed
var gm_nonaddr: bool[>..];        // NonAddressTakenGlobals, by value id
var gm_indirect: bool[>..];       // IndirectGlobals
var gm_alloc_for: i32[>..];       // AllocsForIndirectGlobals: value -> global variable (-1)

// FunctionInfo per function value id: flags (ModRef bits | MayReadAnyGlobal 4), -1 = no info; the per-global
// map is a run of (global, mod/ref) pairs in gm_pg/gm_pm.
var gm_fi: i32[>..];
var gm_fi_at: i32[>..];
var gm_fi_n: i32[>..];
var gm_fi_cap: i32[>..];
var gm_pg: i32[>..];
var gm_pm: i32[>..];
let GM_MAY_READ_ANY: i32 = 4;

fn gm_grow() {
    let n = vals.len;
    while gm_nonaddr.len < n { gm_nonaddr.push(false); gm_indirect.push(false); gm_alloc_for.push(-1); gm_fi.push(-1); gm_fi_at.push(0); gm_fi_n.push(0); gm_fi_cap.push(0); }
}
fn gm_in(v: i32) -> bool { (v as i64) < gm_nonaddr.len }
fn gm_is_nonaddr(v: i32) -> bool { gm_in(v) && gm_nonaddr[v] }
fn gm_has_fi(f: i32) -> bool { gm_in(f) && gm_fi[f] >= 0 }
// FunctionInfos[F] (creates an empty info)
fn gm_fi_get(f: i32) { if gm_fi[f] < 0 { gm_fi[f] = 0; gm_fi_n[f] = 0; gm_fi_cap[f] = 0; } }
fn gm_fi_erase(f: i32) { if f >= 0 && gm_in(f) { gm_fi[f] = -1; } }
fn gm_fi_modref(f: i32) -> i64 { (gm_fi[f] & 3) as i64 }
fn gm_fi_add_modref(f: i32, mr: i64) { gm_fi[f] |= mr as i32; }
fn gm_fi_set_may_read_any(f: i32) { gm_fi[f] |= GM_MAY_READ_ANY; }
fn gm_fi_may_read_any(f: i32) -> bool { (gm_fi[f] & GM_MAY_READ_ANY) != 0 }
fn gm_fi_add_for_global(f: i32, g: i32, mr: i64) {
    let at = gm_fi_at[f] as i64;
    let n = gm_fi_n[f] as i64;
    for k in n { if gm_pg[at + k] == g { gm_pm[at + k] |= mr as i32; return; } }
    if n == (gm_fi_cap[f] as i64) {
        let ncap = max(4, n * 2);
        let nat = gm_pg.len;
        for k in n { gm_pg.push(gm_pg[at + k]); gm_pm.push(gm_pm[at + k]); }
        for k in ncap - n { gm_pg.push(-1); gm_pm.push(0); }
        gm_fi_at[f] = nat as i32;
        gm_fi_cap[f] = ncap as i32;
    }
    let p = (gm_fi_at[f] as i64) + n;
    gm_pg[p] = g;
    gm_pm[p] = mr as i32;
    gm_fi_n[f] += 1;
}
// getModRefInfoForGlobal
fn gm_fi_for_global(f: i32, g: i32) -> i64 {
    var r = if gm_fi_may_read_any(f) { MR_REF } else { MR_NO };
    let at = gm_fi_at[f] as i64;
    for k in gm_fi_n[f] as i64 { if gm_pg[at + k] == g { r |= gm_pm[at + k] as i64; } }
    return r;
}
// addFunctionInfo
fn gm_fi_add_info(f: i32, from: i32) {
    gm_fi_add_modref(f, gm_fi_modref(from));
    if gm_fi_may_read_any(from) { gm_fi_set_may_read_any(f); }
    let at = gm_fi_at[from] as i64;
    let n = gm_fi_n[from] as i64;
    for k in n { gm_fi_add_for_global(f, gm_pg[at + k], gm_pm[at + k] as i64); }
}
// FunctionInfos[To] = FunctionInfo (copy)
fn gm_fi_copy(to: i32, from: i32) {
    gm_fi[to] = gm_fi[from];
    gm_fi_n[to] = 0;
    gm_fi_cap[to] = 0;
    let at = gm_fi_at[from] as i64;
    let n = gm_fi_n[from] as i64;
    for k in n { gm_fi_add_for_global(to, gm_pg[at + k], gm_pm[at + k] as i64); }
}

fn gm_local_linkage(v: i32) -> bool { let l = globs[glob_of(v)].linkage as i64; l == LK_INTERNAL || l == LK_PRIVATE }

// ---------------------------------------------------------------------------------------------
// AnalyzeUsesOfPointer (readers/writers on global stacks, de-duplicated)

var gm_readers: i32[>..<];
var gm_writers: i32[>..<];
fn gm_add_fn(xs: i32[>..<]&, f: i32) { for x in xs { if x == f { return; } } xs.push(f); }

fn gm_is_assume_like(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe || id == IID_dbg_assign || id == IID_dbg_declare ||
        id == IID_dbg_value || id == IID_dbg_label || id == IID_invariant_start || id == IID_invariant_end || id == IID_lifetime_start ||
        id == IID_lifetime_end || id == IID_experimental_noalias_scope_decl || id == IID_objectsize || id == IID_ptr_annotation ||
        id == IID_var_annotation;
}

// getFreedOperand(Call, TLI) is operand k
fn gm_frees_operand(c: i32, k: i64) -> bool {
    let f = cb_callee(c);
    let cf = called_function(c);
    if cf >= 0 && inst_iid(c) == 0 && !call_is_nobuiltin(c) {
        let saved = tli_cur_fn;
        tli_cur_fn = inst_func(c);
        let is_free = tli_is_free_fn(cf);
        tli_cur_fn = saved;
        if is_free { return k == 0; }
    }
    // allockind("free"): the argument with allocptr
    var kind: u64 = 0;
    let a = aset_find(alist_fn(insts[inst_of(c)].attrs), AK_AllocKind);
    if a >= 0 { kind = attrs[a].i1; } else if is_func(f) { let b = aset_find(alist_fn(func_attrs(f)), AK_AllocKind); if b >= 0 { kind = attrs[b].i1; } }
    if (kind & 4) != 0 {
        for j in cb_nargs(c) { if cb_param_has_attr(c, j, AK_AllocatedPointer) { return j == k; } }
    }
    return false;
}

// Constant::isConstantUsed
recursive fn gm_constant_used(c: i32) -> bool {
    var u = vals[c].first_use;
    while u >= 0 {
        let x = uses[u].user;
        if !is_constant(x) || is_global(x) { return true; }
        if gm_constant_used(x) { return true; }
        u = uses[u].next;
    }
    return false;
}

// AnalyzeUsesOfPointer(V, Readers, Writers, OkayStoreDest): true if the pointer escapes
recursive fn gm_analyze_uses(v: i32, want_readers: bool, want_writers: bool, okay_store: i32) -> bool {
    if ty_kind(vals[v].ty) != TK_PTR { return true; }
    if is_constant_data(v) { return false; }
    var u = vals[v].first_use;
    while u >= 0 {
        let i = uses[u].user;
        let opno = (u - vals[i].ops) as i64;
        u = uses[u].next;
        if is_inst_op(i, OP_LOAD) {
            if want_readers { gm_add_fn(gm_readers, inst_func(i)); }
        } else if is_inst_op(i, OP_STORE) {
            if opno == 1 {
                if want_writers { gm_add_fn(gm_writers, inst_func(i)); }
            } else if op(i, 1) != okay_store {
                return true;
            }
        } else if opcode_of(i) == OP_GEP {
            if gm_analyze_uses(i, want_readers, want_writers, -1) { return true; }
        } else if opcode_of(i) == OP_BITCAST || opcode_of(i) == OP_ADDRSPACECAST {
            if gm_analyze_uses(i, want_readers, want_writers, okay_store) { return true; }
        } else if is_callbase(i) {
            if inst_iid(i) == IID_threadlocal_address && v == cb_arg(i, 0) {
                if gm_analyze_uses(i, want_readers, want_writers, -1) { return true; }
                continue;
            }
            let ndata = cb_nargs(i) + cb_bundle_ops(i);
            if opno < ndata {
                if opno < cb_nargs(i) && gm_frees_operand(i, opno) {
                    if want_writers { gm_add_fn(gm_writers, inst_func(i)); }
                } else {
                    let f = called_function(i);
                    if f < 0 || !func_is_decl(f) { return true; }
                    if !call_has_fn_attr(i, AK_NoCallback) || opno >= cb_nargs(i) || cb_capture_info(i, opno) != 0 { return true; }
                    if want_readers { gm_add_fn(gm_readers, inst_func(i)); }
                    if want_writers { gm_add_fn(gm_writers, inst_func(i)); }
                }
            }
        } else if is_inst_op(i, OP_ICMP) {
            let o1 = op(i, 1);
            if !(vals[o1].kind == VK_CNULL && !ty_is_vector(vals[o1].ty)) { return true; }
        } else if is_constant(i) {
            if is_global(i) || gm_constant_used(i) { return true; }
        } else {
            return true;
        }
    }
    return false;
}

// AnalyzeIndirectGlobalMemory
fn gm_analyze_indirect(gv: i32) -> bool {
    if nops(gv) > 0 {
        let c = op(gv, 0);
        if vals[c].kind != VK_CNULL { return false; }
    }
    var allocs: i32[>..<] = [];
    var u = vals[gv].first_use;
    while u >= 0 {
        let x = uses[u].user;
        u = uses[u].next;
        if is_inst_op(x, OP_LOAD) {
            if gm_analyze_uses(x, false, false, -1) { return false; }
        } else if is_inst_op(x, OP_STORE) {
            if op(x, 0) == gv { return false; }
            if vals[op(x, 0)].kind == VK_CNULL { continue; }
            let p = get_underlying_object(op(x, 0), 10);
            if !aa_is_noalias_call(p) { return false; }
            if gm_analyze_uses(p, false, false, gv) { return false; }
            allocs.push(p);
        } else {
            return false;
        }
    }
    while allocs.len > 0 { let p = allocs.pop(); gm_alloc_for[p] = gv; }
    gm_indirect[gv] = true;
    return true;
}

// AnalyzeGlobals
fn gm_analyze_globals(m: i32) {
    var f = modules[m].first_func;
    while f >= 0 {
        if gm_local_linkage(f) {
            gm_readers.clear();
            gm_writers.clear();
            if !gm_analyze_uses(f, false, false, -1) { gm_nonaddr[f] = true; }
            else { gm_unknown_local_fns = true; }
        }
        f = globs[glob_of(f)].next;
    }
    var g = modules[m].first_gvar;
    while g >= 0 {
        if gm_local_linkage(g) {
            gm_readers.clear();
            gm_writers.clear();
            let is_const = globs[glob_of(g)].is_const != 0;
            if !gm_analyze_uses(g, true, !is_const, -1) {
                gm_nonaddr[g] = true;
                for r in gm_readers { gm_fi_get(r); gm_fi_add_for_global(r, g, MR_REF); }
                if !is_const { for w in gm_writers { gm_fi_get(w); gm_fi_add_for_global(w, g, MR_MOD); } }
                if ty_kind(globs[glob_of(g)].vty) == TK_PTR { gm_analyze_indirect(g); }
            }
        }
        g = globs[glob_of(g)].next;
    }
}

// ---------------------------------------------------------------------------------------------
// CallGraph and its SCCs

// node 0 = ExternalCallingNode, node 1 = CallsExternalNode; edges are linked lists in order
var cg_fn: i32[>..];
var cg_head: i32[>..];
var cg_tail: i32[>..];
var cg_edge_to: i32[>..];
var cg_edge_next: i32[>..];
var cg_node_of: i32[>..];       // function value id -> node (-1)

fn cg_node(f: i32) -> i32 {
    while cg_node_of.len < vals.len { cg_node_of.push(-1); }
    if f >= 0 && cg_node_of[f] >= 0 { return cg_node_of[f]; }
    let n = cg_fn.len as i32;
    cg_fn.push(f);
    cg_head.push(-1);
    cg_tail.push(-1);
    if f >= 0 { cg_node_of[f] = n; }
    return n;
}
fn cg_add_edge(from: i32, to: i32) {
    let e = cg_edge_to.len as i32;
    cg_edge_to.push(to);
    cg_edge_next.push(-1);
    if cg_tail[from] >= 0 { cg_edge_next[cg_tail[from]] = e; } else { cg_head[from] = e; }
    cg_tail[from] = e;
}

// Function::hasAddressTaken(nullptr, IgnoreCallbackUses=true, IgnoreAssumeLikeCalls=true, IgnoreLLVMUsed=false)
fn cg_has_address_taken(f: i32) -> bool {
    var u = vals[f].first_use;
    while u >= 0 {
        let x = uses[u].user;
        let opno = (u - vals[x].ops) as i64;
        u = uses[u].next;
        if !is_callbase(x) {
            let o = opcode_of(x);
            if o == OP_BITCAST || o == OP_ADDRSPACECAST {
                var all = true;
                var w = vals[x].first_use;
                while w >= 0 { let y = uses[w].user; if !(is_inst(y) && iop(y) == OP_CALL && gm_is_assume_like(y)) { all = false; } w = uses[w].next; }
                if all { continue; }
            }
            return true;
        }
        if iop(x) == OP_CALL && gm_is_assume_like(x) { continue; }
        if opno != nops(x) - 1 || insts[inst_of(x)].ty2 != func_type(f) { return true; }
    }
    return false;
}

fn cg_build(m: i32) {
    cg_fn.clear(); cg_head.clear(); cg_tail.clear(); cg_edge_to.clear(); cg_edge_next.clear();
    for k in cg_node_of.len { cg_node_of[k] = -1; }
    let ext = cg_node(-1);
    let calls_ext = cg_node(-1);
    var f = modules[m].first_func;
    while f >= 0 {
        let n = cg_node(f);
        if !gm_local_linkage(f) || cg_has_address_taken(f) { cg_add_edge(ext, n); }
        if func_is_decl(f) && !func_has_fn_attr(f, AK_NoCallback) { cg_add_edge(n, calls_ext); }
        each_inst(f) { i =>
            if is_callbase(i) {
                let c = called_function(i);
                if c < 0 { cg_add_edge(n, calls_ext); } else { cg_add_edge(n, cg_node(c)); }
                if inst_get_md(i, md_kind_id("callback")) >= 0 || (is_func(c) && globs[glob_of(c)].nmd > 0 && func_get_md_kind(c, "callback")) {
                    fatal("CallGraph: !callback metadata is not ported yet");
                }
            }
        };
        f = globs[glob_of(f)].next;
    }
}
fn func_get_md_kind(f: i32, name: const u8[:]) -> bool {
    let k = md_kind_id(name);
    let g = globs[glob_of(f)];
    for j in g.nmd as i64 { if md_att[(g.md as i64) + 2 * j] == k { return true; } }
    return false;
}

// Tarjan's SCCs from ExternalCallingNode (scc_iterator); emits SCCs (as node runs in cg_scc) in order
var cg_scc: i32[>..];         // concatenated SCC members
var cg_scc_at: i32[>..];      // start of each SCC
fn cg_compute_sccs() {
    cg_scc.clear();
    cg_scc_at.clear();
    let nn = cg_fn.len;
    var visit_num: i64[>..] = [];
    for k in nn { visit_num.push(0); }
    var counter: i64 = 0;
    var node_stack: i32[>..<] = [];
    var vs_node: i32[>..<] = [];
    var vs_edge: i32[>..<] = [];
    var vs_min: i64[>..<] = [];
    fn visit_one(n: i32) {
        counter++;
        visit_num[n] = counter;
        node_stack.push(n);
        vs_node.push(n);
        vs_edge.push(cg_head[n]);
        vs_min.push(counter);
    }
    visit_one(0);
    while vs_node.len > 0 {
        // DFSVisitChildren
        loop {
            let t = vs_node.len - 1;
            let e = vs_edge[t];
            if e < 0 { break; }
            vs_edge[t] = cg_edge_next[e];
            let c = cg_edge_to[e];
            if visit_num[c] == 0 { visit_one(c); continue; }
            if vs_min[t] > visit_num[c] { vs_min[t] = visit_num[c]; }
        }
        let t = vs_node.len - 1;
        let vn = vs_node[t];
        let mn = vs_min[t];
        vs_node.pop();
        vs_edge.pop();
        vs_min.pop();
        if vs_node.len > 0 && vs_min[vs_node.len - 1] > mn { vs_min[vs_node.len - 1] = mn; }
        if mn != visit_num[vn] { continue; }
        cg_scc_at.push(cg_scc.len as i32);
        loop {
            let x = node_stack.pop();
            cg_scc.push(x);
            visit_num[x] = 0xFFFFFFFF;
            if x == vn { break; }
        }
    }
}

// Function::isDefinitionExact (!mayBeDerefined)
fn gm_definition_exact(f: i32) -> bool {
    // GlobalValue::isDefinitionExact = !mayBeDerefined (isInterposable counts noipa definitions and semantic
    // interposition)
    return !gv_may_be_derefined(f);
}

// AnalyzeCallGraph
fn gm_analyze_call_graph() {
    let nscc = cg_scc_at.len;
    for s in nscc {
        let st = cg_scc_at[s] as i64;
        let en = if s + 1 < nscc { cg_scc_at[s + 1] as i64 } else { cg_scc.len };
        let f = cg_fn[cg_scc[st]];
        if f < 0 || !gm_definition_exact(f) {
            for k in st..en { gm_fi_erase(cg_fn[cg_scc[k]]); }
            continue;
        }
        gm_fi_get(f);
        var know_nothing = false;
        var i = st;
        while i < en && !know_nothing {
            if func_is_decl(f) || func_has_fn_attr(f, AK_OptimizeNone) {
                let me = ml_func_memory_effects(f);
                if me == 0 {
                } else if !mr_is_mod(me_modref(me)) {
                    gm_fi_add_modref(f, MR_REF);
                    if !me_only_arg(me) && gm_may_sync_or_call_into_module(f) { gm_fi_set_may_read_any(f); }
                } else {
                    gm_fi_add_modref(f, MR_MODREF);
                    if !me_only_arg(me) { gm_fi_set_may_read_any(f); }
                    if gm_may_sync_or_call_into_module(f) { know_nothing = true; break; }
                }
                i++;
                continue;
            }
            var e = cg_head[cg_scc[i]];
            while e >= 0 && !know_nothing {
                let cn = cg_edge_to[e];
                let callee = cg_fn[cn];
                if callee >= 0 {
                    if gm_has_fi(callee) { gm_fi_add_info(f, callee); }
                    else {
                        var in_scc = false;
                        for k in st..en { if cg_scc[k] == cn { in_scc = true; } }
                        if !in_scc { know_nothing = true; }
                    }
                } else {
                    know_nothing = true;
                }
                e = cg_edge_next[e];
            }
            i++;
        }
        if know_nothing {
            for k in st..en { gm_fi_erase(cg_fn[cg_scc[k]]); }
            continue;
        }
        for k in st..en {
            if gm_fi_modref(f) == MR_MODREF { break; }
            let nf = cg_fn[cg_scc[k]];
            if func_has_fn_attr(nf, AK_OptimizeNone) { continue; }
            var done = false;
            each_inst(nf) { x =>
                if !done {
                    if gm_fi_modref(f) == MR_MODREF { done = true; }
                    else if !is_callbase(x) {
                        if inst_may_read_memory(x) { gm_fi_add_modref(f, MR_REF); }
                        if inst_may_write_memory(x) { gm_fi_add_modref(f, MR_MOD); }
                    }
                }
            };
        }
        for k in st + 1..en { gm_fi_copy(cg_fn[cg_scc[k]], f); }
    }
}
fn gm_may_sync_or_call_into_module(f: i32) -> bool {
    return !func_is_decl(f) || !func_has_fn_attr(f, AK_NoSync) || !func_has_fn_attr(f, AK_NoCallback);
}

// GlobalsAA::run (require<globals-aa>)
fn gm_compute(m: i32) {
    gm_grow();
    for k in gm_nonaddr.len { gm_nonaddr[k] = false; gm_indirect[k] = false; gm_alloc_for[k] = -1; gm_fi[k] = -1; }
    gm_pg.clear();
    gm_pm.clear();
    gm_unknown_local_fns = false;
    cg_build(m);
    cg_compute_sccs();
    gm_analyze_globals(m);
    gm_analyze_call_graph();
    gm_unknown_computed = gm_unknown_local_fns;
    // GlobalsAA::run returns the result by value into the analysis manager, and the move constructor of
    // GlobalsAAResult does not move UnknownFunctionsWithLocalLinkage: the cached result always has it false
    // (verified with opt 23.1.5: an escaping internal function does not disable the mod/ref refinement).
    gm_unknown_local_fns = false;
    gm_valid = true;
    gm_module = m;
}
fn gm_invalidate() { gm_valid = false; }

// RecomputeGlobalsAAPass::run on the cached result: everything is cleared and recomputed in place, so
// UnknownFunctionsWithLocalLinkage keeps what AnalyzeGlobals computed (no move constructor in between).
fn gm_recompute(m: i32) {
    gm_compute(m);
    gm_unknown_local_fns = gm_unknown_computed;
}

// ---------------------------------------------------------------------------------------------
// Queries

// getUnderlyingObjects(V, Objects) with MaxLookup = 10 and no LoopInfo
fn gm_underlying_objects(v: i32, out: i32[>..<]&) {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(v);
    while wl.len > 0 {
        let p = get_underlying_object(wl.pop(), 10);
        var dup = false;
        for s in seen { if s == p { dup = true; } }
        if dup { continue; }
        seen.push(p);
        if is_inst_op(p, OP_SELECT) { wl.push(op(p, 1)); wl.push(op(p, 2)); continue; }
        if is_inst_op(p, OP_PHI) { for k in nops(p) { wl.push(op(p, k)); } continue; }
        out.push(p);
    }
}

fn gm_is_global_value(v: i32) -> bool { let k = vals[v].kind; k == VK_FUNC || k == VK_GVAR || k == VK_ALIAS || k == VK_IFUNC }

// isNonEscapingGlobalNoAliasWithLoad
fn gm_noalias_with_load(gv: i32, v: i32, depth: i64&) -> bool {
    var visited: i32[>..<] = [];
    var inputs: i32[>..<] = [];
    visited.push(v);
    inputs.push(v);
    fn visit(x: i32) {
        for y in visited { if y == x { return; } }
        visited.push(x);
        inputs.push(x);
    }
    while inputs.len > 0 {
        let input = inputs.pop();
        if gm_is_global_value(input) || is_arg(input) || is_inst_op(input, OP_CALL) || is_inst_op(input, OP_INVOKE) { continue; }
        depth += 1;
        if depth > 4 { return false; }
        if is_inst_op(input, OP_LOAD) { inputs.push(get_underlying_object(op(input, 0), 10)); continue; }
        if is_inst_op(input, OP_SELECT) {
            visit(get_underlying_object(op(input, 1), 10));
            visit(get_underlying_object(op(input, 2), 10));
            continue;
        }
        if is_inst_op(input, OP_PHI) {
            for k in nops(input) { visit(get_underlying_object(op(input, k), 10)); }
            continue;
        }
        return false;
    }
    return true;
}

// isNonEscapingGlobalNoAlias
fn gm_non_escaping_noalias(gv: i32, v: i32, cxt: i32) -> bool {
    if ty_kind(vals[v].ty) != TK_PTR { return true; }
    var visited: i32[>..<] = [];
    var inputs: i32[>..<] = [];
    visited.push(v);
    inputs.push(v);
    fn visit(x: i32) {
        for y in visited { if y == x { return; } }
        visited.push(x);
        inputs.push(x);
    }
    var depth: i64 = 0;
    while inputs.len > 0 {
        let input = inputs.pop();
        if gm_is_global_value(input) {
            if input == gv { return false; }
            if vals[gv].kind == VK_GVAR && vals[input].kind == VK_GVAR && nops(gv) > 0 && nops(input) > 0 &&
               !gm_interposable(gv) && !gm_interposable(input) {
                let t1 = vals[op(gv, 0)].ty;
                let t2 = vals[op(input, 0)].ty;
                if dl_alloc_size(t1) > 0 && dl_alloc_size(t2) > 0 { continue; }
            }
            return false;
        }
        if is_arg(input) || is_inst_op(input, OP_CALL) || is_inst_op(input, OP_INVOKE) { continue; }
        if cxt >= 0 && vals[input].kind == VK_CNULL && !ty_is_vector(vals[input].ty) {
            if !null_pointer_is_defined(inst_func(cxt), types[vals[input].ty].n as i64) { continue; }
        }
        depth++;
        if depth > 4 { return false; }
        if is_inst_op(input, OP_LOAD) {
            let p = get_underlying_object(op(input, 0), 10);
            if gm_noalias_with_load(gv, p, depth) { continue; }
            return false;
        }
        if is_inst_op(input, OP_SELECT) {
            visit(get_underlying_object(op(input, 1), 10));
            visit(get_underlying_object(op(input, 2), 10));
            continue;
        }
        if is_inst_op(input, OP_PHI) {
            for k in nops(input) { visit(get_underlying_object(op(input, k), 10)); }
            continue;
        }
        return false;
    }
    return true;
}
fn gm_interposable(v: i32) -> bool {
    let l = globs[glob_of(v)].linkage as i64;
    return l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK;
}

// GlobalsAAResult::alias: true = MayAlias
fn gm_alias_may(a: ML, b: ML, cxt: i32) -> bool {
    let uv1 = get_underlying_object(bas_strip(a.ptr), 10);
    let uv2 = get_underlying_object(bas_strip(b.ptr), 10);
    var g1 = if gm_is_global_value(uv1) { uv1 } else { -1 };
    var g2 = if gm_is_global_value(uv2) { uv2 } else { -1 };
    if g1 >= 0 || g2 >= 0 {
        if g1 >= 0 && !gm_is_nonaddr(g1) { g1 = -1; }
        if g2 >= 0 && !gm_is_nonaddr(g2) { g2 = -1; }
        if g1 >= 0 && g2 >= 0 && g1 != g2 { return false; }
        if (g1 >= 0 || g2 >= 0) && g1 != g2 {
            let gv = if g1 >= 0 { g1 } else { g2 };
            let uv = if g1 >= 0 { uv2 } else { uv1 };
            if gm_non_escaping_noalias(gv, uv, cxt) { return false; }
        }
    }
    g1 = -1;
    g2 = -1;
    if is_inst_op(uv1, OP_LOAD) { let g = op(uv1, 0); if vals[g].kind == VK_GVAR && gm_in(g) && gm_indirect[g] { g1 = g; } }
    if is_inst_op(uv2, OP_LOAD) { let g = op(uv2, 0); if vals[g].kind == VK_GVAR && gm_in(g) && gm_indirect[g] { g2 = g; } }
    if g1 < 0 && gm_in(uv1) { g1 = gm_alloc_for[uv1]; }
    if g2 < 0 && gm_in(uv2) { g2 = gm_alloc_for[uv2]; }
    if g1 >= 0 && g2 >= 0 && g1 != g2 { return false; }
    return true;
}

// getModRefInfoForArgument
fn gm_mod_ref_for_argument(c: i32, gv: i32) -> i64 {
    let me = call_memory_effects(c);
    if me == 0 { return MR_NO; }
    let conservative = if !mr_is_mod(me_modref(me)) { MR_REF } else { MR_MODREF };
    for k in cb_nargs(c) {
        var objs: i32[>..<] = [];
        gm_underlying_objects(cb_arg(c, k), objs);
        var all_ident = true;
        for o in objs { if !aa_is_identified_object(o) { all_ident = false; } }
        if !all_ident {
            var all_noalias = true;
            for o in objs { if gm_alias_may(ml_before_or_after(o), ml_before_or_after(gv), c) { all_noalias = false; break; } }
            if !all_noalias { return conservative; }
        }
        for o in objs { if o == gv { return conservative; } }
    }
    return MR_NO;
}

// GlobalsAAResult::getModRefInfo(Call, Loc)
fn gm_call_loc_mr(c: i32, loc: ML) -> i64 {
    var known = MR_MODREF;
    let gv = get_underlying_object(loc.ptr, 10);
    if gm_is_global_value(gv) && gm_local_linkage(gv) && !gm_unknown_local_fns {
        let f = called_function(c);
        if f >= 0 && gm_is_nonaddr(gv) && gm_has_fi(f) {
            known = gm_fi_for_global(f, gv) | gm_mod_ref_for_argument(c, gv);
        }
    }
    return known;
}

// GlobalsAAResult::getMemoryEffects(F)
fn gm_fn_me(f: i32) -> u64 {
    if gm_has_fi(f) { return me_of(gm_fi_modref(f)); }
    return me_of(MR_MODREF);
}
