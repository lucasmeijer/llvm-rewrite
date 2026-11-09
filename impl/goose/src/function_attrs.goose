// FunctionAttrs: port of llvm/lib/Transforms/IPO/FunctionAttrs.cpp (PostOrderFunctionAttrsPass,
// ReversePostOrderFunctionAttrsPass, NoRecurseLTOInferencePass: addMemoryAttrs / checkFunctionMemoryAccess,
// addArgumentAttrs with the ArgumentUsesTracker, the ArgumentGraph and its scc_iterator,
// determinePointerAccessAttrs, inferInitializes / collectArgumentUsesPerBlock / getArgumentAccessInfo,
// addArgumentReturnedAttrs, addArgumentAttrsFromCallsites, addNoAliasAttrs, addNonNullAttrs, addNoUndefAttrs,
// the AttributeInferer (convergent, nounwind, nofree, nosync), addNoRecurseAttrs, addNoReturnAttrs,
// addColdAttrs, addWillReturn, the top-down norecurse / nofpclass deduction), ConstantRangeList
// (llvm/lib/IR/ConstantRangeList.cpp: insert, subtract, unionWith, intersectWith), Instruction::getMemoryEffects
// and Instruction::mayThrow(IncludePhaseOneUnwind) (llvm/lib/IR/Instruction.cpp), llvm::canReturn
// (llvm/lib/Analysis/CFG.cpp). Not ported: thinLTOPropagateFunctionAttrs (no summary index).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import analyses;
import flags;
import pm;
import vt;
import poison;
import knownbits;
import fpclass;
import constrange;
import apint;
import memloc;
import aa;
import aautil;
import capture;
import intrinsics;
import build_libcalls;
import cfgutil;
import scev;
import ivec;
import lcg;
import ipoutil;
import passmgr;
import sccp;
import tli;

fn fa_not_ported(what: const u8[:]) { fatal(str("FunctionAttrs: ", what, " is not ported yet")); }

// ---------------------------------------------------------------------------------------------
// Function / argument attribute helpers

fn fa_ret_ty(f: i32) -> i32 { ty_fn_ret(globs[glob_of(f)].vty) }
fn fa_fn_has(f: i32, k: i64) -> bool { fn_has(f, 0, k) }
fn fa_only_reads_memory(f: i32) -> bool { me_only_reads(fn_memory_effects(f)) }
fn fa_does_not_access_memory(f: i32) -> bool { fn_memory_effects(f) == 0 }
fn fa_has_attr_somewhere(f: i32, kind: i64) -> bool {
    let l = globs[glob_of(f)].attrs;
    for k in alists[l].n { if aset_has(alist_runs[alists[l].at + k], kind) { return true; } }
    return false;
}
fn fa_arg_set(a: i32) -> i32 { arg_attrs(a) }
fn fa_arg_idx(a: i32) -> i64 { args_no[vals[a].sub] as i64 }
fn fa_arg_fn(a: i32) -> i32 { args_parent[vals[a].sub] }
fn fa_arg_has(a: i32, kind: i64) -> bool { aset_has(fa_arg_set(a), kind) }
// Argument::addAttr (replaces an attribute of the same kind)
fn fa_arg_add(a: i32, at: i32) { fn_add_attr(fa_arg_fn(a), 2 + fa_arg_idx(a), at); }
fn fa_arg_remove(a: i32, kind: i64) {
    let f = fa_arg_fn(a);
    let idx = 2 + fa_arg_idx(a);
    let s = fn_aset(f, idx);
    if !aset_has(s, kind) { return; }
    fn_set_aset(f, idx, aset_without(s, [kind]));
}
// Argument::onlyReadsMemory
fn fa_arg_only_reads(a: i32) -> bool { fa_arg_has(a, AK_ReadOnly) || fa_arg_has(a, AK_ReadNone) }
// Function::isConvergent etc.
fn fa_set_fn_enum(f: i32, kind: i64) { if !fa_fn_has(f, kind) { fn_add_attr(f, 0, attr_enum(kind)); } }
fn fa_remove_fn_attr(f: i32, kind: i64) { let s = fn_aset(f, 0); if aset_has(s, kind) { fn_set_aset(f, 0, aset_without(s, [kind])); } }
fn fa_capture_attr(ci: i64) -> i32 { attr_int(AK_Captures, ((ci_other(ci) | (ci_ret(ci) << 8)) as u64)) }
fn fa_arg_capture_info(a: i32) -> i64 { aset_capture_info(fa_arg_set(a)) }
fn fa_has_exact_definition(f: i32) -> bool { gv_has_exact_definition(f) }

// FPClassTest of a nofpclass attribute in a set (fcNone if absent)
fn fa_nofpclass(s: i32) -> u64 { let a = aset_find(s, AK_NoFPClass); if a < 0 { 0 } else { attrs[a].i1 } }
// CallBase::getParamNoFPClass(i): call site | callee
fn fa_cb_param_nofpclass(cb: i32, i: i64) -> u64 {
    var m = fa_nofpclass(alist_param(insts[inst_of(cb)].attrs, i));
    let f = called_function(cb);
    if f >= 0 { m |= fa_nofpclass(alist_param(func_attrs(f), i)); }
    return m;
}
fn fa_cb_ret_nofpclass(cb: i32) -> u64 {
    var m = fa_nofpclass(alist_ret(insts[inst_of(cb)].attrs));
    let f = called_function(cb);
    if f >= 0 { m |= fa_nofpclass(alist_ret(func_attrs(f))); }
    return m;
}

// Argument::hasNonNullAttr(AllowUndefOrPoison)
fn fa_arg_has_nonnull(a: i32, allow_undef: bool) -> bool {
    if ty_kind(vals[a].ty) != TK_PTR { return false; }
    if fa_arg_has(a, AK_NonNull) && (allow_undef || fa_arg_has(a, AK_NoUndef)) { return true; }
    let s = fa_arg_set(a);
    let d = aset_find(s, AK_Dereferenceable);
    if d >= 0 && attrs[d].i1 > 0 && !null_pointer_is_defined(fa_arg_fn(a), ptr_as(vals[a].ty)) { return true; }
    return false;
}

