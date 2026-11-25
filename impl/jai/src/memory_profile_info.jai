// MemoryProfileInfo: port of llvm/lib/Analysis/MemoryProfileInfo.cpp (LLVM 23.1.5): the CallStackTrie built from
// existing !memprof MIB metadata (addCallStack(MDNode), buildAndAttachMIBMetadata, buildMIBNodes,
// saveFilteredNewMIBNodes, createMIBNode, convertHotToNotCold, addSingleAllocTypeAttribute), the memprof cl::opts,
// getMIBStackNode / getMIBAllocType / buildCallstackMetadata and the "memprof" ambiguous attribute helpers.
// Used by InlineFunction's propagateMemProfMetadata (inline_function.jai). Optimization remarks are not emitted;
// -memprof-report-hinted-sizes output on stderr fails loudly.
// Data layout: trie nodes are rows of `Mpi_Trie.nodes`; a node's callers are kept sorted by stack id
// (std::map<uint64_t, CallStackTrieNode *>).

mpi_cl: struct {
    report_hinted_sizes := false;          // -memprof-report-hinted-sizes
    keep_all_not_cold_contexts := false;   // -memprof-keep-all-not-cold-contexts
    min_cloned_cold_byte_percent: u64 = 100;    // -memprof-cloning-cold-threshold
    min_callsite_cold_byte_percent: u64 = 100;  // -memprof-callsite-cold-threshold
    min_percent_max_cold_size: u64 = 100;       // -memprof-min-percent-max-cold-size
    keep_context_size_info := false;       // -memprof-keep-context-size-info
    use_ambiguous_attributes := true;      // -memprof-ambiguous-attributes
};

mpi_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    b :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    u :: (name: string, value: string, has_value: bool) -> u64 {
        v, ok := string_to_int(value);
        if !has_value || !ok || v < 0 fatal("invalid integer value '%' for option -%", value, name);
        return cast(u64) v;
    }
    if name == {
        case "memprof-report-hinted-sizes"; mpi_cl.report_hinted_sizes = b(name, value, has_value);
        case "memprof-keep-all-not-cold-contexts"; mpi_cl.keep_all_not_cold_contexts = b(name, value, has_value);
        case "memprof-cloning-cold-threshold"; mpi_cl.min_cloned_cold_byte_percent = u(name, value, has_value);
        case "memprof-callsite-cold-threshold"; mpi_cl.min_callsite_cold_byte_percent = u(name, value, has_value);
        case "memprof-min-percent-max-cold-size"; mpi_cl.min_percent_max_cold_size = u(name, value, has_value);
        case "memprof-keep-context-size-info"; mpi_cl.keep_context_size_info = b(name, value, has_value);
        case "memprof-ambiguous-attributes"; mpi_cl.use_ambiguous_attributes = b(name, value, has_value);
        case; return false;
    }
    return true;
}

// AllocationType
MPI_NONE :: cast(u8) 0; MPI_NOT_COLD :: cast(u8) 1; MPI_COLD :: cast(u8) 2; MPI_HOT :: cast(u8) 4;

mpi_metadata_includes_all_context_size_info :: () -> bool {
    return mpi_cl.report_hinted_sizes || mpi_cl.keep_context_size_info || mpi_cl.min_cloned_cold_byte_percent < 100;
}

// getMIBStackNode
mpi_mib_stack_node :: (mib: Md_Id) -> Md_Id { return md_op(mib, 0); }
// getMIBAllocType
mpi_mib_alloc_type :: (mib: Md_Id) -> u8 {
    s := md_op(mib, 1);
    if s == NONE || ir.mds[s].kind != .STRING return MPI_NOT_COLD;
    if ir.mds[s].str == "cold" return MPI_COLD;
    if ir.mds[s].str == "hot" return MPI_HOT;
    return MPI_NOT_COLD;
}
mpi_alloc_type_string :: (t: u8) -> string {
    if t == MPI_NOT_COLD return "notcold";
    if t == MPI_COLD return "cold";
    if t == MPI_HOT return "hot";
    fatal("internal: memprof: unexpected alloc type %", t);
    return "";
}
mpi_has_single_alloc_type :: (t: u8) -> bool { return popcount(cast(u64) t) == 1; }

