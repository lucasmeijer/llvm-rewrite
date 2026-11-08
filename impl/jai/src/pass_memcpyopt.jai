// MemCpyOpt: a port of llvm/lib/Transforms/Scalar/MemCpyOptimizer.cpp (MemsetRanges / tryMergingIntoMemset, moveUp,
// processStoreOfLoad, processStore, processMemSet, performCallSlotOptzn, processMemCpyMemCpyDependence,
// processMemSetMemCpyDependence, hasUndefContents / overreadUndefContents, performMemCpyToMemSetOptzn,
// performStackMoveOptzn, processMemCpy, isMemMoveMemSetDependency, processMemMove, processByValArgument,
// processImmutArgument, iterateOnFunction, runImpl; -enable-memcpyopt-without-libcalls).
//
// Data-oriented: one Mco state per run. The pass-wide EarliestEscapeAnalysis (EEA_) is an earliest-escape Aa_Query
// (`ee`) whose capture cache backs every BatchAAResults(AA, EEA) (aa_query_new_sharing_ee); AA->... calls on the
// AAResults get a fresh SimpleAAQueryInfo each (aa_query_new). MemsetRanges is an array of ranges sorted by start.
// Not ported (unreachable here): DIAssignID merging (assignment tracking does not parse).

mco_opts: struct {
    enable_without_libcalls := false;   // -enable-memcpyopt-without-libcalls
};
MCO_CL_OPT_COUNT :: 1;
add_mco_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"enable-memcpyopt-without-libcalls", .BOOL, *mco_opts.enable_without_libcalls, null, null};
}

Mco :: struct {
    f: Value_Id;
    tli: *Tli;
    aar: Aa_Results;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    m: *Memory_SSA;
    u: Mssa_Updater;
    ee: *Aa_Query;     // EarliestEscapeAnalysis EEA_(*DT)
}

mco_aa :: (s: *Mco) -> *Aa_Query { return aa_query_new(*s.aar); }               // AA->... (SimpleAAQueryInfo)
mco_baa :: (s: *Mco) -> *Aa_Query { return aa_query_new_sharing_ee(*s.aar, s.ee); }  // BatchAAResults(*AA, EEA)
mco_is_must_alias :: (q: *Aa_Query, a: Value_Id, b: Value_Id) -> bool { return aa_is_must_alias_values(q, a, b); }

// MemIntrinsicBase::getDest / MemTransferBase::getSource: the raw operand with pointer casts stripped
mi_dest :: (i: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(i, 0)); }
mi_source :: (i: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(i, 1)); }
is_memcpy_inst :: (i: Value_Id) -> bool { if !is_inst(i) || inst_op(i) != .CALL return false; id := call_iid(i); return id == IID_MEMCPY || id == IID_MEMCPY_INLINE; }
is_memmove_inst :: (i: Value_Id) -> bool { return is_inst(i) && inst_op(i) == .CALL && call_iid(i) == IID_MEMMOVE; }

// IRBuilder::CreateMemTransferInst
mco_create_mem_transfer :: (b: *Irb, id: Intrinsic_Id, dst: Value_Id, dst_align: u64, src: Value_Id, src_align: u64, size: Value_Id, volatile: bool) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, .[vtype(dst), vtype(src), vtype(size)]);
    ci := irb_call(b, f, .[dst, src, size, const_int(ir.t_i1, ifx volatile then cast(u64) 1 else 0)]);
    if dst_align add_param_align(ci, 0, dst_align);
    if src_align add_param_align(ci, 1, src_align);
    return ci;
}
// IRBuilder::CreateICmp with ConstantFolder
mco_icmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id) -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) { x := cf_compare(pred, l, r); if x != NONE return x; }
    return irb_insert(b, create_icmp(pred, l, r));
}
// IRBuilder::CreateTypeSize(Ty, Size)
mco_type_size :: (b: *Irb, ty: Type_Id, size: u64, scalable: bool) -> Value_Id {
    if !scalable || size == 0 return const_int(ty, size);
    vs := irb_call(b, get_or_insert_intrinsic_declaration(IID_VSCALE, .[ty]), .[]);
    if size == 1 return vs;
    return irb_binop(b, .MUL, vs, const_int(ty, size), "", F_NUW);
}
// CreatePtrAdd: getelementptr i8 (no flags)
mco_ptr_add :: (b: *Irb, ptr: Value_Id, off: Value_Id) -> Value_Id { return irb_gep(b, ir.t_i8, ptr, .[off]); }

// AllocaInst::getAllocationSize: (ok, size, scalable)
mco_alloca_size :: (a: Value_Id) -> (bool, u64, bool) {
    t := inst(a).ty2;
    if type_is_scalable(t) {
        if !is_scalar_const_int(op(a, 0)) || !ap_is_one(const_ap(op(a, 0))) {
            if dl_type_alloc_size(t) == 0 return true, 0, true;
            return false, 0, false;
        }
        return true, dl_type_alloc_size(t), true;
    }
    ok, sz := alloca_allocation_size(a);
    return ok, sz, false;
}

// MemCpyOptPass::eraseInstruction
mco_erase_instruction :: (s: *Mco, i: Value_Id) {
    mssau_remove_memory_access_inst(*s.u, i);
    aa_query_remove_instruction(s.ee, i);
    erase_inst_with_metadata(i);
}

// ---------------------------------------------------------------- MemsetRanges

Memset_Range :: struct {
    start: s64; end: s64;
    start_ptr: Value_Id;
    align: u64;               // MaybeAlign (0 = none)
    stores: [..] Value_Id;
}

// MemsetRange::isProfitableToUseMemset
mco_range_profitable :: (r: *Memset_Range) -> bool {
    if r.stores.count >= 4 || r.end - r.start >= 16 return true;
    if r.stores.count < 2 return false;
    for r.stores if inst_op(it) != .STORE return true;
    if r.stores.count == 2 return false;
    bytes := cast(u32)(r.end - r.start);
    max_int_size := cast(u32)(dl_largest_legal_int_bits() / 8);
    if max_int_size == 0 max_int_size = 1;
    num_ptr := bytes / max_int_size;
    num_byte := bytes % max_int_size;
    return r.stores.count > cast(s64)(num_ptr + num_byte);
}
dl_largest_legal_int_bits :: () -> u64 {
    r: u64 = 0;
    for dl.legal_ints if it > r r = it;
    return r;
}

