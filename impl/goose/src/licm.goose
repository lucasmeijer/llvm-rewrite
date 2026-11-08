// LICM: port of llvm/lib/Transforms/Scalar/LICM.cpp (LICMPass::run / LNICMPass::run,
// LoopInvariantCodeMotion::runOnLoop, SinkAndHoistLICMFlags, sinkRegion, sinkRegionForLoopNest, ControlFlowHoister,
// hoistRegion, isLoadInvariantInLoop, isHoistableAndSinkableInst, isOnlyMemoryAccess, getClobberingMemoryAccess,
// canHoistLoad, canSinkOrHoistInst, isTriviallyReplaceablePHI, isFoldableInLoop, isNotUsedOrFoldableInLoop,
// cloneInstructionInExitBlock, eraseInstruction, moveInstructionBefore, sinkThroughTriviallyReplaceablePHI,
// canSplitPredecessors, splitPredecessorsOfLoopExit, sink, hoist, isSafeToExecuteUnconditionally, LoopPromoter,
// isNotCapturedBeforeOrInLoop, isNotVisibleOnUnwindInLoop, isThreadLocalObject, promoteLoopAccessesToScalars,
// foreachMemoryAccess, collectPromotionCandidates, noConflictingReadWrites, pointerInvalidatedByLoop,
// pointerInvalidatedByBlock, hoistMinMax, hoistGEP, hoistAdd, hoistSub, hoistAddSub, isReassociableOp,
// hoistMulAddAssociation, hoistBOAssociation, hoistSubAddAssociation, hoistArithmetics, inSubLoop), with
// LoadAndStorePromoter::run (llvm/lib/Transforms/Utils/SSAUpdater.cpp), collectChildrenInLoop and
// hasDisableLICMTransformsHint (llvm/lib/Transforms/Utils/LoopUtils.cpp), LoopBlocksDFS/LoopBlocksRPO
// (llvm/lib/Analysis/LoopInfo.cpp), LoopInfo::wouldBeOutOfLoopUseRequiringLCSSA, OverflowTracking
// (llvm/lib/Transforms/Utils/Local.cpp), AAMDNodes::merge (llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp) and
// DebugLoc::getMergedLocations (llvm/lib/IR/DebugLoc.cpp).
//
// One LICM run at a time (lc_* state). ControlFlowHoister's DenseMaps are vectors (every LLVM iteration over them
// is order independent). The IRBuilder<> with a ConstantFolder is lb_* (insertion adopts the debug records at the
// insertion point, as an iterator without the head bit does). Not ported (fail loudly): funclet colours,
// optimization remarks are never printed (no -pass-remarks), mergeDIAssignID with DIAssignID attachments,
// getMostGenericTBAA of different tags.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import gen_attrs;
import analyses;
import flags;
import datalayout;
import constfold;
import domtree;
import loopinfo;
import memloc;
import aautil;
import aa;
import tbaa;
import capture;
import memoryssa;
import mssaupdater;
import mustexec;
import ast;
import vt;
import pm;
import knownbits;
import overflow;
import local;
import dinfo;
import salvage;
import knowledge;
import mem2reg;
import ssaupdater;
import loopsimplify;
import lcssa;
import cfgutil;
import speculate;
import tti;
import autoupgrade;
import scev;
import scev_create;
import scev_eval;

var lc_l: i32 = -1;              // CurLoop of runOnLoop
var lc_fv: i32 = -1;
var lc_allow_spec: bool = true;
// SinkAndHoistLICMFlags
var lc_opt_cap: i64 = 100;
var lc_noacc_cap: i64 = 250;
var lc_opt_counter: i64 = 0;
var lc_too_many_acc: bool = false;
var lc_is_sink: bool = true;

fn lc_not_ported(what: const u8[:]) { fatal(str("LICM: ", what, " is not ported yet")); }

// Loop::isLoopInvariant / hasLoopInvariantOperands / contains(Instruction)
fn lc_invariant(l: i32, v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }
fn lc_invariant_operands(l: i32, i: i32) -> bool {
    for k in nops(i) { if !lc_invariant(l, op(i, k)) { return false; } }
    return true;
}
fn lc_contains_inst(l: i32, i: i32) -> bool { loop_contains(l, inst_parent(i)) }
// inSubLoop
fn lc_in_sub_loop(bb: i32, l: i32) -> bool { li_loop_for(bb) != l }

// ---------------------------------------------------------------------------------------------
// IRBuilder<> (ConstantFolder)

var lb_pos: i32 = -1;
var lb_dl: i32 = -1;
fn lb_set(i: i32) { lb_pos = i; lb_dl = inst_get_md(i, MDK_DBG_SC); }
fn lb_insert(iv: i32, name: const u8[:]) -> i32 {
    m2r_insert_before_adopting(iv, lb_pos);
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if lb_dl >= 0 { inst_set_md(iv, MDK_DBG_SC, lb_dl); }
    return iv;
}
// CreateBinOp / CreateAdd / CreateSub / CreateMul with no-wrap flags (FoldNoWrapBinOp / FoldBinOp)
fn lb_binop(o: i64, a: i32, b: i32, name: const u8[:], fl: u8) -> i32 {
    if is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, fl); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(iv)].flags = fl;
    return lb_insert(iv, name);
}
// CreateFMulFMF(L, R, FMFSource, Name)
fn lb_fmul_fmf(a: i32, b: i32, fmf_src: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_binop(OP_FMUL, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_FMUL, vals[a].ty, [a, b]);
    insts[inst_of(iv)].fmf = insts[inst_of(fmf_src)].fmf;
    return lb_insert(iv, name);
}
// CreateICmp (FoldCmp: ConstantFoldCompareInstruction)
fn lb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let r = cf_cmp(p, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(OP_ICMP, cmp_result_type(vals[a].ty), [a, b]);
    insts[inst_of(iv)].pred = p as u8;
    return lb_insert(iv, name);
}
// CreateFreeze (no folding)
fn lb_freeze(v: i32, name: const u8[:]) -> i32 { lb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }
// CreateBinaryIntrinsic (ConstantFolder::FoldIntrinsic folds nothing)
fn lb_binary_intrinsic(id: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, [vals[a].ty as i32]);
    let fty = globs[glob_of(f)].vty;
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), [a, b, f]);
    insts[inst_of(iv)].ty2 = fty;
    return lb_insert(iv, name);
}
// CreateGEP(Ty, Ptr, IdxList, Name, NW)
fn lb_gep(srcty: i32, p: i32, idxs: const i32[:], flags: u8, name: const u8[:]) -> i32 {
    var allc = is_constant(p);
    for x in idxs { if !is_constant(x) { allc = false; } }
    if allc { return ce_gep(srcty, p, idxs, flags, -1); }
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    var rt: i32 = vals[p].ty;
    for x in idxs { if ty_is_vector(vals[x].ty) { rt = ty_vector(vals[p].ty, types[vals[x].ty].cnt, types[vals[x].ty].kind == TK_SVEC); } }
    if ty_is_vector(vals[p].ty) { rt = vals[p].ty; }
    let iv = create_inst(OP_GEP, rt, opsv);
    insts[inst_of(iv)].ty2 = srcty;
    insts[inst_of(iv)].flags = flags;
    return lb_insert(iv, name);
}

fn cmp_result_type(t: i32) -> i32 {
    if ty_is_vector(t) { return ty_vector(T_I1, types[t].cnt, types[t].kind == TK_SVEC); }
    return T_I1;
}

// ConstantFoldCompareInstruction (no DataLayout)
fn cf_cmp(p: i64, a: i32, b: i32) -> i32 { cf_fold_cmp_operands(p, a, b, -1) }

// ---------------------------------------------------------------------------------------------
// Helpers on instructions and blocks

// RAUW that keeps debug records up to date (ValueAsMetadata::handleRAUW)
fn lc_rauw(old: i32, nw: i32) { m2r_dbg_rauw(old, nw); rauw(old, nw); }

// eraseInstruction(I, SafetyInfo, MSSAU)
fn lc_erase(i: i32) {
    msu_remove_inst_access(i, false);
    lsi_remove_instruction(i);
    m2r_erase(i);
}

// Instruction::dropLocation
fn lc_drop_location(i: i32) {
    let dl = inst_get_md(i, MDK_DBG_SC);
    if dl < 0 { return; }
    var may_call = false;
    if is_callbase(i) {
        let id = inst_iid(i);
        may_call = id == 0 || starts_with(intr_name(id as i64), "llvm.objc.");
    }
    if !may_call { inst_erase_md(i, MDK_DBG_SC); return; }
    let sp = func_get_md(inst_func(i), 0);
    if sp >= 0 { inst_set_md(i, MDK_DBG_SC, di_location_get(0, 0, sp, -1, false)); }
    else { inst_erase_md(i, MDK_DBG_SC); }
}

// Instruction::moveBefore(BB, It) (Preserve = false): the instruction's own records stay behind (they move to the
// next instruction); without the head bit it absorbs the records attached at the destination.
fn lc_move_before(i: i32, pos: i32, head: bool) {
    if dbgrecs.len > 0 { dbg_records_to_next(i); }
    inst_remove(i);
    if head { inst_insert_before(i, pos); } else { m2r_insert_before_adopting(i, pos); }
}

// BasicBlock::getFirstNonPHIIt
fn lc_first_non_phi(bb: i32) -> i32 { first_non_phi(bb) }
// BasicBlock::getFirstInsertionPt (with the head bit)
fn lc_first_insertion_pt(bb: i32) -> i32 {
    var i = first_non_phi(bb);
    if i >= 0 && inst_is_eh_pad(i) { i = inst_next(i); }
    return i;
}

// LoopInfo::wouldBeOutOfLoopUseRequiringLCSSA(V, ExitBB)
fn lc_would_need_lcssa(v: i32, exit: i32) -> bool {
    if vals[v].ty == T_TOKEN { return false; }
    if !is_inst(v) { return false; }
    let l = li_loop_for(inst_parent(v));
    if l < 0 { return false; }
    if loop_contains(l, exit) { return false; }
    return true;
}

// collectChildrenInLoop(DT, N, CurLoop)
fn lc_children_in_loop(header: i32, l: i32, out: i32[>..<]&) {
    out.clear();
    if loop_contains(l, header) { out.push(header); }
    var k: i64 = 0;
    while k < out.len {
        var c = dt_first_child(lc_fv, DT_DOM, out[k]);
        while c >= 0 {
            if loop_contains(l, c) { out.push(c); }
            c = dt_next_sibling(DT_DOM, c);
        }
        k++;
    }
}

// LoopBlocksDFS::perform + LoopBlocksRPO: reverse post-order of the loop's blocks from the header
fn lc_loop_rpo(l: i32, out: i32[>..<]&) {
    out.clear();
    var post: i32[>..<] = [];
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    vs_clear(VS_PASS0);
    let h = loop_header(l);
    vs_add(VS_PASS0, h);
    st_b.push(h);
    st_k.push(0);
    while st_b.len > 0 {
        let top = st_b.len - 1;
        let b = st_b[top];
        let k = st_k[top];
        if k < block_nsucc(b) {
            st_k[top] = k + 1;
            let s = block_succ(b, k);
            // insertEdge: L->contains(LI->getLoopFor(BB)) and not visited
            let sl = li_loop_for(s);
            if sl >= 0 && loop_contains_loop(l, sl) && vs_add(VS_PASS0, s) { st_b.push(s); st_k.push(0); }
        } else {
            post.push(b);
            st_b.pop();
            st_k.pop();
        }
    }
    var i = post.len;
    while i > 0 { i--; out.push(post[i]); }
}

