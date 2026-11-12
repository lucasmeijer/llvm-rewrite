// Replicate regions: createAndOptimizeReplicateRegions (addReplicateRegions, createReplicateRegion,
// sinkScalarOperands, mergeReplicateRegionsIntoSuccessors), hoistPredicatedLoads / sinkPredicatedStores (detection),
// VPBasicBlock::splitAt, VPBlockUtils::cloneFrom / VPRegionBlock::clone, UnrollState::unrollReplicateRegionByUF and
// the replicate-region part of replicateByVF (dissolveReplicateRegion and its helpers).
// Ported from llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp, VPlanUnroll.cpp and VPlan.cpp (LLVM 23.1.5).

// VPBranchOnMaskRecipe
vp_new_branch_on_mask :: (mask: Vp_Val, dl: Md_Id) -> Vp_Rec { return vp_new_recipe(.BRANCH_ON_MASK, .[mask], dl); }
// VPPredInstPHIRecipe
vp_new_pred_inst_phi :: (v: Vp_Val, dl: Md_Id) -> Vp_Rec { return vp_new_single_def(.PRED_INST_PHI, .[v], vp_scalar_type(v), NONE, dl); }

// VPBasicBlock::splitAt
vp_split_at :: (bb: Vp_Blk, at: Vp_Rec) -> Vp_Blk {
    split := vp_create_basic_block(tconcat(vb(bb).name, ".split"));
    vpbu_insert_block_after(split, bb);
    pr := vb(bb).parent;
    if pr != NONE && vb(pr).exiting == bb vp_region_set_exiting(pr, split);
    r := at;
    while r != NONE {
        nx := vr(r).next;
        vp_move_before(r, split, NONE);
        r = nx;
    }
    return split;
}

// VPReplicateRecipe::getMask / operandsWithoutMask
vp_replicate_mask :: (r: Vp_Rec) -> Vp_Val { if vr(r).predicated return vp_op(r, vp_nops(r) - 1); return NONE; }

// createReplicateRegion
vp_create_replicate_region_for :: (pred: Vp_Rec, parent_region: Vp_Blk) -> Vp_Blk {
    ui := vp_underlying_instr(pred);
    rname := tconcat("pred.", opcode_name(inst_op(ui)));
    mask := vp_replicate_mask(pred);
    md := vp_def(mask);
    bom := vp_new_branch_on_mask(mask, ifx md != NONE then vr(md).dl else NONE);
    entry := vp_create_basic_block(tconcat(rname, ".entry"), bom);
    without := vp_new_replicate(ui, vp_ops_without_mask(pred), vr(pred).single_scalar, NONE, vr(pred).flags, vr(pred).md, vr(pred).dl);
    pbb := vp_create_basic_block(tconcat(rname, ".if"), without);
    exiting := vp_create_basic_block(tconcat(rname, ".continue"));
    region := vp_create_replicate_region(entry, exiting, rname);
    vb(region).parent = parent_region;
    vpbu_insert_two_blocks_after(pbb, exiting, entry);
    vpbu_connect(pbb, exiting);
    if vp_num_users(vr(pred).def) {
        phi := vp_new_pred_inst_phi(vr(without).def, vr(without).dl);
        vp_append_recipe(exiting, phi);
        vp_rauw(vr(pred).def, vr(phi).def);
    }
    vp_erase_recipe(pred);
    return region;
}

// addReplicateRegions
vp_add_replicate_regions :: () {
    wl: [..] Vp_Rec; wl.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vpl.entry)) for r: vp_block_recipes(bb)
        if vr(r).kind == .REPLICATE && vr(r).predicated array_add(*wl, r);
    bbnum := 0;
    for rep: wl {
        cur := vr(rep).parent;
        split := vp_split_at(cur, rep);
        orig_bb := inst_block(vp_underlying_instr(rep));
        if ir.v_name[orig_bb].count { vb(split).name = tprint("%.%", ir.v_name[orig_bb], bbnum); bbnum += 1; }
        else vb(split).name = "";
        region := vp_create_replicate_region_for(rep, vb(cur).parent);
        vpbu_insert_on_edge(cur, split, region);
        pr := vb(region).parent;
        if pr != NONE && vb(pr).exiting == cur vp_region_set_exiting(pr, split);
    }
}

