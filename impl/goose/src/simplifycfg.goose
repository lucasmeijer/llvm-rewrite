// SimplifyCFG: port of llvm/lib/Transforms/Utils/SimplifyCFG.cpp (SimplifyCFGOpt and its static helpers) and
// llvm/lib/Transforms/Scalar/SimplifyCFGPass.cpp (the pass: options, removeUnreachableBlocks /
// tailMergeBlocksWithSimilarFunctionTerminators / iterativelySimplifyCFG). The Local.cpp and BasicBlockUtils.cpp
// helpers are in cfgutil.goose, the cost model in tti.goose, branch weights in profdata.goose and
// isSafeToSpeculativelyExecute in speculate.goose.
//
// State of SimplifyCFGOpt (options, Resimplify, LoopHeaders) is module globals: one instance at a time.
// The DomTreeUpdater (-simplifycfg-require-and-preserve-domtree) is dtu.goose's active updater and
// cu_dtu (cfgutil.goose) says whether it is in use.
// What isn't ported fails loudly (scf_not_ported) at the point where LLVM would transform.
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
import dtu;
import analyses;
import local;
import loopsimplify;
import apint;
import pm;
import vt;
import poison;
import knownbits;
import implied;
import constrange;
import constfold;
import cfold;
import assume;
import instsimplify;
import autoupgrade;
import flags;
import tti;
import profdata;
import speculate;
import cfgutil;
import mem2reg;
import dinfo;

fn scf_not_ported(what: const u8[:]) { fatal(str("SimplifyCFG: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Options (SimplifyCFGOptions + the cl::opts of SimplifyCFG.cpp)

struct SCOpts {
    bonus: i64, fwd_switch_cond: bool, range_to_icmp: bool, to_arith: bool, to_lookup: bool, keep_loops: bool,
    hoist_common: bool, hoist_ldst_cf: bool, sink_common: bool, simplify_condbr: bool, spec_blocks: bool,
    spec_unpred: bool,
}
fn scf_default_opts() -> SCOpts {
    SCOpts { bonus: 1, fwd_switch_cond: false, range_to_icmp: false, to_arith: false, to_lookup: false, keep_loops: true,
             hoist_common: false, hoist_ldst_cf: false, sink_common: false, simplify_condbr: true, spec_blocks: true,
             spec_unpred: false }
}

var so: SCOpts = SCOpts { bonus: 1, fwd_switch_cond: false, range_to_icmp: false, to_arith: false, to_lookup: false,
                          keep_loops: true, hoist_common: false, hoist_ldst_cf: false, sink_common: false,
                          simplify_condbr: true, spec_blocks: true, spec_unpred: false };

var cl_phi_fold_threshold: i64 = 2;
var cl_two_entry_phi_threshold: i64 = 4;
var cl_hoist_common: bool = true;
var cl_hoist_loads_cf: bool = true;
var cl_hoist_stores_cf: bool = true;
var cl_hoist_ldst_cf_threshold: i64 = 6;
var cl_hoist_skip_limit: i64 = 20;
var cl_sink_common: bool = true;
var cl_hoist_cond_stores: bool = true;
var cl_merge_cond_stores: bool = true;
var cl_merge_cond_stores_aggr: bool = false;
var cl_spec_one_expensive: bool = true;
var cl_max_spec_depth: i64 = 10;
var cl_max_small_block: i64 = 10;
var cl_branch_fold_threshold: i64 = 2;
var cl_branch_fold_vec_mult: i64 = 2;
var cl_merge_invokes: bool = true;
var cl_max_switch_cases_per_result: i64 = 16;
var cl_max_jt_live_blocks: i64 = 24;

// SimplifyCFGOpt state
var scf_opt_table: SCOpts[>..];
var scf_resimplify: bool = false;
var scf_loop_headers: i32[>..<];
var scf_fn: i32 = -1;

fn scf_request_resimplify() -> bool { scf_resimplify = true; return true; }
fn scf_is_loop_header(bb: i32) -> bool { position(scf_loop_headers, bb) >= 0 }

let MDK_DBG_SC: i32 = 0;
let MDK_PROF_SC: i32 = 2;
fn mdk_unpredictable() -> i32 { md_kind_id("unpredictable") }

// ---------------------------------------------------------------------------------------------
// IRBuilder (insertion point, current debug location; ConstantFolder or NoFolder)

var sb_bb: i32 = -1;
var sb_pos: i32 = -1;        // insert before; -1 = at the end of sb_bb
var sb_dl: i32 = -1;
var sb_nofold: bool = false;
var sb_annot: i32 = -1;       // IRBuilderCallbackInserter of performBranchToCommonDestFolding: !annotation to copy

// IRBuilder<> Builder(I) / SetInsertPoint(I): before I, with I's debug location
fn sb_at(i: i32) { sb_bb = inst_parent(i); sb_pos = i; sb_dl = inst_get_md(i, MDK_DBG_SC); sb_nofold = false; sb_annot = -1; }
fn sb_at_nofold(i: i32) { sb_at(i); sb_nofold = true; }
fn sb_set_before(i: i32) { sb_bb = inst_parent(i); sb_pos = i; sb_dl = inst_get_md(i, MDK_DBG_SC); }
// SetInsertPoint(BB): at the end; the debug location is kept
fn sb_set_end(bb: i32) { sb_bb = bb; sb_pos = -1; }

fn sb_insert(iv: i32, name: const u8[:]) -> i32 {
    if sb_pos >= 0 { inst_insert_before(iv, sb_pos); } else { block_append_inst(sb_bb, iv); }
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    if sb_annot >= 0 { inst_set_md(iv, mdk_annotation(), sb_annot); }
    if sb_dl >= 0 { inst_set_md(iv, MDK_DBG_SC, sb_dl); }
    return iv;
}

fn sb_binop(o: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if !sb_nofold && is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    return sb_insert(create_inst(o, vals[a].ty, [a, b]), name);
}
fn sb_not(v: i32, name: const u8[:]) -> i32 { sb_binop(OP_XOR, v, c_all_ones(vals[v].ty), name) }
fn sb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if !sb_nofold && is_constant(a) && is_constant(b) {
        let r = cf_compare(p, a, b);
        if r >= 0 { return r; }
    }
    let c = create_inst(OP_ICMP, cmp_result_ty(vals[a].ty), [a, b]);
    insts[inst_of(c)].pred = p as u8;
    return sb_insert(c, name);
}
// CreateSelect(C, T, F, Name, MDFrom) / CreateSelectFMF (fmf_from: an FP PHI whose flags are copied)
fn sb_select(c: i32, t: i32, f: i32, name: const u8[:], mdfrom: i32) -> i32 { sb_select_fmf(c, t, f, -1, name, mdfrom) }
fn sb_select_fmf(c: i32, t: i32, f: i32, fmf_from: i32, name: const u8[:], mdfrom: i32) -> i32 {
    if !sb_nofold && is_constant(c) && is_constant(t) && is_constant(f) {
        let r = cf_select(c, t, f);
        if r >= 0 { return r; }
    }
    let s = create_inst(OP_SELECT, vals[t].ty, [c, t, f]);
    if mdfrom >= 0 {
        let prof = inst_get_md(mdfrom, MDK_PROF_SC);
        let un = inst_get_md(mdfrom, mdk_unpredictable());
        if prof >= 0 { inst_set_md(s, MDK_PROF_SC, prof); }
        if un >= 0 { inst_set_md(s, mdk_unpredictable(), un); }
    }
    if fmf_from >= 0 && is_fp_math_operator(s) { insts[inst_of(s)].fmf = insts[inst_of(fmf_from)].fmf; }
    return sb_insert(s, name);
}
// CreateLogicalAnd / CreateLogicalOr
fn sb_logical(is_and: bool, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_and { return sb_select(a, b, c_null(vals[b].ty), name, -1); }
    return sb_select(a, c_all_ones(vals[b].ty), b, name, -1);
}
fn sb_br(dest: i32) -> i32 { sb_insert(create_inst(OP_BR, T_VOID, [dest]), "") }
fn sb_condbr(c: i32, t: i32, f: i32) -> i32 { sb_insert(create_inst(OP_CONDBR, T_VOID, [c, t, f]), "") }
fn sb_unreachable() -> i32 { sb_insert(create_inst(OP_UNREACHABLE, T_VOID, []), "") }
fn sb_cast(o: i64, v: i32, ty: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == ty { return v; }
    if !sb_nofold && is_constant(v) {
        if is_desirable_cast_op(o) { return ce_cast(o, v, ty); }
        let r = cf_cast(o, v, ty);
        if r >= 0 { return r; }
    }
    return sb_insert(create_inst(o, ty, [v]), name);
}
fn sb_freeze(v: i32, name: const u8[:]) -> i32 { sb_insert(create_inst(OP_FREEZE, vals[v].ty, [v]), name) }
// CreateSwitch(V, Dest, NumCases): reserved operands 2 + NumCases (our capacity 2R - 2)
fn sb_switch(v: i32, def: i32, ncases: i64) -> i32 {
    let si = new_inst(OP_SWITCH, T_VOID, 2 + 2 * ncases);
    vals[si].nops = 2;
    set_op(si, 0, v);
    set_op(si, 1, def);
    return sb_insert(si, "");
}
// CreateIntrinsic / CreateCall of an intrinsic
fn sb_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    return sb_insert(iv, name);
}
// CreateAssumption(Cond)
fn sb_assume(c: i32) -> i32 { let one: i32[0] = []; return sb_intrinsic(IID_assume, one, [c], ""); }

// InvertBranch(PBI, Builder)
fn scf_invert_branch(pbi: i32) {
    var nc = op(pbi, 0);
    if has_one_use(nc) && is_inst(nc) && (iop(nc) == OP_ICMP || iop(nc) == OP_FCMP) {
        insts[inst_of(nc)].pred = cmp_inverse_pred(inst_pred(nc)) as u8;
    } else {
        let nm = name_plus(nc, ".not");
        nc = sb_not(nc, nm);
    }
    set_op(pbi, 0, nc);
    cu_swap_successors(pbi);
}

// Instruction::dropLocation
fn scf_drop_location(i: i32) {
    let dl = inst_get_md(i, MDK_DBG_SC);
    if dl < 0 { return; }
    var may_call = false;
    if is_callbase(i) {
        let id = inst_iid(i);
        may_call = id == 0 || starts_with(intr_name(id as i64), "llvm.objc.");
    }
    if !may_call { inst_erase_md(i, MDK_DBG_SC); return; }
    let sp = func_get_md(inst_func(i), 0);
    if sp >= 0 { inst_set_md(i, MDK_DBG_SC, di_location_get(0, 0, sp, -1, false)); }
    else { inst_erase_md(i, MDK_DBG_SC); }
}

// IRBuilder::getTrue / getFalse
fn scf_true() -> i32 { c_int(T_I1, 1) }
fn scf_false() -> i32 { c_int(T_I1, 0) }

// Instruction::setSuccessor / getSuccessor helpers
fn br_cond(bi: i32) -> i32 { op(bi, 0) }
fn br_succ(bi: i32, k: i64) -> i32 { op(bi, 1 + k) }
fn br_set_succ(bi: i32, k: i64, b: i32) { set_op(bi, 1 + k, b); }
fn br_set_cond(bi: i32, c: i32) { set_op(bi, 0, c); }

fn has_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
fn num_uses(v: i32) -> i64 { var n = 0; var u = vals[v].first_use; while u >= 0 { n++; u = uses[u].next; } return n; }
fn has_n_uses(v: i32, n: i64) -> bool { num_uses(v) == n }
fn user_back(v: i32) -> i32 { uses[vals[v].first_use].user }
fn is_icmp(v: i32) -> bool { is_inst(v) && iop(v) == OP_ICMP }

// Value::getName() + suffix
fn name_plus(v: i32, s: const u8[:]) -> u8[>..] {
    var r: u8[>..] = [];
    r.append(val_name(v));
    r.append(s);
    return r;
}

// erase + the debug-info consequences (the instruction must have no uses)
fn scf_erase(i: i32) { inst_erase_from_parent(i); }

// cost kind of the function (hasMinSize -> CodeSize)
fn scf_cost_kind(bb: i32) -> i64 {
    if func_has_fn_attr(block_func(bb), AK_MinSize) { return TCK_CODE_SIZE; }
    return TCK_SIZE_AND_LATENCY;
}

// computeSpeculationCost
fn scf_spec_cost(i: i32) -> i64 { tti_instruction_cost(i, TCK_SIZE_AND_LATENCY) }

// ---------------------------------------------------------------------------------------------
// incomingValuesAreCompatible / safeToMergeTerminators / addPredecessorToBlock

fn incoming_values_compatible(bb: i32, b0: i32, b1: i32, eq_set: const i32[:], use_set: bool) -> bool {
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        let v0 = phi_value_for_block(i, b0);
        let v1 = phi_value_for_block(i, b1);
        i = inst_next(i);
        if v0 == v1 { continue; }
        if use_set && position(eq_set, v0) >= 0 && position(eq_set, v1) >= 0 { continue; }
        return false;
    }
    return true;
}

// safeToMergeTerminators(SI1, SI2, FailBlocks)
fn safe_to_merge_terminators(t1: i32, t2: i32, fail: i32[>..<]&, collect: bool) -> bool {
    if t1 == t2 { return false; }
    let b1 = inst_parent(t1);
    let b2 = inst_parent(t2);
    var s1: i32[>..<] = [];
    cu_succs(b1, s1);
    var s2: i32[>..<] = [];
    cu_succs(b2, s2);
    var failed = false;
    let none: i32[0] = [];
    for s in s2 {
        if position(s1, s) < 0 { continue; }
        if incoming_values_compatible(s, b1, b2, none, false) { continue; }
        failed = true;
        if collect { cu_push_unique(fail, s); } else { break; }
    }
    return !failed;
}

fn add_predecessor_to_block(succ: i32, newp: i32, existp: i32) {
    var i = block_first(succ);
    while i >= 0 && iop(i) == OP_PHI {
        let ni = inst_next(i);
        phi_add_incoming(i, phi_value_for_block(i, existp), newp);
        i = ni;
    }
}

// ---------------------------------------------------------------------------------------------
// dominatesMergePoint

var dmp_aggr: i32[>..<];          // AggressiveInsts (membership + count)
var dmp_zero_cost: i32[>..<];     // ZeroCostInstructions

recursive fn dominates_merge_point(v: i32, bb: i32, ins_pt: i32, cost: i64&, budget: i64, depth: i64) -> bool {
    if depth == cl_max_spec_depth { return false; }
    if !is_inst(v) { return true; }
    let pbb = inst_parent(v);
    if pbb == bb { return false; }
    let bi = block_terminator(pbb);
    if iop(bi) != OP_BR || op(bi, 0) != bb { return true; }
    if position(dmp_aggr, v) >= 0 { return true; }
    if !spec_safe(v, ins_pt, true) { return false; }
    // m_ExtractValue<1>(m_OneUse(m_WithOverflowInst(OverflowInst)))
    var ov: i32 = -1;
    if iop(v) == OP_EXTRACTVALUE && insts[inst_of(v)].naux == 1 && ints[insts[inst_of(v)].aux] == 1 {
        let a = op(v, 0);
        if is_inst(a) && has_one_use(a) && is_with_overflow_iid(inst_iid(a)) { ov = a; }
    }
    if ov >= 0 {
        if position(dmp_zero_cost, ov) < 0 { dmp_zero_cost.push(ov); }
        cost = tc_add(cost, 1);
    } else if position(dmp_zero_cost, v) < 0 {
        cost = tc_add(cost, scf_spec_cost(v));
    }
    if cost > budget && (!cl_spec_one_expensive || dmp_aggr.len > 0 || depth > 0 || !tc_valid(cost)) { return false; }
    for k in nops(v) {
        if !dominates_merge_point(op(v, k), bb, ins_pt, cost, budget, depth + 1) { return false; }
    }
    dmp_aggr.push(v);
    return true;
}

fn is_with_overflow_iid(id: i32) -> bool {
    return id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_ssub_with_overflow ||
           id == IID_usub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow;
}

// ---------------------------------------------------------------------------------------------
// getConstantInt(V, DL)

