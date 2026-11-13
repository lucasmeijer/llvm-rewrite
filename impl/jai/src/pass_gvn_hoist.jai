// GVNHoist: a port of llvm/lib/Transforms/Scalar/GVNHoist.cpp (InsnInfo / LoadInfo / StoreInfo / CallInfo,
// CHI args, computeInsertionPoints with the reverse IDF, insertCHI / fillRenameStack / fillChiArgs,
// findHoistableCandidates, checkSafety / safeToHoistLdSt / hasEHOnPath / hasEHOrLoadsOnPath / hasMemoryUse,
// hoist / makeGepOperandsAvailable / makeGepsAvailable / removeAndReplace / rauw / raMPHIuw, GVNHoistPass::run).
// Value numbers come from GVN's ValueTable (pass_gvn.jai, a `Gvn` with MemDep and no MemorySSA, like
// GVNPass::ValueTable with setMemDep), MemorySSA is updated with mssa_updater.jai.
//
// Order: the VN maps (DenseMap<pair<unsigned, uintptr_t>, ...>) are kept in insertion order; their iteration order
// does not reach the output (each VN's CHIs are contiguous and stable-sorted by VN). OutValue
// (DenseMap<BasicBlock *, ...>) is iterated in LLVM by block address, here in block creation order (value id); this
// decides the order of the hoisting list across hoist points. The rank()-sort of the VNs is not reproduced: it has
// no effect on the result (see above). Load VN keys use the type id where LLVM uses the Type pointer.

gh_opts: struct {
    max_hoisted: s64 = -1;           // -gvn-max-hoisted (read by nothing in GVNHoist.cpp 23.1.5)
    max_bbs_in_path: s64 = 4;        // -gvn-hoist-max-bbs
    max_depth_in_bb: s64 = 100;      // -gvn-hoist-max-depth
    max_chain_length: s64 = 10;      // -gvn-hoist-max-chain-length
};

gh_guess_address_order := false;   // -gvn-hoist-guess-address-order (ours): skip gh_check_address_order

// Ours, not LLVM's. The hoisting list of one computeInsertionPoints call is ordered across hoist points by the
// DenseMap<BasicBlock *> OutValue, i.e. by block address (here: creation order). hoist() checks operand availability
// at hoisting time ("The order in which hoistings are done may influence the availability of operands"), so when an
// instruction to hoist into one block uses (directly or through GEPs) an instruction to hoist into another block, the
// result can depend on the address order: fail loudly.
// Also, load VN keys are (VN of the pointer, Type *): two loads of different types from the same address hoisted
// into the same block are hoisted (and so ordered in it) in Type pointer order (typed_keys).
gh_check_address_order :: (hpl: [] Gh_Hoist_Point, typed_keys := false) {
    if gh_guess_address_order || hpl.count < 2 return;
    if typed_keys for p: 0..hpl.count - 1 for q: p + 1..hpl.count - 1 {
        if hpl[p].bb == hpl[q].bb && hpl[p].vn.a == hpl[q].vn.a && hpl[p].vn.b != hpl[q].vn.b
            fatal("gvn-hoist: loads of different types from one address are hoisted into one block in Type pointer order (heap layout); not reproducible (-gvn-hoist-guess-address-order guesses creation order)");
    }
    multi := false;
    for 1..hpl.count - 1 if hpl[it].bb != hpl[0].bb { multi = true; break; }
    if !multi return;
    owner: Table(Value_Id, s64); owner.allocator = temp;
    for hp, idx: hpl for hp.insts table_set(*owner, it, idx);
    uses_other :: (v: Value_Id, bb: Value_Id, hpl: [] Gh_Hoist_Point, owner: *Table(Value_Id, s64), depth: s64) -> bool {
        for o: 0..cast(s64) nops(v) - 1 {
            x := op(v, cast(u32) o);
            if !is_inst(x) continue;
            found, e := table_find(owner, x);
            if found && hpl[e].bb != bb return true;
            if inst_op(x) == .GEP && depth < 64 && uses_other(x, bb, hpl, owner, depth + 1) return true;
        }
        return false;
    }
    for hp: hpl for i: hp.insts if uses_other(i, hp.bb, hpl, *owner, 0)
        fatal("gvn-hoist: the order of hoistings into different blocks (LLVM: block address order) decides operand availability; not reproducible (-gvn-hoist-guess-address-order guesses creation order)");
}

