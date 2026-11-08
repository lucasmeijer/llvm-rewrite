// EarlyCSE: port of llvm/lib/Transforms/Scalar/EarlyCSE.cpp (early-cse and early-cse<memssa>), with
// llvm/include/llvm/ADT/ScopedHashTable.h (the five scoped tables), combineMetadataForCSE and
// replaceDominatedUsesWith (llvm/lib/Transforms/Utils/Local.cpp), MDNode::getMostGenericRange & co.
// (llvm/lib/IR/Metadata.cpp) and GEPOperator::accumulateConstantOffset (llvm/lib/IR/Operator.cpp).
//
// The scoped hash tables: one chained hash map for all five tables (entries tagged with the table), whose
// entries hold the DenseMap bucket key (the key of the first insertion) and the head of the value chain
// (ScopedHashTableVal: NextForKey / NextInScope). The hash of an entry is the one computed when it was
// created, like a DenseMap bucket position: an instruction whose operands change afterwards is no longer
// found under its new hash, as in LLVM. Hashes are LLVM's getHashValue with value ids instead of pointers
// (equal keys hash equally; the order of pointer comparisons only picks which commuted form is hashed).
// -earlycse-debug-hash only changes hashing in assertion builds (#ifndef NDEBUG); LLVM 23.1.5 here is a
// release build, so it is accepted and ignored.
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
import analyses;
import flags;
import tli;
import local;
import pm;
import vt;
import poison;
import assume;
import instsimplify;
import memloc;
import aa;
import memoryssa;
import mssaupdater;
import instident;
import mem2reg;
import predinfo;
import printer;
import apint;
import constrange;
import dinfo;
import implied;
import loopinfo;
import salvage;
import knowledge;

let ET_VALUES = 0;
let ET_LOADS = 1;
let ET_INVARIANTS = 2;
let ET_CALLS = 3;
let ET_GEPS = 4;

struct EcKey { a: i32, has_off: bool, off: i64, ml: ML }
// ScopedHashTableVal: key, value (v; loads: DefInst, Generation, MatchingId, IsAtomic, IsLoad; calls: (v, gen);
// invariants: gen), NextForKey, NextInScope
struct EcVal { tbl: i32, key: EcKey, v: i32, gen: u32, mid: i32, atomic: bool, isload: bool, next_key: i32, next_scope: i32 }
// TopLevelMap entry
struct EcEnt { tbl: i32, key: EcKey, head: i32, hash: u64, chain: i32, live: bool }

var ec_vals: EcVal[>..<];
var ec_ents: EcEnt[>..<];
var ec_bk: i32[>..<];
var ec_nents: i64 = 0;       // entries in ec_ents that are linked in buckets (live or dead)
var ec_scope_last: i32 = -1; // LastValInScope of the innermost scope

var ec_fn: i32 = -1;
var ec_use_mssa = false;
var ec_gen: u32 = 0;
var ec_clobber_counter: i64 = 0;
var ec_mssa_cap: i64 = 500;

fn ec_key(a: i32) -> EcKey { EcKey { a: a, has_off: false, off: 0, ml: ml_none() } }

// ---------------------------------------------------------------------------------------------
// Hashing

fn ec_mix(h: u64, x: u64) -> u64 {
    var z = (h ^ x) * 0x9E3779B97F4A7C15;
    z = z ^ (z >> 31);
    z = z * 0xBF58476D1CE4E5B9;
    return z ^ (z >> 29);
}
fn ec_hv(h: u64, v: i32) -> u64 { ec_mix(h, ((v as i64) + 7) as! u64) }
fn ec_hu(h: u64, x: i64) -> u64 { ec_mix(h, x as! u64) }

fn ec_hash_ops_from(h0: u64, iv: i32, from: i64) -> u64 {
    var h = h0;
    for k in from..nops(iv) { h = ec_hv(h, op(iv, k)); }
    return h;
}
fn ec_hash_ints(h0: u64, iv: i32) -> u64 {
    var h = h0;
    let x = insts[inst_of(iv)];
    for k in x.naux { h = ec_hu(h, ints[x.aux + k] as i64); }
    return h;
}


fn ec_is_cmp_inst(v: i32) -> bool { is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) }

// matchSelectWithOptionalNotCond: (is select, Cond, A, B, Flavor)
fn ec_match_select(v: i32) -> bool, i32, i32, i32, i64 {
    if !is_inst(v) || iop(v) != OP_SELECT { return false, -1, -1, -1, SPF_UNKNOWN; }
    var c = op(v, 0);
    var a = op(v, 1);
    var b = op(v, 2);
    let cn = m_not(c);
    if cn >= 0 { c = cn; let t = a; a = b; b = t; }
    if !is_inst(c) || iop(c) != OP_ICMP { return true, c, a, b, SPF_UNKNOWN; }
    var p = inst_pred(c);
    if !(op(c, 0) == a && op(c, 1) == b) {
        if !(op(c, 0) == b && op(c, 1) == a) { return true, c, a, b, SPF_UNKNOWN; }
        p = pred_swap_any(p);
    }
    var f = SPF_UNKNOWN;
    if p == P_UGT || p == P_UGE { f = SPF_UMAX; }
    else if p == P_ULT || p == P_ULE { f = SPF_UMIN; }
    else if p == P_SGT || p == P_SGE { f = SPF_SMAX; }
    else if p == P_SLT || p == P_SLE { f = SPF_SMIN; }
    return true, c, a, b, f;
}
fn ec_is_minmax(f: i64) -> bool { f == SPF_SMIN || f == SPF_SMAX || f == SPF_UMIN || f == SPF_UMAX }

fn ec_is_gc_relocate(iv: i32) -> bool { inst_iid(iv) == IID_experimental_gc_relocate }

// hashCallInst
fn ec_hash_call(iv: i32) -> u64 {
    var h = ec_hu(0x5EED, iop(iv));
    if call_has_fn_attr(iv, AK_Convergent) { h = ec_hv(h, inst_parent(iv)); }
    return ec_hash_ops_from(h, iv, 0);
}

