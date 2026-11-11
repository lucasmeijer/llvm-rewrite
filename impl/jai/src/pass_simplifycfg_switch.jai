// SimplifyCFG.cpp, fourth part: switches, icmp chains, conditional branch pairs, stores, invokes, EH, unreachable.

// ---------------------------------------------------------------- mergeCompatibleInvokes

// CompatibleSets::shouldBelongToSameSet({a, b})
invokes_should_belong_to_same_set :: (a: Value_Id, b: Value_Id) -> bool {
    illegal :: (ii: Value_Id) -> bool { return call_cannot_merge(ii) || call_is_inline_asm(ii); }
    if illegal(a) || illegal(b) return false;
    ia := call_is_indirect(a); ib := call_is_indirect(b);
    if ia || ib {
        if !(ia && ib) return false;
    } else if call_callee(a) != call_callee(b) return false;
    has_normal :: (ii: Value_Id) -> bool { return inst_op(block_first_non_phi_or_dbg(invoke_normal_dest(ii))) != .UNREACHABLE; }
    if has_normal(a) || has_normal(b) {
        if !(has_normal(a) && has_normal(b)) return false;
        if invoke_normal_dest(a) != invoke_normal_dest(b) return false;
        if !incoming_values_are_compatible(invoke_normal_dest(a), inst_block(a), inst_block(b), .[a, b]) return false;
    }
    if !incoming_values_are_compatible(invoke_unwind_dest(a), inst_block(a), inst_block(b)) return false;
    if !is_same_operation_as(b, a, intersect_attrs = true) return false;
    // data operands: arguments and bundle operands (everything before normal dest, unwind dest, callee)
    nd := nops(a) - 3;
    for k: 0..cast(s64) nd - 1 {
        if op(a, cast(u32) k) == op(b, cast(u32) k) continue;
        if !can_replace_operand_with_variable(a, cast(u32) k) return false;
    }
    return true;
}

// mergeCompatibleInvokesImpl
merge_compatible_invokes_impl :: (s: *Scfg, invokes: [] Value_Id) {
    ups: [..] Dom_Update; ups.allocator = temp;
    ii0 := invokes[0];
    has_normal := inst_op(block_first_non_phi_or_dbg(invoke_normal_dest(ii0))) != .UNREACHABLE;
    ii0bb := inst_block(ii0);
    f := block_fn(ii0bb);
    insert_before := block(ii0bb).next;
    merged_bb := create_block(f, tprint("%.invoke", vname(ii0bb)), insert_before);
    merged := ic_clone_inst(ii0);
    block_append_inst(merged_bb, merged);
    if !has_normal {
        nd := create_block(f, tprint("%.cont", vname(ii0bb)), insert_before);
        block_append_inst(nd, new_inst(.UNREACHABLE, ir.t_void, 0));
        set_successor(merged, 0, nd);
    }
    if s.dtu {
        for invokes array_add(*ups, .{true, inst_block(it), merged_bb});
        for k: 0..1 array_add(*ups, .{true, merged_bb, get_successor(merged, cast(u32) k)});
        for ii: invokes for k: 0..1 array_add(*ups, .{false, inst_block(ii), get_successor(ii, cast(u32) k)});
    }
    indirect := call_is_indirect(ii0);
    n := nops(merged);
    for k: 0..cast(s64) n - 1 {
        idx := cast(u32) k;
        if idx == n - 1 { if !indirect continue; }
        else if idx >= n - 3 continue;
        cur := op(merged, idx);
        need := false;
        for invokes if op(it, idx) != cur need = true;
        if !need continue;
        pn := create_phi(vtype(cur), cast(u32) invokes.count);
        inst_insert_before(pn, merged);
        for invokes phi_add_incoming(pn, op(it, idx), inst_block(it));
        set_op(merged, idx, pn);
    }
    for k: 0..1 add_predecessor_to_block(get_successor(merged, cast(u32) k), merged_bb, inst_block(ii0));
    merged_loc: Md_Id = NONE;
    first := true;
    for ii: invokes {
        loc := get_metadata(ii, 0);
        if first { merged_loc = loc; first = false; }
        else merged_loc = merged_location(merged_loc, loc);
        pbb := inst_block(ii);
        for k: 0..1 block_remove_predecessor(get_successor(ii, cast(u32) k), pbb);
        br := create_br(merged_bb);
        block_append_inst(pbb, br);
        copy_debug_loc(br, ii);
        try_intersect_attributes(merged, ii);
        rauw_with_metadata(ii, merged);
        erase_inst_with_metadata(ii);
    }
    set_metadata(merged, 0, merged_loc);
    if s.dtu dtu_apply(s.dtu, ups);
}

// mergeCompatibleInvokes
merge_compatible_invokes :: (s: *Scfg, bb: Value_Id) -> bool {
    if !scfg_cl.enable_merge_compatible_invokes return false;
    if !block_is_landing_pad(bb) return false;
    sets: [..] [..] Value_Id; sets.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        ii := block_terminator(p);
        placed := false;
        for * set: sets if invokes_should_belong_to_same_set(set.*[0], ii) { array_add(set, ii); placed = true; break; }
        if !placed { ns: [..] Value_Id; ns.allocator = temp; array_add(*ns, ii); array_add(*sets, ns); }
    }
    changed := false;
    for sets {
        if it.count < 2 continue;
        changed = true;
        merge_compatible_invokes_impl(s, it);
    }
    return changed;
}

// ---------------------------------------------------------------- EH: resume, cleanupret

simplify_resume :: (s: *Scfg, ri: Value_Id, b: *Irb) -> bool {
    v := op(ri, 0);
    if is_phi(v) return simplify_common_resume(s, ri);
    f := block_first_non_phi(inst_block(ri));
    if inst_op(f) == .LANDINGPAD && v == f return simplify_single_resume(s, ri);
    return false;
}
// isCleanupBlockEmpty over [from, to)
is_cleanup_block_empty :: (from: Value_Id, to: Value_Id) -> bool {
    i := from;
    while i != to {
        id := call_iid(i);
        if id == NOT_INTRINSIC return false;
        n := iid_name(id);
        if n != "llvm.dbg.declare" && n != "llvm.dbg.value" && n != "llvm.dbg.label" && n != "llvm.lifetime.end" return false;
        i = inst_next(i);
    }
    return true;
}
simplify_common_resume :: (s: *Scfg, ri: Value_Id) -> bool {
    bb := inst_block(ri);
    if !is_cleanup_block_empty(block_first_non_phi(bb), block_terminator(bb)) return false;
    trivial: [..] Value_Id; trivial.allocator = temp;
    pl := op(ri, 0);
    for k: 0..cast(s64) nops(pl) - 1 {
        ib := phi_block(pl, cast(u32) k);
        iv := phi_value(pl, cast(u32) k);
        if block_unique_successor_of(ib) != bb continue;
        lp := block_first_non_phi(ib);
        if inst_op(lp) != .LANDINGPAD || iv != lp continue;
        if is_cleanup_block_empty(inst_next(lp), block_terminator(ib)) && !block_set_contains(trivial, ib) array_add(*trivial, ib);
    }
    if trivial.count == 0 return false;
    for tb: trivial {
        while phi_block_index(pl, tb) != -1 block_remove_predecessor(bb, tb, true);
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(tb, *preds);
        for preds remove_unwind_edge(it, s.dtu);
        erase_terminator(block_terminator(tb));
        block_append_inst(tb, new_inst(.UNREACHABLE, ir.t_void, 0));
        dtu_apply1(s.dtu, false, tb, bb);
    }
    if !block_has_predecessors(bb) delete_dead_block(bb, s.dtu);
    return true;
}
simplify_single_resume :: (s: *Scfg, ri: Value_Id) -> bool {
    bb := inst_block(ri);
    lp := block_first_non_phi(bb);
    if !is_cleanup_block_empty(inst_next(lp), ri) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for preds remove_unwind_edge(it, s.dtu);
    delete_dead_block(bb, s.dtu);
    return true;
}
cleanupret_unwind_dest :: (ri: Value_Id) -> Value_Id { if nops(ri) > 1 return op(ri, 1); return NONE; }
// Instruction::isUsedOutsideOfBlock
is_used_outside_of_block :: (i: Value_Id, bb: Value_Id) -> bool {
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        ub := ifx inst_op(user) == .PHI then ir.u_aux[u] else inst_block(user);
        if ub != bb return true;
        u = ir.u_next[u];
    }
    return false;
}
remove_empty_cleanup :: (s: *Scfg, ri: Value_Id) -> bool {
    bb := inst_block(ri);
    cp := op(ri, 0);
    if inst_block(cp) != bb return false;
    if num_uses(cp) != 1 return false;
    if !is_cleanup_block_empty(inst_next(cp), ri) return false;
    unwind := cleanupret_unwind_dest(ri);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    if unwind != NONE {
        for dpn: block_insts(unwind) {
            if inst_op(dpn) != .PHI break;
            idx := phi_block_index(dpn, bb);
            sv := phi_value(dpn, cast(u32) idx);
            translate := is_phi(sv) && inst_block(sv) == bb;
            for p: preds phi_add_incoming(dpn, ifx translate then phi_incoming_value_for_block(sv, p) else sv, p);
        }
        ins := block_first_non_phi(unwind);
        for :early_inc pn: block_insts(bb) {
            if inst_op(pn) != .PHI break;
            if !has_uses(pn) || !is_used_outside_of_block(pn, bb) continue;
            up: [..] Value_Id; up.allocator = temp;
            block_predecessors(unwind, *up);
            for p: up if p != bb phi_add_incoming(pn, pn, p);
            inst_move_before_dbg(pn, ins);
            phi_add_incoming(pn, const_poison(vtype(pn)), bb);
        }
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    for p: preds {
        if unwind == NONE {
            if s.dtu { dtu_apply(s.dtu, updates); updates.count = 0; }
            remove_unwind_edge(p, s.dtu);
        } else {
            block_remove_predecessor(bb, p);
            replace_uses_of_with(block_terminator(p), bb, unwind);
            if s.dtu { array_add(*updates, .{true, p, unwind}); array_add(*updates, .{false, p, bb}); }
        }
    }
    if s.dtu dtu_apply(s.dtu, updates);
    delete_dead_block(bb, s.dtu);
    return true;
}
merge_cleanup_pad :: (ri: Value_Id) -> bool {
    unwind := cleanupret_unwind_dest(ri);
    if unwind == NONE return false;
    if block_single_predecessor(unwind) != inst_block(ri) return false;
    scp := block_first(unwind);
    if inst_op(scp) != .CLEANUPPAD return false;
    pcp := op(ri, 0);
    rauw_with_metadata(scp, pcp);
    erase_inst_with_metadata(scp);
    block_append_inst(inst_block(ri), create_br(unwind));
    erase_terminator(ri);
    return true;
}
simplify_cleanup_return :: (s: *Scfg, ri: Value_Id) -> bool {
    if is_undef_value(op(ri, 0)) return false;
    if merge_cleanup_pad(ri) return true;
    if remove_empty_cleanup(s, ri) return true;
    return false;
}

// ---------------------------------------------------------------- unreachable

// CatchSwitchInst::removeHandler: later handlers shift down
catchswitch_remove_handler :: (csi: Value_Id, k: u32) {
    n := nops(csi);
    for j: k..n-2 set_op(csi, j, op(csi, j + 1));
    use_set(op_use(csi, n - 1), NONE);
    ir.v_nops[csi] = n - 1;
}
catchswitch_first_handler :: (csi: Value_Id) -> u32 { return ifx (inst(csi).flags & F_HAS_UNWIND) != 0 then cast(u32) 2 else 1; }
catchswitch_unwind_dest :: (csi: Value_Id) -> Value_Id { if inst(csi).flags & F_HAS_UNWIND return op(csi, 1); return NONE; }

simplify_unreachable :: (s: *Scfg, ui: Value_Id) -> bool {
    bb := inst_block(ui);
    changed := false;
    drop_dbg_records(ui);
    while block_first(bb) != ui {
        p := inst_prev(ui);
        if !is_guaranteed_to_transfer_execution(p) break;
        drop_dbg_records(p);
        rauw_with_metadata(p, const_poison(vtype(p)));
        erase_inst_with_metadata(p);
        changed = true;
    }
    if block_first(bb) != ui return changed;
    updates: [..] Dom_Update; updates.allocator = temp;
    pa: [..] Value_Id; pa.allocator = temp;
    block_predecessors(bb, *pa);
    preds: [..] Value_Id; preds.allocator = temp;
    for pa if !block_set_contains(preds, it) array_add(*preds, it);
    for pred: preds {
        ti := block_terminator(pred);
        o := inst_op(ti);
        if o == .BR {
            insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), pred, ti, false);
            erase_terminator(ti);
            changed = true;
            if s.dtu array_add(*updates, .{false, pred, bb});
        } else if o == .CONDBR {
            if get_successor(ti, 0) == get_successor(ti, 1) {
                insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), pred, ti, false);
                erase_terminator(ti);
                changed = true;
            } else {
                b: Irb; irb_set_before(*b, ti);
                c := op(ti, 0);
                a: Value_Id;
                if get_successor(ti, 0) == bb {
                    nc := irb_not(*b, c);
                    args := Value_Id.[nc];
                    a = irb_intrinsic(*b, "llvm.assume", .[], args);
                    irb_br(*b, get_successor(ti, 1));
                } else {
                    args := Value_Id.[c];
                    a = irb_intrinsic(*b, "llvm.assume", .[], args);
                    irb_br(*b, get_successor(ti, 0));
                }
                if s.opts.ac ac_register_assumption(s.opts.ac, a);
                erase_terminator_and_dce_cond(ti);
                changed = true;
            }
            if s.dtu array_add(*updates, .{false, pred, bb});
        } else if o == .SWITCH {
            p: Sw_Prof; sw_prof_init(*p, ti);
            k: u32 = 0;
            while k < sw_num_cases(ti) {
                if sw_case_dest(ti, k) != bb { k += 1; continue; }
                block_remove_predecessor(bb, inst_block(ti));
                sw_prof_remove_case(*p, k);
                changed = true;
            }
            sw_prof_done(*p);
            if s.dtu && sw_default(ti) != bb array_add(*updates, .{false, pred, bb});
        } else if o == .INVOKE {
            if invoke_unwind_dest(ti) == bb {
                if s.dtu { dtu_apply(s.dtu, updates); updates.count = 0; }
                ci := remove_unwind_edge(inst_block(ti), s.dtu);
                if !call_does_not_throw(ci) call_add_fn_attr(ci, .NoUnwind);
                changed = true;
            }
        } else if o == .CATCHSWITCH {
            if catchswitch_unwind_dest(ti) == bb {
                if s.dtu { dtu_apply(s.dtu, updates); updates.count = 0; }
                remove_unwind_edge(inst_block(ti), s.dtu);
                changed = true;
                continue;
            }
            k := catchswitch_first_handler(ti);
            while k < nops(ti) {
                if op(ti, k) == bb { catchswitch_remove_handler(ti, k); changed = true; }
                else k += 1;
            }
            if s.dtu array_add(*updates, .{false, pred, bb});
            if nops(ti) == catchswitch_first_handler(ti) {
                ud := catchswitch_unwind_dest(ti);
                if ud != NONE {
                    if s.dtu {
                        pp: [..] Value_Id; pp.allocator = temp;
                        block_predecessors(pred, *pp);
                        for pp { array_add(*updates, .{true, it, ud}); array_add(*updates, .{false, it, pred}); }
                    }
                    replace_all_uses_with(pred, ud);
                } else {
                    if s.dtu { dtu_apply(s.dtu, updates); updates.count = 0; }
                    eh: [..] Value_Id; eh.allocator = temp;
                    block_predecessors(pred, *eh);
                    for eh remove_unwind_edge(it, s.dtu);
                }
                insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), pred, ti, false);
                erase_terminator(ti);
                changed = true;
            }
        } else if o == .CLEANUPRET {
            if s.dtu array_add(*updates, .{false, pred, bb});
            insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), pred, ti, false);
            erase_terminator(ti);
            changed = true;
        }
    }
    if s.dtu dtu_apply(s.dtu, updates);
    if !block_has_predecessors(bb) && bb != fn_entry(block_fn(bb)) {
        delete_dead_block(bb, s.dtu);
        return true;
    }
    return changed;
}