// MemsetRanges::addRange (addInst = addStore / addMemSet below)
mco_add_range :: (ranges: *[..] Memset_Range, start: s64, size: s64, ptr: Value_Id, align: u64, i: Value_Id) {
    end := start + size;
    k := 0;
    while k < ranges.count && ranges.*[k].end < start k += 1;
    if k == ranges.count || end < ranges.*[k].start {
        r: Memset_Range; r.start = start; r.end = end; r.start_ptr = ptr; r.align = align; r.stores.allocator = temp;
        array_add(*r.stores, i);
        array_insert_at(ranges, r, k);
        return;
    }
    cur := *ranges.*[k];
    array_add(*cur.stores, i);
    if cur.start <= start && cur.end >= end return;
    if start < cur.start { cur.start = start; cur.start_ptr = ptr; cur.align = align; }
    if end > cur.end {
        cur.end = end;
        while k + 1 < ranges.count && end >= ranges.*[k + 1].start {
            nx := *ranges.*[k + 1];
            cur = *ranges.*[k];
            for nx.stores array_add(*cur.stores, it);
            if nx.end > cur.end cur.end = nx.end;
            array_ordered_remove_by_index(ranges, k + 1);
        }
    }
}
mco_add_store :: (ranges: *[..] Memset_Range, off: s64, si: Value_Id) {
    sz := dl_type_store_size(vtype(op(si, 0)));
    mco_add_range(ranges, off, cast(s64) sz, op(si, 1), inst(si).align, si);
}
mco_add_memset :: (ranges: *[..] Memset_Range, off: s64, msi: Value_Id) {
    sz := ap_zext_value(const_ap(call_arg(msi, 2)));
    mco_add_range(ranges, off, cast(s64) sz, mi_dest(msi), mi_param_align(msi, 0), msi);
}

// ---------------------------------------------------------------- helpers

// mayBeVisibleThroughUnwinding
mco_may_be_visible_through_unwinding :: (v: Value_Id, start: Value_Id, end: Value_Id) -> bool {
    if fn_has_fn_attr(inst_fn(start), .NoUnwind) return false;
    ok, requires := is_not_visible_on_unwind(get_underlying_object(v));
    if ok && !requires return false;
    x := start;
    while x != end && x != NONE {
        if may_throw(x) return true;
        x = inst(x).next;
    }
    return false;
}

// accessedBetween: (accessed, skipped lifetime.start)
mco_accessed_between :: (s: *Mco, q: *Aa_Query, loc: Mem_Loc, start: s32, end: s32, allow_skip: bool) -> (bool, Value_Id) {
    skipped: Value_Id = NONE;
    a := s.m.acc[start].next;
    while a != end && a >= 0 {
        i := s.m.acc[a].inst;
        if aa_mod_ref_inst_loc(q, i, loc) != MR_NO {
            if inst_op(i) == .CALL && call_iid(i) == IID_LIFETIME_START && allow_skip && skipped == NONE {
                skipped = i;
                a = s.m.acc[a].next;
                continue;
            }
            return true, skipped;
        }
        a = s.m.acc[a].next;
    }
    return false, skipped;
}

// writtenBetween
mco_written_between :: (s: *Mco, q: *Aa_Query, loc: Mem_Loc, start: s32, end: s32) -> bool {
    m := s.m;
    if ma_is_use(m, end) {
        if m.acc[start].block != m.acc[end].block return true;
        a := m.acc[start].next;
        while a != end && a >= 0 {
            if !ma_is_use(m, a) {
                if aa_mod_ref_inst_loc(q, m.acc[a].inst, loc) & MR_MOD return true;
            }
            a = m.acc[a].next;
        }
        return false;
    }
    clobber := mssa_get_clobbering_access_for_loc(m, ma_defining(m, end), loc, q);
    return !mssa_dominates(m, clobber, start);
}

// tryMergingIntoMemset
mco_try_merging_into_memset :: (s: *Mco, start_inst: Value_Id, start_ptr_in: Value_Id, byte_val: Value_Id) -> Value_Id {
    start_ptr := start_ptr_in;
    if inst_op(start_inst) == .STORE && type_is_scalable(vtype(op(start_inst, 0))) return NONE;
    ranges: [..] Memset_Range; ranges.allocator = temp;
    mem_insert_point: s32 = -1;
    bi := start_inst;
    while true {
        bi = inst(bi).next;
        if is_terminator(inst_op(bi)) break;
        cur := mssa_access_of(s.m, bi);
        if cur >= 0 mem_insert_point = cur;
        if is_call_base(bi) && call_only_accesses_inaccessible_memory(bi) continue;
        is_store := inst_op(bi) == .STORE;
        is_ms := is_memset_inst(bi);
        if !is_store && !is_ms {
            if may_write_to_memory(bi) || may_read_from_memory(bi) break;
            continue;
        }
        if is_store {
            if !is_simple_load_store(bi) break;
            sv := op(bi, 0);
            if dl_is_non_integral_pointer_type(vtype(sv)) break;
            if type_is_scalable(vtype(sv)) break;
            sb := is_bytewise_value(sv);
            if byte_val != sb break;
            ok, off := value_pointer_offset_from(op(bi, 1), start_ptr);
            if !ok break;
            mco_add_store(*ranges, off, bi);
        } else {
            if mi_is_volatile(bi) || byte_val != call_arg(bi, 1) || !is_scalar_const_int(call_arg(bi, 2)) break;
            ok, off := value_pointer_offset_from(mi_dest(bi), start_ptr);
            if !ok break;
            mco_add_memset(*ranges, off, bi);
        }
    }
    if ranges.count == 0 return NONE;
    if inst_op(start_inst) == .STORE mco_add_store(*ranges, 0, start_inst);
    else mco_add_memset(*ranges, 0, start_inst);
    b: Irb; irb_set_before(*b, bi);
    a_mem_set: Value_Id = NONE;
    for * r: ranges {
        if r.stores.count == 1 continue;
        if !mco_range_profitable(r) continue;
        start_ptr = r.start_ptr;
        a_mem_set = irb_memset(*b, start_ptr, byte_val, const_int(ir.t_i64, cast(u64)(r.end - r.start)), r.align, false);
        if r.stores.count set_metadata(a_mem_set, 0, get_metadata(r.stores[0], 0));
        nd: s32;
        if s.m.acc[mem_insert_point].inst == bi nd = mssau_create_memory_access_before(*s.u, a_mem_set, -1, mem_insert_point);
        else nd = mssau_create_memory_access_after(*s.u, a_mem_set, -1, mem_insert_point);
        mssau_insert_def(*s.u, nd, true);
        mem_insert_point = nd;
        for r.stores mco_erase_instruction(s, it);
    }
    return a_mem_set;
}
is_simple_load_store :: (i: Value_Id) -> bool { return inst(i).ord1 == 0 && (inst(i).flags & F_VOLATILE) == 0; }

