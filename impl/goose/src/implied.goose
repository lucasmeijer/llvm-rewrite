// Condition implication: port of isImpliedCondition / isImpliedCondICmps / isImpliedCondOperands /
// isTruePredicate / isImpliedCondAndOr / isImpliedByDomCondition (llvm/lib/Analysis/ValueTracking.cpp) and
// ICmpInst::isImpliedByMatchingCmp / CmpPredicate::getMatching (llvm/lib/IR/Instructions.cpp).
// Not ported (fail loudly): the constant-range path (a common operand compared with a constant) and fcmps.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;

let P_EQ = 32;
let P_NE = 33;
let P_UGT = 34;
let P_UGE = 35;
let P_ULT = 36;
let P_ULE = 37;
let P_SGT = 38;
let P_SGE = 39;
let P_SLT = 40;
let P_SLE = 41;

// A CmpPredicate: predicate | samesign << 8.
fn cp(p: i64, ss: bool) -> i64 { p | (if ss { 256 } else { 0 }) }
fn cp_pred(c: i64) -> i64 { c & 255 }
fn cp_ss(c: i64) -> bool { (c & 256) != 0 }

fn pred_inverse(p: i64) -> i64 {
    match p { P_EQ => P_NE, P_NE => P_EQ, P_UGT => P_ULE, P_UGE => P_ULT, P_ULT => P_UGE, P_ULE => P_UGT,
              P_SGT => P_SLE, P_SGE => P_SLT, P_SLT => P_SGE, P_SLE => P_SGT, _ => p }
}
fn pred_swapped(p: i64) -> i64 {
    match p { P_UGT => P_ULT, P_UGE => P_ULE, P_ULT => P_UGT, P_ULE => P_UGE,
              P_SGT => P_SLT, P_SGE => P_SLE, P_SLT => P_SGT, P_SLE => P_SGE, _ => p }
}
fn pred_is_signed(p: i64) -> bool { p >= P_SGT && p <= P_SLE }
fn pred_is_unsigned(p: i64) -> bool { p >= P_UGT && p <= P_ULE }
fn pred_flipped_signedness(p: i64) -> i64 {
    if pred_is_signed(p) { return p - 4; }
    if pred_is_unsigned(p) { return p + 4; }
    return p;
}
fn pred_true_when_equal(p: i64) -> bool { p == P_EQ || p == P_UGE || p == P_ULE || p == P_SGE || p == P_SLE }

// CmpPredicate::getMatching; -1 if none.
fn cp_get_matching(a: i64, b: i64) -> i64 {
    let ap = cp_pred(a);
    let bp = cp_pred(b);
    if ap == bp { return if cp_ss(a) == cp_ss(b) { a } else { ap }; }
    if cp_ss(a) && ap == pred_flipped_signedness(bp) { return bp; }
    if cp_ss(b) && bp == pred_flipped_signedness(ap) { return ap; }
    return -1;
}

fn implied_true_by_matching(a0: i64, b0: i64) -> bool {
    if cp_get_matching(a0, b0) >= 0 { return true; }
    var p1 = cp_pred(a0);
    var p2 = cp_pred(b0);
    if cp_ss(a0) && pred_is_signed(p2) { p1 = pred_flipped_signedness(p1); }
    else if cp_ss(b0) && pred_is_signed(p1) { p2 = pred_flipped_signedness(p2); }
    if p1 == P_EQ { return p2 == P_UGE || p2 == P_ULE || p2 == P_SGE || p2 == P_SLE; }
    if p1 == P_UGT { return p2 == P_NE || p2 == P_UGE; }
    if p1 == P_ULT { return p2 == P_NE || p2 == P_ULE; }
    if p1 == P_SGT { return p2 == P_NE || p2 == P_SGE; }
    if p1 == P_SLT { return p2 == P_NE || p2 == P_SLE; }
    return false;
}
// ICmpInst::isImpliedByMatchingCmp: 1 true, 0 false, -1 unknown.
fn implied_by_matching_cmp(a: i64, b: i64) -> i64 {
    if implied_true_by_matching(a, b) { return 1; }
    if implied_true_by_matching(a, cp(pred_inverse(cp_pred(b)), cp_ss(b))) { return 0; }
    return -1;
}

