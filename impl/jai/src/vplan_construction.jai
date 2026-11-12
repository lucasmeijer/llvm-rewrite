// VPlan construction: PlainCFGBuilder, the initial skeleton, loop regions, header phi recipes, SCEV predicate
// finalization, middle/minimum-iteration/check blocks.
// Ported from llvm/lib/Transforms/Vectorize/VPlanConstruction.cpp (LLVM 23.1.5).

// VPIRMetadata(I): getMetadataToPropagate
vp_metadata_to_propagate :: (i: Value_Id) -> [..] Vp_Md {
    out: [..] Vp_Md; out.allocator = temp;
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(i, *all);
    supported :: string.["tbaa", "alias.scope", "noalias", "fpmath", "nontemporal", "invariant.load", "llvm.access.group", "mmra"];
    for all {
        if it.kind == MDK_DBG continue;
        ok := false;
        for s: supported if md_kind_id(s) == it.kind ok = true;
        if ok array_add(*out, .{it.kind, it.md});
    }
    return out;
}
vp_set_md :: (r: Vp_Rec, kind: u32, node: Md_Id) {
    for *vr(r).md if it.kind == kind { it.node = node; return; }
    array_add(*vr(r).md, .{kind, node});
}
vp_get_md :: (r: Vp_Rec, kind: u32) -> Md_Id { for vr(r).md if it.kind == kind return it.node; return NONE; }
inst_dl :: (i: Value_Id) -> Md_Id { return get_metadata(i, MDK_DBG); }

// VPIRFlags(Instruction &I)
vp_flags_from_inst :: (i: Value_Id) -> Vp_Flags {
    o := inst_op(i);
    if o == .FCMP return vpf_fcmp(inst_pred(i), inst_fmf(i));
    if o == .ICMP return vpf_cmp(inst_pred(i));
    if o == .OR return vpf_disjoint(inst_has_disjoint(i));
    if o == .ADD || o == .SUB || o == .MUL || o == .SHL return vpf_wrap(inst_has_nuw(i), inst_has_nsw(i));
    if o == .TRUNC return vpf_trunc(inst_has_nuw(i), inst_has_nsw(i));
    if o == .UDIV || o == .SDIV || o == .LSHR || o == .ASHR return vpf_exact(inst_has_exact(i));
    if o == .GEP return vpf_gep(gep_nowrap_flags(i));
    if o == .ZEXT || o == .UITOFP return vpf_nneg(inst_has_nneg(i));
    if is_fp_math_operator(i) return vpf_fmf(inst_fmf(i));
    return .{};
}

// ---------------------------------------------------------------- LoopVersioning's noalias metadata

// The alias-scope part of LoopVersioning (LoopVersioning.cpp): prepareNoAliasMetadata / getNoAliasMetadataFor
Lv_Noalias :: struct {
    prepared: bool;
    ptr_to_group: Table(Value_Id, s64);
    group_scope: [..] Md_Id;
    lists: [..] Md_Id;                 // GroupToNonAliasingScopeList (NONE = none)
}
lv_prepare_no_alias_metadata :: (n: *Lv_Noalias, rt: *Rpc) {
    n.prepared = true;
    n.ptr_to_group.allocator = temp; n.group_scope.allocator = temp; n.lists.allocator = temp;
    domain := md_self_ref_loop_id(Md_Id.[NONE, md_string("LVerDomain")]);
    for g, gi: rt.groups {
        array_add(*n.group_scope, md_self_ref_loop_id(Md_Id.[NONE, domain]));
        for m: g.members table_set(*n.ptr_to_group, rt.pointers[m].ptr, gi);
    }
    non_aliasing := NewArray(rt.groups.count, [..] Md_Id,, allocator = temp);
    has := NewArray(rt.groups.count, bool,, allocator = temp);
    for c: rt.checks {
        non_aliasing[c[0]].allocator = temp;
        array_add(*non_aliasing[c[0]], n.group_scope[c[1]]);
        has[c[0]] = true;
    }
    for k: 0..rt.groups.count-1 array_add(*n.lists, ifx has[k] then md_tuple(non_aliasing[k], false) else NONE);
}
lv_no_alias_metadata_for :: (n: *Lv_Noalias, i: Value_Id) -> (Md_Id, Md_Id) {
    if !lver_opts.annotate_no_alias || !n.prepared return NONE, NONE;
    ptr := ifx inst_op(i) == .LOAD then op(i, 0) else op(i, 1);
    found, gi := table_find(*n.ptr_to_group, ptr);
    if !found return NONE, NONE;
    scope := md_concatenate(get_metadata(i, md_kind_id("alias.scope")), md_tuple(Md_Id.[n.group_scope[gi]], false));
    na: Md_Id = NONE;
    if n.lists[gi] != NONE na = md_concatenate(get_metadata(i, md_kind_id("noalias")), n.lists[gi]);
    return scope, na;
}

// ---------------------------------------------------------------- PlainCFGBuilder

Vp_Cfg_Builder :: struct {
    li: *Loop_Info;
    l: Loop_Id;
    lver: *Lv_Noalias;
    bb2vpbb: Table(Value_Id, Vp_Blk);
    irdef2vpv: Table(Value_Id, Vp_Val);
    phis_to_fix: [..] Value_Id;
    b: Vp_Builder;
}

vpcb_get_or_create_vpbb :: (c: *Vp_Cfg_Builder, bb: Value_Id) -> Vp_Blk {
    found, x := table_find(*c.bb2vpbb, bb);
    if found return x;
    v := vp_create_basic_block(ir.v_name[bb]);
    table_set(*c.bb2vpbb, bb, v);
    return v;
}
vpcb_set_preds_from_bb :: (c: *Vp_Cfg_Builder, vpbb: Vp_Blk, bb: Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    list: [..] Vp_Blk; list.allocator = temp;
    for preds array_add(*list, vpcb_get_or_create_vpbb(c, it));
    assert(vb(vpbb).preds.count == 0, "Block predecessors already set.");
    for list array_add(*vb(vpbb).preds, it);
}
vpcb_operand :: (c: *Vp_Cfg_Builder, v: Value_Id) -> Vp_Val {
    found, x := table_find(*c.irdef2vpv, v);
    if found return x;
    nv := vp_live_in(v);
    table_set(*c.irdef2vpv, v, nv);
    return nv;
}
vpcb_is_header_bb :: (c: *Vp_Cfg_Builder, bb: Value_Id) -> bool {
    l := li_loop_for(c.li, bb);
    return l != NONE && bb == li_header(c.li, l);
}

