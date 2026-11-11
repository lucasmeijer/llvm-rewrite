// SLPVectorizer: graph reordering and the gather-shuffle analysis it shares with the cost model. Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (isProfitableToReorder, reorderTopToBottom,
// reorderBottomToTop, buildReorderableOperands, getReorderingData, findReusedOrderedScalars,
// findPartiallyOrderedLoads + clusterSortPtrAccesses, collectUserStores / canFormVector /
// findExternalStoreUsersReorderIndices, reorderNodeWithReuses, TreeEntry::reorderSplitNode / reorderOperands /
// buildAltOpShuffleMask / getCommonMask / findLaneForValue, combineOrders, reorderOrder, reorderReuses,
// tryToGatherExtractElements, isGatherShuffledEntry / isGatherShuffledSingleRegisterEntry,
// getLastInstructionInBundle) and ShuffleVectorInst::isOneUseSingleSourceMask (llvm/lib/IR/Instructions.cpp).
//
// The PriorityQueue of reorderBottomToTop is a binary heap with libstdc++'s push_heap / pop_heap, because
// entries with the same user compare equal and the pop order of equal elements decides OrdersUses' insertion
// order (the tie-break of the best order).

Order :: [..] u32;
new_order :: (n: s64 = 0, fill: u32 = 0) -> [..] u32 { r: [..] u32; r.allocator = temp; for 1..n array_add(*r, fill); return r; }
order_copy :: (o: [] u32) -> [..] u32 { r := new_order(); array_add(*r, ..o); return r; }
new_mask :: (n: s64 = 0, fill: s32 = PoisonMaskElem) -> [..] s32 { r: [..] s32; r.allocator = temp; for 1..n array_add(*r, fill); return r; }
mask_copy :: (o: [] s32) -> [..] s32 { r := new_mask(); array_add(*r, ..o); return r; }
orders_equal :: (a: [] u32, b: [] u32) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}

// BoUpSLP::isIdentityOrder
slp_is_identity_order :: (o: [] u32) -> bool {
    sz := cast(u32) o.count;
    for o if it != cast(u32) it_index && it != sz return false;
    return true;
}
// isReverseOrder
slp_is_reverse_order :: (o: [] u32) -> bool {
    sz := cast(u32) o.count;
    for o if it != sz && it != sz - cast(u32) it_index - 1 return false;
    return true;
}
// ShuffleVectorInst::isOneUseSingleSourceMask(Mask, VF)
svm_is_one_use_single_source :: (mask: [] s32, vf: s64) -> bool {
    if vf <= 0 || mask.count < vf || mask.count % vf != 0 return false;
    k := 0;
    while k < mask.count {
        defer k += vf;
        all_poison := true;
        for j: 0..vf-1 if mask[k + j] != PoisonMaskElem { all_poison = false; break; }
        if all_poison continue;
        used := NewArray(vf, bool,, temp);
        for j: 0..vf-1 { idx := mask[k + j]; if idx != PoisonMaskElem && idx < vf used[idx] = true; }
        if !all_bits(used) return false;
    }
    return true;
}

// reorderReuses(Reuses, Mask)
slp_reorder_reuses :: (reuses: *[..] s32, mask: [] s32) {
    prev := mask_copy(reuses.*);
    for i: 0..prev.count-1 if mask[i] != PoisonMaskElem reuses.*[mask[i]] = prev[i];
}
// reorderOrder(Order, Mask, BottomOrder)
slp_reorder_order :: (order: *[..] u32, mask: [] s32, bottom_order := false) {
    sz := mask.count;
    if bottom_order {
        prev: [..] u32;
        if order.count == 0 { prev = new_order(); for i: 0..sz-1 array_add(*prev, cast(u32) i); }
        else prev = order_copy(order.*);
        array_reset_keeping_memory(order);
        for 1..sz array_add(order, cast(u32) sz);
        for i: 0..sz-1 if mask[i] != PoisonMaskElem order.*[i] = prev[mask[i]];
        all := true;
        for order.* if it != cast(u32) sz && it != cast(u32) it_index { all = false; break; }
        if all { array_reset_keeping_memory(order); return; }
        slp_fixup_ordering_indices(order.*);
        return;
    }
    mask_order: [..] s32;
    if order.count == 0 { mask_order = new_mask(); for i: 0..sz-1 array_add(*mask_order, cast(s32) i); }
    else mask_order = slp_inverse_permutation(order.*);
    slp_reorder_reuses(*mask_order, mask);
    if svm_is_identity(mask_order, sz) { array_reset_keeping_memory(order); return; }
    array_reset_keeping_memory(order);
    for 1..sz array_add(order, cast(u32) sz);
    for i: 0..sz-1 if mask_order[i] != PoisonMaskElem order.*[mask_order[i]] = cast(u32) i;
    slp_fixup_ordering_indices(order.*);
}
// combineOrders(Order, SecondaryOrder)
slp_combine_orders :: (order: [] u32, secondary: [] u32) {
    sz := order.count;
    used := NewArray(sz, bool,, temp);
    for i: 0..sz-1 if order[i] != cast(u32) sz used[order[i]] = true;
    if secondary.count == 0 {
        for i: 0..sz-1 if order[i] == cast(u32) sz && !used[i] order[i] = cast(u32) i;
    } else {
        for i: 0..sz-1 if secondary[i] != cast(u32) sz && order[i] == cast(u32) sz && !used[secondary[i]] order[i] = secondary[i];
    }
}

// TreeEntry::getCommonMask
te_common_mask :: (te: Te_Id) -> [..] s32 {
    e := *slp.entries[te];
    if e.state == TE_SPLIT_VECTORIZE return new_mask();
    m := slp_inverse_permutation(e.reorder_indices);
    slp_add_mask(*m, e.reuse_shuffle_indices);
    return m;
}
// TreeEntry::reorderOperands(Mask)
te_reorder_operands :: (te: Te_Id, mask: [] s32) {
    for * o: slp.entries[te].operands slp_reorder_scalars(o, mask);
}
// TreeEntry::reorderSplitNode(Idx, Mask, MaskOrder)
te_reorder_split_node :: (te: Te_Id, idx: u32, mask: [] s32, mask_order: [] s32) {
    e := *slp.entries[te];
    vf := te_vector_factor(te);
    nm := new_mask(); nmo := new_mask();
    for i: 0..vf-1 { array_add(*nm, cast(s32) i); array_add(*nmo, cast(s32) i); }
    if idx == 0 {
        for mask nm[it_index] = it;
        for mask_order nmo[it_index] = it;
    } else {
        off := cast(s32) e.combined_entries_with_indices[e.combined_entries_with_indices.count - 1][1];
        for i: 0..mask.count-1 { nm[i + off] = mask[i] + off; nmo[i + off] = mask_order[i] + off; }
    }
    slp_reorder_scalars(*e.scalars, nm);
    slp_reorder_order(*e.reorder_indices, nmo, true);
    if e.reorder_indices.count && slp_is_identity_order(e.reorder_indices) array_reset_keeping_memory(*e.reorder_indices);
}
// TreeEntry::findLaneForValue(V). The ValueToLane cache is never invalidated, so a lane computed before the entry
// was reordered stays the answer (LLVM does the same; it changes gather masks).
te_find_lane_for_value :: (te: Te_Id, v: Value_Id) -> u32 {
    e := *slp.entries[te];
    cached, lane := table_find(*e.value_to_lane, v);
    if cached return lane;
    found := slp_find_lane_uncached(te, v);
    table_set(*e.value_to_lane, v, found);
    return found;
}
slp_find_lane_uncached :: (te: Te_Id, v: Value_Id) -> u32 {
    e := *slp.entries[te];
    found := cast(u32) te_vector_factor(te);
    for k: 0..e.scalars.count-1 {
        if e.scalars[k] != v continue;
        found = cast(u32) k;
        if e.reorder_indices.count found = e.reorder_indices[found];
        if e.reuse_shuffle_indices.count == 0 break;
        hit := false;
        for r, ri: e.reuse_shuffle_indices if r == cast(s32) found { found = cast(u32) ri; hit = true; break; }
        if hit break;
    }
    return found;
}
// TreeEntry::buildAltOpShuffleMask(IsAltOp, Mask) with IsAltOp = isAlternateInstruction(I, MainOp, AltOp)
te_build_alt_op_shuffle_mask :: (te: Te_Id) -> ([..] s32, [..] Value_Id, [..] Value_Id) {
    e := *slp.entries[te];
    sz := e.scalars.count;
    mask := new_mask(sz);
    op_scalars: [..] Value_Id; op_scalars.allocator = temp;
    alt_scalars: [..] Value_Id; alt_scalars.allocator = temp;
    order_mask: [..] s32;
    if e.reorder_indices.count order_mask = slp_inverse_permutation(e.reorder_indices);
    for i: 0..sz-1 {
        idx := i;
        if e.reorder_indices.count idx = order_mask[i];
        if pm_poison(e.scalars[idx]) continue;
        x := e.scalars[idx];
        if slp_is_alternate_instruction(x, e.s.main, e.s.alt) { mask[i] = cast(s32) (sz + idx); array_add(*alt_scalars, x); }
        else { mask[i] = cast(s32) idx; array_add(*op_scalars, x); }
    }
    if e.reuse_shuffle_indices.count {
        nm := new_mask();
        for e.reuse_shuffle_indices array_add(*nm, ifx it != PoisonMaskElem then mask[it] else PoisonMaskElem);
        mask = nm;
    }
    return mask, op_scalars, alt_scalars;
}

