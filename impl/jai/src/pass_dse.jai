// DeadStoreElimination: a port of llvm/lib/Transforms/Scalar/DeadStoreElimination.cpp (MemorySSA-based DSEState:
// getDomMemoryDef, isOverwrite / isPartialOverwrite with OverlapIntervals, partial store merging, shortening of
// memory intrinsics, calloc / alloc-variant-zeroed folding, no-op stores, redundant stores of existing values and via
// dominating conditions, dead writes at the end of the function, the `initializes` attribute; the dse cl::opts).
//
// Data-oriented: one Dse state per run; MemoryDefs are MemorySSA access rows (s32); LLVM's pointer sets and maps are
// Tables keyed by ids (ids are never reused, so the "reused MemoryAccess address" caveats of the LLVM code don't
// apply). InstOverlapIntervalsTy (MapVector<Instruction *, std::map<int64_t, int64_t>>) is an insertion-ordered
// array of entries, each with its interval map as an array sorted by the interval end.
// Not ported (fail loudly): assignment tracking (shortenAssignment's dbg.assign updates; #dbg_assign does not parse),
// salvageKnowledge (-enable-knowledge-retention is not an accepted flag), -debug-counter.

dse_opts: struct {
    enable_partial_overwrite_tracking := true;   // -enable-dse-partial-overwrite-tracking
    enable_partial_store_merging := true;        // -enable-dse-partial-store-merging
    scan_limit: s64 = 150;                       // -dse-memoryssa-scanlimit
    walk_limit: s64 = 90;                        // -dse-memoryssa-walklimit
    partial_store_limit: s64 = 5;                // -dse-memoryssa-partial-store-limit
    defs_per_block_limit: s64 = 5000;            // -dse-memoryssa-defs-per-block-limit
    same_bb_step_cost: s64 = 1;                  // -dse-memoryssa-samebb-cost
    other_bb_step_cost: s64 = 5;                 // -dse-memoryssa-otherbb-cost
    path_check_limit: s64 = 50;                  // -dse-memoryssa-path-check-limit
    optimize_memoryssa := true;                  // -dse-optimize-memoryssa
    enable_initializes_improvement := true;      // -enable-dse-initializes-attr-improvement
    max_depth_recursion: s64 = 1024;             // -dse-max-dom-cond-depth
};
DSE_CL_OPT_COUNT :: 12;
add_dse_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"enable-dse-partial-overwrite-tracking", .BOOL, *dse_opts.enable_partial_overwrite_tracking, null, null};
    list[start + 1] = .{"enable-dse-partial-store-merging", .BOOL, *dse_opts.enable_partial_store_merging, null, null};
    list[start + 2] = .{"dse-memoryssa-scanlimit", .INT, null, *dse_opts.scan_limit, null};
    list[start + 3] = .{"dse-memoryssa-walklimit", .INT, null, *dse_opts.walk_limit, null};
    list[start + 4] = .{"dse-memoryssa-partial-store-limit", .INT, null, *dse_opts.partial_store_limit, null};
    list[start + 5] = .{"dse-memoryssa-defs-per-block-limit", .INT, null, *dse_opts.defs_per_block_limit, null};
    list[start + 6] = .{"dse-memoryssa-samebb-cost", .INT, null, *dse_opts.same_bb_step_cost, null};
    list[start + 7] = .{"dse-memoryssa-otherbb-cost", .INT, null, *dse_opts.other_bb_step_cost, null};
    list[start + 8] = .{"dse-memoryssa-path-check-limit", .INT, null, *dse_opts.path_check_limit, null};
    list[start + 9] = .{"dse-optimize-memoryssa", .BOOL, *dse_opts.optimize_memoryssa, null, null};
    list[start + 10] = .{"enable-dse-initializes-attr-improvement", .BOOL, *dse_opts.enable_initializes_improvement, null, null};
    list[start + 11] = .{"dse-max-dom-cond-depth", .INT, null, *dse_opts.max_depth_recursion, null};
}

IID_VP_STORE :: #run iid_by_name("llvm.vp.store");
IID_LIFETIME_END_DSE :: #run iid_by_name("llvm.lifetime.end");

// ---------------------------------------------------------------- memory intrinsic classes (IntrinsicInst.h)

// AnyMemIntrinsic
is_any_mem_intrinsic :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .CALL return false;
    id := call_iid(i);
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMSET_INLINE ||
           id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC ||
           id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
// MemIntrinsic (memcpy, memmove, memset, memset.inline, memcpy.inline)
is_mem_intrinsic_inst :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .CALL return false;
    id := call_iid(i);
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMSET_INLINE;
}
// AnyMemSetInst
is_any_mem_set_inst :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .CALL return false;
    id := call_iid(i);
    return id == IID_MEMSET || id == IID_MEMSET_INLINE || id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
// MemSetInst
is_memset_inst :: (i: Value_Id) -> bool { return is_inst(i) && inst_op(i) == .CALL && is_mem_set_inst(i); }
// AnyMemIntrinsic::isAtomic
any_mem_is_atomic :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC ||
           id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
// MemIntrinsicBase::setDestAlignment
mi_set_param_alignment :: (i: Value_Id, k: u32, align: u64) {
    call_remove_param_attr(i, k, .Alignment);
    if align add_param_align(i, k, align);
}

// ---------------------------------------------------------------- helpers

dse_is_shortenable_at_the_end :: (i: Value_Id) -> bool {
    if inst_op(i) == .STORE return false;
    if inst_op(i) == .CALL {
        id := call_iid(i);
        return id == IID_MEMSET || id == IID_MEMCPY || id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC ||
               id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
    }
    return false;
}
dse_is_shortenable_at_the_beginning :: (i: Value_Id) -> bool { return is_any_mem_set_inst(i); }

dse_get_pointer_size :: (v: Value_Id, f: Value_Id) -> (bool, u64) {
    opts: Os_Opts;
    opts.null_is_unknown_size = null_pointer_is_defined(f);
    ok, sz := get_object_size(v, opts);
    return ok, sz;
}

Dse_Ow :: enum u8 { BEGIN; COMPLETE; END; PARTIAL_EARLIER_WITH_FULL_LATER; MAYBE_PARTIAL; NONE; UNKNOWN; }

// isMaskedStoreOverwrite
dse_is_masked_store_overwrite :: (killing_i: Value_Id, dead_i: Value_Id, q: *Aa_Query) -> Dse_Ow {
    if inst_op(killing_i) != .CALL || inst_op(dead_i) != .CALL return .UNKNOWN;
    kid := call_iid(killing_i); did := call_iid(dead_i);
    if kid == NOT_INTRINSIC || did == NOT_INTRINSIC || kid != did return .UNKNOWN;
    if kid != IID_MASKED_STORE && kid != IID_VP_STORE return .UNKNOWN;
    kty := vtype(call_arg(killing_i, 0)); dty := vtype(call_arg(dead_i, 0));
    if dl_type_size_bits(kty) != dl_type_size_bits(dty) || type_is_scalable(kty) != type_is_scalable(dty) return .UNKNOWN;
    if type_count(kty) != type_count(dty) || (type_kind(kty) == .SVECTOR) != (type_kind(dty) == .SVECTOR) return .UNKNOWN;
    kp := call_arg(killing_i, 1); dp := call_arg(dead_i, 1);
    if kp != dp && aa_alias(q, mloc_before_or_after(kp), mloc_before_or_after(dp)).kind != AR_MUST return .UNKNOWN;
    if call_arg(killing_i, 2) != call_arg(dead_i, 2) return .UNKNOWN;
    if kid == IID_VP_STORE && call_arg(killing_i, 3) != call_arg(dead_i, 3) return .UNKNOWN;
    return .COMPLETE;
}

Dse_Interval :: struct { end: s64; start: s64; }       // std::map<end, start>
Dse_Iol_Entry :: struct { inst: Value_Id; map: [..] Dse_Interval; }
Dse_Iol :: struct { bb: Value_Id; entries: [..] Dse_Iol_Entry; }   // InstOverlapIntervalsTy of one block

dse_iol_entry :: (iol: *Dse_Iol, i: Value_Id) -> *Dse_Iol_Entry {
    for * iol.entries if it.inst == i return it;
    e: Dse_Iol_Entry; e.inst = i; e.map.allocator = temp;
    array_add(*iol.entries, e);
    return *iol.entries[iol.entries.count - 1];
}
dse_iol_erase :: (iol: *Dse_Iol, i: Value_Id) {
    for iol.entries if it.inst == i { array_ordered_remove_by_index(*iol.entries, it_index); return; }
}

