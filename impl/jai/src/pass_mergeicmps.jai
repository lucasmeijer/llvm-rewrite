// MergeICmps: a port of llvm/lib/Transforms/Scalar/MergeICmps.cpp (BCEAtom, BCECmpBlock, BCECmpChain, processPhi)
// with getDisjunctionWeights / fitWeights (llvm/include/llvm/IR/ProfDataUtils.h, lib/IR/ProfDataUtils.cpp) and
// DominatorTree::setNewRoot.

Mic_Atom :: struct {
    gep: Value_Id = NONE;
    load: Value_Id = NONE;
    base_id: s32;          // 0 = invalid
    offset: APInt;
}
// BCEAtom::operator<
mic_atom_less :: (a: Mic_Atom, b: Mic_Atom) -> bool {
    if a.base_id != b.base_id return a.base_id < b.base_id;
    return ap_slt(a.offset, b.offset);
}

Mic_Block :: struct {
    lhs: Mic_Atom;
    rhs: Mic_Atom;
    size_bits: s64;
    cmp: Value_Id;
    bb: Value_Id;
    insts: [..] Value_Id;   // BlockInsts
    require_split: bool;
    orig_order: u32;
}

Mic_Base_Ids :: struct {
    order: s32 = 1;
    ids: Table(Value_Id, s32);
}
mic_get_base_id :: (b: *Mic_Base_Ids, v: Value_Id) -> s32 {
    found, id := table_find(*b.ids, v);
    if found return id;
    id = b.order;
    table_set(*b.ids, v, id);
    b.order += 1;
    return id;
}

// visitICmpLoadOperand
mic_visit_icmp_load_operand :: (v: Value_Id, b: *Mic_Base_Ids) -> Mic_Atom {
    r: Mic_Atom;
    if !is_inst(v) || inst_op(v) != .LOAD return r;
    if is_used_outside_of_block(v, inst_block(v)) return r;
    if !load_is_simple(v) return r;
    addr := op(v, 0);
    if type_addrspace(vtype(addr)) != 0 return r;
    if !dl_type_size_equals_store_size(vtype(v)) return r;
    offset := ap_zero(dl_index_type_size_bits(vtype(addr)));
    base := addr;
    gep: Value_Id = NONE;
    if is_inst(addr) && inst_op(addr) == .GEP {
        gep = addr;
        if is_used_outside_of_block(gep, inst_block(v)) return r;
        ok, o := gep_accumulate_constant_offset(gep, offset);
        if !ok return r;
        offset = o;
        base = op(gep, 0);
    }
    r.gep = gep; r.load = v; r.base_id = mic_get_base_id(b, base); r.offset = offset;
    return r;
}

mic_block_contains :: (blk: *Mic_Block, i: Value_Id) -> bool { return block_set_contains(blk.insts, i); }

// canSinkBCECmpInst
mic_can_sink_bce_cmp_inst :: (blk: *Mic_Block, i: Value_Id, aar: *Aa_Results) -> bool {
    if may_write_to_memory(i) {
        may_clobber :: (i: Value_Id, li: Value_Id, aar: *Aa_Results) -> bool {
            if !(inst_block(i) != inst_block(li) || !comes_before(i, li)) return false;
            return (aa_mod_ref_inst_loc(aa_query_new(aar), i, mloc_get(li)) & MR_MOD) != 0;
        }
        if may_clobber(i, blk.lhs.load, aar) || may_clobber(i, blk.rhs.load, aar) return false;
    }
    n := nops(i);
    if n > 0 for k: 0..n - 1 {
        o := op(i, k);
        if is_inst(o) && mic_block_contains(blk, o) return false;
    }
    return true;
}
// split
mic_split :: (blk: *Mic_Block, new_parent: Value_Id) {
    others: [..] Value_Id; others.allocator = temp;
    for i: block_insts(blk.bb) if !mic_block_contains(blk, i) array_add(*others, i);
    k := others.count - 1;
    while k >= 0 {
        i := others[k];
        first := block(new_parent).first;
        inst_unlink(i);   // moveBeforePreserving: the records move with the instruction
        if first == NONE block_append_inst(new_parent, i); else inst_insert_before(i, first);
        k -= 1;
    }
}
// canSplit: (ok, SplitAt)
mic_can_split :: (blk: *Mic_Block, aar: *Aa_Results) -> (bool, Value_Id) {
    split_at: Value_Id = NONE;
    for i: block_insts(blk.bb) {
        if !mic_block_contains(blk, i) {
            split_at = inst(i).next;
            if !mic_can_sink_bce_cmp_inst(blk, i, aar) return false, split_at;
        }
    }
    return true, split_at;
}
mic_does_other_work :: (blk: *Mic_Block) -> bool {
    for i: block_insts(blk.bb) if !mic_block_contains(blk, i) return true;
    return false;
}

