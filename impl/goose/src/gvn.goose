// GVN: port of llvm/lib/Transforms/Scalar/GVN.cpp (GVNPass::run/runImpl, the ValueTable with its Expressions,
// phi translation and call numbering, the LeaderMap, load elimination through MemoryDependence or MemorySSA
// (findReachingValuesForLoad), load PRE (PerformLoadPRE, performLoopLoadPRE), scalar PRE, propagateEquality,
// dead-block handling, processAssumeIntrinsic / processMaskedLoad, every gvn<...> parameter and cl::opt). Also
// MergeBlockIntoPredecessor (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp) with LoopInfo/MemorySSAUpdater/
// MemDep, EliminateDuplicatePHINodes (both implementations), patchReplacementInstruction and
// replaceDominatedUsesWithIf (llvm/lib/Transforms/Utils/Local.cpp), GEPOperator::collectOffset
// (llvm/lib/IR/Operator.cpp), isPointerUseReplacable / canReplacePointersInUseIfEqual (llvm/lib/Analysis/Loads.cpp)
// and ImplicitControlFlowTracking (InstructionPrecedenceTracking.cpp, through mustexec.goose's caches).
// Not ported: optimization remarks (never printed).
//
// State is global (one GVN run at a time). DenseMaps are HMaps (scev.goose); expressions are records in gx with
// their VarArgs in gx_args, found through a chained hash table that keeps insertion order (a DenseMap lookup meets
// equal-hash entries in that order, and Expression equality with attribute intersection is not transitive).
// Expressions under construction keep their VarArgs on the gvs stack (the numbering is recursive).
import std;
import ir;
import irutil;
import instinfo;
import analyses;
import calls;
import gen_iids;
import pm;
import flags;
import domtree;
import dtu;
import loopinfo;
import memloc;
import aa;
import aautil;
import memoryssa;
import mssaupdater;
import memdep;
import phitrans;
import vncoerce;
import vt;
import tli;
import local;
import instsimplify;
import instident;
import salvage;
import knowledge;
import ssaupdater;
import breakcrit;
import cfgutil;
import mustexec;
import speculate;
import memorybuiltins;
import datalayout;
import constfold;
import scev;
import predinfo;
import dinfo;
import apint;
import assume;

