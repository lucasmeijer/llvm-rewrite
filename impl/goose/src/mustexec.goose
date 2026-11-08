// LoopSafetyInfo / ICFLoopSafetyInfo: port of llvm/lib/Analysis/MustExecute.cpp (computeLoopSafetyInfo,
// insertInstructionTo, removeInstruction, computeBlockColors (fails loudly for scoped EH personalities),
// CanProveNotTakenFirstIteration, collectTransitivePredecessors, allLoopPathsLeadToBlock, isGuaranteedToExecute,
// doesNotWriteMemoryBefore) and of llvm/lib/Analysis/InstructionPrecedenceTracking.cpp (the lazily filled
// FirstSpecialInsts caches of ImplicitControlFlowTracking and MemoryWriteTracking, which can go stale exactly as
// LLVM's do: a cached block is only reset by insertInstructionTo of a special instruction or removeInstruction of
// the cached one).
//
// One ICFLoopSafetyInfo at a time (LICM's). The per-block caches are stamped with an epoch per tracker (clear()).
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import domtree;
import loopinfo;
import vt;
import instsimplify;
import constfold;

var lsi_may_throw: bool = false;
// FirstSpecialInsts: block -> first special instruction (-1 = none), valid iff the stamp matches
var lsi_icf_stamp: i32[>..];
var lsi_icf_val: i32[>..];
var lsi_mw_stamp: i32[>..];
var lsi_mw_val: i32[>..];
var lsi_icf_epoch: i32 = 1;
var lsi_mw_epoch: i32 = 1;

// a private stamped block set (collectTransitivePredecessors' Predecessors)
var lsi_set: i32[>..];
var lsi_set_epoch: i32 = 1;
fn lsi_set_clear() { lsi_set_epoch++; }
fn lsi_set_has(b: i32) -> bool { let k = block_of(b) as i64; k < lsi_set.len && lsi_set[k] == lsi_set_epoch }
fn lsi_set_add(b: i32) -> bool {
    let k = block_of(b) as i64;
    while lsi_set.len <= k { lsi_set.push(0); }
    if lsi_set[k] == lsi_set_epoch { return false; }
    lsi_set[k] = lsi_set_epoch;
    return true;
}

fn lsi_grow(k: i64) {
    while lsi_icf_stamp.len <= k { lsi_icf_stamp.push(0); lsi_icf_val.push(-1); lsi_mw_stamp.push(0); lsi_mw_val.push(-1); }
}

// ImplicitControlFlowTracking::isSpecialInstruction
fn icf_special(i: i32) -> bool { !guaranteed_to_transfer(i) }
// MemoryWriteTracking::isSpecialInstruction
fn mw_special(i: i32) -> bool {
    if inst_iid(i) == IID_experimental_widenable_condition { return false; }
    return inst_may_write_memory(i);
}

// getFirstSpecialInstruction(BB)
fn icf_first_special(bb: i32) -> i32 {
    let k = block_of(bb) as i64;
    lsi_grow(k);
    if lsi_icf_stamp[k] != lsi_icf_epoch {
        var r: i32 = -1;
        var i = block_first(bb);
        while i >= 0 { if icf_special(i) { r = i; break; } i = inst_next(i); }
        lsi_icf_stamp[k] = lsi_icf_epoch;
        lsi_icf_val[k] = r;
    }
    return lsi_icf_val[k];
}
fn mw_first_special(bb: i32) -> i32 {
    let k = block_of(bb) as i64;
    lsi_grow(k);
    if lsi_mw_stamp[k] != lsi_mw_epoch {
        var r: i32 = -1;
        var i = block_first(bb);
        while i >= 0 { if mw_special(i) { r = i; break; } i = inst_next(i); }
        lsi_mw_stamp[k] = lsi_mw_epoch;
        lsi_mw_val[k] = r;
    }
    return lsi_mw_val[k];
}

// Instruction::comesBefore (same block)
fn lsi_comes_before(a: i32, b: i32) -> bool {
    var x = inst_next(a);
    while x >= 0 { if x == b { return true; } x = inst_next(x); }
    return false;
}

