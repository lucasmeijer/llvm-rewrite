// The CGSCC pass manager: a port of llvm/lib/Analysis/CGSCCPassManager.cpp (PassManager<SCC>::run,
// ModuleToPostOrderCGSCCPassAdaptor::run with its RefSCC / SCC worklists, DevirtSCCRepeatedPass::run (devirt<N>),
// CGSCCToFunctionPassAdaptor::run, FunctionAnalysisManagerCGSCCProxy::Result::invalidate,
// updateCGAndAnalysisManagerForPass / ForFunctionPass / ForCGSCCPass, incorporateNewSCCRange,
// -abort-on-max-devirt-iterations-reached) and llvm/include/llvm/ADT/PriorityWorklist.h.
//
// There are no CGSCC analyses here except the FunctionAnalysisManagerCGSCCProxy, which exists for every SCC the walk
// touches and never invalidates itself; so CGSCCAnalysisManager::invalidate(C, PA) is `cgam_invalidate`: the
// function analyses of C's functions are invalidated with PA unless PA preserves AllAnalysesOn<Function>. The proxy
// invalidations with sets that preserve AllAnalysesOn<Function> are no-ops and left out.
//
// Everything that lives across a pass invocation is heap-allocated: the pass managers reset temporary storage after
// every pass.

// SmallPriorityWorklist<T *>
Prio_Worklist :: struct {
    v: [..] s32;
    m: Table(s32, s64);
}
pwl_insert :: (w: *Prio_Worklist, x: s32) -> bool {
    found, idx := table_find(*w.m, x);
    if !found {
        table_set(*w.m, x, w.v.count);
        array_add(*w.v, x);
        return true;
    }
    if idx != w.v.count - 1 {
        w.v[idx] = -1;
        table_set(*w.m, x, w.v.count);
        array_add(*w.v, x);
    }
    return false;
}
pwl_pop :: (w: *Prio_Worklist) -> s32 {
    r := w.v[w.v.count - 1];
    table_remove(*w.m, r);
    while true {
        w.v.count -= 1;
        if w.v.count == 0 || w.v[w.v.count - 1] != -1 break;
    }
    return r;
}
pwl_empty :: inline (w: *Prio_Worklist) -> bool { return w.v.count == 0; }
pwl_count :: (w: *Prio_Worklist, x: s32) -> bool { return table_contains(*w.m, x); }
pwl_free :: (w: *Prio_Worklist) { array_free(w.v); deinit(*w.m); }

// CGSCCUpdateResult
Cgscc_Ur :: struct {
    cwl: *Prio_Worklist;
    invalidated: Table(s32, bool);              // InvalidatedSCCs
    updated_c: s32 = -1;                        // UpdatedC
    cross_scc_pa: Preserved = PRESERVE_ALL;     // CrossSCCPA
    inlined_internal_edges: Table(u64, bool);   // InlinedInternalEdges: (node << 32) | scc
    dead_functions: [..] Value_Id;
    // IndirectVHs: SmallMapVector<Value *, WeakTrackingVH> (keys = the calls when inserted; values follow RAUW, become
    // NONE when erased: cg_vh_note_rauw / cg_vh_note_erase)
    ivh_keys: [..] Value_Id;
    ivh_vals: [..] Value_Id;
}
cgscc_ur: *Cgscc_Ur;   // the active update result (for the value-handle hooks)

cg_vh_note_rauw :: (old: Value_Id, new: Value_Id) {
    if !cgscc_ur || cgscc_ur.ivh_vals.count == 0 return;
    for * cgscc_ur.ivh_vals if it.* == old it.* = new;
}
cg_vh_note_erase :: (v: Value_Id) {
    if !cgscc_ur || cgscc_ur.ivh_vals.count == 0 return;
    for * cgscc_ur.ivh_vals if it.* == v it.* = NONE;
}
ivh_find :: (ur: *Cgscc_Ur, k: Value_Id) -> s64 { for ur.ivh_keys if it == k return it_index; return -1; }
ivh_insert :: (ur: *Cgscc_Ur, k: Value_Id, v: Value_Id) {
    if ivh_find(ur, k) >= 0 return;
    array_add(*ur.ivh_keys, k); array_add(*ur.ivh_vals, v);
}
ivh_clear :: (ur: *Cgscc_Ur) { ur.ivh_keys.count = 0; ur.ivh_vals.count = 0; }