// isPartialOverwrite
dse_is_partial_overwrite :: (killing_loc: Mem_Loc, dead_loc: Mem_Loc, killing_off: s64, dead_off: s64, dead_i: Value_Id, iol: *Dse_Iol) -> Dse_Ow {
    killing_size := ls_value(killing_loc.size);
    dead_size := ls_value(dead_loc.size);
    dead_end := cast,no_check(s64)(cast,no_check(u64) dead_off + dead_size);
    killing_end := cast,no_check(s64)(cast,no_check(u64) killing_off + killing_size);
    if dse_opts.enable_partial_overwrite_tracking && killing_off < dead_end && killing_end >= dead_off {
        im := *dse_iol_entry(iol, dead_i).map;
        ks := killing_off; ke := killing_end;
        // lower_bound(ks): first interval whose end >= ks
        k := 0;
        while k < im.count && im.*[k].end < ks k += 1;
        if k < im.count && im.*[k].start <= ke {
            ks = min(ks, im.*[k].start);
            ke = max(ke, im.*[k].end);
            array_ordered_remove_by_index(im, k);
            while k < im.count && im.*[k].start <= ke {
                ke = max(ke, im.*[k].end);
                array_ordered_remove_by_index(im, k);
            }
        }
        // IM[ke] = ks
        p := 0;
        while p < im.count && im.*[p].end < ke p += 1;
        if p < im.count && im.*[p].end == ke im.*[p].start = ks;
        else array_insert_at(im, .{ke, ks}, p);
        first := im.*[0];
        if first.start <= dead_off && first.end >= dead_end return .COMPLETE;
    }
    if dse_opts.enable_partial_store_merging && killing_off >= dead_off && dead_end > killing_off &&
       cast,no_check(u64)(killing_off - dead_off) + killing_size <= dead_size
        return .PARTIAL_EARLIER_WITH_FULL_LATER;
    if !dse_opts.enable_partial_overwrite_tracking && killing_off > dead_off && killing_off < dead_end && killing_end >= dead_end
        return .END;
    if !dse_opts.enable_partial_overwrite_tracking && killing_off <= dead_off && killing_end > dead_off
        return .BEGIN;
    return .UNKNOWN;
}

// memoryIsNotModifiedBetween
dse_memory_is_not_modified_between :: (first_i: Value_Id, second_i: Value_Id, q: *Aa_Query, dt: *Dom_Tree) -> bool {
    Work :: struct { bb: Value_Id; addr: Phi_Trans_Addr; }
    worklist: [..] Work; worklist.allocator = temp;
    visited: Table(Value_Id, Value_Id); visited.allocator = temp;
    first_bb := inst_block(first_i);
    second_bb := inst_block(second_i);
    loc: Mem_Loc;
    if is_memset_inst(second_i) loc = mloc_for_dest(second_i);
    else loc = mloc_get(second_i);
    array_add(*worklist, .{second_bb, pta_make(loc.ptr, null)});
    is_first_block := true;
    preds: [..] Value_Id; preds.allocator = temp;
    while worklist.count {
        cur := pop(*worklist);
        b := cur.bb;
        ptr := cur.addr.addr;
        bi := ifx b == first_bb then inst(first_i).next else block(b).first;
        ei: Value_Id = NONE;
        if is_first_block { ei = second_i; is_first_block = false; }
        x := bi;
        while x != ei && x != NONE {
            if may_write_to_memory(x) && x != second_i {
                l := loc; l.ptr = ptr;
                if aa_mod_ref_inst_loc(q, x, l) & MR_MOD return false;
            }
            x = inst(x).next;
        }
        if b != first_bb {
            block_predecessors(b, *preds);
            for pred: preds {
                pa := pta_copy(cur.addr);
                if pta_needs_phi_translation_from_block(*pa, b) {
                    if !pta_is_potentially_phi_translatable(*pa) return false;
                    if pta_translate_value(*pa, b, pred, dt, false) == NONE return false;
                }
                tp := pa.addr;
                found, prev := table_find(*visited, pred);
                if found {
                    if tp != prev return false;
                    continue;
                }
                table_set(*visited, pred, tp);
                array_add(*worklist, .{pred, pa});
            }
        }
    }
    return true;
}

// adjustArgAttributes
dse_adjust_arg_attributes :: (mi: Value_Id, argno: u32, ptr_offset: u64) {
    old := call_param_attr_set(mi, argno);
    keep: [..] Attr; keep.allocator = temp;
    for attr_set_items(old) {
        if it.kind == .Alignment && (ptr_offset % it.ival) == 0 { array_add(*keep, it); continue; }
        if it.kind == .NonNull || it.kind == .NoUndef { array_add(*keep, it); continue; }
    }
    call_set_param_attr_set(mi, argno, attr_set_get(keep));
}

// tryToShorten
dse_try_to_shorten :: (dead_i: Value_Id, dead_start: *s64, dead_size: *u64, killing_start: s64, killing_size: u64, is_overwrite_end: bool) -> bool {
    pref_align := mi_param_align(dead_i, 0);
    if pref_align == 0 pref_align = 1;
    to_remove_start: s64 = 0;
    to_remove_size: u64 = 0;
    offset_to_alignment :: (v: u64, a: u64) -> u64 { return (a - (v % a)) % a; }
    if is_overwrite_end {
        off := offset_to_alignment(cast,no_check(u64)(killing_start - dead_start.*), pref_align);
        to_remove_start = killing_start + cast,no_check(s64) off;
        if dead_size.* <= cast,no_check(u64)(to_remove_start - dead_start.*) return false;
        to_remove_size = dead_size.* - cast,no_check(u64)(to_remove_start - dead_start.*);
    } else {
        to_remove_start = dead_start.*;
        to_remove_size = killing_size - cast,no_check(u64)(dead_start.* - killing_start);
        off := offset_to_alignment(to_remove_size, pref_align);
        if off != 0 {
            if to_remove_size <= pref_align - off return false;
            to_remove_size -= pref_align - off;
        }
    }
    new_size := dead_size.* - to_remove_size;
    if any_mem_is_atomic(dead_i) {
        es := ap_zext_value(const_ap(call_arg(dead_i, 3)));
        if new_size % es != 0 return false;
    }
    len_ty := vtype(call_arg(dead_i, 2));
    set_op(dead_i, 2, const_int(len_ty, new_size));
    mi_set_param_alignment(dead_i, 0, pref_align);
    orig_dest := call_arg(dead_i, 0);
    if !is_overwrite_end {
        g := new_inst(.GEP, vtype(orig_dest), 2);
        inst(g).ty2 = ir.t_i8;
        inst(g).flags |= F_INBOUNDS;
        set_op(g, 0, orig_dest);
        set_op(g, 1, const_int(len_ty, to_remove_size));
        insert_at_position(g, inst_block(dead_i), dead_i, false);
        d := get_metadata(dead_i, 0);
        set_metadata(g, 0, d);
        set_op(dead_i, 0, g);
        dse_adjust_arg_attributes(dead_i, 0, to_remove_size);
    }
    // shortenAssignment: dbg.assign markers (assignment tracking does not parse)
    if !is_overwrite_end dead_start.* += cast,no_check(s64) to_remove_size;
    dead_size.* = new_size;
    return true;
}

dse_try_to_shorten_end :: (dead_i: Value_Id, im: *[..] Dse_Interval, dead_start: *s64, dead_size: *u64) -> bool {
    if im.count == 0 || !dse_is_shortenable_at_the_end(dead_i) return false;
    last := im.*[im.count - 1];
    ks := last.start;
    ksize := cast,no_check(u64)(last.end - ks);
    if ks > dead_start.* && cast,no_check(u64)(ks - dead_start.*) < dead_size.* &&
       ksize >= dead_size.* - cast,no_check(u64)(ks - dead_start.*) {
        if dse_try_to_shorten(dead_i, dead_start, dead_size, ks, ksize, true) {
            im.count -= 1;
            return true;
        }
    }
    return false;
}
dse_try_to_shorten_begin :: (dead_i: Value_Id, im: *[..] Dse_Interval, dead_start: *s64, dead_size: *u64) -> bool {
    if im.count == 0 || !dse_is_shortenable_at_the_beginning(dead_i) return false;
    first := im.*[0];
    ks := first.start;
    ksize := cast,no_check(u64)(first.end - ks);
    if ks <= dead_start.* && ksize > cast,no_check(u64)(dead_start.* - ks) {
        if dse_try_to_shorten(dead_i, dead_start, dead_size, ks, ksize, false) {
            array_ordered_remove_by_index(im, 0);
            return true;
        }
    }
    return false;
}

