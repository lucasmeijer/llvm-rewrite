// LoopDeletion: port of llvm/lib/Transforms/Scalar/LoopDeletion.cpp (whole; the remarks are not emitted since
// nothing prints them without -pass-remarks). deleteDeadLoop / breakLoopBackedge are in loop_utils.goose.
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import flags;
import domtree;
import loopinfo;
import loopsimplify;
import memoryssa;
import mssaupdater;
import instsimplify;
import vt;
import pm;
import tli;
import local;
import scev;
import scev_btc;
import scev_range;
import loop_utils;
import lpm;
import gen_iids;
import gen_attrs;

let LD_UNMODIFIED = 0;
let LD_MODIFIED = 1;
let LD_DELETED = 2;

fn ld_merge(a: i64, b: i64) -> i64 {
    if a == LD_DELETED || b == LD_DELETED { return LD_DELETED; }
    if a == LD_MODIFIED || b == LD_MODIFIED { return LD_MODIFIED; }
    return LD_UNMODIFIED;
}

// isLoopDead
fn ld_is_loop_dead(l: i32, exiting: const i32[:], exit: i32, changed: bool&, preheader: i32) -> bool {
    var all_inv = true;
    var all_same = true;
    if exit >= 0 {
        var p = block_first(exit);
        while p >= 0 && iop(p) == OP_PHI {
            let incoming = phi_value_for_block(p, exiting[0]);
            for k in 1..exiting.len { if phi_value_for_block(p, exiting[k]) != incoming { all_same = false; } }
            if !all_same { break; }
            if is_inst(incoming) {
                let save_ms = ls_mssau;
                let save_se = mli_se;
                ls_mssau = false;
                mli_se = true;
                let ok = make_loop_invariant(l, incoming, block_terminator(preheader), changed);
                ls_mssau = save_ms;
                mli_se = save_se;
                if !ok { all_inv = false; break; }
            }
            p = inst_next(p);
        }
    }
    if !all_inv || !all_same { return false; }
    for bi in loop_nblocks(l) {
        var i = block_first(loop_block(l, bi));
        while i >= 0 {
            if inst_may_have_side_effects(i) && !ld_is_droppable(i) { return false; }
            i = inst_next(i);
        }
    }
    let fv = block_func(loop_header(l));
    // Function::mustProgress: mustprogress or willreturn
    if func_has_fn_attr(fv, AK_MustProgress) || func_has_fn_attr(fv, AK_WillReturn) { return true; }
    var rpo: i32[>..<] = [];
    lu_loop_rpo(l, rpo);
    if lu_contains_irreducible(rpo) { return false; }
    var wl: i32[>..<] = [];
    wl.push(l);
    while wl.len > 0 {
        let cur = wl.pop();
        if lu_has_must_progress(cur) { continue; }
        let s = sc_get_constant_max_backedge_taken_count(cur);
        if sc_is_cnc(s) { return false; }
        for k in loop_nsubs(cur) { wl.push(loop_sub(cur, k)); }
    }
    return true;
}

// Instruction::isDroppable: llvm.assume and llvm.pseudoprobe
fn ld_is_droppable(i: i32) -> bool {
    if iop(i) != OP_CALL { return false; }
    let id = call_iid(i);
    return id == IID_assume || id == IID_pseudoprobe || id == IID_experimental_noalias_scope_decl;
}

// isLoopNeverExecuted
fn ld_is_loop_never_executed(l: i32) -> bool {
    let ph = loop_preheader(l);
    if ph == func_entry(block_func(ph)) { return false; }
    var ok = true;
    each_pred(ph) { p =>
        if ok {
            let t = block_terminator(p);
            if iop(t) != OP_CONDBR || vals[op(t, 0)].kind != VK_CINT { ok = false; }
            else {
                var taken = term_succ(t, 0);
                if is_null_value(op(t, 0)) { taken = term_succ(t, 1); }
                if taken == ph { ok = false; }
            }
        }
    };
    return ok;
}

