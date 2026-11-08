// MemoryDependenceAnalysis: port of llvm/lib/Analysis/MemoryDependenceAnalysis.cpp and
// llvm/include/llvm/Analysis/MemoryDependenceAnalysis.h (MemDepResult, NonLocalDepEntry / NonLocalDepResult with
// SelectAddr, GetLocation, getCallDependencyFrom, getPointerDependencyFrom, getInvariantGroupPointerDependency,
// canSkipClobberingStore, getSimplePointerDependencyFrom, getDependency, getNonLocalCallDependency,
// getNonLocalPointerDependency, getNonLocalInfoForBlock, SortNonLocalDepInfoCache, getNonLocalPointerDepFromBB incl.
// the select-address translation, removeCachedNonLocalPointerDependencies, invalidateCachedPointerInfo,
// invalidateCachedPredecessors, removeInstruction, getClobberOffset) and of PredIteratorCache
// (llvm/include/llvm/IR/PredIteratorCache.h).
//
// One Mem_Dep_Results per GVN run (GVN does not preserve it). The caches are tables keyed like LLVM's DenseMaps; the
// per-pointer infos (NonLocalPointerDeps) and per-call infos (NonLocalDepsMap) live in arrays indexed through a
// table so that rows stay addressable while the tables grow (LLVM re-fetches its pointers for the same reason).
// NonLocalDepEntry orders by BasicBlock pointer; we order by block id (creation order), which is what malloc
// gives for blocks created in sequence (see knowledge/llvm/gvn.md). The EarliestEscapeAnalysis cache lives as long
// as the analysis (its staleness is visible: see knowledge/llvm/gvn.md).

Mdep_Kind :: enum u8 { INVALID; CLOBBER; DEF; NONLOCAL; NONFUNCLOCAL; SELECT; UNKNOWN; }

// MemDepResult (default = dirty with no instruction)
Mem_Dep :: struct { kind: Mdep_Kind = .INVALID; inst: Value_Id = NONE; }
mdr_def :: (i: Value_Id) -> Mem_Dep { return .{.DEF, i}; }
mdr_clobber :: (i: Value_Id) -> Mem_Dep { return .{.CLOBBER, i}; }
mdr_dirty :: (i: Value_Id) -> Mem_Dep { return .{.INVALID, i}; }
mdr_nonlocal :: () -> Mem_Dep { return .{.NONLOCAL, NONE}; }
mdr_nonfunclocal :: () -> Mem_Dep { return .{.NONFUNCLOCAL, NONE}; }
mdr_select :: () -> Mem_Dep { return .{.SELECT, NONE}; }
mdr_unknown :: () -> Mem_Dep { return .{.UNKNOWN, NONE}; }
mdr_is_def :: inline (r: Mem_Dep) -> bool { return r.kind == .DEF; }
mdr_is_clobber :: inline (r: Mem_Dep) -> bool { return r.kind == .CLOBBER; }
mdr_is_local :: inline (r: Mem_Dep) -> bool { return r.kind == .DEF || r.kind == .CLOBBER; }
mdr_is_nonlocal :: inline (r: Mem_Dep) -> bool { return r.kind == .NONLOCAL; }
mdr_is_nonfunclocal :: inline (r: Mem_Dep) -> bool { return r.kind == .NONFUNCLOCAL; }
mdr_is_select :: inline (r: Mem_Dep) -> bool { return r.kind == .SELECT; }
mdr_is_unknown :: inline (r: Mem_Dep) -> bool { return r.kind == .UNKNOWN; }
mdr_is_dirty :: inline (r: Mem_Dep) -> bool { return r.kind == .INVALID; }
mdr_inst :: inline (r: Mem_Dep) -> Value_Id {
    if r.kind == .INVALID || r.kind == .CLOBBER || r.kind == .DEF return r.inst;
    return NONE;
}

// NonLocalDepEntry
Nl_Entry :: struct { bb: Value_Id; r: Mem_Dep; }
// NonLocalDepResult: the entry plus its SelectAddr (addr = the address, or the select condition when sel_t/sel_f
// are both set)
Nl_Result :: struct { bb: Value_Id; r: Mem_Dep; addr: Value_Id = NONE; sel_t: Value_Id = NONE; sel_f: Value_Id = NONE; }
nlr_has_select_addrs :: inline (r: Nl_Result) -> bool { return r.sel_t != NONE && r.sel_f != NONE; }

// NonLocalPointerInfo
Nl_Ptr_Info :: struct {
    pair_bb: Value_Id = NONE;   // BBSkipFirstBlockPair
    pair_skip: bool;
    deps: [..] Nl_Entry;        // NonLocalDeps
    size: u64 = LS_AFTER;       // LocationSize::afterPointer()
    tags: AA_Tags;
}
// PerInstNLInfo
Per_Inst_Nl :: struct { deps: [..] Nl_Entry; dirty: bool; }
Md_Visit :: struct { v: Value_Id; epoch: u32; }

Mem_Dep_Results :: struct {
    f: Value_Id;
    aar: Aa_Results;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    local_deps: Table(Value_Id, Mem_Dep);
    nl_defs_cache: Table(Value_Id, Nl_Result);
    rev_nl_defs_cache: Table(Value_Id, [..] Value_Id);
    nlp_index: Table(u64, s64);                    // NonLocalPointerDeps: ValueIsLoadPair -> row of nlp
    nlp: [..] Nl_Ptr_Info;
    rev_nlp_deps: Table(Value_Id, [..] u64);
    nl_deps_index: Table(Value_Id, s64);           // NonLocalDepsMap -> row of nl_per_inst
    nl_per_inst: [..] Per_Inst_Nl;
    rev_local_deps: Table(Value_Id, [..] Value_Id);
    rev_nl_deps: Table(Value_Id, [..] Value_Id);
    visited: Table(Value_Id, Md_Visit);            // NonLocalPointerDepVisited
    epoch: u32;
    pred_cache: Table(Value_Id, [] Value_Id);
    clobber_offsets: Table(Value_Id, s32);
    block_scan_limit: s64;
    ee: *Aa_Query;   // EarliestEscapeAnalysis EEA(DT): one cache for the analysis' lifetime, shared by every BatchAA
}

