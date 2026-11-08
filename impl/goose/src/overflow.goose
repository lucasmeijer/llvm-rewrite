// Overflow queries: computeOverflowFor{Unsigned,Signed}{Add,Sub,Mul}, computeConstantRangeIncludingKnownBits,
// haveNoCommonBitsSet / getNoCommonBitsSetResult (llvm/lib/Analysis/ValueTracking.cpp) and the
// ConstantRange::*MayOverflow helpers (llvm/lib/IR/ConstantRange.cpp).
// The SimplifyQuery context instruction is the global kb_cxt (set by the caller, see ovf_* wrappers).
import std;
import ir;
import irutil;
import pm;
import apint;
import knownbits;
import constrange;
import vt;
import poison;
import implied;

let OF_MAY = 0;
let OF_LOW = 1;      // AlwaysOverflowsLow
let OF_HIGH = 2;     // AlwaysOverflowsHigh
let OF_NEVER = 3;

fn rg_unsigned_add_may_overflow(a: CRange, b: CRange) -> i64 {
    if rg_is_empty(a) || rg_is_empty(b) { return OF_MAY; }
    let mn = rg_umin(a); let mx = rg_umax(a);
    let omn = rg_umin(b); let omx = rg_umax(b);
    if ap_ugt(mn, ap_not(omn)) { return OF_HIGH; }
    if ap_ugt(mx, ap_not(omx)) { return OF_MAY; }
    return OF_NEVER;
}
fn rg_signed_add_may_overflow(a: CRange, b: CRange) -> i64 {
    if rg_is_empty(a) || rg_is_empty(b) { return OF_MAY; }
    let w = rg_w(a);
    let mn = rg_smin(a); let mx = rg_smax(a);
    let omn = rg_smin(b); let omx = rg_smax(b);
    let smin = ap_smin_val(w); let smax = ap_smax_val(w);
    if ap_is_nonneg(mn) && ap_is_nonneg(omn) && ap_sgt(mn, ap_sub(smax, omn)) { return OF_HIGH; }
    if ap_is_neg(mx) && ap_is_neg(omx) && ap_slt(mx, ap_sub(smin, omx)) { return OF_LOW; }
    if ap_is_nonneg(mx) && ap_is_nonneg(omx) && ap_sgt(mx, ap_sub(smax, omx)) { return OF_MAY; }
    if ap_is_neg(mn) && ap_is_neg(omn) && ap_slt(mn, ap_sub(smin, omn)) { return OF_MAY; }
    return OF_NEVER;
}
fn rg_unsigned_sub_may_overflow(a: CRange, b: CRange) -> i64 {
    if rg_is_empty(a) || rg_is_empty(b) { return OF_MAY; }
    let mn = rg_umin(a); let mx = rg_umax(a);
    let omn = rg_umin(b); let omx = rg_umax(b);
    if ap_ult(mx, omn) { return OF_LOW; }
    if ap_ult(mn, omx) { return OF_MAY; }
    return OF_NEVER;
}
fn rg_signed_sub_may_overflow(a: CRange, b: CRange) -> i64 {
    if rg_is_empty(a) || rg_is_empty(b) { return OF_MAY; }
    let w = rg_w(a);
    let mn = rg_smin(a); let mx = rg_smax(a);
    let omn = rg_smin(b); let omx = rg_smax(b);
    let smin = ap_smin_val(w); let smax = ap_smax_val(w);
    if ap_is_nonneg(mn) && ap_is_neg(omx) && ap_sgt(mn, ap_add(smax, omx)) { return OF_HIGH; }
    if ap_is_neg(mx) && ap_is_nonneg(omn) && ap_slt(mx, ap_add(smin, omn)) { return OF_LOW; }
    if ap_is_nonneg(mx) && ap_is_neg(omn) && ap_sgt(mx, ap_add(smax, omn)) { return OF_MAY; }
    if ap_is_neg(mn) && ap_is_nonneg(omx) && ap_slt(mn, ap_add(smin, omx)) { return OF_MAY; }
    return OF_NEVER;
}
fn rg_unsigned_mul_may_overflow(a: CRange, b: CRange) -> i64 {
    if rg_is_empty(a) || rg_is_empty(b) { return OF_MAY; }
    let r1, ov1 = ap_umul_ov(rg_umin(a), rg_umin(b));
    if ov1 { return OF_HIGH; }
    let r2, ov2 = ap_umul_ov(rg_umax(a), rg_umax(b));
    if ov2 { return OF_MAY; }
    return OF_NEVER;
}

