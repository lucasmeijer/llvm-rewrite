// SLPVectorizer: the cost of the whole tree. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::getRootEntryInstruction, buildExternalUses, getNumScalarInsts, getNumVectorInsts,
// calculateTreeCostAndTrimNonProfitable, getTreeCost, getSpillCost, isFirstInsertElement,
// areTwoInsertFromSameBuildVector, performExtractsShuffleAction).

External_User :: struct {
    scalar: Value_Id;
    user: Value_Id = NONE;
    te: Te_Id;
    lane: u32;
}

// getRootEntryInstruction(Entry)
slp_root_entry_instruction :: (te: Te_Id) -> Value_Id {
    e := *slp.entries[te];
    if te_has_state(te) && (te_opcode(te) == .STORE || te_opcode(te) == .LOAD) && e.state == TE_STRIDED_VECTORIZE &&
       e.reorder_indices.count && slp_is_reverse_order(e.reorder_indices) {
        v := e.scalars[e.reorder_indices[0]];
        return ifx is_inst(v) then v else NONE;
    }
    v := e.scalars[0];
    return ifx is_inst(v) then v else NONE;
}

te_dead_or_transformed :: (te: Te_Id) -> bool {
    return table_contains(*slp.deleted_nodes, te) || table_contains(*slp.transformed_to_gather_nodes, te);
}

// buildExternalUses(ExternallyUsedValues)
slp_build_external_uses :: (externally_used: [] Value_Id = .[]) {
    num_vect_scalars := slp.scalar_to_tree_entries.count + 1;
    s2e: Table(Value_Id, s64); s2e.allocator = temp;
    for k: 0..slp.entries.count-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[te];
        if te_is_gather(te) || e.state == TE_SPLIT_VECTORIZE || te_dead_or_transformed(te) continue;
        for lane: 0..e.scalars.count-1 {
            scalar := e.scalars[lane];
            if !is_inst(scalar) || slp_te_is_copyable(te, scalar) continue;
            is_struct := type_kind(vtype(scalar)) == .STRUCT;
            found, it_idx := table_find(*s2e, scalar);
            if found && slpx.external_uses[it_idx].user == NONE continue;
            if !is_struct && has_n_uses_or_more(scalar, num_vect_scalars) {
                fl := te_find_lane_for_value(te, scalar);
                if !found { table_set(*s2e, scalar, slpx.external_uses.count); found = true; it_idx = slpx.external_uses.count; }
                array_add(*slpx.external_uses, .{scalar, NONE, te, fl});
                set_add_v(*slpx.external_uses_with_non_users, scalar);
                continue;
            }
            if slp_has(externally_used, scalar) {
                fl := te_find_lane_for_value(te, scalar);
                if !found table_set(*s2e, scalar, slpx.external_uses.count);
                array_add(*slpx.external_uses, .{scalar, NONE, te, fl});
                continue;
            }
            u := ir.v_first_use[scalar];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                if !is_inst(usr) || slp_is_deleted(usr) continue;
                if slpx.has_user_ignore_list && slp_in_user_ignore_list(usr) continue;
                use_entries := slp_get_tree_entries(usr);
                any_live := false;
                for use_entries if !te_dead_or_transformed(it) { any_live = true; break; }
                user := usr;
                if any_live {
                    special := (type_kind(scalar_type(vtype(scalar))) == .PTR && (inst_op(usr) == .LOAD || inst_op(usr) == .STORE)) || inst_op(usr) == .CALL;
                    all_ok := true;
                    for ue: use_entries {
                        if te_dead_or_transformed(ue) continue;
                        if slp.entries[ue].state == TE_SCATTER_VECTORIZE || !slp_does_in_tree_user_need_to_extract(scalar, slp_root_entry_instruction(ue)) continue;
                        all_ok = false; break;
                    }
                    if !special || all_ok continue;
                    if !is_struct {
                        user = NONE;
                        if found { slpx.external_uses[it_idx].user = NONE; break; }
                    }
                }
                if user != NONE && !is_struct && has_n_uses_or_more(scalar, SLP_USES_LIMIT) user = NONE;
                fl := te_find_lane_for_value(te, scalar);
                if !found { table_set(*s2e, scalar, slpx.external_uses.count); found = true; it_idx = slpx.external_uses.count; }
                array_add(*slpx.external_uses, .{scalar, user, te, fl});
                set_add_v(*slpx.external_uses_with_non_users, scalar);
                if user == NONE break;
            }
        }
    }
}
set_add_v :: (s: *[..] Value_Id, v: Value_Id) { if !slp_has(s.*, v) array_add(s, v); }

// getNumScalarInsts()
slp_num_scalar_insts :: () -> u32 {
    count: u32 = 0;
    for k: 0..slp.entries.count-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[te];
        if table_contains(*slp.deleted_nodes, te) continue;
        if te_is_gather(te) || table_contains(*slp.transformed_to_gather_nodes, te) {
            for v: e.scalars if is_inst(v) && inst_op(v) == .EXTRACTELEMENT count += 1;
            continue;
        }
        if e.state == TE_COMBINED_VECTORIZE continue;
        for v: e.scalars {
            if !is_inst(v) || (slp_te_has_copyables(te) && slp_te_is_copyable(te, v)) continue;
            count += 1;
            o := inst_op(v);
            if is_int_div_rem(o) || o == .FDIV || o == .FREM count += 1;
            if o == .CALL && !is_trivially_vectorizable(get_vector_intrinsic_id_for_call(v)) count += 1;
        }
        if e.combined_op == TE_NOT_COMBINED && te_has_state(te) {
            o := te_opcode(te);
            if o == .SELECT {
                for v: e.scalars {
                    if slp_te_has_copyables(te) && slp_te_is_copyable(te, v) continue;
                    if !is_inst(v) || inst_op(v) != .SELECT continue;
                    a: [1] Value_Id; a[0] = v;
                    id, _ := slp_can_convert_to_min_or_max_intrinsic(a);
                    if id != NOT_INTRINSIC count -= 1;
                }
            } else if o == .FADD || o == .FSUB {
                for v: e.scalars {
                    if slp_te_has_copyables(te) && slp_te_is_copyable(te, v) continue;
                    if !is_inst(v) || (is_alt_shuffle(e.s) && inst_op(v) != .FADD && inst_op(v) != .FSUB) continue;
                    a: [1] Value_Id; a[0] = v;
                    if cost_valid(slp_can_convert_to_fma(a, .{v, v, false})) count -= 1;
                }
            }
        }
    }
    return count;
}

// getNumVectorInsts()
slp_num_vector_insts :: () -> u32 {
    count: u32 = 0;
    src_vecs: [..] Value_Id; src_vecs.allocator = temp;
    for k: 0..slp.entries.count-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[te];
        if table_contains(*slp.deleted_nodes, te) continue;
        if e.state == TE_COMBINED_VECTORIZE continue;
        if te_is_gather(te) || table_contains(*slp.transformed_to_gather_nodes, te) {
            if te_has_state(te) {
                s := slp_get_same_values_tree_entry(e.s.main, e.scalars);
                if s != TE_NONE && s != te && te_vector_factor(s) == te_vector_factor(te) continue;
                rev := vl_copy(e.scalars);
                for i: 0..rev.count/2-1 { t := rev[i]; rev[i] = rev[rev.count-1-i]; rev[rev.count-1-i] = t; }
                s = slp_get_same_values_tree_entry(e.s.main, rev);
                if s != TE_NONE && te_vector_factor(s) == te_vector_factor(te) { count += 1; continue; }
            }
            all_ee := true;
            for v: e.scalars if !((is_inst(v) && inst_op(v) == .EXTRACTELEMENT) || is_const(v)) { all_ee = false; break; }
            if all_ee {
                for v: e.scalars if is_inst(v) && inst_op(v) == .EXTRACTELEMENT set_add_v(*src_vecs, op(v, 0));
            } else {
                for v: e.scalars if !slp_is_constant(v) count += 1;
            }
            continue;
        }
        o := te_opcode(te);
        if o == .INSERTELEMENT || o == .EXTRACTELEMENT continue;
        if o == .INSERTVALUE {
            if !slp_can_vector_store_insert_value(te) count += 2;
            if e.reorder_indices.count || e.reuse_shuffle_indices.count count += 1;
            continue;
        }
        if e.state == TE_SPLIT_VECTORIZE count += 2; else count += 1;
        if e.reorder_indices.count || e.reuse_shuffle_indices.count count += 1;
    }
    count += cast(u32) src_vecs.count;
    counted: [..] Value_Id; counted.allocator = temp;
    for eu: slpx.external_uses {
        if eu.user != NONE && inst_op(eu.user) == .INSERTELEMENT continue;
        if eu.user != NONE && table_contains(*slpx.eph_values, eu.user) continue;
        if is_vectorized_ty(vtype(eu.scalar)) continue;
        if slp_has(slpx.external_uses_as_original_scalar, eu.scalar) continue;
        if slp_has(counted, eu.scalar) continue;
        array_add(*counted, eu.scalar);
        count += 1;
    }
    return count;
}

// ---------------------------------------------------------------- calculateTreeCostAndTrimNonProfitable

