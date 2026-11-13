// FunctionSpecialization: a port of llvm/lib/Transforms/IPO/FunctionSpecialization.cpp (FunctionSpecializer,
// InstCostVisitor) with CloneFunction / CloneFunctionInto (llvm/lib/Transforms/Utils/CloneFunction.cpp) and the
// parts of CodeMetrics::analyzeBasicBlock (llvm/lib/Analysis/CodeMetrics.cpp) it reads. Run by ipsccp
// (pass_sccp.jai) unless `ipsccp<no-func-spec>`.
// Fails loudly: cloning a function whose metadata graph has distinct nodes (debug info, loop IDs: the MDNodeMapper
// is not ported) or debug records.

fs_opts: struct {
    force_specialization := false;          // -force-specialization
    max_clones: s64 = 3;                    // -funcspec-max-clones
    max_discovery_iterations: s64 = 100;    // -funcspec-max-discovery-iterations
    max_incoming_phi_values: s64 = 8;       // -funcspec-max-incoming-phi-values
    max_block_predecessors: s64 = 2;        // -funcspec-max-block-predecessors
    min_function_size: s64 = 500;           // -funcspec-min-function-size
    max_codesize_growth: s64 = 3;           // -funcspec-max-codesize-growth
    min_codesize_savings: s64 = 20;         // -funcspec-min-codesize-savings
    min_latency_savings: s64 = 20;          // -funcspec-min-latency-savings
    min_inlining_bonus: s64 = 300;          // -funcspec-min-inlining-bonus
    specialize_on_address := false;         // -funcspec-on-address
    specialize_literal_constant := true;    // -funcspec-for-literal-constant
};

fs_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    bool_opt :: (p: *bool, name: string, value: string, has_value: bool) {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" p.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" p.* = false;
        else fatal(tprint("opt: invalid value '%' for -%", value, name));
    }
    int_opt :: (p: *s64, name: string, value: string, has_value: bool) {
        if !has_value fatal(tprint("opt: -% needs a value", name));
        v, ok := string_to_int(value);
        if !ok || v < 0 fatal(tprint("opt: invalid value '%' for -%", value, name));
        p.* = v;
    }
    o := *fs_opts;
    if name == {
        case "force-specialization"; bool_opt(*o.force_specialization, name, value, has_value);
        case "funcspec-on-address"; bool_opt(*o.specialize_on_address, name, value, has_value);
        case "funcspec-for-literal-constant"; bool_opt(*o.specialize_literal_constant, name, value, has_value);
        case "funcspec-max-clones"; int_opt(*o.max_clones, name, value, has_value);
        case "funcspec-max-discovery-iterations"; int_opt(*o.max_discovery_iterations, name, value, has_value);
        case "funcspec-max-incoming-phi-values"; int_opt(*o.max_incoming_phi_values, name, value, has_value);
        case "funcspec-max-block-predecessors"; int_opt(*o.max_block_predecessors, name, value, has_value);
        case "funcspec-min-function-size"; int_opt(*o.min_function_size, name, value, has_value);
        case "funcspec-max-codesize-growth"; int_opt(*o.max_codesize_growth, name, value, has_value);
        case "funcspec-min-codesize-savings"; int_opt(*o.min_codesize_savings, name, value, has_value);
        case "funcspec-min-latency-savings"; int_opt(*o.min_latency_savings, name, value, has_value);
        case "funcspec-min-inlining-bonus"; int_opt(*o.min_inlining_bonus, name, value, has_value);
        case "funcspec-max-iters"; int_opt(*ipsccp_opts.funcspec_max_iters, name, value, has_value);
        case; return false;
    }
    return true;
}

