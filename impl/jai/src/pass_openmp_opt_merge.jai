// OpenMPOpt::mergeParallelRegions (llvm/lib/Transforms/IPO/OpenMPOpt.cpp, -openmp-opt-enable-merging) and the
// OpenMPIRBuilder pieces it calls (llvm/lib/Frontend/OpenMP/OMPIRBuilder.cpp: createParallel with
// hostParallelCallback, createMaster with EmitOMPInlinedRegion / emitCommonDirectiveEntry / emitCommonDirectiveExit,
// createBarrier, getOrCreateThreadID, FinalizationInfo::getFiniBB / mergeFiniBB, finalize with
// OutlineInfo::collectBlocks / createCodeExtractor and hoistNonEntryAllocasToEntryBlock). The OpenMPIRBuilder's
// IRBuilder is `omb` (an Irb); the callbacks of OpenMPOpt's merge are the fixed code paths they take here.

omb: Irb;   // OMPInfoCache.OMPBuilder.Builder

// FinalizationInfo: the parallel region's FiniCBWrapper (branch to the region exit) or the master's no-op FiniCB
Omp_Fini_Info :: struct { parallel: bool; exit_bb: Value_Id = NONE; fini_bb: Value_Id = NONE; }
omp_fini_stack: [..] Omp_Fini_Info;

// OutlineInfo (host): the region and what hostParallelCallback needs
Omp_Outline_Info :: struct {
    outer_fn: Value_Id;
    outer_alloc_bb: Value_Id;
    entry_bb: Value_Id;
    exit_bb: Value_Id;
    exclude_args: [..] Value_Id;   // ExcludeArgsFromAggregate
    ident: Value_Id;
    priv_tid: Value_Id;
    priv_tid_addr: Value_Id;
    to_be_deleted: [..] Value_Id;
}
omp_outline_infos: [..] Omp_Outline_Info;

// updateToLocation(LocationDescription{IP = (bb, pt), DL})
omp_update_to_location :: (bb: Value_Id, pt: Value_Id, dl_md: Md_Id) {
    irb_set_at(*omb, bb, pt, false);
    omb.dbg = dl_md;
}
// createRuntimeFunctionCall(Callee, Args, Name) at the builder's insertion point (CallingConv::C)
omp_create_runtime_function_call :: (f: Value_Id, args: [] Value_Id, name := "") -> Value_Id {
    c := irb_call(*omb, f, args, name);
    inst(c).cc = 0;
    return c;
}
// getOrCreateThreadID
omp_get_or_create_thread_id :: (ident: Value_Id) -> Value_Id {
    return omp_create_runtime_function_call(omp_get_or_create_runtime_function(.__kmpc_global_thread_num), .[ident], "omp_global_thread_num");
}
// createBarrier(Loc, OMPD_parallel): (insertion block, point) after it
omp_create_barrier :: (bb: Value_Id, pt: Value_Id, dl_md: Md_Id) -> (Value_Id, Value_Id) {
    omp_update_to_location(bb, pt, dl_md);
    src, size := omp_get_or_create_src_loc_str_dl(*omp_ic.b, dl_md, block_fn(bb));
    a0 := omp_get_or_create_ident(*omp_ic.b, src, size, OMP_IDENT_FLAG_BARRIER_IMPL);
    a1 := omp_get_or_create_thread_id(omp_get_or_create_ident(*omp_ic.b, src, size));
    // isLastFinalizationInfoCancellable(OMPD_parallel): no region is cancellable here
    omp_create_runtime_function_call(omp_get_or_create_runtime_function(.__kmpc_barrier), .[a0, a1]);
    return omb.bb, omb.pt;
}

