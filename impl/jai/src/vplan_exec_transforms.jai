// The VPlan transforms LoopVectorizationPlanner::executePlan runs on the chosen plan before emitting IR:
// replaceWideCanonicalIVWithWideIV, materializePacksAndUnpacks, materializeBroadcasts,
// materializeConstantVectorTripCount, optimizeForVFAndUF (simplifyBranchConditionForVFAndUF,
// optimizeVectorInductionWidthForTCAndVFUF), convertToConcreteRecipes (expandVPWidenIntOrFpInduction,
// expandVPWidenPointerInduction, expandVPDerivedIV, ...), dissolveLoopRegions (VPRegionBlock::dissolveToCFGLoop),
// expandBranchOnTwoConds, materializeBackedgeTakenCount / VectorTripCount / Factors, expandSCEVsToVPInstructions,
// cse and expandSCEVs.
// Ported from llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp and VPlan.cpp (LLVM 23.1.5). EVL / active-lane-mask /
// variable-length-step paths fail loudly (tail folding is not ported).

// VPlanTransforms::replaceWideCanonicalIVWithWideIV
vp_replace_wide_canonical_iv_with_wide_iv :: (vf: Ec, uf: u32) {
    region := vp_vector_loop_region();
    if region == NONE return;
    can_iv := vb(region).can_iv;
    wide: Vp_Rec = NONE;
    for u: vv(can_iv).users if vr(u).kind == .WIDEN_CANONICAL_IV { wide = u; break; }
    if wide == NONE return;
    can_ty := vv(can_iv).ty;
    if vp_has_scalar_vf_only() || vp_only_first_lane_used(vr(wide).def) {
        b := vpb_before(wide);
        steps := vp_create_scalar_iv_steps(.INT, .ADD, NONE, NONE, vp_zero(can_ty), vp_const_int(can_ty, 1), vr(wide).dl, *b);
        vp_rauw(vr(wide).def, vr(steps).def);
        vp_erase_recipe(wide);
        return;
    }
    if vp_only_scalar_values_used(vr(wide).def) return;
    for phi: vp_block_phis(vp_entry_basic_block(region)) {
        if !vp_is_canonical_widen_iv(phi) continue;
        vp_drop_poison_generating_flags(phi);
        vp_rauw(vr(wide).def, vr(phi).def);
        vp_erase_recipe(wide);
        return;
    }
    vp_unported("introducing a wide canonical induction (replaceWideCanonicalIVWithWideIV costs)");
}

// VPlanTransforms::materializePacksAndUnpacks
vp_materialize_packs_and_unpacks :: () {
    if vp_has_scalar_vf_only() return;
    region := vp_vector_loop_region();
    outside := vp_blocks_only_basic(vp_depth_first_shallow(vpl.entry));
    inside := vp_blocks_only_basic(vp_depth_first_shallow(vb(region).entry));
    all: [..] Vp_Blk; all.allocator = temp;
    for outside array_add(*all, it);
    for inside array_add(*all, it);
    Ctx :: struct { d: Vp_Val; region: Vp_Blk; bv: Vp_Rec; }
    uses_vector_or_inside_replicate :: (u: Vp_Rec, c: *Ctx) -> bool {
        return !vp_uses_scalars(u, c.d) || vp_recipe_region(u) != c.region;
    }
    for bb: all for r: vp_block_recipes(bb) {
        k := vr(r).kind;
        if k != .SCALAR_IV_STEPS && k != .REPLICATE && k != .INSTRUCTION continue;
        d := vr(r).def;
        ctx := Ctx.{d, region, NONE};
        if k == .REPLICATE && vr(r).single_scalar continue;
        if k == .INSTRUCTION && (vp_only_first_lane_used(d) || !vpi_does_generate_per_all_lanes(r)) continue;
        any := false;
        for u: vv(d).users if uses_vector_or_inside_replicate(u, *ctx) { any = true; break; }
        if !any continue;
        sty := vp_scalar_type(d);
        opc: u16 = xx ifx type_kind(sty) == .STRUCT then VPI_BUILD_STRUCT_VECTOR else VPI_BUILD_VECTOR;
        bv := vp_new_instruction(opc, .[d]);
        vp_insert_after(bv, r);
        ctx.bv = bv;
        pred :: (u: Vp_Rec, idx: s64, data: *void) -> bool {
            c := cast(*Ctx) data;
            return u != c.bv && uses_vector_or_inside_replicate(u, c);
        }
        vp_replace_uses_with_if(d, vr(bv).def, pred, *ctx);
    }
    for bb: inside for r: vp_block_recipes(bb) {
        k := vr(r).kind;
        if k == .REPLICATE || k == .INSTRUCTION || k == .SCALAR_IV_STEPS || k == .DERIVED_IV continue;
        for di: 0..vp_num_defined_values(r)-1 {
            d := vp_defined_value(r, di);
            if vp_is_single_scalar(d) continue;
            n := 0;
            for u: vv(d).users if vp_uses_first_lane_only(u, d) n += 1;
            if n == 0 || n == vp_num_users(d) continue;
            up := vp_new_instruction(VPI_UNPACK, .[d]);
            if vp_is_phi_recipe(r) vp_insert_recipe(up, bb, vp_first_non_phi(bb));
            else vp_insert_after(up, r);
            first_lane :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return vp_uses_first_lane_only(u, (cast(*Vp_Val) data).*); }
            vp_replace_uses_with_if(d, vr(up).def, first_lane, *d);
        }
    }
}

