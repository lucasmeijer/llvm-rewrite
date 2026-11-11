// SCCPSolver: a port of llvm/lib/Transforms/Utils/SCCPSolver.cpp (SCCPInstVisitor, SCCPSolver, simplifyInstsInBlock,
// removeNonFeasibleEdges, inferReturnAttributes / inferArgAttributes) and llvm/lib/Analysis/ValueLatticeUtils.cpp.
// One solver (`Sccp`) per pass run; lattice values live in `lat` and the maps hold indices into it (LLVM's
// DenseMap references are re-fetched after every insertion in the same places). Containers follow LLVM's:
// InstWorkList is a SetVector (pop from the back), BBWorkList a vector, TrackedRetVals / TrackedMultipleRetVals
// MapVectors (insertion order), AdditionalUsers a SetVector per value.

SCCP_MAX_NUM_RANGE_EXTENSIONS :: 10;

Sccp_Ret :: struct { f: Value_Id; lv: s32; }
Sccp_Mrv :: struct { f: Value_Id; i: u32; lv: s32; }

Sccp :: struct {
    lat: [..] Vle;
    value_state: Table(Value_Id, s32);
    struct_state: Table(u64, s32);
    tracked_globals: Table(Value_Id, s32);
    tracked_globals_order: [..] Value_Id;   // DenseMap iteration in the IPSCCP driver (order-insensitive there)
    tracked_ret_vals: [..] Sccp_Ret;        // MapVector
    tracked_ret_index: Table(Value_Id, s32);
    tracked_mrv: [..] Sccp_Mrv;
    tracked_mrv_index: Table(u64, s32);
    invalidated: Table(Value_Id, bool);
    invalidated_order: [..] Value_Id;
    mrv_functions: Table(Value_Id, bool);
    mrv_functions_order: [..] Value_Id;
    must_preserve_returns: Table(Value_Id, bool);
    tracking_incoming_args: Table(Value_Id, bool);
    tracking_incoming_args_order: [..] Value_Id;
    bb_executable: Table(Value_Id, bool);
    bb_visited: Table(Value_Id, bool);
    inst_work: [..] Value_Id;
    inst_work_in: Table(Value_Id, bool);
    cur_i: Value_Id = NONE;
    bb_work: [..] Value_Id;
    feasible_edges: Table(u64, bool);
    pred_info: Table(Value_Id, *Predicate_Info);
    additional_users: Table(Value_Id, s32);
    additional_lists: [..] [..] Value_Id;
}

sccp_new :: () -> *Sccp {
    s := New(Sccp,, allocator = temp);
    s.lat.allocator = temp; s.value_state.allocator = temp; s.struct_state.allocator = temp;
    s.tracked_globals.allocator = temp; s.tracked_globals_order.allocator = temp;
    s.tracked_ret_vals.allocator = temp; s.tracked_ret_index.allocator = temp;
    s.tracked_mrv.allocator = temp; s.tracked_mrv_index.allocator = temp;
    s.invalidated.allocator = temp; s.invalidated_order.allocator = temp;
    s.mrv_functions.allocator = temp; s.mrv_functions_order.allocator = temp;
    s.must_preserve_returns.allocator = temp;
    s.tracking_incoming_args.allocator = temp; s.tracking_incoming_args_order.allocator = temp;
    s.bb_executable.allocator = temp; s.bb_visited.allocator = temp;
    s.inst_work.allocator = temp; s.inst_work_in.allocator = temp;
    s.bb_work.allocator = temp; s.feasible_edges.allocator = temp;
    s.pred_info.allocator = temp; s.additional_users.allocator = temp; s.additional_lists.allocator = temp;
    return s;
}

sc_max_widen_opts :: () -> Vle_Merge_Options { o: Vle_Merge_Options; o.check_widen = true; o.max_widen_steps = SCCP_MAX_NUM_RANGE_EXTENSIONS; return o; }
sc_is_struct :: inline (t: Type_Id) -> bool { return type_kind(t) == .STRUCT; }
sc_key2 :: inline (v: Value_Id, i: u32) -> u64 { return ((cast(u64) v) << 32) | cast(u64) i; }
sc_lv :: inline (s: *Sccp, idx: s32) -> *Vle { return *s.lat[idx]; }
sc_new_lv :: (s: *Sccp) -> s32 { v: Vle; array_add(*s.lat, v); return cast(s32) (s.lat.count - 1); }

// SCCPSolver::isConstant / isOverdefined
sc_is_constant :: (lv: Vle) -> bool { return lv.tag == .CONSTANT || (vle_is_constant_range(lv) && cr_is_single_element(lv.r)); }
sc_is_overdefined :: (lv: Vle) -> bool { return !vle_is_unknown_or_undef(lv) && !sc_is_constant(lv); }

// ValueState[V]
sc_vs :: (s: *Sccp, v: Value_Id) -> s32 {
    found, k := table_find(*s.value_state, v);
    if found return k;
    k = sc_new_lv(s);
    table_set(*s.value_state, v, k);
    return k;
}
// getValueState(V)
sc_gvs :: (s: *Sccp, v: Value_Id) -> s32 {
    found, k := table_find(*s.value_state, v);
    if found return k;
    k = sc_new_lv(s);
    table_set(*s.value_state, v, k);
    if is_constant_kind(vkind(v)) vle_mark_constant(sc_lv(s, k), v);
    return k;
}
// StructValueState[{V, i}]
sc_svs :: (s: *Sccp, v: Value_Id, i: u32) -> s32 {
    key := sc_key2(v, i);
    found, k := table_find(*s.struct_state, key);
    if found return k;
    k = sc_new_lv(s);
    table_set(*s.struct_state, key, k);
    return k;
}
// getStructValueState(V, i)
sc_gsvs :: (s: *Sccp, v: Value_Id, i: u32) -> s32 {
    key := sc_key2(v, i);
    found, k := table_find(*s.struct_state, key);
    if found return k;
    k = sc_new_lv(s);
    table_set(*s.struct_state, key, k);
    if is_constant_kind(vkind(v)) {
        elt := cf_elt(v, i);
        if elt == NONE vle_mark_overdefined(sc_lv(s, k));
        else vle_mark_constant(sc_lv(s, k), elt);
    }
    return k;
}
sc_mrv_slot :: (s: *Sccp, f: Value_Id, i: u32) -> s32 {
    key := sc_key2(f, i);
    found, k := table_find(*s.tracked_mrv_index, key);
    if found return s.tracked_mrv[k].lv;
    lv := sc_new_lv(s);
    table_set(*s.tracked_mrv_index, key, cast(s32) s.tracked_mrv.count);
    array_add(*s.tracked_mrv, .{f, i, lv});
    return lv;
}
sc_ret_slot :: (s: *Sccp, f: Value_Id) -> s32 {
    found, k := table_find(*s.tracked_ret_index, f);
    if found return s.tracked_ret_vals[k].lv;
    return -1;
}

// ---------------------------------------------------------------- worklists

sc_push_to_work_list :: (s: *Sccp, i: Value_Id) {
    if s.cur_i != NONE && inst_block(i) == inst_block(s.cur_i) && comes_before(s.cur_i, i) return;
    if table_contains(*s.bb_visited, inst_block(i)) && !table_contains(*s.inst_work_in, i) {
        array_add(*s.inst_work, i);
        table_set(*s.inst_work_in, i, true);
    }
}
sc_push_users_to_work_list :: (s: *Sccp, v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) sc_push_to_work_list(s, usr);
        u = ir.u_next[u];
    }
    found, k := table_find(*s.additional_users, v);
    if found {
        to_notify: [..] Value_Id; to_notify.allocator = temp;
        for s.additional_lists[k] if is_inst(it) array_add(*to_notify, it);
        for to_notify sc_push_to_work_list(s, it);
    }
}
sc_add_additional_user :: (s: *Sccp, v: Value_Id, u: Value_Id) {
    found, k := table_find(*s.additional_users, v);
    if !found {
        k = cast(s32) s.additional_lists.count;
        l: [..] Value_Id; l.allocator = temp;
        array_add(*s.additional_lists, l);
        table_set(*s.additional_users, v, k);
    }
    for s.additional_lists[k] if it == u return;
    array_add(*s.additional_lists[k], u);
}

