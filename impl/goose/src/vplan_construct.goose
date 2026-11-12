// VPlan construction: PlainCFGBuilder, the initial skeleton (addInitialSkeleton, createExtractsForLiveOuts,
// simplifyLiveInsWithSCEV, buildVPlan0), header phi recipes (createWidenInductionRecipe, createHeaderPhiRecipes),
// finalizeSCEVPredicates, handleEarlyExits (countable exits), addMiddleCheck, createLoopRegions
// (canonicalHeaderAndLatch, createLoopRegion). Ported from llvm/lib/Transforms/Vectorize/VPlanConstruction.cpp;
// introduceMasksAndLinearize from llvm/lib/Transforms/Vectorize/VPlanPredicator.cpp (single-block loop bodies).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import pm;
import loopinfo;
import scev;
import scev_create;
import scev_btc;
import scev_lt;
import pse;
import iv_descriptors;
import lv_legality;
import vplan;
import vplan_utils;

// ---------------------------------------------------------------------------------------------
// PlainCFGBuilder

var pcb_l: i32 = -1;
var pcb_bb2vpbb = hm_new();
var pcb_irdef = hm_new();
var pcb_phis_to_fix: i32[>..<];

fn pcb_get_or_create_vpbb(bb: i32) -> i32 {
    let x = hm_get(pcb_bb2vpbb, bb as u64, -1);
    if x >= 0 { return x as i32; }
    let v = vp_create_basic_block(val_name(bb));
    hm_put(pcb_bb2vpbb, bb as u64, v as i64);
    return v;
}
fn pcb_preds_of(bb: i32, out: i32[>..<]&) { out.clear(); each_pred(bb) { p => out.push(p); }; }
fn pcb_set_preds_from_bb(vpbb: i32, bb: i32) {
    var ps: i32[>..<] = [];
    pcb_preds_of(bb, ps);
    var list: i32[>..<] = [];
    for p in ps { list.push(pcb_get_or_create_vpbb(p)); }
    for b in list { xv_push(vpb[vpbb].preds, b); }
}
fn pcb_operand(v: i32) -> i32 {
    let x = hm_get(pcb_irdef, v as u64, -1);
    if x >= 0 { return x as i32; }
    let nv = vp_live_in(v);
    hm_put(pcb_irdef, v as u64, nv as i64);
    return nv;
}
fn pcb_is_header_bb(bb: i32) -> bool { let l = li_loop_for(bb); l >= 0 && bb == loop_header(l) }

// createVPInstructionsForVPBB
fn pcb_create_instructions(vpbb: i32, bb: i32) {
    vpb_set_at_end(vpbb);
    var i = block_first(bb);
    while i >= 0 {
        let o = iop(i);
        let cur = i;
        i = inst_next(i);
        if o == OP_BR { continue; }
        if o == OP_CONDBR {
            let c = pcb_operand(op(cur, 0));
            let r = vpb_nary(VPI_BRANCH_ON_COND, [c], vpf_none(), vp_inst_dl(cur), "", -1);
            vp_set_underlying(vpr[r].def, cur);
            vp_md_from_inst(r, cur);
            continue;
        }
        if o == OP_SWITCH {
            vp_unported("switches in the loop");
        }
        var nr: i32 = -1;
        if o == OP_PHI {
            nr = vpb_scalar_phi([], vp_inst_dl(cur), "vec.phi", vp_flags_from_inst(cur), vals[cur].ty as i32);
            vp_set_underlying(vpr[nr].def, cur);
            if pcb_is_header_bb(inst_parent(cur)) {
                pcb_phis_to_fix.push(cur);
            } else {
                var m = hm_new();
                for k in phi_nincoming(cur) {
                    let pb = hm_get(pcb_bb2vpbb, phi_block(cur, k) as u64, -1);
                    hm_put(m, pb as u64, pcb_operand(phi_value(cur, k)) as i64);
                }
                for k in vp_npreds(vpbb) {
                    let p = vp_pred(vpbb, k);
                    vp_add_operand(nr, hm_get(m, vp_exiting_basic_block(p) as u64, -1) as i32);
                }
            }
        } else {
            if (o == OP_LOAD || o == OP_STORE) && lv_noalias_prepared { vp_unported("LoopVersioning noalias metadata in VPlan"); }
            var ops: i32[>..<] = [];
            for k in nops(cur) { ops.push(pcb_operand(op(cur, k))); }
            if is_cast_op(o) {
                nr = vpb_scalar_cast(o, ops[0], vals[cur].ty as i32, vp_inst_dl(cur), vp_flags_from_inst(cur));
                vp_set_underlying(vpr[nr].def, cur);
            } else if o == OP_LOAD {
                nr = vpb_scalar_load(vals[cur].ty as i32, ops[0], vp_inst_dl(cur));
                vp_set_underlying(vpr[nr].def, cur);
            } else {
                nr = vpb_nary(o as i32, ops, vp_flags_from_inst(cur), vp_inst_dl(cur), "", vals[cur].ty as i32);
                vp_set_underlying(vpr[nr].def, cur);
            }
            vp_md_from_inst(nr, cur);
        }
        hm_put(pcb_irdef, cur as u64, vpr[nr].def as i64);
    }
}

