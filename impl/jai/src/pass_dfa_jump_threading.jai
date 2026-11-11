// DFAJumpThreading: a port of llvm/lib/Transforms/Scalar/DFAJumpThreading.cpp (MainSwitch, AllSwitchPaths,
// TransformDFA, unfold) with SSAUpdaterBulk (llvm/lib/Transforms/Utils/SSAUpdaterBulk.cpp, RewriteAllUses) and the
// CodeMetrics::analyzeBasicBlock fields it reads. Optimization remarks are not emitted (-pass-remarks is not
// supported).

dfa_opts: struct {
    early_exit_heuristic := true;     // -dfa-early-exit-heuristic
    max_path_length: s64 = 20;        // -dfa-max-path-length
    max_num_visited_paths: s64 = 2500;// -dfa-max-num-visited-paths
    max_num_paths: s64 = 200;         // -dfa-max-num-paths
    cost_threshold: s64 = 50;         // -dfa-cost-threshold
    max_cloned_rate: float64 = 7.5;   // -dfa-max-cloned-rate
    max_outer_use_blocks: s64 = 40;   // -dfa-max-out-use-blocks
};

dfa_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_opt :: (p: *s64, name: string, value: string, has_value: bool) {
        if !has_value fatal(tprint("opt: -% needs a value", name));
        v, ok := string_to_int(value);
        if !ok || v < 0 fatal(tprint("opt: invalid value '%' for -%", value, name));
        p.* = v;
    }
    o := *dfa_opts;
    if name == {
        case "dfa-early-exit-heuristic";
            if !has_value || value == "true" || value == "1" o.early_exit_heuristic = true;
            else if value == "false" || value == "0" o.early_exit_heuristic = false;
            else fatal(tprint("opt: invalid value '%' for -%", value, name));
        case "dfa-max-path-length"; int_opt(*o.max_path_length, name, value, has_value);
        case "dfa-max-num-visited-paths"; int_opt(*o.max_num_visited_paths, name, value, has_value);
        case "dfa-max-num-paths"; int_opt(*o.max_num_paths, name, value, has_value);
        case "dfa-cost-threshold"; int_opt(*o.cost_threshold, name, value, has_value);
        case "dfa-max-out-use-blocks"; int_opt(*o.max_outer_use_blocks, name, value, has_value);
        case "dfa-max-cloned-rate";
            if !has_value fatal("opt: -dfa-max-cloned-rate needs a value");
            v, ok := string_to_float64(value);
            if !ok fatal(tprint("opt: invalid value '%' for -dfa-max-cloned-rate", value));
            o.max_cloned_rate = v;
        case "dfa-jump-view-cfg-before"; fatal("opt: -dfa-jump-view-cfg-before is not supported");
        case; return false;
    }
    return true;
}

Dfa_Select :: struct { si: Value_Id; use: Value_Id; }   // SelectInstToUnfold

Dfa_Path :: struct {   // ThreadingPath
    path: [..] Value_Id;
    exit_val: APInt;
    exit_set: bool;
    dbb: Value_Id = NONE;
}
dfa_path_copy :: (p: Dfa_Path) -> Dfa_Path {
    r := p;
    np: [..] Value_Id; np.allocator = temp;
    for p.path array_add(*np, it);
    r.path = np;
    return r;
}
dfa_path_push_front :: (p: *[..] Value_Id, b: Value_Id) { array_insert_at(p, b, 0); }

Dfa :: struct {
    f: Value_Id;
    ac: *Assumption_Cache;
    dtu: *Dtu;
    li: *Loop_Info;
    tti: *Tti;
    loop_info_broken: bool;
}

// ---------------------------------------------------------------- unfold

