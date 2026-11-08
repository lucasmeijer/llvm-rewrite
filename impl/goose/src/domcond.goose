// DomConditionCache: port of llvm/lib/Analysis/DomConditionCache.cpp and of findValuesAffectedByCondition
// with IsAssume = false (llvm/lib/Analysis/ValueTracking.cpp).
//
// One cache at a time (InstCombine's DC, active between dc_begin and dc_end; LLVM passes it in the
// SimplifyQuery). conditionsFor(V) is the list of registered branches affected by V, in registration
// order: an intrusive list per value id (dc_head/dc_tail, stamped with the cache's epoch).
import std;
import ir;
import irutil;
import pm;
import gen_iids;
import assume;
import knownbits;
import vt;
import implied;
import fpclass;
import apint;
import poison;

var dc_active: bool = false;
var dc_epoch: u32 = 1;
var dc_stamp: u32[>..];
var dc_head: i32[>..];
var dc_tail: i32[>..];
var dc_ebr: i32[>..];     // entry -> branch
var dc_enext: i32[>..];   // entry -> next entry of the same value

fn dc_begin(fv: i32) { dc_active = true; dc_epoch += 1; dc_ebr.resize(0); dc_enext.resize(0); }
fn dc_end() { dc_active = false; dc_epoch += 1; }

fn dc_grow(v: i32) { while dc_stamp.len <= (v as i64) { dc_stamp.push(0); dc_head.push(-1); dc_tail.push(-1); } }
// first entry of conditionsFor(v), -1 = none; walk with dc_next
fn dc_first(v: i32) -> i32 {
    if !dc_active || v < 0 || (v as i64) >= dc_stamp.len || dc_stamp[v] != dc_epoch { return -1; }
    return dc_head[v];
}
fn dc_next(e: i32) -> i32 { dc_enext[e] }
fn dc_branch(e: i32) -> i32 { dc_ebr[e] }
fn dc_has_conditions(v: i32) -> bool { dc_first(v) >= 0 }

fn dc_add(v: i32, br: i32) {
    if v < 0 { return; }
    dc_grow(v);
    if dc_stamp[v] != dc_epoch { dc_stamp[v] = dc_epoch; dc_head[v] = -1; dc_tail[v] = -1; }
    var e = dc_head[v];
    while e >= 0 { if dc_ebr[e] == br { return; } e = dc_enext[e]; }
    let ne = dc_ebr.len as i32;
    dc_ebr.push(br);
    dc_enext.push(-1);
    if dc_tail[v] >= 0 { dc_enext[dc_tail[v]] = ne; } else { dc_head[v] = ne; }
    dc_tail[v] = ne;
}
// DomConditionCache::removeValue
fn dc_remove_value(v: i32) {
    if !dc_active || (v as i64) >= dc_stamp.len { return; }
    if dc_stamp[v] == dc_epoch { dc_head[v] = -1; dc_tail[v] = -1; }
}

// addValueAffectedByCondition into a list
fn dc_add_affected(v: i32, out: i32[>..<]&) {
    if is_arg(v) || is_global(v) { out.push(v); return; }
    if is_inst(v) {
        out.push(v);
        var o: i32 = -1;
        let p = m_ptrtoint_or_addr(v);
        if p >= 0 { o = p; } else if is_op(v, OP_TRUNC) { o = op(v, 0); }
        if o >= 0 && (is_inst(o) || is_arg(o)) { out.push(o); }
    }
}