// moveUp
mco_move_up :: (s: *Mco, si: Value_Id, p: Value_Id, li: Value_Id) -> bool {
    store_loc := mloc_get(si);
    if aa_mod_ref_inst_loc(mco_aa(s), p, store_loc) != MR_NO return false;
    args: Table(Value_Id, bool); args.allocator = temp;
    add_arg :: (args: *Table(Value_Id, bool), si: Value_Id, p: Value_Id, a: Value_Id) -> bool {
        if is_inst(a) && inst_block(a) == inst_block(si) {
            if a == p return false;
            table_set(args, a, true);
        }
        return true;
    }
    if !add_arg(*args, si, p, op(si, 1)) return false;
    to_lift: [..] Value_Id; to_lift.allocator = temp;
    array_add(*to_lift, si);
    mem_locs: [..] Mem_Loc; mem_locs.allocator = temp;
    array_add(*mem_locs, store_loc);
    calls: [..] Value_Id; calls.allocator = temp;
    load_loc := mloc_get(li);
    c := inst(si).prev;
    while c != p {
        defer c = inst(c).prev;
        if !is_guaranteed_to_transfer_execution(c) return false;
        may_alias := aa_mod_ref_inst_opt_loc(mco_aa(s), c, false, .{}) != MR_NO;
        need_lift := false;
        if table_remove(*args, c) need_lift = true;
        else if may_alias {
            for ml: mem_locs if aa_mod_ref_inst_loc(mco_aa(s), c, ml) != MR_NO { need_lift = true; break; }
            if !need_lift for call: calls if aa_mod_ref_inst_call(mco_aa(s), c, call) != MR_NO { need_lift = true; break; }
        }
        if !need_lift continue;
        if may_alias {
            if aa_mod_ref_inst_loc(mco_aa(s), c, load_loc) & MR_MOD return false;
            else if is_call_base(c) {
                if aa_mod_ref_inst_call(mco_aa(s), p, c) != MR_NO return false;
                array_add(*calls, c);
            } else if inst_op(c) == .LOAD || inst_op(c) == .STORE || inst_op(c) == .VAARG {
                ml := mloc_get(c);
                if aa_mod_ref_inst_loc(mco_aa(s), p, ml) != MR_NO return false;
                array_add(*mem_locs, ml);
            } else return false;
        }
        array_add(*to_lift, c);
        for k: 0..cast(s64) nops(c) - 1 if !add_arg(*args, si, p, op(c, cast(u32) k)) return false;
    }
    mem_insert_point: s32 = -1;
    pa := mssa_access_of(s.m, p);
    if pa >= 0 mem_insert_point = s.m.acc[pa].prev;
    else {
        x := inst(p).prev;
        while true {
            a := mssa_access_of(s.m, x);
            if a >= 0 { mem_insert_point = a; break; }
            if x == li break;
            x = inst(x).prev;
        }
    }
    for < to_lift {
        inst_move_before_dbg(it, p);
        a := mssa_access_of(s.m, it);
        if a >= 0 {
            mssau_move_after(*s.u, a, mem_insert_point);
            mem_insert_point = a;
        }
    }
    return true;
}

// processStoreOfLoad: (changed, new iterator position or NONE = unchanged)
mco_process_store_of_load :: (s: *Mco, si: Value_Id, li: Value_Id, bbi: *Value_Id) -> bool {
    if !is_simple_load_store(li) || !has_one_use(li) || inst_block(li) != inst_block(si) return false;
    baa := mco_baa(s);
    t := vtype(li);
    tk := type_kind(t);
    if (tk == .STRUCT || tk == .ARRAY) && (mco_opts.enable_without_libcalls || (tli_func_has(s.tli, .memcpy) && tli_func_has(s.tli, .memmove))) {
        load_loc := mloc_get(li);
        p := si;
        x := inst(li).next;
        while x != si {
            if aa_mod_ref_inst_loc(baa, x, load_loc) & MR_MOD { p = x; break; }
            x = inst(x).next;
        }
        if p == si || mco_move_up(s, si, p, li) {
            use_mem_move := (aa_mod_ref_inst_loc(mco_aa(s), si, load_loc) & MR_MOD) != 0;
            b: Irb; irb_set_before(*b, p);
            size := mco_type_size(*b, ir.t_i64, dl_type_store_size(t), type_is_scalable(t));
            mi := mco_create_mem_transfer(*b, ifx use_mem_move then IID_MEMMOVE else IID_MEMCPY, op(si, 1), inst(si).align, op(li, 0), inst(li).align, size, false);
            last_def := mssa_access_of(s.m, si);
            na := mssau_create_memory_access_after(*s.u, mi, -1, last_def);
            mssau_insert_def(*s.u, na, true);
            mco_erase_instruction(s, si);
            mco_erase_instruction(s, li);
            bbi.* = mi;
            return true;
        }
    }
    sp := strip_pointer_casts(op(si, 1));
    lp := strip_pointer_casts(op(li, 0));
    if mco_perform_call_slot_optzn(s, li, si, sp, lp, dl_type_store_size(vtype(op(si, 0))), type_is_scalable(vtype(op(si, 0))),
                                   min(inst(si).align, inst(li).align), baa, NONE) {
        mco_erase_instruction(s, si);
        mco_erase_instruction(s, li);
        return true;
    }
    if mco_perform_stack_move_optzn(s, li, si, op(si, 1), op(li, 0), dl_type_store_size(t), type_is_scalable(t), baa) {
        bbi.* = inst(si).next;
        mco_erase_instruction(s, si);
        mco_erase_instruction(s, li);
        return true;
    }
    return false;
}

// processStore
mco_process_store :: (s: *Mco, si: Value_Id, bbi: *Value_Id) -> bool {
    if !is_simple_load_store(si) return false;
    if get_metadata(si, md_kind_id("nontemporal")) != NONE return false;
    sv := op(si, 0);
    if dl_is_non_integral_pointer_type(vtype(sv)) return false;
    if is_inst(sv) && inst_op(sv) == .LOAD return mco_process_store_of_load(s, si, sv, bbi);
    if !(tli_func_has(s.tli, .memset) || mco_opts.enable_without_libcalls) return false;
    byte_val := is_bytewise_value(sv);
    if byte_val == NONE return false;
    i := mco_try_merging_into_memset(s, si, op(si, 1), byte_val);
    if i != NONE { bbi.* = i; return true; }
    t := vtype(sv);
    tk := type_kind(t);
    if tk != .STRUCT && tk != .ARRAY return false;
    if type_is_scalable(t) return false;
    b: Irb; irb_set_before(*b, si);
    mi := irb_memset(*b, op(si, 1), byte_val, const_int(ir.t_i64, dl_type_store_size(t)), inst(si).align, false);
    store_def := mssa_access_of(s.m, si);
    na := mssau_create_memory_access_before(*s.u, mi, -1, store_def);
    mssau_insert_def(*s.u, na, false);
    mco_erase_instruction(s, si);
    bbi.* = mi;
    return true;
}

// processMemSet
mco_process_memset :: (s: *Mco, msi: Value_Id, bbi: *Value_Id) -> bool {
    if is_scalar_const_int(call_arg(msi, 2)) && !mi_is_volatile(msi) {
        i := mco_try_merging_into_memset(s, msi, mi_dest(msi), call_arg(msi, 1));
        if i != NONE { bbi.* = i; return true; }
    }
    return false;
}