fn gvn_not_ported(what: const u8[:]) { fatal(str("GVN: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Options (GVNOptions + cl::opts)

var gv_fn: i32 = -1;
var gv_scalar_pre: bool = true;
var gv_load_pre: bool = true;
var gv_load_in_loop_pre: bool = true;
var gv_split_backedge: bool = false;
var gv_memdep: bool = true;
var gv_mssa_enabled: bool = false;
var gv_md: bool = false;          // MD != nullptr
var gv_mssa: bool = false;        // MSSA != nullptr (and MSSAU)
var gv_max_num_deps: i64 = 100;
var gv_max_bb_spec: i64 = 600;
var gv_max_visited: i64 = 100;
var gv_max_insns: i64 = 100;
var gv_scan_users_limit: i64 = 100;
var gv_ac: bool = true;

// gvn<...> parameters (parseGVNOptions): bit 2k = set, bit 2k+1 = value, k: 0 scalar-pre, 1 load-pre,
// 2 split-backedge-load-pre, 3 memdep, 4 memoryssa
fn gvn_opt(arg: i32, k: i64, dflt: bool) -> bool {
    if ((arg >> (2 * k)) & 1) != 0 { return ((arg >> (2 * k + 1)) & 1) != 0; }
    return dflt;
}

// ---------------------------------------------------------------------------------------------
// Expressions

struct GX { opc: i64, comm: bool, ty: i32, args: i32, nargs: i32, attrs: i32, hash: u64, num: i64, chain: i32 }
var gx: GX[>..<];
var gx_args: i64[>..<];
var gx_bk: i32[>..];       // bucket -> first record; chains in insertion order (gx_tail for appends)
var gx_tail: i32[>..];
var gx_count: i64 = 0;
var gvs: i64[>..<];        // VarArgs of expressions under construction

// an expression under construction: VarArgs = gvs[mark..]
struct GE { opc: i64, comm: bool, ty: i32, attrs: i32, mark: i64 }

fn ge_new(opc: i64, ty: i32) -> GE { GE { opc: opc, comm: false, ty: ty, attrs: 0, mark: gvs.len } }
fn ge_nargs(e: GE) -> i64 { gvs.len - e.mark }

fn gx_hash(e: GE) -> u64 {
    var h: u64 = 0xcbf29ce484222325;
    h = (h ^ (e.opc as u64)) * 0x100000001b3;
    h = (h ^ ((e.ty as i64) as u64)) * 0x100000001b3;
    for k in e.mark..gvs.len { h = (h ^ (gvs[k] as u64)) * 0x100000001b3; }
    return h ^ (h >> 31);
}

fn gx_alist_empty(l: i32) -> bool { alists[l].n == 0 }

// Expression::operator==
fn gx_equal(r: i32, e: GE) -> bool {
    let x = gx[r];
    if x.opc != e.opc { return false; }
    if x.ty != e.ty { return false; }
    if (x.nargs as i64) != ge_nargs(e) { return false; }
    for k in x.nargs { if gx_args[x.args + k] != gvs[e.mark + k] { return false; } }
    if !gx_alist_empty(x.attrs) || !gx_alist_empty(e.attrs) {
        let ok, l = ii_alist_intersect(x.attrs, e.attrs);
        if !ok { return false; }
    }
    return true;
}

fn gx_clear() {
    gx.clear();
    gx_args.clear();
    gx_bk.resize(0);
    gx_tail.resize(0);
    gx_count = 0;
}

fn gx_link(r: i32) {
    let mask = gx_bk.len - 1;
    let b = (gx[r].hash as! i64) & mask;
    gx[r].chain = -1;
    if gx_bk[b] < 0 { gx_bk[b] = r; } else { gx[gx_tail[b]].chain = r; }
    gx_tail[b] = r;
}
fn gx_grow() {
    var n: i64 = 64;
    while n < gx_count * 2 { n *= 2; }
    gx_bk.resize(0);
    gx_bk.resize(n, -1);
    gx_tail.resize(0);
    gx_tail.resize(n, -1);
    for r in gx.len { if gx[r].num >= 0 { gx_link(r as i32); } }
}

// ExpressionNumbering.find(Exp): the record or -1
fn gx_find(e: GE) -> i32, u64 {
    let h = gx_hash(e);
    if gx_bk.len == 0 { return -1, h; }
    let mask = gx_bk.len - 1;
    var r = gx_bk[(h as! i64) & mask];
    while r >= 0 {
        if gx[r].hash == h && gx_equal(r, e) { return r, h; }
        r = gx[r].chain;
    }
    return -1, h;
}
// ExpressionNumbering[Exp]: the record (inserted with number 0 when absent); a record copies e's VarArgs
fn gx_get(e: GE) -> i32 {
    let r, h = gx_find(e);
    if r >= 0 { return r; }
    let nr = gx_store(e, h);
    gx[nr].num = 0;
    gx_count++;
    if gx_count * 4 > gx_bk.len * 3 { gx_grow(); } else { gx_link(nr); }
    return nr;
}
// a record holding a copy of e (not in the table: num = -1)
fn gx_store(e: GE, h: u64) -> i32 {
    let at = gx_args.len as i32;
    for k in e.mark..gvs.len { let x = gvs[k]; gx_args.push(x); }
    let r = gx.len as i32;
    gx.push(GX { opc: e.opc, comm: e.comm, ty: e.ty, args: at, nargs: (gvs.len - e.mark) as i32, attrs: e.attrs, hash: h, num: -1, chain: -1 });
    return r;
}

// ---------------------------------------------------------------------------------------------
// ValueTable

var vn_map = hm_new();          // ValueNumbering
var vn_phi = hm_new();          // NumberingPhi
var vn_bb = hm_new();           // NumberingBB
var vn_ptt = hm_new();          // PhiTranslateTable: (Num, Pred) -> Num
var vn_next: i64 = 1;           // NextValueNumber
var vn_exprs: i32[>..<];        // Expressions (record ids)
var vn_expr_idx: i64[>..<];     // ExprIdx
var vn_next_expr: i64 = 0;

fn vk(v: i32) -> u64 { (v as i64) as u64 }

fn vn_clear() {
    hm_clear(vn_map);
    gx_clear();
    hm_clear(vn_phi);
    hm_clear(vn_bb);
    hm_clear(vn_ptt);
    vn_next = 1;
    vn_exprs.clear();
    vn_expr_idx.clear();
    vn_next_expr = 0;
}

fn vn_set(v: i32, n: i64) { hm_put(vn_map, vk(v), n); }
fn vn_new_num(v: i32) -> i64 { vn_set(v, vn_next); vn_next++; return vn_next - 1; }

// add(V, Num)
fn vn_add(v: i32, n: i64) {
    if !hm_has(vn_map, vk(v)) { vn_set(v, n); }
    if is_inst_op(v, OP_PHI) { hm_put(vn_phi, n as u64, v as i64); }
}
fn vn_exists(v: i32) -> bool { hm_has(vn_map, vk(v)) }
// lookup(V, Verify)
fn vn_lookup(v: i32) -> i64 {
    let r = hm_get(vn_map, vk(v), -1);
    if r < 0 { fatal("internal: GVN: value not numbered"); }
    return r;
}
fn vn_lookup0(v: i32) -> i64 { let r = hm_get(vn_map, vk(v), -1); return if r < 0 { 0 } else { r }; }
// erase(V)
fn vn_erase(v: i32) {
    let n = vn_lookup0(v);
    hm_del(vn_map, vk(v));
    if is_inst_op(v, OP_PHI) { hm_del(vn_phi, n as u64); }
    else if vals[v].kind == VK_BLOCK { hm_del(vn_bb, n as u64); }
}

// assignExpNewValueNum(Exp): (number, created); truncates gvs to e.mark
fn vn_assign_exp(e: GE) -> i64, bool {
    let r = gx_get(e);
    gvs.resize(e.mark);
    if gx[r].num != 0 { return gx[r].num, false; }
    vn_exprs.push(r);
    if (vn_expr_idx.len as i64) < vn_next + 1 { vn_expr_idx.resize(vn_next * 2, 0); }
    gx[r].num = vn_next;
    vn_expr_idx[vn_next] = vn_next_expr;
    vn_next_expr++;
    vn_next++;
    return gx[r].num, true;
}

fn gvn_swap_args(e: GE) { let t = gvs[e.mark]; gvs[e.mark] = gvs[e.mark + 1]; gvs[e.mark + 1] = t; }

// createExpr(I)
recursive fn vn_create_expr(i: i32) -> GE {
    var e = ge_new(iop(i), vals[i].ty);
    if inst_iid(i) == IID_experimental_gc_relocate {
        let a = vn_lookup_or_add(op(i, 0));
        gvs.push(a);
        let b = vn_lookup_or_add(gvn_gc_relocate_ptr(i, 1));
        gvs.push(b);
        let c = vn_lookup_or_add(gvn_gc_relocate_ptr(i, 2));
        gvs.push(c);
    } else {
        for k in nops(i) { let x = vn_lookup_or_add(op(i, k)); gvs.push(x); }
    }
    if ii_is_commutative(i) {
        if gvs[e.mark] > gvs[e.mark + 1] { gvn_swap_args(e); }
        e.comm = true;
    }
    let o = iop(i);
    if o == OP_ICMP || o == OP_FCMP {
        var p = inst_pred(i) as i64;
        if gvs[e.mark] > gvs[e.mark + 1] {
            gvn_swap_args(e);
            p = pred_swap_any(p);
        }
        e.opc = (o << 8) | p;
        e.comm = true;
    } else if o == OP_INSERTVALUE {
        let x = insts[inst_of(i)];
        for k in x.naux { gvs.push((ints[x.aux + k] as u32) as i64); }
    } else if o == OP_SHUFFLEVECTOR {
        let x = insts[inst_of(i)];
        for k in x.naux { gvs.push((ints[x.aux + k] as! u32) as i64); }
    } else if is_callbase(i) {
        e.attrs = insts[inst_of(i)].attrs;
    }
    return e;
}

// GCRelocateInst::getBasePtr (k = 1) / getDerivedPtr (k = 2)
fn gvn_gc_relocate_ptr(i: i32, k: i64) -> i32 {
    let tok = op(i, 0);
    if !is_inst_op(tok, OP_CALL) && !is_inst_op(tok, OP_INVOKE) { gvn_not_ported("gc.relocate of a landingpad token"); }
    let idx = cint_lo(op(i, k)) as! i64;
    for b in cb_nbundles(tok) {
        if sbytes(cb_bundle_tag(tok, b)) == "gc-live" { return op(tok, cb_bundle_begin(tok, b) + idx); }
    }
    return cb_arg(tok, idx);
}

// createCmpExpr(Opcode, Predicate, LHS, RHS)
recursive fn vn_create_cmp_expr(o: i64, p0: i64, l: i32, r: i32) -> GE {
    var e = ge_new(o, cmp_result_ty(vals[l].ty));
    let a = vn_lookup_or_add(l);
    gvs.push(a);
    let b = vn_lookup_or_add(r);
    gvs.push(b);
    var p = p0;
    if gvs[e.mark] > gvs[e.mark + 1] { gvn_swap_args(e); p = pred_swap_any(p); }
    e.opc = (o << 8) | p;
    e.comm = true;
    return e;
}

fn gvn_wo_binop(id: i32) -> i64 {
    if id == IID_sadd_with_overflow || id == IID_uadd_with_overflow { return OP_ADD; }
    if id == IID_ssub_with_overflow || id == IID_usub_with_overflow { return OP_SUB; }
    if id == IID_smul_with_overflow || id == IID_umul_with_overflow { return OP_MUL; }
    return -1;
}

// createExtractvalueExpr(EI)
recursive fn vn_create_extractvalue_expr(ei: i32) -> GE {
    var e = ge_new(0, vals[ei].ty);
    let agg = op(ei, 0);
    let x = insts[inst_of(ei)];
    let wo = if is_inst_op(agg, OP_CALL) { gvn_wo_binop(call_iid(agg)) } else { -1 };
    if wo >= 0 && x.naux == 1 && ints[x.aux] == 0 {
        e.opc = wo;
        let a = vn_lookup_or_add(cb_arg(agg, 0));
        gvs.push(a);
        let b = vn_lookup_or_add(cb_arg(agg, 1));
        gvs.push(b);
        return e;
    }
    e.opc = OP_EXTRACTVALUE;
    for k in nops(ei) { let y = vn_lookup_or_add(op(ei, k)); gvs.push(y); }
    for k in x.naux { gvs.push((ints[x.aux + k] as u32) as i64); }
    return e;
}

// GEPOperator::collectOffset(DL, BitWidth, VariableOffsets, ConstantOffset): false when it fails; the variable
// offsets (MapVector order) in gco_vals/gco_scale, the constant offset in gco_const (index width, masked)
var gco_vals: i32[>..<];
var gco_scale: u64[>..<];
var gco_const: u64 = 0;
fn gvn_collect_offset(g: i32, w: i64) -> bool {
    gco_vals.clear();
    gco_scale.clear();
    gco_const = 0;
    let mask: u64 = if w == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (w as u64)) - 1 };
    let src = insts[inst_of(g)].ty2;
    var t = src;
    for k in 1..nops(g) {
        let x = op(g, k);
        var indexed = t;
        var stride: i64 = 0;
        var is_struct = false;
        if k == 1 { indexed = src; stride = dl_alloc_size(src); }
        else if ty_is_struct(t) {
            if vals[x].kind != VK_CINT || ty_kind(vals[x].ty) != TK_INT { return false; }
            is_struct = true;
            indexed = ty_field(t, cint_lo(x) as! i64);
        }
        else { indexed = types[t].a; stride = dl_gep_stride(t, indexed); }
        let scalable = vnc_is_scalable_ty(indexed);
        let is_ci = vals[x].kind == VK_CINT && ty_kind(vals[x].ty) == TK_INT;
        if is_ci {
            if cint_is_zero(x) { t = indexed; continue; }
            if scalable { return false; }
            if ty_bits(vals[x].ty) > 64 { gvn_not_ported("GEP indices wider than 64 bits"); }
            if is_struct {
                gco_const = (gco_const + ((dl_struct_offset(t, cint_lo(x) as! i64) as! u64) & mask)) & mask;
            } else {
                gco_const = (gco_const + ((ci_sval(x) as! u64) & mask) * ((stride as! u64) & mask)) & mask;
            }
            t = indexed;
            continue;
        }
        if is_struct || scalable { return false; }
        let sz = (stride as! u64) & mask;
        if sz != 0 {
            var found: i64 = -1;
            for j in gco_vals.len { if gco_vals[j] == x { found = j; } }
            if found < 0 { gco_vals.push(x); gco_scale.push(0); found = gco_vals.len - 1; }
            gco_scale[found] = (gco_scale[found] + sz) & mask;
        }
        t = indexed;
    }
    return true;
}

// createGEPExpr(GEP)
recursive fn vn_create_gep_expr(g: i32) -> GE {
    let w = dl_ptr(ptr_as(ty_scalar(vals[g].ty))).idx;
    if w > 64 { gvn_not_ported("GEP index widths over 64 bits"); }
    var e = ge_new(OP_GEP, -1);
    if gvn_collect_offset(g, w) {
        // copy the offsets: the numbering below may collect offsets of other GEPs
        let nv = gco_vals.len;
        let cst = gco_const;
        let base = gvs_tmp.len;
        for j in nv { gvs_tmp.push(gco_vals[j] as i64); gvs_tmp.push(gco_scale[j] as i64); }
        let p = vn_lookup_or_add(op(g, 0));
        gvs.push(p);
        let it = ty_int(w);
        for j in nv {
            let a = vn_lookup_or_add(gvs_tmp[base + 2 * j] as i32);
            gvs.push(a);
            let b = vn_lookup_or_add(c_int_ty(it, gvs_tmp[base + 2 * j + 1] as u64));
            gvs.push(b);
        }
        if cst != 0 {
            let c = vn_lookup_or_add(c_int_ty(it, cst));
            gvs.push(c);
        }
        gvs_tmp.resize(base);
    } else {
        e.ty = insts[inst_of(g)].ty2;
        for k in nops(g) { let x = vn_lookup_or_add(op(g, k)); gvs.push(x); }
    }
    return e;
}
var gvs_tmp: i64[>..<];

// addMemoryStateToExp(I, Exp)
recursive fn vn_add_memory_state(i: i32) {
    let ma = mssa_access_of(i);
    if ma < 0 { fatal("internal: GVN: instruction does not access memory"); }
    let q = aq_push(CA_SIMPLE);
    cw_limit = mssa_max_check_limit();
    let c = mssa_clobbering_access(ma, q, true, true);
    aq_pop(q);
    let n = vn_lookup_or_add_ma(c);
    gvs.push(n);
}

// lookupOrAdd(MemoryAccess *)
recursive fn vn_lookup_or_add_ma(ma: i32) -> i64 {
    if mssa_is_live(ma) || macc[ma].kind == MAK_PHI { return vn_lookup_or_add(macc[ma].bb); }
    return vn_lookup_or_add(macc[ma].inst);
}

fn gvn_call_args_equal(c: i32, d: i32) -> bool { true }

// lookupOrAddCall(C)
recursive fn vn_lookup_or_add_call(c: i32) -> i64 {
    if func_has_fn_attr(gv_fn, AK_PresplitCoroutine) { return vn_new_num(c); }
    if call_has_fn_attr(c, AK_Convergent) { return vn_new_num(c); }
    let me = aa_call_me_simple(c);
    if me_none(me) {
        let e = vn_create_expr(c);
        let n, created = vn_assign_exp(e);
        vn_set(c, n);
        return n;
    }
    if gv_md && me_only_reads(me) {
        let e = vn_create_expr(c);
        let n, created = vn_assign_exp(e);
        if created { vn_set(c, n); return n; }
        let ld = mdep_get_dependency(c);
        if ld.k != MDR_DEF && ld.k != MDR_NONLOCAL { return vn_new_num(c); }
        if ld.k == MDR_DEF {
            let dc = ld.i;
            if !is_inst_op(dc, OP_CALL) || cb_nargs(dc) != cb_nargs(c) { return vn_new_num(c); }
            for k in cb_nargs(c) {
                let a = vn_lookup_or_add(cb_arg(c, k));
                let b = vn_lookup_or_add(cb_arg(dc, k));
                if a != b { return vn_new_num(c); }
            }
            let v = vn_lookup_or_add(dc);
            vn_set(c, v);
            return v;
        }
        let deps = mdep_nonlocal_call_dependency(c);
        var cdep: i32 = -1;
        for k in mv_len(deps) {
            let d = md_ents[mv_at(deps, k)];
            if d.r.k == MDR_NONLOCAL { continue; }
            if d.r.k != MDR_DEF || cdep >= 0 { cdep = -1; break; }
            let nlc = d.r.i;
            if is_inst_op(nlc, OP_CALL) && dt_properly_dominates_block(DT_DOM, d.bb, inst_parent(c)) { cdep = nlc; continue; }
            cdep = -1;
            break;
        }
        if cdep < 0 { return vn_new_num(c); }
        if cb_nargs(cdep) != cb_nargs(c) { return vn_new_num(c); }
        for k in cb_nargs(c) {
            let a = vn_lookup_or_add(cb_arg(c, k));
            let b = vn_lookup_or_add(cb_arg(cdep, k));
            if a != b { return vn_new_num(c); }
        }
        let v = vn_lookup_or_add(cdep);
        vn_set(c, v);
        return v;
    }
    if gv_mssa && gv_mssa_enabled && me_only_reads(me) {
        let e = vn_create_expr(c);
        vn_add_memory_state(c);
        let v, created = vn_assign_exp(e);
        vn_set(c, v);
        return v;
    }
    return vn_new_num(c);
}

// computeLoadStoreVN(I)
recursive fn vn_compute_load_store(i: i32) -> i64 {
    if !gv_mssa || !gv_mssa_enabled { return vn_new_num(i); }
    let e = ge_new(iop(i), vals[i].ty);
    for k in nops(i) { let x = vn_lookup_or_add(op(i, k)); gvs.push(x); }
    vn_add_memory_state(i);
    let v, created = vn_assign_exp(e);
    vn_set(i, v);
    return v;
}

fn gvn_expr_opcode(o: i64) -> bool {
    return o == OP_FNEG || o == OP_ADD || o == OP_FADD || o == OP_SUB || o == OP_FSUB || o == OP_MUL || o == OP_FMUL ||
        o == OP_UDIV || o == OP_SDIV || o == OP_FDIV || o == OP_UREM || o == OP_SREM || o == OP_FREM || o == OP_SHL ||
        o == OP_LSHR || o == OP_ASHR || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_ICMP || o == OP_FCMP ||
        o == OP_TRUNC || o == OP_ZEXT || o == OP_SEXT || o == OP_FPTOUI || o == OP_FPTOSI || o == OP_UITOFP ||
        o == OP_SITOFP || o == OP_FPTRUNC || o == OP_FPEXT || o == OP_PTRTOINT || o == OP_PTRTOADDR || o == OP_INTTOPTR ||
        o == OP_ADDRSPACECAST || o == OP_BITCAST || o == OP_SELECT || o == OP_FREEZE || o == OP_EXTRACTELEMENT ||
        o == OP_INSERTELEMENT || o == OP_SHUFFLEVECTOR || o == OP_INSERTVALUE;
}

// lookupOrAdd(V)
recursive fn vn_lookup_or_add(v: i32) -> i64 {
    let f = hm_get(vn_map, vk(v), -1);
    if f >= 0 { return f; }
    if !is_inst(v) {
        let n = vn_new_num(v);
        if vals[v].kind == VK_BLOCK { hm_put(vn_bb, n as u64, v as i64); }
        return n;
    }
    let o = iop(v);
    var e = ge_new(0, -1);
    if o == OP_CALL { return vn_lookup_or_add_call(v); }
    if gvn_expr_opcode(o) { e = vn_create_expr(v); }
    else if o == OP_GEP { e = vn_create_gep_expr(v); }
    else if o == OP_EXTRACTVALUE { e = vn_create_extractvalue_expr(v); }
    else if o == OP_PHI {
        let n = vn_new_num(v);
        hm_put(vn_phi, n as u64, v as i64);
        return n;
    }
    else if o == OP_LOAD || o == OP_STORE { return vn_compute_load_store(v); }
    else { return vn_new_num(v); }
    let n, created = vn_assign_exp(e);
    vn_set(v, n);
    return n;
}

// lookupOrAddCmp(Opcode, Pred, LHS, RHS)
fn vn_lookup_or_add_cmp(o: i64, p: i64, l: i32, r: i32) -> i64 {
    let e = vn_create_cmp_expr(o, p, l, r);
    let n, created = vn_assign_exp(e);
    return n;
}

// lookupPtrToInt(Ptr, Ty)
fn vn_lookup_ptrtoint(p: i32, ty: i32) -> i64 {
    let e = ge_new(OP_PTRTOINT, ty);
    let x = vn_lookup_or_add(p);
    gvs.push(x);
    let r, h = gx_find(e);
    gvs.resize(e.mark);
    if r < 0 { return 0; }
    return gx[r].num;
}

// areAllValsInBB(Num, BB)
fn vn_all_vals_in_bb(num: i64, bb: i32) -> bool {
    var n = lt_head(num);
    while n >= 0 {
        if lt_nodes[n].bb != bb { return false; }
        n = lt_nodes[n].next;
    }
    return true;
}

// phiTranslate(Pred, PhiBlock, Num)
recursive fn vn_phi_translate(pred: i32, phib: i32, num: i64) -> i64 {
    let key = hk2(num as i32, pred);
    let f = hm_get(vn_ptt, key, -1);
    if f >= 0 { return f; }
    let nn = vn_phi_translate_impl(pred, phib, num);
    if !hm_has(vn_ptt, key) { hm_put(vn_ptt, key, nn); }
    return nn;
}

// areCallValsEqual(Num, NewNum, Pred, PhiBlock)
fn vn_call_vals_equal(num: i64, pred: i32, phib: i32) -> bool {
    var call: i32 = -1;
    var n = lt_head(num);
    while n >= 0 {
        let v = lt_nodes[n].val;
        call = if is_inst_op(v, OP_CALL) { v } else { -1 };
        if call >= 0 && inst_parent(call) == phib { break; }
        n = lt_nodes[n].next;
    }
    if call < 0 { fatal("internal: GVN: areCallValsEqual without a call leader"); }
    let me = aa_call_me_simple(call);
    if me_none(me) { return true; }
    if !gv_md || !me_only_reads(me) { return false; }
    let ld = mdep_get_dependency(call);
    if ld.k != MDR_NONLOCAL { return false; }
    let deps = mdep_nonlocal_call_dependency(call);
    for k in mv_len(deps) {
        if md_ents[mv_at(deps, k)].r.k == MDR_NONFUNCLOCAL { return true; }
    }
    return false;
}

// phiTranslateImpl(Pred, PhiBlock, Num)
recursive fn vn_phi_translate_impl(pred: i32, phib: i32, num: i64) -> i64 {
    let pn = hm_get(vn_phi, num as u64, -1) as i32;
    if pn >= 0 {
        if inst_parent(pn) != phib { return num; }
        for k in nops(pn) {
            if phi_block(pn, k) != pred { continue; }
            let tv = vn_lookup0(op(pn, k));
            if tv != 0 { return tv; }
        }
        return num;
    }
    let bb = hm_get(vn_bb, num as u64, -1) as i32;
    if bb >= 0 {
        if bb != phib { return num; }
        let mphi = mssa_access_of(bb);
        for k in mphi_n(mphi) {
            if mphi_blk(mphi, k) != pred { continue; }
            let ma = mphi_val(mphi, k);
            if macc[ma].kind == MAK_PHI { return vn_lookup_or_add(macc[ma].bb); }
            if mssa_is_live(ma) { return vn_lookup_or_add(func_entry(block_func(bb))); }
            return vn_lookup_or_add(macc[ma].inst);
        }
        fatal("internal: GVN: CFG/MemorySSA mismatch: predecessor not found among incoming blocks");
    }
    if !vn_all_vals_in_bb(num, phib) { return num; }
    if num >= (vn_expr_idx.len as i64) || vn_expr_idx[num] == 0 { return num; }
    let r = vn_exprs[vn_expr_idx[num]];
    var e = GE { opc: gx[r].opc, comm: gx[r].comm, ty: gx[r].ty, attrs: gx[r].attrs, mark: gvs.len };
    for k in gx[r].nargs { let x = gx_args[gx[r].args + k]; gvs.push(x); }
    let na = ge_nargs(e);
    for k in na {
        if (k > 1 && e.opc == OP_INSERTVALUE) || (k > 0 && e.opc == OP_EXTRACTVALUE) || (k > 1 && e.opc == OP_SHUFFLEVECTOR) { continue; }
        let t = vn_phi_translate(pred, phib, gvs[e.mark + k]);
        gvs[e.mark + k] = t;
    }
    if e.comm {
        if gvs[e.mark] > gvs[e.mark + 1] {
            gvn_swap_args(e);
            let o = e.opc >> 8;
            if o == OP_ICMP || o == OP_FCMP { e.opc = (o << 8) | pred_swap_any(e.opc & 255); }
        }
    }
    let rr = gx_get(e);
    gvs.resize(e.mark);
    let nn = gx[rr].num;
    if nn != 0 {
        if e.opc == OP_CALL && nn != num { return if vn_call_vals_equal(num, pred, phib) { nn } else { num }; }
        return nn;
    }
    return num;
}

// eraseTranslateCacheEntry(Num, CurrBlock)
fn vn_erase_translate_cache_entry(num: i64, bb: i32) {
    each_pred(bb) { p => hm_del(vn_ptt, hk2(num as i32, p)); };
}

// ---------------------------------------------------------------------------------------------
// LeaderMap: num -> head node; insert puts the new entry second (after the head)

struct LTNode { val: i32, bb: i32, next: i32 }
var lt_nodes: LTNode[>..<];
var lt_free: i32[>..<];
var lt_map = hm_new();

fn lt_clear() { lt_nodes.clear(); lt_free.clear(); hm_clear(lt_map); }
fn lt_head(num: i64) -> i32 { hm_get(lt_map, num as u64, -1) as i32 }
fn lt_alloc(v: i32, bb: i32, next: i32) -> i32 {
    if lt_free.len > 0 { let n = lt_free.pop(); lt_nodes[n] = LTNode { val: v, bb: bb, next: next }; return n; }
    lt_nodes.push(LTNode { val: v, bb: bb, next: next });
    return (lt_nodes.len - 1) as i32;
}
fn lt_insert(num: i64, v: i32, bb: i32) {
    let h = lt_head(num);
    if h < 0 { let n = lt_alloc(v, bb, -1); hm_put(lt_map, num as u64, n as i64); return; }
    let n = lt_alloc(v, bb, lt_nodes[h].next);
    lt_nodes[h].next = n;
}
fn lt_erase(num: i64, v: i32, bb: i32) {
    let h = lt_head(num);
    if h < 0 { return; }
    var prev: i32 = -1;
    var cur = h;
    while cur >= 0 && (lt_nodes[cur].val != v || lt_nodes[cur].bb != bb) { prev = cur; cur = lt_nodes[cur].next; }
    if cur < 0 { return; }
    if prev >= 0 {
        lt_nodes[prev].next = lt_nodes[cur].next;
        lt_free.push(cur);
    } else {
        let nx = lt_nodes[cur].next;
        if nx < 0 { hm_del(lt_map, num as u64); lt_free.push(cur); }
        else {
            lt_nodes[cur] = lt_nodes[nx];
            lt_free.push(nx);
        }
    }
}

// findLeader(BB, Num)
fn gvn_find_leader(bb: i32, num: i64) -> i32 {
    var n = lt_head(num);
    if n < 0 { return -1; }
    var val: i32 = -1;
    while n >= 0 {
        let e = lt_nodes[n];
        if dt_dominates_block(DT_DOM, e.bb, bb) {
            val = e.val;
            if is_constant(val) { return val; }
        }
        n = e.next;
    }
    return val;
}

// ---------------------------------------------------------------------------------------------
// ImplicitControlFlowTracking (mustexec.goose's FirstSpecialInsts cache for the ICF tracker)

fn icf_clear() { lsi_icf_epoch++; }
fn icf_dominated_by_icfi_from_same_block(i: i32) -> bool { icf_preceded(i) }
fn icf_has_icf(bb: i32) -> bool { icf_first_special(bb) >= 0 }
fn icf_insert_instruction_to(i: i32, bb: i32) { lsi_insert_instruction_to(i, bb); }
fn icf_remove_instruction(i: i32) { lsi_remove_instruction(i); }
fn icf_remove_users_of(i: i32) {
    var u = vals[i].first_use;
    while u >= 0 {
        let x = uses[u].user;
        if is_inst(x) { lsi_remove_instruction(x); }
        u = uses[u].next;
    }
}

// ---------------------------------------------------------------------------------------------
// Traversal orders

var gv_bstamp: i64[>..];
var gv_bepoch: i64 = 0;
fn gv_bmark_clear() { gv_bepoch++; }
fn gv_bmark(bb: i32) -> bool {
    let k = block_number(bb) as i64;
    while gv_bstamp.len <= k { gv_bstamp.push(0); }
    if gv_bstamp[k] == gv_bepoch { return false; }
    gv_bstamp[k] = gv_bepoch;
    return true;
}

// ReversePostOrderTraversal<Function *>
fn gvn_rpo(fv: i32, out: i32[>..<]&) {
    out.clear();
    gv_bmark_clear();
    var stk: i32[>..<] = [];
    var idx: i64[>..<] = [];
    let entry = func_entry(fv);
    gv_bmark(entry);
    stk.push(entry);
    idx.push(0);
    var po: i32[>..<] = [];
    while stk.len > 0 {
        let t = stk.len - 1;
        let bb = stk[t];
        if idx[t] < block_nsucc(bb) {
            let s = block_succ(bb, idx[t]);
            idx[t]++;
            if gv_bmark(s) { stk.push(s); idx.push(0); }
            continue;
        }
        po.push(bb);
        stk.pop();
        idx.pop();
    }
    var k = po.len - 1;
    while k >= 0 { out.push(po[k]); k--; }
}

// depth_first(&F.getEntryBlock())
fn gvn_dfs(fv: i32, out: i32[>..<]&) {
    out.clear();
    gv_bmark_clear();
    var stk: i32[>..<] = [];
    var idx: i64[>..<] = [];
    let entry = func_entry(fv);
    gv_bmark(entry);
    out.push(entry);
    stk.push(entry);
    idx.push(0);
    while stk.len > 0 {
        let t = stk.len - 1;
        let bb = stk[t];
        var pushed = false;
        while idx[t] < block_nsucc(bb) {
            let s = block_succ(bb, idx[t]);
            idx[t]++;
            if gv_bmark(s) { out.push(s); stk.push(s); idx.push(0); pushed = true; break; }
        }
        if !pushed { stk.pop(); idx.pop(); }
    }
}

// ---------------------------------------------------------------------------------------------
// MergeBlockIntoPredecessor(BB, &DTU (lazy), &LI, MSSAU, MD)

fn gvn_fold_single_entry_phis(bb: i32) {
    loop {
        let pn = block_first(bb);
        if pn < 0 || iop(pn) != OP_PHI { break; }
        let v = phi_value(pn, 0);
        if v != pn { gvn_rauw(pn, v); } else { gvn_rauw(pn, c_poison(vals[pn].ty)); }
        if gv_md { mdep_remove_instruction(pn); }
        inst_erase_from_parent(pn);
    }
}

fn gvn_merge_block_into_predecessor(bb: i32) -> bool {
    if cu_has_address_taken(bb) { return false; }
    let pred = cu_unique_pred(bb);
    if pred < 0 { return false; }
    if pred == bb { return false; }
    let pti = block_terminator(pred);
    if cu_is_special_terminator(pti) || inst_may_have_side_effects(pti) { return false; }
    if cu_unique_succ(pred) != bb { return false; }
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        for k in nops(i) { if op(i, k) == i { return false; } }
        i = inst_next(i);
    }
    if cu_has_loop_or_entry_convergence_token(bb) && cu_has_loop_or_entry_convergence_token(pred) { return false; }
    if cu_has_phis(bb) { gvn_fold_single_entry_phis(bb); }
    var ups: DTUpdate[>..<] = [];
    var seen: i32[>..<] = [];
    var succs_of_pred: i32[>..<] = [];
    cu_succs(pred, succs_of_pred);
    var succs: i32[>..<] = [];
    cu_succs(bb, succs);
    for s in succs { if position(succs_of_pred, s) < 0 && cu_push_unique(seen, s) { cu_upd(ups, DT_INSERT, pred, s); } }
    seen.clear();
    for s in succs { if cu_push_unique(seen, s) { cu_upd(ups, DT_DELETE, bb, s); } }
    cu_upd(ups, DT_DELETE, pred, bb);
    let sti = block_terminator(bb);
    var start = block_first(bb);
    if start == sti { start = pti; }
    block_splice(pred, pti, false, bb, block_first(bb), true, sti, false);
    if gv_mssa { msu_move_all_after_merge_blocks(bb, pred, start); }
    cu_block_rauw(bb, pred);
    inst_erase_from_parent(pti);
    inst_move_impl(sti, pred, -1, false, true);
    block_append_inst(bb, create_inst(OP_UNREACHABLE, T_VOID, []));
    if gv_mssa {
        let t = block_terminator(pred);
        let mud = mssa_access_of(t);
        if mud >= 0 { msu_move_to_place(mud, pred, MSP_END); }
    }
    if vals[pred].name < 0 && vals[bb].name >= 0 { cu_take_name(pred, bb); }
    li_remove_block(bb);
    if gv_md { mdep_invalidate_cached_predecessors(); }
    dtu_apply_updates(ups);
    cu_dtu = true;
    cu_delete_dead_block(bb);
    cu_dtu = false;
    return true;
}

