// IVDescriptors: RecurrenceDescriptor and InductionDescriptor. Port of llvm/lib/Analysis/IVDescriptors.cpp
// (whole: isReductionPHI / AddReductionVar / getMinMaxRecurrence / the pattern helpers, isFixedOrderRecurrence,
// getReductionOpChain, isInductionPHI (both overloads) / isFPInductionPHI / getCastsForInductionPHI) and
// llvm/include/llvm/Analysis/IVDescriptors.h, plus PredicatedScalarEvolution::areAddRecsEqualWithPreds
// (llvm/lib/Analysis/ScalarEvolution.cpp).
//
// A descriptor is a fixed-size record in `rdx_descs` / `ind_descs` (reset with the loop vectorizer's state);
// its cast instructions / no-wrap predicates are runs in `ivd_pool`. Sets of instructions (SmallPtrSet) are
// HMaps; only membership is observable, except getMinMaxRecurrence's chain iteration (pointer order in LLVM),
// whose every early return gives the same empty descriptor, so insertion order is used.
import std;
import ir;
import irutil;
import instinfo;
import flags;
import gen_iids;
import datalayout;
import pm;
import apint;
import knownbits;
import vt;
import demandedbits;
import domtree;
import loopinfo;
import scev;
import scev_create;
import scev_eval;
import scev_lt;
import pse;

// RecurKind, in LLVM's enum order
let RK_NONE: i32 = 0; let RK_ADD: i32 = 1; let RK_SUB: i32 = 2; let RK_ADD_CHAIN_WITH_SUBS: i32 = 3; let RK_MUL: i32 = 4; let RK_OR: i32 = 5;
let RK_AND: i32 = 6; let RK_XOR: i32 = 7; let RK_SMIN: i32 = 8; let RK_SMAX: i32 = 9; let RK_UMIN: i32 = 10; let RK_UMAX: i32 = 11;
let RK_FADD: i32 = 12; let RK_FADD_CHAIN_WITH_SUBS: i32 = 13; let RK_FSUB: i32 = 14; let RK_FMUL: i32 = 15; let RK_FMIN: i32 = 16;
let RK_FMAX: i32 = 17; let RK_FMINNUM: i32 = 18; let RK_FMAXNUM: i32 = 19; let RK_FMINIMUM: i32 = 20; let RK_FMAXIMUM: i32 = 21;
let RK_FMINIMUMNUM: i32 = 22; let RK_FMAXIMUMNUM: i32 = 23; let RK_FMULADD: i32 = 24; let RK_ANYOF: i32 = 25; let RK_FINDIV: i32 = 26;
let RK_FINDLAST: i32 = 27;

// InductionKind
let IK_NONE: i32 = 0; let IK_INT: i32 = 1; let IK_PTR: i32 = 2; let IK_FP: i32 = 3;

struct RdxDesc {
    start: i32, exit: i32, store: i32, kind: i32, fmf: u8, exact_fp: i32, rty: i32, signed: bool, ordered: bool,
    multi_use: bool, casts_at: i32, casts_n: i32, min_width: i64
}
struct IndDesc { start: i32, kind: i32, step: i32, binop: i32, casts_at: i32, casts_n: i32, preds_at: i32, preds_n: i32 }

var rdx_descs: RdxDesc[>..<];
var ind_descs: IndDesc[>..<];
var ivd_pool: i32[>..<];

fn ivd_reset() { rdx_descs.clear(); ind_descs.clear(); ivd_pool.clear(); }
fn ivd_not_ported(what: const u8[:]) { fatal(str("loop-vectorize: ", what, " is not supported yet")); }

fn rk_is_integer(k: i32) -> bool { (k >= RK_ADD && k <= RK_UMAX) || k == RK_ANYOF || k == RK_FINDIV || k == RK_FINDLAST }
fn rk_is_fp(k: i32) -> bool { k != RK_NONE && !rk_is_integer(k) }
fn rk_is_sub(k: i32) -> bool { k == RK_SUB || k == RK_FSUB }
fn rk_is_int_minmax(k: i32) -> bool { k == RK_UMIN || k == RK_UMAX || k == RK_SMIN || k == RK_SMAX }
fn rk_is_fp_minmax_num(k: i32) -> bool { k == RK_FMINNUM || k == RK_FMAXNUM }
fn rk_is_fp_minmax(k: i32) -> bool {
    k == RK_FMIN || k == RK_FMAX || k == RK_FMINIMUM || k == RK_FMAXIMUM || k == RK_FMINIMUMNUM || k == RK_FMAXIMUMNUM || rk_is_fp_minmax_num(k)
}
fn rk_is_minmax(k: i32) -> bool { rk_is_int_minmax(k) || rk_is_fp_minmax(k) }
fn rk_is_any_of(k: i32) -> bool { k == RK_ANYOF }
fn rk_is_find_iv(k: i32) -> bool { k == RK_FINDIV }
fn rk_is_find_last(k: i32) -> bool { k == RK_FINDLAST }
fn rk_is_find(k: i32) -> bool { k == RK_FINDLAST || k == RK_FINDIV }

// RecurrenceDescriptor::getOpcode
fn rk_opcode(k: i32) -> i64 {
    if k == RK_SUB { return OP_SUB; }
    if k == RK_ADD_CHAIN_WITH_SUBS || k == RK_ADD { return OP_ADD; }
    if k == RK_MUL { return OP_MUL; }
    if k == RK_OR { return OP_OR; }
    if k == RK_AND { return OP_AND; }
    if k == RK_XOR { return OP_XOR; }
    if k == RK_FMUL { return OP_FMUL; }
    if k == RK_FMULADD || k == RK_FADD_CHAIN_WITH_SUBS || k == RK_FADD { return OP_FADD; }
    if k == RK_FSUB { return OP_FSUB; }
    if rk_is_int_minmax(k) { return OP_ICMP; }
    if k == RK_FMAX || k == RK_FMIN || k == RK_FMAXIMUM || k == RK_FMINIMUM || k == RK_FMAXIMUMNUM || k == RK_FMINIMUMNUM { return OP_FCMP; }
    fatal("internal: Unknown recurrence operation");
    return 0;
}