// sinkScalarOperands
vp_sink_scalar_operands :: () -> bool {
    scalar_vf_only := vp_has_scalar_vf_only();
    changed := false;
    Item :: struct { to: Vp_Blk; r: Vp_Rec; }
    wl: [..] Item; wl.allocator = temp;   // SetVector
    insert_candidate :: (wl: *[..] Item, sink_to: Vp_Blk, op: Vp_Val, scalar_vf_only: bool) {
        c := vp_def(op);
        if c == NONE || !vp_is_single_def_kind(vr(c).kind) return;
        k := vr(c).kind;
        if k != .REPLICATE && k != .SCALAR_IV_STEPS return;
        if vr(c).parent == sink_to || vp_cannot_hoist_or_sink_recipe(c, true) return;
        if k == .REPLICATE && !scalar_vf_only && vr(c).single_scalar return;
        for wl.* if it.to == sink_to && it.r == c return;
        array_add(wl, .{sink_to, c});
    }
    for reg: vp_blocks_only_region(vp_depth_first_deep(vpl.entry)) {
        e := vp_entry_basic_block(reg);
        if !vp_is_replicator(reg) || vb(e).succs.count != 2 continue;
        bb := vb(e).succs[0];
        if vp_single_succ(bb) != vp_exiting_basic_block(reg) continue;
        for r: vp_block_recipes(bb) for o: vr(r).ops insert_candidate(*wl, bb, o, scalar_vf_only);
    }
    i := 0;
    while i < wl.count {
        sink_to := wl[i].to; cand := wl[i].r;
        i += 1;
        d := vr(cand).def;
        bad := false; outside := false;
        for u: vv(d).users {
            if vr(u).parent == sink_to continue;
            outside = true;
            if !vp_uses_first_lane_only(u, d) { bad = true; break; }
        }
        if bad continue;
        if outside {
            if scalar_vf_only continue;
            clone: Vp_Rec;
            if vr(cand).kind == .REPLICATE {
                ui := vp_underlying_instr(cand);
                clone = vp_create_single_scalar_op(vp_opc(inst_op(ui)), vp_ops(cand), NONE, vr(cand).flags, vr(cand).md, vr(cand).dl, ui);
            } else {
                clone = vp_clone(cand);
            }
            vp_insert_before(clone, cand);
            not_in :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return vr(u).parent != (cast(*Vp_Blk) data).*; }
            vp_replace_uses_with_if(d, vr(clone).def, not_in, *sink_to);
        }
        vp_move_before(cand, sink_to, vp_first_non_phi(sink_to));
        for o: vr(cand).ops insert_candidate(*wl, sink_to, o, scalar_vf_only);
        changed = true;
    }
    return changed;
}

// getPredicatedMask
vp_region_predicated_mask :: (reg: Vp_Blk) -> Vp_Val {
    e := vb(reg).entry;
    if !vp_is_basic(e) return NONE;
    f := vb(e).first;
    if f == NONE || vr(f).next != NONE || vr(f).kind != .BRANCH_ON_MASK return NONE;
    return vp_op(f, 0);
}
// getPredicatedThenBlock
vp_region_predicated_then_block :: (reg: Vp_Blk) -> Vp_Blk {
    e := vb(reg).entry;
    if vb(e).succs.count != 2 return NONE;
    s0 := vb(e).succs[0]; s1 := vb(e).succs[1];
    if !vp_is_basic(s0) || !vp_is_basic(s1) return NONE;
    if vb(s0).succs.count + vb(s1).succs.count != 1 return NONE;
    if vp_single_succ(s0) == s1 return s0;
    if vp_single_succ(s1) == s0 return s1;
    return NONE;
}

