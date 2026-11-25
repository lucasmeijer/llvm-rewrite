// Small analysis printers from the registry gaps (NOTES.md "Pass registry gaps"):
//   print<cfg-sccs>      llvm/lib/Analysis/CFGSCCPrinter.cpp (scc_iterator<Function *>)
//   print<domfrontier>   llvm/lib/Analysis/DominanceFrontier.cpp, llvm/include/llvm/Analysis/DominanceFrontierImpl.h

// CFGSCCPrinterPass::run
print_cfg_sccs_run :: (f: Value_Id) -> Preserved {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "SCCs for Function % in PostOrder:", vname(f));
    sccs: [..] [..] Value_Id; sccs.allocator = temp;
    cfg_sccs(fn_entry(f), *sccs);   // branch_prob.jai: scc_iterator order, each SCC in pop order
    for scc, k: sccs {
        print_to_builder(*sb, "\nSCC #%: ", k + 1);
        for scc {
            if it_index > 0 append(*sb, ", ");
            append(*sb, value_as_operand(it));
        }
        // scc_iterator::hasCycle: a single node is a cycle if it is its own successor
        if scc.count == 1 {
            t := block_terminator(scc[0]);
            self := false;
            if t != NONE for i: 0..cast(s64) num_successors(t) - 1 if get_successor(t, cast(u32) i) == scc[0] self = true;
            if self append(*sb, " (Has self-loop).");
        }
    }
    append(*sb, "\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// DominanceFrontierPrinterPass::run: getResult<DominanceFrontierAnalysis> = DominanceFrontierBase::analyze(DT), then
// print. Frontiers is a std::map<BasicBlock *, SetVector<BasicBlock *>>, printed in pointer order: with more than one
// entry we fail loudly unless -domfrontier-guess-address-order (guess: block order in the function).
domfrontier_guess_address_order := false;

print_domfrontier_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    Frontier :: struct { b: Value_Id; set: [..] Value_Id; }
    fr: [..] Frontier; fr.allocator = temp;
    index: Table(Value_Id, s64); index.allocator = temp;
    frontier_of :: (fr: *[..] Frontier, index: *Table(Value_Id, s64), b: Value_Id) -> *[..] Value_Id {
        found, i := table_find(index, b);
        if !found {
            e: Frontier; e.b = b; e.set.allocator = temp;
            array_add(fr, e);
            i = fr.count - 1;
            table_set(index, b, i);
        }
        return *fr.*[i].set;
    }
    set_insert :: (s: *[..] Value_Id, b: Value_Id) { for s.* if it == b return; array_add(s, b); }

    Work :: struct { bb: Value_Id; parent_bb: Value_Id; node: s32; parent_node: s32; }
    root := dt.root_node;
    work: [..] Work; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, .{dt_block(dt, root), NONE, root, -1});
    while work.count {
        cur := work[work.count - 1];
        if cur.bb != NONE && !table_contains(*visited, cur.bb) {
            table_set(*visited, cur.bb, true);
            s := frontier_of(*fr, *index, cur.bb);
            t := block_terminator(cur.bb);
            if t != NONE for i: 0..cast(s64) num_successors(t) - 1 {
                child := get_successor(t, cast(u32) i);
                if dt_idom(dt, dt_node(dt, child)) != cur.node set_insert(s, child);
            }
        }
        visit_child := false;
        c := dt.nodes[cur.node].first_child;
        while c >= 0 {
            cb := dt_block(dt, c);
            if !table_contains(*visited, cb) {
                array_add(*work, .{cb, cur.bb, c, cur.node});
                visit_child = true;
            }
            c = dt.nodes[c].sibling;
        }
        if !visit_child {
            if root == cur.node break;
            work.count -= 1;
            if cur.parent_bb == NONE continue;
            s := frontier_of(*fr, *index, cur.bb);
            ps := frontier_of(*fr, *index, cur.parent_bb);
            // iterate by index: ps may be s's neighbour in `fr`, but the set arrays are separate
            for k: 0..s.count - 1 {
                x := s.*[k];
                if !dt_dominates_nodes_proper(dt, cur.parent_node, dt_node(dt, x)) set_insert(ps, x);
            }
        }
    }
    if fr.count > 1 && !domfrontier_guess_address_order
        fatal("print<domfrontier>: LLVM prints the frontiers in BasicBlock pointer order (std::map); use -domfrontier-guess-address-order to guess block order");
    order: [..] s64; order.allocator = temp;
    for b: fn_blocks(f) { found, i := table_find(*index, b); if found array_add(*order, i); }
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "DominanceFrontier for function: %\n", vname(f));
    for i: order {
        e := *fr[i];
        print_to_builder(*sb, "  DomFrontier for BB % is:\t", value_as_operand(e.b));
        for e.set { append(*sb, " "); append(*sb, value_as_operand(it)); }
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// DominatorTreeBase::properlyDominates(const DomTreeNodeBase *A, const DomTreeNodeBase *B)
dt_dominates_nodes_proper :: (dt: *Dom_Tree, a: s32, b: s32) -> bool {
    if a < 0 || b < 0 return false;
    if a == b return false;
    return dt_dominates_nodes(dt, a, b);
}

registry_printers_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "domfrontier-guess-address-order" { domfrontier_guess_address_order = !has_value || value == "true" || value == "1"; return true; }
    return false;
}

