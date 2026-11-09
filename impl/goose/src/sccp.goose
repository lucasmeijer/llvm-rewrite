// Sparse conditional constant propagation: the solver is a port of llvm/lib/Transforms/Utils/SCCPSolver.cpp
// (SCCPInstVisitor + SCCPSolver), the passes are ports of llvm/lib/Transforms/Scalar/SCCP.cpp (sccp) and
// llvm/lib/Transforms/IPO/SCCP.cpp (ipsccp), with llvm/lib/Analysis/ValueLatticeUtils.cpp (the canTrack*
// predicates). Lattice: valuelattice.goose; ranges: constrange.goose; SSA copies: predinfo.goose.
//
// One solver exists at a time; its state lives in the sc_* globals and is reset by sc_init().
// Containers follow LLVM's: InstWorkList is a SetVector (array + in-list bit, pop from the back), BBWorkList a
// vector, KnownFeasibleEdges a set of (from, to), TrackedRetVals / TrackedMultipleRetVals MapVectors
// (insertion order), AdditionalUsers per value a SetVector (insertion order). Function specialization
// (FunctionSpecialization.cpp) is not ported: it fails loudly when a candidate function is large enough to
// be considered.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import domtree;
import dtu;
import dinfo;
import apint;
import constrange;
import valuelattice;
import predinfo;
import constfold;
import cfold;
import instsimplify;
import pm;
import vt;
import poison;
import local;
import tli;
import mem2reg;
import implied;
import analyses;

fn sc_not_ported(what: const u8[:]) { fatal(str("SCCP: ", what, " is not ported yet")); }

let MAX_NUM_RANGE_EXTENSIONS = 10;

// per-value record (valid when stamp == sc_epoch)
struct ScRec { stamp: u32, st: i32, sst: i32, au: i32, ret: i32, mrv: i32, glob: i32, bits: u32, ord: i32 }
let SB_EXEC: u32 = 1;
let SB_VISITED: u32 = 2;
let SB_INWL: u32 = 4;
let SB_ARGTRACK: u32 = 8;
let SB_MUSTPRES: u32 = 16;
let SB_HASPI: u32 = 32;
let SB_INSERTED: u32 = 64;
let SB_NUMBERED: u32 = 128;      // block: instruction order numbers (rec.ord) are valid

var sc_recs: ScRec[>..];
var sc_epoch: u32 = 0;
var sc_vls: VL[>..<];             // lattice elements (ValueState, StructValueState, tracked rets/globals)
var sc_iwl: i32[>..<];            // InstWorkList
var sc_bbwl: i32[>..<];           // BBWorkList
var sc_cur: i32 = -1;             // CurI
var sc_edges: i64[>..<];          // KnownFeasibleEdges (open addressing, -1 empty)
var sc_nedges: i64 = 0;
var sc_ret_fn: i32[>..<];         // TrackedRetVals: function, lattice index
var sc_ret_vl: i32[>..<];
var sc_mrv_fn: i32[>..<];         // MRVFunctionsTracked (insertion order); rec.mrv = first lattice index
var sc_glob_gv: i32[>..<];        // TrackedGlobals (insertion order; rec.glob = lattice index or -1 if erased)
var sc_argfns: i32[>..<];         // TrackingIncomingArguments
var sc_au_user: i32[>..<];        // AdditionalUsers nodes
var sc_au_next: i32[>..<];
var sc_ipsccp: bool = false;      // GetTLI returns the callee's TLI (ipsccp) or the pass function's (sccp)
var sc_fn: i32 = -1;              // the function sccp runs on

fn sc_init(ipsccp: bool) {
    sc_epoch += 1;
    sc_vls.clear(); sc_iwl.clear(); sc_bbwl.clear(); sc_cur = -1;
    sc_edges.clear(); sc_edges.resize(64, -1); sc_nedges = 0;
    sc_ret_fn.clear(); sc_ret_vl.clear(); sc_mrv_fn.clear(); sc_glob_gv.clear(); sc_argfns.clear();
    sc_au_user.clear(); sc_au_next.clear();
    sc_ipsccp = ipsccp;
    pi_reset();
}
fn sc_r(v: i32) -> i64 {
    while sc_recs.len <= (v as i64) { sc_recs.push(ScRec { stamp: 0, st: -1, sst: -1, au: -1, ret: -1, mrv: -1, glob: -1, bits: 0, ord: 0 }); }
    if sc_recs[v].stamp != sc_epoch { sc_recs[v] = ScRec { stamp: sc_epoch, st: -1, sst: -1, au: -1, ret: -1, mrv: -1, glob: -1, bits: 0, ord: 0 }; }
    return v as i64;
}
fn sc_bit(v: i32, b: u32) -> bool { (v as i64) < sc_recs.len && sc_recs[v].stamp == sc_epoch && (sc_recs[v].bits & b) != 0 }
fn sc_set_bit(v: i32, b: u32) { let k = sc_r(v); sc_recs[k].bits = sc_recs[k].bits | b; }
fn sc_clear_bit(v: i32, b: u32) { if sc_bit(v, b) { sc_recs[v].bits = sc_recs[v].bits & ~b; } }
fn sc_new_vl(l: VL) -> i32 { let i = sc_vls.len as i32; sc_vls.push(l); return i; }

// ---------------------------------------------------------------------------------------------
// KnownFeasibleEdges