// tryToMergePartialOverlappingStores
dse_try_to_merge_partial_overlapping_stores :: (killing_i: Value_Id, dead_i: Value_Id, killing_off: s64, dead_off: s64, q: *Aa_Query, dt: *Dom_Tree) -> Value_Id {
    dv := op(dead_i, 0); kv := op(killing_i, 0);
    if !is_scalar_const_int(dv) || !dl_type_size_equals_store_size(vtype(dv)) ||
       !is_scalar_const_int(kv) || !dl_type_size_equals_store_size(vtype(kv)) ||
       !dse_memory_is_not_modified_between(dead_i, killing_i, q, dt) return NONE;
    if !is_unordered(killing_i) || !is_unordered(dead_i) || inst(killing_i).ord1 != inst(dead_i).ord1 return NONE;
    dval := const_ap(dv);
    kval := const_ap(kv);
    kbits := kval.bits;
    kval = ap_zext(kval, dval.bits);
    bit_off := cast(u32)((killing_off - dead_off) * 8);
    lshift := ifx dl.big_endian then dval.bits - bit_off - kbits else bit_off;
    mask := ap_bits_set(dval.bits, lshift, lshift + kbits);
    merged := ap_or(ap_and(dval, ap_not(mask)), ap_shl(kval, lshift));
    return const_int_ap(vtype(dv), merged);
}

// isNoopIntrinsic
dse_is_noop_intrinsic :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    id := call_iid(i);
    return id == IID_LIFETIME_START || id == IID_LIFETIME_END_DSE || id == IID_INVARIANT_END ||
           id == IID_LAUNDER_INVARIANT_GROUP || id == IID_ASSUME;
}
// CallBase::onlyAccessesInaccessibleMemory
call_only_accesses_inaccessible_memory :: (i: Value_Id) -> bool {
    return me_without_loc(call_memory_effects(i), LOC_INACCESSIBLE) == 0;
}
// CallBase::onlyAccessesInaccessibleMemOrArgMem
call_only_accesses_inaccessible_mem_or_arg_mem :: (i: Value_Id) -> bool {
    return me_without_loc(me_without_loc(call_memory_effects(i), LOC_INACCESSIBLE), LOC_ARG) == 0;
}

// canSkipDef
dse_can_skip_def :: (m: *Memory_SSA, d: s32, def_visible_to_caller: bool) -> bool {
    di := m.acc[d].inst;
    if is_call_base(di) && call_only_accesses_inaccessible_memory(di) return true;
    if may_throw(di) && !def_visible_to_caller return true;
    if inst_op(di) == .FENCE return true;
    if dse_is_noop_intrinsic(di) return true;
    return false;
}

// a MemoryLocationWrapper
Dse_Loc :: struct {
    loc: Mem_Loc;
    und_obj: Value_Id;
    def: s32;
    inst: Value_Id;
    by_initializes: bool;
}

// ---------------------------------------------------------------- DSEState

Dse :: struct {
    f: Value_Id;
    aar: Aa_Results;
    q: *Aa_Query;             // BatchAA with EarliestEscapeAnalysis(DT, nullptr, &CI)
    m: *Memory_SSA;
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    ci: *Cycle_Info;
    tli: *Tli;
    mem_defs: [..] s32;
    skip_stores: Table(s32, bool);
    captured_before_return: Table(Value_Id, bool);
    invisible_after_ret: Table(Value_Id, bool);
    invisible_after_ret_bounded: Table(Value_Id, u64);
    throwing_blocks: Table(Value_Id, bool);
    po: Table(Value_Id, u32);
    iols: [..] Dse_Iol;
    any_unreachable_exit: bool;
    should_iterate_eof: bool;
    to_remove: [..] Value_Id;
}

dse_po :: (s: *Dse, b: Value_Id) -> u32 { found, n := table_find(*s.po, b); return n; }

dse_iols_for :: (s: *Dse, bb: Value_Id) -> *Dse_Iol {
    for * s.iols if it.bb == bb return it;
    x: Dse_Iol; x.bb = bb; x.entries.allocator = temp;
    array_add(*s.iols, x);
    return *s.iols[s.iols.count - 1];
}
dse_iols_find :: (s: *Dse, bb: Value_Id) -> *Dse_Iol {
    for * s.iols if it.bb == bb return it;
    return null;
}

// getLocForWrite
dse_get_loc_for_write :: (s: *Dse, i: Value_Id) -> (bool, Mem_Loc) {
    if !may_write_to_memory(i) return false, .{};
    if is_call_base(i) { ok, l := mloc_for_dest_call(i); return ok, l; }
    ok, l := mloc_get_or_none(i);
    return ok, l;
}
// isMemTerminatorInst
dse_is_mem_terminator_inst :: (s: *Dse, i: Value_Id) -> bool {
    if !is_call_base(i) return false;
    return call_iid(i) == IID_LIFETIME_END_DSE || get_freed_operand(i) != NONE;
}
// getLocForTerminator: (ok, loc, is_free)
dse_get_loc_for_terminator :: (s: *Dse, i: Value_Id) -> (bool, Mem_Loc, bool) {
    if is_call_base(i) {
        if call_iid(i) == IID_LIFETIME_END_DSE return true, mloc_for_argument(i, 0, true), false;
        fo := get_freed_operand(i);
        if fo != NONE return true, mloc_after(fo), true;
    }
    return false, .{}, false;
}
call_has_initializes_attr :: (i: Value_Id) -> bool {
    if !is_call_base(i) return false;
    n := call_num_args(i);
    if n > 0 for k: 0..n-1 if call_param_has_attr(i, k, .Initializes) return true;
    return false;
}

dse_init :: (s: *Dse, f: Value_Id) {
    s.f = f;
    s.aar = aa_results_for(f);
    s.tli = tli_for(f);
    s.dt = get_domtree(f);
    s.m = get_memoryssa(f);
    s.pdt = get_postdomtree(f);
    s.ci = get_cycle_info(f);
    s.dt = get_domtree(f);
    s.q = aa_query_new_earliest_escape(*s.aar, s.dt);
    s.q.ee_ci = s.ci;
    s.mem_defs.allocator = temp; s.skip_stores.allocator = temp; s.captured_before_return.allocator = temp;
    s.invisible_after_ret.allocator = temp; s.invisible_after_ret_bounded.allocator = temp;
    s.throwing_blocks.allocator = temp; s.po.allocator = temp; s.iols.allocator = temp; s.to_remove.allocator = temp;
    order: [..] Value_Id; order.allocator = temp;
    cfg_post_order(fn_entry(f), *order);
    for bb, n: order {
        table_set(*s.po, bb, cast(u32) n);
        for i: block_insts(bb) {
            a := mssa_access_of(s.m, i);
            if may_throw(i) && a < 0 table_set(*s.throwing_blocks, bb, true);
            if a >= 0 && ma_is_def(s.m, a) && s.mem_defs.count < dse_opts.defs_per_block_limit {
                ok := dse_get_loc_for_write(s, i);
                if ok || dse_is_mem_terminator_inst(s, i) || (dse_opts.enable_initializes_improvement && call_has_initializes_attr(i))
                    array_add(*s.mem_defs, a);
            }
        }
    }
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        if arg_has_pass_pointee_by_value_copy(a) { table_set(*s.invisible_after_ret, a, true); continue; }
        if !is_ptr_type(vtype(a)) continue;
        at := attr_set_find(arg_attrs(a), .DeadOnReturn);
        if at {
            if at.ival == 0xFFFF_FFFF_FFFF_FFFF table_set(*s.invisible_after_ret, a, true);
            else if at.ival != 0 table_set(*s.invisible_after_ret_bounded, a, at.ival);
        }
    }
    s.any_unreachable_exit = false;
    for s.pdt.roots if inst_op(block_terminator(it)) == .UNREACHABLE { s.any_unreachable_exit = true; break; }
}

// strengthenLocationSize
dse_strengthen_location_size :: (s: *Dse, i: Value_Id, size: u64) -> u64 {
    if is_call_base(i) {
        lf := tli_lib_func_of_call(i);
        if lf == "__memset_chk" || lf == "__memcpy_chk" {
            len := call_arg(i, 2);
            if vkind(len) == .C_INT return ls_precise(ap_zext_value(const_ap(len)));
        }
    }
    return size;
}

