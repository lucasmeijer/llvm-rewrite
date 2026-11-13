// Predication and tail folding in VPlan: VPPredicator / introduceMasksAndLinearize
// (llvm/lib/Transforms/Vectorize/VPlanPredicator.cpp), foldTailByMasking (VPlanConstruction.cpp),
// VPBasicBlock::splitAt (VPlan.cpp), and the VPlanTransforms that act on masks, blends and predicated replicates
// (VPlanTransforms.cpp: simplifyBlends / removeCommonBlendMask, reassociateHeaderMask, addReplicateRegions /
// createReplicateRegion, sinkScalarOperands, mergeReplicateRegionsIntoSuccessors, materializeHeaderMask)
// (LLVM 23.1.5). Switches fail loudly.
import std;
import ir;
import irutil;
import instinfo;
import printer;
import datalayout;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_transforms;

// ---------------------------------------------------------------------------------------------
// blocks

// VPBasicBlock::splitAt(SplitAt): the new block "<name>.split" after b, with the recipes from `at` (-1 = end)
fn vp_split_at(b: i32, at: i32) -> i32 {
    var nm: u8[>..] = [];
    nm.append(sbytes(vpb[b].name));
    nm.append(".split");
    let s = vp_create_basic_block(nm);
    vpbu_insert_block_after(s, b);
    let pr = vpb[b].parent;
    if pr >= 0 && vpb[pr].exiting == b { vp_region_set_exiting(pr, s); }
    var r = at;
    while r >= 0 { let nx = vpr[r].next; vp_move_before(r, s, -1); r = nx; }
    return s;
}

// the header mask of the vector loop region (-1 = none) and its matcher m_HeaderMask
fn vp_header_mask() -> i32 { let r = vp_vector_loop_region(); if r < 0 { -1 } else { vpb[r].header_mask } }
fn vp_is_header_mask(v: i32) -> bool { v >= 0 && vpv[v].kind == VVK_REGION && vpb[vpv[v].region].header_mask == v }
// VPRegionBlock::createHeaderMask
fn vp_create_header_mask(region: i32) -> i32 {
    let m = vp_new_value(VVK_REGION, T_I1, -1);
    vpv[m].region = region;
    vpb[region].header_mask = m;
    return m;
}
// getUsedHeaderMask
fn vp_used_header_mask() -> i32 { let m = vp_header_mask(); if m >= 0 && vp_num_users(m) > 0 { m } else { -1 } }

// ---------------------------------------------------------------------------------------------
// VPPredicator

var vpp_bmask = hm_new();       // BlockMaskCache (present = set; value -1 = all-one)
var vpp_emask = hm_new();       // EdgeMaskCache
var vpp_pdom = hm_new();        // (a << 32 | b) -> 1: a post-dominates b (within the loop region)
var vpp_dt_idom = hm_new();     // the VPDT's idoms at construction

fn vpp_ekey(s: i32, d: i32) -> u64 { ((s as u64) << 32) | (d as u32 as u64) }
fn vpp_get_block_in_mask(b: i32) -> i32 { hm_get(vpp_bmask, b as u64, -1) as i32 }
fn vpp_set_block_in_mask(b: i32, m: i32) { hm_put(vpp_bmask, b as u64, m as i64); }
fn vpp_get_edge_mask(s: i32, d: i32) -> i32 { hm_get(vpp_emask, vpp_ekey(s, d), -1) as i32 }
fn vpp_has_edge_mask(s: i32, d: i32) -> bool { hm_has(vpp_emask, vpp_ekey(s, d)) }
fn vpp_set_edge_mask(s: i32, d: i32, m: i32) -> i32 { hm_put(vpp_emask, vpp_ekey(s, d), m as i64); return m; }

