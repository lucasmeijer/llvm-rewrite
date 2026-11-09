// The end of LoopVectorizePass::processLoop for a chosen plan (interleave count, GeneratedRTChecks, the epilogue
// decision, addMinimumIterationCheck / attachRuntimeChecks) and LoopVectorizationPlanner::executePlan with the
// InnerLoopVectorizer skeleton (createVectorizedLoopSkeleton, fixVectorizedLoop / legacyCSE) and
// updateLoopMetadataAndProfileInfo.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp and VPlan.cpp (LLVM 23.1.5).

LV_FOLLOWUP_ALL :: "llvm.loop.vectorize.followup_all";
LV_FOLLOWUP_VECTORIZED :: "llvm.loop.vectorize.followup_vectorized";
LV_FOLLOWUP_EPILOGUE :: "llvm.loop.vectorize.followup_epilogue";

// GeneratedRTChecks
Lv_Rt_Checks :: struct {
    scev_cond: Value_Id = NONE;
    scev_block: Value_Id = NONE;
    mem_cond: Value_Id = NONE;
    mem_block: Value_Id = NONE;
    cost_too_high: bool;
    scev_exp: Scev_Expander;
    mem_exp: Scev_Expander;
    created: bool;
    outer_loop: Loop_Id = NONE;
}
lv_rt_checks_has_checks :: (c: *Lv_Rt_Checks) -> bool { return c.scev_block != NONE || c.mem_block != NONE; }

// GeneratedRTChecks::create
lv_rt_checks_create :: (c: *Lv_Rt_Checks, lp: *Lv_Planner, vf: Ec, ic: u64) {
    laa := lp.lvl.laa;
    li := lp.li; dt := lp.p.dt; l := lp.l;
    sx_init(*c.scev_exp, "scev.check", false);
    sx_init(*c.mem_exp, "scev.check", false);
    c.created = true;
    c.cost_too_high = laa.rt.checks.count > lv_opts.memory_check_threshold;
    if c.cost_too_high {
        c.mem_cond = const_int(ir.t_i1, 1);
        c.scev_cond = const_int(ir.t_i1, 1);
        return;
    }
    header := li_header(li, l);
    ph := li_loop_preheader(li, l);
    if lp.pse.preds.count {
        c.scev_block = split_block(ph, block_terminator(ph), dt, li, null, "vector.scevcheck");
        c.scev_cond = sx_expand_union_predicate(*c.scev_exp, lp.pse.preds, block_terminator(c.scev_block));
        if is_const(c.scev_cond) sx_cleanup(*c.scev_exp);
    }
    rt := *laa.rt;
    if rt.need {
        pred := ifx c.scev_block != NONE then c.scev_block else ph;
        c.mem_block = split_block(pred, block_terminator(pred), dt, li, null, "vector.memcheck");
        if rt.can_use_diff_check && rt.diff_checks.count {
            c.mem_cond = lv_add_diff_runtime_checks(block_terminator(c.mem_block), rt.diff_checks, *c.mem_exp, vf, ic);
        } else {
            idx: [..] s64; idx.allocator = temp;
            for 0..rt.checks.count-1 array_add(*idx, it);
            c.mem_cond = lver_add_runtime_checks(block_terminator(c.mem_block), l, li, rt, idx, *c.mem_exp, laa_opts.hoist_runtime_checks);
        }
        assert(c.mem_cond != NONE, "no RT checks generated although RtPtrChecking claimed checks are required");
    }
    sx_erase_dead_instructions(*c.scev_exp, c.scev_cond);
    if c.mem_block == NONE && c.scev_block == NONE return;
    if c.scev_block != NONE block_rauw(c.scev_block, ph);
    if c.mem_block != NONE block_rauw(c.mem_block, ph);
    unhook :: (blk: Value_Id, ph: Value_Id) {
        t := block_terminator(blk);
        pt := block_terminator(ph);
        inst_unlink(t);
        inst_insert_before(t, pt);
        u := new_inst(.UNREACHABLE, ir.t_void, 0);
        block_append_inst(blk, u);
        erase_inst(pt);
    }
    if c.scev_block != NONE unhook(c.scev_block, ph);
    if c.mem_block != NONE unhook(c.mem_block, ph);
    dt_change_idom(dt, header, ph);
    if c.mem_block != NONE { dt_erase_node(dt, c.mem_block); li_remove_block(li, c.mem_block); }
    if c.scev_block != NONE { dt_erase_node(dt, c.scev_block); li_remove_block(li, c.scev_block); }
    c.outer_loop = li_parent(li, l);
}