// FinalizationInfo::getFiniBB
omp_get_fini_bb :: (fi: *Omp_Fini_Info) -> Value_Id {
    if fi.fini_bb == NONE {
        parent := block_fn(omb.bb);
        saved := omb;
        fi.fini_bb = create_block(parent, ".fini");
        irb_set_end(*omb, fi.fini_bb);
        // FiniCBWrapper: an open-ended block jumps to the region exit; OpenMPOpt's FiniCB does nothing
        if fi.parallel irb_insert(*omb, create_br(fi.exit_bb));
        omb = saved;
    }
    return fi.fini_bb;
}

// ---------------------------------------------------------------- createMaster

// emitCommonDirectiveEntry(OMPD, EntryCall, ExitBB, Conditional = true)
omp_emit_common_directive_entry :: (entry_call: Value_Id, exit_bb: Value_Id) {
    entry_bb := omb.bb;
    call_bool := irb_insert(*omb, create_icmp(ICMP_NE, entry_call, const_null_value(vtype(entry_call))));
    then_bb := create_block(block_fn(entry_bb), "omp_region.body", block(entry_bb).next);
    ui := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(then_bb, ui);
    entry_ti := block_terminator(entry_bb);
    irb_insert(*omb, create_cond_br(call_bool, then_bb, exit_bb));
    inst_unlink(entry_ti);
    irb_set_before(*omb, ui);
    irb_insert(*omb, entry_ti);
    erase_inst(ui);
    irb_set_before(*omb, block_terminator(then_bb));
}

// createMaster(Loc, BodyGenCB, FiniCB) with CreateSequentialRegion's BodyGenCB (seq_start_bb, seq_end_bb):
// (insertion block, point) after the region
omp_create_master :: (bb: Value_Id, dl_md: Md_Id, seq_start_bb: Value_Id, seq_end_bb: Value_Id) -> (Value_Id, Value_Id) {
    omp_update_to_location(bb, NONE, dl_md);
    src, size := omp_get_or_create_src_loc_str_dl(*omp_ic.b, dl_md, block_fn(bb));
    ident := omp_get_or_create_ident(*omp_ic.b, src, size);
    tid := omp_get_or_create_thread_id(ident);
    entry_call := omp_create_runtime_function_call(omp_get_or_create_runtime_function(.__kmpc_master), .[ident, tid]);
    exit_call := omp_create_runtime_function_call(omp_get_or_create_runtime_function(.__kmpc_end_master), .[ident, tid]);
    // EmitOMPInlinedRegion(OMPD_master, EntryCall, ExitCall, BodyGenCB, FiniCB, Conditional, HasFinalize)
    array_add(*omp_fini_stack, .{false, NONE, NONE});
    entry_bb := omb.bb;
    split_pos := block_terminator_or_null(entry_bb);
    if split_pos == NONE || (inst_op(split_pos) != .BR && inst_op(split_pos) != .CONDBR) {
        split_pos = new_inst(.UNREACHABLE, ir.t_void, 0);
        block_append_inst(entry_bb, split_pos);
    }
    exit_bb := split_basic_block(entry_bb, split_pos, "omp_region.end");
    fini_bb := split_basic_block(entry_bb, block_terminator(entry_bb), "omp_region.finalize");
    irb_set_before(*omb, block_terminator(entry_bb));
    omp_emit_common_directive_entry(entry_call, exit_bb);
    // BodyGenCB(AllocaIP, CodeGenIP, DeallocBlocks)
    cg_start_bb := omb.bb;
    cg_end_bb := split_block(cg_start_bb, omb.pt, null, null);
    set_successor(block_terminator(cg_start_bb), 0, seq_start_bb);
    set_successor(block_terminator(seq_end_bb), 0, cg_end_bb);
    // emitCommonDirectiveExit(OMPD, FinIP = (FiniBB, first insertion point), ExitCall, HasFinalize)
    irb_set_at(*omb, fini_bb, block_first_insertion_pt(fini_bb), true);
    fi := pop(*omp_fini_stack);
    // mergeFiniBB: FiniBB = OtherFiniBB, then FiniCB (nothing)
    fi.fini_bb = fini_bb;
    irb_set_before(*omb, block_terminator(fini_bb));
    inst_unlink(exit_call);
    irb_insert(*omb, exit_call);
    // MergeBlockIntoPredecessor(ExitBB): the region end has two predecessors
    if block_single_predecessor(exit_bb) != NONE fatal("internal: openmp-opt: unexpected single predecessor of omp_region.end");
    if inst_op(split_pos) != .BR && inst_op(split_pos) != .CONDBR erase_inst(split_pos);
    irb_set_end(*omb, exit_bb);
    return omb.bb, omb.pt;
}

