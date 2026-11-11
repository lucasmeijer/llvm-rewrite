// SLPVectorizer: building the vectorizable tree. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::deleteTree, buildTree, buildTreeRec, newTreeEntry / newGatherTreeEntry, TreeEntry::isSame and the
// small TreeEntry queries, getScalarsVectorizationLegality, getScalarsVectorizationState, tryToFindDuplicates,
// canBuildSplitNode, canReuseExtract, canVectorizeLoads (the X86 subset, see below), isMaskedStoreCompress,
// getLoopNest / findInnermostNonInvariantLoop, hasSameNode, isTreeTinyAndNotFullyVectorizable,
// isFullyVectorizableTinyTree, isTreeNotExtendable, ::getShuffleCost).
//
// canVectorizeLoads: X86 has no legal strided loads/stores (TTI::isLegalStridedLoadStore is the base `false`), so
// analyzeConstantStrideCandidate / analyzeRtStrideCandidate are `false` without side effects; the masked-load
// compress check (isMaskedLoadCompress) and the masked-gather cost comparison are not ported and fail loudly.

PoisonMaskElem :: -1;

// ---------------------------------------------------------------- TreeEntry queries

te_is_gather :: inline (te: Te_Id) -> bool { return slp.entries[te].state == TE_NEED_TO_GATHER; }
te_has_state :: inline (te: Te_Id) -> bool { return is_valid(slp.entries[te].s); }
te_opcode :: inline (te: Te_Id) -> Opcode { return is_opcode(slp.entries[te].s); }
te_vector_factor :: (te: Te_Id) -> s64 {
    e := *slp.entries[te];
    if e.reuse_shuffle_indices.count return e.reuse_shuffle_indices.count;
    return e.scalars.count;
}
slp_te_is_copyable :: (te: Te_Id, v: Value_Id) -> bool {
    for slp.entries[te].copyable_elements if it == v return true;
    return false;
}
slp_te_has_copyables :: (te: Te_Id) -> bool { return slp.entries[te].copyable_elements.count > 0; }
// TreeEntry::isExpandedBinOp / isExpandedOperand
slp_te_is_expanded_bin_op :: (te: Te_Id, v: Value_Id) -> bool {
    if slp_te_is_copyable(te, v) return false;
    return is_expanded_bin_op(slp.entries[te].s, v);
}
slp_te_is_expanded_operand :: (te: Te_Id, i: Value_Id, idx: u32) -> bool {
    if slp_te_is_copyable(te, i) return false;
    if !slp_te_is_expanded_bin_op(te, i) return false;
    return is_expanded_operand(i, idx);
}
// TE->doesNotNeedToSchedule() && the user is a (non-split) PHI node
slp_te_is_non_schedulable_with_parent_phi :: (te: Te_Id) -> bool {
    e := *slp.entries[te];
    if !e.does_not_need_to_schedule || e.user_tree_index.user == TE_NONE return false;
    u := e.user_tree_index.user;
    return te_has_state(u) && slp.entries[u].state != TE_SPLIT_VECTORIZE && te_opcode(u) == .PHI;
}
// TreeEntry::isSame(VL)
te_is_same :: (te: Te_Id, vl: [] Value_Id) -> bool {
    e := *slp.entries[te];
    is_same :: (vl: [] Value_Id, scalars: [] Value_Id, mask: [] s32) -> bool {
        if mask.count != vl.count && vl.count == scalars.count {
            for vl if it != scalars[it_index] return false;
            return true;
        }
        if vl.count != mask.count return false;
        for v, k: vl {
            idx := mask[k];
            if (pm_undef_value(v) && idx == PoisonMaskElem) || (idx != PoisonMaskElem && v == scalars[idx]) continue;
            return false;
        }
        return true;
    }
    if e.reorder_indices.count {
        mask := slp_inverse_permutation(e.reorder_indices);
        if vl.count == e.scalars.count return is_same(vl, e.scalars, mask);
        if vl.count == e.reuse_shuffle_indices.count {
            slp_add_mask(*mask, e.reuse_shuffle_indices);
            return is_same(vl, e.scalars, mask);
        }
        return false;
    }
    return is_same(vl, e.scalars, e.reuse_shuffle_indices);
}
// getSameValuesTreeEntry(V, VL, SameVF)
slp_get_same_values_tree_entry :: (v: Value_Id, vl: [] Value_Id, same_vf := false) -> Te_Id {
    for te: slp_get_tree_entries(v) if (!same_vf || te_vector_factor(te) == vl.count) && te_is_same(te, vl) return te;
    return TE_NONE;
}
slp_get_split_tree_entries :: (v: Value_Id) -> [] Te_Id {
    p := table_find_pointer(*slpx.scalars_in_split_nodes, v);
    if !p return .[];
    return p.*;
}
// getOperandEntry(E, Idx): OperandsToTreeEntry
slp_get_operand_entry :: (te: Te_Id, idx: u32) -> Te_Id {
    found, r := table_find(*slpx.operands_to_tree_entry, ((cast(u64) te) << 32) | idx);
    if !found fatal("internal: slp: operand entry not found");
    return r;
}
// hasSameNode(S, VL)
slp_has_same_node :: (s: Inst_State, vl: [] Value_Id) -> bool {
    if is_valid(s) {
        for slp_get_tree_entries(s.main) if te_is_same(it, vl) return true;
        p := table_find_pointer(*slpx.value_to_gather_nodes, s.main);
        if p for p.* if te_is_same(it, vl) return true;
        return false;
    }
    visited: [..] Te_Id; visited.allocator = temp;
    for v: vl {
        if slp_is_constant(v) continue;
        p := table_find_pointer(*slpx.value_to_gather_nodes, v);
        if !p continue;
        for te: p.* {
            dup := false; for visited if it == te { dup = true; break; }
            if dup continue;
            array_add(*visited, te);
            if te_is_same(te, vl) return true;
        }
    }
    return false;
}
slp_is_reduction_tree :: () -> bool { return slpx.has_user_ignore_list; }
slp_in_user_ignore_list :: (v: Value_Id) -> bool {
    if !slpx.has_user_ignore_list return false;
    for slpx.user_ignore_list if it == v return true;
    return false;
}

// ---------------------------------------------------------------- deleteTree / buildTree

slp_delete_tree :: () {
    array_reset_keeping_memory(*slp.entries);
    table_reset(*slp.scalar_to_tree_entries);
    table_reset(*slp.deleted_nodes);
    table_reset(*slp.transformed_to_gather_nodes);
    table_reset(*slpx.operands_to_tree_entry);
    table_reset(*slpx.scalars_in_split_nodes);
    table_reset(*slp.must_gather);
    table_reset(*slpx.non_scheduled_first);
    array_reset_keeping_memory(*slpx.load_entries_to_vectorize);
    slpx.is_graph_transform_mode = false;
    slpx.gathered_loads_first = -1;
    for slpx.block_schedules bs_clear(it);
    slpx.base_graph_size = 1;
    slpx.has_cast_max_min_bw = false;
    array_reset_keeping_memory(*slpx.extra_bitwidth_nodes);
    table_reset(*slpx.instr_element_size);
    slpx.has_user_ignore_list = false;
    slpx.user_ignore_list = .[];
    table_reset(*slpx.value_to_gather_nodes);
    array_reset_keeping_memory(*slpx.current_loop_nest);
    array_reset_keeping_memory(*slpx.merged_loop_btcs);
    slp_delete_tree_later_state();
}

// buildTree(Roots) / buildTree(Roots, UserIgnoreLst)
slp_build_tree :: (roots: [] Value_Id) {
    slp_delete_tree();
    if !slp_all_same_type(roots) return;
    slp_build_tree_rec(roots, 0, .{});
}
slp_build_tree_with_ignore :: (roots: [] Value_Id, ignore_list: [] Value_Id) {
    slp_delete_tree();
    slpx.has_user_ignore_list = true;
    slpx.user_ignore_list = ignore_list;
    if !slp_all_same_type(roots) return;
    slp_build_tree_rec(roots, 0, .{});
}

// ---------------------------------------------------------------- newTreeEntry

slp_new_gather_tree_entry :: (vl: [] Value_Id, s: Inst_State, ei: Edge_Info, reuse: [] s32 = .[]) -> Te_Id {
    return slp_new_tree_entry_state(vl, TE_NEED_TO_GATHER, -1, s, ei, reuse);
}
// newTreeEntry(VL, Bundle, S, UserTreeIdx, ReuseShuffleIndices, ReorderIndices, InterleaveFactor); bundle -2 = the
// empty (valid) bundle of a node that does not need scheduling, -1 = ScheduleBundle::invalid()
slp_new_tree_entry :: (vl: [] Value_Id, bundle: s32, s: Inst_State, ei: Edge_Info, reuse: [] s32 = .[], reorder: [] u32 = .[], interleave: u32 = 0) -> Te_Id {
    st := ifx bundle != -1 then TE_VECTORIZE else TE_NEED_TO_GATHER;
    e := slp_new_tree_entry_state(vl, st, bundle, s, ei, reuse, reorder);
    if e != TE_NONE && interleave > 0 slp.entries[e].interleave_factor = interleave;
    return e;
}
slp_new_tree_entry_state :: (vl: [] Value_Id, state: s32, bundle: s32, s: Inst_State, ei: Edge_Info, reuse: [] s32 = .[], reorder: [] u32 = .[]) -> Te_Id {
    if slpx.gathered_loads_first >= 0 && state == TE_NEED_TO_GATHER && is_valid(s) && is_opcode(s) == .LOAD &&
       ei.edge == EDGE_NONE && ei.user == TE_NONE return TE_NONE;
    ne: Tree_Entry;
    ne.scalars.allocator = temp; ne.reuse_shuffle_indices.allocator = temp; ne.reorder_indices.allocator = temp;
    ne.combined_entries_with_indices.allocator = temp; ne.struct_ev_indices.allocator = temp;
    ne.operands.allocator = temp; ne.copyable_elements.allocator = temp; ne.value_to_lane.allocator = temp;
    array_add(*slp.entries, ne);
    last := cast(Te_Id) (slp.entries.count - 1);
    e := *slp.entries[last];
    e.idx = last;
    e.state = state;
    if ei.user != TE_NONE {
        key := ((cast(u64) ei.user) << 32) | ei.edge;
        if !table_contains(*slpx.operands_to_tree_entry, key) table_set(*slpx.operands_to_tree_entry, key, last);
    }
    for reuse array_add(*e.reuse_shuffle_indices, it);
    if reorder.count == 0 {
        for vl array_add(*e.scalars, it);
        if is_valid(s) e.s = s;
    } else {
        for idx: reorder {
            if cast(s64) idx >= vl.count array_add(*e.scalars, const_undef(vtype(vl[0])));
            else array_add(*e.scalars, vl[idx]);
        }
        s2 := slp_get_same_opcode(e.scalars);
        if is_valid(s2) e.s = s2;
        for reorder array_add(*e.reorder_indices, it);
    }
    if state == TE_SPLIT_VECTORIZE {
        e.s = s;
        processed: [..] Value_Id; processed.allocator = temp;
        for v: vl {
            if !is_inst(v) continue;
            p := table_find_pointer(*slpx.scalars_in_split_nodes, v);
            if !p {
                l: [..] Te_Id; l.allocator = temp; array_add(*l, last);
                table_set(*slpx.scalars_in_split_nodes, v, l);
                array_add(*processed, v);
            } else {
                dup := false; for processed if it == v { dup = true; break; }
                if !dup { array_add(*processed, v); array_add(p, last); }
            }
        }
    } else if state != TE_NEED_TO_GATHER {
        all_non_sched := true;
        for vl if !is_non_schedulable(s, it) { all_non_sched = false; break; }
        if inst_op(s.main) == .PHI || slp_is_vector_like_inst_with_const_ops(s.main) ||
           (!s.has_copyables && slp_does_not_need_to_schedule(vl)) || all_non_sched
            e.does_not_need_to_schedule = true;
        processed: [..] Value_Id; processed.allocator = temp;
        for v: vl {
            if pm_poison(v) continue;
            if is_copyable_element(s, v) { array_add(*e.copyable_elements, v); continue; }
            p := table_find_pointer(*slp.scalar_to_tree_entries, v);
            if !p {
                l: [..] Te_Id; l.allocator = temp; array_add(*l, last);
                table_set(*slp.scalar_to_tree_entries, v, l);
                array_add(*processed, v);
            } else {
                dup := false; for processed if it == v { dup = true; break; }
                if !dup { array_add(*processed, v); array_add(p, last); }
            }
        }
        if bundle >= 0 {
            bs := slpx.cur_bundle_sched;
            bs.bundles[bundle].te = last;
        }
    } else {
        all_consts_or_casts := true;
        for v: vl {
            if is_valid(s) && s.has_copyables && is_copyable_element(s, v) array_add(*e.copyable_elements, v);
            if !slp_is_constant(v) {
                all_consts_or_casts &= is_inst(v) && is_cast_op(inst_op(v)) && type_kind(vtype(v)) == .INT;
                if ei.edge != EDGE_NONE || ei.user == TE_NONE || !te_is_gather(ei.user) {
                    p := table_find_pointer(*slpx.value_to_gather_nodes, v);
                    if !p { l: [..] Te_Id; l.allocator = temp; table_set(*slpx.value_to_gather_nodes, v, l); p = table_find_pointer(*slpx.value_to_gather_nodes, v); }
                    dup := false; for p.* if it == last { dup = true; break; }
                    if !dup array_add(p, last);
                }
            }
        }
        if all_consts_or_casts { slpx.has_cast_max_min_bw = true; slpx.cast_max_bw = 0xFFFF_FFFF; slpx.cast_min_bw = 1; }
        for vl table_set(*slp.must_gather, it, true);
    }
    if ei.user != TE_NONE slp.entries[last].user_tree_index = ei;
    return last;
}
// TreeEntry::setOperands
te_set_operands :: (te: Te_Id, operands: [] [..] Value_Id) {
    e := *slp.entries[te];
    for o: operands {
        l: [..] Value_Id; l.allocator = temp;
        for o array_add(*l, it);
        array_add(*e.operands, l);
    }
}