gvn_hoist_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    p :: (name: string, value: string, has_value: bool, dst: *s64) -> bool {
        if !has_value fatal(tprint("opt: -% needs a value", name));
        v, ok := string_to_int(value);
        if !ok fatal(tprint("opt: invalid value '%' for -%", value, name));
        dst.* = v;
        return true;
    }
    if name == "gvn-max-hoisted" return p(name, value, has_value, *gh_opts.max_hoisted);
    if name == "gvn-hoist-max-bbs" return p(name, value, has_value, *gh_opts.max_bbs_in_path);
    if name == "gvn-hoist-max-depth" return p(name, value, has_value, *gh_opts.max_depth_in_bb);
    if name == "gvn-hoist-max-chain-length" return p(name, value, has_value, *gh_opts.max_chain_length);
    if name == "gvn-hoist-guess-address-order" { gh_guess_address_order = true; return true; }
    return false;
}

GH_INVALID_VN :: 0xFFFF_FFFF_FFFF_FFFD;   // ~(uintptr_t)2

Gh_Vn :: struct { a: u32; b: u64; }
gh_vn_less :: (x: Gh_Vn, y: Gh_Vn) -> bool { if x.a != y.a return x.a < y.a; return x.b < y.b; }
gh_vn_eq :: (x: Gh_Vn, y: Gh_Vn) -> bool { return x.a == y.a && x.b == y.b; }
gh_vn_key :: (x: Gh_Vn) -> string { k: Key; k.buf.allocator = temp; key_u32(*k, x.a); key_u64(*k, x.b); return key_view(*k); }

// VNtoInsns, in insertion order
Gh_Vn_Map :: struct {
    index: Table(string, s64);
    keys: [..] Gh_Vn;
    lists: [..] [..] Value_Id;
}
gh_map_add :: (m: *Gh_Vn_Map, vn: Gh_Vn, i: Value_Id) {
    if m.keys.allocator.proc == null { m.index.allocator = temp; m.keys.allocator = temp; m.lists.allocator = temp; }
    s := gh_vn_key(vn);
    found, k := table_find(*m.index, s);
    if !found {
        k = m.keys.count;
        table_set(*m.index, copy_string(s,, allocator = temp), k);
        array_add(*m.keys, vn);
        l: [..] Value_Id; l.allocator = temp;
        array_add(*m.lists, l);
    }
    array_add(*m.lists[k], i);
}

Gh_Chi :: struct { vn: Gh_Vn; dest: Value_Id = NONE; i: Value_Id = NONE; }

Gh_Hoist_Point :: struct { bb: Value_Id; insts: [..] Value_Id; vn: Gh_Vn; }

Gh_Kind :: enum u8 { UNKNOWN; SCALAR; LOAD; STORE; }

Gvn_Hoist :: struct {
    f: Value_Id;
    gvn: *Gvn;          // the ValueTable (and its DT / AA / MemDep)
    dt: *Dom_Tree;
    pdt: *Dom_Tree;
    aar: Aa_Results;
    md: *Mem_Dep_Results;
    m: *Memory_SSA;
    mssau: Mssa_Updater;
    dfs_number: Table(Value_Id, u32);
    bb_side_effects: Table(Value_Id, bool);
    hoist_barrier: Table(Value_Id, bool);
    num_func_args: u32;
}

gh_dfs :: (g: *Gvn_Hoist, v: Value_Id) -> u32 { found, n := table_find(*g.dfs_number, v); if found return n; return 0; }
// firstInBB
gh_first_in_bb :: (g: *Gvn_Hoist, i1: Value_Id, i2: Value_Id) -> bool { return gh_dfs(g, i1) < gh_dfs(g, i2); }

// hasEH
gh_has_eh :: (g: *Gvn_Hoist, bb: Value_Id) -> bool {
    found, r := table_find(*g.bb_side_effects, bb);
    if found return r;
    if block_is_eh_pad(bb) || block_has_address_taken(bb) { table_set(*g.bb_side_effects, bb, true); return true; }
    if may_throw(block_terminator(bb)) { table_set(*g.bb_side_effects, bb, true); return true; }
    table_set(*g.bb_side_effects, bb, false);
    return false;
}