// VPPostDominatorTree restricted to the blocks of the loop region (single exiting block): pdom sets by fixpoint
fn vpp_compute_pdom(blocks: const i32[:], exiting: i32) {
    hm_clear(vpp_pdom);
    let n = blocks.len;
    // sets as bit rows over the block indices
    var idx = hm_new();
    for k in n { hm_put(idx, blocks[k] as u64, k); }
    var sets: bool[>..<] = [];
    for a in n { for b in n { sets.push(true); } }
    let ex = hm_get(idx, exiting as u64, -1);
    for b in n { sets[ex * n + b] = b == ex; }
    var changed = true;
    while changed {
        changed = false;
        var k = n - 1;
        while k >= 0 {
            let a = k;
            k--;
            if a == ex { continue; }
            let blk = blocks[a];
            for b in n {
                var v = true;
                var any = false;
                for j in vp_nsuccs(blk) {
                    let s = hm_get(idx, vp_succ(blk, j) as u64, -1);
                    if s < 0 { continue; }
                    any = true;
                    if !sets[s * n + b] { v = false; }
                }
                if !any { v = false; }
                let nv = (b == a) || v;
                if nv != sets[a * n + b] { sets[a * n + b] = nv; changed = true; }
            }
        }
    }
    for a in n { for b in n { if sets[a * n + b] { hm_put(vpp_pdom, vpp_ekey(blocks[b], blocks[a]), 1); } } }
}
// VPPDT.properlyDominates(A, B): A post-dominates B, A != B
fn vpp_properly_post_dominates(a: i32, b: i32) -> bool { a != b && hm_has(vpp_pdom, vpp_ekey(a, b)) }

// createEdgeMask(Src, Dst)
fn vpp_create_edge_mask(src: i32, dst: i32) -> i32 {
    if vpp_has_edge_mask(src, dst) {
        let m = vpp_get_edge_mask(src, dst);
        if m >= 0 { return m; }
    }
    let src_mask = vpp_get_block_in_mask(src);
    if vp_nsuccs(src) == 1 { return vpp_set_edge_mask(src, dst, src_mask); }
    let t = vp_terminator(src);
    if vpr[t].kind == VPR_INSTRUCTION && vpr[t].opcode == OP_SWITCH as i32 { vp_unported("switches in the loop (createSwitchEdgeMasks)"); }
    if !vp_is_vpi(t, VPI_BRANCH_ON_COND) { fatal("internal: Unsupported terminator"); }
    if vp_succ(src, 0) == vp_succ(src, 1) { return vpp_set_edge_mask(src, dst, src_mask); }
    var em = vp_op(t, 0);
    let tdl = vpr[t].dl;
    if vp_succ(src, 0) != dst { let n = vpb_not(em, tdl, ""); em = vpr[n].def; }
    if src_mask >= 0 { let a = vpb_logical_and(src_mask, em, tdl); em = vpr[a].def; }
    return vpp_set_edge_mask(src, dst, em);
}
// VPBuilder::createLogicalAnd
fn vpb_logical_and(a: i32, b: i32, dl: i32) -> i32 { vpb_nary(VPI_LOGICAL_AND, [a, b], vpf_none(), dl, "", -1) }
fn vpb_or(a: i32, b: i32) -> i32 { vpb_nary(OP_OR as i32, [a, b], vpf_disjoint(false), -1, "", -1) }

// createBlockInMask(VPBB)
fn vpp_create_block_in_mask(b: i32) {
    vpb_set_at(b, vp_first_non_phi(b));
    let idom = hm_get(vpp_dt_idom, b as u64, -1) as i32;
    if idom < 0 { fatal("internal: Block in loop must have immediate dominator"); }
    if vpp_properly_post_dominates(b, idom) { vpp_set_block_in_mask(b, vpp_get_block_in_mask(idom)); return; }
    var bm: i32 = -1;
    var seen: i32[>..<] = [];
    for k in vp_npreds(b) {
        let p = vp_pred(b, k);
        var dup = false;
        for x in seen { if x == p { dup = true; } }
        if dup { continue; }
        seen.push(p);
        let em = vpp_create_edge_mask(p, b);
        if em < 0 { vpp_set_block_in_mask(b, -1); return; }
        if bm < 0 { bm = em; continue; }
        let o = vpb_or(bm, em);
        bm = vpr[o].def;
    }
    vpp_set_block_in_mask(b, bm);
}
// getMaskInsertPoint(VPBB)
fn vpp_mask_insert_point(b: i32) -> i32 {
    let m = vpp_get_block_in_mask(b);
    if m >= 0 {
        let mr = vp_def(m);
        if mr >= 0 && vpr[mr].parent == b { return vpr[mr].next; }
    }
    return vp_first_non_phi(b);
}

