// LICM: port of llvm/lib/Transforms/Scalar/LICM.cpp (LICMPass::run, LoopInvariantCodeMotion::runOnLoop,
// SinkAndHoistLICMFlags, sinkRegion, hoistRegion, canSinkOrHoistInst / canHoistLoad, isLoadInvariantInLoop,
// isNotUsedOrFoldableInLoop / isFoldableInLoop, sink (splitPredecessorsOfLoopExit, cloneInstructionInExitBlock,
// sinkThroughTriviallyReplaceablePHI), hoist, moveInstructionBefore, eraseInstruction, isSafeToExecuteUnconditionally,
// LoopPromoter + promoteLoopAccessesToScalars, collectPromotionCandidates, noConflictingReadWrites,
// pointerInvalidatedByLoop / Block, hoistArithmetics (hoistMinMax, hoistGEP, hoistAdd / hoistSub, hoistMulAddAssociation,
// hoistBOAssociation, hoistSubAddAssociation)), of collectChildrenInLoop / hasDisableLICMTransformsHint
// (llvm/lib/Transforms/Utils/LoopUtils.cpp), LoopBlocksDFS / LoopBlocksRPO (llvm/include/llvm/Analysis/LoopIterator.h,
// llvm/lib/Analysis/LoopInfo.cpp), LoopInfo::wouldBeOutOfLoopUseRequiringLCSSA, OverflowTracking
// (llvm/lib/Transforms/Utils/Local.cpp), Instruction::mergeDIAssignID (llvm/lib/IR/DebugInfo.cpp) and the load case
// of isSafeToSpeculativelyExecute (llvm/lib/Analysis/ValueTracking.cpp).
// Uses must_execute.jai (ICFLoopSafetyInfo), alias_set_tracker.jai, ssa_updater.jai (LoadAndStorePromoter),
// mssa_updater.jai.
//
// ControlFlowHoister is a struct of LICM state (cfh_*); its DenseMaps are vectors in insertion order (every LLVM
// iteration over them is order-independent or asserts a unique match).
// Not ported (fail loudly): sinking calls with funclet bundles,
// optimization remarks (never printed without -pass-remarks).

licm_opts: struct {
    disable_promotion := false;            // -disable-licm-promotion
    control_flow_hoisting := false;        // -licm-control-flow-hoisting
    single_thread := false;                // -licm-force-thread-model-single
    max_num_uses_traversed: s64 = 8;       // -licm-max-num-uses-traversed
    fp_association_upper_limit: s64 = 5;   // -licm-max-num-fp-reassociations
    int_association_upper_limit: s64 = 5;  // -licm-max-num-int-reassociations
    mssa_opt_cap: s64 = 100;               // -licm-mssa-optimization-cap
    mssa_no_acc_for_promotion_cap: s64 = 250;   // -licm-mssa-max-acc-promotion
};
LICM_CL_OPT_COUNT :: 9;
add_licm_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"disable-licm-promotion", .BOOL, *licm_opts.disable_promotion, null, null};
    list[start + 1] = .{"licm-control-flow-hoisting", .BOOL, *licm_opts.control_flow_hoisting, null, null};
    list[start + 2] = .{"licm-force-thread-model-single", .BOOL, *licm_opts.single_thread, null, null};
    list[start + 3] = .{"licm-max-num-uses-traversed", .INT, null, *licm_opts.max_num_uses_traversed, null};
    list[start + 4] = .{"licm-max-num-fp-reassociations", .INT, null, *licm_opts.fp_association_upper_limit, null};
    list[start + 5] = .{"licm-max-num-int-reassociations", .INT, null, *licm_opts.int_association_upper_limit, null};
    list[start + 6] = .{"licm-mssa-optimization-cap", .INT, null, *licm_opts.mssa_opt_cap, null};
    list[start + 7] = .{"licm-mssa-max-acc-promotion", .INT, null, *licm_opts.mssa_no_acc_for_promotion_cap, null};
    list[start + 8] = .{"alias-set-saturation-threshold", .INT, null, *ast_opts.saturation_threshold, null};
}

IID_CORO_SUSPEND :: #run iid_by_name("llvm.coro.suspend");

Licm :: struct {
    f: Value_Id;
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    mssa: *Memory_SSA;
    mssau: *Mssa_Updater;
    aar: Aa_Results;
    tti: *Tti;
    safety: *Loop_Safety_Info;
    allow_speculation: bool;
    // SinkAndHoistLICMFlags
    opt_cap: u32;
    no_acc_cap: u32;
    opt_counter: u32;
    is_sink: bool;
    too_many_mem_acc: bool;
    loop_nest_mode: bool;
    outermost: Loop_Id = NONE;   // sinkRegion's OutermostLoop (LoopNestMode)
    // ControlFlowHoister
    cfh_dest: [..] Cfh_Pair;        // HoistDestinationMap (block -> hoisted block)
    cfh_branches: [..] Cfh_Pair;    // HoistableBranches (branch -> common successor)
}
Cfh_Pair :: struct { a: Value_Id; b: Value_Id; }

// LICMPass::run
// LICMPass::run / LNICMPass::run (loop_nest_mode: on the outermost loop of a nest)
licm_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater, loop_nest_mode := false) -> Preserved {
    if !lar.mssa fatal(ifx loop_nest_mode then "LNICM requires MemorySSA (loop-mssa)" else "LICM requires MemorySSA (loop-mssa)");
    allow := true;
    // parseLICMOptions
    nm := node.name;
    prefix := ifx loop_nest_mode then "lnicm<" else "licm<";
    if begins_with(nm, prefix) {
        params := slice(nm, prefix.count, nm.count - prefix.count - 1);
        while params.count {
            p := params;
            k := find_index_from_left(params, #char ";");
            if k >= 0 { p = slice(params, 0, k); params = slice(params, k + 1, params.count - k - 1); } else params = "";
            enable := true;
            if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
            if p == "allowspeculation" allow = enable;
            else fatal("invalid LICM pass parameter '%'", p);
        }
    }
    c: Licm;
    c.f = lar.fn; c.l = l; c.li = lar.li; c.dt = lar.dt; c.ac = lar.ac; c.mssa = lar.mssa;
    c.aar = aa_results_for(lar.fn);
    c.tti = tti_get(lar.fn);
    c.allow_speculation = allow;
    c.loop_nest_mode = loop_nest_mode;
    c.opt_cap = cast(u32) licm_opts.mssa_opt_cap;
    c.no_acc_cap = cast(u32) licm_opts.mssa_no_acc_for_promotion_cap;
    if !licm_run_on_loop(*c) return PRESERVE_ALL;
    pa := loop_pass_preserved();
    preserve(*pa, .MEMORYSSA);
    return pa;
}

// Loop::hasLoopInvariantOperands
licm_has_loop_invariant_operands :: (c: *Licm, i: Value_Id) -> bool {
    n := nops(i);
    for k: 0..cast(s64) n - 1 if !li_is_loop_invariant(c.li, c.l, op(i, cast(u32) k)) return false;
    return true;
}
licm_inv :: inline (c: *Licm, v: Value_Id) -> bool { return li_is_loop_invariant(c.li, c.l, v); }
// Loop::contains(Instruction)
licm_contains_inst :: inline (c: *Licm, i: Value_Id) -> bool { return li_contains(c.li, c.l, inst_block(i)); }

// LoopInvariantCodeMotion::runOnLoop
licm_run_on_loop :: (c: *Licm) -> bool {
    li := c.li; l := c.l;
    changed := false;
    if li_boolean_loop_attribute(l, "llvm.licm.disable") return false;
    has_coro_suspend := false;
    for b: li_blocks(li, l) { for i: block_insts(b) if call_iid(i) == IID_CORO_SUSPEND { has_coro_suspend = true; break; } if has_coro_suspend break; }
    mssau: Mssa_Updater;
    mssau.mssa = c.mssa;
    c.mssau = *mssau;
    // SinkAndHoistLICMFlags(..., IsSink = true, L, MSSA)
    c.is_sink = true;
    {
        count: u32 = 0;
        for b: li_blocks(li, l) {
            a := mssa_first_access(c.mssa, b);
            while a >= 0 {
                count += 1;
                if count > c.no_acc_cap { c.too_many_mem_acc = true; break; }
                a = c.mssa.acc[a].next;
            }
            if c.too_many_mem_acc break;
        }
    }
    preheader := li_loop_preheader(li, l);
    safety: Loop_Safety_Info;
    lsi_compute(*safety, li, l);
    c.safety = *safety;
    c.cfh_dest.allocator = temp; c.cfh_branches.allocator = temp;
    header := li_header(li, l);
    if li_has_dedicated_exits(li, l) {
        if c.loop_nest_mode changed |= licm_sink_region_for_loop_nest(c);
        else changed |= licm_sink_region(c, dt_node(c.dt, header));
    }
    c.is_sink = false;
    if preheader != NONE changed |= licm_hoist_region(c, dt_node(c.dt, header), preheader);

    if !licm_opts.disable_promotion && preheader != NONE && li_has_dedicated_exits(li, l) && !c.too_many_mem_acc && !has_coro_suspend {
        exits: [..] Value_Id; exits.allocator = temp;
        li_unique_exit_blocks(li, l, *exits);
        has_catch_switch := false;
        for exits if inst_op(block_terminator(it)) == .CATCHSWITCH { has_catch_switch = true; break; }
        if !has_catch_switch {
            insert_pts: [..] Value_Id; insert_pts.allocator = temp;
            mssa_insert_pts: [..] s32; mssa_insert_pts.allocator = temp;
            for exits { array_add(*insert_pts, block_first_insertion_pt(it)); array_add(*mssa_insert_pts, -1); }
            pic: Pred_Cache; pic.map.allocator = temp;
            promoted := false;
            while true {
                local_promoted := false;
                cands := licm_collect_promotion_candidates(c);
                for cands
                    local_promoted |= licm_promote_loop_accesses_to_scalars(c, it.ptrs, *exits, *insert_pts, *mssa_insert_pts, *pic, it.has_reads_outside, li_loop_preheader(li, l));
                promoted |= local_promoted;
                if !local_promoted break;
            }
            if promoted form_lcssa_recursively(li, l, c.dt);
            changed |= promoted;
        }
    }
    if mssa_opts.verify mssa_verify(c.mssa);
    if changed && scev_pass_se { se = scev_pass_se; sc_forget_loop_dispositions(); }
    return changed;
}

// inSubLoop
licm_in_sub_loop :: (c: *Licm, bb: Value_Id) -> bool { return li_loop_for(c.li, bb) != c.l; }

// collectChildrenInLoop
collect_children_in_loop :: (dt: *Dom_Tree, n: s32, li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    out.count = 0;
    if li_contains(li, l, dt.nodes[n].block) array_add(out, dt.nodes[n].block);
    i := 0;
    while i < out.count {
        x := dt_node(dt, out.*[i]);
        ch := dt.nodes[x].first_child;
        while ch >= 0 {
            if li_contains(li, l, dt.nodes[ch].block) array_add(out, dt.nodes[ch].block);
            ch = dt.nodes[ch].sibling;
        }
        i += 1;
    }
}

// sinkRegionForLoopNest
licm_sink_region_for_loop_nest :: (c: *Licm) -> bool {
    changed := false;
    cur := c.l;
    w: Loop_Worklist;
    lwl_init(*w);
    lwl_insert(*w, cur);
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(c.li, cur) array_add(*subs, it);
    append_loops_to_worklist(c.li, subs, *w);
    while !lwl_empty(*w) {
        l := lwl_pop(*w);
        c.l = l;
        c.outermost = cur;
        changed |= licm_sink_region(c, dt_node(c.dt, li_header(c.li, l)));
    }
    c.l = cur;
    c.outermost = NONE;
    return changed;
}

// eraseInstruction
licm_erase_instruction :: (c: *Licm, i: Value_Id) {
    mssau_remove_memory_access_inst(c.mssau, i);
    lsi_remove_instruction(c.safety, i);
    erase_inst_with_metadata(i);
}

// sinkRegion
licm_sink_region :: (c: *Licm, n: s32) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    collect_children_in_loop(c.dt, n, c.li, c.l, *worklist);
    changed := false;
    for < bb: worklist {
        if licm_in_sub_loop(c, bb) continue;
        cur := block_last(bb);
        while cur != NONE {
            i := cur;
            saved_prev := inst_prev(i);
            if is_instruction_trivially_dead(i) {
                if salvage_knowledge(i) saved_prev = inst_prev(i);   // the new assume is visited next
                salvage_debug_info(i);
                licm_erase_instruction(c, i);
                changed = true;
                cur = saved_prev;
                continue;
            }
            foldable := false;
            erased := false;
            if !may_have_side_effects(i) && licm_is_not_used_or_foldable_in_loop(c, i, *foldable) && licm_can_sink_or_hoist_inst(c, i, true) {
                if licm_sink(c, i) {
                    if !foldable {
                        salvage_debug_info(i);
                        licm_erase_instruction(c, i);
                        erased = true;
                    }
                    changed = true;
                }
            }
            cur = ifx erased then saved_prev else inst_prev(i);
        }
    }
    if mssa_opts.verify mssa_verify(c.mssa);
    return changed;
}

