// VPlanTransforms::unrollByUF and replicateByVF.
// Ported from llvm/lib/Transforms/Vectorize/VPlanUnroll.cpp (LLVM 23.1.5). Replicate regions are not created by the
// ported subset yet (createAndOptimizeReplicateRegions fails loudly first), so their unrolling / dissolution fails
// loudly here too.

Vp_Unroll_State :: struct {
    uf: u32;
    to_skip: Table(Vp_Rec, bool);
    parts: Table(Vp_Val, [..] Vp_Val);    // VPV2Parts: part 0 value -> values of parts 1 .. UF-1
}

vpu_value_for_part :: (u: *Vp_Unroll_State, v: Vp_Val, part: u32) -> Vp_Val {
    k := vv(v).kind;
    if part == 0 || k == .IR || k == .SYMBOLIC || k == .REGION return v;
    p := table_find_pointer(*u.parts, v);
    assert(p != null && p.count >= cast(s64) part, "accessed value does not exist");
    return p.*[part - 1];
}
vpu_parts_of :: (u: *Vp_Unroll_State, v: Vp_Val) -> *[..] Vp_Val {
    p := table_find_pointer(*u.parts, v);
    if p return p;
    e: [..] Vp_Val; e.allocator = temp;
    table_set(*u.parts, v, e);
    return table_find_pointer(*u.parts, v);
}
vpu_add_recipe_for_part :: (u: *Vp_Unroll_State, orig: Vp_Rec, copy: Vp_Rec, part: u32) {
    for k: 0..vp_num_defined_values(orig)-1 {
        p := vpu_parts_of(u, vp_defined_value(orig, k));
        assert(p.count == cast(s64) part - 1, "earlier parts not set");
        array_add(p, vp_defined_value(copy, k));
    }
}
vpu_add_uniform_for_all_parts :: (u: *Vp_Unroll_State, r: Vp_Rec) {
    d := vr(r).def;
    assert(!table_contains(*u.parts, d), "uniform value already added");
    p := vpu_parts_of(u, d);
    for part: 0..u.uf-1 array_add(p, d);
}
vpu_remap_operand :: (u: *Vp_Unroll_State, r: Vp_Rec, idx: s64, part: u32) {
    vp_set_operand(r, idx, vpu_value_for_part(u, vp_op(r, idx), part));
}
vpu_remap_operands :: (u: *Vp_Unroll_State, r: Vp_Rec, part: u32) {
    for i: 0..vp_nops(r)-1 vp_set_operand(r, i, vpu_value_for_part(u, vp_op(r, i), part));
}
vpu_can_iv_const :: (part: u64) -> Vp_Val { return vp_const_int(vv(vb(vp_vector_loop_region()).can_iv).ty, part); }

// addStartIndexForScalarSteps
vp_add_start_index_for_scalar_steps :: (steps: Vp_Rec, part: u32) {
    if part == 0 return;
    b := vpb_before(steps);
    base_ty := vp_scalar_type(vp_op(steps, 0));
    int_step_ty := type_int(type_bits(scalar_type(base_ty)));
    start := vp_op(steps, 2);
    if part > 1 start = vr(vpb_overflowing(*b, .MUL, .[start, vp_const_int(vp_scalar_type(start), part)], false, false)).def;
    start = vpb_scalar_sext_or_trunc(*b, start, int_step_ty, vp_scalar_type(start), vr(steps).dl);
    if is_fp_type(base_ty) start = vr(vpb_scalar_cast(*b, .SITOFP, start, base_ty, vr(steps).dl)).def;
    vp_steps_set_start_index(steps, start);
}
vp_steps_start_index :: (r: Vp_Rec) -> Vp_Val { return ifx vp_nops(r) == 4 then vp_op(r, 3) else NONE; }
vp_steps_set_start_index :: (r: Vp_Rec, v: Vp_Val) { if vp_nops(r) == 4 vp_set_operand(r, 3, v); else vp_add_operand(r, v); }

