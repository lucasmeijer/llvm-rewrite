// SCCP and IPSCCP: ports of llvm/lib/Transforms/Scalar/SCCP.cpp (runSCCP, SCCPPass) and
// llvm/lib/Transforms/IPO/SCCP.cpp (runIPSCCP, findReturnsToZap, IPSCCPPass), with getExpressionForConstant
// (llvm/lib/Transforms/Utils/Local.cpp). The solver is sccp_solver.jai, function specialization
// function_specialization.jai.

ipsccp_opts: struct {
    funcspec_max_iters: s64 = 10;   // -funcspec-max-iters
};

// runSCCP
sccp_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    s := sccp_new();
    sc_add_predicate_info(s, f, dt, ac);
    if sc_can_track_returns_interprocedurally(f) sc_add_tracked_function(s, f);
    sc_mark_block_executable(s, fn_entry(f));
    na := glob(f).nargs;
    if na > 0 for k: 0..na - 1 sc_track_value_of_argument(s, fn_arg(f, k));
    resolved := true;
    while resolved {
        sc_solve(s);
        resolved = sc_resolved_undefs_in(s, f);
    }
    made := false;
    inserted: Table(Value_Id, bool); inserted.allocator = temp;
    to_erase: [..] Value_Id; to_erase.allocator = temp;
    for bb: fn_blocks(f) {
        if !sc_is_block_executable(s, bb) { array_add(*to_erase, bb); made = true; continue; }
        made |= sc_simplify_insts_in_block(s, bb, *inserted);
    }
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    for to_erase change_to_unreachable(block_first_non_phi(it), false, null, *dtu);
    new_unreachable: Value_Id = NONE;
    dtus := *Dtu.[*dtu];
    for bb: fn_blocks(f) made |= sc_remove_non_feasible_edges(s, bb, dtus, *new_unreachable);
    for to_erase if !block_has_address_taken(it) dtu_delete_bb(*dtu, it);
    sc_remove_ssa_copies(s, f);
    sc_infer_return_attributes(s);
    dtu_flush(*dtu);   // ~DomTreeUpdater
    if !made return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}


// findReturnsToZap
sc_find_returns_to_zap :: (s: *Sccp, f: Value_Id, out: *[..] Value_Id) {
    if !sc_is_argument_tracked_function(s, f) return;
    if sc_must_preserve_return(s, f) return;
    for bb: fn_blocks(f) {
        if block_terminating_must_tail_call(bb) != NONE return;
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .RET && !pm_undef_value(op(t, 0)) array_add(out, t);
    }
}

// getExpressionForConstant: NONE if there is none
sc_expression_for_constant :: (c: Value_Id, t: Type_Id) -> Md_Id {
    int_expr :: (c: Value_Id) -> Md_Id {
        a := const_ap(c);
        v: u64;
        if a.bits == 1 { if !ap_fits_u64(a) return NONE; v = ap_zext_value(a); }
        else { if ap_min_signed_bits(a) > 64 return NONE; v = cast,no_check(u64) ap_sext_value(a); }
        return diexpr_get(.[DW_OP_CONSTU, v, DW_OP_STACK_VALUE]);
    }
    k := vkind(c);
    if k == .C_INT && !is_vector_type(vtype(c)) return int_expr(c);
    if k == .C_FP && is_fp_type(t) && type_bits(t) <= 64 {
        w := const_fp_value(c);
        return diexpr_get(.[DW_OP_CONSTU, w[0], DW_OP_STACK_VALUE]);
    }
    if !is_ptr_type(t) return NONE;
    if k == .C_NULL return diexpr_get(.[DW_OP_CONSTU, 0, DW_OP_STACK_VALUE]);
    if k == .C_EXPR && cexpr(c).op == .INTTOPTR {
        v := op(c, 0);
        if vkind(v) == .C_INT return int_expr(v);
    }
    return NONE;
}

// UpdateAttrs of the replaced-pointer-argument case
sc_update_mem_attrs :: (l: u32) -> u32 {
    me := attr_set_memory(attr_list_fn(l));
    if me == MEM_UNKNOWN return l;
    arg := mem_get(me, 0);
    me = mem_set(me, 2, mem_get(me, 2) | arg);
    me = mem_set(me, 3, mem_get(me, 3) | arg);
    a: Attr; a.kind = .Memory; a.ty = NONE; a.ival = me;
    return attr_list_with_fn(l, attr_set_with(attr_list_fn(l), a));
}