// LoopBlocksDFS::perform + LoopBlocksRPO: reverse post-order of the loop's blocks from the header
loop_blocks_rpo :: (li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    out.count = 0;
    post: [..] Value_Id; post.allocator = temp;
    seen: Table(Value_Id, bool); seen.allocator = temp;
    Frame :: struct { b: Value_Id; k: u32; n: u32; }
    stack: [..] Frame; stack.allocator = temp;
    h := li_header(li, l);
    visit :: (li: *Loop_Info, l: Loop_Id, seen: *Table(Value_Id, bool), b: Value_Id) -> bool {
        bl := li_loop_for(li, b);
        if bl == NONE || !li_contains_loop(li, l, bl) return false;
        if table_contains(seen, b) return false;
        table_set(seen, b, true);
        return true;
    }
    if !visit(li, l, *seen, h) return;
    array_add(*stack, .{h, 0, num_successors(block_terminator(h))});
    while stack.count {
        top := *stack[stack.count - 1];
        if top.k == top.n { array_add(*post, top.b); pop(*stack); continue; }
        s := get_successor(block_terminator(top.b), top.k);
        top.k += 1;
        if visit(li, l, *seen, s) array_add(*stack, .{s, 0, num_successors(block_terminator(s))});
    }
    for < post array_add(out, it);
}

// hoistRegion
licm_hoist_region :: (c: *Licm, n: s32, preheader: Value_Id) -> bool {
    li := c.li; l := c.l;
    worklist: [..] Value_Id; worklist.allocator = temp;
    loop_blocks_rpo(li, l, *worklist);
    hoisted: [..] Value_Id; hoisted.allocator = temp;   // HoistedInstructions
    changed := false;
    for bb: worklist {
        if !c.loop_nest_mode && licm_in_sub_loop(c, bb) continue;
        i := block_first(bb);
        while i != NONE {
            nx := inst_next(i);
            defer i = nx;
            if licm_has_loop_invariant_operands(c, i) && licm_can_sink_or_hoist_inst(c, i, true) &&
               licm_is_safe_to_execute_unconditionally(c, i, block_terminator(preheader)) {
                licm_hoist(c, i, cfh_get_or_create_hoisted_block(c, bb));
                array_add(*hoisted, i);
                changed = true;
                continue;
            }
            if inst_op(i) == .FDIV && (get_fmf(i) & FMF_ARCP) != 0 && licm_inv(c, op(i, 1)) {
                divisor := op(i, 1);
                one := fp_from_double(vtype(divisor), 1.0);
                recip := create_binop(.FDIV, one, divisor);
                set_fmf(recip, get_fmf(i));
                lsi_insert_instruction_to(c.safety, recip, inst_block(i));
                insert_at_position(recip, inst_block(i), i, false);
                set_metadata(recip, 0, get_metadata(i, 0));
                product := create_binop(.FMUL, op(i, 0), recip);
                set_fmf(product, get_fmf(i));
                lsi_insert_instruction_to(c.safety, product, inst_block(i));
                inst_insert_after(product, i);
                set_metadata(product, 0, get_metadata(i, 0));
                rauw_with_metadata(i, product);
                licm_erase_instruction(c, i);
                licm_hoist(c, recip, cfh_get_or_create_hoisted_block(c, bb));
                array_add(*hoisted, recip);
                changed = true;
                continue;
            }
            is_invariant_start := !has_uses(i) && call_iid(i) == IID_INVARIANT_START;
            if (is_invariant_start || is_guard(i)) && licm_has_loop_invariant_operands(c, i) &&
               lsi_is_guaranteed_to_execute(c.safety, i, c.dt, l) && lsi_does_not_write_memory_before(c.safety, i, l) {
                licm_hoist(c, i, cfh_get_or_create_hoisted_block(c, bb));
                array_add(*hoisted, i);
                changed = true;
                continue;
            }
            if inst_op(i) == .PHI && cfh_can_hoist_phi(c, i) {
                for k: 0..cast(s64) nops(i) - 1 phi_set_block(i, cast(u32) k, cfh_get_or_create_hoisted_block(c, phi_block(i, cast(u32) k)));
                licm_hoist(c, i, cfh_get_or_create_hoisted_block(c, bb));
                changed = true;
                continue;
            }
            if licm_hoist_arithmetics(c, i, li_loop_preheader(li, l)) { changed = true; continue; }
            if inst_op(i) == .CONDBR cfh_register_possibly_hoistable_branch(c, i);
        }
    }
    // rehoist instructions hoisted into conditional blocks that don't dominate their uses
    hoist_point: Value_Id = NONE;
    if licm_opts.control_flow_hoisting {
        for < i: hoisted {
            all := true;
            u := ir.v_first_use[i];
            while u != NONE { if !dt_dominates_use(c.dt, i, u) { all = false; break; } u = ir.u_next[u]; }
            if all continue;
            dominator := c.dt.nodes[dt_idom(c.dt, dt_node(c.dt, inst_block(i)))].block;
            if hoist_point == NONE || !dt_dominates(c.dt, inst_block(hoist_point), dominator) hoist_point = block_terminator(dominator);
            licm_move_instruction_before(c, i, hoist_point);
            hoist_point = i;
            changed = true;
        }
    }
    if mssa_opts.verify mssa_verify(c.mssa);
    return changed;
}

