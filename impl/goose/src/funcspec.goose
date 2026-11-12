// FunctionSpecialization: port of llvm/lib/Transforms/IPO/FunctionSpecialization.cpp (FunctionSpecializer,
// InstCostVisitor) for IPSCCP, with CloneFunction / CloneFunctionInto (llvm/lib/Transforms/Utils/CloneFunction.cpp,
// LocalChangesOnly: the metadata of the body is mapped with RF_None and createIdentityMDPredicate), the solver
// entry points the specializer needs (SCCPSolver.cpp: setLatticeValueForSpecializationArguments,
// markFunctionUnreachable, solveWhileResolvedUndefsIn(Functions), resetLatticeValueFor/invalidate,
// solveWhileResolvedUndefs) and CodeMetrics::analyzeBasicBlock / collectEphemeralValues(F) (CodeMetrics.cpp).
// The solver is sccp.goose's (one at a time, sc_* globals).
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_attrs;
import gen_iids;
import analyses;
import datalayout;
import apint;
import constrange;
import valuelattice;
import constfold;
import cfold;
import instsimplify;
import pm;
import vt;
import poison;
import tli;
import tti;
import tti_x86;
import sccp;
import assume;
import bfi;
import psi;
import memloc;
import dinfo;
import value_mapper;
import clone_function;
import autoupgrade;
import inline_cost;
import inline_function;
import looprotate;
import mem2reg;
import scev;