// getHashValueImpl(SimpleValue)
fn ec_simple_hash(iv: i32) -> u64 {
    let o = iop(iv);
    let h = ec_hu(0x5EED, o);
    if is_binary_op(o) {
        var l = op(iv, 0);
        var r = op(iv, 1);
        if ii_opcode_is_commutative(o) && l > r { let t = l; l = r; r = t; }
        return ec_hv(ec_hv(h, l), r);
    }
    if o == OP_ICMP || o == OP_FCMP {
        var l = op(iv, 0);
        var r = op(iv, 1);
        var p = inst_pred(iv);
        let sp = pred_swap_any(p);
        if l > r || (l == r && p > sp) { let t = l; l = r; r = t; p = sp; }
        return ec_hv(ec_hv(ec_hu(h, p), l), r);
    }
    let is_sel, c, a0, b0, spf = ec_match_select(iv);
    if is_sel {
        var a = a0;
        var b = b0;
        if ec_is_minmax(spf) {
            if a > b { let t = a; a = b; b = t; }
            return ec_hv(ec_hv(ec_hu(h, spf), a), b);
        }
        if !ec_is_cmp_inst(c) { return ec_hv(ec_hv(ec_hv(h, c), a), b); }
        var p = inst_pred(c);
        let x = op(c, 0);
        let y = op(c, 1);
        let ip = pred_inverse_any(p);
        if ip < p { p = ip; let t = a; a = b; b = t; }
        return ec_hv(ec_hv(ec_hv(ec_hv(ec_hu(h, p), x), y), a), b);
    }
    if is_cast_op(o) { return ec_hv(ec_hu(h, vals[iv].ty as i64), op(iv, 0)); }
    if o == OP_FREEZE { return ec_hv(h, op(iv, 0)); }
    if o == OP_EXTRACTVALUE { return ec_hash_ints(ec_hv(h, op(iv, 0)), iv); }
    if o == OP_INSERTVALUE { return ec_hash_ints(ec_hv(ec_hv(h, op(iv, 0)), op(iv, 1)), iv); }
    let id = inst_iid(iv);
    if id != 0 && ii_intrinsic_is_commutative(id) && cb_nargs(iv) >= 2 {
        var l = cb_arg(iv, 0);
        var r = cb_arg(iv, 1);
        if l > r { let t = l; l = r; r = t; }
        return ec_hash_ops_from(ec_hv(ec_hv(h, l), r), iv, 2);
    }
    if id == IID_experimental_gc_relocate {
        return ec_hv(ec_hv(ec_hv(h, op(iv, 0)), gc_ptr_operand(iv, 1)), gc_ptr_operand(iv, 2));
    }
    if o == OP_CALL { return ec_hash_call(iv); }
    if o == OP_SHUFFLEVECTOR { return ec_hash_ops_from(h, iv, 0); }
    return ec_hash_ops_from(h, iv, 0);
}

// isEqualImpl(SimpleValue)
fn ec_simple_equal(l: i32, r: i32) -> bool {
    if iop(l) != iop(r) { return false; }
    if ii_is_identical_when_defined(l, r, true) {
        if iop(l) == OP_CALL && call_has_fn_attr(l, AK_Convergent) && inst_parent(l) != inst_parent(r) { return false; }
        return true;
    }
    let o = iop(l);
    if is_binary_op(o) {
        if !ii_opcode_is_commutative(o) { return false; }
        return op(l, 0) == op(r, 1) && op(l, 1) == op(r, 0);
    }
    if o == OP_ICMP || o == OP_FCMP {
        return op(l, 0) == op(r, 1) && op(l, 1) == op(r, 0) && pred_swap_any(inst_pred(l)) == inst_pred(r);
    }
    let li = inst_iid(l);
    let ri = inst_iid(r);
    if li != 0 && ri != 0 && li == ri && ii_intrinsic_is_commutative(li) && cb_nargs(l) >= 2 {
        if !(cb_arg(l, 0) == cb_arg(r, 1) && cb_arg(l, 1) == cb_arg(r, 0)) { return false; }
        let n = cb_nargs(l);
        if cb_nargs(r) != n { return false; }
        for k in 2..n { if cb_arg(l, k) != cb_arg(r, k) { return false; } }
        return ii_has_same_special_state(l, r, false, true);
    }
    if li == IID_experimental_gc_relocate && ri == IID_experimental_gc_relocate {
        return op(l, 0) == op(r, 0) && gc_ptr_operand(l, 1) == gc_ptr_operand(r, 1) &&
               gc_ptr_operand(l, 2) == gc_ptr_operand(r, 2);
    }
    let sl, cl, la, lb, lf = ec_match_select(l);
    if sl {
        let sr, cr, ra, rb, rf = ec_match_select(r);
        if sr {
            if lf == rf {
                if ec_is_minmax(lf) { return (la == ra && lb == rb) || (la == rb && lb == ra); }
                if cl == cr && la == ra && lb == rb { return true; }
            }
            if la == rb && lb == ra {
                if ec_is_cmp_inst(cl) && ec_is_cmp_inst(cr) && op(cr, 0) == op(cl, 0) && op(cr, 1) == op(cl, 1) &&
                   pred_inverse_any(inst_pred(cl)) == inst_pred(cr) {
                    return true;
                }
            }
        }
    }
    return false;
}

// DenseMapInfo<CallValue>::isEqual
fn ec_call_equal(l: i32, r: i32) -> bool {
    if call_has_fn_attr(l, AK_Convergent) && inst_parent(l) != inst_parent(r) { return false; }
    return ii_is_identical_when_defined(l, r, true);
}

fn ec_gep_hash(k: EcKey) -> u64 {
    let h = ec_hu(0x5EED, OP_GEP);
    if k.has_off { return ec_hu(ec_hv(h, op(k.a, 0)), k.off); }
    return ec_hash_ops_from(h, k.a, 0);
}
fn ec_gep_equal(l: EcKey, r: EcKey) -> bool {
    if op(l.a, 0) != op(r.a, 0) { return false; }
    if l.has_off && r.has_off { return l.off == r.off; }
    return ii_is_identical_when_defined(l.a, r.a, false);
}

fn ec_ml_hash(m: ML) -> u64 {
    var h = ec_hv(0x1D, m.ptr);
    h = ec_mix(h, m.size);
    h = ec_hv(h, m.tbaa);
    h = ec_hv(h, m.tbaa_struct);
    h = ec_hv(h, m.scope);
    h = ec_hv(h, m.noalias);
    return ec_hv(h, m.noalias_as);
}

fn ec_hash(tbl: i32, k: EcKey) -> u64 {
    var h: u64 = 0;
    if tbl == ET_VALUES { h = ec_simple_hash(k.a); }
    else if tbl == ET_LOADS { h = ec_hv(0x10AD, k.a); }
    else if tbl == ET_INVARIANTS { h = ec_ml_hash(k.ml); }
    else if tbl == ET_CALLS { h = ec_hash_call(k.a); }
    else { h = ec_gep_hash(k); }
    return ec_hu(h, tbl as i64);
}

// isEqual(Lookup key, bucket key)
fn ec_key_equal(tbl: i32, a: EcKey, b: EcKey) -> bool {
    if tbl == ET_VALUES { return a.a == b.a || ec_simple_equal(a.a, b.a); }
    if tbl == ET_LOADS { return a.a == b.a; }
    if tbl == ET_INVARIANTS { return ml_eq(a.ml, b.ml); }
    if tbl == ET_CALLS { return a.a == b.a || ec_call_equal(a.a, b.a); }
    return a.a == b.a || ec_gep_equal(a, b);
}

// ---------------------------------------------------------------------------------------------
// ScopedHashTable

fn ec_tables_reset() {
    ec_vals.clear();
    ec_ents.clear();
    ec_bk.clear();
    ec_nents = 0;
    ec_scope_last = -1;
}