// PlainCFGBuilder::createVPInstructionsForVPBB
vpcb_create_instructions :: (c: *Vp_Cfg_Builder, vpbb: Vp_Blk, bb: Value_Id) {
    c.b = vpb_at_end(vpbb);
    for i: block_insts(bb) {
        o := inst_op(i);
        if o == .BR continue;
        if o == .CONDBR {
            cond := vpcb_operand(c, op(i, 0));
            vpb_nary(*c.b, VPI_BRANCH_ON_COND, .[cond], .{}, vp_metadata_to_propagate(i), inst_dl(i), "", NONE, i);
            continue;
        }
        if o == .SWITCH {
            if nops(i) <= 2 continue;
            vp_unported("switch terminators inside the loop");
        }
        new_r: Vp_Rec;
        if o == .PHI {
            new_r = vpb_scalar_phi(*c.b, .[], inst_dl(i), "vec.phi", vp_flags_from_inst(i), vtype(i));
            vp_set_underlying(vr(new_r).def, i);
            if vpcb_is_header_bb(c, inst_block(i)) {
                array_add(*c.phis_to_fix, i);
            } else {
                m: Table(Vp_Blk, Vp_Val); m.allocator = temp;
                for k: 0..cast(s64) phi_num_incoming(i) - 1 {
                    found, pb := table_find(*c.bb2vpbb, phi_block(i, cast(u32) k));
                    table_set(*m, pb, vpcb_operand(c, phi_value(i, cast(u32) k)));
                }
                for p: vb(vpbb).preds {
                    _, x := table_find(*m, vp_exiting_basic_block(p));
                    vp_add_operand(new_r, x);
                }
            }
        } else {
            md := vp_metadata_to_propagate(i);
            if (o == .LOAD || o == .STORE) && c.lver {
                scope, na := lv_no_alias_metadata_for(c.lver, i);
                if scope != NONE set_vp_md_list(*md, md_kind_id("alias.scope"), scope);
                if na != NONE set_vp_md_list(*md, md_kind_id("noalias"), na);
            }
            ops: [..] Vp_Val; ops.allocator = temp;
            for k: 0..cast(s64) nops(i) - 1 array_add(*ops, vpcb_operand(c, op(i, cast(u32) k)));
            if is_cast_op(o) {
                new_r = vpb_scalar_cast(*c.b, o, ops[0], vtype(i), inst_dl(i), vp_flags_from_inst(i), md);
                vp_set_underlying(vr(new_r).def, i);
            } else if o == .LOAD {
                new_r = vpb_scalar_load(*c.b, vtype(i), ops[0], inst_dl(i), md);
                vp_set_underlying(vr(new_r).def, i);
            } else {
                new_r = vpb_nary(*c.b, vp_opc(o), ops, vp_flags_from_inst(i), md, inst_dl(i), "", vtype(i), i);
            }
        }
        table_set(*c.irdef2vpv, i, vr(new_r).def);
    }
}
set_vp_md_list :: (md: *[..] Vp_Md, kind: u32, node: Md_Id) {
    for * md.* if it.kind == kind { it.node = node; return; }
    array_add(md, .{kind, node});
}

// PlainCFGBuilder::buildPlainCFG
vpcb_build_plain_cfg :: (c: *Vp_Cfg_Builder) {
    entry := vpl.entry;
    table_set(*c.bb2vpbb, vb(entry).irbb, entry);
    for vpl.exit_blocks table_set(*c.bb2vpbb, vb(it).irbb, it);
    ph := li_loop_preheader(c.li, c.l);
    for i: block_insts(ph) {
        if type_kind(vtype(i)) == .VOID continue;
        table_set(*c.irdef2vpv, i, vp_live_in(i));
    }
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(c.li, c.l, *rpo);
    for bb: rpo {
        vpbb := vpcb_get_or_create_vpbb(c, bb);
        vpcb_set_preds_from_bb(c, vpbb, bb);
        vpcb_create_instructions(c, vpbb, bb);
        t := block_terminator(bb);
        if inst_op(t) == .SWITCH vp_unported("switch terminators inside the loop");
        if inst_op(t) == .BR {
            array_add(*vb(vpbb).succs, vpcb_get_or_create_vpbb(c, get_successor(t, 0)));
            continue;
        }
        s0 := vpcb_get_or_create_vpbb(c, get_successor(t, 0));
        s1 := vpcb_get_or_create_vpbb(c, get_successor(t, 1));
        array_add(*vb(vpbb).succs, s0); array_add(*vb(vpbb).succs, s1);
    }
    for eb: vpl.exit_blocks vpcb_set_preds_from_bb(c, eb, vb(eb).irbb);
    // fixHeaderPhis
    for phi: c.phis_to_fix {
        _, v := table_find(*c.irdef2vpv, phi);
        pr := vp_def(v);
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(inst_block(phi), *preds);
        for p: preds vp_add_operand(pr, vpcb_operand(c, phi_incoming_value_for_block(phi, p)));
    }
    array_add(*vb(entry).succs, vpcb_get_or_create_vpbb(c, li_header(c.li, c.l)));
    for eb: vpl.exit_blocks {
        for r: vp_block_phis(eb) {
            phi := vr(r).ir_inst;
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(vb(eb).irbb, *preds);
            for p: preds vp_add_operand(r, vpcb_operand(c, phi_incoming_value_for_block(phi, p)));
        }
    }
}

