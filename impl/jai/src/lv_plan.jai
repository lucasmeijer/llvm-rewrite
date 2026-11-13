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
    profitable_vfs: [..] Lv_Vf;               // ProfitableVFs
}

// VPlanTransforms::replaceSymbolicStrides
vp_replace_symbolic_strides :: (pse: *Pse, strides: *Table(Value_Id, Scev_Id), dt: *Vp_Dom_Tree) {
    if strides.count == 0 return;
    preheader := vb(vpl.entry).succs[1];
    Ctx :: struct { dt: *Vp_Dom_Tree; ph: Vp_Blk; }
    ctx := Ctx.{dt, preheader};
    can_use :: (u: Vp_Rec, idx: s64, data: *void) -> bool { c := cast(*Ctx) data; return vp_dt_dominates(c.dt, c.ph, vr(u).parent); }
    rewrite_map: Table(Value_Id, Scev_Id); rewrite_map.allocator = temp;
    for stride: strides.* {
        stride_v := sc_value(stride);
        ps := pse_get_scev(pse, stride_v);
        if !sc_is_const(ps) continue;
        c := const_ap(sc_value(ps));
        ci := vp_const_int_ap(c);
        sv := vp_get_live_in(stride_v);
        if sv != NONE vp_replace_uses_with_if(sv, ci, can_use, *ctx);
        use := ir.v_first_use[stride_v];
        while use != NONE {
            u := ir.u_user[use];
            use = ir.u_next[use];
            if !is_inst(u) continue;
            o := inst_op(u);
            if o != .SEXT && o != .ZEXT continue;
            uv := vp_get_live_in(u);
            if uv == NONE continue;
            bw := type_bits(scalar_type(vtype(u)));
            cc := vp_const_int_ap(ifx o == .SEXT then ap_sext(c, bw) else ap_zext(c, bw));
            vp_replace_uses_with_if(uv, cc, can_use, *ctx);
        }
        table_set(*rewrite_map, stride_v, ps);
    }
    rw: Sc_Rewriter;
    sc_rewriter_init(*rw, .PARAMETER);
    rw.param_map = *rewrite_map;
    for r: vp_block_recipes(vpl.entry) {
        if vr(r).kind != .EXPAND_SCEV continue;
        e := vr(r).expr;
        ns := sc_rewrite(*rw, e);
        if ns == e continue;
        nv := vp_get_or_create_vp_value_for_scev_expr(ns);
        vp_rauw(vr(r).def, nv);
        if vpl.trip_count == vr(r).def vpl.trip_count = nv;
    }
}
// vputils::getOrCreateVPValueForSCEVExpr
vp_get_or_create_vp_value_for_scev_expr :: (e: Scev_Id) -> Vp_Val {
    if sc_is_const(e) return vp_live_in(sc_value(e));
    if sc_kind(e) == .UNKNOWN && !is_inst(sc_value(e)) return vp_live_in(sc_value(e));
    x := vp_new_expand_scev(e);
    entry := vpl.entry;
    it := vp_first_non_phi(entry);
    while it != NONE && vr(it).kind == .IR_INSTRUCTION it = vr(it).next;
    vp_insert_recipe(x, entry, it);
    return vr(x).def;
}

