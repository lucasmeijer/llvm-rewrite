// LoopFusion (loop-fusion): port of llvm/lib/Transforms/Scalar/LoopFuse.cpp. Adjacent loops on the same nesting
// level with the same trip count (after optionally peeling the first one) and no dependence that forbids it are
// fused into one loop. The code motion checks are code_mover_utils.jai; the dependence tests come from
// dependence_analysis.jai. Optimization remarks are not emitted.

lfu_cl: struct {
    peel_max_count: u32 = 0;   // -loop-fusion-peel-max-count
};

lfu_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name != "loop-fusion-peel-max-count" return false;
    if !has_value fatal("opt: for the --% option: requires a value!", name);
    v, ok, rest := string_to_int(value);
    if !ok || rest.count || v < 0 || v > 0xFFFF_FFFF fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
    lfu_cl.peel_max_count = cast(u32) v;
    return true;
}

// FusionCandidate
Fusion_Candidate :: struct {
    preheader: Value_Id = NONE;
    header: Value_Id = NONE;
    exiting_block: Value_Id = NONE;
    exit_block: Value_Id = NONE;
    latch: Value_Id = NONE;
    l: Loop_Id = NONE;
    mem_reads: [..] Value_Id;
    mem_writes: [..] Value_Id;
    valid: bool;
    guard_branch: Value_Id = NONE;
    peel_count: u32;   // PP.PeelCount (the rest of the peeling preferences is never read)
    able_to_peel: bool;
    peeled: bool;
}

// FusionCandidate::FusionCandidate
lfu_make_candidate :: (li: *Loop_Info, l: Loop_Id, peel_count: u32 = 0) -> Fusion_Candidate {
    fc: Fusion_Candidate;
    fc.preheader = li_loop_preheader(li, l);
    fc.header = li_header(li, l);
    fc.exiting_block = li_exiting_block(li, l);
    fc.exit_block = li_exit_block(li, l);
    fc.latch = li_loop_latch(li, l);
    fc.l = l;
    fc.valid = true;
    fc.guard_branch = li_loop_guard_branch(li, l);
    fc.peel_count = peel_count;
    fc.able_to_peel = can_peel(li, l);
    fc.peeled = false;
    fc.mem_reads.allocator = temp; fc.mem_writes.allocator = temp;
    for bb: li_blocks(li, l) {
        if block_has_address_taken(bb) { lfu_invalidate(*fc); return fc; }
        for i: block_insts(bb) {
            if may_throw(i) || is_volatile(i) || inst_is_atomic(i) { lfu_invalidate(*fc); return fc; }
            if may_write_to_memory(i) array_add(*fc.mem_writes, i);
            if may_read_from_memory(i) array_add(*fc.mem_reads, i);
        }
    }
    return fc;
}
lfu_invalidate :: (fc: *Fusion_Candidate) { fc.mem_writes.count = 0; fc.mem_reads.count = 0; fc.valid = false; }

lfu_is_valid :: (fc: *Fusion_Candidate) -> bool {
    return fc.preheader != NONE && fc.exiting_block != NONE && fc.exit_block != NONE && fc.latch != NONE && fc.l != NONE && fc.valid;
}
lfu_entry_block :: (fc: *Fusion_Candidate) -> Value_Id {
    if fc.guard_branch != NONE return inst_block(fc.guard_branch);
    return fc.preheader;
}
lfu_update_after_peeling :: (fc: *Fusion_Candidate, li: *Loop_Info) {
    fc.preheader = li_loop_preheader(li, fc.l);
    fc.header = li_header(li, fc.l);
    fc.exiting_block = li_exiting_block(li, fc.l);
    fc.exit_block = li_exit_block(li, fc.l);
    fc.latch = li_loop_latch(li, fc.l);
}
lfu_non_loop_block :: (fc: *Fusion_Candidate) -> Value_Id {
    if fc.peeled return get_successor(fc.guard_branch, 1);
    return ifx get_successor(fc.guard_branch, 0) == fc.preheader then get_successor(fc.guard_branch, 1) else get_successor(fc.guard_branch, 0);
}
// isEligibleForFusion
lfu_is_eligible_for_fusion :: (fc: *Fusion_Candidate, li: *Loop_Info) -> bool {
    if !lfu_is_valid(fc) return false;
    if !sc_has_loop_invariant_backedge_taken_count(fc.l) return false;
    if !li_is_loop_simplify_form(li, fc.l) return false;
    if !li_is_rotated_form(li, fc.l) return false;
    return true;
}

