// SSAUpdaterBulk: port of llvm/lib/Transforms/Utils/SSAUpdaterBulk.cpp (AddVariable, AddAvailableValue, AddUse,
// ComputeLiveInBlocks, RewriteAllUses) with the ForwardIDFCalculator of
// llvm/include/llvm/Support/GenericIteratedDominanceFrontier.h (live-in pruning). Not ported:
// RewriteAndOptimizeAllUses (simplifyPass / deduplicatePass, EliminateNewDuplicatePHINodes): no user yet.
//
// One updater at a time (sbu_begin ... sbu_rewrite_all_uses). Variables, their definitions and their uses are
// rows in global arrays; each variable keeps singly linked lists of its definitions and uses in insertion order.
// A use is a slot of the `uses` pool (LLVM's Use *): the users are existing instructions whose operand runs
// don't move while the rewrite runs (only the new PHIs grow).
import std;
import ir;
import irutil;
import domtree;
import scev;
import assume;

struct SbuVar { name: i32, ty: i32, dh: i32, dt: i32, uh: i32, ut: i32 }
var sbu_vars: SbuVar[>..<];
var sbu_def_bb: i32[>..<];
var sbu_def_v: i32[>..<];
var sbu_def_next: i32[>..<];
var sbu_use: i32[>..<];
var sbu_use_next: i32[>..<];

fn sbu_begin() {
    sbu_vars.clear();
    sbu_def_bb.clear(); sbu_def_v.clear(); sbu_def_next.clear();
    sbu_use.clear(); sbu_use_next.clear();
}

// AddVariable(Name, Ty): `name` is a string id (-1 = no name)
fn sbu_add_variable(name: i32, ty: i32) -> i64 {
    sbu_vars.push(SbuVar { name: name, ty: ty, dh: -1, dt: -1, uh: -1, ut: -1 });
    return sbu_vars.len - 1;
}
// AddAvailableValue(Var, BB, V)
fn sbu_add_available_value(var_: i64, bb: i32, v: i32) {
    let k = sbu_def_bb.len as i32;
    sbu_def_bb.push(bb); sbu_def_v.push(v); sbu_def_next.push(-1);
    if sbu_vars[var_].dt >= 0 { sbu_def_next[sbu_vars[var_].dt] = k; } else { sbu_vars[var_].dh = k; }
    sbu_vars[var_].dt = k;
}
// AddUse(Var, U)
fn sbu_add_use(var_: i64, u: i32) {
    let k = sbu_use.len as i32;
    sbu_use.push(u); sbu_use_next.push(-1);
    if sbu_vars[var_].ut >= 0 { sbu_use_next[sbu_vars[var_].ut] = k; } else { sbu_vars[var_].uh = k; }
    sbu_vars[var_].ut = k;
}

// getUserBB(U)
fn sbu_user_bb(u: i32) -> i32 {
    let usr = uses[u].user;
    if iop(usr) == OP_PHI { return phi_block(usr, (u - vals[usr].ops) as i64); }
    return inst_parent(usr);
}

fn sbu_key(b: i32) -> u64 { (b as i64) as u64 }