fn get_constant_int(v: i32) -> i32 {
    let k = vals[v].kind;
    if k == VK_CINT { return if ty_is_vector(vals[v].ty) { -1 } else { v }; }
    if !is_constant(v) || ty_kind(vals[v].ty) != TK_PTR { return -1; }
    let as_ = ptr_as(vals[v].ty);
    if dl_has_unstable_repr(as_) { return -1; }
    let ity = ty_int(dl_ptr(as_).bits);
    if k == VK_CNULL { return c_int(ity, 0); }
    if k == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_INTTOPTR {
        let c = op(v, 0);
        if vals[c].kind == VK_CINT && !ty_is_vector(vals[c].ty) {
            if vals[c].ty == ity { return c; }
            return cf_fold_integer_cast(c, ity, false);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// eraseTerminatorAndDCECond

fn erase_terminator_and_dce_cond(ti: i32) {
    var c: i32 = -1;
    let o = iop(ti);
    if o == OP_SWITCH || o == OP_CONDBR || o == OP_INDIRECTBR { c = op(ti, 0); if !is_inst(c) { c = -1; } }
    scf_erase(ti);
    if c >= 0 { cu_recursively_delete_dead(c); }
}

// ---------------------------------------------------------------------------------------------
// Value equality comparisons

struct VCase { v: i32, d: i32 }

// isValueEqualityComparison
fn is_value_equality_comparison(ti: i32) -> i32 {
    var cv: i32 = -1;
    let o = iop(ti);
    if o == OP_SWITCH {
        if !cu_has_n_preds_or_more(inst_parent(ti), 128 / term_nsucc(ti)) { cv = op(ti, 0); }
    } else if o == OP_CONDBR {
        let c = op(ti, 0);
        if has_one_use(c) {
            if is_icmp(c) {
                let p = inst_pred(c);
                if (p == P_EQ || p == P_NE) && get_constant_int(op(c, 1)) >= 0 { cv = op(c, 0); }
            } else if is_inst(c) && iop(c) == OP_TRUNC {
                if (insts[inst_of(c)].flags & FL_NUW) != 0 { cv = op(c, 0); }
            }
        }
    }
    if cv >= 0 && is_inst(cv) && iop(cv) == OP_PTRTOINT {
        let p = op(cv, 0);
        let as_ = ptr_as(vals[p].ty);
        if dl_has_unstable_repr(as_) { return cv; }
        if vals[cv].ty == ty_int(dl_ptr(as_).bits) && !ty_is_vector(vals[p].ty) { cv = p; }
    }
    return cv;
}

// getValueEqualityComparisonCases: returns the default block
fn get_vec_cases(ti: i32, cases: VCase[>..<]&) -> i32 {
    cases.clear();
    if iop(ti) == OP_SWITCH {
        for k in sw_ncases(ti) { cases.push(VCase { v: sw_case_val(ti, k), d: sw_case_dest(ti, k) }); }
        return sw_default(ti);
    }
    let c = op(ti, 0);
    var p: i64 = P_NE;
    var cv: i32 = -1;
    if is_icmp(c) { p = inst_pred(c); cv = get_constant_int(op(c, 1)); }
    else { cv = c_int(vals[op(c, 0)].ty, 0); }
    let succ = br_succ(ti, if p == P_NE { 1 } else { 0 });
    cases.push(VCase { v: cv, d: succ });
    return br_succ(ti, if p == P_EQ { 1 } else { 0 });
}

fn eliminate_block_cases(bb: i32, cases: VCase[>..<]&) {
    var w = 0;
    for k in cases.len { if cases[k].d != bb { cases[w] = cases[k]; w++; } }
    cases.resize(w);
}

fn values_overlap(c1: VCase[>..<]&, c2: VCase[>..<]&) -> bool {
    for a in c1 { for b in c2 { if a.v == b.v { return true; } } }
    return false;
}

// simplifyEqualityComparisonWithOnlyPredecessor
fn simplify_eq_cmp_with_only_pred(ti: i32, pred: i32) -> bool {
    let pv = is_value_equality_comparison(block_terminator(pred));
    if pv < 0 { return false; }
    let tv = is_value_equality_comparison(ti);
    if tv != pv { return false; }
    var pcases: VCase[>..<] = [];
    let pdef = get_vec_cases(block_terminator(pred), pcases);
    eliminate_block_cases(pdef, pcases);
    var tcases: VCase[>..<] = [];
    let tdef = get_vec_cases(ti, tcases);
    eliminate_block_cases(tdef, tcases);
    let tibb = inst_parent(ti);
    if pdef == tibb {
        if !values_overlap(pcases, tcases) { return false; }
        if iop(ti) == OP_CONDBR {
            sb_at(ti);
            sb_br(tdef);
            block_remove_predecessor(tcases[0].d, pdef, false);
            erase_terminator_and_dce_cond(ti);
            cu_apply1(DT_DELETE, pdef, tcases[0].d);
            return true;
        }
        swp_begin(ti);
        var dead: i32[>..<] = [];
        for c in pcases { dead.push(c.v); }
        var succ_list: i32[>..<] = [];
        var succ_cnt: i64[>..<] = [];
        var k = sw_ncases(ti);
        while k > 0 {
            k--;
            let s = sw_case_dest(ti, k);
            if cu_dtu {
                let j = position(succ_list, s);
                if j < 0 { succ_list.push(s); succ_cnt.push(1); } else { succ_cnt[j] += 1; }
            }
            if position(dead, sw_case_val(ti, k)) >= 0 {
                block_remove_predecessor(s, pdef, false);
                swp_remove_case(ti, k);
                if cu_dtu { let j = position(succ_list, s); succ_cnt[j] -= 1; }
            }
        }
        if cu_dtu {
            var ups: DTUpdate[>..<] = [];
            for j in succ_list.len { if succ_cnt[j] == 0 { cu_upd(ups, DT_DELETE, pdef, succ_list[j]); } }
            dtu_apply_updates(ups);
        }
        swp_end();
        return true;
    }
    var tiv: i32 = -1;
    for c in pcases {
        if c.d == tibb {
            if tiv >= 0 { return false; }
            tiv = c.v;
        }
    }
    var real: i32 = -1;
    for c in tcases { if c.v == tiv { real = c.d; break; } }
    if real < 0 { real = tdef; }
    var removed: i32[>..<] = [];
    var check = real;
    var succs: i32[>..<] = [];
    cu_succs(tibb, succs);
    for s in succs {
        if s != check {
            if s != real { cu_push_unique(removed, s); }
            block_remove_predecessor(s, tibb, false);
        } else { check = -1; }
    }
    sb_at(ti);
    sb_br(real);
    erase_terminator_and_dce_cond(ti);
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        for r in removed { cu_upd(ups, DT_DELETE, tibb, r); }
        dtu_apply_updates(ups);
    }
    return true;
}

// getBranchWeights(TI, Weights): the default weight first
fn get_branch_weights_def_first(ti: i32, ws: u64[>..<]&) {
    let m = pd_prof(ti);
    pd_extract_md(m, ws);
    if iop(ti) == OP_CONDBR {
        let c = op(ti, 0);
        if !is_icmp(c) { return; }
        if inst_pred(c) == P_EQ { let t = ws[0]; ws[0] = ws[ws.len - 1]; ws[ws.len - 1] = t; }
    }
}

// cloneInstructionsIntoPredecessorBlockAndUpdateSSAUses(BB, PredBlock, VMap); vmap is (from, to) pairs
fn clone_insts_into_pred(bb: i32, pred: i32, vmap: i32[>..<]&) {
    let pti = block_terminator(pred);
    var bi = block_first(bb);
    while bi >= 0 {
        let bonus = bi;
        bi = inst_next(bi);
        if is_terminator(bonus) { continue; }
        if inst_iid(bonus) == IID_pseudoprobe { continue; }
        let nb = inst_clone(bonus);
        // Unless the instruction has the same !dbg location as the branch, drop it.
        let ndl = inst_get_md(nb, MDK_DBG_SC);
        let pdl = inst_get_md(pti, MDK_DBG_SC);
        if !scf_same_source_location(ndl, pdl) {
            inst_erase_md(nb, MDK_DBG_SC);
        } else if ndl >= 0 {
            scf_map_atom_instance(ndl);
        }
        scf_remap_instruction(nb, vmap);
        cu_drop_ub_implying_attrs_and_metadata(nb);
        inst_insert_before(nb, pti);
        if inst_first_dbg(bonus) >= 0 { scf_not_ported("cloning debug records of bonus instructions"); }
        // takeName, then the old one gets ".old"
        cu_take_name(nb, bonus);
        if vals[nb].name >= 0 {
            let nm = name_plus(nb, ".old");
            set_name(bonus, nm);
        }
        vmap.push(bonus);
        vmap.push(nb);
        var u = first_use(bonus);
        while u >= 0 {
            let nu = use_next(u);
            let ui = uses[u].user;
            if is_inst(ui) && iop(ui) == OP_PHI {
                if use_aux[u] != bb { use_set(u, nb); }
            }
            u = nu;
        }
    }
    let pdl = inst_get_md(pti, MDK_DBG_SC);
    if pdl >= 0 {
        let tdl = inst_get_md(block_terminator(bb), MDK_DBG_SC);
        if scf_atom_group(pdl) == 0 && tdl >= 0 && scf_atom_group(tdl) != 0 && scf_same_source_location(pdl, tdl) {
            scf_not_ported("key-instructions atom groups");
        }
    }
}

// RemapInstruction(I, VMap, RF_NoModuleLevelChanges | RF_IgnoreMissingLocals): operands found in vmap are
// replaced (PHI incoming blocks too).
fn scf_remap_instruction(i: i32, vmap: i32[>..<]&) {
    for k in nops(i) {
        let v = op(i, k);
        if v < 0 { continue; }
        let j = vmap_find(vmap, v);
        if j >= 0 { set_op(i, k, j); }
    }
    if iop(i) == OP_PHI {
        for k in nops(i) {
            let b = phi_block(i, k);
            let j = vmap_find(vmap, b);
            if j >= 0 { phi_set_block(i, k, j); }
        }
    }
    scf_remap_md_operands(i, vmap);
}
fn vmap_find(vmap: i32[>..<]&, v: i32) -> i32 {
    var k = vmap.len - 2;
    while k >= 0 { if vmap[k] == v { return vmap[k + 1]; } k -= 2; }
    return -1;
}
// Metadata operands of intrinsic calls (metadata-as-value of a local value) would need remapping.
fn scf_remap_md_operands(i: i32, vmap: i32[>..<]&) {
    for k in nops(i) {
        let v = op(i, k);
        if v >= 0 && vals[v].kind == VK_MDVAL {
            let m = vals[v].sub;
            if mds[m].kind == MK_VALUE && vmap_find(vmap, mds[m].extra) >= 0 { scf_not_ported("remapping local metadata operands"); }
        }
    }
}

// DebugLoc::isSameSourceLocation: same line, column, scope, inlinedAt (and the atom data is ignored)
fn scf_same_source_location(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if a < 0 || b < 0 { return false; }
    if !cu_is_dilocation(a) || !cu_is_dilocation(b) { return false; }
    return di_int(a, "line") == di_int(b, "line") && di_int(a, "column") == di_int(b, "column") &&
           di_slot(a, "scope") == di_slot(b, "scope") && di_slot(a, "inlinedAt") == di_slot(b, "inlinedAt");
}
fn scf_atom_group(dl: i32) -> i64 {
    if !cu_is_dilocation(dl) { return 0; }
    return di_int(dl, "atomGroup");
}
fn scf_map_atom_instance(dl: i32) { if scf_atom_group(dl) != 0 { scf_not_ported("key-instructions atom groups"); } }

// performValueComparisonIntoPredecessorFolding
fn perform_value_cmp_into_pred_folding(ti: i32, cv0: i32, pti: i32) -> bool {
    var cv = cv0;
    let bb = inst_parent(ti);
    let pred = inst_parent(pti);
    var ups: DTUpdate[>..<] = [];
    var bbcases: VCase[>..<] = [];
    let bbdef = get_vec_cases(ti, bbcases);
    var pcases: VCase[>..<] = [];
    var pdef = get_vec_cases(pti, pcases);
    // NewSuccessors: SmallMapVector<BasicBlock*, int>
    var ns_b: i32[>..<] = [];
    var ns_n: i64[>..<] = [];
    fn ns_inc(b: i32) {
        let j = position(ns_b, b);
        if j < 0 { ns_b.push(b); ns_n.push(1); } else { ns_n[j] += 1; }
    }
    var ws: u64[>..<] = [];
    var pred_hw = pd_has_branch_weights(pti);
    var succ_hw = pd_has_branch_weights(ti);
    if pred_hw {
        get_branch_weights_def_first(pti, ws);
        if ws.len != 1 + pcases.len { pred_hw = false; succ_hw = false; }
    } else if succ_hw {
        ws.clear();
        for k in 1 + pcases.len { ws.push(1); }
    }
    var sws: u64[>..<] = [];
    if succ_hw {
        get_branch_weights_def_first(ti, sws);
        if sws.len != 1 + bbcases.len { pred_hw = false; succ_hw = false; }
    } else if pred_hw {
        sws.clear();
        for k in 1 + bbcases.len { sws.push(1); }
    }
    if pdef == bb {
        var handled: i32[>..<] = [];
        var i: i64 = 0;
        var e = pcases.len;
        while i < e {
            if pcases[i].d != bb { handled.push(pcases[i].v); i++; continue; }
            let last = pcases.len - 1;
            let tmp = pcases[i]; pcases[i] = pcases[last]; pcases[last] = tmp;
            if pred_hw || succ_hw {
                ws[0] += ws[i + 1];
                let wl = ws.len - 1;
                let t2 = ws[i + 1]; ws[i + 1] = ws[wl]; ws[wl] = t2;
                ws.resize(wl);
            }
            pcases.resize(last);
            e--;
        }
        if pdef != bbdef {
            block_remove_predecessor(pdef, pred, false);
            if cu_dtu && pdef != bb { cu_upd(ups, DT_DELETE, pred, pdef); }
            pdef = bbdef;
            ns_inc(bbdef);
        }
        let cases_from_pred = ws.len;
        var valid_total: u64 = 0;
        for j in bbcases.len {
            if position(handled, bbcases[j].v) < 0 && bbcases[j].d != bbdef {
                pcases.push(bbcases[j]);
                ns_inc(bbcases[j].d);
                if succ_hw || pred_hw {
                    ws.push(ws[0] * sws[j + 1]);
                    valid_total += sws[j + 1];
                }
            }
        }
        if succ_hw || pred_hw {
            valid_total += sws[0];
            for j in 1..cases_from_pred { ws[j] *= valid_total; }
            ws[0] *= sws[0];
        }
    } else {
        // PTIHandled as a std::set ordered by unsigned value; WeightsForHandled keyed by the constant
        var handled: i32[>..<] = [];
        var hw_k: i32[>..<] = [];
        var hw_w: u64[>..<] = [];
        var i: i64 = 0;
        var e = pcases.len;
        while i < e {
            if pcases[i].d != bb { i++; continue; }
            handled.push(pcases[i].v);
            if pred_hw || succ_hw {
                hw_k.push(pcases[i].v);
                hw_w.push(ws[i + 1]);
                let wl = ws.len - 1;
                let t2 = ws[i + 1]; ws[i + 1] = ws[wl]; ws[wl] = t2;
                ws.resize(wl);
            }
            let last = pcases.len - 1;
            let tmp = pcases[i]; pcases[i] = pcases[last]; pcases[last] = tmp;
            pcases.resize(last);
            e--;
        }
        fn hw_get(c: i32) -> u64 { let j = position(hw_k, c); return if j < 0 { 0 } else { hw_w[j] }; }
        for c in bbcases {
            let j = position(handled, c.v);
            if j >= 0 {
                if pred_hw || succ_hw { ws.push(hw_get(c.v)); }
                pcases.push(c);
                ns_inc(c.d);
                handled.remove_at(j);
            }
        }
        // remaining PTIHandled in ascending unsigned order
        sort(handled) { a, b => ap_ult(ci_ap(a), ci_ap(b)) };
        for h in handled {
            if pred_hw || succ_hw { ws.push(hw_get(h)); }
            pcases.push(VCase { v: h, d: bbdef });
            ns_inc(bbdef);
        }
    }
    var succs_of_pred: i32[>..<] = [];
    if cu_dtu { cu_succs(pred, succs_of_pred); }
    for j in ns_b.len {
        for x in ns_n[j] { add_predecessor_to_block(ns_b[j], pred, bb); }
        if cu_dtu && position(succs_of_pred, ns_b[j]) < 0 { cu_upd(ups, DT_INSERT, pred, ns_b[j]); }
    }
    sb_at(pti);
    if ty_kind(vals[cv].ty) == TK_PTR {
        let ity = ty_int(dl_ptr(ptr_as(vals[cv].ty)).bits);
        cv = sb_cast(OP_PTRTOINT, cv, ity, "magicptr");
    }
    let nsi = sb_switch(cv, pdef, pcases.len);
    let pdl = inst_get_md(pti, MDK_DBG_SC);
    if pdl >= 0 { inst_set_md(nsi, MDK_DBG_SC, pdl); } else { inst_erase_md(nsi, MDK_DBG_SC); }
    for c in pcases { sw_add_case_raw(nsi, c.v, c.d); }
    if pred_hw || succ_hw { pd_set_fitted(nsi, ws, false, true); }
    erase_terminator_and_dce_cond(pti);
    var inf: i32 = -1;
    for k in term_nsucc(nsi) {
        if term_succ(nsi, k) == bb {
            if inf < 0 {
                inf = create_block_after(block_func(bb), -1, "infloop");
                block_append_inst(inf, create_inst(OP_BR, T_VOID, [inf]));
                if cu_dtu { cu_upd(ups, DT_INSERT, inf, inf); }
            }
            term_set_succ(nsi, k, inf);
        }
    }
    if cu_dtu {
        if inf >= 0 { cu_upd(ups, DT_INSERT, pred, inf); }
        cu_upd(ups, DT_DELETE, pred, bb);
        dtu_apply_updates(ups);
    }
    return true;
}

// foldValueComparisonIntoPredecessors
fn fold_value_cmp_into_preds(ti: i32) -> bool {
    let bb = inst_parent(ti);
    let cv = is_value_equality_comparison(ti);
    var changed = false;
    var preds: i32[>..<] = [];
    each_pred(bb) { p => cu_push_unique(preds, p); };
    while preds.len > 0 {
        let pred = preds.pop();
        let pti = block_terminator(pred);
        if pred == bb { continue; }
        let pcv = is_value_equality_comparison(pti);
        if pcv != cv { continue; }
        var fail: i32[>..<] = [];
        if !safe_to_merge_terminators(ti, pti, fail, true) {
            for s in fail {
                let one: i32[1] = [inst_parent(ti)];
                if cu_split_block_predecessors(s, one, ".fold.split") < 0 { return false; }
            }
        }
        perform_value_cmp_into_pred_folding(ti, cv, pti);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Hoisting (hoistCommonCodeFromSuccessors and friends)

// isSafeToHoistInvoke
fn is_safe_to_hoist_invoke(bb1: i32, bb2: i32, i1: i32, i2: i32) -> bool {
    var succs: i32[>..<] = [];
    cu_succs(bb1, succs);
    for s in succs {
        var p = block_first(s);
        while p >= 0 && iop(p) == OP_PHI {
            let v1 = phi_value_for_block(p, bb1);
            let v2 = phi_value_for_block(p, bb2);
            if v1 != v2 && (v1 == i1 || v2 == i2) { return false; }
            p = inst_next(p);
        }
    }
    return true;
}

let SKIP_READ_MEM = 1;
let SKIP_SIDE_EFFECT = 2;
let SKIP_IMPLICIT_CF = 4;

fn skipped_instr_flags(i: i32) -> i64 {
    if inst_iid(i) == IID_pseudoprobe { return 0; }
    var f: i64 = 0;
    if inst_may_read_memory(i) { f |= SKIP_READ_MEM; }
    if inst_may_have_side_effects(i) || iop(i) == OP_ALLOCA { f |= SKIP_SIDE_EFFECT; }
    if !guaranteed_to_transfer(i) { f |= SKIP_IMPLICIT_CF; }
    return f;
}

fn is_safe_to_hoist_instr(i: i32, flags: i64) -> bool {
    if (flags & SKIP_READ_MEM) != 0 && inst_may_write_memory(i) { return false; }
    if (flags & SKIP_SIDE_EFFECT) != 0 && (inst_may_read_memory(i) || inst_may_have_side_effects(i) || iop(i) == OP_ALLOCA) { return false; }
    if (flags & SKIP_IMPLICIT_CF) != 0 && !spec_safe(i, -1, false) { return false; }
    if is_callbase(i) && inst_iid(i) == IID_experimental_deoptimize { return false; }
    let bb = inst_parent(i);
    for k in nops(i) {
        let j = op(i, k);
        if is_inst(j) && inst_parent(j) == bb { return false; }
    }
    return true;
}

// CallBase::cannotMerge / isConvergent / cannotDuplicate
fn cb_cannot_merge(c: i32) -> bool { call_has_fn_attr(c, AK_NoMerge) }
fn cb_is_convergent(c: i32) -> bool { call_has_fn_attr(c, AK_Convergent) }
fn cb_cannot_duplicate(c: i32) -> bool { call_has_fn_attr(c, AK_NoDuplicate) }
fn is_musttail(c: i32) -> bool { iop(c) == OP_CALL && insts[inst_of(c)].pred == 2 }

fn should_hoist_common_instructions(i1: i32, i2: i32) -> bool {
    if iop(i1) == OP_CALL && iop(i2) == OP_CALL && is_musttail(i1) != is_musttail(i2) { return false; }
    if !tti_is_profitable_to_hoist(i1) || !tti_is_profitable_to_hoist(i2) { return false; }
    if is_callbase(i1) && (cb_cannot_merge(i1) || cb_is_convergent(i1)) { return false; }
    if is_callbase(i2) && (cb_cannot_merge(i2) || cb_is_convergent(i2)) { return false; }
    return true;
}

// Instruction::isCommutative
fn is_commutative_inst(i: i32) -> bool {
    let o = iop(i);
    if o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL { return true; }
    if o == OP_CALL {
        let id = inst_iid(i);
        if id == 0 { return false; }
        return intr_is_commutative(id);
    }
    return false;
}
fn intr_is_commutative(id: i32) -> bool {
    return id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin || id == IID_sadd_sat ||
           id == IID_uadd_sat || id == IID_sadd_with_overflow || id == IID_uadd_with_overflow ||
           id == IID_smul_with_overflow || id == IID_umul_with_overflow || id == IID_smul_fix ||
           id == IID_umul_fix || id == IID_smul_fix_sat || id == IID_umul_fix_sat || id == IID_fma ||
           id == IID_fmuladd || id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum ||
           id == IID_maximumnum || id == IID_minimumnum;
}
fn swapped_pred(p: i64) -> i64 {
    if p <= 15 {
        // FCMP: swap the lt/gt roles (FCmpInst::getSwappedPredicate)
        return match p { 2 => 4, 3 => 5, 4 => 2, 5 => 3, 10 => 12, 11 => 13, 12 => 10, 13 => 11, _ => p };
    }
    return pred_swap_i(p);
}

fn are_identical_up_to_commutativity(i1: i32, i2: i32) -> bool {
    if cu_identical_when_defined(i1, i2, true) { return true; }
    let o1 = iop(i1);
    if (o1 == OP_ICMP || o1 == OP_FCMP) && (iop(i2) == OP_ICMP || iop(i2) == OP_FCMP) {
        return inst_pred(i1) == swapped_pred(inst_pred(i2)) && op(i1, 0) == op(i2, 1) && op(i1, 1) == op(i2, 0);
    }
    if is_commutative_inst(i1) && cu_same_operation_as(i1, i2, 0) {
        if !(op(i1, 0) == op(i2, 1) && op(i1, 1) == op(i2, 0)) { return false; }
        for k in 2..nops(i1) { if op(i1, k) != op(i2, k) { return false; } }
        return true;
    }
    return false;
}

fn mmra_md(i: i32) -> i32 { inst_get_md(i, md_kind_id("mmra")) }

// Instruction::andIRFlags(V): intersect the poison-generating and fast-math flags
fn and_ir_flags(a: i32, b: i32) {
    let ia = inst_of(a);
    let ib = inst_of(b);
    insts[ia].flags = insts[ia].flags & insts[ib].flags;
    if is_fp_math_operator(a) && is_fp_math_operator(b) { insts[ia].fmf = insts[ia].fmf & insts[ib].fmf; }
}

// combineMetadataForCSE(K, J, DoesKMove)
fn combine_metadata_for_cse(k: i32, j: i32, moves: bool) { cu_combine_metadata(k, j, moves, false); }

// Instruction::applyMergedLocation(A, B)
fn apply_merged_location(i: i32, a: i32, b: i32) {
    let m = merged_location(a, b);
    if m >= 0 { inst_set_md(i, MDK_DBG_SC, m); } else { inst_erase_md(i, MDK_DBG_SC); }
}
// DILocation::getMergedLocation(A, B)
fn merged_location(a: i32, b: i32) -> i32 {
    return m2r_merged_location(a, b);
}

// hoistLockstepIdenticalDbgVariableRecords
fn hoist_lockstep_dbg_records(ti: i32, i1: i32, others: const i32[:]) {
    if inst_first_dbg(i1) < 0 { return; }
    for o in others { if inst_first_dbg(o) < 0 { return; } }
    scf_not_ported("hoisting debug records");
}

// CallBase::tryIntersectAttributes
fn try_intersect_attributes(a: i32, b: i32) {
    if insts[inst_of(a)].attrs == insts[inst_of(b)].attrs { return; }
    let r, ok = cu_alist_intersect(insts[inst_of(a)].attrs, insts[inst_of(b)].attrs);
    insts[inst_of(a)].attrs = r;
}

// LockstepReverseIterator<true> over blocks: the instructions before the terminator, from the end;
// skips debug/pseudo-probe intrinsics. lri_cur holds one instruction per block (-1 = exhausted).
var lri_blocks: i32[>..<];
var lri_cur: i32[>..<];
var lri_valid: bool = false;

fn lri_reset() {
    lri_cur.clear();
    lri_valid = true;
    for b in lri_blocks {
        let t = block_terminator(b);
        let p = inst_prev(t);
        if p < 0 { lri_valid = false; return; }
        lri_cur.push(p);
    }
    if lri_cur.len == 0 { lri_valid = false; }
}
fn lri_init(bbs: const i32[:]) {
    lri_blocks.clear();
    for b in bbs { lri_blocks.push(b); }
    lri_reset();
}
// operator--: the previous instruction in every block
fn lri_dec() {
    if !lri_valid { return; }
    for k in lri_cur.len {
        let p = inst_prev(lri_cur[k]);
        if p < 0 { lri_valid = false; return; }
    }
    for k in lri_cur.len { lri_cur[k] = inst_prev(lri_cur[k]); }
}
// operator++: the next instruction in every block
fn lri_inc() {
    if !lri_valid { return; }
    for k in lri_cur.len {
        let n = inst_next(lri_cur[k]);
        if n < 0 { lri_valid = false; return; }
    }
    for k in lri_cur.len { lri_cur[k] = inst_next(lri_cur[k]); }
}

// hoistCommonCodeFromSuccessors(TI, AllInstsEqOnly)
fn hoist_common_code_from_successors(ti: i32, all_eq_only: bool) -> bool {
    let bb = inst_parent(ti);
    if block_nsucc(bb) < 2 { return false; }
    var usucc: i32[>..<] = [];
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs { cu_push_unique(usucc, s); }
    for s in usucc {
        if cu_has_address_taken(s) { return false; }
        if cu_unique_pred(s) >= 0 { continue; }
        if iop(block_first(s)) == OP_UNREACHABLE { continue; }
        return false;
    }
    var it: i32[>..<] = [];     // SuccIterPairs: iterator
    var fl: i64[>..<] = [];     // skip flags
    for s in usucc {
        let f = block_first(s);
        if iop(f) == OP_PHI { return false; }
        it.push(f);
        fl.push(0);
    }
    if all_eq_only {
        let size0 = cu_block_size(usucc[0]);
        let term0 = block_terminator(usucc[0]);
        for k in 1..usucc.len {
            if !cu_identical(block_terminator(usucc[k]), term0) || cu_block_size(usucc[k]) != size0 { return false; }
        }
        lri_init(usucc);
        while lri_valid {
            let i0 = lri_cur[0];
            for x in lri_cur { if !are_identical_up_to_commutativity(i0, x) { return false; } }
            lri_dec();
        }
    }
    var num_skipped: i64 = 0;
    if it.len > 2 {
        var w = 0;
        for k in it.len { if iop(it[k]) != OP_UNREACHABLE { it[w] = it[k]; fl[w] = fl[k]; w++; } }
        it.resize(w);
        fl.resize(w);
        if it.len < 2 { return false; }
    }
    var changed = false;
    loop {
        let i1 = it[0];
        var all_identical = true;
        var has_term = is_terminator(i1);
        for k in 1..it.len {
            let i2 = it[k];
            if is_terminator(i2) { has_term = true; }
            if all_identical && (!are_identical_up_to_commutativity(i1, i2) || mmra_md(i1) != mmra_md(i2)) { all_identical = false; }
        }
        var others: i32[>..<] = [];
        for k in 1..it.len { others.push(it[k]); }
        if has_term {
            if num_skipped > 0 || !all_identical {
                hoist_lockstep_dbg_records(ti, i1, others);
                return changed;
            }
            return hoist_succ_identical_terminator(ti, i1, others, usucc) || changed;
        }
        if all_identical {
            let f1 = fl[0];
            all_identical = is_safe_to_hoist_instr(i1, f1);
            if all_identical {
                for k in 1..it.len {
                    if !(is_safe_to_hoist_instr(it[k], fl[k]) && should_hoist_common_instructions(i1, it[k])) { all_identical = false; break; }
                }
            }
        }
        if all_identical && iop(i1) == OP_CALL && is_musttail(i1) {
            var ok = num_skipped == 0;
            if ok { for x in it { let n = inst_next(x); if n < 0 || iop(n) != OP_RET { ok = false; } } }
            all_identical = ok;
        }
        if all_identical {
            it[0] = inst_next(it[0]);
            hoist_lockstep_dbg_records(ti, i1, others);
            if inst_first_dbg(i1) >= 0 { scf_not_ported("hoisting instructions with debug records"); }
            inst_move_before(i1, ti);
            for k in 1..it.len {
                let i2 = it[k];
                it[k] = inst_next(i2);
                if vals[i2].first_use >= 0 { rauw(i2, i1); }
                and_ir_flags(i1, i2);
                if is_callbase(i1) { try_intersect_attributes(i1, i2); }
                combine_metadata_for_cse(i1, i2, true);
                apply_merged_location(i1, inst_get_md(i1, MDK_DBG_SC), inst_get_md(i2, MDK_DBG_SC));
                if inst_first_dbg(i2) >= 0 { scf_not_ported("erasing hoisted duplicates with debug records"); }
                scf_erase(i2);
            }
            changed = true;
        } else {
            if num_skipped >= cl_hoist_skip_limit {
                hoist_lockstep_dbg_records(ti, i1, others);
                return changed;
            }
            for k in it.len {
                let x = it[k];
                it[k] = inst_next(x);
                fl[k] = fl[k] | skipped_instr_flags(x);
            }
            num_skipped++;
        }
    }
    return changed;
}

// hoistSuccIdenticalTerminatorToSwitchOrIf
fn hoist_succ_identical_terminator(ti: i32, i1: i32, others: const i32[:], usucc: const i32[:]) -> bool {
    let is_br = iop(ti) == OP_CONDBR;
    let tip = inst_parent(ti);
    let bb1 = inst_parent(i1);
    let i2 = others[0];
    let bb2 = inst_parent(i2);
    if iop(i1) == OP_INVOKE && (!is_br || !is_safe_to_hoist_invoke(bb1, bb2, i1, i2)) { return false; }
    if iop(i1) == OP_CALLBR { return false; }
    var s1: i32[>..<] = [];
    cu_succs(bb1, s1);
    for s in s1 {
        var p = block_first(s);
        while p >= 0 && iop(p) == OP_PHI {
            let v1 = phi_value_for_block(p, bb1);
            for o in others {
                let v2 = phi_value_for_block(p, inst_parent(o));
                if v1 == v2 { continue; }
                if !is_br || passing_value_is_always_undefined(v1, p, false) || passing_value_is_always_undefined(v2, p, false) { return false; }
            }
            p = inst_next(p);
        }
    }
    hoist_lockstep_dbg_records(ti, i1, others);
    let nt = inst_clone(i1);
    inst_insert_before(nt, ti);
    if vals[nt].ty != T_VOID {
        rauw(i1, nt);
        for o in others { rauw(o, nt); }
        cu_take_name(nt, i1);
    }
    // getMergedLocations(I1 and the others)
    var loc = inst_get_md(i1, MDK_DBG_SC);
    for o in others { loc = merged_location(loc, inst_get_md(o, MDK_DBG_SC)); }
    if loc >= 0 { inst_set_md(nt, MDK_DBG_SC, loc); } else { inst_erase_md(nt, MDK_DBG_SC); }
    sb_at_nofold(nt);
    if is_br {
        // InsertedSelects: map (BB1V, BB2V) -> select
        var sel_a: i32[>..<] = [];
        var sel_b: i32[>..<] = [];
        var sel_s: i32[>..<] = [];
        for s in s1 {
            var p = block_first(s);
            while p >= 0 && iop(p) == OP_PHI {
                let v1 = phi_value_for_block(p, bb1);
                let v2 = phi_value_for_block(p, bb2);
                if v1 != v2 {
                    var si: i32 = -1;
                    for k in sel_a.len { if sel_a[k] == v1 && sel_b[k] == v2 { si = sel_s[k]; } }
                    if si < 0 {
                        var nm: u8[>..] = [];
                        nm.append(val_name(v1));
                        nm.append(".");
                        nm.append(val_name(v2));
                        si = sb_select_fmf(br_cond(ti), v1, v2, if is_fp_math_operator(p) { p } else { -1 }, nm, ti);
                        sel_a.push(v1); sel_b.push(v2); sel_s.push(si);
                    }
                    for k in nops(p) {
                        let ib = phi_block(p, k);
                        if ib == bb1 || ib == bb2 { set_op(p, k, si); }
                    }
                }
                p = inst_next(p);
            }
        }
    }
    var ups: DTUpdate[>..<] = [];
    for s in s1 {
        add_predecessor_to_block(s, tip, bb1);
        if cu_dtu { cu_upd(ups, DT_INSERT, tip, s); }
    }
    if cu_dtu { for s in usucc { cu_upd(ups, DT_DELETE, tip, s); } }
    erase_terminator_and_dce_cond(ti);
    cu_apply(ups);
    return true;
}

// ---------------------------------------------------------------------------------------------
// isSafeToSpeculateStore / validateAndCostRequiredSelects / isProfitableToSpeculate / speculativelyExecuteBB

fn store_is_simple(s: i32) -> bool { !inst_is_volatile(s) && insts[inst_of(s)].ord == 0 }
fn inst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }

fn is_safe_to_speculate_store(i: i32, brbb: i32, storebb: i32, endbb: i32) -> i32 {
    if iop(i) != OP_STORE { return -1; }
    if !store_is_simple(i) { return -1; }
    let sp = op(i, 1);
    let sty = vals[op(i, 0)].ty;
    var max_look = 9;
    var cur = block_last(brbb);
    while cur >= 0 {
        if max_look == 0 { break; }
        max_look--;
        let c = cur;
        cur = inst_prev(cur);
        if inst_iid(c) == IID_pseudoprobe { continue; }
        if inst_may_write_memory(c) && iop(c) != OP_STORE { return -1; }
        if iop(c) == OP_STORE {
            if op(c, 1) == sp && vals[op(c, 0)].ty == sty && store_is_simple(c) && inst_align(c) >= inst_align(i) { return op(c, 0); }
            return -1;
        }
        if iop(c) == OP_LOAD {
            if op(c, 0) == sp && vals[c].ty == sty && store_is_simple(c) && inst_align(c) >= inst_align(i) {
                scf_not_ported("isSafeToSpeculateStore from a preceding load (isWritableObject / capture tracking)");
            }
        }
    }
    return -1;
}

fn validate_and_cost_required_selects(bb: i32, thenbb: i32, endbb: i32, spec: i64&, cost: i64&) -> bool {
    let ck = scf_cost_kind(bb);
    var rewritable = false;
    var p = block_first(endbb);
    while p >= 0 && iop(p) == OP_PHI {
        let pn = p;
        p = inst_next(p);
        let ov = phi_value_for_block(pn, bb);
        let tv = phi_value_for_block(pn, thenbb);
        if tv == ov { continue; }
        cost = tc_add(cost, tti_cmpsel_cost(OP_SELECT, vals[pn].ty, cmp_result_ty(vals[pn].ty), -1, ck));
        if passing_value_is_always_undefined(ov, pn, false) || passing_value_is_always_undefined(tv, pn, false) { return false; }
        rewritable = true;
        let oce = vals[ov].kind == VK_CEXPR;
        let tce = vals[tv].kind == VK_CEXPR;
        if !oce && !tce { continue; }
        let oc = if oce { scf_spec_cost(ov) } else { 0 };
        let tc = if tce { scf_spec_cost(tv) } else { 0 };
        let maxc = 2 * cl_phi_fold_threshold * TCC_BASIC;
        if tc_add(oc, tc) > maxc { return false; }
        spec++;
        if spec > 1 { return false; }
    }
    return rewritable;
}

// isProfitableToSpeculate(BI, Invert, TTI); invert: -1 none, 0 false, 1 true
fn is_profitable_to_speculate(bi: i32, invert: i64) -> bool {
    if inst_get_md(bi, mdk_unpredictable()) >= 0 { return true; }
    let ok, tw, fw = pd_extract2(bi);
    if !ok || tw + fw == 0 { return true; }
    if invert < 0 { return false; }
    let endw = if invert == 1 { tw } else { fw };
    let prob = bp_get(endw, tw + fw);
    return prob < tti_predictable_branch_threshold();
}

// EphemeralValueTracker::track(I): I is ephemeral if it only feeds assumes or other ephemeral values
var eph_set: i32[>..<];
fn eph_track(i: i32) -> bool {
    var eph = inst_iid(i) == IID_assume;
    if !eph {
        // all users are ephemeral (vacuously true without users) and I has no side effects / isn't a terminator
        if !inst_may_have_side_effects(i) && !is_terminator(i) {
            var u = first_use(i);
            var all = true;
            while u >= 0 { if position(eph_set, uses[u].user) < 0 { all = false; } u = use_next(u); }
            eph = all;
        }
    }
    if eph { eph_set.push(i); }
    return eph;
}

fn speculatively_execute_bb(bi: i32, thenbb: i32) -> bool {
    if !so.spec_blocks { return false; }
    let brcond = br_cond(bi);
    if is_inst(brcond) && iop(brcond) == OP_FCMP { return false; }
    let bb = inst_parent(bi);
    let endbb = term_succ(block_terminator(thenbb), 0);
    let budget = cl_phi_fold_threshold * TCC_BASIC;
    var invert = false;
    if thenbb != br_succ(bi, 0) { invert = true; }
    if !is_profitable_to_speculate(bi, if invert { 1 } else { 0 }) { return false; }
    var sink_i: i32[>..<] = [];
    var sink_n: i64[>..<] = [];
    var probes: i32[>..<] = [];
    var spec: i64 = 0;
    let hoist_ldst = so.hoist_ldst_cf;
    var cond_ldst: i32[>..<] = [];
    var spec_store_val: i32 = -1;
    var spec_store: i32 = -1;
    eph_set.clear();
    var i = inst_prev(block_terminator(thenbb));
    while i >= 0 {
        let cur = i;
        i = inst_prev(i);
        if inst_iid(cur) == IID_pseudoprobe { probes.push(cur); continue; }
        if eph_track(cur) { continue; }
        let safe_cheap_ldst = hoist_ldst && is_safe_cheap_load_store(cur) && cond_ldst.len < cl_hoist_ldst_cf_threshold;
        if safe_cheap_ldst { cond_ldst.push(cur); } else { spec++; }
        if spec > 1 { return false; }
        if !safe_cheap_ldst && !spec_safe(cur, bi, true) {
            var ok = false;
            if cl_hoist_cond_stores && spec_store_val < 0 {
                spec_store_val = is_safe_to_speculate_store(cur, bb, thenbb, endbb);
                ok = spec_store_val >= 0;
            }
            if !ok { return false; }
        }
        if !safe_cheap_ldst && spec_store_val < 0 && scf_spec_cost(cur) > cl_phi_fold_threshold * TCC_BASIC { return false; }
        if spec_store < 0 && spec_store_val >= 0 { spec_store = cur; }
        for k in nops(cur) {
            let o = op(cur, k);
            if !is_inst(o) || inst_parent(o) != bb || inst_may_have_side_effects(o) { continue; }
            let j = position(sink_i, o);
            if j < 0 { sink_i.push(o); sink_n.push(1); } else { sink_n[j] += 1; }
        }
    }
    for k in sink_i.len {
        if has_n_uses(sink_i[k], sink_n[k]) {
            spec++;
            if spec > 1 { return false; }
        }
    }
    var convert = spec_store >= 0 || cond_ldst.len > 0;
    var cost: i64 = 0;
    if validate_and_cost_required_selects(bb, thenbb, endbb, spec, cost) { convert = true; }
    if !convert || cost > budget { return false; }
    var sel: i32 = -1;
    if spec_store_val >= 0 {
        sb_at_nofold(bi);
        var tv = op(spec_store, 0);
        var fv = spec_store_val;
        if invert { let t = tv; tv = fv; fv = t; }
        let s = sb_select(brcond, tv, fv, "spec.store.select", bi);
        sel = s;
        set_op(spec_store, 0, s);
        apply_merged_location(spec_store, inst_get_md(bi, MDK_DBG_SC), inst_get_md(spec_store, MDK_DBG_SC));
    }
    var x = block_first(thenbb);
    while x >= 0 {
        let nx = inst_next(x);
        if spec_store_val < 0 || x != spec_store { scf_drop_location(x); }
        cu_drop_ub_implying_attrs_and_metadata(x);
        if position(eph_set, x) >= 0 {
            rauw(x, c_poison(vals[x].ty));
            scf_erase(x);
        }
        x = nx;
    }
    x = block_first(thenbb);
    while x >= 0 {
        if inst_first_dbg(x) >= 0 { scf_not_ported("dropping debug records of speculated instructions"); }
        x = inst_next(x);
    }
    cu_splice_before(bi, block_first(thenbb), block_terminator(thenbb));
    if cond_ldst.len > 0 { scf_not_ported("hoisting conditional loads/stores (conditional faulting)"); }
    sb_at_nofold(bi);
    var p = block_first(endbb);
    while p >= 0 && iop(p) == OP_PHI {
        let pn = p;
        p = inst_next(p);
        let oi = phi_block_index(pn, bb);
        let tix = phi_block_index(pn, thenbb);
        let ov = phi_value(pn, oi);
        let tv = phi_value(pn, tix);
        if ov == tv { continue; }
        var t = tv;
        var f = ov;
        if invert { let tmp = t; t = f; f = tmp; }
        let v = sb_select(brcond, t, f, "spec.select", bi);
        set_op(pn, oi, v);
        set_op(pn, tix, v);
    }
    for pr in probes { scf_erase(pr); }
    return true;
}

// isSafeCheapLoadStore
fn is_safe_cheap_load_store(i: i32) -> bool {
    var is_store = false;
    if iop(i) == OP_LOAD {
        if !store_is_simple(i) || !cl_hoist_loads_cf { return false; }
    } else if iop(i) == OP_STORE {
        if !store_is_simple(i) || !cl_hoist_stores_cf { return false; }
        is_store = true;
    } else { return false; }
    let t = if is_store { vals[op(i, 0)].ty } else { vals[i].ty };
    return tti_has_conditional_load_store_for_type(t, is_store) && inst_align(i) < 4294967296;
}

// ---------------------------------------------------------------------------------------------
// Threading (foldCondBranchOnValueKnownInPredecessor)

fn find_reaching(bb: i32, defbb: i32, reaches: i32[>..<]&) -> bool { find_reaching_rec(bb, defbb, reaches) }
recursive fn find_reaching_rec(bb: i32, defbb: i32, reaches: i32[>..<]&) -> bool {
    if bb == defbb { return true; }
    if !cu_push_unique(reaches, bb) { return true; }
    if reaches.len > cl_max_jt_live_blocks { return false; }
    var u = first_use(bb);
    while u >= 0 {
        let us = uses[u].user;
        let nu = use_next(u);
        if vals[us].kind == VK_INST && is_terminator_op(iop(us)) {
            if !find_reaching_rec(inst_parent(us), defbb, reaches) { return false; }
        }
        u = nu;
    }
    return true;
}

fn block_simple_enough_to_thread(bb: i32, nonlocal: i32[>..<]&) -> bool {
    var size: i64 = 0;
    eph_set.clear();
    var i = block_last(bb);
    while i >= 0 {
        let cur = i;
        i = inst_prev(i);
        if iop(cur) == OP_CALL && (cb_cannot_duplicate(cur) || cb_is_convergent(cur)) { return false; }
        if !eph_track(cur) && iop(cur) != OP_PHI {
            if size > cl_max_small_block { return false; }
            size++;
        }
        var u = first_use(cur);
        while u >= 0 {
            let ui = uses[u].user;
            let ub = inst_parent(ui);
            if ub == bb {
                if iop(ui) == OP_PHI { return false; }
            } else { cu_push_unique(nonlocal, ub); }
            u = use_next(u);
        }
    }
    return true;
}

fn get_known_value_on_edge(v: i32, from: i32, to: i32) -> i32 {
    if is_inst(v) && inst_parent(v) == to { return -1; }
    let bi = block_terminator(from);
    if iop(bi) == OP_CONDBR && br_cond(bi) == v && br_succ(bi, 0) != br_succ(bi, 1) {
        return if br_succ(bi, 0) == to { scf_true() } else { scf_false() };
    }
    return -1;
}

// returns 0 = false, 1 = true, 2 = std::nullopt (changed, repeat)
fn fold_cond_branch_known_in_pred_impl(bi: i32) -> i64 {
    var kv_c: i32[>..<] = [];        // SmallMapVector<ConstantInt*, SmallSetVector<BasicBlock*>>
    var kv_at: i64[>..<] = [];
    var kv_blocks: i32[>..<] = [];   // (const index, block) pairs flattened
    fn kv_add(c: i32, b: i32) {
        var j = position(kv_c, c);
        if j < 0 { kv_c.push(c); j = kv_c.len - 1; }
        for k in 0..(kv_blocks.len / 2) { if kv_blocks[2 * k] == j as i32 && kv_blocks[2 * k + 1] == b { return; } }
        kv_blocks.push(j as i32);
        kv_blocks.push(b);
    }
    let bb = inst_parent(bi);
    let cond = br_cond(bi);
    if is_inst(cond) && iop(cond) == OP_PHI && inst_parent(cond) == bb {
        if nops(cond) == 1 { cu_fold_single_entry_phis(bb); return 1; }
        for k in nops(cond) {
            let v = phi_value(cond, k);
            if vals[v].kind == VK_CINT { kv_add(v, phi_block(cond, k)); }
        }
    } else {
        var preds: i32[>..<] = [];
        cu_preds(bb, preds);
        for p in preds {
            let c = get_known_value_on_edge(cond, p, bb);
            if c >= 0 { kv_add(c, p); }
        }
    }
    if kv_c.len == 0 { return 0; }
    var nonlocal: i32[>..<] = [];
    var reaches: i32[>..<] = [];
    if !block_simple_enough_to_thread(bb, nonlocal) { return 0; }
    if position(nonlocal, br_succ(bi, 0)) >= 0 && position(nonlocal, br_succ(bi, 1)) >= 0 { return 0; }
    for ub in nonlocal { if !find_reaching(ub, bb, reaches) { return 0; } }
    for j in kv_c.len {
        let cb = kv_c[j];
        var pbs: i32[>..<] = [];
        for k in 0..(kv_blocks.len / 2) { if kv_blocks[2 * k] == j as i32 { pbs.push(kv_blocks[2 * k + 1]); } }
        let real = br_succ(bi, if cint_is_zero(cb) { 1 } else { 0 });
        if real == bb { continue; }
        var any_ibr = false;
        for p in pbs { if iop(block_terminator(p)) == OP_INDIRECTBR { any_ibr = true; } }
        if any_ibr { continue; }
        if position(reaches, real) >= 0 { continue; }
        let edge = cu_split_block_predecessors(bb, pbs, ".critedge");
        if edge < 0 { continue; }
        let nm = name_plus(real, ".critedge");
        set_name(edge, nm);
        block_move_before(edge, real);
        add_predecessor_to_block(real, edge, bb);
        var ins_pt = first_non_phi(edge);
        var tmap: i32[>..<] = [];
        tmap.push(cond);
        tmap.push(cb);
        var bbi = block_first(bb);
        while bbi != bi {
            let cur = bbi;
            bbi = inst_next(bbi);
            if iop(cur) == OP_PHI {
                tmap.push(cur);
                tmap.push(phi_value_for_block(cur, edge));
                continue;
            }
            var n = inst_clone(cur);
            inst_insert_before(n, ins_pt);
            if vals[cur].name >= 0 {
                let cn = name_plus(cur, ".c");
                set_name(n, cn);
            }
            let cdl = inst_get_md(cur, MDK_DBG_SC);
            if cdl >= 0 { scf_map_atom_instance(cdl); }
            scf_remap_instruction(n, tmap);
            let v = scf_simplify_with_ac(n);
            if v >= 0 {
                if vals[cur].first_use >= 0 { tmap.push(cur); tmap.push(v); }
                if !inst_may_have_side_effects(n) { scf_erase(n); n = -1; }
            } else {
                if vals[cur].first_use >= 0 { tmap.push(cur); tmap.push(n); }
            }
            if n >= 0 && inst_first_dbg(cur) >= 0 { scf_not_ported("cloning debug records while threading"); }
        }
        var y = block_first(bb);
        while y >= 0 { if inst_first_dbg(y) >= 0 { scf_not_ported("cloning debug records while threading"); } y = inst_next(y); }
        block_remove_predecessor(bb, edge, false);
        let ebi = block_terminator(edge);
        set_op(ebi, 0, real);
        let bdl = inst_get_md(bi, MDK_DBG_SC);
        if bdl >= 0 { inst_set_md(ebi, MDK_DBG_SC, bdl); } else { inst_erase_md(ebi, MDK_DBG_SC); }
        if cu_dtu {
            var ups: DTUpdate[>..<] = [];
            cu_upd(ups, DT_DELETE, edge, bb);
            cu_upd(ups, DT_INSERT, edge, real);
            dtu_apply_updates(ups);
        }
        cu_merge_block_into_predecessor(edge);
        ins_pt = -1;
        return 2;
    }
    return 0;
}

fn fold_cond_branch_on_value_known_in_pred(bi: i32) -> bool {
    if so.keep_loops && scf_is_loop_header(inst_parent(bi)) { return false; }
    var ever = false;
    loop {
        let r = fold_cond_branch_known_in_pred_impl(bi);
        if r != 0 { ever = true; }
        if r != 2 { break; }
    }
    return ever;
}

// simplifyInstruction(I, {DL, nullptr, nullptr, AC})
fn scf_simplify_with_ac(i: i32) -> i32 {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    sq_no_dt = true; sq_no_ac = false; sq_no_tli = true;
    ac_invalidate();
    let r = simplify_instruction(i);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    return r;
}
// simplifyInstruction(I, {DL, I}): no DT, AC or TLI
fn scf_simplify_plain(i: i32) -> i32 {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = simplify_instruction(i);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    return r;
}

// ---------------------------------------------------------------------------------------------
// foldTwoEntryPHINode

// m_BinOp(m_Cmp(Pred, ..), m_Value()) | m_BinOp(m_Value(), m_Cmp(..)) | m_c_Select(m_ImmConstant(), m_Cmp(..))
fn is_binop_or_and_eq(v: i32) -> bool {
    if !is_inst(v) { return false; }
    let o = iop(v);
    if is_binary_op(o) {
        let a = op(v, 0);
        let b = op(v, 1);
        if is_inst(a) && (iop(a) == OP_ICMP || iop(a) == OP_FCMP) { return cmp_is_equality(a); }
        if is_inst(b) && (iop(b) == OP_ICMP || iop(b) == OP_FCMP) { return cmp_is_equality(b); }
        return false;
    }
    if o == OP_SELECT {
        let t = op(v, 1);
        let f = op(v, 2);
        if m_imm_constant(t) && is_inst(f) && (iop(f) == OP_ICMP || iop(f) == OP_FCMP) { return cmp_is_equality(f); }
        if m_imm_constant(f) && is_inst(t) && (iop(t) == OP_ICMP || iop(t) == OP_FCMP) { return cmp_is_equality(t); }
    }
    return false;
}
// CmpInst::isEquality(Pred)
fn cmp_is_equality(c: i32) -> bool {
    let p = inst_pred(c);
    if iop(c) == OP_ICMP { return p == P_EQ || p == P_NE; }
    return p == 1 || p == 14 || p == 9 || p == 6;   // oeq, une, ueq, one
}

fn fold_two_entry_phi_node(pn0: i32) -> bool {
    let bb = inst_parent(pn0);
    let dombi, iftrue, iffalse = cu_get_if_condition(bb);
    if dombi < 0 { return false; }
    let ifcond = br_cond(dombi);
    if vals[ifcond].kind == VK_CINT { return false; }
    let domblock = inst_parent(dombi);
    var ifblocks: i32[>..<] = [];
    for k in nops(pn0) {
        let b = phi_block(pn0, k);
        if iop(block_terminator(b)) == OP_BR { ifblocks.push(b); }
    }
    let unpred = inst_get_md(dombi, mdk_unpredictable()) >= 0;
    if !unpred {
        let ok, tw, fw = pd_extract2(dombi);
        if ok && tw + fw != 0 {
            let tp = bp_get(tw, tw + fw);
            let likely = tti_predictable_branch_threshold();
            let fp = bp_compl(tp);
            if ifblocks.len == 1 {
                let bbp = if br_succ(dombi, 0) == bb { tp } else { fp };
                if bbp >= likely { return false; }
            } else {
                if tp >= likely || fp >= likely { return false; }
            }
        }
    }
    if is_inst(ifcond) && iop(ifcond) == OP_PHI && inst_parent(ifcond) == bb { return false; }
    var nphis = 0;
    var x = block_first(bb);
    while x >= 0 && iop(x) == OP_PHI {
        if nphis > 2 { return false; }
        nphis++;
        x = inst_next(x);
    }
    dmp_aggr.clear();
    dmp_zero_cost.clear();
    var cost: i64 = 0;
    var budget = cl_two_entry_phi_threshold * TCC_BASIC;
    if so.spec_unpred && unpred { budget = tc_add(budget, tti_branch_mispredict_penalty()); }
    var changed = false;
    var ii = block_first(bb);
    while ii >= 0 && iop(ii) == OP_PHI {
        let pn = ii;
        ii = inst_next(ii);
        let v = scf_simplify_plain(pn);
        if v >= 0 {
            rauw(pn, v);
            scf_erase(pn);
            changed = true;
            continue;
        }
        if !dominates_merge_point(phi_value(pn, 0), bb, dombi, cost, budget, 0) ||
           !dominates_merge_point(phi_value(pn, 1), bb, dombi, cost, budget, 0) { return changed; }
    }
    let pn = block_first(bb);
    if pn < 0 || iop(pn) != OP_PHI { return true; }
    if vals[pn].ty == T_I1 && (is_binop_or_and_eq(phi_value(pn, 0)) || is_binop_or_and_eq(phi_value(pn, 1)) || is_binop_or_and_eq(ifcond)) {
        return changed;
    }
    for ib in ifblocks {
        var i = block_first(ib);
        while !is_terminator(i) {
            if position(dmp_aggr, i) < 0 && !cu_is_debug_or_pseudo(i) { return changed; }
            i = inst_next(i);
        }
    }
    for ib in ifblocks { if cu_has_address_taken(ib) { return changed; } }
    for ib in ifblocks { cu_hoist_all_instructions_into(domblock, dombi, ib); }
    sb_at_nofold(dombi);
    loop {
        let p = block_first(bb);
        if p < 0 || iop(p) != OP_PHI { break; }
        let tv = phi_value_for_block(p, iftrue);
        let fv = phi_value_for_block(p, iffalse);
        let sel = sb_select_fmf(ifcond, tv, fv, if is_fp_math_operator(p) { p } else { -1 }, "", dombi);
        rauw(p, sel);
        cu_take_name(sel, p);
        scf_erase(p);
    }
    sb_br(bb);
    var ups: DTUpdate[>..<] = [];
    if cu_dtu {
        cu_upd(ups, DT_INSERT, domblock, bb);
        var ss: i32[>..<] = [];
        cu_succs(domblock, ss);
        for s in ss { cu_upd(ups, DT_DELETE, domblock, s); }
    }
    scf_erase(dombi);
    cu_apply(ups);
    return true;
}

// ---------------------------------------------------------------------------------------------
// foldBranchToCommonDest

// createLogicalOp
fn create_logical_op(o: i64, l: i32, r: i32, name: const u8[:]) -> i32 {
    if implies_poison(r, l) { return sb_binop(o, l, r, name); }
    if o == OP_AND { return sb_logical(true, l, r, name); }
    return sb_logical(false, l, r, name);
}

// extractPredSuccWeights
fn extract_pred_succ_weights(pbi: i32, bi: i32) -> bool, u64, u64, u64, u64 {
    var ph, pt, pf = pd_extract2(pbi);
    var sh, st, sf = pd_extract2(bi);
    if ph || sh {
        if !ph { pt = 1; pf = 1; }
        if !sh { st = 1; sf = 1; }
        return true, pt, pf, st, sf;
    }
    return false, 0, 0, 0, 0;
}

// shouldFoldCondBranchesToCommonDestination: (ok, CommonSucc, Opc, InvertPredCond)
fn should_fold_cond_branches(bi: i32, pbi: i32, have_tti: bool) -> bool, i32, i64, bool {
    var known = false;
    var ptp: u32 = 0;
    var likely: u32 = 0;
    if have_tti && inst_get_md(pbi, mdk_unpredictable()) < 0 {
        let ok, tw, fw = pd_extract2(pbi);
        if ok && tw + fw != 0 {
            ptp = bp_get(tw, tw + fw);
            likely = tti_predictable_branch_threshold();
            known = true;
        }
    }
    if br_succ(pbi, 0) == br_succ(bi, 0) {
        if !known || ptp < likely { return true, br_succ(bi, 0), OP_OR, false; }
    } else if br_succ(pbi, 1) == br_succ(bi, 1) {
        if !known || bp_compl(ptp) < likely { return true, br_succ(bi, 1), OP_AND, false; }
    } else if br_succ(pbi, 0) == br_succ(bi, 1) {
        if !known || ptp < likely { return true, br_succ(bi, 1), OP_AND, true; }
    } else if br_succ(pbi, 1) == br_succ(bi, 0) {
        if !known || bp_compl(ptp) < likely { return true, br_succ(bi, 0), OP_OR, true; }
    }
    return false, -1, 0, false;
}

fn perform_branch_to_common_dest_folding(bi: i32, pbi: i32, have_tti: bool) -> bool {
    let bb = inst_parent(bi);
    let pred = inst_parent(pbi);
    let ok, common, opc, invert = should_fold_cond_branches(bi, pbi, have_tti);
    // IRBuilder<ConstantFolder, IRBuilderCallbackInserter>: copies !annotation of BB's terminator
    sb_at(pbi);
    sb_annot = inst_get_md(block_terminator(bb), mdk_annotation());
    if invert { scf_invert_branch(pbi); }
    let usucc = if br_succ(pbi, 0) == bb { br_succ(bi, 0) } else { br_succ(bi, 1) };
    add_predecessor_to_block(usucc, pred, bb);
    let hw, ptw, pfw, stw, sfw = extract_pred_succ_weights(pbi, bi);
    var mdw: u64[>..<] = [];
    if hw {
        if br_succ(pbi, 0) == bb {
            mdw.push(ptw * stw);
            mdw.push(pfw * (sfw + stw) + ptw * sfw);
        } else {
            mdw.push(ptw * (sfw + stw) + pfw * stw);
            mdw.push(pfw * sfw);
        }
        pd_set_fitted(pbi, mdw, false, true);
    } else {
        inst_erase_md(pbi, MDK_PROF_SC);
    }
    br_set_succ(pbi, if br_succ(pbi, 0) != bb { 1 } else { 0 }, usucc);
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        cu_upd(ups, DT_INSERT, pred, usucc);
        cu_upd(ups, DT_DELETE, pred, bb);
        dtu_apply_updates(ups);
    }
    let lmd = inst_get_md(bi, 18);
    if lmd >= 0 { inst_set_md(pbi, 18, lmd); }
    var vmap: i32[>..<] = [];
    clone_insts_into_pred(bb, pred, vmap);
    if inst_first_dbg(block_terminator(bb)) >= 0 { scf_not_ported("cloning debug records of the folded branch"); }
    var bicond = vmap_find(vmap, br_cond(bi));
    if bicond < 0 { bicond = br_cond(bi); }
    let nc = create_logical_op(opc, br_cond(pbi), bicond, "or.cond");
    sb_annot = -1;
    br_set_cond(pbi, nc);
    if is_select(nc) && mdw.len > 0 {
        let two: u64[2] = [mdw[0], mdw[1]];
        pd_set_fitted(nc, two, false, true);
    }
    return true;
}

fn is_vector_op(i: i32) -> bool {
    if ty_is_vector(vals[i].ty) { return true; }
    for k in nops(i) { let o = op(i, k); if o >= 0 && ty_is_vector(vals[o].ty) { return true; } }
    return false;
}

// llvm::foldBranchToCommonDest(BI, DTU, MSSAU = null, TTI, AC, BonusInstThreshold)
fn fold_branch_to_common_dest(bi: i32, have_tti: bool, bonus_threshold: i64) -> bool {
    let bb = inst_parent(bi);
    let ck = scf_cost_kind(bb);
    let c = br_cond(bi);
    if !is_inst(c) { return false; }
    let co = iop(c);
    if !(co == OP_ICMP || co == OP_FCMP || is_binary_op(co) || co == OP_SELECT || co == OP_TRUNC) { return false; }
    if inst_parent(c) != bb || !has_one_use(c) { return false; }
    if br_succ(bi, 0) == bb || br_succ(bi, 1) == bb { return false; }
    var preds: i32[>..<] = [];
    var allp: i32[>..<] = [];
    cu_preds(bb, allp);
    for pb in allp {
        let pbi = block_terminator(pb);
        var dummy: i32[>..<] = [];
        if iop(pbi) != OP_CONDBR || !safe_to_merge_terminators(bi, pbi, dummy, false) { continue; }
        let ok, common, opc, invert = should_fold_cond_branches(bi, pbi, have_tti);
        if !ok { continue; }
        if have_tti {
            let ty = vals[br_cond(bi)].ty;
            var cost = tti_arith_cost(opc, ty, ck, []);
            let pc = br_cond(pbi);
            if invert && (!has_one_use(pc) || !(is_inst(pc) && (iop(pc) == OP_ICMP || iop(pc) == OP_FCMP))) {
                cost = tc_add(cost, tti_arith_cost(OP_XOR, ty, ck, []));
            }
            if cost > cl_branch_fold_threshold { continue; }
        }
        preds.push(pb);
    }
    if preds.len == 0 { return false; }
    var nbonus: i64 = 0;
    var saw_vec = false;
    let pc = preds.len;
    let cxt = if pc == 1 { block_terminator(preds[0]) } else { -1 };
    var i = block_first(bb);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if cur == c { continue; }
        if iop(cur) == OP_BR || iop(cur) == OP_CONDBR { continue; }
        if inst_iid(cur) == IID_pseudoprobe { continue; }
        if !spec_safe(cur, cxt, true) { return false; }
        if is_vector_op(cur) { saw_vec = true; }
        if !have_tti || tti_instruction_cost(cur, ck) != TCC_FREE {
            nbonus += pc;
            if nbonus > bonus_threshold * cl_branch_fold_vec_mult { return false; }
        }
        var u = first_use(cur);
        while u >= 0 {
            let ui = uses[u].user;
            if iop(ui) == OP_PHI {
                if use_aux[u] != bb { return false; }
            } else {
                if inst_parent(ui) != bb || !comes_before(cur, ui) { return false; }
            }
            u = use_next(u);
        }
    }
    if nbonus > bonus_threshold * (if saw_vec { cl_branch_fold_vec_mult } else { 1 }) { return false; }
    let pbi = block_terminator(preds[0]);
    return perform_branch_to_common_dest_folding(bi, pbi, have_tti);
}

// ---------------------------------------------------------------------------------------------
// Conditional stores (mergeConditionalStores)

fn find_unique_store_in_blocks(b1: i32, b2: i32) -> i32 {
    var s: i32 = -1;
    let bs: i32[2] = [b1, b2];
    for b in bs {
        if b < 0 { continue; }
        var i = block_first(b);
        while i >= 0 {
            if iop(i) == OP_STORE {
                if s >= 0 { return -1; }
                s = i;
            }
            i = inst_next(i);
        }
    }
    return s;
}

fn merge_conditional_stores(pbi: i32, qbi: i32) -> bool {
    var ptb = br_succ(pbi, 0);
    var pfb = br_succ(pbi, 1);
    var qtb = br_succ(qbi, 0);
    var qfb = br_succ(qbi, 1);
    var post = cu_single_succ(qfb);
    if cu_single_succ(qtb) == qfb { post = qfb; }
    if post < 0 { return false; }
    let qbb = inst_parent(qbi);
    var inv_p = false;
    var inv_q = false;
    if pfb == qbb { let t = pfb; pfb = ptb; ptb = t; inv_p = true; }
    if qfb == post { let t = qfb; qfb = qtb; qtb = t; inv_q = true; }
    if ptb == qbb { ptb = -1; }
    if qtb == post { qtb = -1; }
    fn one_pred_one_succ(b: i32, p: i32, s: i32) -> bool { single_pred(b) == p && cu_single_succ(b) == s }
    if !one_pred_one_succ(pfb, inst_parent(pbi), qbb) || !one_pred_one_succ(qfb, qbb, post) { return false; }
    if (ptb >= 0 && !one_pred_one_succ(ptb, inst_parent(pbi), qbb)) || (qtb >= 0 && !one_pred_one_succ(qtb, qbb, post)) { return false; }
    if !has_n_uses(qbb, 2) { return false; }
    var paddrs: i32[>..<] = [];
    var qaddrs: i32[>..<] = [];
    let pbs: i32[2] = [ptb, pfb];
    for b in pbs {
        if b < 0 { continue; }
        var i = block_first(b);
        while i >= 0 { if iop(i) == OP_STORE { cu_push_unique(paddrs, op(i, 1)); } i = inst_next(i); }
    }
    let qbs: i32[2] = [qtb, qfb];
    for b in qbs {
        if b < 0 { continue; }
        var i = block_first(b);
        while i >= 0 { if iop(i) == OP_STORE { cu_push_unique(qaddrs, op(i, 1)); } i = inst_next(i); }
    }
    var common: i32[>..<] = [];
    for a in paddrs { if position(qaddrs, a) >= 0 { common.push(a); } }
    var changed = false;
    for a in common {
        if merge_conditional_store_to_address(ptb, pfb, qtb, qfb, post, a, inv_p, inv_q) { changed = true; }
    }
    return changed;
}

fn merge_conditional_store_to_address(ptb: i32, pfb: i32, qtb: i32, qfb: i32, post0: i32, addr: i32, inv_p0: bool, inv_q0: bool) -> bool {
    var post = post0;
    let ps = find_unique_store_in_blocks(ptb, pfb);
    let qs = find_unique_store_in_blocks(qtb, qfb);
    if ps < 0 || qs < 0 { return false; }
    let px = insts[inst_of(ps)];
    let qx = insts[inst_of(qs)];
    if inst_is_volatile(qs) || inst_is_volatile(ps) || qx.ord > 1 || px.ord > 1 || px.ord != qx.ord || px.ss != qx.ss ||
       vals[op(ps, 0)].ty != vals[op(qs, 0)].ty { return false; }
    var i = block_first(single_pred(qfb));
    while i >= 0 { if inst_may_read_or_write_memory(i) { return false; } i = inst_next(i); }
    i = block_first(qfb);
    while i >= 0 { if i != qs && inst_may_read_or_write_memory(i) { return false; } i = inst_next(i); }
    if qtb >= 0 {
        i = block_first(qtb);
        while i >= 0 { if i != qs && inst_may_read_or_write_memory(i) { return false; } i = inst_next(i); }
    }
    i = ps;
    while i >= 0 { if i != ps && inst_may_read_or_write_memory(i) { return false; } i = inst_next(i); }
    fn worthwhile(b: i32) -> bool {
        if b < 0 { return true; }
        var cost: i64 = 0;
        let budget = cl_phi_fold_threshold * TCC_BASIC;
        var x = block_first(b);
        while x >= 0 {
            let cur = x;
            x = inst_next(x);
            if is_terminator(cur) { continue; }
            if iop(cur) == OP_STORE && (cur == ps || cur == qs) { continue; }
            if !is_binary_op(iop(cur)) && iop(cur) != OP_GEP { return false; }
            cost = tc_add(cost, tti_instruction_cost(cur, TCK_SIZE_AND_LATENCY));
            if cost > budget { return false; }
        }
        return true;
    }
    if !cl_merge_cond_stores_aggr && (!worthwhile(ptb) || !worthwhile(pfb) || !worthwhile(qtb) || !worthwhile(qfb)) { return false; }
    if pred_count(post) > 2 {
        let truep = if qtb >= 0 { qtb } else { single_pred(qfb) };
        let two: i32[2] = [qfb, truep];
        let nb = cu_split_block_predecessors(post, two, "condstore.split");
        if nb < 0 { return false; }
        post = nb;
    }
    let pbr = block_terminator(single_pred(pfb));
    let qbr = block_terminator(single_pred(qfb));
    let pcond = br_cond(pbr);
    let qcond = br_cond(qbr);
    let pphi = ensure_value_available_in_successor(op(ps, 0), inst_parent(ps), -1);
    let qphi = ensure_value_available_in_successor(op(qs, 0), inst_parent(qs), pphi);
    let first = scf_first_insertion_pt(post);
    sb_bb = post; sb_pos = first; sb_nofold = false; sb_annot = -1;
    sb_dl = inst_get_md(first, MDK_DBG_SC);
    let inv_p = inv_p0 != (inst_parent(ps) != ptb);
    let inv_q = inv_q0 != (inst_parent(qs) != qtb);
    let ppred = if inv_p { sb_not(pcond, "") } else { pcond };
    let qpred = if inv_q { sb_not(qcond, "") } else { qcond };
    let comb = sb_binop(OP_OR, ppred, qpred, "");
    let ins_pt = sb_pos;
    let t = split_block_and_insert_if_then(comb, ins_pt, false, -1);
    if pd_has_branch_weights(pbr) && pd_has_branch_weights(qbr) {
        var pw: u64[>..<] = [];
        var qw: u64[>..<] = [];
        pd_extract(pbr, pw);
        pd_extract(qbr, qw);
        if inv_p { let x = pw[0]; pw[0] = pw[1]; pw[1] = x; }
        if inv_q { let x = qw[0]; qw[0] = qw[1]; qw[1] = x; }
        let fw = pw[1] * qw[1];
        let tw = pw[0] * (qw[0] + qw[1]) + pw[1] * qw[0];
        let w: u64[2] = [tw, fw];
        pd_set_fitted(block_terminator(post), w, false, true);
    }
    sb_set_before(t);
    let si = create_inst(OP_STORE, T_VOID, [qphi, addr]);
    insts[inst_of(si)].align = (log2_exact_i(dl_align(vals[qphi].ty, true)) + 1) as u8;
    sb_insert(si, "");
    combine_metadata_for_cse(qs, ps, true);
    // copyMetadata(*QStore): all attachments and the debug location, if QStore has any
    if insts[inst_of(qs)].nmd > 0 {
        let qx2 = insts[inst_of(qs)];
        for k in qx2.nmd { inst_set_md(si, md_att[qx2.md + 2 * k], md_att[qx2.md + 2 * k + 1]); }
        if inst_get_md(qs, MDK_DBG_SC) < 0 { inst_erase_md(si, MDK_DBG_SC); }
    }
    insts[inst_of(si)].align = min(insts[inst_of(ps)].align, insts[inst_of(qs)].align);
    if insts[inst_of(qs)].ord != 0 { insts[inst_of(si)].ord = insts[inst_of(qs)].ord; insts[inst_of(si)].ss = insts[inst_of(qs)].ss; }
    scf_erase(qs);
    scf_erase(ps);
    return true;
}

// ensureValueAvailableInSuccessor(V, BB, AlternativeV)
fn ensure_value_available_in_successor(v: i32, bb: i32, alt: i32) -> i32 {
    var phi: i32 = -1;
    let succ = cu_single_succ(bb);
    var p = block_first(succ);
    while p >= 0 && iop(p) == OP_PHI {
        if phi_value_for_block(p, bb) == v {
            phi = p;
            if alt < 0 { break; }
            var ps2: i32[>..<] = [];
            cu_preds(succ, ps2);
            let other = if ps2[0] == bb { ps2[1] } else { ps2[0] };
            if phi_value_for_block(p, other) == alt { break; }
            phi = -1;
        }
        p = inst_next(p);
    }
    if phi >= 0 { return phi; }
    if alt < 0 && (!is_inst(v) || inst_parent(v) != bb) { return v; }
    let np = new_inst(OP_PHI, vals[v].ty, 2);
    vals[np].nops = 0;
    let f = block_first(succ);
    inst_insert_before(np, f);
    set_name(np, "simplifycfg.merge");
    phi_add_incoming(np, v, bb);
    var ps3: i32[>..<] = [];
    cu_preds(succ, ps3);
    for pb in ps3 {
        if pb != bb { phi_add_incoming(np, if alt >= 0 { alt } else { c_poison(vals[v].ty) }, pb); }
    }
    return np;
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable, BranchWeights, DTU): returns the then-block's terminator
fn split_block_and_insert_if_then(cond: i32, before: i32, unreachable: bool, weights: i32) -> i32 {
    var ups: DTUpdate[>..<] = [];
    var orig: i32[>..<] = [];
    let head = inst_parent(before);
    if cu_dtu { var ss: i32[>..<] = []; cu_succs(head, ss); for s in ss { cu_push_unique(orig, s); } }
    // splitBasicBlock(SplitBefore): unnamed, the branch gets the split point's location without its atom
    var loc = inst_get_md(before, MDK_DBG_SC);
    if loc >= 0 && scf_atom_group(loc) != 0 { scf_not_ported("DILocation::getWithoutAtom"); }
    let tail = split_block(head, before, "");
    let hbr = block_terminator(head);
    if loc >= 0 { inst_set_md(hbr, MDK_DBG_SC, loc); }
    let fv = block_func(head);
    let then = create_block_before(fv, tail, "");
    var to_tail = false;
    if unreachable { block_append_inst(then, create_inst(OP_UNREACHABLE, T_VOID, [])); }
    else { block_append_inst(then, create_inst(OP_BR, T_VOID, [tail])); to_tail = true; }
    let tdl = inst_get_md(before, MDK_DBG_SC);
    if tdl >= 0 { inst_set_md(block_terminator(then), MDK_DBG_SC, tdl); }
    let nt = create_inst(OP_CONDBR, T_VOID, [cond, then, tail]);
    if weights >= 0 { inst_set_md(nt, MDK_PROF_SC, weights); }
    // ReplaceInstWithInst: the old terminator's debug location if the new one has none
    let odl = inst_get_md(hbr, MDK_DBG_SC);
    inst_insert_before(nt, hbr);
    if inst_get_md(nt, MDK_DBG_SC) < 0 && odl >= 0 { inst_set_md(nt, MDK_DBG_SC, odl); }
    scf_erase(hbr);
    if cu_dtu {
        cu_upd(ups, DT_INSERT, head, then);
        cu_upd(ups, DT_INSERT, head, tail);
        if to_tail { cu_upd(ups, DT_INSERT, then, tail); }
        for s in orig { cu_upd(ups, DT_INSERT, tail, s); }
        for s in orig { cu_upd(ups, DT_DELETE, head, s); }
        dtu_apply_updates(ups);
    }
    return block_terminator(then);
}

// ---------------------------------------------------------------------------------------------
// SimplifyCondBranchToCondBranch, tryWidenCondBranchToCondBranch

// llvm::isWidenableBranch (GuardUtils.cpp parseWidenableBranch)
fn is_widenable_branch(bi: i32) -> bool {
    let c = br_cond(bi);
    if !has_one_use(c) { return false; }
    if inst_iid(c) == IID_experimental_widenable_condition { return true; }
    if !is_inst_op(c, OP_AND) { return false; }
    let a = op(c, 0);
    let b = op(c, 1);
    if inst_iid(a) == IID_experimental_widenable_condition && has_one_use(a) { return true; }
    if inst_iid(b) == IID_experimental_widenable_condition && has_one_use(b) { return true; }
    return false;
}

fn try_widen_cond_branch(pbi: i32, bi: i32) -> bool {
    let itb = br_succ(pbi, 0);
    let ifb = br_succ(pbi, 1);
    if !is_widenable_branch(pbi) || itb != inst_parent(bi) || single_pred(inst_parent(bi)) < 0 { return false; }
    if cu_has_phis(ifb) { return false; }
    if block_nsucc(ifb) != 0 { return false; }
    let bb = inst_parent(bi);
    fn no_side_effects(b: i32) -> bool {
        var i = block_first(b);
        while i >= 0 { if inst_may_write_memory(i) || inst_may_have_side_effects(i) { return false; } i = inst_next(i); }
        return true;
    }
    // BasicBlock::getTerminatingDeoptimizeCall
    fn deopt_terminated(b: i32) -> bool {
        let t = block_last(b);
        if t < 0 || iop(t) != OP_RET || t == block_first(b) { return false; }
        let p = inst_prev(t);
        return p >= 0 && iop(p) == OP_CALL && called_function(p) >= 0 && func_iid(called_function(p)) == IID_experimental_deoptimize;
    }
    for k in [1, 0] {
        let old = br_succ(bi, k);
        if old != ifb && deopt_terminated(old) && no_side_effects(bb) {
            block_remove_predecessor(old, bb, false);
            br_set_succ(bi, k, ifb);
            if cu_dtu {
                var ups: DTUpdate[>..<] = [];
                cu_upd(ups, DT_INSERT, bb, ifb);
                cu_upd(ups, DT_DELETE, bb, old);
                dtu_apply_updates(ups);
            }
            return true;
        }
    }
    return false;
}

fn simplify_cond_branch_to_cond_branch(pbi: i32, bi: i32) -> bool {
    let bb = inst_parent(bi);
    if br_cond(pbi) == br_cond(bi) && br_succ(pbi, 0) != br_succ(pbi, 1) {
        if single_pred(bb) >= 0 {
            let t = br_succ(pbi, 0) == bb;
            br_set_cond(bi, c_int(T_I1, if t { 1 } else { 0 }));
            return true;
        }
    }
    if try_widen_cond_branch(pbi, bi) { return true; }
    if cl_merge_cond_stores && merge_conditional_stores(pbi, bi) { return true; }
    if block_first(bb) != bi { return false; }
    var pbiop: i64 = 0;
    var biop: i64 = 0;
    if br_succ(pbi, 0) == br_succ(bi, 0) { pbiop = 0; biop = 0; }
    else if br_succ(pbi, 0) == br_succ(bi, 1) { pbiop = 0; biop = 1; }
    else if br_succ(pbi, 1) == br_succ(bi, 0) { pbiop = 1; biop = 0; }
    else if br_succ(pbi, 1) == br_succ(bi, 1) { pbiop = 1; biop = 1; }
    else { return false; }
    if br_succ(pbi, pbiop) == bb { return false; }
    if inst_get_md(pbi, mdk_unpredictable()) < 0 {
        var pw: u64[>..<] = [];
        if pd_extract(pbi, pw) && (pw[0] + pw[1]) != 0 {
            let prob = bp_get(pw[pbiop], pw[0] + pw[1]);
            if prob >= tti_predictable_branch_threshold() { return false; }
        }
    }
    let common = br_succ(pbi, pbiop);
    let removed = br_succ(pbi, pbiop ^ 1);
    var nphis = 0;
    var x = block_first(common);
    while x >= 0 && iop(x) == OP_PHI {
        if nphis > 2 { return false; }
        nphis++;
        x = inst_next(x);
    }
    var other = br_succ(bi, biop ^ 1);
    var ups: DTUpdate[>..<] = [];
    if other == bb {
        let inf = create_block_after(block_func(bb), -1, "infloop");
        block_append_inst(inf, create_inst(OP_BR, T_VOID, [inf]));
        if cu_dtu { cu_upd(ups, DT_INSERT, inf, inf); }
        other = inf;
    }
    var pbicond = br_cond(pbi);
    sb_at_nofold(pbi);
    if pbiop != 0 {
        let nm = name_plus(pbicond, ".not");
        pbicond = sb_not(pbicond, nm);
    }
    var bicond = br_cond(bi);
    if biop != 0 {
        let nm = name_plus(bicond, ".not");
        bicond = sb_not(bicond, nm);
    }
    let cond = create_logical_op(OP_OR, pbicond, bicond, "brmerge");
    br_set_cond(pbi, cond);
    br_set_succ(pbi, 0, common);
    br_set_succ(pbi, 1, other);
    if cu_dtu {
        cu_upd(ups, DT_INSERT, inst_parent(pbi), other);
        cu_upd(ups, DT_DELETE, inst_parent(pbi), removed);
        dtu_apply_updates(ups);
    }
    let hw, ptw, pfw, stw, sfw = extract_pred_succ_weights(pbi, bi);
    if hw {
        let pcom = if pbiop != 0 { pfw } else { ptw };
        let poth = if pbiop != 0 { ptw } else { pfw };
        let scom = if biop != 0 { sfw } else { stw };
        let soth = if biop != 0 { stw } else { sfw };
        let nw: u64[2] = [pcom * (scom + soth) + poth * scom, poth * soth];
        pd_set_fitted(pbi, nw, false, true);
        if is_select(cond) {
            let sw2: u64[2] = [pcom, poth];
            pd_set_fitted(cond, sw2, false, true);
        }
    }
    add_predecessor_to_block(other, inst_parent(pbi), bb);
    var p = block_first(common);
    while p >= 0 && iop(p) == OP_PHI {
        let pn = p;
        p = inst_next(p);
        let biv = phi_value_for_block(pn, bb);
        let pidx = phi_block_index(pn, inst_parent(pbi));
        let pbiv = phi_value(pn, pidx);
        if biv != pbiv {
            let nm = name_plus(pbiv, ".mux");
            let nv = sb_select(pbicond, pbiv, biv, nm, -1);
            set_op(pn, pidx, nv);
            if hw {
                let tw = if pbiop != 0 { pfw } else { ptw };
                let fw = if pbiop != 0 { ptw } else { pfw };
                let w2: u64[2] = [tw, fw];
                pd_set_fitted(nv, w2, false, true);
            }
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ConstantComparesGatherer

var ccg_comp: i32 = -1;
var ccg_extra: i32 = -1;
var ccg_vals: i32[>..<];
var ccg_used: i64 = 0;
var ccg_is_eq: bool = false;
var ccg_ignore_first: bool = false;
var ccg_multiple: bool = false;

fn ccg_set_value_once(nv: i32) -> bool {
    if ccg_ignore_first { ccg_ignore_first = false; return false; }
    if ccg_comp >= 0 && ccg_comp != nv { ccg_multiple = true; return false; }
    ccg_comp = nv;
    return true;
}

fn ccg_match_instruction(i0: i32, is_eq0: bool) -> bool {
    var i = i0;
    var is_eq = is_eq0;
    let nv = m_not(i);
    if nv >= 0 && is_inst(nv) { i = nv; is_eq = !is_eq; }
    // m_NUWTrunc(m_Value(Val))
    if iop(i) == OP_TRUNC && (insts[inst_of(i)].flags & FL_NUW) != 0 {
        let v = op(i, 0);
        if !ccg_set_value_once(v) { return false; }
        ccg_used++;
        ccg_vals.push(c_int(vals[v].ty, if is_eq { 1 } else { 0 }));
        return true;
    }
    if iop(i) != OP_ICMP { return false; }
    let c = get_constant_int(op(i, 1));
    if c < 0 { return false; }
    let pred = inst_pred(i);
    let lhs = op(i, 0);
    if pred == (if is_eq { P_EQ } else { P_NE }) {
        // (x & ~2^z) == y --> x == y || x == y|2^z
        if is_op(lhs, OP_AND) {
            let r = m_apint(op(lhs, 1));
            if r >= 0 {
                let mask = ap_not(ci_ap(r));
                let cv = ci_ap(c);
                if ap_is_pow2(mask) && ap_eq(ap_and(cv, ap_not(mask)), cv) {
                    if !ccg_set_value_once(op(lhs, 0)) { return false; }
                    ccg_vals.push(c);
                    ccg_vals.push(c_int_ap(vals[c].ty, ap_or(cv, mask)));
                    ccg_used++;
                    return true;
                }
            }
        }
        // (x | 2^z) == y --> x == y || x == y & ~2^z
        if is_op(lhs, OP_OR) {
            let r = m_apint(op(lhs, 1));
            if r >= 0 {
                let mask = ci_ap(r);
                let cv = ci_ap(c);
                if ap_is_pow2(mask) && ap_eq(ap_or(cv, mask), cv) {
                    if !ccg_set_value_once(op(lhs, 0)) { return false; }
                    ccg_vals.push(c);
                    ccg_vals.push(c_int_ap(vals[c].ty, ap_and(cv, ap_not(mask))));
                    ccg_used++;
                    return true;
                }
            }
        }
        if !ccg_set_value_once(lhs) { return false; }
        ccg_used++;
        ccg_vals.push(c);
        return true;
    }
    var span = rg_exact_icmp(pred, ci_ap(c));
    var cand = lhs;
    if is_op(lhs, OP_ADD) {
        let r = m_apint(op(lhs, 1));
        if r >= 0 {
            span = rg_subtract(span, ci_ap(r));
            cand = op(lhs, 0);
        }
    }
    if !is_eq { span = rg_inverse(span); }
    if rg_is_size_larger_than(span, 8) || rg_is_empty(span) { return false; }
    if !ccg_set_value_once(cand) { return false; }
    let ity = ty_int(rg_w(span));
    var tmp = span.lo;
    loop {
        ccg_vals.push(c_int_ap(ity, tmp));
        tmp = ap_inc(tmp);
        if ap_eq(tmp, span.hi) { break; }
    }
    ccg_used++;
    return true;
}

fn ccg_gather(v0: i32) {
    var op0: i32 = -1;
    var op1: i32 = -1;
    if m_logical(v0, false) { op0 = lg_a; op1 = lg_b; ccg_is_eq = true; }
    else if m_logical(v0, true) { op0 = lg_a; op1 = lg_b; ccg_is_eq = false; }
    else { return; }
    var dft: i32[>..<] = [];
    dft.push(op0);
    dft.push(op1);
    var visited: i32[>..<] = [];
    visited.push(v0);
    cu_push_unique(visited, op0);
    cu_push_unique(visited, op1);
    while dft.len > 0 {
        let v = dft.pop();
        if is_inst(v) {
            if m_logical(v, !ccg_is_eq) {
                let a = lg_a;
                let b = lg_b;
                if cu_push_unique(visited, b) { dft.push(b); }
                if cu_push_unique(visited, a) { dft.push(a); }
                continue;
            }
            if ccg_match_instruction(v, ccg_is_eq) { continue; }
        }
        if ccg_extra < 0 { ccg_extra = v; continue; }
        ccg_comp = -1;
        break;
    }
}

fn ccg_run(cond: i32) {
    ccg_comp = -1; ccg_extra = -1; ccg_vals.clear(); ccg_used = 0; ccg_is_eq = false;
    ccg_ignore_first = false; ccg_multiple = false;
    ccg_gather(cond);
    if ccg_comp >= 0 || !ccg_multiple { return; }
    ccg_extra = -1;
    ccg_vals.clear();
    ccg_used = 0;
    ccg_ignore_first = true;
    ccg_gather(cond);
}

// SplitBlock(Old, SplitPt, DTU, LI = null, MSSAU = null, BBName)
fn scf_split_block(old: i32, at: i32, name: const u8[:]) -> i32 {
    let loc = inst_get_md(at, MDK_DBG_SC);
    var nm: u8[>..] = [];
    if name.len == 0 { nm.append(val_name(old)); nm.append(".split"); } else { nm.append(name); }
    let nb = split_block(old, at, nm);
    let br = block_terminator(old);
    if loc >= 0 { inst_set_md(br, MDK_DBG_SC, loc); }
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        var uniq: i32[>..<] = [];
        cu_upd(ups, DT_INSERT, old, nb);
        var ss: i32[>..<] = [];
        cu_succs(nb, ss);
        for s in ss {
            if cu_push_unique(uniq, s) { cu_upd(ups, DT_INSERT, nb, s); cu_upd(ups, DT_DELETE, old, s); }
        }
        dtu_apply_updates(ups);
    }
    return nb;
}

// setExplicitlyUnknownBranchWeightsIfProfiled(I, "simplifycfg")
fn set_unknown_weights_if_profiled(i: i32) {
    let fv = inst_func(i);
    let m = func_get_md(fv, MDK_PROF_SC);
    if m < 0 { return; }
    // function_entry_count > 0
    if mds[m].nops < 2 || !pd_md_string_is(md_op(m, 0), "function_entry_count") { return; }
    let c = mds[md_op(m, 1)].extra;
    if ap_is_zero(ci_ap(c)) { return; }
    let ops: i32[2] = [md_string("unknown"), md_string("simplifycfg")];
    inst_set_md(i, MDK_PROF_SC, md_get(MK_TUPLE, -1, ops, false));
}
fn func_get_md(fv: i32, kind: i32) -> i32 {
    let g = globs[glob_of(fv)];
    for k in g.nmd { if md_att[g.md + 2 * k] == kind { return md_att[g.md + 2 * k + 1]; } }
    return -1;
}

// simplifyBranchOnICmpChain
fn simplify_branch_on_icmp_chain(bi: i32) -> bool {
    let cond = br_cond(bi);
    if !is_inst(cond) { return false; }
    ccg_run(cond);
    var compval = ccg_comp;
    let used = ccg_used;
    var extra = ccg_extra;
    let true_when_eq = ccg_is_eq;
    if compval < 0 { return false; }
    if used <= 1 { return false; }
    var values: i32[>..<] = [];
    for v in ccg_vals { values.push(v); }
    // array_pod_sort with constantIntSortPredicate: descending, then unique
    sort(values) { a, b => ap_ult(ci_ap(b), ci_ap(a)) };
    var w = 0;
    for k in values.len { if w == 0 || values[w - 1] != values[k] { values[w] = values[k]; w++; } }
    values.resize(w);
    if extra >= 0 && values.len < 2 { return false; }
    var bw: u64[>..<] = [];
    let has_prof = pd_extract(bi, bw);
    var defbb = br_succ(bi, 1);
    var edgebb = br_succ(bi, 0);
    if !true_when_eq {
        let t = defbb; defbb = edgebb; edgebb = t;
        if has_prof { let t2 = bw[0]; bw[0] = bw[1]; bw[1] = t2; }
    }
    var bb = inst_parent(bi);
    var ups: DTUpdate[>..<] = [];
    if extra >= 0 {
        let nb = scf_split_block(bb, bi, "switch.early.test");
        let oldti = block_terminator(bb);
        sb_set_before(oldti);
        let save_dt = sq_no_dt;
        let save_ac = sq_no_ac;
        sq_no_dt = true;
        sq_no_ac = false;
        ac_invalidate();
        if !is_guaranteed_not_to_be_undef_or_poison(extra, bi, 0) {
            extra = sb_freeze(extra, "");
        }
        sq_no_dt = save_dt;
        sq_no_ac = save_ac;
        let br = if true_when_eq { sb_condbr(extra, edgebb, nb) } else { sb_condbr(extra, nb, edgebb) };
        set_unknown_weights_if_profiled(br);
        scf_erase(oldti);
        if cu_dtu { cu_upd(ups, DT_INSERT, bb, edgebb); }
        add_predecessor_to_block(edgebb, bb, nb);
        bb = nb;
    }
    sb_set_before(bi);
    if ty_kind(vals[compval].ty) == TK_PTR {
        let ity = ty_int(dl_ptr(ptr_as(vals[compval].ty)).bits);
        compval = sb_cast(OP_PTRTOINT, compval, ity, "magicptr");
    }
    let front = ci_ap(values[0]);
    let back = ci_ap(values[values.len - 1]);
    if ap_eq_u64(ap_sub(front, back), (values.len - 1) as u64) {
        let rc = rg_nonempty(back, ap_inc(front));
        let pred, rhs, off = rg_equivalent_icmp_off(rc);
        var x = compval;
        let cty = vals[compval].ty;
        if !ap_is_zero(off) { x = sb_binop(OP_ADD, x, c_int_ap(cty, off), ""); }
        let c2 = sb_icmp(pred, x, c_int_ap(cty, rhs), "");
        let nbi = sb_condbr(c2, edgebb, defbb);
        if has_prof { pd_set(nbi, bw, false, true); }
    } else {
        let nsw = sb_switch(compval, defbb, values.len);
        if has_prof {
            var nw: u64[>..<] = [];
            nw.push(bw[1]);
            for k in values.len { nw.push((bw[0] / (values.len as u64)) & 0xFFFFFFFF); }
            pd_set(nsw, nw, false, true);
        }
        for v in values { sw_add_case_raw(nsw, v, edgebb); }
        var p = block_first(edgebb);
        while p >= 0 && iop(p) == OP_PHI {
            let inv = phi_value_for_block(p, bb);
            for k in values.len - 1 { phi_add_incoming(p, inv, bb); }
            p = inst_next(p);
        }
    }
    erase_terminator_and_dce_cond(bi);
    cu_apply(ups);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Unconditional branches

// SwitchInst::findCaseValue: case index or -1 (default)
fn sw_find_case_value(si: i32, c: i32) -> i64 {
    for k in sw_ncases(si) { if sw_case_val(si, k) == c { return k; } }
    return -1;
}
// SwitchInst::findCaseDest: the unique case value for BB (-1 if none or several)
fn sw_find_case_dest(si: i32, bb: i32) -> i32 {
    if bb == sw_default(si) { return -1; }
    var r: i32 = -1;
    for k in sw_ncases(si) {
        if sw_case_dest(si, k) == bb {
            if r >= 0 { return -1; }
            r = sw_case_val(si, k);
        }
    }
    return r;
}

// tryToSimplifyUncondBranchWithICmpSelectInIt(ICI, Select) (Select = -1: the ICmp-only form)
fn try_simplify_uncond_with_icmp_select(ici: i32, sel: i32) -> bool {
    let bb = inst_parent(ici);
    if iop(block_first(bb)) == OP_PHI || !has_one_use(ici) || (sel >= 0 && !has_one_use(sel)) { return false; }
    let pred = single_pred(bb);
    if pred < 0 || iop(block_terminator(pred)) != OP_SWITCH { return false; }
    let icond = op(ici, 0);
    let ncv = op(ici, 1);
    if vals[ncv].kind != VK_CINT || ty_is_vector(vals[ncv].ty) { return false; }
    let p = inst_pred(ici);
    var st: i32 = -1;
    var sf: i32 = -1;
    var user: i32 = -1;
    if sel < 0 {
        st = scf_true();
        sf = scf_false();
        user = user_back(ici);
    } else {
        if op(sel, 0) != ici { return false; }
        st = op(sel, 1);
        sf = op(sel, 2);
        user = user_back(sel);
    }
    let si = block_terminator(pred);
    if op(si, 0) != icond { return false; }
    if sw_default(si) != bb {
        let vv = sw_find_case_dest(si, bb);
        set_op(ici, 0, vv);
        let v = scf_simplify_plain(ici);
        if v >= 0 {
            rauw(ici, v);
            scf_erase(ici);
        }
        return scf_request_resimplify();
    }
    if sw_find_case_value(si, ncv) >= 0 {
        let v = if p == P_EQ { scf_false() } else { scf_true() };
        rauw(ici, v);
        scf_erase(ici);
        return scf_request_resimplify();
    }
    let succ = term_succ(block_terminator(bb), 0);
    if !(is_inst(user) && iop(user) == OP_PHI) || user != block_first(succ) { return false; }
    let nx = inst_next(user);
    if nx >= 0 && iop(nx) == OP_PHI { return false; }
    var defc = sf;
    var newc = st;
    if p == P_NE { let t = defc; defc = newc; newc = t; }
    if sel >= 0 {
        rauw(sel, defc);
        scf_erase(sel);
    } else {
        rauw(ici, defc);
    }
    scf_erase(ici);
    var ups: DTUpdate[>..<] = [];
    let nb = create_block_before(block_func(bb), bb, "switch.edge");
    swp_begin(si);
    let hw0, w0 = swp_get_weight(0);
    var neww: u64 = 0;
    if hw0 {
        neww = (w0 + 1) >> 1;
        swp_set_weight(si, 0, true, neww);
    }
    swp_add_case(si, ncv, nb, hw0, neww);
    if cu_dtu { cu_upd(ups, DT_INSERT, pred, nb); }
    swp_end();
    sb_set_end(nb);
    sb_dl = inst_get_md(si, MDK_DBG_SC);
    sb_br(succ);
    phi_add_incoming(user, newc, nb);
    if cu_dtu {
        cu_upd(ups, DT_INSERT, nb, succ);
        dtu_apply_updates(ups);
    }
    return true;
}

// tryToMergeLandingPad
fn try_to_merge_landing_pad(lpad: i32, bi: i32, bb: i32) -> bool {
    let succ = cu_unique_succ(bb);
    if iop(block_first(succ)) == OP_PHI { return false; }
    var others: i32[>..<] = [];
    cu_preds(succ, others);
    for other in others {
        if other == bb { continue; }
        let i = block_first(other);
        if iop(i) != OP_LANDINGPAD || !cu_identical(i, lpad) { continue; }
        let b2 = inst_next(i);
        if b2 < 0 || iop(b2) != OP_BR || !cu_identical(b2, bi) { continue; }
        var ups: DTUpdate[>..<] = [];
        var upreds: i32[>..<] = [];
        each_pred(bb) { p => cu_push_unique(upreds, p); };
        for p in upreds {
            let ii = block_terminator(p);
            set_op(ii, nops(ii) - 2, other);
            if cu_dtu { cu_upd(ups, DT_INSERT, p, other); cu_upd(ups, DT_DELETE, p, bb); }
        }
        var usuccs: i32[>..<] = [];
        var ss: i32[>..<] = [];
        cu_succs(bb, ss);
        for s in ss { cu_push_unique(usuccs, s); }
        for s in usuccs {
            block_remove_predecessor(s, bb, false);
            if cu_dtu { cu_upd(ups, DT_DELETE, bb, s); }
        }
        sb_at(bi);
        sb_unreachable();
        scf_erase(bi);
        cu_apply(ups);
        return true;
    }
    return false;
}

fn simplify_uncond_branch(bi: i32) -> bool {
    let bb = inst_parent(bi);
    let succ = op(bi, 0);
    let need_canon = so.keep_loops && scf_loop_headers.len > 0 && cu_has_n_preds_or_more(bb, 2) &&
                     (scf_is_loop_header(bb) || scf_is_loop_header(succ));
    var i = first_non_phi(bb);
    if is_terminator(i) && !cu_is_entry(bb) && !need_canon && cu_try_simplify_uncond_branch_from_empty_block(bb) { return true; }
    if is_icmp(i) {
        let p = inst_pred(i);
        if (p == P_EQ || p == P_NE) && vals[op(i, 1)].kind == VK_CINT {
            let ici = i;
            let n = inst_next(i);
            if is_terminator(n) && try_simplify_uncond_with_icmp_select(ici, -1) { return true; }
            if is_inst(n) && iop(n) == OP_SELECT && is_terminator(inst_next(n)) && try_simplify_uncond_with_icmp_select(ici, n) { return true; }
        }
    }
    if iop(i) == OP_LANDINGPAD {
        let n = inst_next(i);
        if is_terminator(n) && try_to_merge_landing_pad(i, bi, bb) { return true; }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Conditional branches

fn all_preds_from_same_source(bb: i32) -> i32 {
    var pp: i32 = -1;
    var ok = true;
    each_pred(bb) { p =>
        if ok {
            let ppred = single_pred(p);
            if ppred < 0 || (pp >= 0 && pp != ppred) { ok = false; } else { pp = ppred; }
        }
    };
    return if ok { pp } else { -1 };
}

// mergeNestedCondBranch
fn merge_nested_cond_branch(bi: i32) -> bool {
    let bb = inst_parent(bi);
    let bb1 = br_succ(bi, 0);
    let bb2 = br_succ(bi, 1);
    fn simple_succ(s: i32) -> i32 {
        if s == bb { return -1; }
        let t = block_terminator(s);
        if block_first(s) != t { return -1; }
        if iop(t) != OP_CONDBR { return -1; }
        let s1 = br_succ(t, 0);
        let s2 = br_succ(t, 1);
        if s1 != s && s2 != s && s1 != bb && s2 != bb && iop(block_first(s1)) != OP_PHI && iop(block_first(s2)) != OP_PHI { return t; }
        return -1;
    }
    let b1 = simple_succ(bb1);
    if b1 < 0 { return false; }
    let b2 = simple_succ(bb2);
    if b2 < 0 { return false; }
    if br_cond(b1) != br_cond(b2) || br_succ(b1, 0) != br_succ(b2, 1) || br_succ(b1, 1) != br_succ(b2, 0) { return false; }
    let bb3 = br_succ(b1, 0);
    let bb4 = br_succ(b1, 1);
    sb_at(bi);
    br_set_cond(bi, sb_binop(OP_XOR, br_cond(bi), br_cond(b1), ""));
    block_remove_predecessor(bb1, bb, false);
    br_set_succ(bi, 0, bb4);
    block_remove_predecessor(bb2, bb, false);
    br_set_succ(bi, 1, bb3);
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        cu_upd(ups, DT_DELETE, bb, bb1);
        cu_upd(ups, DT_INSERT, bb, bb4);
        cu_upd(ups, DT_DELETE, bb, bb2);
        cu_upd(ups, DT_INSERT, bb, bb3);
        dtu_apply_updates(ups);
    }
    var hw = false;
    var ok, bt, bf = pd_extract2(bi);
    if ok { hw = true; } else { bt = 1; bf = 1; }
    var ok1, b1t, b1f = pd_extract2(b1);
    if ok1 { hw = true; } else { b1t = 1; b1f = 1; }
    var ok2, b2t, b2f = pd_extract2(b2);
    if ok2 { hw = true; } else { b2t = 1; b2f = 1; }
    if hw {
        let w: u64[2] = [bt * b1f + bf * b2t, bt * b1t + bf * b2f];
        pd_set_fitted(bi, w, false, true);
    }
    return true;
}

fn simplify_cond_branch(bi: i32) -> bool {
    let bb = inst_parent(bi);
    if !so.simplify_condbr || func_has_fn_attr(block_func(bb), AK_OptForFuzzing) { return false; }
    if is_value_equality_comparison(bi) >= 0 {
        let only = single_pred(bb);
        if only >= 0 && simplify_eq_cmp_with_only_pred(bi, only) { return scf_request_resimplify(); }
        var i = block_first(bb);
        while i >= 0 {
            if inst_iid(i) == IID_pseudoprobe || i == br_cond(bi) { i = inst_next(i); continue; }
            if i == bi { if fold_value_cmp_into_preds(bi) { return scf_request_resimplify(); } }
            break;
        }
    }
    if simplify_branch_on_icmp_chain(bi) { return true; }
    // isImpliedByDomCondition(BI->getCondition(), BI, DL)
    let imp = scf_implied_by_dom_condition(br_cond(bi), bi);
    if imp >= 0 {
        let old = br_cond(bi);
        br_set_cond(bi, if imp == 1 { scf_true() } else { scf_false() });
        cu_recursively_delete_dead(old);
        return scf_request_resimplify();
    }
    if so.spec_blocks && fold_branch_to_common_dest(bi, true, so.bonus) { return scf_request_resimplify(); }
    let s0 = br_succ(bi, 0);
    let s1 = br_succ(bi, 1);
    if single_pred(s0) >= 0 {
        if single_pred(s1) >= 0 {
            if cl_hoist_common && hoist_common_code_from_successors(bi, !so.hoist_common) { return scf_request_resimplify(); }
            if so.hoist_ldst_cf && is_profitable_to_speculate(bi, -1) {
                var cls: i32[>..<] = [];
                var can = true;
                var ss: i32[>..<] = [];
                cu_succs(bb, ss);
                for s in ss {
                    var x = block_first(s);
                    while x >= 0 && can {
                        if is_terminator(x) { if term_nsucc(x) > 1 { can = false; } }
                        else if !is_safe_cheap_load_store(x) || cls.len == cl_hoist_ldst_cf_threshold { can = false; }
                        else { cls.push(x); }
                        x = inst_next(x);
                    }
                }
                if can && cls.len > 0 { scf_not_ported("hoisting conditional loads/stores (conditional faulting)"); }
            }
        } else {
            let t0 = block_terminator(s0);
            if term_nsucc(t0) == 1 && term_succ(t0, 0) == s1 {
                if speculatively_execute_bb(bi, s0) { return scf_request_resimplify(); }
            }
        }
    } else if single_pred(s1) >= 0 {
        let t1 = block_terminator(s1);
        if term_nsucc(t1) == 1 && term_succ(t1, 0) == s0 {
            if speculatively_execute_bb(bi, s1) { return scf_request_resimplify(); }
        }
    }
    if fold_cond_branch_on_value_known_in_pred(bi) { return scf_request_resimplify(); }
    var preds: i32[>..<] = [];
    cu_preds(bb, preds);
    for p in preds {
        let pbi = block_terminator(p);
        if iop(pbi) == OP_CONDBR && pbi != bi {
            if simplify_cond_branch_to_cond_branch(pbi, bi) { return scf_request_resimplify(); }
        }
    }
    if cl_merge_cond_stores {
        let prev = all_preds_from_same_source(bb);
        if prev >= 0 {
            let pbi = block_terminator(prev);
            if iop(pbi) == OP_CONDBR && pbi != bi && merge_conditional_stores(pbi, bi) { return scf_request_resimplify(); }
        }
    }
    if merge_nested_cond_branch(bi) { return scf_request_resimplify(); }
    return false;
}

// isImpliedByDomCondition(Cond, ContextI, DL): 1 true, 0 false, -1 unknown
fn scf_implied_by_dom_condition(cond: i32, cxt: i32) -> i64 {
    let bb = inst_parent(cxt);
    let pb = single_pred(bb);
    if pb < 0 { return -1; }
    let t = block_terminator(pb);
    if iop(t) != OP_CONDBR { return -1; }
    let tb = op(t, 1);
    let fb = op(t, 2);
    if tb == fb { return -1; }
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let sk = kb_cxt;
    kb_cxt = -1;
    let r = implied_condition_v(op(t, 0), cond, tb == bb, 0);
    kb_cxt = sk;
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    return r;
}

// ---------------------------------------------------------------------------------------------
// passingValueIsAlwaysUndefined / removeUndefIntroducingPredecessor

// CallBase::paramHasNonNullAttr(ArgNo, AllowUndefOrPoison = false)
fn cb_param_has_nonnull_attr(c: i32, k: i64) -> bool {
    if cb_param_has_attr(c, k, AK_NonNull) && cb_param_has_attr(c, k, AK_NoUndef) { return true; }
    if cb_param_has_attr(c, k, AK_Dereferenceable) && !null_pointer_is_defined(inst_func(c), ptr_as(vals[cb_arg(c, k)].ty)) { return true; }
    return false;
}

recursive fn passing_value_is_always_undefined(v: i32, i: i32, ptr_may_be_modified0: bool) -> bool {
    var ptr_mod = ptr_may_be_modified0;
    if !is_constant(v) { return false; }
    if vals[i].first_use < 0 { return false; }
    if !(is_null_value(v) || is_undef_or_poison(v)) { return false; }
    // the first same-block use after I with a UB-triggering opcode (use-list order)
    var found: i32 = -1;
    var u = first_use(i);
    while u >= 0 {
        let us = uses[u].user;
        if is_inst(us) && inst_parent(us) == inst_parent(i) && us != i && !comes_before(us, i) {
            let o = iop(us);
            if o == OP_GEP || o == OP_RET || o == OP_BITCAST || o == OP_LOAD || o == OP_STORE || o == OP_CALL ||
               o == OP_CALLBR || o == OP_INVOKE || o == OP_UDIV || o == OP_UREM || o == OP_SDIV || o == OP_SREM {
                found = u;
                break;
            }
        }
        u = use_next(u);
    }
    if found < 0 { return false; }
    let user = uses[found].user;
    var x = inst_next(i);
    while x >= 0 && x != user {
        if !guaranteed_to_transfer(x) { return false; }
        x = inst_next(x);
    }
    let uo = iop(user);
    if uo == OP_GEP && op(user, 0) == i {
        if ty_is_vector(vals[user].ty) { return false; }
        var allz = true;
        for k in 1..nops(user) { let ix = op(user, k); if !(is_constant(ix) && is_null_value(ix)) { allz = false; } }
        if !allz && ((insts[inst_of(user)].flags & GEP_INBOUNDS) == 0 || null_pointer_is_defined(inst_func(user), ptr_as(vals[user].ty))) {
            ptr_mod = true;
        }
        return passing_value_is_always_undefined(v, user, ptr_mod);
    }
    if uo == OP_RET {
        let f = inst_func(user);
        let rs = alist_ret(func_attrs(f));
        let has_noundef = aset_has(rs, AK_NoUndef);
        if is_undef_or_poison(v) && has_noundef { return true; }
        if is_null_value(v) && has_noundef && aset_has(rs, AK_NonNull) { return !ptr_mod; }
    }
    if uo == OP_LOAD && !inst_is_volatile(user) {
        return !null_pointer_is_defined(inst_func(user), ptr_as(vals[op(user, 0)].ty));
    }
    if uo == OP_STORE && !inst_is_volatile(user) {
        return !null_pointer_is_defined(inst_func(user), ptr_as(vals[op(user, 1)].ty)) && op(user, 1) == i;
    }
    if uo == OP_CALL && inst_iid(user) == IID_assume {
        if i == cb_arg(user, 0) { return true; }
    }
    if uo == OP_CALL || uo == OP_INVOKE || uo == OP_CALLBR {
        if is_null_value(v) && null_pointer_is_defined(inst_func(user), 0) { return false; }
        if cb_callee(user) == i { return true; }
        let ui = found - vals[user].ops;
        if (ui as i64) < cb_nargs(user) {
            let k = ui as i64;
            if vals[v].kind == VK_CNULL && ty_kind(vals[v].ty) == TK_PTR && cb_param_has_nonnull_attr(user, k) { return !ptr_mod; }
            if is_undef_or_poison(v) && cb_is_passing_undef_ub(user, k) { return true; }
        }
    }
    if is_binary_op(uo) && op(user, 1) == i && (uo == OP_UDIV || uo == OP_SDIV || uo == OP_UREM || uo == OP_SREM) { return true; }
    return false;
}

fn remove_undef_introducing_predecessor(bb: i32) -> bool {
    var p = block_first(bb);
    while p >= 0 && iop(p) == OP_PHI {
        let phi = p;
        p = inst_next(p);
        for k in nops(phi) {
            if !passing_value_is_always_undefined(phi_value(phi, k), phi, false) { continue; }
            let pred = phi_block(phi, k);
            let t = block_terminator(pred);
            sb_at(t);
            if iop(t) == OP_BR {
                block_remove_predecessor(bb, pred, false);
                sb_unreachable();
                scf_erase(t);
                cu_apply1(DT_DELETE, pred, bb);
                return true;
            }
            if iop(t) == OP_CONDBR {
                block_remove_predecessor(bb, pred, false);
                let c = br_cond(t);
                if br_succ(t, 0) == bb { sb_assume(sb_not(c, "")); } else { sb_assume(c); }
                ac_invalidate();
                sb_br(if br_succ(t, 0) == bb { br_succ(t, 1) } else { br_succ(t, 0) });
                scf_erase(t);
                cu_apply1(DT_DELETE, pred, bb);
                return true;
            }
            if iop(t) == OP_SWITCH {
                let un = create_block_before(block_func(bb), bb, "unreachable");
                sb_set_end(un);
                sb_unreachable();
                for j in sw_ncases(t) {
                    if sw_case_dest(t, j) == bb {
                        block_remove_predecessor(bb, pred, false);
                        set_op(t, 3 + 2 * j, un);
                    }
                }
                if sw_default(t) == bb {
                    block_remove_predecessor(bb, pred, false);
                    set_op(t, 1, un);
                }
                if cu_dtu {
                    var ups: DTUpdate[>..<] = [];
                    cu_upd(ups, DT_INSERT, pred, un);
                    cu_upd(ups, DT_DELETE, pred, bb);
                    dtu_apply_updates(ups);
                }
                return true;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Resume, cleanupret, unreachable

fn is_cleanup_block_empty(from: i32, to: i32) -> bool {
    var i = from;
    while i >= 0 && i != to {
        let id = inst_iid(i);
        if id == 0 { return false; }
        if !(id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_lifetime_end) { return false; }
        i = inst_next(i);
    }
    return true;
}

fn simplify_resume(ri: i32) -> bool {
    let v = op(ri, 0);
    if is_inst(v) && iop(v) == OP_PHI { return simplify_common_resume(ri); }
    let fnp = first_non_phi(inst_parent(ri));
    if iop(fnp) == OP_LANDINGPAD && v == fnp { return simplify_single_resume(ri); }
    return false;
}

fn simplify_common_resume(ri: i32) -> bool {
    let bb = inst_parent(ri);
    if !is_cleanup_block_empty(first_non_phi(bb), block_terminator(bb)) { return false; }
    var trivial: i32[>..<] = [];
    let phi = op(ri, 0);
    for k in nops(phi) {
        let ib = phi_block(phi, k);
        let iv = phi_value(phi, k);
        if cu_unique_succ(ib) != bb { continue; }
        let lp = first_non_phi(ib);
        if iop(lp) != OP_LANDINGPAD || iv != lp { continue; }
        if is_cleanup_block_empty(inst_next(lp), block_terminator(ib)) { cu_push_unique(trivial, ib); }
    }
    if trivial.len == 0 { return false; }
    for tb in trivial {
        while phi_block_index(phi, tb) != -1 { block_remove_predecessor(bb, tb, true); }
        var preds: i32[>..<] = [];
        cu_preds(tb, preds);
        for p in preds { cu_remove_unwind_edge(p); }
        scf_erase(block_terminator(tb));
        block_append_inst(tb, create_inst(OP_UNREACHABLE, T_VOID, []));
        cu_apply1(DT_DELETE, tb, bb);
    }
    if cu_pred_empty(bb) { cu_delete_dead_block(bb); }
    return true;
}

fn simplify_single_resume(ri: i32) -> bool {
    let bb = inst_parent(ri);
    let lp = first_non_phi(bb);
    if !is_cleanup_block_empty(inst_next(lp), ri) { return false; }
    var preds: i32[>..<] = [];
    cu_preds(bb, preds);
    for p in preds { cu_remove_unwind_edge(p); }
    cu_delete_dead_block(bb);
    return true;
}

fn cleanupret_unwind_dest(ri: i32) -> i32 { if nops(ri) >= 2 { op(ri, 1) } else { -1 } }

// removeEmptyCleanup
fn remove_empty_cleanup(ri: i32) -> bool {
    let bb = inst_parent(ri);
    let cp = op(ri, 0);
    if !is_inst(cp) || inst_parent(cp) != bb { return false; }
    if !has_one_use(cp) { return false; }
    if !is_cleanup_block_empty(inst_next(cp), ri) { return false; }
    let ud = cleanupret_unwind_dest(ri);
    if ud >= 0 {
        var p = block_first(ud);
        while p >= 0 && iop(p) == OP_PHI {
            let dpn = p;
            p = inst_next(p);
            let idx = phi_block_index(dpn, bb);
            let sv = phi_value(dpn, idx);
            let need = is_inst(sv) && iop(sv) == OP_PHI && inst_parent(sv) == bb;
            var preds: i32[>..<] = [];
            cu_preds(bb, preds);
            for pr in preds {
                let inc = if need { phi_value_for_block(sv, pr) } else { sv };
                phi_add_incoming(dpn, inc, pr);
            }
        }
        let ins_pt = first_non_phi(ud);
        var q = block_first(bb);
        while q >= 0 && iop(q) == OP_PHI {
            let pn = q;
            q = inst_next(q);
            if vals[pn].first_use < 0 || !scf_is_used_outside_of_block(pn, bb) { continue; }
            var ups2: i32[>..<] = [];
            cu_preds(ud, ups2);
            for pr in ups2 { if pr != bb { phi_add_incoming(pn, pn, pr); } }
            inst_move_before(pn, ins_pt);
            phi_add_incoming(pn, c_poison(vals[pn].ty), bb);
        }
    }
    var ups: DTUpdate[>..<] = [];
    var preds2: i32[>..<] = [];
    cu_preds(bb, preds2);
    for pb in preds2 {
        if ud < 0 {
            if cu_dtu { dtu_apply_updates(ups); ups.clear(); }
            cu_remove_unwind_edge(pb);
        } else {
            block_remove_predecessor(bb, pb, false);
            let ti = block_terminator(pb);
            for k in nops(ti) { if op(ti, k) == bb { set_op(ti, k, ud); } }
            if cu_dtu { cu_upd(ups, DT_INSERT, pb, ud); cu_upd(ups, DT_DELETE, pb, bb); }
        }
    }
    cu_apply(ups);
    cu_delete_dead_block(bb);
    return true;
}

// Instruction::isUsedOutsideOfBlock
fn scf_is_used_outside_of_block(i: i32, bb: i32) -> bool {
    var u = first_use(i);
    while u >= 0 {
        let us = uses[u].user;
        if iop(us) == OP_PHI { if use_aux[u] != bb { return true; } }
        else if inst_parent(us) != bb { return true; }
        u = use_next(u);
    }
    return false;
}

// mergeCleanupPad
fn merge_cleanup_pad(ri: i32) -> bool {
    let ud = cleanupret_unwind_dest(ri);
    if ud < 0 { return false; }
    if single_pred(ud) != inst_parent(ri) { return false; }
    let scp = block_first(ud);
    if iop(scp) != OP_CLEANUPPAD { return false; }
    let pcp = op(ri, 0);
    rauw(scp, pcp);
    scf_erase(scp);
    block_append_inst(inst_parent(ri), create_inst(OP_BR, T_VOID, [ud]));
    scf_erase(ri);
    return true;
}

fn simplify_cleanup_return(ri: i32) -> bool {
    if is_undef_or_poison(op(ri, 0)) { return false; }
    if merge_cleanup_pad(ri) { return true; }
    if remove_empty_cleanup(ri) { return true; }
    return false;
}

fn simplify_unreachable(ui: i32) -> bool {
    let bb = inst_parent(ui);
    var changed = false;
    if inst_first_dbg(ui) >= 0 { scf_not_ported("debug records on unreachable"); }
    loop {
        let prev = inst_prev(ui);
        if prev < 0 { break; }
        if !guaranteed_to_transfer(prev) { break; }
        if inst_first_dbg(prev) >= 0 { scf_not_ported("dropping debug records before unreachable"); }
        rauw(prev, c_poison(vals[prev].ty));
        scf_erase(prev);
        changed = true;
    }
    if block_first(bb) != ui { return changed; }
    var ups: DTUpdate[>..<] = [];
    var preds: i32[>..<] = [];
    each_pred(bb) { p => cu_push_unique(preds, p); };
    for pred in preds {
        let ti = block_terminator(pred);
        sb_at(ti);
        let o = iop(ti);
        if o == OP_BR {
            inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), ti);
            scf_erase(ti);
            changed = true;
            if cu_dtu { cu_upd(ups, DT_DELETE, pred, bb); }
        } else if o == OP_CONDBR {
            if br_succ(ti, 0) == br_succ(ti, 1) {
                inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), ti);
                scf_erase(ti);
                changed = true;
            } else {
                let c = br_cond(ti);
                if br_succ(ti, 0) == bb {
                    sb_assume(sb_not(c, ""));
                    sb_br(br_succ(ti, 1));
                } else {
                    sb_assume(c);
                    sb_br(br_succ(ti, 0));
                }
                ac_invalidate();
                erase_terminator_and_dce_cond(ti);
                changed = true;
            }
            if cu_dtu { cu_upd(ups, DT_DELETE, pred, bb); }
        } else if o == OP_SWITCH {
            swp_begin(ti);
            var k: i64 = 0;
            while k < sw_ncases(ti) {
                if sw_case_dest(ti, k) != bb { k++; continue; }
                block_remove_predecessor(bb, pred, false);
                swp_remove_case(ti, k);
                changed = true;
            }
            swp_end();
            if cu_dtu && sw_default(ti) != bb { cu_upd(ups, DT_DELETE, pred, bb); }
        } else if o == OP_INVOKE {
            if invoke_unwind_dest(ti) == bb {
                if cu_dtu { dtu_apply_updates(ups); ups.clear(); }
                let ci = cu_remove_unwind_edge(pred);
                if !call_has_fn_attr(ci, AK_NoUnwind) { scf_set_does_not_throw(ci); }
                changed = true;
            }
        } else if o == OP_CATCHSWITCH {
            let csi = ti;
            let has_ud = (insts[inst_of(csi)].bits & 1) != 0;
            if has_ud && op(csi, 1) == bb {
                if cu_dtu { dtu_apply_updates(ups); ups.clear(); }
                cu_remove_unwind_edge(pred);
                changed = true;
                continue;
            }
            let first = if has_ud { 2 } else { 1 };
            var k = first;
            while k < nops(csi) {
                if op(csi, k) == bb { cu_catchswitch_remove_handler(csi, k); changed = true; continue; }
                k++;
            }
            if cu_dtu { cu_upd(ups, DT_DELETE, pred, bb); }
            if nops(csi) == first {
                if has_ud {
                    let cud = op(csi, 1);
                    if cu_dtu {
                        var pp: i32[>..<] = [];
                        cu_preds(pred, pp);
                        for x in pp { cu_upd(ups, DT_INSERT, x, cud); cu_upd(ups, DT_DELETE, x, pred); }
                    }
                    cu_block_rauw(pred, cud);
                } else {
                    if cu_dtu { dtu_apply_updates(ups); ups.clear(); }
                    var ehp: i32[>..<] = [];
                    cu_preds(pred, ehp);
                    for x in ehp { cu_remove_unwind_edge(x); }
                }
                inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), csi);
                if vals[csi].first_use >= 0 { scf_not_ported("erasing a catchswitch that still has uses"); }
                scf_erase(csi);
                changed = true;
            }
        } else if o == OP_CLEANUPRET {
            if cu_dtu { cu_upd(ups, DT_DELETE, pred, bb); }
            inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), ti);
            scf_erase(ti);
            changed = true;
        }
    }
    cu_apply(ups);
    if cu_pred_empty(bb) && !cu_is_entry(bb) {
        cu_delete_dead_block(bb);
        return true;
    }
    return changed;
}

// CallBase::setDoesNotThrow: add nounwind to the call site's function attributes
fn scf_set_does_not_throw(c: i32) {
    let ii = inst_of(c);
    let l = insts[ii].attrs;
    var fnset = alist_fn(l);
    var xs: i32[>..<] = [];
    for k in aset_n(fnset) { xs.push(aset_attr(fnset, k)); }
    xs.push(attr_enum(AK_NoUnwind));
    let ns = aset_get(xs);
    var sets: i32[>..<] = [];
    let n = alists[l].n as i64;
    sets.push(ns);
    for k in 1..max(n, 1) { sets.push(alist_runs[alists[l].at + k]); }
    insts[ii].attrs = alist_get(sets);
}

// ---------------------------------------------------------------------------------------------
// Terminators on selects

fn simplify_terminator_on_select(old: i32, cond: i32, tbb: i32, fbb: i32, tw: u64, fw: u64) -> bool {
    let bb = inst_parent(old);
    var keep1 = tbb;
    var keep2 = if tbb != fbb { fbb } else { -1 };
    var removed: i32[>..<] = [];
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs {
        if s == keep1 { keep1 = -1; }
        else if s == keep2 { keep2 = -1; }
        else {
            block_remove_predecessor(s, bb, true);
            if s != tbb && s != fbb { cu_push_unique(removed, s); }
        }
    }
    sb_at(old);
    if keep1 < 0 && keep2 < 0 {
        if tbb == fbb { sb_br(tbb); }
        else {
            let nbi = sb_condbr(cond, tbb, fbb);
            let w: u64[2] = [tw, fw];
            pd_set(nbi, w, false, true);
        }
    } else if keep1 >= 0 && (keep2 >= 0 || tbb == fbb) {
        inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), old);
    } else {
        if keep1 < 0 { sb_br(tbb); } else { sb_br(fbb); }
    }
    erase_terminator_and_dce_cond(old);
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        for r in removed { cu_upd(ups, DT_DELETE, bb, r); }
        dtu_apply_updates(ups);
    }
    return true;
}

