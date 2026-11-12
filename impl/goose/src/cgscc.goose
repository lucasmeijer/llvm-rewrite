// The CGSCC pass manager: port of llvm/lib/Analysis/CGSCCPassManager.cpp (PassManager<SCC>::run,
// ModuleToPostOrderCGSCCPassAdaptor::run, DevirtSCCRepeatedPass::run, CGSCCToFunctionPassAdaptor::run,
// updateCGAndAnalysisManagerForPass / ForFunctionPass / ForCGSCCPass, incorporateNewSCCRange, the proxies'
// invalidate) and the CGSCCUpdateResult of llvm/include/llvm/Analysis/CGSCCPassManager.h.
//
// Analysis managers: function analyses are the global per-function caches of the pass manager; the CGSCC
// analysis manager holds no results whose staleness shows in the output, so "AM.invalidate(C, PA)" is the
// FunctionAnalysisManagerCGSCCProxy's effect: the functions of C get `invalidate_function(F, PA)` unless every
// function analysis is preserved. Preserved-analysis bits beyond the function analyses: A_LCG
// (LazyCallGraphAnalysis), A_FAMPROXY (FunctionAnalysisManagerCGSCCProxy), A_SCC_ALL
// (AllAnalysesOn<LazyCallGraph::SCC>); PA_FN = every function analysis (AllAnalysesOn<Function>).
//
// CGSCCUpdateResult is global state (`ur_*`); one ModuleToPostOrderCGSCCPassAdaptor runs at a time.
// The CGSCC pipeline runners form one recursive cycle (nested cgscc(...) / devirt<N>(...)), so they keep no
// growable locals: DevirtSCCRepeatedPass's CallCounts live on `dv_counts` above a mark.
import argpromotion;
import std;
import ir;
import irutil;
import instinfo;
import flags;
import analyses;
import scev;
import ivec;
import wvh;
import lcg;
import passmgr;
import function_attrs;
import inliner;
import ipoutil;

// ---------------------------------------------------------------------------------------------
// CGSCCUpdateResult

// SmallPriorityWorklist<SCC *>: vector with null (-1) holes + index map
var ur_cwl: i32[>..<];
var ur_cwl_idx = hm_new();
var ur_invalid = hm_new();          // InvalidatedSCCs
var ur_updated_c: i32 = -1;         // UpdatedC
var ur_cross_pa: u32 = 0xFFFFFFFF;  // CrossSCCPA
var ur_inlined_internal = hm_new(); // InlinedInternalEdges: (node, SCC)
var ur_dead_fns: i32[>..];          // DeadFunctions
// IndirectVHs: SmallMapVector<Value *, WeakTrackingVH>
var ur_vh_keys: i32[>..];
var ur_vh_h: i32[>..];
var ur_vh_idx = hm_new();
var ur_vh_mark: i64 = 0;

fn cwl_insert(c: i32) {
    let key = (c as i64) as u64;
    let i = hm_get(ur_cwl_idx, key, -1);
    if i < 0 { hm_put(ur_cwl_idx, key, ur_cwl.len); ur_cwl.push(c); return; }
    if i != ur_cwl.len - 1 {
        ur_cwl[i] = -1;
        hm_put(ur_cwl_idx, key, ur_cwl.len);
        ur_cwl.push(c);
    }
}
fn cwl_pop() -> i32 {
    let c = ur_cwl[ur_cwl.len - 1];
    hm_del(ur_cwl_idx, (c as i64) as u64);
    loop {
        ur_cwl.pop();
        if ur_cwl.len == 0 || ur_cwl[ur_cwl.len - 1] != -1 { break; }
    }
    return c;
}

fn ur_is_invalid(c: i32) -> bool { hm_has(ur_invalid, (c as i64) as u64) }
fn ur_mark_invalid(c: i32) { hm_put(ur_invalid, (c as i64) as u64, 1); }

