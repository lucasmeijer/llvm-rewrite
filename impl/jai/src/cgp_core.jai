// CodeGenPrepare, part 1: port of llvm/lib/CodeGen/CodeGenPrepare.cpp (the CodeGenPrepare driver `_run`,
// eliminateAssumptions, eliminateFallThrough, eliminateMostlyEmptyBlocks and helpers, SinkCast /
// OptimizeNoopCopyExpression, the compare optimizations (sinkCmpExpression, combineToU{Add,Sub}WithOverflow,
// unfoldPowerOf2Test, foldICmpWithDominatingICmp, swapICmpOperandsToExposeCSEOpportunities, foldFCmpToFPClassTest,
// foldURemOfLoopIncrement), sinkAndCmp0Expression, despeculateCountZeros, optimizeCallInst,
// dupRetToEnableTailCallOpts, optimizeInst / optimizeBlock, makeBitReverse, the debug-record fixups, placeDbgValues,
// placePseudoProbes, splitBranchCondition) with the X86TargetLowering hooks it queries.
// The other parts: cgp_addr.jai (address-mode matching and sinking), cgp_ext.jai (extension promotion, sext
// merging, large GEP offsets, phi types), cgp_misc.jai (select / shift / shuffle / switch / extractelement /
// store splitting / branch), bypass_slow_division.jai.

Cgp_Modify_Dt :: enum u8 { NOT_MODIFY_DT; MODIFY_BB_DT; MODIFY_INST_DT; }

Cgp_State :: struct {
    f: Value_Id;
    t: *Tti;
    xl: *X86_Lowering;
    dtu: Dtu;
    li: *Loop_Info;
    bfi: *Bfi;
    opt_size: bool;
    is_huge_func: bool;
    // CurInstIterator: the next instruction to optimize in the current block (NONE = end)
    cur_inst: Value_Id;
    cur_bb: Value_Id;
    sunk_addrs: Table(Value_Id, Vh);              // SunkAddrs (values are WeakTrackingVHs)
    inserted_insts: Table(Value_Id, bool);        // InsertedInsts
    promoted_insts: Table(Value_Id, Cgp_Orig_Ty); // PromotedInsts
    removed_insts: [..] Value_Id;                 // RemovedInsts (already unlinked; nothing to free here)
    seen_chains_for_sext: Table(Value_Id, Value_Id);
    // LargeOffsetGEPMap (MapVector: keys in insertion order), LargeOffsetGEPID, NewGEPBases
    lgep_keys: [..] Value_Id;
    lgep_vals: [..] [..] Cgp_Gep_Off;
    lgep_id: Table(Value_Id, s64);
    new_gep_bases: [..] Value_Id;
    // ValToSExtendedUses (MapVector)
    sext_keys: [..] Value_Id;
    sext_vals: [..] [..] Value_Id;
    fresh_bbs: Table(Value_Id, bool);
}
Cgp_Orig_Ty :: struct { ty: Type_Id; ext: u8; }   // ext: CGP_ZEXT / CGP_SEXT / CGP_BOTH_EXT
CGP_ZEXT :: 0; CGP_SEXT :: 1; CGP_BOTH_EXT :: 2;
Cgp_Gep_Off :: struct { gep: Value_Id; off: s64; }

cgp: Cgp_State;

// cl::opts of CodeGenPrepare.cpp (defaults)
cgp_cl: struct {
    disable_branch_opts := false;          // -disable-cgp-branch-opts
    disable_gc_opts := false;              // -disable-cgp-gc-opts
    disable_select_to_branch := false;     // -disable-cgp-select2branch
    addr_sink_using_geps := true;          // -addr-sink-using-gep
    verify_bfi_updates := false;           // -cgp-verify-bfi-updates
    enable_and_cmp_sinking := true;        // -enable-andcmp-sinking
    disable_store_extract := false;        // -disable-cgp-store-extract
    stress_store_extract := false;         // -stress-cgp-store-extract
    disable_ext_ld_promotion := false;     // -disable-cgp-ext-ld-promotion
    stress_ext_ld_promotion := false;      // -stress-cgp-ext-ld-promotion
    disable_preheader_protect := false;    // -disable-preheader-prot
    freq_ratio_to_skip_merge: u64 = 2;     // -cgp-freq-ratio-to-skip-merge
    force_split_store := false;            // -force-split-store
    enable_type_promotion_merge := true;   // -cgp-type-promotion-merge
    disable_complex_addr_modes := false;   // -disable-complex-addr-modes
    addr_sink_new_phis := false;           // -addr-sink-new-phis
    addr_sink_new_selects := true;         // -addr-sink-new-select
    addr_sink_combine_base_reg := true;
    addr_sink_combine_base_gv := true;
    addr_sink_combine_base_offs := true;
    addr_sink_combine_scaled_reg := true;
    enable_gep_offset_split := true;       // -cgp-split-large-offset-gep
    enable_icmp_eq_to_icmp_st := false;    // -cgp-icmp-eq2icmp-st
    optimize_phi_types := true;            // -cgp-optimize-phi-types
    huge_func_threshold: u64 = 10000;      // -cgpp-huge-func
    max_address_users_to_scan: u64 = 100;  // -cgp-max-address-users-to-scan
    disable_delete_phis := false;          // -disable-cgp-delete-phis
}

// ---------------------------------------------------------------- X86TargetLowering hooks used by CGP

cgp_evt :: (ty: Type_Id, allow_unknown := false) -> Evt { _, e := x86_value_type(cgp.xl, ty, allow_unknown); return e; }
// X86TargetLowering::useSoftFloat
cgp_use_soft_float :: () -> bool { return st_useSoftFloat(cgp.xl); }
// X86TargetLowering::isTruncateFree(Type*, Type*)
cgp_is_truncate_free :: (t1: Type_Id, t2: Type_Id) -> bool {
    if type_kind(t1) != .INT || type_kind(t2) != .INT return false;
    return type_bits(t1) > type_bits(t2);
}
// X86TargetLowering::isZExtFree(Type*, Type*)
cgp_is_zext_free :: (t1: Type_Id, t2: Type_Id) -> bool {
    return type_kind(t1) == .INT && type_bits(t1) == 32 && type_kind(t2) == .INT && type_bits(t2) == 64 && st_is64Bit(cgp.xl);
}
// X86TargetLowering::shouldFormOverflowOp
cgp_should_form_overflow_op :: (isd: u32, vt: Evt, math_used: bool) -> bool {
    if evt_is_vector(vt) return false;
    return evt_is_simple(vt) || !cgp_is_operation_expand(isd, vt);
}
cgp_is_operation_expand :: (isd: u32, vt: Evt) -> bool {
    // TargetLoweringBase::isOperationExpand: !isTypeLegal(VT) || getOperationAction(Op, VT) == Expand
    if !xl_is_type_legal(cgp.xl, vt) return true;
    return is_op_expand(cgp.xl, isd, vt.m);
}
// TargetLoweringBase::isOperationLegalOrCustom(Op, VT, LegalOnly=false)
cgp_is_operation_legal_or_custom :: (isd: u32, vt: Evt) -> bool {
    if vt.m == MVT_isVoid return is_op_legal_or_custom(cgp.xl, isd, vt.m);
    return xl_is_type_legal(cgp.xl, vt) && is_op_legal_or_custom(cgp.xl, isd, vt.m);
}
// X86TargetLowering::isCheapToSpeculateCttz / Ctlz
cgp_is_cheap_to_speculate_cttz :: (ty: Type_Id) -> bool {
    st := cgp.xl;
    return st_hasBMI(st) || st_canUseCMOV(st) || cgp_has_bit_scan_pass_through(st) ||
           (!is_vector_type(ty) && type_bits(scalar_type(ty)) < (ifx st_is64Bit(st) then cast(u32) 64 else 32));
}
cgp_is_cheap_to_speculate_ctlz :: (ty: Type_Id) -> bool {
    st := cgp.xl;
    return st_hasLZCNT(st) || st_canUseCMOV(st) || cgp_has_bit_scan_pass_through(st);
}
// mayTailCallThisCC / canGuaranteeTCO (X86ISelLoweringCall.cpp)
cgp_may_tail_call_cc :: (cc: u32) -> bool {
    // C 0, Fast 8, GHC 10, HiPE 11, Swift 16, Tail 18, SwiftTail 20, PreserveNone 21, X86_StdCall 64,
    // X86_FastCall 65, X86_ThisCall 70, X86_64_SysV 78, Win64 79, X86_VectorCall 80, X86_RegCall 92
    if cc == 0 || cc == 79 || cc == 78 || cc == 21 || cc == 70 || cc == 64 || cc == 80 || cc == 65 || cc == 16 return true;
    return cc == 8 || cc == 10 || cc == 92 || cc == 11 || cc == 18 || cc == 20;
}
cgp_call_is_tail_call :: (ci: Value_Id) -> bool {
    k := (inst(ci).flags >> TAIL_SHIFT) & 3;
    return k == 1 || k == 2;
}
// X86TargetLowering::mayBeEmittedAsTailCall
cgp_may_be_emitted_as_tail_call :: (ci: Value_Id) -> bool {
    if !cgp_call_is_tail_call(ci) return false;
    return cgp_may_tail_call_cc(inst(ci).cc);
}
// attributesPermitTailCall (CodeGen/Analysis.cpp)
cgp_attributes_permit_tail_call :: (f: Value_Id, i: Value_Id) -> bool {
    benign :: Attr_Kind.[.Alignment, .Dereferenceable, .DereferenceableOrNull, .NoAlias, .NonNull, .NoUndef, .Range, .NoFPClass];
    caller := attr_set_remove_kinds(attr_list_ret(glob(f).attrs), benign);
    callee := attr_set_remove_kinds(attr_list_ret(inst(i).attrs), benign);
    if attr_set_has(caller, .ZExt) {
        if !attr_set_has(callee, .ZExt) return false;
        caller = attr_set_remove(caller, .ZExt);
        callee = attr_set_remove(callee, .ZExt);
    } else if attr_set_has(caller, .SExt) {
        if !attr_set_has(callee, .SExt) return false;
        caller = attr_set_remove(caller, .SExt);
        callee = attr_set_remove(callee, .SExt);
    }
    if !has_uses(i) {
        callee = attr_set_remove(callee, .SExt);
        callee = attr_set_remove(callee, .ZExt);
    }
    return caller == callee;
}

// ---------------------------------------------------------------- the pass

cgp_reset :: (f: Value_Id) {
    cgp.f = f;
    cgp.cur_inst = NONE; cgp.cur_bb = NONE;
    table_reset(*cgp.sunk_addrs);
    table_reset(*cgp.inserted_insts);
    table_reset(*cgp.promoted_insts);
    cgp.removed_insts.count = 0;
    table_reset(*cgp.seen_chains_for_sext);
    cgp_lgep_clear();
    cgp.new_gep_bases.count = 0;
    cgp_sext_uses_clear();
    table_reset(*cgp.fresh_bbs);
}

// CodeGenPrepareLegacyPass::runOnFunction
codegenprepare_run :: (f: Value_Id) -> Preserved {
    if cg_skip_function(f) return PRESERVE_ALL;
    t := tti_get(f);
    if t.kind != .X86 fatal("codegenprepare: a target machine is required");
    cgp_reset(f);
    cgp.t = t;
    cgp.xl = *t.xl;
    cgp.li = get_loop_info(f);
    get_bpi(f);
    cgp.bfi = get_bfi(f);
    cgp.dtu = .{};
    cgp.dtu.dt = get_domtree(f);
    cgp.dtu.lazy = true;
    cgp.dtu.pending.allocator = temp; cgp.dtu.deleted.allocator = temp; cgp.dtu.deleted_set.allocator = temp;
    changed := cgp_run(f);
    vh_release_all();
    cgp_reset(NONE);
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}

