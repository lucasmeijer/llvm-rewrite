// EarlyCSE: a port of llvm/lib/Transforms/Scalar/EarlyCSE.cpp (early-cse and early-cse<memssa>), with the
// ScopedHashTable of llvm/include/llvm/ADT/ScopedHashTable.h and replaceDominatedUsesWith(From, To, DT, Edge) of
// llvm/lib/Transforms/Utils/Local.cpp.
//
// The five scoped hash tables (AvailableValues, AvailableLoads, AvailableInvariants, AvailableCalls,
// AvailableGEPs) share one bucket store. A bucket (DenseMap entry of TopLevelMap) keeps the key of its first
// insertion and the hash computed at that time (its position in the DenseMap); lookups compare the stored hash and
// then isEqual(lookup key, bucket key), so an instruction whose operands changed after it was inserted is no longer
// found, as in LLVM (knowledge/llvm/early-cse.md). Hashes use value ids instead of pointers: only the classes of
// equal keys matter. A lookup that would read a ScopedHashTableVal LLVM has already freed (a stale bucket left by a
// scope exit that could not find its key) fails loudly.
//
// -earlycse-debug-hash only changes hashing in assertion builds; the oracle is a release build, so it is ignored.

ec_opts: struct {
    mssa_optimization_cap: s64 = 500;   // -earlycse-mssa-optimization-cap
};

early_cse_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "earlycse-debug-hash" return true;
    if name == "earlycse-mssa-optimization-cap" {
        if !has_value fatal("opt: -earlycse-mssa-optimization-cap needs a value");
        v, ok := string_to_int(value);
        if !ok fatal(tprint("opt: invalid value '%' for -earlycse-mssa-optimization-cap", value));
        ec_opts.mssa_optimization_cap = v;
        return true;
    }
    return false;
}

Ec_Table :: enum u8 { VALUES; LOADS; INVARIANTS; CALLS; GEPS; }

Ec_Key :: struct {
    tbl: Ec_Table;
    v: Value_Id = NONE;   // the instruction (VALUES, CALLS, GEPS) or the pointer (LOADS)
    has_off: bool;        // GEPValue::ConstantOffset
    off: s64;
    loc: Mem_Loc;         // INVARIANTS
}

// ScopedHashTableVal
Ec_Val :: struct {
    key: Ec_Key;
    v: Value_Id = NONE;   // the value; LoadValue::DefInst; CallValue's instruction
    gen: u32;             // LoadValue::Generation, the call's generation, the invariant's generation
    mid: s32 = -1;        // LoadValue::MatchingId
    is_atomic: bool;
    is_load: bool;
    next_key: s32 = -1;
    next_scope: s32 = -1;
    alive: bool;
}

// a TopLevelMap bucket
Ec_Bucket :: struct {
    key: Ec_Key;
    hash: u64;
    head: s32 = -1;
    live: bool;
    chain: s32 = -1;      // next bucket with the same hash
}

Early_Cse :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    sq: Simplify_Query;
    mssa: *Memory_SSA;
    aar: Aa_Results;
    mssau: Mssa_Updater;
    vals: [..] Ec_Val;
    buckets: [..] Ec_Bucket;
    by_hash: Table(u64, s32);
    scope_last: s32 = -1;
    gen: u32;
    clobber_counter: s64;
    presplit_coroutine: bool;
}

// ---------------------------------------------------------------- hashing

ec_mix :: (h: u64, x: u64) -> u64 {
    z := (h ^ x) * 0x9E37_79B9_7F4A_7C15;
    z ^= z >> 31;
    z *= 0xBF58_476D_1CE4_E5B9;
    return z ^ (z >> 29);
}
ec_hv :: inline (h: u64, v: Value_Id) -> u64 { return ec_mix(h, cast(u64) v + 7); }

ec_hash_ops_from :: (h0: u64, i: Value_Id, from: u32) -> u64 {
    h := h0;
    n := nops(i);
    k := from;
    while k < n { h = ec_hv(h, op(i, k)); k += 1; }
    return h;
}
ec_hash_indices :: (h0: u64, i: Value_Id) -> u64 {
    h := h0;
    r := inst(i);
    if r.nidx > 0 for k: 0..r.nidx - 1 h = ec_mix(h, ir.u32_pool[r.idx + k]);
    return h;
}

SPF_UNKNOWN_EC : s32 : 0; SPF_SMIN_EC : s32 : 1; SPF_UMIN_EC : s32 : 2; SPF_SMAX_EC : s32 : 3; SPF_UMAX_EC : s32 : 4;

ec_is_cmp :: (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP); }

// matchSelectWithOptionalNotCond: (is a select, Cond, A, B, Flavor)
ec_match_select :: (v: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id, s32) {
    if !is_inst(v) || inst_op(v) != .SELECT return false, NONE, NONE, NONE, SPF_UNKNOWN_EC;
    c := op(v, 0); a := op(v, 1); b := op(v, 2);
    is_not, cn := pm_not(c);
    if is_not { c = cn; t := a; a = b; b = t; }
    if !is_inst(c) || inst_op(c) != .ICMP return true, c, a, b, SPF_UNKNOWN_EC;
    p := inst(c).pred;
    if !(op(c, 0) == a && op(c, 1) == b) {
        if !(op(c, 0) == b && op(c, 1) == a) return true, c, a, b, SPF_UNKNOWN_EC;
        p = swapped_predicate(p);
    }
    f := SPF_UNKNOWN_EC;
    if p == {
        case ICMP_UGT; f = SPF_UMAX_EC; case ICMP_ULT; f = SPF_UMIN_EC; case ICMP_SGT; f = SPF_SMAX_EC; case ICMP_SLT; f = SPF_SMIN_EC;
        case ICMP_ULE; f = SPF_UMIN_EC; case ICMP_UGE; f = SPF_UMAX_EC; case ICMP_SLE; f = SPF_SMIN_EC; case ICMP_SGE; f = SPF_SMAX_EC;
    }
    return true, c, a, b, f;
}
ec_is_minmax :: (f: s32) -> bool { return f != SPF_UNKNOWN_EC; }

