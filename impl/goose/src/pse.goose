// PredicatedScalarEvolution: port of the PredicatedScalarEvolution class of llvm/lib/Analysis/ScalarEvolution.cpp
// (getSCEV, getPredicatedSCEV, getBackedgeTakenCount, getSymbolicMaxBackedgeTakenCount, addPredicate(s),
// updateGeneration, hasNoOverflow, getAsAddRec, the copy constructor, print). The union predicates and the
// predicate-aware SCEVPredicateRewriter are in scev_lt.goose.
// A PSE is an id into `pses`; its RewriteMap entries are records in pse_ents (a per-PSE list for copying, and an
// HMap keyed by (pse, SCEV) for lookups).
import std;
import ir;
import irutil;
import flags;
import loopinfo;
import scev;
import scev_create;
import scev_btc;
import scev_lt;

struct PSE { l: i32, u: i32, gen: i32, btc: i32, smax: i32, ents: i32 }
struct PEnt { key: i32, gen: i32, val: i32, next: i32 }
var pses: PSE[>..];
var pse_ents: PEnt[>..];
var pse_map = hm_new();     // (pse << 32 | scev) -> entry index

// PredicatedScalarEvolution(SE, L)
fn pse_new(l: i32) -> i32 {
    pses.push(PSE { l: l, u: su_empty(), gen: 0, btc: -1, smax: -1, ents: -1 });
    return (pses.len - 1) as i32;
}
// the copy constructor (RewriteMap, predicates, generation, BackedgeCount; not the symbolic max)
fn pse_copy(src: i32) -> i32 {
    let p = pse_new(pses[src].l);
    pses[p].u = pse_rebuild(pses[src].u);
    pses[p].gen = pses[src].gen;
    pses[p].btc = pses[src].btc;
    var e = pses[src].ents;
    var keys: i32[>..<] = [];
    while e >= 0 { keys.push(e); e = pse_ents[e].next; }
    var k = keys.len - 1;
    while k >= 0 { let x = pse_ents[keys[k]]; pse_set(p, x.key, x.gen, x.val); k--; }
    return p;
}
// SCEVUnionPredicate(Preds): add each in order to an empty union
recursive fn pse_rebuild(u: i32) -> i32 {
    var r = su_empty();
    for k in su_n(u) { r = su_add(r, su_get(u, k)); }
    return r;
}
// pse_reset: drop every PSE (between passes)
fn pse_reset() { pses.clear(); pse_ents.clear(); hm_clear(pse_map); }

fn pse_key(p: i32, s: i32) -> u64 { ((p as u64) << 32) | (s as u64) }
fn pse_find(p: i32, s: i32) -> i64 { hm_get(pse_map, pse_key(p, s), -1) }
fn pse_set(p: i32, s: i32, gen: i32, v: i32) {
    let e = pse_find(p, s);
    if e >= 0 { pse_ents[e].gen = gen; pse_ents[e].val = v; return; }
    pse_ents.push(PEnt { key: s, gen: gen, val: v, next: pses[p].ents });
    let ne = pse_ents.len - 1;
    pses[p].ents = ne as i32;
    hm_put(pse_map, pse_key(p, s), ne);
}

