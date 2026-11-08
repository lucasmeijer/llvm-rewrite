// AliasSetTracker: port of llvm/lib/Analysis/AliasSetTracker.cpp and llvm/include/llvm/Analysis/AliasSetTracker.h
// (alias sets with forwarding and reference counts, merging, saturation (-alias-set-saturation-threshold), the add()
// dispatch for loads, stores, va_arg, memset/memcpy and argmemonly calls, unknown instructions,
// aliasesMemoryLocation / aliasesUnknownInst). The printer (print<alias-sets>) is not ported: LLVM prints pointers.
//
// An AliasSet is a row of `ast.sets` (the tracker's ilist order = row order; removed sets keep their row with
// `removed`); `forward` is a row index. Every query goes through the tracker's BatchAAResults (`q`).

AST_NO_ACCESS :: 0; AST_REF_ACCESS :: 1; AST_MOD_ACCESS :: 2; AST_MODREF_ACCESS :: 3;

ast_opts: struct { saturation_threshold: s64 = 250; };   // -alias-set-saturation-threshold

Alias_Set :: struct {
    locs: [..] Mem_Loc;            // MemoryLocs
    unknown: [..] Value_Id;        // UnknownInsts
    ref_count: s64;
    forward: s32 = -1;
    access: u8;                    // AccessLattice
    may_alias: bool;               // Alias == SetMayAlias
    alias_any: bool;
    removed: bool;
}

Alias_Set_Tracker :: struct {
    q: *Aa_Query;
    sets: [..] Alias_Set;
    pointer_map: Table(Value_Id, s32);
    alias_any_as: s32 = -1;
    total_size: s64;
}

ast_init :: (t: *Alias_Set_Tracker, q: *Aa_Query) {
    t.q = q;
    t.sets.allocator = temp;
    t.pointer_map.allocator = temp;
}
ast_new_set :: (t: *Alias_Set_Tracker) -> s32 {
    s: Alias_Set;
    s.locs.allocator = temp; s.unknown.allocator = temp;
    array_add(*t.sets, s);
    return cast(s32)(t.sets.count - 1);
}
ast_is_must_alias :: (s: *Alias_Set) -> bool { return !s.may_alias; }
ast_is_mod :: (s: *Alias_Set) -> bool { return (s.access & AST_MOD_ACCESS) != 0; }
ast_is_ref :: (s: *Alias_Set) -> bool { return (s.access & AST_REF_ACCESS) != 0; }
ast_add_ref :: (t: *Alias_Set_Tracker, s: s32) { t.sets[s].ref_count += 1; }
// dropRef
ast_drop_ref :: (t: *Alias_Set_Tracker, s: s32) {
    assert(t.sets[s].ref_count >= 1, "Invalid reference count detected!");
    t.sets[s].ref_count -= 1;
    if t.sets[s].ref_count == 0 ast_remove_alias_set(t, s);
}
// removeAliasSet
ast_remove_alias_set :: (t: *Alias_Set_Tracker, s: s32) {
    fwd := t.sets[s].forward;
    if fwd >= 0 {
        ast_drop_ref(t, fwd);
        t.sets[s].forward = -1;
    } else t.total_size -= t.sets[s].locs.count;
    t.sets[s].removed = true;
    if s == t.alias_any_as t.alias_any_as = -1;
}
// collapseForwardingIn
ast_collapse_forwarding_in :: (t: *Alias_Set_Tracker, s: *s32) {
    fwd := t.sets[s.*].forward;
    if fwd >= 0 {
        ast_collapse_forwarding_in(t, *t.sets[s.*].forward);
        ns := t.sets[s.*].forward;
        ast_add_ref(t, ns);
        ast_drop_ref(t, s.*);
        s.* = ns;
    }
}
mem_loc_eq_ast :: (a: Mem_Loc, b: Mem_Loc) -> bool { return mem_loc_eq(a, b); }
ast_is_must :: (t: *Alias_Set_Tracker, a: Mem_Loc, b: Mem_Loc) -> bool { return aa_alias(t.q, a, b).kind == AR_MUST; }

// AliasSet::mergeSetIn
ast_merge_set_in :: (t: *Alias_Set_Tracker, dst: s32, src: s32) {
    d := *t.sets[dst]; s := *t.sets[src];
    assert(s.forward < 0 && d.forward < 0, "Alias set is already forwarding!");
    d.access |= s.access;
    d.may_alias = d.may_alias || s.may_alias;
    if !d.may_alias {
        found := false;
        for a: d.locs { for b: s.locs if ast_is_must(t, a, b) { found = true; break; } if found break; }
        d = *t.sets[dst]; s = *t.sets[src];
        if !found d.may_alias = true;
    }
    if d.locs.count == 0 {
        tmp := d.locs; d.locs = s.locs; s.locs = tmp;
    } else {
        for s.locs array_add(*d.locs, it);
        s.locs.count = 0;
    }
    had_unknown := s.unknown.count > 0;
    if d.unknown.count == 0 {
        if had_unknown {
            tmp := d.unknown; d.unknown = s.unknown; s.unknown = tmp;
            ast_add_ref(t, dst);
        }
    } else if had_unknown {
        for s.unknown array_add(*d.unknown, it);
        s.unknown.count = 0;
    }
    t.sets[src].forward = dst;
    ast_add_ref(t, dst);
    if had_unknown ast_drop_ref(t, src);
}

