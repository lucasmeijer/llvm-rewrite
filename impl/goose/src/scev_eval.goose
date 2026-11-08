// ScalarEvolution: evaluation. BinomialCoefficient / evaluateAtIteration, constant evolution (brute-force
// exit counts and exit values), getSCEVAtScope / computeSCEVAtScope, getNumIterationsInRange,
// SolveLinEquationWithOverflow, howFarToZero / howFarToNonZero, loop and block dispositions.
// Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
import std;
import scev_lt;
import scev_guards;
import implied;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import cfold;
import constfold;
import instsimplify;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;

let LD_VARIANT = 0;
let LD_INVARIANT = 1;
let LD_COMPUTABLE = 2;
let LD_UNIFORM = 3;
let BD_DOES_NOT_DOMINATE = 0;
let BD_DOMINATES = 1;
let BD_PROPERLY_DOMINATES = 2;

struct AtScope { res: i32, genv: i32, genr: i32 }
var sc_atscopes: AtScope[>..];
var sc_ce_serial: i32 = 0;
var sc_ce_vals = hm_new();       // EvaluateExpression's Vals: (serial, inst) -> constant + 1 (0 = null)

recursive fn scev_reset_eval() { sc_atscopes.resize(0); sc_ce_serial = 0; hm_clear(sc_ce_vals); }

// ---------------------------------------------------------------------------------------------
// BinomialCoefficient / evaluateAtIteration

recursive fn sc_binomial_coefficient(it: i32, k: i64, rty: i32) -> i32 {
    if k == 1 { return sc_get_truncate_or_zero_extend(it, rty, 0); }
    if k > 1000 { return SCEV_CNC; }
    let w = sc_type_bits(rty);
    var odd = ap_u64(1, w);
    var t: i64 = 1;
    var i: i64 = 3;
    while i <= k {
        let tf = ctz_w(i as u64, 64);
        t += tf;
        odd = ap_mul(odd, ap_u64((i >> tf) as u64, w));
        i++;
    }
    let cb = w + t;
    let div = ap_one_bit(cb, t);
    let mf = ap_mult_inverse(odd);
    let cty = ty_int(cb);
    var dividend = sc_get_truncate_or_zero_extend(it, cty, 0);
    var j: i64 = 1;
    while j != k {
        let s = sc_minus(it, sc_get_constant_ty(sc_ty(it), j as u64, false));
        dividend = sc_mul(dividend, sc_get_truncate_or_zero_extend(s, cty, 0));
        j++;
    }
    let dr = sc_get_udiv(dividend, sc_get_constant(div));
    return sc_mul(sc_get_constant(mf), sc_get_truncate_or_zero_extend(dr, rty, 0));
}

// APInt::multiplicativeInverse (of an odd value), modulo 2^w (Newton's iteration)
recursive fn ap_mult_inverse(a: AP) -> AP {
    let w = a.w as i64;
    var x = a;
    var i: i64 = 0;
    // x_{n+1} = x_n * (2 - a * x_n); 3 correct bits to start (a * a == 1 mod 8)
    var bits: i64 = 3;
    while bits < w {
        x = ap_mul(x, ap_sub(ap_u64(2, w), ap_mul(a, x)));
        bits *= 2;
        i++;
    }
    return x;
}

// SCEVAddRecExpr::evaluateAtIteration(Operands = the AddRec's, It)
recursive fn sc_evaluate_at_iteration(ar: i32, it: i32) -> i32 {
    var r = sc_op(ar, 0);
    for i in 1..sc_nops(ar) {
        let c = sc_binomial_coefficient(it, i, sc_ty(r));
        if sc_is_cnc(c) { return c; }
        r = sc_add(r, sc_mul(sc_op(ar, i), c));
    }
    return r;
}

// ---------------------------------------------------------------------------------------------
// Constant evolution