fn fs_not_ported(what: const u8[:]) { fatal(str("FunctionSpecialization: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// cl::opts

var fs_force: bool = false;
var fs_max_clones: i64 = 3;
var fs_max_discovery: i64 = 100;
var fs_max_incoming_phi: i64 = 8;
var fs_max_block_preds: i64 = 2;
var fs_min_function_size: i64 = 500;
var fs_max_codesize_growth: i64 = 3;
var fs_min_codesize_savings: i64 = 20;
var fs_min_latency_savings: i64 = 20;
var fs_min_inlining_bonus: i64 = 300;
var fs_on_address: bool = false;
var fs_literal: bool = true;

fn fs_read_flags() {
    fs_force = flag_bool("force-specialization", false);
    fs_max_clones = flag_int("funcspec-max-clones", 3);
    fs_max_discovery = flag_int("funcspec-max-discovery-iterations", 100);
    fs_max_incoming_phi = flag_int("funcspec-max-incoming-phi-values", 8);
    fs_max_block_preds = flag_int("funcspec-max-block-predecessors", 2);
    fs_min_function_size = flag_int("funcspec-min-function-size", 500);
    fs_max_codesize_growth = flag_int("funcspec-max-codesize-growth", 3);
    fs_min_codesize_savings = flag_int("funcspec-min-codesize-savings", 20);
    fs_min_latency_savings = flag_int("funcspec-min-latency-savings", 20);
    fs_min_inlining_bonus = flag_int("funcspec-min-inlining-bonus", 300);
    fs_on_address = flag_bool("funcspec-on-address", false);
    fs_literal = flag_bool("funcspec-for-literal-constant", true);
}

// ---------------------------------------------------------------------------------------------
// Solver entry points

var fs_inval: i32[>..<];     // Invalidated (insertion order; membership: SB_INVAL)

// setLatticeValueForSpecializationArguments(F, Args): args = (formal, actual) pairs in formal order
fn fs_set_lattice_for_spec_args(nf: i32, args: const i32[:]) {
    let of = args_parent[vals[args[0]].sub];
    var it: i64 = 0;
    for k in func_nargs(nf) {
        let na = func_arg(nf, k);
        let oa = func_arg(of, k);
        if it < args.len && args[it] == oa {
            let c = args[it + 1];
            if sc_is_struct(na) {
                for e in ty_count(vals[na].ty) {
                    let x = sc_gsvs(na, e);
                    vl_mark_constant(sc_vls[x], c_aggregate_element(c, e), false);
                }
            } else {
                let x = sc_vs(na);
                vl_mark_constant(sc_vls[x], c, false);
            }
            it += 2;
        } else {
            if sc_is_struct(na) {
                for e in ty_count(vals[na].ty) {
                    let src = sc_gsvs(oa, e);
                    let dst = sc_gsvs(na, e);
                    sc_vls[dst] = sc_vls[src];
                }
            } else {
                let src = sc_vs(oa);
                let dst = sc_vs(na);
                sc_vls[dst] = sc_vls[src];
            }
        }
    }
}

fn fs_mark_function_unreachable(f: i32) {
    var b = func_first_block(f);
    while b >= 0 { sc_clear_bit(b, SB_EXEC); b = block_next(b); }
}

fn fs_solve_while_resolved_undefs_in(fns: const i32[:]) {
    var again = true;
    while again {
        sc_solve();
        again = false;
        for f in fns { if sc_resolved_undefs_in(f) { again = true; } }
    }
}

// invalidate(Call)
fn fs_invalidate(call: i32) {
    var wl: i32[>..<] = [];
    wl.push(call);
    while wl.len > 0 {
        let i = wl.pop();
        if sc_bit(i, SB_INVAL) { continue; }
        sc_set_bit(i, SB_INVAL);
        fs_inval.push(i);
        if !sc_bit(inst_parent(i), SB_EXEC) { continue; }
        var v: i32 = -1;
        if iop(i) == OP_RET {
            let f = inst_func(i);
            let ri = sc_ret_index(f);
            if ri >= 0 { sc_vls[sc_ret_vl[ri]] = vl_unknown(); v = f; }
            else if sc_mrv_base(f) >= 0 {
                let base = sc_mrv_base(f);
                for e in ty_count(ty_fn_ret(func_type(f))) { sc_vls[base + (e as i32)] = vl_unknown(); }
                v = f;
            }
        } else if ty_is_struct(vals[i].ty) {
            if sc_has_svs(i) {
                for e in ty_count(vals[i].ty) { sc_vls[sc_recs[i].sst + (e as i32)] = vl_unknown(); }
                v = i;
            }
        } else if sc_has_vs(i) {
            sc_vls[sc_recs[i].st] = vl_unknown();
            v = i;
        }
        if v >= 0 {
            var u = first_use(v);
            while u >= 0 { let us = uses[u].user; if is_inst(us) { wl.push(us); } u = use_next(u); }
            if (v as i64) < sc_recs.len && sc_recs[v].stamp == sc_epoch {
                var n = sc_recs[v].au;
                while n >= 0 { if is_inst(sc_au_user[n]) { wl.push(sc_au_user[n]); } n = sc_au_next[n]; }
            }
        }
    }
}

fn fs_solve_while_resolved_undefs() {
    var again = true;
    while again {
        sc_solve();
        again = false;
        for v in fs_inval {
            if sc_bit(v, SB_INVAL) && is_inst(v) && !is_dead(v) {
                if sc_resolved_undef(v) { again = true; }
            }
        }
    }
    for v in fs_inval { sc_clear_bit(v, SB_INVAL); }
    fs_inval.clear();
}

// isStructLatticeConstant
fn fs_is_struct_lattice_constant(f: i32) -> bool {
    let base = sc_mrv_base(f);
    for e in ty_count(ty_fn_ret(func_type(f))) { if !sc_is_constant_lv(sc_vls[base + (e as i32)]) { return false; } }
    return true;
}

// getConstantOrNull(V) for a value the solver must know
fn fs_constant_or_null(v: i32) -> i32 {
    if sc_is_struct(v) {
        if !sc_has_svs(v) && ty_count(vals[v].ty) > 0 { fs_not_ported("a struct value the solver has not seen"); }
    } else if !sc_has_vs(v) { fs_not_ported("a value the solver has not seen"); }
    return sc_get_constant_or_null(v);
}

// ---------------------------------------------------------------------------------------------
// InstCostVisitor (one instance at a time)

var icv_f: i32 = -1;
var icv_known = hm_new();         // KnownConstants: value -> constant
var icv_known_keys: i32[>..<];    // its keys (for the latency walk)
var icv_dead = hm_new();          // DeadBlocks
var icv_visited_phis = hm_new();
var icv_pending: i32[>..<];       // PendingPHIs
var icv_last_key: i32 = -1;       // LastVisited (-1 = end())
var icv_last_val: i32 = -1;

fn icv_begin(f: i32) {
    icv_f = f;
    hm_clear(icv_known); icv_known_keys.clear(); hm_clear(icv_dead); hm_clear(icv_visited_phis); icv_pending.clear();
    icv_last_key = -1; icv_last_val = -1;
}
fn icv_known_get(v: i32) -> i32 { hm_get(icv_known, v as u64, -1) as i32 }
fn icv_known_has(v: i32) -> bool { hm_has(icv_known, v as u64) }
// KnownConstants.insert({V, C}): keeps an existing entry; returns the value in the map
fn icv_known_insert(v: i32, c: i32) -> i32 {
    let e = hm_get(icv_known, v as u64, -1);
    if e >= 0 || hm_has(icv_known, v as u64) { return e as i32; }
    hm_put(icv_known, v as u64, c as i64);
    icv_known_keys.push(v);
    return c;
}

fn icv_is_block_executable(bb: i32) -> bool { sc_bit(bb, SB_EXEC) && !hm_has(icv_dead, bb as u64) }

fn icv_can_eliminate_successor(bb: i32, succ: i32) -> bool {
    var k: i64 = 0;
    var ok = true;
    each_pred(succ) { p =>
        if ok {
            let within = k < fs_max_block_preds;
            k++;
            if !(within && (p == bb || p == succ || !icv_is_block_executable(p))) { ok = false; }
        }
    };
    return ok;
}

fn icv_estimate_basic_blocks(wl: i32[>..<]&) -> i64 {
    var cs: i64 = 0;
    while wl.len > 0 {
        let bb = wl.pop();
        if hm_has(icv_dead, bb as u64) { continue; }
        hm_put(icv_dead, bb as u64, 1);
        var i = block_first(bb);
        while i >= 0 {
            if !icv_known_has(i) { cs = tc_add(cs, tti_instruction_cost(i, TCK_CODE_SIZE)); }
            i = inst_next(i);
        }
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if icv_is_block_executable(s) && icv_can_eliminate_successor(bb, s) { wl.push(s); }
        }
    }
    return cs;
}

fn icv_find_constant_for(v: i32) -> i32 {
    if is_constant(v) { return v; }
    let c = fs_constant_or_null(v);
    if c >= 0 { return c; }
    return icv_known_get(v);
}

fn icv_code_size_savings_from_pending_phis() -> i64 {
    var cs: i64 = 0;
    while icv_pending.len > 0 {
        let p = icv_pending.pop();
        if icv_is_block_executable(inst_parent(p)) { cs = tc_add(cs, icv_code_size_savings_for_user(p, -1, -1)); }
    }
    return cs;
}

fn icv_code_size_savings_for_arg(a: i32, c: i32) -> i64 {
    var cs: i64 = 0;
    var u = first_use(a);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if is_inst(us) && icv_is_block_executable(inst_parent(us)) { cs = tc_add(cs, icv_code_size_savings_for_user(us, a, c)); }
    }
    return cs;
}

fn icv_latency_savings_for_known_constants() -> i64 {
    bfi_get(icv_f);
    let ef = bfi_freq(func_entry(icv_f));
    var total: i64 = 0;
    for v in icv_known_keys {
        if !is_inst(v) { continue; }
        let w = bfi_freq(inst_parent(v)) / ef;
        let lat = tti_instruction_cost(v, TCK_LATENCY);
        total = tc_add(total, tc_mul_u(lat, w));
    }
    return total;
}
fn tc_mul_u(c: i64, w: u64) -> i64 {
    if !tc_valid(c) { return TTI_INVALID; }
    let x = (c as u64) * w;
    return x as! i64;
}

recursive fn icv_code_size_savings_for_user(user: i32, use: i32, c0: i32) -> i64 {
    if icv_known_has(user) { return 0; }
    var c = c0;
    if use >= 0 { icv_last_key = use; icv_last_val = icv_known_insert(use, c); } else { icv_last_key = -1; icv_last_val = -1; }
    var cs: i64 = 0;
    let o = iop(user);
    if o == OP_SWITCH { cs = icv_estimate_switch(user); }
    else if o == OP_CONDBR { cs = icv_estimate_condbr(user); }
    else {
        c = icv_visit(user);
        if c < 0 { return 0; }
    }
    icv_known_insert(user, c);
    cs = tc_add(cs, tti_instruction_cost(user, TCK_CODE_SIZE));
    var u = first_use(user);
    while u >= 0 {
        let ui = uses[u].user;
        u = use_next(u);
        if is_inst(ui) && ui != user && icv_is_block_executable(inst_parent(ui)) {
            cs = tc_add(cs, icv_code_size_savings_for_user(ui, user, c));
        }
    }
    return cs;
}

fn icv_estimate_switch(i: i32) -> i64 {
    if op(i, 0) != icv_last_key { return 0; }
    let c = icv_last_val;
    if c < 0 || vals[c].kind != VK_CINT { return 0; }
    // findCaseValue(C)->getCaseSuccessor()
    var succ = op(i, 1);
    let n = (nops(i) - 2) / 2;
    for k in n { if op(i, 2 + 2 * k) == c { succ = op(i, 3 + 2 * k); break; } }
    var wl: i32[>..<] = [];
    for k in n {
        let bb = op(i, 3 + 2 * k);
        if bb != succ && icv_is_block_executable(bb) && icv_can_eliminate_successor(inst_parent(i), bb) { wl.push(bb); }
    }
    return icv_estimate_basic_blocks(wl);
}

fn icv_estimate_condbr(i: i32) -> i64 {
    if op(i, 0) != icv_last_key { return 0; }
    // getSuccessor(C->isOneValue())
    let one = vals[icv_last_val].kind == VK_CINT && cint_lo(icv_last_val) == 1;
    let succ = term_succ(i, if one { 1 } else { 0 });
    var wl: i32[>..<] = [];
    if icv_is_block_executable(succ) && icv_can_eliminate_successor(inst_parent(i), succ) { wl.push(succ); }
    return icv_estimate_basic_blocks(wl);
}

fn icv_discover_transitive(c: i32, root: i32) -> bool {
    var wl: i32[>..<] = [];
    var seen = hm_new();
    wl.push(root);
    var iter: i64 = 0;
    while wl.len > 0 {
        let pn = wl.pop();
        iter++;
        if iter > fs_max_discovery || phi_nincoming(pn) > fs_max_incoming_phi { return false; }
        if hm_has(seen, pn as u64) { continue; }
        hm_put(seen, pn as u64, 1);
        for k in phi_nincoming(pn) {
            let v = phi_value(pn, k);
            if is_inst(v) && (v == pn || !icv_is_block_executable(phi_block(pn, k))) { continue; }
            let x = icv_find_constant_for(v);
            if x >= 0 { if x != c { return false; } continue; }
            if is_inst(v) && iop(v) == OP_PHI { wl.push(v); continue; }
            return false;
        }
    }
    return true;
}

fn icv_visit_phi(i: i32) -> i32 {
    if phi_nincoming(i) > fs_max_incoming_phi { return -1; }
    let inserted = !hm_has(icv_visited_phis, i as u64);
    if inserted { hm_put(icv_visited_phis, i as u64, 1); }
    var cst: i32 = -1;
    var seen_phi = false;
    for k in phi_nincoming(i) {
        let v = phi_value(i, k);
        if is_inst(v) && (v == i || !icv_is_block_executable(phi_block(i, k))) { continue; }
        let x = icv_find_constant_for(v);
        if x >= 0 {
            if cst < 0 { cst = x; }
            if x != cst { return -1; }
            continue;
        }
        if inserted { icv_pending.push(i); return -1; }
        if is_inst(v) && iop(v) == OP_PHI { seen_phi = true; continue; }
        return -1;
    }
    if cst < 0 { return -1; }
    if !seen_phi { return cst; }
    if !icv_discover_transitive(cst, i) { return -1; }
    return cst;
}

recursive fn icv_visit(i: i32) -> i32 {
    let o = iop(i);
    if o == OP_PHI { return icv_visit_phi(i); }
    if o == OP_FREEZE {
        if is_guaranteed_not_to_be_undef_or_poison_no_dt(icv_last_val, -1) { return icv_last_val; }
        return -1;
    }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR {
        let f = called_function(i);
        if f < 0 { return -1; }
        tli_cur_fn = icv_f;
        if !can_constant_fold_call_to(i, f) { return -1; }
        let mark = is_ops.len;
        for k in nops(i) - 1 {
            let v = op(i, k);
            if vals[v].kind == VK_MDVAL { is_ops.resize(mark); return -1; }
            let c = icv_find_constant_for(v);
            if c < 0 { is_ops.resize(mark); return -1; }
            is_ops.push(c);
        }
        let s3 = sq_no_tli;
        sq_no_tli = true;
        let r = cf_fold_call(i, f, mark, nops(i) - 1, true);
        sq_no_tli = s3;
        is_ops.resize(mark);
        return r;
    }
    if o == OP_LOAD {
        if vals[icv_last_val].kind == VK_CNULL { return -1; }
        return cf_fold_load_from_const_ptr(icv_last_val, vals[i].ty, 0, false);
    }
    if o == OP_GEP {
        let mark = is_ops.len;
        for k in nops(i) {
            let c = icv_find_constant_for(op(i, k));
            if c < 0 { is_ops.resize(mark); return -1; }
            is_ops.push(c);
        }
        let r = cf_fold_inst_operands(i, mark, nops(i), true);
        is_ops.resize(mark);
        return r;
    }
    if o == OP_SELECT {
        if op(i, 0) == icv_last_key {
            let v = if is_null_value(icv_last_val) { op(i, 2) } else { op(i, 1) };
            return icv_find_constant_for(v);
        }
        let cond = icv_find_constant_for(op(i, 0));
        if cond >= 0 {
            if (op(i, 1) == icv_last_key && is_one_value_c(cond)) || (op(i, 2) == icv_last_key && is_null_value(cond)) { return icv_last_val; }
        }
        return -1;
    }
    if is_cast_op(o) { return cf_fold_cast_operand(o, icv_last_val, vals[i].ty); }
    if o == OP_ICMP || o == OP_FCMP {
        var cst = icv_last_val;
        let on_rhs = op(i, 1) == icv_last_key;
        let v = if on_rhs { op(i, 0) } else { op(i, 1) };
        var other = icv_find_constant_for(v);
        let p = inst_pred(i);
        if other >= 0 {
            if on_rhs { let t = cst; cst = other; other = t; }
            return cf_fold_cmp_operands(p, cst, other, -1);
        }
        let clv = vl_get(cst);
        let olv = fs_lattice_for(v);
        if on_rhs { return vl_get_compare(olv, p, vals[i].ty, clv); }
        return vl_get_compare(clv, p, vals[i].ty, olv);
    }
    if o == OP_FNEG { return cf_fold_unary(o, icv_last_val); }
    if is_binary_op(o) {
        let on_rhs = op(i, 1) == icv_last_key;
        let v = if on_rhs { op(i, 0) } else { op(i, 1) };
        let other = icv_find_constant_for(v);
        var ov = if other >= 0 { other } else { v };
        var cvv = icv_last_val;
        if on_rhs { let t = cvv; cvv = ov; ov = t; }
        let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli; let sc = kb_cxt;
        sq_no_dt = true; sq_no_ac = true; sq_no_tli = true; kb_cxt = -1;
        let r = simplify_binop(o, cvv, ov, sq_new(-1), RECURSION_LIMIT);
        sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3; kb_cxt = sc;
        if r >= 0 && is_constant(r) { return r; }
        return -1;
    }
    return -1;
}
fn is_one_value_c(c: i32) -> bool { vals[c].kind == VK_CINT && ap_is_one(ci_ap(c)) }
// Solver.getLatticeValueFor(V) (constants: their own lattice value)
fn fs_lattice_for(v: i32) -> VL {
    if is_constant(v) && !sc_has_vs(v) { return vl_get(v); }
    if !sc_has_vs(v) { fs_not_ported("a lattice value the solver has not computed"); }
    return sc_vls[sc_recs[v].st];
}

// ---------------------------------------------------------------------------------------------
// The specializer state (FunctionSpecializer; lives for one ipsccp run)

var fs_specializations: i32[>..<];   // Specializations (clones)
var fs_dead: i32[>..<];              // DeadFunctions (insertion order)
var fs_metric_f: i32[>..<];          // FunctionMetrics
var fs_metric_size: i64[>..<];
var fs_metric_nodup: bool[>..<];
var fs_metric_rec: bool[>..<];
var fs_growth_f: i32[>..<];          // FunctionGrowth
var fs_growth: i64[>..<];
var fs_nglobals: i64 = 0;
var fs_m: i32 = -1;

// AllSpecs of one run(): Spec { F, Clone, Sig (args run), Score, CodeSize, CallSites (list) }
var sp_f: i32[>..<];
var sp_clone: i32[>..<];
var sp_args_at: i32[>..<];
var sp_args_n: i32[>..<];
var sp_score: u64[>..<];
var sp_size: i64[>..<];
var sp_cs_first: i32[>..<];
var sp_cs_last: i32[>..<];
var sp_args: i32[>..<];              // (formal, actual) pairs
var sp_cs: i32[>..<];                // call site nodes
var sp_cs_next: i32[>..<];
var sm_f: i32[>..<];                 // SM: function -> [begin, end)
var sm_b: i32[>..<];
var sm_e: i32[>..<];

fn fs_init(m: i32) {
    fs_m = m;
    fs_read_flags();
    fs_specializations.clear(); fs_dead.clear();
    fs_metric_f.clear(); fs_metric_size.clear(); fs_metric_nodup.clear(); fs_metric_rec.clear();
    fs_growth_f.clear(); fs_growth.clear();
    fs_nglobals = 0;
    fs_inval.clear();
}

fn fs_is_spec(f: i32) -> bool { for x in fs_specializations { if x == f { return true; } } return false; }
fn fs_is_dead_function(f: i32) -> bool { for x in fs_dead { if x == f { return true; } } return false; }
fn fs_growth_get(f: i32) -> i64 { for x, k in fs_growth_f { if x == f { return fs_growth[k]; } } return 0; }
fn fs_growth_add(f: i32, d: i64) {
    for x, k in fs_growth_f { if x == f { fs_growth[k] += d; return; } }
    fs_growth_f.push(f); fs_growth.push(d);
}

// Function::hasOptSize
fn fs_has_opt_size(f: i32) -> bool { func_has_fn_attr(f, AK_OptimizeForSize) || func_has_fn_attr(f, AK_MinSize) }

fn fs_is_candidate(f: i32) -> bool {
    if func_is_decl(f) || func_nargs(f) == 0 { return false; }
    if sc_is_interposable(f) { return false; }
    if func_has_fn_attr(f, AK_NoDuplicate) { return false; }
    if fs_has_opt_size(f) { return false; }
    if fs_is_spec(f) { return false; }
    if !sc_bit(func_entry(f), SB_EXEC) { return false; }
    if func_has_fn_attr(f, AK_AlwaysInline) { return false; }
    return true;
}

// CodeMetrics over every block of f with the ephemeral values of its assumptions
fn fs_metrics(f: i32) -> i64, bool, bool {
    tti_init_function(f, globs[glob_of(f)].module);
    tli_cur_fn = f;
    // collectEphemeralValues(F, AC)
    var eph = hm_new();
    var visited = hm_new();
    var wl: i32[>..<] = [];
    vt_invalidate_assumes();
    ac_invalidate();
    var asms: i32[>..<] = [];
    ac_assumptions(f, asms);
    fn append_ops(v: i32, visited: HMap&, wl: i32[>..<]&) {
        for k in nops(v) {
            let o = op(v, k);
            if o < 0 || hm_has(visited, o as u64) { continue; }
            hm_put(visited, o as u64, 1);
            if is_inst(o) && !inst_may_have_side_effects(o) && !is_terminator(o) { wl.push(o); }
        }
    }
    for a in asms { if !hm_has(eph, a as u64) { hm_put(eph, a as u64, 1); append_ops(a, visited, wl); } }
    var k: i64 = 0;
    while k < wl.len {
        let v = wl[k];
        k++;
        var all = true;
        var u = vals[v].first_use;
        while u >= 0 { if !hm_has(eph, uses[u].user as u64) { all = false; break; } u = uses[u].next; }
        if !all { continue; }
        hm_put(eph, v as u64, 1);
        append_ops(v, visited, wl);
    }
    var n: i64 = 0;
    var nodup = false;
    var rec = false;
    var bb = func_first_block(f);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            if !hm_has(eph, i as u64) {
                if is_callbase(i) {
                    let cf = called_function(i);
                    if cf >= 0 && cf == f { rec = true; }
                    if call_has_fn_attr(i, AK_NoDuplicate) { nodup = true; }
                }
                if vals[i].ty == T_TOKEN && !lr_is_convergence_control(i) && lr_used_outside_block(i, bb) { nodup = true; }
                n = tc_add(n, tti_instruction_cost(i, TCK_CODE_SIZE));
            }
            i = inst_next(i);
        }
        if iop(block_terminator(bb)) == OP_INDIRECTBR { nodup = true; }
        bb = block_next(bb);
    }
    return n, nodup, rec;
}

