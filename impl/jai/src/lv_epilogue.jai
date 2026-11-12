// Epilogue vectorization: LoopVectorizationPlanner::selectBestEpiloguePlan (with hasUnsupportedHeaderPhiRecipe,
// isCandidateForEpilogueVectorization, isEpilogueVectorizationProfitable), preparePlanForMainVectorLoop,
// preparePlanForEpilogueVectorLoop, EpilogueVectorizerEpilogueLoop::createVectorizedLoopSkeleton,
// connectEpilogueVectorLoop / fixScalarResumeValuesFromBypass and the epilogue branch of processLoop.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp and VPlanConstruction.cpp
// (addIterationCountCheckBlock, addMinimumVectorEpilogueIterationCheck) (LLVM 23.1.5).

Lv_Epilogue_Kind :: enum u8 { NONE; MAIN_LOOP; EPILOGUE; }

// EpilogueLoopVectorizationInfo
Lv_Epi_Info :: struct {
    main_vf: Ec;
    main_uf: u32;
    epi_vf: Ec;
    epi_uf: u32 = 1;
    main_loop_iteration_count_check: Value_Id = NONE;
    epilogue_iteration_count_check: Value_Id = NONE;
    vector_trip_count: Value_Id = NONE;
}

// hasUnsupportedHeaderPhiRecipe (on the current plan)
lv_has_unsupported_header_phi_recipe :: () -> bool {
    for r: vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) {
        k := vr(r).kind;
        if k == .FIRST_ORDER_RECURRENCE_PHI return true;
        if k == .WIDEN_INT_OR_FP_INDUCTION { if vp_uv(vr(r).def) == NONE return true; continue; }
        if k == .REDUCTION_PHI {
            rk := vr(r).rdx_kind;
            if rk_is_fp_min_max_num(rk) || rk_is_find_last(rk) || vp_uv(vr(r).def) == NONE return true;
            if rk_is_find_iv(rk) {
                res := vp_find_compute_reduction_result(r);
                assert(res != NONE, "FindIV reduction must have ComputeReductionResult");
                for u: vv(vr(res).def).users if vr(u).kind != .INSTRUCTION return true;
            }
        }
    }
    return false;
}

// vputils::findComputeReductionResult
vp_find_compute_reduction_result :: (phir: Vp_Rec) -> Vp_Rec {
    be := vp_op(phir, 1);
    for u: vv(be).users if vp_is_vpi(u, VPI_COMPUTE_REDUCTION_RESULT) return u;
    sel: Vp_Rec = NONE;
    for u: vv(be).users {
        d := vr(u).def;
        if d == NONE continue;
        ok := vpm_select(d);
        if ok { sel = u; break; }
    }
    if sel == NONE return NONE;
    for u: vv(vr(sel).def).users if vp_is_vpi(u, VPI_COMPUTE_REDUCTION_RESULT) return u;
    return NONE;
}

// matchFindIVResult: select(icmp ne (ComputeReductionResult X), _), (ComputeReductionResult X), Start)
vp_match_find_iv_result :: (r: Vp_Rec) -> (bool, Vp_Val, Vp_Val) {
    ok, c, t, f := vpm_select(vr(r).def);
    if !ok return false, NONE, NONE;
    cr := vp_def(c);
    if !vp_is_vpi(cr, vp_opc(.ICMP)) || vp_nops(cr) != 2 || vr(cr).flags.pred != ICMP_NE return false, NONE, NONE;
    a := vp_def(vp_op(cr, 0)); tb := vp_def(t);
    if !vp_is_vpi(a, VPI_COMPUTE_REDUCTION_RESULT) || !vp_is_vpi(tb, VPI_COMPUTE_REDUCTION_RESULT) || vp_nops(a) != 1 || vp_nops(tb) != 1 return false, NONE, NONE;
    return true, vp_op(a, 0), f;
}

