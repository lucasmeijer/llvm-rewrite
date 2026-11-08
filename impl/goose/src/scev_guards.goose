// ScalarEvolution::LoopGuards: collect (collectFromBlock, collectFromPHI, divisibility guards) and rewrite
// (SCEVLoopGuardRewriter), applyLoopGuards. Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
// A LoopGuards object is an id into sc_guards; its RewriteMap and NotEqual set live in hash maps keyed by the id.
import std;
import scev_lt;
import implied;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import gen_iids;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_range;
import scev_btc;
import scev_pred;
import scev_eval;

struct GInfo { nmap: i32, nne: i32, pnuw: bool, pnsw: bool }
var sc_guards: GInfo[>..];
var sc_gmap = hm_new();       // (guards, From) -> To
var sc_gne = hm_new();        // (guards, pair) -> 1
var sc_gpairs = hm_new();     // (a, b) -> pair index
var sc_gmult: i32[>..<];      // Multiples: (scev, value of the AP on sc_gmult_ap) in insertion order
var sc_gmult_ap: AP[>..<];
var sc_gexprs: i32[>..<];     // ExprsToRewrite
var sc_gwl: i32[>..<];        // worklists
var sc_gterms: i32[>..<];     // Terms: value, enter-if-true

recursive fn scev_reset_guards() { sc_guards.resize(0); hm_clear(sc_gmap); hm_clear(sc_gne); hm_clear(sc_gpairs); }

recursive fn sc_guards_new() -> i32 { sc_guards.push(GInfo { nmap: 0, nne: 0, pnuw: false, pnsw: false }); return (sc_guards.len - 1) as i32; }
recursive fn sc_gmap_get(g: i32, s: i32) -> i32 { hm_get(sc_gmap, hk2(g, s), -1) as i32 }
recursive fn sc_gmap_set(g: i32, s: i32, t: i32) {
    if !hm_has(sc_gmap, hk2(g, s)) { sc_guards[g].nmap += 1; }
    hm_put(sc_gmap, hk2(g, s), t as i64);
}
recursive fn sc_gpair(a0: i32, b0: i32) -> i64 {
    let a = if a0 < b0 { a0 } else { b0 };
    let b = if a0 < b0 { b0 } else { a0 };
    let k = hk2(a, b);
    let f = hm_get(sc_gpairs, k, -1);
    if f >= 0 { return f; }
    let n = sc_gpairs.n;
    hm_put(sc_gpairs, k, n);
    return n;
}
recursive fn sc_gne_add(g: i32, a: i32, b: i32) {
    let p = sc_gpair(a, b);
    let k = hk2(g, p as i32);
    if !hm_has(sc_gne, k) { sc_guards[g].nne += 1; hm_put(sc_gne, k, 1); }
}
recursive fn sc_gne_has(g: i32, a: i32, b: i32) -> bool { hm_has(sc_gne, hk2(g, sc_gpair(a, b) as i32)) }

// LoopGuards::collect
recursive fn sc_loop_guards_collect(l: i32) -> i32 {
    let g = sc_guards_new();
    let pr = loop_predecessor(l);
    if pr < 0 { return g; }
    let vm = sc_seen.len;
    sc_collect_from_block(g, loop_header(l), pr, vm, 0);
    sc_seen.resize(vm);
    return g;
}

recursive fn sc_visited_insert(vm: i64, b: i32) -> bool {
    for k in vm..sc_seen.len { if sc_seen[k] == b { return false; } }
    sc_seen.push(b);
    return true;
}

recursive fn sc_get_previous_divisible(e: i32, d: AP) -> i32 {
    if !sc_is_const(e) || ap_is_neg(sc_ap(e)) || !ap_is_strictly_pos(d) { return e; }
    let x = sc_ap(e);
    return sc_get_constant(ap_sub(x, ap_urem(x, d)));
}
recursive fn sc_get_next_divisible(e: i32, d: AP) -> i32 {
    if !sc_is_const(e) || ap_is_neg(sc_ap(e)) || !ap_is_strictly_pos(d) { return e; }
    let x = sc_ap(e);
    let r = ap_urem(x, d);
    if ap_is_zero(r) { return e; }
    return sc_get_constant(ap_sub(ap_add(x, d), r));
}

