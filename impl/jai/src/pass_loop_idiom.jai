// LoopIdiomRecognize: llvm/lib/Transforms/Scalar/LoopIdiomRecognize.cpp (complete: memset / memset.pattern /
// memcpy / memmove from strided stores and mem intrinsics, the CRC table rewrite (HashRecognize), strlen /
// wcslen, popcount, ctlz / cttz (shift until zero / less than), shift-until-bittest, shift-until-zero).
// LoopIdiomRecognize is the `Lir` struct; its methods are `lir_*`.

lir_opts: struct {
    disable_all := false;            // -disable-loop-idiom-all
    disable_memset := false;         // -disable-loop-idiom-memset
    disable_memcpy := false;         // -disable-loop-idiom-memcpy
    disable_strlen := false;         // -disable-loop-idiom-strlen
    disable_wcslen := false;         // -disable-loop-idiom-wcslen
    disable_hash_recognize := false; // -disable-loop-idiom-hashrecognize
    use_code_size_heurs := true;     // -use-lir-code-size-heurs
    force_memset_pattern_intrinsic := false;   // -loop-idiom-force-memset-pattern-intrinsic
};
LIR_CL_OPT_COUNT :: 8;
add_lir_cl_opts :: (list: [] Cl_Opt, base: s64) {
    list[base + 0] = .{"disable-loop-idiom-all", .BOOL, *lir_opts.disable_all, null, null};
    list[base + 1] = .{"disable-loop-idiom-memset", .BOOL, *lir_opts.disable_memset, null, null};
    list[base + 2] = .{"disable-loop-idiom-memcpy", .BOOL, *lir_opts.disable_memcpy, null, null};
    list[base + 3] = .{"disable-loop-idiom-strlen", .BOOL, *lir_opts.disable_strlen, null, null};
    list[base + 4] = .{"disable-loop-idiom-wcslen", .BOOL, *lir_opts.disable_wcslen, null, null};
    list[base + 5] = .{"disable-loop-idiom-hashrecognize", .BOOL, *lir_opts.disable_hash_recognize, null, null};
    list[base + 6] = .{"use-lir-code-size-heurs", .BOOL, *lir_opts.use_code_size_heurs, null, null};
    list[base + 7] = .{"loop-idiom-force-memset-pattern-intrinsic", .BOOL, *lir_opts.force_memset_pattern_intrinsic, null, null};
}

Lir_Store_Kind :: enum u8 { NONE; MEMSET; MEMSET_PATTERN; MEMCPY; UNORDERED_ATOMIC_MEMCPY; }

// MapVector<Value *, StoreList>
Lir_Store_Map :: struct {
    keys: [..] Value_Id;
    lists: [..] [..] Value_Id;
}
lir_map_add :: (m: *Lir_Store_Map, key: Value_Id, si: Value_Id) {
    for m.keys if it == key { array_add(*m.lists[it_index], si); return; }
    array_add(*m.keys, key);
    l: [..] Value_Id; l.allocator = temp;
    array_add(*l, si);
    array_add(*m.lists, l);
}

Lir :: struct {
    l: Loop_Id;
    fn: Value_Id;
    aar: Aa_Results;
    dt: *Dom_Tree;
    li: *Loop_Info;
    tli: *Tli;
    tti: *Tti;
    mssau: *Mssa_Updater;
    apply_code_size_heuristics: bool;
    has_memset: bool;
    has_memset_pattern: bool;
    has_memcpy: bool;
    refs_memset: Lir_Store_Map;
    refs_memset_pattern: Lir_Store_Map;
    refs_memcpy: [..] Value_Id;
}

lir_fl :: (c: bool, f: u32) -> u32 { if c return f; return 0; }

// deleteDeadInstruction
lir_delete_dead_instruction :: (i: Value_Id) {
    rauw_with_metadata(i, const_poison(vtype(i)));
    erase_inst_with_metadata(i);
}

// Value::replaceUsesOutsideBlock(New, BB)
replace_uses_outside_block :: (v: Value_Id, new: Value_Id, bb: Value_Id) {
    // replaceDbgUsesOutsideBlock
    recs: [..] u32; recs.allocator = temp;
    find_dbg_users(block_fn(bb), v, *recs);
    for recs if inst_block(dbgr(it).owner) != bb dbgr_replace_variable_location_op(it, v, new);
    u := ir.v_first_use[v];
    while u != NONE {
        nx := ir.u_next[u];
        usr := ir.u_user[u];
        if !(is_inst(usr) && inst_block(usr) == bb) use_set(u, new);
        u = nx;
    }
}

// Value::takeName(V) when `dst` may be a constant: a constant cannot take a name, but V still loses its own
lir_take_name :: (dst: Value_Id, src: Value_Id) {
    if !is_inst(dst) { if vname(src).count set_name(src, ""); return; }
    if vname(dst).count set_name(dst, "");
    take_name(dst, src);
}

// m_scev_AffineAddRec(m_SCEV(Start), m_SCEVConstant(Step), m_SpecificLoop(L))
lir_affine_addrec_const_step :: (s: Scev_Id, l: Loop_Id) -> (bool, Scev_Id, Scev_Id) {
    if !sc_is_addrec(s) || !sc_is_affine(s) || sc_loop(s) != l return false, SCEV_CNC, SCEV_CNC;
    if !sc_is_const(sc_op(s, 1)) return false, SCEV_CNC, SCEV_CNC;
    return true, sc_op(s, 0), sc_op(s, 1);
}

// Function::hasProfileData
fn_has_profile_data :: (f: Value_Id) -> bool { ok, _ := fn_entry_count(f); return ok; }

// isMustProgress(L)
li_is_must_progress :: (l: Loop_Id, f: Value_Id) -> bool { return fn_must_progress(f) || li_has_must_progress(l); }

// DataLayout::hasUnstableRepresentation / hasExternalState of a (vector of) pointer type
dl_has_unstable_representation :: (t: Type_Id) -> bool {
    s := scalar_type(t);
    return type_kind(s) == .PTR && dl_ptr_spec(cast(u32) ir.types[s].a).unstable;
}
dl_has_external_state :: (t: Type_Id) -> bool {
    s := scalar_type(t);
    return type_kind(s) == .PTR && dl_ptr_spec(cast(u32) ir.types[s].a).external;
}

// getMemSetPatternValue
lir_mem_set_pattern_value :: (v: Value_Id) -> Value_Id {
    if !is_constant_kind(vkind(v)) || vkind(v) == .C_EXPR return NONE;
    size := dl_type_size_bits(vtype(v));
    if size == 0 || (size & 7) != 0 || (size & (size - 1)) != 0 return NONE;
    if dl.big_endian return NONE;
    size /= 8;
    if size > 16 return NONE;
    ct := vtype(v);
    if !(is_int_type(ct) || type_kind(ct) == .PTR) && !is_fp_type(ct) return NONE;
    return v;
}

// isLegalStore
lir_is_legal_store :: (c: *Lir, si: Value_Id) -> Lir_Store_Kind {
    if (inst(si).flags & F_VOLATILE) != 0 return .NONE;
    if !is_unordered(si) return .NONE;
    if get_metadata(si, md_fixed("nontemporal")) != NONE return .NONE;
    stored := op(si, 0);
    ptr := op(si, 1);
    if dl_has_unstable_representation(vtype(stored)) return .NONE;
    must_preserve_external := dl_has_external_state(vtype(stored)) && vkind(stored) != .C_NULL;
    if type_is_scalable(vtype(stored)) return .NONE;
    bits := dl_type_size_bits(vtype(stored));
    if (bits & 7) != 0 || (bits >> 32) != 0 return .NONE;
    ok, _, stride := lir_affine_addrec_const_step(sc_get_scev(ptr), c.l);
    if !ok return .NONE;
    splat := is_bytewise_value(stored);
    unordered_atomic := inst(si).ord1 != 0;   // isUnordered() && !isSimple()
    if !must_preserve_external && !unordered_atomic && c.has_memset && splat != NONE && !lir_opts.disable_memset &&
       li_is_loop_invariant(c.li, c.l, splat) return .MEMSET;
    if !must_preserve_external && !unordered_atomic && (c.has_memset_pattern || lir_opts.force_memset_pattern_intrinsic) &&
       !lir_opts.disable_memset && ptr_addrspace(vtype(ptr)) == 0 && lir_mem_set_pattern_value(stored) != NONE
        return .MEMSET_PATTERN;
    if c.has_memcpy && !lir_opts.disable_memcpy {
        store_size := dl_type_store_size(vtype(stored));
        sap := sc_ap(stride);
        ss := ap_from_u64(sap.bits, store_size);
        if !ap_eq(ss, sap) && !ap_eq(ss, ap_neg(sap)) return .NONE;
        ld := stored;
        if !is_inst(ld) || inst_op(ld) != .LOAD || (inst(ld).flags & F_VOLATILE) != 0 return .NONE;
        if !is_unordered(ld) return .NONE;
        lev := sc_get_scev(op(ld, 0));
        if !sc_is_addrec(lev) || !sc_is_affine(lev) || sc_loop(lev) != c.l || sc_op(lev, 1) != stride return .NONE;
        unordered_atomic = unordered_atomic || inst(ld).ord1 != 0;
        return ifx unordered_atomic then Lir_Store_Kind.UNORDERED_ATOMIC_MEMCPY else .MEMCPY;
    }
    return .NONE;
}

// collectStores
lir_collect_stores :: (c: *Lir, bb: Value_Id) {
    c.refs_memset.keys.count = 0; c.refs_memset.lists.count = 0;
    c.refs_memset_pattern.keys.count = 0; c.refs_memset_pattern.lists.count = 0;
    c.refs_memcpy.count = 0;
    for i: block_insts(bb) {
        if inst_op(i) != .STORE continue;
        k := lir_is_legal_store(c, i);
        if k == {
            case .NONE;
            case .MEMSET; lir_map_add(*c.refs_memset, get_underlying_object(op(i, 1)), i);
            case .MEMSET_PATTERN; lir_map_add(*c.refs_memset_pattern, get_underlying_object(op(i, 1)), i);
            case .MEMCPY; #through;
            case .UNORDERED_ATOMIC_MEMCPY; array_add(*c.refs_memcpy, i);
        }
    }
}

