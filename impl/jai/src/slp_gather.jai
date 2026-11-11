// SLPVectorizer: gather-node analyses shared by reordering, the cost model and code generation. Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (tryToGatherSingleRegisterExtractElements,
// tryToGatherExtractElements, isGatherShuffledSingleRegisterEntry, isGatherShuffledEntry,
// getLastInstructionInBundle, findReusedOrderedScalars).
//
// std::optional<TTI::ShuffleKind> is an s64: SK_NONE (-1) or an SK_* kind.

SK_NONE :: -1;

// tryToGatherSingleRegisterExtractElements(VL, Mask): VL is modified in place (extracts moved out)
slp_try_to_gather_single_register_extract_elements :: (vl: [] Value_Id, mask: *[..] s32) -> s64 {
    vec_keys: [..] Value_Id; vec_keys.allocator = temp;   // MapVector<Value *, SmallVector<int>>
    vec_idxs: [..] [..] s32; vec_idxs.allocator = temp;
    undef_extracts: [..] s32; undef_extracts.allocator = temp;
    for i: 0..vl.count-1 {
        v := vl[i];
        if !is_inst(v) || inst_op(v) != .EXTRACTELEMENT {
            if pm_undef_value(v) array_add(*undef_extracts, cast(s32) i);
            continue;
        }
        vt := vtype(op(v, 0));
        if type_kind(vt) != .VECTOR || !(vkind(op(v, 1)) == .C_INT || pm_undef_value(op(v, 1))) continue;
        ok, idx := slp_extract_index(v);
        if !ok { array_add(*undef_extracts, cast(s32) i); continue; }
        if idx >= type_count(vt) { array_add(*undef_extracts, cast(s32) i); continue; }
        em := NewArray(cast(s64) type_count(vt), bool,, temp);
        for * em it.* = true;
        em[idx] = false;
        if all_bits(slp_is_undef_vector(op(v, 0), em, true)) { array_add(*undef_extracts, cast(s32) i); continue; }
        k := -1;
        for vec_keys if it == op(v, 0) { k = it_index; break; }
        if k < 0 {
            array_add(*vec_keys, op(v, 0));
            l: [..] s32; l.allocator = temp;
            array_add(*vec_idxs, l);
            k = vec_keys.count - 1;
        }
        array_add(*vec_idxs[k], cast(s32) i);
    }
    // stable_sort by descending list size
    order: [..] s64; order.allocator = temp;
    for vec_keys array_add(*order, it_index);
    for i: 1..order.count-1 {
        x := order[i]; j := i;
        while j > 0 && vec_idxs[x].count > vec_idxs[order[j-1]].count { order[j] = order[j-1]; j -= 1; }
        order[j] = x;
    }
    undef_sz := undef_extracts.count;
    single_max := 0; pair_max := 0;
    if order.count {
        single_max = vec_idxs[order[0]].count + undef_sz;
        if order.count > 1 pair_max = single_max + vec_idxs[order[1]].count;
    }
    if single_max == 0 && pair_max == 0 && undef_sz == 0 return SK_NONE;
    saved := vl_copy(vl);
    gathered := NewArray(vl.count, Value_Id,, temp);
    for * gathered it.* = const_poison(vtype(vl[0]));
    swap :: (a: *Value_Id, b: *Value_Id) { t := a.*; a.* = b.*; b.* = t; }
    if single_max >= pair_max && single_max != 0 {
        for idx: vec_idxs[order[0]] swap(*gathered[idx], *vl[idx]);
    } else if order.count {
        for w: 0..1 for idx: vec_idxs[order[w]] swap(*gathered[idx], *vl[idx]);
    }
    for idx: undef_extracts swap(*gathered[idx], *vl[idx]);
    ok, kind, m := slp_is_fixed_vector_shuffle(gathered, slp.ac);
    array_reset_keeping_memory(mask);
    for m array_add(mask, it);
    all_poison := true;
    for m if it != PoisonMaskElem { all_poison = false; break; }
    if !ok || all_poison {
        for saved vl[it_index] = it;
        return SK_NONE;
    }
    for i: 0..gathered.count-1 {
        if mask.*[i] == PoisonMaskElem && !pm_poison(gathered[i]) && pm_undef_value(gathered[i]) { swap(*vl[i], *gathered[i]); continue; }
    }
    return kind;
}

// tryToGatherExtractElements(VL, Mask, NumParts)
slp_try_to_gather_extract_elements :: (vl: [] Value_Id, mask: *[..] s32, num_parts: u64) -> [..] s64 {
    res: [..] s64; res.allocator = temp;
    for 1..num_parts array_add(*res, SK_NONE);
    array_reset_keeping_memory(mask);
    for 1..vl.count array_add(mask, PoisonMaskElem);
    slice := cast(s64) slp_part_num_elems(cast(u64) vl.count, num_parts);
    for part: 0..cast(s64) num_parts - 1 {
        off := part * slice;
        psz := cast(s64) slp_num_elems(cast(u64) vl.count, cast(u64) slice, cast(u64) part);
        if off + psz > vl.count break;
        sub := array_view(vl, off, psz);
        sub_mask: [..] s32; sub_mask.allocator = temp;
        r := slp_try_to_gather_single_register_extract_elements(sub, *sub_mask);
        res[part] = r;
        for sub_mask mask.*[part * slice + it_index] = it;
        if psz != slice break;
    }
    any := false;
    for res if it != SK_NONE { any = true; break; }
    if !any array_reset_keeping_memory(*res);
    return res;
}

// ---------------------------------------------------------------- getLastInstructionInBundle