// IntrinsicInst::isCommutative
ec_intrinsic_is_commutative :: (i: Value_Id) -> bool { return call_iid(i) != NOT_INTRINSIC && inst_is_commutative(i); }

// hashCallInst
ec_hash_call :: (i: Value_Id) -> u64 {
    h := ec_mix(0x5EED, cast(u64) inst_op(i));
    if call_is_convergent(i) h = ec_hv(h, inst_block(i));
    return ec_hash_ops_from(h, i, 0);
}

// getHashValueImpl(SimpleValue)
ec_simple_hash :: (i: Value_Id) -> u64 {
    o := inst_op(i);
    h := ec_mix(0x5EED, cast(u64) o);
    if is_binary_op(o) {
        l := op(i, 0); r := op(i, 1);
        if is_commutative_op(o) && l > r { t := l; l = r; r = t; }
        return ec_hv(ec_hv(h, l), r);
    }
    if o == .ICMP || o == .FCMP {
        l := op(i, 0); r := op(i, 1);
        p := inst(i).pred; sp := swapped_predicate(p);
        if l > r || (l == r && p > sp) { t := l; l = r; r = t; p = sp; }
        return ec_hv(ec_hv(ec_mix(h, p), l), r);
    }
    is_sel, c, a0, b0, spf := ec_match_select(i);
    if is_sel {
        a := a0; b := b0;
        if ec_is_minmax(spf) {
            if a > b { t := a; a = b; b = t; }
            return ec_hv(ec_hv(ec_mix(h, cast(u64) spf + 100), a), b);
        }
        if !ec_is_cmp(c) return ec_hv(ec_hv(ec_hv(h, c), a), b);
        p := inst(c).pred;
        ip := cmp_inverse(p);
        if ip < p { p = ip; t := a; a = b; b = t; }
        return ec_hv(ec_hv(ec_hv(ec_hv(ec_mix(h, p), op(c, 0)), op(c, 1)), a), b);
    }
    if is_cast_op(o) return ec_hv(ec_mix(h, vtype(i)), op(i, 0));
    if o == .FREEZE return ec_hv(h, op(i, 0));
    if o == .EXTRACTVALUE return ec_hash_indices(ec_hv(h, op(i, 0)), i);
    if o == .INSERTVALUE return ec_hash_indices(ec_hv(ec_hv(h, op(i, 0)), op(i, 1)), i);
    if ec_intrinsic_is_commutative(i) && call_num_args(i) >= 2 {
        l := call_arg(i, 0); r := call_arg(i, 1);
        if l > r { t := l; l = r; r = t; }
        return ec_hash_ops_from(ec_hv(ec_hv(h, l), r), i, 2);
    }
    if call_iid(i) == IID_EXPERIMENTAL_GC_RELOCATE
        return ec_hv(ec_hv(ec_hv(h, op(i, 0)), gc_relocate_ptr(i, 1)), gc_relocate_ptr(i, 2));
    if o == .CALL return ec_hash_call(i);
    if o == .SHUFFLEVECTOR return ec_hash_indices(ec_hash_ops_from(h, i, 0), i);
    return ec_hash_ops_from(h, i, 0);
}

// isEqualImpl(SimpleValue)
ec_simple_equal :: (l: Value_Id, r: Value_Id) -> bool {
    if inst_op(l) != inst_op(r) return false;
    if inst_identical_when_defined(l, r, true) {
        if inst_op(l) == .CALL && call_is_convergent(l) && inst_block(l) != inst_block(r) return false;
        return true;
    }
    o := inst_op(l);
    if is_binary_op(o) {
        if !is_commutative_op(o) return false;
        return op(l, 0) == op(r, 1) && op(l, 1) == op(r, 0);
    }
    if o == .ICMP || o == .FCMP
        return op(l, 0) == op(r, 1) && op(l, 1) == op(r, 0) && swapped_predicate(inst(l).pred) == inst(r).pred;
    li := call_iid(l); ri := call_iid(r);
    if li != NOT_INTRINSIC && ri != NOT_INTRINSIC && li == ri && inst_is_commutative(l) && call_num_args(l) >= 2 {
        if !(call_arg(l, 0) == call_arg(r, 1) && call_arg(l, 1) == call_arg(r, 0)) return false;
        n := call_num_args(l);
        if call_num_args(r) != n return false;
        k: u32 = 2;
        while k < n { if call_arg(l, k) != call_arg(r, k) return false; k += 1; }
        return has_same_special_state(l, r, false, true);
    }
    if li == IID_EXPERIMENTAL_GC_RELOCATE && ri == IID_EXPERIMENTAL_GC_RELOCATE
        return op(l, 0) == op(r, 0) && gc_relocate_ptr(l, 1) == gc_relocate_ptr(r, 1) && gc_relocate_ptr(l, 2) == gc_relocate_ptr(r, 2);
    sl, cl, la, lb, lf := ec_match_select(l);
    if sl {
        sr, cr, ra, rb, rf := ec_match_select(r);
        if sr {
            if lf == rf {
                if ec_is_minmax(lf) return (la == ra && lb == rb) || (la == rb && lb == ra);
                if cl == cr && la == ra && lb == rb return true;
            }
            if la == rb && lb == ra {
                // m_Cmp(PredL, m_Value(X), m_Value(Y)) and m_Cmp(PredR, m_Specific(X), m_Specific(Y))
                if ec_is_cmp(cl) && ec_is_cmp(cr) && op(cr, 0) == op(cl, 0) && op(cr, 1) == op(cl, 1) &&
                   cmp_inverse(inst(cl).pred) == inst(cr).pred return true;
            }
        }
    }
    return false;
}