md_opts: struct {
    block_scan_limit: s64 = 100;     // -memdep-block-scan-limit
    block_number_limit: s64 = 200;   // -memdep-block-number-limit
    cache_global_limit: s64 = 10000; // -memdep-cache-global-limit
};
MD_NUM_RESULTS_LIMIT :: 100;

// MemoryDependenceAnalysis::run
md_new :: (f: Value_Id, aar: Aa_Results, ac: *Assumption_Cache, dt: *Dom_Tree) -> *Mem_Dep_Results {
    md := New(Mem_Dep_Results,, allocator = temp);
    md.f = f; md.aar = aar; md.ac = ac; md.dt = dt;
    md.block_scan_limit = md_opts.block_scan_limit;
    md.local_deps.allocator = temp; md.nl_defs_cache.allocator = temp; md.rev_nl_defs_cache.allocator = temp;
    md.nlp_index.allocator = temp; md.nlp.allocator = temp; md.rev_nlp_deps.allocator = temp;
    md.nl_deps_index.allocator = temp; md.nl_per_inst.allocator = temp; md.rev_local_deps.allocator = temp;
    md.rev_nl_deps.allocator = temp; md.visited.allocator = temp; md.pred_cache.allocator = temp;
    md.clobber_offsets.allocator = temp;
    md.ee = aa_query_new_earliest_escape(*md.aar, dt);
    return md;
}

md_vil_key :: inline (p: Value_Id, is_load: bool) -> u64 { return ((cast(u64) p) << 1) | cast(u64) is_load; }
md_vil_ptr :: inline (k: u64) -> Value_Id { return cast(Value_Id) (k >> 1); }

// SmallPtrSet-like reverse maps
md_rev_insert :: (t: *Table(Value_Id, [..] $T), key: Value_Id, v: T) {
    p := table_find_pointer(t, key);
    if !p { e: [..] T; e.allocator = temp; p = table_add(t, key, e); }
    for p.* if it == v return;
    array_add(p, v);
}
// RemoveFromReverseMap
md_rev_remove :: (t: *Table(Value_Id, [..] $T), key: Value_Id, v: T) {
    p := table_find_pointer(t, key);
    if !p return;
    for p.* if it == v { array_unordered_remove_by_index(p, it_index); break; }
    if p.count == 0 table_remove(t, key);
}

// PredIteratorCache::get
md_preds :: (md: *Mem_Dep_Results, bb: Value_Id) -> [] Value_Id {
    p := table_find_pointer(*md.pred_cache, bb);
    if p return p.*;
    l: [..] Value_Id; l.allocator = temp;
    block_predecessors(bb, *l);
    table_add(*md.pred_cache, bb, l);
    return l;
}

// AAResults helpers (a fresh SimpleAAQueryInfo per call, like calling AAResults directly)
aar_only_reads_memory :: (aar: *Aa_Results, call: Value_Id) -> bool { return mem_only_reads(aa_memory_effects_call(aa_query_new(aar), call)); }
aar_does_not_access_memory :: (aar: *Aa_Results, call: Value_Id) -> bool { return aa_memory_effects_call(aa_query_new(aar), call) == ME_NONE; }
// isStrongerThan(AO, Other) for Other in {NotAtomic, Unordered, Monotonic}
ord_stronger_than :: inline (a: u8, b: u8) -> bool { return a > b; }

// GetLocation: (ModRefInfo, location; ptr NONE when there is none)
md_get_location :: (i: Value_Id) -> (u8, Mem_Loc) {
    o := inst_op(i);
    none: Mem_Loc; none.ptr = NONE;
    if o == .LOAD {
        if is_unordered(i) return MR_REF, mloc_get(i);
        if inst(i).ord1 == ORD_MONOTONIC return MR_MODREF, mloc_get(i);
        return MR_MODREF, none;
    }
    if o == .STORE {
        if is_unordered(i) return MR_MOD, mloc_get(i);
        if inst(i).ord1 == ORD_MONOTONIC return MR_MODREF, mloc_get(i);
        return MR_MODREF, none;
    }
    if o == .VAARG return MR_MODREF, mloc_get(i);
    if is_call_base(i) {
        fo := get_freed_operand(i);
        if fo != NONE return MR_MOD, mloc_after(fo);
    }
    id := call_iid(i);
    if id == IID_LIFETIME_START || id == IID_LIFETIME_END return MR_MOD, mloc_for_argument(i, 0, true);
    if id == IID_INVARIANT_START return MR_MOD, mloc_for_argument(i, 1, true);
    if id == IID_INVARIANT_END return MR_MOD, mloc_for_argument(i, 2, true);
    if id == IID_MASKED_LOAD return MR_REF, mloc_for_argument(i, 0, true);
    if id == IID_MASKED_STORE return MR_MOD, mloc_for_argument(i, 1, true);
    if may_write_to_memory(i) return MR_MODREF, none;
    if may_read_from_memory(i) return MR_REF, none;
    return MR_NO, none;
}

md_entry_result :: (md: *Mem_Dep_Results, bb: Value_Id) -> Mem_Dep {
    if bb != fn_entry(block_fn(bb)) return mdr_nonlocal();
    return mdr_nonfunclocal();
}