// ---------------------------------------------------------------- createParallel

// createParallel(Loc = (bb, end, dl), OuterAllocIP = (alloca_bb, first insertion point), {}, BodyGenCB, PrivCB,
// FiniCB, nullptr, nullptr, OMP_PROC_BIND_default, false) with mergeParallelRegions' callbacks: the body is
// start_bb .. end_bb. Returns the block after the region (AfterIP is its end).
omp_create_parallel :: (bb: Value_Id, dl_md: Md_Id, alloca_bb: Value_Id, start_bb: Value_Id, end_bb: Value_Id) -> Value_Id {
    if omp_ic.b.is_target_device fatal("openmp-opt: merging parallel regions of device code is not supported yet");
    omp_update_to_location(bb, NONE, dl_md);
    src, size := omp_get_or_create_src_loc_str_dl(*omp_ic.b, dl_md, block_fn(bb));
    ident := omp_get_or_create_ident(*omp_ic.b, src, size);
    insert_bb := omb.bb;
    outer_fn := block_fn(insert_bb);
    outer_alloca_block := alloca_bb;
    oi: Omp_Outline_Info;
    oi.to_be_deleted.allocator = temp;
    oi.exclude_args.allocator = temp;
    i32 := type_int(32);
    // the allocas modelling the tid / zero arguments
    irb_set_at(*omb, outer_alloca_block, block_first(outer_alloca_block), true);   // OuterAllocaBlock->begin()
    create_alloca :: (ty: Type_Id, name: string) -> Value_Id {
        a := create_alloca_unlinked(ty, dl.alloca_as, dl_pref_align(ty));
        return irb_insert(*omb, a, name);
    }
    tid_addr_alloca := create_alloca(i32, "tid.addr");
    zero_addr_alloca := create_alloca(i32, "zero.addr");
    tid_addr := tid_addr_alloca;
    zero_addr := zero_addr_alloca;
    array_add(*oi.to_be_deleted, tid_addr_alloca);
    array_add(*oi.to_be_deleted, zero_addr_alloca);
    ui := new_inst(.UNREACHABLE, ir.t_void, 0);
    block_append_inst(insert_bb, ui);
    entry_bb := inst_block(ui);
    preg_entry_bb := split_basic_block(entry_bb, ui, "omp.par.entry");
    preg_body_bb := split_basic_block(preg_entry_bb, ui, "omp.par.region");
    preg_pre_fini_bb := split_basic_block(preg_body_bb, ui, "omp.par.pre_finalize");
    preg_exit_bb := split_basic_block(preg_pre_fini_bb, ui, "omp.par.exit");
    array_add(*omp_fini_stack, .{true, preg_exit_bb, NONE});
    irb_set_before(*omb, block_terminator(preg_entry_bb));
    load :: (ty: Type_Id, p: Value_Id, name: string) -> Value_Id {
        l := new_inst(.LOAD, ty, 1);
        set_op(l, 0, p);
        inst(l).align = dl_abi_align(ty);
        return irb_insert(*omb, l, name);
    }
    priv_tid_addr := create_alloca(i32, "tid.addr.local");
    priv_tid := load(i32, priv_tid_addr, "tid");
    array_add(*oi.to_be_deleted, load(i32, tid_addr, "tid.addr.use"));
    zero_addr_use := load(i32, zero_addr, "zero.addr.use");
    array_add(*oi.to_be_deleted, zero_addr_use);
    // BodyGenCB(InnerAllocaIP, CodeGenIP = (PRegBodyBB, begin), PRegExitBB)
    cg_start_bb := preg_body_bb;
    cg_end_bb := split_block(cg_start_bb, block_first(cg_start_bb), null, null);
    set_successor(block_terminator(cg_start_bb), 0, start_bb);
    set_successor(block_terminator(end_bb), 0, cg_end_bb);
    oi.outer_fn = outer_fn;
    oi.outer_alloc_bb = outer_alloca_block;
    oi.entry_bb = preg_entry_bb;
    oi.exit_bb = preg_exit_bb;
    oi.ident = ident;
    oi.priv_tid = priv_tid;
    oi.priv_tid_addr = priv_tid_addr;
    region_set: Table(Value_Id, bool); region_set.allocator = temp;
    blocks: [..] Value_Id; blocks.allocator = temp;
    omp_collect_blocks(preg_entry_bb, preg_exit_bb, *region_set, *blocks);
    cache := ce_cache_new(outer_fn);
    ce := ce_new(blocks, null, null, null, null, true, true, ".omp_par");
    ce.allocation_block = outer_alloca_block;
    sink: Value_Set; vset_init(*sink);
    hoist: Value_Set; vset_init(*hoist);
    ce_find_allocas(*ce, *cache, *sink, *hoist);
    inputs: Value_Set; vset_init(*inputs);
    outputs: Value_Set; vset_init(*outputs);
    ce_find_inputs_outputs(*ce, *inputs, *outputs, *sink, true);
    ident_ty := omp_ident_type();
    kept: [..] Value_Id; kept.allocator = temp;
    for inputs.list if !(vkind(it) == .GLOBAL_VAR && glob(it).value_type == ident_ty) array_add(*kept, it);
    tid_rtl_fn := omp_get_or_create_runtime_function(.__kmpc_global_thread_num);
    // InnerAllocaIP right after the fake use of the zero address, OuterAllocIP at the alloca block's start
    inner_alloca_bb := inst_block(zero_addr_use);
    inner_alloca_pt := inst_next(zero_addr_use);
    for v: kept {
        if v == tid_addr || v == zero_addr { array_add(*oi.exclude_args, v); continue; }
        uses: [..] Use_Id; uses.allocator = temp;
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && table_contains(*region_set, inst_block(usr)) array_add(*uses, u);
            u = ir.u_next[u];
        }
        inner := v;
        if !is_ptr_type(vtype(v)) {
            saved := omb;
            irb_set_at(*omb, outer_alloca_block, block_first_insertion_pt(outer_alloca_block), true);
            p := create_alloca(vtype(v), tconcat(vname(v), ".reloaded"));
            irb_set_at(*omb, insert_bb, block_terminator(insert_bb), false);
            st := create_store_raw(v, p, dl_abi_align(vtype(v)));
            irb_insert(*omb, st);
            irb_set_at(*omb, inner_alloca_bb, inner_alloca_pt, false);
            inner = load(vtype(v), p, "");
            omb = saved;
        }
        repl: Value_Id;
        if is_inst(v) && inst_op(v) == .CALL && call_called_function(v) == tid_rtl_fn {
            repl = priv_tid;
        } else {
            // PrivCB: ReplacementValue = &Inner, AfterIP = CodeGenIP
            repl = inner;
            inner_alloca_pt = block_terminator(inner_alloca_bb);
            if repl == v continue;
        }
        for uses use_set(it, repl);
    }
    // the finalization of the region
    fi := pop(*omp_fini_stack);
    pre_fini_ti := block_terminator(preg_pre_fini_bb);
    fini_bb := omp_get_fini_bb(*fi);
    {
        saved := omb;
        irb_set_before(*omb, pre_fini_ti);
        irb_insert(*omb, create_br(fini_bb));
        term := block_terminator_or_null(omb.bb);
        if term != NONE erase_inst(term);
        omb = saved;
    }
    array_add(*omp_outline_infos, oi);
    after := inst_block(ui);
    erase_inst(ui);
    return after;
}

