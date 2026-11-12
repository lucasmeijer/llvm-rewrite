// LoopIdiomRecognize: port of llvm/lib/Transforms/Scalar/LoopIdiomRecognize.cpp (whole: memset / memset.pattern
// / memcpy / memmove from strided stores and mem intrinsics, the CRC table rewrite (hash_recognize.goose),
// strlen / wcslen, popcount, ctlz / cttz (shift until zero / less than), shift-until-bittest, shift-until-zero).
// Also AAMDNodes::extendTo / extendToTBAA (llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp, Metadata.h),
// SimpleLoopSafetyInfo::computeLoopSafetyInfo (llvm/lib/Analysis/MustExecute.cpp), isMustProgress
// (llvm/lib/Transforms/Utils/LoopUtils.cpp), emitStrLen / emitWcsLen (llvm/lib/Transforms/Utils/BuildLibCalls.cpp).
// The pass's members are the lir_* globals; the IRBuilder<> (ConstantFolder) is lrb_*.
import std;
import ir;
import irutil;
import instinfo;
import calls;
import analyses;
import flags;
import gen_iids;
import gen_attrs;
import gen_tli;
import autoupgrade;
import constfold;
import cfold;
import datalayout;
import pm;
import vt;
import poison;
import knownbits;
import apint;
import crange;
import constrange;
import domtree;
import loopinfo;
import memloc;
import aa;
import tbaa;
import memoryssa;
import mssaupdater;
import memintr;
import tli;
import build_libcalls;
import simplify_libcalls;
import local;
import tti;
import tti_x86;
import cfgutil;
import profdata;
import licm;
import indvars;
import wvh;
import scev;
import scev_create;
import scev_btc;
import scev_eval;
import scev_range;
import scev_pred;
import scev_guards;
import scev_update;
import scev_expander;
import constraint_elimination;
import laa;
import hash_recognize;
import loop_utils;
import dinfo;
import loopsimplify;
import ic;

fn lir_not_ported(what: const u8[:]) { fatal(str("LoopIdiomRecognize: ", what, " is not ported yet")); }

var lir_l: i32 = -1;
var lir_fv: i32 = -1;
var lir_mssau: bool = false;
var lir_code_size: bool = false;
var lir_has_memset: bool = false;
var lir_has_memset_pattern: bool = false;
var lir_has_memcpy: bool = false;
var lir_force_pattern: bool = false;
var lir_dis_memset: bool = false;
var lir_dis_memcpy: bool = false;
var lir_dis_strlen: bool = false;
var lir_dis_wcslen: bool = false;
var lir_dis_hash: bool = false;

// ---------------------------------------------------------------------------------------------
// IRBuilder<> with the ConstantFolder

var lrb_bb: i32 = -1;
var lrb_pos: i32 = -1;      // insert before this instruction (-1 = at the end of lrb_bb)
var lrb_head: bool = false;
var lrb_dl: i32 = -1;

// IRBuilder(I) / SetInsertPoint(I)
fn lrb_set_before(i: i32) { lrb_bb = inst_parent(i); lrb_pos = i; lrb_head = false; lrb_dl = inst_get_md(i, 0); }
// SetInsertPoint(BB, It) with an iterator that has the head bit (begin(), getFirstNonPHIIt())
fn lrb_set_head(bb: i32, i: i32) {
    lrb_bb = bb; lrb_pos = i; lrb_head = true;
    if i >= 0 { lrb_dl = inst_get_md(i, 0); }
}
fn lrb_insert(iv: i32, name: const u8[:]) -> i32 {
    if lrb_pos >= 0 {
        if lrb_head { inst_insert_before_head(iv, lrb_pos); } else { inst_insert_before(iv, lrb_pos); }
    } else { block_append_inst(lrb_bb, iv); }
    if lrb_dl >= 0 { inst_set_md(iv, 0, lrb_dl); }
    if name.len > 0 && vals[iv].ty != T_VOID { set_name(iv, name); }
    return iv;
}
fn lrb_binop(o: i64, a: i32, b: i32, name: const u8[:], nuw: bool, nsw: bool) -> i32 {
    var fl: u8 = 0;
    if nuw { fl |= FL_NUW; }
    if nsw { fl |= FL_NSW; }
    if is_constant(a) && is_constant(b) { return ce_binop(o, a, b, fl); }
    let i = create_inst(o, vals[a].ty, [a, b]);
    insts[inst_of(i)].flags = fl;
    return lrb_insert(i, name);
}
fn lrb_cast(o: i64, v: i32, t: i32, name: const u8[:]) -> i32 {
    if vals[v].ty == t { return v; }
    if is_constant(v) { return ce_cast(o, v, t); }
    return lrb_insert(create_inst(o, t, [v]), name);
}
// CreateZExtOrTrunc
fn lrb_zext_or_trunc(v: i32, t: i32, name: const u8[:]) -> i32 {
    let vb = ty_bits(vals[v].ty);
    let tb = ty_bits(t);
    if vb < tb { return lrb_cast(OP_ZEXT, v, t, name); }
    if vb > tb { return lrb_cast(OP_TRUNC, v, t, name); }
    return v;
}
fn lrb_icmp(p: i64, a: i32, b: i32, name: const u8[:]) -> i32 {
    if is_constant(a) && is_constant(b) {
        let f = cf_compare(p, a, b);
        if f >= 0 { return f; }
    }
    let c = create_inst(OP_ICMP, T_I1, [a, b]);
    insts[inst_of(c)].pred = p as u8;
    return lrb_insert(c, name);
}
// CreateIntrinsic(ID, Types, Args, FMFSource = nullptr, Name): no folding
fn lrb_intrinsic(id: i64, ov: const i32[:], argsv: const i32[:], name: const u8[:]) -> i32 {
    let f = au_get_declaration(id, ov);
    let fty = globs[glob_of(f)].vty;
    var opsv: i32[>..<] = [];
    for a in argsv { opsv.push(a); }
    opsv.push(f);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), opsv);
    insts[inst_of(c)].ty2 = fty;
    return lrb_insert(c, name);
}
fn lrb_align_set(al: u64) -> i32 { if al == 0 { 0 } else { aset_get([attr_int(AK_Alignment, al)]) } }
fn lrb_set_param_aligns(c: i32, a0: u64, a1: u64) {
    if a0 == 0 && a1 == 0 { return; }
    var sets: i32[>..<] = [];
    sets.push(0);
    sets.push(0);
    sets.push(lrb_align_set(a0));
    if a1 != 0 { sets.push(lrb_align_set(a1)); }
    insts[inst_of(c)].attrs = alist_get(sets);
}

// Instruction::setAAMetadata
fn lir_set_aa(i: i32, t: ML) {
    cu_set_md(i, MDK_TBAA, t.tbaa);
    cu_set_md(i, MDK_TBAA_STRUCT, t.tbaa_struct);
    cu_set_md(i, MDK_ALIAS_SCOPE, t.scope);
    cu_set_md(i, MDK_NOALIAS, t.noalias);
    cu_set_md(i, MDK_NOALIAS_ADDRSPACE, t.noalias_as);
}
// AAMDNodes::extendToTBAA(MD, Len)
fn lir_extend_to_tbaa(md: i32, len: i64) -> i32 {
    if len == 0 { return -1; }
    // isStructPathTBAA
    if !(mds[md].nops >= 3 && md_op(md, 0) >= 0 && md_is_node(md_op(md, 0))) { return md; }
    let at = md_op(md, 1);
    if at < 0 || !tb_is_new_format_type(at) { return md; }
    if len == -1 { return -1; }
    let szm = md_op(md, 3);
    let pc = mds[szm].extra;
    if lir_u64_eq_ap(len as u64, ci_ap(pc)) { return md; }
    var ops: i32[>..<] = [];
    for k in mds[md].nops as i64 { ops.push(md_op(md, k)); }
    ops[3] = md_value(c_int(vals[pc].ty, len));
    return md_get(MK_TUPLE, -1, ops, false);
}
// AAMDNodes::extendTo(Len)
fn lir_extend_to(t: ML, len: i64) -> ML {
    var r = ml_null();
    r.tbaa = if t.tbaa >= 0 { lir_extend_to_tbaa(t.tbaa, len) } else { -1 };
    r.tbaa_struct = -1;
    r.scope = t.scope;
    r.noalias = t.noalias;
    r.noalias_as = t.noalias_as;
    return r;
}

// ---------------------------------------------------------------------------------------------
// Small helpers

fn lir_store_val(si: i32) -> i32 { op(si, 0) }
fn lir_store_ptr(si: i32) -> i32 { op(si, 1) }
fn lir_align(i: i32) -> u64 { let a = insts[inst_of(i)].align; return if a == 0 { 0 } else { (1 as u64) << ((a - 1) as u64) }; }
// Loop::isLoopInvariant(V)
fn lir_loop_invariant(v: i32) -> bool { !is_inst(v) || !loop_contains(lir_l, inst_parent(v)) }
fn lir_is_inst_op(v: i32, o: i64) -> bool { is_inst(v) && iop(v) == o }
// SCEV pattern m_scev_AffineAddRec(_, _, m_SpecificLoop(L))
fn lir_affine_addrec_of(s: i32, l: i32) -> bool { sc_kind(s) == SC_ADDREC && sc_is_affine(s) && (l < 0 || sc_loop(s) == l) }
fn lir_phi_in(p: i32, bb: i32) -> i32 { let k = phi_block_index(p, bb); if k < 0 { -1 } else { phi_value(p, k) } }
// getUniqueExitBlocks
fn lir_unique_exit_blocks(l: i32, out: i32[>..<]&) {
    out.clear();
    var ex: i32[>..<] = [];
    loop_exit_blocks(l, ex);
    for e in ex { cu_push_unique(out, e); }
}
// Loop::getExitBlock: the single exit block (no repeats from different exiting edges counted as different)
fn lir_exit_block(l: i32) -> i32 {
    var r: i32 = -1;
    for i in loop_nblocks(l) {
        let bb = loop_block(l, i);
        for k in block_nsucc(bb) {
            let s = block_succ(bb, k);
            if loop_contains(l, s) { continue; }
            if r >= 0 { return -1; }
            r = s;
        }
    }
    return r;
}
fn lir_block_size(bb: i32) -> i64 { var n: i64 = 0; var i = block_first(bb); while i >= 0 { n++; i = inst_next(i); } return n; }
fn lir_single_pred(bb: i32) -> i32 { single_pred(bb) }
fn lir_name_plus(v: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    if vals[v].name >= 0 { nm.append(val_name(v)); }
    nm.append(suffix);
    return nm;
}
// Twine(L->getName()) + suffix
fn lir_loop_name_plus(l: i32, suffix: const u8[:]) -> u8[>..] {
    var nm: u8[>..] = [];
    nm.append(loop_name(l));
    nm.append(suffix);
    return nm;
}
fn lir_one_use(v: i32) -> bool { let u = vals[v].first_use; return u >= 0 && uses[u].next < 0; }
// deleteDeadInstruction
fn lir_delete_dead_instruction(i: i32) {
    if vals[i].first_use >= 0 { rauw(i, c_poison(vals[i].ty)); }
    inst_erase_from_parent(i);
}
// Value::replaceUsesOutsideBlock(New, BB)
fn lir_replace_uses_outside_block(v: i32, nv: i32, bb: i32) {
    lir_replace_dbg_uses_outside_block(v, nv, bb);
    var u = vals[v].first_use;
    while u >= 0 {
        let nx = uses[u].next;
        let us = uses[u].user;
        if !is_inst(us) { lir_not_ported("replaceUsesOutsideBlock with a constant user"); }
        if inst_parent(us) != bb { use_set(u, nv); }
        u = nx;
    }
}
// replaceDbgUsesOutsideBlock(V, New, BB): runs before the uses are replaced
fn lir_replace_dbg_uses_outside_block(v: i32, nv: i32, bb: i32) {
    if dbgrecs.len == 0 || !val_used_by_md(v) { return; }
    var recs: i32[>..<] = [];
    find_dbg_users(v, recs);
    for r in recs {
        let o = dbgrecs[r].owner;
        let rb = if o <= -2 { -2 - o } else { inst_parent(o) };
        if rb == bb { continue; }
        // DbgVariableRecord::replaceVariableLocationOp(V, New)
        var ops: i32[>..<] = [];
        dbg_location_ops(r, ops);
        var k: i64 = -1;
        for j in ops.len { if ops[j] == v { k = j; break; } }
        if k < 0 { lir_not_ported("replaceVariableLocationOp of a value that is only a dbg_assign address"); }
        let l = dbgrecs[r].loc;
        if mds[l].kind != MK_DIARGLIST { dbg_set_loc(r, md_value(nv)); continue; }
        var nops_: i32[>..<] = [];
        for j in mds[l].nops as i64 {
            let m = md_op(l, j);
            nops_.push(if m >= 0 && mds[m].kind == MK_VALUE && mds[m].extra == v { md_value(nv) } else { m });
        }
        dbg_set_loc(r, md_get(MK_DIARGLIST, -1, nops_, false));
    }
}
fn loop_name_of(l: i32) -> const u8[:] { loop_name(l) }