fn ec_rehash() {
    var nb: i64 = 64;
    var live: i64 = 0;
    for e in ec_ents { if e.live { live++; } }
    while nb < live * 4 + 64 { nb *= 2; }
    // compact: drop dead entries, keep creation order (bucket chains stay oldest first)
    var w: i64 = 0;
    for k in ec_ents.len {
        if ec_ents[k].live { ec_ents[w] = ec_ents[k]; w++; }
    }
    ec_ents.resize(w);
    ec_bk.clear();
    ec_bk.resize(nb, -1);
    var tails: i32[>..<] = [];
    tails.resize(nb, -1);
    for k in w {
        ec_ents[k].chain = -1;
        let b = (ec_ents[k].hash & ((nb - 1) as u64)) as i64;
        if tails[b] < 0 { ec_bk[b] = k as i32; } else { ec_ents[tails[b]].chain = k as i32; }
        tails[b] = k as i32;
    }
    ec_nents = w;
}

fn ec_find_h(tbl: i32, k: EcKey, h: u64) -> i32 {
    if ec_bk.len == 0 { return -1; }
    var e = ec_bk[(h & ((ec_bk.len - 1) as u64)) as i64];
    while e >= 0 {
        let x = ec_ents[e];
        if x.live && x.tbl == tbl && x.hash == h && ec_key_equal(tbl, k, x.key) { return e; }
        e = x.chain;
    }
    return -1;
}

// TopLevelMap[Key]: find or insert an empty entry
fn ec_find_or_add(tbl: i32, k: EcKey) -> i32 {
    let h = ec_hash(tbl, k);
    let e = ec_find_h(tbl, k, h);
    if e >= 0 { return e; }
    if (ec_nents + 1) * 2 > ec_bk.len { ec_rehash(); }
    let id = ec_ents.len as i32;
    ec_ents.push(EcEnt { tbl: tbl, key: k, head: -1, hash: h, chain: -1, live: true });
    ec_nents++;
    let b = (h & ((ec_bk.len - 1) as u64)) as i64;
    var x = ec_bk[b];
    if x < 0 { ec_bk[b] = id; }
    else {
        while ec_ents[x].chain >= 0 { x = ec_ents[x].chain; }
        ec_ents[x].chain = id;
    }
    return id;
}

// ScopedHashTable::insert(Key, Val) into the current scope; returns the new value record
fn ec_insert(tbl: i32, k: EcKey, v: i32, gen: u32, mid: i32, atomic: bool, isload: bool) {
    let e = ec_find_or_add(tbl, k);
    let r = ec_vals.len as i32;
    ec_vals.push(EcVal { tbl: tbl, key: k, v: v, gen: gen, mid: mid, atomic: atomic, isload: isload,
                         next_key: ec_ents[e].head, next_scope: ec_scope_last });
    ec_ents[e].head = r;
    ec_scope_last = r;
}

// lookup: the value record, -1 if none
fn ec_lookup(tbl: i32, k: EcKey) -> i32 {
    let e = ec_find_h(tbl, k, ec_hash(tbl, k));
    if e < 0 { return -1; }
    return ec_ents[e].head;
}

// ~ScopedHashTableScope
fn ec_scope_pop(saved_last: i32) {
    var r = ec_scope_last;
    while r >= 0 {
        let x = ec_vals[r];
        if x.next_key < 0 {
            let e = ec_find_h(x.tbl, x.key, ec_hash(x.tbl, x.key));
            if e >= 0 { ec_ents[e].live = false; }
        } else {
            let e = ec_find_or_add(x.tbl, x.key);
            ec_ents[e].head = x.next_key;
        }
        r = x.next_scope;
    }
    ec_scope_last = saved_last;
}

// ---------------------------------------------------------------------------------------------
// SimpleValue / CallValue / GEPValue ::canHandle

// ConstrainedFPIntrinsic::getExceptionBehavior: -1 none, 0 ignore, 1 maytrap, 2 strict
fn ec_cfp_exception(iv: i32) -> i64 {
    let n = cb_nargs(iv);
    if n == 0 { return -1; }
    let a = cb_arg(iv, n - 1);
    if vals[a].kind != VK_MDVAL { return -1; }
    let m = vals[a].sub;
    if mds[m].kind != MK_STRING { return -1; }
    let s = sbytes(mds[m].extra);
    if s == "fpexcept.ignore" { return 0; }
    if s == "fpexcept.maytrap" { return 1; }
    if s == "fpexcept.strict" { return 2; }
    return -1;
}
// getRoundingMode() == RoundingMode::Dynamic
fn ec_cfp_rounding_dynamic(iv: i32) -> bool {
    let n = cb_nargs(iv);
    if n < 2 { return false; }
    let a = cb_arg(iv, n - 2);
    if vals[a].kind != VK_MDVAL { return false; }
    let m = vals[a].sub;
    if mds[m].kind != MK_STRING { return false; }
    return sbytes(mds[m].extra) == "round.dynamic";
}

fn ec_fn_presplit_coroutine() -> bool { func_has_fn_attr(ec_fn, AK_PresplitCoroutine) }

fn ec_simple_can_handle(iv: i32) -> bool {
    if !is_inst(iv) { return false; }
    let o = iop(iv);
    if o == OP_CALL {
        let f = called_function(iv);
        if f >= 0 {
            let id = call_iid(iv);
            if id == IID_experimental_constrained_fadd || id == IID_experimental_constrained_fsub ||
               id == IID_experimental_constrained_fmul || id == IID_experimental_constrained_fdiv ||
               id == IID_experimental_constrained_frem || id == IID_experimental_constrained_fptosi ||
               id == IID_experimental_constrained_sitofp || id == IID_experimental_constrained_fptoui ||
               id == IID_experimental_constrained_uitofp || id == IID_experimental_constrained_fcmp ||
               id == IID_experimental_constrained_fcmps {
                if ec_cfp_exception(iv) == 2 { return false; }
                if ec_cfp_rounding_dynamic(iv) { return false; }
                return true;
            }
        }
        return call_does_not_access_memory(iv) && !ec_fn_presplit_coroutine();
    }
    return is_cast_op(o) || o == OP_FNEG || is_binary_op(o) || o == OP_ICMP || o == OP_FCMP || o == OP_SELECT ||
           o == OP_EXTRACTELEMENT || o == OP_INSERTELEMENT || o == OP_SHUFFLEVECTOR || o == OP_EXTRACTVALUE ||
           o == OP_INSERTVALUE || o == OP_FREEZE;
}

fn ec_call_can_handle(iv: i32) -> bool {
    if iop(iv) != OP_CALL { return false; }
    if !call_only_reads_memory(iv) && !call_only_writes_memory(iv) { return false; }
    if ec_fn_presplit_coroutine() { return false; }
    return true;
}

// ---------------------------------------------------------------------------------------------
// ParseMemoryInst (TTI.getTgtMemIntrinsic is false for x86 and for the default target)

struct PMI { inst: i32, iid: i32, ptr: i32, read: bool, write: bool, vol: bool, mid: i32 }

fn ec_is_memset(iv: i32) -> bool { let id = inst_iid(iv); id == IID_memset || id == IID_memset_inline }

