// SLPVectorizer: the pass driver (SLPVectorizerPass). Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (SLPVectorizerPass::run / runImpl, collectSeedInstructions, vectorizeStoreChains, vectorizeStores with
// StoreChainContext and RelatedStoreInsts, vectorizeStoreChain, tryToVectorizeList, tryToVectorizeSequence,
// vectorizeChainsInBlock, vectorizeHorReduction, tryToVectorize, vectorizeInsertValueInst /
// vectorizeInsertElementInst / findBuildAggregate, vectorizeCmpInsts / compareCmp, vectorizeNonVectorizableInsts,
// vectorizeGEPIndices, isPoorThroughputOp, getVectorOpCost / getVectorCallCosts, canConvertToFMA), plus
// sortPtrAccesses (llvm/lib/Analysis/LoopAccessAnalysis.cpp).
//
// The comparator/compatibility lambdas of the tryToVectorizeSequence template instances are a `Seq_Kind` switch.

DEBUG_SLP :: false;   // compile-time switch for the `#if DEBUG_SLP` traces
Slp_Pass :: struct {
    // MapVector<Value *, StoreList> Stores / GEPs: keys in insertion order
    store_keys: [..] Value_Id;
    store_lists: [..] [..] Value_Id;
    gep_keys: [..] Value_Id;
    gep_lists: [..] [..] Value_Id;
    // DenseSet<tuple<Value *, Value *, Value *, Value *, unsigned>> Attempted (vectorizeStoreChains)
    attempted: [..] [5] u32;
}
sv: Slp_Pass;

slp_map_list :: (keys: *[..] Value_Id, lists: *[..] [..] Value_Id, k: Value_Id) -> *[..] Value_Id {
    for keys.* if it == k return *lists.*[it_index];
    array_add(keys, k);
    l: [..] Value_Id; l.allocator = temp;
    array_add(lists, l);
    return *lists.*[lists.count - 1];
}
slp_map_find :: (keys: [] Value_Id, lists: [] [..] Value_Id, k: Value_Id) -> s64 {
    for keys if it == k return it_index;
    return -1;
}

// SLPVectorizerPass::run
slp_vectorizer_run :: (f: Value_Id) -> Preserved {
    s := get_scev(f);
    tti := tti_get(f);
    aar := aa_results_for(f);
    li := get_loop_info(f);
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    db := get_demanded_bits(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    changed := slp_run_impl(f, tti, aar, li, dt, ac, db);
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// SLPVectorizerPass::runImpl
slp_run_impl :: (f: Value_Id, tti: *Tti, aar: Aa_Results, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, db: *Demanded_Bits) -> bool {
    if !slp_cl.run return false;
    sv = .{};
    sv.store_keys.allocator = temp; sv.store_lists.allocator = temp;
    sv.gep_keys.allocator = temp; sv.gep_lists.allocator = temp;
    sv.attempted.allocator = temp;
    if tti_number_of_registers(tti, tti_register_class_for_type(tti, true)) == 0 return false;
    if fn_has_fn_attr(f, .NoImplicitFloat) return false;
    slp_init(f, tti, aar, li, dt, ac, db);
    dt_update_dfs_numbers(dt);
    changed := false;
    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    for bb: po {
        if is_eh_pad(block_first_non_phi(bb)) continue;
        term := block_terminator(bb);
        if term != NONE && inst_op(term) == .UNREACHABLE continue;
        slp_clear_reduction_data();
        slp_collect_seed_instructions(bb);
        if sv.store_keys.count changed |= slp_vectorize_store_chains();
        changed |= slp_vectorize_chains_in_block(bb);
        if sv.gep_keys.count changed |= slp_vectorize_gep_indices(bb);
    }
    if changed slp_optimize_gather_sequence();
    slp_finish();
    return changed;
}

// collectSeedInstructions(BB)
slp_collect_seed_instructions :: (bb: Value_Id) {
    array_reset_keeping_memory(*sv.store_keys); array_reset_keeping_memory(*sv.store_lists);
    array_reset_keeping_memory(*sv.gep_keys); array_reset_keeping_memory(*sv.gep_lists);
    for i: block_insts(bb) {
        o := inst_op(i);
        if o == .STORE {
            if !is_simple_load_store(i) continue;
            if !slp_is_valid_element_type(vtype(op(i, 0))) continue;
            l := slp_map_list(*sv.store_keys, *sv.store_lists, get_underlying_object(op(i, 1)));
            array_add(l, i);
        } else if o == .GEP {
            if nops(i) != 2 continue;
            idx := op(i, 1);
            if is_constant_kind(vkind(idx)) continue;
            if !slp_is_valid_element_type(vtype(idx)) continue;
            if is_vector_type(vtype(i)) continue;
            l := slp_map_list(*sv.gep_keys, *sv.gep_lists, op(i, 0));
            array_add(l, i);
        }
    }
}

// ---------------------------------------------------------------- vectorizeStoreChain


// vectorizeStoreChain(Chain, R, Idx, MinVF, Size): (has_value, value, size)
slp_vectorize_store_chain :: (chain: [] Value_Id, idx: s64, min_vf: u64) -> (bool, bool, u32) {
    size: u32 = 0;
    sz := slp_get_vector_element_size(chain[0]);
    vf := cast(u64) chain.count;
    if !has_single_bit(sz) || !slp_has_full_vectors_or_power_of_2(slp.tti, vtype(op(chain[0], 0)), vf) || vf < 2 || vf < min_vf {
        if !slp_cl.non_power_of_2 || (vf < min_vf && vf + 1 != min_vf) return true, false, size;
    }
    val_ops: [..] Value_Id; val_ops.allocator = temp;   // SetVector
    for v: chain {
        x := op(v, 0);
        found := false;
        for val_ops if it == x { found = true; break; }
        if !found array_add(*val_ops, x);
    }
    s := ica_build_instructions_state(val_ops);
    all_inst := true;
    for val_ops if !is_inst(it) { all_inst = false; break; }
    if all_inst && val_ops.count > 1 {
        is_allowed_size := slp_has_full_vectors_or_power_of_2(slp.tti, vtype(val_ops[0]), cast(u64) val_ops.count) ||
                           slp_is_allowed_non_power_of_2_vf(cast(u64) val_ops.count);
        bad := false;
        if !is_allowed_size && is_valid(s) && is_opcode(s) != .LOAD {
            if !slp_is_safe_to_remove(s.main) bad = true;
            else {
                for v: val_ops {
                    if inst_op(v) == .EXTRACTELEMENT continue;
                    if num_uses(v) > chain.count { bad = true; break; }
                    u := ir.v_first_use[v];
                    while u != NONE {
                        usr := ir.u_user[u]; u = ir.u_next[u];
                        in_chain := false;
                        for chain if it == usr { in_chain = true; break; }
                        if !in_chain { bad = true; break; }
                    }
                    if bad break;
                }
            }
        }
        if bad || (val_ops.count > chain.count / 2 && !is_valid(s)) {
            size = ifx !is_allowed_size && is_valid(s) then cast(u32) 1 else 2;
            return true, false, size;
        }
    }
    slp_build_tree(chain);
    #if DEBUG_SLP for slp.entries print("DBG te% state=% n=% op=% user=%\n", it_index, it.state, it.scalars.count, ifx is_valid(it.s) then inst_op(it.s.main) else .NONE_OP, it.user_tree_index);
    if slp_is_tree_tiny_and_not_fully_vectorizable() {
        if slp_is_gathered(chain[0]) || slp_is_not_scheduled(op(chain[0], 0)) return false, false, size;
        size = slp_canonical_graph_size();
        return true, false, size;
    }
    if slp_is_profitable_to_reorder() {
        slp_reorder_top_to_bottom();
        slp_reorder_bottom_to_top();
    }
    slp_transform_nodes();
    slp_compute_minimum_value_sizes();
    tree_cost := slp_calculate_tree_cost_and_trim_non_profitable();
    slp_build_external_uses();
    size = slp_canonical_graph_size();
    if is_valid(s) && is_opcode(s) == .LOAD size = 2;
    cost := slp_get_tree_cost(tree_cost);
    #if DEBUG_SLP print("SLP: Found cost = % for VF=%\n", cost_to_string(cost), vf);
    if cost < -slp_cl.threshold {
        slp_vectorize_tree();
        return true, true, size;
    }
    return true, false, size;
}

// Instruction::isSafeToRemove
slp_is_safe_to_remove :: (i: Value_Id) -> bool {
    return (!is_call_base(i) || !may_have_side_effects(i)) && !is_terminator(inst_op(i)) && !is_eh_pad(i);
}

// ---------------------------------------------------------------- StoreChainContext

SCC_LOCALLY_UNVECTORIZABLE :: 0xFFFF_FFFF;
SCC_MAX_ATTEMPTS :: 4;

Size_Pair :: struct { first: u32; second: u32; }

Store_Chain_Context :: struct {
    min_vf: u32;
    max_vf: u32;
    max_reg_vf: u32;
    probe_vf: u32;
    store_ty: Type_Id;
    candidate_vfs: [..] u32;      // std::queue (front = index 0)
    operands: [..] Value_Id;
    range_sizes: [..] Size_Pair;
    end: u32;
    repeat: u32 = 1;
    repeat_changed: bool;
    stride: u32;
    non_sched_keys: [..] Value_Id;  // SmallDenseMap<Value *, SizePair> NonSchedulable
    non_sched_vals: [..] Size_Pair;
    alive: bool = true;
}

scc_is_not_vectorized :: (c: *Store_Chain_Context, by_idx: [] u32, p: Size_Pair) -> bool { return p.first != SCC_LOCALLY_UNVECTORIZABLE && by_idx[p.first] > 0; }
scc_is_vectorized :: (c: *Store_Chain_Context, by_idx: [] u32, p: Size_Pair) -> bool { return p.first == SCC_LOCALLY_UNVECTORIZABLE || by_idx[p.first] == 0; }
scc_add_operand :: (c: *Store_Chain_Context, store: Value_Id, idx: u32) { array_add(*c.operands, store); array_add(*c.range_sizes, .{idx, 1}); }

scc_mark_range_vectorized :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32, length: u32, first_unvec: *u32, max_slice_end: *u32) {
    for k: start..start+length-1 { by_idx[c.range_sizes[k].first] = 0; c.range_sizes[k].second = 0; }
    if start < first_unvec.* + c.min_vf {
        if start > first_unvec.* for k: first_unvec.*..start-1 { c.range_sizes[k].first = SCC_LOCALLY_UNVECTORIZABLE; c.range_sizes[k].second = 0; }
        first_unvec.* = start + length;
    }
    if start + length > max_slice_end.* - c.min_vf {
        if max_slice_end.* > start + length for k: start+length..max_slice_end.*-1 { c.range_sizes[k].first = SCC_LOCALLY_UNVECTORIZABLE; c.range_sizes[k].second = 0; }
        if max_slice_end.* == c.end c.end = start;
        max_slice_end.* = start;
    }
}

scc_attempted :: (key: [5] u32) -> bool {
    for sv.attempted if it[0] == key[0] && it[1] == key[1] && it[2] == key[2] && it[3] == key[3] && it[4] == key[4] return true;
    array_add(*sv.attempted, key);
    return false;
}

scc_initialize :: (c: *Store_Chain_Context) -> bool {
    key: [5] u32 = .[c.operands[0], op(c.operands[0], 0), c.operands[c.operands.count - 1], op(c.operands[c.operands.count - 1], 0), cast(u32) c.operands.count];
    if scc_attempted(key) return false;
    max_vec_reg_size := slp.max_vec_reg_size;
    elt_size := slp_get_vector_element_size(c.operands[0]);
    max_elts := bit_floor(max_vec_reg_size / elt_size);
    c.max_vf = cast(u32) min(slp_get_maximum_vf(elt_size, .STORE), max_elts);
    store := c.operands[0];
    c.store_ty = vtype(op(store, 0));
    value_ty := c.store_ty;
    if is_inst(op(store, 0)) && inst_op(op(store, 0)) == .TRUNC value_ty = vtype(op(op(store, 0), 0));
    store_scalar_ty := scalar_type(c.store_ty);
    min_vf := bit_ceil(tti_store_minimum_vf(slp.tti, slp_get_min_vf(dl_type_store_size(store_scalar_ty) * 8), store_scalar_ty, scalar_type(value_ty)));
    min_vf /= slp_num_elements(c.store_ty);
    min_vf = max(cast(u64) 2, min_vf);
    if c.stride > 1 min_vf = max(min_vf, cast(u64) slp_cl.min_strided_stores);
    c.min_vf = cast(u32) min_vf;
    if c.max_vf < c.min_vf return false;
    non_pow2_vf: u32 = 0;
    cand_vf := clamp(cast(u32) c.operands.count, c.min_vf, c.max_vf);
    if slp_is_allowed_non_power_of_2_vf(cand_vf) non_pow2_vf = cand_vf;
    c.max_reg_vf = c.max_vf;
    c.max_vf = min(c.max_vf, cast(u32) bit_floor(cast(u64) c.operands.count));
    if c.max_vf < c.min_vf return false;
    vf := max(c.max_vf, non_pow2_vf);
    while vf >= c.min_vf {
        array_add(*c.candidate_vfs, vf);
        vf = cast(u32) divide_ceil(vf, 2);
        if vf == 1 && c.min_vf <= 1 break;   // unreachable: MinVF >= 2
    }
    c.end = cast(u32) c.operands.count;
    c.probe_vf = c.max_vf;
    return true;
}

scc_first_unvec_store :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32 = 0) -> u32 {
    k := start;
    while k < c.range_sizes.count && !scc_is_not_vectorized(c, by_idx, c.range_sizes[k]) k += 1;
    return k;
}
scc_first_vec_store_after :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32) -> u32 {
    k := start;
    while k < c.range_sizes.count && !scc_is_vectorized(c, by_idx, c.range_sizes[k]) k += 1;
    return k;
}
scc_all_vectorized :: (c: *Store_Chain_Context, by_idx: [] u32) -> bool {
    for c.range_sizes if !scc_is_vectorized(c, by_idx, it) return false;
    return true;
}
scc_is_first_size_same_range :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32, length: u32, tree_size: u32) -> bool {
    for k: start..start+length-1 if tree_size != by_idx[c.range_sizes[k].first] return false;
    return true;
}
scc_all_of_range_profitable :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32, length: u32, tree_size: u32) -> bool {
    for k: start..start+length-1 if !(tree_size >= by_idx[c.range_sizes[k].first]) return false;
    return true;
}
scc_update_range_sizes_from_cache :: (c: *Store_Chain_Context, by_idx: [] u32) {
    for p: c.range_sizes if p.first != SCC_LOCALLY_UNVECTORIZABLE && by_idx[p.first] != 0 by_idx[p.first] = max(p.second, by_idx[p.first]);
}
scc_update_cached_range_sizes :: (c: *Store_Chain_Context, start: u32, length: u32, tree_size: u32) {
    for k: start..start+length-1 c.range_sizes[k].second = max(c.range_sizes[k].second, tree_size);
}
scc_update_candidate_vfs :: (c: *Store_Chain_Context, by_idx: [] u32) -> bool {
    STORES_LIMIT :: 64;
    max_total := min(cast(u32) c.operands.count, c.end - scc_first_unvec_store(c, by_idx));
    vf := cast(u32) bit_ceil(c.probe_vf) * 2;
    if vf > max_total || vf >= STORES_LIMIT return false;
    limit := cast(u32) slp_floor_full_vector_number_of_elements(slp.tti, c.store_ty, max_total);
    if bit_floor(limit) == vf && limit != vf array_add(*c.candidate_vfs, limit);
    array_add(*c.candidate_vfs, vf);
    c.probe_vf = c.candidate_vfs[0];
    c.repeat += 1;
    c.repeat_changed = false;
    return true;
}
scc_increment_vf :: (c: *Store_Chain_Context) { if c.candidate_vfs.count array_ordered_remove_by_index(*c.candidate_vfs, 0); }
scc_current_vf :: (c: *Store_Chain_Context) -> (bool, u32) {
    if c.candidate_vfs.count == 0 return false, 0;
    return true, c.candidate_vfs[0];
}
scc_check_tree_sizes :: (c: *Store_Chain_Context, by_idx: [] u32, start: u32, vf: u32) -> bool {
    num: u64 = 0;
    sum: u64 = 0;
    tsz_of :: (p: Size_Pair, by_idx: [] u32) -> u64 { return ifx p.first == SCC_LOCALLY_UNVECTORIZABLE then cast(u64) 0 else by_idx[p.first]; }
    for k: start..start+vf-1 {
        sz := tsz_of(c.range_sizes[k], by_idx);
        if sz == 1 continue;
        num += 1;
        sum += sz;
    }
    if num == 0 return true;
    mean := sum / num;
    if mean == 0 return true;
    dev: u64 = 0;
    for k: start..start+vf-1 {
        p := tsz_of(c.range_sizes[k], by_idx);
        if p == 1 continue;
        // (P - Mean) is computed in unsigned (u32 promoted by uint64_t Mean -> u64)
        d := p - mean;
        dev += d * d;
    }
    dev /= num;
    return dev * 96 / (mean * mean) == 0;
}

