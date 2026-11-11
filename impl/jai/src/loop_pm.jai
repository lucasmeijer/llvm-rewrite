// The loop pass manager: loop(...) / loop-mssa(...) pipelines.
// Port of llvm/lib/Transforms/Scalar/LoopPassManager.cpp (FunctionToLoopPassAdaptor::run with its
// LoopCanonicalizationFPM = loop-simplify + lcssa, LoopPassManager::runWithoutLoopNestPasses),
// llvm/include/llvm/Transforms/Scalar/LoopPassManager.h (LPMUpdater), llvm/include/llvm/ADT/PriorityWorklist.h
// (SmallPriorityWorklist) and appendLoopsToWorklist / appendReversedLoopsToWorklist (LoopUtils.cpp),
// getLoopPassPreservedAnalyses (LoopAnalysisManager.cpp).
//
// Pipeline nodes: LOOP_ADAPTOR (FunctionToLoopPassAdaptor; `use_mssa`; its children are the loop pipeline, run as
// one LoopPassManager) and LOOP_PM (a nested `loop(...)` inside a loop pipeline). A loop pass is a Pass_Kind with
// level LOOP and a `case` in run_loop_pass. There are no loop-level analyses yet, so LAM invalidation is empty.
//
// LoopStandardAnalysisResults carries the function's ScalarEvolution (lar.se, AM.getResult in the adaptor);
// run_loop_pass also makes it `scev_pass_se`, the SE that the shared utilities (LoopSimplify, LCSSA) update.

// SmallPriorityWorklist<Loop *, 4>: a vector with NONE holes plus a map from loop to its index
Loop_Worklist :: struct {
    v: [..] Loop_Id;
    m: Table(Loop_Id, s64);
}
lwl_init :: (w: *Loop_Worklist) { w.v.allocator = temp; w.m.allocator = temp; }
lwl_empty :: (w: *Loop_Worklist) -> bool { return w.v.count == 0; }
// insert(const T &X)
lwl_insert :: (w: *Loop_Worklist, x: Loop_Id) -> bool {
    found, idx := table_find(*w.m, x);
    if !found {
        table_set(*w.m, x, w.v.count);
        array_add(*w.v, x);
        return true;
    }
    if idx != w.v.count - 1 {
        w.v[idx] = NONE;
        table_set(*w.m, x, w.v.count);
        array_add(*w.v, x);
    }
    return false;
}
// insert(SequenceT &&Input)
lwl_insert_seq :: (w: *Loop_Worklist, input: [] Loop_Id) {
    if input.count == 0 return;
    start := w.v.count;
    for input array_add(*w.v, it);
    i := w.v.count - 1;
    while i >= start {
        x := w.v[i];
        found, idx := table_find(*w.m, x);
        if !found { table_set(*w.m, x, i); i -= 1; continue; }
        if idx < start {
            w.v[idx] = NONE;
            table_set(*w.m, x, i);
            i -= 1;
            continue;
        }
        w.v[i] = NONE;
        i -= 1;
    }
}
// pop_back_val
lwl_pop :: (w: *Loop_Worklist) -> Loop_Id {
    r := w.v[w.v.count - 1];
    table_remove(*w.m, r);
    w.v.count -= 1;
    while w.v.count && w.v[w.v.count - 1] == NONE w.v.count -= 1;
    return r;
}

// appendReversedLoopsToWorklist(Loops, Worklist): each root's nest in preorder (LIFO subloop walk)
append_reversed_loops_to_worklist :: (li: *Loop_Info, loops: [] Loop_Id, w: *Loop_Worklist) {
    pre: [..] Loop_Id; pre.allocator = temp;
    work: [..] Loop_Id; work.allocator = temp;
    for root: loops {
        pre.count = 0;
        array_add(*work, root);
        while work.count {
            l := pop(*work);
            for li_subloops(li, l) array_add(*work, it);
            array_add(*pre, l);
        }
        lwl_insert_seq(w, pre);
    }
}
// appendLoopsToWorklist(LI, Worklist): the top-level loops in stored order
append_loops_to_worklist_li :: (li: *Loop_Info, w: *Loop_Worklist) {
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    append_reversed_loops_to_worklist(li, tops, w);
}
// appendLoopsToWorklist(Range, Worklist): the range reversed
append_loops_to_worklist :: (li: *Loop_Info, loops: [] Loop_Id, w: *Loop_Worklist) {
    rev: [..] Loop_Id; rev.allocator = temp;
    for < loops array_add(*rev, it);
    append_reversed_loops_to_worklist(li, rev, w);
}

