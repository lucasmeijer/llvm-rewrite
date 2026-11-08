// AssumptionCache (llvm/lib/Analysis/AssumptionCache.cpp: scanFunction, findAffectedValues,
// findValuesAffectedByOperandBundle, AffectedValueCallbackVH::allUsesReplacedWith),
// findValuesAffectedByCondition, isValidAssumeForContext, isEphemeralValueOf and the assumption parts of
// computeKnownBitsFromContext / isKnownNonZeroFromAssume / isKnownToBeAPowerOfTwo /
// isKnownNonEqualFromContext / computeConstantRange / getKnowledgeValidInContext
// (llvm/lib/Analysis/ValueTracking.cpp, AssumeBundleQueries.cpp).
//
// The cache is built for one function at a time on first use (LLVM scans lazily too) and entries are kept
// in registration order: ac_val[k] is affected by assume ac_asm[k] through operand bundle ac_idx[k]
// (-1 = the condition, LLVM's ExprResultIdx).
import std;
import constrange;
import apint;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import knownbits;
import implied;
import crange;
import pm;
import vt;
import poison;

var ac_fn: i32 = -1;
var ac_val: i32[>..<];
var ac_asm: i32[>..<];
var ac_idx: i32[>..<];
var ac_has_any: bool = false;

fn ac_invalidate() { ac_fn = -1; }

fn ac_push(v: i32, a: i32, idx: i64) {
    // updateAffectedValues: dedupe (assume, index) per value
    for k in ac_val.len { if ac_val[k] == v && ac_asm[k] == a && ac_idx[k] as i64 == idx { return; } }
    ac_val.push(v);
    ac_asm.push(a);
    ac_idx.push(idx as i32);
}

// addValueAffectedByCondition
fn ac_add_affected(v: i32, a: i32) {
    if is_arg(v) || is_global(v) { ac_push(v, a, -1); return; }
    if is_inst(v) {
        ac_push(v, a, -1);
        var o: i32 = -1;
        let p = m_ptrtoint_or_addr(v);
        if p >= 0 { o = p; } else if is_op(v, OP_TRUNC) { o = op(v, 0); }
        if o >= 0 && (is_inst(o) || is_arg(o)) { ac_push(o, a, -1); }
    }
}

fn bundle_tag_name(a: i32, k: i64) -> const u8[:] { sbytes(cb_bundle_tag(a, k)) }

// findValuesAffectedByCondition(Cond, IsAssume = true)
fn ac_affected_by_condition(cond: i32, a: i32) {
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    wl.push(cond);
    while wl.len > 0 {
        let v = wl.pop();
        var seen = false;
        for x in visited { if x == v { seen = true; } }
        if seen { continue; }
        visited.push(v);
        ac_add_affected(v, a);
        let nx = m_not(v);
        if nx >= 0 { ac_add_affected(nx, a); }
        if m_logical(v, true) || m_logical(v, false) {
            // IsAssume: not split
        } else if is_inst_op(v, OP_ICMP) {
            let p = inst_pred(v);
            let aa = op(v, 0);
            let b = op(v, 1);
            let has_rhsc = m_constant_int(b) >= 0;
            if p == P_EQ || p == P_NE {
                ac_add_affected(aa, a);
                ac_add_affected(b, a);
                if has_rhsc {
                    if (is_op(aa, OP_SHL) || is_op(aa, OP_LSHR) || is_op(aa, OP_ASHR)) && m_constant_int(op(aa, 1)) >= 0 {
                        ac_add_affected(op(aa, 0), a);
                    } else if is_op(aa, OP_AND) || is_op(aa, OP_OR) {
                        ac_add_affected(op(aa, 0), a);
                        ac_add_affected(op(aa, 1), a);
                    } else if is_op(aa, OP_SUB) {
                        ac_add_affected(op(aa, 0), a);
                        ac_add_affected(op(aa, 1), a);
                    }
                }
            } else {
                ac_add_affected(aa, a);
                ac_add_affected(b, a);
                if has_rhsc {
                    if (is_op(aa, OP_ADD) || (is_op(aa, OP_OR) && op_disjoint(aa))) && m_constant_int(op(aa, 1)) >= 0 {
                        ac_add_affected(op(aa, 0), a);
                    }
                    if pred_is_unsigned(p) {
                        if is_op(aa, OP_AND) || is_op(aa, OP_OR) || (is_op(aa, OP_ADD) && op_nuw(aa)) {
                            ac_add_affected(op(aa, 0), a);
                            ac_add_affected(op(aa, 1), a);
                        }
                        if is_op(aa, OP_SUB) && op_nuw(aa) { ac_add_affected(op(aa, 0), a); }
                    }
                }
                if is_op(aa, OP_BITCAST) && elementwise_bitcast_v(aa) {
                    let x = op(aa, 0);
                    if (p == P_SLT && m_zero(b)) || (p == P_SGT && m_all_ones(b)) { ac_push(x, a, -1); }
                }
            }
            if has_rhsc && m_intrinsic(aa, IID_ctpop) { ac_add_affected(op(aa, 0), a); }
        } else if is_inst_op(v, OP_FCMP) {
            var aa = op(v, 0);
            ac_add_affected(aa, a);
            ac_add_affected(op(v, 1), a);
            if is_op(aa, OP_FNEG) { aa = op(aa, 0); ac_add_affected(aa, a); }
            if m_intrinsic(aa, IID_fabs) { aa = op(aa, 0); ac_add_affected(aa, a); }
        } else if m_intrinsic(v, IID_is_fpclass) {
            ac_add_affected(op(v, 0), a);
        }
    }
}

