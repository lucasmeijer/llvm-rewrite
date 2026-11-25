// StructurizeCFGPass: a port of llvm/lib/Transforms/Scalar/StructurizeCFG.cpp, with SSAUpdater::
// RewriteUseAfterInsertions and SSAUpdaterBulk::RewriteAndOptimizeAllUses (simplifyPass, deduplicatePass,
// EliminateNewDuplicatePHINodes: llvm/lib/Transforms/Utils/SSAUpdaterBulk.cpp; RewriteAllUses is
// pass_dfa_jump_threading.jai's) and the scc_iterator over the region node subgraph
// (llvm/include/llvm/ADT/SCCIterator.h). RegionInfo is region_info.jai.
//
// Not ported (fails loudly): `structurizecfg<skip-uniform-regions>` / -structurizecfg-skip-uniform-regions
// (UniformityInfo).
//
// Address order: every DenseMap / SmallPtrSet keyed by pointers is only used for lookups, or iterated where the
// result does not depend on the order (insertConditions' predicate walk: the parent's entry makes the other
// values dead; mergeIfCompatible's reassigned incoming list: a map from block to value; simplifyConditions:
// independent folds; deduplicatePass: per block). The containers below are kept in insertion order.

Scz_Pred :: struct { pred: Value_Id; has_w: bool; tw: u32; fw: u32; }
Scz_Bbp :: struct { keys: [..] Value_Id; vals: [..] Scz_Pred; }   // BBPredicates
Scz_Bv :: struct { bb: Value_Id; v: Value_Id; }
Scz_Phi_Entry :: struct { phi: Value_Id; inc: [..] Scz_Bv; }
Scz_Phi_Map :: struct { entries: [..] Scz_Phi_Entry; }           // PhiMap (MapVector)
Scz_Added :: struct { to: Value_Id; from: [..] Value_Id; }

Scz :: struct {
    f: Value_Id;
    ri: *Region_Info;
    pr: Region_Id;             // ParentRegion
    dt: *Dom_Tree;
    tti: *Tti;
    order: [..] Rn_Id;
    visited: Table(Value_Id, bool);
    flow_set: Table(Value_Id, bool);
    affected_phis: [..] Value_Id;
    deleted_phis: Table(Value_Id, *Scz_Phi_Map);
    added_phis: [..] Scz_Added;
    predicates: Table(Value_Id, *Scz_Bbp);
    loop_preds: Table(Value_Id, *Scz_Bbp);
    conditions: [..] Value_Id;
    loops: Table(Value_Id, Value_Id);
    loop_conds: [..] Value_Id;
    hoisted_values: Table(Value_Id, Value_Id);
    prev_node: Rn_Id = -1;
}

scz_bbp :: (m: *Table(Value_Id, *Scz_Bbp), bb: Value_Id) -> *Scz_Bbp {
    found, p := table_find(m, bb);
    if found return p;
    p = New(Scz_Bbp,, allocator = temp);
    p.keys.allocator = temp; p.vals.allocator = temp;
    table_set(m, bb, p);
    return p;
}
scz_bbp_find :: (p: *Scz_Bbp, bb: Value_Id) -> s64 { for p.keys if it == bb return it_index; return -1; }
scz_bbp_set :: (p: *Scz_Bbp, bb: Value_Id, v: Scz_Pred) {
    k := scz_bbp_find(p, bb);
    if k >= 0 { p.vals[k] = v; return; }
    array_add(*p.keys, bb); array_add(*p.vals, v);
}
scz_pred_const :: (c: Value_Id) -> Scz_Pred { r: Scz_Pred; r.pred = c; return r; }

scz_phi_map :: (s: *Scz, bb: Value_Id) -> *Scz_Phi_Map {
    found, p := table_find(*s.deleted_phis, bb);
    if found return p;
    p = New(Scz_Phi_Map,, allocator = temp);
    p.entries.allocator = temp;
    table_set(*s.deleted_phis, bb, p);
    return p;
}
// PhiMap::operator[]
scz_phi_map_get :: (m: *Scz_Phi_Map, phi: Value_Id) -> *[..] Scz_Bv {
    for * m.entries if it.phi == phi return *it.inc;
    e: Scz_Phi_Entry; e.phi = phi; e.inc.allocator = temp;
    array_add(*m.entries, e);
    return *m.entries[m.entries.count - 1].inc;
}

// WeakVH: null once the value is deleted
scz_alive_phi :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .INST && inst_op(v) == .PHI; }

// isHoistableInstruction
scz_is_hoistable_instruction :: (s: *Scz, i: Value_Id, bb: Value_Id, hoist_to: Value_Id) -> bool {
    if inst_block(i) != bb || inst_op(i) == .PHI return false;
    cost := tti_instruction_cost(s.tti, i, TCK_LATENCY);
    cv := ifx cost_valid(cost) then cost else TCC_EXPENSIVE;
    if cv != 0 return false;
    n := nops(i);
    for k: 0..cast(s64) n - 1 {
        o := op(i, cast(u32) k);
        if is_inst(o) && !dt_dominates(s.dt, inst_block(o), hoist_to) return false;
    }
    return true;
}

// hoistZeroCostElseBlockPhiValues
scz_hoist_zero_cost_else_block_phi_values :: (s: *Scz, else_bb: Value_Id, then_bb: Value_Id) {
    else_succ := scz_single_successor(else_bb);
    common := dt_find_nca(s.dt, else_bb, then_bb);
    if else_succ == NONE || common == NONE return;
    if scz_single_successor(then_bb) != else_succ || scz_num_pred_edges(else_succ) != 2 return;
    term := block_terminator(common);
    for :early_inc block_insts(else_succ) {
        if inst_op(it) != .PHI break;
        idx := phi_block_index(it, else_bb);
        else_val := phi_value(it, cast(u32) idx);
        if !is_inst(else_val) || !scz_is_hoistable_instruction(s, else_val, else_bb, common) continue;
        inst_move_before_dbg(else_val, term);   // removeFromParent + insertInto(CommonDominator, Term)
        table_set(*s.hoisted_values, else_val, common);
    }
}
scz_single_successor :: (bb: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    if t == NONE || num_successors(t) != 1 return NONE;
    return get_successor(t, 0);
}
scz_num_pred_edges :: (bb: Value_Id) -> s64 {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    return preds.count;
}