// VPBlendRecipe(Phi, Operands, Flags, DL)
fn vp_new_blend(phi: i32, ops: const i32[:], f: VPF, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_BLEND, ops, vp_scalar_type(ops[0]), phi, dl);
    vpr[r].f = f;
    return r;
}
fn vp_blend_is_normalized(r: i32) -> bool { vp_nops(r) % 2 == 1 }
fn vp_blend_num_incoming(r: i32) -> i64 { (vp_nops(r) + (if vp_blend_is_normalized(r) { 1 } else { 0 })) / 2 }
fn vp_blend_incoming(r: i32, i: i64) -> i32 { if i == 0 { vp_op(r, 0) } else { vp_op(r, i * 2 - (if vp_blend_is_normalized(r) { 1 } else { 0 })) } }
fn vp_blend_mask(r: i32, i: i64) -> i32 { if i == 0 { vp_op(r, 1) } else { vp_op(r, i * 2 + (if vp_blend_is_normalized(r) { 0 } else { 1 })) } }
fn vp_blend_set_mask(r: i32, i: i64, v: i32) {
    if i == 0 { vp_set_operand(r, 1, v); } else { vp_set_operand(r, i * 2 + (if vp_blend_is_normalized(r) { 0 } else { 1 }), v); }
}

// convertPhisToBlends(VPBB)
fn vpp_convert_phis_to_blends(b: i32) {
    vpb_set_at(b, vpp_mask_insert_point(b));
    var phis: i32[>..<] = [];
    vp_block_phis(b, phis);
    for p in phis {
        var np: i32[>..<] = [];
        for k in vp_nops(p) { let v = vp_op(p, k); if !(vp_is_ir_value(v) && is_poison(vp_ir(v))) { np.push(v); } }
        var all_eq = true;
        for v in np { if v != np[0] { all_eq = false; } }
        if all_eq {
            vp_rauw(vpr[p].def, if np.len == 0 { vp_op(p, 0) } else { np[0] });
            vp_erase_recipe(p);
            continue;
        }
        var ops: i32[>..<] = [];
        for k in vp_nops(p) {
            ops.push(vp_op(p, k));
            let m = vpp_create_edge_mask(vp_phi_incoming_block(p, k), b);
            if m < 0 { vp_unported("blends with an all-one incoming edge mask"); }
            ops.push(m);
        }
        let bl = vp_new_blend(vpv[vpr[p].def].uv, ops, vpr[p].f, vpr[p].dl);
        vpb_insert(bl);
        vp_rauw(vpr[p].def, vpr[bl].def);
        vp_erase_recipe(p);
    }
}

// VPInstruction::alwaysUnmasked
fn vpi_always_unmasked(r: i32) -> bool {
    let o = vpr[r].opcode;
    if o == VPI_MASKED_COND { return false; }
    if vpv[vpr[r].def].uv < 0 { return true; }
    return (vpi_is_ir_opcode(o) && is_cast_op(o as i64)) || o == OP_PHI as i32 || o == OP_GEP as i32;
}

// VPlanTransforms::introduceMasksAndLinearize
fn vp_introduce_masks_and_linearize() {
    let region = vp_vector_loop_region();
    let header = vp_entry_basic_block(region);
    var rpo: i32[>..<] = [];
    vp_rpo(header, false, rpo);
    hm_clear(vpp_bmask);
    hm_clear(vpp_emask);
    vp_dt_build();
    hm_clear(vpp_dt_idom);
    for b in rpo { hm_put(vpp_dt_idom, b as u64, hm_get(vpdt_idom, b as u64, -1)); }
    vpp_compute_pdom(rpo, vpb[region].exiting);
    for b in rpo {
        if !vp_is_basic(b) { fatal("internal: loop-vectorize: nested regions in the predicator"); }
        if b != header { vpp_create_block_in_mask(b); }
        let bm = vpp_get_block_in_mask(b);
        if bm < 0 { continue; }
        var r = vpb[b].first;
        while r >= 0 {
            if vpr[r].kind == VPR_INSTRUCTION && !vpi_always_unmasked(r) {
                if vp_is_masked(r) { fatal("internal: recipe is already masked"); }
                vp_add_operand(r, bm);
            }
            r = vpr[r].next;
        }
    }
    var k = rpo.len - 1;
    while k >= 0 { let b = rpo[k]; k--; if b != header { vpp_convert_phis_to_blends(b); } }
    var prev: i32 = -1;
    for b in rpo {
        var ss: i32[>..<] = [];
        xv_to(vpb[b].succs, ss);
        if ss.len > 1 { vp_erase_recipe(vp_terminator(b)); }
        for s in ss { vpbu_disconnect(b, s); }
        if prev >= 0 { vpbu_connect(prev, b); }
        prev = b;
    }
}