// OutlineInfo::collectBlocks
omp_collect_blocks :: (entry: Value_Id, exit: Value_Id, set: *Table(Value_Id, bool), out: *[..] Value_Id) {
    table_set(set, entry, true);
    table_set(set, exit, true);
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, entry);
    succs: [..] Value_Id; succs.allocator = temp;
    while work.count {
        b := pop(*work);
        array_add(out, b);
        succs.count = 0;
        block_successors(b, *succs);
        for s: succs if !table_contains(set, s) { table_set(set, s, true); array_add(*work, s); }
    }
}

// OpenMPIRBuilder::finalize(Fn)
omp_finalize :: (fnv: Value_Id) -> Value_Id {
    deferred: [..] Omp_Outline_Info; deferred.allocator = temp;
    outlined: Value_Id = NONE;
    for oi: omp_outline_infos {
        if oi.outer_fn != fnv { array_add(*deferred, oi); continue; }
        set: Table(Value_Id, bool); set.allocator = temp;
        blocks: [..] Value_Id; blocks.allocator = temp;
        omp_collect_blocks(oi.entry_bb, oi.exit_bb, *set, *blocks);
        outer := oi.outer_fn;
        cache := ce_cache_new(outer);
        ce := ce_new(blocks, null, null, null, null, true, true, ".omp_par");
        ce.aggregate_args = true;
        ce.allocation_block = oi.outer_alloc_bb;
        ce.args_in_zero_as = omp_ic.b.is_target_device;
        if !ce_is_eligible(*ce) fatal("internal: openmp-opt: expected OpenMP outlining to be possible");
        for oi.exclude_args array_add(*ce.exclude_from_aggregate, it);
        nf := ce_extract_code_region(*ce, *cache);
        // the outlined function goes right after the outer one
        for ir.m_functions if it == nf { array_ordered_remove_by_index(*ir.m_functions, it_index); break; }
        idx := -1;
        for ir.m_functions if it == outer { idx = it_index; break; }
        array_insert_at(*ir.m_functions, nf, idx + 1);
        // remove the extractor's artificial entry block
        art := fn_entry(nf);
        i := block_last(art);
        while i != NONE {
            prev := inst_prev(i);
            if !is_terminator(inst_op(i)) {
                // moveBeforePreserving(EntryBB, getFirstInsertionPt()): the instruction keeps its own records
                inst_unlink(i);
                insert_at_position(i, oi.entry_bb, block_first_insertion_pt(oi.entry_bb), true);
            } else if inst(i).records {
                // TI->adoptDbgRecords(&ArtificialEntry, I, InsertAtHead = false)
                ti := block_terminator_or_null(oi.entry_bb);
                if ti != NONE records_append(ti, records_take(i));
            }
            i = prev;
        }
        block_move_before(oi.entry_bb, art);
        block_erase_from_parent(art);
        omp_host_parallel_callback(*oi, nf);
        omp_hoist_non_entry_allocas_to_entry_block(nf);
        outlined = nf;
    }
    omp_outline_infos.count = 0;
    for deferred array_add(*omp_outline_infos, it);
    return outlined;
}

