// MemoryLocation, LocationSize, ModRefInfo, MemoryEffects, CaptureInfo and the CallBase attribute queries the
// alias analyses need. Ports llvm/lib/Analysis/MemoryLocation.cpp (get, getOrNone, getForArgument,
// getForSource/Dest), llvm/include/llvm/Analysis/MemoryLocation.h (LocationSize),
// llvm/include/llvm/Support/ModRef.h (ModRefInfo, MemoryEffects, CaptureComponents, CaptureInfo),
// llvm/lib/IR/Instructions.cpp (CallBase::paramHasAttr, getCaptureInfo, onlyReadsMemory(OpNo), ...) and
// llvm/lib/IR/Instruction.cpp (Instruction::getAAMetadata, isAtomic, maySynchronize).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import tli;
import pm;
import vt;

// ---------------------------------------------------------------------------------------------
// LocationSize: the raw 64-bit encoding of LLVM (so equality and hashing are identical).

let LS_BEFORE_OR_AFTER: u64 = 0xFFFFFFFFFFFFFFFF;
let LS_SCALABLE_BIT: u64 = 0x4000000000000000;
let LS_AFTER: u64 = 0xBFFFFFFFFFFFFFFE;
let LS_MAP_EMPTY: u64 = 0xFFFFFFFFFFFFFFFD;
let LS_MAP_TOMBSTONE: u64 = 0xFFFFFFFFFFFFFFFC;
let LS_IMPRECISE_BIT: u64 = 0x8000000000000000;
let LS_MAX_VALUE: u64 = 0x3FFFFFFFFFFFFFFB;

fn ls_precise(v: u64) -> u64 { if v > LS_MAX_VALUE { LS_AFTER } else { v } }
fn ls_precise_ts(v: u64, scalable: bool) -> u64 {
    if v > LS_MAX_VALUE { return LS_AFTER; }
    return if scalable { v | LS_SCALABLE_BIT } else { v };
}
fn ls_upper_bound(v: u64) -> u64 {
    if v == 0 { return 0; }
    if v > LS_MAX_VALUE { return LS_AFTER; }
    return v | LS_IMPRECISE_BIT;
}
fn ls_upper_bound_ts(v: u64, scalable: bool) -> u64 { if scalable { LS_AFTER } else { ls_upper_bound(v) } }
fn ls_has_value(s: u64) -> bool { s != LS_AFTER && s != LS_BEFORE_OR_AFTER }
fn ls_is_scalable(s: u64) -> bool { (s & LS_SCALABLE_BIT) != 0 }
fn ls_value(s: u64) -> u64 { s & ~(LS_IMPRECISE_BIT | LS_SCALABLE_BIT) }
fn ls_is_precise(s: u64) -> bool { (s & LS_IMPRECISE_BIT) == 0 }
fn ls_is_zero(s: u64) -> bool { ls_has_value(s) && ls_value(s) == 0 }
fn ls_may_be_before(s: u64) -> bool { s == LS_BEFORE_OR_AFTER }
// LocationSize::unionWith
fn ls_union(a: u64, b: u64) -> u64 {
    if a == b { return a; }
    if a == LS_BEFORE_OR_AFTER || b == LS_BEFORE_OR_AFTER { return LS_BEFORE_OR_AFTER; }
    if a == LS_AFTER || b == LS_AFTER { return LS_AFTER; }
    if ls_is_scalable(a) || ls_is_scalable(b) { return LS_AFTER; }
    return ls_upper_bound(max(ls_value(a), ls_value(b)));
}
// LocationSize::print
fn ls_format(out: u8[>..]&, s: u64) {
    out.append("LocationSize::");
    if s == LS_BEFORE_OR_AFTER { out.append("beforeOrAfterPointer"); }
    else if s == LS_AFTER { out.append("afterPointer"); }
    else if s == LS_MAP_EMPTY { out.append("mapEmpty"); }
    else if s == LS_MAP_TOMBSTONE { out.append("mapTombstone"); }
    else if ls_is_precise(s) { out.append("precise("); ml_put_typesize(out, s); out.push(')'); }
    else { out.append("upperBound("); ml_put_typesize(out, s); out.push(')'); }
}
fn ml_put_typesize(out: u8[>..]&, s: u64) {
    if ls_is_scalable(s) { out.append("vscale x "); }
    format_u64_dec(out, ls_value(s));
}