scc_vectorize_one_vf :: (c: *Store_Chain_Context, by_idx: [] u32, vf: u32, vectorized_stores: *Table(Value_Id, bool), changed: *bool) -> bool {
    any_profitable := false;
    first_unvec := scc_first_unvec_store(c, by_idx);
    while first_unvec < c.end {
        first_vec := scc_first_vec_store_after(c, by_idx, first_unvec);
        max_slice_end := ifx first_vec >= c.end then c.end else first_vec;
        slice_start := first_unvec;
        while slice_start + vf <= max_slice_end {
            if !scc_check_tree_sizes(c, by_idx, slice_start, vf) { slice_start += 1; continue; }
            slice := array_view(c.operands, slice_start, vf);
            if c.non_sched_keys.count {
                ns: Size_Pair;
                for c.non_sched_keys if it == slice[0] { ns = c.non_sched_vals[it_index]; break; }
                if ns.first > 0 && ns.second <= vf { slice_start += ns.first; continue; }
            }
            has, res, tree_size := slp_vectorize_store_chain(slice, slice_start, c.min_vf);
            if !has {
                found := false;
                for c.non_sched_keys if it == slice[0] { c.non_sched_vals[it_index].second = vf; found = true; break; }
                if !found { array_add(*c.non_sched_keys, slice[0]); array_add(*c.non_sched_vals, .{vf, vf}); }
            } else if res {
                for slice table_set(vectorized_stores, it, true);
                any_profitable = true; c.repeat_changed = true; changed.* = true;
                scc_mark_range_vectorized(c, by_idx, slice_start, vf, *first_unvec, *max_slice_end);
                slice_start += vf;
                continue;
            }
            if vf > 2 && has && !scc_all_of_range_profitable(c, by_idx, slice_start, vf, tree_size) { slice_start += vf; continue; }
            if vf > c.max_reg_vf && tree_size > 1 && scc_is_first_size_same_range(c, by_idx, slice_start, vf, tree_size) {
                slice_start += vf;
                while slice_start != max_slice_end && scc_is_first_size_same_range(c, by_idx, slice_start, 1, tree_size) slice_start += 1;
                continue;
            }
            if tree_size > 1 scc_update_cached_range_sizes(c, slice_start, vf, tree_size);
            slice_start += 1;
            any_profitable = true;
        }
        if first_unvec >= c.end break;
        if max_slice_end - first_unvec < vf && max_slice_end - first_unvec >= c.min_vf any_profitable = true;
        first_unvec = scc_first_unvec_store(c, by_idx, max_slice_end);
    }
    if !any_profitable && vf >= c.max_reg_vf && has_single_bit(vf) array_reset_keeping_memory(*c.candidate_vfs);
    if vf == c.max_reg_vf scc_update_range_sizes_from_cache(c, by_idx);
    scc_increment_vf(c);
    has_vf := scc_current_vf(c);
    if !has_vf {
        if scc_all_vectorized(c, by_idx) return false;
        if c.repeat >= SCC_MAX_ATTEMPTS || (c.repeat > 1 && (c.repeat_changed || !any_profitable)) return false;
        if !scc_update_candidate_vfs(c, by_idx) return false;
        if vf != c.max_reg_vf scc_update_range_sizes_from_cache(c, by_idx);
    }
    return true;
}

// RelatedStoreInsts: base index + std::map<int64_t, unsigned> (kept sorted by distance)
Related_Stores :: struct {
    base: u32;
    dists: [..] s64;
    idxs: [..] u32;
}
rs_reset :: (r: *Related_Stores, base: u32) {
    r.base = base;
    array_reset_keeping_memory(*r.dists); array_reset_keeping_memory(*r.idxs);
    rs_insert_or_lookup(r, base, 0);
}
// insertOrLookup: (found existing, its index)
rs_insert_or_lookup :: (r: *Related_Stores, idx: u32, dist: s64) -> (bool, u32) {
    pos := 0;
    while pos < r.dists.count && r.dists[pos] < dist pos += 1;
    if pos < r.dists.count && r.dists[pos] == dist return true, r.idxs[pos];
    array_insert_at(*r.dists, dist, pos);
    array_insert_at(*r.idxs, idx, pos);
    return false, 0;
}
rs_rebase :: (r: *Related_Stores, min_safe: u32, new_base: u32, dist_from_cur: s64) {
    pd := array_copy(r.dists,, temp);
    pi := array_copy(r.idxs,, temp);
    rs_reset(r, new_base);
    for d, k: pd if pi[k] >= min_safe rs_insert_or_lookup(r, pi[k], d - dist_from_cur);
}