// IPSCCPOptions::AllowFuncSpec: `ipsccp<no-func-spec>` turns it off
ipsccp_allow_func_spec := true;
ipsccp_func_spec_enabled :: () -> bool { return ipsccp_allow_func_spec; }
ipsccp_parse_params :: (name: string) {
    ipsccp_allow_func_spec = true;
    if name == "ipsccp" return;
    params := slice(name, 7, name.count - 8);
    while params.count {
        p := params;
        semi := find_index_from_left(params, #char ";");
        if semi >= 0 { p = slice(params, 0, semi); params = slice(params, semi + 1, params.count - semi - 1); }
        else params = "";
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "func-spec" ipsccp_allow_func_spec = enable;
        else fatal("invalid pass pipeline: invalid IPSCCP pass parameter '%'", p);
    }
}

Fs_Spec :: struct {
    f: Value_Id;
    clone: Value_Id = NONE;
    args: [..] Fs_Arg;      // SpecSig::Args (Key is always 0)
    score: u32;
    code_size: u32;
    call_sites: [..] Value_Id;
}

Fs_Metrics :: struct {
    not_duplicatable: bool;
    is_recursive: bool;
    num_insts: Cost;
}

Func_Spec :: struct {
    s: *Sccp;
    specializations: [..] Value_Id;    // SmallPtrSet (insertion order)
    dead_functions: [..] Value_Id;
    metrics: Table(Value_Id, Fs_Metrics);
    growth: Table(Value_Id, u32);
    n_globals: u32;
}

fs_init :: (fs: *Func_Spec, s: *Sccp) {
    fs.s = s;
    fs.specializations.allocator = temp; fs.dead_functions.allocator = temp;
    fs.metrics.allocator = temp; fs.growth.allocator = temp;
}
fs_is_dead_function :: (fs: *Func_Spec, f: Value_Id) -> bool { return block_set_contains(fs.dead_functions, f); }

// ---------------------------------------------------------------- InstCostVisitor

Fs_Cost_Visitor :: struct {
    fs: *Func_Spec;
    f: Value_Id;
    tti: *Tti;
    known: Table(Value_Id, Value_Id);          // KnownConstants
    known_order: [..] Value_Id;
    dead_blocks: Table(Value_Id, bool);
    visited_phis: Table(Value_Id, bool);
    pending_phis: [..] Value_Id;
    lv_key: Value_Id = NONE;                   // LastVisited (NONE = end())
    lv_val: Value_Id = NONE;
}

fs_cv_new :: (fs: *Func_Spec, f: Value_Id) -> Fs_Cost_Visitor {
    v: Fs_Cost_Visitor;
    v.fs = fs; v.f = f; v.tti = tti_get(f);
    v.known.allocator = temp; v.known_order.allocator = temp; v.dead_blocks.allocator = temp;
    v.visited_phis.allocator = temp; v.pending_phis.allocator = temp;
    return v;
}
fs_cv_known_insert :: (v: *Fs_Cost_Visitor, k: Value_Id, c: Value_Id) -> Value_Id {
    found, old := table_find(*v.known, k);
    if found return old;
    table_set(*v.known, k, c);
    array_add(*v.known_order, k);
    return c;
}
fs_cv_is_block_executable :: (v: *Fs_Cost_Visitor, bb: Value_Id) -> bool {
    return sc_is_block_executable(v.fs.s, bb) && !table_contains(*v.dead_blocks, bb);
}
// canEliminateSuccessor
fs_cv_can_eliminate_successor :: (v: *Fs_Cost_Visitor, bb: Value_Id, succ: Value_Id) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(succ, *preds);
    i := 0;
    for p: preds {
        ok := i < fs_opts.max_block_predecessors && (p == bb || p == succ || !fs_cv_is_block_executable(v, p));
        i += 1;
        if !ok return false;
    }
    return true;
}
// estimateBasicBlocks
fs_cv_estimate_basic_blocks :: (v: *Fs_Cost_Visitor, work: *[..] Value_Id) -> Cost {
    code_size: Cost = 0;
    while work.count {
        bb := pop(work);
        if table_contains(*v.dead_blocks, bb) continue;
        table_set(*v.dead_blocks, bb, true);
        for i: block_insts(bb) {
            if table_contains(*v.known, i) continue;
            code_size = cost_add(code_size, tti_instruction_cost(v.tti, i, TCK_CODE_SIZE));
        }
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for sb: succs if fs_cv_is_block_executable(v, sb) && fs_cv_can_eliminate_successor(v, bb, sb) array_add(work, sb);
    }
    return code_size;
}
// findConstantFor
fs_cv_find_constant_for :: (v: *Fs_Cost_Visitor, x: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(x)) return x;
    c := sc_get_constant_or_null(v.fs.s, x);
    if c != NONE return c;
    found, k := table_find(*v.known, x);
    if found return k;
    return NONE;
}
// getCodeSizeSavingsFromPendingPHIs
fs_cv_savings_from_pending_phis :: (v: *Fs_Cost_Visitor) -> Cost {
    code_size: Cost = 0;
    while v.pending_phis.count {
        phi := pop(*v.pending_phis);
        if fs_cv_is_block_executable(v, inst_block(phi)) code_size = cost_add(code_size, fs_cv_savings_for_user(v, phi, NONE, NONE));
    }
    return code_size;
}
// getCodeSizeSavingsForArg
fs_cv_savings_for_arg :: (v: *Fs_Cost_Visitor, a: Value_Id, c: Value_Id) -> Cost {
    code_size: Cost = 0;
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[a];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ui: users if is_inst(ui) && fs_cv_is_block_executable(v, inst_block(ui)) code_size = cost_add(code_size, fs_cv_savings_for_user(v, ui, a, c));
    return code_size;
}
// getLatencySavingsForKnownConstants
fs_cv_latency_savings :: (v: *Fs_Cost_Visitor) -> Cost {
    bfi := get_bfi(v.f);
    total: Cost = 0;
    for k: v.known_order {
        if !is_inst(k) continue;
        weight := bfi_get_block_freq(bfi, inst_block(k)) / bfi.entry_freq;
        c := tti_instruction_cost(v.tti, k, TCK_LATENCY);
        if !cost_valid(c) total = COST_INVALID;
        else total = cost_add(total, cast,no_check(s64) weight * c);
    }
    return total;
}
// getCodeSizeSavingsForUser
fs_cv_savings_for_user :: (v: *Fs_Cost_Visitor, usr: Value_Id, use: Value_Id, c_in: Value_Id) -> Cost {
    if table_contains(*v.known, usr) return 0;
    c := c_in;
    if use != NONE { v.lv_key = use; v.lv_val = fs_cv_known_insert(v, use, c); }
    else { v.lv_key = NONE; v.lv_val = NONE; }
    code_size: Cost = 0;
    o := inst_op(usr);
    if o == .SWITCH code_size = fs_cv_estimate_switch(v, usr);
    else if o == .CONDBR code_size = fs_cv_estimate_cond_br(v, usr);
    else {
        c = fs_cv_visit(v, usr);
        if c == NONE return 0;
    }
    fs_cv_known_insert(v, usr, c);
    code_size = cost_add(code_size, tti_instruction_cost(v.tti, usr, TCK_CODE_SIZE));
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[usr];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for ui: users if is_inst(ui) && ui != usr && fs_cv_is_block_executable(v, inst_block(ui)) code_size = cost_add(code_size, fs_cv_savings_for_user(v, ui, usr, c));
    return code_size;
}
fs_cv_estimate_switch :: (v: *Fs_Cost_Visitor, i: Value_Id) -> Cost {
    if sw_cond(i) != v.lv_key return 0;
    c := v.lv_val;
    if !isa_constant_int(c) return 0;
    k := sw_find_case_value(i, c);
    succ := ifx k < 0 then sw_default(i) else sw_case_dest(i, cast(u32) k);
    work: [..] Value_Id; work.allocator = temp;
    n := sw_num_cases(i);
    if n > 0 for ci: 0..n - 1 {
        bb := sw_case_dest(i, ci);
        if bb != succ && fs_cv_is_block_executable(v, bb) && fs_cv_can_eliminate_successor(v, inst_block(i), bb) array_add(*work, bb);
    }
    return fs_cv_estimate_basic_blocks(v, *work);
}
fs_cv_estimate_cond_br :: (v: *Fs_Cost_Visitor, i: Value_Id) -> Cost {
    if op(i, 0) != v.lv_key return 0;
    succ := get_successor(i, ifx is_one_value(v.lv_val) then cast(u32) 1 else 0);
    work: [..] Value_Id; work.allocator = temp;
    if fs_cv_is_block_executable(v, succ) && fs_cv_can_eliminate_successor(v, inst_block(i), succ) array_add(*work, succ);
    return fs_cv_estimate_basic_blocks(v, *work);
}
// discoverTransitivelyIncomingValues
fs_cv_discover_transitive :: (v: *Fs_Cost_Visitor, cst: Value_Id, root: Value_Id) -> bool {
    work: [..] Value_Id; work.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    array_add(*work, root);
    iter := 0;
    while work.count {
        pn := pop(*work);
        iter += 1;
        if iter > fs_opts.max_discovery_iterations || nops(pn) > fs_opts.max_incoming_phi_values return false;
        if table_contains(*seen, pn) continue;
        table_set(*seen, pn, true);
        n := nops(pn);
        if n > 0 for k: 0..n - 1 {
            x := op(pn, k);
            if is_inst(x) && (x == pn || !fs_cv_is_block_executable(v, phi_block(pn, k))) continue;
            c := fs_cv_find_constant_for(v, x);
            if c != NONE { if c != cst return false; continue; }
            if is_inst(x) && inst_op(x) == .PHI { array_add(*work, x); continue; }
            return false;
        }
    }
    return true;
}
fs_cv_visit_phi :: (v: *Fs_Cost_Visitor, i: Value_Id) -> Value_Id {
    n := nops(i);
    if n > fs_opts.max_incoming_phi_values return NONE;
    inserted := !table_contains(*v.visited_phis, i);
    if inserted table_set(*v.visited_phis, i, true);
    cst: Value_Id = NONE;
    seen_phi := false;
    if n > 0 for k: 0..n - 1 {
        x := op(i, k);
        if is_inst(x) && (x == i || !fs_cv_is_block_executable(v, phi_block(i, k))) continue;
        c := fs_cv_find_constant_for(v, x);
        if c != NONE {
            if cst == NONE cst = c;
            if c != cst return NONE;
            continue;
        }
        if inserted { array_add(*v.pending_phis, i); return NONE; }
        if is_inst(x) && inst_op(x) == .PHI { seen_phi = true; continue; }
        return NONE;
    }
    if cst == NONE return NONE;
    if !seen_phi return cst;
    if !fs_cv_discover_transitive(v, cst, i) return NONE;
    return cst;
}
fs_cv_visit :: (v: *Fs_Cost_Visitor, i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == .PHI return fs_cv_visit_phi(v, i);
    if o == .FREEZE {
        if is_guaranteed_not_to_be_undef_or_poison(v.lv_val) return v.lv_val;
        return NONE;
    }
    if o == .CALL || o == .INVOKE || o == .CALLBR {
        f := call_called_function(i);
        if f == NONE || !can_constant_fold_call_to(i, f) return NONE;
        ops: [..] Value_Id; ops.allocator = temp;
        n := nops(i);
        for k: 0..cast(s64) n - 2 {
            x := op(i, cast(u32) k);
            if vkind(x) == .MD_VALUE return NONE;
            c := fs_cv_find_constant_for(v, x);
            if c == NONE return NONE;
            array_add(*ops, c);
        }
        // ConstantFoldCall(&I, F, Ops) without a TargetLibraryInfo: library calls are not folded
        if fn_iid(f) == NOT_INTRINSIC return NONE;
        return cfo_call(i, f, ops);
    }
    if o == .LOAD {
        if vkind(v.lv_val) == .C_NULL return NONE;
        return cfo_load_from_const_ptr(v.lv_val, vtype(i));
    }
    if o == .GEP {
        n := nops(i);
        ops := NewArray(n, Value_Id,, allocator = temp);
        for k: 0..cast(s64) n - 1 {
            c := fs_cv_find_constant_for(v, op(i, cast(u32) k));
            if c == NONE return NONE;
            ops[k] = c;
        }
        return cfo_inst_operands(i, ops);
    }
    if o == .SELECT {
        if op(i, 0) == v.lv_key {
            x := ifx is_null_value(v.lv_val) then op(i, 2) else op(i, 1);
            return fs_cv_find_constant_for(v, x);
        }
        cond := fs_cv_find_constant_for(v, op(i, 0));
        if cond != NONE {
            if (op(i, 1) == v.lv_key && is_one_value(cond)) || (op(i, 2) == v.lv_key && is_null_value(cond)) return v.lv_val;
        }
        return NONE;
    }
    if is_cast_op(o) return cfo_cast_operand(o, v.lv_val, vtype(i));
    if o == .ICMP || o == .FCMP {
        cst := v.lv_val;
        const_on_rhs := op(i, 1) == v.lv_key;
        x := ifx const_on_rhs then op(i, 0) else op(i, 1);
        other := fs_cv_find_constant_for(v, x);
        if other != NONE {
            if const_on_rhs { t := cst; cst = other; other = t; }
            return cfo_compare_inst_operands(inst(i).pred, cst, other);
        }
        const_lv := vle_get(cst);
        other_lv := sc_lattice_value_for(v.fs.s, x);
        if const_on_rhs return vle_get_compare(other_lv, inst(i).pred, vtype(i), const_lv);
        return vle_get_compare(const_lv, inst(i).pred, vtype(i), other_lv);
    }
    if o == .FNEG return cfo_unary_op_operand(o, v.lv_val);
    if is_binary_op(o) {
        const_on_rhs := op(i, 1) == v.lv_key;
        x := ifx const_on_rhs then op(i, 0) else op(i, 1);
        other := fs_cv_find_constant_for(v, x);
        other_val := ifx other != NONE then other else x;
        const_val := v.lv_val;
        if const_on_rhs { t := const_val; const_val = other_val; other_val = t; }
        q: Simplify_Query; q.have_tli = false;   // SimplifyQuery(DL)
        r := simplify_binop(o, const_val, other_val, q);
        if r != NONE && is_constant_kind(vkind(r)) return r;
        return NONE;
    }
    return NONE;   // visitInstruction
}