// scc_iterator<SubGraphTraits::NodeRef, SubGraphTraits> from `entry`, children filtered by `nodes` (null: all)
scz_sccs :: (s: *Scz, entry: Rn_Id, nodes: *Table(Rn_Id, bool), out: *[..] [..] Rn_Id) {
    visit_num: u32 = 0;
    numbers: Table(Rn_Id, u32); numbers.allocator = temp;
    scc_stack: [..] Rn_Id; scc_stack.allocator = temp;
    Frame :: struct { n: Rn_Id; succs: [..] Rn_Id; next: s64; min_visited: u32; }
    vstack: [..] Frame; vstack.allocator = temp;
    visit_one :: (s: *Scz, n: Rn_Id, nodes: *Table(Rn_Id, bool), visit_num: *u32, numbers: *Table(Rn_Id, u32),
                  scc_stack: *[..] Rn_Id, vstack: *[..] Frame) {
        visit_num.* += 1;
        table_set(numbers, n, visit_num.*);
        array_add(scc_stack, n);
        fr: Frame; fr.n = n; fr.succs.allocator = temp; fr.min_visited = visit_num.*;
        all: [..] Rn_Id; all.allocator = temp;
        rn_successors(s.ri, n, *all);
        for all if !nodes || table_contains(nodes, it) array_add(*fr.succs, it);
        array_add(vstack, fr);
    }
    visit_one(s, entry, nodes, *visit_num, *numbers, *scc_stack, *vstack);
    while vstack.count {
        // GetNextSCC
        scc: [..] Rn_Id; scc.allocator = temp;
        while vstack.count {
            // DFSVisitChildren
            while true {
                top := *vstack[vstack.count - 1];
                if top.next >= top.succs.count break;
                child := top.succs[top.next];
                top.next += 1;
                found, cn := table_find(*numbers, child);
                if !found { visit_one(s, child, nodes, *visit_num, *numbers, *scc_stack, *vstack); continue; }
                if top.min_visited > cn top.min_visited = cn;
            }
            visiting := vstack[vstack.count - 1].n;
            min_visit := vstack[vstack.count - 1].min_visited;
            vstack.count -= 1;
            if vstack.count && vstack[vstack.count - 1].min_visited > min_visit vstack[vstack.count - 1].min_visited = min_visit;
            _, vn := table_find(*numbers, visiting);
            if min_visit != vn continue;
            while true {
                x := pop(*scc_stack);
                array_add(*scc, x);
                table_set(*numbers, x, 0xFFFF_FFFF);
                if x == visiting break;
            }
            break;
        }
        if scc.count array_add(out, scc);
    }
}

// orderNodes
scz_order_nodes :: (s: *Scz) {
    el: [..] Rn_Id; el.allocator = temp;
    ri_elements(s.ri, s.pr, *el);
    array_resize(*s.order, el.count);
    if s.order.count == 0 return;
    nodes: Table(Rn_Id, bool); nodes.allocator = temp;
    entry := ri_get_node(s.ri, s.pr, s.ri.regions[s.pr].entry);
    filter: *Table(Rn_Id, bool) = null;
    Range :: struct { i: s64; e: s64; }
    work: [..] Range; work.allocator = temp;
    i := 0; e := s.order.count;
    while true {
        sccs: [..] [..] Rn_Id; sccs.allocator = temp;
        scz_sccs(s, entry, filter, *sccs);
        for scc: sccs {
            if scc.count > 2 array_add(*work, .{i, i + scc.count});
            for n: scc { assert(i < e, "SCC size mismatch!"); s.order[i] = n; i += 1; }
        }
        assert(i == e, "SCC size mismatch!");
        if work.count == 0 break;
        r := pop(*work);
        i = r.i; e = r.e;
        table_reset(*nodes);
        for k: i..e - 2 table_set(*nodes, s.order[k], true);
        entry = s.order[e - 1];
        filter = *nodes;
    }
}

// analyzeLoops
scz_analyze_loops :: (s: *Scz, n: Rn_Id) {
    if s.ri.nodes[n].sub {
        exit := s.ri.regions[s.ri.nodes[n].region].exit;
        if table_contains(*s.visited, exit) table_set(*s.loops, exit, rn_entry(s.ri, n));
    } else {
        bb := s.ri.nodes[n].bb;
        t := block_terminator(bb);
        if t != NONE && (inst_op(t) == .BR || inst_op(t) == .CONDBR) {
            k := num_successors(t);
            for j: 0..cast(s64) k - 1 {
                succ := get_successor(t, cast(u32) j);
                if table_contains(*s.visited, succ) table_set(*s.loops, succ, bb);
            }
        }
    }
}

// buildCondition
scz_build_condition :: (s: *Scz, term: Value_Id, idx: u32, invert: bool) -> Scz_Pred {
    r: Scz_Pred;
    r.pred = op(term, 0);
    ok, t, f := prof_extract_branch_weights_2(term);
    if ok { r.has_w = true; r.tw = cast(u32) t; r.fw = cast(u32) f; }
    if idx != cast(u32) invert {
        r.pred = invert_condition(r.pred);
        if r.has_w { x := r.tw; r.tw = r.fw; r.fw = x; }
    }
    return r;
}