// ---------------------------------------------------------------- ::getShuffleCost

slp_shuffle_cost :: (kind_sk: s64, tp: Type_Id, mask: [] s32 = .[], cost_kind := TCK_RECIP_THROUGHPUT, index_in: s64 = 0, sub_ty: Type_Id = NONE, args: [] Value_Id = .[]) -> Cost {
    dst := tp;
    if mask.count dst = type_vector(cast(u64) mask.count, scalar_type(tp), false);
    index := index_in;
    if kind_sk != SK_PERMUTE_TWO_SRC return tti_shuffle_cost(slp.tti, kind_sk, dst, tp, mask, cost_kind, index, sub_ty, args, NONE);
    n_src := cast(s64) type_count(tp);
    if mask.count > 2 {
        ok, num_sub, idx := svm_is_insert_subvector(mask, n_src);
        if ok {
            index = idx;
            if index + num_sub > n_src && index + n_src <= mask.count
                return tti_shuffle_cost(slp.tti, SK_INSERT_SUBVECTOR, dst, tp, mask, TCK_RECIP_THROUGHPUT, index, tp, .[], NONE);
        }
    }
    return tti_shuffle_cost(slp.tti, kind_sk, dst, tp, mask, cost_kind, index, sub_ty, args, NONE);
}

// ---------------------------------------------------------------- legality

Sv_Legality :: struct {
    s: Inst_State;
    is_legal: bool;
    try_to_find_duplicates := true;
    try_split_vectorize: bool;
}

// getScalarsVectorizationLegality(VL, Depth, UserTreeIdx)
slp_get_scalars_vectorization_legality :: (vl: [] Value_Id, depth: u32, ei: Edge_Info) -> Sv_Legality {
    s := ica_build_instructions_state(vl, true);
    are_scatter_all_gep_same_block := false;
    if !is_valid(s) {
        is_scatter_user := ei.user != TE_NONE && slp.entries[ei.user].state == TE_SCATTER_VECTORIZE;
        if is_scatter_user && is_ptr_type(vtype(vl[0])) && vl.count > 2 {
            bb: Value_Id = NONE;
            ok := true;
            for v: vl {
                if !is_inst(v) || inst_op(v) != .GEP { if !slp_does_not_need_to_be_scheduled(v) { ok = false; break; } continue; }
                if bb == NONE bb = inst_block(v);
                if bb != inst_block(v) || nops(v) != 2 { ok = false; break; }
            }
            if ok && bb != NONE {
                sorted, _ := sort_ptr_accesses(vl, vtype(slp.entries[ei.user].s.main));
                are_scatter_all_gep_same_block = sorted;
            }
        }
        if !are_scatter_all_gep_same_block return .{s = s, is_legal = false, try_to_find_duplicates = true, try_split_vectorize = true};
        for v: vl if is_inst(v) && inst_op(v) == .GEP { s = slp_get_same_opcode(.[v]); break; }
    }
    if is_opcode(s) == .PHI {
        n := cast(u64) phi_num_incoming(s.main);
        if cast(u64) vl.count * n > cast(u64) slp_cl.phi_budget return .{s = s, is_legal = false};
    }
    if is_vector_type(slp_get_value_type(vl[0])) return .{s = s, is_legal = false, try_to_find_duplicates = false};
    bb := inst_block(s.main);
    term := block_terminator(bb);
    if is_eh_pad(block_first_non_phi(bb)) || (term != NONE && inst_op(term) == .UNREACHABLE) || !dt_is_reachable_from_entry(slp.dt, bb)
        return .{s = s, is_legal = false};
    if term != NONE && inst_op(term) == .CATCHSWITCH return .{s = s, is_legal = false, try_to_find_duplicates = false};
    if is_opcode(s) == .EXTRACTELEMENT && type_kind(vtype(op(s.main, 0))) == .SVECTOR return .{s = s, is_legal = false};
    if depth >= cast(u32) slp_cl.recursion_max_depth {
        ok := !is_alt_shuffle(s) && vl.count >= 4;
        if ok {
            ok = inst_op(s.main) == .LOAD;
            if !ok {
                ok = true;
                for v: vl {
                    if !(is_inst(v) && (inst_op(v) == .ZEXT || inst_op(v) == .SEXT) && has_one_use(v) &&
                         is_inst(op(v, 0)) && inst_op(op(v, 0)) == .LOAD && has_one_use(op(v, 0)) && inst_op(v) == is_opcode(s)) { ok = false; break; }
                }
            }
        }
        if !ok return .{s = s, is_legal = false};
    }
    is_phi_with_loop := is_opcode(s) == .PHI && li_loop_for(slp.li, inst_block(s.main)) != NONE;
    for e: slp_get_tree_entries(s.main) {
        if te_is_same(e, vl) return .{s = s, is_legal = false};
        all := true;
        for v: vl {
            if pm_poison(v) continue;
            inn := false;
            for slp.entries[e].scalars if it == v { inn = true; break; }
            if inn continue;
            if is_phi_with_loop && is_inst(v) && inst_op(v) == .PHI && slp_is_vectorized(v) continue;
            all = false; break;
        }
        if all return .{s = s, is_legal = false};
    }
    are_all_same_block := !are_scatter_all_gep_same_block;
    are_all_same_insts := are_all_same_block || are_scatter_all_gep_same_block;
    mo := inst_op(s.main);
    all_vlike := true;
    for vl if !slp_is_vector_like_inst_with_const_ops(it) { all_vlike = false; break; }
    if !are_all_same_insts || slp_is_splat(vl) || ((mo == .INSERTELEMENT || mo == .EXTRACTVALUE || mo == .EXTRACTELEMENT) && !all_vlike)
        return .{s = s, is_legal = false};
    if slpx.eph_values.count {
        for vl if table_contains(*slpx.eph_values, it) return .{s = s, is_legal = false, try_to_find_duplicates = false};
    }
    if is_alt_shuffle(s) {
        n := vl.count;
        extracted := NewArray(n, bool,, temp);
        vectorized := NewArray(n, bool,, temp);
        for * vectorized it.* = true;
        for v, idx: vl {
            if !is_inst(v) || slp_does_not_need_to_be_scheduled(v) continue;
            all_ee := true;
            for k: 0..cast(s64) nops(v) - 1 { o := op(v, cast(u32) k); if !(is_inst(o) && inst_op(o) == .EXTRACTELEMENT) { all_ee = false; break; } }
            if all_ee continue;
            if slp_is_vectorized(v) vectorized[idx] = false;
            else if !has_one_user(v) && !slp_are_all_users_vectorized(v, true) extracted[idx] = true;
        }
        all_vec := all_bits(vectorized);
        prefer_scalarize := !all_vec && vl.count == 2;
        if !all_vec && !prefer_scalarize {
            sty := vtype(vl[0]);
            vec_ty := slp_widened_type(sty, cast(u64) n);
            vec_est := cost_add(slp_shuffle_cost(SK_PERMUTE_TWO_SRC, vec_ty),
                                slp_get_scalarization_overhead(sty, vec_ty, extracted, false, true, TCK_RECIP_THROUGHPUT));
            sc_est := slp_get_scalarization_overhead(sty, vec_ty, vectorized, true, false, TCK_RECIP_THROUGHPUT, false);
            prefer_scalarize = vec_est > sc_est;
        }
        if prefer_scalarize return .{s = s, is_legal = false};
    }
    if slpx.has_user_ignore_list && slpx.user_ignore_list.count {
        for vl if slp_in_user_ignore_list(it) return .{s = s, is_legal = false};
    }
    return .{s = s, is_legal = true};
}

// ---------------------------------------------------------------- tryToFindDuplicates

