// InferAlignment: port of llvm/lib/Transforms/Scalar/InferAlignment.cpp (tryToImproveAlign, inferAlignment).
// The ScopedHashTable of best base-pointer alignments is an undo log with one scope per dominator-tree node.
// tryEnforceAlignment is in ic_loadstorealloca.jai.

Ia_Mode :: enum u8 { ENFORCE_PREF; INFER; }

Ia_State :: struct {
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    best: Table(Value_Id, u64);                  // ScopedHT: visible value (1 = Align() = none)
    undo: [..] struct { key: Value_Id; had: bool; old: u64; };
}

ia_lookup :: (s: *Ia_State, v: Value_Id) -> u64 {
    found, a := table_find(*s.best, v);
    if found return a;
    return 1;
}
ia_insert :: (s: *Ia_State, v: Value_Id, a: u64) {
    found, old := table_find(*s.best, v);
    array_add(*s.undo, .{v, found, old});
    table_set(*s.best, v, a);
}

// the lambda Fn of tryToImproveAlign, chosen by `mode`
ia_fn :: (s: *Ia_State, mode: Ia_Mode, i: Value_Id, ptr: Value_Id, old_align: u64, pref_align: u64) -> u64 {
    if mode == .ENFORCE_PREF {
        if pref_align > old_align return max(old_align, try_enforce_alignment(ptr, pref_align));
        return old_align;
    }
    // InferFromKnownBits
    known := known_bits_ctx(ptr, i, s.dt, s.ac);
    tz := min(kb_count_min_trailing_zeros(known), 32);   // Value::MaxAlignmentExponent
    from_kb := (cast(u64) 1) << min(kb_bits(known) - 1, tz);
    // InferFromBasePointer
    off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
    base: Value_Id;
    base, off = strip_and_accumulate_constant_offsets(ptr, off, true);
    off_v := ap_limited(off);
    base_align := common_alignment(old_align, off_v);
    from_base := old_align;
    best := ia_lookup(s, base);
    if best != 1 && best > base_align from_base = common_alignment(best, off_v);
    else ia_insert(s, base, base_align);
    return max(from_kb, from_base);
}

ia_try_to_improve_align :: (s: *Ia_State, mode: Ia_Mode, i: Value_Id) -> bool {
    ptr := load_store_pointer_operand(i);
    if ptr != NONE {
        old_align := inst(i).align;
        pref_align := dl_pref_align(load_store_type(i));
        new_align := ia_fn(s, mode, i, ptr, old_align, pref_align);
        if new_align > old_align { inst(i).align = new_align; return true; }
    }
    o := inst_op(i);
    if o == .AND {
        okp, p := pm_ptrtoint_or_addr_v(op(i, 0));
        okc, c := match_apint(op(i, 1));
        if okp && okc {
            actual := ia_fn(s, mode, i, p, 1, 1);
            if ap_active_bits(c) <= 64 && ap_zext_value(c) < actual {   // APInt::ult(uint64_t)
                rauw_with_metadata(i, const_null_value(vtype(i)));
                return true;
            }
            lg := cast(u32) bit_log2(actual);
            if ap_uge(c, ap_bits_set_from(c.bits, lg)) {
                rauw_with_metadata(i, op(i, 0));
                return true;
            }
        }
    }
    if o == .TRUNC {
        okp, p := pm_ptrtoint_or_addr_v(op(i, 0));
        if okp {
            actual := ia_fn(s, mode, i, p, 1, 1);
            if bit_log2(actual) >= cast(s64) type_bits(scalar_type(vtype(i))) {
                rauw_with_metadata(i, const_null_value(vtype(i)));
                return true;
            }
        }
    }
    id := call_iid(i);
    if id == IID_MASKED_LOAD || id == IID_MASKED_STORE {
        ptr_idx: u32 = ifx id == IID_MASKED_LOAD then cast(u32) 0 else 1;
        p := op(i, ptr_idx);
        ty := ifx id == IID_MASKED_LOAD then vtype(i) else vtype(op(i, 0));
        old_align := max(call_param_align(i, ptr_idx), 1);
        new_align := ia_fn(s, mode, i, p, old_align, dl_pref_align(ty));
        if new_align <= old_align return false;
        a: Attr; a.kind = .Alignment; a.ty = NONE; a.ival = new_align;
        call_add_param_attr(i, ptr_idx, a);
        return true;
    }
    return false;
}

bit_log2 :: (x: u64) -> s64 { n := -1; y := x; while y { y >>= 1; n += 1; } return n; }

infer_alignment_run :: (f: Value_Id) -> Preserved {
    s: Ia_State;
    s.ac = get_assumption_cache(f);
    s.dt = get_domtree(f);
    s.best.allocator = temp; s.undo.allocator = temp;
    for i: fn_insts(f) ia_try_to_improve_align(*s, .ENFORCE_PREF, i);
    // DFS over the dominator tree, a scope per node
    Frame :: struct { n: s32; child: s32; undo_mark: s64; }
    stack: [..] Frame; stack.allocator = temp;
    process :: (s: *Ia_State, stack: *[..] Frame, n: s32) {
        array_add(stack, .{n, s.dt.nodes[n].first_child, s.undo.count});
        for i: block_insts(s.dt.nodes[n].block) ia_try_to_improve_align(s, .INFER, i);
    }
    process(*s, *stack, s.dt.root_node);
    while stack.count {
        top := *stack[stack.count - 1];
        if top.child >= 0 {
            c := top.child;
            top.child = s.dt.nodes[c].sibling;
            process(*s, *stack, c);
            continue;
        }
        // ~ScopeTy: undo this scope's insertions, newest first
        while s.undo.count > top.undo_mark {
            u := pop(*s.undo);
            if u.had table_set(*s.best, u.key, u.old); else table_remove(*s.best, u.key);
        }
        stack.count -= 1;
    }
    return PRESERVE_ALL;
}