cgp_get_dt :: () -> *Dom_Tree { return dtu_get_dom_tree(*cgp.dtu); }

cgp_is_fresh :: (b: Value_Id) -> bool { return table_contains(*cgp.fresh_bbs, b); }
cgp_fresh_insert :: (b: Value_Id) { table_set(*cgp.fresh_bbs, b, true); }
cgp_fresh_erase :: (b: Value_Id) { table_remove(*cgp.fresh_bbs, b); }

// llvm::shouldOptimizeForSize(BB, PSI, BFI). BFI is only needed with a profile summary; it is the function's
// BlockFrequencyInfo as computed when first asked (CGP's own incremental BFI updates are not mirrored).
cgp_should_optimize_for_size :: (bb: Value_Id) -> bool {
    p := psi_get();
    if !p.has_summary return fn_has_opt_size(block_fn(bb));
    return should_optimize_for_size_bb(bb, p, cgp_bfi());
}
cgp_bfi :: () -> *Bfi { if !psi_get().has_summary return null; return get_bfi(cgp.f); }

// CodeGenPrepare::_run
cgp_run :: (f: Value_Id) -> bool {
    ever_made_change := false;
    cgp.opt_size = fn_has_opt_size(f);
    // ProfileGuidedSectionPrefix (no basic-block-sections profile reader); -profile-unknown-in-special-section is off
    p := psi_get();
    if fn_has_fn_attr(f, .Hot) || psi_is_function_hot_in_call_graph(p, f, cgp_bfi()) cgp_set_section_prefix(f, "hot");
    else if psi_is_function_cold_in_call_graph(p, f, cgp_bfi()) || fn_has_fn_attr(f, .Cold) cgp_set_section_prefix(f, "unlikely");

    // bypassSlowDivision (!OptSize, !PSI->hasHugeWorkingSetSize(), TLI->isSlowDivBypassed())
    if !cgp.opt_size && !(p.has_huge && p.huge) && cgp_is_slow_div_bypassed() {
        bb := fn_entry(f);
        while bb != NONE {
            next := block(bb).next;
            if !cgp_should_optimize_for_size(bb) ever_made_change |= bypass_slow_division(bb);
            bb = next;
        }
    }

    ever_made_change |= cgp_eliminate_assumptions(f);

    reset_li := false;
    c, r := cgp_eliminate_mostly_empty_blocks(f);
    ever_made_change |= c;
    if r cgp_reset_loop_info(f);

    if !cgp_cl.disable_branch_opts ever_made_change |= cgp_split_branch_condition(f);

    // SplitIndirectBrCriticalEdges(F, IgnoreBlocksWithoutPHI=true, BPI, BFI, DTU)
    split := cgp_split_indirectbr_critical_edges(f);
    ever_made_change |= split;
    if split cgp_reset_loop_info(f);

    nblocks := 0;
    for fn_blocks(f) nblocks += 1;
    cgp.is_huge_func = cast(u64) nblocks > cgp_cl.huge_func_threshold;

    made_change := true;
    func_iterated := false;
    while made_change {
        made_change = false;
        dtu_flush(*cgp.dtu);
        bb := fn_entry(f);
        while bb != NONE {
            next_bb := block(bb).next;   // make_early_inc_range(F)
            defer bb = next_bb;
            if func_iterated && !cgp_is_fresh(bb) continue;
            modified: Cgp_Modify_Dt = .NOT_MODIFY_DT;
            changed := cgp_optimize_block(bb, *modified);
            made_change |= changed;
            if cgp.is_huge_func {
                if changed cgp_fresh_insert(bb);
                else if func_iterated cgp_fresh_erase(bb);
            } else {
                if modified != .NOT_MODIFY_DT break;
            }
        }
        func_iterated = cgp.is_huge_func;

        if cgp_cl.enable_type_promotion_merge && cgp.sext_keys.count made_change |= cgp_merge_sexts(f);
        if cgp.lgep_keys.count made_change |= cgp_split_large_gep_offsets();
        made_change |= cgp_optimize_phi_types(f);

        if made_change cgp_eliminate_fall_through(f);

        ever_made_change |= made_change;
        table_reset(*cgp.seen_chains_for_sext);
        cgp_sext_uses_clear();
        cgp.removed_insts.count = 0;
        cgp_lgep_clear();
    }
    cgp.new_gep_bases.count = 0;
    table_reset(*cgp.sunk_addrs);

    // LoopInfo is not needed anymore and ConstantFoldTerminator can break it.
    cgp.li = null;

    if !cgp_cl.disable_branch_opts {
        made_change = false;
        worklist: [..] Value_Id; worklist.allocator = temp;   // SmallSetVector
        in_wl: Table(Value_Id, bool); in_wl.allocator = temp;
        for bb: fn_blocks(f) {
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            made_change |= constant_fold_terminator(bb, true, *cgp.dtu);
            if !made_change continue;
            for s: succs if !block_has_predecessors(s) && !table_contains(*in_wl, s) { table_set(*in_wl, s, true); array_add(*worklist, s); }
        }
        made_change |= worklist.count > 0;
        while worklist.count {
            bb := pop(*worklist);
            table_remove(*in_wl, bb);
            succs: [..] Value_Id; succs.allocator = temp;
            block_successors(bb, *succs);
            delete_dead_block(bb, *cgp.dtu);
            for s: succs if !block_has_predecessors(s) && !table_contains(*in_wl, s) { table_set(*in_wl, s, true); array_add(*worklist, s); }
        }
        dtu_flush(*cgp.dtu);
        if ever_made_change || made_change made_change |= cgp_eliminate_fall_through(f);
        ever_made_change |= made_change;
    }

    if !cgp_cl.disable_gc_opts {
        for i: fn_insts(f) if call_iid(i) == IID_EXPERIMENTAL_GC_STATEPOINT
            fatal("codegenprepare: gc.statepoint relocations (simplifyOffsetableRelocate) are not supported yet");
    }

    ever_made_change |= cgp_place_dbg_values(f);
    ever_made_change |= cgp_place_pseudo_probes(f);
    return ever_made_change;
}

// resetLoopInfo: LI->releaseMemory(); LI->analyze(DTU->getDomTree())
cgp_reset_loop_info :: (f: Value_Id) {
    dt := cgp_get_dt();
    fam_invalidate_one(f, .LOOPS);
    cgp.li = get_loop_info(f);   // analyzes the cached DominatorTree, which is the DTU's
}

// TargetLoweringBase::isSlowDivBypassed (X86TargetLowering's constructor, at TM opt level >= Default:
// addBypassSlowDiv(64, 32) for idivq-to-divl on x86-64, addBypassSlowDiv(32, 8) for idivl-to-divb)
cgp_is_slow_div_bypassed :: () -> bool {
    if cg_tm_opt_level < 2 return false;
    return (st_hasSlowDivide64(cgp.xl) && st_is64Bit(cgp.xl)) || st_hasSlowDivide32(cgp.xl);
}

// CodeGenPrepare::eliminateAssumptions
cgp_eliminate_assumptions :: (f: Value_Id) -> bool {
    made_change := false;
    for bb: fn_blocks(f) {
        cgp.cur_bb = bb;
        cgp.cur_inst = block_first(bb);
        while cgp.cur_inst != NONE {
            i := cgp.cur_inst;
            cgp.cur_inst = inst_next(i);
            if call_iid(i) == IID_ASSUME {
                made_change = true;
                operand := op(i, 0);
                erase_inst_with_metadata(i);
                cgp_reset_iterator_if_invalidated_while_calling(bb, operand, 0);
            }
        }
    }
    return made_change;
}

// resetIteratorIfInvalidatedWhileCalling(BB, f) with the callers' f:
//   kind 0: RecursivelyDeleteTriviallyDeadInstructions(Operand, TLInfo, nullptr)
//   kind 1: replaceAndRecursivelySimplify(CI, RetVal = true, TLInfo, nullptr)
cgp_reset_iterator_if_invalidated_while_calling :: (bb: Value_Id, v: Value_Id, kind: int, v2: Value_Id = NONE) {
    cur := cgp.cur_inst;
    h: Vh = 0;
    has_h := cur != NONE;
    if has_h h = vh_new(cur);
    if kind == 0 cgp_recursively_delete_trivially_dead(v);
    else {
        q: Simplify_Query;
        q.have_tli = true;
        replace_and_recursively_simplify(v, v2, q);
    }
    // the iterator at end() is a sentinel that can't be deleted
    if has_h && vh_get(h) != cur {
        cgp.cur_inst = block_first(bb);
        table_reset(*cgp.sunk_addrs);
    }
}

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI, MSSAU = nullptr, AboutToDeleteCallback)
cgp_recursively_delete_trivially_dead :: (v: Value_Id) -> bool {
    if !is_inst(v) || has_uses(v) || !is_instruction_trivially_dead(v) return false;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        cgp_remove_all_asserting_vh_references(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o != NONE && is_inst(o) && !has_uses(o) && is_instruction_trivially_dead(o) array_add(*dead, o);
        }
        erase_inst_with_metadata(i);
    }
    return true;
}

// ---------------------------------------------------------------- LargeOffsetGEPMap / ValToSExtendedUses helpers

cgp_lgep_clear :: () {
    cgp.lgep_keys.count = 0;
    for * cgp.lgep_vals it.count = 0;
    cgp.lgep_vals.count = 0;
    table_reset(*cgp.lgep_id);
}
cgp_lgep_find :: (k: Value_Id) -> s64 { for cgp.lgep_keys if it == k return it_index; return -1; }
cgp_lgep_get :: (k: Value_Id) -> *[..] Cgp_Gep_Off {
    i := cgp_lgep_find(k);
    if i >= 0 return *cgp.lgep_vals[i];
    array_add(*cgp.lgep_keys, k);
    e: [..] Cgp_Gep_Off;
    array_add(*cgp.lgep_vals, e);
    return *cgp.lgep_vals[cgp.lgep_vals.count - 1];
}
cgp_lgep_erase :: (k: Value_Id) {
    i := cgp_lgep_find(k);
    if i < 0 return;
    array_ordered_remove_by_index(*cgp.lgep_keys, i);
    array_ordered_remove_by_index(*cgp.lgep_vals, i);
}
cgp_sext_uses_clear :: () {
    cgp.sext_keys.count = 0;
    cgp.sext_vals.count = 0;
}
cgp_sext_uses_get :: (k: Value_Id) -> *[..] Value_Id {
    for cgp.sext_keys if it == k return *cgp.sext_vals[it_index];
    array_add(*cgp.sext_keys, k);
    e: [..] Value_Id;
    array_add(*cgp.sext_vals, e);
    return *cgp.sext_vals[cgp.sext_vals.count - 1];
}

// removeAllAssertingVHReferences
cgp_remove_all_asserting_vh_references :: (v: Value_Id) {
    cgp_lgep_erase(v);
    for cgp.new_gep_bases if it == v { array_ordered_remove_by_index(*cgp.new_gep_bases, it_index); break; }
    if !is_inst(v) || inst_op(v) != .GEP return;
    table_remove(*cgp.lgep_id, v);
    k := cgp_lgep_find(op(v, 0));
    if k < 0 return;
    vec := *cgp.lgep_vals[k];
    i := 0;
    while i < vec.count { if vec.*[i].gep == v array_ordered_remove_by_index(vec, i); else i += 1; }
    if vec.count == 0 { array_ordered_remove_by_index(*cgp.lgep_keys, k); array_ordered_remove_by_index(*cgp.lgep_vals, k); }
}