// hostParallelCallback
omp_host_parallel_callback :: (oi: *Omp_Outline_Info, outlined: Value_Id) {
    rtl_fn := omp_get_or_create_runtime_function(.__kmpc_fork_call);
    if get_metadata(rtl_fn, md_fixed("callback")) == NONE {
        i64 := type_int(64);
        enc := md_tuple(.[md_value(const_int(i64, 2)), md_value(const_int_signed(i64, -1)),
                          md_value(const_int_signed(i64, -1)), md_value(const_int(type_int(1), 1))], false);
        add_metadata(rtl_fn, md_kind_id("callback"), md_tuple(.[enc], false));
    }
    fn_add_param_attr_kind(outlined, 0, .NoAlias);
    fn_add_param_attr_kind(outlined, 1, .NoAlias);
    fn_add_fn_attr_kind(outlined, .NoUnwind);
    num_captured := cast(u64) fn_nargs(outlined) - 2;
    if !has_one_use(outlined) fatal("internal: openmp-opt: the outlined parallel region has more than one use");
    ci := ir.u_user[ir.v_first_use[outlined]];
    set_name(inst_block(ci), "omp_parallel");
    irb_set_before(*omb, ci);
    args: [..] Value_Id; args.allocator = temp;
    array_add(*args, oi.ident);
    array_add(*args, const_int(type_int(32), num_captured));
    array_add(*args, outlined);
    for k: 2..cast(s64) call_num_args(ci) - 1 array_add(*args, call_arg(ci, cast(u32) k));
    omp_create_runtime_function_call(rtl_fn, args);
    irb_set_before(*omb, oi.priv_tid);
    i32 := type_int(32);
    l := new_inst(.LOAD, i32, 1);
    set_op(l, 0, fn_arg(outlined, 0));
    inst(l).align = dl_abi_align(i32);
    irb_insert(*omb, l);
    irb_insert(*omb, create_store_raw(l, oi.priv_tid_addr, dl_abi_align(i32)));
    erase_inst(ci);
    for oi.to_be_deleted erase_inst(it);
}