// LoopVectorizationPlanner::tryToBuildVPlan1
lvp_try_to_build_vplan1 :: (lp: *Lv_Planner) -> *Vp_Plan {
    lvl := lp.lvl;
    laa := lvl.laa;
    // loop versioning (noalias metadata) only for inner loops: outer loops have no LoopAccessInfo
    lver: *Lv_Noalias = null;
    if laa {
        lver = New(Lv_Noalias,, allocator = temp);
        if laa.rt.checks.count && !laa.rt.can_use_diff_check lv_prepare_no_alias_metadata(lver, *laa.rt);
    }
    plan := vp_build_vplan0(lp.li, lp.l, lvl.widest_ind_ty, lp.pse, lver);
    dt := vp_dt_build();
    if laa vp_replace_symbolic_strides(lp.pse, *laa.symbolic_strides, *dt);
    vp_simplify_recipes();
    vp_remove_dead_recipes();
    if !vp_create_header_phi_recipes(lp.pse, lp.li, lp.l, *dt, lvl, lp.in_loop_reductions, lvh_allow_reordering(lp.hints)) return null;
    if laa vp_replace_symbolic_strides(lp.pse, *laa.symbolic_strides, *dt);
    force := lvh_force(lp.hints) == FK_ENABLED;
    opt_for_size := !force && (lp.cm.sel == .NOT_ALLOWED_OPT_SIZE || lp.cm.sel == .NOT_ALLOWED_LOW_TRIP_LOOP);
    threshold := ifx force then lv_opts.pragma_scev_check_threshold else lv_opts.scev_check_threshold;
    if !vp_finalize_scev_predicates(lp.pse, opt_for_size, threshold) return null;
    vp_add_middle_check();
    if !vp_handle_early_exits(lvl.uncountable_exit, lvl, lp.pse) return null;
    pi := lvl.primary_induction;
    vp_create_loop_regions(lv_debug_loc_from_inst_or_operands(pi));
    if lv_cm_fold_tail_by_masking(lp.cm) vp_fold_tail_by_masking();
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
    if reverse {
        rflags := ifx vp_has_tail_folded() then cast(u32) 0 else flags & ~cast(u32) F_GEP_NUW;
        r := vp_new_single_def(.VECTOR_END_POINTER, .[ptr, vpl.vf], vp_scalar_type(ptr), NONE, dl);
        vr(r).src_elt_ty = src_elt_ty; vr(r).stride = -1; vr(r).flags = vpf_gep(rflags);
        return vpb_insert(b, r);
    }
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
    // for scalable VFs, assume / lifetime intrinsics with variant operands still only get lane 0
    if !is_uniform && range.start.scalable && call_iid(i) != NOT_INTRINSIC {
        id := call_iid(i);
        if id == IID_ASSUME || id == IID_LIFETIME_START || id == IID_LIFETIME_END is_uniform = true;
    }
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
    bb := vpb_before(vpi);
    if reverse && mask != NONE mask = vr(vpb_nary(*bb, VPI_REVERSE, .[mask], .{}, .[], inst_dl(i))).def;
    if is_load {
        ld := vp_new_widen_load(i, ptr, mask, consecutive, vr(vpi).md, inst_dl(i));
        if reverse {
            vpb_insert(*bb, ld);
            return vp_new_instruction(VPI_REVERSE, .[vr(ld).def], .{}, .[], vr(ld).dl);
        }
        return ld;
    }
    stored := vp_op(vpi, 0);
    if reverse stored = vr(vpb_nary(*bb, VPI_REVERSE, .[stored], .{}, .[], inst_dl(i))).def;
    return vp_new_widen_store(i, ptr, stored, mask, consecutive, vr(vpi).md, inst_dl(i));
}
// VPRecipeBuilder::tryToCreateWidenNonPhiRecipe
lvp_try_to_create_widen_non_phi_recipe :: (lp: *Lv_Planner, r: Vp_Rec, range: *Vf_Range) -> Vp_Rec {
    o := vr(r).opcode;
    if o == vp_opc(.TRUNC) {
        i := vp_underlying_instr(r);
        ctx := Lvp_Vf_Ctx.{lp, i};
        opt :: (vf: Ec, d: *void) -> bool { c := cast(*Lvp_Vf_Ctx) d; return lv_cm_is_optimizable_iv_truncate(c.lp.cm, c.i, vf); }
        if lvp_decision_and_clamp_range(range, opt, *ctx) {
            // tryToOptimizeInductionTruncate
            wiv := vp_def(vp_op(r, 0));
            assert(vr(wiv).kind == .WIDEN_INT_OR_FP_INDUCTION, "expected a widened induction");
            d := *vpl.inds[vr(wiv).ind];
            step := vp_get_or_create_value_for_scev(d.step);
            return vp_new_widen_int_or_fp_induction(vp_uv(vr(wiv).def), vp_op(wiv, 0), step, vpl.vf, vr(wiv).ind, vpf_wrap(false, false), vr(r).dl, i);
        }
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
        if lv_cm_is_predicated_inst(lp.cm, instr) {
            name: string;
            if io == {
                case .UDIV; name = "llvm.masked.udiv"; case .SDIV; name = "llvm.masked.sdiv";
                case .UREM; name = "llvm.masked.urem"; case .SREM; name = "llvm.masked.srem";
            }
            return vp_new_widen_intrinsic_no_call(iidn(name), vr(r).ops, vtype(instr), .{}, .[], vr(r).dl);
        }
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
    middle := vp_middle_block();
    frs := vpb_at(middle, vp_first_non_phi(middle));   // FinalRedStoresBuilder
    for vpi: mem_ops {
        // replaceWithFinalIfReductionStore
        si := vp_underlying_instr(vpi);
        if vr(vpi).opcode == vp_opc(.STORE) && lvl_is_invariant_address_of_reduction(lp.lvl, op(si, 1)) {
            if lvl_is_invariant_store_of_reduction(lp.lvl, si) {
                val := vp_op(vpi, 0); addr := vp_op(vpi, 1);
                for u: vv(val).users if vr(u).kind == .BLEND { val = vr(u).def; break; }
                rep := vp_new_replicate(si, .[val, addr], true, NONE, vr(vpi).flags, vr(vpi).md, vr(vpi).dl);
                vpb_insert(*frs, rep);
            }
            vp_erase_recipe(vpi);
            continue;
        }
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
    if !lv_tti_prefers_vectorized_addressing(lp.cm.tti) {
        // makeVPlanMemOpDecision: scalarize unpredicated loads used as addresses
        rem: [..] Vp_Rec; rem.allocator = temp;
        for vpi: mem_ops {
            i := vp_underlying_instr(vpi);
            if lv_cm_is_predicated_inst(lp.cm, i) || vr(vpi).opcode != vp_opc(.LOAD) || !vp_is_used_by_load_store_address(vr(vpi).def) {
                array_add(*rem, vpi);
                continue;
            }
            ptr := vp_op(vpi, 0);
            ps := vp_scev_for_value(ptr, lp.pse, lp.l);
            single := !sc_is_cnc(ps) && sc_is_loop_invariant(ps, lp.l);
            replace_with(vpi, vp_new_replicate(i, .[ptr], single, NONE, vr(vpi).flags, vr(vpi).md, vr(vpi).dl));
        }
        mem_ops = rem;
    }
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

// vputils::isUsedByLoadStoreAddress
vp_is_used_by_load_store_address :: (v: Vp_Val) -> bool {
    seen: [..] Vp_Val; seen.allocator = temp;
    wl: [..] Vp_Val; wl.allocator = temp;
    array_add(*wl, v);
    is_mem_with_addr :: (u: Vp_Rec, cur: Vp_Val) -> bool {
        k := vr(u).kind;
        if k == .INTERLEAVE || k == .INTERLEAVE_EVL return vp_op(u, 0) == cur;
        ok, o := vpm_opcode(u);
        if ok && o == vp_opc(.LOAD) && vpm_arity_ok(u, 1) && vp_op(u, 0) == cur return true;
        if ok && o == vp_opc(.STORE) && vpm_arity_ok(u, 2) && vp_op(u, 1) == cur return true;
        if vp_is_widen_memory_kind(k) && vp_op(u, 0) == cur && vr(u).consecutive return true;
        return false;
    }
    while wl.count {
        cur := pop(*wl);
        if array_find(seen, cur) continue;
        array_add(*seen, cur);
        cr := vp_def(cur);
        is_blend := cr != NONE && vr(cr).kind == .BLEND;
        if is_blend {
            any := false;
            for i: 0..vp_blend_num_incoming(cr)-1 if array_find(seen, vp_blend_incoming(cr, i)) { any = true; break; }
            if !any continue;
        }
        for u: vv(cur).users if is_mem_with_addr(u, cur) return true;
        if is_blend continue;
        for u: vv(cur).users {
            if vr(u).kind == .INSTRUCTION {
                m := vp_mask_of(u);
                if m == cur {
                    used := false;
                    for k: 0..vpm_num_ops_without_mask(u)-1 if vp_op(u, k) == cur { used = true; break; }
                    if !used continue;
                }
                if vr(u).opcode == vp_opc(.LOAD) continue;
            }
            if vp_is_single_def_kind(vr(u).kind) array_add(*wl, vr(u).def);
        }
    }
    return false;
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
    // outer loops: only the basic recipe conversion and induction live-out optimization
    if vp_is_outer_loop() {
        vf := range.start;
        while vf.n < range.end.n { vp_add_vf(vf); vf.n *= 2; }
        if !vp_try_to_convert_vp_instructions_to_vp_recipes() return false;
        lvp_optimize_induction_live_out_users(lp);
        return true;
    }
    ctx := Lvp_Vf_Ctx.{lp, NONE};
    no_epi :: (vf: Ec, d: *void) -> bool { c := cast(*Lvp_Vf_Ctx) d; return !lv_cm_requires_scalar_epilogue(c.lp.cm, ec_is_vector(vf)); }
    requires_check := lvp_decision_and_clamp_range(range, no_epi, *ctx);
    middle := vp_middle_block();
    if !requires_check && vb(middle).succs.count == 2 vp_set_operand(vp_terminator(middle), 0, vp_false());
    may_overflow := false;
    vf := range.start;
    while vf.n < range.end.n { may_overflow |= !lvp_is_indvar_overflow_check_known_false(lp, vf); vf.n *= 2; }
    if may_overflow && lp.cm.tail_folding_style != .NONE {
        region := vp_vector_loop_region();
        iv_inc := vp_op(vp_terminator(vp_exiting_basic_block(region)), 0);
        vp_drop_poison_generating_flags(vp_def(iv_inc));
        vb(region).can_iv_nuw = false;
    }
    igs: [..] s32; igs.allocator = temp;
    for gid: lp.cm.iai.order {
        if !lp.cm.iai.groups[gid].alive continue;
        Ig_Ctx :: struct { cm: *Lv_Cm; ip: Value_Id; }
        ic := Ig_Ctx.{lp.cm, lp.cm.iai.groups[gid].insert_pos};
        apply :: (vf: Ec, d: *void) -> bool { c := cast(*Ig_Ctx) d; return ec_is_vector(vf) && lv_cm_widening_decision(c.cm, c.ip, vf) == .INTERLEAVE; }
        if !lvp_decision_and_clamp_range(range, apply, *ic) continue;
        array_add(*igs, gid);
    }
    vp_create_in_loop_reduction_recipes(range.start);
    lvp_make_mem_op_widening_decisions(lp, range);
    lvp_make_scalarization_decisions(range);
    lvp_make_call_widening_decisions(lp, range);
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
            if vr(recipe).kind == .WIDEN_INT_OR_FP_INDUCTION && inst_op(instr) == .TRUNC vp_insert_recipe(recipe, header, vp_first_non_phi(header));
            else vp_insert_before(recipe, r);
            if vp_num_defined_values(recipe) == 1 vp_rauw(vr(r).def, vp_defined_value(recipe, 0));
            vp_erase_recipe(r);
        }
    }
    vp_adjust_first_order_recurrence_middle_users(range);
    lvp_add_reduction_result_computation(lp, range.start);
    vp_optimize_find_iv_reductions(lp.pse, lp.l);
    lvp_optimize_induction_live_out_users(lp);
    if !vp_handle_multi_use_reductions() return false;
    // handleMultiUseReductions, handleMaxMinNumReductions, handleFindLastReductions
    if !vp_handle_max_min_num_reductions() return false;
    if !vp_handle_find_last_reductions() return false;
    vp_remove_branch_on_const(false);
    // createPartialReductions: X86 has no partial-reduction costs, so no partial reductions are formed
    if !lv_cm_fold_tail_with_evl(lp.cm) vp_convert_to_abstract_recipes(lp, range);
    vp_create_interleave_groups(igs, lp.cm.sel == .ALLOWED);
    // convertToStridedAccesses: a no-op on X86 (TTI::isLegalStridedLoadStore is false, so IsProfitable is false
    // for every VF and getDecisionAndClampRange leaves the range as it is)
    if ec_is_scalar(range.start) range.end = Ec.{range.start.n * 2, range.start.scalable};
    vf = range.start;
    while vf.n < range.end.n { vp_add_vf(vf); vf.n *= 2; }
    vpl.name = "Initial VPlan";
    vp_drop_poison_generating_recipes();
    if lv_cm_mask_partial_aliasing(lp.cm) vp_attach_alias_mask_to_header_mask();
    return true;
}
// VPlanTransforms::adjustFirstOrderRecurrenceMiddleUsers
vp_adjust_first_order_recurrence_middle_users :: (range: *Vf_Range) {
    region := vp_vector_loop_region();
    middle := vp_middle_block();
    mb := vpb_at(middle, vp_first_non_phi(middle));
    for f: vp_block_phis(vp_entry_basic_block(region)) {
        if vr(f).kind != .FIRST_ORDER_RECURRENCE_PHI continue;
        splice: Vp_Rec = NONE;
        for u: vv(vr(f).def).users if vp_is_vpi(u, VPI_FIRST_ORDER_RECURRENCE_SPLICE) { splice = u; break; }
        assert(splice != NONE, "expected FirstOrderRecurrenceSplice");
        outside := false;
        for u: vv(vr(splice).def).users if vp_recipe_region(u) == NONE { outside = true; break; }
        if outside {
            scalable_one :: (vf: Ec, d: *void) -> bool { return vf.scalable && vf.n == 1; }
            if lvp_decision_and_clamp_range(range, scalable_one, null) return;
        }
        r := vp_first_non_phi(middle);
        while r != NONE {
            nx := vr(r).next;
            defer r = nx;
            if !vpm_vpi_r(r, VPI_EXTRACT_LAST_LANE, 1) continue;
            okp, elp := vpm_vpi(vp_op(r, 0), VPI_EXTRACT_LAST_PART, 1);
            if !okp || vp_op(elp, 0) != vr(splice).def continue;
            pen := vpb_nary(*mb, VPI_EXTRACT_PENULTIMATE_ELEMENT, .[vp_op(splice, 1)], .{}, .[], NONE, "vector.recur.extract.for.phi");
            users: [..] Vp_Rec; users.allocator = temp;
            for vv(vr(r).def).users array_add(*users, it);
            for u: users if vp_is_ir_phi(u) vp_replace_uses_of_with(u, vr(r).def, vr(pen).def);
        }
    }
}

// LoopVectorizationPlanner::addReductionResultComputation (not AnyOf / FindIV / FindLast; no tail folding)
lvp_add_reduction_result_computation :: (lp: *Lv_Planner, min_vf: Ec) {
    region := vp_vector_loop_region();
    middle := vp_middle_block();
    header_mask := vb(region).header_mask;
    ip := vp_first_non_phi(middle);
    for phir: vp_block_phis(vp_entry_basic_block(region)) {
        if vr(phir).kind != .REDUCTION_PHI continue;
        rk := vr(phir).rdx_kind;
        rd := lvl_find_reduction(lp.lvl, vp_underlying_instr(phir));
        phi_ty := vp_scalar_type(vr(phir).def);
        bd := vp_def(vp_op(phir, 1));
        // a blend backedge value only becomes a select when its first mask is the header mask (tail folding)
        if bd != NONE && vr(bd).kind == .BLEND && header_mask != NONE && vp_blend_num_incoming(bd) == 2 && vp_blend_mask(bd, 0) == header_mask {
            sb := vpb_before(bd);
            sel := vpb_select(*sb, vp_blend_mask(bd, 0), vp_blend_incoming(bd, 0), vp_blend_incoming(bd, 1), NONE, "", vr(bd).flags);
            vp_rauw(vr(bd).def, vr(sel).def);
            vp_erase_recipe(bd);
        }
        orig_exiting := vp_op(phir, 1);
        new_exiting := orig_exiting;
        // usePredicatedReductionSelect: always with EVL tail folding, alias masking and for FindLast, otherwise
        // -prefer-predicated-reduction-select (TTI.preferPredicatedReductionSelect is false)
        use_pred_sel := lv_cm_fold_tail_with_evl(lp.cm) || lv_cm_mask_partial_aliasing(lp.cm) || rk_is_find_last(rk) || lv_opts.prefer_predicated_reduction_select;
        if !use_pred_sel && header_mask != NONE {
            oks, c, t, f := vpm_select(vp_op(phir, 1));
            if oks && c == header_mask && f == vr(phir).def vp_set_operand(phir, 1, t);
        }
        exit_dl := inst_dl(block_terminator(li_loop_latch(lp.li, lp.l)));
        b := vpb_at(middle, ip);
        final: Vp_Val;
        if rk_is_any_of(rk) {
            sel: Vp_Rec = NONE;
            for u: vv(vr(phir).def).users { ok, _, _, _ := vpm_select(vr(u).def); if vr(u).def != NONE && ok { sel = u; break; } }
            assert(sel != NONE, "expected the AnyOf select");
            start := vp_op(phir, 0);
            true_is_phi := vp_op(sel, 1) == vr(phir).def;
            new_val := ifx true_is_phi then vp_op(sel, 2) else vp_op(sel, 1);
            cmp := vp_op(sel, 0);
            cr := vp_def(cmp);
            if cr != NONE vp_replace_uses_of_with(cr, vr(phir).def, start);
            sb := vpb_before(sel);
            if true_is_phi cmp = vr(vpb_not(*sb, cmp)).def;
            new_phi := vp_new_reduction_phi(vp_uv(vr(phir).def), rk, vp_false(), vp_false(), vr(phir).rdx_style, vr(phir).rdx_scale,
                                            vr(phir).flags, vr(phir).has_uses_outside_chain);
            vp_insert_before(new_phi, phir);
            new_ex := vr(vpb_or(*sb, vr(new_phi).def, cmp)).def;
            subst_from: [..] Vp_Val; subst_from.allocator = temp;
            subst_to: [..] Vp_Val; subst_to.allocator = temp;
            array_add(*subst_from, vr(sel).def); array_add(*subst_to, new_ex);
            array_add(*subst_from, vr(phir).def); array_add(*subst_to, vr(new_phi).def);
            lookup :: (from: [] Vp_Val, to: [] Vp_Val, v: Vp_Val) -> Vp_Val { for from if it == v return to[it_index]; return NONE; }
            clone_chain :: (old: Vp_Rec, from: *[..] Vp_Val, to: *[..] Vp_Val) {
                if lookup(from.*, to.*, vr(old).def) != NONE return;
                ops: [..] Vp_Val; ops.allocator = temp;
                for o: vr(old).ops {
                    od := vp_def(o);
                    oks, _, _, _ := vpm_select(o);
                    if od != NONE && (vr(od).kind == .BLEND || oks) clone_chain(od, from, to);
                    x := lookup(from.*, to.*, o);
                    array_add(*ops, ifx x != NONE then x else o);
                }
                k := vr(old).kind;
                n: Vp_Rec;
                if k == .BLEND n = vp_new_blend(vp_uv(vr(old).def), ops, vr(old).flags, vr(old).dl);
                else if k == .WIDEN {
                    n = vp_new_single_def(.WIDEN, ops, vp_compute_scalar_type_for_instruction(vr(old).opcode, ops), vp_uv(vr(old).def), vr(old).dl);
                    vr(n).opcode = vr(old).opcode; vr(n).flags = vr(old).flags; for vr(old).md array_add(*vr(n).md, it);
                } else if k == .REPLICATE {
                    n = vp_new_replicate(vp_underlying_instr(old), ops, vr(old).single_scalar, NONE, vr(old).flags, vr(old).md, vr(old).dl);
                    if vr(old).predicated vp_unported("cloning predicated replicate recipes");
                } else {
                    n = vp_new_instruction(vr(old).opcode, ops, vr(old).flags, vr(old).md, vr(old).dl, vr(old).name);
                    if vp_uv(vr(old).def) != NONE vp_set_underlying(vr(n).def, vp_uv(vr(old).def));
                }
                vp_insert_before(n, old);
                array_add(from, vr(old).def); array_add(to, vr(n).def);
            }
            if orig_exiting != vr(sel).def {
                clone_chain(vp_def(orig_exiting), *subst_from, *subst_to);
                new_ex = lookup(subst_from, subst_to, orig_exiting);
            }
            vp_set_operand(new_phi, 1, new_ex);
            vp_rauw(vr(phir).def, vp_poison(phi_ty));
            b = vpb_at(middle, ip);
            fl := vpf_reduction(.OR, false, false, 0);
            orr := vpb_nary(*b, VPI_COMPUTE_REDUCTION_RESULT, .[new_ex], fl, .[], exit_dl);
            frz := vpb_nary(*b, vp_opc(.FREEZE), .[vr(orr).def], .{}, .[], exit_dl);
            final = vr(vpb_select(*b, vr(frz).def, new_val, start, exit_dl, "rdx.select")).def;
        } else {
            rop := new_exiting;
            has_ext := false; ext_opc := Opcode.ZEXT;
            if ec_is_vector(min_vf) && phi_ty != rd.recur_type {
                assert(vr(phir).rdx_style == .UNORDERED, "Unexpected truncated inloop reduction!");
                rty := rd.recur_type;
                ext_opc = ifx rd.is_signed then Opcode.SEXT else .ZEXT; has_ext = true;
                nd := vp_def(new_exiting);
                tb := vpb_after(nd);
                rop = vr(vpb_widen_cast(*tb, .TRUNC, new_exiting, rty)).def;
                extnd := vpb_widen_cast(*tb, ext_opc, rop, phi_ty);
                if vp_op(phir, 1) == new_exiting vp_set_operand(phir, 1, vr(extnd).def);
            }
            flags := vpf_reduction(rk, vr(phir).rdx_style == .ORDERED, vr(phir).rdx_style != .UNORDERED, vp_fmf_or_none(phir));
            fr := vpb_nary(*b, VPI_COMPUTE_REDUCTION_RESULT, .[rop], flags, .[], exit_dl);
            final = vr(fr).def;
            if has_ext final = vr(vpb_scalar_cast(*b, ext_opc, final, phi_ty, NONE)).def;
        }
        users: [..] Vp_Rec; users.allocator = temp;
        for vv(orig_exiting).users array_add(*users, it);
        for u_in: users {
            u := u_in;
            parent := vr(u).parent;
            if vp_def(final) == u || vb(parent).parent != NONE continue;
            if vp_is_vpi(u, VPI_COMPUTE_REDUCTION_RESULT) || (rk_is_find_iv(rk) && vp_is_vpi(u, vp_opc(.ICMP))) continue;
            vp_replace_uses_of_with(u, orig_exiting, final);
            if vpm_vpi_r(u, VPI_EXTRACT_LAST_PART, 1) u = vp_single_user(vr(u).def);
            if u != NONE && (vpm_vpi_r(u, VPI_EXTRACT_LANE, 2) || vpm_vpi_r(u, VPI_EXTRACT_LAST_LANE, 1)) vp_rauw(vr(u).def, final);
        }
        if !rk_is_any_of(rk) && !rk_is_find_iv(rk) && !rk_is_min_max(rk) && !rk_is_find_last(rk) {
            phb := vpb_at_end(vp_vector_preheader());
            iden := vp_live_in(lv_recurrence_identity(rk, phi_ty, vp_fmf_or_none(phir)));
            scale := vp_const_int(type_int(32), 1);
            sv := vpb_nary(*phb, VPI_REDUCTION_START_VECTOR, .[vp_op(phir, 0), iden, scale], vr(phir).flags);
            vp_set_operand(phir, 0, vr(sv).def);
        }
    }
    // clearReductionWrapFlags
    for phir: vp_block_phis(vp_entry_basic_block(region)) {
        if vr(phir).kind != .REDUCTION_PHI continue;
        k := vr(phir).rdx_kind;
        if k != .ADD && k != .MUL && k != .SUB && k != .ADD_CHAIN_WITH_SUBS continue;
        for u: vp_collect_users_recursively(vr(phir).def) if vp_is_with_ir_flags_kind(vr(u).kind) vp_drop_poison_generating_flags(u);
    }
}

// getReductionIntrinsicID(RecurKind)
lv_reduction_intrinsic_id :: (k: Recur_Kind) -> string {
    if k == {
        case .ADD_CHAIN_WITH_SUBS; #through; case .SUB; #through; case .ADD; return "llvm.vector.reduce.add";
        case .MUL; return "llvm.vector.reduce.mul";
        case .AND; return "llvm.vector.reduce.and";
        case .OR; return "llvm.vector.reduce.or";
        case .XOR; return "llvm.vector.reduce.xor";
        case .FMULADD; #through; case .FADD_CHAIN_WITH_SUBS; #through; case .FSUB; #through; case .FADD; return "llvm.vector.reduce.fadd";
        case .FMUL; return "llvm.vector.reduce.fmul";
        case .SMAX; return "llvm.vector.reduce.smax";
        case .SMIN; return "llvm.vector.reduce.smin";
        case .UMAX; return "llvm.vector.reduce.umax";
        case .UMIN; return "llvm.vector.reduce.umin";
        case .FMAX; #through; case .FMAXNUM; return "llvm.vector.reduce.fmax";
        case .FMIN; #through; case .FMINNUM; return "llvm.vector.reduce.fmin";
        case .FMAXIMUM; return "llvm.vector.reduce.fmaximum";
        case .FMINIMUM; return "llvm.vector.reduce.fminimum";
        case .FMAXIMUMNUM; return "llvm.vector.reduce.fmax";
        case .FMINIMUMNUM; return "llvm.vector.reduce.fmin";
    }
    fatal("internal: unexpected recurrence kind %", k);
    return "";
}
// getRecurrenceIdentity (the arithmetic kinds: ConstantExpr::getBinOpIdentity with NSZ)
lv_recurrence_identity :: (k: Recur_Kind, ty: Type_Id, fmf: u32) -> Value_Id {
    if rk_is_int_min_max(k) {
        // getReductionIdentity for the integer min/max reduction intrinsics
        bw := type_bits(scalar_type(ty));
        a: APInt;
        if k == .SMAX a = ap_signed_min(bw); else if k == .SMIN a = ap_signed_max(bw);
        else if k == .UMAX a = ap_zero(bw); else a = ap_all_ones(bw);
        return const_int_ap(ty, a);
    }
    if rk_is_fp_min_max(k) {
        // vector_reduce_fmin/fmax/fminimum/fmaximum (FMinimumNum/FMaximumNum map to fmin/fmax)
        neg := k == .FMAX || k == .FMAXNUM || k == .FMAXIMUM || k == .FMAXIMUMNUM;
        propagates_nan := k == .FMINIMUM || k == .FMAXIMUM;
        fk := type_kind(scalar_type(ty));
        w: [] u64;
        if !(fmf & FMF_NNAN) && !propagates_nan w = fp_with_sign(fk, fp_default_nan(fk), neg);
        else if !(fmf & FMF_NINF) w = fp_inf(fk, neg);
        else w = fp_largest(fk, neg);
        return const_fp_words(ty, w);
    }
    if rk_is_any_of(k) || rk_is_find(k) vp_unported(tprint("recurrence identities of % reductions", k));
    opc := rk_opcode(k);
    if k == .SUB || k == .ADD_CHAIN_WITH_SUBS opc = .ADD;
    if k == .FSUB || k == .FADD_CHAIN_WITH_SUBS || k == .FMULADD opc = .FADD;
    if opc == .FADD && (fmf & FMF_NSZ) return const_fp_words(ty, fp_zero(type_kind(scalar_type(ty)), false));
    return cf_binop_identity(opc, ty, false);
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
            if p != middle {
                esc := vp_optimize_early_exit_induction_user(vp_op(r, idx), lp.pse);
                if esc != NONE vp_set_operand(r, idx, esc);
                continue;
            }
            o := vp_op(r, idx);
            incoming: Vp_Val = NONE;
            ell := vp_def(o);
            ok1, _ := vpm_vpi(o, VPI_EXTRACT_LAST_LANE, 1);
            if ok1 {
                ok2, elp := vpm_vpi(vp_op(ell, 0), VPI_EXTRACT_LAST_PART, 1);
                if ok2 incoming = vp_op(elp, 0);
            }
            if incoming == NONE {
                ok3, el := vpm_vpi(o, VPI_EXTRACT_LANE, 2);
                if !ok3 continue;
                ok4, lal := vpm_vpi(vp_op(el, 0), VPI_LAST_ACTIVE_LANE, 1);
                if !ok4 || !vp_is_header_mask(vp_op(lal, 0)) continue;
                incoming = vp_op(el, 1);
            }
            w := vp_optimizable_iv_of(incoming, lp.pse);
            if w == NONE continue;
            _, end := table_find(*end_values, w);
            esc := end;
            if incoming == vr(w).def {
                b := vpb_before(ell);
                step := vp_op(w, 1);
                sty := vp_scalar_type(vr(w).def);
                if type_kind(sty) == .INT esc = vr(vpb_sub(*b, end, step, NONE, "ind.escape")).def;
                else if type_kind(sty) == .PTR {
                    neg := vpb_sub(*b, vp_zero(vp_scalar_type(step)), step);
                    esc = vr(vpb_ptr_add(*b, end, vr(neg).def, NONE, "ind.escape")).def;
                } else {
                    bop := vpl.inds[vr(w).ind].bop;
                    opc := ifx inst_op(bop) == .FADD then Opcode.FSUB else .FADD;
                    esc = vr(vpb_nary(*b, vp_opc(opc), .[end, step], vpf_fmf(inst_fmf(bop)))).def;
                }
            }
            vp_set_operand(r, idx, esc);
        }
    }
}