// visitICmp + visitCmpBlock
mic_visit_cmp_block :: (val: Value_Id, bb: Value_Id, phi_bb: Value_Id, b: *Mic_Base_Ids) -> (bool, Mic_Block) {
    r: Mic_Block;
    if block(bb).first == NONE return false, r;
    term := block_terminator(bb);
    cond: Value_Id;
    expected: u8;
    if inst_op(term) == .BR {
        cond = val; expected = ICMP_EQ;
    } else if inst_op(term) == .CONDBR {
        if !is_null_value(val) return false, r;
        false_bb := get_successor(term, 1);
        cond = op(term, 0);
        expected = cast(u8) ifx false_bb == phi_bb then ICMP_EQ else ICMP_NE;
    } else return false, r;
    if !is_inst(cond) || inst_op(cond) != .ICMP return false, r;
    // visitICmp
    if !has_one_use(cond) return false, r;
    if inst(cond).pred != expected return false, r;
    lhs := mic_visit_icmp_load_operand(op(cond, 0), b);
    if lhs.base_id == 0 return false, r;
    rhs := mic_visit_icmp_load_operand(op(cond, 1), b);
    if rhs.base_id == 0 return false, r;
    r.lhs = lhs; r.rhs = rhs;
    if mic_atom_less(r.rhs, r.lhs) { t := r.lhs; r.lhs = r.rhs; r.rhs = t; }   // BCECmp: smallest atom on the left
    r.size_bits = cast(s64) dl_type_size_bits(vtype(op(cond, 0)));
    r.cmp = cond;
    r.bb = bb;
    r.insts.allocator = temp;
    add :: (s: *[..] Value_Id, i: Value_Id) { if !block_set_contains(s.*, i) array_add(s, i); }
    add(*r.insts, r.lhs.load); add(*r.insts, r.rhs.load); add(*r.insts, cond); add(*r.insts, term);
    if r.lhs.gep != NONE add(*r.insts, r.lhs.gep);
    if r.rhs.gep != NONE add(*r.insts, r.rhs.gep);
    return true, r;
}

mic_are_contiguous :: (a: *Mic_Block, b: *Mic_Block) -> bool {
    return a.lhs.base_id == b.lhs.base_id && a.rhs.base_id == b.rhs.base_id &&
           ap_eq(ap_add(a.lhs.offset, ap_from_u64(a.lhs.offset.bits, cast(u64) (a.size_bits / 8))), b.lhs.offset) &&
           ap_eq(ap_add(a.rhs.offset, ap_from_u64(a.rhs.offset.bits, cast(u64) (a.size_bits / 8))), b.rhs.offset);
}

Mic_Chain :: struct {
    phi: Value_Id;
    merged: [..] [..] Mic_Block;   // MergedBlocks_
    entry_block: Value_Id = NONE;
    split_at: Value_Id = NONE;
}