slp_try_to_find_duplicates :: (vl: *[..] Value_Id, reuse: *[..] s32, s: Inst_State, ei: Edge_Info, build_gather_only := true) -> bool {
    if type_kind(slp_get_value_type(vl.*[0])) == .STRUCT { array_reset_keeping_memory(reuse); return true; }
    uniques: [..] Value_Id; uniques.allocator = temp;
    pos: Table(Value_Id, s32); pos.allocator = temp;
    for v: vl.* {
        if slp_is_constant(v) {
            array_add(reuse, ifx pm_poison(v) then cast(s32) PoisonMaskElem else cast(s32) uniques.count);
            array_add(*uniques, v);
            continue;
        }
        found, p := table_find(*pos, v);
        if found { array_add(reuse, p); continue; }
        table_set(*pos, v, cast(s32) uniques.count);
        array_add(reuse, cast(s32) uniques.count);
        array_add(*uniques, v);
    }
    require_scheduling := is_valid(s) && is_opcode(s) != .PHI && !slp_is_vector_like_inst_with_const_ops(s.main) &&
                          (s.has_copyables || !slp_does_not_need_to_schedule(uniques));
    are_all_non_const := pos.count == uniques.count;
    if require_scheduling {
        end := uniques.count;
        while end > 0 && pm_poison(uniques[end - 1]) end -= 1;
        uniques.count = end;
    }
    num_uniques := uniques.count;
    if num_uniques == vl.count { array_reset_keeping_memory(reuse); return true; }
    SMALL_VEC_WIDTH :: 4;
    SMALL_VEC_UNIQUE_THRESHOLD :: 3;
    if vl.count == SMALL_VEC_WIDTH && num_uniques == SMALL_VEC_UNIQUE_THRESHOLD && !build_gather_only &&
       !(is_valid(s) && (is_opcode(s) == .LOAD || is_opcode(s) == .PHI)) {
        array_reset_keeping_memory(reuse);
        return true;
    }
    estimate :: (vl: [] Value_Id, uniques: [] Value_Id, reuse: [] s32, pos: *Table(Value_Id, s32), s: Inst_State, ei: Edge_Info,
                 build_gather_only: bool, require_scheduling: bool, are_all_non_const: bool) -> (bool, bool) {
        num_uniques := uniques.count;
        if pos.count == 1 {
            all := true;
            for uniques if !(pm_undef_value(it) || is_inst(it) || vkind(it) == .ARGUMENT) { all = false; break; }
            if num_uniques == 1 || all return false, false;
        }
        MIN_VL_FOR_CONST_GATHER_CHECK :: 4;
        if build_gather_only && vl.count > MIN_VL_FOR_CONST_GATHER_CHECK && has_single_bit(cast(u64) vl.count) &&
           !has_single_bit(cast(u64) num_uniques) && pos.count * 2 < num_uniques return false, false;
        check_loads :: (loads: [] Value_Id, s: Inst_State, include_gather: bool) -> bool {
            st := slp_can_vectorize_loads(loads, s.main);
            return (include_gather && st == LS_GATHER) || st == LS_SCATTER || st == LS_STRIDED || st == LS_COMPRESS;
        }
        is_root_operand := ei.user != TE_NONE && slp.entries[ei.user].idx == 0 && !build_gather_only;
        if is_root_operand {
            if is_valid(s) && is_opcode(s) == .LOAD {
                use_orig := (check_loads(uniques, s, true) && check_loads(vl, s, false)) || svm_is_identity(reuse, reuse.count);
                return true, use_orig;
            }
            return true, !require_scheduling;
        }
        dem := NewArray(vl.count, bool,, temp);
        for val, idx: reuse if val != PoisonMaskElem && table_contains(pos, uniques[val]) dem[idx] = true;
        sty := slp_get_value_type(uniques[0]);
        vec_ty := slp_widened_type(sty, cast(u64) vl.count);
        uniq_vec_ty := slp_widened_type(sty, cast(u64) num_uniques);
        num_parts := slp_number_of_parts(slp.tti, vec_ty, sty);
        uniq_parts := slp_number_of_parts(slp.tti, uniq_vec_ty, sty);
        if !require_scheduling {
            if vl.count / num_uniques == 1 && (num_parts <= 1 || uniq_parts >= num_parts) return true, true;
            if is_valid(s) && is_opcode(s) == .PHI && num_uniques > 1 && uniq_parts <= num_parts return true, false;
        }
        reuses_cost := slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, vec_ty, ifx num_uniques > vl.count / 2 then .[] else reuse, TCK_RECIP_THROUGHPUT, 0, uniq_vec_ty);
        if is_valid(s) && !build_gather_only {
            has_one_dup := is_opcode(s) != .LOAD && num_uniques + 1 == vl.count;
            mostly_unique := num_uniques * 2 > vl.count;
            is_half := num_uniques * 2 == vl.count && (is_opcode(s) == .GEP || (is_cast_op(inst_op(s.main)) && !is_alt_shuffle(s)));
            threshold := cast(Cost) num_parts * ifx vl.count > SMALL_VEC_WIDTH then 1 else 2;
            if has_one_dup || ((mostly_unique || is_half) && reuses_cost > threshold) return true, true;
        }
        if is_valid(s) && is_opcode(s) == .LOAD {
            uv := check_loads(uniques, s, false);
            if uv || check_loads(vl, s, false) return true, !uv;
        }
        can_skip_bv := (!build_gather_only && !require_scheduling) || slp_has_same_node(s, vl);
        inserts_cost: Cost = TCC_FREE;
        if !can_skip_bv inserts_cost = slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT, are_all_non_const, vl);
        udem := NewArray(num_uniques, bool,, temp);
        for v, idx: uniques udem[idx] = !slp_is_constant(v);
        uniques_cost: Cost = TCC_FREE;
        if !can_skip_bv uniques_cost = slp_get_scalarization_overhead(sty, uniq_vec_ty, udem, true, false, TCK_RECIP_THROUGHPUT, are_all_non_const, uniques);
        uniques_cost = cost_add(uniques_cost, reuses_cost);
        if uniques_cost <= inserts_cost return true, false;
        diff := uniques_cost - inserts_cost;
        if diff < TCC_EXPENSIVE || (slp.entries.count == 0 && slp_is_reduction_tree() && diff == TCC_EXPENSIVE)
            return is_valid(s) && (!is_alt_shuffle(s) || !build_gather_only), false;
        keep := !build_gather_only && !require_scheduling;
        return keep, keep;
    }
    pack_profitable, use_original := estimate(vl.*, uniques, reuse.*, *pos, s, ei, build_gather_only, require_scheduling, are_all_non_const);
    if pack_profitable {
        if use_original array_reset_keeping_memory(reuse);
        else { array_reset_keeping_memory(vl); for uniques array_add(vl, it); }
        return true;
    }
    array_reset_keeping_memory(reuse);
    return false;
}

// ---------------------------------------------------------------- canBuildSplitNode

// isMainInstruction / isAlternateInstruction
slp_is_main_instruction :: (i: Value_Id, main: Value_Id, alt: Value_Id) -> bool {
    return is_matching_main_or_alt(.{main, alt, false}, i) == main;
}
slp_is_alternate_instruction :: (i: Value_Id, main: Value_Id, alt: Value_Id) -> bool {
    if is_cmp_inst(main) {
        mp := inst(main).pred;
        if slp_is_cmp_same_or_swapped(main, i) return false;
        if slp_is_cmp_same_or_swapped(alt, i) return true;
        p := inst(i).pred; sp := swapped_predicate(p);
        return mp != p && mp != sp;
    }
    return is_matching_main_or_alt(.{main, alt, false}, i) == alt;
}

// canBuildSplitNode(VL, LocalState, Op1, Op2, ReorderIndices): (ok, op1, op2, reorder)
slp_can_build_split_node_full :: (vl: [] Value_Id, ls: Inst_State) -> (bool, [..] Value_Id, [..] Value_Id, [..] u32) {
    op1: [..] Value_Id; op1.allocator = temp;
    op2: [..] Value_Id; op2.allocator = temp;
    reorder: [..] u32; reorder.allocator = temp;
    SMALL_NODE_SIZE :: 4;
    // TTI::preferAlternateOpcodeVectorization: X86 false, the base implementation (no target) true
    prefer_alternate := slp.tti.kind != .X86;
    if vl.count <= SMALL_NODE_SIZE || prefer_alternate || !slp_cl.split_alternate return false, op1, op2, reorder;
    if type_kind(slp_get_value_type(vl[0])) == .STRUCT return false, op1, op2, reorder;
    for e: slp_get_split_tree_entries(ls.main) {
        if te_is_same(e, vl) return false, op1, op2, reorder;
        all := true;
        for v: vl {
            if pm_poison(v) continue;
            inn := false; for slp.entries[e].scalars if it == v { inn = true; break; }
            if !inn { all = false; break; }
        }
        if all return false, op1, op2, reorder;
    }
    n := vl.count;
    for 0..n-1 array_add(*reorder, cast(u32) n);
    op1_idx := NewArray(n, bool,, temp);
    for v, idx: vl {
        if !is_inst(v) { array_add(*op1, v); op1_idx[idx] = true; continue; }
        if (is_alt_opcode(ls) != is_opcode(ls) && slp_is_main_instruction(v, ls.main, ls.alt)) ||
           (is_alt_opcode(ls) == is_opcode(ls) && !slp_is_alternate_instruction(v, ls.main, ls.alt)) {
            array_add(*op1, v); op1_idx[idx] = true; continue;
        }
        array_add(*op2, v);
    }
    sty := slp_get_value_type(vl[0]);
    vec_ty := slp_widened_type(sty, cast(u64) n);
    opc0 := is_opcode(ls); opc1 := is_alt_opcode(ls);
    mask_bits := slp_alt_instr_mask(vl, sty, opc0, opc1);
    count_unique :: (l: [] Value_Id) -> s64 {
        u: [..] Value_Id; u.allocator = temp;
        for l { dup := false; for x: u if x == it { dup = true; break; } if !dup array_add(*u, it); }
        return u.count;
    }
    if count_unique(op1) <= 1 || count_unique(op2) <= 1 || tti_is_legal_alt_instr(slp.tti, vec_ty, opc0, opc1, mask_bits)
        return false, op1, op2, reorder;
    c1 := 0; c2 := op1.count;
    for idx: 0..n-1 {
        if op1_idx[idx] { reorder[c1] = cast(u32) idx; c1 += 1; }
        else { reorder[c2] = cast(u32) idx; c2 += 1; }
    }
    identity := true;
    for reorder if it != cast(u32) it_index && it != cast(u32) n { identity = false; break; }
    if identity array_reset_keeping_memory(*reorder);
    else if slp_has_full_vectors_or_power_of_2(slp.tti, vtype(op1[0]), cast(u64) n) &&
            (!slp_has_full_vectors_or_power_of_2(slp.tti, vtype(op1[0]), cast(u64) op1.count) ||
             !slp_has_full_vectors_or_power_of_2(slp.tti, vtype(op2[0]), cast(u64) op2.count))
        return false, op1, op2, reorder;
    mask: [..] s32; mask.allocator = temp;
    if reorder.count mask = slp_inverse_permutation(reorder);
    num_parts := tti_number_of_parts(slp.tti, vec_ty);
    op1_vec_ty := slp_widened_type(sty, cast(u64) op1.count);
    op2_vec_ty := slp_widened_type(sty, cast(u64) op2.count);
    if num_parts >= cast(u64) n return false, op1, op2, reorder;
    insert_cost := slp_shuffle_cost(SK_INSERT_SUBVECTOR, vec_ty, .[], TCK_RECIP_THROUGHPUT, op1.count, op2_vec_ty);
    sub_vec_ty := slp_widened_type(sty, cast(u64) max(op1.count, op2.count));
    new_shuffle_cost := slp_shuffle_cost(SK_PERMUTE_TWO_SRC, sub_vec_ty, mask, TCK_RECIP_THROUGHPUT);
    if !is_cmp_op(ls) && num_parts <= 1 && (mask.count == 0 || insert_cost >= new_shuffle_cost) return false, op1, op2, reorder;
    mo := inst_op(ls.main); ao := inst_op(ls.alt);
    if (is_binary_op(mo) && is_binary_op(ao) && (is_shift_op(ls) || is_bitwise_logic_op_state(ls) || is_add_sub_like_op(ls) || is_mul_div_like_op(ls))) ||
       (is_cast_op(mo) && is_cast_op(ao)) || (mo == .FNEG && ao == .FNEG) {
        orig_ops := cost_add(tti_arith_cost(slp.tti, opc0, vec_ty, TCK_RECIP_THROUGHPUT), tti_arith_cost(slp.tti, opc1, vec_ty, TCK_RECIP_THROUGHPUT));
        orig_mask := NewArray(n, s32,, temp);
        for idx: 0..n-1 {
            orig_mask[idx] = PoisonMaskElem;
            if pm_poison(vl[idx]) continue;
            orig_mask[idx] = cast(s32) (idx + ifx op1_idx[idx] then 0 else n);
        }
        orig_cost := cost_add(orig_ops, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, vec_ty, orig_mask, TCK_RECIP_THROUGHPUT));
        new_ops := cost_add(tti_arith_cost(slp.tti, opc0, op1_vec_ty, TCK_RECIP_THROUGHPUT), tti_arith_cost(slp.tti, opc1, op2_vec_ty, TCK_RECIP_THROUGHPUT));
        store_root := slp.entries.count > 0 && te_has_state(0) && te_opcode(0) == .STORE;
        new_cost := cost_add(cost_add(new_ops, insert_cost), ifx store_root then new_shuffle_cost else 0);
        if new_cost >= orig_cost return false, op1, op2, reorder;
    }
    return true, op1, op2, reorder;
}
slp_can_build_split_node :: (vl: [] Value_Id, s: Inst_State) -> bool {
    ok := slp_can_build_split_node_full(vl, s);
    return ok;
}