// hasDisableLICMTransformsHint: getBooleanLoopAttribute(L, "llvm.licm.disable")
fn lc_disable_hint(l: i32) -> bool {
    let md = find_option_md_for_loop_id(loop_id(l), "llvm.licm.disable");
    if md < 0 { return false; }
    if mds[md].nops == 1 { return true; }
    let c = mds[md_op(md, 1)].extra;
    return !is_null_value(c);
}

// ---------------------------------------------------------------------------------------------
// SinkAndHoistLICMFlags

fn lc_flags_init(l: i32) {
    lc_opt_cap = flag_int("licm-mssa-optimization-cap", 100);
    lc_noacc_cap = flag_int("licm-mssa-max-acc-promotion", 250);
    lc_opt_counter = 0;
    lc_too_many_acc = false;
    lc_is_sink = true;
    var cnt: i64 = 0;
    for k in loop_nblocks(l) {
        var a = mb_first(loop_block(l, k));
        while a >= 0 {
            cnt++;
            if cnt > lc_noacc_cap { lc_too_many_acc = true; return; }
            a = macc[a].next;
        }
    }
}

// getClobberingMemoryAccess(MSSA, BAA, Flags, MA)
fn lc_clobbering(ma: i32, q: i32) -> i32 {
    if lc_opt_counter >= lc_opt_cap { return ma_def(ma); }
    // getSkipSelfWalker()->getClobberingMemoryAccess(MA, BAA)
    cw_limit = mssa_max_check_limit();
    let s = mssa_clobbering_access(ma, q, true, true);
    lc_opt_counter++;
    return s;
}

// ---------------------------------------------------------------------------------------------
// LICMPass::run / LNICMPass::run

// Returns the preserved set (PA_ALL when nothing changed).
fn licm_pass_run(l: i32, allow_spec: bool, nest: bool) -> u32 {
    lc_fv = block_func(loop_header(l));
    lc_allow_spec = allow_spec;
    tli_cur_fn = lc_fv;
    tti_init_function(lc_fv, globs[glob_of(lc_fv)].module);
    m2r_collect_records(lc_fv);
    let changed = licm_run_on_loop(l, nest);
    if !changed { return PA_ALL; }
    return ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV) | ((1 as u32) << A_MEMORYSSA);
}

// LoopInvariantCodeMotion::runOnLoop
fn licm_run_on_loop(l: i32, nest: bool) -> bool {
    lc_l = l;
    var changed = false;
    if lc_disable_hint(l) { return false; }
    var has_coro_suspend = false;
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 { if inst_iid(i) == IID_coro_suspend { has_coro_suspend = true; } i = inst_next(i); }
    }
    msu_reset();
    lc_flags_init(l);
    let preheader = loop_preheader(l);
    lsi_compute(l);
    if loop_has_dedicated_exits(l) {
        if nest { if lc_sink_region_for_loop_nest(l) { changed = true; } }
        else { if lc_sink_region(l, -1) { changed = true; } }
    }
    lc_is_sink = false;
    if preheader >= 0 { if lc_hoist_region(l, nest) { changed = true; } }
    if !flag_bool("disable-licm-promotion", false) && preheader >= 0 && loop_has_dedicated_exits(l) &&
       !lc_too_many_acc && !has_coro_suspend {
        var exits: i32[>..<] = [];
        lc_unique_exit_blocks(l, exits);
        var has_cs = false;
        for e in exits { if iop(block_terminator(e)) == OP_CATCHSWITCH { has_cs = true; } }
        if !has_cs {
            var ins_pts: i32[>..<] = [];
            var mssa_ins: i32[>..<] = [];
            for e in exits { ins_pts.push(lc_first_insertion_pt(e)); mssa_ins.push(-1); }
            var promoted = false;
            loop {
                var local = false;
                lc_collect_promotion_candidates(l);
                // the candidates are copied out first (the next collection reuses the pools)
                var cand_at: i32[>..<] = [];
                var cand_n: i32[>..<] = [];
                var cand_reads: bool[>..<] = [];
                var cand_ptrs: i32[>..<] = [];
                for k in lc_cand_at.len {
                    cand_at.push(cand_ptrs.len as i32);
                    cand_n.push(lc_cand_n[k]);
                    cand_reads.push(lc_cand_reads[k]);
                    for j in lc_cand_n[k] as i64 { cand_ptrs.push(lc_cand_ptrs[(lc_cand_at[k] as i64) + j]); }
                }
                for k in cand_at.len {
                    let at = cand_at[k] as i64;
                    let n = cand_n[k] as i64;
                    if lc_promote(cand_ptrs[at..at + n], exits, ins_pts, mssa_ins, l, cand_reads[k]) { local = true; }
                }
                if local { promoted = true; }
                if !local { break; }
            }
            if promoted { form_lcssa_recursively(l); }
            if promoted { changed = true; }
        }
    }
    if flag_bool("verify-memoryssa", false) { mssa_verify(lc_fv); }
    if changed { sc_forget_loop_dispositions(); }
    return changed;
}

