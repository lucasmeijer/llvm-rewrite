// MemorySSA: a port of llvm/lib/Analysis/MemorySSA.cpp (construction: createNewAccess, placePHINodes, renamePass,
// markUnreachableAsLiveOnEntry; the mutation API used by MemorySSAUpdater: createDefinedAccess, createMemoryPhi,
// insertIntoListsForBlock / insertIntoListsBefore, moveTo, removeFromLookups / removeFromLists; verifyMemorySSA;
// OptimizeUses (ensureOptimizedUses); the ClobberWalker with phi optimization and the CachingWalker / SkipSelfWalker
// entry points; dominance between accesses; the print<memoryssa> and print<memoryssa-walker> annotated printers),
// of the MemoryAccess / MemoryUseOrDef / MemoryDef / MemoryPhi classes and upward_defs_iterator / def_chain from
// llvm/include/llvm/Analysis/MemorySSA.h, of llvm/lib/Analysis/PHITransAddr.cpp (translateValue), and of the parts
// of llvm/lib/IR/Value.cpp / User.cpp / Use.cpp that decide the order of MemoryAccess use lists (Use::set,
// doRAUW, replaceUsesWithIf, growHungoffUses) and llvm/include/llvm/IR/ValueHandle.h (WeakVH, TrackingVH).
//
// Data-oriented: a MemorySSA is a table of Mem_Access rows (index 0 = liveOnEntry); a row's kind (DEF / USE / PHI) is
// a tag. Operands are Mssa_Use rows (m.uses), contiguous per access (`ops`, `nops`; a DEF has 2: defining access and
// optimized access, a USE 1, a PHI its incoming values with the incoming block in `blk`, grown like a hung-off
// operand list). Every access has a use list (`first_use`, uses linked through next/prev, push-front like
// Use::addToList), so users() / uses() / RAUW visit uses in LLVM's order. Per-block access and def lists are intrusive
// doubly linked lists through the rows (prev/next and dprev/dnext), with heads in `blocks`. Deleted accesses keep
// their row with `dead` set; ids are never reused. Value handles (WeakVH / TrackingVH on MemoryAccesses, used by the
// updater) are rows of `vh`, allocated stack-like by the updater. The result lives on the heap (cached in the
// function analysis manager); AA query state (BatchAAResults) lives in temp for one construction / walk / printer run.
//
// Not ported: loop-scoped MemorySSA (MemorySSA(Loop&), only used by LoopSink's legacy path), -dot-cfg-mssa.

MSSA_LIVE_ON_ENTRY :: cast(s32) 0;
MSSA_INVALID_ID :: 0xFFFF_FFFF;

mssa_opts: struct {
    max_check_limit: s64 = 100;     // -memssa-check-limit
    verify := false;                // -verify-memoryssa (VerifyMemorySSA)
};

Ma_Kind :: enum u8 { DEF; USE; PHI; }

Mem_Access :: struct {
    kind: Ma_Kind;
    id: u32;                        // DEF / PHI (liveOnEntry = 0); uses have no id
    inst: Value_Id = NONE;          // DEF / USE
    block: Value_Id = NONE;
    ops: s32 = -1;                  // first operand (row of m.uses)
    nops: u32;                      // DEF 2, USE 1, PHI number of incoming values
    cap: u32;                       // PHI ReservedSpace
    first_use: s32 = -1;            // head of this access's use list
    optimized_id: u32 = MSSA_INVALID_ID;
    prev: s32 = -1; next: s32 = -1;     // the block's access list
    dprev: s32 = -1; dnext: s32 = -1;   // the block's defs list (DEFs and PHIs)
    in_lists: bool;
    dead: bool;
}

// one operand slot (llvm::Use of a MemoryAccess user)
Mssa_Use :: struct {
    val: s32 = -1;          // the used access (-1 = nullptr)
    user: s32 = -1;
    next: s32 = -1;
    prev: s32 = -1;
    blk: Value_Id = NONE;   // MemoryPhi incoming block of this operand
}

// a WeakVH (tracking = false: nulled on deletion) or TrackingVH (also follows RAUW)
Mssa_Vh :: struct { a: s32; tracking: bool; }

Mssa_Block :: struct { first: s32 = -1; last: s32 = -1; dfirst: s32 = -1; dlast: s32 = -1; }

Memory_SSA :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    aar: Aa_Results;
    acc: [..] Mem_Access;
    uses: [..] Mssa_Use;
    vh: [..] Mssa_Vh;
    next_id: u32;
    of_value: Table(Value_Id, s32);      // ValueToMemoryAccess (instructions; blocks -> their MemoryPhi)
    blocks: Table(Value_Id, Mssa_Block); // PerBlockAccesses / PerBlockDefs
    numbering: Table(s32, u32);          // BlockNumbering
    numbered: Table(Value_Id, bool);     // BlockNumberingValid
    is_optimized: bool;
}

mssa_free :: (m: *Memory_SSA) {
    array_free(m.acc); array_free(m.uses); array_free(m.vh);
    deinit(*m.of_value); deinit(*m.blocks); deinit(*m.numbering); deinit(*m.numbered);
    free(m);
}

ma :: inline (m: *Memory_SSA, a: s32) -> *Mem_Access { return *m.acc[a]; }
mssa_access_of :: (m: *Memory_SSA, v: Value_Id) -> s32 {   // getMemoryAccess(I) / getMemoryAccess(BB)
    found, a := table_find(*m.of_value, v);
    if found return a;
    return -1;
}
mssa_block :: (m: *Memory_SSA, b: Value_Id) -> *Mssa_Block { return table_find_pointer(*m.blocks, b); }
mssa_block_or_create :: (m: *Memory_SSA, b: Value_Id) -> *Mssa_Block {
    p := table_find_pointer(*m.blocks, b);
    if p return p;
    blank: Mssa_Block;
    table_set(*m.blocks, b, blank);
    return table_find_pointer(*m.blocks, b);
}
is_live_on_entry :: inline (a: s32) -> bool { return a == MSSA_LIVE_ON_ENTRY; }
ma_is_use :: inline (m: *Memory_SSA, a: s32) -> bool { return m.acc[a].kind == .USE; }
ma_is_def :: inline (m: *Memory_SSA, a: s32) -> bool { return m.acc[a].kind == .DEF; }
ma_is_phi :: inline (m: *Memory_SSA, a: s32) -> bool { return m.acc[a].kind == .PHI; }
ma_block :: inline (m: *Memory_SSA, a: s32) -> Value_Id { return m.acc[a].block; }
ma_inst :: inline (m: *Memory_SSA, a: s32) -> Value_Id { return m.acc[a].inst; }

// ---------------------------------------------------------------- operands, use lists, value handles

ma_op :: inline (m: *Memory_SSA, a: s32, k: u32) -> s32 { return m.uses[m.acc[a].ops + cast(s32) k].val; }
ma_op_use :: inline (m: *Memory_SSA, a: s32, k: u32) -> s32 { return m.acc[a].ops + cast(s32) k; }
ma_nops :: inline (m: *Memory_SSA, a: s32) -> u32 { return m.acc[a].nops; }

mu_unlink :: (m: *Memory_SSA, u: s32) {
    r := *m.uses[u];
    if r.prev >= 0 m.uses[r.prev].next = r.next;
    else m.acc[r.val].first_use = r.next;
    if r.next >= 0 m.uses[r.next].prev = r.prev;
    r.next = -1; r.prev = -1;
}
// Use::set(V): unlink from the old value's list, push at the front of V's
mu_set :: (m: *Memory_SSA, u: s32, v: s32) {
    if m.uses[u].val >= 0 mu_unlink(m, u);
    r := *m.uses[u];
    r.val = v;
    if v >= 0 {
        h := m.acc[v].first_use;
        r.next = h; r.prev = -1;
        if h >= 0 m.uses[h].prev = u;
        m.acc[v].first_use = u;
    }
}
ma_set_op :: inline (m: *Memory_SSA, a: s32, k: u32, v: s32) { mu_set(m, ma_op_use(m, a, k), v); }

ma_has_uses :: inline (m: *Memory_SSA, a: s32) -> bool { return m.acc[a].first_use >= 0; }
// users() of an access in use-list order (one entry per use)
ma_users :: (m: *Memory_SSA, a: s32, out: *[..] s32) {
    out.count = 0;
    u := m.acc[a].first_use;
    while u >= 0 { array_add(out, m.uses[u].user); u = m.uses[u].next; }
}
ma_uses :: (m: *Memory_SSA, a: s32, out: *[..] s32) {
    out.count = 0;
    u := m.acc[a].first_use;
    while u >= 0 { array_add(out, u); u = m.uses[u].next; }
}

vh_new :: (m: *Memory_SSA, a: s32, tracking: bool) -> s32 {
    array_add(*m.vh, .{a, tracking});
    return cast(s32)(m.vh.count - 1);
}
vh_get :: inline (m: *Memory_SSA, h: s32) -> s32 { return m.vh[h].a; }
vh_set :: inline (m: *Memory_SSA, h: s32, a: s32) { m.vh[h].a = a; }
// ValueHandleBase::ValueIsRAUWd
vh_rauw :: (m: *Memory_SSA, old: s32, new: s32) {
    for * m.vh if it.a == old && it.tracking it.a = new;
}
// ValueHandleBase::ValueIsDeleted
vh_deleted :: (m: *Memory_SSA, a: s32) {
    for * m.vh if it.a == a it.a = -1;
}

