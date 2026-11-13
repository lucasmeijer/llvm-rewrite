// PredicateInfo: a port of llvm/lib/Transforms/Utils/PredicateInfo.cpp (PredicateInfoBuilder, getConstraint) and
// the nonnull part of llvm/lib/IR/BundleAttributes.cpp. The SSA copies are no-op `bitcast X to T` instructions
// (LLVM 23); `pi_info_for(pi, copy)` is PredicateInfo::getPredicateInfoFor. Not ported: the print<predicateinfo>
// annotated printer.

Pred_Kind :: enum u8 { BRANCH; SWITCH; CONDITION_ASSUME; BUNDLE_ASSUME; }

Pred_Info :: struct {
    kind: Pred_Kind;
    original_op: Value_Id = NONE;
    renamed_op: Value_Id = NONE;
    condition: Value_Id = NONE;
    from: Value_Id = NONE;      // PredicateWithEdge
    to: Value_Id = NONE;
    true_edge: bool;            // PredicateBranch
    case_value: Value_Id = NONE;   // PredicateSwitch
    assume_inst: Value_Id = NONE;  // PredicateAssume
}
pi_has_edge :: inline (p: *Pred_Info) -> bool { return p.kind == .BRANCH || p.kind == .SWITCH; }
pi_is_assume :: inline (p: *Pred_Info) -> bool { return p.kind == .CONDITION_ASSUME || p.kind == .BUNDLE_ASSUME; }

Predicate_Info :: struct {
    f: Value_Id;
    infos: [..] Pred_Info;
    map: Table(Value_Id, s32);   // PredicateMap: copy -> info
}

// PredicateConstraint
Pred_Constraint :: struct { ok: bool; pred: u8; other: Value_Id = NONE; }

PI_LN_FIRST :: 0; PI_LN_MIDDLE :: 1; PI_LN_LAST :: 2;
PI_MAX_CONDS_PER_BRANCH :: 8;

Value_Dfs :: struct {
    dfs_in: s32;
    dfs_out: s32;
    local_num: s32 = PI_LN_MIDDLE;
    u: Use_Id = NONE;
    pinfo: s32 = -1;
}

Pi_Builder :: struct {
    pi: *Predicate_Info;
    dt: *Dom_Tree;
    value_infos: [..] [..] s32;    // ValueInfos (index 0 unused)
    value_info_nums: Table(Value_Id, s32);
}

pi_info_for :: (pi: *Predicate_Info, i: Value_Id) -> *Pred_Info {
    if !pi return null;
    found, k := table_find(*pi.map, i);
    if !found return null;
    return *pi.infos[k];
}

pi_get_or_create_value_info :: (b: *Pi_Builder, op: Value_Id) -> s32 {
    found, k := table_find(*b.value_info_nums, op);
    if found return k;
    k = cast(s32) b.value_infos.count;
    table_set(*b.value_info_nums, op, k);
    l: [..] s32; l.allocator = temp;
    array_add(*b.value_infos, l);
    return k;
}

pi_add_info_for :: (b: *Pi_Builder, ops_to_rename: *[..] Value_Id, op: Value_Id, pb: Pred_Info) {
    k := pi_get_or_create_value_info(b, op);
    if b.value_infos[k].count == 0 array_add(ops_to_rename, op);
    id := cast(s32) b.pi.infos.count;
    array_add(*b.pi.infos, pb);
    array_add(*b.value_infos[k], id);
}

// shouldRename
pi_should_rename :: (v: Value_Id) -> bool {
    return (is_inst(v) || vkind(v) == .ARGUMENT) && !has_one_use(v);
}

// m_NUWTrunc(m_Value(X))
pi_match_nuw_trunc :: (v: Value_Id) -> (bool, Value_Id) {
    if is_inst(v) && inst_op(v) == .TRUNC && (inst(v).flags & F_NUW) != 0 return true, op(v, 0);
    return false, NONE;
}

pi_collect_values :: (cond: Value_Id, values: *[..] Value_Id) {
    array_add(values, cond);
    if is_inst(cond) && (inst_op(cond) == .ICMP || inst_op(cond) == .FCMP) {
        // collectCmpOps
        a := op(cond, 0); c := op(cond, 1);
        if a != c { array_add(values, a); array_add(values, c); }
    } else {
        ok, x := pi_match_nuw_trunc(cond);
        if ok array_add(values, x);
    }
}