// ---------------------------------------------------------------- canReuseExtract

slp_can_reuse_extract :: (vl: [] Value_Id, order: *[..] u32, resize_allowed := false) -> bool {
    e0: Value_Id = NONE;
    for vl if is_inst(it) && (inst_op(it) == .EXTRACTELEMENT || inst_op(it) == .EXTRACTVALUE) { e0 = it; break; }
    vec := op(e0, 0);
    array_reset_keeping_memory(order);
    n_elts: u64;
    if inst_op(e0) == .EXTRACTVALUE {
        n_elts = slp_can_map_to_vector(vtype(vec));
        if n_elts == 0 return false;
        if !is_inst(vec) || inst_op(vec) != .LOAD || !is_simple_load_store(vec) || !has_n_uses(vec, vl.count) return false;
    } else {
        n_elts = type_count(vtype(vec));
    }
    e := cast(u64) vl.count;
    if !resize_allowed && n_elts != e return false;
    indices := NewArray(vl.count, s64,, temp);
    for * indices it.* = PoisonMaskElem;
    min_idx := n_elts; max_idx: u64 = 0;
    for v, i: vl {
        if !is_inst(v) continue;
        if op(v, 0) != vec return false;
        if inst_op(v) == .EXTRACTELEMENT && pm_undef_value(op(v, 1)) continue;
        ok, ext := slp_extract_index(v);
        if !ok return false;
        if ext >= n_elts continue;
        indices[i] = cast(s64) ext;
        if min_idx > ext min_idx = ext;
        if max_idx < ext max_idx = ext;
    }
    if max_idx - min_idx + 1 > e return false;
    if max_idx + 1 <= e min_idx = 0;
    keep := true;
    for 0..vl.count-1 array_add(order, cast(u32) e);
    for i: 0..vl.count-1 {
        if indices[i] == PoisonMaskElem continue;
        ext := cast(u64) indices[i] - min_idx;
        if order.*[ext] != e { array_reset_keeping_memory(order); return false; }
        keep &= ext == cast(u64) i;
        order.*[ext] = cast(u32) i;
    }
    if keep array_reset_keeping_memory(order);
    return keep;
}

// ---------------------------------------------------------------- canVectorizeLoads

LS_VECTORIZE :: 0; LS_COMPRESS :: 1; LS_SCATTER :: 2; LS_STRIDED :: 3; LS_GATHER :: 4;

slp_are_known_non_vectorizable_loads :: (vl: [] Value_Id) -> bool {
    k := slp_vl_key(vl);
    for slpx.known_non_vectorizable_loads if it == k return true;
    return false;
}
slp_register_non_vectorizable_loads :: (vl: [] Value_Id) {
    if !slp_are_known_non_vectorizable_loads(vl) array_add(*slpx.known_non_vectorizable_loads, slp_vl_key(vl));
}

// canVectorizeLoads(VL, VL0, Order, PointerOps, SPtrInfo, BestVF = nullptr, TryRecursiveCheck = true)
slp_can_vectorize_loads :: (vl: [] Value_Id, vl0: Value_Id, order: *[..] u32 = null, pointer_ops: *[..] Value_Id = null) -> s32 {
    lorder: [..] u32; lorder.allocator = temp;
    lptrs: [..] Value_Id; lptrs.allocator = temp;
    if !order order = *lorder;
    if !pointer_ops pointer_ops = *lptrs;
    if slp_are_known_non_vectorizable_loads(vl) return LS_GATHER;
    sty := vtype(vl0);
    if dl_type_size_bits(sty) != dl_type_alloc_size(sty) * 8 return LS_GATHER;
    array_reset_keeping_memory(pointer_ops);
    for v: vl {
        if !is_inst(v) || inst_op(v) != .LOAD || !is_simple_load_store(v) return LS_GATHER;
        array_add(pointer_ops, op(v, 0));
    }
    array_reset_keeping_memory(order);
    is_sorted, ord := sort_ptr_accesses(pointer_ops.*, sty);
    for ord array_add(order, it);
    sz := vl.count;
    vec_ty := slp_widened_type(sty, cast(u64) sz);
    common_align := inst(vl[0]).align;
    for vl common_align = min(common_align, inst(it).align);
    masked_gather_legal :: (vec_ty: Type_Id, align: u64) -> bool {
        return tti_is_legal_masked_gather(slp.tti, vec_ty, align) && !tti_force_scalarize_masked_gather(slp.tti, vec_ty, align);
    }
    if !is_sorted {
        // analyzeRtStrideCandidate: no legal strided loads on X86
        if !masked_gather_legal(vec_ty, common_align) return LS_GATHER;
        for p: pointer_ops.* if !slp_are_pointers_compatible(p, pointer_ops.*[0]) return LS_GATHER;
    } else {
        ptr0, ptrn: Value_Id;
        if order.count == 0 { ptr0 = pointer_ops.*[0]; ptrn = pointer_ops.*[sz - 1]; }
        else { ptr0 = pointer_ops.*[order.*[0]]; ptrn = pointer_ops.*[order.*[sz - 1]]; }
        _, diff0 := get_pointers_diff(sty, pointer_ops.*[0], sty, ptr0);
        _, diffn := get_pointers_diff(sty, pointer_ops.*[0], sty, ptrn);
        diff := diffn - diff0;
        if cast(u64) diff == cast(u64) (sz - 1) return LS_VECTORIZE;
        mc := slp_is_masked_load_compress(vl, pointer_ops.*, order.*);
        if mc.ok return LS_COMPRESS;
        // analyzeConstantStrideCandidate: no legal strided loads on X86
    }
    if !masked_gather_legal(vec_ty, common_align) return LS_GATHER;
    slp_fail("masked-gather cost check of canVectorizeLoads (CheckForShuffledLoads)");
    return LS_GATHER;
}
Masked_Load_Compress :: struct {
    ok: bool;
    is_masked: bool;
    interleave_factor: u32;
    compress_mask: [..] s32;
    load_vec_ty: Type_Id = NONE;
}

// buildCompressMask(PointerOps, Order, ScalarTy, DL, SE, CompressMask): (built, is strided)
slp_build_compress_mask :: (ptrs: [] Value_Id, order: [] u32, sty: Type_Id, mask: *[..] s32) -> (bool, bool) {
    sz := ptrs.count;
    mask.* = new_mask(sz);
    mask.*[0] = 0;
    has_stride := true;
    stride: s64 = 0;
    ptr0 := ifx order.count == 0 then ptrs[0] else ptrs[order[0]];
    for i: 1..sz-1 {
        ptr := ifx order.count == 0 then ptrs[i] else ptrs[order[i]];
        ok, pos := get_pointers_diff(sty, ptr0, sty, ptr);
        if !ok || pos > 0xFFFF_FFFF return false, false;
        p := cast(s64) (cast,no_check(u32) pos);
        mask.*[i] = cast,no_check(s32) p;
        if !has_stride continue;
        if stride == 0 { stride = p; continue; }
        if p != stride * i has_stride = false;
    }
    return true, has_stride;
}

// llvm::isSafeToLoadUnconditionally(V, Ty, Alignment, DL, ScanFrom, AC, DT, TLI)
slp_is_safe_to_load_unconditionally :: (v_in: Value_Id, ty: Type_Id, align: u64, scan_from: Value_Id) -> bool {
    size := dl_type_store_size(ty);
    q: Simplify_Query;
    q.dt = slp.dt; q.ac = slp.ac; q.cxt = scan_from;
    if is_dereferenceable_and_aligned_pointer(v_in, align, ap_from_u64(cast(u32) dl_pointer_type_size_bits(vtype(v_in)), size), q) {
        if scan_from == NONE return true;
        fa := attr_list_fn(glob(block_fn(inst_block(scan_from))).attrs);
        if !(attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress)) return true;
    }
    if scan_from == NONE return false;
    v := strip_pointer_casts(v_in);
    x := inst_prev(scan_from);
    while x != NONE {
        cur := x;
        x = inst_prev(x);
        o := inst_op(cur);
        if o == .CALL && may_write_to_memory(cur) && !is_lifetime_start_or_end(cur) return false;
        ptr: Value_Id; aty: Type_Id; al: u64;
        if o == .LOAD {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 0); aty = vtype(cur); al = inst(cur).align;
        } else if o == .STORE {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 1); aty = vtype(op(cur, 0)); al = inst(cur).align;
        } else continue;
        if al < align continue;
        if ptr == v && size <= dl_type_store_size(aty) return true;
        if equivalent_address_values(strip_pointer_casts(ptr), v) && size <= dl_type_store_size(aty) return true;
    }
    return false;
}

// isMaskedLoadCompress(VL, PointerOps, Order, TTI, DL, SE, AC, DT, TLI, AreAllUsersVectorized, IsMasked,
// InterleaveFactor, CompressMask, LoadVecTy)
slp_is_masked_load_compress :: (vl: [] Value_Id, ptrs: [] Value_Id, order: [] u32, all_users_vectorized := false) -> Masked_Load_Compress {
    r: Masked_Load_Compress;
    t := slp.tti;
    K :: TCK_RECIP_THROUGHPUT;
    sty := vtype(vl[0]);
    sz := vl.count;
    vec_ty := slp_widened_type(sty, cast(u64) sz);
    mask := slp_inverse_permutation(order);
    for v, i: vl {
        if all_users_vectorized || slp_are_all_users_vectorized(v, true) continue;
        ext := tti_vector_instr_cost(t, .EXTRACTELEMENT, vec_ty, K, cast(u32) (ifx mask.count == 0 then i else mask[i]));
        sc := tti_instruction_cost(t, v, K);
        if ext <= sc return r;
    }
    ptr0 := ifx order.count == 0 then ptrs[0] else ptrs[order[0]];
    ptrn := ifx order.count == 0 then ptrs[sz - 1] else ptrs[order[order.count - 1]];
    ok, diff := get_pointers_diff(sty, ptr0, sty, ptrn);
    if !ok return r;
    max_reg := tti_register_bit_width(t, RGK_FIXED_WIDTH_VECTOR);
    if (cast,no_check(u64) diff) / cast(u64) sz >= max_reg / 8 return r;
    load_vec_ty := slp_widened_type(sty, cast(u64) diff + 1);
    li := ifx order.count == 0 then vl[0] else vl[order[0]];
    common_align := inst(li).align;
    last := ifx order.count == 0 then vl[sz - 1] else vl[order[order.count - 1]];
    is_masked := !slp_is_safe_to_load_unconditionally(ptr0, load_vec_ty, common_align, last);
    if is_masked && !(t.kind == .X86 && x86_is_legal_masked_load(*t.xl, load_vec_ty)) return r;
    compress_mask: [..] s32;
    built, is_strided := slp_build_compress_mask(ptrs, order, sty, *compress_mask);
    if !built fatal("internal: slp: buildCompressMask failed after a successful getPointersDiff");
    ordered_ptrs := vl_copy(ptrs);
    if order.count slp_reorder_scalars(*ordered_ptrs, mask);
    scalar_gep, vector_gep := slp_gep_costs(ordered_ptrs, ordered_ptrs[0], .LOAD, sty, load_vec_ty);
    scalar_loads: Cost = 0;
    for v: vl scalar_loads = cost_add(scalar_loads, tti_instruction_cost(t, v, K));
    scalar_loads = cost_add(scalar_loads, scalar_gep);
    dem := NewArray(sz, bool,, temp);
    for * dem it.* = true;
    gather_cost := cost_add(slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, K), scalar_loads);
    load_cost: Cost;
    as := cast(u32) ir.types[vtype(op(li, 0))].a;
    if is_masked {
        m: Mica;
        m.id = IID_MASKED_LOAD; m.data_ty = load_vec_ty; m.align = common_align; m.addrspace = as;
        load_cost = x86_masked_memory_op_cost(t, *m, K);
    } else {
        load_cost = tti_memory_op_cost(t, .LOAD, load_vec_ty, common_align, as, K);
    }
    // isLegalInterleavedAccessType is false on X86: no segmented loads
    if cost_add(vector_gep, load_cost) >= gather_cost return r;
    compress_cost := slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, load_vec_ty, compress_mask);
    if order.count {
        nm := new_mask(sz);
        for i: 0..sz-1 nm[i] = compress_mask[mask[i]];
        compress_mask = nm;
    }
    total := cost_add(cost_add(vector_gep, load_cost), compress_cost);
    r.ok = total < gather_cost;
    r.is_masked = is_masked;
    r.compress_mask = compress_mask;
    r.load_vec_ty = load_vec_ty;
    return r;
}

