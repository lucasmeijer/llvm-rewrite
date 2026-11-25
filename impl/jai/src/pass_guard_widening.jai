// GuardWidening (guard-widening, function and loop pass): port of llvm/lib/Transforms/Scalar/GuardWidening.cpp.
// A guard (llvm.experimental.guard or a widenable branch to a deoptimize block) dominated by another guard is
// eliminated by hoisting its checks into the dominating guard's condition (merging range checks where possible).
// Guard helpers: guard_utils.jai.

gw_cl: struct {
    widen_branch_guards := true;   // -guard-widening-widen-branch-guards
};

gw_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name != "guard-widening-widen-branch-guards" return false;
    if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" gw_cl.widen_branch_guards = true;
    else if value == "false" || value == "0" || value == "FALSE" || value == "False" gw_cl.widen_branch_guards = false;
    else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
    return true;
}

// getCondition
gw_get_condition :: (i: Value_Id) -> Value_Id {
    if inst_op(i) == .CALL return call_arg(i, 0);   // an IntrinsicInst: the guard
    ok, c := gu_parse_widenable_branch_values(i);
    if ok return c;
    return op(i, 0);
}
// setCondition
gw_set_condition :: (i: Value_Id, c: Value_Id) { set_op(i, 0, c); }   // the guard's arg 0 or the branch condition

// An insertion point (BasicBlock::iterator; never with the head bit here)
Gw_It :: struct { bb: Value_Id; pt: Value_Id; }

// findInsertionPointForWideCondition: ok = false for std::nullopt
gw_find_insertion_point_for_wide_condition :: (wc_or_guard: Value_Id) -> (bool, Gw_It) {
    if gu_is_guard(wc_or_guard) return true, .{inst_block(wc_or_guard), wc_or_guard};
    wc := gu_extract_widenable_condition(wc_or_guard);
    if wc != NONE return true, .{inst_block(wc), wc};
    return false, .{};
}

Gw_Score :: enum u8 { ILLEGAL_OR_NEGATIVE; NEUTRAL; POSITIVE; VERY_POSITIVE; }

// RangeCheck
Gw_Range_Check :: struct { base: Value_Id; offset: APInt; length: Value_Id; check_inst: Value_Id; }

Guard_Widening :: struct {
    dt: *Dom_Tree;
    pdt: *Dom_Tree;   // null in the loop pass
    li: *Loop_Info;
    ac: *Assumption_Cache;
    mssau: *Mssa_Updater;
    root: Value_Id;        // the root block of the dominator-tree walk
    filter_loop: Loop_Id;  // NONE: every block; else BB == root || L.contains(BB)
    eliminated: [..] Value_Id;       // EliminatedGuardsAndBranches
    widened: Table(Value_Id, bool);  // WidenedGuards
    guards_in_block: Table(Value_Id, [..] Value_Id);
}

gw_block_filter :: (g: *Guard_Widening, bb: Value_Id) -> bool {
    if g.filter_loop == NONE return true;
    return bb == g.root || li_contains(g.li, g.filter_loop, bb);
}

// isSupportedGuardInstruction
gw_is_supported_guard_instruction :: (i: Value_Id) -> bool {
    if gu_is_guard(i) return true;
    if gw_cl.widen_branch_guards && gu_is_guard_as_widenable_branch(i) return true;
    return false;
}

