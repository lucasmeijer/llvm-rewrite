// print<loopnest>: LoopNestPrinterPass and LoopNest (llvm/lib/Analysis/LoopNestAnalysis.cpp), with the
// Loop helpers it needs from llvm/lib/Analysis/LoopInfo.cpp (getLatchCmpInst, getBounds,
// getInductionVariable, getLoopGuardBranch, isLoopSimplifyForm, getExitBlock/getUniqueExitBlock) and
// InductionDescriptor::isInductionPHI (llvm/lib/Analysis/IVDescriptors.cpp, the ScalarEvolution overload).
import std;
import ir;
import irutil;
import flags;
import instinfo;
import loopinfo;
import loopsimplify;
import scev;
import scev_create;

fn ln_is_loop_simplify_form(l: i32) -> bool { loop_preheader(l) >= 0 && loop_latch(l) >= 0 && loop_has_dedicated_exits(l) }

// getExitBlockHelper(L, Unique): the single exit block (repeats allowed when unique)
fn ln_exit_block(l: i32, unique: bool) -> i32 {
    var r: i32 = -1;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        let t = block_last(bb);
        // find_singleton_nested over the successors of bb
        var br: i32 = -1;
        for k in term_nsucc(t) {
            let s = term_succ(t, k);
            if loop_contains(l, s) { continue; }
            if br >= 0 {
                if !unique || br != s { return -1; }
            } else { br = s; }
        }
        if br >= 0 {
            if r >= 0 {
                if !unique || r != br { return -1; }
            } else { r = br; }
        }
    }
    return r;
}

fn ln_latch_cmp(l: i32) -> i32 {
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    let t = block_last(latch);
    if iop(t) != OP_CONDBR { return -1; }
    let c = op(t, 0);
    if is_inst(c) && iop(c) == OP_ICMP { return c; }
    return -1;
}

fn ln_incoming_for_block(pn: i32, bb: i32) -> i32 { phi_value(pn, phi_block_index(pn, bb)) }

// InductionDescriptor::isInductionPHI: (ok, start value, induction binop or -1)
fn ln_is_induction_phi(pn: i32, l: i32) -> bool, i32, i32 {
    if !sc_is_scevable(vals[pn].ty) { return false, -1, -1; }
    let s = sc_get_scev(pn);
    if !sc_is_addrec(s) || !sc_is_affine(s) || sc_loop(s) != l { return false, -1, -1; }
    let ph = loop_preheader(l);
    if ph < 0 { return false, -1, -1; }
    let sv = ln_incoming_for_block(pn, ph);
    let latch = loop_latch(l);
    if latch < 0 { return false, -1, -1; }
    if ty_is_int(vals[pn].ty) {
        let b = ln_incoming_for_block(pn, latch);
        let bop = if is_inst(b) && iop(b) >= OP_ADD && iop(b) <= OP_XOR { b } else { -1 };
        return true, sv, bop;
    }
    return true, sv, -1;
}

// Loop::getInductionVariable
fn ln_induction_variable(l: i32) -> i32 {
    if !ln_is_loop_simplify_form(l) { return -1; }
    let c = ln_latch_cmp(l);
    if c < 0 { return -1; }
    let o0 = op(c, 0);
    let o1 = op(c, 1);
    var p = block_first(loop_header(l));
    while p >= 0 && is_phi(p) {
        let ok, sv, bop = ln_is_induction_phi(p, l);
        if ok {
            let si = ln_incoming_for_block(p, loop_latch(l));
            if si == o0 || si == o1 { return p; }
            if p == o0 || p == o1 { return p; }
        }
        p = inst_next(p);
    }
    return -1;
}

// Loop::getBounds: the step instruction, or -1 (std::nullopt)
fn ln_bounds_step_inst(l: i32) -> i32 {
    let iv = ln_induction_variable(l);
    if iv < 0 { return -1; }
    let ok, sv, stepi = ln_is_induction_phi(iv, l);
    if !ok || sv < 0 || stepi < 0 { return -1; }
    // getStep / StepValue: only computed (the SCEVs exist already)
    let step = sc_op(sc_get_scev(iv), 1);
    if sc_get_scev(op(stepi, 1)) != step { let x = sc_get_scev(op(stepi, 0)); }
    // findFinalIVValue
    let c = ln_latch_cmp(l);
    if c < 0 { return -1; }
    let o0 = op(c, 0);
    let o1 = op(c, 1);
    if o0 == iv || o0 == stepi || o1 == iv || o1 == stepi { return stepi; }
    return -1;
}