// VPlanTransforms::materializeBroadcasts
vp_materialize_broadcasts :: () {
    if vp_has_scalar_vf_only() return;
    values: [..] Vp_Val; values.allocator = temp;
    if vpl.btc != NONE array_add(*values, vpl.btc);
    for v: vpl.live_in_order { found, x := table_find(*vpl.live_ins, v); if found array_add(*values, x); }
    r := vb(vpl.entry).first;
    while r != NONE { for k: 0..vp_num_defined_values(r)-1 array_add(*values, vp_defined_value(r, k)); r = vr(r).next; }
    vph := vp_vector_preheader();
    for v: values {
        if vp_only_scalar_values_used(v) || vp_is_constant(v) continue;
        hoist_point: Vp_Rec = NONE;   // end()
        for u: vv(v).users {
            if vp_uses_scalars(u, v) continue;
            if vr(u).parent == vph hoist_point = vb(vph).first;
        }
        b := vpb_at(vph, hoist_point);
        bc := vpb_nary(*b, VPI_BROADCAST, .[v]);
        Ctx :: struct { v: Vp_Val; bc: Vp_Rec; }
        ctx := Ctx.{v, bc};
        pred :: (u: Vp_Rec, idx: s64, data: *void) -> bool { c := cast(*Ctx) data; return c.bc != u && !vp_uses_scalars(u, c.v); }
        vp_replace_uses_with_if(v, vr(bc).def, pred, *ctx);
    }
}

// VPlanTransforms::materializeConstantVectorTripCount
vp_materialize_constant_vector_trip_count :: (vf: Ec, uf: u32, pse: *Pse) {
    tc := vpl.trip_count;
    if vp_num_users(tc) == 0 return;
    if vp_has_tail_folded() || !vp_has_scalar_tail() || vp_single_succ(vp_middle_block()) == vp_scalar_preheader() || !vp_is_ir_value(tc) return;
    tcs := sc_get_scev(vp_ir(tc));
    if !sc_is_const(tcs) return;
    vfxuf := sc_get_element_count(sc_type(tcs), vf.n * uf, vf.scalable, 0);
    vtc := sc_get_mul2(sc_get_udiv(tcs, vfxuf), vfxuf);
    if sc_is_const(vtc) vp_set_underlying(vpl.vector_trip_count, sc_value(vtc));
}

// isConditionTrueViaVFAndUF
vp_is_condition_true_via_vf_and_uf :: (cond: Vp_Val, vf: Ec, uf: u32, pse: *Pse) -> bool {
    ok, a, b := vpm_binary(cond, vp_opc(.OR));
    r := vp_def(cond);
    if ok && r != NONE && vr(r).kind != .WIDEN_CAST {   // m_BinaryOr
        for vr(r).ops if vp_is_condition_true_via_vf_and_uf(it, vf, uf, pse) return true;
        return false;
    }
    can_iv := vb(vp_vector_loop_region()).can_iv;
    okc, l, rr := vpm_cmp(cond);
    if !okc || vr(vp_def(cond)).flags.pred != ICMP_EQ || vpm_opcode_is_fcmp(vp_def(cond)) return false;
    if rr != vpl.vector_trip_count return false;
    oka, x := vpm_c_binary_with(l, vp_opc(.ADD), can_iv);
    if !oka || x != vpl.vfxuf return false;
    vtc := vp_scev_for_value(vpl.vector_trip_count, pse);
    if sc_is_cnc(vtc) vtc = vp_scev_for_value(vpl.trip_count, pse);
    c := sc_get_element_count(sc_type(vtc), vf.n * uf, vf.scalable, 0);
    return sc_is_known_predicate(ICMP_EQ, vtc, c);
}
vpm_opcode_is_fcmp :: (r: Vp_Rec) -> bool { ok, o := vpm_opcode(r); return ok && o == vp_opc(.FCMP); }

