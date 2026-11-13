// mem2reg: port of llvm/lib/Transforms/Utils/Mem2Reg.cpp (PromotePass) and
// llvm/lib/Transforms/Utils/PromoteMemoryToRegister.cpp (isAllocaPromotable, PromoteMemToReg). Phi placement uses
// the IDF calculator in domtree.jai (llvm/include/llvm/Support/GenericIteratedDominanceFrontier.h); debug records
// go through dbg_records.jai (Local.cpp ConvertDebugDeclareToDebugValue & co).
//
// Orders that leak into the output and are reproduced here:
// - NewPhiNodes is a DenseMap<pair<block number, alloca index>, PHINode*>; the phi-simplification loop runs
//   remove_if over its buckets, so the bucket order (hash, linear probing, growth, rehash after removal) is
//   emulated exactly (M2r_Phi_Map).
// - PHIBlocks are sorted by block number; phis are inserted at the block front (last created first).
// - The rename DFS uses an explicit worklist with successors pushed in reverse.
// Assignment tracking (dbg_assign / DIAssignID) is not ported and fails loudly.

mem2reg_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    entry := glob(f).first_block;
    changed := false;
    while true {
        allocas: [..] Value_Id; allocas.allocator = temp;
        // for (I = BB.begin(), E = --BB.end(); I != E; ++I)
        last := block(entry).last;
        i := block(entry).first;
        while i != NONE && i != last {
            if inst_op(i) == .ALLOCA && is_alloca_promotable(i) array_add(*allocas, i);
            i = inst(i).next;
        }
        if allocas.count == 0 break;
        promote_mem_to_reg(allocas, dt, get_assumption_cache(f));
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- isAllocaPromotable

is_lifetime_start_or_end :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    return is_lifetime_intrinsic(intrinsic_id_of_call(i));
}
// User::isDroppable
is_droppable_user :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .CALL return false;
    id := intrinsic_id_of_call(i);
    return id == "llvm.assume" || id == "llvm.pseudoprobe" || id == "llvm.experimental.noalias.scope.decl";
}
// onlyUsedByLifetimeMarkersOrDroppableInstsHelper
only_used_by_lifetime_markers_or_droppable :: (v: Value_Id, allow_droppable: bool) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) || inst_op(user) != .CALL || intrinsic_id_of_call(user) == "" return false;
        if is_lifetime_start_or_end(user) continue;
        if allow_droppable && is_droppable_user(user) continue;
        return false;
    }
    return true;
}
is_alloca_promotable :: (ai: Value_Id) -> bool {
    expected: Type_Id = NONE;
    u := ir.v_first_use[ai];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(user) return false;
        opc := inst_op(user);
        if opc == .LOAD {
            if inst(user).flags & F_VOLATILE return false;
            if expected == NONE expected = vtype(user);
            else if vtype(user) != expected return false;
        } else if opc == .STORE {
            if op(user, 0) == ai return false;
            if inst(user).flags & F_VOLATILE return false;
            st := vtype(op(user, 0));
            if expected == NONE expected = st;
            else if st != expected return false;
        } else if opc == .CALL && intrinsic_id_of_call(user) != "" {
            if !is_lifetime_start_or_end(user) && !is_droppable_user(user) && intrinsic_id_of_call(user) != "llvm.fake.use"
                return false;
        } else if opc == .BITCAST {
            if !only_used_by_lifetime_markers_or_droppable(user, true) return false;
        } else if opc == .GEP {
            if !gep_has_all_zero_indices(user) return false;
            if !only_used_by_lifetime_markers_or_droppable(user, true) return false;
        } else if opc == .ADDRSPACECAST {
            if !only_used_by_lifetime_markers_or_droppable(user, false) return false;
        } else {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- data

M2r_Info :: struct {
    defining_blocks: [..] Value_Id;
    using_blocks: [..] Value_Id;
    only_store: Value_Id = NONE;
    only_block: Value_Id = NONE;
    only_used_in_one_block := true;
    value_type: Type_Id = NONE;
    dp_users: [..] u32;
}

M2r_Undo :: struct { idx: s64; old: u32; }
M2r_Undo_Vec :: struct {
    vals: [..] u32;
    undo: [..] M2r_Undo;
}
undo_vec_set :: (v: *M2r_Undo_Vec, idx: s64, x: u32) {
    if v.vals[idx] == x return;
    array_add(*v.undo, .{idx, v.vals[idx]});
    v.vals[idx] = x;
}
undo_vec_undo :: (v: *M2r_Undo_Vec, s: s64) {
    while s < v.undo.count {
        u := pop(*v.undo);
        v.vals[u.idx] = u.old;
    }
}

M2r_Rename_Data :: struct { bb: Value_Id; pred: Value_Id; undo_vals: s64; undo_locs: s64; }

// DenseMap<std::pair<unsigned, unsigned>, PHINode *> (llvm/include/llvm/ADT/DenseMap.h: linear probing, a "used"
// bitmap, grow to max(64, NextPowerOf2(N-1)) when entries*4 >= buckets*3, remove_if rehashes in bucket order)
M2r_Phi_Map :: struct {
    ka: [..] u32;
    kb: [..] u32;
    val: [..] Value_Id;
    used: [..] bool;
    nb: u32;
    ne: u32;
}
phi_map_hash :: (a: u32, b: u32) -> u32 {
    ha := a * 37;
    hb := b * 37;
    x: u64 = ((cast(u64) ha) << 32) | cast(u64) hb;
    x *= 0xbf58476d1ce4e5b9;
    x ^= x >> 31;
    return cast,trunc(u32) x;
}
phi_map_round_up :: (n: u32) -> u32 {
    m := cast(u64)(n - 1);   // unsigned wrap like LLVM
    if n == 0 m = 0xFFFF_FFFF;
    // NextPowerOf2(m): smallest power of two > m
    p: u64 = 1;
    while p <= m p <<= 1;
    r := cast,trunc(u32) p;
    return max(cast(u32) 64, r);
}
phi_map_grow :: (m: *M2r_Phi_Map, min_buckets: u32) {
    nb := phi_map_round_up(min_buckets);
    oka, okb, oval, oused := m.ka, m.kb, m.val, m.used;
    on := m.nb;
    nka: [..] u32; nka.allocator = temp; array_resize(*nka, nb);
    nkb: [..] u32; nkb.allocator = temp; array_resize(*nkb, nb);
    nval: [..] Value_Id; nval.allocator = temp; array_resize(*nval, nb);
    nused: [..] bool; nused.allocator = temp; array_resize(*nused, nb);
    mask := nb - 1;
    if on > 0 for i: 0..on-1 {
        if !oused[i] continue;
        bn := phi_map_hash(oka[i], okb[i]) & mask;
        while nused[bn] bn = (bn + 1) & mask;
        nka[bn] = oka[i]; nkb[bn] = okb[i]; nval[bn] = oval[i]; nused[bn] = true;
    }
    m.ka, m.kb, m.val, m.used = nka, nkb, nval, nused;
    m.nb = nb;
}
// operator[]: index of the bucket (inserted with value NONE if absent)
phi_map_get :: (m: *M2r_Phi_Map, a: u32, b: u32) -> s64 {
    if m.nb > 0 {
        mask := m.nb - 1;
        bn := phi_map_hash(a, b) & mask;
        while m.used[bn] {
            if m.ka[bn] == a && m.kb[bn] == b return bn;
            bn = (bn + 1) & mask;
        }
    }
    if (m.ne + 1) * 4 >= m.nb * 3 phi_map_grow(m, m.nb * 2);
    mask := m.nb - 1;
    bn := phi_map_hash(a, b) & mask;
    while m.used[bn] bn = (bn + 1) & mask;
    m.used[bn] = true; m.ka[bn] = a; m.kb[bn] = b; m.val[bn] = NONE;
    m.ne += 1;
    return bn;
}

M2r :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    allocas: [..] Value_Id;
    lookup: Table(Value_Id, u32);
    new_phis: M2r_Phi_Map;
    phi_to_alloca: Table(Value_Id, u32);
    dp_users: [..] [..] u32;
    value_types: [..] Type_Id;
    visited: Table(Value_Id, bool);
    num_preds: Table(Value_Id, u32);
    vals: M2r_Undo_Vec;
    locs: M2r_Undo_Vec;
    worklist: [..] M2r_Rename_Data;
    no_signed_zeros: bool;
    lbi: Table(Value_Id, u32);   // LargeBlockInfo
}

m2r_num_preds :: (m: *M2r, b: Value_Id) -> u32 {
    found, n := table_find(*m.num_preds, b);
    if found return n;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(b, *preds);
    n = cast(u32) preds.count;
    table_set(*m.num_preds, b, n);
    return n;
}

// LargeBlockInfo
lbi_is_interesting :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD { p := op(i, 0); return is_inst(p) && inst_op(p) == .ALLOCA; }
    if o == .STORE { p := op(i, 1); return is_inst(p) && inst_op(p) == .ALLOCA; }
    return false;
}
lbi_index :: (m: *M2r, i: Value_Id) -> u32 {
    found, n := table_find(*m.lbi, i);
    if found return n;
    no: u32 = 0;
    for x: block_insts(inst(i).parent) if lbi_is_interesting(x) { table_set(*m.lbi, x, no); no += 1; }
    found, n = table_find(*m.lbi, i);
    assert(found, "Didn't insert instruction?");
    return n;
}
lbi_delete :: (m: *M2r, i: Value_Id) { table_remove(*m.lbi, i); }