fn ln_unique_successor(bb: i32) -> i32 {
    let t = block_last(bb);
    var r: i32 = -1;
    for k in term_nsucc(t) {
        let s = term_succ(t, k);
        if r >= 0 && r != s { return -1; }
        r = s;
    }
    return r;
}
fn ln_unique_predecessor(bb: i32) -> i32 {
    var r: i32 = -1;
    var bad = false;
    each_pred(bb) { p => if r >= 0 && r != p { bad = true; } r = p; };
    return if bad { -1 } else { r };
}
fn ln_block_size(bb: i32) -> i64 { var n: i64 = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }

// LoopNest::skipEmptyBlockUntil
fn ln_skip_empty_block_until(from: i32, end: i32, check_unique_pred: bool) -> i32 {
    if from == end || ln_unique_successor(from) < 0 { return from; }
    vs_clear(VS_PASS1);
    var bb = ln_unique_successor(from);
    var pred = from;
    while bb >= 0 && bb != end && ln_block_size(bb) == 1 && !vs_has(VS_PASS1, bb) && (!check_unique_pred || ln_unique_predecessor(bb) >= 0) {
        vs_add(VS_PASS1, bb);
        pred = bb;
        bb = ln_unique_successor(bb);
    }
    return if bb == end { end } else { pred };
}

// Loop::getLoopGuardBranch
fn ln_loop_guard_branch(l: i32) -> i32 {
    if !ln_is_loop_simplify_form(l) { return -1; }
    let ph = loop_preheader(l);
    let latch = loop_latch(l);
    if !loop_is_exiting(l, latch) { return -1; }
    let efl = ln_exit_block(l, true);
    if efl < 0 { return -1; }
    let gbb = ln_unique_predecessor(ph);
    if gbb < 0 { return -1; }
    let gbi = block_last(gbb);
    if iop(gbi) != OP_CONDBR { return -1; }
    let other = if term_succ(gbi, 0) == ph { term_succ(gbi, 1) } else { term_succ(gbi, 0) };
    if ln_skip_empty_block_until(efl, other, true) == other { return gbi; }
    return -1;
}

// isSafeToSpeculativelyExecute for the instructions LoopNest checks
fn ln_safe_to_speculate(i: i32) -> bool {
    if iop(i) == OP_LOAD {
        let p = op(i, 0);
        let k = vals[p].kind as i64;
        if k == VK_GVAR || (is_inst(p) && iop(p) == OP_ALLOCA) || (k == VK_ARG && arg_has_attr(p, AK_Dereferenceable)) {
            fatal("print<loopnest>: isSafeToSpeculativelyExecute of loads from dereferenceable pointers is not ported");
        }
        return false;
    }
    return safe_to_speculate(i);
}

// checkSafeInstruction
fn ln_check_safe_instruction(i: i32, guard_cmp: i32, latch_cmp: i32, step_inst: i32) -> bool {
    let o = iop(i);
    let allowed = ln_safe_to_speculate(i) || o == OP_PHI || o == OP_BR || o == OP_CONDBR;
    if !allowed { return false; }
    if (o >= OP_ADD && o <= OP_XOR && i != step_inst) || ((o == OP_ICMP || o == OP_FCMP) && i != latch_cmp && i != guard_cmp) { return false; }
    return true;
}

fn ln_only_safe(bb: i32, guard_cmp: i32, latch_cmp: i32, step_inst: i32) -> bool {
    var i = block_first(bb);
    while i >= 0 {
        if !ln_check_safe_instruction(i, guard_cmp, latch_cmp, step_inst) { return false; }
        i = inst_next(i);
    }
    return true;
}

// checkLoopsStructure
fn ln_check_loops_structure(ol: i32, il: i32) -> bool {
    if loop_nsubs(ol) != 1 || loop_parent(il) != ol { return false; }
    if !ln_is_loop_simplify_form(ol) || !ln_is_loop_simplify_form(il) { return false; }
    let oh = loop_header(ol);
    let olatch = loop_latch(ol);
    let iph = loop_preheader(il);
    let ilatch = loop_latch(il);
    let iexit = ln_exit_block(il, false);
    if loop_exiting_block_of(ol) != olatch || loop_exiting_block_of(il) != ilatch || iexit < 0 { return false; }
    var extra: i32 = -1;
    if oh != iph {
        let ss = ln_skip_empty_block_until(oh, iph, false);
        if ss != iph {
            let bi = block_last(ss);
            if iop(bi) != OP_CONDBR || bi != ln_loop_guard_branch(il) { return false; }
            // ContainsLCSSAPhi(InnerLoopExit)
            var has_lcssa = false;
            var p = block_first(iexit);
            while p >= 0 && is_phi(p) { if phi_nincoming(p) == 1 { has_lcssa = true; } p = inst_next(p); }
            for k in 2 {
                let succ = term_succ(bi, k);
                var pih = succ;
                var pol = succ;
                if ln_block_size(succ) == 1 {
                    pih = ln_skip_empty_block_until(succ, iph, false);
                    pol = ln_skip_empty_block_until(succ, olatch, false);
                }
                if pih == iph { continue; }
                if pol == olatch { continue; }
                if has_lcssa && ln_is_extra_phi_block(succ, iexit, oh) && single_succ_of(succ) == olatch { extra = succ; continue; }
                return false;
            }
        }
    }
    let ie = ln_exit_block(il, false);
    if (extra < 0 || ln_skip_empty_block_until(ie, extra, false) != extra) && ln_skip_empty_block_until(ie, olatch, false) != olatch { return false; }
    return true;
}

