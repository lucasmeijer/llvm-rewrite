// SLPVectorizer: generateKeySubkey and its loads subkey generator (GenerateLoadsSubkey), shared by
// HorizontalReduction::matchAssociativeReduction (slp_hr.goose) and reorderGatherNode (slp_transform.goose). Port of
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (generateKeySubkey and the GenerateLoadsSubkey lambdas).
//
// The keys are LLVM hash_codes, of which only equality matters: they are reproduced as 64-bit mixes of the same
// components (hash_value of an integer, of a pointer, hash_combine), so equal inputs give equal keys.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import vt;
import laa;

import tti;
import tti_x86;
import tti_vec;


import vecutils;
import iv_descriptors;
import cfgutil;
import slp_util;
import slp_tree;
import slp_ops;
import slp_loads;


// ---------------------------------------------------------------- hash codes of generateKeySubkey
fn hk_mix(x: u64) -> u64 { var z = x + 0x9E3779B97F4A7C15; z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) * 0x94D049BB133111EB; return z ^ (z >> 31); }
fn hk_int(x: i64) -> u64 { hk_mix(x as u64) }
fn hk_ptr(v: i32) -> u64 { hk_mix((v as u64) + 0x100000000000) }
fn hk_type(t: i32) -> u64 { hk_mix((t as u64) + 0x200000000000) }
fn hk_comb2(a: u64, b: u64) -> u64 { hk_mix(a * 31 + hk_mix(b)) }
fn hk_comb3(a: u64, b: u64, c: u64) -> u64 { hk_comb2(hk_comb2(a, b), c) }
fn hk_comb4(a: u64, b: u64, c: u64, d: u64) -> u64 { hk_comb2(hk_comb3(a, b, c), d) }
// the LoadsMap / LoadKeyUsed of matchAssociativeReduction
var hr_lm_key: u64[>..<];
var hr_lm_ptr: i32[>..<];
var hr_lm_li: i32[>..<];
var hr_lk_used: u64[>..<];
// GenerateLoadsSubkey(Key, LI)
fn hr_loads_subkey(key0: u64, li: i32) -> u64 {
    let key = hk_comb2(hk_int(block_number(inst_parent(li))), key0);
    let ptr = get_underlying_object(op(li, 0), flag_int("slp-recursion-max-depth", 12));
    var used = false;
    for k in hr_lk_used { if k == key { used = true; break; } }
    if used {
        var any = false;
        var lst: i32[>..<] = [];
        for j in hr_lm_key.len { if hr_lm_key[j] == key && hr_lm_ptr[j] == ptr { lst.push(hr_lm_li[j]); any = true; } }
        if any {
            for rli in lst {
                let ok, d = laa_get_pointers_diff(vals[rli].ty, op(rli, 0), vals[li].ty, op(li, 0), true, true);
                if ok { return hk_ptr(op(rli, 0)); }
            }
            for rli in lst { if slp_pointers_compatible(op(rli, 0), op(li, 0), true) { return hk_ptr(op(rli, 0)); } }
            if lst.len > 2 { return hk_ptr(op(lst[lst.len - 1], 0)); }
        }
    } else {
        hr_lk_used.push(key);
    }
    hr_lm_key.push(key); hr_lm_ptr.push(ptr); hr_lm_li.push(li);
    return hk_ptr(op(li, 0));
}
// generateKeySubkey(V, TLI, LoadsSubkeyGenerator, AllowAlternate): (Key, SubKey)
recursive fn hr_key_subkey(v: i32, allow_alt: bool) -> u64, u64 {
    var key = hk_int(slp_value_id(v) + 2);
    var sub = hk_int(0);
    if is_inst_op(v, OP_LOAD) {
        key = hk_comb3(hk_type(vals[v].ty), hk_int(OP_LOAD), key);
        if ld_is_simple(v) { sub = hr_loads_subkey(key, v); } else { key = hk_ptr(v); sub = key; }
        return key, sub;
    }
    if slp_is_vector_like_inst_with_const_ops(v) {
        if is_inst_op(v, OP_EXTRACTELEMENT) || is_undef_or_poison(v) { key = hk_int(12 + 1); }   // Value::UndefValueVal + 1
        if is_inst_op(v, OP_EXTRACTELEMENT) {
            if !slp_is_undef_vector_all(op(v, 0), false) && !is_undef_or_poison(op(v, 1)) { sub = hk_ptr(op(v, 0)); }
        }
        return key, sub;
    }
    if !is_inst(v) { return key, sub; }
    let o = iop(v);
    if (is_binary_op(o) || is_cast_op(o)) && slp_valid_for_alternation(o) {
        if allow_alt { key = hk_int(if is_binary_op(o) { 1 } else { 0 }); } else { key = hk_comb2(hk_int(o), key); }
        sub = hk_comb3(hk_int(o), hk_type(vals[v].ty), hk_type(if is_binary_op(o) { vals[v].ty as i32 } else { vals[op(v, 0)].ty as i32 }));
        if is_cast_op(o) {
            let k2, s2 = hr_key_subkey(op(v, 0), true);
            key = hk_comb2(k2, key);
            sub = hk_comb2(k2, sub);
        }
    } else if o == OP_ICMP || o == OP_FCMP {
        var p = inst_pred(v);
        if slp_cmp_is_commutative(v) { let ip = slp_inverse_pred(p); if ip < p { p = ip; } }
        let sp = slp_swapped_pred(p);
        sub = hk_comb4(hk_int(o), hk_int(p), hk_int(sp), hk_type(vals[op(v, 0)].ty));
    } else if o == OP_CALL {
        let id = laa_vector_intrinsic_id_for_call(v);
        if is_trivially_vectorizable(id) {
            sub = hk_comb2(hk_int(o), hk_int(id as i64));
        } else if slp_is_vf_mapped_call(v) {
            sub = hk_comb2(hk_int(o), hk_ptr(called_function(v)));
        } else {
            key = hk_comb2(hk_ptr(v), key);
            sub = hk_comb2(hk_int(o), hk_ptr(v));
        }
        for k in cb_nbundles(v) {
            sub = hk_comb4(hk_int(cb_bundle_begin(v, k)), hk_int(cb_bundle_begin(v, k) + cb_bundle_count(v, k)),
                           hk_int(cb_bundle_tag(v, k) as i64), sub);
        }
    } else if o == OP_GEP {
        if nops(v) == 2 && is_cint(op(v, 1)) { sub = hk_ptr(op(v, 0)); } else { sub = hk_ptr(v); }
    } else if slp_is_int_div_rem(o) && !is_cint(op(v, 1)) {
        sub = hk_ptr(v);
    } else {
        sub = hk_int(o);
    }
    key = hk_comb2(hk_int(block_number(inst_parent(v))), key);
    return key, sub;
}
fn slp_hk_recursion_guard() {}