// getCallDependencyFrom(Call, isReadOnlyCall, ScanIt, BB): scan_pos = the instruction before which scanning
// starts (NONE = BB->end())
md_call_dependency_from :: (md: *Mem_Dep_Results, call: Value_Id, is_read_only_call: bool, scan_pos: Value_Id, bb: Value_Id) -> Mem_Dep {
    limit := md.block_scan_limit;
    is_invariant_load := get_metadata(call, md_kind_id("invariant.load")) != NONE;
    i := ifx scan_pos == NONE then block_last(bb) else inst_prev(scan_pos);
    while i != NONE {
        cur := i;
        i = inst_prev(i);
        limit -= 1;
        if limit == 0 return mdr_unknown();
        mr, loc := md_get_location(cur);
        if loc.ptr != NONE {
            if aa_mod_ref_call_loc(aa_query_new(*md.aar), call, loc) != MR_NO {
                if is_invariant_load continue;
                return mdr_clobber(cur);
            }
            continue;
        }
        if is_call_base(cur) {
            is_identical_ro := is_read_only_call && (mr & MR_MOD) == 0 && is_identical_to_when_defined(call, cur);
            if is_invariant_load && is_identical_ro return mdr_def(cur);
            if aa_mod_ref_call_call(aa_query_new(*md.aar), call, cur) == MR_NO {
                if is_identical_ro return mdr_def(cur);
                continue;
            } else if is_invariant_load {
                continue;
            } else return mdr_clobber(cur);
        }
        if mr != MR_NO return mdr_clobber(cur);
    }
    return md_entry_result(md, bb);
}

// getPointerDependencyFrom(MemLoc, isLoad, ScanIt, BB, QueryInst, Limit, BatchAA)
md_pointer_dependency_from :: (md: *Mem_Dep_Results, loc: Mem_Loc, is_load: bool, scan_pos: Value_Id, bb: Value_Id,
                               query: Value_Id, limit: *s64, q: *Aa_Query) -> Mem_Dep {
    ig := mdr_unknown();
    if query != NONE && inst_op(query) == .LOAD {
        ig = md_invariant_group_pointer_dependency(md, query, bb);
        if mdr_is_def(ig) return ig;
    }
    simple := md_simple_pointer_dependency_from(md, loc, is_load, scan_pos, bb, query, limit, q);
    if mdr_is_def(simple) return simple;
    if mdr_is_nonlocal(ig) return ig;
    return simple;
}
// getPointerDependencyFrom without a BatchAA: a new one with the EarliestEscapeAnalysis
md_pointer_dependency_from_new_batch :: (md: *Mem_Dep_Results, loc: Mem_Loc, is_load: bool, scan_pos: Value_Id, bb: Value_Id,
                                         query: Value_Id, limit: *s64) -> Mem_Dep {
    q := aa_query_new_sharing_ee(*md.aar, md.ee);
    return md_pointer_dependency_from(md, loc, is_load, scan_pos, bb, query, limit, q);
}

// getInvariantGroupPointerDependency
md_invariant_group_pointer_dependency :: (md: *Mem_Dep_Results, li: Value_Id, bb: Value_Id) -> Mem_Dep {
    if get_metadata(li, md_kind_id("invariant.group")) == NONE return mdr_unknown();
    load_op := strip_pointer_casts(op(li, 0));
    if is_global_value(vkind(load_op)) return mdr_unknown();
    closest: Value_Id = NONE;
    u := ir.v_first_use[load_op];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) || usr == li || !dt_dominates_inst(md.dt, usr, li) continue;
        o := inst_op(usr);
        if (o == .LOAD || (o == .STORE && op(usr, 1) == load_op)) && get_metadata(usr, md_kind_id("invariant.group")) != NONE {
            if closest == NONE || dt_dominates_inst(md.dt, closest, usr) closest = usr;
        }
    }
    if closest == NONE return mdr_unknown();
    if inst_block(closest) == bb return mdr_def(closest);
    if !table_contains(*md.nl_defs_cache, li) {
        r: Nl_Result; r.bb = inst_block(closest); r.r = mdr_def(closest); r.addr = NONE;
        table_add(*md.nl_defs_cache, li, r);
    }
    md_rev_insert(*md.rev_nl_defs_cache, closest, li);
    return mdr_nonlocal();
}

// canSkipClobberingStore
md_can_skip_clobbering_store :: (si: Value_Id, loc: Mem_Loc, loc_align: u64, q: *Aa_Query, scan_limit: s64) -> bool {
    if !ls_has_value(loc.size) return false;
    if mloc_get(si).size != loc.size return false;
    if ls_is_scalable(loc.size) return false;
    if min(loc_align, inst(si).align) < ls_value(loc.size) return false;
    li := op(si, 0);
    if !is_inst(li) || inst_op(li) != .LOAD || inst_block(li) != inst_block(si) return false;
    if aa_alias(q, mloc_get(li), loc).kind != AR_MUST return false;
    n := 0;
    i := li;
    while i != si {
        n += 1;
        if n > scan_limit || (aa_mod_ref_inst_loc(q, i, loc) & MR_MOD) != 0 return false;
        i = inst_next(i);
    }
    return true;
}

// isComplexForReordering
md_is_complex_for_reordering :: (i: Value_Id, ao: u8) -> bool {
    if is_volatile(i) return true;
    if inst_op(i) == .LOAD || inst_op(i) == .STORE return ord_stronger_than(inst(i).ord1, ao);
    return may_read_or_write_memory(i);
}