// ---------------------------------------------------------------- block merging

// MergeBlockIntoPredecessor(BB, DTU (lazy), LI)
cgp_merge_block_into_predecessor :: (bb: Value_Id) -> bool {
    l: Lazy_Dtu;
    l.dt = cgp.dtu.dt;
    l.pending.allocator = temp; l.deleted.allocator = temp;
    ok := merge_block_into_predecessor(bb, cgp.dtu.dt, cgp.li, null, false, *l);
    for l.pending array_add(*cgp.dtu.pending, it);
    for l.deleted if !table_contains(*cgp.dtu.deleted_set, it) { table_set(*cgp.dtu.deleted_set, it, true); array_add(*cgp.dtu.deleted, it); }
    return ok;
}

// CodeGenPrepare::eliminateFallThrough
cgp_eliminate_fall_through :: (f: Value_Id) -> bool {
    changed := false;
    preds: [..] Value_Id; preds.allocator = temp;   // SmallPtrSet (iteration order of the set: insertion here)
    first := true;
    blocks: [..] Value_Id; blocks.allocator = temp;
    for fn_blocks(f) array_add(*blocks, it);
    // `for (auto &Block : llvm::drop_begin(F))` with blocks erased only lazily (DTU), so a snapshot is the same walk
    for bb: blocks {
        if it_index == 0 continue;
        if vkind(bb) == .DEAD || dtu_is_bb_pending_deletion(*cgp.dtu, bb) continue;
        single_pred := block_single_predecessor(bb);
        if single_pred == NONE || single_pred == bb || block_has_address_taken(bb) continue;
        if inst_op(block_terminator(single_pred)) == .BR {
            changed = true;
            cgp_merge_block_into_predecessor(bb);
            seen := false;
            for preds if it == single_pred seen = true;
            if !seen array_add(*preds, single_pred);
            if cgp.is_huge_func { cgp_fresh_insert(single_pred); cgp_fresh_erase(bb); }
        }
    }
    for p: preds if !dtu_is_bb_pending_deletion(*cgp.dtu, p) remove_redundant_dbg_instrs(p);
    return changed;
}

// findDestBlockOfMergeableEmptyBlock
cgp_find_dest_block_of_mergeable_empty_block :: (bb: Value_Id) -> Value_Id {
    bi := block_terminator(bb);
    if bi == NONE || inst_op(bi) != .BR return NONE;
    if bi != block_first(bb) {
        p := inst_prev(bi);
        if inst_op(p) != .PHI return NONE;
    }
    dest := get_successor(bi, 0);
    if dest == bb return NONE;
    if !cgp_can_merge_blocks(bb, dest) dest = NONE;
    return dest;
}

// DeleteDeadPHIs(BB, TLI, nullptr, KnownNonDeadPHIs)
cgp_delete_dead_phis :: (bb: Value_Id, known: *Table(Value_Id, bool)) -> bool {
    phis: [..] Vh; phis.allocator = temp;
    for pn: block_insts(bb) { if inst_op(pn) != .PHI break; array_add(*phis, vh_new(pn)); }
    changed := false;
    for h: phis {
        pn := vh_get(h);
        if pn == NONE || !is_phi(pn) continue;
        c := ivs_recursively_delete_dead_phi_node(pn, null, known);
        changed |= c;
        if c table_reset(known);
    }
    return changed;
}

// eliminateMostlyEmptyBlocks -> (MadeChange, ResetLI)
cgp_eliminate_mostly_empty_blocks :: (f: Value_Id) -> (bool, bool) {
    preheaders: Table(Value_Id, bool); preheaders.allocator = temp;
    loop_list: [..] Loop_Id; loop_list.allocator = temp;
    for cgp.li.top_level array_add(*loop_list, it);
    while loop_list.count {
        l := pop(*loop_list);
        for cgp.li.loops[l].subloops array_add(*loop_list, it);
        ph := li_loop_preheader(cgp.li, l);
        if ph != NONE table_set(*preheaders, ph, true);
    }
    reset_li := false;
    made_change := false;
    known: Table(Value_Id, bool); known.allocator = temp;
    first := true;
    for bb: fn_blocks(f) {
        if first { first = false; continue; }
        if !cgp_cl.disable_delete_phis made_change |= cgp_delete_dead_phis(bb, *known);
    }
    blocks: [..] Value_Id; blocks.allocator = temp;
    for fn_blocks(f) array_add(*blocks, it);
    for bb: blocks {
        if it_index == 0 continue;
        if vkind(bb) == .DEAD || dtu_is_bb_pending_deletion(*cgp.dtu, bb) continue;
        dest := cgp_find_dest_block_of_mergeable_empty_block(bb);
        if dest == NONE || !cgp_is_merging_empty_block_profitable(bb, dest, table_contains(*preheaders, bb)) continue;
        reset_li |= cgp_eliminate_mostly_empty_block(bb);
        made_change = true;
    }
    return made_change, reset_li;
}

// isMergingEmptyBlockProfitable
cgp_is_merging_empty_block_profitable :: (bb: Value_Id, dest: Value_Id, is_preheader: bool) -> bool {
    if !cgp_cl.disable_preheader_protect && is_preheader {
        sp := block_single_predecessor(bb);
        if !(sp != NONE && block_single_successor(sp) != NONE) return false;
    }
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        t := block_terminator(p);
        if inst_op(t) == .CALLBR {
            for k: 0..cast(s64) num_successors(t) - 1 if get_successor(t, cast(u32) k) == dest return false;
        }
    }
    pred := block_unique_predecessor(bb);
    if pred == NONE return true;
    pt := inst_op(block_terminator(pred));
    if !(pt == .SWITCH || pt == .INDIRECTBR) return true;
    if block_terminator(bb) != block_first_non_phi_or_dbg(bb) return true;
    if !is_phi(block_first(dest)) return true;

    same: [..] Value_Id; same.allocator = temp;   // SmallPtrSet: membership and (for the sum) iteration
    dpreds: [..] Value_Id; dpreds.allocator = temp;
    block_predecessors(dest, *dpreds);
    for dp: dpreds {
        if dp == bb continue;
        all := true;
        for pn: block_insts(dest) {
            if inst_op(pn) != .PHI break;
            if phi_incoming_value_for_block(pn, bb) != phi_incoming_value_for_block(pn, dp) { all = false; break; }
        }
        if all {
            seen := false;
            for same if it == dp seen = true;
            if !seen array_add(*same, dp);
        }
    }
    for same if it == pred return true;
    pred_freq := bfi_get_block_freq(cgp.bfi, pred);
    bb_freq := bfi_get_block_freq(cgp.bfi, bb);
    // SmallPtrSet iteration order is pointer order; the sum does not depend on it
    for s: same {
        if block_unique_predecessor(s) == pred && dest == cgp_find_dest_block_of_mergeable_empty_block(s)
            bb_freq += bfi_get_block_freq(cgp.bfi, s);
    }
    // BlockFrequency::mul: saturating multiply, nullopt on overflow
    hi, lo := mul_u64_full(bb_freq, cgp_cl.freq_ratio_to_skip_merge);
    if hi != 0 return true;
    return pred_freq <= lo;
}
// canMergeBlocks
cgp_can_merge_blocks :: (bb: Value_Id, dest: Value_Id) -> bool {
    for pn: block_insts(bb) {
        if inst_op(pn) != .PHI break;
        u := ir.v_first_use[pn];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            if inst_block(ui) != dest || inst_op(ui) != .PHI return false;
            n := nops(ui);
            for k: 0..cast(s64) n - 1 {
                insn := phi_value(ui, cast(u32) k);
                if is_inst(insn) && inst_block(insn) == bb && inst_block(insn) != phi_block(ui, cast(u32) k) return false;
            }
        }
    }
    dpn := block_first(dest);
    if dpn == NONE || inst_op(dpn) != .PHI return true;
    bb_preds: [..] Value_Id; bb_preds.allocator = temp;
    bpn := block_first(bb);
    if bpn != NONE && inst_op(bpn) == .PHI {
        for k: 0..cast(s64) nops(bpn) - 1 array_add(*bb_preds, phi_block(bpn, cast(u32) k));
    } else block_predecessors(bb, *bb_preds);
    for k: 0..cast(s64) nops(dpn) - 1 {
        pred := phi_block(dpn, cast(u32) k);
        common := false;
        for bb_preds if it == pred { common = true; break; }
        if !common continue;
        for pn: block_insts(dest) {
            if inst_op(pn) != .PHI break;
            v1 := phi_incoming_value_for_block(pn, pred);
            v2 := phi_incoming_value_for_block(pn, bb);
            if is_phi(v2) && inst_block(v2) == bb v2 = phi_incoming_value_for_block(v2, pred);
            if v1 != v2 return false;
        }
    }
    return true;
}

// static replaceAllUsesWith(Old, New, FreshBBs, IsHuge)
cgp_rauw :: (old: Value_Id, new: Value_Id) {
    if cgp.is_huge_func && is_inst(old) {
        u := ir.v_first_use[old];
        while u != NONE { cgp_fresh_insert(inst_block(ir.u_user[u])); u = ir.u_next[u]; }
    }
    rauw_with_metadata(old, new);
}

// eliminateMostlyEmptyBlock: true if the LoopInfo was not updated
cgp_eliminate_mostly_empty_block :: (bb: Value_Id) -> bool {
    bi := block_terminator(bb);
    dest := get_successor(bi, 0);
    single_pred := block_single_predecessor(dest);
    if single_pred != NONE && single_pred != dest {
        cgp_merge_block_into_predecessor(dest);
        if cgp.is_huge_func { cgp_fresh_insert(single_pred); cgp_fresh_erase(dest); }
        return false;
    }
    bb_preds: [..] Value_Id; bb_preds.allocator = temp;
    block_predecessors(bb, *bb_preds);
    for pn: block_insts(dest) {
        if inst_op(pn) != .PHI break;
        in_val := phi_remove_incoming_block(pn, bb, false);
        if is_phi(in_val) && inst_block(in_val) == bb {
            n := nops(in_val);
            for k: 0..cast(s64) n - 1 phi_add_incoming(pn, phi_value(in_val, cast(u32) k), phi_block(in_val, cast(u32) k));
        } else {
            bbpn := block_first(bb);
            if bbpn != NONE && inst_op(bbpn) == .PHI {
                for k: 0..cast(s64) nops(bbpn) - 1 phi_add_incoming(pn, in_val, phi_block(bbpn, cast(u32) k));
            } else {
                for bb_preds phi_add_incoming(pn, in_val, it);
            }
        }
    }
    loop_md := get_metadata(bi, md_kind_id("llvm.loop"));
    if loop_md != NONE {
        for bb_preds set_metadata(block_terminator(it), md_kind_id("llvm.loop"), loop_md);
    }
    updates: [..] Dom_Update; updates.allocator = temp;
    dest_preds: [..] Value_Id; dest_preds.allocator = temp;
    block_predecessors(dest, *dest_preds);
    seen: [..] Value_Id; seen.allocator = temp;
    for p: bb_preds {
        in_dest := false;
        for dest_preds if it == p { in_dest = true; break; }
        if in_dest continue;
        dup := false;
        for seen if it == p { dup = true; break; }
        if dup continue;
        array_add(*seen, p);
        array_add(*updates, .{true, p, dest});
    }
    seen.count = 0;
    for p: bb_preds {
        dup := false;
        for seen if it == p { dup = true; break; }
        if dup continue;
        array_add(*seen, p);
        array_add(*updates, .{false, p, bb});
    }
    array_add(*updates, .{false, bb, dest});
    replace_all_uses_with(bb, dest);
    dtu_apply(*cgp.dtu, updates);
    dtu_delete_bb(*cgp.dtu, bb);
    return true;
}