fn fs_metric_index(f: i32) -> i64 { for x, k in fs_metric_f { if x == f { return k; } } return -1; }

// isArgumentInteresting
fn fs_arg_interesting(a: i32) -> bool {
    if first_use(a) < 0 { return false; }
    let t = vals[a].ty;
    let k = ty_kind(t);
    if k != TK_PTR && (!fs_literal || (k != TK_INT && !ty_is_fp(t) && k != TK_STRUCT)) { return false; }
    let f = args_parent[vals[a].sub];
    if arg_has_attr(a, AK_ByVal) && !me_only_reads(aset_memory(alist_fn(globs[glob_of(f)].attrs))) { return false; }
    if !sc_bit(f, SB_ARGTRACK) { return true; }
    if sc_is_struct(a) {
        for e in ty_count(t) { if sc_is_overdefined_lv(sc_gsv(a, e)) { return true; } }
        return false;
    }
    return sc_is_overdefined_lv(sc_lattice(a));
}

// getCandidateConstant
fn fs_candidate_constant(v: i32) -> i32 {
    if vals[v].kind == VK_POISON { return -1; }
    var c = if is_constant(v) { v } else { fs_constant_or_null(v) };
    if c >= 0 && ty_kind(vals[c].ty) == TK_PTR && !is_null_value(c) {
        let u = get_underlying_object(c, 10);
        if is_gvar(u) && !(globs[glob_of(u)].is_const != 0 || fs_on_address) { return -1; }
    }
    return c;
}