mpi_md_u64 :: (v: u64) -> Md_Id { return md_value(const_int(ir.t_i64, v)); }
mpi_md_zext :: (m: Md_Id) -> u64 {
    ok, v := md_const_int_value(m);
    if !ok fatal("internal: memprof: a stack id that is not a ConstantInt");
    return v;
}
// buildCallstackMetadata
mpi_build_callstack_metadata :: (stack: [] u64) -> Md_Id {
    ops := NewArray(stack.count, Md_Id,, temp);
    for stack ops[it_index] = mpi_md_u64(it);
    return md_tuple(ops, false);
}

// CallBase "memprof" string attribute helpers
mpi_has_memprof_attr :: (cb: Value_Id) -> bool { return attr_set_has_str(attr_list_fn(inst(cb).attrs), "memprof"); }
mpi_remove_memprof_attr :: (cb: Value_Id) {
    l := inst(cb).attrs;
    inst(cb).attrs = attr_list_with_fn(l, attr_set_remove_str(attr_list_fn(l), "memprof"));
}
mpi_add_memprof_attr :: (cb: Value_Id, val: string) {
    a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = "memprof"; a.val = val;
    call_add_fn_attr(cb, a);
}
// removeAnyExistingAmbiguousAttribute
mpi_remove_any_existing_ambiguous_attribute :: (cb: Value_Id) { if mpi_has_memprof_attr(cb) mpi_remove_memprof_attr(cb); }
// addAmbiguousAttribute
mpi_add_ambiguous_attribute :: (cb: Value_Id) {
    if !mpi_cl.use_ambiguous_attributes return;
    if !mpi_has_memprof_attr(cb) mpi_add_memprof_attr(cb, "ambiguous");
}

// ---------------------------------------------------------------- CallStackTrie

Mpi_Ctx_Size :: struct { full_stack_id: u64; total_size: u64; alloc_type: u8; }   // ContextSizeTypePair
Mpi_Node :: struct {
    alloc_types: u8;
    context_info: [..] Mpi_Ctx_Size;
    caller_ids: [..] u64;    // sorted
    caller_nodes: [..] s64;
}
Mpi_Trie :: struct {
    nodes: [..] Mpi_Node;
    alloc: s64 = -1;
    alloc_stack_id: u64;
    max_cold_size: u64;
    built_from_existing_metadata: bool;
}

mpi_new_node :: (t: *Mpi_Trie, at: u8) -> s64 {
    n: Mpi_Node;
    n.alloc_types = at;
    n.context_info.allocator = temp; n.caller_ids.allocator = temp; n.caller_nodes.allocator = temp;
    array_add(*t.nodes, n);
    return t.nodes.count - 1;
}

// addCallStack(AllocType, StackIds, ContextSizeInfo)
mpi_add_call_stack_ids :: (t: *Mpi_Trie, at: u8, ids: [] u64, sizes: [] Mpi_Ctx_Size) {
    first := true;
    curr: s64 = -1;
    for id: ids {
        if first {
            first = false;
            if t.alloc >= 0 t.nodes[t.alloc].alloc_types |= at;
            else { t.alloc_stack_id = id; t.alloc = mpi_new_node(t, at); }
            curr = t.alloc;
            continue;
        }
        n := *t.nodes[curr];
        pos := 0;
        while pos < n.caller_ids.count && n.caller_ids[pos] < id pos += 1;
        if pos < n.caller_ids.count && n.caller_ids[pos] == id {
            curr = n.caller_nodes[pos];
            t.nodes[curr].alloc_types |= at;
            continue;
        }
        nn := mpi_new_node(t, at);
        n = *t.nodes[curr];
        array_insert_at(*n.caller_ids, id, pos);
        array_insert_at(*n.caller_nodes, nn, pos);
        curr = nn;
    }
    for sizes { s := it; s.alloc_type = at; array_add(*t.nodes[curr].context_info, s); }
}

