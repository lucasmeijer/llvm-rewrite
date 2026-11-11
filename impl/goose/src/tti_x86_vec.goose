// The X86 cost model, part 2: vector element ops, scalarization overhead, shuffles, memory ops (plain, masked,
// gather/scatter), reductions. Ports
//   llvm/lib/Target/X86/X86TargetTransformInfo.cpp  (getVectorInstrCost, getScalarizationOverhead, getShuffleCost,
//       getReplicationShuffleCost, getMemoryOpCost, getMemIntrinsicInstrCost, getMaskedMemoryOpCost,
//       getGSVectorCost, getGatherScatterOpCost, isLegalMasked*, getArithmeticReductionCost, getMinMaxCost,
//       getMinMaxReductionCost)
//   llvm/include/llvm/CodeGen/BasicTTIImpl.h        (the BaseT:: versions, improveShuffleKindFromMask,
//       getCommonMaskedMemoryOpCost, getTreeReductionCost, getOrderedReductionCost)
//   llvm/lib/IR/Instructions.cpp                    (ShuffleVectorInst's static mask predicates)
//   llvm/lib/Analysis/VectorUtils.cpp               (processShuffleMasks)
//
// Shuffle masks and demanded-element sets are runs (start, length) in the global pool mk_pool (these functions
// are mutually recursive, so they can't keep growable locals); a caller that pushes runs releases them with
// mk_release(mark) when done. Mask elements: -1 = poison.
import std;
import ir;
import irutil;
import instinfo;
import gen_iids;
import gen_x86target;
import gen_x86costs;
import x86_lower;
import tti_x86;
import tti_x86_intr;
import datalayout;
import apint;
import pm;

var mk_pool: i32[>..<] = [];
fn mk_mark() -> i64 { mk_pool.len }
fn mk_release(m: i64) { mk_pool.resize(m, 0); }
fn mk_push_n(n: i64, v: i32) -> i64 { let s = mk_pool.len; for k in n { mk_pool.push(v); } return s; }
fn mk_copy(s: i64, n: i64) -> i64 { let d = mk_pool.len; for k in n { mk_pool.push(mk_pool[s + k]); } return d; }
fn mk_at(s: i64, k: i64) -> i64 { mk_pool[s + k] as i64 }
fn mk_count_set(s: i64, n: i64) -> i64 { var c: i64 = 0; for k in n { if mk_pool[s + k] != 0 { c++; } } return c; }

// ---------------------------------------------------------------- shuffle mask predicates (Instructions.cpp)

fn sv_single_source_impl(s: i64, n: i64, nsrc: i64) -> bool {
    var l = false;
    var r = false;
    for k in n {
        let i = mk_at(s, k);
        if i == -1 { continue; }
        if i < nsrc { l = true; }
        if i >= nsrc { r = true; }
        if l && r { return false; }
    }
    return l || r;
}
fn sv_is_single_source(s: i64, n: i64, nsrc: i64) -> bool { sv_single_source_impl(s, n, nsrc) }
fn sv_identity_impl(s: i64, n: i64, nsrc: i64) -> bool {
    if !sv_single_source_impl(s, n, nsrc) { return false; }
    for k in n {
        let m = mk_at(s, k);
        if m == -1 { continue; }
        if m != k as i64 && m != nsrc + k as i64 { return false; }
    }
    return true;
}
fn sv_is_identity(s: i64, n: i64, nsrc: i64) -> bool { n == nsrc && sv_identity_impl(s, n, nsrc) }
fn sv_is_reverse(s: i64, n: i64, nsrc: i64) -> bool {
    if n != nsrc || !sv_is_single_source(s, n, nsrc) || nsrc < 2 { return false; }
    for k in n {
        let m = mk_at(s, k);
        if m == -1 { continue; }
        if m != nsrc - 1 - k as i64 && m != nsrc + nsrc - 1 - k as i64 { return false; }
    }
    return true;
}
fn sv_is_zero_elt_splat(s: i64, n: i64, nsrc: i64) -> bool {
    if n != nsrc || !sv_is_single_source(s, n, nsrc) { return false; }
    for k in n {
        let m = mk_at(s, k);
        if m == -1 { continue; }
        if m != 0 && m != nsrc { return false; }
    }
    return true;
}
fn sv_is_select(s: i64, n: i64, nsrc: i64) -> bool {
    if n != nsrc || sv_is_single_source(s, n, nsrc) { return false; }
    for k in n {
        let m = mk_at(s, k);
        if m == -1 { continue; }
        if m != k as i64 && m != nsrc + k as i64 { return false; }
    }
    return true;
}
fn sv_is_transpose(s: i64, n: i64, nsrc: i64) -> bool {
    if n != nsrc { return false; }
    if n < 2 || (n & (n - 1)) != 0 { return false; }
    if mk_at(s, 0) != 0 && mk_at(s, 0) != 1 { return false; }
    if mk_at(s, 1) - mk_at(s, 0) != nsrc { return false; }
    for k in 2..n {
        let v = mk_at(s, k);
        if v == -1 { return false; }
        if v - mk_at(s, k - 2) != 2 { return false; }
    }
    return true;
}
fn sv_is_splice(s: i64, n: i64, nsrc: i64) -> bool, i64 {
    if n != nsrc { return false, 0; }
    var start: i64 = -1;
    for k in n {
        let v = mk_at(s, k);
        if v == -1 { continue; }
        if start == -1 {
            if v < k as i64 || nsrc <= v - k as i64 { return false, 0; }
            start = v - k as i64;
            continue;
        }
        if v != start + k as i64 { return false, 0; }
    }
    if start == -1 { return false, 0; }
    return true, start;
}
fn sv_is_extract_subvector(s: i64, n: i64, nsrc: i64) -> bool, i64 {
    if !sv_single_source_impl(s, n, nsrc) { return false, 0; }
    if nsrc <= n { return false, 0; }
    var sub: i64 = -1;
    for k in n {
        let m = mk_at(s, k);
        if m < 0 { continue; }
        let off = (m % nsrc) - k as i64;
        if 0 <= sub && sub != off { return false, 0; }
        sub = off;
    }
    if 0 <= sub && sub + n <= nsrc { return true, sub; }
    return false, 0;
}
// (ok, NumSubElts, Index)
fn sv_is_insert_subvector(s: i64, n: i64, nsrc: i64) -> bool, i64, i64 {
    if n < nsrc { return false, 0, 0; }
    if sv_single_source_impl(s, n, nsrc) { return false, 0, 0; }
    var s0id = true;
    var s1id = true;
    var s0lo: i64 = n;
    var s1lo: i64 = n;
    var s0hi: i64 = 0;
    var s1hi: i64 = 0;
    for k in n {
        let m = mk_at(s, k);
        if m < 0 { continue; }
        if m < nsrc {
            if s0lo == n { s0lo = k as i64; }
            s0hi = k as i64 + 1;
            s0id = s0id && m == k as i64;
            continue;
        }
        if s1lo == n { s1lo = k as i64; }
        s1hi = k as i64 + 1;
        s1id = s1id && m == k as i64 + nsrc;
    }
    if s0id {
        let ns = s1hi - s1lo;
        if ns > 0 && sv_identity_impl(s + s1lo, ns, nsrc) { return true, ns, s1lo; }
        if ns <= 0 && sv_identity_impl(s + s1lo, 0, nsrc) { return true, 0, s1lo; }
    }
    if s1id {
        let ns = s0hi - s0lo;
        if ns > 0 && sv_identity_impl(s + s0lo, ns, nsrc) { return true, ns, s0lo; }
    }
    return false, 0, 0;
}
fn sv_replication_with_params(s: i64, n: i64, rf: i64, vf: i64) -> bool {
    var p = s;
    for cur in vf {
        for k in rf {
            let m = mk_at(p, k);
            if m != -1 && m != cur as i64 { return false; }
        }
        p += rf;
    }
    return true;
}
// BasicTTIImplBase::isSplatMask: (ok, index)
fn sv_is_splat(s: i64, n: i64, nsrc: i64) -> bool, i64 {
    var compared = false;
    var splat: i64 = -1;
    for k in n {
        let v = mk_at(s, k);
        if v == -1 {
            if !(k as i64 != n - 1 || compared) { return false, 0; }
            continue;
        }
        if v < 0 || v >= nsrc * 2 { return false, 0; }
        if splat == -1 {
            splat = v;
            if !(k as i64 != n - 1) { return false, 0; }
            continue;
        }
        compared = true;
        if splat != v { return false, 0; }
    }
    return true, splat;
}