// getInliningBonus
fn fs_inlining_bonus(a: i32, c: i32) -> i64 {
    let cf = strip_ptr_casts(c);
    if !is_func(cf) { return 0; }
    var bonus: i64 = 0;
    var u = first_use(a);
    while u >= 0 {
        let cs = uses[u].user;
        u = use_next(u);
        if !is_inst(cs) || (iop(cs) != OP_CALL && iop(cs) != OP_INVOKE) { continue; }
        if cb_callee(cs) != a { continue; }
        if insts[inst_of(cs)].ty2 != globs[glob_of(cf)].vty { continue; }
        var p = get_inline_params();
        p.default_threshold += IC_INDIRECT_CALL_THRESHOLD;
        tti_init_function(cf, globs[glob_of(cf)].module);
        let ic = get_inline_cost(cs, cf, p, false, false);
        if icost_is_always(ic) { bonus += p.default_threshold; }
        else if !icost_is_never(ic) && icost_delta(ic) > 0 { bonus += icost_delta(ic); }
    }
    return if bonus > 0 { bonus } else { 0 };
}

// promoteConstantStackValues(F)
fn fs_promote_constant_stack_values(f: i32) {
    var u = first_use(f);
    var users: i32[>..<] = [];
    while u >= 0 { users.push(uses[u].user); u = use_next(u); }
    for call in users {
        if !is_inst(call) || iop(call) != OP_CALL { continue; }
        if !sc_bit(inst_parent(call), SB_EXEC) { continue; }
        for idx in cb_nargs(call) {
            let ao = cb_arg(call, idx);
            if !cb_arg_only_reads(call, idx) || ty_kind(vals[ao].ty) != TK_PTR { continue; }
            let cv = fs_constant_stack_value(call, ao);
            if cv < 0 { continue; }
            fs_nglobals++;
            let gv = new_glob(VK_GVAR, ty_ptr(0), -1, 1);
            let g = glob_of(gv);
            globs[g].module = fs_m;
            globs[g].vty = vals[cv].ty;
            globs[g].is_const = 1;
            globs[g].is_decl = 0;
            globs[g].linkage = LK_INTERNAL as u8;
            globs[g].dso_local = 1;
            set_op(gv, 0, cv);
            symtab_set_name(modules[fs_m].symtab, gv, str("specialized.arg.", fs_nglobals), true);
            module_append_global(gv);
            set_op(call, idx, gv);
        }
    }
}
fn fs_constant_stack_value(call: i32, v0: i32) -> i32 {
    let v = strip_ptr_casts(v0);
    if !is_inst(v) || iop(v) != OP_ALLOCA { return -1; }
    var sv: i32 = -1;
    var u = first_use(v);
    while u >= 0 {
        let us = uses[u].user;
        u = use_next(u);
        if us == call { continue; }
        if is_inst(us) && iop(us) == OP_STORE {
            if sv >= 0 || inst_is_volatile(us) { return -1; }
            sv = op(us, 0);
            continue;
        }
        return -1;
    }
    if sv < 0 { return -1; }
    let c = fs_candidate_constant(sv);
    if c < 0 || ty_kind(vals[c].ty) != TK_INT { return -1; }
    return c;
}