// ---------------------------------------------------------------- AnalyzedReductionVals (per function)
var slp_anrv: i32[>..];          // AnalyzedReductionVals sequences (len, values...)
var slp_anrv_lk: SLk[>..];
let SH_ANRV2: i64 = 26;
// AnalyzedReductionVals
fn slp_are_analyzed_reduction_vals(vl: const i32[:]) -> bool {
    let h = slp_vl_hash(vl);
    var c = sh_get(SH_ANRV2, h, 0, -1) as i32;
    while c >= 0 {
        let at = slp_anrv_lk[c].x as i64;
        let n = slp_anrv[at] as i64;
        if n == vl.len {
            var eq = true;
            for k in n { if slp_anrv[at + 1 + k] != vl[k] { eq = false; break; } }
            if eq { return true; }
        }
        c = slp_anrv_lk[c].next;
    }
    return false;
}
fn slp_analyzed_reduction_vals(vl: const i32[:]) {
    if slp_are_analyzed_reduction_vals(vl) { return; }
    let at = slp_anrv.len as i32;
    slp_anrv.push(vl.len as i32);
    for v in vl { slp_anrv.push(v); }
    let h = slp_vl_hash(vl);
    let n = slp_anrv_lk.len as i32;
    slp_anrv_lk.push(SLk { x: at, next: sh_get(SH_ANRV2, h, 0, -1) as i32 });
    sh_set(SH_ANRV2, h, 0, n as i64);
}
// clearReductionData()
fn slp_clear_reduction_data() {
    sh_clear(SH_ANRR); sh_clear(SH_ANRV2); sh_clear(SH_ANMBW);
    slp_anrv.clear(); slp_anrv_lk.clear();
}

