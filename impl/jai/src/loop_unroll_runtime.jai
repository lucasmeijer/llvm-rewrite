// Runtime unrolling: the prolog/epilog remainder loop.
// Port of llvm/lib/Transforms/Utils/LoopUnrollRuntime.cpp (ConnectProlog, probOfNextInRemainder, ConnectEpilog,
// CloneLoopBlocks, canProfitablyRuntimeUnrollMultiExitLoop, CreateTripRemainder, UnrollRuntimeLoopRemainder) and
// SplitEdge (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp, the DominatorTree/LoopInfo form).

UNROLLED_LOOP_HEADER_WEIGHTS :: u32.[1, 127];
EPILOG_HEADER_WEIGHTS :: u32.[1, 127];

// SplitEdge(BB, Succ, DT, LI, MSSAU = nullptr, BBName = "")
split_edge :: (bb: Value_Id, succ: Value_Id, dt: *Dom_Tree, li: *Loop_Info, name := "") -> Value_Id {
    t := block_terminator(bb);
    succ_num: u32 = 0;
    while get_successor(t, succ_num) != succ succ_num += 1;   // GetSuccessorNumber
    o: Crit_Edge_Options; o.dt = dt; o.li = li; o.preserve_lcssa = true;
    if is_critical_edge(t, succ_num, o.merge_identical_edges) {
        if block_is_eh_pad(succ) fatal("SplitEdge of a critical edge into an EH pad (ehAwareSplitEdge) is not implemented yet");
        return split_known_critical_edge(t, succ_num, *o, name);
    }
    sp := block_single_predecessor(succ);
    if sp != NONE {
        assert(sp == bb, "CFG broken");
        return split_block_before(succ, block_first(succ), dt, li, name);
    }
    assert(num_successors(t) == 1, "Should have a single succ!");
    return split_block(bb, t, dt, li, null, name);
}

// SplitBlock(Old, SplitPt, DT, LI, MSSAU, BBName, Before = true) = splitBlockBefore(Old, SplitPt, &LocalDTU (lazy), LI, ...)
split_block_before :: (old: Value_Id, split_pt: Value_Id, dt: *Dom_Tree, li: *Loop_Info, name := "") -> Value_Id {
    it := split_pt;
    while inst_op(it) == .PHI || is_eh_pad(it) it = inst_next(it);
    nm := name;
    if nm.count == 0 nm = tprint("%.split", vname(old));
    // BasicBlock::splitBasicBlockBefore(I, Name)
    f := block_fn(old);
    nb := create_block(f, nm, old);
    loc := get_metadata(it, 0);
    if loc != NONE && di_int(loc, 3) != 0 loc = di_location_get(diloc_line(loc), diloc_col(loc), diloc_scope(loc), diloc_inlined_at(loc), di_int(loc, 2));
    // New->splice(New->end(), this, begin(), I)
    x := block_first(old);
    while x != it {
        nx := inst_next(x);
        inst_unlink(x);
        block_append_inst(nb, x);
        x = nx;
    }
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(old, *preds);
    for p: preds {
        replace_successor_with(block_terminator(p), old, nb);
        block_replace_phi_uses_with(old, p, nb);
    }
    bi := create_br(old);
    block_append_inst(nb, bi);
    if loc != NONE set_metadata(bi, 0, loc);
    if li {
        l := li_loop_for(li, old);
        if l != NONE li_add_basic_block_to_loop(li, l, nb);
    }
    if dt {
        upd: [..] Dom_Update; upd.allocator = temp;
        array_add(*upd, .{true, nb, old});
        np: [..] Value_Id; np.allocator = temp;
        block_predecessors(nb, *np);
        seen: [..] Value_Id; seen.allocator = temp;
        for p: np {
            if block_set_contains(seen, p) continue;
            array_add(*seen, p);
            array_add(*upd, .{true, p, nb});
            array_add(*upd, .{false, p, old});
        }
        // LocalDTU (lazy): flushed when it goes out of scope
        dt_apply_updates(dt, upd);
    }
    return nb;
}