// GuardWideningImpl::run
gw_run :: (g: *Guard_Widening) -> bool {
    changed := false;
    // df_begin(Root) .. df_end(Root): preorder over the dominator tree; `path` is the df_iterator's visit stack
    Frame :: struct { n: s32; next_child: s32; }
    stack: [..] Frame; stack.allocator = temp;
    path: [..] Value_Id; path.allocator = temp;
    rn := dt_node(g.dt, g.root);
    if rn < 0 return false;
    array_add(*stack, .{rn, g.dt.nodes[rn].first_child});
    array_add(*path, g.root);
    visit := true;
    while stack.count {
        if visit {
            visit = false;
            bb := path[path.count - 1];
            if gw_block_filter(g, bb) {
                list: [..] Value_Id; list.allocator = temp;
                for i: block_insts(bb) if gw_is_supported_guard_instruction(i) array_add(*list, i);
                table_set(*g.guards_in_block, bb, list);
                for ii: list changed |= gw_eliminate_instr_via_widening(g, ii, path, list);
            }
        }
        top := *stack[stack.count - 1];
        c := top.next_child;
        if c < 0 { pop(*stack); pop(*path); continue; }
        top.next_child = g.dt.nodes[c].sibling;
        array_add(*stack, .{c, g.dt.nodes[c].first_child});
        array_add(*path, dt_block(g.dt, c));
        visit = true;
    }
    for i: g.eliminated {
        if table_contains(*g.widened, i) continue;
        if gw_is_supported_guard_instruction(i) {
            // eliminateGuard
            if g.mssau mssau_remove_memory_access_inst(g.mssau, i);
            erase_inst_with_metadata(i);
        }
    }
    return changed;
}

// eliminateInstrViaWidening
gw_eliminate_instr_via_widening :: (g: *Guard_Widening, instr: Value_Id, path: [] Value_Id, cur_list: [] Value_Id) -> bool {
    checks_to_hoist: [..] Value_Id; checks_to_hoist.allocator = temp;
    gu_parse_widenable_guard(instr, *checks_to_hoist);
    if checks_to_hoist.count == 0 || (checks_to_hoist.count == 1 && vkind(checks_to_hoist[0]) == .C_INT) return false;
    best: Value_Id = NONE;
    best_score := Gw_Score.ILLEGAL_OR_NEGATIVE;
    for cur_bb: path {
        if !gw_block_filter(g, cur_bb) break;
        guards := table_find_pointer(*g.guards_in_block, cur_bb);
        assert(guards != null, "Must have been populated by now!");
        same := inst_block(instr) == cur_bb;
        for cand: guards.* {
            if same && cand == instr break;
            ok, wp := gw_find_insertion_point_for_wide_condition(cand);
            if !ok continue;
            cand_checks: [..] Value_Id; cand_checks.allocator = temp;
            gu_parse_widenable_guard(cand, *cand_checks);
            score := gw_compute_widening_score(g, instr, cand, wp, *checks_to_hoist, *cand_checks);
            if score > best_score { best_score = score; best = cand; }
        }
    }
    if best_score == .ILLEGAL_OR_NEGATIVE return false;
    checks_to_widen: [..] Value_Id; checks_to_widen.allocator = temp;
    gu_parse_widenable_guard(best, *checks_to_widen);
    gw_widen_guard(g, *checks_to_hoist, *checks_to_widen, best);
    gw_set_condition(instr, const_int(type_int(1), 1));
    array_add(*g.eliminated, instr);
    table_set(*g.widened, best, true);
    return true;
}

// widenGuard
gw_widen_guard :: (g: *Guard_Widening, hoist: *[..] Value_Id, widen: *[..] Value_Id, to_widen: Value_Id) {
    ok, ip := gw_find_insertion_point_for_wide_condition(to_widen);
    assert(ok);
    merged_ok, merged := gw_merge_checks(g, hoist, widen, true, ip);
    result := ifx merged_ok then merged else gw_hoist_checks(g, hoist, gw_get_condition(to_widen), ip);
    if gu_is_guard_as_widenable_branch(to_widen) { gu_set_widenable_branch_cond(to_widen, result); return; }
    gw_set_condition(to_widen, result);
}