// vputils::findRecipe: breadth-first over the users of `start`
vp_find_recipe :: (start: Vp_Val, pred: (r: Vp_Rec) -> bool) -> Vp_Rec {
    wl: [..] Vp_Val; wl.allocator = temp;
    array_add(*wl, start);
    i := 0;
    while i < wl.count {
        cur := wl[i];
        i += 1;
        r := vp_def(cur);
        if r == NONE continue;
        if pred(r) return r;
        for u: vv(cur).users {
            if vr(u).def != NONE array_add_if_unique(*wl, vr(u).def);
            for d: vr(u).defs array_add_if_unique(*wl, d);
        }
    }
    return NONE;
}

lvp_get_plan_for :: (lp: *Lv_Planner, vf: Ec) -> *Vp_Plan {
    saved := vpl;
    defer vpl = saved;
    for lp.vplans { vp_use(it); if vp_has_vf(vf) return it; }
    fatal("internal: no VPlan for the VF");
    return null;
}

// LoopVectorizationPlanner::selectBestEpiloguePlan: a copy of the chosen epilogue plan, or null
lvp_select_best_epilogue_plan :: (lp: *Lv_Planner, main_plan: *Vp_Plan, main_vf_in: Ec, ic: u64) -> *Vp_Plan {
    saved := vpl;
    defer vpl = saved;
    if !lv_opts.enable_epilogue_vectorization return null;
    if lp.cm.sel != .ALLOWED return null;
    // CM.maskPartialAliasing is never set in the ported subset
    // isCandidateForEpilogueVectorization
    vp_use(main_plan);
    if lv_has_unsupported_header_phi_recipe() return null;
    if li_exiting_block(lp.li, lp.l) != li_loop_latch(lp.li, lp.l) return null;
    if lv_opts.epilogue_force_vf.set && lv_opts.epilogue_force_vf.v > 1 {
        fvf := ec_fixed(cast(u64) lv_opts.epilogue_force_vf.v);
        if fvf.n >= ic * main_vf_in.n {
            lv_dbg("LEV: Forced epilogue VF results in dead epilogue vector loop, skipping vectorizing epilogue.\n");
            return null;
        }
        if lvp_has_plan_with_vf(lp, fvf) {
            clone := vp_duplicate(lvp_get_plan_for(lp, fvf));
            vp_set_vf(fvf);
            return clone;
        }
        return null;
    }
    if fn_has_opt_size(lp.cm.f) return null;
    // isEpilogueVectorizationProfitable: TTI.preferEpilogueVectorization = getMaxInterleaveFactor(VF * IC) > 1
    iters := Ec.{main_vf_in.n * ic, main_vf_in.scalable};
    if lv_tti_max_interleave_factor(lp.cm.tti, iters, false) <= 1 return null;
    min_vf := ifx lv_opts.epilogue_min_vf.set then cast(u64) lv_opts.epilogue_min_vf.v else 16;
    if main_vf_in.n * ic < min_vf return null;

    // GetEffectiveVF: 1 for plans whose interleave groups were narrowed (the canonical IV steps by UF)
    get_effective_vf :: (plan: *Vp_Plan, vf: Ec) -> Ec {
        saved := vpl;
        defer vpl = saved;
        vp_use(plan);
        ok, inc, _ := vpm_branch_on_count(vp_terminator(vp_exiting_basic_block(vp_vector_loop_region())));
        if ok {
            oka, a, b := vpm_binary(inc, vp_opc(.ADD));
            if oka && a == vb(vp_vector_loop_region()).can_iv && b == vpl.uf return Ec.{1, vf.scalable};
        }
        return vf;
    }
    main_vf := get_effective_vf(main_plan, main_vf_in);
    if main_vf.scalable vp_unported("epilogue vectorization of scalable main loops");
    tc_ty := lp.lvl.widest_ind_ty;
    vp_use(main_plan);
    tc := vp_scev_for_value(vpl.trip_count, lp.pse);
    assert(!sc_is_cnc(tc), "Trip count SCEV must be computable");
    rem := sc_get_urem(tc, sc_get_element_count(tc_ty, main_vf.n * ic, false));
    if sc_is_zero(rem) return null;
    max_tc := cast(u32) (main_vf.n * ic - 1);
    if sc_is_known_predicate(ICMP_ULT, rem, sc_get_constant_t(tc_ty, max_tc))
        max_tc = cast(u32) ap_zext_value(sc_unsigned_range_max(rem));
    lv_dbg("LEV: Maximum Trip Count for Epilogue: %\n", max_tc);
    has_tail := !vp_has_tail_folded();

    result := Lv_Vf.{ec_fixed(1), 0, 0, ec_fixed(0)};
    best: *Vp_Plan = null;
    for next: lp.profitable_vfs {
        if !lvp_has_plan_with_vf(lp, next.width) continue;
        cur := lvp_get_plan_for(lp, next.width);
        evf := get_effective_vf(cur, next.width);
        if evf.scalable vp_unported("scalable epilogue VFs");
        if ec_known_gt(evf, main_vf) continue;
        if sc_is_known_predicate(ICMP_UGT, sc_get_element_count(tc_ty, evf.n, false), rem) continue;
        if ec_is_scalar(result.width) || lvp_is_more_profitable(lp, next, result, max_tc, has_tail) {
            result = next;
            best = cur;
        }
    }
    if !best return null;
    lv_dbg("LEV: Vectorizing epilogue loop with VF = %\n", lv_ec_str(result.width));
    clone := vp_duplicate(best);
    vp_set_vf(result.width);
    return clone;
}

