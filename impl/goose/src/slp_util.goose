// SLPVectorizer helpers: port of the static helpers at the top of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (lines 300-1980: getWidenedType, getFullVectorNumberOfElements, getFloorFullVectorNumberOfElements,
// isCommutative, isCommutableOperand, getNumberOfPotentiallyCommutativeOps, getElementIndex, buildUseMask,
// isUndefVector, isValidForAlternation, BinOpSameOpcodeHelper, InstructionsState, convertTo, getSameOpcode,
// areCompatibleCmpOps, isCmpSameOrSwapped, doesInTreeUserNeedToExtract, isSimple, addMask, fixupOrderingIndices,
// getAltInstrMask, inversePermutation, reorderScalars, areAllOperandsNonInsts, isUsedOutsideBlock,
// doesNotNeedToBeScheduled, doesNotNeedToSchedule, hasFullVectorsOrPowerOf2, getNumberOfParts) and of
// llvm/lib/Transforms/Vectorize/SLPVectorizer/SLPUtils.cpp (isConstant, isVectorLikeInstWithConstOps,
// getNumElements, getPartNumElems, getNumElems, allSameBlock, allConstant, isSplat, allSameOpcode,
// getExtractIndex, allSameType, getInsertExtractIndex), plus the SLP-wide scratch hash table and the
// -debug-only=SLP trace helpers.
//
// REVEC (-slp-revec) is not supported (the option is unknown to us), so every SLPReVec branch is the "off" one.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import datalayout;
import apint;
import pm;
import flags;
import constfold;
import cfold;
import fpu;
import laa;
import vt;
import speculate;
import tti;
import tti_x86;
import tti_x86_vec;
import tti_vec;
import vecutils;

fn slp_fail(what: const u8[:]) { fatal(str("SLPVectorizer: ", what, " is not ported yet")); }

// ---------------------------------------------------------------- the SLP scratch hash table
// Keys are (slot, a, b) triples; an entry is live while its stamp equals its slot's epoch (O(1) clear per slot).
// Nothing iterates it: containers whose order LLVM relies on keep their own arrays.
struct ShEnt { k1: i64, k2: i64, stamp: i32, data: i64 }
var sh_tab: ShEnt[>..<];
var sh_used: i64 = 0;
var sh_shift: u64 = 64;
var sh_epoch: i32[64];
var sh_inited: bool = false;
fn sh_init() {
    if sh_inited { return; }
    for k in 64 { sh_epoch[k] = 1; }
    sh_inited = true;
}
fn sh_clear(s: i64) { sh_init(); sh_epoch[s] += 1; }
fn sh_find(k1: i64, k2: i64) -> i64 {
    if sh_tab.len == 0 { return -1; }
    let mask = sh_tab.len - 1;
    let h = ((k1 as u64) * 0x9E3779B97F4A7C15) ^ ((k2 as u64) * 0xC2B2AE3D27D4EB4F);
    var j = ((h * 0x9E3779B97F4A7C15) >> sh_shift) as i64;
    loop {
        let e = sh_tab[j];
        if (e.k1 == k1 && e.k2 == k2) || e.k1 < 0 { return j; }
        j = (j + 1) & mask;
    }
    return -1;
}
fn sh_live(j: i64) -> bool { j >= 0 && sh_tab[j].k1 >= 0 && sh_tab[j].stamp == sh_epoch[sh_tab[j].k1 & 63] }
fn sh_rehash() {
    sh_init();
    var old: ShEnt[>..<] = [];
    var live: i64 = 0;
    for e in sh_tab {
        if e.k1 >= 0 && e.stamp == sh_epoch[e.k1 & 63] { old.push(e); live++; }
    }
    var n: i64 = if sh_tab.len == 0 { 1024 } else { sh_tab.len };
    while live * 4 > n { n *= 2; }
    var lg: u64 = 0;
    while ((1 as i64) << lg) < n { lg++; }
    sh_shift = 64 - lg;
    sh_tab.clear();
    sh_tab.resize(n, ShEnt { k1: -1, k2: 0, stamp: 0, data: 0 });
    sh_used = 0;
    for e in old {
        let j = sh_find(e.k1, e.k2);
        sh_tab[j] = e;
        sh_used++;
    }
}
fn sh_k1(s: i64, a: i64) -> i64 { (a + 1) * 64 + s }
fn sh_slot(s: i64, a: i64, b: i64) -> i64 {
    sh_init();
    let k1 = sh_k1(s, a);
    var j = sh_find(k1, b);
    if j >= 0 && sh_tab[j].k1 == k1 && sh_tab[j].k2 == b { return j; }
    if (sh_used + 1) * 2 > sh_tab.len { sh_rehash(); j = sh_find(k1, b); }
    sh_tab[j].k1 = k1;
    sh_tab[j].k2 = b;
    sh_tab[j].stamp = 0;
    sh_used++;
    return j;
}
fn sh_has(s: i64, a: i64, b: i64) -> bool { sh_init(); sh_live(sh_find(sh_k1(s, a), b)) }
fn sh_add(s: i64, a: i64, b: i64) -> bool {
    let j = sh_slot(s, a, b);
    if sh_tab[j].stamp == sh_epoch[s] { return false; }
    sh_tab[j].stamp = sh_epoch[s];
    sh_tab[j].data = 0;
    return true;
}
fn sh_del(s: i64, a: i64, b: i64) {
    sh_init();
    let j = sh_find(sh_k1(s, a), b);
    if sh_live(j) { sh_tab[j].stamp = 0; }
}
fn sh_get(s: i64, a: i64, b: i64, dflt: i64) -> i64 {
    sh_init();
    let j = sh_find(sh_k1(s, a), b);
    if sh_live(j) { return sh_tab[j].data; }
    return dflt;
}
fn sh_set(s: i64, a: i64, b: i64, x: i64) {
    let j = sh_slot(s, a, b);
    sh_tab[j].stamp = sh_epoch[s];
    sh_tab[j].data = x;
}

// ---------------------------------------------------------------- -debug-only=SLP traces
// Our opt accepts -debug-only (release LLVM rejects it, so no test uses it); with "SLP" in it the port prints the
// lines LLVM's assertions build prints with -debug-only=SLP, for impl/goose/tools/slp_debug_compare.py.
var slp_dbg_on: bool = false;
fn slp_dbg_init() {
    slp_dbg_on = false;
    if flag_given("debug-only") {
        let s = flag_str("debug-only");
        var i: i64 = 0;
        while i + 3 <= s.len {
            if s[i] == 'S' && s[i + 1] == 'L' && s[i + 2] == 'P' && (i + 3 == s.len || s[i + 3] == ',') { slp_dbg_on = true; }
            i++;
        }
    }
}
fn slp_dbg_flush() { if errbuf.len > 0 { write_stderr(errbuf); errbuf.clear(); } }
fn slp_dv(v: i32) {
    // `OS << *V`: instructions print as their line, other values as operands with their type
    if is_inst(v) { errs_inst(v, inst_func(v)); return; }
    let f = slp_cur_fn;
    errs_operand(v, f, true);
}
var slp_cur_fn: i32 = -1;