// getSimplePointerDependencyFrom
md_simple_pointer_dependency_from :: (md: *Mem_Dep_Results, loc: Mem_Loc, is_load: bool, scan_pos: Value_Id, bb: Value_Id,
                                      query: Value_Id, limit_in: *s64, q: *Aa_Query) -> Mem_Dep {
    is_invariant_load := false;
    loc_align := pointer_alignment(loc.ptr);
    default_limit := md.block_scan_limit;
    limit := limit_in;
    if !limit limit = *default_limit;
    if is_load && query != NONE {
        is_invariant_load = get_metadata(query, md_kind_id("invariant.load")) != NONE;
        if inst_op(query) == .LOAD loc_align = inst(query).align;
    }
    i := ifx scan_pos == NONE then block_last(bb) else inst_prev(scan_pos);
    while i != NONE {
        cur := i;
        i = inst_prev(i);
        limit.* -= 1;
        if limit.* == 0 return mdr_unknown();
        id := call_iid(cur);
        if id == IID_LIFETIME_START {
            if aa_alias(q, mloc_after(call_arg(cur, 0)), loc).kind == AR_MUST return mdr_def(cur);
            continue;
        }
        if id == IID_MASKED_LOAD || id == IID_MASKED_STORE {
            _, l := md_get_location(cur);
            r := aa_alias(q, l, loc);
            if r.kind == AR_NO continue;
            if r.kind == AR_MUST return mdr_def(cur);
            if id == IID_MASKED_LOAD continue;
            return mdr_clobber(cur);
        }
        o := inst_op(cur);
        if o == .LOAD {
            if is_volatile(cur) {
                if query == NONE return mdr_clobber(cur);
                if is_volatile(query) return mdr_clobber(cur);
            }
            ord := inst(cur).ord1;
            if ord != 0 && is_stronger_than_unordered(ord) {
                if query == NONE || md_is_complex_for_reordering(query, 0) return mdr_clobber(cur);
                if ord != ORD_MONOTONIC return mdr_clobber(cur);
            }
            load_loc := mloc_get(cur);
            r := aa_alias(q, load_loc, loc);
            if r.kind == AR_NO continue;
            if is_load {
                if r.kind == AR_MUST return mdr_def(cur);
                if r.kind == AR_PARTIAL && r.has_offset {
                    table_set(*md.clobber_offsets, cur, r.offset);
                    return mdr_clobber(cur);
                }
                continue;
            }
            if (aa_mod_ref_mask(q, load_loc) & MR_MOD) == 0 continue;
            return mdr_def(cur);
        }
        if o == .STORE {
            if !is_unordered(cur) && inst(cur).ord1 != 0 {
                if query == NONE || md_is_complex_for_reordering(query, ORD_UNORDERED) return mdr_clobber(cur);
            }
            if is_volatile(cur) && (query == NONE || is_volatile(query)) return mdr_clobber(cur);
            if aa_mod_ref_inst_loc(q, cur, loc) == MR_NO continue;
            store_loc := mloc_get(cur);
            r := aa_alias(q, store_loc, loc);
            if r.kind == AR_NO continue;
            if r.kind == AR_MUST return mdr_def(cur);
            if is_invariant_load continue;
            if md_can_skip_clobbering_store(cur, loc, loc_align, q, limit.*) continue;
            return mdr_clobber(cur);
        }
        if o == .ALLOCA || is_no_alias_call(cur) {
            access_ptr := get_underlying_object(loc.ptr);
            if access_ptr == cur || aa_alias(q, mloc_before_or_after(cur), mloc_before_or_after(access_ptr)).kind == AR_MUST
                return mdr_def(cur);
        }
        if o == .SELECT && loc.ptr == cur return mdr_def(cur);
        if is_invariant_load continue;
        if o == .FENCE && is_load && inst(cur).ord1 == ORD_RELEASE continue;
        mr := aa_mod_ref_inst_loc(q, cur, loc);
        if mr == MR_NO continue;
        if mr == MR_MOD return mdr_clobber(cur);
        if mr == MR_REF && is_load continue;
        return mdr_clobber(cur);
    }
    return md_entry_result(md, bb);
}

// getDependency(QueryInst)
md_get_dependency :: (md: *Mem_Dep_Results, query: Value_Id) -> Mem_Dep {
    table_reset(*md.clobber_offsets);
    scan_pos := query;
    cached: Mem_Dep;
    found, c := table_find(*md.local_deps, query);
    if found cached = c;
    else table_add(*md.local_deps, query, cached);   // LocalDeps[QueryInst] default-constructs a dirty entry
    if !mdr_is_dirty(cached) return cached;
    if cached.inst != NONE {
        scan_pos = cached.inst;
        md_rev_remove(*md.rev_local_deps, cached.inst, query);
    }
    qbb := inst_block(query);
    result: Mem_Dep;
    if block_first(qbb) == query {
        result = md_entry_result(md, qbb);
    } else {
        mr, loc := md_get_location(query);
        if loc.ptr != NONE {
            is_load := (mr & MR_MOD) == 0;
            if call_iid(query) == IID_LIFETIME_START is_load = true;
            result = md_pointer_dependency_from_new_batch(md, loc, is_load, scan_pos, qbb, query, null);
        } else if is_call_base(query) {
            ro := aar_only_reads_memory(*md.aar, query);
            result = md_call_dependency_from(md, query, ro, scan_pos, qbb);
        } else result = mdr_unknown();
    }
    table_set(*md.local_deps, query, result);
    if mdr_inst(result) != NONE md_rev_insert(*md.rev_local_deps, mdr_inst(result), query);
    return result;
}

