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
// getSCEVChecks / getMemRuntimeChecks: a check folded to false is no check
lv_is_zero_int :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_INT && const_int_zext(v) == 0; }
lv_rt_scev_checks :: (c: *Lv_Rt_Checks) -> (Value_Id, Value_Id) {
    if c.scev_cond == NONE || lv_is_zero_int(c.scev_cond) return NONE, NONE;
    return c.scev_cond, c.scev_block;
}
lv_rt_mem_checks :: (c: *Lv_Rt_Checks) -> (Value_Id, Value_Id) {
    if lv_is_zero_int(c.mem_cond) return NONE, NONE;
    return c.mem_cond, c.mem_block;
}
lv_rt_checks_has_checks :: (c: *Lv_Rt_Checks) -> bool {
    a := lv_rt_scev_checks(c); b := lv_rt_mem_checks(c);
    return a != NONE || b != NONE;
}

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
    if !sc_union_is_always_true(lp.pse.preds) {
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
lv_rt_checks_get_cost :: (c: *Lv_Rt_Checks, lp: *Lv_Planner) -> Lc {
    if c.cost_too_high return COST_INVALID;
    kind := ifx fn_has_min_size(lp.cm.f) then TCK_CODE_SIZE else TCK_RECIP_THROUGHPUT;
    t := lp.cm.tti;
    total: Cost = 0;
    if c.scev_block != NONE {
        term := block_terminator(c.scev_block);
        for i: block_insts(c.scev_block) if i != term total = lc_add(total, lt_instruction_cost(t, i, kind));
    }
    if c.mem_block != NONE {
        mc: Cost = 0;
        term := block_terminator(c.mem_block);
        for i: block_insts(c.mem_block) if i != term mc = lc_add(mc, lt_instruction_cost(t, i, kind));
        if c.outer_loop != NONE {
            cond := sc_get_scev(c.mem_cond);
            if sc_is_loop_invariant(cond, c.outer_loop) {
                best: u64 = 2;
                ok, est := lv_small_best_known_tc(lp.cm, c.outer_loop, false);
                if ok && !est.scalable best = est.n;
                if cost_valid(mc) mc = lcv(max(lc_value(lc_div(mc, best)), 1));
            }
        }
        total = lc_add(total, mc);
    }
    return total;
}

// isOutsideLoopWorkProfitable
lv_is_outside_loop_work_profitable :: (c: *Lv_Rt_Checks, lp: *Lv_Planner, vf: *Lv_Vf, plan: *Vp_Plan) -> bool {
    rtc := lv_rt_checks_get_cost(c, lp);
    if !cost_valid(rtc) return false;
    if ec_is_scalar(vf.width) return rtc <= lcv(lv_opts.memory_check_threshold);
    scalar_c := lc_value(vf.scalar_cost);
    if scalar_c == 0 return true;
    vp_use(plan);
    ctx: Vp_Cost_Ctx;
    vpc_init(*ctx, lp);
    total := rtc;
    for ex: vpl.exit_blocks for p: vb(ex).preds if p != vp_middle_block() total = lc_add(total, vp_basic_block_cost(*ctx, p, vf.width));
    total = lc_add(total, vp_basic_block_cost(*ctx, vp_middle_block(), vf.width));
    int_vf := cast(u64) vf.width.n;
    // uint64_t arithmetic, like LLVM's
    div := cast(u64) scalar_c * int_vf - cast(u64) lc_value(vf.cost);
    min_tc1: u64 = ifx div == 0 then 0 else (cast(u64) lc_value(total) * int_vf + div - 1) / div;
    min_tc2 := (cast(u64) lc_value(rtc) * 10 + cast(u64) scalar_c - 1) / cast(u64) scalar_c;
    min_tc := max(min_tc1, min_tc2);
    if lp.cm.sel == .ALLOWED min_tc = (min_tc + int_vf - 1) / int_vf * int_vf;
    vf.min_profitable_tc = ec_fixed(min_tc);
    lv_dbg("LV: Minimum required TC for runtime checks to be profitable:%\n", min_tc);
    known, etc := lv_small_best_known_tc(lp.cm, lp.l);
    if known && ec_known_lt(etc, vf.min_profitable_tc) return false;
    return true;
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

// LoopVectorizationPlanner::requiresScalarEpilogue (VPlan-based, before removeBranchOnConst)
lvp_requires_scalar_epilogue :: () -> bool { return vp_single_succ(vp_middle_block()) == vp_scalar_preheader(); }

// the rest of processLoop after computeBestVF
lvp_process_best_plan :: (lp: *Lv_Planner, vf_in: Lv_Vf, plan: *Vp_Plan, user_ic: u64) -> bool {
    vf := vf_in;
    ic: u64 = 1;
    checks: Lv_Rt_Checks;
    if plan {
        vp_use(plan);
        vp_print_plan("chosen");
        ic = lvp_select_interleave_count(lp, plan, vf.width, vf.cost);
        vp_use(plan);
        selected_ic := max(ic, user_ic);
        if ec_is_vector(vf.width) || selected_ic > 1 {
            lv_rt_checks_create(*checks, lp, vf.width, selected_ic);
            sc := lv_rt_scev_checks(*checks);
            mc := lv_rt_mem_checks(*checks);
            if sc != NONE && vkind(sc) == .C_INT && const_int_zext(sc) == 1 { lv_rt_checks_destroy(*checks); return false; }
            if mc != NONE && vkind(mc) == .C_INT && const_int_zext(mc) == 1 { lv_rt_checks_destroy(*checks); return false; }
        }
        force := lvh_force(lp.hints) == FK_ENABLED;
        if !force && !lv_is_outside_loop_work_profitable(*checks, lp, *vf, plan) { lv_rt_checks_destroy(*checks); return false; }
        vp_use(plan);
    }
    vectorize_loop := !ec_is_scalar(vf.width);
    interleave_loop := true;
    if user_ic == 1 && lvh_interleave(lp.hints) > 1 interleave_loop = false;
    else if !plan && user_ic > 1 interleave_loop = false;
    else if ic == 1 && user_ic <= 1 interleave_loop = false;
    else if ic > 1 && user_ic == 1 interleave_loop = false;
    // histograms are not supported (legality)
    ic = ifx user_ic > 0 then user_ic else ic;
    if interleave_loop && lvl_has_uncountable_exit_with_side_effects(lp.lvl) { interleave_loop = false; ic = 1; }
    if !vectorize_loop && !interleave_loop { lv_rt_checks_destroy(*checks); return false; }
    lv_dbg("LV: Vectorizing with VF % and IC %\n", lv_ec_str(vf.width), ic);
    epi_plan := lvp_select_best_epilogue_plan(lp, plan, vf.width, ic);
    latch := li_loop_latch(lp.li, lp.l);
    has_bw := prof_has_branch_weight_md(block_terminator(latch));
    if epi_plan {
        lvp_vectorize_with_epilogue(lp, plan, epi_plan, vf, ic, *checks, has_bw);
    } else {
        vp_use(plan);
        lvp_add_minimum_iteration_check(lp, vf.width, cast(u32) ic, vf.min_profitable_tc, has_bw);
        lvp_attach_runtime_checks(lp, *checks, has_bw);
        lvp_execute_plan(lp, vf.width, cast(u32) ic, *checks);
    }
    lv_rt_checks_destroy(*checks);
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
    scond, sblock := lv_rt_scev_checks(c);
    if sblock != NONE && !block_has_predecessors(sblock) vp_attach_check_block(scond, sblock, has_bw);
    mcond, mblock := lv_rt_mem_checks(c);
    if mblock != NONE && !block_has_predecessors(mblock) vp_attach_check_block(mcond, mblock, has_bw);
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
lvp_update_loop_metadata_and_profile_info :: (lp: *Lv_Planner, vector_loop: Loop_Id, header_vpbb: Vp_Blk, vectorizing_epilogue: bool,
                                              orig_loop_id: Md_Id, has_avg_tc: bool, orig_avg_tc: u32, inv_weight_in: u32, estimated_vfxuf: u64,
                                              disable_runtime_unroll: bool) {
    li := lp.li; l := lp.l;
    sph := vp_scalar_preheader();
    if sph != NONE && !vectorizing_epilogue {
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
        if !vectorizing_epilogue lvh_set_already_vectorized(li, vector_loop);
    }
    // TTI.getUnrollingPreferences: UnrollVectorizedLoop is false for X86 and NoTTI
    lv_add_runtime_unroll_disable_metadata(li, vector_loop);
    ok_ec, ec := fn_entry_count(lp.cm.f);
    is_profiled := ok_ec && ec != 0;
    inv_weight := inv_weight_in;
    avg_vec_tc: u32; rem_tc: u32;
    if !has_avg_tc {
        if !is_profiled return;
        avg_vec_tc = sc_get_small_constant_trip_count(vector_loop);
        if avg_vec_tc == 0 return;
        if sph != NONE rem_tc = cast(u32) (sc_get_small_constant_trip_count(l) % estimated_vfxuf);
        inv_weight = 1;
    } else {
        avg_vec_tc = cast(u32) (orig_avg_tc / estimated_vfxuf);
        rem_tc = cast(u32) (orig_avg_tc % estimated_vfxuf);
    }
    if header_vpbb != NONE li_set_loop_estimated_trip_count_with_weight(li, vector_loop, avg_vec_tc, inv_weight);
    if sph != NONE li_set_loop_estimated_trip_count_with_weight(li, l, rem_tc, inv_weight);
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

// LoopVectorizationPlanner::executePlan (on the current plan); returns the SCEVs expanded by expandSCEVs
lvp_execute_plan :: (lp: *Lv_Planner, vf: Ec, uf: u32, checks: *Lv_Rt_Checks, kind := Lv_Epilogue_Kind.NONE) -> Table(Scev_Id, Value_Id) {
    expanded: Table(Scev_Id, Value_Id); expanded.allocator = temp;
    pse := lp.pse;
    vp_replace_wide_canonical_iv_with_wide_iv(vf, uf, lp.cm.tti, lp.cm.cost_kind, *lp.cm.values_to_ignore);
    vp_unroll_by_uf(uf);
    vp_materialize_packs_and_unpacks();
    vp_materialize_broadcasts();
    vp_replicate_by_vf(vf);
    latch := li_loop_latch(lp.li, lp.l);
    if prof_has_branch_weight_md(block_terminator(latch)) {
        // addBranchWeightToMiddleTerminator
        mt := vp_terminator(vp_middle_block());
        if mt != NONE && vr(mt).kind == .INSTRUCTION {
            step := vpl.ufs[0] * cast(u32) vf.n;
            vp_set_md(mt, md_kind_id(MD_PROF_NAME), md_branch_weights(.[1, step - 1], false));
        }
    }
    vector_ph := vp_vector_preheader();
    vp_materialize_constant_vector_trip_count(vf, uf, pse);
    vp_optimize_for_vf_and_uf(vf, uf, pse);
    vp_simplify_recipes();
    requires_scalar_epilogue := lvp_requires_scalar_epilogue();
    if kind == .NONE vp_remove_branch_on_const(false);
    if vp_single_succ(vpl.entry) == vp_scalar_preheader() return expanded;   // the vector loop never executes
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
    vp_print_plan("after materializeFactors");
    if kind == .NONE vp_expand_scevs_to_vp_instructions();
    vp_print_plan("after expandSCEVsToVPInstructions");
    vp_cse();
    vp_simplify_recipes();
    vp_print_plan("after cse+simplify");
    if vp_remove_branch_on_const(kind != .NONE) vp_simplify_recipes();
    entry_irbb := vb(vpl.entry).irbb;
    vp_expand_scevs(entry_irbb, *expanded);

    st: Vp_State;
    st.vf = vf; st.uf = uf; st.li = lp.li; st.ac = lp.p.ac; st.f = lp.cm.f;
    st.vec.allocator = temp; st.scal.allocator = temp; st.vpbb2irbb.allocator = temp;
    st.dtu.dt = lp.p.dt; st.dtu.lazy = true;
    st.dtu.pending.allocator = temp; st.dtu.deleted.allocator = temp; st.dtu.deleted_set.allocator = temp;
    st.cur_parent_loop = li_parent(lp.li, lp.l);
    // createVectorizedLoopSkeleton: createScalarPreheader("")
    ph := li_loop_preheader(lp.li, lp.l);
    scalar_ph_bb := split_block(ph, block_terminator(ph), lp.p.dt, lp.li, null, ifx kind == .EPILOGUE then "vec.epilog.scalar.ph" else "scalar.ph");
    st.prev_bb = block_single_predecessor(scalar_ph_bb);
    if kind == .EPILOGUE {
        // EpilogueVectorizerEpilogueLoop::createVectorizedLoopSkeleton
        set_name(st.prev_bb, "vec.epilog.iter.check");
        new_entry := vp_create_ir_basic_block(st.prev_bb);
        old_entry := vpl.entry;
        r := vb(old_entry).first;
        while r != NONE {
            nx := vr(r).next;
            if vr(r).kind != .IR_INSTRUCTION vp_move_before(r, new_entry, NONE);
            r = nx;
        }
        vpbu_reassociate_blocks(old_entry, new_entry);
        vpl.entry = new_entry;
    }
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
    has_avg, avg, inv_weight := li_loop_estimated_trip_count_with_weight(lp.li, lp.l);
    vp_execute_plan(*st);
    header_vpbb: Vp_Blk = NONE;
    for b: vp_depth_first_shallow(vpl.entry) if vpbu_is_header(b, *st.vpdt) { header_vpbb = b; break; }
    disable_runtime_unroll := !lv_rt_checks_has_checks(checks) && !ec_is_scalar(vf);
    vloop: Loop_Id = NONE;
    if header_vpbb != NONE { _, hbb := table_find(*st.vpbb2irbb, header_vpbb); vloop = li_loop_for(lp.li, hbb); }
    lvp_update_loop_metadata_and_profile_info(lp, vloop, header_vpbb, kind == .EPILOGUE, lid, has_avg, avg, inv_weight, vf.n * uf, disable_runtime_unroll);
    // fixVectorizedLoop
    if header_vpbb != NONE {
        _, hbb := table_find(*st.vpbb2irbb, header_vpbb);
        lv_legacy_cse(hbb);
    }
    return expanded;
}