// mergeReplicateRegionsIntoSuccessors
vp_merge_replicate_regions_into_successors :: () -> bool {
    transformed: [..] Vp_Blk; transformed.allocator = temp;
    wl: [..] Vp_Blk; wl.allocator = temp;
    for r1: vp_blocks_only_region(vp_depth_first_deep(vpl.entry)) {
        if !vp_is_replicator(r1) continue;
        mid := vp_single_succ(r1);
        if mid == NONE || !vp_is_basic(mid) || !vp_block_empty(mid) continue;
        r2 := vp_single_succ(mid);
        if r2 == NONE || !vp_is_region(r2) || !vp_is_replicator(r2) continue;
        m1 := vp_region_predicated_mask(r1);
        m2 := vp_region_predicated_mask(r2);
        if m1 == NONE || m1 != m2 continue;
        array_add(*wl, r1);
    }
    for r1: wl {
        if array_find(transformed, r1) continue;
        mid := vp_single_succ(r1);
        r2 := vp_single_succ(mid);
        then1 := vp_region_predicated_then_block(r1);
        then2 := vp_region_predicated_then_block(r2);
        if then1 == NONE || then2 == NONE continue;
        r := vb(then1).last;
        while r != NONE {
            pv := vr(r).prev;
            vp_move_before(r, then2, vp_first_non_phi(then2));
            r = pv;
        }
        merge1 := vp_single_succ(then1);
        merge2 := vp_single_succ(then2);
        r = vb(merge1).last;
        while r != NONE {
            pv := vr(r).prev;
            defer r = pv;
            pred_inst := vp_op(r, 0);
            in_then2 :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return vr(u).parent == (cast(*Vp_Blk) data).*; }
            vp_replace_uses_with_if(vr(r).def, pred_inst, in_then2, *then2);
            if vp_num_users(vr(r).def) == 0 { vp_erase_recipe(r); continue; }
            vp_move_before(r, merge2, vb(merge2).first);
        }
        e1 := vp_entry_basic_block(r1);
        r = vb(e1).last;
        while r != NONE { pv := vr(r).prev; vp_erase_recipe(r); r = pv; }
        preds: [..] Vp_Blk; preds.allocator = temp;
        for vb(r1).preds array_add(*preds, it);
        for p: preds { vpbu_disconnect(p, r1); vpbu_connect(p, mid); }
        vpbu_disconnect(r1, mid);
        array_add(*transformed, r1);
    }
    return transformed.count > 0;
}

// createAndOptimizeReplicateRegions
vp_create_and_optimize_replicate_regions :: () {
    vp_add_replicate_regions();
    while true {
        s := vp_sink_scalar_operands();
        s |= vp_merge_replicate_regions_into_successors();
        s |= vp_merge_blocks_into_predecessors();
        if !s break;
    }
}