// isPreceededBySpecialInstruction
fn icf_preceded(i: i32) -> bool { let f = icf_first_special(inst_parent(i)); return f >= 0 && lsi_comes_before(f, i); }
fn mw_preceded(i: i32) -> bool { let f = mw_first_special(inst_parent(i)); return f >= 0 && lsi_comes_before(f, i); }

// BlockColors: block -> its funclet colours (a linked list per block, in insertion order); lsi_colors_on is
// "!BlockColors.empty()"
struct LsiColor { color: i32, next: i32 }
var lsi_colors_on: bool = false;
var lsi_col_pool: LsiColor[>..<];
var lsi_col_head: i32[>..];
var lsi_col_tail: i32[>..];
var lsi_col_stamp: i32[>..];
var lsi_col_epoch: i32 = 1;

fn lsi_col_slot(bb: i32) -> i64 {
    let k = block_of(bb) as i64;
    while lsi_col_stamp.len <= k { lsi_col_stamp.push(0); lsi_col_head.push(-1); lsi_col_tail.push(-1); }
    if lsi_col_stamp[k] != lsi_col_epoch { lsi_col_stamp[k] = lsi_col_epoch; lsi_col_head[k] = -1; lsi_col_tail[k] = -1; }
    return k;
}
fn lsi_col_push(bb: i32, c: i32) {
    let k = lsi_col_slot(bb);
    let e = lsi_col_pool.len as i32;
    lsi_col_pool.push(LsiColor { color: c, next: -1 });
    if lsi_col_tail[k] >= 0 { lsi_col_pool[lsi_col_tail[k]].next = e; } else { lsi_col_head[k] = e; }
    lsi_col_tail[k] = e;
}
fn lsi_col_has(bb: i32, c: i32) -> bool {
    let k = lsi_col_slot(bb);
    var e = lsi_col_head[k];
    while e >= 0 { if lsi_col_pool[e].color == c { return true; } e = lsi_col_pool[e].next; }
    return false;
}
// BlockColors.find(BB)->second.size() / front()
fn lsi_ncolors(bb: i32) -> i64 {
    let k = lsi_col_slot(bb);
    var n: i64 = 0;
    var e = lsi_col_head[k];
    while e >= 0 { n++; e = lsi_col_pool[e].next; }
    return n;
}
fn lsi_first_color(bb: i32) -> i32 { let k = lsi_col_slot(bb); let e = lsi_col_head[k]; return if e >= 0 { lsi_col_pool[e].color } else { -1 }; }
// LoopSafetyInfo::copyColors(New, Old)
fn lsi_copy_colors(nw: i32, old: i32) {
    if !lsi_colors_on { return; }
    let ko = lsi_col_slot(old);
    var cs: i32[>..<] = [];
    var e = lsi_col_head[ko];
    while e >= 0 { cs.push(lsi_col_pool[e].color); e = lsi_col_pool[e].next; }
    let kn = lsi_col_slot(nw);
    lsi_col_head[kn] = -1;
    lsi_col_tail[kn] = -1;
    for c in cs { lsi_col_push(nw, c); }
}

// isScopedEHPersonality(classifyEHPersonality(Pers))
fn lsi_scoped_personality(fv: i32) -> bool {
    if globs[glob_of(fv)].has_personality == 0 { return false; }
    var p = op(fv, 0);
    while vals[p].kind == VK_CEXPR { p = op(p, 0); }
    if !is_func(p) || vals[p].name < 0 { return false; }
    let n = sbytes(vals[p].name);
    return n == "__CxxFrameHandler3" || n == "__C_specific_handler" || n == "_except_handler3" ||
        n == "_except_handler4" || n == "ProcessCLRException" || n == "__gxx_wasm_personality_v0";
}

