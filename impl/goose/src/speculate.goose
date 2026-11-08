// isSafeToSpeculativelyExecute (llvm/lib/Analysis/ValueTracking.cpp, isSafeToSpeculativelyExecuteWithOpcode),
// isDereferenceableAndAlignedPointer and mustSuppressSpeculation (llvm/lib/Analysis/Loads.cpp),
// Value::getPointerDereferenceableBytes / canBeFreed (llvm/lib/IR/Value.cpp), Instruction::hasUBImplyingAttrs.
//
// The query context (SimplifyQuery CxtI / AC / DT) is passed explicitly: spec_safe(i, cxt, use_ac). DT is never
// available (callers that have one aren't ported yet: fail loudly where it would matter). TLI is null.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import knownbits;
import memloc;
import apint;
import pm;
import vt;
import assume;

fn spec_not_ported(what: const u8[:]) { fatal(str("isSafeToSpeculativelyExecute: ", what, " is not ported yet")); }

// CallBase::isPassingUndefUB(ArgNo)
fn cb_is_passing_undef_ub(c: i32, k: i64) -> bool {
    return cb_param_has_attr(c, k, AK_NoUndef) || cb_param_has_attr(c, k, AK_Dereferenceable) ||
           cb_param_has_attr(c, k, AK_DereferenceableOrNull);
}

// Instruction::hasUBImplyingAttrs
fn inst_has_ub_implying_attrs(i: i32) -> bool {
    if !is_callbase(i) { return false; }
    for k in cb_nargs(i) { if cb_is_passing_undef_ub(i, k) { return true; } }
    return cb_has_ret_attr(i, AK_NoUndef) || cb_has_ret_attr(i, AK_Dereferenceable) ||
           cb_has_ret_attr(i, AK_DereferenceableOrNull);
}

// suppressSpeculativeLoadForSanitizers
fn spec_sanitizer_suppresses(i: i32) -> bool {
    let f = inst_func(i);
    return func_has_fn_attr(f, AK_SanitizeThread) || func_has_fn_attr(f, AK_SanitizeAddress) ||
           func_has_fn_attr(f, AK_SanitizeHWAddress);
}

// LoadInst::isUnordered: not volatile, ordering NotAtomic or Unordered
fn load_is_unordered(i: i32) -> bool {
    if inst_is_volatile(i) { return false; }
    return insts[inst_of(i)].ord <= 1;
}

// mustSuppressSpeculation(LoadInst)
fn must_suppress_speculation(li: i32) -> bool { !load_is_unordered(li) || spec_sanitizer_suppresses(li) }

// max(call-site, callee) return attribute integer (getRetDereferenceableBytes and friends)
fn cb_ret_attr_max(c: i32, kind: i64) -> u64 {
    var b: u64 = 0;
    let a = aset_find(alist_ret(insts[inst_of(c)].attrs), kind);
    if a >= 0 { b = attrs[a].i1; }
    let f = called_function(c);
    if f >= 0 {
        let x = aset_find(alist_ret(func_attrs(f)), kind);
        if x >= 0 && attrs[x].i1 > b { b = attrs[x].i1; }
    }
    return b;
}

fn md_limited_int(md: i32) -> u64 {
    let c = mds[md_op(md, 0)].extra;
    return ap_limited(ci_ap(c), 0xFFFFFFFFFFFFFFFF);
}

// Value::getPointerDereferenceableBytes(DL, CanBeNull, CanBeFreed): UseDerefAtPointSemantics is false, so
// CanBeFreed is always false. Returns (bytes, can_be_null).
fn ptr_deref_bytes(v: i32) -> u64, bool {
    var d: u64 = 0;
    var cbn = false;
    let k = vals[v].kind;
    if k == VK_ARG {
        d = ml_arg_int(v, AK_Dereferenceable);
        if d == 0 {
            let mt = ml_arg_mem_type(v);
            if mt >= 0 && ty_is_sized_spec(mt) { d = dl_store_size(mt) as u64; }
        }
        if d == 0 { d = ml_arg_int(v, AK_DereferenceableOrNull); cbn = true; }
        return d, cbn;
    }
    if is_callbase(v) {
        d = cb_ret_attr_max(v, AK_Dereferenceable);
        if d == 0 { d = cb_ret_attr_max(v, AK_DereferenceableOrNull); cbn = true; }
        return d, cbn;
    }
    if is_inst_op(v, OP_LOAD) || is_inst_op(v, OP_INTTOPTR) {
        let m = inst_get_md(v, md_kind_id("dereferenceable"));
        if m >= 0 { d = md_limited_int(m); }
        if d == 0 {
            let m2 = inst_get_md(v, md_kind_id("dereferenceable_or_null"));
            if m2 >= 0 { d = md_limited_int(m2); }
            cbn = true;
        }
        return d, cbn;
    }
    if is_inst_op(v, OP_ALLOCA) {
        let s, ok, sc = ml_alloca_size(v);
        if ok { return s, false; }
        return 0, false;
    }
    if k == VK_GVAR {
        let g = globs[glob_of(v)];
        if ty_is_sized_spec(g.vty) && g.linkage as i64 != LK_EXTERN_WEAK { return dl_store_size(g.vty) as u64, false; }
        return 0, false;
    }
    return 0, false;
}

