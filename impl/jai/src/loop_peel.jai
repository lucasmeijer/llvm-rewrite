// Loop peeling.
// Port of llvm/lib/Transforms/Utils/LoopPeel.cpp: canPeel, PhiAnalyzer, peelToTurnInvariantLoadsDereferenceable,
// canPeelLastIteration, shouldPeelLastIteration, countToEliminateCompares, violatesLegacyMultiExitLoopCheck,
// computePeelCount, cloneLoopBlocks, gatherPeelingPreferences, peelLoop.
//
// Reusable API: compute_peel_count, peel_loop(li, l, count, peel_last, dt, ac, preserve_lcssa, *vm),
// gather_peeling_preferences, can_peel, can_peel_last_iteration. The SE is the global `se`.

PEELED_COUNT_METADATA :: "llvm.loop.peeled.count";

// canPeel
can_peel :: (li: *Loop_Info, l: Loop_Id) -> bool {
    if !li_is_loop_simplify_form(li, l) return false;
    if lu_cl.disable_advanced_peeling.v == 0 return true;
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits, li_loop_latch(li, l));
    for exits if !is_block_followed_by_deopt_or_unreachable(it) return false;
    return true;
}

// ---------------------------------------------------------------- PhiAnalyzer

PEEL_INVARIANT :: 0; PEEL_INDUCTION :: 1;
Peel_Counter :: struct { known: bool; val: u32; ty: u8; }
Phi_Analyzer :: struct {
    li: *Loop_Info;
    l: Loop_Id;
    max_iterations: u32;
    peel_for_iv: bool;
    map: Table(Value_Id, Peel_Counter);
}
pa_add_one :: (a: *Phi_Analyzer, pc: Peel_Counter) -> Peel_Counter {
    if !pc.known return pc;
    if pc.val + 1 <= a.max_iterations return .{true, pc.val + 1, pc.ty};
    unknown: Peel_Counter;
    return unknown;
}
// isInductionPHI
pa_is_induction_phi :: (a: *Phi_Analyzer, phi: Value_Id) -> bool {
    latch := li_loop_latch(a.li, a.l);
    if latch == NONE return false;
    cur := phi_incoming_value_for_block(phi, latch);
    visited: [..] Value_Id; visited.allocator = temp;
    visit_bin_op := false;
    while true {
        if cur == phi break;
        if block_set_contains(visited, cur) return false;
        array_add(*visited, cur);
        if !is_inst(cur) || !li_contains_inst(a.li, a.l, cur) return false;
        o := inst_op(cur);
        if is_cast_op(o) cur = op(cur, 0);
        else if is_binary_op(o) {
            if o != .ADD && o != .SUB return false;
            if vkind(op(cur, 1)) != .C_INT return false;
            visit_bin_op = true;
            cur = op(cur, 0);
        } else return false;
    }
    return visit_bin_op;
}
// mergeTwoCounters
pa_merge_two_counters :: (i: Value_Id, lhs: Peel_Counter, rhs: Peel_Counter) -> Peel_Counter {
    nv := max(lhs.val, rhs.val);
    if lhs.ty == PEEL_INDUCTION || rhs.ty == PEEL_INDUCTION {
        if is_binary_op(inst_op(i)) && (inst_op(i) == .ADD || inst_op(i) == .SUB) return .{true, nv, PEEL_INDUCTION};
        unknown: Peel_Counter;
        return unknown;
    }
    return .{true, nv, PEEL_INVARIANT};
}
// calculate
pa_calculate :: (a: *Phi_Analyzer, v: Value_Id) -> Peel_Counter {
    unknown: Peel_Counter;
    found, r := table_find(*a.map, v);
    if found return r;
    table_set(*a.map, v, unknown);
    if li_is_loop_invariant(a.li, a.l, v) {
        z := Peel_Counter.{true, 0, PEEL_INVARIANT};
        table_set(*a.map, v, z);
        return z;
    }
    if is_phi(v) {
        if inst_block(v) != li_header(a.li, a.l) return unknown;
        if a.peel_for_iv && pa_is_induction_phi(a, v) {
            z := Peel_Counter.{true, 0, PEEL_INDUCTION};
            table_set(*a.map, v, z);
            return z;
        }
        input := phi_incoming_value_for_block(v, li_loop_latch(a.li, a.l));
        iterations := pa_calculate(a, input);
        res := pa_add_one(a, iterations);
        table_set(*a.map, v, res);
        return res;
    }
    if is_inst(v) {
        o := inst_op(v);
        if o == .ICMP || o == .FCMP || is_binary_op(o) {
            lhs := pa_calculate(a, op(v, 0));
            if !lhs.known return unknown;
            rhs := pa_calculate(a, op(v, 1));
            if !rhs.known return unknown;
            res := pa_merge_two_counters(v, lhs, rhs);
            table_set(*a.map, v, res);
            return res;
        }
        if is_cast_op(o) {
            res := pa_calculate(a, op(v, 0));
            table_set(*a.map, v, res);
            return res;
        }
    }
    return unknown;
}
// calculateIterationsToPeel: (has value, iterations)
pa_calculate_iterations_to_peel :: (a: *Phi_Analyzer) -> (bool, u32) {
    iterations: u32 = 0;
    for pn: block_insts(li_header(a.li, a.l)) {
        if !is_phi(pn) break;
        c := pa_calculate(a, pn);
        if c.known {
            iterations = max(iterations, c.val);
            if iterations == a.max_iterations break;
        }
    }
    if iterations return true, iterations;
    return false, 0;
}

