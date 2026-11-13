// CalledValuePropagation: port of llvm/lib/Transforms/IPO/CalledValuePropagation.cpp (CVPLatticeVal,
// CVPLatticeFunc, runCVP) with the SparseSolver of llvm/include/llvm/Analysis/SparsePropagation.h specialized to
// this lattice (it is the only user; no AbstractLatticeFunction interface), and canTrack*Interprocedurally from
// llvm/lib/Analysis/ValueLatticeUtils.cpp.
//
// Lattice keys are (value, grouping) packed in a u64. The solver's map iteration orders (SmallDenseMap of changed
// values, the IndirectCalls SmallPtrSet) only change the order of the worklists; every transfer function joins
// with the current state, so the fixpoint (and the !callees result) does not depend on them.

clv_cl: struct { max_functions_per_value: s64 = 4; };   // -cvp-max-functions-per-value

CLV_REGISTER :: 0; CLV_RETURN :: 1; CLV_MEMORY :: 2;
CLV_UNDEFINED :: 0; CLV_FUNCTION_SET :: 1; CLV_OVERDEFINED :: 2; CLV_UNTRACKED :: 3;

Clv_Val :: struct { state: u8; funcs: [] Value_Id; }   // funcs sorted by name

Clv :: struct {
    states: Table(u64, Clv_Val);
    bb_exec: Table(Value_Id, bool);
    feasible_edges: Table(u64, bool);
    bb_wl: [..] Value_Id;
    value_wl: [..] Value_Id;
    indirect_calls: [..] Value_Id;
    indirect_set: Table(Value_Id, bool);
}

clv_key :: inline (v: Value_Id, g: u64) -> u64 { return ((cast(u64) v) << 2) | g; }
clv_key_value :: inline (k: u64) -> Value_Id { return cast(Value_Id) (k >> 2); }
clv_key_group :: inline (k: u64) -> u64 { return k & 3; }

clv_eq :: (a: Clv_Val, b: Clv_Val) -> bool {
    if a.state != b.state || a.funcs.count != b.funcs.count return false;
    for a.funcs if it != b.funcs[it_index] return false;
    return true;
}
clv_simple :: (s: u8) -> Clv_Val { v: Clv_Val; v.state = s; return v; }

// canTrackArgumentsInterprocedurally / canTrackReturnsInterprocedurally / canTrackGlobalVariableInterprocedurally
clv_has_exact_definition :: (f: Value_Id) -> bool { return !is_declaration(f) && gv_is_definition_exact(f); }
clv_can_track_arguments :: (f: Value_Id) -> bool { return clv_has_exact_definition(f) && gv_has_local_linkage(f) && !fn_has_address_taken(f); }
clv_can_track_returns :: (f: Value_Id) -> bool { return clv_has_exact_definition(f) && !fn_has_fn_attr(f, .Naked); }
clv_can_track_global :: (gv: Value_Id) -> bool {
    if glob(gv).is_const || !gv_has_local_linkage(gv) || !gv_has_definitive_initializer(gv) return false;
    vt := glob(gv).value_type;
    u := ir.v_first_use[gv];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if is_inst(usr) && inst_op(usr) == .STORE {
            if op(usr, 0) == gv || is_volatile(usr) || vtype(op(usr, 0)) != vt return false;
            continue;
        }
        if is_inst(usr) && inst_op(usr) == .LOAD {
            if is_volatile(usr) || vtype(usr) != vt return false;
            continue;
        }
        return false;
    }
    return true;
}

clv_compute_constant :: (c: Value_Id) -> Clv_Val {
    if vkind(c) == .C_NULL && is_ptr_type(vtype(c)) return clv_simple(CLV_FUNCTION_SET);   // ConstantPointerNull
    f := strip_pointer_casts(c);
    if vkind(f) == .FUNCTION {
        v: Clv_Val; v.state = CLV_FUNCTION_SET;
        v.funcs = NewArray(1, Value_Id,, allocator = temp); v.funcs[0] = f;
        return v;
    }
    return clv_simple(CLV_OVERDEFINED);
}

clv_compute_lattice_val :: (k: u64) -> Clv_Val {
    v := clv_key_value(k);
    if clv_key_group(k) == CLV_REGISTER {
        if is_inst(v) return clv_simple(CLV_UNDEFINED);
        if vkind(v) == .ARGUMENT { if clv_can_track_arguments(arg_parent(v)) return clv_simple(CLV_UNDEFINED); }
        else if is_constant_kind(vkind(v)) return clv_compute_constant(v);
        return clv_simple(CLV_OVERDEFINED);
    }
    if vkind(v) == .GLOBAL_VAR {
        if clv_can_track_global(v) return clv_compute_constant(op(v, 0));
    } else if vkind(v) == .FUNCTION {
        if clv_can_track_returns(v) return clv_simple(CLV_UNDEFINED);
    }
    return clv_simple(CLV_OVERDEFINED);
}