// UnrollState::unrollWidenInductionByUF
vpu_unroll_widen_induction :: (u: *Vp_Unroll_State, iv: Vp_Rec, insert_pt_for_phi: Vp_Rec) {
    ph := vp_single_pred(vp_enclosing_loop_region(vr(iv).parent));
    ivty := vp_scalar_type(vr(iv).def);
    id := *vpl.inds[vr(iv).ind];
    fmf: u32 = 0;
    wrap := vpf_wrap(false, false);
    if vr(iv).kind == .WIDEN_INT_OR_FP_INDUCTION {
        fmf = vp_fmf_or_none(iv);
        if vr(iv).flags.optype == .OVERFLOWING_BINOP || vr(iv).flags.optype == .TRUNC wrap = vpf_wrap(vr(iv).flags.nuw, vr(iv).flags.nsw);
    }
    scalar_step := vp_op(iv, 1);
    b := vpb_at_end(ph);
    vstep_ty := ifx type_kind(ivty) == .PTR then vp_scalar_type(scalar_step) else ivty;
    vstep := vpb_nary(*b, VPI_WIDE_IV_STEP, .[vpl.vf, scalar_step], vpf_fmf(fmf), .[], vr(iv).dl, "", vstep_ty);
    vr(vstep).with_type = true;
    table_set(*u.to_skip, vstep, true);
    prev := vr(iv).def;
    b = vpb_at(vr(iv).parent, insert_pt_for_phi);
    add_opc: u16; add_flags: Vp_Flags;
    if type_kind(ivty) == .PTR { add_opc = VPI_WIDE_PTR_ADD; add_flags = vpf_gep(0); }
    else if is_fp_type(ivty) { _, o := ind_opcode(id); add_opc = vp_opc(o); add_flags = vpf_fmf(fmf); }
    else {
        add_opc = vp_opc(.ADD); add_flags = wrap;
        if vp_is_canonical_widen_iv(iv) add_flags = vpf_wrap(true, false);
    }
    for part: 1..u.uf-1 {
        name := ifx part > 1 then tprint("step.add.%", part) else "step.add";
        add := vpb_nary(*b, add_opc, .[prev, vr(vstep).def], add_flags, .[], vr(iv).dl, name);
        table_set(*u.to_skip, add, true);
        vpu_add_recipe_for_part(u, iv, add, part);
        prev = vr(add).def;
    }
    vp_add_operand(iv, vr(vstep).def);
    vp_add_operand(iv, prev);
}

// UnrollState::unrollHeaderPHIByUF
vpu_unroll_header_phi :: (u: *Vp_Unroll_State, r: Vp_Rec, insert_pt_for_phi: Vp_Rec) {
    k := vr(r).kind;
    if k == .FIRST_ORDER_RECURRENCE_PHI return;
    if vp_is_widen_induction_kind(k) { vpu_unroll_widen_induction(u, r, insert_pt_for_phi); return; }
    is_rdx := k == .REDUCTION_PHI;
    if is_rdx && vr(r).rdx_style == .ORDERED return;
    insert_pt := vr(r).next;
    for part: 1..u.uf-1 {
        copy := vp_clone(r);
        vp_insert_recipe(copy, vr(r).parent, insert_pt);
        vpu_add_recipe_for_part(u, r, copy, part);
        if is_rdx {
            start := vp_op(r, 0);
            sr := vp_def(start);
            if sr != NONE && vr(sr).kind == .INSTRUCTION {
                assert(vr(sr).opcode == VPI_REDUCTION_START_VECTOR, "unexpected start VPInstruction");
                if part != 1 continue;
                start_v: Vp_Val;
                if vpm_one(vp_op(sr, 2)) start_v = vp_op(sr, 1);
                else {
                    c := vp_clone(sr);
                    vp_set_operand(c, 0, vp_op(c, 1));
                    vp_insert_after(c, sr);
                    start_v = vr(c).def;
                }
                p := vpu_parts_of(u, start);
                for pp: 1..u.uf-1 p.*[pp - 1] = start_v;
            }
        } else {
            assert(k == .ACTIVE_LANE_MASK_PHI, "unexpected header phi recipe not needing unrolled part");
        }
    }
}

