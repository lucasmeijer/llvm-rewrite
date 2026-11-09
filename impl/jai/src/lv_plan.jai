// LoopVectorizationPlanner: tryToBuildVPlan1, buildVPlans, tryToBuildVPlan, plan() for vector VFs, executePlan.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (LoopVectorizationPlanner methods) (LLVM 23.1.5).

Lv_Planner :: struct {
    p: *Lv_Pass;
    l: Loop_Id;
    li: *Loop_Info;
    lvl: *Lvl;
    cm: *Lv_Cm;
    hints: *Lv_Hints;
    pse: *Pse;
    vplans: [..] *Vp_Plan;
    in_loop_reductions: [..] Value_Id;
}

// LoopVectorizationPlanner::tryToBuildVPlan1
lvp_try_to_build_vplan1 :: (lp: *Lv_Planner) -> *Vp_Plan {
    lvl := lp.lvl;
    laa := lvl.laa;
    lver := New(Lv_Noalias,, allocator = temp);
    if laa.rt.checks.count && !laa.rt.can_use_diff_check lv_prepare_no_alias_metadata(lver, *laa.rt);
    plan := vp_build_vplan0(lp.li, lp.l, lvl.widest_ind_ty, lp.pse, lver);
    dt := vp_dt_build();
    if laa.symbolic_strides.count vp_unported("replaceSymbolicStrides");
    vp_simplify_recipes();
    vp_remove_dead_recipes();
    if !vp_create_header_phi_recipes(lp.pse, lp.li, lp.l, *dt, lvl, lp.in_loop_reductions, lvh_allow_reordering(lp.hints)) return null;
    force := lvh_force(lp.hints) == FK_ENABLED;
    opt_for_size := !force && (lp.cm.sel == .NOT_ALLOWED_OPT_SIZE || lp.cm.sel == .NOT_ALLOWED_LOW_TRIP_LOOP);
    threshold := ifx force then lv_opts.pragma_scev_check_threshold else lv_opts.scev_check_threshold;
    if !vp_finalize_scev_predicates(lp.pse, opt_for_size, threshold) return null;
    vp_add_middle_check();
    if !vp_handle_early_exits(lvl_has_uncountable_early_exit(lvl)) return null;
    pi := lvl.primary_induction;
    vp_create_loop_regions(lv_debug_loc_from_inst_or_operands(pi));
    if lv_cm_fold_tail_by_masking(lp.cm) vp_unported("tail folding by masking (foldTailByMasking)");
    vp_introduce_masks_and_linearize();
    return plan;
}

// getDebugLocFromInstOrOperands
lv_debug_loc_from_inst_or_operands :: (i: Value_Id) -> Md_Id {
    if i == NONE return NONE;
    d := inst_dl(i);
    if d != NONE return d;
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if is_inst(o) && inst_dl(o) != NONE return inst_dl(o);
    }
    return d;
}

// VFRange + getDecisionAndClampRange
Vf_Range :: struct { start: Ec; end: Ec; }
lvp_decision_and_clamp_range :: (r: *Vf_Range, pred: (vf: Ec, data: *void) -> bool, data: *void) -> bool {
    at_start := pred(r.start, data);
    vf := Ec.{r.start.n * 2, r.start.scalable};
    while vf.n < r.end.n {
        if pred(vf, data) != at_start { r.end = vf; break; }
        vf.n *= 2;
    }
    return at_start;
}