// isProfitableToReorder
slp_is_profitable_to_reorder :: () -> bool {
    if slp_cl.disable_tree_reorder return false;
    TINY_VF :: 2; TINY_TREE :: 10; PHI_OPS_LIMIT :: 12; GATHER_LOADS_LIMIT :: 2;
    n := slp.entries.count;
    if n <= TINY_TREE return true;
    f := cast(Te_Id) 0;
    fe := *slp.entries[0];
    if te_has_state(f) && !te_is_gather(f) &&
       (te_opcode(f) == .STORE || te_opcode(f) == .PHI || (te_vector_factor(f) <= TINY_VF && (te_opcode(f) == .PTRTOINT || te_opcode(f) == .ICMP))) &&
       fe.reorder_indices.count == 0 {
        if te_opcode(f) == .PHI && fe.scalars.count == TINY_VF && fe.operands.count > PHI_OPS_LIMIT return false;
        if te_opcode(f) == .STORE && fe.reorder_indices.count == 0 {
            splits := 0;
            for * te: slp.entries {
                u := te.user_tree_index.user;
                if te.state == TE_SPLIT_VECTORIZE && te.reorder_indices.count && u != TE_NONE && slp.entries[u].state == TE_VECTORIZE &&
                   slp_is_commutative(slp.entries[u].s.main) splits += 1;
            }
            cnt := 0;
            for * te, k: slp.entries {
                t := cast(Te_Id) k;
                u := te.user_tree_index.user;
                c1 := (!te_is_gather(t) && (te.reorder_indices.count == 0 || (u != TE_NONE && slp.entries[u].state == TE_VECTORIZE && slp.entries[u].reuse_shuffle_indices.count))) ||
                      (te_is_gather(t) && te.reorder_indices.count == 0 && (!te_has_state(t) || is_alt_shuffle(te.s) || te_opcode(t) == .LOAD || te_opcode(t) == .ZEXT || te_opcode(t) == .SEXT));
                if !c1 continue;
                c2 := te_vector_factor(f) > TINY_VF || !te_is_gather(t);
                if !c2 {
                    c2 = true;
                    for v: te.scalars if !slp_is_constant(v) && slp_is_vectorized(v) { c2 = false; break; }
                }
                if c2 cnt += 1;
            }
            if splits <= 1 && cnt >= n - splits return false;
        }
        has_phis := false;
        has_load := true;
        gather_loads := 0;
        for k: 1..n-1 {
            t := cast(Te_Id) k;
            te := *slp.entries[k];
            if te.state == TE_SPLIT_VECTORIZE continue;
            if !te_has_state(t) {
                all_cp := true; for te.scalars if !(is_constant_kind(vkind(it)) || (is_inst(it) && inst_op(it) == .PHI)) { all_cp = false; break; }
                all_bp := true; for te.scalars if !(is_inst(it) && (is_binary_op(inst_op(it)) || inst_op(it) == .PHI)) { all_bp = false; break; }
                if all_cp || all_bp continue;
                if fe.scalars.count == TINY_VF {
                    any := false;
                    for te.scalars if (is_inst(it) && inst_op(it) == .PHI) || slp_is_gep_operator(it) { any = true; break; }
                    if any continue;
                }
                return true;
            }
            o := te_opcode(t);
            if o == .LOAD && te.reorder_indices.count == 0 {
                if !te_is_gather(t) { has_load = false; continue; }
                if has_load return true;
                gather_loads += 1;
                if gather_loads >= GATHER_LOADS_LIMIT return true;
            }
            if o == .GEP || is_binary_op(o) continue;
            phis := 0; for te.scalars if is_inst(it) && inst_op(it) == .PHI phis += 1;
            if o != .PHI && (!slp_te_has_copyables(t) || phis < te.scalars.count / 2) return true;
            if fe.scalars.count == TINY_VF && te.operands.count > PHI_OPS_LIMIT return false;
            has_phis = true;
        }
        return !has_phis;
    }
    return true;
}
slp_is_gep_operator :: (v: Value_Id) -> bool {
    if is_inst(v) return inst_op(v) == .GEP;
    return vkind(v) == .C_EXPR && cexpr(v).op == .GEP;
}

// ---------------------------------------------------------------- external store users

// collectUserStores(TE)
slp_collect_user_stores :: (te: Te_Id) -> [..] [..] Value_Id {
    Group :: struct { bb: Value_Id; ty: Type_Id; ptr: Value_Id; stores: [..] Value_Id; }
    groups: [..] Group; groups.allocator = temp;
    e := *slp.entries[te];
    for lane: 0..e.scalars.count-1 {
        v := e.scalars[lane];
        if !is_inst(v) continue;
        if has_n_uses_or_more(v, SLP_USES_LIMIT) break;
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u]; u = ir.u_next[u];
            if !is_inst(usr) || inst_op(usr) != .STORE || !is_simple_load_store(usr) || inst_fn(usr) != slpx.f ||
               !slp_is_valid_element_type(vtype(op(usr, 0)))
                continue;
            if slp_is_vectorized(usr) continue;
            ptr := get_underlying_object(op(usr, 1), cast(u32) slp_cl.recursion_max_depth);
            g: *Group = null;
            for * groups if it.bb == inst_block(usr) && it.ty == vtype(op(usr, 0)) && it.ptr == ptr { g = it; break; }
            if !g {
                ng: Group; ng.bb = inst_block(usr); ng.ty = vtype(op(usr, 0)); ng.ptr = ptr;
                array_add(*groups, ng);
                g = *groups[groups.count - 1];
                g.stores.allocator = temp;
            }
            if g.stores.count > lane continue;
            if g.stores.count {
                ok := get_pointers_diff(vtype(op(usr, 0)), op(usr, 1), vtype(op(usr, 0)), op(g.stores[0], 1), true);
                if !ok continue;
            }
            array_add(*g.stores, usr);
        }
    }
    res: [..] [..] Value_Id; res.allocator = temp;
    for groups array_add(*res, it.stores);
    return res;
}
// canFormVector(StoresVec, ReorderIndices)
slp_can_form_vector :: (stores: [] Value_Id) -> (bool, [..] u32) {
    order := new_order();
    offs: [..] [2] s64; offs.allocator = temp;
    s0 := stores[0];
    array_add(*offs, .[0, 0]);
    for idx: 1..stores.count-1 {
        si := stores[idx];
        _, d := get_pointers_diff(vtype(op(s0, 0)), op(s0, 1), vtype(op(si, 0)), op(si, 1), true);
        array_add(*offs, .[d, idx]);
    }
    // sort(less_first): equal distances make the chain invalid below, so the order among them does not matter
    for i: 1..offs.count-1 { x := offs[i]; j := i; while j > 0 && x[0] < offs[j-1][0] { offs[j] = offs[j-1]; j -= 1; } offs[j] = x; }
    prev: s64 = 0;
    for p, idx: offs {
        if idx > 0 && p[0] != prev + 1 return false, order;
        prev = p[0];
    }
    for 1..stores.count array_add(*order, 0);
    identity := true;
    for p, i: offs { order[p[1]] = cast(u32) i; identity &= p[1] == i; }
    if identity array_reset_keeping_memory(*order);
    return true, order;
}
// findExternalStoreUsersReorderIndices(TE)
slp_find_external_store_users_reorder_indices :: (te: Te_Id) -> [..] [..] u32 {
    n := slp.entries[te].scalars.count;
    res: [..] [..] u32; res.allocator = temp;
    for sv: slp_collect_user_stores(te) {
        if sv.count != n continue;
        ok, order := slp_can_form_vector(sv);
        if !ok continue;
        array_add(*res, order);
    }
    // PtrToStoresMap is a DenseMap keyed by pointers: with several qualifying groups the order of this list
    // (and so the tie-break between equally used orders) depends on hash order
    if res.count > 1 for res if !orders_equal(it, res[0]) slp_fail("several external store groups with different orders (DenseMap order)");
    return res;
}