slp_last_instruction_in_bundle :: (te: Te_Id) -> Value_Id {
    found, r := table_find(*slpx.entry_to_last_instruction, te);
    if found return r;
    e := *slp.entries[te];
    front: Value_Id;
    opcode: Opcode;
    if te_has_state(te) { front = e.s.main; opcode = te_opcode(te); }
    else {
        for e.scalars if is_inst(it) { front = it; break; }
        opcode = inst_op(front);
    }
    bb := inst_block(front);
    find_last :: (te: Te_Id, front: Value_Id, bb: *Value_Id) -> Value_Id {
        e := *slp.entries[te];
        last := front;
        for i: e.scalars {
            if !is_inst(i) || slp_te_is_copyable(te, i) continue;
            if inst_block(last) == inst_block(i) { if comes_before(last, i) last = i; continue; }
            if !dt_is_reachable_from_entry(slp.dt, inst_block(last)) { last = i; continue; }
            if !dt_is_reachable_from_entry(slp.dt, inst_block(i)) continue;
            if dt_dfs_in(slp.dt, inst_block(last)) < dt_dfs_in(slp.dt, inst_block(i)) last = i;
        }
        bb.* = inst_block(last);
        return last;
    }
    find_first :: (te: Te_Id, front: Value_Id) -> Value_Id {
        e := *slp.entries[te];
        first := front;
        for i: e.scalars {
            if !is_inst(i) || slp_te_is_copyable(te, i) continue;
            if inst_block(first) == inst_block(i) { if comes_before(i, first) first = i; continue; }
            if !dt_is_reachable_from_entry(slp.dt, inst_block(first)) { first = i; continue; }
            if !dt_is_reachable_from_entry(slp.dt, inst_block(i)) continue;
            if dt_dfs_in(slp.dt, inst_block(first)) > dt_dfs_in(slp.dt, inst_block(i)) first = i;
        }
        return first;
    }
    res: Value_Id = NONE;
    if e.state == TE_SPLIT_VECTORIZE {
        res = find_last(te, front, *bb);
        for x: slp_get_tree_entries(res) {
            i := slp.entries[x].vectorized_value;
            if i == NONE || !is_inst(i) i = slp_last_instruction_in_bundle(x);
            if inst_block(res) == inst_block(i) && comes_before(res, i) res = i;
        }
        table_set(*slpx.entry_to_last_instruction, te, res);
        return res;
    }
    if slpx.gathered_loads_first >= 0 && e.idx >= slpx.gathered_loads_first && !te_is_gather(te) && opcode == .LOAD {
        res = find_first(te, front);
        table_set(*slpx.entry_to_last_instruction, te, res);
        return res;
    }
    // FindScheduleBundle(E)
    bundle := -1;
    bs: *Block_Sched = null;
    if !te_is_gather(te) {
        for slpx.block_schedules if it.bb == bb { bs = it; break; }
        if bs for v: e.scalars {
            if !is_inst(v) || inst_op(v) == .PHI || (!slp_te_is_copyable(te, v) && slp_does_not_need_to_be_scheduled(v)) continue;
            bundles := bs_bundles(bs, v);
            if bundles.count == 0 continue;
            for b: bundles if bs.bundles[b].te == te { bundle = b; break; }
            if bundle >= 0 break;
        }
    }
    if !te_is_gather(te) && bundle < 0 {
        c1 := false;
        if opcode == .GEP for v: e.scalars if is_inst(v) && inst_op(v) != .GEP { c1 = true; break; }
        c2 := false;
        if !c1 {
            all := true;
            for v: e.scalars {
                if pm_poison(v) || (e.idx == 0 && is_inst(v) && (inst_op(v) == .INSERTELEMENT || inst_op(v) == .INSERTVALUE)) || slp_te_is_copyable(te, v) ||
                   (!slp_is_vector_like_inst_with_const_ops(v) && slp_is_used_outside_block(v)) continue;
                all = false; break;
            }
            if all {
                any_ops := false;
                for v: e.scalars {
                    if !is_inst(v) || (slp_te_has_copyables(te) && slp_te_is_copyable(te, v)) continue;
                    if !slp_are_all_operands_non_insts(v) { any_ops = true; break; }
                }
                none_mg := true;
                for v: e.scalars {
                    if !is_inst(v) || (slp_te_has_copyables(te) && slp_te_is_copyable(te, v)) continue;
                    if table_contains(*slp.must_gather, v) { none_mg = false; break; }
                }
                c2 = !e.does_not_need_to_schedule || any_ops || none_mg;
            }
        }
        if c1 || c2 res = find_last(te, front, *bb);
        else res = find_first(te, front);
        table_set(*slpx.entry_to_last_instruction, te, res);
        return res;
    }
    if bundle >= 0 {
        m := bs.bundles[bundle].members;
        res = bs.data[m[m.count - 1]].inst;
        table_set(*slpx.entry_to_last_instruction, te, res);
        return res;
    }
    res = find_last(te, front, *bb);
    table_set(*slpx.entry_to_last_instruction, te, res);
    return res;
}

// ---------------------------------------------------------------- isGatherShuffledEntry