// collectFromPHI
recursive fn sc_collect_from_phi(g: i32, phi: i32, vm: i64, depth: i64, ser: i32) {
    if !sc_is_scevable(vals[phi].ty) { return; }
    // IncomingGuards: per incoming block a LoopGuards (block -> id on a local list)
    var pc: i32 = -1;
    var pk: i64 = SC_CNC;
    var ok = true;
    for i in phi_nincoming(phi) {
        let c, k = sc_get_minmax_const(phi, i, vm, depth, ser);
        if i == 0 { pc = c; pk = k; continue; }
        if pc < 0 { break; }
        // MergeMinMaxConst
        if c < 0 || pk != k { pc = -1; pk = SC_CNC; continue; }
        let a = sc_ap(pc);
        let b = sc_ap(c);
        if k == SC_UMAX { pc = if ap_ult(a, b) { pc } else { c }; }
        else if k == SC_SMAX { pc = if ap_slt(a, b) { pc } else { c }; }
        else if k == SC_UMIN { pc = if ap_ugt(a, b) { pc } else { c }; }
        else { pc = if ap_sgt(a, b) { pc } else { c }; }
    }
    if pc >= 0 {
        let lhs = sc_get_scev(phi);
        let rhs = sc_minmax2(pk, pc, lhs);
        if !hm_has(sc_gmap, hk2(g, lhs)) { sc_gmap_set(g, lhs, rhs); }
    }
}

var sc_incoming_guards = hm_new();   // (phi-collection serial, block) -> guards id
var sc_incoming_serial: i32 = 0;

recursive fn sc_get_minmax_const(phi: i32, idx: i64, vm: i64, depth: i64, ser: i32) -> i32, i64 {
    let inb = phi_block(phi, idx);
    if !sc_visited_insert(vm, inb) { return -1, SC_CNC; }
    if !dt_has_node(DT_DOM, inb) { return -1, SC_CNC; }
    let key = hk2(ser, inb);
    var gi = hm_get(sc_incoming_guards, key, -1) as i32;
    if gi < 0 {
        gi = sc_guards_new();
        hm_put(sc_incoming_guards, key, gi as i64);
        sc_collect_from_block(gi, inst_parent(phi), inb, vm, depth + 1);
    }
    if sc_guards[gi].nmap == 0 { return -1, SC_CNC; }
    let s = sc_gmap_get(gi, sc_get_scev(phi_value(phi, idx)));
    if s < 0 { return -1, SC_CNC; }
    if !sc_is_minmax_kind(sc_kind(s)) { return -1, SC_CNC; }
    if sc_is_const(sc_op(s, 0)) { return sc_op(s, 0), sc_kind(s); }
    return -1, SC_CNC;
}

// applyDivisibilityOnMinMaxExpr
recursive fn sc_apply_divisibility_on_minmax(e: i32, d: AP) -> i32 {
    if !sc_is_minmax_kind(sc_kind(e)) || sc_nops(e) != 2 { return e; }
    if !sc_is_const(sc_op(e, 0)) || ap_is_neg(sc_ap(sc_op(e, 0))) { return e; }
    let k = sc_kind(e);
    let is_min = k == SC_SMIN || k == SC_UMIN;
    let ml = sc_op(e, 0);
    let mr = sc_op(e, 1);
    let de = if is_min { sc_get_previous_divisible(ml, d) } else { sc_get_next_divisible(ml, d) };
    let x = sc_apply_divisibility_on_minmax(mr, d);
    return sc_minmax2(k, x, de);
}