// ConnectProlog
connect_prolog :: (li: *Loop_Info, l: Loop_Id, be_count: Value_Id, count: u32, prolog_exit: Value_Id, original_loop_latch_exit: Value_Id,
                   pre_header: Value_Id, new_pre_header: Value_Id, vm: *Value_Map, dt: *Dom_Tree, preserve_lcssa: bool) {
    latch := li_loop_latch(li, l);
    prolog_latch := vmap_get(vm, latch);
    lt := block_terminator(latch);
    ns := num_successors(lt);
    for s: 0..cast(s64) ns - 1 {
        succ := get_successor(lt, cast(u32) s);
        for pn: block_insts(succ) {
            if !is_phi(pn) break;
            new_pn := create_phi(vtype(pn), 2);
            insert_at_position(new_pn, prolog_exit, block_first_non_phi(prolog_exit), true);
            set_name(new_pn, tprint("%.unr", vname(pn)));
            if li_contains_inst(li, l, pn) phi_add_incoming(new_pn, phi_incoming_value_for_block(pn, new_pre_header), pre_header);
            else phi_add_incoming(new_pn, const_poison(vtype(pn)), pre_header);
            v := phi_incoming_value_for_block(pn, latch);
            if is_inst(v) && li_contains_inst(li, l, v) v = vmap_lookup(vm, v);
            phi_add_incoming(new_pn, v, prolog_latch);
            if li_contains_inst(li, l, pn) phi_set_incoming_value_for_block(pn, new_pre_header, new_pn);
            else phi_add_incoming(pn, new_pn, prolog_exit);
            sc_forget_lcssa_phi_with_new_predecessor(l, pn);
        }
    }
    prolog_loop := li_loop_for(li, prolog_latch);
    if prolog_loop != NONE {
        preds: [..] Value_Id; preds.allocator = temp;
        all: [..] Value_Id; all.allocator = temp;
        block_predecessors(prolog_exit, *all);
        for all if li_contains(li, prolog_loop, it) array_add(*preds, it);
        split_block_predecessors(prolog_exit, preds, ".unr-lcssa", dt, li, null, preserve_lcssa);
    }
    insert_pt := block_terminator(prolog_exit);
    b: Irb; irb_set_before(*b, insert_pt);
    br_loop_exit := irb_icmp(*b, ICMP_ULT, be_count, const_int(vtype(be_count), cast(u64) (count - 1)));
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(original_loop_latch_exit, *preds);
    split_block_predecessors(original_loop_latch_exit, preds, ".unr-lcssa", dt, li, null, preserve_lcssa);
    br := irb_cond_br(*b, br_loop_exit, original_loop_latch_exit, new_pre_header);
    if prof_has_branch_weight_md(block_terminator(latch)) prof_set_branch_weights(br, UNROLLED_LOOP_HEADER_WEIGHTS, false);
    erase_inst_with_metadata(insert_pt);
    if dt {
        nd := dt_find_nca(dt, original_loop_latch_exit, prolog_exit);
        dt_change_idom(dt, original_loop_latch_exit, nd);
    }
}

// probOfNextInRemainder
prob_of_next_in_remainder :: (original_loop_prob: Bprob, n: u32) -> Bprob {
    if original_loop_prob == bprob_one() return original_loop_prob;
    prob_one := original_loop_prob;
    prob_too_many := bprob_pow(prob_one, n + 1);
    prob_not_too_many := bprob_compl(prob_too_many);
    prob_one_not_too_many := bprob_sub(prob_one, prob_too_many);
    return bprob_div(prob_one_not_too_many, prob_not_too_many);
}