// ---------------------------------------------------------------- helpers from ValueTracking / InstructionSimplify

// The DominatorTree and AssumptionCache of the PromoteMem2Reg run (SimplifyQuery SQ)
m2r_cur_dt: *Dom_Tree;
m2r_cur_ac: *Assumption_Cache;

// isGuaranteedNotToBePoison(V)
m2r_not_poison :: (v: Value_Id) -> bool { return is_guaranteed_not_to_be_poison(v); }

// isKnownNonZero(V, SimplifyQuery(DL, DT, AC, CtxI))
m2r_known_non_zero :: (v: Value_Id, ctx: Value_Id) -> bool {
    q: Simplify_Query;
    q.dt = m2r_cur_dt; q.ac = m2r_cur_ac; q.cxt = ctx;
    return is_known_non_zero(v, q);
}

// DominatorTree::dominates(const Instruction *Def, const Instruction *User)
m2r_dominates_inst :: (dt: *Dom_Tree, def: Value_Id, user: Value_Id) -> bool {
    ub := inst(user).parent;
    db := inst(def).parent;
    if !dt_is_reachable_from_entry(dt, ub) return true;
    if !dt_is_reachable_from_entry(dt, db) return false;
    if def == user return false;
    dop := inst_op(def);
    if dop == .INVOKE || dop == .CALLBR || inst_op(user) == .PHI {
        // dominates(Def, UseBB)
        if db == ub return false;
        if dop == .INVOKE return m2r_dominates_edge(dt, db, get_successor(def, 0), ub);
        return dt_dominates(dt, db, ub);
    }
    if db != ub return dt_dominates(dt, db, ub);
    x := inst(def).next;
    while x != NONE { if x == user return true; x = inst(x).next; }
    return false;
}