fn ivd_fmf(i: i32) -> u8 { if is_inst(i) { insts[inst_of(i)].fmf } else { 0 } }
fn ivd_has_allow_reassoc(i: i32) -> bool { (ivd_fmf(i) & FMF_REASSOC) != 0 }
// Instruction::isFast
fn ivd_is_fast(i: i32) -> bool { is_fp_math_operator(i) && (ivd_fmf(i) & FMF_FAST) == FMF_FAST }
fn ivd_is_fmuladd(i: i32) -> bool { is_inst(i) && iop(i) == OP_CALL && call_iid(i) == IID_fmuladd }
fn ivd_has_one_use(v: i32) -> bool { let u = vals[v].first_use; u >= 0 && uses[u].next < 0 }
fn ivd_num_uses(v: i32) -> i64 { var c: i64 = 0; var u = vals[v].first_use; while u >= 0 { c++; u = uses[u].next; } return c; }
fn ivd_uses_at_least(v: i32, n: i64) -> bool {
    var c: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { c++; if c >= n { return true; } u = uses[u].next; }
    return false;
}
fn ivd_contains_inst(l: i32, i: i32) -> bool { is_inst(i) && loop_contains(l, inst_parent(i)) }
// Loop::isLoopInvariant
fn ivd_loop_invariant(l: i32, v: i32) -> bool { !is_inst(v) || !loop_contains(l, inst_parent(v)) }
fn ivd_incoming_for_block(phi: i32, bb: i32) -> i32 { let k = phi_block_index(phi, bb); if k < 0 { -1 } else { phi_value(phi, k) } }
fn ivd_is_binop(i: i32) -> bool { is_inst(i) && iop(i) >= OP_ADD && iop(i) <= OP_XOR }
fn ivd_is_commutative(i: i32) -> bool {
    let o = iop(i);
    if o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL { return true; }
    if o == OP_CALL {
        let id = call_iid(i);
        // IntrinsicInst::isCommutative
        return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum ||
               id == IID_minimumnum || id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin ||
               id == IID_sadd_sat || id == IID_uadd_sat || id == IID_sadd_with_overflow || id == IID_uadd_with_overflow ||
               id == IID_smul_with_overflow || id == IID_umul_with_overflow || id == IID_smul_fix ||
               id == IID_umul_fix || id == IID_smul_fix_sat || id == IID_umul_fix_sat || id == IID_fma ||
               id == IID_fmuladd;
    }
    return false;
}
fn ivd_set_has(s: HMap&, v: i32) -> bool { v >= 0 && hm_has(s, v as u64) }
fn ivd_set_add(s: HMap&, v: i32) -> bool { if hm_has(s, v as u64) { return false; } hm_put(s, v as u64, 1); return true; }

// RecurrenceDescriptor::areAllUsesIn (the operands, despite the name)
fn rdx_are_all_uses_in(i: i32, s: HMap&) -> bool {
    for k in nops(i) {
        let o = op(i, k);
        if !is_inst(o) || !ivd_set_has(s, o) { return false; }
    }
    return true;
}
fn rdx_has_multiple_uses_of(i: i32, s: HMap&, max_uses: i64) -> bool {
    var n: i64 = 0;
    for k in nops(i) {
        let o = op(i, k);
        if is_inst(o) && ivd_set_has(s, o) { n++; }
        if n > max_uses { return true; }
    }
    return false;
}

// lookThroughAnd: (start instruction, recurrence type)
fn rdx_look_through_and(phi: i32, rt: i32, visited: HMap&, casts: i32[>..<]&) -> i32, i32 {
    if !ivd_has_one_use(phi) { return phi, rt; }
    let j = uses[vals[phi].first_use].user;
    if is_inst(j) && iop(j) == OP_AND && is_inst(op(j, 0)) {
        let m = m_apint(op(j, 1));
        if m >= 0 {
            let a = ap_add(ci_ap(m), ap_u64(1, ty_bits(ty_scalar(vals[m].ty))));
            let bits = ap_exact_log2(a);
            if bits > 0 {
                ivd_set_add(visited, phi);
                var found = false;
                for c in casts { if c == j { found = true; } }
                if !found { casts.push(j); }
                return j, ty_int(bits);
            }
        }
    }
    return phi, rt;
}

// computeRecurrenceType: (type, signed)
fn rdx_compute_recurrence_type(exit: i32) -> i32, bool {
    var signed = false;
    let tbits = dl_size_bits(vals[exit].ty);
    // DB->getDemandedBits(Exit)
    let mask = db_demanded_bits_ap(exit);
    var maxbw: i64 = (mask.w as i64) - ap_countl_zero(mask);
    if maxbw == tbits {
        // ComputeNumSignBits(Exit, DL, AC, nullptr, DT)
        let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
        kb_cxt = -1; sq_no_dt = false; sq_no_ac = false;
        let nsb = num_sign_bits(exit, 0);
        maxbw = tbits - nsb;
        // computeKnownBits(Exit, DL)
        kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
        let kb = kb_compute_all(exit, 0);
        kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
        if !kb_is_nonneg(kb) { signed = true; maxbw++; }
    }
    var p: i64 = 1;
    while p < maxbw { p *= 2; }
    if maxbw == 0 { p = 0; }
    return ty_int(p), signed;
}
fn ap_clz64(x: u64) -> i64 { var n: i64 = 0; var b: i64 = 63; while b >= 0 && ((x >> (b as u64)) & 1) == 0 { n++; b--; } return n; }