// isMustProgress(L)
fn lir_is_must_progress(l: i32) -> bool {
    return func_has_fn_attr(lir_fv, AK_MustProgress) || func_has_fn_attr(lir_fv, AK_WillReturn) || lu_has_must_progress(l);
}

// SimpleLoopSafetyInfo::computeLoopSafetyInfo + anyBlockMayThrow
fn lir_any_block_may_throw(l: i32) -> bool {
    for k in loop_nblocks(l) {
        let bb = loop_block(l, k);
        var i = block_first(bb);
        while i >= 0 { if !guaranteed_to_transfer(i) { return true; } i = inst_next(i); }
    }
    // (computeBlockColors only matters for MustExecute queries, which this pass makes none of)
    return false;
}

// TTI::getPopcntSupport(32) == PSK_FastHardware
fn lir_popcnt_fast() -> bool { tti_kind == TTI_X86 && x86_has(X86F_FeaturePOPCNT) }
// TTI::getAtomicMemIntrinsicMaxElementSize
fn lir_atomic_mem_max() -> i64 { if tti_kind == TTI_X86 { 16 } else { 0 } }

// ---------------------------------------------------------------------------------------------
// Countable loops

// getMemSetPatternValue(V, DL)
fn lir_memset_pattern_value(v: i32) -> i32 {
    if !is_constant(v) || is_cexpr(v) { return -1; }
    let t: i32 = vals[v].ty;
    if ty_size_scalable(t) { return -1; }
    let size = dl_size_bits(t);
    if size == 0 || (size & 7) != 0 || (size & (size - 1)) != 0 { return -1; }
    if dl_big_endian { return -1; }
    if size / 8 > 16 { return -1; }
    if !(ty_is_int(t) || ty_kind(t) == TK_PTR || ty_is_fp(t)) { return -1; }
    return v;
}

let LSK_NONE = 0;
let LSK_MEMSET = 1;
let LSK_MEMSET_PATTERN = 2;
let LSK_MEMCPY = 3;
let LSK_UNORDERED_ATOMIC_MEMCPY = 4;

fn lir_is_legal_store(si: i32) -> i64 {
    if inst_is_volatile(si) { return LSK_NONE; }
    if !ldst_is_unordered(si) { return LSK_NONE; }
    if inst_get_md(si, md_kind_id("nontemporal")) >= 0 { return LSK_NONE; }
    let sv = lir_store_val(si);
    let sp = lir_store_ptr(si);
    let svt: i32 = vals[sv].ty;
    if ty_kind(svt) == TK_PTR && dl_has_unstable_repr(ty_bits(svt)) { return LSK_NONE; }
    if ty_is_vector(svt) && ty_kind(ty_elem(svt)) == TK_PTR && dl_has_unstable_repr(ty_bits(ty_elem(svt))) { return LSK_NONE; }
    var ext_state = false;
    if ty_kind(svt) == TK_PTR && dl_has_external_state(ty_bits(svt)) { ext_state = true; }
    if ty_is_vector(svt) && ty_kind(ty_elem(svt)) == TK_PTR && dl_has_external_state(ty_bits(ty_elem(svt))) { ext_state = true; }
    let must_preserve = ext_state && vals[sv].kind != VK_CNULL;
    if ty_size_scalable(svt) { return LSK_NONE; }
    let sib = dl_size_bits(svt);
    if (sib & 7) != 0 || (sib >> 32) != 0 { return LSK_NONE; }
    let sev = sc_get_scev(sp);
    if !lir_affine_addrec_of(sev, lir_l) || !sc_is_const(sc_op(sev, 1)) { return LSK_NONE; }
    let stride = sc_op(sev, 1);
    let splat = is_bytewise_value(sv);
    let unordered_atomic = ldst_is_unordered(si) && insts[inst_of(si)].ord != 0;
    if !must_preserve && !unordered_atomic && lir_has_memset && splat >= 0 && !lir_dis_memset && lir_loop_invariant(splat) {
        return LSK_MEMSET;
    }
    if !must_preserve && !unordered_atomic && (lir_has_memset_pattern || lir_force_pattern) && !lir_dis_memset &&
       ty_bits(vals[sp].ty) == 0 && lir_memset_pattern_value(sv) >= 0 {
        return LSK_MEMSET_PATTERN;
    }
    if lir_has_memcpy && !lir_dis_memcpy {
        let ss = dl_store_size(svt) as u64;
        let sa = sc_ap(stride);
        if !lir_u64_eq_ap(ss, sa) && !lir_u64_eq_ap(ss, ap_neg(sa)) { return LSK_NONE; }
        let li = sv;
        if !lir_is_inst_op(li, OP_LOAD) || inst_is_volatile(li) { return LSK_NONE; }
        if !ldst_is_unordered(li) { return LSK_NONE; }
        let lev = sc_get_scev(op(li, 0));
        if !lir_affine_addrec_of(lev, lir_l) || sc_op(lev, 1) != stride { return LSK_NONE; }
        let ua = unordered_atomic || insts[inst_of(li)].ord != 0;
        return if ua { LSK_UNORDERED_ATOMIC_MEMCPY } else { LSK_MEMCPY };
    }
    return LSK_NONE;
}

// StoreRefsForMemset / StoreRefsForMemsetPattern (MapVector<Value *, StoreList>) and StoreRefsForMemcpy
var lir_ms_keys: i32[>..<];
var lir_ms_key_of: i32[>..<];     // per collected store: index of its key
var lir_ms_stores: i32[>..<];
var lir_mp_keys: i32[>..<];
var lir_mp_key_of: i32[>..<];
var lir_mp_stores: i32[>..<];
var lir_mc_stores: i32[>..<];

fn lir_key_index(keys: i32[>..<]&, k: i32) -> i32 {
    for j in keys.len { if keys[j] == k { return j as i32; } }
    keys.push(k);
    return (keys.len - 1) as i32;
}

fn lir_collect_stores(bb: i32) {
    lir_ms_keys.clear(); lir_ms_key_of.clear(); lir_ms_stores.clear();
    lir_mp_keys.clear(); lir_mp_key_of.clear(); lir_mp_stores.clear();
    lir_mc_stores.clear();
    var i = block_first(bb);
    while i >= 0 {
        if iop(i) == OP_STORE {
            let k = lir_is_legal_store(i);
            if k == LSK_MEMSET {
                let p = get_underlying_object(lir_store_ptr(i), 10);
                lir_ms_key_of.push(lir_key_index(lir_ms_keys, p));
                lir_ms_stores.push(i);
            } else if k == LSK_MEMSET_PATTERN {
                let p = get_underlying_object(lir_store_ptr(i), 10);
                lir_mp_key_of.push(lir_key_index(lir_mp_keys, p));
                lir_mp_stores.push(i);
            } else if k == LSK_MEMCPY || k == LSK_UNORDERED_ATOMIC_MEMCPY {
                lir_mc_stores.push(i);
            }
        }
        i = inst_next(i);
    }
}

// runOnLoopBlock
fn lir_run_on_loop_block(bb: i32, becount: i32, exits: const i32[:]) -> bool {
    for e in exits { if !dt_dominates_block(DT_DOM, bb, e) { return false; } }
    var changed = false;
    lir_collect_stores(bb);
    var ms_keys: i32[>..<] = [];
    var ms_key_of: i32[>..<] = [];
    var ms_stores: i32[>..<] = [];
    var mp_keys: i32[>..<] = [];
    var mp_key_of: i32[>..<] = [];
    var mp_stores: i32[>..<] = [];
    var mc_stores: i32[>..<] = [];
    for x in lir_ms_keys { ms_keys.push(x); }
    for x in lir_ms_key_of { ms_key_of.push(x); }
    for x in lir_ms_stores { ms_stores.push(x); }
    for x in lir_mp_keys { mp_keys.push(x); }
    for x in lir_mp_key_of { mp_key_of.push(x); }
    for x in lir_mp_stores { mp_stores.push(x); }
    for x in lir_mc_stores { mc_stores.push(x); }
    for k in ms_keys.len {
        var sl: i32[>..<] = [];
        for j in ms_stores.len { if ms_key_of[j] == k as i32 { sl.push(ms_stores[j]); } }
        if lir_process_loop_stores(sl, becount, true) { changed = true; }
    }
    for k in mp_keys.len {
        var sl: i32[>..<] = [];
        for j in mp_stores.len { if mp_key_of[j] == k as i32 { sl.push(mp_stores[j]); } }
        if lir_process_loop_stores(sl, becount, false) { changed = true; }
    }
    for si in mc_stores { if lir_process_loop_store_of_loop_load_si(si, becount) { changed = true; } }
    if lir_process_loop_mem_intrinsic(bb, becount, false) { changed = true; }
    if lir_process_loop_mem_intrinsic(bb, becount, true) { changed = true; }
    return changed;
}

// getStoreStride
fn lir_store_stride(sev: i32) -> AP { sc_ap(sc_op(sev, 1)) }