fn simplify_switch_on_select(si: i32, sel: i32) -> bool {
    let tv = op(sel, 1);
    let fv = op(sel, 2);
    if vals[tv].kind != VK_CINT || vals[fv].kind != VK_CINT || ty_is_vector(vals[tv].ty) { return false; }
    let cond = op(sel, 0);
    let ti = sw_find_case_value(si, tv);
    let fi = sw_find_case_value(si, fv);
    let tbb = if ti < 0 { sw_default(si) } else { sw_case_dest(si, ti) };
    let fbb = if fi < 0 { sw_default(si) } else { sw_case_dest(si, fi) };
    var tw: u64 = 0;
    var fw: u64 = 0;
    if pd_has_branch_weights(si) {
        var ws: u64[>..<] = [];
        get_branch_weights_def_first(si, ws);
        if ws.len == 1 + sw_ncases(si) {
            tw = ws[ti + 1] & 0xFFFFFFFF;
            fw = ws[fi + 1] & 0xFFFFFFFF;
        }
    }
    return simplify_terminator_on_select(si, cond, tbb, fbb, tw, fw);
}

fn simplify_indirectbr_on_select(ibi: i32, sel: i32) -> bool {
    let tba = op(sel, 1);
    let fba = op(sel, 2);
    if vals[tba].kind != VK_BLOCKADDR || vals[fba].kind != VK_BLOCKADDR { return false; }
    let tbb = op(tba, 1);
    let fbb = op(fba, 1);
    var tw: u64 = 0;
    var fw: u64 = 0;
    var ws: u64[>..<] = [];
    if pd_extract(sel, ws) { tw = ws[0]; fw = ws[1]; }
    return simplify_terminator_on_select(ibi, op(sel, 0), tbb, fbb, tw, fw);
}

