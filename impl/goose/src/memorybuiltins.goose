// Port of the parts of llvm/lib/Analysis/MemoryBuiltins.cpp InstCombine uses: getAllocationData(ForFunction),
// getAllocationSize, getAllocFnKind, isAllocationFn, getReallocatedOperand, getAllocationFamily,
// getInitialValueOfAllocation, getAllocSize (with the visitor's Mapper), getObjectSize, lowerObjectSizeCall
// (the static path; ObjectSizeOffsetEvaluator for dynamic llvm.objectsize fails loudly) and
// ObjectSizeOffsetVisitor (all four evaluation modes, load tracking through AA). Plus
// MemoryLocation::getForDest(CallBase) (llvm/lib/Analysis/MemoryLocation.cpp) for the pointer it returns.
// isAllocLikeFn / isRemovableAlloc / getFreedOperand are in local.goose, the tables in gen_tli.goose.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import gen_tli;
import datalayout;
import apint;
import pm;
import vt;
import local;
import tli;
import memloc;
import aa;
import implied;
import cfold;
import constfold;
import instsimplify;

fn mb_not_ported(what: const u8[:]) { fatal(str("MemoryBuiltins: ", what, " is not ported yet")); }

// AllocType bits
let MB_OPNEW: i64 = 1;
let MB_MALLOC: i64 = 2;
let MB_STRDUP: i64 = 4;
let MB_MALLOC_OR_OPNEW: i64 = 3;
let MB_ALLOC_LIKE: i64 = 7;
let MB_ANY: i64 = 7;

// getAllocationDataForFunction(Callee, AllocTy, TLI): the TLI_ALLOC_DATA entry index (multiple of 6) or -1
fn mb_alloc_data_for_function(f: i32, alloc_ty: i64) -> i64 {
    let fty = globs[glob_of(f)].vty;
    if ty_kind(ty_fn_ret(fty)) != TK_PTR { return -1; }
    if !local_have_tli || sq_no_tli { return -1; }
    let lf = tli_get_libfunc(f);
    if lf < 0 || !tli_has(lf) { return -1; }
    var k: i64 = 0;
    while k < TLI_ALLOC_DATA.len {
        if TLI_ALLOC_DATA[k] == lf { break; }
        k += 6;
    }
    if k >= TLI_ALLOC_DATA.len { return -1; }
    let at = TLI_ALLOC_DATA[k + 1] as i64;
    if (at & alloc_ty) != at { return -1; }
    let np = TLI_ALLOC_DATA[k + 2] as i64;
    let fst = TLI_ALLOC_DATA[k + 3] as i64;
    let snd = TLI_ALLOC_DATA[k + 4] as i64;
    fn int3264(t: i32) -> bool { ty_is_int(t) && (ty_bits(t) == 32 || ty_bits(t) == 64) }
    if ty_fn_nparams(fty) == np && (fst < 0 || int3264(ty_fn_param(fty, fst))) && (snd < 0 || int3264(ty_fn_param(fty, snd))) {
        return k;
    }
    return -1;
}
// getAllocationData(V, AllocTy, TLI)
fn mb_alloc_data(v: i32, alloc_ty: i64) -> i64 {
    if !is_inst(v) { return -1; }
    let f = mb_called_function(v);
    if f < 0 { return -1; }
    return mb_alloc_data_for_function(f, alloc_ty);
}
fn mb_alloc_kind(v: i32) -> u64 { if is_callbase(v) { call_alloc_kind(v) } else { 0 } }

// getReallocatedOperand(CB)
fn mb_reallocated_operand(cb: i32) -> i32 {
    if !is_callbase(cb) { return -1; }
    if (call_alloc_kind(cb) & AFK_REALLOC) != 0 { return call_arg_with_attr(cb, AK_AllocatedPointer); }
    return -1;
}