// processLoopStores(SL, BECount, For)
fn lir_process_loop_stores(sl: const i32[:], becount: i32, for_memset: bool) -> bool {
    let n = sl.len;
    var heads: i32[>..<] = [];
    var tails: i32[>..<] = [];
    var chain_from: i32[>..<] = [];
    var chain_to: i32[>..<] = [];
    for i in n {
        let fv0 = lir_store_val(sl[i]);
        let fp = lir_store_ptr(sl[i]);
        let fev = sc_get_scev(fp);
        let fstride = lir_store_stride(fev);
        let fsize = dl_store_size(vals[fv0].ty) as u64;
        if lir_u64_eq_ap(fsize, fstride) || lir_u64_eq_ap(fsize, ap_neg(fstride)) {
            cu_push_unique(heads, sl[i]);
            continue;
        }
        var fsplat: i32 = -1;
        var fpat: i32 = -1;
        if for_memset { fsplat = is_bytewise_value(fv0); } else { fpat = lir_memset_pattern_value(fv0); }
        var q: i64[>..<] = [];
        for j in i + 1..n { q.push(j); }
        var j = i;
        while j > 0 { q.push(j - 1); j--; }
        for k in q {
            let sp2 = lir_store_ptr(sl[k]);
            let sev2 = sc_get_scev(sp2);
            let s2 = lir_store_stride(sev2);
            if !ap_eq(fstride, s2) { continue; }
            let sv2 = lir_store_val(sl[k]);
            var ssplat: i32 = -1;
            var spat: i32 = -1;
            if for_memset { ssplat = is_bytewise_value(sv2); } else { spat = lir_memset_pattern_value(sv2); }
            if laa_is_consecutive_access(sl[i], sl[k], false) {
                if for_memset {
                    if is_undef_or_poison(fsplat) { fsplat = ssplat; }
                    if fsplat != ssplat { continue; }
                } else {
                    if is_undef_or_poison(fpat) { fpat = spat; }
                    if fpat != spat { continue; }
                }
                cu_push_unique(tails, sl[k]);
                cu_push_unique(heads, sl[i]);
                var found = false;
                for c in chain_from.len { if chain_from[c] == sl[i] { chain_to[c] = sl[k]; found = true; } }
                if !found { chain_from.push(sl[i]); chain_to.push(sl[k]); }
                break;
            }
        }
    }
    var transformed: i32[>..<] = [];
    var changed = false;
    for h in heads {
        if position(tails, h) >= 0 { continue; }
        var adjacent: i32[>..<] = [];
        let head_store = h;
        var store_size: i64 = 0;
        var i = h;
        while i >= 0 && (position(tails, i) >= 0 || position(heads, i) >= 0) {
            if position(transformed, i) >= 0 { break; }
            cu_push_unique(adjacent, i);
            store_size += dl_store_size(vals[lir_store_val(i)].ty);
            var nx: i32 = -1;
            for c in chain_from.len { if chain_from[c] == i { nx = chain_to[c]; } }
            i = nx;
        }
        let sv = lir_store_val(head_store);
        let sp = lir_store_ptr(head_store);
        let sev = sc_get_scev(sp);
        let stride = lir_store_stride(sev);
        // StoreSize != Stride && StoreSize != -Stride (APInt == uint64_t)
        let ssu = (store_size as u64) & 0xFFFFFFFF;
        if !lir_u64_eq_ap(ssu, stride) && !lir_u64_eq_ap(ssu, ap_neg(stride)) { continue; }
        let neg = lir_u64_eq_ap(ssu, ap_neg(stride));
        let idx_ty = sc_effective_ty(vals[sp].ty);
        let ssc = sc_get_constant_ty(idx_ty, store_size as u64, false);
        if adjacent.len > 8 { lir_not_ported("chains of more than 8 adjacent stores (SmallPtrSet iteration order)"); }
        if lir_process_loop_strided_store(sp, ssc, lir_align(head_store), sv, head_store, adjacent, sev, becount, neg, false) {
            for a in adjacent { cu_push_unique(transformed, a); }
            changed = true;
        }
    }
    return changed;
}


// processLoopMemIntrinsic<MemCpyInst / MemSetInst>
fn lir_process_loop_mem_intrinsic(bb: i32, becount: i32, is_memset: bool) -> bool {
    var changed = false;
    var i = block_first(bb);
    while i >= 0 {
        let inst = i;
        i = inst_next(i);
        let id = inst_iid(inst);
        let match_ = if is_memset { id == IID_memset || id == IID_memset_inline } else { id == IID_memcpy || id == IID_memcpy_inline };
        if !match_ { continue; }
        let mark = wvh_mark();
        let h = if i >= 0 { wvh_new(i, WVH_WEAK_TRACKING) } else { -1 };
        let ok = if is_memset { lir_process_loop_memset(inst, becount) } else { lir_process_loop_memcpy(inst, becount) };
        let nxt_dead = h >= 0 && wvh_get(h) < 0;
        wvh_release(mark);
        if !ok { continue; }
        changed = true;
        if nxt_dead { i = block_first(bb); }
    }
    return changed;
}

// processLoopMemCpy
fn lir_process_loop_memcpy(mci: i32, becount: i32) -> bool {
    if mi_is_volatile(mci) || !is_cint(mi_length(mci)) { return false; }
    let inl = inst_iid(mci) == IID_memcpy_inline;
    if (!lir_has_memcpy && !inl) || lir_dis_memcpy { return false; }
    let dest = mi_dest(mci);
    let src = mi_source(mci);
    let sev = sc_get_scev(dest);
    let lev = sc_get_scev(src);
    if !lir_affine_addrec_of(sev, lir_l) || !sc_is_const(sc_op(sev, 1)) { return false; }
    if !lir_affine_addrec_of(lev, lir_l) || !sc_is_const(sc_op(lev, 1)) { return false; }
    let len = mi_length(mci);
    if ty_bits(vals[len].ty) > 64 { lir_not_ported("memcpy lengths wider than 64 bits"); }
    let size = ap_zext64(ci_ap(len));
    if (size >> 32) != 0 { return false; }
    let ssv = sc_ap(sc_op(sev, 1));
    let lsv = sc_ap(sc_op(lev, 1));
    if ssv.w > 64 || lsv.w > 64 { return false; }
    if !lir_u64_eq_ap(size, ssv) && !lir_u64_eq_ap(size, ap_neg(ssv)) { return false; }
    if ap_sext64(ssv) != ap_sext64(lsv) { return false; }
    return lir_process_loop_store_of_loop_load(dest, src, sc_get_constant_ty(vals[dest].ty, size, false), mi_dest_align(mci),
        mi_source_align(mci), mci, mci, sev, lev, becount);
}
// uint64_t == APInt: the APInt must fit in 64 bits and equal the value
fn lir_u64_eq_ap(x: u64, a: AP) -> bool { ap_active_bits(a) <= 64 && ap_zext64(a) == x }

// processLoopMemSet
fn lir_process_loop_memset(msi: i32, becount: i32) -> bool {
    if mi_is_volatile(msi) { return false; }
    if !lir_has_memset || lir_dis_memset { return false; }
    let p = mi_dest(msi);
    let ev = sc_get_scev(p);
    if !lir_affine_addrec_of(ev, lir_l) { return false; }
    let pstride = sc_op(ev, 1);
    let msize = sc_get_scev(mi_length(msi));
    var neg = false;
    let len = mi_length(msi);
    if is_cint(len) {
        if ty_bits(vals[len].ty) > 64 { lir_not_ported("memset lengths wider than 64 bits"); }
        let size = ap_zext64(ci_ap(len));
        if !sc_is_const(pstride) { return false; }
        let st = sc_ap(pstride);
        if !lir_u64_eq_ap(size, st) && !lir_u64_eq_ap(size, ap_neg(st)) { return false; }
        neg = lir_u64_eq_ap(size, ap_neg(st));
    } else {
        if ty_bits(vals[p].ty) != 0 { return false; }
        if !sc_is_loop_invariant(msize, lir_l) { return false; }
        neg = sx_non_constant_negative(pstride);
        let pos = if neg { sc_get_negative(pstride, SF_ANY) } else { pstride };
        if pos != msize {
            let fp = sc_apply_loop_guards(pos, lir_l);
            let fm = sc_apply_loop_guards(msize, lir_l);
            if fp != fm { return false; }
        }
    }
    let splat = mi_value(msi);
    if splat < 0 || !lir_loop_invariant(splat) { return false; }
    let one: i32[1] = [msi];
    return lir_process_loop_strided_store(p, sc_get_scev(mi_length(msi)), mi_dest_align(msi), splat, msi, one, ev, becount, neg, true);
}

// isSameByteValueStore
fn lir_is_same_byte_value_store(i: i32, splat: i32) -> bool {
    if iop(i) != OP_STORE || inst_is_volatile(i) || insts[inst_of(i)].ord != 0 || !lir_loop_invariant(lir_store_val(i)) { return false; }
    return is_bytewise_value(lir_store_val(i)) == splat;
}

// mayLoopAccessLocation
fn lir_may_loop_access_location(p: i32, access: i64, becount: i32, ssc: i32, ignored: const i32[:], splat: i32, use_dl: bool) -> bool {
    var asize = LS_AFTER;
    if sc_is_const(becount) && sc_is_const(ssc) {
        let be = sc_ap(becount);
        let cs = sc_ap(ssc);
        if ap_active_bits(be) <= 64 && ap_active_bits(cs) <= 64 {
            asize = ls_precise((ap_zext64(be) + 1) * ap_zext64(cs));
        }
    }
    let loc = ml_make(p, asize);
    let try_same = !ls_is_precise(asize) && splat >= 0 && use_dl;
    for k in loop_nblocks(lir_l) {
        var i = block_first(loop_block(lir_l, k));
        while i >= 0 {
            if position(ignored, i) < 0 && (aa_inst_loc_mr_simple(i, loc) & access) != 0 {
                if !(try_same && lir_is_same_byte_value_store(i, splat)) { return true; }
            }
            i = inst_next(i);
        }
    }
    return false;
}

// getStartForNegStride
fn lir_start_for_neg_stride(start: i32, becount: i32, ip: i32, ssc: i32) -> i32 {
    var index = sc_get_truncate_or_zero_extend(becount, ip, 0);
    if !sc_is_one(ssc) { index = sc_mul2(index, sc_get_truncate_or_zero_extend(ssc, ip, 0), SF_NUW, 0); }
    return sc_minus(start, index);
}
// getNumBytes
fn lir_num_bytes(becount: i32, ip: i32, ssc: i32) -> i32 {
    let tc = sc_trip_count_from_exit_count_ty(becount, ip, lir_l);
    return sc_mul2(tc, sc_get_truncate_or_zero_extend(ssc, ip, 0), SF_NUW, 0);
}

// processLoopStridedStore: the expander's lifetime (SCEVExpanderCleaner) wraps the body
fn lir_process_loop_strided_store(dest: i32, ssc: i32, salign: u64, sval: i32, the_store: i32, stores: const i32[:],
                                  ev: i32, becount: i32, neg: bool, is_loop_memset: bool) -> bool {
    sx_begin("loop-idiom", true);
    let changed, used = lir_strided_store_impl(dest, ssc, salign, sval, the_store, stores, ev, becount, neg, is_loop_memset);
    if !used { sx_cleanup(); }
    sx_end();
    return changed;
}
fn lir_strided_store_impl(dest: i32, ssc: i32, salign: u64, sval: i32, the_store: i32, stores: const i32[:],
                          ev: i32, becount: i32, neg: bool, is_loop_memset: bool) -> bool, bool {
    let das = ty_bits(vals[dest].ty);
    let ph = loop_preheader(lir_l);
    let pht = block_terminator(ph);
    lrb_set_before(pht);
    let i8p = ty_ptr(das);
    let idx_ty = sc_effective_ty(vals[dest].ty);
    var start = sc_op(ev, 0);
    if neg { start = lir_start_for_neg_stride(start, becount, idx_ty, ssc); }
    if !sx_is_safe_to_expand(start) { return false, false; }
    let base = sx_expand_code_for_at(start, i8p, block_terminator(ph));
    let splat = is_bytewise_value(sval);
    if lir_may_loop_access_location(base, MR_MODREF, becount, ssc, stores, splat, true) { return true, false; }
    if lir_avoid_for_multi_block_loop(true, is_loop_memset) { return true, false; }
    var pattern: i32 = -1;
    if splat < 0 { pattern = lir_memset_pattern_value(sval); }
    var marg: i32 = -1;
    var has_bw = false;
    var bw: i64 = 0;
    if pattern >= 0 && (lir_has_memset_pattern || lir_force_pattern) {
        let tcs = sc_trip_count_from_exit_count_ty(becount, idx_ty, lir_l);
        if !sx_is_safe_to_expand(tcs) { return true, false; }
        if !sc_is_const(ssc) { return true, false; }
        let tc = sx_expand_code_for_at(tcs, idx_ty, block_terminator(ph));
        let cs = ap_zext64(sc_ap(ssc));
        let reps = (cs * 8) / (dl_size_bits(vals[pattern].ty) as u64);
        lrb_set_before(pht);
        marg = if reps == 1 { tc } else { lrb_binop(OP_MUL, tc, c_int(ty_int(ty_bits(idx_ty)), reps as! i64), "", false, false) };
        if is_cint(tc) { has_bw = true; bw = (ap_zext64(ci_ap(tc)) * cs) as! i64; }
    } else {
        let nbs = lir_num_bytes(becount, idx_ty, ssc);
        if !sx_is_safe_to_expand(nbs) { return true, false; }
        marg = sx_expand_code_for_at(nbs, idx_ty, block_terminator(ph));
        if is_cint(marg) { has_bw = true; bw = ap_zext64(ci_ap(marg)) as! i64; }
    }
    var tags = ml_aa_tags(the_store);
    for s in stores { tags = lc_aa_merge(tags, ml_aa_tags(s)); }
    tags = lir_extend_to(tags, if has_bw { bw } else { -1 });
    lrb_set_before(pht);
    var nc: i32 = -1;
    if splat >= 0 {
        // CreateMemSet(BasePtr, SplatValue, MemsetArg, MaybeAlign, isVolatile = false, AATags)
        let cf0 = c_false();
        let c = lrb_intrinsic(IID_memset, [vals[base].ty as i32, vals[marg].ty as i32], [base, splat, marg, cf0], "");
        lrb_set_param_aligns(c, salign, 0);
        lir_set_aa(c, tags);
        nc = c;
    } else if lir_force_pattern || blc_is_emittable(LF_memset_pattern16) {
        let cf0 = c_false();
        let c = lrb_intrinsic(IID_experimental_memset_pattern, [i8p, vals[pattern].ty as i32, idx_ty], [base, pattern, marg, cf0], "");
        if salign != 0 { lrb_set_param_aligns(c, salign, 0); }
        lir_set_aa(c, tags);
        nc = c;
    } else {
        return true, false;
    }
    let sdl = inst_get_md(the_store, 0);
    if sdl >= 0 { inst_set_md(nc, 0, sdl); } else { inst_erase_md(nc, 0); }
    if lir_mssau {
        let na = msu_create_access_in_bb(nc, -1, inst_parent(nc), MSP_BEFORE_TERMINATOR, false);
        msu_insert_def(na, true);
    }
    for s in stores {
        if lir_mssau { msu_remove_inst_access(s, true); }
        lir_delete_dead_instruction(s);
    }
    if lir_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lir_fv); }
    return true, true;
}