// DenseMapInfo<CallValue>::isEqual
ec_call_equal :: (l: Value_Id, r: Value_Id) -> bool {
    if call_is_convergent(l) && inst_block(l) != inst_block(r) return false;
    return inst_identical_when_defined(l, r, true);
}

ec_gep_hash :: (k: Ec_Key) -> u64 {
    h := ec_mix(0x5EED, cast(u64) Opcode.GEP);
    if k.has_off return ec_mix(ec_hv(h, op(k.v, 0)), cast,no_check(u64) k.off);
    return ec_hash_ops_from(h, k.v, 0);
}
ec_gep_equal :: (l: Ec_Key, r: Ec_Key) -> bool {
    if op(l.v, 0) != op(r.v, 0) return false;
    if l.has_off && r.has_off return l.off == r.off;
    return inst_identical_when_defined(l.v, r.v, false);
}

ec_loc_hash :: (m: Mem_Loc) -> u64 {
    h := ec_hv(0x1D, m.ptr);
    h = ec_mix(h, m.size);
    h = ec_mix(h, m.tags.tbaa); h = ec_mix(h, m.tags.tbaa_struct); h = ec_mix(h, m.tags.scope);
    h = ec_mix(h, m.tags.noalias); h = ec_mix(h, m.tags.noalias_as);
    return h;
}
ec_loc_equal :: (a: Mem_Loc, b: Mem_Loc) -> bool {
    return a.ptr == b.ptr && a.size == b.size && a.tags.tbaa == b.tags.tbaa && a.tags.tbaa_struct == b.tags.tbaa_struct &&
           a.tags.scope == b.tags.scope && a.tags.noalias == b.tags.noalias && a.tags.noalias_as == b.tags.noalias_as;
}

ec_hash :: (k: Ec_Key) -> u64 {
    h: u64;
    if k.tbl == {
        case .VALUES; h = ec_simple_hash(k.v);
        case .LOADS; h = ec_hv(0x10AD, k.v);
        case .INVARIANTS; h = ec_loc_hash(k.loc);
        case .CALLS; h = ec_hash_call(k.v);
        case .GEPS; h = ec_gep_hash(k);
    }
    return ec_mix(h, cast(u64) k.tbl);
}

// KeyInfo::isEqual(lookup key, bucket key)
ec_key_equal :: (a: Ec_Key, b: Ec_Key) -> bool {
    if a.tbl != b.tbl return false;
    if a.tbl == {
        case .VALUES; return a.v == b.v || ec_simple_equal(a.v, b.v);
        case .LOADS; return a.v == b.v;
        case .INVARIANTS; return ec_loc_equal(a.loc, b.loc);
        case .CALLS; return a.v == b.v || ec_call_equal(a.v, b.v);
        case .GEPS; return (a.v == b.v && a.has_off == b.has_off && a.off == b.off) || ec_gep_equal(a, b);
    }
    return false;
}

// ---------------------------------------------------------------- ScopedHashTable

ec_find :: (s: *Early_Cse, k: Ec_Key) -> s32 {
    h := ec_hash(k);
    found, b := table_find(*s.by_hash, h);
    if !found return -1;
    while b >= 0 {
        x := *s.buckets[b];
        if x.live && ec_key_equal(k, x.key) return b;
        b = x.chain;
    }
    return -1;
}

// TopLevelMap[Key]: the bucket, inserted empty when absent
ec_find_or_add :: (s: *Early_Cse, k: Ec_Key) -> s32 {
    b := ec_find(s, k);
    if b >= 0 return b;
    h := ec_hash(k);
    nb: Ec_Bucket;
    nb.key = k; nb.hash = h; nb.live = true;
    id := cast(s32) s.buckets.count;
    found, first := table_find(*s.by_hash, h);
    if found {
        x := first;
        while s.buckets[x].chain >= 0 x = s.buckets[x].chain;
        array_add(*s.buckets, nb);
        s.buckets[x].chain = id;
    } else {
        array_add(*s.buckets, nb);
        table_set(*s.by_hash, h, id);
    }
    return id;
}

// ScopedHashTable::insert into the current scope
ec_insert :: (s: *Early_Cse, k: Ec_Key, v: Value_Id, gen: u32 = 0, mid: s32 = -1, is_atomic := false, is_load := false) {
    b := ec_find_or_add(s, k);
    r := cast(s32) s.vals.count;
    val: Ec_Val;
    val.key = k; val.v = v; val.gen = gen; val.mid = mid; val.is_atomic = is_atomic; val.is_load = is_load;
    val.next_key = s.buckets[b].head; val.next_scope = s.scope_last; val.alive = true;
    array_add(*s.vals, val);
    s.buckets[b].head = r;
    s.scope_last = r;
}