// hoistPredicatedLoads / sinkPredicatedStores: groups of predicated replicated loads (stores) of one address with
// collectGroupedReplicateMemOps + collectComplementaryPredicatedMemOps
vp_collect_complementary_predicated_mem_ops :: (opc: Opcode, pse: *Pse, l: Loop_Id) -> [..] [..] Vp_Rec {
    is_load := opc == .LOAD;
    Group :: struct { addr: Scev_Id; ty: Type_Id; rs: [..] Vp_Rec; }
    groups: [..] Group; groups.allocator = temp;
    for bb: vp_blocks_only_basic(vp_depth_first_deep(vb(vp_vector_loop_region()).entry)) for r: vp_block_recipes(bb) {
        if vr(r).kind != .REPLICATE || inst_op(vp_underlying_instr(r)) != opc || !vr(r).predicated continue;
        a := vp_scev_for_value(vp_op(r, ifx is_load then 0 else 1), pse, l);
        if sc_is_cnc(a) continue;
        ty := ifx is_load then vp_scalar_type(vr(r).def) else vp_scalar_type(vp_op(r, 0));
        g: *Group = null;
        for * groups if it.addr == a && it.ty == ty { g = it; break; }
        if !g { ng: Group; ng.addr = a; ng.ty = ty; ng.rs.allocator = temp; array_add(*groups, ng); g = *groups[groups.count - 1]; }
        array_add(*g.rs, r);
    }
    dt := vp_dt_build();
    out: [..] [..] Vp_Rec; out.allocator = temp;
    for * g: groups {
        // stable_sort by dominance, the most dominating first
        for i: 1..g.rs.count - 1 {
            j := i;
            while j > 0 && vp_dt_properly_dominates(*dt, g.rs[j], g.rs[j - 1]) {
                t := g.rs[j]; g.rs[j] = g.rs[j - 1]; g.rs[j - 1] = t;
                j -= 1;
            }
        }
        if g.rs.count < 2 continue;
        // every recipe of the address joins the first group; it is kept when two masks are complementary
        group: [..] Vp_Rec; group.allocator = temp;
        for g.rs array_add(*group, it);
        mi := vp_replicate_mask(group[0]);
        complementary := false;
        for k: 1..group.count - 1 {
            mj := vp_replicate_mask(group[k]);
            ok1, x1 := vpm_not(mi);
            ok2, x2 := vpm_not(mj);
            if (ok1 && x1 == mj) || (ok2 && x2 == mi) complementary = true;
        }
        if complementary array_add(*out, group);
    }
    return out;
}
// getCommonMetadata
vp_common_metadata :: (group: [] Vp_Rec) -> [..] Vp_Md {
    md: [..] Vp_Md; md.allocator = temp;
    for vr(group[0]).md array_add(*md, it);
    for r: group { if it_index == 0 continue; vp_md_intersect(*md, vr(r).md); }
    return md;
}
vp_find_recipe_with_min_align :: (group: [] Vp_Rec) -> Vp_Rec {
    best := group[0];
    for group if inst(vp_underlying_instr(it)).align < inst(vp_underlying_instr(best)).align best = it;
    return best;
}
// VPlanTransforms::hoistPredicatedLoads
vp_hoist_predicated_loads :: (pse: *Pse, l: Loop_Id) {
    groups := vp_collect_complementary_predicated_mem_ops(.LOAD, pse, l);
    for group: groups {
        earliest := group[0];
        first := vr(earliest).parent; last := vr(group[group.count - 1]).parent;
        ok, loc := vp_memory_location(earliest);
        si: Vp_Sink_Info;
        if !ok || !vp_can_hoist_or_sink_with_no_alias_check_info(loc, first, last, false, *si) continue;
        md := vp_common_metadata(group);
        minal := vp_find_recipe_with_min_align(group);
        single := vr(earliest).single_scalar;
        ul := vp_new_replicate(vp_underlying_instr(minal), .[vp_op(earliest, 0)], single, NONE, vr(earliest).flags, md, NONE);
        vp_insert_before(ul, earliest);
        for r: group { vp_rauw(vr(r).def, vr(ul).def); vp_erase_recipe(r); }
    }
}
// VPlanTransforms::sinkPredicatedStores
vp_sink_predicated_stores :: (pse: *Pse, l: Loop_Id) {
    groups := vp_collect_complementary_predicated_mem_ops(.STORE, pse, l);
    for group: groups {
        // canSinkStoreWithNoAliasCheck
        ok, loc := vp_memory_location(group[0]);
        if !ok || loc.tags.scope == NONE continue;
        si := Vp_Sink_Info.{group, group[0], pse, l};
        if !vp_can_hoist_or_sink_with_no_alias_check_info(loc, vr(group[0]).parent, vr(group[group.count - 1]).parent, true, *si) continue;
        last := group[group.count - 1];
        md := vp_common_metadata(group);
        sel := vp_op(group[0], 0);
        b := vpb_before(last);
        single := vr(group[0]).single_scalar;
        for i: 1..group.count - 1 {
            v := vp_op(group[i], 0);
            sel = vr(vpb_select(*b, vp_replicate_mask(group[i]), v, sel, vr(group[i]).dl, "", vp_default_flags(vp_opc(.SELECT), vp_scalar_type(v)))).def;
        }
        minal := vp_find_recipe_with_min_align(group);
        us := vp_new_replicate(vp_underlying_instr(minal), .[sel, vp_op(last, 1)], single, NONE, vr(last).flags, md, NONE);
        vp_insert_before(us, last);
        for r: group vp_erase_recipe(r);
    }
}

