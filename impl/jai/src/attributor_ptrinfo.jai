// AAPointerInfo (AA::PointerInfo::State, AAPointerInfoImpl, AAPointerInfoFloating, AAPointerInfoArgument,
// AAPointerInfoCallSiteArgument, AAPointerInfoCallSiteReturned, AAPointerInfoReturned): a port of their parts of
// llvm/lib/Transforms/IPO/AttributorAttributes.cpp, with AA::RangeTy, AAPointerInfo::OffsetInfo / RangeList / Access
// from llvm/include/llvm/Transforms/IPO/Attributor.h and GEPOperator::collectOffset from llvm/lib/IR/Operator.cpp.
//
// The offset bins are a DenseMap<RangeTy, SmallSet<unsigned, 4>> that LLVM iterates: Pi_Bins reproduces its bucket
// order (the DenseMap of llvm/ADT/DenseMap.h: linear probing, densemap::detail::mix hashes, 64 initial buckets,
// growth at 3/4 load by rehashing in bucket order; bins are never erased).

PI_UNASSIGNED :: cast(s64) -2147483648;   // std::numeric_limits<int32_t>::min()
PI_UNKNOWN :: cast(s64) 2147483647;       // std::numeric_limits<int32_t>::max()

// AAPointerInfo::AccessKind
AK_MUST :: cast(u8) 1;
AK_MAY :: cast(u8) 2;
AK_R :: cast(u8) 4;
AK_W :: cast(u8) 8;
AK_RW :: cast(u8) 12;
AK_ASSUMPTION :: cast(u8) 17;

// AA::RangeTy
Pi_Range :: struct { offset: s64; size: s64; }
pi_range_unassigned :: () -> Pi_Range { return .{PI_UNASSIGNED, PI_UNASSIGNED}; }
pi_range_unknown :: () -> Pi_Range { return .{PI_UNKNOWN, PI_UNKNOWN}; }
pi_range_offset_or_size_unknown :: (r: Pi_Range) -> bool { return r.offset == PI_UNKNOWN || r.size == PI_UNKNOWN; }
pi_range_offset_and_size_unknown :: (r: Pi_Range) -> bool { return r.offset == PI_UNKNOWN && r.size == PI_UNKNOWN; }
pi_range_is_unassigned :: (r: Pi_Range) -> bool { return r.offset == PI_UNASSIGNED; }
pi_range_eq :: (a: Pi_Range, b: Pi_Range) -> bool { return a.offset == b.offset && a.size == b.size; }
pi_range_may_overlap :: (a: Pi_Range, r: Pi_Range) -> bool {
    if pi_range_offset_or_size_unknown(a) || pi_range_offset_or_size_unknown(r) return true;
    return r.offset + r.size > a.offset && r.offset < a.offset + a.size;
}
// RangeTy::operator&=
pi_range_and :: (a: *Pi_Range, r: Pi_Range) {
    if pi_range_is_unassigned(r) return;
    if pi_range_is_unassigned(a.*) { a.* = r; return; }
    if a.offset == PI_UNKNOWN || r.offset == PI_UNKNOWN a.offset = PI_UNKNOWN;
    if a.size == PI_UNKNOWN || r.size == PI_UNKNOWN a.size = PI_UNKNOWN;
    if pi_range_offset_and_size_unknown(a.*) return;
    if a.offset == PI_UNKNOWN {
        a.size = max(a.size, r.size);
    } else if a.size == PI_UNKNOWN {
        a.offset = min(a.offset, r.offset);
    } else {
        o := min(a.offset, r.offset);
        a.size = max(a.offset + a.size, r.offset + r.size) - o;
        a.offset = o;
    }
}
pi_range_less :: (l: Pi_Range, r: Pi_Range) -> bool {
    if l.offset < r.offset return true;
    if l.offset == r.offset return l.size < r.size;
    return false;
}

// AAPointerInfo::RangeList (a sorted vector of ranges)
Range_List :: [..] Pi_Range;
rl_is_unassigned :: (l: [] Pi_Range) -> bool { return l.count == 0; }
rl_is_unknown :: (l: [] Pi_Range) -> bool { if l.count == 0 return false; return pi_range_offset_or_size_unknown(l[0]); }
rl_set_unknown :: (l: *Range_List) { l.count = 0; array_add(l, pi_range_unknown()); }
rl_is_unique :: (l: [] Pi_Range) -> bool { return l.count == 1 && !pi_range_offset_or_size_unknown(l[0]); }
rl_eq :: (a: [] Pi_Range, b: [] Pi_Range) -> bool {
    if a.count != b.count return false;
    for a if !pi_range_eq(it, b[it_index]) return false;
    return true;
}
// RangeList::insert(Pos, R): (position, changed); the position is an index
rl_insert :: (l: *Range_List, pos: s64, r: Pi_Range) -> (s64, bool) {
    if rl_is_unknown(l.*) return 0, false;
    if pi_range_offset_or_size_unknown(r) { rl_set_unknown(l); return 0, true; }
    lb := pos;
    while lb < l.count && pi_range_less(l.*[lb], r) lb += 1;
    if lb == l.count || l.*[lb].offset != r.offset {
        array_insert_at(l, r, lb);
        return lb, true;
    }
    changed := !pi_range_eq(l.*[lb], r);
    pi_range_and(*l.*[lb], r);
    if pi_range_offset_or_size_unknown(l.*[lb]) { rl_set_unknown(l); return 0, true; }
    return lb, changed;
}
// RangeList::merge
rl_merge :: (l: *Range_List, rhs: [] Pi_Range) -> bool {
    if rl_is_unknown(l.*) return false;
    if rl_is_unknown(rhs) { rl_set_unknown(l); return true; }
    if l.count == 0 { for rhs array_add(l, it); return true; }
    changed := false;
    lpos := 0;
    for r: rhs {
        p, c := rl_insert(l, lpos, r);
        if rl_is_unknown(l.*) return true;
        lpos = p;
        changed |= c;
    }
    return changed;
}
// RangeList::set_difference (std::set_difference with RangeTy::LessThan)
rl_set_difference :: (a: [] Pi_Range, b: [] Pi_Range, d: *Range_List) {
    i, j := 0, 0;
    while i < a.count {
        if j >= b.count { array_add(d, a[i]); i += 1; continue; }
        if pi_range_less(a[i], b[j]) { array_add(d, a[i]); i += 1; }
        else if pi_range_less(b[j], a[i]) j += 1;
        else { i += 1; j += 1; }
    }
}
rl_add_to_all_offsets :: (l: *Range_List, inc: s64) {
    if rl_is_unknown(l.*) return;
    for * l.* it.offset += inc;
}