fn ec_parse_mem(iv: i32) -> PMI {
    var m = PMI { inst: iv, iid: 0, ptr: -1, read: false, write: false, vol: false, mid: 0 };
    let id = inst_iid(iv);
    if id == 0 { return m; }
    m.iid = id;
    if id == IID_masked_load { m.ptr = op(iv, 0); m.mid = IID_masked_load; m.read = true; }
    else if id == IID_masked_store { m.ptr = op(iv, 1); m.mid = IID_masked_load; m.write = true; }
    else if id == IID_memset || id == IID_memset_inline {
        m.ptr = cb_arg(iv, 0);
        m.write = true;
        m.vol = !is_null_value(cb_arg(iv, 3));
    }
    return m;
}
fn pm_is_load(m: PMI) -> bool { if m.iid != 0 { m.read } else { iop(m.inst) == OP_LOAD } }
fn pm_is_store(m: PMI) -> bool { if m.iid != 0 { m.write } else { iop(m.inst) == OP_STORE } }
// Instruction::isAtomic
fn ec_inst_is_atomic(iv: i32) -> bool {
    let o = iop(iv);
    if o == OP_LOAD || o == OP_STORE { return insts[inst_of(iv)].ord != 0; }
    return o == OP_CMPXCHG || o == OP_ATOMICRMW || o == OP_FENCE;
}
fn pm_is_atomic(m: PMI) -> bool { if m.iid != 0 { false } else { ec_inst_is_atomic(m.inst) } }
fn pm_is_unordered(m: PMI) -> bool {
    if m.iid != 0 { return !m.vol; }
    let o = iop(m.inst);
    if o == OP_LOAD || o == OP_STORE { return ldst_is_unordered(m.inst); }
    return !ec_inst_is_atomic(m.inst);
}
fn pm_is_volatile(m: PMI) -> bool {
    if m.iid != 0 { return m.vol; }
    let o = iop(m.inst);
    if o == OP_LOAD || o == OP_STORE { return (insts[inst_of(m.inst)].bits & 1) != 0; }
    return true;
}
fn pm_is_invariant_load(m: PMI) -> bool { iop(m.inst) == OP_LOAD && inst_get_md(m.inst, MDK_INVARIANT_LOAD) >= 0 }
fn pm_ptr(m: PMI) -> i32 {
    if m.iid != 0 { return m.ptr; }
    let o = iop(m.inst);
    if o == OP_LOAD { return op(m.inst, 0); }
    if o == OP_STORE { return op(m.inst, 1); }
    return -1;
}
fn pm_valid(m: PMI) -> bool { pm_ptr(m) >= 0 }
fn pm_matching_id(m: PMI) -> i32 { if m.iid != 0 { m.mid } else { -1 } }
// Instruction::getAccessType; -1 = nullptr
fn ec_access_type(iv: i32) -> i32 {
    let o = iop(iv);
    if o == OP_STORE { return vals[op(iv, 0)].ty; }
    if o == OP_LOAD || o == OP_ATOMICRMW { return vals[iv].ty; }
    if o == OP_CMPXCHG { return vals[op(iv, 2)].ty; }
    if o == OP_CALL || o == OP_INVOKE {
        let id = inst_iid(iv);
        if id == IID_masked_load || id == IID_masked_gather || id == IID_masked_expandload || id == IID_vp_load ||
           id == IID_vp_gather || id == IID_experimental_vp_strided_load { return vals[iv].ty; }
        if id == IID_masked_store || id == IID_masked_scatter || id == IID_masked_compressstore || id == IID_vp_store ||
           id == IID_vp_scatter || id == IID_experimental_vp_strided_store { return vals[op(iv, 0)].ty; }
    }
    return -1;
}
fn pm_value_type(m: PMI) -> i32 { ec_access_type(m.inst) }
fn pm_may_read(m: PMI) -> bool { if m.iid != 0 { m.read } else { inst_may_read_memory(m.inst) } }
fn pm_may_write(m: PMI) -> bool { if m.iid != 0 { m.write } else { inst_may_write_memory(m.inst) } }

fn ec_is_handled_non_target_intrinsic(v: i32) -> bool {
    let id = inst_iid(v);
    return id == IID_masked_load || id == IID_masked_store;
}

// getOrCreateResult(Inst, ExpectedType, CanCreate); -1 = nullptr
fn ec_get_or_create_result(iv: i32, expected: i32) -> i32 {
    var v: i32 = -1;
    let id = inst_iid(iv);
    if id == IID_masked_load { v = iv; }
    else if id == IID_masked_store { v = op(iv, 0); }
    else if id != 0 { return -1; }        // TTI.getOrCreateResultFromMemIntrinsic: none for x86 / default
    else if iop(iv) == OP_LOAD { v = iv; }
    else { v = op(iv, 0); }
    return if vals[v].ty == expected { v } else { -1 };
}

fn ec_is_submask(m0: i32, m1: i32) -> bool {
    if m0 == m1 { return true; }
    if is_undef_val(m0) || is_undef_val(m1) { return false; }
    if vals[m0].kind != VK_CVECTOR || vals[m1].kind != VK_CVECTOR { return false; }
    if vals[m0].ty != vals[m1].ty { return false; }
    for i in nops(m0) {
        let e0 = op(m0, i);
        let e1 = op(m1, i);
        if vals[e0].kind == VK_CINT && cint_is_zero(e0) { continue; }
        if vals[e1].kind == VK_CINT && !cint_is_zero(e1) { continue; }
        if is_undef_val(e0) || is_undef_val(e1) { return false; }
        if e0 == e1 { continue; }
        return false;
    }
    return true;
}

fn ec_is_non_target_intrinsic_match(earlier: i32, later: i32) -> bool {
    let ide = inst_iid(earlier);
    let idl = inst_iid(later);
    let pe = if ide == IID_masked_load { op(earlier, 0) } else { op(earlier, 1) };
    let pl = if idl == IID_masked_load { op(later, 0) } else { op(later, 1) };
    if pe != pl { return false; }
    let me = if ide == IID_masked_load { op(earlier, 1) } else { op(earlier, 2) };
    let ml = if idl == IID_masked_load { op(later, 1) } else { op(later, 2) };
    if ide == IID_masked_load && idl == IID_masked_load {
        if me == ml && op(earlier, 2) == op(later, 2) { return true; }
        if !is_undef_val(op(later, 2)) { return false; }
        return ec_is_submask(ml, me);
    }
    if ide == IID_masked_store && idl == IID_masked_load {
        if !ec_is_submask(ml, me) { return false; }
        return is_undef_val(op(later, 2));
    }
    if ide == IID_masked_load && idl == IID_masked_store { return ec_is_submask(ml, me); }
    if ide == IID_masked_store && idl == IID_masked_store { return ec_is_submask(me, ml); }
    return false;
}


// ---------------------------------------------------------------------------------------------
// Mutation helpers

fn ec_rauw(old: i32, nv: i32) {
    ac_rauw(old, nv);
    rauw(old, nv);
    if dbgrecs.len > 0 { m2r_dbg_rauw(old, nv); }
}
fn ec_remove_mssa(iv: i32) {
    if !ec_use_mssa { return; }
    msu_remove_inst_access(iv, true);
}
fn ec_erase(iv: i32) {
    m2r_erase(iv);
}

