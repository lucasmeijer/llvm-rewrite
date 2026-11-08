// InstSimplify: port of llvm/lib/Analysis/InstructionSimplify.cpp (simplifyInstruction and the per-opcode
// simplify* entry points) and llvm/lib/Transforms/Scalar/InstSimplifyPass.cpp (the instsimplify pass).
//
// Reusable API (all return a value id, or -1 for "no simplification"):
//   simplify_instruction(iv)                         simplifyInstruction(I, SQ) with SQ = {DL, TLI, DT, AC}
//   simplify_inst_with_ops(iv, mark, n, q, mr)       simplifyInstructionWithOperands; operands on is_ops
//   simplify_binop(opc, a, b, q, mr) / simplify_binop_fmf(opc, a, b, fmf, q, mr)
//   simplify_add/sub/mul/sdiv/udiv/srem/urem/shl/lshr/ashr/and/or/xor(...)
//   simplify_icmp(pred, a, b, q, mr), simplify_fcmp(pred, a, b, fmf, q, mr), simplify_cmp(...)
//   simplify_select(c, t, f, fmf, q, mr), simplify_cast(opc, v, ty, q, mr), simplify_gep(...)
//   simplify_freeze(v, q), simplify_extract/insert*(...), simplify_phi(iv, q)
// The SimplifyQuery is SQ { cxt, undef } (context instruction, CanUseUndef); DT/TLI/AC are global
// (dt_get, tli_cur_fn, assumptions fail loudly in vt.goose). RecursionLimit = 3 as in LLVM.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import domtree;
import knownbits;
import implied;
import crange;
import pm;
import printer;
import vt;
import poison;
import constfold;
import cfold;
import fpclass;
import local;
import tli;
import assume;
import mem2reg;
import salvage;

let RECURSION_LIMIT = 3;

struct SQ { cxt: i32, undef: bool }

fn sq_new(cxt: i32) -> SQ { SQ { cxt: cxt, undef: true } }
fn sq_without_undef(q: SQ) -> SQ { SQ { cxt: q.cxt, undef: false } }
fn sq_with_inst(q: SQ, i: i32) -> SQ { SQ { cxt: i, undef: q.undef } }
fn q_undef(q: SQ, v: i32) -> bool { q.undef && m_undef(v) }

fn is_not_ported(what: const u8[:]) { fatal(str("InstSimplify: ", what, " is not ported yet")); }

// Operand stack for simplifyInstructionWithOperands (recursion keeps marks)
var is_ops: i32[>..<];

// ValueTracking with the query's context
fn q_kb(v: i32, q: SQ) -> KB { kb_cxt = q.cxt; return kb_compute_all(v, 0); }
fn q_nonzero(v: i32, q: SQ) -> bool { kb_cxt = q.cxt; return is_known_non_zero(v, 0); }
fn q_pow2(v: i32, or_zero: bool, q: SQ) -> bool { kb_cxt = q.cxt; return is_known_pow2(v, or_zero, 0); }
fn q_nonequal(a: i32, b: i32, q: SQ) -> bool { kb_cxt = q.cxt; return is_known_non_equal(a, b, 0); }
fn q_signbits(v: i32, q: SQ) -> i64 { kb_cxt = q.cxt; return num_sign_bits(v, 0); }
fn q_masked_zero(v: i32, m: AP, q: SQ) -> bool { kb_cxt = q.cxt; return masked_value_is_zero(v, m, 0); }
fn q_dom_implied(p: i64, a: i32, b: i32, q: SQ) -> i64 { return implied_by_dom_condition(p, a, b, q.cxt); }
fn q_fpclass(v: i32, interested: u64, fmf: u8, q: SQ) -> KFC { kb_cxt = q.cxt; return known_fp_class(v, interested, fmf, 0); }

fn null_of(v: i32) -> i32 { c_null(vals[v].ty) }
fn is_select(v: i32) -> bool { is_inst_op(v, OP_SELECT) }
fn is_phi_v(v: i32) -> bool { is_inst_op(v, OP_PHI) }
fn binop_inst(v: i32, o: i64) -> bool { is_inst_op(v, o) }
fn is_commutative(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
fn is_associative(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR }

// ---------------------------------------------------------------------------------------------
// Helpers shared by the folds

fn is_same_compare(v: i32, p: i64, l: i32, r: i32) -> bool {
    if !is_inst(v) || (iop(v) != OP_ICMP && iop(v) != OP_FCMP) { return false; }
    let cp = inst_pred(v);
    let cl = op(v, 0);
    let cr = op(v, 1);
    if cp == p && cl == l && cr == r { return true; }
    return cp == pred_swap_any(p) && cl == r && cr == l;
}
// CmpInst::getSwappedPredicate for icmp and fcmp
fn pred_swap_any(p: i64) -> i64 {
    if p >= 32 { return pred_swapped(p); }
    return match p { 2 => 4, 3 => 5, 4 => 2, 5 => 3, 10 => 12, 11 => 13, 12 => 10, 13 => 11, _ => p };
}
fn pred_inverse_any(p: i64) -> i64 {
    if p >= 32 { return pred_inverse(p); }
    return 15 - p;
}
fn fpred_is_ordered(p: i64) -> bool { p >= 1 && p <= 7 }
fn fpred_is_unordered(p: i64) -> bool { p >= 8 && p <= 14 }
// CmpInst::isTrueWhenEqual / isFalseWhenEqual
fn pred_true_when_eq(p: i64) -> bool {
    if p >= 32 { return p == P_EQ || p == P_UGE || p == P_ULE || p == P_SGE || p == P_SLE; }
    return p == 15 || p == 9 || p == 11 || p == 13;
}
fn pred_false_when_eq(p: i64) -> bool {
    if p >= 32 { return p == P_NE || p == P_UGT || p == P_ULT || p == P_SGT || p == P_SLT; }
    return p == 0 || p == 6 || p == 2 || p == 4;
}
fn pred_is_equality(p: i64) -> bool { p == P_EQ || p == P_NE }
fn pred_unsigned(p: i64) -> i64 { if pred_is_signed(p) { p - 4 } else { p } }
fn pred_signed(p: i64) -> i64 { if pred_is_unsigned(p) { p + 4 } else { p } }
fn pred_strict(p: i64) -> i64 { match p { 35 => 34, 37 => 36, 39 => 38, 41 => 40, _ => p } }
fn pred_nonstrict(p: i64) -> i64 { match p { 34 => 35, 36 => 37, 38 => 39, 40 => 41, _ => p } }
fn pred_relational(p: i64) -> bool { p >= 34 && p <= 41 }

// ICmpInst::compare(a, b, pred) for w <= 64
fn icmp_compare(a: u64, b: u64, p: i64, w: i64) -> bool {
    let sa = sext64(a, w);
    let sb = sext64(b, w);
    return match p {
        32 => a == b, 33 => a != b, 34 => a > b, 35 => a >= b, 36 => a < b, 37 => a <= b,
        38 => sa > sb, 39 => sa >= sb, 40 => sa < sb, _ => sa <= sb,
    };
}

// ---------------------------------------------------------------------------------------------
// Compare/select threading

recursive fn simplify_cmp_sel_case(p: i64, l: i32, r: i32, cond: i32, q: SQ, mr: i64, tf: i32) -> i32 {
    let s = simplify_cmp(p, l, r, q, mr);
    if s == cond { return tf; }
    if s < 0 && is_same_compare(cond, p, l, r) { return tf; }
    return s;
}

recursive fn handle_other_cmp_sel(tcmp: i32, fcmp: i32, cond: i32, q: SQ, mr: i64) -> i32 {
    if m_zero(fcmp) && implies_poison(tcmp, cond) {
        let v = simplify_and(cond, tcmp, q, mr);
        if v >= 0 { return v; }
    }
    if m_one(tcmp) && implies_poison(fcmp, cond) {
        let v = simplify_or(cond, fcmp, q, mr);
        if v >= 0 { return v; }
    }
    if m_one(fcmp) && m_zero(tcmp) {
        let v = simplify_xor(cond, c_all_ones(vals[cond].ty), q, mr);
        if v >= 0 { return v; }
    }
    return -1;
}

fn value_dominates_phi(v: i32, p: i32) -> bool {
    if !is_inst(v) { return true; }
    if sq_no_dt {
        let b = inst_parent(v);
        return b == func_entry(inst_func(v)) && iop(v) != OP_INVOKE && iop(v) != OP_CALLBR;
    }
    return dom_inst(v, p);
}

recursive fn expand_binop(o: i64, v: i32, other: i32, oexp: i64, q: SQ, mr: i64) -> i32 {
    if !binop_inst(v, oexp) { return -1; }
    let b0 = op(v, 0);
    let b1 = op(v, 1);
    let l = simplify_binop(o, b0, other, sq_without_undef(q), mr);
    if l < 0 { return -1; }
    let r = simplify_binop(o, b1, other, sq_without_undef(q), mr);
    if r < 0 { return -1; }
    if (l == b0 && r == b1) || (is_commutative(oexp) && l == b1 && r == b0) { return v; }
    let s = simplify_binop(oexp, l, r, q, mr);
    if s < 0 { return -1; }
    return s;
}

recursive fn expand_commutative_binop(o: i64, l: i32, r: i32, oexp: i64, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    let v = expand_binop(o, l, r, oexp, q, mr);
    if v >= 0 { return v; }
    let w = expand_binop(o, r, l, oexp, q, mr);
    if w >= 0 { return w; }
    return -1;
}

recursive fn simplify_associative_binop(o: i64, lhs: i32, rhs: i32, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    let op0 = binop_inst(lhs, o);
    let op1 = binop_inst(rhs, o);
    if op0 {
        let a = op(lhs, 0);
        let b = op(lhs, 1);
        let c = rhs;
        let v = simplify_binop(o, b, c, q, mr);
        if v >= 0 {
            if v == b { return lhs; }
            let w = simplify_binop(o, a, v, q, mr);
            if w >= 0 { return w; }
        }
    }
    if op1 {
        let a = lhs;
        let b = op(rhs, 0);
        let c = op(rhs, 1);
        let v = simplify_binop(o, a, b, q, mr);
        if v >= 0 {
            if v == b { return rhs; }
            let w = simplify_binop(o, v, c, q, mr);
            if w >= 0 { return w; }
        }
    }
    if !is_commutative(o) { return -1; }
    if op0 {
        let a = op(lhs, 0);
        let b = op(lhs, 1);
        let c = rhs;
        let v = simplify_binop(o, c, a, q, mr);
        if v >= 0 {
            if v == a { return lhs; }
            let w = simplify_binop(o, v, b, q, mr);
            if w >= 0 { return w; }
        }
    }
    if op1 {
        let a = lhs;
        let b = op(rhs, 0);
        let c = op(rhs, 1);
        let v = simplify_binop(o, c, a, q, mr);
        if v >= 0 {
            if v == c { return rhs; }
            let w = simplify_binop(o, b, v, q, mr);
            if w >= 0 { return w; }
        }
    }
    return -1;
}

recursive fn thread_binop_over_select(o: i64, lhs: i32, rhs: i32, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    let si = if is_select(lhs) { lhs } else { rhs };
    var tv: i32 = -1;
    var fv: i32 = -1;
    if si == lhs {
        tv = simplify_binop(o, op(si, 1), rhs, q, mr);
        fv = simplify_binop(o, op(si, 2), rhs, q, mr);
    } else {
        tv = simplify_binop(o, lhs, op(si, 1), q, mr);
        fv = simplify_binop(o, lhs, op(si, 2), q, mr);
    }
    if tv == fv { return tv; }
    if tv >= 0 && q_undef(q, tv) { return fv; }
    if fv >= 0 && q_undef(q, fv) { return tv; }
    if tv == op(si, 1) && fv == op(si, 2) { return si; }
    if (fv >= 0 && tv < 0) || (tv >= 0 && fv < 0) {
        let simp = if fv >= 0 { fv } else { tv };
        if is_inst(simp) && iop(simp) == o && !has_poison_generating_flags(simp) {
            let ub = if fv >= 0 { op(si, 1) } else { op(si, 2) };
            let ul = if si == lhs { ub } else { lhs };
            let ur = if si == lhs { rhs } else { ub };
            if op(simp, 0) == ul && op(simp, 1) == ur { return simp; }
            if is_commutative(o) && op(simp, 1) == ul && op(simp, 0) == ur { return simp; }
        }
    }
    return -1;
}

recursive fn thread_cmp_over_select(p0: i64, l0: i32, r0: i32, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    var p = p0;
    var l = l0;
    var r = r0;
    if !is_select(l) { let t = l; l = r; r = t; p = pred_swap_any(p); }
    let cond = op(l, 0);
    let tv = op(l, 1);
    let fv = op(l, 2);
    let tc = simplify_cmp_sel_case(p, tv, r, cond, q, mr, get_true(vals[cond].ty));
    if tc < 0 { return -1; }
    let fc = simplify_cmp_sel_case(p, fv, r, cond, q, mr, get_false(vals[cond].ty));
    if fc < 0 { return -1; }
    if tc == fc { return tc; }
    if ty_is_vector(vals[cond].ty) == ty_is_vector(vals[r].ty) { return handle_other_cmp_sel(tc, fc, cond, q, mr); }
    return -1;
}

recursive fn thread_binop_over_phi(o: i64, lhs: i32, rhs: i32, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    var pi: i32 = -1;
    if is_phi_v(lhs) {
        pi = lhs;
        if !value_dominates_phi(rhs, pi) { return -1; }
    } else {
        pi = rhs;
        if !value_dominates_phi(lhs, pi) { return -1; }
    }
    var common: i32 = -1;
    for k in nops(pi) {
        let inc = op(pi, k);
        if inc == pi { continue; }
        let ti = block_terminator(phi_block(pi, k));
        let v = if pi == lhs { simplify_binop(o, inc, rhs, sq_with_inst(q, ti), mr) } else { simplify_binop(o, lhs, inc, sq_with_inst(q, ti), mr) };
        if v < 0 || (common >= 0 && v != common) { return -1; }
        common = v;
    }
    return common;
}

recursive fn thread_cmp_over_phi(p0: i64, l0: i32, r0: i32, q: SQ, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    var p = p0;
    var l = l0;
    var r = r0;
    if !is_phi_v(l) { let t = l; l = r; r = t; p = pred_swap_any(p); }
    let pi = l;
    if !value_dominates_phi(r, pi) { return -1; }
    var common: i32 = -1;
    for k in nops(pi) {
        let inc = op(pi, k);
        let ti = block_terminator(phi_block(pi, k));
        if inc == pi { continue; }
        let v = simplify_cmp(p, inc, r, sq_with_inst(q, ti), mr);
        if v < 0 || (common >= 0 && v != common) { return -1; }
        common = v;
    }
    return common;
}

// foldOrCommuteConstant: returns the folded constant (or -1) and possibly swapped operands
recursive fn fold_or_commute_constant(o: i64, a: i32, b: i32, q: SQ) -> i32, i32, i32 {
    if is_constant(a) {
        if is_constant(b) {
            if o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM {
                if q.cxt >= 0 { return cf_fold_fp_inst_operands(o, a, b, q.cxt, true), a, b; }
            }
            return cf_fold_binop_operands(o, a, b), a, b;
        }
        if is_commutative(o) { return -1, b, a; }
    }
    return -1, a, b;
}

// ---------------------------------------------------------------------------------------------
// Add / Sub / Mul

recursive fn simplify_add(a0: i32, b0: i32, nsw: bool, nuw: bool, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_ADD, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(b) { return b; }
    if q_undef(q, b) { return b; }
    if m_zero(b) { return a; }
    if is_known_negation(a, b, false, true) { return null_of(a); }
    if is_op(b, OP_SUB) && op(b, 1) == a { return op(b, 0); }
    if is_op(a, OP_SUB) && op(a, 1) == b { return op(a, 0); }
    let ty = vals[a].ty;
    if m_not_of(a, b) || m_not_of(b, a) { return c_all_ones(ty); }
    if (nsw || nuw) && m_sign_mask(b) && is_op(a, OP_XOR) && m_sign_mask(op(a, 1)) { return op(a, 0); }
    if nuw && m_all_ones(b) { return b; }
    if mr > 0 && is_int_or_int_vec_w(ty, 1) {
        let v = simplify_xor(a, b, q, mr - 1);
        if v >= 0 { return v; }
    }
    let v = simplify_associative_binop(OP_ADD, a, b, q, mr);
    if v >= 0 { return v; }
    return -1;
}

// stripAndComputeConstantOffsets + computePointerDifference
fn compute_pointer_difference(l: i32, r: i32) -> i32 {
    let lb = strip_and_accumulate_offsets(l, true, false, false);
    let lo = vt_off;
    let rb = strip_and_accumulate_offsets(r, true, false, false);
    let ro = vt_off;
    if lb != rb { return -1; }
    let iw = dl_ptr(ptr_as(vals[lb].ty)).idx;
    let res = c_int_words(ty_int(iw), ((lo - ro) as! u64) & wmask64(iw), 0);
    if ty_is_vector(vals[lb].ty) { return c_splat(ty_vector(ty_int(iw), ty_count(vals[lb].ty), ty_kind(vals[lb].ty) == TK_SVEC), res); }
    return res;
}

recursive fn simplify_by_dom_eq(o: i64, a: i32, b: i32, q: SQ, mr: i64) -> i32 {
    if mr != RECURSION_LIMIT { return -1; }
    let imp = q_dom_implied(P_EQ, a, b, q);
    if imp == 1 {
        let ty = vals[a].ty;
        if o == OP_SUB || o == OP_XOR || o == OP_UREM || o == OP_SREM { return c_null(ty); }
        if o == OP_SDIV || o == OP_UDIV { return c_int_ty(ty, 1); }
        if o == OP_AND || o == OP_OR { return b; }
    }
    return -1;
}

recursive fn simplify_sub(a0: i32, b0: i32, nsw: bool, nuw: bool, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_SUB, a0, b0, q);
    if c >= 0 { return c; }
    let ty = vals[a].ty;
    if is_poison(a) || is_poison(b) { return c_poison(ty); }
    if q_undef(q, a) || q_undef(q, b) { return c_undef(ty); }
    if m_zero(b) { return a; }
    if a == b { return c_null(ty); }
    if m_zero(a) {
        if nuw { return c_null(ty); }
        let k = q_kb(b, q);
        if ap_is_max_signed(k.z) {
            if nsw { return c_null(ty); }
            return b;
        }
    }
    if mr > 0 && is_op(a, OP_ADD) {
        let x = op(a, 0);
        let y = op(a, 1);
        let z = b;
        let v = simplify_binop(OP_SUB, y, z, q, mr - 1);
        if v >= 0 { let w = simplify_binop(OP_ADD, x, v, q, mr - 1); if w >= 0 { return w; } }
        let v2 = simplify_binop(OP_SUB, x, z, q, mr - 1);
        if v2 >= 0 { let w = simplify_binop(OP_ADD, y, v2, q, mr - 1); if w >= 0 { return w; } }
    }
    if mr > 0 && is_op(b, OP_ADD) {
        let x = a;
        let y = op(b, 0);
        let z = op(b, 1);
        let v = simplify_binop(OP_SUB, x, y, q, mr - 1);
        if v >= 0 { let w = simplify_binop(OP_SUB, v, z, q, mr - 1); if w >= 0 { return w; } }
        let v2 = simplify_binop(OP_SUB, x, z, q, mr - 1);
        if v2 >= 0 { let w = simplify_binop(OP_SUB, v2, y, q, mr - 1); if w >= 0 { return w; } }
    }
    if mr > 0 && is_op(b, OP_SUB) {
        let z = a;
        let x = op(b, 0);
        let y = op(b, 1);
        let v = simplify_binop(OP_SUB, z, x, q, mr - 1);
        if v >= 0 { let w = simplify_binop(OP_ADD, v, y, q, mr - 1); if w >= 0 { return w; } }
    }
    if mr > 0 && is_op(a, OP_TRUNC) && is_op(b, OP_TRUNC) {
        let x = op(a, 0);
        let y = op(b, 0);
        if vals[x].ty == vals[y].ty {
            let v = simplify_binop(OP_SUB, x, y, q, mr - 1);
            if v >= 0 {
                let w = simplify_cast(OP_TRUNC, v, vals[a].ty, q, mr - 1);
                if w >= 0 { return w; }
            }
        }
    }
    let px = m_ptrtoint_or_addr(a);
    let py = m_ptrtoint_or_addr(b);
    if px >= 0 && py >= 0 {
        let r = compute_pointer_difference(px, py);
        if r >= 0 { return cf_fold_integer_cast(r, vals[a].ty, true); }
    }
    if mr > 0 && is_int_or_int_vec_w(ty, 1) {
        let v = simplify_xor(a, b, q, mr - 1);
        if v >= 0 { return v; }
    }
    let d = simplify_by_dom_eq(OP_SUB, a, b, q, mr);
    if d >= 0 { return d; }
    if nuw {
        if is_op(b, OP_XOR) {
            var x: i32 = -1;
            if op(b, 1) == a { x = op(b, 0); } else if op(b, 0) == a { x = op(b, 1); }
            if x >= 0 && m_low_bit_mask(a) { return x; }
        }
    }
    return -1;
}