// RewriteAllUses(DT, InsertedPHIs = nullptr). The dominator tree is fv's DT_DOM, up to date.
fn sbu_rewrite_all_uses(fv: i32) {
    var defs = hm_new();        // DefBlocks
    var using = hm_new();       // UsingBlocks
    var livein = hm_new();      // LiveInBlocks
    var vpq = hm_new();         // VisitedPQ
    var vwl = hm_new();         // VisitedWorklist
    var info = hm_new();        // BBInfos: block -> row in bi_in / bi_out
    var bi_in: i32[>..<] = [];
    var bi_out: i32[>..<] = [];
    var wl: i32[>..<] = [];
    var idf: i32[>..<] = [];
    var pq: i64[>..<] = [];
    var pqb: i32[>..<] = [];
    var stack: i32[>..<] = [];
    var processed = hm_new();
    var ty: i32 = -1;
    fn row(b: i32) -> i64 {
        let r = hm_get(info, sbu_key(b), -1);
        if r >= 0 { return r; }
        bi_in.push(-1); bi_out.push(-1);
        hm_put(info, sbu_key(b), bi_in.len - 1);
        return bi_in.len - 1;
    }
    fn pq_push(bv: i32) {
        let lvl = dt_level(DT_DOM, bv) as i64;
        let dfs = dt_dfs_in(fv, DT_DOM, bv) as i64;
        let idx = pqb.len as i64;
        if lvl >= (1 << 20) || dfs >= (1 << 21) || idx >= (1 << 21) { fatal("SSAUpdaterBulk: function too large for the IDF priority key"); }
        pqb.push(bv);
        heap_push(pq, (((1 << 20) - 1 - lvl) << 42) | (((1 << 21) - 1 - dfs) << 21) | idx);
    }
    // ComputeValue(BB, IsLiveOut)
    fn compute_value(b0: i32, live_out: bool) -> i32 {
        var b = b0;
        let r0 = row(b);
        if live_out && bi_out[r0] >= 0 { return bi_out[r0]; }
        if bi_in[r0] >= 0 { return bi_in[r0]; }
        stack.clear();
        stack.push(r0 as i32);
        var v: i32 = -1;
        while dt_has_node(DT_DOM, b) && pred_count(b) > 0 {
            let id = dt_idom(DT_DOM, b);
            if id < 0 { break; }
            b = id;
            let rr = row(b);
            if bi_out[rr] >= 0 { v = bi_out[rr]; break; }
            if bi_in[rr] >= 0 { v = bi_in[rr]; break; }
            stack.push(rr as i32);
        }
        if v < 0 { v = c_undef(ty); }
        for s in stack { bi_in[s] = v; }
        return v;
    }
    for r in sbu_vars.len {
        ty = sbu_vars[r].ty;
        hm_clear(info); bi_in.clear(); bi_out.clear();
        hm_clear(defs); hm_clear(using); hm_clear(livein);
        var d = sbu_vars[r].dh;
        while d >= 0 { hm_put(defs, sbu_key(sbu_def_bb[d]), 1); d = sbu_def_next[d]; }
        // UsingBlocks, then ComputeLiveInBlocks (the result is a set: the worklist order doesn't matter)
        wl.clear();
        var u = sbu_vars[r].uh;
        while u >= 0 {
            let b = sbu_user_bb(sbu_use[u]);
            if !hm_has(using, sbu_key(b)) { hm_put(using, sbu_key(b), 1); wl.push(b); }
            u = sbu_use_next[u];
        }
        while wl.len > 0 {
            let b = wl.pop();
            if hm_has(livein, sbu_key(b)) { continue; }
            hm_put(livein, sbu_key(b), 1);
            each_pred(b) { p => if !hm_has(defs, sbu_key(p)) { wl.push(p); } };
        }
        // IDF.calculate(IDFBlocks)
        idf.clear();
        hm_clear(vpq); hm_clear(vwl);
        pq.clear(); pqb.clear();
        dt_update_dfs_numbers(fv, DT_DOM);
        d = sbu_vars[r].dh;
        while d >= 0 {
            let b = sbu_def_bb[d];
            // DefBlocks is a set: each block once (the priority key orders them)
            if dt_has_node(DT_DOM, b) && !hm_has(vwl, sbu_key(b)) { pq_push(b); hm_put(vwl, sbu_key(b), 1); }
            d = sbu_def_next[d];
        }
        while pq.len > 0 {
            let top = heap_pop(pq);
            let root = pqb[top & 0x1FFFFF];
            let root_level = dt_level(DT_DOM, root);
            wl.clear();
            wl.push(root);
            while wl.len > 0 {
                let n = wl.pop();
                let t = block_terminator(n);
                if t >= 0 {
                    for k in term_nsucc(t) {
                        let s = term_succ(t, k);
                        if dt_level(DT_DOM, s) > root_level { continue; }
                        if hm_has(vpq, sbu_key(s)) { continue; }
                        hm_put(vpq, sbu_key(s), 1);
                        if !hm_has(livein, sbu_key(s)) { continue; }
                        idf.push(s);
                        if !hm_has(defs, sbu_key(s)) { pq_push(s); }
                    }
                }
                var c = dt_first_child(fv, DT_DOM, n);
                while c >= 0 {
                    if !hm_has(vwl, sbu_key(c)) { hm_put(vwl, sbu_key(c), 1); wl.push(c); }
                    c = dt_next_sibling(DT_DOM, c);
                }
            }
        }
        d = sbu_vars[r].dh;
        while d >= 0 { let rr = row(sbu_def_bb[d]); bi_out[rr] = sbu_def_v[d]; d = sbu_def_next[d]; }
        // new phi-nodes at the front of the IDF blocks (IRBuilder at begin(): the first instruction's DebugLoc)
        for fb in idf {
            let first = block_first(fb);
            let pn = new_inst(OP_PHI, ty, 0);
            vals[pn].nops = 0;
            inst_insert_at(pn, fb, first, true);
            if sbu_vars[r].name >= 0 {
                var nm: u8[>..] = [];
                nm.append(sbytes(sbu_vars[r].name));
                set_name(pn, nm);
            }
            if first >= 0 {
                let dl = inst_get_md(first, 0);
                if dl >= 0 { inst_set_md(pn, 0, dl); }
            }
            let rr = row(fb);
            bi_in[rr] = pn;
        }
        for b in idf {
            let pn = block_first(b);
            each_pred(b) { p => phi_add_incoming(pn, compute_value(p, true), p); };
        }
        hm_clear(processed);
        u = sbu_vars[r].uh;
        while u >= 0 {
            let us = sbu_use[u];
            u = sbu_use_next[u];
            if hm_has(processed, (us as i64) as u64) { continue; }
            hm_put(processed, (us as i64) as u64, 1);
            let usr = uses[us].user;
            let b = sbu_user_bb(us);
            let v = compute_value(b, b != inst_parent(usr));
            let old_v = uses[us].val;
            if old_v != v { ac_rauw(old_v, v); }   // ValueHandleBase::ValueIsRAUWd: the AssumptionCache's affected values
            set_op(usr, (us - vals[usr].ops) as i64, v);
        }
    }
}