sc_mark_constant :: (s: *Sccp, iv: s32, v: Value_Id, c: Value_Id, may_include_undef := false) -> bool {
    if !vle_mark_constant(sc_lv(s, iv), c, may_include_undef) return false;
    sc_push_users_to_work_list(s, v);
    return true;
}
sc_mark_not_constant :: (s: *Sccp, iv: s32, v: Value_Id, c: Value_Id) -> bool {
    if !vle_mark_not_constant(sc_lv(s, iv), c) return false;
    sc_push_users_to_work_list(s, v);
    return true;
}
sc_mark_not_null :: (s: *Sccp, iv: s32, v: Value_Id) -> bool { return sc_mark_not_constant(s, iv, v, const_null_value(vtype(v))); }
sc_mark_overdefined_lv :: (s: *Sccp, iv: s32, v: Value_Id) -> bool {
    if !vle_mark_overdefined(sc_lv(s, iv)) return false;
    sc_push_users_to_work_list(s, v);
    return true;
}
// markOverdefined(Value *V)
sc_mark_overdefined :: (s: *Sccp, v: Value_Id) {
    t := vtype(v);
    if sc_is_struct(t) {
        n := type_nsub(t);
        if n > 0 for i: 0..n - 1 sc_mark_overdefined_lv(s, sc_gsvs(s, v, i), v);
    } else {
        sc_mark_overdefined_lv(s, sc_vs(s, v), v);
    }
}
sc_merge_in_value :: (s: *Sccp, iv: s32, v: Value_Id, with: Vle, o: Vle_Merge_Options = .{}) -> bool {
    if vle_merge_in(sc_lv(s, iv), with, o) {
        sc_push_users_to_work_list(s, v);
        return true;
    }
    return false;
}

sc_mark_block_executable :: (s: *Sccp, bb: Value_Id) -> bool {
    if table_contains(*s.bb_executable, bb) return false;
    table_set(*s.bb_executable, bb, true);
    array_add(*s.bb_work, bb);
    return true;
}
sc_is_block_executable :: (s: *Sccp, bb: Value_Id) -> bool { return table_contains(*s.bb_executable, bb); }
sc_mark_edge_executable :: (s: *Sccp, src: Value_Id, dst: Value_Id) -> bool {
    key := sc_key2(src, dst);
    if table_contains(*s.feasible_edges, key) return false;
    table_set(*s.feasible_edges, key, true);
    if !sc_mark_block_executable(s, dst) {
        for p: block_insts(dst) {
            if inst_op(p) != .PHI break;
            sc_push_to_work_list(s, p);
        }
    }
    return true;
}
sc_is_edge_feasible :: (s: *Sccp, from: Value_Id, to: Value_Id) -> bool { return table_contains(*s.feasible_edges, sc_key2(from, to)); }

// ---------------------------------------------------------------- constants

// getConstant(LV, Ty)
sc_get_constant :: (lv: Vle, t: Type_Id) -> Value_Id {
    if lv.tag == .CONSTANT return lv.c;
    if vle_is_constant_range(lv) {
        ok, e := cr_single_element(lv.r);
        if ok return cf_int(t, e);
    }
    return NONE;
}
sc_get_constant_int :: (lv: Vle, t: Type_Id) -> Value_Id {
    c := sc_get_constant(lv, t);
    if isa_constant_int(c) return c;
    return NONE;
}
// getLatticeValueFor
sc_lattice_value_for :: (s: *Sccp, v: Value_Id) -> Vle {
    found, k := table_find(*s.value_state, v);
    if !found fatal("sccp: internal: no lattice value for a value");
    return s.lat[k];
}
// getStructLatticeValueFor
sc_struct_lattice_value_for :: (s: *Sccp, v: Value_Id) -> [] Vle {
    t := vtype(v);
    n := type_nsub(t);
    r := NewArray(n, Vle,, allocator = temp);
    for i: 0..cast(s64) n - 1 {
        found, k := table_find(*s.struct_state, sc_key2(v, cast(u32) i));
        if !found fatal("sccp: internal: no struct lattice value for a value");
        r[i] = s.lat[k];
    }
    return r;
}
// getConstantOrNull
sc_get_constant_or_null :: (s: *Sccp, v: Value_Id) -> Value_Id {
    t := vtype(v);
    if sc_is_struct(t) {
        lvs := sc_struct_lattice_value_for(s, v);
        for lvs if sc_is_overdefined(it) return NONE;
        vals := NewArray(lvs.count, Value_Id,, allocator = temp);
        for lvs {
            et := type_sub(t, cast(u32) it_index);
            vals[it_index] = ifx sc_is_constant(it) then sc_get_constant(it, et) else const_undef(et);
        }
        return const_aggregate(.C_STRUCT, t, vals);
    }
    lv := sc_lattice_value_for(s, v);
    if sc_is_overdefined(lv) return NONE;
    if sc_is_constant(lv) return sc_get_constant(lv, t);
    return const_undef(t);
}

// ---------------------------------------------------------------- tracking setup

sc_add_predicate_info :: (s: *Sccp, f: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache) {
    table_set(*s.pred_info, f, predicate_info_build(f, dt, ac));
}
sc_get_predicate_info_for :: (s: *Sccp, i: Value_Id) -> *Pred_Info {
    found, pi := table_find(*s.pred_info, inst_fn(i));
    if !found return null;
    return pi_info_for(pi, i);
}
// removeSSACopies
sc_remove_ssa_copies :: (s: *Sccp, f: Value_Id) {
    found, pi := table_find(*s.pred_info, f);
    if !found return;
    for bb: fn_blocks(f) {
        i := block(bb).first;
        while i != NONE {
            nx := inst(i).next;
            if inst_op(i) == .BITCAST && vtype(i) == vtype(op(i, 0)) && pi_info_for(pi, i) {
                rauw_with_metadata(i, op(i, 0));
                erase_inst_with_metadata(i);
            }
            i = nx;
        }
    }
}
sc_track_value_of_global_variable :: (s: *Sccp, gv: Value_Id) {
    if !is_single_value_type(glob(gv).value_type) return;
    found, k := table_find(*s.tracked_globals, gv);
    if !found {
        k = sc_new_lv(s);
        table_set(*s.tracked_globals, gv, k);
        array_add(*s.tracked_globals_order, gv);
    }
    vle_mark_constant(sc_lv(s, k), gv_initializer(gv));
}
sc_add_tracked_function :: (s: *Sccp, f: Value_Id) {
    rt := func_ret(glob(f).value_type);
    if sc_is_struct(rt) {
        if !table_contains(*s.mrv_functions, f) { table_set(*s.mrv_functions, f, true); array_add(*s.mrv_functions_order, f); }
        n := type_nsub(rt);
        if n > 0 for i: 0..n - 1 sc_mrv_slot(s, f, i);
    } else if rt != ir.t_void {
        if !table_contains(*s.tracked_ret_index, f) {
            table_set(*s.tracked_ret_index, f, cast(s32) s.tracked_ret_vals.count);
            array_add(*s.tracked_ret_vals, .{f, sc_new_lv(s)});
        }
    }
}
sc_add_to_must_preserve_returns :: (s: *Sccp, f: Value_Id) { table_set(*s.must_preserve_returns, f, true); }
sc_must_preserve_return :: (s: *Sccp, f: Value_Id) -> bool { return table_contains(*s.must_preserve_returns, f); }
sc_add_argument_tracked_function :: (s: *Sccp, f: Value_Id) {
    if table_contains(*s.tracking_incoming_args, f) return;
    table_set(*s.tracking_incoming_args, f, true);
    array_add(*s.tracking_incoming_args_order, f);
}
sc_is_argument_tracked_function :: (s: *Sccp, f: Value_Id) -> bool { return f != NONE && table_contains(*s.tracking_incoming_args, f); }

// getArgAttributeVL
sc_get_arg_attribute_vl :: (a: Value_Id) -> Vle {
    if is_int_or_int_vector(vtype(a)) {
        ok, r := arg_range(a);
        if ok return vle_get_range(r);
    }
    if arg_has_nonnull_attr(a) return vle_get_not(const_null_value(vtype(a)));
    return vle_get_overdefined();
}
sc_track_value_of_argument :: (s: *Sccp, a: Value_Id) {
    if sc_is_struct(vtype(a)) { sc_mark_overdefined(s, a); return; }
    sc_merge_in_value(s, sc_vs(s, a), a, sc_get_arg_attribute_vl(a));
}

// canTrackArgumentsInterprocedurally / canTrackReturnsInterprocedurally / canTrackGlobalVariableInterprocedurally
sc_can_track_arguments_interprocedurally :: (f: Value_Id) -> bool {
    return fn_has_exact_definition(f) && gv_has_local_linkage(f) && !fn_has_address_taken(f);
}
sc_can_track_returns_interprocedurally :: (f: Value_Id) -> bool {
    return fn_has_exact_definition(f) && !fn_has_fn_attr(f, .Naked);
}
sc_can_track_global_variable_interprocedurally :: (gv: Value_Id) -> bool {
    if glob(gv).is_const || !gv_has_local_linkage(gv) || !gv_has_definitive_initializer(gv) return false;
    u := ir.v_first_use[gv];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) return false;
        if inst_op(usr) == .STORE {
            if op(usr, 0) == gv || (inst(usr).flags & F_VOLATILE) != 0 || vtype(op(usr, 0)) != glob(gv).value_type return false;
            continue;
        }
        if inst_op(usr) == .LOAD {
            if (inst(usr).flags & F_VOLATILE) != 0 || vtype(usr) != glob(gv).value_type return false;
            continue;
        }
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- visitors

