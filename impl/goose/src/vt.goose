// ValueTracking: ports from llvm/lib/Analysis/ValueTracking.cpp (isKnownNonZero, isKnownToBeAPowerOfTwo,
// isKnownNonEqual, ComputeNumSignBits, isKnownNegation, getUnderlyingObject(s), cmpExcludesZero,
// matchSimpleRecurrence, MaskedValueIsZero, getArgumentAliasingToReturnedPointer), plus
// Value::stripAndAccumulateConstantOffsets (llvm/lib/IR/Value.cpp) and instruction-level dominance
// (llvm/lib/IR/Dominators.cpp).
//
// The SimplifyQuery's context instruction is the global kb_cxt (knownbits.goose); callers set it.
// DominatorTree: always available (dt_get on the context's function). AssumptionCache: assumptions are
// not ported yet; every query that would consult the cache fails loudly when the function contains an
// llvm.assume (vt_check_assumes). DomConditionCache: not used by InstSimplify (Q.DC == nullptr).
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
import knownbits;
import implied;
import crange;
import pm;
import constfold;
import assume;

let VT_MAX_DEPTH = 6;

fn vt_not_ported(what: const u8[:]) { fatal(str("ValueTracking: ", what, " is not ported yet")); }

// The function a value lives in (instruction or argument), -1 for constants/globals.
fn value_func(v: i32) -> i32 {
    if is_inst(v) { return inst_func(v); }
    if is_arg(v) { return args_parent[vals[v].sub]; }
    return -1;
}

// AssumptionCache::assumptionsFor: not ported. Fail loudly if the function has assumptions.
var vt_assume_fn: i32 = -1;
var vt_assume_has: bool = false;
fn vt_fn_has_assumes(fv: i32) -> bool {
    if vt_assume_fn != fv {
        vt_assume_fn = fv;
        vt_assume_has = false;
        each_inst(fv) { i => if inst_iid(i) == IID_assume { vt_assume_has = true; } };
    }
    return vt_assume_has;
}
fn vt_invalidate_assumes() { vt_assume_fn = -1; }
fn vt_check_assumes(v: i32) {
    if kb_cxt < 0 { return; }
    if vt_fn_has_assumes(inst_func(kb_cxt)) { vt_not_ported("the assumption cache (llvm.assume)"); }
}

// ---------------------------------------------------------------------------------------------
// Dominance of instructions (DominatorTree::dominates overloads)

// SimplifyQuery members that may be null in LLVM (Q.DT / Q.AC / Q.TLI). Callers that build a query without them
// (e.g. SCCP: SimplifyQuery(DL, &I)) set these around the call; every place LLVM tests the member honors them.
var sq_no_dt: bool = false;
var sq_no_ac: bool = false;
var sq_no_tli: bool = false;

fn vt_fn_dt(fv: i32) { dt_get(fv, DT_DOM); }
fn block_reachable(bv: i32) -> bool { vt_fn_dt(block_func(bv)); return dt_has_node(DT_DOM, bv); }
fn dom_block(a: i32, b: i32) -> bool { vt_fn_dt(block_func(a)); return dt_dominates_block(DT_DOM, a, b); }
// Instruction::comesBefore (same block)
fn comes_before(a: i32, b: i32) -> bool {
    var x = inst_next(a);
    while x >= 0 { if x == b { return true; } x = inst_next(x); }
    return false;
}
// dominates(BasicBlockEdge(start, end), use_bb)
fn dom_edge(start: i32, end: i32, ubb: i32) -> bool {
    if !dom_block(end, ubb) { return false; }
    if single_pred(end) >= 0 { return true; }
    var dup = 0;
    var ok = true;
    each_pred(end) { p =>
        if p == start { dup++; }
        else if !dom_block(end, p) { ok = false; }
    };
    if dup > 1 { return false; }
    return ok;
}
// dominates(const Value *Def, const BasicBlock *UseBB)
fn dom_value_block(d: i32, ubb: i32) -> bool {
    if !is_inst(d) { return true; }
    let dbb = inst_parent(d);
    if dbb == ubb { return false; }
    if iop(d) == OP_INVOKE { return dom_edge(dbb, invoke_normal_dest(d), ubb); }
    if iop(d) == OP_CALLBR { return dom_edge(dbb, callbr_default_dest(d), ubb); }
    return dom_block(dbb, ubb);
}
// dominates(const Instruction *Def, const Instruction *User)
fn dom_inst(d: i32, u: i32) -> bool {
    let ubb = inst_parent(u);
    let dbb = inst_parent(d);
    if !block_reachable(ubb) { return true; }
    if !block_reachable(dbb) { return false; }
    if d == u { return false; }
    let o = iop(d);
    if o == OP_INVOKE || o == OP_CALLBR || iop(u) == OP_PHI { return dom_value_block(d, ubb); }
    if dbb != ubb { return dom_block(dbb, ubb); }
    return comes_before(d, u);
}

// NullPointerIsDefined(F, AS)
fn null_pointer_is_defined(fv: i32, as_: i64) -> bool {
    if fv >= 0 && func_has_fn_attr(fv, AK_NullPointerIsValid) { return true; }
    return as_ != 0;
}
fn ptr_as(t: i32) -> i64 { types[ty_scalar(t)].n as i64 }

// ---------------------------------------------------------------------------------------------
// Attribute queries

fn arg_attrs(a: i32) -> i32 {
    let f = args_parent[vals[a].sub];
    return alist_param(globs[glob_of(f)].attrs, args_no[vals[a].sub] as i64);
}
fn arg_has_attr(a: i32, k: i64) -> bool { aset_has(arg_attrs(a), k) }
// a range attribute as a CR (only for widths <= 64); returns false if none
var vt_cr: CR;
fn range_attr_cr(s: i32) -> bool {
    let at = aset_find(s, AK_Range);
    if at < 0 { return false; }
    let wi = attrs[at].i1 as i64;
    let bits = words[wi] as i64;
    if bits > 64 { vt_not_ported("a range attribute wider than 64 bits"); }
    let lo = words[wi + 1] as i32;
    let hi = words[wi + 2] as i32;
    vt_cr = cr_new(cint_lo(lo), cint_lo(hi), bits);
    return true;
}
// Argument::getRange
fn arg_range(a: i32) -> bool { range_attr_cr(arg_attrs(a)) }
// CallBase::getRange: call-site return attribute, then the callee's
fn call_range(c: i32) -> bool {
    if range_attr_cr(alist_ret(insts[inst_of(c)].attrs)) { return true; }
    let f = cb_callee(c);
    if is_func(f) && range_attr_cr(alist_ret(globs[glob_of(f)].attrs)) { return true; }
    return false;
}
// CallBase::paramHasAttr
fn call_param_has_attr(c: i32, k: i64, kind: i64) -> bool {
    if aset_has(alist_param(insts[inst_of(c)].attrs, k), kind) { return true; }
    let f = cb_callee(c);
    if is_func(f) && aset_has(alist_param(globs[glob_of(f)].attrs, k), kind) { return true; }
    return false;
}
fn call_ret_has_attr(c: i32, kind: i64) -> bool {
    if aset_has(alist_ret(insts[inst_of(c)].attrs), kind) { return true; }
    let f = cb_callee(c);
    if is_func(f) && aset_has(alist_ret(globs[glob_of(f)].attrs), kind) { return true; }
    return false;
}
// CallBase::getReturnedArgOperand
fn returned_arg_operand(c: i32) -> i32 {
    for k in cb_nargs(c) { if call_param_has_attr(c, k, AK_Returned) { return cb_arg(c, k); } }
    return -1;
}
// getArgumentAliasingToReturnedPointer
fn arg_aliasing_returned_ptr(c: i32, must_preserve_offset: bool) -> i32 {
    let rv = returned_arg_operand(c);
    if rv >= 0 { return rv; }
    let id = call_iid(c);
    if id == IID_launder_invariant_group || id == IID_strip_invariant_group { return cb_arg(c, 0); }
    if id == IID_ptrmask && !must_preserve_offset { return cb_arg(c, 0); }
    if id == IID_threadlocal_address {
        if func_has_fn_attr(inst_func(c), AK_PresplitCoroutine) { return -1; }
        return cb_arg(c, 0);
    }
    return -1;
}
// CallBase::isReturnNonNull
fn call_return_nonnull(c: i32) -> bool {
    if call_ret_has_attr(c, AK_NonNull) { return true; }
    let a = aset_find(alist_ret(insts[inst_of(c)].attrs), AK_Dereferenceable);
    var b = a;
    let f = cb_callee(c);
    if b < 0 && is_func(f) { b = aset_find(alist_ret(globs[glob_of(f)].attrs), AK_Dereferenceable); }
    if b >= 0 && attrs[b].i1 > 0 && !null_pointer_is_defined(inst_func(c), ptr_as(vals[c].ty)) { return true; }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Small helpers

// cmpExcludesZero
fn cmp_excludes_zero(p: i64, rhs: i32) -> bool {
    if p == P_UGT { return true; }
    if p == P_NE { return m_zero(rhs); }
    let c = m_apint(rhs);
    if c >= 0 {
        if ci_w(c) > 64 { pm_wide(); }
        let tv = cr_exact_icmp(p, ci_val(c), ci_w(c));
        return !cr_contains_val(tv, 0);
    }
    if vals[rhs].kind != VK_CDVECTOR { return false; }
    for i in nops(rhs) {
        let e = op(rhs, i);
        let tv = cr_exact_icmp(p, ci_val(e), ci_w(e));
        if cr_contains_val(tv, 0) { return false; }
    }
    return true;
}

// matchSimpleRecurrence(PHI): binop BO with the phi as an operand, Start, Step
var rec_bo: i32 = -1;
var rec_start: i32 = -1;
var rec_step: i32 = -1;
fn match_simple_recurrence(pn: i32) -> bool {
    if nops(pn) != 2 { return false; }
    for i in 2 {
        let o = op(pn, i);
        if is_inst(o) && is_binary_op(iop(o)) {
            let l = op(o, 0);
            let r = op(o, 1);
            if l != pn && r != pn { continue; }
            rec_bo = o;
            rec_start = op(pn, 1 - i);
            rec_step = if l == pn { r } else { l };
            return true;
        }
    }
    return false;
}

// isKnownNegation
fn is_negation_of(x: i32, y: i32, need_nsw: bool, allow_poison: bool) -> bool {
    if m_neg(x) != y || y < 0 { return false; }
    if need_nsw && !op_nsw(x) { return false; }
    if !allow_poison && !is_null_value(op(x, 0)) { return false; }
    return true;
}
fn is_known_negation(x: i32, y: i32, need_nsw: bool, allow_poison: bool) -> bool {
    if is_negation_of(x, y, need_nsw, allow_poison) || is_negation_of(y, x, need_nsw, allow_poison) { return true; }
    if !is_op(x, OP_SUB) || !is_op(y, OP_SUB) { return false; }
    let a = op(x, 0);
    let b = op(x, 1);
    if op(y, 0) != b || op(y, 1) != a { return false; }
    if !need_nsw { return true; }
    return op_nsw(x) && op_nsw(y);
}

// getUnderlyingObject(V, MaxLookup)
fn get_underlying_object(v0: i32, max_lookup: i64) -> i32 {
    var v = v0;
    var count = 0;
    while max_lookup == 0 || count < max_lookup {
        count++;
        let o = opcode_of(v);
        if o == OP_GEP {
            let p = op(v, 0);
            if ty_kind(vals[p].ty) != TK_PTR { return v; }
            v = p;
        } else if o == OP_BITCAST || o == OP_ADDRSPACECAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if vals[v].kind == VK_ALIAS {
            let l = globs[glob_of(v)].linkage as i64;
            // GlobalValue::isInterposable
            if l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK ||
               ((l == LK_EXTERNAL || l == LK_AVAILABLE_EXTERNALLY) && globs[glob_of(v)].dso_local == 0 && false) { return v; }
            if l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return v; }
            v = op(v, 0);
        } else {
            if is_inst_op(v, OP_PHI) {
                if nops(v) == 1 { v = op(v, 0); continue; }
            } else if is_callbase(v) {
                let rp = arg_aliasing_returned_ptr(v, false);
                if rp >= 0 { v = rp; continue; }
            }
            return v;
        }
    }
    return v;
}