dfa_unfold :: (d: *Dfa, sel: Dfa_Select, new_sis: *[..] Dfa_Select, new_bbs: *[..] Value_Id) {
    si := sel.si; si_use := sel.use;
    u := ir.v_first_use[si];
    start := phi_block(si_use, cast(u32) (u - ir.v_ops[si_use]));
    f := block_fn(start);
    t := block_terminator(start);
    if inst_op(t) == .BR {
        end_bb := get_successor(t, 0);
        nb := create_block(f, tprint("%.si.unfold.false", vname(si)), end_bb);
        array_add(new_bbs, nb);
        loc := merged_location(get_metadata(t, 0), get_metadata(si, 0));
        to_end := create_br(end_bb);
        block_append_inst(nb, to_end);
        set_metadata(to_end, 0, loc);
        dtu_apply1(d.dtu, true, nb, end_bb);
        op1 := op(si, 1); op2 := op(si, 2);
        np := create_phi(vtype(si_use), 1);
        insert_at_position(np, nb, block(nb).first, true);
        set_name(np, tprint("%.si.unfold.phi", vname(op2)));
        phi_add_incoming(np, op2, start);
        for p: block_insts(end_bb) {
            if inst_op(p) != .PHI break;
            if p == si_use continue;
            phi_add_incoming(p, phi_incoming_value_for_block(p, start), nb);
        }
        if end_bb == inst_block(si_use) {
            phi_add_incoming(si_use, np, nb);
            replace_uses_of_with(si_use, si, op1);
        } else {
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(end_bb, *preds);
            ep := create_phi(vtype(si_use), cast(u32) preds.count);
            insert_at_position(ep, end_bb, block(end_bb).first, true);
            set_name(ep, tprint("%.si.unfold.phi", vname(si)));
            for p: preds if p != start && p != nb phi_add_incoming(ep, ep, p);
            phi_add_incoming(ep, op1, start);
            phi_add_incoming(ep, np, nb);
            replace_uses_of_with(si_use, si, ep);
            si_use = ep;
        }
        if is_inst(op1) && inst_op(op1) == .SELECT array_add(new_sis, .{op1, si_use});
        if is_inst(op2) && inst_op(op2) == .SELECT array_add(new_sis, .{op2, np});
        recs := inst(t).records; inst(t).records = 0;
        erase_inst_with_metadata(t);
        bi := create_cond_br(op(si, 0), end_bb, nb);
        block_append_inst(start, bi);
        attach_records_before(bi, recs);
        set_metadata(bi, 0, loc);
        set_metadata(bi, md_kind_id("prof"), get_metadata(si, md_kind_id("prof")));
        dtu_apply1(d.dtu, true, start, nb);
    } else {
        end_bb := inst_block(si_use);
        nbt := create_block(f, tprint("%.si.unfold.true", vname(si)), end_bb);
        nbf := create_block(f, tprint("%.si.unfold.false", vname(si)), end_bb);
        array_add(new_bbs, nbt); array_add(new_bbs, nbf);
        f_to_end := create_br(end_bb);
        block_append_inst(nbf, f_to_end);
        bi := create_cond_br(op(si, 0), end_bb, nbf);
        block_append_inst(nbt, bi);
        loc := get_metadata(si, 0);
        set_metadata(f_to_end, 0, loc);
        set_metadata(bi, 0, loc);
        set_metadata(bi, md_kind_id("prof"), get_metadata(si, md_kind_id("prof")));
        ups := Dom_Update.[.{true, nbt, nbf}, .{true, nbt, end_bb}, .{true, nbf, end_bb}];
        dtu_apply(d.dtu, ups);
        tv := op(si, 1); fv := op(si, 2);
        npt := create_phi(vtype(si_use), 1);
        insert_at_position(npt, nbt, block(nbt).first, true);
        set_name(npt, tprint("%.si.unfold.phi", vname(tv)));
        npf := create_phi(vtype(si_use), 1);
        insert_at_position(npf, nbf, block(nbf).first, true);
        set_name(npf, tprint("%.si.unfold.phi", vname(fv)));
        phi_add_incoming(npt, tv, start);
        phi_add_incoming(npf, fv, nbt);
        if is_inst(tv) && inst_op(tv) == .SELECT array_add(new_sis, .{tv, npt});
        if is_inst(fv) && inst_op(fv) == .SELECT array_add(new_sis, .{fv, npf});
        phi_add_incoming(si_use, npt, nbt);
        phi_add_incoming(si_use, npf, nbf);
        phi_remove_incoming_block(si_use, start);
        for p: block_insts(end_bb) {
            if inst_op(p) != .PHI break;
            if p == si_use continue;
            phi_add_incoming(p, phi_incoming_value_for_block(p, start), nbt);
            phi_add_incoming(p, phi_incoming_value_for_block(p, start), nbf);
            phi_remove_incoming_block(p, start);
        }
        cb := block_terminator(start);
        k: u32 = ifx get_successor(cb, 1) == end_bb then cast(u32) 1 else 0;
        set_successor(cb, k, nbt);
        ups2 := Dom_Update.[.{false, start, end_bb}, .{true, start, nbt}];
        dtu_apply(d.dtu, ups2);
    }
    l := li_loop_for(d.li, start);
    if l != NONE for new_bbs.* li_add_basic_block_to_loop(d.li, l, it);
    erase_inst_with_metadata(si);
}


dfa_unfold_select_instrs :: (d: *Dfa, sels: [] Dfa_Select) {
    stack: [..] Dfa_Select; stack.allocator = temp;
    for sels array_add(*stack, it);
    while stack.count {
        s := pop(*stack);
        new_sis: [..] Dfa_Select; new_sis.allocator = temp;
        new_bbs: [..] Value_Id; new_bbs.allocator = temp;
        dfa_unfold(d, s, *new_sis, *new_bbs);
        for new_sis array_add(*stack, it);
    }
}

// ---------------------------------------------------------------- MainSwitch

Dfa_Main_Switch :: struct {
    instr: Value_Id = NONE;
    selects: [..] Dfa_Select;
}

dfa_is_valid_select_inst :: (ms: *Dfa_Main_Switch, si: Value_Id) -> bool {
    if !has_one_use(si) return false;
    u := ir.v_first_use[si];
    usr := ir.u_user[u];
    if !is_inst(usr) || (inst_op(usr) != .PHI && inst_op(usr) != .SELECT) return false;
    sibb := inst_block(si);
    t := block_terminator(sibb);
    if inst_op(t) != .BR return false;
    if inst_op(usr) == .PHI && phi_block(usr, cast(u32) (u - ir.v_ops[usr])) != sibb return false;
    for prev: ms.selects {
        psi := prev.si;
        if op(psi, 1) != si && op(psi, 2) != si && inst_block(psi) == inst_block(si) return false;
    }
    return true;
}

