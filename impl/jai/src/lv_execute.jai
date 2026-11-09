// The end of LoopVectorizePass::processLoop for a chosen plan (interleave count, GeneratedRTChecks, the epilogue
// decision, addMinimumIterationCheck / attachRuntimeChecks) and LoopVectorizationPlanner::executePlan with the
// InnerLoopVectorizer skeleton (createVectorizedLoopSkeleton, fixVectorizedLoop / legacyCSE) and
// updateLoopMetadataAndProfileInfo.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp and VPlan.cpp (LLVM 23.1.5).

LV_FOLLOWUP_ALL :: "llvm.loop.vectorize.followup_all";
LV_FOLLOWUP_VECTORIZED :: "llvm.loop.vectorize.followup_vectorized";
LV_FOLLOWUP_EPILOGUE :: "llvm.loop.vectorize.followup_epilogue";

// GeneratedRTChecks (only the "no checks needed" and "too many checks" paths are ported)
Lv_Rt_Checks :: struct {
    scev_cond: Value_Id = NONE;
    scev_block: Value_Id = NONE;
    mem_cond: Value_Id = NONE;
    mem_block: Value_Id = NONE;
    cost_too_high: bool;
}
lv_rt_checks_has_checks :: (c: *Lv_Rt_Checks) -> bool { return c.scev_block != NONE || c.mem_block != NONE; }

// GeneratedRTChecks::create
lv_rt_checks_create :: (c: *Lv_Rt_Checks, lp: *Lv_Planner, vf: Ec, ic: u64) {
    laa := lp.lvl.laa;
    c.cost_too_high = laa.rt.checks.count > lv_opts.memory_check_threshold;
    if c.cost_too_high {
        c.mem_cond = const_int(ir.t_i1, 1);
        c.scev_cond = const_int(ir.t_i1, 1);
        return;
    }
    if lp.pse.preds.count vp_unported("SCEV runtime checks (GeneratedRTChecks, expandCodeForPredicate)");
    if laa.rt.need vp_unported("memory runtime checks (GeneratedRTChecks)");
}

// LoopVectorizationPlanner::selectInterleaveCount up to the point where the target's maximum interleave factor
// decides (the register-usage and loop-cost heuristics are not ported)
lvp_select_interleave_count :: (lp: *Lv_Planner, vf: Ec) -> u64 {
    cm := lp.cm;
    if cm.sel != .ALLOWED return 1;   // !isEpilogueAllowed() && !(preferTailFoldedLoop && useWideActiveLaneMask)
    header := vp_entry_basic_block(vp_vector_loop_region());
    for vp_block_phis(header) if vr(it).kind == .CURRENT_ITERATION_PHI return 1;
    if !lvl_is_safe_for_any_vector_width(lp.lvl) return 1;
    if vp_has_early_exit() return 1;
    has_rdx := false; has_ordered := false;
    for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI { has_rdx = true; if vr(it).rdx_style == .ORDERED has_ordered = true; }
    for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI && rk_is_find_last(vr(it).rdx_kind) return 1;
    max_ic := lv_tti_max_interleave_factor(cm.tti, vf, has_rdx && !has_ordered);
    if ec_is_scalar(vf) { if lv_opts.force_target_max_scalar_interleave.set max_ic = cast(u64) lv_opts.force_target_max_scalar_interleave.v; }
    else if lv_opts.force_target_max_vector_interleave.set max_ic = cast(u64) lv_opts.force_target_max_vector_interleave.v;
    // With a maximum of 1 every remaining path of the heuristic returns 1 (the loop cost only matters to decide
    // between larger counts).
    if max_ic <= 1 return 1;
    vp_unported("choosing the interleave count with the VPlan cost model (selectInterleaveCount)");
    return 1;
}

// LoopVectorizationPlanner::requiresScalarEpilogue (VPlan-based, before removeBranchOnConst)
lvp_requires_scalar_epilogue :: () -> bool { return vp_single_succ(vp_middle_block()) == vp_scalar_preheader(); }