// replaceDominatedUsesWith(From, To, DT, BasicBlockEdge(start, end))
fn ec_replace_dominated_uses(from: i32, to: i32, start: i32, end: i32) -> i64 {
    var count: i64 = 0;
    var u = vals[from].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let user = uses[u].user;
        if !(is_inst(user) && inst_iid(user) == IID_fake_use) && pi_edge_dominates_use(start, end, u) {
            use_set(u, to);
            count++;
        }
        u = nx;
    }
    return count;
}

// combineIRFlags(From, To)
fn ec_combine_ir_flags(from: i32, to: i32) {
    if is_inst(to) {
        if is_fp_math_operator(to) || (has_poison_generating_flags(to) && !program_undefined_if_undef_or_poison(to, true)) {
            ii_and_ir_flags(to, from);
        }
    }
    if is_callbase(from) && is_callbase(to) {
        if !ii_try_intersect_attributes(to, from) { fatal("internal: EarlyCSE: failed to intersect attributes in callsites that passed identical check"); }
    }
}

// ---------------------------------------------------------------------------------------------
// combineMetadataForCSE(K, J, DoesKMove = false)

let EC_MD_PROF: i32 = 2;
let EC_MD_FPMATH: i32 = 3;
let EC_MD_RANGE: i32 = 4;
let EC_MD_NONTEMPORAL: i32 = 9;
let EC_MD_NONNULL: i32 = 11;
let EC_MD_ALIGN: i32 = 17;
let EC_MD_NOUNDEF: i32 = 29;
let EC_MD_NOSANITIZE: i32 = 31;
let EC_MD_MEMPROF: i32 = 34;
let EC_MD_CALLSITE: i32 = 35;
let EC_MD_DIASSIGNID: i32 = 38;
let EC_MD_MMRA: i32 = 40;
let EC_MD_CALLEE_TYPE: i32 = 42;
let EC_MD_ALLOC_TOKEN: i32 = 45;
let EC_MD_NOFPCLASS: i32 = 47;
let EC_MD_MEM_CACHE_HINT: i32 = 52;

fn ec_set_md(iv: i32, kind: i32, node: i32) {
    if node < 0 { inst_erase_md(iv, kind); } else { inst_set_md(iv, kind, node); }
}
fn ec_md_cint(m: i32, k: i64) -> i32 { mds[md_op(m, k)].extra }

fn ec_range_can_be_merged(a: CRange, b: CRange) -> bool {
    return !rg_is_empty(rg_intersect(a, b)) || ap_eq(a.hi, b.lo) || ap_eq(a.lo, b.hi);
}
// tryMergeRange(EndPoints, Low, High)
fn ec_try_merge_range(eps: i32[>..<]&, lo: i32, hi: i32) -> bool {
    let nr = rg_new(ap_from_cint(lo), ap_from_cint(hi));
    let n = eps.len;
    let last = rg_new(ap_from_cint(eps[n - 2]), ap_from_cint(eps[n - 1]));
    if ec_range_can_be_merged(nr, last) {
        let u = rg_union(last, nr);
        let t = vals[hi].ty;
        eps[n - 2] = ap_to_cint(t, u.lo);
        eps[n - 1] = ap_to_cint(t, u.hi);
        return true;
    }
    return false;
}
fn ec_add_range(eps: i32[>..<]&, lo: i32, hi: i32) {
    if eps.len > 0 && ec_try_merge_range(eps, lo, hi) { return; }
    eps.push(lo);
    eps.push(hi);
}
// MDNode::getMostGenericRange(A, B)
fn ec_most_generic_range(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    var eps: i32[>..<] = [];
    var ai: i64 = 0;
    var bi: i64 = 0;
    let an = mds[a].nops as i64 / 2;
    let bn = mds[b].nops as i64 / 2;
    while ai < an && bi < bn {
        let alo = ec_md_cint(a, 2 * ai);
        let blo = ec_md_cint(b, 2 * bi);
        if ap_slt(ap_from_cint(alo), ap_from_cint(blo)) {
            ec_add_range(eps, alo, ec_md_cint(a, 2 * ai + 1));
            ai++;
        } else {
            ec_add_range(eps, blo, ec_md_cint(b, 2 * bi + 1));
            bi++;
        }
    }
    while ai < an { ec_add_range(eps, ec_md_cint(a, 2 * ai), ec_md_cint(a, 2 * ai + 1)); ai++; }
    while bi < bn { ec_add_range(eps, ec_md_cint(b, 2 * bi), ec_md_cint(b, 2 * bi + 1)); bi++; }
    let size = eps.len;
    if size > 2 {
        let fb = eps[0];
        let fe = eps[1];
        if ec_try_merge_range(eps, fb, fe) {
            for i in size - 2 { eps[i] = eps[i + 2]; }
            eps.resize(size - 2);
        }
    }
    if eps.len == 2 {
        let r = rg_new(ap_from_cint(eps[0]), ap_from_cint(eps[1]));
        if rg_is_full(r) { return -1; }
    }
    var ops: i32[>..<] = [];
    for x in eps { ops.push(md_value(x)); }
    return md_get(MK_TUPLE, -1, ops, false);
}
// MDNode::getMostGenericNoFPClass(A, B)
fn ec_most_generic_nofpclass(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if a == b { return a; }
    let av = ec_md_cint(a, 0);
    let bv = ec_md_cint(b, 0);
    let x = cint_lo(av) & cint_lo(bv);
    if x == 0 { return -1; }
    return md_get(MK_TUPLE, -1, [md_value(c_int(vals[av].ty, x as! i64))], false);
}
// MDNode::getMostGenericAlignmentOrDereferenceable(A, B)
fn ec_most_generic_align(a: i32, b: i32) -> i32 {
    if a < 0 || b < 0 { return -1; }
    if cint_lo(ec_md_cint(a, 0)) < cint_lo(ec_md_cint(b, 0)) { return a; }
    return b;
}