// collectCastInstrs: the minimum width (MinWidthCastToRecurTy)
fn rdx_collect_cast_instrs(l: i32, exit: i32, rt: i32, casts: i32[>..<]&) -> i64 {
    var wl: i32[>..<] = [];
    var visited = hm_new();
    wl.push(exit);
    var minw: i64 = 0xFFFFFFFF;
    while wl.len > 0 {
        let v = wl.pop();
        ivd_set_add(visited, v);
        if is_cast_op(iop(v)) {
            let src = vals[op(v, 0)].ty;
            if src == rt {
                var found = false;
                for c in casts { if c == v { found = true; } }
                if !found { casts.push(v); }
                continue;
            }
            if vals[v].ty == rt {
                let w = ty_scalar_bits(src);
                if w < minw { minw = w; }
                continue;
            }
        }
        for k in nops(v) {
            let o = op(v, k);
            if is_inst(o) && ivd_contains_inst(l, o) && !ivd_set_has(visited, o) { wl.push(o); }
        }
    }
    return minw;
}

// checkOrderedReduction
fn rdx_check_ordered(kind: i32, exact_fp: i32, exit: i32, phi: i32) -> bool {
    if kind != RK_FADD && kind != RK_FMULADD { return false; }
    if kind == RK_FADD && iop(exit) != OP_FADD { return false; }
    if kind == RK_FMULADD && !ivd_is_fmuladd(exit) { return false; }
    if exit != exact_fp || ivd_uses_at_least(exit, 3) { return false; }
    let op0 = op(exit, 0);
    let op1 = op(exit, 1);
    if kind == RK_FADD && op0 != phi && op1 != phi { return false; }
    if kind == RK_FMULADD && op(exit, 2) != phi { return false; }
    return true;
}

// collectMinMaxFMF
fn rdx_collect_minmax_fmf(v: i32) -> u8 {
    var f = ivd_fmf(v);
    if iop(v) == OP_SELECT {
        let c = op(v, 0);
        if is_inst(c) && iop(c) == OP_FCMP { f = f | ivd_fmf(c); }
    }
    return f;
}

// hasRequiredFastMathFlags: (ok, fmf, possibly updated kind)
fn rdx_has_required_fmf(fpop: i32, rk: i32) -> bool, u8, i32 {
    let f = ivd_fmf(fpop);
    if is_fp_math_operator(fpop) && (f & FMF_NNAN) != 0 && (f & FMF_NSZ) != 0 { return true, rdx_collect_minmax_fmf(fpop), rk; }
    var k = rk;
    if rk == RK_FMINIMUM || rk == RK_FMAXIMUM || rk == RK_FMINIMUMNUM || rk == RK_FMAXIMUMNUM {
    } else if rk == RK_FMAX {
        if !m_intrinsic(fpop, IID_maxnum) { return false, 0, rk; }
        k = RK_FMAXNUM;
    } else if rk == RK_FMIN {
        if !m_intrinsic(fpop, IID_minnum) { return false, 0, rk; }
        k = RK_FMINNUM;
    } else {
        return false, 0, rk;
    }
    return true, rdx_collect_minmax_fmf(fpop), k;
}

// m_OrdOrUnordFMin / m_OrdOrUnordFMax on a select: (X, Y) or (-1, -1)
fn ivd_ord_or_unord_fminmax(si: i32, is_max: bool) -> i32, i32 {
    if !is_inst(si) || iop(si) != OP_SELECT { return -1, -1; }
    let c = op(si, 0);
    if !is_inst(c) || iop(c) != OP_FCMP { return -1, -1; }
    let t = op(si, 1);
    let f = op(si, 2);
    let l = op(c, 0);
    let r = op(c, 1);
    if (t != l || f != r) && (t != r || f != l) { return -1, -1; }
    let p = if l == t { inst_pred(c) } else { 15 - inst_pred(c) };
    let ok = if is_max { p == 2 || p == 3 || p == 10 || p == 11 } else { p == 4 || p == 5 || p == 12 || p == 13 };   // FCMP_OGT, OGE, UGT, UGE / OLT, OLE, ULT, ULE
    if !ok { return -1, -1; }
    return l, r;
}
fn ivd_intr2(v: i32, id: i32) -> i32, i32 {
    if is_inst(v) && iop(v) == OP_CALL && call_iid(v) == id && cb_nargs(v) == 2 { return cb_arg(v, 0), cb_arg(v, 1); }
    return -1, -1;
}

// getMinMaxRecurrence's GetMinMaxRK: (kind, A, B)
fn rdx_minmax_rk(v: i32) -> i32, i32, i32 {
    if v < 0 || !is_inst(v) { return RK_NONE, -1, -1; }
    // m_UMin / m_UMax / m_SMax / m_SMin match only the intrinsics in LLVM 23
    let a1, b1 = ivd_intr2(v, IID_umin); if a1 >= 0 { return RK_UMIN, a1, b1; }
    let a2, b2 = ivd_intr2(v, IID_umax); if a2 >= 0 { return RK_UMAX, a2, b2; }
    let a3, b3 = ivd_intr2(v, IID_smax); if a3 >= 0 { return RK_SMAX, a3, b3; }
    let a4, b4 = ivd_intr2(v, IID_smin); if a4 >= 0 { return RK_SMIN, a4, b4; }
    let a5, b5 = ivd_ord_or_unord_fminmax(v, false); if a5 >= 0 { return RK_FMIN, a5, b5; }
    let a6, b6 = ivd_intr2(v, IID_minnum); if a6 >= 0 { return RK_FMIN, a6, b6; }
    let a7, b7 = ivd_ord_or_unord_fminmax(v, true); if a7 >= 0 { return RK_FMAX, a7, b7; }
    let a8, b8 = ivd_intr2(v, IID_maxnum); if a8 >= 0 { return RK_FMAX, a8, b8; }
    let a9, b9 = ivd_intr2(v, IID_minimum); if a9 >= 0 { return RK_FMINIMUM, a9, b9; }
    let a10, b10 = ivd_intr2(v, IID_maximum); if a10 >= 0 { return RK_FMAXIMUM, a10, b10; }
    let a11, b11 = ivd_intr2(v, IID_minimumnum); if a11 >= 0 { return RK_FMINIMUMNUM, a11, b11; }
    let a12, b12 = ivd_intr2(v, IID_maximumnum); if a12 >= 0 { return RK_FMAXIMUMNUM, a12, b12; }
    return RK_NONE, -1, -1;
}