// ---------------------------------------------------------------- merging identical successor/predecessor blocks

// EqualBBWrapper::canBeMerged
ebw_can_be_merged :: (bb: Value_Id) -> bool {
    if bb == fn_entry(block_fn(bb)) return false;
    t := block_terminator(bb);
    if inst_op(t) != .BR return false;
    if block_has_address_taken(bb) || block_is_eh_pad(bb) return false;
    if block_first(bb) != block_last(bb) return false;
    if !block_has_predecessors(bb) return false;
    return true;
}
// mergeIdenticalBBs
merge_identical_bbs :: (s: *Scfg, cands: [] Value_Id) -> bool {
    if cands.count < 2 return false;
    // PhiPredIVs: the first incoming value of each block, per phi of the successors
    first_iv :: (phi: Value_Id, b: Value_Id) -> Value_Id {
        for k: 0..cast(s64) nops(phi) - 1 if phi_block(phi, cast(u32) k) == b return phi_value(phi, cast(u32) k);
        return NONE;
    }
    equal :: (a: Value_Id, b: Value_Id) -> bool {
        sa := get_successor(block_terminator(a), 0);
        if sa != get_successor(block_terminator(b), 0) return false;
        for phi: block_insts(sa) {
            if inst_op(phi) != .PHI break;
            if first_iv(phi, a) != first_iv(phi, b) return false;
        }
        return true;
    }
    keep: [..] Value_Id; keep.allocator = temp;
    updates: [..] Dom_Update; updates.allocator = temp;
    made := false;
    for bb: cands {
        found: Value_Id = NONE;
        for keep if equal(it, bb) { found = it; break; }
        if found == NONE { array_add(*keep, bb); continue; }
        if found == bb continue;
        dead := bb; live := found;
        dp_all: [..] Value_Id; dp_all.allocator = temp;
        block_predecessors(dead, *dp_all);
        dead_preds: [..] Value_Id; dead_preds.allocator = temp;
        for dp_all if !block_set_contains(dead_preds, it) array_add(*dead_preds, it);
        if s.dtu {
            lp: [..] Value_Id; lp.allocator = temp;
            block_predecessors(live, *lp);
            for p: dead_preds {
                if !block_set_contains(lp, p) array_add(*updates, .{true, p, live});
                array_add(*updates, .{false, p, dead});
            }
        }
        for p: dead_preds replace_successor_with(block_terminator(p), dead, live);
        made = true;
    }
    if s.dtu && updates.count dtu_apply(s.dtu, updates);
    return made;
}
simplify_duplicate_switch_arms :: (s: *Scfg, si: Value_Id) -> bool {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(inst_block(si), *succs);
    f: [..] Value_Id; f.allocator = temp;
    for succs if ebw_can_be_merged(it) && !block_set_contains(f, it) array_add(*f, it);
    return merge_identical_bbs(s, f);
}
simplify_duplicate_predecessors :: (s: *Scfg, bb: Value_Id) -> bool {
    if bb == NONE || !block_has_n_predecessors_or_more(bb, 2) return false;
    if s.opts.need_canonical_loop && is_loop_header(s, bb) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    f: [..] Value_Id; f.allocator = temp;
    for preds if ebw_can_be_merged(it) && !block_set_contains(f, it) array_add(*f, it);
    return merge_identical_bbs(s, f);
}

// ---------------------------------------------------------------- indirectbr

simplify_indirect_br :: (s: *Scfg, ibi: Value_Id) -> bool {
    bb := inst_block(ibi);
    changed := false;
    hw, bw := prof_extract_branch_weights(ibi);
    tw_keys: [..] Value_Id; tw_keys.allocator = temp;
    tw_vals: [..] u64; tw_vals.allocator = temp;
    if hw for k: 0..cast(s64) nops(ibi) - 2 {
        d := op(ibi, cast(u32) (k + 1));
        idx := -1;
        for tw_keys if it == d idx = it_index;
        if idx < 0 { array_add(*tw_keys, d); array_add(*tw_vals, 0); idx = tw_keys.count - 1; }
        tw_vals[idx] += bw[k];
    }
    seen: [..] Value_Id; seen.allocator = temp;
    removed: [..] Value_Id; removed.allocator = temp;
    k: u32 = 0;
    while k + 1 < nops(ibi) {
        d := op(ibi, k + 1);
        if !block_has_address_taken(d) || block_set_contains(seen, d) {
            if !block_has_address_taken(d) && !block_set_contains(removed, d) array_add(*removed, d);
            block_remove_predecessor(d, bb);
            indirectbr_remove_destination(ibi, k);
            changed = true;
            continue;
        }
        array_add(*seen, d);
        k += 1;
    }
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        for removed array_add(*ups, .{false, bb, it});
        dtu_apply(s.dtu, ups);
    }
    if nops(ibi) == 1 {
        insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), bb, ibi, false);
        erase_terminator_and_dce_cond(ibi);
        return true;
    }
    if nops(ibi) == 2 {
        insert_at_position(create_br(op(ibi, 1)), bb, ibi, false);
        erase_terminator_and_dce_cond(ibi);
        return true;
    }
    if hw {
        nw := NewArray(nops(ibi) - 1, u64,, allocator = temp);
        for j: 0..nw.count-1 { d := op(ibi, cast(u32) (j + 1)); for tw_keys if it == d nw[j] += tw_vals[it_index]; }
        prof_set_fitted_branch_weights(ibi, nw, false);
    }
    a := op(ibi, 0);
    if is_inst(a) && inst_op(a) == .SELECT && simplify_indirect_br_on_select(s, ibi, a) return request_resimplify(s);
    return changed;
}
// IndirectBrInst::removeDestination: the last destination moves into the hole
indirectbr_remove_destination :: (ibi: Value_Id, k: u32) {
    n := nops(ibi);
    idx := k + 1;
    if idx != n - 1 set_op(ibi, idx, op(ibi, n - 1));
    use_set(op_use(ibi, n - 1), NONE);
    ir.v_nops[ibi] = n - 1;
}

// ---------------------------------------------------------------- switch: range to icmp, dead cases, forwarding

// constantIntSortPredicate: descending
sort_cases_desc :: (cases: *[..] Value_Id) {
    // insertion sort (stable, small)
    for i: 1..cases.count-1 {
        x := cases.*[i];
        j := i - 1;
        while j >= 0 && ap_ult(cf_ap(cases.*[j]), cf_ap(x)) { cases.*[j + 1] = cases.*[j]; j -= 1; }
        cases.*[j + 1] = x;
    }
}
Contiguous :: struct { ok: bool; mn: Value_Id; mx: Value_Id; dest: Value_Id; other_dest: Value_Id; cases: *[..] Value_Id; other_cases: *[..] Value_Id; }
find_contiguous_cases :: (cond: Value_Id, cases: *[..] Value_Id, other: *[..] Value_Id, dest: Value_Id, other_dest: Value_Id) -> Contiguous {
    r: Contiguous;
    sort_cases_desc(cases);
    mn := cf_ap(cases.*[cases.count - 1]);
    mx := cf_ap(cases.*[0]);
    off := ap_sub(mx, mn);
    if ap_eq(off, ap_from_u64(off.bits, cast(u64) (cases.count - 1))) return .{true, cases.*[cases.count - 1], cases.*[0], dest, other_dest, cases, other};
    q: Simplify_Query;
    cr := compute_constant_range(cond, false, q);
    if ap_eq(mx, cr_umax(cr)) && ap_eq(mn, cr_umin(cr)) {
        k := -1;
        for i: 0..cases.count-2 {
            if !ap_eq(cf_ap(cases.*[i]), ap_add(cf_ap(cases.*[i + 1]), ap_from_u64(mn.bits, 1))) { k = i; break; }
        }
        if k < 0 return r;
        omax := cf_ap(cases.*[k]); omin := cf_ap(cases.*[k + 1]);
        sum := ap_add(ap_sub(mx, omax), ap_sub(omin, mn));
        if ap_eq(sum, ap_from_u64(sum.bits, cast(u64) (cases.count - 2))) {
            t := vtype(cases.*[0]);
            return .{true, const_int_words(t, ap_words(ap_add(omin, ap_from_u64(mn.bits, 1)))), const_int_words(t, ap_words(ap_sub(omax, ap_from_u64(mn.bits, 1)))), other_dest, dest, other, cases};
        }
    }
    return r;
}
// createUnreachableSwitchDefault
create_unreachable_switch_default :: (s: *Scfg, sw: Value_Id, remove_orig := true) {
    bb := inst_block(sw);
    orig := sw_default(sw);
    if remove_orig block_remove_predecessor(orig, bb);
    nd := create_block(block_fn(bb), tprint("%.unreachabledefault", vname(bb)), orig);
    block_append_inst(nd, new_inst(.UNREACHABLE, ir.t_void, 0));
    sw_set_default(sw, nd);
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        array_add(*ups, .{true, bb, nd});
        if remove_orig && !succ_contains(bb, orig) array_add(*ups, .{false, bb, orig});
        dtu_apply(s.dtu, ups);
    }
}
turn_switch_range_into_icmp :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    has_default := !sw_default_dest_unreachable(si);
    bb := inst_block(si);
    da: Value_Id = ifx has_default then sw_default(si) else NONE;
    db: Value_Id = NONE;
    ca: [..] Value_Id; ca.allocator = temp;
    cb: [..] Value_Id; cb.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        d := sw_case_dest(si, cast(u32) k);
        if da == NONE da = d;
        if d == da { array_add(*ca, sw_case_value(si, cast(u32) k)); continue; }
        if db == NONE db = d;
        if d == db { array_add(*cb, sw_case_value(si, cast(u32) k)); continue; }
        return false;
    }
    if db == NONE return false;
    cc: Contiguous;
    if !has_default && ca.count == 1 cc = .{true, ca[0], ca[0], da, db, *ca, *cb};
    else if cb.count == 1 cc = .{true, cb[0], cb[0], db, da, *cb, *ca};
    else if !has_default cc = find_contiguous_cases(sw_cond(si), *ca, *cb, da, db);
    if !cc.ok cc = find_contiguous_cases(sw_cond(si), *cb, *ca, db, da);
    if !cc.ok return false;
    offset := ce_neg(cc.mn);
    num := const_int_words(vtype(offset), ap_words(ap_add(ap_sub(cf_ap(cc.mx), cf_ap(cc.mn)), ap_from_u64(cf_ap(cc.mn).bits, 1))));
    nbi: Value_Id;
    if ap_is_one(cf_ap(num)) {
        cmp := irb_icmp(b, ICMP_EQ, sw_cond(si), cc.mn);
        nbi = irb_cond_br(b, cmp, cc.dest, cc.other_dest);
    } else if ap_is_zero(cf_ap(num)) && cc.cases.count > 0 {
        nbi = irb_br(b, cc.dest);
    } else {
        sub := sw_cond(si);
        if !is_null_value(offset) sub = irb_binop(b, .ADD, sub, offset, tprint("%.off", vname(sub)));
        cmp := irb_icmp(b, ICMP_ULT, sub, num, "switch");
        nbi = irb_cond_br(b, cmp, cc.dest, cc.other_dest);
    }
    if prof_has_branch_weight_md(si) && inst_op(nbi) == .CONDBR {
        w := scfg_get_branch_weights(si);
        if w.count == 1 + sw_num_cases(si) {
            tw: u64 = 0; fw: u64 = 0;
            for k: 0..w.count-1 { if get_successor(si, cast(u32) k) == cc.dest tw += w[k]; else fw += w[k]; }
            while tw > 0xFFFF_FFFF || fw > 0xFFFF_FFFF { tw /= 2; fw /= 2; }
            ww := u64.[tw, fw];
            prof_set_fitted_branch_weights(nbi, ww, false, true);
        }
    }
    for :early_inc phi: block_insts(cc.dest) {
        if inst_op(phi) != .PHI break;
        prev := cc.cases.count;
        if cc.dest == sw_default(si) prev += 1;
        for 0..prev-2 phi_remove_incoming_block(phi, inst_block(si));
    }
    for :early_inc phi: block_insts(cc.other_dest) {
        if inst_op(phi) != .PHI break;
        prev := cc.other_cases.count;
        if cc.other_dest == sw_default(si) prev += 1;
        e := prev - 1;
        if inst_op(nbi) == .BR e += 1;
        for 0..e-1 phi_remove_incoming_block(phi, inst_block(si));
    }
    if !has_default create_unreachable_switch_default(s, si);
    ud := sw_default(si);
    erase_terminator(si);
    if !has_default dtu_apply1(s.dtu, false, bb, ud);
    return true;
}