// StackLifetimePrinterPass::run (llvm/lib/Analysis/StackLifetime.cpp): StackLifetime(F, every alloca, Type), run(),
// then F.print(OS, &LifetimeAnnotationWriter)
sl_print_state: *Stack_Lifetime;
sl_print_allocas: [] Value_Id;

print_stack_lifetime_run :: (f: Value_Id, name: string) -> Preserved {
    // parseStackLifetimeOptions: the last of may / must wins, May by default
    must := false;
    lt := "print<stack-lifetime>".count;
    if name.count > lt {
        params := slice(name, lt + 1, name.count - lt - 2);
        while params.count {
            k := find_index_from_left(params, #char ";");
            pn := ifx k >= 0 then slice(params, 0, k) else params;
            params = ifx k >= 0 then slice(params, k + 1, params.count - k - 1) else "";
            must = pn == "must";
        }
    }
    allocas: [..] Value_Id; allocas.allocator = temp;
    for i: fn_insts(f) if inst_op(i) == .ALLOCA array_add(*allocas, i);
    sl := stack_lifetime_run(f, allocas, may_liveness = !must);
    sl_print_state = *sl;
    sl_print_allocas = allocas;
    printer_begin_function(f);
    start := W.buf.count;
    print_annot_block = sl_annot_block;
    print_annot_info = sl_annot_info;
    print_function(f);
    print_annot_block = null;
    print_annot_info = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    sl_print_state = null;
    write_string(s, to_standard_error = true);
    return PRESERVE_ALL;
}

sl_print_alive :: (pick: (a: Value_Id, k: s64) -> bool) {
    names: [..] string; names.allocator = temp;
    for a, k: sl_print_allocas if pick(a, k) array_add(*names, vname(a));
    quick_sort(names, compare_strings_bytewise);
    for names { if it_index > 0 outc(#char " "); out(it); }
}

// emitBasicBlockStartAnnot: printInstrAlive(BlockInstRange[BB].first)
sl_annot_block :: (b: Value_Id) {
    sl := sl_print_state;
    found, bi := table_find(*sl.block_index, b);
    if !found return;   // unreachable
    sl_annot_inst_no = sl.inst_start[bi];
    out("  ; Alive: <");
    sl_print_alive((a: Value_Id, k: s64) -> bool {
        _, n := table_find(*sl_print_state.numbering, a);
        return sl_print_state.ranges[n][sl_annot_inst_no];
    });
    out(">\n");
}
sl_annot_inst_no: s64;

// printInfoComment
sl_annot_info :: (i: Value_Id) {
    sl := sl_print_state;
    if !stack_lifetime_is_reachable(sl, i) return;
    sl_annot_cur = i;
    out("\n  ; Alive: <");
    sl_print_alive((a: Value_Id, k: s64) -> bool { return stack_lifetime_is_alive_after(sl_print_state, a, sl_annot_cur); });
    out(">\n");
}
sl_annot_cur: Value_Id;

compare_strings_bytewise :: (a: string, b: string) -> s64 {
    n := min(a.count, b.count);
    for k: 0..n - 1 if a[k] != b[k] return cast(s64) a[k] - cast(s64) b[k];
    return a.count - b.count;
}

// InlineCostAnnotationPrinterPass::run (llvm/lib/Analysis/InlineCost.cpp): for every direct call of a defined
// function, an InlineCostCallAnalyzer with getInlineParams() (no GetBFI / GetTLI, the cached PSI), analyze(), then
// InlineCostCallAnalyzer::print: the callee with InlineCostAnnotationWriter comments and the counters.
ic_print_annots: Table(Value_Id, string);

print_inline_cost_run :: (f: Value_Id) -> Preserved {
    ic_print_instruction_comments = true;
    params := get_inline_params();
    sb: String_Builder; sb.allocator = temp;
    for cb: fn_insts(f) {
        if !is_call_base(cb) continue;
        callee := call_called_function(cb);
        if callee == NONE || is_declaration(callee) continue;
        ca := cax_new(callee, cb, params, true, false, no_bfi = true, has_ore = true);
        cax_analyze(ca);
        print_to_builder(*sb, "      Analyzing call of %... (caller:%)\n", vname(callee), vname(inst_fn(cb)));
        // the annotations first (printing a value of the caller moves the printer's slot state)
        ic_print_annots = .{}; ic_print_annots.allocator = temp;
        for i: fn_insts(callee) table_set(*ic_print_annots, i, ic_annotation(ca, i));
        printer_begin_function(callee);
        start := W.buf.count;
        print_annot_inst = ic_annot_inst;
        print_function(callee);
        print_annot_inst = null;
        append(*sb, slice_of_buf(start));
        W.buf.count = start;
        stat :: (sb: *String_Builder, n: string, v: Any) { print_to_builder(sb, "      %: %\n", n, v); }
        stat(*sb, "NumConstantArgs", ca.num_constant_args);
        stat(*sb, "NumConstantOffsetPtrArgs", ca.num_constant_offset_ptr_args);
        stat(*sb, "NumAllocaArgs", ca.num_alloca_args);
        stat(*sb, "NumConstantPtrCmps", ca.num_constant_ptr_cmps);
        stat(*sb, "NumConstantPtrDiffs", ca.num_constant_ptr_diffs);
        stat(*sb, "NumInstructionsSimplified", ca.num_instructions_simplified);
        stat(*sb, "NumInstructions", ca.num_instructions);
        stat(*sb, "NumInlineAsmInstructions", ca.num_inline_asm_instructions);
        stat(*sb, "SROACostSavings", ca.sroa_cost_savings);
        stat(*sb, "SROACostSavingsLost", ca.sroa_cost_savings_lost);
        stat(*sb, "LoadEliminationCost", ca.load_elimination_cost);
        stat(*sb, "ContainsNoDuplicateCall", cast(s64) ca.contains_no_duplicate_call);
        stat(*sb, "Cost", ca.cost);
        stat(*sb, "Threshold", ca.threshold);
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

ic_annot_inst :: (i: Value_Id) {
    found, s := table_find(*ic_print_annots, i);
    if found out(s);
}

// InlineCostAnnotationWriter::emitInstructionAnnot
ic_annotation :: (ca: *Call_Analyzer, i: Value_Id) -> string {
    sb: String_Builder; sb.allocator = temp;
    d := table_find_pointer(*ca.details, i);
    if !d append(*sb, "; No analysis for the instruction");
    else {
        print_to_builder(*sb, "; cost before = %, cost after = %, threshold before = %, threshold after = %, cost delta = %",
            d.cost_before, d.cost_after, d.threshold_before, d.threshold_after, d.cost_after - d.cost_before);
        if d.threshold_after != d.threshold_before print_to_builder(*sb, ", threshold delta = %", d.threshold_after - d.threshold_before);
    }
    v := cax_simplified_unchecked(ca, i);
    if v != NONE {
        append(*sb, ", simplified to ");
        // V->print(OS, /*IsForDebug=*/true)
        k := vkind(v);
        if k == .INST {
            append(*sb, inst_to_string(v));
            if inst_fn(v) != inst_fn(i) append(*sb, " (caller instruction)");
        } else if k == .GLOBAL_VAR || k == .FUNCTION {
            append(*sb, value_print_isolated(v));   // Value::print of a global prints its definition
        } else if is_global_value(k) {
            fatal("print<inline-cost>: a value simplified to an alias or ifunc is not supported yet");
        } else if k == .ARGUMENT {
            append(*sb, value_as_operand_typed(v));
            if arg_parent(v) != inst_fn(i) append(*sb, " (caller argument)");
        } else if is_constant_kind(k) {
            // Value::print of a Constant uses a fresh TypePrinting without the module: an unnamed identified struct
            // prints as %"type 0x<address>"
            if ic_constant_has_unnamed_struct(v) fatal("print<inline-cost>: LLVM prints the unnamed struct type of a simplified constant by its address");
            append(*sb, value_as_operand_typed(v));
        } else fatal("print<inline-cost>: simplified to an unsupported kind of value");
    }
    append(*sb, "\n");
    return builder_to_string(*sb,, allocator = temp);
}

ic_type_has_unnamed_struct :: (t: Type_Id) -> bool {
    r := ir.types[t];
    if r.kind == .STRUCT && !(r.flags & TYF_LITERAL) && r.name.count == 0 return true;
    if r.kind == .ARRAY || r.kind == .VECTOR || r.kind == .SVECTOR return ic_type_has_unnamed_struct(type_elem(t));
    if r.kind == .STRUCT || r.kind == .FUNC || r.kind == .TARGET_EXT {
        if r.nsub > 0 for i: 0..r.nsub - 1 if ic_type_has_unnamed_struct(type_sub(t, cast(u32) i)) return true;
    }
    return false;
}
ic_constant_has_unnamed_struct :: (v: Value_Id) -> bool {
    if ic_type_has_unnamed_struct(vtype(v)) return true;
    k := vkind(v);
    if is_global_value(k) return false;
    if k == .C_EXPR && cexpr(v).op == .GEP && ic_type_has_unnamed_struct(cexpr(v).ty2) return true;
    if nops(v) > 0 for i: 0..nops(v) - 1 { o := op(v, i); if o != NONE && ic_constant_has_unnamed_struct(o) return true; }
    return false;
}