// performCallSlotOptzn. `given_c` = the call (memcpy case) or NONE (load/store case: GetCall walks MemorySSA)
mco_perform_call_slot_optzn :: (s: *Mco, cpy_load: Value_Id, cpy_store: Value_Id, cpy_dest: Value_Id, cpy_src: Value_Id,
                                cpy_size: u64, cpy_size_scalable: bool, cpy_dest_align: u64, baa: *Aa_Query, given_c: Value_Id) -> bool {
    if cpy_size_scalable return false;
    if !is_inst(cpy_src) || inst_op(cpy_src) != .ALLOCA return false;
    src_alloca := cpy_src;
    ok, src_size, sc := mco_alloca_size(src_alloca);
    if !ok || sc return false;
    if cpy_size < src_size return false;
    c := given_c;
    if c == NONE {
        lc := mssa_get_clobbering_access_inst(s.m, cpy_load, baa);
        if lc >= 0 && !ma_is_phi(s.m, lc) && !is_live_on_entry(lc) {
            mi := s.m.acc[lc].inst;
            if inst_op(mi) == .CALL c = mi;
        }
    }
    if c == NONE return false;
    cf := call_called_function(c);
    if cf != NONE && call_iid(c) == IID_LIFETIME_START return false;
    if inst_block(c) != inst_block(cpy_store) return false;
    dest_loc := ifx inst_op(cpy_store) == .STORE then mloc_get(cpy_store) else mloc_for_dest(cpy_store);
    accessed, skipped := mco_accessed_between(s, baa, dest_loc, mssa_access_of(s.m, c), mssa_access_of(s.m, cpy_store), true);
    if accessed return false;
    if skipped != NONE {
        la := op(skipped, 0);
        if is_inst(la) && inst_block(la) == inst_block(c) && comes_before(c, la) return false;
    }
    wok, _ := is_writable_object(get_underlying_object(cpy_dest));
    q: Simplify_Query; q.dt = s.dt; q.ac = s.ac; q.cxt = c;
    if !wok || !is_dereferenceable_and_aligned_pointer(cpy_dest, 1, ap_from_u64(64, cpy_size), q) return false;
    if mco_may_be_visible_through_unwinding(cpy_dest, c, cpy_store) return false;
    src_align := inst(src_alloca).align;
    is_dest_sufficiently_aligned := src_align <= cpy_dest_align;
    if !is_dest_sufficiently_aligned && !(is_inst(cpy_dest) && inst_op(cpy_dest) == .ALLOCA) return false;
    // src is only used by the call, the load/copy and lifetime markers
    worklist: [..] Value_Id; worklist.allocator = temp;
    users_into :: (v: Value_Id, out: *[..] Value_Id) {
        u := ir.v_first_use[v];
        while u != NONE { array_add(out, ir.u_user[u]); u = ir.u_next[u]; }
    }
    users_into(src_alloca, *worklist);
    while worklist.count {
        usr := pop(*worklist);
        if is_inst(usr) && inst_op(usr) == .ADDRSPACECAST { users_into(usr, *worklist); continue; }
        if is_inst(usr) && inst_op(usr) == .CALL && (call_iid(usr) == IID_LIFETIME_START || call_iid(usr) == IID_LIFETIME_END_DSE) continue;
        if usr != c && usr != cpy_load return false;
    }
    src_is_captured := false;
    na := call_num_args(c);
    if na > 0 for k: 0..na - 1 {
        if strip_pointer_casts(call_arg(c, k)) == cpy_src && !call_does_not_capture(c, k) { src_is_captured = true; break; }
    }
    if src_is_captured {
        dest_obj := get_underlying_object(cpy_dest);
        if !is_identified_function_local(dest_obj) || pointer_may_be_captured_before(dest_obj, true, c, s.dt, true) != CC_NONE return false;
        src_loc := mloc(src_alloca, ls_precise(src_size));
        x := inst(c).next;
        while x != NONE {
            if inst_op(x) == .CALL && call_iid(x) == IID_LIFETIME_END_DSE && call_arg(x, 0) == src_alloca break;
            if inst_op(x) == .RET break;
            if x != cpy_load {
                if aa_mod_ref_inst_loc(baa, x, src_loc) != MR_NO || is_terminator(inst_op(x)) return false;
            }
            x = inst(x).next;
        }
    }
    need_move_gep := false;
    if !dt_dominates_inst(s.dt, cpy_dest, c) {
        if is_inst(cpy_dest) && inst_op(cpy_dest) == .GEP && gep_has_all_constant_indices(cpy_dest) && dt_dominates_inst(s.dt, op(cpy_dest, 0), c)
            need_move_gep = true;
        else return false;
    }
    dest_with_src_size := mloc(cpy_dest, ls_precise(src_size));
    mr := aa_mod_ref_inst_loc(baa, c, dest_with_src_size);
    if mr != MR_NO mr = aa_call_captures_before(baa, c, dest_with_src_size, s.dt);
    if mr != MR_NO return false;
    if vtype(cpy_src) != vtype(cpy_dest) return false;
    if na > 0 for k: 0..na - 1 {
        a := call_arg(c, k);
        if strip_pointer_casts(a) == cpy_src && vtype(cpy_src) != vtype(a) return false;
    }
    changed_argument := false;
    if na > 0 for k: 0..na - 1 {
        if strip_pointer_casts(call_arg(c, k)) == cpy_src { changed_argument = true; set_op(c, k, cpy_dest); }
    }
    if !changed_argument return false;
    if !is_dest_sufficiently_aligned inst(cpy_dest).align = max(inst(cpy_dest).align, src_align);
    if need_move_gep inst_move_before_dbg(cpy_dest, c);
    if skipped != NONE {
        inst_move_before_dbg(skipped, c);
        mssau_move_before(*s.u, mssa_access_of(s.m, skipped), mssa_access_of(s.m, c));
    }
    combine_aa_metadata(c, cpy_load);
    if cpy_load != cpy_store combine_aa_metadata(c, cpy_store);
    return true;
}