// getUnderlyingObjects (no LoopInfo): pushes the objects (in LLVM's order) onto out; uses VS_ANA1.
fn get_underlying_objects(v: i32, out: i32[>..<]&) {
    var wl: i32[>..<] = [];
    var seen: i32[>..<] = [];
    wl.push(v);
    while wl.len > 0 {
        let p0 = wl.pop();
        let p = get_underlying_object(p0, 6);
        var dup = false;
        for s in seen { if s == p { dup = true; } }
        if dup { continue; }
        seen.push(p);
        if is_inst_op(p, OP_SELECT) { wl.push(op(p, 1)); wl.push(op(p, 2)); continue; }
        if is_inst_op(p, OP_PHI) { for k in nops(p) { wl.push(op(p, k)); } continue; }
        out.push(p);
    }
}

// Value::stripAndAccumulateConstantOffsets(DL, Offset, AllowNonInbounds, AllowInvariantGroup,
// ExternalAnalysis = null, LookThroughIntToPtr). Offsets are 64-bit (index width <= 64).
var vt_off: i64 = 0;
fn gep_accumulate_constant_offset(g: i32) -> bool, i64 {
    // GEPOperator::accumulateConstantOffset: all indices must be constant
    var t = gep_src_ty(g);
    var off: i64 = 0;
    if ty_contains_scalable(t) { return false, 0; }
    for k in 1..nops(g) {
        let ix = op(g, k);
        if k == 1 {
            let c = m_apint(ix);
            if c < 0 { if is_constant(ix) && is_null_value(ix) { continue; } return false, 0; }
            off += ci_sval(c) * dl_alloc_size(t);
            continue;
        }
        if ty_is_struct(t) {
            let c = m_apint(ix);
            if c < 0 { return false, 0; }
            let fi = ci_val(c) as i64;
            off += dl_struct_offset(t, fi);
            t = ty_field(t, fi);
        } else {
            let et = types[t].a;
            let c = m_apint(ix);
            if c < 0 { if is_constant(ix) && is_null_value(ix) { t = et; continue; } return false, 0; }
            if ty_kind(t) == TK_SVEC { return false, 0; }
            off += ci_sval(c) * dl_alloc_size(et);
            t = et;
        }
    }
    return true, off;
}
fn gep_src_ty(g: i32) -> i32 {
    if vals[g].kind == VK_INST { return insts[inst_of(g)].ty2; }
    return csts[vals[g].sub].ty2;
}
fn gep_flags(g: i32) -> u8 { op_flags(g) }
fn strip_and_accumulate_offsets(v0: i32, allow_non_inbounds: bool, allow_invariant_group: bool, look_through_inttoptr: bool) -> i32 {
    vt_off = 0;
    if !is_ptr_or_ptr_vec(vals[v0].ty) { return v0; }
    var v = v0;
    var bitw = dl_ptr(ptr_as(vals[v0].ty)).idx;
    if bitw > 64 { vt_not_ported("index widths over 64 bits"); }
    var gcount = 0;
    while gcount < 100000 {
        gcount++;
        let o = opcode_of(v);
        if o == OP_GEP {
            if !allow_non_inbounds && (gep_flags(v) & GEP_INBOUNDS) == 0 { return v; }
            // Only scalar pointer base
            let ok, off = gep_accumulate_constant_offset(v);
            if !ok { return v; }
            // GEPOffset must fit the index width (APInt arithmetic wraps)
            vt_off = sext64(((vt_off + off) as! u64) & wmask64(bitw), bitw);
            v = op(v, 0);
        } else if o == OP_BITCAST || o == OP_ADDRSPACECAST {
            if o == OP_ADDRSPACECAST {
                let nb = dl_ptr(ptr_as(vals[op(v, 0)].ty)).idx;
                if nb != bitw { vt_not_ported("addrspacecast between index widths"); }
            }
            v = op(v, 0);
        } else if vals[v].kind == VK_ALIAS {
            let l = globs[glob_of(v)].linkage as i64;
            if l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return v; }
            v = op(v, 0);
        } else if is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv >= 0 { v = rv; continue; }
            if allow_invariant_group {
                let id = call_iid(v);
                if id == IID_launder_invariant_group || id == IID_strip_invariant_group { v = cb_arg(v, 0); continue; }
            }
            return v;
        } else if look_through_inttoptr && o == OP_INTTOPTR {
            vt_not_ported("stripAndAccumulateConstantOffsets through inttoptr");
            return v;
        } else {
            return v;
        }
        if !is_ptr_or_ptr_vec(vals[v].ty) { return v; }
    }
    return v;
}

// ---------------------------------------------------------------------------------------------
// isKnownNonZero

fn all_elts_of(v: i32) -> u64 {
    let t = vals[v].ty;
    if ty_kind(t) == TK_FVEC {
        let n = ty_count(t);
        if n > 64 { vt_not_ported("vectors of more than 64 elements"); }
        return wmask64(n);
    }
    return 1;
}

recursive fn is_known_non_zero(v: i32, depth: i64) -> bool { ikz(v, all_elts_of(v), depth) }

recursive fn ikz(v: i32, de: u64, depth0: i64) -> bool {
    var depth = depth0;
    let ty = vals[v].ty;
    let k = vals[v].kind;
    if is_constant(v) {
        if is_null_value(v) { return false; }
        if k == VK_CINT { return true; }
        if ty_kind(ty) == TK_FVEC {
            for i in ty_count(ty) {
                if ((de >> i) & 1) == 0 { continue; }
                let e = agg_elem(v, i);
                if e < 0 || is_null_value(e) { return false; }
                if vals[e].kind != VK_POISON && vals[e].kind != VK_CINT { return false; }
            }
            return true;
        }
        if k == VK_PTRAUTH { vt_not_ported("isKnownNonZero of ptrauth constants"); }
        if is_global(v) {
            // !isAbsoluteSymbolRef() && !hasExternalWeakLinkage() && addrspace 0
            let g = globs[glob_of(v)];
            if g.linkage as i64 != LK_EXTERN_WEAK && g.addrspace == 0 {
                if glob_has_absolute_symbol(v) { return false; }
                return true;
            }
        }
        if k != VK_CEXPR { return false; }
    }
    if k == VK_ARG && arg_range(v) {
        if !cr_contains_val(vt_cr, 0) { return true; }
    }
    if !is_constant(v) && nonzero_from_assume(v) { return true; }
    if depth >= VT_MAX_DEPTH { return false; }
    depth++;
    if ty_kind(ty) == TK_PTR && k == VK_ARG {
        let f = args_parent[vals[v].sub];
        let pass_by_val = arg_has_attr(v, AK_ByVal) || arg_has_attr(v, AK_InAlloca) || arg_has_attr(v, AK_Preallocated);
        if (pass_by_val && !null_pointer_is_defined(f, ptr_as(ty))) || arg_has_attr(v, AK_NonNull) { return true; }
    }
    if k == VK_INST || k == VK_CEXPR {
        if ikz_operator(v, de, depth) { return true; }
    }
    if !is_constant(v) && nonnull_from_dominating_condition(v) { return true; }
    let st = strip_null_test(v);
    if st >= 0 { return ikz(st, de, depth); }
    return false;
}

fn glob_has_absolute_symbol(v: i32) -> bool {
    // GlobalValue::isAbsoluteSymbolRef: !absolute_symbol metadata on a global object
    let g = globs[glob_of(v)];
    let kid = md_kind_id("absolute_symbol");
    for i in g.nmd { if md_att[g.md + 2 * i] == kid { return true; } }
    return false;
}

// stripNullTest: (X >> C) or/add zext((X & mask(C)) != 0) -> X
fn strip_null_test(v: i32) -> i32 {
    if !is_inst(v) { return -1; }
    let o = iop(v);
    if o != OP_ADD && o != OP_OR { return -1; }
    for side in 2 {
        let sh = op(v, side);
        let ze = op(v, 1 - side);
        if !is_op(sh, OP_LSHR) { continue; }
        let x = op(sh, 0);
        let c1 = m_apint(op(sh, 1));
        if c1 < 0 || !is_op(ze, OP_ZEXT) { continue; }
        let c = op(ze, 0);
        if !is_inst_op(c, OP_ICMP) || inst_pred(c) != P_NE || !m_zero(op(c, 1)) { continue; }
        let a = op(c, 0);
        if !is_op(a, OP_AND) || op(a, 0) != x { continue; }
        let c2 = m_apint(op(a, 1));
        if c2 < 0 || !m_low_bit_mask(op(a, 1)) { continue; }
        if popcount(ci_val(c2)) == ci_val(c1) as i64 { return x; }
    }
    return -1;
}

recursive fn ikz_gep(g: i32, depth0: i64) -> bool {
    var depth = depth0;
    let f = if is_inst(g) { inst_func(g) } else { -1 };
    let fl = gep_flags(g);
    if (fl & GEP_NUW) == 0 && !((fl & GEP_INBOUNDS) != 0 && !null_pointer_is_defined(f, ptr_as(vals[g].ty))) { return false; }
    if is_known_non_zero(op(g, 0), depth) { return true; }
    var t = gep_src_ty(g);
    for k in 1..nops(g) {
        let ix = op(g, k);
        if k > 1 && ty_is_struct(t) {
            let fi = ci_val(m_constant_int(ix)) as i64;
            if dl_struct_offset(t, fi) > 0 { return true; }
            t = ty_field(t, fi);
            continue;
        }
        let et = if k == 1 { t } else { types[t].a };
        if k > 1 { t = et; }
        if dl_alloc_size(et) == 0 { continue; }
        let c = m_constant_int(ix);
        if c >= 0 { if !cint_is_zero(c) { return true; } continue; }
        if depth >= VT_MAX_DEPTH { depth++; continue; }
        depth++;
        if is_known_non_zero(ix, depth) { return true; }
    }
    return false;
}

// isKnownNonNullFromDominatingCondition
recursive fn nonnull_from_dominating_condition(v: i32) -> bool {
    let cx = kb_cxt;
    if cx < 0 || sq_no_dt { return false; }
    if !has_use_list(v) { return false; }
    let is_ptr = ty_kind(vals[v].ty) == TK_PTR;
    var nexp = 0;
    var u = vals[v].first_use;
    while u >= 0 {
        if nexp >= 20 { break; }
        nexp++;
        let ui = uses[u].user;
        let uno = u - vals[ui].ops;
        let nxt = uses[u].next;
        if !is_inst(ui) { u = nxt; continue; }
        if is_ptr && is_callbase(ui) {
            if uno < cb_nargs(ui) && call_param_has_attr(ui, uno, AK_NonNull) && call_param_has_attr(ui, uno, AK_NoUndef) && dom_inst(ui, cx) { return true; }
        }
        let uo = iop(ui);
        if (uo == OP_LOAD && op(ui, 0) == v) || (uo == OP_STORE && op(ui, 1) == v) {
            if !null_pointer_is_defined(inst_func(ui), ptr_as(vals[v].ty)) && dom_inst(ui, cx) { return true; }
        }
        if (uo == OP_UDIV || uo == OP_SDIV || uo == OP_UREM || uo == OP_SREM) && op(ui, 1) == v {
            if is_valid_assume_for_context(ui, cx) { return true; }
        }
        if uo != OP_ICMP { u = nxt; continue; }
        var p = inst_pred(ui);
        var rhs = op(ui, 1);
        if op(ui, 0) != v { p = pred_swapped(p); rhs = op(ui, 0); }
        var nonnull_if_true = false;
        if cmp_excludes_zero(p, rhs) { nonnull_if_true = true; }
        else if cmp_excludes_zero(pred_inverse(p), rhs) { nonnull_if_true = false; }
        else { u = nxt; continue; }
        // worklist over the users of the compare
        var visited: i32[>..<] = [];
        var wl: i32[>..<] = [];
        var cu = vals[ui].first_use;
        while cu >= 0 {
            let cuser = uses[cu].user;
            var seen = false;
            for x in visited { if x == cuser { seen = true; } }
            if !seen { visited.push(cuser); wl.push(cuser); }
            while wl.len > 0 {
                let cur = wl.pop();
                if nonnull_if_true && m_logical(cur, true) {
                    var cu2 = vals[cur].first_use;
                    while cu2 >= 0 {
                        let us2 = uses[cu2].user;
                        var s2 = false;
                        for x in visited { if x == us2 { s2 = true; } }
                        if !s2 { visited.push(us2); wl.push(us2); }
                        cu2 = uses[cu2].next;
                    }
                    continue;
                }
                if is_inst_op(cur, OP_CONDBR) {
                    let succ = op(cur, if nonnull_if_true { 1 } else { 2 });
                    if dom_edge(inst_parent(cur), succ, inst_parent(cx)) { return true; }
                } else if nonnull_if_true && inst_iid(cur) == IID_experimental_guard && dom_inst(cur, cx) {
                    return true;
                }
            }
            cu = uses[cu].next;
        }
        u = nxt;
    }
    return false;
}

