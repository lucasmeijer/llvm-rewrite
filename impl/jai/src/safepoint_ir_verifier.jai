// verify<safepoint-ir>: a port of llvm/lib/IR/SafepointIRVerifier.cpp (CFGDeadness, GCPtrTracker, InstructionVerifier).
//
// The available sets are DenseSets (membership only). GCPtrTracker::recalculateBBsStates seeds its worklist from the
// BlockMap DenseMap (pointer order); the fixpoint is computed twice, from the blocks in function order and in reverse
// order, and the verifier fails loudly when the two disagree (see NOTES.md "Heap/pointer address order").

spv_cl: struct { print_only := false; };   // -safepoint-ir-verifier-print-only
safepoint_ir_verifier_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "safepoint-ir-verifier-print-only" { spv_cl.print_only = smisc_bool(name, value, has_value); return true; }
    return false;
}

spv_is_gc_pointer_type :: (t: Type_Id) -> bool { return is_ptr_type(t) && ptr_addrspace(t) == 1; }
spv_contains_gc_ptr_type :: (t: Type_Id) -> bool {
    if spv_is_gc_pointer_type(t) return true;
    if is_vector_type(t) return spv_is_gc_pointer_type(type_elem(t));
    k := type_kind(t);
    if k == .ARRAY return spv_contains_gc_ptr_type(type_elem(t));
    if k == .STRUCT { n := type_nsub(t); if n > 0 for i: 0..n-1 if spv_contains_gc_ptr_type(type_sub(t, i)) return true; }
    return false;
}

// ---------------------------------------------------------------- CFGDeadness

Spv_Deadness :: struct {
    dt: *Dom_Tree;
    dead_blocks: Table(Value_Id, bool);
    dead_edges: Table(Use_Id, bool);   // the terminator operand uses of dead edges
}
spv_is_dead_block :: (cd: *Spv_Deadness, b: Value_Id) -> bool { return table_contains(*cd.dead_blocks, b); }
spv_is_dead_edge :: (cd: *Spv_Deadness, u: Use_Id) -> bool { return table_contains(*cd.dead_edges, u); }
// the predecessor edges of a block: the uses of the block by terminators (const_pred_iterator)
spv_pred_edges :: (b: Value_Id, out: *[..] Use_Id) {
    out.count = 0;
    u := ir.v_first_use[b];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && is_terminator(inst_op(usr)) array_add(out, u);
        u = ir.u_next[u];
    }
}
spv_has_live_incoming_edge :: (cd: *Spv_Deadness, pn: Value_Id, in_bb: Value_Id) -> bool {
    edges: [..] Use_Id; edges.allocator = temp;
    spv_pred_edges(inst_block(pn), *edges);
    for u: edges if inst_block(ir.u_user[u]) == in_bb && !spv_is_dead_edge(cd, u) return true;
    return false;
}
spv_has_live_incoming_edges :: (cd: *Spv_Deadness, b: Value_Id) -> bool {
    edges: [..] Use_Id; edges.allocator = temp;
    spv_pred_edges(b, *edges);
    for u: edges if !spv_is_dead_block(cd, inst_block(ir.u_user[u])) && !spv_is_dead_edge(cd, u) return true;
    return false;
}
spv_add_dead_block :: (cd: *Spv_Deadness, b: Value_Id) {
    nd: [..] Value_Id; nd.allocator = temp;
    array_add(*nd, b);
    dom: [..] Value_Id; dom.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    while nd.count {
        d := pop(*nd);
        if spv_is_dead_block(cd, d) continue;
        dt_get_descendants(cd.dt, d, *dom);
        for dom table_set(*cd.dead_blocks, it, true);
        for x: dom {
            succs.count = 0; block_successors(x, *succs);
            for s: succs if !spv_is_dead_block(cd, s) && !spv_has_live_incoming_edges(cd, s) array_add(*nd, s);
        }
    }
}
spv_add_dead_edge :: (cd: *Spv_Deadness, u: Use_Id) {
    if table_contains(*cd.dead_edges, u) return;
    table_set(*cd.dead_edges, u, true);
    b := ir.u_val[u];
    if spv_has_live_incoming_edges(cd, b) return;
    spv_add_dead_block(cd, b);
}
spv_rpo :: (f: Value_Id) -> [..] Value_Id {
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    r: [..] Value_Id; r.allocator = temp;
    for < po array_add(*r, it);
    return r;
}
spv_process_function :: (cd: *Spv_Deadness, f: Value_Id, dt: *Dom_Tree) {
    cd.dt = dt;
    cd.dead_blocks.allocator = temp; cd.dead_edges.allocator = temp;
    for b: fn_blocks(f) if !dt_is_reachable_from_entry(dt, b) table_set(*cd.dead_blocks, b, true);
    for b: spv_rpo(f) {
        t := block_terminator(b);
        if inst_op(t) != .CONDBR || !is_const(op(t, 0)) continue;
        if get_successor(t, 0) == get_successor(t, 1) continue;
        c := op(t, 0);
        if vkind(c) != .C_INT continue;
        spv_add_dead_edge(cd, op_use(t, ifx const_int_zext(c) != 0 then cast(u32) 1 else 2));
    }
}