Subtree_Cost :: struct { total: Cost; cost: Cost; nodes: [..] s64; }

// calculateTreeCostAndTrimNonProfitable(VectorizedVals, RdxRoot)
slp_calculate_tree_cost_and_trim_non_profitable :: (vectorized_vals: [] Value_Id = .[], rdx_root: Value_Id = NONE) -> Cost {
    n := slp.entries.count;
    for k: 0..n-1 if te_is_gather(cast(Te_Id) k) && type_kind(vtype(slp.entries[k].scalars[0])) == .STRUCT return COST_INVALID;
    #if DEBUG_SLP for slp.entries print("DBG tree te% state=% scalars=% reuse=% reorder=% user=%\n", it_index, it.state, it.scalars, it.reuse_shuffle_indices, it.reorder_indices, it.user_tree_index);
    NO_COST :: COST_INVALID + 1;   // "not in NodesCosts"
    nodes_costs := NewArray(n, Cost,, temp);
    for * nodes_costs it.* = NO_COST;
    checked_extracts: [..] Value_Id; checked_extracts.allocator = temp;
    gathered_loads_nodes: [..] Te_Id; gathered_loads_nodes.allocator = temp;
    extract_costs := NewArray(n, Cost,, temp);   // lookup() default 0
    num_vect_scalars := slp.scalar_to_tree_entries.count + 1;
    ext_cache: Table(Value_Id, bool); ext_cache.allocator = temp;
    is_externally_used_v :: (v: Value_Id, cache: *Table(Value_Id, bool), num_vect_scalars: s64) -> bool {
        found, r := table_find(cache, v);
        if found return r;
        res := false;
        if value_has_one_use(v) || type_kind(vtype(v)) == .VOID {
        } else if has_n_uses_or_more(v, num_vect_scalars) {
            res = true;
        } else if is_inst(v) {
            u := ir.v_first_use[v];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                if is_inst(usr) && inst_op(usr) == .INSERTELEMENT && vkind(op(usr, 2)) == .C_INT {
                    x := op(usr, 1);
                    if x == v continue;
                    if is_inst(x) && is_cast_op(inst_op(x)) && op(x, 0) == v && has_one_use(x) continue;
                }
                if is_inst(usr) && inst_op(usr) == .STORE {
                    x := op(usr, 0);
                    if x == v continue;
                    if is_inst(x) && is_cast_op(inst_op(x)) && op(x, 0) == v && has_one_use(x) continue;
                }
                ents := slp_get_tree_entries(usr);
                if ents.count == 0 && !table_contains(*slp.must_gather, usr) { res = true; break; }
                del := false;
                for ents if table_contains(*slp.deleted_nodes, it) { del = true; break; }
                if del { res = true; break; }
                p := table_find_pointer(*slpx.value_to_gather_nodes, usr);
                if p for p.* if table_contains(*slp.deleted_nodes, it) { del = true; break; }
                if del { res = true; break; }
            }
        }
        table_set(cache, v, res);
        return res;
    }
    cost: Cost = 0;
    entry_to_scale := NewArray(n, u64,, temp);
    prev_scale: u64 = 0;
    prev_vec_parent: Value_Id = NONE;
    for k: 0..n-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[te];
        if e.state == TE_COMBINED_VECTORIZE { nodes_costs[k] = 0; continue; }
        if te_has_state(te) && (te_is_gather(te) || e.state == TE_SPLIT_VECTORIZE) {
            s := slp_get_same_values_tree_entry(e.s.main, e.scalars);
            if s != TE_NONE && te_vector_factor(s) == te_vector_factor(te) { nodes_costs[k] = 0; #if DEBUG_SLP print("SLP: Adding cost 0 for bundle Idx: %\n", te); continue; }
        }
        c := slp_get_entry_cost(te, vectorized_vals, *checked_extracts);
        #if DEBUG_SLP print("DBG cost te% = %\n", te, cost_to_string(c));
        scale: u64 = 0;
        cost_is_free := c == 0;
        is_gather_like := te_is_gather(te) || e.state == TE_SPLIT_VECTORIZE;
        if !cost_is_free && !te_is_gather(te) && te_has_state(te) {
            if prev_vec_parent == inst_block(e.s.main) {
                scale = prev_scale;
                c = cost_scale(c, scale);
                if entry_to_scale[k] == 0 entry_to_scale[k] = scale;
            }
        }
        if !cost_is_free && scale == 0 {
            scale = ifx is_gather_like then slp_gather_node_effective_scale(te, ifx te == 0 then rdx_root else NONE) else slp_scale_to_loop_iterations(te);
            c = cost_scale(c, scale);
            if entry_to_scale[k] == 0 entry_to_scale[k] = scale;
            if !te_is_gather(te) && te_has_state(te) { prev_vec_parent = inst_block(e.s.main); prev_scale = scale; }
        }
        #if DEBUG_SLP print("SLP: Adding cost % for bundle Idx: %\n", cost_to_string(c), te);
        cost = cost_add(cost, c);
        nodes_costs[k] = c;
        if te > 0 && e.user_tree_index.user == TE_NONE && te_has_state(te) && te_opcode(te) == .LOAD set_add_te(*gathered_loads_nodes, te);
        if !te_is_gather(te) && e.state != TE_SPLIT_VECTORIZE &&
           !(te == 0 && (te_opcode(te) == .INSERTELEMENT || te_opcode(te) == .INSERTVALUE || te_opcode(te) == .STORE)) &&
           type_kind(slp_get_value_type(e.scalars[0])) != .STRUCT {
            dem := NewArray(te_vector_factor(te), bool,, temp);
            any := false;
            for v: e.scalars {
                if te_has_state(te) && slp_te_has_copyables(te) && slp_te_is_copyable(te, v) continue;
                if is_externally_used_v(v, *ext_cache, num_vect_scalars) { dem[te_find_lane_for_value(te, v)] = true; any = true; }
            }
            if any {
                sty := vtype(e.scalars[0]);
                found, bw := slp_min_bw_of(te);
                if found sty = type_int(cast(u32) bw.bits);
                vec_ty := slp_widened_type(sty, cast(u64) te_vector_factor(te));
                ext := slp_get_scalarization_overhead(sty, vec_ty, dem, false, true, TCK_RECIP_THROUGHPUT);
                if cost_valid(ext) && ext != 0 {
                    if scale == 0 scale = slp_scale_to_loop_iterations(te);
                    ext = cost_scale(ext, scale);
                    if entry_to_scale[k] == 0 entry_to_scale[k] = scale;
                }
                extract_costs[k] = ext;
            }
        }
    }
    if slp_cl.threshold_given && slp_cl.threshold < 0 && cost < -slp_cl.threshold return cost;
    PART_LIMIT :: 2;
    root := *slp.entries[0];
    sz: u64;
    rfound, rbw := slp_min_bw_of(0);
    if rfound sz = rbw.bits;
    else sz = max(slp_get_vector_element_size(root.scalars[0]), dl_type_size_bits(scalar_type(slp_get_value_type(root.scalars[0]))));
    min_vf := slp_get_min_vf(sz);
    if cost >= -slp_cl.threshold && cast(u64) root.scalars.count * PART_LIMIT <= min_vf &&
       (!te_has_state(0) || (te_opcode(0) != .STORE && li_loop_for(slp.li, inst_block(root.s.main)) != NONE))
        return cost;
    subtree := NewArray(n, Subtree_Cost,, temp);
    for * subtree it.nodes.allocator = temp;
    Visit_Pair :: struct { a: Te_Id; b: Te_Id; }
    update_parent_nodes :: (subtree: [] Subtree_Cost, user_in: Te_Id, te: Te_Id, total: Cost, c: Cost, visited: *[..] Visit_Pair, add_to_list := true) {
        user := user_in;
        while user != TE_NONE {
            p := Visit_Pair.{te, user};
            dup := false; for visited.* if it.a == p.a && it.b == p.b { dup = true; break; }
            if dup break;
            array_add(visited, p);
            subtree[user].total = cost_add(subtree[user].total, total);
            subtree[user].cost = cost_add(subtree[user].cost, c);
            if add_to_list array_add(*subtree[user].nodes, te);
            user = slp.entries[user].user_tree_index.user;
        }
    }
    for k: 0..n-1 {
        c := nodes_costs[k];
        if c == NO_COST fatal("internal: slp: NodesCosts.at");
        ec := extract_costs[k];
        subtree[k].total = cost_add(subtree[k].total, cost_add(c, ec));
        subtree[k].cost = cost_add(subtree[k].cost, c);
        u := slp.entries[k].user_tree_index.user;
        if u != TE_NONE {
            visited: [..] Visit_Pair; visited.allocator = temp;
            update_parent_nodes(subtree, u, cast(Te_Id) k, cost_add(c, ec), c, *visited);
        }
    }
    {
        visited: [..] Visit_Pair; visited.allocator = temp;
        for te: gathered_loads_nodes {
            tot := subtree[te].total; cc := subtree[te].cost;
            for v: slp.entries[te].scalars {
                p := table_find_pointer(*slpx.value_to_gather_nodes, v);
                if p for bvte: p.* update_parent_nodes(subtree, bvte, te, tot, cc, *visited, false);
            }
        }
    }
    // PriorityQueue<CostIndicesTy, ..., FirstGreater>: the top is the largest (total, Idx)
    order: [..] s64; order.allocator = temp;
    for k: 0..n-1 array_add(*order, k);
    less :: (subtree: [] Subtree_Cost, a: s64, b: s64) -> bool {
        return subtree[a].total < subtree[b].total || (subtree[a].total == subtree[b].total && a < b);
    }
    // the keys are distinct (Idx breaks ties), so popping in descending order is exactly the heap's order
    for i: 1..order.count-1 {
        x := order[i]; j := i;
        while j > 0 && less(subtree, order[j-1], x) { order[j] = order[j-1]; j -= 1; }
        order[j] = x;
    }
    if !slpx.has_user_ignore_list && te_vector_factor(0) < cast(s64) min_vf && te_has_state(0) && te_opcode(0) == .STORE &&
       (order[0] == 0 || order[0] == 1)
        return cost;
    changed := false;
    prefer_trimmed := false;
    for top: order {
        if !(subtree[top].total > 0) break;
        te := cast(Te_Id) top;
        e := *slp.entries[te];
        if te_is_gather(te) || te == 0 || table_contains(*slp.deleted_nodes, te) || type_kind(slp_get_value_type(e.scalars[0])) == .STRUCT continue;
        if e.user_tree_index.user != TE_NONE && slp.entries[e.user_tree_index.user].state == TE_SPLIT_VECTORIZE {
            any := false;
            for v: e.scalars if slp_get_split_tree_entries(v).count > 1 { any = true; break; }
            if any continue;
        }
        if e.state == TE_VECTORIZE && !is_alt_shuffle(e.s) && (te_opcode(te) == .ICMP || te_opcode(te) == .FCMP) {
            mp := inst(e.s.main).pred;
            any := false;
            for v: e.scalars if is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP) && inst(v).pred != mp { any = true; break; }
            if any continue;
        }
        total := subtree[top].total;
        sub_cost := subtree[top].cost;
        if total < cast(s64) e.scalars.count continue;
        if slp.transformed_to_gather_nodes.count {
            for idx: subtree[top].nodes {
                found, tc := table_find(*slp.transformed_to_gather_nodes, cast(Te_Id) idx);
                if found {
                    total = cost_add(cost_sub(total, subtree[idx].total), tc);
                    sub_cost = cost_add(cost_sub(sub_cost, subtree[idx].cost), tc);
                }
            }
        }
        if total < 0 || total < cast(s64) e.scalars.count continue;
        entry_vf := te_vector_factor(te);
        dem := NewArray(entry_vf, bool,, temp);
        for v, i: e.scalars if !slp_is_constant(v) dem[i] = true;
        sty := slp_get_value_type(e.scalars[0]);
        found, bw := slp_min_bw_of(te);
        if found sty = type_int(cast(u32) bw.bits);
        vec_ty := slp_widened_type(sty, cast(u64) entry_vf);
        gather_cost := slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT);
        mask := new_mask();
        if e.reorder_indices.count && e.state != TE_COMPRESS_VECTORIZE && (e.state != TE_STRIDED_VECTORIZE || !slp_is_reverse_order(e.reorder_indices)) {
            nm: [..] s32;
            if te_opcode(te) == .STORE { nm = new_mask(); for e.reorder_indices array_add(*nm, cast(s32) it); }
            else nm = slp_inverse_permutation(e.reorder_indices);
            slp_add_mask(*mask, nm);
        }
        if e.reuse_shuffle_indices.count slp_add_mask(*mask, e.reuse_shuffle_indices);
        if mask.count && !svm_is_identity(mask, entry_vf) gather_cost = cost_add(gather_cost, slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, vec_ty, mask));
        if !te_has_state(te) || !is_alt_shuffle(e.s) {
            all := true;
            for v: e.scalars {
                if (slp_te_has_copyables(te) && slp_te_is_copyable(te, v)) || slp_is_constant(v) || slp_is_gathered(v) || slp_get_tree_entries(v).count > 1 continue;
                all = false; break;
            }
            if all gather_cost = cost_mul(gather_cost, 2);
        }
        nodes := subtree[top].nodes;
        is_equal_cost_alt :: (total: Cost, gather_cost: Cost, te: Te_Id, nodes: [] s64) -> bool {
            if !(total == gather_cost && te_has_state(te) && is_alt_shuffle(slp.entries[te].s) && is_binary_op(te_opcode(te))) return false;
            for nodes if te_has_state(cast(Te_Id) it) && te_opcode(cast(Te_Id) it) == .EXTRACTELEMENT return false;
            return true;
        }
        has_np2 := false;
        for nodes if !has_single_bit(cast(u64) slp.entries[it].scalars.count) { has_np2 = true; break; }
        margin: Cost = ifx has_np2 then 1 else 0;
        if total > cost_add(gather_cost, margin) || is_equal_cost_alt(total, gather_cost, te, nodes) {
            prefer_trimmed |= total == gather_cost;
            if te_has_state(0) && te_opcode(0) == .INSERTELEMENT && te == 1 {
                if cost < -slp_cl.threshold continue;
                return COST_INVALID;
            }
            if e.user_tree_index.user != TE_NONE {
                if !table_contains(*slp.transformed_to_gather_nodes, te) table_set(*slp.transformed_to_gather_nodes, te, gather_cost);
                nodes_costs[top] = NO_COST;
            } else {
                table_set(*slp.deleted_nodes, te, true);
                table_remove(*slp.transformed_to_gather_nodes, te);
                nodes_costs[top] = NO_COST;
            }
            for idx: nodes {
                table_set(*slp.deleted_nodes, cast(Te_Id) idx, true);
                table_remove(*slp.transformed_to_gather_nodes, cast(Te_Id) idx);
                nodes_costs[idx] = NO_COST;
            }
            changed = true;
        }
    }
    if !changed return subtree[0].cost;
    to_delete: [..] Te_Id; to_delete.allocator = temp;
    loads_extracts: Cost = 0;
    for te: gathered_loads_nodes {
        if te_dead_or_transformed(te) continue;
        set_add_te(*to_delete, te);
        e := *slp.entries[te];
        dem := NewArray(te_vector_factor(te), bool,, temp);
        any := false;
        bv_keys: [..] Te_Id; bv_keys.allocator = temp;   // SmallDenseMap: summed, order irrelevant
        bv_vals: [..] [..] Value_Id; bv_vals.allocator = temp;
        for v: e.scalars {
            pos := te_find_lane_for_value(te, v);
            p := table_find_pointer(*slpx.value_to_gather_nodes, v);
            if p for bve: p.* {
                if table_contains(*slp.deleted_nodes, bve) continue;
                dem[pos] = true; any = true;
                ki := -1; for bv_keys if it == bve { ki = it_index; break; }
                if ki < 0 { array_add(*bv_keys, bve); array_add(*bv_vals, hr_new_list()); ki = bv_keys.count - 1; }
                array_add(*bv_vals[ki], v);
            }
        }
        if any {
            sty := vtype(e.scalars[0]);
            found, bw := slp_min_bw_of(te);
            if found sty = type_int(cast(u32) bw.bits);
            vec_ty := slp_widened_type(sty, cast(u64) te_vector_factor(te));
            extracts := slp_get_scalarization_overhead(sty, vec_ty, dem, false, true, TCK_RECIP_THROUGHPUT);
            bv_cost: Cost = 0;
            for bve: bv_keys {
                bvf := te_vector_factor(bve);
                bdem := NewArray(bvf, bool,, temp);
                bvals := NewArray(bvf, Value_Id,, temp);
                for * bvals it.* = const_poison(sty);
                for v: bv_vals[it_index] { pos := te_find_lane_for_value(bve, v); bvals[pos] = v; bdem[pos] = true; }
                bv_cost = cost_add(bv_cost, slp_get_scalarization_overhead(sty, slp_widened_type(sty, cast(u64) bvf), bdem, true, false, TCK_RECIP_THROUGHPUT, all_bits(bdem), bvals));
            }
            if extracts < bv_cost {
                loads_extracts = cost_add(loads_extracts, extracts);
                for d, i: to_delete if d == te { array_ordered_remove_by_index(*to_delete, i); break; }
                continue;
            }
            loads_extracts = cost_add(loads_extracts, bv_cost);
        }
        nodes_costs[te] = NO_COST;
    }
    for k: 0..n-1 {
        u := slp.entries[k].user_tree_index.user;
        if u != TE_NONE && slp_has(to_delete, u) {
            table_set(*slp.deleted_nodes, cast(Te_Id) k, true);
            nodes_costs[k] = NO_COST;
            set_add_te(*to_delete, cast(Te_Id) k);
        }
        if slp_has(to_delete, cast(Te_Id) k) table_set(*slp.deleted_nodes, cast(Te_Id) k, true);
    }
    for k: 0..n-1 {
        te := cast(Te_Id) k;
        if slp.entries[k].user_tree_index.user == TE_NONE && table_contains(*slp.transformed_to_gather_nodes, te) continue;
        if table_contains(*slp.deleted_nodes, te) continue;
        if nodes_costs[k] == NO_COST {
            c := slp_get_entry_cost(te, vectorized_vals, *checked_extracts);
            if !cost_valid(c) || c == 0 { nodes_costs[k] = c; continue; }
            scale := entry_to_scale[k];
            if scale == 0 {
                is_gather_like := te_is_gather(te) || slp.entries[k].state == TE_SPLIT_VECTORIZE;
                scale = ifx is_gather_like then slp_gather_node_effective_scale(te) else slp_scale_to_loop_iterations(te);
            }
            nodes_costs[k] = cost_scale(c, scale);
        }
    }
    new_cost: Cost = 0;
    for nodes_costs if it != NO_COST new_cost = cost_add(new_cost, it);
    if cost_add(new_cost, loads_extracts) > cost || (!prefer_trimmed && cost_add(new_cost, loads_extracts) == cost) {
        table_reset(*slp.deleted_nodes);
        table_reset(*slp.transformed_to_gather_nodes);
        new_cost = cost;
    } else {
        if n >= 2 && te_has_state(0) && te_opcode(0) == .INSERTELEMENT && table_contains(*slp.transformed_to_gather_nodes, 1) return COST_INVALID;
        if n >= 3 && te_has_state(0) && te_opcode(0) == .INSERTELEMENT && te_has_state(1) && slp.entries[1].state == TE_VECTORIZE &&
           (te_opcode(1) == .ZEXT || te_opcode(1) == .SEXT || te_opcode(1) == .TRUNC) && table_contains(*slp.transformed_to_gather_nodes, 2)
            return COST_INVALID;
    }
    return new_cost;
}
set_add_te :: (s: *[..] Te_Id, v: Te_Id) { if !slp_has(s.*, v) array_add(s, v); }

