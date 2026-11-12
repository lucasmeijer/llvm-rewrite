// Port of the parts of llvm/lib/Analysis/Loads.cpp InstCombine needs: isSafeToLoadUnconditionally (both
// overloads), AreEquivalentAddressValues, getAvailableLoadStore, FindAvailableLoadedValue (the BatchAA
// overload), findAvailablePtrLoadStore; plus CastInst::isBitCastable / isBitOrNoopPointerCastable
// (llvm/lib/IR/Instructions.cpp). isDereferenceableAndAlignedPointer itself is speculate.goose's
// spec_deref_aligned (same file of LLVM).
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import datalayout;
import apint;
import pm;
import vt;
import local;
import memloc;
import aa;
import cfold;
import speculate;
import instident;
import constrange;
import instsimplify;
import flags;

// CastInst::isBitCastable(SrcTy, DestTy)
fn ld_is_bit_castable(s0: i32, d0: i32) -> bool {
    var s = s0;
    var d = d0;
    if !ty_is_first_class(s) || !ty_is_first_class(d) { return false; }
    if s == d { return true; }
    if ty_is_vector(s) && ty_is_vector(d) && ty_count(s) == ty_count(d) && ty_kind(s) == ty_kind(d) {
        s = ty_elem(s);
        d = ty_elem(d);
    }
    if ty_kind(d) == TK_PTR && ty_kind(s) == TK_PTR { return types[s].n == types[d].n; }
    let sb = ld_primitive_bits(s);
    let db = ld_primitive_bits(d);
    if sb == 0 || db == 0 { return false; }
    if ld_is_scalable(s) != ld_is_scalable(d) { return false; }
    return sb == db;
}

// Type::getPrimitiveSizeInBits (known minimum for scalable vectors); 0 for pointers and aggregates
recursive fn ld_primitive_bits(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_INT || k == TK_BYTE { return ty_bits(t); }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    if k == TK_X86_AMX { return 8192; }
    if k == TK_FVEC || k == TK_SVEC { return ty_count(t) * ld_primitive_bits(ty_elem(t)); }
    return 0;
}
fn ld_is_scalable(t: i32) -> bool { ty_kind(t) == TK_SVEC }

// CastInst::isBitOrNoopPointerCastable(SrcTy, DestTy, DL)
fn ld_is_bit_or_noop_ptr_castable(s: i32, d: i32) -> bool {
    if ty_kind(s) == TK_PTR && ty_kind(d) == TK_INT {
        return ty_bits(d) == dl_ptr(types[s].n).bits && !dl_is_nonintegral_as(types[s].n as i64);
    }
    if ty_kind(d) == TK_PTR && ty_kind(s) == TK_INT {
        return ty_bits(s) == dl_ptr(types[d].n).bits && !dl_is_nonintegral_as(types[d].n as i64);
    }
    return ld_is_bit_castable(s, d);
}

// AreEquivalentAddressValues(A, B)
fn ld_equivalent_address_values(a: i32, b: i32) -> bool {
    if a == b { return true; }
    if is_inst(a) && (is_cast_op(iop(a)) || iop(a) == OP_PHI || iop(a) == OP_GEP) {
        if is_inst(b) && ii_is_identical_when_defined(a, b, false) { return true; }
    }
    return false;
}

fn ld_inst_align(i: i32) -> i64 { let a = insts[inst_of(i)].align; return if a == 0 { 1 } else { 1 << (a - 1) as i64 }; }
fn ld_is_atomic(i: i32) -> bool { insts[inst_of(i)].ord != 0 }
fn ld_is_volatile(i: i32) -> bool { (insts[inst_of(i)].bits & 1) != 0 }
// LoadInst/StoreInst::isUnordered: not volatile, NotAtomic or Unordered
fn ld_is_unordered(i: i32) -> bool { !ld_is_volatile(i) && insts[inst_of(i)].ord <= 1 }
// isSimple: not volatile, not atomic
fn ld_is_simple(i: i32) -> bool { !ld_is_volatile(i) && insts[inst_of(i)].ord == 0 }

// suppressSpeculativeLoadForSanitizers(CtxI)
fn ld_suppress_for_sanitizers(i: i32) -> bool { spec_sanitizer_suppresses(i) }