// computeWideningScore
gw_compute_widening_score :: (g: *Guard_Widening, dominated: Value_Id, to_widen: Value_Id, wp: Gw_It,
                              hoist: *[..] Value_Id, widen: *[..] Value_Id) -> Gw_Score {
    dominated_loop := li_loop_for(g.li, inst_block(dominated));
    dominating_loop := li_loop_for(g.li, wp.bb);
    hoisting_out_of_loop := false;
    if dominating_loop != dominated_loop {
        if dominating_loop != NONE && !li_contains_loop(g.li, dominating_loop, dominated_loop) return .ILLEGAL_OR_NEGATIVE;
        hoisting_out_of_loop = true;
    }
    for hoist.* if !gw_can_be_hoisted_to(g, it, wp) return .ILLEGAL_OR_NEGATIVE;
    if !gw_can_be_hoisted_to(g, gw_get_condition(to_widen), wp) return .ILLEGAL_OR_NEGATIVE;
    // isWideningCondProfitable
    prof_ok := gw_merge_checks(g, hoist, widen, false, .{});
    if prof_ok return ifx hoisting_out_of_loop then Gw_Score.VERY_POSITIVE else .POSITIVE;
    if hoisting_out_of_loop return .POSITIVE;

    get_likely_successor :: (bb: Value_Id) -> Value_Id {
        u := block_unique_successor(bb);
        if u != NONE return u;
        term := block_terminator(bb);
        if inst_op(term) != .CONDBR return NONE;
        cond := op(term, 0);
        if_true := get_successor(term, 0); if_false := get_successor(term, 1);
        if vkind(cond) == .C_INT return ifx ap_is_all_ones(const_ap(cond)) then if_true else if_false;
        if block_postdominating_deoptimize_call(if_false) != NONE return if_true;
        if block_postdominating_deoptimize_call(if_true) != NONE return if_false;
        return NONE;
    }
    // MaybeHoistingToHotterBlock
    dominating_block := wp.bb;
    dominated_block := inst_block(dominated);
    while dominated_block != dominating_block {
        likely := get_likely_successor(dominating_block);
        if likely == NONE break;
        if !dt_properly_dominates(g.dt, dominating_block, likely) break;
        dominating_block = likely;
    }
    hotter: bool;
    if dominated_block == dominating_block hotter = false;
    else if !dt_dominates(g.dt, dominating_block, dominated_block) hotter = true;
    else if !g.pdt hotter = true;
    else hotter = !dt_dominates(g.pdt, dominated_block, dominating_block);
    return ifx hotter then Gw_Score.ILLEGAL_OR_NEGATIVE else .NEUTRAL;
}

// canBeHoistedTo(V, Loc, Visited)
gw_can_be_hoisted_to :: (g: *Guard_Widening, v: Value_Id, loc: Gw_It) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    return gw_can_be_hoisted_to_rec(g, v, loc, *visited);
}
gw_can_be_hoisted_to_rec :: (g: *Guard_Widening, v: Value_Id, loc: Gw_It, visited: *[..] Value_Id) -> bool {
    if !is_inst(v) || dt_dominates_inst(g.dt, v, loc.pt) return true;
    for visited.* if it == v return true;
    // !isSafeToSpeculativelyExecute(Inst, Loc, &AC, &DT) || Inst->mayReadFromMemory() (both are pure queries; a
    // load always fails the second one)
    if may_read_from_memory(v) || !is_safe_to_speculatively_execute(v) return false;
    array_add(visited, v);
    for k: 0..cast(s64) nops(v) - 1 if !gw_can_be_hoisted_to_rec(g, op(v, cast(u32) k), loc, visited) return false;
    return true;
}

// makeAvailableAt
gw_make_available_at :: (g: *Guard_Widening, v: Value_Id, loc: Gw_It) {
    if !is_inst(v) || dt_dominates_inst(g.dt, v, loc.pt) return;
    for k: 0..cast(s64) nops(v) - 1 gw_make_available_at(g, op(v, cast(u32) k), loc);
    inst_move_before_dbg(v, loc.pt);
}

// getFreezeInsertPt: ok = false for std::nullopt; head = the iterator's head bit
gw_get_freeze_insert_pt :: (g: *Guard_Widening, v: Value_Id) -> (bool, Gw_It, head: bool) {
    if !is_inst(v) {
        e := dt_entry(g.dt);
        return true, .{e, block_first_non_phi_or_dbg_or_alloca(e)}, false;
    }
    if vtype(v) == ir.t_void return false, .{}, false;
    pt, bb, head := inst_insertion_point_after_def(v);
    if pt == NONE return false, .{}, false;
    if !dt_dominates_inst(g.dt, v, pt) return false, .{}, false;
    u := ir.v_first_use[v];
    while u != NONE {
        user := ir.u_user[u];
        if pt != user && dt_dominates_inst(g.dt, v, user) && !dt_dominates_inst(g.dt, pt, user) return false, .{}, false;
        u = ir.u_next[u];
    }
    return true, .{bb, pt}, head;
}