pi_process_assume :: (b: *Pi_Builder, ii: Value_Id, ops: *[..] Value_Id) {
    nb := call_num_bundles(ii);
    if nb > 0 {
        for k: 0..nb - 1 {
            if call_bundle_tag(ii, k) != "nonnull" continue;
            begin := ir.u32_pool[inst(ii).idx + 3 * k + 1];
            ptr := op(ii, begin);
            if pi_should_rename(ptr) {
                p: Pred_Info; p.kind = .BUNDLE_ASSUME; p.original_op = ptr; p.assume_inst = ii;
                pi_add_info_for(b, ops, ptr, p);
            }
        }
        return;
    }
    work: [..] Value_Id; work.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*work, op(ii, 0));
    while work.count {
        cond := pop(*work);
        seen := false;
        for visited if it == cond { seen = true; break; }
        if seen continue;
        array_add(*visited, cond);
        if visited.count > PI_MAX_CONDS_PER_BRANCH break;
        ok, o0, o1 := pm_logical_and(cond);
        if ok { array_add(*work, o1); array_add(*work, o0); }
        values: [..] Value_Id; values.allocator = temp;
        pi_collect_values(cond, *values);
        for v: values {
            if pi_should_rename(v) {
                p: Pred_Info; p.kind = .CONDITION_ASSUME; p.original_op = v; p.assume_inst = ii; p.condition = cond;
                pi_add_info_for(b, ops, v, p);
            }
        }
    }
}

pi_process_branch :: (b: *Pi_Builder, bi: Value_Id, branch_bb: Value_Id, ops: *[..] Value_Id) {
    first := get_successor(bi, 0); second := get_successor(bi, 1);
    for succ: Value_Id.[first, second] {
        taken := succ == first;
        if succ == branch_bb continue;
        work: [..] Value_Id; work.allocator = temp;
        visited: [..] Value_Id; visited.allocator = temp;
        array_add(*work, op(bi, 0));
        while work.count {
            cond := pop(*work);
            seen := false;
            for visited if it == cond { seen = true; break; }
            if seen continue;
            array_add(*visited, cond);
            if visited.count > PI_MAX_CONDS_PER_BRANCH break;
            ok: bool; o0, o1: Value_Id;
            if taken ok, o0, o1 = pm_logical_and(cond); else ok, o0, o1 = pm_logical_or(cond);
            if ok { array_add(*work, o1); array_add(*work, o0); }
            values: [..] Value_Id; values.allocator = temp;
            pi_collect_values(cond, *values);
            for v: values {
                if pi_should_rename(v) {
                    p: Pred_Info; p.kind = .BRANCH; p.original_op = v; p.from = branch_bb; p.to = succ;
                    p.condition = cond; p.true_edge = taken;
                    pi_add_info_for(b, ops, v, p);
                }
            }
        }
    }
}

pi_process_switch :: (b: *Pi_Builder, si: Value_Id, branch_bb: Value_Id, ops: *[..] Value_Id) {
    o := sw_cond(si);
    if (!is_inst(o) && vkind(o) != .ARGUMENT) || has_one_use(o) return;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(branch_bb, *succs);
    edge_count :: (succs: [] Value_Id, t: Value_Id) -> s64 { n := 0; for succs if it == t n += 1; return n; }
    n := sw_num_cases(si);
    if n > 0 for k: 0..n - 1 {
        target := sw_case_dest(si, k);
        if edge_count(succs, target) == 1 {
            p: Pred_Info; p.kind = .SWITCH; p.original_op = o; p.from = inst_block(si); p.to = target;
            p.condition = sw_cond(si); p.case_value = sw_case_value(si, k);
            pi_add_info_for(b, ops, o, p);
        }
    }
}