// ---------------------------------------------------------------- clusterSortPtrAccesses / findPartiallyOrderedLoads

slp_cluster_sort_ptr_accesses :: (vl: [] Value_Id, bbs: [] Value_Id, elem_ty: Type_Id) -> (bool, [..] u32) {
    sorted := new_order();
    Item :: struct { ptr: Value_Id; off: s64; idx: u32; }
    Base :: struct { bb: Value_Id; obj: Value_Id; vecs: [..] [..] Item; }
    bases: [..] Base; bases.allocator = temp;
    depth := cast(u32) slp_cl.recursion_max_depth;
    find_base :: (bases: *[..] Base, bb: Value_Id, obj: Value_Id) -> *Base {
        for * bases.* if it.bb == bb && it.obj == obj return it;
        nb: Base; nb.bb = bb; nb.obj = obj;
        array_add(bases, nb);
        b := *bases.*[bases.count - 1];
        b.vecs.allocator = temp;
        return b;
    }
    new_vec :: (b: *Base, it: Item) {
        v: [..] Item; v.allocator = temp;
        array_add(*v, it);
        array_add(*b.vecs, v);
    }
    new_vec(find_base(*bases, bbs[0], get_underlying_object(vl[0], depth)), .{vl[0], 0, 0});
    for cnt: 0..vl.count-2 {
        ptr := vl[cnt + 1];
        b := find_base(*bases, bbs[cnt + 1], get_underlying_object(ptr, depth));
        found := false;
        for * v: b.vecs {
            ok, d := get_pointers_diff(elem_ty, v.*[0].ptr, elem_ty, ptr, true);
            if !ok continue;
            array_add(v, .{ptr, d, cast(u32) (cnt + 1)});
            found = true;
            break;
        }
        if !found {
            if bases.count > vl.count / 2 - 1 return false, sorted;
            new_vec(b, .{ptr, 0, cast(u32) (cnt + 1)});
        }
    }
    if bases.count == vl.count return false, sorted;
    if bases.count == 1 && (bases[0].vecs.count == 1 || bases[0].vecs.count == vl.count) return false, sorted;
    compare_pointers :: (p1_in: Value_Id, p2_in: Value_Id) -> bool {
        first: [..] Value_Id; first.allocator = temp;
        second: [..] Value_Id; second.allocator = temp;
        contains :: (l: [] Value_Id, v: Value_Id) -> bool { for l if it == v return true; return false; }
        p1 := p1_in; p2 := p2_in;
        depth := 0;
        while !contains(first, p2) && !contains(second, p1) {
            if p1 == p2 || depth > slp_cl.recursion_max_depth return false;
            array_add(*first, p1); array_add(*second, p2);
            p1 = get_underlying_object(p1, 1);
            p2 = get_underlying_object(p2, 1);
            depth += 1;
        }
        return contains(first, p2) && !contains(second, p1);
    }
    for * b: bases {
        for * v: b.vecs {
            if v.count > 1 {
                // stable_sort(less_second)
                for i: 1..v.count-1 { x := v.*[i]; j := i; while j > 0 && x.off < v.*[j-1].off { v.*[j] = v.*[j-1]; j -= 1; } v.*[j] = x; }
                init := v.*[0].off;
                for p, k: v.* if p.off != k + init return false, sorted;
            }
        }
        // stable_sort(Base.second, ComparePointers on the fronts)
        n := b.vecs.count;
        for i: 1..n-1 {
            x := b.vecs[i]; j := i;
            while j > 0 && compare_pointers(x[0].ptr, b.vecs[j-1][0].ptr) { b.vecs[j] = b.vecs[j-1]; j -= 1; }
            b.vecs[j] = x;
        }
    }
    for b: bases for v: b.vecs for p: v array_add(*sorted, p.idx);
    return true, sorted;
}
// findPartiallyOrderedLoads(TE)
slp_find_partially_ordered_loads :: (te: Te_Id) -> (bool, [..] u32) {
    e := *slp.entries[te];
    sty := vtype(e.scalars[0]);
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    bbs: [..] Value_Id; bbs.allocator = temp;
    for v: e.scalars {
        if !is_inst(v) || inst_op(v) != .LOAD || !is_simple_load_store(v) return false, new_order();
        array_add(*ptrs, op(v, 0));
        array_add(*bbs, inst_block(v));
    }
    for slpx.load_entries_to_vectorize if it == cast(u32) e.idx return false, new_order();
    ok, order := slp_cluster_sort_ptr_accesses(ptrs, bbs, sty);
    return ok, order;
}

// ---------------------------------------------------------------- getReorderingData