// ---------------------------------------------------------------- casts

// SinkCast
cgp_sink_cast :: (ci: Value_Id) -> bool {
    def_bb := inst_block(ci);
    inserted: Table(Value_Id, Value_Id); inserted.allocator = temp;
    made_change := false;
    u := ir.v_first_use[ci];
    while u != NONE {
        user := ir.u_user[u];
        user_bb := inst_block(user);
        if inst_op(user) == .PHI user_bb = ir.u_aux[u];
        nx := ir.u_next[u];
        defer u = nx;
        if is_eh_pad(user) continue;
        if is_eh_pad(block_terminator(user_bb)) continue;
        if user_bb == def_bb continue;
        found, ic := table_find(*inserted, user_bb);
        if !found {
            pt := block_first_insertion_pt(user_bb);
            ic = ic_clone_inst(ci);
            insert_at_position(ic, user_bb, pt, true);   // getFirstInsertionPt() carries the head bit
            table_set(*inserted, user_bb, ic);
        }
        use_set(u, ic);
        made_change = true;
    }
    if !has_uses(ci) {
        salvage_debug_info(ci);
        erase_inst_with_metadata(ci);
        made_change = true;
    }
    return made_change;
}

// OptimizeNoopCopyExpression
cgp_optimize_noop_copy_expression :: (ci: Value_Id) -> bool {
    if inst_op(ci) == .ADDRSPACECAST {
        // TargetLoweringBase::isFreeAddrSpaceCast = TM.isNoopAddrSpaceCast (X86: both address spaces below 256)
        if !(ptr_addrspace(vtype(op(ci, 0))) < 256 && ptr_addrspace(vtype(ci)) < 256) return false;
    }
    src_vt := cgp_evt(vtype(op(ci, 0)));
    dst_vt := cgp_evt(vtype(ci));
    if evt_is_int(src_vt) != evt_is_int(dst_vt) return false;
    if evt_bits(src_vt) < evt_bits(dst_vt) return false;
    if xl_type_action(cgp.xl, src_vt) == TA_PROMOTE_INTEGER src_vt = xl_type_to_transform_to(cgp.xl, src_vt);
    if xl_type_action(cgp.xl, dst_vt) == TA_PROMOTE_INTEGER dst_vt = xl_type_to_transform_to(cgp.xl, dst_vt);
    if !evt_eq(src_vt, dst_vt) return false;
    return cgp_sink_cast(ci);
}

// ---------------------------------------------------------------- induction increments

// matchIncrement -> (ok, LHS, Step)
cgp_match_increment :: (iv_inc: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !is_inst(iv_inc) return false, NONE, NONE;
    o := inst_op(iv_inc);
    if o == .ADD && is_inst(op(iv_inc, 0)) && is_const(op(iv_inc, 1)) return true, op(iv_inc, 0), op(iv_inc, 1);
    if o == .EXTRACTVALUE && cgp_ev_index0(iv_inc) {
        a := op(iv_inc, 0);
        if call_iid(a) == IID_UADD_WITH_OVERFLOW && is_inst(call_arg(a, 0)) && is_const(call_arg(a, 1)) return true, call_arg(a, 0), call_arg(a, 1);
    }
    if o == .SUB && is_inst(op(iv_inc, 0)) && is_const(op(iv_inc, 1)) return true, op(iv_inc, 0), ce_neg(op(iv_inc, 1));
    if o == .EXTRACTVALUE && cgp_ev_index0(iv_inc) {
        a := op(iv_inc, 0);
        if call_iid(a) == IID_USUB_WITH_OVERFLOW && is_inst(call_arg(a, 0)) && is_const(call_arg(a, 1)) return true, call_arg(a, 0), ce_neg(call_arg(a, 1));
    }
    return false, NONE, NONE;
}
// m_ExtractValue<0>: exactly one index, 0
cgp_ev_index0 :: (ev: Value_Id) -> bool { return inst(ev).nidx == 1 && ir.u32_pool[inst(ev).idx] == 0; }

// getIVIncrement -> (ok, IVInc, Step)
cgp_get_iv_increment :: (pn: Value_Id) -> (bool, Value_Id, Value_Id) {
    l := li_loop_for(cgp.li, inst_block(pn));
    if l == NONE || li_header(cgp.li, l) != inst_block(pn) return false, NONE, NONE;
    latch := li_loop_latch(cgp.li, l);
    if latch == NONE return false, NONE, NONE;
    iv_inc := phi_incoming_value_for_block(pn, latch);
    if !is_inst(iv_inc) || li_loop_for(cgp.li, inst_block(iv_inc)) != l return false, NONE, NONE;
    ok, lhs, step := cgp_match_increment(iv_inc);
    if ok && lhs == pn return true, iv_inc, step;
    return false, NONE, NONE;
}
cgp_is_iv_increment :: (v: Value_Id) -> bool {
    if !is_inst(v) return false;
    ok, lhs, _ := cgp_match_increment(v);
    if !ok return false;
    if is_phi(lhs) {
        ok2, inc, _ := cgp_get_iv_increment(lhs);
        if ok2 return inc == v;
    }
    return false;
}

// ---------------------------------------------------------------- overflow intrinsics

// replaceMathCmpWithIntrinsic
cgp_replace_math_cmp_with_intrinsic :: (bo: Value_Id, arg0: Value_Id, arg1_in: Value_Id, cmp: Value_Id, iid: Intrinsic_Id) -> bool {
    arg1 := arg1_in;
    is_replacable_iv_increment :: (bo: Value_Id, cmp: Value_Id) -> bool {
        if !cgp_is_iv_increment(bo) return false;
        l := li_loop_for(cgp.li, inst_block(bo));
        if li_loop_for(cgp.li, inst_block(cmp)) != l return false;
        dt := cgp_get_dt();
        if dt_dominates(dt, inst_block(cmp), inst_block(bo)) return true;
        return has_one_use(bo) && dt_dominates(dt, inst_block(cmp), li_loop_latch(cgp.li, l));
    }
    if inst_block(bo) != inst_block(cmp) && !is_replacable_iv_increment(bo, cmp) return false;
    if inst_op(bo) == .ADD && iid == IID_USUB_WITH_OVERFLOW arg1 = ce_neg(arg1);
    insert_pt: Value_Id = NONE;
    for it: block_insts(inst_block(cmp)) {
        if (inst_op(bo) != .XOR && it == bo) || it == cmp { insert_pt = it; break; }
    }
    b: Irb;
    irb_set_before(*b, insert_pt);
    math_ov := irb_intrinsic(*b, iid_name(iid), .[vtype(arg0)], .[arg0, arg1]);
    if inst_op(bo) != .XOR {
        math := irb_extract_value(*b, math_ov, .[0], "math");
        cgp_rauw(bo, math);
    }
    ov := irb_extract_value(*b, math_ov, .[1], "ov");
    cgp_rauw(cmp, ov);
    erase_inst_with_metadata(cmp);
    erase_inst_with_metadata(bo);
    return true;
}

// m_UAddWithOverflow(m_Value(A), m_Value(B), m_BinOp(Add)) -> (ok, A, B, Add)
cgp_match_uadd_with_overflow :: (cmp: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    if inst_op(cmp) != .ICMP return false, NONE, NONE, NONE;
    pred := inst_pred(cmp);
    l := op(cmp, 0); r := op(cmp, 1);
    if pred == ICMP_ULT {
        ok, a, b := pm_binop(l, .ADD);
        if ok && (r == a || r == b) return true, a, b, l;
    }
    if pred == ICMP_UGT {
        ok, a, b := pm_binop(r, .ADD);
        if ok && (l == a || l == b) return true, a, b, r;
    }
    if pred == ICMP_ULT && has_one_use(l) {
        ok, x := pm_not(l);
        if ok return true, x, r, l;
    }
    if pred == ICMP_UGT && has_one_use(r) {
        ok, x := pm_not(r);
        if ok return true, x, l, r;
    }
    if pred == ICMP_EQ {
        ok, a, b := pm_binop(l, .ADD);
        if ok && pm_zero_int(r) && (pm_one(a) || pm_one(b)) return true, a, b, l;
        ok2, a2, b2 := pm_binop(r, .ADD);
        if pm_zero_int(l) && ok2 && (pm_one(a2) || pm_one(b2)) return true, a2, b2, r;
    }
    return false, NONE, NONE, NONE;
}

// matchUAddWithOverflowConstantEdgeCases -> (ok, Add)
cgp_match_uadd_with_overflow_constant_edge_cases :: (cmp: Value_Id) -> (bool, Value_Id) {
    a := op(cmp, 0); b := op(cmp, 1);
    if is_const(a) return false, NONE;
    pred := inst_pred(cmp);
    if pred == ICMP_EQ && pm_all_ones(b) b = const_int(vtype(b), 1);
    else if pred == ICMP_NE && pm_zero_int(b) b = cf_all_ones(vtype(b));
    else return false, NONE;
    u := ir.v_first_use[a];
    while u != NONE {
        usr := ir.u_user[u];
        ok, x, y := pm_binop(usr, .ADD);
        if ok && x == a && y == b return true, usr;
        u = ir.u_next[u];
    }
    return false, NONE;
}

// combineToUAddWithOverflow
cgp_combine_to_uadd_with_overflow :: (cmp: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    edge_case := false;
    ok, a, b, add := cgp_match_uadd_with_overflow(cmp);
    if ok && !is_binary_operator(add) ok = false;
    if !ok {
        ok2, add2 := cgp_match_uadd_with_overflow_constant_edge_cases(cmp);
        if !ok2 return false;
        add = add2;
        a = op(add, 0); b = op(add, 1);
        edge_case = true;
    }
    if !cgp_should_form_overflow_op(ISD_UADDO, cgp_evt(vtype(add)), has_n_uses_or_more(add, ifx edge_case then 1 else 2)) return false;
    if inst_block(add) != inst_block(cmp) && !has_one_use(add) return false;
    if !cgp_replace_math_cmp_with_intrinsic(add, a, b, cmp, IID_UADD_WITH_OVERFLOW) return false;
    modified.* = .MODIFY_INST_DT;
    return true;
}

// combineToUSubWithOverflow
cgp_combine_to_usub_with_overflow :: (cmp: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    a := op(cmp, 0); b := op(cmp, 1);
    if is_const(a) && is_const(b) return false;
    pred := inst_pred(cmp);
    if pred == ICMP_UGT { t := a; a = b; b = t; pred = ICMP_ULT; }
    if pred == ICMP_EQ && pm_zero_int(b) { b = const_int(vtype(b), 1); pred = ICMP_ULT; }
    if pred == ICMP_NE && pm_zero_int(b) { t := a; a = b; b = t; pred = ICMP_ULT; }
    if pred != ICMP_ULT return false;
    var_op := ifx is_const(a) then b else a;
    sub: Value_Id = NONE;
    u := ir.v_first_use[var_op];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        ok, x, y := pm_binop(usr, .SUB);
        if ok && x == a && y == b { sub = usr; break; }
        ok2, x2, y2 := pm_binop(usr, .ADD);
        if ok2 && x2 == a {
            ok3, add_c := pm_apint(y2);
            ok4, cmp_c := pm_apint(b);
            if ok3 && ok4 && ap_eq(add_c, ap_neg(cmp_c)) { sub = usr; break; }
        }
    }
    if sub == NONE return false;
    if !cgp_should_form_overflow_op(ISD_USUBO, cgp_evt(vtype(sub)), has_n_uses_or_more(sub, 1)) return false;
    if inst_block(sub) != inst_block(cmp) && !has_one_use(sub) return false;
    if !cgp_replace_math_cmp_with_intrinsic(sub, op(sub, 0), op(sub, 1), cmp, IID_USUB_WITH_OVERFLOW) return false;
    modified.* = .MODIFY_INST_DT;
    return true;
}

