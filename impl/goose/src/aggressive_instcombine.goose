// AggressiveInstCombine: port of llvm/lib/Transforms/AggressiveInstCombine/AggressiveInstCombine.cpp
// (TruncInstCombine.cpp and the ConstantFolder IRBuilder are aic_trunc.goose), with the two TTI queries only this
// pass makes: BasicTTIImplBase::haveFastSqrt and X86TargetLowering::allowsMisalignedMemoryAccesses.
//
// PatternMatch: BinaryOp_match / CastInst_match / the intrinsic matchers match instructions only (LLVM 23);
// commutative matchers try (op0, op1) then (op1, op0), and a variable bound by a failed first attempt stays
// bound, as in LLVM, where the code below depends on it. The per-call DomTreeUpdater of foldLibCalls is a lazy
// dtu (dtu.goose) flushed when foldLibCalls returns.
import std;
import ir;
import irutil;
import analyses;
import instinfo;
import local;
import pm;
import vt;
import knownbits;
import poison;
import fpclass;
import implied;
import constfold;
import cfold;
import apint;
import datalayout;
import domtree;
import dtu;
import memloc;
import aa;
import cfgutil;
import loopsimplify;
import tli;
import tti;
import tti_x86;
import gen_x86target;
import instsimplify;
import salvage;
import simplify_libcalls;
import build_libcalls;
import gen_tli;
import gen_iids;
import intrinsics;
import calls;
import flags;
import aic_trunc;
import scev;
import stdsort;
import dinfo;
import mem2reg;
import simplifycfg;
import constraint_elimination;

fn ai_fail(msg: const u8[:]) { fatal(str("aggressive-instcombine: ", msg, " is not ported yet")); }
var ai_fv: i32 = -1;

// ---------------------------------------------------------------------------------------------
// Matchers