// preparePlanForMainVectorLoop: returns the ResumeForEpilogue recipes of the scalar header phis (in the main plan)
lv_prepare_plan_for_main_vector_loop :: (main_plan: *Vp_Plan, epi_plan: *Vp_Plan) -> [..] Vp_Rec {
    add_freeze :: (update_resume_phis: bool) {
        for r: vp_block_recipes(vp_middle_block()) {
            if vr(r).kind != .INSTRUCTION continue;
            ok, _, orig_start := vp_match_find_iv_result(r);
            if !ok continue;
            if is_guaranteed_not_to_be_undef_or_poison(vp_ir(orig_start)) continue;
            b := vpb_at_end(vpl.entry);
            frz := vpb_nary(*b, vp_opc(.FREEZE), .[orig_start], .{}, .[], NONE, "fr");
            vp_set_operand(r, 2, vr(frz).def);
            if update_resume_phis {
                pred :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return u != (cast(*Vp_Rec) data).* && vp_is_vp_phi(u); }
                vp_replace_uses_with_if(orig_start, vr(frz).def, pred, *frz);
            }
        }
    }
    vp_use(main_plan);
    add_freeze(true);
    vp_use(epi_plan);
    add_freeze(false);
    vp_use(main_plan);
    term := vp_terminator(vp_exiting_basic_block(vp_vector_loop_region()));
    ok, _, vtc := vpm_branch_on_count(term);
    assert(ok, "must match vector trip count");
    sph := vp_scalar_preheader();
    resume_phi: Vp_Rec = NONE;
    for r: vp_block_phis(sph) {
        if vp_is_vpi(r, vp_opc(.PHI)) && vp_nops(r) == 2 && vp_op(r, 0) == vtc && vpm_zero_int(vp_op(r, 1)) { resume_phi = r; break; }
    }
    if resume_phi == NONE {
        ty := vp_scalar_type(vtc);
        b := vpb_at(sph, vb(sph).first);
        resume_phi = vpb_scalar_phi(*b, .[vtc, vp_zero(ty)], NONE, "vec.epilog.resume.val");
    } else {
        vr(resume_phi).name = "vec.epilog.resume.val";
        if vb(sph).first != resume_phi vp_move_before(resume_phi, sph, vb(sph).first);
    }
    rb := vpb_at_end(sph);
    vpb_nary(*rb, VPI_RESUME_FOR_EPILOGUE, .[vr(resume_phi).def, vp_op(resume_phi, 1)]);
    out: [..] Vp_Rec; out.allocator = temp;
    for r: vp_block_phis(vpl.scalar_header) {
        assert(vr(r).kind == .IR_INSTRUCTION, "only VPIRPhis expected in the scalar header");
        main_resume := vp_op(r, 0);
        bypass := vp_op(vp_def(main_resume), 1);
        array_add(*out, vpb_nary(*rb, VPI_RESUME_FOR_EPILOGUE, .[main_resume, bypass]));
    }
    return out;
}