// ---------------------------------------------------------------- FunctionSpecializer

// CodeMetrics::analyzeBasicBlock (the fields FunctionSpecializer reads)
fs_analyze_basic_block :: (m: *Fs_Metrics, t: *Tti, b: Value_Id, eph: *Table(Value_Id, bool)) {
    f := block_fn(b);
    for i: block_insts(b) {
        if table_contains(eph, i) continue;
        if is_call_base(i) {
            callee := call_called_function(i);
            if callee == f m.is_recursive = true;
        }
        if type_kind(vtype(i)) == .TOKEN {
            u := ir.v_first_use[i];
            while u != NONE {
                user := ir.u_user[u];
                ub := inst_block(user);
                if inst_op(user) == .PHI ub = ir.u_aux[u];
                if ub != b { m.not_duplicatable = true; break; }
                u = ir.u_next[u];
            }
        }
        if is_call_base(i) && call_has_fn_attr(i, .NoDuplicate) m.not_duplicatable = true;
        m.num_insts = cost_add(m.num_insts, tti_instruction_cost(t, i, TCK_CODE_SIZE));
    }
    term := block_terminator(b);
    if term != NONE && inst_op(term) == .INDIRECTBR m.not_duplicatable = true;
}

// isCandidateFunction
fs_is_candidate_function :: (fs: *Func_Spec, f: Value_Id) -> bool {
    if is_declaration(f) || glob(f).nargs == 0 return false;
    if gv_is_interposable(f) return false;
    if fn_has_fn_attr(f, .NoDuplicate) return false;
    if fn_has_fn_attr(f, .OptimizeForSize) || fn_has_fn_attr(f, .MinSize) return false;   // hasOptSize
    if block_set_contains(fs.specializations, f) return false;
    // shouldOptimizeForSize(F, nullptr, nullptr): hasOptSize only
    if !sc_is_block_executable(fs.s, fn_entry(f)) return false;
    if fn_has_fn_attr(f, .AlwaysInline) return false;
    return true;
}

