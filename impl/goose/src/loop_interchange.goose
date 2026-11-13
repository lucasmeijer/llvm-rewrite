// LoopInterchange: port of llvm/lib/Transforms/Scalar/LoopInterchange.cpp (LoopInterchangePass::run on a LoopNest,
// populateDependencyMatrix, isLegalToInterChangeLoops, LoopInterchangeLegality, LoopInterchangeProfitability
// (cache with LoopCacheAnalysis (loop_cache_analysis.goose), instorder, vectorize), LoopInterchangeTransform incl. reduction2Memory). Dependences come from dependence_analysis.goose.
// Optimization remarks are not emitted.
//
// The dependency matrix is a flat char array of rows of width depth + 1. LoopInterchangeLegality's sets are
// globals reset per processLoop.
import std;
import ir;
import irutil;
import flags;
import analyses;
import instinfo;
import calls;
import gen_iids;
import loopinfo;
import loopnest;
import loopsimplify;
import lcssa;
import domtree;
import datalayout;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_update;
import scev_pred;
import implied;
import iv_descriptors;
import unroll_utils;
import sroa;
import dependence_analysis;
import loop_cache_analysis;

let LI_RULE_CACHE = 0;
let LI_RULE_INSTORDER = 1;
let LI_RULE_VECTORIZE = 2;
let LI_RULE_IGNORE = 3;

var li_rules: i64[>..<];
var li_dm: u8[>..<];            // DepMatrix rows, li_dm_w wide
var li_dm_w: i64 = 0;
var li_loops: i32[>..<];        // LoopList
var li_fv: i32 = -1;
var li_cc_root: i32 = -1;       // CacheCostManager
var li_cc_done: bool = false;

// LoopInterchangeLegality state
var lil_ind: i32[>..<];         // InnerLoopInductions
var lil_oir = hm_new();         // OuterInnerReductions
var lil_nowrap: i32[>..<];      // HasNoWrapReductions
var lil_noinf: i32[>..<];       // HasNoInfInsts
// InnerReductions (at most one is used): Reduction, Init, Next, LcssaPhi, LcssaStore, MemRef, ElemTy
var lil_red_n: i64 = 0;
var lil_red: i32[7] = [-1, -1, -1, -1, -1, -1, -1];

fn li_read_rules() {
    li_rules.clear();
    if !flag_given("loop-interchange-profitabilities") {
        li_rules.push(LI_RULE_INSTORDER);
        li_rules.push(LI_RULE_VECTORIZE);
        return;
    }
    let s = flag_str("loop-interchange-profitabilities");
    var start: i64 = 0;
    while start <= s.len {
        var end = start;
        while end < s.len && s[end] != ',' { end++; }
        let w = s[start..end];
        if w == "cache" { li_rules.push(LI_RULE_CACHE); }
        else if w == "instorder" { li_rules.push(LI_RULE_INSTORDER); }
        else if w == "vectorize" { li_rules.push(LI_RULE_VECTORIZE); }
        else if w == "ignore" { li_rules.push(LI_RULE_IGNORE); }
        else { fatal(str("opt: Cannot find option named '", w, "'!")); }
        start = end + 1;
    }
}

fn li_contains(xs: const i32[:], v: i32) -> bool { for x in xs { if x == v { return true; } } return false; }
fn li_set_has(s: HMap&, v: i32) -> bool { v >= 0 && hm_has(s, (v as i64) as u64) }
fn li_ldst_simple(i: i32) -> bool { insts[inst_of(i)].ord == 0 && !inst_is_volatile(i) }

// ---------------------------------------------------------------------------------------------
// populateDependencyMatrix

fn li_populate_dependency_matrix(level: i64, l: i32) -> bool {
    var mem: i32[>..<] = [];
    var ninsts: i64 = 0;
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 {
            ninsts++;
            if iop(i) == OP_LOAD || iop(i) == OP_STORE {
                if !li_ldst_simple(i) { return false; }
                mem.push(i);
            }
            i = inst_next(i);
        }
    }
    let nm = mem.len;
    if flag_int("loop-interchange-max-mem-instr-ratio", 4) * ninsts < nm * nm { return false; }
    li_dm.clear();
    li_dm_w = level + 1;
    var dep: u8[>..<] = [];
    for a in nm {
        for b in a..nm {
            let src = mem[a];
            let dst = mem[b];
            if iop(src) == OP_LOAD && iop(dst) == OP_LOAD { continue; }
            da_depends(src, dst, false);
            if da_res_kind == 0 { continue; }
            da_normalize();
            dep.clear();
            if da_res_kind == 2 {
                for ii in 1..da_res_levels + 1 {
                    let d = da_direction(ii);
                    dep.push(if d == DV_LT { '<' } else if d == DV_GT { '>' } else if d == DV_EQ { '=' } else { '*' });
                }
            } else {
                for k in level { dep.push('*'); }
            }
            while dep.len != level { dep.push('I'); }
            var all_star = true;
            for c in dep { if c != '*' { all_star = false; } }
            if all_star { return false; }
            var fwd = true;
            if inst_parent(src) != inst_parent(dst) { fwd = false; }
            else if da_res_src != src { fwd = false; }
            // Seen: the rows without their last element
            var row: i64 = -1;
            let nrows = li_dm.len / li_dm_w;
            for r in nrows {
                var same = true;
                for k in level { if li_dm[r * li_dm_w + k] != dep[k] { same = false; break; } }
                if same { row = r; break; }
            }
            if row < 0 {
                row = nrows;
                for c in dep { li_dm.push(c); }
                li_dm.push('<');
            }
            if !fwd { li_dm[row * li_dm_w + level] = '*'; }
        }
    }
    return true;
}