// addIterationCountCheckBlock
vp_add_iteration_count_check_block :: (vf: Ec, uf: u32, requires_scalar_epilogue: bool, l: Loop_Id, bypass_weights: [] u32,
                                       dl: Md_Id, pse: *Pse) {
    check := vp_new_block(.BASIC, "vector.main.loop.iter.check");
    vp_insert_check_block_before_vector_loop(check);
    vp_add_minimum_iteration_check(vf, uf, ec_fixed(0), requires_scalar_epilogue, false, l, bypass_weights, dl, pse, check);
}

// addMinimumVectorEpilogueIterationCheck
vp_add_minimum_vector_epilogue_iteration_check :: (vector_trip_count: Value_Id, requires_scalar_epilogue: bool, epi_vf: Ec,
                                                   epi_uf: u32, main_step: u32, epi_step: u32) {
    tc := vpl.trip_count;
    tcv := vp_ir(tc);
    b := vpb_at_end(vpl.entry);
    vfxuf := vr(vpb_insert(*b, vp_new_expand_scev(sc_get_element_count(vtype(tcv), epi_vf.n * epi_uf, epi_vf.scalable, SF_NUW)))).def;
    count := vr(vpb_sub(*b, tc, vp_live_in(vector_trip_count), NONE, "n.vec.remaining")).def;
    p: u8 = xx ifx requires_scalar_epilogue then ICMP_ULE else ICMP_ULT;
    chk := vr(vpb_icmp(*b, p, count, vfxuf, NONE, "min.epilog.iters.check")).def;
    br := vpb_nary(*b, VPI_BRANCH_ON_COND, .[chk]);
    skip := min(main_step, epi_step);
    vp_set_md(br, md_kind_id(MD_PROF_NAME), md_branch_weights(.[skip, main_step - skip], false));
}

// what preparePlanForEpilogueVectorLoop needs from the executed main plan
Lv_Main_Resume :: struct { phi: Value_Id; resume: Value_Id; bypass: Value_Id; }