// VPBuilder::createConsecutiveVectorPointer
vpb_consecutive_vector_pointer :: (b: *Vp_Builder, ptr: Vp_Val, src_elt_ty: Type_Id, reverse: bool, dl: Md_Id) -> Vp_Rec {
    flags := vp_gep_flags_for_ptr(ptr);
    if reverse vp_unported("reverse consecutive accesses (VPVectorEndPointerRecipe)");
    stride_ty := dl_int_ptr_type(vp_scalar_type(ptr));
    one := vp_const_int(stride_ty, 1);
    return vpb_insert(b, vp_new_vector_pointer(ptr, src_elt_ty, one, flags, dl));
}
vp_new_vector_pointer :: (ptr: Vp_Val, src_elt_ty: Type_Id, stride: Vp_Val, gep: u32, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.VECTOR_POINTER, .[ptr, stride], vp_scalar_type(ptr), NONE, dl);
    vr(r).src_elt_ty = src_elt_ty; vr(r).flags = vpf_gep(gep);
    return r;
}
// vputils::getGEPFlagsForPtr
vp_gep_flags_for_ptr :: (ptr_in: Vp_Val) -> u32 {
    ptr := ptr_in;
    while true {
        r := vp_def(ptr);
        if r == NONE || vr(r).kind != .INSTRUCTION break;
        o := vr(r).opcode;
        if o == vp_opc(.GEP) {
            all_zero := true;
            for k: 1..vp_nops(r)-1 if !vpm_zero_int(vp_op(r, k)) all_zero = false;
            if !all_zero return vr(r).flags.gep;
            ptr = vp_op(r, 0);
            continue;
        }
        if o != vp_opc(.BITCAST) && o != vp_opc(.ADDRSPACECAST) break;
        ptr = vp_op(r, 0);
    }
    return 0;
}
// VPWidenLoadRecipe / VPWidenStoreRecipe constructors
vp_new_widen_load :: (ld: Value_Id, addr: Vp_Val, mask: Vp_Val, consecutive: bool, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.WIDEN_LOAD, .[addr], vtype(ld), ld, dl);
    vr(r).ir_inst = ld; vr(r).align = inst(ld).align; vr(r).consecutive = consecutive;
    for md array_add(*vr(r).md, it);
    if mask != NONE { vp_add_operand(r, mask); vr(r).masked = true; }
    return r;
}
vp_new_widen_store :: (st: Value_Id, addr: Vp_Val, val: Vp_Val, mask: Vp_Val, consecutive: bool, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    r := vp_new_recipe(.WIDEN_STORE, .[addr, val], dl);
    vr(r).ir_inst = st; vr(r).align = inst(st).align; vr(r).consecutive = consecutive;
    for md array_add(*vr(r).md, it);
    if mask != NONE { vp_add_operand(r, mask); vr(r).masked = true; }
    return r;
}

Lvp_Vf_Ctx :: struct { lp: *Lv_Planner; i: Value_Id; }