dfa_is_candidate :: (d: *Dfa, ms: *Dfa_Main_Switch, sw: Value_Id) -> bool {
    Q_Item :: struct { v: Value_Id; bb: Value_Id; }
    q: [..] Q_Item; q.allocator = temp;
    qhead := 0;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    ms.selects.count = 0;
    cond := sw_cond(sw);
    if !is_inst(cond) || inst_op(cond) != .PHI return false;
    l := li_loop_for(d.li, inst_block(sw));
    if l == NONE return false;
    add :: (q: *[..] Q_Item, seen: *Table(Value_Id, bool), v: Value_Id, bb: Value_Id) {
        if table_contains(seen, v) return;
        table_set(seen, v, true);
        array_add(q, .{v, bb});
    }
    add(*q, *seen, cond, NONE);
    while qhead < q.count {
        cur := q[qhead].v; cur_bb := q[qhead].bb;
        qhead += 1;
        if is_inst(cur) && inst_op(cur) == .PHI {
            n := nops(cur);
            if n > 0 for k: 0..n - 1 {
                ib := phi_block(cur, k);
                add(*q, *seen, phi_incoming_value_for_block(cur, ib), ib);
            }
        } else if is_inst(cur) && inst_op(cur) == .SELECT {
            if !dfa_is_valid_select_inst(ms, cur) return false;
            add(*q, *seen, op(cur, 1), cur_bb);
            add(*q, *seen, op(cur, 2), cur_bb);
            usr := ir.u_user[ir.v_first_use[cur]];
            if inst_op(usr) == .PHI array_add(*ms.selects, .{cur, usr});
        } else if is_constant_kind(vkind(cur)) {
            continue;
        } else {
            if dfa_opts.early_exit_heuristic {
                cl := ifx cur_bb != NONE then li_loop_for(d.li, cur_bb) else NONE;
                if li_contains_loop(d.li, l, cl) return false;
            }
        }
    }
    return true;
}

// ---------------------------------------------------------------- AllSwitchPaths

Dfa_Switch_Paths :: struct {
    d: *Dfa;
    sw: Value_Id;
    sw_bb: Value_Id;
    outer: Loop_Id;
    tpaths: [..] Dfa_Path;
    num_visited: s64;
}

Dfa_Visited :: Table(Value_Id, bool);

// paths(BB, ToBB, Visited, PathDepth, PathsLimit)
dfa_paths :: (sp: *Dfa_Switch_Paths, bb: Value_Id, to_bb: Value_Id, visited: *Dfa_Visited, depth: s64, limit: s64) -> [..] [..] Value_Id {
    res: [..] [..] Value_Id; res.allocator = temp;
    if depth > dfa_opts.max_path_length return res;
    table_set(visited, bb, true);
    sp.num_visited += 1;
    if sp.num_visited > dfa_opts.max_num_visited_paths return res;
    li := sp.d.li;
    if !li_contains(li, sp.outer, bb) return res;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    seen: [..] Value_Id; seen.allocator = temp;
    for succ: succs {
        if res.count >= limit break;
        if block_set_contains(seen, succ) continue;
        array_add(*seen, succ);
        if succ == to_bb {
            p: [..] Value_Id; p.allocator = temp;
            array_add(*p, bb); array_add(*p, to_bb);
            array_add(*res, p);
            continue;
        }
        if table_contains(visited, succ) continue;
        cl := li_loop_for(li, bb);
        if succ == li_header(li, cl) continue;
        if li_loop_for(li, succ) != cl continue;
        sub := dfa_paths(sp, succ, to_bb, visited, depth + 1, limit - res.count);
        for * p: sub {
            dfa_path_push_front(p, bb);
            array_add(*res, p.*);
        }
    }
    table_remove(visited, bb);
    return res;
}

// getStateDefMap: block -> phi
dfa_get_state_def_map :: (sp: *Dfa_Switch_Paths) -> Table(Value_Id, Value_Id) {
    res: Table(Value_Id, Value_Id); res.allocator = temp;
    multi: [..] Value_Id; multi.allocator = temp;
    first := sw_cond(sp.sw);
    stack: [..] Value_Id; stack.allocator = temp;
    array_add(*stack, first);
    seen: Table(Value_Id, bool); seen.allocator = temp;
    while stack.count {
        cur := pop(*stack);
        def_bb := inst_block(cur);
        if table_contains(*res, def_bb) { if !block_set_contains(multi, def_bb) array_add(*multi, def_bb); }
        else table_set(*res, def_bb, cur);
        table_set(*seen, cur, true);
        n := nops(cur);
        if n > 0 for k: 0..n - 1 {
            ib := phi_block(cur, k);
            ip := phi_incoming_value_for_block(cur, ib);
            if !is_inst(ip) || inst_op(ip) != .PHI continue;
            outside := !li_contains(sp.d.li, sp.outer, ib);
            if table_contains(*seen, ip) || outside continue;
            array_add(*stack, ip);
        }
    }
    for multi table_remove(*res, it);
    return res;
}