md_entry_less :: (a: Nl_Entry, b: Nl_Entry) -> bool { return a.bb < b.bb; }
// llvm::sort of a NonLocalDepInfo (keys are unique blocks)
md_sort_entries :: (c: *[..] Nl_Entry) {
    if c.count < 2 return;
    // insertion sort (keys unique, so any sort gives the same result)
    for k: 1..c.count-1 {
        x := c.*[k];
        j := k - 1;
        while j >= 0 && md_entry_less(x, c.*[j]) { c.*[j + 1] = c.*[j]; j -= 1; }
        c.*[j + 1] = x;
    }
}
// std::upper_bound(begin, begin + n, NonLocalDepEntry(bb)) adjusted to an exact match: index or -1
md_find_sorted :: (c: [] Nl_Entry, n: s64, bb: Value_Id) -> s64 {
    lo := 0; hi := n;
    while lo < hi {
        mid := (lo + hi) / 2;
        if bb < c[mid].bb hi = mid; else lo = mid + 1;
    }
    e := lo;
    if e != 0 && c[e - 1].bb == bb e -= 1;
    if e != n && c[e].bb == bb return e;
    return -1;
}

// getNonLocalCallDependency(QueryCall): the row of nl_per_inst holding the result
md_get_non_local_call_dependency :: (md: *Mem_Dep_Results, call: Value_Id) -> [] Nl_Entry {
    idx: s64;
    found, x := table_find(*md.nl_deps_index, call);
    if found idx = x;
    else {
        e: Per_Inst_Nl; e.deps.allocator = temp;
        idx = md.nl_per_inst.count;
        array_add(*md.nl_per_inst, e);
        table_add(*md.nl_deps_index, call, idx);
    }
    cache := *md.nl_per_inst[idx].deps;
    dirty_blocks: [..] Value_Id; dirty_blocks.allocator = temp;
    if cache.count {
        if !md.nl_per_inst[idx].dirty return cache.*;
        for cache.* if mdr_is_dirty(it.r) array_add(*dirty_blocks, it.bb);
        md_sort_entries(cache);
    } else {
        for md_preds(md, inst_block(call)) array_add(*dirty_blocks, it);
    }
    is_readonly_call := aar_only_reads_memory(*md.aar, call);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    num_sorted := cache.count;
    while dirty_blocks.count {
        dirty_bb := pop(*dirty_blocks);
        if table_contains(*visited, dirty_bb) continue;
        table_add(*visited, dirty_bb, true);
        cache = *md.nl_per_inst[idx].deps;
        e := md_find_sorted(cache.*, num_sorted, dirty_bb);
        existing := -1;
        if e >= 0 {
            if !mdr_is_dirty(cache.*[e].r) continue;
            existing = e;
        }
        scan_pos: Value_Id = NONE;   // DirtyBB->end()
        if existing >= 0 {
            ei := mdr_inst(cache.*[existing].r);
            if ei != NONE {
                scan_pos = ei;
                md_rev_remove(*md.rev_nl_deps, ei, call);
            }
        }
        dep: Mem_Dep;
        at_begin := ifx scan_pos == NONE then block_first(dirty_bb) == NONE else block_first(dirty_bb) == scan_pos;
        if !at_begin dep = md_call_dependency_from(md, call, is_readonly_call, scan_pos, dirty_bb);
        else dep = md_entry_result(md, dirty_bb);
        cache = *md.nl_per_inst[idx].deps;
        if existing >= 0 cache.*[existing].r = dep;
        else array_add(cache, .{dirty_bb, dep});
        if !mdr_is_nonlocal(dep) {
            if mdr_inst(dep) != NONE md_rev_insert(*md.rev_nl_deps, mdr_inst(dep), call);
        } else {
            for md_preds(md, dirty_bb) array_add(*dirty_blocks, it);
        }
    }
    return md.nl_per_inst[idx].deps;
}

md_is_visited :: (md: *Mem_Dep_Results, bb: Value_Id) -> bool {
    found, v := table_find(*md.visited, bb);
    return found && v.epoch == md.epoch;
}
md_set_visited :: (md: *Mem_Dep_Results, bb: Value_Id, v: Value_Id) { table_set(*md.visited, bb, .{v, md.epoch}); }
md_lookup_visited :: (md: *Mem_Dep_Results, bb: Value_Id) -> Value_Id { _, v := table_find(*md.visited, bb); return v.v; }

// getNonLocalPointerDependency(QueryInst, Result)
md_get_non_local_pointer_dependency :: (md: *Mem_Dep_Results, query: Value_Id, result: *[..] Nl_Result) {
    loc := mloc_get(query);
    is_load := inst_op(query) == .LOAD;
    from_bb := inst_block(query);
    result.count = 0;
    {
        found, d := table_find(*md.nl_defs_cache, query);
        if found {
            array_add(result, d);
            md_rev_remove(*md.rev_nl_defs_cache, mdr_inst(d.r), query);
            table_remove(*md.nl_defs_cache, query);
            return;
        }
    }
    ordered := false;
    if inst_op(query) == .LOAD || inst_op(query) == .STORE ordered = !is_unordered(query);
    if is_volatile(query) || ordered {
        r: Nl_Result; r.bb = from_bb; r.r = mdr_unknown(); r.addr = loc.ptr;
        array_add(result, r);
        return;
    }
    address := pta_make(loc.ptr, md.ac);
    md.epoch += 1;
    if md_non_local_pointer_dep_from_bb(md, query, *address, loc, is_load, from_bb, result, true) return;
    result.count = 0;
    r: Nl_Result; r.bb = from_bb; r.r = mdr_unknown(); r.addr = loc.ptr;
    array_add(result, r);
}