// VPRecipeBuilder::handleReplication
lvp_handle_replication :: (lp: *Lv_Planner, vpi: Vp_Rec, range: *Vf_Range) -> Vp_Rec {
    i := vp_underlying_instr(vpi);
    ctx := Lvp_Vf_Ctx.{lp, i};
    uni :: (vf: Ec, d: *void) -> bool { c := cast(*Lvp_Vf_Ctx) d; return lv_cm_is_uniform_after_vectorization(c.lp.cm, c.i, vf); }
    is_uniform := lvp_decision_and_clamp_range(range, uni, *ctx);
    is_pred := lv_cm_is_predicated_inst(lp.cm, i);
    mask: Vp_Val = NONE;
    if is_pred mask = vp_mask_of(vpi);
    if is_uniform return vp_create_single_scalar_op(vr(vpi).opcode, vp_ops_without_mask(vpi), mask, vr(vpi).flags, vr(vpi).md, vr(vpi).dl, i);
    return vp_new_replicate(i, vp_ops_without_mask(vpi), false, mask, vr(vpi).flags, vr(vpi).md, vr(vpi).dl);
}
// VPRecipeBuilder::tryToWidenMemory
lvp_try_to_widen_memory :: (lp: *Lv_Planner, vpi: Vp_Rec, range: *Vf_Range, b: *Vp_Builder) -> Vp_Rec {
    i := vp_underlying_instr(vpi);
    ctx := Lvp_Vf_Ctx.{lp, i};
    will_widen :: (vf: Ec, d: *void) -> bool {
        c := cast(*Lvp_Vf_Ctx) d;
        dec := lv_cm_widening_decision(c.lp.cm, c.i, vf);
        if dec == .INTERLEAVE return true;
        if lv_cm_is_scalar_after_vectorization(c.lp.cm, c.i, vf) || lv_cm_is_profitable_to_scalarize(c.lp.cm, c.i, vf) return false;
        return dec != .SCALARIZE;
    }
    if !lvp_decision_and_clamp_range(range, will_widen, *ctx) return NONE;
    mask := ifx lv_cm_is_mask_required(lp.cm, i) then vp_mask_of(vpi) else NONE;
    dec := lv_cm_widening_decision(lp.cm, i, range.start);
    reverse := dec == .WIDEN_REVERSE;
    consecutive := reverse || dec == .WIDEN;
    is_load := vr(vpi).opcode == vp_opc(.LOAD);
    ptr := ifx is_load then vp_op(vpi, 0) else vp_op(vpi, 1);
    if consecutive {
        bb := vpb_before(vpi);
        ptr = vr(vpb_consecutive_vector_pointer(*bb, ptr, load_store_type(i), reverse, vr(vpi).dl)).def;
    }
    if reverse vp_unported("reverse accesses");
    if is_load return vp_new_widen_load(i, ptr, mask, consecutive, vr(vpi).md, inst_dl(i));
    return vp_new_widen_store(i, ptr, vp_op(vpi, 0), mask, consecutive, vr(vpi).md, inst_dl(i));
}
// VPRecipeBuilder::tryToCreateWidenNonPhiRecipe
lvp_try_to_create_widen_non_phi_recipe :: (lp: *Lv_Planner, r: Vp_Rec, range: *Vf_Range) -> Vp_Rec {
    o := vr(r).opcode;
    if o == vp_opc(.TRUNC) {
        i := vp_underlying_instr(r);
        ctx := Lvp_Vf_Ctx.{lp, i};
        opt :: (vf: Ec, d: *void) -> bool { c := cast(*Lvp_Vf_Ctx) d; return lv_cm_is_optimizable_iv_truncate(c.lp.cm, c.i, vf); }
        if lvp_decision_and_clamp_range(range, opt, *ctx) vp_unported("optimizable induction truncates (tryToOptimizeInductionTruncate)");
    }
    scalar :: (vf: Ec, d: *void) -> bool { return ec_is_scalar(vf); }
    if lvp_decision_and_clamp_range(range, scalar, null) return NONE;
    instr := vp_underlying_instr(r);
    ctx := Lvp_Vf_Ctx.{lp, instr};
    will_scalarize :: (vf: Ec, d: *void) -> bool {
        c := cast(*Lvp_Vf_Ctx) d;
        return lv_cm_is_scalar_after_vectorization(c.lp.cm, c.i, vf) || lv_cm_is_profitable_to_scalarize(c.lp.cm, c.i, vf) ||
               lv_cm_is_scalar_with_predication(c.lp.cm, c.i, vf);
    }
    if lvp_decision_and_clamp_range(range, will_scalarize, *ctx) return NONE;
    if o == vp_opc(.GEP) {
        g := vp_new_single_def(.WIDEN_GEP, vp_ops_without_mask(r), vp_scalar_type(vp_op(r, 0)), instr, vr(r).dl);
        vr(g).src_elt_ty = gep_source_type(instr); vr(g).flags = vr(r).flags;
        return g;
    }
    if vp_opcode_is_cast(o) return vp_new_widen_cast(vp_ir_opcode(o), vp_op(r, 0), vp_scalar_type(vr(r).def), instr, vr(r).flags, vr(r).md, vr(r).dl);
    // tryToWiden
    if !vp_is_ir_opcode(o) return NONE;
    io := vp_ir_opcode(o);
    if io == .SDIV || io == .UDIV || io == .SREM || io == .UREM {
        if lv_cm_is_predicated_inst(lp.cm, instr) vp_unported("masked div/rem intrinsics");
    }
    if io == .SDIV || io == .UDIV || io == .SREM || io == .UREM || io == .ADD || io == .AND || io == .ASHR || io == .FADD ||
       io == .FCMP || io == .FDIV || io == .FMUL || io == .FNEG || io == .FREM || io == .FSUB || io == .ICMP || io == .LSHR ||
       io == .MUL || io == .OR || io == .SELECT || io == .SHL || io == .SUB || io == .XOR || io == .FREEZE {
        ops := vp_ops_without_mask(r);
        w := vp_new_single_def(.WIDEN, ops, vp_compute_scalar_type_for_instruction(o, ops), instr, vr(r).dl);
        vr(w).opcode = o; vr(w).flags = vr(r).flags;
        for vr(r).md array_add(*vr(w).md, it);
        return w;
    }
    if io == .EXTRACTVALUE vp_unported("widening extractvalue");
    return NONE;
}