// simplifyBranchConditionForVFAndUF
vp_simplify_branch_condition_for_vf_and_uf :: (vf: Ec, uf: u32, pse: *Pse) -> bool {
    region := vp_vector_loop_region();
    exiting := vp_exiting_basic_block(region);
    term := vb(exiting).last;
    is_can_iv_inc :: (v: Vp_Val) -> bool { ok, _, b := vpm_binary(v, vp_opc(.ADD)); return ok && b == vpl.vfxuf; }
    okc, cnt_iv, _ := vpm_branch_on_count(term);
    matched_count := false;
    if okc {
        if is_can_iv_inc(cnt_iv) matched_count = true;
        else {
            ok, a, b := vpm_c_binary(cnt_iv, vp_opc(.ADD));
            if ok && ((is_can_iv_inc(a) && vp_is_ir_value(b)) || (is_can_iv_inc(b) && vp_is_ir_value(a))) matched_count = true;
        }
    }
    okb, cond := vpm_branch_on_cond(term);
    alm_not := false;
    if okb {
        okn, na := vpm_not(cond);
        if okn && vp_val_is_vpi(na, VPI_ACTIVE_LANE_MASK) && vp_nops(vp_def(na)) == 3 alm_not = true;
    }
    if matched_count || alm_not {
        vtc := vp_scev_for_value(vpl.vector_trip_count, pse);
        if sc_is_cnc(vtc) vtc = vp_scev_for_value(vpl.trip_count, pse);
        assert(!sc_is_cnc(vtc), "Trip count SCEV must be computable");
        c := sc_get_element_count(sc_type(vtc), vf.n * uf, vf.scalable, 0);
        if !sc_is_known_predicate(ICMP_ULE, vtc, c) return false;
    } else if okb {
        if !vp_is_condition_true_via_vf_and_uf(cond, vf, uf, pse) return false;
    } else if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) {
        if !vp_is_condition_true_via_vf_and_uf(vp_op(term, 1), vf, uf, pse) return false;
    } else return false;
    if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) { vp_set_operand(term, 1, vp_true()); return true; }
    boc := vp_new_instruction(VPI_BRANCH_ON_COND, .[vp_true()], .{}, .[], vr(term).dl);
    vp_append_recipe(exiting, boc);
    vp_erase_recipe(term);
    return true;
}

// optimizeVectorInductionWidthForTCAndVFUF
vp_optimize_vector_induction_width_for_tc_and_vf_uf :: (vf: Ec, uf: u32) -> bool {
    region := vp_vector_loop_region();
    if region == NONE return false;
    tc := vpl.trip_count;
    if vf.scalable || !vp_is_constant_int(tc) return false;
    tcv := vp_const_int_value(tc);
    align := vf.n * uf;
    // ComputeBitWidth: max(PowerOf2Ceil((alignTo(TC, Align) - 1).getActiveBits()), 8)
    a := ap_from_u64(tcv.bits, align);
    q := ap_udiv(tcv, a);
    if !ap_is_zero(ap_urem(tcv, a)) q = ap_add(q, ap_one(tcv.bits));
    aligned := ap_mul(ap_from_u64(tcv.bits, align), q);
    maxv := ap_sub(aligned, ap_one(tcv.bits));
    ab := ap_active_bits(maxv);
    p2: u64 = 1;
    while p2 < cast(u64) ab p2 *= 2;
    if ab == 0 p2 = 0;
    nbw := max(p2, 8);
    new_ty := type_int(cast(u32) nbw);
    changed := false;
    for phi: vp_block_phis(vp_entry_basic_block(region)) {
        if !vp_is_canonical_widen_iv(phi) continue;
        d := vr(phi).def;
        if vp_has_more_than_one_unique_user(d) || new_ty == vp_scalar_type(d) continue;
        su := vp_single_user(d);
        if su == NONE continue;
        okc, l, rr := vpm_cmp(vr(su).def);
        if !okc || vpm_opcode_is_fcmp(su) || l != d continue;
        okb, bo := vpm_vpi(rr, VPI_BROADCAST, 1);
        if !okb || vpl.btc == NONE || vp_op(bo, 0) != vpl.btc continue;
        vp_unported("narrowing the canonical wide IV (optimizeVectorInductionWidthForTCAndVFUF, tail folding)");
    }
    return changed;
}

// VPlanTransforms::optimizeForVFAndUF
vp_optimize_for_vf_and_uf :: (vf: Ec, uf: u32, pse: *Pse) {
    for vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) if vr(it).kind == .ACTIVE_LANE_MASK_PHI
        vp_unported("active lane masks (tryToReplaceALMWithWideALM)");
    changed := vp_simplify_branch_condition_for_vf_and_uf(vf, uf, pse);
    changed |= vp_optimize_vector_induction_width_for_tc_and_vf_uf(vf, uf);
    if changed vp_set_vf(vf);
}

// ---------------------------------------------------------------- convertToConcreteRecipes

// VPBuilder::createWidenPhi
vpb_widen_phi :: (b: *Vp_Builder, incoming: [] Vp_Val, dl: Md_Id, name: string) -> Vp_Rec {
    r := vp_new_single_def(.WIDEN_PHI, incoming, vp_scalar_type(incoming[0]), NONE, dl);
    vr(r).name = name;
    return vpb_insert(b, r);
}

