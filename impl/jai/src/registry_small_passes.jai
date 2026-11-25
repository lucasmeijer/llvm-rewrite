// Small transform passes from the registry gaps (NOTES.md "Pass registry gaps"):
//   strip-gc-relocates   llvm/lib/Transforms/Utils/StripGCRelocates.cpp

// StripGCRelocates::run / stripGCRelocates
strip_gc_relocates_run :: (f: Value_Id) -> Preserved {
    rels: [..] Value_Id; rels.allocator = temp;
    for i: fn_insts(f) {
        // dyn_cast<GCRelocateInst> (an IntrinsicInst: a CallInst) bound to a GCStatepointInst token
        if inst_op(i) != .CALL || call_iid(i) != IID_EXPERIMENTAL_GC_RELOCATE continue;
        if call_iid(op(i, 0)) == IID_EXPERIMENTAL_GC_STATEPOINT array_add(*rels, i);
    }
    for r: rels {
        orig := gc_relocate_derived_ptr(r);
        repl := orig;
        if vtype(r) != vtype(orig) repl = insert_before_named(create_cast(.BITCAST, orig, vtype(r)), r, "cast");
        replace_all_uses_with(r, repl);
        erase_inst_with_metadata(r);
    }
    if !rels.count return PRESERVE_ALL;
    return preserved_cfg();
}

// ---------------------------------------------------------------- flatten-cfg
// llvm/lib/Transforms/Scalar/FlattenCFGPass.cpp (FlattenCFGPass::run, iterativelyFlattenCFG) and
// llvm/lib/Transforms/Utils/FlattenCFG.cpp (FlattenCFGOpt: FlattenParallelAndOr, MergeIfRegion, CompareIfRegionBlock)

flatten_cfg_run :: (f: Value_Id) -> Preserved {
    aar := aa_results_for(f);   // AM.getResult<AAManager>(F), held while the CFG changes (like LLVM's)
    ever := false;
    while true {
        // iterativelyFlattenCFG
        blocks: [..] Value_Id; blocks.allocator = temp;
        for b: fn_blocks(f) array_add(*blocks, b);
        changed := false;
        local := true;
        while local {
            local = false;
            for b: blocks {
                if vkind(b) == .DEAD continue;   // WeakVH of an erased block
                if fcfg_flatten_parallel_and_or(b) || fcfg_merge_if_region(b, *aar) local = true;
            }
            changed |= local;
        }
        if !changed break;
        remove_unreachable_blocks(f, null);
        ever = true;
    }
    return ifx ever then PRESERVE_NONE else PRESERVE_ALL;
}

fcfg_flatten_parallel_and_or :: (bb: Value_Id) -> bool {
    if inst_op(block_first(bb)) == .PHI return false;
    last_cond, first_cond, uncond: Value_Id = NONE, NONE, NONE;
    idx := -1;
    // SmallPtrSet<BasicBlock *, 16> Preds(predecessors(BB)): iterated in insertion order while small
    preds_all: [..] Value_Id; preds_all.allocator = temp;
    block_predecessors(bb, *preds_all);
    preds: [..] Value_Id; preds.allocator = temp;
    for p: preds_all array_add_if_unique(*preds, p);
    // Beyond 16 elements the set iterates in pointer order. Every early `return false` below is a property of one
    // predecessor or a count, so only the choice of LastCondBlock can depend on the order: fail loudly when more
    // than one predecessor qualifies for it.
    big := preds.count > 16;
    last_cond_candidates := 0;
    contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }
    for pred: preds {
        pp := block_single_predecessor(pred);
        t := block_terminator(pred);
        if inst_op(t) == .BR {
            if uncond != NONE || pp == NONE || !contains(preds, pp) || block_has_address_taken(pred) return false;
            uncond = pred;
            continue;
        }
        if inst_op(t) != .CONDBR return false;
        pc := op(t, 0);
        if !has_one_use(pc) return false;
        if pp != NONE && contains(preds, pp) {
            if block_has_address_taken(pred) return false;
            i := block_first(pred);
            while i != t {
                if inst_op(i) == .PHI || !is_safe_to_speculatively_execute_cx(i, NONE, null) return false;
                i = inst(i).next;
            }
        } else {
            if first_cond != NONE return false;
            first_cond = pred;
        }
        ps1 := get_successor(t, 0); ps2 := get_successor(t, 1);
        ps := ifx ps1 == bb then ps2 else ps1;
        cidx := ifx ps1 == bb then 0 else 1;
        if idx == -1 idx = cidx;
        else if cidx != idx return false;
        if !contains(preds, ps) { last_cond = pred; last_cond_candidates += 1; }
        else if inst_op(block_terminator(ps)) == .BR { last_cond = pred; last_cond_candidates += 1; }
    }
    if big && last_cond_candidates > 1 && first_cond != NONE
        fatal("flatten-cfg: more than 16 predecessors and several LastCondBlock candidates: LLVM iterates its SmallPtrSet in pointer order");
    if first_cond == NONE || last_cond == NONE || first_cond == last_cond return false;

    tbb := block_terminator(last_cond);
    ps1 := get_successor(tbb, 0); ps2 := get_successor(tbb, 1);
    pbi1 := inst_op(block_terminator(ps1)) == .BR;
    pbi2 := inst_op(block_terminator(ps2)) == .BR;
    if !pbi1 || get_successor(block_terminator(ps1), 0) != ps2 {
        if !pbi2 || get_successor(block_terminator(ps2), 0) != ps1 return false;
        cur := last_cond;
        ever := false;
        while cur != first_cond {
            bi := block_terminator(cur);
            ci := op(bi, 0);
            if is_inst(ci) && (inst_op(ci) == .ICMP || inst_op(ci) == .FCMP) {
                p := inst(ci).pred;
                if p == ICMP_NE || p == FCMP_ONE {
                    inst(ci).pred = cmp_inverse(p);
                    condbr_swap_successors(bi);
                    ever = true;
                }
            }
            cur = block_single_predecessor(cur);
        }
        return ever;
    }
    if inst_op(block_first(ps2)) == .PHI return false;

    pbi := block_terminator(first_cond);
    pc := op(pbi, 0);
    b: Irb;
    while true {
        cb := get_successor(pbi, cast(u32) (1 - idx));
        erase_inst_with_metadata(block_last(first_cond));
        block_splice_whole(first_cond, NONE, false, cb);
        pbi = block_terminator(first_cond);
        cc := op(pbi, 0);
        irb_set_before(*b, pbi);
        nc := irb_binop(*b, ifx idx == 0 then Opcode.OR else .AND, pc, cc);
        replace_uses_of_with(pbi, cc, nc);
        pc = nc;
        done := cb == last_cond;
        // CB->dropAllReferences() (now empty); new UnreachableInst(Ctx, CB)
        block_append_inst(cb, new_inst(.UNREACHABLE, ir.t_void, 0));
        if done break;
    }
    return true;
}