// gatherPredicates
scz_gather_predicates :: (s: *Scz, n: Rn_Id) {
    ri := s.ri;
    bb := rn_entry(ri, n);
    pred := scz_bbp(*s.predicates, bb);
    lpred := scz_bbp(*s.loop_preds, bb);
    bool_true := const_int(ir.t_i1, 1);
    bool_false := const_int(ir.t_i1, 0);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        if !ri_contains(ri, s.pr, p) continue;
        r := ri_get_region_for(ri, p);
        if r == s.pr {
            t := block_terminator(p);
            if inst_op(t) == .BR {
                if table_contains(*s.visited, p) scz_bbp_set(pred, p, scz_pred_const(bool_true));
                else scz_bbp_set(lpred, p, scz_pred_const(bool_false));
            } else if inst_op(t) == .CONDBR {
                idx: u32 = ifx get_successor(t, 0) == bb then cast(u32) 0 else 1;
                if table_contains(*s.visited, p) {
                    other := get_successor(t, 1 - idx);
                    if table_contains(*s.visited, other) && !table_contains(*s.loops, other) &&
                       scz_bbp_find(pred, other) < 0 && scz_bbp_find(pred, p) < 0 {
                        scz_hoist_zero_cost_else_block_phi_values(s, bb, other);
                        scz_bbp_set(pred, other, scz_pred_const(bool_false));
                        scz_bbp_set(pred, p, scz_pred_const(bool_true));
                    } else {
                        scz_bbp_set(pred, p, scz_build_condition(s, t, idx, false));
                    }
                } else {
                    scz_bbp_set(lpred, p, scz_build_condition(s, t, idx, true));
                }
            }
        } else {
            while ri.regions[r].parent != s.pr r = ri.regions[r].parent;
            if ri.regions[r].node == n continue;   // edge from inside a subregion to its entry
            entry := ri.regions[r].entry;
            if table_contains(*s.visited, entry) scz_bbp_set(pred, entry, scz_pred_const(bool_true));
            else scz_bbp_set(lpred, entry, scz_pred_const(bool_false));
        }
    }
}

// collectInfos
scz_collect_infos :: (s: *Scz) {
    table_reset(*s.predicates);
    table_reset(*s.loops);
    table_reset(*s.loop_preds);
    table_reset(*s.visited);
    for < rn: s.order {
        scz_gather_predicates(s, rn);
        table_set(*s.visited, rn_entry(s.ri, rn), true);
        scz_analyze_loops(s, rn);
    }
}

// NearestCommonDominator
Scz_Ncd :: struct { dt: *Dom_Tree; result: Value_Id = NONE; remembered: bool; }
scz_ncd_add :: (d: *Scz_Ncd, bb: Value_Id, remember: bool) {
    if d.result == NONE { d.result = bb; d.remembered = remember; return; }
    nr := dt_find_nca(d.dt, d.result, bb);
    if nr != d.result d.remembered = false;
    if nr == bb d.remembered |= remember;
    d.result = nr;
}

// insertConditions
scz_insert_conditions :: (s: *Scz, loops: bool, vars: *[..] Dfa_Ssa_Var) {
    conds := ifx loops then s.loop_conds else s.conditions;
    default := ifx loops then const_int(ir.t_i1, 1) else const_int(ir.t_i1, 0);
    for term: conds {
        parent := inst_block(term);
        succ_true := get_successor(term, 0);
        succ_false := get_successor(term, 1);
        // AddVariable("", Boolean)
        v: Dfa_Ssa_Var; v.ty = ir.t_i1;
        v.defs_bb.allocator = temp; v.defs_v.allocator = temp; v.uses.allocator = temp;
        array_add(*v.defs_bb, ifx loops then succ_false else parent); array_add(*v.defs_v, default);
        preds := ifx loops then scz_bbp(*s.loop_preds, succ_false) else scz_bbp(*s.predicates, succ_true);
        dom: Scz_Ncd; dom.dt = s.dt;
        scz_ncd_add(*dom, parent, false);
        parent_info: Scz_Pred;
        parent_info.pred = NONE;
        for bb: preds.keys {
            if bb == parent { parent_info = preds.vals[it_index]; break; }
            array_add(*v.defs_bb, bb); array_add(*v.defs_v, preds.vals[it_index].pred);
            scz_ncd_add(*dom, bb, true);
        }
        if parent_info.pred != NONE {
            set_op(term, 0, parent_info.pred);
            if parent_info.has_w prof_set_branch_weights(term, u32.[parent_info.tw, parent_info.fw], false);
        } else {
            if !dom.remembered { array_add(*v.defs_bb, dom.result); array_add(*v.defs_v, default); }
            array_add(*v.uses, op_use(term, 0));
        }
        array_add(vars, v);
    }
}

// simplifyConditions
scz_simplify_conditions :: (s: *Scz) {
    to_erase: [..] Value_Id; to_erase.allocator = temp;
    for m: Table(Value_Id, *Scz_Bbp).[s.predicates, s.loop_preds] {
        for preds: m {
            for pv: preds.vals {
                p := pv.pred;
                ok, inverted := pm_not(p);
                if !ok || !is_inst(inverted) || num_uses(inverted) != 1 || !has_uses(p) continue;
                if inst_op(inverted) == .ICMP || inst_op(inverted) == .FCMP {
                    inst(inverted).pred = cast(u8) cmp_inverse(inst(inverted).pred);
                    rauw_with_metadata(p, inverted);
                    array_add(*to_erase, p);
                }
            }
        }
    }
    for to_erase erase_inst_with_metadata(it);
}

// delPhiValues
scz_del_phi_values :: (s: *Scz, from: Value_Id, to: Value_Id) {
    m := scz_phi_map(s, to);
    for block_insts(to) {
        if inst_op(it) != .PHI break;
        phi := it;
        recorded := false;
        while phi_block_index(phi, from) != -1 {
            deleted := phi_remove_incoming_block(phi, from, false);
            array_add(scz_phi_map_get(m, phi), .{from, deleted});
            if !recorded { array_add(*s.affected_phis, phi); recorded = true; }
        }
    }
}

