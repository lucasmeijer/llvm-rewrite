// The processLoop tail after computeBestVF and LoopVectorizationPlanner::executePlan
// (llvm/lib/Transforms/Vectorize/LoopVectorize.cpp: processLoop's runtime-check / diagnostics / epilogue decisions,
// addMinimumIterationCheck, attachRuntimeChecks, executePlan, createVectorizedLoopSkeleton / createScalarPreheader,
// replaceVPBBWithIRVPBB, updateLoopMetadataAndProfileInfo, fixVectorizedLoop / legacyCSE;
// LoopVectorizeHints::setAlreadyVectorized from LoopVectorizationLegality.cpp; addRuntimeUnrollDisableMetaData).
import std;
import ir;
import irutil;
import instinfo;
import flags;
import analyses;
import domtree;
import dtu;
import loopinfo;
import loop_md;
import loop_utils;
import loopsimplify;
import profdata;
import scev;
import scev_update;
import tti;
import iv_descriptors;
import lv_legality;
import lv_cm;
import vplan;
import vplan_utils;
import vplan_props;
import vplan_transforms;
import vplan_exec_transforms;
import vplan_execute;

var lvx_l: i32 = -1;
var lvx_pse: i32 = -1;
var lvx_fv: i32 = -1;

fn lvx_setup(l: i32, pse: i32, fv: i32) { lvx_l = l; lvx_pse = pse; lvx_fv = fv; }

// requiresScalarEpilogue(Plan, VF): the middle block branches unconditionally to the scalar preheader
fn lvx_requires_scalar_epilogue() -> bool { vp_single_succ(vp_middle_block()) == vp_scalar_preheader() }

// the processLoop tail for the loaded best plan with VF `vf` and interleave count `ic` (user-forced)
fn lv_execute_best_plan(vf: i64, ic: i64) -> bool {
    // GeneratedRTChecks: no runtime checks are supported yet (tryToBuildVPlan1 fails loudly on memory checks)
    if !su_always_true(pse_union(lvx_pse)) { vp_unported("SCEV runtime checks (GeneratedRTChecks)"); }
    // isOutsideLoopWorkProfitable: the scalar cost of a user VF is 0 -> profitable
    if vf == 1 && ic <= 1 { return false; }
    if vf == 1 { vp_unported("interleaving without vectorizing"); }
    // selectBestEpiloguePlan: preferEpilogueVectorization is getMaxInterleaveFactor(VF * IC) > 1
    if lvx_epilogue_candidate(vf, ic) { vp_unported("epilogue vectorization"); }
    let latch = loop_latch(lvx_l);
    let has_bw = inst_get_md(block_terminator(latch), md_kind_id("prof")) >= 0;
    let pred = loop_predecessor(lvx_l);
    vpx_add_minimum_iteration_check(vf, ic, 0, lvx_requires_scalar_epilogue(), vp_has_tail_folded(), lvx_l,
                                    inst_get_md(block_terminator(pred), 0), lvx_pse, has_bw);
    lvx_execute_plan(vf, ic);
    return true;
}

fn lvx_epilogue_candidate(vf: i64, ic: i64) -> bool {
    if !flag_bool("enable-epilogue-vectorization", true) { return false; }
    if !lvx_epilogue_allowed { return false; }
    if lvx_exiting_block(lvx_l) != loop_latch(lvx_l) { return false; }
    if func_has_fn_attr(lvx_fv, AK_OptimizeForSize) || func_has_fn_attr(lvx_fv, AK_MinSize) { return false; }
    let mif = if tti_kind == TTI_X86 { x86_max_interleave_factor_lv(vf * ic) } else { 1 };
    if mif <= 1 { return false; }
    let minvf = if flag_given("epilogue-vectorization-minimum-VF") { flag_int("epilogue-vectorization-minimum-VF", 16) } else { 16 };
    return vf * ic >= minvf;
}
var lvx_epilogue_allowed: bool = true;
fn x86_max_interleave_factor_lv(vf: i64) -> i64 { x86_max_interleave_factor(vf) }
fn lvx_exiting_block(l: i32) -> i32 {
    var ex: i32[>..<] = [];
    loop_exiting_blocks(l, ex);
    return if ex.len == 1 { ex[0] } else { -1 };
}

// replaceVPBBWithIRVPBB
fn lvx_replace_vpbb_with_irvpbb(vpbb: i32, irbb: i32) -> i32 {
    let n = vp_create_ir_basic_block(irbb);
    let ip = vpb[n].first;
    var phis: i32[>..<] = [];
    vp_block_phis(vpbb, phis);
    for r in phis { vp_move_before(r, n, ip); }
    var rest: i32[>..<] = [];
    var r = vp_first_non_phi(vpbb);
    while r >= 0 { rest.push(r); r = vpr[r].next; }
    for x in rest { vp_move_before(x, n, -1); }
    // reassociateBlocks
    var ps: i32[>..<] = [];
    xv_to(vpb[vpbb].preds, ps);
    var ss: i32[>..<] = [];
    xv_to(vpb[vpbb].succs, ss);
    for p in ps { vp_replace_succ(p, vpbb, n); }
    for s in ss { vp_replace_pred(s, vpbb, n); }
    for p in ps { xv_push(vpb[n].preds, p); }
    for s in ss { xv_push(vpb[n].succs, s); }
    xv_clear(vpb[vpbb].preds);
    xv_clear(vpb[vpbb].succs);
    if vph.scalar_header == vpbb { vph.scalar_header = n; }
    vpb[vpbb].dead = true;
    return n;
}