// isSafeToLoadUnconditionally(V, Alignment, Size, DL, ScanFrom, AC = null, DT = null, TLI = null).
// Size has the index width of V's type.
fn ld_safe_to_load_unconditionally(v0: i32, align: i64, size: AP, scan_from: i32) -> bool {
    return ld_safe_to_load_unconditionally_q(v0, align, size, scan_from, false);
}
// acdt: the caller passes its AssumptionCache and DominatorTree (VectorCombine)
fn ld_safe_to_load_unconditionally_q(v0: i32, align: i64, size: AP, scan_from: i32, acdt: bool) -> bool {
    let save_cxt = spec_cxt;
    let save_ac = spec_use_ac;
    let save_dt = spec_use_dt;
    spec_cxt = scan_from;
    spec_use_ac = acdt;
    if acdt { spec_use_dt = true; }
    spec_visited.clear();
    let d = spec_deref_aligned(v0, align, size, 16);
    spec_cxt = save_cxt;
    spec_use_ac = save_ac;
    spec_use_dt = save_dt;
    if d {
        if scan_from < 0 || !ld_suppress_for_sanitizers(scan_from) { return true; }
    }
    if scan_from < 0 { return false; }
    if size.w > 64 { return false; }
    let load_size = ap_zext64(size) as i64;
    let v = strip_ptr_casts(v0);
    var x = inst_prev(scan_from);
    while x >= 0 {
        let cur = x;
        x = inst_prev(x);
        let o = iop(cur);
        if o == OP_CALL && inst_may_write_memory(cur) && !inst_is_lifetime_start_or_end(cur) { return false; }
        var ap: i32 = -1;
        var at: i32 = -1;
        if o == OP_LOAD {
            if ld_is_volatile(cur) { continue; }
            ap = op(cur, 0);
            at = vals[cur].ty;
        } else if o == OP_STORE {
            if ld_is_volatile(cur) { continue; }
            ap = op(cur, 1);
            at = vals[op(cur, 0)].ty;
        } else {
            continue;
        }
        if ld_inst_align(cur) < align { continue; }
        // TypeSize::isKnownLE(LoadSize (fixed), StoreSize(AccessedTy))
        let ss = dl_store_size(at);
        if ap == v && load_size <= ss { return true; }
        if ld_equivalent_address_values(strip_ptr_casts(ap), v) && load_size <= ss { return true; }
    }
    return false;
}

// isSafeToLoadUnconditionally(V, Ty, Alignment, DL, ScanFrom, AC, DT)
fn ld_safe_to_load_unconditionally_ty_acdt(v: i32, ty: i32, align: i64, scan_from: i32) -> bool {
    if ty_contains_scalable(ty) { return false; }
    let w = dl_ptr(ptr_as(vals[v].ty)).idx;
    return ld_safe_to_load_unconditionally_q(v, align, ap_u64(dl_store_size(ty) as u64, w), scan_from, true);
}
// isSafeToLoadUnconditionally(V, Ty, Alignment, DL, ScanFrom)
fn ld_safe_to_load_unconditionally_ty(v: i32, ty: i32, align: i64, scan_from: i32) -> bool {
    if ty_contains_scalable(ty) { return false; }
    let w = dl_ptr(ptr_as(vals[v].ty)).idx;
    return ld_safe_to_load_unconditionally(v, align, ap_u64(dl_store_size(ty) as u64, w), scan_from);
}