// addPhiValues
scz_add_phi_values :: (s: *Scz, from: Value_Id, to: Value_Id) {
    for block_insts(to) {
        if inst_op(it) != .PHI break;
        phi_add_incoming(it, const_poison(vtype(it)), from);
    }
    for * s.added_phis if it.to == to { array_add(*it.from, from); return; }
    a: Scz_Added; a.to = to; a.from.allocator = temp;
    array_add(*a.from, from);
    array_add(*s.added_phis, a);
}

// findUndefBlocks
scz_find_undef_blocks :: (s: *Scz, phi_block: Value_Id, incomings: *Table(Value_Id, bool), undef_blks: *[..] Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    stack: [..] Value_Id; stack.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(phi_block, *preds);
    if phi_block == s.ri.regions[s.pr].exit {
        for p: preds if ri_contains(s.ri, s.pr, p) array_add(*stack, p);
    } else {
        for preds array_add(*stack, it);
    }
    while stack.count {
        cur := pop(*stack);
        if table_contains(*visited, cur) continue;
        table_set(*visited, cur, true);
        if table_contains(*s.flow_set, cur) {
            block_predecessors(cur, *preds);
            for preds array_add(*stack, it);
        } else if !table_contains(incomings, cur) {
            array_add(undef_blks, cur);
        }
    }
}

// EquivalenceClasses<PHINode *>: union-find; unionSets keeps the first class's leader
Scz_Ec :: struct { parent: Table(Value_Id, Value_Id); }
scz_ec_insert :: (ec: *Scz_Ec, v: Value_Id) { if !table_contains(*ec.parent, v) table_set(*ec.parent, v, v); }
scz_ec_leader :: (ec: *Scz_Ec, v: Value_Id) -> Value_Id {
    found, p := table_find(*ec.parent, v);
    if !found return NONE;
    while p != v { v = p; _, p = table_find(*ec.parent, v); }
    return v;
}

// mergeIfCompatible
scz_merge_if_compatible :: (s: *Scz, ec: *Scz_Ec, a: Value_Id, b: Value_Id) {
    scz_ec_insert(ec, a); scz_ec_insert(ec, b);
    la := scz_ec_leader(ec, a); lb := scz_ec_leader(ec, b);
    if la == lb return;
    inc_a := scz_phi_map_get(scz_phi_map(s, inst_block(la)), la);
    inc_b := scz_phi_map_get(scz_phi_map(s, inst_block(lb)), lb);
    // DenseMap<BasicBlock *, Value *> Mergeable(IncomingA): the first entry of a block wins
    merged: [..] Scz_Bv; merged.allocator = temp;
    find :: (m: [] Scz_Bv, bb: Value_Id) -> s64 { for m if it.bb == bb return it_index; return -1; }
    for inc_a.* if find(merged, it.bb) < 0 array_add(*merged, it);
    for inc_b.* {
        k := find(merged, it.bb);
        if k >= 0 && merged[k].v != it.v return;
        if k < 0 array_add(*merged, it);
    }
    inc_a.count = 0;
    for merged array_add(inc_a, it);
    table_set(*ec.parent, lb, la);
}

// setPhiValues
scz_set_phi_values :: (s: *Scz) {
    inserted_phis: [..] Value_Id; inserted_phis.allocator = temp;
    updater: Ssa_Updater;
    updater.inserted_phis = *inserted_phis;
    undef_blks_map: Table(Value_Id, *[..] Value_Id); undef_blks_map.allocator = temp;
    undef_blks_of :: (m: *Table(Value_Id, *[..] Value_Id), bb: Value_Id) -> *[..] Value_Id {
        found, p := table_find(m, bb);
        if found return p;
        p = New([..] Value_Id,, allocator = temp);
        p.allocator = temp;
        table_set(m, bb, p);
        return p;
    }
    ec: Scz_Ec; ec.parent.allocator = temp;
    for ap: s.added_phis {
        found, blk_phis := table_find(*s.deleted_phis, ap.to);
        if !found continue;
        undef_blks := undef_blks_of(*undef_blks_map, ap.to);
        incomings: Table(Value_Id, bool); incomings.allocator = temp;
        if blk_phis.entries.count {
            for blk_phis.entries[0].inc table_set(*incomings, it.bb, true);
            scz_find_undef_blocks(s, ap.to, *incomings, undef_blks);
        }
        n := blk_phis.entries.count;   // range-for: entries appended meanwhile are not visited
        for k: 0..n - 1 {
            phi := blk_phis.entries[k].phi;
            incoming_phis: [..] Value_Id; incoming_phis.allocator = temp;
            for blk_phis.entries[k].inc if is_phi(it.v) array_add(*incoming_phis, it.v);
            for other: incoming_phis {
                if !table_contains(*s.deleted_phis, inst_block(other)) continue;
                scz_merge_if_compatible(s, *ec, phi, other);
            }
        }
    }
    for ap: s.added_phis {
        found, m := table_find(*s.deleted_phis, ap.to);
        if !found continue;
        undef_blks := undef_blks_of(*undef_blks_map, ap.to);
        for k: 0..m.entries.count - 1 {
            phi := m.entries[k].phi;
            poison := const_poison(vtype(phi));
            ssa_init(*updater, vtype(phi), "");
            ssa_add_available(*updater, fn_entry(s.f), poison);
            ssa_add_available(*updater, ap.to, poison);
            leader := scz_ec_leader(*ec, phi);
            incoming_map: [] Scz_Bv = m.entries[k].inc;
            if leader != NONE && leader != phi incoming_map = scz_phi_map_get(scz_phi_map(s, inst_block(leader)), leader).*;
            constant_preds: [..] Value_Id; constant_preds.allocator = temp;
            for incoming_map {
                ssa_add_available(*updater, it.bb, it.v);
                if is_const(it.v) array_add(*constant_preds, it.bb);
            }
            for ub: undef_blks.* {
                dominated := false;
                for cp: constant_preds if dt_dominates(s.dt, cp, ub) { dominated = true; break; }
                if dominated continue;
                if ssa_has_value(*updater, ub) continue;
                ssa_add_available(*updater, ub, poison);
            }
            for fi: ap.from {
                v := ssa_value_at_end(*updater, fi);
                np := nops(phi);
                for j: 0..cast(s64) np - 1 if phi_block(phi, cast(u32) j) == fi phi_set_value(phi, cast(u32) j, v);
            }
            array_add(*s.affected_phis, phi);
        }
    }
    for inserted_phis array_add(*s.affected_phis, it);
}