fn ur_vh_clear() {
    wvh_release(ur_vh_mark);
    ur_vh_keys.resize(0);
    ur_vh_h.resize(0);
    hm_clear(ur_vh_idx);
}
fn ur_vh_find(k: i32) -> i64 { hm_get(ur_vh_idx, (k as i64) as u64, -1) }
fn ur_vh_insert(k: i32) {
    if ur_vh_find(k) >= 0 { return; }
    hm_put(ur_vh_idx, (k as i64) as u64, ur_vh_keys.len);
    ur_vh_keys.push(k);
    ur_vh_h.push(wvh_new(k, WVH_WEAK_TRACKING));
}

// The SCC's printed name for instrumentation: "(f, g)"
fn cg_scc_unit(c: i32) -> u8[] {
    var s: u8[>..] = [];
    s.push('(');
    let n = lcg_scc_size(c);
    for k in n {
        if k > 0 { s.append(", "); }
        if k > 8 { s.append("..., "); s.append(val_name(lcg_fn(lcg_scc_node(c, n - 1)))); break; }
        s.append(val_name(lcg_fn(lcg_scc_node(c, k))));
    }
    s.push(')');
    return s;
}

// AM.invalidate(C, PA) through FunctionAnalysisManagerCGSCCProxy::Result::invalidate
fn cg_invalidate_scc(c: i32, pa: u32) {
    if pa == PA_ALL || (pa & PA_FN) == PA_FN { return; }
    let n = lcg_scc_size(c);
    for k in n { invalidate_function(lcg_fn(lcg_scc_node(c, k)), pa); }
}

// ---------------------------------------------------------------------------------------------
// updateCGAndAnalysisManagerForPass

// incorporateNewSCCRange: new SCCs [b, e) of RefSCC rc replaced c
fn cg_incorporate_new_scc_range(rc: i32, b: i64, e: i64, c: i32) -> i32 {
    if b == e { return c; }
    cwl_insert(c);
    let nc = lcg_rc_scc(rc, b);
    // AM.invalidate(*OldC, allInSet<AllAnalysesOn<Function>> + FAM proxy): no function analysis is touched
    var k = e - 1;
    while k > b { cwl_insert(lcg_rc_scc(rc, k)); k--; }
    return nc;
}

// A SmallSetVector<Node *> as a local array (insertion order, no duplicates)
fn cg_setvec_insert(v: i32[>..<]&, x: i32) { for y in v { if y == x { return; } } v.push(x); }

