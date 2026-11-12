// CalledValuePropagation: port of llvm/lib/Transforms/IPO/CalledValuePropagation.cpp (CVPLatticeVal,
// CVPLatticeFunc, runCVP) with the SparseSolver of llvm/include/llvm/Analysis/SparsePropagation.h specialized to
// this lattice (its only user), and canTrack*Interprocedurally (sccp.goose).
// Lattice keys are (value << 2 | grouping). Every transfer function joins with the current state, so the
// fixpoint (and the !callees result) does not depend on the solver's worklist orders.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import scev;
import sccp;

let CV_REG: u64 = 0;
let CV_RET: u64 = 1;
let CV_MEM: u64 = 2;
let CV_UNDEF: u8 = 0;
let CV_FSET: u8 = 1;
let CV_OVER: u8 = 2;

struct CvVal { st: u8, at: i32, n: i32 }   // functions: cv_pool[at..at+n], sorted by name
var cv_pool: i32[>..<];
var cv_vals: CvVal[>..<];      // state of key = cv_vals[hm(key)]
var cv_states = hm_new();
var cv_bb_exec = hm_new();
var cv_edges = hm_new();
var cv_bb_wl: i32[>..<];
var cv_val_wl: i32[>..<];
var cv_indirect: i32[>..<];
var cv_indirect_set = hm_new();
var cv_max: i64 = 4;

fn cv_key(v: i32, g: u64) -> u64 { ((v as u64) << 2) | g }
fn cv_simple(s: u8) -> CvVal { CvVal { st: s, at: 0, n: 0 } }
fn cv_eq(a: CvVal, b: CvVal) -> bool {
    if a.st != b.st || a.n != b.n { return false; }
    for k in a.n as i64 { if cv_pool[a.at + k] != cv_pool[b.at + k] { return false; } }
    return true;
}

fn cv_compute_constant(c: i32) -> CvVal {
    if vals[c].kind == VK_CNULL && ty_kind(vals[c].ty) == TK_PTR { return cv_simple(CV_FSET); }
    let f = strip_ptr_casts(c);
    if is_func(f) {
        let at = cv_pool.len as i32;
        cv_pool.push(f);
        return CvVal { st: CV_FSET, at: at, n: 1 };
    }
    return cv_simple(CV_OVER);
}

fn cv_compute_lattice_val(k: u64) -> CvVal {
    let v = (k >> 2) as i32;
    if (k & 3) == CV_REG {
        if is_inst(v) { return cv_simple(CV_UNDEF); }
        if is_arg(v) {
            if sc_can_track_arguments(args_parent[vals[v].sub]) { return cv_simple(CV_UNDEF); }
        } else if is_constant(v) { return cv_compute_constant(v); }
        return cv_simple(CV_OVER);
    }
    if vals[v].kind == VK_GVAR {
        if sc_can_track_global(v) { return cv_compute_constant(op(v, 0)); }
    } else if is_func(v) {
        if sc_can_track_returns(v) { return cv_simple(CV_UNDEF); }
    }
    return cv_simple(CV_OVER);
}

fn cv_name_less(a: i32, b: i32) -> bool { bytes_cmp(val_name(a), val_name(b)) < 0 }

fn cv_merge(x: CvVal, y: CvVal) -> CvVal {
    if x.st == CV_OVER || y.st == CV_OVER { return cv_simple(CV_OVER); }
    if x.st == CV_UNDEF && y.st == CV_UNDEF { return cv_simple(CV_UNDEF); }
    let at = cv_pool.len as i32;
    var i: i64 = 0;
    var j: i64 = 0;
    let xn = x.n as i64;
    let yn = y.n as i64;
    while i < xn || j < yn {
        if j >= yn { cv_pool.push(cv_pool[x.at + i]); i++; continue; }
        if i >= xn { cv_pool.push(cv_pool[y.at + j]); j++; continue; }
        let a = cv_pool[x.at + i];
        let b = cv_pool[y.at + j];
        if cv_name_less(a, b) { cv_pool.push(a); i++; }
        else if cv_name_less(b, a) { cv_pool.push(b); j++; }
        else { cv_pool.push(a); i++; j++; }
    }
    let n = cv_pool.len as i32 - at;
    if (n as i64) > cv_max { return cv_simple(CV_OVER); }
    return CvVal { st: CV_FSET, at: at, n: n };
}