// expandVPWidenIntOrFpInduction
vp_expand_widen_int_or_fp_induction :: (w: Vp_Rec) {
    start := vp_op(w, 0); step := vp_op(w, 1); vfv := vp_op(w, 2);
    dl := vr(w).dl;
    ty := vp_scalar_type(vr(w).def);
    id := *vpl.inds[vr(w).ind];
    add_op: Opcode; mul_op: Opcode;
    flags := vr(w).flags;
    if id.kind == .INT { add_op = .ADD; mul_op = .MUL; }
    else { _, o := ind_opcode(id); add_op = o; mul_op = .FMUL; }
    b := vpb_at_end(vp_vector_preheader());
    step_ty := vp_scalar_type(step);
    if type_bits(scalar_type(ty)) < type_bits(scalar_type(step_ty)) {
        step = vr(vpb_scalar_cast(*b, .TRUNC, step, ty, dl)).def;
        start = vr(vpb_scalar_cast(*b, .TRUNC, start, ty, dl)).def;
        step_ty = ty;
    }
    iv_int_ty := type_int(type_bits(scalar_type(step_ty)));
    init := vr(vpb_nary(*b, VPI_STEP_VECTOR, .[], .{}, .[], NONE, "", iv_int_ty)).def;
    if is_fp_type(step_ty) init = vr(vpb_widen_cast(*b, .UITOFP, init, step_ty)).def;
    splat_start := vr(vpb_nary(*b, VPI_BROADCAST, .[start])).def;
    splat_step := vr(vpb_nary(*b, VPI_BROADCAST, .[step])).def;
    init = vr(vpb_nary(*b, vp_opc(mul_op), .[init, splat_step], flags)).def;
    init = vr(vpb_nary(*b, vp_opc(add_op), .[splat_start, init], flags, .[], NONE, "induction")).def;
    pb := vpb_before(w);
    wide_phi := vpb_widen_phi(*pb, .[init], dl, "vec.ind");
    inc: Vp_Val; prev: Vp_Val;
    if vp_nops(w) == 5 {
        inc = vp_op(w, 3);
        prev = vp_op(w, 4);
    } else {
        vr_ := vp_def(vfv);
        if vr_ != NONE && vp_enclosing_loop_region(vr(vr_).parent) != NONE b = vpb_after(vr_);
        vf2: Vp_Val;
        if is_fp_type(step_ty) vf2 = vr(vpb_scalar_cast(*b, .UITOFP, vfv, step_ty, dl)).def;
        else vf2 = vpb_scalar_zext_or_trunc(*b, vfv, step_ty, vp_scalar_type(vfv), dl);
        inc = vr(vpb_nary(*b, vp_opc(mul_op), .[step, vf2], flags)).def;
        inc = vr(vpb_nary(*b, VPI_BROADCAST, .[inc])).def;
        prev = vr(wide_phi).def;
    }
    exiting := vp_exiting_basic_block(vp_vector_loop_region());
    eb := vpb_before(vp_terminator(exiting));
    nxt := vpb_nary(*eb, vp_opc(add_op), .[prev, inc], flags, .[], dl, "vec.ind.next");
    vp_add_operand(wide_phi, vr(nxt).def);
    vp_rauw(vr(w).def, vr(wide_phi).def);
}

// expandVPWidenPointerInduction
vp_expand_widen_pointer_induction :: (w: Vp_Rec) {
    start := vp_op(w, 0); step := vp_op(w, 1); vfv := vp_op(w, 2);
    dl := vr(w).dl;
    b := vpb_before(w);
    ptr_phi := vpb_scalar_phi(*b, .[start], dl, "pointer.phi");
    bb := vr(w).parent;
    b = vpb_at(bb, vp_first_non_phi(bb));
    step_ty := vp_scalar_type(step);
    off := vr(vpb_nary(*b, VPI_STEP_VECTOR, .[], .{}, .[], NONE, "", step_ty)).def;
    off = vr(vpb_overflowing(*b, .MUL, .[off, step], false, false)).def;
    ptr_add := vpb_wide_ptr_add(*b, vr(ptr_phi).def, off, dl, "vector.gep");
    vp_rauw(vr(w).def, vr(ptr_add).def);
    exiting := vp_exiting_basic_block(vp_vector_loop_region());
    eb := vpb_before(vp_terminator(exiting));
    vf2 := vpb_scalar_zext_or_trunc(*eb, vfv, step_ty, vp_scalar_type(vfv), dl);
    inc := vpb_overflowing(*eb, .MUL, .[step, vf2], false, false);
    ind_gep := vpb_ptr_add(*eb, vr(ptr_phi).def, vr(inc).def, dl, "ptr.ind");
    vp_add_operand(ptr_phi, vr(ind_gep).def);
}

