// RewriteStatepointsForGC: a port of llvm/lib/Transforms/Scalar/RewriteStatepointsForGC.cpp (liveness, base pointer
// inference with the BDVState fixpoint, rematerialization, statepoint / gc.relocate / gc.result creation,
// relocationViaAlloca + PromoteMemToReg, stripping of invalid attributes and metadata), the IRBuilder statepoint
// helpers of llvm/lib/IR/IRBuilder.cpp (CreateGCStatepointCall/Invoke, CreateGCResult), parseStatepointDirectives
// of llvm/lib/IR/Statepoint.cpp, the statepoint GC strategies of llvm/lib/IR/BuiltinGCs.cpp and callsGCLeafFunction
// (llvm/lib/Transforms/Utils/Local.cpp).
//
// MapVector / SetVector are insertion-ordered arrays with a hash index (`Rs_Map`, `Rs_Set`). The DenseMaps LLVM
// iterates (relocationViaAlloca's AllocaMap) only decide the order of loads and stores that PromoteMemToReg removes
// again, so their order is not modelled.

rs_cl: struct {
    print_liveset := false;              // -spp-print-liveset
    print_liveset_size := false;         // -spp-print-liveset-size
    print_base_pointers := false;        // -spp-print-base-pointers
    remat_threshold: s64 = 6;            // -spp-rematerialization-threshold
    clobber_non_live := false;           // -rs4gc-clobber-non-live
    allow_no_deopt := true;              // -rs4gc-allow-statepoint-with-no-deopt-info
    remat_derived_at_uses := true;       // -rs4gc-remat-derived-at-uses
};
rs4gc_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "spp-print-liveset"; rs_cl.print_liveset = smisc_bool(name, value, has_value);
        case "spp-print-liveset-size"; rs_cl.print_liveset_size = smisc_bool(name, value, has_value);
        case "spp-print-base-pointers"; rs_cl.print_base_pointers = smisc_bool(name, value, has_value);
        case "spp-rematerialization-threshold"; rs_cl.remat_threshold = smisc_int(name, value, has_value);
        case "rs4gc-clobber-non-live"; rs_cl.clobber_non_live = smisc_bool(name, value, has_value);
        case "rs4gc-allow-statepoint-with-no-deopt-info"; rs_cl.allow_no_deopt = smisc_bool(name, value, has_value);
        case "rs4gc-remat-derived-at-uses"; rs_cl.remat_derived_at_uses = smisc_bool(name, value, has_value);
        case; return false;
    }
    return true;
}

IID_GC_RESULT :: #run iid_by_name("llvm.experimental.gc.result");
IID_GC_GET_POINTER_BASE :: #run iid_by_name("llvm.experimental.gc.get.pointer.base");
IID_GC_GET_POINTER_OFFSET :: #run iid_by_name("llvm.experimental.gc.get.pointer.offset");
IID_GCROOT :: #run iid_by_name("llvm.gcroot");
IID_PATCHPOINT_VOID :: #run iid_by_name("llvm.experimental.patchpoint.void");
IID_PATCHPOINT :: #run iid_by_name("llvm.experimental.patchpoint");

// ---------------------------------------------------------------- GC strategies (BuiltinGCs.cpp)

// getGCStrategy(Name)->useRS4GC(): statepoint-example and coreclr; the gc.root strategies don't; others are fatal
gc_strategy_uses_rs4gc :: (name: string) -> bool {
    if name == "statepoint-example" || name == "coreclr" return true;
    if name == "erlang" || name == "ocaml" || name == "shadow-stack" return false;
    fatal(tprint("unsupported GC: %", name));
    return false;
}
fn_has_gc :: (f: Value_Id) -> bool { return glob(f).gc.count > 0; }

// isGCPointerType: both statepoint strategies manage addrspace(1)
rs_is_gc_pointer_type :: (t: Type_Id) -> bool { return is_ptr_type(t) && ptr_addrspace(t) == 1; }
rs_is_handled_gc_pointer_type :: (t: Type_Id) -> bool {
    if rs_is_gc_pointer_type(t) return true;
    if is_vector_type(t) && rs_is_gc_pointer_type(type_elem(t)) return true;
    return false;
}
// containsGCPtrType / isUnhandledGCPointerType (asserts in LLVM: fail loudly here)
rs_contains_gc_ptr_type :: (t: Type_Id) -> bool {
    if rs_is_gc_pointer_type(t) return true;
    if is_vector_type(t) return rs_is_gc_pointer_type(type_elem(t));
    k := type_kind(t);
    if k == .ARRAY return rs_contains_gc_ptr_type(type_elem(t));
    if k == .STRUCT { n := type_nsub(t); if n > 0 for i: 0..n-1 if rs_contains_gc_ptr_type(type_sub(t, i)) return true; }
    return false;
}
// (an assert in LLVM; a release build ignores such values, which are then never live or relocated)
rs_check_handled :: (t: Type_Id) {}

// callsGCLeafFunction (Local.cpp)
calls_gc_leaf_function :: (call: Value_Id) -> bool {
    if call_has_fn_attr_str(call, "gc-leaf-function") return true;
    f := call_called_function(call);
    if f != NONE {
        if attr_set_has_str(attr_list_fn(glob(f).attrs), "gc-leaf-function") return true;
        id := fn_iid(f);
        if id != NOT_INTRINSIC
            return id != IID_EXPERIMENTAL_GC_STATEPOINT && id != IID_EXPERIMENTAL_DEOPTIMIZE &&
                   id != IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC && id != IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC;
    }
    return tli_lib_func_of_call(call) != "";
}
// CallBase::hasFnAttr(StringRef): call site, then the called function
call_has_fn_attr_str :: (c: Value_Id, key: string) -> bool {
    if attr_set_has_str(attr_list_fn(inst(c).attrs), key) return true;
    f := call_called_operand_fn(c);
    return f != NONE && attr_set_has_str(attr_list_fn(glob(f).attrs), key);
}
attr_set_str_value :: (s: u32, key: string) -> (bool, string) {
    for attr_set_items(s) if it.kind == .STRING_ATTR && it.key == key return true, it.val;
    return false, "";
}

// ---------------------------------------------------------------- ordered containers

// SetVector<Value *>
Rs_Set :: struct { list: [..] Value_Id; set: Table(Value_Id, bool); }
rs_set_init :: (s: *Rs_Set) { s.list.allocator = temp; s.set.allocator = temp; }
rs_set_insert :: (s: *Rs_Set, v: Value_Id) -> bool {
    if s.list.allocator.proc == null rs_set_init(s);
    if table_contains(*s.set, v) return false;
    table_set(*s.set, v, true);
    array_add(*s.list, v);
    return true;
}
rs_set_contains :: (s: *Rs_Set, v: Value_Id) -> bool { return s.set.count > 0 && table_contains(*s.set, v); }
rs_set_remove :: (s: *Rs_Set, v: Value_Id) -> bool {
    if !rs_set_contains(s, v) return false;
    table_remove(*s.set, v);
    for s.list if it == v { array_ordered_remove_by_index(*s.list, it_index); break; }
    return true;
}
rs_set_copy :: (s: *Rs_Set) -> Rs_Set {
    r: Rs_Set; rs_set_init(*r);
    for s.list rs_set_insert(*r, it);
    return r;
}
rs_set_clear :: (s: *Rs_Set) { s.list.count = 0; if s.set.count table_reset(*s.set); }
rs_set_union :: (s: *Rs_Set, o: *Rs_Set) { for o.list rs_set_insert(s, it); }
rs_set_subtract :: (s: *Rs_Set, o: *Rs_Set) {
    if s.list.count == 0 || o.list.count == 0 return;
    // SetVector::set_subtract: remove each element of o (vector order kept)
    any := false;
    for o.list if rs_set_contains(s, it) { table_remove(*s.set, it); any = true; }
    if !any return;
    w := 0;
    for s.list if table_contains(*s.set, it) { s.list[w] = it; w += 1; }
    s.list.count = w;
}
rs_set_pop_back :: (s: *Rs_Set) -> Value_Id {
    v := pop(*s.list);
    table_remove(*s.set, v);
    return v;
}

// MapVector<Value *, Value *>
Rs_Map :: struct { keys: [..] Value_Id; vals: [..] Value_Id; index: Table(Value_Id, s64); }
rs_map_init :: (m: *Rs_Map) { m.keys.allocator = temp; m.vals.allocator = temp; m.index.allocator = temp; }
rs_map_find :: (m: *Rs_Map, k: Value_Id) -> (bool, Value_Id) {
    p := table_find_pointer(*m.index, k);
    if !p return false, NONE;
    return true, m.vals[p.*];
}
rs_map_contains :: (m: *Rs_Map, k: Value_Id) -> bool { return table_contains(*m.index, k); }
rs_map_set :: (m: *Rs_Map, k: Value_Id, v: Value_Id) {
    p := table_find_pointer(*m.index, k);
    if p { m.vals[p.*] = v; return; }
    table_set(*m.index, k, m.keys.count);
    array_add(*m.keys, k); array_add(*m.vals, v);
}
// insert({K, V}): no overwrite
rs_map_insert :: (m: *Rs_Map, k: Value_Id, v: Value_Id) { if !rs_map_contains(m, k) rs_map_set(m, k, v); }
rs_map_get :: (m: *Rs_Map, k: Value_Id) -> Value_Id {
    ok, v := rs_map_find(m, k);
    assert(ok, "rewrite-statepoints-for-gc: missing map entry");
    return v;
}