// hoistNonEntryAllocasToEntryBlock(Function *)
omp_hoist_non_entry_allocas_to_entry_block :: (f: Value_Id) {
    pdt := dt_new(true);
    dt_recalculate(pdt, f);
    entry := fn_entry(f);
    for bb: fn_blocks(f) {
        if !dt_properly_dominates(pdt, bb, entry) continue;
        to_move: [..] Value_Id; to_move.allocator = temp;
        for x: block_insts(bb) if inst_op(x) == .ALLOCA && !alloca_is_array_allocation(x) array_add(*to_move, x);
        t := block_terminator(entry);
        for to_move inst_move_before_dbg(it, t);   // AllocaInst->moveBefore(iterator)
    }
    dt_free(pdt);
}

// ---------------------------------------------------------------- OpenMPOpt::mergeParallelRegions

omp_merge_parallel_regions :: () -> bool {
    callback_callee_operand :: 2;
    callback_first_arg_operand :: 3;
    rfi := omp_rfi(.__kmpc_fork_call);
    if rfi.declaration == NONE return false;
    unmergable := Value_Id.[omp_rfi(.__kmpc_push_proc_bind).declaration, omp_rfi(.__kmpc_push_num_threads).declaration];
    changed := false;
    // BB2PRMap (a SmallDenseMap<BasicBlock *, SmallPtrSet<Instruction *>>: block order is the address order)
    bbs: [..] Value_Id; bbs.allocator = temp;
    bb_cis: [..] [..] Value_Id; bb_cis.allocator = temp;
    for u: omp_rfi_uses(rfi, oo.scc) {
        ci := omp_call_if_regular_call_use(u, rfi);
        if ci == NONE fatal("openmp-opt: a use of __kmpc_fork_call that is not a regular call");
        b := inst_block(ci);
        idx := -1;
        for bbs if it == b { idx = it_index; break; }
        if idx < 0 { array_add(*bbs, b); e: [..] Value_Id; e.allocator = temp; array_add(*bb_cis, e); idx = bbs.count - 1; }
        if !omp_contains(bb_cis[idx], ci) array_add(*bb_cis[idx], ci);
    }
    // IsMergable
    is_mergable :: (x: Value_Id, before_region: bool, unmergable: [] Value_Id) -> bool {
        if is_terminator(inst_op(x)) return false;
        if inst_op(x) != .CALL return true;
        if before_region {
            called := call_called_function(x);
            if called == NONE return false;
            for unmergable if it != NONE && called == it return false;
        } else {
            if call_iid(x) == NOT_INTRINSIC return false;
        }
        return true;
    }
    // the merge candidates of every block, computed before any block is merged (merging one block does not change
    // what another block finds)
    plans: [..] [..] [..] Value_Id; plans.allocator = temp;
    for b, bi: bbs {
        vec: [..] [..] Value_Id; vec.allocator = temp;
        cis := bb_cis[bi];
        if cis.count >= 2 {
            mergable: [..] Value_Id; mergable.allocator = temp;
            x := block_first(b);
            while x != NONE {
                cur := x;
                x = inst_next(x);
                if omp_contains(cis, cur) { array_add(*mergable, cur); continue; }
                if is_mergable(cur, mergable.count == 0, unmergable) continue;
                while x != NONE {
                    skip := x;
                    if omp_contains(cis, skip) { x = inst_next(x); break; }
                    x = inst_next(x);
                }
                if mergable.count > 1 {
                    copy: [..] Value_Id; copy.allocator = temp;
                    for mergable array_add(*copy, it);
                    array_add(*vec, copy);
                }
                mergable.count = 0;
            }
        }
        array_add(*plans, vec);
    }
    blocks_with_merges := 0;
    for plans if it.count != 0 blocks_with_merges += 1;
    if blocks_with_merges > 1 fatal("openmp-opt: merging parallel regions of more than one block in an SCC depends on the address order of the blocks (BB2PRMap)");
    for b, bi: bbs {
        if plans[bi].count == 0 continue;
        changed = true;
        for m: plans[bi] omp_merge(m, b);
    }
    if changed {
        omp_recollect_uses_for_function(.__kmpc_fork_call);
        omp_recollect_uses_for_function(.__kmpc_barrier);
        omp_recollect_uses_for_function(.__kmpc_master);
        omp_recollect_uses_for_function(.__kmpc_end_master);
    }
    return changed;
}