// ---------------------------------------------------------------------------------------------
// Switch range to icmp

// createUnreachableSwitchDefault
fn create_unreachable_switch_default(si: i32, remove_orig: bool) {
    let bb = inst_parent(si);
    let orig = sw_default(si);
    if remove_orig { block_remove_predecessor(orig, bb, false); }
    let nm = name_plus(bb, ".unreachabledefault");
    let nd = create_block_before(block_func(bb), orig, nm);
    block_append_inst(nd, create_inst(OP_UNREACHABLE, T_VOID, []));
    set_op(si, 1, nd);
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        cu_upd(ups, DT_INSERT, bb, nd);
        if remove_orig && !cu_is_succ(bb, orig) { cu_upd(ups, DT_DELETE, bb, orig); }
        dtu_apply_updates(ups);
    }
}

// sort descending by unsigned value (array_pod_sort with constantIntSortPredicate)
fn sort_cases_desc(xs: i32[>..<]&) { sort(xs) { a, b => ap_ult(ci_ap(b), ci_ap(a)) }; }

// findContiguousCases: (ok, min, max, dest, otherdest, cases_is_a)
fn find_contiguous_cases(cond: i32, cases: i32[>..<]&, other: i32[>..<]&, dest: i32, odest: i32) -> bool, i32, i32, i32, i32, bool {
    sort_cases_desc(cases);
    let mn = ci_ap(cases[cases.len - 1]);
    let mx = ci_ap(cases[0]);
    let off = ap_sub(mx, mn);
    if ap_eq_u64(off, (cases.len - 1) as u64) {
        return true, cases[cases.len - 1], cases[0], dest, odest, true;
    }
    let save = kb_cxt;
    kb_cxt = -1;
    let s1 = sq_no_dt; let s2 = sq_no_ac;
    sq_no_dt = true; sq_no_ac = true;
    let cr = compute_constant_range(cond, false, true, 0);
    sq_no_dt = s1; sq_no_ac = s2;
    kb_cxt = save;
    if ap_eq(mx, rg_umax(cr)) && ap_eq(mn, rg_umin(cr)) {
        var it: i64 = -1;
        for k in cases.len - 1 {
            if !ap_eq(ci_ap(cases[k]), ap_inc(ci_ap(cases[k + 1]))) { it = k; break; }
        }
        if it < 0 { return false, -1, -1, -1, -1, true; }
        let omax = ci_ap(cases[it]);
        let omin = ci_ap(cases[it + 1]);
        if ap_eq_u64(ap_add(ap_sub(mx, omax), ap_sub(omin, mn)), (cases.len - 2) as u64) {
            let ty = vals[cases[0]].ty;
            return true, c_int_ap(ty, ap_inc(omin)), c_int_ap(ty, ap_dec(omax)), odest, dest, false;
        }
    }
    return false, -1, -1, -1, -1, true;
}

