// Small analysis printers:
//   print<assumptions>               AssumptionPrinterPass (llvm/lib/Analysis/AssumptionCache.cpp)
//   print-callgraph-sccs             CallGraphSCCsPrinterPass (llvm/lib/Analysis/CallGraph.cpp; the CallGraph and
//                                    scc_iterator are globals_aa.jai's)
//   print<phi-values>                PhiValues + PhiValuesPrinterPass (llvm/lib/Analysis/PhiValues.cpp)
//   print<mem-derefs>                MemDerefPrinterPass (llvm/lib/Analysis/MemDerefPrinter.cpp)
//   print<must-execute>              MustExecutePrinterPass with MustExecuteAnnotatedWriter, SimpleLoopSafetyInfo
//                                    (llvm/lib/Analysis/MustExecute.cpp; ICFLoopSafetyInfo is must_execute.jai's)
//   print-must-be-executed-contexts  MustBeExecutedContextPrinterPass (the explorer is attributor.jai's)

// V->print(OS) / OS << *V for any value: an instruction prints its line (with the two leading spaces), a global
// variable its definition line, everything else `<type> <operand>`.
value_print_to_string :: (v: Value_Id, f: Value_Id) -> string {
    if is_inst(v) return inst_to_string(v);
    if vkind(v) == .GLOBAL_VAR {
        printer_begin_function(f);
        start := W.buf.count;
        print_global(v);
        s := copy_string(slice_of_buf(start),, allocator = temp);
        W.buf.count = start;
        return s;
    }
    if f != NONE printer_begin_function(f);
    return value_as_operand_typed(v);
}

// ---------------------------------------------------------------- print<assumptions>

