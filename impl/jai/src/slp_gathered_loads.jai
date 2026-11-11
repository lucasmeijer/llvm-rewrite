// SLPVectorizer: vectorization of gathered loads. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (gatherPossiblyVectorizableLoads, BoUpSLP::tryToVectorizeGatheredLoads and the GatheredLoads collection at the end
// of transformNodes).
//
// X86 facts used: TTI::isLegalInterleavedAccessType is the base `false` (no interleave factor). canVectorizeLoads'
// BestVF out-parameter is only set by its masked-gather cost recursion, which fails loudly here, so BestVF is 0
// after every call that returns.

Load_Dist :: struct { li: Value_Id; dist: s64; }
Ld_Group :: [..] Load_Dist;

new_ld_group :: () -> Ld_Group { l: Ld_Group; l.allocator = temp; return l; }

// gatherPossiblyVectorizableLoads(R, VL, DL, SE, TTI, GatheredLoads, AddNew)
slp_gather_possibly_vectorizable_loads :: (vl: [] Value_Id, gathered: *[..] Ld_Group, add_new := true) {
    if vl.count == 0 return;
    sty := slp_get_value_type(vl[0]);
    if !slp_is_valid_element_type(sty) return;
    clustered: [..] Ld_Group; clustered.allocator = temp;
    for v: vl {
        if !is_inst(v) || inst_op(v) != .LOAD continue;
        li := v;
        if slp_is_deleted(li) || slp_is_vectorized(li) || !is_simple_load_store(li) continue;
        found := false;
        for * data: clustered {
            f := data.*[0].li;
            ok, dist := get_pointers_diff(vtype(li), op(li, 0), vtype(f), op(f, 0), true);
            if !ok continue;
            at := -1;
            for data.* if it.dist == dist { at = it_index; break; }   // ClusteredDistToLoad (find only)
            if at >= 0 && data.*[at].li != li continue;
            if at < 0 array_add(data, .{li, dist});
            found = true;
            break;
        }
        if !found {
            g := new_ld_group();
            array_add(*g, .{li, 0});
            array_add(*clustered, g);
        }
    }
    // FindMatchingLoads(Loads, GatheredLoads, ToAdd, Repeated, Offset, Start): index into gathered or -1
    find_matching :: (loads: [] Load_Dist, gathered: *[..] Ld_Group, to_add: *[..] u32, repeated: *[..] u32, offset: *s64, start: *u32) -> s64 {
        if loads.count == 0 return -1;
        li := loads[0].li;
        for * data, idx: gathered.* {
            if idx < cast(s64) start.* continue;
            array_reset_keeping_memory(to_add);
            f := data.*[0].li;
            if inst_block(li) != inst_block(f) || vtype(li) != vtype(f) continue;
            ok, dist := get_pointers_diff(vtype(li), op(li, 0), vtype(f), op(f, 0), true);
            if !ok continue;
            num_uniques: u32 = 0;
            for p, cnt: loads {
                used := false; for d: data.* if d.li == p.li { used = true; break; }
                has_dist := false; for d: data.* if d.dist == dist + p.dist { has_dist = true; break; }
                if !used && !has_dist { num_uniques += 1; set_insert_u32(to_add, cast(u32) cnt); }
                else if used set_insert_u32(repeated, cast(u32) cnt);
            }
            n := cast(u32) loads.count;
            dn := cast(u64) data.count;
            if num_uniques > 0 &&
               (n == num_uniques || (n - num_uniques >= 2 && n - num_uniques >= n / 2 &&
                                     (has_single_bit(dn + num_uniques) || bit_ceil(dn) < bit_ceil(dn + num_uniques)))) {
                offset.* = dist;
                start.* = cast(u32) idx + 1;
                return idx;
            }
        }
        array_reset_keeping_memory(to_add);
        return -1;
    }
    for data: clustered {
        start: u32 = 0;
        to_add: [..] u32; to_add.allocator = temp;
        local_to_add: [..] u32; local_to_add.allocator = temp;
        repeated: [..] u32; repeated.allocator = temp;
        offset: s64 = 0;
        it_idx := find_matching(data, gathered, *local_to_add, *repeated, *offset, *start);
        while it_idx >= 0 {
            for idx: local_to_add array_add(*gathered.*[it_idx], .{data[idx].li, data[idx].dist + offset});
            for local_to_add set_insert_u32(*to_add, it);
            it_idx = find_matching(data, gathered, *local_to_add, *repeated, *offset, *start);
        }
        any := false;
        for idx: 0..data.count-1 if !slp_has(to_add, cast(u32) idx) && !slp_has(repeated, cast(u32) idx) { any = true; break; }
        if any {
            add_new_loads :: (loads: *Ld_Group, data: [] Load_Dist, to_add: [] u32, repeated: [] u32) {
                for idx: 0..data.count-1 {
                    if slp_has(to_add, cast(u32) idx) || slp_has(repeated, cast(u32) idx) continue;
                    array_add(loads, data[idx]);
                }
            }
            if !add_new {
                li := data[0].li;
                for * pd: gathered.* {
                    if inst_block(pd.*[0].li) == inst_block(li) && vtype(pd.*[0].li) == vtype(li) add_new_loads(pd, data, to_add, repeated);
                }
            }
            g := new_ld_group();
            for data array_add(*g, it);
            array_add(gathered, g);
            g2 := new_ld_group();
            add_new_loads(*g2, data, to_add, repeated);
            array_add(gathered, g2);
        }
    }
}
set_insert_u32 :: (l: *[..] u32, x: u32) { for l.* if it == x return; array_add(l, x); }