// ---------------------------------------------------------------- cloning blocks

// VPBasicBlock::clone
vp_clone_basic_block :: (bb: Vp_Blk) -> Vp_Blk {
    n := vp_create_basic_block(vb(bb).name);
    for r: vp_block_recipes(bb) vp_append_recipe(n, vp_clone(r));
    return n;
}
vp_clone_block :: (b: Vp_Blk) -> Vp_Blk {
    if vp_is_region(b) return vp_clone_region(b);
    assert(vp_is_basic(b) && !vp_is_ir_basic(b), "cloning an IR basic block");
    return vp_clone_basic_block(b);
}
// VPBlockUtils::cloneFrom: (new entry, new exiting)
vp_clone_from :: (entry: Vp_Blk) -> (Vp_Blk, Vp_Blk) {
    old: [..] Vp_Blk; old.allocator = temp;
    new: [..] Vp_Blk; new.allocator = temp;
    in_region := vb(entry).parent != NONE;
    exiting: Vp_Blk = NONE;
    for b: vp_depth_first_shallow(entry) {
        array_add(*old, b); array_add(*new, vp_clone_block(b));
        if in_region && vb(b).succs.count == 0 exiting = b;
    }
    map :: (old: [] Vp_Blk, new: [] Vp_Blk, b: Vp_Blk) -> Vp_Blk { for old if it == b return new[it_index]; return NONE; }
    for b, i: old {
        n := new[i];
        vb(n).preds.count = 0; vb(n).succs.count = 0;
        for p: vb(b).preds array_add(*vb(n).preds, map(old, new, p));
        for s: vb(b).succs array_add(*vb(n).succs, map(old, new, s));
    }
    return new[0], ifx exiting != NONE then map(old, new, exiting) else NONE;
}
// VPRegionBlock::clone
vp_clone_region :: (reg: Vp_Blk) -> Vp_Blk {
    ne, nx := vp_clone_from(vb(reg).entry);
    can_iv := vb(reg).can_iv;
    n: Vp_Blk;
    if can_iv != NONE n = vp_create_loop_region(vv(can_iv).ty, vv(can_iv).dl, vb(reg).name, ne, nx);
    else n = vp_create_replicate_region(ne, nx, vb(reg).name);
    if vb(reg).header_mask != NONE vp_unported("cloning a region with a header mask");
    for b: vp_depth_first_shallow(ne) vb(b).parent = n;
    return n;
}

// UnrollState::unrollReplicateRegionByUF
vpu_unroll_replicate_region :: (u: *Vp_Unroll_State, reg: Vp_Blk) {
    insert_pt := vp_single_succ(reg);
    for part: 1..u.uf - 1 {
        copy := vp_clone_region(reg);
        vpbu_insert_block_before(copy, insert_pt);
        pi := vp_depth_first_shallow(vb(copy).entry);
        p0 := vp_depth_first_shallow(vb(reg).entry);
        for b, j: pi {
            b0 := p0[j];
            r := vb(b).first; r0 := vb(b0).first;
            while r != NONE && r0 != NONE {
                vpu_remap_operands(u, r, part);
                if vr(r).kind == .SCALAR_IV_STEPS vp_add_start_index_for_scalar_steps(r, part);
                vpu_add_recipe_for_part(u, r0, r, part);
                r = vr(r).next; r0 = vr(r0).next;
            }
        }
    }
}

