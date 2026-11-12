// Evaluator: a constant interpreter for static constructors (GlobalOpt). Port of
// llvm/lib/Transforms/Utils/Evaluator.cpp and llvm/include/llvm/Transforms/Utils/Evaluator.h.
// MutableValue / MutableAggregate are records of ev_mvs / ev_aggs (a MutableValue holds a constant or an
// aggregate; an aggregate's element MutableValues are a run in ev_agg_elems). The per-call ValueStack frames are
// one hash map keyed by (frame serial, value). One evaluator at a time (ev_begin / ev_end).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import datalayout;
import pm;
import vt;
import cfold;
import constfold;
import instsimplify;
import memintr;
import memloc;
import scev;
import apint;
import ipo_globals;

fn ev_fail(what: const u8[:]) { fatal(str("Evaluator: ", what, " is not ported yet")); }

struct EvMv { c: i32, agg: i32 }
struct EvAgg { ty: i32, at: i32, n: i32 }
var ev_mvs: EvMv[>..<];
var ev_aggs: EvAgg[>..<];
var ev_agg_elems: i32[>..<];
var ev_vals = hm_new();            // (frame serial, value) -> constant
var ev_frames: i32[>..<];          // ValueStack: frame serials
var ev_next_frame: i32 = 0;
var ev_call_stack: i32[>..<];
var ev_mut_gv: i32[>..<];          // MutatedMemory, in insertion order
var ev_mut_mv: i32[>..<];
var ev_alloca_tmps: i32[>..<];
var ev_invariants: i32[>..<];
var ev_simple = hm_new();          // SimpleConstants
var ev_formals: i32[>..<];         // argument runs of the calls being evaluated

fn ev_begin() {
    ev_mvs.clear(); ev_aggs.clear(); ev_agg_elems.clear();
    hm_clear(ev_vals);
    ev_frames.clear();
    ev_call_stack.clear();
    ev_mut_gv.clear(); ev_mut_mv.clear();
    ev_alloca_tmps.clear();
    ev_invariants.clear();
    hm_clear(ev_simple);
    ev_formals.clear();
    ev_push_frame();
}
fn ev_push_frame() { ev_frames.push(ev_next_frame); ev_next_frame++; }
// ~Evaluator: the alloca temporaries (detached globals) are destroyed; uses that remain become null
fn ev_end() {
    for t in ev_alloca_tmps {
        if first_use(t) >= 0 { rauw_with_constants(t, c_null(vals[t].ty)); }
        drop_all_refs(t);
        val_set_dead(t);
    }
    ev_alloca_tmps.clear();
}

recursive fn ev_get_val(v: i32) -> i32 {
    if is_constant(v) { return v; }
    let r = hm_get(ev_vals, hk2(ev_frames[ev_frames.len - 1], v), -1);
    return r as i32;
}
recursive fn ev_set_val(v: i32, c: i32) { hm_put(ev_vals, hk2(ev_frames[ev_frames.len - 1], v), c as i64); }

// isSimpleEnoughValueToCommit
recursive fn ev_is_simple_enough(c: i32) -> bool {
    if hm_has(ev_simple, c as u64) { return true; }
    hm_put(ev_simple, c as u64, 1);
    return ev_is_simple_enough_helper(c);
}
recursive fn ev_is_simple_enough_helper(c: i32) -> bool {
    let k = vals[c].kind;
    if ig_is_gv(c) { return globs[glob_of(c)].dll != 1 && globs[glob_of(c)].tls == 0; }
    if nops(c) == 0 || k == VK_BLOCKADDR { return true; }
    if k == VK_CARRAY || k == VK_CSTRUCT || k == VK_CVECTOR {
        for j in nops(c) { if !ev_is_simple_enough(op(c, j)) { return false; } }
        return true;
    }
    if k != VK_CEXPR { return false; }
    let o = cexpr_op(c);
    if o == OP_BITCAST { return ev_is_simple_enough(op(c, 0)); }
    if o == OP_INTTOPTR || o == OP_PTRTOINT {
        if dl_size_bits(vals[c].ty) != dl_size_bits(vals[op(c, 0)].ty) { return false; }
        return ev_is_simple_enough(op(c, 0));
    }
    if o == OP_GEP {
        for j in 1..nops(c) { if vals[op(c, j)].kind != VK_CINT { return false; } }
        return ev_is_simple_enough(op(c, 0));
    }
    if o == OP_ADD {
        if vals[op(c, 1)].kind != VK_CINT { return false; }
        return ev_is_simple_enough(op(c, 0));
    }
    return false;
}