// isGatherShuffledSingleRegisterEntry(TE, VL, Mask, Entries, Part, ForOrder, SliceSize)
slp_is_gather_shuffled_single_register_entry :: (te: Te_Id, vl: [] Value_Id, mask: [] s32, entries: *[..] Te_Id, part: u64, for_order: bool, slice_size: u64) -> s64 {
    array_reset_keeping_memory(entries);
    e := *slp.entries[te];
    if e.idx == 0 return SK_NONE;
    mask_base := cast(s64) (part * slice_size);
    get_user_entry :: (t_in: Te_Id) -> Edge_Info {
        t := t_in;
        while slp.entries[t].user_tree_index.user != TE_NONE && slp.entries[t].user_tree_index.edge == EDGE_NONE t = slp.entries[t].user_tree_index.user;
        if t == 0 return .{0, 0};
        return slp.entries[t].user_tree_index;
    }
    has_gather_user :: (t_in: Te_Id) -> bool {
        t := t_in;
        while slp.entries[t].idx != 0 && slp.entries[t].user_tree_index.user != TE_NONE {
            if slp.entries[t].user_tree_index.edge == EDGE_NONE return true;
            t = slp.entries[t].user_tree_index.user;
        }
        return false;
    }
    use_ei := get_user_entry(te);
    if use_ei.user == TE_NONE || (slp.entries[use_ei.user].idx == 0 && te_is_gather(use_ei.user) && !te_has_state(use_ei.user)) return SK_NONE;
    ue := *slp.entries[use_ei.user];
    insert_pt := slp_last_instruction_in_bundle(use_ei.user);
    insert_block: Value_Id;
    if te_has_state(use_ei.user) && inst_op(ue.s.main) == .PHI && ue.state != TE_SPLIT_VECTORIZE {
        insert_block = phi_block(ue.s.main, use_ei.edge);
        insert_pt = block_terminator(insert_block);
    } else insert_block = inst_block(insert_pt);
    if !dt_is_reachable_from_entry(slp.dt, insert_block) return SK_NONE;
    node_ui := dt_node(slp.dt, insert_block);
    check_ordering :: (ip: Value_Id, insert_pt: Value_Id, node_ui: s32) -> bool {
        ib := inst_block(ip);
        node_eui := dt_node(slp.dt, ib);
        if node_eui < 0 return false;
        if inst_block(insert_pt) != ib && (dt_dominates_nodes(slp.dt, node_ui, node_eui) || !dt_dominates_nodes(slp.dt, node_eui, node_ui)) return false;
        if inst_block(insert_pt) == ib && comes_before(insert_pt, ip) return false;
        return true;
    }
    used_tes: [..] [..] Te_Id; used_tes.allocator = temp;
    used_vals_keys: [..] Value_Id; used_vals_keys.allocator = temp;   // SmallDenseMap<Value *, int> UsedValuesEntry
    used_vals_idx: [..] s32; used_vals_idx.allocator = temp;
    uv_try_emplace :: (keys: *[..] Value_Id, idxs: *[..] s32, v: Value_Id, idx: s32) {
        for keys.* if it == v return;
        array_add(keys, v); array_add(idxs, idx);
    }
    uv_find :: (keys: [] Value_Id, v: Value_Id) -> s64 { for keys if it == v return it_index; return -1; }
    visited_value: [..] Value_Id; visited_value.allocator = temp;
    is_reused_node_found := false;
    new_set :: () -> [..] Te_Id { l: [..] Te_Id; l.allocator = temp; return l; }
    set_has :: (l: [] Te_Id, t: Te_Id) -> bool { for l if it == t return true; return false; }
    set_add :: (l: *[..] Te_Id, t: Te_Id) { if !set_has(l.*, t) array_add(l, t); }
    check_and_use_same_node :: (tp: Te_Id, te: Te_Id, vl: [] Value_Id, is_reused: *bool, used_tes: *[..] [..] Te_Id, keys: *[..] Value_Id, idxs: *[..] s32) -> bool {
        if is_reused.* return false;
        p := *slp.entries[tp]; e := *slp.entries[te];
        if (te_vector_factor(tp) != vl.count && p.scalars.count != vl.count) || (!te_is_same(tp, vl) && !te_is_same(tp, e.scalars)) return false;
        same_list :: (a: [] $T, b: [] T) -> bool { if a.count != b.count return false; for a if it != b[it_index] return false; return true; }
        is_reused.* = same_list(e.scalars, p.scalars) && same_list(e.reorder_indices, p.reorder_indices) && same_list(e.reuse_shuffle_indices, p.reuse_shuffle_indices);
        array_reset_keeping_memory(used_tes);
        s := new_set(); array_add(*s, tp);
        array_add(used_tes, s);
        for v: vl { if slp_is_constant(v) continue; uv_try_emplace(keys, idxs, v, 0); }
        return true;
    }
    check_parent_nodes :: (user1: Te_Id, user2: Te_Id, edge_in: u32) -> bool {
        ptr_keys: [..] Te_Id; ptr_keys.allocator = temp;
        ptr_idx: [..] u32; ptr_idx.allocator = temp;
        edge := edge_in;
        p2 := user2;
        while p2 != TE_NONE {
            found := false; for ptr_keys if it == p2 { found = true; break; }
            if !found { array_add(*ptr_keys, p2); array_add(*ptr_idx, edge); }
            edge = slp.entries[p2].user_tree_index.edge;
            p2 = slp.entries[p2].user_tree_index.user;
        }
        p1 := user1;
        while p1 != TE_NONE {
            idx := slp.entries[p1].user_tree_index.edge;
            p1 = slp.entries[p1].user_tree_index.user;
            for ptr_keys if it == p1 return idx < ptr_idx[it_index];
        }
        return false;
    }
    insert_pt_used_outside := -1;
    is_insert_pt_used_outside :: (cache: *s64, ip: Value_Id) -> bool {
        if cache.* < 0 cache.* = cast(s64) slp_is_used_outside_block(ip);
        return cache.* == 1;
    }
    use_ei_insert_pt_used_outside := slp_te_has_copyables(use_ei.user) && !slp_te_is_copyable(use_ei.user, insert_pt) && is_insert_pt_used_outside(*insert_pt_used_outside, insert_pt);
    check_non_schedulable_ordering :: (t: Te_Id, ip: Value_Id, flag: bool, insert_pt: Value_Id) -> bool {
        return flag && inst_next(ip) == insert_pt && (!slp_te_has_copyables(t) || !slp_te_is_copyable(t, ip) || !slp_is_used_outside_block(ip));
    }
    all_used_outside :: (t: Te_Id) -> bool { for slp.entries[t].scalars if !slp_is_used_outside_block(it) return false; return true; }
    user_needs_emit_first := ue.state == TE_VECTORIZE && te_has_state(use_ei.user) && (te_opcode(use_ei.user) != .PHI || is_alt_shuffle(ue.s)) && all_used_outside(use_ei.user);
    for v: vl {
        if slp_is_constant(v) continue;
        dup := false; for visited_value if it == v { dup = true; break; }
        if dup continue;
        array_add(*visited_value, v);
        vto := new_set();
        gather_nodes := new_set();
        gp := table_find_pointer(*slpx.value_to_gather_nodes, v);
        if gp for gp.* array_add(*gather_nodes, it);
        if table_contains(*slp.transformed_to_gather_nodes, te) {
            for x: slp_get_split_tree_entries(v) {
                if te == x || !table_contains(*slp.transformed_to_gather_nodes, x) || slp.entries[x].user_tree_index.user == TE_NONE || te_is_gather(slp.entries[x].user_tree_index.user) continue;
                array_add(*gather_nodes, x);
            }
            for x: slp_get_tree_entries(v) {
                if te == x || !table_contains(*slp.transformed_to_gather_nodes, x) || slp.entries[x].user_tree_index.user == TE_NONE || te_is_gather(slp.entries[x].user_tree_index.user) continue;
                array_add(*gather_nodes, x);
            }
        }
        for tp: gather_nodes {
            p := *slp.entries[tp];
            if tp == te || p.idx == 0 || table_contains(*slp.deleted_nodes, tp) continue;
            skip := false;
            for c: p.combined_entries_with_indices if c[0] == cast(u32) e.idx { skip = true; break; }
            if skip continue;
            uei := p.user_tree_index;
            uu := *slp.entries[uei.user];
            user_phi: Value_Id = NONE;
            if uu.state != TE_SPLIT_VECTORIZE && te_has_state(uei.user) && inst_op(uu.s.main) == .PHI user_phi = uu.s.main;
            ip := ifx user_phi != NONE then block_terminator(phi_block(user_phi, uei.edge)) else slp_last_instruction_in_bundle(uei.user);
            if insert_pt == ip {
                if user_needs_emit_first {
                    if uu.state != TE_VECTORIZE || (te_has_state(uei.user) && te_opcode(uei.user) == .PHI && !is_alt_shuffle(uu.s)) || !all_used_outside(uei.user) continue;
                }
                if !slp_does_not_need_to_be_scheduled(ip) && (use_ei.user != uei.user || use_ei.edge < uei.edge) continue;
                if ue.state == TE_VECTORIZE && te_opcode(use_ei.user) == .PHI && uu.state == TE_VECTORIZE && te_opcode(uei.user) == .PHI && use_ei.user != uei.user continue;
                if use_ei.user == uei.user && use_ei.edge < uei.edge continue;
                if use_ei.user != uei.user && (ue.idx < uu.idx || has_gather_user(use_ei.user)) continue;
                if check_parent_nodes(use_ei.user, uei.user, uei.edge) continue;
            }
            if !te_is_gather(use_ei.user) && user_phi == NONE && ue.does_not_need_to_schedule != uu.does_not_need_to_schedule {
                inn := false; for uu.scalars if it == insert_pt { inn = true; break; }
                if inn continue;
            }
            if insert_block != inst_block(ip) || use_ei.edge < uei.edge || use_ei.user != uei.user {
                bad := !check_ordering(ip, insert_pt, node_ui);
                if !bad && slp_te_has_copyables(uei.user) && is_insert_pt_used_outside(*insert_pt_used_outside, insert_pt) {
                    for uu.scalars if it == insert_pt { bad = true; break; }
                }
                if bad continue;
            }
            if check_and_use_same_node(tp, te, vl, *is_reused_node_found, *used_tes, *used_vals_keys, *used_vals_idx) break;   // leaves the gather-node loop only
            if check_non_schedulable_ordering(uei.user, ip, use_ei_insert_pt_used_outside, insert_pt) continue;
            set_add(*vto, tp);
        }
        // (the `continue` / `break` of the split and vectorized-entry checks act on the VL loop, as in LLVM)
        {
            vtes := slp_get_split_tree_entries(v);
            if vtes.count {
                vte := TE_NONE;
                for m: vtes if m != te && m != use_ei.user && !table_contains(*slp.deleted_nodes, m) && !table_contains(*slp.transformed_to_gather_nodes, m) { vte = m; break; }
                if vte != TE_NONE {
                    none := true; for c: e.combined_entries_with_indices if c[0] == cast(u32) slp.entries[vte].idx { none = false; break; }
                    cont := false;
                    if none {
                        lbi := slp_last_instruction_in_bundle(vte);
                        if lbi == insert_pt || !check_ordering(lbi, insert_pt, node_ui) cont = true;
                        #if DEBUG_SLP print("DBG   split vte % lbi % insert_pt % cont %\n", vte, lbi, insert_pt, cont);
                    }
                    if cont continue;
                    if check_and_use_same_node(vte, te, vl, *is_reused_node_found, *used_tes, *used_vals_keys, *used_vals_idx) break v;
                    set_add(*vto, vte);
                }
            }
        }
        {
            vtes := slp_get_tree_entries(v);
            if vtes.count {
                k := -1;
                for m, mi: vtes if m != te && !table_contains(*slp.deleted_nodes, m) && !table_contains(*slp.transformed_to_gather_nodes, m) { k = mi; break; }
                if k >= 0 {
                    vte := vtes[k];
                    first_g := ifx slpx.gathered_loads_first >= 0 then slpx.gathered_loads_first else 0;
                    if for_order && slp.entries[vte].idx < first_g && vtes.count > 1 && slp.entries[vte].state != TE_VECTORIZE {
                        rest := array_view(vtes, 1, vtes.count - 1);
                        mi := -1;
                        for m, j: rest if slp.entries[m].state == TE_VECTORIZE { mi = j; break; }
                        if mi < 0 continue;
                        vte = rest[mi];
                    }
                    none := true; for c: e.combined_entries_with_indices if c[0] == cast(u32) slp.entries[vte].idx { none = false; break; }
                    cont := false;
                    if none {
                        lbi := slp_last_instruction_in_bundle(vte);
                        if lbi == insert_pt || !check_ordering(lbi, insert_pt, node_ui) || check_non_schedulable_ordering(vte, lbi, use_ei_insert_pt_used_outside, insert_pt) cont = true;
                    }
                    if cont continue;
                    if check_and_use_same_node(vte, te, vl, *is_reused_node_found, *used_tes, *used_vals_keys, *used_vals_idx) break v;
                    set_add(*vto, vte);
                }
            }
        }
        if is_reused_node_found break;
        #if DEBUG_SLP print("DBG   value % vto %\n", v, vto);
        if vto.count == 0 continue;
        if used_tes.count == 0 {
            array_add(*used_tes, vto);
            uv_try_emplace(*used_vals_keys, *used_vals_idx, v, 0);
        } else {
            saved := new_set(); for vto array_add(*saved, it);
            idx := 0;
            for * set: used_tes {
                inter := new_set();
                for vto if set_has(set.*, it) array_add(*inter, it);
                if inter.count { set.* = inter; break; }
                idx += 1;
            }
            if idx == used_tes.count {
                if used_tes.count == 2 continue;
                array_add(*used_tes, saved);
                idx = used_tes.count - 1;
            }
            uv_try_emplace(*used_vals_keys, *used_vals_idx, v, cast(s32) idx);
        }
    }
    if used_tes.count == 0 { array_reset_keeping_memory(entries); return SK_NONE; }
    vf: s64 = 0;
    if used_tes.count == 1 {
        first := new_set(); for used_tes[0] array_add(*first, it);
        for i: 1..first.count-1 { x := first[i]; j := i; while j > 0 && slp.entries[x].idx < slp.entries[first[j-1]].idx { first[j] = first[j-1]; j -= 1; } first[j] = x; }
        hit := TE_NONE;
        for p: first if (te_vector_factor(p) == e.scalars.count && te_is_same(p, e.scalars)) || te_is_same(p, vl) { hit = p; break; }
        if hit != TE_NONE && (is_reused_node_found || te_vector_factor(hit) == vl.count ||
                              (te_vector_factor(hit) == e.scalars.count && e.reuse_shuffle_indices.count == vl.count && te_is_same(hit, e.scalars))) {
            array_add(entries, hit);
            if is_reused_node_found || te_vector_factor(hit) == vl.count {
                for i: 0..vl.count-1 mask[mask_base + i] = cast(s32) i;
            } else {
                cm := te_common_mask(te);
                for cm mask[it_index] = it;
            }
            for i: 0..vl.count-1 if pm_poison(vl[i]) mask[mask_base + i] = PoisonMaskElem;
            return SK_PERMUTE_SINGLE_SRC;
        }
        array_add(entries, first[0]);
        for * used_vals_idx it.* = 0;
        vf = te_vector_factor(first[0]);
    } else {
        vf_keys: [..] s64; vf_keys.allocator = temp;
        vf_tes: [..] Te_Id; vf_tes.allocator = temp;
        for t: used_tes[0] {
            v := te_vector_factor(t);
            found := false;
            for vf_keys if it == v { if slp.entries[vf_tes[it_index]].idx > slp.entries[t].idx vf_tes[it_index] = t; found = true; break; }
            if !found { array_add(*vf_keys, v); array_add(*vf_tes, t); }
        }
        second := new_set(); for used_tes[1] array_add(*second, it);
        for i: 1..second.count-1 { x := second[i]; j := i; while j > 0 && slp.entries[x].idx < slp.entries[second[j-1]].idx { second[j] = second[j-1]; j -= 1; } second[j] = x; }
        for t: second {
            k := -1; for vf_keys if it == te_vector_factor(t) { k = it_index; break; }
            if k >= 0 { vf = vf_keys[k]; array_add(entries, vf_tes[k]); array_add(entries, t); break; }
        }
        if entries.count == 0 {
            mx := used_tes[0][0];
            for used_tes[0] if slp.entries[mx].idx < slp.entries[it].idx mx = it;
            array_add(entries, mx);
            array_add(entries, second[0]);
            vf = max(te_vector_factor(entries.*[0]), te_vector_factor(entries.*[1]));
        } else vf = te_vector_factor(entries.*[0]);
        for k: 0..used_vals_keys.count-1 {
            for ei, idx: entries.* {
                hit := false; for slp.entries[ei].scalars if it == used_vals_keys[k] { hit = true; break; }
                if hit { used_vals_idx[k] = cast(s32) idx; break; }
            }
        }
    }
    is_splat_or_undefs := slp_is_splat(vl);
    if !is_splat_or_undefs { is_splat_or_undefs = true; for vl if !pm_undef_value(it) { is_splat_or_undefs = false; break; } }
    are_compatible_phis :: (v: Value_Id, v1: Value_Id) -> bool {
        for i: 0..cast(s64) phi_num_incoming(v) - 1 {
            a := phi_value(v, cast(u32) i); b := phi_value(v1, cast(u32) i);
            if slp_is_constant(a) && slp_is_constant(b) continue;
            if !is_valid(slp_get_same_opcode(.[a, b])) return false;
            if inst_block(a) != inst_block(b) return false;
        }
        return true;
    }
    might_be_ignored :: (v: Value_Id, is_splat_or_undefs: bool) -> bool {
        return is_inst(v) && !is_splat_or_undefs && !slp_is_vectorized(v) && !slp_is_vector_like_inst_with_const_ops(v) &&
               !slp_are_all_users_vectorized(v, true) && slp_is_simple(v);
    }
    neighbor_might_be_ignored :: (v: Value_Id, idx: s64, vl: [] Value_Id, keys: [] Value_Id, idxs: [] s32, is_splat_or_undefs: bool) -> bool {
        v1 := vl[idx];
        used_in_same := false;
        k1 := uv_find(keys, v1);
        if k1 >= 0 used_in_same = idxs[k1] == idxs[uv_find(keys, v)];
        return v != v1 && might_be_ignored(v1, is_splat_or_undefs) && !used_in_same && is_valid(slp_get_same_opcode(.[v, v1])) &&
               inst_block(v) == inst_block(v1) && (!(is_inst(v1) && inst_op(v1) == .PHI) || are_compatible_phis(v, v1));
    }
    used_idxs := NewArray(entries.count, bool,, temp);
    Lane :: struct { entry: s64; lane: s64; }
    lanes: [..] Lane; lanes.allocator = temp;
    for i: 0..vl.count-1 {
        v := vl[i];
        k := uv_find(used_vals_keys, v);
        if k < 0 continue;
        if slp_is_constant(v) || (might_be_ignored(v, is_splat_or_undefs) &&
            ((i > 0 && neighbor_might_be_ignored(v, i - 1, vl, used_vals_keys, used_vals_idx, is_splat_or_undefs)) ||
             (i != vl.count - 1 && neighbor_might_be_ignored(v, i + 1, vl, used_vals_keys, used_vals_idx, is_splat_or_undefs))))
            continue;
        idx := cast(s64) used_vals_idx[k];
        array_add(*lanes, .{idx, i});
        used_idxs[idx] = true;
    }
    temp_entries := new_set();
    for i: 0..entries.count-1 {
        if !used_idxs[i] continue;
        for * lanes if it.entry == i it.entry = temp_entries.count;
        array_add(*temp_entries, entries.*[i]);
    }
    array_reset_keeping_memory(entries);
    for temp_entries array_add(entries, it);
    if lanes.count == entries.count {
        n := cast(s64) slp_num_elems(cast(u64) e.scalars.count, slice_size, part);
        same := n == vl.count;
        if same for k: 0..vl.count-1 if vl[k] != e.scalars[mask_base + k] { same = false; break; }
        if !same { array_reset_keeping_memory(entries); return SK_NONE; }
    }
    is_identity := entries.count == 1;
    for p: lanes {
        idx := mask_base + p.lane;
        lane_val: s64;
        if for_order {
            sc := slp.entries[entries.*[p.entry]].scalars;
            lane_val = 0; while lane_val < sc.count && sc[lane_val] != vl[p.lane] lane_val += 1;
        } else lane_val = cast(s64) te_find_lane_for_value(entries.*[p.entry], vl[p.lane]);
        mask[idx] = cast(s32) (p.entry * vf + lane_val);
        is_identity &= mask[idx] == cast(s32) p.lane;
    }
    if for_order || is_identity || entries.count == 0 {
        if entries.count == 1 {
            if is_identity || lanes.count > 1 || vl.count <= 2 return SK_PERMUTE_SINGLE_SRC;
        } else if entries.count == 2 {
            if lanes.count > 2 || vl.count <= 2 return SK_PERMUTE_TWO_SRC;
        }
    } else if !is_vector_type(vtype(vl[0])) && (lanes.count > entries.count || vl.count <= 2) {
        sub := new_mask();
        for k: 0..vl.count-1 array_add(*sub, mask[mask_base + k]);
        min_e := sub[0]; max_e := sub[0];
        for idx: sub {
            if idx == PoisonMaskElem continue;
            if min_e == PoisonMaskElem || min_e % vf > idx % vf min_e = idx;
            if max_e == PoisonMaskElem || max_e % vf < idx % vf max_e = idx;
        }
        offset: s64 = 0;
        min_idx := cast(s64) min_e % vf;
        sty := vtype(vl[0]);
        if min_idx > 1 {
            reg_floor := slp_floor_full_vector_number_of_elements(slp.tti, sty, cast(u64) min_idx);
            reg_floor_parts := slp_number_of_parts(slp.tti, slp_widened_type(sty, reg_floor), sty, reg_floor);
            if reg_floor_parts > 1 offset = cast(s64) reg_floor;
        }
        new_vf := max(vl.count, (cast(s64) max_e % vf) - offset + 1);
        if new_vf < vf {
            for * idx: sub {
                if idx.* == PoisonMaskElem continue;
                idx.* = cast(s32) ((idx.* % vf) - offset + ifx idx.* >= vf then new_vf else 0);
            }
        } else new_vf = vf;
        vec_ty := slp_widened_type(sty, cast(u64) new_vf);
        mask_vec_ty := slp_widened_type(sty, cast(u64) sub.count);
        get_shuffle_cost :: (m: [] s32, ents: [] Te_Id, vec_ty: Type_Id) -> Cost {
            if ents.count == 1 && slp.entries[ents[0]].interleave_factor > 0 && svm_is_deinterleave_mask_of_factor(m, slp.entries[ents[0]].interleave_factor) return TCC_FREE;
            return slp_shuffle_cost(ifx ents.count > 1 then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC, vec_ty, m, TCK_RECIP_THROUGHPUT);
        }
        shuffle_cost := get_shuffle_cost(sub, entries.*, vec_ty);
        first_cost: Cost = 0;
        first_mask := mask_copy(sub);
        if entries.count == 1 || !te_is_gather(entries.*[0]) {
            first_cost = shuffle_cost;
        } else {
            dem := NewArray(sub.count, bool,, temp); for * dem it.* = true;
            ident := true;
            for * idx, i: first_mask {
                if idx.* >= new_vf idx.* = PoisonMaskElem;
                else { dem[i] = false; if idx.* != PoisonMaskElem ident &= cast(s64) i == idx.*; }
            }
            if !ident first_cost = get_shuffle_cost(first_mask, .[entries.*[0]], vec_ty);
            first_cost = cost_add(first_cost, slp_get_scalarization_overhead(sty, mask_vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT));
        }
        second_cost: Cost = 0;
        second_mask := mask_copy(sub);
        if entries.count == 1 || !te_is_gather(entries.*[1]) {
            second_cost = shuffle_cost;
        } else {
            dem := NewArray(sub.count, bool,, temp); for * dem it.* = true;
            ident := true;
            for * idx, i: second_mask {
                if idx.* < new_vf && idx.* >= 0 idx.* = PoisonMaskElem;
                else { dem[i] = false; if idx.* != PoisonMaskElem { idx.* -= cast(s32) new_vf; ident &= cast(s64) i == idx.*; } }
            }
            if !ident second_cost = get_shuffle_cost(second_mask, .[entries.*[1]], vec_ty);
            second_cost = cost_add(second_cost, slp_get_scalarization_overhead(sty, mask_vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT));
        }
        dem := NewArray(sub.count, bool,, temp);
        for idx, i: sub dem[i] = idx != PoisonMaskElem;
        bv_cost := slp_get_scalarization_overhead(sty, mask_vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT);
        best_entry := TE_NONE;
        if first_cost < shuffle_cost {
            for k: 0..vl.count-1 if mask[mask_base + k] >= vf mask[mask_base + k] = PoisonMaskElem;
            best_entry = entries.*[0];
            shuffle_cost = first_cost;
        }
        if second_cost < shuffle_cost {
            for k: 0..vl.count-1 {
                if mask[mask_base + k] < vf mask[mask_base + k] = PoisonMaskElem;
                else mask[mask_base + k] -= cast(s32) vf;
            }
            best_entry = entries.*[1];
            shuffle_cost = second_cost;
        }
        if bv_cost >= shuffle_cost {
            if best_entry != TE_NONE { array_reset_keeping_memory(entries); array_add(entries, best_entry); }
            return ifx entries.count > 1 then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC;
        }
    }
    array_reset_keeping_memory(entries);
    for k: 0..vl.count-1 mask[mask_base + k] = PoisonMaskElem;
    return SK_NONE;
}