// hasMemoryUse
gh_has_memory_use :: (g: *Gvn_Hoist, new_pt: Value_Id, def: s32, bb: Value_Id) -> bool {
    m := g.m;
    a := mssa_first_access(m, bb);
    if a < 0 return false;
    old_pt := ma_inst(m, def);
    old_bb := inst_block(old_pt);
    new_bb := inst_block(new_pt);
    reached_new_pt := false;
    while a >= 0 {
        defer a = m.acc[a].next;
        if !ma_is_use(m, a) continue;
        insn := ma_inst(m, a);
        if bb == old_bb && gh_first_in_bb(g, old_pt, insn) break;
        if bb == new_bb {
            if !reached_new_pt {
                if gh_first_in_bb(g, insn, new_pt) continue;
                reached_new_pt = true;
            }
        }
        if mssa_def_clobbers_use_or_def(m, aa_query_new(*g.aar), def, a) return true;
    }
    return false;
}

// hasEHhelper
gh_has_eh_helper :: (g: *Gvn_Hoist, bb: Value_Id, src_bb: Value_Id, nbbs: *s64) -> bool {
    if nbbs.* == 0 return true;
    if gh_has_eh(g, bb) return true;
    if bb != src_bb && table_contains(*g.hoist_barrier, bb) return true;
    return false;
}

// idf_begin(BB) .. idf_end: inverse depth-first walk; `visit` returns 0 to continue, 1 to skip the node's children,
// 2 to stop with true
Gh_Idf :: struct {
    stack: [..] struct { n: Value_Id; preds: [..] Value_Id; k: s64; started: bool; };
    visited: Table(Value_Id, bool);
}
gh_idf_init :: (w: *Gh_Idf, start: Value_Id) {
    w.stack.allocator = temp; w.visited.allocator = temp;
    e: type_of(w.stack[0]); e.n = start; e.preds.allocator = temp;
    array_add(*w.stack, e);
    table_set(*w.visited, start, true);
}
gh_idf_current :: (w: *Gh_Idf) -> Value_Id { if w.stack.count == 0 return NONE; return w.stack[w.stack.count - 1].n; }
// df_iterator::toNext
gh_idf_to_next :: (w: *Gh_Idf) {
    while w.stack.count {
        top := *w.stack[w.stack.count - 1];
        if !top.started { top.started = true; block_predecessors(top.n, *top.preds); top.k = 0; }
        while top.k < top.preds.count {
            nx := top.preds[top.k];
            top.k += 1;
            if !table_contains(*w.visited, nx) {
                table_set(*w.visited, nx, true);
                e: type_of(w.stack[0]); e.n = nx; e.preds.allocator = temp;
                array_add(*w.stack, e);
                return;
            }
        }
        w.stack.count -= 1;
    }
}
gh_idf_skip_children :: (w: *Gh_Idf) {
    w.stack.count -= 1;
    if w.stack.count gh_idf_to_next(w);
}

// hasEHOrLoadsOnPath
gh_has_eh_or_loads_on_path :: (g: *Gvn_Hoist, new_pt: Value_Id, def: s32, nbbs: *s64) -> bool {
    new_bb := inst_block(new_pt);
    old_bb := ma_block(g.m, def);
    w: Gh_Idf;
    gh_idf_init(*w, old_bb);
    while w.stack.count {
        bb := gh_idf_current(*w);
        if bb == new_bb { gh_idf_skip_children(*w); continue; }
        if gh_has_eh_helper(g, bb, old_bb, nbbs) return true;
        if gh_has_memory_use(g, new_pt, def, bb) return true;
        if nbbs.* != -1 nbbs.* -= 1;
        gh_idf_to_next(*w);
    }
    return false;
}

// hasEHOnPath
gh_has_eh_on_path :: (g: *Gvn_Hoist, hoist_pt: Value_Id, src_bb: Value_Id, nbbs: *s64) -> bool {
    w: Gh_Idf;
    gh_idf_init(*w, src_bb);
    while w.stack.count {
        bb := gh_idf_current(*w);
        if bb == hoist_pt { gh_idf_skip_children(*w); continue; }
        if gh_has_eh_helper(g, bb, src_bb, nbbs) return true;
        if nbbs.* != -1 nbbs.* -= 1;
        gh_idf_to_next(*w);
    }
    return false;
}

