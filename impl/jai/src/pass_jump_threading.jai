// JumpThreading: a port of llvm/lib/Transforms/Scalar/JumpThreading.cpp, plus the utilities it needs from
// llvm/lib/Transforms/Utils/Local.cpp (MergeBasicBlockIntoOnlyPred, SimplifyInstructionsInBlock,
// replaceNonLocalUsesWith, remapDebugVariable), llvm/lib/Transforms/Utils/BasicBlockUtils.cpp (SplitEdge without a
// DominatorTree, DuplicateInstructionsInSplitBetween), llvm/lib/Analysis/Loads.cpp (FindAvailableLoadedValue with a
// scan position, findAvailablePtrLoadStore) and Constant::removeDeadConstantUsers.
//
// The DomTreeUpdater is the lazy one (scfg_util.jai `Dtu` with `lazy`). BlockFrequencyInfo / BranchProbabilityInfo
// (block_freq.jai, branch_prob.jai) are created and kept up to date exactly where LLVM does (getOrCreateBFI /
// runExternalAnalysis).

jt_cl: struct {
    bb_duplicate_threshold: s64 = -1;     // -jump-threading-threshold (-1 = not given; LLVM's default 6)
    implication_search_threshold: s64 = 3;
    phi_duplicate_threshold: s64 = 76;
    thread_across_loop_headers: bool;
};
JT_CL_OPT_COUNT :: 4;
add_jt_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"jump-threading-threshold", .INT, null, *jt_cl.bb_duplicate_threshold, null};
    list[start + 1] = .{"jump-threading-implication-search-threshold", .INT, null, *jt_cl.implication_search_threshold, null};
    list[start + 2] = .{"jump-threading-phi-threshold", .INT, null, *jt_cl.phi_duplicate_threshold, null};
    list[start + 3] = .{"jump-threading-across-loop-headers", .BOOL, *jt_cl.thread_across_loop_headers, null, null};
}

Jt_Pref :: enum u8 { WANT_INTEGER; WANT_BLOCK_ADDRESS; }
Jt_Pred_Value :: struct { c: Value_Id; bb: Value_Id; }   // PredValueInfo entry (constant, predecessor)

JT_DEF_MAX_INSTS_TO_SCAN :: 6;   // DefMaxInstsToScan

Jt :: struct {
    f: Value_Id;
    lvi: *Lvi;
    aar: Aa_Results;
    tti: *Tti;
    dtu: Dtu;
    unreachable: Table(Value_Id, bool);
    loop_headers: Table(Value_Id, bool);
    has_guards: bool;
    bb_dup_threshold: u32;
    bpi: *Bpi;
    bfi: *Bfi;
    changed_since_last_analysis_update: bool;
}

// ---------------------------------------------------------------- small helpers

jt_is_undef :: (v: Value_Id) -> bool { k := vkind(v); return k == .C_UNDEF || k == .C_POISON; }

// getKnownConstant
jt_get_known_constant :: (v: Value_Id, pref: Jt_Pref) -> Value_Id {
    if v == NONE return NONE;
    if jt_is_undef(v) return v;
    if pref == .WANT_BLOCK_ADDRESS {
        s := strip_pointer_casts(v);
        if vkind(s) == .C_BLOCKADDR return s;
        return NONE;
    }
    if vkind(v) == .C_INT return v;
    return NONE;
}

jt_preds :: (bb: Value_Id) -> [..] Value_Id {
    p: [..] Value_Id; p.allocator = temp;
    block_predecessors(bb, *p);
    return p;
}

// Instruction::isUsedOutsideOfBlock
jt_is_used_outside_of_block :: (i: Value_Id, bb: Value_Id) -> bool {
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if inst_op(user) != .PHI { if inst_block(user) != bb return true; }
        else if ir.u_aux[u] != bb return true;
        u = ir.u_next[u];
    }
    return false;
}

// BasicBlock::hasNPredecessors
jt_has_n_predecessors :: (bb: Value_Id, n: s64) -> bool { return jt_preds(bb).count == n; }

// isGuard
jt_is_guard :: (i: Value_Id) -> bool { return call_iid(i) == IID_EXPERIMENTAL_GUARD; }

// replaceNonLocalUsesWith
replace_non_local_uses_with :: (from: Value_Id, to: Value_Id) -> u32 {
    bb := inst_block(from);
    count: u32 = 0;
    u := ir.v_first_use[from];
    while u != NONE {
        nx := ir.u_next[u];
        if inst_block(ir.u_user[u]) != bb { use_set(u, to); count += 1; }
        u = nx;
    }
    return count;
}

// Constant::removeDeadConstantUsers
remove_dead_constant_users :: (c: Value_Id) {
    is_dead :: (c: Value_Id) -> bool {
        if is_global_value(vkind(c)) return false;
        while ir.v_first_use[c] != NONE {
            usr := ir.u_user[ir.v_first_use[c]];
            if !is_constant_kind(vkind(usr)) || is_global_value(vkind(usr)) || vkind(usr) == .C_BLOCKADDR return false;
            if !is_dead(usr) return false;
        }
        destroy_constant(c);
        return true;
    }
    // walk the users; a destroyed user restarts after the last live one
    last_live: Use_Id = NONE;
    u := ir.v_first_use[c];
    while u != NONE {
        usr := ir.u_user[u];
        // a blockaddress is not a user of its function in LLVM 23 (only ~BasicBlock destroys it), so it stays
        if !is_constant_kind(vkind(usr)) || is_global_value(vkind(usr)) || vkind(usr) == .C_BLOCKADDR || !is_dead(usr) { last_live = u; u = ir.u_next[u]; continue; }
        u = ifx last_live == NONE then ir.v_first_use[c] else ir.u_next[last_live];
    }
}

// hasAddressTakenAndUsed
jt_has_address_taken_and_used :: (bb: Value_Id) -> bool {
    if !block_has_address_taken(bb) return false;
    ba := const_blockaddr(block_fn(bb), bb);
    remove_dead_constant_users(ba);
    return has_uses(ba);
}

// BasicBlock::moveAfter
jt_move_block_after :: (bb: Value_Id, after: Value_Id) {
    f := block_fn(bb);
    if block(after).next == bb return;
    fn_unlink_block(f, bb);
    fn_insert_block_after(f, after, bb);
}

// getJumpThreadDuplicationCost
jt_duplication_cost :: (j: *Jt, bb: Value_Id, stop_at: Value_Id, threshold_in: u32) -> u32 {
    threshold := threshold_in;
    phi_count: s64 = 0;
    first_non_phi: Value_Id = NONE;
    for block_insts(bb) {
        if inst_op(it) != .PHI { first_non_phi = it; break; }
        phi_count += 1;
        if phi_count > jt_cl.phi_duplicate_threshold return 0xFFFF_FFFF;
    }
    bonus: u32 = 0;
    if block_terminator(bb) == stop_at {
        if inst_op(stop_at) == .SWITCH bonus = 6;
        if inst_op(stop_at) == .INDIRECTBR bonus = 8;
    }
    threshold += bonus;
    size: u32 = 0;
    i := first_non_phi;
    while i != stop_at {
        defer i = inst_next(i);
        if size > threshold return size;
        if type_kind(vtype(i)) == .TOKEN && jt_is_used_outside_of_block(i, bb) return 0xFFFF_FFFF;
        if inst_op(i) == .CALL && (call_has_fn_attr(i, .NoDuplicate) || call_is_convergent(i)) return 0xFFFF_FFFF;
        if tti_instruction_cost(j.tti, i, TCK_SIZE_AND_LATENCY) == TCC_FREE continue;
        size += 1;
        if inst_op(i) == .CALL {
            if call_iid(i) == NOT_INTRINSIC size += 3;
            else if !is_vector_type(vtype(i)) size += 1;
        }
    }
    return ifx size > bonus then size - bonus else 0;
}

// ---------------------------------------------------------------- computeValueKnownInPredecessors

jt_compute_value_known_in_predecessors :: (j: *Jt, v: Value_Id, bb: Value_Id, result: *[..] Jt_Pred_Value, pref: Jt_Pref, cxt: Value_Id = NONE) -> bool {
    rs: Table(Value_Id, bool); rs.allocator = temp;
    return jt_compute_value_known_in_predecessors_impl(j, v, bb, result, pref, *rs, cxt);
}