// DominatorTree::dominates(const BasicBlockEdge &BBE, const BasicBlock *UseBB)
m2r_dominates_edge :: (dt: *Dom_Tree, start: Value_Id, end: Value_Id, use_bb: Value_Id) -> bool {
    if !dt_dominates(dt, end, use_bb) return false;
    if block_single_predecessor(end) != NONE return true;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(end, *preds);
    dup := 0;
    for bb: preds {
        if bb == start {
            if dup return false;
            dup += 1;
            continue;
        }
        if !dt_dominates(dt, end, bb) return false;
    }
    return true;
}

// simplifyInstruction(PN, SQ); NONE = no simplification
m2r_simplify_phi :: (dt: *Dom_Tree, pn: Value_Id) -> Value_Id {
    q: Simplify_Query;
    q.dt = dt; q.ac = m2r_cur_ac;
    return simplify_instruction(pn, q);
}

// ---------------------------------------------------------------- convertMetadataToAssumes etc.

add_assume_non_null :: (li: Value_Id) {
    assume := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.assume"));
    c := new_inst(.ICMP, ir.t_i1, 2);
    inst(c).pred = 33;   // ICMP_NE
    set_op(c, 0, li); set_op(c, 1, const_null_value(vtype(li)));
    inst_insert_after(c, li);
    fty := glob(assume).value_type;
    ci := new_inst(.CALL, func_ret(fty), 2);
    inst(ci).ty2 = fty;
    set_op(ci, 0, c); set_op(ci, 1, assume);
    inst_insert_after(ci, c);
    // AC->registerAssumption
    if m2r_cur_ac ac_register_assumption(m2r_cur_ac, ci);
}