fn cv_get_state(k: u64) -> CvVal {
    let j = hm_get(cv_states, k, -1);
    if j >= 0 { return cv_vals[j]; }
    let lv = cv_compute_lattice_val(k);
    hm_put(cv_states, k, cv_vals.len);
    cv_vals.push(lv);
    return lv;
}
fn cv_update_state(k: u64, lv: CvVal) {
    let j = hm_get(cv_states, k, -1);
    if j >= 0 {
        if cv_eq(cv_vals[j], lv) { return; }
        cv_vals[j] = lv;
    } else {
        hm_put(cv_states, k, cv_vals.len);
        cv_vals.push(lv);
    }
    cv_val_wl.push((k >> 2) as i32);
}
fn cv_mark_block_executable(bb: i32) {
    if hm_has(cv_bb_exec, bb as u64) { return; }
    hm_put(cv_bb_exec, bb as u64, 1);
    cv_bb_wl.push(bb);
}

// getFeasibleSuccessors (AggressiveUndef = true; no constant from the lattice): bit k set = successor k feasible
fn cv_succ_feasible(t: i32, k: i64) -> bool {
    let o = iop(t);
    if o == OP_BR { return true; }
    if o == OP_CONDBR || o == OP_SWITCH {
        let v = cv_get_state(cv_key(op(t, 0), CV_REG));
        if v.st == CV_UNDEF { return false; }
    }
    return true;
}

fn cv_is_edge_feasible(from: i32, to: i32) -> bool {
    let t = block_terminator(from);
    for k in term_nsucc(t) { if term_succ(t, k) == to && cv_succ_feasible(t, k) { return true; } }
    return false;
}

fn cv_mark_edge_executable(from: i32, to: i32) {
    let ek = ((from as u64) << 32) | (to as u64);
    if hm_has(cv_edges, ek) { return; }
    hm_put(cv_edges, ek, 1);
    if hm_has(cv_bb_exec, to as u64) {
        var i = block_first(to);
        while i >= 0 && iop(i) == OP_PHI { cv_visit_phi(i); i = inst_next(i); }
    } else {
        cv_mark_block_executable(to);
    }
}

fn cv_visit_phi(pn: i32) {
    let k = cv_key(pn, CV_REG);
    var v = cv_get_state(k);
    if v.st == CV_OVER { return; }
    if phi_nincoming(pn) > 64 { cv_update_state(k, cv_simple(CV_OVER)); return; }
    for i in phi_nincoming(pn) {
        if !cv_is_edge_feasible(phi_block(pn, i), inst_parent(pn)) { continue; }
        let ov = cv_get_state(cv_key(phi_value(pn, i), CV_REG));
        if !cv_eq(ov, v) { v = cv_merge(v, ov); }
        if v.st == CV_OVER { break; }
    }
    cv_update_state(k, v);
}

var cv_ck: u64[>..<];
var cv_cv: CvVal[>..<];
fn cv_set_changed(k: u64, v: CvVal) {
    for x, j in cv_ck { if x == k { cv_cv[j] = v; return; } }
    cv_ck.push(k);
    cv_cv.push(v);
}