fn turn_switch_range_into_icmp(si: i32) -> bool {
    let has_default = !cu_default_dest_unreachable(si);
    let bb = inst_parent(si);
    var desta = if has_default { sw_default(si) } else { -1 };
    var destb: i32 = -1;
    var casesa: i32[>..<] = [];
    var casesb: i32[>..<] = [];
    for k in sw_ncases(si) {
        let d = sw_case_dest(si, k);
        if desta < 0 { desta = d; }
        if d == desta { casesa.push(sw_case_val(si, k)); continue; }
        if destb < 0 { destb = d; }
        if d == destb { casesb.push(sw_case_val(si, k)); continue; }
        return false;
    }
    if destb < 0 { return false; }
    var ok = false;
    var mn: i32 = -1;
    var mx: i32 = -1;
    var dest: i32 = -1;
    var odest: i32 = -1;
    var cases_is_a = true;     // which list is Cases (the other is OtherCases)
    if !has_default && casesa.len == 1 {
        ok = true; mn = casesa[0]; mx = casesa[0]; dest = desta; odest = destb; cases_is_a = true;
    } else if casesb.len == 1 {
        ok = true; mn = casesb[0]; mx = casesb[0]; dest = destb; odest = desta; cases_is_a = false;
    } else if !has_default {
        let r, a, b, c, d, first = find_contiguous_cases(op(si, 0), casesa, casesb, desta, destb);
        if r { ok = true; mn = a; mx = b; dest = c; odest = d; cases_is_a = first; }
    }
    if !ok {
        let r, a, b, c, d, first = find_contiguous_cases(op(si, 0), casesb, casesa, destb, desta);
        if r { ok = true; mn = a; mx = b; dest = c; odest = d; cases_is_a = !first; }
    }
    if !ok { return false; }
    let ncases_cases = if cases_is_a { casesa.len } else { casesb.len };
    let ncases_other = if cases_is_a { casesb.len } else { casesa.len };
    let offset = ce_neg_const(mn);
    let nc = ap_inc(ap_sub(ci_ap(mx), ci_ap(mn)));
    let numcases = c_int_ap(vals[offset].ty, nc);
    sb_at(si);
    var nbi: i32 = -1;
    if ap_is_one(nc) {
        let cmp = sb_icmp(P_EQ, op(si, 0), mn, "");
        nbi = sb_condbr(cmp, dest, odest);
    } else if ap_is_zero(nc) && ncases_cases > 0 {
        nbi = sb_br(dest);
    } else {
        var sub = op(si, 0);
        if !is_null_value(offset) {
            let nm = name_plus(sub, ".off");
            sub = sb_binop(OP_ADD, sub, offset, nm);
        }
        let cmp = sb_icmp(P_ULT, sub, numcases, "switch");
        nbi = sb_condbr(cmp, dest, odest);
    }
    if pd_has_branch_weights(si) && iop(nbi) == OP_CONDBR {
        var ws: u64[>..<] = [];
        get_branch_weights_def_first(si, ws);
        if ws.len == 1 + sw_ncases(si) {
            var tw: u64 = 0;
            var fw: u64 = 0;
            for k in ws.len {
                if term_succ(si, k) == dest { tw += ws[k]; } else { fw += ws[k]; }
            }
            while tw > 0xFFFFFFFF || fw > 0xFFFFFFFF { tw /= 2; fw /= 2; }
            let w2: u64[2] = [tw, fw];
            pd_set_fitted(nbi, w2, false, true);
        }
    }
    var p = block_first(dest);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        var prev = ncases_cases;
        if dest == sw_default(si) { prev++; }
        for k in prev - 1 { phi_remove_incoming_block(p, bb, true); }
        p = np;
    }
    p = block_first(odest);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        var prev = ncases_other;
        if odest == sw_default(si) { prev++; }
        var e = prev - 1;
        if iop(nbi) == OP_BR { e++; }
        for k in e { phi_remove_incoming_block(p, bb, true); }
        p = np;
    }
    if !has_default { create_unreachable_switch_default(si, true); }
    let ud = sw_default(si);
    scf_erase(si);
    if !has_default { cu_apply1(DT_DELETE, bb, ud); }
    return true;
}