// vectorizeStores(Stores, R, Visited, AllowMaskedStores)
slp_vectorize_stores :: (stores: [] Value_Id, allow_masked_stores: bool) -> bool {
    vectorized_stores: Table(Value_Id, bool); vectorized_stores.allocator = temp;
    changed := false;
    all_contexts: [..] *Store_Chain_Context; all_contexts.allocator = temp;
    by_idx := NewArray(stores.count, u32,, temp);
    for * by_idx it.* = 1;

    Partial_Chain_Status :: struct { added: bool; idx: u32; first_store: Value_Id; stride: u32; }
    extend_contexts :: (seq: *Related_Stores, all_contexts: *[..] *Store_Chain_Context, stores: [] Value_Id, by_idx: [] u32) {
        max_stride := cast(u32) ifx slp_cl.strided_stores then slp_cl.max_stride else 1;
        chains := NewArray(max_stride + 1, [..] Partial_Chain_Status,, temp);
        for * chains it.allocator = temp;
        n := cast(s64) chains.count;
        key_of :: (q: s64, n: s64) -> s64 { r := q % n; if r < 0 r += n; return r; }
        last_dist: s64;
        for k: 0..seq.dists.count-1 {
            dist := seq.dists[k]; inst_idx := seq.idxs[k];
            if k > 0 {
                d := last_dist;
                while d < min(dist, last_dist + n) { array_reset_keeping_memory(*chains[key_of(d, n)]); d += 1; }
            }
            last_dist = dist;
            found_strides := NewArray(slp_cl.max_stride + 1, bool,, temp);
            cur := *chains[key_of(dist, n)];
            j := 0;
            while j < cur.count {   // the vector may grow when Stride is a multiple of the chain count
                status := *cur.*[j];
                if status.added {
                    scc_add_operand(all_contexts.*[status.idx], stores[inst_idx], inst_idx);
                } else {
                    c := New(Store_Chain_Context,, temp);
                    c.candidate_vfs.allocator = temp; c.operands.allocator = temp; c.range_sizes.allocator = temp;
                    c.non_sched_keys.allocator = temp; c.non_sched_vals.allocator = temp;
                    array_add(*c.operands, status.first_store, stores[inst_idx]);
                    array_add(*c.range_sizes, .{status.idx, 1}, .{inst_idx, 1});
                    c.stride = status.stride;
                    array_add(all_contexts, c);
                    status.idx = cast(u32) (all_contexts.count - 1);
                }
                key := key_of(status.stride + dist, n);
                st := status.*;
                array_add(*chains[key], .{true, st.idx, NONE, st.stride});
                found_strides[st.stride] = true;
                cur = *chains[key_of(dist, n)];
                j += 1;
            }
            array_reset_keeping_memory(*chains[key_of(dist, n)]);
            for stride: 1..max_stride {
                if found_strides[stride] continue;
                key := key_of(dist + stride, n);
                array_add(*chains[key], .{false, inst_idx, stores[inst_idx], stride});
            }
        }
    }

    sorted: [..] Related_Stores; sorted.allocator = temp;
    new_rs :: (idx: u32) -> Related_Stores {
        r: Related_Stores;
        r.dists.allocator = temp; r.idxs.allocator = temp;
        rs_reset(*r, idx);
        return r;
    }
    prev_val_ty: Type_Id = NONE;
    for si, i: stores {
        if slp_is_deleted(si) continue;
        if prev_val_ty == NONE prev_val_ty = vtype(op(si, 0));
        if prev_val_ty != vtype(op(si, 0)) {
            for * sorted extend_contexts(it, *all_contexts, stores, by_idx);
            array_reset_keeping_memory(*sorted);
            prev_val_ty = vtype(op(si, 0));
        }
        // FillStoresSet
        found := -1;
        dist: s64;
        for * seq: sorted {
            base := stores[seq.base];
            ok, d := get_pointers_diff(vtype(op(base, 0)), op(base, 1), vtype(op(si, 0)), op(si, 1), true);
            if ok { found = it_index; dist = d; break; }
        }
        if found < 0 { array_add(*sorted, new_rs(cast(u32) i)); continue; }
        had, prev := rs_insert_or_lookup(*sorted[found], cast(u32) i, dist);
        if had {
            extend_contexts(*sorted[found], *all_contexts, stores, by_idx);
            rs_rebase(*sorted[found], prev + 1, cast(u32) i, dist);
        }
    }
    for * sorted extend_contexts(it, *all_contexts, stores, by_idx);

    // ActuallyVectorizeContexts
    global_max_vf: u32 = 0;
    for c: all_contexts {
        if scc_initialize(c) global_max_vf = max(global_max_vf, c.max_vf);
        else c.alive = false;
    }
    // stable_sort: alive contexts first, by stride
    {
        n := all_contexts.count;
        for i: 1..n-1 {
            x := all_contexts[i];
            j := i;
            less :: (a: *Store_Chain_Context, b: *Store_Chain_Context) -> bool { return a.alive && (!b.alive || a.stride < b.stride); }
            while j > 0 && less(x, all_contexts[j - 1]) { all_contexts[j] = all_contexts[j - 1]; j -= 1; }
            all_contexts[j] = x;
        }
    }
    limit_vf := global_max_vf;
    while limit_vf > 0 {
        for c: all_contexts {
            if !c.alive break;
            while true {
                has, vf := scc_current_vf(c);
                if !has || vf < limit_vf break;
                if !scc_vectorize_one_vf(c, by_idx, vf, *vectorized_stores, *changed) { c.alive = false; break; }
            }
        }
        limit_vf = cast(u32) bit_ceil(limit_vf) / 2;
    }

    if !allow_masked_stores return changed;
    remaining: [..] Value_Id; remaining.allocator = temp;
    for si: stores if !slp_is_deleted(si) && !table_contains(*vectorized_stores, si) array_add(*remaining, si);
    if remaining.count < 2 return changed;
    val_ty := slp_get_value_type(remaining[0]);
    for remaining if vtype(op(it, 0)) != val_ty return changed;
    ptr_ops: [..] Value_Id; ptr_ops.allocator = temp;
    for remaining array_add(*ptr_ops, op(it, 1));
    ok, order := sort_ptr_accesses(ptr_ops, val_ty);
    if !ok return changed;
    sorted_stores := NewArray(remaining.count, Value_Id,, temp);
    for k: 0..remaining.count-1 sorted_stores[k] = remaining[ifx order.count == 0 then k else order[k]];
    key: [5] u32 = .[sorted_stores[0], op(sorted_stores[0], 0), sorted_stores[sorted_stores.count - 1], op(sorted_stores[sorted_stores.count - 1], 0), cast(u32) sorted_stores.count];
    if scc_attempted(key) return changed;
    has, res := slp_vectorize_store_chain(sorted_stores, 0, 2);
    if has && res {
        for sorted_stores table_set(*vectorized_stores, it, true);
        changed = true;
    }
    return changed;
}

// sortPtrAccesses(VL, ElemTy, DL, SE, SortedIndices): (ok, indices; empty when consecutive)
sort_ptr_accesses :: (vl: [] Value_Id, elem_ty: Type_Id) -> (bool, [..] u32) {
    order: [..] u32; order.allocator = temp;
    ptr0 := vl[0];
    offs: [..] s64; offs.allocator = temp;
    idxs: [..] u32; idxs.allocator = temp;
    array_add(*offs, 0); array_add(*idxs, 0);
    consecutive := true;
    for k: 1..vl.count-1 {
        ok, diff := get_pointers_diff(elem_ty, ptr0, elem_ty, vl[k], true);
        if !ok return false, order;
        pos := 0;
        while pos < offs.count && offs[pos] < diff pos += 1;
        if pos < offs.count && offs[pos] == diff return false, order;
        array_insert_at(*offs, diff, pos);
        array_insert_at(*idxs, cast(u32) k, pos);
        consecutive &= pos == offs.count - 1;
    }
    if !consecutive for idxs array_add(*order, it);
    return true, order;
}

// ---------------------------------------------------------------- tryToVectorizeSequence

Seq_Kind :: enum u8 { STORES; CMPS; PHIS; OPERANDS; SEEDS; }

// The state of the comparator / compatibility / helper lambdas of one tryToVectorizeSequence instance
Seq_Ctx :: struct {
    kind: Seq_Kind;
    same_parent := true;           // vectorizeStoreChains: SameParent
    allow_masked_stores: bool;
    phi_keys: [..] Value_Id;       // PHIToOpcodes
    phi_ops: [..] [..] Value_Id;
    op_keys: Table(Value_Id, Operand_Group_Key);   // OpKeys / SeedKeys
}
seq_ctx: *Seq_Ctx;   // read by the comparator passed to gnu_stable_sort

seq_compare :: (a: Value_Id, b: Value_Id) -> bool {
    c := seq_ctx;
    if #complete c.kind == {
        case .STORES; return slp_store_sorter(a, b);
        case .CMPS; if a == b return false; return slp_compare_cmp(a, b, false);
        case .PHIS; return slp_phi_compare(c, a, b);
        case .OPERANDS; return slp_operand_sorter(c, a, b);
        case .SEEDS; return slp_seed_sorter(c, a, b);
    }
    return false;
}
seq_are_compatible :: (c: *Seq_Ctx, vl: [] Value_Id, v: Value_Id) -> bool {
    if #complete c.kind == {
        case .STORES; return slp_are_compatible_stores(c, vl, v);
        case .CMPS;
            if vl.count == 0 || vl[vl.count - 1] == v return true;
            return slp_compare_cmp(v, vl[vl.count - 1], true);
        case .PHIS; return slp_are_compatible_phis(c, vl, v);
        case .OPERANDS;
            if vl.count == 0 || vl[vl.count - 1] == v return true;
            kb := table_find_pointer(*c.op_keys, vl[vl.count - 1]); k := table_find_pointer(*c.op_keys, v);
            if !ogk_equal(kb.*, k.*) return false;
            return vtype(vl[vl.count - 1]) == vtype(v) && inst_op(vl[vl.count - 1]) == inst_op(v);
        case .SEEDS;
            if vl.count == 0 || vl[vl.count - 1] == v return true;
            return vtype(vl[vl.count - 1]) == vtype(v) && ogk_equal(table_find_pointer(*c.op_keys, vl[vl.count - 1]).*, table_find_pointer(*c.op_keys, v).*);
    }
    return false;
}
seq_try_helper :: (c: *Seq_Ctx, cands: [] Value_Id, max_vf_only: bool) -> bool {
    if #complete c.kind == {
        case .STORES; return slp_vectorize_stores(cands, c.allow_masked_stores);
        case .CMPS;
            for v: cands {
                u := ir.v_first_use[v];
                while u != NONE {
                    usr := ir.u_user[u]; u = ir.u_next[u];
                    if is_inst(usr) && inst_op(usr) == .SELECT && inst_block(usr) != inst_block(v) return false;
                }
            }
            return slp_try_to_vectorize_list(cands, max_vf_only);
        case .PHIS; return slp_try_to_vectorize_list(cands, max_vf_only);
        case .OPERANDS; return slp_try_to_vectorize_list(cands, max_vf_only);
        case .SEEDS; return slp_try_to_vectorize_list(cands, max_vf_only, true);
    }
    return false;
}

// tryToVectorizeSequence<T>(Incoming, Comparator, AreCompatible, TryToVectorizeHelper, MaxVFOnly, R)
slp_try_to_vectorize_sequence :: (c: *Seq_Ctx, incoming: [] Value_Id, max_vf_only: bool) -> bool {
    changed := false;
    saved := seq_ctx;
    seq_ctx = c;
    gnu_stable_sort(incoming, seq_compare);
    seq_ctx = saved;
    candidates: [..] Value_Id; candidates.allocator = temp;
    vl: [..] Value_Id; vl.allocator = temp;
    e := incoming.count;
    inc := 0;
    is_live :: (v: Value_Id) -> bool { return is_inst(v) && !slp_is_deleted(v); }
    while inc != e {
        array_reset_keeping_memory(*vl);
        i := incoming[inc];
        if !is_inst(i) || slp_is_deleted(i) || !slp_is_valid_element_type(slp_get_value_type(i)) { inc += 1; continue; }
        same := inc;
        while same != e && (!is_inst(incoming[same]) || slp_is_deleted(incoming[same]) || seq_are_compatible(c, vl, incoming[same])) {
            x := incoming[same];
            same += 1;
            if is_live(x) array_add(*vl, x);
        }
        num_elts := vl.count;
        if num_elts > 1 && seq_try_helper(c, vl, max_vf_only) {
            changed = true;
            prev := array_copy(vl,, temp);
            array_reset_keeping_memory(*candidates);
            for prev if is_live(it) array_add(*candidates, it);
        } else {
            elt_size := slp_get_vector_element_size(incoming[inc]);
            min_elems := max(cast(u64) 2, slp.max_vec_reg_size / elt_size);
            if cast(u64) num_elts < min_elems && (candidates.count == 0 || vtype(candidates[0]) == vtype(incoming[inc])) {
                for vl if is_live(it) array_add(*candidates, it);
            }
        }
        if candidates.count > 1 && (same == e || vtype(incoming[same]) != vtype(incoming[inc])) {
            if seq_try_helper(c, candidates, false) {
                changed = true;
            } else if max_vf_only {
                vl2: [..] Value_Id; vl2.allocator = temp;
                it2 := 0;
                end2 := candidates.count;
                while it2 != end2 {
                    array_reset_keeping_memory(*vl2);
                    x := candidates[it2];
                    if !is_live(x) { it2 += 1; continue; }
                    s2 := it2;
                    // AreCompatible(*SameTypeIt, *It): a one-element "VL" holding the candidate
                    while s2 != end2 && (!is_inst(candidates[s2]) || slp_is_deleted(candidates[s2]) || seq_are_compatible(c, .[candidates[s2]], candidates[it2])) {
                        y := candidates[s2];
                        s2 += 1;
                        if is_live(y) array_add(*vl2, y);
                    }
                    if vl2.count > 1 && seq_try_helper(c, vl2, false) changed = true;
                    it2 = s2;
                }
            }
            array_reset_keeping_memory(*candidates);
        }
        inc = same;
    }
    return changed;
}

// ---------------------------------------------------------------- vectorizeStoreChains

slp_store_sorter :: (v: Value_Id, v2: Value_Id) -> bool {
    a := op(v, 0); b := op(v2, 0);
    ta := slp_type_id(vtype(a)); tb := slp_type_id(vtype(b));
    if ta < tb return true;
    if ta > tb return false;
    pa := slp_type_id(vtype(op(v, 1))); pb := slp_type_id(vtype(op(v2, 1)));
    if pa < pb return true;
    if pa > pb return false;
    sa := type_scalar_size_bits(vtype(a)); sb := type_scalar_size_bits(vtype(b));
    if sa < sb return true;
    if sa > sb return false;
    i1 := is_inst(a); i2 := is_inst(b);
    if i1 && i2 {
        n1 := dt_dfs_in(slp.dt, inst_block(a)); n2 := dt_dfs_in(slp.dt, inst_block(b));
        if inst_block(a) != inst_block(b) return n1 < n2;
        return inst_op(a) < inst_op(b);
    }
    if i1 && !i2 return true;
    if !i1 && i2 return false;
    return slp_value_id(a) < slp_value_id(b);
}