// MemoryAccess::replaceAllUsesWith (Value::doRAUW)
ma_rauw :: (m: *Memory_SSA, old: s32, new: s32) {
    vh_rauw(m, old, new);
    while m.acc[old].first_use >= 0 mu_set(m, m.acc[old].first_use, new);
}

// MemoryPhi accessors
mphi_value :: inline (m: *Memory_SSA, p: s32, k: u32) -> s32 { return ma_op(m, p, k); }
mphi_block :: inline (m: *Memory_SSA, p: s32, k: u32) -> Value_Id { return m.uses[ma_op_use(m, p, k)].blk; }
mphi_set_value :: inline (m: *Memory_SSA, p: s32, k: u32, v: s32) { ma_set_op(m, p, k, v); }
mphi_set_block :: inline (m: *Memory_SSA, p: s32, k: u32, b: Value_Id) { m.uses[ma_op_use(m, p, k)].blk = b; }
// getBasicBlockIndex
mphi_block_index :: (m: *Memory_SSA, p: s32, b: Value_Id) -> s64 {
    n := ma_nops(m, p);
    for k: 0..cast(s64) n - 1 if mphi_block(m, p, cast(u32) k) == b return k;
    return -1;
}
// getIncomingValueForBlock
mphi_value_for_block :: (m: *Memory_SSA, p: s32, b: Value_Id) -> s32 {
    k := mphi_block_index(m, p, b);
    assert(k >= 0, "MemoryPhi: invalid basic block argument");
    return mphi_value(m, p, cast(u32) k);
}
// growOperands + User::growHungoffUses: a new operand range; copying moves each use to the front of its value's list
mphi_grow :: (m: *Memory_SSA, p: s32) {
    r := ma(m, p);
    e := r.nops;
    new_cap := max(e + e / 2, cast(u32) 2);
    start := cast(s32) m.uses.count;
    for 0..new_cap - 1 { blank: Mssa_Use; blank.user = p; array_add(*m.uses, blank); }
    old := r.ops;
    for k: 0..cast(s64) e - 1 {
        ou := old + cast(s32) k;
        nu := start + cast(s32) k;
        m.uses[nu].blk = m.uses[ou].blk;
        mu_set(m, nu, m.uses[ou].val);
    }
    for k: 0..cast(s64) e - 1 { ou := old + cast(s32) k; if m.uses[ou].val >= 0 mu_unlink(m, ou); m.uses[ou].val = -1; }
    r = ma(m, p);
    r.ops = start;
    r.cap = new_cap;
}
// addIncoming
mphi_add_incoming :: (m: *Memory_SSA, p: s32, v: s32, b: Value_Id) {
    if m.acc[p].nops == m.acc[p].cap mphi_grow(m, p);
    r := ma(m, p);
    k := r.nops;
    r.nops += 1;
    mphi_set_value(m, p, k, v);
    mphi_set_block(m, p, k, b);
}
// unorderedDeleteIncoming
mphi_unordered_delete_incoming :: (m: *Memory_SSA, p: s32, i: u32) {
    e := m.acc[p].nops;
    assert(i < e && e >= 2, "MemoryPhi: cannot remove this incoming value");
    mphi_set_value(m, p, i, mphi_value(m, p, e - 1));
    mphi_set_block(m, p, i, mphi_block(m, p, e - 1));
    ma_set_op(m, p, e - 1, -1);
    mphi_set_block(m, p, e - 1, NONE);
    m.acc[p].nops -= 1;
}
// unorderedDeleteIncomingBlock
mphi_unordered_delete_incoming_block :: (m: *Memory_SSA, p: s32, b: Value_Id) {
    i: s64 = 0;
    while i < m.acc[p].nops {
        if mphi_block(m, p, cast(u32) i) == b { mphi_unordered_delete_incoming(m, p, cast(u32) i); continue; }
        i += 1;
    }
    assert(m.acc[p].nops >= 1, "Cannot remove all incoming blocks in a MemoryPhi.");
}

// MemoryUseOrDef::getDefiningAccess
ma_defining :: inline (m: *Memory_SSA, a: s32) -> s32 { return ma_op(m, a, 0); }
// MemoryDef::getOptimized operand
ma_optimized_op :: inline (m: *Memory_SSA, a: s32) -> s32 { return ma_op(m, a, 1); }

// MemoryUseOrDef::isOptimized / getOptimized / setOptimized / resetOptimized
ma_is_optimized :: (m: *Memory_SSA, a: s32) -> bool {
    r := ma(m, a);
    if r.kind == .DEF { o := ma_optimized_op(m, a); return o >= 0 && r.optimized_id == m.acc[o].id; }
    d := ma_defining(m, a);
    return d >= 0 && r.optimized_id == m.acc[d].id;
}
ma_get_optimized :: (m: *Memory_SSA, a: s32) -> s32 {
    if m.acc[a].kind == .DEF return ma_optimized_op(m, a);
    return ma_defining(m, a);
}
ma_set_optimized :: (m: *Memory_SSA, a: s32, to: s32) {
    if m.acc[a].kind == .DEF { ma_set_op(m, a, 1, to); m.acc[a].optimized_id = m.acc[to].id; }
    else { m.acc[a].optimized_id = m.acc[to].id; ma_set_op(m, a, 0, to); }
}
ma_reset_optimized :: (m: *Memory_SSA, a: s32) {
    m.acc[a].optimized_id = MSSA_INVALID_ID;
    if m.acc[a].kind == .DEF ma_set_op(m, a, 1, -1);
}
// setDefiningAccess(DMA, Optimized)
ma_set_defining :: (m: *Memory_SSA, a: s32, d: s32, optimized := false) {
    if optimized { ma_set_optimized(m, a, d); return; }
    ma_set_op(m, a, 0, d);
}
// dropAllReferences
ma_drop_all_references :: (m: *Memory_SSA, a: s32) {
    for k: 0..cast(s64) m.acc[a].nops - 1 ma_set_op(m, a, cast(u32) k, -1);
}

new_access :: (m: *Memory_SSA, kind: Ma_Kind, i: Value_Id, b: Value_Id) -> s32 {
    r: Mem_Access; r.kind = kind; r.inst = i; r.block = b;
    if kind != .USE { r.id = m.next_id; m.next_id += 1; }
    a := cast(s32) m.acc.count;
    n: u32 = ifx kind == .DEF then cast(u32) 2 else ifx kind == .USE then cast(u32) 1 else cast(u32) 0;
    if n {
        r.ops = cast(s32) m.uses.count;
        r.nops = n; r.cap = n;
        for 0..n-1 { u: Mssa_Use; u.user = a; array_add(*m.uses, u); }
    }
    array_add(*m.acc, r);
    return a;
}
// the access is destroyed (deleteValue): drop its operands, null its value handles
ma_destroy :: (m: *Memory_SSA, a: s32) {
    assert(!ma_has_uses(m, a), "MemorySSA: deleting an access that still has uses");
    for k: 0..cast(s64) m.acc[a].nops - 1 { u := ma_op_use(m, a, cast(u32) k); if m.uses[u].val >= 0 mu_unlink(m, u); m.uses[u].val = -1; }
    vh_deleted(m, a);
    m.acc[a].dead = true;
}

// ---------------------------------------------------------------- lists

Mssa_Insertion_Place :: enum u8 { BEGINNING; END; BEFORE_TERMINATOR; }

list_insert_before :: (m: *Memory_SSA, b: Value_Id, a: s32, before: s32) {   // before = -1: push_back
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    r.in_lists = true;
    if before < 0 {
        r.prev = l.last; r.next = -1;
        if l.last >= 0 m.acc[l.last].next = a; else l.first = a;
        l.last = a;
        return;
    }
    p := m.acc[before].prev;
    r.prev = p; r.next = before;
    m.acc[before].prev = a;
    if p >= 0 m.acc[p].next = a; else l.first = a;
}
defs_insert_before :: (m: *Memory_SSA, b: Value_Id, a: s32, before: s32) {
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    if before < 0 {
        r.dprev = l.dlast; r.dnext = -1;
        if l.dlast >= 0 m.acc[l.dlast].dnext = a; else l.dfirst = a;
        l.dlast = a;
        return;
    }
    p := m.acc[before].dprev;
    r.dprev = p; r.dnext = before;
    m.acc[before].dprev = a;
    if p >= 0 m.acc[p].dnext = a; else l.dfirst = a;
}
list_push_back :: (m: *Memory_SSA, b: Value_Id, a: s32) { list_insert_before(m, b, a, -1); }
defs_push_back :: (m: *Memory_SSA, b: Value_Id, a: s32) { defs_insert_before(m, b, a, -1); }
list_push_front :: (m: *Memory_SSA, b: Value_Id, a: s32) { l := mssa_block_or_create(m, b); list_insert_before(m, b, a, l.first); }
defs_push_front :: (m: *Memory_SSA, b: Value_Id, a: s32) { l := mssa_block_or_create(m, b); defs_insert_before(m, b, a, l.dfirst); }