// ---------------------------------------------------------------------------------------------
// AvailableValue / AvailableValueInBlock

let AV_SIMPLE: i32 = 0;
let AV_LOAD: i32 = 1;
let AV_MEMINTRIN: i32 = 2;
let AV_UNDEF: i32 = 3;
let AV_SELECT: i32 = 4;
struct AV { kind: i32, val: i32, off: i64, v1: i32, v2: i32 }
struct AVB { bb: i32, av: AV }
fn av_simple(v: i32, off: i64) -> AV { AV { kind: AV_SIMPLE, val: v, off: off, v1: -1, v2: -1 } }
fn av_none() -> AV { AV { kind: -1, val: -1, off: 0, v1: -1, v2: -1 } }

// DepKind / ReachingMemVal
let DK_OTHER: i32 = 0;
let DK_DEF: i32 = 1;
let DK_CLOBBER: i32 = 2;
let DK_SELECT: i32 = 3;
struct RMV { kind: i32, bb: i32, addr: i32, inst: i32, off: i64, cond: i32, ta: i32, fa: i32 }
fn rmv_unknown(bb: i32, addr: i32, inst: i32) -> RMV { RMV { kind: DK_OTHER, bb: bb, addr: addr, inst: inst, off: -1, cond: -1, ta: -1, fa: -1 } }
fn rmv_def(addr: i32, inst: i32) -> RMV { RMV { kind: DK_DEF, bb: inst_parent(inst), addr: addr, inst: inst, off: -1, cond: -1, ta: -1, fa: -1 } }
fn rmv_clobber(addr: i32, inst: i32, off: i64) -> RMV { RMV { kind: DK_CLOBBER, bb: inst_parent(inst), addr: addr, inst: inst, off: off, cond: -1, ta: -1, fa: -1 } }
fn rmv_select(bb: i32, c: i32, t: i32, f: i32) -> RMV { RMV { kind: DK_SELECT, bb: bb, addr: -1, inst: -1, off: -1, cond: c, ta: t, fa: f } }
fn rmv_none() -> RMV { RMV { kind: -1, bb: -1, addr: -1, inst: -1, off: -1, cond: -1, ta: -1, fa: -1 } }

fn gvn_copy_dbg_loc(dst: i32, src: i32) {
    let d = inst_get_md(src, 0);
    if d >= 0 { inst_set_md(dst, 0, d); } else { inst_erase_md(dst, 0); }
}

// Instruction::dropUnknownNonDebugMetadata(KnownIDs)
fn gvn_drop_unknown_md(i: i32, keep: const i32[:]) {
    var kinds: i32[>..<] = [];
    let ii = inst_of(i);
    for x in insts[ii].nmd {
        let kind = md_att[insts[ii].md + 2 * x];
        if kind == 0 { continue; }
        var known = false;
        for k in keep { if k == kind { known = true; } }
        if !known { kinds.push(kind); }
    }
    for k in kinds { inst_erase_md(i, k); }
}

// AvailableValue::MaterializeAdjustedValue(Load, InsertPt)
fn av_materialize(a: AV, load: i32, insert_pt: i32) -> i32 {
    let lty: i32 = vals[load].ty;
    if a.kind == AV_SIMPLE {
        var res = a.val;
        if vals[res].ty != lty { res = vnc_get_value_for_load(res, a.off, lty, insert_pt, inst_func(load)); }
        return res;
    }
    if a.kind == AV_LOAD {
        let cl = a.val;
        if vals[cl].ty == lty && a.off == 0 {
            cu_combine_metadata(cl, load, false, false);
            return cl;
        }
        let res = vnc_get_value_for_load(cl, a.off, lty, insert_pt, inst_func(load));
        if inst_get_md(cl, md_kind_id("noundef")) < 0 {
            let keep: i32[6] = [MDK_DEREFERENCEABLE, MDK_DEREFERENCEABLE_OR_NULL, MDK_INVARIANT_LOAD, MDK_INVARIANT_GROUP, MDK_ALIAS_SCOPE, MDK_NOALIAS];
            gvn_drop_unknown_md(cl, keep);
        }
        return res;
    }
    if a.kind == AV_MEMINTRIN {
        let r = vnc_get_mem_inst_value_for_load(a.val, a.off, lty, insert_pt);
        if r < 0 { fatal("internal: GVN: failed to materialize a memory intrinsic value"); }
        return r;
    }
    if a.kind == AV_SELECT {
        let s = create_inst(OP_SELECT, vals[a.v1].ty, [a.val, a.v1, a.v2]);
        inst_insert_before(s, insert_pt);
        gvn_copy_dbg_loc(s, load);
        return s;
    }
    fatal("internal: GVN: should not materialize value from dead block");
    return -1;
}
fn avb_materialize(b: AVB, load: i32) -> i32 { av_materialize(b.av, load, block_terminator(b.bb)) }

// replaceValuesPerBlockEntry
fn gvn_replace_values_per_block(vpb: AVB[>..<]&, old: i32, nw: i32) {
    for k in vpb.len {
        if vpb[k].av.val == old { vpb[k].av.val = nw; }
        if vpb[k].av.kind == AV_SELECT {
            if vpb[k].av.v1 == old { vpb[k].av.v1 = nw; }
            if vpb[k].av.v2 == old { vpb[k].av.v2 = nw; }
        }
    }
}