// UnrollState::unrollRecipeByUF
vpu_unroll_recipe :: (u: *Vp_Unroll_State, r: Vp_Rec) {
    if vp_is_vpi(r, VPI_BRANCH_ON_COND) || vp_is_vpi(r, VPI_BRANCH_ON_COUNT) return;
    if vr(r).kind == .INSTRUCTION && vp_only_first_part_used(vr(r).def) { vpu_add_uniform_for_all_parts(u, r); return; }
    if vr(r).kind == .REPLICATE {
        ui := vp_underlying_instr(r);
        if inst_op(ui) == .STORE && vp_is_defined_outside_loop_regions(vp_op(r, 1)) { vpu_remap_operands(u, r, u.uf - 1); return; }
        if call_iid(ui) == iid_by_name("llvm.experimental.noalias.scope.decl") { vpu_add_uniform_for_all_parts(u, r); return; }
    }
    insert_pt := vr(r).next;
    bb := vr(r).parent;
    for part: 1..u.uf-1 {
        copy := vp_clone(r);
        vp_insert_recipe(copy, bb, insert_pt);
        vpu_add_recipe_for_part(u, r, copy, part);
        k := vr(r).kind;
        if k == .WIDEN_PHI continue;
        if vp_is_vpi(r, VPI_FIRST_ORDER_RECURRENCE_SPLICE) {
            o := vp_op(r, 1);
            vp_set_operand(copy, 0, vpu_value_for_part(u, o, part - 1));
            vp_set_operand(copy, 1, vpu_value_for_part(u, o, part));
            continue;
        }
        if k == .VECTOR_POINTER || k == .WIDEN_CANONICAL_IV {
            b := vpb_before(r);
            index_ty := ifx k == .WIDEN_CANONICAL_IV then vv(vb(vp_vector_loop_region()).can_iv).ty else dl_index_type(vp_scalar_type(vr(r).def));
            vfty := vp_scalar_type(vpl.vf);
            vfv := vpb_scalar_zext_or_trunc(*b, vpl.vf, index_ty, vfty, NONE);
            vfxpart := vpb_overflowing(*b, .MUL, .[vfv, vp_const_int(index_ty, part)], true, true);
            vp_add_operand(copy, vr(vfxpart).def);   // addPerPartOffset / addPerPartStep
            continue;
        }
        if k == .REDUCTION {
            phi := vp_def(vp_op(r, 0));
            if phi != NONE && vr(phi).kind == .REDUCTION_PHI && vr(phi).rdx_style == .ORDERED {
                p := vpu_parts_of(u, vr(phi).def);
                if part == 1 { p.count = 0; array_add(p, vr(r).def); }
                array_add(p, vr(copy).def);
                vp_set_operand(phi, 1, vr(copy).def);
            }
        }
        if vr(copy).kind == .VECTOR_END_POINTER {
            vp_set_operand(copy, 0, vp_op(r, 0));
            vp_set_operand(copy, 1, vp_op(r, 1));
            vp_materialize_end_pointer_offset(copy, part);
            continue;
        }
        vpu_remap_operands(u, copy, part);
        if vr(copy).kind == .SCALAR_IV_STEPS vp_add_start_index_for_scalar_steps(copy, part);
        if vp_is_vpi(copy, VPI_CANONICAL_IV_INCREMENT_FOR_PART) {
            b := vpb_before(copy);
            scaled := vpb_overflowing(*b, .MUL, .[vp_op(copy, 1), vpu_can_iv_const(part)], false, false);
            vp_set_operand(copy, 1, vr(scaled).def);
        }
    }
    if vr(r).kind == .VECTOR_END_POINTER vp_materialize_end_pointer_offset(r, 0);
    if vr(r).kind == .WIDEN_CANONICAL_IV vp_add_operand(r, vpu_can_iv_const(0));
}