recursive fn sc_is_cast_op(o: i64) -> bool { o >= OP_TRUNC && o <= OP_ADDRSPACECAST }
// CanConstantFold
recursive fn sc_can_constant_fold(i: i32) -> bool {
    let o = iop(i);
    if (o >= OP_ADD && o <= OP_XOR) || o == OP_ICMP || o == OP_FCMP || o == OP_SELECT || sc_is_cast_op(o) || o == OP_GEP ||
       o == OP_LOAD || o == OP_EXTRACTVALUE { return true; }
    if o == OP_CALL {
        let f = called_function(i);
        if f >= 0 && is_func(f) { return can_constant_fold_call_to(i, f); }
    }
    return false;
}
recursive fn sc_can_constant_evolve(i: i32, l: i32) -> bool {
    if !loop_contains(l, inst_parent(i)) { return false; }
    if iop(i) == OP_PHI { return loop_header(l) == inst_parent(i); }
    return sc_can_constant_fold(i);
}
recursive fn sc_is_constant_value(v: i32) -> bool { let k = vals[v].kind as i64; k != VK_INST && k != VK_ARG && k != VK_BLOCK && k != VK_MDVAL && k != VK_INLINEASM }

// getConstantEvolvingPHIOperands (PHIMap on an HMap with a serial)
recursive fn sc_constant_evolving_phi_operands(u: i32, l: i32, serial: i32, depth: i64) -> i32 {
    if depth > sc_max_constant_evolving_depth { return -1; }
    var phi: i32 = -1;
    for k in nops(u) {
        let o = op(u, k);
        if sc_is_constant_value(o) { continue; }
        if !is_inst(o) || !sc_can_constant_evolve(o, l) { return -1; }
        var p: i32 = if iop(o) == OP_PHI { o } else { -1 };
        if p < 0 { p = (hm_get(sc_ce_vals, hk2(serial, o), 0) - 1) as i32; }
        if p < 0 {
            p = sc_constant_evolving_phi_operands(o, l, serial, depth + 1);
            hm_put(sc_ce_vals, hk2(serial, o), (p + 1) as i64);
        }
        if p < 0 { return -1; }
        if phi >= 0 && phi != p { return -1; }
        phi = p;
    }
    return phi;
}

recursive fn sc_get_constant_evolving_phi(v: i32, l: i32) -> i32 {
    if !is_inst(v) || !sc_can_constant_evolve(v, l) { return -1; }
    if iop(v) == OP_PHI { return v; }
    sc_ce_serial++;
    return sc_constant_evolving_phi_operands(v, l, sc_ce_serial, 0);
}

recursive fn ce_get(serial: i32, i: i32) -> i32 { (hm_get(sc_ce_vals, hk2(serial, i), 0) - 1) as i32 }
recursive fn ce_has(serial: i32, i: i32) -> bool { hm_has(sc_ce_vals, hk2(serial, i)) }
recursive fn ce_set(serial: i32, i: i32, c: i32) { hm_put(sc_ce_vals, hk2(serial, i), (c + 1) as i64); }

// EvaluateExpression(V, L, Vals = map `serial`)
recursive fn sc_evaluate_expression(v: i32, l: i32, serial: i32) -> i32 {
    if sc_is_constant_value(v) { return v; }
    if !is_inst(v) { return -1; }
    let c = ce_get(serial, v);
    if c >= 0 { return c; }
    if !sc_can_constant_evolve(v, l) { return -1; }
    if iop(v) == OP_PHI { return -1; }
    let mark = is_ops.len;
    for i in nops(v) {
        let o = op(v, i);
        if !is_inst(o) {
            if !sc_is_constant_value(o) { is_ops.resize(mark); return -1; }
            is_ops.push(o);
            continue;
        }
        let x = sc_evaluate_expression(o, l, serial);
        ce_set(serial, o, x);
        if x < 0 { is_ops.resize(mark); return -1; }
        is_ops.push(x);
    }
    let r = cf_fold_inst_operands(v, mark, nops(v), false);
    is_ops.resize(mark);
    return r;
}

// getOtherIncomingValue(PN, BB)
recursive fn sc_other_incoming_value(pn: i32, bb: i32) -> i32 {
    var inc: i32 = -1;
    for i in phi_nincoming(pn) {
        if phi_block(pn, i) == bb { continue; }
        let cv = phi_value(pn, i);
        if !sc_is_constant_value(cv) { return -1; }
        if inc != cv {
            if inc >= 0 { return -1; }
            inc = cv;
        }
    }
    return inc;
}