fn sc_edge_key(a: i32, b: i32) -> i64 { ((a as i64) << 32) | (b as i64) }
fn sc_edge_slot(k: i64) -> i64 {
    let mask = sc_edges.len - 1;
    var h = ((k as! u64) * 0x9E3779B97F4A7C15) >> 20;
    var j = (h as! i64) & mask;
    while sc_edges[j] != -1 && sc_edges[j] != k { j = (j + 1) & mask; }
    return j;
}
fn sc_edge_has(a: i32, b: i32) -> bool { let k = sc_edge_key(a, b); return sc_edges[sc_edge_slot(k)] == k; }
fn sc_edge_add(a: i32, b: i32) -> bool {
    let k = sc_edge_key(a, b);
    let j = sc_edge_slot(k);
    if sc_edges[j] == k { return false; }
    sc_edges[j] = k;
    sc_nedges += 1;
    if sc_nedges * 2 > sc_edges.len {
        var old: i64[>..<] = [];
        for x in sc_edges { if x != -1 { old.push(x); } }
        let n = sc_edges.len * 2;
        sc_edges.clear();
        sc_edges.resize(n, -1);
        for x in old { sc_edges[sc_edge_slot(x)] = x; }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Lattice access

fn sc_is_struct(v: i32) -> bool { ty_is_struct(vals[v].ty) }

// ValueState[V] (default-constructed if missing)
fn sc_vs(v: i32) -> i32 {
    let k = sc_r(v);
    if sc_recs[k].st < 0 { let i = sc_new_vl(vl_unknown()); sc_recs[k].st = i; }
    return sc_recs[k].st;
}
// getValueState(V): constants are seeded
fn sc_gvs(v: i32) -> i32 {
    if sc_is_struct(v) { fatal("internal: SCCP getValueState on a struct value"); }
    let k = sc_r(v);
    if sc_recs[k].st >= 0 { return sc_recs[k].st; }
    var l = vl_unknown();
    if is_constant(v) { vl_mark_constant(l, v, false); }
    let i = sc_new_vl(l);
    sc_recs[k].st = i;
    return i;
}
fn sc_has_vs(v: i32) -> bool { (v as i64) < sc_recs.len && sc_recs[v].stamp == sc_epoch && sc_recs[v].st >= 0 }
// getStructValueState(V, i)
fn sc_gsvs(v: i32, i: i64) -> i32 {
    let k = sc_r(v);
    if sc_recs[k].sst < 0 {
        let n = ty_count(vals[v].ty);
        let base = sc_vls.len as i32;
        for j in n {
            var l = vl_unknown();
            if is_constant(v) {
                let e = c_aggregate_element(v, j);
                if e < 0 { vl_mark_overdefined(l); } else { vl_mark_constant(l, e, false); }
            }
            sc_vls.push(l);
        }
        sc_recs[k].sst = base;
    }
    return sc_recs[k].sst + (i as i32);
}
fn sc_has_svs(v: i32) -> bool { (v as i64) < sc_recs.len && sc_recs[v].stamp == sc_epoch && sc_recs[v].sst >= 0 }

fn sc_gv(v: i32) -> VL { let k = sc_gvs(v); return sc_vls[k]; }
fn sc_vsv(v: i32) -> VL { let k = sc_vs(v); return sc_vls[k]; }
fn sc_gsv(v: i32, i: i64) -> VL { let k = sc_gsvs(v, i); return sc_vls[k]; }
fn sc_lattice(v: i32) -> VL {
    if !sc_has_vs(v) { fatal("internal: SCCP: V not found in ValueState"); }
    return sc_vls[sc_recs[v].st];
}

// ---------------------------------------------------------------------------------------------
// Worklists and marking

// Instruction::comesBefore with per-block order numbers (the IR does not change while the solver runs)
fn sc_comes_before(a: i32, b: i32) -> bool {
    let bb = inst_parent(a);
    if !sc_bit(bb, SB_NUMBERED) {
        sc_set_bit(bb, SB_NUMBERED);
        var i = block_first(bb);
        var n: i32 = 0;
        while i >= 0 { let k = sc_r(i); sc_recs[k].ord = n; n++; i = inst_next(i); }
    }
    let ka = sc_r(a);
    let kb = sc_r(b);
    return sc_recs[ka].ord < sc_recs[kb].ord;
}

fn sc_push_to_worklist(i: i32) {
    if sc_cur >= 0 && inst_parent(i) == inst_parent(sc_cur) && sc_comes_before(sc_cur, i) { return; }
    if sc_bit(inst_parent(i), SB_VISITED) {
        if !sc_bit(i, SB_INWL) { sc_set_bit(i, SB_INWL); sc_iwl.push(i); }
    }
}
fn sc_push_users(v: i32) {
    if has_use_list(v) {
        var u = first_use(v);
        while u >= 0 {
            let us = uses[u].user;
            let nu = use_next(u);
            if is_inst(us) { sc_push_to_worklist(us); }
            u = nu;
        }
    }
    if (v as i64) < sc_recs.len && sc_recs[v].stamp == sc_epoch && sc_recs[v].au >= 0 {
        var tonotify: i32[>..<] = [];
        var n = sc_recs[v].au;
        while n >= 0 { if is_inst(sc_au_user[n]) { tonotify.push(sc_au_user[n]); } n = sc_au_next[n]; }
        for x in tonotify { sc_push_to_worklist(x); }
    }
}
fn sc_add_additional_user(v: i32, u: i32) {
    let k = sc_r(v);
    var n = sc_recs[k].au;
    var last: i32 = -1;
    while n >= 0 { if sc_au_user[n] == u { return; } last = n; n = sc_au_next[n]; }
    let id = sc_au_user.len as i32;
    sc_au_user.push(u);
    sc_au_next.push(-1);
    if last < 0 { sc_recs[k].au = id; } else { sc_au_next[last] = id; }
}

fn sc_mark_constant_iv(iv: i32, v: i32, c: i32, may_include_undef: bool) -> bool {
    if !vl_mark_constant(sc_vls[iv], c, may_include_undef) { return false; }
    sc_push_users(v);
    return true;
}
fn sc_mark_not_constant(iv: i32, v: i32, c: i32) -> bool {
    if !vl_mark_not_constant(sc_vls[iv], c) { return false; }
    sc_push_users(v);
    return true;
}
fn sc_mark_not_null(iv: i32, v: i32) -> bool { sc_mark_not_constant(iv, v, c_null(vals[v].ty)) }
fn sc_mark_overdefined_iv(iv: i32, v: i32) -> bool {
    if !vl_mark_overdefined(sc_vls[iv]) { return false; }
    sc_push_users(v);
    return true;
}
fn sc_merge_in_value(iv: i32, v: i32, rhs: VL, o: VLOpts) -> bool {
    if vl_merge_in(sc_vls[iv], rhs, o) { sc_push_users(v); return true; }
    return false;
}
// markOverdefined(Value *V)
fn sc_mark_overdefined(v: i32) {
    if sc_is_struct(v) {
        for i in ty_count(vals[v].ty) { sc_mark_overdefined_iv(sc_gsvs(v, i), v); }
    } else {
        sc_mark_overdefined_iv(sc_vs(v), v);
    }
}
fn sc_mark_block_executable(bb: i32) -> bool {
    if sc_bit(bb, SB_EXEC) { return false; }
    sc_set_bit(bb, SB_EXEC);
    sc_bbwl.push(bb);
    return true;
}
fn sc_mark_edge_executable(src: i32, dst: i32) -> bool {
    if !sc_edge_add(src, dst) { return false; }
    if !sc_mark_block_executable(dst) {
        var i = block_first(dst);
        while i >= 0 && iop(i) == OP_PHI { sc_push_to_worklist(i); i = inst_next(i); }
    }
    return true;
}

// getConstant(LV, Ty)
fn sc_get_constant(l: VL, ty: i32) -> i32 {
    if vl_is_constant(l) { return l.c; }
    if vl_is_range(l, true) && rg_is_single(l.r) { return ap_to_cint(ty, l.r.lo); }
    return -1;
}
fn sc_get_constant_int(l: VL, ty: i32) -> i32 {
    let c = sc_get_constant(l, ty);
    // dyn_cast<ConstantInt>: a vector-typed splat ConstantInt too
    if c >= 0 && vals[c].kind == VK_CINT { return c; }
    return -1;
}
// SCCPSolver::isConstant / isOverdefined
fn sc_is_constant_lv(l: VL) -> bool { vl_is_constant(l) || (vl_is_range(l, true) && rg_is_single(l.r)) }
fn sc_is_overdefined_lv(l: VL) -> bool { !vl_is_unknown_or_undef(l) && !sc_is_constant_lv(l) }

// getConstantOrNull(V)
fn sc_get_constant_or_null(v: i32) -> i32 {
    let ty = vals[v].ty;
    if sc_is_struct(v) {
        let n = ty_count(ty);
        if n == 0 { return c_aggregate(ty, []); }
        if !sc_has_svs(v) { fatal("internal: SCCP: struct value not in valuemap"); }
        for i in n { if sc_is_overdefined_lv(sc_vls[sc_recs[v].sst + (i as i32)]) { return -1; } }
        var elems: i32[>..<] = [];
        for i in n {
            let l = sc_vls[sc_recs[v].sst + (i as i32)];
            let et = ty_field(ty, i);
            elems.push(if sc_is_constant_lv(l) { sc_get_constant(l, et) } else { c_undef(et) });
        }
        return c_aggregate(ty, elems);
    }
    let l = sc_lattice(v);
    if sc_is_overdefined_lv(l) { return -1; }
    return if sc_is_constant_lv(l) { sc_get_constant(l, ty) } else { c_undef(ty) };
}

// ---------------------------------------------------------------------------------------------
// Tracking setup

fn sc_track_global(gv: i32) {
    let vt0 = globs[glob_of(gv)].vty;
    if !sc_single_value_type(vt0) { return; }
    let k = sc_r(gv);
    if sc_recs[k].glob < 0 { sc_recs[k].glob = sc_new_vl(vl_unknown()); sc_glob_gv.push(gv); }
    vl_mark_constant(sc_vls[sc_recs[k].glob], op(gv, 0), false);
}
fn sc_single_value_type(t: i32) -> bool {
    let k = ty_kind(t);
    return ty_is_fp(t) || k == TK_INT || k == TK_PTR || k == TK_FVEC || k == TK_SVEC || k == TK_X86_AMX || k == TK_TARGETEXT || k == TK_BYTE;
}
fn sc_add_tracked_function(f: i32) {
    let rt = ty_fn_ret(globs[glob_of(f)].vty);
    let k = sc_r(f);
    if ty_is_struct(rt) {
        if sc_recs[k].mrv < 0 {
            sc_mrv_fn.push(f);
            let base = sc_vls.len as i32;
            for i in ty_count(rt) { sc_vls.push(vl_unknown()); }
            sc_recs[k].mrv = base;
        }
    } else if ty_kind(rt) != TK_VOID {
        if sc_recs[k].ret < 0 {
            sc_recs[k].ret = sc_ret_fn.len as i32;
            sc_ret_fn.push(f);
            sc_ret_vl.push(sc_new_vl(vl_unknown()));
        }
    }
}
fn sc_ret_index(f: i32) -> i32 { if (f as i64) < sc_recs.len && sc_recs[f].stamp == sc_epoch { sc_recs[f].ret } else { -1 } }
fn sc_mrv_base(f: i32) -> i32 { if (f as i64) < sc_recs.len && sc_recs[f].stamp == sc_epoch { sc_recs[f].mrv } else { -1 } }
fn sc_add_arg_tracked(f: i32) { if !sc_bit(f, SB_ARGTRACK) { sc_set_bit(f, SB_ARGTRACK); sc_argfns.push(f); } }

// getArgAttributeVL
fn sc_arg_attr_vl(a: i32) -> VL {
    let t = vals[a].ty;
    if is_int_or_int_vec(t) {
        let ok, r = rg_from_range_attr(arg_attrs(a));
        if ok { return vl_get_range(r, false); }
    }
    if sc_arg_has_nonnull(a) { return vl_get_not(c_null(t)); }
    return vl_overdefined();
}
// Argument::hasNonNullAttr(AllowUndefOrPoison = true)
fn sc_arg_has_nonnull(a: i32) -> bool {
    let t = vals[a].ty;
    if ty_kind(t) != TK_PTR { return false; }
    if arg_has_attr(a, AK_NonNull) { return true; }
    let d = aset_find(arg_attrs(a), AK_Dereferenceable);
    let f = args_parent[vals[a].sub];
    if d >= 0 && attrs[d].i1 > 0 && !null_pointer_is_defined(f, ptr_as(t)) { return true; }
    return false;
}
fn sc_track_value_of_argument(a: i32) {
    if sc_is_struct(a) { sc_mark_overdefined(a); return; }
    sc_merge_in_value(sc_vs(a), a, sc_arg_attr_vl(a), vl_opts());
}

// ---------------------------------------------------------------------------------------------
// Visitors

fn sc_visit(i: i32) {
    let o = iop(i);
    if o == OP_PHI { sc_visit_phi(i); return; }
    if o == OP_RET { sc_visit_ret(i); return; }
    if o == OP_BR || o == OP_CONDBR || o == OP_SWITCH || o == OP_INDIRECTBR || o == OP_CLEANUPRET || o == OP_CATCHRET {
        sc_visit_terminator(i); return;
    }
    if o == OP_RESUME || o == OP_UNREACHABLE || o == OP_FENCE { return; }
    if o == OP_CATCHSWITCH { sc_mark_overdefined(i); sc_visit_terminator(i); return; }
    if is_cast_op(o) { sc_visit_cast(i); return; }
    if o == OP_SELECT { sc_visit_select(i); return; }
    if o == OP_FNEG { sc_visit_unary(i); return; }
    if o == OP_FREEZE { sc_visit_freeze(i); return; }
    if is_binary_op(o) { sc_visit_binop(i); return; }
    if o == OP_ICMP || o == OP_FCMP { sc_visit_cmp(i); return; }
    if o == OP_EXTRACTVALUE { sc_visit_extractvalue(i); return; }
    if o == OP_INSERTVALUE { sc_visit_insertvalue(i); return; }
    if o == OP_STORE { sc_visit_store(i); return; }
    if o == OP_LOAD { sc_visit_load(i); return; }
    if o == OP_GEP { sc_visit_gep(i); return; }
    if o == OP_ALLOCA { sc_visit_alloca(i); return; }
    if o == OP_CALL { sc_visit_call_base(i); return; }
    if o == OP_INVOKE || o == OP_CALLBR { sc_visit_call_base(i); sc_visit_terminator(i); return; }
    // visitInstruction
    sc_mark_overdefined(i);
}

fn sc_is_inst_fully_overdefined(i: i32) -> bool {
    if sc_is_struct(i) {
        for k in ty_count(vals[i].ty) { if !vl_is_overdefined(sc_gsv(i, k)) { return false; } }
        return true;
    }
    return vl_is_overdefined(sc_gv(i));
}

fn sc_visit_phi(pn: i32) {
    let n = phi_nincoming(pn);
    if n > 64 { sc_mark_overdefined(pn); return; }
    if sc_is_inst_fully_overdefined(pn) { return; }
    var feas: i32[>..<] = [];
    let bb = inst_parent(pn);
    for k in n { if sc_edge_has(phi_block(pn, k), bb) { feas.push(k as i32); } }
    if sc_is_struct(pn) {
        for e in ty_count(vals[pn].ty) {
            var st = sc_gsv(pn, e);
            if vl_is_overdefined(st) { continue; }
            for k in feas {
                let iv = sc_gsv(phi_value(pn, k as i64), e);
                vl_merge_in(st, iv, vl_opts());
                if vl_is_overdefined(st) { break; }
            }
            let r = sc_gsvs(pn, e);
            sc_merge_in_value(r, pn, st, vl_opts_widen((feas.len + 1) as i64));
            let m = if (feas.len as i64) > (sc_vls[r].nre as i64) { feas.len as i64 } else { sc_vls[r].nre as i64 };
            sc_vls[r].nre = if m > 255 { 255 as u8 } else { m as u8 };
        }
        return;
    }
    var st = sc_gv(pn);
    for k in feas {
        let iv = sc_gv(phi_value(pn, k as i64));
        vl_merge_in(st, iv, vl_opts());
        if vl_is_overdefined(st) { break; }
    }
    let r = sc_vs(pn);
    sc_merge_in_value(r, pn, st, vl_opts_widen((feas.len + 1) as i64));
    let m = if (feas.len as i64) > (sc_vls[r].nre as i64) { feas.len as i64 } else { sc_vls[r].nre as i64 };
    sc_vls[r].nre = if m > 255 { 255 as u8 } else { m as u8 };
}

fn sc_visit_ret(i: i32) {
    if nops(i) == 0 { return; }
    let f = inst_func(i);
    let rv = op(i, 0);
    if sc_ret_fn.len > 0 && !sc_is_struct(rv) {
        let ri = sc_ret_index(f);
        if ri >= 0 {
            sc_merge_in_value(sc_ret_vl[ri], f, sc_gv(rv), vl_opts());
            return;
        }
    }
    if sc_mrv_fn.len > 0 && sc_is_struct(rv) {
        let base = sc_mrv_base(f);
        if base >= 0 {
            for k in ty_count(vals[rv].ty) {
                sc_merge_in_value(base + (k as i32), f, sc_gsv(rv, k), vl_opts());
            }
        }
    }
}

// Instruction::isSpecialTerminator
fn sc_is_special_terminator(o: i64) -> bool {
    return o == OP_CATCHSWITCH || o == OP_CATCHRET || o == OP_CLEANUPRET || o == OP_INVOKE || o == OP_RESUME || o == OP_CALLBR;
}

// getFeasibleSuccessors
fn sc_feasible_successors(ti: i32, succs: bool[>..<]&) {
    let n = term_nsucc(ti);
    succs.clear();
    succs.resize(n, false);
    let o = iop(ti);
    if o == OP_BR { succs[0] = true; return; }
    if o == OP_CONDBR {
        let c = op(ti, 0);
        let bc = sc_gv(c);
        let ci = sc_get_constant_int(bc, vals[c].ty);
        if ci < 0 {
            if !vl_is_unknown_or_undef(bc) { succs[0] = true; succs[1] = true; }
            return;
        }
        succs[if cint_is_zero(ci) { 1 } else { 0 }] = true;
        return;
    }
    if sc_is_special_terminator(o) { for k in n { succs[k] = true; } return; }
    if o == OP_SWITCH {
        let ncases = n - 1;
        if ncases == 0 { succs[0] = true; return; }
        let c = op(ti, 0);
        let sv = sc_gv(c);
        let ci = sc_get_constant_int(sv, vals[c].ty);
        if ci >= 0 {
            var idx: i64 = 0;
            for k in ncases { if switch_case_value(ti, k) == ci { idx = k + 1; break; } }
            succs[idx] = true;
            return;
        }
        if vl_is_range(sv, false) {
            let r = sv.r;
            var reach: u64 = 0;
            for k in ncases {
                if rg_contains_ap(r, ap_from_cint(switch_case_value(ti, k))) { succs[k + 1] = true; reach += 1; }
            }
            succs[0] = rg_is_size_larger_than(r, reach);
            return;
        }
        if !vl_is_unknown_or_undef(sv) { for k in n { succs[k] = true; } }
        return;
    }
    if o == OP_INDIRECTBR {
        let a = op(ti, 0);
        let av = sc_gv(a);
        let c = sc_get_constant(av, vals[a].ty);
        if c < 0 || vals[c].kind != VK_BLOCKADDR {
            if !vl_is_unknown_or_undef(av) { for k in n { succs[k] = true; } }
            return;
        }
        let t = op(c, 1);
        for k in n { if term_succ(ti, k) == t { succs[k] = true; return; } }
        return;
    }
    fatal("SCCP: Don't know how to handle this terminator!");
}

fn sc_visit_terminator(ti: i32) {
    var succs: bool[>..<] = [];
    sc_feasible_successors(ti, succs);
    let bb = inst_parent(ti);
    for k in succs.len { if succs[k] { sc_mark_edge_executable(bb, term_succ(ti, k)); } }
}

fn sc_visit_cast(i: i32) {
    if vl_is_overdefined(sc_vsv(i)) { return; }
    let src = op(i, 0);
    if iop(i) == OP_BITCAST && vals[i].ty == vals[src].ty {
        let pi = pi_info_for_fn(i);
        if pi >= 0 { sc_handle_predicate(i, src, pi); return; }
    }
    let ost = sc_gv(src);
    if vl_is_unknown_or_undef(ost) { return; }
    let opc = sc_get_constant(ost, vals[src].ty);
    if opc >= 0 {
        let c = cf_fold_cast_operand(iop(i), opc, vals[i].ty);
        if c >= 0 {
            sc_merge_in_value(sc_vs(i), i, vl_get(c), vl_opts());
            return;
        }
    }
    let dt = vals[i].ty;
    let st = vals[src].ty;
    if is_int_or_int_vec(dt) && is_int_or_int_vec(st) && iop(i) != OP_BITCAST {
        let orng = vl_as_range_ty(ost, st, false);
        let lv = sc_gvs(i);
        let dw = ty_bits(ty_scalar(dt));
        var res = rg_empty(dw);
        if iop(i) == OP_TRUNC {
            let fl = insts[inst_of(i)].flags;
            var nwk: i64 = 0;
            if (fl & FL_NUW) != 0 { nwk |= NW_NUW; }
            if (fl & FL_NSW) != 0 { nwk |= NW_NSW; }
            res = rg_truncate_nw(orng, dw, nwk);
        } else {
            res = rg_cast(iop(i), orng, dw);
        }
        sc_merge_in_value(lv, i, vl_get_range(res, false), vl_opts());
    } else {
        sc_mark_overdefined(i);
    }
}

// FnPredicateInfo lookup: only functions that got predicate info
fn pi_info_for_fn(i: i32) -> i32 {
    if !sc_bit(inst_func(i), SB_HASPI) { return -1; }
    return pi_info_for(i);
}

fn sc_with_overflow_op(id: i32) -> i64 {
    if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow { return OP_ADD; }
    if id == IID_usub_with_overflow || id == IID_ssub_with_overflow { return OP_SUB; }
    if id == IID_umul_with_overflow || id == IID_smul_with_overflow { return OP_MUL; }
    return -1;
}
fn sc_with_overflow_signed(id: i32) -> bool { id == IID_sadd_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow }

fn sc_handle_extract_of_with_overflow(evi: i32, wo: i32, idx: i64) {
    let l = cb_arg(wo, 0);
    let r = cb_arg(wo, 1);
    let ty = vals[l].ty;
    sc_add_additional_user(l, evi);
    sc_add_additional_user(r, evi);
    let ls = sc_gv(l);
    if vl_is_unknown_or_undef(ls) { return; }
    let lr = vl_as_range_ty(ls, ty, false);
    let rs = sc_gv(r);
    if vl_is_unknown_or_undef(rs) { return; }
    let rr = vl_as_range_ty(rs, ty, false);
    let id = call_iid(wo);
    let bo = sc_with_overflow_op(id);
    if idx == 0 {
        let res = rg_binop(bo, lr, rr);
        sc_merge_in_value(sc_vs(evi), evi, vl_get_range(res, false), vl_opts());
    } else {
        let nwk = if sc_with_overflow_signed(id) { NW_NSW } else { NW_NUW };
        let reg = rg_guaranteed_no_wrap(bo, rr, nwk);
        if rg_contains(reg, lr) { sc_mark_constant_iv(sc_vs(evi), evi, c_false_ty(vals[evi].ty), false); return; }
        sc_mark_overdefined(evi);
    }
}
fn c_false_ty(t: i32) -> i32 { get_false(t) }

fn sc_visit_extractvalue(evi: i32) {
    if sc_is_struct(evi) { sc_mark_overdefined(evi); return; }
    if vl_is_overdefined(sc_vsv(evi)) { sc_mark_overdefined(evi); return; }
    let x = insts[inst_of(evi)];
    if x.naux != 1 { sc_mark_overdefined(evi); return; }
    let agg = op(evi, 0);
    if sc_is_struct(agg) {
        let i = ints[x.aux] as i64;
        if is_inst(agg) && is_callbase(agg) && sc_with_overflow_op(call_iid(agg)) >= 0 {
            sc_handle_extract_of_with_overflow(evi, agg, i);
            return;
        }
        let ev = sc_gsv(agg, i);
        sc_merge_in_value(sc_vs(evi), evi, ev, vl_opts());
    } else {
        sc_mark_overdefined(evi);
    }
}

fn sc_visit_insertvalue(ivi: i32) {
    if !sc_is_struct(ivi) { sc_mark_overdefined(ivi); return; }
    if vl_is_overdefined(sc_vsv(ivi)) { sc_mark_overdefined(ivi); return; }
    let x = insts[inst_of(ivi)];
    if x.naux != 1 { sc_mark_overdefined(ivi); return; }
    let agg = op(ivi, 0);
    let idx = ints[x.aux] as i64;
    for i in ty_count(vals[ivi].ty) {
        if i != idx {
            let ev = sc_gsv(agg, i);
            sc_merge_in_value(sc_gsvs(ivi, i), ivi, ev, vl_opts());
            continue;
        }
        let v = op(ivi, 1);
        if sc_is_struct(v) { sc_mark_overdefined_iv(sc_gsvs(ivi, i), ivi); }
        else {
            let inv = sc_gv(v);
            sc_merge_in_value(sc_gsvs(ivi, i), ivi, inv, vl_opts());
        }
    }
}

fn sc_visit_select(i: i32) {
    if sc_is_struct(i) { sc_mark_overdefined(i); return; }
    if vl_is_overdefined(sc_vsv(i)) { sc_mark_overdefined(i); return; }
    let c = op(i, 0);
    let cv = sc_gv(c);
    if vl_is_unknown_or_undef(cv) { return; }
    let ci = sc_get_constant_int(cv, vals[c].ty);
    if ci >= 0 {
        let opv = if cint_is_zero(ci) { op(i, 2) } else { op(i, 1) };
        let os = sc_gv(opv);
        sc_merge_in_value(sc_vs(i), i, os, vl_opts());
        return;
    }
    let tv = sc_gv(op(i, 1));
    let fv = sc_gv(op(i, 2));
    let st = sc_vs(i);
    var changed = vl_merge_in(sc_vls[st], tv, vl_opts());
    if vl_merge_in(sc_vls[st], fv, vl_opts()) { changed = true; }
    if changed { sc_push_users(i); }
}

fn sc_visit_unary(i: i32) {
    let v0 = sc_gv(op(i, 0));
    let iv = sc_vs(i);
    if vl_is_overdefined(sc_vls[iv]) { sc_mark_overdefined(i); return; }
    if vl_is_unknown_or_undef(v0) { return; }
    if sc_is_constant_lv(v0) {
        let c = cf_fold_unary(iop(i), sc_get_constant(v0, vals[i].ty));
        if c >= 0 { sc_mark_constant_iv(iv, i, c, false); return; }
    }
    sc_mark_overdefined(i);
}

fn sc_visit_freeze(i: i32) {
    if sc_is_struct(i) { sc_mark_overdefined(i); return; }
    let v0 = sc_gv(op(i, 0));
    let iv = sc_vs(i);
    if vl_is_overdefined(sc_vls[iv]) { sc_mark_overdefined(i); return; }
    if vl_is_unknown_or_undef(v0) { return; }
    if sc_is_constant_lv(v0) {
        let c = sc_get_constant(v0, vals[i].ty);
        if is_guaranteed_not_to_be_undef_or_poison(c, -1, 0) { sc_mark_constant_iv(iv, i, c, false); return; }
    }
    sc_mark_overdefined(i);
}

fn sc_nowrap_kind(i: i32) -> i64 {
    let fl = insts[inst_of(i)].flags;
    var k: i64 = 0;
    if (fl & FL_NUW) != 0 { k |= NW_NUW; }
    if (fl & FL_NSW) != 0 { k |= NW_NSW; }
    return k;
}
fn sc_is_overflowing_op(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL }

// simplifyBinOp(Opc, V1, V2, SimplifyQuery(DL, &I)): no DT, AC, TLI or DomConditionCache
fn sc_simplify_binop(o: i64, a: i32, b: i32, cxt: i32) -> i32 {
    let s1 = sq_no_dt; let s2 = sq_no_ac; let s3 = sq_no_tli;
    sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = simplify_binop(o, a, b, sq_new(cxt), RECURSION_LIMIT);
    sq_no_dt = s1; sq_no_ac = s2; sq_no_tli = s3;
    return r;
}

fn sc_visit_binop(i: i32) {
    let v1 = sc_gv(op(i, 0));
    let v2 = sc_gv(op(i, 1));
    let iv = sc_vs(i);
    if vl_is_overdefined(sc_vls[iv]) { return; }
    if vl_is_unknown_or_undef(v1) || vl_is_unknown_or_undef(v2) { return; }
    if vl_is_overdefined(v1) && vl_is_overdefined(v2) { sc_mark_overdefined(i); return; }
    if vl_is_constant(v1) || vl_is_constant(v2) {
        let a = if sc_is_constant_lv(v1) { sc_get_constant(v1, vals[op(i, 0)].ty) } else { op(i, 0) };
        let b = if sc_is_constant_lv(v2) { sc_get_constant(v2, vals[op(i, 1)].ty) } else { op(i, 1) };
        let r = sc_simplify_binop(iop(i), a, b, i);
        if r >= 0 && is_constant(r) {
            var nv = vl_unknown();
            vl_mark_constant(nv, r, true);
            sc_merge_in_value(sc_vs(i), i, nv, vl_opts());
            return;
        }
    }
    let ty = vals[i].ty;
    if !is_int_or_int_vec(ty) { sc_mark_overdefined(i); return; }
    let ra = vl_as_range_ty(v1, ty, false);
    let rb = vl_as_range_ty(v2, ty, false);
    let o = iop(i);
    var r = rg_empty(ty_bits(ty_scalar(ty)));
    if sc_is_overflowing_op(o) { r = rg_overflowing_binop(o, ra, rb, sc_nowrap_kind(i)); }
    else { r = rg_binop(o, ra, rb); }
    sc_merge_in_value(sc_vs(i), i, vl_get_range(r, false), vl_opts());
}

fn sc_visit_cmp(i: i32) {
    if vl_is_overdefined(sc_vsv(i)) { sc_mark_overdefined(i); return; }
    let v1 = sc_gv(op(i, 0));
    let v2 = sc_gv(op(i, 1));
    let c = vl_get_compare(v1, inst_pred(i), vals[i].ty, v2);
    if c >= 0 {
        var cv = vl_unknown();
        vl_mark_constant(cv, c, false);
        sc_merge_in_value(sc_vs(i), i, cv, vl_opts());
        return;
    }
    if (vl_is_unknown_or_undef(v1) || vl_is_unknown_or_undef(v2)) && !sc_is_constant_lv(sc_vsv(i)) { return; }
    sc_mark_overdefined(i);
}

fn sc_visit_gep(i: i32) {
    if vl_is_overdefined(sc_vsv(i)) { sc_mark_overdefined(i); return; }
    let ps = sc_gv(op(i, 0));
    if vl_is_unknown_or_undef(ps) { return; }
    if vl_is_not_constant(ps) && is_null_value(ps.c) {
        let fl = insts[inst_of(i)].flags;
        if (fl & GEP_NUW) != 0 || ((fl & GEP_INBOUNDS) != 0 && !null_pointer_is_defined(inst_func(i), ptr_as(vals[i].ty))) {
            sc_mark_not_null(sc_vs(i), i);
            return;
        }
        sc_mark_overdefined(i);
        return;
    }
    let mark = is_ops.len;
    for k in nops(i) {
        let st = sc_gv(op(i, k));
        if vl_is_unknown_or_undef(st) { is_ops.resize(mark); return; }
        let c = sc_get_constant(st, vals[op(i, k)].ty);
        if c >= 0 { is_ops.push(c); continue; }
        is_ops.resize(mark);
        sc_mark_overdefined(i);
        return;
    }
    let c = cf_fold_inst_operands(i, mark, nops(i), true);
    is_ops.resize(mark);
    if c >= 0 { sc_merge_in_value(sc_vs(i), i, vl_get(c), vl_opts()); }
    else { sc_mark_overdefined(i); }
}

fn sc_visit_alloca(i: i32) {
    if !null_pointer_is_defined(inst_func(i), ptr_as(vals[i].ty)) { sc_mark_not_null(sc_vs(i), i); return; }
    sc_mark_overdefined(i);
}

fn sc_visit_store(si: i32) {
    let v = op(si, 0);
    if sc_is_struct(v) { return; }
    let p = op(si, 1);
    if sc_glob_gv.len == 0 || !is_gvar(p) { return; }
    if !((p as i64) < sc_recs.len && sc_recs[p].stamp == sc_epoch && sc_recs[p].glob >= 0) { return; }
    let gi = sc_recs[p].glob;
    var o = vl_opts();
    o.check_widen = false;
    sc_merge_in_value(gi, p, sc_gv(v), o);
    if vl_is_overdefined(sc_vls[gi]) { sc_recs[p].glob = -1; }
}

let MDK_RANGE: i32 = 4;
let MDK_NONNULL: i32 = 11;

// getValueFromMetadata
fn sc_value_from_metadata(i: i32) -> VL {
    let t = vals[i].ty;
    if is_callbase(i) {
        if is_int_or_int_vec(t) {
            // CallBase::getRange: the call-site range intersected with the called function's
            let ok, r = rg_from_range_attr(alist_ret(insts[inst_of(i)].attrs));
            let f = called_function(i);
            var ok2 = false;
            var r2 = rg_empty(1);
            if f >= 0 { let o2, x2 = rg_from_range_attr(alist_ret(globs[glob_of(f)].attrs)); ok2 = o2; r2 = x2; }
            if ok && ok2 { return vl_get_range(rg_intersect(r, r2), false); }
            if ok { return vl_get_range(r, false); }
            if ok2 { return vl_get_range(r2, false); }
        }
        if ty_kind(t) == TK_PTR && call_return_nonnull(i) { return vl_get_not(c_null(t)); }
    }
    if is_int_or_int_vec(t) {
        let md = inst_get_md(i, MDK_RANGE);
        if md >= 0 { return vl_get_range(rg_from_range_md(md), false); }
    }
    if inst_get_md(i, MDK_NONNULL) >= 0 { return vl_get_not(c_null(t)); }
    return vl_overdefined();
}

fn sc_visit_load(i: i32) {
    if sc_is_struct(i) || inst_is_volatile(i) { sc_mark_overdefined(i); return; }
    if vl_is_overdefined(sc_vsv(i)) { sc_mark_overdefined(i); return; }
    let p = op(i, 0);
    let pv = sc_gv(p);
    if vl_is_unknown_or_undef(pv) { return; }
    if sc_is_constant_lv(pv) {
        let ptr = sc_get_constant(pv, vals[p].ty);
        let iv = sc_vs(i);
        if vals[ptr].kind == VK_CNULL {
            if null_pointer_is_defined(inst_func(i), ptr_as(vals[p].ty)) { sc_mark_overdefined_iv(iv, i); return; }
            return;
        }
        if is_gvar(ptr) && sc_glob_gv.len > 0 {
            if (ptr as i64) < sc_recs.len && sc_recs[ptr].stamp == sc_epoch && sc_recs[ptr].glob >= 0 {
                sc_merge_in_value(iv, i, sc_vls[sc_recs[ptr].glob], vl_opts_widen(MAX_NUM_RANGE_EXTENSIONS));
                return;
            }
        }
        let c = cf_fold_load_from_const_ptr(ptr, vals[i].ty, 0, false);
        if c >= 0 { sc_mark_constant_iv(iv, i, c, false); return; }
    }
    sc_merge_in_value(sc_vs(i), i, sc_value_from_metadata(i), vl_opts());
}

fn sc_visit_call_base(cb: i32) {
    sc_handle_call_result(cb);
    sc_handle_call_arguments(cb);
}

fn sc_set_tli_for(f: i32) { tli_cur_fn = if sc_ipsccp { f } else { sc_fn }; }

fn sc_handle_call_overdefined(cb: i32) {
    let f = called_function(cb);
    if ty_kind(vals[cb].ty) == TK_VOID { return; }
    if sc_is_struct(cb) { sc_mark_overdefined(cb); return; }
    if f >= 0 && func_is_decl(f) && sc_can_constant_fold_call_to(cb, f) {
        let mark = is_ops.len;
        for k in cb_nargs(cb) {
            let a = cb_arg(cb, k);
            if sc_is_struct(a) { is_ops.resize(mark); sc_mark_overdefined(cb); return; }
            if ty_kind(vals[a].ty) == TK_METADATA { continue; }
            let st = sc_gv(a);
            if vl_is_unknown_or_undef(st) { is_ops.resize(mark); return; }
            if sc_is_overdefined_lv(st) { is_ops.resize(mark); sc_mark_overdefined(cb); return; }
            is_ops.push(sc_get_constant(st, vals[a].ty));
        }
        if sc_is_overdefined_lv(sc_gv(cb)) { is_ops.resize(mark); sc_mark_overdefined(cb); return; }
        sc_set_tli_for(f);
        let c = cf_fold_call(cb, f, mark, is_ops.len - mark, true);
        is_ops.resize(mark);
        if c >= 0 { sc_merge_in_value(sc_vs(cb), cb, vl_get(c), vl_opts()); return; }
    }
    sc_merge_in_value(sc_vs(cb), cb, sc_value_from_metadata(cb), vl_opts());
}
fn sc_can_constant_fold_call_to(cb: i32, f: i32) -> bool { sc_set_tli_for(f); return can_constant_fold_call_to(cb, f); }

fn sc_handle_call_arguments(cb: i32) {
    let f = called_function(cb);
    if f < 0 || !sc_bit(f, SB_ARGTRACK) { return; }
    sc_mark_block_executable(func_entry(f));
    let fonly_reads = me_only_reads(aset_memory(alist_fn(globs[glob_of(f)].attrs)));
    for k in func_nargs(f) {
        let a = func_arg(f, k);
        let ca = cb_arg(cb, k);
        if arg_has_attr(a, AK_ByVal) && !fonly_reads { sc_mark_overdefined(a); continue; }
        if sc_is_struct(a) {
            for e in ty_count(vals[a].ty) {
                let cav = sc_gsv(ca, e);
                sc_merge_in_value(sc_gsvs(a, e), a, cav, vl_opts_widen(MAX_NUM_RANGE_EXTENSIONS));
            }
        } else {
            let cav = vl_intersect(sc_gv(ca), sc_arg_attr_vl(a));
            sc_merge_in_value(sc_vs(a), a, cav, vl_opts_widen(MAX_NUM_RANGE_EXTENSIONS));
        }
    }
}

fn sc_handle_predicate(i: i32, copy_of: i32, pi: i32) {
    let cov = sc_gv(copy_of);
    let ok, pred, other = pi_constraint(pi);
    if !ok { sc_merge_in_value(sc_vs(i), i, cov, vl_opts()); return; }
    if vl_is_unknown(sc_gv(other)) { sc_add_additional_user(other, i); return; }
    let cv = sc_gv(other);
    let iv = sc_vs(i);
    if vl_is_range(cv, true) || vl_is_range(cov, true) {
        let t = vals[copy_of].ty;
        if ty_is_vector(t) { sc_not_ported("predicates on vector values"); }
        let w = dl_type_size_in_bits(t);
        var imposed = rg_full(w);
        if vl_is_range(cv, true) { imposed = rg_allowed_icmp(pred, cv.r); }
        var cocr = vl_as_range_ty(cov, t, true);
        if rg_is_empty(cocr) { cocr = rg_full(rg_w(cocr)); }
        var ncr = rg_intersect(imposed, cocr);
        if !rg_contains(cocr, ncr) && rg_is_single_missing(cocr) { ncr = cocr; }
        sc_add_additional_user(other, i);
        sc_merge_in_value(iv, i, vl_get_range(ncr, false), vl_opts());
        return;
    } else if pred == P_EQ && (vl_is_constant(cv) || vl_is_not_constant(cv)) {
        sc_add_additional_user(other, i);
        sc_merge_in_value(iv, i, cv, vl_opts());
        return;
    } else if pred == P_NE && vl_is_constant(cv) {
        sc_add_additional_user(other, i);
        sc_merge_in_value(iv, i, vl_get_not(cv.c), vl_opts());
        return;
    }
    sc_merge_in_value(iv, i, cov, vl_opts());
}
fn dl_type_size_in_bits(t: i32) -> i64 {
    if ty_is_int(t) { return ty_bits(t); }
    if ty_kind(t) == TK_PTR { return dl_ptr(types[t].n as i64).bits; }
    sc_not_ported("predicate ranges on this type");
    return 0;
}

// getVScaleRange(F, BitWidth)
fn sc_vscale_range(f: i32, w: i64) -> CRange {
    let a = aset_find(alist_fn(func_attrs(f)), AK_VScaleRange);
    if a < 0 { return rg_new(ap_u64(1, w), ap_zero(w)); }
    let lo = attrs[a].i1 >> 32;
    let hi = attrs[a].i1 & 0xFFFFFFFF;
    let bw_lo = 64 - clz(lo);
    if bw_lo > w { return rg_empty(w); }
    let mn = ap_u64(lo, w);
    let bw_hi = 64 - clz(hi);
    if hi == 0 || bw_hi > w { return rg_new(mn, ap_zero(w)); }
    return rg_new(mn, ap_inc(ap_u64(hi, w)));
}

fn sc_handle_call_result(cb: i32) {
    let f = called_function(cb);
    let id = if is_intrinsic_inst(cb) || (iop(cb) != OP_CALL && call_iid(cb) != 0) { call_iid(cb) } else { 0 };
    if id != 0 {
        if id == IID_vscale {
            let w = ty_bits(ty_scalar(vals[cb].ty));
            sc_merge_in_value(sc_vs(cb), cb, vl_get_range(sc_vscale_range(inst_func(cb), w), false), vl_opts());
            return;
        }
        if id == IID_experimental_get_vector_length {
            let ca = cb_arg(cb, 0);
            let vf = cb_arg(cb, 1);
            let scal = !cint_is_zero(cb_arg(cb, 2));
            let cw = ty_bits(ty_scalar(vals[ca].ty));
            let vw = ty_bits(ty_scalar(vals[vf].ty));
            let w = if cw > vw { cw } else { vw };
            let cnt = rg_zext(vl_as_range_ty(sc_gv(ca), vals[ca].ty, false), w);
            var ml = rg_zext(vl_as_range_ty(sc_gv(vf), vals[vf].ty, false), w);
            if scal { ml = rg_multiply(ml, sc_vscale_range(inst_func(cb), w), 0); }
            var res = rg_nonempty(ap_zero(w), ap_inc(ap_umin(rg_umax(cnt), rg_umax(ml))));
            if rg_icmp(P_ULE, cnt, ml) { res = cnt; }
            res = rg_truncate(res, ty_bits(ty_scalar(vals[cb].ty)));
            sc_merge_in_value(sc_vs(cb), cb, vl_get_range(res, false), vl_opts());
            return;
        }
        if rg_is_intrinsic_supported(id) {
            var ranges: CRange[>..<] = [];
            for k in cb_nargs(cb) {
                let a = cb_arg(cb, k);
                let st = sc_gv(a);
                if vl_is_unknown_or_undef(st) { return; }
                ranges.push(vl_as_range_ty(st, vals[a].ty, false));
            }
            let res = rg_intrinsic(id, ranges);
            sc_merge_in_value(sc_vs(cb), cb, vl_get_range(res, false), vl_opts());
            return;
        }
    }
    if f < 0 || func_is_decl(f) { sc_handle_call_overdefined(cb); return; }
    let rt = ty_fn_ret(globs[glob_of(f)].vty);
    if ty_is_struct(rt) {
        let base = sc_mrv_base(f);
        if base < 0 { sc_handle_call_overdefined(cb); return; }
        for k in ty_count(rt) {
            let rv = sc_vls[base + (k as i32)];
            sc_merge_in_value(sc_gsvs(cb, k), cb, rv, vl_opts_widen(MAX_NUM_RANGE_EXTENSIONS));
        }
    } else {
        let ri = sc_ret_index(f);
        if ri < 0 { sc_handle_call_overdefined(cb); return; }
        sc_merge_in_value(sc_vs(cb), cb, sc_vls[sc_ret_vl[ri]], vl_opts_widen(MAX_NUM_RANGE_EXTENSIONS));
    }
}

// ---------------------------------------------------------------------------------------------
// Solving

fn sc_solve() {
    while sc_bbwl.len > 0 || sc_iwl.len > 0 {
        while sc_iwl.len > 0 {
            let i = sc_iwl.pop();
            sc_clear_bit(i, SB_INWL);
            sc_visit(i);
        }
        while sc_bbwl.len > 0 {
            let bb = sc_bbwl.pop();
            sc_set_bit(bb, SB_VISITED);
            var i = block_first(bb);
            while i >= 0 {
                sc_cur = i;
                sc_visit(i);
                i = inst_next(i);
            }
            sc_cur = -1;
        }
    }
}

fn sc_resolved_undef(i: i32) -> bool {
    let t = vals[i].ty;
    if ty_kind(t) == TK_VOID { return false; }
    if ty_is_struct(t) {
        if is_callbase(i) {
            let f = called_function(i);
            if f >= 0 && sc_mrv_base(f) >= 0 { return false; }
        }
        let o = iop(i);
        if o == OP_EXTRACTVALUE || o == OP_INSERTVALUE { return false; }
        for k in ty_count(t) {
            let lv = sc_gsvs(i, k);
            if vl_is_unknown(sc_vls[lv]) { sc_mark_overdefined_iv(lv, i); return true; }
        }
        return false;
    }
    let lv = sc_gvs(i);
    if !vl_is_unknown(sc_vls[lv]) { return false; }
    if is_callbase(i) {
        let f = called_function(i);
        if f >= 0 && sc_ret_index(f) >= 0 { return false; }
    }
    if iop(i) == OP_LOAD { return false; }
    sc_mark_overdefined(i);
    return true;
}
fn sc_resolved_undefs_in(f: i32) -> bool {
    var changed = false;
    var b = func_first_block(f);
    while b >= 0 {
        if sc_bit(b, SB_EXEC) {
            var i = block_first(b);
            while i >= 0 { if sc_resolved_undef(i) { changed = true; } i = inst_next(i); }
        }
        b = block_next(b);
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Transformation helpers

// Value::replaceAllUsesWith, including ValueAsMetadata::handleRAUW for debug records
fn sc_rauw(old: i32, nv: i32) {
    rauw(old, nv);
    if dbgrecs.len > 0 { m2r_dbg_rauw(old, nv); }
}
fn sc_erase(i: i32) { m2r_erase(i); }

fn sc_inserted(v: i32) -> bool { sc_bit(v, SB_INSERTED) }

// getRange(Op, Solver, InsertedValues)
fn sc_get_range(v: i32) -> CRange {
    if is_constant(v) { return rg_of_const(v); }
    if sc_inserted(v) { return rg_full(ty_bits(ty_scalar(vals[v].ty))); }
    return vl_as_range_ty(sc_lattice(v), vals[v].ty, false);
}

// wouldInstructionBeTriviallyDead(I) without a TargetLibraryInfo: no library allocation/free functions and no
// isMathLibCallNoop (a folded `log(1.0)` call stays)
fn sc_would_be_trivially_dead(i: i32) -> bool {
    let s = sq_no_tli;
    let t = local_have_tli;
    sq_no_tli = true;
    local_have_tli = false;
    let r = would_be_trivially_dead(i);
    sq_no_tli = s;
    local_have_tli = t;
    return r;
}

fn sc_has_bundle(cb: i32, tag: const u8[:]) -> bool {
    for k in cb_nbundles(cb) { if sbytes(cb_bundle_tag(cb, k)) == tag { return true; } }
    return false;
}
fn sc_is_musttail(cb: i32) -> bool { iop(cb) == OP_CALL && insts[inst_of(cb)].pred == 2 }

fn sc_add_must_preserve(f: i32) { sc_set_bit(f, SB_MUSTPRES); }

fn sc_try_to_replace_with_constant(v: i32) -> bool {
    let c = sc_get_constant_or_null(v);
    if c < 0 { return false; }
    if is_inst(v) && is_callbase(v) {
        if (sc_is_musttail(v) && !sc_would_be_trivially_dead(v)) || sc_has_bundle(v, "clang.arc.attachedcall") {
            let f = called_function(v);
            if f >= 0 { sc_add_must_preserve(f); }
            return false;
        }
    }
    sc_rauw(v, c);
    return true;
}

// IRBuilder/CastInst::Create insertion before `pos` (takes over the debug records at that position)
fn sc_insert_new(opc: i64, ty: i32, opsv: const i32[:], pos: i32) -> i32 {
    let v = create_inst(opc, ty, opsv);
    inst_insert_before(v, pos);
    return v;
}
fn sc_copy_dbg_loc(dst: i32, src: i32) { let dl = inst_get_md(src, 0); if dl >= 0 { inst_set_md(dst, 0, dl); } }

fn sc_refine_instruction(i: i32) -> bool {
    var changed = false;
    let o = iop(i);
    let ii = inst_of(i);
    if sc_is_overflowing_op(o) {
        let fl = insts[ii].flags;
        if (fl & FL_NSW) != 0 && (fl & FL_NUW) != 0 { return false; }
        let ra = sc_get_range(op(i, 0));
        let rb = sc_get_range(op(i, 1));
        if (fl & FL_NUW) == 0 {
            if rg_contains(rg_guaranteed_no_wrap(o, rb, NW_NUW), ra) { insts[ii].flags = insts[ii].flags | FL_NUW; changed = true; }
        }
        if (fl & FL_NSW) == 0 {
            if rg_contains(rg_guaranteed_no_wrap(o, rb, NW_NSW), ra) { insts[ii].flags = insts[ii].flags | FL_NSW; changed = true; }
        }
    } else if (o == OP_ZEXT || o == OP_UITOFP) && (insts[ii].flags & FL_NNEG) == 0 {
        if rg_is_all_nonneg(sc_get_range(op(i, 0))) { insts[ii].flags = insts[ii].flags | FL_NNEG; changed = true; }
    } else if o == OP_TRUNC {
        let fl = insts[ii].flags;
        if (fl & FL_NSW) != 0 && (fl & FL_NUW) != 0 { return false; }
        let r = sc_get_range(op(i, 0));
        let dw = ty_bits(ty_scalar(vals[i].ty));
        if (fl & FL_NUW) == 0 && rg_active_bits(r) <= dw { insts[ii].flags = insts[ii].flags | FL_NUW; changed = true; }
        if (fl & FL_NSW) == 0 && rg_min_signed_bits(r) <= dw { insts[ii].flags = insts[ii].flags | FL_NSW; changed = true; }
    } else if o == OP_GEP {
        let fl = insts[ii].flags;
        // hasNoUnsignedWrap() || !hasNoUnsignedSignedWrap()
        if (fl & GEP_NUW) != 0 || (fl & GEP_NUSW) == 0 { return false; }
        for k in 1..nops(i) { if !rg_is_all_nonneg(sc_get_range(op(i, k))) { return false; } }
        insts[ii].flags = fl | GEP_NUW;
        changed = true;
    }
    return changed;
}

fn sc_replace_signed_inst(i: i32) -> bool {
    let o = iop(i);
    var ni: i32 = -1;
    if o == OP_SITOFP || o == OP_SEXT {
        let a = op(i, 0);
        if !rg_is_all_nonneg(sc_get_range(a)) { return false; }
        ni = sc_insert_new(if o == OP_SEXT { OP_ZEXT } else { OP_UITOFP }, vals[i].ty, [a], i);
        insts[inst_of(ni)].flags = FL_NNEG;
    } else if o == OP_ASHR {
        let a = op(i, 0);
        if !rg_is_all_nonneg(sc_get_range(a)) { return false; }
        ni = sc_insert_new(OP_LSHR, vals[i].ty, [a, op(i, 1)], i);
        insts[inst_of(ni)].flags = insts[inst_of(i)].flags & FL_EXACT;
    } else if o == OP_SDIV || o == OP_SREM {
        let a = op(i, 0);
        let b = op(i, 1);
        if !rg_is_all_nonneg(sc_get_range(a)) || !rg_is_all_nonneg(sc_get_range(b)) { return false; }
        ni = sc_insert_new(if o == OP_SDIV { OP_UDIV } else { OP_UREM }, vals[i].ty, [a, b], i);
        if o == OP_SDIV { insts[inst_of(ni)].flags = insts[inst_of(i)].flags & FL_EXACT; }
    } else {
        return false;
    }
    sc_take_name(ni, i);
    sc_set_bit(ni, SB_INSERTED);
    sc_rauw(i, ni);
    sc_copy_dbg_loc(ni, i);
    // removeLatticeValueFor
    if sc_has_vs(i) { sc_recs[i].st = -1; }
    sc_erase(i);
    return true;
}

// Value::takeName(V)
fn sc_take_name(dst: i32, src: i32) {
    if vals[src].name < 0 { return; }
    var nm: u8[>..] = [];
    nm.append(val_name(src));
    set_name(src, "");
    set_name(dst, nm);
}

fn sc_is_low_bit_mask(c: i32) -> i32 {
    // m_LowBitMask: a ConstantInt (or splat) of the form 0..01..1 (non-zero)
    let s = m_apint_ap(c, true);
    if s < 0 { return -1; }
    let a = ap_from_cint(s);
    if ap_is_zero(a) { return -1; }
    if !ap_is_zero(ap_and(a, ap_inc(a))) { return -1; }
    return s;
}

fn sc_simplify_instruction(i: i32) -> i32 {
    let o = iop(i);
    // m_And(m_Value(X), m_LowBitMask(RHSC))
    if o == OP_AND {
        let m = sc_is_low_bit_mask(op(i, 1));
        if m >= 0 {
            let x = op(i, 0);
            if ap_ule(rg_umax(sc_get_range(x)), ap_from_cint(m)) { return x; }
        }
    }
    let id = inst_iid(i);
    if id == IID_scmp || id == IID_ucmp {
        let l = cb_arg(i, 0);
        let r = cb_arg(i, 1);
        let w = ty_bits(ty_scalar(vals[l].ty));
        if w == 1 { return -1; }
        let lr = sc_get_range(l);
        if rg_is_size_larger_than(lr, 3) { return -1; }
        let rr = sc_get_range(r);
        if rg_is_size_larger_than(rr, 3) { return -1; }
        let one = rg_single(ap_u64(1, w));
        let rlo = rg_sub(rr, one);
        let rhi = rg_add(rr, one);
        let p = if id == IID_scmp { P_SLE } else { P_ULE };
        if !rg_icmp(p, rlo, lr) || !rg_icmp(p, lr, rhi) { return -1; }
        var nm: u8[>..] = [];
        nm.append(val_name(i));
        var sub = sc_insert_new(OP_SUB, vals[l].ty, [l, r], i);
        if id == IID_scmp { insts[inst_of(sub)].flags = FL_NSW; }
        sc_copy_dbg_loc(sub, i);
        if nm.len > 0 { set_name(sub, nm); }
        sc_set_bit(sub, SB_INSERTED);
        if vals[sub].ty != vals[i].ty {
            let sw = ty_bits(ty_scalar(vals[sub].ty));
            let dw = ty_bits(ty_scalar(vals[i].ty));
            let co = if sw < dw { OP_SEXT } else { OP_TRUNC };
            let c = sc_insert_new(co, vals[i].ty, [sub], i);
            sc_copy_dbg_loc(c, i);
            sc_set_bit(c, SB_INSERTED);
            sub = c;
        }
        return sub;
    }
    if o == OP_ICMP {
        let rhsc = m_apint(op(i, 1));
        if rhsc < 0 { return -1; }
        let lhs = op(i, 0);
        let pred = inst_pred(i);
        var x: i32 = -1;
        var have = false;
        var cr = rg_empty(1);
        let rc = ap_from_cint(rhsc);
        // m_OneUse(m_AddLike(m_Value(X), m_APInt(Offset)))
        if sc_one_use(lhs) && (is_op(lhs, OP_ADD) || (is_op(lhs, OP_OR) && op_disjoint(lhs))) && m_apint(op(lhs, 1)) >= 0 {
            x = op(lhs, 0);
            cr = rg_subtract(rg_exact_icmp(pred, rc), ap_from_cint(m_apint(op(lhs, 1))));
            have = true;
        } else if pred == P_EQ || pred == P_NE {
            if sc_one_use(lhs) && is_op(lhs, OP_AND) {
                let mk = m_apint_ap(op(lhs, 1), true);
                if mk >= 0 {
                    let mask = ap_from_cint(mk);
                    // m_NegatedPower2: -Mask is a power of two
                    if ap_is_pow2(ap_neg(mask)) && ap_countr_zero(rc) >= ap_countr_zero(mask) {
                        x = op(lhs, 0);
                        let c0 = rg_new(rc, ap_sub(rc, mask));
                        cr = if pred == P_EQ { c0 } else { rg_inverse(c0) };
                        have = true;
                    }
                }
            }
        }
        if have {
            let lr = sc_get_range(x);
            if rg_is_full(lr) { return -1; }
            let ok1, n1 = rg_exact_intersect(cr, lr);
            if ok1 {
                let v = sc_convert_cr_to_icmp(n1, x, i);
                if v >= 0 { return v; }
            }
            let ok2, n2 = rg_exact_union(cr, rg_inverse(lr));
            if ok2 {
                let v = sc_convert_cr_to_icmp(n2, x, i);
                if v >= 0 { return v; }
            }
        }
    }
    return -1;
}
fn sc_one_use(v: i32) -> bool { if !has_use_list(v) { return false; } let u = first_use(v); return u >= 0 && use_next(u) < 0; }
fn sc_convert_cr_to_icmp(cr: CRange, x: i32, i: i32) -> i32 {
    let ok, p, rhs = rg_equivalent_icmp(cr);
    if !ok { return -1; }
    let c = sc_insert_new(OP_ICMP, cmp_result_ty(vals[x].ty), [x, ap_to_cint(vals[x].ty, rhs)], i);
    insts[inst_of(c)].pred = p as u8;
    sc_copy_dbg_loc(c, i);
    sc_set_bit(c, SB_INSERTED);
    return c;
}

fn sc_simplify_insts_in_block(bb: i32) -> bool {
    var changed = false;
    var i = block_first(bb);
    while i >= 0 {
        let ni = inst_next(i);
        if ty_kind(vals[i].ty) == TK_VOID { i = ni; continue; }
        if sc_try_to_replace_with_constant(i) {
            if sc_would_be_trivially_dead(i) {
                if is_callbase(i) { sc_check_implicit_ref(i); }
                sc_erase(i);
            }
            changed = true;
        } else if sc_replace_signed_inst(i) {
            changed = true;
        } else if sc_refine_instruction(i) {
            changed = true;
        } else {
            let v = sc_simplify_instruction(i);
            if v >= 0 {
                sc_rauw(i, v);
                sc_erase(i);
                changed = true;
            }
        }
        i = ni;
    }
    return changed;
}
// propagateImplicitRefFromCall: the callee's !implicit.ref attachments are added to the caller
// (GlobalObject::addMetadata appends; attachments stay ordered by kind, stable)
fn sc_check_implicit_ref(cb: i32) {
    let f = called_function(cb);
    if f < 0 { return; }
    let k = md_kind_id("implicit.ref");
    let g = glob_of(f);
    var refs: i32[>..<] = [];
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == k { refs.push(md_att[globs[g].md + 2 * j + 1]); } }
    if refs.len == 0 { return; }
    let caller = inst_func(cb);
    let cg = glob_of(caller);
    for r in refs {
        let at = md_att.len as i32;
        let n = globs[cg].nmd;
        var placed = false;
        for j in n {
            let kk = md_att[globs[cg].md + 2 * j];
            if !placed && kk > k { md_att.push(k); md_att.push(r); placed = true; }
            let a = md_att[globs[cg].md + 2 * j];
            let b = md_att[globs[cg].md + 2 * j + 1];
            md_att.push(a); md_att.push(b);
        }
        if !placed { md_att.push(k); md_att.push(r); }
        globs[cg].md = at;
        globs[cg].nmd = n + 1;
    }
}

// Does a BlockAddress refer to this block?
fn sc_block_address_taken(bb: i32) -> bool {
    var u = first_use(bb);
    while u >= 0 { if vals[uses[u].user].kind == VK_BLOCKADDR { return true; } u = use_next(u); }
    return false;
}

// changeToUnreachable(I, PreserveLCSSA = false, &DTU)
fn sc_change_to_unreachable(iv: i32) -> i64 {
    let bb = inst_parent(iv);
    var uniq: i32[>..<] = [];
    let tm = block_terminator(bb);
    vs_clear(VS_PASS0);
    if tm >= 0 {
        for k in term_nsucc(tm) {
            let s = term_succ(tm, k);
            block_remove_predecessor(s, bb, false);
            if vs_add(VS_PASS0, s) { uniq.push(s); }
        }
    }
    let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
    inst_insert_before(ui, iv);
    sc_copy_dbg_loc(ui, iv);
    var n: i64 = 0;
    var i = iv;
    while i >= 0 {
        let nx = inst_next(i);
        if vals[i].first_use >= 0 { sc_rauw(i, c_poison(vals[i].ty)); }
        if nx < 0 {
            // the records would fall off the end of the block; BB->flushTerminatorDbgRecords() gives them
            // to the new terminator
            var r = inst_first_dbg(i);
            if r >= 0 {
                inst_dbg[inst_of(i)] = -1;
                while r >= 0 { let rn = dbgrecs[r].next; inst_add_dbg(ui, r); r = rn; }
            }
        }
        sc_erase(i);
        n += 1;
        i = nx;
    }
    var ups: DTUpdate[>..<] = [];
    for s in uniq { ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); }
    dtu_apply_updates(ups);
    return n;
}

// SwitchInst::removeCase(CaseIt) with SwitchInstProfUpdateWrapper's weight bookkeeping
fn sc_switch_remove_case(si: i32, idx: i64, weights: u32[>..<]&) {
    let n = nops(si);
    if weights.len > 0 {
        weights[idx + 1] = weights[weights.len - 1];
        weights.pop();
    }
    if 2 + 2 * idx + 2 != n {
        set_op(si, 2 + 2 * idx, op(si, n - 2));
        set_op(si, 3 + 2 * idx, op(si, n - 1));
    }
    set_op(si, n - 1, -1);
    set_op(si, n - 2, -1);
    vals[si].nops = vals[si].nops - 2;
}

// extractBranchWeights of a switch's !prof (returns false if none / not branch weights)
fn sc_switch_weights(si: i32, w: u32[>..<]&) -> bool {
    w.clear();
    let md = inst_get_md(si, 2);
    if md < 0 { return false; }
    let n = mds[md].nops as i64;
    if n < 1 { return false; }
    let tag = md_op(md, 0);
    if tag < 0 || mds[tag].kind != MK_STRING || sbytes(mds[tag].extra) != "branch_weights" { return false; }
    var k: i64 = 1;
    if n > 1 {
        let o1 = md_op(md, 1);
        if o1 >= 0 && mds[o1].kind == MK_STRING { k = 2; }
    }
    if n - k != term_nsucc(si) { fatal("number of prof branch_weights metadata operands does not correspond to number of succesors"); }
    while k < n {
        let c = mds[md_op(md, k)].extra;
        w.push(cint_lo(c) as! u32);
        k++;
    }
    return true;
}
fn sc_switch_set_weights(si: i32, w: u32[>..<]&) {
    let md = inst_get_md(si, 2);
    var ops: i32[>..<] = [];
    ops.push(md_op(md, 0));
    if mds[md].nops > 1 {
        let o1 = md_op(md, 1);
        if o1 >= 0 && mds[o1].kind == MK_STRING { ops.push(o1); }
    }
    for x in w { ops.push(md_value(c_int(T_I32, x as i64))); }
    inst_set_md(si, 2, md_get(MK_TUPLE, -1, ops, false));
}

fn sc_remove_non_feasible_edges(bb: i32, new_unreach: i32&) -> bool {
    let ti = block_terminator(bb);
    if ti < 0 { return false; }
    let ns = term_nsucc(ti);
    // FeasibleSuccessors (SmallPtrSet): list + VS_PASS0 membership
    var feas: i32[>..<] = [];
    var has_nonfeas = false;
    vs_clear(VS_PASS0);
    for k in ns {
        let s = term_succ(ti, k);
        if sc_edge_has(bb, s) { if vs_add(VS_PASS0, s) { feas.push(s); } }
        else { has_nonfeas = true; }
    }
    if !has_nonfeas { return false; }
    let o = iop(ti);
    if o != OP_BR && o != OP_CONDBR && o != OP_SWITCH && o != OP_INDIRECTBR { fatal("Terminator must be a br, switch or indirectbr"); }
    var ups: DTUpdate[>..<] = [];
    if feas.len == 0 {
        vs_clear(VS_PASS0);
        for k in ns {
            let s = term_succ(ti, k);
            block_remove_predecessor(s, bb, false);
            if vs_add(VS_PASS0, s) { ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s }); }
        }
        let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
        block_append_inst(bb, ui);
        sc_erase(ti);
        dtu_apply_updates_permissive(ups);
    } else if feas.len == 1 {
        let only = feas[0];
        var seen_only = false;
        for k in ns {
            let s = term_succ(ti, k);
            if s == only && !seen_only { seen_only = true; continue; }
            block_remove_predecessor(s, bb, false);
            ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
        }
        let br = create_inst(OP_BR, T_VOID, [only]);
        block_append_inst(bb, br);
        sc_copy_dbg_loc(br, ti);
        sc_erase(ti);
        dtu_apply_updates_permissive(ups);
    } else {
        if o != OP_SWITCH { fatal("internal: SCCP: more than one feasible successor of a non-switch"); }
        var w: u32[>..<] = [];
        let have_w = sc_switch_weights(ti, w);
        var changed_w = false;
        let dd = term_succ(ti, 0);
        if !vs_has(VS_PASS0, dd) {
            if new_unreach < 0 {
                let fv = block_func(dd);
                let nb = sc_create_block_before(fv, dd, "default.unreachable");
                let ui = create_inst(OP_UNREACHABLE, T_VOID, []);
                block_append_inst(nb, ui);
                new_unreach = nb;
            }
            block_remove_predecessor(dd, bb, false);
            term_set_succ(ti, 0, new_unreach);
            ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: dd });
            ups.push(DTUpdate { kind: DT_INSERT, from: bb, to: new_unreach });
        }
        var ci: i64 = 0;
        while ci < (nops(ti) - 2) / 2 {
            let s = op(ti, 3 + 2 * ci);
            if vs_has(VS_PASS0, s) { ci++; continue; }
            block_remove_predecessor(s, bb, false);
            ups.push(DTUpdate { kind: DT_DELETE, from: bb, to: s });
            sc_switch_remove_case(ti, ci, w);
            if have_w { changed_w = true; }
        }
        if changed_w && w.len >= 2 { sc_switch_set_weights(ti, w); }
        dtu_apply_updates_permissive(ups);
    }
    return true;
}