slp_get_reordering_data :: (te: Te_Id, top_to_bottom: bool, ignore_reorder: bool) -> (bool, [..] u32) {
    e := *slp.entries[te];
    none := new_order();
    if e.reuse_shuffle_indices.count {
        if slp_is_splat(e.scalars) return false, none;
        sz := e.scalars.count;
        if te_is_gather(te) {
            ok, cur := slp_find_reused_ordered_scalars(te, top_to_bottom, ignore_reorder);
            if ok {
                slp_fixup_ordering_indices(cur);
                mask := slp_inverse_permutation(cur);
                slp_add_mask(*mask, e.reuse_shuffle_indices);
                vf := te_vector_factor(te);
                res := new_order(vf, cast(u32) vf);
                k := 0;
                while k < vf / sz {
                    for i: 0..sz-1 { idx := mask[k * sz + i]; if idx != PoisonMaskElem res[idx + k * sz] = cast(u32) (i + k * sz); }
                    k += 1;
                }
                return true, res;
            }
        }
        sty := slp_get_value_type(e.scalars[0]);
        if sz == 2 && te_vector_factor(te) == 4 && slp_number_of_parts(slp.tti, slp_widened_type(sty, cast(u64) (2 * te_vector_factor(te))), sty) == 1 return false, none;
        if e.reuse_shuffle_indices.count % sz != 0 return false, none;
        if !svm_is_one_use_single_source(e.reuse_shuffle_indices, sz) {
            reorder_mask: [..] s32;
            if e.reorder_indices.count == 0 { reorder_mask = new_mask(); for i: 0..sz-1 array_add(*reorder_mask, cast(s32) i); }
            else reorder_mask = slp_inverse_permutation(e.reorder_indices);
            slp_add_mask(*reorder_mask, e.reuse_shuffle_indices);
            vf := reorder_mask.count;
            res := new_order(vf, cast(u32) vf);
            num_parts := cast(s64) divide_ceil(cast(u64) vf, cast(u64) sz);
            used := NewArray(num_parts, bool,, temp);
            i := 0;
            while i < vf {
                defer i += sz;
                val: s32 = PoisonMaskElem;
                undef_cnt := 0;
                limit := min(sz, vf - i);
                bad := false;
                for j: 0..limit-1 {
                    idx := reorder_mask[i + j];
                    if val == PoisonMaskElem && idx != PoisonMaskElem val = idx;
                    if idx == PoisonMaskElem undef_cnt += 1;
                    if idx != PoisonMaskElem && idx != val { bad = true; break; }
                }
                if bad || val >= num_parts || val == PoisonMaskElem || used[val] || undef_cnt > sz / 2 return false, none;
                used[val] = true;
                for kk: 0..num_parts-1 {
                    idx := val + sz * kk;
                    if idx < vf && i + kk < vf res[idx] = cast(u32) (i + kk);
                }
            }
            return true, res;
        }
        vf := te_vector_factor(te);
        reused := mask_copy(e.reuse_shuffle_indices);
        if te_has_state(te) && te_opcode(te) == .EXTRACTELEMENT {
            all := true;
            for v: e.scalars {
                if pm_poison(v) continue;
                ok, idx := slp_extract_index(v);
                if !ok || idx >= cast(u64) sz { all = false; break; }
            }
            if all {
                reorder_mask: [..] s32;
                if e.reorder_indices.count == 0 { reorder_mask = new_mask(); for i: 0..sz-1 array_add(*reorder_mask, cast(s32) i); }
                else reorder_mask = slp_inverse_permutation(e.reorder_indices);
                for i: 0..vf-1 {
                    idx := reused[i];
                    if idx == PoisonMaskElem continue;
                    v := e.scalars[reorder_mask[idx]];
                    _, ei := slp_extract_index(v);
                    pos := 0; while pos < reorder_mask.count && reorder_mask[pos] != cast(s32) ei pos += 1;
                    reused[i] = cast(s32) pos;
                }
            }
        }
        res := new_order();
        for i: 0..vf-1 array_add(*res, cast(u32) i);
        k := 0;
        while k < vf {
            cur := order_copy(e.reorder_indices);
            sub := new_mask();
            for j: 0..sz-1 array_add(*sub, reused[k + j]);
            if sub[0] == PoisonMaskElem for j: 0..sz-1 sub[j] = cast(s32) j;
            slp_reorder_order(*cur, sub);
            for pos, j: cur res[k + j] = pos + cast(u32) k;
            k += sz;
        }
        if te_is_gather(te) {
            ident := true;
            for res if it != cast(u32) it_index { ident = false; break; }
            if ident return false, none;
        }
        return true, res;
    }
    u := e.user_tree_index.user;
    if e.state == TE_STRIDED_VECTORIZE && !top_to_bottom && (u == TE_NONE || !te_has_state(u) || !is_binary_op(te_opcode(u))) &&
       (e.reorder_indices.count == 0 || slp_is_reverse_order(e.reorder_indices)) return false, none;
    vec_state := e.state == TE_VECTORIZE || e.state == TE_STRIDED_VECTORIZE || e.state == TE_EXPAND_VECTORIZE || e.state == TE_COMPRESS_VECTORIZE;
    if e.state == TE_SPLIT_VECTORIZE {
        return true, order_copy(e.reorder_indices);
    }
    if vec_state {
        mo := inst_op(e.s.main);
        if mo == .LOAD || mo == .EXTRACTELEMENT || mo == .EXTRACTVALUE || (top_to_bottom && (mo == .STORE || mo == .INSERTELEMENT || mo == .INSERTVALUE))
            return true, order_copy(e.reorder_indices);
    }
    if !top_to_bottom && ignore_reorder && e.state == TE_VECTORIZE && is_alt_shuffle(e.s) {
        mask := te_build_alt_op_shuffle_mask(te);
        vf := te_vector_factor(te);
        res := new_order(vf, cast(u32) vf);
        for i: 0..vf-1 { if mask[i] == PoisonMaskElem continue; res[mask[i] % vf] = cast(u32) i; }
        return true, res;
    }
    if e.reorder_indices.count return true, order_copy(e.reorder_indices);
    if e.state == TE_VECTORIZE && te_opcode(te) == .PHI {
        n := e.scalars.count;
        bv_head := NewArray(n, Value_Id,, temp);
        for v, i: e.scalars {
            bv_head[i] = NONE;
            if is_constant_kind(vkind(v)) || !has_uses(v) continue;
            ii := ir.u_user[ir.v_first_use[v]];
            if !is_inst(ii) || inst_op(ii) != .INSERTELEMENT continue;
            head: Value_Id = NONE;
            bb := inst_block(ii);
            while ii != NONE && has_one_use(ii) && inst_block(ii) == bb {
                head = ii;
                nx := op(ii, 0);
                ii = ifx is_inst(nx) && inst_op(nx) == .INSERTELEMENT then nx else NONE;
            }
            bv_head[i] = head;
        }
        slpx.phi_cmp_te = te;
        slpx.phi_cmp_heads = bv_head;
        phis := new_order();
        for i: 0..n-1 array_add(*phis, cast(u32) i);
        gnu_stable_sort(phis, slp_reorder_phi_compare);
        if slp_is_identity_order(phis) return false, none;
        return true, phis;
    }
    if te_is_gather(te) && (!te_has_state(te) || !is_alt_shuffle(e.s) || table_contains(*slpx.scalars_in_split_nodes, e.s.main)) && slp_all_same_type(e.scalars) {
        all_ee := true; any_ee := false;
        for v: e.scalars {
            is_ee := is_inst(v) && inst_op(v) == .EXTRACTELEMENT;
            any_ee |= is_ee;
            if !(is_ee || pm_undef_value(v)) all_ee = false;
        }
        all_fixed := true;
        for v: e.scalars if is_inst(v) && inst_op(v) == .EXTRACTELEMENT && type_kind(vtype(op(v, 0))) != .VECTOR { all_fixed = false; break; }
        if ((te_has_state(te) && te_opcode(te) == .EXTRACTELEMENT) || (all_ee && any_ee)) && all_fixed {
            cur := new_order();
            reuse_ok := slp_can_reuse_extract(e.scalars, *cur, true);
            if reuse_ok || cur.count return true, cur;
        }
        sz := e.scalars.count;
        undefs := 0; for e.scalars if pm_undef_value(it) undefs += 1;
        if slp_is_splat(e.scalars) && !slp_all_constant(e.scalars) && undefs == sz - 1 {
            pos := -1;
            for v, k: e.scalars if !slp_is_constant(v) { pos = k; break; }
            if pos == 0 return true, new_order();
            ty := slp_widened_type(vtype(e.scalars[0]), cast(u64) sz);
            if pos >= 0 {
                order := new_order(sz, cast(u32) sz);
                order[pos] = 0;
                slp_fixup_ordering_indices(order);
                mask := slp_inverse_permutation(order);
                permute: Cost = ifx top_to_bottom then 0 else slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, ty, mask);
                first := tti_vector_instr_cost(slp.tti, .INSERTELEMENT, ty, TCK_RECIP_THROUGHPUT, 0, const_poison(ty), e.scalars[pos]);
                at_idx := tti_vector_instr_cost(slp.tti, .INSERTELEMENT, ty, TCK_RECIP_THROUGHPUT, cast(u32) pos, const_poison(ty), e.scalars[pos]);
                if cost_add(first, permute) < at_idx {
                    o2 := new_order(sz, cast(u32) sz);
                    o2[pos] = 0;
                    return true, o2;
                }
            }
        }
        if slp_is_splat(e.scalars) return false, none;
        if e.scalars.count >= 3 {
            ok, order := slp_find_partially_ordered_loads(te);
            if ok return true, order;
        }
        if te_has_state(te) && te_opcode(te) == .LOAD {
            cur := new_order();
            st := slp_can_vectorize_loads(e.scalars, e.scalars[0], *cur);
            if st == LS_VECTORIZE || st == LS_STRIDED || st == LS_COMPRESS return true, cur;
        }
        ok, cur := slp_find_reused_ordered_scalars(te, top_to_bottom, ignore_reorder);
        if ok return true, cur;
    }
    return false, none;
}