// SmallSet<T, 4>: insertion order while small, sorted once it has outgrown the inline vector
Small_Set :: struct { items: [..] s64; big: bool; }
sset_contains :: (s: *Small_Set, v: s64) -> bool { for s.items if it == v return true; return false; }
sset_insert :: (s: *Small_Set, v: s64) -> bool {
    if sset_contains(s, v) return false;
    if !s.big && s.items.count < 4 { array_add(*s.items, v); return true; }
    s.big = true;
    array_add(*s.items, v);
    quick_sort(s.items, (a: s64, b: s64) -> s64 { if a < b return -1; if a > b return 1; return 0; });
    return true;
}
sset_erase :: (s: *Small_Set, v: s64) {
    for s.items if it == v { array_ordered_remove_by_index(*s.items, it_index); return; }
}
sset_clear :: (s: *Small_Set) { s.items.count = 0; s.big = false; }
sset_copy :: (s: Small_Set) -> Small_Set { r: Small_Set; for s.items array_add(*r.items, it); r.big = s.big; return r; }
sset_eq :: (a: *Small_Set, b: *Small_Set) -> bool {
    if a.items.count != b.items.count return false;
    for a.items if !sset_contains(b, it) return false;
    return true;
}

// AAPointerInfo::OffsetInfo (a SmallSet<int64_t, 4>)
Offset_Info :: Small_Set;
oi_is_unassigned :: (o: *Offset_Info) -> bool { return o.items.count == 0; }
oi_is_unknown :: (o: *Offset_Info) -> bool { return o.items.count == 1 && o.items[0] == PI_UNKNOWN; }
oi_set_unknown :: (o: *Offset_Info) { sset_clear(o); sset_insert(o, PI_UNKNOWN); }
oi_add_to_all :: (o: *Offset_Info, inc: s64) {
    n: Offset_Info;
    n.items.allocator = o.items.allocator;
    for o.items sset_insert(*n, it + inc);
    o.* = n;
}
oi_merge :: (o: *Offset_Info, r: *Offset_Info) -> bool {
    changed := false;
    for r.items if sset_insert(o, it) changed = true;
    return changed;
}

// AAPointerInfo::Access
Pi_Access :: struct {
    local: Value_Id;
    remote: Value_Id;
    content: Value_Id;         // OV_NOVAL: not yet determined, NONE: unknown
    ranges: Range_List;
    kind: u8;
    ty: Type_Id;
}
pi_acc_is_read :: (a: *Pi_Access) -> bool { return (a.kind & AK_R) != 0; }
pi_acc_is_write :: (a: *Pi_Access) -> bool { return (a.kind & AK_W) != 0; }
pi_acc_is_assumption :: (a: *Pi_Access) -> bool { return a.kind == AK_ASSUMPTION; }
pi_acc_is_write_or_assumption :: (a: *Pi_Access) -> bool { return pi_acc_is_write(a) || pi_acc_is_assumption(a); }
pi_acc_is_must :: (a: *Pi_Access) -> bool { return (a.kind & AK_MUST) != 0; }
pi_acc_is_may :: (a: *Pi_Access) -> bool { return (a.kind & AK_MAY) != 0; }

