// SSAUpdater + LoadAndStorePromoter: port of llvm/lib/Transforms/Utils/SSAUpdater.cpp and
// llvm/include/llvm/Transforms/Utils/SSAUpdaterImpl.h. Blocks are keyed by Value_Id; BBInfo rows live in a temp
// array and are referenced by index (-1 = null).

Ssa_Updater :: struct {
    proto_ty: Type_Id = NONE;
    proto_name: string;
    avail: Table(Value_Id, Value_Id);   // AvailableVals (a value of NONE = no entry)
    inserted_phis: *[..] Value_Id;
}

ssa_init :: (s: *Ssa_Updater, ty: Type_Id, name: string) {
    s.avail.allocator = temp;
    table_reset(*s.avail);
    s.proto_ty = ty;
    s.proto_name = name;
}
ssa_has_value :: (s: *Ssa_Updater, b: Value_Id) -> bool { return table_contains(*s.avail, b); }
ssa_add_available :: (s: *Ssa_Updater, b: Value_Id, v: Value_Id) { table_set(*s.avail, b, v); }
ssa_lookup :: (s: *Ssa_Updater, b: Value_Id) -> Value_Id { found, v := table_find(*s.avail, b); if found return v; return NONE; }

// pred list: walk a phi if the block starts with one, else predecessors(BB)
ssa_preds :: (b: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    f := block(b).first;
    if f != NONE && inst_op(f) == .PHI {
        n := nops(f);
        if n > 0 for k: 0..n-1 array_add(out, phi_block(f, k));
        return;
    }
    tmp: [..] Value_Id; tmp.allocator = temp;
    block_predecessors(b, *tmp);
    for tmp array_add(out, it);
}

Ssa_Info :: struct {
    bb: Value_Id;
    avail: Value_Id;
    def: s64;
    num: s64;
    idom: s64 = -1;
    preds: [..] s64;
    phi_tag: Value_Id = NONE;
}

Ssa_Impl :: struct {
    s: *Ssa_Updater;
    infos: [..] Ssa_Info;
    map: Table(Value_Id, s64);
}

ssai_new :: (m: *Ssa_Impl, bb: Value_Id, v: Value_Id) -> s64 {
    x: Ssa_Info;
    x.bb = bb; x.avail = v;
    id := m.infos.count;
    x.def = ifx v != NONE then id else -1;
    x.preds.allocator = temp;
    array_add(*m.infos, x);
    return id;
}