// removeSSACopy: same-type bitcasts
fn fs_remove_ssa_copy(f: i32) {
    var bb = func_first_block(f);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            let nx = inst_next(i);
            if iop(i) == OP_BITCAST && vals[i].ty == vals[op(i, 0)].ty {
                rauw(i, op(i, 0));
                inst_erase_from_parent(i);
            }
            i = nx;
        }
        bb = block_next(bb);
    }
}

// ---------------------------------------------------------------------------------------------
// CloneFunction with the metadata of a LocalChangesOnly clone

var fm_sp: i32 = -1;             // F.getSubprogram()
var fm_vm: i32 = -1;
var fm_inprog = hm_new();

fn fm_is_type_kind(k: i64) -> bool {
    k == DIK_BASICTYPE || k == DIK_FIXEDPOINTTYPE || k == DIK_STRINGTYPE || k == DIK_DERIVEDTYPE ||
    k == DIK_COMPOSITETYPE || k == DIK_SUBROUTINETYPE || k == DIK_SUBRANGETYPE
}
fn fm_is_local_scope_kind(k: i64) -> bool { k == DIK_SUBPROGRAM || k == DIK_LEXICALBLOCK || k == DIK_LEXICALBLOCKFILE }

// createIdentityMDPredicate(F, LocalChangesOnly)
fn fm_identity(m: i32) -> bool {
    if mds[m].kind != MK_DI { return false; }
    let k = di_kind(m);
    if k == DIK_COMPILEUNIT { return true; }
    if k == DIK_SUBPROGRAM { return m != fm_sp; }
    if k == DIK_LEXICALBLOCK || k == DIK_LEXICALBLOCKFILE { return di_scope_subprogram(m) != fm_sp; }
    if k == DIK_LOCALVARIABLE {
        let sc = di_slot(m, "scope");
        if sc >= 0 && mds[sc].kind == MK_DI && fm_is_local_scope_kind(di_kind(sc)) { return di_scope_subprogram(sc) != fm_sp; }
    }
    if k == DIK_GLOBALVAREXPR { return true; }
    if !fm_is_type_kind(k) { return false; }
    if fm_sp < 0 { return true; }
    let sc = if di_field_index(k, "scope") >= 0 { di_slot(m, "scope") } else { -1 };
    if k == DIK_DERIVEDTYPE && sc < 0 { return false; }
    if sc < 0 || mds[sc].kind != MK_DI || !fm_is_local_scope_kind(di_kind(sc)) { return true; }
    return di_scope_subprogram(sc) != fm_sp;
}

recursive fn fm_map(m: i32) -> i32 {
    if m < 0 { return -1; }
    let e = vmm_find(fm_vm, -2 - m);
    if e >= 0 { return vmm_ents[e].val; }
    let kind = mds[m].kind as i64;
    if kind == MK_STRING || kind == MK_INTLIT { return m; }
    if kind == MK_VALUE {
        let v = mds[m].extra;
        let nv = vmp_map_value(fm_vm, v, 0);
        if nv < 0 || nv == v { return m; }
        return md_value(nv);
    }
    if kind == MK_DIARGLIST { return m; }
    if fm_identity(m) { vmm_md_set(fm_vm, m, m); return m; }
    let n = mds[m].nops as i64;
    if mds[m].distinct != 0 {
        let mark0 = vmp_stack.len;
        for k in n { vmp_stack.push(md_op(m, k)); }
        let nm = md_get(kind, mds[m].extra, vmp_stack[mark0..], true);
        vmp_stack.resize(mark0);
        vmm_md_set(fm_vm, m, nm);
        for k in n {
            let o = md_ops[mds[m].ops + k];
            let mo = fm_map(o);
            md_ops[mds[nm].ops + k] = mo;
        }
        return nm;
    }
    if hm_has(fm_inprog, m as u64) { fs_not_ported("cloning a uniqued metadata cycle"); }
    hm_put(fm_inprog, m as u64, 1);
    let mark = vmp_stack.len;
    var same = true;
    for k in n {
        let o = md_ops[mds[m].ops + k];
        let mo = fm_map(o);
        vmp_stack.push(mo);
        if mo != o { same = false; }
    }
    hm_del_fm(m);
    var nm = m;
    if !same { nm = md_get(kind, mds[m].extra, vmp_stack[mark..], false); }
    vmp_stack.resize(mark);
    vmm_md_set(fm_vm, m, nm);
    return nm;
}
fn hm_del_fm(m: i32) { hm_del(fm_inprog, m as u64); }