fn ac_build(fv: i32) {
    if ac_fn == fv { return; }
    ac_fn = fv;
    ac_val.clear();
    ac_asm.clear();
    ac_idx.clear();
    ac_has_any = false;
    var handles: i32[>..<] = [];
    each_inst(fv) { i => if inst_iid(i) == IID_assume { handles.push(i); } };
    for a in handles { ac_update_affected(a); }
}

// AssumptionCache::registerAssumption(CI): only once the cache has scanned the function
fn ac_register_assumption(a: i32) {
    if ac_fn < 0 || ac_fn != inst_func(a) { return; }
    ac_update_affected(a);
}

// AssumptionCache::updateAffectedValues(CI)
fn ac_update_affected(a: i32) {
    {
        ac_has_any = true;
        // operand bundles first
        for k in cb_nbundles(a) {
            let tag = bundle_tag_name(a, k);
            let b = cb_bundle_begin(a, k);
            let n = cb_bundle_count(a, k);
            if tag == "separate_storage" {
                for j in 2 {
                    let u = get_underlying_object(op(a, b + j), 10);
                    if is_arg(u) || is_global(u) || is_inst(u) { ac_push(u, a, k); }
                }
            } else if n > 0 && tag != "ignore" {
                let w = op(a, b);
                if is_arg(w) || is_global(w) || is_inst(w) { ac_push(w, a, k); }
            }
        }
        ac_affected_by_condition(cb_arg(a, 0), a);
    }
}

// AffectedValueCallbackVH::allUsesReplacedWith(NV)
fn ac_rauw(old: i32, nv: i32) {
    if ac_fn < 0 { return; }
    if !is_inst(nv) && !is_arg(nv) { return; }
    let n = ac_val.len;
    var any = false;
    for k in n {
        if ac_val[k] != old { continue; }
        any = true;
        var dup = false;
        for j in ac_val.len { if ac_val[j] == nv && ac_asm[j] == ac_asm[k] && ac_idx[j] == ac_idx[k] { dup = true; } }
        if !dup { ac_val.push(nv); ac_asm.push(ac_asm[k]); ac_idx.push(ac_idx[k]); }
    }
    if any { for k in ac_val.len { if ac_val[k] == old { ac_val[k] = -1; } } }
}

// The current function's assumption cache (context function), -1 when there is no context
fn ac_ready() -> bool {
    if kb_cxt < 0 || sq_no_ac { return false; }
    ac_build(inst_func(kb_cxt));
    return ac_has_any;
}

// isEphemeralValueOf
fn is_ephemeral_value_of(i: i32, e: i32) -> bool {
    for k in nops(i) { if op(i, k) == e { return true; } }
    if !is_inst(e) { return false; }
    if e == i { return true; }
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    visited.push(e);
    wl.push(e);
    var reaches = false;
    while wl.len > 0 {
        let v = wl.pop();
        var u = vals[v].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if ui == i { reaches = true; continue; }
            if inst_may_have_side_effects(ui) || is_terminator(ui) { return false; }
            var seen = false;
            for x in visited { if x == ui { seen = true; } }
            if !seen { visited.push(ui); wl.push(ui); }
        }
    }
    return reaches;
}

// isValidAssumeForContext(Inv, CxtI, DT, AllowEphemerals = false)
// SimplifyQuery::AllowEphemerals (set around a query by its caller, e.g. ScalarEvolution::getConstantMultiple)
var vt_allow_ephemerals: bool = false;