fn ev_new_mv(c: i32) -> i32 { ev_mvs.push(EvMv { c: c, agg: -1 }); return (ev_mvs.len - 1) as i32; }
fn ev_mv_type(mv: i32) -> i32 {
    let a = ev_mvs[mv].agg;
    if a < 0 { return vals[ev_mvs[mv].c].ty; }
    return ev_aggs[a].ty;
}
// MutableValue::toConstant
recursive fn ev_mv_to_constant(mv: i32) -> i32 {
    let a = ev_mvs[mv].agg;
    if a < 0 { return ev_mvs[mv].c; }
    let mark = ev_formals.len;
    let at = ev_aggs[a].at;
    let n = ev_aggs[a].n as i64;
    for k in n {
        let c = ev_mv_to_constant(ev_agg_elems[at + k]);
        ev_formals.push(c);
    }
    let r = c_aggregate(ev_aggs[a].ty, ev_formals[mark..]);
    ev_formals.resize(mark);
    return r;
}
// MutableValue::makeMutable
fn ev_make_mutable(mv: i32) -> bool {
    let c = ev_mvs[mv].c;
    let t: i32 = vals[c].ty;
    let k = ty_kind(t);
    var n: i64 = 0;
    if k == TK_FVEC || k == TK_ARRAY || k == TK_STRUCT { n = ty_count(t); } else { return false; }
    let at = ev_agg_elems.len as i32;
    for i in n { ev_agg_elems.push(-1); }
    for i in n {
        let e = c_aggregate_element(c, i);
        if e < 0 { ev_fail("an aggregate element of a constant expression"); }
        ev_agg_elems[at + i] = ev_new_mv(e);
    }
    ev_aggs.push(EvAgg { ty: t, at: at, n: n as i32 });
    ev_mvs[mv].agg = (ev_aggs.len - 1) as i32;
    ev_mvs[mv].c = -1;
    return true;
}
// DataLayout::getGEPIndexForOffset(ElemTy, Offset): (ok, index, new element type, new offset)
fn ev_gep_index_for_offset(t: i32, off: i64) -> bool, i64, i32, i64 {
    let k = ty_kind(t);
    if k == TK_ARRAY {
        let et = ty_elem(t);
        let sz = dl_alloc_size(et);
        if sz == 0 { return true, 0, et, off; }
        // getElementIndex: floor division of the signed offset
        var idx = off / sz;
        var rem = off - idx * sz;
        if rem < 0 { idx--; rem += sz; }
        return true, idx, et, rem;
    }
    if k == TK_FVEC || k == TK_SVEC { return false, 0, t, off; }
    if k == TK_STRUCT {
        if off < 0 { return false, 0, t, off; }
        let ssz = dl_struct_size(t);
        if off >= ssz { return false, 0, t, off; }
        var e: i64 = 0;
        let ne = ty_count(t);
        while e + 1 < ne && dl_struct_offset(t, e + 1) <= off { e++; }
        return true, e, ty_field(t, e), off - dl_struct_offset(t, e);
    }
    return false, 0, t, off;
}
// MutableValue::read(Ty, Offset)
fn ev_mv_read(mv0: i32, ty: i32, off0: i64) -> i32 {
    var mv = mv0;
    var off = off0;
    let ty_size = dl_store_size(ty);
    while ev_mvs[mv].agg >= 0 {
        let a = ev_mvs[mv].agg;
        let agg_ty = ev_aggs[a].ty;
        let ok, idx, et, noff = ev_gep_index_for_offset(agg_ty, off);
        if !ok || idx < 0 || idx >= ev_aggs[a].n as i64 || ty_size > dl_store_size(agg_ty) { return -1; }
        off = noff;
        mv = ev_agg_elems[ev_aggs[a].at + idx];
        let _ = et;
    }
    return cf_fold_load_from_const(ev_mvs[mv].c, ty, off);
}
// MutableValue::write(V, Offset)
fn ev_mv_write(mv0: i32, v: i32, off0: i64) -> bool {
    var mv = mv0;
    var off = off0;
    let ty: i32 = vals[v].ty;
    let ty_size = dl_store_size(ty);
    while off != 0 || !ld_is_bit_or_noop_ptr_castable_ev(ty, ev_mv_type(mv)) {
        if ev_mvs[mv].agg < 0 && !ev_make_mutable(mv) { return false; }
        let a = ev_mvs[mv].agg;
        let agg_ty = ev_aggs[a].ty;
        let ok, idx, et, noff = ev_gep_index_for_offset(agg_ty, off);
        if !ok || idx < 0 || idx >= ev_aggs[a].n as i64 || ty_size > dl_store_size(agg_ty) { return false; }
        off = noff;
        mv = ev_agg_elems[ev_aggs[a].at + idx];
        let _ = et;
    }
    let mvt = ev_mv_type(mv);
    ev_mvs[mv].agg = -1;
    if ty_kind(ty) == TK_INT && ty_kind(mvt) == TK_PTR { ev_mvs[mv].c = ce_cast(OP_INTTOPTR, v, mvt); }
    else if ty_kind(ty) == TK_PTR && ty_kind(mvt) == TK_INT { ev_mvs[mv].c = ce_cast(OP_PTRTOINT, v, mvt); }
    else if ty != mvt { ev_mvs[mv].c = ce_cast(OP_BITCAST, v, mvt); }
    else { ev_mvs[mv].c = v; }
    return true;
}
// CastInst::isBitOrNoopPointerCastable (loads.goose's port)
fn ld_is_bit_or_noop_ptr_castable_ev(s: i32, d: i32) -> bool { ld_is_bit_or_noop_ptr_castable(s, d) }