// colorEHFunclets(F) (llvm/lib/IR/EHPersonalities.cpp)
fn lsi_color_eh_funclets(fv: i32) {
    let entry = func_entry(fv);
    var wl_b: i32[>..<] = [];
    var wl_c: i32[>..<] = [];
    wl_b.push(entry);
    wl_c.push(entry);
    while wl_b.len > 0 {
        let visiting = wl_b.pop();
        var color = wl_c.pop();
        let head = first_non_phi(visiting);
        if head >= 0 && inst_is_eh_pad(head) { color = visiting; }
        if lsi_col_has(visiting, color) { continue; }
        lsi_col_push(visiting, color);
        var succ_color = color;
        let t = block_terminator(visiting);
        if t >= 0 && iop(t) == OP_CATCHRET {
            // CatchRet->getCatchSwitchParentPad(): the catchpad's catchswitch's parent pad
            let cp = op(t, 0);
            let cs = op(cp, nops(cp) - 1);
            let pp = op(cs, 0);
            if vals[pp].kind == VK_CTOKENNONE { succ_color = entry; } else { succ_color = inst_parent(pp); }
        }
        if t >= 0 { for k in term_nsucc(t) { wl_b.push(term_succ(t, k)); wl_c.push(succ_color); } }
    }
}

// LoopSafetyInfo::computeBlockColors
fn lsi_compute_block_colors(l: i32) {
    lsi_col_epoch++;
    lsi_col_pool.clear();
    lsi_colors_on = false;
    let fv = block_func(loop_header(l));
    if lsi_scoped_personality(fv) {
        lsi_color_eh_funclets(fv);
        lsi_colors_on = true;
    }
}

// ICFLoopSafetyInfo::computeLoopSafetyInfo
fn lsi_compute(l: i32) {
    lsi_icf_epoch++;
    lsi_mw_epoch++;
    lsi_may_throw = false;
    for k in loop_nblocks(l) {
        if icf_first_special(loop_block(l, k)) >= 0 { lsi_may_throw = true; break; }
    }
    lsi_compute_block_colors(l);
}

fn lsi_any_block_may_throw() -> bool { lsi_may_throw }
fn lsi_block_may_throw(bb: i32) -> bool { icf_first_special(bb) >= 0 }

// InstructionPrecedenceTracking::insertInstructionTo for both trackers
fn lsi_insert_instruction_to(i: i32, bb: i32) {
    let k = block_of(bb) as i64;
    lsi_grow(k);
    if icf_special(i) { lsi_icf_stamp[k] = 0; }
    if mw_special(i) { lsi_mw_stamp[k] = 0; }
}
// removeInstruction: before the instruction leaves its block
fn lsi_remove_instruction(i: i32) {
    let bb = inst_parent(i);
    if bb < 0 { return; }
    let k = block_of(bb) as i64;
    lsi_grow(k);
    if lsi_icf_stamp[k] == lsi_icf_epoch && lsi_icf_val[k] == i { lsi_icf_stamp[k] = 0; }
    if lsi_mw_stamp[k] == lsi_mw_epoch && lsi_mw_val[k] == i { lsi_mw_stamp[k] = 0; }
}

// CanProveNotTakenFirstIteration(ExitBlock, DT, CurLoop)
fn lsi_not_taken_first_iteration(exit: i32, l: i32) -> bool {
    let cond_exit = single_pred(exit);
    if cond_exit < 0 { return false; }
    let bi = block_terminator(cond_exit);
    if iop(bi) != OP_CONDBR { return false; }
    let c = op(bi, 0);
    if vals[c].kind == VK_CINT {
        return term_succ(bi, if is_null_value(c) { 0 } else { 1 }) == exit;
    }
    if !is_inst(c) || (iop(c) != OP_ICMP && iop(c) != OP_FCMP) { return false; }
    var pred = insts[inst_of(c)].pred as i64;
    var lhs = op(c, 0);
    var rhs = op(c, 1);
    let header = loop_header(l);
    if !is_inst_op(lhs, OP_PHI) || inst_parent(lhs) != header {
        pred = lsi_swapped_pred(pred);
        lhs = op(c, 1);
        rhs = op(c, 0);
        if !is_inst_op(lhs, OP_PHI) || inst_parent(lhs) != header { return false; }
    }
    let ph = loop_preheader(l);
    let k = phi_block_index(lhs, ph);
    if k < 0 { fatal("internal: CanProveNotTakenFirstIteration: no preheader entry"); }
    let iv_start = phi_value(lhs, k);
    // simplifyCmpInst(Pred, IVStart, RHS, {DL, /*TLI*/ nullptr, DT, /*AC*/ nullptr, BI})
    let sdt = sq_no_dt;
    let sac = sq_no_ac;
    let stli = sq_no_tli;
    sq_no_dt = false;
    sq_no_ac = true;
    sq_no_tli = true;
    let r = simplify_cmp(pred, iv_start, rhs, sq_new(bi), RECURSION_LIMIT);
    sq_no_dt = sdt;
    sq_no_ac = sac;
    sq_no_tli = stli;
    if r < 0 || !is_constant(r) { return false; }
    if exit == term_succ(bi, 0) { return is_null_value(r); }
    return is_all_ones_value(r);
}