// collectPossibleValues(V, Constants, MaxCount, AllowUndefOrPoison = true)
collect_possible_values :: (v: Value_Id, out: *[..] Value_Id, max_count: s64) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    push :: (x: Value_Id, out: *[..] Value_Id, max_count: s64, visited: *[..] Value_Id, work: *[..] Value_Id) -> bool {
        if is_imm_constant(x) {
            if block_set_contains(out.*, x) return true;
            if out.count == max_count return false;
            array_add(out, x);
            return true;
        }
        if is_inst(x) {
            if !block_set_contains(visited.*, x) { array_add(visited, x); array_add(work, x); }
            return true;
        }
        return false;
    }
    if !push(v, out, max_count, *visited, *work) return false;
    while work.count {
        c := pop(*work);
        if inst_op(c) == .SELECT {
            if !push(op(c, 1), out, max_count, *visited, *work) return false;
            if !push(op(c, 2), out, max_count, *visited, *work) return false;
        } else if inst_op(c) == .PHI {
            for k: 0..cast(s64) nops(c) - 1 {
                iv := phi_value(c, cast(u32) k);
                if iv == c continue;
                if !push(iv, out, max_count, *visited, *work) return false;
            }
        } else return false;
    }
    return true;
}

// eliminateDeadSwitchCases
eliminate_dead_switch_cases :: (s: *Scfg, si: Value_Id) -> bool {
    cond := sw_cond(si);
    known := known_bits_ctx(cond, si, null, s.opts.ac);
    kv: [..] Value_Id; kv.allocator = temp;
    kv_valid := collect_possible_values(cond, *kv, 4);
    // ComputeMaxSignificantBits(Cond, DL, AC, SI): its Depth argument (0) lands in ComputeNumSignBits'
    // UseInstrInfo parameter, so nsw/nuw/exact flags are ignored
    msq: Simplify_Query; msq.ac = s.opts.ac; msq.cxt = safe_cxt(cond, si); msq.use_instr_info = false;
    max_sig := type_bits(vtype(cond)) - num_sign_bits(cond, msq) + 1;
    dead: [..] Value_Id; dead.allocator = temp;
    ps_keys: [..] Value_Id; ps_keys.allocator = temp;
    ps_cnt: [..] s64; ps_cnt.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        succ := sw_case_dest(si, cast(u32) k);
        idx := -1;
        if s.dtu {
            for ps_keys if it == succ idx = it_index;
            if idx < 0 { array_add(*ps_keys, succ); array_add(*ps_cnt, 0); idx = ps_keys.count - 1; }
            ps_cnt[idx] += 1;
        }
        c := sw_case_value(si, cast(u32) k);
        cv := cf_ap(c);
        if ap_intersects(known.zero, cv) || !ap_is_subset_of(known.one, cv) || ap_significant_bits(cv) > max_sig ||
           (kv_valid && !block_set_contains(kv, c)) {
            array_add(*dead, c);
            if s.dtu ps_cnt[idx] -= 1;
        } else if kv_valid {
            for kv if it == c { array_ordered_remove_by_index(*kv, it_index); break; }
        }
    }
    has_default := !sw_default_dest_unreachable(si);
    unknown_bits := kb_bits(known) - ap_popcount(ap_or(known.zero, known.one));
    if has_default && dead.count == 0 {
        all_undef := true;
        for kv if !is_undef_value(it) all_undef = false;
        if kv_valid && all_undef { create_unreachable_switch_default(s, si); return true; }
        if unknown_bits < 64 {
            all_num: u64 = (cast(u64) 1) << cast(u64) unknown_bits;
            if cast(u64) sw_num_cases(si) == all_num { create_unreachable_switch_default(s, si); return true; }
            if cast(u64) sw_num_cases(si) == all_num - 1 {
                w := type_int_width(vtype(cond));
                if w > 64 || !dl_fits_in_legal_integer(w) return false;
                missing: u64 = 0;
                for k: 0..cast(s64) sw_num_cases(si) - 1 missing ^= ap_limited_value(cf_ap(sw_case_value(si, cast(u32) k)));
                mc := const_int(vtype(cond), missing);
                p: Sw_Prof; sw_prof_init(*p, si);
                hw, w0 := sw_prof_get_weight(*p, 0);
                sw_prof_add_case(*p, mc, sw_default(si), hw, w0);
                create_unreachable_switch_default(s, si, false);
                sw_prof_set_weight(*p, 0, true, 0);
                sw_prof_done(*p);
                return true;
            }
        }
    }
    if dead.count == 0 return false;
    p: Sw_Prof; sw_prof_init(*p, si);
    for dc: dead {
        k := sw_find_case_value(si, dc);
        block_remove_predecessor(sw_case_dest(si, cast(u32) k), inst_block(si));
        sw_prof_remove_case(*p, cast(u32) k);
    }
    sw_prof_done(*p);
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        for ps_keys if ps_cnt[it_index] == 0 array_add(*ups, .{false, inst_block(si), it});
        dtu_apply(s.dtu, ups);
    }
    return true;
}
// DataLayout::fitsInLegalInteger: dl_fits_in_legal_integer (ic_compares.jai)
// APInt::getLimitedValue()
ap_limited_value :: (a: APInt) -> u64 {
    if ap_active_bits(a) > 64 return U64_MAX;
    return ap_zext_value(a);
}

// findPHIForConditionForwarding
find_phi_for_condition_forwarding :: (case_value: Value_Id, bb: Value_Id) -> (Value_Id, s64) {
    if block_first_non_phi(bb) != block_terminator(bb) return NONE, 0;
    if block_single_predecessor(bb) == NONE return NONE, 0;
    br := block_terminator(bb);
    if inst_op(br) != .BR return NONE, 0;
    succ := get_successor(br, 0);
    for phi: block_insts(succ) {
        if inst_op(phi) != .PHI break;
        idx := phi_block_index(phi, bb);
        if phi_value(phi, cast(u32) idx) != case_value continue;
        return phi, idx;
    }
    return NONE, 0;
}
forward_switch_condition_to_phi :: (si: Value_Id) -> bool {
    fk: [..] Value_Id; fk.allocator = temp;
    fv: [..] [..] s64; fv.allocator = temp;
    sb := inst_block(si);
    changed := false;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        cv := sw_case_value(si, cast(u32) k);
        cd := sw_case_dest(si, cast(u32) k);
        for phi: block_insts(cd) {
            if inst_op(phi) != .PHI break;
            idx := phi_block_index(phi, sb);
            cnt := 0;
            for j: 0..cast(s64) nops(phi) - 1 if phi_block(phi, cast(u32) j) == sb cnt += 1;
            if phi_value(phi, cast(u32) idx) == cv && cnt == 1 { phi_set_value(phi, cast(u32) idx, sw_cond(si)); changed = true; }
        }
        phi, pidx := find_phi_for_condition_forwarding(cv, cd);
        if phi != NONE {
            ix := -1;
            for fk if it == phi ix = it_index;
            if ix < 0 { array_add(*fk, phi); l: [..] s64; l.allocator = temp; array_add(*fv, l); ix = fk.count - 1; }
            array_add(*fv[ix], pidx);
        }
    }
    for phi, ix: fk {
        idxs := fv[ix];
        has_cond := false;
        for j: 0..cast(s64) nops(phi) - 1 if phi_value(phi, cast(u32) j) == sw_cond(si) has_cond = true;
        if idxs.count < 2 && !has_cond continue;
        for idxs phi_set_value(phi, cast(u32) it, sw_cond(si));
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- switch to select

// validLookupTableConstant
valid_lookup_table_constant :: (s: *Scfg, c: Value_Id) -> bool {
    if const_is_thread_dependent(c) return false;
    if const_is_dll_import_dependent(c) return false;
    k := vkind(c);
    is_cdv := k == .C_DATA && is_vector_type(vtype(c));
    if !(is_cdv || k == .C_EXPR || k == .C_FP || k == .C_INT || k == .C_NULL || is_global_value(k) || k == .C_UNDEF || k == .C_POISON) return false;
    if type_kind(vtype(c)) == .SVECTOR return false;
    if k == .C_EXPR {
        stripped := strip_in_bounds_constant_offsets(c);
        if stripped == c || !valid_lookup_table_constant(s, stripped) return false;
    }
    if !tti_should_build_lookup_tables_for_constant(s.tti, c) return false;
    return true;
}
// Constant::isThreadDependent / isDLLImportDependent: a thread_local / dllimport global reachable through operands
const_is_thread_dependent :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .GLOBAL_VAR return glob(c).tls != 0;
    if k == .C_EXPR || k == .C_VECTOR || k == .C_ARRAY || k == .C_STRUCT {
        for j: 0..cast(s64) nops(c) - 1 if const_is_thread_dependent(op(c, cast(u32) j)) return true;
    }
    return false;
}
const_is_dll_import_dependent :: (c: Value_Id) -> bool {
    k := vkind(c);
    if is_global_value(k) return glob(c).dll == 1;
    if k == .C_EXPR || k == .C_VECTOR || k == .C_ARRAY || k == .C_STRUCT {
        for j: 0..cast(s64) nops(c) - 1 if const_is_dll_import_dependent(op(c, cast(u32) j)) return true;
    }
    return false;
}
// Value::stripInBoundsConstantOffsets on a constant
// Value::stripInBoundsConstantOffsets: strip_in_bounds_constant_offsets (value_tracking2.jai)

Case_Res :: struct { phi: Value_Id; c: Value_Id; }
Cp :: struct { keys: [..] Value_Id; vals: [..] Value_Id; }   // SmallDenseMap<Value*, Constant*> ConstantPool
cp_lookup :: (cp: *Cp, v: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) return v;
    for cp.keys if it == v return cp.vals[it_index];
    return NONE;
}
cp_constant_fold :: (i: Value_Id, cp: *Cp) -> Value_Id {
    if inst_op(i) == .SELECT {
        a := cp_lookup(cp, op(i, 0));
        if a == NONE return NONE;
        if cf_is_all_ones(a) return cp_lookup(cp, op(i, 1));
        if is_null_value(a) return cp_lookup(cp, op(i, 2));
        return NONE;
    }
    ops: [..] Value_Id; ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        a := cp_lookup(cp, op(i, cast(u32) k));
        if a == NONE return NONE;
        array_add(*ops, a);
    }
    return cfo_inst_operands(i, ops);
}
is_special_terminator :: (o: Opcode) -> bool { return o == .CATCHSWITCH || o == .CATCHRET || o == .CLEANUPRET || o == .INVOKE || o == .RESUME || o == .CALLBR; }
// getCaseResults
get_case_results :: (s: *Scfg, si: Value_Id, case_val: Value_Id, case_dest_in: Value_Id, common: *Value_Id, res: *[..] Case_Res) -> bool {
    pred := inst_block(si);
    case_dest := case_dest_in;
    cp: Cp; cp.keys.allocator = temp; cp.vals.allocator = temp;
    array_add(*cp.keys, sw_cond(si)); array_add(*cp.vals, case_val);
    i := block_first(case_dest);
    while i != NONE {
        cur := i;
        i = inst_next(i);
        if is_terminator(inst_op(cur)) {
            if num_successors(cur) != 1 || is_special_terminator(inst_op(cur)) return false;
            pred = case_dest;
            case_dest = get_successor(cur, 0);
            // the loop continues over the instructions of the original block only
            break;
        }
        c := cp_constant_fold(cur, *cp);
        if c == NONE break;
        u := ir.v_first_use[cur];
        while u != NONE {
            user := ir.u_user[u];
            ok := false;
            if is_inst(user) && inst_block(user) == case_dest ok = true;
            if !ok && is_phi(user) && ir.u_aux[u] == case_dest ok = true;
            if !ok return false;
            u = ir.u_next[u];
        }
        array_add(*cp.keys, cur); array_add(*cp.vals, c);
    }
    if common.* == NONE common.* = case_dest;
    if case_dest != common.* return false;
    for phi: block_insts(common.*) {
        if inst_op(phi) != .PHI break;
        idx := phi_block_index(phi, pred);
        if idx == -1 continue;
        cv := cp_lookup(*cp, phi_value(phi, cast(u32) idx));
        if cv == NONE return false;
        if !valid_lookup_table_constant(s, cv) return false;
        array_add(res, .{phi, cv});
    }
    return res.count > 0;
}
Unique_Result :: struct { res: Value_Id; cases: [..] Value_Id; }
map_case_to_result :: (case_val: Value_Id, uniq: *[..] Unique_Result, r: Value_Id) -> s64 {
    for * uniq.* if it.res == r { array_add(*it.cases, case_val); return it.cases.count; }
    u: Unique_Result; u.res = r; u.cases.allocator = temp; array_add(*u.cases, case_val);
    array_add(uniq, u);
    return 1;
}
// initializeUniqueCases: (ok, PHI, DefaultResult)
initialize_unique_cases :: (s: *Scfg, si: Value_Id, common: *Value_Id, uniq: *[..] Unique_Result, max_unique: s64) -> (bool, Value_Id, Value_Id) {
    phi: Value_Id = NONE;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        cv := sw_case_value(si, cast(u32) k);
        res: [..] Case_Res; res.allocator = temp;
        if !get_case_results(s, si, cv, sw_case_dest(si, cast(u32) k), common, *res) return false, NONE, NONE;
        if res.count > 1 return false, NONE, NONE;
        n := map_case_to_result(cv, uniq, res[0].c);
        if n > scfg_cl.max_switch_cases_per_result return false, NONE, NONE;
        if uniq.count > max_unique return false, NONE, NONE;
        if phi == NONE phi = res[0].phi;
        else if phi != res[0].phi return false, NONE, NONE;
    }
    dres: [..] Case_Res; dres.allocator = temp;
    get_case_results(s, si, NONE, sw_default(si), common, *dres);
    def: Value_Id = ifx dres.count == 1 then dres[0].c else NONE;
    return def != NONE || sw_default_dest_unreachable(si), phi, def;
}