// getValueOnFirstIteration (FirstIterValue = VM_PASS0)
recursive fn ld_first_iter_value(v: i32) -> i32 {
    if !is_inst(v) { return v; }
    if vm_has(VM_PASS0, v) { return vm_get(VM_PASS0, v, -1) as i32; }
    var r: i32 = -1;
    let o = iop(v);
    let q = sq_new(-1);
    if is_binary_op(o) {
        let a = ld_first_iter_value(op(v, 0));
        let b = ld_first_iter_value(op(v, 1));
        r = ld_bare(o, a, b, -1);
    } else if o == OP_ICMP {
        let a = ld_first_iter_value(op(v, 0));
        let b = ld_first_iter_value(op(v, 1));
        r = ld_bare(-1, a, b, inst_pred(v));
    } else if o == OP_SELECT {
        let c = ld_first_iter_value(op(v, 0));
        if vals[c].kind == VK_CINT {
            let sel = if !is_null_value(c) { op(v, 1) } else { op(v, 2) };
            r = ld_first_iter_value(sel);
        }
    }
    if r < 0 { r = v; }
    vm_set(VM_PASS0, v, r as i64);
    return r;
}

// simplifyBinOp / simplifyICmpInst with SimplifyQuery(DL): no DT, AC, TLI or context instruction
recursive fn ld_bare(o: i64, a: i32, b: i32, pred: i64) -> i32 {
    let sdt = sq_no_dt; let sac = sq_no_ac; let stl = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = if o >= 0 { simplify_binop(o, a, b, sq_new(-1), RECURSION_LIMIT) } else { simplify_icmp(pred, a, b, sq_new(-1), RECURSION_LIMIT) };
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stl;
    return r;
}

// LiveEdges: a list of (from, to) pairs
fn ld_edge_has(ef: i32[>..<]&, et: i32[>..<]&, f: i32, t: i32) -> bool {
    for k in ef.len { if ef[k] == f && et[k] == t { return true; } }
    return false;
}
fn ld_mark_live_edge(ef: i32[>..<]&, et: i32[>..<]&, f: i32, t: i32) {
    vs_add(VS_PASS1, t);
    if !ld_edge_has(ef, et, f, t) { ef.push(f); et.push(t); }
}

// canProveExitOnFirstIteration (LiveBlocks = VS_PASS1)
fn ld_can_prove_exit_on_first_iteration(l: i32) -> bool {
    if !flag_bool("loop-deletion-enable-symbolic-execution", true) { return false; }
    let pred = loop_predecessor(l);
    let latch = loop_latch(l);
    if pred < 0 || latch < 0 { return false; }
    var rpo: i32[>..<] = [];
    lu_loop_rpo(l, rpo);
    if lu_contains_irreducible(rpo) { return false; }
    let header = loop_header(l);
    vs_clear(VS_PASS1);
    vm_clear(VM_PASS0);
    vs_add(VS_PASS1, header);
    var ef: i32[>..<] = [];
    var et: i32[>..<] = [];
    for bb in rpo {
        if !vs_has(VS_PASS1, bb) { continue; }
        if li_loop_for(bb) != l {
            for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
            continue;
        }
        var pn = block_first(bb);
        while pn >= 0 && iop(pn) == OP_PHI {
            if ty_kind(vals[pn].ty) == TK_INT {
                // GetSoleInputOnFirstIteration
                var incoming: i32 = -1;
                if bb == header { incoming = phi_value_for_block(pn, pred); }
                else {
                    var only: i32 = -1;
                    var two = false;
                    each_pred(bb) { p =>
                        if !two && ld_edge_has(ef, et, p, bb) {
                            let inc = phi_value_for_block(pn, p);
                            if vals[inc].kind != VK_POISON {
                                if only >= 0 && only != inc { two = true; }
                                else { only = inc; }
                            }
                        }
                    };
                    if !two { incoming = if only >= 0 { only } else { c_poison(vals[pn].ty) }; }
                }
                if incoming >= 0 && dt_value_dominates_inst(incoming, block_terminator(bb)) {
                    let fiv = ld_first_iter_value(incoming);
                    vm_set(VM_PASS0, pn, fiv as i64);
                }
            }
            pn = inst_next(pn);
        }
        let t = block_terminator(bb);
        if iop(t) == OP_CONDBR {
            let cond = op(t, 0);
            let if_true = term_succ(t, 0);
            let if_false = term_succ(t, 1);
            if !is_inst(cond) || iop(cond) != OP_ICMP || ty_kind(vals[cond].ty) != TK_INT {
                for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
                continue;
            }
            let kc = ld_first_iter_value(cond);
            if kc == cond {
                for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
                continue;
            }
            if is_undef_or_poison(kc) {
                if loop_contains(l, if_true) && loop_contains(l, if_false) { ld_mark_live_edge(ef, et, bb, if_true); }
                continue;
            }
            if vals[kc].kind != VK_CINT {
                for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
                continue;
            }
            if !is_null_value(kc) { ld_mark_live_edge(ef, et, bb, if_true); }
            else { ld_mark_live_edge(ef, et, bb, if_false); }
        } else if iop(t) == OP_SWITCH {
            let sv = ld_first_iter_value(op(t, 0));
            if vals[sv].kind != VK_CINT {
                for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
                continue;
            }
            var dest = sw_default_dest(t);
            for k in (nops(t) - 2) / 2 { if op(t, 2 + 2 * k) == sv { dest = op(t, 3 + 2 * k); break; } }
            ld_mark_live_edge(ef, et, bb, dest);
        } else {
            for k in block_nsucc(bb) { ld_mark_live_edge(ef, et, bb, block_succ(bb, k)); }
        }
    }
    return !ld_edge_has(ef, et, latch, header);
}
fn sw_default_dest(si: i32) -> i32 { op(si, 1) }