fn cv_visit_inst(i: i32) {
    let o = iop(i);
    if o == OP_PHI { cv_visit_phi(i); return; }
    cv_ck.clear();
    cv_cv.clear();
    let reg = cv_key(i, CV_REG);
    if o == OP_CALL || o == OP_INVOKE {
        let f = called_function(i);
        if f < 0 && !hm_has(cv_indirect_set, i as u64) { hm_put(cv_indirect_set, i as u64, 1); cv_indirect.push(i); }
        if f < 0 || !sc_can_track_returns(f) {
            if vals[i].ty != T_VOID { cv_set_changed(reg, cv_simple(CV_OVER)); }
        } else {
            cv_mark_block_executable(func_entry(f));
            let ret = cv_key(f, CV_RET);
            for a in func_nargs(f) {
                let formal = cv_key(func_arg(f, a), CV_REG);
                let actual = cv_key(cb_arg(i, a), CV_REG);
                let m = cv_merge(cv_get_state(formal), cv_get_state(actual));
                cv_set_changed(formal, m);
            }
            if vals[i].ty != T_VOID { let m = cv_merge(cv_get_state(reg), cv_get_state(ret)); cv_set_changed(reg, m); }
        }
    } else if o == OP_LOAD {
        let p = op(i, 0);
        if vals[p].kind == VK_GVAR {
            let m = cv_merge(cv_get_state(reg), cv_get_state(cv_key(p, CV_MEM)));
            cv_set_changed(reg, m);
        } else { cv_set_changed(reg, cv_simple(CV_OVER)); }
    } else if o == OP_RET {
        let f = inst_func(i);
        if ty_fn_ret(func_type(f)) != T_VOID {
            let rf = cv_key(f, CV_RET);
            let m = cv_merge(cv_get_state(cv_key(op(i, 0), CV_REG)), cv_get_state(rf));
            cv_set_changed(rf, m);
        }
    } else if o == OP_SELECT {
        let m = cv_merge(cv_get_state(cv_key(op(i, 1), CV_REG)), cv_get_state(cv_key(op(i, 2), CV_REG)));
        cv_set_changed(reg, m);
    } else if o == OP_STORE {
        let p = op(i, 1);
        if vals[p].kind == VK_GVAR {
            let mem = cv_key(p, CV_MEM);
            let m = cv_merge(cv_get_state(cv_key(op(i, 0), CV_REG)), cv_get_state(mem));
            cv_set_changed(mem, m);
        }
    } else {
        if vals[i].first_use >= 0 { cv_set_changed(reg, cv_simple(CV_OVER)); }
    }
    let n = cv_ck.len;
    var ks: u64[>..<] = [];
    var vs: CvVal[>..<] = [];
    for j in n { ks.push(cv_ck[j]); vs.push(cv_cv[j]); }
    for j in n { cv_update_state(ks[j], vs[j]); }
    if is_terminator(i) {
        let bb = inst_parent(i);
        for k in term_nsucc(i) { if cv_succ_feasible(i, k) { cv_mark_edge_executable(bb, term_succ(i, k)); } }
    }
}

fn called_value_propagation_run(m: i32) -> u32 {
    cv_max = flag_int("cvp-max-functions-per-value", 4);
    cv_pool.clear(); cv_vals.clear(); cv_bb_wl.clear(); cv_val_wl.clear(); cv_indirect.clear();
    hm_clear(cv_states); hm_clear(cv_bb_exec); hm_clear(cv_edges); hm_clear(cv_indirect_set);
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) && !sc_can_track_arguments(f) { cv_mark_block_executable(func_entry(f)); }
        f = globs[glob_of(f)].next;
    }
    while cv_bb_wl.len > 0 || cv_val_wl.len > 0 {
        while cv_val_wl.len > 0 {
            let v = cv_val_wl.pop();
            var users: i32[>..<] = [];
            if has_use_list(v) {
                var u = vals[v].first_use;
                while u >= 0 { users.push(uses[u].user); u = uses[u].next; }
            }
            for us in users {
                if is_inst(us) && !is_dead(us) && hm_has(cv_bb_exec, inst_parent(us) as u64) { cv_visit_inst(us); }
            }
        }
        while cv_bb_wl.len > 0 {
            let bb = cv_bb_wl.pop();
            var i = block_first(bb);
            while i >= 0 { cv_visit_inst(i); i = inst_next(i); }
        }
    }
    let kc = md_kind_id("callees");
    for c in cv_indirect {
        let j = hm_get(cv_states, cv_key(cb_callee(c), CV_REG), -1);
        if j < 0 { continue; }
        let lv = cv_vals[j];
        if lv.st != CV_FSET || lv.n == 0 { continue; }
        var ops: i32[>..<] = [];
        for k in lv.n as i64 { ops.push(md_value(cv_pool[lv.at + k])); }
        inst_set_md(c, kc, md_get(MK_TUPLE, -1, ops, false));
    }
    return PA_ALL;
}