// GeneratedRTChecks::getCost
lv_rt_checks_get_cost :: (c: *Lv_Rt_Checks, lp: *Lv_Planner) -> Cost {
    if c.cost_too_high return COST_INVALID;
    kind := ifx fn_has_min_size(lp.cm.f) then TCK_CODE_SIZE else TCK_RECIP_THROUGHPUT;
    t := lp.cm.tti;
    total: Cost = 0;
    if c.scev_block != NONE {
        term := block_terminator(c.scev_block);
        for i: block_insts(c.scev_block) if i != term total = cost_add(total, tti_instruction_cost(t, i, kind));
    }
    if c.mem_block != NONE {
        mc: Cost = 0;
        term := block_terminator(c.mem_block);
        for i: block_insts(c.mem_block) if i != term mc = cost_add(mc, tti_instruction_cost(t, i, kind));
        if c.outer_loop != NONE {
            cond := sc_get_scev(c.mem_cond);
            if sc_is_loop_invariant(cond, c.outer_loop) {
                best: u64 = 2;
                ok, est := lv_small_best_known_tc(lp.cm, c.outer_loop, false);
                if ok && !est.scalable best = est.n;
                if cost_valid(mc) mc = max(mc / cast(s64) best, 1);
            }
        }
        total = cost_add(total, mc);
    }
    return total;
}

// isOutsideLoopWorkProfitable (the paths that do not need the VPlan cost of the vector loop)
lv_is_outside_loop_work_profitable :: (c: *Lv_Rt_Checks, lp: *Lv_Planner, vf: Ec, scalar_cost: Cost) -> bool {
    rtc := lv_rt_checks_get_cost(c, lp);
    if !cost_valid(rtc) return false;
    if ec_is_scalar(vf) return rtc <= lv_opts.memory_check_threshold;
    if scalar_cost == 0 return true;
    vp_unported("isOutsideLoopWorkProfitable with the VPlan cost model (minimum profitable trip count)");
    return false;
}

// ~GeneratedRTChecks: remove the check blocks and instructions when they ended up unused
lv_rt_checks_destroy :: (c: *Lv_Rt_Checks) {
    if !c.created return;
    scev_used := c.scev_block == NONE || block_has_predecessors(c.scev_block);
    mem_used := c.mem_block == NONE || block_has_predecessors(c.mem_block);
    if !mem_used {
        insts: [..] Value_Id; insts.allocator = temp;
        for block_insts(c.mem_block) array_add(*insts, it);
        for < i: insts {
            if sx_is_inserted_instruction(*c.mem_exp, i) continue;
            sc_forget_value(i);
            erase_inst(i);
        }
    }
    if !mem_used sx_cleanup(*c.mem_exp);
    if !scev_used sx_cleanup(*c.scev_exp);
    if !scev_used block_erase_from_parent(c.scev_block);
    if !mem_used block_erase_from_parent(c.mem_block);
}