jt_compute_value_known_in_predecessors_impl :: (j: *Jt, v: Value_Id, bb: Value_Id, result: *[..] Jt_Pred_Value, pref: Jt_Pref,
                                                rs: *Table(Value_Id, bool), cxt: Value_Id) -> bool {
    if table_contains(rs, v) return false;
    table_set(rs, v, true);
    kc := jt_get_known_constant(v, pref);
    if kc != NONE {
        for p: jt_preds(bb) array_add(result, .{kc, p});
        return result.count > 0;
    }
    if !is_inst(v) || inst_block(v) != bb {
        for p: jt_preds(bb) {
            pred_cst := lvi_get_constant_on_edge(j.lvi, v, p, bb, cxt);
            if pred_cst == NONE && is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP) && is_constant_kind(vkind(op(v, 1))) {
                pred_cst = lvi_get_predicate_on_edge(j.lvi, inst_pred(v), op(v, 0), op(v, 1), p, bb, cxt);
            }
            k := jt_get_known_constant(pred_cst, pref);
            if k != NONE array_add(result, .{k, p});
        }
        return result.count > 0;
    }
    i := v;
    o := inst_op(i);
    if o == .PHI {
        n := phi_num_incoming(i);
        for k: 0..cast(s64) n - 1 {
            in_val := phi_value(i, cast(u32) k);
            in_bb := phi_block(i, cast(u32) k);
            kc2 := jt_get_known_constant(in_val, pref);
            if kc2 != NONE array_add(result, .{kc2, in_bb});
            else {
                ci := lvi_get_constant_on_edge(j.lvi, in_val, in_bb, bb, cxt);
                kc3 := jt_get_known_constant(ci, pref);
                if kc3 != NONE array_add(result, .{kc3, in_bb});
            }
        }
        return result.count > 0;
    }
    if is_cast_op(o) {
        vals: [..] Jt_Pred_Value; vals.allocator = temp;
        jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, *vals, pref, rs, cxt);
        if vals.count == 0 return false;
        for vals {
            folded := cfo_cast_operand(o, it.c, vtype(i));
            if folded != NONE array_add(result, .{folded, it.bb});
        }
        return result.count > 0;
    }
    if o == .FREEZE {
        jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, result, pref, rs, cxt);
        k := 0;
        for result.* { if is_guaranteed_not_to_be_undef_or_poison(it.c) { result.*[k] = it; k += 1; } }
        result.count = k;
        return result.count > 0;
    }
    t := vtype(i);
    if type_kind(t) == .INT && type_int_width(t) == 1 {   // getPrimitiveSizeInBits() == 1
        if pref != .WANT_INTEGER return false;
        oka, a0, a1 := pm_logical_or(i);
        is_or := oka;
        if !oka { oka, a0, a1 = pm_logical_and(i); }
        if oka {
            lhs_vals: [..] Jt_Pred_Value; lhs_vals.allocator = temp;
            rhs_vals: [..] Jt_Pred_Value; rhs_vals.allocator = temp;
            jt_compute_value_known_in_predecessors_impl(j, a0, bb, *lhs_vals, .WANT_INTEGER, rs, cxt);
            jt_compute_value_known_in_predecessors_impl(j, a1, bb, *rhs_vals, .WANT_INTEGER, rs, cxt);
            if lhs_vals.count == 0 && rhs_vals.count == 0 return false;
            interesting := const_int(ir.t_i1, ifx is_or then cast(u64) 1 else 0);
            lhs_known: [..] Value_Id; lhs_known.allocator = temp;
            for lhs_vals if it.c == interesting || jt_is_undef(it.c) { array_add(result, .{interesting, it.bb}); array_add(*lhs_known, it.bb); }
            for rhs_vals if it.c == interesting || jt_is_undef(it.c) {
                if !block_set_contains(lhs_known, it.bb) array_add(result, .{interesting, it.bb});
            }
            return result.count > 0;
        }
        if o == .XOR && is_scalar_const_int(op(i, 1)) && ap_is_one(const_ap(op(i, 1))) {
            jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, result, .WANT_INTEGER, rs, cxt);
            if result.count == 0 return false;
            for * result.* it.c = ce_not(it.c);
            return true;
        }
    } else if is_binary_op(o) {
        if pref != .WANT_INTEGER return false;
        ci := op(i, 1);
        if vkind(ci) == .C_INT {
            lhs_vals: [..] Jt_Pred_Value; lhs_vals.allocator = temp;
            jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, *lhs_vals, .WANT_INTEGER, rs, cxt);
            for lhs_vals {
                folded := cfo_binary_op_operands(o, it.c, ci);
                k := jt_get_known_constant(folded, .WANT_INTEGER);
                if k != NONE array_add(result, .{k, it.bb});
            }
        }
        return result.count > 0;
    }
    if o == .ICMP || o == .FCMP {
        if pref != .WANT_INTEGER return false;
        cmp_type := vtype(i);
        cmp_lhs := op(i, 0); cmp_rhs := op(i, 1);
        pred := inst_pred(i);
        pn: Value_Id = NONE;
        if is_phi(cmp_lhs) pn = cmp_lhs;
        else if is_phi(cmp_rhs) pn = cmp_rhs;
        if pn != NONE && inst_block(pn) == bb && !table_contains(*j.loop_headers, bb) {
            n := phi_num_incoming(pn);
            for k: 0..cast(s64) n - 1 {
                pred_bb := phi_block(pn, cast(u32) k);
                lhs, rhs: Value_Id;
                if pn == cmp_lhs { lhs = phi_value(pn, cast(u32) k); rhs = do_phi_translation(cmp_rhs, bb, pred_bb); }
                else { lhs = do_phi_translation(cmp_lhs, bb, pred_bb); rhs = phi_value(pn, cast(u32) k); }
                q: Simplify_Query; q.have_tli = false;
                res := simplify_cmp_inst(pred, false, lhs, rhs, q);
                if res == NONE {
                    if !is_constant_kind(vkind(rhs)) continue;
                    if is_inst(lhs) && inst_block(lhs) == bb continue;
                    res = lvi_get_predicate_on_edge(j.lvi, pred, lhs, rhs, pred_bb, bb, ifx cxt != NONE then cxt else i);
                }
                kc2 := jt_get_known_constant(res, .WANT_INTEGER);
                if kc2 != NONE array_add(result, .{kc2, pred_bb});
            }
            return result.count > 0;
        }
        if is_constant_kind(vkind(cmp_rhs)) && !is_vector_type(cmp_type) {
            cmp_const := cmp_rhs;
            if !is_inst(cmp_lhs) || inst_block(cmp_lhs) != bb {
                for p: jt_preds(bb) {
                    res := lvi_get_predicate_on_edge(j.lvi, pred, cmp_lhs, cmp_const, p, bb, ifx cxt != NONE then cxt else i);
                    kc2 := jt_get_known_constant(res, .WANT_INTEGER);
                    if kc2 != NONE array_add(result, .{kc2, p});
                }
                return result.count > 0;
            }
            if vkind(cmp_const) == .C_INT && opr_code(cmp_lhs) == .ADD && vkind(op(cmp_lhs, 1)) == .C_INT && !is_vector_type(vtype(op(cmp_lhs, 1))) {
                add_lhs := op(cmp_lhs, 0);
                add_const := op(cmp_lhs, 1);
                if !is_inst(add_lhs) || inst_block(add_lhs) != bb {
                    for p: jt_preds(bb) {
                        cr := lvi_get_constant_range_on_edge(j.lvi, add_lhs, p, bb, ifx cxt != NONE then cxt else cmp_lhs);
                        cr = cr_add(cr, cr_single(const_ap(add_const)));
                        cmp_range := cr_exact_icmp_region(pred, const_ap(cmp_const));
                        res_c: Value_Id;
                        if cr_contains_range(cmp_range, cr) res_c = const_int(cmp_type, 1);
                        else if cr_contains_range(cr_inverse(cmp_range), cr) res_c = const_int(cmp_type, 0);
                        else continue;
                        array_add(result, .{res_c, p});
                    }
                    return result.count > 0;
                }
            }
            lhs_vals: [..] Jt_Pred_Value; lhs_vals.allocator = temp;
            jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, *lhs_vals, .WANT_INTEGER, rs, cxt);
            for lhs_vals {
                folded := cfo_compare_inst_operands(pred, it.c, cmp_const);
                kc2 := jt_get_known_constant(folded, .WANT_INTEGER);
                if kc2 != NONE array_add(result, .{kc2, it.bb});
            }
            return result.count > 0;
        }
    }
    if o == .SELECT {
        true_val := jt_get_known_constant(op(i, 1), pref);
        false_val := jt_get_known_constant(op(i, 2), pref);
        conds: [..] Jt_Pred_Value; conds.allocator = temp;
        if (true_val != NONE || false_val != NONE) && jt_compute_value_known_in_predecessors_impl(j, op(i, 0), bb, *conds, .WANT_INTEGER, rs, cxt) {
            for c: conds {
                known_cond: bool;
                if vkind(c.c) == .C_INT known_cond = ap_is_one(const_ap(c.c));
                else { assert(jt_is_undef(c.c), "Unexpected condition value"); known_cond = true_val != NONE; }
                val := ifx known_cond then true_val else false_val;
                if val != NONE array_add(result, .{val, c.bb});
            }
            return result.count > 0;
        }
    }
    assert(inst_block(cxt) == bb, "CxtI should be in BB");
    ci := lvi_get_constant(j.lvi, v, cxt);
    kc4 := jt_get_known_constant(ci, pref);
    if kc4 != NONE for p: jt_preds(bb) array_add(result, .{kc4, p});
    return result.count > 0;
}

// getBestDestForJumpOnUndef
jt_get_best_dest_for_jump_on_undef :: (bb: Value_Id) -> u32 {
    t := block_terminator(bb);
    min_succ: u32 = 0;
    min_num_preds := jt_preds(get_successor(t, 0)).count;
    n := num_successors(t);
    for k: 1..cast(s64) n - 1 {
        np := jt_preds(get_successor(t, cast(u32) k)).count;
        if np < min_num_preds { min_succ = cast(u32) k; min_num_preds = np; }
    }
    return min_succ;
}

// ---------------------------------------------------------------- the driver

// replaceFoldableUses
jt_replace_foldable_uses :: (cond: Value_Id, to_val: Value_Id, known_at_end_of_bb: Value_Id) -> bool {
    changed := false;
    if inst_block(cond) == known_at_end_of_bb changed |= replace_non_local_uses_with(cond, to_val) > 0;
    i := block_last(known_at_end_of_bb);
    while i != NONE {
        r := inst(i).records;
        while r != 0 {
            nr := dbgr(r).next;
            if dbgr(r).kind != .LABEL dbgr_replace_variable_location_op(r, cond, to_val, true);
            r = nr;
        }
        if i == cond break;
        if !is_guaranteed_to_transfer_execution(i) break;
        n := nops(i);
        for k: 0..cast(s64) n - 1 if op(i, cast(u32) k) == cond { set_op(i, cast(u32) k, to_val); changed = true; }
        i = inst_prev(i);
    }
    if !has_uses(cond) && !may_have_side_effects(cond) {
        erase_inst_with_metadata(cond);
        changed = true;
    }
    return changed;
}

// UncondBrInst::Create(Dest, Term->getIterator()) + setDebugLoc(Term->getDebugLoc())
jt_br_before :: (dest: Value_Id, term: Value_Id) -> Value_Id {
    br := create_br(dest);
    insert_at_position(br, inst_block(term), term, false);
    set_metadata(br, 0, get_metadata(term, 0));
    return br;
}

// Erase a terminator; its debug records (none after jt_br_before adopted them) must not be lost
jt_erase_terminator :: (t: Value_Id) {
    if inst(t).records fatal("jump-threading: erasing a terminator with debug records attached is not supported yet");
    erase_inst_with_metadata(t);
}

jump_threading_run :: (f: Value_Id) -> Preserved {
    j: Jt;
    j.tti = tti_get(f);
    j.lvi = get_lvi(f);
    j.aar = aa_results_for(f);
    dt := get_domtree(f);
    j.f = f;
    j.dtu.dt = dt; j.dtu.lazy = true;
    j.dtu.pending.allocator = temp; j.dtu.deleted.allocator = temp; j.dtu.deleted_set.allocator = temp;
    j.unreachable.allocator = temp;
    j.loop_headers.allocator = temp;
    changed := jt_run_impl(*j);
    if !changed return PRESERVE_ALL;
    dtu_flush(*j.dtu);
    pa: Preserved;
    preserve(*pa, .LVI);
    preserve(*pa, .DOMTREE);
    return pa;
}

jt_run_impl :: (j: *Jt) -> bool {
    f := j.f;
    g := lookup_global("llvm.experimental.guard");
    j.has_guards = g != NONE && vkind(g) == .FUNCTION && has_uses(g);
    if jt_cl.bb_duplicate_threshold >= 0 j.bb_dup_threshold = cast(u32) jt_cl.bb_duplicate_threshold;
    else if fn_has_fn_attr(f, .MinSize) j.bb_dup_threshold = 3;
    else j.bb_dup_threshold = 6;
    dt := dtu_get_dom_tree(*j.dtu);
    for bb: fn_blocks(f) if !dt_is_reachable_from_entry(dt, bb) table_set(*j.unreachable, bb, true);
    if !jt_cl.thread_across_loop_headers {
        edges: [..] Block_Edge; edges.allocator = temp;
        find_function_backedges(f, *edges);
        for edges table_set(*j.loop_headers, it.to, true);
    }
    ever_changed := false;
    while true {
        changed := false;
        bb := fn_entry(f);
        while bb != NONE {
            defer bb = block(bb).next;
            if table_contains(*j.unreachable, bb) continue;
            while jt_process_block(j, bb) { changed = true; j.changed_since_last_analysis_update = true; }
            if bb == fn_entry(f) || dtu_is_bb_pending_deletion(*j.dtu, bb) continue;
            if jt_preds(bb).count == 0 {
                table_remove(*j.loop_headers, bb);
                lvi_erase_block(j.lvi, bb);
                delete_dead_block(bb, *j.dtu);
                changed = true; j.changed_since_last_analysis_update = true;
                continue;
            }
            t := block_terminator(bb);
            if inst_op(t) == .BR {
                succ := get_successor(t, 0);
                fi := block_first_non_phi_or_dbg_skip_pseudo(bb);
                if fi != NONE && is_terminator(inst_op(fi)) && !table_contains(*j.loop_headers, bb) && !table_contains(*j.loop_headers, succ) &&
                   try_to_simplify_uncond_branch_from_empty_block(bb, *j.dtu) {
                    lvi_erase_block(j.lvi, bb);
                    changed = true; j.changed_since_last_analysis_update = true;
                }
            }
        }
        ever_changed |= changed;
        if !changed break;
    }
    if ever_changed for bb: fn_blocks(f) remove_redundant_dbg_instrs(bb);
    return ever_changed;
}

// BasicBlock::getFirstNonPHIOrDbg(SkipPseudoOp = true)
block_first_non_phi_or_dbg_skip_pseudo :: (b: Value_Id) -> Value_Id {
    for block_insts(b) {
        o := inst_op(it);
        if o == .PHI continue;
        if call_iid(it) == IID_PSEUDOPROBE continue;
        return it;
    }
    return NONE;
}