// collectFromBlock
recursive fn sc_collect_from_block(g: i32, blk: i32, pred: i32, vm: i64, depth: i64) {
    let em = sc_gexprs.len;
    let tm = sc_gterms.len;
    if sc_has_assumptions() {
        let am = sc_tmp.len;
        sc_collect_assumes(sc_tmp);
        let ae = sc_tmp.len;
        for ak in am..ae {
            let a = sc_tmp[ak];
            if !dt_inst_dominates_block(a, blk) { continue; }
            sc_gterms.push(op(a, 0));
            sc_gterms.push(1);
        }
    }
    if sc_has_guards { fatal("ScalarEvolution: experimental.guard in loop guards is not ported"); }
    var ncc: i64 = 0;
    sc_visited_insert(vm, blk);
    var p1 = pred;
    var p2 = blk;
    while p1 >= 0 {
        sc_visited_insert(vm, p2);
        let t = block_last(p1);
        if iop(t) == OP_CONDBR {
            sc_gterms.push(op(t, 0));
            sc_gterms.push(if term_succ(t, 0) == p2 { 1 } else { 0 });
            ncc++;
            if depth > 0 && ncc == 2 { break; }
        }
        let a, b = sc_pred_with_unique_succ(p1);
        p1 = a;
        p2 = b;
    }
    if pred_count(p2) >= 2 && depth < sc_max_loop_guard_collection_depth {
        sc_incoming_serial++;
        let ser = sc_incoming_serial;
        var ph = block_first(p2);
        while ph >= 0 && is_phi(ph) { sc_collect_from_phi(g, ph, vm, depth, ser); ph = inst_next(ph); }
    }
    // GuardsToProcess (pred, lhs, rhs) triples on sc_gwl
    let gp = sc_gwl.len;
    var ti = sc_gterms.len - 2;
    while ti >= tm {
        let term = sc_gterms[ti];
        let enter = sc_gterms[ti + 1] != 0;
        let wl = sc_newops.len;
        let vs = sc_seen.len;
        sc_newops.push(term);
        while sc_newops.len > wl {
            let c = sc_newops.pop();
            var dup = false;
            for k in vs..sc_seen.len { if sc_seen[k] == c { dup = true; break; } }
            if dup { continue; }
            sc_seen.push(c);
            if sc_is_icmp(c) {
                var p = if enter { inst_pred(c) } else { sc_inverse_pred(inst_pred(c)) };
                var lhs = sc_get_scev(op(c, 0));
                var rhs = sc_get_scev(op(c, 1));
                if sc_is_const(lhs) { let t = lhs; lhs = rhs; rhs = t; p = sc_swapped_pred(p); }
                sc_gwl.push(p as i32);
                sc_gwl.push(lhs);
                sc_gwl.push(rhs);
                continue;
            }
            let lk, l, r = sc_match_logical(c);
            if (enter && lk == 1) || (!enter && lk == 2) { sc_newops.push(l); sc_newops.push(r); }
        }
        sc_seen.resize(vs);
        ti -= 2;
    }
    sc_gterms.resize(tm);
    // divisibility guards
    let mm = sc_gmult.len;
    let dg = sc_guards_new();
    var q = gp;
    while q < sc_gwl.len {
        let p = sc_gwl[q] as i64;
        let lhs = sc_gwl[q + 1];
        let rhs = sc_gwl[q + 2];
        q += 3;
        let ux, uy, okm = sc_match_urem(lhs);
        if !(okm && sc_is_zero(rhs)) { continue; }
        // collectDivisibilityInformation
        if p != P_EQ || !sc_is_zero(rhs) { continue; }
        let a, b, ok2 = sc_match_urem(lhs);
        if !ok2 || !sc_is_unknown(a) { continue; }
        let mult = sc_mul(sc_get_udiv(a, b), b);
        sc_gmap_set(dg, a, mult);
        if sc_is_const(b) {
            var found = false;
            for k in mm..sc_gmult.len { if sc_gmult[k] == a { sc_gmult_ap[k] = sc_ap(b); found = true; } }
            if !found { sc_gmult.push(a); sc_gmult_ap.push(sc_ap(b)); }
        }
    }
    q = gp;
    while q < sc_gwl.len {
        let p = sc_gwl[q] as i64;
        let lhs = sc_gwl[q + 1];
        let rhs = sc_gwl[q + 2];
        q += 3;
        sc_collect_condition(g, dg, em, p, lhs, rhs);
    }
    sc_gwl.resize(gp);
    for k in mm..sc_gmult.len {
        let key = sc_gmult[k];
        let d = sc_gmult_ap[k];
        let ds = sc_get_constant(d);
        let x = sc_mul(sc_get_udiv(sc_apply_divisibility_on_minmax(sc_guards_rewrite(g, key), d), ds), ds);
        sc_gmap_set(g, key, x);
        sc_gexprs.push(key);
    }
    sc_gmult.resize(mm);
    sc_gmult_ap.resize(mm);
    var pnuw = true;
    var pnsw = true;
    for k in em..sc_gexprs.len {
        let e = sc_gexprs[k];
        let to = sc_gmap_get(g, e);
        pnuw = pnuw && rg_contains(sc_get_unsigned_range(e), sc_get_unsigned_range(to));
        pnsw = pnsw && rg_contains(sc_get_signed_range(e), sc_get_signed_range(to));
    }
    sc_guards[g].pnuw = pnuw;
    sc_guards[g].pnsw = pnsw;
    if sc_gexprs.len - em > 1 {
        for k in em..sc_gexprs.len {
            let e = sc_gexprs[k];
            let to = sc_gmap_get(g, e);
            // RewriteMap.erase(Expr) before rewriting, then insert
            hm_del(sc_gmap, hk2(g, e));
            sc_guards[g].nmap -= 1;
            let r = sc_guards_rewrite(g, to);
            sc_gmap_set(g, e, r);
        }
    }
    sc_gexprs.resize(em);
}