fn rdx_new(start: i32, exit: i32, store: i32, kind: i32, fmf: u8, exact_fp: i32, rty: i32, signed: bool, ordered: bool,
           multi_use: bool, casts: const i32[:], minw: i64) -> i32 {
    let at = ivd_pool.len as i32;
    for c in casts { ivd_pool.push(c); }
    rdx_descs.push(RdxDesc { start: start, exit: exit, store: store, kind: kind, fmf: fmf, exact_fp: exact_fp, rty: rty,
                             signed: signed, ordered: ordered, multi_use: multi_use, casts_at: at,
                             casts_n: casts.len as i32, min_width: minw });
    return (rdx_descs.len - 1) as i32;
}
fn rdx_cast(d: i32, k: i64) -> i32 { ivd_pool[(rdx_descs[d].casts_at as i64) + k] }

// getMinMaxRecurrence: a descriptor id or -1
fn rdx_get_minmax_recurrence(phi: i32, l: i32) -> i32 {
    let ty: i32 = vals[phi].ty as i32;
    let latch = loop_latch(l);
    if phi_nincoming(phi) != 2 || inst_parent(phi) != loop_header(l) || (!ty_is_int(ty) && !ty_is_fp(ty)) || latch < 0 { return -1; }
    var fmf: u8 = FMF_FAST;
    let be = ivd_incoming_for_block(phi, latch);
    var rk = RK_NONE;
    var wl: i32[>..<] = [];
    wl.push(be);
    var chain = hm_new();
    var chain_order: i32[>..<] = [];
    ivd_set_add(chain, phi);
    chain_order.push(phi);
    while wl.len > 0 {
        let cur = wl.pop();
        if !ivd_set_add(chain, cur) { continue; }
        chain_order.push(cur);
        if !is_inst(cur) || !ivd_contains_inst(l, cur) { return -1; }
        if iop(cur) == OP_PHI {
            for k in nops(cur) { wl.push(op(cur, k)); }
            continue;
        }
        let cur_rk, a, b = rdx_minmax_rk(cur);
        if cur_rk == RK_NONE || (rk != RK_NONE && cur_rk != rk) { return -1; }
        rk = cur_rk;
        if rk_is_fp_minmax(cur_rk) {
            let ok, cf, nrk = rdx_has_required_fmf(cur, rk);
            if !ok { return -1; }
            rk = nrk;
            fmf = fmf & cf;
        }
        if iop(cur) == OP_SELECT {
            if ivd_set_add(chain, op(cur, 0)) { chain_order.push(op(cur, 0)); }
        }
        if a == phi || b == phi { continue; }
        let ark, x1, y1 = rdx_minmax_rk(a);
        let brk, x2, y2 = rdx_minmax_rk(b);
        let am = is_inst(a) && ivd_contains_inst(l, a) && ark == rk;
        let bm = is_inst(b) && ivd_contains_inst(l, b) && brk == rk;
        if am == bm { return -1; }
        wl.push(if am { a } else { b });
    }
    // PhiHasInvalidUses
    var invalid = false;
    var u = vals[phi].first_use;
    while u >= 0 {
        let us = uses[u].user;
        let urk, x, y = rdx_minmax_rk(us);
        if !ivd_set_has(chain, us) && ivd_contains_inst(l, us) && urk == RK_NONE { invalid = true; }
        u = uses[u].next;
    }
    let ph = loop_preheader(l);
    if invalid {
        if !rk_is_int_minmax(rk) || !ivd_has_one_use(be) { return -1; }
        return rdx_new(ivd_incoming_for_block(phi, ph), -1, -1, rk, 0, -1, ty, false, false, true, [], 0xFFFFFFFF);
    }
    var stores: i32[>..<] = [];
    for v in chain_order {
        if !has_use_list(v) { continue; }
        var uu = vals[v].first_use;
        while uu >= 0 {
            let us = uses[uu].user;
            uu = uses[uu].next;
            if ivd_set_has(chain, us) { continue; }
            if !is_inst(us) || (!ivd_contains_inst(l, us) && v != be) { return -1; }
            if !ivd_contains_inst(l, us) { continue; }
            if iop(us) == OP_STORE { stores.push(us); continue; }
            let irk, x, y = rdx_minmax_rk(us);
            if irk != rk { return -1; }
            var iu = vals[us].first_use;
            while iu >= 0 {
                let w = uses[iu].user;
                if is_inst(w) && iop(w) == OP_STORE { stores.push(w); }
                else if !ivd_set_has(chain, w) { return -1; }
                iu = uses[iu].next;
            }
        }
    }
    var istore: i32 = -1;
    var sptr: i32 = -1;
    for si in stores {
        let p = sc_get_scev(op(si, 1));
        if !sc_is_loop_invariant(p, l) || (sptr >= 0 && sptr != p) { return -1; }
        sptr = p;
        if istore < 0 { istore = si; }
        else if inst_parent(istore) != inst_parent(si) { return -1; }
        else if comes_before(istore, si) { istore = si; }
    }
    return rdx_new(ivd_incoming_for_block(phi, ph), be, istore, rk, fmf, -1, ty, false, false, false, [], 0xFFFFFFFF);
}

