// InterleavedAccessInfo (analyzeInterleaving, collectConstStrideAccesses, collectDependences) and InterleaveGroup.
// Ported from llvm/lib/Analysis/VectorUtils.cpp and llvm/include/llvm/Analysis/VectorUtils.h (LLVM 23.1.5).

Ig :: struct {                       // InterleaveGroup<Instruction>
    factor: u32;
    reverse: bool;
    align: u64;
    keys: [..] s32;                  // Members (DenseMap<int32_t, Instruction *>): keys and values side by side
    vals: [..] Value_Id;
    smallest: s32;
    largest: s32;
    insert_pos: Value_Id = NONE;
    alive: bool;
}
Iai :: struct {                      // InterleavedAccessInfo
    pse: *Pse;
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    laa: *Laa;
    opt_for_size: bool;
    requires_scalar_epilogue: bool;
    groups: [..] Ig;                 // all groups ever created (index = group id); `alive` = in InterleaveGroups
    order: [..] s32;                 // InterleaveGroups (SmallPtrSet): the alive groups in creation order
    map: Table(Value_Id, s32);       // InterleaveGroupMap
    deps: Table(Value_Id, [..] Value_Id);
}
Iai_Stride :: struct { i: Value_Id; stride: s64; scev: Scev_Id; size: u64; align: u64; }

iai_init :: (a: *Iai, pse: *Pse, l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, laa: *Laa, opt_for_size: bool) {
    a.pse = pse; a.l = l; a.li = li; a.dt = dt; a.laa = laa; a.opt_for_size = opt_for_size;
    a.groups.allocator = temp; a.order.allocator = temp; a.map.allocator = temp; a.deps.allocator = temp;
}
iai_is_strided :: (stride: s64) -> bool { f := ifx stride < 0 then -stride else stride; return f >= 2 && f <= lv_opts.max_interleave_group_factor; }
iai_group_of :: (a: *Iai, i: Value_Id) -> s32 { found, g := table_find(*a.map, i); return ifx found then g else -1; }
iai_has_groups :: (a: *Iai) -> bool { for a.order if a.groups[it].alive return true; return false; }

ig_get_member :: (g: *Ig, index: u32) -> Value_Id {
    key := g.smallest + cast(s32) index;
    for g.keys if it == key return g.vals[it_index];
    return NONE;
}
ig_index_of :: (g: *Ig, i: Value_Id) -> u32 {
    for g.vals if it == i return cast(u32) (g.keys[it_index] - g.smallest);
    fatal("internal: InterleaveGroup contains no such member");
    return 0;
}
ig_is_full :: (g: *Ig) -> bool { return g.keys.count == cast(s64) g.factor; }
// InterleaveGroup::insertMember
ig_insert_member :: (g: *Ig, i: Value_Id, index: s32, align: u64) -> bool {
    k64 := cast(s64) index + cast(s64) g.smallest;
    if k64 < -0x8000_0000 || k64 > 0x7FFF_FFFF return false;
    key := cast(s32) k64;
    for g.keys if it == key return false;
    if key > g.largest {
        if index >= cast(s32) g.factor return false;
        g.largest = key;
    } else if key < g.smallest {
        d := cast(s64) g.largest - cast(s64) key;
        if d >= cast(s64) g.factor return false;
        g.smallest = key;
    }
    g.align = min(g.align, align);
    array_add(*g.keys, key); array_add(*g.vals, i);
    return true;
}
// InterleaveGroup::requiresScalarEpilogue
ig_requires_scalar_epilogue :: (g: *Ig) -> bool { return ig_get_member(g, g.factor - 1) == NONE; }

iai_create_group :: (a: *Iai, i: Value_Id, stride: s64, align: u64) -> s32 {
    g: Ig;
    g.factor = cast(u32) (ifx stride < 0 then -stride else stride);
    g.reverse = stride < 0;
    g.align = align;
    g.keys.allocator = temp; g.vals.allocator = temp;
    array_add(*g.keys, 0); array_add(*g.vals, i);
    g.insert_pos = i;
    g.alive = true;
    array_add(*a.groups, g);
    id := cast(s32) (a.groups.count - 1);
    array_add(*a.order, id);
    table_set(*a.map, i, id);
    return id;
}
iai_release_group :: (a: *Iai, id: s32) {
    g := *a.groups[id];
    g.alive = false;
    for k: 0..g.factor-1 { m := ig_get_member(g, k); if m != NONE table_remove(*a.map, m); }
}

