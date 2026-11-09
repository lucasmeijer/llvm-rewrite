// VPlan predication (if-conversion of the loop body): VPPredicator (edge and block masks, phis to blends),
// introduceMasksAndLinearize, VPInstruction::addMask; VPBlendRecipe simplification (simplifyBlends,
// removeCommonBlendMask).
// Ported from llvm/lib/Transforms/Vectorize/VPlanPredicator.cpp and VPlanTransforms.cpp (LLVM 23.1.5).
// VPPostDominatorTree is only queried for blocks of the (acyclic, single-exiting) loop body, where post-dominance is
// computed directly on the region's DAG.

Vp_Predicator :: struct {
    b: Vp_Builder;
    dt: Vp_Dom_Tree;
    pdom: Table(Vp_Blk, [..] Vp_Blk);      // post-dominator sets inside the loop region (incl. the block itself)
    edge_mask: Table(u64, Vp_Val);         // EdgeMaskCache (NONE = all-one)
    edge_set: Table(u64, bool);            // which edges have a cached mask
    block_mask: Table(Vp_Blk, Vp_Val);     // BlockMaskCache
}
vpp_edge_key :: (s: Vp_Blk, d: Vp_Blk) -> u64 { return ((cast(u64) s) << 32) | cast(u64) d; }

// post-dominance on the loop body DAG: pdom(B) = {B} + the intersection of pdom over B's successors
vpp_compute_pdom :: (p: *Vp_Predicator, header: Vp_Blk) {
    rpo := vp_rpo(header, false);
    for < b: rpo {
        set: [..] Vp_Blk; set.allocator = temp;
        succs := vb(b).succs;
        if succs.count {
            first := table_find_pointer(*p.pdom, succs[0]);
            if first for x: first.* {
                in_all := true;
                for k: 1..succs.count-1 {
                    o := table_find_pointer(*p.pdom, succs[k]);
                    if !o || !vp_contains_blk(o.*, x) { in_all = false; break; }
                }
                if in_all array_add(*set, x);
            }
        }
        array_add(*set, b);
        table_set(*p.pdom, b, set);
    }
}
// VPPostDominatorTree::properlyDominates(A, B): A post-dominates B, A != B
vpp_properly_post_dominates :: (p: *Vp_Predicator, a: Vp_Blk, b: Vp_Blk) -> bool {
    if a == b return false;
    s := table_find_pointer(*p.pdom, b);
    return s != null && vp_contains_blk(s.*, a);
}
vp_dt_idom :: (t: *Vp_Dom_Tree, b: Vp_Blk) -> Vp_Blk { found, i := table_find(*t.idom, b); if !found return NONE; return i; }

vpp_get_block_in_mask :: (p: *Vp_Predicator, b: Vp_Blk) -> Vp_Val { found, m := table_find(*p.block_mask, b); return ifx found then m else NONE; }
vpp_set_block_in_mask :: (p: *Vp_Predicator, b: Vp_Blk, m: Vp_Val) { table_set(*p.block_mask, b, m); }
vpp_set_edge_mask :: (p: *Vp_Predicator, s: Vp_Blk, d: Vp_Blk, m: Vp_Val) -> Vp_Val {
    k := vpp_edge_key(s, d);
    table_set(*p.edge_mask, k, m); table_set(*p.edge_set, k, true);
    return m;
}

// VPPredicator::createEdgeMask
vpp_create_edge_mask :: (p: *Vp_Predicator, src: Vp_Blk, dst: Vp_Blk) -> Vp_Val {
    k := vpp_edge_key(src, dst);
    found, em := table_find(*p.edge_mask, k);
    if found && em != NONE return em;
    src_mask := vpp_get_block_in_mask(p, src);
    if vb(src).succs.count == 1 return vpp_set_edge_mask(p, src, dst, src_mask);
    term := vp_terminator(src);
    if vr(term).opcode == vp_opc(.SWITCH) vp_unported("switch edge masks (createSwitchEdgeMasks)");
    assert(vr(term).opcode == VPI_BRANCH_ON_COND, "Unsupported terminator");
    if vb(src).succs[0] == vb(src).succs[1] return vpp_set_edge_mask(p, src, dst, src_mask);
    em = vp_op(term, 0);
    if vb(src).succs[0] != dst em = vr(vpb_not(*p.b, em, vr(term).dl)).def;
    if src_mask != NONE em = vr(vpb_logical_and(*p.b, src_mask, em, vr(term).dl)).def;
    return vpp_set_edge_mask(p, src, dst, em);
}