// isFindLastLikePhi
fn rdx_is_find_last_like_phi(phi: i32, header_phi: i32, rinsts: HMap&) -> bool {
    var n: i64 = 0;
    for k in nops(phi) {
        let o = op(phi, k);
        if !(is_inst(o) && ivd_set_has(rinsts, o)) {
            n++;
            if n > 1 { return false; }
        } else if o != header_phi {
            return false;
        }
    }
    return n == 1;
}

// InstDesc as (is recurrence, kind, exact FP inst, pattern inst)
struct InstDesc { rec: bool, kind: i32, exact_fp: i32, pat: i32 }
fn idesc(rec: bool, i: i32) -> InstDesc { InstDesc { rec: rec, kind: RK_NONE, exact_fp: -1, pat: i } }
fn idesc_k(i: i32, k: i32) -> InstDesc { InstDesc { rec: true, kind: k, exact_fp: -1, pat: i } }

fn ivd_m_cmp(v: i32) -> bool { is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) }

// isAnyOfPattern
fn rdx_is_any_of_pattern(l: i32, orig_phi: i32, i0: i32, prev: InstDesc) -> InstDesc {
    var i = i0;
    if ivd_m_cmp(i) && ivd_has_one_use(i) {
        let s = uses[vals[i].first_use].user;
        if is_inst(s) && iop(s) == OP_SELECT { return InstDesc { rec: true, kind: prev.kind, exact_fp: -1, pat: s }; }
    }
    if !(is_inst(i) && iop(i) == OP_SELECT && ivd_m_cmp(op(i, 0))) { return idesc(false, i); }
    var non_phi: i32 = -1;
    if op(i, 1) == orig_phi { non_phi = op(i, 2); }
    else if op(i, 2) == orig_phi { non_phi = op(i, 1); }
    else { return idesc(false, i); }
    if !ivd_loop_invariant(l, non_phi) { return idesc(false, i); }
    return idesc_k(i, RK_ANYOF);
}

// isFindPattern
fn rdx_is_find_pattern(l: i32, orig_phi: i32, i: i32) -> InstDesc {
    if !ivd_has_one_use(orig_phi) { return idesc(false, i); }
    if !(is_inst(i) && iop(i) == OP_SELECT && ivd_m_cmp(op(i, 0)) && (op(i, 2) == orig_phi || op(i, 1) == orig_phi)) {
        return idesc(false, i);
    }
    return idesc_k(i, RK_FINDLAST);
}

// isConditionalRdxPattern
fn rdx_is_conditional_rdx_pattern(i: i32) -> InstDesc {
    if !(is_inst(i) && iop(i) == OP_SELECT) { return idesc(false, i); }
    let c = op(i, 0);
    if !(ivd_m_cmp(c) && ivd_has_one_use(c)) { return idesc(false, i); }
    let tv = op(i, 1);
    let fv = op(i, 2);
    let tp = is_inst(tv) && iop(tv) == OP_PHI;
    let fp = is_inst(fv) && iop(fv) == OP_PHI;
    if (tp && fp) || (!tp && !fp) { return idesc(false, i); }
    let i1 = if tp { fv } else { tv };
    if !is_inst(i1) || !ivd_is_binop(i1) { return idesc(false, i); }
    let o = iop(i1);
    let ok = ((o == OP_FADD || o == OP_FSUB) && ivd_is_fast(i1)) || (o == OP_FMUL && ivd_is_fast(i1)) ||
             o == OP_ADD || o == OP_SUB || o == OP_MUL;
    if !ok { return idesc(false, i); }
    let op1 = op(i1, 0);
    let op2 = op(i1, 1);
    let iphi = if is_inst(op1) && iop(op1) == OP_PHI { op1 } else { (if is_inst(op2) { op2 } else { -1 }) };
    if iphi < 0 || iphi != fv { return idesc(false, i); }
    return idesc(true, i);
}

// isRecurrenceInstr
fn rdx_is_recurrence_instr(l: i32, orig_phi: i32, i: i32, kind: i32, prev: InstDesc) -> InstDesc {
    let o = iop(i);
    if o == OP_PHI { return InstDesc { rec: true, kind: prev.kind, exact_fp: prev.exact_fp, pat: i }; }
    if o == OP_SUB { return idesc(kind == RK_SUB || kind == RK_ADD_CHAIN_WITH_SUBS, i); }
    if o == OP_ADD { return idesc(kind == RK_ADD || kind == RK_ADD_CHAIN_WITH_SUBS, i); }
    if o == OP_MUL { return idesc(kind == RK_MUL, i); }
    if o == OP_AND { return idesc(kind == RK_AND, i); }
    if o == OP_OR { return idesc(kind == RK_OR, i); }
    if o == OP_XOR { return idesc(kind == RK_XOR, i); }
    if o == OP_FDIV || o == OP_FMUL {
        return InstDesc { rec: kind == RK_FMUL, kind: RK_NONE, exact_fp: if ivd_has_allow_reassoc(i) { -1 } else { i }, pat: i };
    }
    if o == OP_FSUB {
        return InstDesc { rec: kind == RK_FSUB || kind == RK_FADD_CHAIN_WITH_SUBS, kind: RK_NONE, exact_fp: if ivd_has_allow_reassoc(i) { -1 } else { i }, pat: i };
    }
    if o == OP_FADD {
        return InstDesc { rec: kind == RK_FADD || kind == RK_FADD_CHAIN_WITH_SUBS, kind: RK_NONE, exact_fp: if ivd_has_allow_reassoc(i) { -1 } else { i }, pat: i };
    }
    if o == OP_SELECT {
        if rk_is_sub(kind) || kind == RK_FADD || kind == RK_FMUL || kind == RK_ADD || kind == RK_MUL ||
           kind == RK_ADD_CHAIN_WITH_SUBS || kind == RK_FADD_CHAIN_WITH_SUBS {
            return rdx_is_conditional_rdx_pattern(i);
        }
        if rk_is_find(kind) { return rdx_is_find_pattern(l, orig_phi, i); }
    }
    if o == OP_SELECT || o == OP_FCMP || o == OP_ICMP || o == OP_CALL {
        if rk_is_any_of(kind) { return rdx_is_any_of_pattern(l, orig_phi, i, prev); }
        if ivd_is_fmuladd(i) {
            return InstDesc { rec: kind == RK_FMULADD, kind: RK_NONE, exact_fp: if ivd_has_allow_reassoc(i) { -1 } else { i }, pat: i };
        }
        return idesc(false, i);
    }
    return idesc(false, i);
}

