// LoopUnrollAndJam (loop-unroll-and-jam, a LoopNest pass): port of llvm/lib/Transforms/Scalar/LoopUnrollAndJamPass.cpp
// (tryToUnrollAndJamLoop, computeUnrollAndJamCount, the pragma helpers) and llvm/lib/Transforms/Utils/
// LoopUnrollAndJam.cpp (UnrollAndJamLoop, isSafeToUnrollAndJam and its partition / dependence checks), plus
// MergeBlockSuccessorsIntoGivenBlocks (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp) and
// hasIterationCountInvariantInParent (llvm/lib/Transforms/Utils/LoopUtils.cpp). Optimization remarks are not emitted.
//
// Pointer-ordered sets whose order does not reach the output (knowledge/llvm/loop-extras.md):
// - the BasicBlockSets (SmallPtrSet<BasicBlock *, 4>; pointer order past 4 blocks) are only iterated by the
//   dependence checks, where the order within one set picks which of two accesses is the dependence source, and those
//   pairs are checked with Sequentialized = true, which accepts a pair exactly when it accepts the reversed pair; the
//   loop of the set's first block is the same for every block of the set. The arrays keep insertion order.
// - MergeBlockSuccessorsIntoGivenBlocks (SmallPtrSet<BasicBlock *, 16>) merges chains of single-successor /
//   single-predecessor blocks: the merged blocks, their instruction order and the names they keep are the same in
//   any visiting order. The small-mode order (slot 0, erase moves the last slot in) is simulated for every size.

luj_cl: struct {
    allow_unroll_and_jam: bool; has_allow_unroll_and_jam: bool;    // -allow-unroll-and-jam
    unroll_and_jam_count: u32; has_unroll_and_jam_count: bool;     // -unroll-and-jam-count
    unroll_and_jam_threshold: u32 = 60; has_unroll_and_jam_threshold: bool;   // -unroll-and-jam-threshold
    pragma_unroll_and_jam_threshold: u32 = 1024;                    // -pragma-unroll-and-jam-threshold
};

luj_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_u :: (name: string, value: string, has_value: bool) -> u32 {
        if !has_value fatal("opt: for the --% option: requires a value!", name);
        v, ok, rest := string_to_int(value);
        if !ok || rest.count || v < 0 || v > 0xFFFF_FFFF fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
        return cast(u32) v;
    }
    if name == {
        case "allow-unroll-and-jam";
            luj_cl.has_allow_unroll_and_jam = true;
            if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" luj_cl.allow_unroll_and_jam = true;
            else if value == "false" || value == "0" || value == "FALSE" || value == "False" luj_cl.allow_unroll_and_jam = false;
            else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        case "unroll-and-jam-count"; luj_cl.unroll_and_jam_count = parse_u(name, value, has_value); luj_cl.has_unroll_and_jam_count = true;
        case "unroll-and-jam-threshold"; luj_cl.unroll_and_jam_threshold = parse_u(name, value, has_value); luj_cl.has_unroll_and_jam_threshold = true;
        case "pragma-unroll-and-jam-threshold"; luj_cl.pragma_unroll_and_jam_threshold = parse_u(name, value, has_value);
        case; return false;
    }
    return true;
}

// ---------------------------------------------------------------- BasicBlockSet (insertion-ordered)

Bb_Set :: struct { list: [..] Value_Id; }
bbs_insert :: (s: *Bb_Set, b: Value_Id) { for s.list if it == b return; array_add(*s.list, b); }
bbs_contains :: (s: *Bb_Set, b: Value_Id) -> bool { for s.list if it == b return true; return false; }
// iteration of a SmallPtrSet<BasicBlock *, 4>: insertion order while small
bbs_iter :: (s: *Bb_Set) -> [] Value_Id { return s.list; }

// ---------------------------------------------------------------- partitions

// partitionLoopBlocks
luj_partition_loop_blocks :: (li: *Loop_Info, l: Loop_Id, fore: *Bb_Set, aft: *Bb_Set, dt: *Dom_Tree) -> bool {
    sub := li_subloops(li, l)[0];
    sub_latch := li_loop_latch(li, sub);
    for bb: li_blocks(li, l) {
        if li_contains(li, sub, bb) continue;
        if dt_dominates(dt, sub_latch, bb) bbs_insert(aft, bb);
        else bbs_insert(fore, bb);
    }
    sub_ph := li_loop_preheader(li, sub);
    for bb: fore.list {   // a pure check over the set: order-free
        if bb == sub_ph continue;
        t := block_terminator(bb);
        n := num_successors(t);
        if n > 0 for k: 0..n - 1 if !bbs_contains(fore, get_successor(t, k)) return false;
    }
    return true;
}