// computeConstantRangeIncludingKnownBits(V, ForSigned, SQ)
fn cr_including_known_bits(v: i32, for_signed: bool) -> CRange {
    let k = kb_compute_all(v, 0);
    let cr1 = rg_from_kb(k, for_signed);
    let cr2 = compute_constant_range(v, for_signed, true, 0);
    return rg_intersect_t(cr1, cr2, if for_signed { RG_SIGNED } else { RG_UNSIGNED });
}

fn ovf_unsigned_mul(l: i32, r: i32, cx: i32, nsw: bool) -> i64 {
    kb_cxt = cx;
    let lr = cr_including_known_bits(l, false);
    kb_cxt = cx;
    let rr = cr_including_known_bits(r, false);
    if nsw && rg_is_all_nonneg(lr) && rg_is_all_nonneg(rr) { return OF_NEVER; }
    return rg_unsigned_mul_may_overflow(lr, rr);
}
fn ovf_signed_mul(l: i32, r: i32, cx: i32) -> i64 {
    let w = ty_scalar_bits(vals[l].ty);
    kb_cxt = cx;
    let s1 = ncsb_q(l, 0);
    kb_cxt = cx;
    let s2 = ncsb_q(r, 0);
    let sb = s1 + s2;
    if sb > w + 1 { return OF_NEVER; }
    if sb == w + 1 {
        kb_cxt = cx;
        let lk = kb_compute_all(l, 0);
        kb_cxt = cx;
        let rk = kb_compute_all(r, 0);
        if kb_is_nonneg(lk) || kb_is_nonneg(rk) { return OF_NEVER; }
    }
    return OF_MAY;
}
fn ovf_unsigned_add(l: i32, r: i32, cx: i32) -> i64 {
    kb_cxt = cx;
    let lr = cr_including_known_bits(l, false);
    kb_cxt = cx;
    let rr = cr_including_known_bits(r, false);
    return rg_unsigned_add_may_overflow(lr, rr);
}
// computeOverflowForSignedAdd(LHS, RHS, Add, SQ); add = -1 for the overload without the AddOperator
fn ovf_signed_add_op(l: i32, r: i32, add: i32, cx: i32) -> i64 {
    if add >= 0 && op_nsw(add) { return OF_NEVER; }
    kb_cxt = cx;
    let s1 = ncsb_q(l, 0);
    if s1 > 1 {
        kb_cxt = cx;
        if ncsb_q(r, 0) > 1 { return OF_NEVER; }
    }
    kb_cxt = cx;
    let lr = cr_including_known_bits(l, true);
    kb_cxt = cx;
    let rr = cr_including_known_bits(r, true);
    let o = rg_signed_add_may_overflow(lr, rr);
    if o != OF_MAY { return o; }
    if add < 0 { return OF_MAY; }
    let nn = rg_is_all_nonneg(lr) || rg_is_all_nonneg(rr);
    let ng = rg_is_all_negative(lr) || rg_is_all_negative(rr);
    if nn || ng {
        kb_cxt = cx;
        let ak = kb_from_context(add, kb_unknown(rg_w(lr)), 0);
        if (kb_is_nonneg(ak) && nn) || (kb_is_neg(ak) && ng) { return OF_NEVER; }
    }
    return OF_MAY;
}
fn ovf_signed_add(l: i32, r: i32, cx: i32) -> i64 { ovf_signed_add_op(l, r, -1, cx) }
fn ovf_unsigned_sub(l: i32, r: i32, cx: i32) -> i64 {
    if (is_inst_op(r, OP_UREM) && op(r, 0) == l) || (is_inst_op(r, OP_SUB) && op_nuw(r) && op(r, 0) == l) {
        if is_guaranteed_not_to_be_undef(l, cx, 0) { return OF_NEVER; }
    }
    let c = implied_by_dom_condition(35, l, r, cx);
    if c == 1 { return OF_NEVER; }
    if c == 0 { return OF_LOW; }
    kb_cxt = cx;
    let lr = cr_including_known_bits(l, false);
    kb_cxt = cx;
    let rr = cr_including_known_bits(r, false);
    return rg_unsigned_sub_may_overflow(lr, rr);
}
fn ovf_signed_sub(l: i32, r: i32, cx: i32) -> i64 {
    if (is_inst_op(r, OP_SREM) && op(r, 0) == l) || (is_inst_op(r, OP_SUB) && op_nsw(r) && op(r, 0) == l) {
        if is_guaranteed_not_to_be_undef(l, cx, 0) { return OF_NEVER; }
    }
    kb_cxt = cx;
    let s1 = ncsb_q(l, 0);
    if s1 > 1 {
        kb_cxt = cx;
        if ncsb_q(r, 0) > 1 { return OF_NEVER; }
    }
    kb_cxt = cx;
    let lr = cr_including_known_bits(l, true);
    kb_cxt = cx;
    let rr = cr_including_known_bits(r, true);
    return rg_signed_sub_may_overflow(lr, rr);
}