// ConstructSSAForLoadSet(Load, ValuesPerBlock, GVN)
fn gvn_construct_ssa_for_load_set(load: i32, vpb: AVB[>..<]&) -> i32 {
    if vpb.len == 1 && dt_properly_dominates_block(DT_DOM, vpb[0].bb, inst_parent(load)) {
        return avb_materialize(vpb[0], load);
    }
    var nm: u8[>..] = [];
    nm.append(val_name(load));
    ssa_init(vals[load].ty, nm);
    for k in vpb.len {
        let b = vpb[k];
        if b.av.kind == AV_UNDEF { continue; }
        if ssa_has_value_for_block(b.bb) { continue; }
        if b.bb == inst_parent(load) && ((b.av.kind == AV_SIMPLE && b.av.val == load) || (b.av.kind == AV_LOAD && b.av.val == load)) { continue; }
        let v = avb_materialize(b, load);
        ssa_add_available_value(b.bb, v);
    }
    return ssa_get_value_in_middle_of_block(inst_parent(load));
}

// ---------------------------------------------------------------------------------------------
// Load availability

fn gvn_is_atomic(i: i32) -> bool { insts[inst_of(i)].ord != 0 }
fn gvn_atomic_int(i: i32) -> i64 { if gvn_is_atomic(i) { 1 } else { 0 } }

// findDominatingValue(Loc, LoadTy, From, AA)
fn gvn_find_dominating_value(loc: ML, lty: i32, from: i32) -> i32 {
    var nv: i64 = 0;
    let from_bb = inst_parent(from);
    let q = aq_push(CA_SIMPLE);
    var bb = from_bb;
    var res: i32 = -1;
    var done = false;
    while bb >= 0 && !done {
        var inst = if bb == from_bb { from } else { block_terminator(bb) };
        while inst >= 0 {
            nv++;
            if nv > gv_max_visited { done = true; break; }
            if mr_is_mod(aa_inst_loc_mr(inst, loc, q)) {
                if iop(inst) == OP_STORE && insts[inst_of(inst)].ord == 0 && !inst_is_volatile(inst) &&
                   op(inst, 1) == loc.ptr && vals[op(inst, 0)].ty == lty { res = op(inst, 0); }
                done = true;
                break;
            }
            if iop(inst) == OP_LOAD && op(inst, 0) == loc.ptr && vals[inst].ty == lty { res = inst; done = true; break; }
            inst = inst_prev(inst);
        }
        if done { break; }
        bb = single_pred(bb);
    }
    aq_pop(q);
    return res;
}

// AnalyzeSelectAvailability(Load, Cond, TrueAddr, FalseAddr, From)
fn gvn_analyze_select_availability(load: i32, cond: i32, ta: i32, fa: i32, from: i32) -> AV {
    let loc = ml_get(load);
    var l1 = loc;
    l1.ptr = ta;
    let v1 = gvn_find_dominating_value(l1, vals[load].ty, from);
    if v1 < 0 { return av_none(); }
    var l2 = loc;
    l2.ptr = fa;
    let v2 = gvn_find_dominating_value(l2, vals[load].ty, from);
    if v2 < 0 { return av_none(); }
    return AV { kind: AV_SELECT, val: cond, off: 0, v1: v1, v2: v2 };
}

// AnalyzeLoadAvailability(Load, Dep, Address)
fn gvn_analyze_load_availability(load: i32, dep: RMV, address: i32) -> AV {
    let di = dep.inst;
    if dep.kind == DK_CLOBBER {
        if iop(di) == OP_STORE {
            if address >= 0 && gvn_atomic_int(load) <= gvn_atomic_int(di) {
                let off = vnc_analyze_from_store(vals[load].ty, address, di);
                if off != -1 { return av_simple(op(di, 0), off); }
            }
        }
        if iop(di) == OP_LOAD {
            if di != load && address >= 0 && gvn_atomic_int(load) <= gvn_atomic_int(di) {
                let lty: i32 = vals[load].ty;
                var off = dep.off;
                if !gv_mssa_enabled {
                    if vnc_can_coerce(di, lty, inst_func(di)) {
                        let co, has = mdep_clobber_offset(di);
                        off = if !has || co < 0 { -1 } else { co };
                    }
                } else {
                    if !vnc_can_coerce(di, lty, inst_func(di)) || off < 0 { off = -1; }
                }
                if off == -1 { off = vnc_analyze_from_load(lty, address, di); }
                if off != -1 { return AV { kind: AV_LOAD, val: di, off: off, v1: -1, v2: -1 }; }
            }
        }
        if iop(di) == OP_CALL && is_mem_intrinsic_id(call_iid(di)) {
            if address >= 0 && !gvn_is_atomic(load) {
                let off = vnc_analyze_from_mem_inst(vals[load].ty, address, di);
                if off != -1 { return AV { kind: AV_MEMINTRIN, val: di, off: off, v1: -1, v2: -1 }; }
            }
        }
        return av_none();
    }
    if iop(di) == OP_ALLOCA || inst_iid(di) == IID_lifetime_start { return av_simple(c_undef(vals[load].ty), 0); }
    let iv = mb_initial_value_of_allocation(di, vals[load].ty);
    if iv >= 0 { return av_simple(iv, 0); }
    if iop(di) == OP_STORE {
        if !vnc_can_coerce(op(di, 0), vals[load].ty, inst_func(di)) { return av_none(); }
        if gvn_atomic_int(di) < gvn_atomic_int(load) { return av_none(); }
        return av_simple(op(di, 0), 0);
    }
    if iop(di) == OP_LOAD {
        if !vnc_can_coerce(di, vals[load].ty, inst_func(di)) { return av_none(); }
        if gvn_atomic_int(di) < gvn_atomic_int(load) { return av_none(); }
        return AV { kind: AV_LOAD, val: di, off: 0, v1: -1, v2: -1 };
    }
    if iop(di) == OP_SELECT {
        return gvn_analyze_select_availability(load, op(di, 0), op(di, 1), op(di, 2), di);
    }
    return av_none();
}

// AnalyzeLoadAvailability(Load, Deps, ValuesPerBlock, UnavailableBlocks)
fn gvn_analyze_load_availability_all(load: i32, deps: RMV[>..<]&, vpb: AVB[>..<]&, unavail: i32[>..<]&) {
    for d in deps {
        let dbb = d.bb;
        if gvn_is_dead_block(dbb) {
            vpb.push(AVB { bb: dbb, av: AV { kind: AV_UNDEF, val: -1, off: 0, v1: -1, v2: -1 } });
            continue;
        }
        if d.kind == DK_OTHER { unavail.push(dbb); continue; }
        if d.kind == DK_SELECT {
            let a = gvn_analyze_select_availability(load, d.cond, d.ta, d.fa, block_terminator(dbb));
            if a.kind >= 0 { vpb.push(AVB { bb: dbb, av: a }); } else { unavail.push(dbb); }
            continue;
        }
        let a = gvn_analyze_load_availability(load, d, d.addr);
        if a.kind >= 0 { vpb.push(AVB { bb: dbb, av: a }); } else { unavail.push(dbb); }
    }
}

// ---------------------------------------------------------------------------------------------
// DeadBlocks (SetVector)

var gv_dead: i32[>..<];
var gv_dead_set = hm_new();
fn gvn_is_dead_block(bb: i32) -> bool { hm_has(gv_dead_set, vk(bb)) }
fn gvn_add_dead(bb: i32) { if !hm_has(gv_dead_set, vk(bb)) { hm_put(gv_dead_set, vk(bb), 1); gv_dead.push(bb); } }
fn gvn_dead_clear() { gv_dead.clear(); hm_clear(gv_dead_set); }

// ---------------------------------------------------------------------------------------------
// Load PRE

// findLoadToHoistIntoPred(Pred, LoadBB, Load)
fn gvn_find_load_to_hoist_into_pred(pred: i32, load_bb: i32, load: i32) -> i32 {
    let term = block_terminator(pred);
    if term_nsucc(term) != 2 || cu_is_special_terminator(term) { return -1; }
    var succ = term_succ(term, 0);
    if succ == load_bb { succ = term_succ(term, 1); }
    if single_pred(succ) < 0 { return -1; }
    var ninsts = gv_max_insns;
    var i = block_first(succ);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if gvn_is_debug_or_pseudo(cur) { continue; }
        ninsts--;
        if ninsts == 0 { return -1; }
        if !cu_identical(cur, load) { continue; }
        var has_local_dep = true;
        if !gv_mssa_enabled {
            let d = mdep_get_dependency(cur);
            has_local_dep = d.k != MDR_NONLOCAL;
        } else {
            let ma = mssa_access_of(cur);
            if ma >= 0 && macc[ma].kind == MAK_USE {
                let q = aq_push(CA_SIMPLE);
                let cl = mssa_get_clobbering(ma, q);
                aq_pop(q);
                has_local_dep = macc[cl].bb == succ;
            }
        }
        if !has_local_dep && !icf_dominated_by_icfi_from_same_block(cur) { return cur; }
        return -1;
    }
    return -1;
}

fn gvn_is_debug_or_pseudo(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_dbg_assign || id == IID_pseudoprobe;
}

struct BV { bb: i32, v: i32 }    // MapVector<BasicBlock *, Value *> / <BasicBlock *, LoadInst *> entry

fn bv_find(m: BV[>..<]&, bb: i32) -> i64 {
    for k in m.len { if m[k].bb == bb { return k; } }
    return -1;
}
fn bv_set(m: BV[>..<]&, bb: i32, v: i32) {
    let k = bv_find(m, bb);
    if k >= 0 { m[k].v = v; } else { m.push(BV { bb: bb, v: v }); }
}

// eliminatePartiallyRedundantLoad(Load, ValuesPerBlock, AvailableLoads, CriticalEdgePredAndLoad)
fn gvn_eliminate_partially_redundant_load(load: i32, vpb: AVB[>..<]&, avail: BV[>..<]&, ce: BV[>..<]&, use_ce: bool) {
    for al in avail {
        let ub = al.bb;
        let lp = al.v;
        let nl = create_inst(OP_LOAD, vals[load].ty, [lp]);
        let x = insts[inst_of(load)];
        insts[inst_of(nl)].align = x.align;
        insts[inst_of(nl)].ord = x.ord;
        insts[inst_of(nl)].ss = x.ss;
        insts[inst_of(nl)].bits = x.bits & 1;
        inst_insert_before(nl, block_terminator(ub));
        var nm: u8[>..] = [];
        nm.append(val_name(load));
        nm.append(".pre");
        set_name(nl, nm);
        gvn_copy_dbg_loc(nl, load);
        if gv_mssa {
            let na = msu_create_access_in_bb(nl, -1, inst_parent(nl), MSP_BEFORE_TERMINATOR, true);
            if macc[na].kind == MAK_DEF { msu_insert_def(na, true); } else { msu_insert_use(na, true); }
        }
        let aa_kinds: i32[5] = [MDK_TBAA, MDK_TBAA_STRUCT, MDK_ALIAS_SCOPE, MDK_NOALIAS, MDK_NOALIAS_ADDRSPACE];
        var any_tag = false;
        for k in aa_kinds { if inst_get_md(load, k) >= 0 { any_tag = true; } }
        if any_tag { for k in aa_kinds { let m = inst_get_md(load, k); if m >= 0 { inst_set_md(nl, k, m); } else { inst_erase_md(nl, k); } } }
        let others: i32[4] = [MDK_INVARIANT_LOAD, MDK_INVARIANT_GROUP, MDK_RANGE, md_kind_id("nofpclass")];
        for k in others { let m = inst_get_md(load, k); if m >= 0 { inst_set_md(nl, k, m); } }
        let ag = inst_get_md(load, MDK_ACCESS_GROUP);
        if ag >= 0 && li_loop_for(inst_parent(load)) == li_loop_for(ub) { inst_set_md(nl, MDK_ACCESS_GROUP, ag); }
        vpb.push(AVB { bb: ub, av: av_simple(nl, 0) });
        if gv_md { mdep_invalidate_cached_pointer_info(lp); }
        if use_ce {
            let k = bv_find(ce, ub);
            if k >= 0 {
                icf_insert_instruction_to(nl, ub);
                let old = ce[k].v;
                cu_combine_metadata(nl, old, true, false);
                gvn_rauw(old, nl);
                gvn_replace_values_per_block(vpb, old, nl);
                let vno = vn_lookup0(old);
                if vno != 0 { lt_erase(vno, old, inst_parent(old)); }
                gvn_remove_instruction(old);
            }
        }
    }
    let v = gvn_construct_ssa_for_load_set(load, vpb);
    icf_remove_users_of(load);
    gvn_rauw(load, v);
    if is_inst_op(v, OP_PHI) { cu_take_name(v, load); }
    if is_inst(v) { gvn_copy_dbg_loc(v, load); }
    if gv_md && is_ptr_or_ptr_vec(vals[v].ty) { mdep_invalidate_cached_pointer_info(v); }
    gvn_salvage_and_remove(load);
}

// AvailabilityState
let AS_UNAVAILABLE: i64 = 0;
let AS_AVAILABLE: i64 = 1;
let AS_SPECULATIVE: i64 = 2;

// IsValueFullyAvailableInBlock(BB, FullyAvailableBlocks)
fn gvn_fully_available(bb: i32, fab: HMap&) -> bool {
    var wl: i32[>..<] = [];
    var unavail: i32 = -1;
    var nnew: i64 = 0;
    wl.push(bb);
    while wl.len > 0 {
        let cur = wl.pop();
        let st = hm_get(fab, vk(cur), -1);
        if st >= 0 {
            if st == AS_UNAVAILABLE { unavail = cur; break; }
            continue;
        }
        hm_put(fab, vk(cur), AS_SPECULATIVE);
        nnew++;
        let oob = nnew > gv_max_bb_spec;
        if oob || pred_count(cur) == 0 {
            hm_put(fab, vk(cur), AS_UNAVAILABLE);
            unavail = cur;
            break;
        }
        each_pred(cur) { p => wl.push(p); };
    }
    if unavail >= 0 {
        wl.clear();
        for k in block_nsucc(unavail) { wl.push(block_succ(unavail, k)); }
        while wl.len > 0 {
            let b = wl.pop();
            let st = hm_get(fab, vk(b), -1);
            if st < 0 { continue; }
            if st == AS_UNAVAILABLE || st == AS_AVAILABLE { continue; }
            hm_put(fab, vk(b), AS_UNAVAILABLE);
            for k in block_nsucc(b) { wl.push(block_succ(b, k)); }
        }
    }
    return unavail < 0;
}