// the PHICompare of getReorderingData
slp_reorder_phi_compare :: (i1: u32, i2: u32) -> bool {
    e := *slp.entries[slpx.phi_cmp_te];
    heads := slpx.phi_cmp_heads;
    v1 := e.scalars[i1]; v2 := e.scalars[i2];
    if v1 == v2 || (!has_uses(v1) && !has_uses(v2)) return false;
    if pm_poison(v1) return true;
    if pm_poison(v2) return false;
    n1 := num_uses(v1); n2 := num_uses(v2);
    if n1 < n2 return true;
    if n1 > n2 return false;
    compare_bbs :: (b1: Value_Id, b2: Value_Id) -> bool {
        if !dt_is_reachable_from_entry(slp.dt, b1) return false;
        if !dt_is_reachable_from_entry(slp.dt, b2) return true;
        return dt_dfs_in(slp.dt, b1) < dt_dfs_in(slp.dt, b2);
    }
    u1 := ir.u_user[ir.v_first_use[v1]]; u2 := ir.u_user[ir.v_first_use[v2]];
    if inst_block(u1) != inst_block(u2) return compare_bbs(inst_block(u1), inst_block(u2));
    ie1 := inst_op(u1) == .INSERTELEMENT; ie2 := inst_op(u2) == .INSERTELEMENT;
    ee1 := inst_op(u1) == .EXTRACTELEMENT; ee2 := inst_op(u2) == .EXTRACTELEMENT;
    if ie1 && !ie2 return true;
    if !ie1 && ie2 return false;
    if ie1 && ie2 {
        h1 := heads[i1]; h2 := heads[i2];
        if h1 != NONE && h2 == NONE return true;
        if h1 == NONE return false;
        if h1 == h2 {
            ok1, x1 := slp_element_index(u1); ok2, x2 := slp_element_index(u2);
            // std::optional<unsigned> comparison
            if !ok1 || !ok2 return !ok1 && ok2;
            return x1 < x2;
        }
        if inst_block(h1) != inst_block(h2) return compare_bbs(inst_block(h1), inst_block(h2));
        return comes_before(h1, h2);
    }
    if ee1 && !ee2 return true;
    if !ee1 && ee2 return false;
    if ee1 && ee2 {
        a := op(u1, 0); b := op(u2, 0);
        inst1 := is_inst(a); inst2 := is_inst(b);
        p1 := vkind(a) == .ARGUMENT; p2 := vkind(b) == .ARGUMENT;
        if !inst2 && !p2 return inst1 || p1;
        if a == b {
            ok1, x1 := slp_element_index(u1); ok2, x2 := slp_element_index(u2);
            if !ok1 || !ok2 return !ok1 && ok2;
            return x1 < x2;
        }
        if !inst1 && inst2 return false;
        if inst1 && inst2 {
            if inst_block(a) != inst_block(b) return compare_bbs(inst_block(a), inst_block(b));
            return comes_before(a, b);
        }
        if !p1 && p2 return false;
        return arg_no(a) < arg_no(b);
    }
    return false;
}

// reorderNodeWithReuses(TE, Mask)
slp_reorder_node_with_reuses :: (te: Te_Id, mask: [] s32) {
    e := *slp.entries[te];
    slp_reorder_reuses(*e.reuse_shuffle_indices, mask);
    sz := e.scalars.count;
    if !te_is_gather(te) || !svm_is_one_use_single_source(e.reuse_shuffle_indices, sz) return;
    // isRepeatedNonIdentityClusteredMask
    {
        r := e.reuse_shuffle_indices;
        first := array_view(r, 0, sz);
        if svm_is_identity(first, sz) return;
        i := sz;
        while i < r.count {
            for j: 0..sz-1 if r[i + j] != first[j] return;
            i += sz;
        }
    }
    nm := slp_inverse_permutation(e.reorder_indices);
    slp_add_mask(*nm, e.reuse_shuffle_indices);
    array_reset_keeping_memory(*e.reorder_indices);
    new_ord := new_order();
    for j: 0..sz-1 array_add(*new_ord, cast(u32) nm[j]);
    nm = slp_inverse_permutation(new_ord);
    slp_reorder_scalars(*e.scalars, nm);
    i := 0;
    while i < e.reuse_shuffle_indices.count {
        for j: 0..sz-1 e.reuse_shuffle_indices[i + j] = cast(s32) j;
        i += sz;
    }
}

// ---------------------------------------------------------------- reorderTopToBottom