recursive fn ty_is_sized_spec(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_VOID || k == TK_LABEL || k == TK_METADATA || k == TK_FUNC || k == TK_TOKEN { return false; }
    if k == TK_STRUCT {
        if (types[t].flags & TF_OPAQUE) != 0 { return false; }
        for j in types[t].cnt { if !ty_is_sized_spec(ty_field(t, j)) { return false; } }
        return true;
    }
    if k == TK_ARRAY || k == TK_FVEC || k == TK_SVEC { return ty_is_sized_spec(types[t].a); }
    if k == TK_TARGETEXT { spec_not_ported("target extension types"); }
    return true;
}

// The context of the current query (SimplifyQuery.CxtI and whether SQ.AC is set).
var spec_cxt: i32 = -1;
var spec_use_ac: bool = false;
var spec_visited: i32[>..<];

fn spec_known_nonzero(v: i32) -> bool {
    let save_cxt = kb_cxt;
    let save_dt = sq_no_dt;
    let save_ac = sq_no_ac;
    let save_tli = sq_no_tli;
    kb_cxt = spec_cxt;
    sq_no_dt = true;
    sq_no_ac = !spec_use_ac;
    sq_no_tli = true;
    let r = is_known_non_zero(v, 0);
    kb_cxt = save_cxt;
    sq_no_dt = save_dt;
    sq_no_ac = save_ac;
    sq_no_tli = save_tli;
    return r;
}

fn spec_valid_assume_for_context(i: i32, cx: i32) -> bool {
    let save_dt = sq_no_dt;
    sq_no_dt = true;
    let r = valid_assume_for_context(i, cx);
    sq_no_dt = save_dt;
    return r;
}

// isDereferenceableAndAlignedPointerViaAssumption(Ptr, Alignment, SQ, IgnoreFree = false,
// CheckSize = ArgValue >= Size) over getKnowledgeForValue(Ptr, {Dereferenceable, Alignment}, AC).
fn spec_deref_via_assumption(v: i32, align: i64, size: AP) -> bool {
    if spec_cxt < 0 { return false; }
    let save_cxt = kb_cxt;
    kb_cxt = spec_cxt;
    let save_ac = sq_no_ac;
    sq_no_ac = false;
    let ready = ac_ready();
    sq_no_ac = save_ac;
    kb_cxt = save_cxt;
    if !ready { return false; }
    let can_free = spec_can_be_freed(v);
    var aligned = pointer_alignment(v) >= align;
    var derefable = false;
    for k in ac_val.len {
        if ac_val[k] != v || ac_idx[k] < 0 { continue; }
        let a = ac_asm[k];
        if a < 0 || is_dead(a) { continue; }
        let bi = ac_idx[k] as i64;
        let tag = bundle_tag_name(a, bi);
        // getKnowledgeFromBundle: the attribute kind of the tag, WasOn, ArgValue
        let b0 = cb_bundle_begin(a, bi);
        let n = cb_bundle_count(a, bi);
        let is_align = tag == "align";
        let is_deref = tag == "dereferenceable";
        if n < 1 || op(a, b0) != v { continue; }
        if !is_align && !is_deref { continue; }
        var argv: u64 = 0;   // RetainedKnowledge::ArgValue without an argument
        if n > 1 {
            argv = if is_align { 1 } else { 0 };
            let c = op(a, b0 + 1);
            argv = if vals[c].kind == VK_CINT { ap_zext64(ci_ap(c)) } else { argv };
            if is_align && n > 2 {
                let c2 = op(a, b0 + 2);
                let off: u64 = if vals[c2].kind == VK_CINT { ap_zext64(ci_ap(c2)) } else { 1 };
                // MinAlign(ArgValue, offset)
                let x = argv | off;
                argv = x & (~x + 1);
            }
        }
        // Filter
        if !spec_valid_assume_for_context(a, spec_cxt) { continue; }
        if is_align {
            if argv >= align as u64 { aligned = true; }
        } else {
            if !derefable && (!can_free || spec_will_not_free_between(a, spec_cxt)) && !ap_ugt_u64(size, argv) {
                derefable = true;
            }
        }
        if aligned && derefable { return true; }
    }
    return false;
}