fn is_valid_assume_for_context(inv: i32, cx: i32) -> bool { valid_assume_for_context(inv, cx) }

// isGuaranteedToTransferExecutionToSuccessor(const Instruction *I)
fn guaranteed_to_transfer(i: i32) -> bool {
    let o = iop(i);
    if o == OP_RET || o == OP_UNREACHABLE { return false; }
    if o == OP_CATCHPAD { vt_not_ported("isGuaranteedToTransferExecutionToSuccessor of catchpad (EH personality)"); }
    return !inst_may_throw(i) && inst_will_return(i);
}

fn match_op_with_op_eq_zero(a: i32, b: i32) -> bool {
    fn one(x: i32, y: i32) -> bool {
        if !is_op(x, OP_ZEXT) && !is_op(x, OP_SEXT) { return false; }
        let c = op(x, 0);
        return is_inst_op(c, OP_ICMP) && inst_pred(c) == P_EQ && op(c, 0) == y && m_zero(op(c, 1));
    }
    return one(a, b) || one(b, a);
}

recursive fn is_non_zero_add(de: u64, w: i64, x: i32, y: i32, nsw: bool, nuw: bool, depth: i64) -> bool {
    if match_op_with_op_eq_zero(x, y) { return true; }
    if nuw { return ikz(y, de, depth) || ikz(x, de, depth); }
    let xk = kb_compute(x, de, depth);
    let yk = kb_compute(y, de, depth);
    if kb_is_nonneg(xk) && kb_is_nonneg(yk) {
        if ikz(y, de, depth) || ikz(x, de, depth) { return true; }
    }
    if kb_is_neg(xk) && kb_is_neg(yk) {
        let mask = sbit64(w) - 1;
        if (xk.o & mask) != 0 { return true; }
        if (yk.o & mask) != 0 { return true; }
    }
    if kb_is_nonneg(xk) && is_known_pow2(y, false, depth) { return true; }
    if kb_is_nonneg(yk) && is_known_pow2(x, false, depth) { return true; }
    return kb_is_nonzero(kb_add_sub(true, nsw, nuw, xk, yk));
}

recursive fn is_non_zero_sub(de: u64, w: i64, x: i32, y: i32, depth: i64) -> bool {
    if match_op_with_op_eq_zero(x, y) { return true; }
    if is_constant(x) && is_null_value(x) && ikz(y, de, depth) { return true; }
    return ikne(x, y, de, depth);
}

recursive fn is_non_zero_mul(de: u64, w: i64, x: i32, y: i32, nsw: bool, nuw: bool, depth: i64) -> bool {
    if nsw || nuw { return ikz(x, de, depth) && ikz(y, de, depth); }
    let xk = kb_compute(x, de, depth);
    if (xk.o & 1) != 0 { return ikz(y, de, depth); }
    let yk = kb_compute(y, de, depth);
    if (yk.o & 1) != 0 { return kb_is_nonzero(xk) || ikz(x, de, depth); }
    return kb_max_tz(xk) + kb_max_tz(yk) < w;
}

fn shift_op_val(o: i64, x: u64, s: i64, w: i64) -> u64 {
    if s >= w { return 0; }
    if o == OP_SHL { return (x << s) & wmask64(w); }
    if o == OP_LSHR { return x >> s; }
    return ((sext64(x, w) >> s) as! u64) & wmask64(w);
}
fn inv_shift_op_val(o: i64, x: u64, s: i64, w: i64) -> u64 {
    if s >= w { return 0; }
    if o == OP_SHL { return x >> s; }
    return (x << s) & wmask64(w);
}

recursive fn is_non_zero_shift(i: i32, de: u64, kv: KB, depth: i64) -> bool {
    if kb_is_unknown(kv) { return false; }
    let kc = kb_compute(op(i, 1), de, depth);
    let maxs = kb_max(kc);
    let nb = kv.w as i64;
    if maxs >= nb as u64 { return false; }
    let o = opcode_of(i);
    let ms = maxs as i64;
    if shift_op_val(o, kv.o, ms, nb) != 0 { return true; }
    if inv_shift_op_val(o, kv.z, nb - ms, nb) == inv_shift_op_val(o, wmask64(nb), nb - ms, nb) && ikz(op(i, 0), de, depth) { return true; }
    return false;
}

fn int_bit_width(t: i32) -> i64 {
    let s = ty_scalar(t);
    if ty_kind(s) == TK_PTR { return dl_ptr(types[s].n as i64).bits; }
    return ty_bits(s);
}