// InstCombiner::willNotOverflow*
fn will_not_overflow_signed_add(l: i32, r: i32, cx: i32) -> bool { ovf_signed_add(l, r, cx) == OF_NEVER }
fn will_not_overflow_unsigned_add(l: i32, r: i32, cx: i32) -> bool { ovf_unsigned_add(l, r, cx) == OF_NEVER }
fn will_not_overflow_signed_sub(l: i32, r: i32, cx: i32) -> bool { ovf_signed_sub(l, r, cx) == OF_NEVER }
fn will_not_overflow_unsigned_sub(l: i32, r: i32, cx: i32) -> bool { ovf_unsigned_sub(l, r, cx) == OF_NEVER }
fn will_not_overflow_signed_mul(l: i32, r: i32, cx: i32) -> bool { ovf_signed_mul(l, r, cx) == OF_NEVER }
fn will_not_overflow_unsigned_mul(l: i32, r: i32, cx: i32, nsw: bool) -> bool { ovf_unsigned_mul(l, r, cx, nsw) == OF_NEVER }
fn will_not_overflow_add(l: i32, r: i32, cx: i32, signed: bool) -> bool {
    if signed { will_not_overflow_signed_add(l, r, cx) } else { will_not_overflow_unsigned_add(l, r, cx) }
}
fn will_not_overflow_sub(l: i32, r: i32, cx: i32, signed: bool) -> bool {
    if signed { will_not_overflow_signed_sub(l, r, cx) } else { will_not_overflow_unsigned_sub(l, r, cx) }
}
fn will_not_overflow_mul(l: i32, r: i32, cx: i32, signed: bool) -> bool {
    if signed { will_not_overflow_signed_mul(l, r, cx) } else { will_not_overflow_unsigned_mul(l, r, cx, false) }
}
fn will_not_overflow(o: i64, l: i32, r: i32, cx: i32, signed: bool) -> bool {
    if o == OP_ADD { return will_not_overflow_add(l, r, cx, signed); }
    if o == OP_SUB { return will_not_overflow_sub(l, r, cx, signed); }
    if o == OP_MUL { return will_not_overflow_mul(l, r, cx, signed); }
    fatal("internal: unexpected opcode in willNotOverflow");
    return false;
}

// ---------------------------------------------------------------------------------------------
// haveNoCommonBitsSet

let NCB_UNKNOWN = 0;
let NCB_ONLY_IF_UNDEF_IGNORED = 1;
let NCB_KNOWN = 2;

fn ncb_undef_result(nu: bool) -> i64 { if nu { NCB_KNOWN } else { NCB_ONLY_IF_UNDEF_IGNORED } }

// m_c_And(m_Not(m_Value(M)), m_Value()): returns M or -1
fn ncb_and_not(v: i32) -> i32 {
    if !is_inst_op(v, OP_AND) { return -1; }
    let a = m_not(op(v, 0));
    if a >= 0 { return a; }
    return m_not(op(v, 1));
}
fn ncb_and_with(v: i32, x: i32) -> bool { is_inst_op(v, OP_AND) && (op(v, 0) == x || op(v, 1) == x) }