// Does the type's size scale with vscale (TypeSize::isScalable)?
recursive fn ty_size_scalable(t: i32) -> bool {
    let k = ty_kind(t);
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY { return ty_size_scalable(ty_elem(t)); }
    if k == TK_STRUCT { for i in ty_count(t) { if ty_size_scalable(ty_field(t, i)) { return true; } } }
    return false;
}
// LocationSize::precise(DL.getTypeStoreSize(T)) (known minimum size for scalable types)
fn ls_store_size(t: i32) -> u64 { ls_precise_ts(dl_store_size(t) as u64, ty_size_scalable(t)) }

// ---------------------------------------------------------------------------------------------
// MemoryLocation. ptr == ML_NULL is MemoryLocation() (Ptr = null); ptr == ML_NONE is std::nullopt.

let ML_NULL: i32 = -1;
let ML_NONE: i32 = -2;

struct ML { ptr: i32, size: u64, tbaa: i32, tbaa_struct: i32, scope: i32, noalias: i32, noalias_as: i32 }

fn ml_make(p: i32, s: u64) -> ML { ML { ptr: p, size: s, tbaa: -1, tbaa_struct: -1, scope: -1, noalias: -1, noalias_as: -1 } }
fn ml_null() -> ML { ml_make(ML_NULL, LS_BEFORE_OR_AFTER) }
fn ml_none() -> ML { ml_make(ML_NONE, LS_BEFORE_OR_AFTER) }
fn ml_before_or_after(p: i32) -> ML { ml_make(p, LS_BEFORE_OR_AFTER) }
fn ml_after(p: i32) -> ML { ml_make(p, LS_AFTER) }
fn ml_with_tags(p: i32, s: u64, tags: ML) -> ML {
    ML { ptr: p, size: s, tbaa: tags.tbaa, tbaa_struct: tags.tbaa_struct, scope: tags.scope, noalias: tags.noalias, noalias_as: tags.noalias_as }
}

// Fixed metadata kind ids (FixedMetadataKinds.def)
let MDK_TBAA: i32 = 1;
let MDK_TBAA_STRUCT: i32 = 5;
let MDK_INVARIANT_LOAD: i32 = 6;
let MDK_ALIAS_SCOPE: i32 = 7;
let MDK_NOALIAS: i32 = 8;
let MDK_DEREFERENCEABLE: i32 = 12;
let MDK_DEREFERENCEABLE_OR_NULL: i32 = 13;
let MDK_INVARIANT_GROUP: i32 = 16;
let MDK_NOALIAS_ADDRSPACE: i32 = 41;
let MDK_CAPTURES: i32 = 44;

// Instruction::getAAMetadata (the tags only; ptr/size unset)
fn ml_aa_tags(iv: i32) -> ML {
    var r = ml_null();
    if !is_inst(iv) { return r; }
    r.tbaa = inst_get_md(iv, MDK_TBAA);
    r.tbaa_struct = inst_get_md(iv, MDK_TBAA_STRUCT);
    r.scope = inst_get_md(iv, MDK_ALIAS_SCOPE);
    r.noalias = inst_get_md(iv, MDK_NOALIAS);
    r.noalias_as = inst_get_md(iv, MDK_NOALIAS_ADDRSPACE);
    return r;
}

// MemoryLocation::get(Load/Store/VAArg/AtomicCmpXchg/AtomicRMW)
fn ml_get(iv: i32) -> ML {
    let o = iop(iv);
    let tags = ml_aa_tags(iv);
    if o == OP_LOAD { return ml_with_tags(op(iv, 0), ls_store_size(vals[iv].ty), tags); }
    if o == OP_STORE { return ml_with_tags(op(iv, 1), ls_store_size(vals[op(iv, 0)].ty), tags); }
    if o == OP_VAARG { return ml_with_tags(op(iv, 0), LS_AFTER, tags); }
    if o == OP_CMPXCHG { return ml_with_tags(op(iv, 0), ls_store_size(vals[op(iv, 1)].ty), tags); }
    if o == OP_ATOMICRMW { return ml_with_tags(op(iv, 0), ls_store_size(vals[op(iv, 1)].ty), tags); }
    fatal("internal: MemoryLocation::get on an instruction without a location");
    return ml_null();
}