// the offset bins: DenseMap<AA::RangeTy, SmallSet<unsigned, 4>> in LLVM's bucket order
Pi_Bins :: struct {
    keys: [..] Pi_Range;
    sets: [..] Small_Set;
    buckets: [..] s32;         // -1: empty, else an index into keys / sets
}
dm_hash_s64 :: inline (v: s64) -> u32 { return cast,no_check(u32) ((cast,no_check(u64) v) * 37); }
dm_mix :: inline (x_in: u64) -> u64 { x := x_in * 0xbf58476d1ce4e5b9; x ^= x >> 31; return x; }
dm_combine_hash :: inline (a: u32, b: u32) -> u32 { return cast,no_check(u32) dm_mix(((cast(u64) a) << 32) | cast(u64) b); }
pi_range_hash :: (r: Pi_Range) -> u32 { return dm_combine_hash(dm_hash_s64(r.offset), dm_hash_s64(r.size)); }
bins_find :: (b: *Pi_Bins, r: Pi_Range) -> s32 {
    n := b.buckets.count;
    if n == 0 return -1;
    mask := cast(u32) (n - 1);
    k := pi_range_hash(r) & mask;
    while true {
        e := b.buckets[k];
        if e < 0 return -1;
        if pi_range_eq(b.keys[e], r) return e;
        k = (k + 1) & mask;
    }
    return -1;
}
bins_place :: (b: *Pi_Bins, e: s32) {
    mask := cast(u32) (b.buckets.count - 1);
    k := pi_range_hash(b.keys[e]) & mask;
    while b.buckets[k] >= 0 k = (k + 1) & mask;
    b.buckets[k] = e;
}
// OffsetBins[Key]
bins_get :: (b: *Pi_Bins, r: Pi_Range) -> *Small_Set {
    e := bins_find(b, r);
    if e >= 0 return *b.sets[e];
    n := b.buckets.count;
    if (b.keys.count + 1) * 4 >= n * 3 {
        nn := max(64, n * 2);
        old: [..] s32;
        for b.buckets array_add(*old, it);
        b.buckets.count = 0;
        for 0..nn - 1 array_add(*b.buckets, -1);
        for old if it >= 0 bins_place(b, it);
        array_free(old);
    }
    array_add(*b.keys, r);
    s: Small_Set;
    array_add(*b.sets, s);
    ne := cast(s32) (b.keys.count - 1);
    bins_place(b, ne);
    return *b.sets[ne];
}
// the bins in DenseMap iteration order
bins_order :: (b: *Pi_Bins) -> [..] s32 {
    r: [..] s32; r.allocator = temp;
    for b.buckets if it >= 0 array_add(*r, it);
    return r;
}

// AA::PointerInfo::State (the BooleanState BS is aa.s)
Pi_Ext :: struct {
    accesses: [..] Pi_Access;
    bins: Pi_Bins;
    remote_map: Table(Value_Id, [..] u32);   // RemoteIMap
    returned: Offset_Info;                   // ReturnedOffsets
}
pi_ext :: inline (i: u32) -> *Pi_Ext { return cast(*Pi_Ext) aa(i).x; }
pi_construct :: (i: u32) { aa(i).x = atr_new(Pi_Ext); }
pi_reaches_return :: (i: u32) -> bool { return !oi_is_unassigned(*pi_ext(i).returned); }
pi_num_offset_bins :: (i: u32) -> s64 { return pi_ext(i).bins.keys.count; }

// AA::PointerInfo::State::addAccess
pi_add_access :: (i: u32, ranges: [] Pi_Range, x: Value_Id, content: Value_Id, kind_in: u8, ty: Type_Id, remote_in: Value_Id = NONE) -> bool {
    e := pi_ext(i);
    remote := ifx remote_in != NONE then remote_in else x;
    ll := table_find_pointer(*e.remote_map, remote);
    if !ll { n: [..] u32; table_set(*e.remote_map, remote, n); ll = table_find_pointer(*e.remote_map, remote); }
    exists := false;
    idx := cast(u32) e.accesses.count;
    for k: ll.* if e.accesses[k].local == x { exists = true; idx = k; break; }
    // Access(LocalI, RemoteI, Ranges, Content, Kind, Ty)
    kind := kind_in;
    if ranges.count > 1 { kind |= AK_MAY; kind &= ~AK_MUST; }
    if !exists {
        a: Pi_Access;
        a.local = x; a.remote = remote; a.content = content; a.kind = kind; a.ty = ty;
        for ranges array_add(*a.ranges, it);
        array_add(*e.accesses, a);
        array_add(ll, idx);
        for r: e.accesses[idx].ranges sset_insert(bins_get(*e.bins, r), idx);
        return ATR_CHANGED;
    }
    cur := *e.accesses[idx];
    before_ranges: [..] Pi_Range; before_ranges.allocator = temp;
    for cur.ranges array_add(*before_ranges, it);
    before_content := cur.content;
    before_kind := cur.kind;
    // Current &= Acc
    rl_merge(*cur.ranges, ranges);
    cur.content = atr_combine_optional_values(cur.content, content, cur.ty);
    cur.kind |= kind;
    if (cur.kind & AK_MAY) != 0 || cur.ranges.count > 1 { cur.kind |= AK_MAY; cur.kind &= ~AK_MUST; }
    if rl_eq(cur.ranges, before_ranges) && cur.content == before_content && cur.kind == before_kind return ATR_UNCHANGED;
    to_remove: Range_List; to_remove.allocator = temp;
    rl_set_difference(before_ranges, cur.ranges, *to_remove);
    for r: to_remove sset_erase(bins_get(*e.bins, r), idx);
    to_add: Range_List; to_add.allocator = temp;
    rl_set_difference(cur.ranges, before_ranges, *to_add);
    for r: to_add sset_insert(bins_get(*e.bins, r), idx);
    return ATR_CHANGED;
}

// setReachesReturn
pi_set_reaches_return :: (i: u32, reached: *Offset_Info) -> bool {
    r := *pi_ext(i).returned;
    if oi_is_unknown(r) return ATR_UNCHANGED;
    if oi_is_unknown(reached) { oi_set_unknown(r); return ATR_CHANGED; }
    if oi_merge(r, reached) return ATR_CHANGED;
    return ATR_UNCHANGED;
}
// addReturnedOffsetsTo
pi_add_returned_offsets_to :: (i: u32, oi: *Offset_Info) {
    r := *pi_ext(i).returned;
    if oi_is_unknown(r) { oi_set_unknown(oi); return; }
    merged: Offset_Info;
    merged.items.allocator = temp;
    for off: r.items {
        tmp := sset_copy(oi.*);
        tmp.items.allocator = temp;
        oi_add_to_all(*tmp, off);
        oi_merge(*merged, *tmp);
    }
    oi.* = merged;
}