// SSAUpdaterImpl::GetValue
ssai_get_value :: (s: *Ssa_Updater, bb: Value_Id) -> Value_Id {
    m: Ssa_Impl;
    m.s = s;
    m.infos.allocator = temp; m.map.allocator = temp;
    I :: (m: *Ssa_Impl, i: s64) -> *Ssa_Info #expand { return *m.infos[i]; }
    // BuildBlockList
    roots: [..] s64; roots.allocator = temp;
    wl: [..] s64; wl.allocator = temp;
    info := ssai_new(*m, bb, NONE);
    table_set(*m.map, bb, info);
    array_add(*wl, info);
    preds: [..] Value_Id; preds.allocator = temp;
    while wl.count {
        info = pop(*wl);
        ssa_preds(m.infos[info].bb, *preds);
        for p: preds {
            found, pi := table_find(*m.map, p);
            if found { array_add(*m.infos[info].preds, pi); continue; }
            pv := ssa_lookup(s, p);
            pi = ssai_new(*m, p, pv);
            table_set(*m.map, p, pi);
            array_add(*m.infos[info].preds, pi);
            if pv != NONE { array_add(*roots, pi); continue; }
            array_add(*wl, pi);
        }
    }
    block_list: [..] s64; block_list.allocator = temp;
    pseudo := ssai_new(*m, NONE, NONE);
    blk_num: s64 = 1;
    while roots.count {
        info = pop(*roots);
        m.infos[info].idom = pseudo;
        m.infos[info].num = -1;
        array_add(*wl, info);
    }
    succs: [..] Value_Id; succs.allocator = temp;
    while wl.count {
        info = wl[wl.count - 1];
        if m.infos[info].num == -2 {
            m.infos[info].num = blk_num; blk_num += 1;
            if m.infos[info].avail == NONE array_add(*block_list, info);
            wl.count -= 1;
            continue;
        }
        m.infos[info].num = -2;
        block_successors(m.infos[info].bb, *succs);
        for sb: succs {
            found, si := table_find(*m.map, sb);
            if !found || m.infos[si].num != 0 continue;
            m.infos[si].num = -1;
            array_add(*wl, si);
        }
    }
    m.infos[pseudo].num = blk_num;
    if block_list.count == 0 {
        v := const_poison(s.proto_ty);
        table_set(*s.avail, bb, v);
        return v;
    }
    // FindDominators
    intersect :: (m: *Ssa_Impl, a_in: s64, b_in: s64) -> s64 {
        a := a_in; b := b_in;
        while a != b {
            while m.infos[a].num < m.infos[b].num { a = m.infos[a].idom; if a < 0 return b; }
            while m.infos[b].num < m.infos[a].num { b = m.infos[b].idom; if b < 0 return a; }
        }
        return a;
    }
    while true {
        changed := false;
        for < bi: block_list {
            new_idom: s64 = -1;
            for p: m.infos[bi].preds {
                if m.infos[p].num == 0 {
                    v := const_poison(s.proto_ty);
                    m.infos[p].avail = v;
                    table_set(*s.avail, m.infos[p].bb, v);
                    m.infos[p].def = p;
                    m.infos[p].num = m.infos[pseudo].num;
                    m.infos[pseudo].num += 1;
                }
                if new_idom < 0 new_idom = p;
                else new_idom = intersect(*m, new_idom, p);
            }
            if new_idom >= 0 && new_idom != m.infos[bi].idom { m.infos[bi].idom = new_idom; changed = true; }
        }
        if !changed break;
    }
    // FindPHIPlacement
    def_in_frontier :: (m: *Ssa_Impl, p_in: s64, idom: s64) -> bool {
        p := p_in;
        while p != idom { if m.infos[p].def == p return true; p = m.infos[p].idom; }
        return false;
    }
    while true {
        changed := false;
        for < bi: block_list {
            if m.infos[bi].def == bi continue;
            nd := m.infos[m.infos[bi].idom].def;
            for p: m.infos[bi].preds if def_in_frontier(*m, p, m.infos[bi].idom) { nd = bi; break; }
            if nd != m.infos[bi].def { m.infos[bi].def = nd; changed = true; }
        }
        if !changed break;
    }
    // FindAvailableVals
    for bi: block_list {
        x := *m.infos[bi];
        if x.def != bi continue;
        // FindSingularVal
        if x.preds.count {
            singular := m.infos[m.infos[x.preds[0]].def].avail;
            ok := singular != NONE;
            if ok for k: 1..x.preds.count-1 {
                pv := m.infos[m.infos[x.preds[k]].def].avail;
                if pv == NONE || pv != singular { ok = false; break; }
            }
            if ok {
                table_set(*s.avail, x.bb, singular);
                x.avail = singular;
                x.def = m.infos[x.preds[0]].def;
                continue;
            }
        }
        ssai_find_existing_phi(*m, x.bb);
        x = *m.infos[bi];
        if x.avail != NONE continue;
        // CreateEmptyPHI
        phi := create_phi(s.proto_ty, cast(u32) x.preds.count);
        insert_at_position(phi, x.bb, block(x.bb).first, true);
        if s.proto_name.count set_name(phi, s.proto_name);
        x.avail = phi;
        table_set(*s.avail, x.bb, phi);
    }
    for < bi: block_list {
        x := *m.infos[bi];
        if x.def != bi { table_set(*s.avail, x.bb, m.infos[x.def].avail); continue; }
        phi := x.avail;
        if !(is_inst(phi) && inst_op(phi) == .PHI && nops(phi) == 0) continue;
        for p: x.preds {
            pi := p;
            pred := m.infos[p].bb;
            if m.infos[pi].def != pi pi = m.infos[pi].def;
            phi_add_incoming(phi, m.infos[pi].avail, pred);
        }
        if s.inserted_phis array_add(s.inserted_phis, phi);
    }
    found, r := table_find(*m.map, bb);
    return m.infos[m.infos[r].def].avail;
}