// UnrollState::unrollBlock
vpu_unroll_block :: (u: *Vp_Unroll_State, b: Vp_Blk) {
    if vp_is_region(b) {
        if vp_is_replicator(b) { vpu_unroll_replicate_region(u, b); return; }
        for x: vp_rpo(vb(b).entry, false) vpu_unroll_block(u, x);
        return;
    }
    insert_pt_for_phi := vp_first_non_phi(b);
    for r: vp_block_recipes(b) {
        if table_contains(*u.to_skip, r) || vr(r).kind == .IR_INSTRUCTION continue;
        if vr(r).kind == .INSTRUCTION {
            o := vr(r).opcode;
            if (o == VPI_ANY_OF || o == VPI_FIRST_ACTIVE_LANE || o == VPI_LAST_ACTIVE_LANE || o == VPI_COMPUTE_REDUCTION_RESULT) && vp_nops(r) == 1 {
                op1 := vp_op(r, 0);
                vpu_add_uniform_for_all_parts(u, r);
                for part: 1..u.uf-1 vp_add_operand(r, vpu_value_for_part(u, op1, part));
                continue;
            }
            if o == VPI_EXTRACT_LANE && vp_nops(r) == 2 {
                op1 := vp_op(r, 1);
                vpu_add_uniform_for_all_parts(u, r);
                for part: 1..u.uf-1 vp_add_operand(r, vpu_value_for_part(u, op1, part));
                continue;
            }
            if o == VPI_EXTRACT_LAST_ACTIVE && vp_nops(r) == 3 {
                op1 := vp_op(r, 1); op2 := vp_op(r, 2);
                vpu_add_uniform_for_all_parts(u, r);
                for part: 1..u.uf-1 { vp_add_operand(r, vpu_value_for_part(u, op1, part)); vp_add_operand(r, vpu_value_for_part(u, op2, part)); }
                continue;
            }
            if vp_has_scalar_vf_only() && (o == VPI_EXTRACT_LAST_PART || o == VPI_EXTRACT_PENULTIMATE_ELEMENT) && vp_nops(r) == 1 {
                pidx := ifx o == VPI_EXTRACT_PENULTIMATE_ELEMENT then u.uf - 2 else u.uf - 1;
                vp_rauw(vr(r).def, vpu_value_for_part(u, vp_op(r, 0), pidx));
                continue;
            }
            // m_ExtractLastLaneOfLastPart: ExtractLastLane(ExtractLastPart(Op0)); m_ExtractPenultimateElement(Op0)
            if o == VPI_EXTRACT_LAST_LANE && vp_nops(r) == 1 {
                okp, elp := vpm_vpi(vp_op(r, 0), VPI_EXTRACT_LAST_PART, 1);
                if okp {
                    op0 := vp_op(elp, 0);
                    vpu_add_uniform_for_all_parts(u, r);
                    vp_set_operand(r, 0, vpu_value_for_part(u, op0, u.uf - 1));
                    continue;
                }
            }
            if o == VPI_EXTRACT_PENULTIMATE_ELEMENT && vp_nops(r) == 1 {
                op0 := vp_op(r, 0);
                vpu_add_uniform_for_all_parts(u, r);
                vp_set_operand(r, 0, vpu_value_for_part(u, op0, u.uf - 1));
                continue;
            }
        }
        if vp_is_single_def_kind(vr(r).kind) && vp_is_uniform_across_vfs_and_ufs(vr(r).def) { vpu_add_uniform_for_all_parts(u, r); continue; }
        if vp_is_header_phi(r) { vpu_unroll_header_phi(u, r, insert_pt_for_phi); continue; }
        vpu_unroll_recipe(u, r);
    }
}