// isArgumentInteresting
fs_is_argument_interesting :: (fs: *Func_Spec, a: Value_Id) -> bool {
    if !has_uses(a) return false;
    t := vtype(a);
    if !is_ptr_type(t) && (!fs_opts.specialize_literal_constant || (!is_int_type(t) && !is_fp_type(t) && type_kind(t) != .STRUCT)) return false;
    f := arg_parent(a);
    if arg_has_attr(a, .ByVal) && !mem_only_reads(fn_memory(f)) return false;
    if !sc_is_argument_tracked_function(fs.s, f) return true;
    if type_kind(t) == .STRUCT {
        for sc_struct_lattice_value_for(fs.s, a) if sc_is_overdefined(it) return true;
        return false;
    }
    return sc_is_overdefined(sc_lattice_value_for(fs.s, a));
}

// getCandidateConstant
fs_get_candidate_constant :: (fs: *Func_Spec, v: Value_Id) -> Value_Id {
    if vkind(v) == .C_POISON return NONE;
    c := v;
    if !is_constant_kind(vkind(c)) c = sc_get_constant_or_null(fs.s, v);
    if c != NONE && is_ptr_type(vtype(c)) && !is_null_value(c) {
        u := get_underlying_object(c);
        if vkind(u) == .GLOBAL_VAR && !(glob(u).is_const || fs_opts.specialize_on_address) return NONE;
    }
    return c;
}

// getInliningBonus
fs_get_inlining_bonus :: (fs: *Func_Spec, a: Value_Id, c: Value_Id) -> u32 {
    callee := strip_pointer_casts(c);
    if vkind(callee) != .FUNCTION return 0;
    bonus: s64 = 0;
    u := ir.v_first_use[a];
    while u != NONE {
        cs := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(cs) || (inst_op(cs) != .CALL && inst_op(cs) != .INVOKE) continue;
        if op(cs, nops(cs) - 1) != a continue;
        if inst(cs).ty2 != glob(callee).value_type continue;
        params := get_inline_params();
        params.default_threshold += IC_INDIRECT_CALL_THRESHOLD;
        ic := get_inline_cost_for_callee(cs, callee, params);
        if ic_is_always(ic) bonus += params.default_threshold;
        else if !ic_is_never(ic) && ic_cost_delta(ic) > 0 bonus += ic_cost_delta(ic);
    }
    return ifx bonus > 0 then cast(u32) bonus else 0;
}

// getInlineCost(Call, Callee, Params, ...) for an explicit callee (the call may be indirect)
get_inline_cost_for_callee :: (call: Value_Id, callee: Value_Id, params: Inline_Params) -> Inline_Cost {
    decided, r := get_attribute_based_inlining_decision(call, callee);
    if decided {
        if r.ok return inline_cost_always("always inline attribute");
        return inline_cost_never(r.reason);
    }
    if ic_opts.inline_all_viable_calls && is_inline_viable(callee).ok return inline_cost_always("Inlining forced by -inline-all-viable-calls");
    ca := cax_new(callee, call, params, true, false, false);
    should := cax_analyze(ca);
    if ca.decided_by_cost_benefit {
        if should.ok return inline_cost_always("benefit over cost");
        return inline_cost_never(should.reason);
    }
    if ca.decided_by_cost_threshold return inline_cost_get(ca.cost, ca.threshold, ca.static_bonus_applied);
    if should.ok return inline_cost_always("empty function");
    return inline_cost_never(should.reason);
}

fs_sig_equal :: (a: [] Fs_Arg, b: [] Fs_Arg) -> bool {
    if a.count != b.count return false;
    for a if it.formal != b[it_index].formal || it.actual != b[it_index].actual return false;
    return true;
}

Fs_Range :: struct { begin: s64; end: s64; }