SSA_PHI_SEARCH_LIMIT :: 80;

ssai_find_existing_phi :: (m: *Ssa_Impl, bb: Value_Id) {
    tagged: [..] s64; tagged.allocator = temp;
    count := 0;
    p := block(bb).first;
    while p != NONE && inst_op(p) == .PHI {
        count += 1;
        if count > SSA_PHI_SEARCH_LIMIT break;
        if ssai_check_phi_matches(m, p, *tagged) {
            for t: tagged {
                phi := m.infos[t].phi_tag;
                pb := inst(phi).parent;
                table_set(*m.s.avail, pb, phi);
                found, bi := table_find(*m.map, pb);
                m.infos[bi].avail = phi;
            }
            break;
        }
        p = inst(p).next;
    }
}

ssai_check_phi_matches :: (m: *Ssa_Impl, phi_in: Value_Id, tagged: *[..] s64) -> bool {
    cleanup :: (m: *Ssa_Impl, tagged: *[..] s64) { for tagged.* m.infos[it].phi_tag = NONE; tagged.count = 0; }
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, phi_in);
    found, pb := table_find(*m.map, inst(phi_in).parent);
    m.infos[pb].phi_tag = phi_in;
    array_add(tagged, pb);
    while wl.count {
        phi := pop(*wl);
        n := nops(phi);
        if n > 0 for k: 0..n-1 {
            inc := op(phi, k);
            f2, pi := table_find(*m.map, phi_block(phi, k));
            if !f2 fatal("internal: SSAUpdater: incoming block not in the block map");
            if m.infos[pi].def != pi pi = m.infos[pi].def;
            if m.infos[pi].avail != NONE {
                if inc == m.infos[pi].avail continue;
                cleanup(m, tagged); return false;
            }
            if !(is_inst(inc) && inst_op(inc) == .PHI) || inst(inc).parent != m.infos[pi].bb { cleanup(m, tagged); return false; }
            if m.infos[pi].phi_tag != NONE {
                if inc == m.infos[pi].phi_tag continue;
                cleanup(m, tagged); return false;
            }
            m.infos[pi].phi_tag = inc;
            array_add(tagged, pi);
            array_add(*wl, inc);
        }
    }
    return true;
}

// GetValueAtEndOfBlock
ssa_value_at_end :: (s: *Ssa_Updater, bb: Value_Id) -> Value_Id {
    v := ssa_lookup(s, bb);
    if v != NONE return v;
    return ssai_get_value(s, bb);
}

// GetValueInMiddleOfBlock
ssa_value_in_middle :: (s: *Ssa_Updater, bb: Value_Id) -> Value_Id {
    if !ssa_has_value(s, bb) return ssa_value_at_end(s, bb);
    Pv :: struct { b: Value_Id; v: Value_Id; }
    pvs: [..] Pv; pvs.allocator = temp;
    singular: Value_Id = NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    ssa_preds(bb, *preds);
    for p, i: preds {
        v := ssa_value_at_end(s, p);
        array_add(*pvs, .{p, v});
        if i == 0 singular = v;
        else if v != singular singular = NONE;
    }
    if pvs.count == 0 return const_poison(s.proto_ty);
    if singular != NONE return singular;
    f := block(bb).first;
    if f != NONE && inst_op(f) == .PHI {
        x := f;
        while x != NONE && inst_op(x) == .PHI {
            // IsEquivalentPHI against the (deduplicating) mapping
            if ssa_equivalent_phi(x, pvs) return x;
            x = inst(x).next;
        }
    }
    phi := create_phi(s.proto_ty, cast(u32) pvs.count);
    insert_at_position(phi, bb, block(bb).first, true);
    if s.proto_name.count set_name(phi, s.proto_name);
    for pvs phi_add_incoming(phi, it.v, it.b);
    q: Simplify_Query;
    sv := simplify_instruction(phi, q);
    if sv != NONE {
        erase_inst(phi);
        return sv;
    }
    dl: Md_Id = NONE;
    fnp := block_first_non_phi(bb);
    if fnp != NONE dl = get_metadata(fnp, 0);
    set_metadata(phi, 0, dl);
    if s.inserted_phis array_add(s.inserted_phis, phi);
    return phi;
}