// processBlock
jt_process_block :: (j: *Jt, bb: Value_Id) -> bool {
    if dtu_is_bb_pending_deletion(*j.dtu, bb) || (jt_preds(bb).count == 0 && bb != fn_entry(block_fn(bb))) return false;
    if jt_maybe_merge_basic_block_into_only_pred(j, bb) return true;
    if jt_try_to_unfold_select_in_curr_bb(j, bb) return true;
    if j.has_guards && jt_process_guards(j, bb) return true;
    pref := Jt_Pref.WANT_INTEGER;
    condition: Value_Id;
    terminator := block_terminator(bb);
    to := inst_op(terminator);
    if to == .CONDBR condition = op(terminator, 0);
    else if to == .SWITCH condition = sw_cond(terminator);
    else if to == .INDIRECTBR {
        if num_successors(terminator) == 0 return false;
        condition = strip_pointer_casts(op(terminator, 0));
        pref = .WANT_BLOCK_ADDRESS;
    } else return false;

    constant_folded := false;
    if is_inst(condition) {
        simple := cfo_instruction(condition);
        if simple != NONE {
            ci := condition;
            rauw_with_metadata(ci, simple);
            if is_instruction_trivially_dead(ci) erase_inst_with_metadata(ci);
            condition = simple;
            constant_folded = true;
        }
    }

    fi: Value_Id = ifx is_inst(condition) && inst_op(condition) == .FREEZE then condition else NONE;
    if jt_is_undef(condition) || (fi != NONE && jt_is_undef(op(fi, 0)) && has_one_use(fi)) {
        best_succ := jt_get_best_dest_for_jump_on_undef(bb);
        updates: [..] Dom_Update; updates.allocator = temp;
        bb_term := block_terminator(bb);
        n := num_successors(bb_term);
        for k: 0..cast(s64) n - 1 {
            if k == best_succ continue;
            succ := get_successor(bb_term, cast(u32) k);
            block_remove_predecessor(succ, bb, true);
            array_add(*updates, .{false, bb, succ});
        }
        jt_br_before(get_successor(bb_term, best_succ), bb_term);
        jt_erase_terminator(bb_term);
        dtu_apply_permissive(*j.dtu, updates);
        if fi != NONE erase_inst_with_metadata(fi);
        return true;
    }

    if jt_get_known_constant(condition, pref) != NONE {
        constant_fold_terminator(bb, true, *j.dtu);
        bpi := jt_get_bpi(j); if bpi bpi_erase_block(bpi, bb);
        return true;
    }

    if !is_inst(condition) {
        if jt_process_threadable_edges(j, condition, bb, pref, terminator) return true;
        return constant_folded;
    }
    cond_inst := condition;
    cond_without_freeze := cond_inst;
    if inst_op(cond_inst) == .FREEZE cond_without_freeze = op(cond_inst, 0);

    if is_inst(cond_without_freeze) && (inst_op(cond_without_freeze) == .ICMP || inst_op(cond_without_freeze) == .FCMP) {
        cond_cmp := cond_without_freeze;
        cond_const := op(cond_cmp, 1);
        if is_constant_kind(vkind(cond_const)) {
            res := lvi_get_predicate_at(j.lvi, inst_pred(cond_cmp), op(cond_cmp, 0), cond_const, block_terminator(bb), false);
            if res != NONE {
                if jt_replace_foldable_uses(cond_cmp, res, bb) return true;
            }
            if jt_try_to_unfold_select_cmp(j, cond_cmp, bb) return true;
        }
    }
    if inst_op(block_terminator(bb)) == .SWITCH && jt_try_to_unfold_select_switch(j, block_terminator(bb), bb) return true;

    simplify_value := cond_without_freeze;
    if is_inst(simplify_value) && (inst_op(simplify_value) == .ICMP || inst_op(simplify_value) == .FCMP) && is_constant_kind(vkind(op(simplify_value, 1)))
        simplify_value = op(simplify_value, 0);
    if is_inst(simplify_value) && inst_op(simplify_value) == .LOAD && jt_simplify_partially_redundant_load(j, simplify_value) return true;

    if is_phi(cond_inst) && inst_block(cond_inst) == bb && inst_op(block_terminator(bb)) == .CONDBR
        jt_update_predecessor_profile_metadata(cond_inst, bb);

    if jt_process_threadable_edges(j, cond_inst, bb, pref, terminator) return true;

    if is_phi(cond_without_freeze) && inst_block(cond_without_freeze) == bb && inst_op(block_terminator(bb)) == .CONDBR
        return jt_process_branch_on_phi(j, cond_without_freeze);

    if inst_op(cond_inst) == .XOR && inst_block(cond_inst) == bb && inst_op(block_terminator(bb)) == .CONDBR
        return jt_process_branch_on_xor(j, cond_inst);

    if jt_process_implied_condition(j, bb) return true;
    return false;
}

// updatePredecessorProfileMetadata
jt_update_predecessor_profile_metadata :: (pn: Value_Id, bb: Value_Id) {
    cond_br := block_terminator(bb);
    if inst_op(cond_br) != .CONDBR return;
    ok, tw, fw := prof_extract_branch_weights_2(cond_br);
    if !ok return;
    if tw + fw == 0 return;
    get_pred_out_edge :: (incoming_bb: Value_Id, phi_bb: Value_Id) -> (Value_Id, Value_Id) {
        pred_bb := incoming_bb; succ_bb := phi_bb;
        visited: [..] Value_Id; visited.allocator = temp;
        while true {
            if inst_op(block_terminator(pred_bb)) == .CONDBR return pred_bb, succ_bb;
            array_add(*visited, pred_bb);
            sp := block_single_predecessor(pred_bb);
            if sp == NONE return NONE, NONE;
            if block_set_contains(visited, sp) return NONE, NONE;
            succ_bb = pred_bb;
            pred_bb = sp;
        }
        return NONE, NONE;
    }
    n := phi_num_incoming(pn);
    for k: 0..cast(s64) n - 1 {
        ci := phi_value(pn, cast(u32) k);
        if vkind(ci) != .C_INT || type_kind(vtype(ci)) != .INT || type_int_width(vtype(ci)) != 1 continue;
        bp := ifx ap_is_one(const_ap(ci)) then bp_get(tw, tw + fw) else bp_get(fw, tw + fw);
        pred_bb, out_succ := get_pred_out_edge(phi_block(pn, cast(u32) k), bb);
        if pred_bb == NONE return;
        pred_br := block_terminator(pred_bb);
        if inst_op(pred_br) != .CONDBR return;
        okp, _, _ := prof_extract_branch_weights_2(pred_br);
        if okp continue;
        if bp >= bp_make(50, 100) continue;
        weights: [2] u32;
        if get_successor(pred_br, 0) == out_succ { weights[0] = bp; weights[1] = bp_compl(bp); }
        else { weights[0] = bp_compl(bp); weights[1] = bp; }
        prof_set_branch_weights(pred_br, weights, prof_has_branch_weight_origin(prof_md(pred_br)));
    }
}

// processImpliedCondition
jt_process_implied_condition :: (j: *Jt, bb: Value_Id) -> bool {
    bi := block_terminator(bb);
    if inst_op(bi) != .CONDBR return false;
    cond := op(bi, 0);
    fi_cond: Value_Id = NONE;
    if is_inst(cond) && inst_op(cond) == .FREEZE && has_one_use(cond) { fi_cond = cond; cond = op(cond, 0); }
    current_bb := bb;
    current_pred := block_single_predecessor(bb);
    iter := 0;
    while current_pred != NONE && iter < jt_cl.implication_search_threshold {
        iter += 1;
        pbi := block_terminator(current_pred);
        if inst_op(pbi) != .CONDBR return false;
        if get_successor(pbi, 0) != current_bb && get_successor(pbi, 1) != current_bb return false;
        cond_is_true := get_successor(pbi, 0) == current_bb;
        implication := is_implied_condition(op(pbi, 0), cond, cond_is_true);
        if implication < 0 && fi_cond != NONE && is_inst(op(pbi, 0)) && inst_op(op(pbi, 0)) == .FREEZE {
            if op(op(pbi, 0), 0) == op(fi_cond, 0) implication = ifx cond_is_true then cast(s8) 1 else 0;
        }
        if implication >= 0 {
            keep_succ := get_successor(bi, ifx implication == 1 then cast(u32) 0 else 1);
            remove_succ := get_successor(bi, ifx implication == 1 then cast(u32) 1 else 0);
            block_remove_predecessor(remove_succ, bb);
            jt_br_before(keep_succ, bi);
            jt_erase_terminator(bi);
            if fi_cond != NONE erase_inst_with_metadata(fi_cond);
            dtu_apply_permissive(*j.dtu, .[.{false, bb, remove_succ}]);
            bpi := jt_get_bpi(j); if bpi bpi_erase_block(bpi, bb);
            return true;
        }
        current_bb = current_pred;
        current_pred = block_single_predecessor(current_bb);
    }
    return false;
}

// isOpDefinedInBlock
jt_is_op_defined_in_block :: (o: Value_Id, bb: Value_Id) -> bool { return is_inst(o) && inst_block(o) == bb; }

// findAvailablePtrLoadStore(Loc, AccessTy, AtLeastAtomic, ScanBB, ScanFrom, MaxInstsToScan, AA, IsLoadCSE, NumScanedInst)
// `scan_from` is the iterator: the instruction *after* the next one to look at (NONE = ScanBB->end()); returns it.
find_available_ptr_load_store :: (loc: Mem_Loc, access_ty: Type_Id, at_least_atomic: bool, scan_bb: Value_Id, scan_from_in: Value_Id,
                                  max_insts_in: u32, aaq: *Aa_Query, is_load_cse: *bool, num_scaned: *u32) -> (Value_Id, Value_Id) {
    max_insts := max_insts_in;
    if max_insts == 0 max_insts = 0xFFFF_FFFF;
    stripped := strip_pointer_casts(loc.ptr);
    scan_from := scan_from_in;
    while scan_from != block_first(scan_bb) {
        i := ifx scan_from == NONE then block_last(scan_bb) else inst_prev(scan_from);
        if is_debug_or_pseudo_inst(i) { scan_from = i; continue; }
        if num_scaned num_scaned.* += 1;
        if max_insts == 0 return NONE, scan_from;
        max_insts -= 1;
        scan_from = i;
        avail := get_available_load_store(i, stripped, access_ty, at_least_atomic, is_load_cse);
        if avail != NONE return avail, scan_from;
        if inst_op(i) == .STORE {
            store_ptr := strip_pointer_casts(op(i, 1));
            sp_ok := (is_inst(stripped) && inst_op(stripped) == .ALLOCA) || vkind(stripped) == .GLOBAL_VAR;
            st_ok := (is_inst(store_ptr) && inst_op(store_ptr) == .ALLOCA) || vkind(store_ptr) == .GLOBAL_VAR;
            if sp_ok && st_ok && stripped != store_ptr continue;
            if !aaq {
                if are_non_overlap_same_base_load_and_store(loc.ptr, access_ty, op(i, 1), vtype(op(i, 0))) continue;
            } else if !mr_is_mod_set(aa_mod_ref_inst_loc(aaq, i, loc)) continue;
            return NONE, inst_next(scan_from);
        }
        if may_write_to_memory(i) {
            if aaq && !mr_is_mod_set(aa_mod_ref_inst_loc(aaq, i, loc)) continue;
            return NONE, inst_next(scan_from);
        }
    }
    return NONE, scan_from;
}

// areNonOverlapSameBaseLoadAndStore (Loads.cpp; findAvailablePtrLoadStore without AA)
are_non_overlap_same_base_load_and_store :: (load_ptr: Value_Id, load_ty: Type_Id, store_ptr: Value_Id, store_ty: Type_Id) -> bool {
    lw := dl_index_type_size_bits(vtype(load_ptr));
    sw := dl_index_type_size_bits(vtype(store_ptr));
    if lw != sw return false;
    lb, lo := strip_and_accumulate_constant_offsets(load_ptr, ap_zero(lw), false);
    sb, so := strip_and_accumulate_constant_offsets(store_ptr, ap_zero(sw), false);
    if lb != sb return false;
    lr := cr_new(lo, ap_add(lo, ap_from_u64(lw, dl_type_store_size(load_ty))));
    sr := cr_new(so, ap_add(so, ap_from_u64(sw, dl_type_store_size(store_ty))));
    return cr_is_empty_set(cr_intersect(lr, sr));
}