// findSpecializations
fs_find_specializations :: (fs: *Func_Spec, f: Value_Id, func_size: u32, all: *[..] Fs_Spec, sm: *Table(Value_Id, Fs_Range)) -> bool {
    unique: [..] s64; unique.allocator = temp;   // UniqueSpecs: indices into `all`
    args: [..] Value_Id; args.allocator = temp;
    na := glob(f).nargs;
    if na > 0 for k: 0..na - 1 if fs_is_argument_interesting(fs, fn_arg(f, k)) array_add(*args, fn_arg(f, k));
    if args.count == 0 return false;
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for cs: users {
        if !is_inst(cs) || (inst_op(cs) != .CALL && inst_op(cs) != .INVOKE) continue;
        if call_called_function(cs) != f continue;
        if call_has_fn_attr(cs, .MinSize) continue;
        if !sc_is_block_executable(fs.s, inst_block(cs)) continue;
        sig: [..] Fs_Arg; sig.allocator = temp;
        for a: args {
            c := fs_get_candidate_constant(fs, call_arg(cs, arg_no(a)));
            if c == NONE continue;
            array_add(*sig, .{a, c});
        }
        if sig.count == 0 continue;
        existing: s64 = -1;
        for idx: unique if fs_sig_equal(all.*[idx].args, sig) { existing = idx; break; }
        if existing >= 0 {
            if inst_fn(cs) == f continue;
            array_add(*all.*[existing].call_sites, cs);
            continue;
        }
        code_size: Cost = 0;
        score: u32 = 0;
        vis := fs_cv_new(fs, f);
        for a: sig {
            code_size = cost_add(code_size, fs_cv_savings_for_arg(*vis, a.formal, a.actual));
            score += fs_get_inlining_bonus(fs, a.formal, a.actual);
        }
        code_size = cost_add(code_size, fs_cv_savings_from_pending_phis(*vis));
        savings := cast,no_check(u32) code_size;
        spec_size := func_size - savings;   // unsigned arithmetic, as in LLVM
        profitable := true;
        if !fs_opts.force_specialization {
            if score > cast,no_check(u32) (fs_opts.min_inlining_bonus * func_size / 100) {
                profitable = true;
            } else if savings < cast,no_check(u32) (fs_opts.min_codesize_savings * func_size / 100) {
                profitable = false;
            } else {
                latency := cast,no_check(u32) fs_cv_latency_savings(*vis);
                if latency < cast,no_check(u32) (fs_opts.min_latency_savings * func_size / 100) profitable = false;
                else {
                    _, g := table_find(*fs.growth, f);
                    if (g + spec_size) / func_size > cast,no_check(u32) fs_opts.max_codesize_growth profitable = false;
                    else score += max(savings, latency);
                }
            }
        }
        if !profitable continue;
        sp: Fs_Spec;
        sp.f = f; sp.score = score; sp.code_size = spec_size;
        sp.args.allocator = temp; sp.call_sites.allocator = temp;
        for sig array_add(*sp.args, it);
        if inst_fn(cs) != f array_add(*sp.call_sites, cs);
        array_add(all, sp);
        index := all.count - 1;
        array_add(*unique, index);
        r := table_find_pointer(sm, f);
        if !r table_set(sm, f, .{index, index + 1});
        else r.end = index + 1;
    }
    return unique.count > 0;
}

// promoteConstantStackValues
fs_promote_constant_stack_values :: (fs: *Func_Spec, f: Value_Id) {
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for call: users {
        if !is_inst(call) || inst_op(call) != .CALL continue;
        if !sc_is_block_executable(fs.s, inst_block(call)) continue;
        n := call_num_args(call);
        if n > 0 for idx: 0..n - 1 {
            arg := call_arg(call, idx);
            if !call_only_reads_memory_arg(call, idx) || !is_ptr_type(vtype(arg)) continue;
            c := fs_get_constant_stack_value(fs, call, arg);
            if c == NONE continue;
            fs.n_globals += 1;
            gv := gv_create(vtype(c), true, .INTERNAL, c, tprint("specialized.arg.%", fs.n_globals), NONE, 0, 0);
            call_set_arg(call, idx, gv);
        }
    }
}
// CallBase::onlyReadsMemory(OpNo)
call_only_reads_memory_arg :: (call: Value_Id, idx: u32) -> bool {
    if call_param_has_attr(call, idx, .ByVal) return true;   // the callee cannot write the original pointer
    return call_param_has_attr(call, idx, .ReadOnly) || call_param_has_attr(call, idx, .ReadNone);
}
fs_get_constant_stack_value :: (fs: *Func_Spec, call: Value_Id, v_in: Value_Id) -> Value_Id {
    if v_in == NONE return NONE;
    v := strip_pointer_casts(v_in);
    if !is_inst(v) || inst_op(v) != .ALLOCA return NONE;
    // getPromotableAlloca
    store_value: Value_Id = NONE;
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if usr == call continue;
        if is_inst(usr) && inst_op(usr) == .STORE {
            if store_value != NONE || (inst(usr).flags & F_VOLATILE) != 0 return NONE;
            store_value = op(usr, 0);
            continue;
        }
        return NONE;
    }
    if store_value == NONE return NONE;
    c := fs_get_candidate_constant(fs, store_value);
    if c == NONE || !is_int_type(vtype(c)) return NONE;
    return c;
}

// removeSSACopy
fs_remove_ssa_copy :: (f: Value_Id) {
    for bb: fn_blocks(f) {
        i := block(bb).first;
        while i != NONE {
            nx := inst(i).next;
            if inst_op(i) == .BITCAST && vtype(i) == vtype(op(i, 0)) {
                rauw_with_metadata(i, op(i, 0));
                erase_inst_with_metadata(i);
            }
            i = nx;
        }
    }
}

// ---------------------------------------------------------------- metadata cloning (MDNodeMapper, RF_None)
// CloneFunctionInto(LocalChangesOnly) maps metadata with RF_None and createIdentityMDPredicate: distinct nodes are
// cloned (the function's DISubprogram and its local scopes, variables, loop IDs, DIAssignIDs), uniqued nodes are
// re-uniqued when an operand changed, compile units / other subprograms / global variable expressions / types
// that are not local to the cloned subprogram map to themselves. The results are put into the Value_Map's MD map
// before RemapInstruction runs, so the ValueMapper finds every top-level node there.

Fs_Md_Mapper :: struct {
    vm: *Value_Map;
    sp: Md_Id;                       // F.getSubprogram()
    in_progress: Table(Md_Id, bool);
}

// createIdentityMDPredicate(F, LocalChangesOnly)
fs_md_identity :: (c: *Fs_Md_Mapper, m: Md_Id) -> bool {
    r := ir.mds[m];
    if r.kind != .SPECIAL return false;
    k := di_kind(m);
    keep :: (c: *Fs_Md_Mapper, sp: Md_Id) -> bool { return sp != c.sp; }
    if k == .COMPILE_UNIT return true;
    if k == .SUBPROGRAM return keep(c, m);
    if k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE return keep(c, di_local_scope_subprogram(m));
    if k == .LOCAL_VARIABLE {
        sc := di_op(m, 0);
        if sc != NONE && ir.mds[sc].kind == .SPECIAL {
            sk := di_kind(sc);
            if sk == .SUBPROGRAM || sk == .LEXICAL_BLOCK || sk == .LEXICAL_BLOCK_FILE return keep(c, di_local_scope_subprogram(sc));
        }
    }
    if k == .GLOBAL_VARIABLE_EXPRESSION return true;
    if !di_is_type(m) return false;
    if c.sp == NONE return true;
    if k == .DERIVED_TYPE && di_op(m, 1) == NONE return false;
    sc := di_op(m, 1);
    if sc == NONE || ir.mds[sc].kind != .SPECIAL return true;
    sk := di_kind(sc);
    if sk != .SUBPROGRAM && sk != .LEXICAL_BLOCK && sk != .LEXICAL_BLOCK_FILE return true;
    return keep(c, di_local_scope_subprogram(sc));
}

