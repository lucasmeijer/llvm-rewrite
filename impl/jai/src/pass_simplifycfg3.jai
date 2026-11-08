// SimplifyCFG.cpp, third part: the per-terminator simplifications, simplifyOnce / run, and SimplifyCFGPass.cpp
// (tail merging of function terminators, iterativelySimplifyCFG, simplifyFunctionCFG, SimplifyCFGPass::run).

// ---------------------------------------------------------------- unconditional branches

// tryToMergeLandingPad
try_to_merge_landing_pad :: (s: *Scfg, lpad: Value_Id, bi: Value_Id, bb: Value_Id) -> bool {
    succ := block_unique_successor_of(bb);
    if inst_op(block_first(succ)) == .PHI return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(succ, *preds);
    for other: preds {
        if other == bb continue;
        i := block_first(other);
        if inst_op(i) != .LANDINGPAD || !is_identical_to(i, lpad) continue;
        i = inst_next(i);
        if inst_op(i) != .BR || !is_identical_to(i, bi) continue;
        updates: [..] Dom_Update; updates.allocator = temp;
        bp: [..] Value_Id; bp.allocator = temp;
        block_predecessors(bb, *bp);
        up: [..] Value_Id; up.allocator = temp;
        for bp if !block_set_contains(up, it) array_add(*up, it);
        for p: up {
            ii := block_terminator(p);
            set_successor(ii, 1, other);
            if s.dtu { array_add(*updates, .{true, p, other}); array_add(*updates, .{false, p, bb}); }
        }
        for sc: unique_successors(bb) {
            block_remove_predecessor(sc, bb);
            if s.dtu array_add(*updates, .{false, bb, sc});
        }
        b: Irb; irb_set_before(*b, bi);
        irb_insert(*b, new_inst(.UNREACHABLE, ir.t_void, 0));
        erase_terminator(bi);
        if s.dtu dtu_apply(s.dtu, updates);
        return true;
    }
    return false;
}

simplify_uncond_branch :: (s: *Scfg, bi: Value_Id, b: *Irb) -> bool {
    bb := inst_block(bi);
    succ := get_successor(bi, 0);
    need_canonical := s.opts.need_canonical_loop && s.loop_headers.count > 0 && block_has_n_predecessors_or_more(bb, 2) &&
                      (is_loop_header(s, bb) || is_loop_header(s, succ));
    i := block_first_non_phi_or_dbg(bb);
    if is_terminator(inst_op(i)) && bb != fn_entry(block_fn(bb)) && !need_canonical &&
       try_to_simplify_uncond_branch_from_empty_block(bb, s.dtu) return true;
    if inst_op(i) == .ICMP {
        if is_equality_pred(inst(i).pred) && is_const_int(op(i, 1)) {
            nx := inst_next(i);
            if is_terminator(inst_op(nx)) && try_to_simplify_uncond_branch_with_icmp_in_it(s, i, b) return true;
            if inst_op(nx) == .SELECT && is_terminator(inst_op(inst_next(nx))) &&
               try_to_simplify_uncond_branch_with_icmp_select_in_it(s, i, nx, b) return true;
        }
    }
    if inst_op(i) == .LANDINGPAD {
        nx := inst_next(i);
        if is_terminator(inst_op(nx)) && try_to_merge_landing_pad(s, i, bi, bb) return true;
    }
    return false;
}

// ---------------------------------------------------------------- conditional branches

all_predecessors_come_from_same_source :: (bb: Value_Id) -> Value_Id {
    pp: Value_Id = NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        x := block_single_predecessor(p);
        if x == NONE || (pp != NONE && pp != x) return NONE;
        pp = x;
    }
    return pp;
}