fcfg_compare_if_region_block :: (b1: Value_Id, b2: Value_Id, head2: Value_Id, aar: *Aa_Results) -> bool {
    pti2 := block_terminator(head2);
    pbi2 := block_first(head2);
    i1 := block_first(b1); e1 := block_terminator(b1);
    i2 := block_first(b2); e2 := block_terminator(b2);
    while true {
        if i1 == e1 {
            if i2 != e2 return false;
            break;
        }
        if !is_identical_to(i1, i2) return false;
        if may_have_side_effects(i1) {
            if inst_op(i1) != .STORE || is_volatile(i1) return false;
        }
        if may_read_from_memory(i1) return false;
        if may_write_to_memory(i1) {
            x := pbi2;
            while x != pti2 {
                if may_read_from_memory(x) || may_write_to_memory(x) {
                    if aa_mod_ref_inst_inst(aa_query_new(aar), i1, x) != MR_NO return false;
                }
                x = inst(x).next;
            }
        }
        i1 = inst(i1).next;
        i2 = inst(i2).next;
    }
    return true;
}

fcfg_merge_if_region :: (bb: Value_Id, aar: *Aa_Results) -> bool {
    if inst_op(block_first(bb)) == .PHI return false;
    dom_bi2, if_true2, if_false2 := get_if_condition(bb);
    if dom_bi2 == NONE return false;
    cinst2 := op(dom_bi2, 0);
    if !is_inst(cinst2) return false;
    second := inst_block(cinst2);
    if block_has_address_taken(second) return false;
    dom_bi1, if_true1, if_false1 := get_if_condition(second);
    if dom_bi1 == NONE return false;
    cinst1 := op(dom_bi1, 0);
    if !is_inst(cinst1) return false;
    first := inst_block(cinst1);
    if first == second return false;
    invert2 := false;
    combine: Opcode;
    if if_false1 == first {
        combine = .OR;
        if if_false2 != second {
            if if_true2 != second return false;
            invert2 = true;
            x := if_true2; if_true2 = if_false2; if_false2 = x;
        }
        if !fcfg_compare_if_region_block(if_true1, if_true2, second, aar) return false;
    } else if if_true1 == first {
        combine = .AND;
        if if_true2 != second {
            if if_false2 != second return false;
            invert2 = true;
            x := if_true2; if_true2 = if_false2; if_false2 = x;
        }
        if !fcfg_compare_if_region_block(if_false1, if_false2, second, aar) return false;
    } else return false;

    pti2 := block_terminator(second);
    x := block_first(second);
    while x != pti2 {
        if inst_op(x) == .PHI || may_have_side_effects(x) || !is_safe_to_speculatively_execute_cx(x, NONE, null) return false;
        x = inst(x).next;
    }
    erase_inst_with_metadata(block_last(first));
    block_splice_whole(first, NONE, false, second);
    pbi := block_terminator(first);
    b: Irb;
    irb_set_before(*b, pbi);
    if invert2 invert_branch(pbi, *b);
    nc := irb_binop(*b, combine, cinst1, op(pbi, 0));
    replace_uses_of_with(pbi, op(pbi, 0), nc);
    if if_true1 != first fcfg_erase_block(if_true1);
    if if_false1 != first fcfg_erase_block(if_false1);
    fcfg_erase_block(second);
    return true;
}

// BB->dropAllReferences(); BB->eraseFromParent()
fcfg_erase_block :: (bb: Value_Id) {
    for i: block_insts(bb) drop_all_references(i);
    block_erase_from_parent(bb);
}