// Loop::addIntLoopAttribute / LoopVectorizeHints::setAlreadyVectorized
fn lvx_set_already_vectorized(l: i32) {
    let attr = md_get(MK_TUPLE, -1, [md_string("llvm.loop.isvectorized"), md_value(c_int(T_I32, 1))], false);
    let removes: const u8[:][2] = ["llvm.loop.vectorize.", "llvm.loop.interleave."];
    let nid = make_post_transformation_metadata(loop_id(l), removes, [attr]);
    lmd_set_loop_id(l, nid);
}

// addRuntimeUnrollDisableMetaData
fn lvx_add_runtime_unroll_disable_metadata(l: i32) {
    var opsv: i32[>..<] = [];
    opsv.push(-1);
    var is_unroll = false;
    let id = loop_id(l);
    if id >= 0 {
        for k in 1..(mds[id].nops as i64) {
            let o = md_op(id, k);
            if o >= 0 && md_is_node(o) {
                if mds[o].nops == 0 { opsv.push(o); continue; }
                let s = md_op(o, 0);
                if s < 0 || mds[s].kind != MK_STRING { continue; }
                let nm = sbytes(mds[s].extra);
                if starts_with(nm, "llvm.loop.unroll.runtime.disable") { continue; }
                is_unroll = starts_with(nm, "llvm.loop.unroll.disable");
            }
            opsv.push(o);
        }
    }
    if is_unroll { return; }
    opsv.push(md_get(MK_TUPLE, -1, [md_string("llvm.loop.unroll.runtime.disable")], false));
    lmd_set_loop_id(l, lvx_self_ref_loop_id(opsv));
}

// updateLoopMetadataAndProfileInfo
fn lvx_update_loop_metadata(vloop: i32, has_header: bool, orig_id: i32, disable_runtime_unroll: bool) {
    let l = lvx_l;
    let sph = vp_scalar_preheader();
    let fu_all: const u8[:] = "llvm.loop.vectorize.followup_all";
    if sph >= 0 {
        let opts: const u8[:][2] = ["llvm.loop.vectorize.followup_all", "llvm.loop.vectorize.followup_epilogue"];
        let has, rid = lvx_make_followup_loop_id(orig_id, opts);
        if has { lmd_set_loop_id(l, rid); }
        else {
            if disable_runtime_unroll { lvx_add_runtime_unroll_disable_metadata(l); }
            lvx_set_already_vectorized(l);
        }
    }
    if vloop < 0 { return; }
    let opts2: const u8[:][2] = ["llvm.loop.vectorize.followup_all", "llvm.loop.vectorize.followup_vectorized"];
    let has2, vid = lvx_make_followup_loop_id(orig_id, opts2);
    if has2 { lmd_set_loop_id(vloop, vid); }
    else {
        if orig_id >= 0 { lmd_set_loop_id(vloop, orig_id); }
        lvx_set_already_vectorized(vloop);
    }
    lvx_add_runtime_unroll_disable_metadata(vloop);
    // profile: no entry count / estimated trip count handling yet
    let has_avg, avg = get_loop_estimated_trip_count(l);
    if has_avg { vp_unported("estimated trip counts on vectorized loops (branch weights)"); }
}
fn lvx_make_followup_loop_id(orig: i32, opts: const u8[:][2]) -> bool, i32 {
    if orig < 0 { return false, -1; }
    for k in 1..(mds[orig].nops as i64) {
        let o = md_op(orig, k);
        if o < 0 || !md_is_node(o) || mds[o].nops < 1 { continue; }
        let s = md_op(o, 0);
        if s < 0 || mds[s].kind != MK_STRING { continue; }
        let nm = sbytes(mds[s].extra);
        if nm == opts[0] || nm == opts[1] { vp_unported("followup loop metadata (makeFollowupLoopID)"); }
    }
    return false, -1;
}
// MDNode::getDistinct with a self reference in operand 0
fn lvx_self_ref_loop_id(opsv: i32[>..<]&) -> i32 {
    let n = md_get(MK_TUPLE, -1, opsv, true);
    md_ops[mds[n].ops] = n;
    return n;
}

// legacyCSE(BB)
fn lvx_legacy_cse(bb: i32) {
    var seen: i32[>..<] = [];
    var i = block_first(bb);
    while i >= 0 {
        let nx = inst_next(i);
        let o = iop(i);
        if o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT || o == OP_SHUFFLEVECTOR || o == OP_GEP {
            var found: i32 = -1;
            for s in seen { if lvx_identical(s, i) { found = s; break; } }
            if found >= 0 { rauw(i, found); inst_erase_from_parent(i); }
            else { seen.push(i); }
        }
        i = nx;
    }
}