// ScopedHashTable::lookup / count: the value record, -1 if none
// ScopedHashTable::count
ec_count :: (s: *Early_Cse, k: Ec_Key) -> bool { return ec_find(s, k) >= 0; }

ec_lookup :: (s: *Early_Cse, k: Ec_Key) -> s32 {
    b := ec_find(s, k);
    if b < 0 return -1;
    r := s.buckets[b].head;
    if r >= 0 && !s.vals[r].alive
        fatal("early-cse: a lookup found a stale ScopedHashTable bucket (LLVM reads freed memory here); not supported");
    return r;
}

// ~ScopedHashTableScope
ec_scope_pop :: (s: *Early_Cse, saved_last: s32) {
    r := s.scope_last;
    while r >= 0 {
        x := s.vals[r];
        if x.next_key < 0 {
            b := ec_find(s, x.key);
            if b >= 0 s.buckets[b].live = false;   // TopLevelMap.erase(Key) (a no-op when the key isn't found)
        } else {
            b := ec_find_or_add(s, x.key);
            s.buckets[b].head = x.next_key;
        }
        s.vals[r].alive = false;
        r = x.next_scope;
    }
    s.scope_last = saved_last;
}

// ---------------------------------------------------------------- SimpleValue / CallValue / GEPValue::canHandle

ec_is_constrained_handled :: (id: Intrinsic_Id) -> bool {
    n := iid_name(id);
    return n == "llvm.experimental.constrained.fadd" || n == "llvm.experimental.constrained.fsub" ||
           n == "llvm.experimental.constrained.fmul" || n == "llvm.experimental.constrained.fdiv" ||
           n == "llvm.experimental.constrained.frem" || n == "llvm.experimental.constrained.fptosi" ||
           n == "llvm.experimental.constrained.sitofp" || n == "llvm.experimental.constrained.fptoui" ||
           n == "llvm.experimental.constrained.uitofp" || n == "llvm.experimental.constrained.fcmp" ||
           n == "llvm.experimental.constrained.fcmps";
}

ec_simple_can_handle :: (s: *Early_Cse, i: Value_Id) -> bool {
    if !is_inst(i) return false;
    o := inst_op(i);
    if o == .CALL {
        if call_called_function(i) != NONE {
            id := call_iid(i);
            if id != NOT_INTRINSIC && ec_is_constrained_handled(id) {
                if constrained_md_string(i, 1) == "fpexcept.strict" return false;
                if constrained_md_string(i, 2) == "round.dynamic" return false;
                return true;
            }
        }
        return mem_does_not_access(call_memory_effects(i)) && !s.presplit_coroutine;
    }
    return is_cast_op(o) || o == .FNEG || is_binary_op(o) || o == .ICMP || o == .FCMP || o == .SELECT ||
           o == .EXTRACTELEMENT || o == .INSERTELEMENT || o == .SHUFFLEVECTOR || o == .EXTRACTVALUE ||
           o == .INSERTVALUE || o == .FREEZE;
}

ec_call_can_handle :: (s: *Early_Cse, i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    me := call_memory_effects(i);
    if (!mem_only_reads(me) && !mem_only_writes(me)) || s.presplit_coroutine return false;
    return true;
}

// ---------------------------------------------------------------- ParseMemoryInst

Ec_Mem :: struct {
    i: Value_Id;
    iid: Intrinsic_Id;    // IntrID (0 for non-intrinsics)
    ptr: Value_Id = NONE; // Info.PtrVal
    read: bool;
    write: bool;
    is_vol: bool;
    mid: s32;             // Info.MatchingId
}

ec_parse_mem :: (i: Value_Id) -> Ec_Mem {
    m: Ec_Mem;
    m.i = i;
    id := call_iid(i);
    if id == NOT_INTRINSIC return m;
    m.iid = id;
    // TTI.getTgtMemIntrinsic is false for X86 and the default target
    if id == IID_MASKED_LOAD { m.ptr = op(i, 0); m.mid = cast(s32) IID_MASKED_LOAD; m.read = true; }
    else if id == IID_MASKED_STORE { m.ptr = op(i, 1); m.mid = cast(s32) IID_MASKED_LOAD; m.write = true; }
    else if is_mem_set_inst(i) {
        m.ptr = call_arg(i, 0);
        m.mid = 0;
        m.write = true;
        m.is_vol = !is_null_value(call_arg(i, 3));
    }
    return m;
}
em_is_load :: (m: Ec_Mem) -> bool { if m.iid != NOT_INTRINSIC return m.read; return inst_op(m.i) == .LOAD; }
em_is_store :: (m: Ec_Mem) -> bool { if m.iid != NOT_INTRINSIC return m.write; return inst_op(m.i) == .STORE; }
em_is_atomic :: (m: Ec_Mem) -> bool { if m.iid != NOT_INTRINSIC return false; return inst_is_atomic(m.i); }
em_is_unordered :: (m: Ec_Mem) -> bool {
    if m.iid != NOT_INTRINSIC return !m.is_vol;
    o := inst_op(m.i);
    if o == .LOAD || o == .STORE return is_unordered(m.i);
    return !inst_is_atomic(m.i);
}
em_is_volatile :: (m: Ec_Mem) -> bool {
    if m.iid != NOT_INTRINSIC return m.is_vol;
    o := inst_op(m.i);
    if o == .LOAD || o == .STORE return (inst(m.i).flags & F_VOLATILE) != 0;
    return true;
}
em_is_invariant_load :: (m: Ec_Mem) -> bool { return inst_op(m.i) == .LOAD && get_metadata(m.i, MDK_INVARIANT_LOAD) != NONE; }
em_ptr :: (m: Ec_Mem) -> Value_Id {
    if m.iid != NOT_INTRINSIC return m.ptr;
    o := inst_op(m.i);
    if o == .LOAD return op(m.i, 0);
    if o == .STORE return op(m.i, 1);
    return NONE;
}
em_valid :: (m: Ec_Mem) -> bool { return em_ptr(m) != NONE; }
em_matching_id :: (m: Ec_Mem) -> s32 { if m.iid != NOT_INTRINSIC return m.mid; return -1; }
em_value_type :: (m: Ec_Mem) -> Type_Id { return ec_access_type(m.i); }
em_may_read :: (m: Ec_Mem) -> bool { if m.iid != NOT_INTRINSIC return m.read; return may_read_from_memory(m.i); }