// VPPredicator::createBlockInMask
vpp_create_block_in_mask :: (p: *Vp_Predicator, bb: Vp_Blk) {
    p.b = vpb_at(bb, vp_first_non_phi(bb));
    idom := vp_dt_idom(*p.dt, bb);
    assert(idom != NONE, "Block in loop must have immediate dominator");
    if vpp_properly_post_dominates(p, bb, idom) { vpp_set_block_in_mask(p, bb, vpp_get_block_in_mask(p, idom)); return; }
    mask: Vp_Val = NONE;
    seen: [..] Vp_Blk; seen.allocator = temp;
    for pred: vb(bb).preds {
        if vp_contains_blk(seen, pred) continue;
        array_add(*seen, pred);
        em := vpp_create_edge_mask(p, pred, bb);
        if em == NONE { vpp_set_block_in_mask(p, bb, NONE); return; }
        if mask == NONE { mask = em; continue; }
        mask = vr(vpb_or(*p.b, mask, em)).def;
    }
    vpp_set_block_in_mask(p, bb, mask);
}

// VPPredicator::getMaskInsertPoint
vpp_mask_insert_point :: (p: *Vp_Predicator, bb: Vp_Blk) -> Vp_Rec {
    m := vpp_get_block_in_mask(p, bb);
    if m != NONE {
        mr := vp_def(m);
        if mr != NONE && vr(mr).parent == bb return vr(mr).next;
    }
    return vp_first_non_phi(bb);
}

// VPBlendRecipe constructor
vp_new_blend :: (phi: Value_Id, ops: [] Vp_Val, flags: Vp_Flags, dl: Md_Id) -> Vp_Rec {
    r := vp_new_single_def(.BLEND, ops, vp_scalar_type(ops[0]), phi, dl);
    vr(r).flags = flags;
    return r;
}
vp_blend_is_normalized :: (r: Vp_Rec) -> bool { return (vp_nops(r) % 2) == 1; }
vp_blend_num_incoming :: (r: Vp_Rec) -> s64 { n := ifx vp_blend_is_normalized(r) then 1 else 0; return (vp_nops(r) + n) / 2; }
vp_blend_incoming :: (r: Vp_Rec, i: s64) -> Vp_Val {
    if i == 0 return vp_op(r, 0);
    return vp_op(r, i * 2 - (ifx vp_blend_is_normalized(r) then 1 else 0));
}
vp_blend_mask :: (r: Vp_Rec, i: s64) -> Vp_Val {
    if i == 0 return vp_op(r, 1);
    return vp_op(r, i * 2 + (ifx vp_blend_is_normalized(r) then 0 else 1));
}
vp_blend_set_mask :: (r: Vp_Rec, i: s64, v: Vp_Val) {
    if i == 0 { vp_set_operand(r, 1, v); return; }
    vp_set_operand(r, i * 2 + (ifx vp_blend_is_normalized(r) then 0 else 1), v);
}

// VPPredicator::convertPhisToBlends
vpp_convert_phis_to_blends :: (p: *Vp_Predicator, bb: Vp_Blk) {
    p.b = vpb_at(bb, vpp_mask_insert_point(p, bb));
    for phir: vp_block_phis(bb) {
        assert(vp_is_vp_phi(phir), "expected VPPhis");
        not_poison: [..] Vp_Val; not_poison.allocator = temp;
        for o: vr(phir).ops if !(vp_is_ir_value(o) && vkind(vp_ir(o)) == .C_POISON) array_add(*not_poison, o);
        all_eq := true;
        for not_poison if it != not_poison[0] { all_eq = false; break; }
        if all_eq {
            vp_rauw(vr(phir).def, ifx not_poison.count == 0 then vp_op(phir, 0) else not_poison[0]);
            vp_erase_recipe(phir);
            continue;
        }
        ops: [..] Vp_Val; ops.allocator = temp;
        for k: 0..vp_nops(phir)-1 {
            array_add(*ops, vp_op(phir, k));
            array_add(*ops, vpp_create_edge_mask(p, vp_phi_incoming_block(phir, k), bb));
        }
        blend := vp_new_blend(vp_uv(vr(phir).def), ops, vr(phir).flags, vr(phir).dl);
        vpb_insert(*p.b, blend);
        vp_rauw(vr(phir).def, vr(blend).def);
        vp_erase_recipe(phir);
    }
}

// VPInstruction::alwaysUnmasked / addMask
vpi_always_unmasked :: (r: Vp_Rec) -> bool {
    o := vr(r).opcode;
    if o == VPI_MASKED_COND return false;
    if vv(vr(r).def).uv == NONE return true;
    return vp_opcode_is_cast(o) || o == vp_opc(.PHI) || o == vp_opc(.GEP);
}
vpi_add_mask :: (r: Vp_Rec, m: Vp_Val) {
    assert(!vp_is_masked(r), "recipe is already masked");
    if vpi_always_unmasked(r) return;
    vp_add_operand(r, m);
}