fn fm_premap_inst(i: i32) {
    let ii = inst_of(i);
    for k in insts[ii].nmd { fm_map(md_att[insts[ii].md + 2 * k + 1]); }
    for k in nops(i) {
        let o = op(i, k);
        if o >= 0 && vals[o].kind == VK_MDVAL { fm_map(vals[o].sub); }
    }
    var r = inst_first_dbg(i);
    while r >= 0 {
        let x = dbgrecs[r];
        if x.kind as i64 == DR_ASSIGN { fs_not_ported("cloning #dbg_assign records"); }
        fm_map(x.dl);
        fm_map(x.dvar);
        fm_map(x.expr);
        r = x.next;
    }
}

// DISubprogram::cleanupRetainedNodesIf: drop global variable expressions not scoped in the new subprogram
fn fm_cleanup_retained_nodes(nsp: i32) {
    if nsp < 0 || mds[nsp].kind != MK_DI || di_kind(nsp) != DIK_SUBPROGRAM { return; }
    let fi = di_field_index(DIK_SUBPROGRAM, "retainedNodes");
    if fi < 0 { return; }
    let rn = md_op(nsp, fi);
    if rn < 0 || mds[rn].kind != MK_TUPLE { return; }
    var kept: i32[>..<] = [];
    var changed = false;
    for k in mds[rn].nops as i64 {
        let n = md_op(rn, k);
        if n >= 0 && mds[n].kind == MK_DI && di_kind(n) == DIK_GLOBALVAREXPR {
            let gvar = di_slot(n, "var");
            let sc = if gvar >= 0 { di_slot(gvar, "scope") } else { -1 };
            if di_scope_subprogram(sc) != nsp { changed = true; continue; }
        }
        kept.push(n);
    }
    if !changed { return; }
    md_ops[mds[nsp].ops + fi] = md_get(MK_TUPLE, -1, kept, false);
}

fn fs_clone_candidate_function(f: i32, nspec: i64) -> i32 {
    let g = glob_of(f);
    let m = globs[g].module;
    cur_module = m;
    let mark = vmm_mark();
    fm_vm = vmm_new();
    hm_clear(fm_inprog);
    var fname: u8[>..] = [];
    fname.append(val_name(f));
    // Function::Create(FTy, F->getLinkage(), F->getAddressSpace(), F->getName(), M)
    let nf = au_create_function(fname, globs[g].vty);
    let ng = glob_of(nf);
    globs[ng].linkage = globs[g].linkage;
    globs[ng].addrspace = globs[g].addrspace;
    for k in func_nargs(f) {
        let oa = func_arg(f, k);
        let na = func_arg(nf, k);
        if vals[oa].name >= 0 { set_name(na, val_name(oa)); }
        vmm_set(fm_vm, oa, na);
    }
    // copyAttributesFrom (GlobalValue, GlobalObject, Function)
    globs[ng].vis = globs[g].vis;
    globs[ng].unnamed = globs[g].unnamed;
    globs[ng].tls = globs[g].tls;
    globs[ng].dll = globs[g].dll;
    globs[ng].dso_local = globs[g].dso_local;
    globs[ng].partition = globs[g].partition;
    globs[ng].sanitizer = globs[g].sanitizer;
    globs[ng].align = globs[g].align;
    globs[ng].section = globs[g].section;
    globs[ng].cc = globs[g].cc;
    globs[ng].gc = globs[g].gc;
    globs[ng].attrs = globs[g].attrs;
    globs[ng].is_decl = 0;
    if globs[g].has_personality != 0 || globs[g].has_prefix != 0 || globs[g].has_prologue != 0 {
        fs_not_ported("cloning a function with personality / prefix / prologue data");
    }
    // CloneFunctionMetadataInto (premapped with the body's metadata) and CloneFunctionBodyInto
    fm_sp = func_get_md_fs(f, 0);
    var bb = func_first_block(f);
    while bb >= 0 {
        let cbb = clone_basic_block(bb, fm_vm, "", nf, false);
        vmm_set(fm_vm, bb, cbb);
        if sc_block_address_taken(bb) { fs_not_ported("cloning a function whose block addresses are taken"); }
        bb = block_next(bb);
    }
    for k in globs[g].nmd { fm_map(md_att[globs[g].md + 2 * k + 1]); }
    var cb = func_first_block(nf);
    while cb >= 0 {
        var i = block_first(cb);
        while i >= 0 { fm_premap_inst(i); i = inst_next(i); }
        cb = block_next(cb);
    }
    for k in globs[g].nmd {
        let kind = md_att[globs[g].md + 2 * k];
        let node = md_att[globs[g].md + 2 * k + 1];
        glob_add_md(nf, kind, fm_map(node));
    }
    cb = func_first_block(nf);
    while cb >= 0 {
        var i = block_first(cb);
        while i >= 0 {
            remap_instruction(i, fm_vm, 0);
            remap_dbg_record_range(i, fm_vm, 0);
            i = inst_next(i);
        }
        cb = block_next(cb);
    }
    fm_cleanup_retained_nodes(func_get_md_fs(nf, 0));
    vmm_release(mark);
    set_name(nf, str(val_name(f), ".specialized.", nspec));
    func_update_iid(nf);
    fs_remove_ssa_copy(nf);
    return nf;
}
fn func_get_md_fs(f: i32, kind: i32) -> i32 {
    let g = glob_of(f);
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == kind { return md_att[globs[g].md + 2 * j + 1]; } }
    return -1;
}

// createSpecialization(F, S)
fn fs_create_specialization(f: i32, args: const i32[:]) -> i32 {
    let clone = fs_clone_candidate_function(f, fs_specializations.len + 1);
    let cg = glob_of(clone);
    // setLinkage(InternalLinkage): local linkage implies default visibility and dso_local
    globs[cg].linkage = LK_INTERNAL as u8;
    globs[cg].vis = 0;
    globs[cg].dso_local = 1;
    let has, c = fn_entry_count(f);
    if has { fn_set_entry_count(clone, 0); }
    fs_set_lattice_for_spec_args(clone, args);
    sc_mark_block_executable(func_entry(clone));
    sc_add_arg_tracked(clone);
    sc_add_tracked_function(clone);
    fs_specializations.push(clone);
    return clone;
}