// Instruction::getAccessType; NONE = nullptr
ec_access_type :: (i: Value_Id) -> Type_Id {
    o := inst_op(i);
    if o == .STORE return vtype(op(i, 0));
    if o == .LOAD || o == .ATOMICRMW return vtype(i);
    if o == .CMPXCHG return vtype(op(i, 2));
    if o == .CALL || o == .INVOKE {
        id := call_iid(i);
        if id != NOT_INTRINSIC {
            n := iid_name(id);
            if n == "llvm.masked.load" || n == "llvm.masked.gather" || n == "llvm.masked.expandload" || n == "llvm.vp.load" ||
               n == "llvm.vp.gather" || n == "llvm.experimental.vp.strided.load" return vtype(i);
            if n == "llvm.masked.store" || n == "llvm.masked.scatter" || n == "llvm.masked.compressstore" || n == "llvm.vp.store" ||
               n == "llvm.vp.scatter" || n == "llvm.experimental.vp.strided.store" return vtype(op(i, 0));
        }
    }
    return NONE;
}

ec_is_handled_non_target_intrinsic :: (v: Value_Id) -> bool {
    id := call_iid(v);
    return id != NOT_INTRINSIC && (id == IID_MASKED_LOAD || id == IID_MASKED_STORE);
}

// getOrCreateResult(Inst, ExpectedType, CanCreate)
ec_get_or_create_result :: (i: Value_Id, expected: Type_Id) -> Value_Id {
    v: Value_Id;
    id := call_iid(i);
    if id != NOT_INTRINSIC {
        if id == IID_MASKED_LOAD v = i;
        else if id == IID_MASKED_STORE v = op(i, 0);
        else return NONE;   // TTI.getOrCreateResultFromMemIntrinsic: nullptr on X86 / the default target
    } else {
        v = ifx inst_op(i) == .LOAD then i else op(i, 0);
    }
    if vtype(v) == expected return v;
    return NONE;
}

// isNonTargetIntrinsicMatch
ec_is_submask :: (m0: Value_Id, m1: Value_Id) -> bool {
    if m0 == m1 return true;
    if pm_undef_value(m0) || pm_undef_value(m1) return false;
    if vkind(m0) != .C_VECTOR || vkind(m1) != .C_VECTOR return false;
    if vtype(m0) != vtype(m1) return false;
    n := nops(m0);
    if n > 0 for k: 0..n - 1 {
        e0 := op(m0, k); e1 := op(m1, k);
        if vkind(e0) == .C_INT && is_null_value(e0) continue;
        if vkind(e1) == .C_INT && !is_null_value(e1) continue;
        if pm_undef_value(e0) || pm_undef_value(e1) return false;
        if e0 == e1 continue;
        return false;
    }
    return true;
}
ec_non_target_intrinsic_match :: (earlier: Value_Id, later: Value_Id) -> bool {
    ptr_op :: (i: Value_Id) -> Value_Id { if call_iid(i) == IID_MASKED_LOAD return op(i, 0); return op(i, 1); }
    mask_op :: (i: Value_Id) -> Value_Id { if call_iid(i) == IID_MASKED_LOAD return op(i, 1); return op(i, 2); }
    thru_op :: (i: Value_Id) -> Value_Id { return op(i, 2); }
    if ptr_op(earlier) != ptr_op(later) return false;
    ide := call_iid(earlier); idl := call_iid(later);
    if ide == IID_MASKED_LOAD && idl == IID_MASKED_LOAD {
        if mask_op(earlier) == mask_op(later) && thru_op(earlier) == thru_op(later) return true;
        if !pm_undef_value(thru_op(later)) return false;
        return ec_is_submask(mask_op(later), mask_op(earlier));
    }
    if ide == IID_MASKED_STORE && idl == IID_MASKED_LOAD {
        if !ec_is_submask(mask_op(later), mask_op(earlier)) return false;
        return pm_undef_value(thru_op(later));
    }
    if ide == IID_MASKED_LOAD && idl == IID_MASKED_STORE return ec_is_submask(mask_op(later), mask_op(earlier));
    if ide == IID_MASKED_STORE && idl == IID_MASKED_STORE return ec_is_submask(mask_op(earlier), mask_op(later));
    return false;
}

ec_remove_mssa :: (s: *Early_Cse, i: Value_Id) {
    if !s.mssa return;
    mssau_remove_memory_access_inst(*s.mssau, i, true);
}

ec_erase :: (s: *Early_Cse, i: Value_Id) {
    ec_remove_mssa(s, i);
    erase_inst_with_metadata(i);
}