// findValuesAffectedByCondition(Cond, IsAssume = false, ...)
fn dc_affected_by_condition(cond: i32, out: i32[>..<]&) {
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    wl.push(cond);
    while wl.len > 0 {
        let v = wl.pop();
        var seen = false;
        for x in visited { if x == v { seen = true; } }
        if seen { continue; }
        visited.push(v);
        if m_logical(v, true) || m_logical(v, false) {
            wl.push(lg_a);
            wl.push(lg_b);
        } else if is_inst_op(v, OP_ICMP) {
            let p = inst_pred(v);
            let aa = op(v, 0);
            let b = op(v, 1);
            let has_rhsc = m_constant_int(b) >= 0;
            if p == 32 || p == 33 {
                dc_add_affected(aa, out);
                if has_rhsc {
                    if (is_op(aa, OP_SHL) || is_op(aa, OP_LSHR) || is_op(aa, OP_ASHR)) && m_constant_int(op(aa, 1)) >= 0 {
                        dc_add_affected(op(aa, 0), out);
                    } else if is_op(aa, OP_AND) || is_op(aa, OP_OR) {
                        dc_add_affected(op(aa, 0), out);
                        dc_add_affected(op(aa, 1), out);
                    } else if is_op(aa, OP_SUB) {
                        dc_add_affected(op(aa, 0), out);
                        dc_add_affected(op(aa, 1), out);
                    }
                }
            } else {
                if is_constant(b) { dc_add_affected(aa, out); }
                if has_rhsc {
                    if (is_op(aa, OP_ADD) || (is_op(aa, OP_OR) && op_disjoint(aa))) && m_constant_int(op(aa, 1)) >= 0 {
                        dc_add_affected(op(aa, 0), out);
                    }
                    if p >= 34 && p <= 37 {
                        if is_op(aa, OP_AND) || is_op(aa, OP_OR) || (is_op(aa, OP_ADD) && op_nuw(aa)) {
                            dc_add_affected(op(aa, 0), out);
                            dc_add_affected(op(aa, 1), out);
                        }
                        if is_op(aa, OP_SUB) && op_nuw(aa) { dc_add_affected(op(aa, 0), out); }
                    }
                }
                if is_op(aa, OP_BITCAST) && elementwise_bitcast_v(aa) {
                    let x = op(aa, 0);
                    if (p == 40 && m_zero(b)) || (p == 38 && m_all_ones(b)) { out.push(x); }
                }
            }
            if has_rhsc && m_intrinsic(aa, IID_ctpop) { dc_add_affected(op(aa, 0), out); }
        } else if is_inst_op(v, OP_FCMP) {
            var aa = op(v, 0);
            if is_constant(op(v, 1)) { dc_add_affected(aa, out); }
            if is_op(aa, OP_FNEG) { aa = op(aa, 0); dc_add_affected(aa, out); }
            if m_intrinsic(aa, IID_fabs) { aa = op(aa, 0); dc_add_affected(aa, out); }
        } else if m_intrinsic(v, IID_is_fpclass) {
            dc_add_affected(op(v, 0), out);
        } else if is_inst_op(v, OP_TRUNC) {
            dc_add_affected(op(v, 0), out);
        } else if m_not(v) >= 0 {
            wl.push(m_not(v));
        }
    }
}

// DomConditionCache::registerBranch(BI)
fn dc_register_branch(br: i32) {
    if !dc_active { return; }
    var aff: i32[>..<] = [];
    dc_affected_by_condition(op(br, 0), aff);
    for v in aff { dc_add(v, br); }
}

// ---------------------------------------------------------------------------------------------
// The DomConditionCache parts of ValueTracking (the "Handle dominating conditions" loops)

fn dc_edge_dominates_cxt(bi: i32, k: i64, cx: i32) -> bool { dom_edge(inst_parent(bi), term_succ(bi, k), inst_parent(cx)) }

// computeKnownBitsFromContext: dominating conditions
recursive fn kb_from_dom_conditions(v: i32, known0: KB, depth: i64) -> KB {
    var known = known0;
    if !dc_active || kb_cxt < 0 || sq_no_dt { return known; }
    let cx = kb_cxt;
    var e = dc_first(v);
    while e >= 0 {
        let bi = dc_branch(e);
        e = dc_next(e);
        if dc_edge_dominates_cxt(bi, 0, cx) { known = kb_from_cond(v, op(bi, 0), known, false, depth); kb_cxt = cx; }
        if dc_edge_dominates_cxt(bi, 1, cx) { known = kb_from_cond(v, op(bi, 0), known, true, depth); kb_cxt = cx; }
    }
    if kb_has_conflict(known) { known = kb_unknown(kb_bw(known)); }
    return known;
}