// VPlanTransforms::makeMemOpWideningDecisions (no histograms / reduction stores / irregular types in the ported subset)
lvp_make_mem_op_widening_decisions :: (lp: *Lv_Planner, range: *Vf_Range) {
    mem_ops: [..] Vp_Rec; mem_ops.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vp_entry_basic_block(vp_vector_loop_region())))
        for r: vp_block_recipes(bb)
            if vr(r).kind == .INSTRUCTION && vv(vr(r).def).uv != NONE && (vr(r).opcode == vp_opc(.LOAD) || vr(r).opcode == vp_opc(.STORE))
                array_add(*mem_ops, r);
    replace_with :: (vpi: Vp_Rec, new: Vp_Rec) {
        vp_insert_before(new, vpi);
        if vr(vpi).opcode == vp_opc(.LOAD) vp_rauw(vr(vpi).def, vr(new).def);
        vp_erase_recipe(vpi);
    }
    // lowerMemoryIdioms
    remaining: [..] Vp_Rec; remaining.allocator = temp;
    for vpi: mem_ops {
        if vr(vpi).opcode == vp_opc(.STORE) && lvl_is_invariant_address_of_reduction(lp.lvl, op(vp_underlying_instr(vpi), 1))
            vp_unported("stores of reductions to invariant addresses");
        array_add(*remaining, vpi);
    }
    mem_ops = remaining;
    scalar :: (vf: Ec, d: *void) -> bool { return ec_is_scalar(vf); }
    if lvp_decision_and_clamp_range(range, scalar, null) return;
    // scalarizeMemOpsWithIrregularTypes
    remaining2: [..] Vp_Rec; remaining2.allocator = temp;
    for vpi: mem_ops {
        if lv_has_irregular_type(load_store_type(vp_underlying_instr(vpi))) { replace_with(vpi, lvp_handle_replication(lp, vpi, range)); continue; }
        array_add(*remaining2, vpi);
    }
    mem_ops = remaining2;
    if !lv_tti_prefers_vectorized_addressing(lp.cm.tti) vp_unported("makeVPlanMemOpDecision");
    // widenConsecutiveMemOps
    remaining3: [..] Vp_Rec; remaining3.allocator = temp;
    for vpi: mem_ops {
        i := vp_underlying_instr(vpi);
        if lv_cm_is_predicated_inst(lp.cm, i) { array_add(*remaining3, vpi); continue; }
        is_load := vr(vpi).opcode == vp_opc(.LOAD);
        ptr := vp_op(vpi, ifx is_load then 0 else 1);
        sty := ifx is_load then vp_scalar_type(vr(vpi).def) else vp_scalar_type(vp_op(vpi, 0));
        e := vp_scev_for_value(ptr, lp.pse, lp.l);
        ok_s := false; stride: s64 = 0;
        if sc_is_addrec(e) { ok_s, stride = laa_stride_from_add_rec(e, lp.l, sty); }
        if !ok_s || stride != 1 { array_add(*remaining3, vpi); continue; }
        stride_ty := dl_int_ptr_type(vp_scalar_type(ptr));
        vptr := vp_new_vector_pointer(ptr, sty, vp_const_int(stride_ty, 1), vp_gep_flags_for_ptr(ptr), vr(vpi).dl);
        vp_insert_before(vptr, vpi);
        w: Vp_Rec;
        if is_load w = vp_new_widen_load(i, vr(vptr).def, NONE, true, vr(vpi).md, vr(vpi).dl);
        else w = vp_new_widen_store(i, vr(vptr).def, vp_op(vpi, 0), NONE, true, vr(vpi).md, vr(vpi).dl);
        replace_with(vpi, w);
    }
    mem_ops = remaining3;
    // delegateMemOpWideningToLegacyCM
    for vpi: mem_ops {
        b := vpb_before(vpi);
        r := lvp_try_to_widen_memory(lp, vpi, range, *b);
        if r != NONE replace_with(vpi, r);
        else replace_with(vpi, lvp_handle_replication(lp, vpi, range));
    }
}

// VPlanTransforms::makeScalarizationDecisions
lvp_make_scalarization_decisions :: (range: *Vf_Range) {
    scalar :: (vf: Ec, d: *void) -> bool { return ec_is_scalar(vf); }
    if lvp_decision_and_clamp_range(range, scalar, null) return;
    rpo := vp_rpo(vpl.entry, true);
    for < bb: rpo {
        if !vp_is_basic(bb) continue;
        r := vb(bb).last;
        while r != NONE {
            prev := vr(r).prev;
            defer r = prev;
            if vr(r).kind != .INSTRUCTION continue;
            i := vv(vr(r).def).uv;
            if i == NONE || !is_inst(i) continue;
            if vp_may_have_side_effects(r) continue;
            if vp_is_masked(r) && !vp_is_safe_to_speculatively_execute(r) continue;
            if vr(r).opcode == vp_opc(.ADD) {
                skip := false;
                for vr(r).ops { d := vp_def(it); if d != NONE && vr(d).kind == .WIDEN_INT_OR_FP_INDUCTION skip = true; }
                if skip continue;
            }
            if !vp_only_first_lane_used(vr(r).def) continue;
            n := vp_create_single_scalar_op(vr(r).opcode, vp_ops_without_mask(r), NONE, vr(r).flags, vr(r).md, vr(r).dl, i);
            vp_insert_before(n, r);
            vp_rauw(vr(r).def, vr(n).def);
            vp_erase_recipe(r);
        }
    }
}

