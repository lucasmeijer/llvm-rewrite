// Memory-intrinsic helpers shared by DSE and MemCpyOpt: the IntrinsicInst.h classes (AnyMemIntrinsic,
// MemIntrinsic, AnyMemSetInst, MemSetInst, MemTransferInst, ...) and their accessors, isBytewiseValue
// (llvm/lib/Analysis/ValueTracking.cpp), MemoryLocation::getForDest(const CallBase *, TLI)
// (llvm/lib/Analysis/MemoryLocation.cpp) and BatchAAResults::isMustAlias (llvm/include/llvm/Analysis/AliasAnalysis.h).
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
import cfold;
import memloc;
import aa;
import local;

// AnyMemIntrinsic
fn mi_is_any_mem_intrinsic(i: i32) -> bool {
    let id = inst_iid(i);
    if id == 0 { return false; }
    return id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove || id == IID_memset || id == IID_memset_inline ||
        id == IID_memcpy_element_unordered_atomic || id == IID_memmove_element_unordered_atomic ||
        id == IID_memset_element_unordered_atomic;
}
// MemIntrinsic (memcpy, memcpy.inline, memmove, memset, memset.inline)
fn mi_is_mem_intrinsic(i: i32) -> bool { let id = inst_iid(i); return id != 0 && is_mem_intrinsic_id(id); }
// AnyMemSetInst
fn mi_is_any_memset(i: i32) -> bool {
    let id = inst_iid(i);
    return id != 0 && (id == IID_memset || id == IID_memset_inline || id == IID_memset_element_unordered_atomic);
}
// MemSetInst
fn mi_is_memset(i: i32) -> bool { let id = inst_iid(i); return id != 0 && (id == IID_memset || id == IID_memset_inline); }
// MemTransferInst (memcpy, memcpy.inline, memmove)
fn mi_is_mem_transfer(i: i32) -> bool {
    let id = inst_iid(i);
    return id != 0 && (id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove);
}
// MemCpyInst (memcpy, memcpy.inline)
fn mi_is_memcpy(i: i32) -> bool { let id = inst_iid(i); return id != 0 && (id == IID_memcpy || id == IID_memcpy_inline); }
fn mi_is_memmove(i: i32) -> bool { inst_iid(i) == IID_memmove }
// AnyMemIntrinsic::isAtomic
fn mi_is_atomic(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_memcpy_element_unordered_atomic || id == IID_memmove_element_unordered_atomic ||
        id == IID_memset_element_unordered_atomic;
}

fn mi_raw_dest(i: i32) -> i32 { cb_arg(i, 0) }
fn mi_raw_source(i: i32) -> i32 { cb_arg(i, 1) }
// getDest / getSource: stripPointerCasts
fn mi_dest(i: i32) -> i32 { strip_ptr_casts(cb_arg(i, 0)) }
fn mi_source(i: i32) -> i32 { strip_ptr_casts(cb_arg(i, 1)) }
fn mi_length(i: i32) -> i32 { cb_arg(i, 2) }
// MemSetInst::getValue
fn mi_value(i: i32) -> i32 { cb_arg(i, 1) }
// MemIntrinsic::isVolatile (the i1 operand)
fn mi_is_volatile(i: i32) -> bool { inst_is_volatile(i) }
// AnyMemIntrinsic::getElementSizeInBytes
fn mi_element_size(i: i32) -> u64 { cint_lo(cb_arg(i, 3)) }

// the "align" attribute of call parameter k (0 = none), call site only (getParamAlign)
fn mi_param_align(i: i32, k: i64) -> u64 {
    let a = aset_find(alist_param(insts[inst_of(i)].attrs, k), AK_Alignment);
    if a < 0 { return 0; }
    return attrs[a].i1;
}
fn mi_dest_align(i: i32) -> u64 { mi_param_align(i, 0) }
fn mi_source_align(i: i32) -> u64 { mi_param_align(i, 1) }