// getAllocationFamily(I, TLI): an interned string id, -1 = none
fn mb_allocation_family(i: i32) -> i32 {
    if !is_inst(i) { return -1; }
    let f = mb_called_function(i);
    if f >= 0 && local_have_tli && !sq_no_tli {
        let lf = tli_get_libfunc(f);
        if lf >= 0 && tli_has(lf) {
            let k = mb_alloc_data_for_function(f, MB_ANY);
            if k >= 0 { return intern(TLI_FAMILY_NAMES[TLI_ALLOC_FAMILY[k / 6]]); }
            var j: i64 = 0;
            while j < TLI_FREE_DATA.len {
                if TLI_FREE_DATA[j] == lf { return intern(TLI_FAMILY_NAMES[TLI_FREE_FAMILY[j / 2]]); }
                j += 2;
            }
        }
    }
    if (mb_alloc_kind(i) & (AFK_FREE | AFK_ALLOC | AFK_REALLOC)) != 0 {
        let s = call_fn_str_attr_value(i, "alloc-family");
        if s >= 0 { return s; }
    }
    return -1;
}
// CallBase::getFnAttr(Kind): the call site's, else the callee's; returns the string value id or -1
fn call_fn_str_attr_value(c: i32, key: const u8[:]) -> i32 {
    var a = aset_find_str(alist_fn(insts[inst_of(c)].attrs), key);
    if a >= 0 { return attrs[a].sval; }
    let f = called_function(c);
    if f >= 0 {
        a = aset_find_str(alist_fn(globs[glob_of(f)].attrs), key);
        if a >= 0 { return attrs[a].sval; }
    }
    return -1;
}

// getInitialValueOfAllocation(V, TLI, Ty): -1 = nullptr
fn mb_initial_value_of_allocation(v: i32, ty: i32) -> i32 {
    if is_inst_op(v, OP_ALLOCA) { return c_undef(ty); }
    if !is_callbase(v) { return -1; }
    if mb_alloc_data(v, MB_MALLOC_OR_OPNEW) >= 0 { return c_undef(ty); }
    let ak = call_alloc_kind(v);
    if (ak & 8) != 0 { return c_undef(ty); }     // Uninitialized
    if (ak & 16) != 0 { return c_null(ty); }     // Zeroed
    return -1;
}

// MemoryLocation::getForDest(CB, TLI) for a call that is not an intrinsic: the pointer, or -1
fn mb_memloc_for_dest(cb: i32) -> i32 {
    // WriteME = getMemoryEffects() & MemoryEffects::writeOnly(): the Mod bits of every location
    let wme = call_memory_effects(cb) & 0xAAA;
    if !me_only_arg(wme) { return -1; }
    if cb_nbundles(cb) > 0 { return -1; }
    var used: i32 = -1;
    for k in cb_nargs(cb) {
        let a = cb_arg(cb, k);
        if ty_kind(vals[a].ty) != TK_PTR { continue; }
        if cb_arg_only_reads(cb, k) { continue; }
        if used < 0 { used = a; continue; }
        if used != a { return -1; }
    }
    return used;
}

// ---------------------------------------------------------------------------------------------
// Object sizes

let OSM_EXACT_SIZE_FROM_OFFSET = 0;
let OSM_EXACT_UNDERLYING = 1;
let OSM_MIN = 2;
let OSM_MAX = 3;

var os_mode: i64 = 0;
var os_round_to_align: bool = false;
var os_null_unknown: bool = false;
var os_use_aa: bool = false;
var os_bits: i64 = 64;          // IntTyBits
var os_visited: i64 = 0;
var os_seen_k: i32[>..<];       // SeenInsts
var os_seen_b: AP[>..<];
var os_seen_a: AP[>..<];
var os_seen_bk: bool[>..<];
var os_seen_ak: bool[>..<];

// An OffsetSpan: (Before, After), each known or not (APInt() = unknown, width 0)
struct OSpan { b: AP, a: AP, bk: bool, ak: bool }
fn os_unknown() -> OSpan { OSpan { b: ap_zero(1), a: ap_zero(1), bk: false, ak: false } }
fn os_span(b: AP, a: AP) -> OSpan { OSpan { b: b, a: a, bk: true, ak: true } }
fn os_both(s: OSpan) -> bool { s.bk && s.ak }

// checkedZextOrTrunc(I, IntTyBits)
fn os_checked_zot(x: AP, bits: i64) -> bool, AP {
    if (x.w as i64) > bits && ap_active_bits(x) > bits { return false, x; }
    return true, ap_zext_or_trunc(x, bits);
}