// runOnLoopBlock
lir_run_on_loop_block :: (c: *Lir, bb: Value_Id, be_count: Scev_Id, exits: [] Value_Id) -> bool {
    for exits if !dt_dominates(c.dt, bb, it) return false;
    made := false;
    lir_collect_stores(c, bb);
    for c.refs_memset.lists made |= lir_process_loop_stores(c, it, be_count, true);
    for c.refs_memset_pattern.lists made |= lir_process_loop_stores(c, it, be_count, false);
    for c.refs_memcpy made |= lir_process_loop_store_of_loop_load_si(c, it, be_count);
    made |= lir_process_loop_mem_intrinsics(c, bb, be_count, true);
    made |= lir_process_loop_mem_intrinsics(c, bb, be_count, false);
    return made;
}

lir_store_stride :: (s: Scev_Id) -> APInt { return sc_ap(sc_op(s, 1)); }

// processLoopStores
lir_process_loop_stores :: (c: *Lir, sl: [] Value_Id, be_count: Scev_Id, for_memset: bool) -> bool {
    heads: [..] Value_Id; heads.allocator = temp;   // SetVector
    tails: [..] Value_Id; tails.allocator = temp;
    chain: Table(Value_Id, Value_Id); chain.allocator = temp;
    set_insert :: (s: *[..] Value_Id, v: Value_Id) { for s.* if it == v return; array_add(s, v); }
    e := sl.count;
    for i: 0..e-1 {
        first_val := op(sl[i], 0);
        first_ev := sc_get_scev(op(sl[i], 1));
        first_stride := lir_store_stride(first_ev);
        first_size := dl_type_store_size(vtype(first_val));
        fs := ap_from_u64(first_stride.bits, first_size);
        if ap_eq(first_stride, fs) || ap_eq(ap_neg(first_stride), fs) { set_insert(*heads, sl[i]); continue; }
        first_splat: Value_Id = NONE; first_pattern: Value_Id = NONE;
        if for_memset first_splat = is_bytewise_value(first_val);
        else first_pattern = lir_mem_set_pattern_value(first_val);
        queue: [..] s64; queue.allocator = temp;
        for j: i+1..e-1 array_add(*queue, j);
        j := i;
        while j > 0 { array_add(*queue, j - 1); j -= 1; }
        for k: queue {
            second_ev := sc_get_scev(op(sl[k], 1));
            second_stride := lir_store_stride(second_ev);
            if !(second_stride.bits == first_stride.bits && ap_eq(first_stride, second_stride)) continue;
            second_val := op(sl[k], 0);
            second_splat: Value_Id = NONE; second_pattern: Value_Id = NONE;
            if for_memset second_splat = is_bytewise_value(second_val);
            else second_pattern = lir_mem_set_pattern_value(second_val);
            if is_consecutive_access(sl[i], sl[k], false) {
                if for_memset {
                    if is_undef_value(first_splat) first_splat = second_splat;
                    if first_splat != second_splat continue;
                } else {
                    if is_undef_value(first_pattern) first_pattern = second_pattern;
                    if first_pattern != second_pattern continue;
                }
                set_insert(*tails, sl[k]);
                set_insert(*heads, sl[i]);
                table_set(*chain, sl[i], sl[k]);
                break;
            }
        }
    }
    transformed: Table(Value_Id, bool); transformed.allocator = temp;
    changed := false;
    for head: heads {
        if block_set_contains(tails, head) continue;
        adjacent: [..] Value_Id; adjacent.allocator = temp;   // SmallPtrSet<Instruction *, 8>
        i := head;
        store_size: u64 = 0;
        while block_set_contains(tails, i) || block_set_contains(heads, i) {
            if table_contains(*transformed, i) break;
            if !block_set_contains(adjacent, i) array_add(*adjacent, i);
            store_size += dl_type_store_size(vtype(op(i, 0)));
            found, nx := table_find(*chain, i);
            i = ifx found then nx else NONE;   // ConsecutiveChain[I] default-inserts nullptr
            if i == NONE break;
        }
        stored := op(head, 0);
        ptr := op(head, 1);
        ev := sc_get_scev(ptr);
        stride := lir_store_stride(ev);
        ss := ap_from_u64(stride.bits, store_size);
        if !ap_eq(ss, stride) && !ap_eq(ss, ap_neg(stride)) continue;
        is_neg := ap_eq(ss, ap_neg(stride));
        idx_ty := dl_index_type(vtype(ptr));
        size_scev := sc_get_constant(ap_from_u64(type_int_width(idx_ty), store_size));
        if adjacent.count > 8 fatal("loop-idiom: a chain of more than 8 adjacent stores (SmallPtrSet iteration order) is not supported yet");
        if lir_process_loop_strided_store(c, ptr, size_scev, inst(head).align, stored, head, adjacent, ev, be_count, is_neg) {
            for adjacent table_set(*transformed, it, true);
            changed = true;
        }
    }
    return changed;
}

// processLoopMemIntrinsic<MemCpyInst | MemSetInst>
lir_process_loop_mem_intrinsics :: (c: *Lir, bb: Value_Id, be_count: Scev_Id, memcpy: bool) -> bool {
    made := false;
    i := block_first(bb);
    while i != NONE {
        inst_ := i;
        i = inst_next(i);
        iid := call_iid(inst_);
        is_it := ifx memcpy then (iid == IID_MEMCPY || iid == IID_MEMCPY_INLINE) else (iid == IID_MEMSET || iid == IID_MEMSET_INLINE);
        if !is_it continue;
        next_ptr := i;   // WeakTrackingVH InstPtr(&*I)
        ok := ifx memcpy then lir_process_loop_memcpy(c, inst_, be_count) else lir_process_loop_memset(c, inst_, be_count);
        if !ok continue;
        made = true;
        if next_ptr != NONE && vkind(next_ptr) == .DEAD i = block_first(bb);
    }
    return made;
}

// processLoopMemCpy
lir_process_loop_memcpy :: (c: *Lir, mci: Value_Id, be_count: Scev_Id) -> bool {
    if ic_mem_is_volatile(mci) || vkind(call_arg(mci, 2)) != .C_INT return false;
    force_inlined := call_iid(mci) == IID_MEMCPY_INLINE;
    if (!c.has_memcpy && !force_inlined) || lir_opts.disable_memcpy return false;
    dest := strip_pointer_casts(call_arg(mci, 0));
    source := strip_pointer_casts(call_arg(mci, 1));
    store_ev := sc_get_scev(dest);
    load_ev := sc_get_scev(source);
    oks, _, sstep := lir_affine_addrec_const_step(store_ev, c.l);
    okl, _, lstep := lir_affine_addrec_const_step(load_ev, c.l);
    if !oks || !okl return false;
    size := const_ap(call_arg(mci, 2));
    if !ap_fits_u64(size) || (ap_zext_value(size) >> 32) != 0 return false;
    size_in_bytes := ap_zext_value(size);
    ssv := sc_ap(sstep); lsv := sc_ap(lstep);
    if ssv.bits > 64 || lsv.bits > 64 return false;
    sb := ap_from_u64(ssv.bits, size_in_bytes);
    if !ap_eq(sb, ssv) && !ap_eq(sb, ap_neg(ssv)) return false;
    if ap_sext_value(ssv) != ap_sext_value(lsv) return false;
    return lir_process_loop_store_of_loop_load(c, dest, source, sc_get_constant(ap_from_u64(dl_index_bits(vtype(dest)), size_in_bytes)),
        mi_param_align(mci, 0), mi_param_align(mci, 1), mci, mci, store_ev, load_ev, be_count);
}

// processLoopMemSet
lir_process_loop_memset :: (c: *Lir, msi: Value_Id, be_count: Scev_Id) -> bool {
    if ic_mem_is_volatile(msi) return false;
    if !c.has_memset || lir_opts.disable_memset return false;
    ptr := strip_pointer_casts(call_arg(msi, 0));
    ev := sc_get_scev(ptr);
    if !sc_is_addrec(ev) || !sc_is_affine(ev) || sc_loop(ev) != c.l return false;
    stride_scev := sc_op(ev, 1);
    len := call_arg(msi, 2);
    memset_size_scev := sc_get_scev(len);
    is_neg := false;
    if vkind(len) == .C_INT {
        size_in_bytes := ap_zext_value(const_ap(len));
        if !sc_is_const(stride_scev) return false;
        stride := sc_ap(stride_scev);
        sb := ap_from_u64(stride.bits, size_in_bytes);
        if !ap_eq(sb, stride) && !ap_eq(sb, ap_neg(stride)) return false;
        is_neg = ap_eq(sb, ap_neg(stride));
    } else {
        if ptr_addrspace(vtype(ptr)) != 0 return false;
        if !sc_is_loop_invariant(memset_size_scev, c.l) return false;
        is_neg = sc_is_non_constant_negative(stride_scev);
        positive := ifx is_neg then sc_get_negative(stride_scev) else stride_scev;
        if positive != memset_size_scev {
            fp := sc_apply_loop_guards(positive, c.l);
            fm := sc_apply_loop_guards(memset_size_scev, c.l);
            if fp != fm return false;
        }
    }
    splat := call_arg(msi, 1);
    if splat == NONE || !li_is_loop_invariant(c.li, c.l, splat) return false;
    stores: [1] Value_Id;
    stores[0] = msi;
    return lir_process_loop_strided_store(c, ptr, sc_get_scev(len), mi_param_align(msi, 0), splat, msi, stores, ev, be_count, is_neg, true);
}

// isSameByteValueStore
lir_is_same_byte_value_store :: (i: Value_Id, splat: Value_Id, li: *Loop_Info, l: Loop_Id) -> bool {
    if inst_op(i) != .STORE || !inst_is_simple(i) || !li_is_loop_invariant(li, l, op(i, 0)) return false;
    return is_bytewise_value(op(i, 0)) == splat;
}

// mayLoopAccessLocation
lir_may_loop_access_location :: (c: *Lir, ptr: Value_Id, access: u8, be_count: Scev_Id, size_scev: Scev_Id, ignored: [] Value_Id, splat: Value_Id = NONE, with_dl := false) -> bool {
    access_size := LS_AFTER;
    if sc_is_const(be_count) && sc_is_const(size_scev) {
        be := sc_ap(be_count); sz := sc_ap(size_scev);
        if ap_fits_u64(be) && ap_fits_u64(sz) access_size = ls_precise((ap_zext_value(be) + 1) * ap_zext_value(sz));
    }
    loc := mloc(ptr, access_size);
    try_same_byte := !ls_is_precise(access_size) && splat != NONE && with_dl;
    for b: li_blocks(c.li, c.l) for i: block_insts(b) {
        if block_set_contains(ignored, i) continue;
        q := aa_query_new(*c.aar);
        if (aa_mod_ref_inst_opt_loc(q, i, true, loc) & access) == 0 continue;
        if try_same_byte && lir_is_same_byte_value_store(i, splat, c.li, c.l) continue;
        return true;
    }
    return false;
}