// expandVPDerivedIV
vp_expand_derived_iv :: (r: Vp_Rec) {
    b := vpb_before(r);
    start := vp_op(r, 0); index := vp_op(r, 1); step := vp_op(r, 2);
    step_ty := vp_scalar_type(step);
    index_ty := vp_scalar_type(index);
    if type_kind(scalar_type(step_ty)) == .INT index = vpb_scalar_sext_or_trunc(*b, index, step_ty, index_ty, NONE);
    else index = vr(vpb_scalar_cast(*b, .SITOFP, index, step_ty, NONE)).def;
    d := vr(r).def;
    if vr(r).ind_kind == {
        case .INT;
            m := vpb_overflowing(*b, .MUL, .[index, step], false, false);
            vp_rauw(d, vr(vpb_add(*b, start, vr(m).def)).def);
        case .PTR;
            m := vpb_overflowing(*b, .MUL, .[index, step], false, false);
            vp_rauw(d, vr(vpb_ptr_add(*b, start, vr(m).def)).def);
        case .FP;
            fpb := vr(r).fp_binop;
            fmf := inst_fmf(fpb);
            fm := vpb_nary(*b, vp_opc(.FMUL), .[step, index], vpf_fmf(fmf));
            vp_rauw(d, vr(vpb_nary(*b, vp_opc(inst_op(fpb)), .[start, vr(fm).def], vpf_fmf(fmf))).def);
        case;
            return;
    }
}

// VPlanTransforms::convertToConcreteRecipes
vp_convert_to_concrete_recipes :: () {
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) {
        for r: vp_block_recipes(bb) {
            if vr(r).dead continue;
            b := vpb_before(r);
            k := vr(r).kind;
            if k == .WIDEN_INT_OR_FP_INDUCTION { vp_expand_widen_int_or_fp_induction(r); vp_erase_recipe(r); continue; }
            if k == .WIDEN_POINTER_INDUCTION {
                if vp_ptr_iv_only_scalars_generated(r) vp_unported("scalarizeVPWidenPointerInduction");
                vp_expand_widen_pointer_induction(r);
                vp_erase_recipe(r);
                continue;
            }
            if k == .DERIVED_IV { vp_expand_derived_iv(r); vp_erase_recipe(r); continue; }
            if k == .WIDEN_CANONICAL_IV {
                can_iv := vp_op(r, 0);
                can_ty := vp_scalar_type(can_iv);
                step := ifx vp_nops(r) == 2 then vp_op(r, 1) else NONE;
                if step == NONE step = vp_zero(can_ty);
                civ := vr(vpb_nary(*b, VPI_BROADCAST, .[can_iv])).def;
                step = vr(vpb_nary(*b, VPI_BROADCAST, .[step])).def;
                sv := vpb_nary(*b, VPI_STEP_VECTOR, .[], .{}, .[], NONE, "", can_ty);
                step = vr(vpb_add(*b, step, vr(sv).def)).def;
                f := vr(r).flags;
                vec := vpb_add(*b, civ, step, vr(r).dl, "vec.iv", f.nuw, f.nsw);
                vp_rauw(vr(r).def, vr(vec).def);
                vp_erase_recipe(r);
                continue;
            }
            if k == .BLEND {
                sel := vp_blend_incoming(r, 0);
                for i: 1..vp_blend_num_incoming(r)-1
                    sel = vr(vpb_select(*b, vp_blend_mask(r, i), vp_blend_incoming(r, i), sel, vr(r).dl, "predphi", vr(r).flags)).def;
                vp_rauw(vr(r).def, sel);
                vp_erase_recipe(r);
                continue;
            }
            if k == .VECTOR_END_POINTER { vp_unported("VPVectorEndPointerRecipe::materializeOffset"); continue; }
            if k == .EXPRESSION { vp_unported("VPExpressionRecipe::decompose"); continue; }
            if vp_is_vpi(r, VPI_LAST_ACTIVE_LANE) { vp_unported("expanding LastActiveLane"); continue; }
            if vp_is_vpi(r, VPI_MASKED_COND) {
                vp_unported("lowering masked MaskedCond");
                continue;
            }
            if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) {
                f := vr(r).flags;
                add := vpb_overflowing(*b, .ADD, vp_ops(r), f.nuw, f.nsw, vr(r).dl);
                vp_rauw(vr(r).def, vr(add).def);
                vp_erase_recipe(r);
                continue;
            }
            okc, iv, tc := vpm_branch_on_count(r);
            if okc {
                dl := vr(r).dl;
                cond := vpb_icmp(*b, ICMP_EQ, iv, tc, dl);
                vpb_nary(*b, VPI_BRANCH_ON_COND, .[vr(cond).def], .{}, .[], dl);
                vp_erase_recipe(r);
                continue;
            }
            if !vpm_vpi_r(r, VPI_WIDE_IV_STEP, 2) continue;
            vector_step := vp_op(r, 0); scalar_step := vp_op(r, 1);
            ivty := vp_scalar_type(vr(r).def);
            if vp_scalar_type(vector_step) != ivty {
                co := ifx is_fp_type(ivty) then Opcode.UITOFP else .TRUNC;
                vector_step = vr(vpb_widen_cast(*b, co, vector_step, ivty)).def;
            }
            if vp_scalar_type(scalar_step) != ivty scalar_step = vr(vpb_widen_cast(*b, .TRUNC, scalar_step, ivty)).def;
            flags: Vp_Flags; mul_opc: Opcode;
            if is_fp_type(ivty) { mul_opc = .FMUL; flags = vpf_fmf(vp_fmf_or_none(r)); }
            else { mul_opc = .MUL; flags = vp_default_flags(vp_opc(.MUL)); }
            mul := vpb_nary(*b, vp_opc(mul_opc), .[vector_step, scalar_step], flags, .[], vr(r).dl);
            vp_rauw(vr(r).def, vr(mul).def);
            vp_erase_recipe(r);
        }
    }
}