// isSameMemGeneration
ec_is_same_mem_generation :: (s: *Early_Cse, earlier_gen: u32, later_gen: u32, earlier_i: Value_Id, later_i: Value_Id) -> bool {
    if earlier_gen == later_gen return true;
    if !s.mssa return false;
    earlier_ma := mssa_access_of(s.mssa, earlier_i);
    if earlier_ma < 0 return true;
    later_ma := mssa_access_of(s.mssa, later_i);
    if later_ma < 0 return true;
    later_def: s32;
    if s.clobber_counter < ec_opts.mssa_optimization_cap {
        later_def = mssa_get_clobbering_access(s.mssa, later_ma, aa_query_new(*s.aar));   // a fresh BatchAAResults
        s.clobber_counter += 1;
    } else {
        later_def = ma_defining(s.mssa, later_ma);
    }
    return mssa_dominates(s.mssa, later_def, earlier_ma);
}

// isOperatingOnInvariantMemAt
ec_is_operating_on_invariant_mem_at :: (s: *Early_Cse, i: Value_Id, gen_at: u32) -> bool {
    if inst_op(i) == .LOAD && get_metadata(i, MDK_INVARIANT_LOAD) != NONE return true;
    ok, loc := mloc_get_or_none(i);
    if !ok return false;
    k: Ec_Key; k.tbl = .INVARIANTS; k.loc = loc;
    if !ec_count(s, k) return false;
    r := ec_lookup(s, k);
    return s.vals[r].gen <= gen_at;
}

// replaceDominatedUsesWith(From, To, DT, BasicBlockEdge(Start, End))
replace_dominated_uses_with_edge :: (dt: *Dom_Tree, from: Value_Id, to: Value_Id, e_start: Value_Id, e_end: Value_Id) -> s64 {
    count := 0;
    u := ir.v_first_use[from];
    while u != NONE {
        nu := ir.u_next[u];
        usr := ir.u_user[u];
        if !(is_inst(usr) && call_iid(usr) == IID_FAKE_USE) && dt_dominates_edge_use(dt, e_start, e_end, u) {
            set_op(usr, cast(u32) (u - ir.v_ops[usr]), to);
            count += 1;
        }
        u = nu;
    }
    return count;
}

// handleBranchCondition
ec_handle_branch_condition :: (s: *Early_Cse, cond_inst: Value_Id, bi: Value_Id, bb: Value_Id, pred: Value_Id) -> bool {
    is_true := get_successor(bi, 0) == bb;
    torf := const_int(ir.t_i1, ifx is_true then cast(u64) 1 else 0);
    made_changes := false;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*work, cond_inst);
    while work.count {
        curr := pop(*work);
        k: Ec_Key; k.tbl = .VALUES; k.v = curr;
        ec_insert(s, k, torf);
        if replace_dominated_uses_with_edge(s.dt, curr, torf, pred, bb) > 0 made_changes = true;
        ok: bool; lhs, rhs: Value_Id;
        if is_true ok, lhs, rhs = pm_logical_and(curr);
        else ok, lhs, rhs = pm_logical_or(curr);
        if ok for o: Value_Id.[lhs, rhs] {
            if is_inst(o) && ec_simple_can_handle(s, o) && !table_contains(*visited, o) {
                table_set(*visited, o, true);
                array_add(*work, o);
            }
        }
    }
    return made_changes;
}

// getMatchingValue
ec_get_matching_value :: (s: *Early_Cse, in_val: s32, m: Ec_Mem, cur_gen: u32) -> Value_Id {
    if in_val < 0 return NONE;
    iv := s.vals[in_val];
    def := iv.v;
    if def == NONE return NONE;
    if is_mem_set_inst(def) {
        if !em_is_load(m) || em_is_volatile(m) || !em_is_unordered(m) || em_matching_id(m) != -1 return NONE;
        if !is_null_value(call_arg(def, 3)) return NONE;   // MSI->isVolatile()
        val := call_arg(def, 1);
        if vkind(val) != .C_INT || !is_null_value(val) return NONE;
        len := call_arg(def, 2);
        if vkind(len) != .C_INT return NONE;
        ty := em_value_type(m);
        if ty == NONE return NONE;
        if type_is_scalable(ty) || ap_ult_u64(const_ap(len), dl_type_store_size(ty)) return NONE;
        if !ec_is_operating_on_invariant_mem_at(s, m.i, iv.gen) && !ec_is_same_mem_generation(s, iv.gen, cur_gen, def, m.i) return NONE;
        return const_null_value(ty);
    }
    if iv.mid != em_matching_id(m) return NONE;
    if em_is_volatile(m) || !em_is_unordered(m) return NONE;
    if em_is_load(m) && !iv.is_atomic && em_is_atomic(m) return NONE;
    mem_inst_matching := !em_is_load(m);
    matching := ifx mem_inst_matching then m.i else def;
    other := ifx mem_inst_matching then def else m.i;
    result: Value_Id = NONE;
    if em_is_store(m) {
        result = ec_get_or_create_result(matching, vtype(other));
        if def != result return NONE;
    }
    matching_nti := ec_is_handled_non_target_intrinsic(matching);
    other_nti := ec_is_handled_non_target_intrinsic(other);
    if other_nti != matching_nti return NONE;
    if other_nti && matching_nti && !ec_non_target_intrinsic_match(def, m.i) return NONE;
    if !ec_is_operating_on_invariant_mem_at(s, m.i, iv.gen) && !ec_is_same_mem_generation(s, iv.gen, cur_gen, def, m.i) return NONE;
    if result == NONE result = ec_get_or_create_result(matching, vtype(other));
    return result;
}

