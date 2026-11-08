// LoopRotate: port of llvm/lib/Transforms/Scalar/LoopRotation.cpp (LoopRotatePass::run) and
// llvm/lib/Transforms/Utils/LoopRotationUtils.cpp (LoopRotate::processLoop, simplifyLoopLatch,
// shouldSpeculateInstrs, rotateLoop, profitableToRotateLoopExitingLatch, updateBranchWeights,
// RewriteUsesOfClonedInstructions), with CodeMetrics::collectEphemeralValues(Loop) / analyzeBasicBlock
// (llvm/lib/Analysis/CodeMetrics.cpp), MergeBlockIntoPredecessor with LoopInfo, MemorySSAUpdater and
// PredecessorWithTwoSuccessors (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp), Loop::setLoopID and
// LoopInfo::replacementPreservesLCSSAForm (llvm/lib/Analysis/LoopInfo.cpp).
//
// Not ported (fail loudly): functions with debug records (cloneDebugInfoFrom / RemapDbgRecordRange / the
// duplicate-record hashes, findDbgValues rewriting, insertDebugValuesForPHIs, RemoveRedundantDbgInstrs),
// llvm.experimental.noalias.scope.decl in the header (cloneAndAdaptNoAliasScopes), key-instruction atoms
// (mapAtomInstance), metadata-as-value operands of cloned instructions, vectorize hints of minsize functions.
// ScalarEvolution::forgetTopmostLoop / forgetValue are not ported: the whole ScalarEvolution is dropped instead
// (a superset of what LLVM forgets).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_iids;
import gen_attrs;
import analyses;
import flags;
import domtree;
import dtu;
import loopinfo;
import memoryssa;
import mssaupdater;
import dinfo;
import mem2reg;
import ssaupdater;
import loopsimplify;
import breakcrit;
import cfgutil;
import speculate;
import instsimplify;
import assume;
import profdata;
import tti;
import scev;
import scev_btc;
import scev_eval;

var lr_mssau: bool = false;
var lr_fv: i32 = -1;

fn lr_not_ported(what: const u8[:]) { fatal(str("LoopRotate: ", what, " is not ported yet")); }

// LoopRotatePass::run: arg bits 0 = EnableHeaderDuplication, 1 = PrepareForLTO, 2 = CheckExitCount.
// Returns the preserved set.
fn loop_rotate_pass_run(l: i32, header_dup: bool, prepare_for_lto: bool, check_exit_count: bool, use_mssa: bool) -> u32 {
    lr_fv = block_func(loop_header(l));
    tli_cur_fn = lr_fv;
    let minsize = func_has_fn_attr(lr_fv, AK_MinSize);
    if header_dup && minsize && !flag_bool("enable-loop-header-duplication-at-minsize", false) {
        if find_option_md_for_loop_id(loop_id(l), "llvm.loop.vectorize.enable") >= 0 { lr_not_ported("hasVectorizeTransformation"); }
    }
    let threshold: i64 = if header_dup && (!minsize || flag_bool("enable-loop-header-duplication-at-minsize", false)) {
        flag_int("rotation-max-header-size", 16)
    } else { 0 };
    lr_mssau = use_mssa;
    if use_mssa { msu_reset(); }
    let changed = lr_process_loop(l, threshold, prepare_for_lto || flag_bool("rotation-prepare-for-lto", false), check_exit_count);
    lr_mssau = false;
    if !changed { return PA_ALL; }
    if use_mssa && flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}

// LoopRotate::processLoop
fn lr_process_loop(l: i32, threshold: i64, prepare_for_lto: bool, check_exit_count: bool) -> bool {
    let loop_md = loop_id(l);
    let simplified = lr_simplify_loop_latch(l);
    let made_change = lr_rotate_loop(l, simplified, threshold, prepare_for_lto, check_exit_count);
    if (made_change || simplified) && loop_md >= 0 { lr_set_loop_id(l, loop_md); }
    return made_change || simplified;
}