// SCEVPtrToAddrRewriter::visitPtrToIntExpr
sc_rw_ptr_to_addr_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if sc_kind(s) != .PTRTOINT return false, s;
    o := sc_rewrite(rw, sc_op(s, 0));
    if sc_type(s) == dl_int_ptr_type(sc_type(sc_op(s, 0))) return true, sc_get_ptr_to_addr(o);
    if o == sc_op(s, 0) return true, s;
    return true, sc_get_ptr_to_int(o, sc_type(s));
}
// SCEVPtrToAddrRewriter + addDiffRuntimeChecks (LoopUtils.cpp)
lv_add_diff_runtime_checks :: (loc: Value_Id, checks: [] Rt_Diff_Check, x: *Scev_Expander, vf: Ec, ic: u64) -> Value_Id {
    if vf.scalable vp_unported("diff runtime checks for scalable VFs");
    b: Irb;
    irb_set_before(*b, loc);
    mem_check: Value_Id = NONE;
    Seen :: struct { diff: Value_Id; thr: Value_Id; cmp: Value_Id; }
    seen: [..] Seen; seen.allocator = temp;
    Thr :: struct { ty: Type_Id; n: u64; v: Value_Id; }
    thr_cache: [..] Thr; thr_cache.allocator = temp;
    rw: Sc_Rewriter;
    sc_rewriter_init(*rw, .PTR_TO_ADDR);
    for chk: checks {
        ty := sc_type(chk.sink_start);
        n := ic * chk.access_size;
        one := const_int(ty, 1);
        thr: Value_Id = NONE;
        for thr_cache if it.ty == ty && it.n == n { thr = it.v; break; }
        if thr == NONE {
            m := isf_binop(*b, .MUL, const_int(ty, vf.n), const_int(ty, n));
            thr = isf_binop(*b, .SUB, m, one);
            array_add(*thr_cache, .{ty, n, thr});
        }
        sink := sc_rewrite(*rw, chk.sink_start);
        src := sc_rewrite(*rw, chk.src_start);
        diff := sx_expand_code_for_at(x, sc_get_minus(sink, src), ty, loc);
        dup := false;
        for seen if it.diff == diff && it.thr == thr { dup = true; break; }
        if dup continue;
        conflict := isf_icmp(*b, ICMP_ULT, isf_binop(*b, .SUB, diff, one), thr, "diff.check");
        array_add(*seen, .{diff, thr, conflict});
        if chk.needs_freeze conflict = irb_freeze(*b, conflict, tprint("%.fr", ir.v_name[conflict]));
        if mem_check != NONE conflict = isf_binop(*b, .OR, mem_check, conflict, "conflict.rdx");
        mem_check = conflict;
    }
    sx_erase_dead_instructions(x, mem_check);
    return mem_check;
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
        if checks.scev_cond != NONE && vkind(checks.scev_cond) == .C_INT && const_int_zext(checks.scev_cond) == 1 { lv_rt_checks_destroy(*checks); return false; }
        if checks.mem_cond != NONE && vkind(checks.mem_cond) == .C_INT && const_int_zext(checks.mem_cond) == 1 { lv_rt_checks_destroy(*checks); return false; }
    }
    force := lvh_force(lp.hints) == FK_ENABLED;
    // the plan was chosen for the user VF (or is the only, scalar, plan): computeBestVF's scalar cost is 0
    if !force && !lv_is_outside_loop_work_profitable(*checks, lp, vf, 0) { lv_rt_checks_destroy(*checks); return false; }
    ic = ifx user_ic > 0 then user_ic else ic;
    if lvl_has_uncountable_exit_with_side_effects(lp.lvl) && ic > 1 ic = 1;
    // selectBestEpiloguePlan
    if lvp_select_best_epilogue_plan(lp, vf, ic) vp_unported("epilogue vectorization");
    latch := li_loop_latch(lp.li, lp.l);
    has_bw := prof_has_branch_weight_md(block_terminator(latch));
    lvp_add_minimum_iteration_check(lp, vf, cast(u32) ic, ec_fixed(0), has_bw);
    lvp_attach_runtime_checks(lp, *checks, has_bw);
    lvp_execute_plan(lp, vf, cast(u32) ic, *checks);
    lv_rt_checks_destroy(*checks);
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