// ---------------------------------------------------------------- heuristics

// peelToTurnInvariantLoadsDereferenceable
peel_to_turn_invariant_loads_dereferenceable :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, ac: *Assumption_Cache) -> u32 {
    if li_exiting_block(li, l) != NONE return 0;
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits, li_loop_latch(li, l));
    for exits if inst_op(block_terminator(it)) != .UNREACHABLE return 0;
    header := li_header(li, l);
    latch := li_loop_latch(li, l);
    load_users: Table(Value_Id, bool); load_users.allocator = temp;
    add_users :: (set: *Table(Value_Id, bool), i: Value_Id) {
        u := ir.v_first_use[i];
        while u != NONE { table_set(set, ir.u_user[u], true); u = ir.u_next[u]; }
    }
    for bb: li_blocks(li, l) {
        for i: block_insts(bb) {
            if may_write_to_memory(i) && !(is_call_base(i) && call_only_accesses_inaccessible_memory(i)) return 0;
            if table_contains(*load_users, i) add_users(*load_users, i);
            if bb == header continue;
            if inst_op(i) == .LOAD {
                ptr := op(i, 0);
                q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = i;
                if dt_dominates(dt, bb, latch) && li_is_loop_invariant(li, l, ptr) && !is_dereferenceable_pointer_ty(ptr, vtype(i), q)
                    add_users(*load_users, i);
            }
        }
    }
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    for exiting if table_contains(*load_users, block_terminator(it)) return 1;
    return 0;
}

// canPeelLastIteration
can_peel_last_iteration :: (li: *Loop_Info, l: Loop_Id) -> bool {
    btc := sc_get_backedge_taken_count(l);
    if btc == SCEV_CNC return false;
    latch := li_loop_latch(li, l);
    if latch == NONE || latch != li_exiting_block(li, l) return false;
    t := block_terminator(latch);
    if inst_op(t) != .CONDBR return false;
    c := op(t, 0);
    if !is_inst(c) || inst_op(c) != .ICMP || num_uses(c) != 1 return false;
    pred := inst(c).pred;
    inc := op(c, 0); bound := op(c, 1);
    succ1 := get_successor(t, 0); succ2 := get_successor(t, 1);
    header := li_header(li, l);
    if !((pred == ICMP_EQ && succ2 == header) || (pred == ICMP_NE && succ1 == header)) return false;
    if !is_int_type(vtype(bound)) return false;
    if !sc_is_loop_invariant(sc_get_scev(bound), l) return false;
    s := sc_get_scev(inc);
    return sc_kind(s) == .ADDREC && sc_is_affine(s) && sc_is_one(sc_op(s, 1)) && sc_loop(s) == l;
}