// The header PHIs in a DenseMap's iteration order are only used to recompute every PHI: the order is irrelevant.
recursive fn sc_compute_exit_count_exhaustively(l: i32, cond: i32, exit_when: bool) -> i32 {
    let pn = sc_get_constant_evolving_phi(cond, l);
    if pn < 0 { return SCEV_CNC; }
    if phi_nincoming(pn) != 2 { return SCEV_CNC; }
    let header = loop_header(l);
    let latch = loop_latch(l);
    sc_ce_serial++;
    var cur = sc_ce_serial;
    let pm = sc_tmp.len;
    var p = block_first(header);
    while p >= 0 && is_phi(p) { sc_tmp.push(p); p = inst_next(p); }
    let pe = sc_tmp.len;
    for xk in pm..pe { let x = sc_tmp[xk]; let sc = sc_other_incoming_value(x, latch); if sc >= 0 { ce_set(cur, x, sc); } }
    if !ce_has(cur, pn) { return SCEV_CNC; }
    var it: i64 = 0;
    while it != sc_max_brute_force_iterations {
        let cv = sc_evaluate_expression(cond, l, cur);
        if cv < 0 || vals[cv].kind as i64 != VK_CINT { return SCEV_CNC; }
        if ap_eq_u64(ap_zext_or_trunc(ap_from_cint(cv), 64), if exit_when { 1 } else { 0 }) && ap_active_bits(ap_from_cint(cv)) <= 64 {
            return sc_get_constant_ty(ty_int(32), it as u64, false);
        }
        sc_ce_serial++;
        let next = sc_ce_serial;
        for xk in pm..pe {
            let x = sc_tmp[xk];
            if !ce_has(cur, x) { continue; }
            if ce_has(next, x) && ce_get(next, x) >= 0 { continue; }
            let bev = phi_value(x, phi_block_index(x, latch));
            ce_set(next, x, sc_evaluate_expression(bev, l, cur));
        }
        cur = next;
        it++;
    }
    return SCEV_CNC;
}