print_assumptions_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    ac := get_assumption_cache(f);
    print_to_builder(*sb, "Cached assumptions for function: %\n", vname(f));
    for a: ac_assumptions(ac).* {
        if a == NONE || vkind(a) == .DEAD continue;
        nb := call_num_bundles(a);
        if nb == 0 {
            print_to_builder(*sb, "  %\n", value_print_to_string(call_arg(a, 0), f));
            continue;
        }
        append(*sb, "  [ ");
        for kk: 0..cast(s64) nb-1 {
            k := cast(u32) kk;
            if k > 0 append(*sb, ", ");
            print_to_builder(*sb, "\"%\"(", call_bundle_tag(a, k));
            b0 := ir.u32_pool[inst(a).idx + 3 * k + 1];
            b1 := ir.u32_pool[inst(a).idx + 3 * k + 2];
            if b1 > b0 for j: b0..b1-1 {
                if j > b0 append(*sb, ", ");
                append(*sb, value_as_operand_typed(op(a, j)));
            }
            append(*sb, ")");
        }
        append(*sb, " ]\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print-callgraph-sccs

print_callgraph_sccs_run :: () {
    sb: String_Builder; sb.allocator = temp;
    cg := cg_build();
    sccs := cg_sccs(*cg);
    append(*sb, "SCCs for the program in PostOrder:");
    for scc, n: sccs {
        print_to_builder(*sb, "\nSCC #%: ", n + 1);
        for scc {
            if it_index > 0 append(*sb, ", ");
            fn := cg.nodes[it].f;
            append(*sb, ifx fn != NONE then vname(fn) else "external node");
        }
        // scc_iterator::hasCycle for a single node: it calls itself
        if scc.count == 1 {
            self := false;
            for c: cg.nodes[scc[0]].callees if c == scc[0] self = true;
            if self append(*sb, " (Has self-loop).");
        }
    }
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}

// ---------------------------------------------------------------- PhiValues

Phi_Values :: struct {
    depth: Table(Value_Id, u32);                 // DepthMap
    next_depth: u32;
    reachable: Table(u32, [..] Value_Id);        // ReachableMap (SmallSetVector: insertion order)
    non_phi: Table(u32, [..] Value_Id);          // NonPhiReachableMap
}
pv_set_insert :: (s: *[..] Value_Id, v: Value_Id) { for s.* if it == v return; array_add(s, v); }

// PhiValues::processPhi
pv_process_phi :: (pv: *Phi_Values, phi: Value_Id, stack: *[..] Value_Id) {
    pv.next_depth += 1;
    root := pv.next_depth;
    table_set(*pv.depth, phi, root);
    n := phi_num_incoming(phi);
    for k: 0..cast(s64) n-1 {
        o := phi_value(phi, cast(u32) k);
        if !is_phi(o) continue;
        _, od := table_find(*pv.depth, o);
        if od == 0 {
            pv_process_phi(pv, o, stack);
            _, od = table_find(*pv.depth, o);
        }
        if !table_contains(*pv.reachable, od) {
            p := table_find_pointer(*pv.depth, phi);
            if od < p.* p.* = od;
        }
    }
    array_add(stack, phi);
    _, d := table_find(*pv.depth, phi);
    if d != root return;
    reach: [..] Value_Id;
    while true {
        cp := pop(stack);
        pv_set_insert(*reach, cp);
        m := phi_num_incoming(cp);
        for k: 0..cast(s64) m-1 {
            o := phi_value(cp, cast(u32) k);
            if is_phi(o) {
                _, od := table_find(*pv.depth, o);
                if od != root {
                    r := table_find_pointer(*pv.reachable, od);
                    if r for r.* pv_set_insert(*reach, it);
                }
            } else pv_set_insert(*reach, o);
        }
        if stack.count == 0 break;
        cd := table_find_pointer(*pv.depth, stack.*[stack.count - 1]);
        if cd.* < root break;
        cd.* = root;
    }
    table_set(*pv.reachable, root, reach);
    np: [..] Value_Id;
    for reach if !is_phi(it) pv_set_insert(*np, it);
    table_set(*pv.non_phi, root, np);
}

pv_values_for_phi :: (pv: *Phi_Values, phi: Value_Id) {
    _, d := table_find(*pv.depth, phi);
    if d == 0 {
        stack: [..] Value_Id; stack.allocator = temp;
        pv_process_phi(pv, phi, *stack);
    }
}

print_phi_values_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "PHI Values for function: %\n", vname(f));
    pv: Phi_Values;
    pv.depth.allocator = temp; pv.reachable.allocator = temp; pv.non_phi.allocator = temp;
    for bb: fn_blocks(f) for i: block_insts(bb) { if !is_phi(i) break; pv_values_for_phi(*pv, i); }
    for bb: fn_blocks(f) for i: block_insts(bb) {
        if !is_phi(i) break;
        print_to_builder(*sb, "PHI % has values:\n", value_as_operand(i));
        _, d := table_find(*pv.depth, i);
        vals := table_find_pointer(*pv.non_phi, d);
        if !vals append(*sb, "  UNKNOWN\n");
        else if vals.count == 0 append(*sb, "  NONE\n");
        else for v: vals.* {
            if is_inst(v) print_to_builder(*sb, "%\n", inst_to_string(v));
            else print_to_builder(*sb, "  %\n", value_print_to_string(v, f));
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print<mem-derefs>

print_mem_derefs_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Memory Dereferencibility of pointers in function '%'\n", vname(f));
    deref: [..] Value_Id; deref.allocator = temp;
    aligned: Table(Value_Id, bool); aligned.allocator = temp;
    for i: fn_insts(f) {
        if inst_op(i) != .LOAD continue;
        po := op(i, 0);
        q: Simplify_Query; q.cxt = i; q.have_tli = false; q.no_tli_libcalls = true;   // SimplifyQuery(DL, LI)
        if is_dereferenceable_pointer_ty(po, vtype(i), q) array_add(*deref, po);
        if is_dereferenceable_and_aligned_pointer_ty(po, vtype(i), inst(i).align, q) table_set(*aligned, po, true);
    }
    append(*sb, "The following are dereferenceable:\n");
    for v: deref {
        print_to_builder(*sb, "  %", value_print_to_string(v, f));
        append(*sb, ifx table_contains(*aligned, v) then "\t(aligned)\n" else "\t(unaligned)\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print<must-execute>

// SimpleLoopSafetyInfo::computeLoopSafetyInfo + isGuaranteedToExecute. allLoopPathsLeadToBlock asks blockMayThrow,
// which is anyBlockMayThrow here: an ICF Loop_Safety_Info with may_throw set for every block gives the same answer
// through lsi_all_loop_paths_lead_to_block only if it consults the flag, so the walk is repeated with the simple rule.
simple_lsi_is_guaranteed_to_execute :: (i: Value_Id, dt: *Dom_Tree, li: *Loop_Info, l: Loop_Id) -> bool {
    header := li_header(li, l);
    header_may_throw := !is_guaranteed_to_transfer_execution_block(header);
    may_throw := header_may_throw;
    blocks := li_blocks(li, l);
    if !may_throw for k: 1..blocks.count-1 {
        may_throw = may_throw || !is_guaranteed_to_transfer_execution_block(blocks[k]);
        if may_throw break;
    }
    if inst_block(i) == header return !header_may_throw || block_first_non_phi_or_dbg(header) == i;
    s: Loop_Safety_Info;
    s.li = li;
    s.simple = true;
    s.may_throw = may_throw;
    f := block_fn(header);
    p := fn_personality(f);
    s.block_colors.allocator = temp;
    if p != NONE && is_scoped_eh_personality(classify_eh_personality(p)) color_eh_funclets(f, *s.block_colors);
    return lsi_all_loop_paths_lead_to_block(*s, l, inst_block(i), dt);
}

// isGuaranteedToExecuteForEveryIteration (ValueTracking.cpp)
is_guaranteed_to_execute_for_every_iteration :: (i: Value_Id, li: *Loop_Info, l: Loop_Id) -> bool {
    header := li_header(li, l);
    if inst_block(i) != header return false;
    for x: block_insts(header) {
        if x == i return true;
        if !is_guaranteed_to_transfer_execution(x) return false;
    }
    return false;
}

must_exec_ctx: struct {
    loops: Table(Value_Id, [..] Value_Id);   // instruction -> headers of the loops it must execute in
}

must_exec_annot_info :: (i: Value_Id) {
    hs := table_find_pointer(*must_exec_ctx.loops, i);
    if !hs return;
    if hs.count > 1 { out(" ; (mustexec in "); out_s64(hs.count); out(" loops: "); }
    else out(" ; (mustexec in: ");
    for hs.* { if it_index > 0 out(", "); out(vname(it)); }
    out(")");
}

print_must_execute_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    dt := get_domtree(f);
    must_exec_ctx.loops = .{};
    must_exec_ctx.loops.allocator = temp;
    for i: fn_insts(f) {
        l := li_loop_for(li, inst_block(i));
        while l != NONE {
            if simple_lsi_is_guaranteed_to_execute(i, dt, li, l) || is_guaranteed_to_execute_for_every_iteration(i, li, l) {
                p := table_find_pointer(*must_exec_ctx.loops, i);
                if !p {
                    e: [..] Value_Id; e.allocator = temp;
                    table_set(*must_exec_ctx.loops, i, e);
                    p = table_find_pointer(*must_exec_ctx.loops, i);
                }
                array_add(p, li_header(li, l));
            }
            l = li_parent(li, l);
        }
    }
    printer_begin_function(f);
    start := W.buf.count;
    print_annot_info = must_exec_annot_info;
    print_function(f);
    print_annot_info = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    write_string(s, to_standard_error = true);
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- print-must-be-executed-contexts

print_must_be_executed_contexts_run :: () {
    sb: String_Builder; sb.allocator = temp;
    atr = .{};   // a fresh explorer (its caches live in the Attributor state); every getter computes the analysis
    atr.cached_only = false;
    for f: ir.m_functions {
        if is_declaration(f) continue;
        for i: fn_insts(f) {
            print_to_builder(*sb, "-- Explore context of: %\n", inst_to_string(i));
            it := mbe_begin(i);
            while !mbe_at_end(*it) {
                ci := it.cur;
                print_to_builder(*sb, "  [F: %] %\n", vname(block_fn(inst_block(ci))), inst_to_string(ci));
                mbe_advance(*it);
            }
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}