// getNonLocalInfoForBlock
md_non_local_info_for_block :: (md: *Mem_Dep_Results, query: Value_Id, loc: Mem_Loc, is_load: bool, bb: Value_Id,
                                cache_row: s64, num_sorted: s64, q: *Aa_Query) -> Mem_Dep {
    is_invariant_load := query != NONE && get_metadata(query, md_kind_id("invariant.load")) != NONE;
    cache := *md.nlp[cache_row].deps;
    existing := md_find_sorted(cache.*, num_sorted, bb);
    if existing >= 0 && is_invariant_load && !mdr_is_nonfunclocal(cache.*[existing].r) existing = -1;
    if existing >= 0 && !mdr_is_dirty(cache.*[existing].r) return cache.*[existing].r;
    scan_pos: Value_Id = NONE;
    if existing >= 0 && mdr_inst(cache.*[existing].r) != NONE {
        scan_pos = mdr_inst(cache.*[existing].r);
        md_rev_remove(*md.rev_nlp_deps, scan_pos, md_vil_key(loc.ptr, is_load));
    }
    dep := md_pointer_dependency_from(md, loc, is_load, scan_pos, bb, query, null, q);
    if is_invariant_load return dep;
    cache = *md.nlp[cache_row].deps;
    if existing >= 0 cache.*[existing].r = dep;
    else array_add(cache, .{bb, dep});
    if !mdr_is_local(dep) return dep;
    md_rev_insert(*md.rev_nlp_deps, mdr_inst(dep), md_vil_key(loc.ptr, is_load));
    return dep;
}

// SortNonLocalDepInfoCache
md_sort_non_local_dep_info_cache :: (cache: *[..] Nl_Entry, num_sorted: s64) {
    if cache.count < 2 return;
    s := cache.count - num_sorted;
    if s == 0 return;
    if num_sorted == 0 { md_sort_entries(cache); return; }
    md_sort_entries(cache);   // the insertion and full sorts give the same order (unique keys)
}

// NonLocalPointerDeps[CacheKey] (inserting a default info)
md_nlp_row :: (md: *Mem_Dep_Results, key: u64) -> s64 {
    found, idx := table_find(*md.nlp_index, key);
    if found return idx;
    e: Nl_Ptr_Info; e.deps.allocator = temp;
    idx = md.nlp.count;
    array_add(*md.nlp, e);
    table_add(*md.nlp_index, key, idx);
    return idx;
}

md_clear_nlp_deps :: (md: *Mem_Dep_Results, row: s64, key: u64) {
    for md.nlp[row].deps { ii := mdr_inst(it.r); if ii != NONE md_rev_remove(*md.rev_nlp_deps, ii, key); }
    md.nlp[row].deps.count = 0;
}