// isOverwrite: (result, KillingOff, DeadOff)
dse_is_overwrite :: (s: *Dse, killing_i: Value_Id, dead_i: Value_Id, killing_loc: Mem_Loc, dead_loc: Mem_Loc) -> (Dse_Ow, s64, s64) {
    if !dse_is_guaranteed_loop_independent(s, dead_i, killing_i, dead_loc) return .UNKNOWN, 0, 0;
    ksize := dse_strengthen_location_size(s, killing_i, killing_loc.size);
    dead_ptr := strip_pointer_casts(dead_loc.ptr);
    killing_ptr := strip_pointer_casts(killing_loc.ptr);
    dead_uo := get_underlying_object(dead_ptr);
    killing_uo := get_underlying_object(killing_ptr);
    if dead_uo == killing_uo && ls_has_value(ksize) && ls_is_precise(ksize) && is_identified_object(killing_uo) {
        ok, sz := dse_get_pointer_size(killing_uo, s.f);
        if ok && !ls_is_scalable(ksize) && sz == ls_value(ksize) return .COMPLETE, 0, 0;
    }
    k_precise := ls_has_value(ksize) && ls_is_precise(ksize);
    d_precise := ls_has_value(dead_loc.size) && ls_is_precise(dead_loc.size);
    if !k_precise || !d_precise {
        if is_mem_intrinsic_inst(killing_i) && is_mem_intrinsic_inst(dead_i) {
            if call_arg(killing_i, 2) == call_arg(dead_i, 2) && aa_alias(s.q, dead_loc, killing_loc).kind == AR_MUST
                return .COMPLETE, 0, 0;
        }
        return dse_is_masked_store_overwrite(killing_i, dead_i, s.q), 0, 0;
    }
    if ls_is_scalable(dead_loc.size) || ls_is_scalable(ksize) return .UNKNOWN, 0, 0;
    killing_size := ls_value(ksize);
    dead_size := ls_value(dead_loc.size);
    aar := aa_alias(s.q, killing_loc, dead_loc);
    if aar.kind == AR_MUST && killing_size >= dead_size return .COMPLETE, 0, 0;
    if aar.kind == AR_PARTIAL && aar.has_offset {
        off := aar.offset;
        if off >= 0 && cast(u64) off + dead_size <= killing_size return .COMPLETE, 0, 0;
    }
    if dead_uo != killing_uo {
        if aar.kind == AR_NO return .NONE, 0, 0;
        return .UNKNOWN, 0, 0;
    }
    dead_base, dead_off := get_pointer_base_with_constant_offset(dead_ptr);
    killing_base, killing_off := get_pointer_base_with_constant_offset(killing_ptr);
    if dead_base != killing_base return .UNKNOWN, killing_off, dead_off;
    if dead_off >= killing_off {
        if cast,no_check(u64)(dead_off - killing_off) + dead_size <= killing_size return .COMPLETE, killing_off, dead_off;
        else if cast,no_check(u64)(dead_off - killing_off) < killing_size return .MAYBE_PARTIAL, killing_off, dead_off;
    } else if cast,no_check(u64)(killing_off - dead_off) < dead_size {
        return .MAYBE_PARTIAL, killing_off, dead_off;
    }
    return .NONE, killing_off, dead_off;
}

// isInvisibleToCallerAfterRet
dse_is_invisible_to_caller_after_ret :: (s: *Dse, v: Value_Id, ptr: Value_Id, store_size: u64) -> bool {
    if is_inst(v) && inst_op(v) == .ALLOCA return true;
    found, bytes := table_find(*s.invisible_after_ret_bounded, v);
    if found {
        base, off := get_pointer_base_with_constant_offset(ptr);
        if base != v return false;
        if ls_has_value(store_size) && cast,no_check(u64) off + ls_value(store_size) <= bytes && off >= 0 return true;
    }
    p := table_find_pointer(*s.invisible_after_ret, v);
    if p return p.*;
    r := false;
    if dse_is_invisible_to_caller_on_unwind(s, v) && aa_is_no_alias_call(v) {
        _, with_ret := pointer_may_be_captured(v, CC_PROVENANCE, .FULL_PROVENANCE);
        r = with_ret == CC_NONE;
    }
    table_set(*s.invisible_after_ret, v, r);
    return r;
}

// isInvisibleToCallerOnUnwind
dse_is_invisible_to_caller_on_unwind :: (s: *Dse, v: Value_Id) -> bool {
    ok, requires_no_capture := is_not_visible_on_unwind(v);
    if !ok return false;
    if !requires_no_capture return true;
    p := table_find_pointer(*s.captured_before_return, v);
    if !p {
        without_ret, _ := pointer_may_be_captured(v, CC_PROVENANCE, .FULL_PROVENANCE);
        table_set(*s.captured_before_return, v, without_ret != CC_NONE);
        p = table_find_pointer(*s.captured_before_return, v);
    }
    return !p.*;
}

// getLocForInst: a list of (location, from initializes)
dse_get_loc_for_inst :: (s: *Dse, i: Value_Id, consider_initializes: bool, out: *[..] Dse_Loc, def: s32) {
    add :: (s: *Dse, out: *[..] Dse_Loc, loc: Mem_Loc, def: s32, by_init: bool) {
        w: Dse_Loc; w.loc = loc; w.def = def; w.by_initializes = by_init;
        w.und_obj = get_underlying_object(loc.ptr);
        w.inst = s.m.acc[def].inst;
        array_add(out, w);
    }
    if dse_is_mem_terminator_inst(s, i) {
        ok, loc := dse_get_loc_for_terminator(s, i);
        if ok add(s, out, loc, def, false);
        return;
    }
    ok, loc := dse_get_loc_for_write(s, i);
    if ok add(s, out, loc, def, false);
    if consider_initializes {
        locs: [..] Mem_Loc; locs.allocator = temp;
        dse_get_initializes_arg_mem_loc(s, i, *locs);
        for locs add(s, out, it, def, true);
    }
}

// isRemovable
dse_is_removable :: (s: *Dse, i: Value_Id) -> bool {
    if inst_op(i) == .STORE return is_unordered(i);
    if is_call_base(i) {
        if is_mem_intrinsic_inst(i) return !mi_is_volatile(i);
        id := call_iid(i);
        if id == IID_LIFETIME_START || id == IID_LIFETIME_END_DSE return false;
        return !has_uses(i) && will_return(i) && call_does_not_throw(i) && inst_op(i) == .CALL;
    }
    return false;
}

// isCompleteOverwrite
dse_is_complete_overwrite :: (s: *Dse, def_loc: Mem_Loc, def_inst: Value_Id, use_inst: Value_Id) -> bool {
    if !may_write_to_memory(use_inst) return false;
    if is_call_base(use_inst) && call_only_accesses_inaccessible_memory(use_inst) return false;
    ok, cc := dse_get_loc_for_write(s, use_inst);
    if ok {
        r := dse_is_overwrite(s, use_inst, def_inst, cc, def_loc);
        return r == .COMPLETE;
    }
    return false;
}

dse_push_mem_uses :: (m: *Memory_SSA, a: s32, worklist: *[..] s32, visited: *Table(s32, bool)) {
    u := m.acc[a].first_use;
    while u >= 0 {
        usr := m.uses[u].user;
        if !table_contains(visited, usr) { table_set(visited, usr, true); array_add(worklist, usr); }
        u = m.uses[u].next;
    }
}

// isWriteAtEndOfFunction
dse_is_write_at_end_of_function :: (s: *Dse, def: s32, def_loc: Mem_Loc) -> bool {
    worklist: [..] s32; worklist.allocator = temp;
    visited: Table(s32, bool); visited.allocator = temp;
    dse_push_mem_uses(s.m, def, *worklist, *visited);
    i := 0;
    while i < worklist.count {
        defer i += 1;
        if worklist.count >= dse_opts.scan_limit return false;
        ua := worklist[i];
        if ma_is_phi(s.m, ua) {
            if !dse_is_guaranteed_loop_invariant(s, def_loc.ptr) return false;
            dse_push_mem_uses(s.m, ua, *worklist, *visited);
            continue;
        }
        use_inst := s.m.acc[ua].inst;
        if dse_is_read_clobber(s, def_loc, use_inst) return false;
        if ma_is_def(s.m, ua) dse_push_mem_uses(s.m, ua, *worklist, *visited);
    }
    return true;
}

// isMemTerminator
dse_is_mem_terminator :: (s: *Dse, loc: Mem_Loc, access_i: Value_Id, maybe_term: Value_Id) -> bool {
    ok, term_loc, is_free := dse_get_loc_for_terminator(s, maybe_term);
    if !ok return false;
    if get_underlying_object(loc.ptr) != get_underlying_object(term_loc.ptr) return false;
    if is_free {
        loc_uo := get_underlying_object(loc.ptr);
        return aa_alias(s.q, mloc_before_or_after(term_loc.ptr), mloc_before_or_after(loc_uo)).kind == AR_MUST;
    }
    r := dse_is_overwrite(s, maybe_term, access_i, term_loc, loc);
    return r == .COMPLETE;
}

// isReadClobber
dse_is_read_clobber :: (s: *Dse, def_loc: Mem_Loc, use_inst: Value_Id) -> bool {
    if dse_is_noop_intrinsic(use_inst) return false;
    if inst_op(use_inst) == .STORE return is_stronger_than_monotonic(inst(use_inst).ord1);
    if !may_read_from_memory(use_inst) return false;
    if is_call_base(use_inst) && call_only_accesses_inaccessible_memory(use_inst) return false;
    return (aa_mod_ref_inst_loc(s.q, use_inst, def_loc) & MR_REF) != 0;
}