var gv_fab = hm_new();

// PerformLoadPRE(Load, ValuesPerBlock, UnavailableBlocks)
fn gvn_perform_load_pre(load: i32, vpb: AVB[>..<]&, unavail: i32[>..<]&) -> bool {
    var load_bb = inst_parent(load);
    var tmp = load_bb;
    var must_ensure = icf_dominated_by_icfi_from_same_block(load);
    while single_pred(tmp) >= 0 {
        tmp = single_pred(tmp);
        if tmp == load_bb { return false; }
        if position(unavail, tmp) >= 0 { return false; }
        if term_nsucc(block_terminator(tmp)) != 1 { return false; }
        must_ensure = must_ensure || icf_has_icf(tmp);
    }
    load_bb = tmp;
    var pred_loads: BV[>..<] = [];
    hm_clear(gv_fab);
    for a in vpb { hm_put(gv_fab, vk(a.bb), AS_AVAILABLE); }
    for u in unavail { hm_put(gv_fab, vk(u), AS_UNAVAILABLE); }
    var ce_split: i32[>..<] = [];
    var ce_and_load: BV[>..<] = [];
    var preds: i32[>..<] = [];
    each_pred(load_bb) { p => preds.push(p); };
    for pred in preds {
        if inst_is_eh_pad(block_terminator(pred)) { return false; }
        if gvn_fully_available(pred, gv_fab) { continue; }
        if term_nsucc(block_terminator(pred)) != 1 {
            if iop(block_terminator(pred)) == OP_INDIRECTBR { return false; }
            let fnp = first_non_phi(load_bb);
            if fnp >= 0 && inst_is_eh_pad(fnp) { return false; }
            if !gv_split_backedge {
                if dt_dominates_block(DT_DOM, load_bb, pred) { return false; }
            }
            let li = gvn_find_load_to_hoist_into_pred(pred, load_bb, load);
            if li >= 0 { bv_set(ce_and_load, pred, li); } else { ce_split.push(pred); }
        } else {
            bv_set(pred_loads, pred, -1);
        }
    }
    let ninsert = pred_loads.len + ce_split.len;
    if ninsert > 1 { return false; }
    if must_ensure {
        if ce_split.len > 0 {
            if !gvn_safe_to_spec(load, gvn_first_non_phi_it(load_bb)) { return false; }
        }
        for pl in pred_loads { if !gvn_safe_to_spec(load, block_terminator(pl.bb)) { return false; } }
        for c in ce_and_load { if !gvn_safe_to_spec(load, block_terminator(c.bb)) { return false; } }
    }
    for op0 in ce_split {
        let np = gvn_split_critical_edges_pair(op0, load_bb);
        bv_set(pred_loads, np, -1);
    }
    for c in ce_and_load { bv_set(pred_loads, c.bb, -1); }
    var can = true;
    var newinsts: i32[>..<] = [];
    let pm = pta_mark();
    for k in pred_loads.len {
        let up = pred_loads[k].bb;
        var lp = op(load, 0);
        var cur = inst_parent(load);
        while cur != load_bb {
            let t = pta_new(lp, gv_ac);
            lp = pta_translate_with_insertion(t, cur, single_pred(cur), newinsts);
            if lp < 0 { can = false; break; }
            cur = single_pred(cur);
        }
        if lp >= 0 {
            let t = pta_new(lp, gv_ac);
            lp = pta_translate_with_insertion(t, load_bb, up, newinsts);
        }
        if lp < 0 { can = false; break; }
        pred_loads[k].v = lp;
    }
    pta_release(pm);
    if !can {
        while newinsts.len > 0 { inst_erase_from_parent(newinsts.pop()); }
        return ce_split.len > 0;
    }
    for i in newinsts {
        gvn_update_location_after_hoist(i);
        vn_lookup_or_add(i);
    }
    gvn_eliminate_partially_redundant_load(load, vpb, pred_loads, ce_and_load, true);
    return true;
}

// Instruction::updateLocationAfterHoist: dropLocation()
fn gvn_update_location_after_hoist(i: i32) {
    let dl = inst_get_md(i, 0);
    if dl < 0 { return; }
    if is_callbase(i) {
        gvn_not_ported("Instruction::dropLocation of a call with a debug location");
    }
    inst_erase_md(i, 0);
}

fn gvn_first_non_phi_it(bb: i32) -> i32 { first_non_phi(bb) }

// isSafeToSpeculativelyExecute(Load, CtxI, AC, DT)
fn gvn_safe_to_spec(i: i32, cxt: i32) -> bool {
    spec_use_dt = true;
    let r = spec_safe(i, cxt, true);
    spec_use_dt = false;
    return r;
}

// performLoopLoadPRE(Load, ValuesPerBlock, UnavailableBlocks)
fn gvn_perform_loop_load_pre(load: i32, vpb: AVB[>..<]&, unavail: i32[>..<]&) -> bool {
    let l = li_loop_for(inst_parent(load));
    if l < 0 || loop_header(l) != inst_parent(load) { return false; }
    let preheader = loop_preheader(l);
    let latch = loop_latch(l);
    if preheader < 0 || latch < 0 { return false; }
    let lp = op(load, 0);
    if is_inst(lp) && loop_contains(l, inst_parent(lp)) { return false; }
    if icf_dominated_by_icfi_from_same_block(load) { return false; }
    var loop_block: i32 = -1;
    for b in unavail {
        if !loop_contains(l, b) { continue; }
        if loop_block >= 0 { return false; }
        if l != li_loop_for(b) { return false; }
        if dt_dominates_block(DT_DOM, b, latch) { return false; }
        if inst_may_write_memory(block_terminator(b)) { return false; }
        loop_block = b;
    }
    if loop_block < 0 { return false; }
    if spec_can_be_freed(lp) { return false; }
    var avail: BV[>..<] = [];
    bv_set(avail, loop_block, lp);
    bv_set(avail, preheader, lp);
    var none: BV[>..<] = [];
    gvn_eliminate_partially_redundant_load(load, vpb, avail, none, false);
    return true;
}

// processNonLocalLoad(Load) through MemDep
fn gvn_process_nonlocal_load_md(load: i32) -> bool {
    if func_has_fn_attr(gv_fn, AK_SanitizeAddress) || func_has_fn_attr(gv_fn, AK_SanitizeHWAddress) { return false; }
    mdep_nonlocal_pointer_dependency(load);
    if (md_result.len as i64) > gv_max_num_deps { return false; }
    var mv: RMV[>..<] = [];
    for d in md_result {
        let bb = d.bb;
        let inst = mdr_inst(d.r);
        if d.r.k == MDR_SELECT {
            mv.push(rmv_select(bb, d.v, d.a1, d.a2));
            continue;
        }
        let addr = d.v;
        if d.r.k == MDR_CLOBBER { mv.push(rmv_clobber(addr, inst, -1)); }
        else if d.r.k == MDR_DEF { mv.push(rmv_def(addr, inst)); }
        else { mv.push(rmv_unknown(bb, addr, inst)); }
    }
    return gvn_process_nonlocal_load(load, mv);
}

// processNonLocalLoad(Load, Deps)
fn gvn_process_nonlocal_load(load: i32, deps: RMV[>..<]&) -> bool {
    if deps.len == 1 && deps[0].kind == DK_OTHER { return false; }
    var changed = false;
    if gv_scalar_pre {
        let g = op(load, 0);
        if is_inst_op(g, OP_GEP) {
            for k in 1..nops(g) {
                let x = op(g, k);
                if is_inst(x) { if gvn_perform_scalar_pre(x) { changed = true; } }
            }
        }
    }
    var vpb: AVB[>..<] = [];
    var unavail: i32[>..<] = [];
    gvn_analyze_load_availability_all(load, deps, vpb, unavail);
    if vpb.len == 0 { return changed; }
    if unavail.len == 0 {
        let v = gvn_construct_ssa_for_load_set(load, vpb);
        icf_remove_users_of(load);
        gvn_rauw(load, v);
        if is_inst_op(v, OP_PHI) { cu_take_name(v, load); }
        if is_inst(v) {
            if inst_get_md(load, 0) >= 0 && inst_parent(load) == inst_parent(v) { gvn_copy_dbg_loc(v, load); }
        }
        if gv_md && is_ptr_or_ptr_vec(vals[v].ty) { mdep_invalidate_cached_pointer_info(v); }
        gvn_salvage_and_remove(load);
        return true;
    }
    if !gv_load_pre { return changed; }
    if !gv_load_in_loop_pre && li_loop_for(inst_parent(load)) >= 0 { return changed; }
    if gvn_perform_loop_load_pre(load, vpb, unavail) || gvn_perform_load_pre(load, vpb, unavail) { return true; }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Assumes, invariant groups, masked loads

// processAssumeIntrinsic(IntrinsicI)
fn gvn_process_assume(ii: i32) -> bool {
    let v = cb_arg(ii, 0);
    if is_cint(v) {
        if cint_is_zero(v) {
            let ns = create_inst(OP_STORE, T_VOID, [c_poison(T_I8), c_null(ty_ptr(0))]);
            insts[inst_of(ns)].align = 1;
            inst_insert_before(ns, ii);
            if gv_mssa {
                var first_non_dom: i32 = -1;
                var a = mb_first(inst_parent(ii));
                while a >= 0 {
                    if macc[a].kind != MAK_PHI {
                        if !lsi_comes_before(macc[a].inst, ns) { first_non_dom = a; break; }
                    }
                    a = macc[a].next;
                }
                var nd: i32 = -1;
                if first_non_dom >= 0 { nd = msu_create_access_before(ns, -1, first_non_dom); }
                else { nd = msu_create_access_in_bb(ns, -1, inst_parent(ns), MSP_BEFORE_TERMINATOR, true); }
                msu_insert_def(nd, false);
            }
        }
        if assume_with_empty_bundle(ii) {
            gvn_salvage_and_remove(ii);
            return true;
        }
        return false;
    }
    if is_constant(v) { return false; }
    return gvn_propagate_equality(v, c_true(), -1, -1, ii);
}

// Value::replaceAllUsesWith, with the AssumptionCache's AffectedValueCallbackVH
fn gvn_rauw(old: i32, nv: i32) {
    ac_rauw(old, nv);
    rauw(old, nv);
}

// patchAndReplaceAllUsesWith(I, Repl)
fn gvn_patch_and_rauw(i: i32, repl: i32) {
    gvn_patch_replacement(i, repl);
    gvn_rauw(i, repl);
}

fn gvn_is_wo_extract0(i: i32) -> bool {
    if iop(i) != OP_EXTRACTVALUE { return false; }
    let x = insts[inst_of(i)];
    if x.naux != 1 || ints[x.aux] != 0 { return false; }
    let a = op(i, 0);
    return is_inst_op(a, OP_CALL) && gvn_wo_binop(call_iid(a)) >= 0;
}
fn gvn_is_overflowing_binop(i: i32) -> bool {
    let o = opcode_of(i);
    return o == OP_ADD || o == OP_SUB || o == OP_MUL || o == OP_SHL;
}

// patchReplacementInstruction(I, Repl)
fn gvn_patch_replacement(i: i32, repl: i32) {
    if !is_inst(repl) { return; }
    if gvn_is_overflowing_binop(repl) && gvn_is_wo_extract0(i) { drop_poison_generating_flags(repl); }
    else if iop(i) != OP_LOAD { ii_and_ir_flags(repl, i); }
    if is_callbase(repl) && is_callbase(i) {
        if !ii_try_intersect_attributes(repl, i) { fatal("internal: GVN: failed to intersect call attributes"); }
    }
    cu_combine_metadata(repl, i, false, false);
}

// getLoadStorePointerOperand
fn gvn_ldst_ptr(i: i32) -> i32 {
    if iop(i) == OP_LOAD { return op(i, 0); }
    if iop(i) == OP_STORE { return op(i, 1); }
    return -1;
}

// findInvariantGroupValue(L, DT)
fn gvn_find_invariant_group_value(l: i32) -> i32 {
    let po = strip_pointer_casts(op(l, 0));
    if is_constant(po) { return -1; }
    var q: i32[>..<] = [];
    q.push(po);
    var most = l;
    while q.len > 0 {
        let p = q.pop();
        var u = vals[p].first_use;
        while u >= 0 {
            let x = uses[u].user;
            u = uses[u].next;
            if !is_inst(x) || x == l || !dt_value_dominates_inst(x, most) { continue; }
            if iop(x) == OP_BITCAST || (iop(x) == OP_GEP && gvn_gep_all_zero(x)) { q.push(x); continue; }
            if inst_get_md(x, MDK_INVARIANT_GROUP) >= 0 && p == gvn_ldst_ptr(x) && !inst_is_volatile(x) { most = x; }
        }
    }
    return if most != l { most } else { -1 };
}
fn gvn_gep_all_zero(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if !is_constant(x) || !is_null_value(x) { return false; }
    }
    return true;
}

// maybeLoadStoreLocation(I, AllowStores, TLI)
fn gvn_maybe_ldst_loc(i: i32, allow_stores: bool) -> ML {
    if iop(i) == OP_LOAD { return ml_get(i); }
    let id = inst_iid(i);
    if id == IID_masked_load { return ml_for_argument(i, 0, true); }
    if id == IID_masked_store {
        if allow_stores { return ml_for_argument(i, 1, true); }
        return ml_none();
    }
    if !allow_stores { return ml_none(); }
    if iop(i) == OP_STORE { return ml_get(i); }
    return ml_none();
}

// ---------------------------------------------------------------------------------------------
// Reaching memory values through MemorySSA

fn ar_is(r: AR, k: i64) -> bool { r.k == k as u8 }