// TTI::forceScalarizeMaskedGather (X86: needs AVX512 or Fast_gather for 2/4-wide; see X86TTIImpl)
tti_force_scalarize_masked_gather :: (t: *Tti, ty: Type_Id, align: u64) -> bool {
    if t.kind != .X86 return false;
    n := type_count(ty);
    st := *t.xl;
    return n == 1 || (st_hasAVX512(st) && (n == 2 || (n == 4 && !st_hasVLX(st))));
}

// isMaskedStoreCompress(VL, PointerOps, Order, TTI, DL, SE, CommonAlignment, ReuseShuffleIndices, StoreVecTy)
slp_is_masked_store_compress :: (vl: [] Value_Id, ptrs: [] Value_Id, order: [] u32, align: u64, reuse: *[..] s32) -> bool {
    sty := vtype(op(vl[0], 0));
    sz := vl.count;
    k := type_kind(sty);
    if sz < 2 || !(k == .INT || k == .PTR || is_fp_kind(k)) return false;
    ptr0 := ifx order.count == 0 then ptrs[0] else ptrs[order[0]];
    ptrn := ifx order.count == 0 then ptrs[sz - 1] else ptrs[order[sz - 1]];
    ok, diff := get_pointers_diff(sty, ptr0, sty, ptrn);
    if !ok || diff <= 0 return false;
    max_reg := tti_register_bit_width(slp.tti, RGK_FIXED_WIDTH_VECTOR);
    bits := dl_type_size_bits(sty);
    if bits == 0 || cast(u64) diff / cast(u64) sz >= max_reg / bits return false;
    store_vec_ty := slp_widened_type(sty, cast(u64) diff + 1);
    if !tti_is_legal_masked_store_const_mask(slp.tti, store_vec_ty, align) return false;
    slp_fail("masked stores of non-consecutive store chains (ExpandVectorize)");
    return false;
}
// TTI::isLegalMaskedStore(DataType, Alignment, AddressSpace, ConstantMask)
tti_is_legal_masked_store_const_mask :: (t: *Tti, ty: Type_Id, align: u64) -> bool {
    if t.kind != .X86 return false;
    return x86_is_legal_masked_store(*t.xl, ty);
}

// ---------------------------------------------------------------- getScalarsVectorizationState

slp_get_scalars_vectorization_state :: (s: Inst_State, vl: [] Value_Id, is_scatter_user: bool, current_order: *[..] u32, pointer_ops: *[..] Value_Id, reuse: *[..] s32) -> s32 {
    shuffle_or_op := ifx is_alt_shuffle(s) then Opcode.SHUFFLEVECTOR else is_opcode(s);
    vl0 := s.main;
    if shuffle_or_op == {
        case .PHI;
            if nops(vl0) > SLP_MAX_PHI_NUM_OPERANDS return TE_NEED_TO_GATHER;
            for v: vl {
                if !is_inst(v) || inst_op(v) != .PHI continue;
                for k: 0..cast(s64) phi_num_incoming(v) - 1 {
                    x := phi_value(v, cast(u32) k);
                    if is_inst(x) && is_terminator(inst_op(x)) return TE_NEED_TO_GATHER;
                }
            }
            return TE_VECTORIZE;
        case .EXTRACTELEMENT; #through;
        case .EXTRACTVALUE;
            if shuffle_or_op == .EXTRACTELEMENT {
                for v: vl {
                    if !is_inst(v) || inst_op(v) != .EXTRACTELEMENT return TE_NEED_TO_GATHER;
                    o := op(v, 0);
                    if slp_is_vectorized(o) return TE_NEED_TO_GATHER;
                    if is_inst(o) && is_terminator(inst_op(o)) return TE_NEED_TO_GATHER;
                }
            }
            reuse_ok := slp_can_reuse_extract(vl, current_order);
            if reuse_ok || current_order.count return TE_VECTORIZE;
            if shuffle_or_op == .EXTRACTVALUE {
                ok := slp_check_evs_for_vec_calls(vl, s);
                if ok return TE_VECTORIZE;
            }
            return TE_NEED_TO_GATHER;
        case .INSERTVALUE; #through;
        case .INSERTELEMENT;
            if shuffle_or_op == .INSERTVALUE {
                bad := false;
                for v: vl {
                    if is_inst(v) && inst_op(v) == .INSERTVALUE && (inst(v).nidx != 1 || !slp_is_valid_element_type(vtype(op(v, 1))) || is_vector_type(vtype(op(v, 1)))) { bad = true; break; }
                }
                none := true;
                for v: vl if is_inst(v) && inst_op(v) == .INSERTVALUE && pm_undef_value(op(v, 0)) { none = false; break; }
                if bad || none return TE_NEED_TO_GATHER;
            }
            sources: [..] Value_Id; sources.allocator = temp;
            for v: vl {
                if pm_poison(v) return TE_NEED_TO_GATHER;
                x := op(v, 0);
                dup := false; for sources if it == x { dup = true; break; }
                if !dup array_add(*sources, x);
            }
            contains :: (l: [] Value_Id, v: Value_Id) -> bool { for l if it == v return true; return false; }
            cnt := 0;
            for vl if !contains(sources, it) cnt += 1;
            if cnt >= 2 return TE_NEED_TO_GATHER;
            for vl if contains(sources, it) && !has_one_use(it) return TE_NEED_TO_GATHER;
            return TE_VECTORIZE;
        case .LOAD;
            st := slp_can_vectorize_loads(vl, vl0, current_order, pointer_ops);
            if st == LS_VECTORIZE return TE_VECTORIZE;
            if st == LS_GATHER {
                slp_register_non_vectorizable_loads(vl);
                return TE_NEED_TO_GATHER;
            }
            if st == LS_COMPRESS {
                if !slpx.is_graph_transform_mode && slp.entries.count > 1 {
                    n := cast(u32) slp.entries.count;
                    if !slp_has(slpx.load_entries_to_vectorize, n) array_add(*slpx.load_entries_to_vectorize, n);
                    return TE_NEED_TO_GATHER;
                }
                // IsGatheredNode()
                gathered := slpx.gathered_loads_first >= 0;
                if gathered for v: vl {
                    if pm_poison(v) continue;
                    any := false;
                    for slp_get_tree_entries(v) if it >= slpx.gathered_loads_first { any = true; break; }
                    if !any { gathered = false; break; }
                }
                return ifx gathered then TE_NEED_TO_GATHER else TE_COMPRESS_VECTORIZE;
            }
            slp_fail("scattered / strided loads");
            return TE_NEED_TO_GATHER;
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .FPEXT; #through; case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .BITCAST;
            src_ty := vtype(op(vl0, 0));
            for v: vl {
                if pm_poison(v) continue;
                t := vtype(op(v, 0));
                if t != src_ty || !slp_is_valid_element_type(t) return TE_NEED_TO_GATHER;
            }
            return TE_VECTORIZE;
        case .ICMP; #through; case .FCMP;
            p0 := inst(vl0).pred; sp0 := swapped_predicate(p0);
            cty := vtype(op(vl0, 0));
            for v: vl {
                if pm_poison(v) continue;
                p := inst(v).pred;
                if (p != p0 && p != sp0) || vtype(op(v, 0)) != cty return TE_NEED_TO_GATHER;
            }
            return TE_VECTORIZE;
        case .SELECT; #through; case .FNEG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through;
        case .FSUB; #through; case .MUL; #through; case .FMUL; #through; case .UDIV; #through; case .SDIV; #through;
        case .FDIV; #through; case .UREM; #through; case .SREM; #through; case .FREM; #through; case .SHL; #through;
        case .LSHR; #through; case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through;
        case .FREEZE;
            // isFPVectorizationPotentiallyUnsafe is false on X86
            return TE_VECTORIZE;
        case .GEP;
            for v: vl if is_inst(v) && inst_op(v) == .GEP && nops(v) != 2 return TE_NEED_TO_GATHER;
            ty0 := opr_gep_source_type(vl0);
            for v: vl if is_inst(v) && inst_op(v) == .GEP && opr_gep_source_type(v) != ty0 return TE_NEED_TO_GATHER;
            ty1 := vtype(op(vl0, 1));
            for v: vl {
                if !is_inst(v) || inst_op(v) != .GEP continue;
                o := op(v, 1);
                is_ci := vkind(o) == .C_INT;
                if (!is_scatter_user && !is_ci) ||
                   (vtype(o) != ty1 && ((is_scatter_user && !is_ci) || type_scalar_size_bits(vtype(o)) > dl_index_size_bits(ptr_addrspace(vtype(v)))))
                    return TE_NEED_TO_GATHER;
            }
            return TE_VECTORIZE;
        case .STORE;
            sty := vtype(op(vl0, 0));
            if dl_type_size_bits(sty) != dl_type_alloc_size(sty) * 8 return TE_NEED_TO_GATHER;
            for v: vl {
                if !is_simple_load_store(v) return TE_NEED_TO_GATHER;
                array_add(pointer_ops, op(v, 1));
            }
            sorted, ord := sort_ptr_accesses(pointer_ops.*, sty);
            array_reset_keeping_memory(current_order);
            for ord array_add(current_order, it);
            if sorted {
                ptr0, ptrn: Value_Id;
                if current_order.count == 0 { ptr0 = pointer_ops.*[0]; ptrn = pointer_ops.*[pointer_ops.count - 1]; }
                else { ptr0 = pointer_ops.*[current_order.*[0]]; ptrn = pointer_ops.*[current_order.*[current_order.count - 1]]; }
                align := inst(vl[0]).align;
                for vl align = min(align, inst(it).align);
                _, dist := get_pointers_diff(sty, ptr0, sty, ptrn);
                if cast(u64) dist == cast(u64) (vl.count - 1) return TE_VECTORIZE;
                // analyzeConstantStrideCandidate (-slp-enable-strided-stores): no legal strided stores on X86
                if slp_cl.masked_stores && slp_is_masked_store_compress(vl, pointer_ops.*, current_order.*, align, reuse) return TE_EXPAND_VECTORIZE;
            }
            return TE_NEED_TO_GATHER;
        case .CALL;
            ci := vl0;
            id := get_vector_intrinsic_id_for_call(ci);
            if call_has_vector_variants(ci) slp_fail("vector library calls (VFDatabase)");
            if !is_trivially_vectorizable(id) return TE_NEED_TO_GATHER;
            if type_kind(vtype(ci)) == .STRUCT {
                for v: vl {
                    if type_kind(vtype(v)) != .STRUCT continue;
                    u := ir.v_first_use[v];
                    while u != NONE { usr := ir.u_user[u]; u = ir.u_next[u]; if !is_inst(usr) || inst_op(usr) != .EXTRACTVALUE return TE_NEED_TO_GATHER; }
                }
            }
            f := call_called_function(ci);
            n := cast(s64) call_num_args(ci);
            for v: vl {
                if !is_inst(v) || inst_op(v) != .CALL || call_called_function(v) != f || get_vector_intrinsic_id_for_call(v) != id return TE_NEED_TO_GATHER;
                if call_num_bundles(v) != call_num_bundles(ci) slp_fail("operand bundles on vectorized calls");
                for j: 0..n-1 {
                    if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) j) && call_arg(v, cast(u32) j) != call_arg(ci, cast(u32) j) return TE_NEED_TO_GATHER;
                }
                if call_num_bundles(ci) > 0 slp_fail("operand bundles on vectorized calls");
            }
            arg_tys := slp_build_intrinsic_arg_types(ci, id, cast(u64) vl.count, 0);
            vec_ty := slp_widened_type(vtype(s.main), cast(u64) vl.count);
            ic, lc := slp_vector_call_costs(ci, vec_ty, arg_tys);
            if !cost_valid(ic) && !cost_valid(lc) return TE_NEED_TO_GATHER;
            return TE_VECTORIZE;
        case .SHUFFLEVECTOR;
            if !is_alt_shuffle(s) return TE_NEED_TO_GATHER;
            return TE_VECTORIZE;
    }
    return TE_NEED_TO_GATHER;
}