fn valid_assume_for_context(inv: i32, cx: i32) -> bool {
    if inst_parent(inv) == inst_parent(cx) {
        if comes_before(inv, cx) { return true; }
        if !vt_allow_ephemerals && inv == cx { return false; }
        var x = cx;
        var limit = 15;
        while x >= 0 && x != inv {
            limit--;
            if limit == 0 { return false; }
            if !guaranteed_to_transfer(x) { return false; }
            x = inst_next(x);
        }
        return vt_allow_ephemerals || !is_ephemeral_value_of(inv, cx);
    }
    if sq_no_dt {
        // no DT: trivially dominating cases only
        let ib = inst_parent(inv);
        return ib == single_pred(inst_parent(cx)) || ib == func_entry(inst_func(inv));
    }
    return dom_inst(inv, cx);
}

// computeKnownBitsFromContext: the assumption loop
recursive fn kb_from_assumptions(v: i32, known0: KB, depth: i64) -> KB {
    var known = known0;
    let w = kb_bw(known);
    if kb_cxt < 0 || sq_no_ac { return known; }
    // with an AssumptionCache, conflicting known bits are reset even when there are no assumptions
    if !ac_ready() { if kb_has_conflict(known) { return kb_unknown(w); } return known; }
    let cx = kb_cxt;
    for k in ac_val.len {
        if ac_val[k] != v { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        if ac_idx[k] >= 0 {
            let bi = ac_idx[k] as i64;
            if bundle_tag_name(a, bi) == "align" {
                let b = cb_bundle_begin(a, bi);
                let n = cb_bundle_count(a, bi);
                // getAssumeAlignInfo: (ptr, align[, offset])
                let ptr = op(a, b);
                if ptr == v && n >= 2 {
                    let ac = m_constant_int(op(a, b + 1));
                    var offc: i32 = -2;
                    if n >= 3 { offc = m_constant_int(op(a, b + 2)); }
                    if ac >= 0 && offc != -1 {
                        // the alignment and offset are getZExtValue()s of i64 operands
                        let al = ap_zext64(ci_ap(ac));
                        let off = if offc >= 0 { ap_zext64(ci_ap(offc)) } else { 0 };
                        if al != 0 && (al & (al - 1)) == 0 && valid_assume_for_context(a, cx) {
                            known = kb_or_z(known, ap_u64((al - 1) & ~off, w));
                            known = kb_or_o(known, ap_u64((al - 1) & off, w));
                        }
                    }
                }
            }
            continue;
        }
        let arg = cb_arg(a, 0);
        if arg == v && valid_assume_for_context(a, cx) { return kb_const_ap(ap_ones(w)); }
        if m_not(arg) == v && valid_assume_for_context(a, cx) { return kb_all_zero(w); }
        if is_inst_op(arg, OP_TRUNC) && op(arg, 0) == v && valid_assume_for_context(a, cx) {
            if op_nuw(arg) { return kb_const(1, w); }
            known.o = ap_set_bit(known.o, 0);
            return known;
        }
        if depth == MAX_ANALYSIS_DEPTH { continue; }
        if !is_inst_op(arg, OP_ICMP) { continue; }
        if !valid_assume_for_context(a, cx) { continue; }
        known = kb_from_icmp_cond(v, arg, known, false);
    }
    if kb_has_conflict(known) { known = kb_unknown(w); }
    return known;
}

// assumeBundleImpliesNonNull
fn bundle_implies_nonnull(v: i32, fv: i32, a: i32, k: i64) -> bool {
    let tag = bundle_tag_name(a, k);
    let b = cb_bundle_begin(a, k);
    let n = cb_bundle_count(a, k);
    if n == 0 || op(a, b) != v { return false; }
    if tag == "nonnull" { return true; }
    if tag == "dereferenceable" {
        if n < 2 { return false; }
        let c = m_constant_int(op(a, b + 1));
        return c >= 0 && !ap_is_zero(ci_ap(c)) && !null_pointer_is_defined(fv, ptr_as(vals[v].ty));
    }
    return false;
}

// isKnownNonZeroFromAssume
fn nonzero_from_assume(v: i32) -> bool {
    if !ac_ready() { return false; }
    let cx = kb_cxt;
    for k in ac_val.len {
        if ac_val[k] != v { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        if ac_idx[k] >= 0 {
            if bundle_implies_nonnull(v, inst_func(cx), a, ac_idx[k] as i64) && valid_assume_for_context(a, cx) { return true; }
            continue;
        }
        let c = cb_arg(a, 0);
        if !is_op(c, OP_ICMP) { continue; }
        fn mv(x: i32, v: i32) -> bool { x == v || (is_op(x, OP_PTRTOINT) && op(x, 0) == v) }
        var p = cmp_pred_of(c);
        var rhs: i32 = -1;
        if mv(op(c, 0), v) { rhs = op(c, 1); }
        else if mv(op(c, 1), v) { rhs = op(c, 0); p = pred_swapped(p); }
        if rhs < 0 { continue; }
        if cmp_excludes_zero(p, rhs) && valid_assume_for_context(a, cx) { return true; }
    }
    return false;
}

// isKnownToBeAPowerOfTwo: assumptions
fn pow2_from_assume(v: i32, or_zero: bool) -> bool {
    if !ac_ready() { return false; }
    let cx = kb_cxt;
    for k in ac_val.len {
        if ac_val[k] != v || ac_idx[k] >= 0 { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        let c = cb_arg(a, 0);
        // isImpliedToBeAPowerOfTwoFromCond(V, OrZero, Cond, true)
        if !is_op(c, OP_ICMP) { continue; }
        let l = op(c, 0);
        let rc = m_apint(op(c, 1));
        if !m_intrinsic(l, IID_ctpop) || op(l, 0) != v || rc < 0 { continue; }
        let p = cmp_pred_of(c);
        let ok = (or_zero && p == P_ULT && ap_eq_u64(ci_ap(rc), 2)) || (p == P_EQ && ap_eq_u64(ci_ap(rc), 1));
        if ok && valid_assume_for_context(a, cx) { return true; }
    }
    return false;
}

// isKnownNonEqualFromContext: assumptions
fn nonequal_from_assume(v1: i32, v2: i32, depth: i64) -> bool {
    if !ac_ready() { return false; }
    let cx = kb_cxt;
    for k in ac_val.len {
        if ac_val[k] != v1 || ac_idx[k] >= 0 { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        if implied_condition(cb_arg(a, 0), cp(P_NE, false), v1, v2, true, depth) == 1 && valid_assume_for_context(a, cx) { return true; }
    }
    return false;
}

// computeConstantRange: assumptions
recursive fn range_from_assumptions(v: i32, cr0: CRange, depth: i64) -> CRange {
    var cr = cr0;
    if !ac_ready() { return cr; }
    let cx = kb_cxt;
    for k in ac_val.len {
        if ac_val[k] != v || ac_idx[k] >= 0 { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        if !valid_assume_for_context(a, cx) { continue; }
        let c = cb_arg(a, 0);
        if !is_inst_op(c, OP_ICMP) || op(c, 0) != v { continue; }
        let save = kb_cxt;
        kb_cxt = a;
        let rhs = compute_constant_range(op(c, 1), false, true, depth + 1);
        kb_cxt = save;
        cr = rg_intersect(cr, cr_allowed_icmp_cp(inst_pred(c), has_flag(c, FL_SAMESIGN), rhs));
    }
    return cr;
}
// ConstantRange::makeAllowedICmpRegion(CmpPredicate, CR)
fn cr_allowed_icmp_cp(p: i64, samesign: bool, c: CRange) -> CRange {
    let r = rg_allowed_icmp(p, c);
    if !samesign { return r; }
    // getPreferredSignedPredicate: the signed form of the predicate
    return rg_intersect(r, rg_allowed_icmp(if pred_is_unsigned(p) { p + 4 } else { p }, c));
}

// simplifyICmpWithDominatingAssume: 1/0 or -1
fn icmp_from_dominating_assume(p: i64, l: i32, r: i32) -> i64 {
    if !ac_ready() { return -1; }
    let cx = kb_cxt;
    for side in 2 {
        let base = if side == 0 { l } else { r };
        for k in ac_val.len {
            if ac_val[k] != base || ac_idx[k] >= 0 { continue; }
            let a = ac_asm[k];
            if is_dead(a) { continue; }
            let imp = implied_condition(cb_arg(a, 0), p, l, r, true, 0);
            if imp >= 0 && valid_assume_for_context(a, cx) { return imp; }
        }
    }
    return -1;
}

// getKnowledgeValidInContext(V, {NoUndef}, AC, CtxI, DT)
fn noundef_from_assume(v: i32, cx: i32) -> bool {
    if cx < 0 { return false; }
    ac_build(inst_func(cx));
    if !ac_has_any { return false; }
    for k in ac_val.len {
        if ac_val[k] != v || ac_idx[k] < 0 { continue; }
        let a = ac_asm[k];
        if is_dead(a) { continue; }
        let bi = ac_idx[k] as i64;
        if bundle_tag_name(a, bi) != "noundef" { continue; }
        if cb_bundle_count(a, bi) == 0 || op(a, cb_bundle_begin(a, bi)) != v { continue; }
        if valid_assume_for_context(a, cx) { return true; }
    }
    return false;
}