ie_key :: inline (n: s32, c: s32) -> u64 { return ((cast(u64) cast(u32) n) << 32) | cast(u64) cast(u32) c; }

// PreservedAnalyses::intersect
pa_intersect :: (a: *Preserved, b: Preserved) {
    if b.all return;
    if a.all { a.* = b; return; }
    a.cfg = a.cfg && b.cfg;
    a.mask &= b.mask;
    a.all_fn = a.all_fn && b.all_fn;
    a.all_scc = a.all_scc && b.all_scc;
    a.lcg = a.lcg && b.lcg;
}
pa_preserves_lcg :: (pa: Preserved) -> bool { return pa.all || pa.lcg; }

// CGSCCAnalysisManager::invalidate(C, PA) through FunctionAnalysisManagerCGSCCProxy::Result::invalidate
cgam_invalidate :: (c: s32, pa: Preserved) {
    if pa.all || pa.all_fn return;
    for n: lcg.sccs[c].nodes fam_invalidate(lcg_fn(n), pa);
}

// PassInstrumentation::runBeforePass for an SCC (OptNone does not apply to SCCs; OptBisect counts optional passes)
should_run_pass_scc :: (node: *Pass_Node, c: s32) -> bool {
    if node.kind == .CGSCC_PM || node.kind == .CGSCC_FN_ADAPTOR return true;
    if node.info && node.info.required return true;
    if opts.opt_bisect_limit >= 0 {
        bisect_count += 1;
        ok := bisect_count <= opts.opt_bisect_limit;
        print_stderr("BISECT: %running pass (%) % on %\n", ifx ok then "" else "NOT ", bisect_count, node.name, lcg_scc_name(c));
        if !ok return false;
    }
    return true;
}

cgscc_opts: struct {
    abort_on_max_devirt := false;   // -abort-on-max-devirt-iterations-reached
};

// ModuleToPostOrderCGSCCPassAdaptor::run. `n` is the adaptor node; its only child is the wrapped pass.
run_cgscc_adaptor :: (n: s32) -> Preserved {
    pass := pipeline.nodes[n].first_child;
    g := lcg_get();
    rcwl := New(Prio_Worklist);
    cwl := New(Prio_Worklist);
    ur := New(Cgscc_Ur);
    ur.cwl = cwl;
    saved_ur := cgscc_ur;
    cgscc_ur = ur;
    defer cgscc_ur = saved_ur;
    pa := PRESERVE_ALL;
    lcg_build_ref_sccs();
    cur := lcg_postorder_from(0);
    while cur >= 0 {
        next := lcg_postorder_next(cur);   // make_early_inc_range
        pwl_insert(rcwl, cur);
        while !pwl_empty(rcwl) {
            rc := pwl_pop(rcwl);
            last_updated_c: s32 = -1;
            for < lcg.rcs[rc].sccs pwl_insert(cwl, it);
            while !pwl_empty(cwl) {
                c := pwl_pop(cwl);
                if table_contains(*ur.invalidated, c) continue;
                if last_updated_c == c continue;
                cgam_invalidate(c, ur.cross_scc_pa);
                while true {
                    last_updated_c = ur.updated_c;
                    ur.updated_c = -1;
                    node := *pipeline.nodes[pass];
                    if !should_run_pass_scc(node, c) { if ur.updated_c < 0 break; continue; }
                    pass_pa := run_cgscc_pass(pass, c, ur);
                    reset_temporary_storage();
                    if ur.updated_c >= 0 c = ur.updated_c;
                    pa_intersect(*ur.cross_scc_pa, pass_pa);
                    pa_intersect(*pa, pass_pa);
                    if table_contains(*ur.invalidated, c) break;
                    cgam_invalidate(c, pass_pa);
                    if ur.updated_c < 0 break;
                }
            }
            table_reset(*ur.inlined_internal_edges);
        }
        cur = next;
        // the early-incremented iterator was computed before the RefSCC ran; an empty RefSCC (merged away) is skipped
        // only when the iterator advanced past it then
    }
    lcg_remove_dead_functions(ur.dead_functions);
    for ur.dead_functions erase_function(it);
    pwl_free(rcwl); pwl_free(cwl);
    pa.all_scc = true; pa.lcg = true;
    return pa;
}