fn ev_mutated(gv: i32) -> i32 { let p = position(ev_mut_gv, gv); if p < 0 { -1 } else { ev_mut_mv[p] } }
// ComputeLoadResult(Constant *P, Type *Ty)
fn ev_compute_load_result_ptr(p0: i32, ty: i32) -> i32 {
    let p = strip_and_accumulate_offsets(p0, true, false, false);
    let off = vt_off;
    if vals[p].kind == VK_GVAR { return ev_compute_load_result(p, ty, off); }
    return -1;
}
// ComputeLoadResult(GlobalVariable *GV, Type *Ty, const APInt &Offset)
fn ev_compute_load_result(gv: i32, ty: i32, off: i64) -> i32 {
    let mv = ev_mutated(gv);
    if mv >= 0 { return ev_mv_read(mv, ty, off); }
    if !ig_has_definitive_initializer(gv) { return -1; }
    return cf_fold_load_from_const(ig_init(gv), ty, off);
}
// getFunction(C)
fn ev_get_function(c: i32) -> i32 {
    if c < 0 { return -1; }
    if vals[c].kind == VK_FUNC { return c; }
    if vals[c].kind == VK_ALIAS { let a = op(c, 0); if vals[a].kind == VK_FUNC { return a; } }
    return -1;
}