merge_nested_cond_branch :: (s: *Scfg, bi: Value_Id) -> bool {
    bb := inst_block(bi);
    bb1 := get_successor(bi, 0);
    bb2 := get_successor(bi, 1);
    is_simple :: (bb: Value_Id, succ: Value_Id) -> Value_Id {
        if succ == bb return NONE;
        if block_first(succ) != block_terminator(succ) return NONE;
        sbi := block_terminator(succ);
        if inst_op(sbi) != .CONDBR return NONE;
        s1 := get_successor(sbi, 0); s2 := get_successor(sbi, 1);
        if s1 != succ && s2 != succ && s1 != bb && s2 != bb && inst_op(block_first(s1)) != .PHI && inst_op(block_first(s2)) != .PHI return sbi;
        return NONE;
    }
    bb1bi := is_simple(bb, bb1);
    if bb1bi == NONE return false;
    bb2bi := is_simple(bb, bb2);
    if bb2bi == NONE return false;
    if op(bb1bi, 0) != op(bb2bi, 0) || get_successor(bb1bi, 0) != get_successor(bb2bi, 1) || get_successor(bb1bi, 1) != get_successor(bb2bi, 0) return false;
    bb3 := get_successor(bb1bi, 0);
    bb4 := get_successor(bb1bi, 1);
    b: Irb; irb_set_before(*b, bi);
    set_op(bi, 0, irb_binop(*b, .XOR, op(bi, 0), op(bb1bi, 0)));
    block_remove_predecessor(bb1, bb);
    set_successor(bi, 0, bb4);
    block_remove_predecessor(bb2, bb);
    set_successor(bi, 1, bb3);
    if s.dtu {
        ups := Dom_Update.[.{false, bb, bb1}, .{true, bb, bb4}, .{false, bb, bb2}, .{true, bb, bb3}];
        dtu_apply(s.dtu, ups);
    }
    hw := false;
    ok, bt, bf := prof_extract_branch_weights_2(bi);
    if ok hw = true; else { bt = 1; bf = 1; }
    ok1, b1t, b1f := prof_extract_branch_weights_2(bb1bi);
    if ok1 hw = true; else { b1t = 1; b1f = 1; }
    ok2, b2t, b2f := prof_extract_branch_weights_2(bb2bi);
    if ok2 hw = true; else { b2t = 1; b2f = 1; }
    if hw {
        w := u64.[bt * b1f + bf * b2t, bt * b1t + bf * b2f];
        prof_set_fitted_branch_weights(bi, w, false, true);
    }
    return true;
}

simplify_cond_branch :: (s: *Scfg, bi: Value_Id, b: *Irb) -> bool {
    bb := inst_block(bi);
    if !s.opts.simplify_cond_branch || fn_has_fn_attr(block_fn(bb), .OptForFuzzing) return false;
    if is_value_equality_comparison(bi) != NONE {
        only := block_single_predecessor(bb);
        if only != NONE && simplify_equality_comparison_with_only_predecessor(s, bi, only, b) return request_resimplify(s);
        for i: block_insts(bb) {
            if is_pseudo_probe(i) || i == op(bi, 0) continue;
            if i == bi && fold_value_comparison_into_predecessors(s, bi, b) return request_resimplify(s);
            break;
        }
    }
    if simplify_branch_on_icmp_chain(s, bi, b) return true;
    imp := is_implied_by_dom_condition(op(bi, 0), bi);
    if imp >= 0 {
        old := op(bi, 0);
        set_op(bi, 0, const_int(ir.t_i1, ifx imp == 1 then cast(u64) 1 else 0));
        recursively_delete_trivially_dead_value(old);
        return request_resimplify(s);
    }
    if s.opts.speculate_blocks && fold_branch_to_common_dest(s, bi, s.opts.bonus_inst_threshold) return request_resimplify(s);
    s0 := get_successor(bi, 0); s1 := get_successor(bi, 1);
    if block_single_predecessor(s0) != NONE {
        if block_single_predecessor(s1) != NONE {
            if scfg_cl.hoist_common && hoist_common_code_from_successors(s, bi, !s.opts.hoist_common_insts) return request_resimplify(s);
            if s.opts.hoist_loads_stores_with_cond_faulting && is_profitable_to_speculate(s, bi, -1) {
                cand: [..] Value_Id; cand.allocator = temp;
                can := true;
                succs: [..] Value_Id; succs.allocator = temp;
                block_successors(bb, *succs);
                for sc: succs {
                    for i: block_insts(sc) {
                        if is_terminator(inst_op(i)) { if num_successors(i) > 1 can = false; continue; }
                        if !is_safe_cheap_load_store(s, i) || cand.count == scfg_cl.hoist_loads_stores_with_cond_faulting_threshold { can = false; break; }
                        array_add(*cand, i);
                    }
                    if !can break;
                }
                if can && cand.count scfg_np("hoisting conditional loads/stores (conditional faulting)");
            }
        } else {
            t0 := block_terminator(s0);
            if num_successors(t0) == 1 && get_successor(t0, 0) == s1 && speculatively_execute_bb(s, bi, s0) return request_resimplify(s);
        }
    } else if block_single_predecessor(s1) != NONE {
        t1 := block_terminator(s1);
        if num_successors(t1) == 1 && get_successor(t1, 0) == s0 && speculatively_execute_bb(s, bi, s1) return request_resimplify(s);
    }
    if fold_cond_branch_on_value_known_in_predecessor(s, bi) return request_resimplify(s);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        pbi := block_terminator(p);
        if inst_op(pbi) == .CONDBR && pbi != bi && simplify_cond_branch_to_cond_branch(s, pbi, bi) return request_resimplify(s);
    }
    if scfg_cl.merge_cond_stores {
        prev := all_predecessors_come_from_same_source(bb);
        if prev != NONE {
            pbi := block_terminator(prev);
            if inst_op(pbi) == .CONDBR && pbi != bi && merge_conditional_stores(s, pbi, bi) return request_resimplify(s);
        }
    }
    if merge_nested_cond_branch(s, bi) return request_resimplify(s);
    return false;
}