// simplifyPartiallyRedundantLoad
jt_simplify_partially_redundant_load :: (j: *Jt, load_i: Value_Id) -> bool {
    if !is_unordered(load_i) return false;
    load_bb := inst_block(load_i);
    if block_single_predecessor(load_bb) != NONE return false;
    if block_is_eh_pad(load_bb) return false;
    loaded_ptr := op(load_i, 0);
    if jt_is_op_defined_in_block(loaded_ptr, load_bb) && !is_phi(loaded_ptr) return false;
    aaq := aa_query_new(*j.aar);
    aaq.use_dominator_tree = false;
    is_load_cse := false;
    // FindAvailableLoadedValue(LoadI, LoadBB, BBIt, DefMaxInstsToScan, &BatchAA, &IsLoadCSE)
    available, bb_it := find_available_ptr_load_store(mloc_get(load_i), vtype(load_i), inst(load_i).ord1 != 0, load_bb, load_i,
                                                       JT_DEF_MAX_INSTS_TO_SCAN, aaq, *is_load_cse, null);
    if available != NONE {
        if is_load_cse {
            nl := available;
            combine_metadata_for_cse(nl, load_i, false);
            lvi_forget_value(j.lvi, nl);
        }
        if available == load_i available = const_poison(vtype(load_i));
        if vtype(available) != vtype(load_i) {
            c := create_cast(bit_or_pointer_cast_opcode(vtype(available), vtype(load_i)), available, vtype(load_i));
            insert_at_position(c, load_bb, load_i, false);
            set_metadata(c, 0, get_metadata(load_i, 0));
            available = c;
        }
        rauw_with_metadata(load_i, available);
        erase_inst_with_metadata(load_i);
        return true;
    }
    if bb_it != block_first(load_bb) return false;
    aa_tags := mloc_get(load_i).tags;
    preds_scanned: [..] Value_Id; preds_scanned.allocator = temp;
    available_preds: [..] [2] Value_Id; available_preds.allocator = temp;   // (pred, value)
    one_unavailable_pred: Value_Id = NONE;
    cse_loads: [..] Value_Id; cse_loads.allocator = temp;
    for pred_bb: jt_preds(load_bb) {
        if block_set_contains(preds_scanned, pred_bb) continue;
        array_add(*preds_scanned, pred_bb);
        num_scaned: u32 = 0;
        access_ty := vtype(load_i);
        loc: Mem_Loc;
        loc.ptr = do_phi_translation(loaded_ptr, load_bb, pred_bb);
        loc.size = ls_precise(dl_type_store_size(access_ty));
        loc.tags = aa_tags;
        pred_available, it_pos := find_available_ptr_load_store(loc, access_ty, inst(load_i).ord1 != 0, pred_bb, NONE,
                                                                 JT_DEF_MAX_INSTS_TO_SCAN, aaq, *is_load_cse, *num_scaned);
        single_pred_bb := pred_bb;
        while pred_available == NONE && single_pred_bb != NONE && it_pos == block_first(single_pred_bb) && num_scaned < JT_DEF_MAX_INSTS_TO_SCAN {
            single_pred_bb = block_single_predecessor(single_pred_bb);
            if single_pred_bb != NONE {
                pred_available, it_pos = find_available_ptr_load_store(loc, access_ty, inst(load_i).ord1 != 0, single_pred_bb, NONE,
                                                                       JT_DEF_MAX_INSTS_TO_SCAN - num_scaned, aaq, *is_load_cse, *num_scaned);
            }
        }
        if pred_available == NONE { one_unavailable_pred = pred_bb; continue; }
        if is_load_cse array_add(*cse_loads, pred_available);
        array_add(*available_preds, .[pred_bb, pred_available]);
    }
    if available_preds.count == 0 return false;
    unavailable_pred: Value_Id = NONE;
    guaranteed_known := false; guaranteed := false;
    can_speculate_into :: (load_i: Value_Id, pred: Value_Id, load_bb: Value_Id, known: *bool, g: *bool) -> bool {
        if jt_is_safe_to_speculatively_execute_load(load_i, block_terminator(pred)) return true;
        if !known.* {
            known.* = true;
            g.* = is_guaranteed_to_transfer_execution_range(block_first(load_bb), load_i, 0xFFFF_FFFF);
        }
        return g.*;
    }
    if preds_scanned.count == available_preds.count + 1 && num_successors(block_terminator(one_unavailable_pred)) == 1 {
        unavailable_pred = one_unavailable_pred;
        if !can_speculate_into(load_i, unavailable_pred, load_bb, *guaranteed_known, *guaranteed) return false;
    } else if preds_scanned.count != available_preds.count {
        preds_to_split: [..] Value_Id; preds_to_split.allocator = temp;
        avail_set: [..] Value_Id; avail_set.allocator = temp;
        for available_preds array_add(*avail_set, it[0]);
        for p: jt_preds(load_bb) {
            if inst_op(block_terminator(p)) == .INDIRECTBR return false;
            if !block_set_contains(avail_set, p) {
                if !can_speculate_into(load_i, p, load_bb, *guaranteed_known, *guaranteed) return false;
                array_add(*preds_to_split, p);
            }
        }
        unavailable_pred = jt_split_block_preds(j, load_bb, preds_to_split, "thread-pre-split");
    }
    if unavailable_pred != NONE {
        nv := new_inst(.LOAD, vtype(load_i), 1);
        set_op(nv, 0, do_phi_translation(loaded_ptr, load_bb, unavailable_pred));
        inst(nv).align = inst(load_i).align;
        inst(nv).ord1 = inst(load_i).ord1;
        inst(nv).sync = inst(load_i).sync;
        insert_at_position(nv, unavailable_pred, block_terminator(unavailable_pred), false);
        set_name(nv, tprint("%.pr", vname(load_i)));
        set_metadata(nv, 0, get_metadata(load_i, 0));
        if !aa_tags_empty(aa_tags) set_aa_metadata(nv, aa_tags);
        array_add(*available_preds, .[unavailable_pred, nv]);
    }
    // array_pod_sort by (block pointer, value pointer): pointer order is allocation order, which for blocks is
    // creation order; the sorted order is only used for lookup, so any consistent order works.
    pn := create_phi(vtype(load_i), cast(u32) jt_preds(load_bb).count);
    insert_at_position(pn, load_bb, block_first(load_bb), true);
    take_name(pn, load_i);
    set_metadata(pn, 0, get_metadata(load_i, 0));
    for p: jt_preds(load_bb) {
        idx := -1;
        for available_preds if it[0] == p { idx = it_index; break; }
        assert(idx >= 0, "Didn't find entry for predecessor!");
        pred_v := available_preds[idx][1];
        if vtype(pred_v) != vtype(load_i) {
            c := create_cast(bit_or_pointer_cast_opcode(vtype(pred_v), vtype(load_i)), pred_v, vtype(load_i));
            insert_at_position(c, p, block_terminator(p), false);
            if num_successors(block_terminator(p)) == 1 set_metadata(c, 0, get_metadata(load_i, 0));
            else set_metadata(c, 0, NONE);   // DebugLoc::getDropped()
            pred_v = c;
            available_preds[idx][1] = c;
        }
        phi_add_incoming(pn, pred_v, p);
    }
    for cse_loads {
        combine_metadata_for_cse(it, load_i, true);
        lvi_forget_value(j.lvi, it);
    }
    rauw_with_metadata(load_i, pn);
    erase_inst_with_metadata(load_i);
    return true;
}

// isSafeToSpeculativelyExecute(LoadI, CtxI) for a load
jt_is_safe_to_speculatively_execute_load :: (load_i: Value_Id, ctx: Value_Id) -> bool {
    if must_suppress_speculation(load_i) return false;
    q: Simplify_Query; q.cxt = ctx;
    return is_dereferenceable_and_aligned_pointer_ty(op(load_i, 0), vtype(load_i), inst(load_i).align, q);
}

// CastInst::getCastOpcode for CreateBitOrPointerCast
bit_or_pointer_cast_opcode :: (src: Type_Id, dst: Type_Id) -> Opcode {
    if is_ptr_type(src) && is_int_type(dst) return .PTRTOINT;
    if is_int_type(src) && is_ptr_type(dst) return .INTTOPTR;
    return .BITCAST;
}

// findMostPopularDest
jt_find_most_popular_dest :: (bb: Value_Id, list: [] [2] Value_Id) -> Value_Id {
    // MapVector: nullptr first, then the successors in order
    keys: [..] Value_Id; keys.allocator = temp;
    counts: [..] u32; counts.allocator = temp;
    add_key :: (keys: *[..] Value_Id, counts: *[..] u32, k: Value_Id) -> s64 {
        for keys.* if it == k return it_index;
        array_add(keys, k); array_add(counts, 0);
        return keys.count - 1;
    }
    add_key(*keys, *counts, NONE);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for succs add_key(*keys, *counts, it);
    for list if it[1] != NONE { k := add_key(*keys, *counts, it[1]); counts[k] += 1; }
    best := 0;
    for k: 1..keys.count - 1 if counts[k] > counts[best] best = k;
    return keys[best];
}

// evaluateOnPredecessorEdge
jt_evaluate_on_predecessor_edge :: (j: *Jt, bb: Value_Id, pred_pred_bb: Value_Id, v: Value_Id, visited: *[..] Value_Id) -> Value_Id {
    if block_set_contains(visited.*, v) return NONE;
    array_add(visited, v);
    defer { for visited.* if it == v { array_unordered_remove_by_index(visited, it_index); break; } }
    pred_bb := block_single_predecessor(bb);
    assert(pred_bb != NONE, "Expected a single predecessor");
    if is_constant_kind(vkind(v)) return v;
    if !is_inst(v) || (inst_block(v) != bb && inst_block(v) != pred_bb) return lvi_get_constant_on_edge(j.lvi, v, pred_pred_bb, pred_bb, NONE);
    if is_phi(v) {
        if inst_block(v) == pred_bb {
            x := phi_incoming_value_for_block(v, pred_pred_bb);
            if x != NONE && is_constant_kind(vkind(x)) return x;
        }
        return NONE;
    }
    if inst_op(v) == .ICMP || inst_op(v) == .FCMP {
        if inst_block(v) == bb {
            op0 := jt_evaluate_on_predecessor_edge(j, bb, pred_pred_bb, op(v, 0), visited);
            op1 := jt_evaluate_on_predecessor_edge(j, bb, pred_pred_bb, op(v, 1), visited);
            if op0 != NONE && op1 != NONE return cfo_compare_inst_operands(inst_pred(v), op0, op1);
        }
        return NONE;
    }
    return NONE;
}

// processThreadableEdges
jt_process_threadable_edges :: (j: *Jt, cond: Value_Id, bb: Value_Id, pref: Jt_Pref, cxt: Value_Id) -> bool {
    if table_contains(*j.loop_headers, bb) return false;
    pred_values: [..] Jt_Pred_Value; pred_values.allocator = temp;
    if !jt_compute_value_known_in_predecessors(j, cond, bb, *pred_values, pref, cxt)
        return jt_maybe_thread_through_two_basic_blocks(j, bb, cond);
    seen_preds: [..] Value_Id; seen_preds.allocator = temp;
    pred_to_dest: [..] [2] Value_Id; pred_to_dest.allocator = temp;
    MULTIPLE :: 0xFFFF_FFFE;
    only_dest: Value_Id = NONE;
    only_val: Value_Id = NONE;
    term := block_terminator(bb);
    for pv: pred_values {
        pred := pv.bb;
        if block_set_contains(seen_preds, pred) continue;
        array_add(*seen_preds, pred);
        val := pv.c;
        dest_bb: Value_Id;
        if jt_is_undef(val) dest_bb = NONE;
        else if inst_op(term) == .CONDBR dest_bb = get_successor(term, ifx ap_is_zero(const_ap(val)) then cast(u32) 1 else 0);
        else if inst_op(term) == .SWITCH {
            k := sw_find_case_value(term, val);
            dest_bb = ifx k < 0 then sw_default(term) else sw_case_dest(term, cast(u32) k);
        } else {
            assert(vkind(val) == .C_BLOCKADDR, "Expecting a constant blockaddress");
            dest_bb = op(val, 1);
        }
        if pred_to_dest.count == 0 { only_dest = dest_bb; only_val = val; }
        else {
            if only_dest != dest_bb only_dest = MULTIPLE;
            if val != only_val only_val = MULTIPLE;
        }
        if inst_op(block_terminator(pred)) == .INDIRECTBR continue;
        array_add(*pred_to_dest, .[pred, dest_bb]);
    }
    if pred_to_dest.count == 0 return false;
    if only_dest != NONE && only_dest != MULTIPLE {
        if jt_has_n_predecessors(bb, pred_to_dest.count) {
            seen_first := false;
            updates: [..] Dom_Update; updates.allocator = temp;
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            for succ: succs {
                if succ == only_dest && !seen_first seen_first = true;
                else {
                    block_remove_predecessor(succ, bb, true);
                    array_add(*updates, .{false, bb, succ});
                }
            }
            t := block_terminator(bb);
            jt_br_before(only_dest, t);
            jt_erase_terminator(t);
            dtu_apply_permissive(*j.dtu, updates);
            bpi := jt_get_bpi(j); if bpi bpi_erase_block(bpi, bb);
            if is_inst(cond) {
                if !has_uses(cond) && !may_have_side_effects(cond) erase_inst_with_metadata(cond);
                else if only_val != NONE && only_val != MULTIPLE jt_replace_foldable_uses(cond, only_val, bb);
            }
            return true;
        }
    }
    most_popular := only_dest;
    if most_popular == MULTIPLE {
        k := 0;
        for pred_to_dest if !table_contains(*j.loop_headers, it[1]) { pred_to_dest[k] = it; k += 1; }
        pred_to_dest.count = k;
        if pred_to_dest.count == 0 return false;
        most_popular = jt_find_most_popular_dest(bb, pred_to_dest);
    }
    preds_to_factor: [..] Value_Id; preds_to_factor.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for pred_to_dest if it[1] == most_popular {
        block_successors(it[0], *succs);
        for s: succs if s == bb array_add(*preds_to_factor, it[0]);
    }
    if most_popular == NONE most_popular = get_successor(block_terminator(bb), jt_get_best_dest_for_jump_on_undef(bb));
    return jt_try_thread_edge(j, bb, preds_to_factor, most_popular);
}

// processBranchOnPHI
jt_process_branch_on_phi :: (j: *Jt, pn: Value_Id) -> bool {
    bb := inst_block(pn);
    n := phi_num_incoming(pn);
    for k: 0..cast(s64) n - 1 {
        pred_bb := phi_block(pn, cast(u32) k);
        if inst_op(block_terminator(pred_bb)) == .BR {
            preds := Value_Id.[pred_bb];
            if jt_duplicate_cond_branch_on_phi_into_pred(j, bb, preds) return true;
        }
    }
    return false;
}