// shouldPeelLastIteration
should_peel_last_iteration :: (li: *Loop_Info, l: Loop_Id, pred: u8, left_ar: Scev_Id, right_in: Scev_Id, t: *Tti) -> bool {
    if !can_peel_last_iteration(li, l) return false;
    btc := sc_get_backedge_taken_count(l);
    x: Scev_Expander; sx_init(*x, "loop-peel");
    if !sc_is_known_non_zero(btc) &&
       sx_is_high_cost_expansion(*x, .[btc], l, scev_cheap_expansion_budget, t, block_terminator(li_loop_predecessor(li, l))) return false;
    guards := sc_loop_guards_collect(l);
    btc = sc_apply_loop_guards_with(btc, *guards);
    right := sc_apply_loop_guards_with(right_in, *guards);
    val_at_last := evaluate_at_iteration(left_ar, btc);
    val_at_second_to_last := evaluate_at_iteration(left_ar, sc_get_minus(btc, sc_get_one(sc_type(btc))));
    return sc_is_known_predicate(icmp_inverse(pred), val_at_last, right) && sc_is_known_predicate(pred, val_at_second_to_last, right);
}

// countToEliminateCompares: (DesiredPeelCount, DesiredPeelCountLast)
count_to_eliminate_compares :: (li: *Loop_Info, l: Loop_Id, max_peel_count_in: u32, t: *Tti) -> (u32, u32) {
    Ctx :: struct {
        li: *Loop_Info; l: Loop_Id; t: *Tti;
        max_peel_count: u32;
        desired: u32;
        desired_last: u32;
    }
    c: Ctx;
    c.li = li; c.l = l; c.t = t;
    c.max_peel_count = max_peel_count_in;
    be := sc_get_constant_max_backedge_taken_count(l);
    if sc_is_const(be) c.max_peel_count = min(cast,trunc(u32) ap_limited(sc_ap(be)) - 1, c.max_peel_count);

    // PeelWhilePredicateIsKnown
    peel_while_predicate_is_known :: (c: *Ctx, peel_count: *u32, iter_val: *Scev_Id, bound: Scev_Id, step: Scev_Id, pred: u8) -> bool {
        while peel_count.* < c.max_peel_count && sc_is_known_predicate(pred, iter_val.*, bound) {
            iter_val.* = sc_get_add2(iter_val.*, step);
            peel_count.* += 1;
        }
        return sc_is_known_predicate(icmp_inverse(pred), iter_val.*, bound);
    }
    MAX_DEPTH :: 4;
    compute_peel_count :: (c: *Ctx, condition: Value_Id, depth: u32) {
        if !is_int_type(vtype(condition)) || depth >= MAX_DEPTH return;
        if is_inst(condition) && (inst_op(condition) == .AND || inst_op(condition) == .OR) {
            compute_peel_count(c, op(condition, 0), depth + 1);
            compute_peel_count(c, op(condition, 1), depth + 1);
            return;
        }
        if !is_inst(condition) || inst_op(condition) != .ICMP return;
        pred := inst(condition).pred;
        left_val := op(condition, 0); right_val := op(condition, 1);
        left := sc_get_scev(left_val);
        right := sc_get_scev(right_val);
        known, _ := sc_evaluate_predicate(pred, left, right);
        if known return;
        if sc_kind(left) != .ADDREC {
            if sc_kind(right) == .ADDREC {
                tmp := left; left = right; right = tmp;
                pred = icmp_swapped(pred);
            } else return;
        }
        left_ar := left;
        if !sc_is_affine(left_ar) || sc_loop(left_ar) != c.l return;
        if !(icmp_is_equality(pred) && sc_has_nw(left_ar)) && sc_get_monotonic_predicate_type(left_ar, pred) == .NONE return;
        new_peel_count := c.desired;
        iter_val := evaluate_at_iteration(left_ar, sc_get_constant_t(sc_type(left), cast(u64) new_peel_count));
        if !sc_is_known_predicate(pred, iter_val, right) pred = icmp_inverse(pred);
        step := sc_step_recurrence(left_ar);
        if !peel_while_predicate_is_known(c, *new_peel_count, *iter_val, right, step, pred) {
            if should_peel_last_iteration(c.li, c.l, pred, left_ar, right, c.t) c.desired_last = 1;
            return;
        }
        next_iter_val := sc_get_add2(iter_val, step);
        if icmp_is_equality(pred) && !sc_is_known_predicate(icmp_inverse(pred), next_iter_val, right) &&
           !sc_is_known_predicate(pred, iter_val, right) && sc_is_known_predicate(pred, next_iter_val, right) {
            if new_peel_count >= c.max_peel_count return;
            new_peel_count += 1;
        }
        c.desired = max(c.desired, new_peel_count);
        c.desired_last = max(c.desired_last, new_peel_count);
    }
    compute_peel_count_min_max :: (c: *Ctx, mm: Value_Id) {
        if !is_int_type(vtype(mm)) return;
        lhs := call_arg(mm, 0); rhs := call_arg(mm, 1);
        bound, iter: Scev_Id;
        if li_is_loop_invariant(c.li, c.l, lhs) { bound = sc_get_scev(lhs); iter = sc_get_scev(rhs); }
        else if li_is_loop_invariant(c.li, c.l, rhs) { bound = sc_get_scev(rhs); iter = sc_get_scev(lhs); }
        else return;
        if sc_kind(iter) != .ADDREC || !sc_is_affine(iter) || sc_loop(iter) != c.l return;
        step := sc_step_recurrence(iter);
        id := call_iid(mm);
        is_signed := id == IID_SMAX || id == IID_SMIN;
        pred: u8;
        if sc_is_known_positive(step) pred = ifx is_signed then cast(u8) ICMP_SLT else cast(u8) ICMP_ULT;
        else if sc_is_known_negative(step) pred = ifx is_signed then cast(u8) ICMP_SGT else cast(u8) ICMP_UGT;
        else return;
        if !(ifx is_signed then (sc_flags(iter, SF_NSW) != 0) else (sc_flags(iter, SF_NUW) != 0)) return;
        new_peel_count := c.desired;
        iter_val := evaluate_at_iteration(iter, sc_get_constant_t(sc_type(iter), cast(u64) new_peel_count));
        if !peel_while_predicate_is_known(c, *new_peel_count, *iter_val, bound, step, pred) {
            if should_peel_last_iteration(c.li, c.l, pred, iter, bound, c.t) c.desired_last = 1;
            return;
        }
        c.desired = new_peel_count;
    }
    for bb: li_blocks(li, l) {
        for i: block_insts(bb) {
            if inst_op(i) == .SELECT compute_peel_count(*c, op(i, 0), 0);
            if inst_op(i) == .CALL && is_min_max_intrinsic(call_iid(i)) compute_peel_count_min_max(*c, i);
        }
        bi := block_terminator(bb);
        if inst_op(bi) != .CONDBR continue;
        if li_loop_latch(li, l) == bb continue;
        compute_peel_count(*c, op(bi, 0), 0);
    }
    return c.desired, c.desired_last;
}