// ---------------------------------------------------------------- removeUndefIntroducingPredecessor

remove_undef_introducing_predecessor :: (s: *Scfg, bb: Value_Id) -> bool {
    for phi: block_insts(bb) {
        if inst_op(phi) != .PHI break;
        for i: 0..cast(s64) nops(phi) - 1 {
            if !passing_value_is_always_undefined(phi_value(phi, cast(u32) i), phi) continue;
            pred := phi_block(phi, cast(u32) i);
            t := block_terminator(pred);
            b: Irb; irb_set_before(*b, t);
            if inst_op(t) == .BR {
                block_remove_predecessor(bb, pred);
                irb_insert(*b, new_inst(.UNREACHABLE, ir.t_void, 0));
                erase_terminator(t);
                dtu_apply1(s.dtu, false, pred, bb);
                return true;
            } else if inst_op(t) == .CONDBR {
                block_remove_predecessor(bb, pred);
                c := op(t, 0);
                cond := c;
                if get_successor(t, 0) == bb cond = irb_not(*b, c);
                args := Value_Id.[cond];
                a := irb_intrinsic(*b, "llvm.assume", .[], args);
                if s.opts.ac ac_register_assumption(s.opts.ac, a);
                irb_br(*b, ifx get_successor(t, 0) == bb then get_successor(t, 1) else get_successor(t, 0));
                erase_terminator(t);
                dtu_apply1(s.dtu, false, pred, bb);
                return true;
            } else if inst_op(t) == .SWITCH {
                u := create_block(block_fn(bb), "unreachable", bb);
                block_append_inst(u, new_inst(.UNREACHABLE, ir.t_void, 0));
                for k: 0..cast(s64) sw_num_cases(t) - 1 {
                    if sw_case_dest(t, cast(u32) k) == bb {
                        block_remove_predecessor(bb, pred);
                        sw_set_case_dest(t, cast(u32) k, u);
                    }
                }
                if sw_default(t) == bb {
                    block_remove_predecessor(bb, pred);
                    sw_set_default(t, u);
                }
                if s.dtu { ups := Dom_Update.[.{true, pred, u}, .{false, pred, bb}]; dtu_apply(s.dtu, ups); }
                return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------- simplifyOnce / run

simplify_once :: (s: *Scfg, bb: Value_Id) -> bool {
    changed := false;
    f := block_fn(bb);
    if (!block_has_predecessors(bb) && bb != fn_entry(f)) || block_single_predecessor(bb) == bb {
        delete_dead_block(bb, s.dtu);
        return true;
    }
    changed |= constant_fold_terminator(bb, true, s.dtu);
    changed |= eliminate_duplicate_phi_nodes(bb);
    if remove_undef_introducing_predecessor(s, bb) return request_resimplify(s);
    if merge_block_into_predecessor(bb, ifx s.dtu then s.dtu.dt else null, null, null) return true;
    if scfg_cl.sink_common && s.opts.sink_common_insts {
        if sink_common_code_from_predecessors(s, bb) || merge_compatible_invokes(s, bb) return true;
        if simplify_duplicate_predecessors(s, bb) return true;
    }
    if s.opts.speculate_blocks && !fn_has_fn_attr(f, .OptForFuzzing) {
        pn := block_first(bb);
        if inst_op(pn) == .PHI && nops(pn) == 2 && fold_two_entry_phi_node(s, pn) return true;
    }
    t := block_terminator(bb);
    b: Irb;
    irb_set_before(*b, t);
    if inst_op(t) == {
        case .BR; changed |= simplify_uncond_branch(s, t, *b);
        case .CONDBR; changed |= simplify_cond_branch(s, t, *b);
        case .RESUME; changed |= simplify_resume(s, t, *b);
        case .CLEANUPRET; changed |= simplify_cleanup_return(s, t);
        case .SWITCH; changed |= simplify_switch(s, t, *b);
        case .UNREACHABLE; changed |= simplify_unreachable(s, t);
        case .INDIRECTBR; changed |= simplify_indirect_br(s, t);
    }
    return changed;
}
simplify_cfg_block :: (s: *Scfg, bb: Value_Id) -> bool {
    changed := false;
    while true {
        s.resimplify = false;
        changed |= simplify_once(s, bb);
        if !s.resimplify break;
    }
    return changed;
}

// ---------------------------------------------------------------- SimplifyCFGPass.cpp

// performBlockTailMerging
perform_block_tail_merging :: (f: Value_Id, bbs: [] Value_Id, updates: *[..] Dom_Update) -> bool {
    if bbs.count < 2 return false;
    term0 := block_terminator(bbs[0]);
    canonical := create_block(f, tprint("common.%", opcode_name(inst_op(term0))), bbs[0]);
    new_ops: [..] Value_Id; new_ops.allocator = temp;
    for k: 0..cast(s64) nops(term0) - 1 {
        pn := create_phi(vtype(op(term0, cast(u32) k)), cast(u32) bbs.count);
        block_append_inst(canonical, pn);
        set_name(pn, tprint("%.op", vname(canonical)));
        array_add(*new_ops, pn);
    }
    ct := inst_clone(term0);
    block_append_inst(canonical, ct);
    for k: 0..cast(s64) nops(ct) - 1 set_op(ct, cast(u32) k, new_ops[k]);
    common_loc: Md_Id = NONE;
    first := true;
    for bb: bbs {
        t := block_terminator(bb);
        for k: 0..cast(s64) nops(t) - 1 phi_add_incoming(new_ops[k], op(t, cast(u32) k), bb);
        if first || common_loc == NONE { common_loc = get_metadata(t, 0); first = false; }
        else common_loc = merged_location(common_loc, get_metadata(t, 0));
        br := create_br(canonical);
        block_append_inst(bb, br);
        copy_debug_loc_or_clear(br, t);
        // Term->eraseFromParent(): the new branch was appended after it
        if inst(t).records { r := records_take(t); records_append(br, r); }
        drop_all_references(t);
        erase_inst_with_metadata(t);
        if updates array_add(updates, .{true, bb, canonical});
    }
    set_metadata(ct, 0, common_loc);
    return true;
}

// tailMergeBlocksWithSimilarFunctionTerminators
tail_merge_blocks_with_similar_function_terminators :: (f: Value_Id, dtu: *Dtu) -> bool {
    keys: [..] Opcode; keys.allocator = temp;          // SmallMapVector<opcode, blocks>
    lists: [..] [..] Value_Id; lists.allocator = temp;
    for bb: fn_blocks(f) {
        if block_num_successors(bb) != 0 continue;
        t := block_terminator(bb);
        o := inst_op(t);
        if o != .RET && o != .RESUME continue;
        if block_terminating_must_tail_call(bb) != NONE continue;
        p := inst_prev(t);
        if p != NONE && inst_op(p) == .CALL && call_iid(p) != NOT_INTRINSIC && iid_name(call_iid(p)) == "llvm.experimental.deoptimize" continue;
        tok := false;
        for k: 0..cast(s64) nops(t) - 1 if type_kind(vtype(op(t, cast(u32) k))) == .TOKEN tok = true;
        if tok continue;
        idx := -1;
        for keys if it == o idx = it_index;
        if idx < 0 { array_add(*keys, o); l: [..] Value_Id; l.allocator = temp; array_add(*lists, l); idx = keys.count - 1; }
        array_add(*lists[idx], bb);
    }
    changed := false;
    updates: [..] Dom_Update; updates.allocator = temp;
    for lists changed |= perform_block_tail_merging(f, it, ifx dtu then *updates else null);
    if dtu dtu_apply(dtu, updates);
    return changed;
}
// BasicBlock::getTerminatingMustTailCall
block_terminating_must_tail_call :: (bb: Value_Id) -> Value_Id {
    t := block_terminator(bb);
    if t == NONE || inst_op(t) != .RET return NONE;
    p := inst_prev(t);
    if p != NONE && inst_op(p) == .BITCAST p = inst_prev(p);
    if p != NONE && inst_op(p) == .CALL && call_is_must_tail(p) return p;
    return NONE;
}

// iterativelySimplifyCFG
iteratively_simplify_cfg :: (f: Value_Id, tti: *Tti, dtu: *Dtu, o: *Scfg_Options) -> bool {
    changed := false;
    local := true;
    edges: [..] Block_Edge; edges.allocator = temp;
    find_function_backedges(f, *edges);
    headers: [..] Value_Id; headers.allocator = temp;
    for edges if !block_set_contains(headers, it.to) array_add(*headers, it.to);
    s: Scfg;
    s.tti = tti; s.dtu = dtu; s.opts = o; s.loop_headers = headers;
    iter := 0;
    while local {
        iter += 1;
        if iter > 2000 fatal("simplifycfg: iterative simplification didn't converge");
        local = false;
        bb := glob(f).first_block;
        while bb != NONE {
            cur := bb;
            bb = block(bb).next;
            if simplify_cfg_block(*s, cur) local = true;
            // the next block may have been deleted (merged into its predecessor): continue from cur's successor
            // in layout when that happened
            if bb != NONE && vkind(bb) == .DEAD fatal("internal: simplifycfg deleted the next block");
        }
        changed |= local;
    }
    return changed;
}

// simplifyFunctionCFGImpl
simplify_function_cfg :: (f: Value_Id, tti: *Tti, dt: *Dom_Tree, o: *Scfg_Options) -> bool {
    dtu_v: Dtu; dtu_v.dt = dt;
    dtu: *Dtu = ifx dt then *dtu_v else null;
    ever := remove_unreachable_blocks(f, dtu);
    ever |= tail_merge_blocks_with_similar_function_terminators(f, dtu);
    ever |= iteratively_simplify_cfg(f, tti, dtu, o);
    if !ever return false;
    if !remove_unreachable_blocks(f, dtu) return true;
    while true {
        ever = iteratively_simplify_cfg(f, tti, dtu, o);
        ever |= remove_unreachable_blocks(f, dtu);
        if !ever break;
    }
    return true;
}

// SimplifyCFGPass::run
simplifycfg_run :: (node: *Pass_Node, f: Value_Id) -> Preserved {
    o: Scfg_Options;
    name := node.name;
    lt := find_index_from_left(name, #char "<");
    if lt >= 0 o = scfg_parse_options(slice(name, lt + 1, name.count - lt - 2));
    scfg_apply_cl_overrides(*o);
    tti := tti_get(f);
    o.ac = get_assumption_cache(f);
    dt: *Dom_Tree = null;
    if scfg_cl.require_and_preserve_domtree dt = get_domtree(f);
    if !simplify_function_cfg(f, tti, dt, *o) return PRESERVE_ALL;
    pa := PRESERVE_NONE;
    if scfg_cl.require_and_preserve_domtree preserve(*pa, .DOMTREE);
    return pa;
}