// AddReductionVar: a descriptor id or -1
fn rdx_add_reduction_var(phi: i32, kind0: i32, l: i32) -> i32 {
    var kind = kind0;
    if phi_nincoming(phi) != 2 { return -1; }
    if inst_parent(phi) != loop_header(l) { return -1; }
    let ph = loop_preheader(l);
    if ph < 0 { return -1; }
    let rdx_start = ivd_incoming_for_block(phi, ph);
    var exit_inst: i32 = -1;
    var istore: i32 = -1;
    var found_redux_op = false;
    var found_start_phi = false;
    var num_cmp_select: i64 = 0;
    var redux = idesc(false, -1);
    var found_find_last_like_phi = false;
    var rty: i32 = vals[phi].ty as i32;
    var casts: i32[>..<] = [];
    var start = phi;
    var signed = false;
    var visited = hm_new();
    var wl: i32[>..<] = [];
    let sty = ty_scalar(rty);
    if kind == RK_FINDLAST {
        if !ty_is_fp(sty) && !ty_is_int(sty) && ty_kind(sty) != TK_PTR { return -1; }
    } else if ty_is_fp(sty) {
        if !rk_is_fp(kind) { return -1; }
    } else if ty_is_int(sty) {
        if !rk_is_integer(kind) { return -1; }
        start, rty = rdx_look_through_and(phi, rty, visited, casts);
    } else {
        return -1;
    }
    wl.push(start);
    ivd_set_add(visited, start);
    var fmf: u8 = FMF_FAST;
    var exact_fp: i32 = -1;
    while wl.len > 0 {
        let cur = wl.pop();
        if iop(cur) == OP_STORE {
            let ps = sc_get_scev(op(cur, 1));
            if istore >= 0 {
                let other = sc_get_scev(op(istore, 1));
                if other != ps { return -1; }
            }
            if !sc_is_loop_invariant(ps, l) { return -1; }
            istore = cur;
            continue;
        }
        if vals[cur].first_use < 0 { return -1; }
        let is_phi_ = iop(cur) == OP_PHI;
        if cur != phi && is_phi_ && inst_parent(cur) == inst_parent(phi) { return -1; }
        if !ivd_is_commutative(cur) && !is_phi_ && iop(cur) != OP_SELECT && iop(cur) != OP_ICMP && iop(cur) != OP_FCMP {
            let o0 = op(cur, 0);
            if !(is_inst(o0) && ivd_set_has(visited, o0)) { return -1; }
        }
        if cur != start {
            redux = rdx_is_recurrence_instr(l, phi, cur, kind, redux);
            if exact_fp < 0 { exact_fp = redux.exact_fp; }
            if !redux.rec { return -1; }
            if is_fp_math_operator(redux.pat) && !is_phi_ { fmf = fmf & rdx_collect_minmax_fmf(redux.pat); }
            if redux.kind != RK_NONE { kind = redux.kind; }
        }
        let is_sel = iop(cur) == OP_SELECT;
        if is_sel && (kind == RK_FADD || kind == RK_FMUL) && rdx_has_multiple_uses_of(cur, visited, 2) { return -1; }
        if !is_phi_ && !is_sel && !rk_is_any_of(kind) && rdx_has_multiple_uses_of(cur, visited, 1) { return -1; }
        if is_phi_ && cur != phi {
            if !rdx_are_all_uses_in(cur, visited) {
                found_find_last_like_phi = kind == RK_FINDLAST && !found_find_last_like_phi && rdx_is_find_last_like_phi(cur, phi, visited);
                if !found_find_last_like_phi { return -1; }
            }
        }
        if rk_is_any_of(kind) && is_sel { num_cmp_select++; }
        if (!is_phi_ || found_find_last_like_phi) && cur != start { found_redux_op = true; }
        var non_phis: i32[>..<] = [];
        var phis: i32[>..<] = [];
        var u = vals[cur].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if ivd_is_fmuladd(ui) {
                if cur == op(ui, 0) || cur == op(ui, 1) { return -1; }
            }
            let parent = inst_parent(ui);
            if !loop_contains(l, parent) {
                if exit_inst == cur { continue; }
                if exit_inst >= 0 || cur == phi { return -1; }
                var in_ops = false;
                for k in nops(phi) { if op(phi, k) == cur { in_ops = true; } }
                if !in_ops { return -1; }
                exit_inst = cur;
                continue;
            }
            if ivd_set_add(visited, ui) {
                if iop(ui) == OP_PHI {
                    phis.push(ui);
                } else {
                    if iop(ui) == OP_STORE && op(ui, 1) == cur { return -1; }
                    non_phis.push(ui);
                }
            } else if iop(ui) != OP_PHI && !rdx_is_conditional_rdx_pattern(ui).rec &&
                      !rdx_is_any_of_pattern(l, phi, ui, idesc(false, -1)).rec {
                return -1;
            }
            if ui == phi { found_start_phi = true; }
        }
        for x in phis { wl.push(x); }
        for x in non_phis { wl.push(x); }
    }
    if rk_is_any_of(kind) && num_cmp_select != 1 { return -1; }
    if istore >= 0 {
        var in_ops = false;
        for k in nops(phi) { if op(phi, k) == op(istore, 0) { in_ops = true; } }
        if !in_ops { return -1; }
        if exit_inst >= 0 && op(istore, 0) != exit_inst { return -1; }
        if exit_inst < 0 { exit_inst = op(istore, 0); }
    }
    if !found_start_phi || !found_redux_op || exit_inst < 0 { return -1; }
    let ordered = rdx_check_ordered(kind, exact_fp, exit_inst, phi);
    if start != phi {
        let cty, sg = rdx_compute_recurrence_type(exit_inst);
        signed = sg;
        if cty != rty { return -1; }
    }
    let minw = rdx_collect_cast_instrs(l, exit_inst, rty, casts);
    return rdx_new(rdx_start, exit_inst, istore, kind, fmf, exact_fp, rty, signed, ordered, false, casts, minw);
}