// BasicTTIImplBase::improveShuffleKindFromMask: (kind, index, subtype)
recursive fn bt_improve_shuffle_kind(sk: i64, s: i64, n: i64, src: i32, index: i64, subtp: i32) -> i64, i64, i32 {
    if n == 0 { return sk, index, subtp; }
    let nsrc = ty_count(src);
    if sk == SK_PERMUTESINGLESRC {
        if sv_is_reverse(s, n, nsrc) { return SK_REVERSE, index, subtp; }
        if sv_is_zero_elt_splat(s, n, nsrc) { return SK_BROADCAST, index, subtp; }
        let sp, si = sv_is_splat(s, n, nsrc);
        if sp { return SK_BROADCAST, si, subtp; }
        let ex, ei = sv_is_extract_subvector(s, n, nsrc);
        if ex && ei + n <= nsrc { return SK_EXTRACTSUBVECTOR, ei, tt_vec(ty_elem(src), n); }
        return sk, index, subtp;
    }
    if sk == SK_PERMUTETWOSRC {
        var all_lo = true;
        for k in n { if mk_at(s, k) >= nsrc { all_lo = false; } }
        if all_lo { return bt_improve_shuffle_kind(SK_PERMUTESINGLESRC, s, n, src, index, subtp); }
        if n > 2 {
            let ins, nsub, ii = sv_is_insert_subvector(s, n, nsrc);
            if ins {
                if ii + nsub > nsrc { return sk, index, subtp; }
                return SK_INSERTSUBVECTOR, ii, tt_vec(ty_elem(src), nsub);
            }
        }
        if sv_is_select(s, n, nsrc) { return SK_SELECT, index, subtp; }
        if sv_is_transpose(s, n, nsrc) { return SK_TRANSPOSE, index, subtp; }
        let spl, spi = sv_is_splice(s, n, nsrc);
        if spl { return SK_SPLICE, spi, subtp; }
        return sk, index, subtp;
    }
    return sk, index, subtp;
}

// ---------------------------------------------------------------- getVectorInstrCost

// BasicTTIImplBase::getVectorInstrCost = getRegUsageForType(Val->getScalarType())
fn bt_vector_inst_cost(vt: i32) -> i64 { x86_reg_usage(ty_scalar(vt)) }

// X86TTIImpl::getVectorInstrCost (opcode, vector type, index (-1 unknown), op0, op1 (insertelement operands or -1))
recursive fn x86_vector_inst_cost(o: i64, vt: i32, index0: i64, op0: i32, op1: i32, kind: i64) -> i64 {
    if ty_kind(vt) == TK_SVEC { return TTI_INVALID; }
    let sty = ty_scalar(vt);
    var rfm: i64 = 0;
    var index = index0;
    if index == -1 && (o == OP_EXTRACTELEMENT || o == OP_INSERTELEMENT) {
        let va = dl_align(vt, false);
        let sa = dl_align(sty, false);
        if o == OP_EXTRACTELEMENT {
            return tc_add(x86_memory_op_cost(OP_STORE, vt, va, 0, kind, 0, -1), x86_memory_op_cost(OP_LOAD, sty, sa, 0, kind, 0, -1));
        }
        return tc_add3(x86_memory_op_cost(OP_STORE, vt, va, 0, kind, 0, -1), x86_memory_op_cost(OP_STORE, sty, sa, 0, kind, 0, -1),
                       x86_memory_op_cost(OP_LOAD, vt, va, 0, kind, 0, -1));
    }
    if index != -1 && (o == OP_EXTRACTELEMENT || o == OP_INSERTELEMENT) {
        if o == OP_EXTRACTELEMENT && tt_scalar_bits(sty) == 1 && ty_count(vt) > 1 { return 1; }
        let ltc, lt = x86_legalize(vt);
        if !mvt_is_vec(lt) { return TCC_FREE; }
        let size = mvt_bits(lt) as i64;
        let ne = mvt_nelem(lt) as i64;
        var sub = ne;
        index = index % ne;
        if size > 128 {
            let nsub = size / 128;
            sub = ne / nsub;
            if sub <= index {
                rfm += if o == OP_INSERTELEMENT { 2 } else { 1 };
                index = index % sub;
            }
        }
        let ms = mvt_elt(lt);
        let cheap = (ms == MVT_i16 && x86_sse2()) || (mvt_is_int(ms) && x86_sse41()) ||
                    (ms == MVT_f32 && x86_sse1() && index == 0 && o == OP_INSERTELEMENT) ||
                    (ms == MVT_f32 && x86_sse41() && o == OP_INSERTELEMENT);
        if index == 0 {
            if ty_is_fp(sty) && (o != OP_INSERTELEMENT || op0 == -1 || is_undef_or_poison(op0)) { return rfm; }
            if o == OP_INSERTELEMENT && op0 >= 0 && is_undef_or_poison(op0) {
                if op1 >= 0 && is_inst_op(op1, OP_LOAD) { return rfm; }
                if !cheap {
                    if op1 >= 0 && is_constant(op1) && ty_is_int(vals[op1].ty) { return 2 + rfm; }
                    return 1 + rfm;
                }
            }
            if ty_is_int(sty) && o == OP_EXTRACTELEMENT { return 1 + rfm; }
        }
        let isd = x86_isd_of_opcode(o);
        if x86_slm_arith() {
            if xct_has(XCT_V_SLMCostTbl, isd, ms, 0) { return xc1(XCT_V_SLMCostTbl, isd, ms, 0) + rfm; }
        }
        if cheap { return 1 + rfm; }
        var shuffle: i64 = 1;
        if o == OP_INSERTELEMENT {
            var subty = vt;
            let ev = x86_value_type(vt, false);
            if evt_elt(ev) != ms as i64 || evt_bits(ev) >= 128 { subty = tt_vec(sty, sub); }
            let m = mk_mark();
            shuffle = x86_shuffle_cost(SK_PERMUTETWOSRC, subty, subty, 0, 0, kind, 0, subty, -1, -1, 0, -1);
            mk_release(m);
        }
        let iof: i64 = if ty_is_fp(sty) { 0 } else { 1 };
        return tc_add(tc_add(shuffle, iof), rfm);
    }
    return tc_add(bt_vector_inst_cost(vt), rfm);
}

// ---------------------------------------------------------------- getScalarizationOverhead

// BasicTTIImplBase::getScalarizationOverhead(Ty, DemandedElts (run ds), Insert, Extract)
recursive fn bt_scalarization_overhead(ty: i32, ds: i64, insert: bool, extract: bool, kind: i64) -> i64 {
    if ty_kind(ty) == TK_SVEC { return TTI_INVALID; }
    var c: i64 = 0;
    for i in ty_count(ty) {
        if mk_at(ds, i) == 0 { continue; }
        if insert { c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, ty, i, -1, -1, kind)); }
        if extract { c = tc_add(c, x86_vector_inst_cost(OP_EXTRACTELEMENT, ty, i, -1, -1, kind)); }
    }
    return c;
}

// getScalarizationOverhead(Ty, Insert, Extract): every element demanded
recursive fn x86_scalarization_overhead_all(ty: i32, insert: bool, extract: bool, kind: i64) -> i64 {
    if ty_kind(ty) == TK_SVEC { return TTI_INVALID; }
    let m = mk_mark();
    let ds = mk_push_n(ty_count(ty), 1);
    let c = x86_scalarization_overhead(ty, ds, insert, extract, kind, true);
    mk_release(m);
    return c;
}
recursive fn bt_scalarization_overhead_all(ty: i32, insert: bool, extract: bool, kind: i64) -> i64 {
    let m = mk_mark();
    let ds = mk_push_n(ty_count(ty), 1);
    let c = bt_scalarization_overhead(ty, ds, insert, extract, kind);
    mk_release(m);
    return c;
}

// APIntOps::ScaleBitMask(A (run of n bits), NewBitWidth, MatchAllBits): a new run
fn mk_scale_bitmask(s: i64, n: i64, nw: i64, all: bool) -> i64 {
    let d = mk_push_n(nw, 0);
    if nw == n {
        for k in n { mk_pool[d + k] = mk_pool[s + k]; }
        return d;
    }
    if nw > n {
        let sc = nw / n;
        for k in n { if mk_pool[s + k] != 0 { for j in sc { mk_pool[d + k * sc + j] = 1; } } }
        return d;
    }
    let sc = n / nw;
    for i in nw {
        var any = false;
        var every = true;
        for j in sc { if mk_pool[s + i * sc + j] != 0 { any = true; } else { every = false; } }
        mk_pool[d + i] = if (if all { every } else { any }) { 1 } else { 0 };
    }
    return d;
}