// ConnectEpilog
connect_epilog :: (li: *Loop_Info, l: Loop_Id, mod_val: Value_Id, new_exit: Value_Id, exit: Value_Id, pre_header: Value_Id,
                   epilog_pre_header: Value_Id, new_pre_header: Value_Id, vm: *Value_Map, dt: *Dom_Tree, preserve_lcssa: bool,
                   count: u32, ac: *Assumption_Cache, original_loop_prob: Bprob) {
    latch := li_loop_latch(li, l);
    epilog_latch := vmap_get(vm, latch);
    for pn: block_insts(new_exit) {
        if !is_phi(pn) break;
        epilog_pn := ir.u_user[ir.v_first_use[pn]];
        v := phi_incoming_value_for_block(pn, latch);
        if is_inst(v) && li_contains_inst(li, l, v) v = vmap_lookup(vm, v);
        phi_add_incoming(epilog_pn, v, epilog_latch);
        sc_forget_lcssa_phi_with_new_predecessor(l, epilog_pn);
        phi_set_block(epilog_pn, cast(u32) phi_block_index(epilog_pn, epilog_pre_header), new_exit);
    }
    lt := block_terminator(latch);
    ns := num_successors(lt);
    for s: 0..cast(s64) ns - 1 {
        succ := get_successor(lt, cast(u32) s);
        if !li_contains(li, l, succ) continue;
        for pn: block_insts(succ) {
            if !is_phi(pn) break;
            pn0 := create_phi(vtype(pn), 1);
            insert_at_position(pn0, new_exit, block_first_non_phi(new_exit), true);
            set_name(pn0, tprint("%.unr", vname(pn)));
            phi_add_incoming(pn0, phi_incoming_value_for_block(pn, latch), latch);
            pn1 := create_phi(vtype(pn), 2);
            insert_at_position(pn1, epilog_pre_header, block_first_non_phi(epilog_pre_header), true);
            set_name(pn1, tprint("%.epil.init", vname(pn)));
            phi_add_incoming(pn1, phi_incoming_value_for_block(pn, new_pre_header), pre_header);
            phi_add_incoming(pn1, pn0, new_exit);
            vpn := vmap_get(vm, pn);
            phi_set_incoming_value_for_block(vpn, epilog_pre_header, pn1);
        }
    }
    insert_pt := block_terminator(new_exit);
    b: Irb; irb_set_before(*b, insert_pt);
    br_loop_exit := irb_icmp(*b, ICMP_NE, mod_val, const_null_value(vtype(mod_val)), "lcmp.mod");
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(exit, *preds);
    split_block_predecessors(exit, preds, ".epilog-lcssa", dt, li, null, preserve_lcssa);
    guard := irb_cond_br(*b, br_loop_exit, epilog_pre_header, exit);
    if bprob_is_unknown(original_loop_prob) && prof_has_branch_weight_md(block_terminator(latch))
        prof_set_branch_weights(guard, .[1, count - 1], false);
    if !bprob_is_unknown(original_loop_prob) set_cond_br_probability(guard, prob_of_next_in_remainder(original_loop_prob, count - 1), true);
    erase_inst_with_metadata(insert_pt);
    if dt {
        nd := dt_find_nca(dt, exit, new_exit);
        dt_change_idom(dt, exit, nd);
    }
    b2: Irb; irb_set_at(*b2, epilog_pre_header, block_first_non_phi(epilog_pre_header), true);
    mod_is_not_null := irb_icmp(*b2, ICMP_NE, mod_val, const_null_value(vtype(mod_val)), "lcmp.mod");
    ai := irb_assumption(*b2, mod_is_not_null);
    ac_register_assumption(ac, ai);
}
// IRBuilder::CreateAssumption(Cond)
irb_assumption :: (b: *Irb, cond: Value_Id) -> Value_Id {
    return irb_intrinsic(b, "llvm.assume", .[], .[cond]);
}