// unfoldPowerOf2Test
cgp_unfold_power_of2_test :: (cmp: Value_Id) -> bool {
    if inst_op(cmp) != .ICMP return false;
    pred := inst_pred(cmp);
    ctp := op(cmp, 0);
    if call_iid(ctp) != IID_CTPOP return false;
    x := call_arg(ctp, 0);
    okc, c := pm_apint(op(cmp, 1), true);
    if !okc return false;
    is_strictly := icmp_is_equality(pred) && ap_is_one(c);
    is_or_zero := (pred == ICMP_ULT && ap_eq_u64(c, 2)) || (pred == ICMP_UGT && ap_is_one(c));
    if !is_strictly && !is_or_zero return false;
    op_ty := vtype(x);
    q: Simplify_Query;
    if cgp_is_ctpop_fast(cgp_evt(op_ty)) {
        if !is_strictly || !is_known_non_zero(op(cmp, 0), q) return false;
        if pred == ICMP_EQ {
            set_op(cmp, 1, const_int(op_ty, 2));
            inst(cmp).pred = ICMP_ULT;
        } else inst(cmp).pred = ICMP_UGT;
        return true;
    }
    new_cmp: Value_Id;
    b: Irb;
    irb_set_before(*b, cmp);
    if is_or_zero || (is_strictly && is_known_non_zero(op(cmp, 0), q)) {
        sub := irb_binop(*b, .ADD, x, cf_all_ones(op_ty));
        and := irb_binop(*b, .AND, x, sub);
        np: u8 = ifx pred == ICMP_ULT || pred == ICMP_EQ then cast(u8) ICMP_EQ else cast(u8) ICMP_NE;
        new_cmp = irb_icmp(*b, np, and, const_null_value(op_ty));
    } else {
        sub := irb_binop(*b, .ADD, x, cf_all_ones(op_ty));
        xr := irb_binop(*b, .XOR, x, sub);
        np: u8 = ifx pred == ICMP_EQ then cast(u8) ICMP_UGT else cast(u8) ICMP_ULE;
        new_cmp = irb_icmp(*b, np, xr, sub);
    }
    rauw_with_metadata(cmp, new_cmp);
    cgp_recursively_delete_trivially_dead(cmp);
    return true;
}
// TargetLoweringBase::isCtpopFast: isOperationLegal(ISD::CTPOP, VT) (isTypeLegal && action Legal)
cgp_is_ctpop_fast :: (vt: Evt) -> bool {
    return xl_is_type_legal(cgp.xl, vt) && xl_op_action(cgp.xl, ISD_CTPOP, vt.m) == LA_LEGAL;
}

// sinkCmpExpression
cgp_sink_cmp_expression :: (cmp: Value_Id) -> bool {
    // hasMultipleConditionRegisters: false (base)
    if cgp_use_soft_float() && inst_op(cmp) == .FCMP return false;
    used_in_phi_or_cur := false;
    u := ir.v_first_use[cmp];
    while u != NONE {
        usr := ir.u_user[u];
        if inst_op(usr) == .PHI || inst_block(usr) == inst_block(cmp) { used_in_phi_or_cur = true; break; }
        u = ir.u_next[u];
    }
    t0 := vtype(op(cmp, 0));
    if used_in_phi_or_cur && type_kind(t0) == .INT && type_bits(t0) > cast(u32) dl_largest_legal_int_bits() return false;
    inserted: Table(Value_Id, Value_Id); inserted.allocator = temp;
    made_change := false;
    u = ir.v_first_use[cmp];
    while u != NONE {
        usr := ir.u_user[u];
        nx := ir.u_next[u];
        defer u = nx;
        if inst_op(usr) == .PHI continue;
        user_bb := inst_block(usr);
        if user_bb == inst_block(cmp) continue;
        found, ic := table_find(*inserted, user_bb);
        if !found {
            pt := block_first_insertion_pt(user_bb);
            if inst_op(cmp) == .ICMP ic = create_icmp(inst_pred(cmp), op(cmp, 0), op(cmp, 1));
            else ic = create_fcmp(inst_pred(cmp), op(cmp, 0), op(cmp, 1));   // CmpInst::Create: no flags
            insert_at_position(ic, user_bb, pt, true);   // getFirstInsertionPt() carries the head bit
            set_metadata(ic, 0, get_metadata(cmp, 0));
            table_set(*inserted, user_bb, ic);
        }
        use_set(u, ic);
        made_change = true;
    }
    if !has_uses(cmp) {
        erase_inst_with_metadata(cmp);
        made_change = true;
    }
    return made_change;
}

// foldICmpWithDominatingICmp
cgp_fold_icmp_with_dominating_icmp :: (cmp: Value_Id) -> bool {
    // !EnableICMP_EQToICMP_ST && TLI.isEqualityCmpFoldedWithSignedCmp() (base: true) -> return false
    if !cgp_cl.enable_icmp_eq_to_icmp_st return false;
    fatal("codegenprepare: -cgp-icmp-eq2icmp-st is not supported yet");
    return false;
}

// swapICmpOperandsToExposeCSEOpportunities
cgp_swap_icmp_operands :: (cmp: Value_Id) -> bool {
    op0 := op(cmp, 0); op1 := op(cmp, 1);
    if type_kind(vtype(op0)) != .INT || is_const(op0) || is_const(op1) || op0 == op1 return false;
    good := 0;
    inspected := 0;
    u := ir.v_first_use[op0];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        inspected += 1;
        if inspected > 128 return false;
        ok, x, y := pm_binop(usr, .SUB);
        if ok && x == op1 && y == op0 good += 1;
        else if ok && x == op0 && y == op1 good -= 1;
    }
    if good > 0 {
        // CmpInst::swapOperands: swapped predicate, operands exchanged
        inst(cmp).pred = swapped_predicate(inst_pred(cmp));
        a := op(cmp, 0); b := op(cmp, 1);
        set_op(cmp, 0, b); set_op(cmp, 1, a);
        return true;
    }
    return false;
}

// foldFCmpToFPClassTest
cgp_fold_fcmp_to_fpclass_test :: (cmp: Value_Id) -> bool {
    if inst_op(cmp) != .FCMP return false;
    // isFAbsFree: false (base) -> never skipped
    // fcmpToClassTest(Pred, F, LHS, RHS): RHS must match m_APFloatAllowPoison
    okc, crhs := pm_apfloat(op(cmp, 1), true);
    if !okc return false;
    class_val, class_test := fcmp_to_class_test(inst_pred(cmp), cgp.f, op(cmp, 0), crhs);
    if class_val == NONE return false;
    should :: (t: u32) -> bool { return t == FC_INF || t == (FC_INF | FC_NAN); }
    if !should(class_test) && !should((~class_test) & FC_ALL_FLAGS) return false;
    b: Irb;
    irb_set_before(*b, cmp);
    is_fp := irb_intrinsic(*b, "llvm.is.fpclass", .[vtype(class_val)], .[class_val, const_int(ir.t_i32, class_test)]);
    rauw_with_metadata(cmp, is_fp);
    cgp_recursively_delete_trivially_dead(cmp);
    return true;
}

// isRemOfLoopIncrementWithLoopInvariant -> (ok, RemAmt, AddInst, AddOffset, LoopIncrPN)
cgp_is_rem_of_loop_increment :: (rem: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id) {
    ok, incr, rem_amt := pm_binop(rem, .UREM);
    if !ok return false, NONE, NONE, NONE, NONE;
    add_inst, add_offset: Value_Id = NONE;
    pn: Value_Id = NONE;
    if is_phi(incr) pn = incr;
    else {
        // m_c_NUWAdd(m_Phi(PN), m_Value(AddOffset))
        if !(is_inst(incr) && inst_op(incr) == .ADD && (inst(incr).flags & F_NUW) != 0) return false, NONE, NONE, NONE, NONE;
        if is_phi(op(incr, 0)) { pn = op(incr, 0); add_offset = op(incr, 1); }
        else if is_phi(op(incr, 1)) { pn = op(incr, 1); add_offset = op(incr, 0); }
        else return false, NONE, NONE, NONE, NONE;
        add_inst = incr;
    }
    if pn == NONE return false, NONE, NONE, NONE, NONE;
    if nops(pn) != 2 return false, NONE, NONE, NONE, NONE;
    l := li_loop_for(cgp.li, inst_block(pn));
    if l == NONE || li_loop_preheader(cgp.li, l) == NONE || li_loop_latch(cgp.li, l) == NONE return false, NONE, NONE, NONE, NONE;
    if !li_contains_inst(cgp.li, l, rem) return false, NONE, NONE, NONE, NONE;
    if !li_is_loop_invariant(cgp.li, l, rem_amt) return false, NONE, NONE, NONE, NONE;
    if add_offset != NONE && !li_is_loop_invariant(cgp.li, l, add_offset) return false, NONE, NONE, NONE, NONE;
    oki, iv_inc, step := cgp_get_iv_increment(pn);
    if !oki return false, NONE, NONE, NONE, NONE;
    if !pm_one(step) return false, NONE, NONE, NONE, NONE;
    if !(is_inst(iv_inc) && inst_op(iv_inc) == .ADD && (inst(iv_inc).flags & F_NUW) != 0 && (op(iv_inc, 0) == pn || op(iv_inc, 1) == pn))
        return false, NONE, NONE, NONE, NONE;
    return true, rem_amt, add_inst, add_offset, pn;
}

// foldURemOfLoopIncrement
cgp_fold_urem_of_loop_increment :: (rem: Value_Id) -> bool {
    ok, rem_amt, add_inst, add_offset, pn := cgp_is_rem_of_loop_increment(rem);
    if !ok return false;
    if is_const(rem_amt) && !cgp_const_contains_ce(rem_amt) return false;   // m_ImmConstant
    l := li_loop_for(cgp.li, inst_block(pn));
    start := phi_incoming_value_for_block(pn, li_loop_preheader(cgp.li, l));
    q: Simplify_Query;
    if add_inst != NONE {
        nsw := (inst(add_inst).flags & F_NSW) != 0;
        start = simplify_add_inst(start, add_offset, nsw, true, q);
        if start == NONE return false;
    }
    start = simplify_urem_inst(start, rem_amt, q);
    if start == NONE return false;
    ty := vtype(rem);
    b: Irb;
    irb_set_before(*b, pn);
    new_rem := irb_phi(*b, ty, 2);
    irb_set_before(*b, phi_incoming_value_for_block(pn, li_loop_latch(cgp.li, l)));
    rem_add := irb_binop(*b, .ADD, new_rem, const_int(ty, 1), "", F_NUW);
    rem_cmp := irb_icmp(*b, ICMP_EQ, rem_add, rem_amt);
    rem_sel := irb_select(*b, rem_cmp, const_null_value(ty), rem_add);
    phi_add_incoming(new_rem, start, li_loop_preheader(cgp.li, l));
    phi_add_incoming(new_rem, rem_sel, li_loop_latch(cgp.li, l));
    cgp_fresh_insert(inst_block(pn));
    cgp_fresh_insert(li_loop_latch(cgp.li, l));
    cgp_fresh_insert(inst_block(rem));
    if add_inst != NONE cgp_fresh_insert(inst_block(add_inst));
    cgp_rauw(rem, new_rem);
    erase_inst_with_metadata(rem);
    if add_inst != NONE && !has_uses(add_inst) erase_inst_with_metadata(add_inst);
    return true;
}
// m_ImmConstant: a constant that is not (and contains no) constant expression
cgp_const_contains_ce :: (c: Value_Id) -> bool {
    if vkind(c) == .C_EXPR return true;
    n := nops(c);
    for k: 0..cast(s64) n - 1 if cgp_const_contains_ce(op(c, cast(u32) k)) return true;
    return false;
}