// foldSwitchToSelect
fold_switch_to_select :: (rv: [] Unique_Result, def: Value_Id, cond_in: Value_Id, b: *Irb, bw: [] u64) -> Value_Id {
    hw := bw.count > 0;
    cond := cond_in;
    set_bw :: (sel: Value_Id, a: u64, c: u64) {
        if !is_inst(sel) || inst_op(sel) != .SELECT return;
        w := u32.[cast(u32) a, cast(u32) c];
        prof_set_branch_weights(sel, w, false, true);
    }
    sum_rest :: (bw: [] u64) -> u64 { t: u32 = 0; for k: 1..bw.count-1 t += cast(u32) bw[k]; return t; }
    if rv.count == 2 && rv[0].cases.count == 1 && rv[1].cases.count == 1 {
        first := rv[0].cases[0];
        second := rv[1].cases[0];
        sv := rv[1].res;
        if def != NONE {
            vc := irb_icmp(b, ICMP_EQ, cond, second, "switch.selectcmp");
            sv = irb_select(b, vc, rv[1].res, def, "switch.select");
            if hw set_bw(sv, bw[2], bw[0] + bw[1]);
        }
        vc := irb_icmp(b, ICMP_EQ, cond, first, "switch.selectcmp");
        ret := irb_select(b, vc, rv[0].res, sv, "switch.select");
        if hw {
            fp: s64 = ifx cond != NONE then 1 else 0;
            dc: u64 = ifx cond != NONE then bw[0] else 0;
            set_bw(ret, bw[fp], dc + bw[fp + 1]);
        }
        return ret;
    }
    if rv.count == 1 && def != NONE {
        cvs := rv[0].cases;
        n := cvs.count;
        if (n & (n - 1)) == 0 {
            mn := cvs[0];
            and_mask := ap_all_ones(cf_ap(mn).bits);
            for c: cvs {
                if ap_slt(cf_ap(c), cf_ap(mn)) mn = c;
                and_mask = ap_and(and_mask, cf_ap(c));
            }
            q: Simplify_Query;
            known := known_bits(cond, q);
            log2n := 0; while (1 << log2n) < n log2n += 1;
            if !ap_is_zero(and_mask) && ap_uge(kb_max_value(known), and_mask) {
                free_bits := cast(s64) kb_count_max_active_bits(known) - cast(s64) ap_popcount(and_mask);
                if free_bits == log2n {
                    an := irb_binop(b, .AND, cond, const_int_words(vtype(cond), ap_words(and_mask)));
                    cmp := irb_icmp(b, ICMP_EQ, an, const_int_words(vtype(an), ap_words(and_mask)));
                    ret := irb_select(b, cmp, rv[0].res, def);
                    if hw set_bw(ret, sum_rest(bw), bw[0]);
                    return ret;
                }
            }
            bitmask := ap_zero(cf_ap(mn).bits);
            for c: cvs bitmask = ap_or(bitmask, ap_sub(cf_ap(c), cf_ap(mn)));
            if ap_popcount(bitmask) == cast(u32) log2n {
                if !is_null_value(mn) cond = irb_binop(b, .SUB, cond, mn);
                an := irb_binop(b, .AND, cond, const_int_words(vtype(cond), ap_words(ap_not(bitmask))), "switch.and");
                cmp := irb_icmp(b, ICMP_EQ, an, const_null_value(vtype(an)), "switch.selectcmp");
                ret := irb_select(b, cmp, rv[0].res, def);
                if hw set_bw(ret, sum_rest(bw), bw[0]);
                return ret;
            }
        }
        if cvs.count == 2 {
            c1 := irb_icmp(b, ICMP_EQ, cond, cvs[0], "switch.selectcmp.case1");
            c2 := irb_icmp(b, ICMP_EQ, cond, cvs[1], "switch.selectcmp.case2");
            cmp := irb_binop(b, .OR, c1, c2, "switch.selectcmp");
            ret := irb_select(b, cmp, rv[0].res, def);
            if hw set_bw(ret, sum_rest(bw), bw[0]);
            return ret;
        }
    }
    return NONE;
}
// removeSwitchAfterSelectFold
remove_switch_after_select_fold :: (s: *Scfg, si: Value_Id, phi: Value_Id, sv: Value_Id, b: *Irb) {
    updates: [..] Dom_Update; updates.allocator = temp;
    sbb := inst_block(si);
    dbb := inst_block(phi);
    if s.dtu {
        dp: [..] Value_Id; dp.allocator = temp;
        block_predecessors(dbb, *dp);
        if !block_set_contains(dp, sbb) array_add(*updates, .{true, sbb, dbb});
    }
    irb_br(b, dbb);
    // removeIncomingValueIf(block == SelectBB)
    k: u32 = 0;
    while k < nops(phi) { if phi_block(phi, k) == sbb phi_remove_incoming(phi, k, false); else k += 1; }
    phi_add_incoming(phi, sv, sbb);
    removed: [..] Value_Id; removed.allocator = temp;
    for j: 0..cast(s64) num_successors(si) - 1 {
        succ := get_successor(si, cast(u32) j);
        if succ == dbb continue;
        block_remove_predecessor(succ, sbb);
        if s.dtu && !block_set_contains(removed, succ) { array_add(*removed, succ); array_add(*updates, .{false, sbb, succ}); }
    }
    erase_terminator(si);
    if s.dtu dtu_apply(s.dtu, updates);
}
try_switch_to_select :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    cond := sw_cond(si);
    common: Value_Id = NONE;
    uniq: [..] Unique_Result; uniq.allocator = temp;
    ok, phi, def := initialize_unique_cases(s, si, *common, *uniq, 2);
    if !ok return false;
    irb_set_before(b, si);
    bw: [..] u64; bw.allocator = temp;
    m := prof_md(si);
    if prof_is_branch_weight_md(m) for prof_weights_of_md(m) array_add(*bw, it);
    sv := fold_switch_to_select(uniq, def, cond, b, bw);
    if sv == NONE return false;
    remove_switch_after_select_fold(s, si, phi, sv, b);
    return true;
}

// ---------------------------------------------------------------- lookup tables (SwitchReplacement)