Luj_Partition :: struct {
    jam_loop_blocks: Bb_Set;
    loops: [..] Loop_Id;      // the keys of ForeBlocksMap / AftBlocksMap, in preorder
    fore: [..] Bb_Set;
    aft: [..] Bb_Set;
}
luj_partition_index :: (p: *Luj_Partition, l: Loop_Id) -> s64 { for p.loops if it == l return it_index; return -1; }

// partitionOuterLoopBlocks(Root, JamLoop, JamLoopBlocks, ForeBlocksMap, AftBlocksMap, DT)
luj_partition_outer_loop_blocks :: (li: *Loop_Info, root: Loop_Id, jam: Loop_Id, p: *Luj_Partition, dt: *Dom_Tree) -> bool {
    for li_blocks(li, jam) bbs_insert(*p.jam_loop_blocks, it);
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder_of(li, root, *pre);
    for l: pre {
        if l == jam break;
        f: Bb_Set; f.list.allocator = temp;
        a: Bb_Set; a.list.allocator = temp;
        array_add(*p.loops, l); array_add(*p.fore, f); array_add(*p.aft, a);
        k := p.loops.count - 1;
        if !luj_partition_loop_blocks(li, l, *p.fore[k], *p.aft[k], dt) return false;
    }
    return true;
}

// processHeaderPhiOperands(Header, Latch, AftBlocks, Visit): kind 0 = moveHeaderPhiOperandsToForeBlocks,
// 1 = the isSafeToUnrollAndJam check
luj_process_header_phi_operands :: (li: *Loop_Info, header: Value_Id, latch: Value_Id, aft: *Bb_Set, kind: u8, sub: Loop_Id,
                                     insert_loc: Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    process :: (i: Value_Id, li: *Loop_Info, aft: *Bb_Set, kind: u8, sub: Loop_Id, insert_loc: Value_Id, visited: *Table(Value_Id, bool)) -> bool {
        if table_contains(visited, i) return true;
        table_set(visited, i, true);
        if bbs_contains(aft, inst_block(i)) {
            for k: 0..cast(s64) nops(i) - 1 {
                o := op(i, cast(u32) k);
                if is_inst(o) && !process(o, li, aft, kind, sub, insert_loc, visited) return false;
            }
        }
        // Visit(I)
        if kind == 0 {
            if bbs_contains(aft, inst_block(i)) inst_move_before_dbg(i, insert_loc);
            return true;
        }
        if li_contains(li, sub, inst_block(i)) return false;
        if bbs_contains(aft, inst_block(i)) {
            if inst_op(i) == .PHI return false;
            if may_have_side_effects(i) || may_read_or_write_memory(i) return false;
        }
        return true;
    }
    for phi: block_insts(header) {
        if inst_op(phi) != .PHI break;
        v := phi_incoming_value_for_block(phi, latch);
        if is_inst(v) && !process(v, li, aft, kind, sub, insert_loc, *visited) return false;
    }
    return true;
}

// ---------------------------------------------------------------- MergeBlockSuccessorsIntoGivenBlocks

// MergeBlockSuccessorsIntoGivenBlocks(MergeBlocks, L, DTU, LI) with MergeBlocks a SmallPtrSet<BasicBlock *, 16>:
// begin() is slot 0 and erase moves the last slot into the erased one (small mode)
luj_merge_block_successors_into_given_blocks :: (merge: *[..] Value_Id, li: *Loop_Info, l: Loop_Id, lazy: *Lazy_Dtu, dt: *Dom_Tree) -> bool {
    erase :: (s: *[..] Value_Id, b: Value_Id) {
        for s.* if it == b { s.*[it_index] = s.*[s.count - 1]; s.count -= 1; return; }
    }
    merged_any := false;
    while merge.count {
        bb := merge.*[0];
        dest := block_single_successor(bb);
        if dest != NONE && (l == NONE || li_contains(li, l, dest)) {
            if merge_block_into_predecessor(dest, dt, li, null, false, lazy) {
                erase(merge, dest);
                merged_any = true;
            } else erase(merge, bb);
        } else erase(merge, bb);
    }
    return merged_any;
}

// ---------------------------------------------------------------- UnrollAndJamLoop