fn li_interchange_dependencies(from: i64, to: i64) {
    let nrows = li_dm.len / li_dm_w;
    for r in nrows {
        let t = li_dm[r * li_dm_w + to];
        li_dm[r * li_dm_w + to] = li_dm[r * li_dm_w + from];
        li_dm[r * li_dm_w + from] = t;
    }
}

// isLexicographicallyPositive over cur[begin, end): 1 = true, 0 = false, -1 = nullopt
fn li_lex_positive(cur: const u8[:], begin: i64, end: i64) -> i64 {
    for k in begin..end {
        let d = cur[k];
        if d == '<' { return 1; }
        if d == '>' || d == '*' { return 0; }
    }
    return -1;
}

fn li_is_legal_to_interchange(inner: i64, outer: i64) -> bool {
    let nrows = li_dm.len / li_dm_w;
    var cur: u8[>..<] = [];
    for r in nrows {
        cur.clear();
        for k in li_dm_w { cur.push(li_dm[r * li_dm_w + k]); }
        if li_lex_positive(cur, 0, outer) == 1 { continue; }
        if li_lex_positive(cur, outer, cur.len - 1) == 0 { return false; }
        let t = cur[inner]; cur[inner] = cur[outer]; cur[outer] = t;
        if li_lex_positive(cur, outer, cur.len - 1) == 0 { return false; }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Legality

fn li_contains_unsafe_instructions(bb: i32, skip: i32) -> bool {
    var i = block_first(bb);
    while i >= 0 {
        if i != skip && (inst_may_have_side_effects(i) || inst_may_read_memory(i)) { return true; }
        i = inst_next(i);
    }
    return false;
}

fn li_tightly_nested(ol: i32, il: i32) -> bool {
    let oh = loop_header(ol);
    let iph = loop_preheader(il);
    let olatch = loop_latch(ol);
    for k in block_nsucc(oh) {
        let s = block_succ(oh, k);
        if s != iph && s != loop_header(il) { return false; }
    }
    let skip = if lil_red_n == 1 { lil_red[4] } else { -1 };
    if li_contains_unsafe_instructions(oh, skip) || li_contains_unsafe_instructions(olatch, skip) { return false; }
    if iph != oh && li_contains_unsafe_instructions(iph, skip) { return false; }
    let iexit = ln_exit_block(il, false);
    let succ = ln_skip_empty_block_until(iexit, olatch, false);
    if succ != olatch { return false; }
    if li_contains_unsafe_instructions(iexit, skip) { return false; }
    return true;
}

// IsPathToInnerIndVar
recursive fn li_path_to_inner_indvar(v: i32) -> bool {
    if li_contains(lil_ind, v) { return true; }
    if is_constant(v) { return true; }
    if !is_inst(v) { return false; }
    if is_cast_op(iop(v)) { return li_path_to_inner_indvar(op(v, 0)); }
    if iop(v) >= OP_ADD && iop(v) <= OP_XOR { return li_path_to_inner_indvar(op(v, 0)) && li_path_to_inner_indvar(op(v, 1)); }
    return false;
}

fn li_is_loop_structure_understood(ol: i32, il: i32) -> bool {
    let iph = loop_preheader(il);
    for ind in lil_ind {
        for k in nops(ind) {
            let v = op(ind, k);
            if is_constant(v) { continue; }
            if !is_inst(v) { return false; }
            if phi_block(ind, k) == iph && !ivd_loop_invariant(ol, v) { return false; }
        }
    }
    let ilatch = loop_latch(il);
    let bi = block_terminator(ilatch);
    if iop(bi) != OP_CONDBR { return false; }
    let cmp = op(bi, 0);
    if !is_inst(cmp) || (iop(cmp) != OP_ICMP && iop(cmp) != OP_FCMP) { return false; }
    let op0 = op(cmp, 0);
    let op1 = op(cmp, 1);
    if li_path_to_inner_indvar(op0) && li_path_to_inner_indvar(op1) { return true; }
    var right: i32 = -1;
    var left: i32 = -1;
    if li_path_to_inner_indvar(op0) && !is_constant(op0) { left = op0; right = op1; }
    else if li_path_to_inner_indvar(op1) && !is_constant(op1) { left = op1; right = op0; }
    if left < 0 { return false; }
    let s = sc_get_scev(right);
    return sc_is_loop_invariant(s, ol);
}

// followLCSSA
fn li_follow_lcssa(v0: i32) -> i32 {
    var v = v0;
    loop {
        if !is_inst(v) || iop(v) != OP_PHI { return v; }
        if phi_nincoming(v) != 1 { return v; }
        v = phi_value(v, 0);
    }
    return v;
}

// checkReductionKind
fn li_check_reduction_kind(l: i32, phi: i32) -> bool {
    let d = rdx_is_reduction_phi(phi, l);
    if d < 0 { return false; }
    if rdx_descs[d].exact_fp >= 0 { return false; }
    let rk = rdx_descs[d].kind;
    if rk == RK_OR || rk == RK_AND || rk == RK_XOR || rk == RK_SMIN || rk == RK_SMAX || rk == RK_UMIN || rk == RK_UMAX { return true; }
    if rk == RK_ANYOF { return false; }
    if rk == RK_FADD || rk == RK_FMUL || rk == RK_FMIN || rk == RK_FMAX || rk == RK_FMINIMUM || rk == RK_FMAXIMUM ||
       rk == RK_FMINIMUMNUM || rk == RK_FMAXIMUMNUM || rk == RK_FMULADD {
        var chain: i32[>..<] = [];
        rdx_reduction_op_chain(d, phi, l, chain);
        for i in chain { if is_fp_math_operator(i) && (insts[inst_of(i)].fmf & FMF_NINF) != 0 { lil_noinf.push(i); } }
        return true;
    }
    if rk == RK_ADD || rk == RK_MUL {
        var chain: i32[>..<] = [];
        rdx_reduction_op_chain(d, phi, l, chain);
        if chain.len == 0 { return false; }
        for i in chain { if (insts[inst_of(i)].flags & (FL_NSW | FL_NUW)) != 0 { lil_nowrap.push(i); } }
        return true;
    }
    return false;
}

// findInnerReductionPhi
fn li_find_inner_reduction_phi(l: i32, v: i32) -> i32 {
    if v < 0 || is_constant(v) { return -1; }
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if is_inst(us) && iop(us) == OP_PHI {
            if phi_nincoming(us) == 1 { continue; }
            if li_check_reduction_kind(l, us) { return us; }
            return -1;
        }
    }
    return -1;
}

fn li_incoming(phi: i32, bb: i32) -> i32 { let k = phi_block_index(phi, bb); if k < 0 { -1 } else { phi_value(phi, k) } }
fn li_has_one_user(v: i32) -> bool {
    let u = vals[v].first_use;
    if u < 0 { return false; }
    let usr = uses[u].user;
    var x = uses[u].next;
    while x >= 0 { if uses[x].user != usr { return false; } x = uses[x].next; }
    return true;
}
// getUniqueUndroppableUser
fn li_unique_undroppable_user(v: i32) -> i32 {
    var r: i32 = -1;
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        let id = inst_iid(us);
        if id == IID_assume || id == IID_pseudoprobe { continue; }
        if r >= 0 && r != us { return -1; }
        r = us;
    }
    return r;
}