// getFeasibleSuccessors
sc_get_feasible_successors :: (s: *Sccp, ti: Value_Id, succs: *[..] bool) {
    n := num_successors(ti);
    array_resize(succs, n);
    for * succs.* it.* = false;
    o := inst_op(ti);
    if o == .BR { succs.*[0] = true; return; }
    if o == .CONDBR {
        c := op(ti, 0);
        bcv := s.lat[sc_gvs(s, c)];
        ci := sc_get_constant_int(bcv, vtype(c));
        if ci == NONE {
            if !vle_is_unknown_or_undef(bcv) { succs.*[0] = true; succs.*[1] = true; }
            return;
        }
        succs.*[ifx is_null_value(ci) then 1 else 0] = true;
        return;
    }
    // isSpecialTerminator
    if o == .CATCHSWITCH || o == .CATCHRET || o == .CLEANUPRET || o == .INVOKE || o == .RESUME || o == .CALLBR {
        for * succs.* it.* = true;
        return;
    }
    if o == .SWITCH {
        nc := sw_num_cases(ti);
        if nc == 0 { succs.*[0] = true; return; }
        c := sw_cond(ti);
        scv := s.lat[sc_gvs(s, c)];
        ci := sc_get_constant_int(scv, vtype(c));
        if ci != NONE {
            k := sw_find_case_value(ti, ci);
            succs.*[ifx k < 0 then 0 else k + 1] = true;
            return;
        }
        if vle_is_constant_range(scv, false) {
            reachable: u64 = 0;
            for k: 0..nc - 1 {
                if cr_contains(scv.r, const_ap(sw_case_value(ti, k))) { succs.*[k + 1] = true; reachable += 1; }
            }
            succs.*[0] = cr_is_size_larger_than(scv.r, reachable);
            return;
        }
        if !vle_is_unknown_or_undef(scv) for * succs.* it.* = true;
        return;
    }
    if o == .INDIRECTBR {
        a := op(ti, 0);
        iv := s.lat[sc_gvs(s, a)];
        addr := sc_get_constant(iv, vtype(a));
        if addr == NONE || vkind(addr) != .C_BLOCKADDR {
            if !vle_is_unknown_or_undef(iv) for * succs.* it.* = true;
            return;
        }
        t := op(addr, 1);
        for k: 0..n - 1 if get_successor(ti, k) == t { succs.*[k] = true; return; }
        return;
    }
    fatal("SCCP: Don't know how to handle this terminator!");
}

sc_visit_terminator :: (s: *Sccp, ti: Value_Id) {
    feasible: [..] bool; feasible.allocator = temp;
    sc_get_feasible_successors(s, ti, *feasible);
    bb := inst_block(ti);
    for feasible if it sc_mark_edge_executable(s, bb, get_successor(ti, cast(u32) it_index));
}

sc_is_inst_fully_overdefined :: (s: *Sccp, i: Value_Id) -> bool {
    t := vtype(i);
    if sc_is_struct(t) {
        n := type_nsub(t);
        if n > 0 for k: 0..n - 1 if !vle_is_overdefined(s.lat[sc_gsvs(s, i, k)]) return false;
        return true;
    }
    return vle_is_overdefined(s.lat[sc_gvs(s, i)]);
}

sc_visit_phi :: (s: *Sccp, pn: Value_Id) {
    n := nops(pn);
    if n > 64 { sc_mark_overdefined(s, pn); return; }
    if sc_is_inst_fully_overdefined(s, pn) return;
    feasible: [..] u32; feasible.allocator = temp;
    bb := inst_block(pn);
    if n > 0 for k: 0..n - 1 if sc_is_edge_feasible(s, phi_block(pn, k), bb) array_add(*feasible, k);
    o: Vle_Merge_Options; o.check_widen = true; o.max_widen_steps = cast(u32) feasible.count + 1;
    t := vtype(pn);
    if sc_is_struct(t) {
        ne := type_nsub(t);
        if ne > 0 for e: 0..ne - 1 {
            phi_state := s.lat[sc_gsvs(s, pn, e)];
            if vle_is_overdefined(phi_state) continue;
            for j: feasible {
                iv := s.lat[sc_gsvs(s, op(pn, j), e)];
                vle_merge_in(*phi_state, iv);
                if vle_is_overdefined(phi_state) break;
            }
            ref := sc_gsvs(s, pn, e);
            sc_merge_in_value(s, ref, pn, phi_state, o);
            r := sc_lv(s, ref);
            r.num_range_extensions = cast(u8) max(cast(u32) feasible.count, cast(u32) r.num_range_extensions);
        }
    } else {
        phi_state := s.lat[sc_gvs(s, pn)];
        for j: feasible {
            iv := s.lat[sc_gvs(s, op(pn, j))];
            vle_merge_in(*phi_state, iv);
            if vle_is_overdefined(phi_state) break;
        }
        ref := sc_vs(s, pn);
        sc_merge_in_value(s, ref, pn, phi_state, o);
        r := sc_lv(s, ref);
        r.num_range_extensions = cast(u8) max(cast(u32) feasible.count, cast(u32) r.num_range_extensions);
    }
}

sc_visit_return :: (s: *Sccp, i: Value_Id) {
    if nops(i) == 0 return;
    f := inst_fn(i);
    res := op(i, 0);
    if s.tracked_ret_vals.count && !sc_is_struct(vtype(res)) {
        k := sc_ret_slot(s, f);
        if k >= 0 {
            sc_merge_in_value(s, k, f, s.lat[sc_gvs(s, res)]);
            return;
        }
    }
    if s.tracked_mrv.count {
        t := vtype(res);
        if sc_is_struct(t) && table_contains(*s.mrv_functions, f) {
            n := type_nsub(t);
            if n > 0 for e: 0..n - 1 {
                slot := sc_mrv_slot(s, f, e);
                sc_merge_in_value(s, slot, f, s.lat[sc_gsvs(s, res, e)]);
            }
        }
    }
}

sc_visit_cast :: (s: *Sccp, i: Value_Id) {
    if vle_is_overdefined(s.lat[sc_vs(s, i)]) return;
    if inst_op(i) == .BITCAST && vtype(i) == vtype(op(i, 0)) {
        pi := sc_get_predicate_info_for(s, i);
        if pi { sc_handle_predicate(s, i, op(i, 0), pi); return; }
    }
    src := op(i, 0);
    op_st := s.lat[sc_gvs(s, src)];
    if vle_is_unknown_or_undef(op_st) return;
    opc := sc_get_constant(op_st, vtype(src));
    if opc != NONE {
        c := cfo_cast_operand(inst_op(i), opc, vtype(i));
        if c != NONE {
            sc_merge_in_value(s, sc_vs(s, i), i, vle_get(c));
            return;
        }
    }
    dt := vtype(i); st := vtype(src);
    if is_int_or_int_vector(dt) && is_int_or_int_vector(st) && inst_op(i) != .BITCAST {
        op_range := vle_as_constant_range(op_st, st, false);
        lv := sc_gvs(s, i);
        bits := type_bits(scalar_type(dt));
        res: Const_Range;
        if inst_op(i) == .TRUNC res = cr_truncate(op_range, bits, (inst(i).flags & F_NUW) != 0);
        else res = cr_cast_op(op_range, inst_op(i), bits);
        sc_merge_in_value(s, lv, i, vle_get_range(res));
    } else {
        sc_mark_overdefined(s, i);
    }
}

sc_handle_extract_of_with_overflow :: (s: *Sccp, evi: Value_Id, wo: Value_Id, idx: u32) {
    lhs := call_arg(wo, 0); rhs := call_arg(wo, 1);
    t := vtype(lhs);
    sc_add_additional_user(s, lhs, evi);
    sc_add_additional_user(s, rhs, evi);
    l := s.lat[sc_gvs(s, lhs)];
    if vle_is_unknown_or_undef(l) return;
    lr := vle_as_constant_range(l, t, false);
    r := s.lat[sc_gvs(s, rhs)];
    if vle_is_unknown_or_undef(r) return;
    rr := vle_as_constant_range(r, t, false);
    id := call_iid(wo);
    if idx == 0 {
        res := cr_binary_op(lr, wo_binary_op(id), rr);
        sc_merge_in_value(s, sc_vs(s, evi), evi, vle_get_range(res));
    } else {
        nw := cr_guaranteed_no_wrap_region(wo_binary_op(id), rr, !wo_is_signed(id));
        if cr_contains_range(nw, lr) { sc_mark_constant(s, sc_vs(s, evi), evi, const_int(vtype(evi), 0)); return; }
        sc_mark_overdefined(s, evi);
    }
}