// CmpInst::getSwappedPredicate (integer and FP predicates)
fn lsi_swapped_pred(p: i64) -> i64 {
    if p >= 32 {
        if p == 32 || p == 33 { return p; }
        if p == 34 { return 36; } if p == 36 { return 34; }
        if p == 35 { return 37; } if p == 37 { return 35; }
        if p == 38 { return 40; } if p == 40 { return 38; }
        if p == 39 { return 41; } if p == 41 { return 39; }
        return p;
    }
    // FCMP: OGT<->OLT, OGE<->OLE, UGT<->ULT, UGE<->ULE
    if p == 2 { return 4; } if p == 4 { return 2; }
    if p == 3 { return 5; } if p == 5 { return 3; }
    if p == 10 { return 12; } if p == 12 { return 10; }
    if p == 11 { return 13; } if p == 13 { return 11; }
    return p;
}

// collectTransitivePredecessors(CurLoop, BB, Predecessors): the set in insertion order
fn lsi_transitive_preds(l: i32, bb: i32, out: i32[>..<]&) {
    out.clear();
    lsi_set_clear();
    if bb == loop_header(l) { return; }
    var wl: i32[>..<] = [];
    each_pred(bb) { p => if loop_contains(l, p) && lsi_set_add(p) { out.push(p); wl.push(p); } };
    let header = loop_header(l);
    var pp: i32[>..<] = [];
    while wl.len > 0 {
        let p = wl.pop();
        if p == header { continue; }
        pp.clear();
        each_pred(p) { x => pp.push(x); };
        for x in pp {
            if loop_contains(l, x) && lsi_set_add(x) { out.push(x); wl.push(x); }
        }
    }
}

// LoopSafetyInfo::allLoopPathsLeadToBlock(CurLoop, BB, DT)
fn lsi_all_paths_lead_to_block(l: i32, bb: i32) -> bool {
    if bb == loop_header(l) { return true; }
    var preds: i32[>..<] = [];
    lsi_transitive_preds(l, bb, preds);
    var bad = false;
    each_pred(loop_header(l)) { p => if lsi_set_has(p) { bad = true; } };
    if bad { return false; }
    var checked: i32[>..<] = [];   // CheckedSuccessors
    for p in preds {
        if lsi_block_may_throw(p) { return false; }
        if dt_dominates_block(DT_DOM, bb, p) { continue; }
        for k in block_nsucc(p) {
            let s = block_succ(p, k);
            if position(checked, s) >= 0 { continue; }
            checked.push(s);
            if s != bb && !lsi_set_has(s) {
                if loop_contains(l, s) || !lsi_not_taken_first_iteration(s, l) { return false; }
            }
        }
    }
    return true;
}

// ICFLoopSafetyInfo::isGuaranteedToExecute(Inst, DT, CurLoop)
fn lsi_guaranteed_to_execute(i: i32, l: i32) -> bool {
    return !icf_preceded(i) && lsi_all_paths_lead_to_block(l, inst_parent(i));
}

// doesNotWriteMemoryBefore(BB, CurLoop)
fn lsi_no_write_before_block(bb: i32, l: i32) -> bool {
    if bb == loop_header(l) { return true; }
    var preds: i32[>..<] = [];
    lsi_transitive_preds(l, bb, preds);
    for p in preds { if mw_first_special(p) >= 0 { return false; } }
    return true;
}
// doesNotWriteMemoryBefore(I, CurLoop)
fn lsi_no_write_before(i: i32, l: i32) -> bool {
    return !mw_preceded(i) && lsi_no_write_before_block(inst_parent(i), l);
}