// getPathsFromStateDefMap
dfa_paths_from_state_def_map :: (sp: *Dfa_Switch_Paths, state_def: *Table(Value_Id, Value_Id), phi: Value_Id, vb: *Dfa_Visited, limit: s64) -> [..] Dfa_Path {
    res: [..] Dfa_Path; res.allocator = temp;
    phi_bb := inst_block(phi);
    table_set(vb, phi_bb, true);
    unique: [..] Value_Id; unique.allocator = temp;
    n := nops(phi);
    if n > 0 for k: 0..n - 1 {
        ib := phi_block(phi, k);
        if res.count >= limit break;
        if block_set_contains(unique, ib) continue;
        array_add(*unique, ib);
        if !li_contains(sp.d.li, sp.outer, ib) continue;
        iv := phi_incoming_value_for_block(phi, ib);
        if isa_constant_int(iv) {
            if phi_bb == sp.sw_bb && sp.sw_bb != inst_block(sw_cond(sp.sw)) continue;
            np: Dfa_Path; np.path.allocator = temp;
            np.dbb = phi_bb; np.exit_val = const_ap(iv); np.exit_set = true;
            if ib != sp.sw_bb {
                if table_contains(vb, ib) continue;
                array_add(*np.path, ib);
            }
            array_add(*np.path, phi_bb);
            array_add(*res, np);
            continue;
        }
        if table_contains(vb, ib) || ib == sp.sw_bb continue;
        if !is_inst(iv) || inst_op(iv) != .PHI continue;
        ip_def := inst_block(iv);
        if !table_contains(state_def, ip_def) continue;
        if ip_def == ib {
            pred := dfa_paths_from_state_def_map(sp, state_def, iv, vb, limit - res.count);
            for * p: pred { array_add(*p.path, phi_bb); array_add(*res, p.*); }
            continue;
        }
        if table_contains(vb, ip_def) continue;
        inter_limit := limit - res.count;
        inter := dfa_paths(sp, ip_def, ib, vb, 1, inter_limit);
        if inter.count == 0 continue;
        pred_limit := inter_limit / inter.count;
        pred := dfa_paths_from_state_def_map(sp, state_def, iv, vb, pred_limit);
        for p: pred {
            for ipath: inter {
                np := dfa_path_copy(p);
                for x: 1..ipath.count - 1 array_add(*np.path, ipath[x]);
                array_add(*np.path, phi_bb);
                array_add(*res, np);
            }
        }
    }
    table_remove(vb, phi_bb);
    return res;
}

// findTPaths
dfa_find_tpaths :: (sp: *Dfa_Switch_Paths) {
    state_def := dfa_get_state_def_map(sp);
    if state_def.count == 0 return;
    sw_phi := sw_cond(sp.sw);
    sw_phi_bb := inst_block(sw_phi);
    vb: Dfa_Visited; vb.allocator = temp;
    to_def := dfa_paths_from_state_def_map(sp, *state_def, sw_phi, *vb, dfa_opts.max_num_paths);
    if sw_phi_bb == sp.sw_bb || to_def.count == 0 { sp.tpaths = to_def; return; }
    limit := dfa_opts.max_num_paths / to_def.count;
    to_sw := dfa_paths(sp, sw_phi_bb, sp.sw_bb, *vb, 1, limit);
    if to_sw.count == 0 return;
    temp_list: [..] Dfa_Path; temp_list.allocator = temp;
    for p: to_def {
        for psw: to_sw {
            clash := false;
            for x: 1..psw.count - 1 if block_set_contains(p.path, psw[x]) { clash = true; break; }
            if clash continue;
            np := dfa_path_copy(p);
            for x: 1..psw.count - 1 array_add(*np.path, psw[x]);
            array_add(*temp_list, np);
        }
    }
    sp.tpaths = temp_list;
}

// getNextCaseSuccessor
dfa_next_case_successor :: (sw: Value_Id, state: APInt) -> Value_Id {
    n := sw_num_cases(sw);
    if n > 0 for k: 0..n - 1 if ap_eq(const_ap(sw_case_value(sw, k)), state) return sw_case_dest(sw, k);
    return sw_default(sw);
}

// unifyTPaths
dfa_unify_tpaths :: (sp: *Dfa_Switch_Paths) {
    dest_to_state: Table(Value_Id, APInt); dest_to_state.allocator = temp;
    for * p: sp.tpaths {
        ns := p.exit_val;
        dest := dfa_next_case_successor(sp.sw, ns);
        found, st := table_find(*dest_to_state, dest);
        if !found { table_set(*dest_to_state, dest, ns); continue; }
        if !ap_eq(ns, st) p.exit_val = st;
    }
}

// ---------------------------------------------------------------- TransformDFA

Dfa_Clone :: struct { bb: Value_Id; state: APInt; }
Dfa_Dup_Map :: Table(Value_Id, [..] Dfa_Clone);

dfa_get_cloned_bb :: (m: *Dfa_Dup_Map, bb: Value_Id, state: APInt) -> Value_Id {
    l := table_find_pointer(m, bb);
    if !l return NONE;
    for l.* if ap_eq(it.state, state) return it.bb;
    return NONE;
}
dfa_dup_push :: (m: *Dfa_Dup_Map, order: *[..] Value_Id, bb: Value_Id, c: Dfa_Clone) {
    l := table_find_pointer(m, bb);
    if !l {
        e: [..] Dfa_Clone; e.allocator = temp;
        table_set(m, bb, e);
        l = table_find_pointer(m, bb);
        if order array_add(order, bb);
    }
    array_add(l, c);
}