// canonicalHeaderAndLatch
vp_canonical_header_and_latch :: (header: Vp_Blk, dt: *Vp_Dom_Tree) -> bool {
    preds := vb(header).preds;
    if preds.count != 2 return false;
    ph := preds[0]; latch := preds[1];
    if !vp_dt_dominates(dt, ph, header) || !vp_dt_dominates(dt, header, latch) {
        t := ph; ph = latch; latch = t;
        if !vp_dt_dominates(dt, ph, header) || !vp_dt_dominates(dt, header, latch) return false;
        vp_swap_preds(header);
        for vp_block_phis(header) vp_swap_operands(it);
    }
    if vp_single_succ(latch) != NONE || vb(latch).succs[0] != header return true;
    term := vp_terminator(latch);
    nr := vp_new_instruction(VPI_NOT, .[vp_op(term, 0)]);
    vp_insert_before(nr, term);
    vp_set_operand(term, 0, vr(nr).def);
    vp_swap_succs(latch);
    return true;
}

// createLoopRegion
vp_create_loop_region_for :: (header: Vp_Blk, dl_in: Md_Id) {
    ph := vb(header).preds[0];
    latch := vb(header).preds[1];
    outermost_header, _ := vpbu_plain_cfg_header_and_latch();
    vpbu_disconnect(ph, header);
    vpbu_disconnect(latch, header);
    is_outermost := header == outermost_header;
    dl := dl_in;
    if !is_outermost vp_unported("nested loop regions (outer-loop vectorization)");
    r := vp_create_loop_region(vv(vpl.vector_trip_count).ty, dl);
    vpbu_transfer_successors(latch, r);
    vpbu_connect(ph, r);
    vp_region_set_entry(r, header);
    vp_region_set_exiting(r, latch);
    for vp_depth_first_shallow(header) vb(it).parent = r;
    term := vp_terminator(latch);
    b := vpb_before(term);
    inc := vpb_add(*b, vb(r).can_iv, vpl.vfxuf, dl, "index.next", true, false);
    if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) {
        cmp := vpb_icmp(*b, ICMP_EQ, vr(inc).def, vpl.vector_trip_count);
        vp_set_operand(term, 1, vr(cmp).def);
    } else {
        ldl := vr(term).dl;
        vpb_nary(*b, VPI_BRANCH_ON_COUNT, .[vr(inc).def, vpl.vector_trip_count], .{}, .[], ldl);
        vp_erase_recipe(term);
    }
}

// createExtractsForLiveOuts
vp_create_extracts_for_live_outs :: (middle: Vp_Blk) {
    b := vpb_at(middle, vp_first_non_phi(middle));
    for eb: vpl.exit_blocks {
        if !vp_contains_blk(vb(eb).preds, middle) continue;
        for r: vp_block_phis(eb) {
            exiting := vp_phi_incoming_value_for_block(r, middle);
            if vp_is_ir_value(exiting) continue;
            e1 := vpb_nary(*b, VPI_EXTRACT_LAST_PART, .[exiting]);
            e2 := vpb_nary(*b, VPI_EXTRACT_LAST_LANE, .[vr(e1).def]);
            vp_phi_set_incoming_value_for_block(r, middle, vr(e2).def);
        }
    }
}

// VPPhiAccessors
vp_phi_num_incoming :: (r: Vp_Rec) -> s64 {
    if vp_is_widen_induction_kind(vr(r).kind) return 1;
    return vp_nops(r);
}
vp_phi_incoming_block :: (r: Vp_Rec, idx: s64) -> Vp_Blk { return vp_cfg_predecessor(vr(r).parent, idx); }
vp_phi_incoming_value_for_block :: (r: Vp_Rec, b: Vp_Blk) -> Vp_Val {
    for k: 0..vp_phi_num_incoming(r)-1 if vp_phi_incoming_block(r, k) == b return vp_op(r, k);
    fatal("internal: VPlan phi has no incoming value for the block");
    return NONE;
}
vp_phi_set_incoming_value_for_block :: (r: Vp_Rec, b: Vp_Blk, v: Vp_Val) {
    for k: 0..vp_phi_num_incoming(r)-1 if vp_phi_incoming_block(r, k) == b { vp_set_operand(r, k, v); return; }
    fatal("internal: VPlan phi has no incoming value for the block");
}
// VPPhiAccessors::removeIncomingValueFor
vp_phi_remove_incoming_value_for :: (r: Vp_Rec, b: Vp_Blk) {
    parent := vr(r).parent;
    idx := vp_index_of(vb(parent).preds, b);
    vp_remove_operand(r, idx);
}

// addInitialSkeleton
vp_add_initial_skeleton :: (induction_ty: Type_Id, pse: *Pse, l: Loop_Id) {
    dt := vp_dt_build();
    header := vp_single_succ(vpl.entry);
    vp_canonical_header_and_latch(header, *dt);
    latch := vb(header).preds[1];
    vec_ph := vp_create_basic_block("vector.ph");
    vpbu_insert_block_after(vec_ph, vpl.entry);
    middle := vp_create_basic_block("middle.block");
    if vb(latch).succs.count == 2 {
        latch_exit := vb(latch).succs[0];
        vpbu_insert_on_edge(latch, latch_exit, middle);
    } else {
        vpbu_connect(latch, middle);
        vp_swap_succs(latch);
        b := vpb_at_end(latch);
        vpb_nary(*b, VPI_BRANCH_ON_COND, .[vp_false()]);
    }
    btc := pse_get_symbolic_max_backedge_taken_count(pse);
    tc := sc_get_trip_count_from_exit_count_ty(btc, induction_ty, l);
    vpl.trip_count = vp_get_or_create_value_for_scev(tc);
    scalar_ph := vp_create_basic_block("scalar.ph");
    vpbu_connect(scalar_ph, vpl.scalar_header);
    vpbu_connect(middle, scalar_ph);
    vpbu_connect(vpl.entry, scalar_ph);
    vp_swap_succs(vpl.entry);
    vp_create_extracts_for_live_outs(middle);
    mb := vpb_at(middle, vp_first_non_phi(middle));
    sb := vpb_at_end(scalar_ph);
    hp := vp_block_phis(header);
    sp := vp_block_phis(vpl.scalar_header);
    assert(hp.count == sp.count, "zip_equal of header phis and scalar header phis");
    for k: 0..hp.count-1 {
        vphi := hp[k];
        be := vp_op(vphi, 1);
        r1 := vpb_nary(*mb, VPI_EXTRACT_LAST_PART, .[be]);
        r2 := vpb_nary(*mb, VPI_EXTRACT_LAST_LANE, .[vr(r1).def]);
        resume := vpb_scalar_phi(*sb, .[vr(r2).def, vp_op(vphi, 0)], vr(vphi).dl);
        vp_add_operand(sp[k], vr(resume).def);
    }
}