// ---------------------------------------------------------------- dissolving replicate regions (replicateByVF)

// convertRecipesInRegionBlocksToSingleScalar
vp_convert_region_recipes_to_single_scalar :: (idx_ty: Type_Id, entry: Vp_Blk, vf: Ec) {
    idx0 := vp_const_int(idx_ty, 0);
    for b: vp_depth_first_shallow(entry) {
        r := vb(b).first;
        while r != NONE {
            nx := vr(r).next;
            defer r = nx;
            dl := vr(r).dl;
            if !ec_is_scalar(vf) {
                for i: 0..vp_nops(r) - 1 {
                    o := vp_op(r, i);
                    d := vp_def(o);
                    if (d != NONE && vr(d).kind == .SCALAR_IV_STEPS && vr(d).parent == b) || vp_is_single_scalar(o) continue;
                    bb := vpb_before(r);
                    ext := vpb_nary(*bb, vp_opc(.EXTRACTELEMENT), .[o, idx0], .{}, .[], dl);
                    vp_set_operand(r, i, vr(ext).def);
                }
            }
            k := vr(r).kind;
            if k == .REPLICATE {
                ui := vp_underlying_instr(r);
                n := vp_create_single_scalar_op(vp_opc(inst_op(ui)), vp_ops(r), NONE, vr(r).flags, vr(r).md, dl, ui);
                vp_insert_before(n, r);
                vp_rauw(vr(r).def, vr(n).def);
                vp_erase_recipe(r);
            } else if k == .BRANCH_ON_MASK {
                bb := vpb_before(r);
                vpb_nary(*bb, VPI_BRANCH_ON_COND, .[vp_op(r, 0)], .{}, .[], dl);
                vp_erase_recipe(r);
            } else if k == .PRED_INST_PHI {
                pop := vp_op(r, 0);
                poison := vp_poison(vp_scalar_type(pop));
                bb := vpb_before(r);
                np := vpb_scalar_phi(*bb, .[poison, pop], dl);
                vp_rauw(vr(r).def, vr(np).def);
                vp_erase_recipe(r);
            }
        }
    }
}

// processLaneForReplicateRegion
vp_process_lane_for_replicate_region :: (idx_ty: Type_Id, lane: u32, old_entry: Vp_Blk, new_entry: Vp_Blk) {
    o2n: Table(Vp_Val, Vp_Val); o2n.allocator = temp;
    idx_lane := vp_const_int(idx_ty, lane);
    olds := vp_depth_first_shallow(old_entry);
    news := vp_depth_first_shallow(new_entry);
    assert(olds.count == news.count);
    for ob, j: olds {
        nb := news[j];
        or := vb(ob).first; nr := vb(nb).first;
        while or != NONE {
            for k: 0..vp_num_defined_values(or) - 1 table_set(*o2n, vp_defined_value(or, k), vp_defined_value(nr, k));
            for i: 0..vp_nops(nr) - 1 {
                found, nv := table_find(*o2n, vp_op(nr, i));
                if found vp_set_operand(nr, i, nv);
            }
            if vr(nr).kind == .SCALAR_IV_STEPS {
                vp_add_lane_to_start_index(nr, lane, nr);
            } else if vp_is_vpi(nr, vp_opc(.EXTRACTELEMENT)) && vp_nops(nr) == 2 {
                assert(vpm_zero_int(vp_op(nr, 1)), "extract indices must be zero");
                vp_set_operand(nr, 1, idx_lane);
            } else if vp_is_vp_phi(nr) {
                bv := vp_single_user(vr(or).def);
                if bv != NONE && (vp_is_vpi(bv, VPI_BUILD_VECTOR) || vp_is_vpi(bv, VPI_BUILD_STRUCT_VECTOR)) {
                    assert(vp_op(bv, 0) == vr(or).def, "Unexpected first operand of build vector user");
                    vp_set_operand(bv, lane, vr(nr).def);
                }
            }
            or = vr(or).next; nr = vr(nr).next;
        }
    }
}