luj_unroll_and_jam_loop :: (li: *Loop_Info, l_in: Loop_Id, count: u32, trip_count: u32, trip_multiple: u32, unroll_remainder: bool,
                            dt: *Dom_Tree, ac: *Assumption_Cache, t: *Tti) -> Loop_Unroll_Result {
    l := l_in;
    f := li.fn;
    header := li_header(li, l);
    sub := li_subloops(li, l)[0];
    if trip_count == 0 && count < 2 return .UNMODIFIED;
    completely_unroll := count == trip_count;
    if trip_multiple % count != 0 {
        // UnrollRuntimeLoopRemainder(..., SCEVCheapExpansionBudget, EpilogueLoop): the Loop ** lands on the
        // bool RuntimeUnrollMultiExit parameter (true), ResultLoop stays nullptr
        if !unroll_runtime_loop_remainder(li, l, count, false, true, unroll_remainder, false, dt, ac, t, true,
                                          cast(u32) scev_cheap_expansion_budget, true, null, false, 0, BPROB_UNKNOWN)
            return .UNMODIFIED;
    }
    sc_forget_loop(l);
    sc_forget_block_and_loop_dispositions();

    preheader := li_loop_preheader(li, l);
    latch_block := li_loop_latch(li, l);
    bi := block_terminator(latch_block);
    continue_on_true := li_contains(li, l, get_successor(bi, 0));
    loop_exit := get_successor(bi, ifx continue_on_true then cast(u32) 1 else 0);
    sub_continue_on_true := li_contains(li, sub, get_successor(block_terminator(li_loop_latch(li, sub)), 0));

    sub_blocks: Bb_Set; sub_blocks.list.allocator = temp;
    fore_blocks: Bb_Set; fore_blocks.list.allocator = temp;
    aft_blocks: Bb_Set; aft_blocks.list.allocator = temp;
    for li_blocks(li, sub) bbs_insert(*sub_blocks, it);
    luj_partition_loop_blocks(li, l, *fore_blocks, *aft_blocks, dt);

    fore_first: [..] Value_Id; fore_first.allocator = temp;
    fore_last: [..] Value_Id; fore_last.allocator = temp;
    sub_first: [..] Value_Id; sub_first.allocator = temp;
    sub_last: [..] Value_Id; sub_last.allocator = temp;
    aft_first: [..] Value_Id; aft_first.allocator = temp;
    aft_last: [..] Value_Id; aft_last.allocator = temp;
    array_add(*fore_first, header);
    array_add(*fore_last, li_loop_preheader(li, sub));
    array_add(*sub_first, li_header(li, sub));
    array_add(*sub_last, li_exiting_block(li, sub));
    array_add(*aft_first, li_exit_block(li, sub));
    array_add(*aft_last, li_exiting_block(li, l));

    last_value_map: Value_Map; vmap_init(*last_value_map);
    luj_process_header_phi_operands(li, header, latch_block, *aft_blocks, 0, sub, block_terminator(fore_last[0]));

    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);

    if fn_should_emit_debug_info_for_profiling(f) {
        for bb: li_blocks(li, l) for i: block_insts(bb) {
            if is_debug_or_pseudo_inst(i) continue;
            dil := get_metadata(i, 0);
            if dil == NONE continue;
            nd := diloc_clone_by_multiplying_duplication_factor(dil, count);
            if nd != NONE set_metadata(i, 0, nd);
        }
    }

    for it_num: 1..cast(s64) count - 1 {
        new_blocks: [..] Value_Id; new_blocks.allocator = temp;
        prev_it: Table(Value_Id, Value_Id); prev_it.allocator = temp;   // PrevItValueMap
        new_loops: New_Loops_Map; nlm_init(*new_loops);
        nlm_set(*new_loops, l, l);
        nlm_set(*new_loops, sub, sub);
        for bb: rpo {
            vm: Value_Map; vmap_init(*vm);
            nb := clone_basic_block(bb, *vm, tprint(".%", it_num), map_atoms = true);
            fn_insert_detached_block_before(f, NONE, nb);
            add_cloned_block_to_loop_info(li, bb, nb, *new_loops);
            if bbs_contains(*fore_blocks, bb) {
                if bb == fore_first[0] array_add(*fore_first, nb);
                if bb == fore_last[0] array_add(*fore_last, nb);
            } else if bbs_contains(*sub_blocks, bb) {
                if bb == sub_first[0] array_add(*sub_first, nb);
                if bb == sub_last[0] array_add(*sub_last, nb);
            } else if bbs_contains(*aft_blocks, bb) {
                if bb == aft_first[0] array_add(*aft_first, nb);
                if bb == aft_last[0] array_add(*aft_last, nb);
            } else fatal("internal: BB being cloned should be in Fore/Sub/Aft");
            if vm.atoms.count for i: block_insts(nb) atom_remap_source(vm.atoms, i);
            last := vmap_get(*last_value_map, bb);
            table_set(*prev_it, nb, ifx it_num == 1 then bb else last);
            vmap_set(*last_value_map, bb, nb);
            for v, k: vm.map {
                lvm := vmap_get(*last_value_map, k);
                table_set(*prev_it, v, ifx it_num == 1 then k else lvm);
                vmap_set(*last_value_map, k, v);
            }
            array_add(*new_blocks, nb);
            if bb == fore_first[0] dt_add_new_block(dt, nb, fore_last[it_num - 1]);
            else if bb == sub_first[0] dt_add_new_block(dt, nb, sub_last[it_num - 1]);
            else if bb == aft_first[0] dt_add_new_block(dt, nb, aft_last[it_num - 1]);
            else {
                orig_idom := dt_idom_block(dt, bb);
                dt_add_new_block(dt, nb, vmap_get(*last_value_map, orig_idom));
            }
        }
        remap_instructions_in_blocks(new_blocks, *last_value_map);
        for nb: new_blocks for i: block_insts(nb) if call_iid(i) == IID_ASSUME ac_register_assumption(ac, i);
        // the cloned header phis take the previous iteration's values
        for phi: block_insts(fore_first[it_num]) {
            if inst_op(phi) != .PHI break;
            old_value := phi_incoming_value_for_block(phi, aft_last[it_num]);
            new_value := old_value;
            found, prev := table_find(*prev_it, old_value);
            if found && prev != NONE new_value = prev;
            phi_set_block(phi, 0, fore_last[it_num - 1]);
            phi_set_value(phi, 0, new_value);
            phi_remove_incoming(phi, 1);
        }
    }

    update_phi_blocks_and_values :: (bb: Value_Id, old_bb: Value_Id, new_bb: Value_Id, lvm: *Value_Map) {
        for phi: block_insts(bb) {
            if inst_op(phi) != .PHI break;
            for b: 0..cast(s64) nops(phi) - 1 {
                k := cast(u32) b;
                if phi_block(phi, k) == old_bb {
                    last := vmap_get(lvm, phi_value(phi, k));
                    if last != NONE phi_set_value(phi, k, last);
                    phi_set_block(phi, k, new_bb);
                    break;
                }
            }
        }
    }
    move_phis :: (src: Value_Id, dest: Value_Id) {
        pt := block_first_non_phi(dest);   // getFirstNonPHIIt (head bit)
        while true {
            phi := block_first(src);
            if phi == NONE || inst_op(phi) != .PHI break;
            if pt == NONE inst_move_to_end(phi, dest); else inst_move_before_at(phi, pt, true);
        }
    }
    // replace an unconditional or conditional terminator by `br Dest` (UncondBrInst::Create(Dest, Term), erase)
    replace_with_br :: (term: Value_Id, dest: Value_Id) {
        br := create_br(dest);
        insert_at_position(br, inst_block(term), term, false);
        erase_inst_with_metadata(term);
    }

    update_phi_blocks_and_values(loop_exit, aft_last[0], aft_last[aft_last.count - 1], *last_value_map);
    set_successor(block_terminator(fore_last[fore_last.count - 1]), 0, sub_first[0]);
    if completely_unroll {
        while true {
            phi := block_first(fore_first[0]);
            if phi == NONE || inst_op(phi) != .PHI break;
            rauw_with_metadata(phi, phi_incoming_value_for_block(phi, preheader));
            erase_inst_with_metadata(phi);
        }
    } else {
        update_phi_blocks_and_values(fore_first[0], aft_last[0], aft_last[aft_last.count - 1], *last_value_map);
    }
    for it_num: 1..cast(s64) count - 1 set_successor(block_terminator(fore_last[it_num - 1]), 0, fore_first[it_num]);

    sub_term := block_terminator(sub_last[sub_last.count - 1]);
    set_successor(sub_term, ifx sub_continue_on_true then cast(u32) 0 else 1, sub_first[0]);
    set_successor(sub_term, ifx sub_continue_on_true then cast(u32) 1 else 0, aft_first[0]);
    block_replace_phi_uses_with(sub_first[0], fore_last[0], fore_last[fore_last.count - 1]);
    block_replace_phi_uses_with(sub_first[0], sub_last[0], sub_last[sub_last.count - 1]);
    for it_num: 1..cast(s64) count - 1 {
        replace_with_br(block_terminator(sub_last[it_num - 1]), sub_first[it_num]);
        block_replace_phi_uses_with(sub_first[it_num], fore_last[it_num], fore_last[fore_last.count - 1]);
        block_replace_phi_uses_with(sub_first[it_num], sub_last[it_num], sub_last[sub_last.count - 1]);
        move_phis(sub_first[it_num], sub_first[0]);
    }

    aft_term := block_terminator(aft_last[aft_last.count - 1]);
    if completely_unroll replace_with_br(aft_term, loop_exit);
    else set_successor(aft_term, ifx continue_on_true then cast(u32) 0 else 1, fore_first[0]);
    block_replace_phi_uses_with(aft_first[0], sub_last[0], sub_last[sub_last.count - 1]);
    for it_num: 1..cast(s64) count - 1 {
        replace_with_br(block_terminator(aft_last[it_num - 1]), aft_first[it_num]);
        block_replace_phi_uses_with(aft_first[it_num], sub_last[it_num], sub_last[sub_last.count - 1]);
        move_phis(aft_first[it_num], aft_first[0]);
    }

    // DomTreeUpdater DTU(DT, Lazy)
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    if count != 1 {
        ups := Dom_Update.[.{false, fore_last[0], sub_first[0]}, .{false, sub_last[0], aft_first[0]},
                           .{true, fore_last[fore_last.count - 1], sub_first[0]}, .{true, sub_last[sub_last.count - 1], aft_first[0]}];
        dtu_apply_permissive(*dtu, ups);
    }
    merge_blocks: [..] Value_Id; merge_blocks.allocator = temp;
    add_unique :: (s: *[..] Value_Id, b: Value_Id) { for s.* if it == b return; array_add(s, b); }
    for fore_last add_unique(*merge_blocks, it);
    for sub_last add_unique(*merge_blocks, it);
    for aft_last add_unique(*merge_blocks, it);
    lazy: Lazy_Dtu; lazy.dt = dt; lazy.pending.allocator = temp; lazy.deleted.allocator = temp;
    for dtu.pending array_add(*lazy.pending, it);
    luj_merge_block_successors_into_given_blocks(*merge_blocks, li, l, *lazy, dt);
    lazy_dtu_flush(*lazy);   // DTU.getDomTree()

    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, l) array_add(*blocks, it);
    if completely_unroll {
        li_erase(li, l);
        l = NONE;
    }
    sub_blocks_now: [..] Value_Id; sub_blocks_now.allocator = temp;
    for li_blocks(li, sub) array_add(*sub_blocks_now, it);
    simplify_loop_after_unroll(li, sub, true, dt, ac, t, sub_blocks_now, false);
    simplify_loop_after_unroll(li, l, !completely_unroll && count > 1, dt, ac, t, blocks, false);
    return ifx completely_unroll then Loop_Unroll_Result.FULLY_UNROLLED else .PARTIALLY_UNROLLED;
}

