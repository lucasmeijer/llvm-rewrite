// LoopAccessAnalysis: port of llvm/lib/Analysis/LoopAccessAnalysis.cpp (whole: LoopAccessInfo, MemoryDepChecker,
// AccessAnalysis, RuntimePointerChecking, getPtrStride, getPointersDiff, isConsecutiveAccess, the printer) and
// llvm/lib/Transforms/Scalar/LoopAccessAnalysisPrinter.cpp (print<access-info>); also getIntrinsicForCallSite /
// getUnderlyingObjects with LoopInfo (llvm/lib/Analysis/ValueTracking.cpp), getVectorIntrinsicIDForCall
// (llvm/lib/Analysis/VectorUtils.cpp).
//
// One LoopAccessInfo at a time (the lai_* / mdc_* / rpc_* / acc_* globals); the LoopAccessInfoManager is not
// cached across passes (each user builds a fresh one per loop). VFDatabase mappings (calls with
// "vector-function-abi-variant") fail loudly.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import flags;
import gen_iids;
import gen_attrs;
import gen_tli;
import datalayout;
import pm;
import vt;
import poison;
import apint;
import cfold;
import constfold;
import domtree;
import loopinfo;
import memloc;
import aa;
import ast;
import tli;
import speculate;
import tti;
import tti_x86;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_range;
import scev_pred;
import scev_guards;
import scev_lt;
import scev_expander;
import pse;
import loop_utils;
import printer;