Dfa_Metrics :: struct { not_duplicatable: bool; convergent: bool; num_insts: Cost; }
dfa_analyze_basic_block :: (m: *Dfa_Metrics, t: *Tti, b: Value_Id, eph: *Table(Value_Id, bool)) {
    for i: block_insts(b) {
        if table_contains(eph, i) continue;
        if type_kind(vtype(i)) == .TOKEN && call_iid(i) == NOT_INTRINSIC {
            u := ir.v_first_use[i];
            while u != NONE {
                user := ir.u_user[u];
                ub := inst_block(user);
                if inst_op(user) == .PHI ub = ir.u_aux[u];
                if ub != b { m.not_duplicatable = true; break; }
                u = ir.u_next[u];
            }
        } else if type_kind(vtype(i)) == .TOKEN {
            id := call_iid(i);
            n := iid_name(id);
            if !begins_with(n, "llvm.experimental.convergence.") {
                u := ir.v_first_use[i];
                while u != NONE {
                    user := ir.u_user[u];
                    ub := inst_block(user);
                    if inst_op(user) == .PHI ub = ir.u_aux[u];
                    if ub != b { m.not_duplicatable = true; break; }
                    u = ir.u_next[u];
                }
            }
        }
        if is_call_base(i) {
            if call_has_fn_attr(i, .NoDuplicate) m.not_duplicatable = true;
            if call_is_convergent(i) {
                if call_num_bundles(i) > 0 && call_has_bundle(i, "convergencectrl") fatal("dfa-jump-threading: convergence control tokens are not supported yet");
                m.convergent = true;
            }
        }
        m.num_insts = cost_add(m.num_insts, tti_instruction_cost(t, i, TCK_CODE_SIZE));
    }
    term := block_terminator(b);
    if term != NONE && inst_op(term) == .INDIRECTBR m.not_duplicatable = true;
}


Dfa_Transform :: struct {
    d: *Dfa;
    sp: *Dfa_Switch_Paths;
    eph: *Table(Value_Id, bool);
}

// isLegalAndProfitableToTransform
dfa_is_legal_and_profitable :: (tr: *Dfa_Transform) -> bool {
    m: Dfa_Metrics;
    num_cloned: u64 = 0;
    sw := tr.sp.sw;
    if num_successors(sw) <= 1 return false;
    dup: Dfa_Dup_Map; dup.allocator = temp;
    order: [..] Value_Id; order.allocator = temp;
    for * tp: tr.sp.tpaths {
        ns := tp.exit_val;
        det := tp.dbb;
        bb := tr.sp.sw_bb;
        if dfa_get_cloned_bb(*dup, bb, ns) == NONE {
            dfa_analyze_basic_block(*m, tr.d.tti, bb, tr.eph);
            num_cloned += cast(u64) block_inst_count(bb);
            dfa_dup_push(*dup, *order, bb, .{bb, ns});
        }
        if tp.path[0] == det continue;
        start := -1;
        for tp.path if it == det { start = it_index; break; }
        if start >= 0 for k: start..tp.path.count - 1 {
            bb = tp.path[k];
            if dfa_get_cloned_bb(*dup, bb, ns) != NONE continue;
            dfa_analyze_basic_block(*m, tr.d.tti, bb, tr.eph);
            num_cloned += cast(u64) block_inst_count(bb);
            dfa_dup_push(*dup, *order, bb, .{bb, ns});
        }
        if m.not_duplicatable return false;
        if m.convergent return false;
        if !cost_valid(m.num_insts) return false;
    }
    num_orig: u64 = 0;
    num_outer: u64 = 0;
    for bb: order {
        num_orig += cast(u64) block_inst_count(bb);
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for s: succs if !table_contains(*dup, s) && block_single_predecessor(s) != NONE num_outer += 1;
    }
    if cast(float64) num_cloned / cast(float64) num_orig > dfa_opts.max_cloned_rate return false;
    if num_outer > cast(u64) dfa_opts.max_outer_use_blocks return false;
    _, jt_size := tti_estimated_number_of_case_clusters(tr.d.tti, sw);
    cost: s64;
    if jt_size == 0 {
        ns := num_successors(sw);
        cond_branches := cast(s64) (64 - count_leading_zeroes_u64(cast(u64) ns - 1));   // APInt(32, N).ceilLogBase2()
        cost = m.num_insts / cond_branches;
    } else {
        cost = m.num_insts / cast(s64) jt_size;
    }
    if cost > dfa_opts.cost_threshold return false;
    return true;
}

dfa_is_predecessor :: (bb: Value_Id, incoming: Value_Id) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    return block_set_contains(preds, incoming);
}

// updatePredecessor
dfa_update_predecessor :: (tr: *Dfa_Transform, prev: Value_Id, old: Value_Id, nb: Value_Id) {
    if !dfa_is_predecessor(old, prev) return;
    t := block_terminator(prev);
    n := num_successors(t);
    for k: 0..n - 1 {
        if get_successor(t, k) == old {
            block_remove_predecessor(old, prev, true);
            set_successor(t, k, nb);
        }
    }
    ups := Dom_Update.[.{false, prev, old}, .{true, prev, nb}];
    dtu_apply(tr.d.dtu, ups);
}

// updateSuccessorPhis
dfa_update_successor_phis :: (tr: *Dfa_Transform, bb: Value_Id, cloned: Value_Id, ns: APInt, vm: *Value_Map, dup: *Dfa_Dup_Map) {
    to_update: [..] Value_Id; to_update.allocator = temp;
    if bb == tr.sp.sw_bb {
        nc := dfa_next_case_successor(tr.sp.sw, ns);
        array_add(*to_update, nc);
        cs := dfa_get_cloned_bb(dup, nc, ns);
        if cs != NONE array_add(*to_update, cs);
    } else {
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for s: succs {
            array_add(*to_update, s);
            cs := dfa_get_cloned_bb(dup, s, ns);
            if cs != NONE array_add(*to_update, cs);
        }
    }
    for s: to_update {
        for p: block_insts(s) {
            if inst_op(p) != .PHI break;
            inc := phi_incoming_value_for_block(p, bb);
            if inc == NONE continue;
            if is_constant_kind(vkind(inc)) { phi_add_incoming(p, inc, cloned); continue; }
            cv := vmap_get(vm, inc);
            phi_add_incoming(p, ifx cv != NONE then cv else inc, cloned);
        }
    }
}