// ---------------------------------------------------------------- isSafeToUnrollAndJam

// getLoadsAndStores
luj_get_loads_and_stores :: (blocks: *Bb_Set, out: *[..] Value_Id) -> bool {
    for bb: bbs_iter(blocks) for i: block_insts(bb) {
        o := inst_op(i);
        if o == .LOAD || o == .STORE {
            if inst_is_atomic(i) || is_volatile(i) return false;   // !isSimple()
            array_add(out, i);
        } else if may_read_or_write_memory(i) return false;
    }
    return true;
}

// preservesForwardDependence / preservesBackwardDependence
luj_preserves_forward :: (unroll_level: s64, jam_level: s64, sequentialized: bool, d: *Da_Dependence) -> bool {
    for depth: unroll_level + 1..jam_level {
        dir := dep_direction(d, depth);
        if dir == DV_LT return true;
        if dir & DV_GT return false;
    }
    return true;
}
luj_preserves_backward :: (unroll_level: s64, jam_level: s64, sequentialized: bool, d: *Da_Dependence) -> bool {
    for depth: unroll_level + 1..jam_level {
        dir := dep_direction(d, depth);
        if dir == DV_GT return true;
        if dir & DV_LT return false;
    }
    return sequentialized;
}

// checkDependency
luj_check_dependency :: (src: Value_Id, dst: Value_Id, unroll_level: s64, jam_level: s64, sequentialized: bool, di: *Da_Info) -> bool {
    if src == dst return true;
    if inst_op(src) == .LOAD && inst_op(dst) == .LOAD return true;
    d := da_depends(di, src, dst);
    if !d return true;
    if d.confused return false;
    for depth: 1..unroll_level - 1 if !(dep_direction(d, depth) & DV_EQ) return true;
    ud := dep_direction(d, unroll_level);
    if ud == DV_EQ return true;
    if (ud & DV_LT) && !luj_preserves_forward(unroll_level, jam_level, sequentialized, d) return false;
    if (ud & DV_GT) && !luj_preserves_backward(unroll_level, jam_level, sequentialized, d) return false;
    return true;
}