// MemoryLocation::getOrNone
fn ml_get_or_none(iv: i32) -> ML {
    let o = iop(iv);
    if o == OP_LOAD || o == OP_STORE || o == OP_VAARG || o == OP_CMPXCHG || o == OP_ATOMICRMW { return ml_get(iv); }
    return ml_none();
}

fn ml_const_zext(v: i32) -> u64, bool {
    if v < 0 || vals[v].kind != VK_CINT || ty_is_vector(vals[v].ty) { return 0, false; }
    let w = ty_bits(vals[v].ty);
    if w > 64 && cint_hi(v) != 0 { fatal("MemoryLocation: a length wider than 64 bits is not supported"); }
    return cint_lo(v), true;
}

// TargetLibraryInfo::getLibFunc(const CallBase&, LibFunc&): -1 if not a known library function.
fn ml_call_libfunc(c: i32) -> i32 {
    if call_is_nobuiltin(c) { return -1; }
    let f = called_function(c);
    if f < 0 { return -1; }
    return tli_get_libfunc(f);
}

// MemoryLocation::getForArgument(Call, ArgIdx, TLI); use_tli = false is the TLI == nullptr overload.
fn ml_for_argument(c: i32, k: i64, use_tli: bool) -> ML {
    let tags = ml_aa_tags(c);
    let arg = cb_arg(c, k);
    let id = inst_iid(c);
    if id != 0 {
        if id == IID_memset || id == IID_memcpy || id == IID_memcpy_inline || id == IID_memmove ||
           id == IID_memcpy_element_unordered_atomic || id == IID_memmove_element_unordered_atomic ||
           id == IID_memset_element_unordered_atomic {
            let n, ok = ml_const_zext(cb_arg(c, 2));
            if ok { return ml_with_tags(arg, ls_precise(n), tags); }
            return ml_with_tags(arg, LS_AFTER, tags);
        }
        if id == IID_experimental_memset_pattern {
            let n, ok = ml_const_zext(cb_arg(c, 2));
            if ok { return ml_with_tags(arg, ls_precise(n * (dl_alloc_size(vals[cb_arg(c, 1)].ty) as u64)), tags); }
            return ml_with_tags(arg, LS_AFTER, tags);
        }
        if id == IID_lifetime_start || id == IID_lifetime_end {
            if !is_inst_op(arg, OP_ALLOCA) { return ml_before_or_after(arg); }
            let sz, ok, sc = ml_alloca_size(arg);
            return ml_with_tags(arg, if ok { ls_precise_ts(sz, sc) } else { LS_AFTER }, tags);
        }
        if id == IID_invariant_start {
            let n, ok = ml_const_zext(cb_arg(c, 0));
            return ml_with_tags(arg, ls_precise(n), tags);
        }
        if id == IID_masked_load || id == IID_masked_store {
            let is_load = id == IID_masked_load;
            let vt = if is_load { vals[c].ty } else { vals[cb_arg(c, 0)].ty };
            let n, ok = ml_known_lanes_from_mask(op(c, if is_load { 1 } else { 2 }), vt);
            if ok {
                let es = dl_size_bits(ty_elem(vt)) as u64;
                return ml_with_tags(arg, ls_precise((n * es + 7) / 8), tags);
            }
            return ml_with_tags(arg, ls_upper_bound_ts(dl_store_size(vt) as u64, ty_kind(vt) == TK_SVEC), tags);
        }
        if id == IID_invariant_end {
            if k == 0 { return ml_with_tags(arg, ls_precise(0), tags); }
            let n, ok = ml_const_zext(cb_arg(c, 1));
            return ml_with_tags(arg, ls_precise(n), tags);
        }
        if id == IID_matrix_column_major_load || id == IID_matrix_column_major_store {
            let is_load = id == IID_matrix_column_major_load;
            let stride, sok = ml_const_zext(cb_arg(c, if is_load { 1 } else { 2 }));
            let rows, rok = ml_const_zext(cb_arg(c, if is_load { 3 } else { 4 }));
            let cols, cok = ml_const_zext(cb_arg(c, if is_load { 4 } else { 5 }));
            if !sok { return ml_with_tags(arg, LS_AFTER, tags); }
            let vt = if is_load { vals[c].ty } else { vals[cb_arg(c, 0)].ty };
            let size = (dl_alloc_size(ty_scalar(vt)) as u64) * (stride * (cols - 1) + rows);
            if stride == rows { return ml_with_tags(arg, ls_precise(size), tags); }
            return ml_with_tags(arg, ls_upper_bound(size), tags);
        }
    }
    if use_tli {
        let lf = ml_call_libfunc(c);
        if lf >= 0 && tli_has(lf) {
            let nm = TLI_NAMES[lf];
            if nm == "strcpy" || nm == "strcat" || nm == "strncat" { return ml_with_tags(arg, LS_AFTER, tags); }
            if nm == "__memset_chk" || nm == "__memcpy_chk" {
                var s = LS_AFTER;
                let n, ok = ml_const_zext(cb_arg(c, 2));
                if ok { s = ls_upper_bound(n); }
                return ml_with_tags(arg, s, tags);
            }
            if nm == "strncpy" {
                var s = LS_AFTER;
                let n, ok = ml_const_zext(cb_arg(c, 2));
                if ok { s = if k == 0 { ls_precise(n) } else { ls_upper_bound(n) }; }
                return ml_with_tags(arg, s, tags);
            }
            if nm == "memset_pattern16" || nm == "memset_pattern4" || nm == "memset_pattern8" {
                if k == 1 {
                    var sz: u64 = 16;
                    if nm == "memset_pattern4" { sz = 4; } else if nm == "memset_pattern8" { sz = 8; }
                    return ml_with_tags(arg, ls_precise(sz), tags);
                }
                let n, ok = ml_const_zext(cb_arg(c, 2));
                if ok { return ml_with_tags(arg, ls_precise(n), tags); }
                return ml_with_tags(arg, LS_AFTER, tags);
            }
            if nm == "bcmp" || nm == "memcmp" || nm == "memchr" {
                let n, ok = ml_const_zext(cb_arg(c, 2));
                if ok { return ml_with_tags(arg, ls_precise(n), tags); }
                return ml_with_tags(arg, LS_AFTER, tags);
            }
            if nm == "memccpy" {
                let n, ok = ml_const_zext(cb_arg(c, 3));
                if ok { return ml_with_tags(arg, ls_upper_bound(n), tags); }
                return ml_with_tags(arg, LS_AFTER, tags);
            }
        }
    }
    return ml_with_tags(arg, LS_BEFORE_OR_AFTER, tags);
}