// ConstantExpr::getNeg(C) for a ConstantInt
fn ce_neg_const(c: i32) -> i32 { c_int_ap(vals[c].ty, ap_neg(ci_ap(c))) }

// ---------------------------------------------------------------------------------------------
// eliminateDeadSwitchCases

// collectPossibleValues(V, Constants, MaxCount, AllowUndefOrPoison = true)
fn collect_possible_values(v: i32, out: i32[>..<]&, max_count: i64) -> bool {
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    fn push(x: i32) -> bool {
        if m_imm_constant(x) {
            if position(out, x) >= 0 { return true; }
            if out.len == max_count { return false; }
            out.push(x);
            return true;
        }
        if is_inst(x) {
            if cu_push_unique(visited, x) { wl.push(x); }
            return true;
        }
        return false;
    }
    if !push(v) { return false; }
    while wl.len > 0 {
        let cur = wl.pop();
        let o = iop(cur);
        if o == OP_SELECT {
            if !push(op(cur, 1)) { return false; }
            if !push(op(cur, 2)) { return false; }
        } else if o == OP_PHI {
            for k in nops(cur) {
                let iv = phi_value(cur, k);
                if iv == cur { continue; }
                if !push(iv) { return false; }
            }
        } else { return false; }
    }
    return true;
}

// DataLayout::fitsInLegalInteger
fn dl_fits_in_legal_integer(w: i64) -> bool {
    for n in dl_native { if n >= w { return true; } }
    return false;
}

fn eliminate_dead_switch_cases(si: i32) -> bool {
    let cond = op(si, 0);
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    sq_no_dt = true; sq_no_ac = false; sq_no_tli = true;
    ac_invalidate();
    let save = kb_cxt;
    kb_cxt = si;
    let known = kb_compute_all(cond, 0);
    var kvals: i32[>..<] = [];
    let kvalid = collect_possible_values(cond, kvals, 4);
    kb_cxt = si;
    let maxsig = ty_scalar_bits(vals[cond].ty) - num_sign_bits(cond, 0) + 1;
    kb_cxt = save;
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    var dead: i32[>..<] = [];
    var us_b: i32[>..<] = [];
    var us_n: i64[>..<] = [];
    for k in sw_ncases(si) {
        let succ = sw_case_dest(si, k);
        if cu_dtu {
            let j = position(us_b, succ);
            if j < 0 { us_b.push(succ); us_n.push(1); } else { us_n[j] += 1; }
        }
        let cc = sw_case_val(si, k);
        let cv = ci_ap(cc);
        if ap_intersects(known.z, cv) || !ap_is_subset_of(known.o, cv) || ap_sig_bits(cv) > maxsig ||
           (kvalid && position(kvals, cc) < 0) {
            dead.push(cc);
            if cu_dtu { let j = position(us_b, succ); us_n[j] -= 1; }
        } else if kvalid {
            let j = position(kvals, cc);
            if j >= 0 { kvals.remove_at(j); }
        }
    }
    let has_default = !cu_default_dest_unreachable(si);
    let nunknown = kb_bw(known) - ap_popcount(ap_or(known.z, known.o));
    if has_default && dead.len == 0 {
        if kvalid {
            var all_undef = true;
            for x in kvals { if !is_undef_or_poison(x) { all_undef = false; } }
            if all_undef {
                create_unreachable_switch_default(si, true);
                return true;
            }
        }
        if nunknown < 64 {
            let all = (1 as u64) << nunknown;
            if sw_ncases(si) as u64 == all {
                create_unreachable_switch_default(si, true);
                return true;
            }
            if sw_ncases(si) as u64 == all - 1 {
                let w = ty_bits(vals[cond].ty);
                if w > 64 || !dl_fits_in_legal_integer(w) { return false; }
                var missing: u64 = 0;
                for k in sw_ncases(si) { missing ^= ap_limited(ci_ap(sw_case_val(si, k)), 0xFFFFFFFFFFFFFFFF); }
                let mc = c_int_ty(vals[cond].ty, missing);
                swp_begin(si);
                let hw, w0 = swp_get_weight(0);
                swp_add_case(si, mc, sw_default(si), hw, w0);
                create_unreachable_switch_default(si, false);
                swp_set_weight(si, 0, true, 0);
                swp_end();
                return true;
            }
        }
    }
    if dead.len == 0 { return false; }
    swp_begin(si);
    for dc in dead {
        let k = sw_find_case_value(si, dc);
        block_remove_predecessor(sw_case_dest(si, k), inst_parent(si), false);
        swp_remove_case(si, k);
    }
    swp_end();
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        for j in us_b.len { if us_n[j] == 0 { cu_upd(ups, DT_DELETE, inst_parent(si), us_b[j]); } }
        dtu_apply_updates(ups);
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// forwardSwitchConditionToPHI

fn find_phi_for_condition_forwarding(cv: i32, bb: i32) -> i32, i64 {
    if first_non_phi(bb) != block_terminator(bb) { return -1, -1; }
    if single_pred(bb) < 0 { return -1, -1; }
    let br = block_terminator(bb);
    if iop(br) != OP_BR { return -1, -1; }
    let succ = op(br, 0);
    var p = block_first(succ);
    while p >= 0 && iop(p) == OP_PHI {
        let idx = phi_block_index(p, bb);
        if phi_value(p, idx) == cv { return p, idx; }
        p = inst_next(p);
    }
    return -1, -1;
}

fn forward_switch_condition_to_phi(si: i32) -> bool {
    let sbb = inst_parent(si);
    var changed = false;
    var fwd_phi: i32[>..<] = [];     // ForwardingNodes: DenseMap<PHINode*, SmallVector<int>>
    var fwd_idx: i64[>..<] = [];     // (phi slot, index) flattened by fwd_owner
    var fwd_owner: i64[>..<] = [];
    for k in sw_ncases(si) {
        let cv = sw_case_val(si, k);
        let cd = sw_case_dest(si, k);
        var p = block_first(cd);
        while p >= 0 && iop(p) == OP_PHI {
            let idx = phi_block_index(p, sbb);
            var cnt = 0;
            for j in nops(p) { if phi_block(p, j) == sbb { cnt++; } }
            if phi_value(p, idx) == cv && cnt == 1 {
                set_op(p, idx, op(si, 0));
                changed = true;
            }
            p = inst_next(p);
        }
        let phi, pidx = find_phi_for_condition_forwarding(cv, cd);
        if phi >= 0 {
            var j = position(fwd_phi, phi);
            if j < 0 { fwd_phi.push(phi); j = fwd_phi.len - 1; }
            fwd_owner.push(j);
            fwd_idx.push(pidx);
        }
    }
    // DenseMap iteration order: the result doesn't depend on it (each PHI is independent)
    for j in fwd_phi.len {
        let phi = fwd_phi[j];
        var idxs: i64[>..<] = [];
        for k in fwd_owner.len { if fwd_owner[k] == j as i64 { idxs.push(fwd_idx[k]); } }
        var contains = false;
        for k in nops(phi) { if phi_value(phi, k) == op(si, 0) { contains = true; } }
        if idxs.len < 2 && !contains { continue; }
        for ix in idxs { set_op(phi, ix, op(si, 0)); }
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Switch to select

// Constant::isThreadDependent / isDLLImportDependent
recursive fn const_thread_or_dllimport_dependent(c: i32, dll: bool) -> bool {
    if vals[c].kind == VK_GVAR {
        let g = globs[glob_of(c)];
        if dll { return g.dll == 1; }
        return g.tls != 0;
    }
    if is_global(c) { if dll { return globs[glob_of(c)].dll == 1; } return false; }
    let k = vals[c].kind;
    if k == VK_CEXPR || k == VK_CARRAY || k == VK_CSTRUCT || k == VK_CVECTOR || k == VK_DSOLOCAL || k == VK_NOCFI || k == VK_PTRAUTH {
        for j in nops(c) { let o = op(c, j); if o >= 0 && is_constant(o) && const_thread_or_dllimport_dependent(o, dll) { return true; } }
    }
    return false;
}

// Value::stripInBoundsConstantOffsets for a constant
fn strip_inbounds_constant_offsets(c0: i32) -> i32 {
    var c = c0;
    loop {
        let o = opcode_of(c);
        if o == OP_GEP {
            if (op_flags(c) & GEP_INBOUNDS) == 0 { return c; }
            for k in 1..nops(c) { if vals[op(c, k)].kind != VK_CINT && !(is_constant(op(c, k)) && is_null_value(op(c, k))) { return c; } }
            c = op(c, 0);
            continue;
        }
        if o == OP_BITCAST || o == OP_ADDRSPACECAST { c = op(c, 0); continue; }
        return c;
    }
}

recursive fn valid_lookup_table_constant(c: i32) -> bool {
    if const_thread_or_dllimport_dependent(c, false) { return false; }
    if const_thread_or_dllimport_dependent(c, true) { return false; }
    let k = vals[c].kind;
    if !(k == VK_CDVECTOR || k == VK_CEXPR || k == VK_CFP || k == VK_CINT || k == VK_CNULL || is_global(c) || k == VK_UNDEF || k == VK_POISON) { return false; }
    if ty_has_scalable(vals[c].ty) { return false; }
    if k == VK_CEXPR {
        let s = strip_inbounds_constant_offsets(c);
        if s == c || !valid_lookup_table_constant(s) { return false; }
    }
    if !tti_should_build_lookup_tables_for_constant(c) { return false; }
    return true;
}

// ConstantPool: (value, constant) pairs
fn lookup_constant(v: i32, pool: i32[>..<]&) -> i32 {
    if is_constant(v) { return v; }
    var k: i64 = 0;
    while k < pool.len { if pool[k] == v { return pool[k + 1]; } k += 2; }
    return -1;
}

fn scf_constant_fold(i: i32, pool: i32[>..<]&) -> i32 {
    if iop(i) == OP_SELECT {
        let a = lookup_constant(op(i, 0), pool);
        if a < 0 { return -1; }
        if is_all_ones_value(a) { return lookup_constant(op(i, 1), pool); }
        if is_null_value(a) { return lookup_constant(op(i, 2), pool); }
        return -1;
    }
    let mark = is_ops.len;
    for k in nops(i) {
        let a = lookup_constant(op(i, k), pool);
        if a < 0 { is_ops.resize(mark); return -1; }
        is_ops.push(a);
    }
    let r = cf_fold_inst_operands(i, mark, nops(i), true);
    is_ops.resize(mark);
    return r;
}

// getCaseResults: returns (ok, CommonDest); results appended to res as (phi, constant) pairs
fn get_case_results(si: i32, case_val: i32, case_dest0: i32, common0: i32, res: i32[>..<]&) -> bool, i32 {
    var pred = inst_parent(si);
    var case_dest = case_dest0;
    var common = common0;
    var pool: i32[>..<] = [];
    pool.push(op(si, 0));
    pool.push(case_val);
    var i = block_first(case_dest);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if is_terminator(cur) {
            if term_nsucc(cur) != 1 || cu_is_special_terminator(cur) { return false, common; }
            pred = case_dest;
            case_dest = term_succ(cur, 0);
        } else {
            let c = if case_val >= 0 || true { scf_constant_fold(cur, pool) } else { -1 };
            if c >= 0 {
                var u = first_use(cur);
                while u >= 0 {
                    let us = uses[u].user;
                    let nu = use_next(u);
                    var ok_use = false;
                    if is_inst(us) && inst_parent(us) == case_dest { ok_use = true; }
                    if !ok_use && is_inst(us) && iop(us) == OP_PHI && use_aux[u] == case_dest { ok_use = true; }
                    if !ok_use { return false, common; }
                    u = nu;
                }
                pool.push(cur);
                pool.push(c);
            } else { break; }
        }
    }
    if common < 0 { common = case_dest; }
    if case_dest != common { return false, common; }
    let start = res.len;
    var p = block_first(common);
    while p >= 0 && iop(p) == OP_PHI {
        let idx = phi_block_index(p, pred);
        if idx >= 0 {
            let cv = lookup_constant(phi_value(p, idx), pool);
            if cv < 0 { return false, common; }
            if !valid_lookup_table_constant(cv) { return false, common; }
            res.push(p);
            res.push(cv);
        }
        p = inst_next(p);
    }
    return res.len > start, common;
}

// SwitchCaseResultVectorTy: unique results with their case lists (ur_res[k], cases (k, case) in ur_case)
var ur_res: i32[>..<];
var ur_owner: i64[>..<];
var ur_case: i32[>..<];

fn ur_cases_of(k: i64, out: i32[>..<]&) {
    out.clear();
    for j in ur_owner.len { if ur_owner[j] == k { out.push(ur_case[j]); } }
}
fn map_case_to_result(cv: i32, r: i32) -> i64 {
    for k in ur_res.len {
        if ur_res[k] == r {
            ur_owner.push(k);
            ur_case.push(cv);
            var n: i64 = 0;
            for o in ur_owner { if o == k { n++; } }
            return n;
        }
    }
    ur_res.push(r);
    ur_owner.push(ur_res.len - 1);
    ur_case.push(cv);
    return 1;
}

// initializeUniqueCases: (ok, PHI, CommonDest, DefaultResult)
fn initialize_unique_cases(si: i32, max_unique: i64) -> bool, i32, i32, i32 {
    ur_res.clear(); ur_owner.clear(); ur_case.clear();
    var phi: i32 = -1;
    var common: i32 = -1;
    for k in sw_ncases(si) {
        let cv = sw_case_val(si, k);
        var res: i32[>..<] = [];
        let ok, c2 = get_case_results(si, cv, sw_case_dest(si, k), common, res);
        common = c2;
        if !ok { return false, phi, common, -1; }
        if res.len > 2 { return false, phi, common, -1; }
        let n = map_case_to_result(cv, res[1]);
        if n > cl_max_switch_cases_per_result { return false, phi, common, -1; }
        if ur_res.len > max_unique { return false, phi, common, -1; }
        if phi < 0 { phi = res[0]; } else if phi != res[0] { return false, phi, common, -1; }
    }
    var dres: i32[>..<] = [];
    let dok, c3 = get_case_results(si, -1, sw_default(si), common, dres);
    common = c3;
    let dr = if dres.len == 2 { dres[1] } else { -1 };
    return dr >= 0 || cu_default_dest_unreachable(si), phi, common, dr;
}

fn fold_switch_to_select(def: i32, cond0: i32, bw: u64[>..<]&) -> i32 {
    var cond = cond0;
    let hbw = bw.len > 0;
    if ur_res.len == 2 {
        var c0: i32[>..<] = [];
        var c1: i32[>..<] = [];
        ur_cases_of(0, c0);
        ur_cases_of(1, c1);
        if c0.len == 1 && c1.len == 1 {
            let first = c0[0];
            let second = c1[0];
            var selv = ur_res[1];
            if def >= 0 {
                let vc = sb_icmp(P_EQ, cond, second, "switch.selectcmp");
                selv = sb_select(vc, ur_res[1], def, "switch.select", -1);
                if is_select(selv) && hbw {
                    let w: u64[2] = [bw[2], (bw[0] + bw[1]) & 0xFFFFFFFF];
                    pd_set(selv, w, false, true);
                }
            }
            let vc2 = sb_icmp(P_EQ, cond, first, "switch.selectcmp");
            let ret = sb_select(vc2, ur_res[0], selv, "switch.select", -1);
            if is_select(ret) && hbw {
                let fp: i64 = if cond >= 0 { 1 } else { 0 };
                let dc = if cond >= 0 { bw[0] } else { 0 };
                let w: u64[2] = [bw[fp], (dc + bw[fp + 1]) & 0xFFFFFFFF];
                pd_set(ret, w, false, true);
            }
            return ret;
        }
    }
    if ur_res.len == 1 && def >= 0 {
        var cvs: i32[>..<] = [];
        ur_cases_of(0, cvs);
        let n = cvs.len;
        fn rest_weights() -> u64 { var s: u64 = 0; for k in 1..bw.len { s += bw[k]; } return s & 0xFFFFFFFF; }
        if n > 0 && (n & (n - 1)) == 0 {
            var minc = cvs[0];
            let w = ty_bits(vals[minc].ty);
            var andm = ap_ones(w);
            for c in cvs {
                if ap_slt(ci_ap(c), ci_ap(minc)) { minc = c; }
                andm = ap_and(andm, ci_ap(c));
            }
            let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
            sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
            let sk = kb_cxt;
            kb_cxt = -1;
            let known = kb_compute_all(cond, 0);
            kb_cxt = sk;
            sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
            if !ap_is_zero(andm) && ap_uge(kb_max(known), andm) {
                let free = kb_max_active_bits(known) - ap_popcount(andm);
                if free == log2_exact_i(n) {
                    let a = sb_binop(OP_AND, cond, c_int_ap(vals[cond].ty, andm), "");
                    let cmp = sb_icmp(P_EQ, a, c_int_ap(vals[a].ty, andm), "");
                    let ret = sb_select(cmp, ur_res[0], def, "", -1);
                    if is_select(ret) && hbw {
                        let ww: u64[2] = [rest_weights(), bw[0]];
                        pd_set(ret, ww, false, true);
                    }
                    return ret;
                }
            }
            var bitmask = ap_zero(w);
            for c in cvs { bitmask = ap_or(bitmask, ap_sub(ci_ap(c), ci_ap(minc))); }
            if ap_popcount(bitmask) == log2_exact_i(n) {
                if !is_null_value(minc) { cond = sb_binop(OP_SUB, cond, minc, ""); }
                let a = sb_binop(OP_AND, cond, c_int_ap(vals[cond].ty, ap_not(bitmask)), "switch.and");
                let cmp = sb_icmp(P_EQ, a, c_null(vals[a].ty), "switch.selectcmp");
                let ret = sb_select(cmp, ur_res[0], def, "", -1);
                if is_select(ret) && hbw {
                    let ww: u64[2] = [rest_weights(), bw[0]];
                    pd_set(ret, ww, false, true);
                }
                return ret;
            }
        }
        if cvs.len == 2 {
            let c1 = sb_icmp(P_EQ, cond, cvs[0], "switch.selectcmp.case1");
            let c2 = sb_icmp(P_EQ, cond, cvs[1], "switch.selectcmp.case2");
            let cmp = sb_binop(OP_OR, c1, c2, "switch.selectcmp");
            let ret = sb_select(cmp, ur_res[0], def, "", -1);
            if is_select(ret) && hbw {
                let ww: u64[2] = [rest_weights(), bw[0]];
                pd_set(ret, ww, false, true);
            }
            return ret;
        }
    }
    return -1;
}
fn log2_exact_i(n: i64) -> i64 { var k = 0; while (1 << k) < n { k++; } return k; }

fn remove_switch_after_select_fold(si: i32, phi: i32, selv: i32) {
    var ups: DTUpdate[>..<] = [];
    let sbb = inst_parent(si);
    let dbb = inst_parent(phi);
    if cu_dtu {
        var isp = false;
        each_pred(dbb) { p => if p == sbb { isp = true; } };
        if !isp { cu_upd(ups, DT_INSERT, sbb, dbb); }
    }
    sb_br(dbb);
    var k = nops(phi);
    // removeIncomingValueIf: keeps the relative order of the rest
    phi_remove_incoming_if_block(phi, sbb);
    phi_add_incoming(phi, selv, sbb);
    var removed: i32[>..<] = [];
    for j in term_nsucc(si) {
        let s = term_succ(si, j);
        if s == dbb { continue; }
        block_remove_predecessor(s, sbb, false);
        if cu_dtu && cu_push_unique(removed, s) { cu_upd(ups, DT_DELETE, sbb, s); }
    }
    scf_erase(si);
    cu_apply(ups);
    k = k;
}

// PHINode::removeIncomingValueIf(Pred): stable compaction of the kept entries
fn phi_remove_incoming_if_block(p: i32, b: i32) {
    let n = nops(p);
    var w: i64 = 0;
    for k in n {
        if phi_block(p, k) == b { continue; }
        if w != k {
            set_op(p, w, op(p, k));
            phi_set_block(p, w, phi_block(p, k));
        }
        w++;
    }
    var k = n;
    while k > w { k--; set_op(p, k, -1); use_aux[vals[p].ops + k] = -1; }
    vals[p].nops = w as i32;
}

fn try_switch_to_select(si: i32) -> bool {
    let cond = op(si, 0);
    let ok, phi, common, def = initialize_unique_cases(si, 2);
    if !ok { return false; }
    sb_at(si);
    var bw: u64[>..<] = [];
    let m = pd_prof(si);
    if pd_is_branch_weight_md(m) { pd_extract_md(m, bw); }
    let selv = fold_switch_to_select(def, cond, bw);
    if selv < 0 { return false; }
    remove_switch_after_select_fold(si, phi, selv);
    return true;
}

// ---------------------------------------------------------------------------------------------
// Switch of powers of two, range reduction, cmp intrinsics, umin

fn is_switch_dense_n(ncases: u64, range: u64, optsize: bool) -> bool {
    let mind: u64 = if optsize { 40 } else { 10 };
    if range >= 0xFFFFFFFFFFFFFFFF / 100 { return false; }
    return ncases * 100 >= range * mind;
}
fn is_switch_dense_vals(xs: i64[>..<]&, optsize: bool) -> bool {
    let diff = (xs[xs.len - 1] as! u64) - (xs[0] as! u64);
    let range = diff + 1;
    if range < diff { return false; }
    return is_switch_dense_n(xs.len as u64, range, optsize);
}
fn dense_range_reduction_shift(xs: i64[>..<]&, base: i64, optsize: bool) -> i64 {
    for v in xs { if v < base { return -1; } }
    var red: i64[>..<] = [];
    var orv: u64 = 0;
    for v in xs {
        let r = (v as! u64) - (base as! u64);
        orv |= r;
        red.push(r as! i64);
    }
    var shift = 0;
    while shift < 64 && ((orv >> shift) & 1) == 0 { shift++; }
    if shift > 0 { for k in red.len { red[k] = ((red[k] as! u64) >> shift) as! i64; } }
    if !is_switch_dense_vals(red, optsize) { return -1; }
    return shift;
}
fn fn_has_opt_size(fv: i32) -> bool { func_has_fn_attr(fv, AK_OptimizeForSize) || func_has_fn_attr(fv, AK_MinSize) }

fn simplify_switch_of_powers_of_two(si: i32) -> bool {
    let cond = op(si, 0);
    let w = ty_bits(vals[cond].ty);
    if w > 64 || !dl_fits_in_legal_integer(w) { return false; }
    // getIntrinsicInstrCost(IntrinsicCostAttributes(cttz, CondTy, {Condition, true})) > 2 * TCC_Basic
    let tru0 = c_true();
    if tti_intrinsic_cost_args(IID_cttz, vals[cond].ty, [cond, tru0], TCK_SIZE_AND_LATENCY) > 2 { return false; }
    if sw_ncases(si) < 4 { return false; }
    var vs: u64[>..<] = [];
    for k in sw_ncases(si) {
        let x = ap_zext64(ci_ap(sw_case_val(si, k)));
        if x != 0 && (x & (x - 1)) == 0 { vs.push(x); } else { return false; }
    }
    sort(vs) { a, b => a < b };
    fn ctz(x: u64) -> u64 { var n: u64 = 0; var y = x; while (y & 1) == 0 { y = y >> 1; n++; } return n; }
    if !is_switch_dense_n(vs.len as u64, ctz(vs[vs.len - 1]) - ctz(vs[0]) + 1, fn_has_opt_size(inst_func(si))) { return false; }
    // Builder.SetInsertPoint(SI): new instructions take the switch's location
    let loc = inst_get_md(si, MDK_DBG_SC);
    let cty = vals[cond].ty;
    if !cu_default_dest_unreachable(si) {
        let popc = scf_new_intrinsic(IID_ctpop, [cty], [cond]);
        inst_insert_before(popc, si);
        if loc >= 0 { inst_set_md(popc, MDK_DBG_SC, loc); }
        let ispow2 = cu_build_icmp_before(P_EQ, popc, c_int_ty(cty, 1), "", si);
        let orig = inst_parent(si);
        let dflt = sw_default(si);
        let split = scf_split_block(orig, si, "");
        let old_term = block_terminator(orig);
        var ws: u64[>..<] = [];
        let has_w = pd_extract(si, ws);
        let bi = create_inst(OP_CONDBR, T_VOID, [ispow2, split, dflt]);
        inst_insert_before(bi, old_term);
        var any_nz = false;
        for x in ws { if x != 0 { any_nz = true; } }
        if has_w && any_nz {
            var den: u64 = 0;
            for x in ws { den += x; }
            let nw1 = ws[0] / 2;
            let nw0 = den - nw1;
            pd_set_fitted(bi, [nw0, nw1], false, false);
            ws[0] = nw1;
            let cden = den - ws[0];
            for k in 1..ws.len {
                // W = NewWeights[0] * static_cast<double>(W) / CasesDenominator, stored into a uint32_t
                let d = (nw0 as f64) * (ws[k] as u32 as f64) / (cden as f64);
                ws[k] = (d as u64) & 0xffffffff;
            }
            var w32: u64[>..<] = [];
            for x in ws { w32.push(x & 0xffffffff); }
            pd_set(si, w32, false, false);
        }
        if loc >= 0 { inst_set_md(bi, MDK_DBG_SC, loc); } else { inst_erase_md(bi, MDK_DBG_SC); }
        scf_erase(old_term);
        add_predecessor_to_block(dflt, orig, split);
        if cu_dtu {
            var ups: DTUpdate[>..<] = [];
            cu_upd(ups, DT_INSERT, orig, dflt);
            dtu_apply_updates(ups);
        }
    }
    for k in sw_ncases(si) {
        let cv = sw_case_val(si, k);
        set_op(si, 2 + 2 * k, c_int_ty(cty, ap_countr_zero(ci_ap(cv)) as u64));
    }
    let tru = c_true();
    let tz = scf_new_intrinsic(IID_cttz, [cty], [cond, tru]);
    inst_insert_before(tz, si);
    if loc >= 0 { inst_set_md(tz, MDK_DBG_SC, loc); }
    set_op(si, 0, tz);
    return true;
}

// CallInst::Create(Intrinsic::getOrInsertDeclaration(M, ID, Types), Args), unattached and unnamed
fn scf_new_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let iv = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(iv)].ty2 = fty;
    return iv;
}

fn reduce_switch_range(si: i32) -> bool {
    let cond = op(si, 0);
    let w = ty_bits(vals[cond].ty);
    if w > 64 || !dl_fits_in_legal_integer(w) { return false; }
    if sw_ncases(si) < 4 { return false; }
    var xs: i64[>..<] = [];
    for k in sw_ncases(si) { xs.push(ap_sext64(ci_ap(sw_case_val(si, k)))); }
    sort(xs) { a, b => a < b };
    let optsize = fn_has_opt_size(inst_func(si));
    if is_switch_dense_vals(xs, optsize) { return false; }
    var base = xs[0];
    var shift = dense_range_reduction_shift(xs, 0, true);
    if shift >= 0 { base = 0; }
    else if base != 0 { shift = dense_range_reduction_shift(xs, base, optsize); }
    if shift < 0 { return false; }
    let ty = vals[cond].ty;
    sb_at(si);
    var sub = cond;
    if base != 0 { sub = sb_binop(OP_SUB, sub, c_int_ap(ty, ap_i64(base, w)), ""); }
    let amt = c_int(ty, w - shift);
    let rot = sb_intrinsic(IID_fshl, [ty], [sub, sub, amt], "");
    for k in nops(si) { if op(si, k) == cond && k == 0 { set_op(si, 0, rot); } }
    for k in sw_ncases(si) {
        let orig = ci_ap(sw_case_val(si, k));
        let s = ap_sub(orig, ap_i64(base, w));
        set_op(si, 2 + 2 * k, c_int_ap(ty, ap_lshr(s, shift)));
    }
    return true;
}