// ---------------------------------------------------------------- GCPtrTracker

Spv_Base_Type :: enum u8 { NonConstant :: 1; ExclusivelyNull; ExclusivelySomeConstant; }
spv_base_type :: (val: Value_Id) -> Spv_Base_Type {
    wl: [..] Value_Id; wl.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    only_null := true;
    array_add(*wl, val);
    while wl.count {
        v := pop(*wl);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        if is_inst(v) {
            o := inst_op(v);
            if o >= .TRUNC && o <= .ADDRSPACECAST { array_add(*wl, strip_pointer_casts_kind(v, .ZERO_INDICES)); continue; }
            if o == .GEP { array_add(*wl, op(v, 0)); continue; }
            if o == .PHI { n := phi_num_incoming(v); for k: 0..n-1 array_add(*wl, phi_value(v, k)); continue; }
            if o == .SELECT { array_add(*wl, op(v, 1)); array_add(*wl, op(v, 2)); continue; }
            if call_iid(v) == IID_GC_RELOCATE { array_add(*wl, gc_relocate_derived_ptr(v)); continue; }
            if o == .FREEZE { array_add(*wl, op(v, 0)); continue; }
        }
        if is_const(v) {
            if v != const_null_value(vtype(v)) only_null = false;
            continue;
        }
        return .NonConstant;
    }
    return ifx only_null then Spv_Base_Type.ExclusivelyNull else .ExclusivelySomeConstant;
}
spv_not_exclusively_constant_derived :: (v: Value_Id) -> bool { return spv_base_type(v) == .NonConstant; }