// ---------------------------------------------------------------------------------------------
// foldTailByMasking

fn vp_fold_tail_by_masking() {
    if xv_len(vph.exit_blocks) != 1 { vp_unported("tail folding with more than one exit block"); }
    let region = vp_vector_loop_region();
    let header = vpb[region].entry;
    vp_split_at(header, vp_first_non_phi(header));
    let hm = vp_create_header_mask(region);
    vpb_set_at(header, vp_first_non_phi(header));
    vpb_nary(VPI_BRANCH_ON_COND, [hm], vpf_none(), -1, "", -1);
    let orig_latch = vpb[region].exiting;
    let term = vp_terminator(orig_latch);
    if !vpm_vpi_r(term, VPI_BRANCH_ON_COUNT, 2) || vp_op(term, 1) != vph.vtc { fatal("internal: Unexpected canonical iv increment"); }
    let ivinc = vp_op(term, 0);
    let latch = vp_split_at(orig_latch, vp_def(ivinc));
    vpb[latch].name = intern("vector.latch");
    vpbu_connect(header, latch);
    // values defined in the loop that need a phi: header phi backedges and live-outs extracted in the middle block
    var nv: i32[>..<] = [];          // MapVector keys
    var nu_at: i32[>..<] = [];       // their users (runs in nu)
    var nu: i32[>..<] = [];
    var nu_next: i32[>..<] = [];
    fn add_need(v: i32, u: i32) {
        var k: i64 = -1;
        for j in nv.len { if nv[j] == v { k = j; } }
        if k < 0 { nv.push(v); nu_at.push(-1); k = nv.len - 1; }
        // append at the end of v's list
        nu.push(u); nu_next.push(-1);
        let e = (nu.len - 1) as i32;
        if nu_at[k] < 0 { nu_at[k] = e; } else { var x = nu_at[k]; while nu_next[x] >= 0 { x = nu_next[x]; } nu_next[x] = e; }
    }
    var phis: i32[>..<] = [];
    vp_block_phis(header, phis);
    for p in phis {
        if vp_is_widen_induction_kind(vpr[p].kind) { continue; }
        if !vp_is_header_phi(p) { fatal("internal: loop-vectorize: a non-header phi in the header"); }
        add_need(vp_op(p, 1), p);
    }
    var mrs: i32[>..<] = [];
    vp_block_recipes(vp_middle_block(), mrs);
    for r in mrs { if vpm_vpi_r(r, VPI_EXTRACT_LAST_PART, 1) { add_need(vp_op(r, 0), r); } }
    vpb_set_at(latch, vpb[latch].first);
    for j in nv.len {
        let v = nv[j];
        if vp_is_ir_value(v) { continue; }
        var tail = vp_poison(vp_scalar_type(v));
        var f = vpf_none();
        var rdx: i32 = -1;
        var e = nu_at[j];
        while e >= 0 { if vpr[nu[e]].kind == VPR_REDUCTION_PHI { rdx = nu[e]; } e = nu_next[e]; }
        if rdx >= 0 && vpr[rdx].rdx_style == VRS_UNORDERED { tail = vpr[rdx].def; f = vpr[rdx].f; }
        let ph = vpb_scalar_phi([v, tail], -1, "", f, -1);
        e = nu_at[j];
        while e >= 0 { vp_replace_uses_of_with(nu[e], v, vpr[ph].def); e = nu_next[e]; }
    }
    // extracts of the last element extract from the last active lane of the header mask instead
    let middle = vp_middle_block();
    vpb_set_before(vp_terminator(middle));
    vp_block_recipes(middle, mrs);
    for r in mrs {
        if !vpm_vpi_r(r, VPI_EXTRACT_LAST_LANE, 1) { continue; }
        let d = vp_def(vp_op(r, 0));
        if !vpm_vpi_r(d, VPI_EXTRACT_LAST_PART, 1) { continue; }
        let op = vp_op(d, 0);
        let ity = ty_int(dl_ptr(0).idx);
        let lal = vpb_nary(VPI_LAST_ACTIVE_LANE, [hm], vpf_none(), -1, "", ity);
        let ext = vpb_nary(VPI_EXTRACT_LANE, [vpr[lal].def, op], vpf_none(), -1, "", -1);
        vp_rauw(vpr[r].def, vpr[ext].def);
    }
    // the vector trip count now equals the trip count: the middle block's branch is always taken
    let mt = vp_terminator(middle);
    vp_set_operand(mt, 0, vp_true());
}