// isReductionPHI: a descriptor id or -1
fn rdx_is_reduction_phi(phi: i32, l: i32) -> i32 {
    let order: i32[7] = [RK_ADD, RK_SUB, RK_ADD_CHAIN_WITH_SUBS, RK_MUL, RK_OR, RK_AND, RK_XOR];
    for k in order { let d = rdx_add_reduction_var(phi, k, l); if d >= 0 { return d; } }
    let mm = rdx_get_minmax_recurrence(phi, l);
    if mm >= 0 { return mm; }
    let order2: i32[7] = [RK_ANYOF, RK_FINDLAST, RK_FMUL, RK_FSUB, RK_FADD, RK_FADD_CHAIN_WITH_SUBS, RK_FMULADD];
    for k in order2 { let d = rdx_add_reduction_var(phi, k, l); if d >= 0 { return d; } }
    return -1;
}

// isFixedOrderRecurrence
fn rdx_is_fixed_order_recurrence(phi: i32, l: i32) -> bool {
    if inst_parent(phi) != loop_header(l) || phi_nincoming(phi) != 2 { return false; }
    let ph = loop_preheader(l);
    let latch = loop_latch(l);
    if ph < 0 || latch < 0 { return false; }
    if phi_block_index(phi, ph) < 0 || phi_block_index(phi, latch) < 0 { return false; }
    var prev = ivd_incoming_for_block(phi, latch);
    if !is_inst(prev) { prev = -1; }
    var seen_phis = hm_new();
    while prev >= 0 && iop(prev) == OP_PHI {
        if inst_parent(prev) != inst_parent(phi) { return false; }
        if !ivd_set_add(seen_phis, prev) { return false; }
        prev = ivd_incoming_for_block(prev, latch);
        if !is_inst(prev) { prev = -1; }
    }
    if prev < 0 || !ivd_contains_inst(l, prev) || iop(prev) == OP_PHI { return false; }
    var seen = hm_new();
    let phibb = inst_parent(phi);
    var wl: i32[>..<] = [];
    wl.push(phi);
    while wl.len > 0 {
        let cur = wl.pop();
        var u = vals[cur].first_use;
        while u >= 0 {
            let sc = uses[u].user;
            u = uses[u].next;
            // TryToPushSinkCandidate
            if prev == sc { return false; }
            if !ivd_set_add(seen, sc) { continue; }
            if dt_value_dominates_inst(prev, sc) { continue; }
            if inst_parent(sc) != phibb || inst_may_have_side_effects(sc) || inst_may_read_memory(sc) || is_terminator(sc) { return false; }
            if iop(sc) == OP_PHI { continue; }
            wl.push(sc);
        }
    }
    return true;
}

// isMinOrMax(matchSelectPattern(Cur).Flavor) for getReductionOpChain
fn rdx_select_is_minmax(i: i32) -> bool {
    // SelectPatternResult::isMinOrMax(matchSelectPattern(Cur, LHS, RHS).Flavor)
    return spf_is_minmax(match_select_pattern_v(i, 0));
}

// getReductionOpChain: the chain into `out` (empty = none)
fn rdx_reduction_op_chain(d: i32, phi: i32, l: i32, out: i32[>..<]&) {
    out.clear();
    let kind = rdx_descs[d].kind;
    let is_minmax = rk_is_minmax(kind);
    let expected: i64 = if is_minmax { 2 } else { 1 };
    fn next_inst(cur: i32) -> i32 {
        var u = vals[cur].first_use;
        while u >= 0 {
            let ui = uses[u].user;
            u = uses[u].next;
            if iop(ui) == OP_PHI { continue; }
            if is_minmax {
                if iop(ui) == OP_SELECT { return ui; }
                continue;
            }
            return ui;
        }
        return -1;
    }
    fn correct_opcode(cur: i32) -> bool {
        if is_minmax { return rdx_select_is_minmax(cur); }
        if ivd_is_fmuladd(cur) { return true; }
        if iop(cur) == OP_SUB && kind == RK_ADD_CHAIN_WITH_SUBS { return true; }
        if iop(cur) == OP_FSUB && kind == RK_FADD_CHAIN_WITH_SUBS { return true; }
        return iop(cur) == rk_opcode(kind);
    }
    let lexit = rdx_descs[d].exit;
    var extra: i64 = 0;
    var rdx_instr = lexit;
    if iop(lexit) == OP_PHI {
        if phi_nincoming(lexit) != 2 { return; }
        let i0 = phi_value(lexit, 0);
        let i1 = phi_value(lexit, 1);
        var chain: i32 = -1;
        if i0 == phi { chain = if is_inst(i1) { i1 } else { -1 }; }
        else if i1 == phi { chain = if is_inst(i0) { i0 } else { -1 }; }
        else { return; }
        rdx_instr = chain;
        extra = 1;
    }
    if rdx_instr < 0 || !correct_opcode(rdx_instr) || ivd_num_uses(lexit) != 2 { return; }
    if ivd_num_uses(phi) != expected + extra { return; }
    var cur = next_inst(phi);
    while cur != rdx_instr {
        if cur < 0 || !correct_opcode(cur) || ivd_num_uses(cur) != expected { out.clear(); return; }
        out.push(cur);
        cur = next_inst(cur);
    }
    out.push(cur);
}