fn ncb_special_cases(l: i32, r: i32, cx: i32) -> i64 {
    // (X & ~M) op (Y & M)
    let m = ncb_and_not(l);
    if m >= 0 && ncb_and_with(r, m) { return ncb_undef_result(is_guaranteed_not_to_be_undef(m, cx, 0)); }
    // X op (Y & ~X)
    if is_inst_op(r, OP_AND) && (m_not_of(op(r, 0), l) || m_not_of(op(r, 1), l)) {
        return ncb_undef_result(is_guaranteed_not_to_be_undef(l, cx, 0));
    }
    // X op ((X & Y) ^ Y)
    if is_inst_op(r, OP_XOR) {
        for k in 2 {
            let a = op(r, k);
            let y = op(r, 1 - k);
            if is_inst_op(a, OP_AND) && ((op(a, 0) == l && op(a, 1) == y) || (op(a, 1) == l && op(a, 0) == y)) {
                let nu = is_guaranteed_not_to_be_undef(l, cx, 0) && is_guaranteed_not_to_be_undef(y, cx, 0);
                return ncb_undef_result(nu);
            }
        }
    }
    // (ext Y) op ext(~Y)
    if is_inst_op(l, OP_ZEXT) || is_inst_op(l, OP_SEXT) {
        let y = op(l, 0);
        if (is_inst_op(r, OP_ZEXT) || is_inst_op(r, OP_SEXT)) && m_not_of(op(r, 0), y) {
            return ncb_undef_result(is_guaranteed_not_to_be_undef(y, cx, 0));
        }
    }
    // (A & B) op ~(A | B)
    if is_inst_op(l, OP_AND) {
        let a = op(l, 0);
        let b = op(l, 1);
        let n = m_not(r);
        if n >= 0 && is_inst_op(n, OP_OR) && ((op(n, 0) == a && op(n, 1) == b) || (op(n, 0) == b && op(n, 1) == a)) {
            let nu = is_guaranteed_not_to_be_undef(a, cx, 0) && is_guaranteed_not_to_be_undef(b, cx, 0);
            return ncb_undef_result(nu);
        }
    }
    // (X << V) op (Y >> (BitWidth - V)) or (X >> V) op (Y << (BitWidth - V))
    for k in 2 {
        let ro = if k == 0 { OP_SHL } else { OP_LSHR };
        let lo = if k == 0 { OP_LSHR } else { OP_SHL };
        if is_inst_op(r, ro) && is_inst_op(op(r, 1), OP_SUB) {
            let s = op(r, 1);
            let rc = m_apint(op(s, 0));
            let v = op(s, 1);
            if rc >= 0 && is_inst_op(l, lo) && op(l, 1) == v && ap_uge_u64(ci_ap(rc), ty_scalar_bits(vals[l].ty) as u64) {
                return NCB_KNOWN;
            }
        }
    }
    return NCB_UNKNOWN;
}

// getNoCommonBitsSetResult(LHS, RHS, SQ)
fn no_common_bits_set_result(l: i32, r: i32, cx: i32) -> i64 {
    let res = ncb_special_cases(l, r, cx);
    if res == NCB_KNOWN { return NCB_KNOWN; }
    let cres = ncb_special_cases(r, l, cx);
    if cres == NCB_KNOWN { return NCB_KNOWN; }
    kb_cxt = cx;
    let lk = kb_compute_all(l, 0);
    kb_cxt = cx;
    let rk = kb_compute_all(r, 0);
    // KnownBits::haveNoCommonBitsSet: (LHS.Zero | RHS.Zero).isAllOnes()
    if ap_is_all_ones(ap_or(lk.z, rk.z)) { return NCB_KNOWN; }
    if res == NCB_ONLY_IF_UNDEF_IGNORED || cres == NCB_ONLY_IF_UNDEF_IGNORED { return NCB_ONLY_IF_UNDEF_IGNORED; }
    return NCB_UNKNOWN;
}
fn have_no_common_bits_set(l: i32, r: i32, cx: i32) -> bool { no_common_bits_set_result(l, r, cx) == NCB_KNOWN }