// optimizeCmp
cgp_optimize_cmp :: (cmp: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    if cgp_sink_cmp_expression(cmp) return true;
    if cgp_combine_to_uadd_with_overflow(cmp, modified) return true;
    if cgp_combine_to_usub_with_overflow(cmp, modified) return true;
    if cgp_unfold_power_of2_test(cmp) return true;
    if cgp_fold_icmp_with_dominating_icmp(cmp) return true;
    if cgp_swap_icmp_operands(cmp) return true;
    if cgp_fold_fcmp_to_fpclass_test(cmp) return true;
    return false;
}

// sinkAndCmp0Expression
cgp_sink_and_cmp0_expression :: (and_i: Value_Id) -> bool {
    if has_one_use(and_i) && inst_block(and_i) == inst_block(ir.u_user[ir.v_first_use[and_i]]) return false;
    o0 := op(and_i, 0); o1 := op(and_i, 1);
    // Value::hasOneUse: ConstantData has no use list in LLVM 23 (always false)
    if vkind(o0) != .C_INT && vkind(o1) != .C_INT && cgp_has_one_use(o0) && cgp_has_one_use(o1) return false;
    u := ir.v_first_use[and_i];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if inst_op(usr) != .ICMP return false;
        c := op(usr, 1);
        if vkind(c) != .C_INT || !pm_zero_int(c) return false;
    }
    // X86TargetLowering::isMaskAndCmp0FoldingBeneficial: true
    u = ir.v_first_use[and_i];
    while u != NONE {
        usr := ir.u_user[u];
        nx := ir.u_next[u];
        insert_pt := ifx inst_block(usr) == inst_block(and_i) then and_i else usr;
        ia := create_binop(.AND, op(and_i, 0), op(and_i, 1));
        insert_at_position(ia, inst_block(insert_pt), insert_pt, false);
        set_metadata(ia, 0, get_metadata(and_i, 0));
        use_set(u, ia);
        u = nx;
    }
    erase_inst_with_metadata(and_i);
    return true;
}

// ---------------------------------------------------------------- despeculateCountZeros

// SplitBlock(Old, SplitPt, DTU, LI, nullptr, Name) with a DomTreeUpdater
cgp_split_block :: (old: Value_Id, split_pt: Value_Id, name: string, head := false) -> Value_Id {
    nb := split_block(old, split_pt, null, cgp.li, null, name, head);
    updates: [..] Dom_Update; updates.allocator = temp;
    array_add(*updates, .{true, old, nb});
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(nb, *succs);
    seen: [..] Value_Id; seen.allocator = temp;
    for s: succs {
        dup := false;
        for seen if it == s dup = true;
        if dup continue;
        array_add(*seen, s);
        array_add(*updates, .{true, nb, s});
        array_add(*updates, .{false, old, s});
    }
    dtu_apply(*cgp.dtu, updates);
    return nb;
}

cgp_despeculate_count_zeros :: (cz: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    if pm_one(call_arg(cz, 1)) return false;
    ty := vtype(cz);
    id := call_iid(cz);
    if (id == IID_CTTZ && cgp_is_cheap_to_speculate_cttz(ty)) || (id == IID_CTLZ && cgp_is_cheap_to_speculate_ctlz(ty)) return false;
    size_in_bits := type_bits(scalar_type(ty));
    if is_vector_type(ty) return false;
    q: Simplify_Query;
    opu := ir.v_ops[cz];   // getOperandUse(0)
    if is_known_non_zero(op(cz, 0), q) return false;
    start := inst_block(cz);
    call_block := cgp_split_block(start, cz, "cond.false");
    if cgp.is_huge_func cgp_fresh_insert(call_block);
    split_pt := inst_next(cz);
    end_block := cgp_split_block(call_block, split_pt, "cond.end", true);
    if cgp.is_huge_func cgp_fresh_insert(end_block);
    b: Irb;
    irb_set_before(*b, block_terminator(start));
    b.dbg = get_metadata(cz, 0);
    zero := const_null_value(ty);
    v := op(cz, 0);
    if !is_guaranteed_not_to_be_undef_or_poison(v) {
        fr := new_inst(.FREEZE, vtype(v), 1);
        set_op(fr, 0, v);
        v = irb_insert(*b, fr, tconcat(vname(v), ".fr"));
        use_set(opu, v);   // `Op = Builder.CreateFreeze(...)`: Op is the Use of the intrinsic
    }
    c := irb_icmp(*b, ICMP_EQ, v, zero, "cmpz");
    irb_cond_br(*b, c, end_block, call_block);
    erase_inst_with_metadata(block_terminator_before(start, block_last(start)));
    dtu_apply1(*cgp.dtu, true, start, end_block);
    irb_set_at(*b, end_block, block_first(end_block), false);
    pn := irb_phi(*b, ty, 2, "ctz");
    cgp_rauw(cz, pn);
    bw := const_int(ty, cast(u64) size_in_bits);
    phi_add_incoming(pn, bw, start);
    phi_add_incoming(pn, cz, call_block);
    set_op(cz, 1, const_int(ir.t_i1, 1));
    modified.* = .MODIFY_BB_DT;
    return true;
}
// StartBlock->getTerminator() before the new conditional branch was appended: the old `br` (the instruction before
// the last one)
block_terminator_before :: (bb: Value_Id, last: Value_Id) -> Value_Id { return inst_prev(last); }

// ---------------------------------------------------------------- optimizeCallInst

cgp_optimize_call_inst :: (ci: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    bb := inst_block(ci);
    if vkind(call_callee(ci)) == .INLINE_ASM && cgp_optimize_inline_asm_inst(ci) return true;
    // shouldAlignPointerArgs: false (base)
    id := call_iid(ci);
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE {
        // MemIntrinsic: dest alignment (param 0), MemTransferInst: source alignment (param 1)
        // MI->getDest() / MTI->getSource(): the raw pointer with pointer casts stripped
        dest_align := get_known_alignment(strip_pointer_casts(call_arg(ci, 0)), NONE, null, null);
        cur := call_param_align(ci, 0);
        if cur == 0 || dest_align > cur add_param_align(ci, 0, dest_align);
        if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE {
            src_cur := call_param_align(ci, 1);
            src_align := get_known_alignment(strip_pointer_casts(call_arg(ci, 1)), NONE, null, null);
            if src_cur == 0 || src_align > src_cur add_param_align(ci, 1, src_align);
        }
    }
    if call_has_fn_attr(ci, .Cold) && !cgp_should_optimize_for_size(inst_block(ci)) {
        n := call_num_args(ci);
        for k: 0..cast(s64) n - 1 {
            arg := call_arg(ci, cast(u32) k);
            if type_kind(vtype(arg)) != .PTR continue;
            if cgp_optimize_memory_inst(ci, arg, vtype(arg), ptr_addrspace(vtype(arg))) return true;
        }
    }
    if id != NOT_INTRINSIC {
        if id == IID_ALLOW_RUNTIME_CHECK || id == IID_ALLOW_UBSAN_CHECK || id == IID_EXPERIMENTAL_WIDENABLE_CONDITION_ {
            if !has_uses(ci) { erase_inst_with_metadata(ci); return true; }
            cgp_reset_iterator_if_invalidated_while_calling(bb, ci, 1, const_int(ir.t_i1, 1));
            return true;
        }
        if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP {
            arg_val := call_arg(ci, 0);
            k := cgp_lgep_find(ci);
            if k >= 0 {
                geps: [..] Cgp_Gep_Off; geps.allocator = temp;
                for cgp.lgep_vals[k] array_add(*geps, it);
                dst := cgp_lgep_get(arg_val);
                for geps array_add(dst, it);
                cgp_lgep_erase(ci);
            }
            cgp_rauw(ci, arg_val);
            erase_inst_with_metadata(ci);
            return true;
        }
        if id == IID_CTTZ || id == IID_CTLZ return cgp_despeculate_count_zeros(ci, modified);
        if id == IID_FSHL || id == IID_FSHR return cgp_optimize_funnel_shift(ci);
        if id == IID_MASKED_GATHER return cgp_optimize_gather_scatter_inst(ci, call_arg(ci, 0));
        if id == IID_MASKED_SCATTER return cgp_optimize_gather_scatter_inst(ci, call_arg(ci, 1));
        if id == IID_MASKED_LOAD {
            vt := vtype(ci);
            if type_kind(vt) == .VECTOR && type_count(vt) == 1 {
                p := call_arg(ci, 0);
                if cgp_optimize_memory_inst(ci, p, type_elem(vt), ptr_addrspace(vtype(p))) return true;
            }
            return false;
        }
        if id == IID_MASKED_STORE {
            vt := vtype(call_arg(ci, 0));
            if type_kind(vt) == .VECTOR && type_count(vt) == 1 {
                p := call_arg(ci, 1);
                if cgp_optimize_memory_inst(ci, p, type_elem(vt), ptr_addrspace(vtype(p))) return true;
            }
            return false;
        }
        if id == IID_UMUL_WITH_OVERFLOW return cgp_optimize_mul_with_overflow(ci, false, modified);
        if id == IID_SMUL_WITH_OVERFLOW return cgp_optimize_mul_with_overflow(ci, true, modified);
        if id == IID_OBJECTSIZE || id == IID_IS_CONSTANT || id == IID_ASSUME fatal("codegenprepare: % should have been lowered already", iid_name(id));
        // X86TargetLowering has no getAddrModeArguments override (base: false)
    }
    callee := call_called_function(ci);
    if callee == NONE return false;
    // FortifiedLibCallSimplifier(TLInfo, OnlyLowerUnknownSize = true)
    if cgp_fortified_libcall_applies(ci) fatal("codegenprepare: lowering fortified library calls (%) is not supported yet", vname(callee));

    if cgp_has_exact_definition(callee) {
        rv := cgp_get_uniform_return_value(callee);
        if rv != NONE {
            made_change := false;
            uses: [..] Use_Id; uses.allocator = temp;
            u := ir.v_first_use[rv];
            while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
            for uu: uses {
                usr := ir.u_user[uu];
                if !is_inst(usr) || inst_block(usr) != inst_block(ci) continue;
                if comes_before(ci, usr) { use_set(uu, ci); made_change = true; }
            }
            return made_change;
        }
    }
    return false;
}

// GlobalValue::hasExactDefinition: a definition that can't be replaced at link time
cgp_has_exact_definition :: (f: Value_Id) -> bool {
    if is_declaration(f) return false;
    l := glob(f).linkage;
    // mayBeDerefined: available_externally, linkonce_odr, weak_odr, linkonce, weak, common, extern_weak
    if l == .AVAILABLE_EXTERNALLY || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .WEAK_ANY || l == .WEAK_ODR || l == .COMMON || l == .EXTERN_WEAK return false;
    return true;
}
cgp_get_uniform_return_value :: (f: Value_Id) -> Value_Id {
    if type_kind(func_ret(glob(f).value_type)) != .PTR return NONE;
    uniform: Value_Id = NONE;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t == NONE || inst_op(t) != .RET continue;
        if nops(t) == 0 return NONE;
        v := op(t, 0);
        if vkind(v) != .GLOBAL_VAR return NONE;
        if uniform == NONE uniform = v;
        else if v != uniform return NONE;
    }
    return uniform;
}
// FortifiedLibCallSimplifier::optimizeCall with OnlyLowerUnknownSize: only __*_chk calls whose object size argument
// is -1 (unknown) are lowered; recognize the candidates and fail loudly
cgp_fortified_libcall_applies :: (ci: Value_Id) -> bool {
    callee := call_called_function(ci);
    name := vname(callee);
    if !begins_with(name, "__") || !ends_with(name, "_chk") return false;
    if call_is_no_builtin(ci) return false;
    ok, lf := tli_lookup_fn(callee);
    return ok && tli_func_has(tli_for(cgp.f), lf);
}