clv_name_less :: (a: Value_Id, b: Value_Id) -> bool {
    x := vname(a); y := vname(b);
    n := min(x.count, y.count);
    for i: 0..n-1 if x[i] != y[i] return x[i] < y[i];
    return x.count < y.count;
}

clv_merge :: (x: Clv_Val, y: Clv_Val) -> Clv_Val {
    if x.state == CLV_OVERDEFINED || y.state == CLV_OVERDEFINED return clv_simple(CLV_OVERDEFINED);
    if x.state == CLV_UNDEFINED && y.state == CLV_UNDEFINED && x.funcs.count == 0 && y.funcs.count == 0 return clv_simple(CLV_UNDEFINED);
    // std::set_union by name
    u: [..] Value_Id; u.allocator = temp;
    i, j := 0;
    while i < x.funcs.count || j < y.funcs.count {
        if j >= y.funcs.count { array_add(*u, x.funcs[i]); i += 1; continue; }
        if i >= x.funcs.count { array_add(*u, y.funcs[j]); j += 1; continue; }
        a := x.funcs[i]; b := y.funcs[j];
        if clv_name_less(a, b) { array_add(*u, a); i += 1; }
        else if clv_name_less(b, a) { array_add(*u, b); j += 1; }
        else { array_add(*u, a); i += 1; j += 1; }
    }
    if u.count > clv_cl.max_functions_per_value return clv_simple(CLV_OVERDEFINED);
    r: Clv_Val; r.state = CLV_FUNCTION_SET; r.funcs = u;
    return r;
}

clv_get_state :: (s: *Clv, k: u64) -> Clv_Val {
    found, v := table_find(*s.states, k);
    if found return v;
    lv := clv_compute_lattice_val(k);
    if lv.state == CLV_UNTRACKED return lv;
    table_set(*s.states, k, lv);
    return lv;
}
clv_update_state :: (s: *Clv, k: u64, lv: Clv_Val) {
    found, old := table_find(*s.states, k);
    if found && clv_eq(old, lv) return;
    table_set(*s.states, k, lv);
    array_add(*s.value_wl, clv_key_value(k));
}
clv_mark_block_executable :: (s: *Clv, bb: Value_Id) {
    if table_contains(*s.bb_exec, bb) return;
    table_set(*s.bb_exec, bb, true);
    array_add(*s.bb_wl, bb);
}

// getFeasibleSuccessors (AggressiveUndef = true; GetValueFromLatticeVal returns nullptr)
clv_feasible_successors :: (s: *Clv, t: Value_Id, out: *[..] bool) {
    n := num_successors(t);
    out.count = 0;
    for 0..cast(s64) n - 1 array_add(out, false);
    if n == 0 return;
    o := inst_op(t);
    if o == .BR { out.*[0] = true; return; }
    if o == .CONDBR || o == .SWITCH {
        v := clv_get_state(s, clv_key(op(t, 0), CLV_REGISTER));
        if v.state == CLV_UNDEFINED && v.funcs.count == 0 return;
    }
    for * out.* it.* = true;
}

clv_is_edge_feasible :: (s: *Clv, from: Value_Id, to: Value_Id) -> bool {
    t := block_terminator(from);
    f: [..] bool; f.allocator = temp;
    clv_feasible_successors(s, t, *f);
    for k: 0..f.count - 1 if get_successor(t, cast(u32) k) == to && f[k] return true;
    return false;
}

clv_mark_edge_executable :: (s: *Clv, from: Value_Id, to: Value_Id) {
    ek := ((cast(u64) from) << 32) | cast(u64) to;
    if table_contains(*s.feasible_edges, ek) return;
    table_set(*s.feasible_edges, ek, true);
    if table_contains(*s.bb_exec, to) {
        for i: block_insts(to) { if inst_op(i) != .PHI break; clv_visit_phi(s, i); }
    } else clv_mark_block_executable(s, to);
}

clv_visit_phi :: (s: *Clv, pn: Value_Id) {
    k := clv_key(pn, CLV_REGISTER);
    v := clv_get_state(s, k);
    if v.state == CLV_OVERDEFINED || v.state == CLV_UNTRACKED return;
    if phi_num_incoming(pn) > 64 { clv_update_state(s, k, clv_simple(CLV_OVERDEFINED)); return; }
    for i: 0..cast(s64) phi_num_incoming(pn) - 1 {
        if !clv_is_edge_feasible(s, phi_block(pn, cast(u32) i), inst_block(pn)) continue;
        ov := clv_get_state(s, clv_key(phi_value(pn, cast(u32) i), CLV_REGISTER));
        if !clv_eq(ov, v) v = clv_merge(v, ov);
        if v.state == CLV_OVERDEFINED break;
    }
    clv_update_state(s, k, v);
}