convert_metadata_to_assumes :: (li: Value_Id, val: Value_Id) {
    k := vkind(val);
    has_noundef := get_metadata(li, md_fixed("noundef")) != NONE;
    if (k == .C_UNDEF || k == .C_POISON) && has_noundef {
        s := new_inst(.STORE, ir.t_void, 2);
        inst(s).align = 1;
        set_op(s, 0, const_int(ir.t_i1, 1));
        set_op(s, 1, const_poison(ir.t_ptr));
        insert_at_position(s, inst(li).parent, li, false);   // new StoreInst(..., LI->getIterator()): adopts LI's records
        return;
    }
    if get_metadata(li, md_fixed("nonnull")) != NONE && has_noundef && !m2r_known_non_zero(val, li)
        add_assume_non_null(li);
}

// Value::dropDroppableUse
drop_droppable_use :: (u: Use_Id) {
    user := ir.u_user[u];
    if intrinsic_id_of_call(user) != "llvm.assume" fatal("internal: unknown droppable use");
    opno := u - ir.v_ops[user];
    if opno == 0 { use_set(u, const_int(ir.t_i1, 1)); return; }
    use_set(u, const_poison(vtype(ir.u_val[u])));
    r := inst(user);
    if r.nidx > 0 for k: 0..r.nidx-1 {
        b := ir.u32_pool[r.idx + 3 * k + 1];
        e := ir.u32_pool[r.idx + 3 * k + 2];
        if opno >= b && opno < e { ir.u32_pool[r.idx + 3 * k] = bundle_tag_id("ignore"); return; }
    }
    fatal("internal: droppable use outside every operand bundle");
}

remove_intrinsic_users :: (ai: Value_Id) {
    u := ir.v_first_use[ai];
    while u != NONE {
        nu := ir.u_next[u];
        i := ir.u_user[u];
        o := inst_op(i);
        if o == .LOAD || o == .STORE { u = nu; continue; }
        if is_droppable_user(i) { drop_droppable_use(u); u = nu; continue; }
        if vtype(i) != ir.t_void {
            uu := ir.v_first_use[i];
            while uu != NONE {
                nuu := ir.u_next[uu];
                x := ir.u_user[uu];
                if is_droppable_user(x) drop_droppable_use(uu);
                else erase_inst_with_metadata(x);
                uu = nuu;
            }
        }
        erase_inst_with_metadata(i);
        u = nu;
    }
}

// ---------------------------------------------------------------- AllocaInfo::AnalyzeAlloca

analyze_alloca :: (m: *M2r, ai: Value_Id, info: *M2r_Info) {
    info.defining_blocks.count = 0;
    info.using_blocks.count = 0;
    info.only_store = NONE;
    info.only_block = NONE;
    info.only_used_in_one_block = true;
    info.value_type = NONE;
    info.dp_users.count = 0;
    u := ir.v_first_use[ai];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if inst_op(user) == .STORE {
            array_add(*info.defining_blocks, inst(user).parent);
            info.only_store = user;
            if info.value_type == NONE info.value_type = vtype(op(user, 0));
        } else {
            assert(inst_op(user) == .LOAD);
            array_add(*info.using_blocks, inst(user).parent);
            if info.value_type == NONE info.value_type = vtype(user);
        }
        if info.only_used_in_one_block {
            if info.only_block == NONE info.only_block = inst(user).parent;
            else if info.only_block != inst(user).parent info.only_used_in_one_block = false;
        }
    }
    all: [..] u32; all.allocator = temp;
    find_dbg_users(m.f, ai, *all);
    for all {
        if dbgr(it).kind == .ASSIGN fatal("mem2reg: assignment tracking (dbg_assign) is not supported yet");
        array_add(*info.dp_users, it);
    }
}