// LPMUpdater
Lpm_Updater :: struct {
    worklist: *Loop_Worklist;
    current: Loop_Id = NONE;
    skip_current: bool;
}
lpm_mark_loop_as_deleted :: (u: *Lpm_Updater, l: Loop_Id) { if l == u.current u.skip_current = true; }
lpm_add_child_loops :: (u: *Lpm_Updater, li: *Loop_Info, children: [] Loop_Id) {
    lwl_insert(u.worklist, u.current);
    append_loops_to_worklist(li, children, u.worklist);
    u.skip_current = true;
}
lpm_add_sibling_loops :: (u: *Lpm_Updater, li: *Loop_Info, sibs: [] Loop_Id) {
    append_loops_to_worklist(li, sibs, u.worklist);
}
lpm_revisit_current_loop :: (u: *Lpm_Updater) {
    u.skip_current = true;
    lwl_insert(u.worklist, u.current);
}

// LoopStandardAnalysisResults (no AA/SE/TLI/TTI objects: those are recomputed by the passes that need them)
Loop_Std_Results :: struct {
    fn: Value_Id;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    li: *Loop_Info;
    se: *Scev_State;   // ScalarEvolution
    mssa: *Memory_SSA;
}

// getLoopPassPreservedAnalyses: DT, LoopInfo, SCEV (and all loop analyses)
loop_pass_preserved :: () -> Preserved {
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    return pa;
}

// PreservedAnalyses::intersect
preserved_intersect :: (a: Preserved, b: Preserved) -> Preserved {
    if a.all return b;
    if b.all return a;
    r: Preserved;
    r.cfg = a.cfg && b.cfg;
    r.mask = a.mask & b.mask;
    return r;
}

// Loop::getName() for OptBisect's "loop %<name> in function <f>"
loop_bisect_name :: (li: *Loop_Info, l: Loop_Id) -> string {
    h := li_header(li, l);
    nm := ifx vname(h).count then vname(h) else "<unnamed loop>";
    return tprint("loop \x1f% in function %", nm, vname(li.fn));
}

// runBeforePass<Loop>: OptNone, then OptBisect
should_run_loop_pass :: (node: *Pass_Node, li: *Loop_Info, l: Loop_Id) -> bool {
    if node.kind == .LOOP_PM return true;   // a PassManager is required
    if node.info && node.info.required return true;
    run := true;
    f := li.fn;
    if attr_set_has(attr_list_fn(glob(f).attrs), .OptimizeNone) run = false;
    if opts.opt_bisect_limit >= 0 {
        bisect_count += 1;
        ok := bisect_count <= opts.opt_bisect_limit;
        print_stderr("BISECT: %running pass (%) % on %\n", ifx ok then "" else "NOT ", bisect_count, bisect_pass_name(node.name), loop_bisect_name(li, l));
        if !ok run = false;
    }
    return run;
}

// LoopPassManager::runWithoutLoopNestPasses
run_loop_pm :: (n: s32, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    pa := PRESERVE_ALL;
    c := pipeline.nodes[n].first_child;
    while c >= 0 {
        idx := c;
        node := *pipeline.nodes[c];
        c = node.next;
        // a loop-nest pass (LoopPassManager::run): only on a top-level loop (runWithLoopNestPasses), on the
        // LoopNest of that loop; runWithoutLoopNestPasses skips it without instrumentation
        if node.kind == .LOOP_INTERCHANGE && li_parent(lar.li, l) != NONE continue;
        if !should_run_loop_pass(node, lar.li, l) continue;
        p := run_loop_pass(idx, l, lar, u);
        if !p.all printer_note_ir_changed();
        if u.skip_current { pa = preserved_intersect(pa, p); break; }
        pa = preserved_intersect(pa, p);
    }
    // PA.preserveSet<AllAnalysesOn<Loop>>(): no loop analyses exist
    return pa;
}

