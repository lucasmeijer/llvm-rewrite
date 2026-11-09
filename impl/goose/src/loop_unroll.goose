// UnrollLoop: port of llvm/lib/Transforms/Utils/LoopUnroll.cpp (needToInsertPhisForLCSSA,
// addClonedBlockToLoopInfo, isEpilogProfitable, loadCSE + getMatchingValue, simplifyLoopAfterUnroll,
// fixProbContradiction, UnrollLoop), with LoopInfo::erase + UnloopUpdater and Loop::isSafeToClone
// (llvm/lib/Analysis/LoopInfo.cpp), LoopBlocksDFS::perform (llvm/lib/Analysis/LoopIterator.cpp),
// MergeBlockIntoPredecessor(BB, DTU or DT, LI) (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp) and
// changeToUnreachable(I, PreserveLCSSA) (llvm/lib/Transforms/Utils/Local.cpp).
//
// Not ported (fail loudly): parallel reduction phis (-unroll-add-parallel-reductions), the loop-scoped
// MemorySSA that loadCSE builds when a matching load is from another generation, FS discriminators
// (debug-info-for-profiling), key-instruction atoms.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import flags;
import apint;
import pm;
import local;
import instsimplify;
import vt;
import assume;
import dinfo;
import dbgutil;
import domtree;
import dtu;
import loopinfo;
import loopsimplify;
import loopsimplify_pass;
import lcssa;
import cfgutil;
import profdata;
import tti;
import wvh;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_update;
import scev_expander;
import simplify_indvar;
import looprotate;
import value_mapper;
import clone_function;
import loop_md;
import loop_unroll_runtime;

fn ul_not_ported(what: const u8[:]) { fatal(str("LoopUnroll: ", what, " is not ported yet")); }

// UnrollLoopOptions
struct UnrollLoopOpts { count: i64, force: bool, allow_expensive_trip_count: bool, unroll_remainder: bool, runtime: bool,
             forget_all_scev: bool, heart: i32, scev_budget: i64, runtime_multi_exit: bool, add_accumulators: bool }

// ---------------------------------------------------------------------------------------------
// Loop helpers

// Loop::isSafeToClone
fn loop_is_safe_to_clone(l: i32) -> bool {
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if iop(block_terminator(bb)) == OP_INDIRECTBR { return false; }
        var i = block_first(bb);
        while i >= 0 {
            if is_callbase(i) && call_has_fn_attr(i, AK_NoDuplicate) { return false; }
            i = inst_next(i);
        }
    }
    return true;
}

var ul_dfs_seen = hm_new();
// LoopBlocksDFS::perform(LI): the postorder of the loop's blocks from the header (successors in order;
// a successor is visited when its innermost loop is contained in l)
fn loop_blocks_dfs_post(l: i32, post: i32[>..<]&) {
    hm_clear(ul_dfs_seen);
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    let h = loop_header(l);
    hm_put(ul_dfs_seen, h as u64, 1);
    st_b.push(h);
    st_k.push(0);
    while st_b.len > 0 {
        let top = st_b.len - 1;
        let b = st_b[top];
        let k = st_k[top];
        if k < block_nsucc(b) {
            st_k[top] = k + 1;
            let s = block_succ(b, k);
            let sl = li_loop_for(s);
            if sl >= 0 && loop_contains_loop(l, sl) && !hm_has(ul_dfs_seen, s as u64) {
                hm_put(ul_dfs_seen, s as u64, 1);
                st_b.push(s);
                st_k.push(0);
            }
        } else {
            post.push(b);
            st_b.pop();
            st_k.pop();
        }
    }
}
fn loop_blocks_rpo(l: i32, out: i32[>..<]&) {
    var post: i32[>..<] = [];
    loop_blocks_dfs_post(l, post);
    var i = post.len;
    while i > 0 { i--; out.push(post[i]); }
}

// LoopInfo::removeLoop(I) for a top-level loop
fn li_remove_top_level_loop(fv: i32, l: i32) {
    let g = glob_of(fv);
    let r = li_heads[g].top;
    var w: i64 = 0;
    for k in r.n { let x = lrun_get(r, k); if x != l { li_pool[r.at + w] = x; w++; } }
    li_heads[g].top.n = w as i32;
}