// AliasSet::addMemoryLocation
ast_set_add_memory_location :: (t: *Alias_Set_Tracker, s: s32, loc: Mem_Loc, known_must_alias: bool) {
    if ast_is_must_alias(*t.sets[s]) && !known_must_alias {
        found := false;
        for t.sets[s].locs if ast_is_must(t, loc, it) { found = true; break; }
        if !found t.sets[s].may_alias = true;
    }
    array_add(*t.sets[s].locs, loc);
    t.total_size += 1;
}
// AliasSet::addUnknownInst
ast_set_add_unknown_inst :: (t: *Alias_Set_Tracker, s: s32, i: Value_Id) {
    if t.sets[s].unknown.count == 0 ast_add_ref(t, s);
    array_add(*t.sets[s].unknown, i);
    may_write := may_write_to_memory(i) && !is_guard(i) && !(!has_uses(i) && call_iid(i) == IID_INVARIANT_START);
    if !may_write {
        t.sets[s].may_alias = true;
        t.sets[s].access |= AST_REF_ACCESS;
        return;
    }
    t.sets[s].may_alias = true;
    t.sets[s].access = AST_MODREF_ACCESS;
}
// AliasSet::aliasesMemoryLocation
ast_aliases_memory_location :: (t: *Alias_Set_Tracker, s: s32, loc: Mem_Loc) -> Alias_Result {
    if t.sets[s].alias_any return ar(AR_MAY);
    for t.sets[s].locs {
        ar := aa_alias(t.q, loc, it);
        if ar.kind != AR_NO return ar;
    }
    for t.sets[s].unknown if aa_mod_ref_inst_loc(t.q, it, loc) != MR_NO return ar(AR_MAY);
    return ar(AR_NO);
}
// AliasSet::aliasesUnknownInst
ast_aliases_unknown_inst :: (t: *Alias_Set_Tracker, s: s32, i: Value_Id) -> u8 {
    if t.sets[s].alias_any return MR_MODREF;
    if !may_read_or_write_memory(i) return MR_NO;
    for ui: t.sets[s].unknown {
        c1 := is_call_base(ui); c2 := is_call_base(i);
        if !c1 || !c2 || aa_mod_ref_call_call(t.q, ui, i) != MR_NO || aa_mod_ref_call_call(t.q, i, ui) != MR_NO return MR_MODREF;
    }
    mr: u8 = MR_NO;
    for t.sets[s].locs {
        mr |= aa_mod_ref_inst_loc(t.q, i, it);
        if mr == MR_MODREF return mr;
    }
    return mr;
}