// ---------------------------------------------------------------------------------------------
// InductionDescriptor

fn ind_new(start: i32, kind: i32, step: i32, binop: i32, casts: const i32[:], preds: const i32[:]) -> i32 {
    let ca = ivd_pool.len as i32;
    for c in casts { ivd_pool.push(c); }
    let pa = ivd_pool.len as i32;
    for p in preds { ivd_pool.push(p); }
    ind_descs.push(IndDesc { start: start, kind: kind, step: step, binop: binop, casts_at: ca, casts_n: casts.len as i32,
                             preds_at: pa, preds_n: preds.len as i32 });
    return (ind_descs.len - 1) as i32;
}
fn ind_cast(d: i32, k: i64) -> i32 { ivd_pool[(ind_descs[d].casts_at as i64) + k] }
fn ind_pred(d: i32, k: i64) -> i32 { ivd_pool[(ind_descs[d].preds_at as i64) + k] }
// getConstIntStepValue: the ConstantInt or -1
fn ind_const_step(d: i32) -> i32 { let s = ind_descs[d].step; if sc_is_const(s) { sc_value(s) } else { -1 } }
// getExactFPMathInst
fn ind_exact_fp(d: i32) -> i32 {
    let b = ind_descs[d].binop;
    if ind_descs[d].kind == IK_FP && b >= 0 && !ivd_has_allow_reassoc(b) { return b; }
    return -1;
}
// getInductionOpcode (-1 = BinaryOpsEnd)
fn ind_opcode(d: i32) -> i64 { let b = ind_descs[d].binop; if b >= 0 { iop(b) } else { -1 } }

// isFPInductionPHI
fn ind_is_fp_induction_phi(phi: i32, l: i32) -> i32 {
    if loop_header(l) != inst_parent(phi) { return -1; }
    if phi_nincoming(phi) != 2 { return -1; }
    var be: i32 = -1;
    var sv: i32 = -1;
    if loop_contains(l, phi_block(phi, 0)) { be = phi_value(phi, 0); sv = phi_value(phi, 1); }
    else { be = phi_value(phi, 1); sv = phi_value(phi, 0); }
    if !ivd_is_binop(be) { return -1; }
    var addend: i32 = -1;
    if iop(be) == OP_FADD {
        if op(be, 0) == phi { addend = op(be, 1); }
        else if op(be, 1) == phi { addend = op(be, 0); }
    } else if iop(be) == OP_FSUB {
        if op(be, 0) == phi { addend = op(be, 1); }
    }
    if addend < 0 { return -1; }
    if is_inst(addend) && ivd_contains_inst(l, addend) { return -1; }
    let step = sc_get_unknown(addend);
    return ind_new(sv, IK_FP, step, be, [], []);
}

// isInductionPHI(Phi, TheLoop, SE, D, Preds, Expr, CastsToIgnore)
fn ind_is_induction_phi_se(phi: i32, l: i32, preds: const i32[:], expr: i32, casts: const i32[:]) -> i32 {
    let ty = vals[phi].ty;
    if !sc_is_scevable(ty) { return -1; }
    let s = if expr >= 0 { expr } else { sc_get_scev(phi) };
    if !sc_is_addrec(s) || !sc_is_affine(s) || sc_loop(s) != l { return -1; }
    let step = sc_op(s, 1);
    let ph = loop_preheader(l);
    if ph < 0 { return -1; }
    let sv = ivd_incoming_for_block(phi, ph);
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    if ty_is_int(ty) {
        let b = ivd_incoming_for_block(phi, latch);
        let bop = if ivd_is_binop(b) { b } else { -1 };
        return ind_new(sv, IK_INT, step, bop, casts, preds);
    }
    return ind_new(sv, IK_PTR, step, -1, [], preds);
}

// isInductionPHI(Phi, TheLoop, PSE, D, Assume): a descriptor id or -1
fn ind_is_induction_phi(phi: i32, l: i32, pse: i32, assume: bool) -> i32 {
    let ty = vals[phi].ty;
    let k = ty_kind(ty);
    if !ty_is_int(ty) && k != TK_PTR && k != TK_FLOAT && k != TK_DOUBLE && k != TK_HALF { return -1; }
    if ty_is_fp(ty) { return ind_is_fp_induction_phi(phi, l); }
    let phi_scev = pse_get_scev(pse, phi);
    var ar = if sc_is_addrec(phi_scev) { phi_scev } else { -1 };
    var preds: i32[>..<] = [];
    if assume && ar < 0 { ar = pse_get_as_add_rec(pse, phi, true, preds); }
    if ar < 0 { return -1; }
    if phi_scev != ar && sc_is_unknown(phi_scev) {
        ivd_not_ported("getCastsForInductionPHI (an induction found only under predicates)");
    }
    return ind_is_induction_phi_se(phi, l, preds, ar, []);
}