fn icmp_cp(c: i32) -> i64 { cp(insts[inst_of(c)].pred as i64, (insts[inst_of(c)].flags & FL_SAMESIGN) != 0) }

fn apint_of(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT { return ty_bits(vals[v].ty) <= 64; }
    if (k == VK_CDVECTOR || k == VK_CVECTOR) && nops(v) > 0 {
        let e = op(v, 0);
        if vals[e].kind != VK_CINT { return false; }
        for i in nops(v) { if op(v, i) != e { return false; } }
        return ty_bits(vals[e].ty) <= 64;
    }
    return false;
}
fn apint_val(v: i32) -> u64 { if vals[v].kind == VK_CINT { cint_lo(v) } else { cint_lo(op(v, 0)) } }
fn apint_w(v: i32) -> i64 { ty_bits(ty_scalar(vals[v].ty)) }
fn apint_sext(v: i32) -> i64 {
    let w = apint_w(v);
    let x = apint_val(v);
    if w >= 64 { return x as! i64; }
    return ((x << (64 - w)) as! i64) >> (64 - w);
}
fn apint_is_neg(v: i32) -> bool { apint_sext(v) < 0 }

fn binop_is(v: i32, o: i64) -> bool { is_inst(v) && iop(v) == o }
fn has_nsw(v: i32) -> bool { (insts[inst_of(v)].flags & FL_NSW) != 0 }
fn has_nuw(v: i32) -> bool { (insts[inst_of(v)].flags & FL_NUW) != 0 }
fn has_disjoint(v: i32) -> bool { (insts[inst_of(v)].flags & FL_DISJOINT) != 0 }
// m_c_<minmax>(m_Specific(x), m_Value())
fn is_minmax_of(v: i32, id: i32, x: i32) -> bool { inst_iid(v) == id && (op(v, 0) == x || op(v, 1) == x) }
// m_NSWAddLike(X, C) / m_NUWAddLike: add nsw/nuw X, C or or disjoint X, C. Returns X or -1.
fn addlike_base(v: i32, nsw: bool) -> i32 {
    if !is_inst(v) { return -1; }
    let o = iop(v);
    let ok = (o == OP_ADD && (if nsw { has_nsw(v) } else { has_nuw(v) })) || (o == OP_OR && has_disjoint(v));
    if ok && apint_of(op(v, 1)) { return op(v, 0); }
    return -1;
}

// isTruePredicate(Pred, LHS, RHS) for SLE / ULE
fn is_true_predicate(p: i64, l: i32, r: i32) -> bool {
    if pred_true_when_equal(p) && l == r { return true; }
    if p == P_SLE {
        if (binop_is(r, OP_ADD) && has_nsw(r) && op(r, 0) == l && apint_of(op(r, 1))) ||
           (binop_is(r, OP_OR) && op(r, 0) == l && apint_of(op(r, 1))) {
            return !apint_is_neg(op(r, 1));
        }
        if is_minmax_of(r, IID_smax, l) { return true; }
        if is_minmax_of(l, IID_smin, r) { return true; }
        let x = addlike_base(l, true);
        if x >= 0 && addlike_base(r, true) == x { return apint_sext(op(l, 1)) <= apint_sext(op(r, 1)); }
        return false;
    }
    if p == P_ULE {
        if binop_is(r, OP_ADD) && (op(r, 0) == l || op(r, 1) == l) && has_nuw(r) { return true; }
        if binop_is(r, OP_OR) && (op(r, 0) == l || op(r, 1) == l) { return true; }
        if is_minmax_of(r, IID_umax, l) { return true; }
        if binop_is(l, OP_LSHR) && op(l, 0) == r { return true; }
        if binop_is(l, OP_UDIV) && op(l, 0) == r && apint_of(op(l, 1)) && apint_val(op(l, 1)) > 1 { return true; }
        if binop_is(l, OP_AND) && (op(l, 0) == r || op(l, 1) == r) { return true; }
        if is_minmax_of(l, IID_umin, r) { return true; }
        let x = addlike_base(l, false);
        if x >= 0 && addlike_base(r, false) == x { return apint_val(op(l, 1)) <= apint_val(op(r, 1)); }
        return false;
    }
    return false;
}