slp_reorder_top_to_bottom :: () {
    // VFToOrderedEntries: DenseMap<unsigned, SetVector<TreeEntry *>> (only looked up by VF)
    vf_keys: [..] s64; vf_keys.allocator = temp;
    vf_lists: [..] [..] Te_Id; vf_lists.allocator = temp;
    add_vf :: (keys: *[..] s64, lists: *[..] [..] Te_Id, vf: s64, te: Te_Id) {
        for keys.* if it == vf {
            for x: lists.*[it_index] if x == te return;
            array_add(*lists.*[it_index], te);
            return;
        }
        array_add(keys, vf);
        l: [..] Te_Id; l.allocator = temp; array_add(*l, te);
        array_add(lists, l);
    }
    Te_Order :: struct { te: Te_Id; order: [..] u32; }
    gathers_to_orders: [..] Te_Order; gathers_to_orders.allocator = temp;
    phis_to_orders: [..] Te_Order; phis_to_orders.allocator = temp;
    alt_to_orders: [..] Te_Order; alt_to_orders.allocator = temp;
    Ext_Orders :: struct { te: Te_Id; orders: [..] [..] u32; }
    ext_map: [..] Ext_Orders; ext_map.allocator = temp;
    find_order :: (l: [] Te_Order, te: Te_Id) -> *[..] u32 { for * l if it.te == te return *it.order; return null; }
    for te: 0..slp.entries.count-1 if slp.entries[te].state == TE_VECTORIZE && type_kind(slp_get_value_type(slp.entries[te].scalars[0])) == .STRUCT return;
    ignore_reorder := !slpx.has_user_ignore_list && te_has_state(0) &&
                      (te_opcode(0) == .INSERTELEMENT || te_opcode(0) == .INSERTVALUE || te_opcode(0) == .STORE);
    for k: 0..slp.entries.count-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[k];
        ext := slp_find_external_store_users_reorder_indices(te);
        if ext.count {
            add_vf(*vf_keys, *vf_lists, te_vector_factor(te), te);
            array_add(*ext_map, .{te, ext});
        }
        if te_has_state(te) && is_alt_shuffle(e.s) && e.state != TE_SPLIT_VECTORIZE {
            sty := vtype(e.scalars[0]);
            vec_ty := slp_widened_type(sty, cast(u64) e.scalars.count);
            mask_bits := slp_alt_instr_mask(e.scalars, sty, te_opcode(te), is_alt_opcode(e.s));
            if tti_is_legal_alt_instr(slp.tti, vec_ty, te_opcode(te), is_alt_opcode(e.s), mask_bits) {
                add_vf(*vf_keys, *vf_lists, te_vector_factor(te), te);
                if !find_order(alt_to_orders, te) array_add(*alt_to_orders, .{te, new_order()});
            }
        }
        ok, cur := slp_get_reordering_data(te, true, ignore_reorder);
        if ok {
            cnt := 0;
            user := te;
            skip := false;   // `return` from the for_each lambda: this entry is not recorded
            while user != TE_NONE && cnt < slp_cl.recursion_max_depth {
                ut := slp.entries[user].user_tree_index.user;
                if ut == TE_NONE break;
                if slp.entries[ut].state == TE_VECTORIZE && is_alt_shuffle(slp.entries[ut].s) && slp.entries[ut].idx != 0 { skip = true; break; }
                user = ut;
                cnt += 1;
            }
            if skip continue;
            add_vf(*vf_keys, *vf_lists, te_vector_factor(te), te);
            st := e.state;
            if !(st == TE_VECTORIZE || st == TE_STRIDED_VECTORIZE || st == TE_EXPAND_VECTORIZE || st == TE_SPLIT_VECTORIZE || st == TE_COMPRESS_VECTORIZE) ||
               e.reuse_shuffle_indices.count {
                if !find_order(gathers_to_orders, te) array_add(*gathers_to_orders, .{te, cur});
            }
            if st == TE_VECTORIZE && te_opcode(te) == .PHI {
                if !find_order(phis_to_orders, te) array_add(*phis_to_orders, .{te, cur});
            }
        }
    }
    vf := te_vector_factor(0);
    while vf_keys.count && vf > 1 {
        defer vf -= 1;
        ki := -1;
        for vf_keys if it == vf { ki = it_index; break; }
        if ki < 0 continue;
        ordered := vf_lists[ki];
        array_ordered_remove_by_index(*vf_keys, ki);
        array_ordered_remove_by_index(*vf_lists, ki);
        // MapVector<OrdersType, unsigned> OrdersUses
        uses_keys: [..] [..] u32; uses_keys.allocator = temp;
        uses_cnt: [..] u32; uses_cnt.allocator = temp;
        add_use :: (keys: *[..] [..] u32, cnts: *[..] u32, o: [] u32, n: u32) {
            for keys.* if orders_equal(it, o) { cnts.*[it_index] += n; return; }
            array_add(keys, order_copy(o));
            array_add(cnts, n);
        }
        for op_te: ordered {
            oe := *slp.entries[op_te];
            if oe.reuse_shuffle_indices.count && !find_order(gathers_to_orders, op_te) && oe.state != TE_SPLIT_VECTORIZE continue;
            ord: [] u32 = oe.reorder_indices;
            {
                p: *[..] u32 = null;
                if te_is_gather(op_te) || oe.reuse_shuffle_indices.count p = find_order(gathers_to_orders, op_te);
                if !p && te_has_state(op_te) && is_alt_shuffle(oe.s) p = find_order(alt_to_orders, op_te);
                if !p && oe.state == TE_VECTORIZE && te_opcode(op_te) == .PHI p = find_order(phis_to_orders, op_te);
                if p ord = p.*;
            }
            ext_i := -1;
            for ext_map if it.te == op_te { ext_i = it_index; break; }
            if ext_i >= 0 {
                exts := ext_map[ext_i].orders;
                if te_vector_factor(op_te) != oe.scalars.count add_use(*uses_keys, *uses_cnt, .[], cast(u32) exts.count);
                else for x: exts add_use(*uses_keys, *uses_cnt, x, 1);
                if ord.count == 0 continue;
            }
            if oe.state == TE_VECTORIZE && te_opcode(op_te) == .STORE && ord.count {
                mask := slp_inverse_permutation(ord);
                e := cast(u32) ord.count;
                cur := new_order();
                for mask array_add(*cur, ifx it == PoisonMaskElem then e else cast(u32) it);
                slp_fixup_ordering_indices(cur);
                add_use(*uses_keys, *uses_cnt, cur, 1);
            } else {
                add_use(*uses_keys, *uses_cnt, ord, 1);
            }
        }
        if uses_keys.count == 0 continue;
        best := slp_select_best_order(uses_keys, uses_cnt, vf, true);
        if slp_is_identity_order(best) continue;
        slp_fixup_ordering_indices(best);
        mask := slp_inverse_permutation(best);
        e := cast(u32) best.count;
        mask_order := new_mask();
        for best array_add(*mask_order, ifx it < e then cast(s32) it else PoisonMaskElem);
        for k: 0..slp.entries.count-1 {
            te := cast(Te_Id) k;
            t := *slp.entries[k];
            if t.scalars.count != vf {
                if t.reuse_shuffle_indices.count == vf && t.state != TE_EXPAND_VECTORIZE {
                    slp_reorder_node_with_reuses(te, mask);
                    u := t.user_tree_index.user;
                    if u != TE_NONE && slp.entries[u].state == TE_SPLIT_VECTORIZE te_reorder_split_node(u, t.user_tree_index.edge, mask, mask_order);
                }
                continue;
            }
            vec_state := t.state == TE_VECTORIZE || t.state == TE_STRIDED_VECTORIZE || t.state == TE_EXPAND_VECTORIZE || t.state == TE_COMPRESS_VECTORIZE;
            mo := ifx te_has_state(te) then inst_op(t.s.main) else .NONE_OP;
            if (t.state == TE_SPLIT_VECTORIZE && t.reuse_shuffle_indices.count == 0) ||
               (vec_state && (mo == .EXTRACTELEMENT || mo == .EXTRACTVALUE || mo == .LOAD || mo == .STORE || mo == .INSERTELEMENT || mo == .INSERTVALUE)) {
                slp_reorder_order(*t.reorder_indices, mask);
                if mo == .INSERTELEMENT || mo == .INSERTVALUE || mo == .STORE te_reorder_operands(te, mask);
            } else {
                te_reorder_operands(te, mask);
                slp_reorder_scalars(*t.scalars, mask);
            }
            if t.reuse_shuffle_indices.count && t.state != TE_EXPAND_VECTORIZE {
                cur := new_order();
                slp_reorder_order(*cur, mask_order);
                nr := slp_inverse_permutation(cur);
                slp_add_mask(*nr, t.reuse_shuffle_indices);
                t.reuse_shuffle_indices = nr;
            } else {
                u := t.user_tree_index.user;
                if u != TE_NONE && slp.entries[u].state == TE_SPLIT_VECTORIZE te_reorder_split_node(u, t.user_tree_index.edge, mask, mask_order);
            }
        }
    }
}

// The best-order selection shared by both reorderings: `filled_identity_tie` is reorderTopToBottom's extra rule
slp_select_best_order :: (keys: [..] [..] u32, cnts: [] u32, vf: s64, filled_identity_tie: bool) -> [..] u32 {
    identity_cnt: u32 = 0;
    filled_identity_cnt: u32 = 0;
    identity := new_order(vf, cast(u32) vf);
    for k, i: keys {
        if k.count == 0 || slp_is_identity_order(k) {
            if k.count filled_identity_cnt += cnts[i];
            identity_cnt += cnts[i];
            slp_combine_orders(identity, k);
        }
    }
    best: [] u32 = identity;
    cnt := identity_cnt;
    for k, i: keys {
        if cnt < cnts[i] || (filled_identity_tie && cnt == identity_cnt && identity_cnt == filled_identity_cnt && cnt == cnts[i] && best.count && slp_is_identity_order(best)) {
            slp_combine_orders(k, best);
            best = k;
            cnt = cnts[i];
        } else {
            slp_combine_orders(best, k);
        }
    }
    return order_copy(best);
}

// ---------------------------------------------------------------- reorderBottomToTop

// libstdc++ std::push_heap / std::pop_heap over Te_Id with TreeEntryCompare
te_heap_less :: (a: Te_Id, b: Te_Id) -> bool {
    ua := slp.entries[a].user_tree_index.user; ub := slp.entries[b].user_tree_index.user;
    if ua != TE_NONE && ub != TE_NONE return slp.entries[ua].idx < slp.entries[ub].idx;
    return slp.entries[a].idx < slp.entries[b].idx;
}
te_heap_push :: (h: *[..] Te_Id, v: Te_Id) {
    array_add(h, v);
    hole := h.count - 1;
    parent := (hole - 1) / 2;
    while hole > 0 && te_heap_less(h.*[parent], v) { h.*[hole] = h.*[parent]; hole = parent; parent = (hole - 1) / 2; }
    h.*[hole] = v;
}
te_heap_pop :: (h: *[..] Te_Id) {
    n := h.count;
    if n <= 1 { h.count = 0; return; }
    value := h.*[n - 1];
    h.*[n - 1] = h.*[0];
    len := n - 1;
    // __adjust_heap(first, 0, len, value)
    hole := 0; second := 0;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if te_heap_less(h.*[second], h.*[second - 1]) second -= 1;
        h.*[hole] = h.*[second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        h.*[hole] = h.*[second - 1];
        hole = second - 1;
    }
    parent := (hole - 1) / 2;
    while hole > 0 && te_heap_less(h.*[parent], value) { h.*[hole] = h.*[parent]; hole = parent; parent = (hole - 1) / 2; }
    h.*[hole] = value;
    h.count = len;
}

Edge_Op :: struct { idx: u32; te: Te_Id; }