// simplifyLiveInsWithSCEV
vp_simplify_live_ins_with_scev :: (pse: *Pse) {
    order: [..] Value_Id; order.allocator = temp;
    for vpl.live_in_order array_add(*order, it);
    for v: order {
        lv := vp_get_live_in(v);
        e := vp_scev_for_value(lv, pse);
        if sc_is_const(e) {
            nv := vp_live_in(sc_value(e));
            vp_rauw(lv, nv);
        }
    }
}

// VPlanTransforms::buildVPlan0
vp_build_vplan0 :: (li: *Loop_Info, l: Loop_Id, induction_ty: Type_Id, pse: *Pse, lver: *Lv_Noalias) -> *Vp_Plan {
    p := vp_plan_new(li, l, induction_ty);
    c: Vp_Cfg_Builder;
    c.li = li; c.l = l; c.lver = lver;
    c.bb2vpbb.allocator = temp; c.irdef2vpv.allocator = temp; c.phis_to_fix.allocator = temp;
    vpcb_build_plain_cfg(*c);
    vp_add_initial_skeleton(induction_ty, pse, l);
    vp_simplify_live_ins_with_scev(pse);
    return p;
}

// ---------------------------------------------------------------- header phi recipes

// VPWidenIntOrFpInductionRecipe / VPWidenPointerInductionRecipe constructors
vp_new_widen_int_or_fp_induction :: (phi: Value_Id, start: Vp_Val, step: Vp_Val, vf: Vp_Val, ind: s32, flags: Vp_Flags, dl: Md_Id, trunc: Value_Id = NONE) -> Vp_Rec {
    ty := ifx trunc != NONE then vtype(trunc) else vp_scalar_type(start);
    r := vp_new_single_def(.WIDEN_INT_OR_FP_INDUCTION, .[start, step], ty, phi, dl);
    vp_add_operand(r, vf);
    vr(r).ind = ind; vr(r).flags = flags; vr(r).ir_inst = trunc;
    return r;
}
vp_new_widen_pointer_induction :: (phi: Value_Id, start: Vp_Val, step: Vp_Val, num_unrolled: Vp_Val, ind: s32, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.WIDEN_POINTER_INDUCTION, .[start, step], vp_scalar_type(start), phi, dl);
    vp_add_operand(r, num_unrolled);
    vr(r).ind = ind;
    return r;
}
vp_add_ind :: (d: Ind_Desc) -> s32 { array_add(*vpl.inds, d); return cast(s32) (vpl.inds.count - 1); }

// createWidenInductionRecipe
vp_create_widen_induction_recipe :: (phi: Value_Id, phir: Vp_Rec, start: Vp_Val, d: *Ind_Desc, pse: *Pse, dl: Md_Id) -> Vp_Rec {
    step := vp_get_or_create_value_for_scev(d.step);
    be := vp_op(phir, 1);
    ind := vp_add_ind(d.*);
    replace_extracts :: (wide: Vp_Rec, be: Vp_Val, d: *Ind_Desc) {
        is_pred := d.preds.count > 0;
        users: [..] Vp_Rec; users.allocator = temp;
        for vv(be).users array_add(*users, it);
        for u: users {
            if vr(u).dead || !vpm_vpi_r(u, VPI_EXTRACT_LAST_PART, 1) continue;
            elp := u;
            elp_user := vp_single_user(vr(elp).def);
            if !vpm_vpi_r(elp_user, VPI_EXTRACT_LAST_LANE, 1) continue;
            ell := elp_user;
            if is_pred {
                skip := false;
                for lu: vv(vr(ell).def).users if vp_is_exit_block(vr(lu).parent) skip = true;
                if skip continue;
            }
            b := vpb_before(ell);
            x := vpb_nary(*b, VPI_EXITING_IV_VALUE, .[vr(wide).def]);
            vp_rauw(vr(ell).def, vr(x).def);
            vp_erase_recipe(ell);
            vp_erase_recipe(elp);
        }
    }
    if d.kind == .PTR {
        w := vp_new_widen_pointer_induction(phi, start, step, vpl.vfxuf, ind, dl);
        replace_extracts(w, be, d);
        return w;
    }
    ok, a, _ := vpm_binary(be, vp_opc(.ADD));
    if ok && a == vr(phir).def vp_set_operand(vp_def(be), 1, step);
    flags := vp_flags_from_ind_desc(d);
    w := vp_new_widen_int_or_fp_induction(phi, start, step, vpl.vf, ind, flags, dl);
    replace_extracts(w, be, d);
    return w;
}

// VPFirstOrderRecurrencePHIRecipe / VPReductionPHIRecipe constructors
vp_new_first_order_recurrence_phi :: (phi: Value_Id, start: Vp_Val, be: Vp_Val) -> Vp_Rec {
    r := vp_new_single_def(.FIRST_ORDER_RECURRENCE_PHI, .[start], vp_scalar_type(start), phi);
    vp_add_operand(r, be);
    return r;
}
vp_new_reduction_phi :: (phi: Value_Id, kind: Recur_Kind, start: Vp_Val, be: Vp_Val, style: Vp_Rdx_Style, scale: u32, flags: Vp_Flags, outside: bool) -> Vp_Rec {
    r := vp_new_single_def(.REDUCTION_PHI, .[start], vp_scalar_type(start), phi);
    vp_add_operand(r, be);
    vr(r).rdx_kind = kind; vr(r).rdx_style = style; vr(r).rdx_scale = scale; vr(r).flags = flags;
    vr(r).has_uses_outside_chain = outside;
    return r;
}
// getReductionStyle
vp_reduction_style :: (in_loop: bool, ordered: bool) -> Vp_Rdx_Style {
    if ordered return .ORDERED;
    if in_loop return .IN_LOOP;
    return .UNORDERED;
}