// safeToHoistLdSt
gh_safe_to_hoist_ld_st :: (g: *Gvn_Hoist, new_pt: Value_Id, old_pt: Value_Id, u: s32, k: Gh_Kind, nbbs: *s64) -> bool {
    if new_pt == old_pt return true;
    m := g.m;
    new_bb := inst_block(new_pt);
    old_bb := inst_block(old_pt);
    d := ma_defining(m, u);
    dbb := ma_block(m, d);
    if dt_properly_dominates(g.dt, new_bb, dbb) return false;
    if new_bb == dbb && !is_live_on_entry(d) && !ma_is_phi(m, d) {
        if !gh_first_in_bb(g, ma_inst(m, d), new_pt) return false;
    }
    if k == .STORE {
        if gh_has_eh_or_loads_on_path(g, new_pt, u, nbbs) return false;
    } else if gh_has_eh_on_path(g, new_bb, old_bb, nbbs) return false;
    return true;
}

// valueAnticipable
gh_value_anticipable :: (c: [] Gh_Chi, ti: Value_Id) -> bool {
    if num_successors(ti) > c.count return false;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(inst_block(ti), *succs);
    for chi: c {
        found := false;
        for succs if it == chi.dest { found = true; break; }
        if !found return false;
    }
    return true;
}

// checkSafety
gh_check_safety :: (g: *Gvn_Hoist, c: [] Gh_Chi, bb: Value_Id, k: Gh_Kind, safe: *[..] Gh_Chi) {
    nbbs := gh_opts.max_bbs_in_path;
    t := block_terminator(bb);
    for chi: c {
        insn := chi.i;
        if insn == NONE continue;
        if has_uses(t) {
            uses_t := false;
            for o: 0..cast(s64) nops(insn) - 1 if op(insn, cast(u32) o) == t { uses_t = true; break; }
            if uses_t continue;
        }
        if k == .SCALAR {
            if !gh_has_eh_on_path(g, bb, inst_block(insn), *nbbs) array_add(safe, chi);
        } else {
            ud := mssa_access_of(g.m, insn);
            if ud >= 0 && gh_safe_to_hoist_ld_st(g, t, insn, ud, k, *nbbs) array_add(safe, chi);
        }
    }
}

// OutValuesType
Gh_Out :: struct { index: Table(Value_Id, s64); blocks: [..] Value_Id; chis: [..] [..] Gh_Chi; }
gh_out_list :: (o: *Gh_Out, bb: Value_Id) -> *[..] Gh_Chi {
    found, k := table_find(*o.index, bb);
    if !found {
        k = o.blocks.count;
        table_set(*o.index, bb, k);
        array_add(*o.blocks, bb);
        l: [..] Gh_Chi; l.allocator = temp;
        array_add(*o.chis, l);
    }
    return *o.chis[k];
}

Gh_In_Item :: struct { vn: Gh_Vn; i: Value_Id; }