// violatesLegacyMultiExitLoopCheck
violates_legacy_multi_exit_loop_check :: (li: *Loop_Info, l: Loop_Id) -> bool {
    latch := li_loop_latch(li, l);
    if latch == NONE return true;
    br := block_terminator(latch);
    if inst_op(br) != .CONDBR || !li_is_loop_exiting(li, l, latch) return true;
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits, latch);
    for exits if block_terminating_deoptimize_call(it) == NONE return true;
    return false;
}

// computePeelCount
compute_peel_count :: (li: *Loop_Info, l: Loop_Id, loop_size: u32, pp: *Peel_Prefs, trip_count: u32, dt: *Dom_Tree, t: *Tti,
                       ac: *Assumption_Cache, threshold: u32) {
    target_peel_count := pp.peel_count;
    pp.peel_count = 0;
    pp.peel_last = false;
    if !can_peel(li, l) return;
    if !pp.allow_loop_nests_peeling && !li_is_innermost(li, l) return;
    if lu_cl.unroll_force_peel_count.given {
        pp.peel_count = lu_u32(lu_cl.unroll_force_peel_count);
        pp.peel_profiled_iterations = true;
        return;
    }
    if !pp.allow_peeling return;
    if 2 * cast(u64) loop_size > threshold return;
    already_peeled: u32 = 0;
    has_p, peeled := li_optional_int_loop_attribute(li, l, PEELED_COUNT_METADATA);
    if has_p already_peeled = cast,trunc(u32) peeled;
    unroll_peel_max_count := lu_u32(lu_cl.unroll_peel_max_count);
    if already_peeled >= unroll_peel_max_count return;
    max_peel_count := unroll_peel_max_count;
    max_peel_count = min(max_peel_count, threshold / loop_size - 1);
    desired_peel_count := target_peel_count;
    if max_peel_count > desired_peel_count {
        a: Phi_Analyzer;
        a.li = li; a.l = l; a.max_iterations = max_peel_count; a.peel_for_iv = lu_cl.enable_peeling_for_iv.v != 0;
        a.map.allocator = temp;
        has, n := pa_calculate_iterations_to_peel(*a);
        if has desired_peel_count = max(desired_peel_count, n);
    }
    cmps, cmps_last := count_to_eliminate_compares(li, l, max_peel_count, t);
    desired_peel_count = max(desired_peel_count, cmps);
    if desired_peel_count == 0 desired_peel_count = peel_to_turn_invariant_loads_dereferenceable(li, l, dt, ac);
    if desired_peel_count > 0 {
        desired_peel_count = min(desired_peel_count, max_peel_count);
        if desired_peel_count + already_peeled <= unroll_peel_max_count {
            pp.peel_count = desired_peel_count;
            pp.peel_profiled_iterations = false;
            pp.peel_last = false;
            return;
        }
    }
    if cmps_last > 0 {
        dl := min(cmps_last, max_peel_count);
        if dl + already_peeled <= unroll_peel_max_count {
            pp.peel_count = dl;
            pp.peel_profiled_iterations = false;
            pp.peel_last = true;
            return;
        }
    }
    if trip_count return;
    if !pp.peel_profiled_iterations return;
    if fn_has_profile_data(li.fn) {
        if violates_legacy_multi_exit_loop_check(li, l) return;
        has_e, etc := li_loop_estimated_trip_count(li, l);
        if !has_e return;
        total := cast(u64) etc + already_peeled;
        if total <= 0xFFFF_FFFF && total <= max_peel_count {
            pp.peel_count = etc;
            return;
        }
    }
}