// Loop::setLoopID
fn lr_set_loop_id(l: i32, md: i32) {
    let h = loop_header(l);
    for k in loop_nblocks(l) {
        let t = block_terminator(loop_block(l, k));
        for j in term_nsucc(t) { if term_succ(t, j) == h { inst_set_md(t, MDK_LOOP, md); break; } }
    }
}

fn lr_forget_scev() {
    if scev_valid(lr_fv) { scev_invalidate(lr_fv); scev_get(lr_fv); }
}

// ---------------------------------------------------------------------------------------------
// simplifyLoopLatch

// shouldSpeculateInstrs(Begin, End, L)
fn lr_should_speculate_instrs(from: i32, end: i32, l: i32) -> bool {
    var seen_increment = false;
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    let multi_exit = exiting.len != 1;
    var i = from;
    while i >= 0 && i != end {
        if !spec_safe(i, -1, false) { return false; }
        let o = iop(i);
        if o == OP_GEP || o == OP_ADD || o == OP_SUB || o == OP_AND || o == OP_OR || o == OP_XOR ||
           o == OP_SHL || o == OP_LSHR || o == OP_ASHR {
            if o == OP_GEP {
                for k in 1..nops(i) { if vals[op(i, k)].kind != VK_CINT { return false; } }
            }
            let iv_opnd = if !is_constant(op(i, 0)) { op(i, 0) } else if !is_constant(op(i, 1)) { op(i, 1) } else { -1 };
            if iv_opnd < 0 { return false; }
            if multi_exit {
                var u = vals[iv_opnd].first_use;
                while u >= 0 {
                    if !loop_contains(l, inst_parent(uses[u].user)) { return false; }
                    u = uses[u].next;
                }
            }
            if seen_increment { return false; }
            seen_increment = true;
        } else if o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT {
        } else {
            return false;
        }
        i = inst_next(i);
    }
    return true;
}

fn lr_simplify_loop_latch(l: i32) -> bool {
    let latch = loop_latch(l);
    if latch < 0 || cu_has_address_taken(latch) { return false; }
    let jmp = block_terminator(latch);
    if iop(jmp) != OP_BR { return false; }
    let last_exit = single_pred(latch);
    if last_exit < 0 || !loop_is_exiting(l, last_exit) { return false; }
    let lt = iop(block_terminator(last_exit));
    if lt != OP_BR && lt != OP_CONDBR { return false; }
    if !lr_should_speculate_instrs(block_first(latch), jmp, l) { return false; }
    lr_check_no_debug_records();
    lr_merge_block_into_predecessor(latch, true);
    if scev_valid(lr_fv) { sc_forget_block_and_loop_dispositions_all(); }
    if lr_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    return true;
}

fn lr_check_no_debug_records() {
    if dbgrecs.len == 0 { return; }
    var b = func_entry(lr_fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 { if inst_first_dbg(i) >= 0 { lr_not_ported("rotating loops in functions with debug records"); } i = inst_next(i); }
        b = block_next(b);
    }
}

