// VPlan transforms run while building and optimizing plans: removeBranchOnConst, optimize() and its sub-passes
// (removeRedundantInductionCasts, reassociateHeaderMask, simplifyBlends, legalizeAndOptimizeInductions,
// narrowToSingleScalarRecipes, removeRedundantExpandSCEVRecipes, simplifyReverses, createAndOptimizeReplicateRegions,
// mergeBlocksIntoPredecessors, licm), truncateToMinimalBitwidths, dropPoisonGeneratingRecipes, materializeHeaderMask,
// and the memory/scalarization/call widening decisions of tryToBuildVPlan.
// Ported from llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp (LLVM 23.1.5). Paths that need predication, interleave
// groups, reductions handled in-loop or EVL fail loudly.

// VPBuilder::createSingleScalarOp
vp_create_single_scalar_op :: (opcode: u16, ops: [] Vp_Val, mask: Vp_Val, flags: Vp_Flags, md: [] Vp_Md, dl: Md_Id, uv: Value_Id) -> Vp_Rec {
    if vp_opcode_is_cast(opcode) {
        r := vp_new_instruction(opcode, ops, flags, md, dl, ir.v_name[uv], vtype(uv));
        vr(r).with_type = true;
        vp_set_underlying(vr(r).def, uv);
        return r;
    }
    return vp_new_replicate(uv, ops, true, mask, flags, md, dl);
}
// VPReplicateRecipe constructor
vp_new_replicate :: (i: Value_Id, ops: [] Vp_Val, single_scalar: bool, mask: Vp_Val, flags: Vp_Flags, md: [] Vp_Md, dl: Md_Id) -> Vp_Rec {
    o := inst_op(i);
    ty: Type_Id;
    if is_cast_op(o) || o == .EXTRACTVALUE || o == .LOAD || o == .ALLOCA ty = vtype(i);
    else ty = vp_compute_scalar_type_for_instruction(vp_opc(o), ops);
    r := vp_new_single_def(.REPLICATE, ops, ty, i, dl);
    vr(r).flags = flags; vr(r).single_scalar = single_scalar; vr(r).predicated = mask != NONE;
    for md array_add(*vr(r).md, it);
    if mask != NONE vp_add_operand(r, mask);
    return r;
}
vp_ops_without_mask :: (r: Vp_Rec) -> [..] Vp_Val {
    out: [..] Vp_Val; out.allocator = temp;
    n := vpm_num_ops_without_mask(r);
    for i: 0..n-1 array_add(*out, vp_op(r, i));
    return out;
}
vp_ops :: (r: Vp_Rec) -> [..] Vp_Val { out: [..] Vp_Val; out.allocator = temp; for vr(r).ops array_add(*out, it); return out; }

// VPIRFlags::dropPoisonGeneratingFlags
vp_drop_poison_generating_flags :: (r: Vp_Rec) {
    f := *vr(r).flags;
    if f.optype == {
        case .OVERFLOWING_BINOP; #through; case .TRUNC; f.nuw = false; f.nsw = false;
        case .DISJOINT_OP; f.disjoint = false;
        case .POSSIBLY_EXACT_OP; f.exact = false;
        case .GEP_OP; f.gep = 0;
        case .FP_MATH_OP; #through; case .FCMP; #through; case .REDUCTION_OP; f.fmf &= ~cast(u32) (FMF_NNAN | FMF_NINF);
        case .NON_NEG_OP; f.nneg = false;
    }
}

// VPlanTransforms::removeBranchOnConst
vp_remove_branch_on_const :: (only_latches: bool) -> bool {
    dt: Vp_Dom_Tree;
    if only_latches dt = vp_dt_build();
    all := vp_depth_first_shallow(vpl.entry);
    simplified_phi := false;
    for bb: vp_blocks_only_basic(all) {
        if vp_block_empty(bb) continue;
        ok, cond := vpm_branch_on_cond(vb(bb).last);
        if !ok continue;
        if only_latches && !vpbu_is_latch(bb, *dt) continue;
        removed_idx := -1;
        if vpm_is_true(cond) removed_idx = 1;
        else if vpm_is_false(cond) removed_idx = 0;
        else continue;
        removed := vb(bb).succs[removed_idx];
        phis := vp_block_phis(removed);
        for phis vp_phi_remove_incoming_value_for(it, bb);
        simplified_phi |= phis.count > 0;
        vpbu_disconnect(bb, removed);
        vp_erase_recipe(vb(bb).last);
    }
    reachable: Table(Vp_Blk, bool); reachable.allocator = temp;
    for vp_depth_first_shallow(vpl.entry) table_set(*reachable, it, true);
    tmp := vp_new_symbolic(NONE);
    for b: all {
        if table_contains(*reachable, b) continue;
        succs: [..] Vp_Blk; succs.allocator = temp;
        for vb(b).succs array_add(*succs, it);
        for s: succs {
            if vp_is_basic(s) for vp_block_phis(s) vp_phi_remove_incoming_value_for(it, b);
            vpbu_disconnect(b, s);
        }
        for dead: vp_blocks_only_basic(vp_depth_first_deep(b)) {
            for r: vp_block_recipes(dead) {
                for k: 0..vp_num_defined_values(r)-1 vp_rauw(vp_defined_value(r, k), tmp);
                vp_erase_recipe(r);
            }
        }
    }
    return simplified_phi;
}