// ---------------------------------------------------------------- SLPUtils.cpp

// isConstant(V): a Constant but not a ConstantExpr or GlobalValue
fn slp_is_constant(v: i32) -> bool {
    let k = vals[v].kind as i64;
    return is_constant(v) && k != VK_CEXPR && k != VK_FUNC && k != VK_ALIAS && k != VK_IFUNC && k != VK_GVAR;
}
fn slp_is_undef(v: i32) -> bool { is_undef_or_poison(v) }
fn slp_is_vector_like_inst_with_const_ops(v: i32) -> bool {
    if is_undef_or_poison(v) { return true; }
    if !is_inst(v) { return false; }
    let o = iop(v);
    if o == OP_EXTRACTVALUE || o == OP_INSERTVALUE { return true; }
    if o == OP_EXTRACTELEMENT { return ty_kind(vals[op(v, 0)].ty) == TK_FVEC && slp_is_constant(op(v, 1)); }
    if o == OP_INSERTELEMENT { return ty_kind(vals[op(v, 0)].ty) == TK_FVEC && slp_is_constant(op(v, 2)); }
    return false;
}
// getNumElements(Ty)
fn slp_num_elements(t: i32) -> i64 {
    if ty_kind(t) == TK_FVEC { return ty_count(t); }
    if ty_is_struct(t) && ty_count(t) > 0 && ty_kind(ty_field(t, 0)) == TK_FVEC {
        slp_fail("struct-of-vectors types (isVectorizedTy of a struct)");
    }
    return 1;
}
fn slp_bit_ceil(x: i64) -> i64 { if x <= 1 { return 1; } var r: i64 = 1; while r < x { r *= 2; } return r; }
fn slp_bit_floor(x: i64) -> i64 { if x <= 0 { return 0; } var r: i64 = 1; while r * 2 <= x { r *= 2; } return r; }
fn slp_is_pow2(x: i64) -> bool { x > 0 && (x & (x - 1)) == 0 }
fn slp_div_ceil(a: i64, b: i64) -> i64 { (a + b - 1) / b }
fn slp_part_num_elems(size: i64, nparts: i64) -> i64 { let x = slp_bit_ceil(slp_div_ceil(size, nparts)); return if size < x { size } else { x }; }
fn slp_num_elems(size: i64, part_n: i64, part: i64) -> i64 { let x = size - part * part_n; return if part_n < x { part_n } else { x }; }

fn slp_all_same_block(vl: const i32[:]) -> bool {
    var it: i64 = -1;
    for k in vl.len { if is_inst(vl[k]) { it = k; break; } }
    if it < 0 { return false; }
    var all_vl = true;
    for v in vl { if !slp_is_vector_like_inst_with_const_ops(v) { all_vl = false; break; } }
    if all_vl { return true; }
    let bb = inst_parent(vl[it]);
    for k in it..vl.len {
        let v = vl[k];
        if is_poison(v) { continue; }
        if !is_inst(v) { return false; }
        if inst_parent(v) != bb { return false; }
    }
    return true;
}
fn slp_all_constant(vl: const i32[:]) -> bool { for v in vl { if !slp_is_constant(v) { return false; } } return true; }
fn slp_is_splat(vl: const i32[:]) -> bool {
    var first: i32 = -1;
    for v in vl {
        if is_undef_or_poison(v) { continue; }
        if first < 0 { first = v; continue; }
        if v != first { return false; }
    }
    return first >= 0;
}
fn slp_is_cmp(v: i32) -> bool { is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) }
fn slp_all_same_opcode(vl: const i32[:]) -> bool {
    var it: i64 = -1;
    for k in vl.len { if is_inst(vl[k]) { it = k; break; } }
    if it < 0 { return true; }
    let m = vl[it];
    let o = iop(m);
    let bp: i64 = if slp_is_cmp(m) { inst_pred(m) } else { 42 };
    for k in it..vl.len {
        let v = vl[k];
        if slp_is_cmp(v) { if bp != inst_pred(v) { return false; } continue; }
        if is_inst(v) { if iop(v) != o { return false; } continue; }
        if !is_poison(v) { return false; }
    }
    return true;
}
// getExtractIndex(E): -1 = none
fn slp_extract_index(e: i32) -> i64 {
    if iop(e) == OP_EXTRACTELEMENT {
        let c = op(e, 1);
        if !is_cint(c) { return -1; }
        let a = ap_from_cint(c);
        let vf = slp_num_elements(vals[op(e, 0)].ty);
        if !ap_fits_u64(a) || a.lo >= vf as u64 { return -1; }
        return a.lo as i64;
    }
    let x = insts[inst_of(e)];
    if x.naux != 1 { return -1; }
    return ints[x.aux] as i64;
}
fn slp_all_same_type(vl: const i32[:]) -> bool {
    let t: i32 = vals[vl[0]].ty;
    for k in 1..vl.len { if vals[vl[k]].ty as i32 != t { return false; } }
    return true;
}
// getInsertExtractIndex<InsertElementInst / ExtractElementInst>(Inst, Offset): -1 = none
fn slp_insert_extract_index(v: i32, is_insert: bool, offset: i64) -> i64 {
    if !is_inst(v) { return -1; }
    if is_insert && iop(v) != OP_INSERTELEMENT { return -1; }
    if !is_insert && iop(v) != OP_EXTRACTELEMENT { return -1; }
    let vt: i32 = if is_insert { vals[v].ty } else { vals[op(v, 0)].ty };
    if ty_kind(vt) != TK_FVEC { return -1; }
    let c = op(v, if is_insert { 2 } else { 1 });
    if !is_cint(c) { return -1; }
    let a = ap_from_cint(c);
    if !ap_fits_u64(a) || a.lo >= ty_count(vt) as u64 { return -1; }
    return offset * ty_count(vt) + a.lo as i64;
}

// ---------------------------------------------------------------- SLPVectorizer.cpp helpers