// LoopAccessInfo dependences are valid
iai_deps_valid :: (a: *Iai) -> bool { return a.laa != null && a.laa.dc.record_dependences; }

// collectDependences
iai_collect_dependences :: (a: *Iai) {
    if !iai_deps_valid(a) return;
    dc := *a.laa.dc;
    for d: dc.dependences {
        src := dc.inst_map[d.source];
        dst := dc.inst_map[d.destination];
        p := table_find_pointer(*a.deps, src);
        if !p { e: [..] Value_Id; e.allocator = temp; table_set(*a.deps, src, e); p = table_find_pointer(*a.deps, src); }
        if !array_find(p.*, dst) array_add(p, dst);
    }
}

// canReorderMemAccessesForInterleavedGroups
iai_can_reorder :: (a: *Iai, src: *Iai_Stride, sink: *Iai_Stride) -> bool {
    if !may_write_to_memory(src.i) return true;
    if !iai_is_strided(src.stride) && !iai_is_strided(sink.stride) return true;
    if !iai_deps_valid(a) return false;
    p := table_find_pointer(*a.deps, src.i);
    return !p || !array_find(p.*, sink.i);
}

// collectConstStrideAccesses
iai_collect_const_stride_accesses :: (a: *Iai, out: *[..] Iai_Stride, preds: *[..] u32) {
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(a.li, a.l, *rpo);
    for bb: rpo for i: block_insts(bb) {
        o := inst_op(i);
        if o != .LOAD && o != .STORE continue;
        ptr := load_store_pointer_operand(i);
        ety := load_store_type(i);
        size := dl_type_alloc_size(ety);
        if size * 8 != dl_type_size_bits(ety) continue;
        ok, stride := laa_get_ptr_stride(a.pse, a.li, ety, ptr, a.l, a.dt, *a.laa.symbolic_strides, false, preds);
        if !ok stride = 0;
        sc := laa_replace_symbolic_stride_scev(a.pse, *a.laa.symbolic_strides, ptr);
        array_add(out, .{i, stride, sc, size, inst(i).align});
    }
}