// gatherPeelingPreferences
gather_peeling_preferences :: (li: *Loop_Info, l: Loop_Id, t: *Tti, has_user_allow_peeling: bool, user_allow_peeling: bool,
                               has_user_profile_peeling: bool, user_profile_peeling: bool, unrolling_specific_values: bool) -> Peel_Prefs {
    pp: Peel_Prefs;
    pp.peel_count = 0;
    pp.allow_peeling = true;
    pp.allow_loop_nests_peeling = false;
    pp.peel_last = false;
    pp.peel_profiled_iterations = true;
    tti_get_peeling_preferences(t, *pp);
    if unrolling_specific_values {
        if lu_cl.unroll_peel_count.given pp.peel_count = lu_u32(lu_cl.unroll_peel_count);
        if lu_cl.unroll_allow_peeling.given pp.allow_peeling = lu_cl.unroll_allow_peeling.v != 0;
        if lu_cl.unroll_allow_loop_nests_peeling.given pp.allow_loop_nests_peeling = lu_cl.unroll_allow_loop_nests_peeling.v != 0;
    }
    if has_user_allow_peeling pp.allow_peeling = user_allow_peeling;
    if has_user_profile_peeling pp.peel_profiled_iterations = user_profile_peeling;
    return pp;
}

// ---------------------------------------------------------------- peeling