recursive fn ikz_operator(i: i32, de: u64, depth: i64) -> bool {
    let w = int_bit_width(vals[i].ty);
    let o = opcode_of(i);
    let is_i = is_inst(i);
    if o == OP_ALLOCA { return ptr_as(vals[i].ty) == 0; }
    if o == OP_GEP { if ty_kind(vals[i].ty) == TK_PTR { return ikz_gep(i, depth); } }
    else if o == OP_BITCAST {
        let ft = vals[op(i, 0)].ty;
        if (is_int_or_int_vec(ft) || is_ptr_or_ptr_vec(ft)) && (w % int_bit_width(ft)) == 0 { return is_known_non_zero(op(i, 0), depth); }
    } else if o == OP_INTTOPTR {
        if !is_scalable_vec(vals[i].ty) && dl_size_bits(vals[op(i, 0)].ty) <= dl_size_bits(vals[i].ty) { return ikz(op(i, 0), de, depth); }
    } else if o == OP_PTRTOADDR {
        return ikz(op(i, 0), de, depth);
    } else if o == OP_PTRTOINT {
        if dl_ptr(ptr_as(vals[op(i, 0)].ty)).idx <= w {
            // getAddressSizeInBits == index size for x86
            return ikz(op(i, 0), de, depth);
        }
    } else if o == OP_TRUNC {
        if is_i && (op_nsw(i) || op_nuw(i)) { return ikz(op(i, 0), de, depth); }
    } else if o == OP_XOR || o == OP_SUB {
        return is_non_zero_sub(de, w, op(i, 0), op(i, 1), depth);
    } else if o == OP_OR {
        if match_op_with_op_eq_zero(op(i, 0), op(i, 1)) { return true; }
        if ikne(op(i, 0), op(i, 1), de, depth) { return true; }
        return ikz(op(i, 1), de, depth) || ikz(op(i, 0), de, depth);
    } else if o == OP_SEXT || o == OP_ZEXT {
        return ikz(op(i, 0), de, depth);
    } else if o == OP_SHL {
        if op_nuw(i) || op_nsw(i) { return ikz(op(i, 0), de, depth); }
        let kn = kb_compute(op(i, 0), de, depth);
        if (kn.o & 1) != 0 { return true; }
        return is_non_zero_shift(i, de, kn, depth);
    } else if o == OP_LSHR || o == OP_ASHR {
        if op_exact(i) { return ikz(op(i, 0), de, depth); }
        let kn = kb_compute(op(i, 0), de, depth);
        if kb_is_neg(kn) { return true; }
        let a0 = op(i, 0);
        let c = m_apint(op(i, 1));
        if depth + 1 < VT_MAX_DEPTH && is_op(a0, OP_ADD) && op_nuw(a0) && c >= 0 && ci_val(c) < w as u64 {
            let ka = kb_compute(op(a0, 0), de, depth + 1);
            if (ka.o >> ci_val(c)) != 0 { return true; }
            let kb2 = kb_compute(op(a0, 1), de, depth + 1);
            if (kb2.o >> ci_val(c)) != 0 { return true; }
        }
        return is_non_zero_shift(i, de, kn, depth);
    } else if o == OP_UDIV || o == OP_SDIV {
        if op_exact(i) { return ikz(op(i, 0), de, depth); }
        var xk = kb_compute(op(i, 0), de, depth);
        if kb_is_unknown(xk) { return false; }
        var yk = kb_compute(op(i, 1), de, depth);
        if o == OP_SDIV { xk = kb_abs(xk, false); yk = kb_abs(yk, false); }
        return kb_uge(xk, yk) == 1;
    } else if o == OP_ADD {
        return is_non_zero_add(de, w, op(i, 0), op(i, 1), op_nsw(i), op_nuw(i), depth);
    } else if o == OP_MUL {
        return is_non_zero_mul(de, w, op(i, 0), op(i, 1), op_nsw(i), op_nuw(i), depth);
    } else if o == OP_SELECT {
        if select_arm_nonzero(i, true, de, depth) && select_arm_nonzero(i, false, de, depth) { return true; }
    } else if o == OP_PHI {
        if match_simple_recurrence(i) && is_non_zero_recurrence() { return true; }
        let nd = max(depth, VT_MAX_DEPTH - 1);
        let save = kb_cxt;
        for k in nops(i) {
            let iv = op(i, k);
            if iv == i { continue; }
            let term = block_terminator(phi_block(i, k));
            kb_cxt = term;
            var ok = false;
            if is_inst_op(term, OP_CONDBR) && is_inst_op(op(term, 0), OP_ICMP) {
                let c = op(term, 0);
                var p = inst_pred(c);
                var x: i32 = -1;
                if op(c, 0) == iv { x = op(c, 1); } else if op(c, 1) == iv { x = op(c, 0); p = pred_swapped(p); }
                if x >= 0 {
                    let ts = op(term, 1);
                    let fs = op(term, 2);
                    let pb = inst_parent(i);
                    if (ts == pb) != (fs == pb) {
                        if fs == pb { p = pred_inverse(p); }
                        if cmp_excludes_zero(p, x) { ok = true; }
                    }
                }
            }
            if !ok { ok = ikz(iv, de, nd); }
            if !ok { kb_cxt = save; return false; }
        }
        kb_cxt = save;
        return true;
    } else if o == OP_INSERTELEMENT {
        if is_scalable_vec(vals[i].ty) { return kb_nonzero_fallback(i, de, depth); }
        let vec = op(i, 0);
        let elt = op(i, 1);
        let ci = m_constant_int(op(i, 2));
        var dv = de;
        var skip = false;
        let n = ty_count(vals[i].ty);
        if ci >= 0 && ci_val(ci) < n as u64 {
            let ix = ci_val(ci) as i64;
            dv &= ~((1 as u64) << ix);
            skip = ((de >> ix) & 1) == 0;
        }
        return (skip || is_known_non_zero(elt, depth)) && (dv == 0 || ikz(vec, dv, depth));
    } else if o == OP_EXTRACTELEMENT {
        if is_i {
            let vec = op(i, 0);
            let ci = m_constant_int(op(i, 1));
            if ty_kind(vals[vec].ty) == TK_FVEC {
                let n = ty_count(vals[vec].ty);
                var dv = wmask64(n);
                if ci >= 0 && ci_val(ci) < n as u64 { dv = (1 as u64) << ci_val(ci); }
                return ikz(vec, dv, depth);
            }
        }
    } else if o == OP_SHUFFLEVECTOR {
        if is_i {
            let ok, dl, dr = shuffle_demanded(i, de);
            if ok {
                return (dr == 0 || ikz(op(i, 1), dr, depth)) && (dl == 0 || ikz(op(i, 0), dl, depth));
            }
        }
    } else if o == OP_FREEZE {
        return is_known_non_zero(op(i, 0), depth) && guaranteed_not_poison_hook(op(i, 0), depth);
    } else if o == OP_LOAD {
        if ty_kind(vals[i].ty) == TK_PTR {
            if inst_get_md(i, md_kind_id("nonnull")) >= 0 ||
               (inst_get_md(i, md_kind_id("dereferenceable")) >= 0 && !null_pointer_is_defined(inst_func(i), ptr_as(vals[i].ty))) { return true; }
        } else {
            let rm = inst_get_md(i, md_kind_id("range"));
            if rm >= 0 { return range_md_excludes(rm, 0); }
        }
        return false;
    } else if o == OP_EXTRACTVALUE {
        let agg = op(i, 0);
        let x = insts[inst_of(i)];
        if x.naux == 1 && ints[x.aux] == 0 {
            let id = inst_iid(agg);
            if id == IID_uadd_with_overflow || id == IID_sadd_with_overflow { return is_non_zero_add(de, w, cb_arg(agg, 0), cb_arg(agg, 1), false, false, depth); }
            if id == IID_usub_with_overflow || id == IID_ssub_with_overflow { return is_non_zero_sub(de, w, cb_arg(agg, 0), cb_arg(agg, 1), depth); }
            if id == IID_umul_with_overflow || id == IID_smul_with_overflow { return is_non_zero_mul(de, w, cb_arg(agg, 0), cb_arg(agg, 1), false, false, depth); }
        }
    } else if o == OP_CALL || o == OP_INVOKE {
        if ty_kind(vals[i].ty) == TK_PTR {
            if call_return_nonnull(i) { return true; }
            let rp = arg_aliasing_returned_ptr(i, true);
            if rp >= 0 { return is_known_non_zero(rp, depth); }
        } else {
            let rm = inst_get_md(i, md_kind_id("range"));
            if rm >= 0 { return range_md_excludes(rm, 0); }
            if call_range(i) { if !cr_contains_val(vt_cr, 0) { return true; } }
            let rv = returned_arg_operand(i);
            if rv >= 0 && vals[rv].ty == vals[i].ty && is_known_non_zero(rv, depth) { return true; }
        }
        let id = call_iid(i);
        if id != 0 {
            if id == IID_sshl_sat || id == IID_ushl_sat || id == IID_abs || id == IID_bitreverse || id == IID_bswap || id == IID_ctpop {
                return ikz(cb_arg(i, 0), de, depth);
            }
            if id == IID_ssub_sat {
                if w == 1 { return false; }
                return is_non_zero_sub(de, w, cb_arg(i, 0), cb_arg(i, 1), depth);
            }
            if id == IID_sadd_sat { return is_non_zero_add(de, w, cb_arg(i, 0), cb_arg(i, 1), true, false, depth); }
            if id == IID_vector_reverse { vt_not_ported("isKnownNonZero of vector.reverse"); }
            if id == IID_vector_reduce_or || id == IID_vector_reduce_umax || id == IID_vector_reduce_umin ||
               id == IID_vector_reduce_smax || id == IID_vector_reduce_smin { return is_known_non_zero(cb_arg(i, 0), depth); }
            if id == IID_umax || id == IID_uadd_sat {
                if match_op_with_op_eq_zero(cb_arg(i, 0), cb_arg(i, 1)) { return true; }
                return ikz(cb_arg(i, 1), de, depth) || ikz(cb_arg(i, 0), de, depth);
            }
            if id == IID_smax {
                let a0 = cb_arg(i, 0);
                let a1 = cb_arg(i, 1);
                let k1 = kb_compute(a1, de, depth);
                var nz1 = -1;
                if kb_is_nonneg(k1) {
                    nz1 = if kb_is_nonzero(k1) || ikz(a1, de, depth) { 1 } else { 0 };
                    if nz1 == 1 { return true; }
                }
                let k0 = kb_compute(a0, de, depth);
                var nz0 = -1;
                if kb_is_nonneg(k0) {
                    nz0 = if kb_is_nonzero(k0) || ikz(a0, de, depth) { 1 } else { 0 };
                    if nz0 == 1 { return true; }
                }
                if nz1 < 0 { nz1 = if kb_is_nonzero(k1) || ikz(a1, de, depth) { 1 } else { 0 }; }
                if nz1 == 0 { return false; }
                if nz0 < 0 { nz0 = if kb_is_nonzero(k0) || ikz(a0, de, depth) { 1 } else { 0 }; }
                return nz0 == 1;
            }
            if id == IID_smin {
                let k1 = kb_compute(cb_arg(i, 1), de, depth);
                if kb_is_neg(k1) { return true; }
                let k0 = kb_compute(cb_arg(i, 0), de, depth);
                if kb_is_neg(k0) { return true; }
                if kb_is_nonzero(k1) && kb_is_nonzero(k0) { return true; }
                return ikz(cb_arg(i, 0), de, depth) && ikz(cb_arg(i, 1), de, depth);
            }
            if id == IID_umin { return ikz(cb_arg(i, 0), de, depth) && ikz(cb_arg(i, 1), de, depth); }
            if id == IID_cttz { return (kb_compute(cb_arg(i, 0), de, depth).z & 1) != 0; }
            if id == IID_ctlz { return kb_is_nonneg(kb_compute(cb_arg(i, 0), de, depth)); }
            if id == IID_fshr || id == IID_fshl {
                if cb_arg(i, 0) == cb_arg(i, 1) { return ikz(cb_arg(i, 0), de, depth); }
                return false;
            }
            if id == IID_vscale { return true; }
            if id == IID_experimental_get_vector_length { return is_known_non_zero(op(i, 0), depth); }
            return false;
        }
        return false;
    }
    return kb_nonzero_fallback(i, de, depth);
}

recursive fn kb_nonzero_fallback(i: i32, de: u64, depth: i64) -> bool {
    let k = kb_compute(i, de, depth);
    return k.o != 0;
}

// Hook to isGuaranteedNotToBePoison (poison.goose)
recursive fn guaranteed_not_poison_hook(v: i32, depth: i64) -> bool { is_guaranteed_not_to_be_poison(v, kb_cxt, depth) }

fn range_md_excludes(md: i32, x: u64) -> bool {
    let n = mds[md].nops as i64 / 2;
    for i in n {
        let lo = mds[md_op(md, 2 * i)].extra;
        let hi = mds[md_op(md, 2 * i + 1)].extra;
        let w = ci_w(lo);
        if w > 64 { pm_wide(); }
        let r = cr_new(cint_lo(lo), cint_lo(hi), w);
        if cr_contains_val(r, x) { return false; }
    }
    return true;
}

fn is_non_zero_recurrence() -> bool {
    let sc = m_apint(rec_start);
    if sc < 0 || ci_val(sc) == 0 { return false; }
    let bo = rec_bo;
    let o = iop(bo);
    if o == OP_ADD {
        if op_nuw(bo) { return true; }
        let st = m_apint(rec_step);
        return op_nsw(bo) && st >= 0 && ((ci_val(sc) & sbit64(ci_w(sc))) != 0) == ((ci_val(st) & sbit64(ci_w(st))) != 0);
    }
    if o == OP_MUL {
        let st = m_apint(rec_step);
        return (op_nuw(bo) || op_nsw(bo)) && st >= 0 && ci_val(st) != 0;
    }
    if o == OP_SHL { return op_nuw(bo) || op_nsw(bo); }
    if o == OP_ASHR || o == OP_LSHR { return op_exact(bo); }
    return false;
}

recursive fn select_arm_nonzero(i: i32, true_arm: bool, de: u64, depth: i64) -> bool {
    let a = op(i, if true_arm { 1 } else { 2 });
    if ikz(a, de, depth) { return true; }
    let c = op(i, 0);
    if !is_op(c, OP_ICMP) { return false; }
    var p = cmp_pred_of(c);
    var x: i32 = -1;
    if op(c, 0) == a { x = op(c, 1); } else if op(c, 1) == a { x = op(c, 0); p = pred_swapped(p); }
    if x < 0 { return false; }
    if !true_arm { p = pred_inverse(p); }
    return cmp_excludes_zero(p, x);
}
fn cmp_pred_of(c: i32) -> i64 { if is_inst(c) { inst_pred(c) } else { csts[vals[c].sub].pred as i64 } }

// getShuffleDemandedElts: ok, demanded LHS, demanded RHS
fn shuffle_demanded(i: i32, de: u64) -> bool, u64, u64 {
    let x = insts[inst_of(i)];
    let a = op(i, 0);
    if ty_kind(vals[a].ty) != TK_FVEC { return false, 0, 0; }
    let nin = ty_count(vals[a].ty);
    var dl: u64 = 0;
    var dr: u64 = 0;
    for k in x.naux {
        if ((de >> k) & 1) == 0 { continue; }
        let mv = ints[x.aux + k] as i64;
        if mv < 0 { return false, 0, 0; }
        if mv < nin { dl |= (1 as u64) << mv; } else { dr |= (1 as u64) << (mv - nin); }
    }
    return true, dl, dr;
}

// ---------------------------------------------------------------------------------------------
// isKnownToBeAPowerOfTwo