// mergeBlocks
mic_merge_blocks :: (blocks: *[..] Mic_Block) -> [..] [..] Mic_Block {
    // llvm::sort by (Lhs, Rhs): std::sort is an insertion sort below 17 elements (stable); larger chains with equal
    // keys would depend on introsort
    less :: (a: *Mic_Block, b: *Mic_Block) -> bool {
        if mic_atom_less(a.lhs, b.lhs) return true;
        if mic_atom_less(b.lhs, a.lhs) return false;
        return mic_atom_less(a.rhs, b.rhs);
    }
    if blocks.count > 16 {
        for i: 0..blocks.count - 1 for j: i + 1..blocks.count - 1
            if !less(*blocks.*[i], *blocks.*[j]) && !less(*blocks.*[j], *blocks.*[i]) fatal("mergeicmps: sorting more than 16 comparisons with equal keys (std::sort introsort order) is not supported");
    }
    for i: 1..blocks.count - 1 {
        x := blocks.*[i];
        j := i - 1;
        while j >= 0 && less(*x, *blocks.*[j]) { blocks.*[j + 1] = blocks.*[j]; j -= 1; }
        blocks.*[j + 1] = x;
    }
    merged: [..] [..] Mic_Block; merged.allocator = temp;
    for blk: blocks.* {
        if merged.count == 0 || !mic_are_contiguous(*merged[merged.count - 1][merged[merged.count - 1].count - 1], *blk) {
            l: [..] Mic_Block; l.allocator = temp;
            array_add(*merged, l);
        }
        array_add(*merged[merged.count - 1], blk);
    }
    min_order :: (l: [..] Mic_Block) -> u32 { m: u32 = 0xFFFF_FFFF; for l m = min(m, it.orig_order); return m; }
    for i: 1..merged.count - 1 {
        x := merged[i];
        j := i - 1;
        while j >= 0 && min_order(x) < min_order(merged[j]) { merged[j + 1] = merged[j]; j -= 1; }
        merged[j + 1] = x;
    }
    return merged;
}

// BCECmpChain::BCECmpChain
mic_chain_build :: (c: *Mic_Chain, blocks: [] Value_Id, phi: Value_Id, aar: *Aa_Results) {
    c.phi = phi;
    c.merged.allocator = temp;
    comparisons: [..] Mic_Block; comparisons.allocator = temp;
    ids: Mic_Base_Ids; ids.ids.allocator = temp;
    for bb: blocks {
        if block_has_address_taken(bb) return;
        ok, cmp := mic_visit_cmp_block(phi_incoming_value_for_block(phi, bb), bb, inst_block(phi), *ids);
        if !ok return;
        if mic_does_other_work(*cmp) {
            if comparisons.count == 0 {
                can, at := mic_can_split(*cmp, aar);
                c.split_at = at;
                if can {
                    cmp.require_split = true;
                    cmp.orig_order = cast(u32) comparisons.count;
                    array_add(*comparisons, cmp);
                } else {
                    c.split_at = NONE;
                }
                continue;
            }
            return;
        }
        cmp.orig_order = cast(u32) comparisons.count;
        array_add(*comparisons, cmp);
    }
    if comparisons.count == 0 return;
    c.entry_block = comparisons[0].bb;
    c.merged = mic_merge_blocks(*comparisons);
}

mic_at_least_one_merged :: (c: *Mic_Chain) -> bool { for c.merged if it.count > 1 return true; return false; }

// isDereferenceable
mic_is_dereferenceable :: (c: *Mic_Chain) -> bool {
    cxt := ifx c.split_at != NONE then c.split_at else block(c.entry_block).first;
    for blocks: c.merged {
        lowest := *blocks[0];
        l := op(lowest.lhs.load, 0); r := op(lowest.rhs.load, 0);
        size_bits: s64 = 0;
        for blocks size_bits += it.size_bits;
        size := ap_from_u64(64, cast(u64) (size_bits / 8));
        q: Simplify_Query; q.cxt = cxt;
        if !is_dereferenceable_and_aligned_pointer(l, 1, size, q) || !is_dereferenceable_and_aligned_pointer(r, 1, size, q) return false;
    }
    return true;
}

// MergedBlockName
mic_merged_block_name :: (cmps: [] Mic_Block) -> string {
    if cmps.count == 1 return vname(cmps[0].bb);
    size := 0;
    for cmps size += vname(it.bb).count;
    if size == 0 return "";
    sb: String_Builder; sb.allocator = temp;
    append(*sb, vname(cmps[0].bb));
    for i: 1..cmps.count - 1 {
        n := vname(cmps[i].bb);
        if n.count { append(*sb, "+"); append(*sb, n); }
    }
    return builder_to_string(*sb,, allocator = temp);
}