// breakBackedgeIfNotTaken
fn ld_break_backedge_if_not_taken(l: i32, use_mssa: bool) -> i64 {
    if loop_latch(l) < 0 { return LD_UNMODIFIED; }
    let maxc = sc_get_constant_max_backedge_taken_count(l);
    if !sc_is_zero(maxc) {
        let btc = sc_get_backedge_taken_count(l, BTC_EXACT);
        if !sc_is_zero(btc) {
            if !sc_is_cnc(btc) && sc_is_known_non_zero(btc) { return LD_UNMODIFIED; }
            if !ld_can_prove_exit_on_first_iteration(l) { return LD_UNMODIFIED; }
        }
    }
    lu_break_loop_backedge(l, use_mssa);
    return LD_DELETED;
}

// deleteLoopIfDead
fn ld_delete_loop_if_dead(l: i32, use_mssa: bool) -> i64 {
    let preheader = loop_preheader(l);
    if preheader < 0 || !loop_has_dedicated_exits(l) { return LD_UNMODIFIED; }
    let exit = lu_unique_exit_block(l);
    if exit >= 0 {
        let f = first_non_phi(exit);
        if f >= 0 && inst_is_eh_pad(f) { return LD_UNMODIFIED; }
    }
    if exit >= 0 && ld_is_loop_never_executed(l) {
        sc_forget_loop(l);
        var p = block_first(exit);
        while p >= 0 && iop(p) == OP_PHI {
            let pz = c_poison(vals[p].ty);
            for k in nops(p) { set_op(p, k, pz); }
            p = inst_next(p);
        }
        lu_delete_dead_loop(l, true, use_mssa);
        return LD_DELETED;
    }
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    if exit < 0 && !lu_has_no_exit_blocks(l) { return LD_UNMODIFIED; }
    var changed = false;
    if !ld_is_loop_dead(l, exiting, exit, changed, preheader) {
        return if changed { LD_MODIFIED } else { LD_UNMODIFIED };
    }
    lu_delete_dead_loop(l, true, use_mssa);
    return LD_DELETED;
}

// LoopDeletionPass::run
fn loop_deletion_pass_run(l: i32, use_mssa: bool) -> u32 {
    let fv = block_func(loop_header(l));
    tli_cur_fn = fv;
    local_have_tli = true;
    if use_mssa { msu_reset(); }
    var r = ld_delete_loop_if_dead(l, use_mssa);
    if r != LD_DELETED { r = ld_merge(r, ld_break_backedge_if_not_taken(l, use_mssa)); }
    if r == LD_UNMODIFIED { return PA_ALL; }
    if r == LD_DELETED { lpm_mark_loop_as_deleted(l); }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