// InterleavedAccessInfo::analyzeInterleaving
iai_analyze_interleaving :: (a: *Iai, enable_predicated: bool) {
    acc: [..] Iai_Stride; acc.allocator = temp;
    preds: [..] u32; preds.allocator = temp;
    iai_collect_const_stride_accesses(a, *acc, ifx a.opt_for_size then null else *preds);
    if acc.count == 0 return;
    iai_collect_dependences(a);
    store_groups: [..] s32; store_groups.allocator = temp;
    load_groups: [..] s32; load_groups.allocator = temp;
    completed: [..] s32; completed.allocator = temp;
    find_acc :: (acc: [] Iai_Stride, i: Value_Id) -> *Iai_Stride { for * acc if it.i == i return it; return null; }
    is_pred :: (a: *Iai, bb: Value_Id) -> bool { return laa_block_needs_predication(bb, a.li, a.l, a.dt); }
    bi := acc.count - 1;
    while bi >= 0 {
        defer bi -= 1;
        B := acc[bi].i;
        des_b := *acc[bi];
        group_b: s32 = -1;
        if iai_is_strided(des_b.stride) && (!is_pred(a, inst_block(B)) || enable_predicated) {
            group_b = iai_group_of(a, B);
            if group_b < 0 {
                group_b = iai_create_group(a, B, des_b.stride, des_b.align);
                if may_write_to_memory(B) array_add(*store_groups, group_b); else array_add(*load_groups, group_b);
            }
        }
        ai := bi - 1;
        while ai >= 0 {
            defer ai -= 1;
            A := acc[ai].i;
            des_a := *acc[ai];
            group_a := iai_group_of(a, A);
            if may_write_to_memory(A) && group_a != group_b {
                dependent: Value_Id = NONE;
                if group_b >= 0 && array_find(load_groups, group_b) {
                    gb := *a.groups[group_b];
                    for idx: 0..gb.factor-1 {
                        m := ig_get_member(gb, idx);
                        if m != NONE && !iai_can_reorder(a, des_a, find_acc(acc, m)) { dependent = m; break; }
                    }
                } else if !iai_can_reorder(a, des_a, des_b) dependent = B;
                if dependent != NONE {
                    if group_a >= 0 && array_find(store_groups, group_a) {
                        array_ordered_remove_by_value(*store_groups, group_a);
                        iai_release_group(a, group_a);
                    }
                    if group_b >= 0 && array_find(load_groups, group_b) && !array_find(completed, group_b) array_add(*completed, group_b);
                }
            }
            if group_b >= 0 && array_find(completed, group_b) continue;
            if !iai_is_strided(des_a.stride) || !iai_is_strided(des_b.stride) continue;
            if iai_group_of(a, A) >= 0 || may_read_from_memory(A) != may_read_from_memory(B) || may_write_to_memory(A) != may_write_to_memory(B) continue;
            if des_a.stride != des_b.stride || des_a.size != des_b.size continue;
            if ptr_addrspace(vtype(load_store_pointer_operand(A))) != ptr_addrspace(vtype(load_store_pointer_operand(B))) continue;
            dist := sc_get_minus(des_a.scev, des_b.scev);
            if !sc_is_const(dist) continue;
            d := ap_sext_value(sc_ap(dist));
            if d % cast(s64) des_b.size continue;
            ba := inst_block(A); bb := inst_block(B);
            if (is_pred(a, ba) || is_pred(a, bb)) && (!enable_predicated || ba != bb) continue;
            gb := *a.groups[group_b];
            index_a := cast,trunc(s32) (cast(s64) ig_index_of(gb, B) + d / cast(s64) des_b.size);   // int IndexA = int64 expression
            if ig_insert_member(gb, A, index_a, des_a.align) {
                table_set(*a.map, A, group_b);
                if may_read_from_memory(A) gb.insert_pos = A;
            }
        }
    }
    if load_groups.count || store_groups.count pse_add_predicates(a.pse, preds);
    may_wrap :: (a: *Iai, gid: s32, index: u32) -> bool {
        m := ig_get_member(*a.groups[gid], index);
        assert(m != NONE, "Group member does not exist");
        ok, s := laa_get_ptr_stride_assume(a.pse, a.li, load_store_type(m), load_store_pointer_operand(m), a.l, a.dt, *a.laa.symbolic_strides, false, true);
        if ok && s != 0 return false;
        iai_release_group(a, gid);
        return true;
    }
    for gid: load_groups {
        g := *a.groups[gid];
        if !g.alive || ig_is_full(g) continue;
        if may_wrap(a, gid, 0) continue;
        if ig_get_member(g, g.factor - 1) != NONE may_wrap(a, gid, g.factor - 1);
        else {
            if g.reverse { iai_release_group(a, gid); continue; }
            a.requires_scalar_epilogue = true;
        }
    }
    for gid: store_groups {
        g := *a.groups[gid];
        if !g.alive || ig_is_full(g) continue;
        if !enable_predicated { iai_release_group(a, gid); continue; }
        if may_wrap(a, gid, 0) continue;
        k := cast(s64) g.factor - 1;
        while k > 0 {
            if ig_get_member(g, cast(u32) k) != NONE { may_wrap(a, gid, cast(u32) k); break; }
            k -= 1;
        }
    }
}

// invalidateGroupsRequiringScalarEpilogue
iai_invalidate_groups_requiring_scalar_epilogue :: (a: *Iai) {
    if !a.requires_scalar_epilogue return;
    released := false;
    for a.order {
        g := *a.groups[it];
        if !g.alive || !ig_requires_scalar_epilogue(g) continue;
        iai_release_group(a, it);
        released = true;
    }
    assert(released, "At least one group must be invalidated, as a scalar epilogue was required");
    a.requires_scalar_epilogue = false;
}
// invalidateGroups
iai_invalidate_groups :: (a: *Iai) -> bool {
    if !iai_has_groups(a) return false;
    for a.order a.groups[it].alive = false;
    table_reset(*a.map);
    a.requires_scalar_epilogue = false;
    return true;
}
// InterleaveGroup::members(): the members in index order
ig_members :: (g: *Ig) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    for k: 0..g.factor - 1 { m := ig_get_member(g, k); if m != NONE array_add(*out, m); }
    return out;
}
iai_group :: (a: *Iai, i: Value_Id) -> *Ig {
    id := iai_group_of(a, i);
    if id < 0 return null;
    return *a.groups[id];
}