gw_new_freeze :: (v: Value_Id, name: string, at: Gw_It, head: bool) -> Value_Id {
    fi := new_inst(.FREEZE, vtype(v), 1);
    set_op(fi, 0, v);
    insert_at_position(fi, at.bb, at.pt, head);
    set_name(fi, name);
    return fi;
}

// freezeAndPush
gw_freeze_and_push :: (g: *Guard_Widening, orig: Value_Id, insert_pt: Gw_It) -> Value_Id {
    if is_guaranteed_not_to_be_poison(orig, null, insert_pt.pt, g.dt) return orig;
    ok, at_def, head := gw_get_freeze_insert_pt(g, orig);
    if !ok return gw_new_freeze(orig, "gw.freeze", insert_pt, false);
    if is_constant_kind(vkind(orig)) return gw_new_freeze(orig, "gw.freeze", at_def, head);

    visited: Table(Value_Id, bool); visited.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    drop_poison_flags: [..] Value_Id; drop_poison_flags.allocator = temp;
    need_freeze: [..] Value_Id; need_freeze.allocator = temp;
    cache_of_freezes: Table(Value_Id, Value_Id); cache_of_freezes.allocator = temp;

    // handleConstantOrGlobal
    handle_constant_or_global :: (g: *Guard_Widening, user: Value_Id, k: u32, visited: *Table(Value_Id, bool),
                                  cache: *Table(Value_Id, Value_Id), insert_pt: Gw_It) -> bool {
        def := op(user, k);
        if !is_constant_kind(vkind(def)) return false;
        if !table_contains(visited, def) {
            table_set(visited, def, true);
            if is_guaranteed_not_to_be_poison(def, null, insert_pt.pt, g.dt) return true;
            _, at, head := gw_get_freeze_insert_pt(g, def);
            fi := gw_new_freeze(def, tconcat(vname(def), ".gw.fr"), at, head);
            table_set(cache, def, fi);
        }
        found, fi := table_find(cache, def);
        if found set_op(user, k, fi);
        return true;
    }

    array_add(*worklist, orig);
    while worklist.count {
        v := pop(*worklist);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        if is_guaranteed_not_to_be_poison(v, null, insert_pt.pt, g.dt) continue;
        if !is_inst(v) || can_create_undef_or_poison(v, false) { array_add(*need_freeze, v); continue; }
        bad := false;
        for k: 0..cast(s64) nops(v) - 1 {
            o := op(v, cast(u32) k);
            if is_inst(o) { okf := gw_get_freeze_insert_pt(g, o); if !okf { bad = true; break; } }
        }
        if bad { array_add(*need_freeze, v); continue; }
        found := false;
        for drop_poison_flags if it == v { found = true; break; }
        if !found array_add(*drop_poison_flags, v);
        for k: 0..cast(s64) nops(v) - 1
            if !handle_constant_or_global(g, v, cast(u32) k, *visited, *cache_of_freezes, insert_pt) array_add(*worklist, op(v, cast(u32) k));
    }
    for drop_poison_flags drop_poison_generating_annotations(it);
    result := orig;
    for v: need_freeze {
        _, at, head := gw_get_freeze_insert_pt(g, v);
        fi := gw_new_freeze(v, tconcat(vname(v), ".gw.fr"), at, head);
        if v == orig result = fi;
        // V->replaceUsesWithIf(FI, U.getUser() != FI)
        u := ir.v_first_use[v];
        while u != NONE {
            nxt := ir.u_next[u];
            if ir.u_user[u] != fi use_set(u, fi);
            u = nxt;
        }
    }
    return result;
}