// processBranchOnXOR
jt_process_branch_on_xor :: (j: *Jt, bo: Value_Id) -> bool {
    bb := inst_block(bo);
    if vkind(op(bo, 0)) == .C_INT || vkind(op(bo, 1)) == .C_INT return false;
    if !is_phi(block_first(bb)) return false;
    if block_is_eh_pad(bb) return false;
    xor_vals: [..] Jt_Pred_Value; xor_vals.allocator = temp;
    is_lhs := true;
    if !jt_compute_value_known_in_predecessors(j, op(bo, 0), bb, *xor_vals, .WANT_INTEGER, bo) {
        if !jt_compute_value_known_in_predecessors(j, op(bo, 1), bb, *xor_vals, .WANT_INTEGER, bo) return false;
        is_lhs = false;
    }
    num_true, num_false := 0, 0;
    for xor_vals {
        if jt_is_undef(it.c) continue;
        if ap_is_zero(const_ap(it.c)) num_false += 1; else num_true += 1;
    }
    split_val: Value_Id = NONE;
    if num_true > num_false split_val = const_int(ir.t_i1, 1);
    else if num_true != 0 || num_false != 0 split_val = const_int(ir.t_i1, 0);
    blocks_to_fold: [..] Value_Id; blocks_to_fold.allocator = temp;
    for xor_vals {
        if it.c != split_val && !jt_is_undef(it.c) continue;
        array_add(*blocks_to_fold, it.bb);
    }
    if blocks_to_fold.count == cast(s64) phi_num_incoming(block_first(bb)) {
        if split_val == NONE {
            rauw_with_metadata(bo, const_undef(vtype(bo)));
            erase_inst_with_metadata(bo);
        } else if ap_is_zero(const_ap(split_val)) && bo != op(bo, ifx is_lhs then cast(u32) 1 else 0) {
            rauw_with_metadata(bo, op(bo, ifx is_lhs then cast(u32) 1 else 0));
            erase_inst_with_metadata(bo);
        } else {
            set_op(bo, ifx is_lhs then cast(u32) 0 else 1, split_val);
        }
        return true;
    }
    for blocks_to_fold if inst_op(block_terminator(it)) == .INDIRECTBR return false;
    return jt_duplicate_cond_branch_on_phi_into_pred(j, bb, blocks_to_fold);
}

// addPHINodeEntriesForMappedBlock
jt_add_phi_node_entries_for_mapped_block :: (phi_bb: Value_Id, old_pred: Value_Id, new_pred: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    for pn: block_insts(phi_bb) {
        if inst_op(pn) != .PHI break;
        iv := phi_incoming_value_for_block(pn, old_pred);
        if is_inst(iv) {
            found, m := table_find(vm, iv);
            if found iv = m;
        }
        phi_add_incoming(pn, iv, new_pred);
    }
}

// maybeMergeBasicBlockIntoOnlyPred
jt_maybe_merge_basic_block_into_only_pred :: (j: *Jt, bb: Value_Id) -> bool {
    single_pred := block_single_predecessor(bb);
    if single_pred == NONE return false;
    ti := block_terminator(single_pred);
    if jt_is_special_terminator(ti) || num_successors(ti) != 1 || single_pred == bb || jt_has_address_taken_and_used(bb) return false;
    if table_contains(*j.unreachable, single_pred) return false;
    if has_loop_or_entry_convergence_token(bb) && has_loop_or_entry_convergence_token(single_pred) return false;
    if table_remove(*j.loop_headers, single_pred) table_set(*j.loop_headers, bb, true);
    lvi_erase_block(j.lvi, single_pred);
    merge_basic_block_into_only_pred(bb, *j.dtu);
    if !is_guaranteed_to_transfer_execution_block(bb) lvi_erase_block(j.lvi, bb);
    return true;
}

// Instruction::isSpecialTerminator: invoke, callbr, catchswitch, cleanupret, catchret
jt_is_special_terminator :: (t: Value_Id) -> bool {
    o := inst_op(t);
    return o == .INVOKE || o == .CALLBR || o == .CATCHSWITCH || o == .CLEANUPRET || o == .CATCHRET;
}

// MergeBasicBlockIntoOnlyPred(DestBB, DTU)
merge_basic_block_into_only_pred :: (dest_bb: Value_Id, dtu: *Dtu) {
    while true {
        pn := block_first(dest_bb);
        if pn == NONE || inst_op(pn) != .PHI break;
        nv := phi_value(pn, 0);
        if nv == pn nv = const_poison(vtype(pn));
        rauw_with_metadata(pn, nv);
        erase_inst_with_metadata(pn);
    }
    pred_bb := block_single_predecessor(dest_bb);
    assert(pred_bb != NONE, "Block doesn't have a single predecessor!");
    f := block_fn(dest_bb);
    replace_entry_bb := pred_bb == fn_entry(f);
    updates: [..] Dom_Update; updates.allocator = temp;
    if dtu {
        seen: [..] Value_Id; seen.allocator = temp;
        pp := jt_preds(pred_bb);
        for p: pp if p != pred_bb && !block_set_contains(seen, p) { array_add(*seen, p); array_add(*updates, .{true, p, dest_bb}); }
        seen.count = 0;
        for p: pp if !block_set_contains(seen, p) { array_add(*seen, p); array_add(*updates, .{false, p, pred_bb}); }
        array_add(*updates, .{false, pred_bb, dest_bb});
    }
    if block_has_address_taken(dest_bb) {
        ba := const_blockaddr(f, dest_bb);
        repl := ce_cast(.INTTOPTR, const_int(type_int(32), 1), vtype(ba));
        replace_all_uses_with(ba, repl);
        destroy_constant(ba);
    }
    replace_all_uses_with(pred_bb, dest_bb);
    block_replace_successors_phi_uses_with(pred_bb, pred_bb, dest_bb);
    // PredBB->getTerminator()->eraseFromParent(): its records become trailing records of PredBB
    t := block_terminator(pred_bb);
    trailing := records_take(t);
    erase_inst_with_metadata(t);
    // DestBB->splice(DestBB->begin(), PredBB): Dest has the head bit, First = begin(), Last = end()
    dest := block_first(dest_bb);
    dest_recs := records_take(dest);
    while block_first(pred_bb) != NONE {
        i := block_first(pred_bb);
        inst_unlink(i);
        inst_insert_before(i, dest);
    }
    attach_records_before(dest, trailing);
    attach_records_before(dest, dest_recs);
    block_append_inst(pred_bb, new_inst(.UNREACHABLE, ir.t_void, 0));
    if replace_entry_bb jt_move_block_after(dest_bb, pred_bb);
    if dtu {
        dtu_apply_permissive(dtu, updates);
        dtu_delete_bb(dtu, pred_bb);
        if replace_entry_bb && dtu.dt dtu_recalculate(dtu, f);
    } else {
        block_erase_from_parent(pred_bb);
    }
}

// updateSSA
jt_update_ssa :: (bb: Value_Id, new_bb: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    ssa: Ssa_Updater;
    uses_to_rename: [..] Use_Id; uses_to_rename.allocator = temp;
    dvrs: [..] u32; dvrs.allocator = temp;
    for i: block_insts(bb) {
        lifetime_markers: [..] Value_Id; lifetime_markers.allocator = temp;
        u := ir.v_first_use[i];
        while u != NONE {
            user := ir.u_user[u];
            if is_lifetime_start_or_end(user) {
                array_add(*lifetime_markers, user);
            } else {
                if inst_op(user) == .PHI { if ir.u_aux[u] == bb { u = ir.u_next[u]; continue; } }
                else if inst_block(user) == bb { u = ir.u_next[u]; continue; }
            }
            array_add(*uses_to_rename, u);
            u = ir.u_next[u];
        }
        find_dbg_users(block_fn(bb), i, *dvrs, true);
        k := 0;
        for dvrs if inst_block(dbgr(it).owner) != bb { dvrs[k] = it; k += 1; }
        dvrs.count = k;
        if uses_to_rename.count == 0 && dvrs.count == 0 continue;
        ssa_init(*ssa, vtype(i), vname(i));
        ssa_add_available(*ssa, bb, i);
        found, mapped := table_find(vm, i);
        ssa_add_available(*ssa, new_bb, mapped);
        while uses_to_rename.count ssa_rewrite_use(*ssa, pop(*uses_to_rename));
        if dvrs.count {
            for r: dvrs {
                user_bb := inst_block(dbgr(r).owner);
                if ssa_has_value(*ssa, user_bb) dbgr_replace_variable_location_op(r, i, ssa_value_at_end(*ssa, user_bb));
                else dbgr_set_kill_location(r);
            }
            dvrs.count = 0;
        }
        has_phi_arg := false;
        for lifetime_markers if is_phi(op(it, 0)) has_phi_arg = true;
        if has_phi_arg for lifetime_markers erase_inst_with_metadata(it);
    }
}

// identifyNoAliasScopesToClone(Start, End) + cloneNoAliasScopes(..., "thread") (CloneFunction.cpp): the map from
// each scope of the noalias.scope.decl calls in [first, last) to a fresh anonymous scope in the same domain
Scope_Map :: struct { from: [..] Md_Id; to: [..] Md_Id; }
jt_clone_no_alias_scopes :: (first: Value_Id, last: Value_Id, ext: string) -> Scope_Map {
    m: Scope_Map; m.from.allocator = temp; m.to.allocator = temp;
    i := first;
    while i != last && i != NONE {
        if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL {
            scope_list := ir.v_aux[call_arg(i, 0)];
            for k: 0..cast(s64) md_nops(scope_list) - 1 {
                md := md_op(scope_list, cast(u32) k);
                if !md_is_node(md) continue;
                // AliasScopeNode: getName = operand 2 (MDString), getDomain = operand 1
                name := ext;
                if md_nops(md) > 2 {
                    nm := md_op(md, 2);
                    if nm != NONE && ir.mds[nm].kind == .STRING && ir.mds[nm].str.count name = tprint("%:%", ir.mds[nm].str, ext);
                }
                domain := ifx md_nops(md) > 1 then md_op(md, 1) else NONE;
                // MDBuilder::createAnonymousAliasScope(Domain, Name) = createAnonymousAARoot(Name, Domain)
                ops: [..] Md_Id; ops.allocator = temp;
                array_add(*ops, NONE);
                if domain != NONE array_add(*ops, domain);
                if name.count array_add(*ops, md_string(name));
                root := md_tuple(ops, true);
                ir.md_ops[ir.mds[root].ops] = root;
                found := false;
                for m.from if it == md { found = true; break; }
                if !found { array_add(*m.from, md); array_add(*m.to, root); }
            }
        }
        i = inst_next(i);
    }
    return m;
}
// adaptNoAliasScopes(I, ClonedScopes, Context)
jt_adapt_no_alias_scopes :: (i: Value_Id, m: *Scope_Map) {
    if m.from.count == 0 return;
    clone_scope_list :: (sl: Md_Id, m: *Scope_Map) -> Md_Id {
        needs := false;
        ops: [..] Md_Id; ops.allocator = temp;
        for k: 0..cast(s64) md_nops(sl) - 1 {
            md := md_op(sl, cast(u32) k);
            if !md_is_node(md) continue;
            rep: Md_Id = NONE;
            for m.from if it == md { rep = m.to[it_index]; break; }
            if rep != NONE { array_add(*ops, rep); needs = true; continue; }
            array_add(*ops, md);
        }
        if needs return md_tuple(ops, false);
        return NONE;
    }
    if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL {
        nsl := clone_scope_list(ir.v_aux[call_arg(i, 0)], m);
        if nsl != NONE {
            k := const_key_begin(.MD_VALUE, ir.t_metadata); key_u32(k, nsl);
            set_op(i, 0, const_lookup_or_create(k, .MD_VALUE, ir.t_metadata, .[], nsl));
        }
    }
    for kind: string.["noalias", "alias.scope"] {
        id := md_kind_id(kind);
        cs := get_metadata(i, id);
        if cs != NONE {
            nsl := clone_scope_list(cs, m);
            if nsl != NONE set_metadata(i, id, nsl);
        }
    }
}
// mapAtomInstance: key-instruction atom groups are not ported
jt_check_atom :: (i: Value_Id) {
    dl := get_metadata(i, 0);
    if dl != NONE && di_int(dl, 3) != 0 fatal("jump-threading: key-instruction atom groups (mapAtomInstance) are not implemented yet");
}

