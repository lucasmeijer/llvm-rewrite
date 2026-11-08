// Knowledge retention (--enable-knowledge-retention): port of salvageKnowledge and AssumeBuilderState from
// llvm/lib/Transforms/Utils/AssumeBundleBuilder.cpp, with getKnowledgeForValue / getKnowledgeFromBundle
// (llvm/lib/Analysis/AssumeBundleQueries.cpp), Value::stripInBoundsOffsets (llvm/lib/IR/Value.cpp) and
// GEPOperator::getMaxPreservedAlignment (llvm/lib/IR/Operator.cpp).
//
// LLVM passes that call salvageKnowledge: DCE, EarlyCSE (ported here), DSE, GVN, NewGVN, LICM, the inliner
// (not ported: they fail as "not implemented" anyway). The -O pipelines add AssumeSimplify passes when the flag
// is on; those pipelines are not ported either.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import pm;
import vt;
import local;
import assume;
import flags;
import mem2reg;

fn kn_enabled() -> bool { flag_bool("enable-knowledge-retention", false) }

// RetainedKnowledge { AttrKind, ArgValue, WasOn }; the AssumedKnowledgeMap is a MapVector (insertion order)
var kn_kind: i64[>..<];
var kn_on: i32[>..<];
var kn_arg: u64[>..<];
var kn_inst: i32 = -1;          // InstBeingModified
var kn_use_ac: bool = false;

fn kn_min_align(a: u64, b: u64) -> u64 {
    let x = a | b;
    return x & ((0 as u64) - x);
}

// GEPOperator::getMaxPreservedAlignment
fn kn_gep_max_preserved_align(g: i32) -> u64 {
    var result: u64 = (1 as u64) << 32;
    var t = gep_src_ty(g);
    for k in 1..nops(g) {
        let x = op(g, k);
        let is_ci = vals[x].kind == VK_CINT && !ty_is_vector(vals[x].ty);
        var offset: u64 = 0;
        if k > 1 && ty_is_struct(t) {
            let fi = (cint_lo(x) & 0xFFFFFFFF) as! i64;
            offset = dl_struct_offset(t, fi) as! u64;
            t = ty_field(t, fi);
        } else {
            var stride: i64 = 0;
            if k == 1 { stride = dl_alloc_size(t); }
            else { let et = types[t].a; stride = dl_gep_stride(t, et); t = et; }
            var cnt: u64 = 1;
            if is_ci {
                let a = ci_ap(x);
                cnt = if ap_active_bits(a) > 64 { 0xFFFFFFFFFFFFFFFF } else { ap_lo64(a) };
            }
            offset = (stride as! u64) * cnt;
        }
        result = kn_min_align(offset, result);
    }
    return result;
}

// Value::stripInBoundsOffsets(Func); with `align` the callback of canonicalizedKnowledge(Alignment)
fn kn_strip_inbounds(v0: i32, align: bool) -> i32 {
    if ty_kind(vals[v0].ty) != TK_PTR { return v0; }
    var visited: i32[>..<] = [];
    var v = v0;
    visited.push(v);
    loop {
        let o = opcode_of(v);
        if align && o == OP_GEP { kn_arg[kn_arg.len - 1] = kn_min_align(kn_arg[kn_arg.len - 1], kn_gep_max_preserved_align(v)); }
        if o == OP_GEP {
            if (gep_flags(v) & GEP_INBOUNDS) == 0 { return v; }
            v = op(v, 0);
        } else if o == OP_BITCAST {
            let nv = op(v, 0);
            if ty_kind(vals[nv].ty) != TK_PTR { return v; }
            v = nv;
        } else if o == OP_ADDRSPACECAST {
            v = op(v, 0);
        } else {
            if is_callbase(v) {
                let rv = returned_arg_operand(v);
                if rv >= 0 {
                    var seen = false;
                    for x in visited { if x == rv { seen = true; } }
                    if seen { return rv; }
                    visited.push(rv);
                    v = rv;
                    continue;
                }
            }
            return v;
        }
        var seen = false;
        for x in visited { if x == v { seen = true; } }
        if seen { return v; }
        visited.push(v);
    }
    return v;
}

// Value::getSingleUndroppableUse: -1 if none or several
fn kn_single_undroppable_use(v: i32) -> i32 {
    var r: i32 = -1;
    var u = vals[v].first_use;
    while u >= 0 {
        let us = uses[u].user;
        if !(is_inst(us) && inst_iid(us) == IID_assume) {
            if r >= 0 { return -1; }
            r = u;
        }
        u = uses[u].next;
    }
    return r;
}

fn kn_is_int_attr_kind(k: i64) -> bool { ATTR_CLASSES[k] as i64 == ATTR_CLASS_INT }