// sinkRecurrenceUsersAfterPrevious
vp_sink_recurrence_users_after_previous :: (for_r: Vp_Rec, previous_in: Vp_Rec, dt: *Vp_Dom_Tree) -> bool {
    previous := previous_in;
    wl: [..] Vp_Rec; wl.allocator = temp;
    seen: Table(Vp_Rec, bool); seen.allocator = temp;
    table_set(*seen, previous, true);
    array_add(*wl, for_r);
    k := 0;
    while k < wl.count {
        cur := wl[k]; k += 1;
        for u: vv(vr(cur).def).users {
            if u == previous return false;
            if vp_is_header_phi(u) || table_contains(*seen, u) continue;
            table_set(*seen, u, true);
            if vp_dt_properly_dominates(dt, previous, u) continue;
            if vp_cannot_hoist_or_sink_recipe(u, true) return false;
            array_add(*wl, u);
        }
    }
    vp_sort_by_dominance(*wl, dt);
    for sc: wl {
        if sc == for_r continue;
        vp_move_after(sc, previous);
        previous = sc;
    }
    return true;
}
// llvm::sort with a properlyDominates comparator (a strict weak order on recipes of one dominance chain)
vp_sort_by_dominance :: (list: *[..] Vp_Rec, dt: *Vp_Dom_Tree) {
    // insertion sort: stable and exact for a total order; LLVM's std::sort gives the same result for a strict total order
    for i: 1..list.count-1 {
        x := list.*[i];
        j := i - 1;
        while j >= 0 && vp_dt_properly_dominates(dt, x, list.*[j]) { list.*[j + 1] = list.*[j]; j -= 1; }
        list.*[j + 1] = x;
    }
}
// hoistPreviousBeforeFORUsers
vp_hoist_previous_before_for_users :: (for_r: Vp_Rec, previous: Vp_Rec, dt: *Vp_Dom_Tree) -> bool {
    if vp_cannot_hoist_or_sink_recipe(previous) return false;
    cands: [..] Vp_Rec; cands.allocator = temp;
    visited: Table(Vp_Rec, bool); visited.allocator = temp;
    hoist_point: Vp_Rec = NONE;
    for u: vv(vr(for_r).def).users if hoist_point == NONE || vp_dt_properly_dominates(dt, u, hoist_point) hoist_point = u;
    needs_hoisting :: (v: Vp_Val, hp: Vp_Rec, dt: *Vp_Dom_Tree, visited: *Table(Vp_Rec, bool)) -> Vp_Rec {
        c := vp_def(v);
        if c == NONE return NONE;
        if table_contains(visited, c) return NONE;
        table_set(visited, c, true);
        if vp_dt_properly_dominates(dt, c, hp) return NONE;
        return c;
    }
    if needs_hoisting(vr(previous).def, hoist_point, dt, *visited) == NONE return true;
    array_add(*cands, previous);
    k := 0;
    while k < cands.count {
        cur := cands[k]; k += 1;
        if vp_cannot_hoist_or_sink_recipe(cur) return false;
        for o: vr(cur).ops {
            if o == vr(for_r).def return false;
            r := needs_hoisting(o, hoist_point, dt, *visited);
            if r != NONE {
                if vp_num_defined_values(r) != 1 return false;
                array_add(*cands, r);
            }
        }
    }
    vp_sort_by_dominance(*cands, dt);
    for cands vp_move_before(it, vr(hoist_point).parent, hoist_point);
    return true;
}
// tryToSinkOrHoistRecurrenceUsers
vp_try_to_sink_or_hoist_recurrence_users :: (header: Vp_Blk, dt: *Vp_Dom_Tree) -> bool {
    fors: [..] Vp_Rec; fors.allocator = temp;
    for vp_block_phis(header) if vr(it).kind == .FIRST_ORDER_RECURRENCE_PHI array_add(*fors, it);
    for f: fors {
        previous := vp_def(vp_op(f, 1));
        while previous != NONE && vr(previous).kind == .FIRST_ORDER_RECURRENCE_PHI previous = vp_def(vp_op(previous, 1));
        insert_block := vr(f).parent;
        insert_pt := vp_first_non_phi(insert_block);
        if previous != NONE {
            if !vp_sink_recurrence_users_after_previous(f, previous, dt) && !vp_hoist_previous_before_for_users(f, previous, dt) return false;
            insert_block = vr(previous).parent;
            insert_pt = ifx vp_is_header_phi(previous) then vp_first_non_phi(insert_block) else vr(previous).next;
        }
        b := vpb_at(insert_block, insert_pt);
        splice := vpb_nary(*b, VPI_FIRST_ORDER_RECURRENCE_SPLICE, .[vr(f).def, vp_op(f, 1)]);
        not_splice :: (r: Vp_Rec, idx: s64, data: *void) -> bool { return r != << cast(*Vp_Rec) data; }
        vp_replace_uses_with_if(vr(f).def, vr(splice).def, not_splice, *splice);
    }
    return true;
}