// optimizeEarlyExitInductionUser
vp_optimize_early_exit_induction_user :: (op: Vp_Val, pse: *Pse) -> Vp_Val {
    ok, ext := vpm_vpi(op, VPI_EXTRACT_LANE, 2);
    if !ok return NONE;
    okf, fal := vpm_vpi(vp_op(ext, 0), VPI_FIRST_ACTIVE_LANE, 1);
    if !okf return NONE;
    mask := vp_op(fal, 0);
    incoming := vp_op(ext, 1);
    w := vp_optimizable_iv_of(incoming, pse);
    if w == NONE return NONE;
    if vr(w).kind == .WIDEN_INT_OR_FP_INDUCTION && vr(w).ir_inst != NONE return NONE;
    region := vp_vector_loop_region();
    can_iv := vb(region).can_iv;
    can_ty := vv(can_iv).ty;
    b := vpb_before(ext);
    dl := vr(ext).dl;
    f := vr(vpb_nary(*b, VPI_FIRST_ACTIVE_LANE, .[mask], .{}, .[], dl, "", dl_index_type(type_ptr(0)))).def;
    f = vpb_scalar_zext_or_trunc(*b, f, can_ty, vp_scalar_type(f), dl);
    end := vr(vpb_add(*b, can_iv, f, dl)).def;
    if incoming != vr(w).def end = vr(vpb_add(*b, end, vp_const_int(can_ty, 1), dl)).def;
    if !vp_is_canonical_widen_iv(w) {
        d := *vpl.inds[vr(w).ind];
        fpb := ifx d.bop != NONE && is_fp_math_operator(d.bop) then d.bop else NONE;
        end = vr(vpb_insert(*b, vp_new_derived_iv(d.kind, fpb, vp_op(w, 0), end, vp_op(w, 1)))).def;
    }
    return end;
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
        vp_hoist_predicated_loads(lp.pse, lp.l);
        vp_sink_predicated_stores(lp.pse, lp.l);
        min_bws := lvp_minimal_bitwidths(lp);
        vp_truncate_to_minimal_bitwidths(min_bws);
        vp_optimize();
        if lp.cm.tail_folding_style == .DATA_WITH_EVL vp_unported("EVL tail folding");
        np := vp_narrow_interleave_groups(lp.cm.tti);
        if np array_add(*lp.vplans, np);
        vp_use(plan);
        st := lp.cm.tail_folding_style;
        vp_materialize_header_mask(st == .DATA || st == .DATA_AND_CONTROL_FLOW || st == .DATA_AND_CONTROL_FLOW_WITHOUT_RUNTIME_CHECK,
                                   st == .DATA_AND_CONTROL_FLOW || st == .DATA_AND_CONTROL_FLOW_WITHOUT_RUNTIME_CHECK);
        array_add(*lp.vplans, plan);
    }
}
// VFSelectionContext::computeMinimalBitwidths (computeMinimumValueSizes): only the empty result is ported
lvp_minimal_bitwidths :: (lp: *Lv_Planner) -> *Table(Value_Id, u64) {
    if !li_is_innermost(lp.li, lp.l) && !lp.cm.min_bws {   // computeMinimalBitwidths is not run for outer loops
        e := New(Table(Value_Id, u64),, allocator = temp);
        e.allocator = temp;
        lp.cm.min_bws = e;
    }
    if !lp.cm.min_bws lp.cm.min_bws = lv_compute_minimum_value_sizes(li_blocks(lp.li, lp.l), lp.p.db, lp.cm.tti);
    return lp.cm.min_bws;
}