recursive fn is_known_pow2(v: i32, or_zero: bool, depth0: i64) -> bool {
    var depth = depth0;
    if is_constant(v) {
        if or_zero { return m_cint_pred(v, IP_POWER2_OR_ZERO, true); }
        return m_power2(v);
    }
    if or_zero && scalar_bits(v) == 1 { return true; }
    if kb_cxt >= 0 && pow2_from_assume(v, or_zero) { return true; }
    if !is_inst(v) { return false; }
    if kb_cxt >= 0 && inst_iid(v) == IID_vscale { return func_has_fn_attr(inst_func(kb_cxt), AK_VScaleRange); }
    let o = iop(v);
    if o == OP_SHL && m_one(op(v, 0)) { return true; }
    if o == OP_LSHR && m_sign_mask(op(v, 0)) { return true; }
    if depth == VT_MAX_DEPTH { return false; }
    depth++;
    if o == OP_ZEXT { return is_known_pow2(op(v, 0), or_zero, depth); }
    if o == OP_TRUNC { return or_zero && is_known_pow2(op(v, 0), or_zero, depth); }
    if o == OP_SHL { if or_zero || op_nuw(v) || op_nsw(v) { return is_known_pow2(op(v, 0), or_zero, depth); } return false; }
    if o == OP_LSHR { if or_zero || op_exact(v) { return is_known_pow2(op(v, 0), or_zero, depth); } return false; }
    if o == OP_UDIV { if op_exact(v) { return is_known_pow2(op(v, 0), or_zero, depth); } return false; }
    if o == OP_MUL {
        return is_known_pow2(op(v, 1), or_zero, depth) && is_known_pow2(op(v, 0), or_zero, depth) && (or_zero || is_known_non_zero(v, depth));
    }
    if o == OP_AND {
        if or_zero && (is_known_pow2(op(v, 1), true, depth) || is_known_pow2(op(v, 0), true, depth)) { return true; }
        if m_neg(op(v, 0)) == op(v, 1) || m_neg(op(v, 1)) == op(v, 0) { return or_zero || is_known_non_zero(op(v, 0), depth); }
        return false;
    }
    if o == OP_ADD {
        let a = op(v, 0);
        let b = op(v, 1);
        if or_zero || op_nuw(v) || op_nsw(v) {
            if m_c_binop_with(a, OP_AND, b) >= 0 && is_known_pow2(b, or_zero, depth) { return true; }
            if m_c_binop_with(b, OP_AND, a) >= 0 && is_known_pow2(a, or_zero, depth) { return true; }
            let lk = kb_compute_all(a, depth);
            let rk = kb_compute_all(b, depth);
            let nz = ~(lk.z & rk.z) & wmask64(lk.w as i64);
            if nz != 0 && (nz & (nz - 1)) == 0 {
                if or_zero || rk.o != 0 || lk.o != 0 { return true; }
            }
        }
        if or_zero || op_nuw(v) {
            if is_op(a, OP_LSHR) && m_all_ones(op(a, 0)) && m_one(b) { return true; }
        }
        return false;
    }
    if o == OP_SELECT { return is_known_pow2(op(v, 1), or_zero, depth) && is_known_pow2(op(v, 2), or_zero, depth); }
    if o == OP_PHI {
        let save = kb_cxt;
        if pow2_recurrence(v, or_zero, depth) { kb_cxt = save; return true; }
        let nd = max(depth, VT_MAX_DEPTH - 1);
        for k in nops(v) {
            let iv = op(v, k);
            if iv == v { continue; }
            kb_cxt = block_terminator(phi_block(v, k));
            if !is_known_pow2(iv, or_zero, nd) { kb_cxt = save; return false; }
        }
        kb_cxt = save;
        return true;
    }
    if o == OP_CALL || o == OP_INVOKE {
        let id = call_iid(v);
        if id == IID_umax || id == IID_smax || id == IID_umin || id == IID_smin {
            return is_known_pow2(cb_arg(v, 1), or_zero, depth) && is_known_pow2(cb_arg(v, 0), or_zero, depth);
        }
        if id == IID_bitreverse || id == IID_bswap { return is_known_pow2(cb_arg(v, 0), or_zero, depth); }
        if id == IID_fshr || id == IID_fshl {
            if cb_arg(v, 0) == cb_arg(v, 1) { return is_known_pow2(cb_arg(v, 0), or_zero, depth); }
        }
        return false;
    }
    return false;
}

recursive fn pow2_recurrence(pn: i32, or_zero: bool, depth: i64) -> bool {
    if !match_simple_recurrence(pn) { return false; }
    let bo = rec_bo;
    let start = rec_start;
    let step = rec_step;
    for k in nops(pn) {
        if op(pn, k) == start {
            kb_cxt = block_terminator(phi_block(pn, k));
            if !is_known_pow2(start, or_zero, depth) { return false; }
        }
    }
    let o = iop(bo);
    if o != OP_MUL && op(bo, 1) != step { return false; }
    kb_cxt = block_terminator(inst_parent(bo));
    if o == OP_MUL { return (or_zero || op_nuw(bo) || op_nsw(bo)) && is_known_pow2(step, or_zero, depth); }
    if o == OP_SDIV {
        if !m_power2(start) || m_sign_mask(start) { return false; }
        return (or_zero || op_exact(bo)) && is_known_pow2(step, false, depth);
    }
    if o == OP_UDIV { return (or_zero || op_exact(bo)) && is_known_pow2(step, false, depth); }
    if o == OP_SHL { return or_zero || op_nuw(bo) || op_nsw(bo); }
    if o == OP_ASHR {
        if !m_power2(start) || m_sign_mask(start) { return false; }
        return or_zero || op_exact(bo);
    }
    if o == OP_LSHR { return or_zero || op_exact(bo); }
    return false;
}

// ---------------------------------------------------------------------------------------------
// isKnownNonEqual

recursive fn is_known_non_equal(a: i32, b: i32, depth: i64) -> bool { ikne(a, b, all_elts_of(a), depth) }

// getInvertibleOperands: ok, first, second
recursive fn invertible_operands(o1: i32, o2: i32) -> bool, i32, i32 {
    let o = opcode_of(o1);
    if o != opcode_of(o2) { return false, -1, -1; }
    if o == OP_OR || o == OP_XOR || o == OP_ADD {
        if o == OP_OR && (!op_disjoint(o1) || !op_disjoint(o2)) { return false, -1, -1; }
        let x = m_c_binop_with(o2, o, op(o1, 0));
        if x >= 0 { return true, op(o1, 1), x; }
        let y = m_c_binop_with(o2, o, op(o1, 1));
        if y >= 0 { return true, op(o1, 0), y; }
        return false, -1, -1;
    }
    if o == OP_SUB {
        if op(o1, 0) == op(o2, 0) { return true, op(o1, 1), op(o2, 1); }
        if op(o1, 1) == op(o2, 1) { return true, op(o1, 0), op(o2, 0); }
        return false, -1, -1;
    }
    if o == OP_MUL {
        if (!op_nuw(o1) || !op_nuw(o2)) && (!op_nsw(o1) || !op_nsw(o2)) { return false, -1, -1; }
        let c = op(o1, 1);
        if c == op(o2, 1) && m_constant_int(c) >= 0 && !cint_is_zero(c) { return true, op(o1, 0), op(o2, 0); }
        return false, -1, -1;
    }
    if o == OP_SHL {
        if (!op_nuw(o1) || !op_nuw(o2)) && (!op_nsw(o1) || !op_nsw(o2)) { return false, -1, -1; }
        if op(o1, 1) == op(o2, 1) { return true, op(o1, 0), op(o2, 0); }
        return false, -1, -1;
    }
    if o == OP_ASHR || o == OP_LSHR {
        if !op_exact(o1) || !op_exact(o2) { return false, -1, -1; }
        if op(o1, 1) == op(o2, 1) { return true, op(o1, 0), op(o2, 0); }
        return false, -1, -1;
    }
    if o == OP_SEXT || o == OP_ZEXT {
        if vals[op(o1, 0)].ty == vals[op(o2, 0)].ty { return true, op(o1, 0), op(o2, 0); }
        return false, -1, -1;
    }
    if o == OP_PHI && is_inst(o1) && is_inst(o2) {
        if inst_parent(o1) != inst_parent(o2) { return false, -1, -1; }
        if !match_simple_recurrence(o1) { return false, -1, -1; }
        let bo1 = rec_bo;
        let s1 = rec_start;
        if !match_simple_recurrence(o2) { return false, -1, -1; }
        let bo2 = rec_bo;
        let s2 = rec_start;
        let ok, f, s = invertible_operands(bo1, bo2);
        if !ok { return false, -1, -1; }
        if f != o1 || s != o2 { return false, -1, -1; }
        return true, s1, s2;
    }
    return false, -1, -1;
}

recursive fn modifying_binop_of_nonzero(v1: i32, v2: i32, de: u64, depth: i64) -> bool {
    if !is_inst(v1) { return false; }
    let o = iop(v1);
    if o == OP_OR && !op_disjoint(v1) { return false; }
    if o != OP_OR && o != OP_XOR && o != OP_ADD { return false; }
    var x: i32 = -1;
    if v2 == op(v1, 0) { x = op(v1, 1); } else if v2 == op(v1, 1) { x = op(v1, 0); } else { return false; }
    return ikz(x, de, depth + 1);
}
recursive fn non_equal_mul(v1: i32, v2: i32, de: u64, depth: i64) -> bool {
    if !is_op(v2, OP_MUL) { return false; }
    let c = m_apint(op(v2, 1));
    return op(v2, 0) == v1 && c >= 0 && (op_nuw(v2) || op_nsw(v2)) && ci_val(c) != 0 && ci_val(c) != 1 && ikz(v1, de, depth + 1);
}
recursive fn non_equal_shl(v1: i32, v2: i32, de: u64, depth: i64) -> bool {
    if !is_op(v2, OP_SHL) { return false; }
    let c = m_apint(op(v2, 1));
    return op(v2, 0) == v1 && c >= 0 && (op_nuw(v2) || op_nsw(v2)) && ci_val(c) != 0 && ikz(v1, de, depth + 1);
}
recursive fn non_equal_phis(p1: i32, p2: i32, de: u64, depth: i64) -> bool {
    if inst_parent(p1) != inst_parent(p2) { return false; }
    var used_full = false;
    let save = kb_cxt;
    for k in nops(p1) {
        let bb = phi_block(p1, k);
        var dup = false;
        for j in k { if phi_block(p1, j) == bb { dup = true; } }
        if dup { continue; }
        let iv1 = op(p1, k);
        let j2 = phi_block_index(p2, bb);
        let iv2 = op(p2, j2);
        let c1 = m_apint(iv1);
        let c2 = m_apint(iv2);
        if c1 >= 0 && c2 >= 0 && ci_val(c1) != ci_val(c2) { continue; }
        if used_full { kb_cxt = save; return false; }
        kb_cxt = block_terminator(bb);
        if !ikne(iv1, iv2, de, depth + 1) { kb_cxt = save; return false; }
        used_full = true;
    }
    kb_cxt = save;
    return true;
}
recursive fn non_equal_select(v1: i32, v2: i32, de: u64, depth: i64) -> bool {
    if !is_inst_op(v1, OP_SELECT) { return false; }
    if is_inst_op(v2, OP_SELECT) {
        if op(v1, 0) == op(v2, 0) {
            return ikne(op(v1, 1), op(v2, 1), de, depth + 1) && ikne(op(v1, 2), op(v2, 2), de, depth + 1);
        }
    }
    return ikne(op(v1, 1), v2, de, depth + 1) && ikne(op(v1, 2), v2, de, depth + 1);
}
fn non_equal_ptrs_recursive_gep(a: i32, b: i32) -> bool {
    if ty_kind(vals[a].ty) != TK_PTR || ty_kind(vals[b].ty) != TK_PTR { return false; }
    if !is_op(a, OP_GEP) || nops(a) != 2 || !is_constant(op(a, 1)) { return false; }
    let pn = op(a, 0);
    if !is_inst_op(pn, OP_PHI) || nops(pn) != 2 { return false; }
    var start: i32 = -1;
    if op(pn, 0) == a { start = op(pn, 1); } else if op(pn, 1) == a { start = op(pn, 0); } else { return false; }
    let s = strip_and_accumulate_offsets(start, false, false, false);
    let so = vt_off;
    let st = strip_and_accumulate_offsets(a, false, false, false);
    let sto = vt_off;
    if st != pn { return false; }
    let bb = strip_and_accumulate_offsets(b, false, false, false);
    let ob = vt_off;
    return s == bb && ((so >= ob && sto > 0) || (so <= ob && sto < 0));
}

recursive fn ikne(v1: i32, v2: i32, de: u64, depth: i64) -> bool {
    if v1 == v2 { return false; }
    if vals[v1].ty != vals[v2].ty { return false; }
    if depth >= VT_MAX_DEPTH { return false; }
    let o1 = opcode_of(v1);
    if o1 >= 0 && o1 == opcode_of(v2) {
        let ok, a, b = invertible_operands(v1, v2);
        if ok { return ikne(a, b, de, depth + 1); }
        if is_inst_op(v1, OP_PHI) {
            if non_equal_phis(v1, v2, de, depth) { return true; }
        }
    }
    if modifying_binop_of_nonzero(v1, v2, de, depth) || modifying_binop_of_nonzero(v2, v1, de, depth) { return true; }
    if non_equal_mul(v1, v2, de, depth) || non_equal_mul(v2, v1, de, depth) { return true; }
    if non_equal_shl(v1, v2, de, depth) || non_equal_shl(v2, v1, de, depth) { return true; }
    if is_int_or_int_vec(vals[v1].ty) {
        let k1 = kb_compute(v1, de, depth);
        if !kb_is_unknown(k1) {
            let k2 = kb_compute(v2, de, depth);
            if (k1.z & k2.o) != 0 || (k2.z & k1.o) != 0 { return true; }
        }
    }
    if non_equal_select(v1, v2, de, depth) || non_equal_select(v2, v1, de, depth) { return true; }
    if non_equal_ptrs_recursive_gep(v1, v2) || non_equal_ptrs_recursive_gep(v2, v1) { return true; }
    // m_PtrToIntSameSize
    if is_op(v1, OP_PTRTOINT) && is_op(v2, OP_PTRTOINT) {
        let a = op(v1, 0);
        let b = op(v2, 0);
        if dl_size_bits(vals[v1].ty) == dl_size_bits(vals[a].ty) && dl_size_bits(vals[v2].ty) == dl_size_bits(vals[b].ty) {
            return ikne(a, b, de, depth + 1);
        }
    }
    // isKnownNonEqualFromContext: no DC; assumptions
    if kb_cxt >= 0 && nonequal_from_assume(v1, v2, depth) { return true; }
    return false;
}