// State::forallInterferingAccesses(Range, CB) collecting (access, exact) in bin order; false if invalid
Pi_Interfering :: struct { acc: u32; exact: bool; }
pi_interfering_in_range :: (i: u32, range: Pi_Range, out: *[..] Pi_Interfering) -> bool {
    if !aa_is_valid(i) || !oi_is_unassigned(*pi_ext(i).returned) return false;
    e := pi_ext(i);
    for b: bins_order(*e.bins) {
        r := e.bins.keys[b];
        if !pi_range_may_overlap(range, r) continue;
        exact := pi_range_eq(range, r) && !pi_range_offset_or_size_unknown(range);
        for idx: e.bins.sets[b].items array_add(out, .{cast(u32) idx, exact});
    }
    return true;
}

// AAPointerInfoImpl::forallInterferingAccesses(A, QueryingAA, I, ...) with getPotentialCopiesOfMemoryValue's
// CheckAccess / SkipCB as the user callbacks (its only client outside OpenMPOpt)
pi_forall_interfering_accesses_for_inst :: (i: u32, q: u32, x: Value_Id, find_writes: bool, find_reads: bool, c: *Copies_Ctx, written: *bool, range: *Pi_Range) -> bool {
    written.* = false;
    e := pi_ext(i);
    scope := inst_fn(x);
    no_sync, _ := atr_has_assumed_ir_attr(.NoSync, q, irp_function(scope), DEP_OPTIONAL);
    all_in_same_no_sync_fn := no_sync;
    // AAExecutionDomain only exists in OpenMPOpt
    is_thread_local_obj := atr_is_assumed_thread_local_object(irp_assoc_value(aa(i).pos), i);
    _, known_no_recurse := atr_has_assumed_ir_attr(.NoRecurse, i, irp_function(scope), DEP_OPTIONAL);
    use_dominance := find_writes && known_no_recurse;
    dt := atr_dt(scope);
    gb: Go_Back;
    av := irp_assoc_value(aa(i).pos);
    if is_inst(av) && inst_op(av) == .ALLOCA {
        aifn := inst_fn(av);
        nr, _ := atr_has_assumed_ir_attr(.NoRecurse, i, irp_function(aifn), DEP_OPTIONAL);
        if nr gb = .{GOBACK_NOT_FN, aifn};
    }
    exclusion: [..] Value_Id; exclusion.allocator = temp;
    dominating: [..] u32; dominating.allocator = temp;
    interfering: [..] Pi_Interfering; interfering.allocator = temp;
    // State::forallInterferingAccesses(I, AccessCB, Range)
    if !aa_is_valid(i) || !oi_is_unassigned(*e.returned) return false;
    ll := table_find_pointer(*e.remote_map, x);
    if ll {
        for idx: ll.* {
            for r: e.accesses[idx].ranges {
                pi_range_and(range, r);
                if pi_range_offset_and_size_unknown(range.*) break;
            }
        }
        cands: [..] Pi_Interfering; cands.allocator = temp;
        if !pi_interfering_in_range(i, range.*, *cands) return false;
        for cd: cands {
            acc := *e.accesses[cd.acc];
            acc_scope := inst_fn(acc.remote);
            in_same := acc_scope == scope;
            if cd.exact && pi_acc_is_must(acc) && acc.remote != x {
                if pi_acc_is_write(acc) || (inst_op(x) == .LOAD && pi_acc_is_write_or_assumption(acc)) copies_insert(*exclusion, acc.remote);
            }
            if (!find_writes || !pi_acc_is_write_or_assumption(acc)) && (!find_reads || !pi_acc_is_read(acc)) continue;
            dominates := find_writes && dt != null && cd.exact && pi_acc_is_must(acc) && in_same && dt_dominates_inst(dt, acc.remote, x);
            if dominates { found := false; for dominating if it == cd.acc { found = true; break; } if !found array_add(*dominating, cd.acc); }
            all_in_same_no_sync_fn &= acc_scope == scope;
            array_add(*interfering, cd);
        }
    }
    written.* = dominating.count != 0;
    least: Value_Id = NONE;
    for d: dominating {
        rem := e.accesses[d].remote;
        if least == NONE least = rem;
        else if dt_dominates_inst(dt, least, rem) least = rem;
    }
    can_ignore_threading_for_inst :: (y: Value_Id, is_thread_local_obj: bool, all_in_same: bool) -> bool {
        return is_thread_local_obj || all_in_same;
    }
    for it: interfering {
        acc := *e.accesses[it.acc];
        skip := false;
        if !(!all_in_same_no_sync_fn && !is_thread_local_obj) {
            // CanSkipAccess
            if copies_skip(c, acc) skip = true;
            else if !(can_ignore_threading_for_inst(acc.remote, is_thread_local_obj, all_in_same_no_sync_fn) ||
                      (acc.remote != acc.local && can_ignore_threading_for_inst(acc.local, is_thread_local_obj, all_in_same_no_sync_fn))) skip = false;
            else {
                read_checked := !find_reads;
                write_checked := !find_writes;
                if !read_checked {
                    if !atr_is_potentially_reachable(x, acc.remote, q, *exclusion, gb) read_checked = true;
                }
                if !write_checked {
                    if !atr_is_potentially_reachable(acc.remote, x, q, *exclusion, gb) write_checked = true;
                }
                if !write_checked && written.* && inst_fn(acc.remote) != scope {
                    fra := atr_get_aa(.INTER_REACH, irp_function(scope), q, DEP_OPTIONAL);
                    if fra != NONE {
                        inserted := copies_insert(*exclusion, x);
                        if !inter_instruction_can_reach(fra, least, inst_fn(acc.remote), exclusion) write_checked = true;
                        if inserted for exclusion if it == x { array_ordered_remove_by_index(*exclusion, it_index); break; }
                    }
                }
                if read_checked && write_checked skip = true;
                else if dt == null || !use_dominance skip = false;
                else {
                    isdom := false;
                    for d: dominating if d == it.acc { isdom = true; break; }
                    skip = isdom && least != acc.remote;
                }
            }
        }
        if !skip {
            if !copies_check_access(c, acc, it.exact) return false;
        }
    }
    return true;
}