// X86TTIImpl::getScalarizationOverhead
recursive fn x86_scalarization_overhead(ty: i32, ds: i64, insert: bool, extract: bool, kind: i64, for_poison: bool) -> i64 {
    let ne0 = ty_count(ty);
    let ltc, lt = x86_legalize(ty);
    let msty = mvt_elt(lt);
    let lvw = mvt_bits(lt) as i64;
    var c: i64 = 0;
    let lane: i64 = 128;
    let nlv = ltc;
    if insert && !for_poison {
        for i in ne0 {
            if mk_at(ds, i) == 0 { continue; }
            // Constant::getNullValue(Ty): a non-undef op0
            c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, ty, i, x86_null_value_marker(), -1, kind));
        }
        return c;
    }
    if insert {
        if (msty == MVT_i16 && x86_sse2()) || (mvt_is_int(msty) && x86_sse41()) || (msty == MVT_f32 && x86_sse41()) {
            if lvw <= lane {
                c = tc_add(c, bt_scalarization_overhead(ty, ds, insert, false, kind));
            } else {
                let m = mk_mark();
                let nll = lvw / lane;
                let nlt = nll * nlv;
                let nle = mvt_nelem(lt) as i64 * nlv;
                let epl = nle / nlt;
                let wd = mk_push_n(nle, 0);
                for k in ne0 { mk_pool[wd + k] = mk_pool[ds + k]; }
                let lane_ty = tt_vec(ty_elem(ty), epl);
                for i in nlt {
                    let le = wd + i * epl;
                    let cnt = mk_count_set(le, epl);
                    if cnt == 0 { continue; }
                    if cnt != epl {
                        c = tc_add(c, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, ty, ty, 0, 0, kind, i * epl, lane_ty, -1, -1, 0, -1));
                    }
                    c = tc_add(c, bt_scalarization_overhead(lane_ty, le, insert, false, kind));
                }
                let aff = mk_scale_bitmask(wd, nle, nlt, false);
                let full = mk_scale_bitmask(aff, nlt, nlv, true);
                for lv in nlv {
                    for l in nll {
                        let i = nll * lv + l;
                        if mk_at(aff, i) == 0 || (l == 0 && mk_at(full, lv) != 0) { continue; }
                        c = tc_add(c, x86_shuffle_cost(SK_INSERTSUBVECTOR, ty, ty, 0, 0, kind, i * epl, lane_ty, -1, -1, 0, -1));
                    }
                }
                mk_release(m);
            }
        } else if mvt_is_vec(lt) {
            if tt_is_int_or_intvec(ty) { c = tc_add(c, mk_count_set(ds, ne0)); }
            let ne = mvt_nelem(lt) as i64;
            let p2 = next_pow2_u(ne0);
            c = tc_add(c, tc_mul((if ne < p2 { ne } else { p2 }) - 1, ltc));
        }
    }
    if extract {
        if !insert && tt_scalar_bits(ty) == 1 && !x86_avx512() {
            let maxe: i64 = if x86_avx2() { 32 } else { 16 };
            return (ne0 + maxe - 1) / maxe;
        }
        if mvt_is_vec(lt) {
            let nle = mvt_nelem(lt) as i64 * nlv;
            if lvw > lane {
                let m = mk_mark();
                let nll = lvw / lane;
                let nlt = nll * nlv;
                let epl = nle / nlt;
                let wd = mk_push_n(nle, 0);
                for k in ne0 { mk_pool[wd + k] = mk_pool[ds + k]; }
                let lane_ty = tt_vec(ty_elem(ty), epl);
                for i in nlt {
                    let le = wd + i * epl;
                    if mk_count_set(le, epl) == 0 { continue; }
                    c = tc_add(c, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, ty, ty, 0, 0, kind, i * epl, lane_ty, -1, -1, 0, -1));
                    c = tc_add(c, bt_scalarization_overhead(lane_ty, le, false, extract, kind));
                }
                mk_release(m);
                return c;
            }
        }
        c = tc_add(c, bt_scalarization_overhead(ty, ds, false, extract, kind));
    }
    return c;
}

// a value that is neither undef nor a load/constant for getVectorInstrCost's Op0 check (Constant::getNullValue)
fn x86_null_value_marker() -> i32 { return -2; }

// ---------------------------------------------------------------- getShuffleCost

// BasicTTIImplBase::getShuffleCost
recursive fn bt_shuffle_cost(sk0: i64, dst: i32, src: i32, ms: i64, ml: i64, kind: i64, index0: i64, subtp0: i32) -> i64 {
    let sk, index, subtp = bt_improve_shuffle_kind(sk0, ms, ml, src, index0, subtp0);
    if sk == SK_BROADCAST {
        if ty_kind(src) != TK_FVEC { return TTI_INVALID; }
        var c = x86_vector_inst_cost(OP_EXTRACTELEMENT, src, 0, -1, -1, kind);
        for i in ty_count(src) { c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, src, i, -1, -1, kind)); }
        return c;
    }
    if sk == SK_SELECT || sk == SK_SPLICE || sk == SK_REVERSE || sk == SK_TRANSPOSE || sk == SK_PERMUTESINGLESRC ||
       sk == SK_PERMUTETWOSRC {
        if ty_kind(src) != TK_FVEC { return TTI_INVALID; }
        var c: i64 = 0;
        for i in ty_count(src) {
            c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, src, i, -1, -1, kind));
            c = tc_add(c, x86_vector_inst_cost(OP_EXTRACTELEMENT, src, i, -1, -1, kind));
        }
        return c;
    }
    if sk == SK_EXTRACTSUBVECTOR {
        var c: i64 = 0;
        for i in ty_count(subtp) {
            c = tc_add(c, x86_vector_inst_cost(OP_EXTRACTELEMENT, src, i + index, -1, -1, kind));
            c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, subtp, i, -1, -1, kind));
        }
        return c;
    }
    // SK_InsertSubvector
    var c: i64 = 0;
    for i in ty_count(subtp) {
        c = tc_add(c, x86_vector_inst_cost(OP_EXTRACTELEMENT, subtp, i, -1, -1, kind));
        c = tc_add(c, x86_vector_inst_cost(OP_INSERTELEMENT, dst, i + index, -1, -1, kind));
    }
    return c;
}

// IsBroadcastLoadFoldUser
fn x86_broadcast_load_fold_user(u: i32, a0: i32) -> bool {
    if is_inst_op(u, OP_INSERTELEMENT) && op(u, 1) == a0 { return true; }
    if ty_is_vector(vals[u].ty) { return false; }
    if is_inst(u) {
        let o = iop(u);
        if is_terminator_op(o) || o == OP_PHI || o == OP_ATOMICRMW || o == OP_CMPXCHG { return false; }
        if is_callbase(u) { return x86_cb_does_not_access_memory(u) && !x86_cb_may_have_side_effects(u); }
    }
    return true;
}
fn x86_cb_does_not_access_memory(u: i32) -> bool { !inst_may_read_or_write_memory(u) }
fn x86_cb_may_have_side_effects(u: i32) -> bool { inst_may_have_side_effects(u) }