// buildPlainCFG
fn pcb_build_plain_cfg(l: i32) {
    pcb_l = l;
    hm_clear(pcb_bb2vpbb);
    hm_clear(pcb_irdef);
    pcb_phis_to_fix.clear();
    let entry = vph.entry;
    hm_put(pcb_bb2vpbb, vpb[entry].irbb as u64, entry as i64);
    for k in xv_len(vph.exit_blocks) { let e = xv_get(vph.exit_blocks, k); hm_put(pcb_bb2vpbb, vpb[e].irbb as u64, e as i64); }
    let ph = loop_preheader(l);
    var i = block_first(ph);
    while i >= 0 {
        if vals[i].ty as i32 != T_VOID { hm_put(pcb_irdef, i as u64, vp_live_in(i) as i64); }
        i = inst_next(i);
    }
    var po: i32[>..<] = [];
    lv_loop_postorder(l, po);
    var k = po.len - 1;
    while k >= 0 {
        let bb = po[k];
        k--;
        let vpbb = pcb_get_or_create_vpbb(bb);
        pcb_set_preds_from_bb(vpbb, bb);
        pcb_create_instructions(vpbb, bb);
        let t = block_terminator(bb);
        if iop(t) == OP_SWITCH { vp_unported("switches in the loop"); }
        if iop(t) == OP_BR {
            let s = pcb_get_or_create_vpbb(term_succ(t, 0));
            xv_push(vpb[vpbb].succs, s);
            continue;
        }
        let s0 = pcb_get_or_create_vpbb(term_succ(t, 0));
        let s1 = pcb_get_or_create_vpbb(term_succ(t, 1));
        xv_push(vpb[vpbb].succs, s0);
        xv_push(vpb[vpbb].succs, s1);
    }
    for j in xv_len(vph.exit_blocks) { let e = xv_get(vph.exit_blocks, j); pcb_set_preds_from_bb(e, vpb[e].irbb); }
    // fixHeaderPhis
    for phi in pcb_phis_to_fix {
        let pr = vp_def(hm_get(pcb_irdef, phi as u64, -1) as i32);
        var ps: i32[>..<] = [];
        pcb_preds_of(inst_parent(phi), ps);
        for p in ps { vp_add_operand(pr, pcb_operand(phi_value(phi, phi_block_index(phi, p)))); }
    }
    xv_push(vpb[entry].succs, pcb_get_or_create_vpbb(loop_header(l)));
    for j in xv_len(vph.exit_blocks) {
        let e = xv_get(vph.exit_blocks, j);
        var phis: i32[>..<] = [];
        vp_block_phis(e, phis);
        for r in phis {
            let phi = vpr[r].ir_inst;
            var ps: i32[>..<] = [];
            pcb_preds_of(vpb[e].irbb, ps);
            for p in ps { vp_add_operand(r, pcb_operand(phi_value(phi, phi_block_index(phi, p)))); }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// skeleton and loop regions

// canonicalHeaderAndLatch (uses the current VPDominatorTree)
fn vp_canonical_header_and_latch(header: i32) -> bool {
    if vp_npreds(header) != 2 { return false; }
    var ph = vp_pred(header, 0);
    var latch = vp_pred(header, 1);
    if !vp_dt_dominates(ph, header) || !vp_dt_dominates(header, latch) {
        let t = ph; ph = latch; latch = t;
        if !vp_dt_dominates(ph, header) || !vp_dt_dominates(header, latch) { return false; }
        vp_swap_preds(header);
        var phis: i32[>..<] = [];
        vp_block_phis(header, phis);
        for r in phis { vp_swap_operands(r); }
    }
    if vp_single_succ(latch) >= 0 || vp_succ(latch, 0) != header { return true; }
    let term = vp_terminator(latch);
    let nr = vp_new_instruction(VPI_NOT, [vp_op(term, 0)], vpf_none(), -1, "", -1);
    vp_insert_before(nr, term);
    vp_set_operand(term, 0, vpr[nr].def);
    vp_swap_succs(latch);
    return true;
}

// createLoopRegion
fn vp_create_loop_region_for(header: i32, dl: i32) {
    let ph = vp_pred(header, 0);
    let latch = vp_pred(header, 1);
    let outermost = vpbu_plain_cfg_header();
    vpbu_disconnect(ph, header);
    vpbu_disconnect(latch, header);
    if header != outermost { vp_unported("nested loop regions (outer-loop vectorization)"); }
    let r = vp_create_loop_region(vpv[vph.vtc].ty, dl, -1, -1);
    vpbu_transfer_successors(latch, r);
    vpbu_connect(ph, r);
    vp_region_set_entry(r, header);
    vp_region_set_exiting(r, latch);
    var bs: i32[>..<] = [];
    vp_depth_first(header, false, bs);
    for b in bs { vpb[b].parent = r; }
    let term = vp_terminator(latch);
    vpb_set_before(term);
    let inc = vpb_add(vpb[r].can_iv, vph.vfxuf, dl, "index.next", true, false);
    if vpm_vpi_r(term, VPI_BRANCH_ON_TWO_CONDS, 2) {
        let cmp = vpb_icmp(32, vp_val(inc), vph.vtc, -1, "");
        vp_set_operand(term, 1, vp_val(cmp));
    } else {
        let ldl = vpr[term].dl;
        vpb_nary(VPI_BRANCH_ON_COUNT, [vp_val(inc), vph.vtc], vpf_none(), ldl, "", -1);
        vp_erase_recipe(term);
    }
}

// createExtractsForLiveOuts
fn vp_create_extracts_for_live_outs(middle: i32) {
    vpb_set_at(middle, vp_first_non_phi(middle));
    for j in xv_len(vph.exit_blocks) {
        let eb = xv_get(vph.exit_blocks, j);
        if !xv_contains(vpb[eb].preds, middle) { continue; }
        var phis: i32[>..<] = [];
        vp_block_phis(eb, phis);
        for r in phis {
            let exiting = vp_phi_incoming_value_for_block(r, middle);
            if vp_is_ir_value(exiting) { continue; }
            let e1 = vpb_nary(VPI_EXTRACT_LAST_PART, [exiting], vpf_none(), -1, "", -1);
            let e2 = vpb_nary(VPI_EXTRACT_LAST_LANE, [vp_val(e1)], vpf_none(), -1, "", -1);
            vp_phi_set_incoming_value_for_block(r, middle, vp_val(e2));
        }
    }
}

// addInitialSkeleton
fn vp_add_initial_skeleton(induction_ty: i32, pse: i32, l: i32) {
    vp_dt_build();
    let header = vp_single_succ(vph.entry);
    vp_canonical_header_and_latch(header);
    let latch = vp_pred(header, 1);
    let vec_ph = vp_create_basic_block("vector.ph");
    vpbu_insert_block_after(vec_ph, vph.entry);
    let middle = vp_create_basic_block("middle.block");
    if vp_nsuccs(latch) == 2 {
        let le = vp_succ(latch, 0);
        vpbu_insert_on_edge(latch, le, middle);
    } else {
        vpbu_connect(latch, middle);
        vp_swap_succs(latch);
        vpb_set_at_end(latch);
        vpb_nary(VPI_BRANCH_ON_COND, [vp_false()], vpf_none(), -1, "", -1);
    }
    let btc = pse_get_symbolic_max_btc(pse);
    let tc = sc_trip_count_from_exit_count_ty(btc, induction_ty, l);
    vph.trip_count = vp_get_or_create_value_for_scev(tc);
    let scalar_ph = vp_create_basic_block("scalar.ph");
    vpbu_connect(scalar_ph, vph.scalar_header);
    vpbu_connect(middle, scalar_ph);
    vpbu_connect(vph.entry, scalar_ph);
    vp_swap_succs(vph.entry);
    vp_create_extracts_for_live_outs(middle);
    var hp: i32[>..<] = [];
    var sp: i32[>..<] = [];
    vp_block_phis(header, hp);
    vp_block_phis(vph.scalar_header, sp);
    if hp.len != sp.len { fatal("internal: zip_equal of header phis and scalar header phis"); }
    for k in hp.len {
        let vphi = hp[k];
        let be = vp_op(vphi, 1);
        vpb_set_at(middle, vp_first_non_phi(middle));
        let r1 = vpb_nary(VPI_EXTRACT_LAST_PART, [be], vpf_none(), -1, "", -1);
        let r2 = vpb_nary(VPI_EXTRACT_LAST_LANE, [vp_val(r1)], vpf_none(), -1, "", -1);
        vpb_set_at_end(scalar_ph);
        let resume = vpb_scalar_phi([vp_val(r2), vp_op(vphi, 0)], vpr[vphi].dl, "", vpf_none(), -1);
        vp_add_operand(sp[k], vp_val(resume));
    }
}

// simplifyLiveInsWithSCEV
fn vp_simplify_live_ins_with_scev(pse: i32) {
    var order: i32[>..<] = [];
    xv_to(vph.live_in_order, order);
    for v in order {
        let lv = vp_get_live_in(v);
        let e = vp_scev_for_value(lv, pse, -1);
        if sc_is_const(e) {
            let nv = vp_live_in(sc_value(e));
            vp_rauw(lv, nv);
        }
    }
}

// VPlanTransforms::buildVPlan0
fn vp_build_vplan0(l: i32, induction_ty: i32, pse: i32) {
    vp_plan_new(l, induction_ty);
    pcb_build_plain_cfg(l);
    vp_add_initial_skeleton(induction_ty, pse, l);
    vp_simplify_live_ins_with_scev(pse);
}

// ---------------------------------------------------------------------------------------------
// header phi recipes

fn vp_new_widen_int_or_fp_induction(phi: i32, start: i32, step: i32, vf: i32, ind: i32, f: VPF, dl: i32, trunc: i32) -> i32 {
    let ty = if trunc >= 0 { vals[trunc].ty as i32 } else { vp_scalar_type(start) };
    let r = vp_new_single_def(VPR_WIDEN_INT_OR_FP_INDUCTION, [start, step], ty, phi, dl);
    vp_add_operand(r, vf);
    vpr[r].ind = ind;
    vpr[r].f = f;
    vpr[r].ir_inst = trunc;
    return r;
}
fn vp_new_widen_pointer_induction(phi: i32, start: i32, step: i32, num_unrolled: i32, ind: i32, dl: i32) -> i32 {
    let r = vp_new_single_def(VPR_WIDEN_POINTER_INDUCTION, [start, step], vp_scalar_type(start), phi, dl);
    vp_add_operand(r, num_unrolled);
    vpr[r].ind = ind;
    return r;
}

// ReplaceExtractsWithExitingIVValueIfPossible
fn vp_replace_extracts_with_exiting_iv(wide: i32, be: i32, d: i32) {
    let is_pred = ind_descs[d].preds_n > 0;
    var users: i32[>..<] = [];
    vp_users(be, users);
    for u in users {
        if vpr[u].dead || !vpm_vpi_r(u, VPI_EXTRACT_LAST_PART, 1) { continue; }
        let elp = u;
        let ell = vp_single_user(vpr[elp].def);
        if !vpm_vpi_r(ell, VPI_EXTRACT_LAST_LANE, 1) { continue; }
        if is_pred {
            var skip = false;
            for j in vp_num_users(vpr[ell].def) { if vp_is_exit_block(vpr[vp_user(vpr[ell].def, j)].parent) { skip = true; } }
            if skip { continue; }
        }
        vpb_set_before(ell);
        let x = vpb_nary(VPI_EXITING_IV_VALUE, [vpr[wide].def], vpf_none(), -1, "", -1);
        vp_rauw(vpr[ell].def, vp_val(x));
        vp_erase_recipe(ell);
        vp_erase_recipe(elp);
    }
}

// createWidenInductionRecipe
fn vp_create_widen_induction_recipe(phi: i32, phir: i32, start: i32, d: i32, dl: i32) -> i32 {
    let step = vp_get_or_create_value_for_scev(ind_descs[d].step);
    let be = vp_op(phir, 1);
    if ind_descs[d].kind == IK_PTR {
        let w = vp_new_widen_pointer_induction(phi, start, step, vph.vfxuf, d, dl);
        vp_replace_extracts_with_exiting_iv(w, be, d);
        return w;
    }
    let ok, a, b = vpm_binary(be, OP_ADD);
    if ok && a == vpr[phir].def { vp_set_operand(vp_def(be), 1, step); }
    let f = vp_flags_from_ind_desc(d);
    let w = vp_new_widen_int_or_fp_induction(phi, start, step, vph.vf, d, f, dl, -1);
    vp_replace_extracts_with_exiting_iv(w, be, d);
    return w;
}

fn vp_new_first_order_recurrence_phi(phi: i32, start: i32, be: i32) -> i32 {
    let r = vp_new_single_def(VPR_FIRST_ORDER_RECURRENCE_PHI, [start], vp_scalar_type(start), phi, -1);
    vp_add_operand(r, be);
    return r;
}
fn vp_new_reduction_phi(phi: i32, kind: i32, start: i32, be: i32, style: u8, scale: i32, f: VPF, outside: bool) -> i32 {
    let r = vp_new_single_def(VPR_REDUCTION_PHI, [start], vp_scalar_type(start), phi, -1);
    vp_add_operand(r, be);
    vpr[r].rdx_kind = kind;
    vpr[r].rdx_style = style;
    vpr[r].rdx_scale = scale;
    vpr[r].f = f;
    vpr[r].outside = outside;
    return r;
}
fn vp_reduction_style(in_loop: bool, ordered: bool) -> u8 { if ordered { VRS_ORDERED } else if in_loop { VRS_IN_LOOP } else { VRS_UNORDERED } }

var lvp_in_loop_rdx = hm_new();
var lv_noalias_prepared: bool = false;   // LoopVersioning::prepareNoAliasMetadata was called   // Config.getInLoopReductions()

// VPlanTransforms::createHeaderPhiRecipes
fn vp_create_header_phi_recipes(pse: i32, allow_reordering: bool) -> bool {
    let header = vpbu_plain_cfg_header();
    var phis: i32[>..<] = [];
    vp_block_phis(header, phis);
    for phir in phis {
        let phi = vp_underlying_instr(phir);
        let start = vp_op(phir, 0);
        let be = vp_op(phir, 1);
        var hr: i32 = -1;
        if lvl_is_fixed_order_recurrence(phi) {
            hr = vp_new_first_order_recurrence_phi(phi, start, be);
        } else {
            let d = lvl_ind_of(phi);
            if d >= 0 {
                hr = vp_create_widen_induction_recipe(phi, phir, start, d, vpr[phir].dl);
            } else {
                let rd = lvl_rdx_of(phi);
                if rd < 0 { fatal("internal: only reductions are expected now"); }
                let ordered = !allow_reordering && rdx_descs[rd].ordered;
                let f = if ty_is_fp(vals[phi].ty) { vpf_fmf(rdx_descs[rd].fmf) } else { vpf_none() };
                hr = vp_new_reduction_phi(phi, rdx_descs[rd].kind, start, be,
                                          vp_reduction_style(hm_has(lvp_in_loop_rdx, phi as u64), ordered), 1, f, rdx_descs[rd].multi_use);
            }
        }
        vpr[hr].dl = vpr[phir].dl;
        vp_insert_before(hr, phir);
        vp_rauw(vpr[phir].def, vpr[hr].def);
        vp_erase_recipe(phir);
    }
    // tryToSinkOrHoistRecurrenceUsers
    var hp: i32[>..<] = [];
    vp_block_phis(header, hp);
    for r in hp { if vpr[r].kind == VPR_FIRST_ORDER_RECURRENCE_PHI { vp_unported("fixed-order recurrences"); } }
    var sp: i32[>..<] = [];
    vp_block_phis(vp_scalar_preheader(), sp);
    if hp.len != sp.len { return true; }
    for k in hp.len {
        let resume = sp[k];
        if vpr[hp[k]].kind == VPR_FIRST_ORDER_RECURRENCE_PHI {
            vpr[resume].name = intern("scalar.recur.init");
            vpr[vp_def(vp_op(resume, 0))].name = intern("vector.recur.extract");
            continue;
        }
        vpr[resume].name = if vp_is_widen_induction_kind(vpr[hp[k]].kind) { intern("bc.resume.val") } else { intern("bc.merge.rdx") };
    }
    return true;
}

// finalizeSCEVPredicates
fn vp_finalize_scev_predicates(pse: i32, opt_for_size: bool, threshold: i64) -> bool {
    let header = vpbu_plain_cfg_header();
    var phis: i32[>..<] = [];
    vp_block_phis(header, phis);
    for r in phis {
        if !vp_is_widen_induction_kind(vpr[r].kind) { continue; }
        let d = vpr[r].ind;
        for k in ind_descs[d].preds_n as i64 { pse_add_predicate(pse, ind_pred(d, k)); }
    }
    let total = su_n(pse_union(pse));
    if total != 0 && opt_for_size { return false; }
    if total > threshold { return false; }
    return true;
}

// handleEarlyExits(NoUncountableExit): disconnect countable early exits
fn vp_handle_early_exits(style: i64) -> bool {
    let middle = vpbu_plain_cfg_middle_block();
    if style != 0 { vp_unported("uncountable early exits"); }
    for j in xv_len(vph.exit_blocks) {
        let eb = xv_get(vph.exit_blocks, j);
        var ps: i32[>..<] = [];
        xv_to(vpb[eb].preds, ps);
        for p in ps {
            if p == middle { continue; }
            var phis: i32[>..<] = [];
            vp_block_phis(eb, phis);
            for r in phis { vp_phi_remove_incoming_value_for(r, p); }
            vp_erase_recipe(vp_terminator(p));
            vpbu_disconnect(p, eb);
        }
    }
    return true;
}

// addMiddleCheck
fn vp_add_middle_check() {
    let middle = vpbu_plain_cfg_middle_block();
    if vp_nsuccs(middle) == 1 { return; }
    let latch = vp_single_pred(middle);
    let ldl = vpr[vp_terminator(latch)].dl;
    vpb_set_at_end(middle);
    let cmp = vpb_icmp(32, vph.trip_count, vph.vtc, ldl, "cmp.n");
    vpb_nary(VPI_BRANCH_ON_COND, [vp_val(cmp)], vpf_none(), ldl, "", -1);
}

// createLoopRegions
fn vp_create_loop_regions(dl: i32) {
    vp_dt_build();
    var rpo: i32[>..<] = [];
    vp_rpo(vph.entry, false, rpo);
    var k = rpo.len - 1;
    while k >= 0 {
        let h = rpo[k];
        k--;
        if vp_canonical_header_and_latch(h) { vp_create_loop_region_for(h, dl); }
    }
    let top = vp_vector_loop_region();
    vpb[top].name = intern("vector loop");
    vpb[vp_entry_basic_block(top)].name = intern("vector.body");
}

// introduceMasksAndLinearize (VPlanPredicator.cpp)
fn vp_introduce_masks_and_linearize() {
    let region = vp_vector_loop_region();
    let header = vp_entry_basic_block(region);
    var rpo: i32[>..<] = [];
    vp_rpo(header, false, rpo);
    if rpo.len > 1 { vp_unported("if-conversion (VPPredicator, more than one block in the loop)"); }
    if vpb[region].header_mask >= 0 { vp_unported("masked header blocks (tail folding)"); }
}