// ControlFlowHoister::registerPossiblyHoistableBranch
cfh_register_possibly_hoistable_branch :: (c: *Licm, bi: Value_Id) {
    if !licm_opts.control_flow_hoisting || !licm_has_loop_invariant_operands(c, bi) return;
    td := get_successor(bi, 0);
    fd := get_successor(bi, 1);
    if !li_contains(c.li, c.l, td) || !li_contains(c.li, c.l, fd) || td == fd return;
    ts: [..] Value_Id; ts.allocator = temp; block_successors(td, *ts);
    fs: [..] Value_Id; fs.allocator = temp; block_successors(fd, *fs);
    has :: (l: [] Value_Id, b: Value_Id) -> bool { for l if it == b return true; return false; }
    common: Value_Id = NONE;
    if has(ts, fd) common = fd;
    else if has(fs, td) common = td;
    else {
        inter: [..] Value_Id; inter.allocator = temp;
        for ts if has(fs, it) && !has(inter, it) array_add(*inter, it);
        if inter.count == 1 common = inter[0];
        else if inter.count > 1 {
            for b: fn_blocks(block_fn(td)) if has(inter, b) { common = b; break; }
        }
    }
    if common != NONE && dt_dominates_inst_block(c.dt, bi, common) {
        for * c.cfh_branches if it.a == bi { it.b = common; return; }
        array_add(*c.cfh_branches, .{bi, common});
    }
}

// ControlFlowHoister::canHoistPHI
cfh_can_hoist_phi :: (c: *Licm, pn: Value_Id) -> bool {
    if !licm_opts.control_flow_hoisting || !licm_has_loop_invariant_operands(c, pn) return false;
    bb := inst_block(pn);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    set: [..] Value_Id; set.allocator = temp;
    for preds { dup := false; for x: set if x == it { dup = true; break; } if !dup array_add(*set, it); }
    if set.count != preds.count return false;
    erase :: (s: *[..] Value_Id, b: Value_Id) { for s.* if it == b { array_ordered_remove_by_index(s, it_index); return; } }
    for p: c.cfh_branches {
        if p.b != bb continue;
        s0 := get_successor(p.a, 0); s1 := get_successor(p.a, 1);
        if s0 == bb { erase(*set, inst_block(p.a)); erase(*set, s1); }
        else if s1 == bb { erase(*set, inst_block(p.a)); erase(*set, s0); }
        else { erase(*set, s0); erase(*set, s1); }
    }
    return set.count == 0;
}

// ControlFlowHoister::getOrCreateHoistedBlock
cfh_get_or_create_hoisted_block :: (c: *Licm, bb: Value_Id) -> Value_Id {
    if !licm_opts.control_flow_hoisting return li_loop_preheader(c.li, c.l);
    for c.cfh_dest if it.a == bb return it.b;
    bi: Value_Id = NONE;
    for p: c.cfh_branches {
        if bb != p.b && (get_successor(p.a, 0) == bb || get_successor(p.a, 1) == bb) { bi = p.a; break; }
    }
    initial_ph := li_loop_preheader(c.li, c.l);
    if bi == NONE {
        array_add(*c.cfh_dest, .{bb, initial_ph});
        return initial_ph;
    }
    td := get_successor(bi, 0);
    fd := get_successor(bi, 1);
    common: Value_Id = NONE;
    for c.cfh_branches if it.a == bi { common = it.b; break; }
    hoist_target := cfh_get_or_create_hoisted_block(c, inst_block(bi));
    f := block_fn(bb);
    create_hoisted :: (c: *Licm, orig: Value_Id, hoist_target: Value_Id, f: Value_Id) -> Value_Id {
        for c.cfh_dest if it.a == orig return it.b;
        nb := create_block(f, tprint("%.licm", vname(orig)));
        array_add(*c.cfh_dest, .{orig, nb});
        dt_add_new_block(c.dt, nb, hoist_target);
        p := li_parent(c.li, c.l);
        if p != NONE li_add_basic_block_to_loop(c.li, p, nb);
        return nb;
    }
    htd := create_hoisted(c, td, hoist_target, f);
    hfd := create_hoisted(c, fd, hoist_target, f);
    hcs := create_hoisted(c, common, hoist_target, f);
    if block_terminator(hcs) == NONE {
        target_succ := block_get_single_successor(hoist_target);
        assert(target_succ != NONE, "Expected hoist target to have a single successor");
        block_move_before(hcs, target_succ);
        block_append_inst(hcs, create_br(target_succ));
    }
    if block_terminator(htd) == NONE { block_move_before(htd, hcs); block_append_inst(htd, create_br(hcs)); }
    if block_terminator(hfd) == NONE { block_move_before(hfd, hcs); block_append_inst(hfd, create_br(hcs)); }
    if hoist_target == initial_ph {
        block_replace_successors_phi_uses_with(initial_ph, initial_ph, hcs);
        mssau_wire_old_predecessors_to_new_immediate_predecessor(c.mssau, block_get_single_successor(hoist_target), hcs, .[hoist_target]);
        dt_change_idom(c.dt, li_header(c.li, c.l), hcs);
        for * c.cfh_dest if it.b == initial_ph && it.a != inst_block(bi) it.b = hcs;
    }
    old_t := block_terminator(hoist_target);
    nbi := create_cond_br(op(bi, 0), htd, hfd);
    insert_at_position(nbi, hoist_target, old_t, false);
    erase_inst_with_metadata(old_t);
    prof := get_metadata(bi, md_kind_id("prof"));
    if prof != NONE set_metadata(nbi, md_kind_id("prof"), prof);
    for c.cfh_dest if it.a == bb return it.b;
    return NONE;
}

// isLoadInvariantInLoop
licm_is_load_invariant_in_loop :: (c: *Licm, ld: Value_Id) -> bool {
    addr := op(ld, 0);
    ty := vtype(ld);
    if type_is_scalable(ty) return false;
    size_bits := dl_type_size_bits(ty);
    if is_constant_kind(vkind(addr)) return false;
    visited := 0;
    u := ir.v_first_use[addr];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        visited += 1;
        if visited > licm_opts.max_num_uses_traversed return false;
        if !is_inst(usr) || call_iid(usr) != IID_INVARIANT_START || has_uses(usr) continue;
        sz := call_arg(usr, 0);
        szv := const_ap(sz);
        if ap_is_negative(szv) continue;
        inv_bits := cast(u64)(ap_sext_value(szv) * 8);
        if size_bits <= inv_bits && dt_properly_dominates(c.dt, inst_block(usr), li_header(c.li, c.l)) return true;
    }
    return false;
}

// isHoistableAndSinkableInst
is_hoistable_and_sinkable_inst :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return o == .LOAD || o == .STORE || o == .CALL || o == .FENCE || is_cast_op(o) || o == .FNEG || is_binary_op(o) ||
           o == .SELECT || o == .GEP || o == .ICMP || o == .FCMP || o == .INSERTELEMENT || o == .EXTRACTELEMENT ||
           o == .SHUFFLEVECTOR || o == .EXTRACTVALUE || o == .INSERTVALUE || o == .FREEZE;
}

// isOnlyMemoryAccess
licm_is_only_memory_access :: (c: *Licm, i: Value_Id) -> bool {
    m := c.mssa;
    for b: li_blocks(c.li, c.l) {
        not_a_phi := 0;
        a := mssa_first_access(m, b);
        while a >= 0 {
            defer a = m.acc[a].next;
            if ma_is_phi(m, a) continue;
            if m.acc[a].inst != i return false;
            if not_a_phi == 1 return false;
            not_a_phi += 1;
        }
    }
    return true;
}

// getClobberingMemoryAccess(MSSA, BAA, Flags, MA)
licm_get_clobbering_memory_access :: (c: *Licm, q: *Aa_Query, a: s32) -> s32 {
    if c.opt_counter >= c.opt_cap return ma_defining(c.mssa, a);
    src := mssa_get_clobbering_access_skip_self(c.mssa, a, q);
    c.opt_counter += 1;
    return src;
}

// canHoistLoad
licm_can_hoist_load :: (c: *Licm, ld: Value_Id, target_executes_once_per_loop: bool) -> bool {
    if !is_unordered(ld) return false;
    q := aa_query_new(*c.aar);
    if (aa_mod_ref_mask(q, mloc_before_or_after(op(ld, 0))) & MR_MOD) == 0 return true;
    if get_metadata(ld, md_kind_id("invariant.load")) != NONE return true;
    if inst(ld).ord1 != 0 && !target_executes_once_per_loop return false;   // isAtomic
    if licm_is_load_invariant_in_loop(c, ld) return true;
    mu := mssa_access_of(c.mssa, ld);
    assert(mu >= 0 && ma_is_use(c.mssa, mu));
    inv_group := get_metadata(ld, md_kind_id("invariant.group")) != NONE;
    return !licm_pointer_invalidated_by_loop(c, mu, ld, inv_group);
}

// canSinkOrHoistInst
licm_can_sink_or_hoist_inst :: (c: *Licm, i: Value_Id, target_executes_once_per_loop: bool) -> bool {
    if !is_hoistable_and_sinkable_inst(i) return false;
    m := c.mssa;
    o := inst_op(i);
    if o == .LOAD return licm_can_hoist_load(c, i, target_executes_once_per_loop);
    if o == .CALL {
        if may_throw(i) return false;
        if call_is_convergent(i) return false;
        if fn_has_fn_attr(inst_fn(i), .PresplitCoroutine) return false;
        if call_iid(i) == IID_ASSUME return true;
        q := aa_query_new(*c.aar);
        behavior := aa_memory_effects_call(q, i);
        if mem_does_not_access(behavior) return true;
        if mem_only_reads(behavior) {
            mu := mssa_access_of(m, i);
            if mu < 0 || !ma_is_use(m, mu) return false;
            return !licm_pointer_invalidated_by_loop(c, mu, i, false);
        }
        if mem_only_writes(behavior) return licm_no_conflicting_read_writes(c, i);
        return false;
    }
    if o == .FENCE return licm_is_only_memory_access(c, i);
    if o == .STORE {
        if !is_unordered(i) return false;
        if licm_is_only_memory_access(c, i) return true;
        return licm_no_conflicting_read_writes(c, i);
    }
    assert(!may_read_or_write_memory(i), "unhandled aliasing");
    return true;
}