// ---------------------------------------------------------------- loops

// findInnermostNonInvariantLoop(L, VL)
slp_find_innermost_non_invariant_loop :: (l_in: Loop_Id, vl: [] Value_Id) -> Loop_Id {
    l := l_in;
    while l != NONE {
        inv := true;
        for v: vl {
            if is_constant_kind(vkind(v)) || !is_inst(v) || li_is_loop_invariant(slp.li, l, v) continue;
            inv = false; break;
        }
        if !inv break;
        l = li_parent(slp.li, l);
    }
    return l;
}
// getLoopNest(L)
slp_get_loop_nest :: (l_in: Loop_Id) -> [..] Loop_Id {
    r: [..] Loop_Id; r.allocator = temp;
    if slp_cl.loop_trip_count == 0 return r;
    l := l_in;
    while l != NONE { array_insert_at(*r, l, 0); l = li_parent(slp.li, l); }
    return r;
}

// ---------------------------------------------------------------- buildTreeRec

slp_build_tree_rec :: (vl_ref: [] Value_Id, depth: u32, ei: Edge_Info, interleave: u32 = 0) {
    reuse: [..] s32; reuse.allocator = temp;
    vl := vl_copy(vl_ref);
    // TrySplitNode(LocalState)
    try_split_node :: (vl: [] Value_Id, ls: Inst_State, depth: u32, ei: Edge_Info) -> bool {
        ok, op1, op2, reorder := slp_can_build_split_node_full(vl, ls);
        if !ok return false;
        te := slp_new_tree_entry_state(vl, TE_SPLIT_VECTORIZE, -1, ls, ei, .[], reorder);
        add_node :: (te: Te_Id, o: [] Value_Id, idx: u32, op1_count: s64, depth: u32) {
            s := slp_get_same_opcode(o);
            off := cast(u32) ifx idx == 0 then 0 else op1_count;
            array_add(*slp.entries[te].combined_entries_with_indices, .[cast(u32) slp.entries.count, off]);
            if is_valid(s) && (inst_op(s.main) == .LOAD || slp_get_same_values_tree_entry(s.main, o, true) != TE_NONE)
                slp_new_tree_entry_state(o, TE_NEED_TO_GATHER, -1, s, .{te, idx});
            else
                slp_build_tree_rec(o, depth, .{te, idx});
        }
        add_node(te, op1, 0, op1.count, depth);
        add_node(te, op2, 1, op1.count, depth);
        return true;
    }
    // AreOnlyConstsWithPHIs
    {
        are_consts := false;
        only := true;
        for v: vl {
            if pm_poison(v) continue;
            if is_constant_kind(vkind(v)) { are_consts = true; continue; }
            if !(is_inst(v) && inst_op(v) == .PHI) { only = false; break; }
        }
        if only && are_consts { slp_new_gather_tree_entry(vl, IS_INVALID, ei); return; }
    }
    legality := slp_get_scalars_vectorization_legality(vl, depth, ei);
    s := legality.s;
    if !legality.is_legal {
        if legality.try_split_vectorize {
            main, alt := slp_main_alt_ops_no_state_vl(vl);
            if main != NONE && alt != NONE && try_split_node(vl, .{main, alt, false}, depth, ei) return;
        }
        if legality.try_to_find_duplicates slp_try_to_find_duplicates(*vl, *reuse, s, ei);
        slp_new_gather_tree_entry(vl, s, ei, reuse);
        return;
    }
    if is_alt_shuffle(s) && try_split_node(vl, s, depth, ei) return;
    if !slp_try_to_find_duplicates(*vl, *reuse, s, ei, false) {
        slp_new_gather_tree_entry(vl, s, ei, reuse);
        return;
    }
    is_scatter_user := ei.user != TE_NONE && slp.entries[ei.user].state == TE_SCATTER_VECTORIZE;
    current_order: [..] u32; current_order.allocator = temp;
    pointer_ops: [..] Value_Id; pointer_ops.allocator = temp;
    expand_mask: [..] s32; expand_mask.allocator = temp;
    state := slp_get_scalars_vectorization_state(s, vl, is_scatter_user, *current_order, *pointer_ops, *expand_mask);
    if state == TE_NEED_TO_GATHER {
        slp_new_gather_tree_entry(vl, s, ei, reuse);
        return;
    }
    // loop nest bookkeeping (loop-aware cost scaling)
    if slp.entries.count == 0 {
        l := li_loop_for(slp.li, inst_block(s.main));
        if l != NONE {
            l = slp_find_innermost_non_invariant_loop(l, vl);
            if l != NONE { array_reset_keeping_memory(*slpx.current_loop_nest); for slp_get_loop_nest(l) array_add(*slpx.current_loop_nest, it); }
        }
    } else if ei.user == TE_NONE || slp.entries[ei.user].state == TE_SPLIT_VECTORIZE || te_is_gather(ei.user) ||
              inst_block(slp.entries[ei.user].s.main) != inst_block(s.main) {
        l := li_loop_for(slp.li, inst_block(s.main));
        if l != NONE {
            l = slp_find_innermost_non_invariant_loop(l, vl);
            if l != NONE {
                new_nest := slp_get_loop_nest(l);
                common := 0;
                for k: 0..min(slpx.current_loop_nest.count, new_nest.count)-1 { if slpx.current_loop_nest[k] != new_nest[k] break; common += 1; }
                validate :: (new_nest: [] Loop_Id, start: s64) -> bool {
                    end := min(new_nest.count, slpx.merged_loop_btcs.count);
                    for d: start..end-1 {
                        c := slpx.merged_loop_btcs[d];
                        if c == NONE continue;
                        nb := sc_get_backedge_taken_count(new_nest[d]);
                        if sc_is_cnc(nb) || nb != c return false;
                    }
                    return true;
                }
                if slpx.current_loop_nest.count == 0 {
                    if !validate(new_nest, 0) { slp_new_gather_tree_entry(vl, s, ei, reuse); return; }
                    for new_nest array_add(*slpx.current_loop_nest, it);
                } else if common < slpx.current_loop_nest.count && common < new_nest.count {
                    bec_a := sc_get_backedge_taken_count(slpx.current_loop_nest[common]);
                    bec_b := sc_get_backedge_taken_count(new_nest[common]);
                    if sc_is_cnc(bec_a) || bec_a != bec_b { slp_new_gather_tree_entry(vl, s, ei, reuse); return; }
                    if !validate(new_nest, common + 1) { slp_new_gather_tree_entry(vl, s, ei, reuse); return; }
                    while slpx.merged_loop_btcs.count <= common array_add(*slpx.merged_loop_btcs, NONE);
                    slpx.merged_loop_btcs[common] = bec_a;
                    slpx.current_loop_nest.count = common;
                } else if new_nest.count > slpx.current_loop_nest.count {
                    if !validate(new_nest, slpx.current_loop_nest.count) { slp_new_gather_tree_entry(vl, s, ei, reuse); return; }
                    for k: slpx.current_loop_nest.count..new_nest.count-1 array_add(*slpx.current_loop_nest, new_nest[k]);
                }
            }
        }
    }
    vl0 := s.main;
    bb := inst_block(vl0);
    bs := slp_block_sched(bb);
    uniques: [..] Value_Id; uniques.allocator = temp;
    for v: vl { dup := false; for uniques if it == v { dup = true; break; } if !dup array_add(*uniques, v); }
    has_bundle, bundle := bs_try_schedule_bundle(bs, uniques, s, ei);
    if !has_bundle {
        if is_alt_shuffle(s) && reuse.count == 0 && try_split_node(vl, s, depth, ei) return;
        if s.has_copyables && reuse.count == 0 {
            alt_s := slp_get_same_opcode(vl);
            if is_valid(alt_s) && is_alt_shuffle(alt_s) && try_split_node(vl, alt_s, depth, ei) return;
        }
        slp_new_gather_tree_entry(vl, s, ei, reuse);
        table_set(*slpx.non_scheduled_first, vl[0], true);
        if is_opcode(s) == .LOAD && bs.region_size < bs.region_size_limit slp_register_non_vectorizable_loads(vl);
        return;
    }
    a: Ica_State;
    operands := ica_build_operands(*a, s, vl);
    slpx.cur_bundle_sched = bs;
    b := ifx bundle >= 0 then bundle else -2;   // -2: the empty bundle of a node that needs no scheduling
    shuffle_or_op := ifx is_alt_shuffle(s) then Opcode.SHUFFLEVECTOR else is_opcode(s);
    create_operand_nodes :: (te: Te_Id, operands: [] [..] Value_Id, depth: u32) {
        phi_ops: [..] u32; phi_ops.allocator = temp;
        for o, k: operands {
            if o.count == 0 continue;
            os := slp_get_same_opcode(o);
            if !is_valid(os) || is_opcode(os) != .PHI || is_alt_shuffle(os) slp_build_tree_rec(o, depth + 1, .{te, cast(u32) k});
            else array_add(*phi_ops, cast(u32) k);
        }
        for k: phi_ops slp_build_tree_rec(operands[k], depth + 1, .{te, k});
    }
    te_operand :: (te: Te_Id, k: s64) -> [] Value_Id { return slp.entries[te].operands[k]; }
    if shuffle_or_op == {
        case .PHI;
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            te_set_operands(te, operands);
            create_operand_nodes(te, operands, depth);
            return;
        case .EXTRACTVALUE; #through;
        case .EXTRACTELEMENT;
            if current_order.count slp_fixup_ordering_indices(current_order);
            te := slp_new_tree_entry(vl, b, s, ei, reuse, current_order);
            te_set_operands(te, operands);
            if shuffle_or_op == .EXTRACTVALUE {
                ok := slp_check_evs_for_vec_calls(vl, s);
                if ok {
                    for k: 0..cast(s64) inst(vl0).nidx - 1 array_add(*slp.entries[te].struct_ev_indices, ir.u32_pool[inst(vl0).idx + cast(u32) k]);
                    slp_build_tree_rec(operands[0], depth + 1, .{te, 0});
                }
            }
            return;
        case .INSERTVALUE; #through;
        case .INSERTELEMENT;
            // PriorityQueue of (index, lane) ordered by smallest index first
            n := vl.count;
            idxs := NewArray(n, u64,, temp);
            for v, i: vl { _, x := slp_element_index(v); idxs[i] = x; }
            order: [..] u32; order.allocator = temp;
            for 0..n-1 array_add(*order, cast(u32) n);
            used := NewArray(n, bool,, temp);
            identity := true;
            for i: 0..n-1 {
                best := -1;
                for j: 0..n-1 {
                    if used[j] continue;
                    // std::priority_queue with `P1.first > P2.first`: equal indices pop in heap order; insertelement
                    // indices of one build vector are unique
                    if best < 0 || idxs[j] < idxs[best] best = j;
                }
                used[best] = true;
                order[best] = cast(u32) i;
                identity &= best == i;
            }
            if identity array_reset_keeping_memory(*order);
            te := slp_new_tree_entry(vl, b, s, ei, .[], order);
            te_set_operands(te, operands);
            slp_build_tree_rec(te_operand(te, 1), depth + 1, .{te, 1});
            return;
        case .LOAD;
            slp_fixup_ordering_indices(current_order);
            te: Te_Id;
            if state == TE_VECTORIZE te = slp_new_tree_entry(vl, b, s, ei, reuse, current_order, interleave);
            else if state == TE_COMPRESS_VECTORIZE te = slp_new_tree_entry_state(vl, TE_COMPRESS_VECTORIZE, b, s, ei, reuse, current_order);
            else slp_fail("non-consecutive load nodes");
            if current_order.count && state != TE_SCATTER_VECTORIZE {
                mask := slp_inverse_permutation(current_order);
                slp_reorder_scalars(*operands[0], mask);
            }
            te_set_operands(te, operands);
            return;
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .FPEXT; #through; case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .BITCAST;
            prev_max: u64 = 0; prev_min: u64 = 0xFFFF_FFFF;
            if slpx.has_cast_max_min_bw { prev_max = slpx.cast_max_bw; prev_min = slpx.cast_min_bw; }
            if shuffle_or_op == .ZEXT || shuffle_or_op == .SEXT {
                slpx.has_cast_max_min_bw = true;
                slpx.cast_max_bw = max(dl_type_size_bits(vtype(vl0)), prev_max);
                slpx.cast_min_bw = min(dl_type_size_bits(vtype(op(vl0, 0))), prev_min);
            } else if shuffle_or_op == .TRUNC {
                slpx.has_cast_max_min_bw = true;
                slpx.cast_max_bw = max(dl_type_size_bits(vtype(op(vl0, 0))), prev_max);
                slpx.cast_min_bw = min(dl_type_size_bits(vtype(vl0)), prev_min);
            }
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            te_set_operands(te, operands);
            for k: 0..cast(s64) nops(vl0) - 1 slp_build_tree_rec(te_operand(te, k), depth, .{te, cast(u32) k});
            if shuffle_or_op == .TRUNC {
                slp_add_extra_bitwidth_node(slp_get_operand_entry(te, 0));
            } else if shuffle_or_op == .SITOFP || shuffle_or_op == .UITOFP {
                o0 := op(vl0, 0);
                nsb := num_sign_bits_ctx(o0, NONE, slp.dt, slp.ac);
                if is_inst(o0) nsb = max(nsb, ap_clz(db_demanded_bits(slpx.db, o0)));
                if cast(u64) nsb * 2 >= dl_type_size_bits(vtype(o0)) slp_add_extra_bitwidth_node(slp_get_operand_entry(te, 0));
            }
            return;
        case .ICMP; #through; case .FCMP;
            p0 := inst(vl0).pred;
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            ops := vlo_init(vl, operands, s);
            if slp_cmp_is_commutative(vl0) {
                vlo_reorder(*ops);
                operands[0] = vlo_get_vl(*ops, 0);
                operands[operands.count - 1] = vlo_get_vl(*ops, 1);
            } else {
                for v, idx: vl {
                    if pm_poison(v) continue;
                    if inst(v).pred != p0 { t := operands[0][idx]; operands[0][idx] = operands[operands.count - 1][idx]; operands[operands.count - 1][idx] = t; }
                }
            }
            te_set_operands(te, operands);
            slp_build_tree_rec(operands[0], depth, .{te, 0});
            slp_build_tree_rec(operands[operands.count - 1], depth, .{te, 1});
            if shuffle_or_op == .ICMP {
                n0 := num_sign_bits_ctx(op(vl0, 0), NONE, slp.dt, slp.ac);
                if cast(u64) n0 * 2 >= dl_type_size_bits(vtype(op(vl0, 0))) slp_add_extra_bitwidth_node(slp_get_operand_entry(te, 0));
                n1 := num_sign_bits_ctx(op(vl0, 1), NONE, slp.dt, slp.ac);
                if cast(u64) n1 * 2 >= dl_type_size_bits(vtype(op(vl0, 1))) slp_add_extra_bitwidth_node(slp_get_operand_entry(te, 1));
            }
            return;
        case .SELECT; #through; case .FNEG; #through; case .ADD; #through; case .FADD; #through; case .SUB; #through;
        case .FSUB; #through; case .MUL; #through; case .FMUL; #through; case .UDIV; #through; case .SDIV; #through;
        case .FDIV; #through; case .UREM; #through; case .SREM; #through; case .FREM; #through; case .SHL; #through;
        case .LSHR; #through; case .ASHR; #through; case .AND; #through; case .OR; #through; case .XOR; #through;
        case .FREEZE;
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            if is_binary_op(inst_op(vl0)) && slp_is_commutative(vl0) {
                ops := vlo_init(vl, operands, s);
                vlo_reorder(*ops);
                operands[0] = vlo_get_vl(*ops, 0);
                operands[1] = vlo_get_vl(*ops, 1);
            }
            te_set_operands(te, operands);
            for k: 0..cast(s64) nops(vl0) - 1 slp_build_tree_rec(te_operand(te, k), depth + 1, .{te, cast(u32) k});
            return;
        case .GEP;
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            te_set_operands(te, operands);
            for k: 0..operands.count-1 slp_build_tree_rec(operands[k], depth + 1, .{te, cast(u32) k});
            return;
        case .STORE;
            if state == TE_STRIDED_VECTORIZE || state == TE_EXPAND_VECTORIZE slp_fail("strided / expanded store nodes");
            te := slp_new_tree_entry(vl, b, s, ei, reuse, current_order);
            te_set_operands(te, operands);
            slp_build_tree_rec(te_operand(te, 0), depth + 1, .{te, 0});
            return;
        case .CALL;
            id := get_vector_intrinsic_id_for_call(vl0);
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            if slp_is_commutative(vl0) {
                ops := vlo_init(vl, operands, s);
                vlo_reorder(*ops);
                operands[0] = vlo_get_vl(*ops, 0);
                operands[1] = vlo_get_vl(*ops, 1);
            }
            te_set_operands(te, operands);
            for k: 0..cast(s64) call_num_args(vl0) - 1 {
                if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) continue;
                slp_build_tree_rec(te_operand(te, k), depth + 1, .{te, cast(u32) k});
            }
            return;
        case .SHUFFLEVECTOR;
            te := slp_new_tree_entry(vl, b, s, ei, reuse);
            is_ci := is_cmp_inst(vl0);
            any_non_comm := false;
            if is_ci for v: vl if !pm_poison(v) && !slp_cmp_is_commutative(v) { any_non_comm = true; break; }
            if is_ci && any_non_comm {
                main_p := inst(s.main).pred; alt_p := inst(s.alt).pred;
                for v, idx: vl {
                    if pm_poison(v) continue;
                    swap := false;
                    if slp_is_alternate_instruction(v, s.main, s.alt) swap = alt_p == swapped_predicate(inst(v).pred);
                    else swap = main_p == swapped_predicate(inst(v).pred);
                    if swap { t := operands[0][idx]; operands[0][idx] = operands[operands.count - 1][idx]; operands[operands.count - 1][idx] = t; }
                }
                te_set_operands(te, operands);
                slp_build_tree_rec(operands[0], depth + 1, .{te, 0});
                slp_build_tree_rec(operands[operands.count - 1], depth + 1, .{te, 1});
                return;
            }
            if is_binary_op(inst_op(vl0)) || is_ci {
                ops := vlo_init(vl, operands, s);
                vlo_reorder(*ops);
                operands[0] = vlo_get_vl(*ops, 0);
                operands[1] = vlo_get_vl(*ops, 1);
            }
            te_set_operands(te, operands);
            for k: 0..cast(s64) nops(vl0) - 1 slp_build_tree_rec(te_operand(te, k), depth + 1, .{te, cast(u32) k});
            return;
    }
    fatal("internal: slp: unexpected vectorization of the instructions");
}
// CmpInst::isCommutative
slp_cmp_is_commutative :: (c: Value_Id) -> bool {
    if inst_op(c) == .ICMP return icmp_is_equality(inst(c).pred);
    return fcmp_is_commutative(inst(c).pred);
}
slp_add_extra_bitwidth_node :: (te: Te_Id) {
    for slpx.extra_bitwidth_nodes if it == te return;
    array_add(*slpx.extra_bitwidth_nodes, te);
}