// ShuffleVectorInst::isDeInterleaveMaskOfFactor(Mask, Factor)
svm_is_deinterleave_mask_of_factor :: (mask: [] s32, factor: u32) -> bool {
    for idx: 0..cast(s64) factor - 1 {
        i := 0;
        while i < mask.count {
            if mask[i] >= 0 && mask[i] != cast(s32) (i * factor + idx) break;
            i += 1;
        }
        if i == mask.count return true;
    }
    return false;
}

// isGatherShuffledEntry(TE, VL, Mask, Entries, NumParts, ForOrder)
slp_is_gather_shuffled_entry :: (te: Te_Id, vl: [] Value_Id, mask: *[..] s32, entries: *[..] [..] Te_Id, num_parts: u64, for_order := false) -> [..] s64 {
    res: [..] s64; res.allocator = temp;
    array_reset_keeping_memory(entries);
    if te == 0 {
        if slpx.gathered_loads_first < 0 return res;
        all_g := true;
        for k: 1..slp.entries.count-1 if !te_is_gather(cast(Te_Id) k) { all_g = false; break; }
        if all_g return res;
    }
    array_reset_keeping_memory(mask);
    for 1..vl.count array_add(mask, PoisonMaskElem);
    e := *slp.entries[te];
    pwsz := slp_full_vector_number_of_elements(slp.tti, vtype(vl[0]), cast(u64) vl.count);
    u := e.user_tree_index;
    if u.user != TE_NONE && te_is_gather(u.user) && u.edge == EDGE_NONE &&
       (e.idx == 0 || (te_has_state(te) && te_opcode(te) == .EXTRACTELEMENT) || slp_is_splat(e.scalars) ||
        (te_has_state(te) && slp_get_same_values_tree_entry(e.s.main, e.scalars) != TE_NONE))
        return res;
    slice := slp_part_num_elems(pwsz, num_parts);
    for part: 0..num_parts-1 {
        if part * slice >= cast(u64) vl.count break;
        sub := array_view(vl, cast(s64) (part * slice), cast(s64) slp_num_elems(cast(u64) vl.count, slice, part));
        sub_entries: [..] Te_Id; sub_entries.allocator = temp;
        sub_res := slp_is_gather_shuffled_single_register_entry(te, sub, mask.*, *sub_entries, part, for_order, slice);
        if sub_res == SK_NONE array_reset_keeping_memory(*sub_entries);
        array_add(entries, sub_entries);
        array_add(*res, sub_res);
        if sub_entries.count == 1 && sub_res == SK_PERMUTE_SINGLE_SRC && te_vector_factor(sub_entries[0]) == vl.count &&
           (te_is_same(sub_entries[0], e.scalars) || te_is_same(sub_entries[0], vl)) {
            only := sub_entries[0];
            array_reset_keeping_memory(entries);
            array_reset_keeping_memory(*res);
            for i: 0..vl.count-1 mask.*[i] = ifx pm_poison(vl[i]) then PoisonMaskElem else cast(s32) i;
            l: [..] Te_Id; l.allocator = temp; array_add(*l, only);
            array_add(entries, l);
            array_add(*res, SK_PERMUTE_SINGLE_SRC);
            return res;
        }
    }
    all_none := true;
    for res if it != SK_NONE { all_none = false; break; }
    if all_none { array_reset_keeping_memory(entries); array_reset_keeping_memory(*res); }
    return res;
}