// BasicBlock::Create(Ctx, Name, Parent, InsertBefore)
fn sc_create_block_before(fv: i32, before: i32, name: const u8[:]) -> i32 {
    let p = block_prev(before);
    if p < 0 { sc_not_ported("inserting a block before the entry block"); }
    return create_block_after(fv, p, name);
}

fn sc_remove_ssa_copies(fv: i32) {
    if !sc_bit(fv, SB_HASPI) { return; }
    var b = func_first_block(fv);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            let ni = inst_next(i);
            if iop(i) == OP_BITCAST && vals[i].ty == vals[op(i, 0)].ty && pi_info_for(i) >= 0 {
                sc_rauw(i, op(i, 0));
                sc_erase(i);
            }
            i = ni;
        }
        b = block_next(b);
    }
}

// inferAttribute(F, AttrIndex, Val): idx 0 = return, 1 + k = parameter k
fn sc_infer_attribute(f: i32, idx: i64, l: VL) {
    let g = glob_of(f);
    let al = globs[g].attrs;
    let s = if idx == 0 { alist_ret(al) } else { alist_param(al, idx - 1) };
    if vl_is_range(l, true) && !rg_is_single(l.r) {
        if vl_is_range_including_undef(l) { return; }
        var cr = l.r;
        let ok, old = rg_from_range_attr(s);
        if ok { cr = rg_intersect(cr, old); }
        globs[g].attrs = sc_alist_set(al, idx, sc_aset_with(s, rg_attr(cr)));
        return;
    }
    if vl_is_not_constant(l) && ty_kind(vals[l.c].ty) == TK_PTR && is_null_value(l.c) && !aset_has(s, AK_NonNull) {
        globs[g].attrs = sc_alist_set(al, idx, sc_aset_with(s, attr_enum(AK_NonNull)));
    }
}
fn sc_aset_with(s: i32, a: i32) -> i32 {
    var xs: i32[>..<] = [];
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind != attrs[a].kind { xs.push(x); } }
    xs.push(a);
    return aset_get(xs);
}
fn sc_aset_without(s: i32, kind: i64) -> i32 {
    var xs: i32[>..<] = [];
    var changed = false;
    for k in aset_n(s) { let x = aset_attr(s, k); if attrs[x].kind as i64 != kind { xs.push(x); } else { changed = true; } }
    if !changed { return s; }
    return aset_get(xs);
}
// attribute list with slot idx (0 = ret, 1 + k = param k, -1 = fn) replaced by set s
fn sc_alist_set(l: i32, idx: i64, s: i32) -> i32 {
    var xs: i32[>..<] = [];
    let np = if alists[l].n > 2 { (alists[l].n - 2) as i64 } else { 0 };
    let want = if idx >= 1 { idx } else { 0 };
    let n = if np > want { np } else { want };
    xs.push(if idx == -1 { s } else { alist_fn(l) });
    xs.push(if idx == 0 { s } else { alist_ret(l) });
    for j in n { xs.push(if idx == j + 1 { s } else { alist_param(l, j) }); }
    return alist_get(xs);
}