// replace parameter k's attribute set
fn mi_set_param_set(i: i32, k: i64, s: i32) {
    let ii = inst_of(i);
    let l = insts[ii].attrs;
    var xs: i32[>..<] = [];
    xs.push(alist_fn(l));
    xs.push(alist_ret(l));
    let n0 = if l == 0 { 0 } else { (alists[l].n as i64) - 2 };
    let n = max(n0, k + 1);
    for j in n { xs.push(if j == k { s } else { alist_param(l, j) }); }
    insts[ii].attrs = alist_get(xs);
}
// setDestAlignment / setSourceAlignment: removeParamAttr(Alignment), then addParamAttr(align) when known
fn mi_set_param_align(i: i32, k: i64, al: u64) {
    let s0 = alist_param(insts[inst_of(i)].attrs, k);
    var xs: i32[>..<] = [];
    for j in aset_n(s0) { let a = aset_attr(s0, j); if attrs[a].kind as i64 != AK_Alignment { xs.push(a); } }
    if al != 0 { xs.push(attr_int(AK_Alignment, al)); }
    mi_set_param_set(i, k, aset_get(xs));
}
// setLength(ConstantInt of the length's type)
fn mi_set_length(i: i32, n: u64) {
    let lt = vals[mi_length(i)].ty;
    set_op(i, 2, c_int(lt, n as! i64));
}

// isBytewiseValue(V, DL): -1 = nullptr
recursive fn is_bytewise_value(v: i32) -> i32 {
    let t = vals[v].ty;
    let i8t = ty_int(8);
    if ty_kind(t) == TK_INT && ty_bits(t) == 8 { return v; }
    let undef8 = c_undef(i8t);
    let k = vals[v].kind;
    if k == VK_UNDEF || k == VK_POISON { return undef8; }
    if !ty_size_scalable(t) && dl_store_size(t) == 0 { return c_poison(i8t); }
    if !is_constant(v) { return -1; }
    if is_null_value(v) { return c_null(i8t); }
    if k == VK_CFP {
        let st = ty_kind(ty_scalar(t));
        if st == TK_HALF || st == TK_FLOAT || st == TK_DOUBLE {
            let w = ty_bits(ty_scalar(t));
            let bits = if st == TK_HALF { 16 } else if st == TK_FLOAT { 32 } else { 64 };
            if w != 0 && w != bits { fatal("isBytewiseValue: unexpected FP width"); }
            let lo, hi = cfp_bits(v);
            return is_bytewise_value(c_int(ty_int(bits), lo as! i64));
        }
        return -1;
    }
    if k == VK_CINT {
        let a = ci_ap(v);
        let w = a.w as i64;
        if w % 8 == 0 {
            let b = ap_trunc(a, 8);
            if !ap_eq(ap_splat(w, b), a) { return -1; }
            return ap_to_cint(i8t, b);
        }
    }
    if k == VK_CEXPR && csts[vals[v].sub].op as i64 == OP_INTTOPTR && ty_kind(t) == TK_PTR {
        let bw = dl_ptr(ptr_as(t)).bits;
        let o = cf_fold_integer_cast(op(v, 0), ty_int(bw), false);
        if o >= 0 { return is_bytewise_value(o); }
    }
    if k == VK_CDARRAY || k == VK_CDVECTOR || k == VK_CARRAY || k == VK_CSTRUCT || k == VK_CVECTOR {
        var val = undef8;
        for j in nops(v) {
            let r = is_bytewise_value(op(v, j));
            // Merge(Val, r)
            if val == r { continue; }
            if val < 0 || r < 0 { return -1; }
            if val == undef8 { val = r; continue; }
            if r == undef8 { continue; }
            return -1;
        }
        return val;
    }
    return -1;
}

// MemoryLocation::getForDest(const CallBase *CB, const TargetLibraryInfo &TLI): ML_NONE = std::nullopt
fn ml_for_dest_call(c: i32) -> ML {
    let wme = call_memory_effects(c) & 0xAAAAAAAA;
    if !me_only_arg(wme) { return ml_none(); }
    if cb_nbundles(c) > 0 { return ml_none(); }
    var used: i32 = -1;
    var used_idx: i64 = -1;
    for k in cb_nargs(c) {
        let a = cb_arg(c, k);
        if ty_kind(vals[a].ty) != TK_PTR { continue; }
        if cb_arg_only_reads(c, k) { continue; }
        if used < 0 { used = a; used_idx = k; continue; }
        used_idx = -1;
        if used != a { return ml_none(); }
    }
    if used < 0 { return ml_none(); }
    if used_idx >= 0 { return ml_for_argument(c, used_idx, true); }
    return ml_with_tags(used, LS_BEFORE_OR_AFTER, ml_aa_tags(c));
}

// BatchAAResults::isMustAlias(const Value *V1, const Value *V2): precise(1) locations without AA metadata
fn aa_is_must_alias_vals(a: i32, b: i32, q: i32) -> bool {
    return ar_k(aa_alias(ml_make(a, ls_precise(1)), ml_make(b, ls_precise(1)), q, -1)) == AR_MUST;
}
fn aa_is_must_alias(a: ML, b: ML, q: i32) -> bool { ar_k(aa_alias(a, b, q, -1)) == AR_MUST }