// findSpecializations(F, FuncSize, AllSpecs, SM)
fn fs_find_specializations(f: i32, fsize: i64) -> bool {
    var args: i32[>..<] = [];
    for k in func_nargs(f) { let a = func_arg(f, k); if fs_arg_interesting(a) { args.push(a); } }
    if args.len == 0 { return false; }
    var uniq: i32[>..<] = [];   // UniqueSpecs: spec indices
    var users: i32[>..<] = [];
    var u = first_use(f);
    while u >= 0 { users.push(uses[u].user); u = use_next(u); }
    for cs in users {
        if !is_inst(cs) || (iop(cs) != OP_CALL && iop(cs) != OP_INVOKE) { continue; }
        if called_function(cs) != f { continue; }
        if call_has_fn_attr(cs, AK_MinSize) { continue; }
        if !sc_bit(inst_parent(cs), SB_EXEC) { continue; }
        let at = sp_args.len as i32;
        for a in args {
            let c = fs_candidate_constant(cb_arg(cs, args_no[vals[a].sub] as i64));
            if c < 0 { continue; }
            sp_args.push(a);
            sp_args.push(c);
        }
        let n = sp_args.len as i32 - at;
        if n == 0 { continue; }
        // UniqueSpecs.find(S)
        var found: i32 = -1;
        for x in uniq {
            if sp_args_n[x] != n { continue; }
            var same = true;
            for j in n as i64 { if sp_args[sp_args_at[x] + j] != sp_args[at + j] { same = false; break; } }
            if same { found = x; break; }
        }
        if found >= 0 {
            sp_args.resize(at as i64);
            if inst_func(cs) == f { continue; }
            fs_spec_add_call_site(found, cs);
            continue;
        }
        // the specialisation gain
        var cs_save: i64 = 0;
        var score: i64 = 0;
        icv_begin(f);
        tti_init_function(f, globs[glob_of(f)].module);
        var j: i64 = 0;
        while j < n as i64 {
            let a = sp_args[at + j];
            let c = sp_args[at + j + 1];
            tti_init_function(f, globs[glob_of(f)].module);
            cs_save = tc_add(cs_save, icv_code_size_savings_for_arg(a, c));
            score += fs_inlining_bonus(a, c);
            j += 2;
        }
        tti_init_function(f, globs[glob_of(f)].module);
        cs_save = tc_add(cs_save, icv_code_size_savings_from_pending_phis());
        if !tc_valid(cs_save) { fs_not_ported("an invalid code size saving"); }
        let saving = cs_save & 0xFFFFFFFF;
        let spec_size = (fsize - saving) & 0xFFFFFFFF;
        var profitable = true;
        if !fs_force {
            // u32 arithmetic of IsProfitable
            if (score as u64) > (((fs_min_inlining_bonus * fsize) & 0xFFFFFFFF) / 100) as u64 {
                profitable = true;
            } else if saving < ((fs_min_codesize_savings * fsize) & 0xFFFFFFFF) / 100 {
                profitable = false;
            } else {
                tti_init_function(f, globs[glob_of(f)].module);
                let lat0 = icv_latency_savings_for_known_constants();
                if !tc_valid(lat0) { fs_not_ported("an invalid latency saving"); }
                let lat = lat0 & 0xFFFFFFFF;
                if lat < ((fs_min_latency_savings * fsize) & 0xFFFFFFFF) / 100 { profitable = false; }
                else if ((fs_growth_get(f) + spec_size) & 0xFFFFFFFF) / fsize > fs_max_codesize_growth { profitable = false; }
                else { score += max(saving, lat); }
            }
        }
        if !profitable { sp_args.resize(at as i64); continue; }
        let idx = sp_f.len as i32;
        sp_f.push(f); sp_clone.push(-1); sp_args_at.push(at); sp_args_n.push(n);
        sp_score.push((score as u64) & 0xFFFFFFFF); sp_size.push(spec_size); sp_cs_first.push(-1); sp_cs_last.push(-1);
        if inst_func(cs) != f { fs_spec_add_call_site(idx, cs); }
        uniq.push(idx);
        var smk: i64 = -1;
        for x, q in sm_f { if x == f { smk = q; } }
        if smk < 0 { sm_f.push(f); sm_b.push(idx); sm_e.push(idx + 1); } else { sm_e[smk] = idx + 1; }
    }
    return uniq.len > 0;
}

fn fs_spec_add_call_site(s: i32, cs: i32) {
    let id = sp_cs.len as i32;
    sp_cs.push(cs);
    sp_cs_next.push(-1);
    if sp_cs_last[s] < 0 { sp_cs_first[s] = id; } else { sp_cs_next[sp_cs_last[s]] = id; }
    sp_cs_last[s] = id;
}

// setCalledFunction(F)
fn fs_set_called_function(cs: i32, f: i32) {
    set_op(cs, nops(cs) - 1, f);
    insts[inst_of(cs)].ty2 = globs[glob_of(f)].vty;
}

// updateCallSites(F, Begin, End)
fn fs_update_call_sites(f: i32, b: i32, e: i32) {
    var to_update: i32[>..<] = [];
    var u = first_use(f);
    while u >= 0 {
        let cs = uses[u].user;
        u = use_next(u);
        if is_inst(cs) && is_callbase(cs) && called_function(cs) == f && sc_bit(inst_parent(cs), SB_EXEC) { to_update.push(cs); }
    }
    var left = to_update.len;
    for cs in to_update {
        var dec = inst_func(cs) == f;
        var best: i32 = -1;
        for s in b..e {
            if sp_clone[s] < 0 || (best >= 0 && sp_score[s] <= sp_score[best]) { continue; }
            var mismatch = false;
            var j: i64 = 0;
            while j < sp_args_n[s] as i64 {
                let a = sp_args[sp_args_at[s] + j];
                let c = sp_args[sp_args_at[s] + j + 1];
                if fs_candidate_constant(cb_arg(cs, args_no[vals[a].sub] as i64)) != c { mismatch = true; break; }
                j += 2;
            }
            if mismatch { continue; }
            best = s as i32;
        }
        if best >= 0 { fs_set_called_function(cs, sp_clone[best]); dec = true; }
        if dec { left--; }
    }
    if left == 0 && sc_bit(f, SB_ARGTRACK) && !sc_has_address_taken(f) {
        fs_mark_function_unreachable(f);
        if !fs_is_dead_function(f) { fs_dead.push(f); }
    }
}

fn fs_heap_less(i: i32, j: i32) -> bool {
    if sp_score[i] != sp_score[j] { return sp_score[i] > sp_score[j]; }
    return i > j;
}
fn fs_adjust_heap(xs: i32[>..<]&, hole0: i64, len: i64, v: i32) {
    var hole = hole0;
    let top = hole0;
    var second = hole0;
    while second < (len - 1) / 2 {
        second = 2 * (second + 1);
        if fs_heap_less(xs[second], xs[second - 1]) { second--; }
        xs[hole] = xs[second];
        hole = second;
    }
    if (len & 1) == 0 && second == (len - 2) / 2 {
        second = 2 * (second + 1);
        xs[hole] = xs[second - 1];
        hole = second - 1;
    }
    fs_push_heap_at(xs, hole, top, v);
}
fn fs_push_heap_at(xs: i32[>..<]&, hole0: i64, top: i64, v: i32) {
    var hole = hole0;
    var parent = (hole - 1) / 2;
    while hole > top && fs_heap_less(xs[parent], v) {
        xs[hole] = xs[parent];
        hole = parent;
        parent = (hole - 1) / 2;
    }
    xs[hole] = v;
}