// CollectCondition
recursive fn sc_collect_condition(g: i32, dg: i32, em: i64, p0: i64, lhs0: i32, rhs0: i32) {
    var p = p0;
    var lhs = lhs0;
    var rhs = rhs0;
    // MatchRangeCheckIdiom
    if sc_kind(lhs) == SC_ADD && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) && sc_is_unknown(sc_op(lhs, 1)) && sc_is_const(rhs) {
        let lu = sc_op(lhs, 1);
        let er = rg_subtract(rg_exact_icmp(p, sc_ap(rhs)), sc_ap(sc_op(lhs, 0)));
        if !rg_is_wrapped(er) && !rg_is_full(er) {
            let ex = sc_gmap_get(g, lu);
            let rl = if ex < 0 { lu } else { ex };
            let to = sc_umax(sc_get_constant(rg_umin(er)), sc_umin(rl, sc_get_constant(rg_umax(er))));
            sc_gmap_set(g, lu, to);
            sc_gexprs.push(lu);
            return;
        }
    }
    if sc_is_const(lhs) || sc_contains_addrec(rhs) { return; }
    if !sc_is_unknown(lhs) && sc_is_unknown(rhs) { let t = lhs; lhs = rhs; rhs = t; p = sc_swapped_pred(p); }
    fn get_maybe(s: i32) -> i32 { let x = sc_gmap_get(g, s); return if x < 0 { s } else { x }; }
    let rl = get_maybe(lhs);
    let divides = sc_get_constant_multiple(sc_guards_rewrite(dg, rl), -1);
    let one = sc_get_one(sc_ty(rhs));
    if p == P_ULT || p == P_SLT {
        if p == P_ULT {
            if sc_is_ptr(rhs) { return; }
            rhs = sc_umax(rhs, one);
        }
        rhs = sc_minus(rhs, one);
        rhs = sc_get_previous_divisible(rhs, divides);
    } else if p == P_UGT || p == P_SGT {
        rhs = sc_add(rhs, one);
        rhs = sc_get_next_divisible(rhs, divides);
    } else if p == P_ULE || p == P_SLE { rhs = sc_get_previous_divisible(rhs, divides); }
    else if p == P_UGE || p == P_SGE { rhs = sc_get_next_divisible(rhs, divides); }
    let wl = sc_gwl.len;
    let vs = sc_seen.len;
    sc_gwl.push(lhs);
    while sc_gwl.len > wl {
        let from = sc_gwl.pop();
        if sc_is_const(from) { continue; }
        var dup = false;
        for k in vs..sc_seen.len { if sc_seen[k] == from { dup = true; break; } }
        if dup { continue; }
        sc_seen.push(from);
        let fr = get_maybe(from);
        var to: i32 = -1;
        if p == P_ULT || p == P_ULE {
            to = sc_umin(fr, rhs);
            if sc_kind(fr) == SC_UMAX { for i in sc_nops(fr) { sc_gwl.push(sc_op(fr, i)); } }
        } else if p == P_SLT || p == P_SLE {
            to = sc_smin(fr, rhs);
            if sc_kind(fr) == SC_SMAX { for i in sc_nops(fr) { sc_gwl.push(sc_op(fr, i)); } }
        } else if p == P_UGT || p == P_UGE {
            to = sc_umax(fr, rhs);
            if sc_kind(fr) == SC_UMIN { for i in sc_nops(fr) { sc_gwl.push(sc_op(fr, i)); } }
        } else if p == P_SGT || p == P_SGE {
            to = sc_smax(fr, rhs);
            if sc_kind(fr) == SC_SMIN { for i in sc_nops(fr) { sc_gwl.push(sc_op(fr, i)); } }
        } else if p == P_EQ {
            if sc_is_const(rhs) { to = rhs; }
        } else if p == P_NE {
            if sc_is_zero(rhs) {
                let oau = sc_get_next_divisible(one, divides);
                to = sc_umax(fr, oau);
            } else {
                var brk = false;
                if sc_is_ptr(lhs) {
                    lhs = sc_get_lossless_ptr_to_int(lhs);
                    rhs = sc_get_lossless_ptr_to_int(rhs);
                    if sc_is_cnc(lhs) || sc_is_cnc(rhs) { brk = true; }
                }
                if !brk {
                    if sc_kind(rhs) == SC_ADD && sc_nops(rhs) == 2 && sc_is_const(sc_op(rhs, 0)) &&
                       sc_kind(lhs) == SC_ADD && sc_nops(lhs) == 2 && sc_op(lhs, 0) == sc_op(rhs, 0) {
                        let a = sc_op(rhs, 1);
                        let b = sc_op(lhs, 1);
                        rhs = a;
                        lhs = b;
                    }
                    sc_gne_add(g, lhs, rhs);
                    continue;
                }
            }
        }
        if to >= 0 {
            if from == fr { sc_gexprs.push(from); }
            sc_gmap_set(g, from, to);
        }
    }
    sc_seen.resize(vs);
}