// ValueDFS_Compare
pi_vd_less :: (b: *Pi_Builder, a: *Value_Dfs, c: *Value_Dfs) -> bool {
    if a == c return false;
    if a.dfs_in != c.dfs_in return a.dfs_in < c.dfs_in;
    if a.local_num != c.local_num return a.local_num < c.local_num;
    if a.local_num == PI_LN_LAST {
        // comparePHIRelated
        _, ad := pi_vd_edge(b, a);
        _, bd := pi_vd_edge(b, c);
        ain := cast(s64) b.dt.nodes[dt_node(b.dt, ad)].dfs_in;
        bin := cast(s64) b.dt.nodes[dt_node(b.dt, bd)].dfs_in;
        a_use := a.u != NONE; b_use := c.u != NONE;
        if ain != bin return ain < bin;
        return !a_use && b_use;
    }
    if a.local_num == PI_LN_MIDDLE return comes_before(pi_vd_def_or_user(b, a), pi_vd_def_or_user(b, c));
    return false;
}
pi_vd_edge :: (b: *Pi_Builder, vd: *Value_Dfs) -> (Value_Id, Value_Id) {
    if vd.u != NONE {
        phi := ir.u_user[vd.u];
        return phi_block(phi, cast(u32) (vd.u - ir.v_ops[phi])), inst_block(phi);
    }
    p := *b.pi.infos[vd.pinfo];
    return p.from, p.to;
}
pi_vd_def_or_user :: (b: *Pi_Builder, vd: *Value_Dfs) -> Value_Id {
    if vd.u != NONE return ir.u_user[vd.u];
    return inst(b.pi.infos[vd.pinfo].assume_inst).next;
}

// llvm::stable_sort with ValueDFS_Compare (a strict weak order: any stable sort agrees)
pi_stable_sort :: (b: *Pi_Builder, a: *[..] Value_Dfs) {
    n := a.count;
    if n < 2 return;
    tmp := NewArray(n, Value_Dfs,, allocator = temp);
    width := 1;
    src := a.data; dst := tmp.data;
    while width < n {
        i := 0;
        while i < n {
            mid := min(i + width, n); hi := min(i + 2 * width, n);
            l := i; r := mid; k := i;
            while l < mid && r < hi {
                if pi_vd_less(b, *src[r], *src[l]) { dst[k] = src[r]; r += 1; }
                else { dst[k] = src[l]; l += 1; }
                k += 1;
            }
            while l < mid { dst[k] = src[l]; l += 1; k += 1; }
            while r < hi { dst[k] = src[r]; r += 1; k += 1; }
            i += 2 * width;
        }
        t := src; src = dst; dst = t;
        width *= 2;
    }
    if src != a.data for k: 0..n - 1 a.data[k] = src[k];
}

Pi_Stack_Entry :: struct { vd: s32; def: Value_Id = NONE; }

pi_stack_is_in_scope :: (b: *Pi_Builder, stack: [..] Pi_Stack_Entry, uses: [] Value_Dfs, vd: *Value_Dfs) -> bool {
    top := *uses[stack[stack.count - 1].vd];
    if top.local_num == PI_LN_LAST {
        tp := *b.pi.infos[top.pinfo];
        if vd.u == NONE {
            vp := *b.pi.infos[vd.pinfo];
            return vd.local_num == PI_LN_LAST && tp.from == vp.from && tp.to == vp.to;
        }
        usr := ir.u_user[vd.u];
        if !is_inst(usr) || inst_op(usr) != .PHI return false;
        edge_pred := phi_block(usr, cast(u32) (vd.u - ir.v_ops[usr]));
        if edge_pred != tp.from return false;
        return dt_dominates_edge_use(b.dt, tp.from, tp.to, vd.u);
    }
    return vd.dfs_in >= top.dfs_in && vd.dfs_out <= top.dfs_out;
}

pi_materialize_stack :: (b: *Pi_Builder, counter: *u32, stack: *[..] Pi_Stack_Entry, uses: [] Value_Dfs, orig_op: Value_Id) -> Value_Id {
    // the first entry from the top that already has a def
    start := 0;
    k := stack.count - 1;
    while k >= 0 { if stack.*[k].def != NONE break; k -= 1; start += 1; }
    first := stack.count - start;
    for idx: first..stack.count - 1 {
        o := ifx idx == 0 then orig_op else stack.*[idx - 1].def;
        p := *b.pi.infos[uses[stack.*[idx].vd].pinfo];
        p.renamed_op = ifx first == 0 then orig_op else stack.*[first - 1].def;
        pic: Value_Id;
        if pi_has_edge(p) {
            pt := block_terminator(p.from);
            pic = create_cast(.BITCAST, o, vtype(o));
            insert_at_position(pic, inst_block(pt), pt, false);
            set_name(pic, tprint("%.%", vname(o), counter.*));
            counter.* += 1;
        } else {
            pt := inst(p.assume_inst).next;
            pic = create_cast(.BITCAST, o, vtype(o));
            insert_at_position(pic, inst_block(pt), pt, false);
        }
        table_set(*b.pi.map, pic, uses[stack.*[idx].vd].pinfo);
        stack.*[idx].def = pic;
    }
    return stack.*[stack.count - 1].def;
}