sc_visit_extract_value :: (s: *Sccp, evi: Value_Id) {
    if sc_is_struct(vtype(evi)) { sc_mark_overdefined(s, evi); return; }
    if vle_is_overdefined(s.lat[sc_vs(s, evi)]) { sc_mark_overdefined(s, evi); return; }
    if inst(evi).nidx != 1 { sc_mark_overdefined(s, evi); return; }
    agg := op(evi, 0);
    if sc_is_struct(vtype(agg)) {
        i := ir.u32_pool[inst(evi).idx];
        if is_with_overflow_inst(agg) { sc_handle_extract_of_with_overflow(s, evi, agg, i); return; }
        elt := s.lat[sc_gsvs(s, agg, i)];
        sc_merge_in_value(s, sc_vs(s, evi), evi, elt);
    } else {
        sc_mark_overdefined(s, evi);
    }
}

sc_visit_insert_value :: (s: *Sccp, ivi: Value_Id) {
    t := vtype(ivi);
    if !sc_is_struct(t) { sc_mark_overdefined(s, ivi); return; }
    if vle_is_overdefined(s.lat[sc_vs(s, ivi)]) { sc_mark_overdefined(s, ivi); return; }
    if inst(ivi).nidx != 1 { sc_mark_overdefined(s, ivi); return; }
    aggr := op(ivi, 0);
    idx := ir.u32_pool[inst(ivi).idx];
    n := type_nsub(t);
    if n > 0 for i: 0..n - 1 {
        if i != idx {
            elt := s.lat[sc_gsvs(s, aggr, i)];
            sc_merge_in_value(s, sc_gsvs(s, ivi, i), ivi, elt);
            continue;
        }
        val := op(ivi, 1);
        if sc_is_struct(vtype(val)) sc_mark_overdefined_lv(s, sc_gsvs(s, ivi, i), ivi);
        else {
            inv := s.lat[sc_gvs(s, val)];
            sc_merge_in_value(s, sc_gsvs(s, ivi, i), ivi, inv);
        }
    }
}

sc_visit_select :: (s: *Sccp, i: Value_Id) {
    if sc_is_struct(vtype(i)) { sc_mark_overdefined(s, i); return; }
    if vle_is_overdefined(s.lat[sc_vs(s, i)]) { sc_mark_overdefined(s, i); return; }
    c := op(i, 0);
    cv := s.lat[sc_gvs(s, c)];
    if vle_is_unknown_or_undef(cv) return;
    ci := sc_get_constant_int(cv, vtype(c));
    if ci != NONE {
        opv := ifx is_null_value(ci) then op(i, 2) else op(i, 1);
        st := s.lat[sc_gvs(s, opv)];
        sc_merge_in_value(s, sc_vs(s, i), i, st);
        return;
    }
    tv := s.lat[sc_gvs(s, op(i, 1))];
    fv := s.lat[sc_gvs(s, op(i, 2))];
    k := sc_vs(s, i);
    changed := vle_merge_in(sc_lv(s, k), tv);
    changed |= vle_merge_in(sc_lv(s, k), fv);
    if changed sc_push_users_to_work_list(s, i);
}

sc_visit_unary :: (s: *Sccp, i: Value_Id) {
    v0 := s.lat[sc_gvs(s, op(i, 0))];
    k := sc_vs(s, i);
    if vle_is_overdefined(s.lat[k]) { sc_mark_overdefined(s, i); return; }
    if vle_is_unknown_or_undef(v0) return;
    if sc_is_constant(v0) {
        c := cfo_unary_op_operand(inst_op(i), sc_get_constant(v0, vtype(i)));
        if c != NONE { sc_mark_constant(s, k, i, c); return; }
    }
    sc_mark_overdefined(s, i);
}

sc_visit_freeze :: (s: *Sccp, i: Value_Id) {
    if sc_is_struct(vtype(i)) { sc_mark_overdefined(s, i); return; }
    v0 := s.lat[sc_gvs(s, op(i, 0))];
    k := sc_vs(s, i);
    if vle_is_overdefined(s.lat[k]) { sc_mark_overdefined(s, i); return; }
    if vle_is_unknown_or_undef(v0) return;
    if sc_is_constant(v0) {
        c := sc_get_constant(v0, vtype(i));
        if is_guaranteed_not_to_be_undef_or_poison(c) { sc_mark_constant(s, k, i, c); return; }
    }
    sc_mark_overdefined(s, i);
}

sc_visit_binary :: (s: *Sccp, i: Value_Id) {
    v1 := s.lat[sc_gvs(s, op(i, 0))];
    v2 := s.lat[sc_gvs(s, op(i, 1))];
    k := sc_vs(s, i);
    if vle_is_overdefined(s.lat[k]) return;
    if vle_is_unknown_or_undef(v1) || vle_is_unknown_or_undef(v2) return;
    if vle_is_overdefined(v1) && vle_is_overdefined(v2) { sc_mark_overdefined(s, i); return; }
    if v1.tag == .CONSTANT || v2.tag == .CONSTANT {
        a := ifx sc_is_constant(v1) then sc_get_constant(v1, vtype(op(i, 0))) else op(i, 0);
        b := ifx sc_is_constant(v2) then sc_get_constant(v2, vtype(op(i, 1))) else op(i, 1);
        q: Simplify_Query; q.cxt = i; q.have_tli = false;   // SimplifyQuery(DL, &I): no DT, AC, TLI
        r := simplify_binop(inst_op(i), a, b, q);
        if r != NONE && is_constant_kind(vkind(r)) {
            nv: Vle;
            vle_mark_constant(*nv, r, true);
            sc_merge_in_value(s, sc_vs(s, i), i, nv);
            return;
        }
    }
    t := vtype(i);
    if !is_int_or_int_vector(t) { sc_mark_overdefined(s, i); return; }
    ra := vle_as_constant_range(v1, t, false);
    rb := vle_as_constant_range(v2, t, false);
    o := inst_op(i);
    res: Const_Range;
    if o == .ADD || o == .SUB || o == .MUL || o == .SHL {
        nw: u32 = 0;
        if (inst(i).flags & F_NUW) != 0 nw |= NW_NUW;
        if (inst(i).flags & F_NSW) != 0 nw |= NW_NSW;
        res = cr_overflowing_binary_op(ra, o, rb, nw);
    } else {
        res = cr_binary_op(ra, o, rb);
    }
    sc_merge_in_value(s, sc_vs(s, i), i, vle_get_range(res));
}

sc_visit_cmp :: (s: *Sccp, i: Value_Id) {
    if vle_is_overdefined(s.lat[sc_vs(s, i)]) { sc_mark_overdefined(s, i); return; }
    v1 := s.lat[sc_gvs(s, op(i, 0))];
    v2 := s.lat[sc_gvs(s, op(i, 1))];
    c := vle_get_compare(v1, inst(i).pred, vtype(i), v2);
    if c != NONE {
        cv: Vle;
        vle_mark_constant(*cv, c);
        sc_merge_in_value(s, sc_vs(s, i), i, cv);
        return;
    }
    if (vle_is_unknown_or_undef(v1) || vle_is_unknown_or_undef(v2)) && !sc_is_constant(s.lat[sc_vs(s, i)]) return;
    sc_mark_overdefined(s, i);
}

sc_visit_gep :: (s: *Sccp, i: Value_Id) {
    if vle_is_overdefined(s.lat[sc_vs(s, i)]) { sc_mark_overdefined(s, i); return; }
    ptr_st := s.lat[sc_gvs(s, op(i, 0))];
    if vle_is_unknown_or_undef(ptr_st) return;
    if ptr_st.tag == .NOTCONSTANT && is_null_value(ptr_st.c) {
        fl := inst(i).flags;
        if (fl & F_GEP_NUW) != 0 || ((fl & F_INBOUNDS) != 0 && !null_pointer_is_defined(inst_fn(i), type_addrspace(vtype(i)))) {
            sc_mark_not_null(s, sc_vs(s, i), i);
            return;
        }
        sc_mark_overdefined(s, i);
        return;
    }
    n := nops(i);
    ops := NewArray(n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        st := s.lat[sc_gvs(s, o)];
        if vle_is_unknown_or_undef(st) return;
        c := sc_get_constant(st, vtype(o));
        if c != NONE { ops[k] = c; continue; }
        sc_mark_overdefined(s, i);
        return;
    }
    c := cfo_inst_operands(i, ops);
    if c != NONE sc_merge_in_value(s, sc_vs(s, i), i, vle_get(c));
    else sc_mark_overdefined(s, i);
}

sc_visit_alloca :: (s: *Sccp, i: Value_Id) {
    if !null_pointer_is_defined(inst_fn(i), type_addrspace(vtype(i))) { sc_mark_not_null(s, sc_vs(s, i), i); return; }
    sc_mark_overdefined(s, i);
}