// getWidenedType(ScalarTy, VF) (REVEC off; struct types fail loudly)
fn slp_widened_type(sty: i32, vf: i64) -> i32 {
    if ty_is_struct(sty) { slp_fail("getWidenedType of a struct type"); }
    if ty_kind(sty) == TK_FVEC { return ty_vector(ty_elem(sty), vf * ty_count(sty), false); }
    return ty_vector(sty, vf, false);
}
// TTI::getNumberOfParts
fn slp_tti_number_of_parts(vt: i32) -> i64 {
    // NoTTIImpl (TargetTransformInfoImplBase): 1
    if tti_kind != TTI_X86 { return 1; }
    return x86_number_of_parts(vt);
}
fn slp_full_vector_number_of_elements(ty: i32, sz: i64) -> i64 {
    if !slp_is_valid_element_type(ty) || ty_is_struct(ty) { return slp_bit_ceil(sz); }
    let np = slp_tti_number_of_parts(slp_widened_type(ty, sz));
    if np == 0 || np >= sz { return slp_bit_ceil(sz); }
    return slp_bit_ceil(slp_div_ceil(sz, np)) * np;
}
fn slp_floor_full_vector_number_of_elements(ty: i32, sz: i64) -> i64 {
    if !slp_is_valid_element_type(ty) || ty_is_struct(ty) { return slp_bit_floor(sz); }
    let np = slp_tti_number_of_parts(slp_widened_type(ty, sz));
    if np == 0 || np >= sz { return slp_bit_floor(sz); }
    let rvf = slp_bit_ceil(slp_div_ceil(sz, np));
    if rvf > sz { return slp_bit_floor(sz); }
    return (sz / rvf) * rvf;
}
// hasFullVectorsOrPowerOf2(TTI, Ty, Sz)
fn slp_has_full_vectors_or_pow2(ty: i32, sz: i64) -> bool {
    if sz <= 1 { return false; }
    if !slp_is_valid_element_type(ty) && ty_kind(ty) != TK_FVEC { return false; }
    if slp_is_pow2(sz) { return true; }
    if ty_is_struct(ty) { return false; }
    let np = slp_tti_number_of_parts(slp_widened_type(ty, sz));
    return np > 0 && np < sz && slp_is_pow2(sz / np) && sz % np == 0;
}
// ::getNumberOfParts(TTI, VecTy, ScalarTy, Limit)
fn slp_number_of_parts(vt: i32, sty: i32, limit: i64) -> i64 {
    if ty_is_struct(vt) { return 1; }
    let np = slp_tti_number_of_parts(vt);
    if np == 0 || np >= limit { return 1; }
    let sz = slp_num_elements(vt);
    let ssz = slp_num_elements(sty);
    let et = ty_scalar(vt);
    let pw = slp_full_vector_number_of_elements(et, sz);
    if np >= sz || pw % np != 0 || (pw / np) % ssz != 0 || !slp_has_full_vectors_or_pow2(et, pw / np) { return 1; }
    let ne = pw / np;
    if slp_div_ceil(sz, ne) != np { return 1; }
    return np;
}