// ---------------------------------------------------------------- getTreeCost helpers

// isFirstInsertElement(IE1, IE2)
slp_is_first_insert_element :: (ie1: Value_Id, ie2: Value_Id) -> bool {
    if ie1 == ie2 return false;
    i1 := ie1; i2 := ie2;
    _, idx1 := slp_element_index(ie1);
    _, idx2 := slp_element_index(ie2);
    is_ie :: (v: Value_Id) -> bool { return v != NONE && is_inst(v) && inst_op(v) == .INSERTELEMENT; }
    while true {
        if i2 == ie1 return true;
        if i1 == ie2 return false;
        p1 := i1; p2 := i2;
        if i1 != NONE && (i1 == ie1 || has_one_use(i1)) {
            ok, x := slp_element_index(i1);
            if (ifx ok then x else idx2) != idx2 i1 = ifx is_ie(op(i1, 0)) then op(i1, 0) else NONE;
        }
        if i2 != NONE && (i2 == ie2 || has_one_use(i2)) {
            ok, x := slp_element_index(i2);
            if (ifx ok then x else idx1) != idx1 i2 = ifx is_ie(op(i2, 0)) then op(i2, 0) else NONE;
        }
        if !((i1 != NONE && p1 != i1) || (i2 != NONE && p2 != i2)) break;
    }
    fatal("internal: slp: two different buildvectors not expected");
    return false;
}