fn ec_combine_metadata_for_cse(k: i32, j: i32) {
    // getAllMetadataOtherThanDebugLoc: a snapshot of K's attachments, in kind order
    var kinds: i32[>..<] = [];
    var nodes: i32[>..<] = [];
    let ki = inst_of(k);
    for x in insts[ki].nmd {
        let kind = md_att[insts[ki].md + 2 * x];
        if kind == 0 { continue; }
        kinds.push(kind);
        nodes.push(md_att[insts[ki].md + 2 * x + 1]);
    }
    for x in kinds.len {
        let kind = kinds[x];
        let kmd = nodes[x];
        let jmd = inst_get_md(j, kind);
        if kind == MDK_TBAA || kind == MDK_ALIAS_SCOPE || kind == MDK_NOALIAS || kind == MDK_MEM_PARALLEL_LOOP_ACCESS ||
           kind == MDK_ACCESS_GROUP || kind == MDK_INVARIANT_LOAD || kind == MDK_INVARIANT_GROUP ||
           kind == MDK_DEREFERENCEABLE || kind == MDK_DEREFERENCEABLE_OR_NULL || kind == 27 || kind == EC_MD_NOUNDEF ||
           kind == MDK_NOALIAS_ADDRSPACE || kind == EC_MD_PROF || kind == EC_MD_MMRA || kind == EC_MD_MEMPROF ||
           kind == EC_MD_CALLSITE {
            continue;      // kept (DoesKMove = false), or merged below
        }
        if kind == EC_MD_DIASSIGNID { fatal("EarlyCSE: mergeDIAssignID (combineMetadataForCSE) is not ported yet"); }
        if kind == EC_MD_RANGE {
            if inst_get_md(k, EC_MD_NOUNDEF) < 0 { ec_set_md(k, kind, ec_most_generic_range(jmd, kmd)); }
            continue;
        }
        if kind == EC_MD_NOFPCLASS {
            if inst_get_md(k, EC_MD_NOUNDEF) < 0 { ec_set_md(k, kind, ec_most_generic_nofpclass(jmd, kmd)); }
            continue;
        }
        if kind == EC_MD_FPMATH {
            if jmd != kmd { fatal("EarlyCSE: MDNode::getMostGenericFPMath (combineMetadataForCSE) is not ported yet"); }
            continue;
        }
        if kind == EC_MD_NONNULL {
            if inst_get_md(k, EC_MD_NOUNDEF) < 0 { ec_set_md(k, kind, jmd); }
            continue;
        }
        if kind == EC_MD_CALLEE_TYPE { fatal("EarlyCSE: getMergedCalleeTypeMetadata (combineMetadataForCSE) is not ported yet"); }
        if kind == EC_MD_ALIGN {
            if inst_get_md(k, EC_MD_NOUNDEF) < 0 { ec_set_md(k, kind, ec_most_generic_align(jmd, kmd)); }
            continue;
        }
        if kind == EC_MD_NONTEMPORAL || kind == EC_MD_NOSANITIZE { ec_set_md(k, kind, jmd); continue; }
        if kind == EC_MD_MEM_CACHE_HINT || kind == EC_MD_ALLOC_TOKEN {
            if kmd != jmd { ec_set_md(k, kind, -1); }
            continue;
        }
        if kind == MDK_CAPTURES {
            if jmd != kmd { fatal("EarlyCSE: merging !captures (combineMetadataForCSE) is not ported yet"); }
            continue;
        }
        ec_set_md(k, kind, -1);       // unknown metadata
    }
    if inst_get_md(j, EC_MD_MMRA) >= 0 || inst_get_md(k, EC_MD_MMRA) >= 0 { fatal("EarlyCSE: MMRAMetadata::combine is not ported yet"); }
    if inst_get_md(j, EC_MD_MEMPROF) >= 0 || inst_get_md(k, EC_MD_MEMPROF) >= 0 { fatal("EarlyCSE: getMergedMemProfMetadata is not ported yet"); }
    if inst_get_md(j, EC_MD_CALLSITE) >= 0 || inst_get_md(k, EC_MD_CALLSITE) >= 0 { fatal("EarlyCSE: getMergedCallsiteMetadata is not ported yet"); }
    if inst_get_md(j, EC_MD_PROF) >= 0 || inst_get_md(k, EC_MD_PROF) >= 0 { fatal("EarlyCSE: getMergedProfMetadata is not ported yet"); }
}

// ---------------------------------------------------------------------------------------------
// GEPOperator::accumulateConstantOffset + APInt::trySExtValue: (ok, offset)

fn ec_gep_const_offset(g: i32) -> bool, i64 {
    let w = dl_ptr(ptr_as(vals[g].ty)).idx;
    if w > 64 { fatal("EarlyCSE: GEP offsets with an index width over 64 bits are not ported yet"); }
    let mask: u64 = if w == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << (w as u64)) - 1 };
    var off: u64 = 0;
    let src = insts[inst_of(g)].ty2;
    let n = nops(g);
    if ty_kind(src) == TK_INT && ty_bits(src) == 8 && n > 1 {
        let c = op(g, 1);
        if vals[c].kind == VK_CINT && ty_kind(vals[c].ty) == TK_INT {
            if ty_bits(vals[c].ty) > 64 { fatal("EarlyCSE: GEP indices wider than 64 bits are not ported yet"); }
            off = (ci_sval(c) as! u64) & mask;
            return true, sext64(off, w);
        }
        return false, 0;
    }
    var t = src;
    for k in 1..n {
        // GTI.getIndexedType(): the source type for the first index, then the type this index selects
        let x = op(g, k);
        var indexed = t;
        var stride: i64 = 0;
        var is_struct = false;
        if k == 1 {
            indexed = src;
            stride = dl_alloc_size(src);
        } else if ty_is_struct(t) {
            is_struct = true;
        } else {
            indexed = types[t].a;
            stride = dl_gep_stride(t, indexed);
        }
        let c = x;
        let is_ci = vals[c].kind == VK_CINT && ty_kind(vals[c].ty) == TK_INT;
        if !is_ci { return false, 0; }
        if ty_bits(vals[c].ty) > 64 { fatal("EarlyCSE: GEP indices wider than 64 bits are not ported yet"); }
        if is_struct {
            let fi = cint_lo(c) as! i64;
            indexed = ty_field(t, fi);
            if cint_is_zero(c) { t = indexed; continue; }
            if ty_contains_scalable(indexed) { return false, 0; }
            off = (off + (dl_struct_offset(t, fi) as! u64)) & mask;
            t = indexed;
            continue;
        }
        if cint_is_zero(c) { t = indexed; continue; }
        if ty_contains_scalable(indexed) { return false, 0; }
        let idx = (ci_sval(c) as! u64) & mask;
        off = (off + idx * ((stride as! u64) & mask)) & mask;
        t = indexed;
    }
    return true, sext64(off, w);
}

// ---------------------------------------------------------------------------------------------
// Memory generations

// isSameMemGeneration
fn ec_same_mem_generation(eg: u32, lg: u32, ei: i32, li: i32) -> bool {
    if eg == lg { return true; }
    if !ec_use_mssa { return false; }
    let ema = mssa_access_of(ei);
    if ema < 0 { return true; }
    let lma = mssa_access_of(li);
    if lma < 0 { return true; }
    var ldef: i32 = -1;
    if ec_clobber_counter < ec_mssa_cap {
        let q = aq_push(CA_SIMPLE);
        ldef = mssa_get_clobbering(lma, q);
        aq_pop(q);
        ec_clobber_counter++;
    } else {
        ldef = ma_def(lma);
    }
    return mssa_dominates(ldef, ema);
}

// isOperatingOnInvariantMemAt
fn ec_operating_on_invariant_mem_at(iv: i32, gen_at: u32) -> bool {
    if iop(iv) == OP_LOAD && inst_get_md(iv, MDK_INVARIANT_LOAD) >= 0 { return true; }
    let loc = ml_get_or_none(iv);
    if loc.ptr == ML_NONE { return false; }
    var k = ec_key(-1);
    k.ml = loc;
    let r = ec_lookup(ET_INVARIANTS, k);
    if r < 0 { return false; }
    return ec_vals[r].gen <= gen_at;
}