slp_are_compatible_stores :: (c: *Seq_Ctx, vl: [] Value_Id, v1: Value_Id) -> bool {
    if vl.count == 0 { c.same_parent = true; return true; }
    v2 := vl[vl.count - 1];
    if v1 == v2 return true;
    a := op(v1, 0); b := op(v2, 0);
    if vtype(a) != vtype(b) return false;
    if vtype(op(v1, 1)) != vtype(op(v2, 1)) return false;
    if pm_undef_value(a) || pm_undef_value(b) return true;
    if is_constant_kind(vkind(a)) && is_constant_kind(vkind(b)) return true;
    i1 := is_inst(a); i2 := is_inst(b);
    if i1 || i2 {
        if i1 && !i2 return false;
        c.same_parent &= i1 && i2 && inst_block(a) == inst_block(b);
        new_vl: [..] Value_Id; new_vl.allocator = temp;
        for vl array_add(*new_vl, op(it, 0));
        array_add(*new_vl, a);
        s := ica_build_instructions_state(new_vl, true, !c.same_parent);
        if is_valid(s) return true;
        if !c.same_parent return false;
    }
    return slp_value_id(a) == slp_value_id(b);
}

slp_vectorize_store_chains :: () -> bool {
    changed := false;
    has_consecutive_or_same_address :: (sis: [] Value_Id) -> bool {
        if sis.count < 2 return false;
        ty := vtype(op(sis[0], 0));
        base := op(sis[0], 1);
        offs: [..] s64; offs.allocator = temp;
        for si: sis {
            ok, off := get_pointers_diff(ty, base, ty, op(si, 1));
            if ok array_add(*offs, off);
        }
        quick_sort(offs, (a: s64, b: s64) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
        for k: 1..offs.count-1 if offs[k] - offs[k - 1] == 1 || offs[k] == offs[k - 1] return true;
        return false;
    }
    for list: sv.store_lists {
        if list.count < 2 continue;
        if !slp_is_valid_element_type(vtype(op(list[0], 0))) continue;
        ctx: Seq_Ctx;
        ctx.kind = .STORES;
        ctx.allow_masked_stores = slp_cl.masked_stores && !has_consecutive_or_same_address(list);
        reversed := NewArray(list.count, Value_Id,, temp);
        for k: 0..list.count-1 reversed[k] = list[list.count - 1 - k];
        changed |= slp_try_to_vectorize_sequence(*ctx, reversed, false);
    }
    return changed;
}

// ---------------------------------------------------------------- tryToVectorizeList

slp_try_to_vectorize_list :: (vl: [] Value_Id, max_vf_only := false, limit_to_register_vf := false) -> bool {
    if vl.count < 2 return false;
    #if DEBUG_SLP print("SLP: Trying to vectorize a list of length = %.\n", vl.count);
    s := slp_get_same_opcode(vl);
    if !is_valid(s) return false;
    i0 := s.main;
    for v: vl {
        if is_inst(v) && (inst_op(v) == .INSERTELEMENT || inst_op(v) == .INSERTVALUE) continue;
        if !slp_is_valid_element_type(vtype(v)) return false;
    }
    sty := slp_get_value_type(vl[0], true);
    sz := slp_get_vector_element_size(i0);
    min_vf := slp_get_min_vf(sz);
    max_vf := max(slp_floor_full_vector_number_of_elements(slp.tti, sty, cast(u64) vl.count), min_vf);
    max_vf = min(slp_get_maximum_vf(sz, is_opcode(s)), max_vf);
    if limit_to_register_vf && sz != 0 max_vf = min(max_vf, max(min_vf, slp.max_vec_reg_size / sz));
    if max_vf < 2 return false;
    #if DEBUG_SLP print("DBG try list n=% sz=% minvf=% maxvf=% maxvfonly=% limit=%\n", vl.count, sz, min_vf, max_vf, max_vf_only, limit_to_register_vf);
    changed := false;
    next_inst: u64 = 0; max_inst := cast(u64) vl.count;
    vf := max_vf;
    while next_inst + 1 < max_inst && vf >= min_vf {
        defer vf = slp_floor_full_vector_number_of_elements(slp.tti, vtype(i0), vf - 1);
        vec_ty := slp_widened_type(sty, vf);
        if slp_number_of_parts(slp.tti, vec_ty, sty) == vf continue;
        i := next_inst;
        while i < max_inst {
            defer i += 1;
            actual_vf := min(max_inst - i, vf);
            if !slp_has_full_vectors_or_power_of_2(slp.tti, sty, actual_vf) continue;
            if max_vf_only && actual_vf < max_vf break;
            if (vf > min_vf && actual_vf < vf) || (vf == min_vf && actual_vf < 2) break;
            ops := NewArray(cast(s64) actual_vf, Value_Id,, temp);
            idx: u64 = 0;
            for k: cast(s64) i..vl.count-1 {
                v := vl[k];
                if !is_inst(v) || !slp_is_deleted(v) {
                    ops[idx] = v;
                    idx += 1;
                    if idx == actual_vf break;
                }
            }
            if idx != actual_vf break;
            #if DEBUG_SLP print("SLP: Analyzing % operations \n", actual_vf);
            slp_build_tree(ops);
            #if DEBUG_SLP for slp.entries print("DBG te% state=% n=% op=% user=% reuse=%\n", it_index, it.state, it.scalars.count, ifx is_valid(it.s) then inst_op(it.s.main) else .NONE_OP, it.user_tree_index, it.reuse_shuffle_indices.count);
            if slp_is_tree_tiny_and_not_fully_vectorizable() continue;
            if slp_is_profitable_to_reorder() {
                slp_reorder_top_to_bottom();
                f0 := ops[0];
                slp_reorder_bottom_to_top(!(is_inst(f0) && (inst_op(f0) == .INSERTELEMENT || inst_op(f0) == .INSERTVALUE)));
            }
            slp_transform_nodes();
            slp_compute_minimum_value_sizes();
            tree_cost := slp_calculate_tree_cost_and_trim_non_profitable();
            slp_build_external_uses();
            cost := slp_get_tree_cost(tree_cost);
            #if DEBUG_SLP print("SLP: Found cost = % for VF=%\n", cost_to_string(cost), actual_vf);
            if cost < -slp_cl.threshold {
                slp_vectorize_tree();
                i += vf - 1;
                next_inst = i + 1;
                changed = true;
            }
        }
    }
    return changed;
}

// ---------------------------------------------------------------- roots, reductions

// matchRdxBop(I, V0, V1)
slp_match_rdx_bop :: (i: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(i) return false, NONE, NONE;
    if is_binary_op(inst_op(i)) return true, op(i, 0), op(i, 1);
    id := call_iid(i);
    if id == IID_MAXNUM || id == IID_MINNUM || id == IID_MAXIMUM || id == IID_MINIMUM || id == IID_SMAX ||
       id == IID_SMIN || id == IID_UMAX || id == IID_UMIN return true, op(i, 0), op(i, 1);
    return false, NONE, NONE;
}
// isReductionCandidate(I)
slp_is_reduction_candidate :: (i: Value_Id) -> bool {
    if is_inst(i) && inst_op(i) == .SELECT return true;
    ok := slp_match_rdx_bop(i);
    return ok;
}
// getReductionInstr(DT, P, ParentBB, LI)
slp_get_reduction_instr :: (p: Value_Id, parent_bb: Value_Id) -> Value_Id {
    dominated :: (p: Value_Id, r: Value_Id) -> bool { return is_inst(r) && dt_dominates(slp.dt, inst_block(p), inst_block(r)); }
    rdx: Value_Id = NONE;
    if phi_block(p, 0) == parent_bb rdx = phi_value(p, 0);
    else if phi_block(p, 1) == parent_bb rdx = phi_value(p, 1);
    if rdx != NONE && !is_inst(rdx) rdx = NONE;
    if rdx != NONE && dominated(p, rdx) return rdx;
    l := li_loop_for(slp.li, parent_bb);
    if l == NONE return NONE;
    latch := li_loop_latch(slp.li, l);
    if latch == NONE return NONE;
    rdx = NONE;
    if phi_block(p, 0) == latch rdx = phi_value(p, 0);
    else if phi_block(p, 1) == latch rdx = phi_value(p, 1);
    if rdx != NONE && !is_inst(rdx) rdx = NONE;
    if rdx != NONE && dominated(p, rdx) return rdx;
    return NONE;
}
// tryGetSecondaryReductionRoot(Phi, Root)
slp_try_get_secondary_reduction_root :: (phi: Value_Id, root: Value_Id) -> Value_Id {
    fi := hr_first_operand_index(root);
    lhs := op(root, fi); rhs := op(root, fi + 1);
    if lhs == phi return ifx is_inst(rhs) then rhs else NONE;
    if rhs == phi return ifx is_inst(lhs) then lhs else NONE;
    return NONE;
}
// getNonPhiOperand(I, Phi)
slp_get_non_phi_operand :: (i: Value_Id, phi: Value_Id) -> Value_Id {
    ok, op0, op1 := slp_match_rdx_bop(i);
    if !ok return NONE;
    r := ifx op0 == phi then op1 else op0;
    return ifx is_inst(r) then r else NONE;
}

// vectorizeHorReduction(P, Root, BB, R, PostponedInsts)
slp_vectorize_hor_reduction :: (p: Value_Id, root: Value_Id, bb: Value_Id, postponed: *[..] Vh) -> bool {
    if !slp_cl.vectorize_hor return false;
    try_operands_as_new_seeds := p != NONE && is_binary_op(inst_op(root));
    if inst_block(root) != bb || inst_op(root) == .PHI return false;
    select_root := root;
    if try_operands_as_new_seeds && slp_is_reduction_candidate(root) && hr_get_rdx_kind(root) != .NONE {
        nr := slp_try_get_secondary_reduction_root(p, root);
        if nr != NONE select_root = nr;
    }
    Item :: struct { i: Value_Id; level: s64; }
    stack: [..] Item; stack.allocator = temp;   // std::queue
    head := 0;
    array_add(*stack, .{select_root, 0});
    visited: Table(Value_Id, bool); visited.allocator = temp;
    res := false;
    try_to_reduce :: (inst: Value_Id) -> Value_Id {
        if slp_is_analyzed_reduction_root(inst) return NONE;
        if !slp_is_reduction_candidate(inst) return NONE;
        hr: Hr_Reduction;
        hr_init(*hr);
        r: Value_Id = NONE;
        if hr_match_associative_reduction(*hr, inst) {
            red := hr_try_to_reduce(*hr);
            if red != NONE {
                if red != inst return red;
                r = red;
            }
        }
        if hr_is_supported_ordered_reduction_op(inst) {
            if hr_match_ordered_reduction(*hr, inst, true) {
                red := hr_try_to_reduce_ordered(*hr);
                if red != NONE {
                    if red != inst return red;
                    r = red;
                }
            }
            if hr_match_ordered_reduction(*hr, inst, false) {
                red := hr_try_to_reduce_ordered(*hr);
                if red != NONE return red;
            }
        }
        return r;
    }
    while head < stack.count {
        inst := stack[head].i; level := stack[head].level;
        head += 1;
        if slp_is_deleted(inst) continue;
        vectorized_v := try_to_reduce(inst);
        if vectorized_v != NONE {
            res = true;
            if is_inst(vectorized_v) && vectorized_v != inst {
                array_add(*stack, .{vectorized_v, level});
                continue;
            }
            if slp_is_deleted(inst) continue;
        } else {
            // TryAppendToPostponedInsts
            future := inst;
            ok := true;
            if try_operands_as_new_seeds && future == root {
                future = slp_get_non_phi_operand(root, p);
                if future == NONE ok = false;
            }
            if !ok break;
            o := inst_op(future);
            if !(o == .ICMP || o == .FCMP || o == .INSERTELEMENT || o == .INSERTVALUE) array_add(postponed, vh_new(future));
        }
        level += 1;
        if level < slp_cl.recursion_max_depth {
            for k: 0..cast(s64) nops(inst) - 1 {
                o := op(inst, cast(u32) k);
                if table_contains(*visited, o) continue;
                table_set(*visited, o, true);
                if !is_inst(o) continue;
                oo := inst_op(o);
                if oo == .PHI || oo == .ICMP || oo == .FCMP || oo == .INSERTELEMENT || oo == .INSERTVALUE continue;
                if slp_is_deleted(o) || inst_block(o) != bb continue;
                array_add(*stack, .{o, level});
            }
        }
    }
    return res;
}

// tryToVectorize(I, R, FMACandidates, AllowFMACandidates)
slp_try_to_vectorize_inst :: (i: Value_Id, fma_candidates: *[..] Value_Id, allow_fma := false) -> bool {
    if i == NONE return false;
    o := inst_op(i);
    if !(is_binary_op(o) || o == .ICMP || o == .FCMP) || is_vector_type(vtype(i)) return false;
    if !allow_fma && (o == .FADD || o == .FSUB) && cost_valid(slp_can_convert_to_fma(.[i], slp_get_same_opcode(.[i]))) {
        found := false;
        for fma_candidates.* if it == i { found = true; break; }
        if !found array_add(fma_candidates, i);
        return false;
    }
    p := inst_block(i);
    op0 := op(i, 0); op1 := op(i, 1);
    if !is_inst(op0) || !is_inst(op1) || inst_block(op0) != p || inst_block(op1) != p || slp_is_deleted(op0) || slp_is_deleted(op1) return false;
    cands: [..] [2] Value_Id; cands.allocator = temp;
    array_add(*cands, .[op0, op1]);
    is_bo :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_op(inst_op(v)); }
    a := ifx is_bo(op0) then op0 else NONE;
    b := ifx is_bo(op1) then op1 else NONE;
    if a != NONE && b != NONE && has_one_use(b) {
        b0 := op(b, 0); b1 := op(b, 1);
        if is_bo(b0) && inst_block(b0) == p && !slp_is_deleted(b0) array_add(*cands, .[a, b0]);
        if is_bo(b1) && inst_block(b1) == p && !slp_is_deleted(b1) array_add(*cands, .[a, b1]);
    }
    if b != NONE && a != NONE && has_one_use(a) {
        a0 := op(a, 0); a1 := op(a, 1);
        if is_bo(a0) && inst_block(a0) == p && !slp_is_deleted(a0) array_add(*cands, .[a0, b]);
        if is_bo(a1) && inst_block(a1) == p && !slp_is_deleted(a1) array_add(*cands, .[a1, b]);
    }
    try_to_reduce :: (inst: Value_Id, ops: [] Value_Id) -> bool {
        if !slp_is_reduction_candidate(inst) return false;
        ty := vtype(inst);
        if !slp_is_valid_element_type(ty) || is_ptr_type(ty) return false;
        hr: Hr_Reduction;
        hr_init_for_operands(*hr, inst, ops);
        if !hr_match_reduction_for_operands(*hr) return false;
        vec_ty := slp_widened_type(ty, cast(u64) ops.count);
        dem := NewArray(cast(s64) slp_num_elements(vec_ty), bool,, temp);
        for * dem it.* = true;
        scalar_cost := cost_add(tti_scalarization_overhead(slp.tti, vec_ty, dem, false, true, TCK_RECIP_THROUGHPUT),
                                tti_instruction_cost(slp.tti, inst, TCK_RECIP_THROUGHPUT));
        red_cost: Cost;
        k := hr_get_rdx_kind(inst);
        if k == .ADD || k == .MUL || k == .OR || k == .AND || k == .XOR || k == .FADD || k == .FMUL {
            fmf: u32 = 0;
            if is_fp_math_inst(inst) fmf = inst_fmf(inst);
            red_cost = tti_arithmetic_reduction_cost(slp.tti, inst_op(inst), vec_ty, true, fmf, TCK_RECIP_THROUGHPUT);
        } else return false;
        if red_cost >= scalar_cost return false;
        return hr_try_to_reduce(*hr) != NONE;
    }
    if cands.count == 1 return try_to_reduce(i, .[op0, op1]) || (!allow_fma && slp_try_to_vectorize_list(.[op0, op1]));
    best := slp_find_best_root_pair(cands);
    if best < 0 return false;
    return (best == 0 && try_to_reduce(i, .[cands[best][0], cands[best][1]])) ||
           (!allow_fma && slp_try_to_vectorize_list(.[cands[best][0], cands[best][1]]));
}