// LoopVectorizationPlanner::executePlan
fn lvx_execute_plan(vf: i64, uf: i64) {
    let pse = lvx_pse;
    vpx_replace_wide_canonical_iv_with_wide_iv();
    vpx_unroll_by_uf(uf);
    vpx_materialize_packs_and_unpacks();
    vpx_materialize_broadcasts();
    vpx_replicate_by_vf(vf);
    let latch = loop_latch(lvx_l);
    if inst_get_md(block_terminator(latch), md_kind_id("prof")) >= 0 { vp_unported("branch weights (addBranchWeightToMiddleTerminator)"); }
    let vector_ph = vp_vector_preheader();
    vpx_materialize_constant_vector_trip_count(vf, uf);
    vpx_optimize_for_vf_and_uf(vf, uf, pse);
    vpt_simplify_recipes();
    let rse = lvx_requires_scalar_epilogue();
    vpt_remove_branch_on_const(false);
    if vp_single_succ(vph.entry) == vp_scalar_preheader() { vp_unported("a vector loop that never executes"); }
    vpt_remove_dead_recipes();
    vpx_convert_to_concrete_recipes();
    let tail_folded = vp_has_tail_folded();
    vpx_dissolve_loop_regions();
    vpx_expand_branch_on_two_conds();
    vpt_remove_branch_on_const_latches();
    vpx_materialize_backedge_taken_count(vector_ph);
    vpx_materialize_vector_trip_count(vector_ph, tail_folded, rse, vph.vfxuf);
    vpx_materialize_factors(vector_ph, vf);
    vpx_expand_scevs_to_vp_instructions();
    vpx_cse();
    vpt_simplify_recipes();
    if vpt_remove_branch_on_const(false) { vpt_simplify_recipes(); }
    let entry_irbb = vpb[vph.entry].irbb;
    vpx_expand_scevs(entry_irbb);
    vts_reset(vf, lvx_fv, loop_parent(lvx_l));
    dtu_begin(lvx_fv, true, false, true);
    // createVectorizedLoopSkeleton: createScalarPreheader("")
    let ph = loop_preheader(lvx_l);
    let sph_bb = lu_split_block_named(ph, block_terminator(ph), "scalar.ph", false);
    vts_prev_bb = single_pred(sph_bb);
    let sph = vp_scalar_preheader();
    if sph >= 0 { lvx_replace_vpbb_with_irvpbb(sph, vts_single_succ_bb(vts_prev_bb)); }
    vpt_remove_dead_recipes();
    for j in xv_len(vph.exit_blocks) {
        let eb = xv_get(vph.exit_blocks, j);
        if vp_npreds(eb) == 0 { continue; }
        var phis: i32[>..<] = [];
        vp_block_phis(eb, phis);
        for r in phis { sc_forget_lcssa_phi_with_new_predecessor(lvx_l, vpr[r].ir_inst); }
    }
    sc_forget_loop(lvx_l);
    sc_forget_block_and_loop_dispositions_all();
    let lid = loop_id(lvx_l);
    vts_execute_plan();
    dtu_end();
    var header_vpbb: i32 = -1;
    var sh: i32[>..<] = [];
    vp_depth_first(vph.entry, false, sh);
    for b in sh { if vp_is_header_block(b) { header_vpbb = b; break; } }
    let disable_runtime_unroll = vf > 1;
    var vloop: i32 = -1;
    if header_vpbb >= 0 { vloop = li_loop_for(vts_bb_of(header_vpbb)); }
    lvx_update_loop_metadata(vloop, header_vpbb >= 0, lid, disable_runtime_unroll);
    if header_vpbb >= 0 { lvx_legacy_cse(vts_bb_of(header_vpbb)); }
}
// removeBranchOnConst(Plan, OnlyLatches = true)
fn vpt_remove_branch_on_const_latches() {
    var bs: i32[>..<] = [];
    vp_depth_first(vph.entry, false, bs);
    vp_dt_build();
    for b in bs {
        if !vp_is_basic(b) || vp_block_empty(b) { continue; }
        let t = vpb[b].last;
        if !vpm_vpi_r(t, VPI_BRANCH_ON_COND, 1) { continue; }
        if !vp_is_latch_block(b) { continue; }
        if vp_is_constant_int(vp_op(t, 0)) { vp_unported("removing a constant latch branch"); }
    }
}

// Instruction::isIdenticalTo for the instructions legacyCSE handles (insertelement, extractelement, shufflevector, GEP)
fn lvx_identical(a: i32, b: i32) -> bool {
    if iop(a) != iop(b) || vals[a].ty != vals[b].ty || nops(a) != nops(b) { return false; }
    for k in nops(a) { if op(a, k) != op(b, k) { return false; } }
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.flags != y.flags || x.ty2 != y.ty2 || x.naux != y.naux { return false; }
    for k in x.naux as i64 { if ints[(x.aux as i64) + k] != ints[(y.aux as i64) + k] { return false; } }
    return true;
}