// getKnownTypeFromMaskedOp: the number of lanes of a get.active.lane.mask(C0, C1) mask
fn ml_known_lanes_from_mask(m: i32, vt: i32) -> u64, bool {
    if inst_iid(m) != IID_get_active_lane_mask { return 0, false; }
    let lo, ok1 = ml_const_zext(cb_arg(m, 0));
    let hi, ok2 = ml_const_zext(cb_arg(m, 1));
    if !ok1 || !ok2 { return 0, false; }
    if hi <= lo { return 0, false; }
    var n = hi - lo;
    let mn = ty_count(vt) as u64;
    if n > mn {
        if ty_kind(vt) == TK_SVEC { return 0, false; }
        n = mn;
    }
    return n, true;
}

// MemoryLocation::getForSource / getForDest (memory intrinsics)
fn ml_for_source(c: i32) -> ML { ml_for_argument(c, 1, false) }
fn ml_for_dest(c: i32) -> ML { ml_for_argument(c, 0, false) }

// AllocaInst::getAllocationSize: (size, known, scalable)
fn ml_alloca_size(a: i32) -> u64, bool, bool {
    let t = insts[inst_of(a)].ty2;
    let sz = dl_alloc_size(t) as u64;
    let sc = ty_size_scalable(t);
    if sz == 0 { return 0, true, sc; }
    let n = op(a, 0);
    // isArrayAllocation: the array size is not the constant 1
    if vals[n].kind == VK_CINT && cint_lo(n) == 1 && (ty_bits(vals[n].ty) <= 64 || cint_hi(n) == 0) { return sz, true, sc; }
    if vals[n].kind != VK_CINT { return 0, false, sc; }
    if ty_bits(vals[n].ty) > 64 && cint_hi(n) != 0 { return 0, false, sc; }
    let cnt = cint_lo(n);
    if cnt != 0 && sz > 0xFFFFFFFFFFFFFFFF / cnt { return 0, false, sc; }
    return sz * cnt, true, sc;
}