// isImpliedToBeAPowerOfTwoFromCond(V, OrZero, Cond, CondIsTrue)
fn implied_pow2_from_cond(v: i32, or_zero: bool, c: i32, cond_true: bool) -> bool {
    if !is_op(c, OP_ICMP) { return false; }
    let l = op(c, 0);
    let rc = m_apint(op(c, 1));
    if !m_intrinsic(l, IID_ctpop) || op(l, 0) != v || rc < 0 { return false; }
    var p = cmp_pred_of(c);
    if !cond_true { p = icmp_inverse_pred(p); }
    if or_zero && p == 36 && ap_eq_u64(ci_ap(rc), 2) { return true; }
    return p == 32 && ap_eq_u64(ci_ap(rc), 1);
}
fn icmp_inverse_pred(p: i64) -> i64 {
    match p { 32 => 33, 33 => 32, 34 => 37, 37 => 34, 35 => 36, 36 => 35, 38 => 41, 41 => 38, 39 => 40, 40 => 39, _ => p }
}
fn pow2_from_dom_conditions(v: i32, or_zero: bool) -> bool {
    if !dc_active || kb_cxt < 0 || sq_no_dt { return false; }
    let cx = kb_cxt;
    var e = dc_first(v);
    while e >= 0 {
        let bi = dc_branch(e);
        e = dc_next(e);
        let c = op(bi, 0);
        if implied_pow2_from_cond(v, or_zero, c, true) && dc_edge_dominates_cxt(bi, 0, cx) { return true; }
        if implied_pow2_from_cond(v, or_zero, c, false) && dc_edge_dominates_cxt(bi, 1, cx) { return true; }
    }
    return false;
}
// isKnownNonEqualFromContext: dominating conditions (for V1, then V2)
fn nonequal_from_dom_conditions_of(v: i32, v1: i32, v2: i32, depth: i64) -> bool {
    let cx = kb_cxt;
    var e = dc_first(v);
    while e >= 0 {
        let bi = dc_branch(e);
        e = dc_next(e);
        let c = op(bi, 0);
        if dc_edge_dominates_cxt(bi, 0, cx) && implied_condition(c, cp(33, false), v1, v2, true, depth) == 1 { kb_cxt = cx; return true; }
        kb_cxt = cx;
        if dc_edge_dominates_cxt(bi, 1, cx) && implied_condition(c, cp(33, false), v1, v2, false, depth) == 1 { kb_cxt = cx; return true; }
        kb_cxt = cx;
    }
    return false;
}
fn nonequal_from_dom_conditions(v1: i32, v2: i32, depth: i64) -> bool {
    if !dc_active || kb_cxt < 0 || sq_no_dt { return false; }
    if nonequal_from_dom_conditions_of(v1, v1, v2, depth) { return true; }
    return nonequal_from_dom_conditions_of(v2, v1, v2, depth);
}
// computeKnownFPClassFromContext: dominating conditions
recursive fn kfc_from_dom_conditions(v: i32, known0: KFC) -> KFC {
    var known = known0;
    if !dc_active || kb_cxt < 0 || sq_no_dt { return known; }
    let cx = kb_cxt;
    var e = dc_first(v);
    while e >= 0 {
        let bi = dc_branch(e);
        e = dc_next(e);
        if dc_edge_dominates_cxt(bi, 0, cx) { known = kfc_from_cond(v, op(bi, 0), true, known, 0); kb_cxt = cx; }
        if dc_edge_dominates_cxt(bi, 1, cx) { known = kfc_from_cond(v, op(bi, 0), false, known, 0); kb_cxt = cx; }
    }
    return known;
}