// getStartForNegStride
lir_start_for_neg_stride :: (start: Scev_Id, be_count: Scev_Id, int_ptr: Type_Id, size_scev: Scev_Id) -> Scev_Id {
    index := sc_get_truncate_or_zero_extend(be_count, int_ptr);
    if !sc_is_one(size_scev) index = sc_get_mul2(index, sc_get_truncate_or_zero_extend(size_scev, int_ptr), SF_NUW);
    return sc_get_minus(start, index);
}
// getNumBytes
lir_num_bytes :: (be_count: Scev_Id, int_ptr: Type_Id, size_scev: Scev_Id, l: Loop_Id) -> Scev_Id {
    tc := sc_get_trip_count_from_exit_count_ty(be_count, int_ptr, l);
    return sc_get_mul2(tc, sc_get_truncate_or_zero_extend(size_scev, int_ptr), SF_NUW);
}

// AAMDNodes::extendTo(Len) (-1 = unknown)
aa_extend_to :: (a: AA_Tags, len: s64) -> AA_Tags {
    r := a;
    if a.tbaa != NONE r.tbaa = tbaa_extend_to(a.tbaa, len);
    return r;
}
// AAMDNodes::extendToTBAA
tbaa_extend_to :: (md: Md_Id, len: s64) -> Md_Id {
    if len == 0 return NONE;
    if !tbaa_tag_is_new_format(md) return md;
    if len == -1 return NONE;
    n := md_nops(md);
    ops := NewArray(n, Md_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 ops[k] = md_op(md, cast(u32) k);
    prev := ir.mds[ops[3]].value;
    if const_int_zext(prev) == cast(u64) len return md;
    ops[3] = md_value(const_int(vtype(prev), cast(u64) len));
    return md_tuple(ops, false);
}

lir_set_aa_metadata :: (call: Value_Id, tags: AA_Tags) {
    // IRBuilder::CreateMem*(..., AAInfo) -> CallInst::setAAMetadata
    if tags.tbaa != NONE set_metadata(call, md_fixed("tbaa"), tags.tbaa);
    if tags.tbaa_struct != NONE set_metadata(call, md_fixed("tbaa.struct"), tags.tbaa_struct);
    if tags.scope != NONE set_metadata(call, md_fixed("alias.scope"), tags.scope);
    if tags.noalias != NONE set_metadata(call, md_fixed("noalias"), tags.noalias);
    if tags.noalias_as != NONE set_metadata(call, md_fixed("noalias.addrspace"), tags.noalias_as);
}

// processLoopStridedStore
lir_process_loop_strided_store :: (c: *Lir, dest_ptr: Value_Id, size_scev: Scev_Id, store_align: u64, stored: Value_Id,
                                   the_store: Value_Id, stores: [] Value_Id, ev: Scev_Id, be_count: Scev_Id,
                                   is_neg: bool, is_loop_memset := false) -> bool {
    dest_as := ptr_addrspace(vtype(dest_ptr));
    preheader := li_loop_preheader(c.li, c.l);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    x: Scev_Expander;
    sx_init(*x, "loop-idiom");
    result_used := false;
    defer if !result_used sx_cleanup(*x);   // SCEVExpanderCleaner
    dest_ptr_ty := type_ptr(dest_as);
    idx_ty := dl_index_type(vtype(dest_ptr));
    changed := false;
    start := sc_start(ev);
    if is_neg start = lir_start_for_neg_stride(start, be_count, idx_ty, size_scev);
    if !sx_is_safe_to_expand(*x, start) return changed;
    base_ptr := sx_expand_code_for_at(*x, start, dest_ptr_ty, block_terminator(preheader));
    changed = true;
    splat := is_bytewise_value(stored);
    if lir_may_loop_access_location(c, base_ptr, MR_MODREF, be_count, size_scev, stores, splat, true) return changed;
    if lir_avoid_for_multi_block_loop(c, true, is_loop_memset) return changed;
    pattern: Value_Id = NONE;
    if splat == NONE pattern = lir_mem_set_pattern_value(stored);
    memset_arg: Value_Id;
    has_bytes := false; bytes_written: s64;
    if pattern != NONE && (c.has_memset_pattern || lir_opts.force_memset_pattern_intrinsic) {
        tcs := sc_get_trip_count_from_exit_count_ty(be_count, idx_ty, c.l);
        if !sx_is_safe_to_expand(*x, tcs) return changed;
        if !sc_is_const(size_scev) return changed;
        tc := sx_expand_code_for_at(*x, tcs, idx_ty, block_terminator(preheader));
        reps := (ap_zext_value(sc_ap(size_scev)) * 8) / dl_type_size_bits(vtype(pattern));
        memset_arg = ifx reps == 1 then tc else irb_binop(*b, .MUL, tc, const_int(idx_ty, reps));
        if vkind(tc) == .C_INT { has_bytes = true; bytes_written = cast(s64) (const_int_zext(tc) * ap_zext_value(sc_ap(size_scev))); }
    } else {
        nbs := lir_num_bytes(be_count, idx_ty, size_scev, c.l);
        if !sx_is_safe_to_expand(*x, nbs) return changed;
        memset_arg = sx_expand_code_for_at(*x, nbs, idx_ty, block_terminator(preheader));
        if vkind(memset_arg) == .C_INT { has_bytes = true; bytes_written = cast(s64) const_int_zext(memset_arg); }
    }
    tags := get_aa_metadata(the_store);
    for stores tags = aa_merge(tags, get_aa_metadata(it));
    tags = aa_extend_to(tags, ifx has_bytes then bytes_written else -1);
    new_call: Value_Id;
    if splat != NONE {
        new_call = irb_memset(*b, base_ptr, splat, memset_arg, store_align, false);
        lir_set_aa_metadata(new_call, tags);
    } else if lir_opts.force_memset_pattern_intrinsic || is_lib_func_emittable(c.tli, .memset_pattern16) {
        f := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_MEMSET_PATTERN, .[dest_ptr_ty, vtype(pattern), idx_ty]);
        new_call = irb_call(*b, f, .[base_ptr, pattern, memset_arg, const_false()]);
        if store_align add_param_align(new_call, 0, store_align);
        set_aa_metadata(new_call, tags);
    } else return changed;
    set_metadata(new_call, 0, get_metadata(the_store, 0));
    if c.mssau {
        a := mssau_create_memory_access_in_bb(c.mssau, new_call, -1, inst_block(new_call), .BEFORE_TERMINATOR);
        mssau_insert_def(c.mssau, a, true);
    }
    for stores {
        if c.mssau mssau_remove_memory_access_inst(c.mssau, it, true);
        lir_delete_dead_instruction(it);
    }
    if c.mssau && mssa_opts.verify mssa_verify(c.mssau.mssa);
    result_used = true;
    return true;
}

// processLoopStoreOfLoopLoad(StoreInst *SI, BECount)
lir_process_loop_store_of_loop_load_si :: (c: *Lir, si: Value_Id, be_count: Scev_Id) -> bool {
    store_ptr := op(si, 1);
    store_ev := sc_get_scev(store_ptr);
    store_size := dl_type_store_size(vtype(op(si, 0)));
    ld := op(si, 0);
    load_ptr := op(ld, 0);
    load_ev := sc_get_scev(load_ptr);
    size_scev := sc_get_constant(ap_from_u64(dl_index_bits(vtype(store_ptr)), store_size));   // getConstant(ptr type, ...)
    return lir_process_loop_store_of_loop_load(c, store_ptr, load_ptr, size_scev, inst(si).align, inst(ld).align, si, ld, store_ev, load_ev, be_count);
}

// MemmoveVerifier
Lir_Memmove_Verifier :: struct {
    load_off: s64;
    store_off: s64;
    bp1: Value_Id;
    bp2: Value_Id;
    is_same_object: bool;
}
lir_memmove_verifier :: (load_base: Value_Id, store_base: Value_Id) -> Lir_Memmove_Verifier {
    v: Lir_Memmove_Verifier;
    v.bp1, v.load_off = get_pointer_base_with_constant_offset(strip_pointer_casts(load_base));
    v.bp2, v.store_off = get_pointer_base_with_constant_offset(strip_pointer_casts(store_base));
    v.is_same_object = v.bp1 == v.bp2;
    return v;
}
lir_load_and_store_may_form_memmove :: (v: *Lir_Memmove_Verifier, store_size: s64, is_neg: bool, the_load: Value_Id, is_memcpy: bool) -> bool {
    if is_memcpy {
        if (!is_neg && v.load_off <= v.store_off) || (is_neg && v.load_off >= v.store_off) return false;
    } else {
        load_size := cast(s64) (dl_type_size_bits(vtype(the_load)) / 8);
        if v.bp1 != v.bp2 || load_size != store_size return false;
        if (!is_neg && v.load_off < v.store_off + store_size) || (is_neg && v.load_off + load_size > v.store_off) return false;
    }
    return true;
}