// X86TTIImpl::getShuffleCost. (ms, ml): the mask (ml = 0: none); a0/a1/nargs: Args; cxt: CxtI or -1.
recursive fn x86_shuffle_cost(sk0: i64, dst: i32, src: i32, ms: i64, ml: i64, kind: i64, index0: i64, subtp0: i32,
                              a0: i32, a1: i32, nargs: i64, cxt: i32) -> i64 {
    var ltc, lt = x86_legalize(src);
    var sk, index, subtp = bt_improve_shuffle_kind(sk0, ms, ml, src, index0, subtp0);
    if nargs > 0 {
        var allc = is_constant(a0);
        if nargs > 1 && !is_constant(a1) { allc = false; }
        if allc { return TCC_FREE; }
    }
    let nsrc = ty_count(src);
    if sk == SK_PERMUTETWOSRC && ml == 2 * nsrc && sv_is_identity(ms, ml, ml) {
        let dbl = tt_vec(ty_elem(src), 2 * nsrc);
        return x86_shuffle_cost(SK_INSERTSUBVECTOR, dbl, dbl, ms, ml, kind, ml / 2, src, -1, -1, 0, -1);
    }
    if sk == SK_TRANSPOSE && lt != MVT_v4f64 && lt != MVT_v4i64 { sk = SK_PERMUTETWOSRC; }
    if sk == SK_BROADCAST {
        ltc = 1;
        if nargs > 0 {
            var fold = false;
            if is_inst_op(a0, OP_LOAD) && tt_has_one_use(a0) { fold = true; }
            else if is_inst_op(a0, OP_LOAD) && ty_kind(dst) == TK_FVEC && tt_num_uses(a0) == ty_count(dst) {
                fold = true;
                var u = vals[a0].first_use;
                while u >= 0 { if !x86_broadcast_load_fold_user(uses[u].user, a0) { fold = false; } u = uses[u].next; }
            }
            if fold && (x86_avx2() || (x86_avx() && mvt_scalar_bits(lt) >= 32)) { return TCC_FREE; }
        }
    }
    var in_lane = false;
    var single_elt = false;
    let pbits = tt_prim_bits(src);
    if pbits > 0 && pbits % 128 == 0 && tt_scalar_bits(src) == mvt_scalar_bits(lt) as i64 && ml == nsrc {
        let nlanes = pbits / 128;
        let epl = ml / nlanes;
        if ml % nlanes == 0 {
            in_lane = true;
            var npoison: i64 = 0;
            for k in ml {
                let m = mk_at(ms, k);
                if m == -1 { npoison++; continue; }
                if ((m % ml) / epl) != (k as i64 / epl) { in_lane = false; }
            }
            single_elt = ml - 1 == npoison;
        }
    }
    if mvt_is_vec(lt) && mvt_elt(lt) == MVT_bf16 { lt = mvt_vec(MVT_f16, mvt_nelem(lt) as i64); }
    if sk == SK_EXTRACTSUBVECTOR && mvt_is_vec(lt) {
        let ne = mvt_nelem(lt) as i64;
        if index % ne == 0 { return TCC_FREE; }
        let subc, sublt = x86_legalize(subtp);
        if mvt_is_vec(sublt) {
            let nse = mvt_nelem(sublt) as i64;
            if index % nse == 0 && ne % nse == 0 { return subc; }
            let orig = ty_count(subtp);
            if nse > orig && index % orig == 0 && nse % orig == 0 && mvt_elt(lt) == mvt_elt(sublt) &&
               mvt_bits(mvt_elt(lt)) as i64 == tt_prim_bits(ty_elem(src)) {
                let vecty = tt_vec(ty_elem(src), ne);
                let subty = tt_vec(ty_elem(src), nse);
                let ei = ((index % ne) / nse) * nse;
                let ec = x86_shuffle_cost(SK_EXTRACTSUBVECTOR, vecty, vecty, 0, 0, kind, ei, subty, -1, -1, 0, -1);
                if tt_prim_bits(subtp) >= 32 || x86_ssse3() { return tc_add(ec, 1); }
                return tc_add(ec, 2);
            }
        }
        sk = SK_PERMUTESINGLESRC;
    }
    if sk == SK_INSERTSUBVECTOR && mvt_is_vec(lt) {
        let dc, dlt = x86_legalize(dst);
        let ne = mvt_nelem(dlt) as i64;
        let subc, sublt = x86_legalize(subtp);
        if mvt_is_vec(sublt) {
            let nse = mvt_nelem(sublt) as i64;
            let matching = ne == nse && ty_count(subtp) % nse == 0;
            if index % nse == 0 && ne % nse == 0 { return if matching { TCC_FREE } else { subc }; }
        }
        if ltc == 1 && lt == MVT_v4f32 && subc == 1 && sublt == MVT_f32 && (index == 0 || x86_sse41()) { return 1; }
        sk = if index == 0 && ltc == 1 { SK_SELECT } else { SK_PERMUTETWOSRC };
    }
    let vt = x86_value_type(src, false);
    if evt_is_simple(vt) && evt_is_vec(vt) && evt_bits(vt) < 128 && !x86_ssse3() {
        if x86_sse2() {
            let r = xc1(XCT_H_SSE2SubVectorShuffleTbl, sk as i32, vt as i32, kind);
            if r >= 0 { return tc_mul(ltc, r); }
        }
    }
    if ltc != 1 {
        let legal = lt;
        if mvt_is_vec(legal) && mvt_bits(mvt_elt(legal)) as i64 == tt_prim_bits(ty_elem(src)) &&
           (mvt_nelem(legal) as i64) < ty_count(src) {
            let vsz = dl_store_size(src);
            let lsz = (mvt_bits(legal) as i64 + 7) / 8;
            let nsrcs = (vsz + lsz - 1) / lsz;
            var ndests = ltc;
            let single = tt_vec(ty_elem(src), mvt_nelem(legal) as i64);
            if ml > 0 && tc_valid(ndests) {
                let m = mk_mark();
                ndests = x86_legalize_first(tt_vec(ty_elem(src), ml));
                let e = ndests;
                let lne = mvt_nelem(legal) as i64;
                let nvf = lne * (if nsrcs > e { nsrcs } else { e });
                let nsr = nvf / lne;
                let ndr = nvf / lne;
                let norm = mk_push_n(nvf, -1);
                for k in ml { mk_pool[norm + k] = mk_pool[ms + k]; }
                let c = x86_process_shuffle_masks(norm, nvf, nsr, ndr, ndr, single, kind);
                mk_release(m);
                return c;
            }
            let nsh = tc_mul(nsrcs - 1, ndests);
            return tc_mul(nsh, x86_shuffle_cost(SK_PERMUTETWOSRC, single, single, 0, 0, kind, 0, -1, -1, -1, 0, -1));
        }
        return bt_shuffle_cost(sk, dst, src, ms, ml, kind, index, subtp);
    }
    if ltc == 1 && in_lane && single_elt { return TCC_BASIC; }
    var r: i64 = -1;
    let k32 = sk as i32;
    if xst_hasVBMI() { r = xc1(XCT_H_AVX512VBMIShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_bwi() { r = xc1(XCT_H_AVX512BWShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if in_lane && x86_avx512() { r = xc1(XCT_H_AVX512InLaneShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx512() { r = xc1(XCT_H_AVX512ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if in_lane && x86_avx2() { r = xc1(XCT_H_AVX2InLaneShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx2() { r = xc1(XCT_H_AVX2ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_xop() { r = xc1(XCT_H_XOPShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if in_lane && x86_avx() { r = xc1(XCT_H_AVX1InLaneShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_avx() { r = xc1(XCT_H_AVX1ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse41() { r = xc1(XCT_H_SSE41ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_ssse3() { r = xc1(XCT_H_SSSE3ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); } }
    if x86_sse2() {
        var is_load = false;
        if nargs > 0 && is_inst_op(a0, OP_LOAD) { is_load = true; }
        if nargs > 1 && is_inst_op(a1, OP_LOAD) { is_load = true; }
        if x86_sse3() && is_load && xct_has(XCT_H_SSE3BroadcastLoadTbl, k32, lt, 0) {
            return tc_mul(ltc, xc1(XCT_H_SSE3BroadcastLoadTbl, k32, lt, 0));
        }
        r = xc1(XCT_H_SSE2ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); }
    }
    if x86_sse1() {
        if ltc == 1 && lt == MVT_v4f32 && ml == 4 {
            let x0 = mk_at(ms, 0);
            let x1 = mk_at(ms, 1);
            let x2 = mk_at(ms, 2);
            let x3 = mk_at(ms, 3);
            if (x0 < 0 || x1 < 0 || (x0 & 4) == (x1 & 4)) && (x2 < 0 || x3 < 0 || (x2 & 4) == (x3 & 4)) { return 1; }
        }
        r = xc1(XCT_H_SSE1ShuffleTbl, k32, lt, kind); if r >= 0 { return tc_mul(ltc, r); }
    }
    return bt_shuffle_cost(sk, dst, src, ms, ml, kind, index, subtp);
}

fn x86_legalize_first(t: i32) -> i64 { let c, m = x86_legalize(t); return c; }
fn tt_has_one_use(v: i32) -> bool { let u = vals[v].first_use; u >= 0 && uses[u].next < 0 }
fn tt_num_uses(v: i32) -> i64 { var c: i64 = 0; var u = vals[v].first_use; while u >= 0 { c++; u = uses[u].next; } return c; }

// processShuffleMasks with the two actions of X86TTIImpl::getShuffleCost's split-type path.
// norm: the normalized mask (length sz); Dest masks live in the pool (2 * nsr runs of szd per destination).
recursive fn x86_process_shuffle_masks(norm: i64, sz: i64, nsr: i64, ndr: i64, nused: i64, single: i32, kind: i64) -> i64 {
    let szd = sz / ndr;
    let szs = sz / nsr;
    let nm = 2 * nsr;
    // res[I][r]: run at res + (I * nm + r) * szd; present flag at pres + I * nm + r
    let res = mk_push_n(ndr * nm * szd, -1);
    let pres = mk_push_n(ndr * nm, 0);
    for i in ndr {
        for k in szd {
            let idx = i * szd + k;
            if idx == sz { break; }
            let mv = mk_at(norm, idx);
            if mv >= 2 * sz || mv == -1 { continue; }
            let mi = mv % sz;
            let sr = mi / szs + (if mv >= sz { nsr } else { 0 });
            mk_pool[pres + i * nm + sr] = 1;
            mk_pool[res + (i * nm + sr) * szd + k] = (mi % szs) as i32;
        }
    }
    var cost: i64 = 0;
    var prev_src: i64 = 0;
    var prev_mask: i64 = -1;
    for i in nused {
        var nsrc: i64 = 0;
        var first: i64 = -1;
        for r in nm { if mk_at(pres, i * nm + r) != 0 { nsrc++; if first < 0 { first = r; } } }
        if nsrc == 0 { continue; }
        if nsrc == 1 {
            let rm = res + (i * nm + first) * szd;
            if !sv_is_identity(rm, szd, szd) {
                var same = prev_mask >= 0 && prev_src == first;
                if same { for k in szd { if mk_at(prev_mask, k) != mk_at(rm, k) { same = false; } } }
                if !same {
                    cost = tc_add(cost, x86_shuffle_cost(SK_PERMUTESINGLESRC, single, single, rm, szd, kind, 0, -1, -1, -1, 0, -1));
                } else {
                    cost = tc_add(cost, TCC_BASIC);
                }
                continue;
            }
            var anyp = false;
            for k in szd { if mk_at(rm, k) != -1 { anyp = true; } }
            if first != i && anyp { cost = tc_add(cost, TCC_FREE); }
            prev_src = first;
            prev_mask = rm;
            continue;
        }
        // many inputs
        var second: i64 = 0;
        loop {
            var fi: i64 = -1;
            second = -1;
            var fm: i64 = -1;
            var sm: i64 = -1;
            for r in nm {
                if mk_at(pres, i * nm + r) == 0 { continue; }
                let rm = res + (i * nm + r) * szd;
                if fi == second {
                    fi = r;
                    fm = rm;
                    continue;
                }
                second = r;
                sm = rm;
                x86_psm_combine(fm, sm, szd);
                cost = tc_add(cost, x86_shuffle_cost(SK_PERMUTETWOSRC, single, single, fm, szd, kind, 0, -1, -1, -1, 0, -1));
                x86_psm_normalize(fm, szd);
                mk_pool[pres + i * nm + r] = 0;
                for k in szd { mk_pool[rm + k] = -1; }
                sm = fm;
                second = fi;
            }
            if fi != second && second >= 0 {
                x86_psm_combine(sm, fm, szd);
                cost = tc_add(cost, x86_shuffle_cost(SK_PERMUTETWOSRC, single, single, sm, szd, kind, 0, -1, -1, -1, 0, -1));
                mk_pool[pres + i * nm + fi] = 0;
                for k in szd { mk_pool[fm + k] = -1; }
                x86_psm_normalize(sm, szd);
            }
            if second < 0 { break; }
        }
    }
    return cost;
}
fn x86_psm_combine(f: i64, s: i64, vf: i64) {
    for k in vf { if mk_pool[s + k] != -1 { mk_pool[f + k] = mk_pool[s + k] + vf as i32; } }
}
fn x86_psm_normalize(f: i64, vf: i64) {
    for k in vf { if mk_pool[f + k] != -1 { mk_pool[f + k] = k as i32; } }
}

// X86TTIImpl::getReplicationShuffleCost (demanded destination elements: run dd of vf * rf)
recursive fn x86_replication_shuffle_cost(elt0: i32, rf: i64, vf: i64, dd: i64, kind: i64) -> i64 {
    let eb = dl_size_bits(elt0);
    let elt = ty_int(eb);
    if !x86_avx512() { return bt_replication_shuffle_cost(elt, rf, vf, dd, kind); }
    var pb = eb;
    if eb == 32 || eb == 64 {
    } else if eb == 16 {
        if !x86_bwi() { pb = 32; }
    } else if eb == 8 {
        if !xst_hasVBMI() { pb = 32; }
    } else if eb == 1 {
        if x86_bwi() { pb = if xst_hasVBMI() { 8 } else { 16 }; } else { pb = 32; }
    } else {
        return bt_replication_shuffle_cost(elt, rf, vf, dd, kind);
    }
    let pe = ty_int(pb);
    let srcv = tt_vec(elt, vf);
    let psrcv = tt_vec(pe, vf);
    let nd = vf * rf;
    let pdstv = tt_vec(pe, nd);
    let dstv = tt_vec(elt, nd);
    let c1, l1 = x86_legalize(srcv);
    let c2, l2 = x86_legalize(psrcv);
    let c3, l3 = x86_legalize(pdstv);
    let c4, l4 = x86_legalize(dstv);
    if !mvt_is_vec(l1) || !mvt_is_vec(l2) || !mvt_is_vec(l3) || !mvt_is_vec(l4) {
        return bt_replication_shuffle_cost(elt, rf, vf, dd, kind);
    }
    if pb != eb {
        var pc = x86_cast_cost(OP_SEXT, psrcv, srcv, 0, kind, -1);
        pc = tc_add(pc, x86_cast_cost(OP_TRUNC, dstv, pdstv, 0, kind, -1));
        return tc_add(pc, x86_replication_shuffle_cost(pe, rf, vf, dd, kind));
    }
    let epd = mvt_nelem(l4) as i64;
    let ndv = (nd + epd - 1) / epd;
    let single = tt_vec(elt, epd);
    let m = mk_mark();
    let wide = mk_push_n(ndv * epd, 0);
    for k in nd { mk_pool[wide + k] = mk_pool[dd + k]; }
    let dv = mk_scale_bitmask(wide, ndv * epd, ndv, false);
    let ndem = mk_count_set(dv, ndv);
    mk_release(m);
    let sc = x86_shuffle_cost(SK_PERMUTESINGLESRC, single, single, 0, 0, kind, 0, -1, -1, -1, 0, -1);
    return tc_mul(sc, ndem);
}

// BasicTTIImplBase::getReplicationShuffleCost
recursive fn bt_replication_shuffle_cost(elt: i32, rf: i64, vf: i64, dd: i64, kind: i64) -> i64 {
    let srcv = tt_vec(elt, vf);
    let repv = tt_vec(elt, vf * rf);
    let m = mk_mark();
    let ds = mk_scale_bitmask(dd, vf * rf, vf, false);
    var c = x86_scalarization_overhead(srcv, ds, false, true, kind, true);
    c = tc_add(c, x86_scalarization_overhead(repv, dd, true, false, kind, true));
    mk_release(m);
    return c;
}

// ---------------------------------------------------------------- getMemoryOpCost

// BasicTTIImplBase::getMemoryOpCost
recursive fn bt_memory_op_cost(o: i64, src: i32, align: i64, as_: i64, kind: i64) -> i64 {
    if x86_value_type(src, true) == MVT_Other as i64 { return 4; }
    let ltc, lt = x86_legalize(src);
    if o == OP_LOAD && kind == TCK_LATENCY { return 4; }
    var c = ltc;
    if kind != TCK_RECIP_THROUGHPUT { return c; }
    if ty_is_vector(src) && dl_store_size(src) * 8 < mvt_bits(lt) as i64 {
        let mem = x86_value_type(src, false);
        var la = LA_EXPAND;
        if o == OP_STORE { la = tl_truncstore_action(lt as i64, mem); }
        else { la = tl_load_action(lt as i64, mem, XLE_EXTLOAD); }
        if la != LA_LEGAL && la != LA_CUSTOM {
            c = tc_add(c, x86_scalarization_overhead_all(src, o != OP_STORE, o == OP_STORE, kind));
        }
    }
    return c;
}

// X86TTIImpl::getMemoryOpCost. opinfo: the stored value's OperandValueInfo; i: the instruction or -1.
recursive fn x86_memory_op_cost(o: i64, src: i32, align0: i64, as_: i64, kind: i64, opinfo: i64, i: i32) -> i64 {
    if o == OP_LOAD && kind == TCK_LATENCY { return bt_memory_op_cost(o, src, align0, as_, kind); }
    if kind != TCK_RECIP_THROUGHPUT {
        if i >= 0 && is_inst_op(i, OP_STORE) {
            let p = op(i, 1);
            if is_inst_op(p, OP_GEP) {
                for k in 1..nops(p) { if !is_constant(op(p, k)) { return TCC_BASIC * 2; } }
            }
        }
        return TCC_BASIC;
    }
    if x86_value_type(src, true) == MVT_Other as i64 { return bt_memory_op_cost(o, src, align0, as_, kind); }
    let ltc, lt = x86_legalize(src);
    var c: i64 = 0;
    if o == OP_STORE && oi_is_constant(opinfo) {
        c = tc_add(c, x86_memory_op_cost(OP_LOAD, src, dl_align(src, true), 0, kind, opinfo, -1));
    }
    if ty_kind(src) != TK_FVEC || !mvt_is_vec(lt) {
        return tc_add(if mvt_is_fp(lt) { c } else { 0 }, ltc);
    }
    let is_load = o == OP_LOAD;
    let elt = ty_elem(src);
    let eb = dl_size_bits(elt);
    let nsrc = ty_count(src);
    var rem = nsrc;
    let maxb = (mvt_bits(lt) as i64 + 7) / 8;
    if 128 % eb != 0 { return bt_memory_op_cost(o, src, align0, as_, kind); }
    let per_xmm = 128 / eb;
    let xmm = tt_vec(elt, per_xmm);
    var align = align0;
    var cur = maxb;
    var sub_left: i64 = 0;
    while rem > 0 {
        if (8 * cur) % eb != 0 { return bt_memory_op_cost(o, src, align0, as_, kind); }
        let per_op = (8 * cur) / eb;
        let curv = if per_op > per_xmm { tt_vec(elt, per_op) } else { xmm };
        let coal = if per_op == 1 { curv } else { tt_vec(ty_int(eb * per_op), ty_count(curv) / per_op) };
        while rem > 0 {
            if rem < per_op && (!is_load || align < cur) && cur != 1 { break; }
            if cur == 32 && xst_isUnalignedMem32Slow() { c = tc_add(c, 2); }
            else if cur < 4 { c = tc_add(c, 2); }
            else { c = tc_add(c, 1); }
            if is_load && oi_is_uniform(opinfo) { return c; }
            let done = nsrc - rem;
            let zeroth = done % (mvt_nelem(lt) as i64) == 0;
            if sub_left == 0 {
                sub_left += ty_count(curv);
                if !zeroth {
                    c = tc_add(c, x86_shuffle_cost(if is_load { SK_INSERTSUBVECTOR } else { SK_EXTRACTSUBVECTOR }, src, src, 0, 0,
                                                   kind, done, curv, -1, -1, 0, -1));
                }
            }
            if cur <= 4 && !zeroth {
                let in_xmm = done % per_xmm;
                let ci = in_xmm / per_op;
                let m = mk_mark();
                let ds = mk_push_n(ty_count(coal), 0);
                mk_pool[ds + ci] = 1;
                c = tc_add(c, x86_scalarization_overhead(coal, ds, is_load, !is_load, kind, true));
                mk_release(m);
            }
            sub_left -= per_op;
            rem -= per_op;
            align = tt_common_align(align, cur);
        }
        cur = cur / 2;
    }
    return c;
}
fn tt_common_align(a: i64, off: i64) -> i64 {
    // commonAlignment(A, Offset): the largest power of two dividing both
    var x = a;
    while x > 1 && off % x != 0 { x = x / 2; }
    return x;
}

// ---------------------------------------------------------------- masked memory, gather / scatter

// isLegalMaskedLoadStore
fn x86_legal_masked_load_store_scalar(s: i32) -> bool {
    if !x86_avx() { return false; }
    let k = ty_kind(s);
    if k == TK_PTR { return true; }
    if k == TK_FLOAT || k == TK_DOUBLE { return true; }
    if k == TK_HALF && x86_bwi() { return true; }
    if k == TK_BFLOAT && xst_hasBF16() { return true; }
    if k != TK_INT { return false; }
    let w = ty_bits(s);
    return w == 32 || w == 64 || ((w == 8 || w == 16) && x86_bwi());
}
fn x86_is_legal_masked_load(t: i32) -> bool {
    if ty_is_vector(t) && ty_count(t) == 1 { return xst_hasCF() && x86_has_conditional_load_store_for_type(ty_scalar(t)); }
    return x86_legal_masked_load_store_scalar(ty_scalar(t));
}
fn x86_is_legal_masked_store(t: i32) -> bool { x86_is_legal_masked_load(t) }
fn x86_supports_gather() -> bool { x86_avx512() || (xst_hasFastGather() && x86_avx2()) }
fn x86_force_scalarize_masked_gather(t: i32) -> bool {
    let n = ty_count(t);
    return n == 1 || (x86_avx512() && (n == 2 || (n == 4 && !x86_vlx())));
}
fn x86_is_legal_masked_gather_scatter(t: i32) -> bool {
    let s = ty_scalar(t);
    let k = ty_kind(s);
    if k == TK_PTR || k == TK_FLOAT || k == TK_DOUBLE { return true; }
    if k != TK_INT { return false; }
    let w = ty_bits(s);
    return w == 32 || w == 64;
}
fn x86_is_legal_masked_gather(t: i32) -> bool {
    if !x86_supports_gather() || !xst_preferGather() { return false; }
    return x86_is_legal_masked_gather_scatter(t);
}
fn x86_is_legal_masked_scatter(t: i32) -> bool {
    if !x86_avx512() || !xst_preferScatter() { return false; }
    return x86_is_legal_masked_gather_scatter(t);
}
fn x86_is_legal_masked_expand_load(t: i32) -> bool {
    if !ty_is_vector(t) || !x86_avx512() || ty_count(t) == 1 { return false; }
    let s = ty_elem(t);
    let k = ty_kind(s);
    if k == TK_FLOAT || k == TK_DOUBLE { return true; }
    if k != TK_INT { return false; }
    let w = ty_bits(s);
    return w == 32 || w == 64 || ((w == 8 || w == 16) && xst_hasVBMI2());
}

// BasicTTIImplBase::getCommonMaskedMemoryOpCost
recursive fn bt_common_masked_memory_op_cost(o: i64, data: i32, align: i64, variable_mask: bool, gs: bool, kind: i64) -> i64 {
    if ty_kind(data) == TK_SVEC { return TTI_INVALID; }
    let vf = ty_count(data);
    var addr: i64 = 0;
    if gs { addr = x86_scalarization_overhead_all(tt_vec(ty_ptr(0), vf), false, true, kind); }
    let memc = tc_mul(x86_memory_op_cost(o, ty_elem(data), align, 0, kind, 0, -1), vf);
    let pack = x86_scalarization_overhead_all(data, o != OP_STORE, o == OP_STORE, kind);
    var cond: i64 = 0;
    if variable_mask {
        cond = tc_add(x86_scalarization_overhead_all(tt_vec(ty_int(1), vf), false, true, kind),
                      tc_mul(tc_add(x86_cf_cost(OP_CONDBR, kind), x86_cf_cost(OP_PHI, kind)), vf));
    }
    return tc_add(tc_add(addr, memc), tc_add(pack, cond));
}

// BasicTTIImplBase::getMemIntrinsicInstrCost
recursive fn bt_mem_intrinsic_cost(id: i32, data: i32, variable_mask: bool, align: i64, kind: i64) -> i64 {
    if id == IID_masked_scatter || id == IID_masked_gather || id == IID_vp_scatter || id == IID_vp_gather {
        let o = if id == IID_masked_gather || id == IID_vp_gather { OP_LOAD } else { OP_STORE };
        return bt_common_masked_memory_op_cost(o, data, align, variable_mask, true, kind);
    }
    if id == IID_experimental_vp_strided_load || id == IID_experimental_vp_strided_store {
        let o = if id == IID_experimental_vp_strided_load { OP_LOAD } else { OP_STORE };
        return bt_common_masked_memory_op_cost(o, data, align, variable_mask, true, kind);
    }
    if id == IID_vp_load || id == IID_vp_store || id == IID_vp_load_ff { return TTI_INVALID; }
    if id == IID_masked_load || id == IID_masked_store {
        return bt_common_masked_memory_op_cost(if id == IID_masked_load { OP_LOAD } else { OP_STORE }, data, align, true, false, kind);
    }
    if id == IID_masked_compressstore || id == IID_masked_expandload {
        return bt_common_masked_memory_op_cost(if id == IID_masked_expandload { OP_LOAD } else { OP_STORE }, data, align,
                                               variable_mask, true, kind);
    }
    fatal("TargetTransformInfo: getMemIntrinsicInstrCost of an unexpected intrinsic");
    return 0;
}

// X86TTIImpl::getMemIntrinsicInstrCost (data type, pointer value or -1, variable mask, alignment, address space)
recursive fn x86_mem_intrinsic_cost(id: i32, data: i32, ptr: i32, variable_mask: bool, align: i64, as_: i64, kind: i64) -> i64 {
    if id == IID_masked_scatter || id == IID_masked_gather {
        return x86_gather_scatter_cost(id, data, ptr, variable_mask, align, as_, kind);
    }
    if id == IID_masked_load || id == IID_masked_store { return x86_masked_memory_op_cost(id, data, align, as_, kind); }
    return bt_mem_intrinsic_cost(id, data, variable_mask, align, kind);
}

// X86TTIImpl::getMaskedMemoryOpCost
recursive fn x86_masked_memory_op_cost(id: i32, src: i32, align: i64, as_: i64, kind: i64) -> i64 {
    let o = if id == IID_masked_load { OP_LOAD } else { OP_STORE };
    let is_load = o == OP_LOAD;
    if ty_kind(src) != TK_FVEC { return x86_memory_op_cost(o, src, align, as_, kind, 0, -1); }
    let n = ty_count(src);
    let mask_ty = tt_vec(ty_int(8), n);
    if (is_load && !x86_is_legal_masked_load(src)) || (!is_load && !x86_is_legal_masked_store(src)) {
        let msplit = x86_scalarization_overhead_all(mask_ty, false, true, kind);
        let scmp = x86_cmpsel_cost(OP_ICMP, ty_int(8), -1, PRED_BAD_ICMP, kind, 0, 0, -1);
        let br = x86_cf_cost(OP_CONDBR, kind);
        let mcmp = tc_mul(tc_add(br, scmp), n);
        let vsplit = x86_scalarization_overhead_all(src, is_load, !is_load, kind);
        let memop = tc_mul(bt_memory_op_cost(o, ty_scalar(src), align, as_, kind), n);
        return tc_add(tc_add(memop, vsplit), tc_add(msplit, mcmp));
    }
    let ltc, lt = x86_legalize(src);
    let vt = x86_value_type(src, false);
    var c: i64 = 0;
    if lt == MVT_i16 || lt == MVT_i32 || lt == MVT_i64 { return tc_add(c, ltc); }
    if evt_is_simple(vt) && lt as i64 != vt && mvt_nelem(lt) as i64 == n {
        c = tc_add(c, tc_add(x86_shuffle_cost(SK_PERMUTETWOSRC, src, src, 0, 0, kind, 0, -1, -1, -1, 0, -1),
                             x86_shuffle_cost(SK_PERMUTETWOSRC, mask_ty, mask_ty, 0, 0, kind, 0, -1, -1, -1, 0, -1)));
    } else if tc_mul(ltc, mvt_nelem(lt) as i64) > n {
        let nm = tt_vec(ty_int(8), ltc * mvt_nelem(lt) as i64);
        c = tc_add(c, x86_shuffle_cost(SK_INSERTSUBVECTOR, nm, nm, 0, 0, kind, 0, mask_ty, -1, -1, 0, -1));
    }
    if !x86_avx512() { return tc_add(c, tc_mul(ltc, if is_load { 2 } else { 8 })); }
    return tc_add(c, ltc);
}

// X86TTIImpl::getGSVectorCost
recursive fn x86_gs_vector_cost(o: i64, kind: i64, src: i32, ptr: i32, align: i64, as_: i64) -> i64 {
    let vf = ty_count(src);
    var isz = dl_ptr(0).bits;
    if x86_avx512() && vf >= 16 { isz = x86_gs_index_size(ptr); }
    let ivt = tt_vec(ty_int(isz), vf);
    let ic, il = x86_legalize(ivt);
    let sc, sl = x86_legalize(src);
    let split = tc_max(ic, sc);
    if split > 1 {
        let st = tt_vec(ty_scalar(src), vf / split);
        return tc_mul(x86_gs_vector_cost(o, kind, st, ptr, align, as_), split);
    }
    if kind == TCK_CODE_SIZE { return 1; }
    let ov: i64 = if o == OP_LOAD { if x86_avx512() || (x86_avx2() && xst_hasFastGather()) { 2 } else { 1024 } }
                  else { if x86_avx512() { 2 } else { 1024 } };
    return tc_add(ov, tc_mul(x86_memory_op_cost(o, ty_scalar(src), align, as_, kind, 0, -1), vf));
}
fn x86_gs_index_size(ptr: i32) -> i64 {
    let isz = dl_ptr(0).bits;
    if isz < 64 || ptr < 0 || !is_inst_op(ptr, OP_GEP) { return isz; }
    var nvar: i64 = 0;
    let base = op(ptr, 0);
    if ty_is_vector(vals[base].ty) && tti_get_splat_value(base) < 0 { return isz; }
    for k in 1..nops(ptr) {
        let ix = op(ptr, k);
        if is_constant(ix) { continue; }
        let it = ty_scalar(vals[ix].ty);
        if tt_prim_bits(it) == 64 && !is_inst_op(ix, OP_SEXT) { return isz; }
        nvar++;
        if nvar > 1 { return isz; }
    }
    return 32;
}

// X86TTIImpl::getGatherScatterOpCost
recursive fn x86_gather_scatter_cost(id: i32, src: i32, ptr: i32, variable_mask: bool, align: i64, as_: i64, kind: i64) -> i64 {
    let is_load = id == IID_masked_gather || id == IID_vp_gather;
    if (is_load && (!x86_is_legal_masked_gather(src) || x86_force_scalarize_masked_gather(src))) ||
       (!is_load && (!x86_is_legal_masked_scatter(src) || x86_force_scalarize_masked_gather(src))) {
        return bt_mem_intrinsic_cost(id, src, variable_mask, align, kind);
    }
    return x86_gs_vector_cost(if is_load { OP_LOAD } else { OP_STORE }, kind, src, ptr, align, as_);
}

// ---------------------------------------------------------------- reductions

// BasicTTIImplBase::getTreeReductionCost
recursive fn bt_tree_reduction_cost(o: i64, ty0: i32, kind: i64) -> i64 {
    if ty_kind(ty0) == TK_SVEC { return TTI_INVALID; }
    var ty = ty0;
    let st = ty_elem(ty);
    var n = ty_count(ty);
    if (o == OP_OR || o == OP_AND) && ty_is_int(st) && ty_bits(st) == 1 && n >= 2 {
        let vt = ty_int(n);
        return tc_add(x86_cast_cost(OP_BITCAST, vt, ty, 0, kind, -1), x86_cmpsel_cost(OP_ICMP, vt, ty_int(1), PRED_BAD_ICMP, kind, 0, 0, -1));
    }
    var levels: i64 = 0;
    while (1 << (levels + 1)) <= n { levels++; }
    var arith: i64 = 0;
    var shuf: i64 = 0;
    let ltc, lt = x86_legalize(ty);
    var longc: i64 = 0;
    let mvtlen: i64 = if mvt_is_vec(lt) { mvt_nelem(lt) as i64 } else { 1 };
    while n > mvtlen {
        n = n / 2;
        let sub = tt_vec(st, n);
        shuf = tc_add(shuf, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, sub, ty, 0, 0, kind, n, sub, -1, -1, 0, -1));
        arith = tc_add(arith, x86_arith0(o, sub, kind));
        ty = sub;
        longc++;
    }
    levels -= longc;
    shuf = tc_add(shuf, tc_mul(x86_shuffle_cost(SK_PERMUTESINGLESRC, ty, ty, 0, 0, kind, 0, ty, -1, -1, 0, -1), levels));
    arith = tc_add(arith, tc_mul(x86_arith0(o, ty, kind), levels));
    return tc_add3(shuf, arith, x86_vector_inst_cost(OP_EXTRACTELEMENT, ty, 0, -1, -1, kind));
}

// BasicTTIImplBase::getOrderedReductionCost
recursive fn bt_ordered_reduction_cost(o: i64, ty: i32, kind: i64) -> i64 {
    if ty_kind(ty) == TK_SVEC { return TTI_INVALID; }
    let ex = x86_scalarization_overhead_all(ty, false, true, kind);
    let ar = tc_mul(x86_arith0(o, ty_elem(ty), kind), ty_count(ty));
    return tc_add(ex, ar);
}

// BasicTTIImplBase::getArithmeticReductionCost. ordered: TTI::requiresOrderedReduction(FMF)
recursive fn bt_arith_reduction_cost(o: i64, ty: i32, ordered: bool, kind: i64) -> i64 {
    if ordered { return bt_ordered_reduction_cost(o, ty, kind); }
    return bt_tree_reduction_cost(o, ty, kind);
}

// X86TTIImpl::getArithmeticReductionCost
recursive fn x86_arith_reduction_cost(o: i64, valty: i32, ordered: bool, kind: i64) -> i64 {
    if ordered { return bt_arith_reduction_cost(o, valty, ordered, kind); }
    let isd = x86_isd_of_opcode(o);
    let vt = x86_value_type(valty, false);
    if evt_is_simple(vt) {
        let m = vt as i32;
        if x86_slm_arith() && xct_has(XCT_R_SLMCostTbl, isd, m, 0) { return xc1(XCT_R_SLMCostTbl, isd, m, 0); }
        if x86_bwi() && xct_has(XCT_R_AVX512BWCostTbl, isd, m, 0) { return xc1(XCT_R_AVX512BWCostTbl, isd, m, 0); }
        if x86_avx512() && xct_has(XCT_R_AVX512FCostTbl, isd, m, 0) { return xc1(XCT_R_AVX512FCostTbl, isd, m, 0); }
        if x86_avx() && xct_has(XCT_R_AVX1CostTbl, isd, m, 0) { return xc1(XCT_R_AVX1CostTbl, isd, m, 0); }
        if x86_sse2() && xct_has(XCT_R_SSE2CostTbl, isd, m, 0) { return xc1(XCT_R_SSE2CostTbl, isd, m, 0); }
    }
    let ltc, mty = x86_legalize(valty);
    if isd == XISD_MUL && mvt_elt(mty) == MVT_i8 {
        let wide = tt_vec(ty_int(16), ty_count(valty));
        return tc_add(x86_cast_cost(OP_ZEXT, wide, valty, 0, kind, -1), x86_arith_reduction_cost(o, wide, ordered, kind));
    }
    var ac: i64 = 0;
    if ltc != 1 && mvt_is_vec(mty) && (mvt_nelem(mty) as i64) < ty_count(valty) {
        let single = tt_vec(ty_elem(valty), mvt_nelem(mty) as i64);
        ac = tc_mul(x86_arith0(o, single, kind), ltc - 1);
    }
    if x86_slm_arith() && xct_has(XCT_R_SLMCostTbl, isd, mty, 0) { return tc_add(ac, xc1(XCT_R_SLMCostTbl, isd, mty, 0)); }
    if x86_avx() && xct_has(XCT_R_AVX1CostTbl, isd, mty, 0) { return tc_add(ac, xc1(XCT_R_AVX1CostTbl, isd, mty, 0)); }
    if x86_sse2() && xct_has(XCT_R_SSE2CostTbl, isd, mty, 0) { return tc_add(ac, xc1(XCT_R_SSE2CostTbl, isd, mty, 0)); }
    let et = ty_elem(valty);
    if ty_is_int(et) && ty_bits(et) == 1 {
        if isd == XISD_ADD {
            let it = ty_int(ty_count(valty));
            let m = ica_mark();
            let ic = ica_new(IID_ctpop, it, 0, -1, TTI_INVALID);
            ica_add_type(ic, it);
            let pc = x86_intrinsic_cost(ic, kind);
            ica_release(m);
            return tc_add(x86_cast_cost(OP_BITCAST, it, valty, 0, kind, -1), pc);
        }
        var ac2: i64 = 0;
        if ltc != 1 && mvt_is_vec(mty) && (mvt_nelem(mty) as i64) < ty_count(valty) {
            let single = tt_vec(ty_elem(valty), mvt_nelem(mty) as i64);
            ac2 = tc_mul(x86_arith0(o, single, kind), ltc - 1);
        }
        if x86_avx512() && xct_has(XCT_R_AVX512BoolReduction, isd, mty, 0) { return tc_add(ac2, xc1(XCT_R_AVX512BoolReduction, isd, mty, 0)); }
        if x86_avx2() && xct_has(XCT_R_AVX2BoolReduction, isd, mty, 0) { return tc_add(ac2, xc1(XCT_R_AVX2BoolReduction, isd, mty, 0)); }
        if x86_avx() && xct_has(XCT_R_AVX1BoolReduction, isd, mty, 0) { return tc_add(ac2, xc1(XCT_R_AVX1BoolReduction, isd, mty, 0)); }
        if x86_sse2() && xct_has(XCT_R_SSE2BoolReduction, isd, mty, 0) { return tc_add(ac2, xc1(XCT_R_SSE2BoolReduction, isd, mty, 0)); }
        return bt_arith_reduction_cost(o, valty, ordered, kind);
    }
    var nve = ty_count(valty);
    let ssz = tt_scalar_bits(valty);
    if (nve & (nve - 1)) != 0 || ssz != mvt_scalar_bits(mty) as i64 { return bt_arith_reduction_cost(o, valty, ordered, kind); }
    var rc: i64 = 0;
    var ty = valty;
    if ltc != 1 && mvt_is_vec(mty) && (mvt_nelem(mty) as i64) < ty_count(valty) {
        ty = tt_vec(ty_elem(valty), mvt_nelem(mty) as i64);
        rc = tc_mul(x86_arith0(o, ty, kind), ltc - 1);
        nve = mvt_nelem(mty) as i64;
    }
    while nve > 1 {
        let size = nve * ssz;
        nve = nve / 2;
        if size > 128 {
            let sub = tt_vec(ty_elem(valty), nve);
            rc = tc_add(rc, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, ty, ty, 0, 0, kind, nve, sub, -1, -1, 0, -1));
            ty = sub;
        } else if size == 128 {
            // ValVTy->isFloatingPointTy() is false for a vector type
            let sh = tt_vec(ty_int(64), 2);
            rc = tc_add(rc, x86_shuffle_cost(SK_PERMUTESINGLESRC, sh, sh, 0, 0, kind, 0, -1, -1, -1, 0, -1));
        } else if size == 64 {
            let sh = tt_vec(ty_int(32), 4);
            rc = tc_add(rc, x86_shuffle_cost(SK_PERMUTESINGLESRC, sh, sh, 0, 0, kind, 0, -1, -1, -1, 0, -1));
        } else {
            let sh = tt_vec(ty_int(size), 128 / size);
            rc = tc_add(rc, x86_arith_cost(OP_LSHR, sh, kind, 0, 2 * 4, -1, -1, 0, -1));
        }
        rc = tc_add(rc, x86_arith0(o, ty, kind));
    }
    return tc_add(rc, x86_vector_inst_cost(OP_EXTRACTELEMENT, ty, 0, -1, -1, kind));
}

// X86TTIImpl::getMinMaxCost
recursive fn x86_minmax_cost(id: i32, ty: i32, kind: i64, fmf: u8) -> i64 {
    let m = ica_mark();
    let ic = ica_new(id, ty, fmf, -1, TTI_INVALID);
    ica_add_type(ic, ty);
    ica_add_type(ic, ty);
    let c = x86_intrinsic_cost(ic, kind);
    ica_release(m);
    return c;
}

// BasicTTIImplBase::getMinMaxReductionCost
recursive fn bt_minmax_reduction_cost(id: i32, ty0: i32, fmf: u8, kind: i64) -> i64 {
    if ty_kind(ty0) == TK_SVEC { return TTI_INVALID; }
    var ty = ty0;
    let st = ty_elem(ty);
    var n = ty_count(ty);
    var levels: i64 = 0;
    while (1 << (levels + 1)) <= n { levels++; }
    var mm: i64 = 0;
    var shuf: i64 = 0;
    let ltc, lt = x86_legalize(ty);
    var longc: i64 = 0;
    let mvtlen: i64 = if mvt_is_vec(lt) { mvt_nelem(lt) as i64 } else { 1 };
    while n > mvtlen {
        n = n / 2;
        let sub = tt_vec(st, n);
        shuf = tc_add(shuf, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, sub, ty, 0, 0, kind, n, sub, -1, -1, 0, -1));
        mm = tc_add(mm, x86_minmax_cost(id, sub, kind, fmf));
        ty = sub;
        longc++;
    }
    levels -= longc;
    shuf = tc_add(shuf, tc_mul(x86_shuffle_cost(SK_PERMUTESINGLESRC, ty, ty, 0, 0, kind, 0, ty, -1, -1, 0, -1), levels));
    mm = tc_add(mm, tc_mul(x86_minmax_cost(id, ty, kind, fmf), levels));
    return tc_add3(shuf, mm, x86_vector_inst_cost(OP_EXTRACTELEMENT, ty, 0, -1, -1, kind));
}

// X86TTIImpl::getMinMaxReductionCost
recursive fn x86_minmax_reduction_cost(id: i32, valty: i32, fmf: u8, kind: i64) -> i64 {
    let ltc, mty = x86_legalize(valty);
    var isd = XISD_SMIN;
    if tt_is_int_or_intvec(valty) {
        isd = if id == IID_umin || id == IID_umax { XISD_UMIN } else { XISD_SMIN };
    } else {
        isd = if id == IID_minnum || id == IID_maxnum { XISD_FMINNUM } else { XISD_FMINIMUM };
    }
    let vt = x86_value_type(valty, false);
    var r: i64 = -1;
    if evt_is_simple(vt) {
        let m = vt as i32;
        if x86_bwi() { r = xc1(XCT_N_AVX512BWCostTbl, isd, m, kind); if r >= 0 { return r; } }
        if x86_avx512() { r = xc1(XCT_N_AVX512FCostTbl, isd, m, kind); if r >= 0 { return r; } }
        if x86_avx2() { r = xc1(XCT_N_AVX2CostTbl, isd, m, kind); if r >= 0 { return r; } }
        if x86_avx() { r = xc1(XCT_N_AVX1CostTbl, isd, m, kind); if r >= 0 { return r; } }
        if x86_sse41() { r = xc1(XCT_N_SSE41CostTbl, isd, m, kind); if r >= 0 { return r; } }
        if x86_sse2() { r = xc1(XCT_N_SSE2CostTbl, isd, m, kind); if r >= 0 { return r; } }
    }
    var nve = ty_count(valty);
    var ty = valty;
    var mm: i64 = 0;
    if ltc != 1 && mvt_is_vec(mty) && (mvt_nelem(mty) as i64) < ty_count(valty) {
        ty = tt_vec(ty_elem(valty), mvt_nelem(mty) as i64);
        mm = tc_mul(x86_minmax_cost(id, ty, kind, fmf), ltc - 1);
        nve = mvt_nelem(mty) as i64;
    }
    if x86_bwi() { r = xc1(XCT_N_AVX512BWCostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    if x86_avx512() { r = xc1(XCT_N_AVX512FCostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    if x86_avx2() { r = xc1(XCT_N_AVX2CostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    if x86_avx() { r = xc1(XCT_N_AVX1CostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    if x86_sse41() { r = xc1(XCT_N_SSE41CostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    if x86_sse2() { r = xc1(XCT_N_SSE2CostTbl, isd, mty, kind); if r >= 0 { return tc_add(mm, r); } }
    let ssz = tt_scalar_bits(valty);
    let n0 = ty_count(valty);
    if (n0 & (n0 - 1)) != 0 || ssz != mvt_scalar_bits(mty) as i64 { return bt_minmax_reduction_cost(id, valty, fmf, kind); }
    while nve > 1 {
        let size = nve * ssz;
        nve = nve / 2;
        if size > 128 {
            let sub = tt_vec(ty_elem(valty), nve);
            mm = tc_add(mm, x86_shuffle_cost(SK_EXTRACTSUBVECTOR, ty, ty, 0, 0, kind, nve, sub, -1, -1, 0, -1));
            ty = sub;
        } else if size == 128 {
            let sh = tt_vec(ty_int(64), 2);
            mm = tc_add(mm, x86_shuffle_cost(SK_PERMUTESINGLESRC, sh, sh, 0, 0, kind, 0, -1, -1, -1, 0, -1));
        } else if size == 64 {
            let sh = tt_vec(ty_int(32), 4);
            mm = tc_add(mm, x86_shuffle_cost(SK_PERMUTESINGLESRC, sh, sh, 0, 0, kind, 0, -1, -1, -1, 0, -1));
        } else {
            let sh = tt_vec(ty_int(size), 128 / size);
            mm = tc_add(mm, x86_arith_cost(OP_LSHR, sh, TCK_RECIP_THROUGHPUT, 0, 2 * 4, -1, -1, 0, -1));
        }
        mm = tc_add(mm, x86_minmax_cost(id, ty, kind, fmf));
    }
    return tc_add(mm, x86_vector_inst_cost(OP_EXTRACTELEMENT, ty, 0, -1, -1, kind));
}