// getNonLocalPointerDepFromBB
md_non_local_pointer_dep_from_bb :: (md: *Mem_Dep_Results, query: Value_Id, pointer: *Phi_Trans_Addr, loc: Mem_Loc, is_load: bool,
                                     start_bb: Value_Id, result: *[..] Nl_Result, skip_first_block_in := false,
                                     is_incomplete_in := false) -> bool {
    skip_first_block := skip_first_block_in;
    is_incomplete := is_incomplete_in;
    cache_key := md_vil_key(pointer.addr, is_load);
    is_invariant_load := query != NONE && get_metadata(query, md_kind_id("invariant.load")) != NONE;

    inserted := !table_contains(*md.nlp_index, cache_key);
    row := md_nlp_row(md, cache_key);
    if inserted { md.nlp[row].size = loc.size; md.nlp[row].tags = loc.tags; }
    if !is_invariant_load && !inserted {
        ci := *md.nlp[row];
        if ci.size != loc.size {
            ci.pair_bb = NONE; ci.pair_skip = false;
            ci.size = loc.size;
            md_clear_nlp_deps(md, row, cache_key);
            is_incomplete = true;
        }
        ci = *md.nlp[row];
        if !aa_tags_eq(ci.tags, loc.tags) {
            if !aa_tags_empty(ci.tags) {
                ci.pair_bb = NONE; ci.pair_skip = false;
                ci.tags = .{};
                md_clear_nlp_deps(md, row, cache_key);
                is_incomplete = true;
            }
            if !aa_tags_empty(loc.tags) {
                l2 := loc; l2.tags = .{};
                return md_non_local_pointer_dep_from_bb(md, query, pointer, l2, is_load, start_bb, result, skip_first_block, is_incomplete);
            }
        }
    }

    cache_row := row;   // Cache (NONE = -1 after phi translation)
    if !is_incomplete && !is_invariant_load && md.nlp[row].pair_bb == start_bb && md.nlp[row].pair_skip == skip_first_block {
        for md.nlp[row].deps {
            if !md_is_visited(md, it.bb) continue;
            if md_lookup_visited(md, it.bb) == pointer.addr continue;
            return false;
        }
        addr := pointer.addr;
        for md.nlp[row].deps {
            md_set_visited(md, it.bb, addr);
            if mdr_is_nonlocal(it.r) continue;
            if dt_is_reachable_from_entry(md.dt, it.bb) {
                r: Nl_Result; r.bb = it.bb; r.r = it.r; r.addr = addr;
                array_add(result, r);
            }
        }
        return true;
    }
    if md.nlp[row].deps.count > md_opts.cache_global_limit return false;
    if !is_invariant_load {
        if !is_incomplete && md.nlp[row].deps.count == 0 { md.nlp[row].pair_bb = start_bb; md.nlp[row].pair_skip = skip_first_block; }
        else { md.nlp[row].pair_bb = NONE; md.nlp[row].pair_skip = false; }
    }

    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, start_bb);
    Pred_Entry :: struct { bb: Value_Id; p: Phi_Trans_Addr; }
    pred_list: [..] Pred_Entry; pred_list.allocator = temp;
    num_sorted := md.nlp[row].deps.count;
    worklist_entries := md_opts.block_number_limit;
    q := aa_query_new_sharing_ee(*md.aar, md.ee);

    while worklist.count {
        bb := pop(*worklist);
        if result.count > MD_NUM_RESULTS_LIMIT {
            if cache_row >= 0 && num_sorted != md.nlp[cache_row].deps.count md_sort_non_local_dep_info_cache(*md.nlp[cache_row].deps, num_sorted);
            md.nlp[row].pair_bb = NONE; md.nlp[row].pair_skip = false;
            return false;
        }
        if !skip_first_block {
            dep := md_non_local_info_for_block(md, query, loc, is_load, bb, cache_row, num_sorted, q);
            if !mdr_is_nonlocal(dep) {
                if dt_is_reachable_from_entry(md.dt, bb) {
                    r: Nl_Result; r.bb = bb; r.r = dep; r.addr = pointer.addr;
                    array_add(result, r);
                    continue;
                }
            }
        }

        failed := false;
        if !pta_needs_phi_translation_from_block(pointer, bb) {
            skip_first_block = false;
            new_blocks: [..] Value_Id; new_blocks.allocator = temp;
            for pred: md_preds(md, bb) {
                if !md_is_visited(md, pred) {
                    md_set_visited(md, pred, pointer.addr);
                    array_add(*new_blocks, pred);
                    continue;
                }
                prev := md_lookup_visited(md, pred);
                if prev != pointer.addr {
                    for new_blocks md_set_visited(md, it, NONE);
                    failed = true;
                    break;
                }
            }
            if !failed {
                if new_blocks.count > worklist_entries {
                    for new_blocks md_set_visited(md, it, NONE);
                    failed = true;
                } else {
                    worklist_entries -= new_blocks.count;
                    for new_blocks array_add(*worklist, it);
                    continue;
                }
            }
        } else if !pta_is_potentially_phi_translatable(pointer) {
            failed = true;
        } else {
            if cache_row >= 0 && num_sorted != md.nlp[cache_row].deps.count {
                md_sort_non_local_dep_info_cache(*md.nlp[cache_row].deps, num_sorted);
                num_sorted = md.nlp[cache_row].deps.count;
            }
            cache_row = -1;
            pred_list.count = 0;
            for pred: md_preds(md, bb) {
                pe: Pred_Entry; pe.bb = pred; pe.p = pta_copy(pointer.*);
                array_add(*pred_list, pe);
                pp := *pred_list[pred_list.count - 1].p;
                pred_ptr_val := pta_translate_value(pp, bb, pred, md.dt, false);
                if !md_is_visited(md, pred) {
                    md_set_visited(md, pred, pred_ptr_val);
                    continue;
                }
                prev_val := md_lookup_visited(md, pred);
                pred_list.count -= 1;
                if prev_val == pred_ptr_val continue;
                for pred_list md_set_visited(md, it.bb, NONE);
                failed = true;
                break;
            }
            if !failed {
                for * pe: pred_list {
                    pred := pe.bb;
                    pred_ptr_val := pe.p.addr;
                    can_translate := true;
                    if pred_ptr_val == NONE {
                        cond := pta_select_condition(*pe.p);
                        if cond != NONE {
                            orig := pta_copy(pointer.*);
                            st, sf := pta_translate_value_select(*orig, bb, pred, md.dt, cond);
                            if st != NONE && sf != NONE {
                                r: Nl_Result; r.bb = pred; r.r = mdr_select(); r.addr = cond; r.sel_t = st; r.sel_f = sf;
                                array_add(result, r);
                                nr := md_nlp_row(md, cache_key);
                                md.nlp[nr].pair_bb = NONE; md.nlp[nr].pair_skip = false;
                                continue;
                            }
                        }
                        can_translate = false;
                    }
                    ok := false;
                    if can_translate {
                        l2 := loc; l2.ptr = pred_ptr_val;
                        ok = md_non_local_pointer_dep_from_bb(md, query, *pe.p, l2, is_load, pred, result);
                    }
                    if !ok {
                        r: Nl_Result; r.bb = pred; r.r = mdr_unknown(); r.addr = pred_ptr_val;
                        array_add(result, r);
                        nr := md_nlp_row(md, cache_key);
                        md.nlp[nr].pair_bb = NONE; md.nlp[nr].pair_skip = false;
                        continue;
                    }
                }
                row = md_nlp_row(md, cache_key);
                cache_row = row;
                num_sorted = md.nlp[row].deps.count;
                md.nlp[row].pair_bb = NONE; md.nlp[row].pair_skip = false;
                skip_first_block = false;
                continue;
            }
        }

        // PredTranslationFailure:
        if cache_row < 0 {
            row = md_nlp_row(md, cache_key);
            cache_row = row;
            num_sorted = md.nlp[row].deps.count;
        }
        md.nlp[row].pair_bb = NONE; md.nlp[row].pair_skip = false;
        if skip_first_block return false;
        if !is_invariant_load {
            c := *md.nlp[cache_row].deps;
            for < k: 0..c.count-1 {
                if c.*[k].bb != bb continue;
                c.*[k].r = mdr_unknown();
                break;
            }
        }
        r: Nl_Result; r.bb = bb; r.r = mdr_unknown(); r.addr = pointer.addr;
        array_add(result, r);
    }
    md_sort_non_local_dep_info_cache(*md.nlp[cache_row].deps, num_sorted);
    return true;
}

aa_tags_eq :: (a: AA_Tags, b: AA_Tags) -> bool {
    return a.tbaa == b.tbaa && a.tbaa_struct == b.tbaa_struct && a.scope == b.scope && a.noalias == b.noalias && a.noalias_as == b.noalias_as;
}
aa_tags_empty :: (a: AA_Tags) -> bool { return aa_tags_eq(a, .{}); }

