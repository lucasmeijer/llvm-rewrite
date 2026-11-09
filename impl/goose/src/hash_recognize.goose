// HashRecognize: port of llvm/lib/Analysis/HashRecognize.cpp (recognizeCRC, getRecurrences, RecurrenceInfo,
// isSignificantBitCheckWellFormed, isConditionalOnXorOfPHIs, isBigEndianBitShift, containsUnreachable,
// genSarwateTable; the printer pass is not ported). The PolynomialInfo result is the hr_* globals.
import std;
import ir;
import irutil;
import instinfo;
import pm;
import vt;
import apint;
import constrange;
import loopinfo;
import scev;
import scev_create;
import scev_btc;
import scev_expander;
import constfold;

var hr_trip_count: i64 = 0;
var hr_lhs: i32 = -1;
var hr_rhs: AP;
var hr_computed: i32 = -1;
var hr_big_endian: bool = false;
var hr_lhs_aux: i32 = -1;
var hr_table: AP[>..<];

// RecurrenceInfo
struct HRec { phi: i32, bo: i32, start: i32, step: i32, has_extra: bool, extra: AP }
fn hr_rec_none() -> HRec { HRec { phi: -1, bo: -1, start: -1, step: -1, has_extra: false, extra: ap_zero(1) } }

fn hr_is(v: i32, o: i64) -> bool { is_inst(v) && iop(v) == o }

// m_ZExtOrTruncOrSelf(m_Specific(P))
fn hr_zext_trunc_self(v: i32, p: i32) -> bool {
    if v == p { return true; }
    return (hr_is(v, OP_ZEXT) || hr_is(v, OP_TRUNC)) && op(v, 0) == p;
}
// m_c_Xor(m_ZExtOrTruncOrSelf(m_Specific(A)), m_ZExtOrTruncOrSelf(m_Specific(B)))
fn hr_c_xor_of(v: i32, a: i32, b: i32) -> bool {
    if !hr_is(v, OP_XOR) { return false; }
    let x = op(v, 0);
    let y = op(v, 1);
    return (hr_zext_trunc_self(x, a) && hr_zext_trunc_self(y, b)) || (hr_zext_trunc_self(y, a) && hr_zext_trunc_self(x, b));
}

// containsUnreachable(L, Roots)
fn hr_contains_unreachable(l: i32, roots: const i32[:]) -> bool {
    let latch = loop_latch(l);
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    for r in roots { wl.push(r); }
    while wl.len > 0 {
        let i = wl.pop();
        var seen = false;
        for x in visited { if x == i { seen = true; break; } }
        if !seen { visited.push(i); }
        if iop(i) == OP_PHI { continue; }
        for k in nops(i) {
            let u = op(i, k);
            if u >= 0 && is_inst(u) {
                if !loop_contains(l, inst_parent(u)) { return true; }
                wl.push(u);
            }
        }
    }
    var n: i64 = 0;
    var i = block_first(latch);
    while i >= 0 { n++; i = inst_next(i); }
    return n != visited.len;
}

// RecurrenceInfo::digRecurrence
fn hr_dig_recurrence(r: HRec&, l: i32, v: i32, with_const_op: i64) -> i32 {
    var wl: i32[>..<] = [];
    wl.push(v);
    while wl.len > 0 {
        let i = wl.pop();
        if iop(i) == OP_PHI { continue; }
        if is_binary_op(iop(i)) && (op(i, 0) == r.phi || op(i, 1) == r.phi) { return i; }
        if iop(i) == with_const_op {
            if r.has_extra { return -1; }
            // m_c_BinOp(m_APInt(C), m_Value())
            if is_binary_op(iop(i)) {
                for k in 2 {
                    let c = op(i, k);
                    if hr_m_apint(c) { r.has_extra = true; r.extra = hr_apint(c); break; }
                }
            }
        }
        for k in nops(i) {
            let u = op(i, k);
            if u >= 0 && is_inst(u) && loop_contains(l, inst_parent(u)) { wl.push(u); }
        }
    }
    return -1;
}
// m_APInt: a ConstantInt or a splat vector of one
fn hr_m_apint(c: i32) -> bool { is_cint(c) || (is_constant(c) && ty_is_vector(vals[c].ty) && c_splat_value(c) >= 0 && is_cint(c_splat_value(c))) }
fn hr_apint(c: i32) -> AP { if is_cint(c) { ci_ap(c) } else { ci_ap(c_splat_value(c)) } }

// RecurrenceInfo::matchConditionalRecurrence(P, BOWithConstOpToMatch)
fn hr_match_conditional(r: HRec&, l: i32, p: i32, with_const_op: i64) -> bool {
    r.phi = p;
    if nops(p) != 2 { return false; }
    for idx in 2 {
        let fstep = op(p, idx);
        let fstart = op(p, 1 - idx);
        if !hr_is(fstep, OP_SELECT) { continue; }
        let c = op(fstep, 0);
        if !(hr_is(c, OP_ICMP) || hr_is(c, OP_FCMP)) { continue; }
        let tv = op(fstep, 1);
        let fv = op(fstep, 2);
        if !is_inst(tv) || !is_inst(fv) { continue; }
        let fbo = hr_dig_recurrence(r, l, tv, with_const_op);
        let abo = hr_dig_recurrence(r, l, fv, with_const_op);
        if fbo < 0 || fbo != abo { return false; }
        if with_const_op >= 0 && !r.has_extra { return false; }
        r.bo = fbo;
        r.start = fstart;
        r.step = fstep;
        return true;
    }
    return false;
}