// containsAddRecurrence (HasRecMap)
recursive fn sc_contains_addrec(s: i32) -> bool {
    if sc_side[s].has_rec >= 0 { return sc_side[s].has_rec != 0; }
    let mark = sc_seen.len;
    let r = sc_has_rec_walk(s, mark);
    sc_seen.resize(mark);
    sc_side[s].has_rec = if r { 1 } else { 0 };
    return r;
}
recursive fn sc_has_rec_walk(s: i32, mark: i64) -> bool {
    for k in mark..sc_seen.len { if sc_seen[k] == s { return false; } }
    sc_seen.push(s);
    if sc_is_addrec(s) { return true; }
    let k = sc_kind(s);
    if k == SC_CONST || k == SC_VSCALE || k == SC_UNKNOWN { return false; }
    for i in sc_nops(s) { if sc_has_rec_walk(sc_op(s, i), mark) { return true; } }
    return false;
}

// LoopGuards::rewrite
recursive fn sc_guards_rewrite(g: i32, e: i32) -> i32 {
    if sc_guards[g].nmap == 0 && sc_guards[g].nne == 0 { return e; }
    var rw = rw_new(RW_GUARDS, g);
    return sc_rw_visit(rw, e);
}

recursive fn sc_guards_rewrite_unknown(rw: RW&, s: i32) -> i32 { let x = sc_gmap_get(rw.l, s); return if x < 0 { s } else { x }; }