// ---------------------------------------------------------------------------------------------
// ComputeNumSignBits

fn num_sign_bits_of(x: u64, w: i64) -> i64 {
    if (x & sbit64(w)) != 0 { return clo_w(x, w); }
    return clz_w(x, w);
}

recursive fn num_sign_bits(v: i32, depth: i64) -> i64 { ncsb(v, all_elts_of(v), depth) }

recursive fn ncsb(v: i32, de: u64, depth: i64) -> i64 {
    let tb = int_bit_width(vals[v].ty);
    var first_answer: i64 = 1;
    if depth == VT_MAX_DEPTH { return 1; }
    let o = opcode_of(v);
    if o >= 0 {
        if o == OP_BITCAST {
            let src = op(v, 0);
            let st = vals[src].ty;
            if is_int_or_int_vec(st) {
                let sb = ty_scalar_bits(st);
                if (sb % tb) == 0 && ty_kind(vals[v].ty) == TK_FVEC {
                    let t = num_sign_bits(src, depth + 1);
                    if t == sb { return tb; }
                }
            }
        } else if o == OP_SEXT {
            let t = tb - ty_scalar_bits(vals[op(v, 0)].ty);
            return ncsb(op(v, 0), de, depth + 1) + t;
        } else if o == OP_SDIV {
            let d = m_apint(op(v, 1));
            if d >= 0 {
                let dv = ci_val(d);
                let dw = ci_w(d);
                if dv != 0 && (dv & sbit64(dw)) == 0 {
                    let nb = ncsb(op(v, 0), de, depth + 1);
                    return min(tb, nb + (63 - clz(dv)));
                }
            }
        } else if o == OP_SREM {
            var t = ncsb(op(v, 0), de, depth + 1);
            let d = m_apint(op(v, 1));
            if d >= 0 {
                let dv = ci_val(d);
                let dw = ci_w(d);
                if dv != 0 && (dv & sbit64(dw)) == 0 {
                    let cl = if dv == 1 { 0 } else { 64 - clz(dv - 1) };
                    t = max(t, tb - cl);
                }
            }
            return t;
        } else if o == OP_ASHR {
            var t = ncsb(op(v, 0), de, depth + 1);
            let sh = m_apint(op(v, 1));
            if sh >= 0 {
                if ci_val(sh) >= tb as u64 { return ncsb_fallback(v, de, depth, first_answer, tb); }
                t += ci_val(sh) as i64;
                if t > tb { t = tb; }
            }
            return t;
        } else if o == OP_SHL {
            let sh = m_apint(op(v, 1));
            if sh >= 0 {
                if ci_val(sh) < tb as u64 {
                    let s = ci_val(sh) as i64;
                    var t: i64 = 0;
                    let a0 = op(v, 0);
                    if is_op(a0, OP_ZEXT) && s >= tb - ty_scalar_bits(vals[op(a0, 0)].ty) {
                        let x = op(a0, 0);
                        t = ncsb(x, de, depth + 1) + tb - ty_scalar_bits(vals[x].ty);
                    } else {
                        t = ncsb(a0, de, depth + 1);
                    }
                    if s < t { return t - s; }
                }
            }
        } else if o == OP_AND || o == OP_OR || o == OP_XOR {
            let t = ncsb(op(v, 0), de, depth + 1);
            if t != 1 {
                let t2 = ncsb(op(v, 1), de, depth + 1);
                first_answer = min(t, t2);
            }
        } else if o == OP_SELECT {
            if is_signed_minmax_clamp_select(v) { vt_not_ported("ComputeNumSignBits of a clamp select"); }
            let t = ncsb(op(v, 1), de, depth + 1);
            if t != 1 {
                let t2 = ncsb(op(v, 2), de, depth + 1);
                return min(t, t2);
            }
        } else if o == OP_ADD {
            let t = num_sign_bits(op(v, 0), depth + 1);
            if t != 1 {
                var done = false;
                let r = op(v, 1);
                if is_constant(r) && is_all_ones_value(r) {
                    let kn = kb_compute(op(v, 0), de, depth + 1);
                    if (kn.z | 1) == wmask64(tb) { return tb; }
                    if kb_is_nonneg(kn) { return t; }
                }
                if !done {
                    let t2 = ncsb(op(v, 1), de, depth + 1);
                    if t2 != 1 { return min(t, t2) - 1; }
                }
            }
        } else if o == OP_SUB {
            let t2 = ncsb(op(v, 1), de, depth + 1);
            if t2 != 1 {
                let l = op(v, 0);
                var negdone = false;
                if is_constant(l) && is_null_value(l) {
                    let kn = kb_compute(op(v, 1), de, depth + 1);
                    if (kn.z | 1) == wmask64(tb) { return tb; }
                    if kb_is_nonneg(kn) { return t2; }
                }
                let t = ncsb(op(v, 0), de, depth + 1);
                if t != 1 { return min(t, t2) - 1; }
            }
        } else if o == OP_MUL {
            let s0 = ncsb(op(v, 0), de, depth + 1);
            if s0 != 1 {
                let s1 = ncsb(op(v, 1), de, depth + 1);
                if s1 != 1 {
                    let ovb = (tb - s0 + 1) + (tb - s1 + 1);
                    return if ovb > tb { 1 } else { tb - ovb + 1 };
                }
            }
        } else if o == OP_PHI {
            let n = nops(v);
            if n <= 4 && n != 0 {
                let save = kb_cxt;
                var t = tb;
                for k in n {
                    if t == 1 { kb_cxt = save; return t; }
                    kb_cxt = block_terminator(phi_block(v, k));
                    t = min(t, ncsb(op(v, k), de, depth + 1));
                }
                kb_cxt = save;
                return t;
            }
        } else if o == OP_TRUNC {
            let t = num_sign_bits(op(v, 0), depth + 1);
            let otb = ty_scalar_bits(vals[op(v, 0)].ty);
            if t > otb - tb { return t - (otb - tb); }
            return 1;
        } else if o == OP_EXTRACTELEMENT {
            return num_sign_bits(op(v, 0), depth + 1);
        } else if o == OP_SHUFFLEVECTOR {
            if !is_inst(v) { return 1; }
            let ok, dl, dr = shuffle_demanded(v, de);
            if !ok { return 1; }
            var t: i64 = 0x7FFFFFFF;
            if dl != 0 { t = ncsb(op(v, 0), dl, depth + 1); }
            if t != 1 {
                if dr != 0 { t = min(t, ncsb(op(v, 1), dr, depth + 1)); }
                if t != 1 { return t; }
            }
        } else if o == OP_CALL {
            let id = call_iid(v);
            if id == IID_abs {
                let t = ncsb(op(v, 0), de, depth + 1);
                if t != 1 { return t - 1; }
            } else if id == IID_smin || id == IID_smax {
                if is_signed_minmax_intrinsic_clamp(v) { vt_not_ported("ComputeNumSignBits of a smin/smax clamp"); }
            }
        }
    }
    return ncsb_fallback(v, de, depth, first_answer, tb);
}

recursive fn ncsb_fallback(v: i32, de: u64, depth: i64, first_answer: i64, tb: i64) -> i64 {
    // computeNumSignBitsVectorConstant
    if is_constant(v) && ty_kind(vals[v].ty) == TK_FVEC {
        var minb = tb;
        var ok = true;
        for i in ty_count(vals[v].ty) {
            if ((de >> i) & 1) == 0 { continue; }
            let e = agg_elem(v, i);
            if e < 0 || vals[e].kind != VK_CINT { ok = false; break; }
            minb = min(minb, num_sign_bits_of(ci_val(e), tb));
        }
        if ok && minb != 0 { return minb; }
    }
    let k = kb_compute(v, de, depth);
    return max(first_answer, kb_min_sign_bits(k));
}

fn kb_min_sign_bits(k: KB) -> i64 {
    let w = k.w as i64;
    if kb_is_nonneg(k) { return kb_min_lz(k); }
    if kb_is_neg(k) { return kb_min_lo(k); }
    return 1;
}

// isSignedMinMaxClamp (select form): select (icmp slt/sgt ...) patterns
fn is_signed_minmax_clamp_select(v: i32) -> bool {
    // matchSelectPattern-based; detect smin(smax(X, lo), hi) shapes built from selects
    let t = op(v, 1);
    let f = op(v, 2);
    return (m_minmax(v, 0) || m_minmax(v, 1)) && (m_apint(t) >= 0 || m_apint(f) >= 0) &&
           (is_inst_op(t, OP_SELECT) || is_inst_op(f, OP_SELECT));
}
fn is_signed_minmax_intrinsic_clamp(v: i32) -> bool {
    let inner = op(v, 0);
    let id = call_iid(v);
    let inv = if id == IID_smin { IID_smax } else { IID_smin };
    return inst_iid(inner) == inv && m_apint(op(v, 1)) >= 0 && m_apint(op(inner, 1)) >= 0;
}

// MaskedValueIsZero(V, Mask)
fn masked_value_is_zero(v: i32, mask: u64, depth: i64) -> bool {
    let k = kb_compute_all(v, depth);
    return (mask & k.z) == mask;
}

// ---------------------------------------------------------------------------------------------
// Select patterns (matchSelectPattern / matchDecomposedSelectPattern) for integer compares.

let SPF_UNKNOWN = 0;
let SPF_SMIN = 1;
let SPF_UMIN = 2;
let SPF_SMAX = 3;
let SPF_UMAX = 4;
let SPF_FMINNUM = 5;
let SPF_FMAXNUM = 6;
let SPF_ABS = 7;
let SPF_NABS = 8;
var sp_lhs: i32 = -1;
var sp_rhs: i32 = -1;

fn spf_is_minmax(f: i64) -> bool { f >= SPF_SMIN && f <= SPF_FMAXNUM }
fn spf_minmax_pred(f: i64) -> i64 {
    match f { 1 => P_SLT, 2 => P_ULT, 3 => P_SGT, 4 => P_UGT, _ => -1 }
}
fn spf_inverse(f: i64) -> i64 { match f { 1 => SPF_SMAX, 3 => SPF_SMIN, 2 => SPF_UMAX, 4 => SPF_UMIN, 5 => SPF_FMAXNUM, 6 => SPF_FMINNUM, _ => f } }
// getMinMaxLimit
fn spf_limit(f: i64, w: i64) -> u64 {
    if f == SPF_UMAX { return wmask64(w); }
    if f == SPF_UMIN { return 0; }
    if f == SPF_SMAX { return sbit64(w) - 1; }
    return sbit64(w);
}