// ---------------------------------------------------------------- dupRetToEnableTailCallOpts

cgp_is_intrinsic_or_lf_to_be_tail_called :: (ci: Value_Id) -> bool {
    id := call_iid(ci);
    if id != NOT_INTRINSIC return id == IID_MEMSET || id == IID_MEMCPY || id == IID_MEMMOVE;
    callee := call_called_function(ci);
    if callee == NONE return false;
    ok, lf := tli_lookup_fn(callee);
    if !ok return false;
    return lf == .strcpy || lf == .strncpy || lf == .strcat || lf == .strncat;
}

cgp_dup_ret_to_enable_tail_call_opts :: (bb: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    ret := block_terminator(bb);
    if ret == NONE || inst_op(ret) != .RET return false;
    pn, evi, bci: Value_Id = NONE;
    v: Value_Id = NONE;
    if nops(ret) > 0 {
        v = op(ret, 0);
        if is_inst(v) && inst_op(v) == .BITCAST { bci = v; v = op(v, 0); }
        if is_inst(v) && inst_op(v) == .EXTRACTVALUE {
            evi = v;
            v = op(v, 0);
            for k: 0..cast(s64) inst(evi).nidx - 1 if ir.u32_pool[inst(evi).idx + cast(u32) k] != 0 return false;
        }
        if is_phi(v) pn = v;
    }
    if pn != NONE && inst_block(pn) != bb return false;
    fake_uses: [..] Value_Id; fake_uses.allocator = temp;
    is_lifetime_end_or_bitcast_for :: (i: Value_Id) -> bool {
        x := i;
        if inst_op(x) == .BITCAST && has_one_use(x) x = ir.u_user[ir.v_first_use[x]];
        return call_iid(x) == IID_LIFETIME_END;
    }
    bi := block_first_non_phi(bb);
    while true {
        if bi == bci || bi == evi || call_iid(bi) == IID_PSEUDOPROBE || is_lifetime_end_or_bitcast_for(bi) { bi = inst_next(bi); continue; }
        if call_iid(bi) == IID_FAKE_USE_ {
            if !is_phi(op(bi, 0)) array_add(*fake_uses, bi);
            bi = inst_next(bi);
            continue;
        }
        break;
    }
    if bi != ret return false;
    may_be_permitted :: (ci: Value_Id) -> bool { return cgp_may_be_emitted_as_tail_call(ci) && cgp_attributes_permit_tail_call(cgp.f, ci); }
    tail_call_bbs: [..] Value_Id; tail_call_bbs.allocator = temp;
    call_insts: [..] Value_Id; call_insts.allocator = temp;
    if pn != NONE {
        for k: 0..cast(s64) nops(pn) - 1 {
            incoming := strip_pointer_casts(phi_value(pn, cast(u32) k));
            ci := ifx is_inst(incoming) && inst_op(incoming) == .CALL then incoming else NONE;
            pred := phi_block(pn, cast(u32) k);
            if ci != NONE && has_one_use(ci) && inst_block(ci) == pred && may_be_permitted(ci) {
                array_add(*tail_call_bbs, pred);
                array_add(*call_insts, ci);
            } else {
                if pred != NONE && block_single_successor(pred) == bb {
                    p := inst_prev(block_terminator(pred));
                    ci = ifx p != NONE && inst_op(p) == .CALL then p else NONE;
                }
                if ci != NONE && !has_uses(ci) && cgp_is_intrinsic_or_lf_to_be_tail_called(ci) && incoming == call_arg(ci, 0) && may_be_permitted(ci) {
                    array_add(*tail_call_bbs, pred);
                    array_add(*call_insts, ci);
                }
            }
        }
    } else {
        visited: [..] Value_Id; visited.allocator = temp;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(bb, *preds);
        for p: preds {
            dup := false;
            for visited if it == p dup = true;
            if dup continue;
            array_add(*visited, p);
            i := inst_prev(block_last(p));
            if i != NONE && inst_op(i) == .CALL && !has_uses(i) && may_be_permitted(i) {
                if v == NONE || vkind(v) == .C_UNDEF || vkind(v) == .C_POISON || (cgp_is_intrinsic_or_lf_to_be_tail_called(i) && v == call_arg(i, 0)) {
                    array_add(*tail_call_bbs, p);
                    array_add(*call_insts, i);
                }
            }
        }
    }
    changed := false;
    for tcb: tail_call_bbs {
        t := block_terminator(tcb);
        if inst_op(t) != .BR || get_successor(t, 0) != bb continue;
        td: Tre_Dtu;
        tre_fold_return_into_uncond_branch(ret, bb, tcb, *td);
        dtu_apply1(*cgp.dtu, false, tcb, bb);
        bf := bfi_get_block_freq(cgp.bfi, bb);
        tf := bfi_get_block_freq(cgp.bfi, tcb);
        // BlockFrequency operator-: saturating at 0
        bfi_set_block_freq(cgp.bfi, bb, ifx bf >= tf then bf - tf else 0);
        modified.* = .MODIFY_BB_DT;
        changed = true;
    }
    if changed && !block_has_address_taken(bb) && !block_has_predecessors(bb) {
        for ci: call_insts for fu: fake_uses {
            c := ic_clone_inst(fu);
            insert_at_position(c, inst_block(ci), ci, false);
        }
        dtu_delete_bb(*cgp.dtu, bb);
    }
    return changed;
}

// ---------------------------------------------------------------- optimizeInst / optimizeBlock

cgp_is_cast_op :: (o: Opcode) -> bool { return o >= .TRUNC && o <= .ADDRSPACECAST; }

cgp_optimize_inst :: (i: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    any_change := cgp_fixup_dbg_variable_records_on_inst(i);
    if table_contains(*cgp.inserted_insts, i) return any_change;
    o := inst_op(i);
    if o == .PHI {
        q: Simplify_Query;
        q.have_tli = true;
        v := simplify_instruction(i, q);
        if v != NONE {
            cgp_lgep_erase(i);
            cgp_rauw(i, v);
            erase_inst_with_metadata(i);
            return true;
        }
        return any_change;
    }
    if cgp_is_cast_op(o) {
        if is_const(op(i, 0)) return any_change;
        if cgp_optimize_noop_copy_expression(i) return true;
        // optimizeExtendOrTruncateConversion: false (base; AArch64 only)
        if o == .ZEXT || o == .SEXT {
            if xl_type_action(cgp.xl, cgp_evt(vtype(i))) == TA_EXPAND_INTEGER return cgp_sink_cast(i);
            ii := i;
            made_change := cgp_optimize_ext(*ii);
            return made_change | cgp_optimize_ext_uses(ii);
        }
        return any_change;
    }
    if o == .ICMP || o == .FCMP {
        if cgp_optimize_cmp(i, modified) return true;
    }
    if o == .UREM {
        if cgp_fold_urem_of_loop_increment(i) return true;
    }
    if o == .LOAD {
        set_metadata(i, md_kind_id("invariant.group"), NONE);
        m := cgp_optimize_load_ext(i);
        as := ptr_addrspace(vtype(op(i, 0)));
        m |= cgp_optimize_memory_inst(i, op(i, 0), vtype(i), as);
        return m;
    }
    if o == .STORE {
        if cgp_split_merged_val_store(i) return true;
        set_metadata(i, md_kind_id("invariant.group"), NONE);
        as := ptr_addrspace(vtype(op(i, 1)));
        return cgp_optimize_memory_inst(i, op(i, 1), vtype(op(i, 0)), as);
    }
    if o == .ATOMICRMW {
        return cgp_optimize_memory_inst(i, op(i, 0), vtype(i), ptr_addrspace(vtype(op(i, 0))));
    }
    if o == .CMPXCHG {
        return cgp_optimize_memory_inst(i, op(i, 0), vtype(op(i, 1)), ptr_addrspace(vtype(op(i, 0))));
    }
    if o == .AND && cgp_cl.enable_and_cmp_sinking && cgp_sink_and_cmp0_expression(i) return true;
    // AShr / LShr by a constant: OptimizeExtractBits only with TLI->hasExtractBitsInsn() (false on X86)
    if o == .GEP {
        if gep_has_all_zero_indices(i) {
            nc := create_cast(.BITCAST, op(i, 0), vtype(i));
            insert_at_position(nc, inst_block(i), i, false);
            set_name(nc, vname(i));
            set_metadata(nc, 0, get_metadata(i, 0));
            cgp_rauw(i, nc);
            cgp_recursively_delete_trivially_dead(i);
            cgp_optimize_inst(nc, modified);
            return true;
        }
        if cgp_try_unmerging_geps_across_indirectbr(i) return true;
    }
    if o == .FREEZE {
        cmp_i: Value_Id = NONE;
        x := op(i, 0);
        if is_inst(x) && inst_op(x) == .ICMP cmp_i = x;
        else if is_inst(x) && inst_op(x) == .FCMP && inst_fmf(x) == 0 cmp_i = x;
        if cmp_i != NONE && has_one_use(cmp_i) {
            op0 := op(cmp_i, 0); op1 := op(cmp_i, 1);
            is_c :: (v: Value_Id) -> bool { k := vkind(v); return k == .C_INT || k == .C_FP || (k == .C_NULL && type_kind(vtype(v)) == .PTR); }
            c0 := is_c(op0); c1 := is_c(op1);
            if c0 || c1 {
                if !c0 || !c1 {
                    fr := new_inst(.FREEZE, vtype(ifx c0 then op1 else op0), 1);
                    set_op(fr, 0, ifx c0 then op1 else op0);
                    insert_at_position(fr, inst_block(cmp_i), cmp_i, false);
                    take_name(fr, i);
                    set_op(cmp_i, ifx c0 then cast(u32) 1 else 0, fr);
                }
                cgp_rauw(i, cmp_i);
                erase_inst_with_metadata(i);
                return true;
            }
        }
        return any_change;
    }
    if cgp_try_to_sink_free_operands(i) return true;
    if o == {
        case .SHL; #through; case .LSHR; #through; case .ASHR; return cgp_optimize_shift_inst(i);
        case .CALL; return cgp_optimize_call_inst(i, modified);
        case .SELECT; return cgp_optimize_select_inst(i);
        case .SHUFFLEVECTOR; return cgp_optimize_shuffle_vector_inst(i);
        case .SWITCH; return cgp_optimize_switch_inst(i);
        case .EXTRACTELEMENT; return cgp_optimize_extract_element_inst(i);
        case .CONDBR; return cgp_optimize_branch(i);
    }
    return any_change;
}
// makeBitReverse
cgp_make_bit_reverse :: (i: Value_Id) -> bool {
    if type_kind(vtype(i)) != .INT return false;
    vt := cgp_evt(vtype(i), true);
    if !cgp_is_operation_legal_or_custom(ISD_BITREVERSE, vt) return false;
    // X86: BITREVERSE is custom for i8..i64 with GFNI and for i128 with SSSE3
    insts := ic_recognize_bswap_or_bit_reverse_idiom(i, false, true);
    if insts.count == 0 return false;
    last := insts[insts.count - 1];
    cgp_rauw(i, last);
    recursively_delete_trivially_dead_value_tli(i);
    return true;
}