// DomTreeUpdater(DT, PDT, Lazy)
Lfu_Dtu :: struct {
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    pending: [..] Dom_Update;
    deleted: [..] Value_Id;
}
lfu_dtu_apply :: (d: *Lfu_Dtu, updates: [] Dom_Update) {
    for updates if it.from != it.to array_add(*d.pending, it);
}
lfu_dtu_delete_bb :: (d: *Lfu_Dtu, bb: Value_Id) {
    for d.deleted if it == bb return;
    validate_delete_bb(bb);
    array_add(*d.deleted, bb);
}
lfu_dtu_flush :: (d: *Lfu_Dtu) {
    if d.pending.count {
        dt_apply_updates(d.dt, d.pending);
        dt_apply_updates(d.pdt, d.pending);
        d.pending.count = 0;
    }
    for d.deleted {
        if dt_node(d.dt, it) >= 0 dt_erase_node(d.dt, it);
        if dt_node(d.pdt, it) >= 0 dt_erase_node(d.pdt, it);
        block_erase_from_parent(it);
    }
    d.deleted.count = 0;
}

Loop_Fuser :: struct {
    li: *Loop_Info;
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    ac: *Assumption_Cache;
    di: *Da_Info;
    dtu: Lfu_Dtu;
    // LoopDepthTree
    levels: [..] [..] Loop_Id;
    removed: [..] Loop_Id;
    candidates: [..] [..] Fusion_Candidate;   // FusionCandidateCollection
}

lfu_is_removed_loop :: (f: *Loop_Fuser, l: Loop_Id) -> bool { for f.removed if it == l return true; return false; }

// fuseLoops
lfu_fuse_loops :: (f: *Loop_Fuser) -> bool {
    changed := false;
    // LoopDepthTree(LI): the top-level loops in reverse LoopInfo order
    if f.li.top_level.count {
        lv: [..] Loop_Id; lv.allocator = temp;
        for < f.li.top_level array_add(*lv, it);
        array_add(*f.levels, lv);
    }
    while f.levels.count - f.removed.count != 0 {
        for lv: f.levels {
            if lv.count == 1 continue;
            lfu_collect_fusion_candidates(f, lv);
            changed |= lfu_fuse_candidates(f);
            f.candidates.count = 0;
        }
        // descend
        next: [..] [..] Loop_Id; next.allocator = temp;
        for lv: f.levels for l: lv {
            if lfu_is_removed_loop(f, l) || f.li.loops[l].subloops.count == 0 continue;
            sub: [..] Loop_Id; sub.allocator = temp;
            for f.li.loops[l].subloops array_add(*sub, it);
            array_add(*next, sub);
        }
        f.levels = next;
        f.removed.count = 0;
    }
    return changed;
}

// collectFusionCandidates
lfu_collect_fusion_candidates :: (f: *Loop_Fuser, lv: [] Loop_Id) {
    for l: lv {
        cur := lfu_make_candidate(f.li, l);
        if !lfu_is_eligible_for_fusion(*cur, f.li) continue;
        found := false;
        for * list: f.candidates {
            if lfu_is_strictly_adjacent(f, *list.*[list.count - 1], *cur) {
                array_add(list, cur);
                found = true;
                break;
            }
        }
        if !found {
            nl: [..] Fusion_Candidate; nl.allocator = temp;
            array_add(*nl, cur);
            array_add(*f.candidates, nl);
        }
    }
}