// isBigEndianBitShift: 1 = true, 0 = false, -1 = nullopt
fn hr_big_endian_bit_shift(v: i32) -> i64 {
    if !ty_is_int(vals[v].ty) { return -1; }
    let e = sc_get_scev(v);
    if sc_kind(e) == SC_UDIV && sc_is_const(sc_op(e, 1)) && ap_eq_u64(sc_ap(sc_op(e, 1)), 2) { return 0; }
    if sc_kind(e) == SC_MUL && sc_nops(e) == 2 && sc_is_const(sc_op(e, 0)) && ap_eq_u64(sc_ap(sc_op(e, 0)), 2) { return 1; }
    return -1;
}

// isSignificantBitCheckWellFormed
fn hr_bit_check_well_formed(cr: HRec, sr: HRec, big: bool) -> bool {
    let si = cr.step;
    let cmp = op(si, 0);
    if !hr_is(cmp, OP_ICMP) || !hr_m_apint(op(cmp, 1)) { return false; }
    let tv = op(si, 1);
    let fv = op(si, 2);
    if !is_inst(tv) || !is_inst(fv) { return false; }
    let pred = inst_pred(cmp);
    let lv = op(cmp, 0);
    let rv = hr_apint(op(cmp, 1));
    // MatchPred = m_CombineOr(m_Specific(CR.Phi), m_c_Xor(ZExtOrTruncOrSelf(CR.Phi), ZExtOrTruncOrSelf(SR.Phi)))
    var ok = false;
    if big { ok = lv == cr.phi || (sr.phi >= 0 && hr_c_xor_of(lv, cr.phi, sr.phi)) || (sr.phi < 0 && hr_c_xor_of_null(lv, cr.phi)); }
    else {
        if hr_is(lv, OP_AND) {
            for k in 2 {
                let a = op(lv, k);
                let b = op(lv, 1 - k);
                let mp = a == cr.phi || (sr.phi >= 0 && hr_c_xor_of(a, cr.phi, sr.phi)) || (sr.phi < 0 && hr_c_xor_of_null(a, cr.phi));
                if mp && m_one(b) { ok = true; break; }
            }
        }
    }
    if !ok { return false; }
    let bw = rv.w as i64;
    let rcr = rg_single(rv);
    let allowed = rg_allowed_icmp(pred, rcr);
    let check = rg_new(ap_zero(bw), if big { ap_smin_val(bw) } else { ap_u64(1, bw) });
    let bs = cr.bo;
    if rg_eq(allowed, check) { return tv == bs && hr_c_xor_specific_int(fv, bs, cr.extra); }
    if rg_eq(rg_inverse(allowed), check) { return fv == bs && hr_c_xor_specific_int(tv, bs, cr.extra); }
    return false;
}
// m_c_Xor with a null SimpleRecurrence.Phi: m_Specific(nullptr) never matches
fn hr_c_xor_of_null(v: i32, a: i32) -> bool { false }
// m_c_Xor(m_Specific(BS), m_SpecificInt(C))
fn hr_c_xor_specific_int(v: i32, bs: i32, c: AP) -> bool {
    if !hr_is(v, OP_XOR) { return false; }
    for k in 2 {
        let a = op(v, k);
        let b = op(v, 1 - k);
        if a == bs && hr_m_apint(b) && ap_eq(hr_apint(b), c) { return true; }
    }
    return false;
}

// isConditionalOnXorOfPHIs(SI, P1, P2, L)
fn hr_conditional_on_xor_of_phis(si: i32, p1: i32, p2: i32, l: i32) -> bool {
    var wl: i32[>..<] = [];
    wl.push(op(si, 0));
    while wl.len > 0 {
        let i = wl.pop();
        if iop(i) == OP_PHI { continue; }
        if hr_c_xor_of(i, p1, p2) { return true; }
        for k in nops(i) {
            let u = op(i, k);
            if u >= 0 && is_inst(u) && loop_contains(l, inst_parent(u)) { wl.push(u); }
        }
    }
    return false;
}

// Value::getUniqueUndroppableUser
fn hr_unique_undroppable_user(v: i32) -> i32 {
    var r: i32 = -1;
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        var droppable = false;
        if is_inst(us) && iop(us) == OP_CALL {
            let id = call_iid(us);
            droppable = id == IID_assume || id == IID_pseudoprobe || id == IID_experimental_noalias_scope_decl;
        }
        if !droppable {
            if r >= 0 && r != us { return -1; }
            r = us;
        }
        u = uses[u].next;
    }
    return r;
}
fn hr_has_n_uses(v: i32, n: i64) -> bool {
    var k: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { k++; u = uses[u].next; }
    return k == n;
}