// ---------------------------------------------------------------- rewriteSingleStoreAlloca

rewrite_single_store_alloca :: (m: *M2r, ai: Value_Id, info: *M2r_Info) -> bool {
    only_store := info.only_store;
    repl := op(only_store, 0);
    require_dom := is_inst(repl) || !m2r_not_poison(repl);
    store_bb := inst(only_store).parent;
    store_index: s64 = -1;
    info.using_blocks.count = 0;
    u := ir.v_first_use[ai];
    while u != NONE {
        nu := ir.u_next[u];
        user := ir.u_user[u];
        u = nu;
        if user == only_store continue;
        li := user;
        if require_dom {
            lb := inst(li).parent;
            if lb == store_bb {
                if store_index == -1 store_index = lbi_index(m, only_store);
                if cast(u32) store_index > lbi_index(m, li) { array_add(*info.using_blocks, store_bb); continue; }
            } else if !dt_dominates(m.dt, store_bb, lb) {
                array_add(*info.using_blocks, lb);
                continue;
            }
        }
        if repl == li repl = const_poison(vtype(li));
        convert_metadata_to_assumes(li, repl);
        rauw_with_metadata(li, repl);
        erase_inst(li);
        lbi_delete(m, li);
        // the next use may have been the one just removed (a load using the alloca twice is impossible)
    }
    if info.using_blocks.count return false;
    for r: info.dp_users {
        rec := dbgr(r);
        if rec.kind == .DECLARE {
            convert_debug_declare_to_debug_value_store(r, only_store);
            dbgr_erase(r);
        } else if (rec.kind == .VALUE || rec.kind == .DECLARE_VALUE) && diexpr_starts_with_deref(rec.expr) {
            insert_debug_value_at_store_loc(r, only_store);
            dbgr_erase(r);
        } else if diexpr_starts_with_deref(rec.expr) {
            dbgr_erase(r);
        }
    }
    erase_inst(only_store);
    lbi_delete(m, only_store);
    erase_inst_with_metadata(ai);
    return true;
}

// ---------------------------------------------------------------- promoteSingleBlockAlloca

promote_single_block_alloca :: (m: *M2r, ai: Value_Id, info: *M2r_Info) -> bool {
    Store_Idx :: struct { idx: u32; si: Value_Id; }
    stores: [..] Store_Idx; stores.allocator = temp;
    u := ir.v_first_use[ai];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        if inst_op(user) == .STORE array_add(*stores, .{lbi_index(m, user), user});
    }
    for i: 1..stores.count-1 {
        x := stores[i];
        j := i - 1;
        while j >= 0 && stores[j].idx > x.idx { stores[j + 1] = stores[j]; j -= 1; }
        stores[j + 1] = x;
    }
    u = ir.v_first_use[ai];
    while u != NONE {
        nu := ir.u_next[u];
        li := ir.u_user[u];
        u = nu;
        if inst_op(li) != .LOAD continue;
        load_idx := lbi_index(m, li);
        // lower_bound on the index
        lo := 0; hi := stores.count;
        while lo < hi { mid := (lo + hi) / 2; if stores[mid].idx < load_idx lo = mid + 1; else hi = mid; }
        repl: Value_Id;
        if lo == 0 {
            if stores.count == 0 repl = const_undef(vtype(li));
            else return false;
        } else {
            repl = op(stores[lo - 1].si, 0);
        }
        convert_metadata_to_assumes(li, repl);
        if repl == li repl = const_poison(vtype(li));
        rauw_with_metadata(li, repl);
        erase_inst(li);
        lbi_delete(m, li);
    }
    while has_uses(ai) {
        si := ir.u_user[ir.v_first_use[ai]];
        for r: info.dp_users if dbgr(r).kind == .DECLARE convert_debug_declare_to_debug_value_store(r, si);
        erase_inst(si);
        lbi_delete(m, si);
    }
    erase_inst_with_metadata(ai);
    for r: info.dp_users {
        rec := dbgr(r);
        if (rec.kind == .DECLARE || diexpr_starts_with_deref(rec.expr)) && rec.owner != NONE dbgr_erase(r);
    }
    return true;
}