SR_SINGLE :: 0; SR_LINEAR :: 1; SR_BITMAP :: 2; SR_TABLE :: 3;
Switch_Replacement :: struct {
    kind: s64;
    default_value: Value_Id;
    value_type: Type_Id;
    single: Value_Id = NONE;
    bitmap: Value_Id = NONE;
    bitmap_elt_ty: Type_Id;
    linear_offset: Value_Id = NONE;
    linear_mult: Value_Id = NONE;
    linear_wrapped: bool;
    initializer: Value_Id = NONE;
}
Case_Value :: struct { case_val: Value_Id; res: Value_Id; }
would_fit_in_register :: (table_size: u64, ty: Type_Id) -> bool {
    if type_kind(ty) != .INT return false;
    w := cast(u64) type_int_width(ty);
    if table_size >= 0xFFFF_FFFF / w return false;
    return dl_fits_in_legal_integer(cast(u32) (table_size * w));
}
is_type_legal_for_lookup_table :: (s: *Scfg, ty: Type_Id) -> bool {
    if tti_is_type_legal(s.tti, ty) return true;
    if type_kind(ty) != .INT return false;
    w := type_int_width(ty);
    return w >= 8 && (w & (w - 1)) == 0 && dl_fits_in_legal_integer(w);
}
sr_init :: (s: *Scfg, r: *Switch_Replacement, table_size: u64, offset: Value_Id, values: [] Case_Value, def: Value_Id) {
    r.default_value = def;
    r.single = values[0].res;
    r.value_type = vtype(values[0].res);
    contents := NewArray(cast(s64) table_size, Value_Id,, allocator = temp);
    for *contents it.* = NONE;
    for values {
        idx := ap_limited_value(ap_sub(cf_ap(it.case_val), cf_ap(offset)));
        contents[idx] = it.res;
        if r.single != NONE && vkind(it.res) != .C_POISON && it.res != r.single
            r.single = ifx vkind(r.single) == .C_POISON then it.res else NONE;
    }
    if cast(u64) values.count < table_size {
        for *contents if it.* == NONE it.* = def;
        if def != r.single && vkind(def) != .C_POISON r.single = NONE;
    }
    if r.single != NONE { r.kind = SR_SINGLE; return; }
    if type_kind(r.value_type) == .INT {
        possible := true;
        prev: APInt; dist: APInt;
        non_monotonic := false;
        for i: 0..cast(s64) table_size - 1 {
            cv := contents[i];
            if !is_const_int(cv) && vkind(cv) == .C_POISON {
                cv = values[0].res;
                if !is_const_int(cv) cv = NONE;
            } else if !is_const_int(cv) cv = NONE;
            if cv == NONE { possible = false; break; }
            v := cf_ap(cv);
            if i != 0 {
                d := ap_sub(v, prev);
                if i == 1 dist = d;
                else if !ap_eq(d, dist) { possible = false; break; }
                non_monotonic |= ifx ap_is_strictly_positive(d) then ap_sle(v, prev) else ap_sgt(v, prev);
            }
            prev = v;
        }
        if possible {
            r.linear_offset = contents[0];
            r.linear_mult = const_int_words(type_int(cast(u64) dist.bits), ap_words(dist));
            m := cf_ap(r.linear_mult);
            may_wrap := true;
            if fits_int_n(m.bits, table_size - 1) { _, ov := ap_smul_ov(m, ap_from_u64(m.bits, table_size - 1)); may_wrap = ov; }
            r.linear_wrapped = non_monotonic || may_wrap;
            r.kind = SR_LINEAR;
            return;
        }
    }
    if would_fit_in_register(table_size, r.value_type) {
        w := type_int_width(r.value_type);
        ti := ap_zero(cast(u32) (table_size * w));
        i := table_size;
        while i > 0 {
            ti = ap_shl(ti, w);
            c := contents[i - 1];
            if !is_undef_value(c) ti = ap_or(ti, ap_zext(cf_ap(c), ti.bits));
            i -= 1;
        }
        r.bitmap = const_int_words(type_int(cast(u64) ti.bits), ap_words(ti));
        r.bitmap_elt_ty = r.value_type;
        r.kind = SR_BITMAP;
        return;
    }
    if type_kind(r.value_type) == .INT {
        w := type_int_width(r.value_type);
        range := cr_empty(w);
        for contents if !is_undef_value(it) range = cr_union(range, cr_single(cf_ap(it)));
        ab := cr_active_bits(range);
        p2: u32 = 1; while p2 < ab p2 *= 2;
        if ab == 0 p2 = 0;
        needed := max(cast(u32) tti_minimum_lookup_table_entry_bit_width(s.tti), p2);
        if needed < w {
            dt := type_int(cast(u64) needed);
            for *contents it.* = cf_cast(.TRUNC, it.*, dt);
        }
    }
    tt := type_array(table_size, vtype(contents[0]));
    r.initializer = const_aggregate(.C_ARRAY, tt, contents);
    r.kind = SR_TABLE;
}
fits_int_n :: (bits: u32, v: u64) -> bool { if bits >= 64 return true; return v < ((cast(u64) 1) << cast(u64) bits); }
irb_zext_or_trunc :: (b: *Irb, v: Value_Id, t: Type_Id, name: string = "") -> Value_Id {
    vb := type_int_width(vtype(v)); tb := type_int_width(t);
    if vb < tb return irb_cast(b, .ZEXT, v, t, name);
    if vb > tb return irb_cast(b, .TRUNC, v, t, name);
    return v;
}
sr_replace_switch :: (s: *Scfg, r: *Switch_Replacement, index_in: Value_Id, b: *Irb, f: Value_Id) -> Value_Id {
    index := index_in;
    if r.kind == {
        case SR_SINGLE; return r.single;
        case SR_LINEAR;
            mt := vtype(r.linear_mult);
            res := index;
            iw := type_int_width(vtype(index)); mw := type_int_width(mt);
            if iw != mw res = irb_cast(b, ifx iw < mw then Opcode.ZEXT else .TRUNC, index, mt, "switch.idx.cast");
            if !ap_is_one(cf_ap(r.linear_mult)) res = irb_binop(b, .MUL, res, r.linear_mult, "switch.idx.mult", ifx r.linear_wrapped then cast(u32) 0 else F_NSW);
            if !ap_is_zero(cf_ap(r.linear_offset)) res = irb_binop(b, .ADD, res, r.linear_offset, "switch.offset", ifx r.linear_wrapped then cast(u32) 0 else F_NSW);
            return res;
        case SR_BITMAP;
            mt := vtype(r.bitmap);
            sa := irb_zext_or_trunc(b, index, mt, "switch.cast");
            sa = irb_binop(b, .MUL, sa, const_int(mt, cast(u64) type_int_width(r.bitmap_elt_ty)), "switch.shiftamt", F_NUW | F_NSW);
            ds := irb_binop(b, .LSHR, r.bitmap, sa, "switch.downshift");
            return irb_cast(b, .TRUNC, ds, r.bitmap_elt_ty, "switch.masked");
        case SR_TABLE;
            ity := vtype(r.initializer);
            table := new_global(.GLOBAL_VAR, ity, 0, 1);
            set_name(table, tprint("switch.table.%", vname(f)));
            array_add(*ir.m_globals, table);
            g := glob(table);
            set_op(table, 0, r.initializer); g.has_init = true;
            g.is_const = true;
            g.linkage = .PRIVATE;
            g.unnamed_addr = 2;
            g.align = dl_pref_align(r.value_type);
            idx_ty := type_int(cast(u64) dl_index_size_bits(0));
            if vtype(index) != idx_ty {
                old_w := type_int_width(vtype(index));
                index = irb_zext_or_trunc(b, index, idx_ty);
                if is_inst(index) && inst_op(index) == .ZEXT {
                    if fits_int_n(old_w - 1, type_count(ity) - 1) inst(index).flags |= F_EXACT; else inst(index).flags &= ~cast(u32) F_EXACT;
                }
            }
            idxs := Value_Id.[const_int(idx_ty, 0), index];
            gep := irb_gep(b, ity, table, idxs, "switch.gep", F_INBOUNDS);
            et := type_elem(ity);
            ld := irb_load(b, et, gep, dl_abi_align(et), false, "switch.load");
            if vtype(ld) == r.value_type return ld;
            return irb_cast(b, .ZEXT, ld, r.value_type, "switch.ext");
    }
    return NONE;
}
is_switch_dense_n :: (num_cases: u64, case_range: u64, opt_size: bool) -> bool {
    min_density: u64 = ifx opt_size then cast(u64) 40 else 10;
    if case_range >= U64_MAX / 100 return false;
    return num_cases * 100 >= case_range * min_density;
}
is_switch_dense_values :: (vals: [] s64, opt_size: bool) -> bool {
    diff := cast,no_check(u64) vals[vals.count - 1] - cast,no_check(u64) vals[0];
    range := diff + 1;
    if range < diff return false;
    return is_switch_dense_n(cast(u64) vals.count, range, opt_size);
}
// getDenseSwitchRangeReductionShift: -1 = none
get_dense_switch_range_reduction_shift :: (vals: [] s64, base: s64, opt_size: bool) -> s64 {
    for vals if it < base return -1;
    red := NewArray(vals.count, s64,, allocator = temp);
    or: u64 = 0;
    for vals { r := cast,no_check(u64) it - cast,no_check(u64) base; or |= r; red[it_index] = cast,no_check(s64) r; }
    shift := 0; while shift < 64 && ((or >> cast(u64) shift) & 1) == 0 shift += 1;
    if shift > 0 for *red it.* = cast,no_check(s64) ((cast,no_check(u64) it.*) >> cast(u64) shift);
    if !is_switch_dense_values(red, opt_size) return -1;
    return shift;
}
should_build_lookup_table :: (s: *Scfg, si: Value_Id, table_size: u64, rtys: [] Type_Id) -> bool {
    if cast(u64) sw_num_cases(si) > table_size return false;
    all_fit := true; illegal := false;
    for rtys {
        illegal = illegal || !is_type_legal_for_lookup_table(s, it);
        all_fit = all_fit && would_fit_in_register(table_size, it);
        if illegal && !all_fit break;
    }
    if all_fit return true;
    if illegal return false;
    return is_switch_dense_n(cast(u64) sw_num_cases(si), table_size, fn_has_opt_size(inst_fn(si)));
}
should_use_switch_condition_as_table_index :: (mn: Value_Id, mx: Value_Id, has_default: bool, rtys: [] Type_Id) -> bool {
    if is_null_value(mn) return true;
    if ap_is_negative(cf_ap(mn)) || ap_limited_value(cf_ap(mx)) == U64_MAX || !has_default return false;
    for rtys if !would_fit_in_register(ap_limited_value(cf_ap(mx)) + 1, it) return false;
    return true;
}
// reuseTableCompare
reuse_table_compare :: (user: Value_Id, phi_block: Value_Id, rcb: Value_Id, def: Value_Id, values: [] Case_Value) {
    if !is_inst(user) || inst_op(user) != .ICMP return;
    if inst_block(user) != phi_block return;
    op1 := op(user, 1);
    if !is_constant_kind(vkind(op1)) return;
    rc := op(rcb, 0);
    tc := const_int(vtype(rc), 1);
    fc := const_int(vtype(rc), 0);
    pred := inst(user).pred;
    dc := cfo_compare_inst_operands(pred, def, op1);
    if dc != tc && dc != fc return;
    for values {
        cc := cfo_compare_inst_operands(pred, it.res, op1);
        if cc == NONE || cc == dc || (cc != tc && cc != fc) return;
    }
    bb := inst_block(rcb);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(phi_block, *preds);
    for p: preds if p != bb && block_unique_predecessor(p) != bb return;
    if dc == fc rauw_with_metadata(user, rc);
    else {
        inv := create_binop(.XOR, rc, const_int(vtype(rc), 1));
        insert_at_position(inv, bb, rcb, false);
        set_name(inv, "inverted.cmp");
        rauw_with_metadata(user, inv);
    }
}
// simplifySwitchLookup
simplify_switch_lookup :: (s: *Scfg, si: Value_Id, b: *Irb, convert_to_lookup: bool) -> bool {
    bb := inst_block(si);
    f := block_fn(bb);
    if sw_num_cases(si) < 3 return false;
    mn := sw_case_value(si, 0); mx := mn;
    common: Value_Id = NONE;
    phis: [..] Value_Id; phis.allocator = temp;
    lists: [..] [..] Case_Value; lists.allocator = temp;
    rtys: [..] Type_Id; rtys.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        cv := sw_case_value(si, cast(u32) k);
        if ap_slt(cf_ap(cv), cf_ap(mn)) mn = cv;
        if ap_sgt(cf_ap(cv), cf_ap(mx)) mx = cv;
        res: [..] Case_Res; res.allocator = temp;
        if !get_case_results(s, si, cv, sw_case_dest(si, cast(u32) k), *common, *res) return false;
        for r: res {
            idx := -1;
            for phis if it == r.phi idx = it_index;
            if idx < 0 { array_add(*phis, r.phi); l: [..] Case_Value; l.allocator = temp; array_add(*lists, l); idx = phis.count - 1; }
            array_add(*lists[idx], .{cv, r.c});
            array_add(*rtys, vtype(r.phi));
        }
    }
    dres: [..] Case_Res; dres.allocator = temp;
    has_default_results := get_case_results(s, si, NONE, sw_default(si), *common, *dres);
    default_of :: (dres: [] Case_Res, phi: Value_Id) -> Value_Id { for dres if it.phi == phi return it.c; return NONE; }
    use_cond := should_use_switch_condition_as_table_index(mn, mx, has_default_results, rtys);
    table_size: u64;
    offset: Value_Id;
    if use_cond {
        table_size = ap_limited_value(cf_ap(mx)) + 1;
        offset = const_int(vtype(mx), 0);
    } else {
        table_size = ap_limited_value(ap_sub(cf_ap(mx), cf_ap(mn))) + 1;
        offset = mn;
    }
    num_results := cast(u64) lists[0].count;
    default_reachable := !sw_default_dest_unreachable(si);
    has_holes := num_results < table_size;
    all_holes_poison := has_holes && !has_default_results;
    need_mask := all_holes_poison && default_reachable;
    if need_mask {
        if sw_num_cases(si) < 4 return false;
        if table_size > 0xFFFF_FFFF || !dl_fits_in_legal_integer(cast(u32) table_size) return false;
    }
    if !should_build_lookup_table(s, si, table_size, rtys) return false;
    table_index: Value_Id = NONE;
    if use_cond {
        table_index = sw_cond(si);
        if has_default_results {
            q: Simplify_Query;
            cr := compute_constant_range(table_index, false, q);
            ub := ap_limited_value(cr.hi);
            fits := true;
            for rtys if !would_fit_in_register(ub, it) fits = false;
            if !cr_is_upper_wrapped(cr) && fits {
                table_size = max(ub, table_size);
                default_reachable = false;
            }
        }
    }
    reps := NewArray(phis.count, Switch_Replacement,, allocator = temp);
    for phi, k: phis {
        rl := lists[k];
        rt := vtype(rl[0].res);
        dv := ifx all_holes_poison then const_poison(rt) else default_of(dres, phi);
        sr_init(s, *reps[k], table_size, offset, rl, dv);
    }
    any_table := false; any_bitmap := false;
    for reps { if it.kind == SR_TABLE any_table = true; if it.kind == SR_BITMAP any_bitmap = true; }
    if any_table && (!tti_should_build_lookup_tables(s.tti) || fn_str_attr_bool(f, "no-jump-tables")) return false;
    if !convert_to_lookup && (any_table || any_bitmap || need_mask) return false;
    irb_set_before(b, si);
    if !use_cond {
        may_wrap := true;
        if !default_reachable { _, ov := ap_ssub_ov(cf_ap(mx), cf_ap(mn)); may_wrap = ov; }
        table_index = irb_binop(b, .SUB, sw_cond(si), offset, "switch.tableidx", ifx may_wrap then cast(u32) 0 else F_NSW);
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    case_size := type_int_width(vtype(mn));
    max_table: u64 = ifx case_size > 63 then U64_MAX else (cast(u64) 1) << cast(u64) case_size;
    lookup_bb := create_block(block_fn(common), "switch.lookup", common);
    rcb: Value_Id = NONE;
    cond_branch: Value_Id = NONE;
    irb_set_before(b, si);
    covered := max_table == table_size;
    if !default_reachable || covered {
        irb_br(b, lookup_bb);
        if s.dtu array_add(*updates, .{true, bb, lookup_bb});
    } else {
        cmp := irb_icmp(b, ICMP_ULT, table_index, const_int(vtype(mn), table_size));
        rcb = irb_cond_br(b, cmp, lookup_bb, sw_default(si));
        cond_branch = rcb;
        if s.dtu array_add(*updates, .{true, bb, lookup_bb});
    }
    irb_set_end(b, lookup_bb);
    if need_mask {
        mask_bb := lookup_bb;
        set_name(mask_bb, "switch.hole_check");
        lookup_bb = create_block(block_fn(common), "switch.lookup", common);
        p2: u64 = 1; x := max(cast(u64) 7, table_size - 1); while p2 <= x p2 *= 2;
        mask := ap_zero(cast(u32) p2);
        one := ap_from_u64(cast(u32) p2, 1);
        for lists[0] {
            idx := ap_limited_value(ap_sub(cf_ap(it.case_val), cf_ap(offset)));
            mask = ap_or(mask, ap_shl(one, cast(u32) idx));
        }
        tm := const_int_words(type_int(p2), ap_words(mask));
        mi := irb_zext_or_trunc(b, table_index, vtype(tm), "switch.maskindex");
        sh := irb_binop(b, .LSHR, tm, mi, "switch.shifted");
        lo := irb_cast(b, .TRUNC, sh, ir.t_i1, "switch.lobit");
        cond_branch = irb_cond_br(b, lo, lookup_bb, sw_default(si));
        if s.dtu { array_add(*updates, .{true, mask_bb, lookup_bb}); array_add(*updates, .{true, mask_bb, sw_default(si)}); }
        irb_set_end(b, lookup_bb);
        add_predecessor_to_block(sw_default(si), mask_bb, bb);
    }
    if !default_reachable || covered {
        block_remove_predecessor(sw_default(si), bb, true);
        if s.dtu array_add(*updates, .{false, bb, sw_default(si)});
    }
    for phi, k: phis {
        res := sr_replace_switch(s, *reps[k], table_index, b, f);
        if !has_holes && has_default_results && rcb != NONE {
            pb := inst_block(phi);
            users: [..] Value_Id; users.allocator = temp;
            u := ir.v_first_use[phi];
            while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
            for users reuse_table_compare(it, pb, rcb, reps[k].default_value, lists[k]);
        }
        phi_add_incoming(phi, res, lookup_bb);
    }
    irb_br(b, common);
    if s.dtu array_add(*updates, .{true, lookup_bb, common});
    hw := false;
    bw: [] u64;
    if cond_branch != NONE { hw, bw = prof_extract_branch_weights(si); }
    to_lookup: u64 = 0; to_default: u64 = 0;
    removed: [..] Value_Id; removed.allocator = temp;
    for j: 0..cast(s64) num_successors(si) - 1 {
        succ := get_successor(si, cast(u32) j);
        if succ == sw_default(si) { if hw to_default += bw[j]; continue; }
        block_remove_predecessor(succ, bb);
        if s.dtu && !block_set_contains(removed, succ) { array_add(*removed, succ); array_add(*updates, .{false, bb, succ}); }
        if hw to_lookup += bw[j];
    }
    erase_terminator(si);
    if hw { w := u64.[to_lookup, to_default]; prof_set_fitted_branch_weights(cond_branch, w, false); }
    if s.dtu dtu_apply(s.dtu, updates);
    return true;
}
fn_str_attr_bool :: (f: Value_Id, key: string) -> bool {
    for attr_set_items(attr_list_fn(glob(f).attrs)) if it.kind == .STRING_ATTR && it.key == key return it.val == "true";
    return false;
}