// simplifyHoistedPhis
scz_simplify_hoisted_phis :: (s: *Scz) {
    for phi: s.affected_phis {
        if !scz_alive_phi(phi) || nops(phi) != 2 continue;
        for i: 0..1 {
            v := phi_value(phi, cast(u32) i);
            found, hb := table_find(*s.hoisted_values, v);
            if !found continue;
            other_v := phi_value(phi, cast(u32) (1 - i));
            if !is_phi(other_v) continue;
            other_phi := other_v;
            poison_idx := -1;
            for k: 0..cast(s64) nops(other_phi) - 1 {
                if vkind(phi_value(other_phi, cast(u32) k)) != .C_POISON continue;
                poison_idx = k;
                break;
            }
            if poison_idx == -1 || !dt_dominates(s.dt, hb, phi_block(other_phi, cast(u32) poison_idx)) continue;
            phi_set_value(other_phi, cast(u32) poison_idx, v);
            if dt_dominates_inst(s.dt, other_v, phi) phi_set_value(phi, cast(u32) i, other_v);
        }
    }
}

// simplifyAffectedPhis
scz_simplify_affected_phis :: (s: *Scz) {
    while true {
        changed := false;
        q: Simplify_Query;
        q.dt = s.dt;
        q.can_use_undef = false;
        q.have_tli = false; q.no_tli_libcalls = true;
        for phi: s.affected_phis {
            if !scz_alive_phi(phi) continue;
            nv := simplify_instruction(phi, q);
            if nv != NONE {
                rauw_with_metadata(phi, nv);
                erase_inst_with_metadata(phi);
                changed = true;
            }
        }
        if !changed break;
    }
}

// killTerminator: returns the terminator's debug location
scz_kill_terminator :: (s: *Scz, bb: Value_Id) -> Md_Id {
    t := block_terminator(bb);
    if t == NONE return NONE;
    k := num_successors(t);
    for j: 0..cast(s64) k - 1 scz_del_phi_values(s, bb, get_successor(t, cast(u32) j));
    dl := get_metadata(t, 0);
    drop_all_references(t);
    erase_inst(t);
    return dl;
}

// pred_iterator: the next terminator use at or after `u`
scz_next_term_use :: (u_in: Use_Id) -> Use_Id {
    u := u_in;
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && is_terminator(inst_op(user)) return u;
        u = ir.u_next[u];
    }
    return NONE;
}

// changeExit
scz_change_exit :: (s: *Scz, node: Rn_Id, new_exit: Value_Id, include_dominator: bool) {
    ri := s.ri;
    if ri.nodes[node].sub {
        sub := ri.nodes[node].region;
        old_exit := ri.regions[sub].exit;
        dominator: Value_Id = NONE;
        // make_early_inc_range(predecessors(OldExit)): the next use is taken before the body (it may move to
        // NewExit's use list, as in LLVM)
        u := scz_next_term_use(ir.v_first_use[old_exit]);
        while u != NONE {
            nx := scz_next_term_use(ir.u_next[u]);
            bb := inst_block(ir.u_user[u]);
            defer u = nx;
            if scz_trace print("changeExit sub % pred % contains %\n", ri_name_str(ri, sub), ri_block_name_str(bb), ri_contains(ri, sub, bb));
            if !ri_contains(ri, sub, bb) continue;
            scz_del_phi_values(s, bb, old_exit);
            replace_uses_of_with(block_terminator(bb), old_exit, new_exit);
            scz_add_phi_values(s, bb, new_exit);
            if include_dominator {
                if dominator == NONE dominator = bb;
                else dominator = dt_find_nca(s.dt, dominator, bb);
            }
        }
        if dominator != NONE dt_change_idom(s.dt, new_exit, dominator);
        ri_replace_exit(ri, sub, new_exit);
    } else {
        bb := ri.nodes[node].bb;
        dl := scz_kill_terminator(s, bb);
        br := create_br(new_exit);
        block_append_inst(bb, br);
        set_metadata(br, 0, dl);
        scz_add_phi_values(s, bb, new_exit);
        if include_dominator dt_change_idom(s.dt, new_exit, bb);
    }
}

// getNextFlow
scz_get_next_flow :: (s: *Scz, dominator: Value_Id) -> Value_Id {
    insert := ifx s.order.count == 0 then s.ri.regions[s.pr].exit else rn_entry(s.ri, s.order[s.order.count - 1]);
    flow := create_block(s.f, "Flow", insert);
    table_set(*s.flow_set, flow, true);
    dt_add_new_block(s.dt, flow, dominator);
    ri_set_region_for(s.ri, flow, s.pr);
    return flow;
}

// needPrefix
scz_need_prefix :: (s: *Scz, need_empty: bool) -> Value_Id, Md_Id {
    entry := rn_entry(s.ri, s.prev_node);
    if !s.ri.nodes[s.prev_node].sub {
        dl := scz_kill_terminator(s, entry);
        if !need_empty || block_first_insertion_pt(entry) == NONE return entry, dl;
    }
    flow := scz_get_next_flow(s, entry);
    scz_change_exit(s, s.prev_node, flow, true);
    s.prev_node = ri_get_bb_node(s.ri, s.pr, flow);
    return flow, NONE;
}