// LoopInfo::erase(Unloop)
fn li_erase_loop(ul: i32) {
    let fv = loops[ul].fv;
    if loop_parent(ul) < 0 {
        for k in loop_nblocks(ul) {
            let bb = loop_block(ul, k);
            if li_loop_for(bb) != ul { continue; }
            li_change_loop_for(bb, -1);
        }
        li_remove_top_level_loop(fv, ul);
        while !loop_is_innermost(ul) {
            let c = loop_sub(ul, loop_nsubs(ul) - 1);
            loop_remove_child(ul, c);
            li_add_top_level_loop(fv, c);
        }
        li_destroy_loop(ul);
        return;
    }
    // UnloopUpdater
    var sp_k: i32[>..<] = [];      // SubloopParents keys
    var sp_v: i32[>..<] = [];
    fn sp_find(x: i32) -> i64 { for j in sp_k.len { if sp_k[j] == x { return j; } } return -1; }
    var found_ib = false;
    var post: i32[>..<] = [];
    // getNearestLoop(BB, BBLoop)
    fn nearest_loop(bb: i32, bbl: i32) -> i32 {
        var near = bbl;
        var sub: i32 = -1;
        if near != ul && loop_contains_loop(ul, near) {
            sub = near;
            while loop_parent(sub) != ul { sub = loop_parent(sub); }
            var j = sp_find(sub);
            if j < 0 { sp_k.push(sub); sp_v.push(ul); j = sp_k.len - 1; }
            near = sp_v[j];
        }
        if block_nsucc(bb) == 0 { near = -1; }
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if s == bb { continue; }
            var l2 = li_loop_for(s);
            if l2 == ul { found_ib = true; }
            if l2 != ul && loop_contains_loop(ul, l2) {
                if sub >= 0 { continue; }
                let j = sp_find(l2);
                if j < 0 { sp_k.push(l2); sp_v.push(-1); l2 = -1; } else { l2 = sp_v[j]; }
            }
            if l2 == ul { continue; }
            if l2 >= 0 && !loop_contains_loop(l2, ul) { l2 = loop_parent(l2); }
            if near == ul || near < 0 || loop_contains_loop(near, l2) { near = l2; }
        }
        if sub >= 0 {
            let j = sp_find(sub);
            sp_v[j] = near;
            return bbl;
        }
        return near;
    }
    // updateBlockParents
    if loop_nblocks(ul) > 0 {
        loop_blocks_dfs_post(ul, post);
        for b in post {
            let l2 = li_loop_for(b);
            let nl = nearest_loop(b, l2);
            if nl != l2 { li_change_loop_for(b, nl); }
        }
    }
    var changed = found_ib;
    while changed {
        changed = false;
        for b in post {
            let l2 = li_loop_for(b);
            let nl = nearest_loop(b, l2);
            if nl != l2 { li_change_loop_for(b, nl); changed = true; }
        }
    }
    // removeBlocksFromAncestors
    var blocks: i32[>..<] = [];
    for k in loop_nblocks(ul) { blocks.push(loop_block(ul, k)); }
    for bb in blocks {
        var op_ = li_loop_for(bb);
        if loop_contains_loop(ul, op_) {
            while loop_parent(op_) != ul { op_ = loop_parent(op_); }
            let j = sp_find(op_);
            if j < 0 { sp_k.push(op_); sp_v.push(-1); op_ = -1; } else { op_ = sp_v[j]; }
        }
        var old = loop_parent(ul);
        while old != op_ {
            if old < 0 { fatal("internal: LoopInfo::erase: new loop is not an ancestor of the original"); }
            loop_remove_block_from_loop(old, bb);
            old = loop_parent(old);
        }
    }
    // updateSubloopParents
    while !loop_is_innermost(ul) {
        let sub = loop_sub(ul, loop_nsubs(ul) - 1);
        loop_remove_child(ul, sub);
        let j = sp_find(sub);
        if j < 0 { fatal("internal: LoopInfo::erase: DFS failed to visit subloop"); }
        let p = sp_v[j];
        if p >= 0 { loop_add_child(p, sub); } else { li_add_top_level_loop(fv, sub); }
    }
    let parent = loop_parent(ul);
    loop_remove_child(parent, ul);
    li_destroy_loop(ul);
}
// LoopInfo::destroy: the loop is invalid from now on
fn li_destroy_loop(l: i32) {
    loops[l].blocks.n = 0;
    loops[l].subs.n = 0;
    loops[l].parent = -1;
}

// needToInsertPhisForLCSSA(L, Blocks, LI)
fn need_to_insert_phis_for_lcssa(l: i32, bbs: const i32[:]) -> bool {
    for bb in bbs {
        if li_loop_for(bb) == l { continue; }
        var i = block_first(bb);
        while i >= 0 {
            for k in nops(i) {
                let d = op(i, k);
                if d >= 0 && is_inst(d) {
                    let dl = li_loop_for(inst_parent(d));
                    if dl < 0 { continue; }
                    if loop_contains_loop(dl, l) { return true; }
                }
            }
            i = inst_next(i);
        }
    }
    return false;
}

// addClonedBlockToLoopInfo(OriginalBB, ClonedBB, LI, NewLoops): NewLoops is the pair list (nl_o, nl_n);
// returns the original loop if a new loop was created, else -1
fn add_cloned_block_to_loop_info(obb: i32, cbb: i32, nl_o: i32[>..<]&, nl_n: i32[>..<]&) -> i32 {
    let fv = block_func(obb);
    let old = li_loop_for(obb);
    var j: i64 = -1;
    for k in nl_o.len { if nl_o[k] == old { j = k; } }
    if j < 0 {
        let nl = li_allocate_loop(fv);
        nl_o.push(old);
        nl_n.push(nl);
        var np: i32 = -1;
        let op_ = loop_parent(old);
        for k in nl_o.len { if nl_o[k] == op_ && op_ >= 0 { np = nl_n[k]; } }
        if np >= 0 { loop_add_child(np, nl); } else { li_add_top_level_loop(fv, nl); }
        loop_add_basic_block_to_loop(nl, cbb);
        return old;
    }
    loop_add_basic_block_to_loop(nl_n[j], cbb);
    return -1;
}