// removeRedundantInductionCasts
vp_remove_redundant_induction_casts :: () {
    for phi: vp_block_phis(vp_entry_basic_block(vp_vector_loop_region())) {
        if vr(phi).kind != .WIDEN_INT_OR_FP_INDUCTION || vr(phi).ir_inst != NONE continue;
        casts := vpl.inds[vr(phi).ind].casts;
        find := vr(phi).def;
        k := casts.count - 1;
        while k >= 0 {
            irc := casts[k]; k -= 1;
            found: Vp_Val = NONE;
            for u: vv(find).users if vp_is_single_def_kind(vr(u).kind) && vv(vr(u).def).uv == irc { found = vr(u).def; break; }
            if found == NONE break;
            find = found;
        }
        if find != vr(phi).def vp_rauw(find, vr(phi).def);
    }
}

// reassociateHeaderMask
vp_reassociate_header_mask :: () {
    hm := vb(vp_vector_loop_region()).header_mask;
    if hm == NONE return;
    wl: [..] Vp_Rec; wl.allocator = temp;
    for u: vv(hm).users {
        if !vp_is_single_def_kind(vr(u).kind) || vr(u).def == NONE continue;
        ok, a, _ := vpm_logical_and(vr(u).def);
        if ok && a == hm for vv(vr(u).def).users array_add(*wl, it);
    }
    while wl.count {
        r := pop(*wl);
        if !vp_is_single_def_kind(vr(r).kind) || vr(r).def == NONE || vr(r).dead continue;
        ok, inner, y := vpm_logical_and(vr(r).def);
        if !ok continue;
        ok2, a, x := vpm_logical_and(inner);
        if !ok2 || a != hm continue;
        for vv(vr(r).def).users array_add(*wl, it);
        b := vpb_before(r);
        xy := vpb_logical_and(*b, x, y);
        n := vpb_logical_and(*b, hm, vr(xy).def);
        vp_rauw(vr(r).def, vr(n).def);
    }
}


// createScalarIVSteps
vp_create_scalar_iv_steps :: (kind: Ind_Kind, ind_opcode: Opcode, fp_binop: Value_Id, trunc_i: Value_Id, start: Vp_Val, step_in: Vp_Val, dl: Md_Id, b: *Vp_Builder) -> Vp_Rec {
    region := vp_vector_loop_region();
    header := vp_entry_basic_block(region);
    can_iv := vb(region).can_iv;
    step := step_in;
    base := vpb_insert(b, vp_new_derived_iv(kind, fp_binop, start, can_iv, step));
    base_v := vr(base).def;
    result_ty := vp_scalar_type(base_v);
    if trunc_i != NONE {
        tty := vtype(trunc_i);
        base_v = vr(vpb_scalar_cast(b, .TRUNC, base_v, tty, dl, vp_default_flags(vp_opc(.TRUNC)))).def;
        result_ty = tty;
    }
    step_ty := vp_scalar_type(step);
    if result_ty != step_ty {
        ph := vp_single_hierarchical_pred(header);
        pb := vpb_at_end(ph);
        step = vr(vpb_scalar_cast(*pb, .TRUNC, step, result_ty, dl, vp_default_flags(vp_opc(.TRUNC)))).def;
    }
    fmf := ifx fp_binop != NONE then inst_fmf(fp_binop) else 0;
    return vpb_insert(b, vp_new_scalar_iv_steps(base_v, step, vpl.vf, ind_opcode, fmf, dl));
}
vp_new_derived_iv :: (kind: Ind_Kind, fp_binop: Value_Id, start: Vp_Val, iv: Vp_Val, step: Vp_Val) -> Vp_Rec {
    r := vp_new_single_def(.DERIVED_IV, .[start, iv, step], vp_scalar_type(start));
    vr(r).ind_kind = kind; vr(r).fp_binop = fp_binop;
    return r;
}
vp_new_scalar_iv_steps :: (iv: Vp_Val, step: Vp_Val, vf: Vp_Val, opcode: Opcode, fmf: u32, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.SCALAR_IV_STEPS, .[iv, step, vf], vp_scalar_type(iv), NONE, dl);
    vr(r).ind_opcode = opcode; vr(r).flags = vpf_fmf(fmf);
    return r;
}