// isGuaranteedLoopIndependent
dse_is_guaranteed_loop_independent :: (s: *Dse, current: Value_Id, killing_def: Value_Id, current_loc: Mem_Loc) -> bool {
    if inst_block(current) == inst_block(killing_def) return true;
    cc := ci_cycle_for(s.ci, inst_block(current));
    if cc != NONE && cc == ci_cycle_for(s.ci, inst_block(killing_def)) return true;
    return dse_is_guaranteed_loop_invariant(s, current_loc.ptr);
}
// isGuaranteedLoopInvariant
dse_is_guaranteed_loop_invariant :: (s: *Dse, ptr_in: Value_Id) -> bool {
    ptr := strip_pointer_casts(ptr_in);
    if opr_code(ptr) == .GEP && gep_has_all_constant_indices(ptr) ptr = strip_pointer_casts(op(ptr, 0));
    if is_inst(ptr) {
        b := inst_block(ptr);
        return b == fn_entry(s.f) || ci_cycle_for(s.ci, b) == NONE;
    }
    return true;
}

// getDomMemoryDef: (found, access)
dse_get_dom_memory_def :: (s: *Dse, killing_def: s32, start_access: s32, killing_loc: Mem_Loc, killing_und_obj: Value_Id,
                           scan_limit: *s64, walker_step_limit: *s64, is_mem_term: bool, partial_limit: *s64,
                           is_initializes_attr_mem_loc: bool) -> (bool, s32) {
    m := s.m;
    if scan_limit.* == 0 || walker_step_limit.* == 0 return false, -1;
    current := start_access;
    killing_i := m.acc[killing_def].inst;
    can_optimize := dse_opts.optimize_memoryssa && ma_defining(m, killing_def) == start_access && !may_read_from_memory(killing_i);
    current_loc: Mem_Loc;
    users: [..] s32; users.allocator = temp;
    first := true;
    while true {
        if !first current = ma_defining(m, current);
        first = false;
        if is_live_on_entry(current) {
            if can_optimize && current != ma_defining(m, killing_def) ma_set_optimized(m, killing_def, current);
            return false, -1;
        }
        step_cost := ifx m.acc[killing_def].block == m.acc[current].block then dse_opts.same_bb_step_cost else dse_opts.other_bb_step_cost;
        if walker_step_limit.* <= step_cost return false, -1;
        walker_step_limit.* -= step_cost;
        if ma_is_phi(m, current) return true, current;
        current_i := m.acc[current].inst;
        if dse_can_skip_def(m, current, !dse_is_invisible_to_caller_on_unwind(s, killing_und_obj)) { can_optimize = false; continue; }
        if dse_may_throw_between(s, killing_i, current_i, killing_und_obj) return false, -1;
        if dse_is_dse_barrier(s, killing_und_obj, current_i) return false, -1;
        if !(inst_op(current_i) == .CALL && call_iid(current_i) != NOT_INTRINSIC) && dse_is_read_clobber(s, killing_loc, current_i) return false, -1;
        ma_users(m, current, *users);
        for usr: users {
            if ma_is_phi(m, usr) continue;
            if !mssa_dominates(m, start_access, usr) && dse_is_read_clobber(s, killing_loc, m.acc[usr].inst) return false, -1;
        }
        ok, cl := dse_get_loc_for_write(s, current_i);
        current_loc = cl;
        if !ok || !dse_is_removable(s, current_i) { can_optimize = false; continue; }
        if !dse_is_guaranteed_loop_independent(s, current_i, killing_i, current_loc) { can_optimize = false; continue; }
        if is_mem_term {
            if !dse_is_mem_terminator(s, current_loc, current_i, killing_i) { can_optimize = false; continue; }
        } else {
            r := dse_is_overwrite(s, killing_i, current_i, killing_loc, current_loc);
            if can_optimize {
                if current != ma_defining(m, killing_def) && (r == .COMPLETE || r == .MAYBE_PARTIAL) ma_set_optimized(m, killing_def, current);
                if r != .NONE can_optimize = false;
            }
            if r == .UNKNOWN || r == .NONE continue;
            else if r == .MAYBE_PARTIAL {
                if partial_limit.* <= 1 { walker_step_limit.* -= 1; continue; }
                partial_limit.* -= 1;
            }
        }
        break;
    }

    killing_defs: [..] Value_Id; killing_defs.allocator = temp;   // SmallPtrSet (only membership and iteration)
    array_add(*killing_defs, killing_i);
    maybe_dead := current;
    maybe_dead_loc := current_loc;
    maybe_dead_i := m.acc[maybe_dead].inst;
    worklist: [..] s32; worklist.allocator = temp;
    visited: Table(s32, bool); visited.allocator = temp;
    dse_push_mem_uses(m, maybe_dead, *worklist, *visited);
    i := 0;
    while i < worklist.count {
        defer i += 1;
        ua := worklist[i];
        if scan_limit.* < worklist.count - i return false, -1;
        scan_limit.* -= 1;
        if ma_is_phi(m, ua) {
            dominated := false;
            for ki: killing_defs if dt_properly_dominates(s.dt, inst_block(ki), m.acc[ua].block) { dominated = true; break; }
            if dominated continue;
            dse_push_mem_uses(m, ua, *worklist, *visited);
            continue;
        }
        use_inst := m.acc[ua].inst;
        dominated := false;
        for ki: killing_defs if dt_dominates_inst(s.dt, ki, use_inst) { dominated = true; break; }
        if dominated continue;
        if dse_is_mem_terminator(s, maybe_dead_loc, maybe_dead_i, use_inst) continue;
        if dse_is_noop_intrinsic(use_inst) { dse_push_mem_uses(m, ua, *worklist, *visited); continue; }
        if may_throw(use_inst) && !dse_is_invisible_to_caller_on_unwind(s, killing_und_obj) return false, -1;
        is_killing_def_from_init_attr := false;
        if is_initializes_attr_mem_loc {
            if killing_i == use_inst && killing_und_obj == get_underlying_object(maybe_dead_loc.ptr) is_killing_def_from_init_attr = true;
        }
        if dse_is_read_clobber(s, maybe_dead_loc, use_inst) && !is_killing_def_from_init_attr return false, -1;
        if maybe_dead == ua && !dse_is_guaranteed_loop_invariant(s, maybe_dead_loc.ptr) return false, -1;
        if killing_def == ua || maybe_dead == ua continue;
        if ma_is_def(m, ua) {
            if dse_is_complete_overwrite(s, maybe_dead_loc, maybe_dead_i, use_inst) {
                maybe_killing_block := inst_block(use_inst);
                if dse_po(s, maybe_killing_block) < dse_po(s, m.acc[maybe_dead].block) {
                    if !dse_is_invisible_to_caller_after_ret(s, killing_und_obj, killing_loc.ptr, killing_loc.size) {
                        dup := false;
                        for killing_defs if it == use_inst { dup = true; break; }
                        if !dup array_add(*killing_defs, use_inst);
                    }
                } else return false, -1;
            } else dse_push_mem_uses(m, ua, *worklist, *visited);
        }
    }

    if !dse_is_invisible_to_caller_after_ret(s, killing_und_obj, killing_loc.ptr, killing_loc.size) {
        killing_blocks: [..] Value_Id; killing_blocks.allocator = temp;
        contains :: (a: [..] Value_Id, b: Value_Id) -> bool { for a if it == b return true; return false; }
        for kd: killing_defs { b := inst_block(kd); if !contains(killing_blocks, b) array_add(*killing_blocks, b); }
        // SmallPtrSet iteration order is by pointer; the common post-dominator does not depend on it
        common_pred := killing_blocks[0];
        for k: 1..killing_blocks.count - 1 {
            if common_pred == NONE break;
            common_pred = dt_find_nca(s.pdt, common_pred, killing_blocks[k]);
        }
        if !dt_dominates(s.pdt, common_pred, m.acc[maybe_dead].block) {
            if !s.any_unreachable_exit return false, -1;
            common_pred = NONE;
        }
        if common_pred != NONE && contains(killing_blocks, common_pred) return true, maybe_dead;
        wl: [..] Value_Id; wl.allocator = temp;     // SetVector
        in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
        wl_insert :: (wl: *[..] Value_Id, in_wl: *Table(Value_Id, bool), b: Value_Id) {
            if table_contains(in_wl, b) return;
            table_set(in_wl, b, true); array_add(wl, b);
        }
        if common_pred != NONE wl_insert(*wl, *in_wl, common_pred);
        else for r: s.pdt.roots if inst_op(block_terminator(r)) != .UNREACHABLE wl_insert(*wl, *in_wl, r);
        preds: [..] Value_Id; preds.allocator = temp;
        k := 0;
        while k < wl.count {
            defer k += 1;
            cur := wl[k];
            if contains(killing_blocks, cur) continue;
            if cur == m.acc[maybe_dead].block return false, -1;
            if !dt_is_reachable_from_entry(s.dt, cur) continue;
            block_predecessors(cur, *preds);
            for preds wl_insert(*wl, *in_wl, it);
            if wl.count >= dse_opts.path_check_limit return false, -1;
        }
    }
    return true, maybe_dead;
}

