// SLPVectorizer: the cost of gather / buildvector nodes. Port of llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp:
// BaseShuffleAnalysis (getVF, isIdentityMask, combineMasks, peekThroughShuffles, createShuffle,
// transformMaskAfterShuffle), the ShuffleCostEstimator class (getBuildVectorCost, computeExtractCost,
// estimateNodesPermuteCost, ShuffleCostBuilder, createShuffle, adjustExtracts, add, gather, finalize) and
// BoUpSLP::processBuildVector instantiated with the estimator (the codegen instantiation is not ported).
//
// Vectors: the estimator shuffles real IR vectors (extractelement bases, which can be shufflevectors that
// peekThroughShuffles looks through) and constant vectors it makes up (Constant::getNullValue, getAllOnesValue,
// the ConstantVector of gather()). A "vector" is an i32: >= 0 a real value, < -1 a made-up constant vector
// -(k + 2) of `cv_*` (element type, then one kind per element: 0 null, 1 undef, 2 poison, 3 all-ones).
// ConstantVector::get of all-poison / all-undef elements is PoisonValue / UndefValue, which the kinds express.
// An InVectors element (PointerUnion<Value *, const TreeEntry *>) is `SCV`.
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import pm;
import flags;
import vt;
import apint;
import knownbits;
import datalayout;
import laa;
import tti;
import tti_x86;
import tti_vec;
import tti_x86_vec;
import gen_x86target;
import slp_util;
import slp_tree;
import slp_loads;
import slp_build;
import slp_gather;
import slp_reorder;
import slp_minbw;

// ---------------------------------------------------------------- made-up constant vectors
var cv_at: i64[>..<];
var cv_n: i64[>..<];
var cv_ty: i32[>..<];
var cv_k: u8[>..<];
let CVK_NULL: u8 = 0;
let CVK_UNDEF: u8 = 1;
let CVK_POISON: u8 = 2;
let CVK_ONES: u8 = 3;
fn cv_clear() { cv_at.clear(); cv_n.clear(); cv_ty.clear(); cv_k.clear(); }
fn cv_new(ety: i32, n: i64, k: u8) -> i32 {
    cv_at.push(cv_k.len); cv_n.push(n); cv_ty.push(ety);
    for j in n { cv_k.push(k); }
    return -((cv_at.len - 1) as i32 + 2);
}
fn cv_id(x: i32) -> i64 { (-(x + 2)) as i64 }
fn cv_kind(x: i32, j: i64) -> u8 { cv_k[cv_at[cv_id(x)] + j] }
// getVF(V) / the element count
fn vx_vf(x: i32) -> i64 { if x >= 0 { ty_count(vals[x].ty) } else { cv_n[cv_id(x)] } }
fn vx_elt(x: i32) -> i32 { if x >= 0 { ty_scalar(vals[x].ty) } else { cv_ty[cv_id(x)] } }
fn vx_is_poison(x: i32) -> bool {
    if x >= 0 { return is_poison(x); }
    for j in cv_n[cv_id(x)] { if cv_kind(x, j) != CVK_POISON { return false; } }
    return true;
}
fn vx_is_constant(x: i32) -> bool { x < 0 || is_constant(x) }
fn vx_same_type(a: i32, b: i32) -> bool { vx_vf(a) == vx_vf(b) && vx_elt(a) == vx_elt(b) }
// isUndefVector<IsPoisonOnly>(V, UseMask).all()
fn vx_undef_all(x: i32, poison_only: bool, um: const bool[:]) -> bool {
    var r: bool[>..<] = [];
    if x >= 0 {
        slp_undef_vector_mask(x, poison_only, um, r);
    } else {
        let n = if um.len == 0 { 1 } else { um.len };
        for k in n { r.push(true); }
        let pa = vx_is_poison(x);
        var ua = true;
        for j in cv_n[cv_id(x)] { let k = cv_kind(x, j); if k != CVK_POISON && k != CVK_UNDEF { ua = false; } }
        if !(if poison_only { pa } else { ua }) {
            for i in cv_n[cv_id(x)] {
                let k = cv_kind(x, i);
                let t = if poison_only { k == CVK_POISON } else { k == CVK_POISON || k == CVK_UNDEF };
                if !t && (um.len == 0 || (i < um.len && !um[i])) { if i < r.len { r[i] = false; } }
            }
        }
    }
    for b in r { if !b { return false; } }
    return true;
}
// buildUseMask(VF, Mask, MaskArg): 0 FirstArg, 1 SecondArg, 2 UndefsAsMask
fn slp_build_use_mask(vf: i64, mask: const i32[:], arg: i64, out: bool[>..<]&) {
    out.clear();
    for k in vf { out.push(true); }
    for idx in mask.len {
        let v = mask[idx] as i64;
        if v == -1 { if arg == 2 && idx < out.len { out[idx] = false; } continue; }
        if arg == 0 && v < vf { out[v] = false; }
        else if arg == 1 && v >= vf { out[v - vf] = false; }
    }
}

// ---------------------------------------------------------------- shufflevector helpers
fn sv_n_of(s: i32) -> i64 { insts[inst_of(s)].naux as i64 }
fn sv_at(s: i32, k: i64) -> i32 { ints[insts[inst_of(s)].aux as i64 + k] }
fn sv_copy(s: i32, out: i32[>..<]&) { out.clear(); for k in sv_n_of(s) { out.push(sv_at(s, k)); } }
fn slp_is_zero_elt_splat_mask(m: const i32[:], nsrc: i64) -> bool {
    if m.len != nsrc { return false; }
    if !slp_single_source_mask(m, nsrc) { return false; }
    for x in m { if x != -1 && x != 0 && x as i64 != nsrc { return false; } }
    return true;
}
fn slp_is_extract_subvector_mask(m: const i32[:], nsrc: i64) -> bool, i64 {
    if !slp_single_source_mask(m, nsrc) { return false, 0; }
    if nsrc <= m.len { return false, 0; }
    var sub: i64 = -1;
    for i in m.len {
        let x = m[i] as i64;
        if x < 0 { continue; }
        let off = (x % nsrc) - i;
        if sub >= 0 && sub != off { return false, 0; }
        sub = off;
    }
    if sub >= 0 && sub + m.len <= nsrc { return true, sub; }
    return false, 0;
}
fn sv_is_zero_elt_splat(s: i32) -> bool {
    var m: i32[>..<] = [];
    sv_copy(s, m);
    let nsrc = ty_count(vals[op(s, 0)].ty);
    return m.len == nsrc && slp_is_zero_elt_splat_mask(m, m.len);
}