fn simplify_switch_of_cmp_intrinsic(si: i32) -> bool {
    let cmp = op(si, 0);
    let id = inst_iid(cmp);
    if id != IID_scmp && id != IID_ucmp { return false; }
    if !has_one_use(cmp) { return false; }
    var ws: u64[>..<] = [];
    let has_w = pd_extract(si, ws);
    if !has_w { ws.clear(); for q in 4 { ws.push(0); } }
    fn sval(c: i32) -> bool, i64 {
        let x = ci_ap(c);
        if ap_sig_bits(x) > 64 { return false, 0; }
        return true, ap_sext64_checked(x);
    }
    var res: i64 = 0;
    var succ: i32 = -1;
    var other: i32 = -1;
    var sw: u64 = 0;
    var ow: u64 = 0;
    var unr: i32 = -1;
    let n = sw_ncases(si);
    if n == 2 {
        var missing: i64[>..<] = [1, 0, -1];
        succ = sw_default(si);
        sw = ws[0];
        for k in n {
            let ok, v = sval(sw_case_val(si, k));
            if !ok { return false; }
            let p = position(missing, v);
            if p < 0 { return false; }
            missing[p] = missing[missing.len - 1];
            missing.pop();
            let d = sw_case_dest(si, k);
            if other >= 0 && other != d { return false; }
            other = d;
            ow += ws[k + 1];
        }
        res = missing[0];
    } else if n == 3 && cu_default_dest_unreachable(si) {
        unr = sw_default(si);
        for k in n {
            let d = sw_case_dest(si, k);
            let w = ws[k + 1];
            if other < 0 || other == d { other = d; ow += w; }
            else if succ < 0 { succ = d; sw = w; }
            else if succ == d {
                let t = succ; succ = other; other = t;
                let tw = sw; sw = ow; ow = tw;
            } else { return false; }
        }
        for k in n {
            let ok, v = sval(sw_case_val(si, k));
            if !ok || (v != 1 && v != 0 && v != -1) { return false; }
            if sw_case_dest(si, k) == succ { res = v; break; }
        }
    } else {
        return false;
    }
    var pred: i64 = if res == 1 { P_UGT } else if res == 0 { P_EQ } else { P_ULT };
    if id == IID_scmp { pred = if res == 1 { P_SGT } else if res == 0 { P_EQ } else { P_SLT }; }
    let bb = inst_parent(si);
    let ic = cu_build_icmp_before(pred, op(cmp, 0), op(cmp, 1), "", si);
    let br = create_inst(OP_CONDBR, T_VOID, [ic, succ, other]);
    inst_insert_before(br, si);
    let loc = inst_get_md(si, MDK_DBG_SC);
    if loc >= 0 { inst_set_md(br, MDK_DBG_SC, loc); }
    if has_w { pd_set(br, [sw & 0xffffffff, ow & 0xffffffff], false, false); }
    let um = inst_get_md(si, mdk_unpredictable());
    if um >= 0 { inst_set_md(br, mdk_unpredictable(), um); }
    block_remove_predecessor(other, bb, false);
    if unr >= 0 { block_remove_predecessor(unr, bb, false); }
    scf_erase(si);
    scf_erase(cmp);
    if cu_dtu && unr >= 0 {
        var ups: DTUpdate[>..<] = [];
        cu_upd(ups, DT_DELETE, bb, unr);
        dtu_apply_updates(ups);
    }
    return true;
}

fn simplify_switch_when_umin(si: i32) -> bool {
    let c = op(si, 0);
    if !m_minmax(c, 3) { return false; }
    let a = mm_a;
    let k = mm_b;
    if vals[k].kind != VK_CINT || ty_is_vector(vals[k].ty) { return false; }
    var ups: DTUpdate[>..<] = [];
    swp_begin(si);
    let bb = inst_parent(si);
    let kv = ci_ap(k);
    var j: i64 = 0;
    while j < sw_ncases(si) {
        if !ap_ugt(ci_ap(sw_case_val(si, j)), kv) { j++; continue; }
        let dead = sw_case_dest(si, j);
        block_remove_predecessor(dead, bb, false);
        cu_upd(ups, DT_DELETE, bb, dead);
        swp_remove_case(si, j);
    }
    let ci = sw_find_case_value(si, k);
    if !cu_default_dest_unreachable(si) || ci < 0 {
        swp_end();
        if cu_dtu { dtu_apply_updates(ups); }
        return ups.len > 0;
    }
    let unr = sw_default(si);
    swp_replace_default_dest(si, ci);
    swp_remove_case(si, ci);
    set_op(si, 0, a);
    swp_end();
    cu_upd(ups, DT_DELETE, bb, unr);
    if cu_dtu { dtu_apply_updates(ups); }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Duplicate switch arms / predecessors (mergeIdenticalBBs)

fn equal_bb_can_be_merged(bb: i32) -> bool {
    if cu_is_entry(bb) { return false; }
    let bi = block_terminator(bb);
    if iop(bi) != OP_BR { return false; }
    if cu_has_address_taken(bb) || inst_is_eh_pad(block_first(bb)) { return false; }
    if block_first(bb) != block_last(bb) { return false; }
    if cu_pred_empty(bb) { return false; }
    return true;
}

fn equal_bbs(a: i32, b: i32) -> bool {
    let sa = op(block_terminator(a), 0);
    let sb = op(block_terminator(b), 0);
    if sa != sb { return false; }
    var p = block_first(sa);
    while p >= 0 && iop(p) == OP_PHI {
        if phi_value_for_block(p, a) != phi_value_for_block(p, b) { return false; }
        p = inst_next(p);
    }
    return true;
}

fn merge_identical_bbs(cands: const i32[:]) -> bool {
    if cands.len < 2 { return false; }
    var keep: i32[>..<] = [];
    var ups: DTUpdate[>..<] = [];
    var changed = false;
    for bb in cands {
        var found: i32 = -1;
        for kb in keep { if equal_bbs(kb, bb) { found = kb; break; } }
        if found < 0 { keep.push(bb); continue; }
        if found == bb { continue; }
        // RedirectIncomingEdges(Dead = bb, Live = found)
        var dead_preds: i32[>..<] = [];
        each_pred(bb) { p => cu_push_unique(dead_preds, p); };
        if cu_dtu {
            var live_preds: i32[>..<] = [];
            each_pred(found) { p => live_preds.push(p); };
            for p in dead_preds {
                if position(live_preds, p) < 0 { cu_upd(ups, DT_INSERT, p, found); }
                cu_upd(ups, DT_DELETE, p, bb);
            }
        }
        for p in dead_preds { term_replace_successor_with(block_terminator(p), bb, found); }
        changed = true;
    }
    if cu_dtu && ups.len > 0 { dtu_apply_updates(ups); }
    return changed;
}

fn simplify_duplicate_switch_arms(si: i32) -> bool {
    var arms: i32[>..<] = [];
    for k in term_nsucc(si) {
        let s = term_succ(si, k);
        if equal_bb_can_be_merged(s) { cu_push_unique(arms, s); }
    }
    return merge_identical_bbs(arms);
}

fn simplify_duplicate_predecessors(bb: i32) -> bool {
    if bb < 0 || !cu_has_n_preds_or_more(bb, 2) { return false; }
    if so.keep_loops && scf_is_loop_header(bb) { return false; }
    var ps: i32[>..<] = [];
    each_pred(bb) { p => if equal_bb_can_be_merged(p) { cu_push_unique(ps, p); } };
    return merge_identical_bbs(ps);
}

// ---------------------------------------------------------------------------------------------
// simplifySwitch / simplifyIndirectBr

// SwitchReplacement
let SR_SINGLE = 0;
let SR_LINEAR = 1;
let SR_BITMAP = 2;
let SR_TABLE = 3;
struct SwRep { kind: i64, def: i32, vty: i32, single: i32, bitmap: i32, bm_elt: i32, lin_off: i32, lin_mul: i32, wrapped: bool, init: i32 }

// SwitchReplacement::wouldFitInRegister
fn would_fit_in_register(table_size: u64, et: i32) -> bool {
    if !ty_is_int(et) { return false; }
    let w = ty_bits(et) as u64;
    if table_size >= 0xFFFFFFFF / w { return false; }
    return dl_fits_in_legal_integer((table_size * w) as i64);
}

// isTypeLegalForLookupTable
fn is_type_legal_for_lookup_table(t: i32) -> bool {
    if tti_is_type_legal(t) { return true; }
    if !ty_is_int(t) { return false; }
    let w = ty_bits(t);
    return w >= 8 && (w & (w - 1)) == 0 && dl_fits_in_legal_integer(w);
}

// shouldBuildLookupTable
fn should_build_lookup_table(si: i32, table_size: u64, rtys: const i32[:]) -> bool {
    if sw_ncases(si) as u64 > table_size { return false; }
    var all_fit = true;
    var illegal = false;
    for t in rtys {
        illegal = illegal || !is_type_legal_for_lookup_table(t);
        all_fit = all_fit && would_fit_in_register(table_size, t);
        if illegal && !all_fit { break; }
    }
    if all_fit { return true; }
    if illegal { return false; }
    return is_switch_dense_n(sw_ncases(si) as u64, table_size, fn_has_opt_size(inst_func(si)));
}

// shouldUseSwitchConditionAsTableIndex
fn should_use_cond_as_table_index(minc: i32, maxc: i32, has_def: bool, rtys: const i32[:]) -> bool {
    if is_null_value(minc) { return true; }
    let mx = ap_limited(ci_ap(maxc), 0xFFFFFFFFFFFFFFFF);
    if ap_is_neg(ci_ap(minc)) || mx == 0xFFFFFFFFFFFFFFFF || !has_def { return false; }
    for t in rtys { if !would_fit_in_register(mx + 1, t) { return false; } }
    return true;
}

// SwitchReplacement::SwitchReplacement
fn sw_rep_build(table_size: u64, offset: i32, rcase: const i32[:], rval: const i32[:], def: i32) -> SwRep {
    var r = SwRep { kind: SR_TABLE, def: def, vty: vals[rval[0]].ty, single: rval[0], bitmap: -1, bm_elt: -1, lin_off: -1, lin_mul: -1, wrapped: false, init: -1 };
    var contents: i32[>..<] = [];
    for k in table_size { contents.push(-1); }
    for k in rcase.len {
        let idx = ap_limited(ap_sub(ci_ap(rcase[k]), ci_ap(offset)), 0xFFFFFFFFFFFFFFFF);
        contents[idx as i64] = rval[k];
        if r.single >= 0 && !is_poison(rval[k]) && rval[k] != r.single {
            r.single = if is_poison(r.single) { rval[k] } else { -1 };
        }
    }
    if (rcase.len as u64) < table_size {
        for k in table_size { if contents[k as i64] < 0 { contents[k as i64] = def; } }
        if def != r.single && !is_poison(def) { r.single = -1; }
    }
    if r.single >= 0 { r.kind = SR_SINGLE; return r; }
    if ty_is_int(r.vty) {
        var possible = true;
        var prev = ap_zero(1);
        var dist = ap_zero(1);
        var nonmono = false;
        for k in table_size {
            var cv = contents[k as i64];
            if vals[cv].kind != VK_CINT && is_poison(cv) { cv = rval[0]; }
            if vals[cv].kind != VK_CINT { possible = false; break; }
            let v = ci_ap(cv);
            if k != 0 {
                let d = ap_sub(v, prev);
                if k == 1 { dist = d; }
                else if !ap_eq(d, dist) { possible = false; break; }
                nonmono = nonmono || (if ap_is_strictly_pos(d) { ap_sle(v, prev) } else { ap_sgt(v, prev) });
            }
            prev = v;
        }
        if possible {
            r.lin_off = contents[0];
            r.lin_mul = c_int_ap(ty_int(dist.w as i64), dist);
            let m = dist;
            var may_wrap = true;
            let w = m.w as i64;
            let ts1 = table_size - 1;
            if w >= 64 || ts1 < ((1 as u64) << w) {
                let p, ov = ap_smul_ov(m, ap_u64(ts1, w));
                may_wrap = ov;
            }
            r.wrapped = nonmono || may_wrap;
            r.kind = SR_LINEAR;
            return r;
        }
    }
    if would_fit_in_register(table_size, r.vty) {
        let ew = ty_bits(r.vty);
        let tw = (table_size as i64) * ew;
        var ti = ap_zero(tw);
        var k = table_size as i64;
        while k > 0 {
            ti = ap_shl(ti, ew);
            let c = contents[k - 1];
            if !is_undef_or_poison(c) { ti = ap_or(ti, ap_zext(ci_ap(c), tw)); }
            k--;
        }
        r.bitmap = c_int_ap(ty_int(tw), ti);
        r.bm_elt = r.vty;
        r.kind = SR_BITMAP;
        return r;
    }
    if ty_is_int(r.vty) {
        let w = ty_bits(r.vty);
        var rng = rg_empty(w);
        for c in contents { if !is_undef_or_poison(c) { rng = rg_union(rng, rg_single(ci_ap(c))); } }
        let ab = rg_active_bits(rng);
        var p2 = 1;
        while p2 < ab { p2 *= 2; }
        if ab == 0 { p2 = 0; }
        let needed = max(tti_minimum_lookup_table_entry_bits(), p2);
        if needed < w {
            let dt = ty_int(needed);
            for k in contents.len { contents[k] = cf_cast(OP_TRUNC, contents[k], dt); }
        }
    }
    let tt = ty_array(vals[contents[0]].ty, table_size as i64);
    r.init = c_aggregate(tt, contents);
    r.kind = SR_TABLE;
    return r;
}

// SwitchReplacement::replaceSwitch
fn sw_rep_replace(r: SwRep, index0: i32, fv: i32) -> i32 {
    var index = index0;
    if r.kind == SR_SINGLE { return r.single; }
    if r.kind == SR_LINEAR {
        let mt = vals[r.lin_mul].ty;
        var res = sb_int_cast(index, mt, false, "switch.idx.cast");
        if !ap_is_one(ci_ap(r.lin_mul)) {
            res = sb_binop_flags(OP_MUL, res, r.lin_mul, "switch.idx.mult", if r.wrapped { 0 } else { FL_NSW });
        }
        if !ap_is_zero(ci_ap(r.lin_off)) {
            res = sb_binop_flags(OP_ADD, res, r.lin_off, "switch.offset", if r.wrapped { 0 } else { FL_NSW });
        }
        return res;
    }
    if r.kind == SR_BITMAP {
        let mt = vals[r.bitmap].ty;
        var sh = sb_zext_or_trunc(index, mt, "switch.cast");
        sh = sb_binop_flags(OP_MUL, sh, c_int(mt, ty_bits(r.bm_elt)), "switch.shiftamt", FL_NUW | FL_NSW);
        let ds = sb_binop(OP_LSHR, r.bitmap, sh, "switch.downshift");
        return sb_cast(OP_TRUNC, ds, r.bm_elt, "switch.masked");
    }
    // LookupTableKind
    let at = vals[r.init].ty;
    let nm = name_plus(fv, "");
    var gname: u8[>..] = [];
    gname.append("switch.table.");
    gname.append(nm);
    let gv = new_glob(VK_GVAR, ty_ptr(0), -1, 1);
    let g = glob_of(gv);
    globs[g].module = globs[glob_of(fv)].module;
    globs[g].vty = at;
    globs[g].is_const = 1;
    globs[g].is_decl = 0;
    globs[g].linkage = LK_PRIVATE as u8;
    globs[g].unnamed = 2;
    globs[g].align = (log2_exact_i(dl_align(r.vty, false)) + 1) as u8;
    set_op(gv, 0, r.init);
    symtab_set_name(modules[globs[g].module].symtab, gv, gname, true);
    module_append_global(gv);
    let ity = ty_int(dl_ptr(0).idx);
    if vals[index].ty != ity {
        let old = ty_bits(vals[index].ty);
        index = sb_zext_or_trunc(index, ity, "");
        if is_inst(index) && iop(index) == OP_ZEXT {
            let n1 = (ty_count(at) - 1) as u64;
            let fits = old - 1 >= 64 || n1 < ((1 as u64) << (old - 1));
            if fits { insts[inst_of(index)].flags |= FL_NNEG; } else { insts[inst_of(index)].flags &= ~FL_NNEG; }
        }
    }
    let gep = sb_gep_inbounds(at, gv, [c_int(ity, 0), index], "switch.gep");
    let et = ty_elem(at);
    let ld = sb_load(et, gep, "switch.load");
    if vals[ld].ty == r.vty { return ld; }
    return sb_cast(OP_ZEXT, ld, r.vty, "switch.ext");
}

// CreateAdd/CreateSub/CreateMul(LHS, RHS, Name, HasNUW, HasNSW) (FoldNoWrapBinOp)
fn sb_binop_flags(o: i64, a: i32, b: i32, name: const u8[:], flags: u8) -> i32 {
    if !sb_nofold && is_constant(a) && is_constant(b) {
        if is_desirable_binop(o) { return ce_binop(o, a, b, flags); }
        let r = cf_binop(o, a, b);
        if r >= 0 { return r; }
    }
    let iv = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(iv)].flags = flags;
    return sb_insert(iv, name);
}
// CreateIntCast(V, DestTy, isSigned)
fn sb_int_cast(v: i32, t: i32, signed: bool, name: const u8[:]) -> i32 {
    let vb = ty_bits(vals[v].ty);
    let tb = ty_bits(t);
    if vb == tb { return v; }
    if vb > tb { return sb_cast(OP_TRUNC, v, t, name); }
    return sb_cast(if signed { OP_SEXT } else { OP_ZEXT }, v, t, name);
}
fn sb_zext_or_trunc(v: i32, t: i32, name: const u8[:]) -> i32 {
    let vb = ty_bits(vals[v].ty);
    let tb = ty_bits(t);
    if vb < tb { return sb_cast(OP_ZEXT, v, t, name); }
    if vb > tb { return sb_cast(OP_TRUNC, v, t, name); }
    return v;
}
// CreateInBoundsGEP(Ty, Ptr, Idx, Name)
fn sb_gep_inbounds(srcty: i32, p: i32, idxs: const i32[:], name: const u8[:]) -> i32 {
    var allc = is_constant(p);
    for x in idxs { if !is_constant(x) { allc = false; } }
    if allc && !sb_nofold { return ce_gep(srcty, p, idxs, GEP_INBOUNDS, -1); }
    var opsv: i32[>..<] = [];
    opsv.push(p);
    for x in idxs { opsv.push(x); }
    let g = create_inst(OP_GEP, vals[p].ty, opsv);
    insts[inst_of(g)].ty2 = srcty;
    insts[inst_of(g)].flags = GEP_INBOUNDS;
    return sb_insert(g, name);
}
// CreateLoad(Ty, Ptr, Name): ABI alignment of the type
fn sb_load(t: i32, p: i32, name: const u8[:]) -> i32 {
    let l = create_inst(OP_LOAD, t, [p]);
    insts[inst_of(l)].align = (log2_exact_i(dl_align(t, true)) + 1) as u8;
    return sb_insert(l, name);
}

// reuseTableCompare
fn reuse_table_compare(user: i32, phibb: i32, rcb: i32, defv: i32, rval: const i32[:]) {
    if !is_icmp(user) { return; }
    if inst_parent(user) != phibb { return; }
    let c1 = op(user, 1);
    if !is_constant(c1) { return; }
    let rc = br_cond(rcb);
    let tc = c_int(vals[rc].ty, 1);
    let fc = c_int(vals[rc].ty, 0);
    let dc = cf_compare_inst_operands(inst_pred(user), defv, c1);
    if dc != tc && dc != fc { return; }
    for v in rval {
        let cc = cf_compare_inst_operands(inst_pred(user), v, c1);
        if cc < 0 || cc == dc || (cc != tc && cc != fc) { return; }
    }
    let brb = inst_parent(rcb);
    var ok = true;
    each_pred(phibb) { p => if p != brb && cu_unique_pred(p) != brb { ok = false; } };
    if !ok { return; }
    if dc == fc {
        rauw(user, rc);
    } else {
        let x = create_inst(OP_XOR, vals[rc].ty, [rc, c_int(vals[rc].ty, 1)]);
        inst_insert_before(x, rcb);
        set_name(x, "inverted.cmp");
        rauw(user, x);
    }
}
// ConstantFoldCompareInstOperands
fn cf_compare_inst_operands(p: i64, a: i32, b: i32) -> i32 { cf_fold_cmp_operands(p, a, b, -1) }

fn simplify_switch_lookup(si: i32, use_tables: bool) -> bool {
    let bb = inst_parent(si);
    let fv = block_func(bb);
    if sw_ncases(si) < 3 { return false; }
    var minc = sw_case_val(si, 0);
    var maxc = sw_case_val(si, 0);
    var common: i32 = -1;
    // ResultLists: per PHI (in PHIs order) the (case, value) pairs
    var phis: i32[>..<] = [];
    var rl_phi: i64[>..<] = [];
    var rl_case: i32[>..<] = [];
    var rl_val: i32[>..<] = [];
    var rtys: i32[>..<] = [];
    for k in sw_ncases(si) {
        let cv = sw_case_val(si, k);
        if ap_slt(ci_ap(cv), ci_ap(minc)) { minc = cv; }
        if ap_sgt(ci_ap(cv), ci_ap(maxc)) { maxc = cv; }
        var res: i32[>..<] = [];
        let ok, c2 = get_case_results(si, cv, sw_case_dest(si, k), common, res);
        common = c2;
        if !ok { return false; }
        var j: i64 = 0;
        while j < res.len {
            let phi = res[j];
            var pi = position(phis, phi);
            if pi < 0 { phis.push(phi); pi = phis.len - 1; }
            rl_phi.push(pi);
            rl_case.push(cv);
            rl_val.push(res[j + 1]);
            rtys.push(vals[phi].ty);
            j += 2;
        }
    }
    var dres: i32[>..<] = [];
    let has_def, c3 = get_case_results(si, -1, sw_default(si), common, dres);
    common = c3;
    fn default_result(phi: i32) -> i32 {
        var j: i64 = 0;
        var r: i32 = -1;
        while j < dres.len { if dres[j] == phi { r = dres[j + 1]; } j += 2; }
        return r;
    }
    let use_cond = should_use_cond_as_table_index(minc, maxc, has_def, rtys);
    var table_size: u64 = 0;
    var tio: i32 = -1;
    if use_cond {
        table_size = ap_limited(ci_ap(maxc), 0xFFFFFFFFFFFFFFFF) + 1;
        tio = c_int(vals[maxc].ty, 0);
    } else {
        table_size = ap_limited(ap_sub(ci_ap(maxc), ci_ap(minc)), 0xFFFFFFFFFFFFFFFF) + 1;
        tio = minc;
    }
    var nres: u64 = 0;
    for x in rl_phi { if x == 0 { nres++; } }
    var def_reachable = !cu_default_dest_unreachable(si);
    let has_holes = nres < table_size;
    let all_holes_poison = has_holes && !has_def;
    let need_mask = all_holes_poison && def_reachable;
    if need_mask {
        if sw_ncases(si) < 4 { return false; }
        if !dl_fits_in_legal_integer(table_size as i64) { return false; }
    }
    if !should_build_lookup_table(si, table_size, rtys) { return false; }
    var tindex: i32 = -1;
    if use_cond {
        tindex = op(si, 0);
        if has_def {
            let s1 = sq_no_dt; let s2 = sq_no_ac;
            sq_no_dt = true; sq_no_ac = true;
            let sk = kb_cxt;
            kb_cxt = -1;
            let cr = compute_constant_range(tindex, false, true, 0);
            kb_cxt = sk;
            sq_no_dt = s1; sq_no_ac = s2;
            let ub = ap_limited(cr.hi, 0xFFFFFFFFFFFFFFFF);
            var allfit = true;
            for t in rtys { if !would_fit_in_register(ub, t) { allfit = false; } }
            if !rg_is_upper_wrapped(cr) && allfit {
                table_size = max(ub, table_size);
                def_reachable = false;
            }
        }
    }
    var reps: SwRep[>..<] = [];
    for pi in phis.len {
        var rc: i32[>..<] = [];
        var rv: i32[>..<] = [];
        for j in rl_phi.len { if rl_phi[j] == pi as i64 { rc.push(rl_case[j]); rv.push(rl_val[j]); } }
        let rt = vals[rv[0]].ty;
        let dv = if all_holes_poison { c_poison(rt) } else { default_result(phis[pi]) };
        reps.push(sw_rep_build(table_size, tio, rc, rv, dv));
    }
    var any_tables = false;
    var any_bitmaps = false;
    for r in reps { if r.kind == SR_TABLE { any_tables = true; } if r.kind == SR_BITMAP { any_bitmaps = true; } }
    if any_tables && (!tti_should_build_lookup_tables() || func_str_attr_is_true_scf(fv, "no-jump-tables")) { return false; }
    if !use_tables && (any_tables || any_bitmaps || need_mask) { return false; }
    sb_at(si);
    if !use_cond {
        var may_wrap = true;
        if !def_reachable {
            let rr, ov = ap_ssub_ov(ci_ap(maxc), ci_ap(minc));
            may_wrap = ov;
        }
        tindex = sb_binop_flags(OP_SUB, op(si, 0), tio, "switch.tableidx", if may_wrap { 0 } else { FL_NSW });
    }
    var ups: DTUpdate[>..<] = [];
    let csize = ty_bits(vals[minc].ty);
    let max_table: u64 = if csize > 63 { 0xFFFFFFFFFFFFFFFF } else { (1 as u64) << csize };
    var lookup = create_block_before(fv, common, "switch.lookup");
    var rcb: i32 = -1;
    var condbr: i32 = -1;
    sb_set_before(si);
    let covered = max_table == table_size;
    if !def_reachable || covered {
        sb_br(lookup);
        if cu_dtu { cu_upd(ups, DT_INSERT, bb, lookup); }
    } else {
        let cmp = sb_icmp(P_ULT, tindex, c_int_ty(vals[minc].ty, table_size), "");
        rcb = sb_condbr(cmp, lookup, sw_default(si));
        condbr = rcb;
        if cu_dtu { cu_upd(ups, DT_INSERT, bb, lookup); }
    }
    sb_set_end(lookup);
    if need_mask {
        let maskbb = lookup;
        set_name(maskbb, "switch.hole_check");
        lookup = create_block_before(fv, common, "switch.lookup");
        var tsp2: u64 = 1;
        let base = max(7, table_size - 1);
        while tsp2 <= base { tsp2 *= 2; }
        let mw = tsp2 as i64;
        var mask = ap_zero(mw);
        for j in rl_phi.len {
            if rl_phi[j] != 0 { continue; }
            let idx = ap_limited(ap_sub(ci_ap(rl_case[j]), ci_ap(tio)), 0xFFFFFFFFFFFFFFFF);
            mask = ap_or(mask, ap_shl(ap_u64(1, mw), idx as i64));
        }
        let tm = c_int_ap(ty_int(mw), mask);
        let mi = sb_zext_or_trunc(tindex, ty_int(mw), "switch.maskindex");
        let shv = sb_binop(OP_LSHR, tm, mi, "switch.shifted");
        let lob = sb_cast(OP_TRUNC, shv, T_I1, "switch.lobit");
        condbr = sb_condbr(lob, lookup, sw_default(si));
        if cu_dtu { cu_upd(ups, DT_INSERT, maskbb, lookup); cu_upd(ups, DT_INSERT, maskbb, sw_default(si)); }
        sb_set_end(lookup);
        add_predecessor_to_block(sw_default(si), maskbb, bb);
    }
    if !def_reachable || covered {
        block_remove_predecessor(sw_default(si), bb, true);
        if cu_dtu { cu_upd(ups, DT_DELETE, bb, sw_default(si)); }
    }
    for pi in phis.len {
        let phi = phis[pi];
        let r = reps[pi];
        let res = sw_rep_replace(r, tindex, fv);
        if !has_holes && has_def && rcb >= 0 {
            let phibb = inst_parent(phi);
            var rv: i32[>..<] = [];
            for j in rl_phi.len { if rl_phi[j] == pi as i64 { rv.push(rl_val[j]); } }
            var users: i32[>..<] = [];
            var u = first_use(phi);
            while u >= 0 { users.push(uses[u].user); u = use_next(u); }
            for us in users { reuse_table_compare(us, phibb, rcb, r.def, rv); }
        }
        phi_add_incoming(phi, res, lookup);
    }
    sb_br(common);
    if cu_dtu { cu_upd(ups, DT_INSERT, lookup, common); }
    var bw: u64[>..<] = [];
    let has_bw = condbr >= 0 && pd_extract(si, bw);
    var to_lookup: u64 = 0;
    var to_def: u64 = 0;
    var removed: i32[>..<] = [];
    for k in term_nsucc(si) {
        let s = term_succ(si, k);
        if s == sw_default(si) {
            if has_bw { to_def += bw[k]; }
            continue;
        }
        block_remove_predecessor(s, bb, false);
        if cu_dtu && cu_push_unique(removed, s) { cu_upd(ups, DT_DELETE, bb, s); }
        if has_bw { to_lookup += bw[k]; }
    }
    scf_erase(si);
    if has_bw {
        let w: u64[2] = [to_lookup, to_def];
        pd_set_fitted(condbr, w, false, false);
    }
    cu_apply(ups);
    return true;
}
fn func_str_attr_is_true_scf(fv: i32, key: const u8[:]) -> bool {
    let a = aset_find_str(alist_fn(func_attrs(fv)), key);
    return a >= 0 && attrs[a].sval >= 0 && sbytes(attrs[a].sval) == "true";
}

fn simplify_switch(si: i32) -> bool {
    let bb = inst_parent(si);
    if is_value_equality_comparison(si) >= 0 {
        let only = single_pred(bb);
        if only >= 0 && simplify_eq_cmp_with_only_pred(si, only) { return scf_request_resimplify(); }
        let cond = op(si, 0);
        if is_select(cond) && simplify_switch_on_select(si, cond) { return scf_request_resimplify(); }
        if si == block_first(bb) && fold_value_cmp_into_preds(si) { return scf_request_resimplify(); }
    }
    if so.range_to_icmp && turn_switch_range_into_icmp(si) { return scf_request_resimplify(); }
    if eliminate_dead_switch_cases(si) { return scf_request_resimplify(); }
    if simplify_switch_of_cmp_intrinsic(si) { return scf_request_resimplify(); }
    if try_switch_to_select(si) { return scf_request_resimplify(); }
    if so.fwd_switch_cond && forward_switch_condition_to_phi(si) { return scf_request_resimplify(); }
    if so.to_arith || so.to_lookup {
        if simplify_switch_lookup(si, so.to_lookup) { return scf_request_resimplify(); }
    }
    if simplify_switch_of_powers_of_two(si) { return scf_request_resimplify(); }
    if reduce_switch_range(si) { return scf_request_resimplify(); }
    if cl_hoist_common && hoist_common_code_from_successors(si, !so.hoist_common) { return scf_request_resimplify(); }
    if simplify_duplicate_switch_arms(si) { return scf_request_resimplify(); }
    if simplify_switch_when_umin(si) { return scf_request_resimplify(); }
    return false;
}