// LoopVectorizationPlanner::tryToBuildVPlan
lvp_try_to_build_vplan :: (lp: *Lv_Planner, range: *Vf_Range) -> bool {
    ctx := Lvp_Vf_Ctx.{lp, NONE};
    no_epi :: (vf: Ec, d: *void) -> bool { c := cast(*Lvp_Vf_Ctx) d; return !lv_cm_requires_scalar_epilogue(c.lp.cm, ec_is_vector(vf)); }
    requires_check := lvp_decision_and_clamp_range(range, no_epi, *ctx);
    middle := vp_middle_block();
    if !requires_check && vb(middle).succs.count == 2 vp_set_operand(vp_terminator(middle), 0, vp_false());
    may_overflow := false;
    vf := range.start;
    while vf.n < range.end.n { may_overflow |= !lvp_is_indvar_overflow_check_known_false(lp, vf); vf.n *= 2; }
    if may_overflow && lp.cm.tail_folding_style != .NONE vp_unported("clearing the canonical IV NUW flag (tail folding)");
    for lp.lvl.reductions if lv_use_ordered_reductions(lp.cm, *it.d) || lp.in_loop_reductions.count vp_unported("in-loop reductions");
    lvp_make_mem_op_widening_decisions(lp, range);
    lvp_make_scalarization_decisions(range);
    // makeCallWideningDecisions
    for bb: vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)
        for r: vp_block_recipes(bb) if vr(r).kind == .INSTRUCTION && vv(vr(r).def).uv != NONE && vr(r).opcode == vp_opc(.CALL)
            vp_unported("call widening decisions (makeCallWideningDecisions)");
    header := vp_entry_basic_block(vp_vector_loop_region());
    for bb: vp_blocks_only_basic(vp_rpo(header, false)) {
        start := vp_first_non_phi(bb);
        r := start;
        while r != NONE {
            next := vr(r).next;
            defer r = next;
            k := vr(r).kind;
            if k == .WIDEN_CANONICAL_IV || k == .BLEND || k == .REDUCTION || k == .REPLICATE || k == .WIDEN_LOAD || k == .WIDEN_STORE ||
               k == .WIDEN_CALL || k == .WIDEN_INTRINSIC || k == .VECTOR_POINTER || k == .VECTOR_END_POINTER || k == .HISTOGRAM ||
               (vp_is_instruction_with_type(r) && vp_opcode_is_cast(vr(r).opcode) && vp_only_first_lane_used(vr(r).def))
                continue;
            if vv(vr(r).def).uv == NONE continue;
            instr := vv(vr(r).def).uv;
            recipe := lvp_try_to_create_widen_non_phi_recipe(lp, r, range);
            if recipe == NONE recipe = lvp_handle_replication(lp, r, range);
            vp_insert_before(recipe, r);
            if vp_num_defined_values(recipe) == 1 vp_rauw(vr(r).def, vp_defined_value(recipe, 0));
            vp_erase_recipe(r);
        }
    }
    for vp_block_phis(header) if vr(it).kind == .FIRST_ORDER_RECURRENCE_PHI vp_unported("first-order recurrences");
    for vp_block_phis(header) if vr(it).kind == .REDUCTION_PHI vp_unported("reductions");
    lvp_optimize_induction_live_out_users(lp);
    vp_remove_branch_on_const(false);
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry))
        for r: vp_block_recipes(bb) if vr(r).kind == .WIDEN_LOAD && !vr(r).consecutive vp_unported("non-consecutive widened loads (convertToStridedAccesses)");
    if ec_is_scalar(range.start) range.end = Ec.{range.start.n * 2, range.start.scalable};
    vf = range.start;
    while vf.n < range.end.n { vp_add_vf(vf); vf.n *= 2; }
    vpl.name = "Initial VPlan";
    vp_drop_poison_generating_recipes();
    return true;
}
// isIndvarOverflowCheckKnownFalse
lvp_is_indvar_overflow_check_known_false :: (lp: *Lv_Planner, vf: Ec) -> bool {
    t := lp.cm.tti;
    max_uf := max(lv_tti_max_interleave_factor(t, vf, false), lv_tti_max_interleave_factor(t, vf, true));
    idx_ty := lp.lvl.widest_ind_ty;
    known, tc := lv_small_best_known_tc(lp.cm, lp.l, true, false, true);
    if !known return false;
    if vf.scalable || tc.scalable return false;
    mask := ap_all_ones(type_bits(idx_ty));
    diff := ap_sub(mask, ap_from_u64(mask.bits, tc.n));
    return ap_ugt(diff, ap_from_u64(mask.bits, vf.n * max_uf));
}
// m_CanonicalWidenIV / VPWidenIntOrFpInductionRecipe::isCanonical
vp_is_canonical_widen_iv :: (r: Vp_Rec) -> bool {
    if r == NONE || vr(r).kind != .WIDEN_INT_OR_FP_INDUCTION return false;
    return vpm_zero_int(vp_op(r, 0)) && vpm_one(vp_op(r, 1)) && vp_scalar_type(vr(r).def) == vv(vb(vp_recipe_region(r)).can_iv).ty;
}
// getOptimizableIVOf
vp_optimizable_iv_of :: (v: Vp_Val, pse: *Pse) -> Vp_Rec {
    d := vp_def(v);
    if d != NONE && vp_is_widen_induction_kind(vr(d).kind) {
        if vr(d).kind == .WIDEN_INT_OR_FP_INDUCTION && vr(d).ir_inst != NONE return NONE;
        return d;
    }
    if d == NONE || vp_nops(d) != 2 return NONE;
    w := vp_def(vp_op(d, 0));
    if w == NONE || !vp_is_widen_induction_kind(vr(w).kind) w = vp_def(vp_op(d, 1));
    if w == NONE || !vp_is_widen_induction_kind(vr(w).kind) return NONE;
    id := *vpl.inds[vr(w).ind];
    step := vp_op(w, 1);
    wv := vr(w).def;
    has, opc := ind_opcode(id);
    if has && opc == .ADD {
        ok, x := vpm_c_binary_with(v, vp_opc(.ADD), wv);
        return ifx ok && x == step then w else NONE;
    }
    if has && opc == .FADD { ok, x := vpm_c_binary_with(v, vp_opc(.FADD), wv); return ifx ok && x == step then w else NONE; }
    if has && opc == .FSUB { ok, a, b := vpm_binary(v, vp_opc(.FSUB)); return ifx ok && a == wv && b == step then w else NONE; }
    if has && opc == .SUB {
        ok, _, st := vpm_binary(v, vp_opc(.SUB));
        if !ok return NONE;
        a := vp_scev_for_value(step, pse); b := vp_scev_for_value(st, pse);
        return ifx !sc_is_cnc(a) && !sc_is_cnc(b) && a == sc_get_negative(b) then w else NONE;
    }
    if id.kind == .PTR {
        okg, gr := vp_match_gep(v);
        if okg && vp_nops(gr) == 2 && vp_op(gr, 0) == wv && vp_op(gr, 1) == step return w;
    }
    return NONE;
}
// VPlanTransforms::optimizeInductionLiveOutUsers (latch exits; early exits are not ported)
lvp_optimize_induction_live_out_users :: (lp: *Lv_Planner) {
    region := vp_vector_loop_region();
    vec_ph := vp_single_pred(region);
    phb := vpb_at(vec_ph, vb(vec_ph).first);
    end_values: Table(Vp_Rec, Vp_Val); end_values.allocator = temp;
    resume_tc := ifx vp_has_tail_folded() then vpl.trip_count else vpl.vector_trip_count;
    for w: vp_block_phis(vp_entry_basic_block(region)) {
        if !vp_is_widen_induction_kind(vr(w).kind) continue;
        if vr(w).kind == .WIDEN_INT_OR_FP_INDUCTION && vr(w).ir_inst != NONE continue;
        end := resume_tc;
        if !vp_is_canonical_widen_iv(w) {
            d := *vpl.inds[vr(w).ind];
            fpb := ifx d.bop != NONE && is_fp_math_operator(d.bop) then d.bop else NONE;
            end = vr(vpb_insert(*phb, vp_new_derived_iv(d.kind, fpb, vp_op(w, 0), resume_tc, vp_op(w, 1)))).def;
        }
        wty := vp_scalar_type(vr(w).def);
        if wty != vp_scalar_type(end) end = vr(vpb_scalar_cast(*phb, .TRUNC, end, wty, vr(w).dl, vp_default_flags(vp_opc(.TRUNC)))).def;
        table_set(*end_values, w, end);
    }
    middle := vp_middle_block();
    for r: vp_block_recipes(middle) {
        if !vpm_vpi_r(r, VPI_EXITING_IV_VALUE, 1) continue;
        w := vp_def(vp_op(r, 0));
        found, e := table_find(*end_values, w);
        if found { vp_rauw(vr(r).def, e); vp_erase_recipe(r); }
    }
    for eb: vpl.exit_blocks for r: vp_block_phis(eb) {
        for p, idx: vb(eb).preds {
            if p != middle vp_unported("early-exit induction users (optimizeEarlyExitInductionUser)");
            o := vp_op(r, idx);
            ok1, ell := vpm_vpi(o, VPI_EXTRACT_LAST_LANE, 1);
            if !ok1 {
                if vp_val_is_vpi(o, VPI_EXTRACT_LANE) vp_unported("tail-folded live-out induction users");
                continue;
            }
            ok2, elp := vpm_vpi(vp_op(ell, 0), VPI_EXTRACT_LAST_PART, 1);
            if !ok2 continue;
            incoming := vp_op(elp, 0);
            w := vp_optimizable_iv_of(incoming, lp.pse);
            if w == NONE continue;
            _, end := table_find(*end_values, w);
            esc := end;
            if incoming == vr(w).def {
                b := vpb_before(ell);
                step := vp_op(w, 1);
                sty := vp_scalar_type(vr(w).def);
                if type_kind(sty) == .INT esc = vr(vpb_sub(*b, end, step, NONE, "ind.escape")).def;
                else vp_unported("pointer / FP induction escapes (ind.escape)");
            }
            vp_set_operand(r, idx, esc);
        }
    }
}