// aggregatePossibleConstantValuesImpl / aggregatePossibleConstantValues: (known, value)
recursive fn os_agg_impl(v: i32, mode: i64, bw: i64, depth: i64) -> bool, AP {
    if depth == 4 { return false, ap_zero(bw); }
    if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) { return true, ap_sext_or_trunc(ci_ap(v), bw); }
    if is_inst_op(v, OP_SELECT) {
        let ok1, a = os_agg_impl(op(v, 1), mode, bw, depth + 1);
        let ok2, b = os_agg_impl(op(v, 2), mode, bw, depth + 1);
        if !ok1 || !ok2 { return false, a; }
        return true, os_combine_const(a, b, mode);
    }
    if is_inst_op(v, OP_PHI) {
        let n = nops(v);
        if n == 0 { return false, ap_zero(bw); }
        var ok, acc = os_agg_impl(op(v, 0), mode, bw, depth + 1);
        var k: i64 = 1;
        while ok && k < n {
            let ok2, t = os_agg_impl(op(v, k), mode, bw, depth + 1);
            if !ok2 { ok = false; } else { acc = os_combine_const(acc, t, mode); }
            k++;
        }
        return ok, acc;
    }
    return false, ap_zero(bw);
}
fn os_combine_const(a: AP, b: AP, mode: i64) -> AP {
    if mode == OSM_MAX { return if ap_sge(a, b) { a } else { b }; }
    return if ap_sle(a, b) { a } else { b };
}
fn os_agg(v: i32, mode: i64, bw: i64) -> bool, AP {
    if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) { return true, ap_sext_or_trunc(ci_ap(v), bw); }
    if mode != OSM_MIN && mode != OSM_MAX { return false, ap_zero(bw); }
    let ok, x = os_agg_impl(v, mode, bw, 0);
    return ok, x;
}

// ObjectSizeOffsetVisitor::align(Size, Alignment): (known, size)
fn os_align(size: AP, al: i64) -> bool, AP {
    var s = size;
    if os_round_to_align && al > 0 { s = ap_u64(align_to(ap_zext64(s) as i64, al) as u64, os_bits); }
    if ap_is_neg(s) { return false, s; }
    return true, s;
}
fn os_zero_span(size_ok: bool, size: AP) -> OSpan {
    if !size_ok { return OSpan { b: ap_zero(os_bits), a: size, bk: true, ak: false }; }
    return os_span(ap_zero(os_bits), size);
}

// getAllocSize(CB, TLI, Mapper): (known, size)
fn mb_get_alloc_size(cb: i32, use_mapper: bool) -> bool, AP {
    let bits = dl_ptr(ptr_as(vals[cb].ty)).idx;
    var at: i64 = 0;
    var fst: i64 = -1;
    var snd: i64 = -1;
    let f = mb_called_function(cb);
    var k: i64 = -1;
    if f >= 0 { k = mb_alloc_data_for_function(f, MB_ANY); }
    if k >= 0 {
        at = TLI_ALLOC_DATA[k + 1] as i64;
        fst = TLI_ALLOC_DATA[k + 3] as i64;
        snd = TLI_ALLOC_DATA[k + 4] as i64;
    } else {
        var a = aset_find(alist_fn(insts[inst_of(cb)].attrs), AK_AllocSize);
        if a < 0 && called_function(cb) >= 0 { a = aset_find(alist_fn(globs[glob_of(called_function(cb))].attrs), AK_AllocSize); }
        if a < 0 { return false, ap_zero(bits); }
        // allocsize(ElemSizeArg, NumElemsArg): packed as (Elem << 32) | Num, Num = 0xFFFFFFFF when absent
        let packed = attrs[a].i1;
        at = MB_MALLOC;
        fst = (packed >> 32) as i64;
        let lo = (packed & 0xFFFFFFFF) as i64;
        snd = if lo == 0xFFFFFFFF { -1 } else { lo };
    }
    fn mapper(v: i32) -> i32 {
        if !use_mapper || !ty_is_int(vals[v].ty) { return v; }
        let ok, b = os_agg(v, os_mode, ty_scalar_bits(vals[v].ty));
        if ok { return c_int_ap(vals[v].ty, b); }
        return v;
    }
    if at == MB_STRDUP {
        mb_not_ported("getAllocSize of strdup-like functions (GetStringLength)");
        return false, ap_zero(bits);
    }
    let a1 = mapper(cb_arg(cb, fst));
    if vals[a1].kind != VK_CINT { return false, ap_zero(bits); }
    let ok, size = os_checked_zot(ci_ap(a1), bits);
    if !ok { return false, size; }
    if snd < 0 { return true, size; }
    let a2 = mapper(cb_arg(cb, snd));
    if vals[a2].kind != VK_CINT { return false, ap_zero(bits); }
    let ok2, ne = os_checked_zot(ci_ap(a2), bits);
    if !ok2 { return false, ne; }
    let p = ap_mul(size, ne);
    // umul_ov
    if !ap_is_zero(ne) && !ap_eq(ap_udiv(p, ne), size) { return false, p; }
    return true, p;
}