// processLoopStoreOfLoopLoad
lir_process_loop_store_of_loop_load :: (c: *Lir, dest_ptr: Value_Id, source_ptr: Value_Id, size_scev: Scev_Id, store_align: u64,
                                        load_align: u64, the_store: Value_Id, the_load: Value_Id, store_ev: Scev_Id,
                                        load_ev: Scev_Id, be_count: Scev_Id) -> bool {
    if call_iid(the_store) == IID_MEMCPY_INLINE return false;
    preheader := li_loop_preheader(c.li, c.l);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    x: Scev_Expander;
    sx_init(*x, "loop-idiom");
    result_used := false;
    defer if !result_used sx_cleanup(*x);
    changed := false;
    str_start := sc_start(store_ev);
    str_as := ptr_addrspace(vtype(dest_ptr));
    idx_ty := type_int(dl_index_size_bits(str_as));
    stride := lir_store_stride(store_ev);
    store_size := cast(s64) ap_zext_value(sc_ap(size_scev));
    is_neg := ap_eq(ap_from_u64(stride.bits, cast(u64) store_size), ap_neg(stride));
    if is_neg str_start = lir_start_for_neg_stride(str_start, be_count, idx_ty, size_scev);
    store_base := sx_expand_code_for_at(*x, str_start, type_ptr(str_as), block_terminator(preheader));
    changed = true;
    ignored: [..] Value_Id; ignored.allocator = temp;
    array_add(*ignored, the_store);
    is_memcpy := call_iid(the_store) == IID_MEMCPY || call_iid(the_store) == IID_MEMCPY_INLINE;
    loop_access_store := lir_may_loop_access_location(c, store_base, MR_MODREF, be_count, size_scev, ignored);
    if loop_access_store {
        if !has_one_use(the_load) return changed;
        array_add(*ignored, the_load);
        if lir_may_loop_access_location(c, store_base, MR_MODREF, be_count, size_scev, ignored) return changed;
        ignored.count -= 1;   // erase TheLoad
    }
    ld_start := sc_start(load_ev);
    ld_as := ptr_addrspace(vtype(source_ptr));
    if is_neg ld_start = lir_start_for_neg_stride(ld_start, be_count, idx_ty, size_scev);
    load_base := sx_expand_code_for_at(*x, ld_start, type_ptr(ld_as), block_terminator(preheader));
    verifier := lir_memmove_verifier(load_base, store_base);
    if is_memcpy && !verifier.is_same_object {
        for ignored if it == the_store { array_ordered_remove_by_index(*ignored, it_index); break; }
    }
    if lir_may_loop_access_location(c, load_base, MR_MOD, be_count, size_scev, ignored) return changed;
    is_atomic := inst_is_atomic_access(the_store) || inst_is_atomic_access(the_load);
    use_memmove := ifx is_memcpy then verifier.is_same_object else loop_access_store;
    if is_atomic {
        if use_memmove return changed;
        if store_align < cast(u64) store_size || load_align < cast(u64) store_size return changed;
        max_elt: s64 = ifx c.tti.kind == .X86 then 16 else 0;   // getAtomicMemIntrinsicMaxElementSize: X86 16, NoTTI 0
        if store_size > max_elt return changed;
    }
    if use_memmove && !lir_load_and_store_may_form_memmove(*verifier, store_size, is_neg, the_load, is_memcpy) return changed;
    if lir_avoid_for_multi_block_loop(c) return changed;
    nbs := lir_num_bytes(be_count, idx_ty, size_scev, c.l);
    num_bytes := sx_expand_code_for_at(*x, nbs, idx_ty, block_terminator(preheader));
    tags := aa_merge(get_aa_metadata(the_load), get_aa_metadata(the_store));
    tags = aa_extend_to(tags, ifx vkind(num_bytes) == .C_INT then cast(s64) const_int_zext(num_bytes) else -1);
    new_call: Value_Id;
    if is_atomic {
        // CreateElementUnorderedAtomicMemCpy
        f := get_or_insert_intrinsic_declaration(IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC, .[vtype(store_base), vtype(load_base), vtype(num_bytes)]);
        new_call = irb_call(*b, f, .[store_base, load_base, num_bytes, const_int(type_int(32), cast(u64) store_size)]);
        add_param_align(new_call, 0, store_align);
        add_param_align(new_call, 1, load_align);
    } else if use_memmove {
        new_call = irb_intrinsic(*b, "llvm.memmove", .[vtype(store_base), vtype(load_base), vtype(num_bytes)], .[store_base, load_base, num_bytes, const_false()]);
        if store_align add_param_align(new_call, 0, store_align);
        if load_align add_param_align(new_call, 1, load_align);
    } else {
        new_call = irb_memcpy(*b, store_base, store_align, load_base, load_align, num_bytes, false);
    }
    lir_set_aa_metadata(new_call, tags);
    set_metadata(new_call, 0, get_metadata(the_store, 0));
    if c.mssau {
        a := mssau_create_memory_access_in_bb(c.mssau, new_call, -1, inst_block(new_call), .BEFORE_TERMINATOR);
        mssau_insert_def(c.mssau, a, true);
    }
    if c.mssau mssau_remove_memory_access_inst(c.mssau, the_store, true);
    lir_delete_dead_instruction(the_store);
    if c.mssau && mssa_opts.verify mssa_verify(c.mssau.mssa);
    result_used = true;
    return true;
}
inst_is_atomic_access :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD || o == .STORE return inst(i).ord1 != 0;
    return false;
}

// avoidLIRForMultiBlockLoop
lir_avoid_for_multi_block_loop :: (c: *Lir, is_memset := false, is_loop_memset := false) -> bool {
    if c.apply_code_size_heuristics && li_blocks(c.li, c.l).count > 1 {
        if li_parent(c.li, c.l) == NONE && (!is_memset || !is_loop_memset) return true;
    }
    return false;
}

// ---------------------------------------------------------------- runOnLoop

// LoopIdiomRecognizePass::run
loop_idiom_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    if lir_opts.disable_all return PRESERVE_ALL;
    se = lar.se;
    c: Lir;
    c.l = l; c.fn = lar.fn; c.dt = lar.dt; c.li = lar.li;
    c.aar = aa_results_for(lar.fn);
    c.tli = tli_for(lar.fn);
    c.tti = tti_get(lar.fn);
    c.refs_memset.keys.allocator = temp; c.refs_memset.lists.allocator = temp;
    c.refs_memset_pattern.keys.allocator = temp; c.refs_memset_pattern.lists.allocator = temp;
    c.refs_memcpy.allocator = temp;
    mssau_storage: Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; c.mssau = *mssau_storage; }
    if !lir_run_on_loop(*c) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}

lir_run_on_loop :: (c: *Lir) -> bool {
    if li_loop_preheader(c.li, c.l) == NONE return false;
    name := vname(c.fn);
    if name == "memset" || name == "memcpy" || name == "strlen" || name == "wcslen" return false;
    c.apply_code_size_heuristics = fn_has_opt_size(c.fn) && lir_opts.use_code_size_heurs;
    c.has_memset = tli_func_has(c.tli, .memset);
    c.has_memset_pattern = tli_func_has(c.tli, .memset_pattern16);
    c.has_memcpy = tli_func_has(c.tli, .memcpy);
    if c.has_memset || c.has_memset_pattern || lir_opts.force_memset_pattern_intrinsic || c.has_memcpy || !lir_opts.disable_hash_recognize
        if sc_has_loop_invariant_backedge_taken_count(c.l) return lir_run_on_countable_loop(c);
    return lir_run_on_noncountable_loop(c);
}

// runOnCountableLoop
lir_run_on_countable_loop :: (c: *Lir) -> bool {
    be_count := sc_get_backedge_taken_count(c.l);
    if sc_is_zero(be_count) return false;
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(c.li, c.l, *exits);
    // SimpleLoopSafetyInfo::computeLoopSafetyInfo + anyBlockMayThrow
    for b: li_blocks(c.li, c.l) if !is_guaranteed_to_transfer_execution_block(b) return false;
    made := false;
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(c.li, c.l) array_add(*blocks, it);
    for bb: blocks {
        if li_loop_for(c.li, bb) != c.l continue;
        made |= lir_run_on_loop_block(c, bb, be_count, exits);
    }
    if !lir_opts.disable_hash_recognize && !c.apply_code_size_heuristics {
        ok, info := hash_recognize_crc(c.li, c.l);
        if ok lir_optimize_crc_loop(c, *info);   // the result is ignored, as in LLVM
    }
    return made;
}

// optimizeCRCLoop
lir_optimize_crc_loop :: (c: *Lir, info: *Hr_Poly) -> bool {
    tt := triple_parse(ir.triple);
    if tt.arch == .hexagon return false;
    crc_ty := vtype(info.lhs);
    crc_bw := type_int_width(crc_ty);
    table := hr_gen_sarwate_table(info.rhs, info.is_big_endian);
    elems: [256] Value_Id;
    for k: 0..255 elems[k] = const_int_ap(crc_ty, table[k]);
    arr_ty := type_array(256, crc_ty);
    const_array := const_aggregate(.C_ARRAY, arr_ty, elems);
    // new GlobalVariable(M, Ty, /*isConstant=*/true, PrivateLinkage, Init, ".crctable")
    gv := new_global(.GLOBAL_VAR, arr_ty, 0, 1);
    array_add(*ir.m_globals, gv);
    set_name(gv, ".crctable");
    set_op(gv, 0, const_array);
    glob(gv).has_init = true;
    glob(gv).is_const = true;
    glob(gv).linkage = .PRIVATE;
    glob(gv).dso_local = true;   // maybeSetDsoLocal
    li := c.li; l := c.l;
    iv := li_canonical_induction_variable(li, l);
    cleanup: [..] Value_Id; cleanup.allocator = temp;
    for pn: block_insts(li_header(li, l)) {
        if inst_op(pn) != .PHI break;
        if pn == iv continue;
        rauw_with_metadata(pn, const_poison(vtype(pn)));
        array_add(*cleanup, pn);
    }
    {
        new_btc := (info.trip_count / 8) - 1;
        latch := li_loop_latch(li, l);
        br := block_terminator(latch);
        exit_pred: u8 = ifx get_successor(br, 0) == latch then cast(u8) ICMP_NE else ICMP_EQ;
        exit_cond := li_latch_cmp_inst(li, l);
        limit := const_int(vtype(iv), new_btc);
        b: Irb;
        irb_set_before(*b, exit_cond);
        nc := irb_icmp(*b, exit_pred, iv, limit, "exit.cond");
        rauw_with_metadata(exit_cond, nc);
        lir_delete_dead_instruction(exit_cond);
    }
    {
        header := li_header(li, l);
        b: Irb;
        irb_set_at(*b, header, block_first_non_phi(header), true);   // getFirstNonPHIIt (head bit)
        lo_byte :: (b: *Irb, v: Value_Id, name: string) -> Value_Id { return irb_zext_or_trunc(b, v, type_int(8), name); }
        crc_phi := irb_phi(*b, crc_ty, 2, "crc");
        phi_add_incoming(crc_phi, info.lhs, li_loop_preheader(li, l));
        crc := crc_phi;
        indexer := crc;
        if info.lhs_aux != NONE {
            data := info.lhs_aux;
            data_ty := vtype(data);
            iv_bits := irb_zext_or_trunc(*b, irb_binop(*b, .SHL, iv, const_int(vtype(iv), 3), "iv.bits"), data_ty, "iv.indexer");
            data_indexer := ifx info.is_big_endian then irb_binop(*b, .SHL, data, iv_bits, "data.indexer") else irb_binop(*b, .LSHR, data, iv_bits, "data.indexer");
            indexer = irb_binop(*b, .XOR, data_indexer, irb_zext_or_trunc(*b, indexer, data_ty, "crc.indexer.cast"), "crc.data.indexer");
        }
        if info.is_big_endian {
            name := "indexer.hi";
            v := indexer;
            if crc_bw > 8 v = irb_binop(*b, .LSHR, indexer, const_int(vtype(indexer), cast(u64) (crc_bw - 8)), name);
            indexer = lo_byte(*b, v, tprint("%.lo.byte", name));
        } else indexer = lo_byte(*b, indexer, "indexer.lo");
        idx_ty := dl_index_type(vtype(gv));
        indexer = irb_cast(*b, .ZEXT, indexer, idx_ty, "indexer.ext");
        gep := irb_gep(*b, crc_ty, gv, .[indexer], "tbl.ptradd", F_INBOUNDS);
        ld := irb_load(*b, crc_ty, gep, dl_abi_align(crc_ty), false, "tbl.ld");
        crc_next := ld;
        if crc_bw > 8 {
            shift := ifx info.is_big_endian then irb_binop(*b, .SHL, crc, const_int(crc_ty, 8), "crc.be.shift") else irb_binop(*b, .LSHR, crc, const_int(crc_ty, 8), "crc.le.shift");
            crc_next = irb_binop(*b, .XOR, shift, ld, "crc.next");
        }
        phi_add_incoming(crc_phi, crc_next, li_loop_latch(li, l));
        replace_uses_outside_block(info.computed_value, crc_next, li_loop_latch(li, l));
    }
    for cleanup ivs_recursively_delete_dead_phi_node(it, null);
    sc_forget_loop(l);
    return true;
}