// preparePlanForEpilogueVectorLoop (on the current plan, the epilogue plan); returns InstsToMove
lv_prepare_plan_for_epilogue_vector_loop :: (lp: *Lv_Planner, main_plan: *Vp_Plan, epi_plan: *Vp_Plan, expanded: *Table(Scev_Id, Value_Id),
                                             epi: *Lv_Epi_Info, resume_values: [] Vp_Rec) -> [..] Value_Id {
    // the main plan's ResumeForEpilogue markers, by scalar header phi
    vp_use(main_plan);
    resumes: [..] Lv_Main_Resume; resumes.allocator = temp;
    hphis := vp_block_phis(vpl.scalar_header);
    assert(hphis.count == resume_values.count);
    for r, k: hphis {
        rv := resume_values[k];
        bp := vp_op(rv, 1);
        array_add(*resumes, .{vr(r).ir_inst, vp_uv(vr(rv).def), vp_uv(bp)});
    }
    first := vp_first_non_phi(vp_scalar_preheader());
    assert(vp_is_vpi(first, VPI_RESUME_FOR_EPILOGUE));
    ep_resume_val := vp_uv(vr(first).def);
    vp_use(epi_plan);
    find_resume :: (resumes: [] Lv_Main_Resume, phi: Value_Id) -> *Lv_Main_Resume {
        for * resumes if it.phi == phi return it;
        fatal("internal: no ResumeForEpilogue for the phi");
        return null;
    }

    region := vp_vector_loop_region();
    header := vp_entry_basic_block(region);
    vb(header).name = "vec.epilog.vector.body";
    iv := vb(region).can_iv;
    if vkind(ep_resume_val) == .INST && inst_op(ep_resume_val) == .PHI {
        n := phi_num_incoming(ep_resume_val);
        for k: 0..n-1 {
            inc := phi_value(ep_resume_val, k);
            if vkind(inc) == .C_INT && const_int_zext(inc) == 0 continue;
            assert(epi.vector_trip_count == NONE, "Must only have a single non-zero incoming value");
            epi.vector_trip_count = inc;
        }
        if epi.vector_trip_count == NONE epi.vector_trip_count = phi_value(ep_resume_val, 0);
    } else {
        epi.vector_trip_count = ep_resume_val;
    }
    vpv := vp_live_in(ep_resume_val);
    hb := vpb_at(header, vp_first_non_phi(header));
    add := vpb_add(*hb, iv, vpv);
    inc := vp_find_canonical_iv_increment();
    assert(inc != NONE, "Must have a canonical IV increment at this point");
    Ex :: struct { a: Vp_Rec; b: Vp_Rec; }
    ex := Ex.{add, inc};
    not_add_or_inc :: (r: Vp_Rec, idx: s64, data: *void) -> bool { e := cast(*Ex) data; return r != e.a && r != e.b; }
    vp_replace_uses_with_if(iv, vr(add).def, not_add_or_inc, *ex);
    ab := vpb_after(inc);
    off_inc := vpb_add(*ab, vr(inc).def, vpv);
    vp_rauw(vr(inc).def, vr(off_inc).def);
    vp_set_operand(off_inc, 0, vr(inc).def);

    insts_to_move: [..] Value_Id; insts_to_move.allocator = temp;
    to_frozen: Table(Value_Id, Value_Id); to_frozen.allocator = temp;
    for r: vp_block_phis(header) {
        resume_v: Value_Id = NONE;
        if vr(r).kind == .REDUCTION_PHI {
            is_rdx_result :: (x: Vp_Rec) -> bool { return vp_is_vpi(x, VPI_COMPUTE_REDUCTION_RESULT); }
            rdx_result := vp_find_recipe(vp_op(r, 1), is_rdx_result);
            assert(rdx_result != NONE, "expected to find reduction result");
            mr := find_resume(resumes, vp_uv(vr(r).def));
            resume_v = mr.resume;
            is_find_iv := false;
            sentinel: Vp_Val = NONE;
            for u: vv(vr(rdx_result).def).users if vp_is_vpi(u, vp_opc(.ICMP)) && vr(u).flags.pred == ICMP_NE && vp_op(u, 0) == vr(rdx_result).def {
                is_find_iv = true; sentinel = vp_op(u, 1); break;
            }
            rk := vr(r).rdx_kind;
            if rk_is_any_of(rk) || is_find_iv {
                start_v := mr.bypass;
                b: Irb;
                irb_set_before(*b, block_first_non_phi(inst(resume_v).parent));
                if rk_is_any_of(rk) {
                    resume_v = isf_icmp(*b, ICMP_NE, resume_v, start_v);
                    if is_inst(resume_v) array_add(*insts_to_move, resume_v);
                } else {
                    assert(sentinel != NONE, "expected to find icmp using RdxResult");
                    if is_inst(start_v) && inst_op(start_v) == .FREEZE table_set(*to_frozen, op(start_v, 0), start_v);
                    cmp := isf_icmp(*b, ICMP_EQ, resume_v, start_v);
                    if is_inst(cmp) array_add(*insts_to_move, cmp);
                    resume_v = irb_select(*b, cmp, vp_ir(sentinel), resume_v);
                    if is_inst(resume_v) array_add(*insts_to_move, resume_v);
                }
            } else {
                start_val := vp_live_in(resume_v);
                sv := vp_op(r, 0);
                if vp_val_is_vpi(sv, VPI_REDUCTION_START_VECTOR) {
                    if vr(r).rdx_scale > 1 && rk_is_sub(rk) vp_unported("partial sub-reductions in epilogue vectorization");
                    vp_set_operand(vp_def(sv), 0, start_val);
                    continue;
                }
            }
        } else {
            assert(vp_is_widen_induction_kind(vr(r).kind), "expected a widened induction");
            resume_v = find_resume(resumes, vp_uv(vr(r).def)).resume;
        }
        assert(resume_v != NONE, "Must have a resume value");
        vp_set_operand(r, 0, vp_live_in(resume_v));
    }

    // re-use the values expanded for the main loop
    r := vb(vpl.entry).first;
    while r != NONE {
        nx := vr(r).next;
        defer r = nx;
        if vp_is_vpi(r, vp_opc(.FREEZE)) {
            _, fz := table_find(*to_frozen, vp_ir(vp_op(r, 0)));
            vp_rauw(vr(r).def, vp_live_in(fz));
            continue;
        }
        if vr(r).kind != .EXPAND_SCEV continue;
        _, ev := table_find(expanded, vr(r).expr);
        evv := vp_live_in(ev);
        d := vr(r).def;
        vp_rauw(d, evv);
        if vpl.trip_count == d vpl.trip_count = evv;
        vp_erase_recipe(r);
    }
    main_step := cast(u32) (epi.main_vf.n * epi.main_uf);
    epi_step := cast(u32) (epi.epi_vf.n * epi.epi_uf);
    vp_add_minimum_vector_epilogue_iteration_check(epi.vector_trip_count, lvp_requires_scalar_epilogue(), epi.epi_vf, epi.epi_uf,
                                                   main_step, epi_step);
    return insts_to_move;
}