// VPlanTransforms::createHeaderPhiRecipes
vp_create_header_phi_recipes :: (pse: *Pse, li: *Loop_Info, l: Loop_Id, dt: *Vp_Dom_Tree, lvl: *Lvl, in_loop_reductions: [] Value_Id, allow_reordering: bool) -> bool {
    header, latch := vpbu_plain_cfg_header_and_latch();
    for phir: vp_block_phis(header) {
        phi := vp_underlying_instr(phir);
        start := vp_op(phir, 0);
        be := vp_op(phir, 1);
        hr: Vp_Rec;
        if lvl_is_fixed_order_recurrence(lvl, phi) {
            hr = vp_new_first_order_recurrence_phi(phi, start, be);
        } else {
            d := lvl_find_induction(lvl, phi);
            if d {
                hr = vp_create_widen_induction_recipe(phi, phir, start, d, pse, vr(phir).dl);
            } else {
                rd := lvl_find_reduction(lvl, phi);
                assert(rd != null, "only reductions are expected now");
                ordered := !allow_reordering && rd.is_ordered;
                flags := ifx is_fp_type(vtype(phi)) then vpf_fmf(rd.fmf) else Vp_Flags.{};
                hr = vp_new_reduction_phi(phi, rd.kind, start, be, vp_reduction_style(array_find(in_loop_reductions, phi), ordered), 1,
                                          flags, rd.phi_has_uses_outside_chain);
            }
        }
        vp_insert_before(hr, phir);
        vp_rauw(vr(phir).def, vr(hr).def);
        vp_erase_recipe(phir);
    }
    if !vp_try_to_sink_or_hoist_recurrence_users(header, dt) return false;
    hp := vp_block_phis(header);
    sp := vp_block_phis(vp_scalar_preheader());
    if hp.count != sp.count return true;
    for k: 0..hp.count-1 {
        resume := sp[k];
        if vr(hp[k]).kind == .FIRST_ORDER_RECURRENCE_PHI {
            vr(resume).name = "scalar.recur.init";
            vr(vp_def(vp_op(resume, 0))).name = "vector.recur.extract";
            continue;
        }
        vr(resume).name = ifx vp_is_widen_induction_kind(vr(hp[k]).kind) then "bc.resume.val" else "bc.merge.rdx";
    }
    return true;
}

// VPlanTransforms::finalizeSCEVPredicates
vp_finalize_scev_predicates :: (pse: *Pse, opt_for_size: bool, threshold: s64) -> bool {
    header, _ := vpbu_plain_cfg_header_and_latch();
    for r: vp_block_phis(header) {
        if !vp_is_widen_induction_kind(vr(r).kind) continue;
        d := *vpl.inds[vr(r).ind];
        if d.preds.count == 0 continue;
        for d.preds pse_add_predicate(pse, it);
    }
    total := sc_union_complexity(pse.preds);
    if total && opt_for_size return false;
    if total > threshold return false;
    return true;
}
// SCEVUnionPredicate::getComplexity: the sum of the predicates' complexities (compare: 1, wrap: 1 per flag kind)
sc_union_complexity :: (preds: [] u32) -> s64 {
    return preds.count;
}

// areAllLoadsDereferenceable
vp_are_all_loads_dereferenceable :: (header: Vp_Blk, lvl: *Lvl, pse: *Pse) -> bool {
    for bb: vp_rpo_plain_cfg_loop_body(header) for r: vp_block_recipes(bb) {
        if !(vp_is_instruction_with_type(r) && vr(r).opcode == vp_opc(.LOAD)) continue;
        ptr := vp_op(r, 0);
        ps := vp_scev_for_value(ptr, pse, lvl.l);
        if sc_is_cnc(ps) return false;
        ld := vp_uv(vr(r).def);
        size := sc_get_constant_t(dl_index_type(sc_type(ps)), dl_type_store_size(vp_scalar_type(vr(r).def)));
        if lv_is_dereferenceable_and_aligned_in_loop_scev(lvl, ps, inst(ld).align, size) continue;
        return false;
    }
    return true;
}

// handleUncountableEarlyExits (the ReadOnly style)
vp_handle_uncountable_early_exits :: (header: Vp_Blk, latch: Vp_Blk, middle: Vp_Blk) -> bool {
    lb := vpb_before(vp_terminator(latch));
    Exit_Info :: struct { exiting: Vp_Blk; exit: Vp_Blk; cond: Vp_Val; }
    exits: [..] Exit_Info; exits.allocator = temp;
    for eb: vpl.exit_blocks {
        preds: [..] Vp_Blk; preds.allocator = temp;
        for vb(eb).preds array_add(*preds, it);
        for p: preds {
            if p == middle continue;
            true_succ := vb(p).succs[0];
            term := vp_terminator(p);
            assert(vpm_vpi_r(term, VPI_BRANCH_ON_COND, 1), "Terminator must be BranchOnCond");
            c := vp_op(term, 0);
            eb2 := vpb_before(term);
            if true_succ != eb c = vr(vpb_not(*eb2, c)).def;
            mc := vpb_nary(*eb2, VPI_MASKED_COND, .[c]);
            array_add(*exits, .{p, eb, vr(mc).def});
        }
    }
    assert(exits.count > 0, "must have at least one early exit");
    rpo := vp_rpo(header, false);
    rpo_idx :: (rpo: [] Vp_Blk, b: Vp_Blk) -> s64 { for rpo if it == b return it_index; return -1; }
    // llvm::sort (stable enough: distinct keys)
    for i: 1..exits.count - 1 {
        j := i;
        while j > 0 && rpo_idx(rpo, exits[j].exiting) < rpo_idx(rpo, exits[j - 1].exiting) {
            t := exits[j]; exits[j] = exits[j - 1]; exits[j - 1] = t;
            j -= 1;
        }
    }
    combined := exits[0].cond;
    for i: 1..exits.count - 1 combined = vr(vpb_logical_or(*lb, combined, exits[i].cond)).def;
    any_taken := vr(vpb_nary(*lb, VPI_ANY_OF, .[combined])).def;
    latch_br := vp_terminator(latch);
    assert(vp_is_vpi(latch_br, VPI_BRANCH_ON_COND), "Unexpected terminator");
    latch_taken := vp_op(latch_br, 0);
    ldl := vr(latch_br).dl;
    vp_erase_recipe(latch_br);
    le := vpb_at_end(latch);
    vpb_nary(*le, VPI_BRANCH_ON_TWO_CONDS, .[any_taken, latch_taken], .{}, .[], ldl);
    vb(latch).succs.count = 0;
    vee: [..] Vp_Blk; vee.allocator = temp;
    for i: 0..exits.count - 1 array_add(*vee, vp_new_block(.BASIC, ifx exits.count == 1 then "vector.early.exit" else tprint("vector.early.exit.%", i)));
    dispatch := ifx exits.count == 1 then vee[0] else vp_new_block(.BASIC, "vector.early.exit.check");
    vb(dispatch).preds.count = 0; array_add(*vb(dispatch).preds, latch);
    array_add(*vb(latch).succs, dispatch); array_add(*vb(latch).succs, middle); array_add(*vb(latch).succs, header);
    db := vpb_at(dispatch, vb(dispatch).first);
    fal := vr(vpb_nary(*db, VPI_FIRST_ACTIVE_LANE, .[combined], .{}, .[], NONE, "first.active.lane", dl_index_type(type_ptr(0)))).def;
    for ex, k: exits {
        for r: vp_block_phis(ex.exit) {
            inc := vp_phi_incoming_value_for_block(r, ex.exiting);
            new_inc := inc;
            if !vp_is_ir_value(inc) {
                xb := vpb_at_end(vee[k]);
                new_inc = vr(vpb_nary(*xb, VPI_EXTRACT_LANE, .[fal, inc], .{}, .[], NONE, "early.exit.value")).def;
            }
            vp_phi_remove_incoming_value_for(r, ex.exiting);
            vp_add_operand(r, new_inc);
        }
        vp_erase_recipe(vp_terminator(ex.exiting));
        vpbu_disconnect(ex.exiting, ex.exit);
        vpbu_connect(vee[k], ex.exit);
    }
    cur := dispatch;
    if exits.count > 1 for i: 0..exits.count - 2 {
        lane_val := vr(vpb_nary(*db, VPI_EXTRACT_LANE, .[fal, exits[i].cond], .{}, .[], NONE, "exit.cond.at.lane")).def;
        is_last := i + 2 == exits.count;
        false_bb := ifx is_last then vee[vee.count - 1] else vp_new_block(.BASIC, tprint("vector.early.exit.check.%", i));
        vpb_nary(*db, VPI_BRANCH_ON_COND, .[lane_val]);
        vb(cur).succs.count = 0; array_add(*vb(cur).succs, vee[i]); array_add(*vb(cur).succs, false_bb);
        vb(vee[i]).preds.count = 0; array_add(*vb(vee[i]).preds, cur);
        vb(false_bb).preds.count = 0; array_add(*vb(false_bb).preds, cur);
        cur = false_bb;
        db = vpb_at_end(cur);
    }
    return true;
}