// isInnerReduction
fn li_is_inner_reduction(l: i32, phi: i32) -> bool {
    if !loop_is_innermost(l) { return false; }
    if phi_nincoming(phi) != 2 { return false; }
    let init = li_incoming(phi, loop_preheader(l));
    let next = li_incoming(phi, loop_latch(l));
    if !is_constant(init) { return false; }
    if is_inst(next) && !loop_contains(l, inst_parent(next)) { return false; }
    if !li_has_one_user(phi) { return false; }
    if !li_check_reduction_kind(l, phi) { return false; }
    let exit = ln_exit_block(l, false);
    if exit < 0 { return false; }
    var lcssa: i32 = -1;
    var u = vals[next].first_use;
    while u >= 0 {
        let p = uses[u].user;
        u = uses[u].next;
        if is_inst(p) && iop(p) == OP_PHI {
            if p == phi { continue; }
            if lcssa < 0 && inst_parent(p) == exit && li_incoming(p, loop_latch(l)) == next { lcssa = p; }
            else { return false; }
        } else { return false; }
    }
    if lcssa < 0 { return false; }
    if !li_has_one_user(lcssa) { return false; }
    let st = li_unique_undroppable_user(lcssa);
    if st < 0 || iop(st) != OP_STORE || inst_parent(st) != exit { return false; }
    let memref = op(st, 1);
    let elty = vals[op(st, 0)].ty;
    if !is_inst(memref) { fatal("loop-interchange: DT->dominates of a non-instruction memory reference (LLVM dereferences null)"); }
    if !dt_inst_dominates_block(memref, loop_header(l)) { return false; }
    lil_red = [phi, init, next, lcssa, st, memref, elty];
    lil_red_n++;
    return true;
}

// InductionDescriptor::isInductionPHI(Phi, L, SE, D)
fn li_is_induction_phi(phi: i32, l: i32) -> i32 {
    // the ScalarEvolution overload handles integer and pointer inductions only (no FP inductions)
    let ty = vals[phi].ty;
    if !ty_is_int(ty) && ty_kind(ty) != TK_PTR { return -1; }
    return ind_is_induction_phi_se(phi, l, [], -1, []);
}

fn li_child(l: i32) -> i32 { if loop_nsubs(l) == 0 { -1 } else { loop_sub(l, 0) } }