// llvm::computeMinimumValueSizes (VectorUtils.cpp)
lv_compute_minimum_value_sizes :: (blocks: [] Value_Id, db: *Demanded_Bits, tti: *Tti) -> *Table(Value_Id, u64) {
    t := New(Table(Value_Id, u64),, allocator = temp);
    t.allocator = temp;
    // EquivalenceClasses<Value *>: insertion-ordered elements, a leader per element, member lists per leader
    Ec_State :: struct {
        order: [..] Value_Id;
        leader: Table(Value_Id, Value_Id);
        members: Table(Value_Id, [..] Value_Id);
    }
    ecs: Ec_State;
    ecs.order.allocator = temp; ecs.leader.allocator = temp; ecs.members.allocator = temp;
    leader_of :: (e: *Ec_State, v: Value_Id) -> Value_Id {
        found, l := table_find(*e.leader, v);
        if found return l;
        array_add(*e.order, v);
        table_set(*e.leader, v, v);
        m: [..] Value_Id; m.allocator = temp; array_add(*m, v);
        table_set(*e.members, v, m);
        return v;
    }
    union_sets :: (e: *Ec_State, a: Value_Id, b: Value_Id) {
        la := leader_of(e, a); lb := leader_of(e, b);
        if la == lb return;
        ma := table_find_pointer(*e.members, la);
        mb := table_find_pointer(*e.members, lb);
        for mb.* { array_add(ma, it); table_set(*e.leader, it, la); }
        table_remove(*e.members, lb);
    }
    worklist: [..] Value_Id; worklist.allocator = temp;
    roots: Table(Value_Id, bool); roots.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    dbits: Table(Value_Id, u64); dbits.allocator = temp;
    dbits_order: [..] Value_Id; dbits_order.allocator = temp;
    in_set: Table(Value_Id, bool); in_set.allocator = temp;
    seen_ext_from_illegal := false;
    for bb: blocks for i: block_insts(bb) {
        table_set(*in_set, i, true);
        o := inst_op(i);
        if (o == .ZEXT || o == .SEXT) && !lv_tti_is_type_legal(tti, vtype(op(i, 0))) seen_ext_from_illegal = true;
        if (o == .TRUNC || o == .ICMP) && !is_vector_type(vtype(i)) && type_bits(scalar_type(vtype(op(i, 0)))) <= 64 {
            if o == .TRUNC && lv_tti_is_type_legal(tti, vtype(i)) continue;
            array_add(*worklist, i);
            table_set(*roots, i, true);
        }
    }
    if worklist.count == 0 || !seen_ext_from_illegal return t;
    dbits_or :: (d: *Table(Value_Id, u64), order: *[..] Value_Id, v: Value_Id, x: u64) {
        p := table_find_pointer(d, v);
        if p { p.* |= x; return; }
        table_set(d, v, x); array_add(order, v);
    }
    dbits_get :: (d: *Table(Value_Id, u64), v: Value_Id) -> u64 { found, x := table_find(d, v); return ifx found then x else 0; }
    while worklist.count {
        i := pop(*worklist);
        leader := leader_of(*ecs, i);
        if table_contains(*visited, i) continue;
        table_set(*visited, i, true);
        dm := db_demanded_bits(db, i);
        if dm.bits > 64 { table_reset(t); return t; }
        v := ap_zext_value(dm);
        dbits_or(*dbits, *dbits_order, leader, v);
        p := table_find_pointer(*dbits, i);
        if p p.* = v; else { table_set(*dbits, i, v); array_add(*dbits_order, i); }
        o := inst_op(i);
        if o == .SEXT || o == .ZEXT || o == .LOAD || !table_contains(*in_set, i) continue;
        if o == .BITCAST || o == .PTRTOINT || o == .INTTOPTR || type_kind(vtype(i)) != .INT {
            dbits_or(*dbits, *dbits_order, leader, 0xFFFF_FFFF_FFFF_FFFF);
            continue;
        }
        if o == .PHI continue;
        if is_call_base(i) continue;
        if dbits_get(*dbits, leader) == 0xFFFF_FFFF_FFFF_FFFF continue;
        for k: 0..cast(s64) nops(i) - 1 {
            x := op(i, cast(u32) k);
            union_sets(*ecs, leader, x);
            if is_inst(x) array_add(*worklist, x);
        }
    }
    // users not seen poison the chain
    snapshot: [..] Value_Id; snapshot.allocator = temp;
    for dbits_order array_add(*snapshot, it);
    for v: snapshot {
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u];
            if type_kind(vtype(usr)) == .INT && !table_contains(*dbits, usr) dbits_or(*dbits, *dbits_order, leader_of(*ecs, v), 0xFFFF_FFFF_FFFF_FFFF);
            u = ir.u_next[u];
        }
    }
    for e: ecs.order {
        _, l := table_find(*ecs.leader, e);
        if l != e continue;
        mem := table_find_pointer(*ecs.members, e);
        ldb: u64 = 0;
        for m: mem.* ldb |= dbits_get(*dbits, m);
        bw: u64 = 0;
        { x := ldb; while x { bw += 1; x >>= 1; } }
        min_bw: u64 = 1;
        while min_bw < bw min_bw *= 2;   // llvm::bit_ceil (bit_ceil(0) = 1)
        abort := false;
        for m: mem.* if is_inst(m) && inst_op(m) == .PHI && min_bw < cast(u64) type_bits(scalar_type(vtype(m))) { abort = true; break; }
        if abort continue;
        for m: mem.* {
            if !is_inst(m) continue;
            ty := vtype(m);
            if table_contains(*roots, m) ty = vtype(op(m, 0));
            if min_bw >= cast(u64) type_bits(scalar_type(ty)) continue;
            n := ifx is_call_base(m) then call_arg_count(m) else nops(m);
            bad := false;
            mo := inst_op(m);
            for k: 0..cast(s64) n - 1 {
                x := op(m, cast(u32) k);
                if vkind(x) == .C_INT && (mo == .SHL || mo == .LSHR || mo == .ASHR) && k == 1 {
                    if ap_uge_u64(const_ap(x), min_bw) { bad = true; break; }
                    continue;
                }
                ud := db_demanded_bits_use(db, ir.v_ops[m] + cast(u32) k);
                ub: u64 = 0;
                { x2 := ap_zext_value(ud); while x2 { ub += 1; x2 >>= 1; } }
                c: u64 = 1; while c < ub c *= 2;
                if c > min_bw { bad = true; break; }
            }
            if bad continue;
            table_set(t, m, min_bw);
        }
    }
    return t;
}
lv_tti_is_type_legal :: (t: *Tti, ty: Type_Id) -> bool {
    if t.kind != .X86 return false;
    return tti_is_type_legal(t, ty);
}