// computeMergedBranchWeights: (ok, weights)
mic_compute_merged_branch_weights :: (cmps: [] Mic_Block) -> (bool, [2] u32) {
    res: [2] u32;
    if cmps.count == 1 {
        ok, w := extract_branch_weights_any(block_terminator(cmps[0].bb));
        if !ok || w.count != 2 return false, res;
        res[0] = w[0]; res[1] = w[1];
        return true, res;
    }
    wt: u64 = 0; wf: u64 = 1;
    for c: cmps {
        ok, w := extract_branch_weights_any(block_terminator(c.bb));
        if !ok || w.count != 2 return false, res;
        b20 := cast(u64) w[1]; b21 := cast(u64) w[0];   // swapped
        // getDisjunctionWeights({wt, wf}, {b20, b21})
        f := wf * b21;
        t := wt * (b20 + b21) + wf * b20;
        wt = t; wf = f;
    }
    // swap back, fitWeights
    a := wf; b := wt;
    mx := max(a, b);
    if mx > 0xFFFF_FFFF {
        sh := 32 - cast(u64) count_leading_zeroes_u64(mx);
        a >>= sh; b >>= sh;
    }
    res[0] = cast(u32) a; res[1] = cast(u32) b;
    return true, res;
}
count_leading_zeroes_u64 :: (x: u64) -> u32 {
    if x == 0 return 64;
    n: u32 = 0;
    v := x;
    while (v & 0x8000_0000_0000_0000) == 0 { n += 1; v <<= 1; }
    return n;
}

// mergeComparisons
mic_merge_comparisons :: (cmps: [] Mic_Block, insert_before: Value_Id, next_cmp_block: Value_Id, phi: Value_Id, tli: *Tli, dtu: *Dtu) -> Value_Id {
    first := *cmps[0];
    f := block_fn(next_cmp_block);
    bb := create_block(f, mic_merged_block_name(cmps), insert_before);
    b: Irb;
    irb_set_end(*b, bb);
    lhs, rhs: Value_Id;
    if first.lhs.gep != NONE lhs = irb_insert(*b, inst_clone(first.lhs.gep)); else lhs = op(first.lhs.load, 0);
    if first.rhs.gep != NONE rhs = irb_insert(*b, inst_clone(first.rhs.gep)); else rhs = op(first.rhs.load, 0);
    for * cmps if it.require_split { mic_split(it, bb); break; }
    is_equal: Value_Id;
    if cmps.count == 1 {
        ll := irb_insert(*b, inst_clone(first.lhs.load));
        rl := irb_insert(*b, inst_clone(first.rhs.load));
        set_op(ll, 0, lhs); set_op(rl, 0, rhs);
        b.dbg = get_metadata(first.cmp, 0);
        is_equal = irb_icmp(*b, ICMP_EQ, ll, rl);
    } else {
        total_bits: u32 = 0;
        for cmps total_bits += cast(u32) it.size_bits;
        loc := get_metadata(cmps[0].cmp, 0);
        for k: 1..cmps.count - 1 { if loc == NONE break; loc = merged_location(loc, get_metadata(cmps[k].cmp, 0)); }
        b.dbg = loc;
        size_t := type_int(tli_size_t_bits());
        call := lir_emit_lib_call(*b, tli, .memcmp, blc_int_ty(), .[ir.t_ptr, ir.t_ptr, size_t], .[lhs, rhs, const_int(size_t, total_bits / 8)]);
        is_equal = irb_icmp(*b, ICMP_EQ, call, const_int(blc_int_ty(), 0));
    }
    bloc := get_metadata(block_terminator(cmps[0].bb), 0);
    for k: 1..cmps.count - 1 { if bloc == NONE break; bloc = merged_location(bloc, get_metadata(block_terminator(cmps[k].bb), 0)); }
    b.dbg = bloc;
    phi_bb := inst_block(phi);
    if next_cmp_block == phi_bb {
        irb_br(*b, phi_bb);
        phi_add_incoming(phi, is_equal, bb);
        dtu_apply1(dtu, true, bb, phi_bb);
    } else {
        bi := irb_cond_br(*b, is_equal, next_cmp_block, phi_bb);
        ok, w := mic_compute_merged_branch_weights(cmps);
        if ok set_branch_weights(bi, w);
        phi_add_incoming(phi, const_false(), bb);
        ups := Dom_Update.[.{true, bb, next_cmp_block}, .{true, bb, phi_bb}];
        dtu_apply(dtu, ups);
    }
    return bb;
}