// ---------------------------------------------------------------- switch range reduction, umin, powers of two, cmp intrinsics

reduce_switch_range :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    ct := vtype(sw_cond(si));
    w := type_int_width(ct);
    if w > 64 || !dl_fits_in_legal_integer(w) return false;
    if sw_num_cases(si) < 4 return false;
    vals: [..] s64; vals.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1 array_add(*vals, ap_sext_value(cf_ap(sw_case_value(si, cast(u32) k))));
    quick_sort(vals, (a: s64, b: s64) -> s64 { if a < b return -1; if a > b return 1; return 0; });
    opt_size := fn_has_opt_size(inst_fn(si));
    if is_switch_dense_values(vals, opt_size) return false;
    base := vals[0];
    shift := get_dense_switch_range_reduction_shift(vals, 0, true);
    if shift >= 0 base = 0;
    else if base != 0 shift = get_dense_switch_range_reduction_shift(vals, base, opt_size);
    if shift < 0 return false;
    irb_set_before(b, si);
    sub := sw_cond(si);
    if base != 0 sub = irb_binop(b, .SUB, sub, const_int_words(ct, ap_words(ap_from_s64(w, base))));
    args := Value_Id.[sub, sub, const_int(ct, cast(u64) (cast(s64) w - shift))];
    otys := Type_Id.[ct];
    rot := irb_intrinsic(b, "llvm.fshl", otys, args);
    replace_uses_of_with(si, sw_cond(si), rot);
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        orig := sw_case_value(si, cast(u32) k);
        d := ap_sub(cf_ap(orig), ap_from_s64(w, base));
        sw_set_case_value(si, cast(u32) k, const_int_words(ct, ap_words(ap_lshr(d, cast(u32) shift))));
    }
    return true;
}
simplify_switch_when_umin :: (s: *Scfg, si: Value_Id) -> bool {
    c := sw_cond(si);
    if call_iid(c) != IID_UMIN || !is_const_int(op(c, 1)) return false;
    a := op(c, 0);
    cst := op(c, 1);
    updates: [..] Dom_Update; updates.allocator = temp;
    p: Sw_Prof; sw_prof_init(*p, si);
    bb := inst_block(si);
    k: u32 = 0;
    while k < sw_num_cases(si) {
        if !ap_ugt(cf_ap(sw_case_value(si, k)), cf_ap(cst)) { k += 1; continue; }
        dead := sw_case_dest(si, k);
        block_remove_predecessor(dead, bb);
        array_add(*updates, .{false, bb, dead});
        sw_prof_remove_case(*p, k);
    }
    ci := sw_find_case_value(si, cst);
    if !sw_default_dest_unreachable(si) || ci < 0 {
        sw_prof_done(*p);
        if s.dtu dtu_apply(s.dtu, updates);
        return updates.count > 0;
    }
    unr := sw_default(si);
    sw_prof_replace_default_dest(*p, cast(u32) ci);
    sw_prof_remove_case(*p, cast(u32) ci);
    set_op(si, 0, a);
    sw_prof_done(*p);
    array_add(*updates, .{false, bb, unr});
    if s.dtu dtu_apply(s.dtu, updates);
    return true;
}
simplify_switch_of_powers_of_two :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    cond := sw_cond(si);
    ct := vtype(cond);
    w := type_int_width(ct);
    if w > 64 || !dl_fits_in_legal_integer(w) return false;
    ica: Ica;
    ica.id = IID_CTTZ; ica.ret = ct;
    args := Value_Id.[cond, const_int(ir.t_i1, 1)];
    tys := Type_Id.[ct, ir.t_i1];
    ica.args = args; ica.tys = tys;
    if tti_intrinsic_cost(s.tti, *ica, TCK_SIZE_AND_LATENCY) > TCC_BASIC * 2 return false;
    if sw_num_cases(si) < 4 return false;
    vals: [..] u64; vals.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        v := ap_zext_value(cf_ap(sw_case_value(si, cast(u32) k)));
        if v != 0 && (v & (v - 1)) == 0 array_add(*vals, v); else return false;
    }
    quick_sort(vals, (a: u64, b: u64) -> s64 { if a < b return -1; if a > b return 1; return 0; });
    ctz :: (v: u64) -> u64 { n: u64 = 0; while ((v >> n) & 1) == 0 n += 1; return n; }
    if !is_switch_dense_n(cast(u64) vals.count, ctz(vals[vals.count - 1]) - ctz(vals[0]) + 1, fn_has_opt_size(inst_fn(si))) return false;
    irb_set_before(b, si);
    if !sw_default_dest_unreachable(si) {
        a1 := Value_Id.[cond];
        o1 := Type_Id.[ct];
        popc := irb_intrinsic(b, "llvm.ctpop", o1, a1);
        is_pow2 := irb_icmp(b, ICMP_EQ, popc, const_int(ct, 1));
        orig := inst_block(si);
        def := sw_default(si);
        split := split_block(orig, si, ifx s.dtu then s.dtu.dt else null, null);
        it := block_terminator(orig);
        hw, w32 := prof_extract_branch_weights(si);
        bi := create_cond_br(is_pow2, split, def);
        insert_at_position(bi, orig, it, false);
        any_nz := false;
        if hw for w32 if it != 0 any_nz = true;
        if hw && any_nz {
            denom: u64 = 0;
            for w32 denom += it;
            nw: [2] u64;
            nw[1] = w32[0] / 2;
            nw[0] = denom - nw[1];
            prof_set_fitted_branch_weights(bi, nw, false);
            ws := NewArray(w32.count, u32,, allocator = temp);
            ws[0] = cast(u32) nw[1];
            cases_denom := denom - nw[1];
            for k: 1..w32.count-1 ws[k] = cast(u32) (cast(float64) nw[0] * cast(float64) w32[k] / cast(float64) cases_denom);
            prof_set_branch_weights(si, ws, false);
        }
        copy_debug_loc_or_clear(bi, si);
        erase_terminator(it);
        add_predecessor_to_block(def, orig, split);
        dtu_apply1(s.dtu, true, orig, def);
    }
    for k: 0..cast(s64) sw_num_cases(si) - 1 {
        ov := sw_case_value(si, cast(u32) k);
        sw_set_case_value(si, cast(u32) k, const_int(vtype(ov), cast(u64) ap_ctz(cf_ap(ov))));
    }
    a2 := Value_Id.[cond, const_int(ir.t_i1, 1)];
    o2 := Type_Id.[ct];
    tz := irb_intrinsic(b, "llvm.cttz", o2, a2);
    set_op(si, 0, tz);
    return true;
}
simplify_switch_of_cmp_intrinsic :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    cmp := sw_cond(si);
    id := call_iid(cmp);
    if (id != IID_SCMP && id != IID_UCMP) || num_uses(cmp) != 1 return false;
    hw, wl := prof_extract_branch_weights(si);
    w: [..] u64; w.allocator = temp;
    if hw for wl array_add(*w, it); else for 0..3 array_add(*w, 0);
    res: s64 = 0;
    succ, other: Value_Id = NONE, NONE;
    sw_, ow: u64 = 0, 0;
    unr: Value_Id = NONE;
    if sw_num_cases(si) == 2 {
        missing: [..] s64; missing.allocator = temp;
        array_add(*missing, 1); array_add(*missing, 0); array_add(*missing, -1);
        succ = sw_default(si);
        sw_ = w[0];
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            cv := cf_ap(sw_case_value(si, cast(u32) k));
            if ap_min_signed_bits(cv) > 64 return false;
            v := ap_sext_value(cv);
            found := -1;
            for missing if it == v found = it_index;
            if found < 0 return false;
            array_ordered_remove_by_index(*missing, found);
            cs := sw_case_dest(si, cast(u32) k);
            if other != NONE && other != cs return false;
            other = cs;
            ow += w[k + 1];
        }
        res = missing[0];
    } else if sw_num_cases(si) == 3 && sw_default_dest_unreachable(si) {
        unr = sw_default(si);
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            ns := sw_case_dest(si, cast(u32) k);
            wt := w[k + 1];
            if other == NONE || other == ns { other = ns; ow += wt; }
            else if succ == NONE { succ = ns; sw_ = wt; }
            else if succ == ns { t := succ; succ = other; other = t; tw := sw_; sw_ = ow; ow = tw; }
            else return false;
        }
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            cv := cf_ap(sw_case_value(si, cast(u32) k));
            if ap_min_signed_bits(cv) > 64 return false;
            v := ap_sext_value(cv);
            if v != 1 && v != 0 && v != -1 return false;
            if sw_case_dest(si, cast(u32) k) == succ { res = v; break; }
        }
    } else return false;
    pred: u8;
    if res == 1 pred = ICMP_UGT; else if res == 0 pred = ICMP_EQ; else pred = ICMP_ULT;
    if id == IID_SCMP pred = icmp_signed_predicate(pred);
    bb := inst_block(si);
    irb_set_before(b, si);
    ic := irb_icmp(b, pred, op(cmp, 0), op(cmp, 1));
    br := irb_cond_br(b, ic, succ, other);
    if hw { ww := u32.[cast(u32) sw_, cast(u32) ow]; prof_set_branch_weights(br, ww, false, false); }
    un := get_metadata(si, md_kind("unpredictable"));
    if un != NONE set_metadata(br, md_kind("unpredictable"), un);
    block_remove_predecessor(other, bb);
    if unr != NONE block_remove_predecessor(unr, bb);
    erase_terminator(si);
    erase_inst_with_metadata(cmp);
    if s.dtu && unr != NONE dtu_apply1(s.dtu, false, bb, unr);
    return true;
}

// ---------------------------------------------------------------- simplifySwitch

simplify_switch :: (s: *Scfg, si: Value_Id, b: *Irb) -> bool {
    bb := inst_block(si);
    if is_value_equality_comparison(si) != NONE {
        only := block_single_predecessor(bb);
        if only != NONE && simplify_equality_comparison_with_only_predecessor(s, si, only, b) return request_resimplify(s);
        c := sw_cond(si);
        if is_inst(c) && inst_op(c) == .SELECT && simplify_switch_on_select(s, si, c) return request_resimplify(s);
        if si == block_first(bb) && fold_value_comparison_into_predecessors(s, si, b) return request_resimplify(s);
    }
    if s.opts.convert_switch_range_to_icmp && turn_switch_range_into_icmp(s, si, b) return request_resimplify(s);
    if eliminate_dead_switch_cases(s, si) return request_resimplify(s);
    if simplify_switch_of_cmp_intrinsic(s, si, b) return request_resimplify(s);
    if try_switch_to_select(s, si, b) return request_resimplify(s);
    if s.opts.forward_switch_cond_to_phi && forward_switch_condition_to_phi(si) return request_resimplify(s);
    if (s.opts.convert_switch_to_arithmetic || s.opts.convert_switch_to_lookup_table) &&
       simplify_switch_lookup(s, si, b, s.opts.convert_switch_to_lookup_table) return request_resimplify(s);
    if simplify_switch_of_powers_of_two(s, si, b) return request_resimplify(s);
    if reduce_switch_range(s, si, b) return request_resimplify(s);
    if scfg_cl.hoist_common && hoist_common_code_from_successors(s, si, !s.opts.hoist_common_insts) return request_resimplify(s);
    if simplify_duplicate_switch_arms(s, si) return request_resimplify(s);
    if simplify_switch_when_umin(s, si) return request_resimplify(s);
    return false;
}

// ---------------------------------------------------------------- terminators on selects