// addCallStack(MDNode *MIB)
mpi_add_call_stack :: (t: *Mpi_Trie, mib: Md_Id) {
    t.built_from_existing_metadata = true;
    stack := mpi_mib_stack_node(mib);
    ids := NewArray(md_nops(stack), u64,, temp);
    for k: 0..cast(s64) md_nops(stack) - 1 ids[k] = mpi_md_zext(md_op(stack, cast(u32) k));
    sizes: [..] Mpi_Ctx_Size; sizes.allocator = temp;
    if md_nops(mib) > 2 for k: 2..md_nops(mib) - 1 {
        pair := md_op(mib, k);
        array_add(*sizes, .{mpi_md_zext(md_op(pair, 0)), mpi_md_zext(md_op(pair, 1)), 0});
    }
    mpi_add_call_stack_ids(t, mpi_mib_alloc_type(mib), ids, sizes);
}

// createMIBNode
mpi_create_mib_node :: (t: *Mpi_Trie, stack: [] u64, at: u8, info: [] Mpi_Ctx_Size, total: *u64, cold: *u64) -> Md_Id {
    payload: [..] Md_Id; payload.allocator = temp;
    array_add(*payload, mpi_build_callstack_metadata(stack));
    array_add(*payload, md_string(mpi_alloc_type_string(at)));
    if info.count == 0 return md_tuple(payload, false);
    for info {
        total.* += it.total_size;
        large := false;
        if at == MPI_COLD {
            cold.* += it.total_size;
            if t.built_from_existing_metadata ||
               (t.max_cold_size > 0 && mpi_cl.min_percent_max_cold_size < 100 &&
                it.total_size * 100 >= t.max_cold_size * mpi_cl.min_percent_max_cold_size)
                large = true;
        }
        if mpi_metadata_includes_all_context_size_info() || large {
            array_add(*payload, md_tuple(.[mpi_md_u64(it.full_stack_id), mpi_md_u64(it.total_size)], false));
        }
    }
    return md_tuple(payload, false);
}

// collectContextInfo
mpi_collect_context_info :: (t: *Mpi_Trie, n: s64, out: *[..] Mpi_Ctx_Size) {
    for t.nodes[n].context_info array_add(out, it);
    for t.nodes[n].caller_nodes mpi_collect_context_info(t, it, out);
}

// convertHotToNotCold
mpi_convert_hot_to_not_cold :: (t: *Mpi_Trie, n: s64) {
    nd := *t.nodes[n];
    if nd.alloc_types & MPI_HOT { nd.alloc_types &= ~MPI_HOT; nd.alloc_types |= MPI_NOT_COLD; }
    for t.nodes[n].caller_nodes mpi_convert_hot_to_not_cold(t, it);
}

// saveFilteredNewMIBNodes
mpi_save_filtered_new_mib_nodes :: (t: *Mpi_Trie, new_nodes: [] Md_Id, saved: *[..] Md_Id, caller_len: s64, total: u64, cold: u64) {
    mostly_cold := !t.built_from_existing_metadata && mpi_cl.min_callsite_cold_byte_percent < 100 && cold > 0 &&
                   cold * 100 >= mpi_cl.min_callsite_cold_byte_percent * total;
    if mpi_cl.keep_all_not_cold_contexts && !mostly_cold { for new_nodes array_add(saved, it); return; }
    if mpi_cl.report_hinted_sizes fatal("memprof: -memprof-report-hinted-sizes messages are not supported yet");
    if mostly_cold {
        for new_nodes if mpi_mib_alloc_type(it) == MPI_COLD array_add(saved, it);
        return;
    }
    longer_kept := false;
    for new_nodes {
        if mpi_mib_alloc_type(it) == MPI_COLD continue;
        if cast(s64) md_nops(mpi_mib_stack_node(it)) > caller_len { longer_kept = true; break; }
    }
    keep_first := !longer_kept;
    for new_nodes {
        if mpi_mib_alloc_type(it) != MPI_COLD {
            if cast(s64) md_nops(mpi_mib_stack_node(it)) > caller_len { array_add(saved, it); continue; }
            if keep_first { keep_first = false; array_add(saved, it); continue; }
            continue;
        }
        array_add(saved, it);
    }
}