// ---------------------------------------------------------------- getRdxKind (shared with computeMinimumValueSizes)
// m_LogicalAnd / m_LogicalOr of a select
fn hr_is_one_value(c: i32) -> bool {
    if is_cint(c) { return ap_is_one(ap_from_cint(c)); }
    if is_constant(c) && ty_is_vector(vals[c].ty) {
        let s = vu_get_splat_value(c);
        return s >= 0 && is_cint(s) && ap_is_one(ap_from_cint(s));
    }
    return false;
}
fn hr_select_logical(i: i32, is_and: bool) -> bool {
    if !is_inst_op(i, OP_SELECT) { return false; }
    let c = op(i, 0);
    if vals[c].ty as i32 != vals[i].ty as i32 { return false; }
    if is_and { let f = op(i, 2); return is_constant(f) && is_null_value(f); }
    return hr_is_one_value(op(i, 1));
}
fn hr_is_i1ish(t: i32) -> bool { ty_is_int(ty_scalar(t)) && ty_bits(ty_scalar(t)) == 1 }
fn hr_m_logical(i: i32, is_and: bool) -> bool {
    if is_inst(i) && iop(i) == (if is_and { OP_AND } else { OP_OR }) && hr_is_i1ish(vals[i].ty) { return true; }
    return hr_select_logical(i, is_and);
}
fn hr_is_bool_logic_op(i: i32) -> bool { is_inst_op(i, OP_SELECT) && (hr_m_logical(i, true) || hr_m_logical(i, false)) }
// getRdxKind(V)
fn hr_rdx_kind(v: i32) -> i32 {
    if !is_inst(v) { return RK_NONE; }
    let o = iop(v);
    if o == OP_ADD { return RK_ADD; }
    if o == OP_MUL { return RK_MUL; }
    if o == OP_AND || hr_m_logical(v, true) { return RK_AND; }
    if o == OP_OR || hr_m_logical(v, false) { return RK_OR; }
    if o == OP_XOR { return RK_XOR; }
    if o == OP_FADD { return RK_FADD; }
    if o == OP_FMUL { return RK_FMUL; }
    let id = inst_iid(v);
    if id == IID_maxnum { return RK_FMAX; }
    if id == IID_minnum { return RK_FMIN; }
    if id == IID_maximum { return RK_FMAXIMUM; }
    if id == IID_minimum { return RK_FMINIMUM; }
    if id == IID_smax { return RK_SMAX; }
    if id == IID_smin { return RK_SMIN; }
    if id == IID_umax { return RK_UMAX; }
    if id == IID_umin { return RK_UMIN; }
    if o == OP_SELECT {
        let lhs = op(v, 1);
        let rhs = op(v, 2);
        let cnd = op(v, 0);
        if !slp_is_cmp(cnd) { return RK_NONE; }
        let c0 = op(cnd, 0);
        let c1 = op(cnd, 1);
        if c0 == lhs && is_inst(c1) {
            if !is_inst_op(rhs, OP_EXTRACTELEMENT) || !cu_identical(c1, rhs) { return RK_NONE; }
        } else if is_inst(c0) && c1 == rhs {
            if !is_inst_op(lhs, OP_EXTRACTELEMENT) || !cu_identical(c0, lhs) { return RK_NONE; }
        } else {
            if !is_inst_op(lhs, OP_EXTRACTELEMENT) || !is_inst_op(rhs, OP_EXTRACTELEMENT) { return RK_NONE; }
            if !is_inst(c0) || !is_inst(c1) || !cu_identical(c0, lhs) || !cu_identical(c1, rhs) { return RK_NONE; }
        }
        let p = inst_pred(cnd);
        if p == 38 || p == 39 { return RK_SMAX; }
        if p == 40 || p == 41 { return RK_SMIN; }
        if p == 34 || p == 35 { return RK_UMAX; }
        if p == 36 || p == 37 { return RK_UMIN; }
        return RK_NONE;
    }
    return RK_NONE;
}