Dfa_Def :: struct { orig: Value_Id; clones: [..] Value_Id; }

// updateDefMap
dfa_update_def_map :: (defs: *[..] Dfa_Def, def_index: *Table(Value_Id, s32), vm: *Value_Map) {
    Pair :: struct { a: Value_Id; b: Value_Id; }
    pairs: [..] Pair; pairs.allocator = temp;
    for v, k: vm.map {
        if !is_inst(k) || v == NONE continue;
        o := inst_op(k);
        if o == .BR || o == .CONDBR || o == .SWITCH continue;
        if !is_inst(v) continue;
        array_add(*pairs, .{k, v});
    }
    for i: 1..pairs.count - 1 {
        x := pairs[i];
        j := i - 1;
        while j >= 0 && (ifx x.a == pairs[j].a then comes_before(x.b, pairs[j].b) else comes_before(x.a, pairs[j].a)) {
            pairs[j + 1] = pairs[j]; j -= 1;
        }
        pairs[j + 1] = x;
    }
    for pairs {
        found, k := table_find(def_index, it.a);
        if !found {
            k = cast(s32) defs.count;
            d: Dfa_Def; d.orig = it.a; d.clones.allocator = temp;
            array_add(defs, d);
            table_set(def_index, it.a, k);
        }
        array_add(*defs.*[k].clones, it.b);
    }
}

// cloneBlockAndUpdatePredecessor
dfa_clone_block :: (tr: *Dfa_Transform, bb: Value_Id, prev: Value_Id, ns: APInt, dup: *Dfa_Dup_Map, defs: *[..] Dfa_Def, def_index: *Table(Value_Id, s32)) -> Value_Id {
    vm: Value_Map; vmap_init(*vm);
    nb := clone_basic_block(bb, *vm, tprint(".jt%", ap_limited(ns)), block_fn(bb));
    block_move_after(nb, bb);
    scopes: [..] Md_Id; scopes.allocator = temp;
    nbs := Value_Id.[nb];
    identify_no_alias_scopes_to_clone(nbs, *scopes);
    clone_and_adapt_no_alias_scopes(scopes, nbs, "dfa");
    for i: block_insts(nb) {
        if inst_op(i) == .PHI continue;
        remap_dbg_record_range(*vm, i, RF_IGNORE_MISSING_LOCALS | RF_NO_MODULE_LEVEL_CHANGES);
        remap_instruction(*vm, i, RF_IGNORE_MISSING_LOCALS | RF_NO_MODULE_LEVEL_CHANGES);
        if call_iid(i) == IID_ASSUME ac_register_assumption(tr.d.ac, i);
    }
    dfa_update_successor_phis(tr, bb, nb, ns, *vm, dup);
    dfa_update_predecessor(tr, prev, bb, nb);
    dfa_update_def_map(defs, def_index, *vm);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(nb, *succs);
    seen: [..] Value_Id; seen.allocator = temp;
    for s: succs {
        if block_set_contains(seen, s) continue;
        array_add(*seen, s);
        dtu_apply1(tr.d.dtu, true, nb, s);
    }
    return nb;
}

// createExitPath
dfa_create_exit_path :: (tr: *Dfa_Transform, defs: *[..] Dfa_Def, def_index: *Table(Value_Id, s32), tp: *Dfa_Path, dup: *Dfa_Dup_Map, to_clean: *[..] Value_Id) {
    ns := tp.exit_val;
    det := tp.dbb;
    path: [..] Value_Id; path.allocator = temp;
    for tp.path array_add(*path, it);
    if path[0] == det array_ordered_remove_by_index(*path, 0);
    det_i := -1;
    for path if it == det { det_i = it_index; break; }
    prev := ifx path.count == 1 then path[det_i] else path[det_i - 1];
    for k: det_i..path.count - 1 {
        bb := path[k];
        if !block_set_contains(to_clean.*, bb) array_add(to_clean, bb);
        nb := dfa_get_cloned_bb(dup, bb, ns);
        if nb != NONE {
            dfa_update_predecessor(tr, prev, bb, nb);
            prev = nb;
            continue;
        }
        nb = dfa_clone_block(tr, bb, prev, ns, dup, defs, def_index);
        dfa_dup_push(dup, null, bb, .{nb, ns});
        if !block_set_contains(to_clean.*, nb) array_add(to_clean, nb);
        prev = nb;
    }
}

// updateLastSuccessor
dfa_update_last_successor :: (tr: *Dfa_Transform, tp: *Dfa_Path, dup: *Dfa_Dup_Map) {
    ns := tp.exit_val;
    bb := tp.path[tp.path.count - 1];
    last := dfa_get_cloned_bb(dup, bb, ns);
    sw := block_terminator(last);
    if inst_op(sw) != .SWITCH return;
    nc := dfa_next_case_successor(sw, ns);
    ups: [..] Dom_Update; ups.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(last, *succs);
    seen: [..] Value_Id; seen.allocator = temp;
    for s: succs if s != nc && !block_set_contains(seen, s) { array_add(*seen, s); array_add(*ups, .{false, last, s}); }
    loc := get_metadata(sw, 0);
    recs := inst(sw).records; inst(sw).records = 0;
    erase_inst_with_metadata(sw);
    br := create_br(nc);
    block_append_inst(last, br);
    attach_records_before(br, recs);
    set_metadata(br, 0, loc);
    dtu_apply(tr.d.dtu, ups);
}