// cloneInstructions(ValueMapping, BI, BE, NewBB, PredBB): BE = NONE is end()
jt_clone_instructions :: (vm: *Table(Value_Id, Value_Id), bi_in: Value_Id, be: Value_Id, new_bb: Value_Id, pred_bb: Value_Id) {
    bi := bi_in;
    range_bb := inst_block(bi);
    retarget :: (r: u32, vm: *Table(Value_Id, Value_Id)) {
        if dbgr(r).kind == .LABEL return;
        ops: [..] Value_Id; ops.allocator = temp;
        dbgr_location_ops(r, *ops);
        remap: [..] [2] Value_Id; remap.allocator = temp;
        for o: ops {
            if !is_inst(o) continue;
            found, m := table_find(vm, o);
            if !found continue;
            dup := false;
            for remap if it[0] == o && it[1] == m dup = true;
            if !dup array_add(*remap, .[o, m]);
        }
        for remap dbgr_replace_variable_location_op(r, it[0], it[1]);
    }
    while bi != NONE && is_phi(bi) {
        new_pn := create_phi(vtype(bi), 1);
        block_append_inst(new_bb, new_pn);
        if vname(bi).count set_name(new_pn, vname(bi));
        phi_add_incoming(new_pn, phi_incoming_value_for_block(bi, pred_bb), pred_bb);
        table_set(vm, bi, new_pn);
        jt_check_atom(bi);
        bi = inst_next(bi);
    }
    scopes := jt_clone_no_alias_scopes(bi, be, "thread");
    recs: [..] u32; recs.allocator = temp;
    while bi != be {
        nw := inst_clone(bi);
        block_append_inst(new_bb, nw);
        if vname(bi).count set_name(nw, vname(bi));
        table_set(vm, bi, nw);
        jt_adapt_no_alias_scopes(nw, *scopes);
        if inst(bi).records {
            clone_debug_info_from(nw, bi, inst(bi).records, *recs);
            for recs retarget(it, vm);
        }
        jt_check_atom(nw);
        n := nops(nw);
        for k: 0..cast(s64) n - 1 {
            o := op(nw, cast(u32) k);
            if o != NONE && is_inst(o) {
                found, m := table_find(vm, o);
                if found set_op(nw, cast(u32) k, m);
            }
        }
        bi = inst_next(bi);
    }
    if be != NONE && inst(be).records {
        // the records on the terminator go to the end of NewBB (a trailing marker until the branch is appended)
        jt_pending_trailing_records.count = 0;
        x := inst(be).records;
        while x != 0 {
            nx := dbgr(x).next;
            nr := dbgr(x).*;
            nr.next = 0; nr.owner = NONE;
            array_add(*ir.dbg_records, nr);
            id := cast(u32) ir.dbg_records.count;
            dbgr_restamp(id);
            array_add(*jt_pending_trailing_records, id);
            x = nx;
        }
    }
}
// Records cloned from the source terminator by jt_clone_instructions; the caller attaches them to the new
// terminator it appends to NewBB (they are NewBB's trailing records until then).
jt_pending_trailing_records: [..] u32;
jt_attach_pending_trailing_records :: (to: Value_Id, vm: *Table(Value_Id, Value_Id)) {
    for jt_pending_trailing_records {
        attach_records_before(to, it);
        if dbg_index.fn != NONE dbgr_index_record(it);
    }
    for jt_pending_trailing_records {
        if dbgr(it).kind == .LABEL continue;
        ops: [..] Value_Id; ops.allocator = temp;
        dbgr_location_ops(it, *ops);
        for o: ops {
            if !is_inst(o) continue;
            found, m := table_find(vm, o);
            if found dbgr_replace_variable_location_op(it, o, m);
        }
    }
    jt_pending_trailing_records.count = 0;
}

// maybethreadThroughTwoBasicBlocks
jt_maybe_thread_through_two_basic_blocks :: (j: *Jt, bb: Value_Id, cond: Value_Id) -> bool {
    cond_br := block_terminator(bb);
    if inst_op(cond_br) != .CONDBR return false;
    pred_bb := block_single_predecessor(bb);
    if pred_bb == NONE return false;
    pred_br := block_terminator(pred_bb);
    if inst_op(pred_br) != .CONDBR return false;
    if block_single_predecessor(pred_bb) != NONE return false;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(pred_bb, *succs);
    if block_set_contains(succs, pred_bb) return false;
    if table_contains(*j.loop_headers, pred_bb) return false;
    if block_is_eh_pad(pred_bb) return false;
    zero_count, one_count := 0, 0;
    zero_pred, one_pred: Value_Id = NONE, NONE;
    for p: jt_preds(pred_bb) {
        if inst_op(block_terminator(p)) == .INDIRECTBR continue;
        visited: [..] Value_Id; visited.allocator = temp;
        ci := jt_evaluate_on_predecessor_edge(j, bb, p, cond, *visited);
        if ci != NONE && vkind(ci) == .C_INT {
            if ap_is_zero(const_ap(ci)) { zero_count += 1; zero_pred = p; }
            else if ap_is_one(const_ap(ci)) { one_count += 1; one_pred = p; }
        }
    }
    pred_pred_bb: Value_Id;
    if zero_count == 1 pred_pred_bb = zero_pred;
    else if one_count == 1 pred_pred_bb = one_pred;
    else return false;
    succ_bb := get_successor(cond_br, ifx pred_pred_bb == zero_pred then cast(u32) 1 else 0);
    if succ_bb == bb return false;
    if table_contains(*j.loop_headers, bb) || table_contains(*j.loop_headers, succ_bb) return false;
    bb_cost := jt_duplication_cost(j, bb, block_terminator(bb), j.bb_dup_threshold);
    pred_bb_cost := jt_duplication_cost(j, pred_bb, block_terminator(pred_bb), j.bb_dup_threshold);
    if bb_cost > j.bb_dup_threshold || pred_bb_cost > j.bb_dup_threshold || cast(u64) bb_cost + pred_bb_cost > j.bb_dup_threshold return false;
    jt_thread_through_two_basic_blocks(j, pred_pred_bb, pred_bb, bb, succ_bb);
    return true;
}

// doesBlockHaveProfileData
jt_does_block_have_profile_data :: (bb: Value_Id) -> bool {
    t := block_terminator(bb);
    if t == NONE || num_successors(t) < 2 return false;
    return prof_valid_branch_weight_md(t) != NONE;
}
// getBPI / getBFI: the pass's own or the cached results
jt_get_bpi :: (j: *Jt) -> *Bpi { if !j.bpi j.bpi = cached_bpi(j.f); return j.bpi; }
jt_get_bfi :: (j: *Jt) -> *Bfi { if !j.bfi j.bfi = cached_bfi(j.f); return j.bfi; }
// runExternalAnalysis<AnalysisT>: invalidate what the pass does not keep up to date, flush the DomTreeUpdater, then
// compute the analysis (and re-fetch AA, TTI, TLI)
jt_run_external_analysis :: (j: *Jt, want_bfi: bool) {
    if j.changed_since_last_analysis_update {
        j.changed_since_last_analysis_update = false;
        pa: Preserved;
        preserve(*pa, .LVI); preserve(*pa, .DOMTREE); preserve(*pa, .BPI); preserve(*pa, .BFI);
        preserve(*pa, .ASSUMPTIONS);   // AssumptionCache::invalidate never invalidates
        fam_invalidate(j.f, pa);
        dtu_flush(*j.dtu);
    }
    if want_bfi j.bfi = get_bfi(j.f); else j.bpi = get_bpi(j.f);
    j.aar = aa_results_for(j.f);
}
// getOrCreateBPI(Force) / getOrCreateBFI(Force)
jt_get_or_create_bpi :: (j: *Jt, force: bool) -> *Bpi {
    r := jt_get_bpi(j);
    if r return r;
    if force jt_run_external_analysis(j, false);
    return j.bpi;
}
jt_get_or_create_bfi :: (j: *Jt, force: bool) -> *Bfi {
    r := jt_get_bfi(j);
    if r return r;
    if force jt_run_external_analysis(j, true);
    return j.bfi;
}

// updateBlockFreqAndEdgeWeight
jt_update_block_freq_and_edge_weight :: (j: *Jt, pred_bb: Value_Id, bb: Value_Id, new_bb: Value_Id, succ_bb: Value_Id, bfi: *Bfi, bpi: *Bpi, has_profile: bool) {
    if !bfi return;
    bb_orig_freq := bfi_get_block_freq(bfi, bb);
    new_bb_freq := bfi_get_block_freq(bfi, new_bb);
    bfi_set_block_freq(bfi, bb, bf_sub(bb_orig_freq, new_bb_freq));
    succ_freq: [..] u64; succ_freq.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs {
        bb2succ := bf_mul_prob(bb_orig_freq, bpi_edge_probability_idx(bpi, bb, cast(u32) it_index));
        f := ifx s == succ_bb then bf_sub(bb2succ, new_bb_freq) else bb2succ;
        array_add(*succ_freq, f);
    }
    mx: u64 = 0;
    for succ_freq if it > mx mx = it;
    probs: [..] u32; probs.allocator = temp;
    if mx == 0 {
        for succ_freq array_add(*probs, bp_make(1, cast(u64) succ_freq.count));
    } else {
        for succ_freq array_add(*probs, bp_get(it, mx));
        bp_normalize(probs);
    }
    bpi_set_edge_probability(bpi, bb, probs);
    if probs.count >= 2 && has_profile {
        t := block_terminator(bb);
        prof_set_branch_weights(t, probs, prof_has_branch_weight_origin(prof_md(t)));
    }
}

// threadThroughTwoBasicBlocks
jt_thread_through_two_basic_blocks :: (j: *Jt, pred_pred_bb: Value_Id, pred_bb: Value_Id, bb: Value_Id, succ_bb: Value_Id) {
    has_profile := jt_does_block_have_profile_data(bb);
    bfi := jt_get_or_create_bfi(j, has_profile);
    bpi := jt_get_or_create_bpi(j, bfi != null);
    cond_br := block_terminator(bb);
    pred_bb_branch := block_terminator(pred_bb);
    f := block_fn(pred_bb);
    new_bb := create_block(f, tprint("%.thread", vname(pred_bb)), pred_bb);
    jt_move_block_after(new_bb, pred_bb);
    if bfi bfi_set_block_freq(bfi, new_bb, bf_mul_prob(bfi_get_block_freq(bfi, pred_pred_bb), bpi_edge_probability(bpi, pred_pred_bb, pred_bb)));
    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    jt_clone_instructions(*vm, block_first(pred_bb), NONE, new_bb, pred_pred_bb);
    if bpi bpi_copy_edge_probabilities(bpi, pred_bb, new_bb);
    pred_pred_term := block_terminator(pred_pred_bb);
    n := num_successors(pred_pred_term);
    for k: 0..cast(s64) n - 1 if get_successor(pred_pred_term, cast(u32) k) == pred_bb {
        block_remove_predecessor(pred_bb, pred_pred_bb, true);
        set_successor(pred_pred_term, cast(u32) k, new_bb);
    }
    jt_add_phi_node_entries_for_mapped_block(get_successor(pred_bb_branch, 0), pred_bb, new_bb, *vm);
    jt_add_phi_node_entries_for_mapped_block(get_successor(pred_bb_branch, 1), pred_bb, new_bb, *vm);
    ups := Dom_Update.[.{true, new_bb, get_successor(cond_br, 0)}, .{true, new_bb, get_successor(cond_br, 1)},
                       .{true, pred_pred_bb, new_bb}, .{false, pred_pred_bb, pred_bb}];
    dtu_apply_permissive(*j.dtu, ups);
    jt_update_ssa(pred_bb, new_bb, *vm);
    simplify_instructions_in_block(new_bb);
    simplify_instructions_in_block(pred_bb);
    preds := Value_Id.[new_bb];
    jt_thread_edge(j, bb, preds, succ_bb);
}

// tryThreadEdge
jt_try_thread_edge :: (j: *Jt, bb: Value_Id, pred_bbs: [] Value_Id, succ_bb: Value_Id) -> bool {
    if succ_bb == bb return false;
    if table_contains(*j.loop_headers, bb) || table_contains(*j.loop_headers, succ_bb) return false;
    cost := jt_duplication_cost(j, bb, block_terminator(bb), j.bb_dup_threshold);
    if cost > j.bb_dup_threshold return false;
    jt_thread_edge(j, bb, pred_bbs, succ_bb);
    return true;
}

// threadEdge
jt_thread_edge :: (j: *Jt, bb: Value_Id, pred_bbs: [] Value_Id, succ_bb: Value_Id) {
    has_profile := jt_does_block_have_profile_data(bb);
    bfi := jt_get_or_create_bfi(j, has_profile);
    bpi := jt_get_or_create_bpi(j, bfi != null);
    pred_bb: Value_Id;
    if pred_bbs.count == 1 pred_bb = pred_bbs[0];
    else pred_bb = jt_split_block_preds(j, bb, pred_bbs, ".thr_comm");
    lvi_thread_edge(j.lvi, pred_bb, bb, succ_bb);
    f := block_fn(bb);
    new_bb := create_block(f, tprint("%.thread", vname(bb)), bb);
    jt_move_block_after(new_bb, pred_bb);
    if bfi bfi_set_block_freq(bfi, new_bb, bf_mul_prob(bfi_get_block_freq(bfi, pred_bb), bpi_edge_probability(bpi, pred_bb, bb)));
    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    jt_clone_instructions(*vm, block_first(bb), block_terminator(bb), new_bb, pred_bb);
    new_bi := create_br(succ_bb);
    block_append_inst(new_bb, new_bi);
    set_metadata(new_bi, 0, get_metadata(block_terminator(bb), 0));
    jt_attach_pending_trailing_records(new_bi, *vm);
    jt_add_phi_node_entries_for_mapped_block(succ_bb, bb, new_bb, *vm);
    pred_term := block_terminator(pred_bb);
    n := num_successors(pred_term);
    for k: 0..cast(s64) n - 1 if get_successor(pred_term, cast(u32) k) == bb {
        block_remove_predecessor(bb, pred_bb, true);
        set_successor(pred_term, cast(u32) k, new_bb);
    }
    ups := Dom_Update.[.{true, new_bb, succ_bb}, .{true, pred_bb, new_bb}, .{false, pred_bb, bb}];
    dtu_apply_permissive(*j.dtu, ups);
    jt_update_ssa(bb, new_bb, *vm);
    simplify_instructions_in_block(new_bb);
    jt_update_block_freq_and_edge_weight(j, pred_bb, bb, new_bb, succ_bb, bfi, bpi, has_profile);
}

