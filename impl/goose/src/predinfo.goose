// PredicateInfo: a port of llvm/lib/Transforms/Utils/PredicateInfo.cpp and
// llvm/include/llvm/Transforms/Utils/PredicateInfo.h. Inserts no-op `bitcast X to T` copies ("SSA copies")
// for values compared in branches, switches and assumes, renaming the uses they dominate, and records which
// predicate each copy stands for.
//
// API: pi_reset() starts a new PredicateInfo lifetime (all functions of one SCCP solver share it; LLVM keeps
// one PredicateInfo per function, the map is keyed by the copy so one table serves all);
// pi_build(fv) builds it for a function (DT must be the cached dominator tree: dt_get(fv, DT_DOM));
// pi_info_for(v) -> info id or -1 (getPredicateInfoFor); pi_constraint(info) -> (ok, pred, other)
// (PredicateBase::getConstraint); pis[info] holds the record.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import domtree;
import gen_iids;
import pm;
import implied;
import constrange;

let PT_BRANCH: u8 = 0;
let PT_COND_ASSUME: u8 = 1;
let PT_BUNDLE_ASSUME: u8 = 2;
let PT_SWITCH: u8 = 3;

// One predicate. from/to: the edge (branch/switch); assume: the assume call; case_val: the switch case.
struct PInfo { kind: u8, true_edge: bool, orig: i32, renamed: i32, cond: i32, from: i32, to: i32, assume: i32,
               case_val: i32, next: i32 }
var pis: PInfo[>..];

// Per value id: the info a copy stands for (stamp), and the builder's per-function data (bstamp).
struct PiRec { stamp: u32, info: i32, bstamp: u32, vhead: i32, vtail: i32, ord: i32 }
var pi_recs: PiRec[>..];
var pi_epoch: u32 = 0;
var pi_bepoch: u32 = 0;

fn pi_rec_grow(v: i32) {
    while pi_recs.len <= (v as i64) { pi_recs.push(PiRec { stamp: 0, info: -1, bstamp: 0, vhead: -1, vtail: -1, ord: 0 }); }
}
fn pi_reset() { pi_epoch += 1; pis.clear(); }
fn pi_info_for(v: i32) -> i32 {
    if (v as i64) >= pi_recs.len { return -1; }
    if pi_recs[v].stamp != pi_epoch { return -1; }
    return pi_recs[v].info;
}
fn pi_set_info(v: i32, info: i32) { pi_rec_grow(v); pi_recs[v].stamp = pi_epoch; pi_recs[v].info = info; }
fn pi_b_valid(v: i32) -> bool { (v as i64) < pi_recs.len && pi_recs[v].bstamp == pi_bepoch }
fn pi_b_touch(v: i32) {
    pi_rec_grow(v);
    if pi_recs[v].bstamp != pi_bepoch { pi_recs[v].bstamp = pi_bepoch; pi_recs[v].vhead = -1; pi_recs[v].vtail = -1; pi_recs[v].ord = 0; }
}
fn pi_ord(i: i32) -> i32 { pi_recs[i].ord }

let MAX_CONDS_PER_BRANCH = 8;

let LN_FIRST: u8 = 0;
let LN_MIDDLE: u8 = 1;
let LN_LAST: u8 = 2;

// ValueDFS: u = use id (or -1), pinfo = info id (or -1)
struct VDFS { dfs_in: i32, dfs_out: i32, local: u8, u: i32, pinfo: i32 }

var pi_fn: i32 = -1;

// shouldRename
fn pi_should_rename(v: i32) -> bool {
    if !is_inst(v) && !is_arg(v) { return false; }
    // !V->hasOneUse()
    let u = first_use(v);
    return !(u >= 0 && use_next(u) < 0);
}