fn cg_update_for_pass(c0: i32, n: i32, function_pass: bool) -> i32 {
    var c = c0;
    let rc = lcg_sccs[c].rc;
    let f = lcg_fn(n);
    var worklist: i32[>..<] = [];
    var visited = hm_new();
    var retained = hm_new();
    var promoted: i32[>..<] = [];
    var demoted: i32[>..<] = [];
    var new_calls: i32[>..<] = [];
    var new_refs: i32[>..<] = [];
    each_inst(f) { i =>
        if is_callbase(i) {
            let callee = called_function(i);
            if callee >= 0 {
                if !hm_has(visited, (callee as i64) as u64) {
                    hm_put(visited, (callee as i64) as u64, 1);
                    if !func_is_decl(callee) {
                        let cn = lcg_lookup(callee);
                        if cn < 0 { fatal("internal: CGSCC update: a function without a call graph node is called"); }
                        let ei = lcg_seq_lookup(n, cn);
                        if function_pass && ei < 0 { fatal("internal: a function pass introduced a new call edge"); }
                        hm_put(retained, (cn as i64) as u64, 1);
                        if ei < 0 { cg_setvec_insert(new_calls, cn); }
                        else if !lcg_e_call(iv_get(lcg_edges(n), ei)) { cg_setvec_insert(promoted, cn); }
                    }
                }
            } else {
                let ei = ur_vh_find(i);
                if ei < 0 { ur_vh_insert(i); }
                else if wvh_get(ur_vh_h[ei]) < 0 { wvh_set(ur_vh_h[ei], i); }
            }
        }
    };
    each_inst(f) { i => lcg_push_const_operands(i, worklist, visited); };
    var refs: i32[>..<] = [];
    lcg_visit_references(worklist, visited, refs);
    // VisitRef
    fn visit_ref(r: i32) {
        let rn = lcg_lookup(r);
        if rn < 0 { fatal("internal: CGSCC update: a function without a call graph node is referenced"); }
        let ei = lcg_seq_lookup(n, rn);
        if function_pass && ei < 0 { fatal("internal: a function pass introduced a new ref edge"); }
        hm_put(retained, (rn as i64) as u64, 1);
        if ei < 0 { cg_setvec_insert(new_refs, rn); }
        else if lcg_e_call(iv_get(lcg_edges(n), ei)) { cg_setvec_insert(demoted, rn); }
    }
    for r in refs { visit_ref(r); }
    for t in new_refs { lcg_insert_trivial_ref_edge(n, t); }
    for t in new_calls { lcg_insert_trivial_ref_edge(n, t); }
    for k in lcg_lib_fns.len {
        let lf = lcg_lib_fns[k];
        if !hm_has(visited, (lf as i64) as u64) { visit_ref(lf); }
    }
    // dead edges
    var dead_targets: i32[>..<] = [];
    {
        let s = lcg_edges(n);
        var i = lcg_next_edge(s, 0);
        while i < iv_len(s) {
            let e = iv_get(s, i);
            let t = lcg_e_node(e);
            if !hm_has(retained, (t as i64) as u64) {
                let tc = lcg_lookup_scc(t);
                let trc = lcg_sccs[tc].rc;
                if trc == rc && lcg_e_call(e) {
                    if c != tc { lcg_switch_trivial_internal_edge_to_ref(n, t); }
                    else {
                        let b, en = lcg_switch_internal_edge_to_ref(rc, n, t);
                        c = cg_incorporate_new_scc_range(rc, b, en, c);
                    }
                }
                dead_targets.push(t);
            }
            i = lcg_next_edge(lcg_edges(n), i + 1);
        }
    }
    // erase_if: only edges leaving the RefSCC are removed; dead internal ref edges stay (LLVM 23 leaves them
    // to removeDeadFunctions)
    for t in dead_targets {
        let trc = lcg_sccs[lcg_lookup_scc(t)].rc;
        if trc != rc { lcg_remove_outgoing_edge(n, t); }
    }
    for t in demoted {
        let tc = lcg_lookup_scc(t);
        let trc = lcg_sccs[tc].rc;
        if trc != rc { lcg_switch_outgoing_edge_to_ref(n, t); continue; }
        if c != tc { lcg_switch_trivial_internal_edge_to_ref(n, t); continue; }
        let b, en = lcg_switch_internal_edge_to_ref(rc, n, t);
        c = cg_incorporate_new_scc_range(rc, b, en, c);
    }
    for t in new_calls { cg_setvec_insert(promoted, t); }
    for t in promoted {
        let tc = lcg_lookup_scc(t);
        let trc = lcg_sccs[tc].rc;
        if trc != rc { lcg_switch_outgoing_edge_to_call(n, t); continue; }
        let init_idx = lcg_rc_find(rc, c);
        var merged: i32[>..<] = [];
        let formed = lcg_switch_internal_edge_to_call(rc, n, t, merged);
        for mc in merged { ur_mark_invalid(mc); }
        if formed { c = tc; }
        let new_idx = lcg_rc_find(rc, c);
        if init_idx < new_idx {
            cwl_insert(c);
            var k = new_idx - 1;
            while k >= init_idx { cwl_insert(lcg_rc_scc(rc, k)); k--; }
        }
    }
    if c != c0 { ur_updated_c = c; }
    return c;
}

// ---------------------------------------------------------------------------------------------
// Running

fn cg_should_run(n: i32, c: i32) -> bool {
    if pnodes[n].required || bisect_limit < 0 { return true; }
    return should_run(n, cg_scc_unit(c));
}