// the rest of processLoop for a chosen plan
lvp_vectorize_with_plan :: (lp: *Lv_Planner, plan: *Vp_Plan, vf: Ec, user_ic: u64) -> bool {
    vp_use(plan);
    vp_print_plan("chosen");
    ic: u64 = 1;
    // selectInterleaveCount is only needed when the user did not force the count, or for the runtime checks
    needs_ic := user_ic == 0 || lp.pse.preds.count > 0 || lp.lvl.laa.rt.need;
    if needs_ic ic = lvp_select_interleave_count(lp, vf);
    selected_ic := max(ic, user_ic);
    checks: Lv_Rt_Checks;
    if ec_is_vector(vf) || selected_ic > 1 {
        lv_rt_checks_create(*checks, lp, vf, selected_ic);
        if checks.scev_cond != NONE && is_const(checks.scev_cond) && vkind(checks.scev_cond) == .C_INT && const_int_zext(checks.scev_cond) == 1 return false;
        if checks.mem_cond != NONE && is_const(checks.mem_cond) && vkind(checks.mem_cond) == .C_INT && const_int_zext(checks.mem_cond) == 1 return false;
    }
    // isOutsideLoopWorkProfitable: with a user VF the scalar cost is 0 and the answer is true (the runtime-check cost
    // is valid: no checks are generated in the ported subset)
    if ec_is_scalar(vf) vp_unported("interleaving without vectorization (VF 1)");
    ic = ifx user_ic > 0 then user_ic else ic;
    if lvl_has_uncountable_exit_with_side_effects(lp.lvl) && ic > 1 ic = 1;
    // selectBestEpiloguePlan
    if lvp_select_best_epilogue_plan(lp, vf, ic) vp_unported("epilogue vectorization");
    latch := li_loop_latch(lp.li, lp.l);
    has_bw := prof_has_branch_weight_md(block_terminator(latch));
    lvp_add_minimum_iteration_check(lp, vf, cast(u32) ic, ec_fixed(0), has_bw);
    lvp_attach_runtime_checks(lp, *checks, has_bw);
    lvp_execute_plan(lp, vf, cast(u32) ic, *checks);
    return true;
}

// selectBestEpiloguePlan: true when an epilogue plan would be chosen (not ported beyond the profitability gate)
lvp_select_best_epilogue_plan :: (lp: *Lv_Planner, vf: Ec, ic: u64) -> bool {
    if !lv_opts.enable_epilogue_vectorization return false;
    if lp.cm.sel != .ALLOWED return false;
    // CM.maskPartialAliasing is never set in the ported subset
    if li_exiting_block(lp.li, lp.l) != li_loop_latch(lp.li, lp.l) return false;
    for vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) {
        k := vr(it).kind;
        if k == .FIRST_ORDER_RECURRENCE_PHI || k == .REDUCTION_PHI vp_unported("hasUnsupportedHeaderPhiRecipe (epilogue vectorization)");
    }
    if lv_opts.epilogue_force_vf.set && lv_opts.epilogue_force_vf.v > 1 vp_unported("-epilogue-vectorization-force-VF");
    if fn_has_opt_size(lp.cm.f) return false;
    // isEpilogueVectorizationProfitable: TTI.preferEpilogueVectorization = getMaxInterleaveFactor(VF * IC) > 1
    iters := Ec.{vf.n * ic, vf.scalable};
    if lv_tti_max_interleave_factor(lp.cm.tti, iters, false) <= 1 return false;
    min_vf := ifx lv_opts.epilogue_min_vf.set then cast(u64) lv_opts.epilogue_min_vf.v else 16;
    if vf.n * ic < min_vf return false;
    return true;
}

// LoopVectorizationPlanner::addMinimumIterationCheck
lvp_add_minimum_iteration_check :: (lp: *Lv_Planner, vf: Ec, uf: u32, min_profitable: Ec, has_bw: bool) {
    w := u32.[1, 127];
    bw: [] u32;
    if has_bw bw = w;
    pred := li_loop_predecessor(lp.li, lp.l);
    vp_add_minimum_iteration_check(vf, uf, min_profitable, lvp_requires_scalar_epilogue(), vp_has_tail_folded(), lp.l, bw,
                                   inst_dl(block_terminator(pred)), lp.pse, vpl.entry);
}

// LoopVectorizationPlanner::attachRuntimeChecks
lvp_attach_runtime_checks :: (lp: *Lv_Planner, c: *Lv_Rt_Checks, has_bw: bool) {
    if c.scev_block != NONE && !block_has_predecessors(c.scev_block) vp_attach_check_block(c.scev_cond, c.scev_block, has_bw);
    if c.mem_block != NONE && !block_has_predecessors(c.mem_block) vp_attach_check_block(c.mem_cond, c.mem_block, has_bw);
}

// replaceVPBBWithIRVPBB
vp_replace_vpbb_with_irvpbb :: (vpbb: Vp_Blk, irbb: Value_Id) -> Vp_Blk {
    n := vp_create_ir_basic_block(irbb);
    ip := vb(n).first;
    for r: vp_block_phis(vpbb) vp_move_before(r, n, ip);
    rest: [..] Vp_Rec; rest.allocator = temp;
    r := vp_first_non_phi(vpbb);
    while r != NONE { array_add(*rest, r); r = vr(r).next; }
    for rest vp_move_before(it, n, NONE);
    vpbu_reassociate_blocks(vpbb, n);
    if vpl.scalar_header == vpbb vpl.scalar_header = n;
    vb(vpbb).dead = true;
    return n;
}