// processMemCpyMemCpyDependence
mco_process_memcpy_memcpy_dependence :: (s: *Mco, m: Value_Id, mdep: Value_Id, baa: *Aa_Query) -> bool {
    if mi_is_volatile(mdep) return false;
    if mco_is_must_alias(baa, mi_dest(mdep), mi_source(mdep)) return false;
    forward_off: s64 = 0;
    if mi_source(m) != mi_dest(mdep) {
        ok, off := value_pointer_offset_from(mi_source(m), mi_dest(mdep));
        if !ok || off < 0 return false;
        forward_off = off;
    }
    copy_length := call_arg(m, 2);
    if forward_off != 0 || call_arg(mdep, 2) != copy_length {
        mdep_len := call_arg(mdep, 2);
        if !is_scalar_const_int(mdep_len) || !is_scalar_const_int(copy_length) return false;
        dl_ := ap_zext_value(const_ap(mdep_len)); ml := ap_zext_value(const_ap(copy_length));
        if dl_ < ml + cast(u64) forward_off {
            if !mco_overread_undef_contents(s, m, mdep, baa) return false;
            if dl_ <= cast(u64) forward_off return false;
            copy_length = const_int(vtype(copy_length), dl_ - cast(u64) forward_off);
        }
    }
    b: Irb; irb_set_before(*b, m);
    copy_source := mi_source(mdep);
    new_copy_source: Value_Id = NONE;
    cleanup :: (s: *Mco, ncs: Value_Id) { if ncs != NONE && !has_uses(ncs) mco_erase_instruction(s, ncs); }
    copy_source_align := mi_param_align(mdep, 1);
    mcopy_loc := mloc_for_source(mdep);
    if call_arg(mdep, 2) != copy_length mcopy_loc.size = ls_precise(ap_zext_value(const_ap(copy_length)));
    if forward_off > 0 {
        okd, mdest_off := value_pointer_offset_from(call_arg(m, 0), call_arg(mdep, 1));
        if okd && mdest_off == forward_off copy_source = mi_dest(m);
        else {
            copy_source = irb_inbounds_ptr_add(*b, copy_source, const_int(ir.t_i64, cast(u64) forward_off));
            if is_inst(copy_source) new_copy_source = copy_source;
        }
        mcopy_loc.ptr = copy_source;
        if copy_source_align copy_source_align = common_alignment(copy_source_align, cast(u64) forward_off);
    }
    if mco_written_between(s, baa, mcopy_loc, mssa_access_of(s.m, mdep), mssa_access_of(s.m, m)) { cleanup(s, new_copy_source); return false; }
    if mco_is_must_alias(baa, mi_dest(m), copy_source) {
        mco_erase_instruction(s, m);
        cleanup(s, new_copy_source);
        return true;
    }
    use_mem_move := false;
    is_inline := call_iid(m) == IID_MEMCPY_INLINE;
    if aa_mod_ref_inst_loc(baa, m, mloc_for_source(mdep)) & MR_MOD {
        if is_inline { cleanup(s, new_copy_source); return false; }
        use_mem_move = true;
    }
    id := ifx use_mem_move then IID_MEMMOVE else ifx is_inline then IID_MEMCPY_INLINE else IID_MEMCPY;
    new_m := mco_create_mem_transfer(*b, id, mi_dest(m), mi_param_align(m, 0), copy_source, copy_source_align, copy_length, mi_is_volatile(m));
    last_def := mssa_access_of(s.m, m);
    na := mssau_create_memory_access_after(*s.u, new_m, -1, last_def);
    mssau_insert_def(*s.u, na, true);
    mco_erase_instruction(s, m);
    cleanup(s, new_copy_source);
    return true;
}

// processMemSetMemCpyDependence
mco_process_memset_memcpy_dependence :: (s: *Mco, memcpy: Value_Id, memset: Value_Id, baa: *Aa_Query) -> bool {
    if !mco_is_must_alias(baa, mi_dest(memset), mi_dest(memcpy)) return false;
    if mi_is_volatile(memset) return false;
    src_size := call_arg(memcpy, 2);
    q: Simplify_Query; q.dt = s.dt; q.ac = s.ac; q.cxt = memcpy;
    if !is_known_non_zero(src_size, q) return false;
    if aa_mod_ref_inst_loc(baa, memcpy, mloc_for_source(memcpy)) & MR_MOD return false;
    acc, _ := mco_accessed_between(s, baa, mloc_for_dest(memset), mssa_access_of(s.m, memset), mssa_access_of(s.m, memcpy), false);
    if acc return false;
    dest := call_arg(memcpy, 0);
    dest_size := call_arg(memset, 2);
    if mco_may_be_visible_through_unwinding(dest, memset, memcpy) return false;
    if dest_size == src_size { mco_erase_instruction(s, memset); return true; }
    alignment: u64 = 1;
    da := max(max(mi_param_align(memset, 0), 1), max(mi_param_align(memcpy, 0), 1));
    if da > 1 && is_scalar_const_int(src_size) alignment = common_alignment(da, ap_zext_value(const_ap(src_size)));
    b: Irb; irb_set_before(*b, memcpy);
    b.dbg = get_metadata(memset, 0);
    if vtype(dest_size) != vtype(src_size) {
        if type_bits(vtype(dest_size)) > type_bits(vtype(src_size)) src_size = irb_cast(*b, .ZEXT, src_size, vtype(dest_size));
        else dest_size = irb_cast(*b, .ZEXT, dest_size, vtype(src_size));
    }
    ule := mco_icmp(*b, ICMP_ULE, dest_size, src_size);
    size_diff := irb_binop(*b, .SUB, dest_size, src_size);
    memset_len := irb_select(*b, ule, const_null_value(vtype(dest_size)), size_diff);
    if is_inst(memset_len) && inst_op(memset_len) == .SELECT set_explicitly_unknown_branch_weights_if_profiled(memset_len, "memcpyopt");
    new_ms := irb_memset(*b, mco_ptr_add(*b, dest, src_size), call_arg(memset, 1), memset_len, alignment, false);
    last_def := mssa_access_of(s.m, memcpy);
    na := mssau_create_memory_access_before(*s.u, new_ms, -1, last_def);
    mssau_insert_def(*s.u, na, true);
    mco_erase_instruction(s, memset);
    return true;
}

// hasUndefContents
mco_has_undef_contents :: (s: *Mco, v: Value_Id, def: s32) -> bool {
    if is_live_on_entry(def) { uo := get_underlying_object(v); return is_inst(uo) && inst_op(uo) == .ALLOCA; }
    i := s.m.acc[def].inst;
    if i != NONE && inst_op(i) == .CALL && call_iid(i) == IID_LIFETIME_START {
        uo := get_underlying_object(v);
        if is_inst(uo) && inst_op(uo) == .ALLOCA return call_arg(i, 0) == uo;
    }
    return false;
}
// overreadUndefContents
mco_overread_undef_contents :: (s: *Mco, memcpy: Value_Id, memsrc: Value_Id, baa: *Aa_Query) -> bool {
    loc := mloc_for_source(memcpy);
    src_access := mssa_access_of(s.m, memsrc);
    clobber := mssa_get_clobbering_access_for_loc(s.m, ma_defining(s.m, src_access), loc, baa);
    if ma_is_def(s.m, clobber) && mco_has_undef_contents(s, mi_source(memcpy), clobber) return true;
    return false;
}

// performMemCpyToMemSetOptzn
mco_perform_memcpy_to_memset_optzn :: (s: *Mco, memcpy: Value_Id, memset: Value_Id, baa: *Aa_Query) -> bool {
    memset_size := call_arg(memset, 2);
    copy_size := call_arg(memcpy, 2);
    moff: s64 = 0;
    if mi_source(memcpy) != mi_dest(memset) {
        ok, off := value_pointer_offset_from(mi_source(memcpy), mi_dest(memset));
        if !ok return false;
        moff = off;
    }
    if moff != 0 || memset_size != copy_size {
        cms := is_scalar_const_int(memset_size); ccs := is_scalar_const_int(copy_size);
        if !cms || !ccs || moff < 0 || ap_zext_value(const_ap(copy_size)) + cast(u64) moff > ap_zext_value(const_ap(memset_size)) {
            if !mco_overread_undef_contents(s, memcpy, memset, baa) return false;
            if cms && ccs {
                msv := ap_zext_value(const_ap(memset_size));
                mcv := ap_zext_value(const_ap(copy_size));
                new_size: u64;
                if moff < 0 { o := cast(u64) -moff; new_size = ifx mcv <= o then 0 else mcv - o; }
                else if moff == 0 new_size = msv;
                else new_size = ifx msv <= cast(u64) moff then 0 else msv - cast(u64) moff;
                copy_size = const_int(vtype(copy_size), new_size);
            } else if moff < 0 return false;
        }
    }
    b: Irb; irb_set_before(*b, memcpy);
    dest_ptr := call_arg(memcpy, 0);
    align := mi_param_align(memcpy, 0);
    if moff < 0 {
        dest_ptr = mco_ptr_add(*b, dest_ptr, const_int(ir.t_i64, cast(u64) -moff));
        if align align = common_alignment(align, cast(u64) -moff);
    }
    new_m := irb_memset(*b, dest_ptr, call_arg(memset, 1), copy_size, align, false);
    last_def := mssa_access_of(s.m, memcpy);
    na := mssau_create_memory_access_after(*s.u, new_m, -1, last_def);
    mssau_insert_def(*s.u, na, true);
    return true;
}