// collectUsersRecursively
vp_collect_users_recursively :: (v: Vp_Val) -> [..] Vp_Rec {
    users: [..] Vp_Rec; users.allocator = temp;
    seen: Table(Vp_Rec, bool); seen.allocator = temp;
    for vv(v).users if !table_contains(*seen, it) { table_set(*seen, it, true); array_add(*users, it); }
    i := 0;
    while i < users.count {
        cur := users[i]; i += 1;
        for k: 0..vp_num_defined_values(cur)-1
            for u: vv(vp_defined_value(cur, k)).users if !table_contains(*seen, u) { table_set(*seen, u, true); array_add(*users, u); }
    }
    return users;
}

// legalizeAndOptimizeInductions
vp_legalize_and_optimize_inductions :: () {
    header := vp_entry_basic_block(vp_vector_loop_region());
    only_vector := !vp_has_scalar_vf_only();
    wide_ivs: [..] Vp_Rec; wide_ivs.allocator = temp;
    for vp_block_phis(header) if vp_is_widen_induction_kind(vr(it).kind) array_add(*wide_ivs, it);
    for phi: wide_ivs {
        users := vp_collect_users_recursively(vr(phi).def);
        for < u: users {
            if vr(u).dead continue;
            k := vr(u).kind;
            if k != .REPLICATE && k != .WIDEN continue;
            d := vr(u).def;
            if vp_num_users(d) == 0 || vv(d).uv == NONE || (k == .REPLICATE && (vr(u).single_scalar || vr(u).predicated)) continue;
            if !vp_is_single_scalar(d) && !vp_only_first_lane_used(d) continue;
            okev, _, _ := vpm_binary(d, vp_opc(.EXTRACTVALUE));
            if okev continue;
            ui := vv(d).uv;
            clone := vp_create_single_scalar_op(vp_opc(inst_op(ui)), vp_ops(u), NONE, vr(u).flags, .[], NONE, ui);
            vp_insert_after(clone, u);
            vp_rauw(d, vr(clone).def);
            vp_erase_recipe(u);
        }
    }
    b := vpb_at(header, vp_first_non_phi(header));
    for phi: wide_ivs {
        if vr(phi).kind == .WIDEN_POINTER_INDUCTION {
            if !vp_has_scalar_vf_only() && !vp_ptr_iv_only_scalars_generated(phi) continue;
            ptr_add := vp_scalarize_widen_pointer_induction(phi, *b);
            vp_rauw(vr(phi).def, ptr_add);
            continue;
        }
        any_scalar_user := false;
        for u: vv(vr(phi).def).users if vp_uses_scalars(u, vr(phi).def) { any_scalar_user = true; break; }
        if only_vector && !any_scalar_user continue;
        d := *vpl.inds[vr(phi).ind];
        ok, opc := ind_opcode(d);
        if !ok opc = xx 0xFF;
        fpb := ifx d.bop != NONE && is_fp_math_operator(d.bop) then d.bop else NONE;
        steps := vp_create_scalar_iv_steps(d.kind, opc, fpb, vr(phi).ir_inst, vp_op(phi, 0), vp_op(phi, 1), vr(phi).dl, *b);
        if !only_vector vp_rauw(vr(phi).def, vr(steps).def);
        else {
            scal :: (r: Vp_Rec, idx: s64, data: *void) -> bool { return vp_uses_scalars(r, << cast(*Vp_Val) data); }
            iv := vr(phi).def;
            vp_replace_uses_with_if(iv, vr(steps).def, scal, *iv);
        }
    }
}
// VPWidenPointerInductionRecipe::onlyScalarsGenerated
vp_ptr_iv_only_scalars_generated :: (r: Vp_Rec) -> bool {
    scalable := false;
    for vpl.vfs if it.scalable scalable = true;
    return vp_only_scalar_values_used(vr(r).def) && (!scalable || vp_only_first_lane_used(vr(r).def));
}
// scalarizeVPWidenPointerInduction
vp_scalarize_widen_pointer_induction :: (r: Vp_Rec, b: *Vp_Builder) -> Vp_Val {
    d := *vpl.inds[vr(r).ind];
    start := vp_zero(sc_type(d.step));
    steps := vp_create_scalar_iv_steps(.INT, .ADD, NONE, NONE, start, vp_op(r, 1), vr(r).dl, b);
    return vr(vpb_ptr_add(b, vp_op(r, 0), vr(steps).def, vr(r).dl, "next.gep")).def;
}

