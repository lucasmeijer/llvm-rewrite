// MemorySSA: a port of llvm/lib/Analysis/MemorySSA.cpp (construction: createNewAccess, placePHINodes, renamePass,
// markUnreachableAsLiveOnEntry; OptimizeUses (ensureOptimizedUses); the ClobberWalker with phi optimization and the
// CachingWalker / SkipSelfWalker entry points; dominance between accesses; the print<memoryssa> and
// print<memoryssa-walker> annotated printers), of upward_defs_iterator / def_chain from
// llvm/include/llvm/Analysis/MemorySSA.h and of llvm/lib/Analysis/PHITransAddr.cpp (translateValue).
//
// Data-oriented: a MemorySSA is a table of Mem_Access rows (index 0 = liveOnEntry); a row's kind (DEF / USE / PHI) is
// a tag, operands are row indices (`defining` = operand 0, `optimized` = MemoryDef's operand 1, phi incoming values in
// `phi_vals` / `phi_blocks`). Per-block access and def lists are intrusive doubly linked lists through the rows
// (prev/next and dprev/dnext), with heads in `blocks`. The result lives on the heap (cached in the function analysis
// manager); AA query state (BatchAAResults) lives in temp for one construction / walk / printer run.
//
// Not ported yet: MemorySSAUpdater, the use lists of accesses (users()), loop-scoped MemorySSA (MemorySSA(Loop&)),
// verifyMemorySSA (verify<memoryssa> and -verify-memoryssa are accepted and check nothing), -dot-cfg-mssa.

MSSA_LIVE_ON_ENTRY :: cast(s32) 0;
MSSA_INVALID_ID :: 0xFFFF_FFFF;

mssa_opts: struct {
    max_check_limit: s64 = 100;     // -memssa-check-limit
    verify := false;                // -verify-memoryssa (no verifier yet: accepted, checks nothing)
};

Ma_Kind :: enum u8 { DEF; USE; PHI; }

Mem_Access :: struct {
    kind: Ma_Kind;
    id: u32;                        // DEF / PHI (liveOnEntry = 0); uses have no id
    inst: Value_Id = NONE;          // DEF / USE
    block: Value_Id = NONE;
    defining: s32 = -1;             // operand 0 of a DEF / USE
    optimized: s32 = -1;            // operand 1 of a DEF
    optimized_id: u32 = MSSA_INVALID_ID;
    phi_vals: [..] s32;             // PHI incoming values and blocks, operand order
    phi_blocks: [..] Value_Id;
    prev: s32 = -1; next: s32 = -1;     // the block's access list
    dprev: s32 = -1; dnext: s32 = -1;   // the block's defs list (DEFs and PHIs)
    in_lists: bool;
}

Mssa_Block :: struct { first: s32 = -1; last: s32 = -1; dfirst: s32 = -1; dlast: s32 = -1; }

Memory_SSA :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    aar: Aa_Results;
    acc: [..] Mem_Access;
    next_id: u32;
    of_value: Table(Value_Id, s32);      // ValueToMemoryAccess (instructions; blocks -> their MemoryPhi)
    blocks: Table(Value_Id, Mssa_Block); // PerBlockAccesses / PerBlockDefs
    numbering: Table(s32, u32);          // BlockNumbering
    numbered: Table(Value_Id, bool);     // BlockNumberingValid
    is_optimized: bool;
}

mssa_free :: (m: *Memory_SSA) {
    for * m.acc { array_free(it.phi_vals); array_free(it.phi_blocks); }
    array_free(m.acc);
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

// MemoryUseOrDef::isOptimized / getOptimized / setOptimized / resetOptimized
ma_is_optimized :: (m: *Memory_SSA, a: s32) -> bool {
    r := ma(m, a);
    if r.kind == .DEF return r.optimized >= 0 && r.optimized_id == m.acc[r.optimized].id;
    return r.defining >= 0 && r.optimized_id == m.acc[r.defining].id;
}
ma_get_optimized :: (m: *Memory_SSA, a: s32) -> s32 {
    r := ma(m, a);
    if r.kind == .DEF return r.optimized;
    return r.defining;
}
ma_set_optimized :: (m: *Memory_SSA, a: s32, to: s32) {
    r := ma(m, a);
    if r.kind == .DEF r.optimized = to; else r.defining = to;
    r.optimized_id = m.acc[to].id;
}
ma_reset_optimized :: (m: *Memory_SSA, a: s32) {
    r := ma(m, a);
    r.optimized_id = MSSA_INVALID_ID;
    if r.kind == .DEF r.optimized = -1;
}
// setDefiningAccess(DMA, Optimized)
ma_set_defining :: (m: *Memory_SSA, a: s32, d: s32, optimized := false) {
    if optimized { ma_set_optimized(m, a, d); return; }
    m.acc[a].defining = d;
}

new_access :: (m: *Memory_SSA, kind: Ma_Kind, i: Value_Id, b: Value_Id) -> s32 {
    r: Mem_Access; r.kind = kind; r.inst = i; r.block = b;
    if kind != .USE { r.id = m.next_id; m.next_id += 1; }
    array_add(*m.acc, r);
    return cast(s32)(m.acc.count - 1);
}

// ---------------------------------------------------------------- lists

list_push_back :: (m: *Memory_SSA, b: Value_Id, a: s32) {
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    r.prev = l.last; r.next = -1; r.in_lists = true;
    if l.last >= 0 m.acc[l.last].next = a; else l.first = a;
    l.last = a;
}
list_push_front :: (m: *Memory_SSA, b: Value_Id, a: s32) {
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    r.next = l.first; r.prev = -1; r.in_lists = true;
    if l.first >= 0 m.acc[l.first].prev = a; else l.last = a;
    l.first = a;
}
defs_push_back :: (m: *Memory_SSA, b: Value_Id, a: s32) {
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    r.dprev = l.dlast; r.dnext = -1;
    if l.dlast >= 0 m.acc[l.dlast].dnext = a; else l.dfirst = a;
    l.dlast = a;
}
defs_push_front :: (m: *Memory_SSA, b: Value_Id, a: s32) {
    l := mssa_block_or_create(m, b);
    r := ma(m, a);
    r.dnext = l.dfirst; r.dprev = -1;
    if l.dfirst >= 0 m.acc[l.dfirst].dprev = a; else l.dlast = a;
    l.dfirst = a;
}
// erase from the access list (and defs list) of its block
list_erase :: (m: *Memory_SSA, a: s32) {
    r := ma(m, a);
    l := mssa_block(m, r.block);
    if r.prev >= 0 m.acc[r.prev].next = r.next; else l.first = r.next;
    if r.next >= 0 m.acc[r.next].prev = r.prev; else l.last = r.prev;
    if r.kind != .USE {
        if r.dprev >= 0 m.acc[r.dprev].dnext = r.dnext; else l.dfirst = r.dnext;
        if r.dnext >= 0 m.acc[r.dnext].dprev = r.dprev; else l.dlast = r.dprev;
    }
    r.prev = -1; r.next = -1; r.dprev = -1; r.dnext = -1; r.in_lists = false;
    if l.first < 0 table_remove(*m.blocks, r.block);
    table_remove(*m.numbered, r.block);
}
// getBlockDefs(BB)->rbegin(): the last def or phi of a block, -1 if none
mssa_last_block_def :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.dlast;
}
// getBlockAccesses(BB)->front()
mssa_first_access :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    l := mssa_block(m, b);
    if !l return -1;
    return l.first;
}