// processLoopStoreOfLoopLoad(SI, BECount)
fn lir_process_loop_store_of_loop_load_si(si: i32, becount: i32) -> bool {
    let sp = lir_store_ptr(si);
    let sev = sc_get_scev(sp);
    let ss = dl_store_size(vals[lir_store_val(si)].ty);
    let li = lir_store_val(si);
    let lp = op(li, 0);
    let lev = sc_get_scev(lp);
    let ssc = sc_get_constant_ty(vals[sp].ty, ss as u64, false);
    return lir_process_loop_store_of_loop_load(sp, lp, ssc, lir_align(si), lir_align(li), si, li, sev, lev, becount);
}

// MemmoveVerifier
var mv_load_off: i64 = 0;
var mv_store_off: i64 = 0;
var mv_bp1: i32 = -1;
var mv_bp2: i32 = -1;
fn lir_mv_init(lbase: i32, sbase: i32) {
    let b1 = strip_and_accumulate_offsets(strip_ptr_casts(lbase), true, false, false);
    mv_load_off = vt_off;
    mv_bp1 = b1;
    let b2 = strip_and_accumulate_offsets(strip_ptr_casts(sbase), true, false, false);
    mv_store_off = vt_off;
    mv_bp2 = b2;
}
fn lir_mv_may_form_memmove(store_size: i64, neg: bool, the_load: i32, is_memcpy: bool) -> bool {
    if is_memcpy {
        if (!neg && mv_load_off <= mv_store_off) || (neg && mv_load_off >= mv_store_off) { return false; }
    } else {
        let lsize = dl_size_bits(vals[the_load].ty) / 8;
        if mv_bp1 != mv_bp2 || lsize != store_size { return false; }
        if (!neg && mv_load_off < mv_store_off + store_size) || (neg && mv_load_off + lsize > mv_store_off) { return false; }
    }
    return true;
}

fn lir_process_loop_store_of_loop_load(dest: i32, src: i32, ssc: i32, salign: u64, lalign: u64, the_store: i32, the_load: i32,
                                       sev: i32, lev: i32, becount: i32) -> bool {
    if inst_iid(the_store) == IID_memcpy_inline { return false; }
    sx_begin("loop-idiom", true);
    let changed, used = lir_store_of_load_impl(dest, src, ssc, salign, lalign, the_store, the_load, sev, lev, becount);
    if !used { sx_cleanup(); }
    sx_end();
    return changed;
}
fn lir_store_of_load_impl(dest: i32, src: i32, ssc: i32, salign: u64, lalign: u64, the_store: i32, the_load: i32,
                          sev: i32, lev: i32, becount: i32) -> bool, bool {
    let ph = loop_preheader(lir_l);
    let pht = block_terminator(ph);
    var str_start = sc_op(sev, 0);
    let sas = ty_bits(vals[dest].ty);
    let idx_ty = ty_int(dl_ptr(sas).idx);
    let stride = lir_store_stride(sev);
    if !sc_is_const(ssc) { fatal("internal: store size is expected to be a constant"); }
    let store_size = ap_zext64(sc_ap(ssc)) as! i64;
    let neg = lir_u64_eq_ap(store_size as u64, ap_neg(stride));
    if neg { str_start = lir_start_for_neg_stride(str_start, becount, idx_ty, ssc); }
    let sbase = sx_expand_code_for_at(str_start, ty_ptr(sas), pht);
    var ignored: i32[>..<] = [];
    ignored.push(the_store);
    let is_memcpy = mi_is_memcpy(the_store);
    let las = lir_may_loop_access_location(sbase, MR_MODREF, becount, ssc, ignored, -1, false);
    if las {
        if !lir_one_use(the_load) { return true, false; }
        ignored.push(the_load);
        if lir_may_loop_access_location(sbase, MR_MODREF, becount, ssc, ignored, -1, false) { return true, false; }
        ignored.pop();
    }
    var ld_start = sc_op(lev, 0);
    let lds = ty_bits(vals[src].ty);
    if neg { ld_start = lir_start_for_neg_stride(ld_start, becount, idx_ty, ssc); }
    let lbase = sx_expand_code_for_at(ld_start, ty_ptr(lds), pht);
    lir_mv_init(lbase, sbase);
    let same_obj = mv_bp1 == mv_bp2;
    if is_memcpy && !same_obj {
        var w: i64 = 0;
        for k in ignored.len { if ignored[k] != the_store { ignored[w] = ignored[k]; w++; } }
        ignored.resize(w);
    }
    if lir_may_loop_access_location(lbase, MR_MOD, becount, ssc, ignored, -1, false) { return true, false; }
    let is_atomic = lir_inst_is_atomic(the_store) || lir_inst_is_atomic(the_load);
    let use_memmove = if is_memcpy { same_obj } else { las };
    if is_atomic {
        if use_memmove { return true, false; }
        if salign < store_size as u64 || lalign < store_size as u64 { return true, false; }
        if store_size > lir_atomic_mem_max() { return true, false; }
    }
    if use_memmove {
        if !lir_mv_may_form_memmove(store_size, neg, the_load, is_memcpy) { return true, false; }
    }
    if lir_avoid_for_multi_block_loop(false, false) { return true, false; }
    let nbs = lir_num_bytes(becount, idx_ty, ssc);
    let nb = sx_expand_code_for_at(nbs, idx_ty, pht);
    var tags = ml_aa_tags(the_load);
    tags = lc_aa_merge(tags, ml_aa_tags(the_store));
    tags = lir_extend_to(tags, if is_cint(nb) { ap_zext64(ci_ap(nb)) as! i64 } else { -1 });
    lrb_set_before(pht);
    var nc: i32 = -1;
    if !is_atomic {
        let id = if use_memmove { IID_memmove } else { IID_memcpy };
        let cf0 = c_false();
        nc = lrb_intrinsic(id, [vals[sbase].ty as i32, vals[lbase].ty as i32, vals[nb].ty as i32], [sbase, lbase, nb, cf0], "");
        lrb_set_param_aligns(nc, salign, lalign);
    } else {
        let esz = c_int(T_I32, store_size);
        nc = lrb_intrinsic(IID_memcpy_element_unordered_atomic, [vals[sbase].ty as i32, vals[lbase].ty as i32, vals[nb].ty as i32],
                          [sbase, lbase, nb, esz], "");
        lrb_set_param_aligns(nc, salign, lalign);
    }
    lir_set_aa(nc, tags);
    let sdl = inst_get_md(the_store, 0);
    if sdl >= 0 { inst_set_md(nc, 0, sdl); } else { inst_erase_md(nc, 0); }
    if lir_mssau {
        let na = msu_create_access_in_bb(nc, -1, inst_parent(nc), MSP_BEFORE_TERMINATOR, false);
        msu_insert_def(na, true);
        msu_remove_inst_access(the_store, true);
    }
    lir_delete_dead_instruction(the_store);
    if lir_mssau && flag_bool("verify-memoryssa", false) { mssa_verify(lir_fv); }
    return true, true;
}
fn lir_inst_is_atomic(i: i32) -> bool {
    let o = iop(i);
    if o == OP_LOAD || o == OP_STORE { return insts[inst_of(i)].ord != 0; }
    return false;
}

// avoidLIRForMultiBlockLoop
fn lir_avoid_for_multi_block_loop(is_memset: bool, is_loop_memset: bool) -> bool {
    if lir_code_size && loop_nblocks(lir_l) > 1 {
        if loop_is_outermost(lir_l) && (!is_memset || !is_loop_memset) { return true; }
    }
    return false;
}

// runOnCountableLoop
fn lir_run_on_countable_loop() -> bool {
    let becount = sc_get_backedge_taken_count(lir_l, BTC_EXACT);
    if sc_is_zero(becount) { return false; }
    var exits: i32[>..<] = [];
    lir_unique_exit_blocks(lir_l, exits);
    if lir_any_block_may_throw(lir_l) { return false; }
    var changed = false;
    var blocks: i32[>..<] = [];
    for k in loop_nblocks(lir_l) { blocks.push(loop_block(lir_l, k)); }
    for bb in blocks {
        if li_loop_for(bb) != lir_l { continue; }
        if lir_run_on_loop_block(bb, becount, exits) { changed = true; }
    }
    if !lir_dis_hash && !lir_code_size {
        if hr_recognize_crc(lir_l) { lir_optimize_crc_loop(); }
    }
    return changed;
}