// AllocaInst::isStaticAlloca: constant array size and in the entry block, not inalloca
fn ml_is_static_alloca(a: i32) -> bool {
    if vals[op(a, 0)].kind != VK_CINT { return false; }
    let b = inst_parent(a);
    if func_entry(block_func(b)) != b { return false; }
    return (insts[inst_of(a)].bits & 1) == 0;
}

// ---------------------------------------------------------------------------------------------
// ModRefInfo (0 NoModRef, 1 Ref, 2 Mod, 3 ModRef) and MemoryEffects (2 bits per IRMemLocation)

let MR_NO = 0;
let MR_REF = 1;
let MR_MOD = 2;
let MR_MODREF = 3;
fn mr_is_mod(m: i64) -> bool { (m & MR_MOD) != 0 }
fn mr_is_ref(m: i64) -> bool { (m & MR_REF) != 0 }
fn mr_any(m: i64) -> bool { m != 0 }

let LOC_ARG = 0;
let LOC_INACCESSIBLE = 1;
let LOC_ERRNO = 2;
let LOC_OTHER = 3;
let LOC_TARGET0 = 4;
let LOC_TARGET1 = 5;

let ME_NONE: u64 = 0;
fn me_of(mr: i64) -> u64 { me_all(mr) }
fn me_loc_only(loc: i64, mr: i64) -> u64 { me_set(0, loc, mr) }
fn me_without(m: u64, loc: i64) -> u64 { me_set(m, loc, MR_NO) }
fn me_modref(m: u64) -> i64 { var r: i64 = 0; for l in 6 { r |= me_get(m, l); } return r; }
fn me_only_arg(m: u64) -> bool { me_without(m, LOC_ARG) == 0 }
fn me_does_access_arg(m: u64) -> bool { me_get(m, LOC_ARG) != 0 }
fn me_only_inaccessible_or_target(m: u64) -> bool {
    var x = m;
    x = x & me_without(x, LOC_TARGET0);
    x = x & me_without(x, LOC_TARGET1);
    return me_without(x, LOC_INACCESSIBLE) == 0;
}

// Function::getMemoryEffects
fn ml_func_memory_effects(fv: i32) -> u64 { aset_memory(alist_fn(func_attrs(fv))) }

// ---------------------------------------------------------------------------------------------
// CaptureComponents / CaptureInfo

let CC_NONE: i64 = 0;
let CC_ADDRESS_IS_NULL: i64 = 1;
let CC_ADDRESS: i64 = 3;
let CC_READ_PROVENANCE: i64 = 4;
let CC_PROVENANCE: i64 = 12;
let CC_ALL: i64 = 15;
fn cc_nothing(c: i64) -> bool { c == 0 }
fn cc_anything(c: i64) -> bool { c != 0 }
fn cc_read_provenance_only(c: i64) -> bool { (c & CC_PROVENANCE) == CC_READ_PROVENANCE }
fn cc_full_provenance(c: i64) -> bool { (c & CC_PROVENANCE) == CC_PROVENANCE }
fn cc_any_provenance(c: i64) -> bool { (c & CC_PROVENANCE) != 0 }