// calculateTripCountDiff: (has_value, difference)
lfu_calculate_trip_count_diff :: (fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> (bool, s64) {
    tc0 := sc_get_backedge_taken_count(fc0.l);
    if sc_is_cnc(tc0) return false, 0;
    tc1 := sc_get_backedge_taken_count(fc1.l);
    if sc_is_cnc(tc1) return false, 0;
    if tc0 == tc1 return true, 0;
    c0 := cast(s64) sc_get_small_constant_trip_count(fc0.l);
    c1 := cast(s64) sc_get_small_constant_trip_count(fc1.l);
    if c0 == 0 || c1 == 0 return false, 0;
    return true, c0 - c1;
}

// peelFusionCandidate
lfu_peel_fusion_candidate :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate, peel_count: u32) {
    vm: Value_Map;
    vmap_init(*vm);
    peel_loop(f.li, fc0.l, peel_count, false, f.dt, f.ac, false, *vm);
    fc0.peeled = true;
    fc0.peel_count += peel_count;
    dt_recalculate(f.pdt, inst_fn(block_terminator(fc0.preheader)));
    lfu_update_after_peeling(fc0, f.li);
    bb := ifx fc0.guard_branch != NONE then block_unique_successor(fc0.exit_block) else fc1.preheader;
    if bb != NONE {
        updates: [..] Dom_Update; updates.allocator = temp;
        work: [..] Value_Id; work.allocator = temp;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds {
            if p != fc0.exit_block {
                array_add(*work, block_terminator(p));
                array_add(*updates, .{false, p, bb});
            }
        }
        for cur: work {
            succ := get_successor(cur, 0);
            if succ == bb succ = get_successor(cur, 1);
            replace_inst_with_inst(cur, create_br(succ));
        }
        lfu_dtu_apply(*f.dtu, updates);
        lfu_dtu_flush(*f.dtu);
    }
}

// fuseCandidates
lfu_fuse_candidates :: (f: *Loop_Fuser) -> bool {
    fused := false;
    for * list_p: f.candidates {
        list := list_p;
        if list.count < 2 continue;
        it := 0;
        while it + 1 < list.count {
            fc0 := *list.*[it];
            fc1 := *list.*[it + 1];
            has_diff, diff := lfu_calculate_trip_count_diff(fc0, fc1);
            will_peel := fc0.able_to_peel && has_diff && diff > 0 && diff <= cast(s64) lfu_cl.peel_max_count;
            skip := false;
            if !will_peel && (!has_diff || diff != 0) skip = true;
            else if (fc0.guard_branch == NONE) != (fc1.guard_branch == NONE) skip = true;
            else if (!has_diff || diff == 0) && fc0.guard_branch != NONE && fc1.guard_branch != NONE && !lfu_have_identical_guards(fc0, fc1) skip = true;
            else if fc0.guard_branch != NONE &&
                    (!cmu_is_safe_to_move_block_before(fc0.exit_block, block_first_non_phi_or_dbg(fc1.exit_block), f.dt, f.pdt, f.di) ||
                     !cmu_is_safe_to_move_block_before(inst_block(fc1.guard_branch), block_terminator(inst_block(fc0.guard_branch)), f.dt, f.pdt, f.di))
                skip = true;
            else if !lfu_dependences_allow_fusion(f, fc0, fc1) skip = true;
            safe_to_hoist: [..] Value_Id; safe_to_hoist.allocator = temp;
            safe_to_sink: [..] Value_Id; safe_to_sink.allocator = temp;
            if !skip && block_size(fc1.preheader) != 1 {
                if !lfu_collect_movable_preheader_insts(f, fc0, fc1, *safe_to_hoist, *safe_to_sink) skip = true;
            }
            if skip { it += 1; continue; }
            lfu_move_preheader_insts(fc0, fc1, safe_to_hoist, safe_to_sink);
            fc0_copy := fc0.*;
            peel := has_diff && diff > 0;
            if peel lfu_peel_fusion_candidate(f, *fc0_copy, fc1, cast(u32) diff);
            fused_loop := lfu_perform_fusion(f, ifx peel then *fc0_copy else fc0, fc1);
            fused_cand := lfu_make_candidate(f.li, fused_loop, fc0_copy.peel_count);
            array_add(*f.removed, fc1.l);
            // erase It, erase It, insert the fused candidate at It; NextIt = It
            list.*[it] = fused_cand;
            for k: it + 1..list.count - 2 list.*[k] = list.*[k + 1];
            list.count -= 1;
            fused = true;
        }
    }
    return fused;
}