// checkInductionsAndReductions
fn li_check_inductions_and_reductions(ol: i32) -> bool {
    let il = li_child(ol);
    var cur = ol;
    while cur >= 0 {
        var p = block_first(loop_header(cur));
        while p >= 0 && iop(p) == OP_PHI {
            let phi = p;
            p = inst_next(p);
            let id = li_is_induction_phi(phi, cur);
            if id >= 0 {
                if cur == il {
                    if !sc_is_loop_invariant(ind_descs[id].step, ol) { return false; }
                    lil_ind.push(phi);
                }
                continue;
            }
            if cur == ol {
                if phi_nincoming(phi) != 2 { return false; }
                let v = li_follow_lcssa(li_incoming(phi, loop_latch(ol)));
                let irp = li_find_inner_reduction_phi(il, v);
                var ok = irp >= 0;
                if ok {
                    var inc = false;
                    for k in phi_nincoming(irp) { if phi_value(irp, k) == phi { inc = true; } }
                    ok = inc;
                }
                if ok {
                    var u = vals[phi].first_use;
                    while u >= 0 { if uses[u].user != irp { ok = false; } u = uses[u].next; }
                }
                if !ok { return false; }
                hm_put(lil_oir, (phi as i64) as u64, 1);
                hm_put(lil_oir, (irp as i64) as u64, 1);
            } else {
                if li_set_has(lil_oir, phi) { }
                else if flag_bool("loop-interchange-reduction-to-mem", false) && li_is_inner_reduction(cur, phi) { }
                else { return false; }
            }
        }
        if lil_red_n > 1 { return false; }
        cur = li_child(cur);
    }
    return lil_ind.len > 0;
}

// currentLimitations
fn li_current_limitations(ol: i32, il: i32) -> bool {
    let ilatch = loop_latch(il);
    if loop_exiting_block_of(il) != ilatch || loop_exiting_block_of(ol) != loop_latch(ol) ||
       iop(block_terminator(ilatch)) != OP_CONDBR || iop(block_terminator(loop_latch(ol))) != OP_CONDBR { return true; }
    if !li_is_loop_structure_understood(ol, il) { return true; }
    for x in 2 {
        let l = if x == 0 { ol } else { il };
        var bad = false;
        each_pred(loop_header(l)) { pr => if !loop_contains(l, pr) && iop(block_terminator(pr)) == OP_INDIRECTBR { bad = true; } };
        if bad { return true; }
    }
    var seen: i32[>..<] = [];
    let ih = loop_header(il);
    for k in block_nsucc(ih) {
        let s = block_succ(ih, k);
        if li_contains(seen, s) { return true; }
        seen.push(s);
    }
    return false;
}

fn li_inner_exit_phis_supported(ol: i32, il: i32, lcssa_red: i32) -> bool {
    let iexit = ln_exit_block(il, true);
    var p = block_first(iexit);
    while p >= 0 && iop(p) == OP_PHI {
        let phi = p;
        p = inst_next(p);
        if phi_nincoming(phi) > 1 { return false; }
        if phi == lcssa_red { continue; }
        var u = vals[phi].first_use;
        while u >= 0 {
            let us = uses[u].user;
            u = uses[u].next;
            if !(is_inst(us) && iop(us) == OP_PHI) { return false; }
            if li_set_has(lil_oir, us) { continue; }
            let pb = inst_parent(us);
            if !loop_contains(ol, pb) { continue; }
            if pb != loop_latch(ol) { return false; }
        }
    }
    return true;
}

fn li_outer_exit_phis_supported(ol: i32) -> bool {
    let nexit = ln_exit_block(ol, true);
    var p = block_first(nexit);
    while p >= 0 && iop(p) == OP_PHI {
        for k in phi_nincoming(p) {
            let v = phi_value(p, k);
            if !is_inst(v) || inst_parent(v) != loop_latch(ol) { continue; }
            if ln_unique_predecessor(loop_latch(ol)) < 0 { return false; }
        }
        p = inst_next(p);
    }
    return true;
}

fn li_inner_latch_phis_supported(il: i32) -> bool {
    if loop_nsubs(il) == 0 { return true; }
    let ilatch = loop_latch(il);
    let bi = block_terminator(ilatch);
    if iop(bi) != OP_CONDBR { return true; }
    let c = op(bi, 0);
    if !is_inst(c) { return true; }
    var wl: i32[>..<] = [];
    wl.push(c);
    var k: i64 = 0;
    while k < wl.len {
        let cur = wl[k];
        k++;
        if iop(cur) == OP_PHI && inst_parent(cur) == ilatch { return false; }
        for j in nops(cur) {
            let o = op(cur, j);
            if is_inst(o) && loop_contains(il, inst_parent(o)) && !li_contains(wl, o) { wl.push(o); }
        }
    }
    return true;
}