// getConstantEvolutionLoopExitValue: constant value id or -1
recursive fn sc_constant_evolution_loop_exit_value(pn: i32, bes: AP, l: i32) -> i32 {
    if hm_has(sc_cevl_exit, pn as u64) { return hm_get(sc_cevl_exit, pn as u64, -1) as i32; }
    hm_put(sc_cevl_exit, pn as u64, -1);
    if ap_ugt_u64(bes, sc_max_brute_force_iterations as u64) { return -1; }
    let header = loop_header(l);
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    sc_ce_serial++;
    var cur = sc_ce_serial;
    let pm = sc_tmp.len;
    var p = block_first(header);
    while p >= 0 && is_phi(p) { sc_tmp.push(p); p = inst_next(p); }
    let pe = sc_tmp.len;
    for xk in pm..pe { let x = sc_tmp[xk]; let sc = sc_other_incoming_value(x, latch); if sc >= 0 { ce_set(cur, x, sc); } }
    if !ce_has(cur, pn) { hm_put(sc_cevl_exit, pn as u64, -1); return -1; }
    let bev = phi_value(pn, phi_block_index(pn, latch));
    let n = ap_lo64(bes) as i64;
    var itn: i64 = 0;
    loop {
        if itn == n { let r = ce_get(cur, pn); hm_put(sc_cevl_exit, pn as u64, r as i64); return r; }
        sc_ce_serial++;
        let next = sc_ce_serial;
        let np = sc_evaluate_expression(bev, l, cur);
        if np < 0 { return -1; }
        ce_set(next, pn, np);
        var stopped = np == ce_get(cur, pn);
        for xk in pm..pe {
            let x = sc_tmp[xk];
            if !ce_has(cur, x) || x == pn { continue; }
            var nx = if ce_has(next, x) { ce_get(next, x) } else { -1 };
            if nx < 0 {
                let bv = phi_value(x, phi_block_index(x, latch));
                nx = sc_evaluate_expression(bv, l, cur);
                ce_set(next, x, nx);
            }
            if nx != ce_get(cur, x) { stopped = false; }
        }
        if stopped { let r = ce_get(cur, pn); hm_put(sc_cevl_exit, pn as u64, r as i64); return r; }
        cur = next;
        itn++;
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// getSCEVAtScope

recursive fn sc_atscope_key(v: i32, l: i32) -> u64 { hk2(v, l + 1) }

recursive fn sc_get_scev_at_scope(v: i32, l: i32) -> i32 {
    let key = sc_atscope_key(v, l);
    let f = hm_get(sc_atscope, key, -1);
    if f >= 0 {
        let a = sc_atscopes[f];
        if a.genv == sc_gen(v) && (a.res < 0 || a.genr == sc_gen(a.res)) {
            return if a.res >= 0 { a.res } else { v };
        }
    }
    let idx = sc_atscopes.len;
    sc_atscopes.push(AtScope { res: -1, genv: sc_gen(v), genr: 0 });
    hm_put(sc_atscope, key, idx);
    let c = sc_compute_scev_at_scope(v, l);
    let f2 = hm_get(sc_atscope, key, -1);
    if f2 >= 0 { sc_atscopes[f2] = AtScope { res: c, genv: sc_gen(v), genr: if sc_is_const(c) { 0 } else { sc_gen(c) } }; }
    return c;
}

// BuildConstantFromSCEV: constant value id or -1
recursive fn sc_build_constant_from_scev(v: i32) -> i32 {
    let k = sc_kind(v);
    if k == SC_CONST { return sc_cval(v); }
    if k == SC_UNKNOWN { let x = sc_value(v); return if sc_is_constant_value(x) { x } else { -1 }; }
    if k == SC_PTRTOADDR {
        let c = sc_build_constant_from_scev(sc_op(v, 0));
        if c >= 0 { return ce_cast(OP_PTRTOADDR, c, sc_ty(v)); }
        return -1;
    }
    if k == SC_PTRTOINT {
        let c = sc_build_constant_from_scev(sc_op(v, 0));
        if c >= 0 { return ce_cast(OP_PTRTOINT, c, sc_ty(v)); }
        return -1;
    }
    if k == SC_TRUNC {
        let c = sc_build_constant_from_scev(sc_op(v, 0));
        if c >= 0 { return ce_cast(OP_TRUNC, c, sc_ty(v)); }
        return -1;
    }
    if k == SC_ADD {
        var c: i32 = -1;
        for i in sc_nops(v) {
            let oc = sc_build_constant_from_scev(sc_op(v, i));
            if oc < 0 { return -1; }
            if c < 0 { c = oc; continue; }
            if ty_kind(vals[oc].ty) == TK_PTR {
                let idx: i32[1] = [c];
                c = ce_gep(ty_int(8), oc, idx[..], 0, -1);
            } else { c = ce_binop(OP_ADD, c, oc, 0); }
        }
        return c;
    }
    return -1;
}

// getWithOperands(S, NewOps = ss[b..])
recursive fn sc_get_with_operands(s: i32, b: i64) -> i32 {
    let k = sc_kind(s);
    if sc_is_cast_kind(k) {
        let o = ss[b];
        ss.resize(b);
        if k == SC_TRUNC { return sc_get_truncate(o, sc_ty(s), 0); }
        if k == SC_ZEXT { return sc_get_zero_extend(o, sc_ty(s), 0); }
        if k == SC_SEXT { return sc_get_sign_extend(o, sc_ty(s), 0); }
        if k == SC_PTRTOADDR { return sc_get_ptr_to_addr(o); }
        return sc_get_ptr_to_int(o, sc_ty(s));
    }
    if k == SC_ADDREC { return sc_addrec_n(b, sc_loop(s), sc_flags(s)); }
    if k == SC_ADD { return sc_add_n(b, sc_flags(s) & (SF_NUW | SF_NSW), 0); }
    if k == SC_MUL { return sc_mul_n(b, sc_flags(s) & (SF_NUW | SF_NSW), 0); }
    if k == SC_UDIV { let x = ss[b]; let y = ss[b + 1]; ss.resize(b); return sc_get_udiv(x, y); }
    if sc_is_minmax_kind(k) { return sc_minmax_n(k, b); }
    if k == SC_SEQUMIN { return sc_seq_minmax_n(k, b); }
    ss.resize(b);
    return s;
}

recursive fn sc_compute_scev_at_scope(v: i32, l: i32) -> i32 {
    let k = sc_kind(v);
    if k == SC_CONST || k == SC_VSCALE { return v; }
    if k == SC_ADDREC {
        var ar = v;
        let e = sc_nops(ar);
        for i in e {
            let oas = sc_get_scev_at_scope(sc_op(ar, i), l);
            if oas == sc_op(ar, i) { continue; }
            let b = ss.len;
            for j in i { ss.push(sc_op(ar, j)); }
            ss.push(oas);
            for j in i + 1..e { let x = sc_get_scev_at_scope(sc_op(ar, j), l); ss.push(x); }
            let fr = sc_addrec_n(b, sc_loop(ar), sc_flags(ar) & SF_NW);
            if !sc_is_addrec(fr) { return fr; }
            ar = fr;
            break;
        }
        if !loop_contains_loop_or_null(sc_loop(ar), l) {
            let btc = sc_get_backedge_taken_count(sc_loop(ar), BTC_EXACT);
            if sc_is_cnc(btc) { return ar; }
            return sc_evaluate_at_iteration(ar, btc);
        }
        return ar;
    }
    if k == SC_UNKNOWN {
        let i = sc_value(v);
        if !is_inst(i) { return v; }
        if iop(i) == OP_PHI {
            let cl = li_loop_for(inst_parent(i));
            if cl >= 0 && loop_parent(cl) == l && inst_parent(i) == loop_header(cl) {
                let btc = sc_get_backedge_taken_count(cl, BTC_EXACT);
                if sc_is_zero(btc) {
                    var init: i32 = -1;
                    var multi = false;
                    for j in phi_nincoming(i) {
                        if !loop_contains(cl, phi_block(i, j)) {
                            if init < 0 { init = phi_value(i, j); }
                            else if init != phi_value(i, j) { multi = true; break; }
                        }
                    }
                    if !multi && init >= 0 { return sc_get_scev(init); }
                }
                if !sc_is_cnc(btc) && sc_is_known_non_zero(btc) && phi_nincoming(i) == 2 {
                    let inl: i64 = if loop_contains(cl, phi_block(i, 0)) { 0 } else { 1 };
                    let bv = phi_value(i, inl);
                    if sc_value_loop_invariant(cl, bv) { return sc_get_scev(bv); }
                }
                if sc_is_const(btc) {
                    let rv = sc_constant_evolution_loop_exit_value(i, sc_ap(btc), cl);
                    if rv >= 0 { return sc_get_scev(rv); }
                }
            }
        }
        if !sc_can_constant_fold(i) { return v; }
        let mark = is_ops.len;
        var improved = false;
        for j in nops(i) {
            let o = op(i, j);
            if sc_is_constant_value(o) { is_ops.push(o); continue; }
            if !sc_is_scevable(vals[o].ty) { is_ops.resize(mark); return v; }
            let orig = sc_get_scev(o);
            let ov = sc_get_scev_at_scope(orig, l);
            if orig != ov { improved = true; }
            let c = sc_build_constant_from_scev(ov);
            if c < 0 { is_ops.resize(mark); return v; }
            is_ops.push(c);
        }
        if !improved { is_ops.resize(mark); return v; }
        let c = cf_fold_inst_operands(i, mark, nops(i), false);
        is_ops.resize(mark);
        if c < 0 { return v; }
        return sc_get_scev(c);
    }
    // casts, n-ary, udiv
    let e = sc_nops(v);
    for i in e {
        let oas = sc_get_scev_at_scope(sc_op(v, i), l);
        if oas != sc_op(v, i) {
            let b = ss.len;
            for j in i { ss.push(sc_op(v, j)); }
            ss.push(oas);
            for j in i + 1..e { let x = sc_get_scev_at_scope(sc_op(v, j), l); ss.push(x); }
            return sc_get_with_operands(v, b);
        }
    }
    return v;
}

// Loop::contains(Loop) with a null L (the function body): a loop never contains null
recursive fn loop_contains_loop_or_null(a: i32, l: i32) -> bool { if l < 0 { false } else { loop_contains_loop(a, l) } }

// stripInjectiveFunctions
recursive fn sc_strip_injective(s: i32) -> i32 {
    var x = s;
    while sc_kind(x) == SC_ZEXT || sc_kind(x) == SC_SEXT { x = sc_op(x, 0); }
    return x;
}

// getNumIterationsInRange
recursive fn sc_get_num_iterations_in_range(ar: i32, range: CRange) -> i32 {
    if rg_is_full(range) { return SCEV_CNC; }
    let st = sc_op(ar, 0);
    if sc_is_const(st) && !sc_is_zero(st) {
        let b = ss.len;
        ss_push_ops(ar);
        let z0 = sc_get_zero(sc_ty(st));
        ss[b] = z0;
        let sh = sc_addrec_n(b, sc_loop(ar), sc_flags(ar) & SF_NW);
        if sc_is_addrec(sh) { return sc_get_num_iterations_in_range(sh, rg_subtract(range, sc_ap(st))); }
        return SCEV_CNC;
    }
    for i in sc_nops(ar) { if !sc_is_const(sc_op(ar, i)) { return SCEV_CNC; } }
    let bw = sc_bits(ar);
    if !rg_contains_ap(range, ap_zero(bw)) { return sc_get_zero(sc_ty(ar)); }
    if sc_is_affine(ar) {
        let a = sc_ap(sc_op(ar, 1));
        let end = if ap_sge(a, ap_u64(1, bw)) { ap_dec(range.hi) } else { range.lo };
        let ev = ap_udiv(ap_add(end, a), a);
        let val = sc_evaluate_at_iteration(ar, sc_get_constant(ev));
        if rg_contains_ap(range, sc_ap(val)) { return SCEV_CNC; }
        return sc_get_constant(ev);
    }
    if sc_is_quadratic(ar) { fatal("ScalarEvolution: SolveQuadraticAddRecRange is not ported"); }
    return SCEV_CNC;
}

// SolveLinEquationWithOverflow (Predicates: allow_preds)
recursive fn sc_solve_lin_equation_with_overflow(a: AP, b: i32, allow_preds: bool, l: i32) -> i32 {
    let bw = a.w as i64;
    let mult2 = ap_countr_zero(a);
    var mtz = sc_get_min_trailing_zeros(b);
    let lp = loop_predecessor(l);
    if mtz < mult2 && lp >= 0 { mtz = sc_get_min_trailing_zeros_cx(b, block_last(lp)); }
    if mtz < mult2 {
        let urem = sc_get_urem(b, sc_get_constant(ap_one_bit(bw, mult2)));
        let zero = sc_get_zero(sc_ty(b));
        if !sc_is_known_predicate(P_EQ, urem, zero) {
            if !allow_preds { return SCEV_CNC; }
            if sc_is_known_predicate(P_NE, urem, zero) { return SCEV_CNC; }
            sc_lin_preds.push(sc_get_compare_predicate(P_EQ, urem, zero));
        }
    }
    let ad = ap_trunc(ap_lshr(a, mult2), bw - mult2);
    let inv = ap_zext(ap_mult_inverse(ad), bw);
    let d = sc_get_constant(ap_one_bit(bw, mult2));
    return sc_get_udiv(sc_mul(b, sc_get_constant(inv)), d);
}
var sc_lin_preds: i32[>..<];

// howFarToZero
recursive fn sc_how_far_to_zero(v: i32, l: i32, only: bool, allow_preds: bool) -> EL {
    if sc_is_const(v) {
        if sc_is_zero(v) { return el_one(v); }
        return el_cnc();
    }
    let pm = sc_lin_preds.len;
    var ar = sc_strip_injective(v);
    if !sc_is_addrec(ar) { ar = -1; }
    if ar < 0 && allow_preds { ar = sc_convert_to_addrec_with_predicates(v, l); }
    if ar < 0 || sc_loop(ar) != l { sc_lin_preds.resize(pm); return el_cnc(); }
    if sc_is_quadratic(ar) && ty_is_int(sc_ty(ar)) { fatal("ScalarEvolution: SolveQuadraticAddRecExact is not ported"); }
    if !sc_is_affine(ar) { sc_lin_preds.resize(pm); return el_cnc(); }
    let pl = loop_parent(l);
    let start = sc_get_scev_at_scope(sc_op(ar, 0), pl);
    let step = sc_get_scev_at_scope(sc_op(ar, 1), pl);
    if !sc_is_loop_invariant(step, l) { sc_lin_preds.resize(pm); return el_cnc(); }
    let guards = sc_loop_guards_collect(l);
    let stepg = sc_apply_loop_guards_g(step, guards);
    let down = sc_is_known_negative(stepg);
    if !down && !sc_is_known_non_negative(stepg) { sc_lin_preds.resize(pm); return el_cnc(); }
    let dist = if down { start } else { sc_get_negative(start, SF_ANY) };
    if sc_is_one(step) || sc_is_all_ones(step) {
        var mbc = sc_get_unsigned_range_max(sc_apply_loop_guards_g(dist, guards));
        mbc = ap_umin(mbc, sc_get_unsigned_range_max(dist));
        let zero = sc_get_zero(sc_ty(dist));
        let one = sc_get_one(sc_ty(dist));
        let dp1 = sc_add(dist, one);
        if sc_is_loop_entry_guarded_by_cond(l, P_NE, dp1, zero) {
            let cr = sc_get_unsigned_range(dp1);
            mbc = ap_umin(mbc, ap_dec(rg_umax(cr)));
        }
        let pat, np = sc_preds_from_lin(pm);
        return el_make(dist, sc_get_constant(mbc), dist, false, pat, np);
    }
    if only && sc_has_nw(ar) && sc_loop_has_no_abnormal_exits(sc_loop(ar)) {
        if !(sc_loop_is_finite_by_assumption(l) && sc_is_known_non_zero(start)) && !sc_is_known_non_zero(stepg) {
            sc_lin_preds.resize(pm);
            return el_cnc();
        }
        let exact = sc_get_udiv(dist, if down { sc_get_negative(step, SF_ANY) } else { step });
        var cmax = SCEV_CNC;
        if !sc_is_cnc(exact) {
            let mi = sc_get_unsigned_range_max(sc_apply_loop_guards_g(exact, guards));
            cmax = sc_get_constant(ap_umin(mi, sc_get_unsigned_range_max(exact)));
        }
        let smax = if sc_is_cnc(exact) { cmax } else { exact };
        let pat, np = sc_preds_from_lin(pm);
        return el_make(exact, cmax, smax, false, pat, np);
    }
    if !sc_is_const(step) || sc_is_zero(step) { sc_lin_preds.resize(pm); return el_cnc(); }
    let e = sc_solve_lin_equation_with_overflow(sc_ap(step), sc_get_negative(start, SF_ANY), allow_preds, l);
    var m = e;
    if !sc_is_cnc(e) {
        let mg = sc_get_unsigned_range_max(sc_apply_loop_guards_g(e, guards));
        m = sc_get_constant(ap_umin(mg, sc_get_unsigned_range_max(e)));
    }
    let s = if sc_is_cnc(e) { m } else { e };
    let pat, np = sc_preds_from_lin(pm);
    return el_make(e, m, s, false, pat, np);
}

// the predicates collected on sc_lin_preds from mark pm, moved to sc_predl
recursive fn sc_preds_from_lin(pm: i64) -> i32, i32 {
    if sc_lin_preds.len == pm { return 0, 0; }
    let at = sc_predl.len as i32;
    for k in pm..sc_lin_preds.len { let p = sc_lin_preds[k]; if !sc_predl_has(at, p) { sc_predl.push(p); } }
    sc_lin_preds.resize(pm);
    return at, (sc_predl.len as i32) - at;
}

recursive fn sc_how_far_to_non_zero(v: i32, l: i32) -> EL {
    if sc_is_const(v) {
        if !sc_is_zero(v) { return el_one(sc_get_zero(sc_ty(v))); }
        return el_cnc();
    }
    return el_cnc();
}

// ---------------------------------------------------------------------------------------------
// Dispositions (stored with the SCEV's generation: forgetMemoizedResults erases them)

recursive fn sc_get_loop_disposition(s: i32, l: i32) -> i64 {
    let key = sc_atscope_key(s, l);
    let g = sc_gen(s) as i64;
    let f = hm_get(sc_ldisp, key, -1);
    if f >= 0 && (f >> 8) == g { return f & 0xFF; }
    hm_put(sc_ldisp, key, (g << 8) | LD_VARIANT);
    let d = sc_compute_loop_disposition(s, l);
    hm_put(sc_ldisp, key, ((sc_gen(s) as i64) << 8) | d);
    return d;
}

recursive fn sc_compute_loop_disposition(s: i32, l: i32) -> i64 {
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE { return LD_INVARIANT; }
    if k == SC_ADDREC {
        let al = sc_loop(s);
        if al == l { return LD_COMPUTABLE; }
        if l < 0 { return LD_VARIANT; }
        if dt_dominates_block(DT_DOM, loop_header(l), loop_header(al)) {
            if loop_contains_loop(l, al) {
                var all = true;
                for i in sc_nops(s) { if !sc_is_loop_uniform(sc_op(s, i), l) { all = false; break; } }
                if all { return LD_UNIFORM; }
            }
            return LD_VARIANT;
        }
        if loop_contains_loop(al, l) { return LD_INVARIANT; }
        for i in sc_nops(s) { if !sc_is_loop_invariant(sc_op(s, i), l) { return LD_VARIANT; } }
        return LD_INVARIANT;
    }
    if k == SC_UNKNOWN {
        let v = sc_value(s);
        if is_inst(v) { return if l >= 0 && !loop_contains(l, inst_parent(v)) { LD_INVARIANT } else { LD_VARIANT }; }
        return LD_INVARIANT;
    }
    var varying = false;
    var uniform = false;
    for i in sc_nops(s) {
        let d = sc_get_loop_disposition(sc_op(s, i), l);
        if d == LD_VARIANT { return LD_VARIANT; }
        if d == LD_COMPUTABLE { varying = true; }
        if d == LD_UNIFORM { uniform = true; }
    }
    return if varying { if uniform { LD_VARIANT } else { LD_COMPUTABLE } } else { if uniform { LD_UNIFORM } else { LD_INVARIANT } };
}

recursive fn sc_is_loop_uniform(s: i32, l: i32) -> bool { let d = sc_get_loop_disposition(s, l); return d == LD_UNIFORM || d == LD_INVARIANT; }
recursive fn sc_is_loop_invariant(s: i32, l: i32) -> bool { sc_get_loop_disposition(s, l) == LD_INVARIANT }
recursive fn sc_has_computable_loop_evolution(s: i32, l: i32) -> bool { sc_get_loop_disposition(s, l) == LD_COMPUTABLE }

recursive fn sc_get_block_disposition(s: i32, bb: i32) -> i64 {
    let key = hk2(s, bb);
    let g = sc_gen(s) as i64;
    let f = hm_get(sc_bdisp, key, -1);
    if f >= 0 && (f >> 8) == g { return f & 0xFF; }
    hm_put(sc_bdisp, key, (g << 8) | BD_DOES_NOT_DOMINATE);
    let d = sc_compute_block_disposition(s, bb);
    hm_put(sc_bdisp, key, ((sc_gen(s) as i64) << 8) | d);
    return d;
}

recursive fn sc_compute_block_disposition(s: i32, bb: i32) -> i64 {
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE { return BD_PROPERLY_DOMINATES; }
    if k == SC_UNKNOWN {
        let v = sc_value(s);
        if is_inst(v) {
            if inst_parent(v) == bb { return BD_DOMINATES; }
            if dt_properly_dominates_block(DT_DOM, inst_parent(v), bb) { return BD_PROPERLY_DOMINATES; }
            return BD_DOES_NOT_DOMINATE;
        }
        return BD_PROPERLY_DOMINATES;
    }
    if k == SC_ADDREC {
        if !dt_dominates_block(DT_DOM, loop_header(sc_loop(s)), bb) { return BD_DOES_NOT_DOMINATE; }
    }
    var proper = true;
    for i in sc_nops(s) {
        let d = sc_get_block_disposition(sc_op(s, i), bb);
        if d == BD_DOES_NOT_DOMINATE { return BD_DOES_NOT_DOMINATE; }
        if d == BD_DOMINATES { proper = false; }
    }
    return if proper { BD_PROPERLY_DOMINATES } else { BD_DOMINATES };
}

recursive fn sc_dominates(s: i32, bb: i32) -> bool { sc_get_block_disposition(s, bb) >= BD_DOMINATES }
recursive fn sc_properly_dominates(s: i32, bb: i32) -> bool { sc_get_block_disposition(s, bb) == BD_PROPERLY_DOMINATES }
recursive fn sc_is_available_at_loop_entry(s: i32, l: i32) -> bool { sc_is_loop_invariant(s, l) && sc_properly_dominates(s, loop_header(l)) }