simplify_terminator_on_select :: (s: *Scfg, old: Value_Id, cond: Value_Id, tbb: Value_Id, fbb: Value_Id, tw: u32, fw: u32) -> bool {
    bb := inst_block(old);
    k1 := tbb;
    k2: Value_Id = ifx tbb != fbb then fbb else NONE;
    removed: [..] Value_Id; removed.allocator = temp;
    for j: 0..cast(s64) num_successors(old) - 1 {
        succ := get_successor(old, cast(u32) j);
        if succ == k1 k1 = NONE;
        else if succ == k2 k2 = NONE;
        else {
            block_remove_predecessor(succ, bb, true);
            if succ != tbb && succ != fbb && !block_set_contains(removed, succ) array_add(*removed, succ);
        }
    }
    b: Irb; irb_set_before(*b, old);
    if k1 == NONE && k2 == NONE {
        if tbb == fbb irb_br(*b, tbb);
        else {
            nbi := irb_cond_br(*b, cond, tbb, fbb);
            w := u32.[tw, fw];
            prof_set_branch_weights(nbi, w, false, true);
        }
    } else if k1 != NONE && (k2 != NONE || tbb == fbb) {
        insert_at_position(new_inst(.UNREACHABLE, ir.t_void, 0), bb, old, false);
    } else {
        if k1 == NONE irb_br(*b, tbb); else irb_br(*b, fbb);
    }
    erase_terminator_and_dce_cond(old);
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        for removed array_add(*ups, .{false, bb, it});
        dtu_apply(s.dtu, ups);
    }
    return true;
}
simplify_switch_on_select :: (s: *Scfg, si: Value_Id, sel: Value_Id) -> bool {
    tv := op(sel, 1); fv := op(sel, 2);
    if !is_const_int(tv) || !is_const_int(fv) return false;
    cond := op(sel, 0);
    tk := sw_find_case_value(si, tv);
    fk := sw_find_case_value(si, fv);
    tbb := ifx tk >= 0 then sw_case_dest(si, cast(u32) tk) else sw_default(si);
    fbb := ifx fk >= 0 then sw_case_dest(si, cast(u32) fk) else sw_default(si);
    tw: u32 = 0; fw: u32 = 0;
    if prof_has_branch_weight_md(si) {
        w := scfg_get_branch_weights(si);
        if w.count == 1 + sw_num_cases(si) {
            tw = cast(u32) w[tk + 1];
            fw = cast(u32) w[fk + 1];
        }
    }
    return simplify_terminator_on_select(s, si, cond, tbb, fbb, tw, fw);
}
simplify_indirect_br_on_select :: (s: *Scfg, ibi: Value_Id, si: Value_Id) -> bool {
    tba := op(si, 1); fba := op(si, 2);
    if vkind(tba) != .C_BLOCKADDR || vkind(fba) != .C_BLOCKADDR return false;
    w: [2] u32;
    ok, ws := prof_extract_branch_weights(si);
    if ok { w[0] = cast(u32) ws[0]; w[1] = cast(u32) ws[1]; }
    return simplify_terminator_on_select(s, ibi, op(si, 0), op(tba, 1), op(fba, 1), w[0], w[1]);
}

// ---------------------------------------------------------------- unconditional branch with an icmp in it

try_to_simplify_uncond_branch_with_icmp_in_it :: (s: *Scfg, icmp: Value_Id, b: *Irb) -> bool {
    return try_to_simplify_uncond_branch_with_icmp_select_in_it(s, icmp, NONE, b);
}
try_to_simplify_uncond_branch_with_icmp_select_in_it :: (s: *Scfg, ici: Value_Id, sel: Value_Id, b: *Irb) -> bool {
    bb := inst_block(ici);
    if inst_op(block_first(bb)) == .PHI || num_uses(ici) != 1 || (sel != NONE && num_uses(sel) != 1) return false;
    pred := block_single_predecessor(bb);
    if pred == NONE || inst_op(block_terminator(pred)) != .SWITCH return false;
    icmp_cond := op(ici, 0);
    new_case := op(ici, 1);
    if !is_const_int(new_case) return false;
    pr := inst(ici).pred;
    st, sf: Value_Id;
    user: Value_Id;
    if sel == NONE {
        st = const_int(ir.t_i1, 1); sf = const_int(ir.t_i1, 0);
        user = ir.u_user[ir.v_first_use[ici]];
    } else {
        if op(sel, 0) != ici return false;
        st = op(sel, 1); sf = op(sel, 2);
        user = ir.u_user[ir.v_first_use[sel]];
    }
    si := block_terminator(pred);
    if sw_cond(si) != icmp_cond return false;
    if sw_default(si) != bb {
        vval := sw_find_case_dest(si, bb);
        set_op(ici, 0, vval);
        q: Simplify_Query; q.cxt = ici;
        v := simplify_instruction(ici, q);
        if v != NONE { rauw_with_metadata(ici, v); erase_inst_with_metadata(ici); }
        return request_resimplify(s);
    }
    if sw_find_case_value(si, new_case) >= 0 {
        v := const_int(ir.t_i1, ifx pr == ICMP_EQ then cast(u64) 0 else 1);
        rauw_with_metadata(ici, v);
        erase_inst_with_metadata(ici);
        return request_resimplify(s);
    }
    succ := get_successor(block_terminator(bb), 0);
    if !is_phi(user) || user != block_first(succ) || inst_op(inst_next(user)) == .PHI return false;
    def_cst := sf; new_cst := st;
    if pr == ICMP_NE { t := def_cst; def_cst = new_cst; new_cst = t; }
    if sel != NONE { rauw_with_metadata(sel, def_cst); erase_inst_with_metadata(sel); }
    else rauw_with_metadata(ici, def_cst);
    erase_inst_with_metadata(ici);
    updates: [..] Dom_Update; updates.allocator = temp;
    nbb := create_block(block_fn(bb), "switch.edge", bb);
    {
        p: Sw_Prof; sw_prof_init(*p, si);
        hw0, w0 := sw_prof_get_weight(*p, 0);
        nw: u32 = 0;
        if hw0 { nw = cast(u32) ((cast(u64) w0 + 1) >> 1); sw_prof_set_weight(*p, 0, true, nw); }
        sw_prof_add_case(*p, new_case, nbb, hw0, nw);
        sw_prof_done(*p);
        if s.dtu array_add(*updates, .{true, pred, nbb});
    }
    br := create_br(succ);
    block_append_inst(nbb, br);
    copy_debug_loc_or_clear(br, si);
    phi_add_incoming(user, new_cst, nbb);
    if s.dtu { array_add(*updates, .{true, nbb, succ}); dtu_apply(s.dtu, updates); }
    return true;
}

// ---------------------------------------------------------------- simplifyBranchOnICmpChain

simplify_branch_on_icmp_chain :: (s: *Scfg, bi: Value_Id, b: *Irb) -> bool {
    cond := op(bi, 0);
    if !is_inst(cond) return false;
    g: Ccg;
    ccg_init(*g, cond);
    if g.comp_value == NONE return false;
    if g.used_icmps <= 1 return false;
    comp := g.comp_value;
    extra := g.extra;
    true_when_equal := g.is_eq;
    sort_cases_desc(*g.vals);
    // unique
    vals: [..] Value_Id; vals.allocator = temp;
    for g.vals if vals.count == 0 || vals[vals.count - 1] != it array_add(*vals, it);
    if extra != NONE && vals.count < 2 return false;
    has_prof, bw64 := prof_extract_branch_weights(bi);
    bw: [..] u32; bw.allocator = temp;
    if has_prof for bw64 array_add(*bw, cast(u32) it);
    default_bb := get_successor(bi, 1);
    edge_bb := get_successor(bi, 0);
    if !true_when_equal {
        t := default_bb; default_bb = edge_bb; edge_bb = t;
        if has_prof { x := bw[0]; bw[0] = bw[1]; bw[1] = x; }
    }
    bb := inst_block(bi);
    updates: [..] Dom_Update; updates.allocator = temp;
    if extra != NONE {
        nbb := split_block(bb, bi, ifx s.dtu then s.dtu.dt else null, null, null, "switch.early.test");
        old := block_terminator(bb);
        irb_set_before(b, old);
        if !is_guaranteed_not_to_be_undef_or_poison(extra, s.opts.ac, bi, null) extra = irb_freeze(b, extra);
        br := ifx true_when_equal then irb_cond_br(b, extra, edge_bb, nbb) else irb_cond_br(b, extra, nbb, edge_bb);
        set_explicitly_unknown_branch_weights_if_profiled(br, "simplifycfg");
        erase_terminator(old);
        if s.dtu array_add(*updates, .{true, bb, edge_bb});
        add_predecessor_to_block(edge_bb, bb, nbb);
        bb = nbb;
    }
    irb_set_before(b, bi);
    if type_kind(vtype(comp)) == .PTR comp = irb_cast(b, .PTRTOINT, comp, dl_int_ptr_type(vtype(comp)), "magicptr");
    front := cf_ap(vals[0]); back := cf_ap(vals[vals.count - 1]);
    if ap_eq(ap_sub(front, back), ap_from_u64(front.bits, cast(u64) (vals.count - 1))) {
        range := cr_non_empty(back, ap_add(front, ap_from_u64(front.bits, 1)));
        pred, rhs, offset := cr_equivalent_icmp(range);
        x := comp;
        if !ap_is_zero(offset) x = irb_binop(b, .ADD, x, const_int_words(vtype(comp), ap_words(offset)));
        c := irb_icmp(b, pred, x, const_int_words(vtype(comp), ap_words(rhs)));
        nbi := irb_cond_br(b, c, edge_bb, default_bb);
        if has_prof prof_set_branch_weights(nbi, bw, false);
    } else {
        ns := create_switch(comp, default_bb, cast(u32) vals.count);
        irb_insert(b, ns);
        if has_prof {
            nw := NewArray(vals.count + 1, u32,, allocator = temp);
            nw[0] = bw[1];
            for k: 1..nw.count-1 nw[k] = bw[0] / cast(u32) vals.count;
            prof_set_branch_weights(ns, nw, false);
        }
        for vals sw_add_case(ns, it, edge_bb);
        for pn: block_insts(edge_bb) {
            if inst_op(pn) != .PHI break;
            iv := phi_incoming_value_for_block(pn, bb);
            for 0..vals.count-2 phi_add_incoming(pn, iv, bb);
        }
    }
    erase_terminator_and_dce_cond(bi);
    if s.dtu dtu_apply(s.dtu, updates);
    return true;
}
irb_freeze :: (b: *Irb, v: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.FREEZE, vtype(v), 1);
    set_op(i, 0, v);
    return irb_insert(b, i, name);
}

// ---------------------------------------------------------------- conditional stores

find_unique_store_in_blocks :: (bb1: Value_Id, bb2: Value_Id) -> Value_Id {
    st: Value_Id = NONE;
    for bb: Value_Id.[bb1, bb2] {
        if bb == NONE continue;
        for i: block_insts(bb) if inst_op(i) == .STORE {
            if st != NONE return NONE;
            st = i;
        }
    }
    return st;
}
ensure_value_available_in_successor :: (v: Value_Id, bb: Value_Id, alt: Value_Id = NONE) -> Value_Id {
    phi: Value_Id = NONE;
    succ := block_single_successor_of(bb);
    for i: block_insts(succ) {
        if inst_op(i) != .PHI break;
        if phi_incoming_value_for_block(i, bb) != v continue;
        phi = i;
        if alt == NONE break;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(succ, *preds);
        other := ifx preds[0] == bb then preds[1] else preds[0];
        if phi_incoming_value_for_block(phi, other) == alt break;
        phi = NONE;
    }
    if phi != NONE return phi;
    if alt == NONE && (!is_inst(v) || inst_block(v) != bb) return v;
    phi = create_phi(vtype(v), 2);
    insert_at_position(phi, succ, block_first(succ), true);
    set_name(phi, "simplifycfg.merge");
    phi_add_incoming(phi, v, bb);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(succ, *preds);
    for p: preds if p != bb phi_add_incoming(phi, ifx alt != NONE then alt else const_poison(vtype(v)), p);
    return phi;
}
// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable = false, BranchWeights = null, DTU): the new terminator
split_block_and_insert_if_then :: (s: *Scfg, cond: Value_Id, split_before: Value_Id, head_bit := false) -> Value_Id {
    head := inst_block(split_before);
    orig := unique_successors(head);
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "", head_bit);
    bb := create_block(f, "", tail);
    br := create_br(tail);
    block_append_inst(bb, br);
    copy_debug_loc_or_clear(br, split_before);
    old := block_terminator(head);
    nt := create_cond_br(cond, bb, tail);
    if get_metadata(nt, 0) == NONE copy_debug_loc(nt, old);
    insert_at_position(nt, head, old, false);
    erase_terminator(old);
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        array_add(*ups, .{true, head, bb});
        array_add(*ups, .{true, head, tail});
        array_add(*ups, .{true, bb, tail});
        for orig array_add(*ups, .{true, tail, it});
        for orig array_add(*ups, .{false, head, it});
        dtu_apply(s.dtu, ups);
    }
    return br;
}
// mergeConditionalStoreToAddress
merge_conditional_store_to_address :: (s: *Scfg, ptb: Value_Id, pfb: Value_Id, qtb: Value_Id, qfb: Value_Id, post_in: Value_Id, address: Value_Id, inv_p_in: bool, inv_q_in: bool) -> bool {
    post := post_in;
    ps := find_unique_store_in_blocks(ptb, pfb);
    qs := find_unique_store_in_blocks(qtb, qfb);
    if ps == NONE || qs == NONE return false;
    if !is_unordered(qs) || !is_unordered(ps) || inst(ps).ord1 != inst(qs).ord1 || inst(ps).sync != inst(qs).sync ||
       vtype(op(ps, 0)) != vtype(op(qs, 0)) return false;
    for i: block_insts(block_single_predecessor(qfb)) if may_read_or_write_memory(i) return false;
    for i: block_insts(qfb) if i != qs && may_read_or_write_memory(i) return false;
    if qtb != NONE for i: block_insts(qtb) if i != qs && may_read_or_write_memory(i) return false;
    x := ps;
    while x != NONE { if x != ps && may_read_or_write_memory(x) return false; x = inst_next(x); }
    worthwhile :: (s: *Scfg, bb: Value_Id, ps: Value_Id, qs: Value_Id) -> bool {
        if bb == NONE return true;
        cost: Cost = 0;
        budget := scfg_cl.phi_node_folding_threshold * TCC_BASIC;
        for i: block_insts(bb) {
            if is_terminator(inst_op(i)) continue;
            if inst_op(i) == .STORE && (i == ps || i == qs) continue;
            if !is_binary_op(inst_op(i)) && inst_op(i) != .GEP return false;
            cost = cost_add(cost, tti_instruction_cost(s.tti, i, TCK_SIZE_AND_LATENCY));
            if cost > budget return false;
        }
        return true;
    }
    if !scfg_cl.merge_cond_stores_aggressively &&
       (!worthwhile(s, ptb, ps, qs) || !worthwhile(s, pfb, ps, qs) || !worthwhile(s, qtb, ps, qs) || !worthwhile(s, qfb, ps, qs)) return false;
    if block_num_preds(post) != 2 {
        true_pred := ifx qtb != NONE then qtb else block_single_predecessor(qfb);
        sp := Value_Id.[qfb, true_pred];
        nbb := scfg_split_block_predecessors(s, post, sp, "condstore.split");
        if nbb == NONE return false;
        post = nbb;
    }
    pbr := block_terminator(block_single_predecessor(pfb));
    qbr := block_terminator(block_single_predecessor(qfb));
    pc := op(pbr, 0); qc := op(qbr, 0);
    pphi := ensure_value_available_in_successor(op(ps, 0), inst_block(ps));
    qphi := ensure_value_available_in_successor(op(qs, 0), inst_block(qs), pphi);
    first := block_first_insertion_pt(post);
    b: Irb; irb_set_at(*b, post, first, true);   // getFirstInsertionPt carries the head bit
    b.dbg = get_metadata(first, 0);   // getStableDebugLoc
    inv_p := inv_p_in != (inst_block(ps) != ptb);
    inv_q := inv_q_in != (inst_block(qs) != qtb);
    ppred := ifx inv_p then irb_not(*b, pc) else pc;
    qpred := ifx inv_q then irb_not(*b, qc) else qc;
    combined := irb_binop(*b, .OR, ppred, qpred);
    t := split_block_and_insert_if_then(s, combined, ifx b.pt != NONE then b.pt else block_first_insertion_pt(post), b.head);
    if prof_has_branch_weight_md(pbr) && prof_has_branch_weight_md(qbr) {
        _, pw := prof_extract_branch_weights(pbr);
        _, qw := prof_extract_branch_weights(qbr);
        p0, p1 := pw[0], pw[1]; q0, q1 := qw[0], qw[1];
        if inv_p { x := p0; p0 = p1; p1 = x; }
        if inv_q { x := q0; q0 = q1; q1 = x; }
        fw := (p1 & 0xFFFF_FFFF) * (q1 & 0xFFFF_FFFF);
        tw := p0 * (q0 + q1) + p1 * q0;
        w := u64.[tw, fw];
        prof_set_fitted_branch_weights(block_terminator(post), w, false, true);
    }
    irb_set_before(*b, t);
    si := irb_store(*b, qphi, address, min(inst(ps).align, inst(qs).align));
    combine_metadata_for_cse(qs, ps, true);
    copy_metadata(si, qs);
    // the dbg_assign records of SI's DIAssignID now track the merged value
    dbg_assign_replace_location(si, op(ps, 0), qphi);
    dbg_assign_replace_location(si, op(qs, 0), qphi);
    inst(si).align = min(inst(ps).align, inst(qs).align);
    if inst(qs).ord1 != 0 { inst(si).ord1 = inst(qs).ord1; inst(si).sync = inst(qs).sync; }
    erase_inst_with_metadata(qs);
    erase_inst_with_metadata(ps);
    return true;
}