// PassManager<SCC>::run over the children of node n; returns the PA. UR.UpdatedC tells the caller the new SCC.
recursive fn cg_run_pm(n: i32, c0: i32) -> u32 {
    var pa = PA_ALL;
    var c = c0;
    var ch = pnodes[n].first;
    while ch >= 0 {
        if cg_should_run(ch, c) {
            let ppa = cg_run_pass(ch, c);
            if ur_updated_c >= 0 { c = ur_updated_c; }
            pa &= ppa;
            if ur_is_invalid(c) { break; }
            cg_invalidate_scc(c, ppa);
        }
        ch = pnodes[ch].next;
    }
    ur_cross_pa &= pa;
    pa |= (1 as u32) << A_SCC_ALL;
    return pa;
}

// One CGSCC-level element on SCC c.
recursive fn cg_run_pass(n: i32, c: i32) -> u32 {
    let k = pnodes[n].kind;
    if k == PK_CGSCC_PM { return cg_run_pm(n, c); }
    if k == PK_DEVIRT { return cg_run_devirt(n, c); }
    if k == PK_CGFN { return cg_run_fn_adaptor(n, c); }
    let p = pnodes[n].pass as i64;
    if p == P_NOOP_CGSCC { return PA_ALL; }
    if p == P_CG_INVALIDATE { return PA_ALL & ~((1 as u32) << A_NOOP_CGSCC); }
    if p == P_FUNCTION_ATTRS { let pa = fa_run_cgscc(c, pnodes[n].arg != 0); ap_pool_reset(); return pa; }
    if p == P_INLINE { let pa = inl_run_cgscc(c, pnodes[n].arg != 0); ap_pool_reset(); return pa; }
    if p == P_ARGPROMOTION { let pa = argpromotion_run_cgscc(c); ap_pool_reset(); return pa; }
    fatal("internal: unknown CGSCC pass id");
    return PA_ALL;
}

// DevirtSCCRepeatedPass::run. CallCounts: (function, direct, indirect) triples on dv_counts from a mark.
struct DVC { f: i32, direct: i32, indirect: i32 }
var dv_counts: DVC[>..<];

recursive fn dv_scan(c: i32) {
    let n = lcg_scc_size(c);
    for k in n {
        let f = lcg_fn(lcg_scc_node(c, k));
        var direct: i32 = 0;
        var indirect: i32 = 0;
        each_inst(f) { i =>
            if is_callbase(i) {
                if called_function(i) >= 0 { direct++; }
                else { indirect++; ur_vh_insert(i); }
            }
        };
        // CallCounts.insert: the first entry for a function wins
        dv_counts.push(DVC { f: f, direct: direct, indirect: indirect });
    }
}

recursive fn cg_run_devirt(n: i32, c: i32) -> u32 {
    var pa = PA_ALL;
    let max_it = pnodes[n].arg as i64;
    ur_vh_clear();
    var base = dv_counts.len;
    dv_scan(c);
    var iteration: i64 = 0;
    loop {
        let ppa = cg_run_pm(n, c);
        pa &= ppa;
        if ur_is_invalid(c) { break; }
        cg_invalidate_scc(c, ppa);
        if ur_updated_c >= 0 && ur_updated_c != c { break; }
        var devirt = false;
        for j in ur_vh_keys.len {
            let v = wvh_get(ur_vh_h[j]);
            if v >= 0 && is_callbase(v) && called_function(v) >= 0 { devirt = true; break; }
        }
        ur_vh_clear();
        let nb = dv_counts.len;
        dv_scan(c);
        if !devirt {
            for j in nb..dv_counts.len {
                let nw = dv_counts[j];
                for q in base..nb {
                    if dv_counts[q].f != nw.f { continue; }
                    if dv_counts[q].indirect > nw.indirect && dv_counts[q].direct < nw.direct { devirt = true; }
                    break;
                }
                if devirt { break; }
            }
        }
        if !devirt { dv_counts.resize(base); break; }
        if iteration >= max_it {
            if flag_bool("abort-on-max-devirt-iterations-reached", false) {
                write_stderr("LLVM ERROR: Max devirtualization iterations reached\n");
                exit(1);
            }
            dv_counts.resize(base);
            break;
        }
        // CallCounts = NewCallCounts
        for j in nb..dv_counts.len { dv_counts[base + j - nb] = dv_counts[j]; }
        dv_counts.resize(base + dv_counts.len - nb);
        iteration++;
    }
    return pa;
}