// getSCEV(V)
recursive fn pse_get_scev(p: i32, v: i32) -> i32 { pse_get_predicated_scev(p, sc_get_scev(v)) }
// getPredicatedSCEV(Expr)
recursive fn pse_get_predicated_scev(p: i32, expr0: i32) -> i32 {
    var expr = expr0;
    let e = pse_find(p, expr0);
    if e >= 0 {
        if pse_ents[e].val >= 0 && pse_ents[e].gen == pses[p].gen { return pse_ents[e].val; }
        if pse_ents[e].val >= 0 { expr = pse_ents[e].val; }
    }
    let ns = sc_rewrite_using_predicate(expr, pses[p].l, pses[p].u);
    pse_set(p, expr0, pses[p].gen, ns);
    return ns;
}
// getBackedgeTakenCount
recursive fn pse_get_backedge_taken_count(p: i32) -> i32 {
    if pses[p].btc < 0 {
        let m = sc_out_preds.len;
        let b = sc_get_predicated_btc(pses[p].l, BTC_EXACT);
        pses[p].btc = b;
        var ps: i32[>..<] = [];
        for k in m..sc_out_preds.len { ps.push(sc_out_preds[k]); }
        sc_out_preds.resize(m);
        for x in ps { pse_add_predicate(p, x); }
    }
    return pses[p].btc;
}
// getSymbolicMaxBackedgeTakenCount
recursive fn pse_get_symbolic_max_btc(p: i32) -> i32 {
    if pses[p].smax < 0 {
        let m = sc_out_preds.len;
        let b = sc_get_predicated_btc(pses[p].l, BTC_SYMBOLIC_MAX);
        pses[p].smax = b;
        var ps: i32[>..<] = [];
        for k in m..sc_out_preds.len { ps.push(sc_out_preds[k]); }
        sc_out_preds.resize(m);
        for x in ps { pse_add_predicate(p, x); }
    }
    return pses[p].smax;
}
// addPredicate(Pred)
recursive fn pse_add_predicate(p: i32, pred: i32) {
    let u = pses[p].u;
    if su_implies(u, pred) { return; }
    let b = su_tmp.len;
    for k in su_n(u) { su_tmp.push(su_get(u, k)); }
    su_tmp.push(pred);
    var r = su_empty();
    var vals_: i32[>..<] = [];
    for k in b..su_tmp.len { vals_.push(su_tmp[k]); }
    su_tmp.resize(b);
    for x in vals_ { r = su_add(r, x); }
    pses[p].u = r;
    pses[p].gen += 1;
}
recursive fn pse_add_predicates(p: i32, preds: const i32[:]) { for x in preds { pse_add_predicate(p, x); } }
// hasNoOverflow(V, Flags)
recursive fn pse_has_no_overflow(p: i32, v: i32, flags: i64) -> bool {
    let ar = pse_get_scev(p, v);
    if !sc_is_addrec(ar) { return false; }
    let f = flags & ~sc_wrap_implied_flags(ar);
    return f == 0;
}
// getAsAddRec(V, ExtraPreds): ExtraPreds (when extra) gets the new predicates on sc_lin_preds-style output `out`
recursive fn pse_get_as_add_rec(p: i32, v: i32, extra: bool, out: i32[>..<]&) -> i32 {
    let expr = pse_get_scev(p, v);
    let m = sc_lin_preds.len;
    let nw = sc_convert_to_addrec_with_predicates(expr, pses[p].l);
    if nw < 0 { sc_lin_preds.resize(m); return -1; }
    var np: i32[>..<] = [];
    for k in m..sc_lin_preds.len { np.push(sc_lin_preds[k]); }
    sc_lin_preds.resize(m);
    if extra { for x in np { out.push(x); } return nw; }
    pse_add_predicates(p, np);
    pse_set(p, sc_get_scev(v), pses[p].gen, nw);
    return nw;
}
fn pse_union(p: i32) -> i32 { pses[p].u }

// print(OS, Depth)
fn pse_print(p: i32, depth: i64) {
    let l = pses[p].l;
    for k in loop_nblocks(l) {
        var i = block_first(loop_block(l, k));
        while i >= 0 {
            if sc_is_scevable(vals[i].ty) {
                let e = sc_get_scev(i);
                let x = pse_find(p, e);
                if x >= 0 && pse_ents[x].val != e {
                    for d in depth { errs(" "); }
                    errs("[PSE]");
                    errs_inst(i, block_func(loop_header(l)));
                    errs(":\n");
                    for d in depth + 2 { errs(" "); }
                    sc_print(e);
                    errs("\n");
                    for d in depth + 2 { errs(" "); }
                    errs("--> ");
                    sc_print(pse_ents[x].val);
                    errs("\n");
                }
            }
            i = inst_next(i);
        }
    }
}