// ObjectSizeOffsetVisitor::computeImpl(V)
recursive fn os_compute_impl(v0: i32) -> OSpan {
    let init_bits = dl_ptr(ptr_as(vals[v0].ty)).idx;
    var v = strip_and_accumulate_offsets(v0, true, true, false);
    var off = ap_i64(vt_off, init_bits);
    if (os_mode == OSM_MIN || os_mode == OSM_MAX) && opcode_of(v) == OP_GEP {
        // stripAndAccumulateConstantOffsets with the ExternalAnalysis of aggregatePossibleConstantValues
        let m = if os_mode == OSM_MIN { OSM_MAX } else { OSM_MIN };
        var cur = v;
        loop {
            if opcode_of(cur) != OP_GEP { break; }
            let ok, o = os_gep_offset_with_analysis(cur, m);
            if !ok { break; }
            off = ap_add(off, o);
            cur = op(cur, 0);
            let nx = strip_and_accumulate_offsets(cur, true, true, false);
            off = ap_add(off, ap_i64(vt_off, init_bits));
            cur = nx;
        }
        v = cur;
    }
    os_bits = dl_ptr(ptr_as(vals[v].ty)).idx;
    var ort = os_compute_value(v);
    let changed = init_bits != os_bits;
    if !changed && ap_is_zero(off) { return ort; }
    if changed { mb_not_ported("ObjectSizeOffsetVisitor across address space casts with a different index width"); }
    if ort.bk {
        let s = ap_add(ort.b, off);
        // sadd_ov
        if ap_is_neg(ort.b) == ap_is_neg(off) && ap_is_neg(s) != ap_is_neg(ort.b) { ort.bk = false; } else { ort.b = s; }
    }
    if ort.ak {
        let s = ap_sub(ort.a, off);
        if ap_is_neg(ort.a) != ap_is_neg(off) && ap_is_neg(s) != ap_is_neg(ort.a) { ort.ak = false; } else { ort.a = s; }
    }
    if ort.bk && ap_is_neg(ort.b) {
        if os_mode == OSM_MIN || os_mode == OSM_MAX { return os_unknown(); }
    }
    return ort;
}
// GEPOperator::accumulateConstantOffset(DL, Offset, ExternalAnalysis)
fn os_gep_offset_with_analysis(g: i32, mode: i64) -> bool, AP {
    let w = dl_ptr(ptr_as(vals[g].ty)).idx;
    var t = gep_src_ty(g);
    var off = ap_zero(w);
    for k in 1..nops(g) {
        let ix = op(g, k);
        var st: i64 = 0;
        if k == 1 { st = dl_alloc_size(t); }
        else if ty_is_struct(t) {
            let c = m_apint(ix);
            if c < 0 { return false, off; }
            let fi = ap_zext64(ci_ap(c)) as i64;
            off = ap_add(off, ap_u64(dl_struct_offset(t, fi) as u64, w));
            t = ty_field(t, fi);
            continue;
        } else {
            st = dl_gep_stride(t, ty_elem(t));
            t = ty_elem(t);
        }
        if ty_kind(t) == TK_SVEC { return false, off; }
        var iv = ap_zero(w);
        let c = m_apint(ix);
        if c >= 0 { iv = ap_sext_or_trunc(ci_ap(c), w); }
        else {
            let ok, x = os_agg(ix, mode, w);
            if !ok { return false, off; }
            iv = x;
        }
        off = ap_add(off, ap_mul(iv, ap_u64(st as u64, w)));
    }
    return true, off;
}

