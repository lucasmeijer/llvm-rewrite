// LowerSwitchPass: a port of llvm/lib/Transforms/Utils/LowerSwitch.cpp (complete).
//
// Address order: DeleteList is a SmallPtrSet<BasicBlock *, 8>; up to 8 entries it iterates in insertion order (the
// small representation is a plain array), beyond that in pointer-hash order, which we can't reproduce: fail loudly.

Ls_Int_Range :: struct { low: APInt; high: APInt; }
Ls_Case_Range :: struct { low: Value_Id; high: Value_Id; bb: Value_Id; }   // ConstantInt *Low, *High

// IsInRanges
ls_is_in_ranges :: (r: Ls_Int_Range, ranges: [] Ls_Int_Range) -> bool {
    // lower_bound(Ranges, R, A.High.slt(B.High))
    lo := 0; hi := ranges.count;
    while lo < hi {
        mid := (lo + hi) / 2;
        if ap_slt(ranges[mid].high, r.high) lo = mid + 1; else hi = mid;
    }
    return lo != ranges.count && ap_sle(ranges[lo].low, r.low);
}

// APInt counts that drive loops: saturate at u64 max (the loops end at the phi's last entry anyway)
ls_count :: (a: APInt) -> u64 { return ap_limited(a); }

// FixPhis
ls_fix_phis :: (succ_bb: Value_Id, orig_bb: Value_Id, new_bb: Value_Id, num_merged_cases: u64) {
    for :early_inc block_insts(succ_bb) {
        if inst_op(it) != .PHI break;
        pn := it;
        idx: u32 = 0;
        e := phi_num_incoming(pn);
        local := num_merged_cases;
        while idx != e && new_bb != NONE {
            if phi_block(pn, idx) == orig_bb { phi_set_block(pn, idx, new_bb); break; }
            idx += 1;
        }
        if new_bb != NONE idx += 1;
        indices: [..] u32; indices.allocator = temp;
        while local > 0 && idx < e {
            if phi_block(pn, idx) == orig_bb { array_add(*indices, idx); local -= 1; }
            idx += 1;
        }
        for < indices phi_remove_incoming(pn, it);
    }
}

// NewLeafBlock
ls_new_leaf_block :: (leaf: Ls_Case_Range, val: Value_Id, lower_bound: Value_Id, upper_bound: Value_Id,
                      orig_block: Value_Id, default: Value_Id) -> Value_Id {
    f := block_fn(orig_block);
    new_leaf := new_block(NONE);
    set_name(new_leaf, "LeafBlock");
    fn_insert_detached_block_after(f, orig_block, new_leaf);
    comp: Value_Id;
    if leaf.low == leaf.high {
        comp = insert_at_end_named(create_icmp(ICMP_EQ, val, leaf.low), new_leaf, "SwitchLeaf");
    } else if leaf.low == lower_bound {
        comp = insert_at_end_named(create_icmp(ICMP_SLE, val, leaf.high), new_leaf, "SwitchLeaf");
    } else if leaf.high == upper_bound {
        comp = insert_at_end_named(create_icmp(ICMP_SGE, val, leaf.low), new_leaf, "SwitchLeaf");
    } else if ap_is_zero(const_ap(leaf.low)) {
        comp = insert_at_end_named(create_icmp(ICMP_ULE, val, leaf.high), new_leaf, "SwitchLeaf");
    } else {
        t := vtype(val);
        neg_lo := ap_neg(const_ap(leaf.low));
        add := insert_at_end_named(create_binop(.ADD, val, const_int_ap(t, neg_lo)), new_leaf, tconcat(vname(val), ".off"));
        ub := const_int_ap(t, ap_add(neg_lo, const_ap(leaf.high)));
        comp = insert_at_end_named(create_icmp(ICMP_ULE, add, ub), new_leaf, "SwitchLeaf");
    }
    succ := leaf.bb;
    block_append_inst(new_leaf, create_cond_br(comp, succ, default));

    // If there were any PHI nodes in the default block, add an entry for the new leaf
    for block_insts(default) {
        if inst_op(it) != .PHI break;
        idx := phi_block_index(it, orig_block);
        v: Value_Id = NONE;
        if idx >= 0 v = phi_value(it, cast(u32) idx);
        phi_add_incoming(it, v, new_leaf);
    }
    // If there were any PHI nodes in the successor, rewrite one entry from OrigBlock to come from NewLeaf
    range := ls_count(ap_sub(const_ap(leaf.high), const_ap(leaf.low)));
    for :early_inc block_insts(succ) {
        if inst_op(it) != .PHI break;
        pn := it;
        j: u64 = 0;
        while j < range { phi_remove_incoming_block(pn, orig_block); j += 1; }
        bi := phi_block_index(pn, orig_block);
        assert(bi != -1, "Switch didn't go to this successor??");
        phi_set_block(pn, cast(u32) bi, new_leaf);
    }
    return new_leaf;
}