// computeInsertionPoints
gh_compute_insertion_points :: (g: *Gvn_Hoist, mp: *Gh_Vn_Map, hpl: *[..] Gh_Hoist_Point, k: Gh_Kind) {
    out: Gh_Out; out.index.allocator = temp; out.blocks.allocator = temp; out.chis.allocator = temp;
    in_values: Table(Value_Id, [..] Gh_In_Item); in_values.allocator = temp;
    for vn, ri: mp.keys {
        v := mp.lists[ri];
        if v.count < 2 continue;
        vn_blocks: [..] Value_Id; vn_blocks.allocator = temp;
        vn_set: Table(Value_Id, bool); vn_set.allocator = temp;
        for i: v {
            bbi := inst_block(i);
            if !gh_has_eh(g, bbi) && !table_contains(*vn_set, bbi) { table_set(*vn_set, bbi, true); array_add(*vn_blocks, bbi); }
        }
        idf_blocks: [..] Value_Id; idf_blocks.allocator = temp;
        idf_calculate(g.pdt, vn_blocks, *vn_set, null, *idf_blocks);
        for i: v {
            p := table_find_pointer(*in_values, inst_block(i));
            if !p { blank: [..] Gh_In_Item; blank.allocator = temp; p = table_set(*in_values, inst_block(i), blank); }
            array_add(p, .{vn, i});
        }
        for idfbb: idf_blocks {
            for i: v {
                if dt_properly_dominates(g.dt, idfbb, inst_block(i)) {
                    l := gh_out_list(*out, idfbb);
                    e: Gh_Chi; e.vn = vn;
                    array_add(l, e);
                }
            }
        }
    }
    // insertCHI: depth-first walk of the post-dominator tree from the virtual root
    pdt := g.pdt;
    root := dt_node(pdt, NONE);
    if root >= 0 {
        Frame :: struct { n: s32; c: s32; }
        fs: [..] Frame; fs.allocator = temp;
        order: [..] s32; order.allocator = temp;
        array_add(*order, root);
        array_add(*fs, .{root, pdt.nodes[root].first_child});
        while fs.count {
            top := *fs[fs.count - 1];
            if top.c < 0 { fs.count -= 1; continue; }
            c := top.c;
            top.c = pdt.nodes[c].sibling;
            array_add(*order, c);
            array_add(*fs, .{c, pdt.nodes[c].first_child});
        }
        for nd: order {
            bb := pdt.nodes[nd].block;
            if bb == NONE continue;
            // fillRenameStack
            rename: Table(string, [..] Value_Id); rename.allocator = temp;
            p := table_find_pointer(*in_values, bb);
            if p {
                for < item: p.* {
                    s := gh_vn_key(item.vn);
                    st := table_find_pointer(*rename, s);
                    if !st { blank: [..] Value_Id; blank.allocator = temp; st = table_set(*rename, copy_string(s,, allocator = temp), blank); }
                    array_add(st, item.i);
                }
            }
            // fillChiArgs
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(bb, *preds);
            for pred: preds {
                found, pk := table_find(*out.index, pred);
                if !found continue;
                vchi := *out.chis[pk];
                it := 0;
                while it < vchi.count {
                    c := *vchi.*[it];
                    if c.dest == NONE {
                        si := table_find_pointer(*rename, gh_vn_key(c.vn));
                        if si && si.count && dt_properly_dominates(g.dt, pred, inst_block(si.*[si.count - 1])) {
                            c.dest = bb;
                            c.i = pop(si);
                        }
                        cur := c.vn;
                        while it < vchi.count && gh_vn_eq(vchi.*[it].vn, cur) it += 1;
                    } else it += 1;
                }
            }
        }
    }
    // findHoistableCandidates, blocks in creation order (LLVM: DenseMap<BasicBlock *> order)
    blocks: [..] Value_Id; blocks.allocator = temp;
    for out.blocks array_add(*blocks, it);
    for a: 1..blocks.count - 1 {
        x := blocks[a]; b := a - 1;
        while b >= 0 && blocks[b] > x { blocks[b + 1] = blocks[b]; b -= 1; }
        blocks[b + 1] = x;
    }
    for bb: blocks {
        _, ck := table_find(*out.index, bb);
        chis := *out.chis[ck];
        // stable_sort by VN
        for a: 1..chis.count - 1 {
            x := chis.*[a]; b := a - 1;
            while b >= 0 && gh_vn_less(x.vn, chis.*[b].vn) { chis.*[b + 1] = chis.*[b]; b -= 1; }
            chis.*[b + 1] = x;
        }
        ti := block_terminator(bb);
        prev := 0;
        while prev < chis.count {
            nxt := prev;
            while nxt < chis.count && gh_vn_eq(chis.*[nxt].vn, chis.*[prev].vn) nxt += 1;
            range: [] Gh_Chi; range.data = chis.data + prev; range.count = nxt - prev;
            safe: [..] Gh_Chi; safe.allocator = temp;
            gh_check_safety(g, range, bb, k, *safe);
            if gh_value_anticipable(safe, ti) {
                hp: Gh_Hoist_Point; hp.bb = bb; hp.insts.allocator = temp; hp.vn = chis.*[prev].vn;
                for safe array_add(*hp.insts, it.i);
                array_add(hpl, hp);
            }
            prev = nxt;
        }
    }
}

// allOperandsAvailable
gh_all_operands_available :: (g: *Gvn_Hoist, i: Value_Id, hoist_pt: Value_Id) -> bool {
    for o: 0..cast(s64) nops(i) - 1 {
        x := op(i, cast(u32) o);
        if is_inst(x) && !dt_dominates(g.dt, inst_block(x), hoist_pt) return false;
    }
    return true;
}
// allGepOperandsAvailable
gh_all_gep_operands_available :: (g: *Gvn_Hoist, i: Value_Id, hoist_pt: Value_Id) -> bool {
    for o: 0..cast(s64) nops(i) - 1 {
        x := op(i, cast(u32) o);
        if is_inst(x) && !dt_dominates(g.dt, inst_block(x), hoist_pt) {
            if inst_op(x) == .GEP {
                if !gh_all_gep_operands_available(g, x, hoist_pt) return false;
            } else return false;
        }
    }
    return true;
}