// translateAndAddStateFromCallee
pi_translate_and_add_state_from_callee :: (i: u32, o: u32, cb: Value_Id) -> bool {
    if !aa_is_valid(o) || !aa_is_valid(i) return aa_pessimistic(i);
    changed := ATR_UNCHANGED;
    is_byval := arg_has_attr(irp_assoc_arg(aa(o).pos), .ByVal);
    changed |= pi_set_reaches_return(i, *pi_ext(o).returned);
    oe := pi_ext(o);
    for b: bins_order(*oe.bins) {
        idxs: [..] s64; idxs.allocator = temp;
        for oe.bins.sets[b].items array_add(*idxs, it);
        for idx: idxs {
            racc := *oe.accesses[idx];
            if is_byval && !pi_acc_is_read(racc) continue;
            uai := false;
            ak := racc.kind;
            content := atr_translate_argument_to_call_site_content(racc.content, cb, i, *uai);
            ak = ak & (ifx is_byval then AK_R else AK_RW);
            ak = ak | (ifx pi_acc_is_may(racc) then AK_MAY else AK_MUST);
            ranges: [..] Pi_Range; ranges.allocator = temp;
            for racc.ranges array_add(*ranges, it);
            changed |= pi_add_access(i, ranges, cb, content, ak, racc.ty, racc.remote);
        }
    }
    return changed;
}
// translateAndAddState
pi_translate_and_add_state :: (i: u32, o: u32, offsets: *Offset_Info, cb: Value_Id, is_must: bool) -> bool {
    if !aa_is_valid(o) || !aa_is_valid(i) return aa_pessimistic(i);
    changed := ATR_UNCHANGED;
    oe := pi_ext(o);
    offs: [..] s64; offs.allocator = temp;
    for offsets.items array_add(*offs, it);
    for b: bins_order(*oe.bins) {
        idxs: [..] s64; idxs.allocator = temp;
        for oe.bins.sets[b].items array_add(*idxs, it);
        for idx: idxs {
            racc := *oe.accesses[idx];
            if !is_must && pi_acc_is_assumption(racc) continue;
            for off: offs {
                nr: Range_List; nr.allocator = temp;
                if off == PI_UNKNOWN array_add(*nr, pi_range_unknown());
                else for racc.ranges array_add(*nr, it);
                if !rl_is_unknown(nr) rl_add_to_all_offsets(*nr, off);
                ak := racc.kind;
                if !is_must ak = (ak & ~AK_MUST) | AK_MAY;
                changed |= pi_add_access(i, nr, cb, racc.content, ak, racc.ty, racc.remote);
            }
        }
    }
    return changed;
}

// ---------------------------------------------------------------- AAPointerInfoFloating

// OffsetInfoMap (DenseMap<Value *, OffsetInfo>, only looked up)
Pi_Offset_Map :: struct { idx: Table(Value_Id, s64); infos: [..] Offset_Info; i: u32; changed: *bool; }
pom_get :: (m: *Pi_Offset_Map, v: Value_Id) -> *Offset_Info {
    found, k := table_find(*m.idx, v);
    if found return *m.infos[k];
    o: Offset_Info;
    o.items.allocator = temp;
    array_add(*m.infos, o);
    table_set(*m.idx, v, m.infos.count - 1);
    return *m.infos[m.infos.count - 1];
}
pom_contains :: (m: *Pi_Offset_Map, v: Value_Id) -> bool { return table_contains(*m.idx, v); }
// HandlePassthroughUser
pom_passthrough :: (m: *Pi_Offset_Map, usr: Value_Id, cur: Value_Id) {
    uk := pom_get(m, usr);
    pk := pom_get(m, cur);
    oi_merge(uk, pk);
}
// EquivalentUseCB
pi_equivalent_use :: (m: *Pi_Offset_Map, old: Use_Id, nu: Use_Id) -> bool {
    nv := ir.u_val[nu];
    ov := ir.u_val[old];
    if pom_contains(m, nv) return sset_eq(pom_get(m, nv), pom_get(m, ov));
    pom_passthrough(m, nv, ov);
    return true;
}