// buildReorderableOperands(UserTE, Edges, ReorderableGathers, GatherOps)
slp_build_reorderable_operands :: (user: Te_Id, edges: *[..] Edge_Op, reorderable_gathers: [] Te_Id, gather_ops: *[..] Te_Id) {
    ue := *slp.entries[user];
    for i: 0..ue.operands.count-1 {
        skip := false;
        for edges.* {
            st := slp.entries[it.te].state;
            if it.idx == cast(u32) i && (st == TE_VECTORIZE || st == TE_STRIDED_VECTORIZE || st == TE_EXPAND_VECTORIZE || st == TE_COMPRESS_VECTORIZE || st == TE_SPLIT_VECTORIZE) { skip = true; break; }
        }
        if skip continue;
        if te_has_state(user) {
            o := te_opcode(user);
            if o == .EXTRACTELEMENT || o == .EXTRACTVALUE continue;
            if (o == .INSERTELEMENT || o == .INSERTVALUE) && i == 0 continue;
            if o == .STORE && i == 1 && (ue.state == TE_VECTORIZE || ue.state == TE_STRIDED_VECTORIZE || ue.state == TE_EXPAND_VECTORIZE) continue;
            if o == .LOAD && (ue.state == TE_VECTORIZE || ue.state == TE_STRIDED_VECTORIZE || ue.state == TE_COMPRESS_VECTORIZE) continue;
        }
        te := slp_get_operand_entry(user, cast(u32) i);
        if !te_is_gather(te) {
            array_add(edges, .{cast(u32) i, te});
            if slp.entries[te].state == TE_SCATTER_VECTORIZE && slp.entries[te].reuse_shuffle_indices.count == 0 && slp.entries[te].reorder_indices.count == 0
                array_add(gather_ops, te);
            continue;
        }
        for reorderable_gathers if it == te { array_add(gather_ops, te); break; }
    }
}