Spv_Bb_State :: struct {
    avail_in: Table(Value_Id, bool);
    avail_out: Table(Value_Id, bool);
    contribution: Table(Value_Id, bool);
    cleared: bool;
}
Spv_Tracker :: struct {
    f: Value_Id;
    cd: *Spv_Deadness;
    index: Table(Value_Id, s64);
    states: [..] Spv_Bb_State;
    valid_unrelocated: Table(Value_Id, bool);
    poisoned: Table(Value_Id, bool);
}
spv_set_new :: () -> Table(Value_Id, bool) { t: Table(Value_Id, bool); t.allocator = temp; return t; }
spv_set_copy :: (s: *Table(Value_Id, bool)) -> Table(Value_Id, bool) {
    t := spv_set_new();
    for _, k: s.* table_set(*t, k, true);
    return t;
}
spv_state :: (t: *Spv_Tracker, b: Value_Id) -> *Spv_Bb_State {
    p := table_find_pointer(*t.index, b);
    if !p return null;
    return *t.states[p.*];
}
spv_transfer_instruction :: (i: Value_Id, cleared: *bool, avail: *Table(Value_Id, bool)) {
    if call_iid(i) == IID_EXPERIMENTAL_GC_STATEPOINT { cleared.* = true; table_reset(avail); }
    else if spv_contains_gc_ptr_type(vtype(i)) table_set(avail, i, true);
}
spv_transfer_block :: (s: *Spv_Bb_State, contribution_changed: bool) {
    if s.cleared {
        if contribution_changed s.avail_out = spv_set_copy(*s.contribution);
    } else {
        tmp := spv_set_copy(*s.contribution);
        for _, k: s.avail_in table_set(*tmp, k, true);
        s.avail_out = tmp;
    }
}
spv_gather_dominating_defs :: (t: *Spv_Tracker, b: Value_Id, result: *Table(Value_Id, bool), dt: *Dom_Tree) {
    n := dt_node(dt, b);
    assert(n >= 0, "Unreachable blocks are ignored");
    while dt_idom(dt, n) >= 0 {
        n = dt_idom(dt, n);
        s := spv_state(t, dt_block(dt, n));
        assert(s != null, "immediate dominator cannot be dead for a live block");
        for _, k: s.contribution table_set(result, k, true);
        if s.cleared return;
    }
    na := func_nparams(glob(t.f).value_type);
    for x: 0..cast(s64) na - 1 { a := fn_arg(t.f, cast(u32) x); if spv_contains_gc_ptr_type(vtype(a)) table_set(result, a, true); }
}
spv_remove_valid_unrelocated_defs :: (t: *Spv_Tracker, b: Value_Id, s: *Spv_Bb_State) -> bool {
    avail := spv_set_copy(*s.avail_in);
    changed := false;
    for i: block_insts(b) {
        valid_unreloc, poisoned := false, false;
        if inst_op(i) == .PHI {
            if spv_contains_gc_ptr_type(vtype(i)) {
                has_reloc, has_unreloc := false, false;
                n := phi_num_incoming(i);
                for k: 0..n-1 {
                    in_bb := phi_block(i, k);
                    if !table_contains(*t.index, in_bb) || !spv_has_live_incoming_edge(t.cd, i, in_bb) continue;
                    iv := phi_value(i, k);
                    if spv_not_exclusively_constant_derived(iv) {
                        if table_contains(*t.poisoned, iv) { has_reloc = true; has_unreloc = true; break; }
                        if table_contains(*spv_state(t, in_bb).avail_out, iv) has_reloc = true;
                        else has_unreloc = true;
                    }
                }
                if has_unreloc { if has_reloc poisoned = true; else valid_unreloc = true; }
            }
        } else if (inst_op(i) == .GEP || inst_op(i) == .BITCAST) && spv_contains_gc_ptr_type(vtype(i)) {
            n := nops(i);
            for k: 0..n-1 {
                v := op(i, k);
                if spv_contains_gc_ptr_type(vtype(v)) && spv_not_exclusively_constant_derived(v) && !table_contains(*avail, v) {
                    if table_contains(*t.poisoned, v) poisoned = true; else valid_unreloc = true;
                    break;
                }
            }
        }
        if valid_unreloc {
            table_remove(*s.contribution, i);
            table_remove(*t.poisoned, i);
            table_set(*t.valid_unrelocated, i, true);
            changed = true;
        } else if poisoned {
            table_remove(*s.contribution, i);
            table_set(*t.poisoned, i, true);
            changed = true;
        } else {
            cl := false;
            spv_transfer_instruction(i, *cl, *avail);
        }
    }
    return changed;
}
spv_recalculate :: (t: *Spv_Tracker, order: [] Value_Id) {
    wl: Rs_Set; rs_set_init(*wl);
    for order rs_set_insert(*wl, it);
    edges: [..] Use_Id; edges.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    while wl.list.count {
        b := rs_set_pop_back(*wl);
        s := spv_state(t, b);
        if !s continue;
        old_in := s.avail_in.count;
        spv_pred_edges(b, *edges);
        for u: edges {
            pb := inst_block(ir.u_user[u]);
            ps := spv_state(t, pb);
            if ps && !spv_is_dead_edge(t.cd, u) {
                // set_intersect(AvailableIn, PBBS->AvailableOut)
                rm: [..] Value_Id; rm.allocator = temp;
                for _, k: s.avail_in if !table_contains(*ps.avail_out, k) array_add(*rm, k);
                for rm table_remove(*s.avail_in, it);
            }
        }
        inputs_changed := old_in != s.avail_in.count;
        contribution_changed := spv_remove_valid_unrelocated_defs(t, b, s);
        if !inputs_changed && !contribution_changed continue;
        old_out := s.avail_out.count;
        spv_transfer_block(s, contribution_changed);
        if old_out != s.avail_out.count {
            succs.count = 0; block_successors(b, *succs);
            for succs rs_set_insert(*wl, it);
        }
    }
}