// canHoistInst
lfu_can_hoist_inst :: (f: *Loop_Fuser, i: Value_Id, safe_to_hoist: [] Value_Id, not_hoisting: [] Value_Id, fc0: *Fusion_Candidate) -> bool {
    target := block_single_successor(fc0.preheader);
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if !is_inst(o) continue;
        hoisted := false;
        for safe_to_hoist if it == o { hoisted = true; break; }
        if !(hoisted || dt_dominates_inst_block(f.dt, o, target)) return false;
    }
    if inst_op(i) == .PHI return false;
    if !may_read_or_write_memory(i) return true;
    for nh: not_hoisting {
        d := da_depends(f.di, i, nh);
        if d && (dep_is_flow(d) || dep_is_anti(d) || dep_is_output(d)) return false;
    }
    for r: fc0.mem_reads {
        d := da_depends(f.di, r, i);
        if d && dep_is_anti(d) return false;
    }
    for w: fc0.mem_writes {
        d := da_depends(f.di, w, i);
        if d && (dep_is_flow(d) || dep_is_output(d)) return false;
    }
    return true;
}

// canSinkInst
lfu_can_sink_inst :: (f: *Loop_Fuser, i: Value_Id, fc1: *Fusion_Candidate) -> bool {
    for u: sx_users(i) if is_inst(u) && li_contains(f.li, fc1.l, inst_block(u)) return false;
    if !may_read_or_write_memory(i) return true;
    for r: fc1.mem_reads {
        d := da_depends(f.di, i, r);
        if d && dep_is_flow(d) return false;
    }
    for w: fc1.mem_writes {
        d := da_depends(f.di, i, w);
        if d && (dep_is_output(d) || dep_is_anti(d)) return false;
    }
    return true;
}

// collectMovablePreheaderInsts
lfu_collect_movable_preheader_insts :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate,
                                        safe_to_hoist: *[..] Value_Id, safe_to_sink: *[..] Value_Id) -> bool {
    ph := fc1.preheader;
    not_hoisting: [..] Value_Id; not_hoisting.allocator = temp;
    t := block_terminator(ph);
    for i: block_insts(ph) {
        if i == t continue;
        if may_throw(i) || !will_return(i) return false;
        if inst_is_atomic(i) || is_volatile(i) return false;
        if lfu_can_hoist_inst(f, i, safe_to_hoist.*, not_hoisting, fc0) array_add(safe_to_hoist, i);
        else {
            array_add(*not_hoisting, i);
            if lfu_can_sink_inst(f, i, fc1) array_add(safe_to_sink, i);
            else return false;
        }
    }
    return true;
}

// dependencesAllowFusion(FC0, FC1, I0, I1)
lfu_dependences_allow_fusion_pair :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate, i0: Value_Id, i1: Value_Id) -> bool {
    d := da_depends(f.di, i0, i1);
    if !d return true;
    levels := dep_levels(d);
    same_sd_levels := dep_same_sd_levels(d);
    cur := cast(s64) li_depth(f.li, fc0.l);
    if cur > levels + same_sd_levels return false;
    for level: 1..min(cur - 1, levels) {
        if !(dep_direction(d, level, false) & DV_EQ) return true;
    }
    if dep_is_scalar(d, cur, true) {
        if dep_is_input(d) || dep_is_output(d) return true;
        return false;
    }
    if !(dep_direction(d, cur, true) & DV_GT) return true;
    return false;
}

// dependencesAllowFusion(FC0, FC1)
lfu_dependences_allow_fusion :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> bool {
    for bb: li_blocks(f.li, fc1.l) for i: block_insts(bb) for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if is_inst(o) && li_contains(f.li, fc0.l, inst_block(o)) return false;
    }
    for w0: fc0.mem_writes {
        for w1: fc1.mem_writes if !lfu_dependences_allow_fusion_pair(f, fc0, fc1, w0, w1) return false;
        for r1: fc1.mem_reads if !lfu_dependences_allow_fusion_pair(f, fc0, fc1, w0, r1) return false;
    }
    for r0: fc0.mem_reads for w1: fc1.mem_writes if !lfu_dependences_allow_fusion_pair(f, fc0, fc1, r0, w1) return false;
    return true;
}

// isStrictlyAdjacent
lfu_is_strictly_adjacent :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> bool {
    if fc0.guard_branch != NONE
        return dt_dominates(f.dt, lfu_entry_block(fc0), lfu_entry_block(fc1)) && block_single_successor(fc0.exit_block) == lfu_entry_block(fc1);
    return fc0.exit_block == lfu_entry_block(fc1);
}