// the GatheredLoads collection at the end of transformNodes
slp_collect_and_vectorize_gathered_loads :: () {
    Gl_Key :: struct { bb: Value_Id; obj: Value_Id; ty: Type_Id; }
    keys: [..] Gl_Key; keys.allocator = temp;          // SmallMapVector: insertion order
    vals: [..] [..] Ld_Group; vals.allocator = temp;
    for k: 0..slp.entries.count-1 {
        t := cast(Te_Id) k;
        e := *slp.entries[k];
        if !te_is_gather(t) || slp_is_splat(e.scalars) continue;
        cand := te_has_state(t) && te_opcode(t) == .LOAD;
        if !cand && !te_has_state(t) {
            for v: e.scalars if is_inst(v) && inst_op(v) == .LOAD && !slp_is_vectorized(v) && !slp_is_deleted(v) { cand = true; break; }
        }
        if !cand continue;
        for v: e.scalars {
            if !is_inst(v) || inst_op(v) != .LOAD continue;
            if slp_is_deleted(v) || slp_is_vectorized(v) || !is_simple_load_store(v) continue;
            key := Gl_Key.{inst_block(v), get_underlying_object(op(v, 0), cast(u32) slp_cl.recursion_max_depth), vtype(v)};
            ki := -1;
            for keys if it.bb == key.bb && it.obj == key.obj && it.ty == key.ty { ki = it_index; break; }
            if ki < 0 { array_add(*keys, key); l: [..] Ld_Group; l.allocator = temp; array_add(*vals, l); ki = keys.count - 1; }
            one: [1] Value_Id; one[0] = v;
            slp_gather_possibly_vectorizable_loads(one, *vals[ki]);
        }
    }
    if keys.count slp_try_to_vectorize_gathered_loads(vals);
}