Spv_Report :: struct { lines: [..] string; }
spv_report_invalid_use :: (r: *Spv_Report, v: Value_Id, i: Value_Id) {
    def := ifx is_inst(v) then inst_to_string(v) else value_as_operand_typed(v);
    array_add(*r.lines, tprint("Illegal use of unrelocated value found!\nDef: %\nUse: %\n", def, inst_to_string(i)));
}
spv_verify_instruction :: (t: *Spv_Tracker, i: Value_Id, avail: *Table(Value_Id, bool), r: *Spv_Report) {
    o := inst_op(i);
    if o == .PHI {
        if spv_contains_gc_ptr_type(vtype(i)) {
            n := phi_num_incoming(i);
            for k: 0..n-1 {
                in_bb := phi_block(i, k);
                ins := spv_state(t, in_bb);
                if !ins || !spv_has_live_incoming_edge(t.cd, i, in_bb) continue;
                iv := phi_value(i, k);
                if spv_not_exclusively_constant_derived(iv) && !table_contains(*ins.avail_out, iv) spv_report_invalid_use(r, iv, i);
            }
        }
    } else if (o == .ICMP || o == .FCMP) && spv_contains_gc_ptr_type(vtype(op(i, 0))) {
        lhs := op(i, 0); rhs := op(i, 1);
        bl := spv_base_type(lhs); br := spv_base_type(rhs);
        valid := true;
        if table_contains(avail, lhs) || table_contains(avail, rhs) valid = false;
        else if (bl == .ExclusivelySomeConstant && br == .NonConstant) || (bl == .NonConstant && br == .ExclusivelySomeConstant) valid = false;
        else if (table_contains(*t.poisoned, lhs) && br != .ExclusivelyNull) || (table_contains(*t.poisoned, rhs) && bl != .ExclusivelyNull) valid = false;
        if !valid {
            if bl == .NonConstant && !table_contains(avail, lhs) spv_report_invalid_use(r, lhs, i);
            if br == .NonConstant && !table_contains(avail, rhs) spv_report_invalid_use(r, rhs, i);
        }
    } else {
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            v := op(i, cast(u32) k);
            if v == NONE continue;
            if spv_contains_gc_ptr_type(vtype(v)) && spv_not_exclusively_constant_derived(v) && !table_contains(avail, v) spv_report_invalid_use(r, v, i);
        }
    }
}

// GCPtrTracker + verifyFunction with a given worklist seed order: the report
spv_run :: (f: Value_Id, dt: *Dom_Tree, cd: *Spv_Deadness, order: [] Value_Id) -> Spv_Report {
    t: Spv_Tracker;
    t.f = f; t.cd = cd;
    t.index.allocator = temp; t.states.allocator = temp;
    t.valid_unrelocated = spv_set_new(); t.poisoned = spv_set_new();
    for b: fn_blocks(f) {
        if spv_is_dead_block(cd, b) continue;
        s: Spv_Bb_State;
        s.avail_in = spv_set_new(); s.avail_out = spv_set_new(); s.contribution = spv_set_new();
        for i: block_insts(b) spv_transfer_instruction(i, *s.cleared, *s.contribution);
        table_set(*t.index, b, t.states.count);
        array_add(*t.states, s);
    }
    for b: fn_blocks(f) {
        s := spv_state(*t, b);
        if !s continue;
        spv_gather_dominating_defs(*t, b, *s.avail_in, dt);
        spv_transfer_block(s, true);
    }
    live_order: [..] Value_Id; live_order.allocator = temp;
    for order if spv_state(*t, it) array_add(*live_order, it);
    spv_recalculate(*t, live_order);
    r: Spv_Report; r.lines.allocator = temp;
    for b: spv_rpo(f) {
        s := spv_state(*t, b);
        if !s continue;
        avail := *s.avail_in;
        for i: block_insts(b) {
            if table_contains(*t.valid_unrelocated, i) || table_contains(*t.poisoned, i) continue;
            spv_verify_instruction(*t, i, avail, *r);
            cl := false;
            spv_transfer_instruction(i, *cl, avail);
        }
    }
    return r;
}

// SafepointIRVerifierPass::run
safepoint_ir_verifier_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    cd: Spv_Deadness;
    spv_process_function(*cd, f, dt);
    if spv_cl.print_only write_string(tprint("Verifying gc pointers in function: %\n", vname(f)), to_standard_error = true);
    fwd: [..] Value_Id; fwd.allocator = temp;
    for b: fn_blocks(f) array_add(*fwd, b);
    rev: [..] Value_Id; rev.allocator = temp;
    for < fwd array_add(*rev, it);
    r1 := spv_run(f, dt, *cd, fwd);
    r2 := spv_run(f, dt, *cd, rev);
    same := r1.lines.count == r2.lines.count;
    if same for r1.lines if it != r2.lines[it_index] { same = false; break; }
    if !same fatal("verify<safepoint-ir>: the result depends on the DenseMap (address) order of GCPtrTracker's worklist");
    for r1.lines {
        write_string(it, to_standard_error = true);
        if !spv_cl.print_only fatal("verify<safepoint-ir>: illegal use of an unrelocated value (LLVM aborts)");
    }
    if spv_cl.print_only && r1.lines.count == 0
        write_string(tprint("No illegal uses found by SafepointIRVerifier in: %\n", vname(f)), to_standard_error = true);
    return PRESERVE_ALL;
}
