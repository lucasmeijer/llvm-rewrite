// SLPVectorizer: transformNodes and reorderGatherNode. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::transformNodes, reorderGatherNode, TreeEntry::getOrdered) and canConvertToMinOrMaxIntrinsic
// (llvm/lib/Analysis/ValueTracking.cpp).
//
// X86 facts used: TTI::isLegalStridedLoadStore and isLegalInterleavedAccessType are the base `false`, so the
// load/store strided rewrites and the store interleave factor never apply. Not ported (fail loudly):
// matchesShlZExt (reduced bitcasts), matchesInversedZExtSelect,
// matchesSelectOfBits.

// TreeEntry::getOrdered(Idx)
te_get_ordered :: (te: Te_Id, idx: s64) -> Value_Id {
    e := *slp.entries[te];
    if e.reorder_indices.count == 0 return e.scalars[idx];
    m := slp_inverse_permutation(e.reorder_indices);
    return e.scalars[m[idx]];
}

// reorderGatherNode(TE)
slp_reorder_gather_node :: (te: Te_Id) {
    e := *slp.entries[te];
    if e.scalars.count == 2 || (te_has_state(te) && !is_alt_shuffle(e.s)) || slp_all_constant(e.scalars) return;
    for k: 0..te-1 if te_is_same(cast(Te_Id) k, e.scalars) return;
    st: Loads_Subkey_State;
    st.keys.allocator = temp; st.loads.allocator = temp; st.key_used.allocator = temp;
    // MapVector<Key, MapVector<SubKey, SmallVector<Value *>>> SortedValues
    Sub :: struct { sub: u64; vals: [..] Value_Id; }
    Grp :: struct { key: u64; subs: [..] Sub; }
    sorted: [..] Grp; sorted.allocator = temp;
    kti_keys: [..] Value_Id; kti_keys.allocator = temp;     // KeyToIndex
    kti_vals: [..] [..] u32; kti_vals.allocator = temp;
    kti_find :: (keys: [] Value_Id, v: Value_Id) -> s64 { for keys if it == v return it_index; return -1; }
    is_ordered := true;
    num_insts := 0;
    for v, i: e.scalars {
        key: u64 = 1; idx: u64 = 1;
        if is_inst(v) && !(inst_op(v) == .EXTRACTELEMENT || inst_op(v) == .LOAD || is_cast_op(inst_op(v))) && !slp_is_deleted(v) && !slp_is_vectorized(v) {
            key, idx = slp_generate_key_subkey(v, *st, false);
            num_insts += 1;
        }
        g: *Grp = null;
        for * sorted if it.key == key { g = it; break; }
        if !g { ng: Grp; ng.key = key; ng.subs.allocator = temp; array_add(*sorted, ng); g = *sorted[sorted.count - 1]; }
        c_idx := -1;
        for g.subs if it.sub == idx { c_idx = it_index; break; }
        if is_ordered && kti_find(kti_keys, v) < 0 && !(is_constant_kind(vkind(v)) || (is_inst(v) && inst_op(v) == .EXTRACTELEMENT) || slp_is_vector_like_inst_with_const_ops(v)) {
            last_of :: (keys: [] Value_Id, vals: [] [..] u32, v: Value_Id) -> u32 { l := vals[kti_find(keys, v)]; return l[l.count - 1]; }
            if c_idx >= 0 {
                cl := g.subs[c_idx].vals;
                if last_of(kti_keys, kti_vals, cl[cl.count - 1]) != cast(u32) (i - 1) is_ordered = false;
            } else if g.subs.count {
                bl := g.subs[g.subs.count - 1].vals;
                if last_of(kti_keys, kti_vals, bl[bl.count - 1]) != cast(u32) (i - 1) is_ordered = false;
            }
        }
        k := kti_find(kti_keys, v);
        if k < 0 {
            array_add(*kti_keys, v);
            l: [..] u32; l.allocator = temp;
            array_add(*kti_vals, l);
            k = kti_keys.count - 1;
            if c_idx < 0 { ns: Sub; ns.sub = idx; ns.vals.allocator = temp; array_add(*g.subs, ns); c_idx = g.subs.count - 1; }
            array_add(*g.subs[c_idx].vals, v);
        }
        array_add(*kti_vals[k], cast(u32) i);
    }
    Sv :: struct { idx: u32; sz: u32; }
    subvecs: [..] Sv; subvecs.allocator = temp;
    n := e.scalars.count;
    dem := NewArray(n, bool,, temp); for * dem it.* = true;
    if !is_ordered && num_insts > 1 {
        cnt: u32 = 0;
        array_reset_keeping_memory(*e.reorder_indices);
        for 1..n array_add(*e.reorder_indices, cast(u32) n);
        for d: sorted for p: d.subs {
            sz: u32 = 0;
            for v: p.vals {
                indices := kti_vals[kti_find(kti_keys, v)];
                for idx, kk: indices { e.reorder_indices[cnt + cast(u32) kk] = idx; e.scalars[cnt + cast(u32) kk] = v; }
                sz += cast(u32) indices.count;
                cnt += cast(u32) indices.count;
            }
            if sz > 1 && is_inst(p.vals[0]) {
                sub_vf := cast(u32) slp_floor_full_vector_number_of_elements(slp.tti, vtype(e.scalars[0]), sz);
                array_add(*subvecs, .{cnt - sz, sub_vf});
                for i: cnt-sz..cnt-sz+sub_vf-1 dem[i] = false;
            } else if p.vals.count && slp_is_constant(p.vals[0]) {
                for i: cnt-sz..cnt-1 dem[i] = false;
            }
        }
    }
    if e.reuse_shuffle_indices.count || e.reorder_indices.count == 0 return;
    cost: Cost = 0;
    sty := vtype(e.scalars[0]);
    vec_ty := slp_widened_type(sty, cast(u64) n);
    for sv: subvecs cost = cost_add(cost, slp_shuffle_cost(SK_INSERT_SUBVECTOR, vec_ty, .[], TCK_RECIP_THROUGHPUT, sv.idx, slp_widened_type(sty, sv.sz)));
    cost = cost_add(cost, slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT));
    rmask := new_mask();
    for e.reorder_indices array_add(*rmask, cast(s32) it);
    for i: 0..n-1 {
        v := te_get_ordered(te, i);
        if pm_poison(v) rmask[i] = PoisonMaskElem;
        else if slp_is_constant(v) || dem[i] rmask[i] = cast(s32) (i + e.reorder_indices.count);
    }
    two := false; for rmask if it >= n { two = true; break; }
    cost = cost_add(cost, slp_shuffle_cost(ifx two then SK_PERMUTE_TWO_SRC else SK_PERMUTE_SINGLE_SRC, vec_ty, rmask));
    for * dem it.* = true;
    for i: 0..n-1 {
        v := te_get_ordered(te, i);
        if slp_is_constant(v) { dem[i] = false; rmask[i] = ifx pm_poison(v) then PoisonMaskElem else cast(s32) i; }
        else rmask[i] = cast(s32) (i + n);
    }
    bv_cost := slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT);
    if !all_bits(dem) bv_cost = cost_add(bv_cost, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, vec_ty, rmask));
    if cost >= bv_cost {
        mask := new_mask(); for e.reorder_indices array_add(*mask, cast(s32) it);
        slp_reorder_scalars(*e.scalars, mask);
        array_reset_keeping_memory(*e.reorder_indices);
    }
}