// isImpliedCondOperands
fn implied_cond_operands(p: i64, al: i32, ar: i32, bl: i32, br: i32) -> i64 {
    if p == P_SLT || p == P_SLE { if is_true_predicate(P_SLE, bl, al) && is_true_predicate(P_SLE, ar, br) { return 1; } }
    else if p == P_SGT || p == P_SGE { if is_true_predicate(P_SLE, al, bl) && is_true_predicate(P_SLE, br, ar) { return 1; } }
    else if p == P_ULT || p == P_ULE { if is_true_predicate(P_ULE, bl, al) && is_true_predicate(P_ULE, ar, br) { return 1; } }
    else if p == P_UGT || p == P_UGE { if is_true_predicate(P_ULE, al, bl) && is_true_predicate(P_ULE, br, ar) { return 1; } }
    return -1;
}

fn is_imm_constant(v: i32) -> bool { is_constant(v) && vals[v].kind != VK_CEXPR && !is_global(v) }

// isImpliedCondICmps
fn implied_cond_icmps(lp0: i64, l00: i32, l10: i32, rp0: i64, r00: i32, r10: i32, lhs_true: bool) -> i64 {
    var lp = lp0;
    var rp = rp0;
    var l0 = l00;
    var l1 = l10;
    var r0 = r00;
    var r1 = r10;
    if !lhs_true { lp = cp(pred_inverse(cp_pred(lp)), cp_ss(lp)); }
    if l0 == r1 { let t = r0; r0 = r1; r1 = t; rp = cp(pred_swapped(cp_pred(rp)), cp_ss(rp)); }
    if r0 == l1 { let t = l0; l0 = l1; l1 = t; lp = cp(pred_swapped(cp_pred(lp)), cp_ss(lp)); }
    if l1 == r1 {
        if l0 != r0 || is_imm_constant(l0) {
            let t = l0; l0 = l1; l1 = t; lp = cp(pred_swapped(cp_pred(lp)), cp_ss(lp));
            let u = r0; r0 = r1; r1 = u; rp = cp(pred_swapped(cp_pred(rp)), cp_ss(rp));
        }
    }
    if l0 == r0 && (apint_of(l1) || apint_of(r1)) {
        fatal("isImpliedCondition: the constant-range case (computeConstantRange) is not ported yet");
    }
    if l0 == r0 && l1 == r1 { return implied_by_matching_cmp(lp, rp); }
    var slp = cp_pred(lp);
    if cp_ss(lp) && pred_is_unsigned(slp) { slp = pred_flipped_signedness(slp); }
    let r0_is_sub = binop_is(r0, OP_SUB) && has_nsw(r0) && op(r0, 0) == l0 && op(r0, 1) == l1;
    if (slp == P_SGT || slp == P_SGE) && r0_is_sub {
        // m_NonPositive: a constant (splat) <= 0
        if apint_of(r1) && apint_sext(r1) <= 0 && implied_by_matching_cmp(slp, rp) == 0 { return 0; }
        if !apint_of(r1) && is_constant(r1) { fatal("isImpliedCondition: m_NonPositive of a non-splat constant is not ported"); }
    }
    if (slp == P_SLT || slp == P_SLE) && r0_is_sub {
        if apint_of(r1) && apint_sext(r1) >= 0 && implied_by_matching_cmp(slp, rp) == 1 { return 1; }
        if !apint_of(r1) && is_constant(r1) { fatal("isImpliedCondition: m_NonNegative of a non-splat constant is not ported"); }
    }
    let lpp = cp_pred(lp);
    let rpp = cp_pred(rp);
    if lpp == P_EQ && (rpp == P_EQ || rpp == P_NE) && apint_of(l1) && apint_val(l1) != 0 && binop_is(l0, OP_SUB) {
        let a = op(l0, 0);
        let b = op(l0, 1);
        if (a == r0 && b == r1) || (a == r1 && b == r0) { return if rpp == P_NE { 1 } else { 0 }; }
        if binop_is(a, OP_PTRTOINT) || binop_is(a, OP_PTRTOADDR) { fatal("isImpliedCondition: ptrtoint sub pattern is not ported"); }
    }
    if l0 == r0 && (lpp == P_ULT || lpp == P_UGE) && (rpp == P_ULT || rpp == P_UGE) && binop_is(l0, OP_ADD) &&
       ((op(l0, 0) == l1 && op(l0, 1) == r1) || (op(l0, 0) == r1 && op(l0, 1) == l1)) {
        return if cp_get_matching(lp, rp) >= 0 { 1 } else { 0 };
    }
    let m = cp_get_matching(lp, rp);
    if m >= 0 { return implied_cond_operands(cp_pred(m), l0, l1, r0, r1); }
    return -1;
}