// LoopVectorizationPlanner::plan (the part after computeMaxVF), followed by computeBestVF and the rest of
// processLoop
lvp_plan_and_vectorize :: (lp: *Lv_Planner, user_vf: Ec, user_ic: u64, max_factors: Vf_Pair) -> bool {
    if ec_is_vector(max_factors.fixed) || ec_is_vector(max_factors.scalable) lvl_collect_unit_stride_predicates(lp.lvl);
    vplan1 := lvp_try_to_build_vplan1(lp);
    if vplan1 && !li_is_innermost(lp.li, lp.l) {
        // outer loops: computeMaxVF returned a single non-scalar VF; build a plan for that VF only
        vf := ifx max_factors.fixed.n then max_factors.fixed else max_factors.scalable;
        lvp_build_vplans(lp, vplan1, vf, vf);
    } else if vplan1 {
        lp.cm.min_bws = lv_compute_minimum_value_sizes(li_blocks(lp.li, lp.l), lp.p.db, lp.cm.tti);
        if lv_cm_block_needs_predication_for_any_reason(lp.cm, li_header(lp.li, lp.l)) && !lv_use_masked_interleaved_accesses(lp.cm.tti) {
            if iai_invalidate_groups(lp.cm.iai) {   // invalidateCostModelingDecisions
                lp.cm.per_vf.count = 0;
                table_reset(*lp.cm.decisions);
            }
        }
        if lv_cm_fold_tail_by_masking(lp.cm) lvl_prepare_to_fold_tail_by_masking(lp.lvl);
        max_user_vf := ifx user_vf.scalable then max_factors.scalable else max_factors.fixed;
        done := false;
        if user_vf.n && ec_known_le(user_vf, max_user_vf) {
            lv_cm_collect_non_vectorized_and_set_widening_decisions(lp.cm, user_vf);
            if lv_opts.epilogue_force_vf.set && lv_opts.epilogue_force_vf.v > 1 && cast(u64) lv_opts.epilogue_force_vf.v < user_vf.n {
                if user_vf.scalable vp_unported("-epilogue-vectorization-force-VF with a scalable user VF");
                evf := ec_fixed(cast(u64) lv_opts.epilogue_force_vf.v);
                lv_cm_collect_non_vectorized_and_set_widening_decisions(lp.cm, evf);
                lvp_build_vplans(lp, vplan1, evf, evf);
            }
            lvp_build_vplans(lp, vplan1, user_vf, user_vf);
            if lp.vplans.count && ec_eq(vp_plan_single_vf(lp.vplans[lp.vplans.count - 1]), user_vf) {
                if ec_is_scalar(user_vf) || cost_valid(lvp_cost(lp, lp.vplans[lp.vplans.count - 1], user_vf, null)) done = true;
            }
            if !done {
                lp.vplans.count = 0;
                lv_dbg("LV: UserVF ignored because of invalid costs.\n");
            }
        }
        if !done {
            vf := ec_fixed(1);
            while ec_known_le(vf, max_factors.fixed) { lv_cm_collect_non_vectorized_and_set_widening_decisions(lp.cm, vf); vf.n *= 2; }
            svf := ec_scalable(1);
            while ec_known_le(svf, max_factors.scalable) { lv_cm_collect_non_vectorized_and_set_widening_decisions(lp.cm, svf); svf.n *= 2; }
            lvp_build_vplans(lp, vplan1, ec_fixed(1), max_factors.fixed);
            lvp_build_vplans(lp, vplan1, ec_scalable(1), max_factors.scalable);
        }
    }
    best, plan := lvp_compute_best_vf(lp);
    // VPlan build stress testing of outer loops bails after plan construction
    if !li_is_innermost(lp.li, lp.l) && lv_opts.vplan_build_outerloop_stress_test return false;
    return lvp_process_best_plan(lp, best, plan, user_ic);
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
            last := phi;
            for ops { table_set(*lp.cm.in_loop_chains, it, last); last = it; }
        }
        if lv_debug_enabled() lv_dbg("LV: Using % reduction for phi: %\n", ifx ops.count then "inloop" else "out of loop", lv_inst_str(phi));
    }
}