// scanMemoryAccessesUsers(Loc, IsInvariantLoad, BB, ClobbersList, MSSA, AA, L)
fn gvn_scan_ma_users(loc: ML, inv_load: bool, bb: i32, clobbers: i32[>..<]&, q: i32, l: i32) -> RMV {
    var rv = rmv_none();
    for ma in clobbers {
        var scanned: i64 = 0;
        var u = mssa_first_use(ma);
        while u >= 0 {
            let us = mssa_use_user(u);
            u = mssa_use_next(u);
            scanned++;
            if scanned >= gv_scan_users_limit { return rmv_unknown(bb, loc.ptr, -1); }
            if macc[us].kind == MAK_PHI || macc[us].bb != bb { continue; }
            let mi = macc[us].inst;
            if mi == l || (l >= 0 && !mssa_locally_dominates(us, mssa_access_of(l))) { continue; }
            let ml = gvn_maybe_ldst_loc(mi, inv_load);
            if ml.ptr == ML_NONE { continue; }
            let r = aa_alias(ml, loc, q, -1);
            if ar_is(r, AR_NO) || ar_is(r, AR_MAY) { continue; }
            if ar_is(r, AR_PARTIAL) && (!r.has_off || r.off < 0) { continue; }
            // UpdateChoice
            if rv.kind < 0 {
                if ar_is(r, AR_PARTIAL) { rv = rmv_clobber(loc.ptr, mi, r.off as i64); }
                else { rv = rmv_def(loc.ptr, mi); }
                continue;
            }
            if !mssa_locally_dominates(mssa_access_of(rv.inst), mssa_access_of(mi)) { continue; }
            if ar_is(r, AR_PARTIAL) { rv.kind = DK_CLOBBER; rv.off = r.off as i64; }
            else { rv.kind = DK_DEF; rv.off = -1; }
            rv.inst = mi;
            rv.bb = inst_parent(mi);
        }
        if rv.kind >= 0 { break; }
    }
    return rv;
}

// accessMayModifyLocation(ClobberMA, Loc, IsInvariantLoad, BB, MSSA, AA)
fn gvn_access_may_modify(cma: i32, loc: ML, inv_load: bool, bb: i32, q: i32) -> RMV {
    if mssa_is_live(cma) {
        let al = get_underlying_object(loc.ptr, 10);
        if is_inst_op(al, OP_ALLOCA) && inst_parent(al) == bb { return rmv_def(loc.ptr, al); }
        return rmv_unknown(bb, loc.ptr, -1);
    }
    if inv_load || aa_points_to_constant_memory(loc, q, false) { return rmv_none(); }
    let ci = macc[cma].inst;
    let ml = gvn_maybe_ldst_loc(ci, true);
    if ml.ptr != ML_NONE {
        let r = aa_alias(ml, loc, q, -1);
        if ar_is(r, AR_MUST) { return rmv_def(loc.ptr, ci); }
        if ar_is(r, AR_NO) {
            if !gvn_is_atomic(ci) || !md_stronger(insts[inst_of(ci)].ord, 2) || iop(ci) == OP_STORE { return rmv_none(); }
            return rmv_clobber(loc.ptr, ci, -1);
        }
        if !gvn_is_atomic(ci) && iop(ci) == OP_LOAD { return rmv_none(); }
        if ar_is(r, AR_MAY) || (ar_is(r, AR_PARTIAL) && (!r.has_off || r.off < 0)) { return rmv_clobber(loc.ptr, ci, -1); }
        return rmv_clobber(loc.ptr, ci, r.off as i64);
    }
    let id = inst_iid(ci);
    if id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_dbg_assign { return rmv_none(); }
    if id == IID_lifetime_start {
        let ol = ml_for_argument(ci, 0, true);
        if aa_alias(ol, loc, q, -1).k == AR_MUST as u8 { return rmv_def(loc.ptr, ci); }
        return rmv_none();
    }
    if aa_is_noalias_call(ci) {
        let obj = get_underlying_object(loc.ptr, 10);
        if obj == ci || aa_alias(ml_before_or_after(ci), ml_before_or_after(loc.ptr), q, -1).k == AR_MUST as u8 { return rmv_def(loc.ptr, ci); }
    }
    if iop(ci) == OP_FENCE && insts[inst_of(ci)].ord == 5 { return rmv_none(); }
    let mr = aa_inst_loc_mr(ci, loc, q);
    if mr == MR_NO || mr == MR_REF { return rmv_none(); }
    return rmv_clobber(loc.ptr, ci, -1);
}

// DependencyBlockInfo
struct DBI { bb: i32, addr: i32, init_ma: i32, ma: i32, memval: RMV, force_unknown: bool, visited: bool }
var gv_dbi: DBI[>..<];
var gv_blocks = hm_new();     // DependencyBlockSet: block -> index into gv_dbi
fn dbi_find(bb: i32) -> i64 { hm_get(gv_blocks, vk(bb), -1) }

// collectPredecessors(BB, Addr, ClobberMA, Blocks, Worklist)
fn gvn_collect_predecessors(bb: i32, addr: i32, cma: i32, wl: i32[>..<]&) -> bool {
    if pta_needs_translation_from_block(addr, bb) && !pta_is_potentially_translatable(addr) { return false; }
    let mphi = if macc[cma].bb == bb && macc[cma].kind == MAK_PHI { cma } else { -1 };
    var pbb: i32[>..<] = [];
    var pinfo: DBI[>..<] = [];
    var preds: i32[>..<] = [];
    each_pred(bb) { p => preds.push(p); };
    for pred in preds {
        if !dt_has_node(DT_DOM, pred) { continue; }
        if position(pbb, pred) >= 0 { continue; }
        let ta = pta_copy(addr);
        if pta_needs_translation_from_block(ta, bb) { pta_translate_value(ta, bb, pred, false); }
        let k = dbi_find(pred);
        if k >= 0 {
            if pta_get_addr(gv_dbi[k].addr) != pta_get_addr(ta) { return false; }
            continue;
        }
        var ma = cma;
        if mphi >= 0 {
            for j in mphi_n(mphi) { if mphi_blk(mphi, j) == pred { ma = mphi_val(mphi, j); break; } }
        }
        pbb.push(pred);
        pinfo.push(DBI { bb: pred, addr: ta, init_ma: ma, ma: ma, memval: rmv_none(), force_unknown: false, visited: false });
    }
    for j in pbb.len {
        if dbi_find(pbb[j]) < 0 {
            hm_put(gv_blocks, vk(pbb[j]), gv_dbi.len);
            gv_dbi.push(pinfo[j]);
        }
        wl.push(pbb[j]);
    }
    return true;
}

// collectClobberList(Clobbers, BB, StartInfo, Blocks, MSSA)
fn gvn_collect_clobber_list(clobbers: i32[>..<]&, bb0: i32, start: DBI) {
    var bb = bb0;
    var ma = start.init_ma;
    var last = start.ma;
    loop {
        while ma != last {
            clobbers.push(ma);
            ma = macc[ma].def;
        }
        clobbers.push(ma);
        if mssa_is_live(ma) || (macc[ma].bb == bb && macc[ma].kind != MAK_PHI) { break; }
        if macc[ma].bb == bb { bb = dt_idom(DT_DOM, bb); }
        else { bb = macc[ma].bb; }
        let k = dbi_find(bb);
        if k < 0 { break; }
        ma = gv_dbi[k].init_ma;
        last = gv_dbi[k].ma;
        if ma == clobbers[clobbers.len - 1] { clobbers.pop(); }
    }
}

// findReachingValuesForLoad(L, Values, MSSA, AA)
fn gvn_find_reaching_values(l: i32, values: RMV[>..<]&) -> bool {
    if gv_md { gvn_not_ported("MemorySSA load numbering together with MemDep (-enable-gvn-memoryssa with memdep)"); }
    ea_begin(true, false);
    let q = aq_push(CA_EARLIEST);
    let r = gvn_find_reaching_values_q(l, values, q);
    aq_pop(q);
    return r;
}

fn gvn_find_reaching_values_q(l: i32, values: RMV[>..<]&, q: i32) -> bool {
    let start = inst_parent(l);
    let inv_load = inst_get_md(l, MDK_INVARIANT_LOAD) >= 0;
    var cma = macc[mssa_access_of(l)].def;
    let loc = ml_get(l);
    if inst_get_md(l, MDK_INVARIANT_GROUP) >= 0 {
        let g = gvn_find_invariant_group_value(l);
        if g >= 0 {
            values.push(rmv_def(gvn_ldst_ptr(g), g));
            return true;
        }
    }
    loop {
        var one: i32[>..<] = [];
        one.push(cma);
        let r = gvn_scan_ma_users(loc, inv_load, start, one, q, l);
        if r.kind >= 0 { values.push(r); return true; }
        if macc[cma].bb != start || macc[cma].kind == MAK_PHI { break; }
        let r2 = gvn_access_may_modify(cma, loc, inv_load, start, q);
        if r2.kind >= 0 { values.push(r2); return true; }
        cma = macc[cma].def;
        if macc[cma].bb != start { break; }
    }
    if func_has_fn_attr(gv_fn, AK_SanitizeAddress) || func_has_fn_attr(gv_fn, AK_SanitizeHWAddress) { return false; }
    gv_dbi.clear();
    hm_clear(gv_blocks);
    let pm = pta_mark();
    var init_wl: i32[>..<] = [];
    let a0 = pta_new(op(l, 0), gv_ac);
    if !gvn_collect_predecessors(start, a0, cma, init_wl) { pta_release(pm); return false; }
    var wl: i32[>..<] = [];
    for b in init_wl { wl.push(b); }
    while wl.len > 0 {
        let bb = wl.pop();
        let k = dbi_find(bb);
        let info = gv_dbi[k];
        let ia = pta_get_addr(info.addr);
        if ia < 0 { continue; }
        if macc[info.ma].bb == bb && macc[info.ma].kind != MAK_PHI {
            var nl = loc;
            nl.ptr = ia;
            let r = gvn_access_may_modify(info.ma, nl, inv_load, bb, q);
            if r.kind >= 0 { gv_dbi[k].memval = r; continue; }
            gv_dbi[k].ma = macc[info.ma].def;
            wl.push(bb);
            continue;
        }
        if bb == start && ia != op(l, 0) { gv_dbi[k].force_unknown = true; continue; }
        if bb != start && !gvn_collect_predecessors(bb, info.addr, info.ma, wl) { gv_dbi[k].force_unknown = true; }
    }
    wl.clear();
    for b in init_wl { wl.push(b); gv_dbi[dbi_find(b)].visited = true; }
    var clobbers: i32[>..<] = [];
    while wl.len > 0 {
        let bb = wl.pop();
        let k = dbi_find(bb);
        let info = gv_dbi[k];
        let ia = pta_get_addr(info.addr);
        if ia < 0 { values.push(rmv_unknown(bb, -1, -1)); continue; }
        clobbers.clear();
        gvn_collect_clobber_list(clobbers, bb, info);
        var nl = loc;
        nl.ptr = ia;
        let r = gvn_scan_ma_users(nl, inv_load, bb, clobbers, q, -1);
        if r.kind >= 0 { values.push(r); continue; }
        if info.memval.kind >= 0 { values.push(info.memval); continue; }
        if info.force_unknown { values.push(rmv_unknown(bb, ia, -1)); continue; }
        each_pred(bb) { p =>
            let pk = dbi_find(p);
            if pk >= 0 && !gv_dbi[pk].visited {
                gv_dbi[pk].visited = true;
                wl.push(p);
            }
        };
    }
    pta_release(pm);
    return true;
}

// ---------------------------------------------------------------------------------------------
// processLoad / processMaskedLoad

fn gvn_is_token_like(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_TOKEN { return true; }
    if k == TK_TARGETEXT {
        let nm = sbytes(types[t].name);
        return (starts_with(nm, "dx.") && nm != "dx.Padding") || nm == "amdgpu.stridemark";
    }
    return false;
}

fn gvn_process_load(l: i32) -> bool {
    if !gv_md && !gv_mssa_enabled { return false; }
    if !ldst_is_unordered(l) { return false; }
    if gvn_is_token_like(vals[l].ty) { return false; }
    if vals[l].first_use < 0 {
        gvn_salvage_and_remove(l);
        return true;
    }
    var mv = rmv_unknown(-1, -1, -1);
    if !gv_mssa_enabled {
        let dep = mdep_get_dependency(l);
        if dep.k == MDR_NONLOCAL { return gvn_process_nonlocal_load_md(l); }
        if dep.k == MDR_DEF { mv = rmv_def(op(l, 0), dep.i); }
        else if dep.k == MDR_CLOBBER { mv = rmv_clobber(op(l, 0), dep.i, -1); }
    } else {
        var mvs: RMV[>..<] = [];
        if !gvn_find_reaching_values(l, mvs) { return false; }
        if mvs.len > 1 || mvs[0].bb != inst_parent(l) { return gvn_process_nonlocal_load(l, mvs); }
        mv = mvs[0];
    }
    if mv.kind == DK_OTHER { return false; }
    let a = gvn_analyze_load_availability(l, mv, op(l, 0));
    if a.kind < 0 { return false; }
    let av = av_materialize(a, l, l);
    icf_remove_users_of(l);
    gvn_rauw(l, av);
    if gv_mssa { msu_remove_inst_access(l, false); }
    gvn_salvage_and_remove(l);
    if gv_md && is_ptr_or_ptr_vec(vals[av].ty) { mdep_invalidate_cached_pointer_info(av); }
    return true;
}

fn gvn_process_masked_load(i: i32) -> bool {
    if !gv_md { return false; }
    let dep = mdep_get_dependency(i);
    let di = mdr_inst(dep);
    if di < 0 || !mdr_is_local(dep) || dep.k != MDR_DEF { return false; }
    let mask = op(i, 1);
    let pt = op(i, 2);
    if inst_iid(di) != IID_masked_store || cb_arg(di, 2) != mask { return false; }
    let sv = cb_arg(di, 0);
    if vals[sv].ty != vals[i].ty { return false; }
    let s = create_inst(OP_SELECT, vals[sv].ty, [mask, sv, pt]);
    inst_insert_before(s, i);
    icf_remove_users_of(i);
    gvn_rauw(i, s);
    gvn_salvage_and_remove(i);
    return true;
}

// ---------------------------------------------------------------------------------------------
// propagateEquality

// DominatorTree::dominates(const Instruction *Def, const Use &U)
fn gvn_inst_dominates_use(def: i32, u: i32) -> bool {
    let user = uses[u].user;
    let dbb = inst_parent(def);
    var ubb = inst_parent(user);
    if iop(user) == OP_PHI { ubb = phi_block(user, (u - vals[user].ops) as i64); }
    if !dt_has_node(DT_DOM, ubb) { return true; }
    if !dt_has_node(DT_DOM, dbb) { return false; }
    let o = iop(def);
    if o == OP_INVOKE { return pi_edge_dominates_use(dbb, invoke_normal_dest(def), u); }
    if o == OP_CALLBR { gvn_not_ported("DominatorTree::dominates(callbr, Use)"); }
    if dbb != ubb { return dt_dominates_block(DT_DOM, dbb, ubb); }
    if iop(user) == OP_PHI { return true; }
    return lsi_comes_before(def, user);
}