// vectorizeRootInstruction(P, Root, BB, R, FMACandidates)
slp_vectorize_root_instruction :: (p: Value_Id, root: Value_Id, bb: Value_Id, fma_candidates: *[..] Value_Id) -> bool {
    postponed: [..] Vh; postponed.allocator = temp;   // WeakTrackingVH: erased entries become NONE
    res := slp_vectorize_hor_reduction(p, root, bb, *postponed);
    res |= slp_try_to_vectorize_insts(postponed, fma_candidates);
    return res;
}
// tryToVectorize(ArrayRef<WeakTrackingVH> Insts, R, FMACandidates)
slp_try_to_vectorize_insts :: (insts: [] Vh, fma_candidates: *[..] Value_Id) -> bool {
    res := false;
    for k: 0..insts.count-1 {
        v := vh_get(insts[k]);
        if v != NONE && is_inst(v) && !slp_is_deleted(v) res |= slp_try_to_vectorize_inst(v, fma_candidates);
    }
    return res;
}

// ---------------------------------------------------------------- inserts

// getAggregateSize(InsertInst)
slp_get_aggregate_size :: (ins: Value_Id) -> (bool, u64) {
    if inst_op(ins) == .INSERTELEMENT return true, type_count(vtype(ins));
    size: u64 = 1;
    t := vtype(ins);
    while true {
        k := type_kind(t);
        if k == .STRUCT {
            n := type_nsub(t);
            for j: 0..cast(s64) n - 1 if type_sub(t, cast(u32) j) != type_sub(t, 0) return false, 0;
            size *= n;
            t = type_sub(t, 0);
        } else if k == .ARRAY {
            size *= type_count(t);
            t = type_elem(t);
        } else if k == .VECTOR {
            size *= type_count(t);
            return true, size;
        } else if is_single_value_type(t) {
            return true, size;
        } else return false, 0;
    }
    return false, 0;
}
// findBuildAggregateRec
slp_find_build_aggregate_rec :: (last_in: Value_Id, opds: [] Value_Id, elts: [] Value_Id, offset: u64) {
    last := last_in;
    while true {
        inserted := op(last, 1);
        ok, idx := slp_element_index(last, offset);
        if !ok || slp_is_deleted(last) return;
        if is_inst(inserted) && (inst_op(inserted) == .INSERTELEMENT || inst_op(inserted) == .INSERTVALUE) {
            slp_find_build_aggregate_rec(inserted, opds, elts, idx);
        } else {
            opds[idx] = inserted;
            elts[idx] = last;
        }
        last = op(last, 0);
        if !(is_inst(last) && (inst_op(last) == .INSERTVALUE || inst_op(last) == .INSERTELEMENT) && has_one_use(last)) break;
    }
}
// findBuildAggregate(LastInsertInst, TTI, BuildVectorOpds, InsertElts, R)
slp_find_build_aggregate :: (last: Value_Id) -> (bool, [..] Value_Id, [..] Value_Id) {
    opds: [..] Value_Id; opds.allocator = temp;
    elts: [..] Value_Id; elts.allocator = temp;
    ok, size := slp_get_aggregate_size(last);
    if !ok return false, opds, elts;
    o := NewArray(cast(s64) size, Value_Id,, temp); for * o it.* = NONE;
    e := NewArray(cast(s64) size, Value_Id,, temp); for * e it.* = NONE;
    slp_find_build_aggregate_rec(last, o, e, 0);
    for o if it != NONE array_add(*opds, it);
    for e if it != NONE array_add(*elts, it);
    return opds.count >= 2, opds, elts;
}
// getContainedTypes(Ty): the struct elements, or the type itself
slp_contained_types :: (t: Type_Id) -> [..] Type_Id {
    r: [..] Type_Id; r.allocator = temp;
    if type_kind(t) == .STRUCT { for j: 0..cast(s64) type_nsub(t) - 1 array_add(*r, type_sub(t, cast(u32) j)); }
    else array_add(*r, t);
    return r;
}
// vectorizeInsertValueInst
slp_vectorize_insert_value_inst :: (ivi: Value_Id, bb: Value_Id, max_vf_only: bool) -> bool {
    if slp_can_map_to_vector(vtype(ivi)) == 0 return false;
    ok, opds, insts := slp_find_build_aggregate(ivi);
    if !ok return false;
    if max_vf_only && opds.count == 2 return false;
    bv := vtype(insts[0]);
    ct := slp_contained_types(bv);
    same := true;
    for ct if it != ct[0] { same = false; break; }
    if ct.count == insts.count && slp_is_valid_element_type(ct[0]) && same
        if slp_try_to_vectorize_list(insts, max_vf_only) return true;
    return slp_try_to_vectorize_list(opds, max_vf_only);
}
// vectorizeInsertElementInst
slp_vectorize_insert_element_inst :: (iei: Value_Id, bb: Value_Id, max_vf_only: bool) -> bool {
    ok, opds, insts := slp_find_build_aggregate(iei);
    if !ok return false;
    all_ext := true;
    for opds if !((is_inst(it) && inst_op(it) == .EXTRACTELEMENT) || pm_undef_value(it)) { all_ext = false; break; }
    if all_ext {
        fixed := slp_is_fixed_vector_shuffle(opds, slp.ac);
        if fixed return false;
    }
    if max_vf_only && insts.count == 2 return false;
    return slp_try_to_vectorize_list(insts, max_vf_only);
}
// vectorizeInserts(Instructions, BB, R, FMACandidates)
slp_vectorize_inserts :: (instructions: *[..] Value_Id, bb: Value_Id, fma_candidates: *[..] Value_Id) -> bool {
    changed := false;
    postponed: [..] Vh; postponed.allocator = temp;
    for < i: instructions.* {
        if slp_is_deleted(i) || inst_op(i) == .ICMP || inst_op(i) == .FCMP continue;
        if inst_op(i) == .INSERTVALUE changed |= slp_vectorize_insert_value_inst(i, bb, true);
        else if inst_op(i) == .INSERTELEMENT changed |= slp_vectorize_insert_element_inst(i, bb, true);
        if slp_is_deleted(i) continue;
        changed |= slp_vectorize_hor_reduction(NONE, i, bb, *postponed);
        if slp_is_deleted(i) || inst_op(i) == .ICMP || inst_op(i) == .FCMP continue;
        if inst_op(i) == .INSERTVALUE changed |= slp_vectorize_insert_value_inst(i, bb, false);
        else if inst_op(i) == .INSERTELEMENT changed |= slp_vectorize_insert_element_inst(i, bb, false);
    }
    changed |= slp_try_to_vectorize_insts(postponed, fma_candidates);
    array_reset_keeping_memory(instructions);
    return changed;
}

// ---------------------------------------------------------------- compares

// compareCmp<IsCompatibility>(V, V2, TLI, DT)
slp_compare_cmp :: (v: Value_Id, v2: Value_Id, is_compat: bool) -> bool {
    if v == v2 return is_compat;
    t1 := vtype(op(v, 0)); t2 := vtype(op(v2, 0));
    if slp_type_id(t1) < slp_type_id(t2) return !is_compat;
    if slp_type_id(t1) > slp_type_id(t2) return false;
    if type_scalar_size_bits(t1) < type_scalar_size_bits(t2) return !is_compat;
    if type_scalar_size_bits(t1) > type_scalar_size_bits(t2) return false;
    p1 := inst(v).pred; p2 := inst(v2).pred;
    bp1 := min(p1, swapped_predicate(p1)); bp2 := min(p2, swapped_predicate(p2));
    if bp1 < bp2 return !is_compat;
    if bp1 > bp2 return false;
    c1 := p1 == bp1; c2 := p2 == bp1;
    e := cast(s64) nops(v);
    for k: 0..e-1 {
        o1 := op(v, cast(u32) ifx c1 then k else e - k - 1);
        o2 := op(v2, cast(u32) ifx c2 then k else e - k - 1);
        if o1 == o2 continue;
        if slp_value_id(o1) < slp_value_id(o2) return !is_compat;
        if slp_value_id(o1) > slp_value_id(o2) return false;
        if is_inst(o1) && is_inst(o2) {
            if is_compat {
                if inst_block(o1) != inst_block(o2) return false;
            } else {
                n1 := dt_node(slp.dt, inst_block(o1)); n2 := dt_node(slp.dt, inst_block(o2));
                if n1 < 0 return n2 >= 0;
                if n2 < 0 return false;
                if n1 != n2 return slp.dt.nodes[n1].dfs_in < slp.dt.nodes[n2].dfs_in;
            }
            s := slp_get_same_opcode(.[o1, o2]);
            if is_valid(s) && (is_compat || !is_alt_shuffle(s)) continue;
            if is_compat return false;
            if inst_op(o1) != inst_op(o2) return inst_op(o1) < inst_op(o2);
        }
    }
    return is_compat;
}