// needPostfix
scz_need_postfix :: (s: *Scz, flow: Value_Id, exit_use_allowed: bool) -> Value_Id {
    if s.order.count != 0 || !exit_use_allowed return scz_get_next_flow(s, flow);
    exit := s.ri.regions[s.pr].exit;
    dt_change_idom(s.dt, exit, flow);
    scz_add_phi_values(s, flow, exit);
    return exit;
}

scz_set_prev_node :: (s: *Scz, bb: Value_Id) {
    s.prev_node = ifx ri_contains(s.ri, s.pr, bb) then ri_get_bb_node(s.ri, s.pr, bb) else -1;
}

// dominatesPredicates
scz_dominates_predicates :: (s: *Scz, bb: Value_Id, node: Rn_Id) -> bool {
    preds := scz_bbp(*s.predicates, rn_entry(s.ri, node));
    // all_of over a DenseMap: which queries run before the first `false` depends on pointer order
    if preds.keys.count > 1 {
        q := NewArray(preds.keys.count, Scz_Query,, allocator = temp);
        for preds.keys { q[it_index].t = true; q[it_index].d, q[it_index].slow = dt_dominates_peek(s.dt, bb, it); }
        scz_check_query_order(s.dt, q, false);
    }
    for preds.keys if !dt_dominates(s.dt, bb, it) return false;
    return true;
}

// The slow-query count of a DenseMap walk with early exits over these queries, for every visiting order: if it
// differs, the tree's SlowQueries (print<domtree>) depends on pointer order.
// predictable = isPredictableTrue's walk (stop at a non-true predicate; query until one dominates), else
// dominatesPredicates' all_of (query until one does not dominate).
Scz_Query :: struct { t: bool; d: bool; slow: bool; }
scz_check_query_order :: (dt: *Dom_Tree, q: [] Scz_Query, predictable: bool) {
    if dt.dfs_valid || dt.slow_queries_unknown return;
    any_slow := false;
    for q if it.slow any_slow = true;
    if !any_slow return;
    if q.count > 7 { dt.slow_queries_unknown = true; return; }
    perm := NewArray(q.count, s64,, allocator = temp);
    for * perm it.* = it_index;
    mn := 1000; mx := -1;
    count :: (q: [] Scz_Query, perm: [] s64, predictable: bool) -> s64 {
        n := 0;
        dominated := false;
        for k: perm {
            if predictable {
                if !q[k].t break;
                if !dominated { if q[k].slow n += 1; if q[k].d dominated = true; }
            } else {
                if q[k].slow n += 1;
                if !q[k].d break;
            }
        }
        return n;
    }
    // Heap's algorithm over all orders
    c := NewArray(q.count, s64,, allocator = temp);
    n := count(q, perm, predictable); mn = n; mx = n;
    i := 0;
    while i < q.count {
        if c[i] < i {
            if i % 2 == 0 { perm[0], perm[i] = perm[i], perm[0]; } else { perm[c[i]], perm[i] = perm[i], perm[c[i]]; }
            n = count(q, perm, predictable);
            mn = min(mn, n); mx = max(mx, n);
            c[i] += 1;
            i = 0;
        } else { c[i] = 0; i += 1; }
    }
    if mn != mx dt.slow_queries_unknown = true;
}
// dominates(A, B) without side effects: (result, whether it would count as a slow query)
dt_dominates_peek :: (dt: *Dom_Tree, a: Value_Id, b: Value_Id) -> bool, bool {
    if a == b return true, false;
    na := dt_node(dt, a); nb := dt_node(dt, b);
    if nb == na return true, false;
    if nb < 0 return true, false;
    if na < 0 return false, false;
    if dt.nodes[nb].idom == na return true, false;
    if dt.nodes[na].idom == nb return false, false;
    if dt.nodes[na].level >= dt.nodes[nb].level return false, false;
    if dt.dfs_valid return dt.nodes[nb].dfs_in >= dt.nodes[na].dfs_in && dt.nodes[nb].dfs_out <= dt.nodes[na].dfs_out, false;
    alevel := dt.nodes[na].level;
    x := nb;
    while true {
        i := dt.nodes[x].idom;
        if i < 0 || dt.nodes[i].level < alevel break;
        x = i;
    }
    return x == na, true;
}

// isPredictableTrue
scz_is_predictable_true :: (s: *Scz, node: Rn_Id) -> bool {
    preds := scz_bbp(*s.predicates, rn_entry(s.ri, node));
    dominated := false;
    if s.prev_node < 0 return true;
    bool_true := const_int(ir.t_i1, 1);
    // a DenseMap walk with early exits: the dominance queries made depend on pointer order
    if preds.keys.count > 1 {
        q := NewArray(preds.keys.count, Scz_Query,, allocator = temp);
        pe := rn_entry(s.ri, s.prev_node);
        for preds.keys { q[it_index].t = preds.vals[it_index].pred == bool_true; q[it_index].d, q[it_index].slow = dt_dominates_peek(s.dt, it, pe); }
        scz_check_query_order(s.dt, q, true);
    }
    for bb: preds.keys {
        if preds.vals[it_index].pred != bool_true return false;
        if !dominated && dt_dominates(s.dt, bb, rn_entry(s.ri, s.prev_node)) dominated = true;
    }
    return dominated;
}