// areTwoInsertFromSameBuildVector(VU, V, GetBaseOperand) with the getTreeCost / vectorizeTree GetBaseOperand
slp_are_two_insert_from_same_build_vector :: (vu: Value_Id, v: Value_Id) -> bool {
    if inst_block(vu) != inst_block(v) return false;
    if vtype(vu) != vtype(v) return false;
    if !has_one_use(vu) && !has_one_use(v) return false;
    ok1, idx1 := slp_element_index(vu);
    ok2, idx2 := slp_element_index(v);
    if !ok1 || !ok2 return false;
    get_base :: (ii: Value_Id) -> Value_Id {
        op0 := op(ii, 0);
        if slp_is_vectorized(ii) && !slp_is_vectorized(op0) return NONE;
        return op0;
    }
    is_ie :: (x: Value_Id) -> bool { return x != NONE && is_inst(x) && inst_op(x) == .INSERTELEMENT; }
    reused := NewArray(cast(s64) type_count(vtype(vu)), bool,, temp);
    is_reused := false;
    ie1 := vu; ie2 := v;
    while true {
        if ie2 == vu && ie1 == NONE return has_one_use(vu);
        if ie1 == v && ie2 == NONE return has_one_use(v);
        if ie1 != NONE && ie1 != v {
            ok, x := slp_element_index(ie1);
            i := ifx ok then x else idx2;
            is_reused |= reused[i];
            reused[i] = true;
            if (ie1 != vu && !has_one_use(ie1)) || is_reused ie1 = NONE;
            else { b := get_base(ie1); ie1 = ifx is_ie(b) then b else NONE; }
        }
        if ie2 != NONE && ie2 != vu {
            ok, x := slp_element_index(ie2);
            i := ifx ok then x else idx1;
            is_reused |= reused[i];
            reused[i] = true;
            if (ie2 != v && !has_one_use(ie2)) || is_reused ie2 = NONE;
            else { b := get_base(ie2); ie2 = ifx is_ie(b) then b else NONE; }
        }
        if !((!is_reused && (ie1 != NONE || ie2 != NONE))) break;
    }
    return false;
}

Te_Mask :: struct { te: Te_Id; mask: [..] s32; }
Scale_Key :: struct { te: Te_Id; scalar: Value_Id; u: Value_Id; }

