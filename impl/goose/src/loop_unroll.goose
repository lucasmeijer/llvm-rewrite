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
import aa;
import memoryssa;
import mssaupdater;
import loop_unroll_runtime;
import unroll_utils;

fn ul_not_ported(what: const u8[:]) { fatal(str("LoopUnroll: ", what, " is not ported yet")); }

// UnrollLoopOptions
struct UnrollLoopOpts { count: i64, force: bool, allow_expensive_trip_count: bool, unroll_remainder: bool, runtime: bool,
             forget_all_scev: bool, heart: i32, scev_budget: i64, runtime_multi_exit: bool, add_accumulators: bool }

// ---------------------------------------------------------------------------------------------
// Loop helpers





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
    var have_mssa = false;
    let baa = aq_push(CA_SIMPLE);
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
                        if lv.gen != cur_gen {
                            // getMatchingValue: the loop's MemorySSA, built on first use
                            if !have_mssa { mssa_build_loop(l); have_mssa = true; }
                            let earlier = mssa_access_of(lv.defi);
                            let later = mssa_get_clobbering(mssa_access_of(i), baa);
                            if mssa_dominates(later, earlier) { m = lv.defi; }
                        } else {
                            m = lv.defi;
                        }
                    }
                }
                if m >= 0 {
                    if lr_replacement_preserves_lcssa(i, m) {
                        ac_rauw(i, m); rauw(i, m);
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
    aq_pop(baa);
    if have_mssa { mssa_invalidate_all(); }
}

// MemorySSA::MemorySSA(Loop &L, AA, DT): accesses for the loop's blocks only, renaming from the preheader with
// the exit blocks marked visited, a MemoryPhi that placePHINodes put in the preheader removed
fn mssa_build_loop(l: i32) {
    let fv = block_func(loop_header(l));
    aa_begin(fv);
    dt_get(fv, DT_DOM);
    mssa_stash();       // the function's MemorySSA, if loaded, stays cached
    mssa_new_epoch();
    mssa_fn = fv;
    mssa_optimized = false;
    macc.clear();
    mphi_v.clear();
    mphi_b.clear();
    mphi_u.clear();
    muses.clear();
    mssa_next_id = 0;
    let live = ma_new(MAK_LIVE, -1, loop_header(l));
    macc[live].id = mssa_next_id;
    mssa_next_id++;
    let q = aq_push(CA_SIMPLE);
    var defblocks: i32[>..<] = [];
    for k in loop_nblocks(l) {
        let b = loop_block(l, k);
        var has_def = false;
        var i = block_first(b);
        while i >= 0 {
            let a = mssa_create_new_access(i, q);
            if a >= 0 {
                mssa_append(b, a);
                if macc[a].kind == MAK_DEF { has_def = true; mssa_append_def(b, a); }
            }
            i = inst_next(i);
        }
        if has_def && position(defblocks, b) < 0 { defblocks.push(b); }
    }
    var idf: i32[>..<] = [];
    mssa_idf(fv, defblocks, idf, false, 0);
    for x in idf { mssa_create_phi(x); }
    let ph = loop_preheader(l);
    let pp = mssa_access_of(ph);
    if pp >= 0 {
        var u = mssa_first_use(pp);
        while u >= 0 { let nx = mssa_use_next(u); fatal("internal: MemorySSA(Loop&): preheader phi with uses"); u = nx; }
        mssa_remove_from_lookups(pp);
        mssa_remove_from_lists(pp);
    }
    ss_clear(SS_MSSA4);
    var exits: i32[>..<] = [];
    loop_exit_blocks(l, exits);
    for e in exits { ss_add(SS_MSSA4, e); }
    mssa_rename_pass(fv, ph, live, false, false);
    for k in loop_nblocks(l) {
        let b = loop_block(l, k);
        if !ss_has(SS_MSSA4, b) { mssa_mark_unreachable(b); }
    }
    aq_pop(q);
}
// LoadInst::isSimple
fn ul_is_simple_load(i: i32) -> bool { (insts[inst_of(i)].bits & 1) == 0 && insts[inst_of(i)].ord == 0 }

// ---------------------------------------------------------------------------------------------
// simplifyLoopAfterUnroll


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
            if iop(i) == OP_ADD && m_apint(op(i, 1)) >= 0 && is_inst_op(op(i, 0), OP_ADD) && m_apint(op(op(i, 0), 1)) >= 0 {
                let inner = op(i, 0);
                let x = op(inner, 0);
                let c1 = ci_ap(m_apint(op(inner, 1)));
                let c2 = ci_ap(m_apint(op(i, 1)));
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




// ---------------------------------------------------------------------------------------------
// UnrollLoop

struct ULExitInfo { exiting: i32, trip_count: i64, trip_multiple: i64, breakout_trip: i64, exit_on_true: bool, first_exiting: i32, eb_at: i64 }

fn ul_gcd(a: i64, b: i64) -> i64 { var x = a; var y = b; while y != 0 { let t = x % y; x = y; y = t; } return x; }

struct ULState { preheader: i32, header: i32, latch_block: i32, fv: i32, max_trip_count: i64, max_or_zero: bool,
               has_otc: bool, otc: u64, orig_prob: u32, complete: bool, preserve_only_first: bool, need_fix_lcssa: bool,
               latch_is_exiting: bool, epilog_prof: bool }

// UnrollLoop up to the runtime remainder (false: LoopUnrollResult::Unmodified)
fn ul_phase1(l: i32, ulo: UnrollLoopOpts&, st: ULState&, preserve_lcssa: bool, exit_blocks: i32[>..<]&, orig_blocks: i32[>..<]&, infos: ULExitInfo[>..<]&, xbs: i32[>..<]&, xbn: i64[>..<]&, exiting: i32[>..<]&) -> bool {
    if loop_preheader(l) < 0 { return false; }
    if loop_latch(l) < 0 { return false; }
    if !loop_is_safe_to_clone(l) { return false; }
    if cu_has_address_taken(loop_header(l)) { return false; }
    st.preheader = loop_preheader(l);
    st.header = loop_header(l);
    st.latch_block = loop_latch(l);
    st.fv = block_func(st.header);
    let latch_block = st.latch_block;
    loop_exit_blocks(l, exit_blocks);
    for k in loop_nblocks(l) { orig_blocks.push(loop_block(l, k)); }
    st.max_trip_count = sc_get_small_constant_max_trip_count(l);
    st.max_or_zero = sc_is_backedge_taken_count_max_or_zero(l);
    let has_otc, otc = get_loop_estimated_trip_count(l);
    st.has_otc = has_otc;
    st.otc = otc;
    st.orig_prob = get_loop_probability(l);
    if st.max_trip_count != 0 && ulo.count > st.max_trip_count { ulo.count = st.max_trip_count; }
    // ExitInfos (MapVector by exiting block); ExitingBlocks of each info are runs in xbs
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
    st.complete = ulo.count == st.max_trip_count;
    st.preserve_only_first = st.complete && st.max_or_zero;
    if st.complete { ulo.runtime = false; }
    st.need_fix_lcssa = false;
    if preserve_lcssa && st.complete {
        for e in exit_blocks { if iop(block_first(e)) == OP_PHI { st.need_fix_lcssa = true; } }
    }
    let latch_term = block_terminator(latch_block);
    st.latch_is_exiting = loop_is_exiting(l, latch_block);
    if iop(latch_term) != OP_BR && !(iop(latch_term) == OP_CONDBR && st.latch_is_exiting) { return false; }
    st.epilog_prof = if flag_given("unroll-runtime-epilog") { flag_bool("unroll-runtime-epilog", false) } else { is_epilog_profitable(l) };
    return true;
}

// UnrollLoop after the runtime remainder: the result (1 partial, 2 full)
fn ul_phase2(l0: i32, ulo: UnrollLoopOpts&, st: ULState&, preserve_lcssa: bool, use_aa: bool, exit_blocks: i32[>..<]&, orig_blocks: i32[>..<]&, infos: ULExitInfo[>..<]&, xbs: i32[>..<]&, xbn: i64[>..<]&, exiting: i32[>..<]&) -> i64 {
    var l = l0;
    let preheader = st.preheader;
    let header = st.header;
    let latch_block = st.latch_block;
    let fv = st.fv;
    let has_otc = st.has_otc;
    let otc = st.otc;
    let orig_prob = st.orig_prob;
    let complete = st.complete;
    let preserve_only_first = st.preserve_only_first;
    var need_fix_lcssa = st.need_fix_lcssa;
    let latch_is_exiting = st.latch_is_exiting;
    let epilog_prof = st.epilog_prof;
    fn info_of(bb: i32) -> i64 { for k in infos.len { if infos[k].exiting == bb { return k; } } return -1; }
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
    return if complete { 2 } else { 1 };
}

fn ul_new_state() -> ULState {
    ULState { preheader: -1, header: -1, latch_block: -1, fv: -1, max_trip_count: 0, max_or_zero: false, has_otc: false, otc: 0,
              orig_prob: 0, complete: false, preserve_only_first: false, need_fix_lcssa: false, latch_is_exiting: false, epilog_prof: false }
}

// UnrollLoop(L, ULO, LI, SE, DT, AC, TTI, ORE, PreserveLCSSA, RemainderLoop, AA): (result, remainder loop)
fn unroll_loop(l: i32, ulo0: UnrollLoopOpts, preserve_lcssa: bool, use_aa: bool) -> i64, i32 {
    var ulo = ulo0;
    var st = ul_new_state();
    var exit_blocks: i32[>..<] = [];
    var orig_blocks: i32[>..<] = [];
    var infos: ULExitInfo[>..<] = [];
    var xbs: i32[>..<] = [];          // per info: Count slots (orig + one per iteration)
    var xbn: i64[>..<] = [];          // number used per info
    var exiting: i32[>..<] = [];
    if !ul_phase1(l, ulo, st, preserve_lcssa, exit_blocks, orig_blocks, infos, xbs, xbn, exiting) { return 0, -1; }
    var remainder: i32 = -1;
    if ulo.runtime {
        let ok, rl, unroll_rem = unroll_runtime_loop_remainder(l, ulo.count, ulo.allow_expensive_trip_count, st.epilog_prof, ulo.unroll_remainder,
                                                   ulo.forget_all_scev, preserve_lcssa, ulo.scev_budget, ulo.runtime_multi_exit,
                                                   st.has_otc, st.otc, st.orig_prob);
        if ok {
            remainder = rl;
            if unroll_rem {
                let ro = UnrollLoopOpts { count: ulo.count - 1, force: false, allow_expensive_trip_count: false, unroll_remainder: false,
                                          runtime: false, forget_all_scev: ulo.forget_all_scev, heart: -1, scev_budget: ulo.scev_budget,
                                          runtime_multi_exit: false, add_accumulators: false };
                let r2 = unroll_loop_no_runtime(rl, ro, preserve_lcssa);
                if r2 == 2 { remainder = -1; }
            }
        } else {
            if ulo.force { ulo.runtime = false; } else { return 0, -1; }
        }
    }
    let r = ul_phase2(l, ulo, st, preserve_lcssa, use_aa, exit_blocks, orig_blocks, infos, xbs, xbn, exiting);
    return r, remainder;
}
// UnrollLoop of the remainder loop from UnrollRuntimeLoopRemainder (ULO.Runtime = false, no AA)
fn unroll_loop_no_runtime(l: i32, ulo0: UnrollLoopOpts, preserve_lcssa: bool) -> i64 {
    var ulo = ulo0;
    var st = ul_new_state();
    var exit_blocks: i32[>..<] = [];
    var orig_blocks: i32[>..<] = [];
    var infos: ULExitInfo[>..<] = [];
    var xbs: i32[>..<] = [];
    var xbn: i64[>..<] = [];
    var exiting: i32[>..<] = [];
    if !ul_phase1(l, ulo, st, preserve_lcssa, exit_blocks, orig_blocks, infos, xbs, xbn, exiting) { return 0; }
    return ul_phase2(l, ulo, st, preserve_lcssa, false, exit_blocks, orig_blocks, infos, xbs, xbn, exiting);
}

// DICompileUnit::getDebugInfoForProfiling of a subprogram's unit
fn di_debug_info_for_profiling(sp: i32) -> bool {
    if mds[sp].kind != MK_DI { return false; }
    let u = di_slot(sp, "unit");
    if u < 0 || mds[u].kind != MK_DI { return false; }
    return di_int(u, "debugInfoForProfiling") != 0;
}