// ---------------------------------------------------------------- PromoteMem2Reg::run

remove_from_allocas :: (m: *M2r, idx: *s64) {
    m.allocas[idx.*] = m.allocas[m.allocas.count - 1];
    m.allocas.count -= 1;
    idx.* -= 1;
}

promote_mem_to_reg :: (allocas: [] Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache) {
    if allocas.count == 0 return;
    m2r_cur_dt = dt; m2r_cur_ac = ac;
    m: M2r;
    m.allocas.allocator = temp; m.dp_users.allocator = temp; m.value_types.allocator = temp;
    m.worklist.allocator = temp;
    m.vals.vals.allocator = temp; m.vals.undo.allocator = temp; m.locs.vals.allocator = temp; m.locs.undo.allocator = temp;
    m.lookup.allocator = temp; m.phi_to_alloca.allocator = temp; m.visited.allocator = temp; m.num_preds.allocator = temp;
    m.lbi.allocator = temp;
    m.new_phis.ka.allocator = temp; m.new_phis.kb.allocator = temp; m.new_phis.val.allocator = temp; m.new_phis.used.allocator = temp;
    for allocas array_add(*m.allocas, it);
    m.dt = dt;
    m.f = block_fn(inst(allocas[0]).parent);
    f := m.f;
    dbgr_index_reset();
    array_resize(*m.dp_users, m.allocas.count);
    for * m.dp_users it.allocator = temp;
    array_resize(*m.value_types, m.allocas.count);
    m.no_signed_zeros = false;
    for attr_set_items(attr_list_fn(glob(f).attrs))
        if it.kind == .STRING_ATTR && it.key == "no-signed-zeros-fp-math" m.no_signed_zeros = it.val == "true";

    info: M2r_Info;
    info.defining_blocks.allocator = temp; info.using_blocks.allocator = temp; info.dp_users.allocator = temp;

    n: s64 = -1;
    while true {
        n += 1;
        if n >= m.allocas.count break;
        ai := m.allocas[n];
        remove_intrinsic_users(ai);
        if !has_uses(ai) {
            erase_inst_with_metadata(ai);
            remove_from_allocas(*m, *n);
            continue;
        }
        analyze_alloca(*m, ai, *info);
        if info.defining_blocks.count == 1 {
            if rewrite_single_store_alloca(*m, ai, *info) { remove_from_allocas(*m, *n); continue; }
        }
        if info.only_used_in_one_block && promote_single_block_alloca(*m, ai, *info) {
            remove_from_allocas(*m, *n);
            continue;
        }
        if info.dp_users.count {
            m.dp_users[n].count = 0;
            for info.dp_users array_add(*m.dp_users[n], it);
        }
        m.value_types[n] = info.value_type;
        table_set(*m.lookup, ai, cast(u32) n);

        def_set := *m2r_def_set; bset_clear(def_set);
        def_list: [..] Value_Id; def_list.allocator = temp;
        for info.defining_blocks if !bset_has(def_set, it) { bset_add(def_set, it); array_add(*def_list, it); }
        live_in := *m2r_live_in; bset_clear(live_in);
        compute_live_in_blocks(ai, *info, def_set, live_in);
        phi_blocks: [..] Value_Id; phi_blocks.allocator = temp;
        idf_calculate(dt, def_list, def_set, live_in, *phi_blocks);
        for i: 1..phi_blocks.count-1 {
            x := phi_blocks[i]; nx := block_number(x);
            j := i - 1;
            while j >= 0 && block_number(phi_blocks[j]) > nx { phi_blocks[j + 1] = phi_blocks[j]; j -= 1; }
            phi_blocks[j + 1] = x;
        }
        version: u32 = 0;
        for bb: phi_blocks queue_phi_node(*m, bb, cast(u32) n, *version);
    }

    if m.allocas.count == 0 return;
    table_reset(*m.lbi);

    array_resize(*m.vals.vals, m.allocas.count);
    for i: 0..m.allocas.count-1 m.vals.vals[i] = const_undef(m.value_types[i]);
    array_resize(*m.locs.vals, m.allocas.count);
    for i: 0..m.allocas.count-1 m.locs.vals[i] = NONE;

    push_worklist(*m, glob(f).first_block, NONE);
    while true {
        rpd := pop(*m.worklist);
        undo_vec_undo(*m.vals, rpd.undo_vals);
        undo_vec_undo(*m.locs, rpd.undo_locs);
        rename_pass(*m, rpd.bb, rpd.pred);
        if m.worklist.count == 0 break;
    }

    for a: m.allocas {
        if has_uses(a) rauw_with_metadata(a, const_poison(vtype(a)));
        erase_inst_with_metadata(a);
    }
    for l: m.dp_users for r: l {
        rec := dbgr(r);
        if rec.owner == NONE continue;
        if rec.kind == .DECLARE || diexpr_starts_with_deref(rec.expr) dbgr_erase(r);
    }

    // eliminate phis that merge one value (remove_if over the DenseMap buckets, repeated while anything changes)
    pm := *m.new_phis;
    while true {
        removed := false;
        nb := pm.nb;
        if nb > 0 for b: 0..nb-1 {
            if !pm.used[b] continue;
            pn := pm.val[b];
            v := m2r_simplify_phi(dt, pn);
            if v != NONE {
                rauw_with_metadata(pn, v);
                erase_inst_with_metadata(pn);
                pm.used[b] = false;
                pm.ne -= 1;
                removed = true;
            }
        }
        if !removed break;
        phi_map_grow(pm, pm.nb);
    }

    // add poison entries for predecessors the renamer never reached
    if pm.nb > 0 for b: 0..pm.nb-1 {
        if !pm.used[b] continue;
        some := pm.val[b];
        bb := inst(some).parent;
        if block(bb).first != some continue;
        if nops(some) == m2r_num_preds(*m, bb) continue;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for i: 1..preds.count-1 {
            x := preds[i]; nx := block_number(x);
            j := i - 1;
            while j >= 0 && block_number(preds[j]) > nx { preds[j + 1] = preds[j]; j -= 1; }
            preds[j + 1] = x;
        }
        k := nops(some);
        if k > 0 for i: 0..k-1 {
            ib := phi_block(some, i);
            nib := block_number(ib);
            lo := 0; hi := preds.count;
            while lo < hi { mid := (lo + hi) / 2; if block_number(preds[mid]) < nib lo = mid + 1; else hi = mid; }
            assert(lo < preds.count && preds[lo] == ib, "PHI node has entry for a block which is not a predecessor!");
            array_ordered_remove_by_index(*preds, lo);
        }
        num_bad := nops(some);
        p := block(bb).first;
        while p != NONE && inst_op(p) == .PHI && nops(p) == num_bad {
            nxt := inst(p).next;
            pv := const_poison(vtype(p));
            for pr: preds phi_add_incoming(p, pv, pr);
            p = nxt;
        }
    }
}