// EvaluateBlock(CurInst, NextBB, StrippedPointerCastsForAliasAnalysis): (ok, next block or -1, stripped)
recursive fn ev_evaluate_block(cur0: i32) -> bool, i32, bool {
    var cur = cur0;
    var stripped = false;
    loop {
        var res: i32 = -1;
        let o = iop(cur);
        if o == OP_STORE {
            if inst_is_volatile(cur) { return false, -1, stripped; }
            var ptr = ev_get_val(op(cur, 1));
            ptr = cf_fold_constant(ptr);
            ptr = strip_and_accumulate_offsets(ptr, true, false, false);
            let off = vt_off;
            if vals[ptr].kind != VK_GVAR || !ig_has_unique_initializer(ptr) { return false, -1, stripped; }
            let val = ev_get_val(op(cur, 0));
            if !ev_is_simple_enough(val) { return false, -1, stripped; }
            var mv = ev_mutated(ptr);
            if mv < 0 {
                mv = ev_new_mv(ig_init(ptr));
                ev_mut_gv.push(ptr);
                ev_mut_mv.push(mv);
            }
            if !ev_mv_write(mv, val, off) { return false, -1, stripped; }
        } else if o == OP_LOAD {
            if inst_is_volatile(cur) { return false, -1, stripped; }
            var ptr = ev_get_val(op(cur, 0));
            ptr = cf_fold_constant(ptr);
            res = ev_compute_load_result_ptr(ptr, vals[cur].ty);
            if res < 0 { return false, -1, stripped; }
        } else if o == OP_ALLOCA {
            // isArrayAllocation: the size operand is not the constant 1
            let sz = op(cur, 0);
            if !(vals[sz].kind == VK_CINT && cint_lo(sz) == 1) { return false, -1, stripped; }
            let ty = insts[inst_of(cur)].ty2;
            let m = globs[glob_of(inst_func(cur))].module;
            let tmp = ig_new_gvar(m, ty, false, LK_INTERNAL, c_undef(ty), 0, ptr_as(vals[cur].ty));
            ev_alloca_tmps.push(tmp);
            res = tmp;
        } else if o == OP_CALL || o == OP_INVOKE {
            let cb = cur;
            if vals[cb_callee(cb)].kind == VK_INLINEASM { return false, -1, stripped; }
            let id = inst_iid(cb);
            if id != 0 {
                if mi_is_memset(cb) {
                    if inst_is_volatile(cb) { return false, -1, stripped; }
                    let lenc = ev_get_val(cb_arg(cb, 2));
                    if vals[lenc].kind != VK_CINT { return false, -1, stripped; }
                    var ptr = ev_get_val(cb_arg(cb, 0));
                    ptr = strip_and_accumulate_offsets(ptr, true, false, false);
                    var off = vt_off;
                    if vals[ptr].kind != VK_GVAR { return false, -1, stripped; }
                    let val = ev_get_val(cb_arg(cb, 1));
                    if !is_null_value(val) || ev_mutated(ptr) >= 0 || !ig_has_definitive_initializer(ptr) || !is_null_value(ig_init(ptr)) {
                        let lap = ap_from_cint(lenc);
                        if ap_active_bits(lap) > 64 || ap_zext64(lap) > 64 * 1024 { return false, -1, stripped; }
                        var len = ap_zext64(lap);
                        while len != 0 {
                            let dv = ev_compute_load_result(ptr, vals[val].ty, off);
                            if dv != val { return false, -1, stripped; }
                            off++;
                            len--;
                        }
                    }
                    cur = inst_next(cur);
                    continue;
                }
                if id == IID_lifetime_start || id == IID_lifetime_end { cur = inst_next(cur); continue; }
                if id == IID_invariant_start {
                    if first_use(cb) >= 0 { return false, -1, stripped; }
                    let size = cb_arg(cb, 0);
                    let p = strip_pointer_casts(ev_get_val(cb_arg(cb, 1)));
                    if vals[p].kind == VK_GVAR {
                        let min_size = dl_alloc_size(globs[glob_of(p)].vty) as u64;
                        let sap = ap_from_cint(size);
                        if !ap_is_all_ones(sap) {
                            let lim = if ap_active_bits(sap) > 64 { 0xFFFFFFFFFFFFFFFF } else { ap_zext64(sap) };
                            if lim >= min_size { if position(ev_invariants, p) < 0 { ev_invariants.push(p); } }
                        }
                    }
                    cur = inst_next(cur);
                    continue;
                } else if id == IID_assume || id == IID_sideeffect || id == IID_pseudoprobe {
                    cur = inst_next(cur);
                    continue;
                } else {
                    let s = bas_strip(cur);
                    if s != cur { res = ev_get_val(s); }
                    if res >= 0 {
                        stripped = true;
                        res = ce_cast(OP_BITCAST, res, vals[cur].ty);
                    } else {
                        return false, -1, stripped;
                    }
                }
            }
            if res < 0 {
                // getCalleeWithFormalArgs
                let cv = strip_pointer_casts(cb_callee(cb));
                let callee = ev_get_function(ev_get_val(cv));
                if callee < 0 || globs[glob_of(callee)].vty != insts[inst_of(cb)].ty2 { return false, -1, stripped; }
                if gv_is_interposable(callee, true) { return false, -1, stripped; }
                let mark = ev_formals.len;
                for k in cb_nargs(cb) { let a = ev_get_val(cb_arg(cb, k)); ev_formals.push(a); }
                let nargs = ev_formals.len - mark;
                if ig_is_declaration(callee) {
                    let im = is_ops.len;
                    for k in nargs { is_ops.push(ev_formals[mark + k]); }
                    let c = cf_fold_call(cb, callee, im, nargs, true);
                    is_ops.resize(im);
                    ev_formals.resize(mark);
                    if c < 0 { return false, -1, stripped; }
                    res = c;
                } else {
                    if ty_fn_vararg(globs[glob_of(callee)].vty) { ev_formals.resize(mark); return false, -1, stripped; }
                    ev_push_frame();
                    let ok, rv = ev_evaluate_function(callee, mark, nargs);
                    ev_formals.resize(mark);
                    if !ok { return false, -1, stripped; }
                    ev_frames.pop();
                    res = rv;
                }
            }
        } else if is_terminator_op(o) {
            var next: i32 = -1;
            if o == OP_BR {
                next = term_succ(cur, 0);
            } else if o == OP_CONDBR {
                let c = ev_get_val(op(cur, 0));
                if c < 0 || vals[c].kind != VK_CINT { return false, -1, stripped; }
                next = term_succ(cur, if cint_lo(c) != 0 { 0 } else { 1 });
            } else if o == OP_SWITCH {
                let v = ev_get_val(op(cur, 0));
                if v < 0 || vals[v].kind != VK_CINT { return false, -1, stripped; }
                next = ev_switch_dest(cur, v);
            } else if o == OP_INDIRECTBR {
                let v = strip_pointer_casts(ev_get_val(op(cur, 0)));
                if vals[v].kind != VK_BLOCKADDR { return false, -1, stripped; }
                next = op(v, 1);
            } else if o == OP_RET {
                next = -1;
            } else {
                return false, -1, stripped;
            }
            return true, next, stripped;
        } else {
            let mark = is_ops.len;
            let n = nops(cur);
            for k in n { let x = ev_get_val(op(cur, k)); is_ops.push(x); }
            var bad = false;
            for k in n { if is_ops[mark + k] < 0 { bad = true; } }
            if !bad { res = cf_fold_inst_operands(cur, mark, n, true); }
            is_ops.resize(mark);
            if res < 0 { return false, -1, stripped; }
        }
        if first_use(cur) >= 0 {
            res = cf_fold_constant(res);
            ev_set_val(cur, res);
        }
        if o == OP_INVOKE { return true, invoke_normal_dest(cur), stripped; }
        cur = inst_next(cur);
    }
    return false, -1, stripped;
}
// SwitchInst::findCaseValue(C)->getCaseSuccessor()
fn ev_switch_dest(t: i32, c: i32) -> i32 {
    let n = nops(t);
    var k: i64 = 2;
    while k + 1 < n {
        if op(t, k) == c { return op(t, k + 1); }
        k += 2;
    }
    return op(t, 1);
}