// ---------------------------------------------------------------- BaseShuffleAnalysis
// isIdentityMask(Mask, VecTy, IsStrict)
fn bsa_is_identity_mask(m: const i32[:], vf: i64, strict: bool) -> bool {
    let limit = m.len;
    if vf == limit && slp_is_identity_mask(m, limit) { return true; }
    if !strict {
        let ok, idx = slp_is_extract_subvector_mask(m, vf);
        if ok && idx == 0 { return true; }
        if limit % vf == 0 {
            var all = true;
            for i in limit / vf {
                let sl = m[(i * vf)..(i * vf + vf)];
                var allp = true;
                for x in sl { if x != -1 { allp = false; } }
                if !allp && !slp_is_identity_mask(sl, vf) { all = false; break; }
            }
            if all { return true; }
        }
    }
    return false;
}
// combineMasks(LocalVF, Mask, ExtMask)
fn bsa_combine_masks(local_vf: i64, mask: i32[>..<]&, ext: const i32[:]) {
    let vf = mask.len;
    var nm: i32[>..<] = [];
    for k in ext.len { nm.push(-1); }
    for i in ext.len {
        if ext[i] == -1 { continue; }
        let mi = mask[(ext[i] as i64) % vf];
        nm[i] = if mi == -1 { -1 } else { ((mi as i64) % local_vf) as i32 };
    }
    slp_copy_list(nm, mask);
}
// peekThroughShuffles(V, Mask, SinglePermute): (identity, V)
fn bsa_peek_through_shuffles(v0: i32, mask: i32[>..<]&, single: bool) -> bool, i32 {
    var o = v0;
    var ident_op: i32 = -1;
    var ident_mask: i32[>..<] = [];
    while o >= 0 && is_inst_op(o, OP_SHUFFLEVECTOR) {
        let sv = o;
        if ty_kind(vals[sv].ty) != TK_FVEC { break; }
        let svvf = ty_count(vals[sv].ty);
        if bsa_is_identity_mask(mask, svvf, false) {
            if ident_op < 0 || !single || (bsa_is_identity_mask(mask, svvf, true) && !slp_is_zero_elt_splat_mask(ident_mask, ident_mask.len)) {
                ident_op = sv;
                slp_copy_list(mask, ident_mask);
            }
        }
        if sv_is_zero_elt_splat(sv) { ident_op = sv; slp_copy_list(mask, ident_mask); }
        var local_vf = mask.len;
        if ty_kind(vals[op(sv, 0)].ty) == TK_FVEC { local_vf = ty_count(vals[op(sv, 0)].ty); }
        var ext: i32[>..<] = [];
        let svn = sv_n_of(sv);
        for i in mask.len { ext.push(-1); }
        for i in mask.len {
            let x = mask[i];
            if x == -1 || (x as i64) >= svn { continue; }
            ext[i] = sv_at(sv, x as i64);
        }
        var um1: bool[>..<] = [];
        var um2: bool[>..<] = [];
        slp_build_use_mask(local_vf, ext, 0, um1);
        slp_build_use_mask(local_vf, ext, 1, um2);
        let u1 = vx_undef_all(op(sv, 0), true, um1);
        let u2 = vx_undef_all(op(sv, 1), true, um2);
        if !u1 && !u2 {
            for i in mask.len {
                if mask[i] == -1 { continue; }
                if sv_at(sv, (mask[i] as i64) % svn) == -1 { mask[i] = -1; }
            }
            break;
        }
        var shm: i32[>..<] = [];
        sv_copy(sv, shm);
        bsa_combine_masks(local_vf, shm, mask);
        slp_copy_list(shm, mask);
        o = if u2 { op(sv, 0) } else { op(sv, 1) };
    }
    let fixed = vx_is_fvec(o);
    if !fixed || !bsa_is_identity_mask(mask, vx_vf(o), single) || slp_is_zero_elt_splat_mask(mask, mask.len) {
        if ident_op >= 0 {
            for i in mask.len { if mask[i] == -1 { ident_mask[i] = -1; } }
            slp_copy_list(ident_mask, mask);
            let shuf = ident_op;
            var r = false;
            if single {
                if bsa_is_identity_mask(mask, ty_count(vals[shuf].ty), true) { r = true; }
                else if mask.len == sv_n_of(shuf) && sv_is_zero_elt_splat(shuf) && slp_is_zero_elt_splat_mask(mask, mask.len) {
                    var all = true;
                    for i in mask.len { if mask[i] != -1 && sv_at(shuf, i) != 0 { all = false; break; } }
                    r = all;
                }
            }
            return r, ident_op;
        }
        return false, o;
    }
    return true, o;
}
fn vx_is_fvec(x: i32) -> bool { x < 0 || ty_kind(vals[x].ty) == TK_FVEC }

// ShuffleCostBuilder::createShuffleVector(V1, V2, Mask) / (V1, Mask, VL)
fn scb_is_empty_or_identity(m: const i32[:], vf: i64) -> bool {
    if m.len == 0 { return true; }
    if vf == m.len && slp_is_identity_mask(m, vf) { return true; }
    let ok, idx = slp_is_extract_subvector_mask(m, vf);
    return ok && idx == 0;
}
fn vx_type(x: i32) -> i32 { if x >= 0 { vals[x].ty } else { slp_widened_type(cv_ty[cv_id(x)], cv_n[cv_id(x)]) } }
// BaseShuffleAnalysis::createShuffle<InstructionCost>(V1, V2, Mask, ShuffleCostBuilder, ScalarTy, VL)
fn bsa_create_shuffle_cost(v1_0: i32, v2: i32, mask: const i32[:], vl: const i32[:]) -> i64 {
    let v1 = v1_0;
    var nm: i32[>..<] = [];
    slp_copy_list(mask, nm);
    var vf = mask.len;
    if vx_is_fvec(v1) { vf = vx_vf(v1); }
    if v2 != -1 {
        var um: bool[>..<] = [];
        slp_build_use_mask(vf, mask, 1, um);
        if !vx_undef_all(v2, true, um) {
            var op1 = v1;
            var op2 = v2;
            let vf2 = vx_vf(v1);
            var cm1: i32[>..<] = [];
            var cm2: i32[>..<] = [];
            for k in mask.len { cm1.push(-1); cm2.push(-1); }
            for i in mask.len {
                if (mask[i] as i64) < vf2 { cm1[i] = mask[i]; } else { cm2[i] = (mask[i] as i64 - vf2) as i32; }
            }
            loop {
                let p1 = op1;
                let p2 = op2;
                let i1, n1 = bsa_peek_through_shuffles(op1, cm1, false);
                op1 = n1;
                let i2, n2 = bsa_peek_through_shuffles(op2, cm2, false);
                op2 = n2;
                if op1 >= 0 && op2 >= 0 && is_inst_op(op1, OP_SHUFFLEVECTOR) && is_inst_op(op2, OP_SHUFFLEVECTOR) {
                    let sv1 = op1;
                    let sv2 = op2;
                    var e1: i32[>..<] = [];
                    for i in cm1.len { e1.push(if cm1[i] == -1 { -1 } else { sv_at(sv1, cm1[i] as i64) }); }
                    var um1: bool[>..<] = [];
                    slp_build_use_mask(ty_count(vals[op(sv1, 1)].ty), e1, 1, um1);
                    var e2: i32[>..<] = [];
                    for i in cm2.len { e2.push(if cm2[i] == -1 { -1 } else { sv_at(sv2, cm2[i] as i64) }); }
                    var um2: bool[>..<] = [];
                    slp_build_use_mask(ty_count(vals[op(sv2, 1)].ty), e2, 1, um2);
                    if vals[op(sv1, 0)].ty as i32 == vals[op(sv2, 0)].ty as i32 && vals[op(sv1, 0)].ty as i32 != vals[sv1].ty as i32 &&
                       vx_undef_all(op(sv1, 1), false, um1) && vx_undef_all(op(sv2, 1), false, um2) {
                        op1 = op(sv1, 0);
                        op2 = op(sv2, 0);
                        var s1: i32[>..<] = [];
                        sv_copy(sv1, s1);
                        var lvf = s1.len;
                        if ty_kind(vals[op1].ty) == TK_FVEC { lvf = ty_count(vals[op1].ty); }
                        bsa_combine_masks(lvf, s1, cm1);
                        slp_copy_list(s1, cm1);
                        var s2: i32[>..<] = [];
                        sv_copy(sv2, s2);
                        lvf = s2.len;
                        if ty_kind(vals[op2].ty) == TK_FVEC { lvf = ty_count(vals[op2].ty); }
                        bsa_combine_masks(lvf, s2, cm2);
                        slp_copy_list(s2, cm2);
                    }
                }
                if p1 == op1 && p2 == op2 { break; }
            }
            let a = vx_vf(op1);
            let b = vx_vf(op2);
            let vf3 = if a > b { a } else { b };
            for i in mask.len {
                if cm2[i] != -1 { cm1[i] = (cm2[i] as i64 + (if op1 == op2 { 0 } else { vf3 })) as i32; }
            }
            if op1 == op2 {
                if slp_is_identity_mask(cm1, vf3) { return 0; }
                if slp_is_zero_elt_splat_mask(cm1, vf3) && op1 >= 0 && is_inst_op(op1, OP_SHUFFLEVECTOR) {
                    var sm: i32[>..<] = [];
                    sv_copy(op1, sm);
                    if slp_lists_equal(sm, cm1) { return 0; }
                }
            }
            // createShuffleVector(Op1, Op2, CombinedMask1)
            if scb_is_empty_or_identity(cm1, vx_vf(op1)) { return 0; }
            return slp_shuffle_cost(SK_PERMUTETWOSRC, vx_type(op1), cm1, 0, -1);
        }
    }
    if vx_is_poison(v1) { return 0; }
    let ident, nv1 = bsa_peek_through_shuffles(v1, nm, true);
    if !ident {
        if scb_is_empty_or_identity(nm, vx_vf(nv1)) { return 0; }
        return slp_shuffle_cost_args(SK_PERMUTESINGLESRC, vx_type(nv1), nm, 0, -1, vl);
    }
    return 0;
}
// ::getShuffleCost(..., Args = VL)
fn slp_shuffle_cost_args(sk: i64, tp: i32, mask: const i32[:], index: i64, subtp: i32, vl: const i32[:]) -> i64 {
    if vl.len == 0 { return slp_shuffle_cost(sk, tp, mask, index, subtp); }
    if sk == SK_PERMUTETWOSRC { slp_fail("getShuffleCost of two sources with Args"); }
    var dst = tp;
    if mask.len > 0 { dst = ty_vector(ty_scalar(tp), mask.len, false); }
    var a1: i32 = -1;
    var nargs: i64 = 1;
    if vl.len > 1 {
        nargs = 2;
        a1 = vl[1];
        for v in vl { if !is_constant(v) { a1 = v; break; } }
    }
    return tv_shuffle(sk, dst, tp, mask, TCK_RECIP_THROUGHPUT, index, subtp, vl[0], a1, nargs, -1);
}
// transformMaskAfterShuffle(CommonMask, Mask)
fn bsa_transform_mask_after_shuffle(cm: i32[>..<]&, mask: const i32[:]) {
    for i in cm.len { if mask[i] != -1 { cm[i] = i as i32; } }
}