// Function::eraseFromParent for a function whose body was made unreachable
erase_function :: (f: Value_Id) {
    table_remove(*fam, f);
    fn_drop_all_references(f);
    md_global_value_deleted(f);
    erase_global(f);
}
// ValueAsMetadata::handleDeletion for a global (a ConstantAsMetadata): every node using it gets a null operand, and
// a uniqued node becomes distinct (MDNode::handleChangedOperand: "deleted constants")
md_global_value_deleted :: (v: Value_Id) {
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, v);
    found, m := table_find(*ir.md_map, key_view(k));
    if !found return;
    defer md_value_deleted(v);   // debug records that use it get poison (DebugValueUser::handleChangedValue)
    for * row, id: ir.mds {
        if row.kind != .TUPLE || row.nops == 0 continue;
        uses := false;
        for x: 0..row.nops-1 if ir.md_ops[row.ops + x] == m { uses = true; break; }
        if !uses continue;
        if !row.distinct {
            key_reset(k); key_u8(k, 2);
            for x: 0..row.nops-1 key_u32(k, ir.md_ops[row.ops + x]);
            f2, cur := table_find(*ir.md_map, key_view(k));
            if f2 && cur == cast(Md_Id) id table_remove(*ir.md_map, key_view(k));
            row.distinct = true;
        }
        for x: 0..row.nops-1 if ir.md_ops[row.ops + x] == m ir.md_ops[row.ops + x] = NONE;
    }
}
// Function::dropAllReferences: delete the body (every block), keep the declaration
fn_drop_all_references :: (f: Value_Id) {
    for b: fn_blocks(f) for i: block_insts(b) drop_all_references(i);
    while glob(f).first_block != NONE block_erase_from_parent(glob(f).first_block);
    // the hung-off personality / prefix / prologue operands
    drop_all_references(f);
    glob(f).has_personality = false; glob(f).has_prefix = false; glob(f).has_prologue = false;
}

run_cgscc_pass :: (n: s32, c: s32, ur: *Cgscc_Ur) -> Preserved {
    node := *pipeline.nodes[n];
    if node.kind == {
        case .CGSCC_PM; return run_cgscc_pm(n, c, ur);
        case .DEVIRT; return run_devirt(n, c, ur);
        case .CGSCC_FN_ADAPTOR; return run_cgscc_fn_adaptor(n, c, ur);
        case .NO_OP_CGSCC; return PRESERVE_ALL;
        case .FUNCTION_ATTRS; return function_attrs_run_scc(node, c);
        case .INLINE; return inliner_run(node, c, ur);
    }
    fatal("internal: '%' is not a cgscc pass", node.name);
    return PRESERVE_NONE;
}

// PassManager<LazyCallGraph::SCC, ...>::run
run_cgscc_pm :: (n: s32, initial_c: s32, ur: *Cgscc_Ur) -> Preserved {
    pa := PRESERVE_ALL;
    c := initial_c;
    p := pipeline.nodes[n].first_child;
    while p >= 0 {
        node := *pipeline.nodes[p];
        next := node.next;
        if should_run_pass_scc(node, c) {
            pass_pa := run_cgscc_pass(p, c, ur);
            reset_temporary_storage();
            if ur.updated_c >= 0 c = ur.updated_c;
            pa_intersect(*pa, pass_pa);
            if table_contains(*ur.invalidated, c) break;
            cgam_invalidate(c, pass_pa);
        }
        p = next;
    }
    pa_intersect(*ur.cross_scc_pa, pa);
    pa.all_scc = true;
    return pa;
}