push_worklist :: (m: *M2r, bb: Value_Id, pred: Value_Id) {
    array_add(*m.worklist, .{bb, pred, m.vals.undo.count, m.locs.undo.count});
}

// ComputeLiveInBlocks
// DefBlocks / LiveInBlocks of the alloca being promoted (Block_Set: cleared per alloca in O(1))
m2r_def_set: Block_Set;
m2r_live_in: Block_Set;

compute_live_in_blocks :: (ai: Value_Id, info: *M2r_Info, def_set: *Block_Set, live_in: *Block_Set) {
    wl: [..] Value_Id; wl.allocator = temp;
    for info.using_blocks array_add(*wl, it);
    i := -1;
    e := wl.count;
    while true {
        i += 1;
        if i == e break;
        bb := wl[i];
        if !bset_has(def_set, bb) continue;
        x := block(bb).first;
        while true {
            o := inst_op(x);
            if o == .STORE {
                if op(x, 1) != ai { x = inst(x).next; continue; }
                wl[i] = wl[wl.count - 1];
                wl.count -= 1;
                i -= 1;
                e -= 1;
                break;
            }
            if o == .LOAD && op(x, 0) == ai break;
            x = inst(x).next;
        }
    }
    preds: [..] Value_Id; preds.allocator = temp;
    while wl.count {
        bb := pop(*wl);
        if bset_has(live_in, bb) continue;
        bset_add(live_in, bb);
        block_predecessors(bb, *preds);
        for p: preds {
            if bset_has(def_set, p) continue;
            array_add(*wl, p);
        }
    }
}