// isEpilogProfitable(L)
fn is_epilog_profitable(l: i32) -> bool {
    let ph = loop_preheader(l);
    var p = block_first(loop_header(l));
    while p >= 0 && iop(p) == OP_PHI {
        if vals[phi_value_for_block(p, ph)].kind == VK_CINT { return true; }
        p = inst_next(p);
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// loadCSE

struct ULLCEnt { key: i32, defi: i32, gen: i64, shadow: i64 }
struct ULLCNode { bb: i32, cur_gen: i64, child_gen: i64, child: i32, processed: bool, scope_mark: i64 }

fn load_cse(l: i32) {
    let fv = block_func(loop_header(l));
    var ents: ULLCEnt[>..<] = [];
    var nodes: ULLCNode[>..<] = [];
    fn lookup(key: i32) -> i64 {
        var k = ents.len;
        while k > 0 { k--; if ents[k].key == key { return k; } }
        return -1;
    }
    let h = loop_header(l);
    nodes.push(ULLCNode { bb: h, cur_gen: 0, child_gen: 0, child: dt_first_child(fv, DT_DOM, h), processed: false, scope_mark: 0 });
    var cur_gen: i64 = 0;
    while nodes.len > 0 {
        let t = nodes.len - 1;
        cur_gen = nodes[t].cur_gen;
        if !nodes[t].processed {
            let bb = nodes[t].bb;
            if single_pred(bb) < 0 { cur_gen++; }
            var i = block_first(bb);
            while i >= 0 {
                let nx = inst_next(i);
                if iop(i) != OP_LOAD || !ul_is_simple_load(i) {
                    if inst_may_write_memory(i) { cur_gen++; }
                    i = nx;
                    continue;
                }
                let ps = sc_get_scev(op(i, 0));
                let e = lookup(ps);
                var m: i32 = -1;
                if e >= 0 {
                    let lv = ents[e];
                    if lv.defi >= 0 && !is_dead(lv.defi) && vals[lv.defi].ty == vals[i].ty {
                        if lv.gen != cur_gen { ul_not_ported("loadCSE across generations (MemorySSA(Loop&))"); }
                        m = lv.defi;
                    }
                }
                if m >= 0 {
                    if lr_replacement_preserves_lcssa(i, m) {
                        rauw(i, m);
                        inst_erase_from_parent(i);
                    }
                } else {
                    ents.push(ULLCEnt { key: ps, defi: i, gen: cur_gen, shadow: -1 });
                }
                i = nx;
            }
            nodes[t].child_gen = cur_gen;
            nodes[t].processed = true;
        } else if nodes[t].child >= 0 {
            let c = nodes[t].child;
            nodes[t].child = dt_next_sibling(DT_DOM, c);
            if !loop_contains(l, c) { continue; }
            nodes.push(ULLCNode { bb: c, cur_gen: nodes[t].child_gen, child_gen: nodes[t].child_gen, child: dt_first_child(fv, DT_DOM, c),
                                processed: false, scope_mark: ents.len });
        } else {
            ents.resize(nodes[t].scope_mark);
            nodes.pop();
        }
    }
}
// LoadInst::isSimple
fn ul_is_simple_load(i: i32) -> bool { (insts[inst_of(i)].bits & 1) == 0 && insts[inst_of(i)].ord == 0 }

// ---------------------------------------------------------------------------------------------
// simplifyLoopAfterUnroll

// RecursivelyDeleteTriviallyDeadInstructions(V) for one value (TLI = nullptr)
fn ul_delete_dead_inst(v: i32) {
    if v < 0 || is_dead(v) || !is_inst(v) { return; }
    if !is_instruction_trivially_dead(v) { return; }
    var one: i32[>..<] = [];
    one.push(v);
    recursively_delete_trivially_dead(one);
}

fn simplify_loop_after_unroll(l: i32, simplify_ivs: bool, bbs: const i32[:], use_aa: bool) {
    let save_tli = local_have_tli;
    local_have_tli = false;
    if simplify_ivs && l >= 0 {
        let wm = wvh_mark();
        let dm = iv_dead.len;
        sx_begin("indvars", true);
        var p = block_first(loop_header(l));
        while p >= 0 && iop(p) == OP_PHI {
            let c, un = simplify_users_of_iv(p, false);
            p = inst_next(p);
        }
        while iv_dead.len > dm {
            let hdl = iv_dead.pop();
            let v = wvh_get(hdl);
            if v >= 0 && is_inst(v) { ul_delete_dead_inst(v); }
        }
        sx_end();
        wvh_release(wm);
        if use_aa { load_cse(l); }
    }
    let fv = block_func(bbs[0]);
    let has_sp = func_subprogram(fv) >= 0;
    for bb in bbs {
        if has_sp { remove_redundant_dbg_instrs(bb); }
        var dead: i32[>..<] = [];
        var i = block_first(bb);
        while i >= 0 {
            let nx = inst_next(i);
            let a = sq_no_tli; let b = sq_no_dt; let c = sq_no_ac; let d = dc_active;
            sq_no_tli = true; sq_no_dt = false; sq_no_ac = false; dc_active = false;
            let v = simplify_instruction(i);
            sq_no_tli = a; sq_no_dt = b; sq_no_ac = c; dc_active = d;
            if v >= 0 && lr_replacement_preserves_lcssa(i, v) { ac_rauw(i, v); rauw(i, v); }
            if is_instruction_trivially_dead(i) { dead.push(i); }
            // Fold ((add X, C1), C2) to (add X, C1+C2)
            if iop(i) == OP_ADD && vals[op(i, 1)].kind == VK_CINT && is_inst_op(op(i, 0), OP_ADD) &&
               vals[op(op(i, 0), 1)].kind == VK_CINT && !ty_is_vector(vals[i].ty) {
                let inner = op(i, 0);
                let x = op(inner, 0);
                let c1 = ci_ap(op(inner, 1));
                let c2 = ci_ap(op(i, 1));
                let nc = ap_add(c1, c2);
                let ov = ap_sadd_overflows(c1, c2);
                let inuw = has_flag(inner, FL_NUW);
                let insw = has_flag(inner, FL_NSW);
                set_op(i, 0, x);
                set_op(i, 1, ap_to_cint(vals[i].ty, nc));
                let ii = inst_of(i);
                let nuw = has_flag(i, FL_NUW) && inuw;
                let nsw = has_flag(i, FL_NSW) && insw && !ov;
                if nuw { insts[ii].flags |= FL_NUW; } else { insts[ii].flags &= ~FL_NUW; }
                if nsw { insts[ii].flags |= FL_NSW; } else { insts[ii].flags &= ~FL_NSW; }
                if is_instruction_trivially_dead(inner) { dead.push(inner); }
            }
            i = nx;
        }
        recursively_delete_trivially_dead(dead);
    }
    local_have_tli = save_tli;
}
// APInt::sadd_ov
fn ap_sadd_overflows(a: AP, b: AP) -> bool {
    let r = ap_add(a, b);
    let w = a.w as i64;
    let sa = ap_get_bit(a, w - 1);
    let sb = ap_get_bit(b, w - 1);
    let sr = ap_get_bit(r, w - 1);
    return sa == sb && sr != sa;
}
// Function::getSubprogram (the !dbg attachment of the function)
fn func_subprogram(fv: i32) -> i32 {
    let g = glob_of(fv);
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == 0 { return md_att[globs[g].md + 2 * j + 1]; } }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// fixProbContradiction

fn fix_prob_contradiction(l: i32, runtime: bool, orig_prob: u32, complete: bool, iter_counts: i64[>..<]&,
                          cond_latches: i32[>..<]&, cond_latch_nexts: i32[>..<]&) {
    if runtime { return; }
    if cond_latches.len == 0 { return; }
    if orig_prob == (BP_D as u32) { return; }
    let freq_desired = 1.0 / (1.0 - bp_to_double(orig_prob));
    fn get_prob(k: i64) -> f64 {
        let b = block_terminator(cond_latches[k]);
        let first = term_succ(b, 0) == cond_latch_nexts[k];
        return bp_to_double(lmd_branch_probability(b, first));
    }
    fn set_prob(k: i64, p: f64) {
        let b = block_terminator(cond_latches[k]);
        let first = term_succ(b, 0) == cond_latch_nexts[k];
        lmd_set_branch_probability(b, bp_from_double(p), first);
    }
    fn clamp(p: f64) -> f64 { var x = p; if x < 0.0 { x = 0.0; } if x > 1.0 { x = 1.0; } return x; }
    let freq_prec = 0.000001;
    let n = cond_latches.len;
    if n == 1 {
        let a = (iter_counts[1] as f64) + (if complete { 0.0 } else { freq_desired });
        let b = (iter_counts[0] as f64) - freq_desired;
        let p = clamp(-b / a);
        set_prob(0, p);
    } else if n == 2 {
        let a = (iter_counts[2] as f64) + (if complete { 0.0 } else { freq_desired });
        let b = iter_counts[1] as f64;
        let c = (iter_counts[0] as f64) - freq_desired;
        let p = clamp((-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a));
        for k in 2 { set_prob(k, p); }
    } else {
        var pb = -1.0;
        var pa = -1.0;
        var fb = -1.0;
        var fa = -1.0;
        for ci in n {
            // AdjustProb(ComputeIdx = ci)
            fn compute_after() {
                pa = 1.0;
                fa = iter_counts[ci + 1] as f64;
                var k = ci + 1;
                while k < n {
                    let p = get_prob(k);
                    pa *= p;
                    if p == 0.0 { break; }
                    fa += (iter_counts[k + 1] as f64) * pa;
                    k++;
                }
            }
            if ci == 0 {
                pb = 1.0;
                fb = iter_counts[0] as f64;
                compute_after();
            } else {
                let pold = get_prob(ci);
                if pold > 0.0 {
                    fa -= (iter_counts[ci] as f64) * pb;
                    pa /= pold;
                    fa /= pold;
                } else {
                    compute_after();
                }
                pb *= get_prob(ci - 1);
                fb += (iter_counts[ci] as f64) * pb;
            }
            let prb = if complete { 0.0 } else { pb * pa };
            let num = freq_desired - fb;
            let den = fa + freq_desired * prb;
            var pc = -1.0;
            if num <= 0.0 { pc = 0.0; }
            else if den == 0.0 { pc = 1.0; }
            else { pc = clamp(num / den); }
            set_prob(ci, pc);
            var fc = -1.0;
            if prb * pc == 1.0 { fc = 1.0e308 * 10.0; }
            else { fc = (fb + fa * pc) / (1.0 - prb * pc); }
            if abs(fc - freq_desired) < freq_prec { break; }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// CFG helpers

// DomTreeNode::setIDom (no DFS-number invalidation)
fn ul_dt_set_idom(fv: i32, bb: i32, idom: i32) { dt_focus(fv, DT_DOM); t_set_idom(bb, idom); }
fn ul_dt_children(fv: i32, bb: i32, out: i32[>..<]&) {
    var c = dt_first_child(fv, DT_DOM, bb);
    while c >= 0 { out.push(c); c = dt_next_sibling(DT_DOM, c); }
}

// changeToUnreachable(I, PreserveLCSSA) without DTU / MSSAU
fn ul_change_to_unreachable(iv: i32, preserve_lcssa: bool) -> i64 {
    let bb = inst_parent(iv);
    let t = block_terminator(bb);
    var succs: i32[>..<] = [];
    for k in term_nsucc(t) { succs.push(term_succ(t, k)); }
    for s in succs { block_remove_predecessor(s, bb, preserve_lcssa); }
    let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
    inst_insert_before(ui, iv);
    let dl = inst_get_md(iv, 0);
    if dl >= 0 { inst_set_md(ui, 0, dl); }
    var n: i64 = 0;
    var i = iv;
    while i >= 0 {
        let ni = inst_next(i);
        if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
        inst_erase_from_parent(i);
        n++;
        i = ni;
    }
    block_flush_terminator_records(bb);
    return n;
}

// MergeBlockIntoPredecessor(BB, DTU, LI, MSSAU = null, MemDep = null, PredecessorWithTwoSuccessors = false, DT):
// use_dtu = the active (lazy) DomTreeUpdater, else the DT is updated directly
fn ul_merge_block_into_predecessor(bb: i32, use_dtu: bool) -> bool {
    let fv = block_func(bb);
    if cu_has_address_taken(bb) { return false; }
    let pred = cu_unique_pred(bb);
    if pred < 0 || pred == bb { return false; }
    let pti = block_terminator(pred);
    if cu_is_special_terminator(pti) || inst_may_have_side_effects(pti) { return false; }
    if cu_unique_succ(pred) != bb { return false; }
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op(i, k) == i { return false; } }
        i = inst_next(i);
    }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(pred) { return false; }
    if cu_has_phis(bb) { cu_fold_single_entry_phis(bb); }
    if !use_dtu {
        if dt_has_node(DT_DOM, pred) {
            var ch: i32[>..<] = [];
            ul_dt_children(fv, bb, ch);
            for c in ch { ul_dt_set_idom(fv, c, pred); }
        }
    }
    var ups: DTUpdate[>..<] = [];
    if use_dtu {
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
    block_splice(pred, pti, false, bb, block_first(bb), true, sti, false);
    cu_block_rauw(bb, pred);
    inst_erase_from_parent(pti);
    inst_move_impl(sti, pred, -1, false, true);
    block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
    if vals[pred].name < 0 && vals[bb].name >= 0 { cu_take_name(pred, bb); }
    li_remove_block(bb);
    if use_dtu { dtu_apply_updates(ups); }
    if !use_dtu { dt_erase_node(fv, DT_DOM, bb); }
    let save = cu_dtu;
    cu_dtu = use_dtu;
    cu_delete_dead_block(bb);
    cu_dtu = save;
    return true;
}

// ---------------------------------------------------------------------------------------------
// UnrollLoop

struct ULExitInfo { exiting: i32, trip_count: i64, trip_multiple: i64, breakout_trip: i64, exit_on_true: bool, first_exiting: i32, eb_at: i64 }

fn ul_gcd(a: i64, b: i64) -> i64 { var x = a; var y = b; while y != 0 { let t = x % y; x = y; y = t; } return x; }

// UnrollLoop(L, UnrollLoopOpts, LI, SE, DT, AC, TTI, ORE, PreserveLCSSA, RemainderLoop, AA): (result, remainder loop)
fn unroll_loop(l0: i32, ulo0: UnrollLoopOpts, preserve_lcssa: bool, use_aa: bool) -> i64, i32 {
    var l = l0;
    var ulo = ulo0;
    var remainder: i32 = -1;
    if loop_preheader(l) < 0 { return 0, -1; }
    if loop_latch(l) < 0 { return 0, -1; }
    if !loop_is_safe_to_clone(l) { return 0, -1; }
    if cu_has_address_taken(loop_header(l)) { return 0, -1; }
    let preheader = loop_preheader(l);
    let header = loop_header(l);
    let latch_block = loop_latch(l);
    let fv = block_func(header);
    var exit_blocks: i32[>..<] = [];
    loop_exit_blocks(l, exit_blocks);
    var orig_blocks: i32[>..<] = [];
    for k in loop_nblocks(l) { orig_blocks.push(loop_block(l, k)); }
    let max_trip_count = sc_get_small_constant_max_trip_count(l);
    let max_or_zero = sc_is_backedge_taken_count_max_or_zero(l);
    let has_otc, otc = get_loop_estimated_trip_count(l);
    let orig_prob = get_loop_probability(l);
    if max_trip_count != 0 && ulo.count > max_trip_count { ulo.count = max_trip_count; }
    // ExitInfos (MapVector by exiting block); ExitingBlocks of each info are runs in xbs
    var infos: ULExitInfo[>..<] = [];
    var xbs: i32[>..<] = [];          // per info: Count slots (orig + one per iteration)
    var xbn: i64[>..<] = [];          // number used per info
    var exiting: i32[>..<] = [];
    loop_exiting_blocks(l, exiting);
    for eb in exiting {
        let bi = block_terminator(eb);
        if iop(bi) != OP_CONDBR { continue; }
        var tc = sc_constant_trip_count(sc_get_exit_count(l, eb, BTC_EXACT, false));
        var tm = sc_trip_multiple_of_exit_count(l, sc_get_exit_count(l, eb, BTC_EXACT, false));
        var bt: i64 = 0;
        if tc != 0 { bt = tc % ulo.count; tm = 0; }
        else { tm = ul_gcd(ulo.count, tm); bt = tm; }
        infos.push(ULExitInfo { exiting: eb, trip_count: tc, trip_multiple: tm, breakout_trip: bt,
                              exit_on_true: !loop_contains(l, term_succ(bi, 0)), first_exiting: -1, eb_at: xbs.len });
        for k in ulo.count { xbs.push(-1); }
        xbs[xbs.len - ulo.count] = eb;
        xbn.push(1);
    }
    fn info_of(bb: i32) -> i64 { for k in infos.len { if infos[k].exiting == bb { return k; } } return -1; }
    let complete = ulo.count == max_trip_count;
    let preserve_only_first = complete && max_or_zero;
    if complete { ulo.runtime = false; }
    var need_fix_lcssa = false;
    if preserve_lcssa && complete {
        for e in exit_blocks { if iop(block_first(e)) == OP_PHI { need_fix_lcssa = true; } }
    }
    let latch_term = block_terminator(latch_block);
    let latch_is_exiting = loop_is_exiting(l, latch_block);
    if iop(latch_term) != OP_BR && !(iop(latch_term) == OP_CONDBR && latch_is_exiting) { return 0, -1; }
    let epilog_prof = if flag_given("unroll-runtime-epilog") { flag_bool("unroll-runtime-epilog", false) } else { is_epilog_profitable(l) };
    if ulo.runtime {
        let ok, rl = unroll_runtime_loop_remainder(l, ulo.count, ulo.allow_expensive_trip_count, epilog_prof, ulo.unroll_remainder,
                                                   ulo.forget_all_scev, preserve_lcssa, ulo.scev_budget, ulo.runtime_multi_exit,
                                                   has_otc, otc, orig_prob);
        if ok { remainder = rl; }
        else {
            if ulo.force { ulo.runtime = false; } else { return 0, -1; }
        }
    }
    if func_subprogram(fv) >= 0 && di_debug_info_for_profiling(func_subprogram(fv)) { ul_not_ported("FS discriminators (debug-info-for-profiling)"); }
    if scev_valid(fv) {
        if ulo.forget_all_scev { ul_not_ported("ScalarEvolution::forgetAllLoops"); }
        sc_forget_topmost_loop(l);
        sc_forget_block_and_loop_dispositions_all();
    }
    let lvm = vmm_new();     // LastValueMap
    var orig_phis: i32[>..<] = [];
    var p = block_first(header);
    while p >= 0 && iop(p) == OP_PHI { orig_phis.push(p); p = inst_next(p); }
    if ulo.add_accumulators || (flag_given("unroll-add-parallel-reductions") && flag_bool("unroll-add-parallel-reductions", false)) {
        let can = !complete && loop_nblocks(l) == 1;
        if can { ul_not_ported("parallel reduction phis"); }
    }
    var headers: i32[>..<] = [];
    var latches: i32[>..<] = [];
    headers.push(header);
    latches.push(latch_block);
    var rpo: i32[>..<] = [];
    loop_blocks_rpo(l, rpo);
    var unrolled_blocks: i32[>..<] = [];
    for k in loop_nblocks(l) { unrolled_blocks.push(loop_block(l, k)); }
    var to_simplify: i32[>..<] = [];
    for k in loop_nsubs(l) { to_simplify.push(loop_sub(l, k)); }
    var scopes: i32[>..<] = [];
    identify_noalias_scopes_to_clone(orig_blocks, scopes);
    let insert_pt = block_next(latch_block);
    for it in 1..ulo.count {
        var new_blocks: i32[>..<] = [];
        var nl_o: i32[>..<] = [];
        var nl_n: i32[>..<] = [];
        nl_o.push(l);
        nl_n.push(l);
        var suffix: u8[>..] = [];
        format(suffix, ".", it);
        for bb in rpo {
            let vmark = vmm_mark();
            let vm = vmm_new();
            let nb = clone_basic_block_insert(bb, vm, suffix, insert_pt, false);
            let oldl = add_cloned_block_to_loop_info(bb, nb, nl_o, nl_n);
            if oldl >= 0 {
                for k in nl_o.len { if nl_o[k] == oldl && position(to_simplify, nl_n[k]) < 0 { to_simplify.push(nl_n[k]); } }
            }
            if bb == header {
                for op_ in orig_phis {
                    let np = vmm_get(vm, op_);
                    var inv = phi_value_for_block(np, latch_block);
                    if is_inst(inv) && it > 1 && loop_contains(l, inst_parent(inv)) { inv = vmm_get(lvm, inv); }
                    vmm_set(vm, op_, inv);
                    inst_erase_from_parent(np);
                }
                if ulo.heart >= 0 {
                    let hc = vmm_get(vm, ulo.heart);
                    inst_erase_from_parent(hc);
                    vmm_erase(vm, ulo.heart);
                }
            }
            vmm_set(lvm, bb, nb);
            vmm_copy_into(lvm, vm);
            let t = block_terminator(bb);
            for k in term_nsucc(t) {
                let s = term_succ(t, k);
                if loop_contains(l, s) { continue; }
                var q = block_first(s);
                while q >= 0 && iop(q) == OP_PHI {
                    var inc = phi_value_for_block(q, bb);
                    if vmm_has(lvm, inc) { inc = vmm_get(lvm, inc); }
                    phi_add_incoming(q, inc, nb);
                    sc_forget_lcssa_phi_with_new_predecessor(l, q);
                    q = inst_next(q);
                }
            }
            if bb == header { headers.push(nb); }
            if bb == latch_block { latches.push(nb); }
            let ei = info_of(bb);
            if ei >= 0 { xbs[infos[ei].eb_at + xbn[ei]] = nb; xbn[ei] = xbn[ei] + 1; }
            new_blocks.push(nb);
            unrolled_blocks.push(nb);
            if bb == header { dt_add_new_block(fv, DT_DOM, nb, latches[it - 1]); }
            else {
                let idom = dt_idom(DT_DOM, bb);
                dt_add_new_block(fv, DT_DOM, nb, vmm_get(lvm, idom));
            }
            vmm_release(vmark);
        }
        remap_instructions_in_blocks(new_blocks, lvm);
        for nb in new_blocks {
            var i = block_first(nb);
            while i >= 0 { if inst_iid(i) == IID_assume { ac_register_assumption(i); } i = inst_next(i); }
        }
        var ext: u8[>..] = [];
        format(ext, "It", it);
        clone_and_adapt_noalias_scopes(scopes, new_blocks, ext);
    }
    for pn in orig_phis {
        if complete {
            sc_forget_value(pn);
            let v = phi_value_for_block(pn, preheader);
            ac_rauw(pn, v);
            rauw(pn, v);
            inst_erase_from_parent(pn);
        } else if ulo.count > 1 {
            var inv = phi_remove_incoming_block(pn, latch_block, false);
            if is_inst(inv) && loop_contains(l, inst_parent(inv)) { inv = vmm_get(lvm, inv); }
            phi_add_incoming(pn, inv, latches[latches.len - 1]);
        }
    }
    let ne = latches.len;
    for k in ne {
        let j = (k + 1) % ne;
        term_replace_successor_with(block_terminator(latches[k]), headers[k], headers[j]);
    }
    let nrm = if complete { ne } else { ne - 1 };
    for k in nrm { inst_set_md(block_terminator(latches[k]), MDK_LOOP, -1); }
    if ulo.count > 1 {
        for bb in orig_blocks {
            var ch: i32[>..<] = [];
            ul_dt_children(fv, bb, ch);
            var upd: i32[>..<] = [];
            for c in ch { if !loop_contains(l, c) { upd.push(c); } }
            let nidom = dt_find_ncd(DT_DOM, bb, latch_block);
            for c in upd { dt_change_idom(fv, DT_DOM, c, nidom); }
        }
    }
    var dt_ups: DTUpdate[>..<] = [];
    fn set_dest(src: i32, will_exit: bool, exit_on_true: bool) {
        let term = block_terminator(src);
        let idx: i64 = if exit_on_true != will_exit { 1 } else { 0 };
        let dest = term_succ(term, idx);
        let dead = term_succ(term, 1 - idx);
        block_remove_predecessor(dead, src, true);
        let br = create_inst(OP_BR, T_VOID, [dest]);
        inst_insert_before(br, term);
        let dl = inst_get_md(term, 0);
        if dl >= 0 { inst_set_md(br, 0, dl); }
        inst_erase_from_parent(term);
        dt_ups.push(DTUpdate { kind: DT_DELETE, from: src, to: dead });
    }
    // WillExit: 0 = false, 1 = true, -1 = std::nullopt
    fn will_exit(ei: i64, i: i64, j: i64, is_latch: bool) -> i64 {
        if complete {
            if preserve_only_first {
                if i == 0 { return -1; }
                return if j == 0 { 1 } else { 0 };
            }
            if j == 0 { return 1; }
            if infos[ei].trip_count != 0 && j != infos[ei].trip_count { return 0; }
            return -1;
        }
        if ulo.runtime {
            if is_latch && j != 0 { return 0; }
            return -1;
        }
        if j != infos[ei].breakout_trip && (infos[ei].trip_multiple == 0 || j % infos[ei].trip_multiple != 0) { return 0; }
        return -1;
    }
    var prob_update = false;
    for ei in infos.len {
        let e = xbn[ei];
        for i in e {
            let j = (i + 1) % e;
            let is_latch = infos[ei].exiting == latch_block;
            let kw = will_exit(ei, i, j, is_latch);
            if kw < 0 {
                if infos[ei].first_exiting < 0 { infos[ei].first_exiting = xbs[infos[ei].eb_at + i]; }
                continue;
            }
            if kw == 1 && !is_latch {
                if infos[ei].first_exiting < 0 { infos[ei].first_exiting = xbs[infos[ei].eb_at + i]; }
                continue;
            }
            if orig_prob != 0xFFFFFFFF && is_latch {
                let actual: u32 = if kw == 1 { 0 } else { BP_D as u32 };
                if orig_prob != actual { prob_update = true; }
            }
            set_dest(xbs[infos[ei].eb_at + i], kw == 1, infos[ei].exit_on_true);
        }
    }
    dtu_begin(fv, true, false, true);
    var use_dtu = true;
    if exiting.len == 1 && infos.len == 1 {
        use_dtu = false;
        if infos[0].first_exiting < 0 { infos[0].first_exiting = xbs[infos[0].eb_at + xbn[0] - 1]; }
        var ch: i32[>..<] = [];
        ul_dt_children(fv, infos[0].exiting, ch);
        for c in ch {
            if loop_contains(l, c) { continue; }
            ul_dt_set_idom(fv, c, infos[0].first_exiting);
        }
    } else {
        dtu_apply_updates(dt_ups);
    }
    if !latch_is_exiting && complete {
        ul_change_to_unreachable(block_terminator(latches[latches.len - 1]), preserve_lcssa);
    }
    var iter_counts: i64[>..<] = [];
    iter_counts.push(0);
    var cond_latches: i32[>..<] = [];
    var cond_nexts: i32[>..<] = [];
    for k in latches.len {
        let latch = latches[k];
        iter_counts[iter_counts.len - 1] = iter_counts[iter_counts.len - 1] + 1;
        let term = block_terminator(latch);
        if iop(term) == OP_BR {
            let dest = term_succ(term, 0);
            let fold = cu_unique_pred(dest);
            if ul_merge_block_into_predecessor(dest, use_dtu) {
                for j in latches.len { if latches[j] == dest { latches[j] = fold; } }
                var w: i64 = 0;
                for j in unrolled_blocks.len { if unrolled_blocks[j] != dest { unrolled_blocks[w] = unrolled_blocks[j]; w++; } }
                unrolled_blocks.resize(w);
            }
        } else if iop(term) == OP_CONDBR {
            iter_counts.push(0);
            cond_latches.push(latch);
            cond_nexts.push(headers[(k + 1) % latches.len]);
        }
    }
    if prob_update {
        fix_prob_contradiction(l, ulo.runtime, orig_prob, complete, iter_counts, cond_latches, cond_nexts);
    }
    if use_dtu { dtu_get_dt(); }
    let outer = loop_parent(l);
    var blocks: i32[>..<] = [];
    if complete {
        for k in loop_nblocks(l) { blocks.push(loop_block(l, k)); }
        li_erase_loop(l);
        l = -1;
    } else {
        for k in loop_nblocks(l) { blocks.push(loop_block(l, k)); }
    }
    dtu_end();
    simplify_loop_after_unroll(l, !complete && ulo.count > 1, blocks, use_aa);
    if !complete {
        if orig_prob != 0xFFFFFFFF && ulo.runtime && epilog_prof {
            set_loop_probability(l, bp_pow(orig_prob, ulo.count));
        }
        if has_otc {
            var ntc = (otc as i64) / ulo.count;
            if !ulo.runtime && (otc as i64) % ulo.count != 0 { ntc++; }
            set_loop_estimated_trip_count(l, ntc as u64, false, 0);
        }
    }
    if preserve_lcssa && outer >= 0 && complete && !need_fix_lcssa {
        need_fix_lcssa = need_to_insert_phis_for_lcssa(outer, unrolled_blocks);
    }
    let save_ls = ls_se;
    let save_lc = lcssa_se;
    ls_se = scev_valid(fv);
    lcssa_se = scev_valid(fv);
    if outer >= 0 {
        if need_fix_lcssa {
            let ll = li_loop_for(latches[latches.len - 1]);
            var fl = outer;
            if !loop_contains_loop(fl, ll) {
                while loop_parent(fl) != ll { fl = loop_parent(fl); }
            }
            form_lcssa_recursively(fl);
        }
        simplify_loop(outer, preserve_lcssa);
    } else {
        for sl in to_simplify { simplify_loop(sl, preserve_lcssa); }
    }
    ls_se = save_ls;
    lcssa_se = save_lc;
    return if complete { 2 } else { 1 }, remainder;
}

// DICompileUnit::getDebugInfoForProfiling of a subprogram's unit
fn di_debug_info_for_profiling(sp: i32) -> bool {
    if mds[sp].kind != MK_DI { return false; }
    let u = di_slot(sp, "unit");
    if u < 0 || mds[u].kind != MK_DI { return false; }
    return di_int(u, "debugInfoForProfiling") != 0;
}