// CloneLoopBlocks
clone_loop_blocks_remainder :: (li: *Loop_Info, l: Loop_Id, new_iter: Value_Id, use_epilog_remainder: bool, unroll_remainder: bool,
                                insert_top: Value_Id, insert_bot: Value_Id, preheader: Value_Id, new_blocks: *[..] Value_Id,
                                rpo: [] Value_Id, vm: *Value_Map, dt: *Dom_Tree, count: u32, has_otc: bool, original_trip_count: u32,
                                original_loop_prob: Bprob) -> Loop_Id {
    suffix := ifx use_epilog_remainder then "epil" else "prol";
    header := li_header(li, l);
    latch := li_loop_latch(li, l);
    f := block_fn(header);
    parent := li_parent(li, l);
    new_loops: New_Loops_Map; nlm_init(*new_loops);
    nlm_set(*new_loops, parent, parent);
    for bb: rpo {
        nb := clone_basic_block(bb, vm, tprint(".%", suffix), f);
        array_add(new_blocks, nb);
        add_cloned_block_to_loop_info(li, bb, nb, *new_loops);
        vmap_set(vm, bb, nb);
        if header == bb set_successor(block_terminator(insert_top), 0, nb);
        if dt {
            if header == bb dt_add_new_block(dt, nb, insert_top);
            else dt_add_new_block(dt, nb, vmap_get(vm, dt_idom_block(dt, bb)));
        }
        if latch == bb {
            vmap_erase(vm, block_terminator(bb));
            first_loop_bb := vmap_get(vm, header);
            latch_br := block_terminator(nb);
            b: Irb; irb_set_before(*b, latch_br);
            new_idx := create_phi(vtype(new_iter), 2);
            insert_at_position(new_idx, first_loop_bb, block_first_non_phi(first_loop_bb), true);
            set_name(new_idx, tprint("%.iter", suffix));
            zero := const_int(vtype(new_iter), 0);
            one := const_int(vtype(new_iter), 1);
            idx_next := irb_binop(*b, .ADD, new_idx, one, tprint("%.next", vname(new_idx)));
            idx_cmp := irb_icmp(*b, ICMP_NE, idx_next, new_iter, tprint("%.cmp", vname(new_idx)));
            remainder_latch := irb_cond_br(*b, idx_cmp, first_loop_bb, insert_bot);
            if (bprob_is_unknown(original_loop_prob) || !use_epilog_remainder) && prof_has_branch_weight_md(latch_br) {
                exit_w: u32 = 1;
                back_w: u32 = ifx count >= 3 then (count - 2) / 2 else 0;
                prof_set_branch_weights(remainder_latch, .[back_w, exit_w], false);
            }
            if !bprob_is_unknown(original_loop_prob) && use_epilog_remainder {
                freq_rem_iters: float64 = 1.0;
                if count > 2 {
                    prob_reaching := bprob_one();
                    nn := count - 2;
                    while nn >= 1 {
                        prob_reaching = bprob_mul(prob_reaching, prob_of_next_in_remainder(original_loop_prob, nn));
                        freq_rem_iters += bprob_to_double(prob_reaching);
                        nn -= 1;
                    }
                }
                set_cond_br_probability(remainder_latch, bprob_from_double(1 - 1 / freq_rem_iters), true);
            }
            phi_add_incoming(new_idx, zero, insert_top);
            phi_add_incoming(new_idx, idx_next, nb);
            erase_inst_with_metadata(latch_br);
        }
    }
    for i: block_insts(header) {
        if !is_phi(i) break;
        new_phi := vmap_get(vm, i);
        idx := cast(u32) phi_block_index(new_phi, preheader);
        phi_set_block(new_phi, idx, insert_top);
        new_latch := vmap_get(vm, latch);
        idx = cast(u32) phi_block_index(new_phi, latch);
        in_val := phi_value(new_phi, idx);
        phi_set_block(new_phi, idx, new_latch);
        v := vmap_lookup(vm, in_val);
        if v != NONE phi_set_value(new_phi, idx, v);
    }
    new_loop := nlm_lookup(*new_loops, l);
    if has_otc && use_epilog_remainder li_set_loop_estimated_trip_count(li, new_loop, original_trip_count % count);
    if !unroll_remainder li_set_loop_already_unrolled(li, new_loop);
    return new_loop;
}

// canProfitablyRuntimeUnrollMultiExitLoop
can_profitably_runtime_unroll_multi_exit_loop :: (li: *Loop_Info, l: Loop_Id, t: *Tti, other_exits: [] Value_Id, latch_exit: Value_Id, use_epilog: bool) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    if exiting.count > 2 return false;
    if other_exits.count == 0 return true;
    if other_exits.count != 1 return false;
    if lu_cl.unroll_runtime_other_exit_predictable.v != 0 return true;
    if t {
        latch_bb := li_loop_latch(li, l);
        non_latch := ifx exiting[0] == latch_bb then exiting[1] else exiting[0];
        bp := edge_branch_probability(non_latch, other_exits[0]);
        if !bprob_is_unknown(bp) {
            threshold := bprob_compl(cast(Bprob) tti_predictable_branch_threshold_prob(t));
            return bp < threshold;
        }
    }
    return block_postdominating_deoptimize_call(other_exits[0]) != NONE;
}
// TTI::getPredictableBranchThreshold as a BranchProbability numerator
tti_predictable_branch_threshold_prob :: (t: *Tti) -> Bprob {
    pct := tti_predictable_branch_threshold(t);
    return bprob_get(cast(u64) pct, 100);
}
// BasicBlock::getPostdominatingDeoptimizeCall
block_postdominating_deoptimize_call :: (bb_in: Value_Id) -> Value_Id {
    bb := bb_in;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, bb);
    while true {
        s := block_unique_successor(bb);
        if s == NONE break;
        if block_set_contains(visited, s) return NONE;
        array_add(*visited, s);
        bb = s;
    }
    return block_terminating_deoptimize_call(bb);
}