// MergeBlockIntoPredecessor(BB, DTU (eager), LI, MSSAU, MemDep = null, PredecessorWithTwoSuccessors)
fn lr_merge_block_into_predecessor(bb: i32, two_succ: bool) -> bool {
    if cu_has_address_taken(bb) { return false; }
    let pred = cu_unique_pred(bb);
    if pred < 0 || pred == bb { return false; }
    let pti = block_terminator(pred);
    if cu_is_special_terminator(pti) || inst_may_have_side_effects(pti) { return false; }
    if !two_succ && cu_unique_succ(pred) != bb { return false; }
    var new_succ: i32 = -1;
    var fall_thru: i64 = 0;
    if two_succ {
        if iop(pti) != OP_CONDBR { return false; }
        let jmp = block_terminator(bb);
        if iop(jmp) != OP_BR { return false; }
        new_succ = term_succ(jmp, 0);
        fall_thru = if term_succ(pti, 0) == bb { 0 } else { 1 };
    }
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op(i, k) == i { return false; } }
        i = inst_next(i);
    }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(pred) { return false; }
    if cu_has_phis(bb) { lr_fold_single_entry_phis(bb); }
    var ups: DTUpdate[>..<] = [];
    {
        var seen: i32[>..<] = [];
        var succs_of_pred: i32[>..<] = [];
        cu_succs(pred, succs_of_pred);
        var succs: i32[>..<] = [];
        cu_succs(bb, succs);
        for s in succs { if position(succs_of_pred, s) < 0 && cu_push_unique(seen, s) { ups.push(DTUpdate { kind: DT_INSERT, from: pred, to: s }); } }
        seen.clear();
        for s in succs { if cu_push_unique(seen, s) { ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); } }
        ups.push(DTUpdate { kind: DT_DELETE, from: pred, to: bb });
    }
    let sti = block_terminator(bb);
    var start = block_first(bb);
    if start == sti { start = pti; }
    // PredBB->splice(PTI, BB, BB->begin(), STI)
    block_splice(pred, pti, false, bb, block_first(bb), true, sti, false);
    if lr_mssau { msu_move_all_after_merge_blocks(bb, pred, start); }
    cu_block_rauw(bb, pred);
    if two_succ {
        inst_erase_from_parent(block_terminator(bb));
        block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
        term_set_succ(pti, fall_thru, new_succ);
    } else {
        inst_erase_from_parent(pti);
        inst_move_impl(sti, pred, -1, false, true);     // moveBeforePreserving(*PredBB, PredBB->end())
        block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
        if lr_mssau {
            let mud = mssa_access_of(block_terminator(pred));
            if mud >= 0 { msu_move_to_place(mud, pred, MSP_END); }
        }
    }
    if vals[pred].name < 0 && vals[bb].name >= 0 { cu_take_name(pred, bb); }
    li_remove_block(bb);
    // DTU (eager) applyUpdates, then DeleteDeadBlock(BB, DTU)
    dt_apply_updates(lr_fv, DT_DOM, ups);
    lr_delete_dead_block(bb);
    return true;
}

// FoldSingleEntryPHINodes(BB, MemDep = null)
fn lr_fold_single_entry_phis(bb: i32) {
    loop {
        let pn = block_first(bb);
        if pn < 0 || iop(pn) != OP_PHI { break; }
        let v = phi_value(pn, 0);
        if v != pn { rauw(pn, v); } else { rauw(pn, c_poison(vals[pn].ty)); }
        inst_erase_from_parent(pn);
    }
}

// DeleteDeadBlock(BB, DTU) for a block without predecessors whose successors' edges were already given to the DTU
fn lr_delete_dead_block(bb: i32) {
    cu_dtu = true;
    dtu_begin(lr_fv, true, false, false);
    cu_delete_dead_block(bb);
    dtu_end();
    cu_dtu = false;
}

// ---------------------------------------------------------------------------------------------
// CodeMetrics