fn pi_new(kind: u8, opv: i32, cond: i32) -> i32 {
    let id = pis.len as i32;
    pis.push(PInfo { kind: kind, true_edge: false, orig: opv, renamed: -1, cond: cond, from: -1, to: -1, assume: -1, case_val: -1, next: -1 });
    return id;
}
// addInfoFor
fn pi_add_info_for(ops: i32[>..<]&, opv: i32, info: i32) {
    pi_b_touch(opv);
    if pi_recs[opv].vhead < 0 {
        ops.push(opv);
        pi_recs[opv].vhead = info;
    } else {
        pis[pi_recs[opv].vtail].next = info;
    }
    pi_recs[opv].vtail = info;
}

// the values of one condition: Cond, then cmp operands (collectCmpOps) or the nuw trunc's operand
fn pi_cond_values(c: i32, out: i32[>..<]&) {
    out.clear();
    out.push(c);
    if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) {
        let a = op(c, 0);
        let b = op(c, 1);
        if a != b { out.push(a); out.push(b); }
    } else if is_inst(c) && iop(c) == OP_TRUNC && (insts[inst_of(c)].flags & FL_NUW) != 0 {
        out.push(op(c, 0));
    }
}

fn pi_process_assume(ii: i32, ops: i32[>..<]&) {
    if cb_nbundles(ii) > 0 {
        for k in cb_nbundles(ii) {
            if sbytes(cb_bundle_tag(ii, k)) == "nonnull" {
                if cb_bundle_count(ii, k) < 1 { continue; }
                let ptr = op(ii, cb_bundle_begin(ii, k));
                if pi_should_rename(ptr) {
                    let info = pi_new(PT_BUNDLE_ASSUME, ptr, -1);
                    pis[info].assume = ii;
                    pi_add_info_for(ops, ptr, info);
                }
            }
        }
        return;
    }
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    var vs: i32[>..<] = [];
    wl.push(op(ii, 0));
    while wl.len > 0 {
        let c = wl.pop();
        var seen = false;
        for x in visited { if x == c { seen = true; } }
        if seen { continue; }
        visited.push(c);
        if visited.len > MAX_CONDS_PER_BRANCH { break; }
        if m_logical(c, true) {
            let a = lg_a;
            let b = lg_b;
            wl.push(b);
            wl.push(a);
        }
        pi_cond_values(c, vs);
        for v in vs {
            if pi_should_rename(v) {
                let info = pi_new(PT_COND_ASSUME, v, c);
                pis[info].assume = ii;
                pi_add_info_for(ops, v, info);
            }
        }
    }
}

fn pi_process_branch(bi: i32, bb: i32, ops: i32[>..<]&) {
    let first = term_succ(bi, 0);
    let second = term_succ(bi, 1);
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    var vs: i32[>..<] = [];
    for si in 2 {
        let succ = if si == 0 { first } else { second };
        let taken = succ == first;
        if succ == bb { continue; }
        wl.clear();
        visited.clear();
        wl.push(op(bi, 0));
        while wl.len > 0 {
            let c = wl.pop();
            var seen = false;
            for x in visited { if x == c { seen = true; } }
            if seen { continue; }
            visited.push(c);
            if visited.len > MAX_CONDS_PER_BRANCH { break; }
            if m_logical(c, taken) {
                let a = lg_a;
                let b = lg_b;
                wl.push(b);
                wl.push(a);
            }
            pi_cond_values(c, vs);
            for v in vs {
                if pi_should_rename(v) {
                    let info = pi_new(PT_BRANCH, v, c);
                    pis[info].from = bb;
                    pis[info].to = succ;
                    pis[info].true_edge = taken;
                    pi_add_info_for(ops, v, info);
                }
            }
        }
    }
}