// CreateSequentialRegion
omp_create_sequential_region :: (outer_fn: Value_Id, seq_start_i: Value_Id, seq_end_i: Value_Id) {
    parent_bb := inst_block(seq_start_i);
    seq_end_bb := split_block(parent_bb, inst_next(seq_end_i), null, null);
    seq_after_bb := split_block(seq_end_bb, block_first_insertion_pt(seq_end_bb), null, null);
    seq_start_bb := split_block(parent_bb, seq_start_i, null, null, null, "seq.par.merged");
    if block_unique_successor(parent_bb) != seq_start_bb fatal("internal: openmp-opt: expected a different CFG");
    dl_md := get_metadata(block_terminator(parent_bb), MDK_DBG);
    erase_inst(block_terminator(parent_bb));
    for x: block_insts(seq_start_bb) {
        outside: [..] Value_Id; outside.allocator = temp;
        u := ir.v_first_use[x];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if call_is_lifetime_start_or_end(usr) continue;
            if inst_block(usr) != seq_start_bb && !omp_contains(outside, usr) array_add(*outside, usr);
        }
        if outside.count == 0 continue;
        // OutsideUsers is a SmallPtrSet<Instruction *, 4>: insertion order while small
        if outside.count > 4 fatal("openmp-opt: more than 4 outside users of a sequential region value (SmallPtrSet iteration order) is not supported yet");
        ty := vtype(x);
        alloca_i := create_alloca_unlinked(ty, dl.alloca_as, dl_pref_align(ty));
        e := fn_entry(outer_fn);
        if block_first(e) != NONE insert_before_named(alloca_i, block_first(e), tconcat(vname(x), ".seq.output.alloc"));
        else insert_at_end_named(alloca_i, e, tconcat(vname(x), ".seq.output.alloc"));
        omp_insert_before(create_store_raw(x, alloca_i, dl_abi_align(ty)), block_terminator(seq_start_bb));
        for usr: outside {
            ld := new_inst(.LOAD, ty, 1);
            set_op(ld, 0, alloca_i);
            inst(ld).align = dl_abi_align(ty);
            omp_insert_before(ld, usr, tconcat(vname(x), ".seq.output.load"));
            replace_uses_of_with(usr, x, ld);
        }
    }
    after_bb, after_pt := omp_create_master(parent_bb, dl_md, seq_start_bb, seq_end_bb);
    after_bb, after_pt = omp_create_barrier(after_bb, after_pt, NONE);
    insert_at_end_named(create_br(seq_after_bb), after_bb, "");
}