// ---------------------------------------------------------------- findReusedOrderedScalars

slp_find_reused_ordered_scalars :: (te: Te_Id, top_to_bottom: bool, ignore_reorder: bool) -> (bool, [..] u32) {
    e := *slp.entries[te];
    none := new_order();
    gathered := vl_copy(e.scalars);
    sty := vtype(gathered[0]);
    n := gathered.count;
    if !slp_is_valid_element_type(sty) return false, none;
    vec_ty := slp_widened_type(sty, cast(u64) n);
    num_parts := slp_number_of_parts(slp.tti, vec_ty, sty, cast(u64) n);
    extract_mask: [..] s32; extract_mask.allocator = temp;
    mask: [..] s32; mask.allocator = temp;
    entries: [..] [..] Te_Id; entries.allocator = temp;
    extract_shuffles := slp_try_to_gather_extract_elements(gathered, *extract_mask, num_parts);
    gather_shuffles := slp_is_gather_shuffled_entry(te, gathered, *mask, *entries, num_parts, true);
    if gather_shuffles.count == 0 && extract_shuffles.count == 0 return false, none;
    cur := new_order(n, cast(u32) n);
    if gather_shuffles.count == 1 && gather_shuffles[0] == SK_PERMUTE_SINGLE_SRC && te_is_same(entries[0][0], e.scalars) {
        f := entries[0][0];
        fe := *slp.entries[f];
        if top_to_bottom return false, none;
        if fe.user_tree_index.user == e.user_tree_index.user return false, none;
        if !ignore_reorder && fe.idx == 0 return false, none;
        if fe.reuse_shuffle_indices.count && te_vector_factor(te) == 2 && mask.count == 2 {
            for p, i: fe.reuse_shuffle_indices if p % 2 != cast(s32) (i % 2) return false, none;
        }
        for k: 0..n-1 cur[k] = cast(u32) k;
        return true, cur;
    }
    is_splat_mask :: (m: [] s32) -> bool {
        single: s32 = PoisonMaskElem;
        for m {
            if single == PoisonMaskElem && it != PoisonMaskElem single = it;
            if !(it == PoisonMaskElem || it == single) return false;
        }
        return true;
    }
    if (extract_shuffles.count == 0 && is_splat_mask(mask) && (entries.count != 1 || slp.entries[entries[0][0]].reorder_indices.count == 0)) ||
       (gather_shuffles.count == 0 && is_splat_mask(extract_mask))
        return false, none;
    shuffled := NewArray(cast(s64) num_parts, bool,, temp);
    transform :: (cur: [] u32, m: [] s32, part_sz: s64, nparts: s64, vfs: [] s64, shuffled: [] bool, gathered: [] Value_Id, n: s64) {
        for i: 0..nparts-1 {
            if shuffled[i] continue;
            vf := vfs[i];
            if vf == 0 continue;
            limit := cast(s64) slp_num_elems(cast(u64) cur.count, cast(u64) part_sz, cast(u64) i);
            sl := array_view(cur, i * part_sz, limit);
            any_set := false; for sl if it != cast(u32) n { any_set = true; break; }
            if any_set { for * sl it.* = cast(u32) n; shuffled[i] = true; continue; }
            first_min: s64 = 0x7FFF_FFFF;
            second := false;
            for k: 0..limit-1 {
                idx := cast(s64) m[i * part_sz + k];
                if idx == PoisonMaskElem {
                    v := gathered[i * part_sz + k];
                    if slp_is_constant(v) && !pm_poison(v) { second = true; break; }
                    continue;
                }
                if idx < vf { if first_min > idx first_min = idx; }
                else { second = true; break; }
            }
            first_min = (first_min / part_sz) * part_sz;
            if second { for * sl it.* = cast(u32) n; shuffled[i] = true; continue; }
            for k: 0..limit-1 {
                idx := cast(s64) m[i * part_sz + k];
                if idx == PoisonMaskElem continue;
                idx -= first_min;
                if idx >= part_sz { second = true; break; }
                if i * part_sz + idx >= cur.count continue;
                if cur[i * part_sz + idx] > cast(u32) (i * part_sz + k) && cur[i * part_sz + idx] != cast(u32) (i * part_sz + idx)
                    cur[i * part_sz + idx] = cast(u32) (i * part_sz + k);
            }
            if second { for * sl it.* = cast(u32) n; shuffled[i] = true; continue; }
        }
    }
    part_sz := cast(s64) slp_part_num_elems(cast(u64) n, num_parts);
    if extract_shuffles.count {
        vfs := NewArray(cast(s64) num_parts, s64,, temp);
        for i: 0..cast(s64) num_parts - 1 {
            if i >= extract_shuffles.count || extract_shuffles[i] == SK_NONE continue;
            vf: s64 = 0;
            sz := cast(s64) slp_num_elems(cast(u64) te_vector_factor(te), cast(u64) part_sz, cast(u64) i);
            for idx: 0..sz-1 {
                k := i * part_sz + idx;
                if k >= extract_mask.count break;
                if extract_mask[k] == PoisonMaskElem continue;
                if e.reuse_shuffle_indices.count k = e.reuse_shuffle_indices[k];
                if k == PoisonMaskElem continue;
                if e.reorder_indices.count { p := 0; while p < e.reorder_indices.count && e.reorder_indices[p] != cast(u32) k p += 1; k = p; }
                x := e.scalars[k];
                if !is_inst(x) || inst_op(x) != .EXTRACTELEMENT continue;
                vf = max(vf, cast(s64) type_count(vtype(op(x, 0))));
            }
            vfs[i] = vf;
        }
        transform(cur, extract_mask, part_sz, cast(s64) num_parts, vfs, shuffled, gathered, n);
    }
    if gather_shuffles.count == 1 && num_parts != 1 {
        if any_bits(shuffled) return false, none;
        part_sz = n;
        num_parts = 1;
    }
    if entries.count {
        vfs := NewArray(cast(s64) num_parts, s64,, temp);
        for i: 0..cast(s64) num_parts - 1 {
            if i >= gather_shuffles.count || gather_shuffles[i] == SK_NONE continue;
            vfs[i] = max(te_vector_factor(entries[i][0]), te_vector_factor(entries[i][entries[i].count - 1]));
        }
        sh := shuffled;
        if sh.count < cast(s64) num_parts sh = NewArray(cast(s64) num_parts, bool,, temp);
        transform(cur, mask, part_sz, cast(s64) num_parts, vfs, sh, gathered, n);
        shuffled = sh;
    }
    undefs := 0; for cur if it == cast(u32) n undefs += 1;
    if all_bits(shuffled) || (n > 2 && undefs >= n / 2) return false, none;
    return true, cur;
}