fn ai_bo(v: i32, o: i64) -> bool { is_inst_op(v, o) }
// Value::hasOneUse
fn ai_one_use(v: i32) -> bool { if is_constant_data(v) { return false; } let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
// hasNUsesOrMore(N)
fn ai_n_uses_or_more(v: i32, n: i64) -> bool {
    if is_constant_data(v) { return false; }
    var c: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { c++; if c >= n { return true; } u = uses[u].next; }
    return false;
}
// m_SpecificInt(uint64_t) / m_SpecificInt(APInt)
fn ai_si(v: i32, x: u64) -> bool { m_specific_int(v, x) }
fn ai_si_ap(v: i32, x: AP) -> bool { m_specific_int_apv(v, x) }
// m_Intrinsic<ID>(...) with N >= 1 arguments matched by the caller
fn ai_intr(v: i32, id: i32) -> bool { is_inst(v) && iop(v) == OP_CALL && inst_iid(v) == id }
fn ai_arg(v: i32, k: i64) -> i32 { cb_arg(v, k) }
// m_LShr(m_Value(X), m_SpecificInt(S)): X or -1
fn ai_lshr_by(v: i32, s: u64) -> i32 { if ai_bo(v, OP_LSHR) && ai_si(op(v, 1), s) { op(v, 0) } else { -1 } }
fn ai_lshr_by_ap(v: i32, s: AP) -> i32 { if ai_bo(v, OP_LSHR) && ai_si_ap(op(v, 1), s) { op(v, 0) } else { -1 } }
// m_And(m_Specific(X), m_SpecificInt(M))
fn ai_and_spec(v: i32, x: i32, m: AP) -> bool { ai_bo(v, OP_AND) && op(v, 0) == x && ai_si_ap(op(v, 1), m) }
// m_AddLike(L, R): add, or `or disjoint`
fn ai_add_like(v: i32) -> bool { ai_bo(v, OP_ADD) || (ai_bo(v, OP_OR) && (op_flags(v) & FL_DISJOINT) != 0) }
// m_Trunc / m_ZExt / m_SExt / m_FPToSI (CastInst_match)
fn ai_cast(v: i32, o: i64) -> i32 { if is_inst_op(v, o) { op(v, 0) } else { -1 } }
// m_SpecificICmp(Pred, L, R) (an icmp instruction with exactly that predicate)
fn ai_icmp_is(v: i32, p: i64) -> bool { is_inst_op(v, OP_ICMP) && inst_pred(v) == p }

// ---------------------------------------------------------------------------------------------
// TTI queries

// InstructionCost operator+ (an invalid cost stays invalid)
fn ai_cost_add(a: i64, b: i64) -> i64 { if a >= TTI_INVALID || b >= TTI_INVALID { TTI_INVALID } else { a + b } }

fn ai_x86_feature(name: const u8[:]) -> bool {
    for k in X86F_NAMES.len { if X86F_NAMES[k] == name { return x86_has(k as i32); } }
    fatal(str("aggressive-instcombine: unknown x86 feature ", name));
    return false;
}
// TargetIRAnalysis is created lazily: only a TTI query reaches the subtarget (and its unsupported CPUs)
var ai_tti_done: bool = false;
fn ai_tti() { if !ai_tti_done { tti_init_function(ai_fv, globs[glob_of(ai_fv)].module); ai_tti_done = true; } }
// TTI.haveFastSqrt(Ty) (BasicTTIImplBase: legal type and FSQRT legal or custom)
fn ai_have_fast_sqrt(ty: i32) -> bool {
    ai_tti();
    if tti_kind != TTI_X86 { return false; }
    if !tti_is_type_legal(ty) { return false; }
    let k = types[ty_scalar(ty)].kind as i64;
    if k == TK_FLOAT || k == TK_DOUBLE || k == TK_X86_FP80 { return true; }
    if k == TK_FP128 { return false; }   // FSQRT f128 is a LibCall
    ai_fail("haveFastSqrt of a half / bfloat type");
    return false;
}
// TTI.allowsMisalignedMemoryAccesses(Ctx, BitWidth, AS, Align, &Fast): (allowed, fast)
fn ai_allows_misaligned(bits: i64) -> bool, bool {
    ai_tti();
    if tti_kind != TTI_X86 { return false, false; }
    var fast = true;
    if bits == 128 { fast = !ai_x86_feature("slow-unaligned-mem-16"); }
    if bits == 256 { fast = !ai_x86_feature("slow-unaligned-mem-32"); }
    return true, fast;
}

// ---------------------------------------------------------------------------------------------
// Split cttz / ctlz selects

// foldSelectSplitCTTZ
fn ai_fold_select_split_cttz(i: i32, lo_trunc: i32, hi_res: i32, lo_res: i32, half_ty: i32) -> bool {
    let hw = ty_bits(half_ty);
    let fw = hw * 2;
    let src = ai_cast(lo_trunc, OP_TRUNC);
    if src < 0 { return false; }
    if !(ty_is_int(vals[src].ty) && ty_bits(vals[src].ty) == fw) { return false; }
    if !(ai_one_use(lo_res) && ai_intr(lo_res, IID_cttz) && ai_arg(lo_res, 0) == lo_trunc) { return false; }
    if !(ai_one_use(hi_res) && ai_add_like(hi_res) && ai_si(op(hi_res, 1), hw as u64)) { return false; }
    let cttz_hi = op(hi_res, 0);
    if !(ai_one_use(cttz_hi) && ai_intr(cttz_hi, IID_cttz)) { return false; }
    let harg = ai_arg(cttz_hi, 0);
    let ht = ai_cast(harg, OP_TRUNC);
    if ht < 0 || !(ai_bo(ht, OP_LSHR) && op(ht, 0) == src && ai_si(op(ht, 1), hw as u64)) { return false; }
    ab_set(i);
    let fls = c_false();
    let sty: i32 = vals[src].ty;
    let w = ab_intrinsic(IID_cttz, [sty], [src, fls], -1, "");
    let t = ab_trunc(w, half_ty);
    rauw(i, t);
    return true;
}

// foldSelectSplitCTLZ
fn ai_fold_select_split_ctlz(i: i32, hi_part0: i32, lo_res: i32, hi_res: i32, half_ty: i32) -> bool {
    let hw = ty_bits(half_ty);
    let fw = hw * 2;
    var hi_part = hi_part0;
    let t0 = ai_cast(hi_part, OP_TRUNC);
    if t0 >= 0 { hi_part = t0; }
    let src = ai_lshr_by(hi_part, hw as u64);
    if src < 0 { return false; }
    if !(ty_is_int(vals[src].ty) && ty_bits(vals[src].ty) == fw) { return false; }
    if !(ai_one_use(hi_res) && ai_intr(hi_res, IID_ctlz)) { return false; }
    let harg = ai_arg(hi_res, 0);
    let ht = ai_cast(harg, OP_TRUNC);
    if ht < 0 || !(ai_bo(ht, OP_LSHR) && op(ht, 0) == src && ai_si(op(ht, 1), hw as u64)) { return false; }
    if !(ai_one_use(lo_res) && ai_add_like(lo_res) && ai_si(op(lo_res, 1), hw as u64)) { return false; }
    let ctlz_lo = op(lo_res, 0);
    if !(ai_one_use(ctlz_lo) && ai_intr(ctlz_lo, IID_ctlz)) { return false; }
    if ai_cast(ai_arg(ctlz_lo, 0), OP_TRUNC) != src { return false; }
    ab_set(i);
    let fls = c_false();
    let sty: i32 = vals[src].ty;
    let w = ab_intrinsic(IID_ctlz, [sty], [src, fls], -1, "");
    let t = ab_trunc(w, half_ty);
    rauw(i, t);
    return true;
}

// foldSelectSplitCTLZCTTZ
fn ai_fold_select_split_ctlz_cttz(i: i32) -> bool {
    if !is_inst_op(i, OP_SELECT) { return false; }
    let cond = op(i, 0);
    var tv = op(i, 1);
    var fv = op(i, 2);
    let ty = vals[i].ty;
    if !ty_is_int(ty) { return false; }
    if ty_bits(ty) <= 2 { return false; }
    if !is_inst_op(cond, OP_ICMP) || !m_zero_int(op(cond, 1)) || !pred_is_equality(inst_pred(cond)) { return false; }
    let cmp_op = op(cond, 0);
    if inst_pred(cond) == P_NE { let t = tv; tv = fv; fv = t; }
    return ai_fold_select_split_cttz(i, cmp_op, tv, fv, ty) || ai_fold_select_split_ctlz(i, cmp_op, tv, fv, ty);
}

// ---------------------------------------------------------------------------------------------
// foldGuardedFunnelShift

// matchFunnelShift: (iid or 0, ShVal0, ShVal1, ShAmt); the out values are those LLVM's bindings hold
fn ai_match_funnel_shift(v: i32) -> i32, i32, i32, i32 {
    let w = ty_scalar_bits(vals[v].ty);
    var s0: i32 = -1;
    var s1: i32 = -1;
    var sa: i32 = -1;
    // fshl: m_OneUse(m_c_Or(m_Shl(m_Value(ShVal0), m_Value(ShAmt)), m_LShr(m_Value(ShVal1), m_Sub(W, m_Deferred(ShAmt)))))
    if ai_one_use(v) && ai_bo(v, OP_OR) {
        for k in 2 {
            let a = op(v, k);
            let b = op(v, 1 - k);
            if ai_bo(a, OP_SHL) {
                s0 = op(a, 0); sa = op(a, 1);
                if ai_bo(b, OP_LSHR) {
                    s1 = op(b, 0);
                    let sub = op(b, 1);
                    if ai_bo(sub, OP_SUB) && ai_si(op(sub, 0), w as u64) && op(sub, 1) == sa { return IID_fshl, s0, s1, sa; }
                }
            }
        }
    }
    // fshr: m_OneUse(m_c_Or(m_Shl(m_Value(ShVal0), m_Sub(W, m_Value(ShAmt))), m_LShr(m_Value(ShVal1), m_Deferred(ShAmt))))
    if ai_one_use(v) && ai_bo(v, OP_OR) {
        for k in 2 {
            let a = op(v, k);
            let b = op(v, 1 - k);
            if ai_bo(a, OP_SHL) {
                s0 = op(a, 0);
                let sub = op(a, 1);
                if ai_bo(sub, OP_SUB) && ai_si(op(sub, 0), w as u64) {
                    sa = op(sub, 1);
                    if ai_bo(b, OP_LSHR) {
                        s1 = op(b, 0);
                        if op(b, 1) == sa { return IID_fshr, s0, s1, sa; }
                    }
                }
            }
        }
    }
    return 0, s0, s1, sa;
}

fn ai_fold_guarded_funnel_shift(i: i32) -> bool {
    if iop(i) != OP_PHI || nops(i) != 2 { return false; }
    let bw = ty_scalar_bits(vals[i].ty);
    if bw <= 0 || (bw & (bw - 1)) != 0 { return false; }
    var funnel_op: i64 = 0;
    var guard_op: i64 = 1;
    let p0 = op(i, 0);
    let p1 = op(i, 1);
    var iid, s0, s1, sa = ai_match_funnel_shift(p0);
    if iid == 0 || (iid == IID_fshl && s0 != p1) || (iid == IID_fshr && s1 != p1) {
        let iid2, t0, t1, ta = ai_match_funnel_shift(p1);
        iid = iid2; s0 = t0; s1 = t1; sa = ta;
        if iid == 0 || (iid == IID_fshl && s0 != p0) || (iid == IID_fshr && s1 != p0) { return false; }
        funnel_op = 1; guard_op = 0;
    }
    let guard_bb = phi_block(i, guard_op);
    let funnel_bb = phi_block(i, funnel_op);
    let term = block_terminator(guard_bb);
    if !dt_value_dominates_inst(s0, term) || !dt_value_dominates_inst(s1, term) { return false; }
    let phi_bb = inst_parent(i);
    if iop(term) != OP_CONDBR { return false; }
    let c = op(term, 0);
    if !(ai_icmp_is(c, P_EQ) && op(c, 0) == sa && m_zero_int(op(c, 1))) { return false; }
    if term_succ(term, 0) != phi_bb || term_succ(term, 1) != funnel_bb { return false; }
    ab_set_at(phi_bb, ai_first_insertion_pt(phi_bb), true);
    let is_fshl = iid == IID_fshl;
    var v0 = s0;
    var v1 = s1;
    if s0 != s1 {
        if is_fshl && !ai_not_poison(s1) { v1 = ab_freeze(s1); }
        else if !is_fshl && !ai_not_poison(s0) { v0 = ab_freeze(s0); }
    }
    let r = ab_intrinsic(iid as i64, [vals[i].ty as i32], [v0, v1, sa], -1, "");
    rauw(i, r);
    return true;
}
fn ai_first_insertion_pt(bb: i32) -> i32 {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { i = inst_next(i); }
    if i >= 0 && inst_is_eh_pad(i) { i = inst_next(i); }
    return i;
}
// isGuaranteedNotToBePoison(V) (no AC, context, DT)
fn ai_not_poison(v: i32) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
    let r = is_guaranteed_not_to_be_poison(v, -1, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
    return r;
}

// ---------------------------------------------------------------------------------------------
// foldAnyOrAllBitsSet

var mo_root: i32 = -1;
var mo_mask: AP;
var mo_and_chain: bool = false;
var mo_found_and1: bool = false;

recursive fn ai_match_and_or_chain(v: i32) -> bool {
    if mo_and_chain {
        if ai_bo(v, OP_AND) && m_one(op(v, 1)) {
            mo_found_and1 = true;
            return ai_match_and_or_chain(op(v, 0));
        }
        if ai_bo(v, OP_AND) { return ai_match_and_or_chain(op(v, 0)) && ai_match_and_or_chain(op(v, 1)); }
    } else {
        if ai_bo(v, OP_OR) { return ai_match_and_or_chain(op(v, 0)) && ai_match_and_or_chain(op(v, 1)); }
    }
    var cand = v;
    var bit: i32 = -1;
    if ai_bo(v, OP_LSHR) {
        let c = m_apint(op(v, 1));
        if c >= 0 { cand = op(v, 0); bit = c; }
    }
    if mo_root < 0 { mo_root = cand; }
    if bit >= 0 && ap_uge_u64(ci_ap(bit), mo_mask.w as u64) { return false; }
    let b: i64 = if bit >= 0 { ap_lo64(ci_ap(bit)) as! i64 } else { 0 };
    mo_mask = ap_set_bit(mo_mask, b);
    return mo_root == cand;
}

fn ai_fold_any_or_all_bits_set(i: i32) -> bool {
    var all_set = false;
    var trunc_m = false;
    var x: i32 = -1;
    if ty_is_int(ty_scalar(vals[i].ty)) && ty_bits(ty_scalar(vals[i].ty)) == 1 {
        let s = ai_cast(i, OP_TRUNC);
        if s >= 0 && ai_one_use(s) && ai_bo(s, OP_AND) { all_set = true; }
        else if s >= 0 && ai_one_use(s) && ai_bo(s, OP_OR) { all_set = false; }
        else { return false; }
        trunc_m = true;
        x = op(i, 0);
    } else {
        // m_c_And(m_OneUse(m_And(m_Value(), m_Value())), m_Value())
        let ca = ai_bo(i, OP_AND) && ((ai_one_use(op(i, 0)) && ai_bo(op(i, 0), OP_AND)) || (ai_one_use(op(i, 1)) && ai_bo(op(i, 1), OP_AND)));
        if ca {
            x = i;
            all_set = true;
        } else if ai_bo(i, OP_AND) && ai_one_use(op(i, 0)) && ai_bo(op(i, 0), OP_OR) && m_one(op(i, 1)) {
            x = op(i, 0);
            all_set = false;
        } else { return false; }
        trunc_m = false;
    }
    let ty = vals[x].ty;
    mo_root = -1;
    mo_mask = ap_zero(ty_bits(ty_scalar(ty)));
    mo_and_chain = all_set;
    mo_found_and1 = false;
    if !ai_match_and_or_chain(x) || (all_set && !trunc_m && !mo_found_and1) { return false; }
    ab_set(i);
    let mask = c_int_ap(ty, mo_mask);
    let a = ab_binop(OP_AND, mo_root, mask, 0, "");
    let cmp = if all_set { ab_icmp(P_EQ, a, mask) } else { ab_icmp(P_NE, a, c_null(vals[a].ty)) };
    let z = if trunc_m { cmp } else { ab_zext(cmp, ty) };
    rauw(i, z);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Popcount

// replaceWithPopCount
fn ai_replace_with_popcount(i: i32, root: i32) {
    let rt = vals[root].ty;
    let ot = vals[i].ty;
    ab_set(i);
    var nv = ab_intrinsic(IID_ctpop, [rt as i32], [root], -1, "");
    if ot != rt { nv = ab_trunc(nv, ot); }
    rauw(i, nv);
}
fn ai_splat8(len: i64, b: u64) -> AP { ap_splat(len, ap_u64(b, 8)) }

// MaskedValueIsZero(V, Mask, SimplifyQuery(DL))
fn ai_masked_zero(v: i32, m: AP) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = masked_value_is_zero(v, m, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return r;
}

// matchPopCountBytes: Root or -1
fn ai_match_popcount_bytes(v: i32, len: i64) -> i32 {
    let m55 = ai_splat8(len, 0x55);
    let m33 = ai_splat8(len, 0x33);
    let m0f = ai_splat8(len, 0x0F);
    // m_And(m_c_Add(m_LShr(m_Value(Add2), m_SpecificInt(4)), m_Deferred(Add2)), m_SpecificInt(Mask0F))
    if !(ai_bo(v, OP_AND) && ai_si_ap(op(v, 1), m0f)) { return -1; }
    let ad = op(v, 0);
    if !ai_bo(ad, OP_ADD) { return -1; }
    var add2: i32 = -1;
    var ok = false;
    for k in 2 {
        let x = ai_lshr_by(op(ad, k), 4);
        if x >= 0 { add2 = x; if op(ad, 1 - k) == add2 { ok = true; break; } }
    }
    if !ok { return -1; }
    // (x & 0x33) + ((x >> 2) & 0x33) (commutative), or x - 3*((x >> 2) & 0x33)
    var sub1: i32 = -1;
    var ok2 = false;
    if ai_bo(add2, OP_ADD) {
        for k in 2 {
            let a = op(add2, k);
            let b = op(add2, 1 - k);
            if ai_bo(a, OP_AND) && ai_si_ap(op(a, 1), m33) {
                let s = ai_lshr_by(op(a, 0), 2);
                if s >= 0 {
                    sub1 = s;
                    if ai_and_spec(b, sub1, m33) { ok2 = true; break; }
                }
            }
        }
        if !ok2 {
            let neg3 = ap_i64(-3, len);
            let a = op(add2, 0);
            if ai_bo(a, OP_MUL) && ai_si_ap(op(a, 1), neg3) {
                let an = op(a, 0);
                if ai_bo(an, OP_AND) && ai_si_ap(op(an, 1), m33) {
                    let s = ai_lshr_by(op(an, 0), 2);
                    if s >= 0 { sub1 = s; if op(add2, 1) == sub1 { ok2 = true; } }
                }
            }
        }
    }
    if !ok2 { return -1; }
    // m_Sub(m_Value(Root), m_And(m_Value(LShr, m_LShr(m_Deferred(Root), m_SpecificInt(1))), m_APInt(AndMask)))
    if !ai_bo(sub1, OP_SUB) { return -1; }
    let root = op(sub1, 0);
    let an = op(sub1, 1);
    if !ai_bo(an, OP_AND) { return -1; }
    let lshr = op(an, 0);
    if ai_lshr_by(lshr, 1) != root { return -1; }
    let am = m_apint(op(an, 1));
    if am < 0 { return -1; }
    let andm = ci_ap(am);
    if !ap_eq(andm, m55) {
        if !ap_is_subset_of(andm, m55) { return -1; }
        let need = ap_and(m55, ap_not(andm));
        if !ai_masked_zero(lshr, need) { return -1; }
    }
    return root;
}

// tryToRecognizePopCount
fn ai_try_popcount(i: i32) -> bool {
    if iop(i) != OP_LSHR { return false; }
    let ty = vals[i].ty;
    if !ty_is_int(ty_scalar(ty)) { return false; }
    let len = ty_bits(ty_scalar(ty));
    if len > 128 || len <= 8 || len % 8 != 0 { return false; }
    let m01 = ai_splat8(len, 0x01);
    let o0 = op(i, 0);
    if !(ai_bo(o0, OP_MUL) && ai_si_ap(op(o0, 1), m01)) || !ai_si(op(i, 1), (len - 8) as u64) { return false; }
    let root = ai_match_popcount_bytes(op(o0, 0), len);
    if root < 0 { return false; }
    ai_replace_with_popcount(i, root);
    return true;
}

fn ai_is_pow2(x: i64) -> bool { x > 0 && (x & (x - 1)) == 0 }

// tryToRecognizePopCount1
fn ai_try_popcount1(i: i32) -> bool {
    if iop(i) != OP_ADD { return false; }
    let ty = vals[i].ty;
    if !ty_is_int(ty_scalar(ty)) { return false; }
    let len = ty_bits(ty_scalar(ty));
    if len > 64 || len <= 8 || len % 8 != 0 { return false; }
    if !ai_is_pow2(len) { return false; }
    let m55 = ai_splat8(len, 0x55);
    let m33 = ai_splat8(len, 0x33);
    fn valid_narrowed(cap: AP, exp: AP, operand: i32) -> bool {
        if ap_eq(cap, exp) { return true; }
        if !ap_is_subset_of(cap, exp) { return false; }
        return ai_masked_zero(operand, ap_and(exp, ap_not(cap)));
    }
    fn pair_ok(base: AP, sh: i64, val: i32, m1: AP, m2: AP) -> bool {
        if !ap_is_subset_of(m1, base) || !ap_is_subset_of(m2, base) { return false; }
        let ns = ap_shl(ap_and(base, ap_not(m1)), sh);
        let nu = ap_and(base, ap_not(m2));
        let all = ap_or(ns, nu);
        return ap_is_zero(all) || ai_masked_zero(val, all);
    }
    // m_c_Add(m_And(m_LShr(m_Value(X), S), m_APInt(M1)), m_And(m_Deferred(X), m_APInt(M2))): (ok, X, M1, M2)
    fn add_pair(v: i32, s: u64, x0: i32) -> bool, i32, i32, i32 {
        var x = x0;
        if !ai_bo(v, OP_ADD) { return false, x, -1, -1; }
        for k in 2 {
            let a = op(v, k);
            let b = op(v, 1 - k);
            if ai_bo(a, OP_AND) {
                let xs = ai_lshr_by(op(a, 0), s);
                if xs >= 0 {
                    x = xs;
                    let c1 = m_apint(op(a, 1));
                    if c1 >= 0 && ai_bo(b, OP_AND) && op(b, 0) == x {
                        let c2 = m_apint(op(b, 1));
                        if c2 >= 0 { return true, x, c1, c2; }
                    }
                }
            }
        }
        return false, x, -1, -1;
    }
    var shift_op: i32 = -1;
    var start = i;
    var w = len;
    while w >= 8 {
        let mask = ap_splat(len, ap_low_bits(w, w / 2));
        let ok, x, c1, c2 = add_pair(start, (w / 2) as u64, shift_op);
        shift_op = x;
        if ok {
            if !pair_ok(mask, w / 2, shift_op, ci_ap(c1), ci_ap(c2)) { return false; }
        } else {
            // m_c_Add(m_LShr(m_Value(X), S), m_And(m_Deferred(X), m_APInt(M1)))
            var ok2 = false;
            var m1: i32 = -1;
            if ai_bo(start, OP_ADD) {
                for k in 2 {
                    let a = op(start, k);
                    let b = op(start, 1 - k);
                    let xs = ai_lshr_by(a, (w / 2) as u64);
                    if xs >= 0 {
                        shift_op = xs;
                        if ai_bo(b, OP_AND) && op(b, 0) == shift_op {
                            let c = m_apint(op(b, 1));
                            if c >= 0 { m1 = c; ok2 = true; break; }
                        }
                    }
                }
            }
            if !ok2 { return false; }
            if !valid_narrowed(ci_ap(m1), mask, shift_op) { return false; }
        }
        start = shift_op;
        w = w / 2;
    }
    let ok3, x3, d1, d2 = add_pair(start, 2, shift_op);
    shift_op = x3;
    if !ok3 { return false; }
    if !pair_ok(m33, 2, shift_op, ci_ap(d1), ci_ap(d2)) { return false; }
    start = shift_op;
    let ok4, root, e1, e2 = add_pair(start, 1, -1);
    if !ok4 { return false; }
    if !pair_ok(m55, 1, root, ci_ap(e1), ci_ap(e2)) { return false; }
    ai_replace_with_popcount(i, root);
    return true;
}

// tryToRecognizePopCount2n3
fn ai_try_popcount2n3(i: i32) -> bool {
    if iop(i) != OP_AND { return false; }
    let ty = vals[i].ty;
    if !ty_is_int(ty_scalar(ty)) { return false; }
    var len = ty_bits(ty_scalar(ty));
    var add1: i32 = -1;
    if len == 8 {
        add1 = i;
    } else {
        let mr = m_apint(op(i, 1));
        if mr < 0 { return false; }
        add1 = op(i, 0);
        let ts = ai_cast(add1, OP_TRUNC);
        if ts >= 0 && ai_one_use(add1) {
            add1 = ts;
            len = ty_bits(ty_scalar(vals[add1].ty));
        }
        if len > 64 || len <= 8 || len % 8 != 0 { return false; }
        if !ai_is_pow2(len) { return false; }
        var nlb: i64 = 1;
        var t = len;
        while t > 1 { t = t / 2; nlb++; }
        let m = ci_ap(mr);
        if ap_countr_one(m) < nlb || ap_active_bits(m) > 8 { return false; }
        var w = len;
        while w >= 16 {
            var add2: i32 = -1;
            var ok = false;
            if ai_bo(add1, OP_ADD) {
                for k in 2 {
                    let x = ai_lshr_by(op(add1, k), (w / 2) as u64);
                    if x >= 0 { add2 = x; if op(add1, 1 - k) == add2 { ok = true; break; } }
                }
            }
            if !ok { return false; }
            add1 = add2;
            w = w / 2;
        }
    }
    let root = ai_match_popcount_bytes(add1, len);
    if root < 0 { return false; }
    ai_replace_with_popcount(i, root);
    return true;
}

// ---------------------------------------------------------------------------------------------
// tryToFPToSat

fn ai_try_fptosat(i: i32) -> bool {
    var inv: i32 = -1;
    var minc: i32 = -1;
    var maxc: i32 = -1;
    // m_SMax(m_OneUse(m_SMin(m_OneUse(m_FPToSI(m_Value(In))), m_APInt(MinC))), m_APInt(MaxC))
    var ok = false;
    if ai_intr(i, IID_smax) {
        let mn = ai_arg(i, 0);
        if ai_one_use(mn) && ai_intr(mn, IID_smin) {
            let f = ai_arg(mn, 0);
            if ai_one_use(f) && is_inst_op(f, OP_FPTOSI) {
                inv = op(f, 0);
                let c1 = m_apint(ai_arg(mn, 1));
                if c1 >= 0 {
                    minc = c1;
                    let c2 = m_apint(ai_arg(i, 1));
                    if c2 >= 0 { maxc = c2; ok = true; }
                }
            }
        }
    }
    if !ok && ai_intr(i, IID_smin) {
        let mx = ai_arg(i, 0);
        if ai_one_use(mx) && ai_intr(mx, IID_smax) {
            let f = ai_arg(mx, 0);
            if ai_one_use(f) && is_inst_op(f, OP_FPTOSI) {
                inv = op(f, 0);
                let c1 = m_apint(ai_arg(mx, 1));
                if c1 >= 0 {
                    maxc = c1;
                    let c2 = m_apint(ai_arg(i, 1));
                    if c2 >= 0 { minc = c2; ok = true; }
                }
            }
        }
    }
    if !ok { return false; }
    let mn1 = ap_add(ci_ap(minc), ap_u64(1, ci_ap(minc).w as i64));
    if !ap_is_pow2(mn1) || !ap_eq(ap_neg(ci_ap(maxc)), mn1) { return false; }
    let int_ty = vals[i].ty;
    let fp_ty = vals[inv].ty;
    var sat_ty = ty_int(ap_exact_log2(mn1) + 1);
    if ty_is_vector(int_ty) { sat_ty = ty_vector(sat_ty, types[int_ty].cnt, types[int_ty].kind == TK_SVEC); }
    let k = TCK_RECIP_THROUGHPUT;
    ai_tti();
    var sat_cost = tti_intrinsic_cost_args(IID_fptosi_sat, sat_ty, [inv], k);
    sat_cost = ai_cost_add(sat_cost, tti_cast_cost(OP_SEXT, int_ty, sat_ty, k));
    var mm_cost = tti_cast_cost(OP_FPTOSI, int_ty, fp_ty, k);
    mm_cost = ai_cost_add(mm_cost, tti_intrinsic_cost_args(IID_smin, int_ty, [], k));
    mm_cost = ai_cost_add(mm_cost, tti_intrinsic_cost_args(IID_smax, int_ty, [], k));
    if sat_cost >= mm_cost { return false; }
    ab_set(i);
    let sat = ab_intrinsic(IID_fptosi_sat, [sat_ty as i32, fp_ty as i32], [inv], -1, "");
    rauw(i, ab_sext(sat, int_ty));
    return true;
}

// ---------------------------------------------------------------------------------------------
// foldSqrt

fn ai_fold_sqrt(call: i32) -> bool {
    let ty = vals[call].ty;
    let arg = cb_arg(call, 0);
    if !ai_have_fast_sqrt(ty) { return false; }
    var ok = (insts[inst_of(call)].fmf & FMF_NNAN) != 0;
    if !ok {
        // cannotBeOrderedLessThanZero(Arg, SimplifyQuery(DL, &TLI, &DT, &AC, Call))
        let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
        kb_cxt = call; sq_no_dt = false; sq_no_ac = false; sq_no_tli = false;
        ok = cannot_be_ordered_less_than_zero(arg, 0);
        kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    }
    if !ok { return false; }
    ab_set(call);
    let ns = ab_intrinsic(IID_sqrt, [ty as i32], [arg], call, "sqrt");
    rauw(call, ns);
    inst_erase_from_parent(call);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Table-based cttz / log2

// ConstantFoldLoadFromConst(C, Ty, Offset, DL): the offset fits in 64 bits here
fn ai_load_from_const(c: i32, ty: i32, off: AP) -> i32 {
    if !ap_fits_u64(off) && !(off.w <= 64) { return -1; }
    return cf_fold_load_from_const(c, ty, ap_sext64(ap_sext_or_trunc(off, 64)));
}

// isCTTZTable
fn ai_is_cttz_table(table: i32, mul: AP, shift: AP, andm: AP, acc_ty: i32, ib: i64, factor: AP) -> bool {
    for idx in ib {
        let index = ap_and(ap_lshr_ap(ap_mul(ap_one_bit(ib, idx), mul), shift), andm);
        let c = ai_load_from_const(table, acc_ty, ap_mul(index, factor));
        if c < 0 || vals[c].kind != VK_CINT || ty_is_vector(vals[c].ty) || !ap_eq_u64(ci_ap(c), idx as u64) { return false; }
    }
    return true;
}
// isLog2Table
fn ai_is_log2_table(table: i32, mul: AP, shift: AP, acc_ty: i32, ib: i64, factor: AP) -> bool {
    for idx in ib {
        let index = ap_lshr_ap(ap_mul(ap_low_bits(ib, idx + 1), mul), shift);
        let c = ai_load_from_const(table, acc_ty, ap_mul(index, factor));
        if c < 0 || vals[c].kind != VK_CINT || ty_is_vector(vals[c].ty) || !ap_eq_u64(ci_ap(c), idx as u64) { return false; }
    }
    if !ap_is_zero(ap_lshr_ap(mul, shift)) { return false; }
    return true;
}
// m_CastOrSelf(P): the operand of a cast instruction if it is one, else V
fn ai_cast_or_self(v: i32) -> i32 { if is_inst(v) && is_cast_op(iop(v)) { op(v, 0) } else { v } }
// createUnlikelyBranchWeights
fn ai_set_unlikely(i: i32) {
    let ops: i32[3] = [md_string("branch_weights"), md_value(c_int(T_I32, 1)), md_value(c_int(T_I32, 1048575))];
    inst_set_md(i, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
}

// tryToRecognizeTableBasedCttz
fn ai_table_cttz(li: i32, acc_ty: i32, gv: i32, idxv: i32, scale: AP) -> bool {
    // m_LShr(m_Mul(m_c_And(m_Neg(m_Value(X1)), m_Deferred(X1)), m_APInt(MulConst)), m_APInt(ShiftConst))
    var x1: i32 = -1;
    fn inner(v: i32) -> bool, i32, i32 {
        if !ai_bo(v, OP_LSHR) { return false, -1, -1; }
        let m = op(v, 0);
        if !ai_bo(m, OP_MUL) { return false, -1, -1; }
        let a = op(m, 0);
        if !ai_bo(a, OP_AND) { return false, -1, -1; }
        var ok = false;
        for k in 2 {
            let x = m_neg(op(a, k));
            if x >= 0 { x1 = x; if op(a, 1 - k) == x1 { ok = true; break; } }
        }
        if !ok { return false, -1, -1; }
        let mc = m_apint(op(m, 1));
        if mc < 0 { return false, -1, -1; }
        let sc = m_apint(op(v, 1));
        if sc < 0 { return false, -1, -1; }
        return true, mc, sc;
    }
    var mulc: i32 = -1;
    var shc: i32 = -1;
    var andc: i32 = -1;
    let iv = ai_cast_or_self(idxv);
    let ok1, m1, s1 = inner(iv);
    if ok1 { mulc = m1; shc = s1; }
    else {
        if !ai_bo(iv, OP_AND) { return false; }
        let ok2, m2, s2 = inner(op(iv, 0));
        if !ok2 { return false; }
        let ac = m_apint(op(iv, 1));
        if ac < 0 { return false; }
        mulc = m2; shc = s2; andc = ac;
    }
    let ib = ty_bits(ty_scalar(vals[x1].ty));
    if ib != 16 && ib != 32 && ib != 64 && ib != 128 { return false; }
    if !ap_is_int_n(scale, ib) { return false; }
    let init = op(gv, 0);
    let andm = if andc >= 0 { ci_ap(andc) } else { ap_ones(ib) };
    if !ai_is_cttz_table(init, ci_ap(mulc), ci_ap(shc), andm, acc_ty, ib, ap_zext_or_trunc(scale, ib)) { return false; }
    let zte = ai_load_from_const(init, acc_ty, ap_zero(64));
    let defined0 = ap_eq_u64(ci_ap(zte), ib as u64);
    ab_set(li);
    let bc = if defined0 { c_false() } else { c_true() };
    let xty = vals[x1].ty;
    let cttz = ab_intrinsic(IID_cttz, [xty as i32], [x1, bc], -1, "");
    var res = ab_zext_or_trunc(cttz, acc_ty);
    if !defined0 {
        let cmp = ab_icmp(P_EQ, x1, c_int_ty(xty, 0));
        res = ab_select(cmp, zte, res, "", -1);
        if is_inst(res) { ai_set_unlikely(res); }
    }
    rauw(li, res);
    return true;
}

// tryToRecognizeTableBasedLog2
fn ai_table_log2(li: i32, acc_ty: i32, gv: i32, idxv: i32, scale: AP) -> bool {
    let iv = ai_cast_or_self(idxv);
    if !ai_bo(iv, OP_LSHR) { return false; }
    let m = op(iv, 0);
    if !ai_bo(m, OP_MUL) { return false; }
    var x = op(m, 0);
    let mc = m_apint(op(m, 1));
    if mc < 0 { return false; }
    let sc = m_apint(op(iv, 1));
    if sc < 0 { return false; }
    var isolated = false;
    if ai_bo(x, OP_SUB) {
        let v = op(x, 0);
        if ai_lshr_by(op(x, 1), 1) == v { isolated = true; x = v; }
    }
    let ib = ty_bits(ty_scalar(vals[x].ty));
    if ib != 16 && ib != 32 && ib != 64 && ib != 128 { return false; }
    var lg: i64 = 0;
    var t = ib;
    while t > 1 { t = t / 2; lg++; }
    if !ap_eq_u64(ci_ap(sc), (ib - lg) as u64) { return false; }
    var sa = ib / 2;
    while sa != 0 {
        var ok = false;
        var y: i32 = -1;
        if ai_bo(x, OP_OR) {
            for k in 2 {
                let yy = ai_lshr_by(op(x, k), sa as u64);
                if yy >= 0 { y = yy; if op(x, 1 - k) == y { ok = true; break; } }
            }
        }
        if !ok { return false; }
        x = y;
        sa = sa / 2;
    }
    if !ap_is_int_n(scale, ib) { return false; }
    let init = op(gv, 0);
    if isolated {
        if !ai_is_cttz_table(init, ci_ap(mc), ci_ap(sc), ap_ones(ib), acc_ty, ib, ap_zext_or_trunc(scale, ib)) { return false; }
    } else {
        if !ai_is_log2_table(init, ci_ap(mc), ci_ap(sc), acc_ty, ib, ap_zext_or_trunc(scale, ib)) { return false; }
    }
    let zte = ai_load_from_const(init, acc_ty, ap_zero(64));
    let xty = vals[x].ty;
    ai_tti();
    let cost = tti_intrinsic_cost_args(IID_ctlz, xty, [c_poison(xty), c_true()], TCK_SIZE_AND_LATENCY);
    if cost > TCC_BASIC { return false; }
    ab_set(li);
    let tru = c_true();
    let ctlz = ab_intrinsic(IID_ctlz, [xty as i32], [x, tru], -1, "");
    let sub = ab_binop(OP_SUB, c_int_ty(xty, (ib - 1) as u64), ctlz, 0, "");
    let cmp = ab_icmp(P_EQ, x, c_int_ty(xty, 0));
    let sel = ab_select(cmp, ab_zext(zte, xty), sub, "", -1);
    if is_inst(sel) { ai_set_unlikely(sel); }
    let r = ab_zext_or_trunc(sel, acc_ty);
    rauw(li, r);
    return true;
}

// tryToRecognizeTableBasedCttzOrLog2
fn ai_table_cttz_or_log2(i: i32) -> bool {
    if iop(i) != OP_LOAD { return false; }
    let acc_ty = vals[i].ty;
    if !ty_is_int(acc_ty) { return false; }
    let g = op(i, 0);
    if !is_inst_op(g, OP_GEP) || !ai_gep_nusw(g) { return false; }
    let gv = op(g, 0);
    if !is_gvar(gv) || nops(gv) == 0 || globs[glob_of(gv)].is_const == 0 { return false; }
    let bw = dl_ptr(ptr_as(vals[g].ty)).idx;
    let mark = co_vals.len;
    let ok, cst = ce_collect_offset(g, bw);
    let nv = co_vals.len - mark;
    if !ok || nv != 1 || !ap_is_zero(cst) { co_vals.resize(mark); co_scale.resize(mark); return false; }
    let idxv = co_vals[mark];
    let scale = co_scale[mark];
    co_vals.resize(mark); co_scale.resize(mark);
    if ai_table_cttz(i, acc_ty, gv, idxv, scale) { return true; }
    return ai_table_log2(i, acc_ty, gv, idxv, scale);
}
fn ai_gep_nusw(g: i32) -> bool { (gep_flags(g) & (GEP_INBOUNDS | GEP_NUSW)) != 0 }

// ---------------------------------------------------------------------------------------------
// Consecutive loads

var lo_root: i32 = -1;
var lo_root_insert: i32 = -1;
var lo_found: bool = false;
var lo_size: u64 = 0;
var lo_shift: u64 = 0;
var lo_zext_ty: i32 = -1;
var lo_tags = ml_null();

// m_OneUse(m_ShlOrSelf(m_OneUse(m_ZExt(m_Instruction(L))), ShAmt)): (ok, L, ShAmt). ShiftLike_match: a shl by a
// constant, or the value itself; a shl by a non-constant does not match at all.
fn ai_shl_zext(v: i32) -> bool, i32, u64 {
    if !ai_one_use(v) { return false, -1, 0; }
    var x = v;
    var sh: u64 = 0;
    if ai_bo(v, OP_SHL) {
        let c = m_apint(op(v, 1));
        if c < 0 || !ap_fits_u64(ci_ap(c)) { return false, -1, 0; }
        x = op(v, 0);
        sh = ap_zext64(ci_ap(c));
    }
    if !ai_one_use(x) || !is_inst_op(x, OP_ZEXT) { return false, -1, 0; }
    let l = op(x, 0);
    if !is_inst(l) { return false, -1, 0; }
    return true, l, sh;
}

fn ai_simple_load(l: i32) -> bool { is_inst_op(l, OP_LOAD) && !inst_is_volatile(l) && insts[inst_of(l)].ord == 0 }

// stripAndAccumulateConstantOffsets(DL, Offset, AllowNonInbounds = true): (base, offset)
fn ai_strip_offsets(p: i32) -> i32, i64 {
    let b = strip_and_accumulate_offsets(p, true, false, false);
    return b, vt_off;
}

recursive fn ai_fold_loads_recursive(v: i32, is_root: bool) -> bool {
    if !is_root && !ai_one_use(v) { return false; }
    // m_c_Or(m_Value(X), m_OneUse(m_ShlOrSelf(m_OneUse(m_ZExt(m_Instruction(L2))), ShAmt2)))
    if !ai_bo(v, OP_OR) { return false; }
    var x: i32 = -1;
    var l2: i32 = -1;
    var sh2: u64 = 0;
    var m = false;
    for k in 2 {
        let ok, l, s = ai_shl_zext(op(v, 1 - k));
        if ok { x = op(v, k); l2 = l; sh2 = s; m = true; break; }
    }
    if !m { return false; }
    if !ai_fold_loads_recursive(x, false) && lo_found { return false; }
    var li1 = lo_root;
    var sh1 = lo_shift;
    if !lo_found {
        let ok, l1, s1 = ai_shl_zext(x);
        if ok { sh1 = s1; li1 = if is_inst_op(l1, OP_LOAD) { l1 } else { -1 }; }
    }
    let li2 = if is_inst_op(l2, OP_LOAD) { l2 } else { -1 };
    if li1 == li2 || li1 < 0 || li2 < 0 || !ai_simple_load(li1) || !ai_simple_load(li2) ||
       ptr_as(vals[op(li1, 0)].ty) != ptr_as(vals[op(li2, 0)].ty) { return false; }
    if inst_parent(li1) != inst_parent(li2) { return false; }
    let big = dl_big_endian;
    var p1, off1 = ai_strip_offsets(op(li1, 0));
    var p2, off2 = ai_strip_offsets(op(li2, 0));
    var ls1 = ty_bits(vals[li1].ty) as u64;
    var ls2 = ty_bits(vals[li2].ty) as u64;
    if !ty_is_int(vals[li1].ty) { ls1 = ai_prim_size(vals[li1].ty); }
    if !ty_is_int(vals[li2].ty) { ls2 = ai_prim_size(vals[li2].ty); }
    if p1 != p2 { return false; }
    if !ai_size_eq_store(vals[li1].ty) || !ai_size_eq_store(vals[li2].ty) { return false; }
    var start = if lo_found { lo_root_insert } else { li1 };
    var end = li2;
    var loc = ml_null();
    if !comes_before(start, end) {
        let t = start; start = end; end = t;
        if lo_found {
            loc = ml_make(op(lo_root, 0), ls_precise(dl_store_size(ty_int(lo_size as i64)) as u64));
            loc.tbaa = lo_tags.tbaa; loc.tbaa_struct = lo_tags.tbaa_struct; loc.scope = lo_tags.scope;
            loc.noalias = lo_tags.noalias; loc.noalias_as = lo_tags.noalias_as;
        } else { loc = ml_get(end); }
    } else { loc = ml_get(end); }
    var nscan: i64 = 0;
    let maxscan = flag_int("aggressive-instcombine-max-scan-instrs", 64);
    var it = start;
    while it != end {
        if inst_may_write_memory(it) && mr_is_mod(aa_inst_loc_mr_simple(it, loc)) { return false; }
        nscan++;
        if nscan > maxscan { return false; }
        it = inst_next(it);
    }
    var reverse = false;
    var lia = li1;
    var lib = li2;
    if off2 < off1 {
        let t = lia; lia = lib; lib = t;
        let ts = sh1; sh1 = sh2; sh2 = ts;
        let to = off1; off1 = off2; off2 = to;
        let tp = p1; p1 = p2; p2 = tp;
        let tl = ls1; ls1 = ls2; ls2 = tl;
        reverse = true;
    }
    if big { let ts = sh1; sh1 = sh2; sh2 = ts; }
    if lo_found {
        if !reverse { ls1 = lo_size; } else { ls2 = lo_size; }
    }
    let diff = if big { ls2 } else { ls1 };
    let prev = dl_store_size(ty_int(ls1 as i64)) as u64;
    if (sh2 - sh1) != diff || ((off2 - off1) as! u64) != prev { return false; }
    if ls1 + ls2 > (ty_bits(ty_scalar(vals[x].ty)) as u64) { return false; }
    var t1 = lo_tags;
    let t2 = ml_aa_tags(lib);
    if !lo_found {
        lo_found = true;
        t1 = ml_aa_tags(lia);
    }
    lo_size = ls1 + ls2;
    lo_root_insert = start;
    lo_tags = ai_tags_concat(t1, t2);
    lo_root = lia;
    lo_shift = sh1;
    lo_zext_ty = vals[x].ty;
    return true;
}
fn ai_prim_size(t: i32) -> u64 { ty_bits(t) as u64 }
// DL.typeSizeEqualsStoreSize
fn ai_size_eq_store(t: i32) -> bool { dl_size_bits(t) == dl_store_size(t) * 8 }
// AAMDNodes::concat
fn ai_tags_concat(a: ML, b: ML) -> ML {
    var r = ml_null();
    r.tbaa = -1;
    r.tbaa_struct = -1;
    r.scope = cu_most_generic_alias_scope(a.scope, b.scope);
    r.noalias = cu_md_intersect(a.noalias, b.noalias);
    r.noalias_as = cu_most_generic_noalias_addrspace(a.noalias_as, b.noalias_as);
    return r;
}
fn ai_tags_any(t: ML) -> bool { t.tbaa >= 0 || t.tbaa_struct >= 0 || t.scope >= 0 || t.noalias >= 0 }
// Instruction::setAAMetadata
fn ai_set_tags(i: i32, t: ML) {
    fn set(k: i32, m: i32) { if m >= 0 { inst_set_md(i, k, m); } else { inst_erase_md(i, k); } }
    set(MDK_TBAA, t.tbaa);
    set(MDK_TBAA_STRUCT, t.tbaa_struct);
    set(MDK_ALIAS_SCOPE, t.scope);
    set(MDK_NOALIAS, t.noalias);
    set(MDK_NOALIAS_ADDRSPACE, t.noalias_as);
}

// foldConsecutiveLoads
fn ai_fold_consecutive_loads(i: i32) -> bool {
    if ty_is_vector(vals[i].ty) { return false; }
    lo_root = -1; lo_root_insert = -1; lo_found = false; lo_size = 0; lo_shift = 0; lo_zext_ty = -1; lo_tags = ml_null();
    if !ai_fold_loads_recursive(i, true) || !lo_found { return false; }
    let li1 = lo_root;
    let wty = ty_int(lo_size as i64);
    ai_tti();
    if !tti_is_type_legal(wty) { return false; }
    let al, fast = ai_allows_misaligned(lo_size as i64);
    if !al || !fast { return false; }
    var p1 = op(li1, 0);
    ab_set(lo_root_insert);
    if !dt_value_dominates_inst(p1, lo_root_insert) {
        let b, off = ai_strip_offsets(p1);
        let iw = dl_ptr(ptr_as(vals[p1].ty)).idx;
        p1 = ai_ptr_add(b, c_int_ty(ty_int(iw), off as! u64), false);
    }
    let nl = create_inst(OP_LOAD, wty, [p1]);
    insts[inst_of(nl)].align = insts[inst_of(li1)].align;
    insts[inst_of(nl)].bits = insts[inst_of(li1)].bits & 1;
    ab_insert(nl, "");
    ab_take_name(nl, li1);
    if ai_tags_any(lo_tags) { ai_set_tags(nl, lo_tags); }
    var nop = ab_zext(nl, lo_zext_ty);
    if lo_shift != 0 { nop = ab_binop(OP_SHL, nop, c_int_ty(vals[nop].ty, lo_shift), 0, ""); }
    rauw(i, nop);
    return true;
}
// CreatePtrAdd / CreateInBoundsPtrAdd: gep i8, ptr, offset
fn ai_ptr_add(p: i32, off: i32, inbounds: bool) -> i32 {
    let fl: u8 = if inbounds { GEP_INBOUNDS } else { 0 };
    if is_constant(p) && is_constant(off) { return ce_gep(T_I8, p, [off], fl, -1); }
    let g = create_inst(OP_GEP, vals[p].ty, [p, off]);
    insts[inst_of(g)].ty2 = T_I8;
    insts[inst_of(g)].flags = fl;
    return ab_insert(g, "");
}

// ---------------------------------------------------------------------------------------------
// Consecutive stores

struct PartStore { base: i32, off: i64, val: i32, voff: u64, vw: u64, st: i32 }

// matchPartStore
fn ai_match_part_store(i: i32) -> bool, PartStore {
    let none = PartStore { base: -1, off: 0, val: -1, voff: 0, vw: 0, st: -1 };
    if iop(i) != OP_STORE || !ai_simple_store(i) { return false, none; }
    let sv = op(i, 0);
    let sty = vals[sv].ty;
    if !ty_is_int(sty) || !ai_size_eq_store(sty) { return false, none; }
    let vw = ty_bits(sty) as u64;
    // m_Trunc(m_LShrOrSelf(m_Value(Val), ValOffset))
    let t = ai_cast(sv, OP_TRUNC);
    if t < 0 { return false, none; }
    var val = t;
    var voff: u64 = 0;
    if ai_bo(t, OP_LSHR) {
        let c = m_apint(op(t, 1));
        if c < 0 || !ap_fits_u64(ci_ap(c)) { return false, none; }
        val = op(t, 0);
        voff = ap_zext64(ci_ap(c));
    }
    let b, off = ai_strip_offsets(op(i, 1));
    return true, PartStore { base: b, off: off, val: val, voff: voff, vw: vw, st: i };
}
fn ai_simple_store(s: i32) -> bool { !inst_is_volatile(s) && insts[inst_of(s)].ord == 0 }

var ai_parts: PartStore[>..<];

// mergeConsecutivePartStores(Parts[b..e), Width)
fn ai_merge_consecutive_part_stores(b: i64, e: i64, width: i64) -> bool {
    if e - b < 2 { return false; }
    let first = ai_parts[b];
    let nty = ty_int(width);
    ai_tti();
    if !tti_is_type_legal(nty) { return false; }
    let al, fast = ai_allows_misaligned(width);
    if !al || !fast { return false; }
    ab_set(first.st);
    var v = first.val;
    if first.voff != 0 { v = ab_binop(OP_LSHR, v, c_int_ty(vals[v].ty, first.voff), 0, ""); }
    v = ab_zext_or_trunc(v, nty);
    let st = create_inst(OP_STORE, T_VOID, [v, op(first.st, 1)]);
    insts[inst_of(st)].align = insts[inst_of(first.st)].align;
    ab_insert(st, "");
    var tags = ml_aa_tags(first.st);
    var dl = inst_get_md(first.st, 0);
    for k in b + 1..e {
        let p = ai_parts[k];
        tags = ai_tags_concat(tags, ml_aa_tags(p.st));
        dl = merged_location_pair(dl, inst_get_md(p.st, 0));
    }
    ai_set_tags(st, tags);
    for k in b..e { if inst_get_md(ai_parts[k].st, md_kind_id("DIAssignID")) >= 0 { ai_fail("mergeDIAssignID"); } }
    if dl >= 0 { inst_set_md(st, 0, dl); } else { inst_erase_md(st, 0); }
    for k in b..e { inst_erase_from_parent(ai_parts[k].st); }
    return true;
}
// DebugLoc::getMergedLocations, folded pairwise
fn merged_location_pair(a: i32, b: i32) -> i32 { m2r_merged_location(a, b) }

// mergePartStores
fn ai_merge_part_stores() -> bool {
    if ai_parts.len < 2 { return false; }
    var changed = false;
    // llvm::sort by PtrOffset.slt (std::sort; equal offsets never merge, so any order of them gives the same result)
    std_sort(ai_parts, 0, ai_parts.len) { a, b => a.off < b.off };
    var last_end: i64 = 0;
    var fi: i64 = 0;
    for k in ai_parts.len {
        let p = ai_parts[k];
        let f = ai_parts[fi];
        let po = ((p.off as! u64) - (f.off as! u64)) as! i64;
        let vo = ((p.voff - f.voff) as! i64);
        if ((po as! u64) * 8) as! i64 != vo || last_end != vo {
            if ai_merge_consecutive_part_stores(fi, k, last_end) { changed = true; }
            fi = k;
            last_end = p.vw as i64;
            continue;
        }
        last_end = vo + (p.vw as i64);
    }
    if ai_merge_consecutive_part_stores(fi, ai_parts.len, last_end) { changed = true; }
    return changed;
}

// foldConsecutiveStores
fn ai_fold_consecutive_stores(bb: i32) -> bool {
    if dl_big_endian { return false; }
    ai_parts.resize(0);
    var changed = false;
    let q = aq_push(CA_SIMPLE);
    var i = block_first(bb);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        let ok, part = ai_match_part_store(cur);
        if ok {
            if ai_parts.len == 0 || (part.base == ai_parts[0].base && part.val == ai_parts[0].val) {
                ai_parts.push(part);
                continue;
            }
            if ai_merge_part_stores() { changed = true; }
            ai_parts.resize(0);
            ai_parts.push(part);
            continue;
        }
        if ai_parts.len == 0 { continue; }
        if inst_may_throw(cur) ||
           (inst_may_read_or_write_memory(cur) && aa_inst_loc_mr(cur, ml_before_or_after(ai_parts[0].base), q) != MR_NO) {
            if ai_merge_part_stores() { changed = true; }
            ai_parts.resize(0);
            continue;
        }
    }
    aq_pop(q);
    if ai_merge_part_stores() { changed = true; }
    ai_parts.resize(0);
    return changed;
}

// ---------------------------------------------------------------------------------------------
// icmp of or chains

// optimizeShiftInOrChain: -1 = nullptr
recursive fn ai_optimize_shift_in_or_chain(v: i32) -> i32 {
    if !is_inst_op(v, OP_OR) || !ai_one_use(v) { return -1; }
    var o0 = op(v, 0);
    if opcode_of(o0) == OP_SHL && (op_flags(o0) & (FL_NSW | FL_NUW)) != 0 { o0 = op(o0, 0); }
    else {
        let n = ai_optimize_shift_in_or_chain(o0);
        if n >= 0 { o0 = n; }
    }
    var o1 = op(v, 1);
    if opcode_of(o1) == OP_SHL && (op_flags(o1) & (FL_NSW | FL_NUW)) != 0 { o1 = op(o1, 0); }
    else {
        let n = ai_optimize_shift_in_or_chain(o1);
        if n >= 0 { o1 = n; }
    }
    if o0 != op(v, 0) || o1 != op(v, 1) { return ab_binop(OP_OR, o0, o1, 0, ""); }
    return -1;
}

// foldICmpOrChain
fn ai_fold_icmp_or_chain(i: i32) -> bool {
    if !is_inst_op(i, OP_ICMP) || !m_zero(op(i, 1)) || !pred_is_equality(inst_pred(i)) { return false; }
    let o0 = op(i, 0);
    if is_inst_op(o0, OP_OR) {
        if ai_fold_consecutive_loads(o0) { return true; }
    }
    ab_set(i);
    let r = ai_optimize_shift_in_or_chain(o0);
    if r >= 0 {
        rauw(i, ab_icmp(inst_pred(i), r, op(i, 1)));
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// foldPatternedLoads

// getStrideAndModOffsetOfGEP: (stride, mod offset) in the index width
fn ai_stride_and_mod_offset(p0: i32) -> AP, AP {
    let bw = dl_ptr(ptr_as(vals[p0].ty)).idx;
    var p = p0;
    var have_stride = false;
    var stride = ap_zero(bw);
    var mod_off = ap_zero(bw);
    while opcode_of(p) == OP_GEP {
        let mark = co_vals.len;
        let ok, c = ce_collect_offset(p, bw);
        if !ok { co_vals.resize(mark); co_scale.resize(mark); break; }
        mod_off = ap_add(mod_off, c);
        for k in mark..co_vals.len {
            var sc = co_scale[k];
            if !ai_gep_nusw(p) { sc = ap_one_bit(bw, ap_countr_zero(sc)); }
            if !have_stride { stride = sc; have_stride = true; }
            else { stride = ap_gcd(stride, sc); }
        }
        co_vals.resize(mark); co_scale.resize(mark);
        p = op(p, 0);
    }
    if !is_gvar(p) || !have_stride { return ap_u64(1, bw), ap_zero(bw); }
    mod_off = ap_srem(mod_off, stride);
    if ap_is_neg(mod_off) { mod_off = ap_add(mod_off, stride); }
    return stride, mod_off;
}

fn ai_fold_patterned_loads(i: i32) -> bool {
    if iop(i) != OP_LOAD || inst_is_volatile(i) { return false; }
    let p = op(i, 0);
    let gv = get_underlying_object(p, 6);
    if !is_gvar(gv) || globs[glob_of(gv)].is_const == 0 || !ai_has_definitive_initializer(gv) { return false; }
    let c = op(gv, 0);
    let gsize = dl_alloc_size(vals[c].ty) as u64;
    if gsize == 0 || 4096 < gsize { return false; }
    let lty = vals[i].ty;
    let bw = dl_ptr(ptr_as(vals[p].ty)).idx;
    var stride, coff = ai_stride_and_mod_offset(p);
    let la = ai_align_bytes(insts[inst_of(i)].align);
    let ga0 = ai_align_bytes(globs[glob_of(gv)].align);
    let ga = if ga0 == 0 { 1 } else { ga0 };
    if la <= ga && ap_zext64(stride) < la {
        coff = ap_zero(bw);
        stride = ap_u64(la, bw);
    }
    let ca = ai_load_from_const(c, lty, coff);
    if ca < 0 { return false; }
    let e = (gsize - (dl_store_size(lty) as u64)) & 0xFFFFFFFF;
    while ap_zext64(coff) <= e {
        if ca != ai_load_from_const(c, lty, coff) { return false; }
        coff = ap_add(coff, stride);
    }
    rauw(i, ca);
    return true;
}
fn ai_align_bytes(lg: u8) -> u64 { if lg == 0 { 1 } else { (1 as u64) << ((lg - 1) as u64) } }
// GlobalVariable::hasDefinitiveInitializer
fn ai_has_definitive_initializer(gv: i32) -> bool {
    if nops(gv) == 0 { return false; }
    let l = globs[glob_of(gv)].linkage as i64;
    // isInterposable (weak, linkonce, common, extern_weak; available_externally is not) or externally_initialized
    if l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK || l == LK_WEAK_ODR || l == LK_LINKONCE_ODR {
        // mayBeDerefined: the ODR linkages keep the definition
        if l != LK_WEAK_ODR && l != LK_LINKONCE_ODR { return false; }
    }
    if globs[glob_of(gv)].ext_init != 0 { return false; }
    return true;
}

// ---------------------------------------------------------------------------------------------
// strncmp / strcmp inlining, memchr

var ai_cfg_change: bool = false;

// SplitBlock(Old, SplitPt, DTU, nullptr, nullptr, BBName)
fn ai_split_block(old: i32, at: i32, name: const u8[:]) -> i32 {
    var nm: u8[>..] = [];
    if name.len == 0 { nm.append(val_name(old)); nm.append(".split"); } else { nm.append(name); }
    var sp = at;
    while iop(sp) == OP_PHI || inst_is_eh_pad(sp) { sp = inst_next(sp); }
    let nb = split_block(old, sp, nm);
    var ups: DTUpdate[>..<] = [];
    var uniq: i32[>..<] = [];
    ups.push(DTUpdate { kind: DT_INSERT, from: old, to: nb });
    for k in block_nsucc(nb) {
        let s = block_succ(nb, k);
        var seen = false;
        for x in uniq { if x == s { seen = true; } }
        if seen { continue; }
        uniq.push(s);
        ups.push(DTUpdate { kind: DT_INSERT, from: nb, to: s });
        ups.push(DTUpdate { kind: DT_DELETE, from: old, to: s });
    }
    dtu_apply_updates(ups);
    return nb;
}

fn ai_entry_count(fv: i32) -> u64 {
    let m = func_get_md(fv, md_kind_id("prof"));
    if m < 0 { return 0; }
    if mds[m].nops < 2 { return 0; }
    let s = md_op(m, 0);
    if s < 0 || mds[s].kind != MK_STRING || sbytes(mds[s].extra) != "function_entry_count" { return 0; }
    let c = mds[md_op(m, 1)].extra;
    return ap_zext64(ci_ap(c));
}
// setExplicitlyUnknownBranchWeights(I, "aggressive-instcombine")
fn ai_set_unknown_weights(i: i32) {
    let ops: i32[2] = [md_string("unknown"), md_string("aggressive-instcombine")];
    inst_set_md(i, md_kind_id("prof"), md_get(MK_TUPLE, -1, ops, false));
}

// StrNCmpInliner::optimizeStrNCmp
fn ai_optimize_strncmp(ci: i32, lf: i32) -> bool {
    let thr = flag_int("strncmp-inline-threshold", 3);
    if thr < 2 { return false; }
    // isOnlyUsedInZeroComparison
    if vals[ci].first_use < 0 { return false; }
    var u = vals[ci].first_use;
    while u >= 0 {
        let us = uses[u].user;
        u = uses[u].next;
        if !(is_inst_op(us, OP_ICMP) && m_zero(op(us, 1))) { return false; }
    }
    let s1p = cb_arg(ci, 0);
    let s2p = cb_arg(ci, 1);
    if s1p == s2p { return false; }
    let has1 = ic::get_constant_string_info(s1p, false);
    var str1: u8[>..<] = [];
    for c in ic::lcs_str { str1.push(c); }
    let has2 = ic::get_constant_string_info(s2p, false);
    var str2: u8[>..<] = [];
    for c in ic::lcs_str { str2.push(c); }
    if has1 == has2 { return false; }
    let sp = if has1 { s2p } else { s1p };
    var s: u8[>..<] = [];
    if has1 { for c in str1 { s.push(c); } } else { for c in str2 { s.push(c); } }
    var n: u64 = 0xFFFFFFFFFFFFFFFF;
    for k in s.len { if s[k] == 0 { n = (k + 1) as u64; break; } }
    if lf == LF_strncmp {
        let c = cb_arg(ci, 2);
        if vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) {
            let z = ap_zext64(ci_ap(c));
            if z < n { n = z; }
        } else { return false; }
    }
    if n > (s.len as u64) || n < 2 || n > (thr as u64) { return false; }
    let db, cbn = pointer_deref_bytes(sp);
    if db > 1 { return false; }
    ai_inline_compare(ci, sp, s, n as i64, has1);
    return true;
}

// StrNCmpInliner::inlineCompare
fn ai_inline_compare(ci: i32, lhs: i32, rhs: const u8[:], n: i64, swapped: bool) {
    let dl = inst_get_md(ci, 0);
    let fv = inst_func(ci);
    let bbci = inst_parent(ci);
    var tn: u8[>..] = [];
    tn.append(val_name(bbci));
    tn.append(".tail");
    let bbtail = ai_split_block(bbci, ci, tn);
    var subs: i32[>..<] = [];
    for k in n {
        var nm: u8[>..] = [];
        nm.append("sub_");
        format(nm, k);
        subs.push(create_block_before(fv, bbtail, nm));
    }
    let bbne = create_block_before(fv, bbtail, "ne");
    term_set_succ(block_terminator(bbci), 0, subs[0]);
    ab_set_end(bbne);
    ab_dl = dl;
    let phi = ab_phi(vals[ci].ty, "");
    ab_insert(create_inst(OP_BR, T_VOID, [bbtail]), "");
    let cty = vals[ci].ty;
    for k in n {
        ab_set_end(subs[k]);
        let gp = ai_ptr_add(lhs, c_int(T_I64, k), true);
        let ld = create_inst(OP_LOAD, T_I8, [gp]);
        insts[inst_of(ld)].align = 1;
        ab_insert(ld, "");
        let vl = ab_zext(ld, cty);
        let vr = c_int_ty(cty, rhs[k] as u64);
        let sub = if swapped { ab_binop(OP_SUB, vr, vl, 0, "") } else { ab_binop(OP_SUB, vl, vr, 0, "") };
        if k < n - 1 {
            let c = ab_icmp(P_NE, sub, c_int_ty(cty, 0));
            let br = ab_insert(create_inst(OP_CONDBR, T_VOID, [c, bbne, subs[k + 1]]), "");
            if ai_entry_count(fv) > 0 { ai_set_unknown_weights(br); }
        } else {
            ab_insert(create_inst(OP_BR, T_VOID, [bbne]), "");
        }
        phi_add_incoming(phi, sub, subs[k]);
    }
    rauw(ci, phi);
    inst_erase_from_parent(ci);
    var ups: DTUpdate[>..<] = [];
    ups.push(DTUpdate { kind: DT_INSERT, from: bbci, to: subs[0] });
    for k in n {
        if k < n - 1 { ups.push(DTUpdate { kind: DT_INSERT, from: subs[k], to: subs[k + 1] }); }
        ups.push(DTUpdate { kind: DT_INSERT, from: subs[k], to: bbne });
    }
    ups.push(DTUpdate { kind: DT_INSERT, from: bbne, to: bbtail });
    ups.push(DTUpdate { kind: DT_DELETE, from: bbci, to: bbtail });
    dtu_apply_updates(ups);
}

// foldMemChr
fn ai_fold_memchr(call: i32) -> bool {
    if is_constant(cb_arg(call, 1)) { return false; }
    let base = cb_arg(call, 0);
    if !ic::get_constant_string_info(base, false) { return false; }
    var s: u8[>..<] = [];
    for c in ic::lcs_str { s.push(c); }
    var n = s.len as u64;
    let c2 = cb_arg(call, 2);
    if vals[c2].kind == VK_CINT && !ty_is_vector(vals[c2].ty) {
        let v = ap_zext64(ci_ap(c2));
        if v > n { return false; }
        n = v;
    } else { return false; }
    if n > (flag_int("memchr-inline-threshold", 3) as u64) { return false; }
    let bb = inst_parent(call);
    let fv = inst_func(call);
    let bbnext = ai_split_block(bb, call, "");
    let dl = inst_get_md(call, 0);
    inst_erase_from_parent(block_terminator(bb));
    ab_set_end(bb);
    ab_dl = dl;
    let tr = ab_trunc(cb_arg(call, 1), T_I8);
    let si = ab_insert(create_inst(OP_SWITCH, T_VOID, [tr, bbnext]), "");
    if ai_entry_count(fv) > 0 { ai_set_unknown_weights(si); }
    let idx_ty = ty_int(dl_ptr(ptr_as(vals[call].ty)).idx);
    var ups: DTUpdate[>..<] = [];
    let bbsucc = create_block_before(fv, bbnext, "memchr.success");
    ab_set_end(bbsucc);
    let iphi = ab_phi(idx_ty, "memchr.idx");
    let first = ai_ptr_add(base, iphi, true);
    ab_insert(create_inst(OP_BR, T_VOID, [bbnext]), "");
    ups.push(DTUpdate { kind: DT_INSERT, from: bbsucc, to: bbnext });
    var cases: i32[>..<] = [];
    for k in n as i64 {
        let cv = c_int(T_I8, s[k] as i64);
        var seen = false;
        for x in cases { if x == cv { seen = true; } }
        if seen { continue; }
        cases.push(cv);
        let bbc = create_block_before(fv, bbsucc, "memchr.case");
        push_op(si, cv);
        push_op(si, bbc);
        ab_set_end(bbc);
        phi_add_incoming(iphi, c_int_ty(idx_ty, k as u64), bbc);
        ab_insert(create_inst(OP_BR, T_VOID, [bbsucc]), "");
        ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: bbc });
        ups.push(DTUpdate { kind: DT_INSERT, from: bbc, to: bbsucc });
    }
    let phi = create_inst(OP_PHI, vals[call].ty, []);
    inst_insert_before_head(phi, block_first(bbnext));
    if vals[call].name >= 0 { var nm: u8[>..] = []; nm.append(sbytes(vals[call].name)); set_name(phi, nm); }
    phi_add_incoming(phi, c_null(vals[call].ty), bb);
    phi_add_incoming(phi, first, bbsucc);
    rauw(call, phi);
    inst_erase_from_parent(call);
    dtu_apply_updates(ups);
    return true;
}

// foldLibCalls
fn ai_fold_lib_calls(i: i32) -> bool {
    if iop(i) != OP_CALL || call_is_nobuiltin(i) { return false; }
    let f = called_function(i);
    if f < 0 { return false; }
    let lf = tli_get_libfunc(f);
    if lf < 0 || !tli_has(lf) || !blc_is_emittable(lf as i64) { return false; }
    if lf == LF_sqrt || lf == LF_sqrtf || lf == LF_sqrtl { return ai_fold_sqrt(i); }
    if lf == LF_strcmp || lf == LF_strncmp || lf == LF_memchr {
        dtu_begin(ai_fv, true, false, true);
        var r = false;
        if lf == LF_memchr { r = ai_fold_memchr(i); } else { r = ai_optimize_strncmp(i, lf); }
        dtu_end();
        if r { ai_cfg_change = true; }
        return r;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// foldMulHigh

var mh_bw: i64 = 0;
var mh_low: AP;
var mh_i: i32 = -1;

fn mh_half() -> u64 { (mh_bw / 2) as u64 }
// m_LShr(m_Value(X), m_SpecificInt(BW/2))
fn mh_hi(v: i32) -> i32 { ai_lshr_by(v, mh_half()) }
// CheckLoLo: m_c_Mul(m_And(m_Specific(X), m_SpecificInt(LowMask)), m_And(m_Specific(Y), m_SpecificInt(LowMask)))
fn mh_lolo(v: i32, x: i32, y: i32) -> bool {
    if !ai_bo(v, OP_MUL) { return false; }
    for k in 2 { if ai_and_spec(op(v, k), x, mh_low) && ai_and_spec(op(v, 1 - k), y, mh_low) { return true; } }
    return false;
}
// CheckHiLo: m_c_Mul(m_LShr(m_Specific(X), m_SpecificInt(BW/2)), m_And(m_Specific(Y), m_SpecificInt(LowMask)))
fn mh_hilo(v: i32, x: i32, y: i32) -> bool {
    if !ai_bo(v, OP_MUL) { return false; }
    for k in 2 {
        let a = op(v, k);
        if ai_bo(a, OP_LSHR) && op(a, 0) == x && ai_si(op(a, 1), mh_half()) && ai_and_spec(op(v, 1 - k), y, mh_low) { return true; }
    }
    return false;
}
fn mh_create(x: i32, y: i32) -> bool {
    let i = mh_i;
    ab_set(i);
    let ty = vals[i].ty;
    let nty = ty_with_elem(ty, ty_int(mh_bw * 2));
    let xe = ab_zext(x, nty);
    let ye = ab_zext(y, nty);
    let m = ab_binop(OP_MUL, xe, ye, FL_NUW, "");
    let h = ab_binop(OP_LSHR, m, c_int_ty(nty, mh_bw as u64), 0, "");
    let r = ab_cast(OP_TRUNC, h, ty, FL_NUW, "");
    ab_take_name(r, i);
    rauw(i, r);
    return true;
}
// m_OneUse(m_Select(m_OneUse(m_SpecificICmp(ULT, m_Value(A), m_Value(B))), m_SpecificInt(1 << BW/2), m_Zero()))
fn mh_carry_select(v: i32) -> bool, i32, i32 {
    if !(ai_one_use(v) && is_inst_op(v, OP_SELECT)) { return false, -1, -1; }
    let c = op(v, 0);
    if !(ai_one_use(c) && ai_icmp_is(c, P_ULT)) { return false, -1, -1; }
    let a = op(c, 0);
    let b = op(c, 1);
    if !ai_si_ap(op(v, 1), ap_one_bit(mh_bw, mh_bw / 2)) || !m_zero(op(v, 2)) { return false, a, b; }
    return true, a, b;
}
fn mh_is_c_add(v: i32) -> bool { ai_bo(v, OP_ADD) }

// FoldMulHighCarry
fn mh_carry(x0: i32, y0: i32, carry0: i32, b0: i32) -> bool {
    var x = x0; var y = y0; var carry = carry0; var b = b0;
    if iop(carry) != OP_SELECT { let t = carry; carry = b; b = t; }
    let ok, low_sum, xhyl = mh_carry_select(carry);
    if !ok { return false; }
    if !mh_hilo(xhyl, x, y) {
        if mh_hilo(xhyl, y, x) { let t = x; x = y; y = t; } else { return false; }
    }
    if ai_n_uses_or_more(xhyl, 3) { return false; }
    if !(ai_one_use(b) && ai_bo(b, OP_LSHR) && op(b, 0) == low_sum && ai_si(op(b, 1), mh_half())) || ai_n_uses_or_more(low_sum, 3) { return false; }
    // LowSum = XhYl + XlYh + XlYl>>32 (three groupings)
    var xlyh: i32 = -1;
    var xlyl: i32 = -1;
    var m = false;
    // m_c_Add(m_Specific(XhYl), m_OneUse(m_c_Add(m_OneUse(m_Value(XlYh)), XlYlHi)))
    if mh_is_c_add(low_sum) {
        for k in 2 {
            if op(low_sum, k) != xhyl { continue; }
            let inner = op(low_sum, 1 - k);
            if !(ai_one_use(inner) && mh_is_c_add(inner)) { continue; }
            for j in 2 {
                let a = op(inner, j);
                let c = op(inner, 1 - j);
                if ai_one_use(a) {
                    xlyh = a;
                    let l = mh_hi(c);
                    if l >= 0 { xlyl = l; m = true; break; }
                }
            }
            if m { break; }
        }
    }
    // m_c_Add(m_OneUse(m_Value(XlYh)), m_OneUse(m_c_Add(m_Specific(XhYl), XlYlHi)))
    if !m && mh_is_c_add(low_sum) {
        for k in 2 {
            let a = op(low_sum, k);
            let inner = op(low_sum, 1 - k);
            if !ai_one_use(a) { continue; }
            xlyh = a;
            if !(ai_one_use(inner) && mh_is_c_add(inner)) { continue; }
            for j in 2 {
                if op(inner, j) != xhyl { continue; }
                let l = mh_hi(op(inner, 1 - j));
                if l >= 0 { xlyl = l; m = true; break; }
            }
            if m { break; }
        }
    }
    // m_c_Add(XlYlHi, m_OneUse(m_c_Add(m_Specific(XhYl), m_OneUse(m_Value(XlYh)))))
    if !m && mh_is_c_add(low_sum) {
        for k in 2 {
            let l = mh_hi(op(low_sum, k));
            if l < 0 { continue; }
            xlyl = l;
            let inner = op(low_sum, 1 - k);
            if !(ai_one_use(inner) && mh_is_c_add(inner)) { continue; }
            for j in 2 {
                if op(inner, j) != xhyl { continue; }
                let a = op(inner, 1 - j);
                if ai_one_use(a) { xlyh = a; m = true; break; }
            }
            if m { break; }
        }
    }
    if !m { return false; }
    if !mh_lolo(xlyl, x, y) { return false; }
    if !mh_hilo(xlyh, y, x) { return false; }
    return mh_create(x, y);
}

// m_c_Add(m_c_Add(A, B), C) helpers for the ladder: is v = (p + q) + r with the given leaves (commutative both)
// FoldMulHighLadder
fn mh_ladder(x: i32, y: i32, a: i32, b: i32) -> bool {
    var c2 = mh_hi(a);
    var c3 = mh_hi(b);
    if c2 < 0 || c3 < 0 { return false; }
    // if (match(C3, m_c_Add(m_Add(m_Value(), m_Value()), m_Value()))) swap(C2, C3)
    if ai_bo(c3, OP_ADD) && (ai_bo(op(c3, 0), OP_ADD) || ai_bo(op(c3, 1), OP_ADD)) { let t = c2; c2 = c3; c3 = t; }
    var xlyh: i32 = -1;
    var xhyl: i32 = -1;
    var xlyl: i32 = -1;
    // three forms of c2 = (c3 & Low) + xlyh + (xlyl >> half)
    fn and_c3(v: i32) -> bool { ai_and_spec(v, c3, mh_low) }
    var form = false;
    // m_c_Add(m_c_Add(m_And(m_Specific(C3), Low), m_Value(XlYh)), m_LShr(m_Value(XlYl), half))
    if ai_bo(c2, OP_ADD) {
        for k in 2 {
            let inner = op(c2, k);
            let other = op(c2, 1 - k);
            if !ai_bo(inner, OP_ADD) { continue; }
            var got = false;
            for j in 2 { if and_c3(op(inner, j)) { xlyh = op(inner, 1 - j); got = true; break; } }
            if !got { continue; }
            let l = mh_hi(other);
            if l >= 0 { xlyl = l; form = true; break; }
        }
    }
    // m_c_Add(m_c_Add(m_And(m_Specific(C3), Low), m_LShr(m_Value(XlYl), half)), m_Value(XlYh))
    if !form && ai_bo(c2, OP_ADD) {
        for k in 2 {
            let inner = op(c2, k);
            let other = op(c2, 1 - k);
            if !ai_bo(inner, OP_ADD) { continue; }
            var got = false;
            for j in 2 {
                if and_c3(op(inner, j)) {
                    let l = mh_hi(op(inner, 1 - j));
                    if l >= 0 { xlyl = l; got = true; break; }
                }
            }
            if got { xlyh = other; form = true; break; }
        }
    }
    // m_c_Add(m_c_Add(m_LShr(m_Value(XlYl), half), m_Value(XlYh)), m_And(m_Specific(C3), Low))
    if !form && ai_bo(c2, OP_ADD) {
        for k in 2 {
            let inner = op(c2, k);
            let other = op(c2, 1 - k);
            if !ai_bo(inner, OP_ADD) { continue; }
            var got = false;
            for j in 2 {
                let l = mh_hi(op(inner, j));
                if l >= 0 { xlyl = l; xlyh = op(inner, 1 - j); got = true; break; }
            }
            if got && and_c3(other) { form = true; break; }
        }
    }
    if form {
        xhyl = c3;
    } else {
        // c3 = c2 & Low + xl*yh
        fn c3_form(c3v: i32, c2v: i32, need_one_use: bool) -> bool, i32 {
            if !ai_bo(c3v, OP_ADD) { return false, -1; }
            for k in 2 {
                let a0 = op(c3v, k);
                if (!need_one_use || ai_one_use(a0)) && ai_and_spec(a0, c2v, mh_low) { return true, op(c3v, 1 - k); }
            }
            return false, -1;
        }
        let okf, v0 = c3_form(c3, c2, false);
        if okf { xlyh = v0; } else { let t = c2; c2 = c3; c3 = t; }
        let okg, v1 = c3_form(c3, c2, true);
        if okg { xlyh = v1; }
        if !okg || !ai_one_use(c3) || ai_n_uses_or_more(c2, 3) { return false; }
        // c2 = xh*yl + (xl*yl >> 32)
        var got = false;
        if ai_bo(c2, OP_ADD) {
            for k in 2 {
                let l = mh_hi(op(c2, k));
                if l >= 0 { xlyl = l; xhyl = op(c2, 1 - k); got = true; break; }
            }
        }
        if !got { return false; }
    }
    if !mh_hilo(xlyh, y, x) { let t = xlyh; xlyh = xhyl; xhyl = t; }
    if !mh_hilo(xlyh, y, x) { return false; }
    if !mh_hilo(xhyl, x, y) { return false; }
    if !mh_lolo(xlyl, x, y) { return false; }
    return mh_create(x, y);
}

// FoldMulHighLadder4
fn mh_ladder4(x: i32, y: i32, a0: i32, b0: i32, c0: i32) -> bool {
    var a = a0; var b = b0; var c = c0;
    fn shift_add(v: i32) -> bool { ai_bo(v, OP_LSHR) && ai_bo(op(v, 0), OP_ADD) && ai_si(op(v, 1), mh_half()) }
    if !shift_add(a) { let t = a; a = b; b = t; }
    if !shift_add(a) { let t = a; a = c; c = t; }
    let low = mh_hi(a);
    if low < 0 || !ai_one_use(low) { return false; }
    var xhyl = mh_hi(b);
    var xlyh = mh_hi(c);
    if xhyl < 0 || xlyh < 0 { return false; }
    if !mh_hilo(xhyl, x, y) { let t = xhyl; xhyl = xlyh; xlyh = t; }
    if !mh_hilo(xhyl, x, y) || ai_n_uses_or_more(xhyl, 3) { return false; }
    if !mh_hilo(xlyh, y, x) || ai_n_uses_or_more(xlyh, 3) { return false; }
    // Low = XlYl>>32 + XhYl&Low + XlYh&Low (three groupings, one-use everywhere)
    fn ou_and(v: i32, s: i32) -> bool { ai_one_use(v) && ai_and_spec(v, s, mh_low) }
    fn ou_hi(v: i32) -> i32 { if ai_one_use(v) { mh_hi(v) } else { -1 } }
    var xlyl: i32 = -1;
    var m = false;
    if ai_bo(low, OP_ADD) {
        // m_c_Add(m_OneUse(m_c_Add(and(XhYl), and(XlYh))), m_OneUse(m_LShr(XlYl)))
        for k in 2 {
            let inner = op(low, k);
            let other = op(low, 1 - k);
            if !(ai_one_use(inner) && ai_bo(inner, OP_ADD)) { continue; }
            var got = false;
            for j in 2 { if ou_and(op(inner, j), xhyl) && ou_and(op(inner, 1 - j), xlyh) { got = true; break; } }
            if !got { continue; }
            let l = ou_hi(other);
            if l >= 0 { xlyl = l; m = true; break; }
        }
        // m_c_Add(m_OneUse(m_c_Add(and(XhYl), m_OneUse(lshr(XlYl)))), m_OneUse(and(XlYh)))
        if !m {
            for k in 2 {
                let inner = op(low, k);
                let other = op(low, 1 - k);
                if !(ai_one_use(inner) && ai_bo(inner, OP_ADD)) { continue; }
                var got = false;
                for j in 2 {
                    if ou_and(op(inner, j), xhyl) {
                        let l = ou_hi(op(inner, 1 - j));
                        if l >= 0 { xlyl = l; got = true; break; }
                    }
                }
                if got && ou_and(other, xlyh) { m = true; break; }
            }
        }
        // m_c_Add(m_OneUse(m_c_Add(and(XlYh), m_OneUse(lshr(XlYl)))), m_OneUse(and(XhYl)))
        if !m {
            for k in 2 {
                let inner = op(low, k);
                let other = op(low, 1 - k);
                if !(ai_one_use(inner) && ai_bo(inner, OP_ADD)) { continue; }
                var got = false;
                for j in 2 {
                    if ou_and(op(inner, j), xlyh) {
                        let l = ou_hi(op(inner, 1 - j));
                        if l >= 0 { xlyl = l; got = true; break; }
                    }
                }
                if got && ou_and(other, xhyl) { m = true; break; }
            }
        }
    }
    if !m { return false; }
    if !mh_lolo(xlyl, x, y) { return false; }
    return mh_create(x, y);
}

// FoldMulHighCarry4
fn mh_carry4(x0: i32, y0: i32, carry0: i32, b0: i32, c0: i32) -> bool {
    var x = x0; var y = y0; var carry = carry0; var b = b0; var c = c0;
    if iop(carry) != OP_SELECT { let t = carry; carry = b; b = t; }
    if iop(carry) != OP_SELECT { let t = carry; carry = c; c = t; }
    let ok, cross, xhyl = mh_carry_select(carry);
    if !ok { return false; }
    fn is_cross_hi(v: i32) -> bool { ai_bo(v, OP_LSHR) && op(v, 0) == cross && ai_si(op(v, 1), mh_half()) }
    if !is_cross_hi(b) { let t = b; b = c; c = t; }
    if !is_cross_hi(b) { return false; }
    let low_acc = mh_hi(c);
    if low_acc < 0 { return false; }
    var xlyl: i32 = -1;
    var m = false;
    if ai_bo(low_acc, OP_ADD) {
        for k in 2 {
            let a = op(low_acc, k);
            let d = op(low_acc, 1 - k);
            if ai_one_use(a) {
                let l = mh_hi(a);
                if l >= 0 {
                    xlyl = l;
                    if ai_one_use(d) && ai_and_spec(d, cross, mh_low) { m = true; break; }
                }
            }
        }
    }
    if !m || ai_n_uses_or_more(low_acc, 3) { return false; }
    if !mh_lolo(xlyl, x, y) { return false; }
    if !mh_hilo(xhyl, x, y) { let t = x; x = y; y = t; }
    if !mh_hilo(xhyl, x, y) { return false; }
    var xlyh: i32 = -1;
    var mm = false;
    if ai_bo(cross, OP_ADD) {
        for k in 2 {
            if op(cross, k) != xhyl { continue; }
            let o = op(cross, 1 - k);
            if ai_one_use(o) { xlyh = o; mm = true; break; }
        }
    }
    if !mm || !mh_hilo(xlyh, y, x) || ai_n_uses_or_more(cross, 4) || ai_n_uses_or_more(xhyl, 3) { return false; }
    return mh_create(x, y);
}

// HiHi = m_OneUse(m_Mul(m_LShr(m_Value(X), half), m_LShr(m_Value(Y), half))): (ok, X, Y)
fn mh_hihi(v: i32) -> bool, i32, i32 {
    if !(ai_one_use(v) && ai_bo(v, OP_MUL)) { return false, -1, -1; }
    let x = mh_hi(op(v, 0));
    if x < 0 { return false, -1, -1; }
    let y = mh_hi(op(v, 1));
    if y < 0 { return false, x, -1; }
    return true, x, y;
}

fn ai_fold_mul_high(i: i32) -> bool {
    let ty = vals[i].ty;
    if !ty_is_int(ty_scalar(ty)) { return false; }
    let bw = ty_bits(ty_scalar(ty));
    if bw % 2 != 0 { return false; }
    mh_bw = bw;
    mh_low = ap_low_bits(bw, bw / 2);
    mh_i = i;
    if !ai_bo(i, OP_ADD) { return false; }
    var x: i32 = -1;
    var y: i32 = -1;
    var a: i32 = -1;
    var b: i32 = -1;
    var c: i32 = -1;
    // (1) m_c_Add(HiHi, m_OneUse(m_Add(m_Instruction(A), m_Instruction(B))))
    // (2) m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(HiHi, m_Instruction(B))))
    var m2 = false;
    for k in 2 {
        let h = op(i, k);
        let o = op(i, 1 - k);
        let ok, hx, hy = mh_hihi(h);
        if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
        if ok && ai_one_use(o) && ai_bo(o, OP_ADD) && is_inst(op(o, 0)) && is_inst(op(o, 1)) { a = op(o, 0); b = op(o, 1); m2 = true; break; }
    }
    if !m2 {
        for k in 2 {
            let ai = op(i, k);
            let o = op(i, 1 - k);
            if !is_inst(ai) { continue; }
            a = ai;
            if !(ai_one_use(o) && ai_bo(o, OP_ADD)) { continue; }
            for j in 2 {
                let ok, hx, hy = mh_hihi(op(o, j));
                if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
                if ok && is_inst(op(o, 1 - j)) { b = op(o, 1 - j); m2 = true; break; }
            }
            if m2 { break; }
        }
    }
    if m2 && ai_one_use(a) && ai_one_use(b) {
        if mh_carry(x, y, a, b) || mh_ladder(x, y, a, b) { return true; }
    }
    // the three-operand forms
    var m3 = false;
    fn add_ab(v: i32) -> bool { ai_one_use(v) && ai_bo(v, OP_ADD) && is_inst(op(v, 0)) && is_inst(op(v, 1)) }
    // (1) m_c_Add(HiHi, m_OneUse(m_c_Add(m_Instruction(A), m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))))
    for k in 2 {
        let ok, hx, hy = mh_hihi(op(i, k));
        if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
        if !ok { continue; }
        let o = op(i, 1 - k);
        if !(ai_one_use(o) && ai_bo(o, OP_ADD)) { continue; }
        for j in 2 {
            let ai = op(o, j);
            let r = op(o, 1 - j);
            if !is_inst(ai) { continue; }
            a = ai;
            if add_ab(r) { b = op(r, 0); c = op(r, 1); m3 = true; break; }
        }
        if m3 { break; }
    }
    // (2) m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(HiHi, m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))))
    if !m3 {
        for k in 2 {
            let ai = op(i, k);
            if !is_inst(ai) { continue; }
            a = ai;
            let o = op(i, 1 - k);
            if !(ai_one_use(o) && ai_bo(o, OP_ADD)) { continue; }
            for j in 2 {
                let ok, hx, hy = mh_hihi(op(o, j));
                if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
                if ok && add_ab(op(o, 1 - j)) { b = op(op(o, 1 - j), 0); c = op(op(o, 1 - j), 1); m3 = true; break; }
            }
            if m3 { break; }
        }
    }
    // (3) m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(m_Instruction(B), m_OneUse(m_c_Add(HiHi, m_Instruction(C))))))
    if !m3 {
        for k in 2 {
            let ai = op(i, k);
            if !is_inst(ai) { continue; }
            a = ai;
            let o = op(i, 1 - k);
            if !(ai_one_use(o) && ai_bo(o, OP_ADD)) { continue; }
            for j in 2 {
                let bi = op(o, j);
                if !is_inst(bi) { continue; }
                b = bi;
                let r = op(o, 1 - j);
                if !(ai_one_use(r) && ai_bo(r, OP_ADD)) { continue; }
                for l in 2 {
                    let ok, hx, hy = mh_hihi(op(r, l));
                    if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
                    if ok && is_inst(op(r, 1 - l)) { c = op(r, 1 - l); m3 = true; break; }
                }
                if m3 { break; }
            }
            if m3 { break; }
        }
    }
    // (4) m_c_Add(m_OneUse(m_c_Add(HiHi, m_Instruction(A))), m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))
    if !m3 {
        for k in 2 {
            let l1 = op(i, k);
            let r1 = op(i, 1 - k);
            if !(ai_one_use(l1) && ai_bo(l1, OP_ADD)) { continue; }
            var got = false;
            for j in 2 {
                let ok, hx, hy = mh_hihi(op(l1, j));
                if hx >= 0 { x = hx; } if hy >= 0 { y = hy; }
                if ok && is_inst(op(l1, 1 - j)) { a = op(l1, 1 - j); got = true; break; }
            }
            if got && add_ab(r1) { b = op(r1, 0); c = op(r1, 1); m3 = true; break; }
        }
    }
    if m3 && ai_one_use(a) && ai_one_use(b) && ai_one_use(c) {
        return mh_carry4(x, y, a, b, c) || mh_ladder4(x, y, a, b, c);
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// SimplifyInstructionsInBlock(BB) without a TargetLibraryInfo

fn ai_trivially_dead(i: i32) -> bool {
    local_have_tli = false;
    let r = is_instruction_trivially_dead(i);
    local_have_tli = true;
    return r;
}
fn ai_wl_insert(wl: i32[>..<]&, i: i32) { for x in wl { if x == i { return; } } wl.push(i); }
fn ai_simplify_and_dce(i: i32, wl: i32[>..<]&) -> bool {
    if ai_trivially_dead(i) {
        salvage_debug_info(i);
        for k in nops(i) {
            let o = op(i, k);
            set_op(i, k, -1);
            if o < 0 { continue; }
            if (!is_constant_data(o) && vals[o].first_use >= 0) || i == o { continue; }
            if is_constant_data(o) { continue; }
            if is_inst(o) && ai_trivially_dead(o) { ai_wl_insert(wl, o); }
        }
        inst_erase_from_parent(i);
        return true;
    }
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    let sc = kb_cxt;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let sv = simplify_instruction(i);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
    if sv >= 0 {
        var u = vals[i].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if us != i { ai_wl_insert(wl, us); }
            u = uses[u].next;
        }
        var changed = false;
        if vals[i].first_use >= 0 { rauw(i, sv); changed = true; }
        if ai_trivially_dead(i) { inst_erase_from_parent(i); changed = true; }
        return changed;
    }
    return false;
}
fn ai_simplify_instructions_in_block(bb: i32) -> bool {
    var changed = false;
    var wl: i32[>..<] = [];
    var bi = block_first(bb);
    let term = block_last(bb);
    while bi >= 0 && bi != term {
        let i = bi;
        bi = inst_next(bi);
        var inl = false;
        for x in wl { if x == i { inl = true; } }
        if !inl { changed = ai_simplify_and_dce(i, wl) || changed; }
    }
    while wl.len > 0 {
        let i = wl.pop();
        changed = ai_simplify_and_dce(i, wl) || changed;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Driver

// foldUnusualPatterns
fn ai_fold_unusual_patterns(fv: i32) -> bool {
    var changed = false;
    var bb = func_entry(fv);
    while bb >= 0 {
        if dt_has_node(DT_DOM, bb) {
            // make_early_inc_range(reverse(BB))
            var i = block_last(bb);
            while i >= 0 {
                let cur = i;
                i = inst_prev(i);
                if ai_fold_any_or_all_bits_set(cur) { changed = true; }
                if ai_fold_guarded_funnel_shift(cur) { changed = true; }
                if ai_fold_select_split_ctlz_cttz(cur) { changed = true; }
                if ai_try_popcount(cur) { changed = true; }
                if ai_try_popcount1(cur) { changed = true; }
                if ai_try_popcount2n3(cur) { changed = true; }
                if ai_try_fptosat(cur) { changed = true; }
                if ai_table_cttz_or_log2(cur) { changed = true; }
                if ai_fold_consecutive_loads(cur) { changed = true; }
                if ai_fold_patterned_loads(cur) { changed = true; }
                if ai_fold_icmp_or_chain(cur) { changed = true; }
                if ai_fold_mul_high(cur) { changed = true; }
                if ai_fold_lib_calls(cur) { changed = true; }
            }
            if ai_fold_consecutive_stores(bb) { changed = true; }
        }
        bb = block_next(bb);
    }
    if changed {
        var b2 = func_entry(fv);
        while b2 >= 0 { ai_simplify_instructions_in_block(b2); b2 = block_next(b2); }
    }
    return changed;
}

fn aggressive_instcombine_run(fv: i32) -> u32 {
    ai_fv = fv;
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    ai_tti_done = false;
    aa_begin(fv);
    ai_cfg_change = false;
    var changed = tc_run(fv);
    if ai_fold_unusual_patterns(fv) { changed = true; }
    if !changed { return PA_ALL; }
    if ai_cfg_change { return (1 as u32) << (A_DOMTREE as u32); }
    return PA_CFG;
}