// getTreeCost(TreeCost, VectorizedVals, ReductionCost, RdxRoot)
slp_get_tree_cost :: (tree_cost: Cost, vectorized_vals: [] Value_Id = .[], reduction_cost_in: Cost = 0, rdx_root: Value_Id = NONE) -> Cost {
    reduction_cost := reduction_cost_in;
    n := slp.entries.count;
    t := slp.tti;
    K :: TCK_RECIP_THROUGHPUT;
    if slp_cl.inst_count_check && te_vector_factor(0) == 2 && slp_cl.threshold == 0 && !is_vector_type(vtype(slp.entries[0].scalars[0])) {
        num_scalar := slp_num_scalar_insts();
        num_vector := slp_num_vector_insts();
        #if DEBUG_SLP print("DBG inst count check: vector=% scalar=%\n", num_vector, num_scalar);
        if num_vector > num_scalar {
            bypass := false;
            if slp_cl.poor_throughput && tree_cost < -slp_cl.threshold {
                cache: Poor_Throughput_Cache;
                for k: 0..n-1 {
                    te := cast(Te_Id) k;
                    if te_has_state(te) && !table_contains(*slp.deleted_nodes, te) && !te_is_gather(te) && !table_contains(*slp.transformed_to_gather_nodes, te) &&
                       slp.entries[k].state != TE_COMBINED_VECTORIZE && slp_is_poor_throughput_op(slp.entries[k].s.main, *cache) { bypass = true; break; }
                }
            }
            if !bypass return COST_INVALID;
        }
    }
    cost := tree_cost;
    scale_keys: [..] Scale_Key; scale_keys.allocator = temp;
    scale_vals: [..] u64; scale_vals.allocator = temp;
    scale_cost :: (c: Cost, te: Te_Id, scalar: Value_Id, u: Value_Id, keys: *[..] Scale_Key, vals: *[..] u64) -> Cost {
        if !cost_valid(c) || c == 0 return c;
        for keys.* if it.te == te && it.scalar == scalar && it.u == u {
            if vals.*[it_index] == 0 vals.*[it_index] = slp_scale_to_loop_iterations(te, scalar, u);
            return cost_scale(c, vals.*[it_index]);
        }
        s := slp_scale_to_loop_iterations(te, scalar, u);
        array_add(keys, .{te, scalar, u}); array_add(vals, s);
        return cost_scale(c, s);
    }
    reduction_root := rdx_root;
    if slpx.has_user_ignore_list reduction_cost = scale_cost(reduction_cost, 0, NONE, reduction_root, *scale_keys, *scale_vals);
    cost = cost_add(cost, reduction_cost);
    for eu: slpx.external_uses {
        if type_kind(vtype(eu.scalar)) == .STRUCT &&
           (eu.te != 0 || slp.entries[eu.te].state != TE_VECTORIZE || te_opcode(eu.te) != .INSERTVALUE) &&
           !(eu.user != NONE && inst_op(eu.user) == .EXTRACTVALUE)
            return COST_INVALID;
    }
    COST_LIMIT :: 100;
    if cost >= -slp_cl.threshold + COST_LIMIT && cast(s64) (n - slp.deleted_nodes.count) * te_vector_factor(0) < COST_LIMIT return cost;
    any_ie_user := false;
    for eu: slpx.external_uses if eu.user != NONE && inst_op(eu.user) == .INSERTELEMENT { any_ie_user = true; break; }
    if cost >= -slp_cl.threshold && !any_ie_user return cost;

    Extract_Key :: struct { scalar: Value_Id; indices: [] u32; }
    extract_calculated: [..] Extract_Key; extract_calculated.allocator = temp;
    extract_cost: Cost = 0;
    Shuffled_Inserts :: struct { inserts: [..] Value_Id; vm_keys: [..] Te_Id; vm_masks: [..] [..] s32; }
    shuffled: [..] Shuffled_Inserts; shuffled.allocator = temp;
    demanded: [..] [] bool; demanded.allocator = temp;
    used_inserts: [..] Value_Id; used_inserts.allocator = temp;
    vector_casts: [..] [2] u32; vector_casts.allocator = temp;
    have_v2e := false;
    v2e: Table(Value_Id, s64); v2e.allocator = temp;
    extracts_count_keys: [..] Te_Id; extracts_count_keys.allocator = temp;
    extracts_count_sets: [..] [..] Value_Id; extracts_count_sets.allocator = temp;
    scalar_ops_from_casts: [..] Value_Id; scalar_ops_from_casts.allocator = temp;
    // external uses that drive address computations
    all_users_geps := true;
    pointers: [..] Value_Id; pointers.allocator = temp;
    user_sty: Value_Id = NONE;
    for eu: slpx.external_uses {
        usr := eu.user;
        if usr != NONE && has_one_use(usr) && (inst_op(usr) == .ZEXT || inst_op(usr) == .SEXT) usr = first_user(usr);
        gep := ifx usr != NONE && is_inst(usr) && inst_op(usr) == .GEP then usr else NONE;
        access_ty: Value_Id = NONE;
        if gep != NONE && has_one_use(gep) {
            ub := first_user(gep);
            if is_inst(ub) && (inst_op(ub) == .LOAD || inst_op(ub) == .STORE) access_ty = slp_get_value_type(ub);
        }
        if access_ty != NONE && type_kind(access_ty) != .SVECTOR && (user_sty == NONE || user_sty == access_ty) {
            user_sty = access_ty;
            array_add(*pointers, gep);
        } else { all_users_geps = false; break; }
    }
    // ScalarToExtractBlock
    s2b: Table(Value_Id, Value_Id); s2b.allocator = temp;
    for eu: slpx.external_uses {
        if eu.user == NONE || inst_op(eu.user) == .INSERTELEMENT continue;
        if table_contains(*slpx.eph_values, eu.user) continue;
        up := inst_block(eu.user);
        if !dt_is_reachable_from_entry(slp.dt, up) || is_eh_pad(block_first_non_phi(up)) || block_ends_unreachable(up) continue;
        use_block: Value_Id = NONE;
        if inst_op(eu.user) == .PHI {
            phi := eu.user;
            if li_loop_for(slp.li, inst_block(phi)) != NONE {
                for k: 0..cast(s64) phi_num_incoming(phi) - 1 {
                    if phi_value(phi, cast(u32) k) != eu.scalar continue;
                    in_bb := phi_block(phi, cast(u32) k);
                    use_block = ifx use_block != NONE then dt_find_nca(slp.dt, use_block, in_bb) else in_bb;
                }
            }
            if use_block == NONE use_block = inst_block(eu.user);
        } else use_block = inst_block(eu.user);
        found, cur := table_find(*s2b, eu.scalar);
        if !found table_set(*s2b, eu.scalar, use_block);
        else if cur != NONE && use_block != NONE table_set(*s2b, eu.scalar, dt_find_nca(slp.dt, cur, use_block));
    }
    Pair_Vv :: struct { a: Value_Id; b: Value_Id; }
    checked_su: [..] Pair_Vv; checked_su.allocator = temp;
    has_pair :: (l: [] Pair_Vv, a: Value_Id, b: Value_Id) -> bool { for l if it.a == a && it.b == b return true; return false; }
    is_phi_in_loop :: (u: External_User) -> bool {
        if u.user == NONE || inst_op(u.user) != .PHI return false;
        l := li_loop_for(slp.li, inst_block(u.user));
        return l != NONE && (inst_block(u.user) == inst_block(u.scalar) || l == li_loop_for(slp.li, inst_block(u.scalar)));
    }
    eui := 0;
    while eui < slpx.external_uses.count {
        defer eui += 1;
        eu := slpx.external_uses[eui];
        if eu.user != NONE && table_contains(*slpx.eph_values, eu.user) continue;
        if has_pair(checked_su, eu.scalar, eu.user) || (eu.user != NONE && has_pair(checked_su, eu.scalar, NONE)) continue;
        array_add(*checked_su, .{eu.scalar, eu.user});
        if eu.user != NONE {
            up := inst_block(eu.user);
            if !dt_is_reachable_from_entry(slp.dt, up) || is_eh_pad(block_first_non_phi(up)) || block_ends_unreachable(up) continue;
        }
        if is_vectorized_ty(vtype(eu.scalar)) continue;
        if is_inst(eu.scalar) && inst_op(eu.scalar) == .INSERTVALUE continue;
        if eu.user != NONE && inst_op(eu.user) == .INSERTELEMENT && op(eu.user, 1) == eu.scalar {
            vu := eu.user;
            fty := vtype(vu);
            if type_kind(fty) == .VECTOR {
                if slp_has(used_inserts, vu) continue;
                array_add(*used_inserts, vu);
                ok, insert_idx := slp_element_index(vu);
                if ok {
                    scalar_te := eu.te;
                    vec_id := -1;
                    for * d: shuffled if slp_are_two_insert_from_same_build_vector(vu, d.inserts[0]) { vec_id = it_index; break; }
                    if vec_id < 0 {
                        d: Shuffled_Inserts;
                        d.inserts.allocator = temp; d.vm_keys.allocator = temp; d.vm_masks.allocator = temp;
                        array_add(*d.inserts, vu);
                        array_add(*shuffled, d);
                        array_add(*demanded, NewArray(cast(s64) type_count(fty), bool,, temp));
                        vec_id = shuffled.count - 1;
                        found, bw := slp_min_bw_of(scalar_te);
                        if found {
                            key: [2] u32 = .[cast(u32) scalar_te, cast(u32) type_elem(fty)];
                            dupk := false; for vector_casts if it[0] == key[0] && it[1] == key[1] { dupk = true; break; }
                            if !dupk {
                                array_add(*vector_casts, key);
                                bw_sz := bw.bits;
                                dst_bw := dl_type_size_bits(type_elem(fty));
                                vo: Opcode = ifx dst_bw < bw_sz then .TRUNC else ifx bw.signed then .SEXT else .ZEXT;
                                c := tti_cast_cost(t, vo, fty, slp_widened_type(type_int(cast(u32) bw_sz), type_count(fty)), CCH_NONE, K);
                                cost = cost_add(cost, c);
                            }
                        }
                    } else {
                        if slp_is_first_insert_element(vu, shuffled[vec_id].inserts[0]) shuffled[vec_id].inserts[0] = vu;
                    }
                    d := *shuffled[vec_id];
                    mi := -1;
                    for d.vm_keys if it == scalar_te { mi = it_index; break; }
                    if mi < 0 { array_add(*d.vm_keys, scalar_te); array_add(*d.vm_masks, new_mask(cast(s64) type_count(fty))); mi = d.vm_keys.count - 1; }
                    d.vm_masks[mi][insert_idx] = cast(s32) eu.lane;
                    demanded[vec_id][insert_idx] = true;
                    continue;
                }
            }
        }
        extra: Cost = TCC_FREE;
        sty := vtype(eu.scalar);
        bundle_width := cast(u64) te_vector_factor(eu.te);
        vec_ty := slp_widened_type(sty, bundle_width);
        entry := eu.te;
        bwfound, bw := slp_min_bw_of(entry);
        indices: [] u32;
        if type_kind(vec_ty) == .STRUCT slp_fail("external uses of struct-typed scalars");
        if !(eu.user != NONE && inst_op(eu.user) == .INSERTELEMENT) {
            dup := false;
            for extract_calculated if it.scalar == eu.scalar && it.indices.count == indices.count { dup = true; break; }
            if dup continue;
            array_add(*extract_calculated, .{eu.scalar, indices});
        }
        if bwfound {
            min_ty := type_int(cast(u32) bw.bits);
            ext: Opcode = ifx is_known_non_negative(eu.scalar, slp_simple_query()) then .ZEXT else .SEXT;
            vec_ty = slp_widened_type(min_ty, bundle_width);
            extra = slp_extract_with_extend_cost(ext, sty, vec_ty, eu.lane);
        } else {
            extra = slp_vector_instr_cost(sty, .EXTRACTELEMENT, vec_ty, eu.lane);
        }
        if entry != 0 || te_opcode(entry) == .GEP || te_opcode(entry) == .LOAD {
            if !have_v2e {
                have_v2e = true;
                for p, pi: slpx.external_uses {
                    if is_phi_in_loop(p) continue;
                    if !table_contains(*v2e, p.scalar) table_set(*v2e, p.scalar, pi);
                }
            }
            inst_ := eu.scalar;
            scalar_cost := tti_instruction_cost(t, inst_, K);
            operand_is_scalar :: (v: Value_Id, v2e: *Table(Value_Id, s64)) -> bool {
                if !slp_is_vectorized(v) {
                    if is_inst(v) && inst_op(v) == .EXTRACTELEMENT return !has_one_use(v) || !table_contains(*slp.must_gather, v);
                    return true;
                }
                if type_kind(vtype(v)) == .STRUCT return false;
                return table_contains(v2e, v);
            }
            all_ops_scalar :: (i: Value_Id, v2e: *Table(Value_Id, s64)) -> bool {
                for k: 0..cast(s64) nops(i) - 1 if !operand_is_scalar(op(i, cast(u32) k), v2e) return false;
                return true;
            }
            can_scalar := all_ops_scalar(inst_, *v2e);
            can_scalar_cast := false;
            if is_cast_op(inst_op(inst_)) && !can_scalar {
                o := op(inst_, 0);
                if is_inst(o) && all_ops_scalar(o, *v2e) {
                    op_cost: Cost = ifx slp_is_vectorized(o) && !table_contains(*v2e, o) then tti_instruction_cost(t, o, K) else 0;
                    if cost_add(scalar_cost, op_cost) <= extra {
                        can_scalar = true; can_scalar_cast = true;
                        scalar_cost = cost_add(scalar_cost, op_cost);
                    }
                }
            }
            if can_scalar {
                keep := scalar_cost <= extra;
                is_profitable_phi_user := false;
                if (keep || (cost_sub(scalar_cost, extra) <= TCC_BASIC && slp.entries[0].scalars.count > 2)) &&
                   te_has_state(0) && te_opcode(0) == .PHI && !has_n_uses_or_more(inst_, SLP_USES_LIMIT) {
                    none_bad := true;
                    rb := inst_block(slp.entries[0].s.main);
                    u := ir.v_first_use[inst_];
                    while u != NONE {
                        usr := ir.u_user[u]; u = ir.u_next[u];
                        is_phi_user := is_inst(usr) && inst_op(usr) == .PHI;
                        if (!is_phi_user || inst_block(usr) != rb) && !slp_is_vectorized(usr) { none_bad = false; break; }
                    }
                    if none_bad {
                        cnt := 0; for v: slp.entries[entry].scalars if table_contains(*v2e, v) cnt += 1;
                        is_profitable_phi_user = cnt <= 2;
                    }
                }
                if is_profitable_phi_user {
                    keep = true;
                } else if keep && scalar_cost != TCC_FREE && cost_sub(extra, scalar_cost) <= TCC_BASIC &&
                          (slpx.gathered_loads_first < 0 || entry < slpx.gathered_loads_first) {
                    suc: u32 = 0; for v: slp.entries[entry].scalars if table_contains(*v2e, v) suc += 1;
                    for extracts_count_keys if it == entry { suc -= cast(u32) extracts_count_sets[it_index].count; break; }
                    keep = suc <= 1 || !has_single_bit(cast(u64) suc);
                }
                if keep {
                    set_add_v(*slpx.external_uses_as_original_scalar, eu.scalar);
                    for k: 0..cast(s64) nops(inst_) - 1 {
                        v := op(inst_, cast(u32) k);
                        if type_kind(vtype(v)) == .STRUCT continue;
                        found, ix := table_find(*v2e, v);
                        if found slpx.external_uses[ix].user = NONE;
                    }
                    extra = scalar_cost;
                    if !is_phi_in_loop(eu) {
                        ki := -1; for extracts_count_keys if it == entry { ki = it_index; break; }
                        if ki < 0 { array_add(*extracts_count_keys, entry); array_add(*extracts_count_sets, hr_new_list()); ki = extracts_count_keys.count - 1; }
                        set_add_v(*extracts_count_sets[ki], inst_);
                    }
                    if can_scalar_cast {
                        set_add_v(*scalar_ops_from_casts, op(inst_, 0));
                        iop := op(inst_, 0);
                        if is_inst(iop) for k: 0..cast(s64) nops(iop) - 1 {
                            v := op(iop, cast(u32) k);
                            if type_kind(vtype(v)) == .STRUCT continue;
                            found, ix := table_find(*v2e, v);
                            if found slpx.external_uses[ix].user = NONE;
                        }
                    }
                }
            }
        }
        if !slp_has(slpx.external_uses_as_original_scalar, eu.scalar) {
            if cost_valid(extra) && extra != 0 {
                if eu.user == NONE {
                    extra = scale_cost(extra, entry, eu.scalar, NONE, *scale_keys, *scale_vals);
                } else {
                    _, ebb := table_find(*s2b, eu.scalar);
                    l := ifx ebb != NONE then li_loop_for(slp.li, ebb) else NONE;
                    if l != NONE {
                        a: [1] Value_Id; a[0] = eu.scalar;
                        extra = cost_scale(extra, slp_loop_nest_scale(slp_find_innermost_non_invariant_loop(l, a)));
                    }
                }
            }
        } else {
            extra = scale_cost(extra, entry, eu.scalar, eu.user, *scale_keys, *scale_vals);
        }
        extract_cost = cost_add(extract_cost, extra);
    }
    if all_users_geps && pointers.count {
        common_base := get_underlying_object(pointers[0]);
        all_same := true; for pointers if get_underlying_object(it) != common_base { all_same = false; break; }
        if all_same {
            vec_ty := slp_widened_type(user_sty, cast(u64) slp.entries[0].scalars.count);
            sg := tti_pointers_chain_cost(t, pointers, common_base, PCI_UNIT_STRIDE, user_sty, K);
            vg := tti_pointers_chain_cost(t, pointers, common_base, PCI_UNKNOWN_STRIDE, vec_ty, K);
            extract_cost = cost_add(extract_cost, scale_cost(cost_sub(vg, sg), 0, NONE, NONE, *scale_keys, *scale_vals));
        }
    }
    for v: scalar_ops_from_casts {
        set_add_v(*slpx.external_uses_as_original_scalar, v);
        tes := slp_get_tree_entries(v);
        for ute: tes {
            if te_dead_or_transformed(ute) continue;
            array_add(*slpx.external_uses, .{v, NONE, ute, te_find_lane_for_value(ute, v)});
            break;
        }
    }
    if vectorized_vals.count {
        rfound, rbw := slp_min_bw_of(0);
        if rfound {
            dst_ty := vtype(slp.entries[0].scalars[0]);
            orig_sz := dl_type_size_bits(scalar_type(dst_ty));
            src_sz := ifx slpx.reduction_bit_width == 0 then rbw.bits else slpx.reduction_bit_width;
            if orig_sz != src_sz {
                opc: Opcode = .TRUNC;
                if orig_sz > src_sz opc = ifx rbw.signed then .SEXT else .ZEXT;
                if is_vector_type(dst_ty) slp_fail("REVEC reduction resize");
                cc := tti_cast_cost(t, opc, dst_ty, type_int(cast(u32) src_sz), CCH_NONE, K);
                cost = cost_add(cost, scale_cost(cc, 0, NONE, reduction_root, *scale_keys, *scale_vals));
            }
        }
    }
    if slp_cl.threshold < 0 && n > 1 && is_inst(slp.entries[0].scalars[0]) && inst_op(slp.entries[0].scalars[0]) == .INSERTELEMENT &&
       te_has_state(1) && slp.entries[1].state == TE_VECTORIZE {
        all := true; for v: slp.entries[1].scalars if !slp_has(slpx.external_uses_as_original_scalar, v) { all = false; break; }
        if all return COST_INVALID;
    }
    cost = cost_add(cost, extract_cost);
    // ResizeToVF / EstimateShufflesCost
    for * d: shuffled {
        base := op(d.inserts[0], 0);
        vf: s64 = 0;
        tms: [..] Te_Mask; tms.allocator = temp;
        for d.vm_keys array_add(*tms, .{it, d.vm_masks[it_index]});
        cost = cost_add(cost, slp_estimate_extracts_shuffle_cost(tms, base, *vf, *scale_keys, *scale_vals));
        ins := tti_scalarization_overhead(t, vtype(d.inserts[0]), demanded[it_index], true, false, K);
        cost = cost_sub(cost, ins);
    }
    if slpx.reduction_bit_width != 0 {
        found, bw := slp_min_bw_of(0);
        if found && bw.bits != slpx.reduction_bit_width {
            src_size := bw.bits; dst_size := slpx.reduction_bit_width;
            opc: Opcode = .TRUNC;
            if src_size < dst_size {
                is_arith := true;
                for v: slpx.user_ignore_list {
                    o := inst_op(v);
                    if !(o == .ADD || o == .FADD || o == .MUL || o == .FMUL || o == .AND || o == .OR || o == .XOR) { is_arith = false; break; }
                }
                if is_arith opc = .BITCAST;
                else opc = ifx bw.signed then .SEXT else .ZEXT;
            }
            if opc != .BITCAST {
                evf := cast(u64) te_vector_factor(0);
                src_vt := slp_widened_type(type_int(cast(u32) src_size), evf);
                dst_vt := slp_widened_type(type_int(cast(u32) dst_size), evf);
                cch := slp_get_cast_context_hint(0);
                o0 := te_opcode(0);
                if o0 == .SEXT || o0 == .ZEXT || o0 == .TRUNC cch = slp_get_cast_context_hint(slp_get_operand_entry(0, 0));
                cc := tti_cast_cost(t, opc, dst_vt, src_vt, cch, K);
                cost = cost_add(cost, scale_cost(cc, 0, NONE, reduction_root, *scale_keys, *scale_vals));
            }
        }
    }
    if cost < -slp_cl.threshold {
        spill := slp_get_spill_cost();
        #if DEBUG_SLP print("DBG spill cost %\n", spill);
        cost = cost_add(cost, spill);
    }
    #if DEBUG_SLP print("DBG extract cost % reduction cost % total %\n", cost_to_string(extract_cost), cost_to_string(reduction_cost), cost_to_string(cost));
    return cost;
}
block_ends_unreachable :: (b: Value_Id) -> bool {
    term := block_terminator(b);
    return term != NONE && inst_op(term) == .UNREACHABLE;
}