// ---------------------------------------------------------------- tiny trees

// isFullyVectorizableTinyTree(ForReduction)
slp_is_fully_vectorizable_tiny_tree :: (for_reduction: bool) -> bool {
    are_vectorizable_gathers :: (te: Te_Id, limit: s64) -> bool {
        e := *slp.entries[te];
        if !te_is_gather(te) return false;
        for e.scalars if table_contains(*slpx.eph_values, it) return false;
        if slp_all_constant(e.scalars) || slp_is_splat(e.scalars) || e.scalars.count < limit return true;
        all_ee := true;
        for e.scalars if !((is_inst(it) && inst_op(it) == .EXTRACTELEMENT) || pm_undef_value(it)) { all_ee = false; break; }
        if (te_has_state(te) && te_opcode(te) == .EXTRACTELEMENT) || all_ee {
            fixed := slp_is_fixed_vector_shuffle(e.scalars, slp.ac);
            if fixed return true;
        }
        if te_has_state(te) && te_opcode(te) == .LOAD && !is_alt_shuffle(e.s) return true;
        for e.scalars if is_inst(it) && inst_op(it) == .LOAD return true;
        return false;
    }
    n := slp.entries.count;
    st0 := slp.entries[0].state;
    if n == 1 && (st0 == TE_VECTORIZE || st0 == TE_STRIDED_VECTORIZE || st0 == TE_EXPAND_VECTORIZE || st0 == TE_COMPRESS_VECTORIZE ||
                  (for_reduction && are_vectorizable_gathers(0, slp.entries[0].scalars.count) && te_vector_factor(0) > 2))
        return true;
    if n != 2 return false;
    if st0 == TE_VECTORIZE && are_vectorizable_gathers(1, slp.entries[0].scalars.count) return true;
    if te_is_gather(0) || (te_is_gather(1) && st0 != TE_SCATTER_VECTORIZE && st0 != TE_STRIDED_VECTORIZE &&
                           st0 != TE_EXPAND_VECTORIZE && st0 != TE_COMPRESS_VECTORIZE) return false;
    return true;
}