// isTriviallyReplaceablePHI
is_trivially_replaceable_phi :: (pn: Value_Id, i: Value_Id) -> bool {
    for k: 0..cast(s64) nops(pn) - 1 if op(pn, cast(u32) k) != i return false;
    return true;
}

// isFoldableInLoop
licm_is_foldable_in_loop :: (c: *Licm, i: Value_Id, cl: Loop_Id) -> bool {
    if inst_op(i) != .GEP return false;
    cost := tti_instruction_cost(c.tti, i, TCK_SIZE_AND_LATENCY);
    if cost != TCC_FREE return false;
    bb := inst_block(i);
    u := ir.v_first_use[i];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if li_contains(c.li, cl, inst_block(ui)) && (bb != inst_block(ui) || (inst_op(ui) != .STORE && inst_op(ui) != .LOAD)) return false;
    }
    return true;
}

// isNotUsedOrFoldableInLoop (LoopNestMode = false; no funclet colours)
licm_is_not_used_or_foldable_in_loop :: (c: *Licm, i: Value_Id, foldable_in_loop: *bool) -> bool {
    lnm := c.outermost != NONE;
    cl := ifx lnm then c.outermost else c.l;
    is_foldable := licm_is_foldable_in_loop(c, i, cl);
    u := ir.v_first_use[i];
    while u != NONE {
        ui := ir.u_user[u];
        u = ir.u_next[u];
        if lnm && inst_op(ui) == .PHI {
            while inst_op(ui) == .PHI && has_one_user(ui) && nops(ui) == 1 {
                if !li_contains(c.li, cl, inst_block(ui)) break;
                ui = ir.u_user[ir.v_first_use[ui]];
            }
        }
        if inst_op(ui) == .PHI {
            pb := inst_block(ui);
            if inst_op(block_terminator(pb)) == .CATCHSWITCH return false;
            if inst_op(i) == .CALL && lsi_has_colors(c.safety) {
                cv := table_find_pointer(*c.safety.block_colors, pb);
                if !cv || cv.count != 1 return false;
            }
        }
        if li_contains(c.li, cl, inst_block(ui)) {
            if is_foldable { foldable_in_loop.* = true; continue; }
            return false;
        }
    }
    return true;
}

// Instruction::mergeDIAssignID(SourceInstructions)
licm_merge_di_assign_id :: (k: Value_Id, sources: [] Value_Id) {
    kind := md_kind_id("DIAssignID");
    ids: [..] Md_Id; ids.allocator = temp;
    for sources { a := get_metadata(it, kind); if a != NONE array_add(*ids, a); }
    b := get_metadata(k, kind); if b != NONE array_add(*ids, b);
    if ids.count == 0 return;
    merge := ids[0];
    for ids {
        if it_index == 0 || it == merge continue;
        old := it;
        f := inst_fn(k);
        for bb: fn_blocks(f) for x: block_insts(bb) if get_metadata(x, kind) == old set_metadata(x, kind, merge);
        for * r: ir.dbg_records if r.assign_id == old r.assign_id = merge;
    }
    set_metadata(k, kind, merge);
}

// LoopInfo::wouldBeOutOfLoopUseRequiringLCSSA
would_be_out_of_loop_use_requiring_lcssa :: (li: *Loop_Info, v: Value_Id, exit_bb: Value_Id) -> bool {
    if type_kind(vtype(v)) == .TOKEN return false;
    if !is_inst(v) return false;
    l := li_loop_for(li, inst_block(v));
    if l == NONE return false;
    if li_contains(li, l, exit_bb) return false;
    return true;
}

// cloneInstructionInExitBlock
licm_clone_instruction_in_exit_block :: (c: *Licm, i: Value_Id, exit: Value_Id, pn: Value_Id) -> Value_Id {
    if inst_op(i) == .CALL {
        if call_num_bundles(i) > 0 && call_has_bundle(i, "funclet") fatal("LICM: sinking a call with a funclet bundle is not implemented yet");
        if lsi_has_colors(c.safety) {
            cv := table_find_pointer(*c.safety.block_colors, exit);
            assert(cv != null && cv.count == 1, "non-unique color for exit block!");
            if block_is_eh_pad(cv.*[0]) fatal("LICM: sinking a call into a funclet (adding a funclet bundle) is not implemented yet");
        }
    }
    nw := ic_clone_inst(i);   // CallInst::Create(CI, OpBundles) + copyMetadata for calls: the same without funclets
    insert_at_position(nw, exit, block_first_insertion_pt(exit), true);
    // CallInst::Create(CI, ...) names the clone CI's name; inserting it into the function uniquifies that name (one
    // ++LastUnique in the symbol table) before the setName below (knowledge/llvm/scalar-misc.md "LICM naming")
    if inst_op(i) == .CALL && vname(i).count set_name(nw, vname(i));
    if vname(i).count set_name(nw, tprint("%.le", vname(i)));
    if mssa_access_of(c.mssa, i) >= 0 {
        na := mssau_create_memory_access_in_bb(c.mssau, nw, -1, inst_block(nw), .BEGINNING, false);
        if na >= 0 {
            if ma_is_def(c.mssa, na) mssau_insert_def(c.mssau, na, true);
            else mssau_insert_use(c.mssau, na, true);
        }
    }
    for k: 0..cast(s64) nops(nw) - 1 {
        o := op(nw, cast(u32) k);
        if would_be_out_of_loop_use_requiring_lcssa(c.li, o, inst_block(pn)) {
            np := nops(pn);
            opn := create_phi(vtype(o), np);
            insert_at_position(opn, exit, block_first(exit), true);
            set_name(opn, tprint("%.lcssa", vname(o)));
            for j: 0..cast(s64) np - 1 phi_add_incoming(opn, o, phi_block(pn, cast(u32) j));
            set_op(nw, cast(u32) k, opn);
        }
    }
    return nw;
}

// canSplitPredecessors
licm_can_split_predecessors :: (c: *Licm, pn: Value_Id) -> bool {
    bb := inst_block(pn);
    if !block_can_split_predecessors(bb) return false;
    if lsi_has_colors(c.safety) && block_is_eh_pad(bb) return false;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for preds if inst_op(block_terminator(it)) == .INDIRECTBR return false;
    return true;
}

// splitPredecessorsOfLoopExit (DomTreeUpdater with the Lazy strategy: flushed by getDomTree() inside each split)
licm_split_predecessors_of_loop_exit :: (c: *Licm, pn: Value_Id) {
    exit_bb := inst_block(pn);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(exit_bb, *preds);
    uniq: [..] Value_Id; uniq.allocator = temp;
    for preds { dup := false; for x: uniq if x == it { dup = true; break; } if !dup array_add(*uniq, it); }
    for pred: uniq {
        if phi_block_index(pn, pred) >= 0 {
            np := split_block_predecessors(exit_bb, .[pred], ".split.loop.exit", c.dt, c.li, c.mssau, true, use_dtu = true);
            if lsi_has_colors(c.safety) lsi_copy_colors(c.safety, np, pred);
        }
    }
}

// sink
licm_sink :: (c: *Licm, i: Value_Id) -> bool {
    changed := false;
    visited: [..] Value_Id; visited.allocator = temp;
    is_visited :: (v: [] Value_Id, x: Value_Id) -> bool { for v if it == x return true; return false; }
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        cur := u;
        u = ir.u_next[u];
        if is_visited(visited, usr) || licm_contains_inst(c, usr) continue;
        if !dt_is_reachable_from_entry(c.dt, inst_block(usr)) {
            use_set(cur, const_poison(vtype(i)));
            changed = true;
            continue;
        }
        assert(inst_op(usr) == .PHI, "LICM: an out-of-loop user that is not an LCSSA phi");
        k := cur - ir.v_ops[usr];
        bb := phi_block(usr, k);
        if !dt_is_reachable_from_entry(c.dt, bb) {
            use_set(cur, const_poison(vtype(i)));
            changed = true;
            continue;
        }
        array_add(*visited, usr);
        if is_trivially_replaceable_phi(usr, i) continue;
        if !licm_can_split_predecessors(c, usr) return changed;
        licm_split_predecessors_of_loop_exit(c, usr);
        u = ir.v_first_use[i];
    }
    if visited.count == 0 return changed;
    sunk: [..] struct { exit: Value_Id; nw: Value_Id; }; sunk.allocator = temp;
    users: [..] Value_Id; users.allocator = temp;
    u = ir.v_first_use[i];
    while u != NONE { x := ir.u_user[u]; if !is_visited(users, x) array_add(*users, x); u = ir.u_next[u]; }
    for usr: users {
        if licm_contains_inst(c, usr) continue;
        pn := usr;
        exit := inst_block(pn);
        nw: Value_Id = NONE;
        for sunk if it.exit == exit { nw = it.nw; break; }
        if nw == NONE {
            nw = licm_clone_instruction_in_exit_block(c, i, exit, pn);
            array_add(*sunk, .{exit, nw});
        }
        drop_location(nw);
        rauw_with_metadata(pn, nw);
        licm_erase_instruction(c, pn);
        changed = true;
    }
    return changed;
}