// decideCallWidening (CallWideningDecision; vector library variants fail loudly at legality)
Lv_Call_Widening_Kind :: enum u8 { SCALARIZE; INTRINSIC; VECTOR_VARIANT; }
Lv_Call_Widening :: struct { kind: Lv_Call_Widening_Kind; variant: Value_Id = NONE; }
// areVFParamsOk
vp_are_vf_params_ok :: (info: *Vf_Info, args: [] Vp_Val, pse: *Pse, l: Loop_Id) -> bool {
    for p: info.shape.params {
        if p.kind == {
            case .VECTOR; #through; case .GLOBAL_PREDICATE; continue;
            case .OMP_UNIFORM;
                a := args[p.pos];
                if !sc_is_scevable(vp_scalar_type(a)) || !sc_is_loop_invariant(vp_scev_for_value(a, pse, l), l) return false;
            case .OMP_LINEAR;
                e := vp_scev_for_value(args[p.pos], pse, l);
                if sc_is_cnc(e) || !sc_is_addrec(e) || !sc_is_affine(e) || sc_loop(e) != l return false;
                st := sc_step_recurrence(e);
                if !sc_is_const(st) return false;
                sv := const_ap(sc_value(st));
                if sv.bits > 64 || ap_sext_value(sv) != cast(s64) p.step return false;
            case; return false;
        }
    }
    return true;
}
// findVectorVariant
vp_find_vector_variant :: (ci: Value_Id, args: [] Vp_Val, vf: Ec, mask_required: bool, pse: *Pse, l: Loop_Id) -> Value_Id {
    if call_is_no_builtin(ci) return NONE;
    for * info: vfdb_get_mappings(ci) {
        if info.shape.vf != cast(u32) vf.n || info.shape.scalable != vf.scalable continue;
        if mask_required && !vf_info_is_masked(info) continue;
        if !vp_are_vf_params_ok(info, args, pse, l) continue;
        return module_get_function(info.vector_name);
    }
    return NONE;
}
lvp_decide_call_widening :: (c: *Vp_Cost_Ctx, vpi: Vp_Rec, ops: [] Vp_Val, vf: Ec) -> Lv_Call_Widening {
    ci := vp_underlying_instr(vpi);
    if ec_is_scalar(vf) || vpc_will_be_scalarized(c, ci, vf) return .{.SCALARIZE, NONE};
    called := vp_ir(vp_op(vpi, vpm_num_ops_without_mask(vpi) - 1));
    result_ty := vp_scalar_type(vr(vpi).def);
    id := get_vector_intrinsic_id_for_call(ci);
    mask_required := lv_cm_is_mask_required(c.lp.cm, ci);
    if id != NOT_INTRINSIC && vpc_is_free_scalar_intrinsic(id) return .{.SCALARIZE, NONE};
    scalar_cost := vp_replicate_call_cost(c, called, result_ty, ops, false, vf);
    vec_func := vp_find_vector_variant(ci, ops, vf, mask_required, c.lp.pse, c.lp.l);
    vec_call_cost := COST_INVALID;
    if vec_func != NONE vec_call_cost = vp_widen_call_cost(c, vec_func);
    if id != NOT_INTRINSIC {
        ic := vp_widen_intrinsic_call_cost(c, id, ops, vpi, vf);
        if cost_valid(ic) && scalar_cost >= ic && (vec_func == NONE || vec_call_cost >= ic) return .{.INTRINSIC, NONE};
    }
    if vec_func != NONE && scalar_cost >= vec_call_cost return .{.VECTOR_VARIANT, vec_func};
    return .{.SCALARIZE, NONE};
}
// VPlanTransforms::makeCallWideningDecisions
lvp_make_call_widening_decisions :: (lp: *Lv_Planner, range: *Vf_Range) {
    c: Vp_Cost_Ctx;
    vpc_init(*c, lp);
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) {
        r := vb(bb).first;
        while r != NONE {
            next := vr(r).next;
            defer r = next;
            if vr(r).kind != .INSTRUCTION || vv(vr(r).def).uv == NONE || vr(r).opcode != vp_opc(.CALL) continue;
            ci := vp_underlying_instr(r);
            n := cast(s64) call_arg_count(ci);
            ops: [..] Vp_Val; ops.allocator = temp;
            for k: 0..n - 1 array_add(*ops, vp_op(r, k));
            decision := lvp_decide_call_widening(*c, r, ops, range.start);
            Ctx :: struct { c: *Vp_Cost_Ctx; r: Vp_Rec; ops: [] Vp_Val; d: Lv_Call_Widening; }
            cx := Ctx.{*c, r, ops, decision};
            same :: (vf: Ec, d: *void) -> bool {
                x := cast(*Ctx) d;
                o := lvp_decide_call_widening(x.c, x.r, x.ops, vf);
                return x.d.kind == o.kind && x.d.variant == o.variant;
            }
            lvp_decision_and_clamp_range(range, same, *cx);
            repl: Vp_Rec;
            if decision.kind == .INTRINSIC {
                id := get_vector_intrinsic_id_for_call(ci);
                repl = vp_new_widen_intrinsic(ci, id, ops, vp_scalar_type(vr(r).def), vr(r).flags, vr(r).md, vr(r).dl);
            } else if decision.kind == .VECTOR_VARIANT {
                // masked variants take the mask as a trailing parameter
                if cast(s64) fn_nargs(decision.variant) > ops.count {
                    m := ifx vp_is_masked(r) then vp_op(r, vp_nops(r) - 1) else vp_true();
                    array_add(*ops, m);
                }
                array_add(*ops, vp_op(r, vpm_num_ops_without_mask(r) - 1));
                repl = vp_new_single_def(.WIDEN_CALL, ops, vp_scalar_type(vr(r).def), ci, vr(r).dl);
                vr(repl).variant = decision.variant; vr(repl).flags = vr(r).flags;
                for vr(r).md array_add(*vr(repl).md, it);
            } else {
                repl = lvp_handle_replication(lp, r, range);
            }
            vp_insert_before(repl, r);
            vp_rauw(vr(r).def, vr(repl).def);
            vp_erase_recipe(r);
        }
    }
}
// VPWidenIntrinsicRecipe(CallInst &CI, ID, CallArguments, Ty, Flags, MD, DL)
vp_new_widen_intrinsic :: (ci: Value_Id, id: Intrinsic_Id, ops: [] Vp_Val, ty: Type_Id, flags: Vp_Flags, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.WIDEN_INTRINSIC, ops, ty, ci, dl);
    vr(r).iid = id; vr(r).flags = flags;
    for md array_add(*vr(r).md, it);
    if ci != NONE {
        vr(r).may_read = may_read_from_memory(ci);
        vr(r).may_write = may_write_to_memory(ci);
        vr(r).may_side_effects = may_have_side_effects(ci);
    }
    return r;
}

// VPWidenIntrinsicRecipe(ID, CallArguments, Ty, Flags, Metadata, DL): memory effects from the intrinsic's attributes
vp_new_widen_intrinsic_no_call :: (id: Intrinsic_Id, ops: [] Vp_Val, ty: Type_Id, flags: Vp_Flags, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    r := vp_new_widen_intrinsic(NONE, id, ops, ty, flags, md, dl);
    attrs := intrinsic_fn_attr_set(id);
    me := attr_set_memory(attrs);
    vr(r).may_read = !mem_only_writes(me);
    vr(r).may_write = !mem_only_reads(me);
    vr(r).may_side_effects = vr(r).may_write || !attr_set_has(attrs, .NoUnwind) || !attr_set_has(attrs, .WillReturn);
    return r;
}
// VPlanTransforms::handleFindLastReductions (VPlanConstruction.cpp)
// VPlanTransforms::handleMaxMinNumReductions
vp_handle_max_min_num_reductions :: () -> bool {
    min_or_max_compare_value :: (phir: Vp_Rec) -> Vp_Val {
        r := vp_def(vp_op(phir, 1));
        if r == NONE || !vp_is_with_ir_flags_kind(vr(r).kind) return NONE;
        expected := lv_min_max_reduction_intrinsic(vr(phir).rdx_kind);
        if !vp_is_intrinsic_match_kind(r) || vp_intrinsic_id(r) != expected return NONE;
        if vp_op(r, 0) == vr(phir).def return vp_op(r, 1);
        assert(vp_op(r, 1) == vr(phir).def, "Reduction phi operand expected");
        return vp_op(r, 0);
    }
    region := vp_vector_loop_region();
    Pair :: struct { phi: Vp_Rec; op: Vp_Val; }
    todo: [..] Pair; todo.allocator = temp;
    unsupported := false;
    for r: vp_block_phis(vp_entry_basic_block(region)) {
        if vr(r).kind == .WIDEN_INT_OR_FP_INDUCTION continue;
        if vr(r).kind != .REDUCTION_PHI { unsupported = true; continue; }
        if !rk_is_fp_min_max_num(vr(r).rdx_kind) { unsupported = true; continue; }
        mo := min_or_max_compare_value(r);
        if mo == NONE return false;
        array_add(*todo, .{r, mo});
    }
    if todo.count == 0 return true;
    if unsupported || !vp_has_scalar_tail() return false;
    for bb: vp_depth_first_shallow(vp_entry_basic_block(region)) {
        assert(vp_is_basic(bb), "expected an early VPlan without nested regions");
        for r: vp_block_recipes(bb) if vp_may_write_to_memory(r) && !vpm_branch_on_count(r) return false;
    }
    latch := vp_exiting_basic_block(region);
    lb := vpb_before(vp_terminator(latch));
    all_nan: Vp_Val = NONE;
    for todo {
        nan := vr(vpb_fcmp(*lb, FCMP_UNO, it.op, it.op)).def;
        all_nan = ifx all_nan != NONE then vr(vpb_or(*lb, all_nan, nan)).def else nan;
    }
    any_nan := vr(vpb_nary(*lb, VPI_ANY_OF, .[all_nan])).def;
    middle := vp_middle_block();
    mb := vpb_at(middle, vb(middle).first);
    rdx_results: [..] Vp_Rec; rdx_results.allocator = temp;
    for todo {
        rr := vp_find_compute_reduction_result(it.phi);
        assert(rr != NONE, "must find a ComputeReductionResult");
        sel := vpb_select(*mb, any_nan, vr(it.phi).def, vp_op(rr, 0));
        vp_set_operand(rr, 0, vr(sel).def);
        assert(!array_find(rdx_results, rr), "RdxResult already used");
        array_add(*rdx_results, rr);
    }
    term := vp_terminator(latch);
    ok, a, b := vpm_branch_on_count(term);
    assert(ok, "Unexpected terminator");
    taken := vpb_icmp(*lb, ICMP_EQ, vp_op(term, 0), vp_op(term, 1));
    any_exit := vpb_or(*lb, any_nan, vr(taken).def);
    vpb_nary(*lb, VPI_BRANCH_ON_COND, .[vr(any_exit).def]);
    vp_erase_recipe(term);
    is_tc :: (v: Vp_Val) -> bool { return v == vpl.vector_trip_count || v == vpl.trip_count; }
    for r: vp_block_phis(vp_scalar_preheader()) {
        assert(vp_is_vp_phi(r), "expected VPPhi resume values");
        vec_v := vp_op(r, 0);
        d := vp_def(vec_v);
        if d != NONE && array_find(rdx_results, d) continue;
        if d != NONE && vr(d).kind == .DERIVED_IV {
            divtc := vp_op(d, 1);
            if vp_has_one_use(vec_v) && is_tc(divtc) {
                sel := vpb_select(*mb, any_nan, vb(region).can_iv, divtc);
                vp_move_after(d, mb.ip);
                vp_set_operand(d, 1, vr(sel).def);
                continue;
            }
        }
        if !is_tc(vec_v) {
            lv_dbg("Found resume phi we cannot update for VPlan with FMaxNum/FMinNum reduction.\n");
            return false;
        }
        sel := vpb_select(*mb, any_nan, vb(region).can_iv, vec_v);
        vp_set_operand(r, 0, vr(sel).def);
    }
    mterm := vp_terminator(middle);
    mb = vpb_before(mterm);
    mcond := vp_op(mterm, 0);
    nt := vpb_not(*mb, any_nan);
    nc := vpb_and(*mb, mcond, vr(nt).def);
    vp_set_operand(mterm, 0, vr(nc).def);
    return true;
}