// runOnNoncountableLoop
lir_run_on_noncountable_loop :: (c: *Lir) -> bool {
    return lir_recognize_popcount(c) || lir_recognize_and_insert_ffs(c) || lir_recognize_shift_until_bit_test(c) ||
           lir_recognize_shift_until_zero(c) || lir_recognize_shift_until_less_than(c) || lir_recognize_and_insert_strlen(c);
}

// matchCondition(BI, LoopEntry, JmpOnZero)
lir_match_condition :: (bi: Value_Id, loop_entry: Value_Id, jmp_on_zero := false) -> Value_Id {
    cond := op(bi, 0);
    if !is_inst(cond) || inst_op(cond) != .ICMP return NONE;
    z := op(cond, 1);
    if vkind(z) != .C_INT || is_vector_type(vtype(z)) || !ap_is_zero(const_ap(z)) return NONE;
    t := get_successor(bi, 0); f := get_successor(bi, 1);
    if jmp_on_zero { x := t; t = f; f = x; }
    pred := inst_pred(cond);
    if (pred == ICMP_NE && t == loop_entry) || (pred == ICMP_EQ && f == loop_entry) return op(cond, 0);
    return NONE;
}
is_cond_br :: (t: Value_Id) -> bool { return t != NONE && inst_op(t) == .CONDBR; }

// StrlenVerifier
Lir_Strlen :: struct {
    op_width: u32;
    load_base_ev: Scev_Id;
    operand_type: Type_Id;
}
lir_is_valid_strlen_idiom :: (c: *Lir, v: *Lir_Strlen) -> bool {
    li := c.li; l := c.l;
    if li_num_back_edges(li, l) != 1 || li_blocks(li, l).count != 1 || li_unique_exit_block(li, l) == NONE return false;
    ph := li_loop_preheader(li, l);
    if ph == NONE || !(inst_op(block_terminator(ph)) == .BR || inst_op(block_terminator(ph)) == .CONDBR) return false;
    body := li_blocks(li, l)[0];
    if block_num_insts(body) >= 15 return false;
    term := block_terminator(body);
    if !is_cond_br(term) return false;
    cond := lir_match_condition(term, body);
    if cond == NONE return false;
    if !is_inst(cond) || inst_op(cond) != .LOAD || ptr_addrspace(vtype(op(cond, 0))) != 0 return false;
    v.operand_type = vtype(cond);
    if !is_int_type(v.operand_type) return false;
    lev := sc_get_scev(op(cond, 0));
    if !sc_is_addrec(lev) || !sc_is_affine(lev) || !sc_is_const(sc_op(lev, 1)) return false;
    v.load_base_ev = sc_op(lev, 0);
    step_size := cast,trunc(u32) ap_zext_value(sc_ap(sc_op(lev, 1)));   // unsigned StepSize = getZExtValue()
    v.op_width = type_int_width(v.operand_type);
    wchar := tli_wchar_size();
    if v.op_width != cast,no_check(u32) (step_size * 8) return false;
    if v.op_width != 8 && v.op_width != 16 && v.op_width != 32 return false;
    if v.op_width >= 16 && v.op_width != wchar * 8 return false;
    for i: block_insts(body) if may_have_side_effects(i) return false;
    exit := li_exit_block(li, l);
    if exit == NONE return false;
    for pn: block_insts(exit) {
        if inst_op(pn) != .PHI break;
        if !sc_is_scevable(vtype(pn)) return false;
        ev := sc_get_scev(pn);
        if !sc_is_addrec(ev) || !sc_is_affine(ev) return false;
        if !sc_is_const(sc_step_recurrence(ev)) return false;
    }
    return true;
}

// recognizeAndInsertStrLen
lir_recognize_and_insert_strlen :: (c: *Lir) -> bool {
    if lir_opts.disable_all return false;
    v: Lir_Strlen;
    if !lir_is_valid_strlen_idiom(c, *v) return false;
    li := c.li; l := c.l;
    ph := li_loop_preheader(li, l);
    body := li_blocks(li, l)[0];
    exit := li_exit_block(li, l);
    term := block_terminator(body);
    if v.op_width == 8 {
        if lir_opts.disable_strlen return false;
        if !is_lib_func_emittable(c.tli, .strlen) return false;
    } else {
        if lir_opts.disable_wcslen return false;
        if !is_lib_func_emittable(c.tli, .wcslen) return false;
    }
    b: Irb;
    irb_set_before(*b, block_terminator(ph));
    b.dbg = li_start_loc(li, l);
    x: Scev_Expander;
    sx_init(*x, "strlen_idiom");
    base := sx_expand_code_for_at(*x, v.load_base_ev, sc_type(v.load_base_ev), b.pt);
    lf: Lib_Func = ifx v.op_width == 8 then Lib_Func.strlen else .wcslen;
    strlen_fn := lir_emit_lib_call(*b, c.tli, lf, tli_size_t_type(), .[ir.t_ptr], .[base]);
    strlen_ev := sc_get_scev(strlen_fn);
    cleanup: [..] Value_Id; cleanup.allocator = temp;
    for pn: block_insts(exit) {
        if inst_op(pn) != .PHI break;
        ev := sc_get_scev(pn);
        step := sc_step_recurrence(ev);
        base_ev := sc_start(ev);
        new_ev := sc_get_add2(base_ev, sc_get_mul2(step, sc_get_truncate_or_sign_extend(strlen_ev, sc_type(base_ev))));
        mat := sx_expand_code_for_at(*x, new_ev, sc_type(new_ev), b.pt);
        sx_clear(*x);
        rauw_with_metadata(pn, mat);
        array_add(*cleanup, pn);
    }
    for cleanup ivs_recursively_delete_dead_phi_node(it, null);
    new_cond := ifx get_successor(term, 0) == body then const_false() else const_int(ir.t_i1, 1);
    set_op(term, 0, new_cond);
    sc_forget_loop(l);
    return true;
}

// emitLibCall with an IRBuilder<> (BuildLibCalls.cpp)
lir_emit_lib_call :: (b: *Irb, t: *Tli, lf: Lib_Func, ret: Type_Id, params: [] Type_Id, ops: [] Value_Id) -> Value_Id {
    if !is_lib_func_emittable(t, lf) return NONE;
    name := tli_func_name(t, lf);
    ft := type_func(ret, params, false);
    f := get_or_insert_lib_func(t, lf, ft);
    infer_non_mandatory_lib_func_attrs_name(name, t);
    ci := irb_call(b, f, ops, name);
    inst(ci).cc = glob(f).cc;
    return ci;
}

// matchShiftULTCondition
lir_match_shift_ult_condition :: (bi: Value_Id, loop_entry: Value_Id) -> (Value_Id, APInt) {
    cond := op(bi, 0);
    if !is_inst(cond) || inst_op(cond) != .ICMP return NONE, .{};
    k := op(cond, 1);
    if vkind(k) != .C_INT || is_vector_type(vtype(k)) return NONE, .{};
    if inst_pred(cond) == ICMP_ULT && get_successor(bi, 1) == loop_entry return op(cond, 0), const_ap(k);
    return NONE, .{};
}

// getRecurrenceVar
lir_recurrence_var :: (var_x: Value_Id, def_x: Value_Id, loop_entry: Value_Id) -> Value_Id {
    if is_inst(var_x) && inst_op(var_x) == .PHI && inst_block(var_x) == loop_entry && (op(var_x, 0) == def_x || op(var_x, 1) == def_x) return var_x;
    return NONE;
}

is_c_int_one :: (v: Value_Id) -> bool { return vkind(v) == .C_INT && !is_vector_type(vtype(v)) && ap_is_one(const_ap(v)); }
is_c_int_minus_one :: (v: Value_Id) -> bool { return vkind(v) == .C_INT && !is_vector_type(vtype(v)) && ap_is_all_ones(const_ap(v)); }

// the "cnt.next = cnt + 1 (or -1)" search of the FFS detectors
lir_find_counter :: (loop_entry: Value_Id, allow_minus_one: bool, need_live_out := false) -> (Value_Id, Value_Id) {
    i := block_first_non_phi(loop_entry);
    while i != NONE {
        defer i = inst_next(i);
        if inst_op(i) != .ADD continue;
        inc := op(i, 1);
        if !(is_c_int_one(inc) || (allow_minus_one && is_c_int_minus_one(inc))) continue;
        phi := lir_recurrence_var(op(i, 0), i, loop_entry);
        if phi == NONE continue;
        if need_live_out {
            live := false;
            u := ir.v_first_use[i];
            while u != NONE { if inst_block(ir.u_user[u]) != loop_entry { live = true; break; } u = ir.u_next[u]; }
            if !live continue;
        }
        return i, phi;
    }
    return NONE, NONE;
}