// LoopVectorizationPlanner::buildVPlans
lvp_build_vplans :: (lp: *Lv_Planner, vplan1: *Vp_Plan, min_vf: Ec, max_vf: Ec) {
    if ec_known_gt(min_vf, max_vf) return;
    max2 := Ec.{max_vf.n * 2, max_vf.scalable};
    vf := min_vf;
    while ec_known_lt(vf, max2) {
        range := Vf_Range.{vf, max2};
        plan := vp_duplicate(vplan1);
        ok := lvp_try_to_build_vplan(lp, *range);
        vf = range.end;
        if !ok continue;
        // hoistPredicatedLoads / sinkPredicatedStores: no predicated replicate recipes in the ported subset
        min_bws := lvp_minimal_bitwidths(lp);
        vp_truncate_to_minimal_bitwidths(min_bws);
        vp_optimize();
        if lp.cm.tail_folding_style == .DATA_WITH_EVL vp_unported("EVL tail folding");
        for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) for r: vp_block_recipes(bb)
            if vr(r).kind == .INTERLEAVE vp_unported("narrowInterleaveGroups");
        vp_materialize_header_mask(false, false);
        array_add(*lp.vplans, plan);
    }
}
// VFSelectionContext::computeMinimalBitwidths (computeMinimumValueSizes): only the empty result is ported
lvp_minimal_bitwidths :: (lp: *Lv_Planner) -> *Table(Value_Id, u64) {
    t := New(Table(Value_Id, u64),, allocator = temp);
    t.allocator = temp;
    seen_ext_from_illegal := false;
    has_root := false;
    for bb: li_blocks(lp.li, lp.l) for i: block_insts(bb) {
        o := inst_op(i);
        if (o == .ZEXT || o == .SEXT) && !lv_tti_is_type_legal(lp.cm.tti, vtype(op(i, 0))) seen_ext_from_illegal = true;
        if (o == .TRUNC || o == .ICMP) && !is_vector_type(vtype(i)) && type_bits(scalar_type(vtype(op(i, 0)))) <= 64 {
            if o == .TRUNC && lv_tti_is_type_legal(lp.cm.tti, vtype(i)) continue;
            has_root = true;
        }
    }
    if !has_root || !seen_ext_from_illegal return t;
    vp_unported("computeMinimumValueSizes");
    return t;
}
lv_tti_is_type_legal :: (t: *Tti, ty: Type_Id) -> bool {
    if t.kind != .X86 return false;
    return tti_is_type_legal(t, ty);
}