// combineIRFlags
ec_combine_ir_flags :: (from: Value_Id, to: Value_Id) {
    if is_inst(to) {
        if is_fp_math_op_value(to) || (has_poison_generating_flags(to) && !program_undefined_if_poison(to)) and_ir_flags(to, from);
    }
    if is_call_base(from) && is_inst(to) && is_call_base(to) try_intersect_attributes(to, from);
}

// overridingStores
ec_overriding_stores :: (earlier: Ec_Mem, later: Ec_Mem) -> bool {
    if em_ptr(earlier) != em_ptr(later) return false;
    et := em_value_type(earlier); lt := em_value_type(later);
    if et == NONE || lt == NONE || et != lt return false;
    if em_matching_id(earlier) != em_matching_id(later) return false;
    if !em_is_unordered(earlier) || !em_is_unordered(later) return false;
    enti := ec_is_handled_non_target_intrinsic(earlier.i);
    lnti := ec_is_handled_non_target_intrinsic(later.i);
    if enti && lnti return ec_non_target_intrinsic_match(earlier.i, later.i);
    return enti == lnti;
}

ec_salvage_knowledge :: (s: *Early_Cse, i: Value_Id) { salvage_knowledge(i, s.ac); }

// processNode
ec_process_node :: (s: *Early_Cse, bb: Value_Id) -> bool {
    changed := false;
    pred := block_single_predecessor(bb);
    if pred == NONE s.gen += 1;
    if pred != NONE {
        bi := block_terminator(pred);
        if bi != NONE && inst_op(bi) == .CONDBR {
            c := op(bi, 0);
            if is_inst(c) && ec_simple_can_handle(s, c) changed |= ec_handle_branch_condition(s, c, bi, bb, pred);
        }
    }
    last_store: Value_Id = NONE;
    i := block(bb).first;
    while i != NONE {
        nxt := inst(i).next;
        defer i = nxt;
        if is_instruction_trivially_dead(i) {
            ec_salvage_knowledge(s, i);
            salvage_debug_info(i);
            ec_erase(s, i);
            changed = true;
            continue;
        }
        id := call_iid(i);
        if id == IID_ASSUME {
            c := call_arg(i, 0);
            if is_inst(c) && ec_simple_can_handle(s, c) {
                k: Ec_Key; k.tbl = .VALUES; k.v = c;
                ec_insert(s, k, const_int(ir.t_i1, 1));
            }
            continue;
        }
        if id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_SIDEEFFECT || id == IID_PSEUDOPROBE continue;
        if id == IID_INVARIANT_START {
            if has_uses(i) continue;
            k: Ec_Key; k.tbl = .INVARIANTS; k.loc = mloc_for_argument(i, 1, true);
            if !ec_count(s, k) ec_insert(s, k, NONE, s.gen);
            continue;
        }
        if is_guard(i) {
            c := call_arg(i, 0);
            if is_inst(c) && ec_simple_can_handle(s, c) {
                k: Ec_Key; k.tbl = .VALUES; k.v = c;
                r := ec_lookup(s, k);
                if r >= 0 && s.vals[r].v != NONE {
                    known := s.vals[r].v;
                    if vkind(known) == .C_INT && is_one_value(known) {
                        ec_salvage_knowledge(s, i);
                        ec_erase(s, i);
                        changed = true;
                        continue;
                    } else {
                        call_set_arg(i, 0, known);
                    }
                }
                ec_insert(s, k, const_int(ir.t_i1, 1));
            }
            last_store = NONE;
            continue;
        }
        // simplifyInstruction(&Inst, SQ)
        v := simplify_instruction(i, s.sq);
        if v != NONE {
            killed := false;
            if has_uses(i) { rauw_with_metadata(i, v); changed = true; }
            if is_instruction_trivially_dead(i) {
                ec_salvage_knowledge(s, i);
                ec_erase(s, i);
                changed = true;
                killed = true;
            }
            if killed continue;
        }
        if may_throw(i) last_store = NONE;
        if ec_simple_can_handle(s, i) {
            k: Ec_Key; k.tbl = .VALUES; k.v = i;
            r := ec_lookup(s, k);
            if r >= 0 && s.vals[r].v != NONE {
                to := s.vals[r].v;
                ec_combine_ir_flags(i, to);
                rauw_with_metadata(i, to);
                ec_salvage_knowledge(s, i);
                ec_erase(s, i);
                changed = true;
                continue;
            }
            ec_insert(s, k, i);
            continue;
        }
        m := ec_parse_mem(i);
        if em_valid(m) && em_is_load(m) {
            if em_is_volatile(m) || !em_is_unordered(m) { last_store = NONE; s.gen += 1; }
            if em_is_invariant_load(m) {
                k: Ec_Key; k.tbl = .INVARIANTS; k.loc = mloc_get(i);
                if !ec_count(s, k) ec_insert(s, k, NONE, s.gen);
            }
            lk: Ec_Key; lk.tbl = .LOADS; lk.v = em_ptr(m);
            in_val := ec_lookup(s, lk);
            o := ec_get_matching_value(s, in_val, m, s.gen);
            if o != NONE {
                if s.vals[in_val].is_load && is_inst(o) combine_metadata_for_cse(o, i, false);
                if has_uses(i) rauw_with_metadata(i, o);
                ec_salvage_knowledge(s, i);
                ec_erase(s, i);
                changed = true;
                continue;
            }
            ec_insert(s, lk, i, s.gen, em_matching_id(m), em_is_atomic(m), em_is_load(m));
            last_store = NONE;
            continue;
        }
        if may_read_from_memory(i) && !(em_valid(m) && !em_may_read(m)) last_store = NONE;
        if ec_call_can_handle(s, i) && (!em_valid(m) || !em_is_store(m)) && !is_mem_set_inst(i) {
            k: Ec_Key; k.tbl = .CALLS; k.v = i;
            r := ec_lookup(s, k);
            if r >= 0 && s.vals[r].v != NONE {
                first := s.vals[r].v;
                if ec_is_same_mem_generation(s, s.vals[r].gen, s.gen, first, i) && may_read_from_memory(first) == may_read_from_memory(i) {
                    ec_combine_ir_flags(i, first);
                    if has_uses(i) rauw_with_metadata(i, first);
                    ec_salvage_knowledge(s, i);
                    ec_erase(s, i);
                    changed = true;
                    continue;
                }
            }
            if may_write_to_memory(i) s.gen += 1;
            ec_insert(s, k, i, s.gen);
            continue;
        }
        if inst_op(i) == .GEP {
            bits := dl_index_type_size_bits(vtype(i));
            ok, off := gep_accumulate_constant_offset(i, ap_zero(bits));
            k: Ec_Key; k.tbl = .GEPS; k.v = i;
            if ok && ap_min_signed_bits(off) <= 64 { k.has_off = true; k.off = ap_sext_value(off); }
            r := ec_lookup(s, k);
            if r >= 0 && s.vals[r].v != NONE {
                to := s.vals[r].v;
                ec_combine_ir_flags(i, to);
                rauw_with_metadata(i, to);
                ec_salvage_knowledge(s, i);
                ec_erase(s, i);
                changed = true;
                continue;
            }
            ec_insert(s, k, i);
            continue;
        }
        if inst_op(i) == .FENCE && inst(i).ord1 == ORD_RELEASE continue;
        if em_valid(m) && em_is_store(m) {
            lk: Ec_Key; lk.tbl = .LOADS; lk.v = em_ptr(m);
            in_val := ec_lookup(s, lk);
            if in_val >= 0 && s.vals[in_val].v != NONE && s.vals[in_val].v == ec_get_matching_value(s, in_val, m, s.gen) {
                ec_salvage_knowledge(s, i);
                ec_erase(s, i);
                changed = true;
                continue;
            }
        }
        if may_write_to_memory(i) {
            s.gen += 1;
            if em_valid(m) && em_is_store(m) {
                if last_store != NONE {
                    if ec_overriding_stores(ec_parse_mem(last_store), m) {
                        ec_salvage_knowledge(s, i);
                        ec_erase(s, last_store);
                        changed = true;
                        last_store = NONE;
                    }
                }
                lk: Ec_Key; lk.tbl = .LOADS; lk.v = em_ptr(m);
                ec_insert(s, lk, i, s.gen, em_matching_id(m), em_is_atomic(m), em_is_load(m));
                if em_is_unordered(m) && !em_is_volatile(m) last_store = i;
                else last_store = NONE;
            }
        }
    }
    return changed;
}