// moveInstructionBefore(I, Dest, SafetyInfo, MSSAU, SE): Dest = `pos` (head: the iterator has the head bit)
licm_move_instruction_before :: (c: *Licm, i: Value_Id, pos: Value_Id, head := false) {
    dest := inst_block(pos);
    lsi_remove_instruction(c.safety, i);
    lsi_insert_instruction_to(c.safety, i, dest);
    if !head inst_move_before_dbg(i, pos);
    else {
        // moveBefore(BB, It) with the head bit: the records stay behind (on the next instruction), none are absorbed
        if inst(i).records && inst_next(i) != NONE records_prepend(inst_next(i), records_take(i));
        inst_unlink(i);
        inst_insert_before(i, pos);
    }
    a := mssa_access_of(c.mssa, i);
    if a >= 0 mssau_move_to_place(c.mssau, a, dest, .BEFORE_TERMINATOR);
    pse_forget_block_and_loop_dispositions(i);
}

// hoist
licm_hoist :: (c: *Licm, i: Value_Id, dest: Value_Id) {
    has_md := false;
    {
        all: [..] Kind_Md; all.allocator = temp;
        get_all_metadata(i, *all);
        for all if it.kind != 0 { has_md = true; break; }
    }
    if (has_md || inst_op(i) == .CALL) && !lsi_is_guaranteed_to_execute(c.safety, i, c.dt, c.l) drop_ub_implying_attrs_and_metadata(i);
    if inst_op(i) == .PHI licm_move_instruction_before(c, i, block_first_non_phi(dest), true);
    else licm_move_instruction_before(c, i, block_terminator(dest));
    drop_location(i);   // updateLocationAfterHoist
}

// isSafeToSpeculativelyExecute(I, CtxI, AC, DT, TLI) (UseVariableInfo, IgnoreUBImplyingAttrs = true)
licm_is_safe_to_speculatively_execute :: (i: Value_Id, ctx: Value_Id, ac: *Assumption_Cache, dt: *Dom_Tree) -> bool {
    if inst_op(i) == .LOAD {
        if !is_unordered(i) return false;   // mustSuppressSpeculation
        fa := attr_list_fn(glob(inst_fn(i)).attrs);
        if attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;
        q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = ctx;
        return is_dereferenceable_and_aligned_pointer_ty(op(i, 0), vtype(i), inst(i).align, q);
    }
    return is_safe_to_speculatively_execute(i);
}

// isSafeToExecuteUnconditionally
licm_is_safe_to_execute_unconditionally :: (c: *Licm, i: Value_Id, ctx: Value_Id) -> bool {
    if c.allow_speculation && licm_is_safe_to_speculatively_execute(i, ctx, c.ac, c.dt) return true;
    return lsi_is_guaranteed_to_execute(c.safety, i, c.dt, c.l);
}

// PredIteratorCache
Pred_Cache :: struct { map: Table(Value_Id, [..] Value_Id); }
pred_cache_get :: (pc: *Pred_Cache, bb: Value_Id) -> [] Value_Id {
    p := table_find_pointer(*pc.map, bb);
    if p return p.*;
    l: [..] Value_Id; l.allocator = temp;
    block_predecessors(bb, *l);
    table_set(*pc.map, bb, l);
    return l;
}

// LoopPromoter (the LoadAndStorePromoter subclass; ssa_updater.jai calls these hooks for Lsp_Kind.LICM)
Licm_Promoter :: struct {
    c: *Licm;
    some_ptr: Value_Id;
    exits: *[..] Value_Id;
    insert_pts: *[..] Value_Id;
    mssa_insert_pts: *[..] s32;
    pred_cache: *Pred_Cache;
    dl: Md_Id;
    alignment: u64;
    unordered_atomic: bool;
    aa_tags: AA_Tags;
    can_insert_stores: bool;
    uses: [] Value_Id;
    ssa: *Ssa_Updater;
}
// maybeInsertLCSSAPHI
licm_maybe_insert_lcssa_phi :: (p: *Licm_Promoter, v: Value_Id, bb: Value_Id) -> Value_Id {
    if !would_be_out_of_loop_use_requiring_lcssa(p.c.li, v, bb) return v;
    preds := pred_cache_get(p.pred_cache, bb);
    pn := create_phi(vtype(v), cast(u32) preds.count);
    insert_at_position(pn, bb, block_first(bb), true);
    set_name(pn, tprint("%.lcssa", vname(v)));
    for preds phi_add_incoming(pn, v, it);
    return pn;
}
// insertStoresInLoopExitBlocks
licm_insert_stores_in_loop_exit_blocks :: (p: *Licm_Promoter) {
    new_id: Md_Id = NONE;
    kind := md_kind_id("DIAssignID");
    for exit, idx: p.exits.* {
        live_in := ssa_value_in_middle(p.ssa, exit);
        live_in = licm_maybe_insert_lcssa_phi(p, live_in, exit);
        ptr := licm_maybe_insert_lcssa_phi(p, p.some_ptr, exit);
        si := new_inst(.STORE, ir.t_void, 2);
        set_op(si, 0, live_in); set_op(si, 1, ptr);
        insert_at_position(si, exit, p.insert_pts.*[idx], true);
        if p.unordered_atomic inst(si).ord1 = ORD_UNORDERED;
        inst(si).align = p.alignment;
        set_metadata(si, 0, p.dl);
        if idx == 0 {
            licm_merge_di_assign_id(si, p.uses);
            new_id = get_metadata(si, kind);
        } else set_metadata(si, kind, new_id);
        if aa_any(p.aa_tags) set_aa_metadata(si, p.aa_tags);
        ip := p.mssa_insert_pts.*[idx];
        na: s32;
        if ip < 0 na = mssau_create_memory_access_in_bb(p.c.mssau, si, -1, exit, .BEGINNING);
        else na = mssau_create_memory_access_after(p.c.mssau, si, -1, ip);
        p.mssa_insert_pts.*[idx] = na;
        mssau_insert_def(p.c.mssau, na, true);
    }
}
licm_promoter_extra_rewrites :: (p: *Licm_Promoter) { if p.can_insert_stores licm_insert_stores_in_loop_exit_blocks(p); }
licm_promoter_instruction_deleted :: (p: *Licm_Promoter, i: Value_Id) {
    lsi_remove_instruction(p.c.safety, i);
    mssau_remove_memory_access_inst(p.c.mssau, i);
}
licm_promoter_should_delete :: (p: *Licm_Promoter, i: Value_Id) -> bool {
    if inst_op(i) == .STORE return p.can_insert_stores;
    return true;
}

// isNotCapturedBeforeOrInLoop
licm_is_not_captured_before_or_in_loop :: (c: *Licm, v: Value_Id) -> bool {
    return pointer_may_be_captured_before(v, true, block_terminator(li_header(c.li, c.l)), c.dt, false, CC_PROVENANCE) == CC_NONE;
}
// isNotVisibleOnUnwindInLoop
licm_is_not_visible_on_unwind_in_loop :: (c: *Licm, obj: Value_Id) -> bool {
    ok, requires_no_capture := is_not_visible_on_unwind(obj);
    if !ok return false;
    return !requires_no_capture || licm_is_not_captured_before_or_in_loop(c, obj);
}
// isThreadLocalObject (TTI->isSingleThreaded(): X86 and NoTTI answer false for the default thread model)
licm_is_thread_local_object :: (c: *Licm, obj: Value_Id) -> bool {
    return (is_identified_function_local(obj) && licm_is_not_captured_before_or_in_loop(c, obj)) || licm_opts.single_thread;
}