// splitBlockPreds
jt_split_block_preds :: (j: *Jt, bb: Value_Id, preds: [] Value_Id, suffix: string) -> Value_Id {
    new_bbs: [..] Value_Id; new_bbs.allocator = temp;
    freq_map: Table(Value_Id, u64); freq_map.allocator = temp;
    bfi := jt_get_bfi(j);
    if bfi {
        bpi := jt_get_or_create_bpi(j, true);
        for p: preds if !table_contains(*freq_map, p) table_set(*freq_map, p, bf_mul_prob(bfi_get_block_freq(bfi, p), bpi_edge_probability(bpi, p, bb)));
    }
    if block_is_landing_pad(bb) {
        split_landing_pad_predecessors(bb, preds, suffix, tprint("%.split-lp", suffix), *new_bbs, null, null, null, false);
    } else {
        array_add(*new_bbs, split_block_predecessors(bb, preds, suffix, null, null));
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    for nb: new_bbs {
        new_bb_freq: u64 = 0;
        array_add(*updates, .{true, nb, bb});
        for p: jt_preds(nb) {
            array_add(*updates, .{false, p, bb});
            array_add(*updates, .{true, p, nb});
            if bfi { _, pf := table_find(*freq_map, p); new_bb_freq = bf_add(new_bb_freq, pf); }
        }
        if bfi bfi_set_block_freq(bfi, nb, new_bb_freq);
    }
    dtu_apply_permissive(*j.dtu, updates);
    return new_bbs[0];
}

// SplitEdge(BB, Succ) without DominatorTree / LoopInfo
jt_split_edge :: (bb: Value_Id, succ: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    succ_num: u32 = 0;
    while get_successor(t, succ_num) != succ succ_num += 1;   // GetSuccessorNumber
    o: Crit_Edge_Options; o.preserve_lcssa = true;
    if is_critical_edge(t, succ_num, o.merge_identical_edges) return split_known_critical_edge(t, succ_num, *o);
    sp := block_single_predecessor(succ);
    if sp != NONE {
        assert(sp == bb, "CFG broken");
        // splitBlockBefore(Succ, &Succ->front(), &DTU (no tree), LI, MSSAU, BBName)
        fatal("jump-threading: SplitEdge through splitBlockBefore is not implemented yet");
    }
    assert(num_successors(t) == 1, "Should have a single succ!");
    return split_block(bb, t, null, null);
}

// duplicateCondBranchOnPHIIntoPred
jt_duplicate_cond_branch_on_phi_into_pred :: (j: *Jt, bb: Value_Id, pred_bbs: [] Value_Id) -> bool {
    assert(pred_bbs.count > 0, "Can't handle an empty set");
    if table_contains(*j.loop_headers, bb) return false;
    dup_cost := jt_duplication_cost(j, bb, block_terminator(bb), j.bb_dup_threshold);
    if dup_cost > j.bb_dup_threshold return false;
    updates: [..] Dom_Update; updates.allocator = temp;
    pred_bb: Value_Id;
    if pred_bbs.count == 1 pred_bb = pred_bbs[0];
    else pred_bb = jt_split_block_preds(j, bb, pred_bbs, ".thr_comm");
    array_add(*updates, .{false, pred_bb, bb});
    old_pred_branch := block_terminator(pred_bb);
    if inst_op(old_pred_branch) != .BR {
        old_pred_bb := pred_bb;
        pred_bb = jt_split_edge(old_pred_bb, bb);
        array_add(*updates, .{true, old_pred_bb, pred_bb});
        array_add(*updates, .{true, pred_bb, bb});
        array_add(*updates, .{false, old_pred_bb, bb});
        old_pred_branch = block_terminator(pred_bb);
    }
    vm: Table(Value_Id, Value_Id); vm.allocator = temp;
    bi := block_first(bb);
    while bi != NONE && is_phi(bi) {
        table_set(*vm, bi, phi_incoming_value_for_block(bi, pred_bb));
        bi = inst_next(bi);
    }
    scopes := jt_clone_no_alias_scopes(bi, NONE, "thread");
    recs: [..] u32; recs.allocator = temp;
    while bi != NONE {
        defer bi = inst_next(bi);
        nw := inst_clone(bi);
        insert_at_position(nw, pred_bb, old_pred_branch, false);
        jt_adapt_no_alias_scopes(nw, *scopes);
        n := nops(nw);
        for k: 0..cast(s64) n - 1 {
            o := op(nw, cast(u32) k);
            if o != NONE && is_inst(o) {
                found, m := table_find(*vm, o);
                if found set_op(nw, cast(u32) k, m);
            }
        }
        remap_debug_variable(*vm, nw);
        jt_check_atom(nw);
        q: Simplify_Query; q.cxt = nw;
        iv := simplify_instruction(nw, q);
        if iv != NONE {
            table_set(*vm, bi, iv);
            if !may_have_side_effects(nw) {
                // New->eraseFromParent(): records adopted from the branch fall onto it again
                erase_inst_with_metadata(nw);
                nw = NONE;
                // OldPredBranch->cloneDebugInfoFrom(&*BI, std::nullopt, /*InsertAtHead=*/true)
                if inst(bi).records jt_clone_debug_info_to_head(old_pred_branch, bi);
            }
        } else {
            table_set(*vm, bi, nw);
        }
        if nw != NONE {
            if vname(bi).count set_name(nw, vname(bi));
            if inst(bi).records clone_debug_info_from(nw, bi, inst(bi).records, *recs);
            nn := nops(nw);
            for k: 0..cast(s64) nn - 1 {
                o := op(nw, cast(u32) k);
                if o != NONE && vkind(o) == .BLOCK array_add(*updates, .{true, pred_bb, o});
            }
        }
    }
    bb_branch := block_terminator(bb);
    jt_add_phi_node_entries_for_mapped_block(get_successor(bb_branch, 0), bb, pred_bb, *vm);
    jt_add_phi_node_entries_for_mapped_block(get_successor(bb_branch, 1), bb, pred_bb, *vm);
    jt_update_ssa(bb, pred_bb, *vm);
    block_remove_predecessor(bb, pred_bb, true);
    // the cloned terminator is the last clone; the old branch's remaining records stay on it as trailing records
    // of PredBB, which the cloned terminator (inserted before it) absorbed already
    jt_erase_terminator_keep_records(old_pred_branch);
    bpi := jt_get_bpi(j); if bpi bpi_copy_edge_probabilities(bpi, bb, pred_bb);
    dtu_apply_permissive(*j.dtu, updates);
    return true;
}

// DbgMarker::cloneDebugInfoFrom(From, nullopt, InsertAtHead = true)
jt_clone_debug_info_to_head :: (to: Value_Id, from: Value_Id) {
    first: u32 = 0; last: u32 = 0;
    x := inst(from).records;
    while x != 0 {
        nr := dbgr(x).*;
        nr.next = 0; nr.owner = NONE;
        array_add(*ir.dbg_records, nr);
        id := cast(u32) ir.dbg_records.count;
        dbgr_restamp(id);
        if first == 0 first = id; else dbgr(last).next = id;
        last = id;
        x = dbgr(x).next;
    }
    if first == 0 return;
    records_prepend(to, first);
    y := first;
    while y != 0 { if dbg_index.fn != NONE dbgr_index_record(y); y = dbgr(y).next; }
}

// OldPredBranch->eraseFromParent() where it is the block's last instruction: its records become trailing records
// of the block. The duplicated terminator now precedes it; trailing records at a block end are not modelled.
jt_erase_terminator_keep_records :: (t: Value_Id) {
    if inst(t).records fatal("jump-threading: trailing debug records after duplicating a block are not supported yet");
    erase_inst_with_metadata(t);
}

// remapDebugVariable(Mapping, Inst)
remap_debug_variable :: (vm: *Table(Value_Id, Value_Id), i: Value_Id) {
    r := inst(i).records;
    while r != 0 {
        nr := dbgr(r).next;
        if dbgr(r).kind != .LABEL {
            ops: [..] Value_Id; ops.allocator = temp;
            dbgr_location_ops(r, *ops);
            for o: ops {
                found, m := table_find(vm, o);
                if found dbgr_replace_variable_location_op(r, o, m, true);
            }
        }
        if dbgr(r).kind == .ASSIGN {
            // RemapAssignAddress: DA->setAddress(Mapping[DA->getAddress()])
            a := dbgr(r).addr;
            if a != NONE && ir.mds[a].kind == .VALUE {
                found, m := table_find(vm, ir.mds[a].value);
                if found {
                    dbgr(r).addr = md_value(m);
                    if dbgr(r).owner != NONE dbgr_restamp(r);
                    if dbg_index.fn != NONE dbgr_index_record(r);
                }
            }
        }
        r = nr;
    }
}

// SimplifyInstructionsInBlock(BB, TLI); use_tli = false is a null TLI (isInstructionTriviallyDead without TLI)
simplify_instructions_in_block :: (bb: Value_Id, use_tli := true) -> bool {
    made_change := false;
    worklist: [..] Value_Id; worklist.allocator = temp;   // SmallSetVector
    in_list :: (wl: [] Value_Id, i: Value_Id) -> bool { for wl if it == i return true; return false; }
    bi := block_first(bb);
    term := block_terminator(bb);
    while bi != NONE && bi != term {
        i := bi;
        bi = inst_next(bi);
        if !in_list(worklist, i) made_change |= jt_simplify_and_dce_instruction(i, *worklist, use_tli);
    }
    while worklist.count {
        i := pop(*worklist);
        made_change |= jt_simplify_and_dce_instruction(i, *worklist, use_tli);
    }
    return made_change;
}
// simplifyAndDCEInstruction
jt_simplify_and_dce_instruction :: (i: Value_Id, worklist: *[..] Value_Id, use_tli := true) -> bool {
    wl_add :: (wl: *[..] Value_Id, i: Value_Id) { for wl.* if it == i return; array_add(wl, i); }
    wl_remove :: (wl: *[..] Value_Id, i: Value_Id) { for wl.* if it == i { array_ordered_remove_by_index(wl, it_index); return; } }
    if is_instruction_trivially_dead_tli(i, use_tli) {
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) || o == i continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, use_tli) wl_add(worklist, o);
        }
        wl_remove(worklist, i);
        erase_inst_with_metadata(i);
        return true;
    }
    q: Simplify_Query; q.have_tli = false; q.no_tli_libcalls = !use_tli;
    simple := simplify_instruction(i, q);
    if simple != NONE {
        u := ir.v_first_use[i];
        while u != NONE {
            usr := ir.u_user[u];
            if usr != i wl_add(worklist, usr);
            u = ir.u_next[u];
        }
        changed := false;
        if has_uses(i) { rauw_with_metadata(i, simple); changed = true; }
        if is_instruction_trivially_dead_tli(i, use_tli) {
            wl_remove(worklist, i);
            erase_inst_with_metadata(i);
            changed = true;
        }
        return changed;
    }
    return false;
}

// ---------------------------------------------------------------- select unfolding

// unfoldSelectInstr
jt_unfold_select_instr :: (j: *Jt, pred: Value_Id, bb: Value_Id, si: Value_Id, si_use: Value_Id, idx: u32) {
    pred_term := block_terminator(pred);
    f := block_fn(bb);
    new_bb := create_block(f, "select.unfold", bb);
    // PredTerm->removeFromParent(); PredTerm->insertInto(NewBB, NewBB->end())
    trailing := records_take(pred_term);
    inst_unlink(pred_term);
    block_append_inst(new_bb, pred_term);
    bi := create_cond_br(op(si, 0), new_bb, bb);
    block_append_inst(pred, bi);
    if trailing attach_records_before(bi, trailing);
    set_metadata(bi, 0, merged_location(get_metadata(pred_term, 0), get_metadata(si, 0)));
    prof := get_metadata(si, md_fixed("prof"));
    if prof != NONE set_metadata(bi, md_fixed("prof"), prof);
    phi_set_value(si_use, idx, op(si, 2));
    phi_add_incoming(si_use, op(si, 1), new_bb);
    tw: u64 = 1; fw: u64 = 1;
    okw, etw, efw := prof_extract_branch_weights_2(si);
    if okw { tw = etw; fw = efw; }
    if okw && tw + fw != 0 {
        bpi := jt_get_bpi(j);
        if bpi bpi_set_edge_probability(bpi, pred, .[bp_get(tw, tw + fw), bp_get(fw, tw + fw)]);
    }
    bfi := jt_get_bfi(j);
    if bfi {
        if tw + fw == 0 { tw = 1; fw = 1; }
        bfi_set_block_freq(bfi, new_bb, bf_mul_prob(bfi_get_block_freq(bfi, pred), bp_get(tw, tw + fw)));
    }
    erase_inst_with_metadata(si);
    dtu_apply_permissive(*j.dtu, .[.{true, new_bb, bb}, .{true, pred, new_bb}]);
    for phi: block_insts(bb) {
        if inst_op(phi) != .PHI break;
        if phi != si_use phi_add_incoming(phi, phi_incoming_value_for_block(phi, pred), new_bb);
    }
}