// SwitchConvert
ls_switch_convert :: (cases: [] Ls_Case_Range, lower_bound: Value_Id, upper_bound: Value_Id, val: Value_Id,
                      predecessor: Value_Id, orig_block: Value_Id, default: Value_Id,
                      unreachable_ranges: [] Ls_Int_Range) -> Value_Id {
    size := cases.count;
    if size == 1 {
        c := cases[0];
        if c.low == lower_bound && c.high == upper_bound {
            n := ls_count(ap_sub(const_ap(upper_bound), const_ap(lower_bound)));
            ls_fix_phis(c.bb, orig_block, predecessor, n);
            return c.bb;
        }
        return ls_new_leaf_block(c, val, lower_bound, upper_bound, orig_block, default);
    }
    mid := size / 2;
    lhs := array_view(cases, 0, mid);
    rhs := array_view(cases, mid, size - mid);
    pivot := cases[mid];
    t := vtype(val);
    new_lower_bound := pivot.low;
    new_upper_bound := const_int_ap(t, ap_sub_u64(const_ap(new_lower_bound), 1));
    if unreachable_ranges.count {
        gap: Ls_Int_Range;
        gap.low = ap_add_u64(const_ap(lhs[lhs.count - 1].high), 1);
        gap.high = ap_sub_u64(const_ap(new_lower_bound), 1);
        if ap_sge(gap.high, gap.low) && ls_is_in_ranges(gap, unreachable_ranges) new_upper_bound = lhs[lhs.count - 1].high;
    }
    f := block_fn(orig_block);
    new_node := new_block(NONE);
    set_name(new_node, "NodeBlock");
    comp := create_icmp(ICMP_SLT, val, pivot.low);   // named "Pivot" when it is inserted
    l_branch := ls_switch_convert(lhs, lower_bound, new_upper_bound, val, new_node, orig_block, default, unreachable_ranges);
    r_branch := ls_switch_convert(rhs, new_lower_bound, upper_bound, val, new_node, orig_block, default, unreachable_ranges);
    fn_insert_detached_block_after(f, orig_block, new_node);
    insert_at_end_named(comp, new_node, "Pivot");
    block_append_inst(new_node, create_cond_br(comp, l_branch, r_branch));
    return new_node;
}

// Clusterify
ls_clusterify :: (cases: *[..] Ls_Case_Range, si: Value_Id) -> u32 {
    num_simple: u32 = 0;
    n := sw_num_cases(si);
    def := sw_default(si);
    if n > 0 for k: 0..n-1 {
        if sw_case_dest(si, k) == def continue;
        cv := sw_case_value(si, k);
        array_add(cases, .{cv, cv, sw_case_dest(si, k)});
        num_simple += 1;
    }
    // llvm::sort(Cases, CaseCmp()): case values are distinct, so any sort gives the same order
    quick_sort(cases.*, (a: Ls_Case_Range, b: Ls_Case_Range) -> s64 {
        if ap_slt(const_ap(a.low), const_ap(b.high)) return -1;
        if ap_slt(const_ap(b.low), const_ap(a.high)) return 1;
        return 0;
    });
    if cases.count >= 2 {
        i := 0;
        for j: 1..cases.count-1 {
            next_value := const_ap(cases.*[j].low);
            current_value := const_ap(cases.*[i].high);
            if ap_eq(next_value, ap_add_u64(current_value, 1)) && cases.*[i].bb == cases.*[j].bb {
                cases.*[i].high = cases.*[j].high;
            } else {
                i += 1;
                if i != j cases.*[i] = cases.*[j];
            }
        }
        cases.count = i + 1;
    }
    return num_simple;
}

Ls_Delete_List :: struct { blocks: [..] Value_Id; }
ls_delete_list_insert :: (d: *Ls_Delete_List, b: Value_Id) {
    for d.blocks if it == b return;
    array_add(*d.blocks, b);
    if d.blocks.count > 8 fatal("lower-switch: more than 8 blocks to delete: LLVM deletes them in SmallPtrSet (pointer address) order");
}
ls_delete_list_contains :: (d: *Ls_Delete_List, b: Value_Id) -> bool {
    for d.blocks if it == b return true;
    return false;
}