// CreateTripRemainder
create_trip_remainder :: (b: *Irb, be_count: Value_Id, trip_count: Value_Id, count: u32) -> Value_Id {
    if (count & (count - 1)) == 0 return irb_binop(b, .AND, trip_count, const_int(vtype(trip_count), cast(u64) (count - 1)), "xtraiter");
    count_c := const_int(vtype(be_count), cast(u64) count);
    mod_tmp := irb_binop(b, .UREM, be_count, count_c);
    mod_add := irb_binop(b, .ADD, mod_tmp, const_int(vtype(mod_tmp), 1));
    return irb_binop(b, .UREM, mod_add, count_c, "xtraiter");
}


// UnrollRuntimeLoopRemainder
unroll_runtime_loop_remainder :: (li: *Loop_Info, l: Loop_Id, count: u32, allow_expensive_trip_count: bool, use_epilog_remainder: bool,
                                  unroll_remainder: bool, forget_all_scev: bool, dt: *Dom_Tree, ac: *Assumption_Cache, t: *Tti,
                                  preserve_lcssa: bool, scev_expansion_budget: u32, runtime_unroll_multi_exit: bool,
                                  result_loop: *Loop_Id, has_otc: bool, original_trip_count: u32, original_loop_prob: Bprob) -> bool {
    if !li_is_loop_simplify_form(li, l) return false;
    latch := li_loop_latch(li, l);
    header := li_header(li, l);
    latch_br := block_terminator(latch);
    if inst_op(latch_br) != .CONDBR return false;
    exit_index: u32 = ifx get_successor(latch_br, 0) == header then cast(u32) 1 else 0;
    latch_exit := get_successor(latch_br, exit_index);
    if li_contains(li, l, latch_exit) return false;

    other_exits: [..] Value_Id; other_exits.allocator = temp;
    li_unique_exit_blocks(li, l, *other_exits, latch);
    if li_exiting_block(li, l) == NONE || other_exits.count {
        if !preserve_lcssa return false;
        if lu_cl.unroll_runtime_multi_exit.given {
            if lu_cl.unroll_runtime_multi_exit.v == 0 return false;
        } else {
            if !runtime_unroll_multi_exit && !can_profitably_runtime_unroll_multi_exit_loop(li, l, t, other_exits, latch_exit, use_epilog_remainder)
                return false;
        }
    }
    be_count_sc := sc_get_exit_count(l, latch);
    if be_count_sc == SCEV_CNC return false;
    be_width := type_int_width(sc_type(be_count_sc));
    trip_count_sc := sc_get_add2(be_count_sc, sc_get_constant_t(sc_type(be_count_sc), 1));
    if trip_count_sc == SCEV_CNC return false;

    pre_header := li_loop_preheader(li, l);
    pre_header_br := block_terminator(pre_header);
    expander: Scev_Expander;
    sx_init(*expander, "loop-unroll");
    if !allow_expensive_trip_count && sx_is_high_cost_expansion(*expander, .[trip_count_sc], l, cast(s64) scev_expansion_budget, t, pre_header_br)
        return false;
    if log2_u32(count) > be_width return false;

    new_pre_header: Value_Id;
    new_exit: Value_Id = NONE;
    prolog_exit: Value_Id = NONE;
    epilog_pre_header: Value_Id = NONE;
    prolog_pre_header: Value_Id = NONE;
    if use_epilog_remainder {
        new_pre_header = split_block(pre_header, block_terminator(pre_header), dt, li);
        set_name(new_pre_header, tprint("%.new", vname(pre_header)));
        new_exit = split_block_predecessors(latch_exit, .[latch], ".unr-lcssa", dt, li, null, preserve_lcssa);
        net := block_terminator(new_exit);
        hl := get_metadata(block_terminator(header), 0);
        set_metadata(net, 0, hl);
        epilog_pre_header = split_block(new_exit, net, dt, li);
        set_name(epilog_pre_header, tprint("%.epil.preheader", vname(header)));
        parent := li_parent(li, l);
        if parent != NONE && li_loop_for(li, latch_exit) != parent {
            li_remove_block(li, new_exit);
            li_add_basic_block_to_loop(li, parent, new_exit);
            li_remove_block(li, epilog_pre_header);
            li_add_basic_block_to_loop(li, parent, epilog_pre_header);
        }
    } else {
        prolog_pre_header = split_edge(pre_header, header, dt, li);
        set_name(prolog_pre_header, tprint("%.prol.preheader", vname(header)));
        prolog_exit = split_block(prolog_pre_header, block_terminator(prolog_pre_header), dt, li);
        set_name(prolog_exit, tprint("%.prol.loopexit", vname(header)));
        new_pre_header = split_block(prolog_exit, block_terminator(prolog_exit), dt, li);
        set_name(new_pre_header, tprint("%.new", vname(pre_header)));
    }

    pre_header_br = block_terminator(pre_header);
    b: Irb; irb_set_before(*b, pre_header_br);
    trip_count := sx_expand_code_for_at(*expander, trip_count_sc, sc_type(trip_count_sc), pre_header_br);
    be_count: Value_Id;
    if (other_exits.count || !sc_loop_has_no_abnormal_exits(l)) && !is_guaranteed_not_to_be_undef_or_poison(trip_count, ac, pre_header_br, dt) {
        trip_count = irb_freeze(*b, trip_count);
        be_count = irb_binop(*b, .ADD, trip_count, cf_all_ones(vtype(trip_count)));
    } else {
        be_count = sx_expand_code_for_at(*expander, be_count_sc, sc_type(be_count_sc), pre_header_br);
    }
    mod_val := create_trip_remainder(*b, be_count, trip_count, count);
    branch_val: Value_Id;
    if use_epilog_remainder branch_val = irb_icmp(*b, ICMP_ULT, be_count, const_int(vtype(be_count), cast(u64) (count - 1)));
    else branch_val = irb_icmp(*b, ICMP_NE, mod_val, const_null_value(vtype(mod_val)), "lcmp.mod");
    remainder_loop_bb := ifx use_epilog_remainder then epilog_pre_header else prolog_pre_header;
    unrolling_loop := ifx use_epilog_remainder then new_pre_header else prolog_exit;
    guard := irb_cond_br(*b, branch_val, remainder_loop_bb, unrolling_loop);
    if (bprob_is_unknown(original_loop_prob) || !use_epilog_remainder) && prof_has_branch_weight_md(block_terminator(latch))
        prof_set_branch_weights(guard, EPILOG_HEADER_WEIGHTS, false);
    if !bprob_is_unknown(original_loop_prob) && use_epilog_remainder
        set_cond_br_probability(guard, bprob_pow(original_loop_prob, count - 1), false);
    erase_inst_with_metadata(pre_header_br);
    if dt {
        if use_epilog_remainder dt_change_idom(dt, epilog_pre_header, pre_header);
        else dt_change_idom(dt, prolog_exit, pre_header);
    }
    f := block_fn(header);
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);

    new_blocks: [..] Value_Id; new_blocks.allocator = temp;
    vm: Value_Map; vmap_init(*vm);
    insert_bot := ifx use_epilog_remainder then latch_exit else prolog_exit;
    insert_top := ifx use_epilog_remainder then epilog_pre_header else prolog_pre_header;
    remainder_loop := clone_loop_blocks_remainder(li, l, mod_val, use_epilog_remainder, unroll_remainder, insert_top, insert_bot,
                                                  new_pre_header, *new_blocks, rpo, *vm, dt, count, has_otc, original_trip_count,
                                                  original_loop_prob);
    fn_splice_blocks(f, insert_bot, new_blocks[0]);

    for bb: other_exits {
        for pn: block_insts(bb) {
            if !is_phi(pn) break;
            old_n := phi_num_incoming(pn);
            for i: 0..cast(s64) old_n - 1 {
                pred_bb := phi_block(pn, cast(u32) i);
                if pred_bb == latch continue;
                if !li_contains(li, l, pred_bb) continue;
                v := phi_value(pn, cast(u32) i);
                if is_inst(v) && li_contains_inst(li, l, v) v = vmap_lookup(*vm, v);
                phi_add_incoming(pn, v, vmap_get(*vm, pred_bb));
            }
        }
    }

    if dt && li_exiting_block(li, l) == NONE {
        to_update: [..] Value_Id; to_update.allocator = temp;
        kids: [..] Value_Id; kids.allocator = temp;
        for bb: li_blocks(li, l) {
            dt_child_blocks(dt, bb, *kids);
            for c: kids {
                cl := li_loop_for(li, c);
                if !(cl != NONE && li_contains_loop(li, l, cl)) && block_unique_predecessor(c) != bb array_add(*to_update, c);
            }
        }
        for to_update dt_change_idom(dt, it, pre_header);
    }

    for bb: new_blocks for i: block_insts(bb) {
        remap_instruction(*vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        remap_dbg_record_range(*vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
    }

    if use_epilog_remainder {
        connect_epilog(li, l, mod_val, new_exit, latch_exit, pre_header, epilog_pre_header, new_pre_header, *vm, dt, preserve_lcssa,
                       count, ac, original_loop_prob);
        b2: Irb; irb_set_before(*b2, block_terminator(new_pre_header));
        test_val := irb_binop(*b2, .SUB, trip_count, mod_val, "unroll_iter");
        lbr := block_terminator(latch);
        new_idx := create_phi(vtype(test_val), 2);
        insert_at_position(new_idx, header, block_first_non_phi(header), true);
        set_name(new_idx, "niter");
        irb_set_before(*b2, lbr);
        zero := const_int(vtype(new_idx), 0);
        one := const_int(vtype(new_idx), 1);
        idx_next := irb_binop(*b2, .ADD, new_idx, one, tprint("%.next", vname(new_idx)));
        pred := ifx get_successor(lbr, 0) == header then ICMP_NE else ICMP_EQ;
        idx_cmp := irb_icmp(*b2, cast(u8) pred, idx_next, test_val, tprint("%.ncmp", vname(new_idx)));
        phi_add_incoming(new_idx, zero, new_pre_header);
        phi_add_incoming(new_idx, idx_next, latch);
        set_op(lbr, 0, idx_cmp);
    } else {
        connect_prolog(li, l, be_count, count, prolog_exit, latch_exit, pre_header, new_pre_header, *vm, dt, preserve_lcssa);
    }

    sc_forget_topmost_loop(l);

    if count == 2 && dt && li {
        remainder_latch := li_loop_latch(li, remainder_loop);
        remainder_blocks: [..] Value_Id; remainder_blocks.allocator = temp;
        for li_blocks(li, remainder_loop) array_add(*remainder_blocks, it);
        break_loop_backedge(remainder_loop, dt, li, null);
        remainder_loop = NONE;
        dead: [..] Value_Id; dead.allocator = temp;
        for bb: remainder_blocks {
            for :early_inc i: block_insts(bb) {
                q: Simplify_Query; q.dt = dt; q.ac = ac; q.have_tli = false;
                v := simplify_instruction(i, q);
                if v != NONE && li_replacement_preserves_lcssa_form(li, i, v) rauw_with_metadata(i, v);
                if is_trivially_dead_no_tli(i) array_add(*dead, i);
            }
            delete_dead_worklist_no_tli(*dead);
        }
        exit_bb := block_get_single_successor(remainder_latch);
        merge_block_into_predecessor(exit_bb, dt, li, null);
    }

    if other_exits.count > 0 {
        form_dedicated_exit_blocks(li, l, dt, null, preserve_lcssa);
        if remainder_loop != NONE form_dedicated_exit_blocks(li, remainder_loop, dt, null, preserve_lcssa);
    }

    unroll_result := Loop_Unroll_Result.UNMODIFIED;
    if remainder_loop != NONE && unroll_remainder {
        ulo: Unroll_Loop_Options;
        ulo.count = count - 1;
        ulo.force = false;
        ulo.runtime = false;
        ulo.allow_expensive_trip_count = false;
        ulo.unroll_remainder = false;
        ulo.forget_all_scev = forget_all_scev;
        unroll_result = unroll_loop(li, remainder_loop, ulo, dt, ac, t, preserve_lcssa, null, false);
    }
    if result_loop && unroll_result != .FULLY_UNROLLED result_loop.* = remainder_loop;
    return true;
}