sc_visit_store :: (s: *Sccp, si: Value_Id) {
    if sc_is_struct(vtype(op(si, 0))) return;
    gv := op(si, 1);
    if s.tracked_globals.count == 0 || vkind(gv) != .GLOBAL_VAR return;
    found, k := table_find(*s.tracked_globals, gv);
    if !found return;
    o: Vle_Merge_Options; o.check_widen = false;
    sc_merge_in_value(s, k, gv, s.lat[sc_gvs(s, op(si, 0))], o);
    if vle_is_overdefined(s.lat[k]) table_remove(*s.tracked_globals, gv);
}

// getValueFromMetadata
sc_get_value_from_metadata :: (i: Value_Id) -> Vle {
    t := vtype(i);
    if is_call_base(i) {
        if is_int_or_int_vector(t) {
            ok, r := call_range(i);
            if ok return vle_get_range(r);
        }
        if is_ptr_type(t) && call_is_return_non_null(i) return vle_get_not(const_null(t));
    }
    if is_int_or_int_vector(t) {
        m := get_metadata(i, md_kind_id("range"));
        if m != NONE return vle_get_range(cr_from_range_md(m));
    }
    if get_metadata(i, md_kind_id("nonnull")) != NONE return vle_get_not(const_null(t));
    return vle_get_overdefined();
}

sc_visit_load :: (s: *Sccp, i: Value_Id) {
    if sc_is_struct(vtype(i)) || (inst(i).flags & F_VOLATILE) != 0 { sc_mark_overdefined(s, i); return; }
    if vle_is_overdefined(s.lat[sc_vs(s, i)]) { sc_mark_overdefined(s, i); return; }
    p := op(i, 0);
    pv := s.lat[sc_gvs(s, p)];
    if vle_is_unknown_or_undef(pv) return;
    if sc_is_constant(pv) {
        ptr := sc_get_constant(pv, vtype(p));
        iv := sc_vs(s, i);
        if vkind(ptr) == .C_NULL {
            if null_pointer_is_defined(inst_fn(i), type_addrspace(vtype(p))) { sc_mark_overdefined_lv(s, iv, i); return; }
            return;
        }
        if vkind(ptr) == .GLOBAL_VAR && s.tracked_globals.count {
            found, k := table_find(*s.tracked_globals, ptr);
            if found {
                sc_merge_in_value(s, iv, i, s.lat[k], sc_max_widen_opts());
                return;
            }
        }
        c := cfo_load_from_const_ptr(ptr, vtype(i));
        if c != NONE { sc_mark_constant(s, iv, i, c); return; }
    }
    sc_merge_in_value(s, sc_vs(s, i), i, sc_get_value_from_metadata(i));
}

sc_visit_call_base :: (s: *Sccp, cb: Value_Id) {
    sc_handle_call_result(s, cb);
    sc_handle_call_arguments(s, cb);
}

sc_handle_call_overdefined :: (s: *Sccp, cb: Value_Id) {
    f := call_called_function(cb);
    t := vtype(cb);
    if t == ir.t_void return;
    if sc_is_struct(t) { sc_mark_overdefined(s, cb); return; }
    if f != NONE && is_declaration(f) && can_constant_fold_call_to(cb, f) {
        ops: [..] Value_Id; ops.allocator = temp;
        n := call_num_args(cb);
        if n > 0 for k: 0..n - 1 {
            a := call_arg(cb, k);
            at := vtype(a);
            if sc_is_struct(at) { sc_mark_overdefined(s, cb); return; }
            if at == ir.t_metadata continue;
            st := s.lat[sc_gvs(s, a)];
            if vle_is_unknown_or_undef(st) return;
            if sc_is_overdefined(st) { sc_mark_overdefined(s, cb); return; }
            array_add(*ops, sc_get_constant(st, at));
        }
        if sc_is_overdefined(s.lat[sc_gvs(s, cb)]) { sc_mark_overdefined(s, cb); return; }
        c := cfo_call(cb, f, ops);
        if c != NONE {
            sc_merge_in_value(s, sc_vs(s, cb), cb, vle_get(c));
            return;
        }
    }
    sc_merge_in_value(s, sc_vs(s, cb), cb, sc_get_value_from_metadata(cb));
}

sc_handle_call_arguments :: (s: *Sccp, cb: Value_Id) {
    f := call_called_function(cb);
    if !sc_is_argument_tracked_function(s, f) return;
    sc_mark_block_executable(s, fn_entry(f));
    na := glob(f).nargs;
    if na > 0 for k: 0..na - 1 {
        a := fn_arg(f, k);
        if arg_has_attr(a, .ByVal) && !mem_only_reads(fn_memory(f)) { sc_mark_overdefined(s, a); continue; }
        ca := call_arg(cb, k);
        at := vtype(a);
        if sc_is_struct(at) {
            n := type_nsub(at);
            if n > 0 for e: 0..n - 1 {
                cv := s.lat[sc_gsvs(s, ca, e)];
                sc_merge_in_value(s, sc_gsvs(s, a, e), a, cv, sc_max_widen_opts());
            }
        } else {
            cv := vle_intersect(s.lat[sc_gvs(s, ca)], sc_get_arg_attribute_vl(a));
            sc_merge_in_value(s, sc_vs(s, a), a, cv, sc_max_widen_opts());
        }
    }
}

sc_handle_predicate :: (s: *Sccp, i: Value_Id, copy_of: Value_Id, pi: *Pred_Info) {
    copy_of_val := s.lat[sc_gvs(s, copy_of)];
    c := pi_get_constraint(pi);
    if !c.ok { sc_merge_in_value(s, sc_vs(s, i), i, copy_of_val); return; }
    pred := c.pred;
    other := c.other;
    if vle_is_unknown(s.lat[sc_gvs(s, other)]) { sc_add_additional_user(s, other, i); return; }
    cond_val := s.lat[sc_gvs(s, other)];
    iv := sc_vs(s, i);
    if vle_is_constant_range(cond_val) || vle_is_constant_range(copy_of_val) {
        imposed := cr_full(cast(u32) dl_type_size_bits(vtype(copy_of)));
        if vle_is_constant_range(cond_val) imposed = cr_allowed_icmp_region(pred, cond_val.r);
        copy_of_cr := vle_as_constant_range(copy_of_val, vtype(copy_of), true);
        if cr_is_empty_set(copy_of_cr) copy_of_cr = cr_full(cr_bits(copy_of_cr));
        new_cr := cr_intersect(imposed, copy_of_cr);
        ok, _ := cr_single_missing_element(copy_of_cr);
        if !cr_contains_range(copy_of_cr, new_cr) && ok new_cr = copy_of_cr;
        sc_add_additional_user(s, other, i);
        sc_merge_in_value(s, iv, i, vle_get_range(new_cr, false));
        return;
    } else if pred == ICMP_EQ && (cond_val.tag == .CONSTANT || cond_val.tag == .NOTCONSTANT) {
        sc_add_additional_user(s, other, i);
        sc_merge_in_value(s, iv, i, cond_val);
        return;
    } else if pred == ICMP_NE && cond_val.tag == .CONSTANT {
        sc_add_additional_user(s, other, i);
        sc_merge_in_value(s, iv, i, vle_get_not(cond_val.c));
        return;
    }
    sc_merge_in_value(s, iv, i, copy_of_val);
}

sc_handle_call_result :: (s: *Sccp, cb: Value_Id) {
    f := call_called_function(cb);
    id := call_iid(cb);
    if id != NOT_INTRINSIC {
        if id == IID_VSCALE {
            bits := type_bits(scalar_type(vtype(cb)));
            sc_merge_in_value(s, sc_vs(s, cb), cb, vle_get_range(get_vscale_range(inst_fn(cb), bits)));
            return;
        }
        if iid_name(id) == "llvm.experimental.get.vector.length" {
            count_arg := call_arg(cb, 0); vf := call_arg(cb, 1);
            scalable := !is_null_value(call_arg(cb, 2));
            bw := max(type_bits(scalar_type(vtype(count_arg))), type_bits(scalar_type(vtype(vf))));
            count := cr_zero_extend(vle_as_constant_range(s.lat[sc_gvs(s, count_arg)], vtype(count_arg), false), bw);
            max_lanes := cr_zero_extend(vle_as_constant_range(s.lat[sc_gvs(s, vf)], vtype(vf), false), bw);
            if scalable max_lanes = cr_multiply(max_lanes, get_vscale_range(inst_fn(cb), bw));
            um := cr_umax(count); ul := cr_umax(max_lanes);
            mn := ifx ap_ult(um, ul) then um else ul;
            res := cr_non_empty(ap_zero(bw), ap_add_u64(mn, 1));
            if cr_icmp(count, ICMP_ULE, max_lanes) res = count;
            res = cr_truncate(res, type_bits(scalar_type(vtype(cb))));
            sc_merge_in_value(s, sc_vs(s, cb), cb, vle_get_range(res));
            return;
        }
        if cr_is_intrinsic_supported(id) {
            ranges: [..] Const_Range; ranges.allocator = temp;
            n := call_num_args(cb);
            if n > 0 for k: 0..n - 1 {
                a := call_arg(cb, k);
                st := s.lat[sc_gvs(s, a)];
                if vle_is_unknown_or_undef(st) return;
                array_add(*ranges, vle_as_constant_range(st, vtype(a), false));
            }
            res := cr_intrinsic(id, ranges);
            sc_merge_in_value(s, sc_vs(s, cb), cb, vle_get_range(res));
            return;
        }
    }
    if f == NONE || is_declaration(f) { sc_handle_call_overdefined(s, cb); return; }
    rt := func_ret(glob(f).value_type);
    if sc_is_struct(rt) {
        if !table_contains(*s.mrv_functions, f) { sc_handle_call_overdefined(s, cb); return; }
        n := type_nsub(rt);
        if n > 0 for e: 0..n - 1 {
            slot := sc_mrv_slot(s, f, e);
            sc_merge_in_value(s, sc_gsvs(s, cb, e), cb, s.lat[slot], sc_max_widen_opts());
        }
    } else {
        k := sc_ret_slot(s, f);
        if k < 0 { sc_handle_call_overdefined(s, cb); return; }
        sc_merge_in_value(s, sc_vs(s, cb), cb, s.lat[k], sc_max_widen_opts());
    }
}