fs_map_md :: (c: *Fs_Md_Mapper, m: Md_Id) -> Md_Id {
    if m == NONE return NONE;
    found, x := table_find(*c.vm.md, m);
    if found return x;
    r := ir.mds[m];
    if r.kind == .STRING return m;
    if r.kind == .VALUE {
        v := r.value;
        nv := map_value(c.vm, v, RF_NONE);
        if nv == NONE || nv == v return m;
        return md_value(nv);
    }
    if r.kind != .TUPLE && r.kind != .SPECIAL fatal("function specialization: cloning metadata of an unexpected kind");
    if fs_md_identity(c, m) { table_set(*c.vm.md, m, m); return m; }
    n := r.nops;
    if r.distinct {
        ops := NewArray(n, Md_Id,, allocator = temp);
        for k: 0..cast(s64) n - 1 ops[k] = ir.md_ops[r.ops + cast(u32) k];
        nm: Md_Id;
        if r.kind == .TUPLE nm = md_tuple(ops, true);
        else {
            ints: [] u64; ints.data = ir.md_ints.data + r.ints; ints.count = r.nints;
            nm = di_get(cast(DI_Kind) r.sub, true, ops, ints);
        }
        table_set(*c.vm.md, m, nm);
        for k: 0..cast(s64) n - 1 {
            o := ir.md_ops[r.ops + cast(u32) k];
            mapped := fs_map_md(c, o);   // may grow ir.md_ops: index after the call
            ir.md_ops[ir.mds[nm].ops + cast(u32) k] = mapped;
        }
        return nm;
    }
    if table_contains(*c.in_progress, m) fatal("function specialization: cloning a uniqued metadata cycle is not supported yet");
    table_set(*c.in_progress, m, true);
    ops := NewArray(n, Md_Id,, allocator = temp);
    same := true;
    for k: 0..cast(s64) n - 1 {
        o := ir.md_ops[ir.mds[m].ops + cast(u32) k];
        ops[k] = fs_map_md(c, o);
        if ops[k] != o same = false;
    }
    table_remove(*c.in_progress, m);
    nm := m;
    if !same {
        rr := ir.mds[m];
        if rr.kind == .TUPLE nm = md_tuple(ops, false);
        else {
            ints := NewArray(rr.nints, u64,, allocator = temp);
            for k: 0..cast(s64) rr.nints - 1 ints[k] = ir.md_ints[rr.ints + cast(u32) k];
            nm = di_get(cast(DI_Kind) rr.sub, false, ops, ints);
        }
    }
    table_set(*c.vm.md, m, nm);
    return nm;
}

// map every metadata node the cloned body and the function refer to
fs_premap_metadata :: (c: *Fs_Md_Mapper, f: Value_Id, nf: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(f, *all);
    for all fs_map_md(c, it.md);
    for bb: fn_blocks(nf) for i: block_insts(bb) {
        get_all_metadata(i, *all);
        for all fs_map_md(c, it.md);
        n := nops(i);
        if n > 0 for k: 0..n - 1 {
            o := op(i, k);
            if o != NONE && vkind(o) == .MD_VALUE fs_map_md(c, cast(Md_Id) ir.v_aux[o]);
        }
        r := inst(i).records;
        while r != 0 {
            rec := dbgr(r);
            for m: Md_Id.[rec.dbg, rec.var, rec.expr] if m != NONE fs_map_md(c, m);
            if rec.kind == .ASSIGN for m: Md_Id.[rec.assign_id, rec.addr_expr] if m != NONE fs_map_md(c, m);
            if rec.kind == .LABEL && rec.loc != NONE fs_map_md(c, rec.loc);
            r = rec.next;
        }
    }
}

// NewSP->cleanupRetainedNodesIf(...): global variable expressions of static locals stay with the old subprogram
fs_cleanup_retained_nodes :: (new_sp: Md_Id) {
    if !is_di(new_sp, .SUBPROGRAM) return;
    rn := di_op(new_sp, 7);
    if rn == NONE || ir.mds[rn].kind != .TUPLE return;
    kept: [..] Md_Id; kept.allocator = temp;
    changed := false;
    for k: 0..cast(s64) ir.mds[rn].nops - 1 {
        n := md_op(rn, cast(u32) k);
        if is_di(n, .GLOBAL_VARIABLE_EXPRESSION) {
            var := di_op(n, 0);
            sc := ifx var != NONE then di_op(var, 0) else NONE;
            if di_local_scope_subprogram(sc) != new_sp { changed = true; continue; }
        }
        array_add(*kept, n);
    }
    if !changed return;
    kept_t := md_tuple(kept, false);   // md_tuple can grow ir.md_ops: build it before indexing
    ir.md_ops[ir.mds[new_sp].ops + 7] = kept_t;
}

// CloneFunction(F, VMap) + setName(F->getName() + ".specialized." + N) + removeSSACopy
fs_clone_candidate_function :: (f: Value_Id, n: s64) -> Value_Id {
    vm: Value_Map; vmap_init(*vm);
    nf := clone_function(f, *vm);
    set_name(nf, tprint("%.specialized.%", vname(f), n));
    fs_remove_ssa_copy(nf);
    return nf;
}
// CloneFunction(F, VMap): a new function with F's name (uniqued) at the end of the module, the body cloned with
// CloneFunctionInto(LocalChangesOnly); `vm` maps F's arguments and blocks (and instructions) to the clone's
// (`new_name`/`before`: Function::Create(F->getName() + suffix) inserted before `before`, as Attributor::internalizeFunctions)
clone_function :: (f: Value_Id, vm: *Value_Map, new_name := "", before: Value_Id = NONE) -> Value_Id {
    ft := glob(f).value_type;
    nf := new_function(ft, "", glob(f).addrspace);
    gv_set_linkage(nf, glob(f).linkage);
    if before != NONE ipo_fn_insert_before(nf, before);
    else array_add(*ir.m_functions, nf);
    set_name(nf, ifx new_name.count then new_name else vname(f));
    na := glob(f).nargs;
    if na > 0 for k: 0..na - 1 {
        if vname(fn_arg(f, k)).count set_name(fn_arg(nf, k), vname(fn_arg(f, k)));
        vmap_set(vm, fn_arg(f, k), fn_arg(nf, k));
    }
    // CloneFunctionAttributesInto
    ipo_fn_copy_attributes_from(nf, f);
    if glob(f).has_personality set_op(nf, 0, map_value(vm, op(f, 0), RF_NONE));
    if glob(f).has_prefix set_op(nf, 1, map_value(vm, op(f, 1), RF_NONE));
    if glob(f).has_prologue set_op(nf, 2, map_value(vm, op(f, 2), RF_NONE));
    glob(nf).attrs = glob(f).attrs;
    // CloneFunctionBodyInto's block cloning first (the metadata mapping needs the value map of the body)
    for bb: fn_blocks(f) {
        cbb := clone_basic_block(bb, vm, "", nf);
        vmap_set(vm, bb, cbb);
        if block_has_address_taken(bb) vmap_set(vm, const_blockaddr(f, bb), const_blockaddr(nf, cbb));
    }
    mm: Fs_Md_Mapper; mm.vm = vm; mm.in_progress.allocator = temp;
    mm.sp = get_metadata(f, MDK_DBG);
    vm.has_md = true;
    fs_premap_metadata(*mm, f, nf);
    // CloneFunctionMetadataInto
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(f, *all);
    for all add_metadata(nf, it.kind, fs_map_md(*mm, it.md));
    for bb: fn_blocks(nf) for i: block_insts(bb) {
        remap_instruction(vm, i, RF_NONE);
        remap_dbg_record_range(vm, i, RF_NONE);
    }
    fs_cleanup_retained_nodes(get_metadata(nf, MDK_DBG));
    return nf;
}