// detectShiftUntilLessThanIdiom
lir_detect_shift_until_less_than :: (c: *Lir) -> (bool, iid: Intrinsic_Id, init_x: Value_Id, cnt_inst: Value_Id, cnt_phi: Value_Id, def_x: Value_Id, threshold: APInt) {
    loop_entry := li_blocks(c.li, c.l)[0];
    bi := block_terminator(loop_entry);
    if !is_cond_br(bi) return false, 0, NONE, NONE, NONE, NONE, .{};
    t, threshold := lir_match_shift_ult_condition(bi, loop_entry);
    if t == NONE return false, 0, NONE, NONE, NONE, NONE, .{};
    def_x := t;
    if !is_inst(def_x) || inst_op(def_x) != .PHI return false, 0, NONE, NONE, NONE, NONE, threshold;
    var_phi := def_x;
    idx := phi_block_index(var_phi, loop_entry);
    if idx < 0 return false, 0, NONE, NONE, NONE, NONE, threshold;
    def_x = op(var_phi, cast(u32) idx);
    if !is_inst(def_x) || nops(def_x) == 0 || op(def_x, 0) != var_phi return false, 0, NONE, NONE, NONE, NONE, threshold;
    if inst_op(def_x) != .LSHR return false, 0, NONE, NONE, NONE, NONE, threshold;
    if !is_c_int_one(op(def_x, 1)) return false, 0, NONE, NONE, NONE, NONE, threshold;
    init_x := phi_incoming_for_block(var_phi, li_loop_preheader(c.li, c.l));
    cnt_inst, cnt_phi := lir_find_counter(loop_entry, true);
    if cnt_inst == NONE return false, 0, NONE, NONE, NONE, NONE, threshold;
    return true, IID_CTLZ, init_x, cnt_inst, cnt_phi, def_x, threshold;
}

// detectPopcountIdiom
lir_detect_popcount :: (c: *Lir, pre_cond_bb: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    loop_entry := li_blocks(c.li, c.l)[0];
    term := block_terminator(loop_entry);
    if !is_cond_br(term) return false, NONE, NONE, NONE;
    def_x2 := lir_match_condition(term, loop_entry);
    if def_x2 == NONE || !is_inst(def_x2) || inst_op(def_x2) != .AND return false, NONE, NONE, NONE;
    var_x1: Value_Id;
    sub_one := op(def_x2, 0);
    if is_binary_operator(sub_one) var_x1 = op(def_x2, 1);
    else { var_x1 = op(def_x2, 0); sub_one = op(def_x2, 1); }
    if !is_binary_operator(sub_one) || op(sub_one, 0) != var_x1 return false, NONE, NONE, NONE;
    dec := op(sub_one, 1);
    if vkind(dec) != .C_INT || is_vector_type(vtype(dec)) return false, NONE, NONE, NONE;
    if !((inst_op(sub_one) == .SUB && is_c_int_one(dec)) || (inst_op(sub_one) == .ADD && is_c_int_minus_one(dec))) return false, NONE, NONE, NONE;
    phi_x := lir_recurrence_var(var_x1, def_x2, loop_entry);
    if phi_x == NONE return false, NONE, NONE, NONE;
    count_inst, count_phi := lir_find_counter(loop_entry, false, true);
    if count_inst == NONE return false, NONE, NONE, NONE;
    pre_br := block_terminator(pre_cond_bb);
    if !is_cond_br(pre_br) return false, NONE, NONE, NONE;
    t := lir_match_condition(pre_br, li_loop_preheader(c.li, c.l));
    if t != op(phi_x, 0) && t != op(phi_x, 1) return false, NONE, NONE, NONE;
    return true, count_inst, count_phi, t;
}

// detectShiftUntilZeroIdiom (the FFS form)
lir_detect_ffs :: (c: *Lir) -> (bool, iid: Intrinsic_Id, init_x: Value_Id, cnt_inst: Value_Id, cnt_phi: Value_Id, def_x: Value_Id) {
    loop_entry := li_blocks(c.li, c.l)[0];
    term := block_terminator(loop_entry);
    if !is_cond_br(term) return false, 0, NONE, NONE, NONE, NONE;
    def_x := lir_match_condition(term, loop_entry);
    if def_x == NONE || !is_inst(def_x) || !is_shift_op(inst_op(def_x)) return false, 0, NONE, NONE, NONE, NONE;
    iid := ifx inst_op(def_x) == .SHL then IID_CTTZ else IID_CTLZ;
    if !is_c_int_one(op(def_x, 1)) return false, 0, NONE, NONE, NONE, NONE;
    var_x := op(def_x, 0);
    phi_x := lir_recurrence_var(var_x, def_x, loop_entry);
    if phi_x == NONE return false, 0, NONE, NONE, NONE, NONE;
    init_x := phi_incoming_for_block(phi_x, li_loop_preheader(c.li, c.l));
    if inst_op(def_x) == .ASHR {
        q: Simplify_Query; q.have_tli = false;   // isKnownNonNegative(InitX, DL)
        if !is_known_non_negative(init_x, q) return false, 0, NONE, NONE, NONE, NONE;
    }
    cnt_inst, cnt_phi := lir_find_counter(loop_entry, true);
    if cnt_inst == NONE return false, 0, NONE, NONE, NONE, NONE;
    return true, iid, init_x, cnt_inst, cnt_phi, def_x;
}

// isProfitableToInsertFFS
lir_is_profitable_to_insert_ffs :: (c: *Lir, iid: Intrinsic_Id, init_x: Value_Id, zero_check: bool, canonical_size: s64) -> bool {
    args := Value_Id.[init_x, const_int(ir.t_i1, ifx zero_check then cast(u64) 1 else 0)];
    header_size := block_num_insts(li_header(c.li, c.l));
    ica := ica_new(iid, vtype(init_x), args);
    cost := tti_intrinsic_cost(c.tti, *ica, TCK_SIZE_AND_LATENCY);
    if header_size != canonical_size && cost > TCC_BASIC return false;
    return true;
}
// IntrinsicCostAttributes(Id, RTy, Args)
ica_new :: (id: Intrinsic_Id, ret: Type_Id, args: [] Value_Id) -> Ica {
    a: Ica;
    a.id = id; a.ret = ret;
    a.args = array_copy(args,, allocator = temp);
    tys := NewArray(args.count, Type_Id,, allocator = temp);
    for args tys[it_index] = vtype(it);
    a.tys = tys;
    return a;
}

user_outside_loop :: (li: *Loop_Info, l: Loop_Id, v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE { if !li_contains(li, l, inst_block(ir.u_user[u])) return true; u = ir.u_next[u]; }
    return false;
}

// insertFFSIfProfitable
lir_insert_ffs_if_profitable :: (c: *Lir, iid: Intrinsic_Id, init_x: Value_Id, def_x: Value_Id, cnt_phi: Value_Id, cnt_inst: Value_Id) -> bool {
    phi_out := user_outside_loop(c.li, c.l, cnt_phi);
    inst_out := user_outside_loop(c.li, c.l, cnt_inst);
    if inst_out && phi_out return false;
    zero_check := false;
    ph := li_loop_preheader(c.li, c.l);
    if !phi_out {
        pre := block_single_predecessor(ph);
        if pre == NONE return false;
        pbi := block_terminator(pre);
        if !is_cond_br(pbi) return false;
        if lir_match_condition(pbi, ph) != init_x return false;
        zero_check = true;
    }
    if !lir_is_profitable_to_insert_ffs(c, iid, init_x, zero_check, 6) return false;
    lir_transform_loop_to_countable(c, iid, ph, cnt_inst, cnt_phi, init_x, def_x, get_metadata(def_x, 0), zero_check, phi_out);
    return true;
}

// recognizeAndInsertFFS
lir_recognize_and_insert_ffs :: (c: *Lir) -> bool {
    if li_num_back_edges(c.li, c.l) != 1 || li_blocks(c.li, c.l).count != 1 return false;
    ok, iid, init_x, cnt_inst, cnt_phi, def_x := lir_detect_ffs(c);
    if !ok return false;
    return lir_insert_ffs_if_profitable(c, iid, init_x, def_x, cnt_phi, cnt_inst);
}

// recognizeShiftUntilLessThan
lir_recognize_shift_until_less_than :: (c: *Lir) -> bool {
    if li_num_back_edges(c.li, c.l) != 1 || li_blocks(c.li, c.l).count != 1 return false;
    ok, iid, init_x, cnt_inst, cnt_phi, def_x, threshold := lir_detect_shift_until_less_than(c);
    if !ok return false;
    if ap_fits_u64(threshold) && ap_zext_value(threshold) == 2 return lir_insert_ffs_if_profitable(c, iid, init_x, def_x, cnt_phi, cnt_inst);
    if !(ap_fits_u64(threshold) && ap_zext_value(threshold) == 4) return false;
    if user_outside_loop(c.li, c.l, cnt_phi) return false;
    ph := li_loop_preheader(c.li, c.l);
    pre := block_single_predecessor(ph);
    if pre == NONE return false;
    pbi := block_terminator(pre);
    if !is_cond_br(pbi) return false;
    v, pre_threshold := lir_match_shift_ult_condition(pbi, ph);
    if v != init_x || !(ap_fits_u64(pre_threshold) && ap_zext_value(pre_threshold) == 2) return false;
    if !lir_is_profitable_to_insert_ffs(c, iid, init_x, true, 6) return false;
    lir_transform_loop_to_countable(c, iid, ph, cnt_inst, cnt_phi, init_x, def_x, get_metadata(def_x, 0), true, false, true);
    return true;
}

// recognizePopcount
lir_recognize_popcount :: (c: *Lir) -> bool {
    if !(c.tti.kind == .X86 && st_hasPOPCNT(*c.tti.xl)) return false;   // getPopcntSupport(32) == PSK_FastHardware
    if li_num_back_edges(c.li, c.l) != 1 || li_blocks(c.li, c.l).count != 1 return false;
    body := li_blocks(c.li, c.l)[0];
    if block_num_insts(body) >= 20 return false;
    ph := li_loop_preheader(c.li, c.l);
    if ph == NONE || block_first(ph) != block_terminator(ph) return false;
    if inst_op(block_terminator(ph)) != .BR return false;
    pre := block_single_predecessor(ph);
    if pre == NONE return false;
    if !is_cond_br(block_terminator(pre)) return false;
    ok, cnt_inst, cnt_phi, val := lir_detect_popcount(c, pre);
    if !ok return false;
    lir_transform_loop_to_popcount(c, pre, cnt_inst, cnt_phi, val);
    return true;
}