// ---------------------------------------------------------------- ShuffleCostEstimator
struct SCV { te: bool, x: i32 }
var ce_sty: i32 = -1;                 // ScalarTy
var ce_cost: i64 = 0;
var ce_common: i32[>..<];             // CommonMask
var ce_in: SCV[>..<];                 // InVectors
var ce_bv_on: bool = true;            // BVValues engaged
var ce_bv: i32[>..<];
var ce_same_nodes: bool = true;       // SameNodesEstimated
var ce_finalized: bool = false;
let SH_CEVV: i64 = 38;                // VectorizedVals of the estimator
let SH_CHKEXT: i64 = 39;              // CheckedExtracts (per calculateTreeCostAndTrimNonProfitable)
fn ce_begin(sty: i32, vectorized_vals: const i32[:]) {
    ce_sty = sty;
    ce_cost = 0;
    ce_common.clear();
    ce_in.clear();
    ce_bv_on = true;
    ce_bv.clear();
    ce_same_nodes = true;
    ce_finalized = false;
    sh_clear(SH_CEVV);
    for v in vectorized_vals { sh_add(SH_CEVV, v as i64, 0); }
}
fn ce_null_vec(n: i64) -> i32 { cv_new(ce_sty, n, CVK_NULL) }
fn ce_ones_vec(n: i64) -> i32 { cv_new(ce_sty, n, CVK_ONES) }
fn scv_te(t: i32) -> SCV { SCV { te: true, x: t } }
fn scv_v(v: i32) -> SCV { SCV { te: false, x: v } }
fn scv_null() -> SCV { SCV { te: false, x: -1 } }