// checkDependencies
luj_check_dependencies :: (li: *Loop_Info, root: Loop_Id, p: *Luj_Partition, di: *Da_Info) -> bool {
    all: [..] *Bb_Set; all.allocator = temp;
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder_of(li, root, *pre);
    for l: pre { k := luj_partition_index(p, l); if k >= 0 array_add(*all, *p.fore[k]); }
    array_add(*all, *p.jam_loop_blocks);
    for l: pre { k := luj_partition_index(p, l); if k >= 0 array_add(*all, *p.aft[k]); }
    loop_depth := cast(s64) li_depth(li, root);
    earlier: [..] Value_Id; earlier.allocator = temp;
    current: [..] Value_Id; current.allocator = temp;
    for blocks: all {
        current.count = 0;
        if !luj_get_loads_and_stores(blocks, *current) return false;
        first := bbs_iter(blocks)[0];   // (*Blocks.begin())->front().getParent()
        cur_loop_depth := cast(s64) li_depth(li, li_loop_for(li, first));
        for e: earlier {
            earlier_depth := cast(s64) li_depth(li, li_loop_for(li, inst_block(e)));
            common := min(earlier_depth, cur_loop_depth);
            for later: current if !luj_check_dependency(e, later, loop_depth, common, false, di) return false;
        }
        n := current.count;
        for i: 0..n - 1 for j: i..n - 1
            if !luj_check_dependency(current[i], current[j], loop_depth, cur_loop_depth, true, di) return false;
        for current array_add(*earlier, it);
    }
    return true;
}