// vectorizeCmpInsts(CmpInsts, BB, R, FMACandidates); cmps in the iteration order given
slp_vectorize_cmp_insts :: (cmps: [] Value_Id, bb: Value_Id, fma_candidates: *[..] Value_Id) -> bool {
    changed := false;
    for i: cmps {
        if slp_is_deleted(i) continue;
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if is_inst(o) {
                changed |= slp_vectorize_root_instruction(NONE, o, bb, fma_candidates);
                if slp_is_deleted(i) break;
            }
        }
    }
    for i: cmps {
        if slp_is_deleted(i) continue;
        changed |= slp_try_to_vectorize_inst(i, fma_candidates);
    }
    vals: [..] Value_Id; vals.allocator = temp;
    for v: cmps if !slp_is_deleted(v) && slp_is_valid_element_type(slp_get_value_type(v, true)) array_add(*vals, v);
    if vals.count <= 1 return changed;
    ctx: Seq_Ctx;
    ctx.kind = .CMPS;
    changed |= slp_try_to_vectorize_sequence(*ctx, vals, true);
    return changed;
}

// ---------------------------------------------------------------- non-vectorizable roots

// isNonVectorizableInst(I, TLI)
slp_is_non_vectorizable_inst :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if is_call_base(i) {
        if call_is_inline_asm(i) return false;
        if call_iid(i) != NOT_INTRINSIC {
            if is_assume_like_intrinsic(i) return false;
            if is_any_mem_intrinsic(i) return false;
        }
        if o == .CALL {
            id := get_vector_intrinsic_id_for_call(i);
            if is_trivially_vectorizable(id) return false;
            if call_has_vector_variants(i) return false;
            n := cast(s64) call_num_args(i);
            all_non_inst := true;
            for k: 0..n-1 { a := call_arg(i, cast(u32) k); if is_inst(a) && !is_ptr_type(vtype(a)) { all_non_inst = false; break; } }
            if all_non_inst return false;
            for k: 0..n-1 if is_ptr_type(vtype(call_arg(i, cast(u32) k))) return false;
        }
        return !is_vector_type(vtype(i));
    }
    if o == .ATOMICRMW || o == .CMPXCHG return true;
    if o == .EXTRACTVALUE {
        arg := op(i, 0);
        if is_inst(arg) && inst_op(arg) == .CALL {
            id := get_vector_intrinsic_id_for_call(arg);
            if is_trivially_vectorizable(id) return true;
            if call_has_vector_variants(arg) return true;
            return false;
        }
    }
    if o == .RET return nops(i) > 0 && !is_vector_type(vtype(op(i, 0))) && is_inst(op(i, 0));
    return false;
}

// forEachOperandChainCandidate(I, F, ForReduction): the (operand, position) pairs
slp_operand_chain_candidates :: (i: Value_Id, for_reduction: bool) -> [..] [2] Value_Id {
    r: [..] [2] Value_Id; r.allocator = temp;
    o := inst_op(i);
    if is_call_base(i) {
        n := cast(s64) call_num_args(i);
        if for_reduction && !slp_cl.non_vect_reductions && n > 1 return r;
        for k: 0..n-1 array_add(*r, .[call_arg(i, cast(u32) k), cast(u32) k]);
        return r;
    }
    if o == .ATOMICRMW { array_add(*r, .[op(i, 1), 0]); return r; }
    if o == .CMPXCHG { array_add(*r, .[op(i, 1), 0]); array_add(*r, .[op(i, 2), 1]); return r; }
    if o == .EXTRACTVALUE { array_add(*r, .[op(i, 0), 0]); return r; }
    if for_reduction && !slp_cl.non_vect_reductions return r;
    if o == .STORE { array_add(*r, .[op(i, 0), 0]); return r; }
    if o == .RET { if nops(i) > 0 array_add(*r, .[op(i, 0), 0]); return r; }
    fatal("internal: slp: unexpected instruction kind for operand-chain seeding");
    return r;
}

Operand_Group_Key :: struct {
    root_kind: u32;    // 0 NonCall, 1 Intrinsic, 2 NamedFunction, 3 IndirectCall; SeedGroupKey uses 0
    kind_id: u32;
    sub_op: u32;
    func_name: string;
    position: u32;
}
ogk_equal :: (a: Operand_Group_Key, b: Operand_Group_Key) -> bool {
    return a.root_kind == b.root_kind && a.kind_id == b.kind_id && a.sub_op == b.sub_op && a.func_name == b.func_name && a.position == b.position;
}
ogk_less :: (a: Operand_Group_Key, b: Operand_Group_Key) -> bool {
    if a.root_kind != b.root_kind return a.root_kind < b.root_kind;
    if a.kind_id != b.kind_id return a.kind_id < b.kind_id;
    if a.sub_op != b.sub_op return a.sub_op < b.sub_op;
    c := compare_strings(a.func_name, b.func_name);
    if c != 0 return c < 0;
    return a.position < b.position;
}

slp_operand_sorter :: (c: *Seq_Ctx, v1: Value_Id, v2: Value_Id) -> bool {
    if v1 == v2 return false;
    k1 := table_find_pointer(*c.op_keys, v1).*; k2 := table_find_pointer(*c.op_keys, v2).*;
    if !ogk_equal(k1, k2) return ogk_less(k1, k2);
    t1 := vtype(v1); t2 := vtype(v2);
    if slp_type_id(t1) != slp_type_id(t2) return slp_type_id(t1) < slp_type_id(t2);
    if type_scalar_size_bits(t1) != type_scalar_size_bits(t2) return type_scalar_size_bits(t1) < type_scalar_size_bits(t2);
    if inst_op(v1) != inst_op(v2) return inst_op(v1) < inst_op(v2);
    return comes_before(v1, v2);
}

// vectorizeNonVectorizableInsts(InstRange, BB, R, FMACandidates)
slp_vectorize_non_vectorizable_insts :: (range: [] Value_Id, bb: Value_Id, fma_candidates: *[..] Value_Id) -> bool {
    if range.count == 0 return false;
    insts := array_copy(range,, temp);
    // stable_sort by opcode
    for i: 1..insts.count-1 {
        x := insts[i]; j := i;
        while j > 0 && inst_op(x) < inst_op(insts[j - 1]) { insts[j] = insts[j - 1]; j -= 1; }
        insts[j] = x;
    }
    changed := false;
    root_seen: Table(Value_Id, bool); root_seen.allocator = temp;
    for i: insts {
        if slp_is_deleted(i) continue;
        for pair: slp_operand_chain_candidates(i, true) {
            root := pair[0];
            if !is_inst(root) || inst_block(root) != bb || slp_is_deleted(root) || inst_op(root) == .SHUFFLEVECTOR ||
               !slp_is_valid_element_type(vtype(root)) continue;
            if table_contains(*root_seen, root) continue;
            table_set(*root_seen, root, true);
            changed |= slp_vectorize_root_instruction(NONE, root, bb, fma_candidates);
            if slp_is_deleted(i) break;
        }
    }
    if insts.count < 2 return changed;
    ctx: Seq_Ctx;
    ctx.kind = .OPERANDS;
    ctx.op_keys.allocator = temp;
    build_key :: (i: Value_Id, position: u32) -> Operand_Group_Key {
        if is_call_base(i) {
            id := call_iid(i);
            if id != NOT_INTRINSIC return .{1, cast(u32) id, 0, "", position};
            f := call_called_function(i);
            if f != NONE return .{2, 0, 0, vname(f), position};
            return .{3, slp_value_id(call_callee(i)), 0, "", position};
        }
        sub: u32 = 0;
        if inst_op(i) == .ATOMICRMW sub = inst(i).ord2;
        return .{0, cast(u32) inst_op(i), sub, "", position};
    }
    operands: [..] Value_Id; operands.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    for i: insts {
        if slp_is_deleted(i) continue;
        for pair: slp_operand_chain_candidates(i, false) {
            o := pair[0];
            if !is_inst(o) || inst_block(o) != bb || slp_is_deleted(o) || inst_op(o) == .SHUFFLEVECTOR ||
               (!slp_is_valid_element_type(vtype(o)) && call_iid(o) == NOT_INTRINSIC) continue;
            if table_contains(*seen, o) continue;
            table_set(*seen, o, true);
            if !table_contains(*ctx.op_keys, o) table_set(*ctx.op_keys, o, build_key(i, pair[1]));
            array_add(*operands, o);
        }
    }
    if operands.count <= 1 return changed;
    changed |= slp_try_to_vectorize_sequence(*ctx, operands, true);
    return changed;
}

// ---------------------------------------------------------------- phis

slp_phi_ops :: (c: *Seq_Ctx, v: Value_Id) -> [] Value_Id {
    for c.phi_keys if it == v return c.phi_ops[it_index];
    // PHIToOpcodes[V] default-constructs an empty entry
    array_add(*c.phi_keys, v);
    l: [..] Value_Id; l.allocator = temp;
    array_add(*c.phi_ops, l);
    return c.phi_ops[c.phi_ops.count - 1];
}

slp_phi_compare :: (c: *Seq_Ctx, v1: Value_Id, v2: Value_Id) -> bool {
    if v1 == v2 return false;
    t1 := vtype(v1); t2 := vtype(v2);
    if slp_type_id(t1) < slp_type_id(t2) return true;
    if slp_type_id(t1) > slp_type_id(t2) return false;
    if type_scalar_size_bits(t1) < type_scalar_size_bits(t2) return true;
    if type_scalar_size_bits(t1) > type_scalar_size_bits(t2) return false;
    o1 := slp_phi_ops(c, v1); o2 := slp_phi_ops(c, v2);
    if o1.count < o2.count return true;
    if o1.count > o2.count return false;
    for k: 0..o1.count-1 {
        {
            i1 := is_inst(o1[k]); i2 := is_inst(o2[k]);
            if i1 && i2 {
                a := o1[k]; b := o2[k];
                n1 := dt_node(slp.dt, inst_block(a)); n2 := dt_node(slp.dt, inst_block(b));
                if n1 < 0 return n2 >= 0;
                if n2 < 0 return false;
                if n1 != n2 return slp.dt.nodes[n1].dfs_in < slp.dt.nodes[n2].dfs_in;
                s := slp_get_same_opcode(.[a, b]);
                if is_valid(s) && !is_alt_shuffle(s) && inst_op(a) == inst_op(b) {
                    if inst_op(a) != .EXTRACTELEMENT || inst_op(b) != .EXTRACTELEMENT continue;
                    x1 := op(a, 0); x2 := op(b, 0);
                    xv1 := ifx is_inst(x1) then x1 else NONE;
                    xv2 := ifx is_inst(x2) then x2 else NONE;
                    if xv1 != xv2 {
                        if xv1 != NONE && xv2 == NONE return true;
                        if xv1 == NONE && xv2 != NONE return false;
                        m1 := dt_node(slp.dt, inst_block(xv1)); m2 := dt_node(slp.dt, inst_block(xv2));
                        if m1 < 0 return m2 >= 0;
                        if m2 < 0 return false;
                        if m1 != m2 return slp.dt.nodes[m1].dfs_in < slp.dt.nodes[m2].dfs_in;
                        return comes_before(xv1, xv2);
                    }
                    ok1, id1 := slp_extract_index(a);
                    ok2, id2 := slp_extract_index(b);
                    if ok1 && !ok2 return true;
                    if !ok1 && ok2 return false;
                    if ok1 && ok2 return id1 < id2;
                    continue;
                }
                if inst_op(a) == inst_op(b) continue;
                return inst_op(a) < inst_op(b);
            }
            if i1 return true;
            if i2 return false;
        }
        {
            c1 := is_constant_kind(vkind(o1[k])) && !pm_undef_value(o1[k]);
            c2 := is_constant_kind(vkind(o2[k])) && !pm_undef_value(o2[k]);
            if c1 && c2 continue;
            if c1 return true;
            if c2 return false;
        }
        u1 := pm_undef_value(o1[k]); u2 := pm_undef_value(o2[k]);
        {
            if !u1 && !u2 {
                id1 := slp_value_id(o1[k]); id2 := slp_value_id(o2[k]);
                if id1 == id2 continue;
                if id1 < id2 return true;
                if id1 > id2 return false;
            }
            if !u1 return true;
            if !u2 return false;
        }
    }
    return false;
}