// VPlanTransforms::handleEarlyExits
vp_handle_early_exits :: (style: Uncountable_Exit_Trait, lvl: *Lvl, pse: *Pse) -> bool {
    middle := vpbu_plain_cfg_middle_block();
    if style != .NONE {
        header, latch := vpbu_plain_cfg_header_and_latch();
        if style == .READ_WRITE vp_unported("uncountable early exits with side effects (MaskedHandleExitInScalarLoop)");
        if !vp_are_all_loads_dereferenceable(header, lvl, pse) return false;
        return vp_handle_uncountable_early_exits(header, latch, middle);
    }
    for eb: vpl.exit_blocks {
        preds: [..] Vp_Blk; preds.allocator = temp;
        for vb(eb).preds array_add(*preds, it);
        for p: preds {
            if p == middle continue;
            for r: vp_block_phis(eb) vp_phi_remove_incoming_value_for(r, p);
            vp_erase_recipe(vp_terminator(p));
            vpbu_disconnect(p, eb);
        }
    }
    return true;
}

// VPlanTransforms::addMiddleCheck
vp_add_middle_check :: () {
    middle := vpbu_plain_cfg_middle_block();
    if vb(middle).succs.count == 1 return;
    latch := vp_single_pred(middle);
    ldl := vr(vp_terminator(latch)).dl;
    b := vpb_at_end(middle);
    cmp := vpb_icmp(*b, ICMP_EQ, vpl.trip_count, vpl.vector_trip_count, ldl, "cmp.n");
    vpb_nary(*b, VPI_BRANCH_ON_COND, .[vr(cmp).def], .{}, .[], ldl);
}

// VPlanTransforms::createLoopRegions
vp_create_loop_regions :: (dl: Md_Id) {
    dt := vp_dt_build();
    post: [..] Vp_Blk; post.allocator = temp;
    rpo := vp_rpo(vpl.entry, false);
    for < rpo array_add(*post, it);
    for h: post if vp_canonical_header_and_latch(h, *dt) vp_create_loop_region_for(h, dl);
    top := vp_vector_loop_region();
    vb(top).name = "vector loop";
    vb(vp_entry_basic_block(top)).name = "vector.body";
}

// insertCheckBlockBeforeVectorLoop
vp_insert_check_block_before_vector_loop :: (check: Vp_Blk) {
    vec_ph := vp_vector_preheader();
    scalar_ph := vp_scalar_preheader();
    pre := vp_single_pred(vec_ph);
    vpbu_insert_on_edge(pre, vec_ph, check);
    vpbu_connect(check, scalar_ph);
    vp_swap_succs(check);
    n := vb(scalar_ph).preds.count;
    for r: vp_block_phis(scalar_ph) vp_add_operand(r, vp_op(r, n - 2));
}