// DevirtSCCRepeatedPass::run
Call_Count :: struct { f: Value_Id; direct: s32; indirect: s32; }
devirt_scan_scc :: (c: s32, ur: *Cgscc_Ur) -> [..] Call_Count {
    counts: [..] Call_Count;
    for n: lcg.sccs[c].nodes {
        f := lcg_fn(n);
        idx := -1;
        for counts if it.f == f { idx = it_index; break; }
        if idx < 0 { idx = counts.count; array_add(*counts, .{f, 0, 0}); }
        for i: fn_insts(f) {
            if !is_call_base(i) continue;
            if call_called_function(i) != NONE counts[idx].direct += 1;
            else { counts[idx].indirect += 1; ivh_insert(ur, i, i); }
        }
    }
    return counts;
}
run_devirt :: (n: s32, initial_c: s32, ur: *Cgscc_Ur) -> Preserved {
    pa := PRESERVE_ALL;
    c := initial_c;
    max_iterations := pipeline.nodes[n].count;
    pass := pipeline.nodes[n].first_child;
    ivh_clear(ur);
    call_counts := devirt_scan_scc(c, ur);
    iteration := 0;
    while true {
        defer iteration += 1;
        if !should_run_pass_scc(*pipeline.nodes[pass], c) continue;
        pass_pa := run_cgscc_pass(pass, c, ur);
        reset_temporary_storage();
        pa_intersect(*pa, pass_pa);
        if table_contains(*ur.invalidated, c) break;
        cgam_invalidate(c, pass_pa);
        if ur.updated_c >= 0 && ur.updated_c != c break;
        devirt := false;
        for v: ur.ivh_vals {
            if v != NONE && vkind(v) == .INST && is_call_base(v) && call_called_function(v) != NONE { devirt = true; break; }
        }
        ivh_clear(ur);
        new_counts := devirt_scan_scc(c, ur);
        if !devirt {
            for nc: new_counts {
                for oc: call_counts {
                    if oc.f != nc.f continue;
                    if oc.indirect > nc.indirect && oc.direct < nc.direct devirt = true;
                    break;
                }
                if devirt break;
            }
        }
        if !devirt { array_free(new_counts); break; }
        if iteration >= max_iterations {
            if cgscc_opts.abort_on_max_devirt fatal("Max devirtualization iterations reached");
            array_free(new_counts);
            break;
        }
        array_free(call_counts);
        call_counts = new_counts;
    }
    array_free(call_counts);
    return pa;
}

// CGSCCToFunctionPassAdaptor::run. The node's children are the function pipeline (one pass, or a
// FunctionPassManager's passes).
run_cgscc_fn_adaptor :: (n: s32, c_in: s32, ur: *Cgscc_Ur) -> Preserved {
    nodes: [..] s32;
    defer array_free(nodes);
    for lcg.sccs[c_in].nodes array_add(*nodes, it);
    current_c := c_in;
    eager := pipeline.nodes[n].eager_inv;
    pa := PRESERVE_ALL;
    for nd: nodes {
        if lcg_lookup_scc(nd) != current_c continue;
        f := lcg_fn(nd);
        fpa := PRESERVE_ALL;   // the FunctionPassManager's result (or the single pass's)
        p := pipeline.nodes[n].first_child;
        while p >= 0 {
            node := *pipeline.nodes[p];
            next := node.next;
            if should_run_pass(node, f) {
                ppa := run_function_pass(node, f);
                if !ppa.all printer_note_ir_changed();
                fam_invalidate(f, ppa);
                pa_intersect(*fpa, ppa);
            }
            reset_temporary_storage();
            p = next;
        }
        // (the FAM invalidation of the adaptor itself: the passes above already invalidated after each pass)
        if eager fam_invalidate(f, PRESERVE_NONE);
        pa_intersect(*pa, fpa);
        if !pa_preserves_lcg(pa) {
            current_c = update_cg_and_am_for_pass(current_c, nd, ur, true);
        }
    }
    pa.all_fn = true;
    pa.lcg = true;
    return pa;
}

// incorporateNewSCCRange: the new SCCs are the positions [b, e) of the RefSCC's SCC list
incorporate_new_scc_range :: (rc: s32, b: s64, e: s64, nd: s32, c: s32, ur: *Cgscc_Ur) -> s32 {
    if b == e return c;
    pwl_insert(ur.cwl, c);
    new_c := lcg.rcs[rc].sccs[b];
    k := e - 1;
    while k > b {
        pwl_insert(ur.cwl, lcg.rcs[rc].sccs[k]);
        k -= 1;
    }
    return new_c;
}