// mergeChecks: (has_value, value); do_insert = InsertPt is set
gw_merge_checks :: (g: *Guard_Widening, hoist: *[..] Value_Id, widen: *[..] Value_Id, do_insert: bool, ip: Gw_It) -> (bool, Value_Id) {
    result: Value_Id = NONE;
    match_icmp_const :: (v: Value_Id) -> (bool, u8, Value_Id, Value_Id) {
        if !is_inst(v) || inst_op(v) != .ICMP return false, 0, NONE, NONE;
        r := op(v, 1);
        if vkind(r) != .C_INT return false, 0, NONE, NONE;
        return true, inst(v).pred, op(v, 0), r;
    }
    if widen.count == 1 && hoist.count == 1 {
        ok0, pred0, lhs, rhs0 := match_icmp_const(widen.*[0]);
        ok1, pred1, lhs1, rhs1 := match_icmp_const(hoist.*[0]);
        if ok0 && ok1 && lhs1 == lhs {
            cr0 := cr_exact_icmp_region(pred0, const_ap(rhs0));
            cr1 := cr_exact_icmp_region(pred1, const_ap(rhs1));
            iok, inter := cr_exact_intersect(cr0, cr1);
            if iok {
                eok, pred, new_rhs_ap := cr_equivalent_icmp_no_offset(inter);
                if eok {
                    if do_insert {
                        new_rhs := const_int_ap(vtype(rhs0), new_rhs_ap);
                        gw_make_available_at(g, lhs, ip);
                        result = create_icmp(pred, lhs, new_rhs);
                        insert_at_position(result, ip.bb, ip.pt, false);
                        set_name(result, "wide.chk");
                    }
                    return true, result;
                }
            }
        }
    }
    {
        checks: [..] Gw_Range_Check; checks.allocator = temp;
        combined: [..] Gw_Range_Check; combined.allocator = temp;
        if gw_parse_range_checks_list(widen, *checks) && gw_parse_range_checks_list(hoist, *checks) &&
           gw_combine_range_checks(*checks, *combined) {
            if do_insert {
                for rc: combined {
                    gw_make_available_at(g, rc.check_inst, ip);
                    if result != NONE {
                        a := create_binop(.AND, rc.check_inst, result);
                        insert_at_position(a, ip.bb, ip.pt, false);
                        result = a;
                    } else result = rc.check_inst;
                }
                set_name(result, "wide.chk");
                result = gw_freeze_and_push(g, result, ip);
            }
            return true, result;
        }
    }
    return false, NONE;
}

// hoistChecks
gw_hoist_checks :: (g: *Guard_Widening, hoist: *[..] Value_Id, old_condition: Value_Id, ip: Gw_It) -> Value_Id {
    b: Irb; irb_set_at(*b, ip.bb, ip.pt, false);
    for hoist.* gw_make_available_at(g, it, ip);
    gw_make_available_at(g, old_condition, ip);
    result := gu_irb_and_list(*b, hoist.*);
    result = gw_freeze_and_push(g, result, ip);
    result = gu_irb_and(*b, old_condition, result);
    set_name(result, "wide.chk");
    return result;
}

gw_parse_range_checks_list :: (hoist_or_widen: *[..] Value_Id, checks: *[..] Gw_Range_Check) -> bool {
    for hoist_or_widen.* if !gw_parse_range_checks(it, checks) return false;
    return true;
}

// parseRangeChecks(CheckCond, Checks)
gw_parse_range_checks :: (check_cond: Value_Id, checks: *[..] Gw_Range_Check) -> bool {
    ic := check_cond;
    if !is_inst(ic) || inst_op(ic) != .ICMP || type_kind(vtype(op(ic, 0))) != .INT return false;
    pred := inst(ic).pred;
    if pred != ICMP_ULT && pred != ICMP_UGT return false;
    cmp_lhs := op(ic, 0); cmp_rhs := op(ic, 1);
    if pred == ICMP_UGT cmp_lhs, cmp_rhs = cmp_rhs, cmp_lhs;
    check: Gw_Range_Check;
    check.base = cmp_lhs;
    check.offset = ap_zero(type_bits(vtype(cmp_rhs)));
    check.length = cmp_rhs;
    check.check_inst = ic;
    q: Simplify_Query; q.have_tli = false;   // SimplifyQuery(DL)
    if !is_known_non_negative(check.length, q) return false;
    while true {
        changed := false;
        b := check.base;
        if is_inst(b) && inst_op(b) == .ADD && vkind(op(b, 1)) == .C_INT {
            check.base = op(b, 0);
            check.offset = ap_add(check.offset, const_ap(op(b, 1)));
            changed = true;
        } else if is_inst(b) && inst_op(b) == .OR && vkind(op(b, 1)) == .C_INT {
            known := known_bits(op(b, 0), q);
            rhs := const_ap(op(b, 1));
            if ap_eq(ap_and(rhs, known.zero), rhs) {
                check.base = op(b, 0);
                check.offset = ap_add(check.offset, rhs);
                changed = true;
            }
        }
        if !changed break;
    }
    array_add(checks, check);
    return true;
}