slp_are_compatible_phis :: (c: *Seq_Ctx, vl: [] Value_Id, v1: Value_Id) -> bool {
    if vl.count == 0 || v1 == vl[vl.count - 1] return true;
    v2 := vl[vl.count - 1];
    if vtype(v1) != vtype(v2) return false;
    o1 := slp_phi_ops(c, v1); o2 := slp_phi_ops(c, v2);
    if o1.count != o2.count return false;
    for k: 0..o1.count-1 {
        if pm_undef_value(o1[k]) || pm_undef_value(o2[k]) continue;
        if is_inst(o1[k]) && is_inst(o2[k]) {
            if slp_is_deleted(o1[k]) || slp_is_deleted(o2[k]) return false;
            if inst_block(o1[k]) != inst_block(o2[k]) return false;
            if is_valid(slp_get_same_opcode(.[o1[k], o2[k]])) continue;
            return false;
        }
        if is_constant_kind(vkind(o1[k])) && is_constant_kind(vkind(o2[k])) continue;
        if slp_value_id(o1[k]) != slp_value_id(o2[k]) return false;
    }
    return true;
}

// ---------------------------------------------------------------- poor-throughput seeds

// buildIntrinsicArgTypes(CI, ID, VF, MinBW, TTI)
slp_build_intrinsic_arg_types :: (ci: Value_Id, id: Intrinsic_Id, vf: u64, min_bw: u32) -> [..] Type_Id {
    r: [..] Type_Id; r.allocator = temp;
    for k: 0..cast(s64) call_num_args(ci) - 1 {
        a := call_arg(ci, cast(u32) k);
        if id != NOT_INTRINSIC {
            if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) { array_add(*r, vtype(a)); continue; }
            if min_bw > 0 { array_add(*r, slp_widened_type(type_int(min_bw), vf)); continue; }
        }
        array_add(*r, slp_widened_type(vtype(a), vf));
    }
    return r;
}
// getVectorCallCosts(CI, VecTy, TTI, TLI, ArgTys): (intrinsic cost, library cost)
slp_vector_call_costs :: (ci: Value_Id, vec_ty: Type_Id, arg_tys: [] Type_Id) -> (Cost, Cost) {
    if call_has_vector_variants(ci) slp_fail("vector library calls (VFDatabase::getVectorizedFunction)");
    lib_cost := COST_INVALID;
    id := get_vector_intrinsic_id_for_call(ci);
    fmf: u32 = 0;
    if is_fp_math_inst(ci) fmf = inst_fmf(ci);
    SCALAR_LIMIT :: 10000;
    a := ica_types(id, vec_ty, arg_tys, fmf, NONE, SCALAR_LIMIT);
    ic := tti_intrinsic_cost(slp.tti, *a, TCK_RECIP_THROUGHPUT);
    if ic > SCALAR_LIMIT {
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) call_num_args(ci) - 1 array_add(*args, call_arg(ci, cast(u32) k));
        b := ica_types(id, vec_ty, arg_tys, fmf, ifx call_iid(ci) != NOT_INTRINSIC then ci else NONE, SCALAR_LIMIT);
        b.args = args;
        b.type_based_only = false;
        ic = tti_intrinsic_cost(slp.tti, *b, TCK_RECIP_THROUGHPUT);
        #if DEBUG_SLP print("DBG retry ic=%\n", ic);
        if ic > SCALAR_LIMIT ic = COST_INVALID;
    }
    #if DEBUG_SLP print("DBG call costs ic=% lc=%\n", ic, lib_cost);
    return ic, lib_cost;
}
// getVectorOpCost(I, VF, TTI, TLI)
slp_vector_op_cost :: (i: Value_Id, vf: u64) -> Cost {
    vec_ty := slp_widened_type(vtype(i), vf);
    if inst_op(i) == .CALL {
        id := get_vector_intrinsic_id_for_call(i);
        arg_tys := slp_build_intrinsic_arg_types(i, id, vf, 0);
        ic, lc := slp_vector_call_costs(i, vec_ty, arg_tys);
        return min(ic, lc);
    }
    return tti_arith_cost(slp.tti, inst_op(i), vec_ty, TCK_RECIP_THROUGHPUT);
}

Poor_Throughput_Cache :: struct {
    cheap_opcodes: [..] [2] u32;
    cheap_intrinsics: [..] [2] u32;
    cheap_callees: [..] Value_Id;
}
// isPoorThroughputOp(I, TTI, TLI, Cache)
slp_is_poor_throughput_op :: (i: Value_Id, cache: *Poor_Throughput_Cache) -> bool {
    o := inst_op(i);
    if !is_binary_op(o) && o != .CALL return false;
    ty := vtype(i);
    if is_vector_type(ty) || is_aggregate(ty) || !slp_is_valid_element_type(ty) return false;
    analyze :: (i: Value_Id) -> bool {
        scalar_cost := tti_instruction_cost(slp.tti, i, TCK_RECIP_THROUGHPUT);
        if scalar_cost < TCC_EXPENSIVE return false;
        return slp_vector_op_cost(i, 2) < cost_mul(scalar_cost, 2);
    }
    type_key := (slp_type_id(ty) << 16) | cast(u32) type_scalar_size_bits(ty);
    contains :: (l: [] [2] u32, a: u32, b: u32) -> bool { for l if it[0] == a && it[1] == b return true; return false; }
    if o == .CALL {
        for k: 0..cast(s64) call_num_args(i) - 1 if !slp_is_valid_element_type(vtype(call_arg(i, cast(u32) k))) return false;
        id := get_vector_intrinsic_id_for_call(i);
        if id != NOT_INTRINSIC {
            if contains(cache.cheap_intrinsics, cast(u32) id, type_key) return false;
            if analyze(i) return true;
            array_add(*cache.cheap_intrinsics, .[cast(u32) id, type_key]);
            return false;
        }
        callee := call_called_function(i);
        if callee == NONE return analyze(i);
        for cache.cheap_callees if it == callee return false;
        if analyze(i) return true;
        array_add(*cache.cheap_callees, callee);
        return false;
    }
    if contains(cache.cheap_opcodes, cast(u32) o, type_key) return false;
    if analyze(i) return true;
    array_add(*cache.cheap_opcodes, .[cast(u32) o, type_key]);
    return false;
}
// getSeedGroupKey(I, TLI)
slp_seed_group_key :: (i: Value_Id) -> Operand_Group_Key {
    k: Operand_Group_Key;
    k.kind_id = cast(u32) inst_op(i);
    if inst_op(i) == .CALL {
        k.sub_op = cast(u32) get_vector_intrinsic_id_for_call(i);
        f := call_called_function(i);
        if f != NONE k.func_name = vname(f);
    }
    return k;
}
slp_seed_sorter :: (c: *Seq_Ctx, v1: Value_Id, v2: Value_Id) -> bool {
    if v1 == v2 return false;
    t1 := vtype(v1); t2 := vtype(v2);
    if slp_type_id(t1) != slp_type_id(t2) return slp_type_id(t1) < slp_type_id(t2);
    if type_scalar_size_bits(t1) != type_scalar_size_bits(t2) return type_scalar_size_bits(t1) < type_scalar_size_bits(t2);
    k1 := table_find_pointer(*c.op_keys, v1).*; k2 := table_find_pointer(*c.op_keys, v2).*;
    if !ogk_equal(k1, k2) {
        // SeedGroupKey::less: Opcode, IntrID, CalleeName
        if k1.kind_id != k2.kind_id return k1.kind_id < k2.kind_id;
        if k1.sub_op != k2.sub_op return k1.sub_op < k2.sub_op;
        return compare_strings(k1.func_name, k2.func_name) < 0;
    }
    return comes_before(v1, v2);
}

// ---------------------------------------------------------------- vectorizeChainsInBlock