// createSpecialization
fs_create_specialization :: (fs: *Func_Spec, f: Value_Id, args: [] Fs_Arg) -> Value_Id {
    clone := fs_clone_candidate_function(f, fs.specializations.count + 1);
    gv_set_linkage(clone, .INTERNAL);
    ok, _ := fn_entry_count(f);
    if ok fn_set_entry_count(clone, 0);
    sc_set_lattice_value_for_specialization_arguments(fs.s, clone, args);
    sc_mark_block_executable(fs.s, fn_entry(clone));
    sc_add_argument_tracked_function(fs.s, clone);
    sc_add_tracked_function(fs.s, clone);
    array_add(*fs.specializations, clone);
    return clone;
}

// updateCallSites
fs_update_call_sites :: (fs: *Func_Spec, f: Value_Id, specs: [] Fs_Spec) {
    to_update: [..] Value_Id; to_update.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE {
        cs := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(cs) && is_call_base(cs) && call_called_function(cs) == f && sc_is_block_executable(fs.s, inst_block(cs)) array_add(*to_update, cs);
    }
    left := to_update.count;
    for cs: to_update {
        should_decrement := inst_fn(cs) == f;
        best: *Fs_Spec = null;
        for * sp: specs {
            if sp.clone == NONE || (best && sp.score <= best.score) continue;
            mismatch := false;
            for a: sp.args if fs_get_candidate_constant(fs, call_arg(cs, arg_no(a.formal))) != a.actual { mismatch = true; break; }
            if mismatch continue;
            best = sp;
        }
        if best {
            call_set_called_function(cs, best.clone);
            should_decrement = true;
        }
        if should_decrement left -= 1;
    }
    if left == 0 && sc_is_argument_tracked_function(fs.s, f) && !fn_has_address_taken(f) {
        sc_mark_function_unreachable(fs.s, f);
        if !block_set_contains(fs.dead_functions, f) array_add(*fs.dead_functions, f);
    }
}