// CaptureInfo as (other << 4) | ret, like toIntValue
fn ci_other(ci: i64) -> i64 { (ci >> 4) & 15 }
fn ci_ret(ci: i64) -> i64 { ci & 15 }
fn ci_make(other: i64, ret: i64) -> i64 { (other << 4) | ret }
let CI_ALL: i64 = 0xFF;
// AttributeSet::getCaptureInfo
fn aset_capture_info(s: i32) -> i64 {
    let a = aset_find(s, AK_Captures);
    if a < 0 { return CI_ALL; }
    // the parser stores captures(...) as other | (ret << 8)
    let x = attrs[a].i1;
    return ci_make((x & 0xFF) as i64, ((x >> 8) & 0xFF) as i64);
}

// ---------------------------------------------------------------------------------------------
// CallBase attribute queries

// CallBase::hasOperandBundles
fn cb_has_bundles(c: i32) -> bool { cb_nbundles(c) > 0 }

// CallBase::paramHasAttr
fn cb_param_has_attr(c: i32, k: i64, kind: i64) -> bool {
    if aset_has(alist_param(insts[inst_of(c)].attrs, k), kind) { return true; }
    let f = called_function(c);
    if f < 0 { return false; }
    if !aset_has(alist_param(func_attrs(f), k), kind) { return false; }
    if kind == AK_ReadNone { return !call_has_reading_bundles(c) && !call_has_clobbering_bundles(c); }
    if kind == AK_ReadOnly { return !call_has_clobbering_bundles(c); }
    if kind == AK_WriteOnly { return !call_has_reading_bundles(c); }
    return true;
}

// the bundle index containing data operand `i` (i >= nargs)
fn cb_bundle_of_operand(c: i32, i: i64) -> i64 {
    for b in cb_nbundles(c) {
        let st = cb_bundle_begin(c, b);
        if i >= st && i < st + cb_bundle_count(c, b) { return b; }
    }
    fatal("internal: operand is not a bundle operand");
    return -1;
}

// CallBase::dataOperandHasImpliedAttr (bundle operands: OperandBundleUse::operandHasAttr)
fn cb_data_op_has_implied_attr(c: i32, i: i64, kind: i64) -> bool {
    if i < cb_nargs(c) { return cb_param_has_attr(c, i, kind); }
    let b = cb_bundle_of_operand(c, i);
    if sbytes(cb_bundle_tag(c, b)) == "deopt" {
        if kind == AK_ReadOnly || kind == AK_Captures { return ty_kind(vals[op(c, i)].ty) == TK_PTR; }
    }
    return false;
}

fn cb_is_byval_arg(c: i32, k: i64) -> bool { cb_param_has_attr(c, k, AK_ByVal) }

// CallBase::doesNotAccessMemory(OpNo) / onlyReadsMemory(OpNo) / onlyWritesMemory(OpNo)
fn cb_arg_no_memory(c: i32, i: i64) -> bool { cb_data_op_has_implied_attr(c, i, AK_ReadNone) }
fn cb_arg_only_reads(c: i32, i: i64) -> bool {
    if i < cb_nargs(c) && cb_is_byval_arg(c, i) { return true; }
    return cb_data_op_has_implied_attr(c, i, AK_ReadOnly) || cb_data_op_has_implied_attr(c, i, AK_ReadNone);
}
fn cb_arg_only_writes(c: i32, i: i64) -> bool {
    return cb_data_op_has_implied_attr(c, i, AK_WriteOnly) || cb_data_op_has_implied_attr(c, i, AK_ReadNone);
}

// CallBase::getCaptureInfo(OpNo)
fn cb_capture_info(c: i32, i: i64) -> i64 {
    if i < cb_nargs(c) {
        if cb_is_byval_arg(c, i) { return 0; }
        var ci = aset_capture_info(alist_param(insts[inst_of(c)].attrs, i));
        let f = cb_callee(c);
        if is_func(f) { ci &= aset_capture_info(alist_param(func_attrs(f), i)); }
        return ci;
    }
    if call_iid(c) == IID_assume { return 0; }
    let b = cb_bundle_of_operand(c, i);
    return if sbytes(cb_bundle_tag(c, b)) == "deopt" { 0 } else { CI_ALL };
}