// dissolveReplicateRegion
vp_dissolve_replicate_region :: (reg: Vp_Blk, vf: Ec, idx_ty: Type_Id) {
    first_entry := vb(reg).entry;
    first_exiting := vb(reg).exiting;
    pred := vp_single_pred(reg);
    assert(pred != NONE, "Replicate region must have a single predecessor");
    succ := vp_single_succ(reg);
    vpbu_disconnect(pred, reg);
    vpbu_disconnect(reg, succ);
    parent := vb(reg).parent;
    for b: vp_depth_first_shallow(first_entry) vb(b).parent = parent;
    vb(reg).dead = true;
    vp_convert_region_recipes_to_single_scalar(idx_ty, first_entry, vf);
    if ec_is_scalar(vf) {
        vpbu_connect(pred, first_entry);
        vpbu_connect(first_exiting, succ);
        return;
    }
    num_lanes := cast(u32) vf.n;
    bvs: [..] Vp_Rec; bvs.allocator = temp;
    for p: vp_block_phis(first_exiting) {
        if vp_only_first_lane_used(vr(p).def) continue;
        sty := vp_scalar_type(vr(p).def);
        if type_kind(sty) == .STRUCT vp_unported("struct-typed predicated values (BuildStructVector)");
        poison := vp_poison(sty);
        ops: [..] Vp_Val; ops.allocator = temp;
        for 0..num_lanes - 1 array_add(*ops, poison);
        bv := vp_new_instruction(VPI_BUILD_VECTOR, ops, .{}, .[], NONE, "");
        array_add(*bvs, bv);
        vp_rauw(vr(p).def, vr(bv).def);
        vp_set_operand(bv, 0, vr(p).def);
        vp_insert_recipe(bv, succ, vp_first_non_phi(succ));
    }
    next_entry := succ;
    lane := cast(s64) num_lanes - 1;
    while lane > 0 {
        ce, cx := vp_clone_from(first_entry);
        for b: vp_depth_first_shallow(ce) vb(b).parent = parent;
        vp_process_lane_for_replicate_region(idx_ty, cast(u32) lane, first_entry, ce);
        vpbu_connect(cx, next_entry);
        next_entry = ce;
        lane -= 1;
    }
    vpbu_connect(pred, first_entry);
    vpbu_connect(first_exiting, next_entry);
    for bv: bvs {
        assert(vp_nops(bv) == cast(s64) num_lanes, "BuildVector must have one operand per lane");
        ops := vp_ops(bv);
        for o, idx: ops {
            sphi := vp_def(o);
            dl := vr(sphi).dl;
            pred_op := vp_def(vp_op(sphi, 1));
            poison := vp_op(sphi, 0);
            prev := ifx idx == 0 then poison else vp_op(bv, idx - 1);
            b := vpb_after(pred_op);
            ins := vpb_nary(*b, vp_opc(.INSERTELEMENT), .[prev, vr(pred_op).def, vp_const_int(type_int(64), cast(u64) idx)], .{}, .[], dl);
            wp := vp_new_single_def(.WIDEN_PHI, .[prev, vr(ins).def], vp_scalar_type(prev), NONE, dl);
            vp_insert_before(wp, sphi);
            vp_rauw(vr(sphi).def, vr(wp).def);
            vp_erase_recipe(sphi);
        }
        vp_rauw(vr(bv).def, vp_op(bv, num_lanes - 1));
        vp_erase_recipe(bv);
    }
}