// ---------------------------------------------------------------- construction

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

// MemorySSA::createNewAccess (no Template)
mssa_create_new_access :: (m: *Memory_SSA, i: Value_Id, q: *Aa_Query) -> s32 {
    id := call_iid(i);
    if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_ASSUME ||
       id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_PSEUDOPROBE return -1;
    if !may_read_from_memory(i) && !may_write_to_memory(i) return -1;
    mr := aa_mod_ref_inst_opt_loc(q, i, false, .{});
    def := (mr & MR_MOD) != 0 || inst_is_ordered(i);
    use := (mr & MR_REF) != 0;
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

// MemorySSA::createMemoryPhi (insertIntoListsForBlock(Phi, BB, Beginning))
mssa_create_phi :: (m: *Memory_SSA, b: Value_Id) -> s32 {
    a := new_access(m, .PHI, NONE, b);
    list_push_front(m, b, a);
    defs_push_front(m, b, a);
    table_remove(*m.numbered, b);
    table_set(*m.of_value, b, a);
    return a;
}
phi_add_incoming :: (m: *Memory_SSA, p: s32, v: s32, b: Value_Id) {
    array_add(*m.acc[p].phi_vals, v);
    array_add(*m.acc[p].phi_blocks, b);
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
            if r.defining < 0 || rename_all_uses ma_set_defining(m, a, incoming);
            if r.kind == .DEF incoming = a;
        } else incoming = a;
        a = r.next;
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
            r := ma(m, f);
            for k: 0..r.phi_vals.count-1 if r.phi_blocks[k] == b r.phi_vals[k] = incoming;
        } else phi_add_incoming(m, f, incoming, b);
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

// markUnreachableAsLiveOnEntry
mssa_mark_unreachable_as_live_on_entry :: (m: *Memory_SSA, b: Value_Id) {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    for s: succs {
        if !dt_is_reachable_from_entry(m.dt, s) continue;
        f := mssa_first_access(m, s);
        if f < 0 || !ma_is_phi(m, f) continue;
        phi_add_incoming(m, f, MSSA_LIVE_ON_ENTRY, b);
    }
    l := mssa_block(m, b);
    if !l return;
    a := l.first;
    while a >= 0 {
        nx := m.acc[a].next;
        if m.acc[a].kind != .PHI ma_set_defining(m, a, MSSA_LIVE_ON_ENTRY);
        else {
            list_erase(m, a);
            if table_find_pointer(*m.of_value, b) table_remove(*m.of_value, b);
            l = mssa_block(m, b);
            if !l return;
        }
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
        x: Upward_Defs_Elem; x.ma = r.defining; x.loc = e.loc; x.mbci = e.mbci;
        array_add(out, x);
        return;
    }
    for k: 0..r.phi_vals.count-1 {
        x: Upward_Defs_Elem; x.ma = r.phi_vals[k]; x.loc = e.loc; x.mbci = e.mbci;
        if e.loc.ptr != NONE {
            addr := phi_translate_value(e.loc.ptr, r.block, r.phi_blocks[k], m.dt, true);
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
        cur = r.defining;
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
                    x = r.defining;
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
    if ma_is_use(m, start) current = m.acc[start].defining;
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
            if ma_is_use(m, cma) return m.acc[cma].defining;
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
        defining := m.acc[a].defining;
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
            s := tprint("% = MemoryDef(%)", r.id, mssa_id_string(m, r.defining));
            if ma_is_optimized(m, a) s = tprint("%->%", s, mssa_id_string(m, r.optimized));
            return s;
        case .USE;
            return tprint("MemoryUse(%)", mssa_id_string(m, r.defining));
    }
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "% = MemoryPhi(", r.id);
    for k: 0..r.phi_vals.count-1 {
        if k > 0 append(*sb, ",");
        b := r.phi_blocks[k];
        append(*sb, "{");
        if vname(b).count append(*sb, vname(b)); else append(*sb, value_as_operand(b));
        append(*sb, ",");
        append(*sb, mssa_id_string(m, r.phi_vals[k]));
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