// attribute-list edits of the zapping step
al_remove_param_attr :: (l: u32, k: u32, kind: Attr_Kind) -> u32 {
    s := attr_list_param(l, k);
    if !attr_set_has(s, kind) return l;
    return attr_list_with_param(l, k, attr_set_remove(s, kind));
}
al_remove_ret_attrs :: (l: u32, kinds: [] Attr_Kind) -> u32 {
    r := attr_list_ret(l);
    nr := attr_set_remove_kinds(r, kinds);
    if nr == r return l;
    np := 0;
    if l != 0 np = ir.attr_lists[l].params.count;
    ps := NewArray(np, u32,, allocator = temp);
    for k: 0..np - 1 ps[k] = attr_list_param(l, cast(u32) k);
    return attr_list_get(attr_list_fn(l), nr, ps);
}

// runIPSCCP
ipsccp_run :: (name: string) -> Preserved {
    ipsccp_parse_params(name);
    s := sccp_new();
    for f: ir.m_functions {
        if is_declaration(f) continue;
        dt := get_domtree(f);
        ac := get_assumption_cache(f);
        sc_add_predicate_info(s, f, dt, ac);
        if sc_can_track_returns_interprocedurally(f) sc_add_tracked_function(s, f);
        if sc_can_track_arguments_interprocedurally(f) { sc_add_argument_tracked_function(s, f); continue; }
        sc_mark_block_executable(s, fn_entry(f));
        na := glob(f).nargs;
        if na > 0 for k: 0..na - 1 sc_track_value_of_argument(s, fn_arg(f, k));
    }
    for g: ir.m_globals {
        if vkind(g) != .GLOBAL_VAR continue;
        remove_dead_constant_users(g);
        if sc_can_track_global_variable_interprocedurally(g) sc_track_value_of_global_variable(s, g);
    }
    sc_solve_while_resolved_undefs_in_module(s);

    fs: Func_Spec;
    func_spec_enabled := ipsccp_func_spec_enabled();
    if func_spec_enabled {
        fs_init(*fs, s);
        iters := 0;
        while iters < ipsccp_opts.funcspec_max_iters {
            iters += 1;
            if !fs_run(*fs) break;
        }
    }

    made := false;
    fi := 0;
    while fi < ir.m_functions.count {
        f := ir.m_functions[fi];
        fi += 1;
        if is_declaration(f) continue;
        if func_spec_enabled && fs_is_dead_function(*fs, f) { made = true; continue; }
        to_erase: [..] Value_Id; to_erase.allocator = temp;
        if sc_is_block_executable(s, fn_entry(f)) {
            replaced_ptr_arg := false;
            na := glob(f).nargs;
            if na > 0 for k: 0..na - 1 {
                a := fn_arg(f, k);
                if has_uses(a) && sc_try_to_replace_with_constant(s, a) replaced_ptr_arg |= is_ptr_type(vtype(a));
            }
            if replaced_ptr_arg {
                glob(f).attrs = sc_update_mem_attrs(glob(f).attrs);
                u := ir.v_first_use[f];
                while u != NONE {
                    usr := ir.u_user[u];
                    u = ir.u_next[u];
                    if !is_inst(usr) || !is_call_base(usr) || call_called_function(usr) != f continue;
                    inst(usr).attrs = sc_update_mem_attrs(inst(usr).attrs);
                }
            }
            made |= replaced_ptr_arg;
        }
        inserted: Table(Value_Id, bool); inserted.allocator = temp;
        for bb: fn_blocks(f) {
            if !sc_is_block_executable(s, bb) {
                made = true;
                if bb != fn_entry(f) array_add(*to_erase, bb);
                continue;
            }
            made |= sc_simplify_insts_in_block(s, bb, *inserted);
        }
        // DomTreeUpdater(DT, PDT, Lazy) over the cached trees: one update list for both; the PDT only drops the
        // nodes of the deleted blocks
        dt_dtu: Dtu; pdt_dtu: Dtu;
        dt_dtu.dt = cached_domtree(f); dt_dtu.lazy = true;
        pdt_dtu.dt = cached_postdomtree(f); pdt_dtu.lazy = true;
        dt_dtu.pending.allocator = temp; dt_dtu.deleted.allocator = temp; dt_dtu.deleted_set.allocator = temp;
        pdt_dtu.pending.allocator = temp; pdt_dtu.deleted.allocator = temp; pdt_dtu.deleted_set.allocator = temp;
        dtus: [..] *Dtu; dtus.allocator = temp;
        array_add(*dtus, *dt_dtu);
        if pdt_dtu.dt array_add(*dtus, *pdt_dtu);
        for to_erase sc_change_to_unreachable_dtus(block_first_non_phi(it), dtus);
        if !sc_is_block_executable(s, fn_entry(f)) sc_change_to_unreachable_dtus(block_first_non_phi(fn_entry(f)), dtus);
        new_unreachable: Value_Id = NONE;
        for bb: fn_blocks(f) made |= sc_remove_non_feasible_edges(s, bb, dtus, *new_unreachable);
        for to_erase if !block_has_address_taken(it) dtu_delete_bb(*dt_dtu, it);
        sc_remove_ssa_copies(s, f);
        // ~DomTreeUpdater: apply the updates to both trees, then erase the deleted blocks
        if pdt_dtu.dt {
            if pdt_dtu.pending.count { dt_apply_updates(pdt_dtu.dt, pdt_dtu.pending); pdt_dtu.pending.count = 0; }
            for dt_dtu.deleted if dt_node(pdt_dtu.dt, it) >= 0 dt_erase_node(pdt_dtu.dt, it);
        }
        dtu_flush(*dt_dtu);
    }

    zap: [..] Value_Id; zap.allocator = temp;
    sc_infer_return_attributes(s);
    sc_infer_arg_attributes(s);
    for s.tracked_ret_vals {
        rv := s.lat[it.lv];
        if sc_is_constant(rv) || vle_is_unknown_or_undef(rv) sc_find_returns_to_zap(s, it.f, *zap);
    }
    for f: s.mrv_functions_order {
        if sc_is_struct_lattice_constant(s, f, func_ret(glob(f).value_type)) sc_find_returns_to_zap(s, f, *zap);
    }
    zapped: [..] Value_Id; zapped.allocator = temp;
    for ri: zap {
        f := inst_fn(ri);
        set_op(ri, 0, const_poison(func_ret(glob(f).value_type)));
        if !block_set_contains(zapped, f) array_add(*zapped, f);
    }
    UB_IMPLYING :: Attr_Kind.[.NoUndef, .Dereferenceable, .DereferenceableOrNull];
    for f: zapped {
        na := glob(f).nargs;
        if na > 0 for k: 0..na - 1 glob(f).attrs = al_remove_param_attr(glob(f).attrs, k, .Returned);
        glob(f).attrs = al_remove_ret_attrs(glob(f).attrs, UB_IMPLYING);
        u := ir.v_first_use[f];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(usr) || !is_call_base(usr) continue;
            n := call_num_args(usr);
            if n > 0 for k: 0..n - 1 inst(usr).attrs = al_remove_param_attr(inst(usr).attrs, k, .Returned);
            inst(usr).attrs = al_remove_ret_attrs(inst(usr).attrs, UB_IMPLYING);
        }
    }
    for gv: s.tracked_globals_order {
        found, k := table_find(*s.tracked_globals, gv);
        if !found continue;
        if sc_is_overdefined(s.lat[k]) continue;
        while ir.v_first_use[gv] != NONE {
            usr := ir.u_user[ir.v_first_use[gv]];
            if !is_inst(usr) || (inst_op(usr) != .LOAD && inst_op(usr) != .STORE) fatal("ipsccp: internal: a tracked global has a user that is not a load or store");
            if inst_op(usr) == .LOAD && has_uses(usr) rauw_with_metadata(usr, const_poison(vtype(usr)));
            erase_inst_with_metadata(usr);
        }
        gves: [..] Md_Id; gves.allocator = temp;
        gv_get_debug_info(gv, *gves);
        if gves.count == 1 {
            e := sc_expression_for_constant(gv_initializer(gv), glob(gv).value_type);
            if e != NONE {
                r := ir.mds[gves[0]];
                old := ir.md_ops[r.ops + 1];
                if old != e md_handle_changed_operand(gves[0], 1, old, e);
            }
        }
        made = true;
        gv_erase_from_parent(gv);
    }
    if func_spec_enabled fs_finish(*fs);   // ~FunctionSpecializer
    if !made return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .POSTDOMTREE);
    return pa;
}

sc_change_to_unreachable_dtus :: (i: Value_Id, dtus: [] *Dtu) {
    if dtus.count == 1 { change_to_unreachable(i, false, null, dtus[0]); return; }
    // the same updates for both trees
    bb := inst_block(i);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    change_to_unreachable(i, false, null, dtus[0]);
    uniq: [..] Value_Id; uniq.allocator = temp;
    for succs if !block_set_contains(uniq, it) array_add(*uniq, it);
    ups: [..] Dom_Update; ups.allocator = temp;
    for uniq array_add(*ups, .{false, bb, it});
    for k: 1..dtus.count - 1 dtu_apply(dtus[k], ups);
}