// promoteLoopAccessesToScalars
licm_promote_loop_accesses_to_scalars :: (c: *Licm, ptrs: [] Value_Id, exits: *[..] Value_Id, insert_pts: *[..] Value_Id,
                                          mssa_insert_pts: *[..] s32, pic: *Pred_Cache, has_reads_outside: bool, preheader: Value_Id) -> bool {
    some_ptr := ptrs[0];
    deref_in_ph := false;
    store_guaranteed := false;
    load_guaranteed := false;
    found_load := false;
    Store_Safety :: enum u8 { SAFE; UNSAFE; UNKNOWN; }
    store_safety := Store_Safety.UNKNOWN;
    loop_uses: [..] Value_Id; loop_uses.allocator = temp;
    alignment: u64 = 1;
    saw_unordered_atomic := false;
    saw_not_atomic := false;
    aa_tags: AA_Tags;
    if has_reads_outside store_safety = .UNSAFE;
    if store_safety == .UNKNOWN && c.safety.may_throw {
        obj := get_underlying_object(some_ptr);
        if !licm_is_not_visible_on_unwind_in_loop(c, obj) store_safety = .UNSAFE;
    }
    access_ty: Type_Id = NONE;
    pterm := block_terminator(preheader);
    for asiv: ptrs {
        u := ir.v_first_use[asiv];
        while u != NONE {
            ui := ir.u_user[u];
            opno := u - ir.v_ops[ui];
            u = ir.u_next[u];
            if !is_inst(ui) || !licm_contains_inst(c, ui) continue;
            o := inst_op(ui);
            if o == .LOAD {
                if !is_unordered(ui) return false;
                atomic := inst(ui).ord1 != 0;
                saw_unordered_atomic |= atomic;
                saw_not_atomic |= !atomic;
                found_load = true;
                ia := inst(ui).align;
                if !load_guaranteed load_guaranteed = lsi_is_guaranteed_to_execute(c.safety, ui, c.dt, c.l);
                if !deref_in_ph || ia > alignment {
                    if licm_is_safe_to_execute_unconditionally(c, ui, pterm) {
                        deref_in_ph = true;
                        alignment = max(alignment, ia);
                    }
                }
            } else if o == .STORE {
                if opno != 1 continue;
                if !is_unordered(ui) return false;
                atomic := inst(ui).ord1 != 0;
                saw_unordered_atomic |= atomic;
                saw_not_atomic |= !atomic;
                ia := inst(ui).align;
                guaranteed := lsi_is_guaranteed_to_execute(c.safety, ui, c.dt, c.l);
                store_guaranteed |= guaranteed;
                if guaranteed {
                    deref_in_ph = true;
                    if store_safety == .UNKNOWN store_safety = .SAFE;
                    alignment = max(alignment, ia);
                }
                if store_safety == .UNKNOWN {
                    all := true;
                    for e: exits.* if !dt_dominates(c.dt, inst_block(ui), e) { all = false; break; }
                    if all store_safety = .SAFE;
                }
                if !deref_in_ph {
                    q: Simplify_Query; q.dt = c.dt; q.ac = c.ac; q.cxt = pterm;
                    deref_in_ph = is_dereferenceable_and_aligned_pointer_ty(op(ui, 1), vtype(op(ui, 0)), inst(ui).align, q);
                }
            } else continue;
            lst := ifx o == .LOAD then vtype(ui) else vtype(op(ui, 0));
            if access_ty == NONE access_ty = lst;
            else if access_ty != lst return false;
            if loop_uses.count == 0 aa_tags = get_aa_metadata(ui);
            else if aa_any(aa_tags) aa_tags = aa_merge(aa_tags, get_aa_metadata(ui));
            array_add(*loop_uses, ui);
        }
    }
    if saw_unordered_atomic && saw_not_atomic return false;
    if saw_unordered_atomic && alignment < dl_type_store_size(access_ty) return false;
    if !deref_in_ph return false;
    if store_safety == .UNKNOWN {
        obj := get_underlying_object(some_ptr);
        ok, explicitly_deref_only := is_writable_object(obj);
        if ok {
            q0: Simplify_Query; q0.have_tli = false;
            if (!explicitly_deref_only || is_dereferenceable_pointer_ty(some_ptr, access_ty, q0, true)) && licm_is_thread_local_object(c, obj)
                store_safety = .SAFE;
        }
    }
    if store_safety != .SAFE && !found_load return false;

    // DebugLoc::getMergedLocations
    dl: Md_Id = NONE;
    for loop_uses {
        l := get_metadata(it, 0);
        if it_index == 0 dl = l;
        else { dl = merged_location(dl, l); if dl == NONE break; }
    }
    new_phis: [..] Value_Id; new_phis.allocator = temp;
    ssa: Ssa_Updater;
    ssa.inserted_phis = *new_phis;
    // LoadAndStorePromoter(Insts, SSA, BaseName = ""): SSA.Initialize(SomeVal->getType(), SomeVal->getName())
    {
        first := loop_uses[0];
        some_val := ifx inst_op(first) == .LOAD then first else op(first, 0);
        ssa_init(*ssa, vtype(some_val), vname(some_val));
    }
    pr: Licm_Promoter;
    pr.c = c; pr.some_ptr = some_ptr; pr.exits = exits; pr.insert_pts = insert_pts; pr.mssa_insert_pts = mssa_insert_pts;
    pr.pred_cache = pic; pr.dl = dl; pr.alignment = alignment; pr.unordered_atomic = saw_unordered_atomic;
    if store_guaranteed pr.aa_tags = aa_tags;
    pr.can_insert_stores = store_safety == .SAFE;
    pr.uses = loop_uses;
    pr.ssa = *ssa;
    ph_load: Value_Id = NONE;
    if found_load || !store_guaranteed {
        ph_load = new_inst(.LOAD, access_ty, 1);
        set_op(ph_load, 0, some_ptr);
        insert_at_position(ph_load, preheader, pterm, false);
        set_name(ph_load, tprint("%.promoted", vname(some_ptr)));
        if saw_unordered_atomic inst(ph_load).ord1 = ORD_UNORDERED;
        inst(ph_load).align = alignment;
        set_metadata(ph_load, 0, NONE);
        if aa_any(aa_tags) && load_guaranteed set_aa_metadata(ph_load, aa_tags);
        na := mssau_create_memory_access_in_bb(c.mssau, ph_load, -1, preheader, .END);
        assert(ma_is_use(c.mssa, na));
        mssau_insert_use(c.mssau, na, true);
        ssa_add_available(*ssa, preheader, ph_load);
    } else ssa_add_available(*ssa, preheader, const_poison(access_ty));
    if mssa_opts.verify mssa_verify(c.mssa);
    hooks: Lsp_Hooks; hooks.kind = .LICM; hooks.licm = *pr;
    load_and_store_promote(loop_uses, *ssa, NONE, hooks);
    if mssa_opts.verify mssa_verify(c.mssa);
    if ph_load != NONE && !has_uses(ph_load) licm_erase_instruction(c, ph_load);
    return true;
}

Promotion_Candidate :: struct { ptrs: [..] Value_Id; has_reads_outside: bool; }

// collectPromotionCandidates
licm_collect_promotion_candidates :: (c: *Licm) -> [..] Promotion_Candidate {
    result: [..] Promotion_Candidate; result.allocator = temp;
    q := aa_query_new(*c.aar);
    ast: Alias_Set_Tracker;
    ast_init(*ast, q);
    m := c.mssa;
    is_potentially_promotable :: (c: *Licm, i: Value_Id) -> bool {
        o := inst_op(i);
        if o == .STORE { p := op(i, 1); return !is_constant_data(p) && licm_inv(c, p); }
        if o == .LOAD { p := op(i, 0); return !is_constant_data(p) && licm_inv(c, p); }
        return false;
    }
    attempting: Table(Value_Id, bool); attempting.allocator = temp;
    for b: li_blocks(c.li, c.l) {
        a := mssa_first_access(m, b);
        while a >= 0 {
            if !ma_is_phi(m, a) {
                i := m.acc[a].inst;
                if is_potentially_promotable(c, i) { table_set(*attempting, i, true); ast_add(*ast, i); }
            }
            a = m.acc[a].next;
        }
    }
    Set_Pair :: struct { s: s32; reads_outside: bool; }
    sets: [..] Set_Pair; sets.allocator = temp;
    for * ast.sets {
        if it.removed continue;
        if it.forward < 0 && ast_is_mod(it) && ast_is_must_alias(it) array_add(*sets, .{cast(s32) it_index, false});
    }
    if sets.count == 0 return result;
    for b: li_blocks(c.li, c.l) {
        a := mssa_first_access(m, b);
        while a >= 0 {
            defer a = m.acc[a].next;
            if ma_is_phi(m, a) continue;
            i := m.acc[a].inst;
            if table_contains(*attempting, i) continue;
            k := 0;
            for spv: sets {
                sp := spv;
                mr := ast_aliases_unknown_inst(*ast, sp.s, i);
                keep := true;
                if mr & MR_MOD keep = false;
                else if mr & MR_REF {
                    sp.reads_outside = true;
                    keep = ast_is_ref(*ast.sets[sp.s]);
                }
                if keep { sets[k] = sp; k += 1; }
            }
            sets.count = k;
        }
    }
    for sp: sets {
        pc: Promotion_Candidate; pc.ptrs.allocator = temp;
        for loc: ast.sets[sp.s].locs {
            dup := false;
            for pc.ptrs if it == loc.ptr { dup = true; break; }
            if !dup array_add(*pc.ptrs, loc.ptr);
        }
        pc.has_reads_outside = sp.reads_outside;
        array_add(*result, pc);
    }
    return result;
}

// noConflictingReadWrites
licm_no_conflicting_read_writes :: (c: *Licm, i: Value_Id) -> bool {
    if c.too_many_mem_acc return false;
    m := c.mssa;
    imd := mssa_access_of(m, i);
    q := aa_query_new(*c.aar);
    src := licm_get_clobbering_memory_access(c, q, imd);
    if !is_live_on_entry(src) && li_contains(c.li, c.l, m.acc[src].block) return false;
    for b: li_blocks(c.li, c.l) {
        a := mssa_first_access(m, b);
        while a >= 0 {
            defer a = m.acc[a].next;
            if !c.is_sink && mssa_dominates(m, imd, a) break;
            if !ma_is_phi(m, a) {
                if aa_mod_ref_inst_inst(q, m.acc[a].inst, i) == MR_NO continue;
                return false;
            }
        }
    }
    return true;
}

// pointerInvalidatedByLoop
licm_pointer_invalidated_by_loop :: (c: *Licm, mu: s32, i: Value_Id, invariant_group: bool) -> bool {
    m := c.mssa;
    if !c.is_sink {
        q := aa_query_new(*m.aar);
        src := licm_get_clobbering_memory_access(c, q, mu);
        return !is_live_on_entry(src) && li_contains(c.li, c.l, m.acc[src].block) &&
               !(invariant_group && m.acc[src].block == li_header(c.li, c.l) && ma_is_phi(m, src));
    }
    if c.too_many_mem_acc return true;
    for b: li_blocks(c.li, c.l) if licm_pointer_invalidated_by_block(m, b, mu) return true;
    if !licm_contains_inst(c, i) return licm_pointer_invalidated_by_block(m, inst_block(i), mu);
    return false;
}
// pointerInvalidatedByBlock
licm_pointer_invalidated_by_block :: (m: *Memory_SSA, bb: Value_Id, mu: s32) -> bool {
    d := mssa_first_block_def(m, bb);
    while d >= 0 {
        if ma_is_def(m, d) {
            if m.acc[mu].block != m.acc[d].block || !mssa_locally_dominates(m, d, mu) return true;
        }
        d = m.acc[d].dnext;
    }
    return false;
}