// performExtractsShuffleAction<const TreeEntry>(ShuffleMask, Base, GetVF, ResizeToVF, EstimateShufflesCost) for
// getTreeCost: returns the added cost
slp_estimate_extracts_shuffle_cost :: (sm: [] Te_Mask, base: Value_Id, vf: *s64, keys: *[..] Scale_Key, vals: *[..] u64) -> Cost {
    cost: Cost = 0;
    // ResizeToVF(TE, Mask, ForSingleMask): (TE, identity found)
    resize_to_vf :: (te: Te_Id, mask: [] s32, for_single: bool, cost: *Cost) -> bool {
        c: Cost = 0;
        mvf := mask.count;
        vec_vf := te_vector_factor(te);
        has_large := false; for mask if it >= cast(s32) mvf { has_large = true; break; }
        if (mvf != vec_vf && has_large) || !svm_is_identity(mask, mvf) {
            mty := vtype(slp.entries[te].s.main);
            if has_large {
                om := new_mask(vec_vf);
                for k: 0..min(mvf, vec_vf)-1 om[k] = mask[k];
                c = slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, slp_widened_type(mty, cast(u64) vec_vf), om);
                cost.* = cost_add(cost.*, c);
                return true;
            }
            if !for_single {
                rm := new_mask(mvf);
                for i: 0..mvf-1 if mask[i] != PME rm[mask[i]] = mask[i];
                if !svm_is_identity(rm, mvf) c = slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, slp_widened_type(mty, cast(u64) vec_vf), rm);
                cost.* = cost_add(cost.*, c);
            }
        }
        return false;
    }
    // EstimateShufflesCost(Mask, TEs)
    estimate :: (mask: [] s32, t1: Te_Id, t2: Te_Id, two: bool, vf: *s64, cost: *Cost, keys: *[..] Scale_Key, vals: *[..] u64) -> Te_Id {
        if !two {
            if vf.* == 0 vf.* = te_vector_factor(t1);
            fty := slp_widened_type(vtype(slp.entries[t1].scalars[0]), cast(u64) vf.*);
            all := true;
            for m, i: mask if !(m == PME || (i < vf.* && cast(s32) i == m)) { all = false; break; }
            if !svm_is_identity(mask, vf.*) && !all {
                c := slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, fty, mask);
                cost.* = cost_add(cost.*, slp_tree_cost_scale(c, t1, keys, vals));
            }
            vf.* = mask.count;
            return t1;
        }
        if vf.* == 0 {
            if t1 != TE_NONE && te_vector_factor(t1) == te_vector_factor(t2) vf.* = te_vector_factor(t1);
            else vf.* = mask.count;
        }
        fty := slp_widened_type(vtype(slp.entries[t2].scalars[0]), cast(u64) vf.*);
        c := slp_shuffle_cost(SK_PERMUTE_TWO_SRC, fty, mask);
        cost.* = cost_add(cost.*, slp_tree_cost_scale(c, t2, keys, vals));
        vf.* = mask.count;
        return t2;
    }
    mask := mask_copy(sm[0].mask);
    vmi := 1;
    prev := TE_NONE;
    use_mask := slp_build_use_mask(mask.count, mask, SLP_USE_MASK_UNDEFS_AS_MASK);
    base_undef := slp_is_undef_vector(base, use_mask);
    if !all_bits(base_undef) {
        r := resize_to_vf(sm[0].te, mask, false, *cost);
        base_poison := slp_is_undef_vector(base, use_mask, true);
        mvf := mask.count;
        for idx: 0..mvf-1 {
            if mask[idx] == PME mask[idx] = ifx base_poison[idx] then PME else cast(s32) idx;
            else mask[idx] = (ifx r then cast(s32) idx else mask[idx]) + cast(s32) mvf;
        }
        prev = estimate(mask, TE_NONE, sm[0].te, true, vf, *cost, keys, vals);
    } else if sm.count == 1 {
        r := resize_to_vf(sm[0].te, mask, true, *cost);
        if r prev = sm[0].te;
        else prev = estimate(mask, sm[0].te, TE_NONE, false, vf, *cost, keys, vals);
    } else {
        v1vf := te_vector_factor(sm[0].te);
        v2vf := te_vector_factor(sm[1].te);
        if v1vf == v2vf {
            sec := sm[1].mask;
            for i: 0..mask.count-1 if sec[i] != PME mask[i] = sec[i] + cast(s32) v1vf;
            prev = estimate(mask, sm[0].te, sm[1].te, true, vf, *cost, keys, vals);
        } else {
            r1 := resize_to_vf(sm[0].te, mask, false, *cost);
            r2 := resize_to_vf(sm[1].te, sm[1].mask, false, *cost);
            sec := sm[1].mask;
            mvf := mask.count;
            for i: 0..mvf-1 {
                if mask[i] != PME { if r1 mask[i] = cast(s32) i; }
                else if sec[i] != PME mask[i] = (ifx r2 then cast(s32) i else sec[i]) + cast(s32) mvf;
            }
            prev = estimate(mask, sm[0].te, sm[1].te, true, vf, *cost, keys, vals);
        }
        vmi = 2;
    }
    while vmi < sm.count {
        r := resize_to_vf(sm[vmi].te, sm[vmi].mask, false, *cost);
        sec := sm[vmi].mask;
        mvf := mask.count;
        for i: 0..mvf-1 {
            if sec[i] != PME mask[i] = (ifx r then cast(s32) i else sec[i]) + cast(s32) mvf;
            else if mask[i] != PME mask[i] = cast(s32) i;
        }
        prev = estimate(mask, prev, sm[vmi].te, true, vf, *cost, keys, vals);
        vmi += 1;
    }
    return cost;
}
// ScaleCost(C, TE) of getTreeCost (Scalar = nullptr, U = nullptr)
slp_tree_cost_scale :: (c: Cost, te: Te_Id, keys: *[..] Scale_Key, vals: *[..] u64) -> Cost {
    if !cost_valid(c) || c == 0 return c;
    for keys.* if it.te == te && it.scalar == NONE && it.u == NONE {
        if vals.*[it_index] == 0 vals.*[it_index] = slp_scale_to_loop_iterations(te);
        return cost_scale(c, vals.*[it_index]);
    }
    s := slp_scale_to_loop_iterations(te);
    array_add(keys, .{te, NONE, NONE}); array_add(vals, s);
    return cost_scale(c, s);
}