// getAvailableLoadStore(Inst, Ptr, AccessTy, AtLeastAtomic, DL, IsLoadCSE): value or -1; ld_is_load_cse
var ld_is_load_cse: bool = false;
fn ld_get_available_load_store(inst: i32, ptr: i32, access_ty: i32, at_least_atomic: bool) -> i32 {
    let o = iop(inst);
    if o == OP_LOAD {
        if !ld_is_atomic(inst) && at_least_atomic { return -1; }
        let lp = strip_ptr_casts(op(inst, 0));
        if !ld_equivalent_address_values(lp, ptr) { return -1; }
        if ld_is_bit_or_noop_ptr_castable(vals[inst].ty, access_ty) {
            ld_is_load_cse = true;
            return inst;
        }
    }
    if o == OP_STORE {
        if !ld_is_atomic(inst) && at_least_atomic { return -1; }
        let sp = strip_ptr_casts(op(inst, 1));
        if !ld_equivalent_address_values(sp, ptr) { return -1; }
        ld_is_load_cse = false;
        let val = op(inst, 0);
        if ld_is_bit_or_noop_ptr_castable(vals[val].ty, access_ty) { return val; }
        let ssz = dl_size_bits(vals[val].ty);
        let lsz = dl_size_bits(access_ty);
        // TypeSize::isKnownLE: a scalable size is only known LE a scalable one
        let le = if ty_contains_scalable(access_ty) && !ty_contains_scalable(vals[val].ty) { false } else { lsz <= ssz };
        if le && is_constant(val) { return cf_fold_load_from_const(val, access_ty, 0); }
    }
    if inst_iid(inst) == IID_memset {
        if at_least_atomic { return -1; }
        let mv = cb_arg(inst, 1);
        let len = cb_arg(inst, 2);
        if vals[mv].kind != VK_CINT || vals[len].kind != VK_CINT { return -1; }
        let sb = strip_and_accumulate_offsets(cb_arg(inst, 0), true, false, false);
        let soff = vt_off;
        let lb = strip_and_accumulate_offsets(ptr, true, false, false);
        let loff = vt_off;
        if sb != lb || loff < soff { return -1; }
        ld_is_load_cse = false;
        if ty_contains_scalable(access_ty) { return -1; }
        let lsize = dl_size_bits(access_ty);
        // (Len * 8).ult(LoadSize + (LoadOffset - StoreOffset) * 8)
        // (Len * 8).ult(uint64_t): Len * 8 wraps in Len's width, the right side is not truncated
        let lw = ty_bits(vals[len].ty);
        let lhs = ap_mul(ci_ap(len), ap_u64(8, lw));
        let rhs = (lsize + (loff - soff) * 8) as u64;
        if ap_ult_u64(lhs, rhs) { return -1; }
        let bv = ci_ap(mv);
        let splat = if lsize >= 8 { ap_splat(lsize, bv) } else { ap_trunc(bv, lsize) };
        let sc = c_int_ap(ty_int(lsize), splat);
        if ld_is_bit_or_noop_ptr_castable(vals[sc].ty, access_ty) { return sc; }
        return -1;
    }
    return -1;
}

// FindAvailableLoadedValue(Load, BatchAA, IsLoadCSE, MaxInstsToScan = DefMaxInstsToScan). `q` is the
// BatchAAResults query context. Sets ld_is_load_cse.
fn ld_find_available_loaded_value(li: i32, q: i32, max_scan0: i64) -> i32 {
    ld_is_load_cse = false;
    let sp = strip_ptr_casts(op(li, 0));
    let bb = inst_parent(li);
    let access_ty = vals[li].ty;
    let at_least_atomic = ld_is_atomic(li);
    if !ld_is_unordered(li) { return -1; }
    var max_scan = max_scan0;
    var avail: i32 = -1;
    var must_not_alias: i32[>..<] = [];
    var x = inst_prev(li);
    while x >= 0 {
        let cur = x;
        x = inst_prev(x);
        if ld_is_debug_or_pseudo(cur) { continue; }
        if max_scan == 0 { return -1; }
        max_scan--;
        avail = ld_get_available_load_store(cur, sp, access_ty, at_least_atomic);
        if avail >= 0 { break; }
        if inst_may_write_memory(cur) { must_not_alias.push(cur); }
    }
    if avail >= 0 {
        let loc = ml_get(li);
        for i in must_not_alias {
            let mr = aa_inst_loc_mr(i, loc, q);
            if (mr & MR_MOD) != 0 { return -1; }
        }
    }
    return avail;
}
fn ld_max_insts_to_scan() -> i64 { flag_int("available-load-scan-limit", 6) }

fn ld_is_debug_or_pseudo(i: i32) -> bool {
    let id = inst_iid(i);
    return id == IID_pseudoprobe || id == IID_dbg_declare || id == IID_dbg_value || id == IID_dbg_label || id == IID_dbg_assign;
}