// isPointerUseReplacable(U, HasNonAddressBits)
fn gvn_pointer_use_replacable(u: i32, non_addr_bits: bool) -> bool {
    var limit: i64 = 40;
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    wl.push(uses[u].user);
    loop {
        if wl.len == 0 { break; }
        limit--;
        if limit == 0 { break; }
        let user = wl.pop();
        if position(visited, user) >= 0 { continue; }
        visited.push(user);
        let o = opcode_of(user);
        if is_inst(user) && (o == OP_ICMP || o == OP_PTRTOADDR) { continue; }
        if is_inst(user) && !non_addr_bits && o == OP_PTRTOINT { continue; }
        if is_inst(user) && (o == OP_PHI || o == OP_SELECT) {
            var x = vals[user].first_use;
            var us: i32[>..<] = [];
            while x >= 0 { us.push(uses[x].user); x = uses[x].next; }
            for y in us { wl.push(y); }
        } else {
            return false;
        }
    }
    return limit != 0;
}

// canReplacePointersInUseIfEqual(U, To, DL)
fn gvn_can_replace_pointers_in_use(u: i32, to: i32) -> bool {
    let ty: i32 = vals[to].ty;
    if !is_ptr_or_ptr_vec(ty) { return true; }
    let user = uses[u].user;
    let id = inst_iid(user);
    if id == IID_lifetime_start || id == IID_lifetime_end { return false; }
    if can_replace_pointers_if_equal(uses[u].val, to) { return true; }
    let as_ = ptr_as(ty_scalar(ty));
    let non_addr = dl_ptr(as_).idx != dl_ptr(as_).bits;
    return gvn_pointer_use_replacable(u, non_addr);
}

// replaceDominatedUsesWith(If)(From, To, DT, Root[, ShouldReplace]); root: edge (es, ee) or instruction ri
fn gvn_replace_dominated_uses(from: i32, to: i32, es: i32, ee: i32, ri: i32, check_ptrs: bool) -> i64 {
    var count: i64 = 0;
    var u = vals[from].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let user = uses[u].user;
        if !(is_inst(user) && inst_iid(user) == IID_fake_use) {
            let dom = if ri >= 0 { gvn_inst_dominates_use(ri, u) } else { pi_edge_dominates_use(es, ee, u) };
            if dom && (!check_ptrs || gvn_can_replace_pointers_in_use(u, to)) {
                use_set(u, to);
                count++;
            }
        }
        u = nx;
    }
    return count;
}

// CmpInst::isEquivalence(Invert)
fn gvn_cmp_is_equivalence(c: i32, invert: bool) -> bool {
    if iop(c) == OP_ICMP { return inst_pred(c) == (if invert { 33 } else { 32 }); }
    return fcmp_is_equivalence(c, invert);
}

// m_LogicalAnd / m_LogicalOr
fn gvn_match_logical(v: i32, is_and: bool) -> bool, i32, i32 {
    if !is_inst(v) { return false, -1, -1; }
    let o = iop(v);
    if o == (if is_and { OP_AND } else { OP_OR }) { return true, op(v, 0), op(v, 1); }
    if o == OP_SELECT {
        let c = op(v, 0);
        if vals[c].ty != vals[v].ty { return false, -1, -1; }
        if is_and {
            let f = op(v, 2);
            if is_constant(f) && is_null_value(f) { return true, c, op(v, 1); }
        } else {
            let t = op(v, 1);
            if is_constant(t) && gvn_is_one_value(t) { return true, c, op(v, 2); }
        }
    }
    return false, -1, -1;
}
fn gvn_is_one_value(c: i32) -> bool { is_cint(c) && ap_is_one(ci_ap(c)) }

struct EqPair { l: i32, r: i32 }