// matchSelectPattern(V, LHS, RHS, CastOp = nullptr, Depth)
recursive fn match_select_pattern_v(v: i32, depth: i64) -> i64 {
    if depth >= VT_MAX_DEPTH { return SPF_UNKNOWN; }
    if !is_inst_op(v, OP_SELECT) { return SPF_UNKNOWN; }
    let c = op(v, 0);
    if is_inst_op(c, OP_ICMP) {
        let p = inst_pred(c);
        if p == P_EQ || p == P_NE { return SPF_UNKNOWN; }
        return match_select_pattern_int(p, op(c, 0), op(c, 1), op(v, 1), op(v, 2), depth);
    }
    if is_inst_op(c, OP_FCMP) {
        // FP flavors never combine with the integer flavors the callers here look for.
        return SPF_UNKNOWN;
    }
    return SPF_UNKNOWN;
}

fn is_sext_or_mul_of(v: i32, x: i32) -> bool {
    fn lhs_or_sext(a: i32, x: i32) -> bool { a == x || (is_op(a, OP_SEXT) && op(a, 0) == x) }
    if lhs_or_sext(v, x) { return true; }
    if is_op(v, OP_MUL) && op_nsw(v) && lhs_or_sext(op(v, 0), x) && m_cint_pred(op(v, 1), IP_STRICTLYPOS, true) { return true; }
    if is_op(v, OP_SHL) && op_nsw(v) && lhs_or_sext(op(v, 0), x) { return true; }
    return false;
}

recursive fn match_select_pattern_int(p0: i64, cl0: i32, cr0: i32, tv: i32, fv: i32, depth: i64) -> i64 {
    var p = p0;
    var cl = cl0;
    var cr = cr0;
    sp_lhs = cl;
    sp_rhs = cr;
    if tv == cr && fv == cl { let t = cl; cl = cr; cr = t; p = pred_swapped(p); }
    if tv == cl && fv == cr {
        return match p { 34 => SPF_UMAX, 35 => SPF_UMAX, 38 => SPF_SMAX, 39 => SPF_SMAX, 36 => SPF_UMIN, 37 => SPF_UMIN, 40 => SPF_SMIN, 41 => SPF_SMIN, _ => SPF_UNKNOWN };
    }
    if is_known_negation(tv, fv, false, true) {
        let zero_or_ones = m_zero_int(cr) || m_all_ones(cr);
        let zero_or_one = m_zero_int(cr) || m_one(cr);
        if is_sext_or_mul_of(tv, cl) {
            sp_lhs = tv;
            sp_rhs = fv;
            if m_neg(cl) == fv && fv >= 0 { sp_lhs = fv; sp_rhs = tv; }
            if p == P_SGT && zero_or_ones { return SPF_ABS; }
            if p == P_SGE && zero_or_one { return SPF_ABS; }
            if p == P_SLT && zero_or_one { return SPF_NABS; }
        } else if is_sext_or_mul_of(fv, cl) {
            sp_lhs = fv;
            sp_rhs = tv;
            if m_neg(cl) == tv && tv >= 0 { sp_lhs = tv; sp_rhs = fv; }
            if p == P_SGT && zero_or_ones { return SPF_NABS; }
            if p == P_SLT && zero_or_one { return SPF_ABS; }
        }
    }
    return match_minmax_int(p, cl, cr, tv, fv, depth);
}

fn not_value_of(v: i32) -> i32 {
    let x = m_not(v);
    if x >= 0 { return x; }
    let c = m_apint(v);
    if c >= 0 { return c_int_ty(vals[v].ty, ~ci_val(c)); }
    return -1;
}

recursive fn match_minmax_int(p: i64, cl: i32, cr: i32, tv: i32, fv: i32, depth: i64) -> i64 {
    sp_lhs = tv;
    sp_rhs = fv;
    // matchClamp
    {
        var pp = p;
        var t = tv;
        var f = fv;
        if cr != t { pp = pred_swapped(pp); let x = t; t = f; f = x; }
        let c1 = m_apint(cr);
        if cr == t && c1 >= 0 {
            let w = ci_w(c1);
            let v1 = ci_val(c1);
            fn mm_c2(f: i32, kind: i64, x: i32) -> i32 {
                if !m_minmax(f, kind) { return -1; }
                if mm_a != x { return -1; }
                return m_apint(mm_b);
            }
            let c2a = mm_c2(f, 1, cl);
            if c2a >= 0 && sext64(v1, w) < sext64(ci_val(c2a), w) && pp == P_SLT { return SPF_SMAX; }
            let c2b = mm_c2(f, 0, cl);
            if c2b >= 0 && sext64(v1, w) > sext64(ci_val(c2b), w) && pp == P_SGT { return SPF_SMIN; }
            let c2c = mm_c2(f, 3, cl);
            if c2c >= 0 && v1 < ci_val(c2c) && pp == P_ULT { return SPF_UMAX; }
            let c2d = mm_c2(f, 2, cl);
            if c2d >= 0 && v1 > ci_val(c2d) && pp == P_UGT { return SPF_UMIN; }
        }
    }
    // matchMinMaxOfMinMax
    {
        let lf = match_select_pattern_v(tv, depth + 1);
        let a = sp_lhs;
        let b = sp_rhs;
        if spf_is_minmax(lf) {
            let rf = match_select_pattern_v(fv, depth + 1);
            let c = sp_lhs;
            let d = sp_rhs;
            if lf == rf {
                var pp = p;
                var x = cl;
                var y = cr;
                var ok = false;
                if lf == SPF_SMIN { if pp == P_SGT || pp == P_SGE { pp = pred_swapped(pp); let t = x; x = y; y = t; } ok = pp == P_SLT || pp == P_SLE; }
                else if lf == SPF_SMAX { if pp == P_SLT || pp == P_SLE { pp = pred_swapped(pp); let t = x; x = y; y = t; } ok = pp == P_SGT || pp == P_SGE; }
                else if lf == SPF_UMIN { if pp == P_UGT || pp == P_UGE { pp = pred_swapped(pp); let t = x; x = y; y = t; } ok = pp == P_ULT || pp == P_ULE; }
                else if lf == SPF_UMAX { if pp == P_ULT || pp == P_ULE { pp = pred_swapped(pp); let t = x; x = y; y = t; } ok = pp == P_UGT || pp == P_UGE; }
                if ok {
                    fn nots(p1: i32, q1: i32, x: i32, y: i32) -> bool { m_not(p1) == x && x >= 0 && m_not(q1) == y && y >= 0 }
                    var res = SPF_UNKNOWN;
                    if d == b && ((x == a && y == c) || nots(c, a, x, y)) { res = lf; }
                    else if c == b && ((x == a && y == d) || nots(d, a, x, y)) { res = lf; }
                    else if d == a && ((x == b && y == c) || nots(c, b, x, y)) { res = lf; }
                    else if c == a && ((x == b && y == d) || nots(d, b, x, y)) { res = lf; }
                    if res != SPF_UNKNOWN { sp_lhs = tv; sp_rhs = fv; return res; }
                }
            }
        }
        sp_lhs = tv;
        sp_rhs = fv;
    }
    if cl == not_value_of(tv) && cr == not_value_of(fv) {
        if p == P_SGT { return SPF_SMIN; }
        if p == P_SLT { return SPF_SMAX; }
        if p == P_UGT { return SPF_UMIN; }
        if p == P_ULT { return SPF_UMAX; }
    }
    if cl == not_value_of(fv) && cr == not_value_of(tv) {
        if p == P_SGT { return SPF_SMAX; }
        if p == P_SLT { return SPF_SMIN; }
        if p == P_UGT { return SPF_UMAX; }
        if p == P_ULT { return SPF_UMIN; }
    }
    if p != P_SGT && p != P_SLT { return SPF_UNKNOWN; }
    let c1 = m_apint(cr);
    if c1 < 0 { return SPF_UNKNOWN; }
    var c2: i32 = -1;
    if cl == tv { c2 = m_apint(fv); }
    if c2 < 0 && cl == fv { c2 = m_apint(tv); }
    if c2 >= 0 && (cl == tv || cl == fv) {
        let w = ci_w(c1);
        if p == P_SLT && ci_val(c1) == 0 && ci_val(c2) == sbit64(w) - 1 { return if cl == tv { SPF_UMAX } else { SPF_UMIN }; }
        if p == P_SGT && ci_val(c1) == wmask64(w) && ci_val(c2) == sbit64(w) { return if cl == fv { SPF_UMAX } else { SPF_UMIN }; }
    }
    return SPF_UNKNOWN;
}

// ---------------------------------------------------------------------------------------------
// computeConstantRange

// Constant::toConstantRange
fn const_to_range(c: i32) -> CR {
    let w = ty_scalar_bits(vals[c].ty);
    if w > 64 { vt_not_ported("constant ranges wider than 64 bits"); }
    if vals[c].kind == VK_CINT { return cr_single(cint_lo(c), w); }
    if !ty_is_vector(vals[c].ty) { return cr_full(w); }
    let s = splat_value(c, true);
    if s >= 0 && vals[s].kind == VK_CINT { return cr_single(cint_lo(s), w); }
    let k = vals[c].kind;
    if k == VK_CDVECTOR || k == VK_CVECTOR {
        var r = cr_empty(w);
        for i in nops(c) {
            let e = op(c, i);
            if vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CINT { return cr_full(w); }
            r = cr_union(r, cr_single(cint_lo(e), w));
        }
        return r;
    }
    return cr_full(w);
}