// Loop::addIntLoopAttribute
li_add_int_loop_attribute :: (li: *Loop_Info, l: Loop_Id, name: string, v: u32, remove_prefixes: [] string) {
    attr := md_tuple(.[md_string(name), md_value(const_int(ir.t_i32, v))], false);
    nid := make_post_transformation_metadata(li_loop_id(li, l), remove_prefixes, .[attr]);
    li_set_loop_id(li, l, nid);
}
// LoopVectorizeHints::setAlreadyVectorized
lvh_set_already_vectorized :: (li: *Loop_Info, l: Loop_Id) {
    li_add_int_loop_attribute(li, l, "llvm.loop.isvectorized", 1, .["llvm.loop.vectorize.", "llvm.loop.interleave."]);
}
// addRuntimeUnrollDisableMetaData
lv_add_runtime_unroll_disable_metadata :: (li: *Loop_Info, l: Loop_Id) {
    mds: [..] Md_Id; mds.allocator = temp;
    array_add(*mds, NONE);
    is_unroll := false;
    id := li_loop_id(li, l);
    if id != NONE {
        n := md_nops(id);
        if n > 1 for k: 1..n-1 {
            o := md_op(id, k);
            if o != NONE && md_is_node(o) {
                if md_nops(o) == 0 { array_add(*mds, o); continue; }
                s := md_op(o, 0);
                if s == NONE || ir.mds[s].kind != .STRING continue;
                if begins_with(ir.mds[s].str, "llvm.loop.unroll.runtime.disable") continue;
                is_unroll = begins_with(ir.mds[s].str, "llvm.loop.unroll.disable");
            }
            array_add(*mds, o);
        }
    }
    if is_unroll return;
    array_add(*mds, md_tuple(.[md_string("llvm.loop.unroll.runtime.disable")], false));
    li_set_loop_id(li, l, md_self_ref_loop_id(mds));
}

// LoopVectorizationPlanner::updateLoopMetadataAndProfileInfo
lvp_update_loop_metadata_and_profile_info :: (lp: *Lv_Planner, vector_loop: Loop_Id, header_vpbb: Vp_Blk, orig_loop_id: Md_Id,
                                              has_avg_tc: bool, orig_avg_tc: u32, estimated_vfxuf: u64, disable_runtime_unroll: bool) {
    li := lp.li; l := lp.l;
    sph := vp_scalar_preheader();
    if sph != NONE {
        has, rid := make_followup_loop_id(orig_loop_id, .[LV_FOLLOWUP_ALL, LV_FOLLOWUP_EPILOGUE]);
        if has li_set_loop_id(li, l, rid);
        else {
            if disable_runtime_unroll lv_add_runtime_unroll_disable_metadata(li, l);
            lvh_set_already_vectorized(li, l);
        }
    }
    if vector_loop == NONE return;
    has, vid := make_followup_loop_id(orig_loop_id, .[LV_FOLLOWUP_ALL, LV_FOLLOWUP_VECTORIZED]);
    if has li_set_loop_id(li, vector_loop, vid);
    else {
        if orig_loop_id != NONE li_set_loop_id(li, vector_loop, orig_loop_id);
        lvh_set_already_vectorized(li, vector_loop);
    }
    // TTI.getUnrollingPreferences: UnrollVectorizedLoop is false for X86 and NoTTI
    lv_add_runtime_unroll_disable_metadata(li, vector_loop);
    ok_ec, ec := fn_entry_count(lp.cm.f);
    is_profiled := ok_ec && ec != 0;
    if !has_avg_tc {
        if !is_profiled return;
        vp_unported("profile-based trip-count metadata of vectorized loops (updateLoopMetadataAndProfileInfo)");
    }
    vp_unported("estimated trip-count metadata of vectorized loops (setLoopEstimatedTripCount)");
}

// legacyCSE
lv_legacy_cse :: (bb: Value_Id) {
    can_handle :: (i: Value_Id) -> bool { o := inst_op(i); return o == .INSERTELEMENT || o == .EXTRACTELEMENT || o == .SHUFFLEVECTOR || o == .GEP; }
    seen: [..] Value_Id; seen.allocator = temp;
    insts: [..] Value_Id; insts.allocator = temp;
    for block_insts(bb) array_add(*insts, it);
    for i: insts {
        if !can_handle(i) continue;
        found: Value_Id = NONE;
        for s: seen if is_identical_to(s, i) { found = s; break; }
        if found != NONE { replace_all_uses_with(i, found); erase_inst(i); continue; }
        array_add(*seen, i);
    }
}