// performStackMoveOptzn
mco_perform_stack_move_optzn :: (s: *Mco, load: Value_Id, store: Value_Id, dest_ptr: Value_Id, src_ptr: Value_Id,
                                 size: u64, size_scalable: bool, baa: *Aa_Query) -> bool {
    dest_alloca := get_underlying_object(dest_ptr);
    if !is_inst(dest_alloca) || inst_op(dest_alloca) != .ALLOCA return false;
    src_alloca := get_underlying_object(src_ptr);
    if !is_inst(src_alloca) || inst_op(src_alloca) != .ALLOCA return false;
    if src_alloca == dest_alloca return false;
    if type_addrspace(vtype(src_alloca)) != type_addrspace(vtype(dest_alloca)) return false;
    if !is_static_alloca(src_alloca) || !is_static_alloca(dest_alloca) return false;
    okd, dest_offset := value_pointer_offset_from(dest_ptr, dest_alloca);
    if !okd return false;
    oks, src_offset := value_pointer_offset_from(src_ptr, src_alloca);
    if !oks || src_offset < dest_offset || src_offset < 0 return false;
    if (src_offset - dest_offset) % cast(s64) inst(dest_alloca).align != 0 return false;
    ok1, src_size, src_sc := mco_alloca_size(src_alloca);
    ok2, dest_size, dest_sc := mco_alloca_size(dest_alloca);
    if !ok1 || !ok2 return false;
    if src_size != dest_size || src_sc != dest_sc {
        if src_sc || dest_sc return false;
    }
    if size != dest_size || size_scalable != dest_sc || dest_offset != 0 return false;
    if src_offset != 0 {
        if size_scalable || cast(u64) src_offset + size > src_size return false;
    }
    move_src := !dt_dominates_inst(s.dt, src_alloca, dest_alloca);
    if move_src && !dt_dominates_inst(s.dt, dest_alloca, src_alloca) return false;

    lifetime_markers: [..] Value_Id; lifetime_markers.allocator = temp;
    aa_md_instrs: [..] Value_Id; aa_md_instrs.allocator = temp;     // SmallPtrSet (only iterated to drop metadata)
    aa_md_set: Table(Value_Id, bool); aa_md_set.allocator = temp;

    Cb_Kind :: enum u8 { DEST; SRC; }
    Cb :: struct {
        kind: Cb_Kind;
        // DEST
        dest_mod_ref: u8;
        dest_loc: Mem_Loc;
        reach: [..] Value_Id;
        // SRC
        src_loc: Mem_Loc;
    }
    callback :: (s: *Mco, cb: *Cb, ui: Value_Id, load: Value_Id, store: Value_Id, baa: *Aa_Query) -> bool {
        if cb.kind == {
            case .DEST;
                if ui == store return true;
                res := aa_mod_ref_inst_loc(baa, ui, cb.dest_loc);
                cb.dest_mod_ref |= res;
                if res != MR_NO {
                    if inst_block(ui) == inst_block(store) {
                        bb := inst_block(ui);
                        if comes_before(ui, store) return false;
                        if bb == fn_entry(block_fn(bb)) return true;
                        succs: [..] Value_Id; succs.allocator = temp;
                        block_successors(bb, *succs);
                        for succs array_add(*cb.reach, it);
                    } else array_add(*cb.reach, inst_block(ui));
                }
                return true;
            case .SRC; return true;
        }
        return true;
    }
    capture_tracking_with_mod_ref :: (s: *Mco, ai: Value_Id, cb: *Cb, address_captured: *bool, load: Value_Id, store: Value_Id,
                                      baa: *Aa_Query, lifetime_markers: *[..] Value_Id, aa_md_instrs: *[..] Value_Id,
                                      aa_md_set: *Table(Value_Id, bool), dest_mod_ref: u8) -> bool {
        worklist: [..] Value_Id; worklist.allocator = temp;
        array_add(*worklist, ai);
        max_uses := capture_tracking_max_uses;
        visited: Table(Use_Id, bool); visited.allocator = temp;
        while worklist.count {
            i := pop(*worklist);
            u := ir.v_first_use[i];
            while u != NONE {
                defer u = ir.u_next[u];
                ui := ir.u_user[u];
                if visited.count >= max_uses return false;
                if table_contains(*visited, u) continue;
                table_set(*visited, u, true);
                use_cc, result_cc := ct_use_capture_kind(u, ai);
                if cc_captures_any_provenance(use_cc) return false;
                if (use_cc & CC_ADDRESS) != 0 address_captured.* = true;
                if may_read_or_write_memory(ui) {
                    if is_lifetime_start_or_end(ui) { array_add(lifetime_markers, ui); continue; }
                    if !table_contains(aa_md_set, ui) { table_set(aa_md_set, ui, true); array_add(aa_md_instrs, ui); }
                    if cb.kind == .DEST {
                        if !callback(s, cb, ui, load, store, baa) return false;
                    } else {
                        // SrcModRefCallback
                        if !(dt_dominates_post_inst(s.pdt, load, ui) || ui == load || ui == store) {
                            res := aa_mod_ref_inst_loc(baa, ui, cb.src_loc);
                            if ((dest_mod_ref & MR_MOD) != 0 && (res & MR_REF) != 0) || ((dest_mod_ref & MR_REF) != 0 && (res & MR_MOD) != 0) return false;
                        }
                    }
                }
                if result_cc != CC_NONE { array_add(*worklist, ui); continue; }
            }
        }
        return true;
    }

    dcb: Cb; dcb.kind = .DEST; dcb.dest_loc = mloc(dest_alloca, ls_precise(dest_size, dest_sc)); dcb.reach.allocator = temp;
    dest_address_captured := false;
    if !capture_tracking_with_mod_ref(s, dest_alloca, *dcb, *dest_address_captured, load, store, baa, *lifetime_markers, *aa_md_instrs, *aa_md_set, 0) return false;
    if dcb.reach.count && is_potentially_reachable_from_many(dcb.reach, inst_block(store), s.dt) return false;
    scb: Cb; scb.kind = .SRC; scb.src_loc = mloc(src_ptr, ls_precise(size, size_scalable));
    src_address_captured := false;
    if !capture_tracking_with_mod_ref(s, src_alloca, *scb, *src_address_captured, load, store, baa, *lifetime_markers, *aa_md_instrs, *aa_md_set, dcb.dest_mod_ref) return false;
    if dest_address_captured && src_address_captured return false;

    if move_src inst_move_before_dbg(src_alloca, dest_alloca);
    inst(src_alloca).align = max(inst(src_alloca).align, inst(dest_alloca).align);
    if src_size != dest_size && dest_size > src_size {
        inst(src_alloca).ty2 = inst(dest_alloca).ty2;
        set_op(src_alloca, 0, op(dest_alloca, 0));
    }
    new_dest_ptr := src_alloca;
    if src_offset != dest_offset {
        b: Irb; irb_set_before(*b, dest_alloca);
        new_dest_ptr = irb_inbounds_ptr_add(*b, src_alloca, const_int(ir.t_i64, cast(u64)(src_offset - dest_offset)));
    }
    rauw_with_metadata(dest_alloca, new_dest_ptr);
    mco_erase_instruction(s, dest_alloca);
    drop_unknown_non_debug_metadata(src_alloca, .[]);
    for lifetime_markers mco_erase_instruction(s, it);
    for aa_md_instrs {
        set_metadata(it, md_kind_id("alias.scope"), NONE);
        set_metadata(it, md_kind_id("noalias"), NONE);
        set_metadata(it, md_kind_id("tbaa"), NONE);
        set_metadata(it, md_kind_id("tbaa.struct"), NONE);
    }
    return true;
}
// PostDominatorTree::dominates(const Instruction *I1, const Instruction *I2)
dt_dominates_post_inst :: (pdt: *Dom_Tree, i1: Value_Id, i2: Value_Id) -> bool {
    b1 := inst_block(i1); b2 := inst_block(i2);
    if b1 != b2 return dt_dominates(pdt, b1, b2);
    if inst_op(i1) == .PHI return false;   // PHINodes in a block are unordered
    if inst_op(i2) == .PHI return true;
    return !comes_before(i1, i2);
}