// Value::canBeFreed for a pointer
fn spec_can_be_freed(v: i32) -> bool {
    if is_constant(v) { return false; }
    if is_inst_op(v, OP_ALLOCA) { return false; }
    var f: i32 = -1;
    if is_arg(v) {
        for kind in [AK_ByVal, AK_StructRet, AK_InAlloca, AK_Preallocated, AK_ByRef] { if ml_arg_has(v, kind) { return false; } }
        f = args_parent[vals[v].sub];
        if me_only_reads(aset_memory(alist_fn(func_attrs(f)))) || func_has_fn_attr(f, AK_NoFree) { return false; }
        if (ml_arg_has(v, AK_NoFree) || ml_arg_has(v, AK_ReadOnly) || ml_arg_has(v, AK_ReadNone)) && ml_arg_has(v, AK_NoAlias) { return false; }
    }
    if is_inst_op(v, OP_INTTOPTR) && inst_get_md(v, md_kind_id("nofree")) >= 0 { return false; }
    if is_inst(v) { f = inst_func(v); }
    if f < 0 { return true; }
    if globs[glob_of(f)].gc < 0 { return true; }
    spec_not_ported("Value::canBeFreed with a garbage collector");
    return true;
}

// willNotFreeBetween(Assume, CtxI)
fn spec_will_not_free_between(asm_: i32, cx: i32) -> bool {
    var checked: i64 = 0;
    fn no_free_in(from: i32, to: i32, checked: i64&) -> bool {
        // [from, to): to = -1 means the end of the block
        var i = from;
        while i >= 0 && i != to {
            if checked > 32 { return false; }
            checked += 1;
            if is_callbase(i) {
                if !call_has_fn_attr(i, AK_NoFree) { return false; }
            } else if inst_may_synchronize(i) { return false; }
            i = inst_next(i);
        }
        return true;
    }
    let cbb = inst_parent(cx);
    let abb = inst_parent(asm_);
    if cbb == abb {
        if asm_ != cx && !comes_before(asm_, cx) { return false; }
        return no_free_in(asm_, cx, checked);
    }
    var cur = cbb;
    loop {
        if cur == abb { return no_free_in(asm_, -1, checked); }
        let pred = single_pred(cur);
        if pred < 0 { return false; }
        if !no_free_in(block_first(cur), if cur == cbb { cx } else { -1 }, checked) { return false; }
        cur = pred;
    }
    return false;
}

// static isDereferenceableAndAlignedPointer(V, Alignment, Size, SQ, IgnoreFree, Visited, MaxDepth)
recursive fn spec_deref_aligned(v: i32, align: i64, size: AP, depth: i64) -> bool {
    if depth == 0 { return false; }
    if position(spec_visited, v) >= 0 { return false; }
    spec_visited.push(v);
    let o = opcode_of(v);
    if o == OP_GEP {
        let ok, off = gep_accumulate_constant_offset(v);
        if !ok || off < 0 || off % align != 0 { return false; }
        let w = dl_ptr(ptr_as(vals[v].ty)).idx;
        let ofs = ap_add(ap_i64(off, w), ap_sext_or_trunc(size, w));
        return spec_deref_aligned(op(v, 0), align, ofs, depth - 1);
    }
    if o == OP_BITCAST && ty_kind(vals[op(v, 0)].ty) == TK_PTR {
        return spec_deref_aligned(op(v, 0), align, size, depth - 1);
    }
    if is_inst_op(v, OP_SELECT) {
        return spec_deref_aligned(op(v, 1), align, size, depth - 1) && spec_deref_aligned(op(v, 2), align, size, depth - 1);
    }
    // IsKnownDeref
    var known = true;
    let bytes, cbn = ptr_deref_bytes(v);
    if ap_ugt_u64(size, bytes) { known = false; }
    if known && cbn && !spec_known_nonzero(v) { known = false; }
    // CheckForFreed (use-dereferenceable-at-point-semantics): the object must not be freed between its
    // definition and the context
    if known && bytes != 0 && !is_inst_op(v, OP_ALLOCA) && vals[v].kind != VK_GVAR && spec_can_be_freed(v) {
        var defi: i32 = -1;
        if is_inst(v) {
            if iop(v) == OP_INVOKE { defi = block_first(invoke_normal_dest(v)); }
            else if !is_terminator(v) { defi = inst_next(v); }
            else { defi = v; }
        } else {
            defi = block_first(func_entry(args_parent[vals[v].sub]));
        }
        if spec_cxt < 0 || !spec_will_not_free_between(defi, spec_cxt) { known = false; }
    }
    if known && is_inst(v) && iop(v) != OP_ALLOCA {
        known = spec_cxt >= 0 && spec_valid_assume_for_context(v, spec_cxt);
    }
    if known { return pointer_alignment(v) >= align; }
    if is_callbase(v) {
        let rp = arg_aliasing_returned_ptr(v, true);
        if rp >= 0 { return spec_deref_aligned(rp, align, size, depth - 1); }
        // getObjectSize with TLI = null: only allocsize-attributed calls have a size.
        let f = called_function(v);
        if aset_has(alist_fn(insts[inst_of(v)].attrs), AK_AllocSize) || (f >= 0 && func_has_fn_attr(f, AK_AllocSize)) {
            spec_not_ported("getObjectSize of allocsize calls");
        }
    }
    if inst_iid(v) == IID_experimental_gc_relocate { spec_not_ported("gc.relocate"); }
    if o == OP_ADDRSPACECAST { return spec_deref_aligned(op(v, 0), align, size, depth - 1); }
    if spec_use_ac { return spec_deref_via_assumption(v, align, size); }
    return false;
}