// cloneLoopBlocks (LoopPeel.cpp)
peel_clone_loop_blocks :: (li: *Loop_Info, l: Loop_Id, iter_number: u32, peel_last: bool, insert_top: Value_Id, insert_bot: Value_Id,
                           orig_pre_header: Value_Id, exit_edges: [] [2] Value_Id, new_blocks: *[..] Value_Id, rpo: [] Value_Id,
                           vm: *Value_Map, lvm: *Value_Map, dt: *Dom_Tree, scopes: [] Md_Id) {
    header := li_header(li, l);
    latch := li_loop_latch(li, l);
    pre_header := li_loop_preheader(li, l);
    f := block_fn(header);
    parent := li_parent(li, l);
    for bb: rpo {
        nb := clone_basic_block(bb, vm, ".peel", f);
        array_add(new_blocks, nb);
        if parent != NONE && li_loop_for(li, bb) == l li_add_basic_block_to_loop(li, parent, nb);
        vmap_set(vm, bb, nb);
        if dt {
            if header == bb dt_add_new_block(dt, nb, insert_top);
            else dt_add_new_block(dt, nb, vmap_get(vm, dt_idom_block(dt, bb)));
        }
    }
    clone_and_adapt_no_alias_scopes(scopes, new_blocks.*, tprint("Peel%", iter_number));
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(li, l) array_add(*subs, it);
    for subs clone_loop(li, it, parent, vm);

    set_successor(block_terminator(insert_top), 0, vmap_get(vm, header));
    new_latch := vmap_get(vm, latch);
    if peel_last {
        lt := block_terminator(new_latch);
        set_successor(lt, 0, insert_bot);
        set_successor(lt, 1, insert_bot);
    } else {
        lt := block_terminator(new_latch);
        ns := num_successors(lt);
        for k: 0..cast(s64) ns - 1 if get_successor(lt, cast(u32) k) == header { set_successor(lt, cast(u32) k, insert_bot); break; }
    }
    if dt dt_change_idom(dt, insert_bot, new_latch);

    if peel_last {
        b: Irb; irb_set_at(*b, insert_top, block_first_non_phi(insert_top), true);
        for i: block_insts(header) {
            if !is_phi(i) break;
            new_phi := vmap_get(vm, i);
            pn := irb_phi(*b, vtype(new_phi), 2);
            erase_inst_with_metadata(new_phi);
            if orig_pre_header != NONE phi_add_incoming(pn, phi_incoming_value_for_block(i, pre_header), orig_pre_header);
            phi_add_incoming(pn, phi_incoming_value_for_block(i, latch), latch);
            vmap_set(vm, i, pn);
        }
    } else {
        for i: block_insts(header) {
            if !is_phi(i) break;
            new_phi := vmap_get(vm, i);
            if iter_number == 0 vmap_set(vm, i, phi_incoming_value_for_block(new_phi, pre_header));
            else {
                latch_val := phi_incoming_value_for_block(new_phi, latch);
                if is_inst(latch_val) && li_contains_inst(li, l, latch_val) vmap_set(vm, i, vmap_get(lvm, latch_val));
                else vmap_set(vm, i, latch_val);
            }
            erase_inst_with_metadata(new_phi);
        }
    }
    for e: exit_edges {
        for pn: block_insts(e[1]) {
            if !is_phi(pn) break;
            latch_val := phi_incoming_value_for_block(pn, e[0]);
            if is_inst(latch_val) && li_contains_inst(li, l, latch_val) latch_val = vmap_get(vm, latch_val);
            phi_add_incoming(pn, latch_val, vmap_get(vm, e[0]));
            sc_forget_lcssa_phi_with_new_predecessor(l, pn);
        }
    }
    for v, k: vm.map vmap_set(lvm, k, v);
}

