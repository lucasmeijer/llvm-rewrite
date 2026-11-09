// MergedLoadStoreMotion: port of llvm/lib/Transforms/Scalar/MergedLoadStoreMotion.cpp (isDiamondHead,
// getDiamondTail, isStoreSinkBarrierInRange, canSinkFromBlock, getPHIOperand, canSinkStoresAndGEPs,
// sinkStoresAndGEPs, mergeStores, run) and AAResults::canInstructionRangeModRef (llvm/lib/Analysis/
// AliasAnalysis.cpp). Pass parameters: mldst-motion<[no-]split-footer-bb> (parseMergedLoadStoreMotionOptions).

MLSM_MAGIC_COMPILE_TIME_CONTROL :: 250;

Mlsm :: struct {
    aar: Aa_Results;
    split_footer_bb: bool;
}

mlsm_parse_options :: (name: string) -> bool {
    if name == "mldst-motion" return false;
    if !begins_with(name, "mldst-motion<") || name[name.count - 1] != #char ">" fatal("invalid pass pipeline: unknown pass name '%'", name);
    params := slice(name, 13, name.count - 14);
    split := false;
    while params.count {
        k := find_index_from_left(params, #char ";");
        p := ifx k >= 0 then slice(params, 0, k) else params;
        params = ifx k >= 0 then slice(params, k + 1, params.count - k - 1) else "";
        enable := true;
        if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
        if p == "split-footer-bb" split = enable;
        else fatal("invalid pass pipeline: invalid MergedLoadStoreMotionPass parameter '%'", p);
    }
    return split;
}

mlsm_is_diamond_head :: (bb: Value_Id) -> bool {
    if bb == NONE return false;
    bi := block_terminator(bb);
    if bi == NONE || inst_op(bi) != .CONDBR return false;
    s0 := get_successor(bi, 0); s1 := get_successor(bi, 1);
    if block_single_predecessor(s0) == NONE return false;
    if block_single_predecessor(s1) == NONE return false;
    ss0 := block_single_successor(s0); ss1 := block_single_successor(s1);
    if ss0 == NONE || ss1 == NONE || ss0 != ss1 return false;
    return true;
}

mlsm_is_store_sink_barrier_in_range :: (m: *Mlsm, start: Value_Id, end: Value_Id, loc: Mem_Loc) -> bool {
    x := start;
    while x != end { if may_throw(x) return true; x = inst_next(x); }
    // canInstructionRangeModRef(Start, End, Loc, ModRef)
    x = start;
    while true {
        if aa_mod_ref_inst_loc(aa_query_new(*m.aar), x, loc) != MR_NO return true;
        if x == end break;
        x = inst_next(x);
    }
    return false;
}

mlsm_can_sink_from_block :: (m: *Mlsm, bb1: Value_Id, s0: Value_Id) -> Value_Id {
    bb0 := inst_block(s0);
    s1 := block_last(bb1);
    while s1 != NONE {
        defer s1 = inst_prev(s1);
        if inst_op(s1) != .STORE continue;
        loc0 := mloc_get(s0); loc1 := mloc_get(s1);
        if aa_alias(aa_query_new(*m.aar), loc0, loc1).kind == AR_MUST &&
           !mlsm_is_store_sink_barrier_in_range(m, inst_next(s1), block_last(bb1), loc1) &&
           !mlsm_is_store_sink_barrier_in_range(m, inst_next(s0), block_last(bb0), loc0) &&
           has_same_special_state(s0, s1, false, false) &&
           is_bit_or_noop_pointer_castable(vtype(op(s0, 0)), vtype(op(s1, 0)))
            return s1;
    }
    return NONE;
}

mlsm_get_phi_operand :: (bb: Value_Id, s0: Value_Id, s1: Value_Id) -> Value_Id {
    o1 := op(s0, 0); o2 := op(s1, 0);
    if o1 == o2 return NONE;
    pn := create_phi(vtype(o1), 2);
    insert_at_position(pn, bb, block_first(bb), true);   // insertBefore(BB->begin())
    set_name(pn, tconcat(vname(o2), ".sink"));
    apply_merged_location(pn, get_metadata(s0, 0), get_metadata(s1, 0));
    phi_add_incoming(pn, o1, inst_block(s0));
    phi_add_incoming(pn, o2, inst_block(s1));
    return pn;
}

mlsm_can_sink_stores_and_geps :: (s0: Value_Id, s1: Value_Id) -> bool {
    p0 := op(s0, 1); p1 := op(s1, 1);
    if p0 == p1 return true;
    if !is_inst(p0) || inst_op(p0) != .GEP || !is_inst(p1) || inst_op(p1) != .GEP return false;
    return is_identical_to(p0, p1) && has_one_use(p0) && inst_block(p0) == inst_block(s0) &&
           has_one_use(p1) && inst_block(p1) == inst_block(s1);
}

mlsm_sink_stores_and_geps :: (bb: Value_Id, s0: Value_Id, s1: Value_Id) {
    ptr0 := op(s0, 1); ptr1 := op(s1, 1);
    insert_pt := block_first_insertion_pt(bb);
    and_ir_flags(s0, s1);
    combine_metadata_for_cse(s0, s1, true);
    apply_merged_location(s0, get_metadata(s0, 0), get_metadata(s1, 0));
    inst_merge_di_assign_id(s0, s1);
    // IRBuilder<> Builder(S0); CreateBitOrPointerCast
    v := op(s0, 0);
    t := vtype(op(s1, 0));
    if vtype(v) != t {
        b: Irb; irb_set_before(*b, s0);
        opc: Opcode = .BITCAST;
        if is_ptr_or_ptr_vector(vtype(v)) && !is_ptr_or_ptr_vector(t) opc = .PTRTOINT;
        else if !is_ptr_or_ptr_vector(vtype(v)) && is_ptr_or_ptr_vector(t) opc = .INTTOPTR;
        v = irb_cast(*b, opc, v, t);
    }
    set_op(s0, 0, v);
    snew := ic_clone_inst(s0);
    insert_at_position(snew, bb, insert_pt, true);
    pn := mlsm_get_phi_operand(bb, s0, s1);
    if pn != NONE set_op(snew, 0, pn);
    erase_inst_with_metadata(s0);
    erase_inst_with_metadata(s1);
    if ptr0 != ptr1 {
        gep_new := ic_clone_inst(ptr0);
        insert_at_position(gep_new, bb, snew, false);
        apply_merged_location(gep_new, get_metadata(ptr0, 0), get_metadata(ptr1, 0));
        set_op(snew, 1, gep_new);
        rauw_with_metadata(ptr0, gep_new);
        erase_inst_with_metadata(ptr0);
        rauw_with_metadata(ptr1, gep_new);
        erase_inst_with_metadata(ptr1);
    }
}

mlsm_merge_stores :: (m: *Mlsm, head: Value_Id) -> bool {
    merged := false;
    t := block_terminator(head);
    tail := block_single_successor(get_successor(t, 0));
    sink_bb := tail;
    pred0 := get_successor(t, 0);
    pred1 := get_successor(t, 1);
    if pred0 == pred1 return false;
    if !m.split_footer_bb && block_has_n_predecessors_or_more(tail, 3) return false;
    size1 := cast(u32) block_size(pred1);
    n_stores: u32 = 0;
    rbi := block_last(pred0);
    while rbi != NONE {
        i := rbi;
        rbi = inst_prev(rbi);
        if inst_op(i) != .STORE || !inst_is_simple(i) continue;
        n_stores += 1;
        if n_stores * size1 >= MLSM_MAGIC_COMPILE_TIME_CONTROL break;
        s1 := mlsm_can_sink_from_block(m, pred1, i);
        if s1 != NONE {
            if !mlsm_can_sink_stores_and_geps(i, s1) break;
            if sink_bb == tail && block_has_n_predecessors_or_more(tail, 3) {
                sink_bb = split_block_predecessors(tail, .[pred0, pred1], ".sink.split", null, null);
                if sink_bb == NONE break;
            }
            merged = true;
            mlsm_sink_stores_and_geps(sink_bb, i, s1);
            rbi = block_last(pred0);
        }
    }
    return merged;
}

mldst_motion_run :: (f: Value_Id, name: string) -> Preserved {
    m: Mlsm;
    m.split_footer_bb = mlsm_parse_options(name);
    m.aar = aa_results_for(f);
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        nb := block(bb).next;   // make_early_inc_range
        if mlsm_is_diamond_head(bb) && mlsm_merge_stores(*m, bb) changed = true;
        bb = nb;
    }
    if !changed return PRESERVE_ALL;
    if !m.split_footer_bb return preserved_cfg();
    return PRESERVE_NONE;
}