// updateCGAndAnalysisManagerForPass
update_cg_and_am_for_pass :: (initial_c: s32, nd: s32, ur: *Cgscc_Ur, function_pass: bool) -> s32 {
    rc := lcg.sccs[initial_c].rc;
    c := initial_c;
    f := lcg_fn(nd);
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    retained: Table(s32, bool); retained.allocator = temp;
    promoted: [..] s32; promoted.allocator = temp;     // SmallSetVector
    demoted: [..] s32; demoted.allocator = temp;
    new_calls: [..] s32; new_calls.allocator = temp;
    new_refs: [..] s32; new_refs.allocator = temp;
    set_vector_add :: (v: *[..] s32, x: s32) { for v.* if it == x return; array_add(v, x); }
    for i: fn_insts(f) {
        if !is_call_base(i) continue;
        callee := call_called_function(i);
        if callee != NONE {
            if table_contains(*visited, callee) continue;
            table_set(*visited, callee, true);
            if is_declaration(callee) continue;
            cn := lcg_lookup(callee);
            ei := lcg_seq_lookup(lcg_seq(nd), cn);
            if ei < 0 && function_pass fatal("cgscc: a function pass introduced a new call edge");
            table_set(*retained, cn, true);
            if ei < 0 set_vector_add(*new_calls, cn);
            else if !lcg_seq(nd).edges[ei].call set_vector_add(*promoted, cn);
        } else {
            k := ivh_find(ur, i);
            if k < 0 ivh_insert(ur, i, i);
            else if ur.ivh_vals[k] == NONE ur.ivh_vals[k] = i;
        }
    }
    for i: fn_insts(f) lcg_visit_operands_of_inst(i, *worklist, *visited);
    refs: [..] Value_Id; refs.allocator = temp;
    lcg_visit_references(*worklist, *visited, *refs);
    visit_ref :: (referee: Value_Id, nd: s32, function_pass: bool, retained: *Table(s32, bool), new_refs: *[..] s32, demoted: *[..] s32) {
        rn := lcg_lookup(referee);
        if rn < 0 fatal("cgscc: a referenced function has no call graph node");
        ei := lcg_seq_lookup(lcg_seq(nd), rn);
        if ei < 0 && function_pass fatal("cgscc: a function pass introduced a new ref edge");
        table_set(retained, rn, true);
        if ei < 0 set_vector_add(new_refs, rn);
        else if lcg_seq(nd).edges[ei].call set_vector_add(demoted, rn);
    }
    for refs visit_ref(it, nd, function_pass, *retained, *new_refs, *demoted);
    for t: new_refs lcg_insert_trivial_ref_edge(nd, t);
    for t: new_calls lcg_insert_trivial_ref_edge(nd, t);
    for lf: lcg.lib_functions if !table_contains(*visited, lf) visit_ref(lf, nd, function_pass, *retained, *new_refs, *demoted);

    dead_targets: [..] s32; dead_targets.allocator = temp;
    k := 0;
    while k < lcg_seq(nd).edges.count {
        e := lcg_seq(nd).edges[k];
        k += 1;
        if !lcg_edge_ok(e) continue;
        if table_contains(*retained, e.node) continue;
        tc := lcg_lookup_scc(e.node);
        trc := lcg.sccs[tc].rc;
        if trc == rc && e.call {
            if c != tc lcg_switch_trivial_internal_edge_to_ref(nd, e.node);
            else {
                b, en := lcg_switch_internal_edge_to_ref(rc, nd, e.node);
                c = incorporate_new_scc_range(rc, b, en, nd, c, ur);
            }
        }
        array_add(*dead_targets, e.node);
    }
    for t: dead_targets {
        tc := lcg_lookup_scc(t);
        if lcg.sccs[tc].rc == rc continue;
        lcg_remove_outgoing_edge(nd, t);
    }
    for t: demoted {
        tc := lcg_lookup_scc(t);
        trc := lcg.sccs[tc].rc;
        if trc != rc { lcg_switch_outgoing_edge_to_ref(nd, t); continue; }
        if c != tc { lcg_switch_trivial_internal_edge_to_ref(nd, t); continue; }
        b, en := lcg_switch_internal_edge_to_ref(rc, nd, t);
        c = incorporate_new_scc_range(rc, b, en, nd, c, ur);
    }
    for new_calls set_vector_add(*promoted, it);
    for t: promoted {
        tc := lcg_lookup_scc(t);
        trc := lcg.sccs[tc].rc;
        if trc != rc { lcg_switch_outgoing_edge_to_call(nd, t); continue; }
        initial_idx := lcg.sccs[c].idx;
        merged: [..] s32; merged.allocator = temp;
        formed := lcg_switch_internal_edge_to_call(rc, nd, t, *merged);
        for merged table_set(*ur.invalidated, it, true);
        if formed c = tc;
        new_idx := lcg.sccs[c].idx;
        if initial_idx < new_idx {
            pwl_insert(ur.cwl, c);
            j := new_idx - 1;
            while j >= initial_idx { pwl_insert(ur.cwl, lcg.rcs[rc].sccs[j]); j -= 1; }
        }
    }
    if c != initial_c ur.updated_c = c;
    return c;
}