// ---------------------------------------------------------------- hoistArithmetics

// hoistMinMax
licm_hoist_min_max :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    inverse := false;
    ok, cond1, cond2 := pm_logical_or(i);
    if ok inverse = true;
    else {
        ok, cond1, cond2 = pm_logical_and(i);
        if !ok return false;
    }
    match :: (c: *Licm, cnd: Value_Id, inverse: bool) -> (bool, u8, bool, Value_Id, Value_Id) {
        ok, p, ss, lhs, rhs := pm_icmp(cnd);
        if !ok || !has_one_use(cnd) return false, 0, false, NONE, NONE;
        if !is_int_type(vtype(lhs)) return false, 0, false, NONE, NONE;
        if !icmp_is_relational(p) return false, 0, false, NONE, NONE;
        if licm_inv(c, lhs) {
            t := lhs; lhs = rhs; rhs = t;
            p = cmp_swapped(p); ss = false;   // P = ICmpInst::getSwappedPredicate(P): samesign is dropped
        }
        if licm_inv(c, lhs) || !licm_inv(c, rhs) return false, 0, false, NONE, NONE;
        if inverse { p = cmp_inverse(p); ss = false; }
        return true, p, ss, lhs, rhs;
    }
    ok1, p1, ss1, lhs1, rhs1 := match(c, cond1, inverse);
    if !ok1 return false;
    ok2, p2, ss2, lhs2, rhs2 := match(c, cond2, inverse);
    if !ok2 return false;
    okm, mp, mss := cmp_get_matching(p1, ss1, p2, ss2);
    if !okm || lhs1 != lhs2 return false;
    use_min := icmp_is_lt(mp) || icmp_is_le(mp);
    id: Intrinsic_Id;
    if icmp_is_signed(mp) id = ifx use_min then IID_SMIN else IID_SMAX;
    else id = ifx use_min then IID_UMIN else IID_UMAX;
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    if inst_op(i) == .SELECT rhs2 = irb_freeze(*b, rhs2, tprint("%.fr", vname(rhs2)));
    fdecl := get_or_insert_intrinsic_declaration(id, .[vtype(rhs1)]);
    nm := tprint("invariant.%1%2", ifx icmp_is_signed(mp) then "s" else "u", ifx use_min then "min" else "max");
    new_rhs := irb_call(*b, fdecl, .[rhs1, rhs2], nm);
    irb_set_before(*b, i);
    p := mp;
    if inverse p = cmp_inverse(p);
    new_cond := irb_icmp(*b, p, lhs1, new_rhs);
    take_name(new_cond, i);
    rauw_with_metadata(i, new_cond);
    licm_erase_instruction(c, i);
    salvage_debug_info(cond1);
    salvage_debug_info(cond2);
    licm_erase_instruction(c, cond1);
    licm_erase_instruction(c, cond2);
    return true;
}

// hoistGEP
licm_hoist_gep :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    if inst_op(i) != .GEP return false;
    gep := i;
    if gep_has_all_constant_indices(gep) return false;
    src := op(gep, 0);
    if !is_inst(src) || inst_op(src) != .GEP || !has_one_use(src) || !licm_contains_inst(c, src) return false;
    src_ptr := op(src, 0);
    if !licm_inv(c, src_ptr) return false;
    for k: 1..cast(s64) nops(gep) - 1 if !licm_inv(c, op(gep, cast(u32) k)) return false;
    all_inv := true;
    for k: 1..cast(s64) nops(src) - 1 if !licm_inv(c, op(src, cast(u32) k)) { all_inv = false; break; }
    if all_inv return false;
    q: Simplify_Query; q.dt = c.dt; q.ac = c.ac; q.cxt = gep; q.have_tli = false;
    in_bounds := (inst(src).flags & F_INBOUNDS) != 0 && (inst(gep).flags & F_INBOUNDS) != 0;
    if in_bounds for k: 1..cast(s64) nops(src) - 1 if !is_known_non_negative(op(src, cast(u32) k), q) { in_bounds = false; break; }
    if in_bounds for k: 1..cast(s64) nops(gep) - 1 if !is_known_non_negative(op(gep, cast(u32) k), q) { in_bounds = false; break; }
    flags: u32 = ifx in_bounds then cast(u32)(F_INBOUNDS | F_NUSW) else 0;
    gidx: [..] Value_Id; gidx.allocator = temp;
    for k: 1..cast(s64) nops(gep) - 1 array_add(*gidx, op(gep, cast(u32) k));
    sidx: [..] Value_Id; sidx.allocator = temp;
    for k: 1..cast(s64) nops(src) - 1 array_add(*sidx, op(src, cast(u32) k));
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    new_src := irb_gep(*b, inst(gep).ty2, src_ptr, gidx, "invariant.gep", flags);
    irb_set_before(*b, gep);
    new_gep := irb_gep(*b, inst(src).ty2, new_src, sidx, "gep", flags);
    rauw_with_metadata(gep, new_gep);
    licm_erase_instruction(c, gep);
    salvage_debug_info(src);
    licm_erase_instruction(c, src);
    return true;
}

// hoistAdd
licm_hoist_add :: (c: *Licm, pred_in: u8, variant_lhs: Value_Id, invariant_rhs: Value_Id, icmp: Value_Id, preheader: Value_Id) -> bool {
    pred := pred_in;
    is_signed := icmp_is_signed(pred);
    ok: bool; variant_op, invariant_op: Value_Id;
    if is_signed ok, variant_op, invariant_op = pm_nsw_add_like_i(variant_lhs);
    else ok, variant_op, invariant_op = pm_nuw_add_like_i(variant_lhs);
    if !ok return false;
    if licm_inv(c, variant_op) { t := variant_op; variant_op = invariant_op; invariant_op = t; }
    if licm_inv(c, variant_op) || !licm_inv(c, invariant_op) return false;
    q: Simplify_Query; q.dt = c.dt; q.ac = c.ac; q.cxt = icmp; q.have_tli = false;
    if is_signed && compute_overflow_for_signed_sub(invariant_rhs, invariant_op, q) != .NEVER_OVERFLOWS return false;
    if !is_signed && compute_overflow_for_unsigned_sub(invariant_rhs, invariant_op, q) != .NEVER_OVERFLOWS return false;
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    flags: u32 = ifx is_signed then cast(u32) F_NSW else cast(u32) F_NUW;
    new_op := irb_binop(*b, .SUB, invariant_rhs, invariant_op, "invariant.op", flags);
    inst(icmp).pred = pred;
    set_op(icmp, 0, variant_op);
    set_op(icmp, 1, new_op);
    drop_poison_generating_flags(icmp);
    salvage_debug_info(variant_lhs);
    licm_erase_instruction(c, variant_lhs);
    return true;
}

// hoistSub
licm_hoist_sub :: (c: *Licm, pred_in: u8, variant_lhs: Value_Id, invariant_rhs: Value_Id, icmp: Value_Id, preheader: Value_Id) -> bool {
    pred := pred_in;
    is_signed := icmp_is_signed(pred);
    ok, variant_op, invariant_op := pm_ob(variant_lhs, .SUB, ifx is_signed then cast(u32) F_NSW else cast(u32) F_NUW);
    if !ok || !is_inst(variant_lhs) return false;
    variant_subtracted := false;
    if licm_inv(c, variant_op) {
        t := variant_op; variant_op = invariant_op; invariant_op = t;
        variant_subtracted = true;
        pred = cmp_swapped(pred);
    }
    if licm_inv(c, variant_op) || !licm_inv(c, invariant_op) return false;
    q: Simplify_Query; q.dt = c.dt; q.ac = c.ac; q.cxt = icmp; q.have_tli = false;
    if variant_subtracted && is_signed {
        if compute_overflow_for_signed_sub(invariant_op, invariant_rhs, q) != .NEVER_OVERFLOWS return false;
    } else if variant_subtracted && !is_signed {
        if compute_overflow_for_unsigned_sub(invariant_op, invariant_rhs, q) != .NEVER_OVERFLOWS return false;
    } else if !variant_subtracted && is_signed {
        if compute_overflow_for_signed_add(invariant_op, invariant_rhs, q) != .NEVER_OVERFLOWS return false;
    } else {
        if compute_overflow_for_unsigned_add(invariant_op, invariant_rhs, q) != .NEVER_OVERFLOWS return false;
    }
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    flags: u32 = ifx is_signed then cast(u32) F_NSW else cast(u32) F_NUW;
    new_op := irb_binop(*b, ifx variant_subtracted then Opcode.SUB else .ADD, invariant_op, invariant_rhs, "invariant.op", flags);
    inst(icmp).pred = pred;
    set_op(icmp, 0, variant_op);
    set_op(icmp, 1, new_op);
    drop_poison_generating_flags(icmp);
    salvage_debug_info(variant_lhs);
    licm_erase_instruction(c, variant_lhs);
    return true;
}