// CallBase::hasArgumentWithAdditionalReturnCaptureComponents
fn cb_has_arg_with_extra_ret_captures(c: i32) -> bool {
    for i in cb_nargs(c) {
        if ty_kind(vals[cb_arg(c, i)].ty) != TK_PTR { continue; }
        var ci = aset_capture_info(alist_param(insts[inst_of(c)].attrs, i));
        let f = cb_callee(c);
        if is_func(f) { ci &= aset_capture_info(alist_param(func_attrs(f), i)); }
        if cc_anything(ci_ret(ci) & ~ci_other(ci) & 15) { return true; }
    }
    return false;
}

// CallBase::hasRetAttr
fn cb_has_ret_attr(c: i32, kind: i64) -> bool {
    if aset_has(alist_ret(insts[inst_of(c)].attrs), kind) { return true; }
    let f = called_function(c);
    return f >= 0 && aset_has(alist_ret(func_attrs(f)), kind);
}
fn cb_ret_attr_int(c: i32, kind: i64) -> u64 {
    let a = aset_find(alist_ret(insts[inst_of(c)].attrs), kind);
    if a >= 0 { return attrs[a].i1; }
    let f = called_function(c);
    if f >= 0 {
        let b = aset_find(alist_ret(func_attrs(f)), kind);
        if b >= 0 { return attrs[b].i1; }
    }
    return 0;
}

// CallInst::isTailCall (tail or musttail)
fn cb_is_tail_call(c: i32) -> bool { iop(c) == OP_CALL && (insts[inst_of(c)].pred == 1 || insts[inst_of(c)].pred == 2) }

// AttributeList::hasAttrSomewhere(Kind) on the call site's attributes
fn cb_has_attr_somewhere(c: i32, kind: i64) -> bool {
    let l = insts[inst_of(c)].attrs;
    for k in alists[l].n { if aset_has(alist_runs[alists[l].at + k], kind) { return true; } }
    return false;
}

// CallBase::isInlineAsm
fn cb_is_inline_asm(c: i32) -> bool { let f = cb_callee(c); return f >= 0 && vals[f].kind == VK_INLINEASM; }

// Atomic ordering helpers (Inst.ord: 0 notatomic, 1 unordered, 2 monotonic, 4 acquire, 5 release, 6 acq_rel, 7 seq_cst)
fn ord_stronger_than_unordered(o: u8) -> bool { o > 1 }
fn ord_stronger_than_monotonic(o: u8) -> bool { o > 2 }

// Instruction::isAtomic
fn inst_is_atomic(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_CMPXCHG || o == OP_ATOMICRMW || o == OP_FENCE { return true; }
    if o == OP_LOAD || o == OP_STORE { return insts[inst_of(iv)].ord != 0; }
    return false;
}

// Instruction::maySynchronize
fn inst_may_synchronize(iv: i32) -> bool {
    let o = iop(iv);
    let x = insts[inst_of(iv)];
    if o == OP_FENCE { return !(x.ss >= 0 && sbytes(x.ss) == "singlethread"); }
    if o == OP_ATOMICRMW || o == OP_CMPXCHG { return true; }
    if o == OP_STORE || o == OP_LOAD { return ord_stronger_than_unordered(x.ord); }
    if o == OP_CALL || o == OP_INVOKE || o == OP_CALLBR { return !call_has_fn_attr(iv, AK_NoSync); }
    return false;
}

// Instruction::isFenceLike
fn inst_is_fence_like(iv: i32) -> bool {
    let o = iop(iv);
    return o == OP_FENCE || o == OP_CATCHPAD || o == OP_CATCHRET || o == OP_CALL || o == OP_INVOKE;
}

// ---------------------------------------------------------------------------------------------
// Arguments