// wireFlow
scz_wire_flow :: (s: *Scz, exit_use_allowed: bool, loop_end: Value_Id) {
    node := pop(*s.order);
    table_set(*s.visited, rn_entry(s.ri, node), true);
    if scz_is_predictable_true(s, node) {
        if s.prev_node >= 0 scz_change_exit(s, s.prev_node, rn_entry(s.ri, node), true);
        s.prev_node = node;
    } else {
        flow, dl := scz_need_prefix(s, false);
        entry := rn_entry(s.ri, node);
        next := scz_need_postfix(s, flow, exit_use_allowed);
        br := create_cond_br(const_poison(ir.t_i1), entry, next);
        block_append_inst(flow, br);
        set_metadata(br, 0, dl);
        array_add(*s.conditions, br);
        scz_add_phi_values(s, flow, entry);
        dt_change_idom(s.dt, entry, flow);
        s.prev_node = node;
        while s.order.count && !table_contains(*s.visited, loop_end) &&
              scz_dominates_predicates(s, entry, s.order[s.order.count - 1]) {
            scz_handle_loops(s, false, loop_end);
        }
        scz_change_exit(s, s.prev_node, next, false);
        scz_set_prev_node(s, next);
    }
}

// handleLoops
scz_handle_loops :: (s: *Scz, exit_use_allowed: bool, loop_end_in: Value_Id) {
    node := s.order[s.order.count - 1];
    loop_start := rn_entry(s.ri, node);
    if !table_contains(*s.loops, loop_start) {
        scz_wire_flow(s, exit_use_allowed, loop_end_in);
        return;
    }
    if !scz_is_predictable_true(s, node) {
        loop_start = scz_need_prefix(s, true);
    }
    _, loop_end := table_find(*s.loops, rn_entry(s.ri, node));
    scz_wire_flow(s, false, loop_end);
    while !table_contains(*s.visited, loop_end) scz_handle_loops(s, false, loop_end);
    le, dl := scz_need_prefix(s, false);
    next := scz_need_postfix(s, le, exit_use_allowed);
    br := create_cond_br(const_poison(ir.t_i1), next, loop_start);
    block_append_inst(le, br);
    set_metadata(br, 0, dl);
    array_add(*s.loop_conds, br);
    scz_add_phi_values(s, le, loop_start);
    scz_set_prev_node(s, next);
}

// createFlow
scz_create_flow :: (s: *Scz) {
    exit := s.ri.regions[s.pr].exit;
    entry_dominates_exit := dt_dominates(s.dt, s.ri.regions[s.pr].entry, exit);
    s.affected_phis.count = 0;
    table_reset(*s.deleted_phis);
    s.added_phis.count = 0;
    s.conditions.count = 0;
    s.loop_conds.count = 0;
    s.prev_node = -1;
    table_reset(*s.visited);
    while s.order.count scz_handle_loops(s, entry_dominates_exit, NONE);
    if s.prev_node >= 0 scz_change_exit(s, s.prev_node, exit, entry_dominates_exit);
    else assert(entry_dominates_exit);
}

// SSAUpdater::RewriteUseAfterInsertions
ssa_rewrite_use_after_insertions :: (s: *Ssa_Updater, u: Use_Id) {
    user := ir.u_user[u];
    v: Value_Id;
    if inst_op(user) == .PHI v = ssa_value_at_end(s, ir.u_aux[u]);
    else v = ssa_value_at_end(s, inst_block(user));
    use_set(u, v);
}

// rebuildSSA
scz_rebuild_ssa :: (s: *Scz) {
    updater: Ssa_Updater;
    blocks: [..] Value_Id; blocks.allocator = temp;
    ri_blocks(s.ri, s.pr, *blocks);
    for bb: blocks {
        for i: block_insts(bb) {
            initialized := false;
            u := ir.v_first_use[i];
            while u != NONE {
                nx := ir.u_next[u];
                defer u = nx;
                user := ir.u_user[u];
                if inst_block(user) == bb continue;
                if inst_op(user) == .PHI && ir.u_aux[u] == bb continue;
                if dt_dominates_inst(s.dt, i, user) continue;
                if !initialized {
                    ssa_init(*updater, vtype(i), "");
                    ssa_add_available(*updater, fn_entry(s.f), const_poison(vtype(i)));
                    ssa_add_available(*updater, bb, i);
                    initialized = true;
                }
                ssa_rewrite_use_after_insertions(*updater, u);
            }
        }
    }
}

// SSAUpdaterBulk::RewriteAndOptimizeAllUses
ssa_bulk_rewrite_and_optimize_all_uses :: (vars: [] Dfa_Ssa_Var, dt: *Dom_Tree) {
    phis: [..] Value_Id; phis.allocator = temp;
    dfa_ssa_rewrite_all_uses(vars, dt, *phis);
    if phis.count == 0 return;
    // simplifyPass
    q: Simplify_Query; q.have_tli = false; q.no_tli_libcalls = true;
    for * phis {
        sv := simplify_instruction(it.*, q);
        if sv != NONE {
            rauw_with_metadata(it.*, sv);
            erase_inst_with_metadata(it.*);
            it.* = NONE;
        }
    }
    // deduplicatePass: SmallDenseMap<BasicBlock *, unsigned> BBs is iterated in pointer-hash order. Blocks are
    // independent unless a phi replaced in one block makes the new phis of another block identical (or not);
    // then the result depends on the order: fail loudly unless -structurizecfg-guess-address-order.
    Cnt :: struct { bb: Value_Id; n: s64; }
    bbs: [..] Cnt; bbs.allocator = temp;
    for p: phis {
        if p == NONE continue;
        b := inst_block(p);
        found := false;
        for * bbs if it.bb == b { it.n += 1; found = true; break; }
        if !found array_add(*bbs, .{b, 1});
    }
    first_existing_of :: (c: Cnt) -> Value_Id {
        fe := block_first(c.bb);
        for 1..c.n fe = inst_next(fe);
        return fe;
    }
    before := NewArray(bbs.count, s64,, allocator = temp);
    for bbs before[it_index] = eliminate_new_duplicate_phi_nodes(it.bb, first_existing_of(it), dry_run = true);
    for bbs {
        if !scz_guess_address_order {
            now := eliminate_new_duplicate_phi_nodes(it.bb, first_existing_of(it), dry_run = true);
            if now != before[it_index] scz_address_order_fatal();
        }
        eliminate_new_duplicate_phi_nodes(it.bb, first_existing_of(it));
    }
    if !scz_guess_address_order {
        for bbs {
            // the new phis that are left are the first ones of the block (none of them was a duplicate)
            n := 0;
            for p: phis if p != NONE && vkind(p) == .INST && inst_block(p) == it.bb n += 1;
            c := it; c.n = n;
            if eliminate_new_duplicate_phi_nodes(it.bb, first_existing_of(c), dry_run = true) != 0 scz_address_order_fatal();
        }
    }
}
scz_address_order_fatal :: () {
    fatal("structurizecfg: SSAUpdaterBulk's deduplicatePass visits blocks in DenseMap (pointer address) order and the result depends on it here (use -structurizecfg-guess-address-order to guess)");
}
scz_guess_address_order := false;   // -structurizecfg-guess-address-order (ours)