// fixScalarResumeValuesFromBypass
lv_fix_scalar_resume_values_from_bypass :: (bypass: Value_Id, l: Loop_Id, li: *Loop_Info, epi_plan: *Vp_Plan, main_plan: *Vp_Plan,
                                           resume_values: [] Vp_Rec) {
    ph := li_loop_preheader(li, l);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(ph, *preds);
    for pred: preds {
        for phi: block_insts(ph) {
            if inst_op(phi) != .PHI break;
            if phi_block_index(phi, pred) != -1 continue;
            phi_add_incoming(phi, phi_incoming_value_for_block(phi, bypass), pred);
        }
    }
    vp_use(main_plan);
    main_resume: [..] Value_Id; main_resume.allocator = temp;
    for resume_values array_add(*main_resume, vp_uv(vr(it).def));
    vp_use(epi_plan);
    sph := vp_scalar_preheader();
    if sph == NONE || vb(sph).preds.count == 0 return;
    for hp, k: vp_block_phis(vpl.scalar_header) {
        if k >= main_resume.count break;
        epi_resume := phi_incoming_value_for_block(vr(hp).ir_inst, ph);
        if phi_block_index(epi_resume, bypass) == -1 continue;
        mrp := main_resume[k];
        idx := phi_block_index(epi_resume, bypass);
        phi_set_value(epi_resume, cast(u32) idx, phi_incoming_value_for_block(mrp, bypass));
    }
}