// ---------------------------------------------------------------- liveness (computeLiveInValues & co)

Rs_Liveness :: struct {
    index: Table(Value_Id, s64);
    kill: [..] Rs_Set;
    live: [..] Rs_Set;
    live_in: [..] Rs_Set;
    live_out: [..] Rs_Set;
}
rs_lv_index :: (d: *Rs_Liveness, bb: Value_Id) -> s64 {
    p := table_find_pointer(*d.index, bb);
    assert(p != null);
    return p.*;
}

// computeLiveInValues(Begin, End, LiveTmp): instructions from `from` backwards to `stop` (exclusive; NONE = block start)
rs_live_in_range :: (from: Value_Id, stop: Value_Id, live: *Rs_Set) {
    i := from;
    while i != NONE && i != stop {
        rs_set_remove(live, i);
        if inst_op(i) != .PHI {
            n := nops(i);
            if n > 0 for k: 0..n-1 {
                v := op(i, k);
                if v == NONE continue;
                rs_check_handled(vtype(v));
                if rs_is_handled_gc_pointer_type(vtype(v)) && !is_const(v) rs_set_insert(live, v);
            }
        }
        i = inst(i).prev;
    }
}
// computeLiveOutSeed
rs_live_out_seed :: (bb: Value_Id, live: *Rs_Set) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs {
        for i: block_insts(s) {
            if inst_op(i) != .PHI break;
            v := phi_incoming_value_for_block(i, bb);
            rs_check_handled(vtype(v));
            if rs_is_handled_gc_pointer_type(vtype(v)) && !is_const(v) rs_set_insert(live, v);
        }
    }
}
// computeLiveInValues(DT, F, Data)
rs_compute_live_in_values :: (f: Value_Id, d: *Rs_Liveness) {
    d.index.allocator = temp; d.kill.allocator = temp; d.live.allocator = temp; d.live_in.allocator = temp; d.live_out.allocator = temp;
    wl: Rs_Set; rs_set_init(*wl);
    preds: [..] Value_Id; preds.allocator = temp;
    for bb: fn_blocks(f) {
        idx := d.kill.count;
        table_set(*d.index, bb, idx);
        kill: Rs_Set; rs_set_init(*kill);
        for i: block_insts(bb) if rs_is_handled_gc_pointer_type(vtype(i)) rs_set_insert(*kill, i);
        array_add(*d.kill, kill);
        live: Rs_Set; rs_set_init(*live);
        rs_live_in_range(block(bb).last, NONE, *live);
        array_add(*d.live, live);
        out: Rs_Set; rs_set_init(*out);
        rs_live_out_seed(bb, *out);
        array_add(*d.live_out, out);
        in := rs_set_copy(*d.live[idx]);
        rs_set_union(*in, *d.live_out[idx]);
        rs_set_subtract(*in, *d.kill[idx]);
        array_add(*d.live_in, in);
        if in.list.count {
            preds.count = 0; block_predecessors(bb, *preds);
            for preds rs_set_insert(*wl, it);
        }
    }
    succs: [..] Value_Id; succs.allocator = temp;
    while wl.list.count {
        bb := rs_set_pop_back(*wl);
        idx := rs_lv_index(d, bb);
        out := *d.live_out[idx];
        old := out.list.count;
        succs.count = 0; block_successors(bb, *succs);
        for s: succs rs_set_union(out, *d.live_in[rs_lv_index(d, s)]);
        if old == out.list.count continue;
        tmp := rs_set_copy(out);
        rs_set_union(*tmp, *d.live[idx]);
        rs_set_subtract(*tmp, *d.kill[idx]);
        if d.live_in[idx].list.count != tmp.list.count {
            d.live_in[idx] = tmp;
            preds.count = 0; block_predecessors(bb, *preds);
            for preds rs_set_insert(*wl, it);
        }
    }
}
// findLiveSetAtInst
rs_find_live_set_at_inst :: (i: Value_Id, d: *Rs_Liveness, out: *Rs_Set) {
    bb := inst_block(i);
    live := rs_set_copy(*d.live_out[rs_lv_index(d, bb)]);
    rs_live_in_range(block(bb).last, inst(i).prev, *live);
    rs_set_remove(*live, i);
    for live.list rs_set_insert(out, it);
}

// ---------------------------------------------------------------- base pointers

Rs_State :: struct {
    f: Value_Id;
    dv_cache: Table(Value_Id, Value_Id);   // DefiningValueMapTy (lookups only)
    known_bases: Table(Value_Id, bool);    // IsKnownBaseMapTy (lookups only)
}

rs_set_known_base :: (s: *Rs_State, v: Value_Id, b: bool) { table_set(*s.known_bases, v, b); }
rs_is_known_base :: (s: *Rs_State, v: Value_Id) -> bool {
    p := table_find_pointer(*s.known_bases, v);
    assert(p != null, "Value not present in the map");
    return p.*;
}
rs_cache_set :: (s: *Rs_State, k: Value_Id, v: Value_Id) { table_set(*s.dv_cache, k, v); }
rs_both_vector_or_scalar :: (a: Value_Id, b: Value_Id) -> bool { return is_vector_type(vtype(a)) == is_vector_type(vtype(b)); }
rs_is_cast :: (i: Value_Id) -> bool { o := inst_op(i); return o >= .TRUNC && o <= .ADDRSPACECAST; }