recursive fn sc_guards_mask(g: i32) -> u32 {
    var m = SF_ANY;
    if sc_guards[g].pnuw { m |= SF_NUW; }
    if sc_guards[g].pnsw { m |= SF_NSW; }
    return m;
}

// SCEVLoopGuardRewriter's visit* overrides (called from sc_rw_visit_impl)
recursive fn sc_guards_visit(rw: RW&, s: i32) -> i32 {
    let g = rw.l;
    let k = sc_kind(s);
    if k == SC_ADDREC { return s; }
    if k == SC_ZEXT {
        let m = sc_gmap_get(g, s);
        if m >= 0 { return m; }
        let ty = sc_ty(s);
        let o = sc_op(s, 0);
        var bw = ty_bits(ty) / 2;
        while bw % 8 == 0 && bw >= 8 && bw > ty_bits(ty_scalar(sc_ty(o))) {
            let ne = sc_get_zero_extend(o, ty_int(bw), 0);
            let m2 = sc_gmap_get(g, ne);
            if m2 >= 0 { return sc_get_zero_extend(m2, ty, 0); }
            bw = bw / 2;
        }
        return sc_rw_default(rw, s);
    }
    if k == SC_SEXT || k == SC_UMIN || k == SC_SMIN {
        let m = sc_gmap_get(g, s);
        if m >= 0 { return m; }
        return sc_rw_default(rw, s);
    }
    if k == SC_ADD {
        let r1 = sc_guards_rewrite_subtraction(g, s);
        if r1 >= 0 { return r1; }
        if sc_is_const(sc_op(s, 0)) && sc_nops(s) == 3 {
            let add = sc_add(sc_op(s, 1), sc_op(s, 2));
            let r2 = sc_guards_rewrite_subtraction(g, add);
            if r2 >= 0 { return sc_add2(sc_op(s, 0), r2, sc_flags(s) & sc_guards_mask(g) & (SF_NUW | SF_NSW), 0); }
            let m = sc_gmap_get(g, add);
            if m >= 0 { return sc_add(sc_op(s, 0), m); }
        }
        let b = ss.len;
        var changed = false;
        for i in sc_nops(s) { let x = sc_rw_visit(rw, sc_op(s, i)); ss.push(x); if x != sc_op(s, i) { changed = true; } }
        if !changed { ss.resize(b); return s; }
        return sc_add_n(b, sc_flags(s) & sc_guards_mask(g) & (SF_NUW | SF_NSW), 0);
    }
    if k == SC_MUL {
        let b = ss.len;
        var changed = false;
        for i in sc_nops(s) { let x = sc_rw_visit(rw, sc_op(s, i)); ss.push(x); if x != sc_op(s, i) { changed = true; } }
        if !changed { ss.resize(b); return s; }
        return sc_mul_n(b, sc_flags(s) & sc_guards_mask(g) & (SF_NUW | SF_NSW), 0);
    }
    return sc_rw_default(rw, s);
}

recursive fn sc_guards_rewrite_subtraction(g: i32, s: i32) -> i32 {
    let ok, l, r = sc_match_binary_sub(s);
    if ok && sc_gne_has(g, l, r) {
        let oau = sc_get_next_divisible(sc_get_one(sc_ty(s)), sc_get_constant_multiple(s, -1));
        return sc_umax(oau, s);
    }
    return -1;
}

recursive fn sc_apply_loop_guards(e: i32, l: i32) -> i32 { sc_guards_rewrite(sc_loop_guards_collect(l), e) }
recursive fn sc_apply_loop_guards_g(e: i32, g: i32) -> i32 { sc_guards_rewrite(g, e) }