// erase from the access list (and defs list) of its block (removeFromLists without deletion)
list_erase :: (m: *Memory_SSA, a: s32) {
    r := ma(m, a);
    l := mssa_block(m, r.block);
    if r.kind != .USE {
        if r.dprev >= 0 m.acc[r.dprev].dnext = r.dnext; else l.dfirst = r.dnext;
        if r.dnext >= 0 m.acc[r.dnext].dprev = r.dprev; else l.dlast = r.dprev;
    }
    if r.prev >= 0 m.acc[r.prev].next = r.next; else l.first = r.next;
    if r.next >= 0 m.acc[r.next].prev = r.prev; else l.last = r.prev;
    r.prev = -1; r.next = -1; r.dprev = -1; r.dnext = -1; r.in_lists = false;
    if l.first < 0 { table_remove(*m.blocks, r.block); table_remove(*m.numbered, r.block); }
}
// getBlockDefs(BB)->rbegin(): the last def or phi of a block, -1 if none
mssa_last_block_def :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.dlast;
}
// getBlockDefs(BB)->begin()
mssa_first_block_def :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.dfirst;
}
// getBlockAccesses(BB)->front()
mssa_first_access :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.first;
}
mssa_last_access :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.last;
}
mssa_num_block_accesses :: (m: *Memory_SSA, b: Value_Id) -> s64 {
    n := 0;
    a := mssa_first_access(m, b);
    while a >= 0 { n += 1; a = m.acc[a].next; }
    return n;
}

// insertIntoListsForBlock
mssa_insert_into_lists_for_block :: (m: *Memory_SSA, a: s32, b: Value_Id, point: Mssa_Insertion_Place) {
    mssa_block_or_create(m, b);
    if point == .BEGINNING {
        if ma_is_phi(m, a) {
            list_push_front(m, b, a);
            defs_push_front(m, b, a);
        } else {
            ai := mssa_first_access(m, b);
            while ai >= 0 && ma_is_phi(m, ai) ai = m.acc[ai].next;
            list_insert_before(m, b, a, ai);
            if !ma_is_use(m, a) {
                di := mssa_first_block_def(m, b);
                while di >= 0 && ma_is_phi(m, di) di = m.acc[di].dnext;
                defs_insert_before(m, b, a, di);
            }
        }
    } else {
        list_push_back(m, b, a);
        if !ma_is_use(m, a) defs_push_back(m, b, a);
    }
    table_remove(*m.numbered, b);
}
// insertIntoListsBefore(What, BB, InsertPt): insert_pt = -1 is end()
mssa_insert_into_lists_before :: (m: *Memory_SSA, a: s32, b: Value_Id, insert_pt_in: s32) {
    insert_pt := insert_pt_in;
    was_end := insert_pt < 0;
    list_insert_before(m, b, a, insert_pt);
    if !ma_is_use(m, a) {
        if was_end defs_push_back(m, b, a);
        else if ma_is_def(m, insert_pt) defs_insert_before(m, b, a, insert_pt);
        else {
            while insert_pt >= 0 && !ma_is_def(m, insert_pt) insert_pt = m.acc[insert_pt].next;
            if insert_pt < 0 defs_push_back(m, b, a);
            else defs_insert_before(m, b, a, insert_pt);
        }
    }
    table_remove(*m.numbered, b);
}
// prepareForMoveTo
mssa_prepare_for_move_to :: (m: *Memory_SSA, a: s32, b: Value_Id) {
    list_erase(m, a);
    if ma_is_def(m, a) ma_reset_optimized(m, a);
    m.acc[a].block = b;
}
// moveTo(MemoryUseOrDef *What, BB, AccessList::iterator Where)
mssa_move_to_before :: (m: *Memory_SSA, a: s32, b: Value_Id, where: s32) {
    mssa_prepare_for_move_to(m, a, b);
    mssa_insert_into_lists_before(m, a, b, where);
}
// moveTo(MemoryAccess *What, BB, InsertionPlace Point)
mssa_move_to_place :: (m: *Memory_SSA, a: s32, b: Value_Id, point: Mssa_Insertion_Place) {
    if ma_is_phi(m, a) {
        assert(point == .BEGINNING, "Can only move a Phi at the beginning of the block");
        table_remove(*m.of_value, m.acc[a].block);
        assert(!table_contains(*m.of_value, b), "Cannot move a Phi to a block that already has one");
        table_set(*m.of_value, b, a);
    }
    mssa_prepare_for_move_to(m, a, b);
    mssa_insert_into_lists_for_block(m, a, b, point);
}

// removeFromLookups
mssa_remove_from_lookups :: (m: *Memory_SSA, a: s32) {
    assert(!ma_has_uses(m, a), "Trying to remove memory access that still has uses");
    table_remove(*m.numbering, a);
    if !ma_is_phi(m, a) ma_set_defining(m, a, -1);
    // getWalker()->invalidateInfo(MA): resetOptimized for a MemoryDef
    if ma_is_def(m, a) ma_reset_optimized(m, a);
    key := ifx ma_is_phi(m, a) then m.acc[a].block else m.acc[a].inst;
    found, cur := table_find(*m.of_value, key);
    if found && cur == a table_remove(*m.of_value, key);
}
// removeFromLists(MA, ShouldDelete)
mssa_remove_from_lists :: (m: *Memory_SSA, a: s32, should_delete := true) {
    list_erase(m, a);
    if should_delete ma_destroy(m, a);
}

// isOrdered
inst_is_ordered :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .STORE || o == .LOAD return !is_unordered(i);
    return false;
}

// isUseTriviallyOptimizableToLiveOnEntry
is_use_trivially_optimizable_to_live_on_entry :: (q: *Aa_Query, i: Value_Id) -> bool {
    if get_metadata(i, md_kind_id("invariant.load")) != NONE return true;
    if inst_op(i) == .LOAD return (aa_mod_ref_mask(q, mloc_get(i)) & MR_MOD) == 0;
    return false;
}

// MemorySSA::createNewAccess(I, AA, Template); template_kind: -1 = no template, else the template's Ma_Kind
mssa_create_new_access :: (m: *Memory_SSA, i: Value_Id, q: *Aa_Query, template_kind: s32 = -1) -> s32 {
    id := call_iid(i);
    if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_ASSUME ||
       id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_PSEUDOPROBE return -1;
    if !may_read_from_memory(i) && !may_write_to_memory(i) return -1;
    def, use: bool;
    if template_kind >= 0 {
        def = template_kind == cast(s32) Ma_Kind.DEF;
        use = template_kind == cast(s32) Ma_Kind.USE;
    } else {
        mr := aa_mod_ref_inst_opt_loc(q, i, false, .{});
        def = (mr & MR_MOD) != 0 || inst_is_ordered(i);
        use = (mr & MR_REF) != 0;
    }
    if !def && !use return -1;
    a: s32;
    if def a = new_access(m, .DEF, i, inst_block(i));
    else {
        a = new_access(m, .USE, i, inst_block(i));
        if is_use_trivially_optimizable_to_live_on_entry(q, i) ma_set_optimized(m, a, MSSA_LIVE_ON_ENTRY);
    }
    table_set(*m.of_value, i, a);
    return a;
}

// createDefinedAccess(I, Definition, Template, CreationMustSucceed)
mssa_create_defined_access :: (m: *Memory_SSA, i: Value_Id, definition: s32, template_kind: s32 = -1, must_succeed := true) -> s32 {
    q := aa_query_new(*m.aar);   // AA, not a batch: a fresh AAQueryInfo per query
    a := mssa_create_new_access(m, i, q, template_kind);
    if must_succeed assert(a >= 0, "Tried to create a memory access for a non-memory touching instruction");
    if a >= 0 {
        assert(definition < 0 || !ma_is_use(m, definition), "A use cannot be a defining access");
        ma_set_defining(m, a, definition);
    }
    return a;
}

// MemorySSA::createMemoryPhi
mssa_create_phi :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    assert(mssa_access_of(m, b) < 0, "MemoryPhi already exists for this BB");
    a := new_access(m, .PHI, NONE, b);
    mssa_insert_into_lists_for_block(m, a, b, .BEGINNING);
    table_set(*m.of_value, b, a);
    return a;
}