fn ml_arg_attrs(a: i32) -> i32 {
    let f = args_parent[vals[a].sub];
    return alist_param(func_attrs(f), args_no[vals[a].sub] as i64);
}
fn ml_arg_has(a: i32, kind: i64) -> bool { aset_has(ml_arg_attrs(a), kind) }
fn ml_arg_int(a: i32, kind: i64) -> u64 { let at = aset_find(ml_arg_attrs(a), kind); return if at < 0 { 0 } else { attrs[at].i1 }; }
// Argument::getPointeeInMemoryValueType (-1 if none)
fn ml_arg_mem_type(a: i32) -> i32 {
    let s = ml_arg_attrs(a);
    for kind in [AK_ByVal, AK_ByRef, AK_Preallocated, AK_InAlloca, AK_StructRet] {
        let at = aset_find(s, kind);
        if at >= 0 && attrs[at].ty >= 0 { return attrs[at].ty; }
    }
    return -1;
}
// Argument::onlyReadsMemory
fn ml_arg_only_reads(a: i32) -> bool { ml_arg_has(a, AK_ReadOnly) || ml_arg_has(a, AK_ReadNone) }

// ---------------------------------------------------------------------------------------------
// Identified objects (AliasAnalysis.cpp) and stripPointerCastsForAliasAnalysis (Value.cpp)

// Argument::hasNoAliasAttr / hasByValAttr
fn aa_arg_noalias(a: i32) -> bool { ty_kind(vals[a].ty) == TK_PTR && ml_arg_has(a, AK_NoAlias) }
fn aa_arg_byval(a: i32) -> bool { ty_kind(vals[a].ty) == TK_PTR && ml_arg_has(a, AK_ByVal) }

fn aa_is_noalias_call(v: i32) -> bool { is_callbase(v) && cb_has_ret_attr(v, AK_NoAlias) }
fn aa_is_noalias_or_byval_arg(v: i32) -> bool { is_arg(v) && (aa_arg_noalias(v) || aa_arg_byval(v)) }

fn aa_is_identified_object(v: i32) -> bool {
    if is_inst_op(v, OP_ALLOCA) { return true; }
    let k = vals[v].kind;
    if k == VK_FUNC || k == VK_GVAR || k == VK_IFUNC { return true; }
    if aa_is_noalias_call(v) { return true; }
    if aa_is_noalias_or_byval_arg(v) { return true; }
    return false;
}
fn aa_is_identified_function_local(v: i32) -> bool {
    return is_inst_op(v, OP_ALLOCA) || aa_is_noalias_call(v) || aa_is_noalias_or_byval_arg(v);
}
// Value::stripPointerCastsForAliasAnalysis
fn bas_strip(v0: i32) -> i32 {
    if ty_kind(vals[v0].ty) != TK_PTR { return v0; }
    var v = v0;
    var seen: i32[>..<] = [];
    var iters = 0;
    loop {
        iters++;
        if iters > 100000 { return v; }
        let o = opcode_of(v);
        var nv: i32 = -1;
        if o == OP_GEP {
            if !bas_gep_all_zero(v) { return v; }
            nv = op(v, 0);
        } else if o == OP_BITCAST {
            let x = op(v, 0);
            if ty_kind(vals[x].ty) != TK_PTR { return v; }
            nv = x;
        } else if o == OP_ADDRSPACECAST {
            nv = op(v, 0);
        } else if is_inst_op(v, OP_PHI) && nops(v) == 1 {
            nv = op(v, 0);
        } else if is_callbase(v) {
            let rv = returned_arg_operand(v);
            if rv >= 0 { nv = rv; }
            else {
                let id = call_iid(v);
                if id == IID_launder_invariant_group || id == IID_strip_invariant_group { nv = cb_arg(v, 0); }
                else { return v; }
            }
        } else {
            return v;
        }
        v = nv;
        // Visited set (cycles only in unreachable code)
        if v == v0 { return v; }
        var dup = false;
        for s in seen { if s == v { dup = true; } }
        if dup { return v; }
        seen.push(v);
    }
    return v;
}

fn bas_gep_all_zero(g: i32) -> bool {
    for k in 1..nops(g) {
        let x = op(g, k);
        if !(is_constant(x) && is_null_value(x)) { return false; }
    }
    return true;
}