vp_handle_find_last_reductions :: () -> bool {
    if vp_has_scalar_vf_only() return false;
    region := vp_vector_loop_region();
    phis: [..] Vp_Rec; phis.allocator = temp;
    for vp_block_phis(vp_entry_basic_block(region)) if vr(it).kind == .REDUCTION_PHI && rk_is_find_last(vr(it).rdx_kind) array_add(*phis, it);
    if phis.count == 0 return true;
    hm := vb(region).header_mask;
    for phir: phis {
        pd := vr(phir).def;
        backedge_select := vp_op(phir, 1);
        cond_select := backedge_select;
        if hm != NONE {
            // m_SelectLike(m_Specific(HeaderMask), m_VPValue(CondSelect), m_Specific(PhiR))
            matched := false;
            oks, c, t, f := vpm_select(backedge_select);
            if oks && c == hm && f == pd { cond_select = t; matched = true; }
            if !matched {
                bd := vp_def(backedge_select);
                if bd != NONE && vr(bd).kind == .BLEND && vp_blend_num_incoming(bd) == 2 && vp_blend_mask(bd, 1) == hm &&
                   vp_blend_incoming(bd, 0) == pd { cond_select = vp_blend_incoming(bd, 1); matched = true; }
            }
            if !matched return false;
        }
        cond: Vp_Val = NONE; op1: Vp_Val = NONE; op2: Vp_Val = NONE;
        sel_r := vp_def(cond_select);
        oks, c, t, f := vpm_select(cond_select);
        if oks { cond = c; op1 = t; op2 = f; }
        else {
            if sel_r == NONE || vr(sel_r).kind != .BLEND return false;
            n_data := 0;
            for k: 0..vp_blend_num_incoming(sel_r) - 1 {
                inc := vp_blend_incoming(sel_r, k);
                if inc != pd { n_data += 1; cond = vp_blend_mask(sel_r, k); op1 = inc; op2 = pd; }
            }
            if n_data != 1 return false;
        }
        rdx_result: Vp_Rec = NONE;
        for u: vv(backedge_select).users if vp_is_vpi(u, VPI_COMPUTE_REDUCTION_RESULT) { rdx_result = u; break; }
        assert(rdx_result != NONE, "Could not find reduction result");
        ab := vpb_after(phir);
        mask_phi := vp_new_single_def(.WIDEN_PHI, .[vp_false()], type_int(1), NONE, NONE);
        vpb_insert(*ab, mask_phi);
        b := vpb_before(sel_r);
        if op1 == pd {
            t2 := op1; op1 = op2; op2 = t2;
            cond = vr(vpb_not(*b, cond)).def;
        }
        assert(op2 == pd, "data value must be selected if Cond is true");
        if hm != NONE cond = vr(vpb_logical_and(*b, hm, cond)).def;
        any_of := vpb_nary(*b, VPI_ANY_OF, .[cond]);
        mask_select := vpb_select(*b, vr(any_of).def, cond, vr(mask_phi).def);
        vp_add_operand(mask_phi, vr(mask_select).def);
        data_select := vpb_select(*b, vr(any_of).def, op1, op2, vr(sel_r).dl);
        vp_rauw(vr(sel_r).def, vr(data_select).def);
        vp_set_operand(phir, 1, vr(data_select).def);
        vp_erase_recipe(sel_r);
        rb := vpb_before(rdx_result);
        ela := vpb_nary(*rb, VPI_EXTRACT_LAST_ACTIVE, .[vp_op(phir, 0), vr(data_select).def, vr(mask_select).def], .{}, .[], vr(rdx_result).dl,
                        "", vp_scalar_type(vr(data_select).def));
        vp_rauw(vr(rdx_result).def, vr(ela).def);
        vp_erase_recipe(rdx_result);
    }
    return true;
}

// findFindIVSelect: the select of the FindIV result pattern of `be`
vp_find_find_iv_select :: (be: Vp_Val) -> Vp_Rec {
    wl: [..] Vp_Val; wl.allocator = temp;
    array_add(*wl, be);
    i := 0;
    while i < wl.count {
        cur := wl[i]; i += 1;
        r := vp_def(cur);
        if r == NONE continue;
        if vr(r).kind == .INSTRUCTION {
            ok, red, _ := vp_match_find_iv_result(r);
            if ok && red == be return r;
        }
        for u: vv(cur).users {
            if vr(u).def != NONE array_add_if_unique(*wl, vr(u).def);
            for d: vr(u).defs array_add_if_unique(*wl, d);
        }
    }
    return NONE;
}
vp_find_user_vpi :: (v: Vp_Val, opc: u16) -> Vp_Rec { for u: vv(v).users if vp_is_vpi(u, opc) return u; return NONE; }

// handleFirstArgMinOrMax
vp_handle_first_arg_min_or_max :: (mm_phi: Vp_Rec, fiv_phi: Vp_Rec, wide_iv: Vp_Rec, mm_result: Vp_Rec, fiv_select: Vp_Rec, fiv_cmp: Vp_Rec, fiv_rdx: Vp_Rec) -> bool {
    region := vp_vector_loop_region();
    ty := vv(vb(region).can_iv).ty;
    if ty != vp_scalar_type(vr(wide_iv).def) return false;
    sel := vp_def(vp_op(fiv_phi, 1));
    wiv := vr(wide_iv).def;
    if vp_op(sel, 1) != wiv && vp_op(sel, 2) != wiv return false;
    canonical := vpm_zero_int(vp_op(wide_iv, 0)) && vp_is_const_int_one(vp_op(wide_iv, 1)) && vp_scalar_type(wiv) == ty;
    if !canonical {
        wc := vp_new_widen_int_or_fp_induction(NONE, vp_const_int(ty, 0), vp_const_int(ty, 1), vp_op(wide_iv, 2), vr(wide_iv).ind,
                                                vpf_wrap(true, false), vr(wide_iv).dl);
        vp_insert_before(wc, wide_iv);
        vp_set_operand(sel, ifx vp_op(sel, 1) == wiv then 1 else 2, vr(wc).def);
    }
    vp_set_operand(fiv_phi, 0, vp_poison(ty));
    b := vpb_before(fiv_rdx);
    mm_exiting := vp_op(mm_result, 0);
    final_cmp := vpb_icmp(*b, ICMP_EQ, mm_exiting, vr(mm_result).def);
    last_iv_exiting := vp_op(fiv_rdx, 0);
    max_iv := vp_const_int_ap(ap_all_ones(type_bits(ty)));
    final_sel := vpb_select(*b, vr(final_cmp).def, last_iv_exiting, max_iv);
    final_can_iv := vr(vpb_nary(*b, VPI_COMPUTE_REDUCTION_RESULT, .[vr(final_sel).def], vpf_reduction(.UMIN, false, false, 0), .[], vr(fiv_rdx).dl)).def;
    if !canonical {
        d := vp_new_derived_iv(.INT, NONE, vp_op(wide_iv, 0), final_can_iv, vp_op(wide_iv, 1));
        vp_insert_recipe(d, b.bb, b.ip);
        final_can_iv = vr(d).def;
    }
    always_false := vpb_icmp(*b, ICMP_EQ, vr(mm_result).def, vp_op(mm_phi, 0));
    final_iv := vpb_select(*b, vr(always_false).def, vp_op(fiv_select, 2), final_can_iv);
    vp_rauw(vr(fiv_select).def, vr(final_iv).def);
    vp_erase_recipe(fiv_select);
    vp_erase_recipe(fiv_cmp);
    vp_erase_recipe(fiv_rdx);
    return true;
}

// VPlanTransforms::handleMultiUseReductions
vp_handle_multi_use_reductions :: () -> bool {
    for phir: vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) {
        if vr(phir).kind != .REDUCTION_PHI || !vr(phir).has_uses_outside_chain continue;
        rk := vr(phir).rdx_kind;
        assert(rk_is_int_min_max(rk), "only min/max recurrences support users outside the reduction chain");
        pd := vr(phir).def;
        mm_op := vp_def(vp_op(phir, 1));
        if mm_op == NONE || !vp_is_with_ir_flags_kind(vr(mm_op).kind) return false;
        expected: Intrinsic_Id;
        if rk == .UMIN expected = IID_UMIN; else if rk == .UMAX expected = IID_UMAX; else if rk == .SMIN expected = IID_SMIN; else expected = IID_SMAX;
        if vp_intrinsic_id(mm_op) != expected return false;
        mm_val := vp_op(mm_op, 0);
        if mm_val == pd mm_val = vp_op(mm_op, 1);
        cmp: Vp_Rec = NONE; a, bb: Vp_Val;
        for u: vv(pd).users {
            if vr(u).def == NONE continue;
            ok, x, y := vpm_cmp(vr(u).def);
            if ok { cmp = u; a = x; bb = y; break; }
        }
        if cmp == NONE || !vp_is_with_ir_flags_kind(vr(cmp).kind) || vp_num_users(vr(cmp).def) != 1 || (a != mm_val && bb != mm_val) return false;
        pred := vr(cmp).flags.pred;
        if mm_val != bb pred = cmp_swapped(pred);
        if vp_num_users(pd) != 2 return false;
        mm_result := vp_find_user_vpi(vr(mm_op).def, VPI_COMPUTE_REDUCTION_RESULT);
        assert(mm_result != NONE, "MinOrMaxResult must be a user of MinOrMaxOp");
        sel_r := vp_single_user(vr(cmp).def);
        if sel_r == NONE || vr(sel_r).def == NONE || vp_num_users(vr(sel_r).def) != 2 return false;
        oks, c, iv_op, find_iv := vpm_select(vr(sel_r).def);
        if !oks || c != vr(cmp).def return false;
        fd := vp_def(find_iv);
        if fd == NONE || vr(fd).kind != .REDUCTION_PHI {
            t := find_iv; find_iv = iv_op; iv_op = t;
            pred = cmp_inverse(pred);
        }
        fiv_phi := vp_def(find_iv);
        if fiv_phi == NONE || vr(fiv_phi).kind != .REDUCTION_PHI || !rk_is_find_iv(vr(fiv_phi).rdx_kind) return false;
        fiv_result := vp_find_user_vpi(vp_op(fiv_phi, 1), VPI_COMPUTE_REDUCTION_RESULT);
        assert(fiv_result != NONE, "must be able to retrieve the FindIVResult VPInstruction");
        fk := vr(fiv_result).flags.rdx_kind;
        if fk != .SMAX && fk != .UMAX return false;
        okt, tx := vpm_unary(iv_op, vp_opc(.TRUNC));
        if okt iv_op = tx;
        ivr := vp_def(iv_op);
        if ivr == NONE || vr(ivr).kind != .WIDEN_INT_OR_FP_INDUCTION return false;
        valid: bool;
        if rk == .UMIN valid = pred == ICMP_UGE || pred == ICMP_UGT;
        else if rk == .UMAX valid = pred == ICMP_ULE || pred == ICMP_ULT;
        else if rk == .SMAX valid = pred == ICMP_SLE || pred == ICMP_SLT;
        else valid = pred == ICMP_SGE || pred == ICMP_SGT;
        if !valid return false;
        fiv_select := vp_find_find_iv_select(vp_op(fiv_phi, 1));
        fiv_cmp := vp_def(vp_op(fiv_select, 0));
        fiv_rdx := vp_def(vp_op(fiv_cmp, 0));
        vp_move_before(mm_result, vr(fiv_rdx).parent, fiv_rdx);
        strict := pred == ICMP_SLT || pred == ICMP_ULT || pred == ICMP_SGT || pred == ICMP_UGT;
        if strict {
            if !vp_handle_first_arg_min_or_max(phir, fiv_phi, ivr, mm_result, fiv_select, fiv_cmp, fiv_rdx) return false;
            continue;
        }
        b := vpb_before(fiv_rdx);
        mm_exiting := vp_op(mm_result, 0);
        fcmp := vpb_icmp(*b, ICMP_EQ, mm_exiting, vr(mm_result).def);
        sentinel := vp_op(fiv_cmp, 1);
        last_iv := vp_op(fiv_rdx, 0);
        fsel := vpb_select(*b, vr(fcmp).def, last_iv, sentinel);
        vp_set_operand(fiv_rdx, 0, vr(fsel).def);
    }
    return true;
}