// ---------------------------------------------------------------- dissolving regions

// VPRegionBlock::getOrCreateCanonicalIVIncrement
vp_region_get_or_create_can_iv_increment :: (region: Vp_Blk) -> Vp_Rec {
    inc := vp_find_canonical_iv_increment();
    if inc != NONE return inc;
    assert(!vv(vpl.vfxuf).materialized, "VFxUF can be used only before it is materialized.");
    exiting := vb(region).exiting;
    can_iv := vb(region).can_iv;
    b := vpb_before(vp_terminator(exiting));
    return vpb_overflowing(*b, .ADD, .[can_iv, vpl.vfxuf], vb(region).can_iv_nuw, false, vv(can_iv).dl, "index.next");
}

// VPRegionBlock::dissolveToCFGLoop
vp_dissolve_to_cfg_loop :: (region: Vp_Blk) {
    header := vb(region).entry;
    latch := vb(region).exiting;
    can_iv := vb(region).can_iv;
    if vp_num_users(can_iv) {
        zero := vp_zero(vv(can_iv).ty);
        dl := vv(can_iv).dl;
        inc := vp_region_get_or_create_can_iv_increment(region);
        hb := vpb_at(header, vb(header).first);
        scalar := vpb_scalar_phi(*hb, .[zero, vr(inc).def], dl, "index");
        vp_rauw(can_iv, vr(scalar).def);
    }
    ph := vp_single_pred(region);
    vpbu_disconnect(ph, region);
    for vp_depth_first_shallow(vb(region).entry) vb(it).parent = vb(region).parent;
    vpbu_connect(ph, header);
    vpbu_transfer_successors(region, latch);
    vpbu_connect(latch, header);
    vb(region).dead = true;
}

// VPlanTransforms::dissolveLoopRegions
vp_dissolve_loop_regions :: () {
    regions: [..] Vp_Blk; regions.allocator = temp;
    for r: vp_blocks_only_region(vp_depth_first_deep(vpl.entry)) if !vp_is_replicator(r) array_add(*regions, r);
    for regions vp_dissolve_to_cfg_loop(it);
}

// VPlanTransforms::expandBranchOnTwoConds
vp_expand_branch_on_two_conds :: () {
    wl: [..] Vp_Rec; wl.allocator = temp;
    for bb: vp_depth_first_shallow(vpl.entry) {
        if !vp_is_basic(bb) || vp_block_empty(bb) continue;
        if vpm_vpi_r(vb(bb).last, VPI_BRANCH_ON_TWO_CONDS, 2) array_add(*wl, vb(bb).last);
    }
    for br: wl {
        dl := vr(br).dl;
        bb := vr(br).parent;
        succs: [..] Vp_Blk; succs.allocator = temp;
        for vb(bb).succs array_add(*succs, it);
        assert(succs.count == 3, "BranchOnTwoConds must have exactly 3 successors");
        for s: succs vpbu_disconnect(bb, s);
        c0 := vp_op(br, 0); c1 := vp_op(br, 1);
        if succs[0] == succs[1] {
            b := vpb_before(br);
            comb := vpb_or(*b, c0, c1, dl);
            vpb_nary(*b, VPI_BRANCH_ON_COND, .[vr(comb).def], .{}, .[], dl);
            vpbu_connect(bb, succs[0]);
            vpbu_connect(bb, succs[2]);
            vp_erase_recipe(br);
            continue;
        }
        interim := vp_create_basic_block(tconcat(vb(bb).name, ".interim"));
        b := vpb_at_end(bb);
        vpb_nary(*b, VPI_BRANCH_ON_COND, .[c0], .{}, .[], dl);
        vpbu_connect(bb, succs[0]);
        vpbu_connect(bb, interim);
        ib := vpb_at_end(interim);
        vpb_nary(*ib, VPI_BRANCH_ON_COND, .[c1], .{}, .[], dl);
        vpbu_connect(interim, succs[1]);
        vpbu_connect(interim, succs[2]);
        vp_erase_recipe(br);
    }
}

// ---------------------------------------------------------------- materialization

// VPlanTransforms::materializeBackedgeTakenCount
vp_materialize_backedge_taken_count :: (vector_ph: Vp_Blk) {
    btc := vp_or_create_backedge_taken_count();
    if vp_num_users(btc) == 0 return;
    b := vpb_at(vector_ph, vb(vector_ph).first);
    tcty := vp_scalar_type(vpl.trip_count);
    tcmo := vpb_sub(*b, vpl.trip_count, vp_const_int(tcty, 1), NONE, "trip.count.minus.1");
    vp_rauw(btc, vr(tcmo).def);
}