// getMatchingValue(InVal, MemInst, CurrentGeneration); InVal = value record r (-1 = default LoadValue)
fn ec_get_matching_value(r: i32, m: PMI, cur_gen: u32) -> i32 {
    if r < 0 { return -1; }
    let def = ec_vals[r].v;
    if def < 0 { return -1; }
    let in_gen = ec_vals[r].gen;
    if ec_is_memset(def) {
        if !pm_is_load(m) || pm_is_volatile(m) || !pm_is_unordered(m) || pm_matching_id(m) != -1 { return -1; }
        if !is_null_value(cb_arg(def, 3)) { return -1; }
        let val = cb_arg(def, 1);
        if vals[val].kind != VK_CINT || !cint_is_zero(val) { return -1; }
        let len = cb_arg(def, 2);
        if vals[len].kind != VK_CINT { return -1; }
        let it = pm_value_type(m);
        if it < 0 { return -1; }
        if ty_contains_scalable(it) { return -1; }
        let ls = dl_store_size(it);
        // APInt::ult(uint64_t)
        let lv = ap_from_cint(len);
        if ap_active_bits(lv) <= 64 && ap_lo64(lv) < (ls as! u64) { return -1; }
        if !ec_operating_on_invariant_mem_at(m.inst, in_gen) && !ec_same_mem_generation(in_gen, cur_gen, def, m.inst) { return -1; }
        return c_null(it);
    }
    if ec_vals[r].mid != pm_matching_id(m) { return -1; }
    if pm_is_volatile(m) || !pm_is_unordered(m) { return -1; }
    if pm_is_load(m) && !ec_vals[r].atomic && pm_is_atomic(m) { return -1; }
    let mem_inst_matching = !pm_is_load(m);
    let matching = if mem_inst_matching { m.inst } else { def };
    let other = if mem_inst_matching { def } else { m.inst };
    var result: i32 = -1;
    if pm_is_store(m) {
        result = ec_get_or_create_result(matching, vals[other].ty);
        if def != result { return -1; }
    }
    let mnti = ec_is_handled_non_target_intrinsic(matching);
    let onti = ec_is_handled_non_target_intrinsic(other);
    if onti != mnti { return -1; }
    if onti && mnti {
        if !ec_is_non_target_intrinsic_match(def, m.inst) { return -1; }
    }
    if !ec_operating_on_invariant_mem_at(m.inst, in_gen) && !ec_same_mem_generation(in_gen, cur_gen, def, m.inst) { return -1; }
    if result < 0 { result = ec_get_or_create_result(matching, vals[other].ty); }
    return result;
}

// overridingStores(Earlier, Later)
fn ec_overriding_stores(e: PMI, l: PMI) -> bool {
    if pm_ptr(e) != pm_ptr(l) { return false; }
    let et = pm_value_type(e);
    let lt = pm_value_type(l);
    if et < 0 || lt < 0 || et != lt { return false; }
    if pm_matching_id(e) != pm_matching_id(l) { return false; }
    if !pm_is_unordered(e) || !pm_is_unordered(l) { return false; }
    let enti = ec_is_handled_non_target_intrinsic(e.inst);
    let lnti = ec_is_handled_non_target_intrinsic(l.inst);
    if enti && lnti { return ec_is_non_target_intrinsic_match(e.inst, l.inst); }
    return enti == lnti;
}

// ---------------------------------------------------------------------------------------------
// processNode

fn ec_salvage_debug_info(iv: i32) { salvage_debug_info(iv); }

fn ec_handle_branch_condition(cond: i32, bi: i32, bb: i32, pred: i32) -> bool {
    let is_true = term_succ(bi, 0) == bb;
    let torf = if is_true { c_true() } else { c_false() };
    var changed = false;
    var wl: i32[>..<] = [];
    var visited: i32[>..<] = [];
    wl.push(cond);
    while wl.len > 0 {
        let cur = wl.pop();
        ec_insert(ET_VALUES, ec_key(cur), torf, 0, 0, false, false);
        if ec_replace_dominated_uses(cur, torf, pred, bb) > 0 { changed = true; }
        if m_logical(cur, is_true) {
            let l = lg_a;
            let r = lg_b;
            let both: i32[2] = [l, r];
            for x in both {
                if is_inst(x) && ec_simple_can_handle(x) {
                    var seen = false;
                    for y in visited { if y == x { seen = true; } }
                    if !seen { visited.push(x); wl.push(x); }
                }
            }
        }
    }
    return changed;
}