// deleteDeadInstruction
dse_delete_dead_instruction :: (s: *Dse, si: Value_Id, deleted: *Table(s32, bool) = null) {
    u: Mssa_Updater; u.mssa = s.m;
    now_dead: [..] Value_Id; now_dead.allocator = temp;
    array_add(*now_dead, si);
    while now_dead.count {
        dead := pop(*now_dead);
        salvage_debug_info(dead);
        a := mssa_access_of(s.m, dead);
        is_mem_def := a >= 0 && ma_is_def(s.m, a);
        if a >= 0 {
            if is_mem_def {
                table_set(*s.skip_stores, a, true);
                if deleted table_set(deleted, a, true);
                if inst_op(dead) == .STORE && is_ptr_type(vtype(op(dead, 0))) {
                    uo := get_underlying_object(op(dead, 0));
                    if table_remove(*s.captured_before_return, uo) s.should_iterate_eof = true;
                    table_remove(*s.invisible_after_ret, uo);
                    table_remove(*s.invisible_after_ret_bounded, uo);
                }
            }
            mssau_remove_memory_access(*u, a);
        }
        iol := dse_iols_find(s, inst_block(dead));
        if iol dse_iol_erase(iol, dead);
        n := nops(dead);
        if n > 0 for k: 0..n-1 {
            o := op(dead, k);
            if o == NONE || !is_inst(o) continue;
            set_op(dead, k, const_poison(vtype(o)));
            if is_instruction_trivially_dead(o) array_add(*now_dead, o);
        }
        aa_query_remove_instruction(s.q, dead);
        if is_mem_def && vtype(dead) == ir.t_void erase_inst_with_metadata(dead);
        else array_add(*s.to_remove, dead);
    }
}

// mayThrowBetween
dse_may_throw_between :: (s: *Dse, killing_i: Value_Id, dead_i: Value_Id, killing_und_obj: Value_Id) -> bool {
    if killing_und_obj != NONE && dse_is_invisible_to_caller_on_unwind(s, killing_und_obj) return false;
    if inst_block(killing_i) == inst_block(dead_i) return table_contains(*s.throwing_blocks, inst_block(killing_i));
    return s.throwing_blocks.count != 0;
}
// isDSEBarrier
dse_is_dse_barrier :: (s: *Dse, killing_und_obj: Value_Id, dead_i: Value_Id) -> bool {
    if may_throw(dead_i) && !dse_is_invisible_to_caller_on_unwind(s, killing_und_obj) return true;
    if inst_is_atomic(dead_i) {
        o := inst_op(dead_i);
        if o == .LOAD || o == .STORE || o == .ATOMICRMW return is_stronger_than_monotonic(inst(dead_i).ord1);
        if o == .CMPXCHG return is_stronger_than_monotonic(inst(dead_i).ord1) || is_stronger_than_monotonic(inst(dead_i).ord2);
        fatal("dse: other atomic instructions should be skipped in MemorySSA");
    }
    return false;
}

// eliminateDeadWritesAtEndOfFunction
dse_eliminate_dead_writes_at_end_of_function :: (s: *Dse) -> bool {
    made_change := false;
    while true {
        s.should_iterate_eof = false;
        for < k: 0..s.mem_defs.count - 1 {
            def := s.mem_defs[k];
            if table_contains(*s.skip_stores, def) continue;
            def_i := s.m.acc[def].inst;
            ok, def_loc := dse_get_loc_for_write(s, def_i);
            if !ok || !dse_is_removable(s, def_i) continue;
            uo := get_underlying_object(def_loc.ptr);
            if !dse_is_invisible_to_caller_after_ret(s, uo, def_loc.ptr, def_loc.size) continue;
            if dse_is_write_at_end_of_function(s, def, def_loc) {
                dse_delete_dead_instruction(s, def_i);
                made_change = true;
            }
        }
        if !s.should_iterate_eof break;
    }
    return made_change;
}

// eliminateRedundantStoresViaDominatingConditions
dse_eliminate_redundant_stores_via_dominating_conditions :: (s: *Dse) -> bool {
    Cond :: struct { ptr: Value_Id; val: Value_Id; li: Value_Id; }
    Ctx :: struct { s: *Dse; active: [..] Cond; made_change: bool; }
    ctx: Ctx; ctx.s = s; ctx.active.allocator = temp;
    get_dominating_condition :: (s: *Dse, bb: Value_Id) -> (bool, Cond, Value_Id) {
        bi := block_terminator(bb);
        if inst_op(bi) != .CONDBR return false, .{}, NONE;
        if get_successor(bi, 0) == get_successor(bi, 1) return false, .{}, NONE;
        c := op(bi, 0);
        if !is_inst(c) || inst_op(c) != .ICMP return false, .{}, NONE;
        pred := inst(c).pred;
        icmp_l: Value_Id = NONE; store_val: Value_Id = NONE;
        for side: 0..1 {
            a := op(c, cast(u32) side); b := op(c, cast(u32)(1 - side));
            if is_inst(a) && inst_op(a) == .LOAD { icmp_l = a; store_val = b; break; }
        }
        if icmp_l == NONE || !(pred == ICMP_EQ || pred == ICMP_NE) return false, .{}, NONE;
        if is_ptr_type(vtype(store_val)) && !can_replace_pointers_if_equal(store_val, icmp_l) return false, .{}, NONE;
        succ := get_successor(bi, ifx pred == ICMP_EQ then cast(u32) 0 else 1);
        return true, .{op(icmp_l, 0), store_val, icmp_l}, succ;
    }
    visit_node :: (ctx: *Ctx, bb: Value_Id, depth: s64) {
        s := ctx.s;
        if depth > dse_opts.max_depth_recursion return;
        l := mssa_block(s.m, bb);
        if l {
            a := l.dfirst;
            while a >= 0 {
                next := s.m.acc[a].dnext;
                defer a = next;
                if !ma_is_def(s.m, a) continue;
                si := s.m.acc[a].inst;
                if inst_op(si) != .STORE || !is_unordered(si) continue;
                li: Value_Id = NONE;
                for < ctx.active if it.ptr == op(si, 1) && it.val == op(si, 0) { li = it.li; break; }
                if li == NONE continue;
                load_access := mssa_access_of(s.m, li);
                clobber := mssa_get_clobbering_access_skip_self(s.m, a, s.q);
                if mssa_dominates(s.m, clobber, load_access) {
                    dse_delete_dead_instruction(s, si);
                    ctx.made_change = true;
                }
            }
        }
        has, cond, implied := get_dominating_condition(s, bb);
        n := dt_node(s.dt, bb);
        c := s.dt.nodes[n].first_child;
        while c >= 0 {
            child_bb := s.dt.nodes[c].block;
            saved := ctx.active.count;
            if has && dt_dominates_edge_block(s.dt, bb, implied, child_bb) array_add(*ctx.active, cond);
            visit_node(ctx, child_bb, depth + 1);
            ctx.active.count = saved;
            c = s.dt.nodes[c].sibling;
        }
    }
    visit_node(*ctx, fn_entry(s.f), 0);
    return ctx.made_change;
}