// narrowToSingleScalarRecipes
vp_narrow_to_single_scalar_recipes :: () {
    if vp_has_scalar_vf_only() return;
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) {
        r := vb(bb).last;
        while r != NONE {
            prev := vr(r).prev;
            defer r = prev;
            k := vr(r).kind;
            if k != .WIDEN && k != .WIDEN_GEP && k != .REPLICATE && k != .WIDEN_INTRINSIC continue;
            if k == .REPLICATE && (vr(r).single_scalar || vr(r).predicated) continue;
            if k == .REPLICATE && inst_op(vp_underlying_instr(r)) == .STORE && vp_is_single_scalar(vp_op(r, 1)) {
                clone := vp_new_replicate(vp_underlying_instr(r), vp_ops(r), true, NONE, vr(r).flags, vr(r).md, vr(r).dl);
                vp_insert_before(clone, r);
                b := vpb_before(clone);
                ext := vp_op(clone, 0);
                if vp_is_uniform_across_vfs_and_ufs(vp_op(r, 1)) ext = vr(vpb_nary(*b, VPI_EXTRACT_LAST_PART, .[ext])).def;
                ext = vr(vpb_nary(*b, VPI_EXTRACT_LAST_LANE, .[ext])).def;
                vp_set_operand(clone, 0, ext);
                vp_erase_recipe(r);
                continue;
            }
            if k == .WIDEN_INTRINSIC {
                if !vp_only_first_lane_used(vr(r).def) continue;
                id := vr(r).iid;
                nm := intrinsic_name(id);
                if nm == "llvm.masked.udiv" || nm == "llvm.masked.sdiv" || nm == "llvm.masked.urem" || nm == "llvm.masked.srem"
                    vp_unported("narrowing masked div/rem intrinsics");
                continue;
            }
            d := vr(r).def;
            if !vp_is_single_scalar(d) continue;
            introduces_bcast :: (u: Vp_Rec, op: Vp_Val) -> bool {
                if vr(u).kind == .INSTRUCTION {
                    o := vr(u).opcode;
                    if o == VPI_EXTRACT_LAST_LANE || o == VPI_EXTRACT_LAST_PART || o == VPI_EXTRACT_PENULTIMATE_ELEMENT return false;
                }
                return !vp_uses_scalars(u, op);
            }
            any_b := false;
            for u: vv(d).users if introduces_bcast(u, d) { any_b = true; break; }
            if any_b {
                none_ok := true;
                for o: vr(r).ops {
                    bad := false;
                    for u: vv(o).users if u != r && introduces_bcast(u, o) { bad = true; break; }
                    if bad continue;
                    live_in_needs := vp_is_ir_value(o) && !vp_is_constant(o);
                    or_ := vp_def(o);
                    if live_in_needs || (or_ != NONE && vr(or_).kind == .REPLICATE && vr(or_).single_scalar) { none_ok = false; break; }
                }
                if none_ok continue;
            }
            has, is_iid, oc := vp_opcode_or_intrinsic_id(r);
            if is_iid vp_unported("narrowing intrinsics to single scalars");
            clone := vp_create_single_scalar_op(cast(u16) oc, vp_ops(r), NONE, vr(r).flags, .[], NONE, vv(d).uv);
            vp_insert_before(clone, r);
            vp_rauw(d, vr(clone).def);
            if vp_is_dead_recipe(r) vp_erase_recipe(r);
        }
    }
}

// removeRedundantExpandSCEVRecipes
vp_remove_redundant_expand_scev_recipes :: () {
    m: Table(Scev_Id, Vp_Val); m.allocator = temp;
    for r: vp_block_recipes(vp_entry_basic_block(vpl.entry)) {
        if vr(r).kind != .EXPAND_SCEV continue;
        found, v := table_find(*m, vr(r).expr);
        if !found { table_set(*m, vr(r).expr, vr(r).def); continue; }
        vp_rauw(vr(r).def, v);
        if vr(r).def == vpl.trip_count vpl.trip_count = v;
        vp_erase_recipe(r);
    }
}