// handleAccess
pi_handle_access :: (i: u32, x: Value_Id, content: Value_Id, kind: u8, offsets: *Offset_Info, changed: *bool, ty: Type_Id) -> bool {
    size := PI_UNKNOWN;
    if !type_is_scalable(ty) size = cast(s64) dl_type_store_size(ty);
    sorted: [..] s64; sorted.allocator = temp;
    for offsets.items array_add(*sorted, it);
    quick_sort(sorted, (a: s64, b: s64) -> s64 { if a < b return -1; if a > b return 1; return 0; });
    vt := ifx is_vector_type(ty) && type_kind(ty) != .SVECTOR then ty else NONE;
    if vt == NONE || content == OV_NOVAL || content == NONE || !is_constant_kind(vkind(content)) || vtype(content) != vt || type_is_scalable(type_elem(vt)) {
        ranges: [..] Pi_Range; ranges.allocator = temp;
        for sorted array_add(*ranges, .{it, size});
        changed.* |= pi_add_access(i, ranges, x, content, kind, ty);
    } else {
        et := type_elem(vt);
        esize := cast(s64) dl_type_store_size(et);
        eoffs: [..] s64; eoffs.allocator = temp;
        for offsets.items array_add(*eoffs, it);
        n := cast(s64) type_count(vt);
        i32t := type_int(32);
        for k: 0..n - 1 {
            ec := ce_extract_element(content, const_int(i32t, cast(u64) k));
            ranges: [..] Pi_Range; ranges.allocator = temp;
            for eoffs array_add(*ranges, .{it, esize});
            changed.* |= pi_add_access(i, ranges, x, ec, kind, et);
            for * eoffs it.* += esize;
        }
    }
    return true;
}

// GEPOperator::collectOffset: (ok, variable offsets (value, scale) in insertion order, constant offset)
gep_collect_offset :: (g: Value_Id, bw: u32, vars: *[..] Gep_Var_Offset) -> (bool, APInt) {
    off := ap_zero(bw);
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        index := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        scalable := type_is_scalable(indexed);
        if vkind(index) == .C_INT && is_int_type(vtype(index)) {
            ci := const_ap(index);
            if ap_is_zero(ci) continue;
            if scalable return false, off;
            if is_struct {
                off = ap_add(off, ap_from_u64(bw, dl_struct_offset(cur, cast(u32) ap_zext_value(ci))));
                continue;
            }
            idx := ap_sext_or_trunc(ci, bw);
            off = ap_add(off, ap_mul(idx, ap_from_u64(bw, gep_seq_stride(cur, k, indexed))));
            continue;
        }
        if is_struct || scalable return false, off;
        sz := ap_from_u64(bw, gep_seq_stride(cur, k, indexed));
        if !ap_is_zero(sz) {
            found := false;
            for * vars.* if it.v == index { it.scale = ap_add(it.scale, sz); found = true; break; }
            if !found array_add(vars, .{index, sz});
        }
    }
    return true, off;
}

// collectConstantsForGEP: false means "do not follow"
pi_collect_constants_for_gep :: (i: u32, usr_oi: *Offset_Info, ptr_oi: *Offset_Info, g: Value_Id) -> bool {
    bw := dl_index_type_size_bits(vtype(g));
    vars: [..] Gep_Var_Offset; vars.allocator = temp;
    ok, coff := gep_collect_offset(g, bw, *vars);
    if !ok { oi_set_unknown(usr_oi); return true; }
    uni := sset_copy(ptr_oi.*);
    uni.items.allocator = temp;
    oi_add_to_all(*uni, ap_sext_value(coff));
    for vi: vars {
        pc := atr_get_aa(.POTENTIAL_CONSTANT_VALUES, irp_value(vi.v), i, DEP_OPTIONAL);
        if pc == NONE || !aa_is_valid(pc) { oi_set_unknown(usr_oi); return true; }
        if pcv_ext(pc).undef continue;
        if pcv_ext(pc).set.count == 0 return false;
        product: Offset_Info;
        product.items.allocator = temp;
        for c: pcv_ext(pc).set {
            cp := sset_copy(uni);
            cp.items.allocator = temp;
            oi_add_to_all(*cp, ap_sext_value(c) * cast,no_check(s64) ap_zext_value(vi.scale));
            oi_merge(*product, *cp);
        }
        uni = product;
    }
    usr_oi.* = uni;
    return true;
}

pi_floating_update :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    av := irp_assoc_value(aa(i).pos);
    m: Pi_Offset_Map;
    m.idx.allocator = temp;
    m.infos.allocator = temp;
    m.i = i;
    m.changed = *changed;
    sset_insert(pom_get(*m, av), 0);
    afn := irp_assoc_fn(aa(i).pos);
    ok, w := atr_uses_begin(i, av, true, DEP_OPTIONAL, true, EQU_POINTER_INFO, *m);
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        follow := false;
        if !pi_use_pred(i, *m, u, *follow, av, afn, *changed) return aa_pessimistic(i);
        if follow atr_uses_follow(*w, u);
    }
    if w.failed return aa_pessimistic(i);
    return changed;
}