// propagateEquality(LHS, RHS, Root): Root is the edge (es, ee) when ri < 0, else the instruction ri
fn gvn_propagate_equality(lhs0: i32, rhs0: i32, es: i32, ee: i32, ri: i32) -> bool {
    var wl: EqPair[>..<] = [];
    wl.push(EqPair { l: lhs0, r: rhs0 });
    var changed = false;
    var dom_blocks: i32[>..<] = [];
    if ri < 0 {
        if single_pred(ee) >= 0 { dom_blocks.push(ee); }
    } else {
        let pb = inst_parent(ri);
        var c = dt_first_child(gv_fn, DT_DOM, pb);
        while c >= 0 { dom_blocks.push(c); c = dt_next_sibling(DT_DOM, c); }
    }
    while wl.len > 0 {
        let it = wl.pop();
        var lhs = it.l;
        var rhs = it.r;
        if lhs == rhs { continue; }
        if is_constant(lhs) && is_constant(rhs) { continue; }
        if is_constant(lhs) || (is_arg(lhs) && !is_constant(rhs)) { let t = lhs; lhs = rhs; rhs = t; }
        var lvn = vn_lookup_or_add(lhs);
        if (is_arg(lhs) && is_arg(rhs)) || (is_inst(lhs) && is_inst(rhs)) {
            let rvn = vn_lookup_or_add(rhs);
            if lvn < rvn { let t = lhs; lhs = rhs; rhs = t; lvn = rvn; }
        }
        if !is_inst(rhs) && can_replace_pointers_if_equal(lhs, rhs) {
            for b in dom_blocks { lt_insert(lvn, rhs, b); }
        }
        let u0 = vals[lhs].first_use;
        if !(u0 >= 0 && uses[u0].next < 0) {
            let n = gvn_replace_dominated_uses(lhs, rhs, es, ee, ri, true);
            if n > 0 {
                changed = true;
                if gv_md { mdep_invalidate_cached_pointer_info(lhs); }
            }
        }
        if vals[rhs].ty != T_I1 { continue; }
        if !is_cint(rhs) { continue; }
        let known_true = !cint_is_zero(rhs);
        let known_false = !known_true;
        let ma, a, b = gvn_match_logical(lhs, true);
        let mo, a2, b2 = gvn_match_logical(lhs, false);
        if known_true && ma {
            wl.push(EqPair { l: a, r: rhs });
            wl.push(EqPair { l: b, r: rhs });
            continue;
        }
        if known_false && mo {
            wl.push(EqPair { l: a2, r: rhs });
            wl.push(EqPair { l: b2, r: rhs });
            continue;
        }
        if is_inst(lhs) && (iop(lhs) == OP_ICMP || iop(lhs) == OP_FCMP) {
            let op0 = op(lhs, 0);
            let op1 = op(lhs, 1);
            if gvn_cmp_is_equivalence(lhs, known_false) { wl.push(EqPair { l: op0, r: op1 }); }
            let notpred = pred_inverse_any(inst_pred(lhs));
            let notval = c_int(vals[lhs].ty, if known_false { 1 } else { 0 });
            let nextnum = vn_next;
            let num = vn_lookup_or_add_cmp(iop(lhs), notpred, op0, op1);
            if num < nextnum {
                var n = lt_head(num);
                while n >= 0 {
                    let e = lt_nodes[n];
                    n = e.next;
                    if ri < 0 {
                        if !dt_dominates_block(DT_DOM, e.bb, es) && !dt_dominates_block(DT_DOM, ee, e.bb) { continue; }
                    } else {
                        let ibb = inst_parent(ri);
                        if !dt_dominates_block(DT_DOM, e.bb, ibb) && !dt_dominates_block(DT_DOM, ibb, e.bb) { continue; }
                    }
                    let notcmp = e.val;
                    if notcmp >= 0 && is_inst(notcmp) {
                        let nr = gvn_replace_dominated_uses(notcmp, notval, es, ee, ri, false);
                        if nr > 0 { changed = true; }
                        if gv_md { mdep_invalidate_cached_pointer_info(notcmp); }
                    }
                }
            }
            for bb in dom_blocks { lt_insert(num, notval, bb); }
            continue;
        }
        if is_inst_op(lhs, OP_TRUNC) && op_nuw(lhs) {
            let x = op(lhs, 0);
            wl.push(EqPair { l: x, r: c_int(vals[x].ty, if known_true { 1 } else { 0 }) });
            continue;
        }
        if is_inst_op(lhs, OP_XOR) {
            var x: i32 = -1;
            if is_constant(op(lhs, 1)) && is_all_ones_value(op(lhs, 1)) { x = op(lhs, 0); }
            else if is_constant(op(lhs, 0)) && is_all_ones_value(op(lhs, 0)) { x = op(lhs, 1); }
            if x >= 0 {
                wl.push(EqPair { l: x, r: c_int(vals[x].ty, if !known_true { 1 } else { 0 }) });
                continue;
            }
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// The main loop

// processInstruction(I)
fn gvn_process_instruction(i: i32) -> bool {
    let v = simplify_instruction(i);
    if v >= 0 {
        var changed = false;
        if vals[i].first_use >= 0 {
            icf_remove_users_of(i);
            gvn_rauw(i, v);
            changed = true;
        }
        if is_instruction_trivially_dead(i) {
            gvn_salvage_and_remove(i);
            changed = true;
        }
        if changed {
            if gv_md && is_ptr_or_ptr_vec(vals[v].ty) { mdep_invalidate_cached_pointer_info(v); }
            return true;
        }
    }
    let o = iop(i);
    if inst_iid(i) == IID_assume { return gvn_process_assume(i); }
    if o == OP_LOAD {
        if gvn_process_load(i) { return true; }
        let num = vn_lookup_or_add(i);
        lt_insert(num, i, inst_parent(i));
        return false;
    }
    if inst_iid(i) == IID_masked_load && gvn_process_masked_load(i) { return true; }
    if o == OP_CONDBR {
        let c = op(i, 0);
        if is_constant(c) { return gvn_process_foldable_cond_br(i); }
        let ts = term_succ(i, 0);
        let fs = term_succ(i, 1);
        if ts == fs { return false; }
        let parent = inst_parent(i);
        var changed = false;
        if gvn_propagate_equality(c, c_true(), parent, ts, -1) { changed = true; }
        if gvn_propagate_equality(c, c_false(), parent, fs, -1) { changed = true; }
        return changed;
    }
    if o == OP_SWITCH {
        let c = op(i, 0);
        let parent = inst_parent(i);
        var changed = false;
        var succs: i32[>..<] = [];
        var cnt: i64[>..<] = [];
        for k in term_nsucc(i) {
            let s = term_succ(i, k);
            let j = position(succs, s);
            if j >= 0 { cnt[j]++; } else { succs.push(s); cnt.push(1); }
        }
        let ncases = (nops(i) - 2) / 2;
        for k in ncases {
            let dst = op(i, 3 + 2 * k);
            let j = position(succs, dst);
            if j >= 0 && cnt[j] == 1 {
                if gvn_propagate_equality(c, op(i, 2 + 2 * k), parent, dst, -1) { changed = true; }
            }
        }
        return changed;
    }
    if vals[i].ty == T_VOID { return false; }
    let nextnum = vn_next;
    let num = vn_lookup_or_add(i);
    if o == OP_ALLOCA || is_terminator(i) || o == OP_PHI {
        lt_insert(num, i, inst_parent(i));
        return false;
    }
    if o == OP_PTRTOADDR {
        let as_ = ptr_as(ty_scalar(vals[op(i, 0)].ty));
        if dl_ptr(as_).idx == dl_ptr(as_).bits && !dl_has_unstable_repr(as_) {
            let ptinum = vn_lookup_ptrtoint(op(i, 0), vals[i].ty);
            let pti = gvn_find_leader(inst_parent(i), ptinum);
            if pti >= 0 {
                gvn_patch_and_rauw(i, pti);
                gvn_salvage_and_remove(i);
                return true;
            }
        }
    }
    if num >= nextnum {
        lt_insert(num, i, inst_parent(i));
        return false;
    }
    let repl = gvn_find_leader(inst_parent(i), num);
    if repl < 0 {
        lt_insert(num, i, inst_parent(i));
        return false;
    }
    if repl == i { return false; }
    gvn_patch_and_rauw(i, repl);
    if gv_md && is_ptr_or_ptr_vec(vals[repl].ty) { mdep_invalidate_cached_pointer_info(repl); }
    gvn_salvage_and_remove(i);
    return true;
}

// EliminateDuplicatePHINodes(BB, ToRemove)
fn gvn_eliminate_duplicate_phis(bb: i32, to_remove: i32[>..<]&) -> bool {
    var nphis: i64 = 0;
    var i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI { nphis++; i = inst_next(i); }
    var changed = false;
    if nphis <= 32 {
        i = block_first(bb);
        while i >= 0 && iop(i) == OP_PHI {
            let pn = i;
            i = inst_next(i);
            var j = i;
            var restarted = false;
            while j >= 0 && iop(j) == OP_PHI {
                let dup = j;
                j = inst_next(j);
                if position(to_remove, dup) >= 0 { continue; }
                if !cu_identical_when_defined(dup, pn, false) { continue; }
                gvn_rauw(dup, pn);
                to_remove.push(dup);
                changed = true;
                restarted = true;
                break;
            }
            if restarted { i = block_first(bb); }
        }
        return changed;
    }
    // the set-based implementation: the first PHI of each class (isIdenticalTo) since the last restart wins
    var set: i32[>..<] = [];
    i = block_first(bb);
    while i >= 0 && iop(i) == OP_PHI {
        let pn = i;
        i = inst_next(i);
        if position(to_remove, pn) >= 0 { continue; }
        var found: i32 = -1;
        for s in set { if cu_identical(s, pn) { found = s; break; } }
        if found < 0 { set.push(pn); continue; }
        gvn_rauw(pn, found);
        to_remove.push(pn);
        changed = true;
        set.clear();
        i = block_first(bb);
    }
    return changed;
}

// processBlock(BB)
fn gvn_process_block(bb: i32) -> bool {
    if gvn_is_dead_block(bb) { return false; }
    var changed = false;
    var to_remove: i32[>..<] = [];
    if gvn_eliminate_duplicate_phis(bb, to_remove) { changed = true; }
    for pn in to_remove { gvn_remove_instruction(pn); }
    var i = block_first(bb);
    while i >= 0 {
        let cur = i;
        i = inst_next(i);
        if gvn_process_instruction(cur) { changed = true; }
        // make_early_inc_range: the saved next instruction is used even if processing erased it? LLVM's
        // iterator was incremented before processing, so `i` is still the right next instruction unless
        // processing erased it, which GVN never does for an instruction other than the current one.
    }
    return changed;
}

// iterateOnFunction(F)
fn gvn_iterate_on_function(fv: i32) -> bool {
    gvn_cleanup_global_sets();
    var changed = false;
    var rpo: i32[>..<] = [];
    gvn_rpo(fv, rpo);
    for bb in rpo { if gvn_process_block(bb) { changed = true; } }
    return changed;
}

// cleanupGlobalSets
fn gvn_cleanup_global_sets() {
    vn_clear();
    lt_clear();
    hm_clear(gv_rpo_num);
    icf_clear();
    gv_invalid_rpo = true;
}

// removeInstruction(I)
fn gvn_remove_instruction(i: i32) {
    vn_erase(i);
    if gv_md { mdep_remove_instruction(i); }
    if gv_mssa { msu_remove_inst_access(i, false); }
    icf_remove_instruction(i);
    inst_erase_from_parent(i);
}

// salvageAndRemoveInstruction(I)
fn gvn_salvage_and_remove(i: i32) {
    salvage_knowledge(i, true);
    salvage_debug_info(i);
    gvn_remove_instruction(i);
}

// ---------------------------------------------------------------------------------------------
// Scalar PRE

var gv_rpo_num = hm_new();       // BlockRPONumber
var gv_invalid_rpo: bool = true;
struct Edge { ti: i32, k: i64 }
var gv_to_split: Edge[>..<];

// assignBlockRPONumber(F)
fn gvn_assign_block_rpo_number(fv: i32) {
    hm_clear(gv_rpo_num);
    var rpo: i32[>..<] = [];
    gvn_rpo(fv, rpo);
    var n: i64 = 1;
    for bb in rpo { hm_put(gv_rpo_num, vk(bb), n); n++; }
    gv_invalid_rpo = false;
}

// performScalarPREInsertion(Instr, Pred, Curr, ValNo)
fn gvn_perform_scalar_pre_insertion(instr: i32, pred: i32, curr: i32) -> bool {
    var ok = true;
    for k in nops(instr) {
        let x = op(instr, k);
        if is_arg(x) || is_constant(x) { continue; }
        if !vn_exists(x) { ok = false; break; }
        let tv = vn_phi_translate(pred, curr, vn_lookup(x));
        let v = gvn_find_leader(pred, tv);
        if v >= 0 { set_op(instr, k, v); }
        else { ok = false; break; }
    }
    if !ok { return false; }
    inst_insert_before(instr, block_terminator(pred));
    var nm: u8[>..] = [];
    nm.append(val_name(instr));
    nm.append(".pre");
    set_name(instr, nm);
    icf_insert_instruction_to(instr, pred);
    let num = vn_lookup_or_add(instr);
    vn_add(instr, num);
    lt_insert(num, instr, pred);
    return true;
}

// GetSuccessorNumber(BB, Succ)
fn gvn_successor_number(bb: i32, succ: i32) -> i64 {
    let t = block_terminator(bb);
    for k in term_nsucc(t) { if term_succ(t, k) == succ { return k; } }
    fatal("internal: GVN: block is not a successor");
    return 0;
}

// performScalarPRE(CurInst)
fn gvn_perform_scalar_pre(cur: i32) -> bool {
    let o = iop(cur);
    if o == OP_ALLOCA || is_terminator(cur) || o == OP_PHI || vals[cur].ty == T_VOID || inst_may_read_memory(cur) ||
       inst_may_have_side_effects(cur) || gvn_is_token_like(vals[cur].ty) { return false; }
    if o == OP_ICMP || o == OP_FCMP { return false; }
    if o == OP_GEP { return false; }
    if is_callbase(cur) && vals[cb_callee(cur)].kind == VK_INLINEASM { return false; }
    let valno = vn_lookup(cur);
    var num_with: i64 = 0;
    var num_without: i64 = 0;
    var pre_pred: i32 = -1;
    let cb = inst_parent(cur);
    if gv_invalid_rpo { gvn_assign_block_rpo_number(gv_fn); }
    var pm: BV[>..<] = [];
    var preds: i32[>..<] = [];
    each_pred(cb) { p => preds.push(p); };
    for p in preds {
        if !dt_has_node(DT_DOM, p) { num_without = 2; break; }
        if hm_get(gv_rpo_num, vk(p), 0) >= hm_get(gv_rpo_num, vk(cb), 0) { num_without = 2; break; }
        let tv = vn_phi_translate(p, cb, valno);
        let pv = gvn_find_leader(p, tv);
        if pv < 0 {
            pm.push(BV { bb: p, v: -1 });
            pre_pred = p;
            num_without++;
        } else if pv == cur {
            num_without = 2;
            break;
        } else {
            pm.push(BV { bb: p, v: pv });
            num_with++;
        }
    }
    if num_without > 1 || num_with == 0 { return false; }
    var pre_instr: i32 = -1;
    if num_without != 0 {
        if !spec_safe(cur, -1, false) {
            if icf_dominated_by_icfi_from_same_block(cur) { return false; }
        }
        if iop(block_terminator(pre_pred)) == OP_INDIRECTBR { return false; }
        let sn = gvn_successor_number(pre_pred, cb);
        if is_critical_edge(block_terminator(pre_pred), sn, false) {
            gv_to_split.push(Edge { ti: block_terminator(pre_pred), k: sn });
            return false;
        }
        pre_instr = inst_clone(cur);
        if !gvn_perform_scalar_pre_insertion(pre_instr, pre_pred, cb) {
            drop_all_refs(pre_instr);
            val_set_dead(pre_instr);
            return false;
        }
    }
    let phi = new_inst(OP_PHI, vals[cur].ty, pm.len as i64);
    vals[phi].nops = 0;
    inst_insert_at(phi, cb, block_first(cb), true);
    var nm: u8[>..] = [];
    nm.append(val_name(cur));
    nm.append(".pre-phi");
    set_name(phi, nm);
    for e in pm {
        if e.v >= 0 {
            gvn_patch_replacement(cur, e.v);
            phi_add_incoming(phi, e.v, e.bb);
        } else {
            phi_add_incoming(phi, pre_instr, pre_pred);
        }
    }
    vn_add(phi, valno);
    vn_erase_translate_cache_entry(valno, cb);
    lt_insert(valno, phi, cb);
    gvn_copy_dbg_loc(phi, cur);
    gvn_rauw(cur, phi);
    if gv_md && is_ptr_or_ptr_vec(vals[phi].ty) { mdep_invalidate_cached_pointer_info(phi); }
    lt_erase(valno, cur, cb);
    gvn_remove_instruction(cur);
    return true;
}

// performPRE(F)
fn gvn_perform_pre(fv: i32) -> bool {
    var changed = false;
    var order: i32[>..<] = [];
    gvn_dfs(fv, order);
    let entry = func_entry(fv);
    for cb in order {
        if cb == entry { continue; }
        let fnp = first_non_phi(cb);
        if fnp >= 0 && inst_is_eh_pad(fnp) { continue; }
        var i = block_first(cb);
        while i >= 0 {
            let cur = i;
            i = inst_next(i);
            if gvn_perform_scalar_pre(cur) { changed = true; }
        }
    }
    if gvn_split_critical_edges() { changed = true; }
    return changed;
}

fn gvn_ces_opts(preserve_loop_simplify: bool) -> CESOpts {
    var o = ces_opts(true, true, false);
    o.mssau = gv_mssa;
    o.preserve_loop_simplify = preserve_loop_simplify;
    return o;
}

// splitCriticalEdges(Pred, Succ)
fn gvn_split_critical_edges_pair(pred: i32, succ: i32) -> i32 {
    let t = block_terminator(pred);
    let k = gvn_successor_number(pred, succ);
    let bb = split_critical_edge(t, k, gvn_ces_opts(false), "");
    if bb >= 0 {
        if gv_md { mdep_invalidate_cached_predecessors(); }
        gv_invalid_rpo = true;
    }
    return bb;
}

// splitCriticalEdges()
fn gvn_split_critical_edges() -> bool {
    if gv_to_split.len == 0 { return false; }
    var changed = false;
    loop {
        let e = gv_to_split.pop();
        if split_critical_edge(e.ti, e.k, gvn_ces_opts(true), "") >= 0 { changed = true; }
        if gv_to_split.len == 0 { break; }
    }
    if changed {
        if gv_md { mdep_invalidate_cached_predecessors(); }
        gv_invalid_rpo = true;
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// Dead blocks

// DominatorTree::getDescendants(R, Result)
fn gvn_descendants(r: i32, out: i32[>..<]&) {
    out.clear();
    if !dt_has_node(DT_DOM, r) { return; }
    var wl: i32[>..<] = [];
    wl.push(r);
    while wl.len > 0 {
        let n = wl.pop();
        out.push(n);
        var c = dt_first_child(gv_fn, DT_DOM, n);
        while c >= 0 { wl.push(c); c = dt_next_sibling(DT_DOM, c); }
    }
}

// addDeadBlock(BB)
fn gvn_add_dead_block(bb: i32) {
    var newdead: i32[>..<] = [];
    var df: i32[>..<] = [];
    newdead.push(bb);
    var dom: i32[>..<] = [];
    while newdead.len > 0 {
        let d = newdead.pop();
        if gvn_is_dead_block(d) { continue; }
        gvn_descendants(d, dom);
        for b in dom { gvn_add_dead(b); }
        for b in dom {
            for k in block_nsucc(b) {
                let s = block_succ(b, k);
                if gvn_is_dead_block(s) { continue; }
                var all_dead = true;
                each_pred(s) { p => if all_dead && !gvn_is_dead_block(p) { all_dead = false; } };
                if !all_dead { if position(df, s) < 0 { df.push(s); } }
                else { newdead.push(s); }
            }
        }
    }
    for b in df {
        if gvn_is_dead_block(b) { continue; }
        var preds: i32[>..<] = [];
        each_pred(b) { p => preds.push(p); };
        for p in preds {
            if !gvn_is_dead_block(p) { continue; }
            var is_succ = false;
            for k in block_nsucc(p) { if block_succ(p, k) == b { is_succ = true; } }
            if is_succ && is_critical_edge(block_terminator(p), gvn_successor_number(p, b), false) {
                let s = gvn_split_critical_edges_pair(p, b);
                if s >= 0 { gvn_add_dead(s); }
            }
        }
        preds.clear();
        each_pred(b) { p => preds.push(p); };
        for p in preds {
            if !gvn_is_dead_block(p) { continue; }
            var i = block_first(b);
            while i >= 0 && iop(i) == OP_PHI {
                for k in nops(i) { if phi_block(i, k) == p { set_op(i, k, c_poison(vals[i].ty)); } }
                if gv_md { mdep_invalidate_cached_pointer_info(i); }
                i = inst_next(i);
            }
        }
    }
}

// processFoldableCondBr(BI)
fn gvn_process_foldable_cond_br(bi: i32) -> bool {
    if term_succ(bi, 0) == term_succ(bi, 1) { return false; }
    let c = op(bi, 0);
    if !is_cint(c) { return false; }
    var dead = if !cint_is_zero(c) { term_succ(bi, 1) } else { term_succ(bi, 0) };
    if gvn_is_dead_block(dead) { return false; }
    if single_pred(dead) < 0 { dead = gvn_split_critical_edges_pair(inst_parent(bi), dead); }
    gvn_add_dead_block(dead);
    return true;
}

// assignValNumForDeadCode
fn gvn_assign_val_num_for_dead_code() {
    for bb in gv_dead {
        var i = block_first(bb);
        while i >= 0 {
            let n = vn_lookup_or_add(i);
            lt_insert(n, i, bb);
            i = inst_next(i);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// GVNPass::run

fn gvn_run(fv: i32, arg: i32) -> u32 {
    gv_fn = fv;
    tli_cur_fn = fv;
    local_have_tli = true;
    gv_scalar_pre = gvn_opt(arg, 0, flag_bool("enable-scalar-pre", true));
    gv_load_pre = gvn_opt(arg, 1, flag_bool("enable-load-pre", true));
    gv_load_in_loop_pre = flag_bool("enable-load-in-loop-pre", true);
    gv_split_backedge = gvn_opt(arg, 2, flag_bool("enable-split-backedge-in-load-pre", false));
    gv_memdep = gvn_opt(arg, 3, flag_bool("enable-gvn-memdep", true));
    gv_mssa_enabled = gvn_opt(arg, 4, flag_bool("enable-gvn-memoryssa", false));
    gv_max_num_deps = flag_int("gvn-max-num-deps", 100);
    gv_max_bb_spec = flag_int("gvn-max-block-speculations", 600);
    gv_max_visited = flag_int("gvn-max-num-visited-insts", 100);
    gv_max_insns = flag_int("gvn-max-num-insns", 100);
    gv_scan_users_limit = flag_int("gvn-scan-users-limit", 100);
    dt_get(fv, DT_DOM);
    vt_invalidate_assumes();
    ac_invalidate();
    aa_begin(fv);
    gv_md = gv_memdep;
    if gv_md { mdep_begin(fv); }
    li_get(fv);
    var have_mssa = mssa_valid(fv);
    if gv_mssa_enabled && !have_mssa {
        mssa_get(fv);
        have_mssa = true;
    }
    gv_mssa = have_mssa;
    if gv_mssa { msu_reset(); }
    let changed = gvn_run_impl(fv);
    if gv_md { mdep_end(); }
    gv_md = false;
    if !changed { return PA_ALL; }
    var pa: u32 = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS);
    if gv_mssa { pa = pa | ((1 as u32) << A_MEMORYSSA); }
    return pa;
}

// runImpl
fn gvn_run_impl(fv: i32) -> bool {
    gv_invalid_rpo = true;
    gv_to_split.clear();
    gvn_dead_clear();
    var changed = false;
    dtu_begin(fv, true, false, true);
    var b = func_first_block(fv);
    while b >= 0 {
        let nx = block_next(b);
        if gvn_merge_block_into_predecessor(b) { changed = true; }
        b = nx;
    }
    dtu_flush();
    dtu_end();
    var cont = true;
    while cont {
        cont = gvn_iterate_on_function(fv);
        if cont { changed = true; }
    }
    if gv_scalar_pre {
        gvn_assign_val_num_for_dead_code();
        var pre_changed = true;
        while pre_changed {
            pre_changed = gvn_perform_pre(fv);
            if pre_changed { changed = true; }
        }
    }
    gvn_cleanup_global_sets();
    gvn_dead_clear();
    if gv_mssa && flag_bool("verify-memoryssa", false) { mssa_verify(fv); }
    return changed;
}