slp_vectorize_chains_in_block :: (bb: Value_Id) -> bool {
    changed := false;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    phi_ctx: Seq_Ctx;
    phi_ctx.kind = .PHIS;
    phi_ctx.phi_keys.allocator = temp; phi_ctx.phi_ops.allocator = temp;
    have_vectorized_phis := false;
    while true {
        incoming: [..] Value_Id; incoming.allocator = temp;
        for i: block_insts(bb) {
            if inst_op(i) != .PHI || phi_num_incoming(i) > SLP_MAX_PHI_NUM_OPERANDS break;
            if !table_contains(*visited, i) && !slp_is_deleted(i) && slp_is_valid_element_type(vtype(i)) array_add(*incoming, i);
        }
        if incoming.count <= 1 break;
        for v: incoming {
            k := -1;
            for phi_ctx.phi_keys if it == v { k = it_index; break; }
            if k < 0 {
                array_add(*phi_ctx.phi_keys, v);
                l: [..] Value_Id; l.allocator = temp;
                array_add(*phi_ctx.phi_ops, l);
                k = phi_ctx.phi_keys.count - 1;
            }
            if phi_ctx.phi_ops[k].count continue;
            nodes: [..] Value_Id; nodes.allocator = temp;
            array_add(*nodes, v);
            vis: Table(Value_Id, bool); vis.allocator = temp;
            while nodes.count {
                phi := pop(*nodes);
                if table_contains(*vis, phi) continue;
                table_set(*vis, phi, true);
                for j: 0..cast(s64) phi_num_incoming(phi) - 1 {
                    x := phi_value(phi, cast(u32) j);
                    if is_inst(x) && inst_op(x) == .PHI { array_add(*nodes, x); continue; }
                    array_add(*phi_ctx.phi_ops[k], x);
                }
            }
        }
        have_vectorized_phis = slp_try_to_vectorize_sequence(*phi_ctx, incoming, true);
        changed |= have_vectorized_phis;
        if have_vectorized_phis {
            any := false;
            for phi_ctx.phi_keys if !is_inst(it) || inst_op(it) != .PHI || slp_is_deleted(it) { any = true; break; }
            if any { array_reset_keeping_memory(*phi_ctx.phi_keys); array_reset_keeping_memory(*phi_ctx.phi_ops); }
        }
        for incoming table_set(*visited, it, true);
        if !have_vectorized_phis break;
    }
    table_reset(*visited);

    post_inserts: [..] Value_Id; post_inserts.allocator = temp;     // SetVectors (insertion order, unique)
    post_cmps: [..] Value_Id; post_cmps.allocator = temp;
    post_insts: [..] Value_Id; post_insts.allocator = temp;
    post_stores: [..] Value_Id; post_stores.allocator = temp;
    fma_candidates: [..] Value_Id; fma_candidates.allocator = temp;
    poor_seeds: [..] Value_Id; poor_seeds.allocator = temp;
    poor_cache: Poor_Throughput_Cache;
    poor_cache.cheap_opcodes.allocator = temp; poor_cache.cheap_intrinsics.allocator = temp; poor_cache.cheap_callees.allocator = temp;
    set_insert :: (s: *[..] Value_Id, v: Value_Id) { for s.* if it == v return; array_add(s, v); }
    set_contains :: (s: [] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }
    reversed :: (s: [] Value_Id) -> [] Value_Id { r := NewArray(s.count, Value_Id,, temp); for k: 0..s.count-1 r[k] = s[s.count - 1 - k]; return r; }
    vectorize_inserts_and_cmps :: (at_terminator: bool, bb: Value_Id, post_inserts: *[..] Value_Id, post_cmps: *[..] Value_Id,
                                   post_insts: *[..] Value_Id, fma: *[..] Value_Id) -> bool {
        ch := slp_vectorize_inserts(post_inserts, bb, fma);
        if at_terminator {
            ch |= slp_vectorize_cmp_insts(reversed(post_cmps.*), bb, fma);
            array_reset_keeping_memory(post_cmps);
            if post_insts.count ch |= slp_vectorize_non_vectorizable_insts(reversed(post_insts.*), bb, fma);
            array_reset_keeping_memory(post_insts);
        }
        array_reset_keeping_memory(post_inserts);
        return ch;
    }
    is_in_post_process :: (i: Value_Id, post_inserts: [] Value_Id, post_cmps: [] Value_Id, post_insts: [] Value_Id, post_stores: [] Value_Id) -> bool {
        o := inst_op(i);
        if o == .ICMP || o == .FCMP return set_contains(post_cmps, i);
        if set_contains(post_insts, i) return true;
        if o == .STORE return set_contains(post_stores, i);
        return (o == .INSERTELEMENT || o == .INSERTVALUE) && set_contains(post_inserts, i);
    }
    has_no_users :: (i: Value_Id) -> bool {
        return !has_uses(i) && (type_kind(vtype(i)) == .VOID || inst_op(i) == .CALL || inst_op(i) == .INVOKE);
    }
    it := block_first(bb);
    while it != NONE {
        defer it = inst_next(it);
        if type_kind(vtype(it)) == .SVECTOR continue;
        if slp_is_deleted(it) continue;
        if table_contains(*visited, it) {
            if has_no_users(it) && vectorize_inserts_and_cmps(is_terminator(inst_op(it)), bb, *post_inserts, *post_cmps, *post_insts, *fma_candidates) {
                changed = true;
                it = block_first(bb);   // It = BB->begin(); the loop's ++It then skips it
            }
            continue;
        }
        table_set(*visited, it, true);
        if inst_op(it) == .PHI {
            p := it;
            if phi_num_incoming(p) == 2 {
                root := slp_get_reduction_instr(p, bb);
                if root != NONE && slp_vectorize_root_instruction(p, root, bb, *fma_candidates) {
                    changed = true;
                    it = block_first(bb);
                    continue;
                }
            }
            restarted := false;
            for k: 0..cast(s64) phi_num_incoming(p) - 1 {
                inb := phi_block(p, cast(u32) k);
                if bb == inb || !dt_is_reachable_from_entry(slp.dt, inb) continue;
                pi := phi_value(p, cast(u32) k);
                if is_inst(pi) && !is_in_post_process(pi, post_inserts, post_cmps, post_insts, post_stores) {
                    res := slp_vectorize_root_instruction(NONE, pi, inb, *fma_candidates);
                    changed |= res;
                    if res && slp_is_deleted(p) { it = block_first(bb); restarted = true; break; }
                }
            }
            continue;
        }
        if has_no_users(it) {
            ops_changed := false;
            is_store := inst_op(it) == .STORE;
            try_root := slp_cl.vectorize_hor_store || !is_store;
            if is_store {
                k := slp_map_find(sv.store_keys, sv.store_lists, get_underlying_object(op(it, 1)));
                try_root |= (k < 0 || sv.store_lists[k].count == 1) && value_has_one_use(op(it, 0));
            }
            if try_root {
                n := cast(s64) nops(it);
                vals := NewArray(n, Value_Id,, temp);
                for k: 0..n-1 vals[k] = op(it, cast(u32) k);
                for vi: vals {
                    if is_inst(vi) && !is_in_post_process(vi, post_inserts, post_cmps, post_insts, post_stores)
                        ops_changed |= slp_vectorize_root_instruction(NONE, vi, bb, *fma_candidates);
                }
            }
            ops_changed |= vectorize_inserts_and_cmps(is_terminator(inst_op(it)), bb, *post_inserts, *post_cmps, *post_insts, *fma_candidates);
            if ops_changed {
                changed = true;
                it = block_first(bb);
                continue;
            }
        }
        o := inst_op(it);
        if o == .INSERTELEMENT || o == .INSERTVALUE set_insert(*post_inserts, it);
        else if o == .ICMP || o == .FCMP set_insert(*post_cmps, it);
        else if o == .STORE && !is_vector_type(vtype(op(it, 0))) && is_inst(op(it, 0)) set_insert(*post_stores, it);
        else if slp_is_non_vectorizable_inst(it) set_insert(*post_insts, it);
        else if slp_cl.poor_throughput && slp_is_poor_throughput_op(it, *poor_cache) set_insert(*poor_seeds, it);
    }

    if post_stores.count && (slp_cl.non_vect_reductions || post_stores.count >= 2) {
        try_vectorize := true;
        if !slp_cl.postprocess_stores_operands && slp_cl.threshold >= 0 {
            sty := slp_get_value_type(post_stores[0]);
            if !slp_is_valid_element_type(sty) {
                try_vectorize = false;
            } else {
                vf_ := op(post_stores[0], 0); vb := op(post_stores[post_stores.count - 1], 0);
                if !slp_cl.non_vect_reductions && post_stores.count == 2 && (!is_inst(vf_) || !is_inst(vb) || inst_op(vf_) != inst_op(vb)) {
                    try_vectorize = false;
                } else {
                    sty = type_int(cast(u32) dl_type_size_bits(scalar_type(sty)));
                    vt0 := vtype(op(post_stores[0], 0));
                    if is_vector_type(vt0) sty = slp_widened_type(sty, slp_num_elements(vt0));
                    vec_ty := slp_widened_type(sty, cast(u64) post_stores.count);
                    dem := NewArray(post_stores.count, bool,, temp);
                    for * dem it.* = true;
                    extracts_cost := slp_get_scalarization_overhead(sty, vec_ty, dem, false, true, TCK_RECIP_THROUGHPUT, true, .[], VIC_STORE);
                    try_vectorize = extracts_cost <= post_stores.count + 1;
                }
            }
        }
        if try_vectorize changed |= slp_vectorize_non_vectorizable_insts(reversed(post_stores), bb, *fma_candidates);
    }
    empty: [..] Value_Id; empty.allocator = temp;
    for i: fma_candidates {
        if slp_is_deleted(i) continue;
        changed |= slp_try_to_vectorize_inst(i, *empty, true);
    }
    if poor_seeds.count >= 2 {
        seeds: [..] Value_Id; seeds.allocator = temp;
        ctx: Seq_Ctx;
        ctx.kind = .SEEDS;
        ctx.op_keys.allocator = temp;
        for i: poor_seeds {
            if slp_is_deleted(i) || !slp_is_valid_element_type(slp_get_value_type(i)) continue;
            skip := false;
            u := ir.v_first_use[i];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                if is_inst(usr) && (slp_is_deleted(usr) || slp_is_vectorized(usr)) { skip = true; break; }
            }
            if skip continue;
            if !table_contains(*ctx.op_keys, i) table_set(*ctx.op_keys, i, slp_seed_group_key(i));
            array_add(*seeds, i);
        }
        if seeds.count >= 2 changed |= slp_try_to_vectorize_sequence(*ctx, seeds, false);
    }
    return changed;
}


// ---------------------------------------------------------------- GEP indices

slp_vectorize_gep_indices :: (bb: Value_Id) -> bool {
    changed := false;
    for list: sv.gep_lists {
        if list.count < 2 continue;
        first := -1;
        for list if !slp_is_deleted(it) { first = it_index; break; }
        if first < 0 continue;
        max_vec_reg_size := slp.max_vec_reg_size;
        elt_size := slp_get_vector_element_size(op(list[first], 1));
        if max_vec_reg_size < elt_size continue;
        max_elts := cast(s64) (max_vec_reg_size / elt_size);
        bi := 0;
        while bi < list.count {
            defer bi += max_elts;
            len := min(list.count - bi, max_elts);
            gep_list := array_view(list, bi, len);
            cands: [..] Value_Id; cands.allocator = temp;
            for gep_list {
                dup := false;
                for c: cands if c == it { dup = true; break; }
                if !dup array_add(*cands, it);
            }
            remove_v :: (c: *[..] Value_Id, v: Value_Id) { for c.* if it == v { array_ordered_remove_by_index(c, it_index); return; } }
            contains :: (c: [] Value_Id, v: Value_Id) -> bool { for c if it == v return true; return false; }
            {
                k := 0;
                while k < cands.count {
                    x := cands[k];
                    if slp_is_deleted(x) || is_constant_kind(vkind(op(x, 1))) array_ordered_remove_by_index(*cands, k);
                    else k += 1;
                }
            }
            for i: 0..gep_list.count-1 {
                if cands.count <= 1 break;
                gi := gep_list[i];
                if !contains(cands, gi) continue;
                si := sc_get_scev(gi);
                for j: i+1..gep_list.count-1 {
                    if cands.count <= 1 break;
                    gj := gep_list[j];
                    if !contains(cands, gj) continue;
                    sj := sc_get_scev(gj);
                    if sc_kind(sc_get_minus(si, sj)) == .CONSTANT {
                        remove_v(*cands, gi);
                        remove_v(*cands, gj);
                    } else if op(gi, 1) == op(gj, 1) {
                        remove_v(*cands, gj);
                    }
                }
            }
            if cands.count < 2 continue;
            bundle := NewArray(cands.count, Value_Id,, temp);
            for cands bundle[it_index] = op(it, 1);
            changed |= slp_try_to_vectorize_list(bundle);
        }
    }
    return changed;
}

// ---------------------------------------------------------------- canConvertToFMA

// canConvertToFMA(VL, S, DT, DL, TTI, TLI)
slp_can_convert_to_fma :: (vl: [] Value_Id, s: Inst_State) -> Cost {
    check_contractable :: (vl: [] Value_Id, s: Inst_State) -> bool {
        fmf: u32 = FMF_ALL;
        for v: vl {
            if !is_inst(v) continue;
            if is_copyable_element(s, v) continue;
            m := is_matching_main_or_alt(s, v);
            if s.main != m && s.alt != m continue;
            if is_fp_math_inst(v) fmf &= inst_fmf(v);
        }
        return (fmf & FMF_CONTRACT) != 0;
    }
    if !check_contractable(vl, s) return COST_INVALID;
    a: Ica_State;
    operands := ica_build_operands(*a, s, vl);
    ops_s := slp_get_same_opcode(operands[0]);
    if !is_valid(ops_s) return COST_INVALID;
    if is_alt_shuffle(ops_s) || is_opcode(ops_s) != .FMUL return COST_INVALID;
    if !check_contractable(operands[0], s) return COST_INVALID;   // LLVM checks the fmuls against the fadd state S (CheckForContractable captures S)
    fmul_plus_fadd: Cost = 0;
    fma_cost: Cost = 0;
    fmf: u32 = FMF_ALL;
    for v: vl {
        if !is_inst(v) continue;
        if !is_copyable_element(s, v) && is_fp_math_inst(v) fmf &= inst_fmf(v);
        fmul_plus_fadd = cost_add(fmul_plus_fadd, tti_instruction_cost(slp.tti, v, TCK_RECIP_THROUGHPUT));
    }
    num_ops := 0;
    for v, k: vl {
        if is_copyable_element(s, v) continue;
        i := operands[0][k];
        if !is_inst(i) || !has_one_use(i) || is_copyable_element(ops_s, i) {
            if is_inst(v) fma_cost = cost_add(fma_cost, tti_instruction_cost(slp.tti, v, TCK_RECIP_THROUGHPUT));
            if is_inst(i) fma_cost = cost_add(fma_cost, tti_instruction_cost(slp.tti, i, TCK_RECIP_THROUGHPUT));
            continue;
        }
        num_ops += 1;
        if is_fp_math_inst(i) fmf &= inst_fmf(i);
        fmul_plus_fadd = cost_add(fmul_plus_fadd, tti_instruction_cost(slp.tti, i, TCK_RECIP_THROUGHPUT));
    }
    ty := vtype(vl[0]);
    ica := ica_types(IID_FMULADD, ty, .[ty, ty, ty], fmf);
    fma_cost = cost_add(fma_cost, cost_mul(num_ops, tti_intrinsic_cost(slp.tti, *ica, TCK_RECIP_THROUGHPUT)));
    return ifx fma_cost < fmul_plus_fadd then fma_cost else COST_INVALID;
}