pi_use_pred :: (i: u32, m: *Pi_Offset_Map, u: Use_Id, follow: *bool, av: Value_Id, afn: Value_Id, changed: *bool) -> bool {
    cur := ir.u_val[u];
    usr := ir.u_user[u];
    passthrough :: (m: *Pi_Offset_Map, usr: Value_Id, cur: Value_Id, follow: *bool) -> bool {
        pom_passthrough(m, usr, cur);
        follow.* = true;
        return true;
    }
    if vkind(usr) == .C_EXPR {
        ce := cexpr(usr);
        if is_cast_op(ce.op) return passthrough(m, usr, cur, follow);
        if ce.op != .GEP return false;
    }
    if opr_code(usr) == .GEP {
        uo := pom_get(m, usr);
        po := pom_get(m, cur);
        if oi_is_unknown(uo) return true;
        if oi_is_unknown(po) { follow.* = true; oi_set_unknown(uo); return true; }
        follow.* = pi_collect_constants_for_gep(i, uo, po, usr);
        return true;
    }
    if !is_inst(usr) return false;
    o := inst_op(usr);
    if o == .PTRTOINT return false;
    if is_cast_op(o) || o == .SELECT return passthrough(m, usr, cur, follow);
    if o == .RET {
        if inst_fn(usr) == afn {
            changed.* |= pi_set_reaches_return(i, pom_get(m, cur));
            return true;
        }
        return false;
    }
    if o == .PHI {
        first := !pom_contains(m, usr);
        uo := pom_get(m, usr);
        po := pom_get(m, cur);
        if oi_is_unknown(po) {
            follow.* = !oi_is_unknown(uo);
            oi_set_unknown(uo);
            return true;
        }
        if sset_eq(uo, po) return true;
        off := ap_zero(dl_index_type_size_bits(vtype(cur)));
        base, off2 := strip_and_accumulate_constant_offsets(cur, off, true);
        if !pom_contains(m, base) { oi_set_unknown(uo); follow.* = true; return true; }
        ci := atr_ci(inst_fn(usr));
        if atr_may_be_in_cycle(ci, usr, true) {
            base_oi := sset_copy(pom_get(m, base).*);
            base_oi.items.allocator = temp;
            oi_add_to_all(*base_oi, cast,no_check(s64) ap_zext_value(off2));
            uo = pom_get(m, usr);
            if first || sset_eq(*base_oi, uo) return passthrough(m, usr, cur, follow);
            oi_set_unknown(uo);
            follow.* = true;
            return true;
        }
        uo = pom_get(m, usr);
        po = pom_get(m, cur);
        oi_merge(uo, po);
        follow.* = true;
        return true;
    }
    if o == .LOAD {
        ak := AK_R;
        if get_underlying_object(cur) == av ak |= AK_MUST; else ak |= AK_MAY;
        if !pi_handle_access(i, usr, NONE, ak, pom_get(m, cur), changed, vtype(usr)) return false;
        // an llvm.assume(icmp eq (load), V) gives the loaded value
        bb := inst_block(usr);
        is_assumption :: (y: Value_Id) -> bool { return is_inst(y) && is_call_base(y) && call_is_intrinsic(y) && is_assume_like_intrinsic(y); }
        is_impacted_in_range :: (from: Value_Id, to: Value_Id) -> bool {
            f := from;
            while true {
                if may_write_to_memory(f) && !is_assumption(f) return true;
                f = inst_next(f);
                if f == NONE || f == to break;
            }
            return false;
        }
        is_valid_assume :: (intr: Value_Id, li: Value_Id, bb: Value_Id) -> bool {
            if call_iid(intr) != IID_ASSUME return false;
            ibb := inst_block(intr);
            if ibb == bb {
                if is_impacted_in_range(inst_next(li), intr) return false;
            } else {
                preds: [..] Value_Id; preds.allocator = temp;
                block_predecessors(ibb, *preds);
                if preds.count == 0 return false;
                if preds[0] != bb return false;
                if preds.count != 1 return false;
                succs: [..] Value_Id; succs.allocator = temp;
                block_successors(bb, *succs);
                for s: succs {
                    if s == ibb continue;
                    if inst_op(block_terminator(s)) == .UNREACHABLE continue;
                    return false;
                }
                if is_impacted_in_range(inst_next(li), block_terminator(bb)) return false;
                if is_impacted_in_range(block_first(ibb), intr) return false;
            }
            return true;
        }
        a_val: Value_Id = NONE;
        a_intr: Value_Id = NONE;
        lu := ir.v_first_use[usr];
        while lu != NONE {
            cmp := ir.u_user[lu];
            if is_inst(cmp) && (inst_op(cmp) == .ICMP || inst_op(cmp) == .FCMP) {
                pred := inst_pred(cmp);
                if cmp_is_equality(pred) && cmp_is_true_when_equal(pred) {
                    cu := ir.v_first_use[cmp];
                    while cu != NONE {
                        intr := ir.u_user[cu];
                        if is_inst(intr) && is_call_base(intr) && call_is_intrinsic(intr) {
                            if is_valid_assume(intr, usr, bb) {
                                idx: u32 = ifx op_use(cmp, 0) == lu then cast(u32) 1 else 0;
                                a_val = op(cmp, idx);
                                a_intr = intr;
                                break;
                            }
                        }
                        cu = ir.u_next[cu];
                    }
                }
            }
            if a_val != NONE break;
            lu = ir.u_next[lu];
        }
        if a_val == NONE || a_intr == NONE return true;
        uai := false;
        content := atr_get_assumed_simplified_value(a_val, i, *uai, AA_INTER);
        return pi_handle_access(i, a_intr, content, AK_ASSUMPTION, pom_get(m, cur), changed, vtype(usr));
    }
    handle_store_like :: (i: u32, m: *Pi_Offset_Map, x: Value_Id, value_op: Value_Id, value_ty: Type_Id, others: [] Value_Id, ak_in: u8, cur: Value_Id, av: Value_Id, changed: *bool) -> bool {
        for others if it == cur return false;
        ak := ak_in;
        if get_underlying_object(cur) == av ak |= AK_MUST; else ak |= AK_MAY;
        uai := false;
        content: Value_Id = NONE;
        if value_op != NONE content = atr_get_assumed_simplified_value(value_op, i, *uai, AA_INTER);
        return pi_handle_access(i, x, content, ak, pom_get(m, cur), changed, value_ty);
    }
    if o == .STORE return handle_store_like(i, m, usr, op(usr, 0), vtype(op(usr, 0)), .[op(usr, 0)], AK_W, cur, av, changed);
    if o == .ATOMICRMW return handle_store_like(i, m, usr, NONE, vtype(op(usr, 1)), .[op(usr, 1)], AK_RW, cur, av, changed);
    if o == .CMPXCHG return handle_store_like(i, m, usr, NONE, vtype(op(usr, 2)), .[op(usr, 1), op(usr, 2)], AK_RW, cur, av, changed);
    if is_call_base(usr) {
        if call_is_lifetime_start_or_end(usr) return true;
        fo := get_freed_operand(usr);
        if fo != NONE && fo == cur && atr_freed_operand_use_is(usr, u) return true;
        if call_is_arg_operand(usr, u) {
            argno := use_arg_no(u);
            csa := atr_get_aa(.POINTER_INFO, irp_cs_argument(usr, argno), i, DEP_REQUIRED);
            if csa == NONE return false;
            is_arg_must := get_underlying_object(cur) == av;
            changed.* = pi_translate_and_add_state(i, csa, pom_get(m, cur), usr, is_arg_must) || changed.*;
            if !pi_reaches_return(csa) return aa_is_valid(i);
            callee := call_called_function(usr);
            if callee == NONE || fn_nargs(callee) <= argno return false;
            uai := false;
            rv := atr_get_assumed_simplified(irp_returned(callee), i, *uai, AA_INTRA);
            rarg: Value_Id = NONE;
            if rv != OV_NOVAL && rv != NONE && vkind(rv) == .ARGUMENT rarg = rv;
            arg := fn_arg(callee, argno);
            if rarg != NONE && arg != rarg return true;
            is_ret_must := is_arg_must && rarg == arg;
            csr := atr_get_aa(.POINTER_INFO, irp_cs_returned(usr), i, DEP_REQUIRED);
            if csr == NONE return false;
            oi := sset_copy(pom_get(m, cur).*);
            oi.items.allocator = temp;
            pi_add_returned_offsets_to(csa, *oi);
            changed.* = pi_translate_and_add_state(i, csr, *oi, usr, is_ret_must) || changed.*;
            return aa_is_valid(i);
        }
        return false;
    }
    return false;
}
// getFreedOperand(CB, TLI) == U: the freed operand is this use (the use's operand number)
atr_freed_operand_use_is :: (cb: Value_Id, u: Use_Id) -> bool {
    fo := get_freed_operand(cb);
    return ir.u_val[u] == fo && fo != NONE && atr_freed_operand_no(cb) == use_arg_no(u);
}
atr_freed_operand_no :: (cb: Value_Id) -> u32 {
    fo := get_freed_operand(cb);
    for k: 0..cast(s64) call_num_args(cb) - 1 if call_arg(cb, cast(u32) k) == fo return cast(u32) k;
    return 0xFFFF_FFFF;
}