// the vector part of LoopVectorizationPlanner::plan and the rest of processLoop (the VPlan path)
lvp_plan_and_vectorize :: (lp: *Lv_Planner, user_vf: Ec, user_ic: u64, max_factors: Vf_Pair) -> bool {
    if ec_is_vector(max_factors.fixed) lvl_collect_unit_stride_predicates(lp.lvl);
    vplan1 := lvp_try_to_build_vplan1(lp);
    if lv_cm_block_needs_predication_for_any_reason(lp.cm, li_header(lp.li, lp.l)) && lv_tti_enable_interleaved_access_vectorization(lp.cm.tti)
        vp_unported("invalidating interleave groups for tail folding");
    if lv_cm_fold_tail_by_masking(lp.cm) lvl_prepare_to_fold_tail_by_masking(lp.lvl);
    max_user_vf := ifx user_vf.scalable then max_factors.scalable else max_factors.fixed;
    if user_vf.n && ec_known_le(user_vf, max_user_vf) {
        lv_cm_collect_non_vectorized_and_set_widening_decisions(lp.cm, user_vf);
        if lv_opts.epilogue_force_vf.set && lv_opts.epilogue_force_vf.v > 1 vp_unported("-epilogue-vectorization-force-VF");
        if vplan1 lvp_build_vplans(lp, vplan1, user_vf, user_vf);
        if lp.vplans.count && ec_eq(vp_plan_single_vf(lp.vplans[lp.vplans.count - 1]), user_vf) {
            // cost(*VPlans.back(), UserVF).isValid(): the VPlan cost model is not ported; fixed-VF costs of the ported
            // recipes are always valid
            return lvp_vectorize_with_plan(lp, lp.vplans[lp.vplans.count - 1], user_vf, user_ic);
        }
        vp_unported("UserVF ignored because of invalid costs");
    }
    vp_unported("choosing the VF with the VPlan cost model (computeBestVF)");
    return false;
}
// LoopVectorizationPlanner::plan when VF 1 is the only candidate (or the user VF), followed by computeBestVF (a
// single scalar plan) and the rest of processLoop: the loop is only interleaved
lvp_plan_scalar_and_interleave :: (lp: *Lv_Planner, user_vf: Ec, user_ic: u64, max_factors: Vf_Pair) -> bool {
    if ec_is_vector(max_factors.fixed) || ec_is_vector(max_factors.scalable) lvl_collect_unit_stride_predicates(lp.lvl);
    vplan1 := lvp_try_to_build_vplan1(lp);
    if !vplan1 return false;
    if lv_cm_block_needs_predication_for_any_reason(lp.cm, li_header(lp.li, lp.l)) && lv_tti_enable_interleaved_access_vectorization(lp.cm.tti)
        vp_unported("invalidating interleave groups for tail folding");
    if lv_cm_fold_tail_by_masking(lp.cm) lvl_prepare_to_fold_tail_by_masking(lp.lvl);
    one := ec_fixed(1);
    lvp_build_vplans(lp, vplan1, one, max_factors.fixed);
    if max_factors.scalable.n lvp_build_vplans(lp, vplan1, ec_scalable(1), max_factors.scalable);
    if lp.vplans.count == 0 return false;
    assert(lp.vplans.count == 1 && vp_plan_single_vf(lp.vplans[0]).n == 1, "expected a single scalar plan");
    return lvp_vectorize_with_plan(lp, lp.vplans[0], one, user_ic);
}
vp_plan_single_vf :: (p: *Vp_Plan) -> Ec { assert(p.vfs.count == 1); return p.vfs[0]; }

// the rest of processLoop for a chosen plan

// VFSelectionContext::collectInLoopReductions
lvp_collect_in_loop_reductions :: (lp: *Lv_Planner) {
    if lp.in_loop_reductions.count return;
    for *lp.lvl.reductions {
        phi := it.phi; rd := *it.d;
        if rd.phi_has_uses_outside_chain continue;
        if rd.recur_type != vtype(phi) continue;
        k := rd.kind;
        if rk_is_any_of(k) || rk_is_find_iv(k) || rk_is_find_last(k) continue;
        if !lv_opts.prefer_inloop_reductions && !lv_use_ordered_reductions(lp.cm, rd) && !lv_tti_prefer_in_loop_reduction(lp.cm.tti, k, vtype(phi)) continue;
        ops := rdx_get_reduction_op_chain(rd, phi);
        if ops.count {
            array_add(*lp.in_loop_reductions, phi);
            vp_unported("in-loop reductions");
        }
    }
}