// optimizeCRCLoop(Info)
fn lir_optimize_crc_loop() -> bool {
    let m = globs[glob_of(lir_fv)].module;
    let ts = modules[m].triple;
    if ts >= 0 && starts_with(sbytes(ts), "hexagon") { return false; }
    let crc_ty: i32 = vals[hr_lhs].ty;
    let crc_bw = ty_bits(crc_ty);
    var elems: i32[>..<] = [];
    hr_gen_sarwate_table(hr_rhs, hr_big_endian);
    for k in 256 { elems.push(ap_to_cint(crc_ty, hr_table[k])); }
    let at = ty_array(crc_ty, 256);
    let init = c_aggregate(at, elems);
    let gv = new_glob(VK_GVAR, ty_ptr(0), -1, 1);
    let g = glob_of(gv);
    globs[g].module = m;
    globs[g].vty = at;
    globs[g].is_const = 1;
    globs[g].is_decl = 0;
    globs[g].linkage = LK_PRIVATE as u8;
    set_op(gv, 0, init);
    symtab_set_name(modules[m].symtab, gv, ".crctable", true);
    module_append_global(gv);
    let iv = loop_canonical_induction_variable(lir_l);
    var cleanup: i32[>..<] = [];
    let header = loop_header(lir_l);
    var p = block_first(header);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        if p != iv {
            rauw(p, c_poison(vals[p].ty));
            cleanup.push(p);
        }
        p = np;
    }
    {
        let new_btc = (hr_trip_count / 8) - 1;
        let lb = loop_latch(lir_l);
        let br = block_terminator(lb);
        let pred = if term_succ(br, 0) == lb { P_NE } else { P_EQ };
        let ec = ln_latch_cmp_inst(lir_l);
        let lim = c_int(vals[iv].ty, new_btc);
        lrb_set_before(ec);
        let nec = lrb_icmp(pred, iv, lim, "exit.cond");
        rauw(ec, nec);
        lir_delete_dead_instruction(ec);
    }
    {
        lrb_set_head(header, first_non_phi(header));
        let crcphi = new_inst(OP_PHI, crc_ty, 2);
        vals[crcphi].nops = 0;
        lrb_insert(crcphi, "crc");
        phi_add_incoming(crcphi, hr_lhs, loop_preheader(lir_l));
        let crc = crcphi;
        var indexer = crc;
        if hr_lhs_aux >= 0 {
            let data = hr_lhs_aux;
            let dty: i32 = vals[data].ty;
            let ivb = lrb_binop(OP_SHL, iv, c_int(vals[iv].ty, 3), "iv.bits", false, false);
            let ivbits = lrb_zext_or_trunc(ivb, dty, "iv.indexer");
            let di = if hr_big_endian { lrb_binop(OP_SHL, data, ivbits, "data.indexer", false, false) }
                     else { lrb_binop(OP_LSHR, data, ivbits, "data.indexer", false, false) };
            indexer = lrb_binop(OP_XOR, di, lrb_zext_or_trunc(indexer, dty, "crc.indexer.cast"), "crc.data.indexer", false, false);
        }
        if hr_big_endian {
            // HiIdx(Builder, Indexer, "indexer.hi")
            let opty: i32 = vals[indexer].ty;
            let sh = if crc_bw > 8 { lrb_binop(OP_LSHR, indexer, c_int(opty, crc_bw - 8), "indexer.hi", false, false) } else { indexer };
            indexer = lrb_zext_or_trunc(sh, T_I8, "indexer.hi.lo.byte");
        } else {
            indexer = lrb_zext_or_trunc(indexer, T_I8, "indexer.lo");
        }
        let ity = ty_int(dl_ptr(0).idx);
        indexer = lrb_cast(OP_ZEXT, indexer, ity, "indexer.ext");
        var gep: i32 = -1;
        if is_constant(indexer) { gep = ce_gep(crc_ty, gv, [indexer], GEP_INBOUNDS | GEP_NUSW, -1); }
        else {
            gep = create_inst(OP_GEP, ty_ptr(0), [gv, indexer]);
            insts[inst_of(gep)].ty2 = crc_ty;
            insts[inst_of(gep)].flags = GEP_INBOUNDS | GEP_NUSW;
            lrb_insert(gep, "tbl.ptradd");
        }
        let ld = create_inst(OP_LOAD, crc_ty, [gep]);
        insts[inst_of(ld)].align = (log2_exact_i(dl_align(crc_ty, true)) + 1) as u8;
        lrb_insert(ld, "tbl.ld");
        var next = ld;
        if crc_bw > 8 {
            let shift = if hr_big_endian { lrb_binop(OP_SHL, crc, c_int(crc_ty, 8), "crc.be.shift", false, false) }
                        else { lrb_binop(OP_LSHR, crc, c_int(crc_ty, 8), "crc.le.shift", false, false) };
            next = lrb_binop(OP_XOR, shift, ld, "crc.next", false, false);
        }
        phi_add_incoming(crcphi, next, loop_latch(lir_l));
        lir_replace_uses_outside_block(hr_computed, next, loop_latch(lir_l));
    }
    for pn in cleanup { if !is_dead(pn) { ivs_recursively_delete_dead_phi(pn); } }
    sc_forget_loop(lir_l);
    return true;
}
// Loop::getLatchCmpInst
fn ln_latch_cmp_inst(l: i32) -> i32 {
    let latch = loop_latch(l);
    if latch < 0 { return -1; }
    let t = block_terminator(latch);
    if iop(t) != OP_CONDBR { return -1; }
    let c = op(t, 0);
    if is_inst(c) && (iop(c) == OP_ICMP || iop(c) == OP_FCMP) { return c; }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Noncountable loops

fn lir_run_on_noncountable_loop() -> bool {
    if lir_recognize_popcount() { return true; }
    if lir_recognize_and_insert_ffs() { return true; }
    if lir_recognize_shift_until_bit_test() { return true; }
    if lir_recognize_shift_until_zero() { return true; }
    if lir_recognize_shift_until_less_than() { return true; }
    return lir_recognize_and_insert_strlen();
}

// matchCondition(BI, LoopEntry, JmpOnZero)
fn lir_match_condition(bi: i32, entry: i32, jmp_on_zero: bool) -> i32 {
    let c = op(bi, 0);
    if !lir_is_inst_op(c, OP_ICMP) { return -1; }
    let z = op(c, 1);
    if !is_cint(z) || !cint_is_zero(z) { return -1; }
    var t = term_succ(bi, 0);
    var f = term_succ(bi, 1);
    if jmp_on_zero { let x = t; t = f; f = x; }
    let p = inst_pred(c);
    if (p == P_NE && t == entry) || (p == P_EQ && f == entry) { return op(c, 0); }
    return -1;
}

// StrlenVerifier::isValidStrlenIdiom
var sv_op_width: i64 = 0;
var sv_load_base: i32 = -1;
fn lir_is_valid_strlen_idiom() -> bool {
    let l = lir_l;
    if loop_num_back_edges(l) != 1 || loop_nblocks(l) != 1 || lu_unique_exit_block(l) < 0 { return false; }
    let ph = loop_preheader(l);
    if ph < 0 { return false; }
    let pt = iop(block_terminator(ph));
    if pt != OP_BR && pt != OP_CONDBR { return false; }
    let body = loop_block(l, 0);
    if lir_block_size(body) >= 15 { return false; }
    let lt = block_terminator(body);
    if iop(lt) != OP_CONDBR { return false; }
    let cond = lir_match_condition(lt, body, false);
    if cond < 0 { return false; }
    if !lir_is_inst_op(cond, OP_LOAD) || ty_bits(vals[op(cond, 0)].ty) != 0 { return false; }
    let ot: i32 = vals[cond].ty;
    if !ty_is_int(ot) { return false; }
    let lev = sc_get_scev(op(cond, 0));
    if !lir_affine_addrec_of(lev, -1) || !sc_is_const(sc_op(lev, 1)) { return false; }
    sv_load_base = sc_op(lev, 0);
    let step = sc_ap(sc_op(lev, 1));
    if ap_active_bits(step) > 64 { lir_not_ported("strlen idiom with a step wider than 64 bits"); }
    let step_size = ap_zext64(step) & 0xFFFFFFFF;
    sv_op_width = ty_bits(ot);
    let wchar = tli_wchar_size(globs[glob_of(lir_fv)].module);
    if (sv_op_width as u64) != step_size * 8 { return false; }
    if sv_op_width != 8 && sv_op_width != 16 && sv_op_width != 32 { return false; }
    if sv_op_width >= 16 && sv_op_width != wchar * 8 { return false; }
    var i = block_first(body);
    while i >= 0 { if inst_may_have_side_effects(i) { return false; } i = inst_next(i); }
    let exit = lir_exit_block(l);
    if exit < 0 { return false; }
    var p = block_first(exit);
    while p >= 0 && iop(p) == OP_PHI {
        if !sc_is_scevable(vals[p].ty) { return false; }
        let ev = sc_get_scev(p);
        if sc_kind(ev) != SC_ADDREC || !sc_is_affine(ev) { return false; }
        if !sc_is_const(sc_op(ev, 1)) { return false; }
        p = inst_next(p);
    }
    return true;
}

// emitStrLen / emitWcsLen(Ptr, B, DL, TLI) at the lb builder
fn lir_emit_len_call(lf: i64, p: i32) -> i32 {
    if !blc_is_emittable(lf) { return -1; }
    let rt = ty_int(tli_sizet_bits());
    let fty = ty_func_of(rt, [ty_ptr(0)], false);
    let f = blc_get_or_insert(lf, fty, 0);
    var nm: u8[>..] = [];
    nm.append(tli_name(lf));
    blc_infer_by_name(nm);
    let c = create_inst(OP_CALL, ty_fn_ret(fty), [p, f]);
    insts[inst_of(c)].ty2 = fty;
    insts[inst_of(c)].cc = globs[glob_of(f)].cc;
    return lrb_insert(c, nm);
}

fn lir_recognize_and_insert_strlen() -> bool {
    if !lir_is_valid_strlen_idiom() { return false; }
    let ph = loop_preheader(lir_l);
    let body = loop_block(lir_l, 0);
    let exit = lir_exit_block(lir_l);
    let lt = block_terminator(body);
    if sv_op_width == 8 {
        if lir_dis_strlen { return false; }
        if !blc_is_emittable(LF_strlen) { return false; }
    } else {
        if lir_dis_wcslen { return false; }
        if !blc_is_emittable(LF_wcslen) { return false; }
    }
    let pht = block_terminator(ph);
    lrb_set_before(pht);
    lrb_dl = loop_start_loc(lir_l);
    sx_begin("strlen_idiom", true);
    let base = sx_expand_code_for_at(sv_load_base, sc_ty(sv_load_base), pht);
    lrb_set_before(pht);
    lrb_dl = loop_start_loc(lir_l);
    let call = lir_emit_len_call(if sv_op_width == 8 { LF_strlen } else { LF_wcslen }, base);
    let slev = sc_get_scev(call);
    var cleanup: i32[>..<] = [];
    var p = block_first(exit);
    while p >= 0 && iop(p) == OP_PHI {
        let np = inst_next(p);
        let ev = sc_get_scev(p);
        let step = sc_op(ev, 1);
        let b = sc_op(ev, 0);
        let nev = sc_add(b, sc_mul(step, sc_get_truncate_or_sign_extend(slev, sc_ty(b), 0)));
        let mp = sx_expand_code_for_at(nev, sc_ty(nev), pht);
        sx_clear();
        rauw(p, mp);
        cleanup.push(p);
        p = np;
    }
    sx_end();
    for pn in cleanup { if !is_dead(pn) { ivs_recursively_delete_dead_phi(pn); } }
    let nc = if term_succ(lt, 0) == body { c_false() } else { c_true() };
    set_op(lt, 0, nc);
    sc_forget_loop(lir_l);
    return true;
}
// matchShiftULTCondition
fn lir_match_shift_ult_condition(bi: i32, entry: i32) -> i32, AP {
    let z = ap_zero(1);
    let c = op(bi, 0);
    if !lir_is_inst_op(c, OP_ICMP) { return -1, z; }
    let k = op(c, 1);
    if !is_cint(k) { return -1, z; }
    if inst_pred(c) == P_ULT && term_succ(bi, 1) == entry { return op(c, 0), ci_ap(k); }
    return -1, z;
}

// getRecurrenceVar
fn lir_recurrence_var(varx: i32, defx: i32, entry: i32) -> i32 {
    if is_inst(varx) && iop(varx) == OP_PHI && inst_parent(varx) == entry && (op(varx, 0) == defx || op(varx, 1) == defx) { return varx; }
    return -1;
}

fn lir_cint_is_one(c: i32) -> bool { is_cint(c) && ap_is_one(ci_ap(c)) }
fn lir_cint_is_minus_one(c: i32) -> bool { is_cint(c) && ap_is_all_ones(ci_ap(c)) }

// the "cnt.next = cnt +/- 1" search shared by the FFS detectors
fn lir_find_count_inst(entry: i32, allow_minus: bool) -> i32, i32 {
    var i = first_non_phi(entry);
    while i >= 0 {
        if iop(i) == OP_ADD {
            let inc = op(i, 1);
            if is_cint(inc) && (lir_cint_is_one(inc) || (allow_minus && lir_cint_is_minus_one(inc))) {
                let ph = lir_recurrence_var(op(i, 0), i, entry);
                if ph >= 0 { return i, ph; }
            }
        }
        i = inst_next(i);
    }
    return -1, -1;
}

var ffs_intrin: i64 = 0;
var ffs_initx: i32 = -1;
var ffs_cnt_inst: i32 = -1;
var ffs_cnt_phi: i32 = -1;
var ffs_defx: i32 = -1;

// detectShiftUntilLessThanIdiom
fn lir_detect_shift_until_less_than() -> bool, AP {
    let z = ap_zero(1);
    ffs_defx = -1; ffs_cnt_inst = -1; ffs_cnt_phi = -1;
    let entry = loop_block(lir_l, 0);
    let bi = block_terminator(entry);
    if iop(bi) != OP_CONDBR { return false, z; }
    let t, thr = lir_match_shift_ult_condition(bi, entry);
    if t < 0 { return false, z; }
    var defx = if is_inst(t) { t } else { -1 };
    if defx < 0 || iop(defx) != OP_PHI { return false, thr; }
    let varphi = defx;
    let idx = phi_block_index(varphi, entry);
    if idx < 0 { return false, thr; }
    defx = phi_value(varphi, idx);
    if !is_inst(defx) || nops(defx) == 0 || op(defx, 0) != varphi { return false, thr; }
    if iop(defx) != OP_LSHR { return false, thr; }
    ffs_intrin = IID_ctlz;
    if !lir_cint_is_one(op(defx, 1)) { return false, thr; }
    ffs_initx = lir_phi_in(varphi, loop_preheader(lir_l));
    ffs_defx = defx;
    let ci, cp = lir_find_count_inst(entry, true);
    if ci < 0 { return false, thr; }
    ffs_cnt_inst = ci; ffs_cnt_phi = cp;
    return true, thr;
}

// detectPopcountIdiom
fn lir_detect_popcount(precond: i32) -> bool, i32 {
    let entry = loop_block(lir_l, 0);
    let lt = block_terminator(entry);
    if iop(lt) != OP_CONDBR { return false, -1; }
    let d0 = lir_match_condition(lt, entry, false);
    let defx2 = if d0 >= 0 && is_inst(d0) { d0 } else { -1 };
    if defx2 < 0 || iop(defx2) != OP_AND { return false, -1; }
    var sub1: i32 = -1;
    var varx1: i32 = -1;
    let a0 = op(defx2, 0);
    if is_inst(a0) && is_binary_op(iop(a0)) { sub1 = a0; varx1 = op(defx2, 1); }
    else {
        varx1 = a0;
        let a1 = op(defx2, 1);
        if is_inst(a1) && is_binary_op(iop(a1)) { sub1 = a1; }
    }
    if sub1 < 0 || op(sub1, 0) != varx1 { return false, -1; }
    let dec = op(sub1, 1);
    if !is_cint(dec) || !((iop(sub1) == OP_SUB && lir_cint_is_one(dec)) || (iop(sub1) == OP_ADD && lir_cint_is_minus_one(dec))) { return false, -1; }
    let phix = lir_recurrence_var(varx1, defx2, entry);
    if phix < 0 { return false, -1; }
    var count_inst: i32 = -1;
    var count_phi: i32 = -1;
    var i = first_non_phi(entry);
    while i >= 0 {
        if iop(i) == OP_ADD && lir_cint_is_one(op(i, 1)) {
            let ph = lir_recurrence_var(op(i, 0), i, entry);
            if ph >= 0 {
                var live_out = false;
                var u = vals[i].first_use;
                while u >= 0 { if inst_parent(uses[u].user) != entry { live_out = true; break; } u = uses[u].next; }
                if live_out { count_inst = i; count_phi = ph; break; }
            }
        }
        i = inst_next(i);
    }
    if count_inst < 0 { return false, -1; }
    let pcb = block_terminator(precond);
    if iop(pcb) != OP_CONDBR { return false, -1; }
    let t = lir_match_condition(pcb, loop_preheader(lir_l), false);
    if t != op(phix, 0) && t != op(phix, 1) { return false, -1; }
    ffs_cnt_inst = count_inst;
    ffs_cnt_phi = count_phi;
    return true, t;
}

// detectShiftUntilZeroIdiom (the FFS one)
fn lir_detect_shift_until_zero_ffs() -> bool {
    ffs_defx = -1; ffs_cnt_inst = -1; ffs_cnt_phi = -1;
    let entry = loop_block(lir_l, 0);
    let lt = block_terminator(entry);
    if iop(lt) != OP_CONDBR { return false; }
    let d0 = lir_match_condition(lt, entry, false);
    let defx = if d0 >= 0 && is_inst(d0) { d0 } else { -1 };
    if defx < 0 { return false; }
    let o = iop(defx);
    if o != OP_SHL && o != OP_LSHR && o != OP_ASHR { return false; }
    ffs_intrin = if o == OP_SHL { IID_cttz } else { IID_ctlz };
    if !lir_cint_is_one(op(defx, 1)) { return false; }
    let varx = op(defx, 0);
    let phix = lir_recurrence_var(varx, defx, entry);
    if phix < 0 { return false; }
    ffs_initx = lir_phi_in(phix, loop_preheader(lir_l));
    ffs_defx = defx;
    if o == OP_ASHR && !ce_known_nonneg(ffs_initx, 0) { return false; }
    let ci, cp = lir_find_count_inst(entry, true);
    if ci < 0 { return false; }
    ffs_cnt_inst = ci; ffs_cnt_phi = cp;
    return true;
}

// isProfitableToInsertFFS
fn lir_profitable_ffs(id: i64, initx: i32, zero_check: bool, canonical: i64) -> bool {
    let header_size = lir_block_size(loop_header(lir_l));
    let args: i32[2] = [initx, if zero_check { c_true() } else { c_false() }];
    let cost = tti_intrinsic_cost_args(id as i32, vals[initx].ty, args, TCK_SIZE_AND_LATENCY);
    if header_size != canonical && cost > TCC_BASIC { return false; }
    return true;
}

fn lir_used_outside_loop(v: i32) -> bool {
    var u = vals[v].first_use;
    while u >= 0 { if !loop_contains(lir_l, inst_parent(uses[u].user)) { return true; } u = uses[u].next; }
    return false;
}

// insertFFSIfProfitable
fn lir_insert_ffs_if_profitable(id: i64, initx: i32, defx: i32, cnt_phi: i32, cnt_inst: i32) -> bool {
    let phi_out = lir_used_outside_loop(cnt_phi);
    let inst_out = lir_used_outside_loop(cnt_inst);
    if inst_out && phi_out { return false; }
    var zero_check = false;
    let ph = loop_preheader(lir_l);
    if !phi_out {
        let pcb = lir_single_pred(ph);
        if pcb < 0 { return false; }
        let pbi = block_terminator(pcb);
        if iop(pbi) != OP_CONDBR { return false; }
        if lir_match_condition(pbi, ph, false) != initx { return false; }
        zero_check = true;
    }
    if !lir_profitable_ffs(id, initx, zero_check, 6) { return false; }
    lir_transform_loop_to_countable(id, ph, cnt_inst, cnt_phi, initx, defx, inst_get_md(defx, 0), zero_check, phi_out, false);
    return true;
}

fn lir_recognize_and_insert_ffs() -> bool {
    if loop_num_back_edges(lir_l) != 1 || loop_nblocks(lir_l) != 1 { return false; }
    if !lir_detect_shift_until_zero_ffs() { return false; }
    return lir_insert_ffs_if_profitable(ffs_intrin, ffs_initx, ffs_defx, ffs_cnt_phi, ffs_cnt_inst);
}

fn lir_recognize_shift_until_less_than() -> bool {
    if loop_num_back_edges(lir_l) != 1 || loop_nblocks(lir_l) != 1 { return false; }
    let ok, thr = lir_detect_shift_until_less_than();
    if !ok { return false; }
    if lir_ap_eq_u(thr, 2) { return lir_insert_ffs_if_profitable(ffs_intrin, ffs_initx, ffs_defx, ffs_cnt_phi, ffs_cnt_inst); }
    if !lir_ap_eq_u(thr, 4) { return false; }
    var u = vals[ffs_cnt_phi].first_use;
    while u >= 0 { if !loop_contains(lir_l, inst_parent(uses[u].user)) { return false; } u = uses[u].next; }
    let ph = loop_preheader(lir_l);
    let pcb = lir_single_pred(ph);
    if pcb < 0 { return false; }
    let pbi = block_terminator(pcb);
    if iop(pbi) != OP_CONDBR { return false; }
    let v, pthr = lir_match_shift_ult_condition(pbi, ph);
    if v != ffs_initx || !lir_ap_eq_u(pthr, 2) { return false; }
    if !lir_profitable_ffs(ffs_intrin, ffs_initx, true, 6) { return false; }
    lir_transform_loop_to_countable(ffs_intrin, ph, ffs_cnt_inst, ffs_cnt_phi, ffs_initx, ffs_defx, inst_get_md(ffs_defx, 0), true, false, true);
    return true;
}
fn lir_ap_eq_u(a: AP, x: u64) -> bool { ap_active_bits(a) <= 64 && ap_zext64(a) == x }

fn lir_recognize_popcount() -> bool {
    if !lir_popcnt_fast() { return false; }
    if loop_num_back_edges(lir_l) != 1 || loop_nblocks(lir_l) != 1 { return false; }
    let body = loop_block(lir_l, 0);
    if lir_block_size(body) >= 20 { return false; }
    let ph = loop_preheader(lir_l);
    if ph < 0 || block_first(ph) != block_terminator(ph) { return false; }
    if iop(block_terminator(ph)) != OP_BR { return false; }
    let pcb = lir_single_pred(ph);
    if pcb < 0 { return false; }
    if iop(block_terminator(pcb)) != OP_CONDBR { return false; }
    let ok, v = lir_detect_popcount(pcb);
    if !ok { return false; }
    lir_transform_loop_to_popcount(pcb, ffs_cnt_inst, ffs_cnt_phi, v);
    return true;
}

// transformLoopToCountable
fn lir_transform_loop_to_countable(id: i64, ph: i32, cnt_inst: i32, cnt_phi: i32, initx: i32, defx: i32, dl: i32,
                                   zero_check: bool, phi_out: bool, insert_sub: bool) {
    lrb_set_before(block_terminator(ph));
    lrb_dl = dl;
    var initx_next = initx;
    if phi_out {
        let o = iop(defx);
        if o == OP_ASHR { initx_next = lrb_binop(OP_ASHR, initx, c_int(vals[initx].ty, 1), "", false, false); }
        else if o == OP_LSHR { initx_next = lrb_binop(OP_LSHR, initx, c_int(vals[initx].ty, 1), "", false, false); }
        else if o == OP_SHL { initx_next = lrb_binop(OP_SHL, initx, c_int(vals[initx].ty, 1), "", false, false); }
        else { fatal("Unexpected opcode!"); }
    }
    lrb_dl = dl;
    let zc = if zero_check { c_true() } else { c_false() };
    var count = lrb_intrinsic(id, [vals[initx_next].ty as i32], [initx_next, zc], "");
    let cty: i32 = vals[count].ty;
    count = lrb_binop(OP_SUB, c_int(cty, ty_bits(cty)), count, "", false, false);
    if insert_sub { count = lrb_binop(OP_SUB, count, c_int(cty, 1), "", false, false); }
    var new_count = count;
    if phi_out { count = lrb_binop(OP_ADD, count, c_int(cty, 1), "", false, false); }
    new_count = lrb_zext_or_trunc(new_count, vals[cnt_inst].ty, "");
    let init = lir_phi_in(cnt_phi, ph);
    if lir_cint_is_one(op(cnt_inst, 1)) {
        if !(is_cint(init) && cint_is_zero(init)) { new_count = lrb_binop(OP_ADD, new_count, init, "", false, false); }
    } else {
        new_count = lrb_binop(OP_SUB, init, new_count, "", false, false);
    }
    let body = loop_block(lir_l, 0);
    let lbr = block_terminator(body);
    let lcond = op(lbr, 0);
    let tcphi = new_inst(OP_PHI, cty, 2);
    vals[tcphi].nops = 0;
    inst_insert_before_head(tcphi, block_first(body));
    set_name(tcphi, "tcphi");
    lrb_set_before(lcond);
    let tcdec = lrb_binop(OP_SUB, tcphi, c_int(cty, 1), "tcdec", false, true);
    phi_add_incoming(tcphi, count, ph);
    phi_add_incoming(tcphi, tcdec, body);
    let pred = if term_succ(lbr, 0) == body { P_NE } else { P_EQ };
    insts[inst_of(lcond)].pred = pred as u8;
    set_op(lcond, 0, tcdec);
    set_op(lcond, 1, c_int(cty, 0));
    if phi_out { lir_replace_uses_outside_block(cnt_phi, new_count, body); }
    else { lir_replace_uses_outside_block(cnt_inst, new_count, body); }
    sc_forget_loop(lir_l);
}

// transformLoopToPopcount
fn lir_transform_loop_to_popcount(pcb: i32, cnt_inst: i32, cnt_phi: i32, v: i32) {
    let ph = loop_preheader(lir_l);
    let pbr = block_terminator(pcb);
    let dl = inst_get_md(cnt_inst, 0);
    lrb_set_before(pbr);
    lrb_dl = dl;
    let popcnt = lrb_intrinsic(IID_ctpop, [vals[v].ty as i32], [v], "");
    let pz = lrb_zext_or_trunc(popcnt, vals[cnt_phi].ty, "");
    var new_count = pz;
    if new_count != popcnt { lir_set_dl(new_count, dl); }
    let trip = new_count;
    let init = lir_phi_in(cnt_phi, ph);
    if !(is_cint(init) && cint_is_zero(init)) {
        new_count = lrb_binop(OP_ADD, new_count, init, "", false, false);
        lir_set_dl(new_count, dl);
    }
    {
        let pc = op(pbr, 0);
        var o0 = pz;
        var o1 = c_int(vals[pz].ty, 0);
        if op(pc, 0) != v { let x = o0; o0 = o1; o1 = x; }
        let npc = lrb_icmp(inst_pred(pc), o0, o1, "");
        set_op(pbr, 0, npc);
        var dead: i32[>..<] = [];
        dead.push(pc);
        lu_recursively_delete_dead(dead, false);
    }
    let body = loop_block(lir_l, 0);
    {
        let lbr = block_terminator(body);
        let lc = op(lbr, 0);
        let ty: i32 = vals[trip].ty;
        let tcphi = new_inst(OP_PHI, ty, 2);
        vals[tcphi].nops = 0;
        inst_insert_before_head(tcphi, block_first(body));
        set_name(tcphi, "tcphi");
        lrb_set_before(lc);
        let tcdec = lrb_binop(OP_SUB, tcphi, c_int(ty, 1), "tcdec", false, true);
        phi_add_incoming(tcphi, trip, ph);
        phi_add_incoming(tcphi, tcdec, body);
        let pred = if term_succ(lbr, 0) == body { P_UGT } else { P_SLE };
        insts[inst_of(lc)].pred = pred as u8;
        set_op(lc, 0, tcdec);
        set_op(lc, 1, c_int(ty, 0));
    }
    lir_replace_uses_outside_block(cnt_inst, new_count, body);
    sc_forget_loop(lir_l);
}
fn lir_set_dl(i: i32, dl: i32) { if !is_inst(i) { return; } if dl >= 0 { inst_set_md(i, 0, dl); } else { inst_erase_md(i, 0); } }

// detectShiftUntilBitTestIdiom
var sbt_x: i32 = -1;
var sbt_mask: i32 = -1;
var sbt_pos: i32 = -1;
var sbt_curr: i32 = -1;
var sbt_next: i32 = -1;
fn lir_detect_shift_until_bit_test() -> bool {
    if loop_nblocks(lir_l) != 1 || loop_num_back_edges(lir_l) != 1 { return false; }
    let hb = loop_header(lir_l);
    let ph = loop_preheader(lir_l);
    let t = block_terminator(hb);
    if iop(t) != OP_CONDBR || !lir_is_inst_op(op(t, 0), OP_ICMP) { return false; }
    let cmp = op(t, 0);
    var pred = inst_pred(cmp);
    let lhs = op(cmp, 0);
    let rhs = op(cmp, 1);
    var tb = term_succ(t, 0);
    var fb = term_succ(t, 1);
    var matched = false;
    // MatchVariableBitMask
    if (pred == P_EQ || pred == P_NE) && m_zero(rhs) && lir_is_inst_op(lhs, OP_AND) {
        for k in 2 {
            let x = op(lhs, k);
            let bm = op(lhs, 1 - k);
            if lir_is_inst_op(bm, OP_SHL) && m_one(op(bm, 0)) && lir_loop_invariant(bm) {
                sbt_curr = x; sbt_mask = bm; sbt_pos = op(bm, 1);
                matched = true;
                break;
            }
        }
    }
    if !matched {
        let ok, x, mask, c, p2 = ic::icc_decompose_bit_test_icmp(lhs, rhs, pred, true, false, true);
        let unused = c;
        if ok && ap_is_pow2(mask) {
            pred = p2;
            sbt_curr = x;
            sbt_mask = ap_to_cint(vals[x].ty, mask);
            sbt_pos = c_int(vals[x].ty, ap_log2(mask));
            matched = true;
        }
    }
    if !matched { return false; }
    if !lir_is_inst_op(sbt_curr, OP_PHI) || inst_parent(sbt_curr) != hb { return false; }
    sbt_x = lir_phi_in(sbt_curr, ph);
    let nx = lir_phi_in(sbt_curr, hb);
    sbt_next = if is_inst(nx) { nx } else { -1 };
    if sbt_next < 0 || iop(sbt_next) != OP_SHL || op(sbt_next, 0) != sbt_curr || !m_one(op(sbt_next, 1)) { return false; }
    if pred != P_EQ { let x = tb; tb = fb; fb = x; }
    if tb != hb { return false; }
    return true;
}

fn lir_recognize_shift_until_bit_test() -> bool {
    if !lir_detect_shift_until_bit_test() { return false; }
    var x = sbt_x;
    let bit_mask = sbt_mask;
    var bit_pos = sbt_pos;
    let xcurr = sbt_curr;
    let xnext = sbt_next;
    let hb = loop_header(lir_l);
    let ph = loop_preheader(lir_l);
    let succ = lir_exit_block(lir_l);
    lrb_set_before(block_terminator(ph));
    lrb_dl = inst_get_md(xcurr, 0);
    let ty: i32 = vals[x].ty;
    let bw = ty_bits(ty);
    let cargs: i32[2] = [c_poison(ty), c_true()];
    if tti_intrinsic_cost_args(IID_ctlz as i32, ty, cargs, TCK_SIZE_AND_LATENCY) > TCC_BASIC { return false; }
    if tti_arith_cost(OP_SHL, ty, TCK_SIZE_AND_LATENCY, []) > TCC_BASIC { return false; }
    if !lir_not_undef_poison(bit_pos) {
        var ip: i32 = -1;
        var ip_bb: i32 = -1;
        var ok = true;
        if is_inst(bit_pos) {
            let o = iop(bit_pos);
            if o == OP_PHI { ip_bb = inst_parent(bit_pos); ip = lu_first_insertion_pt(ip_bb); }
            else if o == OP_INVOKE { lir_not_ported("getInsertionPointAfterDef of an invoke"); }
            else if o == OP_CALLBR { ok = false; }
            else { ip_bb = inst_parent(bit_pos); ip = inst_next(bit_pos); }
        } else {
            // DT->getRoot()->getFirstNonPHIOrDbgOrAlloca(): static allocas and pseudo probes skipped, no head bit
            ip_bb = func_entry(lir_fv);
            ip = first_non_phi(ip_bb);
            if ip >= 0 && inst_is_eh_pad(ip) { ip = inst_next(ip); }
            while ip >= 0 && ((iop(ip) == OP_ALLOCA && ml_is_static_alloca(ip)) || inst_iid(ip) == IID_pseudoprobe) { ip = inst_next(ip); }
        }
        if !ok { return false; }
        let fr = create_inst(OP_FREEZE, vals[bit_pos].ty, [bit_pos]);
        // new FreezeInst(..., InsertPt): getInsertionPointAfterDef of a PHI is getFirstInsertionPt (head bit); the
        // other insertion points have no head bit (the new instruction adopts the debug records there)
        if ip >= 0 {
            if is_inst(bit_pos) && iop(bit_pos) == OP_PHI { inst_insert_before_head(fr, ip); } else { inst_insert_before(fr, ip); }
        } else { block_append_inst(ip_bb, fr); }
        let nm = lir_name_plus(bit_pos, ".fr");
        set_name(fr, nm);
        var u = vals[bit_pos].first_use;
        while u >= 0 {
            let nu = uses[u].next;
            if uses[u].user != fr { use_set(u, fr); }
            u = nu;
        }
        bit_pos = fr;
    }
    lrb_set_before(block_terminator(ph));
    lrb_dl = inst_get_md(xcurr, 0);
    let low = lrb_binop(OP_ADD, bit_mask, c_all_ones(ty), lir_name_plus(bit_pos, ".lowbitmask"), false, false);
    let mask = lrb_binop(OP_OR, low, bit_mask, lir_name_plus(bit_pos, ".mask"), false, false);
    let xm = lrb_binop(OP_AND, x, mask, lir_name_plus(x, ".masked"), false, false);
    let ct = c_true();
    let nlz = lrb_intrinsic(IID_ctlz, [ty], [xm, ct], lir_name_plus(xm, ".numleadingzeros"));
    let nab = lrb_binop(OP_SUB, c_int(ty, bw), nlz, lir_name_plus(xm, ".numactivebits"), true, bw != 2);
    let lop = lrb_binop(OP_ADD, nab, c_all_ones(ty), lir_name_plus(xm, ".leadingonepos"), false, bw > 2);
    let btc = lrb_binop(OP_SUB, bit_pos, lop, lir_loop_name_plus(lir_l, ".backedgetakencount"), true, true);
    let tc = lrb_binop(OP_ADD, btc, c_int(ty, 1), lir_loop_name_plus(lir_l, ".tripcount"), true, bw != 2);
    let newx = lrb_binop(OP_SHL, x, btc, "", false, false);
    cu_take_name(newx, xcurr);
    if is_inst(newx) { ic::copy_ir_flags(newx, xnext); }
    var newxnext: i32 = -1;
    var bp_ne = false;
    if is_cint(bit_pos) { bp_ne = !lir_ap_eq_u(ci_ap(bit_pos), (bw - 1) as u64); }
    if lir_has_nsw(xnext) || lir_has_nuw(xnext) || bp_ne { newxnext = lrb_binop(OP_SHL, x, tc, "", false, false); }
    else { newxnext = lrb_binop(OP_SHL, newx, c_int(ty, 1), "", false, false); }
    cu_take_name(newxnext, xnext);
    if is_inst(newxnext) { ic::copy_ir_flags(newxnext, xnext); }
    lir_replace_uses_outside_block(xcurr, newx, hb);
    lir_replace_uses_outside_block(xnext, newxnext, hb);
    lrb_set_head(hb, block_first(hb));
    let iv = new_inst(OP_PHI, ty, 2);
    vals[iv].nops = 0;
    lrb_insert(iv, lir_loop_name_plus(lir_l, ".iv"));
    lrb_set_before(block_terminator(hb));
    let ivnext = lrb_binop(OP_ADD, iv, c_int(ty, 1), lir_name_plus(iv, ".next"), true, bw != 2);
    let ivcheck = lrb_icmp(P_EQ, ivnext, tc, lir_loop_name_plus(lir_l, ".ivcheck"));
    let old_t = block_terminator(hb);
    var ws: u64[>..<] = [];
    let has_w = !flag_bool("profcheck-disable-metadata-fixes", false) && pd_extract(old_t, ws);
    let bi = lrb_insert(create_inst(OP_CONDBR, T_VOID, [ivcheck, succ, hb]), "");
    if has_w {
        if succ == term_succ(old_t, 1) { let a = ws[0]; ws[0] = ws[1]; ws[1] = a; }
        pd_set(bi, ws, false, false);
    }
    inst_erase_from_parent(old_t);
    phi_add_incoming(iv, c_int(ty, 0), ph);
    phi_add_incoming(iv, ivnext, hb);
    sc_forget_loop(lir_l);
    let unused = x;
    x = unused;
    return true;
}
fn lir_has_nsw(i: i32) -> bool { (insts[inst_of(i)].flags & FL_NSW) != 0 }
fn lir_has_nuw(i: i32) -> bool { (insts[inst_of(i)].flags & FL_NUW) != 0 }
// isGuaranteedNotToBeUndefOrPoison(V) without AC, context or DT
fn lir_not_undef_poison(v: i32) -> bool {
    let sc = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac;
    kb_cxt = -1; sq_no_dt = true; sq_no_ac = true;
    let r = is_guaranteed_not_to_be_undef_or_poison(v, -1, 0);
    kb_cxt = sc; sq_no_dt = sdt; sq_no_ac = sac;
    return r;
}

// detectShiftUntilZeroIdiom (the SCEV one)
var suz_cmp: i32 = -1;
var suz_intrin: i64 = 0;
var suz_iv: i32 = -1;
var suz_start: i32 = -1;
var suz_val: i32 = -1;
var suz_extra: i32 = -1;
var suz_inverted: bool = false;
fn lir_detect_shift_until_zero_scev() -> bool {
    if loop_nblocks(lir_l) != 1 || loop_num_back_edges(lir_l) != 1 { return false; }
    let hb = loop_header(lir_l);
    let ph = loop_preheader(lir_l);
    let t = block_terminator(hb);
    if iop(t) != OP_CONDBR || !is_inst(op(t, 0)) { return false; }
    suz_cmp = op(t, 0);
    var tb = term_succ(t, 0);
    var fb = term_succ(t, 1);
    if iop(suz_cmp) != OP_ICMP || !is_inst(op(suz_cmp, 0)) || !m_zero(op(suz_cmp, 1)) { return false; }
    var pred = inst_pred(suz_cmp);
    if pred != P_EQ && pred != P_NE { return false; }
    let vs = op(suz_cmp, 0);
    let vo = iop(vs);
    if vo != OP_SHL && vo != OP_LSHR && vo != OP_ASHR { return false; }
    if !lir_loop_invariant(op(vs, 0)) || !is_inst(op(vs, 1)) { return false; }
    suz_val = op(vs, 0);
    let nbits = op(vs, 1);
    suz_intrin = if vo == OP_SHL { IID_cttz } else { IID_ctlz };
    var matched = false;
    if iop(nbits) == OP_ADD && (lir_has_nsw(nbits) || lir_has_nuw(nbits)) {
        for k in 2 {
            let a = op(nbits, k);
            let b = op(nbits, 1 - k);
            if is_inst(a) && lir_loop_invariant(b) {
                suz_iv = a;
                suz_extra = sc_get_negative(sc_get_scev(b), SF_ANY);
                matched = true;
                break;
            }
        }
    }
    if !matched && iop(nbits) == OP_SUB && is_inst(op(nbits, 0)) && lir_loop_invariant(op(nbits, 1)) && lir_has_nsw(nbits) {
        suz_iv = op(nbits, 0);
        suz_extra = sc_get_scev(op(nbits, 1));
        matched = true;
    }
    if !matched {
        suz_iv = nbits;
        suz_extra = sc_get_zero(vals[nbits].ty);
    }
    if iop(suz_iv) != OP_PHI || inst_parent(suz_iv) != hb { return false; }
    suz_start = lir_phi_in(suz_iv, ph);
    let ivn = lir_phi_in(suz_iv, hb);
    if !is_inst(ivn) || iop(ivn) != OP_ADD || op(ivn, 0) != suz_iv || !m_one(op(ivn, 1)) { return false; }
    suz_inverted = pred != P_EQ;
    if suz_inverted { let x = tb; tb = fb; fb = x; }
    if fb != hb { return false; }
    if vo == OP_ASHR && !lir_is_must_progress(lir_l) && !sc_is_known_non_negative(sc_get_scev(suz_val)) { return false; }
    return true;
}

fn lir_recognize_shift_until_zero() -> bool {
    if !lir_detect_shift_until_zero_scev() { return false; }
    let hb = loop_header(lir_l);
    let ph = loop_preheader(lir_l);
    let succ = lir_exit_block(lir_l);
    let iv = suz_iv;
    let start = suz_start;
    let val = suz_val;
    lrb_set_before(block_terminator(ph));
    lrb_dl = inst_get_md(iv, 0);
    let ty: i32 = vals[val].ty;
    let bw = ty_bits(ty);
    let cargs: i32[2] = [c_poison(ty), c_false()];
    if tti_intrinsic_cost_args(suz_intrin as i32, ty, cargs, TCK_SIZE_AND_LATENCY) > TCC_BASIC { return false; }
    let off_zero = sc_is_zero(suz_extra);
    let cfz = c_false();
    let nlz = lrb_intrinsic(suz_intrin, [ty], [val, cfz], lir_name_plus(val, ".numleadingzeros"));
    let nab = lrb_binop(OP_SUB, c_int(ty, bw), nlz, lir_name_plus(val, ".numactivebits"), true, bw != 2);
    sx_begin("loop-idiom", true);
    sx_set_insert_point(block_terminator(ph));
    let extra = sx_expand_code_for(suz_extra, -1);
    sx_end();
    lrb_set_before(block_terminator(ph));
    lrb_dl = inst_get_md(iv, 0);
    let nabo = lrb_binop(OP_ADD, nab, extra, lir_name_plus(nab, ".offset"), off_zero, true);
    let ivfinal = lrb_intrinsic(IID_smax, [ty], [nabo, start], "iv.final");
    let btc = lrb_binop(OP_SUB, ivfinal, start, lir_loop_name_plus(lir_l, ".backedgetakencount"), off_zero, true);
    let tc = lrb_binop(OP_ADD, btc, c_int(ty, 1), lir_loop_name_plus(lir_l, ".tripcount"), true, bw != 2);
    lir_replace_uses_outside_block(iv, ivfinal, hb);
    lrb_set_head(hb, block_first(hb));
    let civ = new_inst(OP_PHI, ty, 2);
    vals[civ].nops = 0;
    lrb_insert(civ, lir_loop_name_plus(lir_l, ".iv"));
    lrb_set_head(hb, first_non_phi(hb));
    let civn = lrb_binop(OP_ADD, civ, c_int(ty, 1), lir_name_plus(civ, ".next"), true, bw != 2);
    let civc = lrb_icmp(P_EQ, civn, tc, lir_loop_name_plus(lir_l, ".ivcheck"));
    var newc = civc;
    if suz_inverted {
        newc = lrb_binop(OP_XOR, civc, c_all_ones(vals[civc].ty), "", false, false);
        cu_take_name(newc, suz_cmp);
    }
    let ivd = lrb_binop(OP_ADD, civ, start, "", false, true);
    cu_take_name(ivd, iv);
    let old_t = block_terminator(hb);
    lrb_set_before(old_t);
    var ws: u64[>..<] = [];
    let has_w = !flag_bool("profcheck-disable-metadata-fixes", false) && pd_extract(old_t, ws);
    let bi = lrb_insert(create_inst(OP_CONDBR, T_VOID, [civc, succ, hb]), "");
    if has_w {
        if suz_inverted { let a = ws[0]; ws[0] = ws[1]; ws[1] = a; }
        pd_set(bi, ws, false, false);
    }
    inst_erase_from_parent(old_t);
    phi_add_incoming(civ, c_int(ty, 0), ph);
    phi_add_incoming(civ, civn, hb);
    sc_forget_loop(lir_l);
    rauw(iv, ivd);
    inst_erase_from_parent(iv);
    rauw(suz_cmp, newc);
    inst_erase_from_parent(suz_cmp);
    return true;
}

// ---------------------------------------------------------------------------------------------
// runOnLoop and the pass

fn lir_run_on_loop(l: i32) -> bool {
    lir_l = l;
    if loop_preheader(l) < 0 { return false; }
    let nm = val_name(lir_fv);
    if nm == "memset" || nm == "memcpy" || nm == "strlen" || nm == "wcslen" { return false; }
    lir_code_size = (func_has_fn_attr(lir_fv, AK_OptimizeForSize) || func_has_fn_attr(lir_fv, AK_MinSize)) && flag_bool("use-lir-code-size-heurs", true);
    lir_has_memset = tli_has(LF_memset as i32);
    lir_has_memset_pattern = tli_has(LF_memset_pattern16 as i32);
    lir_has_memcpy = tli_has(LF_memcpy as i32);
    if lir_has_memset || lir_has_memset_pattern || lir_force_pattern || lir_has_memcpy || !lir_dis_hash {
        if !sc_is_cnc(sc_get_backedge_taken_count(l, BTC_EXACT)) { return lir_run_on_countable_loop(); }
    }
    return lir_run_on_noncountable_loop();
}

fn loop_idiom_pass_run(l: i32, use_mssa: bool) -> u32 {
    if flag_bool("disable-loop-idiom-all", false) { return PA_ALL; }
    lir_fv = block_func(loop_header(l));
    tli_cur_fn = lir_fv;
    local_have_tli = true;
    tti_init_function(lir_fv, globs[glob_of(lir_fv)].module);
    lir_dis_memset = flag_bool("disable-loop-idiom-memset", false);
    lir_dis_memcpy = flag_bool("disable-loop-idiom-memcpy", false);
    lir_dis_strlen = flag_bool("disable-loop-idiom-strlen", false);
    lir_dis_wcslen = flag_bool("disable-loop-idiom-wcslen", false);
    lir_dis_hash = flag_bool("disable-loop-idiom-hashrecognize", false);
    lir_force_pattern = flag_bool("loop-idiom-force-memset-pattern-intrinsic", false);
    lir_mssau = use_mssa;
    if use_mssa { msu_reset(); }
    let changed = lir_run_on_loop(l);
    lir_mssau = false;
    if !changed { return PA_ALL; }
    var pa = ((1 as u32) << A_DOMTREE) | ((1 as u32) << A_LOOPS) | ((1 as u32) << A_SCEV);
    if use_mssa { pa |= (1 as u32) << A_MEMORYSSA; }
    return pa;
}