// VPlanTransforms::addMinimumIterationCheck
vp_add_minimum_iteration_check :: (vf: Ec, uf: u32, min_profitable_tc: Ec, requires_scalar_epilogue: bool, tail_folded: bool,
                                   l: Loop_Id, bypass_weights: [] u32, dl: Md_Id, pse: *Pse, check: Vp_Blk) {
    pred: u8 = xx ifx requires_scalar_epilogue then ICMP_ULE else ICMP_ULT;
    tcv := vpl.trip_count;
    tc := vp_scev_for_value(tcv, pse);
    tc_ty := sc_type(tc);
    vfxuf := sc_get_element_count(tc_ty, vf.n * uf, vf.scalable, SF_NUW);
    step := vfxuf;
    if cast(u64) uf * vf.n < min_profitable_tc.n {
        mp := sc_get_element_count(tc_ty, min_profitable_tc.n, min_profitable_tc.scalable, SF_NUW);
        step = sc_get_umax2(mp, vfxuf);
    }
    b := vpb_at_end(check);
    tc_check := vp_false();
    if !tail_folded {
        tcg := sc_apply_loop_guards(tc, l);
        if sc_is_known_predicate(pred, tcg, step) {
            tc_check = vp_true();
        } else if !sc_is_known_predicate(cmp_inverse(pred), tcg, step) {
            x: Vp_Scev_Expander; x.b = *b; x.dl = dl;
            min_tc := vpsx_try_to_expand(*x, step);
            if min_tc == NONE {
                eb := vpb_at_end(vpl.entry);
                min_tc = vr(vpb_insert(*eb, vp_new_expand_scev(step))).def;
            }
            tc_check = vr(vpb_icmp(*b, pred, tcv, min_tc, dl, "min.iters.check")).def;
        }
    }
    term := vpb_nary(*b, VPI_BRANCH_ON_COND, .[tc_check], .{}, .[], dl);
    if bypass_weights.count vp_set_md(term, md_kind_id(MD_PROF_NAME), md_branch_weights(bypass_weights, false));
}

// attachCheckBlock / attachVPCheckBlock
vp_attach_check_block :: (cond: Value_Id, check_irbb: Value_Id, add_branch_weights: bool) {
    cv := vp_live_in(cond);
    cb := vp_create_ir_basic_block(check_irbb);
    vp_attach_vp_check_block(cv, cb, add_branch_weights);
}
vp_attach_vp_check_block :: (cond: Vp_Val, check: Vp_Blk, add_branch_weights: bool) {
    vp_insert_check_block_before_vector_loop(check);
    dl := vv(vb(vp_vector_loop_region()).can_iv).dl;
    b := vpb_at_end(check);
    term := vpb_nary(*b, VPI_BRANCH_ON_COND, .[cond], .{}, .[], dl);
    if add_branch_weights vp_set_md(term, md_kind_id(MD_PROF_NAME), md_branch_weights(.[1, 127], false));
}

// MDBuilder::createBranchWeights(Weights, IsExpected)
md_branch_weights :: (w: [] u32, is_expected: bool) -> Md_Id {
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, md_string("branch_weights"));
    if is_expected array_add(*ops, md_string("expected"));
    for w array_add(*ops, md_value(const_int(type_int(32), it)));
    return md_tuple(ops, false);
}

// VPlanTransforms::foldTailByMasking (VPlanConstruction.cpp)
vp_fold_tail_by_masking :: () {
    assert(vpl.exit_blocks.count == 1, "only a single-exit block is supported currently");
    region := vp_vector_loop_region();
    header := vp_entry_basic_block(region);
    vp_split_at(header, vp_first_non_phi(header));
    hm := vp_create_header_mask(region);
    b := vpb_at(header, vp_first_non_phi(header));
    vpb_nary(*b, VPI_BRANCH_ON_COND, .[hm]);
    orig_latch := vp_exiting_basic_block(region);
    term := vp_terminator(orig_latch);
    okc, iv_inc, _ := vpm_branch_on_count(term);
    assert(okc, "Unexpected canonical iv increment");
    latch := vp_split_at(orig_latch, vp_def(iv_inc));
    vb(latch).name = "vector.latch";
    vpbu_connect(header, latch);
    // NeedsPhi: MapVector<VPValue *, SmallVector<VPUser *>>
    Need :: struct { v: Vp_Val; users: [..] Vp_Rec; }
    needs: [..] Need; needs.allocator = temp;
    add_need :: (needs: *[..] Need, v: Vp_Val, u: Vp_Rec) {
        for * needs.* if it.v == v { array_add(*it.users, u); return; }
        n: Need; n.v = v; n.users.allocator = temp; array_add(*n.users, u);
        array_add(needs, n);
    }
    for r: vp_block_phis(header) {
        if vp_is_widen_induction_kind(vr(r).kind) continue;
        add_need(*needs, vp_op(r, 1), r);
    }
    middle := vp_middle_block();
    for r: vp_block_recipes(middle) {
        ok, _ := vpm_vpi(vr(r).def, VPI_EXTRACT_LAST_PART, 1);
        if vr(r).def != NONE && ok add_need(*needs, vp_op(r, 0), r);
    }
    lb := vpb_at(latch, vb(latch).first);
    for nd: needs {
        if vp_is_ir_value(nd.v) continue;
        tail := vp_poison(vp_scalar_type(nd.v));
        flags: Vp_Flags;
        rdx: Vp_Rec = NONE;
        for u: nd.users if vr(u).kind == .REDUCTION_PHI { rdx = u; break; }
        if rdx != NONE && vr(rdx).rdx_style == .UNORDERED { tail = vr(rdx).def; flags = vr(rdx).flags; }
        phi := vpb_scalar_phi(*lb, .[nd.v, tail], NONE, "", flags);
        for u: nd.users vp_replace_uses_of_with(u, nd.v, vr(phi).def);
    }
    mb := vpb_before(vp_terminator(middle));
    r := vb(middle).first;
    while r != NONE {
        nx := vr(r).next;
        defer r = nx;
        if !vpm_vpi_r(r, VPI_EXTRACT_LAST_LANE, 1) continue;
        okp, elp := vpm_vpi(vp_op(r, 0), VPI_EXTRACT_LAST_PART, 1);
        if !okp continue;
        op0 := vp_op(elp, 0);
        lal := vpb_nary(*mb, VPI_LAST_ACTIVE_LANE, .[hm], .{}, .[], NONE, "", dl_index_type(type_ptr(0)));
        ext := vpb_nary(*mb, VPI_EXTRACT_LANE, .[vr(lal).def, op0]);
        vp_rauw(vr(r).def, vr(ext).def);
    }
    vp_set_operand(vp_terminator(middle), 0, vp_true());
}