// renameBlock
mssa_rename_block :: (m: *Memory_SSA, b: Value_Id, incoming_in: s32, rename_all_uses: bool) -> s32 {
    incoming := incoming_in;
    l := mssa_block(m, b);
    if !l return incoming;
    a := l.first;
    while a >= 0 {
        r := ma(m, a);
        if r.kind != .PHI {
            if ma_defining(m, a) < 0 || rename_all_uses ma_set_defining(m, a, incoming);
            if r.kind == .DEF incoming = a;
        } else incoming = a;
        a = m.acc[a].next;
    }
    return incoming;
}
// renameSuccessorPhis
mssa_rename_successor_phis :: (m: *Memory_SSA, b: Value_Id, incoming: s32, rename_all_uses: bool) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    for s: succs {
        f := mssa_first_access(m, s);
        if f < 0 || !ma_is_phi(m, f) continue;
        if rename_all_uses {
            done := false;
            for k: 0..cast(s64) ma_nops(m, f) - 1 if mphi_block(m, f, cast(u32) k) == b { mphi_set_value(m, f, cast(u32) k, incoming); done = true; }
            assert(done, "Incomplete phi during partial rename");
        } else mphi_add_incoming(m, f, incoming, b);
    }
}
// renamePass(Root, IncomingVal, Visited, SkipVisited = false, RenameAllUses = false)
mssa_rename_pass :: (m: *Memory_SSA, root: s32, incoming_in: s32, visited: *Table(Value_Id, bool), skip_visited := false, rename_all_uses := false) {
    dt := m.dt;
    rb := dt.nodes[root].block;
    already := table_contains(visited, rb);
    if !already table_set(visited, rb, true);
    if skip_visited && already return;
    incoming := mssa_rename_block(m, rb, incoming_in, rename_all_uses);
    mssa_rename_successor_phis(m, rb, incoming, rename_all_uses);
    Frame :: struct { node: s32; child: s32; incoming: s32; }
    stack: [..] Frame; stack.allocator = temp;
    array_add(*stack, .{root, dt.nodes[root].first_child, incoming});
    while stack.count {
        top := *stack[stack.count - 1];
        incoming = top.incoming;
        if top.child < 0 { pop(*stack); continue; }
        child := top.child;
        top.child = dt.nodes[child].sibling;
        bb := dt.nodes[child].block;
        already = table_contains(visited, bb);
        if !already table_set(visited, bb, true);
        if skip_visited && already {
            d := mssa_last_block_def(m, bb);
            if d >= 0 incoming = d;
        } else incoming = mssa_rename_block(m, bb, incoming, rename_all_uses);
        mssa_rename_successor_phis(m, bb, incoming, rename_all_uses);
        array_add(*stack, .{child, dt.nodes[child].first_child, incoming});
    }
}
// renamePass(BasicBlock *BB, MemoryAccess *IncomingVal, Visited) (the updater's entry point)
mssa_rename_pass_from_block :: (m: *Memory_SSA, b: Value_Id, incoming: s32, visited: *Table(Value_Id, bool)) {
    n := dt_node(m.dt, b);
    assert(n >= 0, "Trying to rename accesses in an unreachable block");
    mssa_rename_pass(m, n, incoming, visited, true, true);
}

// markUnreachableAsLiveOnEntry
mssa_mark_unreachable_as_live_on_entry :: (m: *Memory_SSA, b: Value_Id) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    for s: succs {
        if !dt_is_reachable_from_entry(m.dt, s) continue;
        f := mssa_first_access(m, s);
        if f < 0 || !ma_is_phi(m, f) continue;
        mphi_add_incoming(m, f, MSSA_LIVE_ON_ENTRY, b);
    }
    l := mssa_block(m, b);
    if !l return;
    a := l.first;
    while a >= 0 {
        nx := m.acc[a].next;
        if m.acc[a].kind != .PHI ma_set_defining(m, a, MSSA_LIVE_ON_ENTRY);
        else fatal("MemorySSA: a MemoryPhi in an unreachable block (Accesses->erase leaves dangling entries in LLVM)");
        a = nx;
    }
}

// MemorySSA::MemorySSA(F, AA, DT) + buildMemorySSA
mssa_build :: (f: Value_Id, dt: *Dom_Tree, aar: Aa_Results) -> *Memory_SSA {
    m := New(Memory_SSA);
    m.f = f; m.dt = dt; m.aar = aar;
    q := aa_query_new(*m.aar);
    entry := fn_entry(f);
    new_access(m, .DEF, NONE, entry);   // liveOnEntry (id 0)
    def_blocks: [..] Value_Id; def_blocks.allocator = temp;
    def_set: Table(Value_Id, bool); def_set.allocator = temp;
    for b: fn_blocks(f) {
        insert_into_def := false;
        for i: block_insts(b) {
            a := mssa_create_new_access(m, i, q);
            if a < 0 continue;
            list_push_back(m, b, a);
            if m.acc[a].kind == .DEF { insert_into_def = true; defs_push_back(m, b, a); }
        }
        if insert_into_def && !table_contains(*def_set, b) { table_set(*def_set, b, true); array_add(*def_blocks, b); }
    }
    // placePHINodes
    idf: [..] Value_Id; idf.allocator = temp;
    idf_calculate(dt, def_blocks, *def_set, null, *idf);
    for idf mssa_create_phi(m, it);
    // renaming
    visited: Table(Value_Id, bool); visited.allocator = temp;
    mssa_rename_pass(m, dt_node(dt, entry), MSSA_LIVE_ON_ENTRY, *visited);
    for b: fn_blocks(f) if !table_contains(*visited, b) mssa_mark_unreachable_as_live_on_entry(m, b);
    return m;
}

// ---------------------------------------------------------------- dominance

// renumberBlock
mssa_renumber_block :: (m: *Memory_SSA, b: Value_Id) {
    n: u32 = 0;
    a := mssa_first_access(m, b);
    while a >= 0 { n += 1; table_set(*m.numbering, a, n); a = m.acc[a].next; }
    table_set(*m.numbered, b, true);
}
// locallyDominates
mssa_locally_dominates :: (m: *Memory_SSA, dominator: s32, dominatee: s32) -> bool {
    if dominatee == dominator return true;
    if is_live_on_entry(dominatee) return false;
    if is_live_on_entry(dominator) return true;
    b := m.acc[dominator].block;
    if !table_contains(*m.numbered, b) mssa_renumber_block(m, b);
    _, n1 := table_find(*m.numbering, dominator);
    _, n2 := table_find(*m.numbering, dominatee);
    return n1 < n2;
}
// MemorySSA::dominates(MemoryAccess, MemoryAccess)
mssa_dominates :: (m: *Memory_SSA, dominator: s32, dominatee: s32) -> bool {
    if dominator == dominatee return true;
    if is_live_on_entry(dominatee) return false;
    b1 := m.acc[dominator].block; b2 := m.acc[dominatee].block;
    if b1 != b2 return dt_dominates(m.dt, b1, b2);
    return mssa_locally_dominates(m, dominator, dominatee);
}
// MemorySSA::dominates(MemoryAccess, const Use &)
mssa_dominates_use :: (m: *Memory_SSA, dominator: s32, u: s32) -> bool {
    usr := m.uses[u].user;
    if ma_is_phi(m, usr) {
        use_bb := m.uses[u].blk;
        if use_bb != m.acc[dominator].block return dt_dominates(m.dt, m.acc[dominator].block, use_bb);
        // locallyDominates(Dominator, cast<MemoryAccess>(Dominatee)): casting the Use yields its value, the dominator
        return mssa_locally_dominates(m, dominator, m.uses[u].val);
    }
    return mssa_dominates(m, dominator, usr);
}

// ---------------------------------------------------------------- verifyMemorySSA

// verifyMemorySSA(VerificationLevel::Fast): verifyOrderingDominationAndDefUses + verifyDominationNumbers. LLVM's
// release builds compile the checks out; this port runs them (they never change state that is observable).
mssa_verify :: (m: *Memory_SSA, full := false) {
    fail :: (what: string) { fatal(tprint("MemorySSA verification failed: %", what)); }
    actual_accesses: [..] s32; actual_accesses.allocator = temp;
    actual_defs: [..] s32; actual_defs.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    for b: fn_blocks(m.f) {
        l := mssa_block(m, b);
        phi := mssa_access_of(m, b);
        actual_accesses.count = 0; actual_defs.count = 0;
        if phi >= 0 {
            if m.acc[phi].dead || !ma_is_phi(m, phi) || m.acc[phi].block != b fail("bad MemoryPhi lookup");
            array_add(*actual_accesses, phi);
            array_add(*actual_defs, phi);
            u := m.acc[phi].first_use;
            while u >= 0 { if !mssa_dominates_use(m, phi, u) fail("Memory PHI does not dominate it's uses"); u = m.uses[u].next; }
            if full {
                block_predecessors(b, *preds);
                if ma_nops(m, phi) != cast(u32) preds.count fail("Incomplete MemoryPhi Node");
            }
        }
        for i: block_insts(b) {
            a := mssa_access_of(m, i);
            if a < 0 continue;
            if !l || (!ma_is_use(m, a) && l.dfirst < 0) fail("memory affecting instructions not in the access or defs list");
            if m.acc[a].dead || m.acc[a].inst != i || m.acc[a].block != b fail("bad MemoryUseOrDef lookup");
            array_add(*actual_accesses, a);
            if ma_is_def(m, a) {
                array_add(*actual_defs, a);
                u := m.acc[a].first_use;
                while u >= 0 { if !mssa_dominates_use(m, a, u) fail(tprint("Memory Def % does not dominate it's use by %", m.acc[a].id, mssa_access_to_string(m, m.uses[u].user))); u = m.uses[u].next; }
            }
        }
        if !l { if actual_accesses.count fail("accesses without an access list"); continue; }
        k := 0;
        x := l.first;
        while x >= 0 {
            if k >= actual_accesses.count || actual_accesses[k] != x fail("Not the same accesses in the same order");
            k += 1; x = m.acc[x].next;
        }
        if k != actual_accesses.count fail("We don't have the same number of accesses in the block as on the access list");
        k = 0;
        x = l.dfirst;
        while x >= 0 {
            if k >= actual_defs.count || actual_defs[k] != x fail("Not the same defs in the same order");
            k += 1; x = m.acc[x].dnext;
        }
        if k != actual_defs.count fail("We don't have the same number of defs in the block as on the def list");
    }
    // verifyDominationNumbers
    for v, b: m.numbered {
        l := mssa_block(m, b);
        if !l continue;
        last: u32 = 0;
        x := l.first;
        while x >= 0 {
            found, n := table_find(*m.numbering, x);
            if !found fail("MemoryAccess has no domination number in a valid block!");
            if n <= last fail("Domination numbers should be strictly increasing!");
            last = n; x = m.acc[x].next;
        }
    }
    // use-list consistency (implied by LLVM's data structure)
    for r, a: m.acc {
        if r.dead continue;
        for k: 0..cast(s64) r.nops - 1 {
            u := r.ops + cast(s32) k;
            v := m.uses[u].val;
            if v < 0 continue;
            if m.acc[v].dead fail("an operand refers to a deleted access");
        }
    }
}
// ---------------------------------------------------------------- clobber queries