// HashRecognize::recognizeCRC (true = a PolynomialInfo in hr_*)
fn hr_recognize_crc(l: i32) -> bool {
    if !loop_is_innermost(l) { return false; }
    let latch = loop_latch(l);
    let exit = hr_exit_block(l);
    let indvar = loop_canonical_induction_variable(l);
    if latch < 0 || exit < 0 || indvar < 0 || loop_nblocks(l) != 1 { return false; }
    let tc = sc_get_small_constant_trip_count(l);
    if tc == 0 || tc % 8 != 0 { return false; }
    // getRecurrences
    var nphis: i64 = 0;
    var p = block_first(latch);
    while p >= 0 && iop(p) == OP_PHI { nphis++; p = inst_next(p); }
    if nphis != 2 && nphis != 3 { return false; }
    var sr = hr_rec_none();
    var cr = hr_rec_none();
    p = block_first(latch);
    while p >= 0 && iop(p) == OP_PHI {
        if p != indvar {
            if sr.bo < 0 {
                if match_simple_recurrence(p) { sr.phi = p; sr.bo = rec_bo; sr.start = rec_start; sr.step = rec_step; }
            }
            if cr.bo < 0 {
                hr_match_conditional(cr, l, p, OP_XOR);
            }
        }
        p = inst_next(p);
    }
    if nphis == 3 && (sr.bo < 0 || cr.bo < 0) { return false; }
    if cr.bo < 0 { return false; }
    let big = hr_big_endian_bit_shift(cr.bo);
    if big < 0 { return false; }
    if sr.bo >= 0 {
        if hr_big_endian_bit_shift(sr.bo) != big { return false; }
        if !hr_has_n_uses(cr.phi, 2) || !hr_has_n_uses(sr.phi, 2) || hr_unique_undroppable_user(sr.bo) != sr.phi { return false; }
        if !hr_conditional_on_xor_of_phis(cr.step, sr.phi, cr.phi, l) { return false; }
    }
    let lhs = cr.start;
    var aux = if sr.bo >= 0 { sr.start } else { -1 };
    if big == 1 && aux >= 0 && ty_bits(vals[aux].ty) < ty_bits(vals[lhs].ty) { aux = -1; }
    let lim = if aux >= 0 { ty_bits(vals[aux].ty) } else { ty_bits(vals[lhs].ty) };
    if tc > lim { return false; }
    let computed = cr.step;
    var used_in_exit = false;
    var u = vals[computed].first_use;
    while u >= 0 { let us = uses[u].user; if is_inst(us) && inst_parent(us) == exit { used_in_exit = true; } u = uses[u].next; }
    if !used_in_exit { return false; }
    if !hr_bit_check_well_formed(cr, if sr.bo >= 0 { sr } else { hr_rec_none() }, big == 1) { return false; }
    var roots: i32[>..<] = [];
    roots.push(computed);
    roots.push(phi_value(indvar, phi_block_index(indvar, latch)));
    roots.push(hr_latch_cmp(l));
    roots.push(block_terminator(latch));
    if sr.bo >= 0 { roots.push(sr.bo); }
    for r in roots { if r < 0 || !is_inst(r) { fatal("internal: HashRecognize: missing root"); } }
    if hr_contains_unreachable(l, roots) { return false; }
    hr_trip_count = tc;
    hr_lhs = lhs;
    hr_rhs = cr.extra;
    hr_computed = computed;
    hr_big_endian = big == 1;
    hr_lhs_aux = aux;
    return true;
}
fn hr_latch_cmp(l: i32) -> i32 {
    let latch = loop_latch(l);
    let t = block_terminator(latch);
    if iop(t) != OP_CONDBR { return -1; }
    let c = op(t, 0);
    if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) { return c; }
    return -1;
}
// Loop::getExitBlock
fn hr_exit_block(l: i32) -> i32 {
    var r: i32 = -1;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if loop_contains(l, s) { continue; }
            if r >= 0 { return -1; }
            r = s;
        }
    }
    return r;
}

// HashRecognize::genSarwateTable(GenPoly, IsBigEndian) into hr_table
fn hr_gen_sarwate_table(gp: AP, big: bool) {
    let bw = gp.w as i64;
    hr_table.clear();
    for k in 256 { hr_table.push(ap_zero(bw)); }
    if big {
        var crc = ap_smin_val(bw);
        var i: i64 = 1;
        while i < 256 {
            crc = ap_xor(ap_shl(crc, 1), if ap_is_neg(crc) { gp } else { ap_zero(bw) });
            for j in i { hr_table[i + j] = ap_xor(crc, hr_table[j]); }
            i = i << 1;
        }
        return;
    }
    var crc = ap_u64(1, bw);
    var i: i64 = 128;
    while i > 0 {
        crc = ap_xor(ap_lshr(crc, 1), if ap_get_bit(crc, 0) { gp } else { ap_zero(bw) });
        var j: i64 = 0;
        while j < 256 { hr_table[i + j] = ap_xor(crc, hr_table[j]); j += i << 1; }
        i = i >> 1;
    }
}