// VPlanTransforms::optimizeFindIVReductions (with getExpressionIV and cloneBinOpForScalarIV)
vp_optimize_find_iv_reductions :: (pse: *Pse, l: Loop_Id) {
    region := vp_vector_loop_region();
    hm := vb(region).header_mask;
    // CheckSentinel: (found, sentinel, signed)
    check_sentinel :: (s: Scev_Id, use_max: bool) -> (bool, APInt, bool) {
        bw := type_bits(scalar_type(sc_type(s)));
        for signed: bool.[true, false] {
            sentinel: APInt;
            if use_max sentinel = ifx signed then ap_signed_min(bw) else ap_zero(bw);
            else sentinel = ifx signed then ap_signed_max(bw) else ap_all_ones(bw);
            r := ifx signed then sc_signed_range(s) else sc_unsigned_range(s);
            if !cr_contains(r, sentinel) return true, sentinel, signed;
        }
        return false, .{}, false;
    }
    is_affine :: (s: Scev_Id) -> bool { return !sc_is_cnc(s) && sc_is_addrec(s) && sc_is_affine(s); }
    phis := vp_block_phis(vp_entry_basic_block(region));
    for phir: phis {
        if vr(phir).kind != .REDUCTION_PHI || !rk_is_find_last(vr(phir).rdx_kind) continue;
        pd := vr(phir).def;
        pty := vp_scalar_type(pd);
        if type_kind(pty) == .PTR || is_fp_type(pty) continue;
        backedge := vp_op(phir, 1);
        fls := backedge;
        if hm != NONE {
            oks, c, t, f := vpm_select(backedge);
            if !oks || c != hm || f != pd || vp_def(t) == NONE || !vp_is_single_def_kind(vr(vp_def(t)).kind) continue;
            fls = t;
        }
        // m_SelectLike(Cond, PhiR, Expr) or m_SelectLike(Cond, Expr, PhiR)
        cond: Vp_Val = NONE; expr: Vp_Val = NONE;
        phi_is_true := false;
        select_like :: (v: Vp_Val) -> (bool, Vp_Val, Vp_Val, Vp_Val) {
            oks, c, t, f := vpm_select(v);
            if oks return true, c, t, f;
            bd := vp_def(v);
            if bd != NONE && vr(bd).kind == .BLEND && vp_blend_num_incoming(bd) == 2
                return true, vp_blend_mask(bd, 1), vp_blend_incoming(bd, 1), vp_blend_incoming(bd, 0);
            return false, NONE, NONE, NONE;
        }
        oksl, c, t, f := select_like(fls);
        if !oksl continue;
        if t == pd { cond = c; expr = f; phi_is_true = true; }
        else if f == pd { cond = c; expr = t; }
        else continue;
        // getExpressionIV
        iv_of_expr: Vp_Val = NONE;
        er := vp_def(expr);
        if er != NONE && vr(er).kind == .WIDEN && vp_is_ir_opcode(vr(er).opcode) && is_binary_op(vp_ir_opcode(vr(er).opcode)) {
            o := vp_ir_opcode(vr(er).opcode);
            if !(o == .UDIV || o == .SDIV || o == .UREM || o == .SREM) {
                cand := vp_op(er, 0); inv := vp_op(er, 1);
                cd := vp_def(cand);
                if cd == NONE || vr(cd).kind != .WIDEN_INT_OR_FP_INDUCTION { t2 := cand; cand = inv; inv = t2; }
                cd = vp_def(cand);
                if vp_is_defined_outside_loop_regions(inv) && cd != NONE && vr(cd).kind == .WIDEN_INT_OR_FP_INDUCTION iv_of_expr = cand;
            }
        }
        ivscev := vp_scev_for_value(ifx iv_of_expr != NONE then iv_of_expr else expr, pse, l);
        if !is_affine(ivscev) continue;
        step := sc_step_recurrence(ivscev);
        if !sc_is_known_non_zero(step) continue;
        use_max := sc_is_known_positive(step);
        has_sentinel, sentinel, use_signed := check_sentinel(ivscev, use_max);
        if iv_of_expr != NONE {
            fs := vp_scev_for_value(expr, pse, l);
            if is_affine(fs) {
                new_use_max := sc_is_known_positive(sc_step_recurrence(fs));
                ok2, s2, sg2 := check_sentinel(fs, new_use_max);
                if ok2 {
                    has_sentinel = true; sentinel = s2; use_signed = sg2; use_max = new_use_max;
                    ivscev = fs; iv_of_expr = NONE;
                }
            }
        }
        if !has_sentinel {
            fl := sc_flags(ivscev);
            if fl & SF_NSW use_signed = true;
            else if fl & SF_NUW use_signed = false;
            else continue;
        }
        is_rdx_result :: (x: Vp_Rec) -> bool { return vp_is_vpi(x, VPI_COMPUTE_REDUCTION_RESULT); }
        rdx_result := vp_find_recipe(backedge, is_rdx_result);
        new_fls := backedge;
        select_cond := cond;
        if !has_sentinel || iv_of_expr != NONE {
            flr := vp_def(fls);
            dl := vr(flr).dl;
            lb := vpb_before(flr);
            if phi_is_true select_cond = vr(vpb_not(*lb, select_cond)).def;
            if hm != NONE select_cond = vr(vpb_logical_and(*lb, hm, select_cond)).def;
            if select_cond != cond || iv_of_expr != NONE
                new_fls = vr(vpb_select(*lb, select_cond, ifx iv_of_expr != NONE then iv_of_expr else expr, pd, dl)).def;
        }
        mm: Recur_Kind = ifx use_max then (ifx use_signed then Recur_Kind.SMAX else .UMAX) else (ifx use_signed then Recur_Kind.SMIN else .UMIN);
        exit_dl := vr(rdx_result).dl;
        mb := vpb_before(rdx_result);
        reduced_iv := vr(vpb_nary(*mb, VPI_COMPUTE_REDUCTION_RESULT, .[new_fls], vpf_reduction(mm, false, false, 0), .[], exit_dl)).def;
        exiting_val := reduced_iv;
        if iv_of_expr != NONE {
            // cloneBinOpForScalarIV
            cl := vp_clone(er);
            if vp_op(cl, 0) == iv_of_expr vp_set_operand(cl, 0, reduced_iv);
            else { assert(vp_op(cl, 1) == iv_of_expr, "one operand must be WideIV"); vp_set_operand(cl, 1, reduced_iv); }
            vp_insert_after(cl, vp_def(reduced_iv));
            exiting_val = vr(cl).def;
        }
        new_rdx: Vp_Val;
        start := vp_op(phir, 0);
        if has_sentinel {
            sv := vp_const_int_ap(sentinel);
            cmp := vpb_icmp(*mb, ICMP_NE, reduced_iv, sv, exit_dl);
            new_rdx = vr(vpb_select(*mb, vr(cmp).def, exiting_val, start, exit_dl)).def;
            start = sv;
        } else {
            any_phi := vp_new_reduction_phi(NONE, .OR, vp_false(), vp_false(), .UNORDERED, 1, .{}, false);
            vp_insert_after(any_phi, phir);
            lb := vpb_before(vp_def(backedge));
            or_val := vr(vpb_or(*lb, vr(any_phi).def, select_cond)).def;
            vp_set_operand(any_phi, 1, or_val);
            orr := vpb_nary(*mb, VPI_COMPUTE_REDUCTION_RESULT, .[or_val], vpf_reduction(.OR, false, false, 0), .[], exit_dl);
            frz := vpb_nary(*mb, vp_opc(.FREEZE), .[vr(orr).def], .{}, .[], exit_dl);
            new_rdx = vr(vpb_select(*mb, vr(frz).def, exiting_val, start, exit_dl, "rdx.select")).def;
            start = vp_live_in(lv_recurrence_identity(mm, sc_type(ivscev), 0));
        }
        vp_rauw(vr(rdx_result).def, new_rdx);
        vp_erase_recipe(rdx_result);
        new_phi := vp_new_reduction_phi(vp_uv(pd), .FINDIV, start, new_fls, .UNORDERED, 1, .{}, vr(phir).has_uses_outside_chain);
        vp_insert_before(new_phi, phir);
        vp_rauw(pd, vr(new_phi).def);
        vp_erase_recipe(phir);
    }
}