// vputils::isElementwise
vp_is_elementwise :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    if k != .INSTRUCTION && k != .WIDEN return false;
    o := vr(r).opcode;
    return vp_is_ir_opcode(o) && (vp_ir_opcode(o) == .FNEG || is_binary_op(vp_ir_opcode(o)));
}
// simplifyReverses (pullOutPermutations with m_Reverse, then reverse(reverse(x)) -> x)
vp_simplify_reverses :: () {
    is_rev :: (v: Vp_Val) -> (bool, Vp_Val) { ok, r := vpm_vpi(v, VPI_REVERSE, 1); if ok return true, vp_op(r, 0); return false, NONE; }
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) for r: vp_block_recipes(bb) {
        if vr(r).dead || !vp_is_single_def_kind(vr(r).kind) || !vp_is_elementwise(r) continue;
        any := false;
        for vr(r).ops { ok, _ := is_rev(it); if ok { any = true; break; } }
        if !any continue;
        all := true;
        for vr(r).ops {
            ok, _ := is_rev(it);
            if ok && vp_has_one_use(it) continue;
            k := vv(it).kind;
            if k == .IR || k == .SYMBOLIC || k == .REGION continue;
            all = false; break;
        }
        if !all continue;
        for i: 0..vp_nops(r)-1 { ok, x := is_rev(vp_op(r, i)); if ok vp_set_operand(r, i, x); }
        res := vp_new_instruction(VPI_REVERSE, .[vr(r).def]);
        vp_insert_after(res, r);
        not_res :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return u != (cast(*Vp_Rec) data).*; }
        vp_replace_uses_with_if(vr(r).def, vr(res).def, not_res, *res);
    }
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) for r: vp_block_recipes(bb) {
        if vr(r).dead || !vp_is_vpi(r, VPI_REVERSE) || vp_nops(r) != 1 continue;
        ok, x := is_rev(vp_op(r, 0));
        if ok vp_rauw(vr(r).def, x);
    }
}


// mergeBlocksIntoPredecessors
vp_merge_blocks_into_predecessors :: () -> bool {
    wl: [..] Vp_Blk; wl.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) {
        if vb(bb).parent == NONE continue;
        p := vp_single_pred(bb);
        if p == NONE || !vp_is_basic(p) || vb(p).succs.count != 1 || vp_is_ir_basic(p) continue;
        array_add(*wl, bb);
    }
    for bb: wl {
        p := vp_single_pred(bb);
        for r: vp_block_recipes(bb) vp_move_before(r, p, NONE);
        vpbu_disconnect(p, bb);
        pr := vb(bb).parent;
        if pr != NONE && vb(pr).exiting == bb vp_region_set_exiting(pr, p);
        vpbu_transfer_successors(bb, p);
        vb(bb).dead = true;
    }
    return wl.count > 0;
}