// VPlanTransforms::unrollByUF
vp_unroll_by_uf :: (uf: u32) {
    assert(uf > 0, "Unroll factor must be positive");
    vp_set_uf(uf);
    if uf != 1 {
        u: Vp_Unroll_State;
        u.uf = uf;
        u.to_skip.allocator = temp; u.parts.allocator = temp;
        for b: vp_rpo(vpl.entry, false) vpu_unroll_block(*u, b);
        part: u32 = 1;
        for h: vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) {
            if vr(h).kind == .FIRST_ORDER_RECURRENCE_PHI { vpu_remap_operand(*u, h, 1, uf - 1); continue; }
            if table_contains(*u.parts, vr(h).def) { part = 1; continue; }
            vpu_remap_operands(*u, h, part);
            part += 1;
        }
        vp_remove_dead_recipes();
    }
    // the scope_exit cleanup
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) for r: vp_block_recipes(bb) {
        if vp_is_vpi(r, VPI_CANONICAL_IV_INCREMENT_FOR_PART) && vp_op(r, 1) == vpl.vf {
            vp_rauw(vr(r).def, vp_op(r, 0));
            vp_erase_recipe(r);
        }
    }
    tcty := vp_scalar_type(vpl.trip_count);
    vp_rauw(vpl.uf, vp_const_int(tcty, uf));
}

// ---------------------------------------------------------------- replicateByVF

// addLaneToStartIndex
vp_add_lane_to_start_index :: (steps: Vp_Rec, lane: u32, insert_pt: Vp_Rec) {
    assert(lane > 0, "Zero lane adds no offset to start index");
    base_ty := vp_scalar_type(vp_op(steps, 0));
    old := vp_steps_start_index(steps);
    lane_off: Vp_Val; add_opc: u16; flags: Vp_Flags;
    if is_fp_type(base_ty) {
        signed_lane := cast(s64) lane;
        if old == NONE && vr(steps).ind_opcode == .FSUB signed_lane = -signed_lane;
        lane_off = vp_live_in(fp_const(base_ty, signed_lane));
        add_opc = vp_opc(vr(steps).ind_opcode);
        flags = vpf_fmf(0);
    } else {
        bits := type_bits(base_ty);
        lane_off = vp_const_int_ap(ap_u64_implicit_trunc(bits, lane));
        add_opc = vp_opc(.ADD);
        flags = vpf_wrap(false, false);
    }
    new := lane_off;
    if old != NONE {
        b := vpb_before(insert_pt);
        new = vr(vpb_nary(*b, add_opc, .[old, lane_off], flags)).def;
    }
    vp_steps_set_start_index(steps, new);
}

// cloneForLane
vp_clone_for_lane :: (b: *Vp_Builder, idx_ty: Type_Id, defr: Vp_Rec, lane: u32, lane_defs: *Table(Vp_Val, [..] Vp_Val)) -> Vp_Val {
    if vp_is_vpi(defr, VPI_UNPACK) {
        o := vp_op(defr, 0);
        ld := table_find_pointer(lane_defs, o);
        if ld return ld.*[lane];
        return vr(vpb_nary(b, vp_opc(.EXTRACTELEMENT), .[o, vp_const_int(idx_ty, lane)])).def;
    }
    new_ops: [..] Vp_Val; new_ops.allocator = temp;
    for o: vr(defr).ops {
        ld := table_find_pointer(lane_defs, o);
        if ld { array_add(*new_ops, ld.*[lane]); continue; }
        if vp_is_single_scalar(o) { array_add(*new_ops, o); continue; }
        if vp_val_is_vpi(o, VPI_BUILD_VECTOR) { array_add(*new_ops, vp_op(vp_def(o), lane)); continue; }
        ext := vpb_nary(b, vp_opc(.EXTRACTELEMENT), .[o, vp_const_int(idx_ty, lane)]);
        array_add(*new_ops, vr(ext).def);
    }
    new: Vp_Rec;
    if vr(defr).kind == .REPLICATE {
        new = vp_create_single_scalar_op(vp_opc(inst_op(vp_underlying_instr(defr))), new_ops, NONE, vr(defr).flags, vr(defr).md,
                                         vr(defr).dl, vp_underlying_instr(defr));
    } else {
        new = vp_clone(defr);
        for o, i: new_ops vp_set_operand(new, i, o);
        if vr(new).kind == .SCALAR_IV_STEPS && lane != 0 vp_add_lane_to_start_index(new, lane, defr);
    }
    vp_insert_before(new, defr);
    return vr(new).def;
}