ssa_equivalent_phi :: (phi: Value_Id, pvs: [] $T) -> bool {
    // ValueMapping is a map built by insert: the first value for a block wins; its size counts distinct blocks
    distinct := 0;
    for a, i: pvs {
        dup := false;
        for j: 0..i-1 if pvs[j].b == a.b { dup = true; break; }
        if !dup distinct += 1;
    }
    n := nops(phi);
    if n != cast(u32) distinct return false;
    if n > 0 for k: 0..n-1 {
        b := phi_block(phi, k);
        mv: Value_Id = NONE;
        for pvs if it.b == b { mv = it.v; break; }
        if mv != op(phi, k) return false;
    }
    return true;
}

// LoadAndStorePromoter::run for SROA's BasicLoadAndStorePromoter (stores and the alloca are kept; the alloca acts
// as a store of undef of `zero_ty`)
load_and_store_promote :: (insts: [] Value_Id, s: *Ssa_Updater, zero_ty: Type_Id) {
    by_block: Table(Value_Id, [..] Value_Id); by_block.allocator = temp;
    for u: insts {
        bb := inst(u).parent;
        l := table_find_pointer(*by_block, bb);
        if !l { e: [..] Value_Id; e.allocator = temp; l = table_add(*by_block, bb, e); }
        array_add(l, u);
    }
    live_in: [..] Value_Id; live_in.allocator = temp;
    replaced: Table(Value_Id, Value_Id); replaced.allocator = temp;
    for u: insts {
        bb := inst(u).parent;
        uses := table_find_pointer(*by_block, bb);
        if uses.count == 0 continue;
        if uses.count == 1 {
            o := inst_op(u);
            if o == .STORE ssa_add_available(s, bb, op(u, 0));
            else if o == .ALLOCA ssa_add_available(s, bb, const_undef(zero_ty));
            else array_add(*live_in, u);
            uses.count = 0;
            continue;
        }
        has_store := false;
        for uses.* { o := inst_op(it); if o == .STORE || o == .ALLOCA { has_store = true; break; } }
        if !has_store {
            for uses.* array_add(*live_in, it);
            uses.count = 0;
            continue;
        }
        // sort by block order (comesBefore)
        for i: 1..uses.count-1 {
            x := uses.*[i]; j := i - 1;
            while j >= 0 && comes_before_in_block(x, uses.*[j]) { uses.*[j + 1] = uses.*[j]; j -= 1; }
            uses.*[j + 1] = x;
        }
        stored: Value_Id = NONE;
        for i: uses.* {
            o := inst_op(i);
            if o == .LOAD {
                if stored != NONE {
                    rauw_with_metadata(i, stored);
                    table_set(*replaced, i, stored);
                } else array_add(*live_in, i);
                continue;
            }
            if o == .STORE stored = op(i, 0);
            else if o == .ALLOCA stored = const_undef(zero_ty);
        }
        ssa_add_available(s, bb, stored);
        uses.count = 0;
    }
    for ld: live_in {
        nv := ssa_value_in_middle(s, inst(ld).parent);
        if nv == ld nv = const_poison(vtype(nv));
        rauw_with_metadata(ld, nv);
        table_set(*replaced, ld, nv);
    }
    for u: insts {
        o := inst_op(u);
        if o == .STORE || o == .ALLOCA continue;   // shouldDelete
        if has_uses(u) {
            found, nv := table_find(*replaced, u);
            assert(found, "not a replaced load?");
            while true {
                f2, nx := table_find(*replaced, nv);
                if !f2 break;
                nv = nx;
            }
            rauw_with_metadata(u, nv);
        }
        erase_inst_with_metadata(u);
    }
}