// ---------------------------------------------------------------- getSpillCost

slp_get_spill_cost :: () -> Cost {
    if te_is_gather(0) return 0;
    n := slp.entries.count;
    t := slp.tti;
    cost: Cost = 0;
    ops_of := NewArray(n, [..] Te_Id,, temp);
    for * ops_of it.allocator = temp;
    last_of := NewArray(n, Value_Id,, temp);
    for * last_of it.* = NONE;
    last_insts: [..] Value_Id; last_insts.allocator = temp;
    pseudo := NewArray(n, bool,, temp);
    for k: 0..n-1 {
        e := *slp.entries[k];
        c := e.combined_op;
        if c == TE_REDUCED_BITCAST || c == TE_REDUCED_BITCAST_BSWAP || c == TE_REDUCED_BITCAST_LOADS || c == TE_REDUCED_BITCAST_BSWAP_LOADS || c == TE_REDUCED_CMP_BITCAST {
            pseudo[k] = true;
            continue;
        }
        if !te_is_gather(cast(Te_Id) k) {
            li := slp_last_instruction_in_bundle(cast(Te_Id) k);
            last_of[k] = li;
            set_add_v(*last_insts, li);
        }
        if e.user_tree_index.user != TE_NONE array_add(*ops_of[e.user_tree_index.user], cast(Te_Id) k);
    }
    nci_cache: Table(Value_Id, bool); nci_cache.allocator = temp;
    no_call_intrinsic_or_does_not_return :: (i: Value_Id, cache: *Table(Value_Id, bool)) -> bool {
        if !is_call_base(i) return false;
        if call_does_not_return(i) return true;
        if call_iid(i) == NOT_INTRINSIC return false;
        if is_assume_like_intrinsic(i) return true;
        found, r := table_find(cache, i);
        if found return r;
        ica := ica_from_call(i);
        ic := tti_intrinsic_cost(slp.tti, *ica, TCK_RECIP_THROUGHPUT);
        cc := tti_call_instr_cost(slp.tti);
        res := ic < cc;
        table_set(cache, i, res);
        return res;
    }
    Checked :: struct { checked: Value_Id; no_calls: bool; }
    checked_insts: Table(Value_Id, Checked); checked_insts.allocator = temp;
    budget: s64 = 0;
    budget_limit := slp_cl.schedule_budget / n;
    check_same_block :: (first: Value_Id, last_in: Value_Id, budget: *s64, budget_limit: s64, checked_insts: *Table(Value_Id, Checked),
                         last_insts: [] Value_Id, cache: *Table(Value_Id, bool)) -> bool {
        last := last_in;
        found, ck := table_find(checked_insts, last);
        if found {
            if ck.checked == first return ck.no_calls;
            if comes_before(ck.checked, first) return true;
            last = ck.checked;
        } else if last == first || comes_before(last, first) {
            return true;
        }
        stop := inst_prev(first);   // ++First->getIterator().getReverse()
        cur := last;
        in_range: [..] Value_Id; in_range.allocator = temp;
        while cur != stop && budget.* <= budget_limit {
            if is_call_base(cur) && !no_call_intrinsic_or_does_not_return(cur, cache) && !slp_is_vectorized(cur) {
                for li: in_range if !table_contains(checked_insts, li) table_set(checked_insts, li, .{cur, false});
                return false;
            }
            if slp_has(last_insts, cur) array_add(*in_range, cur);
            cur = inst_prev(cur);
            budget.* += 1;
        }
        completed := cur == stop;
        no_calls := completed || budget.* <= budget_limit;
        for li: in_range if !table_contains(checked_insts, li) table_set(checked_insts, li, .{ifx completed then first else cur, no_calls});
        return no_calls;
    }
    add_costs :: (op_te: Te_Id, pseudo: [] bool, cost: *Cost) {
        if pseudo[op_te] return;
        sty := vtype(slp.entries[op_te].scalars[0]);
        found, bw := slp_min_bw_of(op_te);
        if found sty = type_int(cast(u32) bw.bits);
        vec_ty := slp_widened_type(sty, cast(u64) te_vector_factor(op_te));
        scale := slp_scale_to_loop_iterations(op_te);
        keep := cost_scale(tti_cost_of_keeping_live_over_call(slp.tti, vec_ty), scale);
        cost.* = cost_add(cost.*, keep);
    }
    Bb_Pair :: struct { a: Value_Id; b: Value_Id; }
    pp_keys: [..] Bb_Pair; pp_keys.allocator = temp;
    pp_vals: [..] bool; pp_vals.allocator = temp;
    noret_cache: Table(Value_Id, bool); noret_cache.allocator = temp;
    block_has_no_return_call :: (bb: Value_Id, c: *Table(Value_Id, bool)) -> bool {
        found, r := table_find(c, bb);
        if found return r;
        table_set(c, bb, false);
        for i: block_insts(bb) {
            if is_call_base(i) && call_does_not_return(i) && !is_terminator(inst_op(i)) { table_set(c, bb, true); return true; }
        }
        return false;
    }
    loop_call_cache: Table(Loop_Id, bool); loop_call_cache.allocator = temp;
    loop_body_has_call :: (l: Loop_Id, lc: *Table(Loop_Id, bool), nr: *Table(Value_Id, bool), cache: *Table(Value_Id, bool)) -> bool {
        found, r := table_find(lc, l);
        if found return r;
        for bb: li_blocks(slp.li, l) {
            if inst_op(block_terminator(bb)) == .CATCHSWITCH continue;
            if block_has_no_return_call(bb, nr) continue;
            for i: block_insts(bb) {
                if !is_call_base(i) || no_call_intrinsic_or_does_not_return(i, cache) || slp_is_vectorized(i) continue;
                table_set(lc, l, true);
                return true;
            }
        }
        table_set(lc, l, false);
        return false;
    }
    pp_find :: (keys: [] Bb_Pair, a: Value_Id, b: Value_Id) -> s64 { for keys if it.a == a && it.b == b return it_index; return -1; }
    // CheckPredecessors(Root, Pred, OpParent)
    check_predecessors :: (root: Value_Id, pred: Value_Id, op_parent: Value_Id, pp_keys: *[..] Bb_Pair, pp_vals: *[..] bool,
                           lc: *Table(Loop_Id, bool), nr: *Table(Value_Id, bool), cache: *Table(Value_Id, bool),
                           budget: *s64, budget_limit: s64, checked_insts: *Table(Value_Id, Checked), last_insts: [] Value_Id) -> bool {
        ki := pp_find(pp_keys.*, root, op_parent);
        if ki >= 0 return pp_vals.*[ki];
        res := false;
        defer { if pp_find(pp_keys.*, root, op_parent) < 0 { array_add(pp_keys, .{root, op_parent}); array_add(pp_vals, res); } }
        l := li_loop_for(slp.li, root);
        outermost: Value_Id = NONE;
        while l != NONE && !li_contains(slp.li, l, op_parent) { outermost = l; l = li_parent(slp.li, l); }
        if outermost != NONE && loop_body_has_call(outermost, lc, nr, cache) return res;
        worklist: [..] Value_Id; worklist.allocator = temp;
        if pred != NONE array_add(*worklist, pred);
        else block_predecessors(root, *worklist);
        visited: Table(Value_Id, bool); visited.allocator = temp;
        while worklist.count {
            bb := pop(*worklist);
            if bb == op_parent { res = true; return res; }
            if table_contains(*visited, bb) continue;
            table_set(*visited, bb, true);
            if dt_properly_dominates(slp.dt, root, bb) continue;
            if block_has_no_return_call(bb, nr) continue;
            pk := pp_find(pp_keys.*, bb, op_parent);
            if pk >= 0 {
                if pp_vals.*[pk] { res = true; return res; }
                continue;
            }
            bsz := block_size(bb);
            if bsz > slp_cl.schedule_budget continue;
            budget.* += bsz;
            if budget.* > budget_limit return res;
            if inst_op(block_terminator(bb)) != .CATCHSWITCH &&
               !check_same_block(block_first_non_phi_or_dbg_or_alloca(bb), block_terminator(bb), budget, budget_limit, checked_insts, last_insts, cache)
                continue;
            block_predecessors(bb, *worklist);
        }
        return res;
    }
    live: [..] Te_Id; live.allocator = temp;
    array_add(*live, 0);
    while live.count {
        entry := pop(*live);
        ops := ops_of[entry];
        if ops.count == 0 continue;
        if pseudo[entry] {
            x := entry;
            ne := TE_NONE;
            while slp.entries[x].user_tree_index.user != TE_NONE {
                x = slp.entries[x].user_tree_index.user;
                if !pseudo[x] { ne = x; break; }
            }
            if ne == TE_NONE {
                for o: ops if !te_is_gather(o) array_add(*live, o);
                continue;
            }
            entry = ne;
        }
        last_inst := last_of[entry];
        parent := inst_block(last_inst);
        ee := *slp.entries[entry];
        for o: ops {
            if !te_is_gather(o) array_add(*live, o);
            if pseudo[o] continue;
            if ee.state == TE_SPLIT_VECTORIZE || (te_opcode(entry) != .PHI && te_is_gather(o)) || (te_is_gather(o) && slp_all_constant(slp.entries[o].scalars)) continue;
            budget = 0;
            pred: Value_Id = NONE;
            if inst_op(ee.s.main) == .PHI pred = phi_block(ee.s.main, slp.entries[o].user_tree_index.edge);
            op_parent: Value_Id; op_last: Value_Id;
            if te_is_gather(o) {
                op_parent = phi_block(ee.s.main, slp.entries[o].user_tree_index.edge);
                op_last = block_terminator(op_parent);
                for v: slp.entries[o].scalars {
                    if !is_inst(v) continue;
                    if slp_is_vectorized(v) { op_parent = inst_block(v); op_last = v; break; }
                }
            } else {
                op_last = last_of[o];
                op_parent = inst_block(op_last);
            }
            if op_parent == parent {
                if te_opcode(entry) == .PHI {
                    if !check_same_block(last_inst, op_last, *budget, budget_limit, *checked_insts, last_insts, *nci_cache) add_costs(o, pseudo, *cost);
                    continue;
                }
                if !check_same_block(op_last, last_inst, *budget, budget_limit, *checked_insts, last_insts, *nci_cache) add_costs(o, pseudo, *cost);
                continue;
            }
            if te_opcode(entry) != .PHI && !check_same_block(block_first_non_phi_or_dbg_or_alloca(parent), last_inst, *budget, budget_limit, *checked_insts, last_insts, *nci_cache) {
                add_costs(o, pseudo, *cost); continue;
            }
            if !check_same_block(op_last, block_terminator(op_parent), *budget, budget_limit, *checked_insts, last_insts, *nci_cache) {
                add_costs(o, pseudo, *cost); continue;
            }
            if !check_predecessors(parent, pred, op_parent, *pp_keys, *pp_vals, *loop_call_cache, *noret_cache, *nci_cache, *budget, budget_limit, *checked_insts, last_insts) {
                add_costs(o, pseudo, *cost); continue;
            }
        }
    }
    return cost;
}