pi_rename_uses :: (b: *Pi_Builder, ops: [] Value_Id) {
    for o: ops {
        counter: u32 = 0;
        uses: [..] Value_Dfs; uses.allocator = temp;
        found, vi := table_find(*b.value_info_nums, o);
        for pidx: b.value_infos[vi] {
            p := *b.pi.infos[pidx];
            vd: Value_Dfs;
            if pi_is_assume(p) {
                vd.local_num = PI_LN_MIDDLE;
                n := dt_node(b.dt, inst_block(p.assume_inst));
                if n < 0 continue;
                vd.dfs_in = cast(s32) b.dt.nodes[n].dfs_in; vd.dfs_out = cast(s32) b.dt.nodes[n].dfs_out;
                vd.pinfo = pidx;
                array_add(*uses, vd);
            } else {
                if block_single_predecessor(p.to) == NONE {
                    vd.local_num = PI_LN_LAST;
                    n := dt_node(b.dt, p.from);
                    if n >= 0 {
                        vd.dfs_in = cast(s32) b.dt.nodes[n].dfs_in; vd.dfs_out = cast(s32) b.dt.nodes[n].dfs_out;
                        vd.pinfo = pidx;
                        array_add(*uses, vd);
                    }
                } else {
                    vd.local_num = PI_LN_FIRST;
                    n := dt_node(b.dt, p.to);
                    if n >= 0 {
                        vd.dfs_in = cast(s32) b.dt.nodes[n].dfs_in; vd.dfs_out = cast(s32) b.dt.nodes[n].dfs_out;
                        vd.pinfo = pidx;
                        array_add(*uses, vd);
                    }
                }
            }
        }
        // convertUsesToDFSOrdered
        u := ir.v_first_use[o];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && !is_lifetime_start_or_end(usr) {
                vd: Value_Dfs;
                ib: Value_Id;
                if inst_op(usr) == .PHI { ib = phi_block(usr, cast(u32) (u - ir.v_ops[usr])); vd.local_num = PI_LN_LAST; }
                else { ib = inst_block(usr); vd.local_num = PI_LN_MIDDLE; }
                n := dt_node(b.dt, ib);
                if n >= 0 {
                    vd.dfs_in = cast(s32) b.dt.nodes[n].dfs_in; vd.dfs_out = cast(s32) b.dt.nodes[n].dfs_out;
                    vd.u = u;
                    array_add(*uses, vd);
                }
            }
            u = ir.u_next[u];
        }
        pi_stable_sort(b, *uses);
        stack: [..] Pi_Stack_Entry; stack.allocator = temp;
        for * vd, vd_index: uses {
            while stack.count && !pi_stack_is_in_scope(b, stack, uses, vd) pop(*stack);
            if vd.pinfo >= 0 { array_add(*stack, .{vd = cast(s32) vd_index}); continue; }
            if stack.count == 0 continue;
            if stack[stack.count - 1].def == NONE {
                d := pi_materialize_stack(b, *counter, *stack, uses, o);
                stack[stack.count - 1].def = d;
            }
            usr := ir.u_user[vd.u];
            set_op(usr, cast(u32) (vd.u - ir.v_ops[usr]), stack[stack.count - 1].def);
        }
    }
}

// PredicateInfo::PredicateInfo (buildPredicateInfo)
predicate_info_build :: (f: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache) -> *Predicate_Info {
    pi := New(Predicate_Info,, allocator = temp);
    pi.f = f;
    pi.infos.allocator = temp; pi.map.allocator = temp;
    b: Pi_Builder;
    b.pi = pi; b.dt = dt;
    b.value_infos.allocator = temp; b.value_info_nums.allocator = temp;
    empty: [..] s32;
    array_add(*b.value_infos, empty);
    dt_update_dfs_numbers(dt);
    ops: [..] Value_Id; ops.allocator = temp;
    for bb: fn_blocks(f) {
        if !dt_is_reachable_from_entry(dt, bb) continue;
        t := block_terminator(bb);
        if t == NONE continue;
        if inst_op(t) == .CONDBR {
            if get_successor(t, 0) == get_successor(t, 1) continue;
            pi_process_branch(*b, t, bb, *ops);
        } else if inst_op(t) == .SWITCH {
            pi_process_switch(*b, t, bb, *ops);
        }
    }
    for a: ac_assumptions(ac).* {
        if a == NONE || vkind(a) == .DEAD continue;
        if dt_is_reachable_from_entry(dt, inst_block(a)) pi_process_assume(*b, a, *ops);
    }
    pi_rename_uses(*b, ops);
    return pi;
}