// AAPointerInfoCallSiteArgument::updateImpl
pi_cs_argument_update :: (i: u32) -> bool {
    p := aa(i).pos;
    cb := irp_ctx_i(p);
    if is_mem_intrinsic_call(cb) {
        lv := PI_UNKNOWN;
        len := op(cb, 2);
        if vkind(len) == .C_INT lv = ap_sext_value(const_ap(len));
        argno := irp_cs_arg_no(p);
        if argno > 1 return aa_pessimistic(i);
        kind := ifx argno == 0 then AK_MUST | AK_W else AK_MUST | AK_R;
        return pi_add_access(i, .[.{0, lv}], cb, NONE, kind, NONE);
    }
    arg := irp_assoc_arg(p);
    if arg != NONE {
        o := atr_get_aa(.POINTER_INFO, irp_argument(arg), i, DEP_REQUIRED);
        if o != NONE && aa_is_valid(o) return pi_translate_and_add_state_from_callee(i, o, cb);
        if !is_declaration(arg_parent(arg)) return aa_pessimistic(i);
    }
    nc, _ := atr_has_assumed_ir_attr(.Captures, i, p, DEP_OPTIONAL);
    if !nc return aa_pessimistic(i);
    rn, _ := atr_is_assumed_read_none(p, i);
    if rn return ATR_UNCHANGED;
    ro, _ := atr_is_assumed_read_only(p, i);
    kind := ifx ro then AK_MAY | AK_R else AK_MAY | AK_R | AK_W;
    return pi_add_access(i, .[pi_range_unknown()], cb, NONE, kind, NONE);
}
pi_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    if pk == .RETURNED return aa_pessimistic(i);
    if pk == .CALL_SITE_ARGUMENT return pi_cs_argument_update(i);
    return pi_floating_update(i);
}