// setLimitsForBinOp: returns (lower, upper) of a range (getNonEmpty)
fn limits_for_binop(bo: i32, w: i64, prefer_signed: bool) -> u64, u64 {
    var lower: u64 = 0;
    var upper: u64 = 0;
    let m = wmask64(w);
    let smin = sbit64(w);
    let smax = sbit64(w) - 1;
    let o = iop(bo);
    if o == OP_SUB {
        let c = m_apint(op(bo, 0));
        if c >= 0 {
            let cv = ci_val(c);
            let nsw = op_nsw(bo);
            var nuw = op_nuw(bo);
            if prefer_signed && nsw && nuw { nuw = false; }
            if nuw { upper = (cv + 1) & m; }
            else if nsw {
                if (cv & smin) != 0 { lower = smin; upper = (cv - smax) & m; }
                else { lower = (cv - smax) & m; upper = smin; }
            }
        }
    } else if o == OP_ADD {
        let c = m_apint(op(bo, 1));
        if c >= 0 && ci_val(c) != 0 {
            let cv = ci_val(c);
            let nsw = op_nsw(bo);
            var nuw = op_nuw(bo);
            if prefer_signed && nsw && nuw { nuw = false; }
            if nuw { lower = cv; }
            else if nsw {
                if (cv & smin) != 0 { lower = smin; upper = (smax + cv + 1) & m; }
                else { lower = (smin + cv) & m; upper = (smax + 1) & m; }
            }
        }
    } else if o == OP_AND {
        let c = m_apint(op(bo, 1));
        if c >= 0 { upper = (ci_val(c) + 1) & m; }
        if m_neg(op(bo, 0)) == op(bo, 1) || m_neg(op(bo, 1)) == op(bo, 0) { upper = (smin + 1) & m; }
    } else if o == OP_OR {
        let c = m_apint(op(bo, 1));
        if c >= 0 { lower = ci_val(c); }
    } else if o == OP_ASHR {
        let c = m_apint(op(bo, 1));
        if c >= 0 && ci_val(c) < w as u64 {
            let s = ci_val(c) as i64;
            lower = ((sext64(smin, w) >> s) as! u64) & m;
            upper = ((smax >> s) + 1) & m;
        } else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 {
                let cv = ci_val(c0);
                var sa = w - 1;
                if cv != 0 && op_exact(bo) { sa = ctz_w(cv, w); }
                if (cv & smin) != 0 { lower = cv; upper = (((sext64(cv, w) >> sa) as! u64) + 1) & m; }
                else { lower = ((sext64(cv, w) >> sa) as! u64) & m; upper = (cv + 1) & m; }
            }
        }
    } else if o == OP_LSHR {
        let c = m_apint(op(bo, 1));
        if c >= 0 && ci_val(c) < w as u64 {
            upper = ((m >> ci_val(c)) + 1) & m;
        } else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 {
                let cv = ci_val(c0);
                var sa = w - 1;
                if cv != 0 && op_exact(bo) { sa = ctz_w(cv, w); }
                lower = cv >> sa;
                upper = (cv + 1) & m;
            }
        }
    } else if o == OP_SHL {
        let c0 = m_apint(op(bo, 0));
        if c0 >= 0 {
            let cv = ci_val(c0);
            if op_nuw(bo) {
                lower = cv;
                let lz = clz_w(cv, w);
                upper = (if lz >= w { 0 } else { (cv << lz) & m }) + 1;
                upper &= m;
            } else if op_nsw(bo) {
                if (cv & smin) != 0 {
                    let s = clo_w(cv, w) - 1;
                    lower = (cv << s) & m;
                    upper = (cv + 1) & m;
                } else {
                    let s = clz_w(cv, w) - 1;
                    lower = cv;
                    upper = (((cv << s) & m) + 1) & m;
                }
            } else {
                if (cv & 1) != 0 { lower = 1; }
                upper = (high_bits(w, popcount(cv)) + 1) & m;
            }
        } else {
            let c = m_apint(op(bo, 1));
            if c >= 0 && ci_val(c) < w as u64 {
                upper = ((m & ~low_bits(ci_val(c) as i64)) + 1) & m;
            }
        }
    } else if o == OP_SDIV {
        let c = m_apint(op(bo, 1));
        if c >= 0 {
            let cv = ci_val(c);
            if cv == m {
                lower = (smin + 1) & m;
                upper = (smax + 1) & m;
            } else if clz_w(cv, w) < w - 1 {
                let d = sext64(cv, w);
                var l = sdiv_w(smin, cv, w);
                var u = sdiv_w(smax, cv, w);
                if sext64(l, w) > sext64(u, w) { let t = l; l = u; u = t; }
                lower = l;
                upper = (u + 1) & m;
            }
        } else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 {
                let cv = ci_val(c0);
                if cv == smin { lower = cv; upper = ((cv >> 1) + 1) & m; }
                else {
                    let s = sext64(cv, w);
                    let ab = (if s < 0 { (0 as u64) - cv } else { cv }) & m;
                    upper = (ab + 1) & m;
                    lower = (((0 as u64) - upper) + 1) & m;
                }
            }
        }
    } else if o == OP_UDIV {
        let c = m_apint(op(bo, 1));
        if c >= 0 && ci_val(c) != 0 { upper = (m / ci_val(c) + 1) & m; }
        else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 { upper = (ci_val(c0) + 1) & m; }
        }
    } else if o == OP_SREM {
        let c = m_apint(op(bo, 1));
        if c >= 0 {
            let cv = ci_val(c);
            let s = sext64(cv, w);
            upper = (if s < 0 { (0 as u64) - cv } else { cv }) & m;
            lower = (((0 as u64) - upper) + 1) & m;
        } else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 {
                let cv = ci_val(c0);
                if (cv & smin) != 0 { upper = 1; lower = cv; }
                else { upper = (cv + 1) & m; }
            }
        }
    } else if o == OP_UREM {
        let c = m_apint(op(bo, 1));
        if c >= 0 { upper = ci_val(c); }
        else {
            let c0 = m_apint(op(bo, 0));
            if c0 >= 0 { upper = (ci_val(c0) + 1) & m; }
        }
    }
    return lower, upper;
}
fn sdiv_w(a: u64, b: u64, w: i64) -> u64 {
    let sa = sext64(a, w);
    let sb = sext64(b, w);
    if sb == -1 { return ((0 as u64) - a) & wmask64(w); }
    var q = sa / sb;   // truncates
    return (q as! u64) & wmask64(w);
}

fn range_for_intrinsic(ii: i32, w: i64) -> CR {
    let id = inst_iid(ii);
    let m = wmask64(w);
    let smin = sbit64(w);
    let smax = sbit64(w) - 1;
    if id == IID_ctlz || id == IID_cttz {
        var up = w as u64;
        if !m_one(op(ii, 1)) { up += 1; }
        return cr_nonempty(0, up & m, w);
    }
    if id == IID_ctpop { return cr_nonempty(0, ((w + 1) as u64) & m, w); }
    var c = m_apint(op(ii, 0));
    if id == IID_uadd_sat {
        if c < 0 { c = m_apint(op(ii, 1)); }
        if c >= 0 { return cr_nonempty(ci_val(c), 0, w); }
        return cr_full(w);
    }
    if id == IID_sadd_sat {
        if c < 0 { c = m_apint(op(ii, 1)); }
        if c >= 0 {
            let cv = ci_val(c);
            if (cv & smin) != 0 { return cr_nonempty(smin, (smax + cv + 1) & m, w); }
            return cr_nonempty((smin + cv) & m, (smax + 1) & m, w);
        }
        return cr_full(w);
    }
    if id == IID_usub_sat {
        if c >= 0 { return cr_nonempty(0, (ci_val(c) + 1) & m, w); }
        let c1 = m_apint(op(ii, 1));
        if c1 >= 0 { return cr_nonempty(0, (m - ci_val(c1) + 1) & m, w); }
        return cr_full(w);
    }
    if id == IID_ssub_sat {
        if c >= 0 {
            let cv = ci_val(c);
            if (cv & smin) != 0 { return cr_nonempty(smin, (cv - smin + 1) & m, w); }
            return cr_nonempty((cv - smax) & m, (smax + 1) & m, w);
        }
        let c1 = m_apint(op(ii, 1));
        if c1 >= 0 {
            let cv = ci_val(c1);
            if (cv & smin) != 0 { return cr_nonempty((smin - cv) & m, (smax + 1) & m, w); }
            return cr_nonempty(smin, (smax - cv + 1) & m, w);
        }
        return cr_full(w);
    }
    if id == IID_umin || id == IID_umax || id == IID_smin || id == IID_smax {
        if c < 0 { c = m_apint(op(ii, 1)); }
        if c < 0 { return cr_full(w); }
        let cv = ci_val(c);
        if id == IID_umin { return cr_nonempty(0, (cv + 1) & m, w); }
        if id == IID_umax { return cr_nonempty(cv, 0, w); }
        if id == IID_smin { return cr_nonempty(smin, (cv + 1) & m, w); }
        return cr_nonempty(cv, (smax + 1) & m, w);
    }
    if id == IID_abs {
        if m_one(op(ii, 1)) { return cr_nonempty(0, (smax + 1) & m, w); }
        return cr_nonempty(0, (smin + 1) & m, w);
    }
    if id == IID_vscale { vt_not_ported("getVScaleRange"); }
    return cr_full(w);
}

fn range_for_select_pattern(si: i32, w: i64) -> CR {
    let m = wmask64(w);
    let smin = sbit64(w);
    let smax = sbit64(w) - 1;
    let f = match_select_pattern_v(si, 0);
    let l = sp_lhs;
    let r = sp_rhs;
    if f == SPF_UNKNOWN { return cr_full(w); }
    if f == SPF_ABS {
        if m_neg(r) == l && l >= 0 && is_inst(r) && op_nsw(r) { return cr_nonempty(0, (smax + 1) & m, w); }
        return cr_nonempty(0, (smin + 1) & m, w);
    }
    if f == SPF_NABS { return cr_nonempty(smin, 1, w); }
    var c = m_apint(l);
    if c < 0 { c = m_apint(r); }
    if c < 0 { return cr_full(w); }
    let cv = ci_val(c);
    if f == SPF_UMIN { return cr_nonempty(0, (cv + 1) & m, w); }
    if f == SPF_UMAX { return cr_nonempty(cv, 0, w); }
    if f == SPF_SMIN { return cr_nonempty(smin, (cv + 1) & m, w); }
    if f == SPF_SMAX { return cr_nonempty(cv, (smax + 1) & m, w); }
    return cr_full(w);
}

// computeConstantRange(V, ForSigned, SQ, Depth); UseInstrInfo is always true
recursive fn compute_constant_range(v: i32, for_signed: bool, use_info: bool, depth: i64) -> CR {
    let w = ty_scalar_bits(vals[v].ty);
    if w > 64 { vt_not_ported("constant ranges wider than 64 bits"); }
    if depth == VT_MAX_DEPTH { return cr_full(w); }
    if is_constant(v) { return const_to_range(v); }
    var cr = cr_full(w);
    if is_inst(v) && is_binary_op(iop(v)) {
        let lo, hi = limits_for_binop(v, w, for_signed);
        cr = cr_nonempty(lo, hi, w);
    } else if inst_iid(v) != 0 {
        cr = range_for_intrinsic(v, w);
    } else if is_inst_op(v, OP_SELECT) {
        let ct = compute_constant_range(op(v, 1), for_signed, use_info, depth + 1);
        let cf = compute_constant_range(op(v, 2), for_signed, use_info, depth + 1);
        cr = cr_union(ct, cf);
        cr = cr_intersect(cr, range_for_select_pattern(v, w));
    } else if is_inst_op(v, OP_TRUNC) {
        let s = compute_constant_range(op(v, 0), for_signed, use_info, depth + 1);
        cr = cr_truncate(s, w);
    } else if is_inst_op(v, OP_FPTOUI) || is_inst_op(v, OP_FPTOSI) {
        let src_half = types[ty_scalar(vals[op(v, 0)].ty)].kind == TK_HALF;
        var lo: u64 = 0;
        var hi: u64 = 0;
        if src_half {
            if iop(v) == OP_FPTOSI && w >= 17 { lo = ((0 - 65504) as! u64) & wmask64(w); hi = 65505; }
            if iop(v) == OP_FPTOUI && w >= 16 { hi = 65505; }
        }
        cr = cr_nonempty(lo, hi, w);
    } else if is_arg(v) {
        if arg_range(v) { cr = vt_cr; }
    }
    if is_inst(v) {
        let md = inst_get_md(v, md_kind_id("range"));
        if md >= 0 { cr = cr_intersect(cr, range_md_to_cr(md)); }
        if is_callbase(v) {
            if call_range(v) { cr = cr_intersect(cr, vt_cr); }
        } else if iop(v) == OP_EXTRACTVALUE && inst_iid(op(v, 0)) == IID_frexp {
            vt_not_ported("computeConstantRange of frexp exponents");
        }
    }
    if kb_cxt >= 0 { cr = range_from_assumptions(v, cr, depth); }
    return cr;
}
fn range_md_to_cr(md: i32) -> CR {
    let n = mds[md].nops as i64 / 2;
    let lo0 = mds[md_op(md, 0)].extra;
    let w = ci_w(lo0);
    if w > 64 { pm_wide(); }
    var cr = cr_new(cint_lo(lo0), cint_lo(mds[md_op(md, 1)].extra), w);
    for i in 1..n {
        cr = cr_union(cr, cr_new(cint_lo(mds[md_op(md, 2 * i)].extra), cint_lo(mds[md_op(md, 2 * i + 1)].extra), w));
    }
    return cr;
}

// getUnderlyingObjectAggressive
fn get_underlying_object_aggressive(v: i32) -> i32 {
    var visited: i32[>..<] = [];
    var wl: i32[>..<] = [];
    wl.push(v);
    var obj: i32 = -1;
    var first = true;
    let first_obj = get_underlying_object(v, 6);
    while wl.len > 0 {
        let p0 = wl.pop();
        let p = if first { first_obj } else { get_underlying_object(p0, 6) };
        first = false;
        var seen = false;
        for x in visited { if x == p { seen = true; } }
        if seen { continue; }
        visited.push(p);
        if visited.len == 8 { return first_obj; }
        if is_inst_op(p, OP_SELECT) { wl.push(op(p, 1)); wl.push(op(p, 2)); continue; }
        if is_inst_op(p, OP_PHI) { for k in nops(p) { wl.push(op(p, k)); } continue; }
        if obj < 0 { obj = p; } else if obj != p { return first_obj; }
    }
    return if obj >= 0 { obj } else { first_obj };
}