// tryToUnfoldSelect(SwitchInst *, BB)
jt_try_to_unfold_select_switch :: (j: *Jt, sw: Value_Id, bb: Value_Id) -> bool {
    cond_phi := sw_cond(sw);
    if !is_phi(cond_phi) || inst_block(cond_phi) != bb return false;
    n := phi_num_incoming(cond_phi);
    for k: 0..cast(s64) n - 1 {
        pred := phi_block(cond_phi, cast(u32) k);
        pred_si := phi_value(cond_phi, cast(u32) k);
        if !is_inst(pred_si) || inst_op(pred_si) != .SELECT || inst_block(pred_si) != pred || !has_one_use(pred_si) continue;
        if inst_op(block_terminator(pred)) != .BR continue;
        jt_unfold_select_instr(j, pred, bb, pred_si, cond_phi, cast(u32) k);
        return true;
    }
    return false;
}

// tryToUnfoldSelect(CmpInst *, BB)
jt_try_to_unfold_select_cmp :: (j: *Jt, cond_cmp: Value_Id, bb: Value_Id) -> bool {
    cond_br := block_terminator(bb);
    cond_lhs := op(cond_cmp, 0);
    cond_rhs := op(cond_cmp, 1);
    if inst_op(cond_br) != .CONDBR || !is_phi(cond_lhs) || inst_block(cond_lhs) != bb return false;
    n := phi_num_incoming(cond_lhs);
    for k: 0..cast(s64) n - 1 {
        pred := phi_block(cond_lhs, cast(u32) k);
        si := phi_value(cond_lhs, cast(u32) k);
        if !is_inst(si) || inst_op(si) != .SELECT || inst_block(si) != pred || !has_one_use(si) continue;
        if inst_op(block_terminator(pred)) != .BR continue;
        lhs_res := lvi_get_predicate_on_edge(j.lvi, inst_pred(cond_cmp), op(si, 1), cond_rhs, pred, bb, cond_cmp);
        rhs_res := lvi_get_predicate_on_edge(j.lvi, inst_pred(cond_cmp), op(si, 2), cond_rhs, pred, bb, cond_cmp);
        if (lhs_res != NONE || rhs_res != NONE) && lhs_res != rhs_res {
            jt_unfold_select_instr(j, pred, bb, si, cond_lhs, cast(u32) k);
            return true;
        }
    }
    return false;
}

// tryToUnfoldSelectInCurrBB
jt_try_to_unfold_select_in_curr_bb :: (j: *Jt, bb: Value_Id) -> bool {
    if fn_has_fn_attr(block_fn(bb), .SanitizeMemory) return false;
    if table_contains(*j.loop_headers, bb) return false;
    pn := block_first(bb);
    while pn != NONE && is_phi(pn) {
        defer pn = inst_next(pn);
        has_ci := false;
        for k: 0..cast(s64) phi_num_incoming(pn) - 1 if vkind(phi_value(pn, cast(u32) k)) == .C_INT has_ci = true;
        if !has_ci continue;
        is_unfold_candidate :: (bb: Value_Id, si: Value_Id, v: Value_Id) -> bool {
            if inst_block(si) != bb return false;
            c := op(si, 0);
            ok1, _, _ := pm_logical_and(si);
            ok2, _, _ := pm_logical_or(si);
            is_and_or := ok1 || ok2;
            return c != NONE && c == v && type_kind(vtype(c)) == .INT && type_int_width(vtype(c)) == 1 && !is_and_or;
        }
        si: Value_Id = NONE;
        u := ir.v_first_use[pn];
        while u != NONE {
            defer u = ir.u_next[u];
            usr := ir.u_user[u];
            if inst_op(usr) == .ICMP {
                opno := u - ir.v_ops[usr];
                if inst_block(usr) == bb && has_one_use(usr) && vkind(op(usr, 1 - opno)) == .C_INT {
                    sel := ir.u_user[ir.v_first_use[usr]];
                    if is_inst(sel) && inst_op(sel) == .SELECT && is_unfold_candidate(bb, sel, ir.u_val[ir.v_first_use[usr]]) { si = sel; break; }
                }
            } else if inst_op(usr) == .SELECT {
                if is_unfold_candidate(bb, usr, ir.u_val[u]) { si = usr; break; }
            }
        }
        if si == NONE continue;
        cond := op(si, 0);
        if !is_guaranteed_not_to_be_undef_or_poison(cond, null, si) {
            fr := new_inst(.FREEZE, vtype(cond), 1);
            set_op(fr, 0, cond);
            insert_at_position(fr, inst_block(si), si, false);
            set_name(fr, "cond.fr");
            cond = fr;
        }
        branch_weights := prof_md(si);
        if branch_weights != NONE && !prof_is_branch_weight_md(branch_weights) branch_weights = NONE;   // getBranchWeightMDNode
        term := jt_split_block_and_insert_if_then(cond, si, branch_weights);
        split_bb := inst_block(si);
        new_bb := inst_block(term);
        new_pn := create_phi(vtype(si), 2);
        insert_at_position(new_pn, split_bb, si, false);
        phi_add_incoming(new_pn, op(si, 1), new_bb);
        phi_add_incoming(new_pn, op(si, 2), bb);
        set_metadata(new_pn, 0, get_metadata(si, 0));
        rauw_with_metadata(si, new_pn);
        bpi := jt_get_bpi(j);
        bfi := jt_get_bfi(j);
        if branch_weights != NONE {   // !ProfcheckDisableMetadataFixes
            bw := prof_weights_of_md(branch_weights);
            denom: u64 = 0;
            for bw denom += cast(u64) cast,no_check(u32) it;
            true_prob := bp_get(cast(u64) cast,no_check(u32) bw[0], denom);
            false_prob := bp_get(cast(u64) cast,no_check(u32) bw[1], denom);
            if bpi bpi_set_edge_probability(bpi, bb, .[true_prob, false_prob]);
            if bfi {
                bb_orig := bfi_get_block_freq(bfi, bb);
                bfi_set_block_freq(bfi, new_bb, bf_mul_prob(bb_orig, true_prob));
                bfi_set_block_freq(bfi, split_bb, bb_orig);
            }
        }
        erase_inst_with_metadata(si);
        updates: [..] Dom_Update; updates.allocator = temp;
        array_add(*updates, .{true, bb, split_bb});
        array_add(*updates, .{true, bb, new_bb});
        array_add(*updates, .{true, new_bb, split_bb});
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(split_bb, *succs);
        for s: succs {
            array_add(*updates, .{false, bb, s});
            array_add(*updates, .{true, split_bb, s});
        }
        dtu_apply_permissive(*j.dtu, updates);
        return true;
    }
    return false;
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable = false, BranchWeights, DTU = nullptr): the new
// block's terminator
jt_split_block_and_insert_if_then :: (cond: Value_Id, split_before: Value_Id, weights: Md_Id) -> Value_Id {
    head := inst_block(split_before);
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    then_bb := create_block(f, "", tail);
    br := create_br(tail);
    block_append_inst(then_bb, br);
    set_metadata(br, 0, get_metadata(split_before, 0));
    head_old_term := block_terminator(head);
    cbr := create_cond_br(cond, then_bb, tail);
    insert_at_position(cbr, head, head_old_term, false);
    if weights != NONE set_metadata(cbr, md_fixed("prof"), weights);
    set_metadata(cbr, 0, get_metadata(split_before, 0));
    erase_inst_with_metadata(head_old_term);
    return br;
}

// ---------------------------------------------------------------- guards

// processGuards
jt_process_guards :: (j: *Jt, bb: Value_Id) -> bool {
    preds := jt_preds(bb);
    if preds.count != 2 return false;
    pred1 := preds[0]; pred2 := preds[1];
    if pred1 == pred2 return false;
    parent := block_single_predecessor(pred1);
    if parent == NONE || parent != block_single_predecessor(pred2) return false;
    bi := block_terminator(parent);
    if inst_op(bi) == .CONDBR {
        for i: block_insts(bb) if jt_is_guard(i) && jt_thread_guard(j, bb, i, bi) return true;
    }
    return false;
}

// threadGuard
jt_thread_guard :: (j: *Jt, bb: Value_Id, guard: Value_Id, bi: Value_Id) -> bool {
    guard_cond := call_arg(guard, 0);
    branch_cond := op(bi, 0);
    true_dest := get_successor(bi, 0);
    false_dest := get_successor(bi, 1);
    true_safe, false_safe := false, false;
    impl := is_implied_condition(branch_cond, guard_cond, true);
    if impl == 1 true_safe = true;
    else {
        impl = is_implied_condition(branch_cond, guard_cond, false);
        if impl == 1 false_safe = true;
    }
    if !true_safe && !false_safe return false;
    pred_unguarded := ifx true_safe then true_dest else false_dest;
    pred_guarded := ifx false_safe then true_dest else false_dest;
    unguarded_map: Table(Value_Id, Value_Id); unguarded_map.allocator = temp;
    guarded_map: Table(Value_Id, Value_Id); guarded_map.allocator = temp;
    after_guard := inst_next(guard);
    cost := jt_duplication_cost(j, bb, after_guard, j.bb_dup_threshold);
    if cost > j.bb_dup_threshold return false;
    guarded_block := duplicate_instructions_in_split_between(bb, pred_guarded, after_guard, *guarded_map, *j.dtu);
    assert(guarded_block != NONE, "Could not create the guarded block?");
    unguarded_block := duplicate_instructions_in_split_between(bb, pred_unguarded, guard, *unguarded_map, *j.dtu);
    assert(unguarded_block != NONE, "Could not create the unguarded block?");
    to_remove: [..] Value_Id; to_remove.allocator = temp;
    x := block_first(bb);
    while x != after_guard { if !is_phi(x) array_add(*to_remove, x); x = inst_next(x); }
    insertion_point := block_first_non_phi(bb);   // getFirstInsertionPt (BB is not an EH pad here)
    for < k: 0..to_remove.count - 1 {
        i := to_remove[k];
        if has_uses(i) {
            np := create_phi(vtype(i), 2);
            _, uv := table_find(*unguarded_map, i);
            _, gv := table_find(*guarded_map, i);
            phi_add_incoming(np, uv, unguarded_block);
            phi_add_incoming(np, gv, guarded_block);
            set_metadata(np, 0, get_metadata(i, 0));
            insert_at_position(np, bb, insertion_point, true);
            rauw_with_metadata(i, np);
        }
        drop_dbg_records(i);
        if i == insertion_point insertion_point = inst_next(i);
        erase_inst_with_metadata(i);
    }
    return true;
}

// DuplicateInstructionsInSplitBetween(BB, PredBB, StopAt, ValueMapping, DTU) (CloneFunction.cpp)
duplicate_instructions_in_split_between :: (bb: Value_Id, pred_bb: Value_Id, stop_at: Value_Id, vm: *Table(Value_Id, Value_Id), dtu: *Dtu) -> Value_Id {
    bi := block_first(bb);
    while is_phi(bi) {
        table_set(vm, bi, phi_incoming_value_for_block(bi, pred_bb));
        bi = inst_next(bi);
    }
    new_bb := jt_split_edge(pred_bb, bb);
    set_name(new_bb, tprint("%.split", vname(pred_bb)));
    new_term := block_terminator(new_bb);
    dtu_apply(dtu, .[.{false, pred_bb, bb}, .{true, pred_bb, new_bb}, .{true, new_bb, bb}]);
    recs: [..] u32; recs.allocator = temp;
    while stop_at != bi && block_terminator(bb) != bi {
        nw := inst_clone(bi);
        insert_at_position(nw, new_bb, new_term, false);
        if vname(bi).count set_name(nw, vname(bi));
        if inst(bi).records clone_debug_info_from(nw, bi, inst(bi).records, *recs);
        table_set(vm, bi, nw);
        n := nops(nw);
        for k: 0..cast(s64) n - 1 {
            o := op(nw, cast(u32) k);
            if o != NONE && is_inst(o) {
                found, m := table_find(vm, o);
                if found set_op(nw, cast(u32) k, m);
            }
        }
        remap_debug_variable(vm, nw);
        bi = inst_next(bi);
    }
    return new_bb;
}