// CmpInst predicates
fn slp_swapped_pred(p: i64) -> i64 {
    match p {
        2 => 4, 4 => 2, 3 => 5, 5 => 3,            // OGT/OLT, OGE/OLE
        10 => 12, 12 => 10, 11 => 13, 13 => 11,    // UGT/ULT, UGE/ULE
        34 => 36, 36 => 34, 35 => 37, 37 => 35,    // ugt/ult, uge/ule
        38 => 40, 40 => 38, 39 => 41, 41 => 39,    // sgt/slt, sge/sle
        _ => p,
    }
}
fn slp_inverse_pred(p: i64) -> i64 {
    if p <= 15 { return 15 - p; }
    match p { 32 => 33, 33 => 32, 34 => 37, 37 => 34, 35 => 36, 36 => 35, 38 => 41, 41 => 38, 39 => 40, 40 => 39, _ => p }
}
// CmpInst::isCommutative
fn slp_cmp_is_commutative(i: i32) -> bool {
    let p = inst_pred(i);
    if iop(i) == OP_ICMP { return p == 32 || p == 33; }
    return p == 1 || p == 6 || p == 9 || p == 14 || p == 0 || p == 15 || p == 7 || p == 8;
}
fn slp_is_binop(v: i32) -> bool { is_inst(v) && is_binary_op(iop(v)) }
fn slp_is_int_div_rem(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM }
fn slp_is_fp_div_rem(o: i64) -> bool { o == OP_FDIV || o == OP_FREM }
// Instruction::isCommutative
fn slp_inst_is_commutative(i: i32) -> bool {
    if slp_is_cmp(i) { return slp_cmp_is_commutative(i); }
    let id = inst_iid(i);
    if id != 0 { return slp_intrinsic_is_commutative(id); }
    let o = iop(i);
    return o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL;
}
// IntrinsicInst::isCommutative
fn slp_intrinsic_is_commutative(id: i32) -> bool {
    return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum ||
           id == IID_maximumnum || id == IID_minimumnum || id == IID_smax || id == IID_smin ||
           id == IID_umax || id == IID_umin || id == IID_sadd_sat || id == IID_uadd_sat ||
           id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_smul_with_overflow ||
           id == IID_umul_with_overflow || id == IID_smul_fix || id == IID_umul_fix || id == IID_smul_fix_sat ||
           id == IID_umul_fix_sat || id == IID_fma || id == IID_fmuladd;
}
fn slp_bo_is_commutative_op(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
let SLP_USES_LIMIT: i64 = 64;
fn slp_has_n_uses_or_more(v: i32, n: i64) -> bool {
    var c: i64 = 0;
    var u = vals[v].first_use;
    while u >= 0 { c++; if c >= n { return true; } u = uses[u].next; }
    return false;
}
fn slp_num_uses(v: i32) -> i64 { var c: i64 = 0; var u = vals[v].first_use; while u >= 0 { c++; u = uses[u].next; } return c; }
fn slp_has_one_use(v: i32) -> bool { let u = vals[v].first_use; u >= 0 && uses[u].next < 0 }
// Value::hasOneUser
fn slp_has_one_user(v: i32) -> bool {
    var u = vals[v].first_use;
    if u < 0 { return false; }
    let usr = uses[u].user;
    u = uses[u].next;
    while u >= 0 { if uses[u].user != usr { return false; } u = uses[u].next; }
    return true;
}
fn slp_use_opno(u: i32) -> i64 { (u - vals[uses[u].user].ops) as i64 }
fn slp_is_one_cint(v: i32) -> bool { is_cint(v) && ap_is_one(ap_from_cint(v)) }
fn slp_is_zero_int(v: i32) -> bool { is_cint(v) && cint_is_zero(v) }
// isCommutative(I, ValWithUses, IsCopyable)
fn slp_is_commutative_vu(i: i32, vwu: i32, copyable: bool) -> bool {
    if slp_is_cmp(i) { return slp_cmp_is_commutative(i); }
    if slp_is_binop(i) {
        let o = iop(i);
        if slp_bo_is_commutative_op(o) { return true; }
        if o == OP_SUB && has_use_list(vwu) && !slp_has_n_uses_or_more(vwu, SLP_USES_LIMIT) {
            var all = true;
            var u = vals[vwu].first_use;
            while u >= 0 {
                let usr = uses[u].user;
                let uv = uses[u].val;
                var ok = false;
                if is_inst_op(usr, OP_ICMP) && op(usr, 0) == uv && slp_is_zero_int(op(usr, 1)) &&
                   (inst_pred(usr) == 32 || inst_pred(usr) == 33) {
                    ok = true;
                } else if inst_iid(usr) == IID_abs && cb_arg(usr, 0) == uv && is_cint(cb_arg(usr, 1)) {
                    let flag_one = slp_is_one_cint(cb_arg(usr, 1));
                    let bo = slp_is_binop(uv);
                    ok = (!copyable && bo && (insts[inst_of(uv)].flags & FL_NSW) == 0) || flag_one;
                }
                if !ok { all = false; break; }
                u = uses[u].next;
            }
            if all { return true; }
        }
        if o == OP_FSUB && has_use_list(vwu) && !slp_has_n_uses_or_more(vwu, SLP_USES_LIMIT) {
            var all = true;
            var u = vals[vwu].first_use;
            while u >= 0 {
                let usr = uses[u].user;
                if !(inst_iid(usr) == IID_fabs && cb_arg(usr, 0) == uses[u].val) { all = false; break; }
                u = uses[u].next;
            }
            if all { return true; }
        }
        return false;
    }
    return slp_inst_is_commutative(i);
}
fn slp_is_commutative(i: i32) -> bool { slp_is_commutative_vu(i, i, false) }
// isCommutableOperand(I, ValWithUses, Op, IsCopyable)
fn slp_is_commutable_operand(i: i32, op_: i64) -> bool {
    if slp_is_cmp(i) { return true; }
    if slp_is_binop(i) && (iop(i) == OP_SUB || iop(i) == OP_FSUB) { return true; }
    // Instruction::isCommutableOperand: the first two operands of a commutative instruction
    return op_ < 2;
}
// getNumberOfPotentiallyCommutativeOps(I)
fn slp_num_potentially_commutative_ops(i: i32) -> i64 {
    if inst_iid(i) != 0 && slp_is_commutative(i) { return 2; }
    return nops(i);
}
// getElementIndex(Inst, Offset): -1 = none
fn slp_element_index(v: i32, offset: i64) -> i64 {
    let a = slp_insert_extract_index(v, true, offset);
    if a >= 0 { return a; }
    let b = slp_insert_extract_index(v, false, offset);
    if b >= 0 { return b; }
    if !is_inst_op(v, OP_INSERTVALUE) { return -1; }
    var index = offset;
    var cur: i32 = vals[v].ty;
    let x = insts[inst_of(v)];
    for k in x.naux {
        let i = ints[x.aux + k] as i64;
        if ty_is_struct(cur) {
            index *= ty_count(cur);
            cur = ty_field(cur, i);
        } else if ty_is_array(cur) {
            index *= ty_count(cur);
            cur = ty_elem(cur);
        } else {
            return -1;
        }
        index += i;
    }
    return index;
}
// isUndefVector<IsPoisonOnly>(V).all() with an empty UseMask: LLVM's result bitvector has a single bit, and resets
// beyond it are masked off, so only lane 0 of a constant vector decides.
fn slp_is_undef_vector_all(v: i32, poison_only: bool) -> bool {
    if poison_only { if is_poison(v) { return true; } } else { if is_undef_or_poison(v) { return true; } }
    if ty_kind(vals[v].ty) != TK_FVEC { return false; }
    if !is_constant(v) { return false; }
    let e = c_aggregate_element(v, 0);
    if e >= 0 {
        let u = if poison_only { is_poison(e) } else { is_undef_or_poison(e) };
        if !u { return false; }
    }
    return true;
}
// isValidForAlternation(Opcode)
fn slp_valid_for_alternation(o: i64) -> bool { !slp_is_int_div_rem(o) }

// ---------------------------------------------------------------- BinOpSameOpcodeHelper
let BO_SHL: u32 = 1;
let BO_ASHR: u32 = 2;
let BO_MUL: u32 = 4;
let BO_ADD: u32 = 8;
let BO_SUB: u32 = 16;
let BO_AND: u32 = 32;
let BO_OR: u32 = 64;
let BO_XOR: u32 = 128;
let BO_FADD: u32 = 256;
let BO_FSUB: u32 = 512;
let BO_MAIN: u32 = 1024;
let BO_ALL: u32 = 2047;
let BO_CAN_BE_ALL: u32 = 255;
struct BoInfo { i: i32, mask: u32, seen: u32 }
struct BoHelper { main: BoInfo, alt: BoInfo }
fn bo_info(i: i32) -> BoInfo { BoInfo { i: i, mask: BO_ALL, seen: 0 } }
fn bo_helper(main: i32, alt: i32) -> BoHelper { BoHelper { main: bo_info(main), alt: bo_info(alt) } }
fn bo_try_set(x: BoInfo&, opm: u32, im: u32) -> bool {
    if (x.mask & im) != 0 { x.seen |= opm; x.mask &= im; return true; }
    return false;
}
fn bo_equal(x: BoInfo&, o: i64) -> bool { o == iop(x.i) && bo_try_set(x, BO_MAIN, BO_MAIN) }
fn bo_opcode(x: BoInfo) -> i64 {
    let c = x.mask & x.seen;
    if (c & BO_MAIN) != 0 { return iop(x.i); }
    if (c & BO_SHL) != 0 { return OP_SHL; }
    if (c & BO_ASHR) != 0 { return OP_ASHR; }
    if (c & BO_MUL) != 0 { return OP_MUL; }
    if (c & BO_ADD) != 0 { return OP_ADD; }
    if (c & BO_SUB) != 0 { return OP_SUB; }
    if (c & BO_FADD) != 0 { return OP_FADD; }
    if (c & BO_FSUB) != 0 { return OP_FSUB; }
    if (c & BO_AND) != 0 { return OP_AND; }
    if (c & BO_OR) != 0 { return OP_OR; }
    if (c & BO_XOR) != 0 { return OP_XOR; }
    fatal("internal: SLP: cannot find interchangeable instruction");
    return 0;
}
fn bo_has_defined_opcode(x: BoInfo) -> bool { (x.mask & x.seen) > 0 }
fn bo_has_candidate_opcode(x: BoInfo, o: i64) -> bool {
    let c = x.mask & x.seen;
    if o == OP_SHL { return (c & BO_SHL) != 0; }
    if o == OP_ASHR { return (c & BO_ASHR) != 0; }
    if o == OP_MUL { return (c & BO_MUL) != 0; }
    if o == OP_ADD { return (c & BO_ADD) != 0; }
    if o == OP_SUB { return (c & BO_SUB) != 0; }
    if o == OP_AND { return (c & BO_AND) != 0; }
    if o == OP_OR { return (c & BO_OR) != 0; }
    if o == OP_XOR { return (c & BO_XOR) != 0; }
    if o == OP_FADD { return (c & BO_FADD) != 0; }
    if o == OP_FSUB { return (c & BO_FSUB) != 0; }
    if o == OP_LSHR || o == OP_FMUL || o == OP_SDIV || o == OP_UDIV || o == OP_FDIV || o == OP_SREM || o == OP_UREM || o == OP_FREM { return false; }
    fatal("internal: SLP: cannot find interchangeable instruction");
    return false;
}
// isBinOpWithConstant(I): (constant or -1, position)
fn bo_with_constant(i: i32) -> i32, i64 {
    let c1 = op(i, 1);
    if is_cint(c1) || vals[c1].kind == VK_CFP { return c1, 1; }
    if !slp_is_commutative(i) { return -1, 0; }
    let c0 = op(i, 0);
    if is_cint(c0) || vals[c0].kind == VK_CFP { return c0, 0; }
    return -1, 0;
}
// InterchangeableInfo::getOperand(To): the two converted operands
fn bo_get_operand(x: BoInfo, to: i32) -> i32, i32 {
    let i = x.i;
    let tooc = iop(to);
    let fromoc = iop(i);
    if fromoc == tooc { return op(i, 0), op(i, 1); }
    let c, pos = bo_with_constant(i);
    let rty: i32 = vals[op(i, pos)].ty;
    var rhs: i32 = -1;
    if vals[c].kind == VK_CFP {
        let lo, hi = fp_neg_bits(fp_kind_ty(rty), cint_lo(c), cint_hi(c));
        rhs = c_fp(rty, lo, hi);
    } else {
        let a = ap_from_cint(c);
        let w = a.w as i64;
        if fromoc == OP_SHL {
            if tooc == OP_ADD && ap_is_one(a) { return op(i, 0), op(i, 0); }
            if tooc == OP_MUL {
                rhs = ap_to_cint(rty, ap_one_bit(w, ap_zext64(a) as i64));
            } else {
                rhs = binop_identity(tooc, rty, true);
            }
        } else if fromoc == OP_MUL {
            if tooc == OP_SHL {
                rhs = ap_to_cint(rty, ap_u64(ap_log2(a) as u64, w));
            } else {
                rhs = binop_identity(tooc, rty, true);
            }
        } else if fromoc == OP_ADD || fromoc == OP_SUB {
            if ap_is_zero(a) {
                rhs = binop_identity(tooc, rty, true);
            } else {
                rhs = ap_to_cint(rty, ap_neg(a));
            }
        } else {
            rhs = binop_identity(tooc, rty, true);
        }
    }
    let lhs = op(i, 1 - pos);
    if pos == 1 || !slp_bo_is_commutative_op(tooc) { return lhs, rhs; }
    return rhs, lhs;
}
fn boh_valid_for_alternation(h: BoHelper, i: i32) -> bool { slp_valid_for_alternation(iop(h.main.i)) && slp_valid_for_alternation(iop(i)) }
fn boh_init_alt(h: BoHelper&, i: i32) -> bool {
    if h.alt.i >= 0 { return true; }
    if !boh_valid_for_alternation(h, i) { return false; }
    h.alt.i = i;
    return true;
}
fn boh_add(h: BoHelper&, i: i32) -> bool {
    let o = iop(i);
    var opm: u32 = 0;
    if o == OP_SHL { opm = BO_SHL; } else if o == OP_ASHR { opm = BO_ASHR; } else if o == OP_MUL { opm = BO_MUL; }
    else if o == OP_ADD { opm = BO_ADD; } else if o == OP_SUB { opm = BO_SUB; } else if o == OP_AND { opm = BO_AND; }
    else if o == OP_OR { opm = BO_OR; } else if o == OP_XOR { opm = BO_XOR; } else if o == OP_FADD { opm = BO_FADD; }
    else if o == OP_FSUB { opm = BO_FSUB; }
    if opm == 0 {
        if bo_equal(h.main, o) { return true; }
        return boh_init_alt(h, i) && bo_equal(h.alt, o);
    }
    var im = opm;
    let c, pos = bo_with_constant(i);
    if c >= 0 && is_cint(c) {
        let a = ap_from_cint(c);
        let w = a.w as i64;
        if o == OP_SHL {
            if ap_ult_u64(a, w as u64) { im = if ap_is_zero(a) { BO_CAN_BE_ALL } else { BO_MUL | BO_SHL }; }
            if ap_is_one(a) { im |= BO_ADD; }
        } else if o == OP_MUL {
            if ap_is_one(a) { im = BO_CAN_BE_ALL; } else if ap_is_pow2(a) { im = BO_MUL | BO_SHL; }
        } else if o == OP_ADD || o == OP_SUB {
            im = if ap_is_zero(a) { BO_CAN_BE_ALL } else { BO_SUB | BO_ADD };
        } else if o == OP_AND {
            if ap_is_all_ones(a) { im = BO_CAN_BE_ALL; }
        } else if o == OP_XOR {
            if ap_is_zero(a) { im = BO_XOR | BO_OR | BO_SUB | BO_ADD; }
        } else {
            if ap_is_zero(a) { im = BO_CAN_BE_ALL; }
        }
    } else if c >= 0 && pos == 1 {
        im = BO_FSUB | BO_FADD;
    }
    if bo_try_set(h.main, opm, im) { return true; }
    return boh_init_alt(h, i) && bo_try_set(h.alt, opm, im);
}
fn boh_main_opcode(h: BoHelper) -> i64 { bo_opcode(h.main) }
fn boh_has_defined_main(h: BoHelper) -> bool { bo_has_defined_opcode(h.main) }
fn boh_has_candidate(h: BoHelper, o: i64) -> bool { bo_has_candidate_opcode(h.main, o) }
fn boh_has_alt(h: BoHelper) -> bool { h.alt.i >= 0 }
fn boh_alt_opcode(h: BoHelper) -> i64 { if boh_has_alt(h) { bo_opcode(h.alt) } else { boh_main_opcode(h) } }
fn boh_has_defined_alt(h: BoHelper) -> bool { !boh_has_alt(h) || bo_has_defined_opcode(h.alt) }

// ---------------------------------------------------------------- InstructionsState
struct SIS { main: i32, alt: i32, copy: bool }
fn sis_invalid() -> SIS { SIS { main: -1, alt: -1, copy: false } }
fn sis_valid(s: SIS) -> bool { s.main >= 0 && s.alt >= 0 }
fn sis_opcode(s: SIS) -> i64 { iop(s.main) }
fn sis_alt_opcode(s: SIS) -> i64 { iop(s.alt) }
fn sis_is_alt_shuffle(s: SIS) -> bool { s.main != s.alt }
// getMatchingMainOpOrAltOp(I): -1 = none
fn sis_matching(s: SIS, i: i32) -> i32 {
    if iop(i) == iop(s.main) { return s.main; }
    if iop(s.main) == OP_SELECT && iop(i) == OP_ZEXT && !sis_is_alt_shuffle(s) { return s.main; }
    if iop(i) == iop(s.alt) { return s.alt; }
    if !slp_is_binop(i) { return -1; }
    var conv = bo_helper(s.main, -1);
    if !boh_add(conv, i) || !boh_add(conv, s.main) { return -1; }
    if sis_is_alt_shuffle(s) && !boh_has_candidate(conv, iop(s.main)) {
        var ac = bo_helper(s.alt, -1);
        if boh_add(ac, i) && boh_add(ac, s.alt) && boh_has_candidate(ac, iop(s.alt)) { return s.alt; }
    }
    if boh_has_alt(conv) && !sis_is_alt_shuffle(s) { return -1; }
    return if boh_has_alt(conv) { s.alt } else { s.main };
}
fn sis_is_shift_op(s: SIS) -> bool { let a = iop(s.main); let b = iop(s.alt); (a == OP_SHL || a == OP_LSHR || a == OP_ASHR) && (b == OP_SHL || b == OP_LSHR || b == OP_ASHR) }
fn sis_is_bitwise_logic_op(s: SIS) -> bool { let a = iop(s.main); let b = iop(s.alt); (a == OP_AND || a == OP_OR || a == OP_XOR) && (b == OP_AND || b == OP_OR || b == OP_XOR) }
fn slp_is_muldiv(o: i64) -> bool { o == OP_MUL || o == OP_FMUL || o == OP_SDIV || o == OP_UDIV || o == OP_FDIV || o == OP_SREM || o == OP_UREM || o == OP_FREM }
fn sis_is_muldiv_like_op(s: SIS) -> bool { slp_is_muldiv(sis_opcode(s)) && slp_is_muldiv(sis_alt_opcode(s)) }
fn slp_is_addsub(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_FADD || o == OP_FSUB }
fn sis_is_addsub_like_op(s: SIS) -> bool { slp_is_addsub(sis_opcode(s)) && slp_is_addsub(sis_alt_opcode(s)) }
fn sis_is_cmp_op(s: SIS) -> bool { (sis_opcode(s) == OP_ICMP || sis_opcode(s) == OP_FCMP) && sis_alt_opcode(s) == sis_opcode(s) }
// isCopyableElement(V)
fn sis_is_copyable_element(s: SIS, v: i32) -> bool {
    if !s.copy { return false; }
    if sis_is_alt_shuffle(s) || sis_opcode(s) == OP_GEP { return false; }
    if !is_inst(v) { return !is_poison(v); }
    if inst_parent(v) != inst_parent(s.main) &&
       (!slp_is_vector_like_inst_with_const_ops(v) || !slp_is_vector_like_inst_with_const_ops(s.main)) { return true; }
    if iop(v) == iop(s.main) { return false; }
    if !slp_is_binop(v) { return true; }
    var conv = bo_helper(s.main, -1);
    return !boh_add(conv, v) || !boh_add(conv, s.main) || boh_has_alt(conv) || !boh_has_candidate(conv, sis_opcode(s));
}
// isExpandedBinOp(V)
fn sis_is_expanded_binop(s: SIS, v: i32) -> bool {
    if sis_is_copyable_element(s, v) { return false; }
    if !is_inst(v) { return false; }
    let m = sis_matching(s, v);
    if m < 0 { fatal("internal: SLP: the instruction should be compatible with either main or alt op"); }
    if iop(m) == OP_ADD && iop(v) == OP_SHL { return slp_is_one_cint(op(v, 1)); }
    return false;
}
fn sis_is_expanded_operand(s: SIS, i: i32, idx: i64) -> bool {
    if iop(i) == OP_SHL { return idx == 1; }
    fatal("internal: SLP: unexpected opcode for an expanded operand");
    return false;
}
// isNonSchedulable(V)
fn sis_is_non_schedulable(s: SIS, v: i32) -> bool {
    if !s.copy { return !is_inst(v) || iop(v) == OP_PHI || slp_is_vector_like_inst_with_const_ops(v) || slp_does_not_need_to_be_scheduled(v); }
    if s.main == v { return false; }
    if sis_is_copyable_element(s, v) {
        return !is_inst(v) || iop(v) == OP_PHI || inst_parent(v) != inst_parent(s.main) ||
               (slp_does_not_need_to_be_scheduled(v) && !slp_comes_before(s.main, v));
    }
    return !is_inst(v) || iop(v) == OP_PHI || slp_is_vector_like_inst_with_const_ops(v) || slp_does_not_need_to_be_scheduled(v);
}
// Instruction::comesBefore (same block)
fn slp_comes_before(a: i32, b: i32) -> bool {
    var x = inst_next(a);
    while x >= 0 { if x == b { return true; } x = inst_next(x); }
    return false;
}
// convertTo(I, S): the matching main/alt op and, for a binary operator, its two converted operands (other
// instructions keep their own operands)
fn slp_convert_to(i: i32, s: SIS) -> i32, i32, i32 {
    let sel = sis_matching(s, i);
    if sel < 0 { fatal("internal: SLP: cannot convert the instruction"); }
    if slp_is_binop(i) {
        let x = bo_info(i);
        let a, b = bo_get_operand(x, sel);
        return sel, a, b;
    }
    return sel, -1, -1;
}

// findInstructionWithOpcode(VL, Opcode)
fn slp_find_inst_with_opcode(vl: const i32[:], o: i64) -> i32 {
    for v in vl {
        if is_poison(v) { continue; }
        if iop(v) == o { return v; }
    }
    return -1;
}
// areCompatibleCmpOps
recursive fn slp_compatible_cmp_ops(b0: i32, b1: i32, o0: i32, o1: i32) -> bool {
    if slp_is_constant(b0) && slp_is_constant(o0) { return true; }
    if slp_is_constant(b1) && slp_is_constant(o1) { return true; }
    if !is_inst(b0) && !is_inst(o0) && !is_inst(b1) && !is_inst(o1) { return true; }
    if b0 == o0 || b1 == o1 { return true; }
    let p0: i32[2] = [b0, o0];
    if sis_valid(slp_get_same_opcode(p0[..])) { return true; }
    let p1: i32[2] = [b1, o1];
    return sis_valid(slp_get_same_opcode(p1[..]));
}
// isCmpSameOrSwapped(BaseCI, CI)
recursive fn slp_cmp_same_or_swapped(base: i32, ci: i32) -> bool {
    let bp = inst_pred(base);
    let p = inst_pred(ci);
    let sp = slp_swapped_pred(p);
    let b0 = op(base, 0);
    let b1 = op(base, 1);
    let o0 = op(ci, 0);
    let o1 = op(ci, 1);
    return (bp == p && slp_compatible_cmp_ops(b0, b1, o0, o1)) || (bp == sp && slp_compatible_cmp_ops(b0, b1, o1, o0));
}
fn slp_is_vf_mapped_call(c: i32) -> bool {
    if call_has_fn_str_attr(c, "vector-function-abi-variant") { slp_fail("VFDatabase::getMappings (vector-function-abi-variant)"); }
    return false;
}
fn slp_pred_bit(p: i64) -> u64 { (1 as u64) << (p as u64) }
fn slp_popcount(x: u64) -> i64 { var n: i64 = 0; var y = x; while y != 0 { y &= y - 1; n++; } return n; }
// getSameOpcode(VL, TLI)
recursive fn slp_get_same_opcode(vl: const i32[:]) -> SIS {
    for v in vl { if !is_inst(v) && !is_poison(v) { return sis_invalid(); } }
    var it: i64 = -1;
    for k in vl.len { if is_inst(vl[k]) { it = k; break; } }
    if it < 0 { return sis_invalid(); }
    var main = vl[it];
    var inst_cnt: i64 = 0;
    for k in it..vl.len { if is_inst(vl[k]) { inst_cnt++; } }
    if (vl.len > 2 && iop(main) != OP_PHI && inst_cnt < vl.len / 2) || (vl.len == 2 && inst_cnt < 2) { return sis_invalid(); }
    let is_cast = is_cast_op(iop(main));
    let is_bin = slp_is_binop(main);
    let is_cmp = slp_is_cmp(main);
    let base_pred: i64 = if is_cmp { inst_pred(main) } else { 42 };
    var alt = main;
    let opcode = iop(main);
    var alt_opcode = opcode;
    var helper = bo_helper(main, -1);
    var swapped_compatible = false;
    if is_cmp {
        // UniquePreds / UniqueNonSwappedPreds as predicate bit sets
        var uniq: u64 = slp_pred_bit(base_pred);
        var uniq_ns: u64 = slp_pred_bit(base_pred);
        var ok = true;
        for v in vl {
            if !slp_is_cmp(v) { ok = false; break; }
            let cp = inst_pred(v);
            let scp = slp_swapped_pred(cp);
            uniq_ns |= slp_pred_bit(cp);
            if (uniq & slp_pred_bit(cp)) == 0 && (uniq & slp_pred_bit(scp)) == 0 { uniq |= slp_pred_bit(cp); }
        }
        swapped_compatible = ok && slp_popcount(uniq_ns) > 2 && slp_popcount(uniq) == 2;
    }
    var base_id: i32 = 0;
    if is_inst_op(main, OP_CALL) {
        base_id = laa_vector_intrinsic_id_for_call(main);
        let mapped = slp_is_vf_mapped_call(main);
        if !is_trivially_vectorizable(base_id) && !mapped { return sis_invalid(); }
    }
    let any_poison = inst_cnt != vl.len;
    for k in it..vl.len {
        let i = vl[k];
        if !is_inst(i) { continue; }
        let io = iop(i);
        if any_poison && (slp_is_int_div_rem(io) || slp_is_fp_div_rem(io) || io == OP_CALL) { return sis_invalid(); }
        if is_bin && slp_is_binop(i) {
            if boh_add(helper, i) { continue; }
        } else if is_cast && is_cast_op(io) {
            let ty0: i32 = vals[op(main, 0)].ty;
            let ty1: i32 = vals[op(i, 0)].ty;
            if ty0 == ty1 {
                if io == opcode || io == alt_opcode { continue; }
                if opcode == alt_opcode {
                    alt_opcode = io;
                    alt = i;
                    continue;
                }
            }
        } else if slp_is_cmp(i) && is_cmp {
            let ty0: i32 = vals[op(main, 0)].ty;
            let ty1: i32 = vals[op(i, 0)].ty;
            if ty0 == ty1 {
                let cp = inst_pred(i);
                let scp = slp_swapped_pred(cp);
                if (vl.len == 2 || swapped_compatible) && (base_pred == cp || base_pred == scp) { continue; }
                if slp_cmp_same_or_swapped(main, i) { continue; }
                if main != alt {
                    if slp_cmp_same_or_swapped(alt, i) { continue; }
                } else if base_pred != cp {
                    alt = i;
                    continue;
                }
                let ap = inst_pred(alt);
                if base_pred == cp || base_pred == scp || ap == cp || ap == scp { continue; }
            }
        } else if io == opcode {
            if io == OP_GEP {
                if nops(i) != 2 || vals[op(i, 0)].ty as i32 != vals[op(main, 0)].ty as i32 { return sis_invalid(); }
            } else if io == OP_EXTRACTELEMENT {
                if !slp_is_vector_like_inst_with_const_ops(i) { return sis_invalid(); }
            } else if io == OP_LOAD {
                if !ld_is_simple(i) || !ld_is_simple(main) { return sis_invalid(); }
            } else if io == OP_CALL {
                if called_function(i) != called_function(main) { return sis_invalid(); }
                if cb_nbundles(i) > 0 {
                    if cb_nbundles(main) == 0 { return sis_invalid(); }
                    if !slp_same_bundle_operands(i, main) { return sis_invalid(); }
                }
                let id = laa_vector_intrinsic_id_for_call(i);
                if id != base_id { return sis_invalid(); }
                if id == 0 {
                    // VFDatabase mappings: none without vector-function-abi-variant (fails loudly with it)
                    let m1 = slp_is_vf_mapped_call(i);
                    if m1 { return sis_invalid(); }
                }
            }
            continue;
        }
        return sis_invalid();
    }
    if is_bin {
        if !boh_has_defined_main(helper) || !boh_has_defined_alt(helper) { return sis_invalid(); }
        main = slp_find_inst_with_opcode(vl, boh_main_opcode(helper));
        alt = slp_find_inst_with_opcode(vl, boh_alt_opcode(helper));
        if main < 0 || alt < 0 { fatal("internal: SLP: cannot find MainOp/AltOp with the opcode from BinOpHelper"); }
    }
    return SIS { main: main, alt: alt, copy: false };
}
// std::equal of the bundle operands of two calls (from a's bundle operands start)
fn slp_same_bundle_operands(a: i32, b: i32) -> bool {
    let n = cb_bundle_ops(a);
    let sa = if cb_nbundles(a) > 0 { cb_bundle_begin(a, 0) } else { 0 };
    let sb = if cb_nbundles(b) > 0 { cb_bundle_begin(b, 0) } else { 0 };
    if sb + n > nops(b) { return false; }
    for k in n { if op(a, sa + k) != op(b, sb + k) { return false; } }
    return true;
}
fn slp_same_opcode2(a: i32, b: i32) -> SIS {
    let p: i32[2] = [a, b];
    return slp_get_same_opcode(p[..]);
}
fn slp_same_opcode1(a: i32) -> SIS {
    let p: i32[1] = [a];
    return slp_get_same_opcode(p[..]);
}

// isMainInstruction / isAlternateInstruction (SLPVectorizer.cpp 14047)
fn slp_is_alternate_instruction(i: i32, main: i32, alt: i32) -> bool {
    if slp_is_cmp(main) {
        if slp_cmp_same_or_swapped(main, i) { return false; }
        if slp_cmp_same_or_swapped(alt, i) { return true; }
        let p = inst_pred(i);
        let sp = slp_swapped_pred(p);
        let mp = inst_pred(main);
        return mp != p && mp != sp;
    }
    let s = SIS { main: main, alt: alt, copy: false };
    return sis_matching(s, i) == alt;
}
fn slp_is_main_instruction(i: i32, main: i32, alt: i32) -> bool {
    let s = SIS { main: main, alt: alt, copy: false };
    return sis_matching(s, i) == main;
}

// isSimple(I)
fn slp_is_simple(i: i32) -> bool {
    let o = iop(i);
    if o == OP_LOAD || o == OP_STORE { return ld_is_simple(i); }
    let id = inst_iid(i);
    if id == IID_memcpy || id == IID_memmove || id == IID_memset || id == IID_memcpy_inline || id == IID_memset_inline {
        return !slp_mem_intrinsic_volatile(i);
    }
    return true;
}
fn slp_mem_intrinsic_volatile(i: i32) -> bool {
    let v = cb_arg(i, 3);
    return is_cint(v) && !cint_is_zero(v);
}
// addMask(Mask, SubMask, ExtendingManyInputs)
fn slp_add_mask(mask: i32[>..<]&, sub: const i32[:], many: bool) {
    if sub.len == 0 { return; }
    if mask.len == 0 { for x in sub { mask.push(x); } return; }
    var nm: i32[>..<] = [];
    for k in sub.len { nm.push(-1); }
    let tv: i64 = if mask.len < sub.len { mask.len } else { sub.len };
    for i in sub.len {
        if sub[i] == -1 { continue; }
        if !many && ((sub[i] as i64) >= tv || (mask[sub[i] as i64] as i64) >= tv) { continue; }
        nm[i] = mask[sub[i] as i64];
    }
    mask.clear();
    for x in nm { mask.push(x); }
}
// fixupOrderingIndices(Order)
fn slp_fixup_ordering_indices(order: i32[>..<]&) {
    let sz = order.len;
    var unused: bool[>..<] = [];
    var masked: bool[>..<] = [];
    for k in sz { unused.push(true); masked.push(false); }
    var any = false;
    for i in sz {
        if (order[i] as i64) < sz { unused[order[i] as i64] = false; } else { masked[i] = true; any = true; }
    }
    if !any { return; }
    var idx: i64 = 0;
    while idx < sz && !unused[idx] { idx++; }
    for mi in sz {
        if !masked[mi] { continue; }
        order[mi] = idx as i32;
        idx++;
        while idx < sz && !unused[idx] { idx++; }
    }
}
// inversePermutation(Indices, Mask)
fn slp_inverse_permutation(ind: const i32[:], mask: i32[>..<]&) {
    mask.clear();
    for k in ind.len { mask.push(-1); }
    for i in ind.len { mask[ind[i] as i64] = i as i32; }
}
// reorderScalars(Scalars, Mask) in place on a run of the value pool
fn slp_reorder_scalars(sc: i32[>..<]&, mask: const i32[:]) {
    var prev: i32[>..<] = [];
    for x in sc { prev.push(x); }
    let pz = c_poison(vals[sc[0]].ty);
    for k in sc.len { sc[k] = pz; }
    for i in prev.len { if mask[i] != -1 { sc[mask[i] as i64] = prev[i]; } }
}
// mayHaveNonDefUseDependency (ValueTracking.cpp)
fn slp_may_have_non_def_use_dependency(i: i32) -> bool {
    if inst_may_read_or_write_memory(i) { return true; }
    if !spec_safe(i, -1, false) { return true; }
    return !guaranteed_to_transfer(i);
}
fn slp_are_all_operands_non_insts(v: i32) -> bool {
    if !is_inst(v) { return true; }
    if slp_may_have_non_def_use_dependency(v) { return false; }
    for k in nops(v) {
        let o = op(v, k);
        if !is_inst(o) { continue; }
        if !(iop(o) == OP_PHI || inst_parent(o) != inst_parent(v)) { return false; }
    }
    return true;
}
fn slp_is_used_outside_block(v: i32) -> bool {
    if !is_inst(v) { return true; }
    if inst_may_read_or_write_memory(v) || slp_has_n_uses_or_more(v, SLP_USES_LIMIT) { return false; }
    var u = vals[v].first_use;
    while u >= 0 {
        let usr = uses[u].user;
        if is_inst(usr) && !(inst_parent(usr) != inst_parent(v) || iop(usr) == OP_PHI) { return false; }
        u = uses[u].next;
    }
    return true;
}
fn slp_does_not_need_to_be_scheduled(v: i32) -> bool { slp_are_all_operands_non_insts(v) && slp_is_used_outside_block(v) }
fn slp_does_not_need_to_schedule(vl: const i32[:]) -> bool {
    if vl.len == 0 { return false; }
    var a = true;
    for v in vl { if !slp_is_used_outside_block(v) { a = false; break; } }
    if a { return true; }
    for v in vl { if !slp_are_all_operands_non_insts(v) { return false; } }
    return true;
}
// getAltInstrMask(VL, ScalarTy, Opcode0, Opcode1)
fn slp_alt_instr_mask(vl: const i32[:], sty: i32, o1: i64, out: bool[>..<]&) {
    let n = slp_num_elements(sty);
    out.clear();
    for k in vl.len * n { out.push(false); }
    for l in vl.len {
        if is_poison(vl[l]) { continue; }
        if iop(vl[l]) == o1 { for j in n { out[l * n + j] = true; } }
    }
}
// Type::getTypeID (Type.h enum order)
fn slp_type_id(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_HALF { return 0; } if k == TK_BFLOAT { return 1; } if k == TK_FLOAT { return 2; } if k == TK_DOUBLE { return 3; }
    if k == TK_X86_FP80 { return 4; } if k == TK_FP128 { return 5; } if k == TK_PPC_FP128 { return 6; } if k == TK_VOID { return 7; }
    if k == TK_LABEL { return 8; } if k == TK_METADATA { return 9; } if k == TK_X86_AMX { return 10; } if k == TK_TOKEN { return 11; }
    if k == TK_INT { return 12; } if k == TK_BYTE { return 13; } if k == TK_FUNC { return 14; } if k == TK_PTR { return 15; }
    if k == TK_STRUCT { return 16; } if k == TK_ARRAY { return 17; } if k == TK_FVEC { return 18; } if k == TK_SVEC { return 19; }
    return 21;
}

// VectorType::isValidElementType
fn slp_valid_vector_element(t: i32) -> bool {
    let k = ty_kind(t);
    if ty_is_int(t) || ty_is_fp(t) || k == TK_PTR || k == TK_BYTE { return true; }
    if k == TK_TARGETEXT { slp_not_ported("TargetExtType::CanBeVectorElement"); }
    return false;
}
// isValidElementType(Ty) (SLPReVec is off): canVectorizeTy(Ty) && !x86_fp80 && !ppc_fp128 && !void
fn slp_is_valid_element_type(t: i32) -> bool {
    var can = false;
    if ty_is_struct(t) {
        let n = ty_count(t);
        can = n > 0 && (types[t].flags & TF_NAMED) == 0 && (types[t].flags & TF_PACKED) == 0;
        if can { for k in n { if !slp_valid_vector_element(ty_field(t, k)) { can = false; } } }
    } else {
        can = ty_kind(t) == TK_VOID || slp_valid_vector_element(t);
    }
    let k = ty_kind(t);
    return can && k != TK_X86_FP80 && k != TK_PPC_FP128 && k != TK_VOID;
}

// getValueType(V, LookThroughCmp)
fn slp_value_type(v: i32, look_through_cmp: bool) -> i32 {
    if is_inst_op(v, OP_STORE) { return vals[op(v, 0)].ty; }
    if is_inst_op(v, OP_INSERTELEMENT) { return vals[op(v, 1)].ty; }
    if look_through_cmp && is_inst(v) && (iop(v) == OP_ICMP || iop(v) == OP_FCMP) { return vals[op(v, 0)].ty; }
    return vals[v].ty;
}