// getBuildVectorCost(VL, Root)
fn ce_build_vector_cost(vl: const i32[:], root: i32) -> i64 {
    var all_undef = true;
    for v in vl { if !is_undef_or_poison(v) { all_undef = false; break; } }
    if (root == -1 && slp_all_constant(vl)) || all_undef { return 0; }
    let vecty = slp_widened_type(ce_sty, vl.len);
    if root == -1 && slp_is_splat(vl) {
        var it: i64 = -1;
        for k in vl.len { if !is_undef_or_poison(vl[k]) { it = k; break; } }
        let x = vl[it];
        var cnt: i64 = 0;
        for v in vl { if v == x { cnt++; } }
        var rest_undef = true;
        for k in 1..vl.len { if !is_undef_or_poison(vl[k]) { rest_undef = false; break; } }
        let need = cnt > 1 && (vl[0] != x || !rest_undef);
        if !need { return tv_vec_inst(OP_INSERTELEMENT, vecty, it, c_poison(vecty), x, TCK_RECIP_THROUGHPUT); }
        var sm: i32[>..<] = [];
        for v in vl { sm.push(if is_poison(v) { -1 } else { 0 }); }
        let ic = tv_vec_inst(OP_INSERTELEMENT, vecty, 0, c_poison(vecty), x, TCK_RECIP_THROUGHPUT);
        var args: i32[1] = [x];
        return tc_add(ic, slp_shuffle_cost_args(SK_BROADCAST, vecty, sm, 0, -1, args[..]));
    }
    return slp_gather_cost(vl, root == -1, ce_sty);
}
// computeExtractCost(VL, Mask, ShuffleKinds, NumParts)
fn ce_compute_extract_cost(vl: const i32[:], mask: const i32[:], kinds: const i64[:], nparts: i64) -> i64 {
    var nelts: i64 = 0;
    for v in vl {
        if !is_inst_op(v, OP_EXTRACTELEMENT) { continue; }
        let vt: i32 = vals[op(v, 0)].ty;
        if ty_kind(vt) != TK_FVEC { continue; }
        if ty_count(vt) > nelts { nelts = ty_count(vt); }
    }
    let epv = slp_part_num_elems(vl.len, nparts);
    // CheckPerRegistersShuffle(Mask, Indices, SubVecSizes): kind or -1
    fn per_reg(m: i32[>..<]&, idxs: i64[>..<]&, sizes: i64[>..<]&) -> i64 {
        if nelts <= epv { return -1; }
        var mn: i64 = 0x7FFFFFFF;
        for x in m { if x != -1 && (x as i64) < mn { mn = x as i64; } }
        let off0 = (mn / epv) * epv;
        var off1 = off0;
        var regs: i64[>..<] = [];
        var kind = SK_PERMUTESINGLESRC;
        var first: i64 = -1;
        idxs.clear();
        idxs.push(off0);
        for pos in m.len {
            let i = m[pos] as i64;
            if i == -1 { continue; }
            var idx = i - off0;
            let reg = (idx / nelts) * nparts + (idx % nelts) / epv;
            if first < 0 { first = reg; }
            var have = false;
            for r in regs { if r == reg { have = true; } }
            if !have { regs.push(reg); }
            if regs.len > 2 { return -1; }
            if regs.len == 2 {
                kind = SK_PERMUTETWOSRC;
                if idxs.len == 1 {
                    var s: i64 = 0x7FFFFFFF;
                    for p2 in pos..m.len {
                        let j = m[p2] as i64;
                        if j == -1 { continue; }
                        let r2 = ((j - off0) / nelts) * nparts + ((j - off0) % nelts) / epv;
                        if r2 == first { continue; }
                        if j < s { s = j; }
                    }
                    off1 = (s / epv) * epv;
                    let index = off1 % nelts;
                    idxs.push(index);
                    sizes.push(if nelts - index < epv { nelts - index } else { epv });
                }
                idx = i - off1;
            }
            m[pos] = ((idx % nelts) % epv + (if reg == first { 0 } else { epv })) as i32;
        }
        return kind;
    }
    var cost: i64 = 0;
    for part in nparts {
        if part >= kinds.len || kinds[part] < 0 { continue; }
        let lim = slp_num_elems(mask.len, epv, part);
        let ms = mask[(part * epv)..(part * epv + lim)];
        var sub: i32[>..<] = [];
        for k in epv { sub.push(-1); }
        for k in ms.len { sub[k] = ms[k]; }
        var idxs: i64[>..<] = [];
        var sizes: i64[>..<] = [];
        let rk = per_reg(sub, idxs, sizes);
        if rk < 0 {
            let mx = if nelts > ms.len { nelts } else { ms.len };
            if kinds[part] != SK_PERMUTESINGLESRC || !slp_is_identity_mask(ms, mx) {
                cost = tc_add(cost, slp_shuffle_cost(kinds[part], slp_widened_type(ce_sty, nelts), ms, 0, -1));
            }
            continue;
        }
        if rk != SK_PERMUTESINGLESRC || !slp_is_identity_mask(sub, epv) {
            cost = tc_add(cost, slp_shuffle_cost(rk, slp_widened_type(ce_sty, epv), sub, 0, -1));
        }
        let base_vf = slp_full_vector_number_of_elements(vals[vl[0]].ty, ((nelts + epv - 1) / epv) * epv);
        for k in sizes.len {
            cost = tc_add(cost, slp_shuffle_cost(SK_EXTRACTSUBVECTOR, slp_widened_type(ce_sty, base_vf), slp_no_mask(), idxs[k],
                                                 slp_widened_type(ce_sty, sizes[k])));
        }
        var sub2: i32[>..<] = [];
        for k in nelts { sub2.push(-1); }
        for k in ms.len { sub2[k] = ms[k]; }
        let oc = slp_shuffle_cost(kinds[part], slp_widened_type(ce_sty, nelts), sub2, 0, -1);
        if oc < cost { cost = oc; }
    }
    return cost;
}
// ShuffleCostEstimator::createShuffle(P1, P2, Mask, VL)
fn ce_create_shuffle(p1: SCV, p2: SCV, mask: const i32[:], vl: const i32[:]) -> i64 {
    var cm: i32[>..<] = [];
    slp_copy_list(mask, cm);
    var v1: i32 = if p1.te { -1 } else { p1.x };
    var v2: i32 = if p2.te { -1 } else { p2.x };
    let p2null = !p2.te && p2.x == -1;
    var cvf = mask.len;
    var extra: i64 = 0;
    fn node_minbw_cost(e: i32, vf: i64) -> i64 {
        if te_is_gather(e) && slp_all_constant(te_scalars(e)) { return 0; }
        var est: i32 = vals[te_scalar(e, 0)].ty;
        var signed = true;
        if slp_te[e].mbw > 0 { est = ty_int(slp_te[e].mbw as i64); signed = slp_te[e].mbw_s; }
        if est != ce_sty {
            var co = OP_TRUNC;
            let dsz = slp_dl_bits(ce_sty);
            let ssz = slp_dl_bits(est);
            if dsz > ssz { co = if signed { OP_SEXT } else { OP_ZEXT }; }
            return tv_cast(co, slp_widened_type(ce_sty, vf), slp_widened_type(est, vf), 0, TCK_RECIP_THROUGHPUT, -1);
        }
        return 0;
    }
    fn value_minbw_cost(v: i32) -> i64 {
        if vx_is_constant(v) { return 0; }
        let est = ty_scalar(vals[v].ty);
        if est != ce_sty {
            let signed = !mb_known_non_negative(v);
            var co = OP_TRUNC;
            let dsz = slp_dl_bits(ce_sty);
            let ssz = slp_dl_bits(est);
            if dsz > ssz { co = if signed { OP_SEXT } else { OP_ZEXT }; }
            return tv_cast(co, slp_widened_type(ce_sty, ty_count(vals[v].ty)), vals[v].ty, 0, TCK_RECIP_THROUGHPUT, -1);
        }
        return 0;
    }
    if v1 == -1 && v2 == -1 && !p2null {
        let e = p1.x;
        let vf = te_vector_factor(e);
        let e2 = p2.x;
        cvf = if vf > te_vector_factor(e2) { vf } else { te_vector_factor(e2) };
        if te_nscalars(e) == te_nscalars(e2) {
            var em: i32[>..<] = [];
            var e2m: i32[>..<] = [];
            te_common_mask(e, em);
            te_common_mask(e2, e2m);
            if em.len > 0 || e2m.len > 0 {
                for k in cm.len {
                    let idx = cm[k] as i64;
                    if idx == -1 { continue; }
                    if idx < cvf && em.len > 0 { cm[k] = em[idx]; }
                    else if idx >= cvf { cm[k] = ((if e2m.len == 0 { idx - cvf } else { e2m[idx - cvf] as i64 }) + te_nscalars(e)) as i32; }
                }
            }
            cvf = te_nscalars(e);
            extra = tc_add(extra, tc_add(node_minbw_cost(e, cvf), node_minbw_cost(e2, cvf)));
        } else {
            extra = tc_add(extra, tc_add(node_minbw_cost(e, te_vector_factor(e)), node_minbw_cost(e2, te_vector_factor(e2))));
        }
        v1 = ce_null_vec(cvf);
        v2 = ce_ones_vec(cvf);
    } else if v1 == -1 && p2null {
        let e = p1.x;
        let vf = te_vector_factor(e);
        cvf = vf;
        if te_nscalars(e) == mask.len && vf != mask.len {
            var em: i32[>..<] = [];
            te_common_mask(e, em);
            for k in cm.len { if cm[k] != -1 { cm[k] = em[cm[k] as i64]; } }
            cvf = te_nscalars(e);
        } else if slp_te[e].inter > 0 && te_nscalars(e) != mask.len && sv_is_deinterleave_mask_of_factor(cm, slp_te[e].inter as i64) {
            for k in cm.len { cm[k] = k as i32; }
        }
        extra = tc_add(extra, node_minbw_cost(e, cvf));
        v1 = ce_null_vec(cvf);
        let nr = slp_te[e].nreord as i64;
        if nr > 0 && cvf == nr && cvf == cm.len {
            var a = false;
            var b = false;
            for k in cm.len { if cm[k] != -1 && cm[k] as i64 != k { a = true; } if cm[k] != -1 && cm[k] != 0 { b = true; } }
            if a && b {
                var rm: i32[>..<] = [];
                slp_inverse_permutation(te_reorder(e), rm);
                slp_add_mask(cm, rm, false);
            }
        }
    } else if v1 != -1 && p2null {
        extra = tc_add(extra, value_minbw_cost(v1));
        cvf = vx_vf(v1);
    } else if v1 != -1 && v2 == -1 {
        let vf = vx_vf(v1);
        let e2 = p2.x;
        cvf = if vf > te_vector_factor(e2) { vf } else { te_vector_factor(e2) };
        if te_nscalars(e2) == vf && vf != cvf {
            var e2m: i32[>..<] = [];
            te_common_mask(e2, e2m);
            for k in cm.len {
                let idx = cm[k] as i64;
                if idx == -1 { continue; }
                if idx >= cvf { cm[k] = (e2m[idx - cvf] as i64 + vf) as i32; }
            }
            cvf = vf;
        }
        extra = tc_add(extra, value_minbw_cost(v1));
        v1 = ce_null_vec(cvf);
        extra = tc_add(extra, node_minbw_cost(e2, if cvf < te_vector_factor(e2) { cvf } else { te_vector_factor(e2) }));
        v2 = ce_ones_vec(cvf);
    } else if v1 == -1 && v2 != -1 {
        let vf = vx_vf(v2);
        let e1 = p1.x;
        cvf = if vf > te_vector_factor(e1) { vf } else { te_vector_factor(e1) };
        if te_nscalars(e1) == vf && vf != cvf {
            var e1m: i32[>..<] = [];
            te_common_mask(e1, e1m);
            for k in cm.len {
                let idx = cm[k] as i64;
                if idx == -1 { continue; }
                if idx >= cvf { cm[k] = (e1m[idx - cvf] as i64 + vf) as i32; } else { cm[k] = e1m[idx]; }
            }
            cvf = vf;
        }
        extra = tc_add(extra, node_minbw_cost(e1, if cvf < te_vector_factor(e1) { cvf } else { te_vector_factor(e1) }));
        v1 = ce_null_vec(cvf);
        extra = tc_add(extra, value_minbw_cost(v2));
        v2 = ce_ones_vec(cvf);
    } else {
        let a = vx_vf(v1);
        let b = vx_vf(v2);
        cvf = if a > b { a } else { b };
        extra = tc_add(extra, tc_add(value_minbw_cost(v1), value_minbw_cost(v2)));
        if !vx_same_type(v1, v2) {
            v1 = ce_null_vec(cvf);
            v2 = ce_ones_vec(cvf);
        } else {
            if vx_elt(v1) != ce_sty { v1 = ce_null_vec(cvf); }
            if vx_elt(v2) != ce_sty { v2 = ce_ones_vec(cvf); }
        }
    }
    if ce_in.len > 0 { ce_in[0] = scv_v(ce_null_vec(cm.len)); }
    if ce_in.len == 2 { ce_in.pop(); }
    return tc_add(extra, bsa_create_shuffle_cost(v1, if p2null { -1 } else { v2 }, cm, vl));
}
fn ce_in_back() -> SCV { ce_in[ce_in.len - 1] }
// estimateNodesPermuteCost(E1, E2, Mask, Part, SliceSize)
fn ce_estimate_nodes_permute_cost(e1: i32, e2: i32, mask: const i32[:], part: i64, slice: i64) {
    if ce_same_nodes {
        if (ce_in.len == 2 && ce_in[0].x == e1 && ce_in[1].x == e2 && ce_in[0].te && ce_in[1].te) ||
           (e2 < 0 && ce_in[0].te && ce_in[0].x == e1) {
            let lim = slp_num_elems(mask.len, slice, part);
            for k in lim { ce_common[slice * part + k] = mask[part * slice + k]; }
            return;
        }
        ce_cost = tc_add(ce_cost, ce_create_shuffle(ce_in[0], if ce_in.len == 1 { scv_null() } else { ce_in_back() }, ce_common, slp_no_mask()));
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
    } else if ce_in.len == 2 {
        ce_cost = tc_add(ce_cost, ce_create_shuffle(ce_in[0], ce_in_back(), ce_common, slp_no_mask()));
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
    }
    ce_same_nodes = false;
    if e2 < 0 && ce_in.len == 1 {
        var vf = te_vector_factor(e1);
        if !ce_in[0].te { let w = vx_vf(ce_in[0].x); if w > vf { vf = w; } }
        else { let w = te_vector_factor(ce_in[0].x); if w > vf { vf = w; } }
        for i in ce_common.len { if mask[i] != -1 && ce_common[i] == -1 { ce_common[i] = (mask[i] as i64 + vf) as i32; } }
        ce_cost = tc_add(ce_cost, ce_create_shuffle(ce_in[0], scv_te(e1), ce_common, slp_no_mask()));
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
    } else {
        let p = ce_in[0];
        ce_cost = tc_add(ce_cost, ce_create_shuffle(scv_te(e1), if e2 < 0 { scv_null() } else { scv_te(e2) }, mask, slp_no_mask()));
        var vf = mask.len;
        if !p.te { let w = vx_vf(p.x); if w > vf { vf = w; } } else { let w = te_vector_factor(p.x); if w > vf { vf = w; } }
        for i in ce_common.len { if mask[i] != -1 { ce_common[i] = (i + (if ce_in.len == 0 { 0 } else { vf })) as i32; } }
        ce_cost = tc_add(ce_cost, ce_create_shuffle(p, ce_in[0], ce_common, slp_no_mask()));
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
    }
}
// adjustExtracts(E, Mask, ShuffleKinds, NumParts, UseVecBaseAsInput): (VecBase or -1, UseVecBaseAsInput)
fn ce_adjust_extracts(e: i32, mask: i32[>..<]&, kinds: const i64[:], nparts: i64) -> i32, bool {
    if mask.len == 0 { return -1, false; }
    var vecbase: i32 = -1;
    var vl: i32[>..<] = [];
    slp_copy_list(te_scalars(e), vl);
    if slp_te[e].nreord > 0 { slp_reorder_scalars(vl, te_reorder(e)); }
    var prev_found = false;
    for t0 in e {
        let t = t0 as i32;
        let ok = (te_has_state(t) && !te_is_alt_shuffle(t) && te_opcode(t) == OP_EXTRACTELEMENT) || te_is_gather(t);
        if !ok { continue; }
        var all = true;
        let sc = te_scalars(t);
        for k in sc.len {
            if !(vl.len > k && (mask[k] == -1 || is_undef_or_poison(vl[k]) || sc[k] == vl[k])) { all = false; break; }
        }
        if all { prev_found = true; break; }
    }
    var bases: i32[>..<] = [];
    let slice = slp_part_num_elems(vl.len, nparts);
    var vo_v: i32[>..<] = [];     // VectorOpsToExtracts: vector -> demanded elements (bit lists)
    var vo_at: i64[>..<] = [];
    var vo_bits: bool[>..<] = [];
    for part in nparts {
        let lim = slp_num_elems(vl.len, slice, part);
        for i in lim {
            let v = vl[part * slice + i];
            if is_undef_or_poison(v) || mask[part * slice + i] == -1 { continue; }
            let ee = v;
            vecbase = op(ee, 0);
            if !slp_contains(bases, vecbase) { bases.push(vecbase); }
            var ves: i32[>..<] = [];
            var c = slp_tree_entries_head(v);
            while c >= 0 { ves.push(slp_lk[c].x); c = slp_lk[c].next; }
            var skip = !sh_add(SH_CHKEXT, v as i64, 0);
            if !skip && !slp_are_all_users_vectorized_in(ee, SH_CEVV) { skip = true; }
            if !skip { for t in ves { if slp_is_deleted_node(t) || slp_is_transformed_to_gather(t) { skip = true; break; } } }
            if !skip && slp_te[e].ui_te >= 0 && slp_te[e].ui_edge < 0 && !slp_is_vectorized(ee) {
                var c1: i64 = 0;
                var c2: i64 = 0;
                for x in te_scalars(e) { if x == ee { c1++; } }
                for x in te_scalars(slp_te[e].ui_te) { if x == ee { c2++; } }
                if c1 != c2 { skip = true; }
            }
            if !skip {
                var u = vals[ee].first_use;
                while u >= 0 {
                    let usr = uses[u].user;
                    u = uses[u].next;
                    if is_inst_op(usr, OP_GEP) && !slp_are_all_users_vectorized_in(usr, SH_CEVV) { skip = true; break; }
                }
            }
            if !skip && ves.len > 0 && !slp_contains(ves, e) { skip = true; }
            if skip { continue; }
            let eidx = slp_extract_index(ee);
            if eidx < 0 { continue; }
            if slp_has_one_use(ee) || !prev_found {
                let ext = slp_user_back(ee);
                if (is_inst_op(ext, OP_SEXT) || is_inst_op(ext, OP_ZEXT)) && slp_users_all_op(ext, OP_GEP) {
                    ce_cost = tc_sub(ce_cost, tv_extract_with_extend(iop(ext), vals[ext].ty, vals[op(ee, 0)].ty, eidx));
                    ce_cost = tc_add(ce_cost, tv_cast(iop(ext), vals[ext].ty, vals[ee].ty, tv_cast_context_hint(ext), TCK_RECIP_THROUGHPUT, ext));
                    continue;
                }
            }
            var k = -1 as i64;
            for j in vo_v.len { if vo_v[j] == vecbase { k = j; break; } }
            if k < 0 {
                k = vo_v.len;
                vo_v.push(vecbase);
                vo_at.push(vo_bits.len);
                for j in ty_count(vals[vecbase].ty) { vo_bits.push(false); }
            }
            vo_bits[vo_at[k] + eidx] = true;
        }
    }
    for j in vo_v.len {
        let n = ty_count(vals[vo_v[j]].ty);
        ce_cost = tc_sub(ce_cost, tv_scalarization_overhead(vals[vo_v[j]].ty, vo_bits[vo_at[j]..(vo_at[j] + n)], false, true, TCK_RECIP_THROUGHPUT));
    }
    if !prev_found { ce_cost = tc_add(ce_cost, ce_compute_extract_cost(vl, mask, kinds, nparts)); }
    ce_in.clear();
    ce_in.push(scv_te(e));
    slp_copy_list(mask, ce_common);
    var cc: i32[>..<] = [];
    slp_copy_list(ce_common, cc);
    bsa_transform_mask_after_shuffle(ce_common, cc);
    ce_same_nodes = false;
    var use_base = false;
    if nparts != 1 && bases.len != 1 {
        use_base = true;
        vecbase = ce_null_vec(ce_common.len);
    }
    return vecbase, use_base;
}
// getExtractWithExtendCost(Opcode, Dst, VecTy, Index): BasicTTIImpl's (X86 does not override it)
fn tv_extract_with_extend(o: i64, dst: i32, vecty: i32, idx: i64) -> i64 {
    if tti_kind != TTI_X86 { return 1; }   // TargetTransformInfoImplBase
    return tc_add(tv_vec_inst(OP_EXTRACTELEMENT, vecty, idx, -1, -1, TCK_RECIP_THROUGHPUT),
                  tv_cast(o, dst, ty_scalar(vecty), 0, TCK_RECIP_THROUGHPUT, -1));
}
fn slp_user_back(v: i32) -> i32 {
    // Value::user_back(): the user of the most recently added use (the head of the use list)
    return uses[vals[v].first_use].user;
}
fn slp_users_all_op(v: i32, o: i64) -> bool {
    var u = vals[v].first_use;
    while u >= 0 { if !is_inst_op(uses[u].user, o) { return false; } u = uses[u].next; }
    return true;
}
// areAllUsersVectorized(I, VectorizedVals as a set slot)
fn slp_are_all_users_vectorized_in(i: i32, slot: i64) -> bool {
    if slp_has_one_use(i) && sh_has(slot, i as i64, 0) { return true; }
    var u = vals[i].first_use;
    while u >= 0 {
        let usr = uses[u].user;
        u = uses[u].next;
        if slp_is_vectorized(usr) || sh_has(slot, usr as i64, 0) { continue; }
        if is_inst_op(usr, OP_EXTRACTELEMENT) && slp_is_constant(op(usr, 1)) { continue; }
        return false;
    }
    return true;
}
// add(E1, E2, Mask) / add(E1, Mask)
fn ce_add_te2(e1: i32, e2: i32, mask: const i32[:]) {
    ce_bv_on = false;
    if e1 == e2 { ce_add_te(e1, mask); return; }
    if ce_in.len == 0 {
        slp_copy_list(mask, ce_common);
        ce_in.clear(); ce_in.push(scv_te(e1)); ce_in.push(scv_te(e2));
        return;
    }
    let mvt = slp_widened_type(ce_sty, mask.len);
    let np = slp_number_of_parts(mvt, ce_sty, mask.len);
    let slice = slp_part_num_elems(mask.len, np);
    var it: i64 = mask.len;
    for k in mask.len { if mask[k] != -1 { it = k; break; } }
    ce_estimate_nodes_permute_cost(e1, e2, mask, it / slice, slice);
}
fn ce_add_te(e1: i32, mask: const i32[:]) {
    ce_bv_on = false;
    if ce_in.len == 0 {
        slp_copy_list(mask, ce_common);
        ce_in.clear(); ce_in.push(scv_te(e1));
        return;
    }
    let mvt = slp_widened_type(ce_sty, mask.len);
    let np = slp_number_of_parts(mvt, ce_sty, mask.len);
    let slice = slp_part_num_elems(mask.len, np);
    var it: i64 = mask.len;
    for k in mask.len { if mask[k] != -1 { it = k; break; } }
    ce_estimate_nodes_permute_cost(e1, -1, mask, it / slice, slice);
    if !ce_same_nodes && ce_in.len == 1 { ce_in.push(scv_te(e1)); }
}
// add(V1, Mask, ForExtracts)
fn ce_add_v(v1: i32, mask: const i32[:], for_extracts: bool) {
    if ce_bv_on && !vx_is_constant(v1) { ce_bv_on = false; }
    if ce_in.len == 0 {
        slp_copy_list(mask, ce_common);
        ce_in.push(scv_v(v1));
        return;
    }
    if for_extracts { return; }
    var vf = vx_vf(v1);
    if ce_in.len == 2 {
        ce_cost = tc_add(ce_cost, ce_create_shuffle(ce_in[0], ce_in_back(), ce_common, slp_no_mask()));
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
        if ce_common.len > vf { vf = ce_common.len; }
    } else if ce_in[0].te {
        let w = te_vector_factor(ce_in[0].x);
        if w > vf { vf = w; }
    } else {
        let w = vx_vf(ce_in[0].x);
        if w > vf { vf = w; }
    }
    ce_in.push(scv_v(v1));
    for i in ce_common.len { if mask[i] != -1 && ce_common[i] == -1 { ce_common[i] = (mask[i] as i64 + vf) as i32; } }
}
// gather(VL, MaskVF, Root): the made-up constant vector
fn ce_gather(vl: const i32[:], mask_vf: i64, root: i32) -> i32 {
    ce_cost = tc_add(ce_cost, ce_build_vector_cost(vl, root));
    if ce_bv_on {
        if ce_bv.len == 0 && ce_in.len == 0 { slp_copy_list(vl, ce_bv); } else { ce_bv_on = false; ce_bv.clear(); }
    }
    if root == -1 {
        var vf = vl.len;
        if mask_vf != 0 && mask_vf < vf { vf = mask_vf; }
        let ety = ty_scalar(vals[vl[0]].ty);
        let x = cv_new(ety, vf, CVK_NULL);
        for k in vf {
            let v = vl[k];
            cv_k[cv_at[cv_id(x)] + k] = if is_poison(v) { CVK_POISON } else if is_undef_or_poison(v) { CVK_UNDEF } else { CVK_NULL };
        }
        return x;
    }
    return cv_new(ty_scalar(ce_sty), vx_vf(root), CVK_ONES);
}
// the first part of finalize(..., Action): the shuffle of InVectors; returns the value the action gets
fn ce_finalize_action_begin() -> i32 {
    let vec = ce_in[0];
    if ce_in.len == 2 { ce_cost = tc_add(ce_cost, ce_create_shuffle(vec, ce_in_back(), ce_common, slp_no_mask())); }
    else { ce_cost = tc_add(ce_cost, ce_create_shuffle(vec, scv_null(), ce_common, slp_no_mask())); }
    var cc: i32[>..<] = [];
    slp_copy_list(ce_common, cc);
    bsa_transform_mask_after_shuffle(ce_common, cc);
    // Vec is a reference to InVectors.front(), which createShuffle replaced by a null vector
    let v = ce_in[0];
    if v.te { fatal("internal: SLP: the finalize action of a tree entry vector"); }
    return v.x;
}
fn ce_finalize_action_end(v: i32) { ce_in[0] = scv_v(v); }
// finalize(ExtMask, SubVectors, SubVectorsMask, VF) (an Action runs between ce_finalize_action_begin / end before)
fn ce_finalize(ext: const i32[:], sub_te: const i32[:], sub_idx: const i64[:], sub_mask: const i32[:], vf: i64, action: bool) -> i64 {
    ce_finalized = true;
    if action { fatal("internal: SLP: use ce_finalize_action_begin / end for the finalize action"); }
    if sub_te.len > 0 {
        let vec = ce_in[0];
        if ce_in.len == 2 { ce_cost = tc_add(ce_cost, ce_create_shuffle(vec, ce_in_back(), ce_common, slp_no_mask())); }
        else { ce_cost = tc_add(ce_cost, ce_create_shuffle(vec, scv_null(), ce_common, slp_no_mask())); }
        var cc: i32[>..<] = [];
        slp_copy_list(ce_common, cc);
        bsa_transform_mask_after_shuffle(ce_common, cc);
        if sub_mask.len > 0 {
            var svm: i32[>..<] = [];
            for k in ce_common.len { svm.push(-1); }
            for k in sub_mask.len { svm[k] = sub_mask[k]; }
            for k in svm.len { if ce_common[k] != -1 { svm[k] = (ce_common[k] as i64 + ce_common.len) as i32; } }
            ce_cost = tc_add(ce_cost, slp_shuffle_cost(SK_PERMUTETWOSRC, slp_widened_type(ce_sty, ce_common.len), svm, 0, -1));
        }
        for j in sub_te.len {
            let e = sub_te[j];
            let idx = sub_idx[j];
            var est: i32 = vals[te_scalar(e, 0)].ty;
            var signed = true;
            if slp_te[e].mbw > 0 { est = ty_int(slp_te[e].mbw as i64); signed = slp_te[e].mbw_s; }
            if ce_sty != est {
                var co = OP_TRUNC;
                if slp_dl_bits(ce_sty) > slp_dl_bits(est) { co = if signed { OP_SEXT } else { OP_ZEXT }; }
                ce_cost = tc_add(ce_cost, tv_cast(co, slp_widened_type(ce_sty, te_vector_factor(e)), slp_widened_type(est, te_vector_factor(e)),
                                                  1, TCK_RECIP_THROUGHPUT, -1));
            }
            ce_cost = tc_add(ce_cost, slp_shuffle_cost(SK_INSERTSUBVECTOR, slp_widened_type(ce_sty, ce_common.len), slp_no_mask(), idx,
                                                       slp_widened_type(ce_sty, te_vector_factor(e))));
            if ce_common.len > 0 { for k in te_vector_factor(e) { ce_common[idx + k] = (idx + k) as i32; } }
        }
    }
    if ext.len > 0 {
        if ce_common.len == 0 { slp_copy_list(ext, ce_common); }
        else {
            var nm: i32[>..<] = [];
            for k in ext.len { nm.push(if ext[k] == -1 { -1 } else { ce_common[ext[k] as i64] }); }
            slp_copy_list(nm, ce_common);
        }
    }
    if ce_common.len == 0 { return ce_cost; }
    var vl: i32[>..<] = [];
    if ce_bv_on { slp_copy_list(ce_bv, vl); }
    return tc_add(ce_cost, ce_create_shuffle(ce_in[0], if ce_in.len == 2 { ce_in_back() } else { scv_null() }, ce_common, vl));
}