// canConvertToMinOrMaxIntrinsic(VL): (intrinsic, all compares single use)
slp_can_convert_to_min_or_max_intrinsic :: (vl: [] Value_Id) -> (Intrinsic_Id, bool) {
    flavor := Select_Flavor.UNKNOWN;
    all_single := true;
    for v: vl {
        sp := match_select_pattern(v);
        if !spf_is_min_or_max(sp.flavor) return NOT_INTRINSIC, false;
        if flavor != .UNKNOWN && flavor != sp.flavor return NOT_INTRINSIC, false;
        flavor = sp.flavor;
        all_single &= is_inst(v) && inst_op(v) == .SELECT && has_one_use(op(v, 0));
    }
    if flavor == {
        case .SMIN; return IID_SMIN, all_single;
        case .UMIN; return IID_UMIN, all_single;
        case .SMAX; return IID_SMAX, all_single;
        case .UMAX; return IID_UMAX, all_single;
        case .FMAXNUM; return IID_MAXNUM, all_single;
        case .FMINNUM; return IID_MINNUM, all_single;
    }
    fatal("internal: unexpected select pattern flavor");
    return NOT_INTRINSIC, false;
}

// transformNodes()
slp_transform_nodes :: () {
    slpx.base_graph_size = cast(u32) slp.entries.count;
    slpx.is_graph_transform_mode = true;
    defer slpx.is_graph_transform_mode = false;
    base := cast(s64) slpx.base_graph_size;
    check_operands_profitability :: (i1: Value_Id, i2: Value_Id, s: Inst_State) -> bool {
        for k: 0..cast(s64) nops(s.main) - 1 {
            a := op(i1, cast(u32) k); b := op(i2, cast(u32) k);
            if is_constant_kind(vkind(a)) || is_constant_kind(vkind(b)) || a == b continue;
            idx := slp_find_best_root_pair(.[.[a, b]], LA_SCORE_SPLAT_LOADS);
            if idx < 0 return false;
        }
        return true;
    }
    for k: 0..base-1 if te_is_gather(cast(Te_Id) k) slp_reorder_gather_node(cast(Te_Id) k);
    VF_LIMIT :: 16;
    gl := 0;
    for k: 0..slp.entries.count-1 {
        t := cast(Te_Id) k;
        if te_is_gather(t) && te_has_state(t) && te_opcode(t) == .LOAD && te_vector_factor(t) < VF_LIMIT gl += 1;
    }
    force_load_gather := gl == 2;
    are_reused_scalars :: (t: Te_Id, vl: [] Value_Id, tes: [] Te_Id, split: bool) -> bool {
        if te_is_same(t, vl) return true;
        for v: vl {
            if pm_poison(v) continue;
            if !is_inst(v) return false;
            inn := false; for slp.entries[t].scalars if it == v { inn = true; break; }
            if inn continue;
            vtes := ifx split then slp_get_split_tree_entries(v) else slp_get_tree_entries(v);
            hit := false;
            for x: vtes for y: tes if x == y { hit = true; break; }
            if !hit return false;
        }
        return true;
    }
    check_for_same_vector_nodes :: (t: Te_Id) -> bool {
        e := *slp.entries[t];
        if te_has_state(t) {
            tes := slp_get_tree_entries(e.s.main);
            for x: tes if are_reused_scalars(x, e.scalars, tes, false) return true;
            stes := slp_get_split_tree_entries(e.s.main);
            for x: stes if are_reused_scalars(x, e.scalars, stes, true) return true;
        } else {
            for v: e.scalars {
                if !is_inst(v) continue;
                stes := slp_get_split_tree_entries(v);
                for x: stes if are_reused_scalars(x, e.scalars, stes, true) return true;
                break;
            }
        }
        return false;
    }
    for k: 0..base-1 {
        t := cast(Te_Id) k;
        if te_is_gather(t) {
            vl := slp.entries[k].scalars;
            sz := slp_get_vector_element_size(vl[0]);
            min_vf := slp_get_min_vf(2 * sz);
            skip := vl.count <= 2;
            if !skip for slpx.load_entries_to_vectorize if it == cast(u32) k { skip = true; break; }
            if !skip skip = !(!te_has_state(t) || te_opcode(t) == .LOAD || !slp_all_same_opcode(vl) || !slp_all_same_block(vl)) || slp_all_constant(vl) || slp_is_splat(vl);
            if !skip && force_load_gather && te_has_state(t) && te_opcode(t) == .LOAD skip = true;
            if !skip && check_for_same_vector_nodes(t) skip = true;
            if !skip {
                start: u64 = 0;
                end := cast(u64) vl.count;
                processed := NewArray(vl.count, bool,, temp);
                sty := vtype(vl[0]);
                vf := slp_floor_full_vector_number_of_elements(slp.tti, sty, cast(u64) vl.count - 1);
                while vf >= min_vf {
                    defer vf = slp_floor_full_vector_number_of_elements(slp.tti, sty, vf - 1);
                    if start + vf > end continue;
                    Slice :: struct { cnt: u64; sz: u64; }
                    slices: [..] Slice; slices.allocator = temp;
                    all_strided := true;
                    cnt := start;
                    while cnt < end {
                        defer cnt += vf;
                        slice_vf := min(vf, end - cnt);
                        if slice_vf <= 1 continue;
                        sl := array_view(vl, cast(s64) cnt, cast(s64) slice_vf);
                        if (processed[cnt] || slp_is_vectorized(sl[0])) && slp_get_same_values_tree_entry(sl[0], sl, true) == TE_NONE continue;
                        if slp_all_constant(sl) continue;
                        is_splat := slp_is_splat(sl);
                        two_reg_splat := true;
                        if is_splat && vf == 2 {
                            st := slp_get_value_type(sl[0]);
                            two_reg_splat = slp_number_of_parts(slp.tti, slp_widened_type(st, 2 * vf), st) == 2;
                        }
                        front_cnt := 0; for sl if it == sl[0] front_cnt += 1;
                        expected := ifx pm_undef_value(sl[0]) then cast(s64) slice_vf - 1 else 1;
                        if slices.count == 0 || !is_splat || !two_reg_splat || front_cnt == expected {
                            if is_splat continue;
                            s := slp_get_same_opcode(sl);
                            if !is_valid(s) || !slp_all_same_opcode(sl) || !slp_all_same_block(sl) || (is_opcode(s) == .LOAD && slp_are_known_non_vectorizable_loads(sl)) continue;
                            if vf == 2 {
                                main_cheap := -1;
                                is_main_cheap :: (c: *s64, s: Inst_State) -> bool {
                                    if c.* < 0 c.* = cast(s64) (tti_instruction_cost(slp.tti, s.main, TCK_RECIP_THROUGHPUT) < TCC_EXPENSIVE);
                                    return c.* == 1;
                                }
                                if (!slpx.has_user_ignore_list || slp.entries[k].idx != 0) && is_main_cheap(*main_cheap, s) {
                                    all_uv := true;
                                    for v: sl { if pm_poison(v) continue; if !slp_are_all_users_vectorized(v, true) { all_uv = false; break; } }
                                    if !all_uv continue;
                                }
                                if is_opcode(s) == .LOAD {
                                    res := slp_can_vectorize_loads(sl, sl[0]);
                                    all_strided &= res == LS_STRIDED || res == LS_SCATTER || res == LS_GATHER;
                                    if res == LS_SCATTER || res == LS_GATHER {
                                        if res == LS_GATHER {
                                            slp_register_non_vectorizable_loads(sl);
                                            if slpx.has_user_ignore_list && slp.entries[k].idx == 0 slp_analyzed_reduction_vals(sl);
                                        }
                                        continue;
                                    }
                                } else if is_opcode(s) == .EXTRACTELEMENT {
                                    continue;
                                } else if is_main_cheap(*main_cheap, s) {
                                    last: Value_Id = NONE;
                                    for < sl if is_inst(it) { last = it; break; }
                                    if !check_operands_profitability(s.main, last, s) continue;
                                }
                            }
                        }
                        array_add(*slices, .{cnt, slice_vf});
                    }
                    if vf == 2 && all_strided && slices.count > 2 continue;
                    for sl_: slices {
                        sl := array_view(vl, cast(s64) sl_.cnt, cast(s64) sl_.sz);
                        same_te := TE_NONE;
                        for v: sl if is_inst(v) { same_te = slp_get_same_values_tree_entry(v, sl); break; }
                        prev_size := slp.entries.count;
                        slp_build_tree_rec(sl, 0, .{t, EDGE_NONE});
                        if prev_size + 1 == slp.entries.count && same_te == TE_NONE && te_is_gather(cast(Te_Id) prev_size) &&
                           te_has_state(cast(Te_Id) prev_size) && te_opcode(cast(Te_Id) prev_size) != .EXTRACTELEMENT && !slp_is_splat(sl) {
                            if slpx.has_user_ignore_list && slp.entries[k].idx == 0 && vf == 2 slp_analyzed_reduction_vals(sl);
                            slp.entries.count -= 1;   // VectorizableTree.pop_back()
                            continue;
                        }
                        // AddCombinedNode(PrevSize, Cnt, Sz)
                        array_add(*slp.entries[k].combined_entries_with_indices, .[cast(u32) prev_size, cast(u32) sl_.cnt]);
                        for i: sl_.cnt..sl_.cnt+sl_.sz-1 processed[i] = true;
                        if start == sl_.cnt start = sl_.cnt + sl_.sz;
                        if end == sl_.cnt + sl_.sz end = sl_.cnt;
                    }
                }
                ek := *slp.entries[k];
                if ek.combined_entries_with_indices.count == 0 && ek.reorder_indices.count {
                    mask := new_mask(); for ek.reorder_indices array_add(*mask, cast(s32) it);
                    slp_reorder_scalars(*ek.scalars, mask);
                    array_reset_keeping_memory(*ek.reorder_indices);
                }
            }
        }
        if !te_has_state(t) continue;
        e := *slp.entries[k];
        o := te_opcode(t);
        if o == .SELECT {
            if e.state != TE_VECTORIZE continue;
            mm, select_only := slp_can_convert_to_min_or_max_intrinsic(e.scalars);
            if mm != NOT_INTRINSIC {
                e.combined_op = TE_MIN_MAX;
                cond := slp_get_operand_entry(t, 0);
                if select_only && slp.entries[cond].user_tree_index.user != TE_NONE && slp.entries[cond].state == TE_VECTORIZE
                    slp.entries[cond].state = TE_COMBINED_VECTORIZE;
                continue;
            }
            for v: e.scalars if is_inst(v) && inst_op(v) == .ZEXT { slp_fail("matchesInversedZExtSelect"); break; }
            if slpx.has_user_ignore_list && e.idx == 0 slp_fail("matchesSelectOfBits");
        } else if o == .FSUB || o == .FADD {
            if e.state != TE_VECTORIZE || !is_add_sub_like_op(e.s) || is_alt_shuffle(e.s) continue;
            lhs := slp_get_operand_entry(t, 0);
            rhs := slp_get_operand_entry(t, 1);
            is_one_use_fmul :: (x: Te_Id) -> bool {
                xe := *slp.entries[x];
                if !(xe.state == TE_VECTORIZE && xe.reorder_indices.count == 0 && xe.reuse_shuffle_indices.count == 0 && te_opcode(x) == .FMUL && !is_alt_shuffle(xe.s)) return false;
                for v: xe.scalars if !((slp_te_has_copyables(x) && slp_te_is_copyable(x, v)) || has_one_use(v)) return false;
                return true;
            }
            if !is_one_use_fmul(lhs) && (o == .FSUB || !is_one_use_fmul(rhs)) continue;
            if !cost_valid(slp_can_convert_to_fma(e.scalars, e.s)) continue;
            e.combined_op = TE_FMULADD;
            fm := slp_get_operand_entry(t, 0);
            if slp.entries[fm].user_tree_index.user != TE_NONE && slp.entries[fm].state == TE_VECTORIZE slp.entries[fm].state = TE_COMBINED_VECTORIZE;
        } else if o == .SHL {
            if e.idx != 0 || !slpx.has_user_ignore_list continue;
            all_disjoint := true;
            for v: slpx.user_ignore_list if !(is_inst(v) && inst_op(v) == .OR && (inst(v).flags & F_EXACT) != 0) { all_disjoint = false; break; }
            if !all_disjoint continue;
            slp_fail("matchesShlZExt (reduced bitcasts)");
        }
    }
    if slpx.load_entries_to_vectorize.count == 0 {
        if slp.entries.count <= 1 && te_has_state(0) && te_opcode(0) == .LOAD return;
        SMALL_TREE :: 3; SMALL_VF :: 2;
        if (slp.entries.count <= SMALL_TREE && slp.entries[0].scalars.count == SMALL_VF) || (slp.entries.count <= 2 && slpx.has_user_ignore_list) return;
        if !has_single_bit(cast(u64) slp.entries[0].scalars.count) && slp_canonical_graph_size() != cast(u32) slp.entries.count && slpx.has_user_ignore_list &&
           slp_canonical_graph_size() <= SMALL_TREE {
            c := 0;
            for k: cast(s64) slp_canonical_graph_size()..slp.entries.count-1 {
                t := cast(Te_Id) k;
                if te_is_gather(t) && te_has_state(t) && te_opcode(t) == .LOAD && !slp_all_same_block(slp.entries[k].scalars) c += 1;
            }
            if c == 1 return;
        }
    }
    slp_collect_and_vectorize_gathered_loads();
}