// movePreheaderInsts
lfu_move_preheader_insts :: (fc0: *Fusion_Candidate, fc1: *Fusion_Candidate, hoist: [] Value_Id, sink: [] Value_Id) {
    for i: hoist inst_move_before_dbg(i, block_terminator(fc0.preheader));   // moveBefore(BB, terminator iterator)
    for < i: sink {
        if inst_op(i) == .PHI {
            replace_all_uses_with(i, op(i, 0));
            erase_inst_with_metadata(i);
        } else inst_move_before_at(i, block_first_insertion_pt(fc1.exit_block), true);
    }
}

// haveIdenticalGuards
lfu_have_identical_guards :: (fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> bool {
    c0 := op(fc0.guard_branch, 0); c1 := op(fc1.guard_branch, 0);
    i0 := is_inst(c0); i1 := is_inst(c1);
    if (!i0 || !i1) && c0 != c1 return false;
    if i0 && i1 && !is_identical_to(c0, c1) return false;
    if get_successor(fc0.guard_branch, 0) == fc0.preheader return get_successor(fc1.guard_branch, 0) == fc1.preheader;
    return get_successor(fc1.guard_branch, 1) == fc1.preheader;
}

// simplifyLatchBranch
lfu_simplify_latch_branch :: (fc: *Fusion_Candidate) {
    br := block_terminator(fc.latch);
    if inst_op(br) == .CONDBR replace_inst_with_inst(br, create_br(get_successor(br, 0)));
}

// mergeLatch
lfu_merge_latch :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) {
    cmu_move_instructions_to_the_beginning(fc0.latch, fc1.latch, f.dt, f.pdt, f.di);
    succ := block_unique_successor(fc0.latch);
    if succ != NONE {
        // MergeBlockIntoPredecessor(Succ, &DTU, &LI): the lazy updates go to both trees
        lazy: Lazy_Dtu; lazy.dt = f.dt;
        lazy.pending.allocator = temp; lazy.deleted.allocator = temp;
        merge_block_into_predecessor(succ, f.dt, f.li, null, false, *lazy);
        for lazy.pending array_add(*f.dtu.pending, it);
        for lazy.deleted array_add(*f.dtu.deleted, it);
        lfu_dtu_flush(*f.dtu);
    }
}

// rewireFusedHeaderPHIsAndLatches
lfu_rewire_fused_header_phis_and_latches :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate, original_fc0_phis: [] Value_Id, updates: *[..] Dom_Update) {
    while true {
        phi := block_first(fc1.header);
        if phi == NONE || inst_op(phi) != .PHI break;
        if sc_is_scevable(vtype(phi)) sc_forget_value(phi);
        if has_uses(phi) inst_move_before_at(phi, block_first_insertion_pt(fc0.header), true);
        else erase_inst_with_metadata(phi);
    }
    l1_header_ip := block_first(fc1.header);   // FC1.Header->begin() (head bit)
    for lcphi: original_fc0_phis {
        idx := phi_block_index(lcphi, fc1.latch);
        assert(idx >= 0);
        lcv := phi_value(lcphi, cast(u32) idx);
        p := create_phi(vtype(lcv), 2);
        insert_at_position(p, fc1.header, l1_header_ip, true);
        set_name(p, tconcat(vname(lcphi), ".afterFC0"));
        phi_add_incoming(p, lcv, fc0.latch);
        phi_add_incoming(p, const_poison(vtype(lcv)), fc0.exiting_block);
        phi_set_value(lcphi, cast(u32) idx, p);
    }
    replace_uses_of_with(block_terminator(fc0.latch), fc0.header, fc1.header);
    replace_uses_of_with(block_terminator(fc1.latch), fc1.header, fc0.header);
    lfu_simplify_latch_branch(fc0);
    if fc0.latch != fc0.exiting_block array_add(updates, .{true, fc0.latch, fc1.header});
    array_add(updates, .{false, fc0.latch, fc0.header});
    array_add(updates, .{true, fc1.latch, fc0.header});
    array_add(updates, .{false, fc1.latch, fc1.header});
}