// cleanPhiNodes
dfa_clean_phi_nodes :: (bb: Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    if preds.count == 0 {
        i := block(bb).first;
        while i != NONE && inst_op(i) == .PHI {
            nx := inst(i).next;
            rauw_with_metadata(i, const_poison(vtype(i)));
            erase_inst_with_metadata(i);
            i = nx;
        }
        return;
    }
    i := block(bb).first;
    while i != NONE && inst_op(i) == .PHI {
        nx := inst(i).next;
        not_pred :: (p: Value_Id, idx: u32, data: *void) -> bool {
            return !dfa_is_predecessor(inst_block(p), phi_block(p, idx));
        }
        phi_remove_incoming_if(i, not_pred, null);
        i = nx;
    }
}

// SSAUpdaterBulk::RewriteAllUses with the variables of updateSSA
Dfa_Ssa_Var :: struct { name: string; ty: Type_Id; defs_bb: [..] Value_Id; defs_v: [..] Value_Id; uses: [..] Use_Id; }

dfa_ssa_rewrite_all_uses :: (vars: [] Dfa_Ssa_Var, dt: *Dom_Tree) {
    pred_cache: Table(Value_Id, [..] Value_Id); pred_cache.allocator = temp;
    preds_of :: (cache: *Table(Value_Id, [..] Value_Id), bb: Value_Id) -> [] Value_Id {
        p := table_find_pointer(cache, bb);
        if p return p.*;
        l: [..] Value_Id; l.allocator = temp;
        block_predecessors(bb, *l);
        table_set(cache, bb, l);
        return l;
    }
    user_bb :: (u: Use_Id) -> Value_Id {
        usr := ir.u_user[u];
        if inst_op(usr) == .PHI return phi_block(usr, cast(u32) (u - ir.v_ops[usr]));
        return inst_block(usr);
    }
    for * r: vars {
        Info :: struct { live_in: Value_Id = NONE; live_out: Value_Id = NONE; }
        infos: Table(Value_Id, Info); infos.allocator = temp;
        def_set: Table(Value_Id, bool); def_set.allocator = temp;
        def_list: [..] Value_Id; def_list.allocator = temp;
        for r.defs_bb if !table_contains(*def_set, it) { table_set(*def_set, it, true); array_add(*def_list, it); }
        using_set: Table(Value_Id, bool); using_set.allocator = temp;
        using_list: [..] Value_Id; using_list.allocator = temp;
        for r.uses { b := user_bb(it); if !table_contains(*using_set, b) { table_set(*using_set, b, true); array_add(*using_list, b); } }
        // ComputeLiveInBlocks
        live_in: Table(Value_Id, bool); live_in.allocator = temp;
        wl: [..] Value_Id; wl.allocator = temp;
        for using_list array_add(*wl, it);
        while wl.count {
            bb := pop(*wl);
            if table_contains(*live_in, bb) continue;
            table_set(*live_in, bb, true);
            for p: preds_of(*pred_cache, bb) {
                if table_contains(*def_set, p) continue;
                array_add(*wl, p);
            }
        }
        idf: [..] Value_Id; idf.allocator = temp;
        idf_calculate(dt, def_list, *def_set, *live_in, *idf);
        for r.defs_bb {
            p := table_find_pointer(*infos, it);
            if !p { table_set(*infos, it, .{}); p = table_find_pointer(*infos, it); }
            p.live_out = r.defs_v[it_index];
        }
        for fb: idf {
            pn := create_phi(r.ty, 0);
            insert_at_position(pn, fb, block(fb).first, true);
            if r.name.count set_name(pn, r.name);
            p := table_find_pointer(*infos, fb);
            if !p { table_set(*infos, fb, .{}); p = table_find_pointer(*infos, fb); }
            p.live_in = pn;
        }
        compute_value :: (infos: *Table(Value_Id, Info), cache: *Table(Value_Id, [..] Value_Id), dt: *Dom_Tree, bb_in: Value_Id, is_live_out: bool, ty: Type_Id) -> Value_Id {
            get :: (infos: *Table(Value_Id, Info), b: Value_Id) -> *Info {
                p := table_find_pointer(infos, b);
                if !p { table_set(infos, b, .{}); p = table_find_pointer(infos, b); }
                return p;
            }
            bb := bb_in;
            info := get(infos, bb);
            if is_live_out && info.live_out != NONE return info.live_out;
            if info.live_in != NONE return info.live_in;
            stack: [..] Value_Id; stack.allocator = temp;
            array_add(*stack, bb);
            v: Value_Id = NONE;
            while dt_is_reachable_from_entry(dt, bb) && preds_of(cache, bb).count > 0 {
                id := dt_idom_block(dt, bb);
                if id == NONE break;
                bb = id;
                info = get(infos, bb);
                if info.live_out != NONE { v = info.live_out; break; }
                if info.live_in != NONE { v = info.live_in; break; }
                array_add(*stack, bb);
            }
            if v == NONE v = const_undef(ty);
            for stack get(infos, it).live_in = v;
            return v;
        }
        for bb: idf {
            pn := block(bb).first;
            for p: preds_of(*pred_cache, bb) phi_add_incoming(pn, compute_value(*infos, *pred_cache, dt, p, true, r.ty), p);
        }
        processed: Table(Use_Id, bool); processed.allocator = temp;
        for u: r.uses {
            if table_contains(*processed, u) continue;
            table_set(*processed, u, true);
            usr := ir.u_user[u];
            bb := user_bb(u);
            v := compute_value(*infos, *pred_cache, dt, bb, bb != inst_block(usr), r.ty);
            old := ir.u_val[u];
            if old != v value_is_rauwd_handles(old, v);
            set_op(usr, cast(u32) (u - ir.v_ops[usr]), v);
        }
    }
}
// ValueHandleBase::ValueIsRAUWd(Old, New) when Old has value handles
value_is_rauwd_handles :: (old: Value_Id, new: Value_Id) { value_is_rauwd(old, new); }