// DominatorTree::setNewRoot
dt_set_new_root :: (dt: *Dom_Tree, bb: Value_Id) {
    n := dt_create_node(dt, bb);
    if dt.roots.count == 0 { array_add(*dt.roots, bb); dt.root_node = n; return; }
    old := dt.root_node;
    dt.roots[0] = bb;
    dt_add_child(dt, n, old);
    dt.nodes[old].idom = n;
    dt_update_level(dt, old);
    dt.root_node = n;
    dt.dfs_valid = false;
}

// BCECmpChain::simplify
mic_simplify :: (c: *Mic_Chain, tli: *Tli, dtu: *Dtu) -> bool {
    insert_before := c.entry_block;
    next := inst_block(c.phi);
    k := c.merged.count - 1;
    while k >= 0 {
        next = mic_merge_comparisons(c.merged[k], insert_before, next, c.phi, tli, dtu);
        insert_before = next;
        k -= 1;
    }
    entry := c.entry_block;
    while true {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(entry, *preds);
        if preds.count == 0 break;
        p := preds[0];
        t := block_terminator(p);
        n := nops(t);
        for x: 0..n - 1 if op(t, x) == entry set_op(t, x, next);
        ups := Dom_Update.[.{false, p, entry}, .{true, p, next}];
        dtu_apply(dtu, ups);
    }
    // EntryBlock_->isEntryBlock(), asked after the new blocks were inserted in front of it
    if fn_entry(block_fn(entry)) == entry && dtu.dt {
        dt_set_new_root(dtu.dt, next);
        dtu_apply1(dtu, false, next, entry);
    }
    dead: [..] Value_Id; dead.allocator = temp;
    for blocks: c.merged for blocks array_add(*dead, it.bb);
    delete_dead_blocks(dead, dtu);
    return true;
}

// getOrderedBlocks
mic_get_ordered_blocks :: (phi: Value_Id, last: Value_Id, n: s64) -> [..] Value_Id {
    blocks: [..] Value_Id; blocks.allocator = temp;
    array_resize(*blocks, n);
    cur := last;
    idx := n - 1;
    while idx > 0 {
        if block_has_address_taken(cur) { blocks.count = 0; return blocks; }
        blocks[idx] = cur;
        sp := block_single_predecessor(cur);
        if sp == NONE { blocks.count = 0; return blocks; }
        if phi_block_index(phi, sp) < 0 { blocks.count = 0; return blocks; }
        cur = sp;
        idx -= 1;
    }
    blocks[0] = cur;
    return blocks;
}

mic_process_phi :: (phi: Value_Id, tli: *Tli, aar: *Aa_Results, dtu: *Dtu) -> bool {
    n := nops(phi);
    if n <= 1 return false;
    last: Value_Id = NONE;
    for k: 0..n - 1 {
        v := op(phi, k);
        if isa_constant_int(v) continue;
        if last != NONE return false;
        if !is_inst(v) || inst_op(v) != .ICMP || inst_block(v) != phi_block(phi, k) return false;
        last = phi_block(phi, k);
    }
    if last == NONE return false;
    if block_single_successor(last) != inst_block(phi) return false;
    blocks := mic_get_ordered_blocks(phi, last, n);
    if blocks.count == 0 return false;
    c: Mic_Chain;
    mic_chain_build(*c, blocks, phi, aar);
    if !mic_at_least_one_merged(*c) return false;
    if !mic_is_dereferenceable(*c) return false;
    return mic_simplify(*c, tli, dtu);
}

// TTI::enableMemCmpExpansion(OptSize, IsZeroCmp): X86's MaxNumLoads is non-zero; the default target has no expansion
mic_enable_memcmp_expansion :: (t: *Tti) -> bool { return t.kind == .X86; }

mergeicmps_run :: (f: Value_Id) -> Preserved {
    tli := tli_for(f);
    aar := aa_results_for(f);   // AM.getResult<AAManager>: BasicAA computes the DominatorTree (cached below)
    if !mic_enable_memcmp_expansion(tti_get(f)) return PRESERVE_ALL;
    if !is_lib_func_emittable(tli, .memcmp) return PRESERVE_ALL;
    dtu: Dtu; dtu.dt = cached_domtree(f); dtu.lazy = false;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    made := false;
    bb := block(fn_entry(f)).next;
    while bb != NONE {
        first := block(bb).first;
        if first != NONE && inst_op(first) == .PHI made |= mic_process_phi(first, tli, *aar, *dtu);
        bb = block(bb).next;
    }
    if !made return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