// buildMIBNodes
mpi_build_mib_nodes :: (t: *Mpi_Trie, n: s64, stack: *[..] u64, mib_nodes: *[..] Md_Id, callee_ambiguous: bool, total: *u64, cold: *u64) -> bool {
    if mpi_has_single_alloc_type(t.nodes[n].alloc_types) {
        info: [..] Mpi_Ctx_Size; info.allocator = temp;
        mpi_collect_context_info(t, n, *info);
        array_add(mib_nodes, mpi_create_mib_node(t, stack.*, t.nodes[n].alloc_types, info, total, cold));
        return true;
    }
    if t.nodes[n].caller_ids.count {
        node_ambiguous := t.nodes[n].caller_ids.count > 1;
        all_added := true;
        new_nodes: [..] Md_Id; new_nodes.allocator = temp;
        ctotal: u64 = 0; ccold: u64 = 0;
        for k: 0..t.nodes[n].caller_ids.count - 1 {
            array_add(stack, t.nodes[n].caller_ids[k]);
            all_added &= mpi_build_mib_nodes(t, t.nodes[n].caller_nodes[k], stack, *new_nodes, node_ambiguous, *ctotal, *ccold);
            stack.count -= 1;
        }
        mpi_save_filtered_new_mib_nodes(t, new_nodes, mib_nodes, stack.count + 1, ctotal, ccold);
        total.* += ctotal;
        cold.* += ccold;
        if all_added return true;
    }
    if !callee_ambiguous return false;
    info: [..] Mpi_Ctx_Size; info.allocator = temp;
    mpi_collect_context_info(t, n, *info);
    array_add(mib_nodes, mpi_create_mib_node(t, stack.*, MPI_NOT_COLD, info, total, cold));
    return true;
}

// addSingleAllocTypeAttribute (remarks are not emitted)
mpi_add_single_alloc_type_attribute :: (t: *Mpi_Trie, cb: Value_Id, at: u8) {
    s := mpi_alloc_type_string(at);
    mpi_remove_any_existing_ambiguous_attribute(cb);
    mpi_add_memprof_attr(cb, s);
    if mpi_cl.report_hinted_sizes fatal("memprof: -memprof-report-hinted-sizes messages are not supported yet");
}

// buildAndAttachMIBMetadata: true if !memprof was attached, false if an attribute was added instead
mpi_build_and_attach_mib_metadata :: (t: *Mpi_Trie, cb: Value_Id) -> bool {
    if mpi_has_single_alloc_type(t.nodes[t.alloc].alloc_types) {
        mpi_add_single_alloc_type_attribute(t, cb, t.nodes[t.alloc].alloc_types);
        return false;
    }
    if t.nodes[t.alloc].alloc_types & MPI_HOT {
        mpi_convert_hot_to_not_cold(t, t.alloc);
        if mpi_has_single_alloc_type(t.nodes[t.alloc].alloc_types) {
            mpi_add_single_alloc_type_attribute(t, cb, t.nodes[t.alloc].alloc_types);
            return false;
        }
    }
    stack: [..] u64; stack.allocator = temp;
    array_add(*stack, t.alloc_stack_id);
    mib_nodes: [..] Md_Id; mib_nodes.allocator = temp;
    total: u64 = 0; cold: u64 = 0;
    if mpi_build_mib_nodes(t, t.alloc, *stack, *mib_nodes, false, *total, *cold) {
        set_metadata(cb, md_fixed("memprof"), md_tuple(mib_nodes, false));
        mpi_add_ambiguous_attribute(cb);
        return true;
    }
    mpi_add_single_alloc_type_attribute(t, cb, MPI_NOT_COLD);
    return false;
}