// peelLoop(L, PeelCount, PeelLast, LI, SE, DT, AC, PreserveLCSSA, LVMap)
peel_loop :: (li: *Loop_Info, l_in: Loop_Id, peel_count: u32, peel_last: bool, dt: *Dom_Tree, ac: *Assumption_Cache, preserve_lcssa: bool, lvm: *Value_Map) {
    l := l_in;
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    header := li_header(li, l);
    pre_header := li_loop_preheader(li, l);
    latch := li_loop_latch(li, l);
    exit_edges: [..] [2] Value_Id; exit_edges.allocator = temp;
    for bb: li_blocks(li, l) {
        t := block_terminator(bb);
        ns := num_successors(t);
        for k: 0..cast(s64) ns - 1 { s := get_successor(t, cast(u32) k); if !li_contains(li, l, s) array_add(*exit_edges, .[bb, s]); }
    }
    // NonLoopBlocksIDom (MapVector)
    nl_keys: [..] Value_Id; nl_keys.allocator = temp;
    nl_vals: [..] Value_Id; nl_vals.allocator = temp;
    kids: [..] Value_Id; kids.allocator = temp;
    for bb: li_blocks(li, l) {
        dt_child_blocks(dt, bb, *kids);
        to_update: [..] Value_Id; to_update.allocator = temp;
        for kids if !li_contains(li, l, it) array_add(*to_update, it);
        new_idom := dt_find_nca(dt, bb, latch);
        for c: to_update {
            found := false;
            for nl_keys if it == c { nl_vals[it_index] = new_idom; found = true; break; }
            if !found { array_add(*nl_keys, c); array_add(*nl_vals, new_idom); }
        }
    }
    f := block_fn(header);
    insert_top, insert_bot: Value_Id;
    new_pre_header: Value_Id = NONE;
    exit_values_k: [..] Value_Id; exit_values_k.allocator = temp;
    exit_values_v: [..] Value_Id; exit_values_v.allocator = temp;
    if peel_last {
        exit := li_exit_block(li, l);
        for p: block_insts(exit) {
            if !is_phi(p) break;
            array_add(*exit_values_k, p); array_add(*exit_values_v, phi_incoming_value_for_block(p, latch));
        }
        btc := sc_get_backedge_taken_count(l);
        insert_top = split_edge(latch, exit, dt, li);
        insert_bot = split_block(insert_top, block_terminator(insert_top), dt, li);
        set_name(insert_top, tprint("%.peel.begin", vname(exit)));
        set_name(insert_bot, tprint("%.peel.next", vname(exit)));
        new_pre_header = NONE;
        if sc_is_known_non_zero(btc) {
            p := li_loop_probability(li, l);
            if !bprob_is_unknown(p) {
                exit_p := bprob_compl(p);
                if exit_p != 0 {
                    freq := 1 / bprob_to_double(exit_p);
                    new_freq := max(freq - 1, cast(float64) 1);
                    li_set_loop_probability(li, l, bprob_from_double(1 - 1 / new_freq));
                }
            }
        } else {
            new_pre_header = split_edge(pre_header, header, dt, li);
            x: Scev_Expander; sx_init(*x, "loop-peel");
            pre_header_br := block_terminator(pre_header);
            btc_value := sx_expand_code_for_at(*x, btc, sc_type(btc), pre_header_br);
            b: Irb; irb_set_before(*b, pre_header_br);
            cond := irb_icmp(*b, ICMP_NE, btc_value, const_int(vtype(btc_value), 0));
            bi := irb_cond_br(*b, cond, new_pre_header, insert_top);
            orig_latch_br := block_terminator(latch);
            ok, w := prof_extract_branch_weights(orig_latch_br);
            if ok {
                ww := NewArray(w.count, u32,, allocator = temp);
                for w ww[it_index] = cast,trunc(u32) it;
                if li_exit_block(li, l) == get_successor(orig_latch_br, 0) && ww.count >= 2 { tmp := ww[0]; ww[0] = ww[1]; ww[1] = tmp; }
                prof_set_branch_weights(bi, ww, false);
            }
            erase_inst_with_metadata(pre_header_br);
            dt_change_idom(dt, insert_top, pre_header);
        }
    } else {
        insert_top = split_edge(pre_header, header, dt, li);
        insert_bot = split_block(insert_top, block_terminator(insert_top), dt, li);
        new_pre_header = split_block(insert_bot, block_terminator(insert_bot), dt, li);
        set_name(insert_top, tprint("%.peel.begin", vname(header)));
        set_name(insert_bot, tprint("%.peel.next", vname(header)));
        set_name(new_pre_header, tprint("%.peel.newph", vname(pre_header)));
    }
    latch_term := block_terminator(latch);
    scopes: [..] Md_Id; scopes.allocator = temp;
    identify_no_alias_scopes_to_clone(li_blocks(li, l), *scopes);

    vm: Value_Map; vmap_init(*vm);
    for iter: 0..cast(s64) peel_count - 1 {
        new_blocks: [..] Value_Id; new_blocks.allocator = temp;
        peel_clone_loop_blocks(li, l, cast(u32) iter, peel_last, insert_top, insert_bot, ifx new_pre_header != NONE then pre_header else NONE,
                               exit_edges, *new_blocks, rpo, *vm, lvm, dt, scopes);
        remap_instructions_in_blocks(new_blocks, *vm);
        if iter == 0 {
            if peel_last {
                cmp := op(block_terminator(li_loop_latch(li, l)), 0);
                b: Irb; irb_set_before(*b, cmp);
                o1 := op(cmp, 1);
                set_op(cmp, 1, irb_binop(*b, .SUB, o1, const_int(vtype(o1), 1)));
            } else {
                for k: nl_keys dt_change_idom(dt, k, vmap_get(lvm, nl_vals[it_index]));
            }
        }
        latch_term_copy := vmap_get(*vm, latch_term);
        set_metadata(latch_term_copy, MD_LOOP_KIND, NONE);
        insert_top = insert_bot;
        insert_bot = split_block(insert_bot, block_terminator(insert_bot), dt, li);
        set_name(insert_bot, tprint("%.peel.next", vname(header)));
        fn_splice_blocks(f, insert_top, new_blocks[0]);
    }
    if peel_last {
        for p: exit_values_k {
            e := exit_values_v[it_index];
            if is_inst(e) && li_contains_inst(li, l, e) rauw_with_metadata(p, vmap_get(*vm, e));
            else rauw_with_metadata(p, e);
            erase_inst_with_metadata(p);
        }
        form_lcssa(li, l, dt);
    } else {
        for phi: block_insts(header) {
            if !is_phi(phi) break;
            nv := phi_incoming_value_for_block(phi, latch);
            if is_inst(nv) && li_contains_inst(li, l, nv) nv = vmap_get(lvm, nv);
            phi_set_incoming_value_for_block(phi, new_pre_header, nv);
        }
    }
    already_peeled: u32 = 0;
    has_p, peeled := li_optional_int_loop_attribute(li, l, PEELED_COUNT_METADATA);
    if has_p already_peeled = cast,trunc(u32) peeled;
    total_peeled := already_peeled + peel_count;
    add_string_metadata_to_loop(li, l, PEELED_COUNT_METADATA, total_peeled);
    has_e, etc := li_loop_estimated_trip_count(li, l);
    if has_e {
        n := ifx etc < total_peeled then cast(u32) 0 else etc - total_peeled;
        li_set_loop_estimated_trip_count(li, l, n);
    }
    parent := li_parent(li, l);
    if parent != NONE l = parent;
    sc_forget_topmost_loop(l);
    sc_forget_block_and_loop_dispositions();
    simplify_loop(li, l, dt, ac, null, preserve_lcssa);
}