// InstVisitor::visit
sc_visit :: (s: *Sccp, i: Value_Id) {
    o := inst_op(i);
    if is_cast_op(o) { sc_visit_cast(s, i); return; }
    if is_binary_op(o) { sc_visit_binary(s, i); return; }
    if o == {
        case .PHI; sc_visit_phi(s, i);
        case .RET; sc_visit_return(s, i);
        case .BR; #through;
        case .CONDBR; #through;
        case .SWITCH; #through;
        case .INDIRECTBR; #through;
        case .CLEANUPRET; #through;
        case .CATCHRET; sc_visit_terminator(s, i);
        case .CATCHSWITCH; sc_mark_overdefined(s, i); sc_visit_terminator(s, i);
        case .INVOKE; #through;
        case .CALLBR; sc_visit_call_base(s, i); sc_visit_terminator(s, i);
        case .CALL; sc_visit_call_base(s, i);
        case .RESUME; #through;
        case .UNREACHABLE; #through;
        case .FENCE;
        case .SELECT; sc_visit_select(s, i);
        case .FNEG; sc_visit_unary(s, i);
        case .FREEZE; sc_visit_freeze(s, i);
        case .ICMP; #through;
        case .FCMP; sc_visit_cmp(s, i);
        case .EXTRACTVALUE; sc_visit_extract_value(s, i);
        case .INSERTVALUE; sc_visit_insert_value(s, i);
        case .STORE; sc_visit_store(s, i);
        case .LOAD; sc_visit_load(s, i);
        case .GEP; sc_visit_gep(s, i);
        case .ALLOCA; sc_visit_alloca(s, i);
        case; sc_mark_overdefined(s, i);   // visitInstruction
    }
}

sc_solve :: (s: *Sccp) {
    while s.bb_work.count || s.inst_work.count {
        while s.inst_work.count {
            i := pop(*s.inst_work);
            table_remove(*s.inst_work_in, i);
            if table_contains(*s.invalidated, i) table_remove(*s.invalidated, i);
            sc_visit(s, i);
        }
        while s.bb_work.count {
            bb := pop(*s.bb_work);
            table_set(*s.bb_visited, bb, true);
            for i: block_insts(bb) {
                s.cur_i = i;
                sc_visit(s, i);
            }
            s.cur_i = NONE;
        }
    }
}

sc_resolved_undef :: (s: *Sccp, i: Value_Id) -> bool {
    t := vtype(i);
    if t == ir.t_void return false;
    if sc_is_struct(t) {
        if is_call_base(i) {
            f := call_called_function(i);
            if f != NONE && table_contains(*s.mrv_functions, f) return false;
        }
        if inst_op(i) == .EXTRACTVALUE || inst_op(i) == .INSERTVALUE return false;
        n := type_nsub(t);
        if n > 0 for e: 0..n - 1 {
            k := sc_gsvs(s, i, e);
            if vle_is_unknown(s.lat[k]) { sc_mark_overdefined_lv(s, k, i); return true; }
        }
        return false;
    }
    k := sc_gvs(s, i);
    if !vle_is_unknown(s.lat[k]) return false;
    if is_call_base(i) {
        f := call_called_function(i);
        if f != NONE && table_contains(*s.tracked_ret_index, f) return false;
    }
    if inst_op(i) == .LOAD return false;
    sc_mark_overdefined(s, i);
    return true;
}

sc_resolved_undefs_in :: (s: *Sccp, f: Value_Id) -> bool {
    made := false;
    for bb: fn_blocks(f) {
        if !table_contains(*s.bb_executable, bb) continue;
        for i: block_insts(bb) made |= sc_resolved_undef(s, i);
    }
    return made;
}

sc_solve_while_resolved_undefs_in_module :: (s: *Sccp) {
    resolved := true;
    while resolved {
        sc_solve(s);
        resolved = false;
        for f: ir.m_functions resolved |= sc_resolved_undefs_in(s, f);
    }
}

// ---------------------------------------------------------------- SCCPSolver transformations

// tryToReplaceWithConstant
sc_try_to_replace_with_constant :: (s: *Sccp, v: Value_Id) -> bool {
    c := sc_get_constant_or_null(s, v);
    if c == NONE return false;
    if is_inst(v) && is_call_base(v) {
        if (call_is_must_tail(v) && !would_instruction_be_trivially_dead(v, false)) || call_has_bundle(v, "clang.arc.attachedcall") {
            f := call_called_function(v);
            if f != NONE sc_add_to_must_preserve_returns(s, f);
            return false;
        }
    }
    rauw_with_metadata(v, c);
    return true;
}


// propagateImplicitRefFromCall
sc_propagate_implicit_ref_from_call :: (cb: Value_Id) {
    callee := call_called_function(cb);
    if callee == NONE return;
    k := md_kind_id("implicit.ref");
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(callee, *all);
    caller := inst_fn(cb);
    for all if it.kind == k add_metadata(caller, k, it.md);
}

// getRange(Op, Solver, InsertedValues)
sc_get_range :: (s: *Sccp, o: Value_Id, inserted: *Table(Value_Id, bool)) -> Const_Range {
    if is_constant_kind(vkind(o)) return constant_to_range(o);
    if table_contains(inserted, o) return cr_full(type_bits(scalar_type(vtype(o))));
    return vle_as_constant_range(sc_lattice_value_for(s, o), vtype(o), false);
}

// refineInstruction
sc_refine_instruction :: (s: *Sccp, inserted: *Table(Value_Id, bool), i: Value_Id) -> bool {
    changed := false;
    o := inst_op(i);
    fl := inst(i).flags;
    if o == .ADD || o == .SUB || o == .MUL || o == .SHL {
        if (fl & F_NSW) != 0 && (fl & F_NUW) != 0 return false;
        ra := sc_get_range(s, op(i, 0), inserted);
        rb := sc_get_range(s, op(i, 1), inserted);
        if (fl & F_NUW) == 0 {
            nuw := cr_guaranteed_no_wrap_region(o, rb, true);
            if cr_contains_range(nuw, ra) { inst(i).flags |= F_NUW; changed = true; }
        }
        if (fl & F_NSW) == 0 {
            nsw := cr_guaranteed_no_wrap_region(o, rb, false);
            if cr_contains_range(nsw, ra) { inst(i).flags |= F_NSW; changed = true; }
        }
    } else if (o == .ZEXT || o == .UITOFP) && (fl & F_EXACT) == 0 {   // PossiblyNonNegInst; nneg is the F_EXACT bit
        r := sc_get_range(s, op(i, 0), inserted);
        if cr_is_all_non_negative(r) { inst(i).flags |= F_EXACT; changed = true; }
    } else if o == .TRUNC {
        if (fl & F_NSW) != 0 && (fl & F_NUW) != 0 return false;
        r := sc_get_range(s, op(i, 0), inserted);
        dw := type_bits(scalar_type(vtype(i)));
        if (fl & F_NUW) == 0 && cr_active_bits(r) <= dw { inst(i).flags |= F_NUW; changed = true; }
        if (fl & F_NSW) == 0 && cr_min_signed_bits(r) <= dw { inst(i).flags |= F_NSW; changed = true; }
    } else if o == .GEP {
        if (fl & F_GEP_NUW) != 0 || (fl & (F_NUSW | F_INBOUNDS)) == 0 return false;   // hasNoUnsignedSignedWrap: inbounds implies nusw
        n := nops(i);
        all := true;
        k: u32 = 1;
        while k < n { if !cr_is_all_non_negative(sc_get_range(s, op(i, k), inserted)) { all = false; break; } k += 1; }
        if all { inst(i).flags |= F_GEP_NUW; changed = true; }
    }
    return changed;
}