// MemoryLocOrCall
Mloc_Or_Call :: struct {
    is_call: bool;
    call: Value_Id = NONE;
    loc: Mem_Loc;
}
mloc_or_call_of :: (i: Value_Id) -> Mloc_Or_Call {
    r: Mloc_Or_Call;
    if is_call_base(i) { r.is_call = true; r.call = i; }
    else if inst_op(i) != .FENCE r.loc = mloc_get(i);
    return r;
}
mloc_or_call_key :: (r: Mloc_Or_Call) -> string {
    sb: String_Builder; sb.allocator = temp;
    if r.is_call {
        c := r.call;
        print_to_builder(*sb, "C%", call_callee(c));
        n := call_num_args(c);
        if n > 0 for k: 0..n-1 print_to_builder(*sb, ",%", op(c, k));
    } else {
        l := r.loc;
        print_to_builder(*sb, "L%,%,%,%,%,%,%", l.ptr, l.size, l.tags.tbaa, l.tags.tbaa_struct, l.tags.scope, l.tags.noalias, l.tags.noalias_as);
    }
    return builder_to_string(*sb,, allocator = temp);
}
mem_loc_eq :: (a: Mem_Loc, b: Mem_Loc) -> bool {
    return a.ptr == b.ptr && a.size == b.size && a.tags.tbaa == b.tags.tbaa && a.tags.tbaa_struct == b.tags.tbaa_struct &&
           a.tags.scope == b.tags.scope && a.tags.noalias == b.tags.noalias && a.tags.noalias_as == b.tags.noalias_as;
}

// areLoadsReorderable(Use, MayClobber)
are_loads_reorderable :: (use: Value_Id, may_clobber: Value_Id) -> bool {
    vu := (inst(use).flags & F_VOLATILE) != 0;
    vc := (inst(may_clobber).flags & F_VOLATILE) != 0;
    if vu && vc return false;
    seq_cst_use := inst(use).ord1 == 7;
    clobber_is_acquire := inst(may_clobber).ord1 >= 4 && inst(may_clobber).ord1 != 5;   // isAtLeastOrStrongerThan(Acquire)
    return !(seq_cst_use || clobber_is_acquire);
}

// instructionClobbersQuery(MD, UseLoc, UseInst, AA)
mssa_clobbers_query :: (m: *Memory_SSA, q: *Aa_Query, md: s32, use_loc: Mem_Loc, use_inst: Value_Id) -> bool {
    def_inst := m.acc[md].inst;
    if inst_op(def_inst) == .CALL {
        id := call_iid(def_inst);
        if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_INVARIANT_START ||
           id == IID_INVARIANT_END || id == IID_ASSUME || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_PSEUDOPROBE
            return false;
    }
    if use_inst != NONE && is_call_base(use_inst) return (aa_mod_ref_inst_call(q, def_inst, use_inst) & MR_MOD) != 0;
    if inst_op(def_inst) == .LOAD && use_inst != NONE && inst_op(use_inst) == .LOAD return !are_loads_reorderable(use_inst, def_inst);
    return (aa_mod_ref_inst_loc(q, def_inst, use_loc) & MR_MOD) != 0;
}
// instructionClobbersQuery(MD, MU, UseMLOC, AA)
mssa_clobbers_use :: (m: *Memory_SSA, q: *Aa_Query, md: s32, mu: s32, mloc_: Mloc_Or_Call) -> bool {
    if mloc_.is_call return mssa_clobbers_query(m, q, md, .{}, m.acc[mu].inst);
    return mssa_clobbers_query(m, q, md, mloc_.loc, m.acc[mu].inst);
}
// MemorySSAUtil::defClobbersUseOrDef
mssa_def_clobbers_use_or_def :: (m: *Memory_SSA, q: *Aa_Query, md: s32, mu: s32) -> bool {
    return mssa_clobbers_use(m, q, md, mu, mloc_or_call_of(m.acc[mu].inst));
}

// ---------------------------------------------------------------- PHITransAddr

Phi_Trans_Addr :: struct {
    addr: Value_Id;
    inputs: [..] Value_Id;   // InstInputs
    dt: *Dom_Tree;
}
pta_add_as_input :: (t: *Phi_Trans_Addr, v: Value_Id) -> Value_Id {
    if is_inst(v) array_add(*t.inputs, v);
    return v;
}
pta_input_index :: (t: *Phi_Trans_Addr, v: Value_Id) -> s64 { for t.inputs if it == v return it_index; return -1; }
pta_remove_inst_inputs :: (t: *Phi_Trans_Addr, v: Value_Id) {
    if !is_inst(v) return;
    k := pta_input_index(t, v);
    if k >= 0 { array_ordered_remove_by_index(*t.inputs, k); return; }
    n := nops(v);
    if n > 0 for j: 0..n-1 { o := op(v, j); if is_inst(o) pta_remove_inst_inputs(t, o); }
}
can_phi_trans :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .PHI || o == .GEP || is_cast_op(o) return true;
    return o == .ADD && is_scalar_const_int(op(i, 1));
}
// translateSubExpr (no select condition)
pta_translate_sub_expr :: (t: *Phi_Trans_Addr, v: Value_Id, cur_bb: Value_Id, pred_bb: Value_Id) -> Value_Id {
    if !is_inst(v) return v;
    i := v;
    k := pta_input_index(t, i);
    if k >= 0 {
        if inst_block(i) != cur_bb return i;
        array_ordered_remove_by_index(*t.inputs, k);
        if inst_op(i) == .PHI return pta_add_as_input(t, phi_incoming_value_for_block(i, pred_bb));
        if !can_phi_trans(i) return NONE;
        n := nops(i);
        if n > 0 for j: 0..n-1 pta_add_as_input(t, op(i, j));
    }
    sq: Simplify_Query; sq.dt = t.dt; sq.ac = null;
    o := inst_op(i);
    if is_cast_op(o) {
        phi_in := pta_translate_sub_expr(t, op(i, 0), cur_bb, pred_bb);
        if phi_in == NONE return NONE;
        if phi_in == op(i, 0) return i;
        s := simplify_cast_inst(o, phi_in, vtype(i), sq);
        if s != NONE { pta_remove_inst_inputs(t, phi_in); return pta_add_as_input(t, s); }
        u := ir.v_first_use[phi_in];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == o && vtype(usr) == vtype(i) && (!t.dt || dt_dominates(t.dt, inst_block(usr), pred_bb)) return usr;
            u = ir.u_next[u];
        }
        return NONE;
    }
    if o == .GEP {
        n := nops(i);
        ops: [..] Value_Id; ops.allocator = temp;
        any_changed := false;
        for j: 0..n-1 {
            x := pta_translate_sub_expr(t, op(i, j), cur_bb, pred_bb);
            if x == NONE return NONE;
            any_changed = any_changed || x != op(i, j);
            array_add(*ops, x);
        }
        if !any_changed return i;
        idxs: [] Value_Id; idxs.data = ops.data + 1; idxs.count = ops.count - 1;
        s := simplify_gep_inst(inst(i).ty2, ops[0], idxs, inst(i).flags & (F_INBOUNDS | F_NUSW | F_GEP_NUW), sq);
        if s != NONE { for ops pta_remove_inst_inputs(t, it); return pta_add_as_input(t, s); }
        aphi := ops[0];
        if is_constant_data(aphi) return NONE;
        u := ir.v_first_use[aphi];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == .GEP && vtype(usr) == vtype(i) && inst(usr).ty2 == inst(i).ty2 && nops(usr) == cast(u32) ops.count &&
               inst_fn(usr) == block_fn(cur_bb) && (!t.dt || dt_dominates(t.dt, inst_block(usr), pred_bb)) {
                same := true;
                for ops if op(usr, cast(u32) it_index) != it { same = false; break; }
                if same return usr;
            }
            u = ir.u_next[u];
        }
        return NONE;
    }
    if o == .ADD && is_scalar_const_int(op(i, 1)) {
        rhs := op(i, 1);
        is_nsw := (inst(i).flags & F_NSW) != 0;
        is_nuw := (inst(i).flags & F_NUW) != 0;
        lhs := pta_translate_sub_expr(t, op(i, 0), cur_bb, pred_bb);
        if lhs == NONE return NONE;
        if is_inst(lhs) && inst_op(lhs) == .ADD && is_scalar_const_int(op(lhs, 1)) {
            bop := lhs;
            lhs = op(bop, 0);
            rhs = ce_add_const(rhs, op(bop, 1));
            is_nsw = false; is_nuw = false;
            if pta_input_index(t, bop) >= 0 { pta_remove_inst_inputs(t, bop); pta_add_as_input(t, lhs); }
        }
        s := simplify_add_inst(lhs, rhs, is_nsw, is_nuw, sq);
        if s != NONE { pta_remove_inst_inputs(t, lhs); return pta_add_as_input(t, s); }
        if lhs == op(i, 0) && rhs == op(i, 1) return i;
        u := ir.v_first_use[lhs];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == .ADD && op(usr, 0) == lhs && op(usr, 1) == rhs &&
               inst_fn(usr) == block_fn(cur_bb) && (!t.dt || dt_dominates(t.dt, inst_block(usr), pred_bb)) return usr;
            u = ir.u_next[u];
        }
        return NONE;
    }
    return NONE;
}
// ConstantExpr::getAdd of two ConstantInts (folds)
ce_add_const :: (a: Value_Id, b: Value_Id) -> Value_Id {
    return const_int_ap(vtype(a), ap_add(const_ap(a), const_ap(b)));
}
const_int_ap :: (t: Type_Id, v: APInt) -> Value_Id { return const_int_words(t, ap_words(v)); }
// isa<ConstantData>
is_constant_data :: (v: Value_Id) -> bool {
    k := vkind(v);
    return k == .C_INT || k == .C_FP || k == .C_NULL || k == .C_ZERO || k == .C_TOKEN_NONE || k == .C_UNDEF ||
           k == .C_POISON || k == .C_DATA || k == .C_TARGET_NONE;
}
// PHITransAddr(Addr).translateValue(CurBB, PredBB, DT, MustDominate)
phi_translate_value :: (addr: Value_Id, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree, must_dominate: bool) -> Value_Id {
    t: Phi_Trans_Addr; t.addr = addr; t.dt = dt; t.inputs.allocator = temp;
    pta_add_as_input(*t, addr);
    if dt && dt_is_reachable_from_entry(dt, pred_bb) t.addr = pta_translate_sub_expr(*t, t.addr, cur_bb, pred_bb);
    else t.addr = NONE;
    if must_dominate && t.addr != NONE && is_inst(t.addr) && !dt_dominates(dt, inst_block(t.addr), pred_bb) t.addr = NONE;
    return t.addr;
}