fn single_succ_of(bb: i32) -> i32 { let t = block_last(bb); return if term_nsucc(t) == 1 { term_succ(t, 0) } else { -1 }; }

fn ln_is_extra_phi_block(bb: i32, iexit: i32, oh: i32) -> bool {
    if first_non_phi(bb) != block_last(bb) { return false; }
    var p = block_first(bb);
    while p >= 0 && is_phi(p) {
        for k in phi_nincoming(p) { let b = phi_block(p, k); if b != iexit && b != oh { return false; } }
        p = inst_next(p);
    }
    return true;
}

// Loop::getExitingBlock
fn loop_exiting_block_of(l: i32) -> i32 {
    var r: i32 = -1;
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        if loop_is_exiting(l, bb) { if r >= 0 { return -1; } r = bb; }
    }
    return r;
}

// arePerfectlyNested (analyzeLoopNestForPerfectNest == PerfectLoopNest)
fn ln_are_perfectly_nested(ol: i32, il: i32) -> bool {
    if !ln_check_loops_structure(ol, il) { return false; }
    let step_inst = ln_bounds_step_inst(ol);
    if step_inst < 0 { return false; }
    let lc = ln_outer_latch_cmp(ol);
    let gb = ln_loop_guard_branch(il);
    let gc = if gb >= 0 && is_inst(op(gb, 0)) && (iop(op(gb, 0)) == OP_ICMP || iop(op(gb, 0)) == OP_FCMP) { op(gb, 0) } else { -1 };
    let oh = loop_header(ol);
    let olatch = loop_latch(ol);
    let iph = loop_preheader(il);
    if !ln_only_safe(oh, gc, lc, step_inst) || !ln_only_safe(olatch, gc, lc, step_inst) ||
       (iph != oh && !ln_only_safe(iph, gc, lc, step_inst)) || !ln_only_safe(ln_exit_block(il, false), gc, lc, step_inst) { return false; }
    return true;
}

fn ln_outer_latch_cmp(l: i32) -> i32 {
    let t = block_last(loop_latch(l));
    let c = op(t, 0);
    if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) { return c; }
    return -1;
}

// getMaxPerfectDepth
fn ln_max_perfect_depth(root: i32) -> i64 {
    var cur = root;
    var d: i64 = 1;
    while loop_nsubs(cur) == 1 {
        let inner = loop_sub(cur, 0);
        if !ln_are_perfectly_nested(cur, inner) { break; }
        cur = inner;
        d++;
    }
    return d;
}

// LoopNestPrinterPass::run on loop l
fn print_loopnest(l: i32) {
    let fv = loops[l].fv;
    scev_get(fv);
    let mpd = ln_max_perfect_depth(l);
    // Loops: breadth_first(Root)
    var q: i32[>..<] = [];
    q.push(l);
    var h: i64 = 0;
    while h < q.len {
        let x = q[h];
        for k in loop_nsubs(x) { q.push(loop_sub(x, k)); }
        h++;
    }
    let depth = loop_depth(q[q.len - 1]) - loop_depth(q[0]) + 1;
    errs("IsPerfect=");
    errs(if mpd == depth { "true" } else { "false" });
    errs(", Depth=");
    errs_int(depth);
    errs(", OutermostLoop: ");
    errs(ln_loop_name(l));
    errs(", Loops: ( ");
    for x in q { errs(ln_loop_name(x)); errs(" "); }
    errs(")\n");
}

fn ln_loop_name(l: i32) -> const u8[:] {
    let h = loop_header(l);
    if vals[h].name >= 0 { return val_name(h); }
    return "<unnamed loop>";
}