// findBaseDefiningValueOfVector
rs_fbdv_vector :: (s: *Rs_State, i: Value_Id) -> Value_Id {
    p := table_find_pointer(*s.dv_cache, i);
    if p return p.*;
    if vkind(i) == .ARGUMENT { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if is_const(i) {
        caz := const_zero(vtype(i));
        rs_cache_set(s, i, caz); rs_set_known_base(s, caz, true); return caz;
    }
    o := inst_op(i);
    if o == .LOAD { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if o == .INSERTELEMENT || o == .SHUFFLEVECTOR { rs_cache_set(s, i, i); rs_set_known_base(s, i, false); return i; }
    if o == .GEP || o == .FREEZE || o == .BITCAST {
        bdv := rs_fbdv(s, op(i, 0));
        rs_cache_set(s, i, bdv);
        return bdv;
    }
    if o == .CALL || o == .INVOKE { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if o != .SELECT && o != .PHI fatal("rewrite-statepoints-for-gc: unknown vector instruction - no base found for vector element");
    rs_cache_set(s, i, i);
    rs_set_known_base(s, i, false);
    return i;
}

// findBaseDefiningValue
rs_fbdv :: (s: *Rs_State, i: Value_Id) -> Value_Id {
    p := table_find_pointer(*s.dv_cache, i);
    if p return p.*;
    if is_vector_type(vtype(i)) return rs_fbdv_vector(s, i);
    if vkind(i) == .ARGUMENT { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if is_const(i) {
        cpn := const_null(vtype(i));
        rs_cache_set(s, i, cpn); rs_set_known_base(s, cpn, true); return cpn;
    }
    if !is_inst(i) fatal("rewrite-statepoints-for-gc: unexpected base defining value kind");
    o := inst_op(i);
    if o == .INTTOPTR { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if rs_is_cast(i) {
        def := strip_pointer_casts_kind(i, .ZERO_INDICES);
        if ptr_addrspace(vtype(def)) != ptr_addrspace(vtype(i)) fatal("rewrite-statepoints-for-gc: unsupported addrspacecast");
        bdv := rs_fbdv(s, def);
        rs_cache_set(s, i, bdv);
        return bdv;
    }
    if o == .LOAD { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if o == .GEP || o == .FREEZE {
        bdv := rs_fbdv(s, op(i, 0));
        rs_cache_set(s, i, bdv);
        return bdv;
    }
    if o == .CALL || o == .INVOKE {
        id := call_iid(i);
        if id == IID_EXPERIMENTAL_GC_STATEPOINT fatal("statepoints don't produce pointers");
        if id == IID_GC_RELOCATE fatal("repeat safepoint insertion is not supported");
        if id == IID_GCROOT fatal("interaction with the gcroot mechanism is not supported");
        if id == IID_GC_GET_POINTER_BASE {
            bdv := rs_fbdv(s, op(i, 0));
            rs_cache_set(s, i, bdv);
            return bdv;
        }
        rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i;
    }
    if o == .LANDINGPAD fatal("rewrite-statepoints-for-gc: Landing Pad is unimplemented");
    if o == .CMPXCHG || o == .ATOMICRMW || o == .EXTRACTVALUE { rs_cache_set(s, i, i); rs_set_known_base(s, i, true); return i; }
    if o == .INSERTVALUE fatal("Base pointer for a struct is meaningless");
    kb := md_kind_id_lookup("is_base_value");
    known := kb != NONE && get_metadata(i, kb) != NONE;
    rs_set_known_base(s, i, known);
    rs_cache_set(s, i, i);
    if o == .EXTRACTELEMENT return i;
    if o != .SELECT && o != .PHI fatal("rewrite-statepoints-for-gc: missing instruction case in findBaseDefiningValue");
    return i;
}
// findBaseDefiningValueCached
rs_fbdv_cached :: (s: *Rs_State, i: Value_Id) -> Value_Id {
    if !table_contains(*s.dv_cache, i) {
        bdv := rs_fbdv(s, i);
        rs_cache_set(s, i, bdv);
    }
    return table_find_pointer(*s.dv_cache, i).*;
}
// findBaseOrBDV
rs_find_base_or_bdv :: (s: *Rs_State, i: Value_Id) -> Value_Id {
    def := rs_fbdv_cached(s, i);
    p := table_find_pointer(*s.dv_cache, def);
    if p return p.*;
    return def;
}

Bdv_Status :: enum u8 { Unknown; Base; Conflict; }
Bdv_State :: struct { orig: Value_Id; status: Bdv_Status; base: Value_Id = NONE; }
bdv_meet :: (s: *Bdv_State, o: Bdv_State) {
    if s.status == .Conflict return;
    if s.status == .Unknown { s.status = o.status; s.base = o.base; return; }
    if o.status == .Unknown return;
    if o.status == .Conflict { s.status = .Conflict; s.base = NONE; return; }
    if s.base != o.base { s.status = .Conflict; s.base = NONE; }
}
bdv_eq :: (a: Bdv_State, b: Bdv_State) -> bool { return a.orig == b.orig && a.base == b.base && a.status == b.status; }

// MapVector<Value *, BDVState>
Bdv_Map :: struct { keys: [..] Value_Id; vals: [..] Bdv_State; index: Table(Value_Id, s64); }
bdv_map_find :: (m: *Bdv_Map, k: Value_Id) -> s64 { p := table_find_pointer(*m.index, k); if p return p.*; return -1; }
bdv_map_insert :: (m: *Bdv_Map, k: Value_Id, v: Bdv_State) -> bool {
    if bdv_map_find(m, k) >= 0 return false;
    table_set(*m.index, k, m.keys.count);
    array_add(*m.keys, k); array_add(*m.vals, v);
    return true;
}
bdv_map_erase :: (m: *Bdv_Map, k: Value_Id) {
    i := bdv_map_find(m, k);
    if i < 0 return;
    array_ordered_remove_by_index(*m.keys, i);
    array_ordered_remove_by_index(*m.vals, i);
    table_remove(*m.index, k);
    for x: i..m.keys.count-1 table_set(*m.index, m.keys[x], x);
}

// visitBDVOperands
rs_bdv_operands :: (bdv: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    o := inst_op(bdv);
    if o == .PHI { n := phi_num_incoming(bdv); for k: 0..n-1 array_add(out, phi_value(bdv, k)); }
    else if o == .SELECT { array_add(out, op(bdv, 1)); array_add(out, op(bdv, 2)); }
    else if o == .EXTRACTELEMENT array_add(out, op(bdv, 0));
    else if o == .INSERTELEMENT { array_add(out, op(bdv, 0)); array_add(out, op(bdv, 1)); }
    else if o == .SHUFFLEVECTOR {
        array_add(out, op(bdv, 0));
        if !sv_is_zero_elt_splat_i(bdv) array_add(out, op(bdv, 1));
    } else fatal("unexpected BDV type");
}

rs_suffixed_name_or :: (v: Value_Id, suffix: string, def: string) -> string {
    if vname(v).count return tconcat(vname(v), suffix);
    return def;
}

// findBasePointer
rs_find_base_pointer :: (s: *Rs_State, i: Value_Id) -> Value_Id {
    def := rs_find_base_or_bdv(s, i);
    if rs_is_known_base(s, def) && rs_both_vector_or_scalar(def, i) return def;
    states: Bdv_Map; states.keys.allocator = temp; states.vals.allocator = temp; states.index.allocator = temp;
    ops: [..] Value_Id; ops.allocator = temp;
    {
        wl: [..] Value_Id; wl.allocator = temp;
        array_add(*wl, def);
        bdv_map_insert(*states, def, .{def, .Unknown, NONE});
        while wl.count {
            cur := pop(*wl);
            rs_bdv_operands(cur, *ops);
            for in_val: ops {
                base := rs_find_base_or_bdv(s, in_val);
                if rs_is_known_base(s, base) && rs_both_vector_or_scalar(base, in_val) continue;
                if bdv_map_insert(*states, base, .{base, .Unknown, NONE}) array_add(*wl, base);
            }
        }
    }
    // prune states whose inputs all come from outside (or are the BDV itself)
    to_remove: [..] Value_Id; to_remove.allocator = temp;
    while true {
        to_remove.count = 0;
        for bdv: states.keys {
            rs_bdv_operands(bdv, *ops);
            can_prune := true;
            for v: ops {
                if !can_prune break;
                sv := strip_pointer_casts_kind(v, .ZERO_INDICES);
                if sv == bdv continue;
                vbdv := rs_find_base_or_bdv(s, v);
                if sv != vbdv { can_prune = false; break; }
                if bdv_map_find(*states, vbdv) >= 0 { can_prune = false; break; }
            }
            if can_prune array_add(*to_remove, bdv);
        }
        for to_remove { bdv_map_erase(*states, it); rs_cache_set(s, it, it); }
        if to_remove.count == 0 break;
    }
    if bdv_map_find(*states, def) < 0 return def;

    get_state :: (states: *Bdv_Map, base: Value_Id) -> Bdv_State {
        x := bdv_map_find(states, base);
        if x >= 0 return states.vals[x];
        return .{base, .Base, base};
    }
    mark_conflict :: (i: Value_Id, base: Value_Id) -> bool {
        o := inst_op(i);
        if o == .INSERTELEMENT || o == .EXTRACTELEMENT || o == .SHUFFLEVECTOR return true;
        if !rs_both_vector_or_scalar(base, i) return true;
        return false;
    }
    progress := true;
    while progress {
        progress = false;
        for bdv, idx: states.keys {
            ns: Bdv_State; ns.orig = bdv;
            rs_bdv_operands(bdv, *ops);
            for v: ops {
                b := rs_find_base_or_bdv(s, v);
                bdv_meet(*ns, get_state(*states, b));
            }
            if ns.base != NONE && mark_conflict(bdv, ns.base) ns = .{bdv, .Conflict, NONE};
            if !bdv_eq(states.vals[idx], ns) { progress = true; states.vals[idx] = ns; }
        }
    }
    // insert the base instructions for the conflicts
    for bdv, idx: states.keys {
        st := states.vals[idx];
        if st.status == .Unknown fatal("Optimistic algorithm didn't complete!");
        if st.status != .Conflict continue;
        o := inst_op(bdv);
        name: string;
        if o == .PHI name = rs_suffixed_name_or(bdv, ".base", "base_phi");
        else if o == .SELECT name = rs_suffixed_name_or(bdv, ".base", "base_select");
        else if o == .EXTRACTELEMENT name = rs_suffixed_name_or(bdv, ".base", "base_ee");
        else if o == .INSERTELEMENT name = rs_suffixed_name_or(bdv, ".base", "base_ie");
        else name = rs_suffixed_name_or(bdv, ".base", "base_sv");
        bi := ic_clone_inst(bdv);
        insert_at_position(bi, inst_block(bdv), bdv, false);
        set_name(bi, name);
        set_metadata(bi, md_kind_id("is_base_value"), md_tuple(.[], false));
        states.vals[idx] = .{bdv, .Conflict, bi};
        rs_set_known_base(s, bi, true);
    }
    get_base_for_input :: (s: *Rs_State, states: *Bdv_Map, input: Value_Id, insert_pt: Value_Id) -> Value_Id {
        bdv := rs_find_base_or_bdv(s, input);
        base: Value_Id;
        x := bdv_map_find(states, bdv);
        if x < 0 base = bdv; else base = states.vals[x].base;
        assert(base != NONE, "Can't be null");
        if vtype(base) != vtype(input) && insert_pt != NONE {
            bc := new_inst(.BITCAST, vtype(input), 1);
            set_op(bc, 0, base);
            insert_at_position(bc, inst_block(insert_pt), insert_pt, false);
            set_name(bc, "cast");
            base = bc;
        }
        return base;
    }
    for bdv, idx: states.keys {
        st := states.vals[idx];
        if st.status != .Conflict continue;
        bv := st.base;
        o := inst_op(bv);
        if o == .PHI {
            n := phi_num_incoming(bdv);
            b2v_keys: [..] Value_Id; b2v_keys.allocator = temp;
            b2v_vals: [..] Value_Id; b2v_vals.allocator = temp;
            for k: 0..n-1 {
                in_val := phi_value(bdv, k);
                in_bb := phi_block(bdv, k);
                found := -1;
                for b2v_keys if it == in_bb { found = it_index; break; }
                base: Value_Id;
                if found < 0 {
                    base = get_base_for_input(s, *states, in_val, block_terminator(in_bb));
                    array_add(*b2v_keys, in_bb); array_add(*b2v_vals, base);
                } else base = b2v_vals[found];
                phi_set_value(bv, k, base);
            }
        } else if o == .SELECT {
            set_op(bv, 1, get_base_for_input(s, *states, op(bdv, 1), bv));
            set_op(bv, 2, get_base_for_input(s, *states, op(bdv, 2), bv));
        } else if o == .EXTRACTELEMENT {
            set_op(bv, 0, get_base_for_input(s, *states, op(bdv, 0), bv));
        } else if o == .INSERTELEMENT {
            set_op(bv, 0, get_base_for_input(s, *states, op(bdv, 0), bv));
            set_op(bv, 1, get_base_for_input(s, *states, op(bdv, 1), bv));
        } else {
            set_op(bv, 0, get_base_for_input(s, *states, op(bdv, 0), bv));
            if !sv_is_zero_elt_splat_i(bdv) set_op(bv, 1, get_base_for_input(s, *states, op(bdv, 1), bv));
            else set_op(bv, 1, const_poison(vtype(op(bdv, 1))));
        }
    }
    for bdv, idx: states.keys rs_cache_set(s, bdv, states.vals[idx].base);
    return table_find_pointer(*s.dv_cache, def).*;
}

// ---------------------------------------------------------------- safepoint records

Rs_Record :: struct {
    live: Rs_Set;
    token: Value_Id = NONE;
    unwind_token: Value_Id = NONE;
    remat_keys: [..] Value_Id;    // RematerializedValues: MapVector<Instruction *, Value *>
    remat_vals: [..] Value_Id;
}

Rs_Remat_Cand :: struct { chain: [..] Value_Id; root: Value_Id; cost: s64; }

// GetDeoptBundleOperands
rs_deopt_operands :: (call: Value_Id, out: *[..] Value_Id) {
    k := call_bundle_index(call, "deopt");
    if k < 0 {
        return;   // assert(AllowStatepointWithNoDeoptInfo) in LLVM
    }
    b, e := call_bundle_range(call, cast(u32) k);
    for x: cast(s64) b..cast(s64) e - 1 array_add(out, op(call, cast(u32) x));
}

// insertUseHolderAfter
rs_insert_use_holder_after :: (call: Value_Id, values: [] Value_Id, holders: *[..] Value_Id) {
    if values.count == 0 return;
    f := get_or_insert_function("__tmp_use", type_func(ir.t_void, .[], true));
    make :: (f: Value_Id, values: [] Value_Id) -> Value_Id {
        fty := glob(f).value_type;
        c := new_inst(.CALL, ir.t_void, cast(u32)(values.count + 1));
        inst(c).ty2 = fty;
        for values set_op(c, cast(u32) it_index, it);
        set_op(c, cast(u32) values.count, f);
        return c;
    }
    if inst_op(call) == .CALL {
        h := make(f, values);
        insert_at_position(h, inst_block(call), inst(call).next, false);
        array_add(holders, h);
        return;
    }
    nd := get_successor(call, 0);
    h1 := make(f, values);
    insert_at_position(h1, nd, block_first_insertion_pt(nd), true);
    array_add(holders, h1);
    ud := get_successor(call, 1);
    h2 := make(f, values);
    insert_at_position(h2, ud, block_first_insertion_pt(ud), true);
    array_add(holders, h2);
}

// normalizeForInvokeSafepoint
rs_normalize_for_invoke_safepoint :: (bb: Value_Id, invoke_parent: Value_Id, dt: *Dom_Tree) -> Value_Id {
    ret := bb;
    if block_unique_predecessor(bb) == NONE ret = split_block_predecessors(bb, .[invoke_parent], "", dt, null);
    fold_single_entry_phi_nodes(ret);
    return ret;
}

// findRematerializableChainToBasePointer
rs_find_remat_chain :: (chain: *[..] Value_Id, cur: Value_Id) -> Value_Id {
    if is_inst(cur) && inst_op(cur) == .GEP {
        array_add(chain, cur);
        return rs_find_remat_chain(chain, op(cur, 0));
    }
    if is_inst(cur) && rs_is_cast(cur) {
        if !cast_is_noop(cur) return cur;
        array_add(chain, cur);
        return rs_find_remat_chain(chain, op(cur, 0));
    }
    return cur;
}
// chainToBasePointerCost
rs_chain_cost :: (chain: [] Value_Id, t: *Tti) -> s64 {
    cost: s64 = 0;
    for i: chain {
        if rs_is_cast(i) {
            c := tti_cast_cost(t, inst_op(i), vtype(i), vtype(op(i, 0)), tti_cast_context_hint(i), TCK_SIZE_AND_LATENCY, i);
            cost += cast(s64) c;
        } else if inst_op(i) == .GEP {
            // getAddressComputationCost(PtrTy, nullptr, nullptr): 0 for every target without a SCEV
            if !gep_has_all_constant_indices(i) cost += 2;
        } else fatal("unsupported instruction type during rematerialization");
    }
    return cost;
}
// AreEquivalentPhiNodes
rs_are_equivalent_phis :: (a: Value_Id, b: Value_Id) -> bool {
    n := phi_num_incoming(a);
    if n != phi_num_incoming(b) || inst_block(a) != inst_block(b) return false;
    // SmallDenseMap<Value *, BasicBlock *>: the last block of each value
    for k: 0..n-1 {
        v := phi_value(b, k);
        found := false; fb: Value_Id = NONE;
        for x: 0..n-1 if phi_value(a, x) == v { found = true; fb = phi_block(a, x); }
        if !found return false;
        if fb != phi_block(b, k) return false;
    }
    return true;
}

// rematerializeChain
rs_rematerialize_chain :: (chain: [] Value_Id, bb: Value_Id, before: Value_Id, head: bool, root: Value_Id, alt_base: Value_Id) -> Value_Id {
    last_cloned: Value_Id = NONE;
    last: Value_Id = NONE;
    for < instr: chain {
        c := ic_clone_inst(instr);
        insert_at_position(c, bb, before, head);
        set_name(c, tconcat(vname(instr), ".remat"));
        if last_cloned != NONE replace_uses_of_with(c, last, last_cloned);
        else if root != alt_base replace_uses_of_with(c, root, alt_base);
        last_cloned = c;
        last = instr;
        // insertion before `before` keeps the order of the clones
    }
    return last_cloned;
}

// findRematerializationCandidates
rs_find_remat_candidates :: (ptb: *Rs_Map, cand_keys: *[..] Value_Id, cands: *[..] Rs_Remat_Cand, t: *Tti) {
    for derived, idx: ptb.keys {
        base := ptb.vals[idx];
        if derived == base continue;
        chain: [..] Value_Id; chain.allocator = temp;
        root := rs_find_remat_chain(*chain, derived);
        if chain.count == 0 || chain.count > 10 continue;
        if root != base {
            if !is_phi(root) || !is_phi(base) continue;
            if !rs_are_equivalent_phis(root, base) continue;
        }
        cost := rs_chain_cost(chain, t);
        found := false;
        for cand_keys.* if it == derived { found = true; break; }
        if found continue;
        array_add(cand_keys, derived);
        array_add(cands, .{chain, root, cost});
    }
}

// rematerializeLiveValuesAtUses
rs_remat_at_uses :: (cand_keys: *[..] Value_Id, cands: *[..] Rs_Remat_Cand, records: [] Rs_Record, ptb: *Rs_Map) {
    if !rs_cl.remat_derived_at_uses return;
    deleted: [..] Value_Id; deleted.allocator = temp;
    for cand, ci: cand_keys.* {
        rec := *cands.*[ci];
        if rec.cost >= rs_cl.remat_threshold continue;
        if !has_uses(cand) continue;
        if has_one_use(cand) {
            u := ir.u_user[ir.v_first_use[cand]];
            if is_inst(u) && inst_block(u) == inst_block(cand) continue;
        }
        has_phi_user := false;
        u := ir.v_first_use[cand];
        while u != NONE { if is_phi(ir.u_user[u]) { has_phi_user = true; break; } u = ir.u_next[u]; }
        if has_phi_user continue;
        num_live: s64 = 0;
        for * r: records if rs_set_contains(*r.live, cand) num_live += 1;
        num_uses: s64 = 0;
        u = ir.v_first_use[cand];
        while u != NONE { num_uses += 1; u = ir.u_next[u]; }
        if num_live < num_uses continue;
        if num_live == num_uses && rec.cost > 0 continue;
        if rec.chain.count > 1 {
            rec.chain.count = 0;
            rs_find_remat_chain(*rec.chain, cand);
        }
        while has_uses(cand) {
            user := ir.u_user[ir.v_first_use[cand]];
            rc := rs_rematerialize_chain(rec.chain, inst_block(user), user, false, rec.root, rs_map_get(ptb, cand));
            replace_uses_of_with(user, cand, rc);
            rs_map_set(ptb, rc, rs_map_get(ptb, cand));
        }
        array_add(*deleted, cand);
    }
    for c: deleted {
        for cand_keys.* if it == c {
            array_ordered_remove_by_index(cand_keys, it_index);
            array_ordered_remove_by_index(cands, it_index);
            break;
        }
        for * r: records rs_set_remove(*r.live, c);
    }
    if deleted.count {
        for p, ci: cand_keys.* {
            r := *cands.*[ci];
            if r.chain.count > 1 {
                r.chain.count = 0;
                rs_find_remat_chain(*r.chain, p);
            }
        }
    }
}

// rematerializeLiveValues
rs_remat_live_values :: (call: Value_Id, info: *Rs_Record, ptb: *Rs_Map, cand_keys: *[..] Value_Id, cands: *[..] Rs_Remat_Cand) {
    to_delete: [..] Value_Id; to_delete.allocator = temp;
    for lv: info.live.list {
        ci := -1;
        for cand_keys.* if it == lv { ci = it_index; break; }
        if ci < 0 continue;
        rec := *cands.*[ci];
        cost := rec.cost;
        if inst_op(call) == .INVOKE cost *= 2;
        if cost >= rs_cl.remat_threshold continue;
        array_add(*to_delete, lv);
        if inst_op(call) == .CALL {
            nx := inst(call).next;
            rv := rs_rematerialize_chain(rec.chain, inst_block(nx), nx, false, rec.root, rs_map_get(ptb, lv));
            rs_record_remat(info, rv, lv);
        } else {
            nd := get_successor(call, 0);
            ud := get_successor(call, 1);
            nip := block_first_insertion_pt(nd);
            uip := block_first_insertion_pt(ud);
            nrv := rs_rematerialize_chain(rec.chain, nd, nip, true, rec.root, rs_map_get(ptb, lv));
            urv := rs_rematerialize_chain(rec.chain, ud, uip, true, rec.root, rs_map_get(ptb, lv));
            rs_record_remat(info, nrv, lv);
            rs_record_remat(info, urv, lv);
        }
    }
    for to_delete rs_set_remove(*info.live, it);
}
rs_record_remat :: (info: *Rs_Record, k: Value_Id, v: Value_Id) {
    if info.remat_keys.allocator.proc == null { info.remat_keys.allocator = temp; info.remat_vals.allocator = temp; }
    for info.remat_keys if it == k { info.remat_vals[it_index] = v; return; }
    array_add(*info.remat_keys, k); array_add(*info.remat_vals, v);
}

// ---------------------------------------------------------------- making the statepoint explicit

STATEPOINT_DEFAULT_ID :: 0xABCDEF00;
SP_FLAG_GC_TRANSITION :: 1;
SP_FLAG_DEOPT_LIVE_IN :: 2;

// legalizeCallAttributes
rs_legalize_call_attributes :: (call: Value_Id, is_mem_intrinsic: bool, sp_al: u32) -> u32 {
    orig := inst(call).attrs;
    if orig == 0 return sp_al;
    fa: [..] Attr; fa.allocator = temp;
    for attr_set_items(attr_list_fn(orig)) {
        if it.kind == .Memory || it.kind == .NoSync || it.kind == .NoFree continue;
        if it.kind == .STRING_ATTR && (it.key == "statepoint-id" || it.key == "statepoint-num-patch-bytes") continue;
        array_add(*fa, it);
    }
    fn := attr_set_merge(attr_list_fn(sp_al), attr_set_get(fa));
    params: [..] u32; params.allocator = temp;
    n0 := ifx sp_al == 0 then 0 else ir.attr_lists[sp_al].params.count;
    for k: 0..n0-1 array_add(*params, ir.attr_lists[sp_al].params[k]);
    if !is_mem_intrinsic {
        na := call_num_args(call);
        if na > 0 for x: 0..na-1 {
            p := 5 + x;
            while params.count <= p array_add(*params, 0);
            params[p] = attr_set_merge(params[p], attr_list_param(orig, x));
        }
    }
    return attr_list_get(fn, attr_list_ret(sp_al), params);
}

// CreateGCRelocates
rs_create_gc_relocates :: (live: [] Value_Id, bases: [] Value_Id, token: Value_Id, b: *Irb) {
    if live.count == 0 return;
    find_index :: (vec: [] Value_Id, v: Value_Id) -> s64 { for vec if it == v return it_index; assert(false, "Val not found in LiveVec!"); return 0; }
    decl_tys: [..] Type_Id; decl_tys.allocator = temp;
    decls: [..] Value_Id; decls.allocator = temp;
    for lv, i: live {
        base_idx := const_int(ir.t_i32, cast(u64) find_index(live, bases[i]));
        live_idx := const_int(ir.t_i32, cast(u64) i);
        ty := vtype(lv);
        d: Value_Id = NONE;
        for decl_tys if it == ty { d = decls[it_index]; break; }
        if d == NONE {
            if !rs_is_handled_gc_pointer_type(ty) fatal("rewrite-statepoints-for-gc: gc.relocate of a non-gc pointer");
            nt := type_ptr(ptr_addrspace(ty));
            if is_vector_type(ty) nt = type_vector(type_count(ty), nt, false);
            d = get_or_insert_intrinsic_declaration(IID_GC_RELOCATE, .[nt]);
            array_add(*decl_tys, ty); array_add(*decls, d);
        }
        r := irb_call(b, d, .[token, base_idx, live_idx], rs_suffixed_name_or(lv, ".relocated", ""));
        inst(r).cc = CC_COLD;
    }
}

Rs_Replacement :: struct { old: Value_Id; new: Value_Id = NONE; is_deoptimize: bool; }

// getDeoptLowering
rs_deopt_lowering :: (call: Value_Id) -> string {
    k := "deopt-lowering";
    if call_has_fn_attr_str(call, k) {
        ok, v := attr_set_str_value(attr_list_fn(inst(call).attrs), k);
        if ok return v;
        f := call_called_function(call);
        ok2, v2 := attr_set_str_value(attr_list_fn(glob(f).attrs), k);
        return v2;
    }
    return "live-through";
}

// parseStatepointDirectivesFromAttrs
rs_statepoint_directives :: (al: u32) -> (has_id: bool, id: u64, has_npb: bool, npb: u32) {
    fa := attr_list_fn(al);
    has_id, has_npb := false, false;
    id: u64; npb: u32;
    ok, v := attr_set_str_value(fa, "statepoint-id");
    if ok {
        x, good, rest := string_to_int(v, 10, u64);
        if good && rest.count == 0 && v.count > 0 { has_id = true; id = x; }
    }
    ok2, v2 := attr_set_str_value(fa, "statepoint-num-patch-bytes");
    if ok2 {
        x, good, rest := string_to_int(v2, 10, u64);
        if good && rest.count == 0 && v2.count > 0 && x <= 0xFFFF_FFFF { has_npb = true; npb = cast(u32) x; }
    }
    return has_id, id, has_npb, npb;
}

// makeStatepointExplicitImpl
rs_make_statepoint_explicit :: (call: Value_Id, bases: [] Value_Id, live: [] Value_Id, result: *Rs_Record, repl: *[..] Rs_Replacement, ptb: *Rs_Map) {
    b: Irb; irb_set_before(*b, call); b.dbg = get_metadata(call, 0);
    sp_id: u64 = STATEPOINT_DEFAULT_ID;
    npb: u32 = 0;
    flags: u32 = 0;
    call_args: [..] Value_Id; call_args.allocator = temp;
    na := call_num_args(call);
    if na > 0 for x: 0..na-1 array_add(*call_args, call_arg(call, x));
    deopt: [..] Value_Id; deopt.allocator = temp;
    has_deopt := false;
    k := call_bundle_index(call, "deopt");
    if k >= 0 { has_deopt = true; s, e := call_bundle_range(call, cast(u32) k); for x: cast(s64) s..cast(s64) e - 1 array_add(*deopt, op(call, cast(u32) x)); }
    trans: [..] Value_Id; trans.allocator = temp;
    has_trans := false;
    k = call_bundle_index(call, "gc-transition");
    if k >= 0 { has_trans = true; s, e := call_bundle_range(call, cast(u32) k); for x: cast(s64) s..cast(s64) e - 1 array_add(*trans, op(call, cast(u32) x)); flags |= SP_FLAG_GC_TRANSITION; }
    is_deoptimize, is_mem_intrinsic := false, false;
    hid, did, hnpb, dnpb := rs_statepoint_directives(inst(call).attrs);
    if hnpb npb = dnpb;
    if hid sp_id = did;
    lowering := rs_deopt_lowering(call);
    if lowering == "live-in" flags |= SP_FLAG_DEOPT_LIVE_IN;
    else if lowering != "live-through" fatal("Unsupported value!");

    target_fty := inst(call).ty2;
    target := call_callee(call);
    if vkind(target) == .FUNCTION {
        iid := fn_iid(target);
        if iid == IID_EXPERIMENTAL_DEOPTIMIZE {
            dom: [..] Type_Id; dom.allocator = temp;
            for call_args array_add(*dom, vtype(it));
            fty := type_func(ir.t_void, dom, false);
            target = get_or_insert_function("__llvm_deoptimize", fty);
            target_fty = fty;
            is_deoptimize = true;
        } else if iid == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC || iid == IID_MEMMOVE_ELEMENT_UNORDERED_ATOMIC {
            is_mem_intrinsic = true;
            get_base_and_offset :: (b: *Irb, ptb: *Rs_Map, derived: Value_Id) -> (Value_Id, Value_Id) {
                base: Value_Id;
                if is_const(derived) base = const_null(vtype(derived));
                else base = rs_map_get(ptb, derived);
                bits := dl_ptr_spec(ptr_addrspace(vtype(derived))).bits;
                it := type_int(bits);
                bi := irb_cast(b, .PTRTOINT, base, it);
                di := irb_cast(b, .PTRTOINT, derived, it);
                return base, irb_binop(b, .SUB, di, bi);
            }
            dest := call_args[0];
            db, doff := get_base_and_offset(*b, ptb, dest);
            src := call_args[1];
            sb, soff := get_base_and_offset(*b, ptb, src);
            len := call_args[2];
            esz := call_args[3];
            if vkind(esz) != .C_INT fatal("rewrite-statepoints-for-gc: element size is not a constant");
            call_args.count = 0;
            array_add(*call_args, db); array_add(*call_args, doff); array_add(*call_args, sb); array_add(*call_args, soff); array_add(*call_args, len);
            dom: [..] Type_Id; dom.allocator = temp;
            for call_args array_add(*dom, vtype(it));
            fty := type_func(ir.t_void, dom, false);
            es := const_int_zext(esz);
            base_name := ifx iid == IID_MEMCPY_ELEMENT_UNORDERED_ATOMIC then "__llvm_memcpy_element_unordered_atomic_safepoint_" else "__llvm_memmove_element_unordered_atomic_safepoint_";
            if es != 1 && es != 2 && es != 4 && es != 8 && es != 16 fatal("unexpected element size!");
            target = get_or_insert_function(tprint("%1%2", base_name, es), fty);
            target_fty = fty;
        }
    }

    // CreateGCStatepointCall / CreateGCStatepointInvoke
    fn_sp := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_GC_STATEPOINT, .[vtype(target)]);
    args: [..] Value_Id; args.allocator = temp;
    array_add(*args, const_int(ir.t_i64, sp_id));
    array_add(*args, const_int(ir.t_i32, npb));
    array_add(*args, target);
    array_add(*args, const_int(ir.t_i32, cast(u64) call_args.count));
    array_add(*args, const_int(ir.t_i32, flags));
    for call_args array_add(*args, it);
    array_add(*args, const_int(ir.t_i32, 0));
    array_add(*args, const_int(ir.t_i32, 0));
    bundles: [..] Arc_Bundle; bundles.allocator = temp;
    if has_deopt array_add(*bundles, .{"deopt", deopt});
    if has_trans array_add(*bundles, .{"gc-transition", trans});
    if live.count array_add(*bundles, .{"gc-live", live});
    token: Value_Id;
    et: Attr; et.kind = .ElementType; et.ty = target_fty;
    if inst_op(call) == .CALL {
        sp := arc_new_call_fn(fn_sp, args, bundles);
        irb_insert(*b, sp, "safepoint_token");
        call_add_param_attr(sp, 2, et);
        call_set_tail_kind(sp, call_tail_kind(call));
        inst(sp).cc = inst(call).cc;
        inst(sp).attrs = rs_legalize_call_attributes(call, is_mem_intrinsic, inst(sp).attrs);
        token = sp;
        nx := inst(call).next;
        irb_set_before(*b, nx);
        b.dbg = get_metadata(nx, 0);
    } else {
        nd := get_successor(call, 0);
        ud := get_successor(call, 1);
        sp := rs_new_invoke(fn_sp, args, bundles, nd, ud);
        irb_insert(*b, sp, "statepoint_token");
        call_add_param_attr(sp, 2, et);
        inst(sp).cc = inst(call).cc;
        inst(sp).attrs = rs_legalize_call_attributes(call, is_mem_intrinsic, inst(sp).attrs);
        token = sp;
        if block_first(ud) != NONE && inst_op(block_first(ud)) == .PHI fatal("can't safely insert in this block!");
        irb_set_at(*b, ud, block_first_insertion_pt(ud), true);
        b.dbg = get_metadata(call, 0);
        lp := block_landing_pad_inst(ud);
        result.unwind_token = lp;
        rs_create_gc_relocates(live, bases, lp, *b);
        irb_set_at(*b, nd, block_first_insertion_pt(nd), true);
    }
    if is_deoptimize {
        array_add(repl, .{call, NONE, true});
    } else {
        set_name(token, "statepoint_token");
        if vtype(call) != ir.t_void && has_uses(call) {
            gr_f := get_or_insert_intrinsic_declaration(IID_GC_RESULT, .[vtype(call)]);
            gr := irb_call(*b, gr_f, .[token], name_ref(vname(call)));
            inst(gr).attrs = attr_list_get(0, attr_list_ret(inst(call).attrs), .[]);
            array_add(repl, .{call, gr, false});
        } else array_add(repl, .{call, NONE, false});
    }
    result.token = token;
    rs_create_gc_relocates(live, bases, token, *b);
}

// InvokeInst::Create(FTy, Callee, NormalDest, UnwindDest, Args, Bundles) (unlinked)
rs_new_invoke :: (f: Value_Id, args: [] Value_Id, bundles: [] Arc_Bundle, nd: Value_Id, ud: Value_Id) -> Value_Id {
    fty := glob(f).value_type;
    nin := 0;
    for bundles nin += it.inputs.count;
    i := new_inst(.INVOKE, func_ret(fty), cast(u32)(args.count + nin + 3));
    inst(i).ty2 = fty;
    k: u32 = 0;
    for args { set_op(i, k, it); k += 1; }
    if bundles.count {
        r := inst(i);
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) bundles.count;
        bb := k;
        for bundles {
            array_add(*ir.u32_pool, bundle_tag_id(it.tag));
            array_add(*ir.u32_pool, bb);
            array_add(*ir.u32_pool, bb + cast(u32) it.inputs.count);
            bb += cast(u32) it.inputs.count;
        }
        for bd: bundles for bd.inputs { set_op(i, k, it); k += 1; }
    }
    set_op(i, k, nd); set_op(i, k + 1, ud); set_op(i, k + 2, f);
    return i;
}

block_landing_pad_inst :: (bb: Value_Id) -> Value_Id {
    i := block_first_non_phi(bb);
    if i != NONE && inst_op(i) == .LANDINGPAD return i;
    return NONE;
}

// DeferredReplacement::doReplacement
rs_do_replacement :: (r: Rs_Replacement) {
    if r.new != NONE rauw_with_metadata(r.old, r.new);
    if r.is_deoptimize {
        ri := block_terminator(inst_block(r.old));
        if inst_op(ri) != .RET fatal("rewrite-statepoints-for-gc: deoptimize not followed by ret");
        u := new_inst(.UNREACHABLE, ir.t_void, 0);
        insert_at_position(u, inst_block(ri), ri, false);
        erase_inst_with_metadata(ri);
    }
    erase_inst_with_metadata(r.old);
}

// ---------------------------------------------------------------- relocationViaAlloca

rs_relocation_via_alloca :: (f: Value_Id, dt: *Dom_Tree, live: [] Value_Id, records: [] Rs_Record) {
    alloca_keys: [..] Value_Id; alloca_keys.allocator = temp;
    alloca_vals: [..] Value_Id; alloca_vals.allocator = temp;
    alloca_map: Table(Value_Id, Value_Id); alloca_map.allocator = temp;
    promotable: [..] Value_Id; promotable.allocator = temp;
    entry := fn_entry(f);
    emit_alloca_for :: (v: Value_Id, entry: Value_Id, keys: *[..] Value_Id, vals: *[..] Value_Id, map: *Table(Value_Id, Value_Id), promotable: *[..] Value_Id) {
        a := create_alloca_unlinked(vtype(v), dl.alloca_as, dl_pref_align(vtype(v)));
        insert_at_position(a, entry, block_first_non_phi(entry), true);
        if !table_contains(map, v) { array_add(keys, v); array_add(vals, a); }
        else for keys.* if it == v { vals.*[it_index] = a; break; }
        table_set(map, v, a);
        array_add(promotable, a);
    }
    for live emit_alloca_for(it, entry, *alloca_keys, *alloca_vals, *alloca_map, *promotable);
    for * info: records for ov: info.remat_vals {
        if table_contains(*alloca_map, ov) continue;
        emit_alloca_for(ov, entry, *alloca_keys, *alloca_vals, *alloca_map, *promotable);
    }
    insert_relocation_stores :: (tok: Value_Id, map: *Table(Value_Id, Value_Id), visited: *Table(Value_Id, bool)) {
        u := ir.v_first_use[tok];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(usr) || call_iid(usr) != IID_GC_RELOCATE continue;
            ov := gc_relocate_derived_ptr(usr);
            a := table_find_pointer(map, ov);
            assert(a != null);
            st := create_store_raw(usr, a.*, dl_abi_align(vtype(usr)));
            nx := inst(usr).next;
            insert_at_position(st, inst_block(usr), nx, false);
            table_set(visited, ov, true);
        }
    }
    for * info: records {
        visited: Table(Value_Id, bool); visited.allocator = temp;
        insert_relocation_stores(info.token, *alloca_map, *visited);
        if inst_op(info.token) == .INVOKE insert_relocation_stores(info.unwind_token, *alloca_map, *visited);
        for rv, ri: info.remat_keys {
            ov := info.remat_vals[ri];
            a := table_find_pointer(*alloca_map, ov);
            assert(a != null, "Can not find alloca for rematerialized value");
            st := create_store_raw(rv, a.*, dl_abi_align(vtype(rv)));
            insert_at_position(st, inst_block(rv), inst(rv).next, false);
            table_set(*visited, ov, true);
        }
        if rs_cl.clobber_non_live {
            Clob :: struct { ty: Type_Id; a: Value_Id; }
            to_clobber: [..] Clob; to_clobber.allocator = temp;
            for d, di: alloca_keys {
                if table_contains(*visited, d) continue;
                array_add(*to_clobber, .{vtype(d), alloca_vals[di]});
            }
            insert_clobbers_at :: (bb: Value_Id, ip: Value_Id, head: bool, cl: [] Clob) {
                for cl {
                    cpn := ifx is_vector_type(it.ty) then const_zero(it.ty) else const_null(it.ty);
                    st := create_store_raw(cpn, it.a, dl_abi_align(it.ty));
                    insert_at_position(st, bb, ip, head);
                }
            }
            t := info.token;
            if inst_op(t) == .INVOKE {
                nd := get_successor(t, 0); ud := get_successor(t, 1);
                insert_clobbers_at(nd, block_first_insertion_pt(nd), true, to_clobber);
                insert_clobbers_at(ud, block_first_insertion_pt(ud), true, to_clobber);
            } else insert_clobbers_at(inst_block(t), inst(t).next, false, to_clobber);
        }
    }
    for d, di: alloca_keys {
        a := alloca_vals[di];
        uses: [..] Value_Id; uses.allocator = temp;
        u := ir.v_first_use[d];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) {
                dup := false;
                for uses if it == usr { dup = true; break; }
                if !dup array_add(*uses, usr);
            } else if vkind(usr) != .C_EXPR fatal("rewrite-statepoints-for-gc: a non-instruction user");
            u = ir.u_next[u];
        }
        for usr: uses {
            if is_phi(usr) {
                n := phi_num_incoming(usr);
                for x: 0..n-1 if phi_value(usr, x) == d {
                    ib := phi_block(usr, x);
                    t := block_terminator(ib);
                    ld := rs_new_load(vtype(d), a);
                    insert_at_position(ld, ib, t, false);
                    phi_set_value(usr, x, ld);
                }
            } else {
                ld := rs_new_load(vtype(d), a);
                insert_at_position(ld, inst_block(usr), usr, false);
                replace_uses_of_with(usr, d, ld);
            }
        }
        st := create_store_raw(d, a, dl_abi_align(vtype(d)));
        if is_inst(d) {
            if inst_op(d) == .INVOKE {
                nd := get_successor(d, 0);
                insert_at_position(st, nd, block_first_non_phi(nd), true);
            } else insert_at_position(st, inst_block(d), inst(d).next, true);   // insertAfter
        } else {
            assert(vkind(d) == .ARGUMENT);
            insert_at_position(st, inst_block(a), inst(a).next, true);
        }
    }
    if promotable.count promote_mem_to_reg(promotable, dt, null);
}
rs_new_load :: (ty: Type_Id, p: Value_Id) -> Value_Id {
    l := new_inst(.LOAD, ty, 1);
    set_op(l, 0, p);
    inst(l).align = dl_abi_align(ty);
    return l;
}
// GCRelocateInst::getDerivedPtr
gc_relocate_derived_ptr :: (r: Value_Id) -> Value_Id {
    tok := op(r, 0);
    if !is_inst(tok) || inst_op(tok) == .LANDINGPAD {
        // the relocate of an unwind path: the statepoint is the invoke whose unwind block holds the landingpad
        bb := inst_block(tok);
        p := block_unique_predecessor(bb);
        tok = block_terminator(p);
    }
    k := call_bundle_index(tok, "gc-live");
    idx := cast(u32) const_int_zext(op(r, 2));
    if k >= 0 { s, e := call_bundle_range(tok, cast(u32) k); return op(tok, s + idx); }
    return call_arg(tok, idx);
}

// ---------------------------------------------------------------- insertParsePoints

rs_find_base_pointers :: (s: *Rs_State, call: Value_Id, info: *Rs_Record, ptb: *Rs_Map) {
    pot := rs_set_copy(*info.live);
    k := call_bundle_index(call, "deopt");
    if k >= 0 {
        b, e := call_bundle_range(call, cast(u32) k);
        for x: cast(s64) b..cast(s64) e - 1 {
            v := op(call, cast(u32) x);
            if !rs_set_contains(*pot, v) continue;
            rs_set_remove(*pot, v);
            rs_map_set(ptb, v, v);
        }
    }
    for ptr: pot.list {
        base := rs_find_base_pointer(s, ptr);
        rs_map_set(ptb, ptr, base);
    }
}

rs_print_base_pairs :: (ptb: *Rs_Map, title: string) {
    sb: String_Builder; sb.allocator = temp;
    append(*sb, title);
    for d, i: ptb.keys {
        append(*sb, " derived ");
        append(*sb, value_as_operand(d));
        append(*sb, " base ");
        append(*sb, value_as_operand(ptb.vals[i]));
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}

rs_insert_parse_points :: (s: *Rs_State, dt: *Dom_Tree, t: *Tti, to_update: [] Value_Id) -> bool {
    f := s.f;
    for call: to_update {
        if inst_op(call) != .INVOKE continue;
        rs_normalize_for_invoke_safepoint(get_successor(call, 0), inst_block(call), dt);
        rs_normalize_for_invoke_safepoint(get_successor(call, 1), inst_block(call), dt);
    }
    holders: [..] Value_Id; holders.allocator = temp;
    for call: to_update {
        dv: [..] Value_Id; dv.allocator = temp;
        ops: [..] Value_Id; ops.allocator = temp;
        rs_deopt_operands(call, *ops);
        for a: ops {
            rs_check_handled(vtype(a));
            if rs_is_handled_gc_pointer_type(vtype(a)) array_add(*dv, a);
        }
        rs_insert_use_holder_after(call, dv, *holders);
    }
    records := NewArray(to_update.count, Rs_Record,, allocator = temp);
    {
        d: Rs_Liveness;
        rs_compute_live_in_values(f, *d);
        for * info, i: records {
            rs_set_init(*info.live);
            rs_find_live_set_at_inst(to_update[i], *d, *info.live);
            if rs_cl.print_liveset || rs_cl.print_liveset_size fatal("-spp-print-liveset is not implemented yet");
        }
    }
    ptb: Rs_Map; rs_map_init(*ptb);
    for * info, i: records rs_find_base_pointers(s, to_update[i], info, *ptb);
    if rs_cl.print_base_pointers rs_print_base_pairs(*ptb, "Base Pairs (w/o Relocation):\n");
    for * info, i: records {
        bases: [..] Value_Id; bases.allocator = temp;
        for d: info.live.list array_add(*bases, rs_map_get(*ptb, d));
        rs_insert_use_holder_after(to_update[i], bases, *holders);
    }
    {
        d: Rs_Liveness;
        rs_compute_live_in_values(f, *d);
        for * info, i: records {
            upd: Rs_Set; rs_set_init(*upd);
            rs_find_live_set_at_inst(to_update[i], *d, *upd);
            for upd.list rs_map_insert(*ptb, it, it);
            info.live = upd;
        }
    }
    if rs_cl.print_base_pointers rs_print_base_pairs(*ptb, "Base Pairs: (w/Relocation)\n");
    for * info: records {
        rm: [..] Value_Id; rm.allocator = temp;
        for lv: info.live.list if is_const(rs_map_get(*ptb, lv)) array_add(*rm, lv);
        for rm rs_set_remove(*info.live, it);
    }
    for holders erase_inst_with_metadata(it);
    holders.count = 0;

    cand_keys: [..] Value_Id; cand_keys.allocator = temp;
    cands: [..] Rs_Remat_Cand; cands.allocator = temp;
    {
        // findRematerizationCandidates takes PointerToBase by value
        rs_find_remat_candidates(*ptb, *cand_keys, *cands, t);
    }
    rs_remat_at_uses(*cand_keys, *cands, records, *ptb);
    for * info, i: records rs_remat_live_values(to_update[i], info, *ptb, *cand_keys, *cands);

    repl: [..] Rs_Replacement; repl.allocator = temp;
    for * info, i: records {
        lv: [..] Value_Id; lv.allocator = temp;
        bv: [..] Value_Id; bv.allocator = temp;
        for l: info.live.list { array_add(*lv, l); array_add(*bv, rs_map_get(*ptb, l)); }
        rs_make_statepoint_explicit(to_update[i], bv, lv, info, *repl, *ptb);
    }
    for repl rs_do_replacement(it);

    live: Rs_Set; rs_set_init(*live);
    for * info: records {
        tok := info.token;
        k := call_bundle_index(tok, "gc-live");
        if k >= 0 { b, e := call_bundle_range(tok, cast(u32) k); for x: cast(s64) b..cast(s64) e - 1 rs_set_insert(*live, op(tok, cast(u32) x)); }
    }
    rs_relocation_via_alloca(f, dt, live.list, records);
    return records.count > 0;
}

// inlineGetBaseAndOffset
rs_inline_get_base_and_offset :: (s: *Rs_State, intrinsics: [] Value_Id) -> bool {
    changed := false;
    for cs: intrinsics {
        id := call_iid(cs);
        if id == IID_GC_GET_POINTER_BASE {
            changed = true;
            base := rs_find_base_pointer(s, op(cs, 0));
            rauw_with_metadata(cs, base);
            if vname(base).count == 0 && !is_const(base) take_name(base, cs);
            erase_inst_with_metadata(cs);
        } else if id == IID_GC_GET_POINTER_OFFSET {
            changed = true;
            derived := op(cs, 0);
            base := rs_find_base_pointer(s, derived);
            bits := dl_ptr_spec(ptr_addrspace(vtype(derived))).bits;
            b: Irb; irb_set_before(*b, cs); b.dbg = get_metadata(cs, 0);
            it := type_int(bits);
            bi := irb_cast(*b, .PTRTOINT, base, it, rs_suffixed_name_or(base, ".int", ""));
            di := irb_cast(*b, .PTRTOINT, derived, it, rs_suffixed_name_or(derived, ".int", ""));
            off := irb_binop(*b, .SUB, di, bi);
            rauw_with_metadata(cs, off);
            take_name(off, cs);
            erase_inst_with_metadata(cs);
        } else fatal("Unknown intrinsic");
    }
    return changed;
}

// RewriteStatepointsForGC::runOnFunction
rs_run_on_function :: (f: Value_Id) -> bool {
    needs_rewrite :: (i: Value_Id) -> bool {
        if !is_call_base(i) return false;
        if call_iid(i) == IID_EXPERIMENTAL_GC_STATEPOINT return false;
        if calls_gc_leaf_function(i) return false;
        if !rs_cl.allow_no_deopt && call_bundle_index(i, "deopt") < 0 return false;
        return true;
    }
    dt := get_domtree(f);
    dtu: Dtu; dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    made_change := remove_unreachable_blocks(f, *dtu);
    dt = dtu_get_dom_tree(*dtu);
    parse_points: [..] Value_Id; parse_points.allocator = temp;
    intrinsics: [..] Value_Id; intrinsics.allocator = temp;
    for i: fn_insts(f) {
        if needs_rewrite(i) array_add(*parse_points, i);
        if inst_op(i) == .CALL {
            id := call_iid_any(i);
            if id == IID_GC_GET_POINTER_BASE || id == IID_GC_GET_POINTER_OFFSET array_add(*intrinsics, i);
        }
    }
    if parse_points.count == 0 && intrinsics.count == 0 return made_change;
    for bb: fn_blocks(f) if block_unique_predecessor(bb) != NONE made_change |= fold_single_entry_phi_nodes(bb);
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t == NONE || inst_op(t) != .CONDBR continue;
        c := op(t, 0);
        if is_inst(c) && inst_op(c) == .ICMP && has_one_use(c) {
            made_change = true;
            inst_move_before_dbg(c, t);
        }
    }
    for i: fn_insts(f) {
        if inst_op(i) != .GEP continue;
        vf: u64 = 0;
        n := nops(i);
        for k: 0..n-1 { ty := vtype(op(i, k)); if is_vector_type(ty) vf = type_count(ty); }
        if !is_vector_type(vtype(op(i, 0))) && vf != 0 {
            b: Irb; irb_set_before(*b, i); b.dbg = get_metadata(i, 0);
            splat := irb_vector_splat(*b, vf, op(i, 0), "");
            set_op(i, 0, splat);
            made_change = true;
        }
    }
    s: Rs_State;
    s.f = f;
    s.dv_cache.allocator = temp; s.known_bases.allocator = temp;
    if intrinsics.count made_change |= rs_inline_get_base_and_offset(*s, intrinsics);
    if parse_points.count made_change |= rs_insert_parse_points(*s, dt, tti_get(f), parse_points);
    return made_change;
}

// ---------------------------------------------------------------- stripNonValidData

RS_STRIP_KINDS :: Attr_Kind.[.Dereferenceable, .DereferenceableOrNull, .ReadNone, .ReadOnly, .WriteOnly, .NoAlias, .NoFree];
rs_strip_set :: (s: u32) -> u32 {
    r := s;
    for RS_STRIP_KINDS r = attr_set_remove(r, it);
    return r;
}
rs_strip_attrs_from_prototype :: (f: Value_Id) {
    id := fn_iid(f);
    if id != NOT_INTRINSIC { set_intrinsic_attributes(f, id); return; }
    g := glob(f);
    l := g.attrs;
    fty := g.value_type;
    np := func_nparams(fty);
    params: [..] u32; params.allocator = temp;
    for k: 0..cast(s64) np - 1 {
        p := attr_list_param(l, cast(u32) k);
        if is_ptr_type(type_sub(fty, cast(u32) k + 1)) p = rs_strip_set(p);
        array_add(*params, p);
    }
    // parameter attribute sets past the parameters (varargs) are kept
    if l != 0 for k: np..cast(s64) ir.attr_lists[l].params.count - 1 array_add(*params, ir.attr_lists[l].params[k]);
    ret := attr_list_ret(l);
    if is_ptr_type(func_ret(fty)) ret = rs_strip_set(ret);
    fn := attr_list_fn(l);
    fn = attr_set_remove(fn, .Memory); fn = attr_set_remove(fn, .NoSync); fn = attr_set_remove(fn, .NoFree);
    glob(f).attrs = attr_list_get(fn, ret, params);
}
rs_strip_data_from_body :: (f: Value_Id) {
    if glob(f).first_block == NONE return;
    inv: [..] Value_Id; inv.allocator = temp;
    keep := u32.[MDK_TBAA, md_fixed("range"), md_fixed("alias.scope"), md_fixed("nontemporal"), md_fixed("nonnull"), md_fixed("align"), md_fixed("type")];
    for i: fn_insts(f) {
        if call_iid(i) == IID_INVARIANT_START { array_add(*inv, i); continue; }
        tag := get_metadata(i, MDK_TBAA);
        if tag != NONE set_metadata(i, MDK_TBAA, rs_mutable_tbaa_tag(tag));
        if inst_op(i) == .LOAD || inst_op(i) == .STORE drop_unknown_non_debug_metadata(i, keep);
        if is_call_base(i) {
            na := call_num_args(i);
            if na > 0 for k: 0..na-1 if is_ptr_type(vtype(call_arg(i, k))) {
                s := call_param_attr_set(i, k);
                ns := rs_strip_set(s);
                if ns != s call_set_param_attr_set(i, k, ns);
            }
            if is_ptr_type(vtype(i)) {
                s := attr_list_ret(inst(i).attrs);
                ns := rs_strip_set(s);
                if ns != s call_set_ret_attr_set(i, ns);
            }
        }
    }
    for inv {
        rauw_with_metadata(it, const_poison(vtype(it)));
        erase_inst_with_metadata(it);
    }
}
// MDBuilder::createMutableTBAAAccessTag
rs_mutable_tbaa_tag :: (tag: Md_Id) -> Md_Id {
    if md_nops(tag) < 3 fatal("rewrite-statepoints-for-gc: a scalar (non struct-path) TBAA tag is not supported");
    base := md_op(tag, 0);
    access := md_op(tag, 1);
    new_format := md_nops(access) > 0 && md_is_node(md_op(access, 0));
    flag_op: u32 = ifx new_format then cast(u32) 4 else 3;
    if md_nops(tag) <= flag_op return tag;
    flag := md_op(tag, flag_op);
    if md_const_int_zext(flag) == 0 return tag;
    if !new_format return md_tuple(.[base, access, md_op(tag, 2)], false);
    return md_tuple(.[base, access, md_op(tag, 2), md_op(tag, 3)], false);
}
md_const_int_zext :: (m: Md_Id) -> u64 {
    v := md_value_of(m);
    if v == NONE || vkind(v) != .C_INT fatal("rewrite-statepoints-for-gc: a TBAA operand is not a constant integer");
    return const_int_zext(v);
}

// RewriteStatepointsForGC::run
rewrite_statepoints_for_gc_run :: () -> Preserved {
    changed := false;
    i := 0;
    while i < ir.m_functions.count {
        f := ir.m_functions[i];
        i += 1;
        if is_declaration(f) || glob(f).first_block == NONE continue;
        if !fn_has_gc(f) || !gc_strategy_uses_rs4gc(glob(f).gc) continue;
        changed |= rs_run_on_function(f);
    }
    if !changed return PRESERVE_ALL;
    for ir.m_functions rs_strip_attrs_from_prototype(it);
    for ir.m_functions rs_strip_data_from_body(it);
    return PRESERVE_NONE;
}