run_loop_pass :: (idx: s32, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    node := *pipeline.nodes[idx];
    knowledge_retention_check(node.kind, node.name);
    saved_se := scev_pass_se;
    scev_pass_se = lar.se;
    se = lar.se;
    defer scev_pass_se = saved_se;
    if node.kind == {
        case .LOOP_PM; return run_loop_pm(idx, l, lar, u);
        case .NO_OP_LOOP; return PRESERVE_ALL;
        case .EXTRA_LOOP_UNSWITCH;
            // ExtraLoopPassManager<ShouldRunExtraSimpleLoopUnswitch>::run: the inner passes only when IndVarSimplify
            // left the marker analysis cached for L; the marker is abandoned either way
            pa := PRESERVE_ALL;
            if table_contains(*extra_unswitch_marker, l) pa = run_loop_pm(idx, l, lar, u);
            table_remove(*extra_unswitch_marker, l);
            return pa;
        case .LOOP_INTERCHANGE; return loop_interchange_run(node, l, lar, u);
        case .LOOP_ROTATE; return loop_rotate_run(node, l, lar, u);
        case .LICM; return licm_run(node, l, lar, u);
        case .INDVARS; return indvars_run(node, l, lar, u);
        case .LOOP_DELETION; return loop_deletion_run(node, l, lar, u);
        case .LOOP_INSTSIMPLIFY; return loop_instsimplify_run(node, l, lar, u);
        case .LOOP_SIMPLIFYCFG; return loop_simplifycfg_run(node, l, lar, u);
        case .LOOP_IDIOM; return loop_idiom_run(node, l, lar, u);
        case .LOOP_UNROLL_FULL; return loop_unroll_full_run(node, l, lar, u);
        case .SIMPLE_LOOP_UNSWITCH; return simple_loop_unswitch_run(node, l, lar, u);
        case .LNICM;
            // a loop-nest pass runs on the LoopNest of the outermost loop containing L
            root := l;
            while li_parent(lar.li, root) != NONE root = li_parent(lar.li, root);
            return licm_run(node, root, lar, u, true);
        case .PRINT_LOOPNEST; return loop_nest_printer_run(l, lar);
        case .PRINT_IV_USERS; return iv_users_printer_run(l, lar);
        case .REQUIRE_IV_USERS; return iv_users_require_run(l, lar);
    }
    fatal("internal: '%' is not a loop pass", node.name);
    return PRESERVE_NONE;
}

// ShouldRunExtraSimpleLoopUnswitch: the loops for which IndVarSimplify requested the marker (a loop analysis that
// lives until the ExtraLoopPassManager right after it abandons it)
extra_unswitch_marker: Table(Loop_Id, bool);

// FunctionToLoopPassAdaptor::run. The loop pipeline (the adaptor's children) runs as one LoopPassManager.
run_loop_adaptor :: (n: s32, f: Value_Id) -> Preserved {
    table_reset(*extra_unswitch_marker);
    use_mssa := pipeline.nodes[n].use_mssa;
    pa := PRESERVE_ALL;
    // LoopCanonicalizationFPM (a FunctionPassManager: required) = LoopSimplifyPass, LCSSAPass
    for k: 0..1 {
        cn: Pass_Node;
        cn.kind = ifx k == 0 then Pass_Kind.LOOP_SIMPLIFY else .LCSSA;
        cn.name = ifx k == 0 then "loop-simplify" else "lcssa";
        cn.info = lookup_pass(cn.name);
        if !should_run_pass(*cn, f) continue;
        p := run_function_pass(*cn, f);
        if !p.all printer_note_ir_changed();
        fam_invalidate(f, p);
        pa = preserved_intersect(pa, p);
    }
    li := get_loop_info(f);
    if li.top_level.count == 0 return pa;
    lar: Loop_Std_Results;
    lar.fn = f;
    if use_mssa lar.mssa = get_memoryssa(f);
    lar.ac = get_assumption_cache(f);
    lar.dt = get_domtree(f);
    lar.li = get_loop_info(f);
    lar.se = get_scev(f);

    w: Loop_Worklist;
    lwl_init(*w);
    u: Lpm_Updater;
    u.worklist = *w;
    // LoopNestMode (the loop pipeline has only loop-nest passes): only the top-level loops, in LoopInfo's order
    loop_nest_mode := pipeline.nodes[n].first_child >= 0;
    {
        c := pipeline.nodes[n].first_child;
        while c >= 0 { if pipeline.nodes[c].kind != .LNICM loop_nest_mode = false; c = pipeline.nodes[c].next; }
    }
    if loop_nest_mode for li.top_level lwl_insert(*w, it);
    else append_loops_to_worklist_li(li, *w);
    while !lwl_empty(*w) {
        l := lwl_pop(*w);
        u.current = l;
        u.skip_current = false;
        // the adaptor's pass is the LoopPassManager of its children (required: always runs)
        p := run_loop_pm(n, l, *lar, *u);
        if lar.mssa && !is_preserved(p, .MEMORYSSA) fatal("Loop pass manager using MemorySSA contains a pass that does not preserve MemorySSA");
        pa = preserved_intersect(pa, p);
    }
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    if use_mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