// licm
vp_is_defined_outside_loop_regions :: (v: Vp_Val) -> bool {
    if vv(v).kind == .REGION return false;
    r := vp_def(v);
    if r == NONE return true;
    return !(vp_vector_loop_region() == NONE || vp_enclosing_loop_region(vr(r).parent) != NONE);
}
vp_licm_cannot_hoist_or_sink :: (r: Vp_Rec, first: Vp_Blk, last: Vp_Blk, sinking := false) -> bool {
    if vr(r).kind != .REPLICATE || !vp_may_read_or_write_memory(r) || vp_intrinsic_id(r) == IID_ASSUME
        return vp_cannot_hoist_or_sink_recipe(r, sinking);
    ok, loc := vp_memory_location(r);
    leader := ifx sinking then r else NONE;
    return !ok || !vp_can_hoist_or_sink_with_no_alias_check(loc, first, last, sinking, leader);
}
// VPIRMetadata recipes (the classes that derive from VPIRMetadata)
vp_has_ir_metadata :: (r: Vp_Rec) -> bool {
    k := vr(r).kind;
    return k == .INSTRUCTION || k == .WIDEN || k == .WIDEN_CAST || k == .WIDEN_INTRINSIC || k == .WIDEN_CALL || k == .HISTOGRAM ||
           k == .INTERLEAVE || k == .INTERLEAVE_EVL || k == .REPLICATE || vp_is_widen_memory_kind(k);
}
// vputils::getMemoryLocation: only the scoped-noalias tags
vp_memory_location :: (r: Vp_Rec) -> (bool, Mem_Loc) {
    loc: Mem_Loc;
    if !vp_has_ir_metadata(r) return false, loc;
    loc.tags.noalias = vp_get_md(r, md_kind_id("noalias"));
    loc.tags.scope = vp_get_md(r, md_kind_id("alias.scope"));
    return true, loc;
}
// VPBlockUtils::blocksInSingleSuccessorChainBetween
vpbu_blocks_in_single_successor_chain_between :: (first: Vp_Blk, last: Vp_Blk) -> [..] Vp_Blk {
    out: [..] Vp_Blk; out.allocator = temp;
    for vp_blocks_only_basic(vp_depth_first_deep(first)) { array_add(*out, it); if it == last break; }
    return out;
}
// SinkStoreInfo
Vp_Sink_Info :: struct { exclude: [] Vp_Rec; leader: Vp_Rec = NONE; pse: *Pse; l: Loop_Id = NONE; }
// SinkStoreInfo::isNoAliasViaDistance
vp_no_alias_via_distance :: (si: *Vp_Sink_Info, a: Vp_Rec, b: Vp_Rec) -> bool {
    if inst_op(vp_underlying_instr(a)) != .STORE || inst_op(vp_underlying_instr(b)) != .STORE return false;
    if !si.pse || si.l == NONE return a == b;
    sa := vp_scev_for_value(vp_op(a, 1), si.pse, si.l);
    sb := vp_scev_for_value(vp_op(b, 1), si.pse, si.l);
    if sc_is_cnc(sa) || sc_is_cnc(sb) return false;
    d := sc_get_minus(sa, sb);
    if !sc_is_const(d) return false;
    dist := sc_ap(d);
    size_a := dl_type_store_size(vp_scalar_type(vp_op(a, 0)));
    size_b := dl_type_store_size(vp_scalar_type(vp_op(b, 0)));
    max_size := max(size_a, size_b);
    max_vf: Ec = vpl.vfs[0];
    for vpl.vfs if ec_known_lt(max_vf, it) max_vf = it;
    if max_vf.scalable return false;
    abs := ifx ap_is_negative(dist) then ap_neg(dist) else dist;
    return ap_uge(abs, ap_from_u64(abs.bits, max_vf.n * max_size));
}
// canHoistOrSinkWithNoAliasCheck with an optional SinkStoreInfo (sinking)
vp_can_hoist_or_sink_with_no_alias_check_info :: (loc: Mem_Loc, first: Vp_Blk, last: Vp_Blk, sinking: bool, si: *Vp_Sink_Info) -> bool {
    for bb: vpbu_blocks_in_single_successor_chain_between(first, last) {
        r := vb(bb).first;
        while r != NONE {
            defer r = vr(r).next;
            if sinking && vr(r).kind == .REPLICATE && (array_find(si.exclude, r) || vp_no_alias_via_distance(si, r, si.leader)) continue;
            if !vp_may_write_to_memory(r) && !(sinking && vp_may_read_from_memory(r)) continue;
            ok, l2 := vp_memory_location(r);
            if !ok return false;
            if scoped_noalias_alias(l2, loc).kind != AR_NO return false;
        }
    }
    return true;
}
// canHoistOrSinkWithNoAliasCheck (with SinkStoreInfo(GroupLeader) when sinking)
vp_can_hoist_or_sink_with_no_alias_check :: (loc: Mem_Loc, first: Vp_Blk, last: Vp_Blk, sinking: bool, leader: Vp_Rec) -> bool {
    check_reads := sinking;
    for bb: vpbu_blocks_in_single_successor_chain_between(first, last) {
        r := vb(bb).first;
        while r != NONE {
            defer r = vr(r).next;
            // SinkStoreInfo::shouldSkip: without PSE, isNoAliasViaDistance(A, B) is A == B for two stores
            if sinking && r == leader && inst_op(vp_underlying_instr(r)) == .STORE continue;
            if !vp_may_write_to_memory(r) && !(check_reads && vp_may_read_from_memory(r)) continue;
            ok, l2 := vp_memory_location(r);
            if !ok return false;
            if scoped_noalias_alias(l2, loc).kind != AR_NO return false;
        }
    }
    return true;
}
vp_licm :: () {
    ph := vp_vector_preheader();
    region := vp_vector_loop_region();
    first := vp_entry_basic_block(region); last := vp_exiting_basic_block(region);
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(region).entry)) {
        for r: vp_block_recipes(bb) {
            if vp_licm_cannot_hoist_or_sink(r, first, last) continue;
            outside := true;
            for vr(r).ops if !vp_is_defined_outside_loop_regions(it) { outside = false; break; }
            if !outside continue;
            vp_move_before(r, ph, NONE);
        }
    }
    rpo := vp_rpo(vb(region).entry, false);
    for < bb: rpo {
        if !vp_is_basic(bb) continue;
        r := vb(bb).last;
        while r != NONE {
            prev := vr(r).prev;
            defer r = prev;
            if vp_licm_cannot_hoist_or_sink(r, first, last, true) continue;
            if vr(r).kind == .REPLICATE {
                if !vr(r).single_scalar continue;
                if inst_op(vp_underlying_instr(r)) == .STORE && !vp_is_defined_outside_loop_regions(vp_op(r, 1)) continue;
            }
            d := vr(r).def;
            sink_bb: Vp_Blk = NONE;
            bad := false;
            for u: vv(d).users {
                parent := vr(u).parent;
                if sink_bb != NONE && sink_bb != parent { bad = true; break; }
                sink_bb = parent;
                if vp_is_phi_recipe(u) || vp_enclosing_loop_region(parent) != NONE || vp_single_pred(parent) != region { bad = true; break; }
            }
            if bad continue;
            if sink_bb == NONE sink_bb = vp_single_succ(region);
            vp_move_before(r, sink_bb, vp_first_non_phi(sink_bb));
        }
    }
}