// ---------------------------------------------------------------- upward_defs

Upward_Defs_Elem :: struct { ma: s32; loc: Mem_Loc; mbci: bool; }

// upward_defs_iterator::IsGuaranteedLoopInvariant
is_guaranteed_loop_invariant :: (ptr_in: Value_Id) -> bool {
    base_ok :: (p_in: Value_Id) -> bool {
        p := strip_pointer_casts_kind(p_in, .ZERO_INDICES);
        if !is_inst(p) return true;
        return inst_op(p) == .ALLOCA;
    }
    ptr := strip_pointer_casts_kind(ptr_in, .ZERO_INDICES);
    if is_inst(ptr) && inst_block(ptr) == fn_entry(inst_fn(ptr)) return true;
    if opr_code(ptr) == .GEP return base_ok(op(ptr, 0)) && gep_has_all_constant_indices(ptr);
    return base_ok(ptr);
}

// upward_defs(Elem, DT): one element per defining access of Elem.ma (a phi's incoming values in operand order)
mssa_upward_defs :: (m: *Memory_SSA, e: Upward_Defs_Elem, out: *[..] Upward_Defs_Elem) {
    out.count = 0;
    r := ma(m, e.ma);
    if r.kind != .PHI {
        x: Upward_Defs_Elem; x.ma = ma_defining(m, e.ma); x.loc = e.loc; x.mbci = e.mbci;
        array_add(out, x);
        return;
    }
    for k: 0..cast(s64) ma_nops(m, e.ma) - 1 {
        x: Upward_Defs_Elem; x.ma = mphi_value(m, e.ma, cast(u32) k); x.loc = e.loc; x.mbci = e.mbci;
        if e.loc.ptr != NONE {
            addr := phi_translate_value(e.loc.ptr, r.block, mphi_block(m, e.ma, cast(u32) k), m.dt, true);
            if addr != NONE && addr != x.loc.ptr x.loc.ptr = addr;
            if !is_guaranteed_loop_invariant(x.loc.ptr) x.loc.size = LS_BEFORE_OR_AFTER;
        } else x.mbci = true;
        array_add(out, x);
    }
}

// ---------------------------------------------------------------- ClobberWalker

Upwards_Query :: struct {
    is_call: bool;
    starting_loc: Mem_Loc;
    inst: Value_Id = NONE;
    original: s32 = -1;
    skip_self: bool;
}
upwards_query_for :: (i: Value_Id, a: s32) -> Upwards_Query {
    q: Upwards_Query;
    q.is_call = is_call_base(i); q.inst = i; q.original = a;
    if !q.is_call q.starting_loc = mloc_get(i);
    return q;
}

Def_Path :: struct {
    loc: Mem_Loc;
    first: s32;
    last: s32;
    previous: s64 = -1;
    mbci: bool;
}
Terminated_Path :: struct { clobber: s32; last_node: s64; }

Clobber_Walker :: struct {
    m: *Memory_SSA;
    aa: *Aa_Query;
    query: *Upwards_Query;
    limit: *u32;
    paths: [..] Def_Path;
    visited_phis: [..] Upward_Defs_Elem;
}

cw_visited_insert :: (w: *Clobber_Walker, e: Upward_Defs_Elem) -> bool {
    for w.visited_phis if it.ma == e.ma && it.mbci == e.mbci && mem_loc_eq(it.loc, e.loc) return false;
    array_add(*w.visited_phis, e);
    return true;
}

// getWalkTarget
cw_walk_target :: (w: *Clobber_Walker, phi: s32) -> s32 {
    dt := w.m.dt;
    n := dt_node(dt, w.m.acc[phi].block);
    while true {
        n = dt_idom(dt, n);
        if n < 0 break;
        d := mssa_last_block_def(w.m, dt.nodes[n].block);
        if d >= 0 return d;
    }
    return MSSA_LIVE_ON_ENTRY;
}

// walkToPhiOrClobber(Desc, StopAt, SkipStopAt): (Result, IsKnownClobber)
cw_walk_to_phi_or_clobber :: (w: *Clobber_Walker, desc_index: s64, stop_at: s32 = -1, skip_stop_at: s32 = -1) -> (s32, bool) {
    limit_already_reached := false;
    if w.limit.* == 0 { w.limit.* = 1; limit_already_reached = true; }
    m := w.m;
    cur := w.paths[desc_index].last;
    while cur >= 0 {
        w.paths[desc_index].last = cur;
        if cur == stop_at || cur == skip_stop_at return cur, false;
        r := ma(m, cur);
        if r.kind == .DEF {
            if is_live_on_entry(cur) return cur, true;
            w.limit.* -= 1;
            if w.limit.* == 0 return cur, true;
            saved := w.aa.may_be_cross_iteration;
            w.aa.may_be_cross_iteration = w.paths[desc_index].mbci;
            clob := mssa_clobbers_query(m, w.aa, cur, w.paths[desc_index].loc, w.query.inst);
            w.aa.may_be_cross_iteration = saved;
            if clob return cur, true;
        }
        if r.kind == .PHI break;
        cur = ma_defining(m, cur);
    }
    if limit_already_reached w.limit.* = 0;
    return w.paths[desc_index].last, false;
}

// addSearches
cw_add_searches :: (w: *Clobber_Walker, phi: s32, paused: *[..] s64, prior: s64, mbci: bool) {
    e: Upward_Defs_Elem; e.ma = phi; e.loc = w.paths[prior].loc; e.mbci = mbci;
    defs: [..] Upward_Defs_Elem; defs.allocator = temp;
    mssa_upward_defs(w.m, e, *defs);
    for d: defs {
        array_add(paused, w.paths.count);
        p: Def_Path; p.loc = d.loc; p.first = d.ma; p.last = d.ma; p.mbci = d.mbci; p.previous = prior;
        array_add(*w.paths, p);
    }
}

// getBlockingAccess: (found, blocker)
cw_get_blocking_access :: (w: *Clobber_Walker, stop_where: s32, paused: *[..] s64, new_paused: *[..] s64, terminated: *[..] Terminated_Path) -> (bool, Terminated_Path) {
    m := w.m;
    while paused.count {
        path_index := pop(paused);
        node := w.paths[path_index];
        ve: Upward_Defs_Elem; ve.ma = node.last; ve.loc = node.loc; ve.mbci = node.mbci;
        if !cw_visited_insert(w, ve) continue;
        skip_stop_where: s32 = -1;
        if w.query.skip_self && mem_loc_eq(node.loc, w.query.starting_loc) skip_stop_where = w.query.original;
        res, known := cw_walk_to_phi_or_clobber(w, path_index, stop_where, skip_stop_where);
        if known {
            term := Terminated_Path.{res, path_index};
            if !mssa_dominates(m, res, stop_where) return true, term;
            array_add(terminated, term);
            continue;
        }
        if res == stop_where || res == skip_stop_where {
            if res != skip_stop_where array_add(new_paused, path_index);
            continue;
        }
        cw_add_searches(w, res, paused, path_index, w.paths[path_index].mbci);
    }
    return false, .{};
}