// collectEphemeralValues(L, AC, EphValues): the set is VS_PASS2
fn lr_collect_ephemeral_values(l: i32) {
    vs_clear(VS_PASS2);
    vs_clear(VS_PASS3);      // Visited
    var wl: i32[>..<] = [];
    fn append_speculatable_operands(v: i32) {
        for k in nops(v) {
            let o = op(v, k);
            if !vs_add(VS_PASS3, o) { continue; }
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    var b = func_entry(lr_fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if inst_iid(i) == IID_assume && loop_contains(l, inst_parent(i)) {
                if vs_add(VS_PASS2, i) { append_speculatable_operands(i); }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !vs_has(VS_PASS2, uses[u].user) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        vs_add(VS_PASS2, v);
        append_speculatable_operands(v);
    }
}

// analyzeBasicBlock(BB, TTI, EphValues, PrepareForLTO): (notDuplicatable, convergent, NumInsts, NumInlineCandidates)
fn lr_analyze_basic_block(bb: i32, prepare_for_lto: bool) -> bool, bool, i64, i64 {
    var not_dup = false;
    var convergent = false;
    var num_insts: i64 = 0;
    var inline_cands: i64 = 0;
    var i = block_first(bb);
    while i >= 0 {
        if vs_has(VS_PASS2, i) { i = inst_next(i); continue; }
        if is_callbase(i) {
            let f = called_function(i);
            if f >= 0 {
                let lowered = tti_is_lowered_to_call(f);
                let internal = globs[glob_of(f)].linkage as i64 == LK_INTERNAL;
                if !call_has_fn_attr(i, AK_NoInline) && lowered && ((internal && lr_has_one_live_use(f)) || prepare_for_lto) {
                    inline_cands++;
                }
            }
        }
        if vals[i].ty == T_TOKEN && !lr_is_convergence_control(i) && lr_used_outside_block(i, bb) { not_dup = true; }
        if is_callbase(i) {
            if call_has_fn_attr(i, AK_NoDuplicate) { not_dup = true; }
            if call_has_fn_attr(i, AK_Convergent) { convergent = true; }
        }
        num_insts += tti_instruction_cost(i, TCK_CODE_SIZE);
        i = inst_next(i);
    }
    if iop(block_terminator(bb)) == OP_INDIRECTBR { not_dup = true; }
    return not_dup, convergent, num_insts, inline_cands;
}

fn lr_is_convergence_control(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_experimental_convergence_entry || id == IID_experimental_convergence_loop ||
        id == IID_experimental_convergence_anchor;
}
fn lr_used_outside_block(i: i32, bb: i32) -> bool {
    var u = vals[i].first_use;
    while u >= 0 {
        let x = uses[u].user;
        if iop(x) == OP_PHI {
            let k = (u - vals[x].ops) as i64;
            if phi_block(x, k) != bb { return true; }
        } else if inst_parent(x) != bb { return true; }
        u = uses[u].next;
    }
    return false;
}
// Constant::hasOneLiveUse = hasNLiveUses(1) (Constants.cpp): uses by constants that are dead don't count
fn lr_has_one_live_use(f: i32) -> bool {
    var n: i64 = 0;
    var u = vals[f].first_use;
    while u >= 0 {
        let x = uses[u].user;
        if !is_constant(x) || !lr_constant_is_dead(x) {
            n++;
            if n > 1 { return false; }
        }
        u = uses[u].next;
    }
    return n == 1;
}
// constantIsDead(C, RemoveDeadUsers = false)
recursive fn lr_constant_is_dead(c: i32) -> bool {
    if is_global(c) { return false; }
    var u = vals[c].first_use;
    while u >= 0 {
        let x = uses[u].user;
        if !is_constant(x) { return false; }
        if !lr_constant_is_dead(x) { return false; }
        u = uses[u].next;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// rotateLoop

// profitableToRotateLoopExitingLatch(L, SE)
fn lr_profitable_exiting_latch(l: i32, check_exit_count: bool) -> bool {
    let header = loop_header(l);
    let latch = loop_latch(l);
    let bi = block_terminator(header);
    var header_exit = term_succ(bi, 0);
    if loop_contains(l, header_exit) { header_exit = term_succ(bi, 1); }
    var p = block_first(header);
    while p >= 0 && iop(p) == OP_PHI {
        var any = false;
        var u = vals[p].first_use;
        while u >= 0 { if inst_parent(uses[u].user) != header_exit { any = true; } u = uses[u].next; }
        if !any { return true; }
        p = inst_next(p);
    }
    if check_exit_count {
        scev_get(lr_fv);
        let a = sc_get_exit_count(l, latch, 0, false);
        if a == 0 {
            let b = sc_get_exit_count(l, header, 0, false);
            if b != 0 { return true; }
        }
    }
    return false;
}

// LoopInfo::replacementPreservesLCSSAForm(From, To)
fn lr_replacement_preserves_lcssa(from: i32, to: i32) -> bool {
    if !is_inst(to) { return true; }
    if inst_parent(to) == inst_parent(from) { return true; }
    let tl = li_loop_for(inst_parent(to));
    if tl < 0 { return true; }
    return loop_contains_loop(tl, li_loop_for(inst_parent(from)));
}

// updateBranchWeights(PreHeaderBI, LoopBI, HasConditionalPreHeader, SuccsSwapped)
fn lr_update_branch_weights(phbi: i32, lbi: i32, has_cond_ph: bool, swapped: bool) {
    let wmd = inst_get_md(phbi, MDK_PROF);
    if wmd < 0 || !pd_is_branch_weight_md(wmd) { return; }
    let lmd = inst_get_md(lbi, MDK_PROF);
    if wmd != lmd { return; }
    var ws: u64[>..<] = [];
    pd_extract_md(wmd, ws);
    if ws.len != 2 { return; }
    var exit_w = ws[0] & 0xFFFFFFFF;
    var back_w = ws[1] & 0xFFFFFFFF;
    if swapped { let t = exit_w; exit_w = back_w; back_w = t; }
    var x0: u64 = 0;
    var x1: u64 = 0;
    var y0: u64 = 0;
    var y1: u64 = 0;
    if exit_w > 0 && back_w > 0 {
        x0 = 0;
        if has_cond_ph {
            if back_w >= exit_w {
                x0 = 1;
                while exit_w < 127 + x0 {
                    let hb: u64 = 0x80000000;
                    if (back_w & hb) != 0 || (exit_w & hb) != 0 { break; }
                    back_w = (back_w << 1) & 0xFFFFFFFF;
                    exit_w = (exit_w << 1) & 0xFFFFFFFF;
                }
            } else {
                x0 = exit_w - back_w;
            }
        } else {
            if exit_w > back_w { back_w = exit_w; }
        }
        x1 = exit_w - x0;
        y0 = x1;
        y1 = back_w - y0;
    } else if exit_w == 0 {
        if back_w == 0 { x0 = 0; x1 = 0; y0 = 0; y1 = 0; }
        else { x0 = 0; x1 = 0; y0 = 1; y1 = back_w; }
    } else {
        x0 = 1; x1 = 1; y0 = 0; y1 = 0;
    }
    let lw0 = if swapped { y1 } else { x1 };
    let lw1 = if swapped { x1 } else { y1 };
    pd_set(lbi, [lw0, lw1], false, false);
    if has_cond_ph {
        let pw0 = if swapped { y0 } else { x0 };
        let pw1 = if swapped { x0 } else { y0 };
        pd_set(phbi, [pw0, pw1], false, false);
    }
}

// ValueMap / ValueMapMSSA: vm slots VM_PASS0 / VM_PASS1 (value id -> value id)
fn lr_vmap_get(v: i32) -> i32 { vm_get(VM_PASS0, v, -1) as i32 }
fn lr_vmap_set(k: i32, v: i32) {
    if vm_has(VM_PASS0, k) { fatal("internal: LoopRotate: value mapped twice"); }
    vm_set(VM_PASS0, k, v as i64);
}

// RewriteUsesOfClonedInstructions(OrigHeader, OrigPreheader, ValueMap, SE, InsertedPHIs)
fn lr_rewrite_uses_of_cloned(oh: i32, oph: i32) {
    var p = block_first(oh);
    while p >= 0 && iop(p) == OP_PHI {
        let k = phi_block_index(p, oph);
        if k >= 0 { phi_remove_incoming(p, k); }
        p = inst_next(p);
    }
    var i = block_first(oh);
    while i >= 0 {
        let ohv = i;
        i = inst_next(i);
        if vals[ohv].first_use < 0 { continue; }
        let ophv = lr_vmap_get(ohv);
        var nm: u8[>..] = [];
        nm.append(val_name(ohv));
        ssa_init(vals[ohv].ty, nm);
        ssa_add_available_value(oh, ohv);
        ssa_add_available_value(oph, ophv);
        var u = vals[ohv].first_use;
        while u >= 0 {
            let nu = uses[u].next;
            let ui = uses[u].user;
            if iop(ui) != OP_PHI {
                let ub = inst_parent(ui);
                if ub == oh { u = nu; continue; }
                if ub == oph {
                    let k = (u - vals[ui].ops) as i64;
                    set_op(ui, k, ophv);
                    u = nu;
                    continue;
                }
            }
            ssa_rewrite_use(u);
            u = nu;
        }
    }
}

fn lr_rotate_loop(l: i32, simplified_latch: bool, threshold: i64, prepare_for_lto: bool, check_exit_count: bool) -> bool {
    if loop_nblocks(l) == 1 { return false; }
    let oh = loop_header(l);
    let ol = loop_latch(l);
    let bi = block_terminator(oh);
    if iop(bi) != OP_CONDBR { return false; }
    if !loop_is_exiting(l, oh) { return false; }
    if ol < 0 { return false; }
    if loop_is_exiting(l, ol) && !simplified_latch && !lr_profitable_exiting_latch(l, check_exit_count) { return false; }
    {
        lr_collect_ephemeral_values(l);
        tti_init_function(lr_fv, globs[glob_of(lr_fv)].module);
        let not_dup, conv, num_insts, inline_cands = lr_analyze_basic_block(oh, prepare_for_lto);
        if not_dup { return false; }
        if conv { return false; }
        if num_insts > threshold { return false; }
        if prepare_for_lto && inline_cands > 0 { return false; }
    }
    let oph = loop_preheader(l);
    if oph < 0 || !loop_has_dedicated_exits(l) { return false; }
    lr_check_no_debug_records();
    lr_forget_scev();
    if lr_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    var exit = term_succ(bi, 0);
    var nh = term_succ(bi, 1);
    let swapped = loop_contains(l, exit);
    if swapped { let t = exit; exit = nh; nh = t; }
    if single_pred(nh) < 0 { fatal("internal: LoopRotate: new header doesn't have one pred"); }
    lr_fold_single_entry_phis(nh);
    vm_clear(VM_PASS0);
    vm_clear(VM_PASS1);
    var i = block_first(oh);
    while i >= 0 && iop(i) == OP_PHI {
        lr_vmap_set(i, phi_value(i, phi_block_index(i, oph)));
        i = inst_next(i);
    }
    let entry_br = block_terminator(oph);
    var j = i;
    while j >= 0 {
        let inst = j;
        j = inst_next(j);
        if inst_iid(inst) == IID_experimental_noalias_scope_decl { lr_not_ported("noalias scope declarations in the rotated header"); }
        if lr_invariant_operands(l, inst) && !inst_may_read_memory(inst) && !inst_may_write_memory(inst) &&
           !is_terminator(inst) && iop(inst) != OP_ALLOCA && !func_has_fn_attr(lr_fv, AK_PresplitCoroutine) {
            inst_move_before(inst, entry_br);
            continue;
        }
        let c = inst_clone(inst);
        let dl = inst_get_md(c, MDK_DBG_SC);
        if dl >= 0 && mds[dl].kind == MK_DI && (di_int(dl, "atomGroup") != 0) { lr_not_ported("mapAtomInstance (key instructions)"); }
        inst_insert_before(c, entry_br);
        // RemapInstruction(C, ValueMap, RF_NoModuleLevelChanges | RF_IgnoreMissingLocals)
        for k in nops(c) {
            let o = op(c, k);
            if vals[o].kind == VK_MDVAL { lr_check_md_operand(o); continue; }
            let m = lr_vmap_get(o);
            if m >= 0 { set_op(c, k, m); }
        }
        if iop(c) == OP_PHI { fatal("internal: LoopRotate: cloned a PHI"); }
        var cc = c;
        let v = simplify_instruction(c);
        if v >= 0 && v != c && lr_replacement_preserves_lcssa(c, v) {
            lr_vmap_set(inst, v);
            if !inst_may_have_side_effects(c) {
                inst_erase_from_parent(c);
                cc = -1;
            }
        } else {
            lr_vmap_set(inst, c);
        }
        if cc >= 0 {
            if vals[inst].name >= 0 {
                var nm: u8[>..] = [];
                nm.append(val_name(inst));
                set_name(cc, nm);
            }
            if inst_iid(cc) == IID_assume { ac_register_assumption(cc); }
            if lr_mssau { vm_set(VM_PASS1, inst, cc as i64); }
        }
    }
    // fix up the PHIs of OrigHeader's successors
    for k in block_nsucc(oh) {
        let s = block_succ(oh, k);
        var p = block_first(s);
        while p >= 0 && iop(p) == OP_PHI {
            let pv = phi_value(p, phi_block_index(p, oh));
            phi_add_incoming(p, pv, oph);
            p = inst_next(p);
        }
    }
    inst_erase_from_parent(entry_br);
    if lr_mssau {
        vm_set(VM_PASS1, oh, oph as i64);
        msu_update_for_cloned_block_into_pred(oh, oph, VM_PASS1);
    }
    lr_rewrite_uses_of_cloned(oh, oph);
    loop_move_to_header(l, nh);
    var ups: DTUpdate[>..<] = [];
    ups.push(DTUpdate { kind: DT_INSERT, from: oph, to: exit });
    ups.push(DTUpdate { kind: DT_INSERT, from: oph, to: nh });
    ups.push(DTUpdate { kind: DT_DELETE, from: oph, to: oh });
    if lr_mssau {
        msu_apply_updates(lr_fv, ups, true);
        if flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    } else {
        dt_apply_updates(lr_fv, DT_DOM, ups);
    }
    let phbi = block_terminator(oph);
    if iop(phbi) != OP_CONDBR { fatal("internal: LoopRotate: the preheader branch is not conditional"); }
    let cond = op(phbi, 0);
    let has_cond_ph = vals[cond].kind != VK_CINT || term_succ(phbi, if is_null_value(cond) { 1 } else { 0 }) != nh;
    lr_update_branch_weights(phbi, bi, has_cond_ph, swapped);
    if has_cond_ph {
        var o = ces_opts(true, true, false);
        o.mssau = lr_mssau;
        o.preserve_lcssa = true;
        var si: i64 = 0;
        while term_succ(phbi, si) != nh { si++; }
        let save = ls_mssau;
        ls_mssau = lr_mssau;
        let new_ph = split_critical_edge(phbi, si, o, "");
        if new_ph < 0 { fatal("internal: LoopRotate: the preheader edge is not critical"); }
        var nm: u8[>..] = [];
        nm.append(val_name(nh));
        nm.append(".lr.ph");
        set_name(new_ph, nm);
        var exit_preds: i32[>..<] = [];
        each_pred(exit) { p => exit_preds.push(p); };
        var split_latch_edge = false;
        for ep in exit_preds {
            let pl = li_loop_for(ep);
            if pl < 0 || loop_contains(pl, exit) || iop(block_terminator(ep)) == OP_INDIRECTBR { continue; }
            if loop_latch(l) == ep { split_latch_edge = true; }
            let t = block_terminator(ep);
            var ek: i64 = 0;
            while term_succ(t, ek) != exit { ek++; }
            let es = split_critical_edge(t, ek, o, "");
            if es < 0 { fatal("internal: LoopRotate: an exit edge is not critical"); }
            block_move_before(es, exit);
        }
        ls_mssau = save;
        if !split_latch_edge { fatal("internal: LoopRotate: despite splitting all preds, failed to split latch exit"); }
    } else {
        block_remove_predecessor(exit, oph, true);
        let nbi = create_inst(OP_BR, T_VOID, [nh]);
        inst_insert_before(nbi, phbi);
        let pdl = inst_get_md(phbi, MDK_DBG_SC);
        if pdl >= 0 { inst_set_md(nbi, MDK_DBG_SC, pdl); }
        inst_erase_from_parent(phbi);
        dt_delete_edge(lr_fv, DT_DOM, oph, exit);
        if lr_mssau { msu_remove_edge(oph, exit); }
    }
    if lr_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    lr_merge_block_into_predecessor(oh, false);
    if lr_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lr_fv); }
    return true;
}

fn lr_invariant_operands(l: i32, i: i32) -> bool {
    for k in nops(i) {
        let v = op(i, k);
        if is_inst(v) && loop_contains(l, inst_parent(v)) { return false; }
    }
    return true;
}

// a metadata-as-value operand of a cloned instruction (RemapInstruction maps function-local values in it)
fn lr_check_md_operand(o: i32) {
    let m = vals[o].sub;
    if m >= 0 && mds[m].kind == MK_VALUE && lr_vmap_get(mds[m].extra) >= 0 { lr_not_ported("remapping metadata-as-value operands"); }
    if m >= 0 && mds[m].kind == MK_DIARGLIST { lr_not_ported("remapping DIArgList operands"); }
}