// VPlanTransforms::introduceMasksAndLinearize
vp_introduce_masks_and_linearize :: () {
    region := vp_vector_loop_region();
    header := vp_entry_basic_block(region);
    rpo := vp_rpo(header, false);
    p: Vp_Predicator;
    p.dt = vp_dt_build();
    p.pdom.allocator = temp; p.edge_mask.allocator = temp; p.edge_set.allocator = temp; p.block_mask.allocator = temp;
    vpp_compute_pdom(*p, header);
    for bb: rpo {
        assert(vp_is_basic(bb), "Non-outer regions with VPBBs only are supported");
        if bb != header vpp_create_block_in_mask(*p, bb);
        m := vpp_get_block_in_mask(*p, bb);
        if m == NONE continue;
        r := vb(bb).first;
        while r != NONE {
            if vr(r).kind == .INSTRUCTION vpi_add_mask(r, m);
            r = vr(r).next;
        }
    }
    for < bb: rpo if bb != header vpp_convert_phis_to_blends(*p, bb);
    prev: Vp_Blk = NONE;
    for bb: vp_blocks_only_basic(rpo) {
        succs: [..] Vp_Blk; succs.allocator = temp;
        for vb(bb).succs array_add(*succs, it);
        if succs.count > 1 vp_erase_recipe(vp_terminator(bb));
        for s: succs vpbu_disconnect(bb, s);
        if prev != NONE vpbu_connect(prev, bb);
        prev = bb;
    }
}

// removeCommonBlendMask
vp_remove_common_blend_mask :: (blend: Vp_Rec) {
    if vp_blend_is_normalized(blend) return;
    ok, common, _ := vpm_logical_and(vp_blend_mask(blend, 0));
    if !ok return;
    n := vp_blend_num_incoming(blend);
    for i: 0..n-1 {
        ok2, c2, _ := vpm_logical_and(vp_blend_mask(blend, i));
        if !ok2 || c2 != common return;
    }
    for i: 0..n-1 vp_blend_set_mask(blend, i, vp_op(vp_def(vp_blend_mask(blend, i)), 1));
}

// simplifyBlends
vp_simplify_blends :: () {
    for bb: vp_blocks_only_basic(vp_depth_first_shallow(vb(vp_vector_loop_region()).entry)) {
        for r: vp_block_recipes(bb) {
            if vr(r).dead || vr(r).kind != .BLEND continue;
            blend := r;
            vp_remove_common_blend_mask(blend);
            uniq: [..] Vp_Val; uniq.allocator = temp;
            add_uniq :: (u: *[..] Vp_Val, v: Vp_Val) { for u.* if it == v return; array_add(u, v); }
            n := vp_blend_num_incoming(blend);
            if vp_blend_is_normalized(blend) || !vpm_is_false(vp_blend_mask(blend, 0)) add_uniq(*uniq, vp_blend_incoming(blend, 0));
            for i: 1..n-1 if !vpm_is_false(vp_blend_mask(blend, i)) add_uniq(*uniq, vp_blend_incoming(blend, i));
            if uniq.count == 1 { vp_rauw(vr(blend).def, uniq[0]); vp_erase_recipe(blend); continue; }
            if vp_blend_is_normalized(blend) continue;
            start := 0;
            for i: 0..n-1 {
                m := vp_blend_mask(blend, i);
                if vp_has_one_use(m) && !vpm_is_false(m) { start = i; break; }
            }
            ops: [..] Vp_Val; ops.allocator = temp;
            array_add(*ops, vp_blend_incoming(blend, start));
            for i: 0..n-1 {
                if i == start continue;
                array_add(*ops, vp_blend_incoming(blend, i));
                array_add(*ops, vp_blend_mask(blend, i));
            }
            nb := vp_new_blend(vp_uv(vr(blend).def), ops, vr(blend).flags, vr(blend).dl);
            vp_insert_before(nb, blend);
            dead_mask := vp_blend_mask(blend, start);
            vp_rauw(vr(blend).def, vr(nb).def);
            vp_erase_recipe(blend);
            vp_recursively_delete_dead_recipes(dead_mask);
            if vp_nops(nb) == 3 {
                okn, new_mask := vpm_not(vp_blend_mask(nb, 1));
                if okn {
                    inc0 := vp_op(nb, 0); inc1 := vp_op(nb, 1); old_mask := vp_op(nb, 2);
                    vp_set_operand(nb, 0, inc1);
                    vp_set_operand(nb, 1, inc0);
                    vp_set_operand(nb, 2, new_mask);
                    if vp_num_users(old_mask) == 0 vp_erase_recipe(vp_def(old_mask));
                }
            }
        }
    }
}