// isEligibleLoopForm
luj_is_eligible_loop_form :: (li: *Loop_Info, root: Loop_Id) -> bool {
    if li_subloops(li, root).count != 1 return false;
    l := root;
    while l != NONE {
        if !li_is_loop_simplify_form(li, l) return false;
        if !li_is_rotated_form(li, l) return false;
        if block_has_address_taken(li_header(li, l)) return false;
        n := li_subloops(li, l).count;
        if n == 0 return true;
        if n != 1 return false;
        if li_exit_block(li, l) == NONE return false;
        if li_exiting_block(li, l) == NONE return false;
        l = li_subloops(li, l)[0];
    }
    return true;
}

// hasIterationCountInvariantInParent
has_iteration_count_invariant_in_parent :: (li: *Loop_Info, inner: Loop_Id) -> bool {
    outer := li_parent(li, inner);
    if outer == NONE return true;
    bec := sc_get_exit_count(inner, li_loop_latch(li, inner));
    if sc_is_cnc(bec) || type_kind(sc_type(bec)) != .INT return false;
    return sc_is_loop_invariant(bec, outer);
}

// isSafeToUnrollAndJam
luj_is_safe_to_unroll_and_jam :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, di: *Da_Info) -> bool {
    if !luj_is_eligible_loop_form(li, l) return false;
    jam := l;
    while li_subloops(li, jam).count jam = li_subloops(li, jam)[0];
    p: Luj_Partition;
    p.jam_loop_blocks.list.allocator = temp; p.loops.allocator = temp; p.fore.allocator = temp; p.aft.allocator = temp;
    if !luj_partition_outer_loop_blocks(li, l, jam, *p, dt) return false;
    k := luj_partition_index(*p, l);
    if p.aft[k].list.count != 1 return false;
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder_of(li, l, *pre);
    for pre if !has_iteration_count_invariant_in_parent(li, it) return false;
    // SimpleLoopSafetyInfo::computeLoopSafetyInfo + anyBlockMayThrow
    for bb: li_blocks(li, l) if !is_guaranteed_to_transfer_execution_block(bb) return false;
    header := li_header(li, l);
    latch := li_loop_latch(li, l);
    sub := li_subloops(li, l)[0];
    if !luj_process_header_phi_operands(li, header, latch, *p.aft[k], 1, sub, NONE) return false;
    if !luj_check_dependencies(li, l, *p, di) return false;
    return true;
}

// ---------------------------------------------------------------- the pass