// replaceSignedInst
sc_replace_signed_inst :: (s: *Sccp, inserted: *Table(Value_Id, bool), i: Value_Id) -> bool {
    non_neg :: (s: *Sccp, inserted: *Table(Value_Id, bool), v: Value_Id) -> bool { return cr_is_all_non_negative(sc_get_range(s, v, inserted)); }
    o := inst_op(i);
    ni: Value_Id = NONE;
    if o == .SITOFP || o == .SEXT {
        o0 := op(i, 0);
        if !non_neg(s, inserted, o0) return false;
        ni = create_cast(ifx o == .SEXT then Opcode.ZEXT else .UITOFP, o0, vtype(i));
        insert_at_position(ni, inst_block(i), i, false);
        inst(ni).flags |= F_EXACT;   // nneg
    } else if o == .ASHR {
        o0 := op(i, 0);
        if !non_neg(s, inserted, o0) return false;
        ni = create_binop(.LSHR, o0, op(i, 1));
        insert_at_position(ni, inst_block(i), i, false);
        if (inst(i).flags & F_EXACT) != 0 inst(ni).flags |= F_EXACT;
    } else if o == .SDIV || o == .SREM {
        o0 := op(i, 0); o1 := op(i, 1);
        if !non_neg(s, inserted, o0) || !non_neg(s, inserted, o1) return false;
        ni = create_binop(ifx o == .SDIV then Opcode.UDIV else .UREM, o0, o1);
        insert_at_position(ni, inst_block(i), i, false);
        if o == .SDIV && (inst(i).flags & F_EXACT) != 0 inst(ni).flags |= F_EXACT;
    } else {
        return false;
    }
    take_name(ni, i);
    table_set(inserted, ni, true);
    rauw_with_metadata(i, ni);
    set_metadata(ni, 0, get_metadata(i, 0));
    table_remove(*s.value_state, i);
    erase_inst_with_metadata(i);
    return true;
}

// m_LowBitMask: (ok, mask) for a low-bit mask constant (splats too)
sc_match_low_bit_mask :: (c: Value_Id) -> (bool, APInt) {
    ok, a := pm_apint(c, true);   // api_pred_ty: splats with poison elements too
    if !ok { no: APInt; return false, no; }
    if ap_is_mask(a) return true, a;
    no: APInt;
    return false, no;
}

// simplifyInstruction (SCCPSolver.cpp)
sc_simplify_instruction :: (s: *Sccp, inserted: *Table(Value_Id, bool), i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == .AND {
        ok, m := sc_match_low_bit_mask(op(i, 1));
        if ok {
            x := op(i, 0);
            lr := sc_get_range(s, x, inserted);
            if ap_ule(cr_umax(lr), m) return x;
        }
    }
    id := call_iid(i);
    if id == IID_SCMP || id == IID_UCMP {
        lhs := op(i, 0); rhs := op(i, 1);
        bw := type_bits(scalar_type(vtype(lhs)));
        if bw == 1 return NONE;
        lr := sc_get_range(s, lhs, inserted);
        if cr_is_size_larger_than(lr, 3) return NONE;
        rr := sc_get_range(s, rhs, inserted);
        if cr_is_size_larger_than(rr, 3) return NONE;
        rhs_lower := cr_sub(rr, cr_single(ap_from_u64(bw, 1)));
        rhs_upper := cr_add(rr, cr_single(ap_from_u64(bw, 1)));
        pred := cast(u8) ifx id == IID_SCMP then ICMP_SLE else ICMP_ULE;
        if !cr_icmp(rhs_lower, pred, lr) || !cr_icmp(lr, pred, rhs_upper) return NONE;
        b: Irb;
        irb_set_at(*b, inst_block(i), i, false);
        sub := create_binop(.SUB, lhs, rhs);
        if id == IID_SCMP inst(sub).flags |= F_NSW;
        irb_insert(*b, sub, name_ref(vname(i)));
        table_set(inserted, sub, true);
        if vtype(sub) != vtype(i) {
            sb := type_bits(scalar_type(vtype(sub))); db := type_bits(scalar_type(vtype(i)));
            c := create_cast(ifx sb < db then Opcode.SEXT else .TRUNC, sub, vtype(i));
            irb_insert(*b, c);
            sub = c;
            table_set(inserted, sub, true);
        }
        return sub;
    }
    if o == .ICMP {
        x: Value_Id = NONE;
        ok, rhsc := pm_apint(op(i, 1));
        have_cr := false;
        cr: Const_Range;
        if ok {
            lhs := op(i, 0);
            pred := inst(i).pred;
            ok2, ax, offv := pm_add_like(lhs);
            ok3, offset := false, rhsc;
            if ok2 && has_one_use(lhs) { ok3, offset = pm_apint(offv); }
            if ok2 && ok3 && has_one_use(lhs) {
                x = ax;
                cr = cr_sub(cr_exact_icmp_region(pred, rhsc), cr_single(offset));
                have_cr = true;
            } else if icmp_is_equality(pred) && is_inst(lhs) && inst_op(lhs) == .AND && has_one_use(lhs) {
                okm, mask := pm_apint(op(lhs, 1), true);
                if okm && ap_is_negated_power_of_2(mask) && ap_ctz(rhsc) >= ap_ctz(mask) {
                    x = op(lhs, 0);
                    r := cr_new(rhsc, ap_sub(rhsc, mask));
                    cr = ifx pred == ICMP_EQ then r else cr_inverse(r);
                    have_cr = true;
                }
            }
        }
        if have_cr {
            lr := sc_get_range(s, x, inserted);
            if cr_is_full_set(lr) return NONE;
            convert :: (s: *Sccp, inserted: *Table(Value_Id, bool), i: Value_Id, x: Value_Id, ok: bool, ncr: Const_Range) -> Value_Id {
                if !ok return NONE;
                p, rhs, off := cr_equivalent_icmp(ncr);
                if !ap_is_zero(off) return NONE;
                b: Irb;
                irb_set_at(*b, inst_block(i), i, false);
                c := create_icmp(p, x, cf_int(vtype(x), rhs));
                irb_insert(*b, c);
                table_set(inserted, c, true);
                return c;
            }
            ok1, r1 := cr_exact_intersect(cr, lr);
            v := convert(s, inserted, i, x, ok1, r1);
            if v != NONE return v;
            ok2, r2 := cr_exact_union(cr, cr_inverse(lr));
            v = convert(s, inserted, i, x, ok2, r2);
            if v != NONE return v;
        }
    }
    return NONE;
}

// simplifyInstsInBlock
sc_simplify_insts_in_block :: (s: *Sccp, bb: Value_Id, inserted: *Table(Value_Id, bool)) -> bool {
    made := false;
    i := block(bb).first;
    while i != NONE {
        nx := inst(i).next;
        defer i = nx;
        if vtype(i) == ir.t_void continue;
        if sc_try_to_replace_with_constant(s, i) {
            if would_instruction_be_trivially_dead(i, false) {
                if is_call_base(i) sc_propagate_implicit_ref_from_call(i);
                erase_inst_with_metadata(i);
            }
            made = true;
        } else if sc_replace_signed_inst(s, inserted, i) {
            made = true;
        } else if sc_refine_instruction(s, inserted, i) {
            made = true;
        } else {
            v := sc_simplify_instruction(s, inserted, i);
            if v != NONE {
                rauw_with_metadata(i, v);
                erase_inst_with_metadata(i);
                made = true;
            }
        }
    }
    return made;
}