// tryFoldIntoCalloc
dse_try_fold_into_calloc :: (s: *Dse, def: s32, def_uo: Value_Id) -> bool {
    def_i := s.m.acc[def].inst;
    if !is_memset_inst(def_i) return false;
    stored := call_arg(def_i, 1);
    if !is_constant_kind(vkind(stored)) || !is_null_value(stored) return false;
    if !dse_is_removable(s, def_i) return false;
    if fn_has_fn_attr(s.f, .SanitizeMemory) || fn_has_fn_attr(s.f, .SanitizeAddress) ||
       fn_has_fn_attr(s.f, .SanitizeHWAddress) || vname(s.f) == "calloc" return false;
    malloc := def_uo;
    if !is_inst(malloc) || inst_op(malloc) != .CALL return false;
    inner := call_called_function(malloc);
    if inner == NONE return false;
    zeroed_variant_name := "";
    is_malloc := false;
    {
        okf, lf := tli_lookup_fn(inner);
        is_malloc = okf && tli_func_has(s.tli, lf) && lf == .malloc;
    }
    if !is_malloc {
        found := false;
        for attr_set_items(call_fn_attrs(malloc)) if it.kind == .STRING_ATTR && it.key == "alloc-variant-zeroed" { found = true; zeroed_variant_name = it.val; }
        if !found {
            for attr_set_items(attr_list_fn(glob(inner).attrs)) if it.kind == .STRING_ATTR && it.key == "alloc-variant-zeroed" { found = true; zeroed_variant_name = it.val; }
        }
        if !found || zeroed_variant_name.count == 0 return false;
    }
    malloc_def := mssa_access_of(s.m, malloc);
    if malloc_def < 0 || !ma_is_def(s.m, malloc_def) return false;
    should_create_calloc :: (malloc: Value_Id, memset: Value_Id) -> bool {
        mb := inst_block(malloc); msb := inst_block(memset);
        if mb == msb return true;
        ptr := call_arg(memset, 0);
        ti := block_terminator(mb);
        if inst_op(ti) != .CONDBR return false;
        c := op(ti, 0);
        if !is_inst(c) || inst_op(c) != .ICMP || inst(c).pred != ICMP_EQ || op(c, 0) != ptr || !pm_zero(op(c, 1)) return false;
        if msb != get_successor(ti, 1) return false;
        return true;
    }
    if op(malloc, 0) != call_arg(def_i, 2) return false;
    if !should_create_calloc(malloc, def_i) || !dt_dominates_inst(s.dt, malloc, def_i) ||
       !dse_memory_is_not_modified_between(malloc, def_i, s.q, s.dt) return false;
    calloc: Value_Id = NONE;
    irb: Irb; irb_set_before(*irb, malloc);
    if zeroed_variant_name.count {
        attrs := glob(inner).attrs;
        ak := fn_alloc_kind(inner);
        ak = (ak | AFK_ZEROED) & ~cast(u64) AFK_UNINITIALIZED;
        fa := attr_list_fn(attrs);
        fa = attr_set_remove(fa, .AllocKind);
        akat: Attr; akat.kind = .AllocKind; akat.ty = NONE; akat.ival = ak;
        fa = attr_set_with(fa, akat);
        fa = attr_set_remove_str(fa, "alloc-variant-zeroed");
        attrs = attr_list_with_fn(attrs, fa);
        zv := module_get_or_insert_function(zeroed_variant_name, glob(inner).value_type, attrs);
        glob(zv).cc = inst(malloc).cc;
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) call_num_args(malloc) - 1 array_add(*args, call_arg(malloc, cast(u32) k));
        ci := irb_call(*irb, zv, args, zeroed_variant_name);
        inst(ci).cc = inst(malloc).cc;
        calloc = ci;
    } else {
        saved := ic;
        ic = .{};
        ic.b = irb;
        size_t_ty := vtype(call_arg(malloc, 0));
        calloc = emit_calloc(const_int(size_t_ty, 1), call_arg(malloc, 0), s.tli, type_addrspace(vtype(malloc)));
        ic = saved;
    }
    if calloc == NONE return false;
    u: Mssa_Updater; u.mssa = s.m;
    na := mssau_create_memory_access_after(*u, calloc, -1, malloc_def);
    mssau_insert_def(*u, na, true);
    rauw_with_metadata(malloc, calloc);
    dse_delete_dead_instruction(s, malloc);
    return true;
}

// storeIsNoop
dse_store_is_noop :: (s: *Dse, def: s32, def_uo: Value_Id) -> bool {
    m := s.m;
    def_i := m.acc[def].inst;
    is_store := inst_op(def_i) == .STORE;
    is_memset := is_memset_inst(def_i);
    stored: Value_Id = NONE;
    if is_store { v := op(def_i, 0); if is_constant_kind(vkind(v)) stored = v; }
    else if is_memset { v := call_arg(def_i, 1); if is_constant_kind(vkind(v)) stored = v; }
    else return false;
    if !dse_is_removable(s, def_i) return false;
    if stored != NONE {
        init_c := get_initial_value_of_allocation(def_uo, vtype(stored));
        if init_c != NONE && init_c == stored
            return is_live_on_entry(mssa_get_clobbering_access_skip_self(m, def, s.q));
    }
    if !is_store return false;
    load_i := op(def_i, 0);
    if is_inst(load_i) && inst_op(load_i) == .LOAD && op(load_i, 0) == op(def_i, 1) {
        load_access := ma_defining(m, mssa_access_of(m, load_i));
        if load_access == ma_defining(m, def) return true;
        to_check: [..] s32; to_check.allocator = temp;
        in_set: Table(s32, bool); in_set.allocator = temp;
        ins :: (to_check: *[..] s32, in_set: *Table(s32, bool), a: s32) {
            if table_contains(in_set, a) return;
            table_set(in_set, a, true); array_add(to_check, a);
        }
        current := mssa_get_clobbering_access(m, def, s.q);
        ins(*to_check, *in_set, def);
        ins(*to_check, *in_set, current);
        k := 1;
        while k < to_check.count {
            defer k += 1;
            current = to_check[k];
            if ma_is_phi(m, current) {
                for j: 0..cast(s64) ma_nops(m, current) - 1 ins(*to_check, *in_set, mphi_value(m, current, cast(u32) j));
                continue;
            }
            if load_access != current return false;
        }
        return true;
    }
    return false;
}

// removePartiallyOverlappedStores
dse_remove_partially_overlapped_stores :: (s: *Dse, iol: *Dse_Iol) -> bool {
    changed := false;
    // `for (auto OI : IOL)` iterates copies
    n := iol.entries.count;
    for k: 0..n - 1 {
        if k >= iol.entries.count break;
        e := iol.entries[k];
        im: [..] Dse_Interval; im.allocator = temp;
        for e.map array_add(*im, it);
        dead_i := e.inst;
        _, loc := dse_get_loc_for_write(s, dead_i);
        ptr := strip_pointer_casts(loc.ptr);
        dead_size := ls_value(loc.size);
        _, dead_start := get_pointer_base_with_constant_offset(ptr);
        changed |= dse_try_to_shorten_end(dead_i, *im, *dead_start, *dead_size);
        if im.count == 0 continue;
        changed |= dse_try_to_shorten_begin(dead_i, *im, *dead_start, *dead_size);
    }
    return changed;
}

// eliminateRedundantStoresOfExistingValues
dse_eliminate_redundant_stores_of_existing_values :: (s: *Dse) -> bool {
    m := s.m;
    made_change := false;
    for def: s.mem_defs {
        if table_contains(*s.skip_stores, def) || is_live_on_entry(def) continue;
        def_inst := m.acc[def].inst;
        ok, def_loc := dse_get_loc_for_write(s, def_inst);
        if !ok || !dse_is_removable(s, def_inst) continue;
        upper := ifx ma_is_optimized(m, def) then ma_get_optimized(m, def) else ma_defining(m, def);
        if upper < 0 || !ma_is_def(m, upper) || is_live_on_entry(upper) continue;
        upper_inst := m.acc[upper].inst;
        is_redundant :: (s: *Dse, def_inst: Value_Id, upper_inst: Value_Id, def_loc: Mem_Loc) -> bool {
            if is_identical_to_when_defined_intersect_attrs(def_inst, upper_inst) return true;
            if is_memset_inst(upper_inst) && inst_op(def_inst) == .STORE {
                okl, upper_loc := dse_get_loc_for_write(s, upper_inst);
                if !okl return false;
                r := dse_is_overwrite(s, upper_inst, def_inst, upper_loc, def_loc);
                sb := is_bytewise_value(op(def_inst, 0));
                return sb != NONE && sb == call_arg(upper_inst, 1) && r == .COMPLETE;
            }
            return false;
        }
        if !is_redundant(s, def_inst, upper_inst, def_loc) || dse_is_read_clobber(s, def_loc, def_inst) continue;
        dse_delete_dead_instruction(s, def_inst);
        made_change = true;
    }
    return made_change;
}