// Value::stripPointerCasts
fn fa_strip_pointer_casts(v0: i32) -> i32 {
    var v = v0;
    if ty_kind(vals[v].ty) != TK_PTR { return v; }
    var visited: i32[>..<] = [v];
    loop {
        let o = opcode_of(v);
        if o == OP_GEP {
            var allz = true;
            for j in 1..nops(v) { let x = op(v, j); if !(is_constant(x) && is_null_value(x)) { allz = false; } }
            if !allz { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else if is_inst(v) && is_callbase(v) {
            let rv = fa_returned_arg_operand(v);
            if rv < 0 { return v; }
            v = rv;
        } else { return v; }
        for x in visited { if x == v { return v; } }
        visited.push(v);
    }
    return v;
}
// CallBase::getReturnedArgOperand (getArgOperandWithAttribute(Returned))
fn fa_returned_arg_operand(cb: i32) -> i32 {
    let l = insts[inst_of(cb)].attrs;
    let n = cb_nargs(cb);
    for k in n { if aset_has(alist_param(l, k), AK_Returned) { return cb_arg(cb, k); } }
    let f = called_function(cb);
    if f >= 0 {
        let fl = func_attrs(f);
        for k in n { if aset_has(alist_param(fl, k), AK_Returned) { return cb_arg(cb, k); } }
    }
    return -1;
}

// Instruction::mayThrow(IncludePhaseOneUnwind)
fn fa_inst_may_throw(iv: i32, p1: bool) -> bool {
    let o = iop(iv);
    if o == OP_INVOKE {
        let lp = first_non_phi(invoke_unwind_dest(iv));
        if lp >= 0 && iop(lp) == OP_LANDINGPAD { return landingpad_can_unwind_past(lp, p1); }
        return false;
    }
    if o == OP_CLEANUPPAD { return p1; }
    return inst_may_throw(iv);
}

// Instruction::getMemoryEffects
fn fa_inst_memory_effects(iv: i32) -> u64 {
    let o = iop(iv);
    fn get_effects(base: i64, ord: u8, vol: bool) -> u64 {
        if ord_stronger_than_monotonic(ord) { return ME_UNKNOWN; }
        if vol { return me_set(me_set(0, LOC_ARG, MR_MODREF), LOC_INACCESSIBLE, MR_MODREF); }
        if ord_stronger_than_unordered(ord) { return me_set(0, LOC_ARG, MR_MODREF); }
        return me_set(0, LOC_ARG, base);
    }
    let x = insts[inst_of(iv)];
    let vol = (x.bits & 1) != 0;
    if o == OP_VAARG { return me_set(0, LOC_ARG, MR_MODREF); }
    if o == OP_CATCHPAD || o == OP_CATCHRET || o == OP_FENCE { return ME_UNKNOWN; }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { return call_memory_effects(iv); }
    if o == OP_LOAD { return get_effects(MR_REF, x.ord, vol); }
    if o == OP_STORE { return get_effects(MR_MOD, x.ord, vol); }
    if o == OP_ATOMICRMW { return get_effects(MR_MODREF, x.ord, vol); }
    if o == OP_CMPXCHG { return get_effects(MR_MODREF, x.ord, vol); }
    return 0;
}

// SCCNodeSet (SmallSetVector<Function *>): fa_scc, membership by search (SCCs are small)
var fa_scc: i32[>..];
fn fa_in_scc(f: i32) -> bool { if f < 0 { return false; } for x in fa_scc { if x == f { return true; } } return false; }
// SmallPtrSet<Function *> Changed
var fa_changed: i32[>..];
fn fa_mark_changed(f: i32) { for x in fa_changed { if x == f { return; } } fa_changed.push(f); }

// ---------------------------------------------------------------------------------------------
// Memory attributes

// addLocAccess
fn fa_add_loc_access(me: u64, loc: ML, mr0: i64) -> u64 {
    var m = me;
    let mr = mr0 & aa_mod_ref_mask_simple(loc, true);
    if mr == MR_NO { return m; }
    let uo = get_underlying_object_aggressive(loc.ptr);
    if is_inst_op(uo, OP_ALLOCA) { return m; }
    if is_arg(uo) { return m | me_set(0, LOC_ARG, mr); }
    if !aa_is_identified_object(uo) { m |= me_set(0, LOC_ARG, mr); }
    m |= me_set(0, LOC_ERRNO, mr);
    m |= me_set(0, LOC_OTHER, mr);
    return m;
}
// addArgLocs
fn fa_add_arg_locs(me: u64, cb: i32, mr: i64) -> u64 {
    var m = me;
    let tags = ml_aa_tags(cb);
    let n = cb_nargs(cb);
    for k in n {
        let a = cb_arg(cb, k);
        if ty_kind(ty_scalar(vals[a].ty)) != TK_PTR { continue; }
        m = fa_add_loc_access(m, ml_with_tags(a, LS_BEFORE_OR_AFTER, tags), mr);
    }
    return m;
}

// checkFunctionMemoryAccess -> (ME, RecursiveArgME)
fn fa_check_function_memory_access(f: i32, this_body: bool) -> u64, u64 {
    aa_begin(f);
    let orig = aa_fn_me(f);
    if orig == 0 { return orig, 0; }
    if !this_body { return orig, 0; }
    var me: u64 = 0;
    var rec: u64 = 0;
    fn add_non_arg(inst_me: u64) {
        me |= me_without(inst_me, LOC_ARG);
        let other = me_get(inst_me, LOC_OTHER);
        me |= me_set(0, LOC_ARG, other);
    }
    if fa_has_attr_somewhere(f, AK_InAlloca) || fa_has_attr_somewhere(f, AK_Preallocated) { me |= me_set(0, LOC_ARG, MR_MODREF); }
    each_inst(f) { i =>
        if is_callbase(i) {
            let cf = called_function(i);
            if !cb_has_bundles(i) && cf >= 0 && fa_in_scc(cf) {
                rec = fa_add_arg_locs(rec, i, MR_MODREF);
            } else {
                let cme = aa_call_me_simple(i);
                if cme != 0 && inst_iid(i) != IID_pseudoprobe {
                    add_non_arg(cme);
                    let amr = me_get(cme, LOC_ARG);
                    if amr != MR_NO { me = fa_add_arg_locs(me, i, amr); }
                }
            }
        } else {
            let ime = fa_inst_memory_effects(i);
            if ime != 0 {
                let loc = ml_get_or_none(i);
                if loc.ptr == ML_NONE {
                    me |= me_all(me_modref(ime));
                } else {
                    add_non_arg(ime);
                    me = fa_add_loc_access(me, loc, me_get(ime, LOC_ARG));
                }
            }
        }
    };
    return orig & me, rec;
}

// addMemoryAttrs
fn fa_add_memory_attrs() {
    var me: u64 = 0;
    var rec: u64 = 0;
    for f in fa_scc {
        let fme, frec = fa_check_function_memory_access(f, fa_has_exact_definition(f));
        me |= fme;
        rec |= frec;
        if me == ME_UNKNOWN { return; }
    }
    let amr = me_get(me, LOC_ARG);
    if amr != MR_NO { me |= rec & me_all(amr); }
    for f in fa_scc {
        let old = fn_memory_effects(f);
        let nw = me & old;
        if nw != old {
            fn_add_attr(f, 0, attr_int(AK_Memory, nw));
            if (me_get(nw, LOC_ARG) & MR_MOD) == 0 {
                for k in func_nargs(f) { fa_arg_remove(func_arg(f, k), AK_Writable); }
            }
            fa_mark_changed(f);
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Argument attributes

// addArgumentReturnedAttrs
fn fa_add_argument_returned_attrs() {
    for f in fa_scc {
        if !fa_has_exact_definition(f) { continue; }
        if ty_kind(fa_ret_ty(f)) == TK_VOID { continue; }
        if fa_has_attr_somewhere(f, AK_Returned) { continue; }
        var ret_arg: i32 = -1;
        var ok = true;
        var b = func_first_block(f);
        while b >= 0 && ok {
            let t = block_terminator(b);
            if t >= 0 && iop(t) == OP_RET {
                let rv = fa_strip_pointer_casts(op(t, 0));
                if !is_arg(rv) || vals[rv].ty != fa_ret_ty(f) { ok = false; }
                else if ret_arg < 0 { ret_arg = rv; }
                else if ret_arg != rv { ok = false; }
            }
            b = block_next(b);
        }
        if ok && ret_arg >= 0 {
            fa_arg_add(ret_arg, attr_enum(AK_Returned));
            fa_mark_changed(f);
        }
    }
}

// addArgumentAttrsFromCallsites
fn fa_add_argument_attrs_from_callsites(f: i32) -> bool {
    if !flag_bool("enable-poison-arg-attr-prop", true) { return false; }
    var changed = false;
    var i = block_first(func_entry(f));
    while i >= 0 {
        if is_callbase(i) {
            let cf = called_function(i);
            if cf >= 0 {
                for an in func_nargs(cf) {
                    let cs_arg = func_arg(cf, an);
                    let farg = cb_arg(i, an);
                    if !is_arg(farg) { continue; }
                    if fa_arg_has_nonnull(cs_arg, false) {
                        if !fa_arg_has_nonnull(farg, true) {
                            fa_arg_add(farg, attr_enum(AK_NonNull));
                            changed = true;
                        }
                    } else {
                        let cs_nofp = fa_cb_param_nofpclass(i, an);
                        if cs_nofp != 0 && cb_param_has_attr(i, an, AK_NoUndef) {
                            let arg_nofp = fa_nofpclass(fa_arg_set(farg));
                            if (cs_nofp | arg_nofp) != arg_nofp {
                                fa_arg_add(farg, attr_int(AK_NoFPClass, cs_nofp | arg_nofp));
                                changed = true;
                            }
                        }
                    }
                }
            }
        }
        if !guaranteed_to_transfer(i) { break; }
        i = inst_next(i);
    }
    return changed;
}

// ArgAccessProperties as bits: 1 read, 2 write, 4 free
let AP_READ: i64 = 1;
let AP_WRITE: i64 = 2;
let AP_FREE: i64 = 4;
let AP_ALL: i64 = 7;

// determinePointerAccessAttrs(A, SCCNodes); `scc_args` is the argument set (value ids)
fn fa_determine_pointer_access(a: i32, scc_args: i32[:]) -> i64 {
    if fa_arg_has(a, AK_InAlloca) || fa_arg_has(a, AK_Preallocated) { return AP_ALL; }
    var props: i64 = 0;
    var wl: i32[>..<] = [];
    var visited = hm_new();
    var u = first_use(a);
    while u >= 0 { hm_put(visited, (u as i64) as u64, 1); wl.push(u); u = use_next(u); }
    fn in_set(x: i32) -> bool { for y in scc_args { if y == x { return true; } } return false; }
    while wl.len > 0 {
        if props == AP_ALL { return props; }
        let uu = wl.pop();
        let ins = uses[uu].user;
        if iop(ins) == OP_RET { continue; }
        var info = ct_use_capture_kind(uu, a);
        if is_callbase(ins) && call_only_reads_memory(ins) { info.use_cc &= CC_ADDRESS; }
        if cc_any_provenance(info.use_cc) {
            if !cc_read_provenance_only(info.use_cc) { return AP_ALL; }
            props |= AP_READ;
        }
        if cc_any_provenance(info.result_cc) {
            var w = first_use(ins);
            while w >= 0 {
                if !hm_has(visited, (w as i64) as u64) { hm_put(visited, (w as i64) as u64, 1); wl.push(w); }
                w = use_next(w);
            }
        }
        if is_callbase(ins) {
            let opno = (uu - vals[ins].ops) as i64;
            if opno == nops(ins) - 1 { props |= AP_READ; continue; }    // isCallee
            let use_index = opno;
            let amr = me_get(call_memory_effects(ins), LOC_ARG);
            if amr == MR_NO { continue; }
            let cf = called_function(ins);
            let is_arg_op = opno < cb_nargs(ins);
            if cf >= 0 && is_arg_op && use_index < func_nargs(cf) && in_set(func_arg(cf, use_index)) { continue; }
            if (amr & MR_REF) != 0 && !cb_arg_only_writes(ins, use_index) { props |= AP_READ; }
            if (amr & MR_MOD) != 0 && !cb_arg_only_reads(ins, use_index) {
                props |= AP_WRITE;
                if is_arg_op && !call_has_fn_attr(ins, AK_NoFree) && !cb_param_has_attr(ins, use_index, AK_NoFree) { props |= AP_FREE; }
            }
        } else {
            if iop(ins) == OP_STORE && (uu - vals[ins].ops) != 1 { continue; }
            if inst_may_read_memory(ins) { props |= AP_READ; }
            if inst_may_write_memory(ins) { props |= AP_WRITE; }
        }
    }
    return props;
}

// addAccessAttrs
fn fa_add_access_attrs(a: i32, props: i64) -> bool {
    var changed = false;
    if (props & AP_FREE) == 0 && !fa_arg_has(a, AK_NoFree) {
        fa_arg_add(a, attr_enum(AK_NoFree));
        changed = true;
    }
    if (props & AP_READ) != 0 && (props & AP_WRITE) != 0 { return changed; }
    var k: i64 = AK_ReadNone;
    if (props & AP_READ) != 0 { k = AK_ReadOnly; } else if (props & AP_WRITE) != 0 { k = AK_WriteOnly; }
    if fa_arg_has(a, k) { return false; }
    fa_arg_remove(a, AK_WriteOnly);
    fa_arg_remove(a, AK_ReadOnly);
    fa_arg_remove(a, AK_ReadNone);
    if k == AK_ReadNone || k == AK_ReadOnly { fa_arg_remove(a, AK_Writable); }
    fa_arg_add(a, attr_enum(k));
    return true;
}

fn fa_determine_access_singleton(a: i32) -> bool { return fa_add_access_attrs(a, fa_determine_pointer_access(a, [a])); }

// ---------------------------------------------------------------------------------------------
// ConstantRangeList over signed 64-bit (lo, hi) pairs, flattened

fn crl_insert(r: i64[>..<]&, lo: i64, hi: i64) {
    if lo == hi { fa_not_ported("an empty or degenerate access range"); }
    let n = r.len / 2;
    if n == 0 || r[r.len - 1] < lo { r.push(lo); r.push(hi); return; }
    if hi < r[0] { r.insert_at(0, hi); r.insert_at(0, lo); return; }
    // lower_bound by lower
    var lb: i64 = 0;
    while lb < n && r[2 * lb] < lo { lb++; }
    if lb < n && r[2 * lb] <= lo && hi <= r[2 * lb + 1] { return; }    // contains
    var tail: i64[>..<] = [];
    for k in 2 * lb..r.len { tail.push(r[k]); }
    r.resize(2 * lb);
    if r.len > 0 && lo <= r[r.len - 1] {
        r[r.len - 1] = max(hi, r[r.len - 1]);
    } else { r.push(lo); r.push(hi); }
    var k: i64 = 0;
    while k < tail.len {
        if r[r.len - 1] < tail[k] { r.push(tail[k]); r.push(tail[k + 1]); }
        else { r[r.len - 1] = max(tail[k + 1], r[r.len - 1]); }
        k += 2;
    }
}
fn crl_subtract(r: i64[>..<]&, slo: i64, shi: i64) {
    if r.len == 0 { return; }
    if r[r.len - 1] <= slo { return; }
    if shi <= r[0] { return; }
    var res: i64[>..<] = [];
    var k: i64 = 0;
    while k < r.len {
        let lo = r[k];
        let hi = r[k + 1];
        k += 2;
        if shi <= lo || hi <= slo { res.push(lo); res.push(hi); }
        else if lo <= slo && shi <= hi {
            if lo < slo { res.push(lo); res.push(slo); }
            if shi < hi { res.push(shi); res.push(hi); }
        } else if slo <= lo && hi <= shi { continue; }
        else if lo >= slo && lo <= shi { if shi < hi { res.push(shi); res.push(hi); } }
        else { if lo < slo { res.push(lo); res.push(slo); } }
    }
    r.resize(0);
    for x in res { r.push(x); }
}
fn crl_union(a: i64[:], b: i64[:], out: i64[>..<]&) {
    out.resize(0);
    if a.len == 0 { for x in b { out.push(x); } return; }
    if b.len == 0 { for x in a { out.push(x); } return; }
    var i: i64 = 0;
    var j: i64 = 0;
    var plo: i64 = 0;
    var phi: i64 = 0;
    if a[0] < b[0] { plo = a[0]; phi = a[1]; i = 2; } else { plo = b[0]; phi = b[1]; j = 2; }
    while i < a.len || j < b.len {
        var lo: i64 = 0;
        var hi: i64 = 0;
        if j == b.len || (i < a.len && a[i] < b[j]) { lo = a[i]; hi = a[i + 1]; i += 2; }
        else { lo = b[j]; hi = b[j + 1]; j += 2; }
        if phi < lo { out.push(plo); out.push(phi); plo = lo; phi = hi; }
        else { phi = max(phi, hi); }
    }
    out.push(plo);
    out.push(phi);
}
fn crl_intersect(a: i64[:], b: i64[:], out: i64[>..<]&) {
    out.resize(0);
    if a.len == 0 || b.len == 0 { return; }
    var i: i64 = 0;
    var j: i64 = 0;
    while i < a.len && j < b.len {
        let s = max(a[i], b[j]);
        let e = min(a[i + 1], b[j + 1]);
        if s < e { out.push(s); out.push(e); }
        if a[i + 1] < b[j + 1] { i += 2; } else { j += 2; }
    }
}
// the ranges of an initializes attribute (words pool, see the parser)
fn crl_from_attr(at: i32, out: i64[>..<]&) {
    out.resize(0);
    let w = attrs[at].i1 as! i64;
    let n = words[w] as! i64;
    for j in n { out.push(words[w + 1 + 2 * j] as! i64); out.push(words[w + 2 + 2 * j] as! i64); }
}
fn crl_attr(r: i64[:]) -> i32 {
    let at = words.len;
    words.push((r.len / 2) as u64);
    for x in r { words.push(x as! u64); }
    return attr_int(AK_Initializes, at as u64);
}

// ---------------------------------------------------------------------------------------------
// inferInitializes

// ArgumentAccessInfo kinds
let AAI_WRITE: i64 = 0;
let AAI_WRITE_SE: i64 = 1;
let AAI_READ: i64 = 2;
let AAI_UNKNOWN: i64 = 3;

// Per-instruction info of collectArgumentUsesPerBlock: (inst, kind, ranges run in fa_rr)
struct FaInfo { inst: i32, blk: i32, kind: i64, rr: i32, rn: i32 }
var fa_infos: FaInfo[>..<];
var fa_rr: i64[>..<];

// sadd_ov on i64
fn fa_sadd(a: i64, b: i64) -> i64, bool {
    let s = (a as! u64) + (b as! u64);
    let r = s as! i64;
    let ov = (a >= 0 && b >= 0 && r < 0) || (a < 0 && b < 0 && r >= 0);
    return r, ov;
}

// getArgumentAccessInfo(I, ArgUse(u, offset), DL): appends ranges to fa_rr and returns (kind, ranges start, count)
fn fa_access_info(i: i32, u: i32, has_off: bool, off: i64) -> i64, i32, i32 {
    let rr = fa_rr.len as i32;
    fn type_range(t: i32) -> bool {
        if ty_size_scalable(t) || !has_off { return false; }
        let size = dl_store_size(t) as i64;
        let hi, ov = fa_sadd(off, size);
        if ov { return false; }
        if size == 0 {
            // ConstantRange(Off, Off): the empty set for Off == 0 (inserting or subtracting it does nothing)
            if off == 0 { return false; }
            fa_not_ported("zero-size accesses at a nonzero offset in initializes inference");
        }
        fa_rr.push(off);
        fa_rr.push(hi);
        return true;
    }
    fn const_range(len: i32) -> bool {
        if !is_cint(len) || !has_off { return false; }
        let l = cint_sext(len);
        if l <= 0 { return false; }
        let hi, ov = fa_sadd(off, l);
        if ov { return false; }
        fa_rr.push(off);
        fa_rr.push(hi);
        return true;
    }
    let o = iop(i);
    let opno = (u - vals[i].ops) as i64;
    let simple = insts[inst_of(i)].ord == 0 && (insts[inst_of(i)].bits & 1) == 0;
    if o == OP_STORE {
        if simple && opno == 1 {
            let ok = type_range(vals[op(i, 0)].ty);
            return AAI_WRITE, rr, if ok { 1 } else { 0 };
        }
    } else if o == OP_LOAD {
        if simple {
            if type_range(vals[i].ty) { return AAI_READ, rr, 1; }
        }
    } else if is_callbase(i) {
        let id = inst_iid(i);
        if id == IID_memset || id == IID_memset_inline {
            if !inst_is_volatile(i) {
                let ok = const_range(cb_arg(i, 2));
                return AAI_WRITE, rr, if ok { 1 } else { 0 };
            }
        } else if id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove {
            if !inst_is_volatile(i) {
                if opno == 0 {
                    let ok = const_range(cb_arg(i, 2));
                    return AAI_WRITE, rr, if ok { 1 } else { 0 };
                } else if opno == 1 {
                    if const_range(cb_arg(i, 2)) { return AAI_READ, rr, 1; }
                }
            }
        } else if opno < cb_nargs(i) && !cb_is_byval_arg(i, opno) {
            let ano = opno;
            let init_at = fa_cb_param_attr(i, ano, AK_Initializes);
            if init_at >= 0 && has_off {
                let kind = if cb_arg_only_writes(i, ano) && cc_nothing(ci_other(cb_capture_info(i, ano)) | ci_ret(cb_capture_info(i, ano))) { AAI_WRITE } else { AAI_WRITE_SE };
                var cbcrl: i64[>..<] = [];
                crl_from_attr(init_at, cbcrl);
                var acc: i64[>..<] = [];
                var k: i64 = 0;
                while k < cbcrl.len { crl_insert(acc, cbcrl[k] + off, cbcrl[k + 1] + off); k += 2; }
                for x in acc { fa_rr.push(x); }
                return kind, rr, (acc.len / 2) as i32;
            }
        }
    }
    return AAI_UNKNOWN, rr, 0;
}
// CallBase::getParamAttr(ArgNo, Kind): the call site's, else the callee's (-1 = none)
fn fa_cb_param_attr(cb: i32, k: i64, kind: i64) -> i32 {
    let a = aset_find(alist_param(insts[inst_of(cb)].attrs, k), kind);
    if a >= 0 { return a; }
    let f = called_function(cb);
    if f < 0 { return -1; }
    return aset_find(alist_param(func_attrs(f), k), kind);
}

// Per-block summary of collectArgumentUsesPerBlock (UsesPerBlockInfo): kept by block value id in an HMap
struct FaBlk { first_info: i32, has_writes: bool, has_unknown: bool }

fn fa_infer_initializes(a: i32, f: i32) -> bool {
    fa_infos.resize(0);
    fa_rr.resize(0);
    var blk = hm_new();          // block -> index into blks
    var blks: FaBlk[>..<] = [];
    var blk_ids: i32[>..<] = [];
    var info_of = hm_new();      // instruction -> index into fa_infos (the BBInfo.Insts map)
    var has_any_write = false;
    var write_outside_entry = false;
    let entry = func_entry(f);
    // worklist of (use, has offset, offset)
    var wl_u: i32[>..<] = [];
    var wl_h: bool[>..<] = [];
    var wl_o: i64[>..<] = [];
    var u0 = first_use(a);
    while u0 >= 0 { wl_u.push(u0); wl_h.push(true); wl_o.push(0); u0 = use_next(u0); }
    while wl_u.len > 0 {
        let u = wl_u.pop();
        let ho = wl_h.pop();
        let off = wl_o.pop();
        let us = uses[u].user;
        if opcode_of(us) == OP_GEP {
            var nho = false;
            var noff: i64 = 0;
            if ho {
                let ok, goff = gep_accumulate_constant_offset(us);
                if ok {
                    let w = dl_ptr(ptr_as(vals[a].ty)).idx;
                    let so = if w >= 64 { goff } else { sext64(goff as! u64, w) };
                    nho = true;
                    noff = off + so;
                }
            }
            var w2 = first_use(us);
            while w2 >= 0 { wl_u.push(w2); wl_h.push(nho); wl_o.push(noff); w2 = use_next(w2); }
            continue;
        }
        if !is_inst(us) { fa_not_ported("a non-instruction, non-GEP user of an argument in initializes inference"); }
        let kind, rr, rn = fa_access_info(us, u, ho, off);
        // UpdateUseInfo
        let bb = inst_parent(us);
        var bi = hm_get(blk, (bb as i64) as u64, -1);
        if bi < 0 {
            bi = blks.len;
            hm_put(blk, (bb as i64) as u64, bi);
            blks.push(FaBlk { first_info: -1, has_writes: false, has_unknown: false });
            blk_ids.push(bb);
        }
        let ii = hm_get(info_of, (us as i64) as u64, -1);
        var has_write = false;
        if ii >= 0 {
            fa_infos[ii].kind = AAI_UNKNOWN;
            fa_infos[ii].rn = 0;
            blks[bi].has_unknown = true;
        } else {
            hm_put(info_of, (us as i64) as u64, fa_infos.len);
            fa_infos.push(FaInfo { inst: us, blk: bb, kind: kind, rr: rr, rn: rn });
            if kind == AAI_UNKNOWN { blks[bi].has_unknown = true; }
            has_write = (kind == AAI_WRITE || kind == AAI_WRITE_SE) && rn > 0;
            if has_write { blks[bi].has_writes = true; }
        }
        if has_write { has_any_write = true; }
        if has_write && bb != entry { write_outside_entry = true; }
    }
    if !has_any_write { return false; }
    // Initialized: block -> ranges (runs in init_r)
    var init_at = hm_new();
    var init_r: i64[>..<] = [];
    var init_n = hm_new();
    var crl: i64[>..<] = [];
    fn visit_block(bb: i32) {
        crl.resize(0);
        let bi = hm_get(blk, (bb as i64) as u64, -1);
        if bi < 0 || !blks[bi].has_unknown {
            var added = false;
            let ns = block_nsucc(bb);
            for k in ns {
                let s = block_succ(bb, k);
                let sat = hm_get(init_at, (s as i64) as u64, -1);
                if sat >= 0 {
                    let sn = hm_get(init_n, (s as i64) as u64, 0);
                    if added {
                        var tmp: i64[>..<] = [];
                        crl_intersect(crl, init_r[sat..sat + sn], tmp);
                        crl.resize(0);
                        for x in tmp { crl.push(x); }
                    } else {
                        crl.resize(0);
                        for x in init_r[sat..sat + sn] { crl.push(x); }
                        added = true;
                    }
                } else { crl.resize(0); break; }
            }
        }
        if bi >= 0 {
            // the block's instructions, sorted by position, walked backwards
            var ins: i32[>..<] = [];
            for j in fa_infos.len { if fa_infos[j].blk == bb { ins.push(j as i32); } }
            sort(ins) { x, y => comes_before(fa_infos[x].inst, fa_infos[y].inst) };
            var k = ins.len - 1;
            while k >= 0 {
                let inf = fa_infos[ins[k]];
                k--;
                if inf.kind == AAI_UNKNOWN || inf.kind == AAI_WRITE_SE { crl.resize(0); }
                if inf.rn > 0 {
                    let rs0 = inf.rr as i64;
                    let rs = fa_rr[rs0..rs0 + 2 * (inf.rn as i64)];
                    if inf.kind == AAI_WRITE || inf.kind == AAI_WRITE_SE {
                        var tmp: i64[>..<] = [];
                        crl_union(crl, rs, tmp);
                        crl.resize(0);
                        for x in tmp { crl.push(x); }
                    } else {
                        var q: i64 = 0;
                        while q < rs.len { crl_subtract(crl, rs[q], rs[q + 1]); q += 2; }
                    }
                }
            }
        }
    }
    var entry_crl: i64[>..<] = [];
    var only_entry = !write_outside_entry;
    if !only_entry {
        let ebi = hm_get(blk, (entry as i64) as u64, -1);
        if ebi >= 0 { only_entry = blks[ebi].has_unknown; }
    }
    if only_entry {
        visit_block(entry);
        if crl.len == 0 { return false; }
        for x in crl { entry_crl.push(x); }
    } else {
        var po: i32[>..<] = [];
        fa_post_order(f, po);
        for bb in po {
            visit_block(bb);
            if crl.len > 0 {
                hm_put(init_at, (bb as i64) as u64, init_r.len);
                hm_put(init_n, (bb as i64) as u64, crl.len);
                for x in crl { init_r.push(x); }
            }
        }
        let eat = hm_get(init_at, (entry as i64) as u64, -1);
        if eat < 0 { return false; }
        let en = hm_get(init_n, (entry as i64) as u64, 0);
        for x in init_r[eat..eat + en] { entry_crl.push(x); }
    }
    let prev_at = aset_find(fa_arg_set(a), AK_Initializes);
    if prev_at >= 0 {
        var prev: i64[>..<] = [];
        crl_from_attr(prev_at, prev);
        var same = prev.len == entry_crl.len;
        if same { for k in prev.len { if prev[k] != entry_crl[k] { same = false; } } }
        if same { return false; }
        var tmp: i64[>..<] = [];
        crl_union(entry_crl, prev, tmp);
        entry_crl.resize(0);
        for x in tmp { entry_crl.push(x); }
    }
    fa_arg_add(a, crl_attr(entry_crl));
    return true;
}

// post_order(&F): the blocks reachable from the entry in DFS post-order (successor order)
fn fa_post_order(f: i32, out: i32[>..<]&) {
    var visited = hm_new();
    var st_b: i32[>..<] = [];
    var st_k: i64[>..<] = [];
    let e = func_entry(f);
    hm_put(visited, (e as i64) as u64, 1);
    st_b.push(e);
    st_k.push(0);
    while st_b.len > 0 {
        let t = st_b.len - 1;
        let b = st_b[t];
        let k = st_k[t];
        if k < block_nsucc(b) {
            st_k[t] = k + 1;
            let s = block_succ(b, k);
            if !hm_has(visited, (s as i64) as u64) {
                hm_put(visited, (s as i64) as u64, 1);
                st_b.push(s);
                st_k.push(0);
            }
            continue;
        }
        out.push(b);
        st_b.pop();
        st_k.pop();
    }
}

// ---------------------------------------------------------------------------------------------
// addArgumentAttrs with the ArgumentGraph

// ArgumentGraph nodes: 0 = SyntheticRoot. Uses lists are linked (append at the tail).
var ag_def: i32[>..<];
var ag_cc: i64[>..<];
var ag_uhead: i32[>..<];
var ag_utail: i32[>..<];
var ag_unode: i32[>..<];   // use-list cell -> node
var ag_unext: i32[>..<];
var ag_map = hm_new();     // argument -> node

fn ag_reset() {
    ag_def.resize(0); ag_cc.resize(0); ag_uhead.resize(0); ag_utail.resize(0); ag_unode.resize(0); ag_unext.resize(0);
    hm_clear(ag_map);
    ag_def.push(-1); ag_cc.push(0); ag_uhead.push(-1); ag_utail.push(-1);
}
fn ag_add_use(n: i32, t: i32) {
    let c = ag_unode.len as i32;
    ag_unode.push(t);
    ag_unext.push(-1);
    if ag_utail[n] >= 0 { ag_unext[ag_utail[n]] = c; } else { ag_uhead[n] = c; }
    ag_utail[n] = c;
}
// ArgumentGraph::operator[]: the node (created on first use); every call appends it to the root's Uses
fn ag_node(a: i32) -> i32 {
    var n = hm_get(ag_map, (a as i64) as u64, -1) as i32;
    if n < 0 {
        n = ag_def.len as i32;
        ag_def.push(a); ag_cc.push(0); ag_uhead.push(-1); ag_utail.push(-1);
        hm_put(ag_map, (a as i64) as u64, n as i64);
    }
    ag_add_use(0, n);
    return n;
}

// The ArgumentUsesTracker: PointerMayBeCaptured(A, &Tracker) with capture.goose's CTK_ARGUSES kind; returns
// the tracker's CaptureInfo and leaves Tracker.Uses in fa_tracker_uses.
var fa_tracker_uses: i32[>..<];

fn fa_add_argument_attrs(skip_initializes: bool) {
    ag_reset();
    for f in fa_scc {
        if !fa_has_exact_definition(f) { continue; }
        if fa_add_argument_attrs_from_callsites(f) { fa_mark_changed(f); }
        if fa_only_reads_memory(f) && fa_fn_has(f, AK_NoUnwind) && fa_fn_has(f, AK_WillReturn) && ty_kind(fa_ret_ty(f)) == TK_VOID {
            for k in func_nargs(f) {
                let a = func_arg(f, k);
                if ty_kind(vals[a].ty) == TK_PTR && !cc_nothing(ci_other(fa_arg_capture_info(a)) | ci_ret(fa_arg_capture_info(a))) {
                    fa_arg_add(a, fa_capture_attr(0));
                    fa_mark_changed(f);
                }
            }
            continue;
        }
        for k in func_nargs(f) {
            let a = func_arg(f, k);
            if ty_kind(vals[a].ty) != TK_PTR { continue; }
            var has_nonlocal = false;
            let orig = fa_arg_capture_info(a);
            if orig != 0 {
                fa_tracker_uses.resize(0);
                ct_arg_scc.resize(0);
                for g in fa_scc { if fa_has_exact_definition(g) { ct_arg_scc.push(g); } }
                let tci = ct_argument_uses_tracker(a);
                for x in ct_arg_uses { fa_tracker_uses.push(x); }
                let nci = tci & orig;
                if nci != orig {
                    if fa_tracker_uses.len == 0 {
                        fa_arg_add(a, fa_capture_attr(nci));
                        fa_mark_changed(f);
                    } else {
                        let node = ag_node(a);
                        ag_cc[node] = ci_other(nci) | ci_ret(nci);
                        for x in fa_tracker_uses {
                            let un = ag_node(x);
                            ag_add_use(node, un);
                            if x != a { has_nonlocal = true; }
                        }
                    }
                }
            }
            if !has_nonlocal && !fa_arg_only_reads(a) {
                if fa_determine_access_singleton(a) { fa_mark_changed(f); }
            }
            if !skip_initializes && !fa_arg_only_reads(a) {
                if fa_infer_initializes(a, f) { fa_mark_changed(f); }
            }
        }
    }
    // scc_iterator over the ArgumentGraph from the synthetic root
    let nn = ag_def.len;
    var visit_num: i64[>..<] = [];
    for k in nn { visit_num.push(0); }
    var counter: i64 = 0;
    var node_stack: i32[>..<] = [];
    var vs_node: i32[>..<] = [];
    var vs_edge: i32[>..<] = [];
    var vs_min: i64[>..<] = [];
    var scc: i32[>..<] = [];
    fn visit_one(n: i32) {
        counter++;
        visit_num[n] = counter;
        node_stack.push(n);
        vs_node.push(n);
        vs_edge.push(ag_uhead[n]);
        vs_min.push(counter);
    }
    visit_one(0);
    while vs_node.len > 0 {
        loop {
            let t = vs_node.len - 1;
            let e = vs_edge[t];
            if e < 0 { break; }
            vs_edge[t] = ag_unext[e];
            let c = ag_unode[e];
            if visit_num[c] == 0 { visit_one(c); continue; }
            if vs_min[t] > visit_num[c] { vs_min[t] = visit_num[c]; }
        }
        let t = vs_node.len - 1;
        let vn = vs_node[t];
        let mn = vs_min[t];
        vs_node.pop();
        vs_edge.pop();
        vs_min.pop();
        if vs_node.len > 0 && vs_min[vs_node.len - 1] > mn { vs_min[vs_node.len - 1] = mn; }
        if mn != visit_num[vn] { continue; }
        scc.resize(0);
        loop {
            let x = node_stack.pop();
            scc.push(x);
            visit_num[x] = 0x7FFFFFFFFFFFFFFF;
            if x == vn { break; }
        }
        fa_process_arg_scc(scc);
    }
}

fn fa_process_arg_scc(scc: i32[:]) {
    if scc.len == 1 {
        let n = scc[0];
        if ag_def[n] < 0 { return; }
        let h = ag_uhead[n];
        if h >= 0 && ag_unext[h] < 0 && ag_unode[h] == n {
            let a = ag_def[n];
            let orig = fa_arg_capture_info(a);
            let nci = ci_make(ag_cc[n], ag_cc[n]) & orig;
            if nci != orig {
                fa_arg_add(a, fa_capture_attr(nci));
                fa_mark_changed(fa_arg_fn(a));
            }
            if fa_determine_access_singleton(a) { fa_mark_changed(fa_arg_fn(a)); }
        }
        return;
    }
    var scc_args: i32[>..] = [];
    for n in scc { scc_args.push(ag_def[n]); }
    fn in_args(a: i32) -> bool { for x in scc_args { if x == a { return true; } } return false; }
    var cc: i64 = 0;
    for n in scc {
        let h = ag_uhead[n];
        if h >= 0 {
            let un = ag_unode[h];
            let a = ag_def[un];
            if in_args(a) { cc |= ag_cc[un]; }
            else { let ci = fa_arg_capture_info(a); cc |= ci_other(ci) | ci_ret(ci); }
        }
        if cc == CC_ALL { break; }
    }
    if cc != CC_ALL {
        for n in scc {
            let a = ag_def[n];
            let orig = fa_arg_capture_info(a);
            let c2 = ag_cc[n] | cc;
            let nci = ci_make(c2, c2) & orig;
            if nci != orig {
                fa_arg_add(a, fa_capture_attr(nci));
                fa_mark_changed(fa_arg_fn(a));
            }
        }
    }
    if cc_any_provenance(cc) {
        for n in scc { if fa_determine_access_singleton(ag_def[n]) { fa_mark_changed(fa_arg_fn(ag_def[n])); } }
        return;
    }
    var props: i64 = 0;
    for n in scc {
        props |= fa_determine_pointer_access(ag_def[n], scc_args);
        if props == AP_ALL { break; }
    }
    if props != AP_ALL {
        for n in scc { if fa_add_access_attrs(ag_def[n], props) { fa_mark_changed(fa_arg_fn(ag_def[n])); } }
    }
}

// ---------------------------------------------------------------------------------------------
// Return attributes

// FlowsToReturn: a SmallSetVector of values
fn fa_flows_insert(v: i32[>..<]&, x: i32) { for y in v { if y == x { return; } } v.push(x); }
fn fa_collect_returns(f: i32, out: i32[>..<]&) {
    var b = func_first_block(f);
    while b >= 0 {
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_RET { fa_flows_insert(out, op(t, 0)); }
        b = block_next(b);
    }
}

// isFunctionMallocLike
fn fa_is_function_malloc_like(f: i32) -> bool {
    var flows: i32[>..<] = [];
    fa_collect_returns(f, flows);
    var i: i64 = 0;
    while i < flows.len {
        let rv = flows[i];
        i++;
        if is_constant(rv) {
            if !is_null_value(rv) && vals[rv].kind != VK_UNDEF && vals[rv].kind != VK_POISON { return false; }
            continue;
        }
        if is_arg(rv) { return false; }
        if is_inst(rv) {
            let o = iop(rv);
            if o == OP_BITCAST || o == OP_GEP || o == OP_ADDRSPACECAST { fa_flows_insert(flows, op(rv, 0)); continue; }
            if o == OP_SELECT { fa_flows_insert(flows, op(rv, 1)); fa_flows_insert(flows, op(rv, 2)); continue; }
            if o == OP_PHI { for k in nops(rv) { fa_flows_insert(flows, op(rv, k)); } continue; }
            if o == OP_ALLOCA {
            } else if o == OP_CALL || o == OP_INVOKE {
                let cf = called_function(rv);
                if !(cb_has_ret_attr(rv, AK_NoAlias) || (cf >= 0 && fa_in_scc(cf))) { return false; }
            } else { return false; }
        }
        if ct_may_be_captured_bool(rv, false) { return false; }
    }
    return true;
}

fn fa_add_noalias_attrs() {
    for f in fa_scc {
        if fn_has(f, 1, AK_NoAlias) { continue; }
        if !fa_has_exact_definition(f) { return; }
        if ty_kind(fa_ret_ty(f)) != TK_PTR { continue; }
        if !fa_is_function_malloc_like(f) { return; }
    }
    for f in fa_scc {
        if fn_has(f, 1, AK_NoAlias) || ty_kind(fa_ret_ty(f)) != TK_PTR { continue; }
        fn_add_attr(f, 1, attr_enum(AK_NoAlias));
        fa_mark_changed(f);
    }
}

// isKnownNonZero(V, DL): a SimplifyQuery with only the DataLayout
fn fa_known_non_zero(v: i32) -> bool {
    let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
    let r = is_known_non_zero(v, 0);
    sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
    return r;
}

// isReturnNonNull -> (nonnull, speculative)
fn fa_is_return_non_null(f: i32) -> bool, bool {
    var spec = false;
    var flows: i32[>..<] = [];
    fa_collect_returns(f, flows);
    var i: i64 = 0;
    while i < flows.len {
        let rv = flows[i];
        i++;
        if fa_known_non_zero(rv) { continue; }
        if !is_inst(rv) { return false, spec; }
        let o = iop(rv);
        if o == OP_BITCAST || o == OP_ADDRSPACECAST { fa_flows_insert(flows, op(rv, 0)); continue; }
        if o == OP_GEP {
            if gep_is_inbounds(rv) { fa_flows_insert(flows, op(rv, 0)); continue; }
            return false, spec;
        }
        if o == OP_SELECT { fa_flows_insert(flows, op(rv, 1)); fa_flows_insert(flows, op(rv, 2)); continue; }
        if o == OP_PHI { for k in nops(rv) { fa_flows_insert(flows, op(rv, k)); } continue; }
        if o == OP_CALL || o == OP_INVOKE {
            let cf = called_function(rv);
            if cf >= 0 && fa_in_scc(cf) { spec = true; continue; }
            return false, spec;
        }
        return false, spec;
    }
    return true, spec;
}
fn gep_is_inbounds(g: i32) -> bool { (insts[inst_of(g)].flags & GEP_INBOUNDS) != 0 }

fn fa_add_nonnull_attrs() {
    var scc_nonnull = true;
    for f in fa_scc {
        if fn_has(f, 1, AK_NonNull) { continue; }
        if !fa_has_exact_definition(f) { return; }
        if ty_kind(fa_ret_ty(f)) != TK_PTR { continue; }
        let nn, spec = fa_is_return_non_null(f);
        if nn {
            if !spec { fn_add_attr(f, 1, attr_enum(AK_NonNull)); fa_mark_changed(f); }
            continue;
        }
        scc_nonnull = false;
    }
    if scc_nonnull {
        for f in fa_scc {
            if fn_has(f, 1, AK_NonNull) || ty_kind(fa_ret_ty(f)) != TK_PTR { continue; }
            fn_add_attr(f, 1, attr_enum(AK_NonNull));
            fa_mark_changed(f);
        }
    }
}

fn fa_add_noundef_attrs() {
    for f in fa_scc {
        if fn_has(f, 1, AK_NoUndef) { continue; }
        if !fa_has_exact_definition(f) { return; }
        if fa_fn_has(f, AK_SanitizeMemory) { continue; }
        if ty_kind(fa_ret_ty(f)) == TK_VOID { continue; }
        let rs = fn_aset(f, 1);
        var all = true;
        var b = func_first_block(f);
        while b >= 0 && all {
            let t = block_terminator(b);
            if t >= 0 && iop(t) == OP_RET {
                let rv = op(t, 0);
                kb_cxt = -1;
                if !fa_not_undef_or_poison(rv) { all = false; }
                else if aset_has(rs, AK_NonNull) && !fa_known_non_zero(rv) { all = false; }
                else {
                    let al = aset_find(rs, AK_Alignment);
                    if al >= 0 && pointer_alignment(rv) < (attrs[al].i1 as i64) { all = false; }
                    if all && range_attr_cr(rs) {
                        let want = vt_cr;
                        let sdt = sq_no_dt; let sac = sq_no_ac;
                        kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
                        let got = compute_constant_range(rv, false, true, 0);
                        sq_no_dt = sdt; sq_no_ac = sac;
                        if !rg_contains(want, got) { all = false; }
                    }
                    let fpc = fa_nofpclass(rs);
                    if all && fpc != 0 {
                        let sdt = sq_no_dt; let sac = sq_no_ac;
                        kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
                        let k = kfc_compute_all(rv, FCL_ALL, 0);
                        sq_no_dt = sdt; sq_no_ac = sac;
                        if (k.known & fpc) != 0 { all = false; }
                    }
                }
            }
            b = block_next(b);
        }
        if all {
            fn_add_attr(f, 1, attr_enum(AK_NoUndef));
            fa_mark_changed(f);
        }
    }
}
// isGuaranteedNotToBeUndefOrPoison(V) (no context, no DT, no AC)
fn fa_not_undef_or_poison(v: i32) -> bool {
    let sdt = sq_no_dt; let sac = sq_no_ac;
    sq_no_dt = true; sq_no_ac = true;
    let r = is_guaranteed_not_to_be_undef_or_poison(v, -1, 0);
    sq_no_dt = sdt; sq_no_ac = sac;
    return r;
}

// ---------------------------------------------------------------------------------------------
// AttributeInferer: convergent; nounwind, nofree, nosync

let FI_CONVERGENT: i64 = 0;
let FI_NOUNWIND: i64 = 1;
let FI_NOFREE: i64 = 2;
let FI_NOSYNC: i64 = 3;

fn fi_skip(id: i64, f: i32) -> bool {
    if id == FI_CONVERGENT { return !fa_fn_has(f, AK_Convergent); }
    if id == FI_NOUNWIND { return fa_fn_has(f, AK_NoUnwind); }
    if id == FI_NOFREE { return fa_fn_has(f, AK_NoFree) || fa_only_reads_memory(f); }   // doesNotFreeMemory
    return fa_fn_has(f, AK_NoSync);
}
fn fi_requires_exact(id: i64) -> bool { id != FI_CONVERGENT }
fn fi_kind(id: i64) -> i64 { id }
fn fi_breaks(id: i64, i: i32) -> bool {
    if id == FI_CONVERGENT {
        return is_callbase(i) && call_has_fn_attr(i, AK_Convergent) && !fa_in_scc(called_function(i));
    }
    if id == FI_NOUNWIND {
        if !fa_inst_may_throw(i, true) { return false; }
        if iop(i) == OP_CALL { let c = called_function(i); if c >= 0 && fa_in_scc(c) { return false; } }
        return true;
    }
    if id == FI_NOFREE {
        if !is_callbase(i) { return inst_may_synchronize(i); }
        if call_has_fn_attr(i, AK_NoFree) { return false; }
        let c = called_function(i);
        if c >= 0 && fa_in_scc(c) { return false; }
        return true;
    }
    if !inst_may_synchronize(i) { return false; }
    if is_callbase(i) { let c = called_function(i); if c >= 0 && fa_in_scc(c) { return false; } }
    return true;
}
fn fi_set(id: i64, f: i32) {
    if id == FI_CONVERGENT { fa_remove_fn_attr(f, AK_Convergent); return; }
    if id == FI_NOUNWIND { fa_set_fn_enum(f, AK_NoUnwind); return; }
    if id == FI_NOFREE { fa_set_fn_enum(f, AK_NoFree); return; }
    fa_set_fn_enum(f, AK_NoSync);
}

// AttributeInferer::run over the descriptors in `ids`
fn fi_run(ids: i64[:]) {
    var in_scc: i64[>..<] = [];
    for x in ids { in_scc.push(x); }
    for f in fa_scc {
        if in_scc.len == 0 { return; }
        var keep: i64[>..<] = [];
        for id in in_scc {
            if fi_skip(id, f) { keep.push(id); continue; }
            if func_is_decl(f) || (fi_requires_exact(id) && !fa_has_exact_definition(f)) { continue; }
            keep.push(id);
        }
        in_scc.resize(0);
        for x in keep { in_scc.push(x); }
        var this_fn: i64[>..<] = [];
        for id in in_scc { if !fi_skip(id, f) { this_fn.push(id); } }
        if this_fn.len == 0 { continue; }
        var done = false;
        each_inst(f) { i =>
            if !done {
                var k2: i64[>..<] = [];
                for id in this_fn {
                    if !fi_breaks(id, i) { k2.push(id); continue; }
                    var rest: i64[>..<] = [];
                    for d in in_scc { if fi_kind(d) != fi_kind(id) { rest.push(d); } }
                    in_scc.resize(0);
                    for x in rest { in_scc.push(x); }
                }
                this_fn.resize(0);
                for x in k2 { this_fn.push(x); }
                if this_fn.len == 0 { done = true; }
            }
        };
    }
    if in_scc.len == 0 { return; }
    for f in fa_scc {
        for id in in_scc {
            if fi_skip(id, f) { continue; }
            fa_mark_changed(f);
            fi_set(id, f);
        }
    }
}

fn fa_infer_convergent() { fi_run([FI_CONVERGENT]); }
fn fa_infer_attrs_from_function_bodies() {
    var ids: i64[>..] = [];
    if !flag_bool("disable-nounwind-inference", false) { ids.push(FI_NOUNWIND); }
    if !flag_bool("disable-nofree-inference", false) { ids.push(FI_NOFREE); }
    ids.push(FI_NOSYNC);
    fi_run(ids);
}

// ---------------------------------------------------------------------------------------------
// norecurse, noreturn, cold, willreturn

// mayHaveRecursiveCallee
fn fa_may_have_recursive_callee(f: i32, any_address_taken: bool) -> bool {
    var b = func_first_block(f);
    while b >= 0 {
        var i = block_first(b);
        while i >= 0 {
            if is_callbase(i) {
                let c = called_function(i);
                if c < 0 || c == f { return true; }
                if !fa_fn_has(c, AK_NoRecurse) {
                    if !(!any_address_taken || (func_is_decl(c) && fa_fn_has(c, AK_NoCallback))) { return true; }
                }
            }
            i = inst_next(i);
        }
        b = block_next(b);
    }
    return false;
}
fn fa_add_norecurse_attrs() {
    if fa_scc.len != 1 { return; }
    let f = fa_scc[0];
    if !fa_has_exact_definition(f) || fa_fn_has(f, AK_NoRecurse) { return; }
    if !fa_may_have_recursive_callee(f, true) { fa_set_fn_enum(f, AK_NoRecurse); fa_mark_changed(f); }
}

// llvm::canReturn
fn fa_can_return(f: i32) -> bool {
    var visited = hm_new();
    var wl: i32[>..<] = [];
    let e = func_entry(f);
    hm_put(visited, (e as i64) as u64, 1);
    wl.push(e);
    while wl.len > 0 {
        let b = wl.pop();
        let t = block_terminator(b);
        if t >= 0 && iop(t) == OP_RET {
            var noret = false;
            var i = block_first(b);
            while i >= 0 { if is_callbase(i) && call_has_fn_attr(i, AK_NoReturn) { noret = true; } i = inst_next(i); }
            if !noret { return true; }
        }
        let ns = block_nsucc(b);
        for k in ns {
            let s = block_succ(b, k);
            if !hm_has(visited, (s as i64) as u64) { hm_put(visited, (s as i64) as u64, 1); wl.push(s); }
        }
    }
    return false;
}
fn fa_add_noreturn_attrs() {
    for f in fa_scc {
        if !fa_has_exact_definition(f) || fa_fn_has(f, AK_Naked) || fa_fn_has(f, AK_NoReturn) { continue; }
        if !fa_can_return(f) { fa_set_fn_enum(f, AK_NoReturn); fa_mark_changed(f); }
    }
}

// allPathsGoThroughCold
fn fa_all_paths_cold(f: i32) -> bool {
    var cold = hm_new();      // block -> 1 (cold) / 0
    var jobs: i32[>..<] = [];
    let e = func_entry(f);
    hm_put(cold, (e as i64) as u64, 0);
    jobs.push(e);
    while jobs.len > 0 {
        let b = jobs.pop();
        var has_cold = false;
        var i = block_first(b);
        while i >= 0 { if is_callbase(i) && call_has_fn_attr(i, AK_Cold) { has_cold = true; break; } i = inst_next(i); }
        if has_cold { hm_put(cold, (b as i64) as u64, 1); continue; }
        let ns = block_nsucc(b);
        if ns == 0 { return false; }
        for k in ns {
            let s = block_succ(b, k);
            let c = hm_get(cold, (s as i64) as u64, -1);
            if c >= 0 {
                if c == 1 { continue; }
                return false;
            }
            hm_put(cold, (s as i64) as u64, 0);
            jobs.push(s);
        }
    }
    return true;
}
fn fa_add_cold_attrs() {
    for f in fa_scc {
        if !fa_has_exact_definition(f) || fa_fn_has(f, AK_Naked) || fa_fn_has(f, AK_Cold) || fa_fn_has(f, AK_Hot) { continue; }
        if fa_all_paths_cold(f) { fa_set_fn_enum(f, AK_Cold); fa_mark_changed(f); }
    }
}

// functionWillReturn
fn fa_function_will_return(f: i32) -> bool {
    if !fa_has_exact_definition(f) { return false; }
    if fa_fn_has(f, AK_MustProgress) && fa_only_reads_memory(f) { return true; }
    if func_is_decl(f) { return false; }
    var be: i32[>..<] = [];
    cu_find_function_backedges(f, be);
    if be.len > 0 { return false; }
    var all = true;
    each_inst(f) { i => if all && !inst_will_return(i) { all = false; } };
    return all;
}
fn fa_add_will_return() {
    for f in fa_scc {
        if fa_fn_has(f, AK_WillReturn) || !fa_function_will_return(f) { continue; }
        fa_set_fn_enum(f, AK_WillReturn);
        fa_mark_changed(f);
    }
}

// ---------------------------------------------------------------------------------------------
// The passes

// deriveAttrsInPostOrder (functions = the SCC's, in its order)
fn fa_derive_attrs_in_post_order(fns: i32[:], arg_attrs_only: bool) {
    fa_scc.resize(0);
    fa_changed.resize(0);
    for f in fns {
        if fa_fn_has(f, AK_OptimizeNone) || fa_fn_has(f, AK_Naked) || fa_fn_has(f, AK_PresplitCoroutine) { continue; }
        fa_scc.push(f);
    }
    if fa_scc.len == 0 { return; }
    if arg_attrs_only { fa_add_argument_attrs(true); return; }
    fa_add_argument_returned_attrs();
    fa_add_memory_attrs();
    fa_add_argument_attrs(false);
    fa_infer_convergent();
    fa_add_noreturn_attrs();
    fa_add_cold_attrs();
    fa_add_will_return();
    fa_add_noundef_attrs();
    fa_add_noalias_attrs();
    fa_add_nonnull_attrs();
    fa_infer_attrs_from_function_bodies();
    fa_add_norecurse_attrs();
    for f in fa_scc { if infer_attributes_from_others(f) { fa_mark_changed(f); } }
}

// PostOrderFunctionAttrsPass::run
fn fa_run_cgscc(c: i32, skip_nonrec: bool) -> u32 {
    var arg_only = false;
    if lcg_scc_size(c) == 1 && skip_nonrec {
        let n = lcg_scc_node(c, 0);
        if lcg_seq_lookup(n, n) < 0 { arg_only = true; }
    }
    var fns: i32[>..] = [];
    let n = lcg_scc_size(c);
    for k in n { fns.push(lcg_fn(lcg_scc_node(c, k))); }
    tli_cur_fn = fns[0];
    fa_derive_attrs_in_post_order(fns, arg_only);
    if fa_changed.len == 0 { return PA_ALL; }
    for f in fa_changed {
        tli_cur_fn = f;
        invalidate_function(f, PA_CFG);
        var u = first_use(f);
        while u >= 0 {
            let us = uses[u].user;
            if is_inst(us) && is_callbase(us) && cb_callee(us) == f { invalidate_function(inst_func(us), PA_CFG); }
            u = use_next(u);
        }
    }
    return PA_FN | ((1 as u32) << A_FAMPROXY);
}

// addNoRecurseAttrsTopDown
fn fa_add_norecurse_top_down(f: i32) -> bool {
    if fa_fn_has(f, AK_NoRecurse) { return false; }
    var u = first_use(f);
    while u >= 0 {
        let us = uses[u].user;
        // a BlockAddress is not a user of its function in LLVM 23
        if vals[us].kind == VK_BLOCKADDR { u = use_next(u); continue; }
        if !is_inst(us) || !is_callbase(us) || (u - vals[us].ops) as i64 != nops(us) - 1 || !fa_fn_has(inst_func(us), AK_NoRecurse) { return false; }
        u = use_next(u);
    }
    fa_set_fn_enum(f, AK_NoRecurse);
    return true;
}

// addNoFPClassAttrsTopDown
fn fa_add_nofpclass_top_down(f: i32) -> bool {
    let na = func_nargs(f);
    var argm: u64[>..<] = [];
    for k in na { argm.push(FCL_ALL); }
    var retm: u64 = FCL_ALL;
    var u = first_use(f);
    while u >= 0 {
        let us = uses[u].user;
        if vals[us].kind == VK_BLOCKADDR { u = use_next(u); continue; }
        if !is_inst(us) || !is_callbase(us) || called_function(us) != f { return false; }
        retm &= fa_cb_ret_nofpclass(us);
        for k in na {
            let a = cb_arg(us, k);
            if vals[a].kind == VK_CFP || (is_constant(a) && ty_is_vector(vals[a].ty) && fa_splat_fp(a) >= 0) {
                let cfp = if vals[a].kind == VK_CFP { a } else { fa_splat_fp(a) };
                argm[k] &= ~fa_fp_classify(cfp);
            } else {
                argm[k] &= fa_cb_param_nofpclass(us, k);
            }
        }
        u = use_next(u);
    }
    var changed = false;
    if retm != 0 {
        if fa_nofpclass(fn_aset(f, 1)) != retm { fn_add_attr(f, 1, attr_int(AK_NoFPClass, retm)); changed = true; }
    }
    for k in na {
        let m = argm[k];
        if m == 0 { continue; }
        if fa_nofpclass(fn_aset(f, 2 + k)) == m { continue; }
        fn_add_attr(f, 2 + k, attr_int(AK_NoFPClass, m));
        changed = true;
    }
    return changed;
}
// m_APFloat on a vector: the splat value (-1 if none)
fn fa_splat_fp(v: i32) -> i32 { let s = splat_value(v); if s >= 0 && vals[s].kind == VK_CFP { s } else { -1 } }
// APFloat::classify as an FPClassTest
fn fa_fp_classify(c: i32) -> u64 { cfp_class(c) }

// deduceFunctionAttributeInRPO
fn rpo_function_attrs_run(m: i32) -> u32 {
    lcg_get(m);
    lcg_build_ref_sccs();
    var wl: i32[>..] = [];
    var r = lcg_postorder_from(0);
    while r >= 0 {
        let nc = lcg_rc_size(r);
        for ci in nc {
            let c = lcg_rc_scc(r, ci);
            if lcg_scc_size(c) != 1 { continue; }
            let f = lcg_fn(lcg_scc_node(c, 0));
            if !func_is_decl(f) && gv_linkage(f) == LK_INTERNAL && fa_has_real_use(f) { wl.push(f); }
        }
        r = lcg_postorder_next(r);
    }
    var changed = false;
    var k = wl.len - 1;
    while k >= 0 {
        let f = wl[k];
        tli_cur_fn = f;
        if fa_add_norecurse_top_down(f) { changed = true; }
        if fa_add_nofpclass_top_down(f) { changed = true; }
        k--;
    }
    if !changed { return PA_ALL; }
    return (1 as u32) << A_LCG;
}

// NoRecurseLTOInferencePass::run
fn norecurse_lto_run(m: i32) -> u32 {
    var any_taken = false;
    var f = modules[m].first_func;
    while f >= 0 {
        if !func_is_decl(f) && !fa_fn_has(f, AK_NoRecurse) {
            if !gv_has_local_linkage(f) || fa_has_address_taken(f) { any_taken = true; break; }
        }
        f = globs[glob_of(f)].next;
    }
    var changed = false;
    lcg_get(m);
    lcg_build_ref_sccs();
    var r = lcg_postorder_from(0);
    while r >= 0 {
        if lcg_rc_size(r) == 1 {
            let c = lcg_rc_scc(r, 0);
            if lcg_scc_size(c) == 1 {
                let g = lcg_fn(lcg_scc_node(c, 0));
                if fa_has_exact_definition(g) && !fa_fn_has(g, AK_NoRecurse) {
                    if !fa_may_have_recursive_callee(g, any_taken) { fa_set_fn_enum(g, AK_NoRecurse); changed = true; }
                }
            }
        }
        r = lcg_postorder_next(r);
    }
    if changed { return (1 as u32) << A_LCG; }
    return PA_ALL;
}

// Function::hasAddressTaken() with the default arguments (assume-like calls ignored)
fn fa_has_address_taken(f: i32) -> bool { sc_has_address_taken(f) }
// !F.use_empty(), ignoring blockaddresses (not users of their function in LLVM 23)
fn fa_has_real_use(f: i32) -> bool {
    var u = first_use(f);
    while u >= 0 { if vals[uses[u].user].kind != VK_BLOCKADDR { return true; } u = use_next(u); }
    return false;
}