// isTreeTinyAndNotFullyVectorizable(ForReduction)
slp_is_tree_tiny_and_not_fully_vectorizable :: (for_reduction := false) -> bool {
    if slp.entries.count == 0 return true;
    for te: 0..slp.entries.count-1 if te_is_gather(cast(Te_Id) te) && type_kind(vtype(slp.entries[te].scalars[0])) == .STRUCT return true;
    tree_size := slp.entries.count;
    front := cast(Te_Id) 0;
    fe := *slp.entries[0];
    front_is_gather := te_is_gather(front);
    front_has_state := te_has_state(front);
    front_opcode := ifx front_has_state then te_opcode(front) else .NONE_OP;
    threshold_set := slp_cl.threshold_given;
    threshold_non_negative := slp_cl.threshold >= 0;
    LIMIT :: 4;
    LARGE_TREE :: 20;
    LIMIT_TREE_SIZE :: 36;
    is_ee :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .EXTRACTELEMENT; }
    count_ee :: (l: [] Value_Id) -> s64 { c := 0; for l if is_ee(it) c += 1; return c; }
    if !for_reduction {
        if tree_size == 1 && front_is_gather {
            if front_has_state && front_opcode == .EXTRACTELEMENT return true;
            for fe.scalars if is_inst(it) return true;
        }
        if tree_size <= slp_cl.min_tree_size {
            all := true;
            for te: 0..tree_size-1 if !(te_is_gather(cast(Te_Id) te) || slp.entries[te].state == TE_SPLIT_VECTORIZE) { all = false; break; }
            if all return true;
        }
        if tree_size == 1 && slp_cl.threshold < 0 && front_has_state && front_opcode == .EXTRACTELEMENT {
            all := true;
            for v: fe.scalars if is_inst(v) && slp_are_all_users_vectorized(v, true) { all = false; break; }
            if te_vector_factor(front) == 2 || all return true;
        }
    }
    if tree_size == 2 && is_inst(fe.scalars[0]) && inst_op(fe.scalars[0]) == .INSERTELEMENT && te_is_gather(1) &&
       (te_vector_factor(1) <= 2 || !(slp_is_splat(slp.entries[1].scalars) || slp_all_constant(slp.entries[1].scalars)))
        return true;
    if tree_size == 3 && slp_cl.threshold == 0 && (!for_reduction || te_vector_factor(front) <= 2) {
        all := true;
        for te: 1..tree_size-1 {
            e := *slp.entries[te];
            all_const_like := true;
            for e.scalars if !(is_ee(it) || pm_undef_value(it) || is_constant_kind(vkind(it))) { all_const_like = false; break; }
            if !(te_is_gather(cast(Te_Id) te) && te_vector_factor(cast(Te_Id) te) <= LIMIT && !all_const_like) { all = false; break; }
        }
        if all return true;
    }
    if !for_reduction {
        if !threshold_set {
            all := true;
            for te: 0..tree_size-1 {
                t := cast(Te_Id) te;
                g := te_is_gather(t); hs := te_has_state(t);
                o := ifx hs then te_opcode(t) else .NONE_OP;
                if g && (!hs || o != .EXTRACTELEMENT) && count_ee(slp.entries[te].scalars) <= LIMIT continue;
                if hs && o == .PHI continue;
                all = false; break;
            }
            if all return true;
        }
        if threshold_set && tree_size <= LIMIT {
            has_vector_phi := false;
            all := true;
            for te: 0..tree_size-1 {
                t := cast(Te_Id) te;
                g := te_is_gather(t); hs := te_has_state(t);
                o := ifx hs then te_opcode(t) else .NONE_OP;
                ok := false;
                if g && (!hs || o != .EXTRACTELEMENT) && count_ee(slp.entries[te].scalars) <= LIMIT ok = true;
                else if !hs ok = false;
                else if o == .INSERTELEMENT ok = true;
                else if o != .PHI ok = false;
                else {
                    if slp.entries[te].state == TE_VECTORIZE has_vector_phi = true;
                    ok = true;
                    for v: slp.entries[te].scalars if !(pm_poison(v) || table_contains(*slp.must_gather, v)) { ok = false; break; }
                }
                if !ok { all = false; break; }
            }
            if all && has_vector_phi return true;
        }
        if threshold_non_negative {
            is_large := tree_size >= LARGE_TREE;
            has_single_load := false;
            all := true;
            for te: 0..tree_size-1 {
                t := cast(Te_Id) te;
                e := *slp.entries[te];
                g := te_is_gather(t); hs := te_has_state(t);
                o := ifx hs then te_opcode(t) else .NONE_OP;
                r := false;
                decided := false;
                if is_large {
                    prev_load := has_single_load;
                    has_single_load |= hs && !g && (o == .LOAD || slp_te_has_copyables(t)) && (te_vector_factor(t) > 2 || e.reorder_indices.count == 0);
                    if hs {
                        if o == .PHI { r = true; decided = true; }
                        else if te_vector_factor(t) <= LIMIT && (o == .STORE || (o == .LOAD && !prev_load)) { r = true; decided = true; }
                    }
                } else if hs && o == .PHI { r = true; decided = true; }
                if !decided r = g && (!hs || o != .EXTRACTELEMENT);
                if !r { all = false; break; }
            }
            if all return true;
            if tree_size >= 5 && te_vector_factor(front) <= 2 && type_kind(vtype(fe.scalars[0])) == .INT {
                vector_node_found := false;
                any_non_const := false;
                all2 := true;
                for te: 0..tree_size-1 {
                    t := cast(Te_Id) te;
                    e := *slp.entries[te];
                    if e.state == TE_VECTORIZE && te_has_state(t) {
                        o := te_opcode(t);
                        if o == .PHI || e.reorder_indices.count continue;
                        if vector_node_found { all2 = false; break; }
                        vector_node_found = true;
                        continue;
                    }
                    if !any_non_const any_non_const = !slp_all_constant(e.scalars);
                    if !(te_is_gather(t) || e.state == TE_SPLIT_VECTORIZE) { all2 = false; break; }
                }
                if all2 && any_non_const return true;
            }
        }
        is_benign :: (t: Te_Id, tree_size: s64) -> bool {
            e := *slp.entries[t];
            if e.state == TE_SPLIT_VECTORIZE return true;
            g := te_is_gather(t);
            if te_has_state(t) {
                o := te_opcode(t);
                if o == .PHI return true;
                n := e.scalars.count;
                if e.idx == 0 && n == 2 && o == .ICMP && tree_size > LIMIT_TREE_SIZE return true;
                if n == 2 && (e.reuse_shuffle_indices.count || e.reorder_indices.count || is_alt_shuffle(e.s)) return true;
                if slp_te_has_copyables(t) {
                    c := 0;
                    for e.scalars if (is_inst(it) && inst_op(it) == .PHI) || is_constant_kind(vkind(it)) c += 1;
                    if c >= n / 2 return true;
                }
            }
            if !g return false;
            for e.scalars if is_ee(it) return false;
            return true;
        }
        if !threshold_set {
            store_load: [..] Te_Id; store_load.allocator = temp;
            num_gathers := 0;
            all := true;
            for te: 0..tree_size-1 {
                t := cast(Te_Id) te;
                g := te_is_gather(t);
                if !g && te_has_state(t) {
                    o := te_opcode(t);
                    if o == .LOAD || o == .STORE { array_add(*store_load, t); continue; }
                }
                if g num_gathers += 1;
                if !is_benign(t, tree_size) { all = false; break; }
            }
            if all {
                ok := store_load.count == 0;
                if !ok && tree_size > LIMIT_TREE_SIZE * store_load.count {
                    if num_gathers > 0 ok = true;
                    else {
                        none := true;
                        for t: store_load {
                            if te_opcode(t) == .STORE { none = false; break; }
                            all_uv := true;
                            for v: slp.entries[t].scalars if is_inst(v) && inst_op(v) == .LOAD && !slp_are_all_users_vectorized(v) { all_uv = false; break; }
                            if all_uv { none = false; break; }
                        }
                        ok = none;
                    }
                }
                if ok return true;
            }
        }
        if threshold_non_negative && tree_size > LIMIT_TREE_SIZE {
            vector_node := TE_NONE;
            all := true;
            for te: 0..tree_size-1 {
                t := cast(Te_Id) te;
                if !te_is_gather(t) && te_has_state(t) && slp.entries[te].state != TE_SPLIT_VECTORIZE && te_opcode(t) != .PHI {
                    if vector_node != TE_NONE { all = false; break; }
                    vector_node = t;
                    continue;
                }
                if !is_benign(t, tree_size) { all = false; break; }
            }
            if all return true;
        }
        if threshold_set && tree_size >= LIMIT && fe.state == TE_SPLIT_VECTORIZE {
            c := 0;
            for te: 1..tree_size-1 {
                e := *slp.entries[te];
                if !te_is_gather(cast(Te_Id) te) && e.user_tree_index.user != TE_NONE && slp.entries[e.user_tree_index.user].idx == 0 c += 1;
            }
            if c == 2 return true;
        }
        if threshold_set && tree_size > 2 && fe.state == TE_VECTORIZE && front_opcode == .INSERTELEMENT &&
           slp.entries[1].state == TE_VECTORIZE && te_opcode(1) == .PHI {
            all := true;
            for te: 2..tree_size-1 if !te_is_gather(cast(Te_Id) te) { all = false; break; }
            if all return true;
        }
    }
    if tree_size >= slp_cl.min_tree_size return false;
    if slp_is_fully_vectorizable_tiny_tree(for_reduction) return false;
    allowed_single_bv := tree_size > 1 || (front_has_state && !is_alt_shuffle(fe.s) && front_opcode != .PHI && front_opcode != .GEP && slp_all_same_block(fe.scalars));
    for te: 0..tree_size-1 {
        if !te_is_gather(cast(Te_Id) te) continue;
        all := true;
        for v: slp.entries[te].scalars {
            if is_ee(v) || is_constant_kind(vkind(v)) continue;
            if allowed_single_bv && !has_n_uses_or_more(v, SLP_USES_LIMIT) {
                any_ins := false;
                u := ir.v_first_use[v];
                while u != NONE { usr := ir.u_user[u]; u = ir.u_next[u]; if is_inst(usr) && inst_op(usr) == .INSERTELEMENT { any_ins = true; break; } }
                if any_ins continue;
            }
            all = false; break;
        }
        if all return false;
    }
    back := cast(Te_Id) (tree_size - 1);
    if te_is_gather(back) && te_has_state(back) && is_alt_shuffle(slp.entries[back].s) {
        bvf := te_vector_factor(back);
        bsc := slp.entries[back].scalars;
        if bvf > 2 && slp_all_same_block(bsc) && !is_vector_type(vtype(bsc[0])) {
            dem := NewArray(bvf, bool,, temp); for * dem it.* = true;
            if tti_scalarization_overhead(slp.tti, slp_widened_type(vtype(bsc[0]), cast(u64) bvf), dem, true, false, TCK_RECIP_THROUGHPUT) > -slp_cl.threshold
                return false;
        }
    }
    return true;
}