fn sc_infer_return_attributes() {
    for k in sc_ret_fn.len { sc_infer_attribute(sc_ret_fn[k], 0, sc_vls[sc_ret_vl[k]]); }
}
fn sc_infer_arg_attributes() {
    for f in sc_argfns {
        if !sc_bit(func_entry(f), SB_EXEC) { continue; }
        for k in func_nargs(f) {
            let a = func_arg(f, k);
            if sc_is_struct(a) { continue; }
            sc_infer_attribute(f, 1 + k, sc_lattice(a));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// ValueLatticeUtils.cpp

fn sc_is_interposable(f: i32) -> bool {
    // isNoipaFnDef
    if vals[f].kind == VK_FUNC && !func_is_decl(f) && func_has_fn_attr(f, AK_NoIPA) { return true; }
    let lk = globs[glob_of(f)].linkage as i64;
    if lk == LK_WEAK_ANY || lk == LK_LINKONCE_ANY || lk == LK_COMMON || lk == LK_EXTERN_WEAK { return true; }
    if sc_semantic_interposition() && globs[glob_of(f)].dso_local == 0 { return true; }
    return false;
}
var sc_si_checked: i32 = -1;
var sc_si_value: bool = false;
fn sc_semantic_interposition() -> bool {
    // Module::getSemanticInterposition: the "SemanticInterposition" module flag
    if sc_si_checked == cur_module { return sc_si_value; }
    sc_si_checked = cur_module;
    sc_si_value = false;
    for m in mds {
        if m.kind == MK_STRING && sbytes(m.extra) == "SemanticInterposition" { sc_not_ported("the SemanticInterposition module flag"); }
    }
    return false;
}
fn sc_has_local_linkage(g: i32) -> bool { let lk = globs[glob_of(g)].linkage as i64; return lk == LK_INTERNAL || lk == LK_PRIVATE; }
fn sc_may_be_derefined(f: i32) -> bool {
    let lk = globs[glob_of(f)].linkage as i64;
    if lk == LK_WEAK_ODR || lk == LK_LINKONCE_ODR || lk == LK_AVAILABLE_EXTERNALLY { return true; }
    // isNobuiltinFnDef
    return sc_is_interposable(f) || (!func_is_decl(f) && func_has_fn_attr(f, AK_NoBuiltin));
}
fn sc_has_exact_definition(f: i32) -> bool { !func_is_decl(f) && !sc_may_be_derefined(f) }

// Function::hasAddressTaken() with the default arguments (IgnoreAssumeLikeCalls = true)
fn sc_is_assume_like(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe || id == IID_dbg_assign || id == IID_dbg_declare ||
           id == IID_dbg_value || id == IID_dbg_label || id == IID_invariant_start || id == IID_invariant_end ||
           id == IID_lifetime_start || id == IID_lifetime_end || id == IID_experimental_noalias_scope_decl ||
           id == IID_objectsize || id == IID_ptr_annotation || id == IID_var_annotation;
}
fn sc_has_address_taken(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 {
        let fu = uses[u].user;
        let nu = use_next(u);
        // a BlockAddress is not a user of its function in LLVM 23 (it only refers to the block)
        if vals[fu].kind == VK_BLOCKADDR { u = nu; continue; }
        if !(is_inst(fu) && is_callbase(fu)) {
            let k = opcode_of(fu);
            if is_constant(fu) && (k == OP_BITCAST || k == OP_ADDRSPACECAST) {
                var all = true;
                var u2 = first_use(fu);
                while u2 >= 0 { let x = uses[u2].user; if !(is_inst(x) && sc_is_assume_like(x)) { all = false; } u2 = use_next(u2); }
                if all { u = nu; continue; }
            }
            if is_inst(fu) && (k == OP_BITCAST || k == OP_ADDRSPACECAST) {
                var all = true;
                var u2 = first_use(fu);
                while u2 >= 0 { let x = uses[u2].user; if !(is_inst(x) && sc_is_assume_like(x)) { all = false; } u2 = use_next(u2); }
                if all { u = nu; continue; }
            }
            return true;
        }
        if sc_is_assume_like(fu) { u = nu; continue; }
        // isCallee(&U) and the call's function type
        let is_callee = (u - vals[fu].ops) as i64 == nops(fu) - 1;
        if !is_callee || insts[inst_of(fu)].ty2 != globs[glob_of(f)].vty { return true; }
        u = nu;
    }
    return false;
}
fn sc_can_track_arguments(f: i32) -> bool { sc_has_exact_definition(f) && sc_has_local_linkage(f) && !sc_has_address_taken(f) }
fn sc_can_track_returns(f: i32) -> bool { sc_has_exact_definition(f) && !func_has_fn_attr(f, AK_Naked) }
fn sc_can_track_global(gv: i32) -> bool {
    let g = glob_of(gv);
    if globs[g].is_const != 0 || !sc_has_local_linkage(gv) { return false; }
    // hasDefinitiveInitializer
    if nops(gv) == 0 || op(gv, 0) < 0 || sc_is_interposable(gv) || globs[g].ext_init != 0 { return false; }
    let gvt = globs[g].vty;
    var u = first_use(gv);
    while u >= 0 {
        let us = uses[u].user;
        if !is_inst(us) { return false; }
        let o = iop(us);
        if o == OP_STORE {
            if op(us, 0) == gv || inst_is_volatile(us) || vals[op(us, 0)].ty != gvt { return false; }
        } else if o == OP_LOAD {
            if inst_is_volatile(us) || vals[us].ty != gvt { return false; }
        } else { return false; }
        u = use_next(u);
    }
    return true;
}

// Constant::removeDeadConstantUsers (constantIsDead with RemoveDeadUsers = true)
fn sc_remove_dead_constant_users(c: i32) {
    var u = first_use(c);
    while u >= 0 {
        let us = uses[u].user;
        let nu = use_next(u);
        if is_constant(us) && !is_global(us) && sc_constant_is_dead(us) {
            // users changed: restart from the head (equivalent to LLVM's restart after LastNonDeadUser)
            u = first_use(c);
            continue;
        }
        u = nu;
    }
}
recursive fn sc_constant_is_dead(c: i32) -> bool {
    if is_global(c) { return false; }
    var u = first_use(c);
    while u >= 0 {
        let us = uses[u].user;
        if !is_constant(us) { return false; }
        if !sc_constant_is_dead(us) { return false; }
        u = first_use(c);
    }
    // destroyConstant: metadata uses are not ported (SalvageDebugInfo)
    for m in mds { if m.kind == MK_VALUE && m.extra == c { sc_not_ported("destroying a constant used by metadata"); } }
    drop_all_refs(c);
    vals[c].kind = VK_DEAD;
    return true;
}

// ---------------------------------------------------------------------------------------------
// sccp (Scalar/SCCP.cpp runSCCP)

fn sccp_run(fv: i32) -> u32 {
    sc_init(false);
    sc_fn = fv;
    tli_cur_fn = fv;
    dt_get(fv, DT_DOM);
    vt_invalidate_assumes();
    sc_set_bit(fv, SB_HASPI);
    pi_build(fv);
    if sc_can_track_returns(fv) { sc_add_tracked_function(fv); }
    sc_mark_block_executable(func_entry(fv));
    for k in func_nargs(fv) { sc_track_value_of_argument(func_arg(fv, k)); }
    var again = true;
    while again {
        sc_solve();
        again = sc_resolved_undefs_in(fv);
    }
    var changed = false;
    m2r_collect_records(fv);
    var dead: i32[>..<] = [];
    var b = func_first_block(fv);
    while b >= 0 {
        let nb = block_next(b);
        if !sc_bit(b, SB_EXEC) { dead.push(b); changed = true; b = nb; continue; }
        if sc_simplify_insts_in_block(b) { changed = true; }
        b = nb;
    }
    dtu_begin(fv, true, false, true);
    for d in dead { sc_change_to_unreachable(first_non_phi(d)); }
    var nu: i32 = -1;
    b = func_first_block(fv);
    while b >= 0 { if sc_remove_non_feasible_edges(b, nu) { changed = true; } b = block_next(b); }
    for d in dead { if !sc_block_address_taken(d) { dtu_delete_bb(d); } }
    dtu_end();
    sc_remove_ssa_copies(fv);
    sc_infer_return_attributes();
    vt_invalidate_assumes();
    if !changed { return PA_ALL; }
    return (1 as u32) << A_DOMTREE;
}

// ---------------------------------------------------------------------------------------------
// ipsccp (IPO/SCCP.cpp runIPSCCP)

fn sc_find_returns_to_zap(f: i32, out: i32[>..<]&) {
    if !sc_bit(f, SB_ARGTRACK) { return; }
    if sc_bit(f, SB_MUSTPRES) { return; }
    var b = func_first_block(f);
    while b >= 0 {
        if sc_terminating_musttail_call(b) >= 0 { return; }
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_RET && !is_undef_or_poison(op(t, 0)) { out.push(t); }
        b = block_next(b);
    }
}
// BasicBlock::getTerminatingMustTailCall
fn sc_terminating_musttail_call(b: i32) -> i32 {
    let ri = block_last(b);
    if ri < 0 || iop(ri) != OP_RET || ri == block_first(b) { return -1; }
    var prev = inst_prev(ri);
    if prev < 0 { return -1; }
    if nops(ri) > 0 {
        var rv = op(ri, 0);
        if rv != prev { return -1; }
        if iop(prev) == OP_BITCAST {
            rv = op(prev, 0);
            prev = inst_prev(prev);
            if prev < 0 || rv != prev { return -1; }
        }
    }
    if iop(prev) == OP_CALL && sc_is_musttail(prev) { return prev; }
    return -1;
}

// FunctionSpecializer::run with its default options (FunctionSpecialization.cpp is not ported). A function is
// specialized only if (1) isCandidateFunction holds, (2) its code size (CodeMetrics over TTI TCK_CodeSize
// costs) reaches funcspec-min-function-size = 500, and (3) findSpecializations finds an executable direct
// call site passing a candidate constant (getCandidateConstant) for an interesting argument
// (isArgumentInteresting), or promoteConstantStackValues applies (recursive functions). We fail loudly when
// (1) and (3) hold and a generous upper bound of the code size reaches 500.
fn sc_spec_size_bound(f: i32) -> i64 {
    var n: i64 = 0;
    each_inst(f) { i =>
        if is_callbase(i) { n += 4 + 2 * cb_nargs(i); }
        else if ty_is_vector(vals[i].ty) || (nops(i) > 0 && op(i, 0) >= 0 && ty_is_vector(vals[op(i, 0)].ty)) { n += 64; }
        else { n += 4; }
    };
    return n;
}
fn sc_arg_interesting(a: i32) -> bool {
    if first_use(a) < 0 { return false; }
    let t = vals[a].ty;
    let k = ty_kind(t);
    if k != TK_PTR && k != TK_INT && !ty_is_fp(t) && k != TK_STRUCT { return false; }
    let f = args_parent[vals[a].sub];
    if arg_has_attr(a, AK_ByVal) && !me_only_reads(aset_memory(alist_fn(globs[glob_of(f)].attrs))) { return false; }
    if !sc_bit(f, SB_ARGTRACK) { return true; }
    if sc_is_struct(a) {
        for e in ty_count(t) { if sc_is_overdefined_lv(sc_gsv(a, e)) { return true; } }
        return false;
    }
    return sc_is_overdefined_lv(sc_lattice(a));
}
fn sc_candidate_constant(v: i32) -> i32 {
    if vals[v].kind == VK_POISON { return -1; }
    var c = if is_constant(v) { v } else { sc_get_constant_or_null(v) };
    if c >= 0 && ty_kind(vals[c].ty) == TK_PTR && !is_null_value(c) {
        let u = get_underlying_object(c, 6);
        if is_gvar(u) && globs[glob_of(u)].is_const == 0 { return -1; }
    }
    return c;
}
fn sc_check_func_spec(m: i32) {
    var f = modules[m].first_func;
    while f >= 0 {
        let g = glob_of(f);
        if !func_is_decl(f) && globs[g].nargs > 0 && !sc_is_interposable(f) && !func_has_fn_attr(f, AK_NoDuplicate) &&
           !func_has_fn_attr(f, AK_OptimizeForSize) && !func_has_fn_attr(f, AK_MinSize) && sc_bit(func_entry(f), SB_EXEC) &&
           !func_has_fn_attr(f, AK_AlwaysInline) {
            var hit = false;
            var recursive_ptr = false;
            var u = first_use(f);
            while u >= 0 {
                let cs = uses[u].user;
                if is_inst(cs) && (iop(cs) == OP_CALL || iop(cs) == OP_INVOKE) && called_function(cs) == f && sc_bit(inst_parent(cs), SB_EXEC) {
                    for k in func_nargs(f) {
                        if sc_arg_interesting(func_arg(f, k)) && sc_candidate_constant(cb_arg(cs, k)) >= 0 { hit = true; }
                        if inst_func(cs) == f && ty_kind(vals[cb_arg(cs, k)].ty) == TK_PTR { recursive_ptr = true; }
                    }
                }
                u = use_next(u);
            }
            if (hit || recursive_ptr) && sc_spec_size_bound(f) >= 500 {
                sc_not_ported(str("function specialization (", val_name(f), " may be a specialization candidate)"));
            }
        }
        f = globs[g].next;
    }
}

fn sc_update_mem_attrs(al: i32) -> i32 {
    let s = alist_fn(al);
    let me = aset_memory(s);
    if me == ME_UNKNOWN { return al; }
    let argmr = me_get(me, 0);
    var nme = me_set(me, 2, me_get(me, 2) | argmr);
    nme = me_set(nme, 3, me_get(nme, 3) | argmr);
    return sc_alist_set(al, -1, sc_aset_with(s, attr_int(AK_Memory, nme)));
}

fn ipsccp_run(m: i32, func_spec: bool) -> bool {
    sc_init(true);
    vt_invalidate_assumes();
    var f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if func_is_decl(f) { f = nf; continue; }
        dt_get(f, DT_DOM);
        sc_set_bit(f, SB_HASPI);
        pi_build(f);
        if sc_can_track_returns(f) { sc_add_tracked_function(f); }
        if sc_can_track_arguments(f) { sc_add_arg_tracked(f); f = nf; continue; }
        sc_mark_block_executable(func_entry(f));
        for k in func_nargs(f) { sc_track_value_of_argument(func_arg(f, k)); }
        f = nf;
    }
    var gv = modules[m].first_gvar;
    while gv >= 0 {
        sc_remove_dead_constant_users(gv);
        if sc_can_track_global(gv) { sc_track_global(gv); }
        gv = globs[glob_of(gv)].next;
    }
    var again = true;
    while again {
        sc_solve();
        again = false;
        f = modules[m].first_func;
        while f >= 0 { if sc_resolved_undefs_in(f) { again = true; } f = globs[glob_of(f)].next; }
    }
    if func_spec { sc_check_func_spec(m); }
    var changed = false;
    f = modules[m].first_func;
    while f >= 0 {
        let nf = globs[glob_of(f)].next;
        if func_is_decl(f) { f = nf; continue; }
        tli_cur_fn = f;
        m2r_collect_records(f);
        var dead: i32[>..<] = [];
        let entry = func_entry(f);
        if sc_bit(entry, SB_EXEC) {
            var replaced_ptr = false;
            for k in func_nargs(f) {
                let a = func_arg(f, k);
                if first_use(a) >= 0 && sc_try_to_replace_with_constant(a) {
                    if ty_kind(vals[a].ty) == TK_PTR { replaced_ptr = true; }
                }
            }
            if replaced_ptr {
                let g = glob_of(f);
                globs[g].attrs = sc_update_mem_attrs(globs[g].attrs);
                var u = first_use(f);
                while u >= 0 {
                    let us = uses[u].user;
                    if is_inst(us) && is_callbase(us) && called_function(us) == f {
                        insts[inst_of(us)].attrs = sc_update_mem_attrs(insts[inst_of(us)].attrs);
                    }
                    u = use_next(u);
                }
                changed = true;
            }
        }
        var b = func_first_block(f);
        while b >= 0 {
            let nb = block_next(b);
            if !sc_bit(b, SB_EXEC) {
                changed = true;
                if b != entry { dead.push(b); }
                b = nb;
                continue;
            }
            if sc_simplify_insts_in_block(b) { changed = true; }
            b = nb;
        }
        dtu_begin(f, true, true, true);
        for d in dead { sc_change_to_unreachable(sc_first_non_phi_or_dbg(d)); }
        if !sc_bit(entry, SB_EXEC) { sc_change_to_unreachable(sc_first_non_phi_or_dbg(entry)); }
        var nu: i32 = -1;
        b = func_first_block(f);
        while b >= 0 { if sc_remove_non_feasible_edges(b, nu) { changed = true; } b = block_next(b); }
        for d in dead { if !sc_block_address_taken(d) { dtu_delete_bb(d); } }
        dtu_end();
        sc_remove_ssa_copies(f);
        f = nf;
    }
    var zap: i32[>..<] = [];
    sc_infer_return_attributes();
    sc_infer_arg_attributes();
    for k in sc_ret_fn.len {
        let rv = sc_vls[sc_ret_vl[k]];
        if sc_is_constant_lv(rv) || vl_is_unknown_or_undef(rv) { sc_find_returns_to_zap(sc_ret_fn[k], zap); }
    }
    for mf in sc_mrv_fn {
        let base = sc_recs[mf].mrv;
        var all = true;
        for k in ty_count(ty_fn_ret(globs[glob_of(mf)].vty)) { if !sc_is_constant_lv(sc_vls[base + (k as i32)]) { all = false; } }
        if all { sc_find_returns_to_zap(mf, zap); }
    }
    var zapped: i32[>..<] = [];
    vs_clear(VS_PASS0);
    for ri in zap {
        let zf = inst_func(ri);
        set_op(ri, 0, c_poison(ty_fn_ret(globs[glob_of(zf)].vty)));
        if vs_add(VS_PASS0, zf) { zapped.push(zf); }
    }
    for zf in zapped {
        let g = glob_of(zf);
        var al = globs[g].attrs;
        for k in func_nargs(zf) { al = sc_alist_set(al, 1 + k, sc_aset_without(alist_param(al, k), AK_Returned)); }
        al = sc_alist_set(al, 0, sc_drop_ub_attrs(alist_ret(al)));
        globs[g].attrs = al;
        var u = first_use(zf);
        while u >= 0 {
            let us = uses[u].user;
            if is_inst(us) && is_callbase(us) {
                var cl = insts[inst_of(us)].attrs;
                for k in cb_nargs(us) { cl = sc_alist_set(cl, 1 + k, sc_aset_without(alist_param(cl, k), AK_Returned)); }
                cl = sc_alist_set(cl, 0, sc_drop_ub_attrs(alist_ret(cl)));
                insts[inst_of(us)].attrs = cl;
            }
            u = use_next(u);
        }
    }
    for gvv in sc_glob_gv {
        if sc_recs[gvv].glob < 0 { continue; }
        if sc_is_overdefined_lv(sc_vls[sc_recs[gvv].glob]) { continue; }
        var u = first_use(gvv);
        while u >= 0 {
            let us = uses[u].user;
            if !is_inst(us) || (iop(us) != OP_STORE && iop(us) != OP_LOAD) { fatal("internal: IPSCCP: only Store|Load Instruction can be user of GlobalVariable"); }
            if iop(us) == OP_LOAD { sc_rauw(us, c_poison(vals[us].ty)); }
            m2r_collect_records(inst_func(us));
            sc_erase(us);
            u = first_use(gvv);
        }
        sc_update_gv_debug_expr(gvv);
        changed = true;
        sc_erase_global(gvv);
    }
    vt_invalidate_assumes();
    return changed;
}
fn sc_drop_ub_attrs(s: i32) -> i32 {
    var r = sc_aset_without(s, AK_NoUndef);
    r = sc_aset_without(r, AK_Dereferenceable);
    r = sc_aset_without(r, AK_DereferenceableOrNull);
    return r;
}
fn sc_first_non_phi_or_dbg(b: i32) -> i32 {
    // BasicBlock::getFirstNonPHIOrDbg: debug records are not instructions here
    return first_non_phi(b);
}
// Module::eraseGlobalVariable
fn sc_erase_global(gv: i32) {
    if first_use(gv) >= 0 { fatal("internal: erasing a global that still has uses"); }
    module_remove_global(gv);
    drop_all_refs(gv);
    vals[gv].kind = VK_DEAD;
}

// GV->getDebugInfo(GVEs); if exactly one, replace its expression with getExpressionForConstant(init)
// (MDNode::replaceOperandWith: the uniqued node is changed in place)
fn sc_update_gv_debug_expr(gv: i32) {
    let g = glob_of(gv);
    var gve: i32 = -1;
    var n = 0;
    for j in globs[g].nmd { if md_att[globs[g].md + 2 * j] == 0 { gve = md_att[globs[g].md + 2 * j + 1]; n++; } }
    if n != 1 { return; }
    let e = sc_expression_for_constant(op(gv, 0), globs[g].vty);
    if e < 0 { return; }
    let k = di_field_index(di_kind(gve), "expr");
    md_ops[mds[gve].ops + k] = e;
}
fn sc_const_value_expr(v: u64) -> i32 {
    return md_get(MK_DIEXPR, -1, [md_int(16), md_int(v as! i64), md_int(159)], false);
}
// getExpressionForConstant(DIB, C, Ty)
fn sc_expression_for_constant(c: i32, ty: i32) -> i32 {
    if vals[c].kind == VK_CINT { return sc_int_expr(c); }
    if vals[c].kind == VK_CFP && !ty_is_vector(vals[c].ty) && ty_is_fp(ty) && ty_bits_fp(ty) <= 64 {
        return sc_const_value_expr(cint_lo(c));
    }
    if ty_kind(ty) != TK_PTR { return -1; }
    if vals[c].kind == VK_CNULL { return sc_const_value_expr(0); }
    if vals[c].kind == VK_CEXPR && cexpr_op(c) == OP_INTTOPTR {
        let v = op(c, 0);
        if vals[v].kind == VK_CINT { return sc_int_expr(v); }
    }
    return -1;
}
fn sc_int_expr(c: i32) -> i32 {
    let a = ap_from_cint(c);
    if a.w == 1 { return sc_const_value_expr(ap_lo64(a)); }
    if ap_sig_bits(a) > 64 { return -1; }
    return sc_const_value_expr(ap_sext64(a) as! u64);
}
fn ty_bits_fp(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    return 128;
}