fn simplify_indirect_br(ibi: i32) -> bool {
    let bb = inst_parent(ibi);
    var changed = false;
    var bw: u64[>..<] = [];
    let has_bw = pd_extract(ibi, bw);
    var tw_b: i32[>..<] = [];
    var tw_w: u64[>..<] = [];
    if has_bw {
        for k in nops(ibi) - 1 {
            let d = op(ibi, 1 + k);
            let j = position(tw_b, d);
            if j < 0 { tw_b.push(d); tw_w.push(bw[k]); } else { tw_w[j] += bw[k]; }
        }
    }
    var seen: i32[>..<] = [];
    var removed: i32[>..<] = [];
    var k: i64 = 0;
    while k < nops(ibi) - 1 {
        let d = op(ibi, 1 + k);
        if !cu_has_address_taken(d) || !cu_push_unique(seen, d) {
            if !cu_has_address_taken(d) { cu_push_unique(removed, d); }
            block_remove_predecessor(d, bb, false);
            // IndirectBrInst::removeDestination(k): the last moves into the hole
            let n = nops(ibi);
            if 1 + k != n - 1 { set_op(ibi, 1 + k, op(ibi, n - 1)); }
            set_op(ibi, n - 1, -1);
            vals[ibi].nops = (n - 1) as i32;
            changed = true;
            continue;
        }
        k++;
    }
    if cu_dtu {
        var ups: DTUpdate[>..<] = [];
        for r in removed { cu_upd(ups, DT_DELETE, bb, r); }
        dtu_apply_updates(ups);
    }
    if nops(ibi) - 1 == 0 {
        inst_insert_before(create_inst(OP_UNREACHABLE, T_VOID, []), ibi);
        erase_terminator_and_dce_cond(ibi);
        return true;
    }
    if nops(ibi) - 1 == 1 {
        inst_insert_before(create_inst(OP_BR, T_VOID, [op(ibi, 1)]), ibi);
        erase_terminator_and_dce_cond(ibi);
        return true;
    }
    if has_bw {
        var nw: u64[>..<] = [];
        for j in nops(ibi) - 1 { nw.push(tw_w[position(tw_b, op(ibi, 1 + j))]); }
        pd_set_fitted(ibi, nw, false, true);
    }
    let a = op(ibi, 0);
    if is_select(a) {
        if simplify_indirectbr_on_select(ibi, a) { return scf_request_resimplify(); }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Sinking (sinkCommonCodeFromPredecessors) and invoke merging: not ported

// PHIOperands: DenseMap<const Use*, SmallVector<Value*>> as (use id, run start, run length)
var po_use: i32[>..<];
var po_at: i64[>..<];
var po_n: i64[>..<];
var po_pool: i32[>..<];
fn po_find(u: i32) -> i64 { for k in po_use.len { if po_use[k] == u { return k; } } return -1; }
fn po_value(k: i64, j: i64) -> i32 { po_pool[po_at[k] + j] }

// replacingOperandWithVariableIsCheap
fn replacing_operand_with_variable_is_cheap(i: i32, k: i64) -> bool {
    let o = iop(i);
    if o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM { return k != 1; }
    return inst_iid(i) == 0;
}

// CallBase::isIndirectCall
fn cb_is_indirect_call(c: i32) -> bool {
    let v = cb_callee(c);
    if is_func(v) { return false; }
    if vals[v].kind == VK_INLINEASM { return false; }
    return true;
}

// canSinkInstructions(Insts, PHIOperands)
fn can_sink_instructions(xs: const i32[:]) -> bool {
    var nuses: i64 = -1;
    for i in xs {
        let o = iop(i);
        if o == OP_PHI || inst_is_eh_pad(i) || o == OP_ALLOCA || ty_kind(vals[i].ty) == TK_TOKEN { return false; }
        let p = inst_parent(i);
        if cu_single_succ(p) == p { return false; }
        if is_callbase(i) && (vals[cb_callee(i)].kind == VK_INLINEASM || cb_cannot_merge(i) || cb_is_convergent(i)) { return false; }
        let n = num_uses(i);
        if nuses < 0 { nuses = n; } else if nuses != n { return false; }
    }
    let i0 = xs[0];
    let m0 = mmra_md(i0);
    for i in xs {
        if !cu_same_operation_as(i, i0, CU_INTERSECT_ATTRS) { return false; }
        if mmra_md(i) != m0 { return false; }
    }
    var u = first_use(i0);
    while u >= 0 {
        let k = po_find(u);
        if k < 0 { return false; }
        if po_n[k] != xs.len { return false; }
        for j in xs.len { if po_value(k, j) != xs[j] { return false; } }
        u = use_next(u);
    }
    if is_callbase(i0) {
        var have_ind = false;
        var all_ind = true;
        for i in xs { if cb_is_indirect_call(i) { have_ind = true; } else { all_ind = false; } }
        if have_ind {
            if !all_ind { return false; }
        } else {
            let c0 = cb_callee(xs[0]);
            for i in xs { if cb_callee(i) != c0 { return false; } }
        }
    }
    for k in nops(i0) {
        let opv = op(i0, k);
        var same = true;
        for i in xs { if op(i, k) != opv { same = false; } }
        if !same {
            if (is_constant(opv) && !replacing_operand_with_variable_is_cheap(i0, k)) || !cu_can_replace_operand_with_variable(i0, k) { return false; }
            let ui = vals[i0].ops + k as i32;
            var e = po_find(ui);
            if e < 0 { po_use.push(ui); po_at.push(po_pool.len); po_n.push(0); e = po_use.len - 1; }
            if po_n[e] != 0 && po_at[e] + po_n[e] != po_pool.len {
                // re-append the run at the end so it stays contiguous
                let old = po_at[e];
                let n = po_n[e];
                po_at[e] = po_pool.len;
                for j in n { po_pool.push(po_pool[old + j]); }
            }
            for i in xs { po_pool.push(op(i, k)); po_n[e] += 1; }
        }
    }
    return true;
}

// sinkLastInstruction(Blocks)
fn sink_last_instruction(bbs: const i32[:]) {
    let bbend = term_succ(block_terminator(bbs[0]), 0);
    var xs: i32[>..<] = [];
    for b in bbs { xs.push(inst_prev(block_terminator(b))); }
    let i0 = xs[0];
    var newops: i32[>..<] = [];
    for k in nops(i0) {
        var need = false;
        for i in xs { if op(i, k) != op(i0, k) { need = true; } }
        if !need { newops.push(op(i0, k)); continue; }
        let o = op(i0, k);
        let pn = new_inst(OP_PHI, vals[o].ty, xs.len);
        vals[pn].nops = 0;
        let f = block_first(bbend);
        if f >= 0 { inst_insert_before(pn, f); } else { block_append_inst(bbend, pn); }
        let nm = name_plus(o, ".sink");
        set_name(pn, nm);
        for i in xs { phi_add_incoming(pn, op(i, k), inst_parent(i)); }
        newops.push(pn);
    }
    for k in nops(i0) { set_op(i0, k, newops[k]); }
    if inst_first_dbg(i0) >= 0 { scf_not_ported("sinking instructions with debug records"); }
    inst_move_before(i0, scf_first_insertion_pt(bbend));
    for i in xs {
        if i == i0 { continue; }
        apply_merged_location(i0, inst_get_md(i0, MDK_DBG_SC), inst_get_md(i, MDK_DBG_SC));
        combine_metadata_for_cse(i0, i, true);
        and_ir_flags(i0, i);
        if is_callbase(i0) { try_intersect_attributes(i0, i); }
    }
    // make_early_inc_range(I0->users()): the next use is read before the PHI is replaced
    var u = first_use(i0);
    while u >= 0 {
        let nu = use_next(u);
        let pn = uses[u].user;
        rauw(pn, i0);
        scf_erase(pn);
        u = nu;
    }
    for i in xs {
        if i == i0 { continue; }
        rauw(i, i0);
        if inst_first_dbg(i) >= 0 { scf_not_ported("sinking instructions with debug records"); }
        scf_erase(i);
    }
}

// BasicBlock::getFirstInsertionPt
fn scf_first_insertion_pt(bb: i32) -> i32 {
    var i = first_non_phi(bb);
    if i >= 0 && (iop(i) == OP_LANDINGPAD || iop(i) == OP_CLEANUPPAD || iop(i) == OP_CATCHPAD || iop(i) == OP_CATCHSWITCH) { i = inst_next(i); }
    return i;
}

fn is_gep_operator(v: i32) -> bool { opcode_of(v) == OP_GEP }

fn sink_common_code_from_predecessors(bb: i32) -> bool {
    var upreds: i32[>..<] = [];
    var have_non_uncond = false;
    var preds: i32[>..<] = [];
    cu_preds(bb, preds);
    for p in preds {
        if iop(block_terminator(p)) == OP_BR { upreds.push(p); } else { have_non_uncond = true; }
    }
    if upreds.len < 2 { return false; }
    po_use.clear(); po_at.clear(); po_n.clear(); po_pool.clear();
    var p = block_first(bb);
    while p >= 0 && iop(p) == OP_PHI {
        // IncomingVals: first use per incoming block
        var key_use: i32 = -1;
        for k in nops(p) { if phi_block(p, k) == upreds[0] { key_use = vals[p].ops + k as i32; break; } }
        var e = po_find(key_use);
        if e < 0 { po_use.push(key_use); po_at.push(po_pool.len); po_n.push(0); e = po_use.len - 1; }
        for pb in upreds {
            var v: i32 = -1;
            for k in nops(p) { if phi_block(p, k) == pb { v = phi_value(p, k); break; } }
            po_pool.push(v);
            po_n[e] += 1;
        }
        p = inst_next(p);
    }
    var scan_idx: i64 = 0;
    var to_sink: i32[>..<] = [];
    lri_init(upreds);
    while lri_valid {
        var cur: i32[>..<] = [];
        for x in lri_cur { cur.push(x); }
        if !can_sink_instructions(cur) { break; }
        for x in cur { cu_push_unique(to_sink, x); }
        scan_idx++;
        lri_dec();
    }
    if scan_idx == 0 { return false; }
    let followed = cu_followed_by_deopt_or_unreachable(bb);
    if !followed {
        fn profitable() -> bool {
            var nphi = 0;
            let i0 = lri_cur[0];
            for k in nops(i0) {
                let u = vals[i0].ops + k as i32;
                let e = po_find(u);
                if e < 0 { continue; }
                var all = true;
                for j in po_n[e] { if position(to_sink, po_value(e, j)) < 0 { all = false; } }
                if all { continue; }
                nphi++;
                let o = iop(i0);
                let is_mem = (o == OP_LOAD && k == 0) || (o == OP_STORE && k == 1);
                if is_mem {
                    for j in po_n[e] { if is_gep_operator(po_value(e, j)) { return false; } }
                }
            }
            return nphi <= 1;
        }
        lri_reset();
        var idx: i64 = 0;
        var prof_set: i32[>..<] = [];
        while idx < scan_idx {
            if !profitable() { break; }
            for x in lri_cur { cu_push_unique(prof_set, x); }
            lri_dec();
            idx++;
        }
        if idx == 0 { return false; }
        if idx < scan_idx {
            scan_idx = idx;
            to_sink.clear();
            for x in prof_set { to_sink.push(x); }
            lri_inc();
            idx--;
            while idx >= 0 {
                for x in lri_cur { let j = position(prof_set, x); if j >= 0 { prof_set.remove_at(j); } }
                if !profitable() {
                    scan_idx = idx;
                    to_sink.clear();
                    for x in prof_set { to_sink.push(x); }
                }
                lri_inc();
                idx--;
            }
        }
        if scan_idx == 0 { return false; }
    }
    var changed = false;
    if have_non_uncond {
        if !followed {
            lri_reset();
            var idx: i64 = 0;
            var profitable_any = false;
            while idx < scan_idx {
                if !spec_safe(lri_cur[0], -1, false) { profitable_any = true; break; }
                lri_dec();
                idx++;
            }
            if !profitable_any { return false; }
        }
        if cu_split_block_predecessors(bb, upreds, ".sink.split") < 0 { return false; }
        changed = true;
    }
    var sink_idx: i64 = 0;
    while sink_idx != scan_idx {
        sink_last_instruction(upreds);
        changed = true;
        sink_idx++;
    }
    return changed;
}

fn invoke_has_normal_dest(ii: i32) -> bool { iop(first_non_phi(invoke_normal_dest(ii))) != OP_UNREACHABLE }
fn invoke_data_ops(ii: i32) -> i64 { cb_nargs(ii) + cb_bundle_ops_cu(ii) }

// CompatibleSets::shouldBelongToSameSet({a, b})
fn invokes_should_belong_to_same_set(a: i32, b: i32) -> bool {
    let two: i32[2] = [a, b];
    for ii in two { if cb_cannot_merge(ii) || vals[cb_callee(ii)].kind == VK_INLINEASM { return false; } }
    let ia = cb_is_indirect_call(a);
    let ib = cb_is_indirect_call(b);
    if ia || ib {
        if !(ia && ib) { return false; }
    } else if cb_callee(a) != cb_callee(b) { return false; }
    let ha = invoke_has_normal_dest(a);
    let hb = invoke_has_normal_dest(b);
    if ha || hb {
        if !(ha && hb) { return false; }
        if invoke_normal_dest(a) != invoke_normal_dest(b) { return false; }
        if !incoming_values_compatible(invoke_normal_dest(a), inst_parent(a), inst_parent(b), two, true) { return false; }
    }
    let none: i32[0] = [];
    if !incoming_values_compatible(invoke_unwind_dest(a), inst_parent(a), inst_parent(b), none, false) { return false; }
    if !cu_same_operation_as(b, a, CU_INTERSECT_ATTRS) { return false; }
    for k in invoke_data_ops(a) {
        if op(a, k) == op(b, k) { continue; }
        if !cu_can_replace_operand_with_variable(a, k) { return false; }
    }
    return true;
}

fn merge_compatible_invokes_impl(invs: const i32[:]) {
    var ups: DTUpdate[>..<] = [];
    let has_nd = invoke_has_normal_dest(invs[0]);
    let ii0 = invs[0];
    let bb0 = inst_parent(ii0);
    let fv = block_func(bb0);
    let before = block_next(bb0);
    let nm = name_plus(bb0, ".invoke");
    let mbb = create_block_before(fv, before, nm);
    let mi = inst_clone(ii0);
    block_append_inst(mbb, mi);
    if !has_nd {
        let nm2 = name_plus(bb0, ".cont");
        let nd = create_block_before(fv, before, nm2);
        block_append_inst(nd, create_inst(OP_UNREACHABLE, T_VOID, []));
        set_op(mi, nops(mi) - 3, nd);
    }
    if cu_dtu {
        for ii in invs { cu_upd(ups, DT_INSERT, inst_parent(ii), mbb); }
        var ms: i32[>..<] = [];
        cu_succs(mbb, ms);
        for s in ms { cu_upd(ups, DT_INSERT, mbb, s); }
        for ii in invs {
            var ss: i32[>..<] = [];
            cu_succs(inst_parent(ii), ss);
            for s in ss { cu_upd(ups, DT_DELETE, inst_parent(ii), s); }
        }
    }
    let indirect = cb_is_indirect_call(invs[0]);
    for k in nops(mi) {
        let is_callee = k == nops(mi) - 1;
        if is_callee { if !indirect { continue; } }
        else if k >= invoke_data_ops(mi) { continue; }
        var need = false;
        for ii in invs { if op(ii, k) != op(mi, k) { need = true; } }
        if !need { continue; }
        let pn = new_inst(OP_PHI, vals[op(mi, k)].ty, invs.len);
        vals[pn].nops = 0;
        inst_insert_before(pn, mi);
        for ii in invs { phi_add_incoming(pn, op(ii, k), inst_parent(ii)); }
        set_op(mi, k, pn);
    }
    var ms2: i32[>..<] = [];
    cu_succs(mbb, ms2);
    for s in ms2 { add_predecessor_to_block(s, mbb, inst_parent(invs[0])); }
    var mdl: i32 = -1;
    var first = true;
    for ii in invs {
        let dl = inst_get_md(ii, MDK_DBG_SC);
        if first || mdl < 0 { mdl = dl; first = false; } else { mdl = merged_location(mdl, dl); }
        let pb = inst_parent(ii);
        var ss: i32[>..<] = [];
        cu_succs(pb, ss);
        for s in ss { block_remove_predecessor(s, pb, false); }
        let br = create_inst(OP_BR, T_VOID, [mbb]);
        block_append_inst(pb, br);
        if dl >= 0 { inst_set_md(br, MDK_DBG_SC, dl); }
        try_intersect_attributes(mi, ii);
        rauw(ii, mi);
        scf_erase(ii);
    }
    if mdl >= 0 { inst_set_md(mi, MDK_DBG_SC, mdl); } else { inst_erase_md(mi, MDK_DBG_SC); }
    cu_apply(ups);
}

fn merge_compatible_invokes(bb: i32) -> bool {
    if !cl_merge_invokes { return false; }
    let lp = first_non_phi(bb);
    if lp < 0 || iop(lp) != OP_LANDINGPAD { return false; }
    // CompatibleSets: sets as runs (set index per invoke, in insertion order)
    var invs: i32[>..<] = [];
    var setof: i64[>..<] = [];
    var heads: i32[>..<] = [];
    var preds: i32[>..<] = [];
    cu_preds(bb, preds);
    for p in preds {
        let ii = block_terminator(p);
        var found: i64 = -1;
        for k in heads.len { if invokes_should_belong_to_same_set(heads[k], ii) { found = k; break; } }
        if found < 0 { heads.push(ii); found = heads.len - 1; }
        invs.push(ii);
        setof.push(found);
    }
    var changed = false;
    for k in heads.len {
        var set: i32[>..<] = [];
        for j in invs.len { if setof[j] == k { set.push(invs[j]); } }
        if set.len < 2 { continue; }
        changed = true;
        merge_compatible_invokes_impl(set);
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// simplifyOnce / run

fn simplify_once(bb: i32) -> bool {
    var changed = false;
    let fv = block_func(bb);
    ac_invalidate();
    vt_invalidate_assumes();
    if (cu_pred_empty(bb) && !cu_is_entry(bb)) || single_pred(bb) == bb {
        cu_delete_dead_block(bb);
        return true;
    }
    if cu_constant_fold_terminator(bb, true) { changed = true; }
    if cu_eliminate_duplicate_phis(bb) { changed = true; }
    if remove_undef_introducing_predecessor(bb) { return scf_request_resimplify(); }
    if cu_merge_block_into_predecessor(bb) { return true; }
    if cl_sink_common && so.sink_common {
        if sink_common_code_from_predecessors(bb) || merge_compatible_invokes(bb) { return true; }
        if simplify_duplicate_predecessors(bb) { return true; }
    }
    if so.spec_blocks && !func_has_fn_attr(fv, AK_OptForFuzzing) {
        let pn = block_first(bb);
        if iop(pn) == OP_PHI && nops(pn) == 2 {
            if fold_two_entry_phi_node(pn) { return true; }
        }
    }
    let t = block_terminator(bb);
    let o = iop(t);
    if o == OP_BR { if simplify_uncond_branch(t) { changed = true; } }
    else if o == OP_CONDBR { if simplify_cond_branch(t) { changed = true; } }
    else if o == OP_RESUME { if simplify_resume(t) { changed = true; } }
    else if o == OP_CLEANUPRET { if simplify_cleanup_return(t) { changed = true; } }
    else if o == OP_SWITCH { if simplify_switch(t) { changed = true; } }
    else if o == OP_UNREACHABLE { if simplify_unreachable(t) { changed = true; } }
    else if o == OP_INDIRECTBR { if simplify_indirect_br(t) { changed = true; } }
    return changed;
}

fn simplify_cfg_block(bb: i32) -> bool {
    var changed = false;
    loop {
        scf_resimplify = false;
        if simplify_once(bb) { changed = true; }
        if !scf_resimplify { break; }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// The pass (SimplifyCFGPass.cpp)

// performBlockTailMerging
fn perform_block_tail_merging(fv: i32, bbs: const i32[:], ups: DTUpdate[>..<]&) -> bool {
    if bbs.len < 2 { return false; }
    let term = block_terminator(bbs[0]);
    let nm = if iop(term) == OP_RET { "common.ret" } else { "common.resume" };
    let cb = create_block_before(fv, bbs[0], nm);
    var newops: i32[>..<] = [];
    for k in nops(term) {
        let o = op(term, k);
        let pn = new_inst(OP_PHI, vals[o].ty, bbs.len);
        vals[pn].nops = 0;
        block_append_inst(cb, pn);
        let pnm = name_plus(cb, ".op");
        set_name(pn, pnm);
        newops.push(pn);
    }
    let ct = inst_clone(term);
    block_append_inst(cb, ct);
    for k in nops(term) { set_op(ct, k, newops[k]); }
    var common_dl: i32 = -1;
    var first = true;
    for b in bbs {
        let t = block_terminator(b);
        for k in nops(t) { phi_add_incoming(newops[k], op(t, k), b); }
        let tdl = inst_get_md(t, MDK_DBG_SC);
        if first || common_dl < 0 { common_dl = tdl; first = false; }
        else { common_dl = merged_location(common_dl, tdl); }
        let br = create_inst(OP_BR, T_VOID, [cb]);
        block_append_inst(b, br);
        if tdl >= 0 { inst_set_md(br, MDK_DBG_SC, tdl); }
        scf_erase(t);
        if cu_dtu { cu_upd(ups, DT_INSERT, b, cb); }
    }
    if common_dl >= 0 { inst_set_md(ct, MDK_DBG_SC, common_dl); } else { inst_erase_md(ct, MDK_DBG_SC); }
    return true;
}

fn tail_merge_blocks_with_similar_function_terminators(fv: i32) -> bool {
    var rets: i32[>..<] = [];
    var resumes: i32[>..<] = [];
    var order: i64[>..<] = [];    // SmallMapVector key insertion order: OP_RET / OP_RESUME
    var b = func_first_block(fv);
    while b >= 0 {
        let bb = b;
        b = block_next(b);
        if cu_dtu && dtu_is_bb_pending_deletion(bb) { continue; }
        if block_nsucc(bb) != 0 { continue; }
        let t = block_terminator(bb);
        let o = iop(t);
        if o != OP_RET && o != OP_RESUME { continue; }
        if cu_terminating_musttail_call(bb) >= 0 { continue; }
        let p = inst_prev(t);
        if p >= 0 && iop(p) == OP_CALL {
            let f = called_function(p);
            if f >= 0 && func_iid(f) == IID_experimental_deoptimize { continue; }
        }
        var tok = false;
        for k in nops(t) { if ty_kind(vals[op(t, k)].ty) == TK_TOKEN { tok = true; } }
        if tok { continue; }
        if position(order, o) < 0 { order.push(o); }
        if o == OP_RET { rets.push(bb); } else { resumes.push(bb); }
    }
    var changed = false;
    var ups: DTUpdate[>..<] = [];
    for o in order {
        if o == OP_RET { if perform_block_tail_merging(fv, rets, ups) { changed = true; } }
        else { if perform_block_tail_merging(fv, resumes, ups) { changed = true; } }
    }
    cu_apply(ups);
    return changed;
}

fn iteratively_simplify_cfg(fv: i32) -> bool {
    var changed = false;
    var local_change = true;
    var edges: i32[>..<] = [];
    cu_find_function_backedges(fv, edges);
    scf_loop_headers.clear();
    var k: i64 = 0;
    while k < edges.len { cu_push_unique(scf_loop_headers, edges[k + 1]); k += 2; }
    var iters = 0;
    while local_change {
        iters++;
        if iters > 2000 { fatal("SimplifyCFG: iterative simplification didn't converge"); }
        local_change = false;
        var it = func_first_block(fv);
        while it >= 0 {
            let bb = it;
            it = block_next(it);
            if cu_dtu {
                while it >= 0 && dtu_is_bb_pending_deletion(it) { it = block_next(it); }
            }
            if simplify_cfg_block(bb) { local_change = true; }
            // the next block may have been deleted by this iteration (LLVM's iterator stays valid because
            // simplifyCFG only deletes BB itself or blocks that are not the next one)
            if it >= 0 && is_dead(it) { fatal("internal: SimplifyCFG deleted the next block"); }
        }
        if local_change { changed = true; }
    }
    return changed;
}

fn simplify_function_cfg_impl(fv: i32) -> bool {
    var ever = cu_remove_unreachable_blocks(fv);
    if tail_merge_blocks_with_similar_function_terminators(fv) { ever = true; }
    if iteratively_simplify_cfg(fv) { ever = true; }
    if !ever { return false; }
    if !cu_remove_unreachable_blocks(fv) { return true; }
    loop {
        ever = iteratively_simplify_cfg(fv);
        if cu_remove_unreachable_blocks(fv) { ever = true; }
        if !ever { break; }
    }
    return true;
}

// Command-line overrides (applyCommandLineOverridesToOptions) and the cl::opts read by SimplifyCFG.cpp
fn scf_read_flags() {
    if flag_given("bonus-inst-threshold") { so.bonus = flag_int("bonus-inst-threshold", 1); }
    if flag_given("forward-switch-cond") { so.fwd_switch_cond = flag_bool("forward-switch-cond", false); }
    if flag_given("switch-range-to-icmp") { so.range_to_icmp = flag_bool("switch-range-to-icmp", false); }
    if flag_given("switch-to-lookup") { so.to_lookup = flag_bool("switch-to-lookup", false); }
    if flag_given("keep-loops") { so.keep_loops = flag_bool("keep-loops", true); }
    if flag_given("hoist-common-insts") { so.hoist_common = flag_bool("hoist-common-insts", false); }
    if flag_given("hoist-loads-stores-with-cond-faulting") { so.hoist_ldst_cf = flag_bool("hoist-loads-stores-with-cond-faulting", false); }
    if flag_given("sink-common-insts") { so.sink_common = flag_bool("sink-common-insts", false); }
    if flag_given("speculate-unpredictables") { so.spec_unpred = flag_bool("speculate-unpredictables", false); }
    cl_phi_fold_threshold = flag_int("phi-node-folding-threshold", 2);
    cl_two_entry_phi_threshold = flag_int("two-entry-phi-node-folding-threshold", 4);
    cl_hoist_common = flag_bool("simplifycfg-hoist-common", true);
    cl_hoist_loads_cf = flag_bool("simplifycfg-hoist-loads-with-cond-faulting", true);
    cl_hoist_stores_cf = flag_bool("simplifycfg-hoist-stores-with-cond-faulting", true);
    cl_hoist_ldst_cf_threshold = flag_int("hoist-loads-stores-with-cond-faulting-threshold", 6);
    cl_hoist_skip_limit = flag_int("simplifycfg-hoist-common-skip-limit", 20);
    cl_sink_common = flag_bool("simplifycfg-sink-common", true);
    cl_hoist_cond_stores = flag_bool("simplifycfg-hoist-cond-stores", true);
    cl_merge_cond_stores = flag_bool("simplifycfg-merge-cond-stores", true);
    cl_merge_cond_stores_aggr = flag_bool("simplifycfg-merge-cond-stores-aggressively", false);
    cl_spec_one_expensive = flag_bool("speculate-one-expensive-inst", true);
    cl_max_spec_depth = flag_int("max-speculation-depth", 10);
    cl_max_small_block = flag_int("simplifycfg-max-small-block-size", 10);
    cl_branch_fold_threshold = flag_int("simplifycfg-branch-fold-threshold", 2);
    cl_branch_fold_vec_mult = flag_int("simplifycfg-branch-fold-common-dest-vector-multiplier", 2);
    cl_merge_invokes = flag_bool("simplifycfg-merge-compatible-invokes", true);
    cl_max_switch_cases_per_result = flag_int("max-switch-cases-per-result", 16);
    cl_max_jt_live_blocks = flag_int("max-jump-threading-live-blocks", 24);
    cu_max_phi_entries_increase = flag_int("max-phi-entries-increase-after-removing-empty-block", 1000);
}

// SimplifyCFGPass::run(F, AM); opts are the pass parameters (simplifycfg<...>).
fn simplifycfg_run(fv: i32, opts: SCOpts) -> u32 {
    so = opts;
    scf_read_flags();
    scf_fn = fv;
    tli_cur_fn_sc(fv);
    tti_init_function(fv, globs[glob_of(fv)].module);
    let save_tli = local_have_tli;
    local_have_tli = false;
    let require_dt = flag_bool("simplifycfg-require-and-preserve-domtree", false);
    if require_dt { dt_get(fv, DT_DOM); }
    cu_dtu = require_dt;
    cu_dead_ba.clear();
    dtu_begin(fv, require_dt, false, false);
    ac_invalidate();
    vt_invalidate_assumes();
    let changed = simplify_function_cfg_impl(fv);
    dtu_end();
    cu_dtu = false;
    local_have_tli = save_tli;
    ac_invalidate();
    vt_invalidate_assumes();
    scf_fn = -1;
    if !changed { return PA_ALL; }
    cu_renumber_blocks(fv);
    if require_dt { return (1 as u32) << A_DOMTREE; }
    return PA_NONE;
}
fn tli_cur_fn_sc(fv: i32) { }