// MoveDominatedPathToEnd
move_dominated_path_to_end :: (m: *Memory_SSA, paths: *[..] Terminated_Path) {
    dom := 0;
    for i: 1..paths.count-1 if !mssa_dominates(m, paths.*[i].clobber, paths.*[dom].clobber) dom = i;
    last := paths.count - 1;
    if last != dom { tmp := paths.*[last]; paths.*[last] = paths.*[dom]; paths.*[dom] = tmp; }
}

// tryOptimizePhi: the primary clobber (OtherClobbers are only used for verification in LLVM)
cw_try_optimize_phi :: (w: *Clobber_Walker, phi: s32, start: s32, loc: Mem_Loc) -> Terminated_Path {
    m := w.m;
    p0: Def_Path; p0.loc = loc; p0.first = start; p0.last = phi; p0.mbci = false; p0.previous = -1;
    array_add(*w.paths, p0);
    prior_paths_size := w.paths.count;
    paused: [..] s64; paused.allocator = temp;
    new_paused: [..] s64; new_paused.allocator = temp;
    terminated: [..] Terminated_Path; terminated.allocator = temp;
    cw_add_searches(w, phi, *paused, 0, false);
    current := phi;
    while true {
        target := cw_walk_target(w, current);
        found, blocker := cw_get_blocking_access(w, target, *paused, *new_paused, *terminated);
        if found {
            // find the node we started at: the first node on the def path with index < PriorPathsSize
            n := blocker.last_node;
            while n >= 0 && n >= prior_paths_size n = w.paths[n].previous;
            assert(n >= 0, "MemorySSA: lost the starting path");
            return .{w.paths[n].last, n};
        }
        if new_paused.count == 0 {
            move_dominated_path_to_end(m, *terminated);
            return pop(*terminated);
        }
        def_chain_end: s32 = -1;
        clobbers: [..] Terminated_Path; clobbers.allocator = temp;
        for p: new_paused {
            res, known := cw_walk_to_phi_or_clobber(w, p);
            if known array_add(*clobbers, .{res, p});
            else def_chain_end = res;
        }
        if terminated.count {
            if def_chain_end < 0 {
                x := target;
                while x >= 0 {
                    def_chain_end = x;
                    r := ma(m, x);
                    if r.kind == .PHI break;
                    x = ma_defining(m, x);
                }
            }
            chain_bb := m.acc[def_chain_end].block;
            for tp: terminated if dt_dominates(m.dt, chain_bb, m.acc[tp.clobber].block) array_add(*clobbers, tp);
        }
        if clobbers.count {
            move_dominated_path_to_end(m, *clobbers);
            return pop(*clobbers);
        }
        def_chain_phi := def_chain_end;
        assert(ma_is_phi(m, def_chain_phi), "MemorySSA: def chain end is not a phi");
        prior_paths_size = w.paths.count;
        paused.count = 0;
        for i: new_paused cw_add_searches(w, def_chain_phi, *paused, i, w.paths[i].mbci);
        new_paused.count = 0;
        current = def_chain_phi;
    }
    return .{};
}

// findClobber(BAA, Start, Q, UpWalkLimit)
cw_find_clobber :: (m: *Memory_SSA, aa: *Aa_Query, start: s32, q: *Upwards_Query, limit: *u32) -> s32 {
    w: Clobber_Walker;
    w.m = m; w.aa = aa; w.query = q; w.limit = limit;
    w.paths.allocator = temp; w.visited_phis.allocator = temp;
    if limit.* == 0 limit.* += 1;
    current := start;
    if ma_is_use(m, start) current = ma_defining(m, start);
    first: Def_Path; first.loc = q.starting_loc; first.first = current; first.last = current; first.mbci = false; first.previous = -1;
    array_add(*w.paths, first);
    res, known := cw_walk_to_phi_or_clobber(*w, 0);
    if known return res;
    last := w.paths[0].last;
    w.paths.count = 0;
    opt := cw_try_optimize_phi(*w, last, current, q.starting_loc);
    return opt.clobber;
}

// getInvariantGroupClobberingInstruction
invariant_group_clobbering_instruction :: (i: Value_Id, dt: *Dom_Tree) -> Value_Id {
    k := md_kind_id("invariant.group");
    if get_metadata(i, k) == NONE || is_volatile(i) return NONE;
    p := load_store_pointer_operand(i);
    if p == NONE return NONE;
    ptr := strip_pointer_casts_kind(p, .ZERO_INDICES);
    if is_const(ptr) return NONE;
    most := i;
    u := ir.v_first_use[ptr];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) || usr == i || !dt_dominates_inst(dt, usr, most) continue;
        if get_metadata(usr, k) != NONE && load_store_pointer_operand(usr) == ptr && !is_volatile(usr) most = usr;
    }
    return ifx most == i then NONE else most;
}

// ClobberWalkerBase::getClobberingMemoryAccessBase(MA, BAA, UWL, SkipSelf, UseInvariantGroup)
mssa_clobbering_access_base :: (m: *Memory_SSA, a: s32, aa: *Aa_Query, limit: *u32, skip_self: bool, use_invariant_group := true) -> s32 {
    if ma_is_phi(m, a) return a;
    if use_invariant_group {
        ci := invariant_group_clobbering_instruction(m.acc[a].inst, m.dt);
        if ci != NONE {
            cma := mssa_access_of(m, ci);
            if ma_is_use(m, cma) return ma_defining(m, cma);
            return cma;
        }
    }
    is_opt := false;
    if ma_is_optimized(m, a) {
        if !skip_self || !ma_is_def(m, a) return ma_get_optimized(m, a);
        is_opt = true;
    }
    i := m.acc[a].inst;
    if !is_call_base(i) && is_fence_like(i) return a;
    q := upwards_query_for(i, a);
    if is_use_trivially_optimizable_to_live_on_entry(aa, i) {
        ma_set_optimized(m, a, MSSA_LIVE_ON_ENTRY);
        return MSSA_LIVE_ON_ENTRY;
    }
    optimized: s32;
    if !is_opt {
        defining := ma_defining(m, a);
        if is_live_on_entry(defining) {
            ma_set_optimized(m, a, defining);
            return defining;
        }
        optimized = cw_find_clobber(m, aa, defining, *q, limit);
        ma_set_optimized(m, a, optimized);
    } else optimized = ma_get_optimized(m, a);
    if skip_self && ma_is_phi(m, optimized) && ma_is_def(m, a) && limit.* != 0 {
        q.skip_self = true;
        return cw_find_clobber(m, aa, optimized, *q, limit);
    }
    return optimized;
}
// ClobberWalkerBase::getClobberingMemoryAccessBase(StartingAccess, Loc, BAA, UWL)
mssa_clobbering_access_for_loc :: (m: *Memory_SSA, start: s32, loc: Mem_Loc, aa: *Aa_Query, limit: *u32) -> s32 {
    if loc.ptr == NONE return start;
    if !ma_is_phi(m, start) {
        if is_live_on_entry(start) return start;
        i := m.acc[start].inst;
        if !is_call_base(i) && is_fence_like(i) return start;
    }
    q: Upwards_Query; q.original = start; q.starting_loc = loc; q.inst = NONE; q.is_call = false;
    return cw_find_clobber(m, aa, start, *q, limit);
}

// CachingWalker::getClobberingMemoryAccess(MA, BAA)
mssa_get_clobbering_access :: (m: *Memory_SSA, a: s32, aa: *Aa_Query) -> s32 {
    limit := cast(u32) mssa_opts.max_check_limit;
    return mssa_clobbering_access_base(m, a, aa, *limit, false);
}
// CachingWalker::getClobberingMemoryAccess(MA, Loc, BAA)
mssa_get_clobbering_access_for_loc :: (m: *Memory_SSA, a: s32, loc: Mem_Loc, aa: *Aa_Query) -> s32 {
    limit := cast(u32) mssa_opts.max_check_limit;
    return mssa_clobbering_access_for_loc(m, a, loc, aa, *limit);
}
// SkipSelfWalker::getClobberingMemoryAccess(MA, BAA)
mssa_get_clobbering_access_skip_self :: (m: *Memory_SSA, a: s32, aa: *Aa_Query) -> s32 {
    limit := cast(u32) mssa_opts.max_check_limit;
    return mssa_clobbering_access_base(m, a, aa, *limit, true);
}
// MemorySSAWalker::getClobberingMemoryAccess(const Instruction *I, BatchAA)
mssa_get_clobbering_access_inst :: (m: *Memory_SSA, i: Value_Id, aa: *Aa_Query) -> s32 {
    a := mssa_access_of(m, i);
    if a < 0 return -1;
    return mssa_get_clobbering_access(m, a, aa);
}

// ---------------------------------------------------------------- OptimizeUses