// tryToVectorizeGatheredLoads(GatheredLoads)
slp_try_to_vectorize_gathered_loads :: (gathered_loads: [] [..] Ld_Group) {
    slpx.gathered_loads_first = slp.entries.count;
    load_sets: [..] [..] Value_Id; load_sets.allocator = temp;
    for idx: slpx.load_entries_to_vectorize { l := vl_copy(slp.entries[idx].scalars); array_add(*load_sets, l); }
    is_masked_gather_supported :: (loads: [] Value_Id) -> bool {
        align := inst(loads[0]).align;
        for loads align = min(align, inst(it).align);
        ty := slp_widened_type(vtype(loads[0]), cast(u64) loads.count);
        return tti_is_legal_masked_gather(slp.tti, ty, align) && !tti_force_scalarize_masked_gather(slp.tti, ty, align);
    }
    Ls_Result :: struct { start: s64; count: s64; state: s32; }   // ArrayRef<Value *> into `loads`
    // GetVectorizedRanges(Loads, VectorizedLoads, NonVectorized, Final, MaxVF)
    get_vectorized_ranges :: (loads: [] Value_Id, vectorized: *[..] Value_Id, non_vectorized: *[..] Value_Id, final: bool, max_vf: u64) -> [..] Ls_Result {
        results: [..] Ls_Result; results.allocator = temp;
        start_idx: u64 = 0;
        cand_vfs: [..] u64; cand_vfs.allocator = temp;
        sty := vtype(loads[0]);
        if slp_is_allowed_non_power_of_2_vf(max_vf) array_add(*cand_vfs, max_vf);
        ne := slp_floor_full_vector_number_of_elements(slp.tti, sty, max_vf);
        while ne > 1 {
            array_add(*cand_vfs, ne);
            if slp_cl.non_power_of_2 && ne > 2 array_add(*cand_vfs, ne - 1);
            ne = slp_floor_full_vector_number_of_elements(slp.tti, sty, ne - 1);
        }
        if final && cand_vfs.count == 0 return results;
        best_vf: u64 = ifx final then cand_vfs[cand_vfs.count - 1] else 0;
        e := cast(u64) loads.count;
        for num_elts: cand_vfs {
            if final && num_elts > best_vf continue;
            masked_gather_vectorized: [..] u64; masked_gather_vectorized.allocator = temp;
            cnt := start_idx;
            while cnt < e {
                defer cnt += 1;
                slice := array_view(loads, cast(s64) cnt, cast(s64) min(num_elts, e - cnt));
                if slp_has(vectorized.*, slice[0]) || slp_has(vectorized.*, slice[slice.count - 1]) || slp_are_known_non_vectorizable_loads(slice) continue;
                allow := false;
                if num_elts == 2 {
                    legal_bcast := tti_is_legal_broadcast_load(slp.tti, vtype(slice[0]), num_elts);
                    check_if_allowed :: (slice: [] Value_Id, legal_bcast: bool) -> bool {
                        for li: slice {
                            if has_one_use(li) continue;
                            // std::distance(user_begin, user_end) == getNumUses(): always true
                            if !legal_bcast continue;
                            if has_n_uses_or_more(li, SLP_USES_LIMIT) return false;
                            u := ir.v_first_use[li];
                            while u != NONE {
                                usr := ir.u_user[u]; u = ir.u_next[u];
                                if is_inst(usr) && slp_is_deleted(usr) continue;
                                for ute: slp_get_tree_entries(usr) {
                                    for ops: slp.entries[ute].operands {
                                        all := true;
                                        for x: ops if !(x == li || pm_poison(x)) { all = false; break; }
                                        if all return false;
                                    }
                                }
                            }
                        }
                        return true;
                    }
                    allow = check_if_allowed(slice, legal_bcast);
                } else {
                    allow = num_elts >= 3;
                    if !allow {
                        p := table_find_pointer(*slpx.value_to_gather_nodes, slice[0]);
                        if !p fatal("internal: slp: ValueToGatherNodes.at");
                        for te: p.* {
                            sc := slp.entries[te].scalars;
                            if sc.count == 2 && ((sc[0] == slice[0] && sc[1] == slice[slice.count-1]) || (sc[0] == slice[slice.count-1] && sc[1] == slice[0])) { allow = true; break; }
                        }
                    }
                }
                if allow {
                    order: [..] u32; order.allocator = temp;
                    ptrs: [..] Value_Id; ptrs.allocator = temp;
                    ls := slp_can_vectorize_loads(slice, slice[0], *order, *ptrs, *best_vf);
                    if ls != LS_GATHER || (best_vf > 1 && num_elts == 2 * best_vf) {
                        if ls == LS_SCATTER {
                            if masked_gather_vectorized.count == 0 || cnt >= masked_gather_vectorized[masked_gather_vectorized.count - 1] + num_elts
                                array_add(*masked_gather_vectorized, cnt);
                            continue;
                        }
                        if ls != LS_GATHER {
                            array_add(*results, .{cast(s64) cnt, slice.count, ls});
                            for slice set_add_v(vectorized, it);
                            if cnt == start_idx start_idx += num_elts;
                        }
                        if start_idx >= e break;
                        if masked_gather_vectorized.count && cnt < masked_gather_vectorized[masked_gather_vectorized.count - 1] + num_elts
                            pop(*masked_gather_vectorized);
                        cnt += num_elts - 1;
                        continue;
                    }
                }
                if !allow || best_vf == 0 slp_register_non_vectorizable_loads(slice);
            }
            for c: masked_gather_vectorized {
                n := min(num_elts, e - c);
                array_add(*results, .{cast(s64) c, cast(s64) n, LS_SCATTER});
                for k: 0..cast(s64) n - 1 set_add_v(vectorized, loads[cast(s64) c + k]);
                if c == start_idx start_idx += num_elts;
            }
        }
        for li: loads if !slp_has(vectorized.*, li) array_add(non_vectorized, li);
        return results;
    }
    // ProcessGatheredLoads(GatheredLoads, Final)
    process_gathered_loads :: (groups: [] Ld_Group, final: bool, load_sets: [] [..] Value_Id) -> [..] Value_Id {
        non_vectorized: [..] Value_Id; non_vectorized.allocator = temp;
        for loads_dists: groups {
            if loads_dists.count <= 1 { array_add(*non_vectorized, loads_dists[loads_dists.count - 1].li); continue; }
            local := new_ld_group();
            for loads_dists array_add(*local, it);
            original: [..] Value_Id; original.allocator = temp;
            for loads_dists array_add(*original, it.li);
            // stable_sort by descending distance (insertion sort is stable)
            for i: 1..local.count-1 {
                x := local[i]; j := i;
                while j > 0 && x.dist > local[j-1].dist { local[j] = local[j-1]; j -= 1; }
                local[j] = x;
            }
            loads: [..] Value_Id; loads.allocator = temp;
            max_consecutive: u64 = 0;
            cur_consecutive: u64 = 1;
            last_dist := local[0].dist;
            allow_masked_gather := is_masked_gather_supported(original);
            for l: local {
                if slp_is_vectorized(l.li) continue;
                if cast(u64) (last_dist - l.dist) == cur_consecutive {
                    cur_consecutive += 1;
                    max_consecutive = max(max_consecutive, cur_consecutive);
                    array_add(*loads, l.li);
                    continue;
                }
                if !allow_masked_gather && cur_consecutive == 1 && loads.count pop(*loads);
                cur_consecutive = 1;
                last_dist = l.dist;
                array_add(*loads, l.li);
            }
            if loads.count <= 1 continue;
            if allow_masked_gather max_consecutive = cast(u64) loads.count;
            else if max_consecutive < 2 continue;
            vectorized: [..] Value_Id; vectorized.allocator = temp;
            sorted_non_vectorized: [..] Value_Id; sorted_non_vectorized.allocator = temp;
            results := get_vectorized_ranges(loads, *vectorized, *sorted_non_vectorized, final, max_consecutive);
            res_src := loads;
            all_scatter := true; for results if it.state != LS_SCATTER { all_scatter = false; break; }
            if results.count && sorted_non_vectorized.count && original.count == loads.count && max_consecutive == cast(u64) loads.count && all_scatter {
                array_reset_keeping_memory(*vectorized);
                unsorted_non_vectorized: [..] Value_Id; unsorted_non_vectorized.allocator = temp;
                unsorted_results := get_vectorized_ranges(original, *vectorized, *unsorted_non_vectorized, final, cast(u64) original.count);
                if sorted_non_vectorized.count >= unsorted_non_vectorized.count {
                    sorted_non_vectorized = unsorted_non_vectorized;
                    results = unsorted_results;
                    res_src = original;
                }
            }
            for r: results {
                slice := array_view(res_src, r.start, r.count);
                any_vec := false; for slice if slp_is_vectorized(it) { any_vec = true; break; }
                if any_vec {
                    for l: slice if !slp_is_vectorized(l) array_add(*sorted_non_vectorized, l);
                    continue;
                }
                max_vf := cast(u64) slice.count;
                user_max_vf: u64 = 0;
                interleave_factor: u32 = 0;
                if max_vf == 2 {
                    user_max_vf = max_vf;
                } else {
                    // the interleaved-loads distance analysis: X86's isLegalInterleavedAccessType is false, so
                    // InterleaveFactor stays 0; only UserMaxVF matters
                    pos_keys: [..] Te_Id; pos_keys.allocator = temp; pos_vals: [..] u64; pos_vals.allocator = temp;   // EntryToPosition
                    for v, idx: slice {
                        p := table_find_pointer(*slpx.value_to_gather_nodes, v);
                        if !p fatal("internal: slp: ValueToGatherNodes.at");
                        for te: p.* {
                            user_max_vf = max(user_max_vf, cast(u64) slp.entries[te].scalars.count);
                            pos: u64 = cast(u64) idx;
                            found := false;
                            for pos_keys if it == te { pos = pos_vals[it_index]; found = true; break; }
                            if !found { array_add(*pos_keys, te); array_add(*pos_vals, cast(u64) idx); }
                            user_max_vf = max(user_max_vf, cast(u64) idx - pos + 1);
                        }
                    }
                    consecutive_nodes_size: u64 = 0;
                    skip := false;
                    if slpx.load_entries_to_vectorize.count && interleave_factor == 0 {
                        for idx_e, pi: slpx.load_entries_to_vectorize {
                            set := load_sets[pi];
                            first_in := -1;
                            for v, k: slice if slp_has(set, v) { first_in = k; break; }
                            if first_in < 0 continue;
                            vl := slp.entries[idx_e].scalars;
                            st := slp_can_vectorize_loads(vl, vl[0]);
                            if st == LS_SCATTER || st == LS_COMPRESS continue;
                            consecutive_nodes_size += cast(u64) vl.count;
                            sz := slice.count - first_in;
                            if sz < vl.count || !vl_equal(array_view(slice, first_in, vl.count), vl) { skip = true; break; }
                        }
                    }
                    if skip continue;
                    user_max_vf = bit_ceil(user_max_vf);
                    if interleave_factor == 0 {
                        any_scatter := false;
                        for idx: 0..cast(s64) (cast(u64) slice.count / user_max_vf) - 1 {
                            sub := array_view(slice, idx * cast(s64) user_max_vf, cast(s64) user_max_vf);
                            if slp_can_vectorize_loads(sub, sub[0]) == LS_SCATTER { any_scatter = true; break; }
                        }
                        if any_scatter user_max_vf = max_vf;
                    }
                    if cast(u64) slice.count != consecutive_nodes_size max_vf = min(max_vf, user_max_vf);
                }
                vf := max_vf;
                while vf >= 2 {
                    is_vectorized := true;
                    i: u64 = 0;
                    e := cast(u64) slice.count;
                    while i < e {
                        defer i += vf;
                        sub := array_view(slice, cast(s64) i, cast(s64) min(vf, e - i));
                        if slp_is_vectorized(sub[0]) continue;
                        in_other := false;
                        for idx_e, pi: slpx.load_entries_to_vectorize {
                            if vl_equal(sub, slp.entries[idx_e].scalars) continue;
                            subset := true; for sub if !slp_has(load_sets[pi], it) { subset = false; break; }
                            if subset { in_other = true; break; }
                        }
                        if in_other continue;
                        sz := slp.entries.count;
                        slp_build_tree_rec(vl_copy(sub), 0, .{}, interleave_factor);
                        if sz == slp.entries.count {
                            is_vectorized = false;
                            continue;
                        }
                    }
                    if is_vectorized break;
                    vf /= 2;
                }
            }
            for sorted_non_vectorized array_add(*non_vectorized, it);
        }
        return non_vectorized;
    }
    for ref: gathered_loads {
        non_vectorized := process_gathered_loads(ref, false, load_sets);
        total := 0; for ref total += it.count;
        if ref.count && non_vectorized.count && total != non_vectorized.count && is_masked_gather_supported(non_vectorized) {
            final_groups: [..] Ld_Group; final_groups.allocator = temp;
            for li: non_vectorized {
                one: [1] Value_Id; one[0] = li;
                slp_gather_possibly_vectorizable_loads(one, *final_groups, false);
            }
            process_gathered_loads(final_groups, true, load_sets);
        }
    }
    for idx: slpx.load_entries_to_vectorize {
        e := *slp.entries[idx];
        gs := vl_copy(e.scalars);
        if e.reorder_indices.count {
            rm := slp_inverse_permutation(e.reorder_indices);
            slp_reorder_scalars(*gs, rm);
        }
        slp_build_tree_rec(gs, 0, .{});
    }
    if slpx.gathered_loads_first == slp.entries.count slpx.gathered_loads_first = -1;
}