lir_intrinsic :: (b: *Irb, iid: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    f := get_or_insert_intrinsic_declaration(iid, otys);
    return irb_call(b, f, args, name);
}

// transformLoopToCountable
lir_transform_loop_to_countable :: (c: *Lir, iid: Intrinsic_Id, preheader: Value_Id, cnt_inst: Value_Id, cnt_phi: Value_Id,
                                    init_x: Value_Id, def_x: Value_Id, dl_: Md_Id, zero_check: bool,
                                    is_cnt_phi_used_outside: bool, insert_sub := false) {
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    b.dbg = dl_;
    init_x_next: Value_Id;
    if is_cnt_phi_used_outside {
        o := inst_op(def_x);
        if o == .ASHR || o == .LSHR || o == .SHL init_x_next = irb_binop(*b, o, init_x, const_int(vtype(init_x), 1));
        else fatal("Unexpected opcode!");
    } else init_x_next = init_x;
    b.dbg = dl_;
    count := lir_intrinsic(*b, iid, .[vtype(init_x_next)], .[init_x_next, const_int(ir.t_i1, ifx zero_check then cast(u64) 1 else 0)]);
    count_ty := vtype(count);
    count = irb_binop(*b, .SUB, const_int(count_ty, type_int_width(count_ty)), count);
    if insert_sub count = irb_binop(*b, .SUB, count, const_int(count_ty, 1));
    new_count := count;
    if is_cnt_phi_used_outside count = irb_binop(*b, .ADD, count, const_int(count_ty, 1));
    new_count = irb_zext_or_trunc(*b, new_count, vtype(cnt_inst));
    cnt_init := phi_incoming_for_block(cnt_phi, preheader);
    if is_c_int_one(op(cnt_inst, 1)) {
        if !(vkind(cnt_init) == .C_INT && ap_is_zero(const_ap(cnt_init))) new_count = irb_binop(*b, .ADD, new_count, cnt_init);
    } else new_count = irb_binop(*b, .SUB, cnt_init, new_count);
    body := li_blocks(c.li, c.l)[0];
    lb_br := block_terminator(body);
    lb_cond := op(lb_br, 0);
    tc_phi := create_phi(count_ty, 2);
    insert_at_position(tc_phi, body, block_first(body), true);   // insertBefore(Body->begin()): head bit
    set_name(tc_phi, "tcphi");
    irb_set_before(*b, lb_cond);
    tc_dec := irb_binop(*b, .SUB, tc_phi, const_int(count_ty, 1), "tcdec", F_NSW);
    phi_add_incoming(tc_phi, count, preheader);
    phi_add_incoming(tc_phi, tc_dec, body);
    pred: u8 = ifx get_successor(lb_br, 0) == body then cast(u8) ICMP_NE else ICMP_EQ;
    inst(lb_cond).pred = pred;   // CmpInst::setPredicate
    set_op(lb_cond, 0, tc_dec);
    set_op(lb_cond, 1, const_int(count_ty, 0));
    if is_cnt_phi_used_outside replace_uses_outside_block(cnt_phi, new_count, body);
    else replace_uses_outside_block(cnt_inst, new_count, body);
    sc_forget_loop(c.l);
}

// transformLoopToPopcount
lir_transform_loop_to_popcount :: (c: *Lir, pre_cond_bb: Value_Id, cnt_inst: Value_Id, cnt_phi: Value_Id, var: Value_Id) {
    pre_head := li_loop_preheader(c.li, c.l);
    pre_br := block_terminator(pre_cond_bb);
    dl_ := get_metadata(cnt_inst, 0);
    b: Irb;
    irb_set_before(*b, pre_br);
    b.dbg = dl_;
    pop_cnt := lir_intrinsic(*b, IID_CTPOP, .[vtype(var)], .[var]);
    pop_cnt_zext := irb_zext_or_trunc(*b, pop_cnt, vtype(cnt_phi));
    new_count := pop_cnt_zext;
    if new_count != pop_cnt set_metadata(new_count, 0, dl_);
    trip_cnt := new_count;
    cnt_init := phi_incoming_for_block(cnt_phi, pre_head);
    if !(vkind(cnt_init) == .C_INT && ap_is_zero(const_ap(cnt_init))) {
        new_count = irb_binop(*b, .ADD, new_count, cnt_init);
        set_metadata(new_count, 0, dl_);
    }
    {
        pre_cond := op(pre_br, 0);
        o0 := pop_cnt_zext; o1 := const_int(vtype(pop_cnt_zext), 0);
        if op(pre_cond, 0) != var { x := o0; o0 = o1; o1 = x; }
        new_pre := irb_icmp(*b, inst_pred(pre_cond), o0, o1);
        set_op(pre_br, 0, new_pre);
        ivs_recursively_delete_trivially_dead(pre_cond, null);
    }
    body := li_blocks(c.li, c.l)[0];
    {
        lb_br := block_terminator(body);
        lb_cond := op(lb_br, 0);
        ty := vtype(trip_cnt);
        tc_phi := create_phi(ty, 2);
        insert_at_position(tc_phi, body, block_first(body), true);
        set_name(tc_phi, "tcphi");
        irb_set_before(*b, lb_cond);
        tc_dec := irb_binop(*b, .SUB, tc_phi, const_int(ty, 1), "tcdec", F_NSW);
        phi_add_incoming(tc_phi, trip_cnt, pre_head);
        phi_add_incoming(tc_phi, tc_dec, body);
        pred: u8 = ifx get_successor(lb_br, 0) == body then cast(u8) ICMP_UGT else ICMP_SLE;
        inst(lb_cond).pred = pred;   // CmpInst::setPredicate
        set_op(lb_cond, 0, tc_dec);
        set_op(lb_cond, 1, const_int(ty, 0));
    }
    replace_uses_outside_block(cnt_inst, new_count, body);
    sc_forget_loop(c.l);
}

// detectShiftUntilBitTestIdiom
lir_detect_shift_until_bit_test :: (c: *Lir) -> (bool, base_x: Value_Id, bit_mask: Value_Id, bit_pos: Value_Id, curr_x: Value_Id, next_x: Value_Id) {
    li := c.li; l := c.l;
    if li_blocks(li, l).count != 1 || li_num_back_edges(li, l) != 1 return false, NONE, NONE, NONE, NONE, NONE;
    header := li_header(li, l);
    preheader := li_loop_preheader(li, l);
    term := block_terminator(header);
    if !is_cond_br(term) return false, NONE, NONE, NONE, NONE, NONE;
    okc, pred, ss, cmp_lhs, cmp_rhs := pm_icmp(op(term, 0));
    if !okc return false, NONE, NONE, NONE, NONE, NONE;
    true_bb := get_successor(term, 0); false_bb := get_successor(term, 1);
    curr_x, bit_mask, bit_pos: Value_Id = NONE, NONE, NONE;
    // MatchVariableBitMask
    matched := false;
    if icmp_is_equality(pred) && pm_zero(cmp_rhs) && is_inst(cmp_lhs) && inst_op(cmp_lhs) == .AND {
        for side: 0..1 {
            cx := op(cmp_lhs, cast(u32) side);
            m := op(cmp_lhs, cast(u32) (1 - side));
            if li_is_loop_invariant(li, l, m) && is_inst(m) && inst_op(m) == .SHL && pm_one(op(m, 0)) {
                curr_x = cx; bit_mask = m; bit_pos = op(m, 1); matched = true; break;
            }
        }
    }
    if !matched {
        okd, res := decompose_bit_test_icmp(cmp_lhs, cmp_rhs, pred, true, false, true);
        if okd && ap_is_power_of_2(res.mask) {
            pred = res.pred;
            curr_x = res.x;
            bit_mask = const_int_ap(vtype(curr_x), res.mask);
            bit_pos = const_int(vtype(curr_x), ap_log2(res.mask));
            matched = true;
        }
    }
    if !matched return false, NONE, NONE, NONE, NONE, NONE;
    if !is_inst(curr_x) || inst_op(curr_x) != .PHI || inst_block(curr_x) != header return false, NONE, NONE, NONE, NONE, NONE;
    base_x := phi_incoming_for_block(curr_x, preheader);
    next_x := phi_incoming_for_block(curr_x, header);
    if !is_inst(next_x) || inst_op(next_x) != .SHL || op(next_x, 0) != curr_x || !pm_one(op(next_x, 1)) return false, NONE, NONE, NONE, NONE, NONE;
    if pred != ICMP_EQ { pred = icmp_inverse(pred); x := true_bb; true_bb = false_bb; false_bb = x; }
    if true_bb != header return false, NONE, NONE, NONE, NONE, NONE;
    return true, base_x, bit_mask, bit_pos, curr_x, next_x;
}