// isDereferenceableAndAlignedPointer(V, Ty, Alignment, SQ)
fn spec_deref_aligned_ty(v: i32, ty: i32, align: i64) -> bool {
    if !ty_is_sized_spec(ty) || ty_kind(ty) == TK_SVEC || ty_has_scalable(ty) { return false; }
    let w = dl_ptr(ptr_as(vals[v].ty)).bits;
    spec_visited.clear();
    return spec_deref_aligned(v, align, ap_u64(dl_store_size(ty) as u64, w), 16);
}

recursive fn ty_has_scalable(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_SVEC { return true; }
    if k == TK_STRUCT { for j in types[t].cnt { if ty_has_scalable(ty_field(t, j)) { return true; } } return false; }
    if k == TK_ARRAY || k == TK_FVEC { return ty_has_scalable(types[t].a); }
    return false;
}

fn ldst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }

// isSafeToSpeculativelyExecute(Inst, CtxI, AC, DT = null, TLI = null, UseVariableInfo = true,
// IgnoreUBImplyingAttrs = true). use_ac says whether the caller passes an AssumptionCache.
fn spec_safe(i: i32, cxt: i32, use_ac: bool) -> bool { spec_safe_opc(iop(i), i, cxt, use_ac, true) }

fn spec_safe_opc(o: i64, i: i32, cxt: i32, use_ac: bool, ignore_ub_attrs: bool) -> bool {
    if o == OP_UDIV || o == OP_UREM {
        let c = m_apint(op(i, 1));
        if c >= 0 { return !ap_is_zero(ci_ap(c)); }
        return false;
    }
    if o == OP_SDIV || o == OP_SREM {
        let d = m_apint(op(i, 1));
        if d < 0 { return false; }
        let dv = ci_ap(d);
        if ap_is_zero(dv) { return false; }
        if !ap_is_all_ones(dv) { return true; }
        let n = m_apint(op(i, 0));
        if n >= 0 { return !ap_is_min_signed(ci_ap(n)); }
        return false;
    }
    if o == OP_LOAD {
        if must_suppress_speculation(i) { return false; }
        spec_cxt = cxt;
        spec_use_ac = use_ac;
        let r = spec_deref_aligned_ty(op(i, 0), vals[i].ty, ldst_align(i));
        spec_cxt = -1;
        spec_use_ac = false;
        return r;
    }
    if o == OP_CALL {
        let f = called_function(i);
        if f < 0 || !func_has_fn_attr(f, AK_Speculatable) { return false; }
        return ignore_ub_attrs || !inst_has_ub_implying_attrs(i);
    }
    if o == OP_VAARG || o == OP_ALLOCA || o == OP_INVOKE || o == OP_CALLBR || o == OP_PHI || o == OP_STORE ||
       is_terminator_op(o) || o == OP_FENCE || o == OP_ATOMICRMW || o == OP_CMPXCHG || o == OP_LANDINGPAD ||
       o == OP_CATCHPAD || o == OP_CLEANUPPAD { return false; }
    return true;
}