fn li_can_interchange_loops(inner_id: i64, outer_id: i64, ol: i32, il: i32) -> bool {
    if !li_is_legal_to_interchange(inner_id, outer_id) { return false; }
    for k in loop_nblocks(ol) {
        var i = block_first(loop_block(ol, k));
        while i >= 0 {
            let o = iop(i);
            if o == OP_LOAD || o == OP_STORE || inst_iid(i) == IID_pseudoprobe { i = inst_next(i); continue; }
            if !inst_may_have_side_effects(i) && !inst_may_read_memory(i) { i = inst_next(i); continue; }
            return false;
        }
    }
    if !li_check_inductions_and_reductions(ol) { return false; }
    if !li_inner_latch_phis_supported(il) { return false; }
    if li_current_limitations(ol, il) { return false; }
    if !li_tightly_nested(ol, il) { return false; }
    let lcssa_red = if lil_red_n == 1 { lil_red[3] } else { -1 };
    if !li_inner_exit_phis_supported(ol, il, lcssa_red) { return false; }
    if !li_outer_exit_phis_supported(ol) { return false; }
    let olatch = loop_latch(ol);
    var p = block_first(olatch);
    while p >= 0 && iop(p) == OP_PHI { if phi_nincoming(p) != 1 { return false; } p = inst_next(p); }
    if ln_exit_block(il, false) != olatch {
        p = block_first(olatch);
        while p >= 0 && iop(p) == OP_PHI {
            var u = vals[p].first_use;
            while u >= 0 { let us = uses[u].user; if !(is_inst(us) && iop(us) == OP_PHI) { return false; } u = uses[u].next; }
            p = inst_next(p);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Profitability

// getAddRecCoefficient: (known, coeff or -1 = nullptr)
recursive fn li_addrec_coefficient(s: i32, l: i32) -> bool, i32 {
    if sc_kind(s) != SC_ADDREC {
        if sc_is_loop_invariant(s, l) { return true, -1; }
        return false, -1;
    }
    if !sc_is_affine(s) { return false, -1; }
    let ok, c = li_addrec_coefficient(sc_op(s, 0), l);
    if !ok { return false, -1; }
    if sc_loop(s) == l { return true, sc_get_step_recurrence(s); }
    return true, c;
}

fn li_instr_order_cost(ol: i32, il: i32) -> i64 {
    var good: i32[>..<] = [];
    var bad: i32[>..<] = [];
    for k in loop_nblocks(il) {
        var i = block_first(loop_block(il, k));
        while i >= 0 {
            let o = iop(i);
            if o == OP_LOAD || o == OP_STORE {
                let acc = sc_get_scev(if o == OP_STORE { op(i, 1) } else { op(i, 0) });
                let base = sc_get_pointer_base(acc);
                let ok1, oc = li_addrec_coefficient(acc, ol);
                let ok2, ic = li_addrec_coefficient(acc, il);
                if ok1 && oc >= 0 && ok2 && ic >= 0 {
                    let os = sc_get_abs(oc, false);
                    let is = sc_get_abs(ic, false);
                    if sc_is_known_predicate(P_SLT, is, os) { if !li_contains(good, base) { good.push(base); } }
                    else if sc_is_known_predicate(P_SLT, os, is) { if !li_contains(bad, base) { bad.push(base); } }
                }
            }
            i = inst_next(i);
        }
    }
    return good.len - bad.len;
}

fn li_can_vectorize(id: i64) -> bool {
    let nrows = li_dm.len / li_dm_w;
    for r in nrows {
        let d = li_dm[r * li_dm_w + id];
        let t = li_dm[r * li_dm_w + li_dm_w - 1];
        if d == '=' || d == 'I' { continue; }
        if d == '<' && t == '<' { continue; }
        return false;
    }
    return true;
}

fn li_is_profitable(ol: i32, il: i32, inner_id: i64, outer_id: i64) -> bool {
    let ibtc = sc_get_backedge_taken_count(il, BTC_EXACT);
    let obtc = sc_get_backedge_taken_count(ol, BTC_EXACT);
    if sc_is_zero(ibtc) { return false; }
    if sc_is_zero(obtc) { return false; }
    if li_rules.len == 1 && li_rules[0] == LI_RULE_IGNORE { return true; }
    var r: i64 = -1;   // std::optional<bool>: -1 = none, 0 / 1
    for rule in li_rules {
        if rule == LI_RULE_CACHE {
            // CacheCostManager: computed once per loop list, for the outermost loop it was created with
            if !li_cc_done { lcc_compute(li_cc_root); li_cc_done = true; }
            let ii = lcc_index_of(il);
            let oi = lcc_index_of(ol);
            if ii < 0 || oi < 0 { r = -1; }
            else {
                let a = lcc_loop_cost(ol);
                let b = lcc_loop_cost(il);
                if lcost_eq(a, b) { r = -1; } else { r = if ii < oi { 1 } else { 0 }; }
            }
        } else if rule == LI_RULE_INSTORDER {
            let cost = li_instr_order_cost(ol, il);
            r = if cost < 0 && cost < flag_int("loop-interchange-threshold", 0) { 1 } else { -1 };
        } else if rule == LI_RULE_VECTORIZE {
            if !li_can_vectorize(outer_id) { r = 0; }
            else if !li_can_vectorize(inner_id) { r = 1; }
            else { r = -1; }
        } else {
            fatal("loop-interchange: option 'ignore' is not supported with other options");
        }
        if r >= 0 { break; }
    }
    return r == 1;
}

// ---------------------------------------------------------------------------------------------
// Transform

fn li_dt_ups_apply(ups: const DTUpdate[:]) { dt_apply_updates(li_fv, DT_DOM, ups); }

// updateSuccessor(Term, OldBB, NewBB, DTUpdates)
fn li_update_successor(t: i32, old: i32, nw: i32, ups: DTUpdate[>..<]&) {
    var changed = false;
    for k in nops(t) { if op(t, k) == old { set_op(t, k, nw); changed = true; } }
    if !changed { fatal("internal: loop-interchange: expected a successor to be updated"); }
    ups.push(DTUpdate { kind: DT_INSERT, from: inst_parent(t), to: nw });
    ups.push(DTUpdate { kind: DT_DELETE, from: inst_parent(t), to: old });
}

// reduction2Memory
fn li_reduction_to_memory(il: i32) {
    let red = lil_red[0];
    let init = lil_red[1];
    let next = lil_red[2];
    let st = lil_red[4];
    let memref = lil_red[5];
    let elty = lil_red[6];
    let ih = loop_header(il);
    let at = first_non_phi(ih);
    let dl = inst_get_md(at, 0);
    let fi = new_inst(OP_PHI, ty_int(1), 0);
    vals[fi].nops = 0;
    inst_insert_before_head(fi, at);
    set_name(fi, "first.iter");
    if dl >= 0 { inst_set_md(fi, 0, dl); }
    phi_add_incoming(fi, c_int(ty_int(1), 1), loop_preheader(il));
    phi_add_incoming(fi, c_int(ty_int(1), 0), loop_latch(il));
    let ld = create_inst(OP_LOAD, elty, [memref]);
    sr_set_inst_align(ld, dl_align(elty, true));
    inst_insert_before_head(ld, at);
    if dl >= 0 { inst_set_md(ld, 0, dl); }
    let sel = create_inst(OP_SELECT, vals[init].ty, [fi, init, ld]);
    inst_insert_before_head(sel, at);
    set_name(sel, "new.var");
    if dl >= 0 { inst_set_md(sel, 0, dl); }
    rauw(red, sel);
    set_op(st, 0, next);
    inst_move_after(st, next);
}

// MoveInstructions (the worklist is a SetVector; `wi` the persistent index)
fn li_move_instructions(il: i32, nlatch: i32, wl: i32[>..<]&, wi: i64) -> i64 {
    var i = wi;
    while i < wl.len {
        let w = wl[i];
        if iop(w) == OP_PHI { fatal("internal: loop-interchange: MoveInstructions does not support PHI nodes"); }
        let ni = inst_clone(w);
        inst_insert_before_head(ni, first_non_phi(nlatch));
        var u = vals[w].first_use;
        while u >= 0 {
            let nu = uses[u].next;
            let us = uses[u].user;
            let ub = inst_parent(us);
            if !loop_contains(il, ub) || ub == nlatch || li_contains(lil_ind, us) { set_op(us, (u - vals[us].ops) as i64, ni); }
            u = nu;
        }
        for k in nops(w) {
            let o = op(w, k);
            if !is_inst(o) || li_loop_for(inst_parent(o)) != il || li_contains(lil_ind, o) { continue; }
            if !li_contains(wl, o) { wl.push(o); }
        }
        i++;
    }
    return i;
}

// moveBBContents(FromBB, InsertBefore)
fn li_move_bb_contents(from: i32, before: i32) {
    let t = block_terminator(from);
    block_splice(inst_parent(before), before, false, from, block_first(from), true, t, false);
}
// swapBBContents
fn li_swap_bb_contents(b1: i32, b2: i32) {
    var tmp: i32[>..<] = [];
    var i = block_first(b1);
    let t1 = block_terminator(b1);
    while i >= 0 && i != t1 { tmp.push(i); i = inst_next(i); }
    for x in tmp { inst_remove_from_parent(x); }
    li_move_bb_contents(b2, block_terminator(b1));
    for x in tmp { inst_insert_before(x, block_terminator(b2)); }
}

// moveLCSSAPhis
fn li_move_lcssa_phis(iexit: i32, ih: i32, ilatch: i32, oh: i32, olatch: i32, oexit: i32, il: i32) {
    var p = block_first(iexit);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        let inc = li_incoming(p, ilatch);
        if !is_inst(inc) {
            rauw(p, inc);
            inst_erase_from_parent(p);
            p = np;
            continue;
        }
        let inm = li_follow_lcssa(inc);
        if !is_inst(inm) || (inst_parent(inm) != ilatch && inst_parent(inm) != ih) { p = np; continue; }
        rauw(p, inc);
        inst_erase_from_parent(p);
        p = np;
    }
    var le: i32[>..<] = [];
    p = block_first(iexit);
    while p >= 0 && iop(p) == OP_PHI { le.push(p); p = inst_next(p); }
    var ll: i32[>..<] = [];
    p = block_first(ilatch);
    while p >= 0 && iop(p) == OP_PHI { ll.push(p); p = inst_next(p); }
    for x in le { inst_move_before_head(x, first_non_phi(ilatch)); }
    for x in ll { inst_move_before_head(x, first_non_phi(iexit)); }
    if oexit >= 0 {
        p = block_first(oexit);
        while p >= 0 && iop(p) == OP_PHI {
            let np = inst_next(p);
            if phi_nincoming(p) != 1 { p = np; continue; }
            let i = phi_value(p, 0);
            if !is_inst(i) || li_loop_for(inst_parent(i)) == il { p = np; continue; }
            let nphi = inst_clone(p);
            set_op(nphi, 0, phi_value(p, 0));
            phi_set_block(nphi, 0, olatch);
            each_pred(ilatch) { pr => if pr != olatch { phi_add_incoming(nphi, phi_value(p, 0), pr); } };
            inst_insert_before_head(nphi, first_non_phi(ilatch));
            set_op(p, 0, nphi);
            p = np;
        }
    }
    block_replace_phi_uses_with(ilatch, ilatch, olatch);
}

// simplifyLCSSAPhis
fn li_simplify_lcssa_phis(ol: i32, il: i32) {
    let iexit = ln_exit_block(il, false);
    let olatch = loop_latch(ol);
    if olatch == iexit { return; }
    var phis: i32[>..<] = [];
    var p = block_first(olatch);
    while p >= 0 && iop(p) == OP_PHI { phis.push(p); p = inst_next(p); }
    for x in phis { rauw(x, phi_value(x, 0)); inst_erase_from_parent(x); }
}

// restructureLoops(NewInner, NewOuter, OrigInnerPreHeader, OrigOuterPreHeader)
fn li_restructure_loops(ninner: i32, nouter: i32, oiph: i32, ooph: i32, ol: i32) {
    let olp = loop_parent(ol);
    loop_remove_block_from_loop(ninner, oiph);
    li_change_loop_for(oiph, olp);
    if olp >= 0 {
        loop_remove_child(olp, ninner);
        loop_remove_child(ninner, nouter);
        loop_add_child(olp, nouter);
    } else {
        loop_remove_child(ninner, nouter);
        li_change_top_level_loop(li_fv, ninner, nouter);
    }
    while !loop_is_innermost(nouter) {
        let c = loop_sub(nouter, 0);
        loop_remove_child(nouter, c);
        loop_add_child(ninner, c);
    }
    loop_add_child(nouter, ninner);
    var orig_inner: i32[>..<] = [];
    for k in loop_nblocks(nouter) { orig_inner.push(loop_block(nouter, k)); }
    for k in loop_nblocks(ninner) {
        let bb = loop_block(ninner, k);
        if li_loop_for(bb) == ninner { loop_add_block_entry(nouter, bb); }
    }
    let oh = loop_header(nouter);
    let olatch = loop_latch(nouter);
    for bb in orig_inner {
        if li_loop_for(bb) != nouter { continue; }
        if bb == oh || bb == olatch { loop_remove_block_from_loop(ninner, bb); }
        else { li_change_loop_for(bb, ninner); }
    }
    loop_add_block_entry(nouter, ooph);
    li_change_loop_for(ooph, nouter);
    sc_forget_loop(nouter);
}

// adjustLoopBranches
fn li_adjust_loop_branches(ol: i32, il: i32) {
    var ups: DTUpdate[>..<] = [];
    var oph = loop_preheader(ol);
    var iph = loop_preheader(il);
    li_simplify_lcssa_phis(ol, il);
    if iop(block_first(oph)) == OP_PHI || ln_unique_predecessor(oph) < 0 { oph = insert_preheader_for_loop(ol, true); }
    if iph == loop_header(ol) { iph = insert_preheader_for_loop(il, true); }
    let ih = loop_header(il);
    let oh = loop_header(ol);
    let ilatch = loop_latch(il);
    let olatch = loop_latch(ol);
    let opred = ln_unique_predecessor(oph);
    let ilpred = ln_unique_predecessor(ilatch);
    let olbi = block_terminator(olatch);
    let ilbi = block_terminator(ilatch);
    let ohbi = block_terminator(oh);
    let ihbi = block_terminator(ih);
    if opred < 0 || ilpred < 0 { fatal("internal: loop-interchange: failed to find a unique predecessor"); }
    let ilpred_bi = block_terminator(ilpred);
    let opred_bi = block_terminator(opred);
    let ihsucc = ln_unique_successor(ih);
    if ihsucc < 0 { fatal("internal: loop-interchange: the inner loop header has no unique successor"); }
    li_update_successor(opred_bi, oph, iph, ups);
    var has_olatch = false;
    for k in term_nsucc(ohbi) { if term_succ(ohbi, k) == olatch { has_olatch = true; } }
    if has_olatch { li_update_successor(ohbi, olatch, ilatch, ups); }
    li_update_successor(ohbi, iph, ihsucc, ups);
    block_replace_phi_uses_with(ihsucc, ih, oh);
    li_update_successor(ihbi, ihsucc, oph, ups);
    let ilsucc = if term_succ(ilbi, 0) == ih { term_succ(ilbi, 1) } else { term_succ(ilbi, 0) };
    li_update_successor(ilpred_bi, ilatch, ilsucc, ups);
    let olsucc = if term_succ(olbi, 0) == oh { term_succ(olbi, 1) } else { term_succ(olbi, 0) };
    li_update_successor(ilbi, ilsucc, olsucc, ups);
    li_update_successor(olbi, olsucc, ilatch, ups);
    li_dt_ups_apply(ups);
    li_restructure_loops(ol, il, iph, oph, ol);
    li_move_lcssa_phis(ilsucc, ih, ilatch, oh, olatch, ln_exit_block(il, false), il);
    block_replace_phi_uses_with(olsucc, olatch, ilatch);
    var ilp: i32[>..<] = [];
    var olp: i32[>..<] = [];
    var p = block_first(ih);
    while p >= 0 && iop(p) == OP_PHI { if li_set_has(lil_oir, p) { ilp.push(p); } p = inst_next(p); }
    p = block_first(oh);
    while p >= 0 && iop(p) == OP_PHI { if li_set_has(lil_oir, p) { olp.push(p); } p = inst_next(p); }
    for x in olp { inst_move_before_head(x, first_non_phi(ih)); }
    for x in ilp { inst_move_before_head(x, first_non_phi(oh)); }
    block_replace_phi_uses_with(oh, iph, oph);
    block_replace_phi_uses_with(oh, ilatch, olatch);
    block_replace_phi_uses_with(ih, oph, iph);
    block_replace_phi_uses_with(ih, olatch, ilatch);
    var may: i32[>..<] = [];
    var i = block_first(oh);
    let t = block_terminator(oh);
    while i >= 0 && i != t { may.push(i); i = inst_next(i); }
    lcssa_se = true;
    form_lcssa_for_instructions(may);
    lcssa_se = false;
}

fn li_transform(ol: i32, il: i32) {
    if lil_red_n == 1 { li_reduction_to_memory(il); }
    var ivl: i32[>..<] = [];
    for ind in lil_ind {
        let inc = li_incoming(ind, loop_latch(il));
        if !is_inst(inc) { fatal("internal: loop-interchange: the latch incoming value isn't an instruction"); }
        if li_contains(lil_ind, inc) { continue; }
        ivl.push(inc);
    }
    let ilatch0 = loop_latch(il);
    let nlatch = lp_split_block(ilatch0, block_terminator(ilatch0));
    var wl: i32[>..<] = [];
    var wi: i64 = 0;
    let c = op(block_terminator(loop_latch(il)), 0);
    if is_inst(c) { wl.push(c); }
    wi = li_move_instructions(il, nlatch, wl, wi);
    for x in ivl { if !li_contains(wl, x) { wl.push(x); } }
    wi = li_move_instructions(il, nlatch, wl, wi);
    let ih = loop_header(il);
    lp_split_block_it(ih, first_non_phi(ih), true);
    let iph = loop_preheader(il);
    let oh = loop_header(ol);
    if iph != oh {
        var p = block_first(iph);
        while p >= 0 && iop(p) == OP_PHI {
            let np = inst_next(p);
            rauw(p, phi_value(p, 0));
            inst_erase_from_parent(p);
            p = np;
        }
        var mv: i32[>..<] = [];
        var i = block_first(iph);
        let t = block_terminator(iph);
        while i >= 0 && i != t { mv.push(i); i = inst_next(i); }
        for x in mv { inst_move_before_preserving(x, block_terminator(oh)); }
    }
    // adjustLoopLinks
    li_adjust_loop_branches(ol, il);
    li_swap_bb_contents(loop_preheader(ol), loop_preheader(il));
    for x in lil_nowrap { insts[inst_of(x)].flags = insts[inst_of(x)].flags & ~(FL_NSW | FL_NUW); }
    for x in lil_noinf { insts[inst_of(x)].fmf = insts[inst_of(x)].fmf & ~FMF_NINF; }
}

// ---------------------------------------------------------------------------------------------
// The driver

fn li_process_loop(inner_id: i64, outer_id: i64) -> bool {
    let ol = li_loops[outer_id];
    let il = li_loops[inner_id];
    lil_ind.clear(); hm_clear(lil_oir); lil_nowrap.clear(); lil_noinf.clear(); lil_red_n = 0;
    ivd_reset();
    if !li_can_interchange_loops(inner_id, outer_id, ol, il) { return false; }
    if !li_is_profitable(ol, il, inner_id, outer_id) { return false; }
    li_transform(ol, il);
    lcssa_se = true;
    form_lcssa_recursively(ol);
    lcssa_se = false;
    let t = li_loops[outer_id]; li_loops[outer_id] = li_loops[inner_id]; li_loops[inner_id] = t;
    li_interchange_dependencies(inner_id, outer_id);
    return true;
}

fn li_process_loop_list() -> bool {
    var changed = false;
    let depth = li_loops.len;
    let outermost = li_loops[0];
    if !li_populate_dependency_matrix(depth, outermost) { return false; }
    if ln_exit_block(outermost, false) < 0 { return false; }
    li_cc_root = li_loops[0];
    li_cc_done = false;
    let sel = depth - 1;
    var j = sel;
    while j > 0 {
        var per = false;
        var i = sel;
        while i > sel - j {
            if li_process_loop(i, i - 1) { per = true; changed = true; }
            i--;
        }
        if !per { break; }
        j--;
    }
    return changed;
}

// LoopInterchangePass::run(LoopNest &LN, ...) on the top-level loop l
fn loop_interchange_run(l: i32, fv: i32) -> bool {
    li_fv = fv;
    li_read_rules();
    da_read_options();
    // LN.getLoops(): breadth first from the root
    li_loops.clear();
    li_loops.push(l);
    var k: i64 = 0;
    while k < li_loops.len { let x = li_loops[k]; for s in loop_nsubs(x) { li_loops.push(loop_sub(x, s)); } k++; }
    let depth = li_loops.len;
    if depth < flag_int("loop-interchange-min-loop-nest-depth", 2) || depth > flag_int("loop-interchange-max-loop-nest-depth", 10) { return false; }
    for x in li_loops {
        if sc_is_cnc(sc_get_backedge_taken_count(x, BTC_EXACT)) { return false; }
        if loop_num_back_edges(x) != 1 { return false; }
        if loop_exiting_block_of(x) < 0 { return false; }
    }
    for i in 1..li_loops.len { if loop_parent(li_loops[i]) != li_loops[i - 1] { return false; } }
    return li_process_loop_list();
}