// ProcessSwitchInst
ls_process_switch_inst :: (si: Value_Id, delete_list: *Ls_Delete_List, ac: *Assumption_Cache, lvi: *Lvi) {
    orig_block := inst_block(si);
    f := block_fn(orig_block);
    val := sw_cond(si);
    default := sw_default(si);

    if (orig_block != fn_entry(f) && !block_has_predecessors(orig_block)) || block_single_predecessor(orig_block) == orig_block {
        ls_delete_list_insert(delete_list, orig_block);
        return;
    }

    cases: [..] Ls_Case_Range; cases.allocator = temp;
    num_simple_cases := ls_clusterify(*cases, si);

    t := vtype(val);
    bit_width := type_int_width(t);
    unsigned_zero := ap_zero(bit_width + 1);
    unsigned_max := ls_count(ap_all_ones(bit_width));

    if cases.count == 0 {
        block_append_inst(orig_block, create_br(default));
        ls_fix_phis(default, orig_block, orig_block, unsigned_max);
        drop_all_references(si);
        erase_inst(si);
        return;
    }

    lower_bound: Value_Id = NONE;
    upper_bound: Value_Id = NONE;
    default_is_unreachable_from_switch := false;
    if sw_default_dest_unreachable(si) {
        lower_bound = cases[0].low;
        upper_bound = cases[cases.count - 1].high;
        default_is_unreachable_from_switch = true;
    } else {
        known := known_bits_ctx(val, si, null, ac);
        known_bits_range := cr_from_known_bits(known, false);
        lvi_range := lvi_get_constant_range(lvi, val, si, false);
        val_range := cr_intersect(known_bits_range, lvi_range);
        low := const_ap(cases[0].low);
        high := const_ap(cases[cases.count - 1].high);
        mn := ap_smin(cr_smin(val_range), low);
        mx := ap_smax(cr_smax(val_range), high);
        lower_bound = const_int_ap(t, mn);
        upper_bound = const_int_ap(t, mx);
        default_is_unreachable_from_switch = ap_eq(ap_add_u64(mn, cast(u64)(num_simple_cases - 1)), mx);
    }

    unreachable_ranges: [..] Ls_Int_Range; unreachable_ranges.allocator = temp;
    if default_is_unreachable_from_switch {
        Pop :: struct { bb: Value_Id; n: APInt; }
        popularity: [..] Pop; popularity.allocator = temp;
        max_pop := unsigned_zero;
        pop_succ: Value_Id = NONE;
        signed_max := ap_signed_max(bit_width);
        signed_min := ap_signed_min(bit_width);
        array_add(*unreachable_ranges, .{signed_min, signed_max});
        for c: cases {
            low := const_ap(c.low);
            high := const_ap(c.high);
            last := *unreachable_ranges[unreachable_ranges.count - 1];
            if ap_eq(last.low, low) {
                unreachable_ranges.count -= 1;
            } else {
                last.high = ap_sub_u64(low, 1);
            }
            if ap_ne(high, signed_max) array_add(*unreachable_ranges, .{ap_add_u64(high, 1), signed_max});
            n := ap_add_u64(ap_sub(ap_sext(high, bit_width + 1), ap_sext(low, bit_width + 1)), 1);
            p: *Pop = null;
            for *popularity if it.bb == c.bb { p = it; break; }
            if !p { array_add(*popularity, .{c.bb, unsigned_zero}); p = *popularity[popularity.count - 1]; }
            p.n = ap_add(p.n, n);
            if ap_ugt(p.n, max_pop) { max_pop = p.n; pop_succ = c.bb; }
        }
        num_default_edges := sw_num_cases(si) + 1 - num_simple_cases;
        for 0..cast(s64) num_default_edges - 1 block_remove_predecessor(default, orig_block);
        default = pop_succ;
        w := 0;
        for c: cases if c.bb != pop_succ { cases[w] = c; w += 1; }
        cases.count = w;
        if cases.count == 0 {
            block_append_inst(orig_block, create_br(default));
            drop_all_references(si);
            erase_inst(si);
            if !ap_is_zero(max_pop) {
                k := ls_count(ap_sub_u64(max_pop, 1));
                i: u64 = 0;
                while i < k { block_remove_predecessor(pop_succ, orig_block); i += 1; }
            }
            return;
        }
        val = sw_cond(si);
    }

    switch_block := ls_switch_convert(cases, lower_bound, upper_bound, val, orig_block, orig_block, default, unreachable_ranges);
    if switch_block != default ls_fix_phis(default, orig_block, NONE, unsigned_max);
    block_append_inst(orig_block, create_br(switch_block));
    old_default := sw_default(si);
    drop_all_references(si);
    erase_inst(si);
    if !block_has_predecessors(old_default) ls_delete_list_insert(delete_list, old_default);
}

lower_switch_run :: (f: Value_Id) -> Preserved {
    lvi := get_lvi(f);
    ac := cached_assumption_cache(f);
    changed := false;
    dl: Ls_Delete_List; dl.blocks.allocator = temp;
    cur := fn_entry(f);
    while cur != NONE {
        nx := block(cur).next;   // make_early_inc_range(F)
        defer cur = nx;
        if ls_delete_list_contains(*dl, cur) continue;
        t := block_terminator(cur);
        if t != NONE && inst_op(t) == .SWITCH {
            changed = true;
            ls_process_switch_inst(t, *dl, ac, lvi);
        }
    }
    for dl.blocks {
        lvi_erase_block(lvi, it);
        delete_dead_block(it, null);
    }
    if changed return PRESERVE_NONE;
    return PRESERVE_ALL;
}