// VPInstruction::doesGeneratePerAllLanes
vpi_does_generate_per_all_lanes :: (r: Vp_Rec) -> bool { return vr(r).opcode == VPI_PTR_ADD && !vp_only_first_lane_used(vr(r).def); }

// replicateReplicateRegionsByVF
vp_replicate_replicate_regions_by_vf :: (vf: Ec, idx_ty: Type_Id) {
    regions: [..] Vp_Blk; regions.allocator = temp;
    for r: vp_blocks_only_region(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry))
        if vp_is_replicator(r) array_add(*regions, r);
    assert(regions.count == 0 || !vf.scalable, "cannot replicate across scalable VFs");
    for < regions vp_dissolve_replicate_region(it, vf, idx_ty);
    vp_merge_blocks_into_predecessors();
}

// VPlanTransforms::replicateByVF
vp_replicate_by_vf :: (vf: Ec) {
    idx_ty := type_int(32);
    if vp_has_scalar_vf_only() { vp_replicate_replicate_regions_by_vf(vf, idx_ty); return; }
    blocks: [..] Vp_Blk; blocks.allocator = temp;
    for vp_blocks_only_basic(vp_depth_first_shallow(vpl.entry)) array_add(*blocks, it);
    for vp_blocks_only_basic(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) array_add(*blocks, it);
    lane_defs: Table(Vp_Val, [..] Vp_Val); lane_defs.allocator = temp;
    to_remove: [..] Vp_Rec; to_remove.allocator = temp;
    for bb: blocks for r: vp_block_recipes(bb) {
        k := vr(r).kind;
        if k != .INSTRUCTION && k != .REPLICATE && k != .SCALAR_IV_STEPS continue;
        if k == .REPLICATE && vr(r).single_scalar continue;
        if k == .INSTRUCTION && !vpi_does_generate_per_all_lanes(r) && vr(r).opcode != VPI_UNPACK continue;
        b := vpb_before(r);
        d := vr(r).def;
        if vp_num_users(d) == 0 {
            for i: 0..cast(u32) vf.n - 1 vp_clone_for_lane(*b, idx_ty, r, i, *lane_defs);
            vp_erase_recipe(r);
            continue;
        }
        defs: [..] Vp_Val; defs.allocator = temp;
        for i: 0..cast(u32) vf.n - 1 array_add(*defs, vp_clone_for_lane(*b, idx_ty, r, i, *lane_defs));
        table_set(*lane_defs, d, defs);
        first_lane :: (u: Vp_Rec, idx: s64, data: *void) -> bool {
            d := (cast(*Vp_Val) data).*;
            if vp_uses_first_lane_only(u, d) return true;
            return vp_is_instruction_with_type(u) && vp_opcode_is_cast(vr(u).opcode);
        }
        vp_replace_uses_with_if(d, defs[0], first_lane, *d);
        users: [..] Vp_Rec; users.allocator = temp;
        for vv(d).users array_add(*users, it);
        for us: users {
            if !(vp_is_vpi(us, VPI_BUILD_VECTOR) || vp_is_vpi(us, VPI_BUILD_STRUCT_VECTOR)) continue;
            assert(vp_nops(us) == 1, "Build(Struct)Vector must have a single operand before replicating by VF");
            vp_set_operand(us, 0, defs[0]);
            for i: 1..defs.count-1 vp_add_operand(us, defs[i]);
        }
        array_add(*to_remove, r);
    }
    for < to_remove vp_erase_recipe(it);
    vp_replicate_replicate_regions_by_vf(vf, idx_ty);
}

// APInt(Bits, V, /*isSigned=*/false, /*implicitTrunc=*/true)
ap_u64_implicit_trunc :: (bits: u32, v: u64) -> APInt {
    if bits >= 64 return ap_from_u64(bits, v);
    return ap_trunc(ap_from_u64(64, v), bits);
}