// finalizeFusedLoop
lfu_finalize_fused_loop :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> Loop_Id {
    li := f.li;
    sc_forget_loop(fc1.l);
    sc_forget_loop(fc0.l);
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, fc1.l) array_add(*blocks, it);
    for bb: blocks {
        li_add_block_entry(li, fc0.l, bb);
        li_remove_block_from_loop(li, fc1.l, bb);
        if li_loop_for(li, bb) != fc1.l continue;
        li_change_loop_for(li, bb, fc0.l);
    }
    while li.loops[fc1.l].subloops.count {
        child := li.loops[fc1.l].subloops[0];
        li_remove_child_loop(li, fc1.l, child);
        li_add_child_loop(li, fc0.l, child);
    }
    li_erase(li, fc1.l);
    sc_forget_block_and_loop_dispositions();
    lfu_merge_latch(f, fc0, fc1);
    return fc0.l;
}

// performFusion
lfu_perform_fusion :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> Loop_Id {
    cmu_move_instructions_to_the_end(fc1.preheader, fc0.preheader, f.dt, f.pdt, f.di);
    if fc0.guard_branch != NONE return lfu_fuse_guarded_loops(f, fc0, fc1);
    original_fc0_phis: [..] Value_Id; original_fc0_phis.allocator = temp;
    if fc0.exiting_block != fc0.latch
        for p: block_insts(fc0.header) { if inst_op(p) != .PHI break; array_add(*original_fc0_phis, p); }
    block_replace_successors_phi_uses_with(fc1.preheader, fc1.preheader, fc0.preheader);
    block_replace_successors_phi_uses_with(fc0.latch, fc0.latch, fc1.latch);
    updates: [..] Dom_Update; updates.allocator = temp;
    if !fc0.peeled {
        replace_uses_of_with(block_terminator(fc0.exiting_block), fc1.preheader, fc1.header);
        array_add(*updates, .{false, fc0.exiting_block, fc1.preheader});
        array_add(*updates, .{true, fc0.exiting_block, fc1.header});
    } else {
        array_add(*updates, .{false, fc0.exit_block, fc1.preheader});
        replace_uses_of_with(block_terminator(fc0.exiting_block), fc0.exit_block, fc1.header);
        array_add(*updates, .{false, fc0.exiting_block, fc0.exit_block});
        erase_inst_with_metadata(block_terminator(fc0.exit_block));
        array_add(*updates, .{true, fc0.exiting_block, fc1.header});
        block_append_inst(fc0.exit_block, new_inst(.UNREACHABLE, ir.t_void, 0));
    }
    erase_inst_with_metadata(block_terminator(fc1.preheader));
    block_append_inst(fc1.preheader, new_inst(.UNREACHABLE, ir.t_void, 0));
    array_add(*updates, .{false, fc1.preheader, fc1.header});
    lfu_rewire_fused_header_phis_and_latches(f, fc0, fc1, original_fc0_phis, *updates);
    lfu_dtu_apply(*f.dtu, updates);
    li_remove_block(f.li, fc1.preheader);
    lfu_dtu_delete_bb(*f.dtu, fc1.preheader);
    if fc0.peeled {
        li_remove_block(f.li, fc0.exit_block);
        lfu_dtu_delete_bb(*f.dtu, fc0.exit_block);
    }
    lfu_dtu_flush(*f.dtu);
    return lfu_finalize_fused_loop(f, fc0, fc1);
}