// CVPLatticeFunc::ComputeInstructionState, then the solver's UpdateState of every changed value
clv_visit_inst :: (s: *Clv, i: Value_Id) {
    o := inst_op(i);
    if o == .PHI { clv_visit_phi(s, i); return; }
    ck: [..] u64; ck.allocator = temp;          // ChangedValues
    cv: [..] Clv_Val; cv.allocator = temp;
    set_changed :: (k: u64, v: Clv_Val) #expand {
        for ck if it == k { cv[it_index] = v; return; }
        array_add(*ck, k); array_add(*cv, v);
    }
    reg := clv_key(i, CLV_REGISTER);
    if o == .CALL || o == .INVOKE {
        f := call_called_function(i);
        if f == NONE && !table_contains(*s.indirect_set, i) { table_set(*s.indirect_set, i, true); array_add(*s.indirect_calls, i); }
        if f == NONE || !clv_can_track_returns(f) {
            if vtype(i) != ir.t_void set_changed(reg, clv_simple(CLV_OVERDEFINED));
        } else {
            clv_mark_block_executable(s, fn_entry(f));
            ret := clv_key(f, CLV_RETURN);
            for a: 0..cast(s64) fn_nargs(f) - 1 {
                formal := clv_key(fn_arg(f, cast(u32) a), CLV_REGISTER);
                actual := clv_key(op(i, cast(u32) a), CLV_REGISTER);
                set_changed(formal, clv_merge(clv_get_state(s, formal), clv_get_state(s, actual)));
            }
            if vtype(i) != ir.t_void set_changed(reg, clv_merge(clv_get_state(s, reg), clv_get_state(s, ret)));
        }
    } else if o == .LOAD {
        p := op(i, 0);
        if vkind(p) == .GLOBAL_VAR {
            mem := clv_key(p, CLV_MEMORY);
            set_changed(reg, clv_merge(clv_get_state(s, reg), clv_get_state(s, mem)));
        } else set_changed(reg, clv_simple(CLV_OVERDEFINED));
    } else if o == .RET {
        f := inst_fn(i);
        if func_ret(glob(f).value_type) != ir.t_void {
            ri := clv_key(op(i, 0), CLV_REGISTER);
            rf := clv_key(f, CLV_RETURN);
            set_changed(rf, clv_merge(clv_get_state(s, ri), clv_get_state(s, rf)));
        }
    } else if o == .SELECT {
        t := clv_key(op(i, 1), CLV_REGISTER);
        fv := clv_key(op(i, 2), CLV_REGISTER);
        set_changed(reg, clv_merge(clv_get_state(s, t), clv_get_state(s, fv)));
    } else if o == .STORE {
        p := op(i, 1);
        if vkind(p) == .GLOBAL_VAR {
            ri := clv_key(op(i, 0), CLV_REGISTER);
            mem := clv_key(p, CLV_MEMORY);
            set_changed(mem, clv_merge(clv_get_state(s, ri), clv_get_state(s, mem)));
        }
    } else {
        if has_uses(i) set_changed(reg, clv_simple(CLV_OVERDEFINED));
    }
    for ck if cv[it_index].state != CLV_UNTRACKED clv_update_state(s, it, cv[it_index]);
    if is_terminator(o) {
        f: [..] bool; f.allocator = temp;
        clv_feasible_successors(s, i, *f);
        bb := inst_block(i);
        for k: 0..f.count - 1 if f[k] clv_mark_edge_executable(s, bb, get_successor(i, cast(u32) k));
    }
}

clv_solve :: (s: *Clv) {
    while s.bb_wl.count || s.value_wl.count {
        while s.value_wl.count {
            v := pop(*s.value_wl);
            users: [..] Value_Id; users.allocator = temp;
            u := ir.v_first_use[v];
            while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
            for usr: users if is_inst(usr) && vkind(usr) != .DEAD && table_contains(*s.bb_exec, inst_block(usr)) clv_visit_inst(s, usr);
        }
        while s.bb_wl.count {
            bb := pop(*s.bb_wl);
            for i: block_insts(bb) clv_visit_inst(s, i);
        }
    }
}

called_value_propagation_run :: () -> Preserved {
    s: Clv;
    s.states.allocator = temp; s.bb_exec.allocator = temp; s.feasible_edges.allocator = temp;
    s.bb_wl.allocator = temp; s.value_wl.allocator = temp; s.indirect_calls.allocator = temp; s.indirect_set.allocator = temp;
    for f: ir.m_functions if !is_declaration(f) && !clv_can_track_arguments(f) clv_mark_block_executable(*s, fn_entry(f));
    clv_solve(*s);
    callees := md_fixed("callees");
    for c: s.indirect_calls {
        found, lv := table_find(*s.states, clv_key(call_callee(c), CLV_REGISTER));   // getExistingValueState
        if !found || lv.state != CLV_FUNCTION_SET || lv.funcs.count == 0 continue;
        ops := NewArray(lv.funcs.count, Md_Id,, allocator = temp);
        for lv.funcs ops[it_index] = md_value(it);
        set_metadata(c, callees, md_tuple(ops, false));   // MDBuilder::createCallees
    }
    return PRESERVE_ALL;
}