// makeGepsAvailable
gh_make_geps_available :: (g: *Gvn_Hoist, repl: Value_Id, hoist_pt: Value_Id, to_hoist: [] Value_Id, gep: Value_Id) {
    cloned := ic_clone_inst(gep);
    for o: 0..cast(s64) nops(gep) - 1 {
        x := op(gep, cast(u32) o);
        if !is_inst(x) continue;
        if dt_dominates(g.dt, inst_block(x), hoist_pt) continue;
        if inst_op(x) == .GEP gh_make_geps_available(g, cloned, hoist_pt, to_hoist, x);
    }
    insert_at_position(cloned, hoist_pt, block_terminator(hoist_pt), false);
    drop_unknown_non_debug_metadata(cloned, .[]);
    for other: to_hoist {
        other_gep := ifx inst_op(other) == .LOAD then op(other, 0) else op(other, 1);
        and_ir_flags(cloned, other_gep);
        if other_gep != gep apply_merged_location(cloned, get_metadata(cloned, MDK_DBG), get_metadata(other_gep, MDK_DBG));
    }
    replace_uses_of_with(repl, gep, cloned);
}

// updateAlignment
gh_update_alignment :: (i: Value_Id, repl: Value_Id) {
    o := inst_op(repl);
    if o == .LOAD || o == .STORE {
        inst(repl).align = min(inst(repl).align, inst(i).align);
    } else if o == .ALLOCA {
        inst(repl).align = max(inst(repl).align, inst(i).align);
    }
}

// rauw
gh_rauw :: (g: *Gvn_Hoist, candidates: [] Value_Id, repl: Value_Id, new_mem_acc: s32) -> u32 {
    nr: u32 = 0;
    for i: candidates {
        if i == repl continue;
        nr += 1;
        gh_update_alignment(i, repl);
        if new_mem_acc >= 0 {
            old := mssa_access_of(g.m, i);
            ma_rauw(g.m, old, new_mem_acc);
            mssau_remove_memory_access(*g.mssau, old);
        }
        combine_metadata_for_cse(repl, i, true);
        and_ir_flags(repl, i);
        rauw_with_metadata(i, repl);
        md_remove_instruction(g.md, i);
        erase_inst_with_metadata(i);
    }
    return nr;
}

// raMPHIuw
gh_ra_mphi_uw :: (g: *Gvn_Hoist, new_mem_acc: s32) {
    m := g.m;
    phis: [..] s32; phis.allocator = temp;
    u := m.acc[new_mem_acc].first_use;
    while u >= 0 {
        usr := m.uses[u].user;
        if ma_is_phi(m, usr) {
            dup := false;
            for phis if it == usr { dup = true; break; }
            if !dup array_add(*phis, usr);
        }
        u = m.uses[u].next;
    }
    for phi: phis {
        all := true;
        for k: 0..cast(s64) ma_nops(m, phi) - 1 if mphi_value(m, phi, cast(u32) k) != new_mem_acc { all = false; break; }
        if all {
            ma_rauw(m, phi, new_mem_acc);
            mssau_remove_memory_access(*g.mssau, phi);
        }
    }
}

// removeAndReplace
gh_remove_and_replace :: (g: *Gvn_Hoist, candidates: [] Value_Id, repl: Value_Id, dest_bb: Value_Id, move_access: bool) -> u32 {
    new_mem_acc := mssa_access_of(g.m, repl);
    if move_access && new_mem_acc >= 0 mssau_move_to_place(*g.mssau, new_mem_acc, dest_bb, .BEFORE_TERMINATOR);
    nr := gh_rauw(g, candidates, repl, new_mem_acc);
    if new_mem_acc >= 0 gh_ra_mphi_uw(g, new_mem_acc);
    return nr;
}