recursive fn simplify_mul(a0: i32, b0: i32, nsw: bool, nuw: bool, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_MUL, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(b) { return b; }
    let ty = vals[a].ty;
    if q_undef(q, b) || m_zero(b) { return c_null(ty); }
    if m_one(b) { return a; }
    fn exact_idiv_of(v: i32, y: i32) -> i32 {
        if (is_op(v, OP_SDIV) || is_op(v, OP_UDIV)) && op_exact(v) && op(v, 1) == y { return op(v, 0); }
        return -1;
    }
    let x1 = exact_idiv_of(a, b);
    if x1 >= 0 { return x1; }
    let x2 = exact_idiv_of(b, a);
    if x2 >= 0 { return x2; }
    if is_int_or_int_vec_w(ty, 1) {
        if nsw { return c_null(ty); }
        if mr > 0 {
            let v = simplify_and(a, b, q, mr - 1);
            if v >= 0 { return v; }
        }
    }
    let v = simplify_associative_binop(OP_MUL, a, b, q, mr);
    if v >= 0 { return v; }
    let e = expand_commutative_binop(OP_MUL, a, b, OP_ADD, q, mr);
    if e >= 0 { return e; }
    if is_select(a) || is_select(b) {
        let s = thread_binop_over_select(OP_MUL, a, b, q, mr);
        if s >= 0 { return s; }
    }
    if is_phi_v(a) || is_phi_v(b) {
        let p = thread_binop_over_phi(OP_MUL, a, b, q, mr);
        if p >= 0 { return p; }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Div / Rem

recursive fn is_icmp_true(p: i64, l: i32, r: i32, q: SQ, mr: i64) -> bool {
    let v = simplify_icmp(p, l, r, q, mr);
    return v >= 0 && is_constant(v) && is_all_ones_value(v);
}

recursive fn is_div_zero(x: i32, y: i32, q: SQ, mr0: i64, signed: bool) -> bool {
    if mr0 == 0 { return false; }
    let mr = mr0 - 1;
    let ty = vals[x].ty;
    if signed {
        if is_op(x, OP_SREM) && op(x, 1) == y { return true; }
        let c = m_apint(x);
        if c >= 0 && !ap_is_min_signed(ci_ap(c)) {
            let ab = ap_abs(ci_ap(c));
            let pos = c_int_ap(ty, ab);
            let neg = c_int_ap(ty, ap_neg(ab));
            if is_icmp_true(P_SLT, y, neg, q, mr) || is_icmp_true(P_SGT, y, pos, q, mr) { return true; }
        }
        let cy = m_apint(y);
        if cy >= 0 {
            if ap_is_min_signed(ci_ap(cy)) { return is_icmp_true(P_NE, x, y, q, mr); }
            let ab = ap_abs(ci_ap(cy));
            let pos = c_int_ap(ty, ab);
            let neg = c_int_ap(ty, ap_neg(ab));
            if is_icmp_true(P_SGT, x, neg, q, mr) && is_icmp_true(P_SLT, x, pos, q, mr) { return true; }
        }
        return false;
    }
    let c = m_apint(y);
    if c >= 0 && ap_ult(kb_max(q_kb(x, q)), ci_ap(c)) { return true; }
    return is_icmp_true(P_ULT, x, y, q, mr);
}

recursive fn simplify_div_rem(o: i64, a: i32, b: i32, q: SQ, mr: i64) -> i32 {
    let is_div = o == OP_SDIV || o == OP_UDIV;
    let signed = o == OP_SDIV || o == OP_SREM;
    let ty = vals[a].ty;
    if q_undef(q, b) || is_poison(b) { return c_poison(ty); }
    if m_zero(b) { return c_poison(ty); }
    if is_poison(a) { return a; }
    if q_undef(q, a) { return c_null(ty); }
    if m_zero(a) { return c_null(ty); }
    if a == b { return if is_div { c_int_ty(ty, 1) } else { c_null(ty) }; }
    let k = q_kb(b, q);
    if kb_is_constant(k) && ap_is_zero(k.o) { return c_poison(ty); }
    if kb_min_lz(k) == kb_bw(k) - 1 { return if is_div { a } else { c_null(ty) }; }
    let x = m_c_binop_with(a, OP_MUL, b);
    if x >= 0 {
        if (signed && op_nsw(a)) || (!signed && op_nuw(a)) || (signed && is_op(x, OP_SDIV) && op(x, 1) == b) ||
           (!signed && is_op(x, OP_UDIV) && op(x, 1) == b) {
            return if is_div { x } else { c_null(ty) };
        }
    }
    if is_div_zero(a, b, q, mr, signed) { return if is_div { c_null(ty) } else { a }; }
    let d = simplify_by_dom_eq(o, a, b, q, mr);
    if d >= 0 { return d; }
    if is_select(a) || is_select(b) {
        let s = thread_binop_over_select(o, a, b, q, mr);
        if s >= 0 { return s; }
    }
    if is_phi_v(a) || is_phi_v(b) {
        let p = thread_binop_over_phi(o, a, b, q, mr);
        if p >= 0 { return p; }
    }
    return -1;
}

recursive fn simplify_div(o: i64, a0: i32, b0: i32, exact: bool, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(o, a0, b0, q);
    if c >= 0 { return c; }
    let v = simplify_div_rem(o, a, b, q, mr);
    if v >= 0 { return v; }
    let dc = m_apint(b);
    if exact && dc >= 0 {
        let dv = ci_ap(dc);
        let tz = ap_countr_zero(dv);
        if tz != 0 {
            let k = q_kb(a, q);
            if kb_max_tz(k) < tz { return c_poison(vals[a].ty); }
        }
        let pow2 = ap_is_pow2(dv);
        if !pow2 {
            if o == OP_UDIV { if is_op(a, OP_MUL) && op_nsw(a) && op(a, 1) == b { return op(a, 0); } }
            else { if is_op(a, OP_MUL) && op_nuw(a) && op(a, 1) == b { return op(a, 0); } }
        }
    }
    return -1;
}

recursive fn simplify_rem(o: i64, a0: i32, b0: i32, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(o, a0, b0, q);
    if c >= 0 { return c; }
    let v = simplify_div_rem(o, a, b, q, mr);
    if v >= 0 { return v; }
    if (o == OP_SREM && is_op(a, OP_SHL) && op_nsw(a) && op(a, 0) == b) ||
       (o == OP_UREM && is_op(a, OP_SHL) && op_nuw(a) && op(a, 0) == b) { return null_of(a); }
    let c0 = m_apint(b);
    if c0 >= 0 {
        let w = ci_w(c0);
        let signed = o == OP_SREM;
        if is_op(a, OP_MUL) && (if signed { op_nsw(a) } else { op_nuw(a) }) {
            // m_CheckedInt: every (non-poison) element must satisfy C rem C0 == 0
            if checked_int_rem_zero(op(a, 1), c0, signed) { return null_of(a); }
        }
    }
    return -1;
}
fn rem_zero(c: i32, c0: i32, signed: bool) -> bool {
    let d = ci_ap(c0);
    if ap_is_zero(d) { is_not_ported("srem/urem of mul by a constant with a zero divisor"); }
    if signed { return ap_is_zero(ap_srem(ci_ap(c), d)); }
    return ap_is_zero(ap_urem(ci_ap(c), d));
}
// m_CheckedInt(pred) (cstval_pred_ty with a checked predicate): scalar, splat, or all fixed-vector elements
fn checked_int_rem_zero(v: i32, c0: i32, signed: bool) -> bool {
    if !is_constant(v) { return false; }
    let k = vals[v].kind;
    if k == VK_CINT { let s = if ty_is_vector(vals[v].ty) { splat_value(v, false) } else { v }; return rem_zero(s, c0, signed); }
    if !ty_is_vector(vals[v].ty) { return false; }
    let s = splat_value(v, false);
    if s >= 0 && vals[s].kind == VK_CINT { return rem_zero(s, c0, signed); }
    if ty_kind(vals[v].ty) != TK_FVEC { return false; }
    var has = false;
    for i in ty_count(vals[v].ty) {
        let e = agg_elem(v, i);
        if e < 0 { return false; }
        if vals[e].kind == VK_POISON { continue; }
        if vals[e].kind != VK_CINT || !rem_zero(e, c0, signed) { return false; }
        has = true;
    }
    return has;
}
fn rem_i64(a: i64, b: i64) -> i64 {
    // C-style remainder (sign of the dividend); handle INT64_MIN % -1
    if b == -1 { return 0; }
    let r = a % b;    // Euclidean in Goose
    if r != 0 && a < 0 { return r - (if b < 0 { -b } else { b }); }
    return r;
}

recursive fn simplify_sdiv(a: i32, b: i32, exact: bool, q: SQ, mr: i64) -> i32 {
    if is_known_negation(a, b, true, true) { return c_all_ones(vals[a].ty); }
    return simplify_div(OP_SDIV, a, b, exact, q, mr);
}
recursive fn simplify_udiv(a: i32, b: i32, exact: bool, q: SQ, mr: i64) -> i32 { simplify_div(OP_UDIV, a, b, exact, q, mr) }
recursive fn simplify_srem(a: i32, b: i32, q: SQ, mr: i64) -> i32 {
    if is_op(b, OP_SEXT) && is_int_or_int_vec_w(vals[op(b, 0)].ty, 1) { return null_of(a); }
    if is_known_negation(a, b, false, true) { return null_of(a); }
    return simplify_rem(OP_SREM, a, b, q, mr);
}
recursive fn simplify_urem(a: i32, b: i32, q: SQ, mr: i64) -> i32 { simplify_rem(OP_UREM, a, b, q, mr) }

// ---------------------------------------------------------------------------------------------
// Shifts

recursive fn is_poison_shift(amt: i32, q: SQ) -> bool {
    if !is_constant(amt) { return false; }
    if q_undef(q, amt) { return true; }
    let c = m_apint(amt);
    if c >= 0 && ap_uge_u64(ci_ap(c), ci_w(c) as u64) { return true; }
    let k = vals[amt].kind;
    if k == VK_CVECTOR || k == VK_CDVECTOR {
        for i in ty_count(vals[amt].ty) {
            if !is_poison_shift(agg_elem(amt, i), q) { return false; }
        }
        return true;
    }
    return false;
}

recursive fn simplify_shift(o: i64, a0: i32, b0: i32, nsw: bool, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(o, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(a) { return a; }
    if m_zero(a) { return null_of(a); }
    if m_zero(b) || (is_op(b, OP_SEXT) && is_int_or_int_vec_w(vals[op(b, 0)].ty, 1)) { return a; }
    if is_poison_shift(b, q) { return c_poison(vals[a].ty); }
    if is_select(a) || is_select(b) {
        let s = thread_binop_over_select(o, a, b, q, mr);
        if s >= 0 { return s; }
    }
    if is_phi_v(a) || is_phi_v(b) {
        let p = thread_binop_over_phi(o, a, b, q, mr);
        if p >= 0 { return p; }
    }
    let ka = q_kb(b, q);
    let w = kb_bw(ka);
    if ap_uge_u64(kb_min(ka), w as u64) { return c_poison(vals[a].ty); }
    let nvalid = if w <= 1 { 0 } else { 64 - clz((w - 1) as u64) };
    if kb_min_tz(ka) >= nvalid { return a; }
    if nsw {
        let kv = q_kb(a, q);
        var ks = kb_shl(kv, ka, false, false, false);
        let aw = kb_bw(kv);
        if ap_is_neg(kv.z) { ks.z = ap_set_bit(ks.z, aw - 1); }
        if ap_is_neg(kv.o) { ks.o = ap_set_bit(ks.o, aw - 1); }
        if kb_has_conflict(ks) { return c_poison(vals[a].ty); }
    }
    return -1;
}

recursive fn simplify_right_shift(o: i64, a: i32, b: i32, exact: bool, q: SQ, mr: i64) -> i32 {
    let v = simplify_shift(o, a, b, false, q, mr);
    if v >= 0 { return v; }
    if a == b { return null_of(a); }
    if q_undef(q, a) { return if exact { a } else { null_of(a) }; }
    if exact {
        let k = q_kb(a, q);
        if ap_get_bit(k.o, 0) { return a; }
    }
    return -1;
}

recursive fn simplify_shl(a: i32, b: i32, nsw: bool, nuw: bool, q: SQ, mr: i64) -> i32 {
    let v = simplify_shift(OP_SHL, a, b, nsw, q, mr);
    if v >= 0 { return v; }
    let ty = vals[a].ty;
    if q_undef(q, a) { return if nsw || nuw { a } else { c_null(ty) }; }
    if (is_op(a, OP_LSHR) || is_op(a, OP_ASHR)) && op_exact(a) && op(a, 1) == b { return op(a, 0); }
    if nuw && m_negative(a) { return a; }
    if nsw && nuw && m_specific_int(b, (ty_scalar_bits(ty) - 1) as u64) { return c_null(ty); }
    return -1;
}

recursive fn simplify_lshr(a: i32, b: i32, exact: bool, q: SQ, mr: i64) -> i32 {
    let v = simplify_right_shift(OP_LSHR, a, b, exact, q, mr);
    if v >= 0 { return v; }
    if is_op(a, OP_SHL) && op_nuw(a) && op(a, 1) == b { return op(a, 0); }
    let sr = m_apint(b);
    if sr >= 0 && is_op(a, OP_OR) {
        for side in 2 {
            let sh = op(a, side);
            let y = op(a, 1 - side);
            if is_op(sh, OP_SHL) && op_nuw(sh) && m_apint(op(sh, 1)) >= 0 {
                let sl = m_apint(op(sh, 1));
                if ap_eq(ci_ap(sl), ci_ap(sr)) {
                    let yk = q_kb(y, q);
                    let eff = kb_bw(yk) - kb_min_lz(yk);
                    if ap_uge_u64(ci_ap(sr), eff as u64) { return op(sh, 0); }
                }
                break;
            }
        }
    }
    return -1;
}

recursive fn simplify_ashr(a: i32, b: i32, exact: bool, q: SQ, mr: i64) -> i32 {
    let v = simplify_right_shift(OP_ASHR, a, b, exact, q, mr);
    if v >= 0 { return v; }
    if m_all_ones(a) || (is_op(a, OP_SHL) && m_all_ones(op(a, 0)) && op(a, 1) == b) { return c_all_ones(vals[a].ty); }
    if is_op(a, OP_SHL) && op_nsw(a) && op(a, 1) == b { return op(a, 0); }
    let nsb = q_signbits(a, q);
    if nsb == ty_scalar_bits(vals[a].ty) { return a; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// And / Or / Xor helpers on compares

fn icmp_parts(v: i32) -> bool { is_inst_op(v, OP_ICMP) }

recursive fn simplify_unsigned_range_check(zc: i32, uc: i32, is_and: bool, q: SQ) -> i32 {
    if !icmp_parts(zc) || !m_zero(op(zc, 1)) { return -1; }
    let eqp = inst_pred(zc);
    if !pred_is_equality(eqp) { return -1; }
    let y = op(zc, 0);
    if !icmp_parts(uc) { return -1; }
    if is_op(y, OP_SUB) {
        let a = op(y, 0);
        let b = op(y, 1);
        // m_c_ICmp(UnsignedPred, m_Specific(A), m_Specific(B))
        var up = inst_pred(uc);
        var matched = false;
        if op(uc, 0) == a && op(uc, 1) == b { matched = true; }
        else if op(uc, 0) == b && op(uc, 1) == a { matched = true; up = pred_swapped(up); }
        if matched && pred_is_unsigned(up) {
            if (up == P_UGE || up == P_ULE) && eqp == P_NE && !is_and { return get_true(vals[uc].ty); }
            if (up == P_ULT || up == P_UGT) && eqp == P_EQ && is_and { return get_false(vals[uc].ty); }
            if eqp == P_NE && (up == P_ULT || up == P_UGT) { return if is_and { uc } else { zc }; }
            if eqp == P_EQ && (up == P_ULE || up == P_UGE) { return if is_and { zc } else { uc }; }
        }
        // m_c_ICmp(UnsignedPred, m_Specific(Y), m_Specific(A))
        var up2 = inst_pred(uc);
        var m2 = false;
        if op(uc, 0) == y && op(uc, 1) == a { m2 = true; }
        else if op(uc, 0) == a && op(uc, 1) == y { m2 = true; up2 = pred_swapped(up2); }
        if m2 {
            if up2 == P_UGE && is_and && eqp == P_NE && q_nonzero(b, q) { return uc; }
            if up2 == P_ULT && !is_and && eqp == P_EQ && q_nonzero(b, q) { return uc; }
        }
    }
    var up = inst_pred(uc);
    var x: i32 = -1;
    if op(uc, 1) == y && pred_is_unsigned(up) { x = op(uc, 0); }
    else if op(uc, 0) == y && pred_is_unsigned(up) { x = op(uc, 1); up = pred_swapped(up); }
    else { return -1; }
    if up == P_UGT && eqp == P_EQ && q_nonzero(x, q) { return if is_and { zc } else { uc }; }
    if up == P_ULE && eqp == P_NE && q_nonzero(x, q) { return if is_and { uc } else { zc }; }
    if up == P_ULT && eqp == P_NE { return if is_and { uc } else { zc }; }
    if up == P_UGE && eqp == P_EQ { return if is_and { zc } else { uc }; }
    if up == P_ULT && eqp == P_EQ && is_and { return get_false(vals[uc].ty); }
    if up == P_UGE && eqp == P_NE && !is_and { return get_true(vals[uc].ty); }
    return -1;
}

fn simplify_and_or_of_icmps_with_constants(c0: i32, c1: i32, is_and: bool) -> i32 {
    if op(c0, 0) != op(c1, 0) { return -1; }
    let k0 = m_apint(op(c0, 1));
    let k1 = m_apint(op(c1, 1));
    if k0 < 0 || k1 < 0 { return -1; }
    let r0 = rg_exact_icmp(inst_pred(c0), ci_ap(k0));
    let r1 = rg_exact_icmp(inst_pred(c1), ci_ap(k1));
    if is_and && rg_is_empty(rg_intersect(r0, r1)) { return get_false(vals[c0].ty); }
    if !is_and && rg_is_full(rg_union(r0, r1)) { return get_true(vals[c0].ty); }
    if rg_contains(r0, r1) { return if is_and { c1 } else { c0 }; }
    if rg_contains(r1, r0) { return if is_and { c0 } else { c1 }; }
    return -1;
}

fn simplify_and_or_of_icmps_with_add(o0: i32, o1: i32, is_and: bool) -> i32 {
    let l = op(o0, 0);
    if !is_op(l, OP_ADD) { return -1; }
    let c0 = m_apint(op(l, 1));
    let c1 = m_apint(op(o0, 1));
    if c0 < 0 || c1 < 0 { return -1; }
    let v = op(l, 0);
    if op(o1, 0) != v { return -1; }
    if op(l, 1) != op(o1, 1) { return -1; }
    let ity = vals[o0].ty;
    let nsw = op_nsw(l);
    let nuw = op_nuw(l);
    let dap = ap_sub(ci_ap(c1), ci_ap(c0));
    let delta: u64 = if ap_eq_u64(dap, 1) { 1 } else if ap_eq_u64(dap, 2) { 2 } else { 0 };
    let p0 = inst_pred(o0);
    let p1 = inst_pred(o1);
    let c0a = ci_ap(c0);
    let c0nz = !ap_is_zero(c0a);
    let strictly_pos = ap_is_strictly_pos(c0a);
    if is_and {
        if strictly_pos {
            if delta == 2 {
                if p0 == P_ULT && p1 == P_SGT { return get_false(ity); }
                if p0 == P_SLT && p1 == P_SGT && nsw { return get_false(ity); }
            }
            if delta == 1 {
                if p0 == P_ULE && p1 == P_SGT { return get_false(ity); }
                if p0 == P_SLE && p1 == P_SGT && nsw { return get_false(ity); }
            }
        }
        if c0nz && nuw {
            if delta == 2 { if p0 == P_ULT && p1 == P_UGT { return get_false(ity); } }
            if delta == 1 { if p0 == P_ULE && p1 == P_UGT { return get_false(ity); } }
        }
    } else {
        if strictly_pos {
            if delta == 2 {
                if p0 == P_UGE && p1 == P_SLE { return get_true(ity); }
                if p0 == P_SGE && p1 == P_SLE && nsw { return get_true(ity); }
            }
            if delta == 1 {
                if p0 == P_UGT && p1 == P_SLE { return get_true(ity); }
                if p0 == P_SGT && p1 == P_SLE && nsw { return get_true(ity); }
            }
        }
        if c0nz && nuw {
            if delta == 2 { if p0 == P_UGE && p1 == P_ULE { return get_true(ity); } }
            if delta == 1 { if p0 == P_UGT && p1 == P_ULE { return get_true(ity); } }
        }
    }
    return -1;
}

fn simplify_and_or_of_icmps_with_ctpop(c0: i32, c1: i32, is_and: bool) -> i32 {
    let l = op(c0, 0);
    if !m_intrinsic(l, IID_ctpop) { return -1; }
    let c = m_apint(op(c0, 1));
    if c < 0 { return -1; }
    let x = op(l, 0);
    if op(c1, 0) != x || !m_zero_int(op(c1, 1)) || ap_is_zero(ci_ap(c)) { return -1; }
    let p0 = inst_pred(c0);
    let p1 = inst_pred(c1);
    if !is_and && p0 == P_EQ && p1 == P_NE { return c1; }
    if is_and && p0 == P_NE && p1 == P_EQ { return c1; }
    return -1;
}

recursive fn simplify_and_of_icmps(o0: i32, o1: i32, q: SQ) -> i32 {
    var x = simplify_unsigned_range_check(o0, o1, true, q);
    if x >= 0 { return x; }
    x = simplify_unsigned_range_check(o1, o0, true, q);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_constants(o0, o1, true);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_ctpop(o0, o1, true);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_ctpop(o1, o0, true);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_add(o0, o1, true);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_add(o1, o0, true);
    if x >= 0 { return x; }
    return -1;
}
recursive fn simplify_or_of_icmps(o0: i32, o1: i32, q: SQ) -> i32 {
    var x = simplify_unsigned_range_check(o0, o1, false, q);
    if x >= 0 { return x; }
    x = simplify_unsigned_range_check(o1, o0, false, q);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_constants(o0, o1, false);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_ctpop(o0, o1, false);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_ctpop(o1, o0, false);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_add(o0, o1, false);
    if x >= 0 { return x; }
    x = simplify_and_or_of_icmps_with_add(o1, o0, false);
    if x >= 0 { return x; }
    return -1;
}

fn m_fabs_of(v: i32, x: i32) -> bool { m_intrinsic(v, IID_fabs) && op(v, 0) == x }

recursive fn simplify_and_or_of_fcmps(q: SQ, l: i32, r: i32, is_and: bool) -> i32 {
    let l0 = op(l, 0);
    let l1 = op(l, 1);
    let r0 = op(r, 0);
    let r1 = op(r, 1);
    if vals[l0].ty != vals[r0].ty { return -1; }
    let pl = inst_pred(l);
    let pr = inst_pred(r);
    fn abs_or_self(v: i32, x: i32) -> bool { v == x || m_fabs_of(v, x) }
    if (pl == 7 || pl == 8) && ((fpred_is_ordered(pr) && is_and) || (fpred_is_unordered(pr) && !is_and)) {
        if (abs_or_self(r0, l0) || abs_or_self(r1, l0)) && m_pos_zero_fp(l1) {
            return if fpred_is_ordered(pl) == fpred_is_ordered(pr) { r } else { c_bool_ty(vals[l].ty, !is_and) };
        }
    }
    if (pr == 7 || pr == 8) && ((fpred_is_ordered(pl) && is_and) || (fpred_is_unordered(pl) && !is_and)) {
        if (abs_or_self(l0, r0) || abs_or_self(l1, r0)) && m_pos_zero_fp(r1) {
            return if fpred_is_ordered(pl) == fpred_is_ordered(pr) { l } else { c_bool_ty(vals[l].ty, !is_and) };
        }
    }
    let v = fcmps_with_constants(l, r, is_and);
    if v >= 0 { return v; }
    return -1;
}

// simplifyAndOrOfFCmpsWithConstants (ConstantFPRange)
fn fcmps_with_constants(c0: i32, c1: i32, is_and: bool) -> i32 {
    if op(c0, 0) != op(c1, 0) { return -1; }
    let k0 = m_apfloat(op(c0, 1));
    let k1 = m_apfloat(op(c1, 1));
    if k0 < 0 || k1 < 0 { return -1; }
    let p0 = if is_and { inst_pred(c0) } else { 15 - inst_pred(c0) };
    let p1 = if is_and { inst_pred(c1) } else { 15 - inst_pred(c1) };
    let ok0, r0 = fpr_exact_fcmp_region(p0, k0);
    let ok1, r1 = fpr_exact_fcmp_region(p1, k1);
    if !ok0 || !ok1 { return -1; }
    if fpr_is_empty(fpr_intersect(r0, r1)) { return c_bool_ty(vals[c0].ty, !is_and); }
    if fpr_contains(r0, r1) { return c1; }
    if fpr_contains(r1, r0) { return c0; }
    return -1;
}

recursive fn simplify_and_or_of_cmps(q: SQ, a0: i32, b0: i32, is_and: bool) -> i32 {
    var a = a0;
    var b = b0;
    let ca = is_inst(a) && is_cast_op(iop(a));
    let cb = is_inst(b) && is_cast_op(iop(b));
    var looked = false;
    if ca && cb && iop(a) == iop(b) && vals[op(a, 0)].ty == vals[op(b, 0)].ty {
        a = op(a, 0);
        b = op(b, 0);
        looked = true;
    }
    var v: i32 = -1;
    if is_inst_op(a, OP_ICMP) && is_inst_op(b, OP_ICMP) {
        v = if is_and { simplify_and_of_icmps(a, b, q) } else { simplify_or_of_icmps(a, b, q) };
    }
    if is_inst_op(a, OP_FCMP) && is_inst_op(b, OP_FCMP) { v = simplify_and_or_of_fcmps(q, a, b, is_and); }
    if v < 0 { return -1; }
    if !ca { return v; }
    if is_constant(v) { return cf_fold_cast_operand(iop(a0), v, vals[a0].ty); }
    return -1;
}

recursive fn simplify_and_or_with_icmp_eq(o: i64, a: i32, b: i32, q: SQ, mr: i64) -> i32 {
    // m_ICmpLike: icmp, or trunc nuw X to i1 (as X != 0)
    var p: i64 = -1;
    var x: i32 = -1;
    var y: i32 = -1;
    if is_op(a, OP_ICMP) { p = cmp_pred_of(a); x = op(a, 0); y = op(a, 1); }
    else if is_op(a, OP_TRUNC) && is_inst(a) && op_nuw(a) && is_int_or_int_vec_w(vals[a].ty, 1) {
        p = P_NE; x = op(a, 0); y = c_null(vals[x].ty);
    } else { return -1; }
    if !pred_is_equality(p) { return -1; }
    var res = simplify_with_op_replaced(b, x, y, sq_without_undef(q), true, mr);
    if res < 0 { res = simplify_with_op_replaced(b, y, x, sq_without_undef(q), true, mr); }
    if res < 0 { return -1; }
    let ab = binop_absorber(o, vals[res].ty, false);
    if p == (if o == OP_AND { P_EQ } else { P_NE }) {
        if res == ab { return ab; }
        if res == binop_identity(o, vals[res].ty, false) { return a; }
        return -1;
    }
    if res == ab { return b; }
    return -1;
}

fn simplify_logic_of_add_sub(a: i32, b: i32, o: i64) -> i32 {
    var x: i32 = -1;
    var c1: i32 = -1;
    var c2: i32 = -1;
    if is_op(a, OP_ADD) && is_constant(op(a, 1)) && is_op(b, OP_SUB) && is_constant(op(b, 0)) && op(b, 1) == op(a, 0) {
        x = op(a, 0); c1 = op(a, 1); c2 = op(b, 0);
    } else if is_op(b, OP_ADD) && is_constant(op(b, 1)) && is_op(a, OP_SUB) && is_constant(op(a, 0)) && op(a, 1) == op(b, 0) {
        x = op(b, 0); c1 = op(b, 1); c2 = op(a, 0);
    }
    if x >= 0 && ce_not(c1) == c2 {
        let ty = vals[a].ty;
        return if o == OP_AND { c_null(ty) } else { c_all_ones(ty) };
    }
    return -1;
}

// isCheckForZeroAndMulWithOverflow (OverflowInstAnalysis.cpp)
fn is_check_for_zero_and_mul_with_overflow(op0: i32, op1: i32, is_and: bool) -> bool {
    // Op0: icmp eq/ne X, 0 ; Op1: extractvalue (umul/smul.with.overflow X, Y), 1, or its not
    if !is_inst_op(op0, OP_ICMP) || !m_zero_int(op(op0, 1)) { return false; }
    let p = inst_pred(op0);
    if p != (if is_and { P_NE } else { P_EQ }) { return false; }
    let x = op(op0, 0);
    var ov = op1;
    if !is_and {
        let n = m_not(op1);
        if n < 0 { return false; }
        ov = n;
    }
    if !is_inst_op(ov, OP_EXTRACTVALUE) { return false; }
    let ix = insts[inst_of(ov)];
    if ix.naux != 1 || ints[ix.aux] != 1 { return false; }
    let m = op(ov, 0);
    let id = inst_iid(m);
    if id != IID_umul_with_overflow && id != IID_smul_with_overflow { return false; }
    return cb_arg(m, 0) == x || cb_arg(m, 1) == x;
}

recursive fn simplify_and_commutative(a: i32, b: i32, q: SQ, mr: i64) -> i32 {
    if m_not_of(a, b) { return null_of(a); }
    if m_c_binop_with(a, OP_OR, b) >= 0 { return b; }
    // (X | ~Y) & (X | Y) --> X
    if is_op(a, OP_OR) && is_op(b, OP_OR) {
        for s in 2 {
            let x = op(a, s);
            let ny = op(a, 1 - s);
            let y = m_not(ny);
            if y >= 0 { if m_c_binop_both(b, OP_OR, x, y) { return x; } break; }
        }
    }
    if is_check_for_zero_and_mul_with_overflow(a, b, true) { return b; }
    if m_neg(a) == b && b >= 0 && q_pow2(b, true, q) { return b; }
    if is_op(a, OP_ADD) && op(a, 0) == b && m_all_ones(op(a, 1)) && q_pow2(b, true, q) { return null_of(b); }
    if is_op(a, OP_SHL) && m_apint(op(a, 1)) >= 0 && is_op(b, OP_ADD) && m_all_ones(op(b, 1)) {
        let x = op(a, 0);
        let s1 = m_apint(op(a, 1));
        let sb = op(b, 0);
        if is_op(sb, OP_SHL) && op(sb, 0) == x && m_apint(op(sb, 1)) >= 0 {
            let s2 = m_apint(op(sb, 1));
            kb_cxt = q.cxt;
            if is_known_pow2(x, true, 0) && ap_uge(ci_ap(s1), ci_ap(s2)) { return null_of(a); }
        }
    }
    let v = simplify_and_or_with_icmp_eq(OP_AND, a, b, q, mr);
    if v >= 0 { return v; }
    return -1;
}

recursive fn simplify_and(a0: i32, b0: i32, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_AND, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(b) { return b; }
    if q_undef(q, b) { return null_of(a); }
    if a == b { return a; }
    if m_zero(b) { return null_of(a); }
    if m_all_ones(b) { return a; }
    var r = simplify_and_commutative(a, b, q, mr);
    if r >= 0 { return r; }
    r = simplify_and_commutative(b, a, q, mr);
    if r >= 0 { return r; }
    r = simplify_logic_of_add_sub(a, b, OP_AND);
    if r >= 0 { return r; }
    let mask = m_apint(b);
    let w = ty_scalar_bits(vals[a].ty);
    if mask >= 0 {
        let mv = ci_ap(mask);
        if is_op(a, OP_SHL) && m_apint(op(a, 1)) >= 0 {
            let sh = ci_ap(m_apint(op(a, 1)));
            if ap_is_zero(ap_lshr_ap(ap_not(mv), sh)) { return a; }
        }
        if is_op(a, OP_LSHR) && m_apint(op(a, 1)) >= 0 {
            let sh = ci_ap(m_apint(op(a, 1)));
            if ap_is_zero(ap_shl_ap(ap_not(mv), sh)) { return a; }
        }
    }
    let pc = m_apint(b);
    if pc >= 0 && m_power2(b) && is_op(a, OP_ADD) && m_all_ones(op(a, 1)) {
        let sh = op(a, 0);
        if q_pow2(sh, false, q) {
            let k = q_kb(sh, q);
            if ap_active_bits(ci_ap(pc)) >= ap_active_bits(kb_max(k)) { return null_of(b); }
        }
    }
    r = simplify_and_or_of_cmps(q, a, b, true);
    if r >= 0 { return r; }
    r = simplify_associative_binop(OP_AND, a, b, q, mr);
    if r >= 0 { return r; }
    r = expand_commutative_binop(OP_AND, a, b, OP_OR, q, mr);
    if r >= 0 { return r; }
    r = expand_commutative_binop(OP_AND, a, b, OP_XOR, q, mr);
    if r >= 0 { return r; }
    if is_select(a) || is_select(b) {
        if is_int_or_int_vec_w(vals[a].ty, 1) {
            if is_select(b) && op(b, 0) == a && m_zero(op(b, 2)) { return b; }
            else if is_select(a) && op(a, 0) == b && m_zero(op(a, 2)) { return a; }
        }
        r = thread_binop_over_select(OP_AND, a, b, q, mr);
        if r >= 0 { return r; }
    }
    if is_phi_v(a) || is_phi_v(b) {
        r = thread_binop_over_phi(OP_AND, a, b, q, mr);
        if r >= 0 { return r; }
    }
    if mask >= 0 && is_op(a, OP_OR) {
        let mv = ci_ap(mask);
        for s in 2 {
            let xs = op(a, s);
            let y = op(a, 1 - s);
            if is_op(xs, OP_SHL) && op_nuw(xs) && m_apint(op(xs, 1)) >= 0 {
                let x = op(xs, 0);
                let shc = ap_limited(ci_ap(m_apint(op(xs, 1))), w as u64) as i64;
                let yk = q_kb(y, q);
                let effy = w - kb_min_lz(yk);
                if effy <= shc {
                    let xk = q_kb(x, q);
                    let effx = w - kb_min_lz(xk);
                    let by = ap_low_bits(w, effy);
                    let bx = ap_shl(ap_low_bits(w, effx), shc);
                    if ap_is_subset_of(by, mv) && !ap_intersects(bx, mv) { return y; }
                    if ap_is_subset_of(bx, mv) && !ap_intersects(by, mv) { return xs; }
                }
                break;
            }
        }
    }
    // ((X | Y) ^ X ) & ((X | Y) ^ Y) --> 0
    if is_op(a, OP_XOR) && is_op(b, OP_XOR) {
        for s in 2 {
            let x = op(a, s);
            let orv = op(a, 1 - s);
            if is_inst(orv) && is_binary_op(iop(orv)) && is_op(orv, OP_OR) {
                let y = m_c_binop_with(orv, OP_OR, x);
                if y >= 0 { if m_c_binop_both(b, OP_XOR, orv, y) { return null_of(a); } break; }
            }
        }
    }
    if is_op(a, OP_XOR) && m_apint(op(a, 1)) >= 0 && is_op(b, OP_XOR) && op(b, 0) == op(a, 0) {
        let c1 = m_apint(op(a, 1));
        if m_specific_int_apv(op(b, 1), ap_not(ci_ap(c1))) { return null_of(a); }
    }
    if is_int_or_int_vec_w(vals[a].ty, 1) {
        let i1 = implied_condition_vals(a, b, true);
        if i1 == 1 { return a; }
        if i1 == 0 { return get_false(vals[a].ty); }
        let i2 = implied_condition_vals(b, a, true);
        if i2 == 1 { return b; }
        if i2 == 0 { return get_false(vals[b].ty); }
    }
    let d = simplify_by_dom_eq(OP_AND, a, b, q, mr);
    if d >= 0 { return d; }
    return -1;
}

// isImpliedCondition(LHS, RHS, DL, LHSIsTrue)
fn implied_condition_vals(l: i32, r: i32, lhs_true: bool) -> i64 { implied_condition_v(l, r, lhs_true, 0) }

recursive fn simplify_or_logic(x: i32, y: i32) -> i32 {
    let ty = vals[x].ty;
    if m_not_of(y, x) { return c_all_ones(ty); }
    let ny = m_not(y);
    if ny >= 0 && m_c_binop_with(ny, OP_AND, x) >= 0 { return c_all_ones(ty); }
    if m_c_binop_with(y, OP_AND, x) >= 0 { return x; }
    if is_op(x, OP_XOR) && m_c_binop_both(y, OP_OR, op(x, 0), op(x, 1)) { return y; }
    let nx = m_not(x);
    if nx >= 0 && is_op(nx, OP_XOR) && m_c_binop_both(y, OP_OR, op(nx, 0), op(nx, 1)) { return c_all_ones(ty); }
    // (A & ~B) | (A ^ B) --> A ^ B
    if is_op(x, OP_AND) {
        for s in 2 {
            let a = op(x, s);
            let b = m_not(op(x, 1 - s));
            if b >= 0 { if m_c_binop_both(y, OP_XOR, a, b) { return y; } break; }
        }
    }
    // (~A ^ B) | (A & B) --> ~A ^ B
    if is_op(x, OP_XOR) {
        for s in 2 {
            let a = m_not(op(x, s));
            let b = op(x, 1 - s);
            if a >= 0 { if m_c_binop_both(y, OP_AND, a, b) { return x; } break; }
        }
    }
    // (~A | B) | (A ^ B) --> -1
    if is_op(x, OP_OR) {
        for s in 2 {
            let a = m_not(op(x, s));
            let b = op(x, 1 - s);
            if a >= 0 { if m_c_binop_both(y, OP_XOR, a, b) { return c_all_ones(ty); } break; }
        }
    }
    // (~A & B) | ~(A | B) --> ~A
    if is_op(x, OP_AND) {
        let nyy = m_not(y);
        for s in 2 {
            let na = op(x, s);
            let a = m_not(na);
            let b = op(x, 1 - s);
            if a >= 0 { if nyy >= 0 && m_c_binop_both(nyy, OP_OR, a, b) { return na; } break; }
        }
    }
    // logical-and version
    if m_logical(x, true) {
        let la = lg_a;
        let lb = lg_b;
        let nyy = m_not(y);
        for s in 2 {
            let na = if s == 0 { la } else { lb };
            let b = if s == 0 { lb } else { la };
            let a = m_not(na);
            if a >= 0 { if nyy >= 0 && m_c_logical_both(nyy, false, a, b) { return na; } break; }
        }
    }
    // ~(A ^ B) | (A & B) --> ~(A ^ B)
    if nx >= 0 && is_op(nx, OP_XOR) && m_c_binop_both(y, OP_AND, op(nx, 0), op(nx, 1)) { return x; }
    // ~(A & B) | (A ^ B) --> ~(A & B)
    if nx >= 0 && is_op(nx, OP_AND) && m_c_binop_both(y, OP_XOR, op(nx, 0), op(nx, 1)) { return x; }
    return -1;
}

recursive fn simplify_or(a0: i32, b0: i32, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_OR, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(b) { return b; }
    if q_undef(q, b) || m_all_ones(b) { return c_all_ones(vals[a].ty); }
    if a == b || m_zero(b) { return a; }
    var r = simplify_or_logic(a, b);
    if r >= 0 { return r; }
    r = simplify_or_logic(b, a);
    if r >= 0 { return r; }
    r = simplify_logic_of_add_sub(a, b, OP_OR);
    if r >= 0 { return r; }
    // rotated -1
    var x: i32 = -1;
    var y: i32 = -1;
    if is_op(a, OP_SHL) && m_all_ones(op(a, 0)) && is_op(b, OP_LSHR) && m_all_ones(op(b, 0)) { x = op(a, 1); y = op(b, 1); }
    else if is_op(b, OP_SHL) && m_all_ones(op(b, 0)) && is_op(a, OP_LSHR) && m_all_ones(op(a, 0)) { x = op(b, 1); y = op(a, 1); }
    if x >= 0 {
        var cc: i32 = -1;
        if is_op(x, OP_SUB) && m_apint(op(x, 0)) >= 0 && op(x, 1) == y { cc = m_apint(op(x, 0)); }
        else if is_op(y, OP_SUB) && m_apint(op(y, 0)) >= 0 && op(y, 1) == x { cc = m_apint(op(y, 0)); }
        if cc >= 0 && ap_ule_u64(ci_ap(cc), ty_scalar_bits(vals[x].ty) as u64) { return c_all_ones(vals[x].ty); }
    }
    if m_intrinsic(a, IID_fshl) && is_op(b, OP_SHL) && op(b, 0) == op(a, 0) && op(b, 1) == op(a, 2) { return a; }
    if m_intrinsic(b, IID_fshl) && is_op(a, OP_SHL) && op(a, 0) == op(b, 0) && op(a, 1) == op(b, 2) { return b; }
    if m_intrinsic(a, IID_fshr) && is_op(b, OP_LSHR) && op(b, 0) == op(a, 1) && op(b, 1) == op(a, 2) { return a; }
    if m_intrinsic(b, IID_fshr) && is_op(a, OP_LSHR) && op(a, 0) == op(b, 1) && op(a, 1) == op(b, 2) { return b; }
    r = simplify_and_or_with_icmp_eq(OP_OR, a, b, q, mr);
    if r >= 0 { return r; }
    r = simplify_and_or_with_icmp_eq(OP_OR, b, a, q, mr);
    if r >= 0 { return r; }
    r = simplify_and_or_of_cmps(q, a, b, false);
    if r >= 0 { return r; }
    if is_check_for_zero_and_mul_with_overflow(a, b, false) { return b; }
    if is_check_for_zero_and_mul_with_overflow(b, a, false) { return a; }
    r = simplify_associative_binop(OP_OR, a, b, q, mr);
    if r >= 0 { return r; }
    r = expand_commutative_binop(OP_OR, a, b, OP_AND, q, mr);
    if r >= 0 { return r; }
    if is_select(a) || is_select(b) {
        if is_int_or_int_vec_w(vals[a].ty, 1) {
            if is_select(b) && op(b, 0) == a && m_one(op(b, 1)) { return b; }
            else if is_select(a) && op(a, 0) == b && m_one(op(a, 1)) { return a; }
        }
        r = thread_binop_over_select(OP_OR, a, b, q, mr);
        if r >= 0 { return r; }
    }
    if is_op(a, OP_AND) && m_apint(op(a, 1)) >= 0 && is_op(b, OP_AND) && m_apint(op(b, 1)) >= 0 {
        let aa = op(a, 0);
        let bb = op(b, 0);
        let c1 = ci_ap(m_apint(op(a, 1)));
        let c2 = ci_ap(m_apint(op(b, 1)));
        if ap_eq(c1, ap_not(c2)) {
            let n = m_c_binop_with(aa, OP_ADD, bb);
            if ap_is_mask(c2) && n >= 0 {
                if q_masked_zero(n, c2, q) { return aa; }
            }
            let n2 = m_c_binop_with(bb, OP_ADD, aa);
            if ap_is_mask(c1) && n2 >= 0 {
                if q_masked_zero(n2, c1, q) { return bb; }
            }
        }
    }
    if is_phi_v(a) || is_phi_v(b) {
        r = thread_binop_over_phi(OP_OR, a, b, q, mr);
        if r >= 0 { return r; }
    }
    if is_op(a, OP_XOR) && m_apint(op(a, 1)) >= 0 && is_op(b, OP_XOR) && op(b, 0) == op(a, 0) {
        let c1 = m_apint(op(a, 1));
        if m_specific_int_apv(op(b, 1), ap_not(ci_ap(c1))) { return c_all_ones(vals[a].ty); }
    }
    if is_int_or_int_vec_w(vals[a].ty, 1) {
        let i1 = implied_condition_vals(a, b, false);
        if i1 == 0 { return a; }
        if i1 == 1 { return get_true(vals[a].ty); }
        let i2 = implied_condition_vals(b, a, false);
        if i2 == 0 { return b; }
        if i2 == 1 { return get_true(vals[b].ty); }
    }
    let d = simplify_by_dom_eq(OP_OR, a, b, q, mr);
    if d >= 0 { return d; }
    return -1;
}

recursive fn simplify_xor(a0: i32, b0: i32, q: SQ, mr: i64) -> i32 {
    let c, a, b = fold_or_commute_constant(OP_XOR, a0, b0, q);
    if c >= 0 { return c; }
    if is_poison(b) { return b; }
    if q_undef(q, b) { return b; }
    if m_zero(b) { return a; }
    if a == b { return null_of(a); }
    if m_not_of(a, b) || m_not_of(b, a) { return c_all_ones(vals[a].ty); }
    fn fold_and_or_not(x: i32, y: i32) -> i32 {
        // (~A & B) ^ (A | B) --> A
        if is_op(x, OP_AND) {
            for s in 2 {
                let a = m_not(op(x, s));
                let b = op(x, 1 - s);
                if a >= 0 { if m_c_binop_both(y, OP_OR, a, b) { return a; } break; }
            }
        }
        // (~A | B) ^ (A & B) --> ~A
        if is_op(x, OP_OR) {
            for s in 2 {
                let na = op(x, s);
                let a = m_not(na);
                let b = op(x, 1 - s);
                if a >= 0 { if m_c_binop_both(y, OP_AND, a, b) { return na; } break; }
            }
        }
        return -1;
    }
    var r = fold_and_or_not(a, b);
    if r >= 0 { return r; }
    r = fold_and_or_not(b, a);
    if r >= 0 { return r; }
    r = simplify_logic_of_add_sub(a, b, OP_XOR);
    if r >= 0 { return r; }
    r = simplify_associative_binop(OP_XOR, a, b, q, mr);
    if r >= 0 { return r; }
    let d = simplify_by_dom_eq(OP_XOR, a, b, q, mr);
    if d >= 0 { return d; }
    if is_op(a, OP_SUB) && op_nuw(a) && op(a, 0) == b && m_low_bit_mask(b) { return op(a, 1); }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// ICmp

fn get_compare_ty(v: i32) -> i32 { cmp_result_ty(vals[v].ty) }

fn extract_equivalent_condition(v: i32, p: i64, l: i32, r: i32) -> i32 {
    if !is_select(v) { return -1; }
    let c = op(v, 0);
    if !is_inst(c) || (iop(c) != OP_ICMP && iop(c) != OP_FCMP) { return -1; }
    let cl = op(c, 0);
    let cr = op(c, 1);
    if p == inst_pred(c) && l == cl && r == cr { return c; }
    if p == pred_swap_any(inst_pred(c)) && l == cr && r == cl { return c; }
    return -1;
}

fn is_byval_arg(v: i32) -> bool { is_arg(v) && arg_has_attr(v, AK_ByVal) }
fn arg_deref_bytes(v: i32) -> u64 {
    let s = arg_attrs(v);
    let at = aset_find(s, AK_Dereferenceable);
    if at < 0 { return 0; }
    return attrs[at].i1;
}
fn is_dereferenceable_arg(v: i32) -> bool { is_arg(v) && ty_kind(vals[v].ty) == TK_PTR && arg_deref_bytes(v) > 0 }
fn is_static_alloca(v: i32) -> bool {
    // AllocaInst::isStaticAlloca: constant array size and in the entry block (not inalloca)
    if !is_inst_op(v, OP_ALLOCA) { return false; }
    if !is_constant(op(v, 0)) || vals[op(v, 0)].kind != VK_CINT { return false; }
    let f = inst_func(v);
    return inst_parent(v) == func_entry(f) && (insts[inst_of(v)].bits & 4) == 0;
}
fn is_alloc_disjoint(v: i32) -> bool {
    if is_inst_op(v, OP_ALLOCA) { return is_static_alloca(v); }
    if is_global(v) && vals[v].kind != VK_IFUNC {
        let g = globs[glob_of(v)];
        let l = g.linkage as i64;
        return (l == LK_INTERNAL || l == LK_PRIVATE || g.vis == 1 || g.vis == 2 || g.unnamed == 1) && g.tls == 0;
    }
    return is_byval_arg(v);
}
fn have_non_overlapping_storage(a: i32, b: i32) -> bool {
    if is_byval_arg(a) { return is_inst_op(b, OP_ALLOCA) || is_gvar(b) || is_byval_arg(b) || is_dereferenceable_arg(b); }
    if is_byval_arg(b) { return is_inst_op(a, OP_ALLOCA) || is_gvar(a) || is_byval_arg(a) || is_dereferenceable_arg(a); }
    if (is_dereferenceable_arg(a) && is_inst_op(b, OP_ALLOCA)) || (is_dereferenceable_arg(b) && is_inst_op(a, OP_ALLOCA)) { return true; }
    return is_inst_op(a, OP_ALLOCA) && (is_inst_op(b, OP_ALLOCA) || is_gvar(b));
}
// Value::getPointerDereferenceableBytes (CanBeNull out); returns bytes, can_be_null
fn pointer_deref_bytes(v: i32) -> u64, bool {
    if is_arg(v) {
        var b = arg_deref_bytes(v);
        var cbn = false;
        if b == 0 {
            let at = aset_find(arg_attrs(v), AK_DereferenceableOrNull);
            if at >= 0 { b = attrs[at].i1; cbn = true; }
        }
        if b == 0 {
            if (arg_has_attr(v, AK_ByVal) || arg_has_attr(v, AK_InAlloca) || arg_has_attr(v, AK_Preallocated)) {
                is_not_ported("dereferenceable bytes of byval arguments");
            }
        }
        if b != 0 && null_pointer_is_defined(args_parent[vals[v].sub], ptr_as(vals[v].ty)) { cbn = true; }
        return b, cbn;
    }
    if is_inst_op(v, OP_ALLOCA) {
        if !is_constant(op(v, 0)) || vals[op(v, 0)].kind != VK_CINT { return 0, false; }
        let at = insts[inst_of(v)].ty2;
        if ty_kind(at) == TK_SVEC { return 0, false; }
        return (dl_alloc_size(at) as u64) * ci_val(op(v, 0)), false;
    }
    if is_gvar(v) {
        let g = globs[glob_of(v)];
        // GlobalVariable with a known size: !isInterposable/definitive or not; LLVM: if (!GV->getValueType()->isSized() ...)
        if g.vty >= 0 && ty_is_sized(g.vty) && !gv_has_external_weak(v) {
            return dl_alloc_size(g.vty) as u64, false;
        }
        return 0, false;
    }
    if is_callbase(v) {
        is_not_ported("dereferenceable bytes of calls");
    }
    if is_inst_op(v, OP_LOAD) { is_not_ported("dereferenceable bytes of loads"); }
    return 0, false;
}
fn gv_has_external_weak(v: i32) -> bool { globs[glob_of(v)].linkage as i64 == LK_EXTERN_WEAK }
recursive fn ty_is_sized(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_VOID || k == TK_LABEL || k == TK_METADATA || k == TK_FUNC || k == TK_TOKEN { return false; }
    if k == TK_STRUCT { if (types[t].flags & TF_OPAQUE) != 0 { return false; } for i in types[t].cnt { if !ty_is_sized(ty_field(t, i)) { return false; } } return true; }
    if k == TK_ARRAY || k == TK_FVEC || k == TK_SVEC { return ty_is_sized(types[t].a); }
    return true;
}

// isNoAliasCall: a call with a noalias return
fn is_noalias_call(v: i32) -> bool { is_callbase(v) && call_ret_has_attr(v, AK_NoAlias) }

recursive fn compute_pointer_icmp(p0: i64, l0: i32, r0: i32, q: SQ) -> i32 {
    if pred_is_signed(p0) { return -1; }
    let p = pred_signed(p0);
    let allow_non_inbounds = pred_is_equality(p);
    let l = strip_and_accumulate_offsets(l0, allow_non_inbounds, false, false);
    let lo = vt_off;
    let r = strip_and_accumulate_offsets(r0, allow_non_inbounds, false, false);
    let ro = vt_off;
    let iw = dl_ptr(ptr_as(vals[l0].ty)).idx;
    if l == r {
        return c_bool_ty(get_compare_ty(l), icmp_compare((lo as! u64) & wmask64(iw), (ro as! u64) & wmask64(iw), p, iw));
    }
    if pred_is_equality(p) {
        if have_non_overlapping_storage(l, r) {
            let ls, lcn = pointer_deref_bytes(l);
            let rs, rcn = pointer_deref_bytes(r);
            if ls != 0 && !lcn && rs != 0 && !rcn {
                let dist = lo - ro;
                if (dist >= 0 && (dist as u64) < ls) || (dist < 0 && ((0 - dist) as u64) < rs) {
                    return c_bool_ty(get_compare_ty(l), !pred_true_when_eq(p));
                }
            }
        }
        var lu: i32[>..<] = [];
        var ru: i32[>..<] = [];
        get_underlying_objects(l, lu);
        get_underlying_objects(r, ru);
        var l_noalias = true;
        var l_disj = true;
        for o in lu { if !is_noalias_call(o) { l_noalias = false; } if !is_alloc_disjoint(o) { l_disj = false; } }
        var r_noalias = true;
        var r_disj = true;
        for o in ru { if !is_noalias_call(o) { r_noalias = false; } if !is_alloc_disjoint(o) { r_disj = false; } }
        if (l_noalias && r_disj) || (r_noalias && l_disj) { return c_bool_ty(get_compare_ty(l), !pred_true_when_eq(p)); }
        var mi: i32 = -1;
        if is_alloc_like_value(l) && q_nonzero(r, q) { mi = l; }
        else if is_alloc_like_value(r) && q_nonzero(l, q) { mi = r; }
        if mi >= 0 {
            if !alloc_captured_for_icmp(mi) { return c_bool_ty(get_compare_ty(l), pred_false_when_eq(p)); }
        }
    }
    return -1;
}

fn is_alloc_like_value(v: i32) -> bool { is_callbase(v) && is_alloc_like_fn(v) }

// PointerMayBeCaptured with the CustomCaptureTracker of computePointerICmp
fn alloc_captured_for_icmp(mi: i32) -> bool {
    is_not_ported("capture tracking (PointerMayBeCaptured)");
    return true;
}

recursive fn simplify_icmp_of_bools(p: i64, l: i32, r: i32, q: SQ) -> i32 {
    let ity = get_compare_ty(l);
    if !is_int_or_int_vec_w(vals[l].ty, 1) { return -1; }
    if m_zero(r) {
        if p == P_NE || p == P_UGT || p == P_SLT { return l; }
        if p == P_EQ || p == P_ULE || p == P_SGE { let x = m_not(l); if x >= 0 { return x; } }
        if p == P_ULT || p == P_SGT { return get_false(ity); }
        if p == P_UGE || p == P_SLE { return get_true(ity); }
    } else if m_one(r) {
        if p == P_EQ || p == P_UGE || p == P_SLE { return l; }
        if p == P_NE || p == P_ULT || p == P_SGT { let x = m_not(l); if x >= 0 { return x; } }
        if p == P_UGT || p == P_SLT { return get_false(ity); }
        if p == P_ULE || p == P_SGE { return get_true(ity); }
    }
    if p == P_UGE { if implied_condition_vals(r, l, true) == 1 { return get_true(ity); } }
    else if p == P_SGE { if implied_condition_vals(l, r, true) == 1 { return get_true(ity); } }
    else if p == P_ULE { if implied_condition_vals(l, r, true) == 1 { return get_true(ity); } }
    else if p == P_SLE { if implied_condition_vals(r, l, true) == 1 { return get_true(ity); } }
    return -1;
}

recursive fn simplify_icmp_with_zero(p0: i64, l: i32, r: i32, q: SQ) -> i32 {
    var p = p0;
    if m_zero(r) { }
    else if m_all_ones(r) {
        if p == P_SGT { p = P_SGE; } else if p == P_SLE { p = P_SLT; } else { return -1; }
    } else if m_one(r) {
        if p == P_SGE { p = P_SGT; } else if p == P_UGE { p = P_UGT; } else if p == P_SLT { p = P_SLE; } else if p == P_ULT { p = P_ULE; } else { return -1; }
    } else { return -1; }
    let ity = get_compare_ty(l);
    if p == P_ULT { return get_false(ity); }
    if p == P_UGE { return get_true(ity); }
    if p == P_EQ || p == P_ULE { if q_nonzero(l, q) { return get_false(ity); } return -1; }
    if p == P_NE || p == P_UGT { if q_nonzero(l, q) { return get_true(ity); } return -1; }
    if p == P_SLT {
        let k = q_kb(l, q);
        if kb_is_neg(k) { return get_true(ity); }
        if kb_is_nonneg(k) { return get_false(ity); }
        return -1;
    }
    if p == P_SLE {
        let k = q_kb(l, q);
        if kb_is_neg(k) { return get_true(ity); }
        if kb_is_nonneg(k) && q_nonzero(l, q) { return get_false(ity); }
        return -1;
    }
    if p == P_SGE {
        let k = q_kb(l, q);
        if kb_is_neg(k) { return get_false(ity); }
        if kb_is_nonneg(k) { return get_true(ity); }
        return -1;
    }
    if p == P_SGT {
        let k = q_kb(l, q);
        if kb_is_neg(k) { return get_false(ity); }
        if kb_is_nonneg(k) && q_nonzero(l, q) { return get_true(ity); }
        return -1;
    }
    return -1;
}

// isSignBitCheck(Pred, RHS, TrueIfSigned): 1/0 for TrueIfSigned, -1 if not a sign-bit check
fn sign_bit_check(p: i64, c: AP) -> i64 {
    let ok, tis = is_sign_bit_check(p, c);
    if !ok { return -1; }
    return if tis { 1 } else { 0 };
}

recursive fn simplify_icmp_with_constant(p: i64, l: i32, r: i32, q: SQ) -> i32 {
    let ity = get_compare_ty(r);
    let c = m_apint_ap(r, true);
    if c < 0 { return -1; }
    let cv = ci_ap(c);
    // m_ElementWiseBitCast(m_UIToFP(m_Value()))
    if is_op(l, OP_BITCAST) && is_op(op(l, 0), OP_UITOFP) && elementwise_bitcast(l) {
        let t = sign_bit_check(p, cv);
        if t >= 0 { return c_bool_ty(ity, t == 0); }
    }
    let rcr = rg_exact_icmp(p, cv);
    if rg_is_empty(rcr) { return get_false(ity); }
    if rg_is_full(rcr) { return get_true(ity); }
    let lcr = q_constant_range(l, pred_is_signed(p), q);
    if !rg_is_full(lcr) {
        if rg_contains(rcr, lcr) { return get_true(ity); }
        if rg_contains(rg_inverse(rcr), lcr) { return get_false(ity); }
    }
    if pred_is_equality(p) && is_op(l, OP_MUL) {
        let mc = m_apint_ap(op(l, 1), true);
        if mc >= 0 {
            let mv = ci_ap(mc);
            if (op_nuw(l) && !ap_is_zero(mv) && !ap_is_zero(ap_urem(cv, mv))) || (op_nsw(l) && !ap_is_zero(mv) && !ap_is_zero(ap_srem(cv, mv))) {
                return c_bool_ty(ity, p == P_NE);
            }
        }
    }
    if p == P_UGE && ap_is_one(cv) && q_nonzero(l, q) { return get_true(ity); }
    return -1;
}
fn elementwise_bitcast(v: i32) -> bool {
    // m_ElementWiseBitCast: bitcast between types with the same element count
    let st = vals[op(v, 0)].ty;
    let dt = vals[v].ty;
    if ty_is_vector(st) != ty_is_vector(dt) { return false; }
    if ty_is_vector(st) { return ty_count(st) == ty_count(dt) && ty_kind(st) == ty_kind(dt); }
    return true;
}

fn q_constant_range(v: i32, signed: bool, q: SQ) -> CRange { kb_cxt = q.cxt; return compute_constant_range(v, signed, true, 0); }

// getUnsignedMonotonicValues (Depth limit 1): values collected into the given array
recursive fn unsigned_monotonic_values(res: i32[>..<]&, v: i32, greater: bool, q: SQ, depth0: i64) {
    for x in res { if x == v { return; } }
    res.push(v);
    let depth = depth0 + 1;
    if depth > 1 { return; }
    if !is_inst(v) { return; }
    if greater {
        if (iop(v) == OP_OR) || m_intrinsic(v, IID_uadd_sat) {
            unsigned_monotonic_values(res, op(v, 0), greater, q, depth);
            unsigned_monotonic_values(res, op(v, 1), greater, q, depth);
        }
        if iop(v) == OP_MUL && op_nuw(v) {
            let x = op(v, 0);
            let y = op(v, 1);
            if q_nonzero(x, q) { unsigned_monotonic_values(res, y, greater, q, depth); }
            if q_nonzero(y, q) { unsigned_monotonic_values(res, x, greater, q, depth); }
        }
    } else {
        let o = iop(v);
        if o == OP_AND {
            unsigned_monotonic_values(res, op(v, 0), greater, q, depth);
            unsigned_monotonic_values(res, op(v, 1), greater, q, depth);
        } else if o == OP_UREM || o == OP_UDIV || o == OP_LSHR {
            unsigned_monotonic_values(res, op(v, 0), greater, q, depth);
        } else if o == OP_CALL {
            if m_intrinsic(v, IID_usub_sat) { unsigned_monotonic_values(res, op(v, 0), greater, q, depth); }
        }
    }
}

recursive fn simplify_icmp_using_monotonic(p: i64, l: i32, r: i32, q: SQ) -> i32 {
    if p != P_UGE && p != P_ULT { return -1; }
    var gv: i32[>..<] = [];
    unsigned_monotonic_values(gv, l, true, q, 0);
    var lv: i32[>..<] = [];
    unsigned_monotonic_values(lv, r, false, q, 0);
    for g in gv {
        for x in lv { if x == g { return c_bool_ty(get_compare_ty(l), p == P_UGE); } }
    }
    return -1;
}

recursive fn simplify_icmp_with_binop_on_lhs(p: i64, lbo: i32, r: i32, q: SQ, mr: i64) -> i32 {
    let ity = get_compare_ty(r);
    let y = m_c_binop_with(lbo, OP_OR, r);
    if y >= 0 {
        if p == P_SLT || p == P_SGE {
            let rk = q_kb(r, q);
            let yk = q_kb(y, q);
            if kb_is_nonneg(rk) && kb_is_neg(yk) { return if p == P_SLT { get_true(ity) } else { get_false(ity) }; }
            if kb_is_neg(rk) || kb_is_nonneg(yk) { return if p == P_SLT { get_false(ity) } else { get_true(ity) }; }
        }
    }
    if is_op(lbo, OP_UREM) && op(lbo, 1) == r {
        var res: i64 = -1;
        if p == P_SGT || p == P_SGE {
            if kb_is_nonneg(q_kb(r, q)) { res = 0; }
        } else if p == P_EQ || p == P_UGT || p == P_UGE { res = 0; }
        else if p == P_SLT || p == P_SLE {
            if kb_is_nonneg(q_kb(r, q)) { res = 1; }
        } else if p == P_NE || p == P_ULT || p == P_ULE { res = 1; }
        if res == 0 { return get_false(ity); }
        if res == 1 { return get_true(ity); }
    }
    var shr_or_div = false;
    if is_op(lbo, OP_LSHR) && op(lbo, 0) == r { let c = m_apint(op(lbo, 1)); if c >= 0 && !ap_is_zero(ci_ap(c)) { shr_or_div = true; } }
    if !shr_or_div && is_op(lbo, OP_UDIV) && op(lbo, 0) == r { let c = m_apint(op(lbo, 1)); if c >= 0 && !ap_is_one(ci_ap(c)) { shr_or_div = true; } }
    if shr_or_div {
        if q_nonzero(r, q) {
            if p == P_EQ || p == P_UGE || p == P_UGT { return get_false(ity); }
            if p == P_NE || p == P_ULT || p == P_ULE { return get_true(ity); }
        }
    }
    var mdiv = false;
    let a0 = op(lbo, 0);
    if is_op(lbo, OP_UDIV) && is_op(a0, OP_MUL) && op(a0, 0) == r {
        let c1 = m_apint(op(a0, 1));
        let c2 = m_apint(op(lbo, 1));
        if c1 >= 0 && c2 >= 0 && ap_ule(ci_ap(c1), ci_ap(c2)) { mdiv = true; }
    }
    if !mdiv && is_op(lbo, OP_LSHR) && is_op(a0, OP_MUL) && op(a0, 0) == r {
        let c1 = m_apint(op(a0, 1));
        let c2 = m_apint(op(lbo, 1));
        if c1 >= 0 && c2 >= 0 {
            let pw = ap_shl_ap(ap_u64(1, ci_w(c2)), ci_ap(c2));
            if ap_ule(ci_ap(c1), pw) { mdiv = true; }
        }
    }
    if !mdiv && is_op(lbo, OP_UDIV) && is_op(a0, OP_SHL) && op(a0, 0) == r {
        let c1 = m_apint(op(a0, 1));
        let c2 = m_apint(op(lbo, 1));
        if c1 >= 0 && c2 >= 0 {
            let pw = ap_shl_ap(ap_u64(1, ci_w(c1)), ci_ap(c1));
            if ap_ule(pw, ci_ap(c2)) { mdiv = true; }
        }
    }
    if mdiv {
        if p == P_UGT { return get_false(ity); }
        if p == P_ULE { return get_true(ity); }
    }
    if is_op(lbo, OP_SUB) && op(lbo, 1) == r {
        let c = m_apint_ap(op(lbo, 0), true);
        if c >= 0 && ap_get_bit(ci_ap(c), 0) && pred_is_equality(p) { return if p == P_EQ { get_false(ity) } else { get_true(ity) }; }
    }
    return -1;
}

fn try_simplify_icmp_with_adds(p: i64, l0: i32, r0: i32) -> bool {
    if !pred_is_signed(p) { return false; }
    var l = l0;
    var r = r0;
    fn nswadd(v: i32) -> bool { is_op(v, OP_ADD) && op_nsw(v) }
    if !nswadd(r) { let t = l; l = r; r = t; }
    if !nswadd(r) { return false; }
    if !is_op(l, OP_ADD) { return false; }
    let x = op(l, 0);
    let c1 = m_apint(op(l, 1));
    if c1 < 0 { return false; }
    if op(r, 0) != x { return false; }
    let c2 = m_apint(op(r, 1));
    if c2 < 0 { return false; }
    let a = ci_ap(c1);
    let b = ci_ap(c2);
    return (ap_sle(a, b) && !ap_is_neg(a)) || (ap_sle(b, a) && !ap_is_strictly_pos(a));
}

recursive fn simplify_icmp_with_binop(p0: i64, l: i32, r: i32, q: SQ, mr: i64) -> i32 {
    var p = p0;
    let lbo = is_inst(l) && is_binary_op(iop(l));
    let rbo = is_inst(r) && is_binary_op(iop(r));
    if mr > 0 && (lbo || rbo) {
        var a: i32 = -1;
        var b: i32 = -1;
        var c: i32 = -1;
        var d: i32 = -1;
        var nlw = false;
        var nrw = false;
        if lbo && iop(l) == OP_ADD {
            a = op(l, 0);
            b = op(l, 1);
            nlw = pred_is_equality(p) || (pred_is_unsigned(p) && op_nuw(l)) || (pred_is_signed(p) && op_nsw(l));
        }
        if rbo && iop(r) == OP_ADD {
            c = op(r, 0);
            d = op(r, 1);
            nrw = pred_is_equality(p) || (pred_is_unsigned(p) && op_nuw(r)) || (pred_is_signed(p) && op_nsw(r));
        }
        if a >= 0 && (a == r || b == r) && nlw {
            let v = simplify_icmp(p, if a == r { b } else { a }, null_of(r), q, mr - 1);
            if v >= 0 { return v; }
        }
        if c >= 0 && (c == l || d == l) && nrw {
            let v = simplify_icmp(p, null_of(l), if c == l { d } else { c }, q, mr - 1);
            if v >= 0 { return v; }
        }
        let can = (nlw && nrw) || try_simplify_icmp_with_adds(p, l, r);
        if a >= 0 && c >= 0 && (a == c || a == d || b == c || b == d) && can {
            var y: i32 = -1;
            var z: i32 = -1;
            if a == c { y = b; z = d; }
            else if a == d { y = b; z = c; }
            else if b == c { y = a; z = d; }
            else { y = a; z = c; }
            let v = simplify_icmp(p, y, z, q, mr - 1);
            if v >= 0 { return v; }
        }
    }
    if lbo {
        let v = simplify_icmp_with_binop_on_lhs(p, l, r, q, mr);
        if v >= 0 { return v; }
    }
    if rbo {
        let v = simplify_icmp_with_binop_on_lhs(pred_swapped(p), r, l, q, mr);
        if v >= 0 { return v; }
    }
    if !pred_is_unsigned(p) {
        let n = m_neg(l);
        if n >= 0 && is_op(n, OP_ZEXT) {
            let c = m_apint(r);
            if c >= 0 {
                let cv = ci_ap(c);
                let ty = get_compare_ty(r);
                if ap_is_strictly_pos(cv) {
                    if p == P_SLT || p == P_NE { return get_true(ty); }
                    if p == P_SGE || p == P_EQ { return get_false(ty); }
                }
                if !ap_is_neg(cv) {
                    if p == P_SLE { return get_true(ty); }
                    if p == P_SGT { return get_false(ty); }
                }
            }
        }
    }
    if is_op(l, OP_SHL) && m_power2(op(l, 0)) {
        let c = m_apint_ap(r, true);
        if c >= 0 {
            let cv = ci_ap(c);
            let c_pow2 = ap_is_pow2(cv);
            if !c_pow2 {
                if op_nsw(l) || op_nuw(l) || m_one(op(l, 0)) || !ap_is_zero(cv) {
                    if p == P_EQ { return get_false(get_compare_ty(r)); }
                    if p == P_NE { return get_true(get_compare_ty(r)); }
                }
            }
        }
    }
    if is_op(l, OP_SHL) && m_power2(op(l, 0)) && m_sign_mask(r) {
        if p == P_UGT { return get_false(get_compare_ty(r)); }
        if p == P_ULE { return get_true(get_compare_ty(r)); }
    }
    if mr == 0 || !lbo || !rbo || iop(l) != iop(r) { return -1; }
    let o = iop(l);
    if op(l, 0) == op(r, 0) {
        if o == OP_SHL {
            let nuw = op_nuw(l) && op_nuw(r);
            let nsw = op_nsw(l) && op_nsw(r);
            if nuw && !(pred_is_signed(p) && !nsw) && q_nonzero(op(l, 0), q) {
                let v = simplify_icmp(p, op(l, 1), op(r, 1), q, mr - 1);
                if v >= 0 { return v; }
            }
        } else if o == OP_AND || o == OP_OR {
            var c1 = m_apint(op(l, 1));
            var c2 = m_apint(op(r, 1));
            if pred_relational(p) && c1 >= 0 && c2 >= 0 {
                fn subset(x: i32, y: i32) -> bool { ap_is_subset_of(ci_ap(x), ci_ap(y)) }
                if !subset(c1, c2) { let t = c1; c1 = c2; c2 = t; p = pred_swapped(p); }
                if subset(c1, c2) {
                    let ty = get_compare_ty(l);
                    if p == P_ULE { return get_true(ty); }
                    if p == P_UGT { return get_false(ty); }
                    if ap_is_neg(ci_ap(c1)) == ap_is_neg(ci_ap(c2)) {
                        if p == P_SLE { return get_true(ty); }
                        if p == P_SGT { return get_false(ty); }
                    }
                }
            }
        }
    }
    if op(l, 1) == op(r, 1) {
        if o == OP_UDIV || o == OP_LSHR {
            if !(pred_is_signed(p) || !op_exact(l) || !op_exact(r)) {
                let v = simplify_icmp(p, op(l, 0), op(r, 0), q, mr - 1);
                if v >= 0 { return v; }
            }
        } else if o == OP_SDIV {
            if pred_is_equality(p) && op_exact(l) && op_exact(r) {
                let v = simplify_icmp(p, op(l, 0), op(r, 0), q, mr - 1);
                if v >= 0 { return v; }
            }
        } else if o == OP_ASHR {
            if op_exact(l) && op_exact(r) {
                let v = simplify_icmp(p, op(l, 0), op(r, 0), q, mr - 1);
                if v >= 0 { return v; }
            }
        } else if o == OP_SHL {
            let nuw = op_nuw(l) && op_nuw(r);
            let nsw = op_nsw(l) && op_nsw(r);
            if (nuw || nsw) && !(!nsw && pred_is_signed(p)) {
                let v = simplify_icmp(p, op(l, 0), op(r, 0), q, mr - 1);
                if v >= 0 { return v; }
            }
        }
    }
    return -1;
}

recursive fn minmax_case(p: i64, eqp: i64, a: i32, b: i32, l: i32, r: i32, q: SQ, mr: i64, signed: bool) -> i32 {
    let ity = get_compare_ty(l);
    let lt = if signed { P_SLE } else { P_ULE };
    let gt = if signed { P_SGT } else { P_UGT };
    let ge = if signed { P_SGE } else { P_UGE };
    let ltp = if signed { P_SLT } else { P_ULT };
    if p == P_EQ || p == lt {
        var v = extract_equivalent_condition(l, eqp, a, b);
        if v >= 0 { return v; }
        v = extract_equivalent_condition(r, eqp, a, b);
        if v >= 0 { return v; }
        if mr > 0 { v = simplify_icmp(eqp, a, b, q, mr - 1); if v >= 0 { return v; } }
        return -1;
    }
    if p == P_NE || p == gt {
        let inv = pred_inverse(eqp);
        var v = extract_equivalent_condition(l, inv, a, b);
        if v >= 0 { return v; }
        v = extract_equivalent_condition(r, inv, a, b);
        if v >= 0 { return v; }
        if mr > 0 { v = simplify_icmp(inv, a, b, q, mr - 1); if v >= 0 { return v; } }
        return -1;
    }
    if p == ge { return get_true(ity); }
    if p == ltp { return get_false(ity); }
    return -1;
}

recursive fn simplify_icmp_with_minmax(p0: i64, l0: i32, r0: i32, q: SQ, mr: i64) -> i32 {
    let ity = get_compare_ty(l0);
    var p = p0;
    var l = l0;
    var r = r0;
    var a: i32 = -1;
    var b: i32 = -1;
    var pp: i64 = -1;
    var eqp: i64 = -1;
    if m_minmax(l, 0) && (mm_a == r || mm_b == r) {
        a = mm_a; b = mm_b; if a != r { let t = a; a = b; b = t; } eqp = P_SGE; pp = p;
    } else if m_minmax(r, 0) && (mm_a == l || mm_b == l) {
        a = mm_a; b = mm_b; if a != l { let t = a; a = b; b = t; } eqp = P_SGE; pp = pred_swapped(p);
    } else if m_minmax(l, 1) && (mm_a == r || mm_b == r) {
        a = mm_a; b = mm_b; if a != r { let t = a; a = b; b = t; } eqp = P_SLE; pp = pred_swapped(p);
    } else if m_minmax(r, 1) && (mm_a == l || mm_b == l) {
        a = mm_a; b = mm_b; if a != l { let t = a; a = b; b = t; } eqp = P_SLE; pp = p;
    }
    if pp >= 0 {
        let v = minmax_case(pp, eqp, a, b, l, r, q, mr, true);
        if v >= 0 { return v; }
    }
    pp = -1;
    if m_minmax(l, 2) && (mm_a == r || mm_b == r) {
        a = mm_a; b = mm_b; if a != r { let t = a; a = b; b = t; } eqp = P_UGE; pp = p;
    } else if m_minmax(r, 2) && (mm_a == l || mm_b == l) {
        a = mm_a; b = mm_b; if a != l { let t = a; a = b; b = t; } eqp = P_UGE; pp = pred_swapped(p);
    } else if m_minmax(l, 3) && (mm_a == r || mm_b == r) {
        a = mm_a; b = mm_b; if a != r { let t = a; a = b; b = t; } eqp = P_ULE; pp = pred_swapped(p);
    } else if m_minmax(r, 3) && (mm_a == l || mm_b == l) {
        a = mm_a; b = mm_b; if a != l { let t = a; a = b; b = t; } eqp = P_ULE; pp = p;
    }
    if pp >= 0 {
        let v = minmax_case(pp, eqp, a, b, l, r, q, mr, false);
        if v >= 0 { return v; }
    }
    if m_minmax(l, 3) || m_minmax(l, 1) { let t = l; l = r; r = t; p = pred_swapped(p); }
    if m_minmax(l, 0) {
        let la = mm_a;
        let lb = mm_b;
        if m_minmax(r, 1) {
            let rc = mm_a;
            let rd = mm_b;
            if la == rc || la == rd || lb == rc || lb == rd {
                if p == P_SGE { return get_true(ity); }
                if p == P_SLT { return get_false(ity); }
                return -1;
            }
        }
    }
    if m_minmax(l, 2) {
        let la = mm_a;
        let lb = mm_b;
        if m_minmax(r, 3) {
            let rc = mm_a;
            let rd = mm_b;
            if la == rc || la == rd || lb == rc || lb == rd {
                if p == P_UGE { return get_true(ity); }
                if p == P_ULT { return get_false(ity); }
            }
        }
    }
    return -1;
}

fn simplify_icmp_with_intrinsic_on_lhs(p: i64, l: i32, r: i32) -> i32 {
    let id = inst_iid(l);
    if id == IID_uadd_sat {
        if m_c_binop_both(r, OP_ADD, cb_arg(l, 0), cb_arg(l, 1)) {
            if p == P_UGE { return get_true(get_compare_ty(l)); }
            if p == P_ULT { return get_false(get_compare_ty(l)); }
        }
        return -1;
    }
    if id == IID_usub_sat {
        if is_op(r, OP_SUB) && op(r, 0) == cb_arg(l, 0) && op(r, 1) == cb_arg(l, 1) {
            if p == P_ULE { return get_true(get_compare_ty(l)); }
            if p == P_UGT { return get_false(get_compare_ty(l)); }
        }
    }
    return -1;
}

// getRange(V, IIQ): range metadata, argument or call range attribute
fn get_range_of(v: i32) -> bool {
    if is_inst(v) {
        let md = inst_get_md(v, md_kind_id("range"));
        if md >= 0 { vt_cr = range_md_cr(md); return true; }
    }
    if is_arg(v) { return arg_range(v); }
    if is_callbase(v) { return call_range(v); }
    return false;
}
// getConstantRangeFromMetadata
fn range_md_cr(md: i32) -> CRange { rg_from_range_md(md) }

// p0 is a CmpPredicate: predicate | samesign << 8 (implied.goose cp()).
recursive fn simplify_icmp(p0: i64, l0: i32, r0: i32, q: SQ, mr: i64) -> i32 {
    let ss = cp_ss(p0);
    var p = cp_pred(p0);
    var l = l0;
    var r = r0;
    if is_constant(l) {
        if is_constant(r) { return cf_fold_cmp_operands(p, l, r, q.cxt); }
        let t = l; l = r; r = t;
        p = pred_swapped(p);
    }
    let ity = get_compare_ty(l);
    if is_poison(r) { return c_poison(ity); }
    if q_undef(q, r) && pred_is_equality(p) { return c_undef(ity); }
    if l == r || q_undef(q, r) { return c_bool_ty(ity, pred_true_when_eq(p)); }
    var v = simplify_icmp_of_bools(p, l, r, q);
    if v >= 0 { return v; }
    v = simplify_icmp_with_zero(p, l, r, q);
    if v >= 0 { return v; }
    v = simplify_icmp_with_constant(p, l, r, q);
    if v >= 0 { return v; }
    if get_range_of(r) {
        let rcr = vt_cr;
        if get_range_of(l) {
            let lcr = vt_cr;
            if rg_icmp(p, lcr, rcr) { return get_true(ity); }
            if rg_icmp(pred_inverse(p), lcr, rcr) { return get_false(ity); }
        }
    }
    if is_inst(l) && is_cast_op(iop(l)) && (is_constant(r) || (is_inst(r) && is_cast_op(iop(r)))) {
        let li = l;
        let src = op(li, 0);
        let st = vals[src].ty;
        let dt = vals[li].ty;
        let lo = iop(li);
        if mr > 0 && (lo == OP_PTRTOINT || lo == OP_PTRTOADDR) && address_type_of(st) == dt {
            if is_constant(r) {
                v = simplify_icmp(p, src, ce_cast(OP_INTTOPTR, r, st), q, mr - 1);
                if v >= 0 { return v; }
            } else if is_inst(r) && (iop(r) == OP_PTRTOINT || iop(r) == OP_PTRTOADDR) {
                if vals[op(r, 0)].ty == st {
                    v = simplify_icmp(p, src, op(r, 0), q, mr - 1);
                    if v >= 0 { return v; }
                }
            }
        }
        if lo == OP_ZEXT {
            if is_inst_op(r, OP_ZEXT) {
                if mr > 0 && st == vals[op(r, 0)].ty {
                    v = simplify_icmp(pred_unsigned(p), src, op(r, 0), q, mr - 1);
                    if v >= 0 { return v; }
                }
            } else if is_inst_op(r, OP_SEXT) {
                if src == op(r, 0) {
                    if p == P_ULE || p == P_SGE { return get_true(ity); }
                    if p == P_UGT || p == P_SLT { return get_false(ity); }
                }
            } else if m_imm_constant(r) {
                let c = r;
                let tr = cf_fold_cast_operand(OP_TRUNC, c, st);
                let rext = cf_fold_cast_operand(OP_ZEXT, tr, dt);
                let anyeq = cf_fold_cmp_operands(P_EQ, rext, c, -1);
                if is_all_ones_value(anyeq) && mr > 0 {
                    v = simplify_icmp(pred_unsigned(p), src, tr, q, mr - 1);
                    if v >= 0 { return v; }
                }
                if is_null_value(anyeq) {
                    if p == P_EQ || p == P_UGT || p == P_UGE { return c_null(ity); }
                    if p == P_NE || p == P_ULT || p == P_ULE { return c_all_ones(ity); }
                    if p == P_SGT || p == P_SGE { return cf_fold_cmp_operands(P_SLT, c, c_null(vals[c].ty), -1); }
                    if p == P_SLT || p == P_SLE { return cf_fold_cmp_operands(P_SGE, c, c_null(vals[c].ty), -1); }
                }
            }
        }
        if lo == OP_SEXT {
            if is_inst_op(r, OP_SEXT) {
                if mr > 0 && st == vals[op(r, 0)].ty {
                    v = simplify_icmp(p, src, op(r, 0), q, mr - 1);
                    if v >= 0 { return v; }
                }
            } else if is_inst_op(r, OP_ZEXT) {
                if src == op(r, 0) {
                    if p == P_UGE || p == P_SLE { return get_true(ity); }
                    if p == P_ULT || p == P_SGT { return get_false(ity); }
                }
            } else if m_imm_constant(r) {
                let c = r;
                let tr = cf_fold_cast_operand(OP_TRUNC, c, st);
                let rext = cf_fold_cast_operand(OP_SEXT, tr, dt);
                let anyeq = cf_fold_cmp_operands(P_EQ, rext, c, -1);
                if is_all_ones_value(anyeq) && mr > 0 {
                    v = simplify_icmp(p, src, tr, q, mr - 1);
                    if v >= 0 { return v; }
                }
                if is_null_value(anyeq) {
                    if p == P_EQ { return c_null(ity); }
                    if p == P_NE { return c_all_ones(ity); }
                    if p == P_SGT || p == P_SGE { return cf_fold_cmp_operands(P_SLT, c, c_null(vals[c].ty), -1); }
                    if p == P_SLT || p == P_SLE { return cf_fold_cmp_operands(P_SGE, c, c_null(vals[c].ty), -1); }
                    if p == P_UGT || p == P_UGE {
                        if mr > 0 { v = simplify_icmp(P_SLT, src, c_null(st), q, mr - 1); if v >= 0 { return v; } }
                    } else if p == P_ULT || p == P_ULE {
                        if mr > 0 { v = simplify_icmp(P_SGE, src, c_null(st), q, mr - 1); if v >= 0 { return v; } }
                    }
                }
            }
        }
    }
    if pred_is_equality(p) && !m_zero(r) && q_nonequal(l, r, q) { return if p == P_NE { get_true(ity) } else { get_false(ity) }; }
    v = simplify_icmp_with_binop(p, l, r, q, mr);
    if v >= 0 { return v; }
    v = simplify_icmp_with_minmax(p, l, r, q, mr);
    if v >= 0 { return v; }
    v = simplify_icmp_with_intrinsic_on_lhs(p, l, r);
    if v >= 0 { return v; }
    v = simplify_icmp_with_intrinsic_on_lhs(pred_swapped(p), r, l);
    if v >= 0 { return v; }
    v = simplify_icmp_using_monotonic(p, l, r, q);
    if v >= 0 { return v; }
    v = simplify_icmp_using_monotonic(pred_swapped(p), r, l, q);
    if v >= 0 { return v; }
    // simplifyICmpWithDominatingAssume
    if q.cxt >= 0 {
        kb_cxt = q.cxt;
        let da = icmp_from_dominating_assume(cp(p, ss), l, r);
        if da >= 0 { return c_bool_ty(ity, da == 1); }
    }
    let imp = implied_by_dom_condition_cp(cp(p, ss), l, r, q.cxt);
    if imp >= 0 { return c_bool_ty(ity, imp == 1); }
    if ty_kind(vals[l].ty) == TK_PTR {
        let c = compute_pointer_icmp(p, l, r, q);
        if c >= 0 { return c; }
    }
    if is_select(l) || is_select(r) {
        v = thread_cmp_over_select(p, l, r, q, mr);
        if v >= 0 { return v; }
    }
    if is_phi_v(l) || is_phi_v(r) {
        v = thread_cmp_over_phi(p, l, r, q, mr);
        if v >= 0 { return v; }
    }
    return -1;
}

// DataLayout::getAddressType(PtrTy): integer of the address (= index) width, vector-shaped like the input
fn address_type_of(t: i32) -> i32 {
    let s = ty_scalar(t);
    let it = ty_int(dl_ptr(types[s].n as i64).idx);
    if ty_is_vector(t) { return ty_vector(it, ty_count(t), ty_kind(t) == TK_SVEC); }
    return it;
}

// ---------------------------------------------------------------------------------------------
// FCmp

recursive fn simplify_fcmp(p0: i64, l0: i32, r0: i32, fmf: u8, q: SQ, mr: i64) -> i32 {
    var p = p0;
    var l = l0;
    var r = r0;
    if is_constant(l) {
        if is_constant(r) {
            let res = cf_fold_cmp_operands(p, l, r, q.cxt);
            if res >= 0 { return res; }
        } else {
            let t = l; l = r; r = t;
            p = pred_swap_any(p);
        }
    }
    let rty = get_compare_ty(l);
    if p == 0 { return get_false(rty); }
    if p == 15 { return get_true(rty); }
    if is_poison(l) || is_poison(r) { return c_poison(rty); }
    if q_undef(q, l) || q_undef(q, r) { return c_bool_ty(rty, fpred_is_unordered(p)); }
    if l == r {
        if pred_true_when_eq(p) { return get_true(rty); }
        if pred_false_when_eq(p) { return get_false(rty); }
    }
    let nnan = (fmf & FMF_NNAN) != 0;
    if p == 7 || p == 8 {
        let rc = q_fpclass(r, FCL_ALL, 0, q);
        let lc = q_fpclass(l, FCL_ALL, 0, q);
        if nnan || (kfc_never_nan(rc) && kfc_never_nan(lc)) { return c_bool_ty(rty, p == 7); }
        if kfc_always_nan(rc) || kfc_always_nan(lc) { return c_bool_ty(rty, p == 8); }
    }
    let imp = fcmp_implied_by_dom(p, l, r, q);
    if imp >= 0 { return c_bool_ty(rty, imp == 1); }
    let c = m_apfloat_ap(r, true);
    var have_full = false;
    var full: KFC = kfc_unknown();
    if c >= 0 && q.cxt >= 0 {
        let fv = inst_func(q.cxt);
        let cv, ct = fcmp_to_class_test(p, fv, l, c);
        if cv >= 0 {
            full = q_fpclass(l, FCL_ALL, fmf, q);
            have_full = true;
            if (full.known & ct) == 0 { return get_false(rty); }
            if (full.known & ~ct & FCL_ALL) == 0 { return get_true(rty); }
        }
    }
    if c >= 0 {
        let cp0 = cfp_parts(c);
        if cp0.cat == FC_NAN { return c_bool_ty(rty, fpred_is_unordered(p)); }
        if cp0.neg && cp0.cat != FC_ZERO {
            let interested = FCL_ORDERED_LT_ZERO_MASK;
            if p == 11 || p == 10 || p == 14 {
                let kc = if have_full { full } else { q_fpclass(l, interested, fmf, q) };
                if kfc_cannot_be_ordered_lt_zero(kc) { return get_true(rty); }
            } else if p == 1 || p == 5 || p == 4 {
                let kc = if have_full { full } else { q_fpclass(l, interested, fmf, q) };
                if kfc_cannot_be_ordered_lt_zero(kc) { return get_false(rty); }
            }
        }
        // m_FMaxNum_or_FMaximumNum(m_Value(), m_APFloat(C2)) / min
        let id = inst_iid(l);
        var is_max = false;
        var is_min = false;
        var c2: i32 = -1;
        if id == IID_maxnum || id == IID_maximumnum { c2 = m_apfloat(op(l, 1)); is_max = c2 >= 0; }
        if id == IID_minnum || id == IID_minimumnum { c2 = m_apfloat(op(l, 1)); is_min = c2 >= 0; }
        if (is_max && fp_cmp_gt(c2, c)) || (is_min && fp_cmp_lt(c2, c)) {
            if p == 1 || p == 9 { return get_false(rty); }
            if p == 6 || p == 14 { return get_true(rty); }
            if p == 3 || p == 11 || p == 2 || p == 10 { return c_bool_ty(rty, is_max); }
            if p == 5 || p == 13 || p == 4 || p == 12 { return c_bool_ty(rty, !is_max); }
        }
    }
    if m_any_zero_fp(r) {
        if p == 3 || p == 12 {
            var interested = FCL_ORDERED_LT_ZERO_MASK;
            if !nnan { interested |= FCL_NAN; }
            let k = if have_full { full } else { q_fpclass(l, interested, fmf, q) };
            if (nnan || kfc_never_nan(k)) && kfc_cannot_be_ordered_lt_zero(k) { return if p == 3 { get_true(rty) } else { get_false(rty) }; }
        } else if p == 11 || p == 4 {
            let k = if have_full { full } else { q_fpclass(l, FCL_ORDERED_LT_ZERO_MASK, fmf, q) };
            if kfc_cannot_be_ordered_lt_zero(k) { return if p == 11 { get_true(rty) } else { get_false(rty) }; }
        }
    }
    if is_select(l) || is_select(r) {
        let v = thread_cmp_over_select(p, l, r, q, mr);
        if v >= 0 { return v; }
    }
    if is_phi_v(l) || is_phi_v(r) {
        let v = thread_cmp_over_phi(p, l, r, q, mr);
        if v >= 0 { return v; }
    }
    return -1;
}

// isImpliedByDomCondition for fcmp predicates
fn fcmp_implied_by_dom(p: i64, l: i32, r: i32, q: SQ) -> i64 {
    let cx = q.cxt;
    if cx < 0 { return -1; }
    let bb = inst_parent(cx);
    let pb = single_pred(bb);
    if pb < 0 { return -1; }
    let t = block_terminator(pb);
    if iop(t) != OP_CONDBR { return -1; }
    if op(t, 1) == op(t, 2) { return -1; }
    return implied_condition_fcmp(op(t, 0), p, l, r, op(t, 1) == bb);
}

recursive fn simplify_cmp(p: i64, l: i32, r: i32, q: SQ, mr: i64) -> i32 {
    if cp_pred(p) >= 32 { return simplify_icmp(p, l, r, q, mr); }
    return simplify_fcmp(p, l, r, 0, q, mr);
}

// ---------------------------------------------------------------------------------------------
// simplifyWithOpsReplaced

// isNotCrossLaneOperation
fn is_not_cross_lane(i: i32) -> bool {
    let id = inst_iid(i);
    if id != 0 { return is_trivially_vectorizable(id); }
    let o = iop(i);
    if o == OP_SHUFFLEVECTOR && !shuffle_is_select(i) { return false; }
    return !is_callbase(i) && o != OP_BITCAST && o != OP_EXTRACTELEMENT;
}
// isTriviallyVectorizable (VectorUtils.cpp)
fn is_trivially_vectorizable(id: i32) -> bool {
    return id == IID_abs || id == IID_bswap || id == IID_bitreverse || id == IID_ctpop || id == IID_ctlz || id == IID_cttz ||
        id == IID_fshl || id == IID_fshr || id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin ||
        id == IID_sadd_sat || id == IID_ssub_sat || id == IID_uadd_sat || id == IID_usub_sat || id == IID_smul_fix ||
        id == IID_smul_fix_sat || id == IID_umul_fix || id == IID_umul_fix_sat || id == IID_uadd_with_overflow ||
        id == IID_sadd_with_overflow || id == IID_usub_with_overflow || id == IID_ssub_with_overflow ||
        id == IID_umul_with_overflow || id == IID_smul_with_overflow || id == IID_sqrt || id == IID_asin || id == IID_acos ||
        id == IID_atan || id == IID_atan2 || id == IID_sin || id == IID_cos || id == IID_sincos || id == IID_sincospi ||
        id == IID_tan || id == IID_sinh || id == IID_cosh || id == IID_tanh || id == IID_exp || id == IID_exp10 ||
        id == IID_exp2 || id == IID_frexp || id == IID_ldexp || id == IID_log || id == IID_log10 || id == IID_log2 ||
        id == IID_fabs || id == IID_minnum || id == IID_maxnum || id == IID_minimum || id == IID_maximum ||
        id == IID_minimumnum || id == IID_maximumnum || id == IID_modf || id == IID_copysign || id == IID_floor ||
        id == IID_ceil || id == IID_trunc || id == IID_rint || id == IID_nearbyint || id == IID_round ||
        id == IID_roundeven || id == IID_pow || id == IID_fma || id == IID_fmuladd || id == IID_is_fpclass ||
        id == IID_powi || id == IID_canonicalize || id == IID_fptosi_sat || id == IID_fptoui_sat || id == IID_lround ||
        id == IID_llround || id == IID_lrint || id == IID_llrint || id == IID_ucmp || id == IID_scmp || id == IID_clmul;
}

// The DropFlags vector of simplifyWithOpReplaced: on when the caller passes one (InstCombine's
// foldSelectValueEquivalence); the instructions whose poison-generating annotations must be dropped.
var swo_drop_on: bool = false;
var swo_drop: i32[>..<];
// Ops pairs live on is_ops at [pm .. pm + 2*np) as (from, to)
recursive fn simplify_with_ops_replaced(v: i32, pmk: i64, np: i64, q: SQ, allow_ref: bool, mr0: i64) -> i32 {
    for k in np {
        let from = is_ops[pmk + 2 * k];
        if is_constant(from) { return -1; }
        if v == from { return is_ops[pmk + 2 * k + 1]; }
    }
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    if !is_inst(v) { return -1; }
    let i = v;
    if iop(i) == OP_PHI { return -1; }
    if inst_iid(i) == IID_is_constant { return -1; }
    if iop(i) == OP_FREEZE { return -1; }
    for k in np {
        let from = is_ops[pmk + 2 * k];
        if ty_is_vector(vals[from].ty) && !is_not_cross_lane(i) { return -1; }
    }
    let n = nops(i);
    let mark = is_ops.len;
    var any = false;
    for k in n {
        let iop_v = op(i, k);
        let nv = simplify_with_ops_replaced(iop_v, pmk, np, q, allow_ref, mr);
        if nv >= 0 {
            is_ops.push(nv);
            any = iop_v != nv;
        } else {
            is_ops.push(iop_v);
        }
        let last = is_ops[is_ops.len - 1];
        if is_undef_val(last) && !q.undef { is_ops.resize(mark); return -1; }
    }
    if !any { is_ops.resize(mark); return -1; }
    let o = iop(i);
    if !allow_ref {
        if is_binary_op(o) {
            let n0 = is_ops[mark];
            let n1 = is_ops[mark + 1];
            if !is_fp_or_fp_vec(vals[i].ty) {
                if n0 == binop_identity(o, vals[i].ty, false) { is_ops.resize(mark); return n1; }
                if n1 == binop_identity(o, vals[i].ty, true) { is_ops.resize(mark); return n0; }
            }
            if (o == OP_AND || o == OP_OR) && n0 == n1 {
                if o == OP_OR && op_disjoint(i) {
                    if !swo_drop_on { is_ops.resize(mark); return -1; }
                    swo_drop.push(i);
                }
                is_ops.resize(mark);
                return n0;
            }
            if (o == OP_SUB || o == OP_XOR) && n0 == n1 {
                var anyrep = false;
                for k in np { if n0 == is_ops[pmk + 2 * k + 1] { anyrep = true; } }
                if anyrep { is_ops.resize(mark); return c_null(vals[i].ty); }
            }
            let ab = binop_absorber(o, vals[i].ty, false);
            if ab >= 0 && (n0 == ab || n1 == ab) {
                var ip = false;
                for k in np { if implies_poison(i, is_ops[pmk + 2 * k]) { ip = true; } }
                if ip { is_ops.resize(mark); return ab; }
            }
        }
        let id = inst_iid(i);
        if id != 0 {
            let n0 = is_ops[mark];
            let n1 = if n > 1 { is_ops[mark + 1] } else { -1 };
            if (id == IID_scmp || id == IID_ucmp) && n0 == n1 {
                if has_poison_generating_annotations(i) {
                    if !swo_drop_on { is_ops.resize(mark); return -1; }
                    swo_drop.push(i);
                }
                is_ops.resize(mark);
                return c_int_ty(vals[i].ty, 0);
            }
            if id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin {
                let w = ty_scalar_bits(vals[i].ty);
                let ident = minmax_identity(id, w);
                var res: i32 = -1;
                if m_specific_int_apv(n0, ident) { res = n1; }
                else if m_specific_int_apv(n1, ident) { res = n0; }
                if res >= 0 {
                    if has_poison_generating_annotations(i) {
                        if !swo_drop_on { is_ops.resize(mark); return -1; }
                        swo_drop.push(i);
                    }
                    is_ops.resize(mark);
                    return res;
                }
            }
        }
        if o == OP_GEP {
            if n == 2 && m_zero(is_ops[mark + 1]) { let r = is_ops[mark]; is_ops.resize(mark); return r; }
        }
    } else {
        let s = simplify_inst_with_ops(i, mark, n, q, mr);
        is_ops.resize(mark);
        if s == v { return -1; }
        return s;
    }
    for k in n { if !is_constant(is_ops[mark + k]) { is_ops.resize(mark); return -1; } }
    if !allow_ref {
        let id = inst_iid(i);
        if can_create_poison(i, !swo_drop_on) {
            if id == IID_abs {
                if !is_not_min_signed_value(is_ops[mark]) { is_ops.resize(mark); return -1; }
            } else { is_ops.resize(mark); return -1; }
        }
        if swo_drop_on && (id == IID_abs || id == IID_ctlz || id == IID_cttz) { is_ops[mark + 1] = c_bool_ty(T_I1, false); }
        let r = cf_fold_inst_operands(i, mark, n, false);
        is_ops.resize(mark);
        if swo_drop_on && r >= 0 && has_poison_generating_annotations(i) { swo_drop.push(i); }
        return r;
    }
    let r = cf_fold_inst_operands(i, mark, n, false);
    is_ops.resize(mark);
    return r;
}

// MinMaxIntrinsic::getIdentity
fn minmax_identity(id: i32, w: i64) -> AP {
    if id == IID_umax { return ap_zero(w); }
    if id == IID_umin { return ap_ones(w); }
    if id == IID_smax { return ap_smin_val(w); }
    return ap_smax_val(w);
}
// MinMaxIntrinsic::getSaturationPoint
fn minmax_saturation_ap(id: i32, w: i64) -> AP {
    if id == IID_umax { return ap_ones(w); }
    if id == IID_umin { return ap_zero(w); }
    if id == IID_smax { return ap_smax_val(w); }
    return ap_smin_val(w);
}
fn minmax_pred(id: i32) -> i64 { if id == IID_umax { P_UGT } else if id == IID_umin { P_ULT } else if id == IID_smax { P_SGT } else { P_SLT } }
fn inverse_minmax_iid(id: i32) -> i32 {
    if id == IID_umax { return IID_umin; }
    if id == IID_umin { return IID_umax; }
    if id == IID_smax { return IID_smin; }
    if id == IID_smin { return IID_smax; }
    if id == IID_maxnum { return IID_minnum; }
    if id == IID_minnum { return IID_maxnum; }
    if id == IID_maximum { return IID_minimum; }
    if id == IID_minimum { return IID_maximum; }
    if id == IID_maximumnum { return IID_minimumnum; }
    if id == IID_minimumnum { return IID_maximumnum; }
    return 0;
}

// Constant::isNotMinSignedValue
recursive fn is_not_min_signed_value(c: i32) -> bool {
    let k = vals[c].kind;
    if k == VK_CINT && !ty_is_vector(vals[c].ty) { return !ap_is_min_signed(ci_ap(c)); }
    if ty_kind(vals[c].ty) == TK_FVEC && (k == VK_CDVECTOR || k == VK_CVECTOR) {
        for i in ty_count(vals[c].ty) {
            let e = agg_elem(c, i);
            if e < 0 || !is_not_min_signed_value(e) { return false; }
        }
        return true;
    }
    if ty_is_vector(vals[c].ty) {
        let s = splat_value(c, false);
        if s >= 0 { return is_not_min_signed_value(s); }
    }
    if k == VK_CFP { return true; }
    return false;
}

recursive fn simplify_with_op_replaced(v: i32, from: i32, to: i32, q: SQ, allow_ref: bool, mr: i64) -> i32 {
    let pmk = is_ops.len;
    is_ops.push(from);
    is_ops.push(to);
    let r = simplify_with_ops_replaced(v, pmk, 1, q, allow_ref, mr);
    is_ops.resize(pmk);
    return r;
}
// public entry (refinement off => undef folds off)
fn simplify_with_op_replaced_api(v: i32, from: i32, to: i32, cxt: i32, allow_ref: bool) -> i32 {
    var q = sq_new(cxt);
    if !allow_ref { q = sq_without_undef(q); }
    return simplify_with_op_replaced(v, from, to, q, allow_ref, RECURSION_LIMIT);
}

// ---------------------------------------------------------------------------------------------
// Select

fn simplify_select_bit_test(t: i32, f: i32, x: i32, y: AP, true_when_unset: bool) -> i32 {
    if f == x && is_op(t, OP_AND) && op(t, 0) == x {
        let c = m_apint(op(t, 1));
        if c >= 0 && ap_eq(y, ap_not(ci_ap(c))) { return if true_when_unset { f } else { t }; }
    }
    if t == x && is_op(f, OP_AND) && op(f, 0) == x {
        let c = m_apint(op(f, 1));
        if c >= 0 && ap_eq(y, ap_not(ci_ap(c))) { return if true_when_unset { f } else { t }; }
    }
    if ap_is_pow2(y) {
        if f == x && is_op(t, OP_OR) && op(t, 0) == x {
            let c = m_apint(op(t, 1));
            if c >= 0 && ap_eq(y, ci_ap(c)) {
                if true_when_unset && op_disjoint(t) { return -1; }
                return if true_when_unset { t } else { f };
            }
        }
        if t == x && is_op(f, OP_OR) && op(f, 0) == x {
            let c = m_apint(op(f, 1));
            if c >= 0 && ap_eq(y, ci_ap(c)) {
                if !true_when_unset && op_disjoint(f) { return -1; }
                return if true_when_unset { t } else { f };
            }
        }
    }
    return -1;
}

fn shuffle_is_select(v: i32) -> bool {
    // ShuffleVectorInst::isSelect: mask selects each lane i from either op0[i] or op1[i], same length
    let x = insts[inst_of(v)];
    let n = ty_count(vals[op(v, 0)].ty);
    if x.naux != n { return false; }
    var used0 = false;
    var used1 = false;
    for k in x.naux {
        let mv = ints[x.aux + k] as i64;
        if mv < 0 { continue; }
        if mv == k { used0 = true; } else if mv == k + n { used1 = true; } else { return false; }
    }
    return used0 && used1;
}

fn simplify_cmp_sel_of_maxmin(cl0: i32, cr0: i32, p0: i64, tv0: i32, fv0: i32) -> i32 {
    var cl = cl0;
    var cr = cr0;
    var p = p0;
    var tv = tv0;
    var fv = fv0;
    if cr == tv || cr == fv { let t = cl; cl = cr; cr = t; p = pred_swapped(p); }
    if cl == fv { let t = tv; tv = fv; fv = t; p = pred_inverse(p); }
    let x = cl;
    let y = cr;
    var peeked = false;
    if is_inst_op(fv, OP_SHUFFLEVECTOR) && shuffle_is_select(fv) {
        if op(fv, 0) == y { fv = op(fv, 1); }
        else if op(fv, 1) == y { fv = op(fv, 0); }
        else { return -1; }
        peeked = true;
    }
    let id = inst_iid(fv);
    let is_mm = id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin;
    if !is_mm || tv != x || !(m_max_or_min(fv) && ((mm_a == x && mm_b == y) || (mm_a == y && mm_b == x))) { return -1; }
    let mmp = minmax_pred(id);
    if mmp == pred_strict(p) { return fv; }
    if peeked { return -1; }
    if p == P_EQ { return fv; }
    if p == P_NE { return x; }
    let inv = pred_inverse(p);
    if mmp == pred_strict(inv) { return x; }
    return -1;
}

// decomposeBitTest (CmpInstAnalysis.cpp, LookThroughTrunc = true, AllowNonZeroC = false,
// DecomposeAnd = false): returns true with dbt_x / dbt_mask / dbt_pred
var dbt_x: i32 = -1;
var dbt_mask: AP = AP { lo: 0, w: 1, ix: -1 };
var dbt_pred: i64 = 0;
fn decompose_bit_test(cond: i32) -> bool {
    if is_inst_op(cond, OP_ICMP) {
        if !is_int_or_int_vec(vals[op(cond, 0)].ty) { return false; }
        return decompose_bit_test_icmp(op(cond, 0), op(cond, 1), inst_pred(cond));
    }
    if is_int_or_int_vec_w(vals[cond].ty, 1) {
        var x: i32 = -1;
        var is_trunc = false;
        if is_op(cond, OP_TRUNC) { x = op(cond, 0); is_trunc = true; }
        else {
            let n = m_not(cond);
            if n >= 0 && is_op(n, OP_TRUNC) { x = op(n, 0); }
        }
        if x >= 0 {
            dbt_x = x;
            dbt_mask = ap_u64(1, ty_scalar_bits(vals[x].ty));
            dbt_pred = if is_inst_op(cond, OP_TRUNC) { P_NE } else { P_EQ };
            return true;
        }
    }
    return false;
}
// decomposeBitTestICmp(LHS, RHS, Pred, LookThroughTrunc = true, AllowNonZeroC = false, DecomposeAnd = false)
fn decompose_bit_test_icmp(lhs: i32, rhs: i32, p0: i64) -> bool {
    var p = p0;
    if pred_is_equality(p) { return false; }
    let oc = m_apint_ap(rhs, true);
    if oc < 0 { return false; }
    let w = ci_w(oc);
    var inverted = false;
    if p == P_UGT || p == P_SGT || p == P_UGE || p == P_SGE { inverted = true; p = pred_inverse(p); }
    var c = ci_ap(oc);
    if p == P_ULE || p == P_SLE {
        if (if pred_is_signed(p) { ap_is_max_signed(c) } else { ap_is_all_ones(c) }) { return false; }
        c = ap_inc(c);
        p = pred_strict(p);
    }
    var mask = ap_zero(w);
    var rc = ap_zero(w);
    var rp: i64 = 0;
    if p == P_SLT {
        if ap_is_zero(c) { mask = ap_smin_val(w); rp = P_NE; }
        else {
            let fs = ap_xor(c, ap_smin_val(w));
            if ap_is_pow2(fs) { mask = ap_neg(fs); rc = ap_smin_val(w); rp = P_EQ; }
            else if ap_is_neg_pow2(fs) { mask = fs; rc = c; rp = P_NE; }
            else { return false; }
        }
    } else if p == P_ULT {
        if ap_is_pow2(c) { mask = ap_neg(c); rp = P_EQ; }
        else if ap_is_neg_pow2(c) { mask = c; rc = c; rp = P_NE; }
        else { return false; }
    } else { return false; }
    if !ap_is_zero(rc) { return false; }
    if inverted { rp = pred_inverse(rp); }
    if is_op(lhs, OP_TRUNC) {
        let x = op(lhs, 0);
        dbt_x = x;
        mask = ap_zext(mask, ty_scalar_bits(vals[x].ty));
    } else {
        dbt_x = lhs;
    }
    dbt_mask = mask;
    dbt_pred = rp;
    return true;
}

recursive fn simplify_select_with_bit_test(c: i32, t: i32, f: i32) -> i32 {
    if decompose_bit_test(c) {
        return simplify_select_bit_test(t, f, dbt_x, dbt_mask, dbt_pred == P_EQ);
    }
    return -1;
}

recursive fn simplify_select_with_equivalence(pmk: i64, np: i64, t: i32, f: i32, q: SQ, mr: i64) -> i32 {
    var sf = simplify_with_ops_replaced(f, pmk, np, sq_without_undef(q), false, mr);
    if sf < 0 { sf = f; }
    var st = simplify_with_ops_replaced(t, pmk, np, q, true, mr);
    if st < 0 { st = t; }
    if sf == st { return f; }
    return -1;
}
recursive fn select_equiv1(from: i32, to: i32, t: i32, f: i32, q: SQ, mr: i64) -> i32 {
    let pmk = is_ops.len;
    is_ops.push(from);
    is_ops.push(to);
    let r = simplify_select_with_equivalence(pmk, 1, t, f, q, mr);
    is_ops.resize(pmk);
    return r;
}
recursive fn select_equiv2(f1: i32, t1: i32, f2: i32, t2: i32, t: i32, f: i32, q: SQ, mr: i64) -> i32 {
    let pmk = is_ops.len;
    is_ops.push(f1);
    is_ops.push(t1);
    is_ops.push(f2);
    is_ops.push(t2);
    let r = simplify_select_with_equivalence(pmk, 2, t, f, q, mr);
    is_ops.resize(pmk);
    return r;
}

// canReplacePointersIfEqual / isPointerAlwaysReplaceable (Loads.cpp)
fn can_replace_pointers_if_equal(from: i32, to: i32) -> bool {
    if !is_ptr_or_ptr_vec(vals[from].ty) { return true; }
    if vals[to].kind == VK_CNULL { return true; }
    if vals[from].kind == VK_CNULL && ptr_as(vals[from].ty) == 0 { return true; }
    if is_constant(to) && ty_kind(vals[to].ty) == TK_PTR && const_is_dereferenceable(to) { return true; }
    return get_underlying_object_aggressive(from) == get_underlying_object_aggressive(to);
}
// isDereferenceablePointer(To, i8) for a constant pointer
fn const_is_dereferenceable(c: i32) -> bool {
    if is_gvar(c) {
        let b, cbn = pointer_deref_bytes(c);
        return b >= 1 && !cbn;
    }
    if vals[c].kind == VK_FUNC || vals[c].kind == VK_UNDEF || vals[c].kind == VK_POISON { return false; }
    if is_cexpr(c) && cexpr_op(c) == OP_INTTOPTR { return false; }
    if is_global(c) { return false; }
    if is_cexpr(c) { is_not_ported("isDereferenceablePointer of a constant expression"); }
    return false;
}

recursive fn simplify_select_with_icmp_cond(c: i32, t0: i32, f0: i32, q: SQ, mr: i64) -> i32 {
    if !is_op(c, OP_ICMP) { return -1; }
    var t = t0;
    var f = f0;
    var p = cmp_pred_of(c);
    let cl = op(c, 0);
    let cr = op(c, 1);
    var v = simplify_cmp_sel_of_maxmin(cl, cr, p, t, f);
    if v >= 0 { return v; }
    if p == P_NE { p = P_EQ; let x = t; t = f; f = x; }
    if is_int_or_int_vec(vals[t].ty) && is_inst(c) {
        // matchDecomposedSelectPattern(CmpI, TrueVal, FalseVal, X, Y): the compare's own predicate
        let cpp = inst_pred(c);
        if cpp != P_EQ && cpp != P_NE {
            kb_cxt = q.cxt;
            let spf = match_select_pattern_int(cpp, cl, cr, t, f, 0);
            let x = sp_lhs;
            let y = sp_rhs;
            if spf_is_minmax(spf) && p == spf_minmax_pred(spf) {
                let lim = spf_limit(spf_inverse(spf), ty_scalar_bits(vals[x].ty));
                if m_specific_int_apv(y, lim) { return x; }
            }
        }
    }
    if p == P_EQ && m_zero(cr) {
        if is_op(cl, OP_AND) {
            let y = m_apint(op(cl, 1));
            if y >= 0 {
                v = simplify_select_bit_test(t, f, op(cl, 0), ci_ap(y), true);
                if v >= 0 { return v; }
            }
        }
        // (ShAmt == 0) ? fshl(X, *, ShAmt) : X --> X
        if m_intrinsic(t, IID_fshl) && f == op(t, 0) && cl == op(t, 2) { return f; }
        if m_intrinsic(t, IID_fshr) && f == op(t, 1) && cl == op(t, 2) { return f; }
        if (m_intrinsic(f, IID_fshl) || m_intrinsic(f, IID_fshr)) && op(f, 0) == op(f, 1) && t == op(f, 0) && cl == op(f, 2) && p == P_EQ { return f; }
        fn abs_of(v: i32, x: i32) -> bool { m_intrinsic(v, IID_abs) && op(v, 0) == x }
        if abs_of(t, cl) && m_neg(f) >= 0 && abs_of(m_neg(f), cl) { return f; }
        if m_neg(t) >= 0 && abs_of(m_neg(t), cl) && abs_of(f, cl) { return f; }
    }
    if p == P_EQ {
        if is_int_or_int_vec(vals[cl].ty) || can_replace_pointers_if_equal(cl, cr) {
            v = select_equiv1(cl, cr, t, f, q, mr);
            if v >= 0 { return v; }
        }
        if is_int_or_int_vec(vals[cl].ty) || can_replace_pointers_if_equal(cr, cl) {
            v = select_equiv1(cr, cl, t, f, q, mr);
            if v >= 0 { return v; }
        }
        if is_op(cl, OP_OR) && m_zero(cr) {
            v = select_equiv2(op(cl, 0), cr, op(cl, 1), cr, t, f, q, mr);
            if v >= 0 { return v; }
        }
        if is_op(cl, OP_AND) && m_all_ones(cr) {
            v = select_equiv2(op(cl, 0), cr, op(cl, 1), cr, t, f, q, mr);
            if v >= 0 { return v; }
        }
    }
    return -1;
}

// CmpInst::isEquivalence(Invert) for fcmp
fn fcmp_is_equivalence(c: i32, invert: bool) -> bool {
    let p = if invert { 15 - inst_pred(c) } else { inst_pred(c) };
    if p == 9 && (insts[inst_of(c)].fmf & FMF_NNAN) == 0 { return false; }
    if p == 9 || p == 1 { return fcmp_has_nonzero_fp_operands(c); }
    return false;
}
fn fcmp_has_nonzero_fp_operands(c: i32) -> bool {
    var k = op(c, 0);
    if !is_constant(k) { k = op(c, 1); }
    if !is_constant(k) { return false; }
    return m_cfp_pred(k, FPP_NONZERO_NOT_DENORMAL);
}

recursive fn simplify_select_with_fcmp(c: i32, t0: i32, f0: i32, fmf: u8, q: SQ, mr: i64) -> i32 {
    if !is_op(c, OP_FCMP) { return -1; }
    var t = t0;
    var f = f0;
    var cl = op(c, 0);
    var cr = op(c, 1);
    var p = cmp_pred_of(c);
    if !is_inst(c) { return -1; }
    var equiv = fcmp_is_equivalence(c, false);
    if fcmp_is_equivalence(c, true) { let x = t; t = f; f = x; p = 15 - p; equiv = true; }
    if equiv {
        var v = select_equiv1(cl, cr, t, f, q, mr);
        if v >= 0 { return v; }
        v = select_equiv1(cr, cl, t, f, q, mr);
        if v >= 0 { return v; }
    }
    if cl == f && cr == t { let x = cl; cl = cr; cr = x; }
    if cl != t || cr != f { return -1; }
    if (fmf & FMF_NSZ) != 0 {
        if p == 1 { return f; }
        if p == 14 { return t; }
    }
    return -1;
}

fn incoming_for_block(p: i32, b: i32) -> i32 { op(p, phi_block_index(p, b)) }

fn is_select_with_identical_phi(pn: i32, ipn: i32) -> bool {
    if inst_parent(pn) != inst_parent(ipn) { return false; }
    if nops(pn) != 2 { return false; }
    var diff = 0;
    var diffbb: i32 = -1;
    for i in 2 {
        let pb = phi_block(pn, i);
        if op(pn, i) != incoming_for_block(ipn, pb) { diff++; diffbb = pb; }
    }
    if diff != 1 { return false; }
    let si = incoming_for_block(pn, diffbb);
    let isi = incoming_for_block(ipn, diffbb);
    if !is_select(si) || !is_select(isi) { return false; }
    if op(si, 0) != op(isi, 0) { return false; }
    var siov: i32 = -1;
    var isiov: i32 = -1;
    if op(si, 1) == op(isi, 1) { siov = op(si, 2); isiov = op(isi, 2); }
    else if op(si, 2) == op(isi, 2) { siov = op(si, 1); isiov = op(isi, 1); }
    else { return false; }
    if !is_select(siov) || isiov != ipn { return false; }
    if !(op(siov, 1) == ipn && op(siov, 2) == pn) && !(op(siov, 1) == pn && op(siov, 2) == ipn) { return false; }
    return true;
}

recursive fn simplify_select(c: i32, t: i32, f: i32, fmf: u8, q: SQ, mr: i64) -> i32 {
    if is_constant(c) {
        if is_constant(t) && is_constant(f) {
            let r = cf_select(c, t, f);
            if r >= 0 { return r; }
        }
        if is_poison(c) { return c_poison(vals[t].ty); }
        if q_undef(q, c) { return if is_constant(f) { f } else { t }; }
        if m_one(c) { return t; }
        if m_zero(c) { return f; }
    }
    if vals[c].ty == vals[t].ty {
        if m_one(t) && m_zero_int(f) { return c; }
        if m_c_logical_both(c, true, t, f) { return f; }
        if m_c_logical_both(c, false, t, f) { return t; }
        if m_c_logical_with(c, false, f) >= 0 && m_zero_int(t) { return get_false(vals[c].ty); }
        if m_zero_int(f) {
            let nc = m_not(c);
            if nc >= 0 && m_c_logical_with(nc, false, t) >= 0 { return get_false(vals[c].ty); }
            let nt = m_not(t);
            if nt >= 0 && m_c_logical_with(nt, false, c) >= 0 { return get_false(vals[c].ty); }
            if m_c_logical_with(c, false, t) >= 0 { return t; }
            if m_c_logical_with(t, false, c) >= 0 { return c; }
            // (X || Y) && (X || !Y) --> X
            if m_logical(c, false) {
                let a = lg_a;
                let b = lg_b;
                for s in 2 {
                    let x = if s == 0 { a } else { b };
                    let ny = if s == 0 { b } else { a };
                    let y = m_not(ny);
                    if y >= 0 { if m_c_logical_both(t, false, x, y) { return x; } break; }
                }
            }
            if m_logical(t, false) {
                let a = lg_a;
                let b = lg_b;
                for s in 2 {
                    let x = if s == 0 { a } else { b };
                    let ny = if s == 0 { b } else { a };
                    let y = m_not(ny);
                    if y >= 0 { if m_c_logical_both(c, false, x, y) { return x; } break; }
                }
            }
        }
        if m_one(t) {
            let nc = m_not(c);
            if nc >= 0 && m_c_logical_with(nc, true, f) >= 0 { return get_true(vals[c].ty); }
            let nf = m_not(f);
            if nf >= 0 && m_c_logical_with(nf, true, c) >= 0 { return get_true(vals[c].ty); }
            if m_c_logical_with(c, true, f) >= 0 { return f; }
            if m_c_logical_with(f, true, c) >= 0 { return c; }
        }
    }
    if t == f { return t; }
    if c == t {
        if m_zero_int(f) { return c; }
        if m_one(f) { return get_true(vals[c].ty); }
    }
    if c == f {
        if m_one(t) { return c; }
        if m_zero_int(t) { return get_false(vals[c].ty); }
    }
    if is_poison(t) || (q_undef(q, t) && implies_poison(f, c)) { return f; }
    if is_poison(f) || (q_undef(q, f) && implies_poison(t, c)) { return t; }
    if is_fixed_vec(vals[t].ty) && is_constant(t) && is_constant(f) {
        let n = ty_count(vals[t].ty);
        let mark = is_ops.len;
        for i in n {
            let te = agg_elem(t, i);
            let fe = agg_elem(f, i);
            if te < 0 || fe < 0 { break; }
            if te == fe { is_ops.push(te); }
            else if is_poison(te) || (q_undef(q, te) && is_guaranteed_not_to_be_poison(fe, -1, 0)) { is_ops.push(fe); }
            else if is_poison(fe) || (q_undef(q, fe) && is_guaranteed_not_to_be_poison(te, -1, 0)) { is_ops.push(te); }
            else { break; }
        }
        if is_ops.len - mark == n {
            let r = c_aggregate(vals[t].ty, is_ops[mark..]);
            is_ops.resize(mark);
            return r;
        }
        is_ops.resize(mark);
    }
    var v = simplify_select_with_icmp_cond(c, t, f, q, mr);
    if v >= 0 { return v; }
    v = simplify_select_with_bit_test(c, t, f);
    if v >= 0 { return v; }
    v = simplify_select_with_fcmp(c, t, f, fmf, q, mr);
    if v >= 0 { return v; }
    let imp = implied_by_dom_cond_value(c, q.cxt);
    if imp >= 0 { return if imp == 1 { t } else { f }; }
    if is_phi_v(t) && is_phi_v(f) {
        if is_select_with_identical_phi(t, f) { return f; }
        if is_select_with_identical_phi(f, t) { return t; }
    }
    return -1;
}

// isImpliedByDomCondition(Cond, ContextI, DL)
fn implied_by_dom_cond_value(c: i32, cxt: i32) -> i64 {
    if cxt < 0 { return -1; }
    let bb = inst_parent(cxt);
    let pb = single_pred(bb);
    if pb < 0 { return -1; }
    let t = block_terminator(pb);
    if iop(t) != OP_CONDBR { return -1; }
    if op(t, 1) == op(t, 2) { return -1; }
    return implied_condition_vals(op(t, 0), c, op(t, 1) == bb);
}

// ---------------------------------------------------------------------------------------------
// GEP, aggregates, vectors

// GetElementPtrInst::getIndexedType(SrcTy, Indices[1..])
fn gep_indexed_type(srcty: i32, mark: i64, n: i64) -> i32 {
    var t = srcty;
    for k in 1..n {
        let ix = is_ops[mark + k];
        if ty_is_struct(t) {
            let c = m_apint(ix);
            if c < 0 { return -1; }
            t = ty_field(t, ci_val(c) as i64);
        } else if ty_is_array(t) || ty_is_vector(t) {
            t = types[t].a;
        } else { return -1; }
    }
    return t;
}

// indices are is_ops[mark .. mark+n)
recursive fn simplify_gep(srcty: i32, ptr: i32, mark: i64, n: i64, flags: u8, q: SQ, mr: i64) -> i32 {
    if n == 0 { return ptr; }
    let is_ops_mark = mark - 1;   // is_ops[mark-1] is the pointer slot in the caller's run (not used)
    let last_type = gep_indexed_type_idx(srcty, mark, n);
    var gepty = vals[ptr].ty;
    if !ty_is_vector(gepty) {
        for k in n {
            let it = vals[is_ops[mark + k]].ty;
            if ty_is_vector(it) { gepty = ty_vector(gepty, ty_count(it), ty_kind(it) == TK_SVEC); break; }
        }
    }
    var allz = true;
    for k in n { if !m_zero(is_ops[mark + k]) { allz = false; } }
    if vals[ptr].ty == gepty && allz { return ptr; }
    if is_poison(ptr) { return c_poison(gepty); }
    for k in n { if is_poison(is_ops[mark + k]) { return c_poison(gepty); } }
    if q_undef(q, ptr) { return c_undef(gepty); }
    var scalable = ty_kind(srcty) == TK_SVEC || ty_contains_scalable(srcty);
    for k in n { if ty_kind(vals[is_ops[mark + k]].ty) == TK_SVEC { scalable = true; } }
    if n == 1 {
        let ty = srcty;
        if !scalable && ty_is_sized(ty) {
            let tas = dl_alloc_size(ty);
            if tas == 0 && vals[ptr].ty == gepty { return ptr; }
            let ix0 = is_ops[mark];
            if ty_scalar_bits(vals[ix0].ty) >= dl_ptr(ptr_as(vals[ptr].ty)).idx {
                // getelementptr V, (sub P, V) -> P if size 1
                fn sub_ptr_diff(v: i32, base: i32) -> i32 {
                    if !is_op(v, OP_SUB) { return -1; }
                    let p = m_ptrtoint_or_addr(op(v, 0));
                    let b = m_ptrtoint_or_addr(op(v, 1));
                    if p < 0 || b != base { return -1; }
                    return p;
                }
                fn can_simplify(p: i32, gepty: i32, ptr: i32) -> bool { vals[p].ty == gepty && get_underlying_object(p, 10) == get_underlying_object(ptr, 10) }
                if tas == 1 {
                    let p = sub_ptr_diff(ix0, ptr);
                    if p >= 0 && can_simplify(p, gepty, ptr) { return p; }
                }
                if is_op(ix0, OP_ASHR) {
                    let p = sub_ptr_diff(op(ix0, 0), ptr);
                    let c = m_constant_int(op(ix0, 1));
                    if p >= 0 && c >= 0 && ci_val(c) < 64 && tas as u64 == ((1 as u64) << ci_val(c)) && can_simplify(p, gepty, ptr) { return p; }
                }
                if is_op(ix0, OP_SDIV) {
                    let p = sub_ptr_diff(op(ix0, 0), ptr);
                    if p >= 0 && m_specific_int(op(ix0, 1), tas as u64) && can_simplify(p, gepty, ptr) { return p; }
                }
            }
        }
    }
    if !scalable && last_type >= 0 && ty_is_sized(last_type) && dl_alloc_size(last_type) == 1 {
        var z = true;
        for k in n - 1 { if !m_zero(is_ops[mark + k]) { z = false; } }
        if z {
            let iw = dl_ptr(ptr_as(vals[ptr].ty)).idx;
            let lastix = is_ops[mark + n - 1];
            if dl_size_bits(vals[lastix].ty) == iw {
                let sb = strip_and_accumulate_offsets(ptr, false, false, false);
                let boff = vt_off;
                let ng = m_neg(lastix);
                if ng >= 0 && is_op(ng, OP_PTRTOINT) && op(ng, 0) == sb && boff != 0 {
                    let ci = c_int_words(ty_int(iw), (boff as! u64) & wmask64(iw), 0);
                    return ce_cast(OP_INTTOPTR, ci, gepty);
                }
                if is_binop_match(lastix, OP_XOR) && is_op(op(lastix, 0), OP_PTRTOINT) && op(op(lastix, 0), 0) == sb && m_all_ones(op(lastix, 1)) && boff != 1 {
                    let ci = c_int_words(ty_int(iw), ((boff - 1) as! u64) & wmask64(iw), 0);
                    return ce_cast(OP_INTTOPTR, ci, gepty);
                }
            }
        }
    }
    if !is_constant(ptr) { return -1; }
    for k in n { if !is_constant(is_ops[mark + k]) { return -1; } }
    if ty_contains_scalable(srcty) { return cf_gep(srcty, ptr, is_ops[mark..mark + n], -1); }
    let ce = ce_gep(srcty, ptr, is_ops[mark..mark + n], flags, -1);
    return cf_fold_constant(ce);
}
fn gep_indexed_type_idx(srcty: i32, mark: i64, n: i64) -> i32 {
    // indices start at mark (the first index steps over srcty)
    var t = srcty;
    for k in 1..n {
        let ix = is_ops[mark + k];
        if ty_is_struct(t) {
            let c = m_apint(ix);
            if c < 0 { return -1; }
            t = ty_field(t, ci_val(c) as i64);
        } else if ty_is_array(t) || ty_is_vector(t) { t = types[t].a; }
        else { return -1; }
    }
    return t;
}
recursive fn ty_contains_scalable(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY { return ty_contains_scalable(types[t].a); }
    if k == TK_STRUCT { for i in types[t].cnt { if ty_contains_scalable(ty_field(t, i)) { return true; } } }
    return false;
}

fn extractvalue_indices_eq(a: i32, b: i32) -> bool {
    let x = insts[inst_of(a)];
    let y = insts[inst_of(b)];
    if x.naux != y.naux { return false; }
    for k in x.naux { if ints[x.aux + k] != ints[y.aux + k] { return false; } }
    return true;
}

recursive fn simplify_insertvalue(iv: i32, agg: i32, val: i32, q: SQ) -> i32 {
    let x = insts[inst_of(iv)];
    if is_constant(agg) && is_constant(val) { return cf_insertvalue(agg, val, ints[x.aux..x.aux + x.naux]); }
    if is_poison(val) || (q_undef(q, val) && is_guaranteed_not_to_be_poison(agg, -1, 0)) { return agg; }
    if is_inst_op(val, OP_EXTRACTVALUE) {
        let ev = val;
        let ea = op(ev, 0);
        let y = insts[inst_of(ev)];
        var same = vals[ea].ty == vals[agg].ty && y.naux == x.naux;
        if same { for k in x.naux { if ints[x.aux + k] != ints[y.aux + k] { same = false; } } }
        if same {
            if is_poison(agg) || (q_undef(q, agg) && is_guaranteed_not_to_be_poison(ea, -1, 0)) { return ea; }
            if agg == ea { return agg; }
        }
    }
    return -1;
}

recursive fn simplify_insertelement(vec: i32, val: i32, idx: i32, q: SQ) -> i32 {
    if is_constant(vec) && is_constant(val) && is_constant(idx) { return ce_insertelement(vec, val, idx); }
    let ci = m_constant_int(idx);
    if ci >= 0 && is_fixed_vec(vals[vec].ty) && ap_uge_u64(ci_ap(ci), ty_count(vals[vec].ty) as u64) { return c_poison(vals[vec].ty); }
    if q_undef(q, idx) { return c_poison(vals[vec].ty); }
    if is_poison(val) || (q_undef(q, val) && is_guaranteed_not_to_be_poison(vec, -1, 0)) { return vec; }
    if is_constant(vec) && is_constant(val) && splat_value(vec, false) == val { return vec; }
    if is_op(val, OP_EXTRACTELEMENT) && op(val, 0) == vec && op(val, 1) == idx { return vec; }
    return -1;
}

recursive fn simplify_extractvalue(iv: i32, agg: i32, q: SQ) -> i32 {
    let x = insts[inst_of(iv)];
    if is_constant(agg) { return cf_extractvalue(agg, ints[x.aux..x.aux + x.naux]); }
    let n = x.naux as i64;
    var ivi = agg;
    var gcount = 0;
    while is_inst_op(ivi, OP_INSERTVALUE) {
        gcount++;
        if gcount > 10000 { break; }
        let y = insts[inst_of(ivi)];
        let ni = y.naux as i64;
        let nc = min(ni, n);
        var eq = true;
        for k in nc { if ints[y.aux + k] != ints[x.aux + k] { eq = false; } }
        if eq {
            if n == ni { return op(ivi, 1); }
            break;
        }
        ivi = op(ivi, 0);
        if ivi == agg { break; }
    }
    if n == 1 && m_intrinsic(agg, IID_umul_with_overflow) {
        var v: i32 = -1;
        if m_one(cb_arg(agg, 1)) { v = cb_arg(agg, 0); }
        else if m_one(cb_arg(agg, 0)) { v = cb_arg(agg, 1); }
        if v >= 0 {
            if ints[x.aux] == 0 { return v; }
            return get_false(cmp_result_ty(vals[v].ty));
        }
    }
    return -1;
}

// findScalarElement (VectorUtils.cpp)
// llvm::findScalarElement (VectorUtils.cpp)
recursive fn find_scalar_element(v: i32, en: i64) -> i32 {
    let vt = vals[v].ty;
    if ty_kind(vt) == TK_FVEC && en >= ty_count(vt) { return c_poison(types[vt].a); }
    if is_constant(v) { return agg_elem(v, en); }
    if is_inst_op(v, OP_INSERTELEMENT) {
        // m_ConstantInt(uint64_t&)
        let ci = m_constant_int(op(v, 2));
        if ci < 0 || ap_active_bits(ci_ap(ci)) > 64 { return -1; }
        let ie = ap_lo64(ci_ap(ci));
        if (en as u64) == ie { return op(v, 1); }
        if op(v, 0) == v { return -1; }
        return find_scalar_element(op(v, 0), en);
    }
    if is_inst_op(v, OP_SHUFFLEVECTOR) && ty_kind(vt) == TK_FVEC {
        let lw = ty_count(vals[op(v, 0)].ty);
        let x = insts[inst_of(v)];
        let iel = ints[x.aux + en] as i64;
        if iel < 0 { return c_poison(types[vt].a); }
        if iel < lw { return find_scalar_element(op(v, 0), iel); }
        return find_scalar_element(op(v, 1), iel - lw);
    }
    // m_Add(m_Value(Val), m_Constant(C)) with C's element EltNo null
    if is_binop_match(v, OP_ADD) && is_constant(op(v, 1)) {
        let e = agg_elem(op(v, 1), en);
        if e >= 0 && is_null_value(e) { return find_scalar_element(op(v, 0), en); }
    }
    if ty_kind(vt) == TK_SVEC {
        let sp = get_splat_value_v(v);
        if sp >= 0 && en < ty_count(vt) { return sp; }
    }
    return -1;
}

// llvm::getSplatValue(const Value *V)
fn get_splat_value_v(v: i32) -> i32 {
    if is_constant(v) { return splat_value(v, false); }
    if is_inst_op(v, OP_SHUFFLEVECTOR) { return shuffle_splat_value(v); }
    return -1;
}

recursive fn simplify_extractelement(vec: i32, idx: i32, q: SQ) -> i32 {
    let vt = vals[vec].ty;
    let et = types[vt].a;
    if is_constant(vec) {
        if is_constant(idx) { return ce_extractelement(vec, idx); }
        if q_undef(q, vec) { return c_undef(et); }
    }
    if q_undef(q, idx) { return c_poison(et); }
    let ci = m_constant_int(idx);
    if ci >= 0 {
        let mn = ty_count(vt);
        let iv = ci_ap(ci);
        if ty_kind(vt) == TK_FVEC && ap_uge_u64(iv, mn as u64) { return c_poison(et); }
        if ap_ult_u64(iv, mn as u64) {
            let s = get_splat_value_v(vec);
            if s >= 0 { return s; }
        }
        let e = find_scalar_element(vec, ap_zext64(iv) as i64);
        if e >= 0 { return e; }
    } else {
        if is_inst_op(vec, OP_INSERTELEMENT) && op(vec, 2) == idx { return op(vec, 1); }
        let s = get_splat_value_v(vec);
        if s >= 0 { return s; }
    }
    return -1;
}

recursive fn simplify_phi(pn: i32, mark: i64, n: i64, q: SQ) -> i32 {
    var common: i32 = -1;
    var has_poison = false;
    var has_undef = false;
    for k in n {
        let inc = is_ops[mark + k];
        if inc == pn { continue; }
        if is_poison(inc) { has_poison = true; continue; }
        if q_undef(q, inc) { has_undef = true; continue; }
        if common >= 0 && inc != common { return -1; }
        common = inc;
    }
    if common < 0 { return if has_undef { c_undef(vals[pn].ty) } else { c_poison(vals[pn].ty) }; }
    if has_poison || has_undef {
        if !value_dominates_phi(common, pn) { return -1; }
        if has_undef && !is_guaranteed_not_to_be_poison(common, q.cxt, 0) { return -1; }
        return common;
    }
    return common;
}

recursive fn simplify_cast(o: i64, v: i32, ty: i32, q: SQ, mr: i64) -> i32 {
    if is_constant(v) { return cf_fold_cast_operand(o, v, ty); }
    if is_inst(v) && is_cast_op(iop(v)) {
        let src = op(v, 0);
        let st = vals[src].ty;
        let mt = vals[v].ty;
        if st == ty {
            if eliminable_cast_pair_dl(iop(v), o, st, mt, ty) == OP_BITCAST { return src; }
        }
    }
    if o == OP_BITCAST && vals[v].ty == ty { return v; }
    if (o == OP_PTRTOINT || o == OP_PTRTOADDR) && is_op(v, OP_GEP) && is_ptradd(v) {
        let ptr = op(v, 0);
        let s = op(v, 1);
        if is_op(s, OP_SUB) {
            let x = op(s, 0);
            let pp = m_ptrtoint_or_addr(op(s, 1));
            if pp == ptr && vals[x].ty == ty && ty == index_type_of(vals[ptr].ty) { return x; }
        }
    }
    if o == OP_ZEXT || o == OP_SEXT {
        if is_inst_op(v, OP_TRUNC) {
            let src = op(v, 0);
            let nw = if o == OP_ZEXT { op_nuw(v) } else { op_nsw(v) };
            if vals[src].ty == ty && nw { return src; }
        }
    }
    return -1;
}
// m_PtrAdd: a GEP of i8 with one index
fn is_ptradd(g: i32) -> bool {
    let st = gep_src_ty(g);
    return nops(g) == 2 && ty_is_int(st) && ty_bits(st) == 8;
}
fn index_type_of(t: i32) -> i32 {
    let s = ty_scalar(t);
    let it = ty_int(dl_ptr(types[s].n as i64).idx);
    if ty_is_vector(t) { return ty_vector(it, ty_count(t), ty_kind(t) == TK_SVEC); }
    return it;
}

recursive fn fold_identity_shuffles(dest: i64, op0: i32, op1: i32, mv: i64, root0: i32, mr0: i64) -> i32 {
    if mr0 == 0 { return -1; }
    let mr = mr0 - 1;
    if mv == -1 { return -1; }
    let inn = ty_count(vals[op0].ty);
    var root_elt = mv;
    var src = op0;
    if mv >= inn { root_elt = mv - inn; src = op1; }
    if is_inst_op(src, OP_SHUFFLEVECTOR) {
        let x = insts[inst_of(src)];
        return fold_identity_shuffles(dest, op(src, 0), op(src, 1), ints[x.aux + root_elt] as i64, root0, mr);
    }
    var root = root0;
    if root < 0 { root = src; }
    if root != src { return -1; }
    if root_elt != dest { return -1; }
    return root;
}

recursive fn simplify_shufflevector(iv: i32, op00: i32, op10: i32, q: SQ, mr: i64) -> i32 {
    let x = insts[inst_of(iv)];
    let rt = vals[iv].ty;
    var allp = true;
    for k in x.naux { if ints[x.aux + k] != -1 { allp = false; } }
    if allp { return c_poison(rt); }
    var op0 = op00;
    var op1 = op10;
    let ivt = vals[op0].ty;
    let nm = x.naux as i64;
    let scalable = ty_kind(ivt) == TK_SVEC;
    let mark = is_ops.len;
    for k in nm { is_ops.push(ints[x.aux + k]); }
    if !scalable {
        var s0 = false;
        var s1 = false;
        let inn = ty_count(ivt);
        for k in nm {
            let m = is_ops[mark + k] as i64;
            if m == -1 { continue; }
            if m < inn { s0 = true; } else { s1 = true; }
        }
        if !s0 { op0 = c_poison(ivt); }
        if !s1 { op1 = c_poison(ivt); }
    }
    let c0 = is_constant(op0);
    let c1 = is_constant(op1);
    if c0 && c1 {
        let r = ce_shufflevector(op0, op1, is_ops[mark..mark + nm]);
        is_ops.resize(mark);
        return r;
    }
    if !scalable && c0 && !c1 {
        let t = op0; op0 = op1; op1 = t;
        let inn = ty_count(ivt);
        for k in nm {
            let m = is_ops[mark + k] as i64;
            if m == -1 { continue; }
            is_ops[mark + k] = (if m < inn { m + inn } else { m - inn }) as i32;
        }
    }
    if !scalable && is_op(op0, OP_INSERTELEMENT) && is_constant(op(op0, 1)) && m_constant_int(op(op0, 2)) >= 0 {
        let c = op(op0, 1);
        let ii = ap_zext64(ci_ap(op(op0, 2))) as i64;
        var all = true;
        for k in nm { let m = is_ops[mark + k] as i64; if m != ii && m != -1 { all = false; } }
        if all {
            let m2 = is_ops.len;
            for k in nm { is_ops.push(if is_ops[mark + k] == -1 { c_poison(vals[c].ty) } else { c }); }
            let r = c_aggregate(ty_vector(vals[c].ty, nm, false), is_ops[m2..]);
            is_ops.resize(mark);
            return r;
        }
    }
    if is_inst_op(op0, OP_SHUFFLEVECTOR) && q_undef(q, op1) && rt == ivt {
        let y = insts[inst_of(op0)];
        var eq = true;
        for k in y.naux { if ints[y.aux + k] != ints[y.aux] { eq = false; } }
        if eq { is_ops.resize(mark); return op0; }
    }
    if scalable { is_ops.resize(mark); return -1; }
    for k in nm { if is_ops[mark + k] == -1 { is_ops.resize(mark); return -1; } }
    var root: i32 = -1;
    for k in nm {
        root = fold_identity_shuffles(k, op0, op1, is_ops[mark + k] as i64, root, mr);
        if root < 0 || vals[root].ty != rt { is_ops.resize(mark); return -1; }
    }
    is_ops.resize(mark);
    return root;
}

// ---------------------------------------------------------------------------------------------
// Floating point

recursive fn simplify_fneg(v: i32, fmf: u8, q: SQ) -> i32 {
    if is_constant(v) { return cf_fold_unary(OP_FNEG, v); }
    let x = m_fneg(v);
    if x >= 0 { return x; }
    return -1;
}

// propagateNaN
fn propagate_nan(c: i32) -> i32 {
    let ty = vals[c].ty;
    if ty_kind(ty) == TK_FVEC {
        let n = ty_count(ty);
        let mark = is_ops.len;
        let et = types[ty].a;
        for i in n {
            let e = agg_elem(c, i);
            if e >= 0 && is_poison(e) { is_ops.push(e); }
            else if e >= 0 && vals[e].kind == VK_CFP && cfp_parts(e).cat == FC_NAN { is_ops.push(c_fp_quiet(e)); }
            else { is_ops.push(c_fp_nan(et)); }
        }
        let r = c_aggregate(ty, is_ops[mark..]);
        is_ops.resize(mark);
        return r;
    }
    if !const_is_nan(c) { return c_fp_nan(ty); }
    var inn = c;
    if ty_kind(ty) == TK_SVEC { inn = splat_value(c, false); }
    let qv = c_fp_quiet(if ty_is_vector(vals[inn].ty) { splat_value(inn, false) } else { inn });
    if ty_is_vector(ty) { return c_splat(ty, qv); }
    return qv;
}
// Constant::isNaN
fn const_is_nan(c: i32) -> bool {
    if vals[c].kind == VK_CFP { let s = if ty_is_vector(vals[c].ty) { splat_value(c, false) } else { c }; return cfp_parts(s).cat == FC_NAN; }
    if ty_kind(vals[c].ty) == TK_FVEC {
        for i in ty_count(vals[c].ty) {
            let e = agg_elem(c, i);
            if e < 0 || vals[e].kind != VK_CFP || cfp_parts(e).cat != FC_NAN { return false; }
        }
        return true;
    }
    if ty_is_vector(vals[c].ty) {
        let s = splat_value(c, false);
        if s >= 0 && vals[s].kind == VK_CFP { return cfp_parts(s).cat == FC_NAN; }
    }
    return false;
}

// fp::ExceptionBehavior: 0 ignore, 1 maytrap, 2 strict; rounding: 1 = NearestTiesToEven, 7 = dynamic, ...
let EB_IGNORE = 0;
let EB_MAYTRAP = 1;
let EB_STRICT = 2;
let RM_NEAREST = 1;
let RM_DYNAMIC = 7;
let RM_TOWARD_NEG = 3;
fn is_default_fp_env(eb: i64, rm: i64) -> bool { eb == EB_IGNORE && rm == RM_NEAREST }
fn can_ignore_snan(eb: i64, fmf: u8) -> bool { eb == EB_IGNORE || (fmf & FMF_NNAN) != 0 }
fn can_rounding_mode_be(rm: i64, qrm: i64) -> bool { rm == RM_DYNAMIC || rm == qrm }

recursive fn simplify_fp_op(mark: i64, n: i64, fmf: u8, q: SQ, eb: i64, rm: i64) -> i32 {
    for k in n { if is_poison(is_ops[mark + k]) { return c_poison(vals[is_ops[mark]].ty); } }
    for k in n {
        let v = is_ops[mark + k];
        let is_nan = m_nan(v);
        let is_inf = m_inf(v);
        let is_undef = q_undef(q, v);
        if (fmf & FMF_NNAN) != 0 && (is_nan || is_undef) { return c_poison(vals[v].ty); }
        if (fmf & FMF_NINF) != 0 && (is_inf || is_undef) { return c_poison(vals[v].ty); }
        if is_default_fp_env(eb, rm) {
            if is_undef { return c_fp_nan(vals[v].ty); }
            if is_nan { return propagate_nan(v); }
        } else if eb != EB_STRICT {
            if is_nan { return propagate_nan(v); }
        }
    }
    return -1;
}
recursive fn fp_op2(a: i32, b: i32, fmf: u8, q: SQ, eb: i64, rm: i64) -> i32 {
    let mark = is_ops.len;
    is_ops.push(a);
    is_ops.push(b);
    let r = simplify_fp_op(mark, 2, fmf, q, eb, rm);
    is_ops.resize(mark);
    return r;
}

fn q_cannot_be_neg_zero(v: i32, q: SQ) -> bool {
    let k = q_fpclass(v, FCL_NEG_ZERO, 0, q);
    return kfc_never(k, FCL_NEG_ZERO);
}

recursive fn simplify_fadd(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    if is_default_fp_env(eb, rm) {
        let c, x, y = fold_or_commute_constant(OP_FADD, a, b, q);
        if c >= 0 { return c; }
        a = x;
        b = y;
    }
    let c2 = fp_op2(a, b, fmf, q, eb, rm);
    if c2 >= 0 { return c2; }
    let nsz = (fmf & FMF_NSZ) != 0;
    if can_ignore_snan(eb, fmf) && (!can_rounding_mode_be(rm, RM_TOWARD_NEG) || nsz) {
        if m_neg_zero_fp(b) { return a; }
    }
    if can_ignore_snan(eb, fmf) {
        if m_pos_zero_fp(b) && (nsz || q_cannot_be_neg_zero(a, q)) { return a; }
    }
    if !is_default_fp_env(eb, rm) { return -1; }
    if (fmf & FMF_NNAN) != 0 {
        if m_inf(b) { return b; }
        if (is_op(a, OP_FSUB) && m_any_zero_fp(op(a, 0)) && op(a, 1) == b) || (is_op(b, OP_FSUB) && m_any_zero_fp(op(b, 0)) && op(b, 1) == a) {
            return c_null(vals[a].ty);
        }
        if (m_fneg(a) == b && b >= 0) || (m_fneg(b) == a && a >= 0) { return c_null(vals[a].ty); }
    }
    if nsz && (fmf & FMF_REASSOC) != 0 {
        if is_op(a, OP_FSUB) && op(a, 1) == b { return op(a, 0); }
        if is_op(b, OP_FSUB) && op(b, 1) == a { return op(b, 0); }
    }
    return -1;
}

recursive fn simplify_fsub(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    if is_default_fp_env(eb, rm) {
        let c, x, y = fold_or_commute_constant(OP_FSUB, a, b, q);
        if c >= 0 { return c; }
        a = x;
        b = y;
    }
    let c2 = fp_op2(a, b, fmf, q, eb, rm);
    if c2 >= 0 { return c2; }
    let nsz = (fmf & FMF_NSZ) != 0;
    if can_ignore_snan(eb, fmf) && (!can_rounding_mode_be(rm, RM_TOWARD_NEG) || nsz) {
        if m_pos_zero_fp(b) { return a; }
    }
    if can_ignore_snan(eb, fmf) {
        if m_neg_zero_fp(b) && (nsz || q_cannot_be_neg_zero(a, q)) { return a; }
    }
    if can_ignore_snan(eb, fmf) {
        if m_neg_zero_fp(a) && m_fneg(b) >= 0 { return m_fneg(b); }
    }
    if can_ignore_snan(eb, fmf) {
        if nsz && m_any_zero_fp(a) {
            if is_op(b, OP_FSUB) && m_any_zero_fp(op(b, 0)) { return op(b, 1); }
            if m_fneg(b) >= 0 { return m_fneg(b); }
        }
    }
    if !is_default_fp_env(eb, rm) { return -1; }
    if (fmf & FMF_NNAN) != 0 {
        if a == b { return c_null(vals[a].ty); }
        if m_inf(a) { return a; }
        if m_inf(b) { return cf_fold_unary(OP_FNEG, b); }
    }
    if nsz && (fmf & FMF_REASSOC) != 0 {
        if is_op(b, OP_FSUB) && op(b, 0) == a { return op(b, 1); }
        let x = m_c_binop_with(a, OP_FADD, b);
        if x >= 0 { return x; }
    }
    return -1;
}

recursive fn simplify_fma_fmul(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    let c2 = fp_op2(a, b, fmf, q, eb, rm);
    if c2 >= 0 { return c2; }
    if !is_default_fp_env(eb, rm) { return -1; }
    if m_fp_one(a) || m_any_zero_fp(a) { let t = a; a = b; b = t; }
    if m_fp_one(b) { return a; }
    if m_any_zero_fp(b) {
        if (fmf & FMF_NNAN) != 0 && (fmf & FMF_NSZ) != 0 { return c_null(vals[a].ty); }
        let k = q_fpclass(a, FCL_INF | FCL_NAN, fmf, q);
        if kfc_never(k, FCL_INF | FCL_NAN) {
            if (fmf & FMF_NSZ) != 0 { return c_null(vals[a].ty); }
            if k.sign == 0 { return b; }
            if k.sign == 1 { return cf_fold_unary(OP_FNEG, b); }
        }
    }
    if a == b && m_intrinsic(a, IID_sqrt) && (fmf & FMF_REASSOC) != 0 && (fmf & FMF_NNAN) != 0 && (fmf & FMF_NSZ) != 0 { return op(a, 0); }
    return -1;
}

recursive fn simplify_fmul(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    if is_default_fp_env(eb, rm) {
        let c, x, y = fold_or_commute_constant(OP_FMUL, a, b, q);
        if c >= 0 { return c; }
        a = x;
        b = y;
    }
    return simplify_fma_fmul(a, b, fmf, q, mr, eb, rm);
}

recursive fn simplify_fdiv(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    if is_default_fp_env(eb, rm) {
        let c, x, y = fold_or_commute_constant(OP_FDIV, a, b, q);
        if c >= 0 { return c; }
        a = x;
        b = y;
    }
    let c2 = fp_op2(a, b, fmf, q, eb, rm);
    if c2 >= 0 { return c2; }
    if !is_default_fp_env(eb, rm) { return -1; }
    if m_fp_one(b) { return a; }
    let nnan = (fmf & FMF_NNAN) != 0;
    if nnan && (fmf & FMF_NSZ) != 0 && m_any_zero_fp(a) { return c_null(vals[a].ty); }
    if nnan {
        if a == b { return c_fp_from_f64(vals[a].ty, 1.0); }
        if (fmf & FMF_REASSOC) != 0 {
            let x = m_c_binop_with(a, OP_FMUL, b);
            if x >= 0 { return x; }
        }
        // m_FNegNSZ(m_Specific(X)): m_FSub(m_AnyZeroFP(), X) (PatternMatch.h; no fneg form)
        fn fneg_nsz_of(v: i32, x: i32) -> bool { is_op(v, OP_FSUB) && op(v, 1) == x && m_any_zero_fp(op(v, 0)) }
        if fneg_nsz_of(a, b) || fneg_nsz_of(b, a) { return c_fp_from_f64(vals[a].ty, -1.0); }
        if (fmf & FMF_NINF) != 0 && m_any_zero_fp(b) { return c_poison(vals[b].ty); }
    }
    return -1;
}

recursive fn simplify_frem(a0: i32, b0: i32, fmf: u8, q: SQ, mr: i64, eb: i64, rm: i64) -> i32 {
    var a = a0;
    var b = b0;
    if is_default_fp_env(eb, rm) {
        let c, x, y = fold_or_commute_constant(OP_FREM, a, b, q);
        if c >= 0 { return c; }
        a = x;
        b = y;
    }
    let c2 = fp_op2(a, b, fmf, q, eb, rm);
    if c2 >= 0 { return c2; }
    if !is_default_fp_env(eb, rm) { return -1; }
    if (fmf & FMF_NNAN) != 0 {
        if m_pos_zero_fp(a) { return c_null(vals[a].ty); }
        if m_neg_zero_fp(a) { return c_fp_neg_zero(vals[a].ty); }
    }
    return -1;
}

recursive fn simplify_binop(o: i64, l: i32, r: i32, q: SQ, mr: i64) -> i32 {
    if o == OP_ADD { return simplify_add(l, r, false, false, q, mr); }
    if o == OP_SUB { return simplify_sub(l, r, false, false, q, mr); }
    if o == OP_MUL { return simplify_mul(l, r, false, false, q, mr); }
    if o == OP_SDIV { return simplify_sdiv(l, r, false, q, mr); }
    if o == OP_UDIV { return simplify_udiv(l, r, false, q, mr); }
    if o == OP_SREM { return simplify_srem(l, r, q, mr); }
    if o == OP_UREM { return simplify_urem(l, r, q, mr); }
    if o == OP_SHL { return simplify_shl(l, r, false, false, q, mr); }
    if o == OP_LSHR { return simplify_lshr(l, r, false, q, mr); }
    if o == OP_ASHR { return simplify_ashr(l, r, false, q, mr); }
    if o == OP_AND { return simplify_and(l, r, q, mr); }
    if o == OP_OR { return simplify_or(l, r, q, mr); }
    if o == OP_XOR { return simplify_xor(l, r, q, mr); }
    if o == OP_FADD { return simplify_fadd(l, r, 0, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FSUB { return simplify_fsub(l, r, 0, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FMUL { return simplify_fmul(l, r, 0, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FDIV { return simplify_fdiv(l, r, 0, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FREM { return simplify_frem(l, r, 0, q, mr, EB_IGNORE, RM_NEAREST); }
    fatal("internal: simplify_binop opcode");
    return -1;
}
recursive fn simplify_binop_fmf(o: i64, l: i32, r: i32, fmf: u8, q: SQ, mr: i64) -> i32 {
    if o == OP_FADD { return simplify_fadd(l, r, fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FSUB { return simplify_fsub(l, r, fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FMUL { return simplify_fmul(l, r, fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_FDIV { return simplify_fdiv(l, r, fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    return simplify_binop(o, l, r, q, mr);
}

// ---------------------------------------------------------------------------------------------
// Intrinsics and calls

fn is_idempotent(id: i32) -> bool {
    return id == IID_fabs || id == IID_floor || id == IID_ceil || id == IID_trunc || id == IID_rint || id == IID_nearbyint ||
           id == IID_round || id == IID_roundeven || id == IID_canonicalize || id == IID_arithmetic_fence;
}
fn removes_fp_fraction(id: i32) -> bool {
    return id == IID_floor || id == IID_ceil || id == IID_trunc || id == IID_rint || id == IID_nearbyint || id == IID_round || id == IID_roundeven;
}

recursive fn simplify_relative_load(ptr: i32, off: i32) -> i32 {
    is_not_ported("llvm.load.relative simplification");
    return -1;
}

recursive fn simplify_ldexp(a: i32, b: i32, q: SQ, strict: bool) -> i32 {
    if is_poison(a) || is_poison(b) { return a; }
    if q_undef(q, a) { return c_fp_nan(vals[a].ty); }
    if !strict { if q_undef(q, b) { return a; } }
    let c = m_apfloat(a);
    if c >= 0 {
        let p = cfp_parts(c);
        if p.cat == FC_ZERO || p.cat == FC_INF { return a; }
    }
    if strict { return -1; }
    if c >= 0 && cfp_parts(c).cat == FC_NAN {
        let qn = c_fp_quiet(c);
        if ty_is_vector(vals[a].ty) { return c_splat(vals[a].ty, qn); }
        return qn;
    }
    if m_zero_int(b) { return a; }
    return -1;
}

recursive fn simplify_unary_intrinsic(id: i32, a: i32, fmf: u8, q: SQ) -> i32 {
    if is_idempotent(id) && inst_iid(a) == id { return a; }
    if removes_fp_fraction(id) {
        let ai = inst_iid(a);
        if (ai != 0 && removes_fp_fraction(ai)) || is_op(a, OP_SITOFP) || is_op(a, OP_UITOFP) { return a; }
    }
    let reassoc = (fmf & FMF_REASSOC) != 0;
    if id == IID_fabs {
        let k = q_fpclass(a, FCL_ALL, 0, q);
        if k.sign == 0 { return a; }
        if kfc_cannot_be_ordered_lt_zero(k) && kfc_never_nan(k) && (fmf & FMF_NSZ) != 0 { return a; }
        return -1;
    }
    if id == IID_bswap { if m_intrinsic(a, IID_bswap) { return op(a, 0); } return -1; }
    if id == IID_bitreverse { if m_intrinsic(a, IID_bitreverse) { return op(a, 0); } return -1; }
    if id == IID_ctpop {
        if q_pow2(a, false, q) { return c_int_ty(vals[a].ty, 1); }
        let w = ty_scalar_bits(vals[a].ty);
        if q_masked_zero(a, highb(w, w - 1), q) { return a; }
        return -1;
    }
    if id == IID_exp { if reassoc && m_intrinsic(a, IID_log) { return op(a, 0); } return -1; }
    if id == IID_exp2 { if reassoc && m_intrinsic(a, IID_log2) { return op(a, 0); } return -1; }
    if id == IID_exp10 { if reassoc && m_intrinsic(a, IID_log10) { return op(a, 0); } return -1; }
    if id == IID_log { if reassoc && m_intrinsic(a, IID_exp) { return op(a, 0); } return -1; }
    if id == IID_log2 {
        if reassoc && (m_intrinsic(a, IID_exp2) || (m_intrinsic(a, IID_pow) && m_specific_fp(op(a, 0), 2.0))) { return if m_intrinsic(a, IID_exp2) { op(a, 0) } else { op(a, 1) }; }
        return -1;
    }
    if id == IID_log10 {
        if reassoc && (m_intrinsic(a, IID_exp10) || (m_intrinsic(a, IID_pow) && m_specific_fp(op(a, 0), 10.0))) { return if m_intrinsic(a, IID_exp10) { op(a, 0) } else { op(a, 1) }; }
        return -1;
    }
    if id == IID_vector_reverse {
        if m_intrinsic(a, IID_vector_reverse) { return op(a, 0); }
        if is_splat_value(a, 0) { return a; }
        return -1;
    }
    if id == IID_structured_gep { return a; }
    return -1;
}

// isSplatValue(V, Index = -1, Depth) (VectorUtils.cpp)
recursive fn is_splat_value(v: i32, depth0: i64) -> bool {
    var depth = depth0;
    if ty_is_vector(vals[v].ty) {
        if is_undef_val(v) { return true; }
        if is_constant(v) { return splat_value(v, false) >= 0; }
    }
    if is_inst_op(v, OP_SHUFFLEVECTOR) {
        let x = insts[inst_of(v)];
        for k in x.naux { if ints[x.aux + k] != ints[x.aux] { return false; } }
        return true;
    }
    if depth == VT_MAX_DEPTH { return false; }
    depth++;
    if is_op(v, OP_ADD) || (opcode_of(v) >= 0 && is_binary_op(opcode_of(v))) {
        return is_splat_value(op(v, 0), depth) && is_splat_value(op(v, 1), depth);
    }
    if is_inst_op(v, OP_SELECT) {
        return is_splat_value(op(v, 0), depth) && is_splat_value(op(v, 1), depth) && is_splat_value(op(v, 2), depth);
    }
    return false;
}

recursive fn fold_minmax_shared_op(id: i32, a: i32, b: i32) -> i32 {
    if !m_max_or_min(a) { return -1; }
    let x = mm_a;
    let y = mm_b;
    let id0 = inst_iid(a);
    if id0 == 0 { return -1; }
    if b == x || b == y || (m_max_or_min(b) && ((mm_a == x && mm_b == y) || (mm_a == y && mm_b == x))) {
        if id0 == id { return a; }
        if id0 == inverse_minmax_iid(id) { return b; }
    }
    return -1;
}

fn is_minimum_maximum_iid(id: i32) -> bool {
    return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum || id == IID_minimumnum;
}
fn fold_minimum_maximum_shared_op(id: i32, a: i32, b: i32) -> i32 {
    if inst_iid(a) != id { return -1; }
    let x0 = op(a, 0);
    let y0 = op(a, 1);
    if x0 == b || y0 == b { return a; }
    let id1 = inst_iid(b);
    if id1 == 0 || !is_minimum_maximum_iid(id1) { return -1; }
    let x1 = op(b, 0);
    let y1 = op(b, 1);
    if (x0 == x1 && y0 == y1) || (x0 == y1 && y0 == x1) {
        if id1 == id || inverse_minmax_iid(id1) == id { return a; }
    }
    return -1;
}

let MMO_CANNOT = 0;
let MMO_NEWCONST = 1;
let MMO_OTHER = 2;
let MMO_EITHER = 3;
var mmo_const: i32 = -1;
fn optimize_const_minmax(rc: i32, id: i32, fmf: u8) -> i64 {
    let prop_nan = id == IID_minimum || id == IID_maximum;
    let prop_snan = id == IID_minnum || id == IID_maxnum;
    let is_min = id == IID_minimum || id == IID_minnum || id == IID_minimumnum;
    if is_undef_val(rc) { mmo_const = rc; return MMO_EITHER; }
    if vals[rc].kind != VK_CFP || ty_is_vector(vals[rc].ty) { return MMO_CANNOT; }
    let p = cfp_parts(rc);
    if p.cat == FC_NAN {
        if prop_nan || (prop_snan && cfp_is_signaling(rc)) { mmo_const = c_fp_quiet(rc); return MMO_NEWCONST; }
        return MMO_OTHER;
    }
    if p.cat == FC_INF || ((fmf & FMF_NINF) != 0 && cfp_is_largest(rc)) {
        if p.neg == is_min && (!prop_nan || (fmf & FMF_NNAN) != 0) { mmo_const = rc; return MMO_NEWCONST; }
        if p.neg != is_min && (prop_nan || (fmf & FMF_NNAN) != 0) { return MMO_OTHER; }
    }
    return MMO_CANNOT;
}

recursive fn simplify_binary_intrinsic(id: i32, rty: i32, a0: i32, b0: i32, fmf: u8, q: SQ) -> i32 {
    var a = a0;
    var b = b0;
    let bw = ty_scalar_bits(rty);
    if id == IID_get_active_lane_mask {
        if m_zero(b) { return get_false(rty); }
        if q.cxt < 0 { return -1; }
        if ty_kind(rty) == TK_SVEC && func_has_fn_attr(inst_func(q.cxt), AK_VScaleRange) { is_not_ported("get_active_lane_mask with vscale_range"); }
        return -1;
    }
    if id == IID_abs { if m_intrinsic(a, IID_abs) { return a; } return -1; }
    if id == IID_cttz { if is_op(a, OP_SHL) && m_one(op(a, 0)) { return op(a, 1); } return -1; }
    if id == IID_ctlz {
        if is_op(a, OP_LSHR) && m_negative(op(a, 0)) { return op(a, 1); }
        if is_op(a, OP_ASHR) && m_negative(op(a, 0)) { return c_null(rty); }
        return -1;
    }
    if id == IID_ptrmask {
        if q_undef(q, a) || m_zero(a) { return c_null(vals[a].ty); }
        if m_ptrtoint_or_addr(b) == a { return a; }
        if m_all_ones(b) || q_undef(q, b) { return a; }
        if m_imm_constant(b) {
            let pk = q_kb(a, q);
            let cw = ty_scalar_bits(vals[b].ty);
            let irr = ap_zext_or_trunc(pk.z, cw);
            let c = cf_fold_binop_operands(OP_OR, b, c_int_ap(vals[b].ty, irr));
            if c >= 0 && is_all_ones_value(c) { return a; }
        }
        return -1;
    }
    if id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin {
        if a == b { return a; }
        if m_imm_constant(a) { let t = a; a = b; b = t; }
        if q_undef(q, b) { return c_int_ap(rty, minmax_saturation_ap(id, bw)); }
        let c = m_apint_ap(b, true);
        if c >= 0 {
            let cv = ci_ap(c);
            if ap_eq(cv, minmax_saturation_ap(id, bw)) { return c_int_ap(rty, cv); }
            if ap_eq(cv, minmax_saturation_ap(inverse_minmax_iid(id), bw)) { return a; }
            if inst_iid(a) == id {
                let m00 = op(a, 0);
                let m01 = op(a, 1);
                var inner = m_apint(m00);
                if inner < 0 { inner = m_apint(m01); }
                if inner >= 0 && ap_icmp(ci_ap(inner), cv, pred_nonstrict(minmax_pred(id))) { return a; }
            }
        }
        var v = fold_minmax_shared_op(id, a, b);
        if v >= 0 { return v; }
        v = fold_minmax_shared_op(id, b, a);
        if v >= 0 { return v; }
        let p = pred_nonstrict(minmax_pred(id));
        if is_icmp_true(p, a, b, sq_without_undef(q), RECURSION_LIMIT) { return a; }
        if is_icmp_true(p, b, a, sq_without_undef(q), RECURSION_LIMIT) { return b; }
        return -1;
    }
    if id == IID_scmp || id == IID_ucmp {
        if is_icmp_true(P_EQ, a, b, q, RECURSION_LIMIT) { return c_null(rty); }
        let gt = if id == IID_scmp { P_SGT } else { P_UGT };
        if is_icmp_true(gt, a, b, q, RECURSION_LIMIT) { return c_int_ty(rty, 1); }
        let lt = if id == IID_scmp { P_SLT } else { P_ULT };
        if is_icmp_true(lt, a, b, q, RECURSION_LIMIT) { return c_int_ty_s(rty, -1); }
        return -1;
    }
    if id == IID_usub_with_overflow || id == IID_ssub_with_overflow {
        if a == b || q_undef(q, a) || q_undef(q, b) { return c_null(rty); }
        return -1;
    }
    if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow {
        if q_undef(q, a) || q_undef(q, b) {
            let mark = is_ops.len;
            is_ops.push(c_all_ones(ty_field(rty, 0)));
            is_ops.push(c_null(ty_field(rty, 1)));
            let r = c_aggregate(rty, is_ops[mark..]);
            is_ops.resize(mark);
            return r;
        }
        return -1;
    }
    if id == IID_umul_with_overflow || id == IID_smul_with_overflow {
        if m_zero(a) || m_zero(b) { return c_null(rty); }
        if q_undef(q, a) || q_undef(q, b) { return c_null(rty); }
        return -1;
    }
    if id == IID_uadd_sat || id == IID_sadd_sat {
        if id == IID_uadd_sat && (m_all_ones(a) || m_all_ones(b)) { return c_all_ones(rty); }
        if q_undef(q, a) || q_undef(q, b) { return c_all_ones(rty); }
        if m_zero(b) { return a; }
        if m_zero(a) { return b; }
        return -1;
    }
    if id == IID_usub_sat || id == IID_ssub_sat {
        if id == IID_usub_sat && (m_zero(a) || m_all_ones(b)) { return c_null(rty); }
        if a == b || q_undef(q, a) || q_undef(q, b) { return c_null(rty); }
        if m_zero(b) { return a; }
        return -1;
    }
    if id == IID_load_relative {
        if is_constant(a) && is_constant(b) { return simplify_relative_load(a, b); }
        return -1;
    }
    if id == IID_powi {
        let pw = m_constant_int(b);
        if pw >= 0 {
            if cint_is_zero(pw) { return c_fp_from_f64(vals[a].ty, 1.0); }
            if ap_is_one(ci_ap(pw)) { return a; }
        }
        return -1;
    }
    if id == IID_ldexp { return simplify_ldexp(a, b, q, false); }
    if id == IID_copysign {
        if a == b { return a; }
        if (m_fneg(a) == b && b >= 0) || (m_fneg(b) == a && a >= 0) { return b; }
        return -1;
    }
    if id == IID_is_fpclass {
        let mask = ap_lo64(ci_ap(b));
        if (mask & FCL_ALL) == FCL_ALL { return c_bool_ty(rty, true); }
        if (mask & FCL_ALL) == 0 { return c_bool_ty(rty, false); }
        if q_undef(q, a) { return c_undef(rty); }
        return -1;
    }
    if is_minimum_maximum_iid(id) {
        if a == b { return a; }
        if is_constant(a) { let t = a; a = b; b = t; }
        if is_constant(b) {
            var res = MMO_CANNOT;
            var newc: i32 = -1;
            let ct = vals[b].ty;
            if ty_is_vector(ct) {
                let sv = splat_value(b, false);
                if sv >= 0 {
                    res = optimize_const_minmax(sv, id, fmf);
                    newc = mmo_const;
                    if res == MMO_NEWCONST { newc = c_splat(ct, newc); }
                } else if ty_kind(ct) == TK_FVEC {
                    let n = ty_count(ct);
                    let mark = is_ops.len;
                    res = MMO_EITHER;
                    for i in n {
                        let e = agg_elem(b, i);
                        if e < 0 { res = MMO_CANNOT; break; }
                        let er = optimize_const_minmax(e, id, fmf);
                        if er == MMO_CANNOT || (er != res && res != MMO_EITHER && er != MMO_EITHER) { res = MMO_CANNOT; break; }
                        is_ops.push(mmo_const);
                        if er != MMO_EITHER { res = er; }
                    }
                    if res == MMO_NEWCONST { newc = c_aggregate(ct, is_ops[mark..]); }
                    is_ops.resize(mark);
                }
            } else {
                res = optimize_const_minmax(b, id, fmf);
                newc = mmo_const;
            }
            if res == MMO_OTHER || res == MMO_EITHER { return a; }
            if res == MMO_NEWCONST { return newc; }
        }
        var v = fold_minimum_maximum_shared_op(id, a, b);
        if v >= 0 { return v; }
        v = fold_minimum_maximum_shared_op(id, b, a);
        if v >= 0 { return v; }
        return -1;
    }
    if id == IID_vector_extract {
        let idxn = ap_zext64(ci_ap(b));
        if m_intrinsic(a, IID_vector_insert) && m_zero(op(a, 2)) && idxn == 0 && vals[op(a, 1)].ty == rty { return op(a, 1); }
        return -1;
    }
    if id == IID_pdep || id == IID_pext {
        is_not_ported("pdep/pext simplification");
    }
    return -1;
}

// simplifyIntrinsic(IID, ReturnType, Args, FMF, Q, CxtF, ExBehavior, Rounding); args on is_ops
recursive fn simplify_intrinsic_args(id: i32, rty: i32, mark: i64, n: i64, fmf: u8, q: SQ, cxtf: i32, eb: i64, rm: i64) -> i32 {
    if id != 0 && intrinsic_propagates_poison(id) {
        for k in n { if is_poison(is_ops[mark + k]) { return c_poison(rty); } }
    }
    if n == 0 {
        if id == IID_vscale {
            if cxtf < 0 { return -1; }
            let ok, lo, hi = vscale_range_of(cxtf);
            if ok && lo == hi { return c_int_ty(rty, lo); }
            return -1;
        }
        return -1;
    }
    let v = simplify_identity_interleave(id, mark, n);
    if v >= 0 { return v; }
    if n == 1 { return simplify_unary_intrinsic(id, is_ops[mark], fmf, q); }
    if n == 2 { return simplify_binary_intrinsic(id, rty, is_ops[mark], is_ops[mark + 1], fmf, q); }
    if id == IID_masked_load || id == IID_masked_gather {
        if m_zero_or_poison(is_ops[mark + 1]) { return is_ops[mark + 2]; }
        return -1;
    }
    if id == IID_fshl || id == IID_fshr {
        let a = is_ops[mark];
        let b = is_ops[mark + 1];
        let sh = is_ops[mark + 2];
        if q_undef(q, a) && q_undef(q, b) { return c_undef(rty); }
        if q_undef(q, sh) { return if id == IID_fshl { a } else { b }; }
        let shc = m_apint(sh);
        if shc >= 0 {
            let w = ci_w(shc);
            let bwa = ap_u64(w as u64, w);
            let s = ap_urem(ci_ap(shc), bwa);
            if ap_is_zero(s) { return if id == IID_fshl { a } else { b }; }
            if is_op(a, OP_LSHR) && m_apint(op(a, 1)) >= 0 && is_op(b, OP_SHL) && op(b, 0) == op(a, 0) && m_apint(op(b, 1)) >= 0 {
                let c1 = ci_ap(m_apint(op(a, 1)));
                let c2 = ci_ap(m_apint(op(b, 1)));
                if ap_eq(ap_add(c1, c2), bwa) && ap_eq(s, if id == IID_fshl { c1 } else { c2 }) { return op(a, 0); }
            }
        }
        if m_zero(a) && m_zero(b) { return c_null(rty); }
        if m_all_ones(a) && m_all_ones(b) { return c_all_ones(rty); }
        return -1;
    }
    if id == IID_experimental_constrained_fma { return simplify_fp_op(mark, n, 0, q, eb, rm); }
    if id == IID_fma || id == IID_fmuladd { return simplify_fp_op(mark, n, 0, q, EB_IGNORE, RM_NEAREST); }
    if id == IID_smul_fix || id == IID_smul_fix_sat {
        var a = is_ops[mark];
        var b = is_ops[mark + 1];
        let c = is_ops[mark + 2];
        if is_constant(a) { let t = a; a = b; b = t; }
        if m_zero(b) { return c_null(rty); }
        if q_undef(q, b) { return c_null(rty); }
        let w = ty_scalar_bits(rty);
        let sc = ap_zext64(ci_ap(c));
        if sc < w as u64 {
            let one = ap_one_bit(w, sc as i64);
            if !ap_is_neg(one) && m_specific_int_apv(b, one) { return a; }
        }
        return -1;
    }
    if id == IID_vector_insert {
        let vec = is_ops[mark];
        let sub = is_ops[mark + 1];
        let ix = ap_zext64(ci_ap(is_ops[mark + 2]));
        if m_intrinsic(sub, IID_vector_extract) && m_zero(op(sub, 1)) {
            let x = op(sub, 0);
            if (q_undef(q, vec) || vec == x) && ix == 0 && vals[x].ty == rty { return x; }
        }
        return -1;
    }
    if id == IID_vector_splice_right || id == IID_vector_splice_left {
        is_not_ported("vector.splice simplification");
    }
    if id == IID_experimental_constrained_fadd { return simplify_fadd(is_ops[mark], is_ops[mark + 1], fmf, q, RECURSION_LIMIT, eb, rm); }
    if id == IID_experimental_constrained_fsub { return simplify_fsub(is_ops[mark], is_ops[mark + 1], fmf, q, RECURSION_LIMIT, eb, rm); }
    if id == IID_experimental_constrained_fmul { return simplify_fmul(is_ops[mark], is_ops[mark + 1], fmf, q, RECURSION_LIMIT, eb, rm); }
    if id == IID_experimental_constrained_fdiv { return simplify_fdiv(is_ops[mark], is_ops[mark + 1], fmf, q, RECURSION_LIMIT, eb, rm); }
    if id == IID_experimental_constrained_frem { return simplify_frem(is_ops[mark], is_ops[mark + 1], fmf, q, RECURSION_LIMIT, eb, rm); }
    if id == IID_experimental_constrained_ldexp { return simplify_ldexp(is_ops[mark], is_ops[mark + 1], q, true); }
    if id == IID_experimental_vp_reverse {
        let vec = is_ops[mark];
        let evl = is_ops[mark + 2];
        if m_intrinsic(vec, IID_experimental_vp_reverse) && op(vec, 2) == evl { return op(vec, 0); }
        if is_splat_value(vec, 0) { return vec; }
        return -1;
    }
    return -1;
}

fn vscale_range_of(fv: i32) -> bool, u64, u64 {
    let at = aset_find(alist_fn(func_attrs(fv)), AK_VScaleRange);
    if at < 0 { return false, 0, 0; }
    is_not_ported("vscale_range attribute decoding");
    return false, 0, 0;
}

fn simplify_identity_interleave(id: i32, mark: i64, n: i64) -> i32 {
    let factor = interleave_factor(id);
    if factor == 0 || factor != n { return -1; }
    let di_id = deinterleave_iid(factor);
    var di: i32 = -1;
    for k in factor {
        let ev = is_ops[mark + k];
        if !is_inst_op(ev, OP_EXTRACTVALUE) { return -1; }
        let x = insts[inst_of(ev)];
        if x.naux != 1 || ints[x.aux] as i64 != k { return -1; }
        let cur = op(ev, 0);
        if inst_iid(cur) != di_id || di_id == 0 { return -1; }
        if di < 0 { di = cur; } else if di != cur { return -1; }
    }
    return cb_arg(di, 0);
}
fn interleave_factor(id: i32) -> i64 {
    if id == IID_vector_interleave2 { return 2; }
    if id == IID_vector_interleave3 { return 3; }
    if id == IID_vector_interleave4 { return 4; }
    if id == IID_vector_interleave5 { return 5; }
    if id == IID_vector_interleave6 { return 6; }
    if id == IID_vector_interleave7 { return 7; }
    if id == IID_vector_interleave8 { return 8; }
    return 0;
}
fn deinterleave_iid(f: i64) -> i32 {
    return match f { 2 => IID_vector_deinterleave2, 3 => IID_vector_deinterleave3, 4 => IID_vector_deinterleave4,
                     5 => IID_vector_deinterleave5, 6 => IID_vector_deinterleave6, 7 => IID_vector_deinterleave7,
                     8 => IID_vector_deinterleave8, _ => 0 };
}

// ConstrainedFPIntrinsic::getExceptionBehavior / getRoundingMode from the metadata arguments
fn constrained_eb_rm(c: i32) -> i64, i64 {
    var eb = EB_IGNORE;
    var rm = RM_NEAREST;
    let na = cb_nargs(c);
    for k in na {
        let a = cb_arg(c, k);
        if vals[a].kind != VK_MDVAL { continue; }
        let md = vals[a].sub;
        if mds[md].kind != MK_STRING { continue; }
        let s = sbytes(mds[md].extra);
        if s == "fpexcept.ignore" { eb = EB_IGNORE; }
        else if s == "fpexcept.maytrap" { eb = EB_MAYTRAP; }
        else if s == "fpexcept.strict" { eb = EB_STRICT; }
        else if s == "round.dynamic" { rm = RM_DYNAMIC; }
        else if s == "round.tonearest" { rm = RM_NEAREST; }
        else if s == "round.downward" { rm = RM_TOWARD_NEG; }
        else if s == "round.upward" { rm = 2; }
        else if s == "round.towardzero" { rm = 0; }
        else if s == "round.tonearestaway" { rm = 4; }
    }
    return eb, rm;
}

recursive fn simplify_intrinsic_call(c: i32, mark: i64, n: i64, q: SQ) -> i32 {
    let f = called_function(c);
    let id = func_iid(f) as i32;
    let rty = ty_fn_ret(globs[glob_of(f)].vty);
    if id == IID_experimental_gc_relocate {
        // GCRelocateInst::getDerivedPtr / getBasePtr (gc_ptr_operand, printer.goose; -1 = nullptr)
        let dp = gc_ptr_operand(c, 2);
        let bp = gc_ptr_operand(c, 1);
        if (dp >= 0 && is_undef_val(dp)) || (bp >= 0 && is_undef_val(bp)) { return c_undef(vals[c].ty); }
        if ty_kind(vals[c].ty) == TK_PTR && dp >= 0 && vals[dp].kind == VK_CNULL { return c_null(vals[c].ty); }
        return -1;
    }
    var eb = EB_IGNORE;
    var rm = RM_NEAREST;
    if is_constrained_fp_iid(id) {
        let e, r = constrained_eb_rm(c);
        eb = e;
        rm = r;
    }
    let fmf = if is_fp_math_operator(c) { insts[inst_of(c)].fmf } else { 0 };
    return simplify_intrinsic_args(id, rty, mark, n, fmf, q, inst_func(c), eb, rm);
}

recursive fn try_constant_fold_call(c: i32, mark: i64, n: i64, q: SQ) -> i32 {
    let f = called_function(c);
    if f < 0 || !can_constant_fold_call_to(c, f) { return -1; }
    let m2 = is_ops.len;
    for k in n {
        let a = is_ops[mark + k];
        if !is_constant(a) {
            if vals[a].kind == VK_MDVAL { continue; }
            is_ops.resize(m2);
            return -1;
        }
        is_ops.push(a);
    }
    let r = cf_fold_call(c, f, m2, is_ops.len - m2, true);
    is_ops.resize(m2);
    return r;
}

recursive fn simplify_call(c: i32, callee: i32, mark: i64, n: i64, q: SQ) -> i32 {
    if (insts[inst_of(c)].bits & 8) != 0 { return -1; }
    if is_undef_val(callee) || (vals[callee].kind == VK_CNULL) { return c_poison(vals[c].ty); }
    let v = try_constant_fold_call(c, mark, n, q);
    if v >= 0 { return v; }
    if is_func(callee) && func_iid(callee) != 0 && called_function(c) == callee {
        let r = simplify_intrinsic_call(c, mark, n, q);
        if r >= 0 { return r; }
    }
    return -1;
}

recursive fn simplify_freeze(v: i32, q: SQ) -> i32 {
    if is_guaranteed_not_to_be_undef_or_poison(v, q.cxt, 0) { return v; }
    return -1;
}

recursive fn simplify_load(li: i32, ptr: i32, q: SQ) -> i32 {
    if inst_is_volatile(li) { return -1; }
    if is_constant(ptr) { return cf_fold_load_from_const_ptr(ptr, vals[li].ty, 0, false); }
    let gv = get_underlying_object(ptr, 10);
    if !is_gvar(gv) { return -1; }
    let g = globs[glob_of(gv)];
    if g.is_const == 0 || !gv_has_definitive_initializer(gv) { return -1; }
    let init = op(gv, 0);
    let c = cf_fold_load_from_uniform(init, vals[li].ty);
    if c >= 0 { return c; }
    let base = strip_and_accumulate_offsets(ptr, true, true, false);
    if base == gv {
        return cf_fold_load_from_const_ptr(gv, vals[li].ty, vt_off, true);
    }
    return -1;
}
// GlobalVariable::hasDefinitiveInitializer
fn gv_has_definitive_initializer(gv: i32) -> bool {
    let g = globs[glob_of(gv)];
    if nops(gv) == 0 { return false; }
    if g.is_decl != 0 { return false; }
    let l = g.linkage as i64;
    // isInterposable: linkonce/weak (non-odr)/common/extern_weak
    if l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return false; }
    if g.ext_init != 0 { return false; }
    return true;
}

// ---------------------------------------------------------------------------------------------
// simplifyInstructionWithOperands

recursive fn simplify_inst_with_ops(i: i32, mark: i64, n: i64, sq: SQ, mr: i64) -> i32 {
    let q = if sq.cxt >= 0 { sq } else { sq_with_inst(sq, i) };
    let o = iop(i);
    let x = insts[inst_of(i)];
    if o == OP_FNEG { return simplify_fneg(is_ops[mark], x.fmf, q); }
    if o == OP_FADD { return simplify_fadd(is_ops[mark], is_ops[mark + 1], x.fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_ADD { return simplify_add(is_ops[mark], is_ops[mark + 1], op_nsw(i), op_nuw(i), q, mr); }
    if o == OP_FSUB { return simplify_fsub(is_ops[mark], is_ops[mark + 1], x.fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_SUB { return simplify_sub(is_ops[mark], is_ops[mark + 1], op_nsw(i), op_nuw(i), q, mr); }
    if o == OP_FMUL { return simplify_fmul(is_ops[mark], is_ops[mark + 1], x.fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_MUL { return simplify_mul(is_ops[mark], is_ops[mark + 1], op_nsw(i), op_nuw(i), q, mr); }
    if o == OP_SDIV { return simplify_sdiv(is_ops[mark], is_ops[mark + 1], op_exact(i), q, mr); }
    if o == OP_UDIV { return simplify_udiv(is_ops[mark], is_ops[mark + 1], op_exact(i), q, mr); }
    if o == OP_FDIV { return simplify_fdiv(is_ops[mark], is_ops[mark + 1], x.fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_SREM { return simplify_srem(is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_UREM { return simplify_urem(is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_FREM { return simplify_frem(is_ops[mark], is_ops[mark + 1], x.fmf, q, mr, EB_IGNORE, RM_NEAREST); }
    if o == OP_SHL { return simplify_shl(is_ops[mark], is_ops[mark + 1], op_nsw(i), op_nuw(i), q, mr); }
    if o == OP_LSHR { return simplify_lshr(is_ops[mark], is_ops[mark + 1], op_exact(i), q, mr); }
    if o == OP_ASHR { return simplify_ashr(is_ops[mark], is_ops[mark + 1], op_exact(i), q, mr); }
    if o == OP_AND { return simplify_and(is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_OR { return simplify_or(is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_XOR { return simplify_xor(is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_ICMP { return simplify_icmp(cp(x.pred as i64, (x.flags & FL_SAMESIGN) != 0), is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_FCMP { return simplify_fcmp(x.pred as i64, is_ops[mark], is_ops[mark + 1], x.fmf, q, mr); }
    if o == OP_SELECT {
        let fmf = if is_fp_math_operator(i) { x.fmf } else { 0 };
        return simplify_select(is_ops[mark], is_ops[mark + 1], is_ops[mark + 2], fmf, q, mr);
    }
    if o == OP_GEP { return simplify_gep(x.ty2, is_ops[mark], mark + 1, n - 1, x.flags, q, mr); }
    if o == OP_INSERTVALUE { return simplify_insertvalue(i, is_ops[mark], is_ops[mark + 1], q); }
    if o == OP_INSERTELEMENT { return simplify_insertelement(is_ops[mark], is_ops[mark + 1], is_ops[mark + 2], q); }
    if o == OP_EXTRACTVALUE { return simplify_extractvalue(i, is_ops[mark], q); }
    if o == OP_EXTRACTELEMENT { return simplify_extractelement(is_ops[mark], is_ops[mark + 1], q); }
    if o == OP_SHUFFLEVECTOR { return simplify_shufflevector(i, is_ops[mark], is_ops[mark + 1], q, mr); }
    if o == OP_PHI { return simplify_phi(i, mark, n, q); }
    if o == OP_CALL {
        let nb = cb_bundle_ops(i);
        return simplify_call(i, is_ops[mark + n - 1], mark, n - 1 - nb, q);
    }
    if o == OP_FREEZE { return simplify_freeze(is_ops[mark], q); }
    if is_cast_op(o) { return simplify_cast(o, is_ops[mark], vals[i].ty, q, mr); }
    if o == OP_ALLOCA { return -1; }
    if o == OP_LOAD { return simplify_load(i, is_ops[mark], q); }
    // default: constant fold if all operands are constant
    for k in n { if !is_constant(is_ops[mark + k]) { return -1; } }
    return cf_fold_inst_operands(i, mark, n, true);
}

// simplifyInstruction(I, SQ)
fn simplify_instruction(iv: i32) -> i32 {
    let mark = is_ops.len;
    let n = nops(iv);
    for k in n { is_ops.push(op(iv, k)); }
    let r = simplify_inst_with_ops(iv, mark, n, sq_new(-1), RECURSION_LIMIT);
    is_ops.resize(mark);
    if r == iv { return c_poison(vals[iv].ty); }
    return r;
}

// ---------------------------------------------------------------------------------------------
// The instsimplify pass (InstSimplifyPass.cpp runImpl)

// isInstructionTriviallyDead(&I) without a TargetLibraryInfo (InstSimplifyPass passes none there; the
// RecursivelyDeleteTriviallyDeadInstructions call gets SQ.TLI)
fn is_trivially_dead_without_tli(i: i32) -> bool {
    local_have_tli = false;
    let r = is_instruction_trivially_dead(i);
    local_have_tli = true;
    return r;
}

fn instsimplify_run(fv: i32) -> u32 {
    tli_cur_fn = fv;
    local_have_tli = true;
    dt_get(fv, DT_DOM);
    vt_invalidate_assumes();
    ac_invalidate();
    var changed = false;
    // debug records (VS_PASS1: values they mention) for RAUW and salvageDebugInfo
    m2r_collect_records(fv);
    // ToSimplify / Next: scratch sets VS_PASS2 / VS_PASS3 (swapped by index)
    var cur_set = VS_PASS2;
    var next_set = VS_PASS3;
    vs_clear(cur_set);
    vs_clear(next_set);
    var cur_empty = true;
    var next_count = 0;
    loop {
        var bb = func_entry(fv);
        while bb >= 0 {
            if !dt_has_node(DT_DOM, bb) { bb = block_next(bb); continue; }
            var dead: i32[>..<] = [];
            var it = block_first(bb);
            while it >= 0 {
                let i = it;
                it = inst_next(it);
                if !cur_empty && !vs_has(cur_set, i) { continue; }
                if is_trivially_dead_without_tli(i) {
                    dead.push(i);
                    changed = true;
                } else if vals[i].first_use >= 0 {
                    let v = simplify_instruction(i);
                    if v >= 0 {
                        var u = vals[i].first_use;
                        while u >= 0 {
                            let us = uses[u].user;
                            if vs_add(next_set, us) { next_count++; }
                            u = uses[u].next;
                        }
                        ac_rauw(i, v);
                        rauw(i, v);
                        if dbgrecs.len > 0 { m2r_dbg_rauw(i, v); }
                        changed = true;
                        if is_trivially_dead_without_tli(i) { dead.push(i); }
                    }
                }
            }
            recursively_delete_trivially_dead(dead);
            bb = block_next(bb);
        }
        let t = cur_set; cur_set = next_set; next_set = t;
        vs_clear(next_set);
        cur_empty = next_count == 0;
        next_count = 0;
        if cur_empty { break; }
    }
    if !changed { return 0xFFFFFFFF; }
    return 3;
}

// RecursivelyDeleteTriviallyDeadInstructions(DeadInsts): the list holds WeakTrackingVHs; entries that were
// already deleted are skipped.
fn recursively_delete_trivially_dead(dead: i32[>..<]&) {
    var wl: i32[>..<] = [];
    for d in dead {
        if is_dead(d) { continue; }
        if is_instruction_trivially_dead(d) { wl.push(d); }
    }
    while wl.len > 0 {
        let i = wl.pop();
        if is_dead(i) { continue; }
        salvage_debug_info(i);
        for k in nops(i) {
            let opv = op(i, k);
            set_op(i, k, -1);
            if opv < 0 || !has_use_list(opv) || vals[opv].first_use >= 0 { continue; }
            if is_inst(opv) && is_instruction_trivially_dead(opv) { wl.push(opv); }
        }
        m2r_erase(i);
    }
}