// VPlanTransforms::materializeVectorTripCount
vp_materialize_vector_trip_count :: (vector_ph: Vp_Blk, tail_by_masking: bool, requires_scalar_epilogue: bool, step: Vp_Val,
                                     has_max_runtime_step: bool, max_runtime_step: u64) {
    vtc := vpl.vector_trip_count;
    if vp_num_users(vtc) == 0 || vv(vtc).uv != NONE return;
    tc := vpl.trip_count;
    tcty := vp_scalar_type(tc);
    ip := vb(vector_ph).first;
    sr := vp_def(step);
    if sr != NONE ip = vr(sr).next;
    b := vpb_at(vector_ph, ip);
    if !requires_scalar_epilogue && vp_is_constant_int(tc) && has_max_runtime_step {
        if ap_is_zero(ap_urem(vp_const_int_value(tc), ap_from_u64(vp_const_int_value(tc).bits, max_runtime_step))) {
            vp_rauw(vtc, tc);
            return;
        }
    }
    if tail_by_masking {
        s1 := vpb_sub(*b, step, vp_const_int(tcty, 1));
        tc = vr(vpb_add(*b, tc, vr(s1).def, NONE, "n.rnd.up")).def;
    }
    r := vr(vpb_nary(*b, vp_opc(.UREM), .[tc, step], .{}, .[], NONE, "n.mod.vf")).def;
    if requires_scalar_epilogue {
        assert(!tail_by_masking, "requiring scalar epilogue is not supported with fail folding");
        is_zero := vpb_icmp(*b, ICMP_EQ, r, vp_zero(tcty));
        r = vr(vpb_select(*b, vr(is_zero).def, step, r)).def;
    }
    res := vpb_sub(*b, tc, r, NONE, "n.vec");
    vp_rauw(vtc, vr(res).def);
}

// VPBuilder::createElementCount (fixed VFs)
vpb_element_count :: (b: *Vp_Builder, ty: Type_Id, ec: Ec) -> Vp_Val {
    if ec.scalable vp_unported("scalable element counts (createVScale)");
    return vp_const_int(ty, ec.n);
}

// VPlanTransforms::materializeFactors
vp_materialize_factors :: (vector_ph: Vp_Blk, vfec: Ec) {
    if vv(vpl.vf).materialized return;
    b := vpb_at(vector_ph, vb(vector_ph).first);
    tcty := vp_scalar_type(vpl.trip_count);
    uf := vpl.ufs[0];
    if vp_num_users(vpl.vf) == 0 {
        rt := vpb_element_count(*b, tcty, Ec.{vfec.n * uf, vfec.scalable});
        vp_rauw(vpl.vfxuf, rt);
        return;
    }
    rvf := vpb_element_count(*b, tcty, vfec);
    if !vp_only_scalar_values_used(vpl.vf) {
        bc := vpb_nary(*b, VPI_BROADCAST, .[rvf]);
        scalars :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return !vp_uses_scalars(u, vpl.vf); }
        vp_replace_uses_with_if(vpl.vf, vr(bc).def, scalars, null);
    }
    vp_rauw(vpl.vf, rvf);
    mul := vpb_overflowing(*b, .MUL, .[rvf, vp_const_int(tcty, uf)], true, false);
    vp_rauw(vpl.vfxuf, vr(mul).def);
}

// VPlanTransforms::expandSCEVsToVPInstructions
vp_expand_scevs_to_vp_instructions :: () {
    entry := vpl.entry;
    b := vpb_at(entry, vb(entry).first);
    x: Vp_Scev_Expander; x.b = *b; x.dl = inst_dl(block_terminator(vb(entry).irbb));
    for r: vp_block_recipes(entry) {
        if vr(r).kind != .EXPAND_SCEV || vp_num_users(vr(r).def) == 0 continue;
        b = vpb_before(r);
        e := vpsx_try_to_expand(*x, vr(r).expr);
        if e == NONE continue;
        vp_rauw(vr(r).def, e);
        if vpl.trip_count == vr(r).def vpl.trip_count = vp_poison(vp_scalar_type(vr(r).def));
        vp_erase_recipe(r);
    }
}

// ---------------------------------------------------------------- cse

