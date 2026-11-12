// PartiallyInlineLibCalls: port of llvm/lib/Transforms/Scalar/PartiallyInlineLibCalls.cpp (optimizeSQRT,
// runPartiallyInlineLibCalls) with BasicTTIImpl::haveFastSqrt and X86TTIImpl::isFCmpOrdCheaperThanFCmpZero (false).

// TTI->haveFastSqrt(Ty): isTypeLegal(VT) && isOperationLegalOrCustom(ISD::FSQRT, VT)
pilc_have_fast_sqrt :: (t: *Tti, ty: Type_Id) -> bool {
    if t.kind != .X86 return false;
    ok, vt := x86_value_type(*t.xl, ty, true);
    if !ok return false;
    return xl_is_type_legal(*t.xl, vt) && is_op_legal_or_custom(*t.xl, ISD_FSQRT, vt.m);
}

// optimizeSQRT -> the join block (the scan continues there), NONE when nothing changed
pilc_optimize_sqrt :: (call: Value_Id, curr_bb: Value_Id, t: *Tti, ups: *[..] Dom_Update) -> Value_Id {
    if call_only_reads_memory(call) return NONE;
    ty := vtype(call);
    next := inst_next(call);
    next_dl := get_metadata(next, 0);   // IRBuilder<> Builder(Call->getNextNode()): its StoredDL
    // SplitBlockAndInsertIfThen(true, Call->getNextNode(), false, nullptr, DTU) (lazy DTU over the cached DT)
    head := curr_bb;
    orig: [..] Value_Id; orig.allocator = temp;
    {
        s: [..] Value_Id; s.allocator = temp;
        block_successors(head, *s);
        for s { dup := false; for x: orig if x == it dup = true; if !dup array_add(*orig, it); }
    }
    tail := split_basic_block(head, next, "");
    then_bb := create_block(block_fn(head), "", tail);
    lib_term := create_br(tail);
    block_append_inst(then_bb, lib_term);
    set_metadata(lib_term, 0, get_metadata(next, 0));
    old := block_terminator(head);
    nt := create_cond_br(const_int(ir.t_i1, 1), then_bb, tail);
    if get_metadata(nt, 0) == NONE { d := get_metadata(old, 0); if d != NONE set_metadata(nt, 0, d); }
    insert_at_position(nt, head, old, false);
    erase_inst_with_metadata(old);
    if ups {
        array_add(ups, .{true, head, then_bb});
        array_add(ups, .{true, head, tail});
        array_add(ups, .{true, then_bb, tail});
        for orig array_add(ups, .{true, tail, it});
        for orig array_add(ups, .{false, head, it});
    }
    curr_term := block_terminator(curr_bb);
    condbr_swap_successors(curr_term);
    join := get_successor(lib_term, 0);
    set_name(join, tconcat(vname(curr_bb), ".split"));
    phi := create_phi(ty, 2);
    insert_at_position(phi, join, block_first(join), false);
    if next_dl != NONE set_metadata(phi, 0, next_dl);
    rauw_with_metadata(call, phi);
    lib_bb := inst_block(lib_term);
    set_name(lib_bb, "call.sqrt");
    lib_call := ic_clone_inst(call);
    insert_at_position(lib_call, lib_bb, lib_term, false);
    // Builder.Insert at LibCallTerm: the builder's location (the terminator's) replaces the clone's when set
    if get_metadata(lib_term, 0) != NONE set_metadata(lib_call, 0, get_metadata(lib_term, 0));
    // Call->setDoesNotAccessMemory(): memory(none)
    me: Attr; me.kind = .Memory; me.ty = NONE; me.ival = 0;
    inst(call).attrs = attr_list_with_fn(inst(call).attrs, attr_set_with(attr_list_fn(inst(call).attrs), me));
    // isFCmpOrdCheaperThanFCmpZero: false on X86 -> fcmp oge Op0, 0.0
    b: Irb; irb_set_before(*b, curr_term);
    fc := create_fcmp(FCMP_OGE, call_arg(call, 0), const_fp_words(ty, .[0]));
    fcmp := irb_insert(*b, fc);
    if get_metadata(curr_term, 0) == NONE set_metadata(fcmp, 0, NONE);
    set_op(curr_term, 0, fcmp);
    // the quick path is presumed frequent: MDBuilder::createLikelyBranchWeights() = {(1 << 20) - 1, 1}
    ok, ec := ic_fn_entry_count(inst_fn(curr_term));
    if ok set_metadata(curr_term, md_kind_id("prof"), md_branch_weights(.[(1 << 20) - 1, 1], false));
    phi_add_incoming(phi, call, curr_bb);
    phi_add_incoming(phi, lib_call, lib_bb);
    return join;
}

partially_inline_libcalls_run :: (f: Value_Id) -> Preserved {
    if cg_skip_function(f) return PRESERVE_ALL;
    t := tti_get(f);
    dt := cached_domtree(f);
    ups: [..] Dom_Update; ups.allocator = temp;   // the lazy DomTreeUpdater, flushed when the pass returns
    pups := ifx dt then *ups else null;
    tli := tli_for(f);
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        curr := bb;
        bb = block(bb).next;
        for i: block_insts(curr) {
            if inst_op(i) != .CALL continue;
            callee := call_called_function(i);
            if callee == NONE continue;
            if call_is_no_builtin(i) || call_is_strict_fp(i) continue;
            if ((inst(i).flags >> TAIL_SHIFT) & 3) == 2 continue;   // isMustTailCall
            if is_local_linkage(glob(callee).linkage) continue;
            okl, lf := tli_lookup_fn(callee);
            if !okl || !tli_func_has(tli, lf) continue;
            if lf == .sqrtf || lf == .sqrt {
                if pilc_have_fast_sqrt(t, vtype(i)) {
                    join := pilc_optimize_sqrt(i, curr, t, pups);
                    if join != NONE { bb = join; changed = true; break; }
                }
            }
        }
    }
    if dt && ups.count dt_apply_updates(dt, ups);
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