Memloc_Stack_Info :: struct {
    stack_epoch: u64;
    pop_epoch: u64;
    lower_bound: u64;
    lower_bound_block: Value_Id = NONE;
    last_kill: u64;
    last_kill_valid: bool;
}

// optimizeUsesInBlock
mssa_optimize_uses_in_block :: (m: *Memory_SSA, aa: *Aa_Query, bb: Value_Id, stack_epoch: *u64, pop_epoch: *u64,
                                version_stack: *[..] s32, loc_info: *Table(string, Memloc_Stack_Info)) {
    l := mssa_block(m, bb);
    if !l return;
    dt := m.dt;
    while true {
        back_block := m.acc[version_stack.*[version_stack.count - 1]].block;
        if dt_dominates(dt, back_block, bb) break;
        while m.acc[version_stack.*[version_stack.count - 1]].block == back_block pop(version_stack);
        pop_epoch.* += 1;
    }
    a := l.first;
    while a >= 0 {
        defer a = m.acc[a].next;
        if !ma_is_use(m, a) {
            array_add(version_stack, a);
            stack_epoch.* += 1;
            continue;
        }
        if ma_is_optimized(m, a) continue;
        use_mloc := mloc_or_call_of(m.acc[a].inst);
        key := mloc_or_call_key(use_mloc);   // temp: loc_info lives in temp too
        info := table_find_pointer(loc_info, key);
        if !info {
            blank: Memloc_Stack_Info;
            table_set(loc_info, key, blank);
            info = table_find_pointer(loc_info, key);
        }
        if info.pop_epoch != pop_epoch.* {
            info.pop_epoch = pop_epoch.*;
            info.stack_epoch = stack_epoch.*;
            if info.lower_bound_block != NONE && info.lower_bound_block != bb && !dt_dominates(dt, info.lower_bound_block, bb) {
                info.lower_bound = 0;
                info.lower_bound_block = m.acc[version_stack.*[0]].block;
                info.last_kill_valid = false;
            }
        } else if info.stack_epoch != stack_epoch.* {
            info.pop_epoch = pop_epoch.*;
            info.stack_epoch = stack_epoch.*;
        }
        if !info.last_kill_valid {
            info.last_kill = cast(u64)(version_stack.count - 1);
            info.last_kill_valid = true;
        }
        upper := cast(u64)(version_stack.count - 1);
        if upper - info.lower_bound > cast(u64) mssa_opts.max_check_limit {
            info.last_kill_valid = false;
            continue;
        }
        found_clobber := false;
        limit := cast(u32) mssa_opts.max_check_limit;
        while upper > info.lower_bound {
            top := version_stack.*[upper];
            if ma_is_phi(m, top) {
                result := mssa_clobbering_access_base(m, a, aa, *limit, false, false);
                while version_stack.*[upper] != result {
                    assert(upper != 0, "MemorySSA: walker result not on the version stack");
                    upper -= 1;
                }
                found_clobber = true;
                break;
            }
            if mssa_clobbers_use(m, aa, top, a, use_mloc) { found_clobber = true; break; }
            upper -= 1;
        }
        if found_clobber || upper < info.last_kill {
            ma_set_defining(m, a, version_stack.*[upper], true);
            info.last_kill = upper;
        } else {
            ma_set_defining(m, a, version_stack.*[info.last_kill], true);
        }
        info.lower_bound = cast(u64)(version_stack.count - 1);
        info.lower_bound_block = bb;
    }
}

// MemorySSA::ensureOptimizedUses (OptimizeUses::optimizeUses with a fresh BatchAA)
mssa_ensure_optimized_uses :: (m: *Memory_SSA) {
    if m.is_optimized return;
    aa := aa_query_new(*m.aar);
    version_stack: [..] s32; version_stack.allocator = temp;
    loc_info: Table(string, Memloc_Stack_Info); loc_info.allocator = temp;
    array_add(*version_stack, MSSA_LIVE_ON_ENTRY);
    stack_epoch: u64 = 1;
    pop_epoch: u64 = 1;
    // depth_first(DT->getRootNode()): preorder, children in order
    dt := m.dt;
    root := dt_node(dt, fn_entry(m.f));
    Frame :: struct { n: s32; c: s32; }
    fs: [..] Frame; fs.allocator = temp;
    mssa_optimize_uses_in_block(m, aa, dt.nodes[root].block, *stack_epoch, *pop_epoch, *version_stack, *loc_info);
    array_add(*fs, .{root, dt.nodes[root].first_child});
    while fs.count {
        top := *fs[fs.count - 1];
        if top.c < 0 { pop(*fs); continue; }
        c := top.c;
        top.c = dt.nodes[c].sibling;
        mssa_optimize_uses_in_block(m, aa, dt.nodes[c].block, *stack_epoch, *pop_epoch, *version_stack, *loc_info);
        array_add(*fs, .{c, dt.nodes[c].first_child});
    }
    m.is_optimized = true;
}

// ---------------------------------------------------------------- printing

mssa_id_string :: (m: *Memory_SSA, a: s32) -> string {
    if a >= 0 && m.acc[a].id != 0 return tprint("%", m.acc[a].id);
    return "liveOnEntry";
}
// MemoryAccess::print
mssa_access_to_string :: (m: *Memory_SSA, a: s32) -> string {
    r := ma(m, a);
    if r.kind == {
        case .DEF;
            s := tprint("% = MemoryDef(%)", r.id, mssa_id_string(m, ma_defining(m, a)));
            if ma_is_optimized(m, a) s = tprint("%->%", s, mssa_id_string(m, ma_optimized_op(m, a)));
            return s;
        case .USE;
            return tprint("MemoryUse(%)", mssa_id_string(m, ma_defining(m, a)));
    }
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "% = MemoryPhi(", r.id);
    for k: 0..cast(s64) r.nops - 1 {
        if k > 0 append(*sb, ",");
        b := mphi_block(m, a, cast(u32) k);
        append(*sb, "{");
        if vname(b).count append(*sb, vname(b)); else append(*sb, value_as_operand(b));
        append(*sb, ",");
        append(*sb, mssa_id_string(m, mphi_value(m, a, cast(u32) k)));
        append(*sb, "}");
    }
    append(*sb, ")");
    return builder_to_string(*sb,, allocator = temp);
}

mssa_print_ctx: struct {
    m: *Memory_SSA;
    walker: bool;
    aa: *Aa_Query;
};
mssa_annot_block :: (b: Value_Id) {
    m := mssa_print_ctx.m;
    a := mssa_access_of(m, b);
    if a >= 0 { out("; "); out(mssa_access_to_string(m, a)); out("\n"); }
}
mssa_annot_inst :: (i: Value_Id) {
    m := mssa_print_ctx.m;
    a := mssa_access_of(m, i);
    if a < 0 return;
    if !mssa_print_ctx.walker { out("; "); out(mssa_access_to_string(m, a)); out("\n"); return; }
    clobber := mssa_get_clobbering_access(m, a, mssa_print_ctx.aa);
    out("; "); out(mssa_access_to_string(m, a));
    if clobber >= 0 {
        out(" - clobbered by ");
        if is_live_on_entry(clobber) out("liveOnEntry");
        else out(mssa_access_to_string(m, clobber));
    }
    out("\n");
}

// F->print(OS, &Writer) with the MemorySSA(Walker)AnnotatedWriter
mssa_print_function :: (m: *Memory_SSA, walker: bool) -> string {
    mssa_print_ctx.m = m;
    mssa_print_ctx.walker = walker;
    if walker mssa_print_ctx.aa = aa_query_new(*m.aar);
    printer_begin_function(m.f);
    start := W.buf.count;
    print_annot_block = mssa_annot_block;
    print_annot_inst = mssa_annot_inst;
    print_function(m.f);
    print_annot_block = null;
    print_annot_inst = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    return s;
}

// AM.getResult<MemorySSAAnalysis>(F)
get_memoryssa :: (f: Value_Id) -> *Memory_SSA {
    e := fam_entry(f);
    if !e.mssa {
        dt := get_domtree(f);
        aar := aa_results_for(f);
        e = fam_entry(f);
        e.mssa = mssa_build(f, dt, aar);
    }
    return e.mssa;
}
cached_memoryssa :: (f: Value_Id) -> *Memory_SSA { e := table_find_pointer(*fam, f); if e return e.mssa; return null; }

// print<memoryssa>, print<memoryssa><no-ensure-optimized-uses>, print<memoryssa-walker>, verify<memoryssa>
mssa_printer_run :: (f: Value_Id, ensure_optimized_uses: bool) {
    m := get_memoryssa(f);
    if ensure_optimized_uses mssa_ensure_optimized_uses(m);
    s := tprint("MemorySSA for function: %\n%", vname(f), mssa_print_function(m, false));
    write_string(s, to_standard_error = true);
}
mssa_walker_printer_run :: (f: Value_Id) {
    m := get_memoryssa(f);
    s := tprint("MemorySSA (walker) for function: %\n%", vname(f), mssa_print_function(m, true));
    write_string(s, to_standard_error = true);
}
// verify<memoryssa> (MemorySSAVerifierPass)
mssa_verifier_run :: (f: Value_Id) {
    m := get_memoryssa(f);
    mssa_verify(m);
}