// QueuePhiNode
queue_phi_node :: (m: *M2r, bb: Value_Id, alloca_no: u32, version: *u32) -> bool {
    slot := phi_map_get(*m.new_phis, block_number(bb), alloca_no);
    if m.new_phis.val[slot] != NONE return false;
    pn := create_phi(m.value_types[alloca_no], m2r_num_preds(m, bb));
    name := tconcat(vname(m.allocas[alloca_no]), ".", tdec(version.*));
    version.* += 1;
    m.new_phis.val[slot] = pn;
    insert_before_named(pn, block(bb).first, name);
    table_set(*m.phi_to_alloca, pn, alloca_no);
    return true;
}

// updateForIncomingValueLocation
update_for_incoming_value_location :: (pn: Value_Id, dl: Md_Id, apply_merged: bool) {
    new_dl := dl;
    if apply_merged new_dl = merged_debug_loc(get_metadata(pn, 0), dl);
    set_metadata(pn, 0, new_dl);
}

// RenamePass
rename_pass :: (m: *M2r, bb: Value_Id, pred: Value_Id) {
    apn := block(bb).first;
    if apn != NONE && inst_op(apn) == .PHI && table_contains(*m.phi_to_alloca, apn) {
        new_phi_num_operands := nops(apn);
        num_edges: u32 = 0;
        t := block_terminator(pred);
        ns := num_successors(t);
        if ns > 0 for s: 0..ns-1 if get_successor(t, s) == bb num_edges += 1;
        assert(num_edges > 0, "Must be at least one edge from Pred to BB!");
        while true {
            found, alloca_no := table_find(*m.phi_to_alloca, apn);
            if !found fatal("internal: mem2reg reached a pre-existing phi with the operand count of an inserted one");
            update_for_incoming_value_location(apn, m.locs.vals[alloca_no], nops(apn) > 0);
            for 1..num_edges phi_add_incoming(apn, m.vals.vals[alloca_no], pred);
            if m.no_signed_zeros && is_fp_math_type(vtype(apn)) inst(apn).flags |= FMF_NSZ << FMF_SHIFT;
            undo_vec_set(*m.vals, alloca_no, apn);
            for r: m.dp_users[alloca_no] if dbgr(r).kind == .DECLARE convert_debug_declare_to_debug_value_phi(m.f, r, apn);
            apn = inst(apn).next;
            if apn == NONE || inst_op(apn) != .PHI break;
            if nops(apn) != new_phi_num_operands break;
        }
    }
    if table_contains(*m.visited, bb) return;
    table_set(*m.visited, bb, true);

    i := block(bb).first;
    while !is_terminator(inst_op(i)) {
        cur := i;
        i = inst(i).next;
        o := inst_op(cur);
        if o == .LOAD {
            src := op(cur, 0);
            if !is_inst(src) || inst_op(src) != .ALLOCA continue;
            found, idx := table_find(*m.lookup, src);
            if !found continue;
            v := m.vals.vals[idx];
            convert_metadata_to_assumes(cur, v);
            rauw_with_metadata(cur, v);
            erase_inst(cur);
        } else if o == .STORE {
            dest := op(cur, 1);
            if !is_inst(dest) || inst_op(dest) != .ALLOCA continue;
            found, idx := table_find(*m.lookup, dest);
            if !found continue;
            undo_vec_set(*m.vals, idx, op(cur, 0));
            undo_vec_set(*m.locs, idx, get_metadata(cur, 0));
            for r: m.dp_users[idx] if dbgr(r).kind == .DECLARE convert_debug_declare_to_debug_value_store(r, cur);
            erase_inst(cur);
        }
    }

    t := block_terminator(bb);
    ns := num_successors(t);
    seen: [..] Value_Id; seen.allocator = temp;
    if ns > 0 for < s: 0..ns-1 {
        succ := get_successor(t, cast(u32) s);
        dup := false;
        for seen if it == succ { dup = true; break; }
        if dup continue;
        array_add(*seen, succ);
        push_worklist(m, succ, bb);
    }
}