// connectEpilogueVectorLoop
lv_connect_epilogue_vector_loop :: (lp: *Lv_Planner, epi_plan: *Vp_Plan, main_plan: *Vp_Plan, epi: *Lv_Epi_Info, checks: *Lv_Rt_Checks,
                                    insts_to_move: [] Value_Id, resume_values: [] Vp_Rec) {
    vp_use(epi_plan);
    iter_check := vb(vpl.entry).irbb;
    epi_ph := get_successor(block_terminator(iter_check), 1);
    assert(epi.main_loop_iteration_count_check != NONE && epi.epilogue_iteration_count_check != NONE);
    dt := lp.p.dt;
    redirect :: (bb: Value_Id, new_succ: Value_Id, iter_check: Value_Id, dt: *Dom_Tree) {
        replace_uses_of_with(block_terminator(bb), iter_check, new_succ);
        dt_apply_updates(dt, .[.{false, bb, iter_check}, .{true, bb, new_succ}]);
    }
    redirect(epi.main_loop_iteration_count_check, epi_ph, iter_check, dt);
    scalar_ph := vb(vp_scalar_preheader()).irbb;
    redirect(epi.epilogue_iteration_count_check, scalar_ph, iter_check, dt);
    _, scev_block := lv_rt_scev_checks(checks);
    _, mem_block := lv_rt_mem_checks(checks);
    if scev_block != NONE redirect(scev_block, scalar_ph, iter_check, dt);
    if mem_block != NONE redirect(mem_block, scalar_ph, iter_check, dt);

    phis: [..] Value_Id; phis.allocator = temp;
    for block_insts(iter_check) { if inst_op(it) != .PHI break; array_add(*phis, it); }
    single_pred := block_single_predecessor(iter_check);
    for phi: phis {
        inst_move_before(phi, block_first_non_phi(epi_ph));
        phi_replace_incoming_block(phi, single_pred, iter_check);
        if phi_block_index(phi, epi.epilogue_iteration_count_check) == -1 continue;
        for bb: Value_Id.[epi.epilogue_iteration_count_check, scev_block, mem_block] {
            if bb != NONE phi_remove_incoming_block(phi, bb);
        }
    }
    ip := block_first_non_phi(epi_ph);
    for insts_to_move inst_move_before(it, ip);
    lv_fix_scalar_resume_values_from_bypass(iter_check, lp.l, lp.li, epi_plan, main_plan, resume_values);
    for :early_inc phi: block_insts(epi_ph) {
        if inst_op(phi) != .PHI break;
        if !has_uses(phi) erase_inst(phi);
    }
}

// processLoop's epilogue-vectorization branch
lvp_vectorize_with_epilogue :: (lp: *Lv_Planner, main_plan: *Vp_Plan, epi_plan: *Vp_Plan, vf: Lv_Vf, ic: u64, checks: *Lv_Rt_Checks, has_bw: bool) {
    vp_use(epi_plan);
    epi_vf := vp_single_vf();
    vb(vp_middle_block()).name = "vec.epilog.middle.block";
    vb(vp_vector_preheader()).name = "vec.epilog.ph";
    resume_values := lv_prepare_plan_for_main_vector_loop(main_plan, epi_plan);
    epi: Lv_Epi_Info;
    epi.main_vf = vf.width; epi.main_uf = cast(u32) ic; epi.epi_vf = epi_vf; epi.epi_uf = 1;
    vp_use(main_plan);
    lvp_add_minimum_iteration_check(lp, epi.epi_vf, epi.epi_uf, ec_fixed(0), has_bw);
    lvp_attach_runtime_checks(lp, checks, has_bw);
    w := u32.[1, 127];
    bw: [] u32;
    if has_bw bw = w;
    pred := li_loop_predecessor(lp.li, lp.l);
    vp_add_iteration_count_check_block(epi.main_vf, epi.main_uf, lvp_requires_scalar_epilogue(), lp.l, bw,
                                       inst_dl(block_terminator(pred)), lp.pse);
    expanded := lvp_execute_plan(lp, epi.main_vf, epi.main_uf, checks, .MAIN_LOOP);
    vp_use(main_plan);
    entry_bb := vb(vpl.entry).irbb;
    set_name(entry_bb, "iter.check");
    epi.epilogue_iteration_count_check = entry_bb;
    last_check := entry_bb;
    _, mem_bb := lv_rt_mem_checks(checks);
    _, scev_bb := lv_rt_scev_checks(checks);
    if mem_bb != NONE last_check = mem_bb;
    else if scev_bb != NONE last_check = scev_bb;
    scalar_ph := li_loop_preheader(lp.li, lp.l);
    bi := block_terminator(last_check);
    epi.main_loop_iteration_count_check = get_successor(bi, cast(u32) ifx get_successor(bi, 0) == scalar_ph then 1 else 0);
    insts_to_move := lv_prepare_plan_for_epilogue_vector_loop(lp, main_plan, epi_plan, *expanded, *epi, resume_values);
    vp_use(epi_plan);
    lvp_attach_runtime_checks(lp, checks, has_bw);
    lvp_execute_plan(lp, epi.epi_vf, epi.epi_uf, checks, .EPILOGUE);
    lv_connect_epilogue_vector_loop(lp, epi_plan, main_plan, *epi, checks, insts_to_move, resume_values);
}