// Loop::getUniqueExitBlocks
fn lc_unique_exit_blocks(l: i32, out: i32[>..<]&) {
    out.clear();
    vs_clear(VS_PASS0);
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        let t = block_terminator(bb);
        if t < 0 { continue; }
        for j in term_nsucc(t) {
            let s = term_succ(t, j);
            if loop_contains(l, s) { continue; }
            if vs_add(VS_PASS0, s) { out.push(s); }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// sinkRegion

fn lc_sink_region(cur: i32, outermost: i32) -> bool {
    var wl: i32[>..<] = [];
    lc_children_in_loop(loop_header(cur), cur, wl);
    var changed = false;
    var w = wl.len;
    while w > 0 {
        w--;
        let bb = wl[w];
        if lc_in_sub_loop(bb, cur) { continue; }
        var i = block_last(bb);
        while i >= 0 {
            let nxt = inst_next(i);
            var erased = false;
            if is_instruction_trivially_dead(i) {
                salvage_knowledge(i, false);
                salvage_debug_info(i);
                lc_erase(i);
                erased = true;
                changed = true;
            } else {
                var foldable = false;
                let nest = outermost >= 0;
                if !inst_may_have_side_effects(i) {
                    let ok, fold = lc_not_used_or_foldable(i, if nest { outermost } else { cur }, nest);
                    foldable = fold;
                    if ok && lc_can_sink_or_hoist(i, cur, true) {
                        if lc_sink(i, cur) {
                            if !foldable {
                                salvage_debug_info(i);
                                lc_erase(i);
                                erased = true;
                            }
                            changed = true;
                        }
                    }
                }
            }
            if erased { i = if nxt >= 0 { inst_prev(nxt) } else { block_last(bb) }; }
            else { i = inst_prev(i); }
        }
    }
    if flag_bool("verify-memoryssa", false) { mssa_verify(lc_fv); }
    return changed;
}

// sinkRegionForLoopNest
fn lc_sink_region_for_loop_nest(cur: i32) -> bool {
    var changed = false;
    // SmallPriorityWorklist: insert(CurLoop), appendLoopsToWorklist(*CurLoop) (the subloops' reversed preorder)
    var wl: i32[>..<] = [];
    wl.push(cur);
    var tmp: i32[>..<] = [];
    var k = loop_nsubs(cur);
    var roots: i32[>..<] = [];
    while k > 0 { k--; roots.push(loop_sub(cur, k)); }
    for r in roots {
        var stack: i32[>..<] = [];
        stack.push(r);
        tmp.clear();
        while stack.len > 0 {
            let x = stack.pop();
            for c in loop_nsubs(x) { stack.push(loop_sub(x, c)); }
            tmp.push(x);
        }
        for x in tmp { wl.push(x); }
    }
    while wl.len > 0 {
        let l = wl.pop();
        if lc_sink_region(l, cur) { changed = true; }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// ControlFlowHoister

struct CfhPair { k: i32, v: i32 }
var cfh_dest: CfhPair[>..<];      // HoistDestinationMap
var cfh_br: CfhPair[>..<];        // HoistableBranches: conditional branch -> common successor

fn cfh_on() -> bool { flag_bool("licm-control-flow-hoisting", false) }
fn cfh_dest_find(b: i32) -> i64 { for k in cfh_dest.len { if cfh_dest[k].k == b { return k; } } return -1; }

// registerPossiblyHoistableBranch(BI)
fn cfh_register_branch(bi: i32, l: i32) {
    if !cfh_on() || !lc_invariant_operands(l, bi) { return; }
    let td = term_succ(bi, 0);
    let fd = term_succ(bi, 1);
    if !loop_contains(l, td) || !loop_contains(l, fd) || td == fd { return; }
    var ts: i32[>..<] = [];
    var fs: i32[>..<] = [];
    for k in block_nsucc(td) { let s = block_succ(td, k); if position(ts, s) < 0 { ts.push(s); } }
    for k in block_nsucc(fd) { let s = block_succ(fd, k); if position(fs, s) < 0 { fs.push(s); } }
    var common: i32 = -1;
    if position(ts, fd) >= 0 { common = fd; }
    else if position(fs, td) >= 0 { common = td; }
    else {
        var inter: i32[>..<] = [];
        for s in ts { if position(fs, s) >= 0 { inter.push(s); } }
        if inter.len == 1 { common = inter[0]; }
        else if inter.len > 0 {
            var b = func_entry(lc_fv);
            while b >= 0 { if position(inter, b) >= 0 { common = b; break; } b = block_next(b); }
        }
    }
    // DT->dominates(BI, CommonSucc)
    if common >= 0 && dt_inst_dominates_block(bi, common) {
        for k in cfh_br.len { if cfh_br[k].k == bi { cfh_br[k].v = common; return; } }
        cfh_br.push(CfhPair { k: bi, v: common });
    }
}

// canHoistPHI(PN)
fn cfh_can_hoist_phi(pn: i32, l: i32) -> bool {
    if !cfh_on() || !lc_invariant_operands(l, pn) { return false; }
    let bb = inst_parent(pn);
    var preds: i32[>..<] = [];
    var npreds: i64 = 0;
    each_pred(bb) { p => npreds++; if position(preds, p) < 0 { preds.push(p); } };
    if preds.len != npreds { return false; }
    fn erase(b: i32) {
        let k = position(preds, b);
        if k >= 0 { var w = k; while w + 1 < preds.len { preds[w] = preds[w + 1]; w++; } preds.pop(); }
    }
    for pr in cfh_br {
        if pr.v != bb { continue; }
        let s0 = term_succ(pr.k, 0);
        let s1 = term_succ(pr.k, 1);
        if s0 == bb { erase(inst_parent(pr.k)); erase(s1); }
        else if s1 == bb { erase(inst_parent(pr.k)); erase(s0); }
        else { erase(s0); erase(s1); }
    }
    return preds.len == 0;
}

// CreateHoistedBlock (getOrCreateHoistedBlock's lambda)
fn cfh_create_hoisted_block(orig: i32, hoist_target: i32, l: i32) -> i32 {
    let k = cfh_dest_find(orig);
    if k >= 0 { return cfh_dest[k].v; }
    let nm = block_name_plus(orig, ".licm");
    let nb = create_block_after(lc_fv, -1, "");
    set_name(nb, nm);
    cfh_dest.push(CfhPair { k: orig, v: nb });
    dt_add_new_block(lc_fv, DT_DOM, nb, hoist_target);
    let pl = loop_parent(l);
    if pl >= 0 { loop_add_basic_block_to_loop(pl, nb); }
    return nb;
}

// getOrCreateHoistedBlock(BB)
recursive fn cfh_get_or_create_hoisted_block(bb: i32, l: i32) -> i32 {
    if !cfh_on() { return loop_preheader(l); }
    let k = cfh_dest_find(bb);
    if k >= 0 { return cfh_dest[k].v; }
    var bi: i32 = -1;
    for pr in cfh_br {
        if bb != pr.v && (term_succ(pr.k, 0) == bb || term_succ(pr.k, 1) == bb) { bi = pr.k; break; }
    }
    let initial_ph = loop_preheader(l);
    if bi < 0 {
        cfh_dest.push(CfhPair { k: bb, v: initial_ph });
        return initial_ph;
    }
    let td = term_succ(bi, 0);
    let fd = term_succ(bi, 1);
    var common: i32 = -1;
    for pr in cfh_br { if pr.k == bi { common = pr.v; } }
    let hoist_target = cfh_get_or_create_hoisted_block(inst_parent(bi), l);
    let htd = cfh_create_hoisted_block(td, hoist_target, l);
    let hfd = cfh_create_hoisted_block(fd, hoist_target, l);
    let hcs = cfh_create_hoisted_block(common, hoist_target, l);
    if block_terminator(hcs) < 0 {
        let ts = lc_single_successor(hoist_target);
        if ts < 0 { fatal("internal: LICM: expected hoist target to have a single successor"); }
        block_move_before(hcs, ts);
        block_append_inst(hcs, create_inst(OP_BR, T_VOID, [ts]));
    }
    if block_terminator(htd) < 0 {
        block_move_before(htd, hcs);
        block_append_inst(htd, create_inst(OP_BR, T_VOID, [hcs]));
    }
    if block_terminator(hfd) < 0 {
        block_move_before(hfd, hcs);
        block_append_inst(hfd, create_inst(OP_BR, T_VOID, [hcs]));
    }
    if hoist_target == initial_ph {
        // InitialPreheader->replaceSuccessorsPhiUsesWith(HoistCommonSucc)
        let t = block_terminator(initial_ph);
        for j in term_nsucc(t) { block_replace_phi_uses_with(term_succ(t, j), initial_ph, hcs); }
        msu_wire_old_preds_to_new_pred(lc_single_successor(hoist_target), hcs, [hoist_target], true);
        dt_change_idom(lc_fv, DT_DOM, loop_header(l), hcs);
        for j in cfh_dest.len {
            if cfh_dest[j].v == initial_ph && cfh_dest[j].k != inst_parent(bi) { cfh_dest[j].v = hcs; }
        }
    }
    let old_t = block_terminator(hoist_target);
    let nbi = create_inst(OP_CONDBR, T_VOID, [op(bi, 0), htd, hfd]);
    m2r_insert_before_adopting(nbi, old_t);
    lc_erase_terminator(old_t);
    let prof = inst_get_md(bi, MDK_PROF);
    if prof >= 0 { inst_set_md(nbi, MDK_PROF, prof); }
    // NewBI->setDebugLoc(HoistTarget->getTerminator()->getDebugLoc()): the new branch is the terminator now
    if loop_preheader(l) < 0 { fatal("internal: LICM: hoisting blocks should not have destroyed the preheader"); }
    let r = cfh_dest_find(bb);
    return cfh_dest[r].v;
}

fn lc_erase_terminator(t: i32) {
    if dbgrecs.len > 0 { dbg_records_to_next(t); }
    inst_erase_from_parent(t);
}

// BasicBlock::getSingleSuccessor
fn lc_single_successor(bb: i32) -> i32 {
    let t = block_terminator(bb);
    if t < 0 || term_nsucc(t) != 1 { return -1; }
    return term_succ(t, 0);
}

// ---------------------------------------------------------------------------------------------
// hoistRegion

fn lc_hoist_region(l: i32, nest: bool) -> bool {
    cfh_dest.clear();
    cfh_br.clear();
    var hoisted: i32[>..<] = [];
    var wl: i32[>..<] = [];
    lc_loop_rpo(l, wl);
    var changed = false;
    let preheader = loop_preheader(l);
    for bb in wl {
        if !nest && lc_in_sub_loop(bb, l) { continue; }
        var i = block_first(bb);
        while i >= 0 {
            let nxt = inst_next(i);
            if lc_hoist_one(i, bb, l, preheader, hoisted) { changed = true; }
            i = nxt;
        }
    }
    if cfh_on() {
        var hoist_point: i32 = -1;
        var k = hoisted.len;
        while k > 0 {
            k--;
            let i = hoisted[k];
            var all = true;
            var u = vals[i].first_use;
            while u >= 0 { if !lc_dominates_use(i, u) { all = false; break; } u = uses[u].next; }
            if !all {
                let dom = dt_idom(DT_DOM, inst_parent(i));
                if hoist_point < 0 || !dt_dominates_block(DT_DOM, inst_parent(hoist_point), dom) {
                    hoist_point = block_terminator(dom);
                }
                lc_move_instruction_before(i, hoist_point, false);
                hoist_point = i;
                changed = true;
            }
        }
    }
    if flag_bool("verify-memoryssa", false) { mssa_verify(lc_fv); }
    return changed;
}

// DominatorTree::dominates(const Value *Def, const Use &U)
fn lc_dominates_use(def: i32, u: i32) -> bool {
    let user = uses[u].user;
    if !is_inst(user) { return true; }
    if iop(user) == OP_PHI {
        let k = (u - vals[user].ops) as i64;
        let ub = phi_block(user, k);
        // dominates(Def, BasicBlockEdge(UseBB, PHI block)) for a PHI use: dominates the end of the incoming block
        return dt_inst_dominates_block_end(def, ub);
    }
    return dt_value_dominates_inst(def, user);
}
// DominatorTree::dominates(Def, BasicBlock *UseBB) for the incoming edge end (isReachableFromEntry first)
fn dt_inst_dominates_block_end(def: i32, ub: i32) -> bool {
    if !dt_has_node(DT_DOM, ub) { return true; }
    let db = inst_parent(def);
    if !dt_has_node(DT_DOM, db) { return false; }
    if db == ub { return true; }
    return dt_dominates_block(DT_DOM, db, ub);
}

// one instruction of hoistRegion's loop; returns Changed
fn lc_hoist_one(i: i32, bb: i32, l: i32, preheader: i32, hoisted: i32[>..<]&) -> bool {
    if lc_invariant_operands(l, i) && lc_can_sink_or_hoist(i, l, true) &&
       lc_safe_to_execute_unconditionally(i, l, block_terminator(preheader)) {
        let dest = cfh_get_or_create_hoisted_block(bb, l);
        lc_hoist(i, l, dest);
        hoisted.push(i);
        return true;
    }
    let o = iop(i);
    if o == OP_FDIV && (insts[inst_of(i)].fmf & FMF_ARCP) != 0 && lc_invariant(l, op(i, 1)) {
        let divisor = op(i, 1);
        let one = c_fp_one_ty(vals[divisor].ty);
        let fmf = insts[inst_of(i)].fmf;
        let dl = inst_get_md(i, MDK_DBG_SC);
        let rd = create_inst(OP_FDIV, vals[divisor].ty, [one, divisor]);
        insts[inst_of(rd)].fmf = fmf;
        lsi_insert_instruction_to(rd, inst_parent(i));
        m2r_insert_before_adopting(rd, i);
        if dl >= 0 { inst_set_md(rd, MDK_DBG_SC, dl); }
        let prod = create_inst(OP_FMUL, vals[i].ty, [op(i, 0), rd]);
        insts[inst_of(prod)].fmf = fmf;
        lsi_insert_instruction_to(prod, inst_parent(i));
        inst_insert_after(prod, i);
        if dl >= 0 { inst_set_md(prod, MDK_DBG_SC, dl); }
        lc_rauw(i, prod);
        lc_erase(i);
        let dest = cfh_get_or_create_hoisted_block(bb, l);
        lc_hoist(rd, l, dest);
        hoisted.push(rd);
        return true;
    }
    let is_inv_start = vals[i].first_use < 0 && inst_iid(i) == IID_invariant_start;
    if (is_inv_start || ast_is_guard(i)) && lc_invariant_operands(l, i) &&
       lsi_guaranteed_to_execute(i, l) && lsi_no_write_before(i, l) {
        let dest = cfh_get_or_create_hoisted_block(bb, l);
        lc_hoist(i, l, dest);
        hoisted.push(i);
        return true;
    }
    if o == OP_PHI {
        if cfh_can_hoist_phi(i, l) {
            for k in phi_nincoming(i) {
                let nb = cfh_get_or_create_hoisted_block(phi_block(i, k), l);
                phi_set_block(i, k, nb);
            }
            let dest = cfh_get_or_create_hoisted_block(bb, l);
            lc_hoist(i, l, dest);
            return true;
        }
    }
    if lc_hoist_arithmetics(i, l) { return true; }
    if o == OP_CONDBR { cfh_register_branch(i, l); }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Legality

// isLoadInvariantInLoop(LI, DT, CurLoop)
fn lc_load_invariant_in_loop(li: i32, l: i32) -> bool {
    let addr = op(li, 0);
    let t = vals[li].ty;
    if ty_size_scalable(t) { return false; }
    let bits = dl_size_bits(t);
    if is_constant(addr) { return false; }
    let max_uses = flag_int("licm-max-num-uses-traversed", 8);
    var visited: i64 = 0;
    var u = vals[addr].first_use;
    while u >= 0 {
        let x = uses[u].user;
        u = uses[u].next;
        visited++;
        if visited > max_uses { return false; }
        if !is_inst(x) || inst_iid(x) != IID_invariant_start || vals[x].first_use >= 0 { continue; }
        let sz = op(x, 0);
        let ap = ci_ap(sz);
        if ap_is_neg(ap) { continue; }
        let sbits = ap_sext64(ap) * 8;
        if bits <= sbits && dt_properly_dominates_block(DT_DOM, inst_parent(x), loop_header(l)) { return true; }
    }
    return false;
}

// isHoistableAndSinkableInst
fn lc_hoistable_and_sinkable(i: i32) -> bool {
    let o = iop(i);
    return o == OP_LOAD || o == OP_STORE || o == OP_CALL || o == OP_FENCE || is_cast_op(o) || o == OP_FNEG ||
        is_binary_op(o) || o == OP_SELECT || o == OP_GEP || o == OP_ICMP || o == OP_FCMP ||
        o == OP_INSERTELEMENT || o == OP_EXTRACTELEMENT || o == OP_SHUFFLEVECTOR || o == OP_EXTRACTVALUE ||
        o == OP_INSERTVALUE || o == OP_FREEZE;
}

// isOnlyMemoryAccess(I, L, MSSAU)
fn lc_only_memory_access(i: i32, l: i32) -> bool {
    for k in loop_nblocks(l) {
        var a = mb_first(loop_block(l, k));
        var not_phi: i64 = 0;
        while a >= 0 {
            if macc[a].kind != MAK_PHI {
                if macc[a].inst != i { return false; }
                let was = not_phi;
                not_phi++;
                if was == 1 { return false; }
            }
            a = macc[a].next;
        }
    }
    return true;
}

// canHoistLoad
fn lc_can_hoist_load(li: i32, l: i32, target_once: bool) -> bool {
    if !ldst_is_unordered(li) { return false; }
    if !mr_is_mod(aa_mod_ref_mask_simple(ml_before_or_after(op(li, 0)), false)) { return true; }
    if inst_get_md(li, MDK_INVARIANT_LOAD) >= 0 { return true; }
    if insts[inst_of(li)].ord != 0 && !target_once { return false; }
    if lc_load_invariant_in_loop(li, l) { return true; }
    let mu = mssa_access_of(li);
    if mu < 0 || macc[mu].kind != MAK_USE { fatal("internal: LICM: a hoisted load has no MemoryUse"); }
    let inv_group = inst_get_md(li, MDK_INVARIANT_GROUP) >= 0;
    return !lc_pointer_invalidated_by_loop(mu, l, li, inv_group);
}

// canSinkOrHoistInst(I, AA, DT, CurLoop, MSSAU, TargetExecutesOncePerLoop, Flags, ORE)
fn lc_can_sink_or_hoist(i: i32, l: i32, target_once: bool) -> bool {
    if !lc_hoistable_and_sinkable(i) { return false; }
    let o = iop(i);
    if o == OP_LOAD { return lc_can_hoist_load(i, l, target_once); }
    if o == OP_CALL {
        if inst_may_throw(i) { return false; }
        if call_has_fn_attr(i, AK_Convergent) { return false; }
        if func_has_fn_attr(inst_func(i), AK_PresplitCoroutine) { return false; }
        if inst_iid(i) == IID_assume { return true; }
        let me = aa_call_me_simple(i);
        let mr = me_modref(me);
        if mr == MR_NO { return true; }
        if !mr_is_mod(mr) {
            let mu = mssa_access_of(i);
            if mu < 0 || macc[mu].kind != MAK_USE { return false; }
            return !lc_pointer_invalidated_by_loop(mu, l, i, false);
        }
        if !mr_is_ref(mr) { return lc_no_conflicting_read_writes(i, l); }
        return false;
    }
    if o == OP_FENCE { return lc_only_memory_access(i, l); }
    if o == OP_STORE {
        if !ldst_is_unordered(i) { return false; }
        if lc_only_memory_access(i, l) { return true; }
        return lc_no_conflicting_read_writes(i, l);
    }
    return true;
}

// noConflictingReadWrites(I, MSSA, AA, CurLoop, Flags)
fn lc_no_conflicting_read_writes(i: i32, l: i32) -> bool {
    if lc_too_many_acc { return false; }
    let imd = mssa_access_of(i);
    let q = aq_push(CA_SIMPLE);
    let src = lc_clobbering(imd, q);
    if !mssa_is_live(src) && loop_contains(l, macc[src].bb) { aq_pop(q); return false; }
    for k in loop_nblocks(l) {
        var a = mb_first(loop_block(l, k));
        while a >= 0 {
            if !lc_is_sink && mssa_dominates(imd, a) { break; }
            if macc[a].kind != MAK_PHI {
                if aa_inst_inst_mr(macc[a].inst, i, q) != MR_NO { aq_pop(q); return false; }
            }
            a = macc[a].next;
        }
    }
    aq_pop(q);
    return true;
}

// pointerInvalidatedByLoop(MSSA, MU, CurLoop, I, Flags, InvariantGroup)
fn lc_pointer_invalidated_by_loop(mu: i32, l: i32, i: i32, inv_group: bool) -> bool {
    if !lc_is_sink {
        let q = aq_push(CA_SIMPLE);
        let src = lc_clobbering(mu, q);
        aq_pop(q);
        return !mssa_is_live(src) && loop_contains(l, macc[src].bb) &&
            !(inv_group && macc[src].bb == loop_header(l) && macc[src].kind == MAK_PHI);
    }
    if lc_too_many_acc { return true; }
    for k in loop_nblocks(l) { if lc_pointer_invalidated_by_block(loop_block(l, k), mu) { return true; } }
    if !lc_contains_inst(l, i) { return lc_pointer_invalidated_by_block(inst_parent(i), mu); }
    return false;
}

// pointerInvalidatedByBlock(BB, MSSA, MU)
fn lc_pointer_invalidated_by_block(bb: i32, mu: i32) -> bool {
    var d = mb_dfirst(bb);
    while d >= 0 {
        if macc[d].kind == MAK_DEF {
            if macc[mu].bb != macc[d].bb || !mssa_locally_dominates(d, mu) { return true; }
        }
        d = macc[d].dnext;
    }
    return false;
}

// isFoldableInLoop(I, CurLoop, TTI)
fn lc_foldable_in_loop(i: i32, l: i32) -> bool {
    if iop(i) != OP_GEP { return false; }
    if tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) != TCC_FREE { return false; }
    let bb = inst_parent(i);
    var u = vals[i].first_use;
    while u >= 0 {
        let ui = uses[u].user;
        u = uses[u].next;
        if lc_contains_inst(l, ui) && (bb != inst_parent(ui) || (iop(ui) != OP_STORE && iop(ui) != OP_LOAD)) { return false; }
    }
    return true;
}

// Value::hasOneUser
fn lc_has_one_user(v: i32) -> bool {
    let u = vals[v].first_use;
    if u < 0 { return false; }
    let x = uses[u].user;
    var w = uses[u].next;
    while w >= 0 { if uses[w].user != x { return false; } w = uses[w].next; }
    return true;
}

// isNotUsedOrFoldableInLoop(I, CurLoop, SafetyInfo, TTI, FoldableInLoop, LoopNestMode): (result, FoldableInLoop)
fn lc_not_used_or_foldable(i: i32, l: i32, nest: bool) -> bool, bool {
    var foldable_in_loop = false;
    let is_foldable = lc_foldable_in_loop(i, l);
    var u = vals[i].first_use;
    while u >= 0 {
        var ui = uses[u].user;
        u = uses[u].next;
        if iop(ui) == OP_PHI {
            let bb = inst_parent(ui);
            if iop(block_terminator(bb)) == OP_CATCHSWITCH { return false, foldable_in_loop; }
            if nest {
                while iop(ui) == OP_PHI && lc_has_one_user(ui) && nops(ui) == 1 {
                    if !lc_contains_inst(l, ui) { break; }
                    ui = uses[vals[ui].first_use].user;
                }
            }
        }
        if lc_contains_inst(l, ui) {
            if is_foldable { foldable_in_loop = true; continue; }
            return false, foldable_in_loop;
        }
    }
    return true, foldable_in_loop;
}

// isSafeToExecuteUnconditionally(Inst, DT, TLI, CurLoop, SafetyInfo, ORE, CtxI, AC, AllowSpeculation)
fn lc_safe_to_execute_unconditionally(i: i32, l: i32, cxt: i32) -> bool {
    if lc_allow_spec && spec_safe_dt_tli(i, cxt, true) { return true; }
    return lsi_guaranteed_to_execute(i, l);
}

// ---------------------------------------------------------------------------------------------
// Sinking

// isTriviallyReplaceablePHI(PN, I)
fn lc_trivially_replaceable_phi(pn: i32, i: i32) -> bool {
    for k in phi_nincoming(pn) { if phi_value(pn, k) != i { return false; } }
    return true;
}

// canSplitPredecessors(PN, SafetyInfo)
fn lc_can_split_predecessors(pn: i32) -> bool {
    let bb = inst_parent(pn);
    let fnp = first_non_phi(bb);
    if !(fnp >= 0 && iop(fnp) == OP_LANDINGPAD) && fnp >= 0 && inst_is_eh_pad(fnp) { return false; }
    var ok = true;
    each_pred(bb) { p => if iop(block_terminator(p)) == OP_INDIRECTBR { ok = false; } };
    return ok;
}

// splitPredecessorsOfLoopExit(PN, DT, LI, CurLoop, SafetyInfo, MSSAU): a lazy DomTreeUpdater, flushed by
// SplitBlockPredecessors (UpdateAnalysisInformation asks for the tree because LoopInfo is passed)
fn lc_split_predecessors_of_loop_exit(pn: i32) {
    let exit = inst_parent(pn);
    var preds: i32[>..<] = [];
    each_pred(exit) { p => if position(preds, p) < 0 { preds.push(p); } };
    for p in preds {
        if phi_block_index(pn, p) >= 0 {
            ls_mssau = true;
            ls_split_dtu = true;
            split_block_predecessors(exit, [p], ".split.loop.exit", true, true, true);
            ls_mssau = false;
            ls_split_dtu = false;
        }
    }
}

// cloneInstructionInExitBlock(I, ExitBlock, PN, LI, SafetyInfo, MSSAU)
fn lc_clone_in_exit_block(i: i32, exit: i32, pn: i32) -> i32 {
    if is_callbase(i) {
        for k in cb_nbundles(i) { if sbytes(cb_bundle_tag(i, k)) == "funclet" { lc_not_ported("sinking calls with funclet bundles"); } }
    }
    let nw = inst_clone(i);
    let ip = lc_first_insertion_pt(exit);
    if ip >= 0 { inst_insert_before(nw, ip); } else { block_append_inst(exit, nw); }
    if vals[i].name >= 0 {
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        nm.append(".le");
        set_name(nw, nm);
    }
    if mssa_access_of(i) >= 0 {
        let na = msu_create_access_in_bb(nw, -1, inst_parent(nw), MSP_BEGINNING, false);
        if na >= 0 {
            if macc[na].kind == MAK_DEF { msu_insert_def(na, true); } else { msu_insert_use(na, true); }
        }
    }
    for k in nops(nw) {
        let o = op(nw, k);
        if lc_would_need_lcssa(o, inst_parent(pn)) {
            let np = new_phi(vals[o].ty, phi_nincoming(pn));
            let fi = block_first(exit);
            inst_insert_before(np, fi);
            var nm: u8[>..] = [];
            nm.append(val_name(o));
            nm.append(".lcssa");
            set_name(np, nm);
            for j in phi_nincoming(pn) { phi_add_incoming(np, o, phi_block(pn, j)); }
            set_op(nw, k, np);
        }
    }
    return nw;
}

// sink(I, LI, DT, CurLoop, SafetyInfo, MSSAU, ORE)
fn lc_sink(i: i32, l: i32) -> bool {
    var changed = false;
    var visited: i32[>..<] = [];
    var u = vals[i].first_use;
    while u >= 0 {
        let user = uses[u].user;
        let cu = u;
        u = uses[u].next;
        if position(visited, user) >= 0 || lc_contains_inst(l, user) { continue; }
        if !dt_has_node(DT_DOM, inst_parent(user)) {
            let k = (cu - vals[user].ops) as i64;
            set_op(user, k, c_poison(vals[i].ty));
            changed = true;
            continue;
        }
        if iop(user) != OP_PHI { fatal("internal: LICM: an out-of-loop user that is not a PHI"); }
        let k = (cu - vals[user].ops) as i64;
        let bb = phi_block(user, k);
        if !dt_has_node(DT_DOM, bb) {
            set_op(user, k, c_poison(vals[i].ty));
            changed = true;
            continue;
        }
        visited.push(user);
        if lc_trivially_replaceable_phi(user, i) { continue; }
        if !lc_can_split_predecessors(user) { return changed; }
        lc_split_predecessors_of_loop_exit(user);
        u = vals[i].first_use;
    }
    if visited.len == 0 { return changed; }
    // SmallSetVector<User *> Users(I.users())
    var users: i32[>..<] = [];
    var w = vals[i].first_use;
    while w >= 0 { let x = uses[w].user; if position(users, x) < 0 { users.push(x); } w = uses[w].next; }
    var sunk_bb: i32[>..<] = [];
    var sunk_inst: i32[>..<] = [];
    for x in users {
        if lc_contains_inst(l, x) { continue; }
        let pn = x;
        let exit = inst_parent(pn);
        var nw: i32 = -1;
        let sk = position(sunk_bb, exit);
        if sk >= 0 { nw = sunk_inst[sk]; }
        else {
            nw = lc_clone_in_exit_block(i, exit, pn);
            sunk_bb.push(exit);
            sunk_inst.push(nw);
        }
        lc_drop_location(nw);
        lc_rauw(pn, nw);
        lc_erase(pn);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Hoisting

// moveInstructionBefore(I, Dest, SafetyInfo, MSSAU, SE)
fn lc_move_instruction_before(i: i32, dest: i32, head: bool) {
    lsi_remove_instruction(i);
    let db = inst_parent(dest);
    lsi_insert_instruction_to(i, db);
    lc_move_before(i, dest, head);
    let a = mssa_access_of(i);
    if a >= 0 { msu_move_to_place(a, db, MSP_BEFORE_TERMINATOR); }
    sc_forget_block_and_loop_dispositions(i);
}

// Instruction::hasMetadataOtherThanDebugLoc
fn lc_has_md_other_than_dbg(i: i32) -> bool {
    let ii = inst_of(i);
    for k in insts[ii].nmd { if md_att[insts[ii].md + 2 * k] != MDK_DBG_SC { return true; } }
    return false;
}

// hoist(I, DT, CurLoop, Dest, SafetyInfo, MSSAU, SE, ORE)
fn lc_hoist(i: i32, l: i32, dest: i32) {
    if (lc_has_md_other_than_dbg(i) || iop(i) == OP_CALL) && !lsi_guaranteed_to_execute(i, l) {
        cu_drop_ub_implying_attrs_and_metadata(i);
    }
    if iop(i) == OP_PHI { lc_move_instruction_before(i, lc_first_non_phi(dest), true); }
    else { lc_move_instruction_before(i, block_terminator(dest), false); }
    lc_drop_location(i);
}

// ---------------------------------------------------------------------------------------------
// Promotion

// collectPromotionCandidates results: runs of pointers in lc_cand_ptrs
var lc_cand_at: i32[>..<];
var lc_cand_n: i32[>..<];
var lc_cand_reads: bool[>..<];
var lc_cand_ptrs: i32[>..<];

// IsPotentiallyPromotable
fn lc_potentially_promotable(i: i32, l: i32) -> bool {
    let o = iop(i);
    if o == OP_STORE { let p = op(i, 1); return !is_constant_data(p) && lc_invariant(l, p); }
    if o == OP_LOAD { let p = op(i, 0); return !is_constant_data(p) && lc_invariant(l, p); }
    return false;
}

// collectPromotionCandidates(MSSA, AA, L)
fn lc_collect_promotion_candidates(l: i32) {
    lc_cand_at.clear();
    lc_cand_n.clear();
    lc_cand_reads.clear();
    lc_cand_ptrs.clear();
    let q = aq_push(CA_SIMPLE);
    ast_reset(q);
    vs_clear(VS_PASS0);       // AttemptingPromotion
    for k in loop_nblocks(l) {
        var a = mb_first(loop_block(l, k));
        while a >= 0 {
            if macc[a].kind != MAK_PHI {
                let i = macc[a].inst;
                if lc_potentially_promotable(i, l) { vs_add(VS_PASS0, i); ast_add_inst(i); }
            }
            a = macc[a].next;
        }
    }
    var sets: i32[>..<] = [];
    var reads: bool[>..<] = [];
    for k in ast_nsets() {
        let s = k as i32;
        if !ast_set_live(s) { continue; }
        if !ast_is_forwarding(s) && ast_is_mod(s) && ast_is_must_alias(s) { sets.push(s); reads.push(false); }
    }
    if sets.len == 0 { aq_pop(q); return; }
    for k in loop_nblocks(l) {
        var a = mb_first(loop_block(l, k));
        while a >= 0 {
            if macc[a].kind != MAK_PHI {
                let i = macc[a].inst;
                if !vs_has(VS_PASS0, i) {
                    var w: i64 = 0;
                    for j in sets.len {
                        let s = sets[j];
                        let mr = ast_aliases_unknown_inst(s, i);
                        var erase = false;
                        var rd = reads[j];
                        if mr_is_mod(mr) { erase = true; }
                        else if mr_is_ref(mr) { rd = true; erase = !ast_is_ref(s); }
                        if !erase { sets[w] = s; reads[w] = rd; w++; }
                    }
                    sets.resize(w);
                    reads.resize(w);
                }
            }
            a = macc[a].next;
        }
    }
    for j in sets.len {
        let s = sets[j];
        lc_cand_at.push(lc_cand_ptrs.len as i32);
        let mark = lc_cand_ptrs.len;
        for m in ast_nml(s) {
            let p = ast_ml(s, m).ptr;
            var dup = false;
            for x in mark..lc_cand_ptrs.len { if lc_cand_ptrs[x] == p { dup = true; } }
            if !dup { lc_cand_ptrs.push(p); }
        }
        lc_cand_n.push((lc_cand_ptrs.len - mark) as i32);
        lc_cand_reads.push(reads[j]);
    }
    aq_pop(q);
}

// isNotCapturedBeforeOrInLoop(V, L, DT)
fn lc_not_captured_before_or_in_loop(v: i32, l: i32) -> bool {
    let c = ct_may_be_captured_before(v, true, block_terminator(loop_header(l)), false, CC_PROVENANCE, CT_STOP_ANY, false);
    return cc_nothing(c);
}
// isNotVisibleOnUnwindInLoop(Object, L, DT)
fn lc_not_visible_on_unwind_in_loop(obj: i32, l: i32) -> bool {
    let r, req = aa_is_not_visible_on_unwind(obj);
    if !r { return false; }
    return !req || lc_not_captured_before_or_in_loop(obj, l);
}
// isThreadLocalObject(Object, L, DT, TTI): X86TTI / NoTTI isSingleThreaded() is false
fn lc_thread_local_object(obj: i32, l: i32) -> bool {
    return (aa_is_identified_function_local(obj) && lc_not_captured_before_or_in_loop(obj, l)) ||
        flag_bool("licm-force-thread-model-single", false);
}

// AAMDNodes (as an ML's tag fields)
fn lc_aa_any(t: ML) -> bool { t.tbaa >= 0 || t.tbaa_struct >= 0 || t.scope >= 0 || t.noalias >= 0 || t.noalias_as >= 0 }
// AAMDNodes::merge
fn lc_aa_merge(a: ML, b: ML) -> ML {
    var r = ml_null();
    r.tbaa = tb_most_generic_tbaa(a.tbaa, b.tbaa);
    r.tbaa_struct = -1;
    r.scope = cu_most_generic_alias_scope(a.scope, b.scope);
    r.noalias = cu_md_intersect(a.noalias, b.noalias);
    r.noalias_as = cu_most_generic_noalias_addrspace(a.noalias_as, b.noalias_as);
    return r;
}
// Instruction::setAAMetadata
fn lc_set_aa_metadata(i: i32, t: ML) {
    cu_set_md(i, md_kind_id("tbaa"), t.tbaa);
    cu_set_md(i, md_kind_id("tbaa.struct"), t.tbaa_struct);
    cu_set_md(i, md_kind_id("alias.scope"), t.scope);
    cu_set_md(i, md_kind_id("noalias"), t.noalias);
    cu_set_md(i, md_kind_id("noalias.addrspace"), t.noalias_as);
}

// getLoadStoreType
fn lc_load_store_type(i: i32) -> i32 { if iop(i) == OP_LOAD { vals[i].ty } else { vals[op(i, 0)].ty } }
fn lc_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { (1 as i64) << ((a - 1) as i64) }; }
fn lc_set_align(i: i32, al: i64) {
    var lg: u8 = 0;
    var x = al;
    while x > 1 { x = x >> 1; lg++; }
    insts[inst_of(i)].align = lg + 1;
}

// LoopPromoter::maybeInsertLCSSAPHI(V, BB)
fn lc_maybe_insert_lcssa_phi(v: i32, bb: i32) -> i32 {
    if !lc_would_need_lcssa(v, bb) { return v; }
    var preds: i32[>..<] = [];
    each_pred(bb) { p => preds.push(p); };
    let pn = new_phi(vals[v].ty, preds.len);
    inst_insert_before(pn, block_first(bb));
    var nm: u8[>..] = [];
    nm.append(val_name(v));
    nm.append(".lcssa");
    set_name(pn, nm);
    for p in preds { phi_add_incoming(pn, v, p); }
    return pn;
}

// promoteLoopAccessesToScalars(PointerMustAliases, ExitBlocks, InsertPts, MSSAInsertPts, PIC, LI, DT, AC, TLI,
// TTI, CurLoop, MSSAU, SafetyInfo, ORE, AllowSpeculation, HasReadsOutsideSet)
fn lc_promote(ptrs: const i32[:], exits: const i32[:], ins_pts: const i32[:], mssa_ins: i32[>..<]&, l: i32,
              has_reads_outside: bool) -> bool {
    let some_ptr = ptrs[0];
    let preheader = loop_preheader(l);
    var deref_in_ph = false;
    var store_guaranteed = false;
    var load_guaranteed = false;
    var found_load = false;
    // 0 = StoreSafe, 1 = StoreUnsafe, 2 = StoreSafetyUnknown
    var store_safety: i64 = 2;
    var loop_uses: i32[>..<] = [];
    var alignment: i64 = 1;
    var saw_unordered_atomic = false;
    var saw_not_atomic = false;
    var tags = ml_null();
    if has_reads_outside { store_safety = 1; }
    if store_safety == 2 && lsi_any_block_may_throw() {
        let obj = get_underlying_object(some_ptr, 10);
        if !lc_not_visible_on_unwind_in_loop(obj, l) { store_safety = 1; }
    }
    var access_ty: i32 = -1;
    for asiv in ptrs {
        var u = vals[asiv].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            let cu = u;
            u = uses[u].next;
            if !is_inst(ui) || !lc_contains_inst(l, ui) { continue; }
            let o = iop(ui);
            if o == OP_LOAD {
                if !ldst_is_unordered(ui) { return false; }
                let atomic = insts[inst_of(ui)].ord != 0;
                if atomic { saw_unordered_atomic = true; } else { saw_not_atomic = true; }
                found_load = true;
                let ia = lc_align(ui);
                if !load_guaranteed { load_guaranteed = lsi_guaranteed_to_execute(ui, l); }
                if !deref_in_ph || ia > alignment {
                    if lc_safe_to_execute_unconditionally(ui, l, block_terminator(preheader)) {
                        deref_in_ph = true;
                        alignment = max(alignment, ia);
                    }
                }
            } else if o == OP_STORE {
                if (cu - vals[ui].ops) != 1 { continue; }
                if !ldst_is_unordered(ui) { return false; }
                let atomic = insts[inst_of(ui)].ord != 0;
                if atomic { saw_unordered_atomic = true; } else { saw_not_atomic = true; }
                let ia = lc_align(ui);
                let g = lsi_guaranteed_to_execute(ui, l);
                if g { store_guaranteed = true; }
                if g {
                    deref_in_ph = true;
                    if store_safety == 2 { store_safety = 0; }
                    alignment = max(alignment, ia);
                }
                if store_safety == 2 {
                    var all = true;
                    for e in exits { if !dt_dominates_block(DT_DOM, inst_parent(ui), e) { all = false; break; } }
                    if all { store_safety = 0; }
                }
                if !deref_in_ph {
                    deref_in_ph = spec_deref_aligned_ty_sq(op(ui, 1), vals[op(ui, 0)].ty, lc_align(ui), block_terminator(preheader));
                }
            } else {
                continue;
            }
            let lt = lc_load_store_type(ui);
            if access_ty < 0 { access_ty = lt; } else if access_ty != lt { return false; }
            if loop_uses.len == 0 { tags = ml_aa_tags(ui); }
            else if lc_aa_any(tags) { tags = lc_aa_merge(tags, ml_aa_tags(ui)); }
            loop_uses.push(ui);
        }
    }
    if saw_unordered_atomic && saw_not_atomic { return false; }
    if saw_unordered_atomic && alignment < dl_store_size(access_ty) { return false; }
    if !deref_in_ph { return false; }
    if store_safety == 2 {
        let obj = get_underlying_object(some_ptr, 10);
        let w, explicit_only = aa_is_writable_object(obj);
        if w && (!explicit_only || spec_deref_pointer_ignore_free(some_ptr, access_ty)) && lc_thread_local_object(obj, l) {
            store_safety = 0;
        }
    }
    if store_safety != 0 && !found_load { return false; }
    // DebugLoc::getMergedLocations of the loop uses
    var dl: i32 = -1;
    if loop_uses.len > 0 {
        dl = inst_get_md(loop_uses[0], MDK_DBG_SC);
        for k in 1..loop_uses.len {
            if dl < 0 { break; }
            dl = m2r_merged_location(dl, inst_get_md(loop_uses[k], MDK_DBG_SC));
        }
    }
    let can_insert_stores = store_safety == 0;
    // LoadAndStorePromoter(Insts, SSA, BaseName = ""): SSA.Initialize(SomeVal->getType(), SomeVal->getName())
    let some_val = if iop(loop_uses[0]) == OP_LOAD { loop_uses[0] } else { op(loop_uses[0], 0) };
    var bname: u8[>..] = [];
    bname.append(val_name(some_val));
    ssa_init(vals[some_val].ty, bname);
    var ph_load: i32 = -1;
    if found_load || !store_guaranteed {
        let ld = create_inst(OP_LOAD, access_ty, [some_ptr]);
        m2r_insert_before_adopting(ld, block_terminator(preheader));
        var nm: u8[>..] = [];
        nm.append(val_name(some_ptr));
        nm.append(".promoted");
        set_name(ld, nm);
        if saw_unordered_atomic { insts[inst_of(ld)].ord = 1; }
        lc_set_align(ld, alignment);
        if lc_aa_any(tags) && load_guaranteed { lc_set_aa_metadata(ld, tags); }
        let a = msu_create_access_in_bb(ld, -1, inst_parent(ld), MSP_END, true);
        msu_insert_use(a, true);
        ssa_add_available_value(preheader, ld);
        ph_load = ld;
    } else {
        ssa_add_available_value(preheader, c_poison(access_ty));
    }
    if flag_bool("verify-memoryssa", false) { mssa_verify(lc_fv); }
    let st_tags = if store_guaranteed { tags } else { ml_null() };
    lc_promoter_run(loop_uses, some_ptr, exits, ins_pts, mssa_ins, dl, alignment, saw_unordered_atomic, st_tags, can_insert_stores);
    if flag_bool("verify-memoryssa", false) { mssa_verify(lc_fv); }
    if ph_load >= 0 && vals[ph_load].first_use < 0 { lc_erase(ph_load); }
    return true;
}

// LoadAndStorePromoter::run(Insts) with LoopPromoter's hooks
fn lc_promoter_run(insts_: const i32[:], some_ptr: i32, exits: const i32[:], ins_pts: const i32[:], mssa_ins: i32[>..<]&,
                   dl: i32, alignment: i64, unordered_atomic: bool, tags: ML, can_insert_stores: bool) {
    // UsesByBlock: per block, the users in Insts order
    var blocks_: i32[>..<] = [];
    var done: bool[>..<] = [];
    for x in insts_ { let b = inst_parent(x); if position(blocks_, b) < 0 { blocks_.push(b); done.push(false); } }
    var live_in: i32[>..<] = [];
    var repl_from: i32[>..<] = [];   // ReplacedLoads
    var repl_to: i32[>..<] = [];
    var buses: i32[>..<] = [];
    for user in insts_ {
        let bb = inst_parent(user);
        let bk = position(blocks_, bb);
        if done[bk] { continue; }
        done[bk] = true;
        buses.clear();
        for x in insts_ { if inst_parent(x) == bb { buses.push(x); } }
        if buses.len == 1 {
            if iop(user) == OP_STORE { ssa_add_available_value(bb, op(user, 0)); }
            else { live_in.push(user); }
            continue;
        }
        var has_store = false;
        for x in buses { if iop(x) == OP_STORE { has_store = true; } }
        if !has_store {
            for x in buses { live_in.push(x); }
            continue;
        }
        // sort by comesBefore: the block order
        var sorted: i32[>..<] = [];
        var j = block_first(bb);
        while j >= 0 { if position(buses, j) >= 0 { sorted.push(j); } j = inst_next(j); }
        var stored: i32 = -1;
        for x in sorted {
            if iop(x) == OP_LOAD {
                if stored >= 0 {
                    lc_rauw(x, stored);
                    repl_from.push(x);
                    repl_to.push(stored);
                } else {
                    live_in.push(x);
                }
                continue;
            }
            stored = op(x, 0);
        }
        ssa_add_available_value(bb, stored);
    }
    for ld in live_in {
        var nv = ssa_get_value_in_middle_of_block(inst_parent(ld));
        if nv == ld { nv = c_poison(vals[nv].ty); }
        lc_rauw(ld, nv);
        repl_from.push(ld);
        repl_to.push(nv);
    }
    if can_insert_stores { lc_insert_stores_in_exits(insts_, some_ptr, exits, ins_pts, mssa_ins, dl, alignment, unordered_atomic, tags); }
    for user in insts_ {
        if iop(user) == OP_STORE && !can_insert_stores { continue; }
        if vals[user].first_use >= 0 {
            var k = position(repl_from, user);
            if k < 0 { fatal("internal: LoadAndStorePromoter: not a replaced load"); }
            var nv = repl_to[k];
            loop {
                let k2 = position(repl_from, nv);
                if k2 < 0 { break; }
                nv = repl_to[k2];
            }
            lc_rauw(user, nv);
        }
        // instructionDeleted
        lsi_remove_instruction(user);
        msu_remove_inst_access(user, false);
        m2r_erase(user);
    }
}

// LoopPromoter::insertStoresInLoopExitBlocks
fn lc_insert_stores_in_exits(uses_: const i32[:], some_ptr: i32, exits: const i32[:], ins_pts: const i32[:], mssa_ins: i32[>..<]&,
                             dl: i32, alignment: i64, unordered_atomic: bool, tags: ML) {
    let assign_id = md_kind_id("DIAssignID");
    for x in uses_ { if inst_get_md(x, assign_id) >= 0 { lc_not_ported("mergeDIAssignID of promoted stores"); } }
    for i in exits.len {
        let exit = exits[i];
        var live = ssa_get_value_in_middle_of_block(exit);
        live = lc_maybe_insert_lcssa_phi(live, exit);
        let p = lc_maybe_insert_lcssa_phi(some_ptr, exit);
        let si = create_inst(OP_STORE, T_VOID, [live, p]);
        let pos = ins_pts[i];
        if pos >= 0 { inst_insert_before(si, pos); } else { block_append_inst(exit, si); }
        if unordered_atomic { insts[inst_of(si)].ord = 1; }
        lc_set_align(si, alignment);
        if dl >= 0 { inst_set_md(si, MDK_DBG_SC, dl); }
        if lc_aa_any(tags) { lc_set_aa_metadata(si, tags); }
        var na: i32 = -1;
        if mssa_ins[i] < 0 { na = msu_create_access_in_bb(si, -1, inst_parent(si), MSP_BEGINNING, true); }
        else { na = msu_create_access_after(si, -1, mssa_ins[i]); }
        mssa_ins[i] = na;
        msu_insert_def(na, true);
    }
}

// ---------------------------------------------------------------------------------------------
// hoistArithmetics

// ICmpInst::isRelational
fn lc_is_relational(p: i64) -> bool { p >= 34 && p <= 41 }
fn lc_is_signed(p: i64) -> bool { p >= 38 && p <= 41 }
fn lc_is_lt_or_le(p: i64) -> bool { p == 36 || p == 37 || p == 40 || p == 41 }
fn lc_swapped(p: i64) -> i64 { lsi_swapped_pred(p) }
fn lc_inverse(p: i64) -> i64 { cmp_inverse_pred(p) }
fn lc_flipped_signedness(p: i64) -> i64 {
    if p >= 38 && p <= 41 { return p - 4; }
    if p >= 34 && p <= 37 { return p + 4; }
    return p;
}
fn lc_samesign(i: i32) -> bool { (insts[inst_of(i)].flags & FL_SAMESIGN) != 0 }

// MatchICmpAgainstInvariant (hoistMinMax): (ok, P, LHS, RHS); P loses samesign when swapped or inverted
fn lc_match_icmp_against_invariant(c: i32, l: i32, inverse: bool) -> bool, i64, bool, i32, i32 {
    if !is_inst_op(c, OP_ICMP) || !one_use_v(c) { return false, 0, false, -1, -1; }
    var p = insts[inst_of(c)].pred as i64;
    var ss = lc_samesign(c);
    var lhs = op(c, 0);
    var rhs = op(c, 1);
    if !ty_is_int(vals[lhs].ty) { return false, 0, false, -1, -1; }
    if !lc_is_relational(p) { return false, 0, false, -1, -1; }
    if lc_invariant(l, lhs) {
        let t = lhs; lhs = rhs; rhs = t;
        p = lc_swapped(p);
        ss = false;
    }
    if lc_invariant(l, lhs) || !lc_invariant(l, rhs) { return false, 0, false, -1, -1; }
    if inverse { p = lc_inverse(p); ss = false; }
    return true, p, ss, lhs, rhs;
}

// m_OneUse for a Value (ConstantData has no uses)
fn one_use_v(v: i32) -> bool { if is_constant_data(v) { return false; } let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }

// hoistMinMax(I, L, SafetyInfo, MSSAU)
fn lc_hoist_min_max(i: i32, l: i32) -> bool {
    var inverse = false;
    var c1: i32 = -1;
    var c2: i32 = -1;
    if m_logical(i, false) { c1 = lg_a; c2 = lg_b; inverse = true; }
    else if m_logical(i, true) { c1 = lg_a; c2 = lg_b; }
    else { return false; }
    let ok1, p1, s1, lhs1, rhs1 = lc_match_icmp_against_invariant(c1, l, inverse);
    if !ok1 { return false; }
    let ok2, p2, s2, lhs2, rhs2 = lc_match_icmp_against_invariant(c2, l, inverse);
    if !ok2 { return false; }
    // CmpPredicate::getMatching(P1, P2)
    var mp: i64 = -1;
    if p1 == p2 { mp = p1; }
    else if s1 && p1 == lc_flipped_signedness(p2) { mp = p2; }
    else if s2 && p2 == lc_flipped_signedness(p1) { mp = p1; }
    if mp < 0 || lhs1 != lhs2 { return false; }
    let use_min = lc_is_lt_or_le(mp);
    let signed = lc_is_signed(mp);
    let id = if signed { if use_min { IID_smin } else { IID_smax } } else { if use_min { IID_umin } else { IID_umax } };
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    var r2 = rhs2;
    if iop(i) == OP_SELECT {
        var nm: u8[>..] = [];
        nm.append(val_name(rhs2));
        nm.append(".fr");
        r2 = lb_freeze(rhs2, nm);
    }
    var nm2: u8[>..] = [];
    nm2.append("invariant.");
    nm2.append(if signed { "s" } else { "u" });
    nm2.append(if use_min { "min" } else { "max" });
    let new_rhs = lb_binary_intrinsic(id as i64, rhs1, r2, nm2);
    lb_set(i);
    var p = mp;
    if inverse { p = lc_inverse(p); }
    let nc = lb_icmp(p, lhs1, new_rhs, "");
    // NewCond->takeName(&I)
    lc_take_name(nc, i);
    lc_rauw(i, nc);
    lc_erase(i);
    salvage_debug_info(c1);
    salvage_debug_info(c2);
    lc_erase(c1);
    lc_erase(c2);
    return true;
}

// Value::takeName
fn lc_take_name(dst: i32, src: i32) {
    if vals[src].name < 0 || !is_inst(dst) { return; }
    var nm: u8[>..] = [];
    nm.append(val_name(src));
    set_name(src, "");
    set_name(dst, nm);
}

// GEPOperator::hasAllConstantIndices
fn lc_gep_all_constant_indices(g: i32) -> bool {
    for k in 1..nops(g) { if !is_cint_any(op(g, k)) { return false; } }
    return true;
}
fn is_cint_any(v: i32) -> bool { vals[v].kind == VK_CINT }

fn lc_known_nonneg(v: i32, cx: i32) -> bool {
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    sq_no_dt = false; sq_no_ac = false; sq_no_tli = true;
    kb_cxt = cx;
    let k = kb_compute_all(v, 0);
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return kb_is_nonneg(k);
}

// hoistGEP(I, L, SafetyInfo, MSSAU, AC, DT)
fn lc_hoist_gep(i: i32, l: i32) -> bool {
    if iop(i) != OP_GEP { return false; }
    let gep = i;
    if lc_gep_all_constant_indices(gep) { return false; }
    let src = op(gep, 0);
    if !is_inst_op(src, OP_GEP) || !one_use_v(src) || !lc_contains_inst(l, src) { return false; }
    let src_ptr = op(src, 0);
    if !lc_invariant(l, src_ptr) { return false; }
    for k in 1..nops(gep) { if !lc_invariant(l, op(gep, k)) { return false; } }
    var all_src_inv = true;
    for k in 1..nops(src) { if !lc_invariant(l, op(src, k)) { all_src_inv = false; } }
    if all_src_inv { return false; }
    var inb = (insts[inst_of(src)].flags & GEP_INBOUNDS) != 0 && (insts[inst_of(gep)].flags & GEP_INBOUNDS) != 0;
    if inb { for k in 1..nops(src) { if !lc_known_nonneg(op(src, k), gep) { inb = false; break; } } }
    if inb { for k in 1..nops(gep) { if !lc_known_nonneg(op(gep, k), gep) { inb = false; break; } } }
    let fl: u8 = if inb { GEP_INBOUNDS | GEP_NUSW } else { 0 };
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    var gi: i32[>..<] = [];
    for k in 1..nops(gep) { gi.push(op(gep, k)); }
    let new_src = lb_gep(insts[inst_of(gep)].ty2, src_ptr, gi, fl, "invariant.gep");
    lb_set(gep);
    var si: i32[>..<] = [];
    for k in 1..nops(src) { si.push(op(src, k)); }
    let new_gep = lb_gep(insts[inst_of(src)].ty2, new_src, si, fl, "gep");
    lc_rauw(gep, new_gep);
    lc_erase(gep);
    salvage_debug_info(src);
    lc_erase(src);
    return true;
}

// m_NSWAddLike / m_NUWAddLike: (ok, a, b)
fn lc_match_add_like(v: i32, signed: bool) -> bool, i32, i32 {
    if !is_inst(v) { return false, -1, -1; }
    let o = iop(v);
    let f = insts[inst_of(v)].flags;
    if o == OP_ADD && (f & (if signed { FL_NSW } else { FL_NUW })) != 0 { return true, op(v, 0), op(v, 1); }
    // m_DisjointOr: an or with the disjoint flag counts as add nsw nuw
    if o == OP_OR && (f & FL_DISJOINT) != 0 { return true, op(v, 0), op(v, 1); }
    return false, -1, -1;
}

// hoistAdd(Pred, VariantLHS, InvariantRHS, ICmp, L, ...)
fn lc_hoist_add(pred: i64, variant_lhs: i32, inv_rhs: i32, icmp: i32, l: i32) -> bool {
    let signed = lc_is_signed(pred);
    let ok, a, b = lc_match_add_like(variant_lhs, signed);
    if !ok { return false; }
    var vop = a;
    var iop_ = b;
    if lc_invariant(l, vop) { let t = vop; vop = iop_; iop_ = t; }
    if lc_invariant(l, vop) || !lc_invariant(l, iop_) { return false; }
    if signed && ovf_signed_sub_sq(inv_rhs, iop_, icmp) != OF_NEVER { return false; }
    if !signed && ovf_unsigned_sub_sq(inv_rhs, iop_, icmp) != OF_NEVER { return false; }
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    let ncop = lb_binop(OP_SUB, inv_rhs, iop_, "invariant.op", if signed { FL_NSW } else { FL_NUW });
    insts[inst_of(icmp)].pred = pred as u8;
    set_op(icmp, 0, vop);
    set_op(icmp, 1, ncop);
    drop_poison_generating_flags(icmp);
    salvage_debug_info(variant_lhs);
    lc_erase(variant_lhs);
    return true;
}

// hoistSub(Pred, VariantLHS, InvariantRHS, ICmp, L, ...)
fn lc_hoist_sub(pred0: i64, variant_lhs: i32, inv_rhs: i32, icmp: i32, l: i32) -> bool {
    var pred = pred0;
    let signed = lc_is_signed(pred);
    if !is_inst_op(variant_lhs, OP_SUB) { return false; }
    let f = insts[inst_of(variant_lhs)].flags;
    if (f & (if signed { FL_NSW } else { FL_NUW })) == 0 { return false; }
    var vop = op(variant_lhs, 0);
    var iop_ = op(variant_lhs, 1);
    var var_subtracted = false;
    if lc_invariant(l, vop) {
        let t = vop; vop = iop_; iop_ = t;
        var_subtracted = true;
        pred = lc_swapped(pred);
    }
    if lc_invariant(l, vop) || !lc_invariant(l, iop_) { return false; }
    if var_subtracted && signed { if ovf_signed_sub_sq(iop_, inv_rhs, icmp) != OF_NEVER { return false; } }
    else if var_subtracted && !signed { if ovf_unsigned_sub_sq(iop_, inv_rhs, icmp) != OF_NEVER { return false; } }
    else if !var_subtracted && signed { if ovf_signed_add_sq(iop_, inv_rhs, icmp) != OF_NEVER { return false; } }
    else { if ovf_unsigned_add_sq(iop_, inv_rhs, icmp) != OF_NEVER { return false; } }
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    let fl = if signed { FL_NSW } else { FL_NUW };
    let ncop = if var_subtracted { lb_binop(OP_SUB, iop_, inv_rhs, "invariant.op", fl) }
               else { lb_binop(OP_ADD, iop_, inv_rhs, "invariant.op", fl) };
    insts[inst_of(icmp)].pred = pred as u8;
    set_op(icmp, 0, vop);
    set_op(icmp, 1, ncop);
    drop_poison_generating_flags(icmp);
    salvage_debug_info(variant_lhs);
    lc_erase(variant_lhs);
    return true;
}

// computeOverflowFor*(..., SimplifyQuery(DL, DT, AC, &ICmp)): no TLI
fn ovf_q_begin() -> bool, bool, bool { let a = sq_no_dt; let b = sq_no_ac; let c = sq_no_tli; sq_no_dt = false; sq_no_ac = false; sq_no_tli = true; return a, b, c; }
fn ovf_q_end(a: bool, b: bool, c: bool) { sq_no_dt = a; sq_no_ac = b; sq_no_tli = c; }
fn ovf_signed_sub_sq(x: i32, y: i32, cx: i32) -> i64 { let a, b, c = ovf_q_begin(); let r = ovf_signed_sub(x, y, cx); ovf_q_end(a, b, c); return r; }
fn ovf_unsigned_sub_sq(x: i32, y: i32, cx: i32) -> i64 { let a, b, c = ovf_q_begin(); let r = ovf_unsigned_sub(x, y, cx); ovf_q_end(a, b, c); return r; }
fn ovf_signed_add_sq(x: i32, y: i32, cx: i32) -> i64 { let a, b, c = ovf_q_begin(); let r = ovf_signed_add(x, y, cx); ovf_q_end(a, b, c); return r; }
fn ovf_unsigned_add_sq(x: i32, y: i32, cx: i32) -> i64 { let a, b, c = ovf_q_begin(); let r = ovf_unsigned_add(x, y, cx); ovf_q_end(a, b, c); return r; }

// hoistAddSub(I, L, ...)
fn lc_hoist_add_sub(i: i32, l: i32) -> bool {
    if iop(i) != OP_ICMP { return false; }
    var pred = insts[inst_of(i)].pred as i64;
    var lhs = op(i, 0);
    var rhs = op(i, 1);
    if lc_invariant(l, lhs) {
        let t = lhs; lhs = rhs; rhs = t;
        pred = lc_swapped(pred);
    }
    if lc_invariant(l, lhs) || !lc_invariant(l, rhs) || !lc_has_one_use(lhs) { return false; }
    if lc_hoist_add(pred, lhs, rhs, i, l) { return true; }
    if lc_hoist_sub(pred, lhs, rhs, i, l) { return true; }
    return false;
}
fn lc_has_one_use(v: i32) -> bool { if is_constant_data(v) { return false; } let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }

// isReassociableOp(I, IntOpcode, FPOpcode)
fn lc_reassociable(i: i32, int_op: i64, fp_op: i64) -> bool {
    let o = iop(i);
    if o == int_op { return true; }
    if o == fp_op { let f = insts[inst_of(i)].fmf; return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0; }
    return false;
}

// hoistMulAddAssociation(I, L, ...)
fn lc_hoist_mul_add(i: i32, l: i32) -> bool {
    if !lc_reassociable(i, OP_MUL, OP_FMUL) { return false; }
    var vop = op(i, 0);
    var iop_ = op(i, 1);
    if lc_invariant(l, vop) { let t = vop; vop = iop_; iop_ = t; }
    if lc_invariant(l, vop) || !lc_invariant(l, iop_) { return false; }
    let factor = iop_;
    var changes_user: i32[>..<] = [];
    var changes_k: i64[>..<] = [];
    var adds: i32[>..<] = [];
    var wl: i32[>..<] = [];
    if is_inst(vop) && is_binary_op(iop(vop)) { wl.push(vop); }
    let is_int = ty_is_int(ty_scalar(vals[i].ty));
    let limit = if is_int { flag_int("licm-max-num-int-reassociations", 5) } else { flag_int("licm-max-num-fp-reassociations", 5) };
    while wl.len > 0 {
        let bo = wl.pop();
        if !lc_has_one_use(bo) { return false; }
        if lc_reassociable(bo, OP_ADD, OP_FADD) && is_inst(op(bo, 0)) && is_binary_op(iop(op(bo, 0))) &&
           is_inst(op(bo, 1)) && is_binary_op(iop(op(bo, 1))) {
            wl.push(op(bo, 0));
            wl.push(op(bo, 1));
            adds.push(bo);
            continue;
        }
        if !lc_reassociable(bo, OP_MUL, OP_FMUL) || lc_invariant(l, bo) { return false; }
        if lc_invariant(l, op(bo, 0)) { changes_user.push(bo); changes_k.push(0); }
        else if lc_invariant(l, op(bo, 1)) { changes_user.push(bo); changes_k.push(1); }
        else { return false; }
        if changes_user.len > limit { return false; }
    }
    if changes_user.len == 0 { return false; }
    if is_int { for a in adds { drop_poison_generating_flags(a); } }
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    for c in changes_user.len {
        let ins = changes_user[c];
        let k = changes_k[c];
        let uv = op(ins, k);
        var mul: i32 = -1;
        if is_int {
            mul = lb_binop(OP_MUL, uv, factor, "factor.op.mul", 0);
            drop_poison_generating_flags(ins);
        } else {
            mul = lb_fmul_fmf(uv, factor, ins, "factor.op.fmul");
        }
        let lhs = if k == 0 { mul } else { op(ins, 0) };
        let rhs = if k == 1 { mul } else { op(ins, 1) };
        let nbo = create_inst(iop(ins), vals[ins].ty, [lhs, rhs]);
        m2r_insert_before_adopting(nbo, ins);
        var nm: u8[>..] = [];
        nm.append(val_name(ins));
        nm.append(".reass");
        set_name(nbo, nm);
        // setDebugLoc(DebugLoc::getDropped()): no !dbg; copyIRFlags(Ins)
        lc_copy_ir_flags(nbo, ins);
        if vop == ins { vop = nbo; }
        lc_rauw(ins, nbo);
        lc_erase(ins);
    }
    lc_rauw(i, vop);
    lc_erase(i);
    return true;
}

// Instruction::copyIRFlags(V) (IncludeWrapFlags = true)
fn lc_copy_ir_flags(dst: i32, src: i32) {
    let o = iop(dst);
    let sf = insts[inst_of(src)].flags;
    var f: u8 = 0;
    if o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL { f |= sf & (FL_NUW | FL_NSW); }
    if o == OP_UDIV || o == OP_SDIV || o == OP_LSHR || o == OP_ASHR { f |= sf & FL_EXACT; }
    if o == OP_OR { f |= sf & FL_DISJOINT; }
    insts[inst_of(dst)].flags = f;
    if is_fp_math_operator(dst) && is_fp_math_operator(src) { insts[inst_of(dst)].fmf = insts[inst_of(src)].fmf; }
}

// Instruction::isAssociative
fn lc_is_associative(i: i32) -> bool {
    let o = iop(i);
    if o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ADD || o == OP_MUL { return true; }
    if o == OP_FMUL || o == OP_FADD { let f = insts[inst_of(i)].fmf; return (f & FMF_REASSOC) != 0 && (f & FMF_NSZ) != 0; }
    return false;
}
// Value::hasNUsesOrMore
fn lc_has_n_uses_or_more(v: i32, n: i64) -> bool {
    var c: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { c++; if c >= n { return true; } u = uses[u].next; }
    return false;
}

// hoistBOAssociation(I, L, ...)
fn lc_hoist_bo_association(i: i32, l: i32) -> bool {
    if !is_inst(i) || !is_binary_op(iop(i)) || !lc_is_associative(i) { return false; }
    let bo = i;
    let opc = iop(bo);
    let lv_in_rhs = lc_invariant(l, op(bo, 0));
    let bo0 = op(bo, if lv_in_rhs { 1 } else { 0 });
    if !is_inst(bo0) || !is_binary_op(iop(bo0)) || iop(bo0) != opc || !lc_is_associative(bo0) ||
       lc_has_n_uses_or_more(bo0, if ty_is_int(vals[bo0].ty) { 2 } else { 3 }) { return false; }
    var lv = op(bo0, 0);
    var c1 = op(bo0, 1);
    let c2 = op(bo, if lv_in_rhs { 0 } else { 1 });
    if lc_invariant(l, lv) && !lc_invariant(l, c1) { let t = lv; lv = c1; c1 = t; }
    if lc_invariant(l, lv) || !lc_invariant(l, c1) || !lc_invariant(l, c2) { return false; }
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    let inv = lb_binop_plain(opc, c1, c2, "invariant.op");
    let nbo = create_inst(opc, vals[bo].ty, [lv, inv]);
    m2r_insert_before_adopting(nbo, bo);
    var nm: u8[>..] = [];
    nm.append(val_name(bo));
    nm.append(".reass");
    set_name(nbo, nm);
    if opc == OP_FADD || opc == OP_FMUL {
        let inter = insts[inst_of(bo)].fmf & insts[inst_of(bo0)].fmf;
        if is_inst(inv) { insts[inst_of(inv)].fmf = inter; }
        insts[inst_of(nbo)].fmf = inter;
    } else {
        // OverflowTracking with AllKnownNonNegative = AllKnownNonZero = false: mergeFlags(BO), mergeFlags(BO0)
        var has_nuw = true;
        var has_nsw = true;
        var is_disjoint = true;
        fn merge(x: i32) {
            let f = insts[inst_of(x)].flags;
            if iop(x) == OP_ADD || iop(x) == OP_SUB || iop(x) == OP_MUL || iop(x) == OP_SHL {
                has_nuw = has_nuw && (f & FL_NUW) != 0;
                has_nsw = has_nsw && (f & FL_NSW) != 0;
            }
            if iop(x) == OP_OR { is_disjoint = is_disjoint && (f & FL_DISJOINT) != 0; }
        }
        merge(bo);
        merge(bo0);
        // applyFlags(I): dropPoisonGeneratingFlags, then nuw/nsw for add (mul only when AllKnownNonZero, false
        // here), disjoint for or
        fn apply(x: i32) {
            drop_poison_generating_flags(x);
            let o = iop(x);
            if o == OP_ADD {
                if has_nuw { insts[inst_of(x)].flags |= FL_NUW; }
                if has_nsw && has_nuw { insts[inst_of(x)].flags |= FL_NSW; }
            }
            if o == OP_OR && is_disjoint { insts[inst_of(x)].flags |= FL_DISJOINT; }
        }
        if is_inst(inv) { apply(inv); }
        apply(nbo);
    }
    lc_rauw(bo, nbo);
    lc_erase(bo);
    if vals[bo0].first_use < 0 {
        salvage_debug_info(bo0);
        lc_erase(bo0);
    }
    return true;
}

// CreateBinOp(Opc, LHS, RHS, Name) (FoldBinOp; the builder's FMF is empty)
fn lb_binop_plain(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 { lb_binop(o, a, b, name, 0) }

// hoistSubAddAssociation(I, L, ...)
fn lc_hoist_sub_add_association(i: i32, l: i32) -> bool {
    var bo: i32 = -1;
    var lv: i32 = -1;
    var c1: i32 = -1;
    var c2: i32 = -1;
    var inv_op: i64 = 0;
    var res_op: i64 = 0;
    let o = iop(i);
    var matched = false;
    if o == OP_SUB {
        let x = op(i, 0);
        if one_use_v(x) && is_inst_op(x, OP_ADD) {
            bo = x; lv = op(x, 0); c1 = op(x, 1); c2 = op(i, 1);
            if lc_invariant(l, lv) && !lc_invariant(l, c1) { let t = lv; lv = c1; c1 = t; }
            inv_op = OP_SUB; res_op = OP_ADD;
            matched = true;
        } else if one_use_v(x) && is_inst_op(x, OP_SUB) {
            bo = x; lv = op(x, 0); c1 = op(x, 1); c2 = op(i, 1);
            inv_op = OP_ADD; res_op = OP_SUB;
            matched = true;
        }
    }
    if !matched && o == OP_ADD {
        // m_c_Add(m_OneUse(m_Instruction(BO, m_Sub(LV, C1))), C2): operand 0 first, then the commuted form
        for k in 2 {
            let x = op(i, k);
            if one_use_v(x) && is_inst_op(x, OP_SUB) {
                bo = x; lv = op(x, 0); c1 = op(x, 1); c2 = op(i, 1 - k);
                let t = c1; c1 = c2; c2 = t;
                inv_op = OP_SUB; res_op = OP_ADD;
                matched = true;
                break;
            }
        }
    }
    if !matched { return false; }
    if lc_invariant(l, lv) || !lc_invariant(l, c1) || !lc_invariant(l, c2) { return false; }
    let preheader = loop_preheader(l);
    lb_set(block_terminator(preheader));
    let inv = lb_binop_plain(inv_op, c1, c2, "invariant.op");
    let nbo = create_inst(res_op, vals[i].ty, [lv, inv]);
    m2r_insert_before_adopting(nbo, i);
    var nm: u8[>..] = [];
    nm.append(val_name(i));
    nm.append(".reass");
    set_name(nbo, nm);
    lc_rauw(i, nbo);
    lc_erase(i);
    salvage_debug_info(bo);
    lc_erase(bo);
    return true;
}

// hoistArithmetics(I, L, SafetyInfo, MSSAU, AC, DT)
fn lc_hoist_arithmetics(i: i32, l: i32) -> bool {
    if lc_hoist_min_max(i, l) { return true; }
    if lc_hoist_gep(i, l) { return true; }
    if lc_hoist_add_sub(i, l) { return true; }
    if lc_hoist_mul_add(i, l) { return true; }
    if lc_hoist_bo_association(i, l) { return true; }
    if lc_hoist_sub_add_association(i, l) { return true; }
    return false;
}