// EliminateNewDuplicatePHINodes(BB, FirstExistingPN): the new phis are the ones before FirstExistingPN. Returns
// the number of phis replaced; `dry_run` only counts them (a replaced phi is skipped, its uses are not rewritten).
eliminate_new_duplicate_phi_nodes :: (bb: Value_Id, first_existing_in: Value_Id, dry_run := false) -> s64 {
    first_existing := first_existing_in;   // a non-phi (or NONE) here is phis().end()
    dead: Table(Value_Id, bool); dead.allocator = temp;
    replace_if_identical :: (phi: Value_Id, repl: Value_Id, dry_run: bool, dead: *Table(Value_Id, bool)) -> s64 {
        if dry_run && (table_contains(dead, phi) || table_contains(dead, repl)) return 0;
        if !phi_is_identical_to_when_defined(phi, repl) return 0;
        if dry_run { table_set(dead, phi, true); return 1; }
        rauw_with_metadata(phi, repl);
        erase_inst_with_metadata(phi);
        return 1;
    }
    changed := 0;
    i := block_first(bb);
    while i != first_existing {
        j := inst_next(i);
        while j != first_existing {
            nj := inst_next(j);
            changed += replace_if_identical(j, i, dry_run, *dead);
            j = nj;
        }
        i = inst_next(i);
    }
    e := first_existing;
    while e != NONE && inst_op(e) == .PHI {
        ne := inst_next(e);
        i = block_first(bb);
        while true {
            ni := inst_next(i);
            changed += replace_if_identical(i, e, dry_run, *dead);
            i = ni;
            if i == first_existing break;
        }
        if dry_run {
            all_dead := true;
            x := block_first(bb);
            while x != first_existing { if !table_contains(*dead, x) all_dead = false; x = inst_next(x); }
            if all_dead return changed;
        } else if block_first(bb) == first_existing return changed;
        e = ne;
    }
    return changed;
}

// StructurizeCFG::run
scz_run_region :: (s: *Scz) -> bool {
    r := s.pr;
    if ri_is_top_level(s.ri, r) return false;
    t := block_terminator(s.ri.regions[r].entry);
    if t != NONE && inst_op(t) == .CALLBR return false;
    scz_order_nodes(s);
    scz_collect_infos(s);
    scz_create_flow(s);
    vars: [..] Dfa_Ssa_Var; vars.allocator = temp;
    scz_insert_conditions(s, false, *vars);
    scz_insert_conditions(s, true, *vars);
    ssa_bulk_rewrite_and_optimize_all_uses(vars, s.dt);
    scz_set_phi_values(s);
    scz_simplify_hoisted_phis(s);
    scz_simplify_conditions(s);
    scz_simplify_affected_phis(s);
    scz_rebuild_ssa(s);
    return true;
}

structurizecfg_run :: (f: Value_Id, node: *Pass_Node) -> Preserved {
    skip := node.name == "structurizecfg<skip-uniform-regions>";
    if scz_force_skip_uniform_regions_given skip = scz_force_skip_uniform_regions;
    if skip
        fatal("structurizecfg: skip-uniform-regions (UniformityInfo) is not supported yet");
    dt := get_domtree(f);
    ri := ri_get(f);
    tti := tti_get(f);
    regions: [..] Region_Id; regions.allocator = temp;
    add :: (ri: *Region_Info, r: Region_Id, out: *[..] Region_Id) {
        array_add(out, r);
        for ri.regions[r].children add(ri, it, out);
    }
    add(ri, ri.top, *regions);
    changed := false;
    while regions.count {
        r := pop(*regions);
        s: Scz;
        s.f = f; s.ri = ri; s.pr = r; s.dt = dt; s.tti = tti;
        s.order.allocator = temp; s.visited.allocator = temp; s.flow_set.allocator = temp;
        s.affected_phis.allocator = temp; s.deleted_phis.allocator = temp; s.added_phis.allocator = temp;
        s.predicates.allocator = temp; s.loop_preds.allocator = temp; s.conditions.allocator = temp;
        s.loops.allocator = temp; s.loop_conds.allocator = temp; s.hoisted_values.allocator = temp;
        changed |= scz_run_region(*s);
        if scz_trace {
            printer_begin_function(f);
            start := W.buf.count;
            print_function(f);
            str := copy_string(slice_of_buf(start),, allocator = temp);
            W.buf.count = start;
            print("=== after region %\n%\n", ri_name_str(ri, r), str);
        }
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
scz_force_skip_uniform_regions_given := false;   // -structurizecfg-skip-uniform-regions (getNumOccurrences)
scz_force_skip_uniform_regions := false;

scz_trace := false;