// EvaluateFunction(F, RetVal, ActualArgs = ev_formals[mark..mark + n]): (ok, return value or -1)
recursive fn ev_evaluate_function(f: i32, mark: i64, n: i64) -> bool, i32 {
    if position(ev_call_stack, f) >= 0 { return false, -1; }
    ev_call_stack.push(f);
    for k in func_nargs(f) { ev_set_val(func_arg(f, k), ev_formals[mark + k]); }
    // ExecutedBlocks: blocks are marked by a set keyed by (frame serial, -2 - block)
    let frame = ev_frames[ev_frames.len - 1];
    var cur_bb = func_entry(f);
    var cur = block_first(cur_bb);
    loop {
        let ok, next, stripped = ev_evaluate_block(cur);
        if !ok { return false, -1; }
        if next < 0 {
            let ri = block_terminator(cur_bb);
            var rv: i32 = -1;
            if nops(ri) > 0 {
                if stripped && vals[op(ri, 0)].ty != T_VOID { return false, -1; }
                rv = ev_get_val(op(ri, 0));
            }
            ev_call_stack.pop();
            return true, rv;
        }
        let bk = hk2(frame, -2 - next);
        if hm_has(ev_vals, bk) { return false, -1; }
        hm_put(ev_vals, bk, 1);
        cur = block_first(next);
        while cur >= 0 && iop(cur) == OP_PHI {
            let pv = ev_get_val(phi_value(cur, phi_block_index(cur, cur_bb)));
            ev_set_val(cur, pv);
            cur = inst_next(cur);
        }
        cur_bb = next;
    }
    return false, -1;
}