// Merge(MergableCIs, BB)
omp_merge :: (cis: [] Value_Id, bb: Value_Id) {
    original_fn := block_fn(bb);
    end_bb := split_block(bb, inst_next(cis[cis.count - 1]), null, null);
    after_bb := split_block(end_bb, block_first_insertion_pt(end_bb), null, null);
    start_bb := split_block(bb, cis[0], null, null, null, "omp.par.merged");
    if block_unique_successor(bb) != start_bb fatal("internal: openmp-opt: expected a different CFG");
    dl_md := get_metadata(block_terminator(bb), MDK_DBG);
    erase_inst(block_terminator(bb));
    for k: 0..cis.count - 2 {
        fork := cis[k];
        next := cis[k + 1];
        if inst_next(fork) == next continue;
        omp_create_sequential_region(original_fn, inst_next(fork), inst_prev(next));
    }
    entry := fn_entry(original_fn);
    after_ip_bb := omp_create_parallel(bb, dl_md, entry, start_bb, end_bb);
    insert_at_end_named(create_br(after_bb), after_ip_bb, "");
    omp_finalize(original_fn);
    outlined := inst_fn(cis[0]);
    parallel_task := type_func(ir.t_void, .[ir.t_ptr, ir.t_ptr], true);   // OpenMPIRBuilder::ParallelTask
    for ci, k: cis {
        callee := call_arg(ci, 2);
        args: [..] Value_Id; args.allocator = temp;
        array_add(*args, fn_arg(outlined, 0));
        array_add(*args, fn_arg(outlined, 1));
        for a: 3..cast(s64) call_num_args(ci) - 1 array_add(*args, call_arg(ci, cast(u32) a));
        nci := new_inst(.CALL, ir.t_void, cast(u32) (args.count + 1));
        inst(nci).ty2 = parallel_task;
        for args set_op(nci, cast(u32) it_index, it);
        set_op(nci, cast(u32) args.count, callee);
        omp_insert_before(nci, ci);
        d := get_metadata(ci, MDK_DBG);
        if d != NONE set_metadata(nci, MDK_DBG, d);
        // forward the callback arguments' parameter attributes
        for a: 3..cast(s64) call_num_args(ci) - 1 {
            pa := attr_list_param(inst(ci).attrs, cast(u32) a);
            for at: attr_set_items(pa) call_add_param_attr(nci, cast(u32) (a - 1), at);
        }
        if k != cis.count - 1 omp_create_barrier(inst_block(nci), inst_next(nci), NONE);
        erase_inst(ci);
    }
    // CGUpdater.registerOutlinedFunction / reanalyzeFunction
    if !oo.is_module_pass omp_cg_register_outlined_function(original_fn, outlined);
}

// CallGraphUpdater::registerOutlinedFunction + reanalyzeFunction in the CGSCC pass
omp_cg_register_outlined_function :: (original: Value_Id, outlined: Value_Id) {
    n := lcg_lookup(original);
    if n < 0 return;
    lcg_add_split_function(original, outlined);
    oo.cgscc_c = update_cg_and_am_for_pass(oo.cgscc_c, n, oo.cgscc_ur, false);
}