// hoistAddSub
licm_hoist_add_sub :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    ok, pred, ss, lhs, rhs := pm_icmp(i);
    if !ok return false;
    if licm_inv(c, lhs) { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(pred); }
    if licm_inv(c, lhs) || !licm_inv(c, rhs) || !has_one_use(lhs) return false;
    if licm_hoist_add(c, pred, lhs, rhs, i, preheader) return true;
    if licm_hoist_sub(c, pred, lhs, rhs, i, preheader) return true;
    return false;
}

// isReassociableOp
is_reassociable_op :: (i: Value_Id, int_opc: Opcode, fp_opc: Opcode) -> bool {
    if inst_op(i) == int_opc return true;
    if inst_op(i) == fp_opc { f := get_fmf(i); if (f & FMF_REASSOC) && (f & FMF_NSZ) return true; }
    return false;
}

// hoistMulAddAssociation
licm_hoist_mul_add_association :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    if !is_reassociable_op(i, .MUL, .FMUL) return false;
    variant_op := op(i, 0);
    invariant_op := op(i, 1);
    if licm_inv(c, variant_op) { t := variant_op; variant_op = invariant_op; invariant_op = t; }
    if licm_inv(c, variant_op) || !licm_inv(c, invariant_op) return false;
    factor := invariant_op;
    Use_Ref :: struct { user: Value_Id; k: u32; }
    changes: [..] Use_Ref; changes.allocator = temp;
    adds: [..] Value_Id; adds.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    if is_binary_operator(variant_op) array_add(*worklist, variant_op);
    is_int := is_int_type(scalar_type(vtype(i)));
    while worklist.count {
        bo := pop(*worklist);
        if !has_one_use(bo) return false;
        if is_reassociable_op(bo, .ADD, .FADD) && is_binary_operator(op(bo, 0)) && is_binary_operator(op(bo, 1)) {
            array_add(*worklist, op(bo, 0));
            array_add(*worklist, op(bo, 1));
            array_add(*adds, bo);
            continue;
        }
        if !is_reassociable_op(bo, .MUL, .FMUL) || licm_inv(c, bo) return false;
        if licm_inv(c, op(bo, 0)) array_add(*changes, .{bo, 0});
        else if licm_inv(c, op(bo, 1)) array_add(*changes, .{bo, 1});
        else return false;
        limit := ifx is_int then licm_opts.int_association_upper_limit else licm_opts.fp_association_upper_limit;
        if changes.count > limit return false;
    }
    if changes.count == 0 return false;
    if is_int for adds drop_poison_generating_flags(it);
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    for ch: changes {
        ins := ch.user;
        v := op(ins, ch.k);
        mul: Value_Id;
        if is_int {
            mul = irb_binop(*b, .MUL, v, factor, "factor.op.mul");
            drop_poison_generating_flags(ins);
        } else {
            mul = irb_binop(*b, .FMUL, v, factor, "factor.op.fmul");
            if is_inst(mul) set_fmf(mul, get_fmf(ins));
        }
        lhs := ifx ch.k == 0 then mul else op(ins, 0);
        rhs := ifx ch.k == 1 then mul else op(ins, 1);
        nbo := create_binop(inst_op(ins), lhs, rhs);
        insert_at_position(nbo, inst_block(ins), ins, false);
        set_name(nbo, tprint("%.reass", vname(ins)));
        set_metadata(nbo, 0, NONE);
        copy_ir_flags(nbo, ins);
        if variant_op == ins variant_op = nbo;
        rauw_with_metadata(ins, nbo);
        licm_erase_instruction(c, ins);
    }
    rauw_with_metadata(i, variant_op);
    licm_erase_instruction(c, i);
    return true;
}

// OverflowTracking::mergeFlags / applyFlags
Overflow_Tracking :: struct { has_nuw := true; has_nsw := true; is_disjoint := true; all_known_non_negative := true; all_known_non_zero := true; }
ot_merge_flags :: (t: *Overflow_Tracking, i: Value_Id) {
    o := inst_op(i);
    if o == .ADD || o == .SUB || o == .MUL || o == .SHL {
        t.has_nuw = t.has_nuw && (inst(i).flags & F_NUW) != 0;
        t.has_nsw = t.has_nsw && (inst(i).flags & F_NSW) != 0;
    }
    if o == .OR t.is_disjoint = t.is_disjoint && (inst(i).flags & F_EXACT) != 0;
}
ot_apply_flags :: (t: *Overflow_Tracking, i: Value_Id) {
    drop_poison_generating_flags(i);
    o := inst_op(i);
    if o == .ADD || (o == .MUL && t.all_known_non_zero) {
        if t.has_nuw inst(i).flags |= F_NUW;
        if t.has_nsw && (t.all_known_non_negative || t.has_nuw) inst(i).flags |= F_NSW;
    }
    if o == .OR {
        if t.is_disjoint inst(i).flags |= F_EXACT; else inst(i).flags &= ~cast(u32) F_EXACT;
    }
}

// hoistBOAssociation
licm_hoist_bo_association :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    if !is_binary_operator(i) || !inst_is_associative(i) return false;
    bo := i;
    opc := inst_op(bo);
    lv_in_rhs := licm_inv(c, op(bo, 0));
    bo0 := op(bo, ifx lv_in_rhs then cast(u32) 1 else 0);
    if !is_binary_operator(bo0) || inst_op(bo0) != opc || !inst_is_associative(bo0) ||
       has_n_uses_or_more(bo0, ifx type_kind(vtype(bo0)) == .INT then 2 else 3) return false;
    lv := op(bo0, 0);
    c1 := op(bo0, 1);
    c2 := op(bo, ifx lv_in_rhs then cast(u32) 0 else 1);
    if licm_inv(c, lv) && !licm_inv(c, c1) { t := lv; lv = c1; c1 = t; }
    if licm_inv(c, lv) || !licm_inv(c, c1) || !licm_inv(c, c2) return false;
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    inv := irb_binop(*b, opc, c1, c2, "invariant.op");
    nbo := create_binop(opc, lv, inv);
    insert_at_position(nbo, inst_block(bo), bo, false);
    set_name(nbo, tprint("%.reass", vname(bo)));
    set_metadata(nbo, 0, NONE);
    if opc == .FADD || opc == .FMUL {
        inter := get_fmf(bo) & get_fmf(bo0);
        if is_inst(inv) set_fmf(inv, inter);
        set_fmf(nbo, inter);
    } else {
        t: Overflow_Tracking;
        t.all_known_non_negative = false;
        t.all_known_non_zero = false;
        ot_merge_flags(*t, bo);
        ot_merge_flags(*t, bo0);
        if is_inst(inv) ot_apply_flags(*t, inv);
        ot_apply_flags(*t, nbo);
    }
    rauw_with_metadata(bo, nbo);
    licm_erase_instruction(c, bo);
    if !has_uses(bo0) {
        salvage_debug_info(bo0);
        licm_erase_instruction(c, bo0);
    }
    return true;
}

// hoistSubAddAssociation
licm_hoist_sub_add_association :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    bo, lv, c1, c2: Value_Id;
    inv_op, result_op: Opcode;
    matched := false;
    is_op :: (v: Value_Id, o: Opcode) -> bool { return is_inst(v) && inst_op(v) == o; }
    if is_op(i, .SUB) && is_op(op(i, 0), .ADD) && has_one_use(op(i, 0)) {
        bo = op(i, 0); lv = op(bo, 0); c1 = op(bo, 1); c2 = op(i, 1);
        if licm_inv(c, lv) && !licm_inv(c, c1) { t := lv; lv = c1; c1 = t; }
        inv_op = .SUB; result_op = .ADD;
        matched = true;
    } else if is_op(i, .SUB) && is_op(op(i, 0), .SUB) && has_one_use(op(i, 0)) {
        bo = op(i, 0); lv = op(bo, 0); c1 = op(bo, 1); c2 = op(i, 1);
        inv_op = .ADD; result_op = .SUB;
        matched = true;
    } else if is_op(i, .ADD) {
        // m_c_Add(m_OneUse(m_Instruction(BO, m_Sub(m_Value(LV), m_Value(C1)))), m_Value(C2))
        for side: 0..1 {
            x := op(i, cast(u32) side);
            if is_op(x, .SUB) && has_one_use(x) {
                bo = x; lv = op(x, 0); c1 = op(x, 1); c2 = op(i, cast(u32)(1 - side));
                matched = true;
                break;
            }
        }
        if matched { t := c1; c1 = c2; c2 = t; inv_op = .SUB; result_op = .ADD; }
    }
    if !matched return false;
    if licm_inv(c, lv) || !licm_inv(c, c1) || !licm_inv(c, c2) return false;
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    inv := irb_binop(*b, inv_op, c1, c2, "invariant.op");
    nbo := create_binop(result_op, lv, inv);
    insert_at_position(nbo, inst_block(i), i, false);
    set_name(nbo, tprint("%.reass", vname(i)));
    set_metadata(nbo, 0, NONE);
    rauw_with_metadata(i, nbo);
    licm_erase_instruction(c, i);
    salvage_debug_info(bo);
    licm_erase_instruction(c, bo);
    return true;
}

// hoistArithmetics
licm_hoist_arithmetics :: (c: *Licm, i: Value_Id, preheader: Value_Id) -> bool {
    if licm_hoist_min_max(c, i, preheader) return true;
    if licm_hoist_gep(c, i, preheader) return true;
    if licm_hoist_add_sub(c, i, preheader) return true;
    if licm_hoist_mul_add_association(c, i, preheader) return true;
    if licm_hoist_bo_association(c, i, preheader) return true;
    if licm_hoist_sub_add_association(c, i, preheader) return true;
    return false;
}