// libstdc++ heap algorithms (std::make_heap / push_heap / pop_heap) over indices with CompareScore
fs_cmp :: (all: [] Fs_Spec, i: u32, j: u32) -> bool {
    if all[i].score != all[j].score return all[i].score > all[j].score;
    return i > j;
}
fs_push_heap_impl :: (all: [] Fs_Spec, h: [] u32, hole_in: s64, top: s64, value: u32) {
    hole := hole_in;
    parent := (hole - 1) / 2;
    while hole > top && fs_cmp(all, h[parent], value) {
        h[hole] = h[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    h[hole] = value;
}
fs_adjust_heap :: (all: [] Fs_Spec, h: [] u32, hole_in: s64, len: s64, value: u32) {
    hole := hole_in;
    top := hole;
    second := hole;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if fs_cmp(all, h[second], h[second - 1]) second -= 1;
        h[hole] = h[second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        h[hole] = h[second - 1];
        hole = second - 1;
    }
    fs_push_heap_impl(all, h, hole, top, value);
}
fs_make_heap :: (all: [] Fs_Spec, h: [] u32) {
    len := h.count;
    if len < 2 return;
    parent := (len - 2) / 2;
    while true {
        fs_adjust_heap(all, h, parent, len, h[parent]);
        if parent == 0 return;
        parent -= 1;
    }
}
fs_push_heap :: (all: [] Fs_Spec, h: [] u32) { fs_push_heap_impl(all, h, h.count - 1, 0, h[h.count - 1]); }
fs_pop_heap :: (all: [] Fs_Spec, h: [] u32) {
    if h.count <= 1 return;
    last := h.count - 1;
    value := h[last];
    h[last] = h[0];
    sub: [] u32; sub.data = h.data; sub.count = last;
    fs_adjust_heap(all, sub, 0, last, value);
}

// FunctionSpecializer::run
fs_run :: (fs: *Func_Spec) -> bool {
    sm: Table(Value_Id, Fs_Range); sm.allocator = temp;
    all: [..] Fs_Spec; all.allocator = temp;
    num_candidates: u32 = 0;
    fi := 0;
    while fi < ir.m_functions.count {
        f := ir.m_functions[fi];
        fi += 1;
        if !fs_is_candidate_function(fs, f) continue;
        inserted := !table_contains(*fs.metrics, f);
        if inserted {
            m: Fs_Metrics;
            eph: Table(Value_Id, bool); eph.allocator = temp;
            collect_ephemeral_values_fn(f, get_assumption_cache(f), *eph);
            t := tti_get(f);
            for bb: fn_blocks(f) fs_analyze_basic_block(*m, t, bb, *eph);
            table_set(*fs.metrics, f, m);
        }
        _, metrics := table_find(*fs.metrics, f);
        require_min_size := !fs_opts.force_specialization && (fs_opts.specialize_literal_constant || !fn_has_fn_attr(f, .NoInline));
        if metrics.not_duplicatable || !cost_valid(metrics.num_insts) || (require_min_size && metrics.num_insts < fs_opts.min_function_size) continue;
        if !fs_opts.specialize_literal_constant && !inserted && !metrics.is_recursive continue;
        func_size := cast(u32) metrics.num_insts;
        if inserted && metrics.is_recursive fs_promote_constant_stack_values(fs, f);
        if !fs_find_specializations(fs, f, func_size, *all, *sm) continue;
        num_candidates += 1;
    }
    if num_candidates == 0 return false;
    nspecs := min(cast(s64) num_candidates * fs_opts.max_clones, all.count);
    best := NewArray(nspecs + 1, u32,, allocator = temp);
    for k: 0..nspecs - 1 best[k] = cast(u32) k;
    if all.count > nspecs {
        heap: [] u32; heap.data = best.data; heap.count = nspecs;
        fs_make_heap(all, heap);
        for i: nspecs..all.count - 1 {
            best[nspecs] = cast(u32) i;
            fs_push_heap(all, best);
            fs_pop_heap(all, best);
        }
    }
    original: [..] Value_Id; original.allocator = temp;
    clones: [..] Value_Id; clones.allocator = temp;
    for k: 0..nspecs - 1 {
        sp := *all[best[k]];
        g := table_find_pointer(*fs.growth, sp.f);
        if !g { table_set(*fs.growth, sp.f, 0); g = table_find_pointer(*fs.growth, sp.f); }
        g.* += sp.code_size;
        sp.clone = fs_create_specialization(fs, sp.f, sp.args);
        for call: sp.call_sites {
            call_set_called_function(call, sp.clone);
            caller := inst_fn(call);
            bfi := get_bfi(caller);
            has_count, count := bfi_block_profile_count(bfi, inst_block(call));
            if has_count {
                has_clone, clone_count := fn_entry_count(sp.clone);
                if has_clone {
                    fn_set_entry_count(sp.clone, count + clone_count);
                    has_orig, orig := fn_entry_count(sp.f);
                    if has_orig && orig >= count fn_set_entry_count(sp.f, orig - count);
                }
            }
        }
        array_add(*clones, sp.clone);
        if !block_set_contains(original, sp.f) array_add(*original, sp.f);
    }
    sc_solve_while_resolved_undefs_in_list(fs.s, clones);
    // OriginalFuncs is a SmallPtrSet<Function *, 8>: with more than 8 functions LLVM iterates it in pointer order.
    // The order only matters when a call site of one original function lies in another one that this loop marks
    // dead; that case fails loudly.
    dead_before := fs.dead_functions.count;
    for f: original {
        _, r := table_find(*sm, f);
        specs: [] Fs_Spec; specs.data = all.data + r.begin; specs.count = r.end - r.begin;
        fs_update_call_sites(fs, f, specs);
    }
    if original.count > 8 && fs.dead_functions.count > dead_before {
        newly_dead: [] Value_Id; newly_dead.data = fs.dead_functions.data + dead_before; newly_dead.count = fs.dead_functions.count - dead_before;
        for f: original {
            if !sc_is_argument_tracked_function(fs.s, f) || fn_has_address_taken(f) continue;
            // calls of f left in executable code of functions this loop did not kill: then f stays alive in any order
            other_left := 0;
            unmatched_in_dead := 0;
            _, r := table_find(*sm, f);
            u := ir.v_first_use[f];
            while u != NONE {
                cs := ir.u_user[u];
                u = ir.u_next[u];
                if !is_inst(cs) || !is_call_base(cs) || call_called_function(cs) != f continue;
                g := inst_fn(cs);
                if g == f continue;
                if block_set_contains(newly_dead, g) {
                    matched := false;
                    for k: r.begin..r.end - 1 {
                        sp := *all[k];
                        if sp.clone == NONE continue;
                        ok := true;
                        for a: sp.args if fs_get_candidate_constant(fs, call_arg(cs, arg_no(a.formal))) != a.actual { ok = false; break; }
                        if ok { matched = true; break; }
                    }
                    if !matched unmatched_in_dead += 1;
                } else if sc_is_block_executable(fs.s, inst_block(cs)) {
                    other_left += 1;
                }
            }
            if unmatched_in_dead > 0 && other_left == 0
                fatal("function specialization: the result depends on SmallPtrSet pointer order (more than 8 specialized functions in one round calling each other); not supported");
        }
    }
    for f: clones {
        rt := func_ret(glob(f).value_type);
        if rt == ir.t_void continue;
        if type_kind(rt) == .STRUCT {
            if !sc_is_struct_lattice_constant(fs.s, f, rt) continue;
        } else {
            k := sc_ret_slot(fs.s, f);
            if k < 0 fatal("function specialization: internal: the return value of a specialization is not tracked");
            if sc_is_overdefined(fs.s.lat[k]) continue;
        }
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[f];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for cs: users {
            if !is_inst(cs) || !is_call_base(cs) || call_called_function(cs) != f continue;
            sc_reset_lattice_value_for(fs.s, cs);
        }
    }
    sc_solve_while_resolved_undefs(fs.s);
    promoting := 0;
    for f: original {
        _, m := table_find(*fs.metrics, f);
        if m.is_recursive {
            before := fs.n_globals;
            fs_promote_constant_stack_values(fs, f);
            if fs.n_globals != before promoting += 1;
        }
    }
    if original.count > 8 && promoting > 1
        fatal("function specialization: the names of promoted stack values depend on SmallPtrSet pointer order (more than 8 specialized functions in one round); not supported");
    return true;
}

// ~FunctionSpecializer: removeDeadFunctions, cleanUpSSA
fs_finish :: (fs: *Func_Spec) {
    for f: fs.dead_functions {
        { table_remove(*fam, f); ac_virtual_clear(f); }   // FAM->clear(*F)
        while ir.v_first_use[f] != NONE {
            cs := ir.u_user[ir.v_first_use[f]];
            if !is_inst(cs) || (inst_op(cs) != .CALL && inst_op(cs) != .INVOKE) fatal("function specialization: internal: a dead function has a user that is not a call");
            if has_uses(cs) rauw_with_metadata(cs, const_poison(vtype(cs)));
            erase_inst_with_metadata(cs);
        }
        gv_erase_from_parent(f);
    }
    fs.dead_functions.count = 0;
    for fs.specializations fs_remove_ssa_copy(it);
}