// isKnowledgeWorthPreserving
fn kn_worth_preserving(kind: i64, on: i32, arg: u64) -> bool {
    if kind == 0 { return false; }
    if on < 0 { return true; }
    if ty_kind(vals[on].ty) == TK_PTR {
        let u = get_underlying_object(on, 10);
        if is_inst_op(u, OP_ALLOCA) || is_global(u) { return false; }
    }
    if is_arg(on) {
        let at = aset_find(arg_attrs(on), kind);
        if at >= 0 && (!kn_is_int_attr_kind(kind) || attrs[at].i1 >= arg) { return false; }
        return true;
    }
    if is_inst(on) {
        local_have_tli = false;
        let dead = would_be_trivially_dead(on);
        local_have_tli = true;
        if dead {
            if vals[on].first_use < 0 { return false; }
            let su = kn_single_undroppable_use(on);
            if su >= 0 && uses[su].user == kn_inst { return false; }
        }
    }
    return true;
}

// getKnowledgeFromBundle(Assume, BOI): (kind, wasOn, arg); kind 0 = none
fn kn_from_bundle(a: i32, k: i64) -> i64, i32, u64 {
    let tag = sbytes(cb_bundle_tag(a, k));
    var kind: i64 = 0;
    for j in 1..AK_COUNT { if ATTR_NAMES[j] == tag { kind = j; } }
    if kind == 0 { return 0, -1, 0; }
    let b = cb_bundle_begin(a, k);
    let n = cb_bundle_count(a, k);
    var on: i32 = -1;
    if n > 0 { on = op(a, b); }
    var arg: u64 = 0;
    fn arg_or_1(x: i32) -> u64 {
        if vals[x].kind == VK_CINT && !ty_is_vector(vals[x].ty) { return cint_lo(x); }
        return 1;
    }
    if n > 1 { arg = arg_or_1(op(a, b + 1)); }
    if kind == AK_Alignment && n > 2 { arg = kn_min_align(arg, arg_or_1(op(a, b + 2))); }
    return kind, on, arg;
}

// tryToPreserveWithoutAddingAssume (DT = nullptr: EarlyCSE and DCE pass only the AssumptionCache)
fn kn_try_preserve_without_assume(kind: i64, on: i32, arg: u64) -> bool {
    if kn_inst < 0 || on < 0 || !kn_use_ac { return false; }
    ac_build(inst_func(kn_inst));
    var preserved = false;
    var to_update: i64 = -1;     // operand index in the assume
    var to_assume: i32 = -1;
    let save = sq_no_dt;
    sq_no_dt = true;
    for e in ac_val.len {
        if ac_val[e] != on { continue; }
        let a = ac_asm[e];
        let idx = ac_idx[e] as i64;
        if a < 0 || is_dead(a) || idx < 0 { continue; }
        let k2, on2, arg2 = kn_from_bundle(a, idx);
        if k2 == 0 { continue; }
        if on2 != on { continue; }
        if k2 != kind { continue; }
        // Filter
        if !valid_assume_for_context(a, kn_inst) { continue; }
        if arg2 >= arg { preserved = true; break; }
        if valid_assume_for_context(kn_inst, a) {
            preserved = true;
            to_update = cb_bundle_begin(a, idx) + 1;
            to_assume = a;
            break;
        }
    }
    sq_no_dt = save;
    if to_assume >= 0 { set_op(to_assume, to_update, c_int(T_I64, arg as! i64)); }
    return preserved;
}

// addKnowledge (after canonicalizedKnowledge)
fn kn_add_knowledge(kind: i64, on0: i32, arg0: u64) {
    var on = on0;
    var arg = arg0;
    if kind == AK_NonNull { on = kn_strip_inbounds(on, false); }
    else if kind == AK_Alignment {
        kn_arg.push(arg);
        on = kn_strip_inbounds(on, true);
        arg = kn_arg.pop();
    } else if kind == AK_Dereferenceable || kind == AK_DereferenceableOrNull {
        let base = strip_and_accumulate_offsets(on, false, false, false);
        let off = vt_off;
        if off >= 0 { arg = arg + (off as! u64); on = base; }
    }
    if !kn_worth_preserving(kind, on, arg) { return; }
    if kn_try_preserve_without_assume(kind, on, arg) { return; }
    for j in kn_kind.len {
        if kn_kind[j] == kind && kn_on[j] == on {
            if arg > kn_arg[j] { kn_arg[j] = arg; }
            return;
        }
    }
    kn_kind.push(kind);
    kn_on.push(on);
    kn_arg.push(arg);
}

fn kn_useful(kind: i64) -> bool {
    return kind == AK_NonNull || kind == AK_NoUndef || kind == AK_Alignment || kind == AK_Dereferenceable ||
           kind == AK_DereferenceableOrNull || kind == AK_Cold;
}