// updateSSA
dfa_update_ssa :: (tr: *Dfa_Transform, defs: [] Dfa_Def) {
    vars: [..] Dfa_Ssa_Var; vars.allocator = temp;
    to_rename: [..] Use_Id; to_rename.allocator = temp;
    for d: defs {
        i := d.orig;
        bb := inst_block(i);
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if inst_op(usr) == .PHI {
                if phi_block(usr, cast(u32) (u - ir.v_ops[usr])) != bb array_add(*to_rename, u);
            } else if inst_block(usr) != bb array_add(*to_rename, u);
            u = ir.u_next[u];
        }
        if to_rename.count == 0 continue;
        v: Dfa_Ssa_Var;
        v.name = vname(i); v.ty = vtype(i);
        v.defs_bb.allocator = temp; v.defs_v.allocator = temp; v.uses.allocator = temp;
        array_add(*v.defs_bb, bb); array_add(*v.defs_v, i);
        for c: d.clones { array_add(*v.defs_bb, inst_block(c)); array_add(*v.defs_v, c); }
        while to_rename.count array_add(*v.uses, pop(*to_rename));
        array_add(*vars, v);
    }
    dt := dtu_get_dom_tree(tr.d.dtu);
    dfa_ssa_rewrite_all_uses(vars, dt);
}

// createAllExitPaths
dfa_create_all_exit_paths :: (tr: *Dfa_Transform) {
    sw_bb := tr.sp.sw_bb;
    for * tp: tr.sp.tpaths dfa_path_push_front(*tp.path, sw_bb);
    dup: Dfa_Dup_Map; dup.allocator = temp;
    defs: [..] Dfa_Def; defs.allocator = temp;
    def_index: Table(Value_Id, s32); def_index.allocator = temp;
    to_clean: [..] Value_Id; to_clean.allocator = temp;   // SmallPtrSet: cleanPhiNodes does not depend on the order
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(sw_bb, *succs);
    for succs if !block_set_contains(to_clean, it) array_add(*to_clean, it);
    for * tp: tr.sp.tpaths dfa_create_exit_path(tr, *defs, *def_index, tp, *dup, *to_clean);
    for * tp: tr.sp.tpaths dfa_update_last_successor(tr, tp, *dup);
    dfa_update_ssa(tr, defs);
    for to_clean dfa_clean_phi_nodes(it);
}

dfa_jump_threading_run :: (f: Value_Id) -> Preserved {
    d: Dfa;
    d.f = f;
    d.ac = get_assumption_cache(f);
    dt := get_domtree(f);
    d.li = get_loop_info(f);
    d.tti = tti_get(f);
    // DFAJumpThreading::run: the analyses (LoopInfo updates the DT's DFS numbers) are requested before this check
    if fn_has_fn_attr(f, .OptimizeForSize) || fn_has_fn_attr(f, .MinSize) return PRESERVE_ALL;
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    d.dtu = *dtu;
    made := false;
    threadable: [..] *Dfa_Switch_Paths; threadable.allocator = temp;
    bb := fn_entry(f);
    while bb != NONE {
        defer bb = block(bb).next;
        sw := block_terminator(bb);
        if sw == NONE || inst_op(sw) != .SWITCH continue;
        ms: Dfa_Main_Switch; ms.selects.allocator = temp;
        if dfa_is_candidate(*d, *ms, sw) ms.instr = sw;
        if ms.instr == NONE continue;
        dfa_unfold_select_instrs(*d, ms.selects);
        if ms.selects.count made = true;
        sp := New(Dfa_Switch_Paths,, allocator = temp);
        sp.d = *d; sp.sw = sw; sp.sw_bb = inst_block(sw);
        sp.outer = li_outermost(d.li, li_loop_for(d.li, bb));
        sp.tpaths.allocator = temp;
        dfa_find_tpaths(sp);
        dfa_unify_tpaths(sp);
        if sp.tpaths.count > 0 { array_add(*threadable, sp); break; }
    }
    dtu_get_dom_tree(*dtu);   // LI->verify(DTU->getDomTree()) in a release build: only the DTU flush
    eph: Table(Value_Id, bool); eph.allocator = temp;
    if threadable.count > 0 collect_ephemeral_values_fn(f, d.ac, *eph);
    for sp: threadable {
        tr: Dfa_Transform;
        tr.d = *d; tr.sp = sp; tr.eph = *eph;
        if dfa_is_legal_and_profitable(*tr) {
            dfa_create_all_exit_paths(*tr);
            made = true;
            d.loop_info_broken = true;
        }
    }
    dtu_flush(*dtu);
    if !made return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    if !d.loop_info_broken preserve(*pa, .LOOPS);
    return pa;
}