// ---------------------------------------------------------------------------------------------
// simplifyBlends / removeCommonBlendMask

fn vpt_remove_common_blend_mask(bl: i32) {
    if vp_blend_is_normalized(bl) { return; }
    let ok0, common, y0 = vpm_logical_and(vp_blend_mask(bl, 0));
    if !ok0 { return; }
    for i in vp_blend_num_incoming(bl) {
        let ok, a, b = vpm_logical_and(vp_blend_mask(bl, i));
        if !ok || a != common { return; }
    }
    for i in vp_blend_num_incoming(bl) { vp_blend_set_mask(bl, i, vp_op(vp_def(vp_blend_mask(bl, i)), 1)); }
}
// recursivelyDeleteDeadRecipes(V)
fn vpt_recursively_delete_dead_recipes(v: i32) {
    var wl: i32[>..<] = [];
    var seen = hm_new();
    wl.push(v);
    while wl.len > 0 {
        let cur = wl.pop();
        if hm_has(seen, cur as u64) { continue; }
        hm_put(seen, cur as u64, 1);
        let r = vp_def(cur);
        if r < 0 || !vp_is_dead_recipe(r) { continue; }
        var ops: i32[>..<] = [];
        xv_to(vpr[r].ops, ops);
        vp_erase_recipe(r);
        for o in ops { wl.push(o); }
    }
}
fn vpt_simplify_blends() {
    var bs: i32[>..<] = [];
    vp_depth_first(vpb[vp_vector_loop_region()].entry, false, bs);
    vp_only_basic(bs);
    for b in bs {
        var rs: i32[>..<] = [];
        vp_block_recipes(b, rs);
        for bl in rs {
            if vpr[bl].dead || vpr[bl].kind != VPR_BLEND { continue; }
            vpt_remove_common_blend_mask(bl);
            var uniq: i32[>..<] = [];
            fn add_u(v: i32) { for x in uniq { if x == v { return; } } uniq.push(v); }
            if vp_blend_is_normalized(bl) || !vpm_false(vp_blend_mask(bl, 0)) { add_u(vp_blend_incoming(bl, 0)); }
            for i in 1..vp_blend_num_incoming(bl) { if !vpm_false(vp_blend_mask(bl, i)) { add_u(vp_blend_incoming(bl, i)); } }
            if uniq.len == 1 {
                vp_rauw(vpr[bl].def, uniq[0]);
                vp_erase_recipe(bl);
                continue;
            }
            if vp_blend_is_normalized(bl) { continue; }
            var start: i64 = 0;
            for i in vp_blend_num_incoming(bl) {
                let m = vp_blend_mask(bl, i);
                if vp_has_one_use(m) && !vpm_false(m) { start = i; break; }
            }
            var ops: i32[>..<] = [];
            ops.push(vp_blend_incoming(bl, start));
            for i in vp_blend_num_incoming(bl) {
                if i == start { continue; }
                ops.push(vp_blend_incoming(bl, i));
                ops.push(vp_blend_mask(bl, i));
            }
            let nb = vp_new_blend(vpv[vpr[bl].def].uv, ops, vpr[bl].f, vpr[bl].dl);
            vp_insert_before(nb, bl);
            let dead = vp_blend_mask(bl, start);
            vp_rauw(vpr[bl].def, vpr[nb].def);
            vp_erase_recipe(bl);
            vpt_recursively_delete_dead_recipes(dead);
            if vp_nops(nb) == 3 {
                let nm = vpm_not(vp_blend_mask(nb, 1));
                if nm >= 0 {
                    let i0 = vp_op(nb, 0);
                    let i1 = vp_op(nb, 1);
                    let om = vp_op(nb, 2);
                    vp_set_operand(nb, 0, i1);
                    vp_set_operand(nb, 1, i0);
                    vp_set_operand(nb, 2, nm);
                    if vp_num_users(om) == 0 { vp_erase_recipe(vp_def(om)); }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// reassociateHeaderMask

fn vpt_reassociate_header_mask() {
    let hm = vp_header_mask();
    if hm < 0 { return; }
    var wl: i32[>..<] = [];
    for j in vp_num_users(hm) {
        let u = vp_user(hm, j);
        if vpr[u].def < 0 { continue; }
        let ok, a, b = vpm_logical_and(vpr[u].def);
        if ok && a == hm { let d = vpr[u].def; for k in vp_num_users(d) { wl.push(vp_user(d, k)); } }
    }
    while wl.len > 0 {
        let r = wl.pop();
        if vpr[r].dead || vpr[r].def < 0 { continue; }
        let ok, l, y = vpm_logical_and(vpr[r].def);
        if !ok { continue; }
        let ok2, h, x = vpm_logical_and(l);
        if !ok2 || h != hm { continue; }
        let d = vpr[r].def;
        for k in vp_num_users(d) { wl.push(vp_user(d, k)); }
        vpb_set_before(r);
        let inner = vpb_logical_and(x, y, -1);
        let outer = vpb_logical_and(hm, vpr[inner].def, -1);
        vp_rauw(d, vpr[outer].def);
    }
}

// ---------------------------------------------------------------------------------------------
// replicate regions

fn vp_replicate_mask(r: i32) -> i32 { if vpr[r].predicated { vp_op(r, vp_nops(r) - 1) } else { -1 } }

// createReplicateRegion(PredRecipe, ParentRegion, Plan)
fn vpt_create_replicate_region(pr: i32, parent_region: i32) -> i32 {
    let i = vp_underlying_instr(pr);
    var rn: u8[>..] = [];
    rn.append("pred.");
    rn.append(opcode_name(iop(i)));
    let mask = vp_replicate_mask(pr);
    let md = vp_def(mask);
    let bom = vp_new_recipe(VPR_BRANCH_ON_MASK, [mask], if md >= 0 { vpr[md].dl } else { -1 });
    var en: u8[>..] = []; en.append(rn); en.append(".entry");
    let entry = vp_create_basic_block(en);
    vp_append_recipe(entry, bom);
    var ops: i32[>..<] = [];
    for k in vp_nops(pr) - 1 { ops.push(vp_op(pr, k)); }
    let rwm = vp_new_single_def(VPR_REPLICATE, ops, vpv[vpr[pr].def].ty, i, vpr[pr].dl);
    vpr[rwm].single_scalar = vpr[pr].single_scalar;
    vpr[rwm].opcode = vpr[pr].opcode;
    vpr[rwm].f = vpr[pr].f;
    vp_md_copy(rwm, pr);
    var pn: u8[>..] = []; pn.append(rn); pn.append(".if");
    let pred = vp_create_basic_block(pn);
    vp_append_recipe(pred, rwm);
    var xn: u8[>..] = []; xn.append(rn); xn.append(".continue");
    let exiting = vp_create_basic_block(xn);
    let region = vp_create_replicate_region(entry, exiting, rn);
    vpb[region].parent = parent_region;
    vpbu_insert_two_blocks_after(pred, exiting, entry);
    vpbu_connect(pred, exiting);
    if vp_num_users(vpr[pr].def) != 0 {
        let phi = vp_new_single_def(VPR_PRED_INST_PHI, [vpr[rwm].def], vp_scalar_type(vpr[rwm].def), -1, vpr[rwm].dl);
        vp_append_recipe(exiting, phi);
        vp_rauw(vpr[pr].def, vpr[phi].def);
    }
    vp_erase_recipe(pr);
    return region;
}
// addReplicateRegions
fn vpt_add_replicate_regions() {
    var bs: i32[>..<] = [];
    vp_all_basic_blocks_deep(bs);
    var wl: i32[>..<] = [];
    for b in bs {
        var r = vpb[b].first;
        while r >= 0 { if vpr[r].kind == VPR_REPLICATE && vpr[r].predicated { wl.push(r); } r = vpr[r].next; }
    }
    var bbnum: i64 = 0;
    for rr in wl {
        let cur = vpr[rr].parent;
        let split = vp_split_at(cur, rr);
        let obb = inst_parent(vp_underlying_instr(rr));
        if vals[obb].name >= 0 {
            var nm: u8[>..] = [];
            nm.append(val_name(obb));
            nm.append(".");
            format(nm, bbnum);
            bbnum++;
            vpb[split].name = intern(nm);
        } else {
            vpb[split].name = intern("");
        }
        let region = vpt_create_replicate_region(rr, vpb[cur].parent);
        vpbu_insert_on_edge(cur, split, region);
        let pr = vpb[region].parent;
        if pr >= 0 && vpb[pr].exiting == cur { vp_region_set_exiting(pr, split); }
    }
}

// sinkScalarOperands
fn vpt_sink_scalar_operands() -> bool {
    let scalar_vf_only = vp_has_scalar_vf_only();
    var changed = false;
    var wl_to: i32[>..<] = [];
    var wl_r: i32[>..<] = [];
    var wl_set = hm_new();
    fn insert_candidate(sink_to: i32, opv: i32) {
        let c = vp_def(opv);
        if c < 0 || vpr[c].def < 0 { return; }
        let k = vpr[c].kind;
        if k != VPR_REPLICATE && k != VPR_SCALAR_IV_STEPS { return; }
        if vpr[c].parent == sink_to || vp_cannot_hoist_or_sink_recipe(c, true) { return; }
        if k == VPR_REPLICATE && !scalar_vf_only && vpr[c].single_scalar { return; }
        let key = ((sink_to as u64) << 32) | (c as u32 as u64);
        if hm_has(wl_set, key) { return; }
        hm_put(wl_set, key, 1);
        wl_to.push(sink_to);
        wl_r.push(c);
    }
    var all: i32[>..<] = [];
    vp_depth_first(vph.entry, true, all);
    for reg in all {
        if !vp_is_region(reg) || !vp_is_replicator(reg) { continue; }
        let eb = vp_entry_basic_block(reg);
        if vp_nsuccs(eb) != 2 { continue; }
        let b = vp_succ(eb, 0);
        if vp_single_succ(b) != vpb[reg].exiting { continue; }
        var r = vpb[b].first;
        while r >= 0 { for k in vp_nops(r) { insert_candidate(b, vp_op(r, k)); } r = vpr[r].next; }
    }
    var i: i64 = 0;
    while i < wl_r.len {
        let sink_to = wl_to[i];
        let c = wl_r[i];
        i++;
        let d = vpr[c].def;
        var outside: i32[>..<] = [];
        for j in vp_num_users(d) { let u = vp_user(d, j); if vpr[u].parent != sink_to { outside.push(u); } }
        var bad = false;
        for u in outside { if !vp_uses_first_lane_only(u, d) { bad = true; } }
        if bad { continue; }
        if outside.len != 0 {
            if scalar_vf_only { continue; }
            var clone: i32 = -1;
            if vpr[c].kind == VPR_REPLICATE {
                var ops: i32[>..<] = [];
                xv_to(vpr[c].ops, ops);
                clone = vp_create_single_scalar_op(vpr[c].opcode, ops, -1, vpr[c].f, c, vpr[c].dl, vpv[d].uv);
            } else {
                clone = vp_clone(c);
            }
            vp_insert_before(clone, c);
            let cd = vpr[clone].def;
            vp_replace_uses_with_if(d, cd) { u, ii => vpr[u].parent != sink_to };
        }
        vp_move_before(c, sink_to, vp_first_non_phi(sink_to));
        for k in vp_nops(c) { insert_candidate(sink_to, vp_op(c, k)); }
        changed = true;
    }
    return changed;
}

// getPredicatedMask(R) / getPredicatedThenBlock(R)
fn vpt_predicated_mask(reg: i32) -> i32 {
    let e = vpb[reg].entry;
    if !vp_is_basic(e) { return -1; }
    let f = vpb[e].first;
    if f < 0 || vpr[f].next >= 0 || vpr[f].kind != VPR_BRANCH_ON_MASK { return -1; }
    return vp_op(f, 0);
}
fn vpt_predicated_then_block(reg: i32) -> i32 {
    let e = vpb[reg].entry;
    if vp_nsuccs(e) != 2 { return -1; }
    let s0 = vp_succ(e, 0);
    let s1 = vp_succ(e, 1);
    if !vp_is_basic(s0) || !vp_is_basic(s1) { return -1; }
    if vp_nsuccs(s0) + vp_nsuccs(s1) != 1 { return -1; }
    if vp_single_succ(s0) == s1 { return s0; }
    if vp_single_succ(s1) == s0 { return s1; }
    return -1;
}
// mergeReplicateRegionsIntoSuccessors
fn vpt_merge_replicate_regions_into_successors() -> bool {
    var done: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var all: i32[>..<] = [];
    vp_depth_first(vph.entry, true, all);
    for r1 in all {
        if !vp_is_region(r1) || !vp_is_replicator(r1) { continue; }
        let mb = vp_single_succ(r1);
        if mb < 0 || !vp_is_basic(mb) || !vp_block_empty(mb) { continue; }
        let r2 = vp_single_succ(mb);
        if r2 < 0 || !vp_is_region(r2) || !vp_is_replicator(r2) { continue; }
        let m1 = vpt_predicated_mask(r1);
        let m2 = vpt_predicated_mask(r2);
        if m1 < 0 || m1 != m2 { continue; }
        wl.push(r1);
    }
    for r1 in wl {
        var skip = false;
        for x in done { if x == r1 { skip = true; } }
        if skip { continue; }
        let mb = vp_single_succ(r1);
        let r2 = vp_single_succ(mb);
        let t1 = vpt_predicated_then_block(r1);
        let t2 = vpt_predicated_then_block(r2);
        if t1 < 0 || t2 < 0 { continue; }
        var rs: i32[>..<] = [];
        vp_block_recipes(t1, rs);
        var k = rs.len - 1;
        while k >= 0 { vp_move_before(rs[k], t2, vp_first_non_phi(t2)); k--; }
        let m1 = vp_single_succ(t1);
        let m2 = vp_single_succ(t2);
        vp_block_recipes(m1, rs);
        k = rs.len - 1;
        while k >= 0 {
            let p = rs[k];
            k--;
            let pi1 = vp_op(p, 0);
            let pv = vpr[p].def;
            vp_replace_uses_with_if(pv, pi1) { u, ii => vpr[u].parent == t2 };
            if vp_num_users(pv) == 0 { vp_erase_recipe(p); continue; }
            vp_move_before(p, m2, vpb[m2].first);
        }
        var er: i32[>..<] = [];
        vp_block_recipes(vp_entry_basic_block(r1), er);
        k = er.len - 1;
        while k >= 0 { vp_erase_recipe(er[k]); k--; }
        var ps: i32[>..<] = [];
        xv_to(vpb[r1].preds, ps);
        for p in ps { vpbu_disconnect(p, r1); vpbu_connect(p, mb); }
        vpbu_disconnect(r1, mb);
        done.push(r1);
    }
    return done.len != 0;
}

// createAndOptimizeReplicateRegions
fn vpt_create_and_optimize_replicate_regions() {
    vpt_add_replicate_regions();
    var again = true;
    while again {
        again = vpt_sink_scalar_operands();
        if vpt_merge_replicate_regions_into_successors() { again = true; }
        if vpt_merge_blocks_into_predecessors() { again = true; }
    }
}

// ---------------------------------------------------------------------------------------------
// materializeHeaderMask (no active lane masks: X86's default tail-folding style is DataWithoutLaneMask)

fn vpt_materialize_header_mask(use_alm: bool, use_alm_cf: bool) {
    let hm = vp_used_header_mask();
    if hm < 0 { return; }
    if use_alm || use_alm_cf { vp_unported("active lane masks"); }
    let region = vp_vector_loop_region();
    let header = vpb[region].entry;
    vpb_set_at(header, vp_first_non_phi(header));
    let can_iv = vpb[region].can_iv;
    let w = vp_new_single_def(VPR_WIDEN_CANONICAL_IV, [can_iv], vpv[can_iv].ty, -1, -1);
    vpr[w].f = vpf_wrap(true, false);
    vpb_insert(w);
    let m = vpb_icmp(37, vpr[w].def, vp_or_create_backedge_taken_count(), -1, "");
    vp_rauw(hm, vpr[m].def);
}