// addAttribute(Attr, WasOn)
fn kn_add_attribute(at: i32, on: i32) {
    let kind = attrs[at].kind as i64;
    if kind == 0 { return; }                                 // string attribute
    if ATTR_CLASSES[kind] as i64 == ATTR_CLASS_TYPE { return; }
    if !kn_useful(kind) { return; }
    var arg: u64 = 0;
    if kn_is_int_attr_kind(kind) { arg = attrs[at].i1; }
    kn_add_knowledge(kind, on, arg);
}

// CallBase::isPassingUndefUB
fn kn_passing_undef_ub(c: i32, k: i64) -> bool {
    return call_param_has_attr(c, k, AK_NoUndef) || call_param_has_attr(c, k, AK_Dereferenceable) ||
           call_param_has_attr(c, k, AK_DereferenceableOrNull);
}

fn kn_add_attr_list(c: i32, l: i32, nargs: i64) {
    for k in nargs {
        let s = alist_param(l, k);
        for j in aset_n(s) {
            let at = aset_attr(s, j);
            let ak = attrs[at].kind as i64;
            let poison_attr = ak == AK_NonNull || ak == AK_Alignment;
            if !poison_attr || kn_passing_undef_ub(c, k) { kn_add_attribute(at, cb_arg(c, k)); }
        }
    }
    let fs = alist_fn(l);
    for j in aset_n(fs) { kn_add_attribute(aset_attr(fs, j), -1); }
}

// addAccessedPtr
fn kn_add_accessed_ptr(i: i32, p: i32, t: i32, align_log: u8) {
    let ds = dl_store_size(t);
    if ds != 0 {
        kn_add_knowledge(AK_Dereferenceable, p, ds as! u64);
        if !null_pointer_is_defined(inst_func(i), ptr_as(vals[p].ty)) { kn_add_knowledge(AK_NonNull, p, 0); }
    }
    let al: u64 = if align_log == 0 { 1 } else { (1 as u64) << ((align_log - 1) as u64) };
    if al > 1 { kn_add_knowledge(AK_Alignment, p, al); }
}

// addInstruction
fn kn_add_instruction(i: i32) {
    let o = iop(i);
    if is_callbase(i) {
        kn_add_attr_list(i, insts[inst_of(i)].attrs, cb_nargs(i));
        let f = called_function(i);
        if f >= 0 { kn_add_attr_list(i, globs[glob_of(f)].attrs, func_nargs(f)); }
        return;
    }
    let x = insts[inst_of(i)];
    if o == OP_LOAD { kn_add_accessed_ptr(i, op(i, 0), vals[i].ty, x.align); return; }
    if o == OP_STORE { kn_add_accessed_ptr(i, op(i, 1), vals[op(i, 0)].ty, x.align); return; }
    if o == OP_ATOMICRMW { kn_add_accessed_ptr(i, op(i, 0), vals[op(i, 1)].ty, x.align); return; }
    if o == OP_CMPXCHG { kn_add_accessed_ptr(i, op(i, 0), vals[op(i, 1)].ty, x.align); return; }
}

// build(): the new llvm.assume (unattached), -1 if nothing to preserve
fn kn_build() -> i32 {
    if kn_kind.len == 0 { return -1; }
    let f = au_get_declaration(IID_assume, []);
    var opsv: i32[>..<] = [];
    opsv.push(c_true());
    var pairs: i32[>..<] = [];
    for j in kn_kind.len {
        var n: i32 = 0;
        if kn_on[j] >= 0 { opsv.push(kn_on[j]); n++; }
        if kn_arg[j] != 0 { opsv.push(c_int(T_I64, kn_arg[j] as! i64)); n++; }
        pairs.push(intern(ATTR_NAMES[kn_kind[j]]));
        pairs.push(n);
    }
    opsv.push(f);
    let ci = create_inst(OP_CALL, T_VOID, opsv);
    insts[inst_of(ci)].ty2 = globs[glob_of(f)].vty;
    cb_set_bundles(ci, 1, pairs, 0);
    return ci;
}

// salvageKnowledge(I, AC, DT = nullptr)
fn salvage_knowledge(i: i32, use_ac: bool) -> bool {
    if !kn_enabled() || is_terminator(i) { return false; }
    kn_kind.clear();
    kn_on.clear();
    kn_arg.clear();
    kn_inst = i;
    kn_use_ac = use_ac;
    kn_add_instruction(i);
    let a = kn_build();
    kn_inst = -1;
    if a < 0 { return false; }
    m2r_insert_before_adopting(a, i);
    if use_ac { ac_register_assumption(a); }
    return true;
}