// VPlanTransforms::optimize
vp_optimize :: () {
    vp_remove_redundant_induction_casts();
    vp_reassociate_header_mask();
    vp_simplify_recipes();
    vp_remove_dead_recipes();
    vp_simplify_blends();
    vp_legalize_and_optimize_inductions();
    vp_narrow_to_single_scalar_recipes();
    vp_remove_redundant_expand_scev_recipes();
    vp_reassociate_header_mask();
    vp_simplify_recipes();
    vp_remove_branch_on_const(false);
    vp_simplify_reverses();
    vp_remove_dead_recipes();
    vp_create_and_optimize_replicate_regions();
    vp_merge_blocks_into_predecessors();
    vp_licm();
}

// VPlanTransforms::truncateToMinimalBitwidths (MinBWs empty is the only ported case)
vp_truncate_to_minimal_bitwidths :: (min_bws: *Table(Value_Id, u64)) {
    if vp_has_scalar_vf_only() return;
    if min_bws.count == 0 return;
    processed: Table(Vp_Val, Vp_Rec); processed.allocator = temp;
    ph := vp_vector_preheader();
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vp_vector_loop_region())) {
        for r: vp_block_recipes(bb) {
            k := vr(r).kind;
            if k != .WIDEN && k != .WIDEN_CAST && k != .REPLICATE && k != .WIDEN_LOAD && k != .WIDEN_INTRINSIC continue;
            uv := vv(vr(r).def).uv;
            if uv == NONE || !table_contains(min_bws, uv) continue;
            _, new_bits := table_find(min_bws, uv);
            if new_bits == 0 continue;
            if k == .REPLICATE || k == .WIDEN_CAST continue;
            res := vr(r).def;
            old_ty := vp_scalar_type(res);
            old_bits := cast(u64) type_bits(old_ty);
            new_ty := type_int(cast(u32) new_bits);
            if vp_is_with_ir_flags_kind(k) vp_drop_poison_generating_flags(r);
            if k == .WIDEN_LOAD || k == .WIDEN_INTRINSIC {
                if old_bits != new_bits {
                    b := vpb_after(r);
                    ext := vpb_widen_cast(*b, .ZEXT, res, old_ty);
                    vp_rauw(res, vr(ext).def);
                    vp_set_operand(ext, 0, res);
                }
                continue;
            }
            start := ifx vr(r).opcode == vp_opc(.SELECT) then 1 else 0;
            new_ops: [..] Vp_Val; new_ops.allocator = temp;
            for vr(r).ops array_add(*new_ops, it);
            for idx: start..new_ops.count-1 {
                o := new_ops[idx];
                if cast(u64) type_bits(vp_scalar_type(o)) == new_bits continue;
                found, tr := table_find(*processed, o);
                if !found {
                    b: Vp_Builder;
                    if vp_is_ir_value(o) b = vpb_at_end(ph); else b = vpb_before(r);
                    tr = vpb_widen_cast(*b, .TRUNC, o, new_ty);
                    table_set(*processed, o, tr);
                }
                new_ops[idx] = vr(tr).def;
            }
            nwr := vp_new_single_def(.WIDEN, new_ops, vp_compute_scalar_type_for_instruction(vr(r).opcode, new_ops), uv, vr(r).dl);
            vr(nwr).opcode = vr(r).opcode; vr(nwr).flags = vr(r).flags;
            for vr(r).md array_add(*vr(nwr).md, it);
            vp_insert_before(nwr, r);
            repl := vr(nwr).def;
            if old_bits != new_bits { b := vpb_after(nwr); repl = vr(vpb_widen_cast(*b, .ZEXT, repl, old_ty)).def; }
            vp_rauw(res, repl);
            vp_erase_recipe(r);
        }
    }
}