// LoopVectorizationPlanner::executePlan (EpilogueVecKind = None)
lvp_execute_plan :: (lp: *Lv_Planner, vf: Ec, uf: u32, checks: *Lv_Rt_Checks) {
    pse := lp.pse;
    vp_replace_wide_canonical_iv_with_wide_iv(vf, uf);
    vp_unroll_by_uf(uf);
    vp_materialize_packs_and_unpacks();
    vp_materialize_broadcasts();
    vp_replicate_by_vf(vf);
    latch := li_loop_latch(lp.li, lp.l);
    if prof_has_branch_weight_md(block_terminator(latch)) vp_unported("addBranchWeightToMiddleTerminator");
    vector_ph := vp_vector_preheader();
    vp_materialize_constant_vector_trip_count(vf, uf, pse);
    vp_optimize_for_vf_and_uf(vf, uf, pse);
    vp_simplify_recipes();
    requires_scalar_epilogue := lvp_requires_scalar_epilogue();
    vp_remove_branch_on_const(false);
    if vp_single_succ(vpl.entry) == vp_scalar_preheader() return;   // the vector loop never executes
    vp_remove_dead_recipes();
    vp_convert_to_concrete_recipes();
    has_tail_folded := vp_has_tail_folded();
    vp_dissolve_loop_regions();
    vp_expand_branch_on_two_conds();
    vp_remove_branch_on_const(true);
    vp_materialize_backedge_taken_count(vector_ph);
    has_mrs, mvs := ic_vscale_range_max(lp.cm.f);
    vp_materialize_vector_trip_count(vector_ph, has_tail_folded, requires_scalar_epilogue, vpl.vfxuf, has_mrs, mvs * vf.n * uf);
    vp_materialize_factors(vector_ph, vf);
    vp_expand_scevs_to_vp_instructions();
    vp_cse();
    vp_simplify_recipes();
    if vp_remove_branch_on_const(false) vp_simplify_recipes();
    entry_irbb := vb(vpl.entry).irbb;
    vp_expand_scevs(entry_irbb);

    st: Vp_State;
    st.vf = vf; st.uf = uf; st.li = lp.li; st.ac = lp.p.ac; st.f = lp.cm.f;
    st.vec.allocator = temp; st.scal.allocator = temp; st.vpbb2irbb.allocator = temp;
    st.dtu.dt = lp.p.dt; st.dtu.lazy = true;
    st.dtu.pending.allocator = temp; st.dtu.deleted.allocator = temp; st.dtu.deleted_set.allocator = temp;
    st.cur_parent_loop = li_parent(lp.li, lp.l);
    // createVectorizedLoopSkeleton: createScalarPreheader("")
    ph := li_loop_preheader(lp.li, lp.l);
    scalar_ph_bb := split_block(ph, block_terminator(ph), lp.p.dt, lp.li, null, "scalar.ph");
    st.prev_bb = block_single_predecessor(scalar_ph_bb);
    sph := vp_scalar_preheader();
    if sph != NONE vp_replace_vpbb_with_irvpbb(sph, block_get_single_successor(st.prev_bb));
    vp_remove_dead_recipes();
    for eb: vpl.exit_blocks {
        if vb(eb).preds.count == 0 continue;
        for r: vp_block_phis(eb) sc_forget_lcssa_phi_with_new_predecessor(lp.l, vr(r).ir_inst);
    }
    sc_forget_loop(lp.l);
    sc_forget_block_and_loop_dispositions();
    lid := li_loop_id(lp.li, lp.l);
    has_avg, avg := li_loop_estimated_trip_count(lp.li, lp.l);
    vp_execute_plan(*st);
    header_vpbb: Vp_Blk = NONE;
    for b: vp_depth_first_shallow(vpl.entry) if vpbu_is_header(b, *st.vpdt) { header_vpbb = b; break; }
    disable_runtime_unroll := !lv_rt_checks_has_checks(checks) && !ec_is_scalar(vf);
    vloop: Loop_Id = NONE;
    if header_vpbb != NONE { _, hbb := table_find(*st.vpbb2irbb, header_vpbb); vloop = li_loop_for(lp.li, hbb); }
    lvp_update_loop_metadata_and_profile_info(lp, vloop, header_vpbb, lid, has_avg, avg, vf.n * uf, disable_runtime_unroll);
    // fixVectorizedLoop
    if header_vpbb != NONE {
        _, hbb := table_find(*st.vpbb2irbb, header_vpbb);
        lv_legacy_cse(hbb);
    }
}