// mergeAliasSetsForMemoryLocation
ast_merge_alias_sets_for_memory_location :: (t: *Alias_Set_Tracker, loc: Mem_Loc, ptr_as: s32, must_alias_all: *bool) -> s32 {
    found: s32 = -1;
    must_alias_all.* = true;
    n := t.sets.count;
    for k: 0..n-1 {
        s := cast(s32) k;
        if t.sets[s].removed || t.sets[s].forward >= 0 continue;
        if s != ptr_as {
            ar := ast_aliases_memory_location(t, s, loc);
            if ar.kind == AR_NO continue;
            if ar.kind != AR_MUST must_alias_all.* = false;
        }
        if found < 0 found = s;
        else ast_merge_set_in(t, found, s);
    }
    return found;
}
// findAliasSetForUnknownInst
ast_find_alias_set_for_unknown_inst :: (t: *Alias_Set_Tracker, i: Value_Id) -> s32 {
    found: s32 = -1;
    n := t.sets.count;
    for k: 0..n-1 {
        s := cast(s32) k;
        if t.sets[s].removed || t.sets[s].forward >= 0 || ast_aliases_unknown_inst(t, s, i) == MR_NO continue;
        if found < 0 found = s;
        else ast_merge_set_in(t, found, s);
    }
    return found;
}
// getAliasSetFor
ast_get_alias_set_for :: (t: *Alias_Set_Tracker, loc: Mem_Loc) -> s32 {
    has_entry, entry := table_find(*t.pointer_map, loc.ptr);
    if has_entry {
        ast_collapse_forwarding_in(t, *entry);
        table_set(*t.pointer_map, loc.ptr, entry);
        for t.sets[entry].locs if mem_loc_eq(it, loc) return entry;
    }
    s: s32;
    must_alias_all := false;
    if t.alias_any_as >= 0 s = t.alias_any_as;
    else {
        m := ast_merge_alias_sets_for_memory_location(t, loc, ifx has_entry then entry else -1, *must_alias_all);
        if m >= 0 s = m;
        else { s = ast_new_set(t); must_alias_all = true; }
    }
    ast_set_add_memory_location(t, s, loc, must_alias_all);
    if has_entry {
        ast_collapse_forwarding_in(t, *entry);
        table_set(*t.pointer_map, loc.ptr, entry);
        assert(entry == s, "Memory locations with same pointer value cannot be in different alias sets");
    } else {
        ast_add_ref(t, s);
        table_set(*t.pointer_map, loc.ptr, s);
    }
    return s;
}
// mergeAllAliasSets
ast_merge_all_alias_sets :: (t: *Alias_Set_Tracker) -> s32 {
    vec: [..] s32; vec.allocator = temp;
    for t.sets if !it.removed array_add(*vec, cast(s32) it_index);
    a := ast_new_set(t);
    t.alias_any_as = a;
    t.sets[a].may_alias = true;
    t.sets[a].access = AST_MODREF_ACCESS;
    t.sets[a].alias_any = true;
    for cur: vec {
        fwd := t.sets[cur].forward;
        if fwd >= 0 {
            t.sets[cur].forward = a;
            ast_add_ref(t, a);
            ast_drop_ref(t, fwd);
            continue;
        }
        ast_merge_set_in(t, a, cur);
    }
    return a;
}
// addMemoryLocation(Loc, E)
ast_add_memory_location :: (t: *Alias_Set_Tracker, loc: Mem_Loc, e: u8) -> s32 {
    s := ast_get_alias_set_for(t, loc);
    t.sets[s].access |= e;
    if t.alias_any_as < 0 && t.total_size > ast_opts.saturation_threshold return ast_merge_all_alias_sets(t);
    return s;
}
// addUnknown
ast_add_unknown :: (t: *Alias_Set_Tracker, i: Value_Id) {
    if is_call_base(i) {
        id := call_iid(i);
        if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_ASSUME ||
           id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_SIDEEFFECT || id == IID_PSEUDOPROBE return;
    }
    if !may_read_or_write_memory(i) return;
    s := ast_find_alias_set_for_unknown_inst(t, i);
    if s >= 0 { ast_set_add_unknown_inst(t, s, i); return; }
    s = ast_new_set(t);
    ast_set_add_unknown_inst(t, s, i);
}
// add(Instruction *I)
ast_add :: (t: *Alias_Set_Tracker, i: Value_Id) {
    o := inst_op(i);
    if o == .LOAD || o == .STORE {
        if inst(i).ord1 > ORD_MONOTONIC { ast_add_unknown(t, i); return; }   // isStrongerThanMonotonic
        ast_add_memory_location(t, mloc_get(i), ifx o == .LOAD then cast(u8) AST_REF_ACCESS else AST_MOD_ACCESS);
        return;
    }
    if o == .VAARG { ast_add_memory_location(t, mloc_get(i), AST_MODREF_ACCESS); return; }
    if ast_is_any_mem_set(i) { ast_add_memory_location(t, mloc_for_dest(i), AST_MOD_ACCESS); return; }
    if ast_is_any_mem_transfer(i) {
        ast_add_memory_location(t, mloc_for_dest(i), AST_MOD_ACCESS);
        ast_add_memory_location(t, mloc_for_source(i), AST_REF_ACCESS);
        return;
    }
    if is_call_base(i) && me_only_accesses_arg_pointees(call_memory_effects(i)) {
        call_mask := me_mod_ref(aa_memory_effects_call(t.q, i));
        if !has_uses(i) && call_iid(i) == IID_INVARIANT_START call_mask &= MR_REF;
        n := call_num_args(i);
        for k: 0..cast(s64) n - 1 {
            arg := op(i, cast(u32) k);
            if type_kind(vtype(arg)) != .PTR continue;
            arg_loc := mloc_for_argument(i, cast(u32) k, false);
            arg_mask := aa_arg_mod_ref(t.q, i, cast(u32) k) & call_mask;
            if arg_mask != MR_NO {
                acc: u8 = AST_NO_ACCESS;
                if (arg_mask & MR_REF) && (arg_mask & MR_MOD) acc = AST_MODREF_ACCESS;
                else if arg_mask & MR_MOD acc = AST_MOD_ACCESS;
                else if arg_mask & MR_REF acc = AST_REF_ACCESS;
                ast_add_memory_location(t, arg_loc, acc);
            }
        }
        return;
    }
    ast_add_unknown(t, i);
}

// isa<AnyMemSetInst> / isa<AnyMemTransferInst>
ast_is_any_mem_set :: (i: Value_Id) -> bool {
    if !is_call_base(i) return false;
    id := call_iid(i);
    return id == IID_MEMSET || id == IID_MEMSET_INLINE || id == IID_MEMSET_ELEMENT_UNORDERED_ATOMIC;
}
ast_is_any_mem_transfer :: (i: Value_Id) -> bool {
    if !is_call_base(i) return false;
    id := call_iid(i);
    return id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE ||
           id == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || id == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC;
}