// mergeConditionalStores
merge_conditional_stores :: (s: *Scfg, pbi: Value_Id, qbi: Value_Id) -> bool {
    ptb := get_successor(pbi, 0); pfb := get_successor(pbi, 1);
    qtb := get_successor(qbi, 0); qfb := get_successor(qbi, 1);
    post := block_single_successor_of(qfb);
    if block_single_successor_of(qtb) == qfb post = qfb;
    if post == NONE return false;
    inv_p := false; inv_q := false;
    if pfb == inst_block(qbi) { x := pfb; pfb = ptb; ptb = x; inv_p = true; }
    if qfb == post { x := qfb; qfb = qtb; qtb = x; inv_q = true; }
    if ptb == inst_block(qbi) ptb = NONE;
    if qtb == post qtb = NONE;
    one_pred_succ :: (bb: Value_Id, p: Value_Id, sc: Value_Id) -> bool { return block_single_predecessor(bb) == p && block_single_successor_of(bb) == sc; }
    if !one_pred_succ(pfb, inst_block(pbi), inst_block(qbi)) || !one_pred_succ(qfb, inst_block(qbi), post) return false;
    if (ptb != NONE && !one_pred_succ(ptb, inst_block(pbi), inst_block(qbi))) || (qtb != NONE && !one_pred_succ(qtb, inst_block(qbi), post)) return false;
    if num_uses(inst_block(qbi)) != 2 return false;
    pa: [..] Value_Id; pa.allocator = temp;
    qa: [..] Value_Id; qa.allocator = temp;
    for bb: Value_Id.[ptb, pfb] { if bb == NONE continue; for i: block_insts(bb) if inst_op(i) == .STORE && !block_set_contains(pa, op(i, 1)) array_add(*pa, op(i, 1)); }
    for bb: Value_Id.[qtb, qfb] { if bb == NONE continue; for i: block_insts(bb) if inst_op(i) == .STORE && !block_set_contains(qa, op(i, 1)) array_add(*qa, op(i, 1)); }
    if pa.count > 4 scfg_np("mergeConditionalStores with more than 4 store addresses (SmallPtrSet iteration order)");
    // set_intersect -> SmallPtrSet::remove_if (small mode: the last element moves into the hole)
    k := 0;
    e := pa.count;
    while k < e {
        if !block_set_contains(qa, pa[k]) { e -= 1; pa[k] = pa[e]; }
        else k += 1;
    }
    pa.count = e;
    changed := false;
    for a: pa changed |= merge_conditional_store_to_address(s, ptb, pfb, qtb, qfb, post, a, inv_p, inv_q);
    return changed;
}

// ---------------------------------------------------------------- conditional branch to conditional branch

is_widenable_branch :: (u: Value_Id) -> bool {
    if inst_op(u) != .CONDBR return false;
    c := op(u, 0);
    if num_uses(c) != 1 return false;
    is_wc :: (v: Value_Id) -> bool { id := call_iid(v); return id != NOT_INTRINSIC && iid_name(id) == "llvm.experimental.widenable.condition"; }
    if is_wc(c) return true;
    if !is_inst(c) || inst_op(c) != .AND return false;
    a := op(c, 0); b := op(c, 1);
    if is_wc(a) && num_uses(a) == 1 return true;
    if is_wc(b) && num_uses(b) == 1 return true;
    return false;
}
try_widen_cond_branch_to_cond_branch :: (s: *Scfg, pbi: Value_Id, bi: Value_Id) -> bool {
    if_true := get_successor(pbi, 0); if_false := get_successor(pbi, 1);
    if !is_widenable_branch(pbi) || if_true != inst_block(bi) || block_single_predecessor(inst_block(bi)) == NONE return false;
    if block_has_phis(if_false) return false;
    if block_num_successors(if_false) != 0 return false;
    no_side_effects :: (bb: Value_Id) -> bool { for i: block_insts(bb) if may_write_to_memory(i) || may_have_side_effects(i) return false; return true; }
    for k: u32.[1, 0] {
        succ := get_successor(bi, k);
        if succ != if_false && block_terminating_deoptimize_call(succ) != NONE && no_side_effects(inst_block(bi)) {
            block_remove_predecessor(succ, inst_block(bi));
            set_successor(bi, k, if_false);
            if s.dtu { ups := Dom_Update.[.{true, inst_block(bi), if_false}, .{false, inst_block(bi), succ}]; dtu_apply(s.dtu, ups); }
            return true;
        }
    }
    return false;
}
irb_binop_nofold :: (b: *Irb, opc: Opcode, l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    return irb_insert(b, i, name);
}
// SimplifyCondBranchToCondBranch
simplify_cond_branch_to_cond_branch :: (s: *Scfg, pbi: Value_Id, bi: Value_Id) -> bool {
    bb := inst_block(bi);
    if op(pbi, 0) == op(bi, 0) && get_successor(pbi, 0) != get_successor(pbi, 1) {
        if block_single_predecessor(bb) != NONE {
            set_op(bi, 0, const_int(ir.t_i1, ifx get_successor(pbi, 0) == bb then cast(u64) 1 else 0));
            return true;
        }
    }
    if try_widen_cond_branch_to_cond_branch(s, pbi, bi) return true;
    if scfg_cl.merge_cond_stores && merge_conditional_stores(s, pbi, bi) return true;
    if block_first(bb) != bi return false;
    pop_, bop: u32;
    if get_successor(pbi, 0) == get_successor(bi, 0) { pop_ = 0; bop = 0; }
    else if get_successor(pbi, 0) == get_successor(bi, 1) { pop_ = 0; bop = 1; }
    else if get_successor(pbi, 1) == get_successor(bi, 0) { pop_ = 1; bop = 0; }
    else if get_successor(pbi, 1) == get_successor(bi, 1) { pop_ = 1; bop = 1; }
    else return false;
    if get_successor(pbi, pop_) == bb return false;
    if get_metadata(pbi, md_kind("unpredictable")) == NONE {
        ok, pw := prof_extract_branch_weights(pbi);
        if ok && pw[0] + pw[1] != 0 {
            if bp_get(pw[pop_], pw[0] + pw[1]) >= tti_likely(s) return false;
        }
    }
    common := get_successor(pbi, pop_);
    removed := get_successor(pbi, pop_ ^ 1);
    nphis := 0;
    for block_insts(common) { if inst_op(it) != .PHI break; if nphis > 2 return false; nphis += 1; }
    other := get_successor(bi, bop ^ 1);
    updates: [..] Dom_Update; updates.allocator = temp;
    if other == bb {
        inf := create_block(block_fn(bb), "infloop");
        block_append_inst(inf, create_br(inf));
        if s.dtu array_add(*updates, .{true, inf, inf});
        other = inf;
    }
    pc := op(pbi, 0);
    b: Irb; irb_set_before(*b, pbi);
    if pop_ pc = irb_binop_nofold(*b, .XOR, pc, cf_all_ones(vtype(pc)), tprint("%.not", vname(pc)));
    bc := op(bi, 0);
    if bop bc = irb_binop_nofold(*b, .XOR, bc, cf_all_ones(vtype(bc)), tprint("%.not", vname(bc)));
    cond: Value_Id;
    if implies_poison(bc, pc) cond = irb_binop_nofold(*b, .OR, pc, bc, "brmerge");
    else cond = irb_select_fmf_nofold(*b, pc, const_int(vtype(pc), 1), bc, NONE, "brmerge", NONE);
    set_op(pbi, 0, cond);
    set_successor(pbi, 0, common);
    set_successor(pbi, 1, other);
    if s.dtu {
        array_add(*updates, .{true, inst_block(pbi), other});
        array_add(*updates, .{false, inst_block(pbi), removed});
        dtu_apply(s.dtu, updates);
    }
    ph, pt, pf := prof_extract_branch_weights_2(pbi);
    sh, st, sf := prof_extract_branch_weights_2(bi);
    hw := ph || sh;
    if hw {
        if !ph { pt = 1; pf = 1; }
        if !sh { st = 1; sf = 1; }
        pcw := ifx pop_ then pf else pt;
        pow := ifx pop_ then pt else pf;
        scw := ifx bop then sf else st;
        sow := ifx bop then st else sf;
        nw := u64.[pcw * (scw + sow) + pow * scw, pow * sow];
        prof_set_fitted_branch_weights(pbi, nw, false, true);
        if inst_op(cond) == .SELECT { w2 := u64.[pcw, pow]; prof_set_fitted_branch_weights(cond, w2, false, true); }
    }
    add_predecessor_to_block(other, inst_block(pbi), bb);
    for pn: block_insts(common) {
        if inst_op(pn) != .PHI break;
        biv := phi_incoming_value_for_block(pn, bb);
        idx := cast(u32) phi_block_index(pn, inst_block(pbi));
        pbiv := phi_value(pn, idx);
        if biv != pbiv {
            nv := irb_select_fmf_nofold(*b, pc, pbiv, biv, NONE, tprint("%.mux", vname(pbiv)), NONE);
            phi_set_value(pn, idx, nv);
            if hw { tw := ifx pop_ then pf else pt; fw := ifx pop_ then pt else pf; w := u64.[tw, fw]; prof_set_fitted_branch_weights(nv, w, false, true); }
        }
    }
    return true;
}

// for (DVR : at::getDVRAssignmentMarkers(I)) if (is_contained(DVR->location_ops(), Old)) DVR->replaceVariableLocationOp(Old, New)
dbg_assign_replace_location :: (i: Value_Id, old: Value_Id, new: Value_Id) {
    aid := get_metadata(i, md_kind_id("DIAssignID"));
    if aid == NONE return;
    ops: [..] Value_Id; ops.allocator = temp;
    for * rec, ri: ir.dbg_records {
        if rec.kind != .ASSIGN || rec.assign_id != aid || rec.owner == NONE continue;
        r := cast(u32) (ri + 1);
        dbgr_location_ops(r, *ops);
        if block_set_contains(ops, old) dbgr_replace_variable_location_op(r, old, new);
    }
}