// VPlanTransforms::dropPoisonGeneratingRecipes
vp_drop_poison_generating_recipes :: () {
    visited: Table(Vp_Rec, bool); visited.allocator = temp;
    collect :: (root: Vp_Rec, visited: *Table(Vp_Rec, bool)) {
        wl: [..] Vp_Rec; wl.allocator = temp;
        array_add(*wl, root);
        while wl.count {
            cur := pop(*wl);
            if table_contains(visited, cur) continue;
            table_set(visited, cur, true);
            k := vr(cur).kind;
            if vp_is_widen_memory_kind(k) || k == .INTERLEAVE || k == .SCALAR_IV_STEPS || vp_is_header_phi_kind(k) continue;
            if vp_is_with_ir_flags_kind(k) {
                ok, a, b := vpm_binary_r(cur, vp_opc(.OR));
                if ok && vr(cur).flags.optype == .DISJOINT_OP && vr(cur).flags.disjoint {
                    bl := vpb_before(cur);
                    n := vpb_add(*bl, a, b, vr(cur).dl);
                    vp_set_underlying(vr(n).def, vv(vr(cur).def).uv);
                    vp_rauw(vr(cur).def, vr(n).def);
                    vp_erase_recipe(cur);
                    cur = n;
                } else vp_drop_poison_generating_flags(cur);
            }
            for o: vr(cur).ops { d := vp_def(o); if d != NONE array_add(*wl, d); }
        }
    }
    not_header_mask :: (m: Vp_Val) -> bool {
        if m == NONE return false;
        if vv(m).kind == .REGION && m == vb(vv(m).region).header_mask return false;
        okr, rr := vpm_vpi(m, VPI_REVERSE, 1);
        if okr { x := vp_op(rr, 0); if vv(x).kind == .REGION && x == vb(vv(x).region).header_mask return false; }
        return true;
    }
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vp_entry_basic_block(vp_vector_loop_region()))) {
        for r: vp_block_recipes(bb) {
            if vr(r).dead continue;
            k := vr(r).kind;
            if vp_is_widen_memory_kind(k) {
                ad := vp_def(vp_op(r, 0));
                mask := ifx vr(r).masked then vp_op(r, vp_nops(r) - 1) else NONE;
                if ad != NONE && vr(r).consecutive && not_header_mask(mask) collect(ad, *visited);
            } else if k == .INTERLEAVE {
                ad := vp_def(vp_op(r, 0));
                mask := ifx vr(r).masked then vp_op(r, vp_nops(r) - 1) else NONE;
                if ad != NONE && not_header_mask(mask) collect(ad, *visited);
            }
        }
    }
}

// VPlanTransforms::materializeHeaderMask
vp_materialize_header_mask :: (use_alm: bool, use_alm_cf: bool) {
    region := vp_vector_loop_region();
    hm := vb(region).header_mask;
    if hm == NONE || vp_num_users(hm) == 0 return;
    if use_alm_cf vp_unported("active lane masks for control flow (addVPLaneMaskPhiAndUpdateExitBranch)");
    header := vp_entry_basic_block(region);
    b := vpb_at(header, vp_first_non_phi(header));
    can_iv := vb(region).can_iv;
    w := vp_new_single_def(.WIDEN_CANONICAL_IV, .[can_iv], vv(can_iv).ty, NONE, NONE);
    vr(w).flags = vpf_wrap(true, false);
    vpb_insert(*b, w);
    mask: Vp_Val;
    if use_alm vp_unported("active lane masks (materializeHeaderMask)");
    mask = vr(vpb_icmp(*b, ICMP_ULE, vr(w).def, vp_or_create_backedge_taken_count())).def;
    vp_rauw(hm, mask);
}