// recognizeShiftUntilBitTest
lir_recognize_shift_until_bit_test :: (c: *Lir) -> bool {
    ok, x, bit_mask, bit_pos, x_curr, x_next := lir_detect_shift_until_bit_test(c);
    if !ok return false;
    li := c.li; l := c.l;
    header := li_header(li, l);
    preheader := li_loop_preheader(li, l);
    succ_bb := li_exit_block(li, l);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    b.dbg = get_metadata(x_curr, 0);
    ty := vtype(x);
    bw := scalar_bits(x);
    ica := ica_new(IID_CTLZ, ty, .[const_poison(ty), const_int(ir.t_i1, 1)]);
    if tti_intrinsic_cost(c.tti, *ica, TCK_SIZE_AND_LATENCY) > TCC_BASIC return false;
    if tti_arith_cost(c.tti, .SHL, ty, TCK_SIZE_AND_LATENCY) > TCC_BASIC return false;
    if !is_guaranteed_not_to_be_undef_or_poison(bit_pos) {
        pos: Value_Id; bb: Value_Id; head: bool;
        if is_inst(bit_pos) {
            okp, it := sx_insertion_point_after_def(bit_pos);
            if !okp return false;
            bb = it.bb; pos = it.pt; head = it.head;
        } else {
            entry := fn_entry(c.fn);
            bb = entry; pos = block_first_non_phi_or_dbg_or_alloca(entry); head = false;
        }
        fr := new_inst(.FREEZE, vtype(bit_pos), 1);
        set_op(fr, 0, bit_pos);
        insert_at_position(fr, bb, pos, head);
        set_name(fr, tprint("%.fr", vname(bit_pos)));
        u := ir.v_first_use[bit_pos];
        while u != NONE {
            nx := ir.u_next[u];
            if ir.u_user[u] != fr use_set(u, fr);
            u = nx;
        }
        bit_pos = fr;
    }
    low_mask := irb_binop(*b, .ADD, bit_mask, const_all_ones_of(ty), tprint("%.lowbitmask", vname(bit_pos)));
    mask := irb_binop(*b, .OR, low_mask, bit_mask, tprint("%.mask", vname(bit_pos)));
    x_masked := irb_binop(*b, .AND, x, mask, tprint("%.masked", vname(x)));
    nlz := lir_intrinsic(*b, IID_CTLZ, .[ty], .[x_masked, const_int(ir.t_i1, 1)], tprint("%.numleadingzeros", vname(x_masked)));
    nab := irb_binop(*b, .SUB, const_int(ty, bw), nlz, tprint("%.numactivebits", vname(x_masked)), F_NUW | lir_fl(bw != 2, F_NSW));
    lop := irb_binop(*b, .ADD, nab, const_all_ones_of(ty), tprint("%.leadingonepos", vname(x_masked)), lir_fl(bw > 2, F_NSW));
    lname := vname(header);
    btc := irb_binop(*b, .SUB, bit_pos, lop, tprint("%.backedgetakencount", lname), F_NUW | F_NSW);
    tc := irb_binop(*b, .ADD, btc, const_int(ty, 1), tprint("%.tripcount", lname), F_NUW | lir_fl(bw != 2, F_NSW));
    new_x := irb_binop(*b, .SHL, x, btc);
    lir_take_name(new_x, x_curr);
    if is_inst(new_x) copy_ir_flags(new_x, x_next);
    new_x_next: Value_Id;
    okbp, bp := pm_apint(bit_pos);
    bp_ne := okbp && !(ap_fits_u64(bp) && ap_zext_value(bp) == cast(u64) (bw - 1));   // m_SpecificInt_ICMP(NE, bw - 1)
    if has_nsw(x_next) || has_nuw(x_next) || bp_ne new_x_next = irb_binop(*b, .SHL, x, tc);
    else new_x_next = irb_binop(*b, .SHL, new_x, const_int(ty, 1));
    lir_take_name(new_x_next, x_next);
    if is_inst(new_x_next) copy_ir_flags(new_x_next, x_next);
    replace_uses_outside_block(x_curr, new_x, header);
    replace_uses_outside_block(x_next, new_x_next, header);
    irb_set_at(*b, header, block_first(header), true);
    iv := irb_phi(*b, ty, 2, tprint("%.iv", lname));
    irb_set_before(*b, block_terminator(header));
    iv_next := irb_binop(*b, .ADD, iv, const_int(ty, 1), tprint("%.next", vname(iv)), F_NUW | lir_fl(bw != 2, F_NSW));
    iv_check := irb_icmp(*b, ICMP_EQ, iv_next, tc, tprint("%.ivcheck", lname));
    old_term := block_terminator(header);
    has_w, w := extract_branch_weights_any(old_term);
    nbi := irb_insert(*b, create_cond_br(iv_check, succ_bb, header));
    if has_w {
        if succ_bb == get_successor(old_term, 1) { t := w[0]; w[0] = w[1]; w[1] = t; }
        set_branch_weights(nbi, w);
    }
    erase_inst(old_term);
    phi_add_incoming(iv, const_int(ty, 0), preheader);
    phi_add_incoming(iv, iv_next, header);
    sc_forget_loop(l);
    return true;
}

// extractBranchWeights(I, SmallVector<uint32_t>&)
extract_branch_weights_any :: (t: Value_Id) -> (bool, [] u32) {
    md, w := branch_weights_of(t);
    if md == NONE return false, .[];
    c := NewArray(w.count, u32,, allocator = temp);
    for w c[it_index] = it;
    return true, c;
}

// detectShiftUntilZeroIdiom (the SCEV form)
lir_detect_shift_until_zero :: (c: *Lir) -> (bool, is_zero: Value_Id, iid: Intrinsic_Id, iv: Value_Id, start: Value_Id, val: Value_Id, extra: Scev_Id, inverted: bool) {
    li := c.li; l := c.l;
    if li_blocks(li, l).count != 1 || li_num_back_edges(li, l) != 1 return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    header := li_header(li, l);
    preheader := li_loop_preheader(li, l);
    term := block_terminator(header);
    if !is_cond_br(term) || !is_inst(op(term, 0)) return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    is_zero := op(term, 0);
    true_bb := get_successor(term, 0); false_bb := get_successor(term, 1);
    okc, pred, ss, shifted, z := pm_icmp(is_zero);
    if !okc || !is_inst(shifted) || !pm_zero(z) || !icmp_is_equality(pred) return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    if !is_shift_op(inst_op(shifted)) return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    val := op(shifted, 0);
    nbits := op(shifted, 1);
    if !li_is_loop_invariant(li, l, val) || !is_inst(nbits) return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    iid := ifx inst_op(shifted) == .SHL then IID_CTTZ else IID_CTLZ;
    iv: Value_Id = NONE;
    extra: Scev_Id;
    matched := false;
    if inst_op(nbits) == .ADD && (has_nsw(nbits) || has_nuw(nbits)) {
        for side: 0..1 {   // m_c_Add(m_Instruction(IV), m_LoopInvariant(m_Value(ExtraOffset)))
            a := op(nbits, cast(u32) side); e := op(nbits, cast(u32) (1 - side));
            if is_inst(a) && li_is_loop_invariant(li, l, e) {
                iv = a; extra = sc_get_negative(sc_get_scev(e)); matched = true; break;
            }
        }
    }
    if !matched && inst_op(nbits) == .SUB && is_inst(op(nbits, 0)) && li_is_loop_invariant(li, l, op(nbits, 1)) && has_nsw(nbits) {
        iv = op(nbits, 0); extra = sc_get_scev(op(nbits, 1)); matched = true;
    }
    if !matched { iv = nbits; extra = sc_get_zero(vtype(nbits)); }
    if inst_op(iv) != .PHI || inst_block(iv) != header return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    start := phi_incoming_for_block(iv, preheader);
    iv_next := phi_incoming_for_block(iv, header);
    if !is_inst(iv_next) || inst_op(iv_next) != .ADD || op(iv_next, 0) != iv || !pm_one(op(iv_next, 1)) return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    inverted := pred != ICMP_EQ;
    if inverted { pred = icmp_inverse(pred); x := true_bb; true_bb = false_bb; false_bb = x; }
    if false_bb != header return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    if inst_op(shifted) == .ASHR && !li_is_must_progress(l, c.fn) && !sc_is_known_non_negative(sc_get_scev(val))
        return false, NONE, 0, NONE, NONE, NONE, SCEV_CNC, false;
    return true, is_zero, iid, iv, start, val, extra, inverted;
}

// recognizeShiftUntilZero
lir_recognize_shift_until_zero :: (c: *Lir) -> bool {
    ok, is_zero, iid, iv, start, val, extra_expr, inverted := lir_detect_shift_until_zero(c);
    if !ok return false;
    li := c.li; l := c.l;
    header := li_header(li, l);
    preheader := li_loop_preheader(li, l);
    succ_bb := li_exit_block(li, l);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    b.dbg = get_metadata(iv, 0);
    ty := vtype(val);
    bw := scalar_bits(val);
    ica := ica_new(iid, ty, .[const_poison(ty), const_false()]);
    if tti_intrinsic_cost(c.tti, *ica, TCK_SIZE_AND_LATENCY) > TCC_BASIC return false;
    offset_is_zero := sc_is_zero(extra_expr);
    nlz := lir_intrinsic(*b, iid, .[ty], .[val, const_false()], tprint("%.numleadingzeros", vname(val)));
    nab := irb_binop(*b, .SUB, const_int(ty, bw), nlz, tprint("%.numactivebits", vname(val)), F_NUW | lir_fl(bw != 2, F_NSW));
    x: Scev_Expander;
    sx_init(*x, "loop-idiom");
    sx_set_insert_point(*x, b.pt);
    extra := sx_expand_code_for(*x, extra_expr);
    nabo := irb_binop(*b, .ADD, nab, extra, tprint("%.offset", vname(nab)), lir_fl(offset_is_zero, F_NUW) | F_NSW);
    iv_final := lir_intrinsic(*b, IID_SMAX, .[ty], .[nabo, start], "iv.final");
    lname := vname(header);
    btc := irb_binop(*b, .SUB, iv_final, start, tprint("%.backedgetakencount", lname), lir_fl(offset_is_zero, F_NUW) | F_NSW);
    tc := irb_binop(*b, .ADD, btc, const_int(ty, 1), tprint("%.tripcount", lname), F_NUW | lir_fl(bw != 2, F_NSW));
    replace_uses_outside_block(iv, iv_final, header);
    irb_set_at(*b, header, block_first(header), true);
    civ := irb_phi(*b, ty, 2, tprint("%.iv", lname));
    irb_set_at(*b, header, block_first_non_phi(header), true);
    civ_next := irb_binop(*b, .ADD, civ, const_int(ty, 1), tprint("%.next", vname(civ)), F_NUW | lir_fl(bw != 2, F_NSW));
    civ_check := irb_icmp(*b, ICMP_EQ, civ_next, tc, tprint("%.ivcheck", lname));
    new_check := civ_check;
    if inverted {
        new_check = irb_binop(*b, .XOR, civ_check, const_all_ones_of(vtype(civ_check)), "");   // CreateNot
        lir_take_name(new_check, is_zero);
    }
    iv_dephid := irb_binop(*b, .ADD, civ, start, "", F_NSW);
    lir_take_name(iv_dephid, iv);
    irb_set_before(*b, block_terminator(header));
    old_term := block_terminator(header);
    has_w, w := extract_branch_weights_any(old_term);
    nbi := irb_insert(*b, create_cond_br(civ_check, succ_bb, header));
    if has_w {
        if inverted { t := w[0]; w[0] = w[1]; w[1] = t; }
        set_branch_weights(nbi, w);
    }
    erase_inst(old_term);
    phi_add_incoming(civ, const_int(ty, 0), preheader);
    phi_add_incoming(civ, civ_next, header);
    sc_forget_loop(l);
    rauw_with_metadata(iv, iv_dephid);
    erase_inst_with_metadata(iv);
    rauw_with_metadata(is_zero, new_check);
    erase_inst_with_metadata(is_zero);
    return true;
}