// optimizeBlock
cgp_optimize_block :: (bb: Value_Id, modified: *Cgp_Modify_Dt) -> bool {
    table_reset(*cgp.sunk_addrs);
    made_change := false;
    while true {
        cgp.cur_bb = bb;
        cgp.cur_inst = block_first(bb);
        modified.* = .NOT_MODIFY_DT;
        while cgp.cur_inst != NONE {
            i := cgp.cur_inst;
            cgp.cur_inst = inst_next(i);
            made_change |= cgp_optimize_inst(i, modified);
            if modified.* != .NOT_MODIFY_DT {
                if cgp.is_huge_func break;
                return true;
            }
        }
        if modified.* != .MODIFY_INST_DT break;
    }
    // makeBitReverse: only when BITREVERSE is legal or custom for some integer type (GFNI / XOP)
    if cgp_bitreverse_possible() {
        made_br := true;
        while made_br {
            made_br = false;
            x := block_last(bb);
            while x != NONE {
                p := inst_prev(x);
                if cgp_make_bit_reverse(x) { made_br = true; made_change = true; break; }
                x = p;
            }
        }
    }
    made_change |= cgp_dup_ret_to_enable_tail_call_opts(bb, modified);
    return made_change;
}
cgp_bitreverse_possible :: () -> bool {
    for m: u32.[MVT_i8, MVT_i16, MVT_i32, MVT_i64, MVT_i128] if cgp_is_operation_legal_or_custom(ISD_BITREVERSE, evt_simple(m)) return true;
    return false;
}

// fixupDbgVariableRecordsOnInst / fixupDbgVariableRecord
cgp_fixup_dbg_variable_records_on_inst :: (i: Value_Id) -> bool {
    if inst(i).records == 0 || cgp.sunk_addrs.count == 0 return false;
    any := false;
    r := inst(i).records;
    while r != 0 {
        rec := dbgr(r);
        nx := rec.next;
        if dbgr(r).kind == .VALUE || dbgr(r).kind == .ASSIGN {
            locs: [..] Value_Id; locs.allocator = temp;
            dbgr_location_ops(r, *locs);
            uniq: [..] Value_Id; uniq.allocator = temp;
            for locs { dup := false; for uniq if it == locs[it_index] dup = true; if !dup array_add(*uniq, it); }
            for loc: uniq {
                found, h := table_find(*cgp.sunk_addrs, loc);
                if !found continue;
                sunk := vh_get(h);
                if sunk == NONE || vkind(sunk) == .DEAD continue;
                dbgr_replace_variable_location_op(r, loc, sunk);
                any = true;
            }
        }
        r = nx;
    }
    return any;
}

// placeDbgValues
cgp_place_dbg_values :: (f: Value_Id) -> bool {
    made_change := false;
    dt := cgp_get_dt();
    for bb: fn_blocks(f) {
        for :early_inc insn: block_insts(bb) {
            r := inst(insn).records;
            while r != 0 {
                nx := dbgr(r).next;
                if dbgr(r).kind == .VALUE made_change |= cgp_dbg_process(r, insn, dt);
                r = nx;
            }
        }
    }
    return made_change;
}
cgp_dbg_process :: (r: u32, position: Value_Id, dt: *Dom_Tree) -> bool {
    made_change := false;
    vis: [..] Value_Id; vis.allocator = temp;
    locs: [..] Value_Id; locs.allocator = temp;
    dbgr_location_ops(r, *locs);
    for locs if it != NONE && is_inst(it) array_add(*vis, it);
    for vi: vis {
        if is_terminator(inst_op(vi)) continue;
        if is_phi(vi) && is_eh_pad(block_terminator(inst_block(vi))) continue;
        if dt_dominates_inst(dt, vi, position) continue;
        if vis.count > 1 {
            dbgr_set_kill_location(r);
            break;
        }
        // DbgInserterHelper
        cgp_dbgr_unlink(r);
        vbb := inst_block(vi);
        // insertDbgRecordBefore(getFirstInsertionPt()) (head bit set) / insertDbgRecordAfter: at the head of the marker
        if is_phi(vi) cgp_dbgr_insert_at_head(r, block_first_insertion_pt(vbb));
        else cgp_dbgr_insert_at_head(r, inst_next(vi));
        made_change = true;
    }
    return made_change;
}

// placePseudoProbes
cgp_place_pseudo_probes :: (f: Value_Id) -> bool {
    made_change := false;
    for bb: fn_blocks(f) {
        first := block_first_insertion_pt(bb);
        while first != NONE && is_debug_or_pseudo_inst(first) first = inst_next(first);
        if first == NONE continue;
        x := inst_next(first);
        while x != NONE {
            nx := inst_next(x);
            if call_iid(x) == IID_PSEUDOPROBE {
                inst_move_before_dbg(x, first);
                made_change = true;
            }
            x = nx;
        }
    }
    return made_change;
}

// splitBranchCondition: `if (!TM->Options.EnableFastISel || TLI->isJumpExpensive()) return false` -- llc enables
// FastISel only at -O0, where CodeGenPrepare does not run
cgp_split_branch_condition :: (f: Value_Id) -> bool { return false; }

// findIBRPredecessor -> (IBB, OtherPreds)
cgp_find_ibr_predecessor :: (bb: Value_Id, others: *[..] Value_Id) -> Value_Id {
    ibb: Value_Id = NONE;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for p: preds {
        o := inst_op(block_terminator(p));
        if o == .INDIRECTBR {
            if ibb != NONE return NONE;
            ibb = p;
        } else if o == .BR || o == .CONDBR || o == .SWITCH {
            array_add(others, p);
        } else return NONE;
    }
    return ibb;
}

// SplitIndirectBrCriticalEdges(F, IgnoreBlocksWithoutPHI = true, BPI, BFI, DTU)
// (llvm/lib/Transforms/Utils/BreakCriticalEdges.cpp)
cgp_split_indirectbr_critical_edges :: (f: Value_Id) -> bool {
    targets: [..] Value_Id; targets.allocator = temp;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t == NONE || inst_op(t) != .INDIRECTBR continue;
        for k: 0..cast(s64) num_successors(t) - 1 {
            s := get_successor(t, cast(u32) k);
            dup := false;
            for targets if it == s dup = true;
            if !dup array_add(*targets, s);
        }
    }
    if targets.count == 0 return false;
    bpi := get_bpi(f);
    bfi := cgp.bfi;
    changed := false;
    for target: targets {
        if !is_phi(block_first(target)) continue;
        other_preds: [..] Value_Id; other_preds.allocator = temp;
        ibr_pred := cgp_find_ibr_predecessor(target, *other_preds);
        if ibr_pred == NONE || other_preds.count == 0 continue;
        first_non_phi := block_first_non_phi(target);
        if is_eh_pad(first_non_phi) continue;
        // remember the edge probabilities, then BPI->eraseBlock(Target)
        tt := block_terminator(target);
        nsucc := num_successors(tt);
        probs := NewArray(nsucc, u32,, temp);
        for k: 0..cast(s64) nsucc - 1 probs[k] = bpi_edge_probability_idx(bpi, target, cast(u32) k);
        bpi_erase_block(bpi, target);
        body := cgp_split_block(target, first_non_phi, ".split");
        bpi_set_edge_probability(bpi, body, probs);
        bfi_set_block_freq(bfi, body, bfi_get_block_freq(bfi, target));
        if ibr_pred == target ibr_pred = body;
        vm: Value_Map;
        vmap_init(*vm);
        direct := clone_basic_block(target, *vm, ".clone", f);
        freq_direct: u64 = 0;
        updates: [..] Dom_Update; updates.allocator = temp;
        seen: [..] Value_Id; seen.allocator = temp;
        for pred: other_preds {
            src := ifx pred != target then pred else body;
            replace_uses_of_with(block_terminator(src), target, direct);
            freq_direct = bm_add(freq_direct, bf_mul_prob(bfi_get_block_freq(bfi, src), bpi_edge_probability(bpi, src, direct)));
            dup := false;
            for seen if it == src dup = true;
            if !dup {
                array_add(*seen, src);
                array_add(*updates, .{true, src, direct});
                array_add(*updates, .{false, src, target});
            }
        }
        bfi_set_block_freq(bfi, direct, freq_direct);
        bfi_set_block_freq(bfi, target, bm_sub(bfi_get_block_freq(bfi, target), freq_direct));
        array_add(*updates, .{true, direct, body});
        dtu_apply(*cgp.dtu, updates);
        indirect := block_first(target);
        end := block_first_non_phi(target);
        dir := block_first(direct);
        merge_insert := block_first_insertion_pt(body);
        while indirect != end {
            dir_phi := dir; ind_phi := indirect;
            insert_pt := indirect;
            phi_remove_incoming_block(dir_phi, ibr_pred, false);
            dir = inst_next(dir);
            indirect = inst_next(indirect);
            new_ind := create_phi(vtype(ind_phi), 1);
            insert_at_position(new_ind, target, insert_pt, false);
            set_name(new_ind, "ind");
            phi_add_incoming(new_ind, phi_incoming_value_for_block(ind_phi, ibr_pred), ibr_pred);
            set_metadata(new_ind, 0, get_metadata(ind_phi, 0));
            merge := create_phi(vtype(ind_phi), 2);
            insert_at_position(merge, body, merge_insert, true);
            set_name(merge, "merge");
            phi_add_incoming(merge, new_ind, target);
            phi_add_incoming(merge, dir_phi, direct);
            set_metadata(merge, 0, merged_location(get_metadata(dir_phi, 0), get_metadata(ind_phi, 0)));
            rauw_with_metadata(ind_phi, merge);
            erase_inst_with_metadata(ind_phi);
        }
        changed = true;
    }
    return changed;
}

IID_FAKE_USE_ :: #run iid_by_name("llvm.fake.use");
IID_EXPERIMENTAL_WIDENABLE_CONDITION_ :: #run iid_by_name("llvm.experimental.widenable.condition");

// X86Subtarget::hasBitScanPassThrough: is64Bit()
cgp_has_bit_scan_pass_through :: (st: *X86_Lowering) -> bool { return st_is64Bit(st); }

// DbgRecord::removeFromParent
cgp_dbgr_unlink :: (r: u32) {
    o := dbgr(r).owner;
    x := inst(o).records;
    if x == r inst(o).records = dbgr(r).next;
    else {
        while dbgr(x).next != r x = dbgr(x).next;
        dbgr(x).next = dbgr(r).next;
    }
    dbgr(r).next = 0;
    dbgr(r).owner = NONE;
}
// DbgMarker::insertDbgRecord(DR, InsertAtHead = true) on the marker of `i`
cgp_dbgr_insert_at_head :: (r: u32, i: Value_Id) {
    dbgr(r).next = inst(i).records;
    dbgr(r).owner = i;
    inst(i).records = r;
}

// GlobalObject::setSectionPrefix(Prefix): !section_prefix !{!"section_prefix", !"<prefix>"}
cgp_set_section_prefix :: (f: Value_Id, prefix: string) {
    k := md_kind_id("section_prefix");
    old := get_metadata(f, k);
    if old != NONE && ir.mds[old].nops >= 2 {
        p := md_op(old, 1);
        if p != NONE && ir.mds[p].kind == .STRING && ir.mds[p].str == prefix return;
    }
    ops: [2] Md_Id;
    ops[0] = md_string("section_prefix"); ops[1] = md_string(prefix);
    set_metadata(f, k, md_tuple(ops, false));
}

// Value::hasOneUse: false for ConstantData (no use list)
cgp_has_one_use :: (v: Value_Id) -> bool {
    if cgp_is_constant_data(v) return false;
    return has_one_use(v);
}