// combineRangeChecks
gw_combine_range_checks :: (checks: *[..] Gw_Range_Check, out: *[..] Gw_Range_Check) -> bool {
    old_count := checks.count;
    while checks.count {
        current_base := checks.*[0].base;
        current_length := checks.*[0].length;
        current: [..] Gw_Range_Check; current.allocator = temp;
        rest: [..] Gw_Range_Check; rest.allocator = temp;
        for checks.* {
            if it.base == current_base && it.length == current_length array_add(*current, it);
            else array_add(*rest, it);
        }
        checks.count = 0;
        for rest array_add(checks, it);
        if current.count < 3 {
            for current array_add(out, it);
            continue;
        }
        // llvm::sort(CurrentChecks, offset slt): libstdc++'s std::sort over indices
        idx := NewArray(current.count, Value_Id,, allocator = temp);
        for i: 0..current.count - 1 idx[i] = cast(Value_Id) i;
        less :: (a: Value_Id, b: Value_Id, data: *void) -> bool {
            cs := cast(*[..] Gw_Range_Check) data;
            return ap_slt(cs.*[a].offset, cs.*[b].offset);
        }
        std_sort_by(idx, less, *current);
        sorted: [..] Gw_Range_Check; sorted.allocator = temp;
        for idx array_add(*sorted, current[it]);
        min_offset := sorted[0].offset;
        max_offset := sorted[sorted.count - 1].offset;
        bw := max_offset.bits;
        if ap_ugt(ap_sub(max_offset, min_offset), ap_signed_min(bw)) return false;
        max_diff := ap_sub(max_offset, min_offset);
        if ap_is_zero(max_diff) return false;
        for i: 1..sorted.count - 1 if !ap_ult(ap_sub(max_offset, sorted[i].offset), max_diff) return false;
        array_add(out, sorted[0]);
        array_add(out, sorted[sorted.count - 1]);
    }
    return out.count != old_count;
}

// GuardWideningPass::run(Function &F, ...)
guard_widening_run :: (f: Value_Id) -> Preserved {
    guard_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_GUARD);
    has_intrinsic_guards := guard_decl != NONE && has_uses(guard_decl);
    wc_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_WIDENABLE_CONDITION);
    has_widenable_conditions := wc_decl != NONE && has_uses(wc_decl);
    if !has_intrinsic_guards && !has_widenable_conditions return PRESERVE_ALL;
    g: Guard_Widening;
    g.dt = get_domtree(f);
    g.li = get_loop_info(f);
    g.pdt = get_postdomtree(f);
    g.ac = get_assumption_cache(f);
    mssa := cached_memoryssa(f);
    mssau_storage: Mssa_Updater;
    if mssa { mssau_storage.mssa = mssa; g.mssau = *mssau_storage; }
    g.root = fn_entry(f);
    g.filter_loop = NONE;
    g.guards_in_block.allocator = temp;
    g.widened.allocator = temp;
    g.eliminated.allocator = temp;
    if !gw_run(*g) return PRESERVE_ALL;
    pa: Preserved;
    pa.cfg = true;
    preserve(*pa, .MEMORYSSA);
    return pa;
}

// GuardWideningPass::run(Loop &L, ...)
guard_widening_loop_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    root := li_loop_predecessor(lar.li, l);
    if root == NONE root = li_header(lar.li, l);
    g: Guard_Widening;
    g.dt = lar.dt; g.li = lar.li; g.ac = lar.ac; g.pdt = null;
    mssau_storage: Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; g.mssau = *mssau_storage; }
    g.root = root;
    g.filter_loop = l;
    g.guards_in_block.allocator = temp;
    g.widened.allocator = temp;
    g.eliminated.allocator = temp;
    if !gw_run(*g) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