// isZeroSize
mco_is_zero_size :: (size_in: Value_Id) -> bool {
    size := size_in;
    if is_inst(size) {
        q: Simplify_Query;
        r := simplify_instruction(size, q);
        if r != NONE size = r;
    }
    if is_constant_kind(vkind(size)) return vkind(size) == .C_UNDEF || vkind(size) == .C_POISON || is_null_value(size);
    return false;
}

// processMemCpy
mco_process_memcpy :: (s: *Mco, m: Value_Id, bbi: *Value_Id) -> bool {
    if mi_is_volatile(m) return false;
    if mi_source(m) == mi_dest(m) {
        bbi.* = inst(bbi.*).next;   // ++BBI (BBI already points past M)
        mco_erase_instruction(s, m);
        return true;
    }
    if mco_is_zero_size(call_arg(m, 2)) {
        bbi.* = inst(bbi.*).next;
        mco_erase_instruction(s, m);
        return true;
    }
    ma_ := mssa_access_of(s.m, m);
    if ma_ < 0 return false;
    gv := get_underlying_object(mi_source(m));
    if vkind(gv) == .GLOBAL_VAR && glob(gv).is_const && gv_has_definitive_initializer(gv) {
        bv := is_bytewise_value(gv_initializer(gv));
        if bv != NONE {
            b: Irb; irb_set_before(*b, m);
            new_m := irb_memset(*b, call_arg(m, 0), bv, call_arg(m, 2), mi_param_align(m, 0), false);
            na := mssau_create_memory_access_after(*s.u, new_m, -1, ma_);
            mssau_insert_def(*s.u, na, true);
            mco_erase_instruction(s, m);
            return true;
        }
    }
    baa := mco_baa(s);
    any_clobber := ma_defining(s.m, ma_);
    dest_loc := mloc_for_dest(m);
    dest_clobber := mssa_get_clobbering_access_for_loc(s.m, any_clobber, dest_loc, baa);
    if ma_is_def(s.m, dest_clobber) && !is_live_on_entry(dest_clobber) {
        mdep := s.m.acc[dest_clobber].inst;
        if is_memset_inst(mdep) && s.m.acc[dest_clobber].block == inst_block(m)
            if mco_process_memset_memcpy_dependence(s, m, mdep, baa) return true;
    }
    src_clobber := mssa_get_clobbering_access_for_loc(s.m, any_clobber, mloc_for_source(m), baa);
    if ma_is_def(s.m, src_clobber) {
        mi := s.m.acc[src_clobber].inst;
        if mi != NONE {
            len := call_arg(m, 2);
            if is_scalar_const_int(len) && inst_op(mi) == .CALL {
                if mco_perform_call_slot_optzn(s, m, m, mi_dest(m), mi_source(m), ap_zext_value(const_ap(len)), false,
                                               max(mi_param_align(m, 0), 1), baa, mi) {
                    mco_erase_instruction(s, m);
                    return true;
                }
            }
            if is_memcpy_inst(mi) && mco_process_memcpy_memcpy_dependence(s, m, mi, baa) return true;
            if is_memset_inst(mi) {
                if mco_perform_memcpy_to_memset_optzn(s, m, mi, baa) {
                    mco_erase_instruction(s, m);
                    return true;
                }
            }
        }
        if mco_has_undef_contents(s, mi_source(m), src_clobber) {
            mco_erase_instruction(s, m);
            return true;
        }
    }
    len := call_arg(m, 2);
    if !is_scalar_const_int(len) return false;
    if mco_perform_stack_move_optzn(s, m, m, mi_dest(m), mi_source(m), ap_zext_value(const_ap(len)), false, baa) {
        bbi.* = inst(m).next;
        mco_erase_instruction(s, m);
        return true;
    }
    return false;
}

// isMemMoveMemSetDependency
mco_is_memmove_memset_dependency :: (s: *Mco, m: Value_Id) -> bool {
    mma := mssa_access_of(s.m, m);
    if mma < 0 return false;
    source_loc := mloc_for_source(m);
    source := mi_source(m);
    if opr_code(source) != .GEP return false;
    w := dl_index_type_size_bits(vtype(source));
    off: u64 = 0;
    if op(source, 0) != mi_dest(m) || !ls_has_value(source_loc.size) || !sv_gep_accumulate_of(source, *off, w) return false;
    if w < 64 && ((off >> (w - 1)) & 1) != 0 return false;
    if w == 64 && cast,no_check(s64) off < 0 return false;
    mm_size := ls_value(source_loc.size);
    combined := mloc(mi_dest(m), ls_precise(off + mm_size));
    baa := aa_query_new(*s.aar);   // BatchAAResults BAA(*AA): no EEA
    first_def := ma_defining(s.m, mma);
    dc := mssa_get_clobbering_access_for_loc(s.m, first_def, combined, baa);
    if !ma_is_def(s.m, dc) || is_live_on_entry(dc) return false;
    ms := s.m.acc[dc].inst;
    if !is_memset_inst(ms) return false;
    ml := call_arg(ms, 2);
    if !is_scalar_const_int(ml) || ap_zext_value(const_ap(ml)) < off + mm_size return false;
    if !mco_is_must_alias(baa, mi_dest(ms), mi_dest(m)) return false;
    return true;
}