// makeGepOperandsAvailable
gh_make_gep_operands_available :: (g: *Gvn_Hoist, repl: Value_Id, hoist_pt: Value_Id, to_hoist: [] Value_Id) -> bool {
    gep: Value_Id = NONE;
    val: Value_Id = NONE;
    if inst_op(repl) == .LOAD {
        p := op(repl, 0);
        if is_inst(p) && inst_op(p) == .GEP gep = p;
    } else if inst_op(repl) == .STORE {
        p := op(repl, 1);
        if is_inst(p) && inst_op(p) == .GEP gep = p;
        v := op(repl, 0);
        if is_inst(v) {
            val = v;
            if inst_op(val) == .GEP {
                if !gh_all_gep_operands_available(g, val, hoist_pt) return false;
            } else if !dt_dominates(g.dt, inst_block(val), hoist_pt) return false;
        }
    }
    if gep == NONE || !gh_all_gep_operands_available(g, gep, hoist_pt) return false;
    gh_make_geps_available(g, repl, hoist_pt, to_hoist, gep);
    if val != NONE && inst_op(val) == .GEP gh_make_geps_available(g, repl, hoist_pt, to_hoist, val);
    return true;
}

// hoist
gh_hoist :: (g: *Gvn_Hoist, hpl: [] Gh_Hoist_Point) -> (u32, u32) {
    ni: u32 = 0; nl: u32 = 0; ns: u32 = 0; nc: u32 = 0;
    for *hp: hpl {
        dest_bb := hp.bb;
        to_hoist := hp.insts;
        repl: Value_Id = NONE;
        for i: to_hoist {
            if inst_block(i) == dest_bb {
                if repl == NONE || gh_first_in_bb(g, i, repl) repl = i;
            }
        }
        move_access := true;
        if repl != NONE {
            move_access = false;
        } else {
            repl = to_hoist[0];
            if !gh_all_operands_available(g, repl, dest_bb) {
                if !gh_make_gep_operands_available(g, repl, dest_bb, to_hoist) continue;
            }
            last := block_terminator(dest_bb);
            md_remove_instruction(g.md, repl);
            inst_move_before_dbg(repl, last);
            p := table_find_pointer(*g.dfs_number, last);
            if !p p = table_set(*g.dfs_number, last, 0);
            table_set(*g.dfs_number, repl, p.*);
            p = table_find_pointer(*g.dfs_number, last);
            p.* += 1;
        }
        drop_location(repl);
        gh_remove_and_replace(g, to_hoist, repl, dest_bb, move_access);
        o := inst_op(repl);
        if o == .LOAD nl += 1;
        else if o == .STORE ns += 1;
        else if o == .CALL nc += 1;
        else ni += 1;
    }
    return ni, nl + nc + ns;
}

// hoistExpressions
gh_hoist_expressions :: (g: *Gvn_Hoist) -> (u32, u32) {
    ii: Gh_Vn_Map; li: Gh_Vn_Map; si: Gh_Vn_Map;
    ci_scalars: Gh_Vn_Map; ci_loads: Gh_Vn_Map; ci_stores: Gh_Vn_Map;
    for bb: gh_depth_first_blocks(g.f) {
        n := 0;
        for i1: block_insts(bb) {
            if !is_guaranteed_to_transfer_execution(i1) { table_set(*g.hoist_barrier, bb, true); break; }
            if gh_opts.max_depth_in_bb != -1 { if n >= gh_opts.max_depth_in_bb break; n += 1; }
            if is_terminator(inst_op(i1)) break;
            o := inst_op(i1);
            if o == .LOAD {
                if load_is_simple(i1) {
                    v := gvn_lookup_or_add(g.gvn, op(i1, 0));
                    gh_map_add(*li, .{v, cast(u64) vtype(i1)}, i1);
                }
            } else if o == .STORE {
                if ng_store_is_simple(i1) {
                    pv := gvn_lookup_or_add(g.gvn, op(i1, 1));
                    vv := gvn_lookup_or_add(g.gvn, op(i1, 0));
                    gh_map_add(*si, .{pv, cast(u64) vv}, i1);
                }
            } else if o == .CALL {
                id := call_iid(i1);
                if id == IID_ASSUME || id == IID_SIDEEFFECT continue;
                if may_have_side_effects(i1) break;
                if call_is_convergent(i1) break;
                v := gvn_lookup_or_add(g.gvn, i1);
                key := Gh_Vn.{v, GH_INVALID_VN};
                me := call_memory_effects(i1);
                if mem_does_not_access(me) gh_map_add(*ci_scalars, key, i1);
                else if mem_only_reads(me) gh_map_add(*ci_loads, key, i1);
                else gh_map_add(*ci_stores, key, i1);
            } else if o != .GEP {
                v := gvn_lookup_or_add(g.gvn, i1);
                gh_map_add(*ii, .{v, GH_INVALID_VN}, i1);
            }
        }
    }
    hpl: [..] Gh_Hoist_Point; hpl.allocator = temp;
    seg := 0;
    gh_compute_insertion_points(g, *ii, *hpl, .SCALAR);  gh_check_address_order(array_view(hpl, seg, hpl.count - seg)); seg = hpl.count;
    gh_compute_insertion_points(g, *li, *hpl, .LOAD);    gh_check_address_order(array_view(hpl, seg, hpl.count - seg), typed_keys = true); seg = hpl.count;
    gh_compute_insertion_points(g, *si, *hpl, .STORE);   gh_check_address_order(array_view(hpl, seg, hpl.count - seg)); seg = hpl.count;
    gh_compute_insertion_points(g, *ci_scalars, *hpl, .SCALAR); gh_check_address_order(array_view(hpl, seg, hpl.count - seg)); seg = hpl.count;
    gh_compute_insertion_points(g, *ci_loads, *hpl, .LOAD);     gh_check_address_order(array_view(hpl, seg, hpl.count - seg)); seg = hpl.count;
    gh_compute_insertion_points(g, *ci_stores, *hpl, .STORE);   gh_check_address_order(array_view(hpl, seg, hpl.count - seg));
    a, b := gh_hoist(g, hpl);
    return a, b;
}