// getInitializesArgMemLoc
dse_get_initializes_arg_mem_loc :: (s: *Dse, i: Value_Id, out: *[..] Mem_Loc) {
    if !is_call_base(i) return;
    Range :: struct { lo: s64; hi: s64; }
    Arg_Info :: struct { idx: u32; dead_or_invisible: bool; inits: [..] Range; }
    Group :: struct { arg: Value_Id; list: [..] Arg_Info; }
    groups: [..] Group; groups.allocator = temp;
    n := call_num_args(i);
    for idx: 0..cast(s64) n - 1 {
        k := cast(u32) idx;
        cur := call_arg(i, k);
        if !is_ptr_type(vtype(cur)) continue;
        inits: [..] Range; inits.allocator = temp;
        at := call_param_attr(i, k, .Initializes);
        if at && !call_param_has_attr(i, k, .ByVal) {
            for lo, j: at.lo array_add(*inits, .{cast,no_check(s64) lo, cast,no_check(s64) at.hi[j]});
        }
        if inits.count && !call_only_accesses_inaccessible_mem_or_arg_mem(i) && !dse_is_func_local_and_not_captured(s, cur, i)
            inits.count = 0;
        dead_or_inv := call_param_has_attr(i, k, .DeadOnUnwind) || (inst_op(i) == .CALL && dse_is_invisible_to_caller_on_unwind(s, cur));
        info: Arg_Info; info.idx = k; info.dead_or_invisible = dead_or_inv; info.inits = inits;
        found_aliasing := false;
        for * g: groups {
            r := aa_alias(s.q, mloc_before_or_after(g.arg), mloc_before_or_after(cur));
            if r.kind == AR_NO continue;
            found_aliasing = true;
            if r.kind == AR_MUST array_add(*g.list, info);
            else { e := info; e.inits.allocator = temp; e.inits.count = 0; e.inits.data = null; e.inits.allocated = 0; array_add(*g.list, e); }
        }
        if !found_aliasing {
            // Arguments[CurArg] = {InitInfo}
            replaced := false;
            for * g: groups if g.arg == cur { g.list.count = 0; array_add(*g.list, info); replaced = true; }
            if !replaced { g: Group; g.arg = cur; g.list.allocator = temp; array_add(*g.list, info); array_add(*groups, g); }
        }
    }
    does_not_throw := call_does_not_throw(i);
    for g: groups {
        // getIntersectedInitRangeList
        if g.list.count == 0 continue;
        bad := false;
        for g.list { if !does_not_throw && !it.dead_or_invisible { bad = true; break; } if it.inits.count == 0 { bad = true; break; } }
        if bad continue;
        inter: [..] Range; inter.allocator = temp;
        for g.list[0].inits array_add(*inter, it);
        for a, ai: g.list {
            if ai == 0 continue;
            // ConstantRangeList::intersectWith (both sorted, disjoint)
            res: [..] Range; res.allocator = temp;
            x := 0; y := 0;
            while x < inter.count && y < a.inits.count {
                lo := max(inter[x].lo, a.inits[y].lo); hi := min(inter[x].hi, a.inits[y].hi);
                if lo < hi array_add(*res, .{lo, hi});
                if inter[x].hi < a.inits[y].hi x += 1; else y += 1;
            }
            inter = res;
        }
        if inter.count == 0 continue;
        for a: g.list for r: inter {
            if r.lo == 0 array_add(out, mloc(call_arg(i, a.idx), ls_precise(cast(u64)(r.hi - r.lo)), aa_metadata(i)));
        }
    }
}
// isFuncLocalAndNotCaptured
dse_is_func_local_and_not_captured :: (s: *Dse, arg: Value_Id, cb: Value_Id) -> bool {
    uo := get_underlying_object(arg);
    return is_identified_function_local(uo) && aa_captures_before(s.q, uo, cb, true, false) == CC_NONE;
}

// eliminateDeadDefs(MemoryLocationWrapper): (changed, deleted killing loc)
dse_eliminate_dead_defs_loc :: (s: *Dse, kw: *Dse_Loc) -> (bool, bool) {
    m := s.m;
    changed := false;
    deleted_killing_loc := false;
    scan_limit := dse_opts.scan_limit;
    walker_step_limit := dse_opts.walk_limit;
    partial_limit := dse_opts.partial_store_limit;
    to_check: [..] s32; to_check.allocator = temp;
    in_check: Table(s32, bool); in_check.allocator = temp;
    ins :: (to_check: *[..] s32, in_check: *Table(s32, bool), a: s32) {
        if table_contains(in_check, a) return;
        table_set(in_check, a, true); array_add(to_check, a);
    }
    deleted: Table(s32, bool); deleted.allocator = temp;
    ins(*to_check, *in_check, ma_defining(m, kw.def));
    is_term := dse_is_mem_terminator_inst(s, kw.inst);
    k := 0;
    while k < to_check.count {
        defer k += 1;
        current := to_check[k];
        if table_contains(*deleted, current) continue;
        found, dead_access := dse_get_dom_memory_def(s, kw.def, current, kw.loc, kw.und_obj, *scan_limit, *walker_step_limit,
                                                     is_term, *partial_limit, kw.by_initializes);
        if !found continue;
        if ma_is_phi(m, dead_access) {
            phi_block := m.acc[dead_access].block;
            for j: 0..cast(s64) ma_nops(m, dead_access) - 1 {
                inc := mphi_value(m, dead_access, cast(u32) j);
                inc_block := m.acc[inc].block;
                if dse_po(s, inc_block) > dse_po(s, phi_block) ins(*to_check, *in_check, inc);
            }
            continue;
        }
        dlocs: [..] Dse_Loc; dlocs.allocator = temp;
        dse_get_loc_for_inst(s, m.acc[dead_access].inst, false, *dlocs, dead_access);
        assert(dlocs.count == 1, "dse: expected one location for a dead def");
        dw := dlocs[0];
        ins(*to_check, *in_check, ma_defining(m, dw.def));
        if is_term {
            if kw.und_obj != dw.und_obj continue;
            dse_delete_dead_instruction(s, dw.inst, *deleted);
            changed = true;
        } else {
            r, killing_off, dead_off := dse_is_overwrite(s, kw.inst, dw.inst, kw.loc, dw.loc);
            if r == .MAYBE_PARTIAL {
                iol := dse_iols_for(s, inst_block(dw.inst));
                r = dse_is_partial_overwrite(kw.loc, dw.loc, killing_off, dead_off, dw.inst, iol);
            }
            if dse_opts.enable_partial_store_merging && r == .PARTIAL_EARLIER_WITH_FULL_LATER {
                dead_si := dw.inst; killing_si := kw.inst;
                if inst_op(dead_si) == .STORE && inst_op(killing_si) == .STORE && dt_dominates_inst(s.dt, dead_si, killing_si) {
                    merged := dse_try_to_merge_partial_overlapping_stores(killing_si, dead_si, killing_off, dead_off, s.q, s.dt);
                    if merged != NONE {
                        set_op(dead_si, 0, merged);
                        changed = true;
                        deleted_killing_loc = true;
                        dse_delete_dead_instruction(s, killing_si, *deleted);
                        iol := dse_iols_find(s, inst_block(dead_si));
                        if iol dse_iol_erase(iol, dead_si);
                        break;
                    }
                }
            }
            if r == .COMPLETE {
                dse_delete_dead_instruction(s, dw.inst, *deleted);
                changed = true;
            }
        }
    }
    return changed, deleted_killing_loc;
}

// eliminateDeadDefs(MemoryDefWrapper)
dse_eliminate_dead_defs :: (s: *Dse, locs: [] Dse_Loc) -> bool {
    if locs.count == 0 return false;
    made_change := false;
    for * kw: locs {
        changed, deleted_killing := dse_eliminate_dead_defs_loc(s, kw);
        made_change |= changed;
        if !deleted_killing && dse_store_is_noop(s, kw.def, kw.und_obj) {
            dse_delete_dead_instruction(s, kw.inst);
            made_change = true;
            continue;
        }
        if !deleted_killing && dse_try_fold_into_calloc(s, kw.def, kw.und_obj) {
            dse_delete_dead_instruction(s, kw.inst);
            made_change = true;
            continue;
        }
    }
    return made_change;
}

// DSEPass::run
dse_run :: (f: Value_Id) -> Preserved {
    s: Dse;
    dse_init(*s, f);
    made_change := false;
    k := 0;
    while k < s.mem_defs.count {
        defer k += 1;
        killing_def := s.mem_defs[k];
        if table_contains(*s.skip_stores, killing_def) continue;
        locs: [..] Dse_Loc; locs.allocator = temp;
        dse_get_loc_for_inst(*s, s.m.acc[killing_def].inst, dse_opts.enable_initializes_improvement, *locs, killing_def);
        made_change |= dse_eliminate_dead_defs(*s, locs);
    }
    if dse_opts.enable_partial_overwrite_tracking
        for * s.iols made_change |= dse_remove_partially_overlapped_stores(*s, it);
    made_change |= dse_eliminate_redundant_stores_of_existing_values(*s);
    made_change |= dse_eliminate_dead_writes_at_end_of_function(*s);
    made_change |= dse_eliminate_redundant_stores_via_dominating_conditions(*s);
    while s.to_remove.count {
        d := pop(*s.to_remove);
        erase_inst_with_metadata(d);
    }
    if mssa_opts.verify mssa_verify(s.m);
    if !made_change return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .MEMORYSSA);
    return pa;
}

attr_set_remove_str :: (s: u32, key: string) -> u32 {
    all: [..] Attr; all.allocator = temp;
    found := false;
    for attr_set_items(s) { if it.kind == .STRING_ATTR && it.key == key { found = true; continue; } array_add(*all, it); }
    if !found return s;
    return attr_set_get(all);
}
// Instruction::isIdenticalToWhenDefined(I, IntersectAttrs = true): call attribute lists only need to intersect
is_identical_to_when_defined_intersect_attrs :: (a: Value_Id, b: Value_Id) -> bool {
    if is_identical_to_when_defined(a, b) return true;
    if !is_call_base(a) || inst_op(a) != inst_op(b) || inst(a).attrs == inst(b).attrs return false;
    ok, _ := attr_list_intersect(inst(a).attrs, inst(b).attrs);
    if !ok return false;
    saved := inst(b).attrs;
    inst(b).attrs = inst(a).attrs;
    r := is_identical_to_when_defined(a, b);
    inst(b).attrs = saved;
    return r;
}