// ---------------------------------------------------------------- processBuildVector<ShuffleCostEstimator>
fn slp_pbv_cost(e: i32, sty: i32, vvals: const i32[:]) -> i64 {
    ce_begin(sty, vvals);
    let vf = te_vector_factor(e);
    var need_freeze = false;
    var gs: i32[>..<] = [];
    slp_copy_list(te_scalars(e), gs);
    var sub_te: i32[>..<] = [];
    var sub_idx: i64[>..<] = [];
    if !(slp_te[e].state == TE_SPLIT && slp_is_transformed_to_gather(e)) {
        for k in te_comb_n(e) {
            let ei = te_comb_idx(e, k);
            let idx = te_comb_off(e, k) as i64;
            for j in te_vector_factor(ei) { gs[idx + j] = c_poison(vals[gs[idx + j]].ty); }
            sub_te.push(ei);
            sub_idx.push(idx);
        }
    }
    var rmask: i32[>..<] = [];
    slp_copy_list(te_reorder(e), rmask);
    if rmask.len > 0 { slp_reorder_scalars(gs, rmask); }
    var svmask: i32[>..<] = [];
    slp_inverse_permutation(te_reorder(e), svmask);
    if sub_te.len > 0 && svmask.len > 0 {
        for i in gs.len { if te_scalar(e, i) == gs[rmask[i] as i64] { svmask[rmask[i] as i64] = -1; } }
    } else {
        svmask.clear();
    }
    var stored: i32[>..<] = [];
    slp_copy_list(gs, stored);
    // FindReusedSplat(Mask, InputVF, I, SliceSize, IsNotPoisonous)
    fn find_reused_splat(m: i32[>..<]&, input_vf: i64, i: i64, slice: i64, not_poisonous: bool) -> bool {
        if !slp_is_splat(te_scalars(e)) { return false; }
        var any_undef = false;
        for v in te_scalars(e) { if is_undef_or_poison(v) && !is_poison(v) { any_undef = true; break; } }
        if !any_undef { return false; }
        let ut = slp_te[e].ui_te;
        let edge = slp_te[e].ui_edge;
        if te_num_operands(ut) != 2 { return false; }
        if !not_poisonous {
            var it: i32 = -1;
            for t in (ut as i64 + 1)..slp_te.len {
                if slp_te[t].ui_te == ut && slp_te[t].ui_edge != edge { it = t as i32; break; }
            }
            if it < 0 { return false; }
            var g2: i32[>..<] = [];
            slp_copy_list(te_scalars(it), g2);
            if slp_te[it].nreord > 0 {
                slp_inverse_permutation(te_reorder(it), rmask);
                slp_reorder_scalars(g2, rmask);
            }
            for k in gs.len {
                let v0 = gs[k];
                let v1 = g2[k];
                if !(!is_undef_or_poison(v0) || is_poison(v0) || (is_undef_or_poison(v0) && !is_poison(v0) && slp_contains(te_scalars(e), v1))) { return false; }
            }
        }
        let es, eidx = slp_is_extract_subvector_mask(m, input_vf);
        if (m.len < input_vf && es && eidx == 0) || (m.len == input_vf && slp_is_identity_mask(m, m.len)) {
            let n = slp_num_elems(m.len, slice, i);
            for k in n { m[i * slice + k] = k as i32; }
        } else {
            var ival: i32 = -1;
            for x in m { if x != -1 { ival = x; break; } }
            let n = slp_num_elems(m.len, slice, i);
            for k in n { m[i * slice + k] = ival; }
        }
        return true;
    }
    var mask: i32[>..<] = [];
    var emask: i32[>..<] = [];
    for k in gs.len { emask.push(-1); }
    var eshuf: i64[>..<] = [];
    var evb: i32 = -1;
    var use_vb = false;
    var gshuf: i64[>..<] = [];
    var ents: i32[>..<] = [];
    var nents: i32[>..<] = [];
    let osty: i32 = vals[gs[0]].ty;
    let vecty = slp_widened_type(sty, gs.len);
    var nparts = slp_number_of_parts(vecty, sty, gs.len);
    var all_undef = true;
    for v in gs { if !is_undef_or_poison(v) { all_undef = false; break; } }
    if !all_undef {
        var resized = false;
        slp_gather_extract_elements(gs, emask, nparts, eshuf);
        if eshuf.len > 0 {
            let vb, ub = ce_adjust_extracts(e, emask, eshuf, nparts);
            use_vb = ub;
            if vb != -1 {
                evb = vb;
                if vx_is_fvec(vb) && vf == vx_vf(vb) && gs.len != vf {
                    resized = true;
                    while gs.len < vf { gs.push(c_poison(osty)); }
                    nparts = slp_number_of_parts(slp_widened_type(osty, vf), osty, vf);
                }
            }
        }
        var go = eshuf.len > 0 || !te_has_state(e) || te_opcode(e) != OP_LOAD;
        if !go {
            var any_load = false;
            for v in te_scalars(e) { if is_inst_op(v, OP_LOAD) { any_load = true; break; } }
            if (te_has_state(e) && te_opcode(e) == OP_LOAD) || any_load {
                for v in te_scalars(e) { if is_inst_op(v, OP_LOAD) && slp_is_vectorized(v) { go = true; break; } }
            }
        }
        if !go && te_has_state(e) && te_is_alt_shuffle(e) { go = true; }
        if !go {
            var all = true;
            for v in te_scalars(e) { if !slp_is_vectorized(v) { all = false; break; } }
            if all { go = true; }
        }
        if !go && slp_is_splat(te_scalars(e)) { go = true; }
        if !go && !slp_lists_equal(te_scalars(e), gs) && gs.len <= 2 { go = true; }
        if go { slp_gather_shuffled_entry(e, gs, mask, ents, nents, nparts, false, gshuf); }
        if gshuf.len > 0 {
            let f0 = ents[0];
            if gshuf.len == 1 && gshuf[0] == SK_PERMUTESINGLESRC && (te_is_same(f0, te_scalars(e)) || te_is_same(e, te_scalars(f0))) {
                if slp_dbg_on { errs("SLP: perfect diamond match for gather bundle "); slp_short_bundle_name(te_scalars(e), e); errs(".\n"); slp_dbg_flush(); }
                while mask.len < te_nscalars(e) { mask.push(-1); }
                while mask.len > te_nscalars(e) { mask.pop(); }
                if slp_te[f0].nreord == 0 && slp_te[e].nreord == 0 &&
                   ((slp_te[f0].nreuse == 0 && te_nscalars(e) == te_nscalars(f0)) || te_nscalars(e) == slp_te[f0].nreuse as i64) {
                    for k in mask.len { mask[k] = k as i32; }
                } else {
                    for i in te_nscalars(e) {
                        let v = te_scalar(e, i);
                        if is_poison(v) { mask[i] = -1; continue; }
                        mask[i] = te_find_lane(f0, v) as i32;
                    }
                }
                // resetForSameNode()
                ce_finalized = false; ce_common.clear(); ce_in.clear(); ce_cost = 0; sh_clear(SH_CEVV); ce_same_nodes = true;
                if (te_is_same(e, te_scalars(f0)) && slp_te[f0].nreuse == 0 && slp_te[f0].nreord == 0 && te_vector_factor(e) == te_vector_factor(f0)) ||
                   (slp_lists_equal(te_scalars(e), te_scalars(f0)) && slp_lists_equal(te_reorder(e), te_reorder(f0)) &&
                    slp_lists_equal(te_reuse(e), te_reuse(f0))) {
                    mask.clear();
                    for k in te_vector_factor(f0) { mask.push(k as i32); }
                    ce_add_te(f0, mask);
                    return ce_finalize(slp_no_mask(), slp_no_mask(), slp_no_imask(), slp_no_mask(), 0, false);
                }
                ce_add_te(f0, mask);
                var cm: i32[>..<] = [];
                te_common_mask(e, cm);
                return ce_finalize(cm, slp_no_mask(), slp_no_imask(), slp_no_mask(), 0, false);
            }
            if !resized {
                var any = false;
                for p in nents.len { for j in nents[p] { if te_vector_factor(ents[2 * p + j as i64]) == vf { any = true; } } }
                if gs.len != vf && any { while gs.len < vf { gs.push(c_poison(osty)); } }
            }
            for i in mask.len { if mask[i] != -1 { gs[i] = c_poison(osty); } }
        }
    }
    // TryPackScalars(Scalars, ReuseMask, IsRootPoison)
    fn try_pack_scalars(sc: i32[>..<]&, rm: i32[>..<]&, root_poison: bool) {
        let is_splat = root_poison && slp_is_splat(sc) && (sc.len > 2 || sc[0] == sc[sc.len - 1]);
        while sc.len < vf { sc.push(c_poison(osty)); }
        var undef_pos: i64[>..<] = [];
        var up_v: i32[>..<] = [];
        var up_i: i64[>..<] = [];
        var nnc: i64 = 0;
        var single: i64 = 0;
        for i in sc.len {
            let v = sc[i];
            if is_undef_or_poison(v) {
                if !is_poison(v) { rm[i] = i as i32; undef_pos.push(i); }
                continue;
            }
            if slp_is_constant(v) { rm[i] = i as i32; continue; }
            nnc++;
            single = i;
            let ov = v;
            sc[i] = c_poison(osty);
            if is_splat {
                sc[0] = ov;
                rm[i] = 0;
            } else {
                var pos: i64 = -1;
                for k in up_v.len { if up_v[k] == ov { pos = up_i[k]; break; } }
                if pos < 0 { up_v.push(ov); up_i.push(i); pos = i; }
                sc[pos] = ov;
                rm[i] = pos as i32;
            }
        }
        if nnc == 1 {
            if is_splat {
                rm.clear();
                for k in vf { rm.push(-1); }
                let t = sc[0]; sc[0] = sc[single]; sc[single] = t;
                if undef_pos.len > 0 && undef_pos[0] == 0 { sc[0] = c_undef(osty); }
            }
            rm[single] = single as i32;
        } else if undef_pos.len > 0 && is_splat {
            var it: i64 = -1;
            for k in sc.len {
                let v = sc[k];
                if is_undef_or_poison(v) { continue; }
                var ok = slp_is_vectorized(v) || is_guaranteed_not_to_be_poison(v, -1, 0);
                if !ok && slp_te[e].ui_te >= 0 {
                    var u = vals[v].first_use;
                    while u >= 0 {
                        let usr = uses[u].user;
                        let opno = slp_use_opno(u);
                        u = uses[u].next;
                        if slp_te[e].ui_edge != opno && slp_contains(te_scalars(slp_te[e].ui_te), usr) { ok = true; break; }
                    }
                }
                if ok { it = k; break; }
            }
            if it >= 0 {
                for i in undef_pos { rm[i] = it as i32; if i != it { sc[i] = c_poison(osty); } }
            } else {
                for i in undef_pos { rm[i] = -1; if is_undef_or_poison(sc[i]) { sc[i] = c_poison(osty); } }
                need_freeze = true;
            }
        }
    }
    var res: i64 = 0;
    if eshuf.len > 0 || gshuf.len > 0 {
        var non_poisoned = true;
        var used_in_expr = true;
        var vec1: i32 = -1;
        if eshuf.len > 0 {
            var vec2: i32 = -1;
            for i in emask.len { if mask.len > 0 && mask[i] != -1 { emask[i] = -1; } }
            if use_vb {
                vec1 = evb;
            } else {
                for i in emask.len {
                    if emask[i] == -1 { continue; }
                    if is_undef_or_poison(stored[i]) { continue; }
                    let vo = op(stored[i], 0);
                    if vec1 == -1 { vec1 = vo; } else if vec1 != vo { vec2 = vo; }
                }
            }
            if vec2 != -1 {
                used_in_expr = false;
                non_poisoned = non_poisoned && is_guaranteed_not_to_be_poison(vec1, -1, 0) && is_guaranteed_not_to_be_poison(vec2, -1, 0);
                // add(V1, V2, Mask): already handled in adjustExtracts
            } else if vec1 != -1 {
                let np = vec1 < 0 || is_guaranteed_not_to_be_poison(vec1, -1, 0);
                used_in_expr = used_in_expr && find_reused_splat(emask, vx_vf(vec1), 0, emask.len, np);
                ce_add_v(vec1, emask, true);
                non_poisoned = non_poisoned && np;
            } else {
                used_in_expr = false;
                ce_add_v(cv_new(ty_scalar(vecty), ty_count(vecty), CVK_POISON), emask, true);
            }
        }
        if gshuf.len > 0 {
            var slice = slp_part_num_elems(vf, nparts);
            if mask.len == te_nscalars(e) {
                slice = slp_part_num_elems(te_nscalars(e), slp_number_of_parts(vecty, sty, te_nscalars(e)));
            }
            var vm: i32[>..<] = [];
            for k in mask.len { vm.push(-1); }
            for i in nents.len {
                let n = nents[i] as i64;
                if n == 0 { continue; }
                let lim = slp_num_elems(mask.len, slice, i);
                for k in vm.len { vm[k] = -1; }
                for k in lim { vm[i * slice + k] = mask[i * slice + k]; }
                if n == 1 {
                    let f = ents[2 * i];
                    let np = true;   // TEs.front()->VectorizedValue is null during the cost model
                    used_in_expr = used_in_expr && find_reused_splat(vm, te_vector_factor(f), i, slice, np);
                    ce_add_te(f, vm);
                } else {
                    used_in_expr = false;
                    ce_add_te2(ents[2 * i], ents[2 * i + 1], vm);
                }
            }
        }
        var nonc: i32[>..<] = [];
        slp_copy_list(gs, nonc);
        let emsz = emask.len;
        let msz = mask.len;
        let single_shuffle = eshuf.len == 0 || gshuf.len == 0;
        var ident_e = use_vb;
        if !ident_e {
            ident_e = true;
            for k in eshuf { let x = if k < 0 { SK_PERMUTETWOSRC } else { k }; if x != SK_PERMUTESINGLESRC { ident_e = false; } }
        }
        if ident_e {
            for x in emask { if x as i64 >= emsz { ident_e = false; } }
            ident_e = ident_e && slp_is_identity_mask(emask, emsz);
        }
        var ident_g = gshuf.len > 0;
        if ident_g {
            for k in gshuf { let x = if k < 0 { SK_PERMUTETWOSRC } else { k }; if x != SK_PERMUTESINGLESRC { ident_g = false; } }
            for x in mask { if x as i64 >= msz { ident_g = false; } }
            ident_g = ident_g && slp_is_identity_mask(mask, msz);
        }
        let ident_shuffle = ident_e || ident_g;
        var enough = single_shuffle;
        if enough {
            var no_undef = true;
            var any_const = false;
            for v in gs {
                if is_undef_or_poison(v) && !is_poison(v) { no_undef = false; }
                if is_constant(v) && !is_undef_or_poison(v) { any_const = true; }
            }
            enough = no_undef || any_const;
        }
        if enough {
            var cnt: i64 = 0;
            var any_def = false;
            for v in gs { if is_constant(v) && !is_poison(v) { cnt++; } if !is_undef_or_poison(v) { any_def = true; } }
            enough = !ident_shuffle || (gs.len == 2 && any_def) || cnt > 1;
        }
        for i in gs.len {
            if enough && is_constant(gs[i]) { nonc[i] = c_poison(osty); } else { gs[i] = c_poison(osty); }
        }
        var all_p = true;
        for v in gs { if !is_poison(v) { all_p = false; break; } }
        if !all_p {
            var bvm: i32[>..<] = [];
            for k in gs.len { bvm.push(-1); }
            try_pack_scalars(gs, bvm, true);
            let bv = ce_gather(gs, bvm.len, -1);
            ce_add_v(bv, bvm, false);
        }
        var plain = true;
        for v in nonc {
            if !(is_poison(v) || (single_shuffle && ((ident_shuffle && non_poisoned) || used_in_expr) && is_undef_or_poison(v))) { plain = false; break; }
        }
        if plain {
            res = ce_finalize(te_reuse(e), sub_te, sub_idx, svmask, 0, false);
        } else {
            var vec = ce_finalize_action_begin();
            // the Action(Vec, Mask, CreateShuffle) of processBuildVector
            let splat = slp_is_splat(nonc);
            var bvm: i32[>..<] = [];
            for k in ce_common.len { bvm.push(-1); }
            try_pack_scalars(nonc, bvm, false);
            fn splat_profitable() -> bool {
                var v: i32 = -1;
                for x in nonc { if !is_undef_or_poison(x) { v = x; break; } }
                if is_inst_op(v, OP_EXTRACTELEMENT) || slp_is_vectorized(v) { return false; }
                var sc = tv_vec_inst(OP_INSERTELEMENT, vecty, 0, c_poison(vecty), v, TCK_RECIP_THROUGHPUT);
                var nm: i32[>..<] = [];
                slp_copy_list(ce_common, nm);
                for k in bvm.len { if bvm[k] != -1 { nm[k] = ce_common.len as i32; } }
                sc = tc_add(sc, slp_shuffle_cost(SK_PERMUTETWOSRC, vecty, nm, 0, -1));
                var fi: i64 = 0;
                for x in ce_common { if x != -1 { fi = x as i64; break; } }
                var bc = tv_vec_inst(OP_INSERTELEMENT, vecty, fi, vx_real_or_null(vec), v, TCK_RECIP_THROUGHPUT);
                var np: i64 = 0;
                for x in bvm { if x == -1 { np++; } }
                if np < bvm.len - 1 {
                    var nm2: i32[>..<] = [];
                    slp_copy_list(ce_common, nm2);
                    for k in bvm.len { if bvm[k] != -1 { nm2[k] = bvm[k]; } }
                    bc = tc_add(bc, slp_shuffle_cost(SK_PERMUTESINGLESRC, vecty, nm2, 0, -1));
                }
                return sc <= bc;
            }
            if !splat || ce_common.len <= 2 || !splat_profitable() {
                for k in bvm.len { if bvm[k] != -1 { ce_common[k] = bvm[k]; } }
                vec = ce_gather(nonc, ce_common.len, vec);
            } else {
                var v: i32 = -1;
                for x in nonc { if !is_undef_or_poison(x) { v = x; break; } }
                var values: i32[>..<] = [];
                for k in nonc.len { values.push(c_poison(sty)); }
                values[0] = v;
                var bv = ce_gather(values, bvm.len, -1);
                var sm: i32[>..<] = [];
                for x in bvm { sm.push(if x == -1 { -1 } else { 0 }); }
                if !slp_is_identity_mask(sm, vf) { ce_cost = tc_add(ce_cost, ce_create_shuffle(scv_v(bv), scv_null(), sm, slp_no_mask())); }
                for k in bvm.len { if bvm[k] != -1 { ce_common[k] = (bvm.len + k) as i32; } }
                ce_cost = tc_add(ce_cost, ce_create_shuffle(scv_v(vec), scv_v(bv), ce_common, slp_no_mask()));
                for k in ce_common.len { if ce_common[k] != -1 { ce_common[k] = k as i32; } }
            }
            ce_finalize_action_end(vec);
            res = ce_finalize(te_reuse(e), sub_te, sub_idx, svmask, te_nscalars(e), false);
        }
    } else if !slp_all_constant(gs) {
        var rm: i32[>..<] = [];
        for k in gs.len { rm.push(-1); }
        try_pack_scalars(gs, rm, true);
        let bv = ce_gather(gs, rm.len, -1);
        ce_add_v(bv, rm, false);
        res = ce_finalize(te_reuse(e), sub_te, sub_idx, svmask, 0, false);
    } else {
        var m2: i32[>..<] = [];
        for v in gs { m2.push(-1); }
        for i in gs.len { if !is_poison(gs[i]) { m2[i] = i as i32; } }
        let bv = ce_gather(gs, 0, -1);
        ce_add_v(bv, m2, false);
        res = ce_finalize(te_reuse(e), sub_te, sub_idx, svmask, 0, false);
    }
    // createFreeze(Cost) is the cost itself
    return res;
}
fn vx_real_or_null(x: i32) -> i32 { if x >= 0 { x } else { -1 } }
fn slp_no_imask() -> const i64[:] { slp_no_i64_buf[..0] }
var slp_no_i64_buf: i64[1];
// shortBundleName(VL, Idx)
fn slp_short_bundle_name(vl: const i32[:], idx: i32) {
    errs("Idx: "); errs_int(idx as i64); errs(", n="); errs_int(vl.len); errs(" ["); slp_dv(vl[0]); errs(", ..]");
}