// processMemMove
mco_process_memmove :: (s: *Mco, m: Value_Id, bbi: *Value_Id) -> bool {
    if aa_mod_ref_inst_loc(mco_aa(s), m, mloc_for_source(m)) & MR_MOD {
        if !mi_is_volatile(m) && mco_is_memmove_memset_dependency(s, m) {
            bbi.* = inst(bbi.*).next;
            mco_erase_instruction(s, m);
            return true;
        }
        return false;
    }
    f := get_or_insert_intrinsic_declaration(IID_MEMCPY, .[vtype(call_arg(m, 0)), vtype(call_arg(m, 1)), vtype(call_arg(m, 2))]);
    set_op(m, nops(m) - 1, f);
    inst(m).ty2 = glob(f).value_type;
    return true;
}

// processByValArgument
mco_process_byval_argument :: (s: *Mco, cb: Value_Id, argno: u32) -> bool {
    byval_arg := call_arg(cb, argno);
    at := call_param_attr(cb, argno, .ByVal);
    byval_ty := at.ty;
    byval_size := dl_type_alloc_size(byval_ty);
    byval_sc := type_is_scalable(byval_ty);
    loc := mloc(byval_arg, ls_precise(byval_size, byval_sc));
    call_access := mssa_access_of(s.m, cb);
    if call_access < 0 return false;
    mdep: Value_Id = NONE;
    baa := mco_baa(s);
    clobber := mssa_get_clobbering_access_for_loc(s.m, ma_defining(s.m, call_access), loc, baa);
    if ma_is_def(s.m, clobber) && !is_live_on_entry(clobber) {
        x := s.m.acc[clobber].inst;
        if is_memcpy_inst(x) mdep = x;
    }
    if mdep == NONE || mi_is_volatile(mdep) || strip_pointer_casts(byval_arg) != mi_dest(mdep) return false;
    c1 := call_arg(mdep, 2);
    // TypeSize::isKnownGE(Fixed(C1), ByValSize): never for a scalable ByValSize
    if !is_scalar_const_int(c1) || byval_sc || ap_zext_value(const_ap(c1)) < byval_size return false;
    al := attr_set_find(attr_list_param(inst(cb).attrs, argno), .Alignment);
    if !al return false;
    byval_align := al.ival;
    mem_dep_align := mi_param_align(mdep, 1);
    if (mem_dep_align == 0 || mem_dep_align < byval_align) &&
       get_or_enforce_known_alignment(mi_source(mdep), byval_align, cb, s.ac, s.dt) < byval_align return false;
    if vtype(mi_source(mdep)) != vtype(byval_arg) return false;
    if mco_written_between(s, baa, mloc_for_source(mdep), mssa_access_of(s.m, mdep), call_access) return false;
    combine_aa_metadata(cb, mdep);
    set_op(cb, argno, mi_source(mdep));
    return true;
}

// processImmutArgument
mco_process_immut_argument :: (s: *Mco, cb: Value_Id, argno: u32) -> bool {
    baa := mco_baa(s);
    immut_arg := call_arg(cb, argno);
    if !call_does_not_capture(cb, argno) return false;
    if !call_param_has_attr(cb, argno, .NoAlias) && (aa_mod_ref_inst_loc(baa, cb, mloc_before_or_after(immut_arg)) & MR_MOD) != 0 return false;
    ai := strip_pointer_casts(immut_arg);
    if !is_inst(ai) || inst_op(ai) != .ALLOCA return false;
    ok, asize, sc := mco_alloca_size(ai);
    if !ok || sc return false;
    loc := mloc(immut_arg, ls_precise(asize));
    call_access := mssa_access_of(s.m, cb);
    if call_access < 0 return false;
    mdep: Value_Id = NONE;
    clobber := mssa_get_clobbering_access_for_loc(s.m, ma_defining(s.m, call_access), loc, baa);
    if ma_is_def(s.m, clobber) && !is_live_on_entry(clobber) {
        x := s.m.acc[clobber].inst;
        if is_memcpy_inst(x) mdep = x;
    }
    if mdep == NONE || mi_is_volatile(mdep) || ai != mi_dest(mdep) return false;
    if vtype(mi_source(mdep)) != vtype(immut_arg) return false;
    ml := call_arg(mdep, 2);
    if !is_scalar_const_int(ml) || ap_active_bits(const_ap(ml)) > 64 || asize != ap_zext_value(const_ap(ml)) return false;
    mem_dep_align := max(mi_param_align(mdep, 1), 1);
    alloca_align := inst(ai).align;
    if mem_dep_align < alloca_align &&
       get_or_enforce_known_alignment(mi_source(mdep), alloca_align, cb, s.ac, s.dt) < alloca_align return false;
    if mco_written_between(s, baa, mloc_for_source(mdep), mssa_access_of(s.m, mdep), call_access) return false;
    if aa_mod_ref_inst_loc(baa, cb, mloc_for_source(mdep)) & MR_MOD return false;
    combine_aa_metadata(cb, mdep);
    set_op(cb, argno, mi_source(mdep));
    return true;
}

// iterateOnFunction
mco_iterate_on_function :: (s: *Mco) -> bool {
    made_change := false;
    for bb: fn_blocks(s.f) {
        if !dt_is_reachable_from_entry(s.dt, bb) continue;
        bi := block(bb).first;
        while bi != NONE {
            i := bi;
            bi = inst(bi).next;
            repeat := false;
            if inst_op(i) == .STORE made_change |= mco_process_store(s, i, *bi);
            else if is_memset_inst(i) repeat = mco_process_memset(s, i, *bi);
            else if is_memcpy_inst(i) repeat = mco_process_memcpy(s, i, *bi);
            else if is_memmove_inst(i) repeat = mco_process_memmove(s, i, *bi);
            else if is_call_base(i) {
                n := call_num_args(i);
                if n > 0 for k: 0..n - 1 {
                    if call_is_byval_arg(i, k) made_change |= mco_process_byval_argument(s, i, k);
                    else if call_param_only_reads(i, k) made_change |= mco_process_immut_argument(s, i, k);
                }
            }
            if repeat {
                // if (BI != BB.begin()) --BI
                if bi == NONE bi = block(bb).last;
                else if bi != block(bb).first bi = inst(bi).prev;
                made_change = true;
            }
        }
    }
    return made_change;
}

// MemCpyOptPass::run
memcpyopt_run :: (f: Value_Id) -> Preserved {
    s: Mco;
    s.f = f;
    s.tli = tli_for(f);
    s.aar = aa_results_for(f);
    s.ac = get_assumption_cache(f);
    s.dt = get_domtree(f);
    s.pdt = get_postdomtree(f);
    s.m = get_memoryssa(f);
    s.dt = get_domtree(f);
    s.u.mssa = s.m;
    s.ee = aa_query_new_earliest_escape(*s.aar, s.dt);
    made_change := false;
    while true {
        if !mco_iterate_on_function(*s) break;
        made_change = true;
    }
    if mssa_opts.verify mssa_verify(s.m);
    if !made_change return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .MEMORYSSA);
    return pa;
}