// hasAnyUnrollPragma
luj_has_any_unroll_pragma :: (li: *Loop_Info, l: Loop_Id, prefix: string) -> bool {
    id := li_loop_id(li, l);
    if id == NONE return false;
    n := md_nops(id);
    if n > 1 for k: 1..n - 1 {
        md := md_op(id, cast(u32) k);
        if md == NONE || !md_is_node(md) || md_nops(md) == 0 continue;
        s := md_op(md, 0);
        if s == NONE || ir.mds[s].kind != .STRING continue;
        if begins_with(ir.mds[s].str, prefix) return true;
    }
    return false;
}
// unrollAndJamCountPragmaValue
luj_count_pragma_value :: (li: *Loop_Info, l: Loop_Id) -> u32 {
    md := li_unroll_metadata(li, l, "llvm.loop.unroll_and_jam.count");
    if md == NONE return 0;
    c := md_const_int_op(md, 1);
    return cast,trunc(u32) const_int_zext(c);
}
// getUnrollAndJammedLoopSize
luj_unrolled_size :: (loop_size: u32, up: *Unroll_Prefs) -> u64 { return cast(u64) (loop_size - up.be_insns) * cast(u64) up.count + up.be_insns; }

// computeUnrollAndJamCount
luj_compute_unroll_and_jam_count :: (li: *Loop_Info, l: Loop_Id, sub: Loop_Id, t: *Tti, dt: *Dom_Tree, ac: *Assumption_Cache,
                                     eph: *Table(Value_Id, bool), outer_trip_count: u32, outer_trip_multiple: u32,
                                     outer_uce: *Unroll_Cost_Estimator, inner_trip_count: u32, inner_loop_size: u32,
                                     up: *Unroll_Prefs, pp: *Peel_Prefs) -> bool {
    outer_loop_size := uce_rolled_loop_size(outer_uce);
    compute_unroll_count(li, l, t, dt, ac, eph, outer_trip_count, 0, false, outer_trip_multiple, outer_uce, up, pp);
    user_unroll_count := luj_cl.has_unroll_and_jam_count;
    if user_unroll_count {
        up.count = luj_cl.unroll_and_jam_count;
        up.force = true;
        if up.allow_remainder && luj_unrolled_size(outer_loop_size, up) < up.threshold &&
           luj_unrolled_size(inner_loop_size, up) < up.unroll_and_jam_inner_loop_threshold return true;
    }
    pragma_count := luj_count_pragma_value(li, l);
    if pragma_count > 0 {
        up.count = pragma_count;
        up.runtime = true;
        up.force = true;
        if (up.allow_remainder || (outer_trip_multiple % pragma_count == 0)) &&
           luj_unrolled_size(outer_loop_size, up) < up.threshold &&
           luj_unrolled_size(inner_loop_size, up) < up.unroll_and_jam_inner_loop_threshold return true;
    }
    pragma_enable := li_unroll_metadata(li, l, "llvm.loop.unroll_and_jam.enable") != NONE;
    explicit_count := pragma_count > 0 || user_unroll_count;
    explicit := pragma_enable || explicit_count;
    if explicit up.unroll_and_jam_inner_loop_threshold = luj_cl.pragma_unroll_and_jam_threshold;
    if !up.allow_remainder && luj_unrolled_size(inner_loop_size, up) >= up.unroll_and_jam_inner_loop_threshold {
        up.count = 0;
        return false;
    }
    if !explicit_count && up.allow_remainder {
        while up.count != 0 && luj_unrolled_size(inner_loop_size, up) >= up.unroll_and_jam_inner_loop_threshold up.count -= 1;
    }
    if explicit return true;
    if inner_trip_count && inner_loop_size * inner_trip_count < up.threshold { up.count = 0; return false; }
    if li_blocks(li, sub).count != 1 { up.count = 0; return false; }
    num_invariant := 0;
    for bb: li_blocks(li, sub) for i: block_insts(bb) {
        if inst_op(i) == .LOAD {
            ls := sc_get_scev_at_scope(sc_get_scev(op(i, 0)), l);
            if sc_is_loop_invariant(ls, l) num_invariant += 1;
        }
    }
    if num_invariant == 0 { up.count = 0; return false; }
    return false;
}