Ec_Stack_Node :: struct {
    cur_gen: u32;
    child_gen: u32;
    node: s32;
    child: s32;           // the next child to push
    saved_scope: s32;     // LastValInScope of the enclosing scope
    processed: bool;
}

early_cse_run :: (f: Value_Id, name: string) -> Preserved {
    use_mssa := false;
    if name == "early-cse" || name == "early-cse<>" use_mssa = false;
    else if name == "early-cse<memssa>" use_mssa = true;
    else fatal("invalid pass pipeline: invalid EarlyCSE pass parameter in '%'", name);
    s: Early_Cse;
    s.f = f;
    s.dt = get_domtree(f);
    s.ac = get_assumption_cache(f);
    s.sq.dt = s.dt; s.sq.ac = s.ac;
    if use_mssa { s.mssa = get_memoryssa(f); s.dt = get_domtree(f); s.sq.dt = s.dt; s.aar = aa_results_for(f); }
    s.mssau.mssa = s.mssa;
    s.vals.allocator = temp; s.buckets.allocator = temp; s.by_hash.allocator = temp;
    s.presplit_coroutine = fn_has_fn_attr(f, .PresplitCoroutine);
    changed := false;
    stack: [..] Ec_Stack_Node; stack.allocator = temp;
    root := s.dt.root_node;
    array_add(*stack, .{cur_gen = s.gen, child_gen = s.gen, node = root, child = s.dt.nodes[root].first_child, saved_scope = s.scope_last});
    s.scope_last = -1;   // a new scope starts with LastValInScope = null
    while stack.count {
        top := *stack[stack.count - 1];
        s.gen = top.cur_gen;
        if !top.processed {
            changed |= ec_process_node(*s, s.dt.nodes[top.node].block);
            top = *stack[stack.count - 1];
            top.child_gen = s.gen;
            top.processed = true;
        } else if top.child >= 0 {
            c := top.child;
            top.child = s.dt.nodes[c].sibling;
            g := top.child_gen;
            array_add(*stack, .{cur_gen = g, child_gen = g, node = c, child = s.dt.nodes[c].first_child, saved_scope = s.scope_last});
            s.scope_last = -1;
        } else {
            ec_scope_pop(*s, top.saved_scope);
            pop(*stack);
        }
    }
    if !changed return PRESERVE_ALL;
    // PA.preserveSet<CFGAnalyses>() (+ MemorySSA, which is invalidated anyway since AAManager is not preserved)
    return preserved_cfg();
}