fn ec_process_node(bb: i32) -> bool {
    var changed = false;
    let pred = single_pred(bb);
    if pred < 0 { ec_gen++; }
    if pred >= 0 {
        let bi = block_terminator(pred);
        if bi >= 0 && iop(bi) == OP_CONDBR {
            let c = op(bi, 0);
            if is_inst(c) && ec_simple_can_handle(c) { if ec_handle_branch_condition(c, bi, bb, pred) { changed = true; } }
        }
    }
    var last_store: i32 = -1;
    var it = block_first(bb);
    while it >= 0 {
        let i = it;
        it = inst_next(it);
        if is_instruction_trivially_dead(i) {
            salvage_knowledge(i, true);
            ec_salvage_debug_info(i);
            ec_remove_mssa(i);
            ec_erase(i);
            changed = true;
            continue;
        }
        let id = inst_iid(i);
        if id == IID_assume {
            let ci = cb_arg(i, 0);
            if is_inst(ci) && ec_simple_can_handle(ci) { ec_insert(ET_VALUES, ec_key(ci), c_true(), 0, 0, false, false); }
            continue;
        }
        if id == IID_experimental_noalias_scope_decl || id == IID_sideeffect || id == IID_pseudoprobe { continue; }
        if id == IID_invariant_start {
            if vals[i].first_use >= 0 { continue; }
            var k = ec_key(-1);
            k.ml = ml_for_argument(i, 1, true);
            if ec_lookup(ET_INVARIANTS, k) < 0 { ec_insert(ET_INVARIANTS, k, -1, ec_gen, 0, false, false); }
            continue;
        }
        if id == IID_experimental_guard {
            let ci = cb_arg(i, 0);
            if is_inst(ci) && ec_simple_can_handle(ci) {
                let r = ec_lookup(ET_VALUES, ec_key(ci));
                if r >= 0 && ec_vals[r].v >= 0 {
                    let known = ec_vals[r].v;
                    if vals[known].kind == VK_CINT && is_one_value(known) {
                        salvage_knowledge(i, true);
                        ec_remove_mssa(i);
                        ec_erase(i);
                        changed = true;
                        continue;
                    }
                    set_op(i, 0, known);
                }
                ec_insert(ET_VALUES, ec_key(ci), c_true(), 0, 0, false, false);
            }
            last_store = -1;
            continue;
        }
        let v = simplify_instruction(i);
        if v >= 0 {
            var killed = false;
            if vals[i].first_use >= 0 { ec_rauw(i, v); changed = true; }
            if is_instruction_trivially_dead(i) {
                salvage_knowledge(i, true);
                ec_remove_mssa(i);
                ec_erase(i);
                changed = true;
                killed = true;
            }
            if killed { continue; }
        }
        if inst_may_throw(i) { last_store = -1; }
        if ec_simple_can_handle(i) {
            let r = ec_lookup(ET_VALUES, ec_key(i));
            if r >= 0 && ec_vals[r].v >= 0 {
                let av = ec_vals[r].v;
                ec_combine_ir_flags(i, av);
                ec_rauw(i, av);
                salvage_knowledge(i, true);
                ec_remove_mssa(i);
                ec_erase(i);
                changed = true;
                continue;
            }
            ec_insert(ET_VALUES, ec_key(i), i, 0, 0, false, false);
            continue;
        }
        let m = ec_parse_mem(i);
        if pm_valid(m) && pm_is_load(m) {
            if pm_is_volatile(m) || !pm_is_unordered(m) { last_store = -1; ec_gen++; }
            if pm_is_invariant_load(m) {
                var k = ec_key(-1);
                k.ml = ml_get(i);
                if ec_lookup(ET_INVARIANTS, k) < 0 { ec_insert(ET_INVARIANTS, k, -1, ec_gen, 0, false, false); }
            }
            let r = ec_lookup(ET_LOADS, ec_key(pm_ptr(m)));
            let opv = ec_get_matching_value(r, m, ec_gen);
            if opv >= 0 {
                if ec_vals[r].isload && is_inst(opv) { ec_combine_metadata_for_cse(opv, i); }
                if vals[i].first_use >= 0 { ec_rauw(i, opv); }
                salvage_knowledge(i, true);
                ec_remove_mssa(i);
                ec_erase(i);
                changed = true;
                continue;
            }
            ec_insert(ET_LOADS, ec_key(pm_ptr(m)), i, ec_gen, pm_matching_id(m), pm_is_atomic(m), pm_is_load(m));
            last_store = -1;
            continue;
        }
        if inst_may_read_memory(i) && !(pm_valid(m) && !pm_may_read(m)) { last_store = -1; }
        if ec_call_can_handle(i) && (!pm_valid(m) || !pm_is_store(m)) && !ec_is_memset(i) {
            let r = ec_lookup(ET_CALLS, ec_key(i));
            if r >= 0 && ec_vals[r].v >= 0 {
                let first = ec_vals[r].v;
                if ec_same_mem_generation(ec_vals[r].gen, ec_gen, first, i) && inst_may_read_memory(first) == inst_may_read_memory(i) {
                    ec_combine_ir_flags(i, first);
                    if vals[i].first_use >= 0 { ec_rauw(i, first); }
                    salvage_knowledge(i, true);
                    ec_remove_mssa(i);
                    ec_erase(i);
                    changed = true;
                    continue;
                }
            }
            if inst_may_write_memory(i) { ec_gen++; }
            ec_insert(ET_CALLS, ec_key(i), i, ec_gen, 0, false, false);
            continue;
        }
        if iop(i) == OP_GEP {
            let ok, off = ec_gep_const_offset(i);
            var k = ec_key(i);
            k.has_off = ok;
            k.off = off;
            let r = ec_lookup(ET_GEPS, k);
            if r >= 0 && ec_vals[r].v >= 0 {
                let gv = ec_vals[r].v;
                ec_combine_ir_flags(i, gv);
                ec_rauw(i, gv);
                salvage_knowledge(i, true);
                ec_remove_mssa(i);
                ec_erase(i);
                changed = true;
                continue;
            }
            ec_insert(ET_GEPS, k, i, 0, 0, false, false);
            continue;
        }
        if iop(i) == OP_FENCE && insts[inst_of(i)].ord == 5 { continue; }
        if pm_valid(m) && pm_is_store(m) {
            let r = ec_lookup(ET_LOADS, ec_key(pm_ptr(m)));
            if r >= 0 && ec_vals[r].v >= 0 && ec_vals[r].v == ec_get_matching_value(r, m, ec_gen) {
                salvage_knowledge(i, true);
                ec_remove_mssa(i);
                ec_erase(i);
                changed = true;
                continue;
            }
        }
        if inst_may_write_memory(i) {
            ec_gen++;
            if pm_valid(m) && pm_is_store(m) {
                if last_store >= 0 {
                    if ec_overriding_stores(ec_parse_mem(last_store), m) {
                        salvage_knowledge(i, true);      // sic: LLVM salvages the later store's knowledge
                        ec_remove_mssa(last_store);
                        ec_erase(last_store);
                        changed = true;
                        last_store = -1;
                    }
                }
                ec_insert(ET_LOADS, ec_key(pm_ptr(m)), i, ec_gen, pm_matching_id(m), pm_is_atomic(m), pm_is_load(m));
                if pm_is_unordered(m) && !pm_is_volatile(m) { last_store = i; } else { last_store = -1; }
            }
        }
    }
    return changed;
}

// ---------------------------------------------------------------------------------------------
// run

struct ENode { cur_gen: u32, child_gen: u32, node: i32, child: i32, processed: bool, saved_last: i32 }

fn early_cse_run(fv: i32, use_mssa: bool) -> u32 {
    tli_cur_fn = fv;
    local_have_tli = true;
    ec_fn = fv;
    dt_get(fv, DT_DOM);
    vt_invalidate_assumes();
    ac_invalidate();
    ec_use_mssa = use_mssa;
    if use_mssa {
        mssa_get(fv);
        msu_reset();
    }
    ec_mssa_cap = flag_int("earlycse-mssa-optimization-cap", 500);
    ec_clobber_counter = 0;
    ec_gen = 0;
    ec_tables_reset();
    m2r_collect_records(fv);
    var changed = false;
    var stk: ENode[>..<] = [];
    let root = dt_root(fv, DT_DOM);
    stk.push(ENode { cur_gen: ec_gen, child_gen: ec_gen, node: root, child: dt_first_child(fv, DT_DOM, root),
                     processed: false, saved_last: ec_scope_last });
    ec_scope_last = -1;
    while stk.len > 0 {
        let t = stk.len - 1;
        ec_gen = stk[t].cur_gen;
        if !stk[t].processed {
            if ec_process_node(stk[t].node) { changed = true; }
            stk[t].child_gen = ec_gen;
            stk[t].processed = true;
        } else if stk[t].child >= 0 {
            let c = stk[t].child;
            stk[t].child = dt_next_sibling(DT_DOM, c);
            let g = stk[t].child_gen;
            stk.push(ENode { cur_gen: g, child_gen: g, node: c, child: dt_first_child(fv, DT_DOM, c),
                             processed: false, saved_last: ec_scope_last });
            ec_scope_last = -1;
        } else {
            ec_scope_pop(stk[t].saved_last);
            stk.pop();
        }
    }
    ec_tables_reset();
    if !changed { return PA_ALL; }
    if use_mssa { return PA_CFG | ((1 as u32) << A_MEMORYSSA); }
    return PA_CFG;
}