// tryToUnrollAndJamLoop(Loop *L, ...)
luj_try_loop :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, t: *Tti, ac: *Assumption_Cache, di: *Da_Info, opt_level: s64) -> Loop_Unroll_Result {
    no_opts: Unroll_Options;
    up := gather_unrolling_preferences(li, l, t, opt_level, *no_opts);
    pp := gather_peeling_preferences(li, l, t, false, false, false, false, false);
    mode := li_has_unroll_and_jam_transformation(li, l);
    if mode & TM_DISABLE return .UNMODIFIED;
    if mode & TM_FORCED_BY_USER up.unroll_and_jam = true;
    if luj_cl.has_allow_unroll_and_jam up.unroll_and_jam = luj_cl.allow_unroll_and_jam;
    if luj_cl.has_unroll_and_jam_threshold up.unroll_and_jam_inner_loop_threshold = luj_cl.unroll_and_jam_threshold;
    if !up.unroll_and_jam || up.unroll_and_jam_inner_loop_threshold == 0 return .UNMODIFIED;
    if luj_has_any_unroll_pragma(li, l, "llvm.loop.unroll.") && !luj_has_any_unroll_pragma(li, l, "llvm.loop.unroll_and_jam.") return .UNMODIFIED;
    if !luj_is_safe_to_unroll_and_jam(li, l, dt, di) return .UNMODIFIED;
    eph: Table(Value_Id, bool); eph.allocator = temp;
    collect_ephemeral_values(li, l, ac, *eph);
    sub := li_subloops(li, l)[0];
    inner_uce := unroll_cost_estimator(li, sub, t, *eph, up.be_insns, false);
    outer_uce := unroll_cost_estimator(li, l, t, *eph, up.be_insns, false);
    if !uce_can_unroll(*inner_uce) || !uce_can_unroll(*outer_uce) return .UNMODIFIED;
    inner_loop_size := uce_rolled_loop_size(*inner_uce);
    if inner_uce.num_inline_candidates != 0 || outer_uce.num_inline_candidates != 0 return .UNMODIFIED;
    if inner_uce.convergence != .NONE || outer_uce.convergence != .NONE return .UNMODIFIED;
    orig_outer_id := li_loop_id(li, l);
    orig_sub_id := li_loop_id(li, sub);
    ok, id := make_followup_loop_id(orig_outer_id, .["llvm.loop.unroll_and_jam.followup_all", "llvm.loop.unroll_and_jam.followup_remainder_inner"]);
    if ok li_set_loop_id(li, sub, id);
    latch := li_loop_latch(li, l);
    sub_latch := li_loop_latch(li, sub);
    outer_trip_count := sc_small_constant_trip_count_exiting(l, latch);
    outer_trip_multiple := sc_small_constant_trip_multiple_exiting(l, latch);
    inner_trip_count := sc_small_constant_trip_count_exiting(sub, sub_latch);
    explicit := luj_compute_unroll_and_jam_count(li, l, sub, t, dt, ac, *eph, outer_trip_count, outer_trip_multiple, *outer_uce,
                                                 inner_trip_count, inner_loop_size, *up, *pp);
    if up.count <= 1 return .UNMODIFIED;
    if outer_trip_count && up.count > outer_trip_count up.count = outer_trip_count;
    result := luj_unroll_and_jam_loop(li, l, up.count, outer_trip_count, outer_trip_multiple, up.unroll_remainder, dt, ac, t);
    // EpilogueOuterLoop is never set (see luj_unroll_and_jam_loop), so no remainder_outer followup
    ok, id = make_followup_loop_id(orig_outer_id, .["llvm.loop.unroll_and_jam.followup_all", "llvm.loop.unroll_and_jam.followup_inner"]);
    if ok li_set_loop_id(li, sub, id);
    else li_set_loop_id(li, sub, orig_sub_id);
    if result == .PARTIALLY_UNROLLED {
        ok, id = make_followup_loop_id(orig_outer_id, .["llvm.loop.unroll_and_jam.followup_all", "llvm.loop.unroll_and_jam.followup_outer"]);
        if ok { li_set_loop_id(li, l, id); return result; }
    }
    if result != .FULLY_UNROLLED && explicit li_set_loop_already_unrolled(li, l);
    return result;
}

// LoopUnrollAndJamPass::run(LoopNest &LN, ...)
loop_unroll_and_jam_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    li := lar.li;
    di := da_new(lar.fn, li);
    t := tti_get(lar.fn);
    opt_level: s64 = 2;   // LoopUnrollAndJamPass(int OptLevel = 2)
    loops := loop_nest_loops_bfs(li, l);
    w: Loop_Worklist; lwl_init(*w);
    append_loops_to_worklist(li, loops, *w);   // appendLoopsToWorklist(LN.getLoops(), Worklist)
    did_something := false;
    while !lwl_empty(*w) {
        x := lwl_pop(*w);
        r := luj_try_loop(li, x, lar.dt, t, lar.ac, di, opt_level);
        if r != .UNMODIFIED did_something = true;
        if r == .FULLY_UNROLLED && x == l && u lpm_mark_loop_as_deleted(u, x);
    }
    if !did_something return PRESERVE_ALL;
    return loop_pass_preserved();
}