// depth_first(&F.getEntryBlock()): preorder over successors
gh_depth_first_blocks :: (f: Value_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    Frame :: struct { b: Value_Id; succs: [..] Value_Id; k: s64; }
    fs: [..] Frame; fs.allocator = temp;
    push :: (fs: *[..] Frame, out: *[..] Value_Id, visited: *Table(Value_Id, bool), b: Value_Id) {
        table_set(visited, b, true);
        array_add(out, b);
        fr: Frame; fr.b = b; fr.succs.allocator = temp;
        block_successors(b, *fr.succs);
        array_add(fs, fr);
    }
    push(*fs, *out, *visited, fn_entry(f));
    while fs.count {
        top := *fs[fs.count - 1];
        if top.k >= top.succs.count { fs.count -= 1; continue; }
        s := top.succs[top.k];
        top.k += 1;
        if !table_contains(*visited, s) push(*fs, *out, *visited, s);
    }
    return out;
}

gvn_hoist_run :: (f: Value_Id) -> Preserved {
    g := New(Gvn_Hoist,, allocator = temp);
    g.f = f;
    g.dfs_number.allocator = temp; g.bb_side_effects.allocator = temp; g.hoist_barrier.allocator = temp;
    g.dt = get_domtree(f);
    g.pdt = get_postdomtree(f);
    g.aar = aa_results_for(f);
    ac := get_assumption_cache(f);
    g.md = md_new(f, g.aar, ac, g.dt);
    g.m = get_memoryssa(f);
    g.mssau.mssa = g.m;
    mssa_ensure_optimized_uses(g.m);
    // GVNPass::ValueTable with setDomTree / setAliasAnalysis / setMemDep
    gv := New(Gvn,, allocator = temp);
    gv.f = f; gv.dt = g.dt; gv.aar = g.aar; gv.md = g.md; gv.ac = ac;
    gv.vn_md_enabled = true;
    vt := *gv.vn;
    vt.value_numbering.allocator = temp; vt.expr_heads.allocator = temp; vt.expr_entries.allocator = temp;
    vt.expressions.allocator = temp; vt.expr_idx.allocator = temp; vt.numbering_phi.allocator = temp;
    vt.numbering_bb.allocator = temp; vt.phi_translate_table.allocator = temp;
    g.gvn = gv;
    g.num_func_args = func_nparams(glob(f).value_type);
    res := false;
    bbi: u32 = 0;
    for bb: gh_depth_first_blocks(f) {
        bbi += 1;
        table_set(*g.dfs_number, bb, bbi);
        n: u32 = 0;
        for i: block_insts(bb) { n += 1; table_set(*g.dfs_number, i, n); }
    }
    chain_length: s64 = 0;
    while true {
        chain_length += 1;
        if gh_opts.max_chain_length != -1 && chain_length >= gh_opts.max_chain_length break;
        a, b := gh_hoist_expressions(g);
        if a + b == 0 break;
        if b > 0 gvn_vt_clear(vt);
        res = true;
    }
    if !res return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .MEMORYSSA);
    return pa;
}