// fuseGuardedLoops
lfu_fuse_guarded_loops :: (f: *Loop_Fuser, fc0: *Fusion_Candidate, fc1: *Fusion_Candidate) -> Loop_Id {
    fc0_guard_block := inst_block(fc0.guard_branch);
    fc1_guard_block := inst_block(fc1.guard_branch);
    fc0_non_loop_block := lfu_non_loop_block(fc0);
    fc1_non_loop_block := lfu_non_loop_block(fc1);
    fc0_exit_block_successor := block_unique_successor(fc0.exit_block);
    cmu_move_instructions_to_the_beginning(ifx fc0.peeled then fc0_exit_block_successor else fc0.exit_block, fc1.exit_block, f.dt, f.pdt, f.di);
    cmu_move_instructions_to_the_end(fc1_guard_block, fc0_guard_block, f.dt, f.pdt, f.di);
    updates: [..] Dom_Update; updates.allocator = temp;
    block_replace_phi_uses_with(fc1_non_loop_block, fc1_guard_block, fc0_guard_block);
    replace_uses_of_with(fc0.guard_branch, fc0_non_loop_block, fc1_non_loop_block);
    bb_to_update := ifx fc0.peeled then fc0_exit_block_successor else fc0.exit_block;
    replace_uses_of_with(block_terminator(bb_to_update), fc1_guard_block, fc1.header);
    erase_inst_with_metadata(fc1.guard_branch);
    block_append_inst(fc1_guard_block, new_inst(.UNREACHABLE, ir.t_void, 0));
    array_add(*updates, .{false, fc1_guard_block, fc1.preheader});
    array_add(*updates, .{false, fc1_guard_block, fc1_non_loop_block});
    array_add(*updates, .{false, fc0_guard_block, fc1_guard_block});
    array_add(*updates, .{true, fc0_guard_block, fc1_non_loop_block});
    if fc0.peeled {
        array_add(*updates, .{false, fc0.exit_block, fc0_exit_block_successor});
        array_add(*updates, .{false, fc0_exit_block_successor, fc1_guard_block});
        erase_inst_with_metadata(block_terminator(fc0_exit_block_successor));
        block_append_inst(fc0_exit_block_successor, new_inst(.UNREACHABLE, ir.t_void, 0));
    }
    original_fc0_phis: [..] Value_Id; original_fc0_phis.allocator = temp;
    if fc0.exiting_block != fc0.latch
        for p: block_insts(fc0.header) { if inst_op(p) != .PHI break; array_add(*original_fc0_phis, p); }
    block_replace_successors_phi_uses_with(fc1.preheader, fc1.preheader, fc0.preheader);
    block_replace_successors_phi_uses_with(fc0.latch, fc0.latch, fc1.latch);
    replace_uses_of_with(block_terminator(fc0.exiting_block), fc0.exit_block, fc1.header);
    array_add(*updates, .{false, fc0.exiting_block, fc0.exit_block});
    array_add(*updates, .{true, fc0.exiting_block, fc1.header});
    erase_inst_with_metadata(block_terminator(fc0.exit_block));
    block_append_inst(fc0.exit_block, new_inst(.UNREACHABLE, ir.t_void, 0));
    erase_inst_with_metadata(block_terminator(fc1.preheader));
    block_append_inst(fc1.preheader, new_inst(.UNREACHABLE, ir.t_void, 0));
    array_add(*updates, .{false, fc1.preheader, fc1.header});
    lfu_rewire_fused_header_phis_and_latches(f, fc0, fc1, original_fc0_phis, *updates);
    lfu_dtu_apply(*f.dtu, updates);
    li_remove_block(f.li, fc1_guard_block);
    li_remove_block(f.li, fc1.preheader);
    li_remove_block(f.li, fc0.exit_block);
    if fc0.peeled {
        li_remove_block(f.li, fc0_exit_block_successor);
        lfu_dtu_delete_bb(*f.dtu, fc0_exit_block_successor);
    }
    lfu_dtu_delete_bb(*f.dtu, fc1_guard_block);
    lfu_dtu_delete_bb(*f.dtu, fc1.preheader);
    lfu_dtu_delete_bb(*f.dtu, fc0.exit_block);
    lfu_dtu_flush(*f.dtu);
    return lfu_finalize_fused_loop(f, fc0, fc1);
}

// LoopFusePass::run
loop_fuse_run :: (fn: Value_Id) -> Preserved {
    li := get_loop_info(fn);
    dt := get_domtree(fn);
    s := get_scev(fn);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    pdt := get_postdomtree(fn);
    ac := get_assumption_cache(fn);
    changed := false;
    // `for (auto &L : LI)`: L is the TopLevelLoops slot (see knowledge/llvm/loop-extras.md, IRCE)
    n := li.top_level.count;
    for i: 0..n - 1 {
        se = s;
        changed |= simplify_loop(li, li.top_level[i], dt, ac, null, false);
    }
    se = s;
    if changed dt_recalculate(pdt, fn);
    f: Loop_Fuser;
    f.li = li; f.dt = dt; f.pdt = pdt; f.ac = ac;
    f.di = da_new(fn, li);
    f.dtu.dt = dt; f.dtu.pdt = pdt;
    f.dtu.pending.allocator = temp; f.dtu.deleted.allocator = temp;
    f.levels.allocator = temp; f.removed.allocator = temp; f.candidates.allocator = temp;
    changed |= lfu_fuse_loops(*f);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .POSTDOMTREE);
    preserve(*pa, .SCEV);
    preserve(*pa, .LOOPS);
    return pa;
}