// removeNonFeasibleEdges
sc_remove_non_feasible_edges :: (s: *Sccp, bb: Value_Id, dtus: [] *Dtu, new_unreachable_bb: *Value_Id) -> bool {
    ti := block_terminator(bb);
    if ti == NONE return false;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    feasible: [..] Value_Id; feasible.allocator = temp;
    has_non_feasible := false;
    for succs {
        if sc_is_edge_feasible(s, bb, it) { if !block_set_contains(feasible, it) array_add(*feasible, it); }
        else has_non_feasible = true;
    }
    if !has_non_feasible return false;
    o := inst_op(ti);
    if o != .BR && o != .CONDBR && o != .SWITCH && o != .INDIRECTBR fatal("sccp: internal: a non-feasible edge from a terminator that is not br/switch/indirectbr");
    updates: [..] Dom_Update; updates.allocator = temp;
    if feasible.count == 0 {
        seen: [..] Value_Id; seen.allocator = temp;
        for succs {
            block_remove_predecessor(it, bb);
            if !block_set_contains(seen, it) { array_add(*seen, it); array_add(*updates, .{false, bb, it}); }
        }
        recs := inst(ti).records;
        inst(ti).records = 0;
        erase_inst_with_metadata(ti);
        ui := new_inst(.UNREACHABLE, ir.t_void, 0);
        block_append_inst(bb, ui);
        attach_records_before(ui, recs);   // the trailing records go to the new terminator
        for dtus dtu_apply_permissive(it, updates);
    } else if feasible.count == 1 {
        only := feasible[0];
        seen_only := false;
        for succs {
            if it == only && !seen_only { seen_only = true; continue; }
            block_remove_predecessor(it, bb);
            array_add(*updates, .{false, bb, it});
        }
        bi := create_br(only);
        block_append_inst(bb, bi);
        copy_debug_loc(bi, ti);
        erase_inst_with_metadata(ti);
        for dtus dtu_apply_permissive(it, updates);
    } else {
        if o != .SWITCH fatal("sccp: internal: several feasible successors of a non-switch terminator");
        p: Sw_Prof; p.w.allocator = temp;
        sw_prof_init(*p, ti);
        default_dest := sw_default(ti);
        if !block_set_contains(feasible, default_dest) {
            if new_unreachable_bb.* == NONE {
                nb := create_block(block_fn(bb), "default.unreachable", default_dest);
                ui := new_inst(.UNREACHABLE, ir.t_void, 0);
                block_append_inst(nb, ui);
                new_unreachable_bb.* = nb;
            }
            block_remove_predecessor(default_dest, bb);
            sw_set_default(ti, new_unreachable_bb.*);
            array_add(*updates, .{false, bb, default_dest});
            array_add(*updates, .{true, bb, new_unreachable_bb.*});
        }
        k: u32 = 0;
        while k < sw_num_cases(ti) {
            succ := sw_case_dest(ti, k);
            if block_set_contains(feasible, succ) { k += 1; continue; }
            block_remove_predecessor(succ, bb);
            array_add(*updates, .{false, bb, succ});
            sw_prof_remove_case(*p, k);
        }
        sw_prof_done(*p);
        for dtus dtu_apply_permissive(it, updates);
    }
    return true;
}

// inferAttribute
sc_infer_attribute :: (f: Value_Id, idx: s64, v: Vle) {   // idx: -1 = return, else the argument number
    if vle_is_constant_range(v) && !cr_is_single_element(v.r) {
        if vle_is_constant_range_including_undef(v) return;
        cr := v.r;
        old := sc_fn_attr_at(f, idx, .Range);
        if old cr = cr_intersect(cr, attr_range(old));
        a: Attr; a.kind = .Range; a.ty = NONE; a.ival = cr.lo.bits;
        lw := ap_words(cr.lo); hw := ap_words(cr.hi);
        a.lo = NewArray(lw.count, u64,, allocator = temp); for lw a.lo[it_index] = it;
        a.hi = NewArray(hw.count, u64,, allocator = temp); for hw a.hi[it_index] = it;
        sc_fn_add_attr_at(f, idx, a);
        return;
    }
    if v.tag == .NOTCONSTANT && is_ptr_type(vtype(v.c)) && is_null_value(v.c) && !sc_fn_attr_at(f, idx, .NonNull) {
        a: Attr; a.kind = .NonNull; a.ty = NONE;
        sc_fn_add_attr_at(f, idx, a);
    }
}
sc_fn_attr_at :: (f: Value_Id, idx: s64, k: Attr_Kind) -> *Attr {
    l := glob(f).attrs;
    s := ifx idx < 0 then attr_list_ret(l) else attr_list_param(l, cast(u32) idx);
    return attr_set_find(s, k);
}
sc_fn_add_attr_at :: (f: Value_Id, idx: s64, a: Attr) {
    l := glob(f).attrs;
    if idx < 0 {
        r := attr_set_with(attr_list_ret(l), a);
        np := cast(s64) glob(f).nargs;
        ps := NewArray(np, u32,, allocator = temp);
        for k: 0..np - 1 ps[k] = attr_list_param(l, cast(u32) k);
        glob(f).attrs = attr_list_get(attr_list_fn(l), r, ps);
    } else {
        glob(f).attrs = attr_list_with_param(l, cast(u32) idx, attr_set_with(attr_list_param(l, cast(u32) idx), a));
    }
}
sc_infer_return_attributes :: (s: *Sccp) {
    for s.tracked_ret_vals sc_infer_attribute(it.f, -1, s.lat[it.lv]);
}
sc_infer_arg_attributes :: (s: *Sccp) {
    for f: s.tracking_incoming_args_order {
        if !sc_is_block_executable(s, fn_entry(f)) continue;
        na := glob(f).nargs;
        if na > 0 for k: 0..na - 1 {
            a := fn_arg(f, k);
            if !sc_is_struct(vtype(a)) sc_infer_attribute(f, k, sc_lattice_value_for(s, a));
        }
    }
}

sc_is_struct_lattice_constant :: (s: *Sccp, f: Value_Id, t: Type_Id) -> bool {
    n := type_nsub(t);
    if n > 0 for i: 0..n - 1 if !sc_is_constant(s.lat[sc_mrv_slot(s, f, i)]) return false;
    return true;
}

// ---------------------------------------------------------------- function specialization support

// invalidate(Call): the call and its users (transitively) get an unknown lattice value
sc_invalidate :: (s: *Sccp, call: Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, call);
    while work.count {
        i := pop(*work);
        if table_contains(*s.invalidated, i) continue;
        table_set(*s.invalidated, i, true);
        array_add(*s.invalidated_order, i);
        if !table_contains(*s.bb_executable, inst_block(i)) continue;
        v: Value_Id = NONE;
        t := vtype(i);
        if inst_op(i) == .RET {
            f := inst_fn(i);
            k := sc_ret_slot(s, f);
            if k >= 0 { s.lat[k] = .{}; v = f; }
            else if table_contains(*s.mrv_functions, f) {
                rt := func_ret(glob(f).value_type);
                n := type_nsub(rt);
                if n > 0 for e: 0..n - 1 s.lat[sc_mrv_slot(s, f, e)] = .{};
                v = f;
            }
        } else if sc_is_struct(t) {
            n := type_nsub(t);
            if n > 0 for e: 0..n - 1 {
                found, k := table_find(*s.struct_state, sc_key2(i, e));
                if found { s.lat[k] = .{}; v = i; }
            }
        } else {
            found, k := table_find(*s.value_state, i);
            if found { s.lat[k] = .{}; v = i; }
        }
        if v != NONE {
            u := ir.v_first_use[v];
            while u != NONE {
                usr := ir.u_user[u];
                if is_inst(usr) array_add(*work, usr);
                u = ir.u_next[u];
            }
            found, k := table_find(*s.additional_users, v);
            if found for s.additional_lists[k] if is_inst(it) array_add(*work, it);
        }
    }
}
// resetLatticeValueFor(Call)
sc_reset_lattice_value_for :: (s: *Sccp, call: Value_Id) {
    sc_invalidate(s, call);
    sc_handle_call_result(s, call);
}
// setLatticeValueForSpecializationArguments
Fs_Arg :: struct { formal: Value_Id; actual: Value_Id; }
sc_set_lattice_value_for_specialization_arguments :: (s: *Sccp, f: Value_Id, args: [] Fs_Arg) {
    old_f := arg_parent(args[0].formal);
    it_k := 0;
    na := glob(f).nargs;
    if na > 0 for k: 0..na - 1 {
        new_arg := fn_arg(f, k); old_arg := fn_arg(old_f, k);
        t := vtype(new_arg);
        if it_k < args.count && args[it_k].formal == old_arg {
            if sc_is_struct(t) {
                n := type_nsub(t);
                if n > 0 for e: 0..n - 1 vle_mark_constant(sc_lv(s, sc_svs(s, new_arg, e)), cf_elt(args[it_k].actual, e));
            } else {
                vle_mark_constant(sc_lv(s, sc_vs(s, new_arg)), args[it_k].actual);
            }
            it_k += 1;
        } else {
            if sc_is_struct(t) {
                n := type_nsub(t);
                if n > 0 for e: 0..n - 1 { d := sc_svs(s, new_arg, e); src := sc_svs(s, old_arg, e); s.lat[d] = s.lat[src]; }
            } else {
                d := sc_vs(s, new_arg); src := sc_vs(s, old_arg); s.lat[d] = s.lat[src];
            }
        }
    }
}
sc_mark_function_unreachable :: (s: *Sccp, f: Value_Id) {
    for bb: fn_blocks(f) table_remove(*s.bb_executable, bb);
}
sc_solve_while_resolved_undefs_in_list :: (s: *Sccp, fns: [] Value_Id) {
    resolved := true;
    while resolved {
        sc_solve(s);
        resolved = false;
        for fns resolved |= sc_resolved_undefs_in(s, it);
    }
}
// solveWhileResolvedUndefs (Invalidated is a DenseSet; visited here in insertion order)
sc_solve_while_resolved_undefs :: (s: *Sccp) {
    resolved := true;
    while resolved {
        sc_solve(s);
        resolved = false;
        for s.invalidated_order {
            if !table_contains(*s.invalidated, it) continue;
            if is_inst(it) resolved |= sc_resolved_undef(s, it);
        }
    }
    table_reset(*s.invalidated);
    s.invalidated_order.count = 0;
}