slp_reorder_bottom_to_top :: (ignore_reorder_in := false) {
    ignore_reorder := ignore_reorder_in;
    queue: [..] Te_Id; queue.allocator = temp;
    gathers_to_orders: [..] Te_Id; gathers_to_orders.allocator = temp;
    non_vectorized: [..] Te_Id; non_vectorized.allocator = temp;
    contains :: (l: [] Te_Id, t: Te_Id) -> bool { for l if it == t return true; return false; }
    is_vec_state :: (st: s32) -> bool { return st == TE_VECTORIZE || st == TE_STRIDED_VECTORIZE || st == TE_EXPAND_VECTORIZE || st == TE_COMPRESS_VECTORIZE || st == TE_SPLIT_VECTORIZE; }
    for k: 0..slp.entries.count-1 {
        te := cast(Te_Id) k;
        if !is_vec_state(slp.entries[k].state) array_add(*non_vectorized, te);
        ok := slp_get_reordering_data(te, false, ignore_reorder);
        if ok {
            te_heap_push(*queue, te);
            if !is_vec_state(slp.entries[k].state) || slp.entries[k].reuse_shuffle_indices.count array_add(*gathers_to_orders, te);
        }
    }
    visited: [..] Te_Id; visited.allocator = temp;
    revisited_ops: [..] Te_Id; revisited_ops.allocator = temp;
    set_insert :: (s: *[..] Te_Id, t: Te_Id) -> bool { for s.* if it == t return false; array_add(s, t); return true; }
    set_erase :: (s: *[..] Te_Id, t: Te_Id) { for s.* if it == t { array_unordered_remove_by_index(s, it_index); return; } }
    while queue.count {
        users_first := TE_NONE;
        users_second: [..] Edge_Op; users_second.allocator = temp;
        te := queue[0];
        user_te := slp.entries[te].user_tree_index.user;
        te_heap_pop(*queue);
        ordered_ops: [..] Te_Id; ordered_ops.allocator = temp;
        array_add(*ordered_ops, te);
        while queue.count {
            te = queue[0];
            if user_te == TE_NONE || user_te != slp.entries[te].user_tree_index.user break;
            te_heap_pop(*queue);
            array_add(*ordered_ops, te);
        }
        for t: ordered_ops {
            e := *slp.entries[t];
            if !(is_vec_state(e.state) || (te_is_gather(t) && contains(gathers_to_orders, t))) || e.user_tree_index.user == TE_NONE ||
               e.reuse_shuffle_indices.count || !set_insert(*visited, t) continue;
            users_first = e.user_tree_index.user;
            array_add(*users_second, .{e.user_tree_index.edge, t});
        }
        if users_first == TE_NONE continue;
        df := users_first;
        dfe := *slp.entries[df];
        if dfe.state == TE_VECTORIZE && type_kind(slp_get_value_type(dfe.scalars[0])) == .STRUCT continue;
        if dfe.state == TE_SPLIT_VECTORIZE {
            any_no_user := false;
            for users_second if slp.entries[it.te].user_tree_index.user == TE_NONE { any_no_user = true; break; }
            if any_no_user continue;
            for p: dfe.combined_entries_with_indices {
                op_te := cast(Te_Id) p[0];
                oe := *slp.entries[op_te];
                if oe.state != TE_SPLIT_VECTORIZE && oe.reorder_indices.count && oe.reuse_shuffle_indices.count continue;
                ord := order_copy(oe.reorder_indices);
                if ord.count == 0 || oe.reuse_shuffle_indices.count {
                    if !te_is_gather(op_te) && oe.reuse_shuffle_indices.count == 0 continue;
                    ok, bo := slp_get_reordering_data(op_te, false, ignore_reorder);
                    if !ok || bo.count == 0 || slp_is_identity_order(bo) continue;
                    ord = bo;
                }
                slp_fixup_ordering_indices(ord);
                mask := slp_inverse_permutation(ord);
                e := cast(u32) ord.count;
                mask_order := new_mask();
                for ord array_add(*mask_order, ifx it < e then cast(s32) it else PoisonMaskElem);
                te_reorder_split_node(df, ifx p[1] != 0 then cast(u32) 1 else 0, mask, mask_order);
                if oe.reorder_indices.count array_reset_keeping_memory(*oe.reorder_indices);
                else if oe.reuse_shuffle_indices.count slp_reorder_reuses(*oe.reuse_shuffle_indices, mask);
                else slp_reorder_scalars(*oe.scalars, mask);
            }
            if dfe.reuse_shuffle_indices.count == 0 && dfe.reorder_indices.count te_heap_push(*queue, df);
            continue;
        }
        gather_ops: [..] Te_Id; gather_ops.allocator = temp;
        slp_build_reorderable_operands(df, *users_second, non_vectorized, *gather_ops);
        uses_keys: [..] [..] u32; uses_keys.allocator = temp;
        uses_cnt: [..] u32; uses_cnt.allocator = temp;
        use_index :: (keys: *[..] [..] u32, cnts: *[..] u32, o: [] u32) -> s64 {
            for keys.* if orders_equal(it, o) return it_index;
            array_add(keys, order_copy(o));
            array_add(cnts, 0);
            return keys.count - 1;
        }
        visited_ops: [..] Te_Id; visited_ops.allocator = temp;
        visited_users: [..] Te_Id; visited_users.allocator = temp;
        for opd: users_second {
            op_te := opd.te;
            oe := *slp.entries[op_te];
            if !set_insert(*visited_ops, op_te) continue;
            if oe.reuse_shuffle_indices.count && !contains(gathers_to_orders, op_te) continue;
            ord: [..] u32;
            if te_is_gather(op_te) || oe.reuse_shuffle_indices.count {
                ok, o := slp_get_reordering_data(op_te, false, ignore_reorder);
                if ok ord = o; else ord = new_order(1, 0);
            } else ord = order_copy(oe.reorder_indices);
            if ord.count == 1 continue;
            if ord.count && !slp_is_identity_order(ord) {
                root: Value_Id;
                if te_has_state(op_te) root = oe.s.main;
                else { for oe.scalars if !slp_is_constant(it) { root = it; break; } }
                // GetSameNodesUsers(Root)
                users: [..] Te_Id; users.allocator = temp;
                same_node :: (t: Te_Id, op_te: Te_Id) -> bool {
                    a := *slp.entries[t]; b := *slp.entries[op_te];
                    return t != op_te && a.user_tree_index.user != TE_NONE && te_vector_factor(t) == te_vector_factor(op_te) &&
                           a.scalars.count == b.scalars.count &&
                           ((a.reorder_indices.count == 0 && te_is_same(op_te, a.scalars)) || (b.reorder_indices.count == 0 && te_is_same(t, b.scalars)));
                }
                gp := table_find_pointer(*slpx.value_to_gather_nodes, root);
                if gp for t: gp.* if same_node(t, op_te) set_insert(*users, slp.entries[t].user_tree_index.user);
                for t: slp_get_tree_entries(root) if same_node(t, op_te) set_insert(*users, slp.entries[t].user_tree_index.user);
                num_operands :: (t: Te_Id) -> s64 {
                    e := *slp.entries[t];
                    if e.state == TE_SPLIT_VECTORIZE return e.operands.count;
                    if inst_op(e.s.main) == .CALL return cast(s64) call_num_args(e.s.main);
                    return e.operands.count;
                }
                should_reorder_with_operands :: (t: Te_Id) -> bool {
                    id: Intrinsic_Id = NOT_INTRINSIC;
                    if inst_op(slp.entries[t].s.main) == .CALL id = get_vector_intrinsic_id_for_call(slp.entries[t].s.main);
                    for idx: 0..num_operands(t)-1 {
                        if id != NOT_INTRINSIC && vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) idx) continue;
                        o := slp_get_operand_entry(t, cast(u32) idx);
                        if te_is_gather(o) && te_has_state(o) {
                            vo := slp_get_same_values_tree_entry(slp.entries[o].s.main, slp.entries[o].scalars);
                            if vo != TE_NONE o = vo;
                        }
                        if slp.entries[o].reorder_indices.count == 0 && slp.entries[o].reuse_shuffle_indices.count == 0 return false;
                    }
                    return true;
                }
                if users.count {
                    all := true;
                    for ut: users {
                        if !set_insert(*revisited_ops, ut) { all = false; break; }
                        u := *slp.entries[ut];
                        uu := u.user_tree_index.user;
                        ok := ut == df || u.reorder_indices.count > 0 || u.reuse_shuffle_indices.count > 0 || (uu != TE_NONE && uu == df) ||
                              (dfe.user_tree_index.user != TE_NONE && dfe.user_tree_index.user == ut) ||
                              (ignore_reorder && uu != TE_NONE && slp.entries[uu].idx == 0) || should_reorder_with_operands(ut);
                        if !ok { all = false; break; }
                    }
                    if !all continue;
                }
                for ut: users {
                    id: Intrinsic_Id = NOT_INTRINSIC;
                    if inst_op(slp.entries[ut].s.main) == .CALL id = get_vector_intrinsic_id_for_call(slp.entries[ut].s.main);
                    for idx: 0..num_operands(ut)-1 {
                        if id != NOT_INTRINSIC && vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) idx) continue;
                        o := slp_get_operand_entry(ut, cast(u32) idx);
                        set_erase(*visited, o);
                        te_heap_push(*queue, o);
                    }
                }
            }
            num_ops: u32 = 0;
            for users_second if it.te == op_te num_ops += 1;
            if oe.state == TE_VECTORIZE && te_opcode(op_te) == .STORE && ord.count {
                mask := slp_inverse_permutation(ord);
                e := cast(u32) ord.count;
                cur := new_order();
                for mask array_add(*cur, ifx it == PoisonMaskElem then e else cast(u32) it);
                slp_fixup_ordering_indices(cur);
                uses_cnt[use_index(*uses_keys, *uses_cnt, cur)] += num_ops;
            } else {
                uses_cnt[use_index(*uses_keys, *uses_cnt, ord)] += num_ops;
            }
            res_i := use_index(*uses_keys, *uses_cnt, .[]);
            allows_reordering :: (t: Te_Id, gathers_to_orders: [] Te_Id, ignore_reorder: bool) -> bool {
                e := *slp.entries[t];
                if e.reorder_indices.count || e.reuse_shuffle_indices.count || (e.state == TE_VECTORIZE && is_alt_shuffle(e.s)) || (ignore_reorder && e.idx == 0) return true;
                if te_is_gather(t) {
                    in_g := false; for gathers_to_orders if it == t { in_g = true; break; }
                    if in_g {
                        ok, o := slp_get_reordering_data(t, false, ignore_reorder);
                        if !ok return true;   // !value_or(OrdersType(1)).empty()
                        return o.count != 0;
                    }
                    return true;
                }
                return false;
            }
            if oe.user_tree_index.user != TE_NONE {
                ut := oe.user_tree_index.user;
                if !set_insert(*visited_users, ut) continue;
                if allows_reordering(ut, gathers_to_orders, ignore_reorder) continue;
                c := 0;
                for o2: users_second if allows_reordering(o2.te, gathers_to_orders, ignore_reorder) && slp.entries[o2.te].user_tree_index.user == ut c += 1;
                if c <= users_second.count / 2 uses_cnt[res_i] += 1;
            }
        }
        if uses_keys.count == 0 {
            for users_second set_insert(*visited, it.te);
            continue;
        }
        vf := te_vector_factor(users_second[0].te);
        best := slp_select_best_order(uses_keys, uses_cnt, vf, false);
        if slp_is_identity_order(best) {
            for users_second set_insert(*visited, it.te);
            continue;
        }
        slp_fixup_ordering_indices(best);
        array_reset_keeping_memory(*visited_ops);
        mask := slp_inverse_permutation(best);
        e := cast(u32) best.count;
        mask_order := new_mask();
        for best array_add(*mask_order, ifx it < e then cast(s32) it else PoisonMaskElem);
        for opd: users_second {
            t := opd.te;
            if !set_insert(*visited_ops, t) continue;
            te_ := *slp.entries[t];
            if te_.state == TE_VECTORIZE && type_kind(slp_get_value_type(te_.scalars[0])) == .STRUCT continue;
            if te_.reuse_shuffle_indices.count == best.count { slp_reorder_node_with_reuses(t, mask); continue; }
            st := te_.state;
            if st != TE_VECTORIZE && st != TE_STRIDED_VECTORIZE && st != TE_EXPAND_VECTORIZE && st != TE_COMPRESS_VECTORIZE && st != TE_SPLIT_VECTORIZE &&
               (st != TE_SCATTER_VECTORIZE || te_.reorder_indices.count == 0) continue;
            slp_reorder_order(*te_.reorder_indices, mask);
            if ignore_reorder && t == 0 ignore_reorder = false;
        }
        for g: gather_ops {
            ge := *slp.entries[g];
            if ge.reuse_shuffle_indices.count { slp_reorder_reuses(*ge.reuse_shuffle_indices, mask); continue; }
            slp_reorder_scalars(*ge.scalars, mask);
            set_insert(*visited, g);
        }
        not_profitable_alt :: (t: Te_Id) -> bool {
            e := *slp.entries[t];
            return is_alt_shuffle(e.s) && (e.reuse_shuffle_indices.count || te_vector_factor(t) == 2 || e.reorder_indices.count == 0);
        }
        mo := inst_op(dfe.s.main);
        if dfe.state != TE_VECTORIZE || !(mo == .EXTRACTELEMENT || mo == .EXTRACTVALUE || mo == .LOAD) || not_profitable_alt(df) te_reorder_operands(df, mask);
        if !(mo == .INSERTELEMENT || mo == .INSERTVALUE || mo == .STORE) || not_profitable_alt(df) || dfe.state == TE_COMPRESS_VECTORIZE {
            slp_reorder_scalars(*dfe.scalars, mask);
            slp_reorder_order(*dfe.reorder_indices, mask_order, true);
            if dfe.reuse_shuffle_indices.count == 0 && dfe.reorder_indices.count && !not_profitable_alt(df) te_heap_push(*queue, df);
        } else {
            slp_reorder_order(*dfe.reorder_indices, mask);
        }
    }
    if ignore_reorder && slp.entries[0].reorder_indices.count && slp.entries[0].reuse_shuffle_indices.count == 0 array_reset_keeping_memory(*slp.entries[0].reorder_indices);
}