// PredicateBase::getConstraint
pi_get_constraint :: (p: *Pred_Info) -> Pred_Constraint {
    r: Pred_Constraint;
    if p.kind == .BUNDLE_ASSUME {
        r.ok = true; r.pred = ICMP_NE; r.other = const_null(vtype(p.original_op));
        return r;
    }
    if p.kind == .SWITCH {
        if p.condition != p.renamed_op return r;
        r.ok = true; r.pred = ICMP_EQ; r.other = p.case_value;
        return r;
    }
    true_edge := ifx p.kind == .BRANCH then p.true_edge else true;
    c := p.condition;
    if c == p.renamed_op {
        r.ok = true; r.pred = ICMP_EQ; r.other = const_int(vtype(c), ifx true_edge then cast(u64) 1 else 0);
        return r;
    }
    ok, x := pi_match_nuw_trunc(c);
    if ok && x == p.renamed_op {
        r.ok = true; r.pred = cast(u8) ifx true_edge then ICMP_NE else ICMP_EQ; r.other = const_null_value(vtype(p.renamed_op));
        return r;
    }
    if !is_inst(c) || (inst_op(c) != .ICMP && inst_op(c) != .FCMP) return r;
    pred: u8; other: Value_Id;
    if op(c, 0) == p.renamed_op { pred = inst(c).pred; other = op(c, 1); }
    else if op(c, 1) == p.renamed_op { pred = swapped_predicate(inst(c).pred); other = op(c, 0); }
    else return r;
    if !true_edge pred = cmp_inverse(pred);
    r.ok = true; r.pred = pred; r.other = other;
    return r;
}

// ---------------------------------------------------------------- print<predicate-info>

pi_print_ctx: struct { pi: *Predicate_Info; };

// PredicateInfoAnnotatedWriter::emitInstructionAnnot
pi_annot_inst :: (i: Value_Id) {
    p := pi_info_for(pi_print_ctx.pi, i);
    if !p return;
    print_value :: (v: Value_Id) {   // OS << *V
        if is_inst(v) {
            if is_referencing_md_node(v) out(printer_isolated_inst_to_string(v));
            else print_instruction(v);
        } else write_operand(v, true);
    }
    if p.kind == .BRANCH {
        out("; branch predicate info { TrueEdge: "); out(ifx p.true_edge then "1" else "0");
        out(" Comparison:"); print_value(p.condition);
        out(" Edge: ["); write_operand(p.from, true); out(","); write_operand(p.to, true); out("]");
    } else if p.kind == .SWITCH {
        out("; switch predicate info { CaseValue: "); print_value(p.case_value);
        out(" Edge: ["); write_operand(p.from, true); out(","); write_operand(p.to, true); out("]");
    } else {
        out("; assume predicate info {");
        if p.kind == .BUNDLE_ASSUME out(" Attribute: nonnull");
        else { out(" Comparison:"); print_value(p.condition); }
    }
    out(", RenamedOp: "); write_operand(p.renamed_op, false); out(" }\n");
}

// PredicateInfoPrinterPass::run
print_predicate_info_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    write_string(tprint("PredicateInfo for function: %\n", vname(f)), to_standard_error = true);
    pi := predicate_info_build(f, dt, ac);
    if pi.map.count printer_note_ir_changed();
    pi_print_ctx.pi = pi;
    printer_begin_function(f);
    start := W.buf.count;
    print_annot_inst = pi_annot_inst;
    print_function(f);
    print_annot_inst = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    write_string(s, to_standard_error = true);
    // replaceCreatedSSACopys
    for bb: fn_blocks(f) {
        i := block(bb).first;
        while i != NONE {
            nx := inst(i).next;
            if pi_info_for(pi, i) { rauw_with_metadata(i, op(i, 0)); erase_inst_with_metadata(i); }
            i = nx;
        }
    }
    if pi.map.count printer_note_ir_changed();
    return PRESERVE_ALL;
}