fn laa_not_ported(what: const u8[:]) { fatal(str("LoopAccessAnalysis: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Small helpers

// getLoadStorePointerOperand / getLoadStoreType
fn laa_ldst_ptr(i: i32) -> i32 {
    if !is_inst(i) { return -1; }
    if iop(i) == OP_LOAD { return op(i, 0); }
    if iop(i) == OP_STORE { return op(i, 1); }
    return -1;
}
fn laa_ldst_type(i: i32) -> i32 { if iop(i) == OP_LOAD { vals[i].ty } else { vals[op(i, 0)].ty } }
fn laa_sext_from(x: i64, w: i64) -> i64 {
    if w >= 64 { return x; }
    let sh = (64 - w) as u64;
    return (x << sh) >> sh;
}
fn laa_ptr_as(v: i32) -> i64 { ty_bits(vals[v].ty) }
fn laa_indent(d: i64) { for k in d { errs(" "); } }
fn laa_u64(x: u64) { var b: u8[>..] = []; laa_fmt_u64(b, x); errs(b); }
recursive fn laa_fmt_u64(b: u8[>..]&, x: u64) {
    if x >= 10 { laa_fmt_u64(b, x / 10); }
    b.push(('0' as u64 + x % 10) as u8);
}

// getPointersDiff(ElemTyA, PtrA, ElemTyB, PtrB, DL, SE, StrictCheck, CheckType): ok, distance
fn laa_get_pointers_diff(eta: i32, pa: i32, etb: i32, pb: i32, strict: bool, check_type: bool) -> bool, i64 {
    if pa == pb { return true, 0; }
    if check_type && eta != etb { return false, 0; }
    var asa = ty_bits(vals[pa].ty);
    var asb = ty_bits(vals[pb].ty);
    if asa != asb { return false, 0; }
    var iw = dl_ptr(asa).idx;
    if iw > 64 { laa_not_ported("getPointersDiff with index widths over 64 bits"); }
    let pa1 = strip_and_accumulate_offsets(pa, true, false, false);
    let offa = vt_off;
    let pb1 = strip_and_accumulate_offsets(pb, true, false, false);
    let offb = vt_off;
    var val: i64 = 0;
    if pa1 == pb1 {
        asa = ty_bits(vals[pa1].ty);
        asb = ty_bits(vals[pb1].ty);
        if asa != asb { return false, 0; }
        iw = dl_ptr(asa).idx;
        val = laa_sext_from(laa_sext_from(offb, iw) - laa_sext_from(offa, iw), iw);
    } else {
        let sa = sc_get_scev(pa);
        let sb = sc_get_scev(pb);
        let ok, d = sc_compute_constant_difference(sb, sa);
        if !ok { return false, 0; }
        if ap_sig_bits(d) > 64 { return false, 0; }
        val = ap_sext64(d);
    }
    let size = dl_store_size(eta);
    let dist = val / size;
    if !strict || dist * size == val { return true, dist; }
    return false, 0;
}

// isConsecutiveAccess(A, B, DL, SE, CheckType)
fn laa_is_consecutive_access(a: i32, b: i32, check_type: bool) -> bool {
    let pa = laa_ldst_ptr(a);
    let pb = laa_ldst_ptr(b);
    if pa < 0 || pb < 0 { return false; }
    let ok, d = laa_get_pointers_diff(laa_ldst_type(a), pa, laa_ldst_type(b), pb, true, check_type);
    return ok && d == 1;
}

// getIntrinsicForCallSite(CB, TLI)
fn laa_intrinsic_for_call_site(c: i32) -> i32 {
    let f = called_function(c);
    if f < 0 { return 0; }
    let id = func_iid(f) as i32;
    if id != 0 { return id; }
    let lk = globs[glob_of(f)].linkage as i64;
    if lk == LK_INTERNAL || lk == LK_PRIVATE { return 0; }
    let lf = ml_call_libfunc(c);
    if lf < 0 || !call_only_reads_memory(c) { return 0; }
    let lf64 = lf as i64;
    if lf64 == LF_sin || lf64 == LF_sinf || lf64 == LF_sinl { return IID_sin as i32; }
    if lf64 == LF_cos || lf64 == LF_cosf || lf64 == LF_cosl { return IID_cos as i32; }
    if lf64 == LF_tan || lf64 == LF_tanf || lf64 == LF_tanl { return IID_tan as i32; }
    if lf64 == LF_asin || lf64 == LF_asinf || lf64 == LF_asinl { return IID_asin as i32; }
    if lf64 == LF_acos || lf64 == LF_acosf || lf64 == LF_acosl { return IID_acos as i32; }
    if lf64 == LF_atan || lf64 == LF_atanf || lf64 == LF_atanl { return IID_atan as i32; }
    if lf64 == LF_atan2 || lf64 == LF_atan2f || lf64 == LF_atan2l { return IID_atan2 as i32; }
    if lf64 == LF_sinh || lf64 == LF_sinhf || lf64 == LF_sinhl { return IID_sinh as i32; }
    if lf64 == LF_cosh || lf64 == LF_coshf || lf64 == LF_coshl { return IID_cosh as i32; }
    if lf64 == LF_tanh || lf64 == LF_tanhf || lf64 == LF_tanhl { return IID_tanh as i32; }
    if lf64 == LF_exp || lf64 == LF_expf || lf64 == LF_expl { return IID_exp as i32; }
    if lf64 == LF_exp2 || lf64 == LF_exp2f || lf64 == LF_exp2l { return IID_exp2 as i32; }
    if lf64 == LF_exp10 || lf64 == LF_exp10f || lf64 == LF_exp10l { return IID_exp10 as i32; }
    if lf64 == LF_log || lf64 == LF_logf || lf64 == LF_logl { return IID_log as i32; }
    if lf64 == LF_log10 || lf64 == LF_log10f || lf64 == LF_log10l { return IID_log10 as i32; }
    if lf64 == LF_log2 || lf64 == LF_log2f || lf64 == LF_log2l { return IID_log2 as i32; }
    if lf64 == LF_fabs || lf64 == LF_fabsf || lf64 == LF_fabsl { return IID_fabs as i32; }
    if lf64 == LF_fmin || lf64 == LF_fminf || lf64 == LF_fminl { return IID_minnum as i32; }
    if lf64 == LF_fmax || lf64 == LF_fmaxf || lf64 == LF_fmaxl { return IID_maxnum as i32; }
    if lf64 == LF_copysign || lf64 == LF_copysignf || lf64 == LF_copysignl { return IID_copysign as i32; }
    if lf64 == LF_floor || lf64 == LF_floorf || lf64 == LF_floorl { return IID_floor as i32; }
    if lf64 == LF_ceil || lf64 == LF_ceilf || lf64 == LF_ceill { return IID_ceil as i32; }
    if lf64 == LF_trunc || lf64 == LF_truncf || lf64 == LF_truncl { return IID_trunc as i32; }
    if lf64 == LF_rint || lf64 == LF_rintf || lf64 == LF_rintl { return IID_rint as i32; }
    if lf64 == LF_nearbyint || lf64 == LF_nearbyintf || lf64 == LF_nearbyintl { return IID_nearbyint as i32; }
    if lf64 == LF_round || lf64 == LF_roundf || lf64 == LF_roundl { return IID_round as i32; }
    if lf64 == LF_roundeven || lf64 == LF_roundevenf || lf64 == LF_roundevenl { return IID_roundeven as i32; }
    if lf64 == LF_pow || lf64 == LF_powf || lf64 == LF_powl { return IID_pow as i32; }
    if lf64 == LF_sqrt || lf64 == LF_sqrtf || lf64 == LF_sqrtl { return IID_sqrt as i32; }
    return 0;
}
// getVectorIntrinsicIDForCall(CI, TLI)
fn laa_vector_intrinsic_id_for_call(c: i32) -> i32 {
    let id = laa_intrinsic_for_call_site(c);
    if id == 0 { return 0; }
    let i64id = id as i64;
    if is_trivially_vectorizable(id) || i64id == IID_lifetime_start || i64id == IID_lifetime_end || i64id == IID_assume ||
       i64id == IID_experimental_noalias_scope_decl || i64id == IID_sideeffect || i64id == IID_pseudoprobe { return id; }
    return 0;
}

// isSameUnderlyingObjectInLoop(PN, LI)
fn laa_same_underlying_object_in_loop(pn: i32) -> bool {
    let l = li_loop_for(inst_parent(pn));
    if nops(pn) != 2 { return true; }
    var prev = op(pn, 0);
    if !is_inst(prev) || li_loop_for(inst_parent(prev)) != l { prev = op(pn, 1); }
    if !is_inst(prev) || li_loop_for(inst_parent(prev)) != l { return true; }
    if iop(prev) == OP_LOAD {
        let p = op(prev, 0);
        if is_inst(p) && loop_contains(l, inst_parent(p)) { return false; }
    }
    return true;
}
// getUnderlyingObjects(V, Objects, LI)
fn laa_underlying_objects(v: i32, out: i32[>..<]&) {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(v);
    loop {
        let p0 = wl.pop();
        let p = get_underlying_object(p0, 10);
        var dup = false;
        for s in seen { if s == p { dup = true; break; } }
        if !dup {
            seen.push(p);
            if is_inst_op(p, OP_SELECT) { wl.push(op(p, 1)); wl.push(op(p, 2)); }
            else if is_inst_op(p, OP_PHI) {
                if !li_is_loop_header(inst_parent(p)) || laa_same_underlying_object_in_loop(p) {
                    for k in nops(p) { wl.push(op(p, k)); }
                } else { out.push(p); }
            } else { out.push(p); }
        }
        if wl.len == 0 { break; }
    }
}

// ---------------------------------------------------------------------------------------------
// MemAccessInfo (Ptr, IsWrite) = ptr * 2 + write; EquivalenceClasses<MemAccessInfo>

fn mai(p: i32, w: bool) -> i64 { (p as i64) * 2 + (if w { 1 } else { 0 }) }
fn mai_ptr(m: i64) -> i32 { (m / 2) as i32 }
fn mai_write(m: i64) -> bool { (m % 2) == 1 }

// a node per element: next in its class's list; a leader keeps its class's tail
struct EqNode { m: i64, next: i32, leader: i32, tail: i32, alive: bool }
var eq_nodes: EqNode[>..<];
var eq_map = hm_new();
fn eq_clear() { eq_nodes.clear(); hm_clear(eq_map); }
fn eq_node(m: i64) -> i32 { hm_get(eq_map, m as u64, -1) as i32 }
fn eq_contains(m: i64) -> bool { eq_node(m) >= 0 }
fn eq_insert(m: i64) -> i32 {
    let n = eq_node(m);
    if n >= 0 { return n; }
    let k = eq_nodes.len as i32;
    eq_nodes.push(EqNode { m: m, next: -1, leader: k, tail: k, alive: true });
    hm_put(eq_map, m as u64, k as i64);
    return k;
}
fn eq_leader_node(m: i64) -> i32 { let n = eq_node(m); if n < 0 { -1 } else { eq_nodes[n].leader } }
fn eq_union(a: i64, b: i64) {
    let na = eq_insert(a);
    let nb = eq_insert(b);
    let l1 = eq_nodes[na].leader;
    let l2 = eq_nodes[nb].leader;
    if l1 == l2 { return; }
    eq_nodes[eq_nodes[l1].tail].next = l2;
    eq_nodes[l1].tail = eq_nodes[l2].tail;
    var x = l2;
    while x >= 0 { eq_nodes[x].leader = l1; x = eq_nodes[x].next; }
}
// the members of m's class, leader first
fn eq_members(m: i64, out: i64[>..<]&) {
    out.clear();
    let l = eq_leader_node(m);
    var x = l;
    while x >= 0 { out.push(eq_nodes[x].m); x = eq_nodes[x].next; }
}
// eraseClass(V)
fn eq_erase_class(m: i64) {
    let l = eq_leader_node(m);
    if l < 0 { return; }
    var x = l;
    while x >= 0 { hm_del(eq_map, eq_nodes[x].m as u64); eq_nodes[x].alive = false; x = eq_nodes[x].next; }
}

// ---------------------------------------------------------------------------------------------
// The LoopAccessInfo state

let DT_NODEP = 0;
let DT_UNKNOWN = 1;
let DT_INDIRECT_UNSAFE = 2;
let DT_INVARIANT_UNSAFE = 3;
let DT_FORWARD = 4;
let DT_FORWARD_PREVENTS = 5;
let DT_BACKWARD = 6;
let DT_BACKWARD_VEC = 7;
let DT_BACKWARD_VEC_PREVENTS = 8;
let VS_SAFE = 0;
let VS_RT = 1;
let VS_UNSAFE = 2;

var lai_l: i32 = -1;
var lai_fv: i32 = -1;
var lai_pse: i32 = -1;
var lai_allow_partial: bool = false;
var lai_can_vec_mem: bool = false;
var lai_has_convergent: bool = false;
var lai_has_report: bool = false;
var lai_report: u8[>..];
var lai_has_complete_rt: bool = false;
var lai_st_st_inv: bool = false;
var lai_ld_st_inv: bool = false;
var lai_num_loads: i64 = 0;
var lai_num_stores: i64 = 0;
var lai_stores_to_inv: i32[>..<];
var lai_strides_k: i32[>..<];     // SymbolicStrides (Value -> SCEVUnknown), insertion order
var lai_strides_v: i32[>..<];
var lai_guards: i32 = -1;          // std::optional<LoopGuards>

// MemoryDepChecker
struct Dep { src: i32, dst: i32, ty: i32 }
var mdc_keys: i64[>..<];           // Accesses: MemAccessInfo -> run of access indices (MapVector order)
var mdc_idx: i32[>..<];            // per access index: the key it belongs to (k index)
var mdc_inst: i32[>..<];           // InstMap
var mdc_deps: Dep[>..<];
var mdc_record: bool = true;
var mdc_status: i64 = 0;
var mdc_min_dep_dist: u64 = 0;
var mdc_max_safe_width: u64 = 0xFFFFFFFF;
var mdc_max_sl_fwd: u64 = 0xFFFFFFFFFFFFFFFF;
var mdc_retry: bool = false;
var mdc_max_target_width: u64 = 0xFFFFFFFF;
var mdc_pb_key1: i32[>..<];        // PointerBounds cache: (PtrExpr, EltSize) -> (Start, End)
var mdc_pb_key2: i32[>..<];
var mdc_pb_s: i32[>..<];
var mdc_pb_e: i32[>..<];
var mdc_pb_map = hm_new();

// RuntimePointerChecking
struct PtrInfo { ptr: i32, start: i32, end: i32, write: bool, dep: i32, asid: i32, expr: i32, freeze: bool }
struct Grp { high: i32, low: i32, at: i32, n: i32, as_: i64, freeze: bool }
var rpc_ptrs: PtrInfo[>..<];
var rpc_groups: Grp[>..<];
var rpc_gmem: i32[>..<];           // group members (runs; a group's run is copied to the end when it grows)
var rpc_checks: i64[>..<];         // pairs of group indices: g1 * 2^32 + g2
var rpc_diff: i32[>..<];           // DiffChecks: (SrcStart, SinkStart, AccessSize, NeedsFreeze) x 4
var rpc_can_diff: bool = true;
var rpc_need: bool = false;

// AccessAnalysis
var acc_keys: i64[>..<];           // Accesses: MapVector<MemAccessInfo, SmallSetVector<Type*>>
var acc_tat: i32[>..<];            // the type run of each key (in acc_tys, linked)
var acc_tys: i32[>..<];
var acc_tnext: i32[>..<];
var acc_tlast: i32[>..<];
var acc_check_deps: i64[>..<];
var acc_readonly: i32[>..<];
var acc_rt_needed: bool = false;
var acc_q: i32 = -1;
var acc_scopes: i32[>..<];         // LoopAliasScopes

fn acc_key_index(m: i64) -> i64 { for k in acc_keys.len { if acc_keys[k] == m { return k; } } return -1; }
fn acc_add_type(m: i64, t: i32) {
    var k = acc_key_index(m);
    if k < 0 {
        acc_keys.push(m);
        acc_tat.push(-1);
        acc_tlast.push(-1);
        k = acc_keys.len - 1;
    }
    var x = acc_tat[k];
    while x >= 0 { if acc_tys[x] == t { return; } x = acc_tnext[x]; }
    acc_tys.push(t);
    acc_tnext.push(-1);
    let n = (acc_tys.len - 1) as i32;
    if acc_tlast[k] < 0 { acc_tat[k] = n; } else { acc_tnext[acc_tlast[k]] = n; }
    acc_tlast[k] = n;
}
fn acc_contains(m: i64) -> bool { acc_key_index(m) >= 0 }

// adjustAliasScopeList
fn acc_adjust_scope_list(sl: i32) -> i32 {
    if sl < 0 { return -1; }
    for k in mds[sl].nops as i64 {
        let s = md_op(sl, k);
        for x in acc_scopes { if x == s { return -1; } }
    }
    return sl;
}
// adjustLoc
fn acc_adjust_loc(l0: ML) -> ML {
    var l = l0;
    l.size = LS_BEFORE_OR_AFTER;
    l.scope = acc_adjust_scope_list(l.scope);
    l.noalias = acc_adjust_scope_list(l.noalias);
    return l;
}
fn acc_add_load(loc: ML, t: i32, ro: bool) {
    ast_add_memory_location(acc_adjust_loc(loc), AS_NO_ACCESS);
    acc_add_type(mai(loc.ptr, false), t);
    if ro { var seen = false; for x in acc_readonly { if x == loc.ptr { seen = true; } } if !seen { acc_readonly.push(loc.ptr); } }
}
fn acc_add_store(loc: ML, t: i32) {
    ast_add_memory_location(acc_adjust_loc(loc), AS_NO_ACCESS);
    acc_add_type(mai(loc.ptr, true), t);
}
fn acc_is_readonly(p: i32) -> bool { for x in acc_readonly { if x == p { return true; } } return false; }

// AliasSet::getPointers: the unique pointers of the set's MemoryLocs
fn acc_as_pointers(s: i32, out: i32[>..<]&) {
    out.clear();
    for k in ast_nml(s) {
        let p = ast_ml(s, k).ptr;
        var seen = false;
        for x in out { if x == p { seen = true; break; } }
        if !seen { out.push(p); }
    }
}

// ---------------------------------------------------------------------------------------------
// getStrideFromAddRec, isNoWrap, getPtrStride

fn laa_scalable(t: i32) -> bool { ty_kind(t) == TK_SVEC }

// getStrideFromAddRec(AR, Lp, AccessTy, Ptr, PSE): ok, stride
fn laa_stride_from_addrec(ar: i32, l: i32, at: i32) -> bool, i64 {
    if laa_scalable(at) { return false, 0; }
    if l != sc_loop(ar) { return false, 0; }
    let step = sc_get_step_recurrence(ar);
    if !sc_is_const(step) { return false, 0; }
    let size = dl_alloc_size(at);
    let sa = sc_ap(step);
    if ap_sig_bits(sa) > 64 { return false, 0; }
    let sv = ap_sext64(sa);
    if sv % size != 0 { return false, 0; }
    return true, sv / size;
}

// LoopAccessInfo::blockNeedsPredication
fn laa_block_needs_predication(bb: i32, l: i32) -> bool { !dt_dominates_block(DT_DOM, bb, loop_latch(l)) }

// isNoWrap(PSE, AR, Ptr, AccessTy, L, DT, Stride, Predicates)
fn laa_is_no_wrap(ar: i32, ptr: i32, at: i32, l: i32, has_stride: bool, stride0: i64, preds: bool, out: i32[>..<]&) -> bool {
    if (sc_flags(ar) & SF_MASK) != 0 { return true; }
    if ptr >= 0 && pse_has_no_overflow(lai_pse, ptr, IW_NUSW) { return true; }
    if ptr >= 0 && is_inst_op(ptr, OP_GEP) && (op_flags(ptr) & GEP_NUSW) != 0 {
        if loop_header(l) == loop_latch(l) { return true; }
        var u = vals[ptr].first_use;
        while u >= 0 {
            let us = uses[u].user;
            if laa_ldst_ptr(us) == ptr {
                let ubb = inst_parent(us);
                if loop_contains(l, ubb) && !laa_block_needs_predication(ubb, l) { return true; }
            }
            u = uses[u].next;
        }
    }
    var hs = has_stride;
    var stride = stride0;
    if !hs { let ok, s = laa_stride_from_addrec(ar, l, at); hs = ok; stride = s; }
    if hs {
        let as_ = ty_bits(sc_ty(ar));
        if !null_pointer_is_defined(block_func(loop_header(l)), as_) && (stride == 1 || stride == -1) { return true; }
    }
    if ptr >= 0 && preds {
        let f = IW_NUSW & ~sc_wrap_implied_flags(ar);
        out.push(sc_get_wrap_predicate(ar, f));
        return true;
    }
    return false;
}

// replaceSymbolicStrideSCEV(PSE, PtrToStride, Ptr)
fn laa_replace_symbolic_stride_scev(ptr: i32) -> i32 {
    let orig = pse_get_scev(lai_pse, ptr);
    var st: i32 = -1;
    for k in lai_strides_k.len { if lai_strides_k[k] == ptr { st = lai_strides_v[k]; } }
    if st < 0 { return orig; }
    let ct = sc_get_one(sc_ty(st));
    pse_add_predicate(lai_pse, sc_get_compare_predicate(P_EQ, st, ct));
    return pse_get_scev(lai_pse, ptr);
}

// getPtrStride(PSE, AccessTy, Ptr, Lp, DT, StridesMap, ShouldCheckWrap, Predicates): ok, stride
fn laa_get_ptr_stride(at: i32, ptr: i32, l: i32, check_wrap: bool, preds: bool, out: i32[>..<]&) -> bool, i64 {
    let ps = laa_replace_symbolic_stride_scev(ptr);
    if sc_is_loop_invariant(ps, l) { return true, 0; }
    var ar = if sc_is_addrec(ps) { ps } else { -1 };
    if preds && ar < 0 {
        let m = sc_lin_preds.len;
        ar = sc_convert_to_addrec_with_predicates(ps, l);
        for k in m..sc_lin_preds.len { out.push(sc_lin_preds[k]); }
        sc_lin_preds.resize(m);
    }
    if ar < 0 { return false, 0; }
    let ok, stride = laa_stride_from_addrec(ar, l, at);
    if !check_wrap || !ok { return ok, stride; }
    if laa_is_no_wrap(ar, ptr, at, l, true, stride, preds, out) { return true, stride; }
    return false, 0;
}
// getPtrStride(..., Assume, ShouldCheckWrap)
fn laa_get_ptr_stride_assume(at: i32, ptr: i32, l: i32, assume: bool, check_wrap: bool) -> bool, i64 {
    var ps: i32[>..<] = [];
    let ok, s = laa_get_ptr_stride(at, ptr, l, check_wrap, assume, ps);
    pse_add_predicates(lai_pse, ps);
    return ok, s;
}

// ---------------------------------------------------------------------------------------------
// getStartAndEndForAccess

fn laa_add_no_overflow(a: i32, b: i32) -> i32 { if !sc_will_not_overflow(OP_ADD, false, a, b, -1) { -1 } else { sc_add(a, b) } }
fn laa_mul_no_overflow(a: i32, b: i32) -> i32 { if !sc_will_not_overflow(OP_MUL, false, a, b, -1) { -1 } else { sc_mul(a, b) } }

fn laa_guards() -> i32 {
    if lai_guards < 0 { lai_guards = sc_loop_guards_collect(lai_l); }
    return lai_guards;
}

// evaluatePtrAddRecAtMaxBTCWillNotWrap
fn laa_eval_at_max_btc_will_not_wrap(ar: i32, max_btc0: i32, elt: i32) -> bool {
    let pb = sc_get_pointer_base(sc_op(ar, 0));
    if sc_kind(pb) != SC_UNKNOWN { return false; }
    let l = sc_loop(ar);
    let spv = sc_value(pb);
    let db, cnn = ptr_deref_bytes(spv);
    if db != 0 && cnn { return false; }
    var step = sc_get_step_recurrence(ar);
    let wt = sc_get_wider_type(sc_ty(max_btc0), sc_ty(step));
    var dbs = sc_get_constant_ty(wt, db, false);
    // getKnowledgeForValue(StartPtrV, Dereferenceable, AC, ...) valid at the loop predecessor's branch
    var cx = first_non_phi(loop_header(l));
    let lp = loop_predecessor(l);
    if lp >= 0 {
        let t = block_terminator(lp);
        if iop(t) == OP_BR || iop(t) == OP_CONDBR { cx = t; }
    }
    var bb = func_entry(lai_fv);
    while bb >= 0 {
        var i = block_first(bb);
        while i >= 0 {
            if inst_iid(i) == IID_assume {
                for k in cb_nbundles(i) {
                    if sbytes(cb_bundle_tag(i, k)) != "dereferenceable" { continue; }
                    let b = cb_bundle_begin(i, k);
                    if cb_bundle_count(i, k) < 2 || op(i, b) != spv { continue; }
                    if !is_valid_assume_for_context(i, cx) { continue; }
                    var rk = sc_get_scev(op(i, b + 1));
                    let ct = sc_get_wider_type(sc_ty(dbs), sc_ty(rk));
                    dbs = sc_get_noop_or_zero_extend(dbs, ct);
                    rk = sc_get_noop_or_zero_extend(rk, ct);
                    dbs = sc_umax(dbs, rk);
                }
            }
            i = inst_next(i);
        }
        bb = block_next(bb);
    }
    if sc_is_zero(dbs) { return false; }
    let nonneg = sc_is_known_non_negative(step);
    if !nonneg && !sc_is_known_negative(step) { return false; }
    step = sc_get_noop_or_sign_extend(step, wt);
    var max_btc = sc_get_noop_or_zero_extend(max_btc0, wt);
    if !sc_is_known_predicate(P_UGE, sc_op(ar, 0), pb) { return false; }
    let soff = sc_get_noop_or_zero_extend(sc_minus(sc_op(ar, 0), pb), wt);
    max_btc = sc_apply_loop_guards_g(max_btc, laa_guards());
    var olast = laa_mul_no_overflow(max_btc, sc_get_abs(step, false));
    if olast < 0 {
        max_btc = sc_get_constant_max_backedge_taken_count(sc_loop(ar));
        if sc_is_cnc(max_btc) { return false; }
        max_btc = sc_get_noop_or_zero_extend(max_btc, wt);
        olast = laa_mul_no_overflow(max_btc, sc_get_abs(step, false));
        if olast < 0 { return false; }
    }
    let oend = laa_add_no_overflow(olast, sc_get_noop_or_zero_extend(elt, wt));
    if oend < 0 { return false; }
    if nonneg {
        let eb = laa_add_no_overflow(soff, oend);
        if eb < 0 { return false; }
        dbs = sc_apply_loop_guards_g(dbs, laa_guards());
        return sc_is_known_predicate(P_ULE, eb, dbs);
    }
    return sc_is_known_predicate(P_SGE, soff, oend) && sc_is_known_predicate(P_ULE, soff, dbs);
}

// getStartAndEndForAccess(Lp, PtrExpr, EltSizeSCEV, BTC, MaxBTC, SE, PointerBounds, DT, AC, LoopGuards)
fn laa_start_end_for_access(l: i32, pe: i32, elt: i32, btc: i32, max_btc: i32, use_cache: bool) -> i32, i32 {
    var slot: i64 = -1;
    if use_cache {
        let key = ((pe as u64) << 32) | (elt as u64);
        let c = hm_get(mdc_pb_map, key, -1);
        if c >= 0 { return mdc_pb_s[c], mdc_pb_e[c]; }
        mdc_pb_key1.push(pe); mdc_pb_key2.push(elt); mdc_pb_s.push(SCEV_CNC); mdc_pb_e.push(SCEV_CNC);
        slot = mdc_pb_s.len - 1;
        hm_put(mdc_pb_map, key, slot);
    }
    var ss: i32 = -1;
    var se: i32 = -1;
    if sc_is_loop_invariant(pe, l) { ss = pe; se = pe; }
    else if sc_is_addrec(pe) {
        let ar = pe;
        ss = sc_op(ar, 0);
        if !sc_is_cnc(btc) { se = sc_evaluate_at_iteration(ar, btc); }
        else {
            if laa_eval_at_max_btc_will_not_wrap(ar, max_btc, elt) { se = sc_evaluate_at_iteration(ar, max_btc); }
            else {
                let ones = c_all_ones(sc_ty(elt));
                let itp = ce_cast(OP_INTTOPTR, ones, sc_ty(ar));
                se = sc_add(sc_get_negative(elt, SF_ANY), sc_get_scev(itp));
            }
        }
        let step = sc_get_step_recurrence(ar);
        if sc_is_const(step) {
            if ap_is_neg(sc_ap(step)) { let x = ss; ss = se; se = x; }
        } else {
            ss = sc_umin(ss, se);
            se = sc_umax(sc_op(ar, 0), se);
        }
    } else {
        return SCEV_CNC, SCEV_CNC;
    }
    se = sc_add(se, elt);
    if slot >= 0 { mdc_pb_s[slot] = ss; mdc_pb_e[slot] = se; }
    return ss, se;
}
fn laa_start_end_for_access_ty(l: i32, pe: i32, at: i32, btc: i32, max_btc: i32, use_cache: bool) -> i32, i32 {
    let it = sc_effective_ty(sc_ty(pe));
    let elt = sc_get_store_size_of(it, at);
    return laa_start_end_for_access(l, pe, elt, btc, max_btc, use_cache);
}

// ---------------------------------------------------------------------------------------------
// RuntimePointerChecking

fn rpc_reset() {
    rpc_need = false;
    rpc_ptrs.clear();
    rpc_diff.clear();
    rpc_checks.clear();
    rpc_can_diff = true;
    rpc_groups.clear();
    rpc_gmem.clear();
}
// insert(Lp, Ptr, PtrExpr, AccessTy, WritePtr, DepSetId, ASId, PSE, NeedsFreeze)
fn rpc_insert(l: i32, ptr: i32, pe: i32, at: i32, w: bool, dep: i32, asid: i32, freeze: bool) {
    let smax = pse_get_symbolic_max_btc(lai_pse);
    let btc = pse_get_backedge_taken_count(lai_pse);
    let s, e = laa_start_end_for_access_ty(l, pe, at, btc, smax, true);
    rpc_ptrs.push(PtrInfo { ptr: ptr, start: s, end: e, write: w, dep: dep, asid: asid, expr: pe, freeze: freeze });
}

// RuntimeCheckingPtrGroup(Index, RtCheck)
fn rpc_new_group(idx: i32, list: Grp[>..<]&, mem: i32[>..<]&) {
    let p = rpc_ptrs[idx];
    let at = mem.len as i32;
    mem.push(idx);
    list.push(Grp { high: p.end, low: p.start, at: at, n: 1, as_: laa_ptr_as(p.ptr), freeze: p.freeze });
}
fn rpc_group_member(g: Grp, k: i64, mem: i32[>..<]&) -> i32 { mem[(g.at as i64) + k] }
// getMinFromExprs(I, J, SE)
fn rpc_min_from_exprs(i: i32, j: i32) -> i32 {
    let ok, d = sc_compute_constant_difference(j, i);
    if !ok { return -1; }
    return if ap_is_neg(d) { j } else { i };
}
// RuntimeCheckingPtrGroup::addPointer(Index, RtCheck)
fn rpc_group_add_pointer(gi: i64, idx: i32, list: Grp[>..<]&, mem: i32[>..<]&) -> bool {
    let p = rpc_ptrs[idx];
    let m0 = rpc_min_from_exprs(p.start, list[gi].low);
    if m0 < 0 { return false; }
    let m1 = rpc_min_from_exprs(p.end, list[gi].high);
    if m1 < 0 { return false; }
    if m0 == p.start { list[gi].low = p.start; }
    if m1 != p.end { list[gi].high = p.end; }
    // Members.push_back(Index): the run moves to the end of the pool when it is not there already
    let g = list[gi];
    if (g.at as i64) + (g.n as i64) != mem.len {
        let nat = mem.len as i32;
        for k in g.n as i64 { mem.push(mem[(g.at as i64) + k]); }
        list[gi].at = nat;
    }
    mem.push(idx);
    list[gi].n += 1;
    if p.freeze { list[gi].freeze = true; }
    return true;
}

// needsChecking(I, J)
fn rpc_needs_checking_ptrs(i: i32, j: i32) -> bool {
    let a = rpc_ptrs[i];
    let b = rpc_ptrs[j];
    if !a.write && !b.write { return false; }
    if a.dep == b.dep { return false; }
    return a.asid == b.asid;
}
fn rpc_needs_checking_groups(m: i64, n: i64) -> bool {
    let gm = rpc_groups[m];
    let gn = rpc_groups[n];
    for a in gm.n as i64 {
        for b in gn.n as i64 {
            if rpc_needs_checking_ptrs(rpc_gmem[(gm.at as i64) + a], rpc_gmem[(gn.at as i64) + b]) { return true; }
        }
    }
    return false;
}

// groupChecks(DepCands)
fn rpc_group_checks() {
    rpc_groups.clear();
    rpc_gmem.clear();
    var total: i64 = 0;
    let thr = flag_int("memory-check-merge-threshold", 100);
    var seen: i32[>..<] = [];
    for i in rpc_ptrs.len {
        var s = false;
        for x in seen { if x == i as i32 { s = true; break; } }
        if s { continue; }
        let acc = mai(rpc_ptrs[i].ptr, rpc_ptrs[i].write);
        if !eq_contains(acc) {
            rpc_new_group(i as i32, rpc_groups, rpc_gmem);
            continue;
        }
        var groups: Grp[>..<] = [];
        var gmem: i32[>..<] = [];
        var members: i64[>..<] = [];
        eq_members(acc, members);
        for m in members {
            let mp = mai_ptr(m);
            // PositionMap[M.getPointer()]: every index with that pointer value, in order
            var found = false;
            for pi in rpc_ptrs.len {
                if rpc_ptrs[pi].ptr != mp { continue; }
                found = true;
                var merged = false;
                var dup = false;
                for x in seen { if x == pi as i32 { dup = true; break; } }
                if !dup { seen.push(pi as i32); }
                for gi in groups.len {
                    if total > thr { break; }
                    total++;
                    if rpc_group_add_pointer(gi, pi as i32, groups, gmem) { merged = true; break; }
                }
                if !merged { rpc_new_group(pi as i32, groups, gmem); }
            }
            let unused = found;
        }
        for g in groups {
            let at = rpc_gmem.len as i32;
            for k in g.n as i64 { rpc_gmem.push(gmem[(g.at as i64) + k]); }
            rpc_groups.push(Grp { high: g.high, low: g.low, at: at, n: g.n, as_: g.as_, freeze: g.freeze });
        }
    }
}

// tryToCreateDiffCheck(CGI, CGJ)
fn rpc_try_diff_check(gi: i64, gj: i64) -> bool {
    let ci = rpc_groups[gi];
    let cj = rpc_groups[gj];
    if ci.n != 1 || cj.n != 1 { return false; }
    var src = rpc_gmem[ci.at];
    var sink = rpc_gmem[cj.at];
    if mdc_order_count(rpc_ptrs[src].ptr, !rpc_ptrs[src].write) != 0 || mdc_order_count(rpc_ptrs[sink].ptr, !rpc_ptrs[sink].write) != 0 { return false; }
    if mdc_order_count(rpc_ptrs[src].ptr, rpc_ptrs[src].write) != 1 || mdc_order_count(rpc_ptrs[sink].ptr, rpc_ptrs[sink].write) != 1 { return false; }
    if mdc_order_first(rpc_ptrs[sink].ptr, rpc_ptrs[sink].write) < mdc_order_first(rpc_ptrs[src].ptr, rpc_ptrs[src].write) { let x = src; src = sink; sink = x; }
    let se = rpc_ptrs[src].expr;
    let ke = rpc_ptrs[sink].expr;
    if !(sc_is_addrec(se) && sc_is_affine(se) && sc_loop(se) == lai_l && sc_is_const(sc_op(se, 1))) { return false; }
    let step = sc_op(se, 1);
    if !(sc_is_addrec(ke) && sc_is_affine(ke) && sc_loop(ke) == lai_l && sc_op(ke, 1) == step) { return false; }
    var src_start = sc_op(se, 0);
    var sink_start = sc_op(ke, 0);
    let srcty = laa_ldst_type(mdc_inst[mdc_order_first(rpc_ptrs[src].ptr, rpc_ptrs[src].write)]);
    let dstty = laa_ldst_type(mdc_inst[mdc_order_first(rpc_ptrs[sink].ptr, rpc_ptrs[sink].write)]);
    if laa_scalable(srcty) || laa_scalable(dstty) { return false; }
    let a1 = dl_alloc_size(srcty);
    let a2 = dl_alloc_size(dstty);
    let alloc = if a1 > a2 { a1 } else { a2 };
    let sa = sc_ap(step);
    let absa = if ap_is_neg(sa) { ap_neg(sa) } else { sa };
    if !(ap_active_bits(absa) <= 64 && ap_zext64(absa) == alloc as u64) { return false; }
    if ap_is_neg(sa) { let x = sink_start; sink_start = src_start; src_start = x; }
    let sink_int = sc_get_ptr_to_addr(sink_start);
    let src_int = sc_get_ptr_to_addr(src_start);
    if sc_is_cnc(sink_int) || sc_is_cnc(src_int) { return false; }
    if flag_bool("hoist-runtime-checks", true) && loop_parent(lai_l) >= 0 && sc_is_addrec(sink_int) && sc_is_addrec(src_int) {
        let sl = sc_loop(src_int);
        if sl == sc_loop(sink_int) && sl == loop_parent(lai_l) && sc_get_step_recurrence(src_int) != sc_get_step_recurrence(sink_int) { return false; }
    }
    rpc_diff.push(src_int);
    rpc_diff.push(sink_int);
    rpc_diff.push(alloc as i32);
    rpc_diff.push(if rpc_ptrs[src].freeze || rpc_ptrs[sink].freeze { 1 } else { 0 });
    return true;
}

// generateChecks(DepCands)
fn rpc_generate_checks() {
    rpc_group_checks();
    rpc_checks.clear();
    for i in rpc_groups.len {
        for j in i + 1..rpc_groups.len {
            if rpc_needs_checking_groups(i, j) {
                rpc_can_diff = rpc_can_diff && rpc_try_diff_check(i, j);
                rpc_checks.push(i * 4294967296 + j);
            }
        }
    }
}

fn rpc_print_checks(depth: i64) {
    for n in rpc_checks.len {
        let c = rpc_checks[n];
        let g1 = c / 4294967296;
        let g2 = c % 4294967296;
        laa_indent(depth); errs("Check "); laa_u64(n as u64); errs(":\n");
        laa_indent(depth + 2); errs("Comparing group GRP"); laa_u64(g1 as u64); errs(":\n");
        for k in rpc_groups[g1].n as i64 { laa_indent(depth + 2); laa_print_value(rpc_ptrs[rpc_gmem[(rpc_groups[g1].at as i64) + k]].ptr); errs("\n"); }
        laa_indent(depth + 2); errs("Against group GRP"); laa_u64(g2 as u64); errs(":\n");
        for k in rpc_groups[g2].n as i64 { laa_indent(depth + 2); laa_print_value(rpc_ptrs[rpc_gmem[(rpc_groups[g2].at as i64) + k]].ptr); errs("\n"); }
    }
}
fn rpc_print(depth: i64) {
    laa_indent(depth); errs("Run-time memory checks:\n");
    rpc_print_checks(depth);
    laa_indent(depth); errs("Grouped accesses:\n");
    for gi in rpc_groups.len {
        let g = rpc_groups[gi];
        laa_indent(depth + 2); errs("Group GRP"); laa_u64(gi as u64); errs(":\n");
        laa_indent(depth + 4); errs("(Low: "); sc_print(g.low); errs(" High: "); sc_print(g.high); errs(")\n");
        for k in g.n as i64 { laa_indent(depth + 6); errs("Member: "); sc_print(rpc_ptrs[rpc_gmem[(g.at as i64) + k]].expr); errs("\n"); }
    }
}
// `OS << *V` for a pointer value: an instruction or a global prints its definition line, an argument
// `ptr %a`
fn laa_print_value(v: i32) {
    if is_inst(v) { errs_inst(v, lai_fv); return; }
    if vals[v].kind == VK_ARG { errs_operand(v, lai_fv, true); return; }
    if vals[v].kind == VK_GVAR {
        // GlobalVariable::print: the whole definition line
        if globs[glob_of(v)].nmd > 0 { laa_not_ported("printing a global variable with metadata attachments"); }
        slots_begin(lai_fv);
        let mark = out.len;
        print_global_var(v);
        var end = out.len;
        if end > mark && out[end - 1] == '\n' { end--; }
        errbuf.append(out[mark..end]);
        out.resize(mark);
        return;
    }
    if is_constant(v) && vals[v].kind != VK_FUNC && !is_global(v) { errs_operand(v, lai_fv, true); return; }
    laa_not_ported("printing a function or alias pointer");
}

// ---------------------------------------------------------------------------------------------
// MemoryDepChecker

fn mdc_reset() {
    mdc_keys.clear(); mdc_idx.clear(); mdc_inst.clear(); mdc_deps.clear();
    mdc_record = true;
    mdc_status = VS_SAFE;
    mdc_min_dep_dist = 0;
    mdc_max_safe_width = 0xFFFFFFFF;
    mdc_max_sl_fwd = 0xFFFFFFFFFFFFFFFF;
    mdc_retry = false;
    mdc_pb_key1.clear(); mdc_pb_key2.clear(); mdc_pb_s.clear(); mdc_pb_e.clear(); hm_clear(mdc_pb_map);
}
fn mdc_key_index(m: i64) -> i64 { for k in mdc_keys.len { if mdc_keys[k] == m { return k; } } return -1; }
// visitPointers(StartPtr, InnermostLoop, AddPointer)
fn laa_visit_pointers(start: i32, l: i32, out: i32[>..<]&) {
    out.clear();
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    wl.push(start);
    while wl.len > 0 {
        let p = wl.pop();
        var seen = false;
        for x in visited { if x == p { seen = true; break; } }
        if seen { continue; }
        visited.push(p);
        if is_inst_op(p, OP_PHI) && loop_contains(l, inst_parent(p)) && inst_parent(p) != loop_header(l) {
            for k in nops(p) { wl.push(op(p, k)); }
        } else { out.push(p); }
    }
}
// addAccess(LoadInst / StoreInst)
fn mdc_add_access(i: i32) {
    let w = iop(i) == OP_STORE;
    var ps: i32[>..<] = [];
    laa_visit_pointers(laa_ldst_ptr(i), lai_l, ps);
    for p in ps {
        let m = mai(p, w);
        var k = mdc_key_index(m);
        if k < 0 { mdc_keys.push(m); k = mdc_keys.len - 1; }
        mdc_idx.push(k as i32);
        mdc_inst.push(i);
    }
}
// getOrderForAccess(Ptr, IsWrite): the access indices
fn mdc_order_count(p: i32, w: bool) -> i64 {
    let k = mdc_key_index(mai(p, w));
    if k < 0 { return 0; }
    var n: i64 = 0;
    for x in mdc_idx { if x == k as i32 { n++; } }
    return n;
}
fn mdc_order_first(p: i32, w: bool) -> i64 {
    let k = mdc_key_index(mai(p, w));
    for j in mdc_idx.len { if mdc_idx[j] == k as i32 { return j; } }
    return -1;
}
fn mdc_accesses_of(m: i64, out: i64[>..<]&) {
    out.clear();
    let k = mdc_key_index(m);
    if k < 0 { return; }
    for j in mdc_idx.len { if mdc_idx[j] == k as i32 { out.push(j); } }
}

fn dep_is_safe_for_vectorization(t: i64) -> i64 {
    if t == DT_NODEP || t == DT_FORWARD || t == DT_BACKWARD_VEC { return VS_SAFE; }
    if t == DT_UNKNOWN { return VS_RT; }
    return VS_UNSAFE;
}
fn dep_is_backward(t: i64) -> bool { t == DT_BACKWARD_VEC || t == DT_BACKWARD || t == DT_BACKWARD_VEC_PREVENTS }
fn dep_is_possibly_backward(t: i64) -> bool { dep_is_backward(t) || t == DT_UNKNOWN || t == DT_INDIRECT_UNSAFE || t == DT_INVARIANT_UNSAFE }
fn dep_is_forward(t: i64) -> bool { t == DT_FORWARD || t == DT_FORWARD_PREVENTS }
fn dep_name(t: i64) -> const u8[:] {
    match t {
        DT_NODEP => { return "NoDep"; }, DT_UNKNOWN => { return "Unknown"; }, DT_INDIRECT_UNSAFE => { return "IndirectUnsafe"; },
        DT_INVARIANT_UNSAFE => { return "InvariantUnsafe"; }, DT_FORWARD => { return "Forward"; },
        DT_FORWARD_PREVENTS => { return "ForwardButPreventsForwarding"; }, DT_BACKWARD => { return "Backward"; },
        DT_BACKWARD_VEC => { return "BackwardVectorizable"; }, _ => { return "BackwardVectorizableButPreventsForwarding"; },
    }
}

fn mdc_merge_status(s: i64) { if mdc_status < s { mdc_status = s; } }
fn mdc_is_safe_for_vectorization() -> bool { mdc_status == VS_SAFE }

// couldPreventStoreLoadForward(Distance, TypeByteSize, CommonStride)
fn mdc_could_prevent_sl_forward(dist: u64, tbs: u64, common: u64) -> bool {
    let num_iters = 8 * tbs;
    var maxvf = 64 * tbs;
    if mdc_max_sl_fwd < maxvf { maxvf = mdc_max_sl_fwd; }
    var vf = 2 * tbs;
    while vf <= maxvf {
        if dist % vf != 0 && dist / vf < num_iters { maxvf = vf >> 1; break; }
        vf *= 2;
    }
    if maxvf < 2 * tbs { return true; }
    if common != 0 && maxvf < mdc_max_sl_fwd && maxvf != 64 * tbs {
        let q = maxvf / common;
        var mv: u64 = 0;
        if q > 0 { mv = 1; while mv * 2 <= q { mv *= 2; } }
        let bits = mv * tbs * 8;
        if bits < mdc_max_sl_fwd { mdc_max_sl_fwd = bits; }
    }
    return false;
}

// isSafeDependenceDistance(DL, SE, MaxBTC, Dist, MaxStride)
fn laa_is_safe_dependence_distance(max_btc: i32, dist: i32, max_stride: u64) -> bool {
    let step = sc_get_constant_ty(sc_ty(max_btc), max_stride, false);
    let prod = sc_mul(max_btc, step);
    var cd = dist;
    var cp = prod;
    let db = dl_size_bits(sc_ty(dist));
    let pbits = dl_size_bits(sc_ty(prod));
    if db > pbits { cp = sc_get_zero_extend(prod, sc_ty(dist), 0); }
    else { cd = sc_get_noop_or_sign_extend(dist, sc_ty(prod)); }
    var minus = sc_minus(cd, cp);
    if sc_is_known_positive(minus) { return true; }
    let nd = sc_get_negative(cd, SF_ANY);
    minus = sc_minus(nd, cp);
    return sc_is_known_positive(minus);
}

// areStridedAccessesIndependent
fn laa_strided_independent(dist: u64, stride: u64, tbs: u64) -> bool {
    if dist % tbs != 0 { return false; }
    return dist % stride != 0;
}

// areAccessesCompletelyBeforeOrAfter(Src, SrcTy, Sink, SinkTy)
fn mdc_completely_before_or_after(src: i32, srcty: i32, sink: i32, sinkty: i32) -> bool {
    let btc = pse_get_backedge_taken_count(lai_pse);
    let smax = pse_get_symbolic_max_btc(lai_pse);
    let ss, se = laa_start_end_for_access_ty(lai_l, src, srcty, btc, smax, true);
    if sc_is_cnc(ss) || sc_is_cnc(se) { return false; }
    let ks, ke = laa_start_end_for_access_ty(lai_l, sink, sinkty, btc, smax, true);
    if sc_is_cnc(ks) || sc_is_cnc(ke) { return false; }
    let g = laa_guards();
    let src_end = sc_apply_loop_guards_g(se, g);
    let sink_start = sc_apply_loop_guards_g(ks, g);
    if sc_is_known_predicate(P_ULE, src_end, sink_start) { return true; }
    let sink_end = sc_apply_loop_guards_g(ke, g);
    let src_start = sc_apply_loop_guards_g(ss, g);
    return sc_is_known_predicate(P_ULE, sink_end, src_start);
}

// getDependenceDistanceStrideAndSize: (is_info, deptype, dist, max_stride, common_stride (0 = none), tbs, aw, bw)
struct DDI { info: bool, ty: i64, dist: i32, max_stride: u64, has_common: bool, common: u64, tbs: u64, aw: bool, bw: bool }
fn ddi_type(t: i64) -> DDI { DDI { info: false, ty: t, dist: -1, max_stride: 0, has_common: false, common: 0, tbs: 0, aw: false, bw: false } }

fn mdc_dep_distance(a: i64, ainst0: i32, b: i64, binst0: i32) -> DDI {
    let aptr = mai_ptr(a);
    let bptr = mai_ptr(b);
    let aw = mai_write(a);
    let bw = mai_write(b);
    if !aw && !bw { return ddi_type(DT_NODEP); }
    var ainst = ainst0;
    var binst = binst0;
    var aty = laa_ldst_type(ainst);
    var bty = laa_ldst_type(binst);
    if laa_ptr_as(aptr) != laa_ptr_as(bptr) { return ddi_type(DT_UNKNOWN); }
    var preds: i32[>..<] = [];
    var oka, sa = laa_get_ptr_stride(aty, aptr, lai_l, true, true, preds);
    var okb, sb = laa_get_ptr_stride(bty, bptr, lai_l, true, true, preds);
    pse_add_predicates(lai_pse, preds);
    var src = pse_get_scev(lai_pse, aptr);
    var sink = pse_get_scev(lai_pse, bptr);
    if oka && sa < 0 {
        let x = src; src = sink; sink = x;
        let xi = ainst; ainst = binst; binst = xi;
        let xt = aty; aty = bty; bty = xt;
        let xo = oka; oka = okb; okb = xo;
        let xs = sa; sa = sb; sb = xs;
    }
    let dist = sc_minus(sink, src);
    if !oka || !okb { return ddi_type(DT_INDIRECT_UNSAFE); }
    if sa == 0 || sb == 0 {
        if sa == 0 && sb == 0 && sc_is_zero(dist) { return ddi_type(DT_INVARIANT_UNSAFE); }
        return ddi_type(DT_UNKNOWN);
    }
    if (sa > 0) != (sb > 0) { return ddi_type(DT_UNKNOWN); }
    let ast_ = dl_store_size(aty);
    let bst = dl_store_size(bty);
    let asz = dl_alloc_size(aty) as u64;
    let bsz = dl_alloc_size(bty) as u64;
    let tbs: u64 = if ast_ == bst { bsz } else { 0 };
    let sas = (if sa < 0 { -sa } else { sa }) as u64 * asz;
    let sbs = (if sb < 0 { -sb } else { sb }) as u64 * bsz;
    let maxs = if sas > sbs { sas } else { sbs };
    var r = DDI { info: true, ty: 0, dist: dist, max_stride: maxs, has_common: false, common: 0, tbs: tbs, aw: aw, bw: bw };
    if sas == sbs { r.has_common = true; r.common = sas; }
    if !sc_is_const(dist) { if sa == sb { mdc_retry = true; } }
    if sc_is_cnc(dist) { return ddi_type(DT_UNKNOWN); }
    return r;
}

// isDependent(A, AIdx, B, BIdx)
fn mdc_is_dependent(a: i64, aidx: i64, b: i64, bidx: i64) -> i64 {
    let res = mdc_dep_distance(a, mdc_inst[aidx], b, mdc_inst[bidx]);
    if !res.info {
        if res.ty == DT_UNKNOWN && mdc_check_completely(a, aidx, b, bidx) { return DT_NODEP; }
        return res.ty;
    }
    var dist = res.dist;
    let max_stride = res.max_stride;
    let tbs = res.tbs;
    let aw = res.aw;
    let bw = res.bw;
    let same_size = tbs > 0;
    if same_size && laa_is_safe_dependence_distance(pse_get_symbolic_max_btc(lai_pse), dist, max_stride) { return DT_NODEP; }
    var has_ap = false;
    var cdist: u64 = 0;
    if sc_is_const(dist) {
        has_ap = true;
        let d = sc_ap(dist);
        let ab = if ap_is_neg(d) { ap_neg(d) } else { d };
        if ap_active_bits(ab) > 64 { return DT_UNKNOWN; }
        cdist = ap_zext64(ab);
    }
    if has_ap {
        if cdist > 0 && res.has_common && res.common > 1 && same_size && laa_strided_independent(cdist, res.common, tbs) { return DT_NODEP; }
    } else {
        dist = sc_apply_loop_guards_g(dist, laa_guards());
    }
    if sc_is_known_non_positive(dist) {
        if sc_is_known_non_negative(dist) {
            if same_size { return DT_FORWARD; }
            return DT_UNKNOWN;
        }
        let true_dep = aw && !bw;
        if true_dep && flag_bool("store-to-load-forwarding-conflict-detection", true) {
            if cdist == 0 { return if mdc_check_completely(a, aidx, b, bidx) { DT_NODEP } else { DT_UNKNOWN }; }
            if !same_size || mdc_could_prevent_sl_forward(cdist, tbs, 0) { return DT_FORWARD_PREVENTS; }
        }
        return DT_FORWARD;
    }
    let mn = sc_get_signed_range_min(dist);
    if ap_sig_bits(mn) > 64 { return DT_UNKNOWN; }
    let min_dist = ap_sext64(mn);
    if min_dist <= 0 { return if mdc_check_completely(a, aidx, b, bidx) { DT_NODEP } else { DT_UNKNOWN }; }
    if !same_size {
        if mdc_check_completely(a, aidx, b, bidx) { return DT_NODEP; }
        return DT_UNKNOWN;
    }
    let fvw = flag_int("force-vector-width", 0);
    let min_forced: u64 = if fvw > 1 { fvw as u64 } else { 1 };
    let fvi = flag_int("force-vector-interleave", 0);
    let forced_unroll: u64 = if fvi > 0 { fvi as u64 } else { 1 };
    var min_num_iter = min_forced * forced_unroll;
    if min_num_iter < 2 { min_num_iter = 2; }
    let needed = max_stride * (min_num_iter - 1) + tbs;
    if needed > min_dist as u64 {
        if cdist == 0 { return if mdc_check_completely(a, aidx, b, bidx) { DT_NODEP } else { DT_UNKNOWN }; }
        return DT_BACKWARD;
    }
    if needed > mdc_min_dep_dist { return DT_BACKWARD; }
    if (min_dist as u64) < mdc_min_dep_dist { mdc_min_dep_dist = min_dist as u64; }
    let true_dep = !aw && bw;
    if true_dep && flag_bool("store-to-load-forwarding-conflict-detection", true) && cdist != 0 &&
       mdc_could_prevent_sl_forward(min_dist as u64, tbs, res.common) { return DT_BACKWARD_VEC_PREVENTS; }
    let max_vf = mdc_min_dep_dist / max_stride;
    let max_vf_bits = max_vf * tbs * 8;
    if cdist == 0 && max_vf_bits < mdc_max_target_width {
        return if mdc_check_completely(a, aidx, b, bidx) { DT_NODEP } else { DT_UNKNOWN };
    }
    if mdc_check_completely(a, aidx, b, bidx) { return DT_NODEP; }
    if max_vf_bits < mdc_max_safe_width { mdc_max_safe_width = max_vf_bits; }
    return DT_BACKWARD_VEC;
}
// the CheckCompletelyBeforeOrAfter lambda
fn mdc_check_completely(a: i64, aidx: i64, b: i64, bidx: i64) -> bool {
    let aty = laa_ldst_type(mdc_inst[aidx]);
    let bty = laa_ldst_type(mdc_inst[bidx]);
    let src = pse_get_scev(lai_pse, mai_ptr(a));
    let sink = pse_get_scev(lai_pse, mai_ptr(b));
    return mdc_completely_before_or_after(src, aty, sink, bty);
}

// areDepsSafe(DepCands, CheckDeps)
fn mdc_are_deps_safe() -> bool {
    mdc_min_dep_dist = 0xFFFFFFFFFFFFFFFF;
    var visited: i64[>..<] = [];
    let max_deps = flag_int("max-dependences", 100);
    for cur in acc_check_deps {
        var vis = false;
        for x in visited { if x == cur { vis = true; break; } }
        if vis { continue; }
        // findLeader(CurAccess): the whole class, leader first
        var cls: i64[>..<] = [];
        eq_members(cur, cls);
        var ai: i64 = 0;
        while ai < cls.len {
            let am = cls[ai];
            var seen = false;
            for x in visited { if x == am { seen = true; break; } }
            if !seen { visited.push(am); }
            let aw = mai_write(am);
            var oi = if aw { ai } else { ai + 1 };
            while oi < cls.len {
                let om = cls[oi];
                var acc_a: i64[>..<] = [];
                mdc_accesses_of(am, acc_a);
                var acc_o: i64[>..<] = [];
                mdc_accesses_of(om, acc_o);
                for i1 in acc_a.len {
                    let i2s = if oi == ai { i1 + 1 } else { 0 };
                    let i2e = if oi == ai { acc_a.len } else { acc_o.len };
                    var i2 = i2s;
                    while i2 < i2e {
                        let x1 = acc_a[i1];
                        let x2 = if oi == ai { acc_a[i2] } else { acc_o[i2] };
                        var ma = am; var ia = x1;
                        var mb = om; var ib = x2;
                        if x1 > x2 { ma = om; ia = x2; mb = am; ib = x1; }
                        let t = mdc_is_dependent(ma, ia, mb, ib);
                        mdc_merge_status(dep_is_safe_for_vectorization(t));
                        if mdc_record {
                            if t != DT_NODEP { mdc_deps.push(Dep { src: ia as i32, dst: ib as i32, ty: t as i32 }); }
                            if mdc_deps.len >= max_deps { mdc_record = false; mdc_deps.clear(); }
                        }
                        if !mdc_record && !mdc_is_safe_for_vectorization() { return false; }
                        i2++;
                    }
                }
                oi++;
            }
            ai++;
        }
    }
    return mdc_is_safe_for_vectorization();
}

// ---------------------------------------------------------------------------------------------
// AccessAnalysis

// findForkedSCEVs: (scev, needs_freeze) pairs pushed on ff_s / ff_f (1 or 2 of them; a recursive call
// returns how many it pushed)
var ff_s: i32[>..<];
var ff_f: bool[>..<];
recursive fn laa_ff_push(s: i32, f: bool) -> i64 { ff_s.push(s); ff_f.push(f); return 1; }
recursive fn laa_find_forked_scevs(l: i32, ptr: i32, depth: i64) -> i64 {
    let sv = sc_get_scev(ptr);
    if sc_is_addrec(sv) || lu_loop_invariant(l, ptr) || !is_inst(ptr) || depth == 0 {
        return laa_ff_push(sv, !laa_not_undef_poison(ptr));
    }
    let d = depth - 1;
    let o = iop(ptr);
    let base = ff_s.len;
    if o == OP_GEP {
        let st = gep_src_ty(ptr);
        if nops(ptr) != 2 || ty_is_vector(st) { return laa_ff_push(sv, !laa_not_undef_poison(ptr)); }
        let nb = laa_find_forked_scevs(l, op(ptr, 0), d);
        let no = laa_find_forked_scevs(l, op(ptr, 1), d);
        var nf = false;
        for k in nb + no { if ff_f[base + k] { nf = true; } }
        var bs: i32[2] = [-1, -1];
        var os: i32[2] = [-1, -1];
        if no == 2 && nb == 1 { bs[0] = ff_s[base]; bs[1] = ff_s[base]; os[0] = ff_s[base + 1]; os[1] = ff_s[base + 2]; }
        else if nb == 2 && no == 1 { bs[0] = ff_s[base]; bs[1] = ff_s[base + 1]; os[0] = ff_s[base + 2]; os[1] = ff_s[base + 2]; }
        else { ff_s.resize(base); ff_f.resize(base); return laa_ff_push(sv, nf); }
        ff_s.resize(base); ff_f.resize(base);
        let ipt = sc_effective_ty(vals[op(ptr, 0)].ty);
        let size = sc_get_size_of(ipt, st);
        for k in 2 { laa_ff_push(sc_add(bs[k], sc_mul(size, sc_get_truncate_or_sign_extend(os[k], ipt, 0))), nf); }
        return 2;
    }
    if o == OP_SELECT || o == OP_PHI {
        var n: i64 = 0;
        if o == OP_SELECT {
            n += laa_find_forked_scevs(l, op(ptr, 1), d);
            n += laa_find_forked_scevs(l, op(ptr, 2), d);
        } else if nops(ptr) == 2 {
            n += laa_find_forked_scevs(l, op(ptr, 0), d);
            n += laa_find_forked_scevs(l, op(ptr, 1), d);
        }
        if n == 2 { return 2; }
        ff_s.resize(base); ff_f.resize(base);
        return laa_ff_push(sv, !laa_not_undef_poison(ptr));
    }
    if o == OP_ADD || o == OP_SUB {
        let nl = laa_find_forked_scevs(l, op(ptr, 0), d);
        let nr = laa_find_forked_scevs(l, op(ptr, 1), d);
        var nf = false;
        for k in nl + nr { if ff_f[base + k] { nf = true; } }
        var ls: i32[2] = [-1, -1];
        var rs: i32[2] = [-1, -1];
        if nl == 2 && nr == 1 { ls[0] = ff_s[base]; ls[1] = ff_s[base + 1]; rs[0] = ff_s[base + 2]; rs[1] = ff_s[base + 2]; }
        else if nr == 2 && nl == 1 { ls[0] = ff_s[base]; ls[1] = ff_s[base]; rs[0] = ff_s[base + 1]; rs[1] = ff_s[base + 2]; }
        else { ff_s.resize(base); ff_f.resize(base); return laa_ff_push(sv, nf); }
        ff_s.resize(base); ff_f.resize(base);
        for k in 2 { laa_ff_push(if o == OP_ADD { sc_add(ls[k], rs[k]) } else { sc_minus(ls[k], rs[k]) }, nf); }
        return 2;
    }
    return laa_ff_push(sv, !laa_not_undef_poison(ptr));
}
// isGuaranteedNotToBeUndefOrPoison(V) (no AC, context, DT)
fn laa_not_undef_poison(v: i32) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
    let r = is_guaranteed_not_to_be_undef_or_poison(v, -1, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
    return r;
}

// DepSetId: leader pointer -> id
var acc_depset_k: i32[>..<];
var acc_depset_v: i32[>..<];

// createCheckForAccess(RtCheck, Access, AccessTy, StridesMap, DepSetId, TheLoop, RunningDepId, ASId, Assume)
fn acc_create_check_for_access(access: i64, at: i32, running: i32&, asid: i32, assume: bool) -> bool {
    let ptr = mai_ptr(access);
    var rs: i32[>..<] = [];
    var rf: bool[>..<] = [];
    let fb = ff_s.len;
    let fnn = laa_find_forked_scevs(lai_l, ptr, flag_int("max-forked-scev-depth", 5));
    for k in fnn { rs.push(ff_s[fb + k]); rf.push(ff_f[fb + k]); }
    ff_s.resize(fb); ff_f.resize(fb);
    var forked = rs.len == 2;
    if forked {
        for x in rs { if !(sc_is_loop_invariant(x, lai_l) || sc_is_addrec(x)) { forked = false; } }
    }
    if !forked {
        rs.clear(); rf.clear();
        rs.push(laa_replace_symbolic_stride_scev(ptr)); rf.push(false);
    }
    var preds: i32[>..<] = [];
    for k in rs.len {
        if sc_is_loop_invariant(rs[k], lai_l) { continue; }
        var ar = if sc_is_addrec(rs[k]) { rs[k] } else { -1 };
        if ar < 0 && assume { ar = pse_get_as_add_rec(lai_pse, ptr, true, preds); }
        if ar < 0 || !sc_is_affine(ar) { return false; }
        if rs.len == 1 {
            pse_add_predicates(lai_pse, preds);
            preds.clear();
            let sar = laa_replace_symbolic_stride_scev(ptr);
            if sc_is_addrec(sar) { ar = sar; }
            rs[k] = ar;
        }
        if !laa_is_no_wrap(ar, if rs.len == 1 { ptr } else { -1 }, at, lai_l, false, 0, assume, preds) { return false; }
    }
    pse_add_predicates(lai_pse, preds);
    for k in rs.len {
        var dep: i32 = 0;
        if eq_contains(access) {
            let leader = mai_ptr(eq_nodes[eq_leader_node(access)].m);
            var j: i64 = -1;
            for x in acc_depset_k.len { if acc_depset_k[x] == leader { j = x; } }
            if j < 0 { acc_depset_k.push(leader); acc_depset_v.push(0); j = acc_depset_k.len - 1; }
            if acc_depset_v[j] == 0 { acc_depset_v[j] = running; running += 1; }
            dep = acc_depset_v[j];
        } else { dep = running; running += 1; }
        rpc_insert(lai_l, ptr, rs[k], at, mai_write(access), dep, asid, rf[k]);
    }
    return true;
}

// canCheckPtrAtRT(RtCheck, TheLoop, StridesMap, UncomputablePtr, AllowPartial, DepChecker): ok, uncomputable
fn acc_can_check_ptr_at_rt() -> bool, i32 {
    var can_rt = true;
    var may_need = false;
    var uncomputable: i32 = -1;
    if !acc_rt_needed { return true, -1; }
    if mdc_record {
        for d in mdc_deps {
            if d.ty as i64 != DT_UNKNOWN { continue; }
            let s = mdc_inst[d.src];
            let t = mdc_inst[d.dst];
            eq_erase_class(mai(laa_ldst_ptr(s), inst_may_write_memory(s)));
            eq_erase_class(mai(laa_ldst_ptr(t), inst_may_write_memory(t)));
        }
    } else {
        acc_check_deps.clear();
        eq_clear();
    }
    var asid: i32 = 0;
    for s in ast_nsets() {
        if !ast_set_live(s as i32) { continue; }
        var nr = 0;
        var nw = 0;
        var can_as = true;
        asid++;
        var ps: i32[>..<] = [];
        acc_as_pointers(s as i32, ps);
        var running: i32 = 1;
        acc_depset_k.clear(); acc_depset_v.clear();
        var retry_m: i64[>..<] = [];
        var retry_t: i32[>..<] = [];
        var infos: i64[>..<] = [];
        for p in ps {
            let w = acc_contains(mai(p, true));
            if w { nw++; } else { nr++; }
            infos.push(mai(p, w));
        }
        if nw == 0 || (nw == 1 && nr == 0) { continue; }
        for a in infos {
            let k = acc_key_index(a);
            var x = acc_tat[k];
            while x >= 0 {
                if !acc_create_check_for_access(a, acc_tys[x], running, asid, false) {
                    retry_m.push(a); retry_t.push(acc_tys[x]);
                    can_as = false;
                }
                x = acc_tnext[x];
            }
        }
        let needs = running > 2 || retry_m.len > 0;
        if needs && !can_as {
            can_as = true;
            for r in retry_m.len {
                if !acc_create_check_for_access(retry_m[r], retry_t[r], running, asid, true) {
                    can_as = false;
                    uncomputable = mai_ptr(retry_m[r]);
                    if !lai_allow_partial { break; }
                }
            }
        }
        can_rt = can_rt && can_as;
        may_need = may_need || needs;
        asid++;
    }
    let np = rpc_ptrs.len;
    for i in np {
        for j in i + 1..np {
            if rpc_ptrs[i].dep == rpc_ptrs[j].dep { continue; }
            if rpc_ptrs[i].asid != rpc_ptrs[j].asid { continue; }
            if laa_ptr_as(rpc_ptrs[i].ptr) != laa_ptr_as(rpc_ptrs[j].ptr) { return false, uncomputable; }
        }
    }
    if may_need && (can_rt || lai_allow_partial) { rpc_generate_checks(); }
    rpc_need = if can_rt { rpc_checks.len != 0 } else { may_need };
    let ok = !rpc_need || can_rt;
    if !ok && !lai_allow_partial { rpc_reset(); }
    return ok, uncomputable;
}

// buildDependenceSets
fn acc_build_dependence_sets() {
    for s in ast_nsets() {
        if !ast_set_live(s as i32) { continue; }
        var has_write = false;
        var ul_obj: i32[>..<] = [];   // ObjToLastAccess keys (object, address space packed below) and values
        var ul_as: i64[>..<] = [];
        var ul_acc: i64[>..<] = [];
        var deferred: i64[>..<] = [];
        var ps: i32[>..<] = [];
        acc_as_pointers(s as i32, ps);
        for pass in 2 {
            let use_def = pass == 1;
            for p in ps {
                let n = if use_def { deferred.len } else { acc_keys.len };
                for ki in n {
                    let key = if use_def { deferred[ki] } else { acc_keys[ki] };
                    let ap = mai_ptr(key);
                    let w = mai_write(key);
                    if ap != p { continue; }
                    let ro = acc_is_readonly(p) && !w;
                    if use_def && !ro { continue; }
                    let access = mai(p, w);
                    eq_insert(access);
                    if !use_def && ro {
                        var dup = false;
                        for x in deferred { if x == access { dup = true; } }
                        if !dup { deferred.push(access); }
                        continue;
                    }
                    if (w || ro) && has_write { acc_check_deps.push(access); acc_rt_needed = true; }
                    if w { has_write = true; }
                    var uos: i32[>..<] = [];
                    laa_underlying_objects(p, uos);
                    for uo in uos {
                        if vals[uo].kind == VK_CNULL && !null_pointer_is_defined(lai_fv, ty_bits(vals[uo].ty)) { continue; }
                        let pas = laa_ptr_as(p);
                        var f: i64 = -1;
                        for x in ul_obj.len { if ul_obj[x] == uo && ul_as[x] == pas { f = x; } }
                        if f < 0 { ul_obj.push(uo); ul_as.push(pas); ul_acc.push(access); }
                        else { eq_union(access, ul_acc[f]); ul_acc[f] = access; }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// LoopAccessInfo

fn lai_record(msg: const u8[:]) { lai_has_report = true; lai_report.resize(0); lai_report.append(msg); }

// canAnalyzeLoop
fn lai_can_analyze_loop() -> bool {
    let l = lai_l;
    if !loop_is_innermost(l) { lai_record("loop is not the innermost loop"); return false; }
    if loop_num_back_edges(l) != 1 { lai_record("loop control flow is not understood by analyzer"); return false; }
    let ec = pse_get_symbolic_max_btc(lai_pse);
    if sc_is_cnc(ec) { lai_record("could not determine number of loop iterations"); return false; }
    return true;
}

// isInvariant(V)
fn lai_is_invariant(v: i32) -> bool {
    if lu_loop_invariant(lai_l, v) { return true; }
    if !sc_is_scevable(vals[v].ty) { return false; }
    return sc_is_loop_invariant(sc_get_scev(v), lai_l);
}

// getLoopVariantGEPOperand
fn laa_loop_variant_gep_operand(ptr: i32, l: i32) -> i32 {
    if !is_inst_op(ptr, OP_GEP) { return ptr; }
    var v = ptr;
    for k in nops(ptr) {
        let u = op(ptr, k);
        if !sc_is_loop_invariant(sc_get_scev(u), l) {
            if v == ptr { v = u; } else { return ptr; }
        }
    }
    return v;
}
fn laa_is_integral_cast(s: i32) -> bool { let k = sc_kind(s); k == SC_TRUNC || k == SC_ZEXT || k == SC_SEXT || k == SC_PTRTOINT || k == SC_PTRTOADDR }
// getStrideFromPointer(Ptr, SE, Lp)
fn laa_stride_from_pointer(ptr0: i32, l: i32) -> i32 {
    if ty_kind(vals[ptr0].ty) != TK_PTR { return -1; }
    let ptr = laa_loop_variant_gep_operand(ptr0, l);
    var v = sc_get_scev(ptr);
    if ptr != ptr0 { while laa_is_integral_cast(v) { v = sc_op(v, 0); } }
    if !(sc_is_addrec(v) && sc_is_affine(v) && sc_loop(v) == l) { return -1; }
    v = sc_op(v, 1);
    if !sc_is_loop_invariant(v, l) { return -1; }
    if sc_kind(v) == SC_UNKNOWN { return v; }
    if sc_kind(v) == SC_MUL && sc_nops(v) == 2 && sc_is_const(sc_op(v, 0)) { v = sc_op(v, 1); }
    if laa_is_integral_cast(v) && sc_kind(sc_op(v, 0)) == SC_UNKNOWN { return v; }
    return -1;
}
// collectStridedAccess(MemAccess)
fn lai_collect_strided_access(i: i32) {
    let ptr = laa_ldst_ptr(i);
    if ptr < 0 { return; }
    let se = laa_stride_from_pointer(ptr, lai_l);
    if se < 0 { return; }
    // m_scev_UndefOrPoison
    if sc_kind(se) == SC_UNKNOWN && is_undef_or_poison(sc_value(se)) { return; }
    if !flag_bool("laa-speculate-unit-stride", true) { return; }
    let mb = pse_get_symbolic_max_btc(lai_pse);
    let stb = dl_size_bits(sc_ty(se));
    let beb = dl_size_bits(sc_ty(mb));
    var cs = se;
    var cb = mb;
    if beb >= stb { cs = sc_get_noop_or_sign_extend(se, sc_ty(mb)); }
    else { cb = sc_get_zero_extend(mb, sc_ty(se), 0); }
    let d = sc_minus(cs, cb);
    if sc_is_known_positive(d) { return; }
    var base = se;
    if laa_is_integral_cast(base) { base = sc_op(base, 0); }
    for k in lai_strides_k.len { if lai_strides_k[k] == ptr { lai_strides_v[k] = base; return; } }
    lai_strides_k.push(ptr);
    lai_strides_v.push(base);
}

// analyzeLoop(AA, LI, TLI, DT)
fn lai_analyze_loop() -> bool {
    let l = lai_l;
    var loads: i32[>..<] = [];
    var stores: i32[>..<] = [];
    acc_scopes.clear();
    var num_reads: i64 = 0;
    var num_rw: i64 = 0;
    var complex = false;
    lai_has_convergent = false;
    rpc_ptrs.clear();
    rpc_need = false;
    let parallel = loop_is_annotated_parallel(l);
    let versioning = flag_bool("enable-mem-access-versioning", true) &&
        !(func_has_fn_attr(lai_fv, AK_OptimizeForSize) || func_has_fn_attr(lai_fv, AK_MinSize));
    var rpo: i32[>..<] = [];
    lu_loop_rpo(l, rpo);
    for bb in rpo {
        var i = block_first(bb);
        while i >= 0 {
            let ni = inst_next(i);
            if is_callbase(i) && call_has_fn_attr(i, AK_Convergent) { lai_has_convergent = true; }
            if complex && lai_has_convergent { return false; }
            if complex { i = ni; continue; }
            if inst_iid(i) == IID_experimental_noalias_scope_decl {
                let m = op(i, 0);
                if vals[m].kind == VK_MDVAL {
                    let sl = vals[m].sub;
                    for k in mds[sl].nops as i64 { acc_scopes.push(md_op(sl, k)); }
                }
            }
            let is_call = iop(i) == OP_CALL;
            if is_call && laa_vector_intrinsic_id_for_call(i) != 0 { i = ni; continue; }
            if inst_may_read_memory(i) {
                if is_call && !call_is_nobuiltin(i) && called_function(i) >= 0 && laa_has_vector_variants(i) {
                    laa_not_ported("VFDatabase mappings (vector-function-abi-variant)");
                }
                if iop(i) != OP_LOAD { lai_record("instruction cannot be vectorized"); complex = true; i = ni; continue; }
                if !ld_simple(i) && !parallel { lai_record("read with atomic ordering or volatile read"); complex = true; i = ni; continue; }
                lai_num_loads++;
                loads.push(i);
                mdc_add_access(i);
                if versioning { lai_collect_strided_access(i); }
                i = ni;
                continue;
            }
            if inst_may_write_memory(i) {
                if iop(i) != OP_STORE { lai_record("instruction cannot be vectorized"); complex = true; i = ni; continue; }
                if !ld_simple(i) && !parallel { lai_record("write with atomic ordering or volatile write"); complex = true; i = ni; continue; }
                lai_num_stores++;
                stores.push(i);
                mdc_add_access(i);
                if versioning { lai_collect_strided_access(i); }
            }
            i = ni;
        }
    }
    if complex { return false; }
    if stores.len == 0 { return true; }
    eq_clear();
    acc_keys.clear(); acc_tat.clear(); acc_tys.clear(); acc_tnext.clear(); acc_tlast.clear();
    acc_check_deps.clear(); acc_readonly.clear(); acc_rt_needed = false;
    acc_q = aq_push(CA_SIMPLE);
    aq_set_cross(acc_q, true);
    ast_reset(acc_q);
    let r = lai_analyze_accesses(loads, stores, num_reads, num_rw, parallel);
    aq_pop(acc_q);
    acc_q = -1;
    return r;
}

fn ld_simple(i: i32) -> bool { insts[inst_of(i)].ord == 0 && (insts[inst_of(i)].bits & 1) == 0 }
// VFDatabase::getMappings(CI).empty(): the call site's "vector-function-abi-variant" attribute
fn laa_has_vector_variants(c: i32) -> bool {
    let a = aset_find_str(alist_fn(insts[inst_of(c)].attrs), "vector-function-abi-variant");
    return a >= 0;
}

fn lai_analyze_accesses(loads: const i32[:], stores: const i32[:], nr0: i64, nrw0: i64, parallel: bool) -> bool {
    let l = lai_l;
    var num_reads = nr0;
    var num_rw = nrw0;
    var seen_p: i32[>..<] = [];
    var seen_t: i32[>..<] = [];
    var uniform: i32[>..<] = [];
    for st in stores {
        let ptr = laa_ldst_ptr(st);
        if lai_is_invariant(ptr) {
            lai_stores_to_inv.push(st);
            var dup = false;
            for x in uniform { if x == ptr { dup = true; } }
            if dup { lai_st_st_inv = true; } else { uniform.push(ptr); }
        }
        let at = laa_ldst_type(st);
        var seen = false;
        for k in seen_p.len { if seen_p[k] == ptr && seen_t[k] == at { seen = true; } }
        if !seen {
            seen_p.push(ptr); seen_t.push(at);
            num_rw++;
            var loc = ml_get(st);
            if laa_block_needs_predication(inst_parent(st), l) { loc.tbaa = -1; }
            var ps: i32[>..<] = [];
            laa_visit_pointers(loc.ptr, l, ps);
            for p in ps { var nl = loc; nl.ptr = p; acc_add_store(nl, at); }
        }
    }
    if parallel { return true; }
    for ld in loads {
        let ptr = laa_ldst_ptr(ld);
        var ro = false;
        let at = laa_ldst_type(ld);
        var seen = false;
        for k in seen_p.len { if seen_p[k] == ptr && seen_t[k] == at { seen = true; } }
        var inserted = false;
        if !seen { seen_p.push(ptr); seen_t.push(at); inserted = true; }
        var stride_ok = true;
        if !inserted {
            let ok, s = laa_get_ptr_stride_assume(at, ptr, l, false, true);
            stride_ok = ok;
            let unused = s;
        }
        if inserted || !stride_ok { num_reads++; ro = true; }
        for x in uniform { if x == ptr { lai_ld_st_inv = true; } }
        var loc = ml_get(ld);
        if laa_block_needs_predication(inst_parent(ld), l) { loc.tbaa = -1; }
        var ps: i32[>..<] = [];
        laa_visit_pointers(loc.ptr, l, ps);
        for p in ps { var nl = loc; nl.ptr = p; acc_add_load(nl, at, ro); }
    }
    if num_rw == 1 && num_reads == 0 { return true; }
    acc_build_dependence_sets();
    let ok, unc = acc_can_check_ptr_at_rt();
    lai_has_complete_rt = ok;
    if !lai_has_complete_rt { lai_record("cannot identify array bounds"); return false; }
    let unused = unc;
    var deps_safe = true;
    if acc_check_deps.len != 0 {
        deps_safe = mdc_are_deps_safe();
        if !deps_safe && mdc_retry && mdc_status == VS_RT {
            rpc_reset();
            rpc_need = true;
            let ok2, unc2 = acc_can_check_ptr_at_rt();
            lai_has_complete_rt = ok2;
            let unused2 = unc2;
            if !lai_has_complete_rt { lai_record("cannot check memory dependencies at runtime"); return false; }
            acc_check_deps.clear();
            mdc_deps.clear();
            deps_safe = true;
        }
    }
    if mdc_record {
        for d in mdc_deps {
            if d.ty as i64 != DT_INVARIANT_UNSAFE { continue; }
            let s = mdc_inst[d.src];
            let t = mdc_inst[d.dst];
            if (iop(s) == OP_LOAD) != (iop(t) == OP_LOAD) { lai_ld_st_inv = true; } else { lai_st_st_inv = true; }
        }
    }
    if lai_has_convergent { lai_record("cannot add control dependency to convergent operation"); return false; }
    if deps_safe { return true; }
    lai_emit_unsafe_dependence_remark();
    return false;
}

// emitUnsafeDependenceRemark
fn lai_emit_unsafe_dependence_remark() {
    if !mdc_record { return; }
    var found: i64 = -1;
    for k in mdc_deps.len { if dep_is_safe_for_vectorization(mdc_deps[k].ty as i64) != VS_SAFE { found = k; break; } }
    if found < 0 { return; }
    let d = mdc_deps[found];
    var forced = false;
    let md = find_option_md_for_loop_id(loop_id(lai_l), "llvm.loop.distribute.enable");
    if md >= 0 && mds[md].nops >= 2 {
        let o = md_op(md, 1);
        if o >= 0 && mds[o].kind == MK_VALUE && is_cint(mds[o].extra) { forced = !cint_is_zero(mds[o].extra); }
    }
    var msg: u8[>..] = [];
    if forced { msg.append("unsafe dependent memory operations in loop."); }
    else { msg.append("unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop"); }
    let t = d.ty as i64;
    if t == DT_BACKWARD { msg.append("\nBackward loop carried data dependence."); }
    else if t == DT_FORWARD_PREVENTS { msg.append("\nForward loop carried data dependence that prevents store-to-load forwarding."); }
    else if t == DT_BACKWARD_VEC_PREVENTS { msg.append("\nBackward loop carried data dependence that prevents store-to-load forwarding."); }
    else if t == DT_INDIRECT_UNSAFE { msg.append("\nUnsafe indirect dependence."); }
    else if t == DT_INVARIANT_UNSAFE { msg.append("\nUnsafe dependence on loop-invariant address."); }
    else if t == DT_UNKNOWN { msg.append("\nUnknown data dependence."); }
    let s = mdc_inst[d.src];
    var sl = inst_get_md(s, 0);
    let pp = laa_ldst_ptr(s);
    if pp >= 0 && is_inst(pp) { sl = inst_get_md(pp, 0); }
    if sl >= 0 {
        msg.append(" Memory location is the same as accessed at ");
        laa_fmt_debug_loc(msg, sl);
    }
    lai_record(msg);
}
// DebugLoc::print: file:line:col (and " @[ ...]" for inlined-at, not ported)
fn laa_fmt_debug_loc(b: u8[>..]&, dl: i32) {
    let sc = di_slot(dl, "scope");
    if di_slot(dl, "inlinedAt") >= 0 { laa_not_ported("printing an inlined debug location"); }
    let file = di_scope_file(sc);
    if file >= 0 { let fnm = di_slot(file, "filename"); if fnm >= 0 { b.append(sbytes(mds[fnm].extra)); } }
    b.push(':');
    laa_fmt_u64(b, di_int(dl, "line") as u64);
    b.push(':');
    laa_fmt_u64(b, di_int(dl, "column") as u64);
}

// LoopAccessInfo(L, SE, TTI, TLI, AA, DT, LI, AC, AllowPartial): analyse l into the lai_* state
fn lai_compute(l: i32, allow_partial: bool) {
    lai_l = l;
    lai_fv = block_func(loop_header(l));
    tli_cur_fn = lai_fv;
    tti_init_function(lai_fv, globs[glob_of(lai_fv)].module);
    lai_pse = pse_new(l);
    lai_allow_partial = allow_partial;
    lai_can_vec_mem = false;
    lai_has_convergent = false;
    lai_has_report = false;
    lai_report.resize(0);
    lai_has_complete_rt = false;
    lai_st_st_inv = false;
    lai_ld_st_inv = false;
    lai_num_loads = 0;
    lai_num_stores = 0;
    lai_stores_to_inv.clear();
    lai_strides_k.clear();
    lai_strides_v.clear();
    lai_guards = -1;
    mdc_reset();
    rpc_reset();
    eq_clear();
    // MaxTargetVectorWidthInBits: getRegisterBitWidth(RGK_FixedWidthVector) * 2 (no scalable vectors on x86)
    var w: u64 = 32;
    if tti_kind == TTI_X86 {
        w = 0;
        if x86_avx512() && x86_prefer_width >= 512 { w = 512; }
        else if x86_avx() && x86_prefer_width >= 256 { w = 256; }
        else if x86_sse1() && x86_prefer_width >= 128 { w = 128; }
    }
    mdc_max_target_width = w * 2;
    if lai_can_analyze_loop() { lai_can_vec_mem = lai_analyze_loop(); }
}

// LoopAccessInfo::print(OS, Depth)
fn lai_print(depth: i64) {
    if lai_can_vec_mem {
        laa_indent(depth); errs("Memory dependences are safe");
        if mdc_max_safe_width != 0xFFFFFFFF { errs(" with a maximum safe vector width of "); laa_u64(mdc_max_safe_width); errs(" bits"); }
        if mdc_max_sl_fwd != 0xFFFFFFFFFFFFFFFF { errs(", with a maximum safe store-load forward width of "); laa_u64(mdc_max_sl_fwd); errs(" bits"); }
        if rpc_need { errs(" with run-time checks"); }
        errs("\n");
    }
    if lai_has_convergent { laa_indent(depth); errs("Has convergent operation in loop\n"); }
    if lai_has_report { laa_indent(depth); errs("Report: "); errs(lai_report); errs("\n"); }
    if mdc_record {
        laa_indent(depth); errs("Dependences:\n");
        for d in mdc_deps {
            laa_indent(depth + 2); errs(dep_name(d.ty as i64)); errs(":\n");
            laa_indent(depth + 4); errs_inst(mdc_inst[d.src], lai_fv); errs(" -> \n");
            laa_indent(depth + 4); errs_inst(mdc_inst[d.dst], lai_fv); errs("\n");
            errs("\n");
        }
    } else { laa_indent(depth); errs("Too many dependences, not recorded\n"); }
    rpc_print(depth);
    if rpc_need && !lai_has_complete_rt { laa_indent(depth); errs("Generated run-time checks are incomplete\n"); }
    errs("\n");
    laa_indent(depth);
    errs("Non vectorizable stores to invariant address were ");
    if !(lai_st_st_inv || lai_ld_st_inv) { errs("not "); }
    errs("found in loop.\n");
    laa_indent(depth); errs("SCEV assumptions:\n");
    su_print(pse_union(lai_pse), depth);
    errs("\n");
    laa_indent(depth); errs("Expressions re-written:\n");
    pse_print(lai_pse, depth);
}

// LoopAccessInfoPrinterPass::run
fn print_access_info(fv: i32, allow_partial: bool) {
    li_get(fv);
    dt_get(fv, DT_DOM);
    scev_get(fv);
    aa_begin(fv);
    tli_cur_fn = fv;
    errs("Printing analysis 'Loop Access Analysis' for function '");
    errs(val_name(fv));
    errs("':\n");
    lpm_append_function_loops_to(fv);
    while lpm_pw.len > 0 {
        let l = lpm_pw_pop();
        errs("  ");
        errs(val_name(loop_header(l)));
        errs(":\n");
        lai_compute(l, allow_partial);
        lai_print(4);
    }
    pse_reset();
}

// A private SmallPriorityWorklist filled by appendLoopsToWorklist(LI) (the loop pass manager's one is busy
// inside loop pipelines)
var lpm_pw: i32[>..<];
fn lpm_pw_pop() -> i32 { let r = lpm_pw[lpm_pw.len - 1]; lpm_pw.pop(); return r; }
fn lpm_append_function_loops_to(fv: i32) {
    lpm_pw.clear();
    // appendReversedLoopsToWorklist over the top-level loops in LoopInfo order: a preorder of each nest
    // (children pushed in order, popped LIFO), each nest inserted as a sequence (no duplicates arise)
    for k in li_ntop(fv) {
        var stack: i32[>..<] = [];
        stack.push(li_top(fv, k));
        while stack.len > 0 {
            let l = stack.pop();
            for c in loop_nsubs(l) { stack.push(loop_sub(l, c)); }
            lpm_pw.push(l);
        }
    }
}