fn is_not_of(v: i32) -> i32 {
    // m_Not(X): xor X, -1 (either operand order: m_Not is m_c_Xor(X, AllOnes))
    if !binop_is(v, OP_XOR) { return -1; }
    fn all_ones(x: i32) -> bool { apint_of(x) && apint_val(x) == (if apint_w(x) >= 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << apint_w(x)) - 1 }) }
    if all_ones(op(v, 1)) { return op(v, 0); }
    if all_ones(op(v, 0)) { return op(v, 1); }
    return -1;
}

// isImpliedCondition(LHS, RHSPred, RHSOp0, RHSOp1, LHSIsTrue, Depth)
recursive fn implied_condition(lhs0: i32, rp: i64, r0: i32, r1: i32, lhs_true0: bool, depth: i64) -> i64 {
    if depth == 6 { return -1; }
    var lhs = lhs0;
    var lhs_true = lhs_true0;
    if ty_is_vector(vals[r0].ty) != ty_is_vector(vals[lhs].ty) { return -1; }
    let nx = is_not_of(lhs);
    if nx >= 0 { lhs = nx; lhs_true = !lhs_true; }
    let st = ty_scalar(vals[r0].ty);
    if ty_is_int(st) || ty_kind(st) == TK_PTR {
        if binop_is(lhs, OP_ICMP) { return implied_cond_icmps(icmp_cp(lhs), op(lhs, 0), op(lhs, 1), rp, r0, r1, lhs_true); }
        if binop_is(lhs, OP_TRUNC) && has_nuw(lhs) { fatal("isImpliedCondition: m_ICmpLike(trunc nuw) is not ported"); }
    } else {
        if binop_is(lhs, OP_FCMP) { fatal("isImpliedCondition: fcmp conditions are not ported"); }
    }
    if is_inst(lhs) {
        let o = iop(lhs);
        if o == OP_AND || o == OP_OR || o == OP_SELECT {
            // isImpliedCondAndOr: m_LogicalOr / m_LogicalAnd
            var a: i32 = -1;
            var b: i32 = -1;
            let i1 = ty_bits(ty_scalar(vals[lhs].ty)) == 1;
            if o == OP_AND && i1 && lhs_true { a = op(lhs, 0); b = op(lhs, 1); }
            if o == OP_OR && i1 && !lhs_true { a = op(lhs, 0); b = op(lhs, 1); }
            if o == OP_SELECT && i1 && ty_bits(ty_scalar(vals[op(lhs, 0)].ty)) == 1 {
                let t = op(lhs, 1);
                let f = op(lhs, 2);
                // select c, x, false == and; select c, true, x == or
                if lhs_true && is_cint(f) && cint_is_zero(f) { a = op(lhs, 0); b = t; }
                if !lhs_true && is_cint(t) && cint_lo(t) == 1 { a = op(lhs, 0); b = f; }
                if (is_constant(f) && !is_cint(f)) || (is_constant(t) && !is_cint(t)) { fatal("isImpliedCondition: logical and/or with vector constants is not ported"); }
            }
            if a >= 0 {
                let x = implied_condition(a, rp, r0, r1, lhs_true, depth + 1);
                if x >= 0 { return x; }
                return implied_condition(b, rp, r0, r1, lhs_true, depth + 1);
            }
        }
    }
    return -1;
}

// isImpliedByDomCondition(Pred, LHS, RHS, ContextI): 1 true, 0 false, -1 unknown.
fn implied_by_dom_condition(p: i64, l: i32, r: i32, cxt: i32) -> i64 {
    if cxt < 0 { return -1; }
    let bb = inst_parent(cxt);
    if bb < 0 { return -1; }
    let pb = single_pred(bb);
    if pb < 0 { return -1; }
    let t = block_terminator(pb);
    if iop(t) != OP_CONDBR { return -1; }
    let tb = op(t, 1);
    let fb = op(t, 2);
    if tb == fb { return -1; }
    return implied_condition(op(t, 0), cp(p, false), l, r, tb == bb, 0);
}