fn pi_process_switch(si: i32, bb: i32, ops: i32[>..<]&) {
    let c = op(si, 0);
    if (!is_inst(c) && !is_arg(c)) || !pi_should_rename_switch(c) { return; }
    // SwitchEdges: number of edges to each successor
    let n = term_nsucc(si);
    // cases: successor 1.. (successor 0 is the default)
    for k in 1..n {
        let tb = term_succ(si, k);
        var cnt = 0;
        for j in n { if term_succ(si, j) == tb { cnt++; } }
        if cnt == 1 {
            let info = pi_new(PT_SWITCH, c, c);
            pis[info].from = bb;
            pis[info].to = tb;
            pis[info].case_val = switch_case_value(si, k - 1);
            pi_add_info_for(ops, c, info);
        }
    }
}
fn pi_should_rename_switch(c: i32) -> bool { let u = first_use(c); return !(u >= 0 && use_next(u) < 0); }

// SwitchInst case value k (operand layout: cond, default, then (value, dest) pairs)
fn switch_case_value(si: i32, k: i64) -> i32 { op(si, 2 + 2 * k) }

// Build predicate info for function fv
fn pi_build(fv: i32) {
    pi_fn = fv;
    pi_bepoch += 1;
    dt_get(fv, DT_DOM);
    dt_update_dfs_numbers(fv, DT_DOM);
    // instruction order numbers (Instruction::comesBefore)
    var b = func_first_block(fv);
    while b >= 0 {
        var i = block_first(b);
        var n: i32 = 0;
        while i >= 0 { pi_b_touch(i); pi_recs[i].ord = n; n += 2; i = inst_next(i); }
        b = block_next(b);
    }
    var ops: i32[>..<] = [];
    b = func_first_block(fv);
    while b >= 0 {
        if dt_has_node(DT_DOM, b) {
            let t = block_terminator(b);
            if t >= 0 && iop(t) == OP_CONDBR {
                if term_succ(t, 0) != term_succ(t, 1) { pi_process_branch(t, b, ops); }
            } else if t >= 0 && iop(t) == OP_SWITCH {
                pi_process_switch(t, b, ops);
            }
        }
        b = block_next(b);
    }
    // AC.assumptions(): in function order
    b = func_first_block(fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if inst_iid(i) == IID_assume && dt_has_node(DT_DOM, inst_parent(i)) { pi_process_assume(i, ops); }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    pi_rename_uses(ops);
}

fn pi_is_edge(info: i32) -> bool { pis[info].kind == PT_BRANCH || pis[info].kind == PT_SWITCH }

// for a phi use or an edge def: the edge
fn pi_vd_edge(vd: VDFS) -> i32, i32 {
    if vd.u >= 0 {
        let p = uses[vd.u].user;
        return phi_block(p, (vd.u - vals[p].ops) as i64), inst_parent(p);
    }
    return pis[vd.pinfo].from, pis[vd.pinfo].to;
}
fn pi_def_or_user_ord(vd: VDFS) -> i64 {
    if vd.u >= 0 { return (pi_ord(uses[vd.u].user) as i64); }
    // right after the assume
    return (pi_ord(pis[vd.pinfo].assume) as i64) + 1;
}
fn pi_less(a: VDFS, b: VDFS) -> bool {
    if a.dfs_in != b.dfs_in { return a.dfs_in < b.dfs_in; }
    if a.local != b.local { return a.local < b.local; }
    if a.local == LN_LAST {
        let as_, ad = pi_vd_edge(a);
        let bs, bd = pi_vd_edge(b);
        let ain = dt_dfs_in(pi_fn, DT_DOM, ad);
        let bin = dt_dfs_in(pi_fn, DT_DOM, bd);
        let au = a.u >= 0;
        let bu = b.u >= 0;
        if ain != bin { return ain < bin; }
        return !au && bu;
    }
    if a.local == LN_MIDDLE { return pi_def_or_user_ord(a) < pi_def_or_user_ord(b); }
    return false;
}

// DominatorTree::dominates(BasicBlockEdge(start, end), const Use &U)
fn pi_edge_dominates_use(start: i32, end: i32, u: i32) -> bool {
    let ui = uses[u].user;
    var ubb = inst_parent(ui);
    if iop(ui) == OP_PHI {
        let ib = phi_block(ui, (u - vals[ui].ops) as i64);
        if inst_parent(ui) == end && ib == start { return true; }
        ubb = ib;
    }
    if !dt_dominates_block(DT_DOM, end, ubb) { return false; }
    if single_pred(end) >= 0 { return true; }
    var dup = 0;
    var ok = true;
    each_pred(end) { p =>
        if ok {
            if p == start {
                if dup > 0 { ok = false; }
                dup++;
            } else if !dt_dominates_block(DT_DOM, end, p) { ok = false; }
        }
    };
    return ok;
}

fn pi_stack_in_scope(stack_vd: VDFS[>..<]&, vd: VDFS) -> bool {
    let top = stack_vd[stack_vd.len - 1];
    if top.local == LN_LAST {
        if vd.u < 0 {
            return vd.local == LN_LAST && pis[top.pinfo].from == pis[vd.pinfo].from && pis[top.pinfo].to == pis[vd.pinfo].to;
        }
        let ui = uses[vd.u].user;
        if iop(ui) != OP_PHI { return false; }
        let ep = phi_block(ui, (vd.u - vals[ui].ops) as i64);
        if ep != pis[top.pinfo].from { return false; }
        return pi_edge_dominates_use(pis[top.pinfo].from, pis[top.pinfo].to, vd.u);
    }
    return vd.dfs_in >= top.dfs_in && vd.dfs_out <= top.dfs_out;
}

fn pi_rename_uses(ops: i32[>..<]&) {
    var ordered: VDFS[>..<] = [];
    var st_vd: VDFS[>..<] = [];
    var st_def: i32[>..<] = [];
    for opv in ops {
        var counter: i64 = 0;
        ordered.clear();
        var info = pi_recs[opv].vhead;
        while info >= 0 {
            let p = pis[info];
            if p.kind == PT_COND_ASSUME || p.kind == PT_BUNDLE_ASSUME {
                let bb = inst_parent(p.assume);
                if dt_has_node(DT_DOM, bb) {
                    ordered.push(VDFS { dfs_in: dt_dfs_in(pi_fn, DT_DOM, bb) as i32, dfs_out: dt_dfs_out(pi_fn, DT_DOM, bb) as i32,
                                        local: LN_MIDDLE, u: -1, pinfo: info });
                }
            } else {
                if single_pred(p.to) < 0 {
                    if dt_has_node(DT_DOM, p.from) {
                        ordered.push(VDFS { dfs_in: dt_dfs_in(pi_fn, DT_DOM, p.from) as i32, dfs_out: dt_dfs_out(pi_fn, DT_DOM, p.from) as i32,
                                            local: LN_LAST, u: -1, pinfo: info });
                    }
                } else {
                    if dt_has_node(DT_DOM, p.to) {
                        ordered.push(VDFS { dfs_in: dt_dfs_in(pi_fn, DT_DOM, p.to) as i32, dfs_out: dt_dfs_out(pi_fn, DT_DOM, p.to) as i32,
                                            local: LN_FIRST, u: -1, pinfo: info });
                    }
                }
            }
            info = pis[info].next;
        }
        // convertUsesToDFSOrdered
        var u = first_use(opv);
        while u >= 0 {
            let ui = uses[u].user;
            if is_inst(ui) && !inst_is_lifetime_start_or_end(ui) {
                var ib = inst_parent(ui);
                var ln = LN_MIDDLE;
                if iop(ui) == OP_PHI { ib = phi_block(ui, (u - vals[ui].ops) as i64); ln = LN_LAST; }
                if dt_has_node(DT_DOM, ib) {
                    ordered.push(VDFS { dfs_in: dt_dfs_in(pi_fn, DT_DOM, ib) as i32, dfs_out: dt_dfs_out(pi_fn, DT_DOM, ib) as i32,
                                        local: ln, u: u, pinfo: -1 });
                }
            }
            u = use_next(u);
        }
        stable_sort(ordered) { x, y => pi_less(x, y) };
        st_vd.clear();
        st_def.clear();
        for vd in ordered {
            while st_vd.len > 0 && !pi_stack_in_scope(st_vd, vd) { st_vd.pop(); st_def.pop(); }
            if vd.pinfo >= 0 { st_vd.push(vd); st_def.push(-1); continue; }
            if st_vd.len == 0 { continue; }
            if st_def[st_def.len - 1] < 0 { pi_materialize(counter, st_vd, st_def, opv); }
            use_set(vd.u, st_def[st_def.len - 1]);
        }
    }
}

// materializeStack
fn pi_materialize(counter: i64&, st_vd: VDFS[>..<]&, st_def: i32[>..<]&, orig: i32) {
    var k = st_def.len - 1;
    while k >= 0 && st_def[k] < 0 { k--; }
    // entries k+1 .. end get materialized
    let start = k + 1;
    var j = start;
    while j < st_def.len {
        let opv = if j == 0 { orig } else { st_def[j - 1] };
        let info = st_vd[j].pinfo;
        pis[info].renamed = if start == 0 { orig } else { st_def[start - 1] };
        if pi_is_edge(info) {
            var nm: u8[>..] = [];
            nm.append(val_name(opv));
            nm.push('.');
            format_u64_dec(nm, counter as u64);
            counter += 1;
            let pic = build_before(OP_BITCAST, vals[opv].ty, [opv], nm, block_terminator(pis[info].from));
            pi_set_info(pic, info);
            st_def[j] = pic;
        } else {
            let nx = inst_next(pis[info].assume);
            let pic = build_before(OP_BITCAST, vals[opv].ty, [opv], "", nx);
            pi_set_info(pic, info);
            st_def[j] = pic;
        }
        j++;
    }
}

// PredicateBase::getConstraint: (ok, predicate, other operand)
fn pi_constraint(info: i32) -> bool, i64, i32 {
    let p = pis[info];
    if p.kind == PT_BUNDLE_ASSUME { return true, P_NE, c_null(vals[p.orig].ty); }
    if p.kind == PT_COND_ASSUME || p.kind == PT_BRANCH {
        let te = if p.kind == PT_BRANCH { p.true_edge } else { true };
        if p.cond == p.renamed {
            let c = if te { get_true(vals[p.cond].ty) } else { get_false(vals[p.cond].ty) };
            return true, P_EQ, c;
        }
        let c = p.cond;
        if is_inst(c) && iop(c) == OP_TRUNC && (insts[inst_of(c)].flags & FL_NUW) != 0 && op(c, 0) == p.renamed {
            return true, if te { P_NE } else { P_EQ }, c_null(vals[p.renamed].ty);
        }
        if !is_inst(c) || (iop(c) != OP_ICMP && iop(c) != OP_FCMP) { return false, 0, -1; }
        var pred = inst_pred(c);
        var other: i32 = -1;
        if op(c, 0) == p.renamed { other = op(c, 1); }
        else if op(c, 1) == p.renamed { pred = pi_swapped_pred(pred); other = op(c, 0); }
        else { return false, 0, -1; }
        if !te { pred = pi_inverse_pred(pred); }
        return true, pred, other;
    }
    // PT_SWITCH
    if p.cond != p.renamed { return false, 0, -1; }
    return true, P_EQ, p.case_val;
}

// CmpInst::getSwappedPredicate / getInversePredicate (FCmp 0..15, ICmp 32..41)
fn pi_swapped_pred(p: i64) -> i64 {
    if p >= 32 { return pred_swap_i(p); }
    // fcmp: swap the ordering bits (LT <-> GT): bits 2 (lt) and 4? FCMP encoding: U L G E
    let e = p & 1; let g = (p >> 1) & 1; let l = (p >> 2) & 1; let u = (p >> 3) & 1;
    return e | (l << 1) | (g << 2) | (u << 3);
}
fn pi_inverse_pred(p: i64) -> i64 {
    if p >= 32 { return rg_icmp_inverse(p); }
    return 15 - p;
}