// FunctionSpecializer::run
fn fs_run() -> bool {
    sp_f.clear(); sp_clone.clear(); sp_args_at.clear(); sp_args_n.clear(); sp_score.clear(); sp_size.clear();
    sp_cs_first.clear(); sp_cs_last.clear(); sp_args.clear(); sp_cs.clear(); sp_cs_next.clear();
    sm_f.clear(); sm_b.clear(); sm_e.clear();
    var ncand: i64 = 0;
    var f = modules[fs_m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if !fs_is_candidate(f) { f = nf; continue; }
        var mi = fs_metric_index(f);
        let inserted = mi < 0;
        if inserted {
            let n, nodup, rec = fs_metrics(f);
            fs_metric_f.push(f); fs_metric_size.push(n); fs_metric_nodup.push(nodup); fs_metric_rec.push(rec);
            mi = fs_metric_f.len - 1;
        }
        let require_min = !fs_force && (fs_literal || !func_has_fn_attr(f, AK_NoInline));
        let sz = fs_metric_size[mi];
        if fs_metric_nodup[mi] || !tc_valid(sz) || (require_min && sz < fs_min_function_size) { f = nf; continue; }
        if !fs_literal && !inserted && !fs_metric_rec[mi] { f = nf; continue; }
        let fsize = sz & 0xFFFFFFFF;
        if inserted && fs_metric_rec[mi] { fs_promote_constant_stack_values(f); }
        if !fs_find_specializations(f, fsize) { f = nf; continue; }
        ncand++;
        f = nf;
    }
    if ncand == 0 { return false; }
    let nall = sp_f.len;
    let nspecs = min(ncand * fs_max_clones, nall);
    var best: i32[>..<] = [];
    for k in nspecs + 1 { best.push(if k < nspecs { k as i32 } else { 0 }); }
    if nall > nspecs {
        // std::make_heap(BestSpecs.begin(), BestSpecs.begin() + NSpecs, CompareScore)
        if nspecs >= 2 {
            var parent = (nspecs - 2) / 2;
            loop {
                let v = best[parent];
                fs_adjust_heap(best, parent, nspecs, v);
                if parent == 0 { break; }
                parent--;
            }
        }
        for i in nspecs..nall {
            best[nspecs] = i as i32;
            // push_heap(begin, end)
            fs_push_heap_at(best, nspecs, 0, best[nspecs]);
            // pop_heap(begin, end)
            let len = nspecs + 1;
            if len > 1 {
                let v = best[len - 1];
                best[len - 1] = best[0];
                fs_adjust_heap(best, 0, len - 1, v);
            }
        }
    }
    var orig: i32[>..<] = [];
    var clones: i32[>..<] = [];
    for k in nspecs {
        let s = best[k];
        let sf = sp_f[s];
        fs_growth_add(sf, sp_size[s]);
        var args: i32[>..<] = [];
        for j in sp_args_n[s] as i64 { args.push(sp_args[sp_args_at[s] + j]); }
        let clone = fs_create_specialization(sf, args);
        sp_clone[s] = clone;
        var c = sp_cs_first[s];
        while c >= 0 {
            let call = sp_cs[c];
            fs_set_called_function(call, clone);
            let ok, cnt = bfi_block_profile_count(inst_parent(call));
            if ok {
                let ch, cc = fn_entry_count(clone);
                if ch {
                    fn_set_entry_count(clone, cnt + cc);
                    let oh, oc = fn_entry_count(sf);
                    if oh && oc >= cnt { fn_set_entry_count(sf, oc - cnt); }
                }
            }
            c = sp_cs_next[c];
        }
        clones.push(clone);
        var seen = false;
        for x in orig { if x == sf { seen = true; } }
        if !seen { orig.push(sf); }
    }
    fs_solve_while_resolved_undefs_in(clones);
    // OriginalFuncs is a SmallPtrSet<Function *, 8>: small-mode iteration is insertion order
    if orig.len > 8 { fs_not_ported("more than 8 specialized functions in one round (SmallPtrSet iteration order)"); }
    for of in orig {
        var k: i64 = -1;
        for x, q in sm_f { if x == of { k = q; } }
        fs_update_call_sites(of, sm_b[k], sm_e[k]);
    }
    for cf in clones {
        let rt = ty_fn_ret(func_type(cf));
        if rt == T_VOID { continue; }
        if ty_is_struct(rt) {
            if !fs_is_struct_lattice_constant(cf) { continue; }
        } else {
            let ri = sc_ret_index(cf);
            if sc_is_overdefined_lv(sc_vls[sc_ret_vl[ri]]) { continue; }
        }
        var users: i32[>..<] = [];
        var u = first_use(cf);
        while u >= 0 { users.push(uses[u].user); u = use_next(u); }
        for cs in users {
            if !is_inst(cs) || !is_callbase(cs) || called_function(cs) != cf { continue; }
            fs_invalidate(cs);
            sc_handle_call_result(cs);
        }
    }
    fs_solve_while_resolved_undefs();
    for of in orig {
        let mi = fs_metric_index(of);
        if fs_metric_rec[mi] { fs_promote_constant_stack_values(of); }
    }
    return true;
}

// ~FunctionSpecializer: removeDeadFunctions, cleanUpSSA
fn fs_finish() {
    for f in fs_dead {
        var users: i32[>..<] = [];
        var u = first_use(f);
        while u >= 0 { users.push(uses[u].user); u = use_next(u); }
        for cs in users {
            if !is_inst(cs) { fs_not_ported("a non-call user of a dead specialized function"); }
            rauw(cs, c_poison(vals[cs].ty));
            inst_erase_from_parent(cs);
        }
        fs_erase_function(f);
    }
    fs_dead.clear();
    for f in fs_specializations { fs_remove_ssa_copy(f); }
}

// Function::eraseFromParent
fn fs_erase_function(f: i32) {
    var bb = func_first_block(f);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 { drop_all_refs(i); i = inst_next(i); }
        bb = block_next(bb);
    }
    while func_first_block(f) >= 0 { block_erase(func_first_block(f)); }
    for k in nops(f) { set_op(f, k, -1); }
    module_remove_global(f);
    if vals[f].name >= 0 { symtab_remove(modules[globs[glob_of(f)].module].symtab, f); }
    val_set_dead(f);
}

// IPSCCP: while (Iters++ < FuncSpecMaxIters && Specializer.run());
fn fs_run_iterations(m: i32) -> bool {
    fs_init(m);
    let max_iters = flag_int("funcspec-max-iters", 10);
    var any = false;
    var it: i64 = 0;
    while it < max_iters {
        it++;
        if !fs_run() { break; }
        any = true;
    }
    return any;
}