vp_cse_gep_source_element_type :: (r: Vp_Rec) -> Type_Id {
    k := vr(r).kind;
    if k == .REPLICATE { ui := vp_underlying_instr(r); if inst_op(ui) == .GEP return gep_source_type(ui); return NONE; }
    if k == .VECTOR_POINTER || k == .WIDEN_GEP return vr(r).src_elt_ty;
    return NONE;
}
// VPCSEDenseMapInfo::canHandle
vp_cse_can_handle :: (r: Vp_Rec) -> bool {
    has, is_iid, oc := vp_opcode_or_intrinsic_id(r);
    if !has return false;
    if !is_iid && (oc == cast(u32) Opcode.INSERTVALUE || oc == cast(u32) Opcode.EXTRACTVALUE || oc == cast(u32) Opcode.ALLOCA) return false;
    return !vp_may_read_or_write_memory(r);
}
vp_has_predicate :: (r: Vp_Rec) -> bool { o := vr(r).flags.optype; return o == .CMP || o == .FCMP; }
// VPCSEDenseMapInfo::isEqual
vp_cse_is_equal :: (l: Vp_Rec, r: Vp_Rec) -> bool {
    if vr(l).kind != vr(r).kind return false;
    h1, i1, o1 := vp_opcode_or_intrinsic_id(l);
    h2, i2, o2 := vp_opcode_or_intrinsic_id(r);
    if h1 != h2 || i1 != i2 || o1 != o2 return false;
    if vp_cse_gep_source_element_type(l) != vp_cse_gep_source_element_type(r) return false;
    if vp_is_single_scalar(vr(l).def) != vp_is_single_scalar(vr(r).def) return false;
    if vp_nops(l) != vp_nops(r) return false;
    for vr(l).ops if it != vp_op(r, it_index) return false;
    if vp_is_with_ir_flags_kind(vr(l).kind) && vp_has_predicate(l) && vr(l).flags.pred != vr(r).flags.pred return false;
    if vr(l).kind == .SCALAR_IV_STEPS && vr(l).ind_opcode != vr(r).ind_opcode return false;
    if vr(l).kind == .WIDEN_PHI && vr(l).parent != vr(r).parent return false;
    rl := vp_recipe_region(l); rr := vp_recipe_region(r);
    if ((rl != NONE && vp_is_replicator(rl)) || (rr != NONE && vp_is_replicator(rr))) && vr(l).parent != vr(r).parent return false;
    return vp_scalar_type(vr(l).def) == vp_scalar_type(vr(r).def);
}
// VPIRFlags::intersectFlags
vp_intersect_flags :: (a: *Vp_Flags, b: Vp_Flags) {
    if a.optype == {
        case .OVERFLOWING_BINOP; #through; case .TRUNC; a.nuw &= b.nuw; a.nsw &= b.nsw;
        case .DISJOINT_OP; a.disjoint &= b.disjoint;
        case .POSSIBLY_EXACT_OP; a.exact &= b.exact;
        case .GEP_OP; a.gep &= b.gep;
        case .FP_MATH_OP; #through; case .FCMP; a.fmf &= b.fmf;
        case .NON_NEG_OP; a.nneg &= b.nneg;
        case .REDUCTION_OP; a.fmf &= b.fmf;
    }
}
// VPlanTransforms::cse (the DenseMap lookup finds the first inserted equal recipe; equality is all that matters)
vp_cse :: () {
    dt := vp_dt_build();
    buckets: Table(u64, [..] Vp_Rec); buckets.allocator = temp;
    for bb: vp_blocks_only_basic(vp_rpo(vpl.entry, true)) {
        r := vb(bb).first;
        while r != NONE {
            defer r = vr(r).next;
            if !vp_is_single_def_kind(vr(r).kind) || !vp_cse_can_handle(r) continue;
            key: u64 = cast(u64) vr(r).kind * 1000003 + cast(u64) vp_nops(r);
            for vr(r).ops key = key * 31 + cast(u64) it;
            lst := table_find_pointer(*buckets, key);
            found: Vp_Rec = NONE;
            if lst for c: lst.* if vp_cse_is_equal(c, r) { found = c; break; }
            if found != NONE {
                if !vp_dt_dominates(*dt, vr(found).parent, bb) continue;
                if vp_is_with_ir_flags_kind(vr(found).kind) vp_intersect_flags(*vr(found).flags, vr(r).flags);
                vp_rauw(vr(r).def, vr(found).def);
                continue;
            }
            if !lst { e: [..] Vp_Rec; e.allocator = temp; table_set(*buckets, key, e); lst = table_find_pointer(*buckets, key); }
            array_add(lst, r);
        }
    }
}

// VPlanTransforms::expandSCEVs: the remaining VPExpandSCEVRecipes become IR in the entry block (SCEVExpander with
// name "induction"), and IR instructions added to the entry block get VPIRInstructions.
vp_expand_scevs :: (entry_irbb: Value_Id) {
    x: Scev_Expander;
    sx_init(*x, "induction", false);
    entry := vpl.entry;
    for r: vp_block_recipes(entry) {
        if vr(r).kind != .EXPAND_SCEV continue;
        e := vr(r).expr;
        res := sx_expand_code_for_at(*x, e, sc_type(e), block_terminator(entry_irbb));
        exp := vp_live_in(res);
        vp_rauw(vr(r).def, exp);
        if vpl.trip_count == vr(r).def vpl.trip_count = exp;
        vp_erase_recipe(r);
    }
    ei := vb(entry).first;
    t := block_terminator(entry_irbb);
    for i: block_insts(entry_irbb) {
        if i == t break;
        if ei != NONE && vr(ei).kind == .IR_INSTRUCTION && vr(ei).ir_inst == i { ei = vr(ei).next; continue; }
        n := vp_new_ir_instruction(i);
        vp_insert_recipe(n, entry, ei);
    }
}