recursive fn os_compute_value(v: i32) -> OSpan {
    if is_inst(v) {
        let k = position(os_seen_k, v);
        if k >= 0 { return OSpan { b: os_seen_b[k], a: os_seen_a[k], bk: os_seen_bk[k], ak: os_seen_ak[k] }; }
        os_seen_k.push(v);
        os_seen_b.push(ap_zero(1));
        os_seen_a.push(ap_zero(1));
        os_seen_bk.push(false);
        os_seen_ak.push(false);
        let slot = os_seen_k.len - 1;
        os_visited++;
        if os_visited > flag_int_mb("object-size-offset-visitor-max-visit-instructions", 100) { return os_unknown(); }
        let r = os_visit(v);
        os_seen_b[slot] = r.b;
        os_seen_a[slot] = r.a;
        os_seen_bk[slot] = r.bk;
        os_seen_ak[slot] = r.ak;
        return r;
    }
    if is_arg(v) {
        let mt = ml_arg_mem_type(v);
        if mt < 0 || !cf_ty_is_sized(mt) { return os_unknown(); }
        let ok, s = os_align(ap_u64(dl_alloc_size(mt) as u64, os_bits), ml_arg_int(v, AK_Alignment) as i64);
        return os_zero_span(ok, s);
    }
    if vals[v].kind == VK_CNULL {
        if os_null_unknown || ptr_as(vals[v].ty) != 0 { return os_unknown(); }
        return os_span(ap_zero(os_bits), ap_zero(os_bits));
    }
    if vals[v].kind == VK_ALIAS {
        let l = globs[glob_of(v)].linkage as i64;
        if l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return os_unknown(); }
        return os_compute_impl(op(v, 0));
    }
    if vals[v].kind == VK_GVAR {
        let g = globs[glob_of(v)];
        let l = g.linkage as i64;
        let interposable = l == LK_WEAK_ANY || l == LK_LINKONCE_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK;
        if !cf_ty_is_sized(g.vty) || l == LK_EXTERN_WEAK || ((nops(v) == 0 || interposable) && os_mode != OSM_MIN) { return os_unknown(); }
        let al = if g.align == 0 { 0 } else { 1 << (g.align - 1) as i64 };
        let ok, s = os_align(ap_u64(dl_alloc_size(g.vty) as u64, os_bits), al);
        return os_zero_span(ok, s);
    }
    if is_undef_or_poison(v) { return os_span(ap_zero(os_bits), ap_zero(os_bits)); }
    return os_unknown();
}
fn flag_int_mb(name: const u8[:], d: i64) -> i64 { d }

recursive fn os_visit(i: i32) -> OSpan {
    let o = iop(i);
    if o == OP_ALLOCA {
        let et = insts[inst_of(i)].ty2;
        if ty_contains_scalable(et) && os_mode != OSM_MIN { return os_unknown(); }
        let es = dl_alloc_size(et);
        if os_bits < 64 && (es as u64) >= ((1 as u64) << os_bits) { return os_unknown(); }
        let size = ap_u64(es as u64, os_bits);
        let al = icb_inst_align_mb(i);
        let n = op(i, 0);
        if vals[n].kind == VK_CINT && ap_is_one(ci_ap(n)) {
            let ok, s = os_align(size, al);
            return os_zero_span(ok, s);
        }
        let okc, ne0 = os_agg(n, os_mode, ty_scalar_bits(vals[n].ty));
        if okc {
            let ok2, ne = os_checked_zot(ne0, os_bits);
            if !ok2 { return os_unknown(); }
            let p = ap_mul(size, ne);
            if !ap_is_zero(ne) && !ap_eq(ap_udiv(p, ne), size) { return os_unknown(); }
            let ok, s = os_align(p, al);
            return os_zero_span(ok, s);
        }
        return os_unknown();
    }
    if is_callbase(i) {
        let ok, s = mb_get_alloc_size(i, true);
        if ok {
            if ap_is_neg(s) { return os_unknown(); }
            return os_span(ap_zero(os_bits), s);
        }
        return os_unknown();
    }
    if o == OP_LOAD {
        if !os_use_aa { return os_unknown(); }
        mb_not_ported("ObjectSizeOffsetVisitor::visitLoadInst (findLoadOffsetRange)");
        return os_unknown();
    }
    if o == OP_PHI {
        let n = nops(i);
        if n == 0 { return os_unknown(); }
        var acc = os_compute_impl(op(i, 0));
        for k in 1..n { acc = os_combine_range(acc, os_compute_impl(op(i, k))); }
        return acc;
    }
    if o == OP_SELECT { return os_combine_range(os_compute_impl(op(i, 1)), os_compute_impl(op(i, 2))); }
    return os_unknown();
}
fn icb_inst_align_mb(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }

fn os_combine_range(l: OSpan, r: OSpan) -> OSpan {
    if !os_both(l) || !os_both(r) { return os_unknown(); }
    if os_mode == OSM_MIN { return os_span(if ap_slt(l.b, r.b) { l.b } else { r.b }, if ap_slt(l.a, r.a) { l.a } else { r.a }); }
    if os_mode == OSM_MAX { return os_span(if ap_sgt(l.b, r.b) { l.b } else { r.b }, if ap_sgt(l.a, r.a) { l.a } else { r.a }); }
    if os_mode == OSM_EXACT_SIZE_FROM_OFFSET {
        return OSpan { b: l.b, a: l.a, bk: ap_eq(l.b, r.b), ak: ap_eq(l.a, r.a) };
    }
    if ap_eq(l.b, r.b) && ap_eq(l.a, r.a) { return l; }
    return os_unknown();
}

// ObjectSizeOffsetVisitor::compute(V): (known, Size, Offset)
fn os_compute(v: i32) -> bool, AP, AP {
    os_visited = 0;
    os_seen_k.clear();
    os_seen_b.clear();
    os_seen_a.clear();
    os_seen_bk.clear();
    os_seen_ak.clear();
    var sp = os_compute_impl(v);
    if sp.ak && !sp.bk && os_mode == OSM_EXACT_SIZE_FROM_OFFSET { sp.b = ap_zero(sp.a.w as i64); sp.bk = true; }
    if !os_both(sp) { return false, sp.a, sp.b; }
    return true, ap_add(sp.b, sp.a), sp.b;
}

// getObjectSize(Ptr, Size, DL, TLI, Opts): (ok, size)
fn mb_get_object_size(p: i32, mode: i64, round: bool, null_unknown: bool, use_aa: bool) -> bool, u64 {
    os_mode = mode;
    os_round_to_align = round;
    os_null_unknown = null_unknown;
    os_use_aa = use_aa;
    let ok, size, off = os_compute(p);
    if !ok { return false, 0; }
    // getSizeWithOverflow
    if ap_is_neg(off) || ap_ult(size, off) { return true, 0; }
    let r = ap_sub(size, off);
    return true, ap_zext64(r);
}

// lowerObjectSizeCall(ObjectSize, DL, TLI, AA, MustSucceed, InsertedInstructions): -1 = nullptr
fn mb_lower_object_size_call(ii: i32, must_succeed: bool) -> i32 { mb_lower_object_size_call_aa(ii, must_succeed, true) }
// the same with AA = nullptr when !use_aa (LowerConstantIntrinsics' overload without AA)
fn mb_lower_object_size_call_aa(ii: i32, must_succeed: bool, use_aa: bool) -> i32 {
    let max_val = ap_is_zero(ci_ap(cb_arg(ii, 1)));
    var mode = OSM_EXACT_SIZE_FROM_OFFSET;
    if must_succeed { mode = if max_val { OSM_MAX } else { OSM_MIN }; }
    let null_unknown = ap_is_one(ci_ap(cb_arg(ii, 2)));
    let rt = vals[ii].ty;
    let static_only = ap_is_zero(ci_ap(cb_arg(ii, 3)));
    if static_only {
        let ok, size = mb_get_object_size(cb_arg(ii, 0), mode, false, null_unknown, use_aa);
        let bw = ty_bits(rt);
        if ok && (bw >= 64 || size < ((1 as u64) << bw)) { return c_int_ty(rt, size); }
    } else {
        mb_not_ported("dynamic llvm.objectsize (ObjectSizeOffsetEvaluator)");
    }
    if !must_succeed { return -1; }
    return if max_val { c_all_ones(rt) } else { c_null(rt) };
}