// removeCachedNonLocalPointerDependencies
md_remove_cached_non_local_pointer_dependencies :: (md: *Mem_Dep_Results, key: u64) {
    p := md_vil_ptr(key);
    if md.nl_defs_cache.count {
        found, d := table_find(*md.nl_defs_cache, p);
        if found {
            md_rev_remove(*md.rev_nl_defs_cache, mdr_inst(d.r), p);
            table_remove(*md.nl_defs_cache, p);
        }
        if is_inst(p) {
            rp := table_find_pointer(*md.rev_nl_defs_cache, p);
            if rp {
                for rp.* table_remove(*md.nl_defs_cache, it);
                table_remove(*md.rev_nl_defs_cache, p);
            }
        }
    }
    found, row := table_find(*md.nlp_index, key);
    if !found return;
    for md.nlp[row].deps {
        t := mdr_inst(it.r);
        if t == NONE continue;
        md_rev_remove(*md.rev_nlp_deps, t, key);
    }
    md.nlp[row].deps.count = 0;
    table_remove(*md.nlp_index, key);
}

// invalidateCachedPointerInfo
md_invalidate_cached_pointer_info :: (md: *Mem_Dep_Results, ptr: Value_Id) {
    if type_kind(vtype(ptr)) != .PTR return;
    md_remove_cached_non_local_pointer_dependencies(md, md_vil_key(ptr, false));
    md_remove_cached_non_local_pointer_dependencies(md, md_vil_key(ptr, true));
}
// invalidateCachedPredecessors
md_invalidate_cached_predecessors :: (md: *Mem_Dep_Results) { table_reset(*md.pred_cache); }

// getClobberOffset
md_get_clobber_offset :: (md: *Mem_Dep_Results, li: Value_Id) -> (bool, s32) {
    found, v := table_find(*md.clobber_offsets, li);
    return found, v;
}

// removeInstruction(RemInst)
md_remove_instruction :: (md: *Mem_Dep_Results, rem: Value_Id) {
    aa_query_remove_instruction(md.ee, rem);   // EEA.removeInstruction
    {
        found, idx := table_find(*md.nl_deps_index, rem);
        if found {
            for md.nl_per_inst[idx].deps { ii := mdr_inst(it.r); if ii != NONE md_rev_remove(*md.rev_nl_deps, ii, rem); }
            md.nl_per_inst[idx].deps.count = 0;
            table_remove(*md.nl_deps_index, rem);
        }
    }
    {
        found, ld := table_find(*md.local_deps, rem);
        if found {
            if mdr_inst(ld) != NONE md_rev_remove(*md.rev_local_deps, mdr_inst(ld), rem);
            table_remove(*md.local_deps, rem);
        }
    }
    if type_kind(vtype(rem)) == .PTR {
        md_remove_cached_non_local_pointer_dependencies(md, md_vil_key(rem, false));
        md_remove_cached_non_local_pointer_dependencies(md, md_vil_key(rem, true));
    } else {
        found, d := table_find(*md.nl_defs_cache, rem);
        if found {
            dv := mdr_inst(d.r);
            rp := table_find_pointer(*md.rev_nl_defs_cache, dv);
            if rp for rp.* if it == rem { array_unordered_remove_by_index(rp, it_index); break; }
            table_remove(*md.nl_defs_cache, rem);
        }
    }
    Pair :: struct { a: Value_Id; b: Value_Id; }
    to_add: [..] Pair; to_add.allocator = temp;
    new_dirty: Mem_Dep;
    if !is_terminator(inst_op(rem)) new_dirty = mdr_dirty(inst_next(rem));
    {
        found, set := table_find(*md.rev_local_deps, rem);
        if found {
            for dep_inst: set {
                table_set(*md.local_deps, dep_inst, new_dirty);
                array_add(*to_add, .{new_dirty.inst, dep_inst});
            }
            table_remove(*md.rev_local_deps, rem);
            while to_add.count { p := pop(*to_add); md_rev_insert(*md.rev_local_deps, p.a, p.b); }
        }
    }
    {
        found, set := table_find(*md.rev_nl_deps, rem);
        if found {
            for i: set {
                idx: s64;
                f2, x := table_find(*md.nl_deps_index, i);
                if f2 idx = x;
                else {
                    e: Per_Inst_Nl; e.deps.allocator = temp;
                    idx = md.nl_per_inst.count;
                    array_add(*md.nl_per_inst, e);
                    table_add(*md.nl_deps_index, i, idx);
                }
                md.nl_per_inst[idx].dirty = true;
                for * e: md.nl_per_inst[idx].deps {
                    if mdr_inst(e.r) != rem continue;
                    e.r = new_dirty;
                    if new_dirty.inst != NONE array_add(*to_add, .{new_dirty.inst, i});
                }
            }
            table_remove(*md.rev_nl_deps, rem);
            while to_add.count { p := pop(*to_add); md_rev_insert(*md.rev_nl_deps, p.a, p.b); }
        }
    }
    {
        found, set := table_find(*md.rev_nlp_deps, rem);
        if found {
            Pair2 :: struct { a: Value_Id; k: u64; }
            to_add2: [..] Pair2; to_add2.allocator = temp;
            for key: set {
                row := md_nlp_row(md, key);
                md.nlp[row].pair_bb = NONE; md.nlp[row].pair_skip = false;
                for * e: md.nlp[row].deps {
                    if mdr_inst(e.r) != rem continue;
                    e.r = new_dirty;
                    if new_dirty.inst != NONE array_add(*to_add2, .{new_dirty.inst, key});
                }
                md_sort_entries(*md.nlp[row].deps);
            }
            table_remove(*md.rev_nlp_deps, rem);
            while to_add2.count { p := pop(*to_add2); md_rev_insert(*md.rev_nlp_deps, p.a, p.k); }
        }
    }
}