// CGSCCToFunctionPassAdaptor::run. arg bit 0: EagerlyInvalidate, bit 1: NoRerun.
recursive fn cg_run_fn_adaptor(n: i32, c: i32) -> u32 {
    let base = cg_nodes_stack.len;
    let m = lcg_scc_size(c);
    for k in m { cg_nodes_stack.push(lcg_scc_node(c, k)); }
    var cur = c;
    var pa = PA_ALL;
    let eager = (pnodes[n].arg & 1) != 0;
    var k = base;
    while k < cg_nodes_stack.len {
        let nd = cg_nodes_stack[k];
        k++;
        if lcg_lookup_scc(nd) != cur { continue; }
        let f = lcg_fn(nd);
        // the function pipeline (a FunctionPassManager: its PA preserves AllAnalysesOn<Function>)
        fn_pa_acc = PA_ALL;
        var ch = pnodes[n].first;
        while ch >= 0 { run_function_node(ch, f); ch = pnodes[ch].next; }
        var ppa = fn_pa_acc;
        if pnodes[n].pass != 0 { ppa |= PA_FN; }    // wrapped in a FunctionPassManager
        if eager { invalidate_function(f, PA_NONE); } else { invalidate_function(f, ppa); }
        pa &= ppa;
        if (ppa & ((1 as u32) << A_LCG)) == 0 {
            cur = cg_update_for_pass(cur, nd, true);
        }
    }
    cg_nodes_stack.resize(base);
    pa |= PA_FN | ((1 as u32) << A_FAMPROXY) | ((1 as u32) << A_LCG);
    return pa;
}
var cg_nodes_stack: i32[>..<];

// ModuleToPostOrderCGSCCPassAdaptor::run (node n: a PK_CGSCC whose children are the CGSCC pipeline)
fn cg_run_adaptor(n: i32, m: i32) -> u32 {
    lcg_get(m);
    ur_cwl.resize(0);
    hm_clear(ur_cwl_idx);
    hm_clear(ur_invalid);
    ur_updated_c = -1;
    ur_cross_pa = PA_ALL;
    hm_clear(ur_inlined_internal);
    ur_dead_fns.resize(0);
    ur_vh_mark = wvh_mark();
    ur_vh_keys.resize(0);
    ur_vh_h.resize(0);
    hm_clear(ur_vh_idx);
    var pa = PA_ALL;
    lcg_build_ref_sccs();
    var rc0 = lcg_postorder_from(0);
    while rc0 >= 0 {
        // make_early_inc_range: the next RefSCC is taken before visiting this one
        let next_rc = lcg_postorder_next(rc0);
        let rc = rc0;
        var last_updated: i32 = -1;
        let nc = lcg_rc_size(rc);
        var k = nc - 1;
        while k >= 0 { cwl_insert(lcg_rc_scc(rc, k)); k--; }
        while ur_cwl.len > 0 {
            var c = cwl_pop();
            if ur_is_invalid(c) { continue; }
            if last_updated == c { continue; }
            cg_invalidate_scc(c, ur_cross_pa);
            loop {
                last_updated = ur_updated_c;
                ur_updated_c = -1;
                // runBeforePass: the CGSCC pass manager is required (never skipped)
                let ppa = cg_run_pm(n, c);
                if ur_updated_c >= 0 { c = ur_updated_c; }
                ur_cross_pa &= ppa;
                pa &= ppa;
                if ur_is_invalid(c) { break; }
                cg_invalidate_scc(c, ppa);
                if ur_updated_c < 0 { break; }
            }
        }
        hm_clear(ur_inlined_internal);
        rc0 = next_rc;
    }
    lcg_remove_dead_functions(ur_dead_fns);
    for f in ur_dead_fns { func_erase_from_parent(f); }
    ur_dead_fns.resize(0);
    ur_vh_clear();
    pa |= ((1 as u32) << A_SCC_ALL) | ((1 as u32) << A_LCG) | ((1 as u32) << A_FAMPROXY);
    return pa;
}

