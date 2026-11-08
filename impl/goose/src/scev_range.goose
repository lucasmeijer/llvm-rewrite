// ScalarEvolution: constant multiples, ranges (getRangeRef, getRangeRefIter, getRangeForAffineAR,
// getRangeViaFactoring, getRangeForUnknownRecurrence, getRangeForAffineNoSelfWrappingAR), the isKnown*
// sign queries and setNoWrapFlags. Port of the corresponding parts of llvm/lib/Analysis/ScalarEvolution.cpp.
import std;
import scev_eval;
import scev_lt;
import scev_guards;
import implied;
import ir;
import irutil;
import instinfo;
import calls;
import pm;
import vt;
import knownbits;
import assume;
import datalayout;
import gen_attrs;
import gen_iids;
import apint;
import constrange;
import loopinfo;
import domtree;
import scev;
import scev_create;
import scev_btc;
import scev_pred;

let HINT_UNSIGNED = 0;
let HINT_SIGNED = 1;

struct ScCm { valid: bool, cm: i32 }    // the multiple as an IR constant
var sc_cm: ScCm[>..];
recursive fn sc_cm_grow() { while sc_cm.len < scevs.len { sc_cm.push(ScCm { valid: false, cm: -1 }); } }
recursive fn sc_cm_erase(s: i32) { sc_cm_grow(); sc_cm[s].valid = false; }

// ScalarEvolution::setNoWrapFlags(AddRec, Flags)
recursive fn sc_set_nowrap_flags(ar: i32, f: u32) {
    if (sc_flags(ar) & f) != f {
        sc_or_flags(ar, f);
        sc_side[ar].ur_valid = false;
        sc_side[ar].sr_valid = false;
        sc_cm_erase(ar);
    }
}

// computeKnownBits(V, DL, AC, CxtI, DT) as APInt known bits
// safeCxtI(V, CxtI): without a context, an instruction is its own context
recursive fn sc_compute_known_bits_cx(v: i32, cx0: i32) -> KB {
    let cx = if cx0 < 0 && is_inst(v) { v } else { cx0 };
    let save = kb_cxt;
    kb_cxt = cx;
    let k = kb_compute_all(v, 0);
    kb_cxt = save;
    return k;
}
recursive fn sc_compute_known_bits_ap(v: i32) -> KB { sc_compute_known_bits_cx(v, -1) }
recursive fn sc_num_sign_bits(v: i32) -> i64 {
    let save = kb_cxt;
    kb_cxt = if is_inst(v) { v } else { -1 };
    let r = num_sign_bits(v, 0);
    kb_cxt = save;
    return r;
}

recursive fn sc_shifted_by_zeros(bw: i64, tz: i64) -> AP { if tz >= bw { ap_zero(bw) } else { ap_one_bit(bw, tz) } }

// getConstantMultipleImpl
recursive fn sc_get_constant_multiple_impl(s: i32, cx0: i32) -> AP {
    var cx = cx0;
    let bw = sc_bits(s);
    let k = sc_kind(s);
    if k == SC_CONST { return sc_ap(s); }
    if k == SC_PTRTOADDR || k == SC_PTRTOINT { return sc_get_constant_multiple(sc_op(s, 0), -1); }
    if k == SC_UDIV || k == SC_VSCALE { return ap_u64(1, bw); }
    if k == SC_TRUNC || k == SC_SEXT { return sc_shifted_by_zeros(bw, sc_get_min_trailing_zeros_cx(sc_op(s, 0), cx)); }
    if k == SC_ZEXT { return ap_zext(sc_get_constant_multiple(sc_op(s, 0), cx), bw); }
    if k == SC_MUL {
        if sc_has_nuw(s) {
            var r = sc_get_constant_multiple(sc_op(s, 0), cx);
            for i in 1..sc_nops(s) { r = ap_mul(r, sc_get_constant_multiple(sc_op(s, i), cx)); }
            return r;
        }
        var tz: i64 = 0;
        for i in sc_nops(s) { tz += sc_get_min_trailing_zeros_cx(sc_op(s, i), cx); }
        return sc_shifted_by_zeros(bw, tz);
    }
    if k == SC_ADD || k == SC_ADDREC {
        if sc_has_nuw(s) { return sc_gcd_multiple(s, cx); }
        var tz = sc_get_min_trailing_zeros_cx(sc_op(s, 0), cx);
        for i in 1..sc_nops(s) { let t = sc_get_min_trailing_zeros_cx(sc_op(s, i), cx); if t < tz { tz = t; } }
        return sc_shifted_by_zeros(bw, tz);
    }
    if sc_is_minmax_kind(k) || k == SC_SEQUMIN { return sc_gcd_multiple(s, cx); }
    // SCEVUnknown
    let v = sc_value(s);
    if cx < 0 {
        if vals[v].kind as i64 == VK_ARG { cx = block_first(func_entry(sc_fv)); }
        else if is_inst(v) { cx = v; }
    }
    let save = vt_allow_ephemerals;
    vt_allow_ephemerals = true;
    let kn = sc_compute_known_bits_cx(v, cx);
    vt_allow_ephemerals = save;
    return sc_shifted_by_zeros(bw, ap_countr_one(kn.z));
}

recursive fn sc_gcd_multiple(s: i32, cx: i32) -> AP {
    var r = sc_get_constant_multiple(sc_op(s, 0), cx);
    var i: i64 = 1;
    while i < sc_nops(s) && !ap_is_one(r) {
        r = ap_gcd(r, sc_get_constant_multiple(sc_op(s, i), cx));
        i++;
    }
    return r;
}

recursive fn sc_get_constant_multiple(s: i32, cx: i32) -> AP {
    if cx >= 0 { return sc_get_constant_multiple_impl(s, cx); }
    sc_cm_grow();
    if sc_cm[s].valid { return ap_from_cint(sc_cm[s].cm); }
    let r = sc_get_constant_multiple_impl(s, cx);
    sc_cm_grow();
    sc_cm[s] = ScCm { valid: true, cm: ap_to_cint(ty_int(r.w as i64), r) };
    return r;
}
recursive fn sc_get_non_zero_constant_multiple(s: i32) -> AP {
    let m = sc_get_constant_multiple(s, -1);
    return if ap_is_zero(m) { ap_u64(1, m.w as i64) } else { m };
}
recursive fn sc_get_min_trailing_zeros_cx(s: i32, cx: i32) -> i64 {
    let tz = ap_countr_zero(sc_get_constant_multiple(s, cx));
    let bw = sc_bits(s);
    return if tz < bw { tz } else { bw };
}
recursive fn sc_get_min_trailing_zeros(s: i32) -> i64 { sc_get_min_trailing_zeros_cx(s, -1) }

// ---------------------------------------------------------------------------------------------
// Ranges

recursive fn sc_get_unsigned_range(s: i32) -> CRange { sc_get_range_ref(s, HINT_UNSIGNED, 0) }
recursive fn sc_get_signed_range(s: i32) -> CRange { sc_get_range_ref(s, HINT_SIGNED, 0) }
recursive fn sc_get_unsigned_range_min(s: i32) -> AP { rg_umin(sc_get_unsigned_range(s)) }
recursive fn sc_get_unsigned_range_max(s: i32) -> AP { rg_umax(sc_get_unsigned_range(s)) }
recursive fn sc_get_signed_range_min(s: i32) -> AP { rg_smin(sc_get_signed_range(s)) }
recursive fn sc_get_signed_range_max(s: i32) -> AP { rg_smax(sc_get_signed_range(s)) }

recursive fn sc_is_known_negative(s: i32) -> bool { ap_is_neg(sc_get_signed_range_max(s)) }
recursive fn sc_is_known_positive(s: i32) -> bool { ap_is_strictly_pos(sc_get_signed_range_min(s)) }
recursive fn sc_is_known_non_negative(s: i32) -> bool { !ap_is_neg(sc_get_signed_range_min(s)) }
recursive fn sc_is_known_non_positive(s: i32) -> bool { !ap_is_strictly_pos(sc_get_signed_range_max(s)) }
recursive fn sc_is_known_non_zero(s: i32) -> bool {
    if sc_kind(s) == SC_SEXT { return sc_is_known_non_zero(sc_op(s, 0)); }
    return !ap_is_zero(sc_get_unsigned_range_min(s));
}

recursive fn sc_range_cached(s: i32, hint: i64) -> bool { if hint == HINT_UNSIGNED { sc_side[s].ur_valid } else { sc_side[s].sr_valid } }
recursive fn sc_range_get(s: i32, hint: i64) -> CRange {
    if hint == HINT_UNSIGNED { return CRange { lo: ap_from_cint(sc_side[s].url), hi: ap_from_cint(sc_side[s].urh) }; }
    return CRange { lo: ap_from_cint(sc_side[s].srl), hi: ap_from_cint(sc_side[s].srh) };
}
// setRange
recursive fn sc_set_range(s: i32, hint: i64, c: CRange) -> CRange {
    let t = ty_int(c.lo.w as i64);
    let l = ap_to_cint(t, c.lo);
    let h = ap_to_cint(t, c.hi);
    if hint == HINT_UNSIGNED { sc_side[s].url = l; sc_side[s].urh = h; sc_side[s].ur_valid = true; }
    else { sc_side[s].srl = l; sc_side[s].srh = h; sc_side[s].sr_valid = true; }
    return c;
}

recursive fn sc_is_phi_value(v: i32) -> bool { is_inst(v) && iop(v) == OP_PHI }

// getRangeRefIter
recursive fn sc_get_range_ref_iter(s: i32, hint: i64) -> CRange {
    let wl = sc_newops.len;
    let seen = sc_seen.len;
    fn add(e: i32) {
        for k in seen..sc_seen.len { if sc_seen[k] == e { return; } }
        sc_seen.push(e);
        if sc_range_cached(e, hint) { return; }
        let k = sc_kind(e);
        if k == SC_UNKNOWN { if !sc_is_phi_value(sc_value(e)) { return; } }
        sc_newops.push(e);
    }
    add(s);
    var i = wl;
    while i < sc_newops.len {
        let p = sc_newops[i];
        if !sc_is_unknown(p) {
            if sc_kind(p) != SC_CONST && sc_kind(p) != SC_VSCALE { for k in sc_nops(p) { add(sc_op(p, k)); } }
            i++;
            continue;
        }
        let pv = sc_value(p);
        if sc_is_phi_value(pv) && sc_range_ref_phi_allowed_operands(pv) {
            var k = nops(pv) - 1;
            while k >= 0 { let x = sc_get_scev(op(pv, k)); add(x); k--; }
        }
        i++;
    }
    sc_seen.resize(seen);
    if sc_newops.len > wl {
        var j = sc_newops.len - 1;
        while j > wl { let r = sc_get_range_ref(sc_newops[j], hint, 0); j--; }
    }
    sc_newops.resize(wl);
    return sc_get_range_ref(s, hint, 0);
}

recursive fn sc_get_range_ref(s: i32, hint: i64, depth: i64) -> CRange {
    let rt = if hint == HINT_UNSIGNED { RG_UNSIGNED } else { RG_SIGNED };
    if sc_range_cached(s, hint) { return sc_range_get(s, hint); }
    if sc_is_const(s) { return sc_set_range(s, hint, rg_single(sc_ap(s))); }
    if depth > sc_range_iter_threshold { return sc_get_range_ref_iter(s, hint); }
    let bw = sc_bits(s);
    var cons = rg_full(bw);
    if hint == HINT_UNSIGNED {
        let m = sc_get_non_zero_constant_multiple(s);
        let rem = ap_urem(ap_ones(bw), m);
        if !ap_is_zero(rem) { cons = rg_new(ap_zero(bw), ap_inc(ap_sub(ap_ones(bw), rem))); }
    } else {
        let tz = sc_get_min_trailing_zeros(s);
        if tz != 0 { cons = rg_new(ap_smin_val(bw), ap_inc(ap_shl(ap_ashr(ap_smax_val(bw), tz), tz))); }
    }
    let k = sc_kind(s);
    if k == SC_VSCALE { return sc_set_range(s, hint, sc_vscale_range(bw)); }
    if k == SC_TRUNC {
        let x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        return sc_set_range(s, hint, rg_intersect_t(cons, rg_truncate(x, bw), rt));
    }
    if k == SC_ZEXT {
        let x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        return sc_set_range(s, hint, rg_intersect_t(cons, rg_zext(x, bw), rt));
    }
    if k == SC_SEXT {
        let x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        return sc_set_range(s, hint, rg_intersect_t(cons, rg_sext(x, bw), rt));
    }
    if k == SC_PTRTOADDR || k == SC_PTRTOINT {
        let x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        return sc_set_range(s, hint, x);
    }
    if k == SC_ADD {
        if hint == HINT_UNSIGNED {
            let ul, ur, ok = sc_match_urem(s);
            if ok {
                let lr = sc_get_range_ref(ul, hint, depth + 1);
                let rr = sc_get_range_ref(ur, hint, depth + 1);
                cons = rg_intersect_t(cons, rg_urem(lr, rr), rt);
            }
        }
        var x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        var wt: i64 = 0;
        if sc_has_nsw(s) { wt |= NW_NSW; }
        if sc_has_nuw(s) { wt |= NW_NUW; }
        for i in 1..sc_nops(s) { x = rg_add_nw(x, sc_get_range_ref(sc_op(s, i), hint, depth + 1), wt, rt); }
        return sc_set_range(s, hint, rg_intersect_t(cons, x, rt));
    }
    if k == SC_MUL {
        var x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        for i in 1..sc_nops(s) { x = rg_multiply(x, sc_get_range_ref(sc_op(s, i), hint, depth + 1), 0); }
        return sc_set_range(s, hint, rg_intersect_t(cons, x, rt));
    }
    if k == SC_UDIV {
        let x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        let y = sc_get_range_ref(sc_op(s, 1), hint, depth + 1);
        return sc_set_range(s, hint, rg_intersect_t(cons, rg_udiv(x, y), rt));
    }
    if k == SC_ADDREC {
        let ar = s;
        if sc_has_nuw(ar) {
            let umin = sc_get_unsigned_range_min(sc_op(ar, 0));
            if !ap_is_zero(umin) { cons = rg_intersect_t(cons, rg_new(umin, ap_zero(bw)), rt); }
        }
        if sc_has_nsw(ar) {
            var nn = true;
            var np = true;
            for i in 1..sc_nops(ar) {
                if !sc_is_known_non_negative(sc_op(ar, i)) { nn = false; }
                if !sc_is_known_non_positive(sc_op(ar, i)) { np = false; }
            }
            if nn { cons = rg_intersect_t(cons, rg_nonempty(sc_get_signed_range_min(sc_op(ar, 0)), ap_smin_val(bw)), rt); }
            else if np { cons = rg_intersect_t(cons, rg_nonempty(ap_smin_val(bw), ap_inc(sc_get_signed_range_max(sc_op(ar, 0)))), rt); }
        }
        if sc_is_affine(ar) {
            let maxbes = sc_get_constant_max_backedge_taken_count(sc_loop(ar));
            if !sc_is_cnc(maxbes) {
                var mbc = sc_ap(maxbes);
                if (mbc.w as i64) > bw && ap_active_bits(mbc) <= bw { mbc = ap_trunc(mbc, bw); }
                else if (mbc.w as i64) < bw { mbc = ap_zext(mbc, bw); }
                if (mbc.w as i64) == bw {
                    let raf, fl = sc_get_range_for_affine_ar(sc_op(ar, 0), sc_get_step_recurrence(ar), mbc);
                    cons = rg_intersect_t(cons, raf, rt);
                    sc_or_flags(ar, fl);
                    let rf = sc_get_range_via_factoring(sc_op(ar, 0), sc_get_step_recurrence(ar), mbc);
                    cons = rg_intersect_t(cons, rf, rt);
                }
            }
            if sc_use_expensive_range_sharpening {
                let smax = sc_get_backedge_taken_count(sc_loop(ar), BTC_SYMBOLIC_MAX);
                if !sc_is_cnc(smax) && sc_bits(maxbes) <= bw && sc_has_nw(ar) {
                    let rn = sc_get_range_for_affine_no_self_wrapping_ar(ar, smax, bw, hint);
                    cons = rg_intersect_t(cons, rn, rt);
                }
            }
        }
        return sc_set_range(ar, hint, cons);
    }
    if sc_is_minmax_kind(k) || k == SC_SEQUMIN {
        var id: i32 = IID_umin;
        if k == SC_UMAX { id = IID_umax; } else if k == SC_SMAX { id = IID_smax; } else if k == SC_SMIN { id = IID_smin; }
        var x = sc_get_range_ref(sc_op(s, 0), hint, depth + 1);
        for i in 1..sc_nops(s) {
            let y = sc_get_range_ref(sc_op(s, i), hint, depth + 1);
            let pair: CRange[2] = [x, y];
            x = rg_intrinsic(id, pair[..]);
        }
        return sc_set_range(s, hint, rg_intersect_t(cons, x, rt));
    }
    // SCEVUnknown
    let v = sc_value(s);
    let mdok, mdr = sc_range_from_metadata(v);
    if mdok { cons = rg_intersect_t(cons, mdr, rt); }
    let cr = sc_get_range_for_unknown_recurrence(s);
    cons = rg_intersect(cons, cr);
    var known = sc_compute_known_bits_ap(v);
    if (known.z.w as i64) != bw { known = KB { z: ap_zext_or_trunc(known.z, bw), o: ap_zext_or_trunc(known.o, bw) }; }
    var ns = sc_num_sign_bits(v);
    if sc_is_ptr(s) {
        let psize = dl_ptr(sc_ptr_as(sc_ty(s))).bits;
        let diff = psize - bw;
        if diff > 0 && psize > bw && ns > diff { ns -= diff; }
    }
    if ns > 1 {
        if !ap_is_zero(ap_hi_bits(known.z, ns)) { known.z = ap_or(known.z, ap_high_bits(bw, ns)); }
        if !ap_is_zero(ap_hi_bits(known.o, ns)) { known.o = ap_or(known.o, ap_high_bits(bw, ns)); }
    }
    let kmin = known.o;
    let kmax = ap_not(known.z);
    if !ap_eq(kmin, ap_inc(kmax)) { cons = rg_intersect_t(cons, rg_new(kmin, ap_inc(kmax)), rt); }
    if ns > 1 { cons = rg_intersect_t(cons, rg_new(ap_ashr(ap_smin_val(bw), ns - 1), ap_inc(ap_ashr(ap_smax_val(bw), ns - 1))), rt); }
    if sc_is_ptr(s) && hint == HINT_UNSIGNED {
        let db = sc_pointer_dereferenceable_bytes(v) as! u64;
        if db > 1 && (bw >= 64 || db < ((1 as u64) << bw)) {
            var maxv = ap_sub(ap_ones(bw), ap_u64(db, bw));
            let al = pointer_alignment(v);
            let rem = ap_urem(maxv, ap_u64(al as u64, bw));
            maxv = ap_sub(maxv, rem);
            var minv = ap_zero(bw);
            // isKnownNonZero(V, DL): a SimplifyQuery with only the DataLayout (no context, DT, AC, TLI)
            let scx = kb_cxt; let sdt = sq_no_dt; let sac = sq_no_ac; let stli = sq_no_tli;
            kb_cxt = -1; sq_no_dt = true; sq_no_ac = true; sq_no_tli = true;
            let nz = is_known_non_zero(v, 0);
            kb_cxt = scx; sq_no_dt = sdt; sq_no_ac = sac; sq_no_tli = stli;
            if nz { minv = ap_u64(al as u64, bw); }
            cons = rg_intersect_t(cons, rg_nonempty(minv, ap_inc(maxv)), rt);
        }
    }
    if sc_is_phi_value(v) {
        let ar = sc_get_scev(v);
        if sc_is_addrec(ar) { return sc_get_range_ref(ar, hint, depth + 1); }
        if sc_range_ref_phi_allowed_operands(v) {
            var rfo = rg_empty(bw);
            for i in nops(v) {
                let orr = sc_get_range_ref(sc_get_scev(op(v, i)), hint, depth + 1);
                rfo = rg_union(rfo, orr);
                if rg_is_full(rfo) { break; }
            }
            cons = rg_intersect_t(cons, rfo, rt);
        }
    }
    if is_inst(v) && inst_iid(v) == IID_vscale { cons = rg_difference(cons, rg_single(ap_zero(bw))); }
    return sc_set_range(s, hint, cons);
}

// getVScaleRange (ValueTracking.cpp)
recursive fn sc_vscale_range(bw: i64) -> CRange {
    let fa = alist_fn(globs[glob_of(sc_fv)].attrs);
    let k = aset_find(fa, AK_VScaleRange);
    if k < 0 { return rg_new(ap_u64(1, bw), ap_zero(bw)); }
    let packed = attrs[k].i1;
    let amin = (packed >> 32) as i64;
    let amax = (packed & 0xFFFFFFFF) as i64;
    let bwmin = if amin == 0 { 0 } else { 64 - clz64(amin as u64) };
    if bwmin > bw { return rg_empty(bw); }
    let mn = ap_u64(amin as u64, bw);
    let bwmax = if amax == 0 { 0 } else { 64 - clz64(amax as u64) };
    if amax == 0 || bwmax > bw { return rg_new(mn, ap_zero(bw)); }
    return rg_new(mn, ap_inc(ap_u64(amax as u64, bw)));
}

// GetRangeFromMetadata
recursive fn sc_range_from_metadata(v: i32) -> bool, CRange {
    if is_inst(v) {
        let md = inst_get_md(v, md_kind_id("range"));
        if md >= 0 { return true, rg_from_range_md(md); }
        if is_callbase(v) {
            // CallBase::getRange: the call-site range intersected with the callee's
            let ok, r = rg_from_range_attr(alist_ret(insts[inst_of(v)].attrs));
            let cf = called_function(v);
            var ok2 = false;
            var r2 = r;
            if cf >= 0 { let a, b = rg_from_range_attr(alist_ret(globs[glob_of(cf)].attrs)); ok2 = a; r2 = b; }
            if ok && ok2 { return true, rg_intersect(r, r2); }
            if ok { return true, r; }
            if ok2 { return true, r2; }
        }
    }
    if vals[v].kind as i64 == VK_ARG {
        let ok, r = rg_from_range_attr(arg_attrs(v));
        if ok { return true, r; }
    }
    return false, rg_full(1);
}

// Value::getPointerDereferenceableBytes (CanBeNull is not needed by the callers here)
recursive fn sc_pointer_dereferenceable_bytes(v: i32) -> i64 {
    let k = vals[v].kind as i64;
    if k == VK_ARG {
        let s = arg_attrs(v);
        var d = sc_aset_int(s, AK_Dereferenceable);
        if d == 0 {
            // getPointeeInMemoryValueType: byval, byref, preallocated, inalloca, sret types
            let kinds: i64[5] = [AK_ByVal, AK_ByRef, AK_Preallocated, AK_InAlloca, AK_StructRet];
            for kk in kinds {
                let a = aset_find(s, kk);
                if a >= 0 {
                    let mt = attrs[a].ty;
                    if mt >= 0 && cf_ty_is_sized(mt) {
                        if sc_type_has_scalable(mt) { fatal("ScalarEvolution: dereferenceable bytes of scalable pointee types are not ported"); }
                        d = dl_store_size(mt);
                    }
                    break;
                }
            }
        }
        if d == 0 { d = sc_aset_int(s, AK_DereferenceableOrNull); }
        return d;
    }
    if k == VK_INST {
        let o = iop(v);
        if is_callbase(v) {
            // CallBase::getRetDereferenceableBytes / getRetDereferenceableOrNullBytes: max of call site and callee
            fn ret_bytes(k: i64) -> i64 {
                var b = sc_aset_int(alist_ret(insts[inst_of(v)].attrs), k);
                let cf = called_function(v);
                if cf >= 0 { let fb = sc_aset_int(alist_ret(globs[glob_of(cf)].attrs), k); if fb > b { b = fb; } }
                return b;
            }
            var d = ret_bytes(AK_Dereferenceable);
            if d == 0 { d = ret_bytes(AK_DereferenceableOrNull); }
            return d;
        }
        if o == OP_LOAD || o == OP_INTTOPTR {
            var d: i64 = 0;
            let m1 = inst_get_md(v, md_kind_id("dereferenceable"));
            if m1 >= 0 { d = ap_limited(ci_ap(mds[md_op(m1, 0)].extra), 0xFFFFFFFFFFFFFFFF) as! i64; }
            if d == 0 {
                let m2 = inst_get_md(v, md_kind_id("dereferenceable_or_null"));
                if m2 >= 0 { d = ap_limited(ci_ap(mds[md_op(m2, 0)].extra), 0xFFFFFFFFFFFFFFFF) as! i64; }
            }
            return d;
        }
        if o == OP_ALLOCA {
            let n = op(v, 0);
            if vals[n].kind as i64 != VK_CINT { return 0; }
            let ty = insts[inst_of(v)].ty2;
            if sc_type_has_scalable(ty) { fatal("ScalarEvolution: scalable allocas are not ported"); }
            // checkedMulUnsigned(size, count): no size on overflow
            let sz = dl_alloc_size(ty) as u64;
            let cnt = ap_lo64(ap_from_cint(n));
            if !ap_fits_u64(ap_from_cint(n)) { return 0; }
            if sz != 0 && cnt > 0xFFFFFFFFFFFFFFFF / sz { return 0; }
            return (sz * cnt) as! i64;
        }
        return 0;
    }
    if k == VK_GVAR {
        let g = glob_of(v);
        if globs[g].linkage as i64 == LK_EXTERN_WEAK { return 0; }
        return dl_store_size(globs[g].vty);
    }
    return 0;
}

// getRangeForUnknownRecurrence
recursive fn sc_get_range_for_unknown_recurrence(u: i32) -> CRange {
    let bw = sc_bits(u);
    let full = rg_full(bw);
    let p = sc_value(u);
    if !sc_is_phi_value(p) { return full; }
    var unreach = false;
    each_pred(inst_parent(p)) { pr => if !dt_has_node(DT_DOM, pr) { unreach = true; } };
    if unreach { return full; }
    if !match_simple_recurrence(p) { return full; }
    let bo = rec_bo;
    let start = rec_start;
    let step = rec_step;
    let l = li_loop_for(inst_parent(p));
    if !loop_contains(l, inst_parent(bo)) { return full; }
    let o = iop(bo);
    if o != OP_ASHR && o != OP_LSHR && o != OP_SHL { return full; }
    if op(bo, 0) != p { return full; }
    let tc = sc_get_small_constant_max_trip_count(l);
    if tc == 0 || tc >= bw { return full; }
    let ks = sc_compute_known_bits_ap(start);
    let kst = sc_compute_known_bits_ap(step);
    let msa = ap_not(kst.z);
    let tcap = ap_u64((tc - 1) as u64, bw);
    let ts, ov = ap_umul_ov(msa, tcap);
    if ov { return full; }
    let tsk = kb_const_ap(ts);
    if o == OP_ASHR {
        let ke = kb_shr(ks, tsk, false, false, true);
        if kb_is_nonneg(ks) { return rg_nonempty(kb_min(ke), ap_inc(kb_max(ks))); }
        if kb_is_neg(ks) { return rg_nonempty(kb_min(ks), ap_inc(kb_max(ke))); }
        return full;
    }
    if o == OP_LSHR {
        let ke = kb_shr(ks, tsk, false, false, false);
        return rg_nonempty(kb_min(ke), ap_inc(kb_max(ks)));
    }
    let ke = kb_shl(ks, tsk, false, false, false);
    if ap_ult_u64(ts, kb_min_lz(ks) as u64) && ap_fits_u64(ts) { return rg_new(kb_min(ks), ap_inc(kb_max(ke))); }
    return full;
}

// getRangeForAffineARHelper: (range, no-wrap)
recursive fn sc_range_for_affine_ar_helper(step0: AP, sr: CRange, mbc: AP, signed: bool) -> CRange, bool {
    var step = step0;
    let bw = step.w as i64;
    if ap_is_zero(step) || ap_is_zero(mbc) { return sr, true; }
    if rg_is_full(sr) { return rg_full(bw), false; }
    let desc = signed && ap_is_neg(step);
    if signed { step = ap_abs(step); }
    if ap_ult(ap_udiv(ap_ones(bw), step), mbc) { return rg_full(bw), false; }
    let off = ap_mul(step, mbc);
    let sl = sr.lo;
    let su = ap_dec(sr.hi);
    var ov = false;
    var mb = sl;
    if signed {
        if desc { mb = ap_sub(sl, off); ov = ap_sgt(mb, sl) || rg_is_sign_wrapped(sr); }
        else { mb = ap_add(su, off); ov = ap_slt(mb, su) || rg_is_sign_wrapped(sr); }
    } else {
        let x, o = ap_uadd_ov(su, off);
        mb = x;
        ov = o || rg_is_wrapped(sr);
    }
    if rg_contains_ap(sr, mb) { return rg_full(bw), false; }
    let nl = if desc { mb } else { sl };
    let nu = ap_inc(if desc { su } else { mb });
    return rg_nonempty(nl, nu), !ov;
}

// getRangeForAffineAR: (range, flags)
recursive fn sc_get_range_for_affine_ar(start: i32, step: i32, mbc: AP) -> CRange, u32 {
    let ssr = sc_get_signed_range(start);
    let stsr = sc_get_signed_range(step);
    let sr1, nsw1 = sc_range_for_affine_ar_helper(rg_smin(stsr), ssr, mbc, true);
    let sr2, nsw2 = sc_range_for_affine_ar_helper(rg_smax(stsr), ssr, mbc, true);
    let sr = rg_union(sr1, sr2);
    let ur, nuw = sc_range_for_affine_ar_helper(sc_get_unsigned_range_max(step), sc_get_unsigned_range(start), mbc, false);
    var f = SF_ANY;
    if nuw { f |= SF_NUW; }
    if nsw1 && nsw2 { f |= SF_NSW; }
    return rg_intersect_t(sr, ur, RG_SMALLEST), f;
}

// getRangeForAffineNoSelfWrappingAR
recursive fn sc_get_range_for_affine_no_self_wrapping_ar(ar: i32, mbc0: i32, bw: i64, hint: i64) -> CRange {
    let signed = hint == HINT_SIGNED;
    let step = sc_get_step_recurrence(ar);
    if !sc_is_const(step) { return rg_full(bw); }
    if sc_bits(mbc0) > sc_bits(ar) { return rg_full(bw); }
    let mbc = sc_get_noop_or_zero_extend(mbc0, sc_ty(ar));
    let rw = sc_get_minus_one(sc_ty(ar));
    let sa = sc_umin(step, sc_get_negative(step, SF_ANY));
    let miw = sc_get_udiv(rw, sa);
    if !sc_is_known_predicate_via_constant_ranges(P_ULE, mbc, miw) { return rg_full(bw); }
    let le = if signed { P_SLE } else { P_ULE };
    let ge = if signed { P_SGE } else { P_UGE };
    let end = sc_evaluate_at_iteration(ar, mbc);
    let start = sc_apply_loop_guards(sc_op(ar, 0), sc_loop(ar));
    let srr = sc_get_range_ref(start, hint, 0);
    let er = sc_get_range_ref(end, hint, 0);
    let rb = rg_union(srr, er);
    if rg_is_full(rb) { return rb; }
    let wr = if signed { rg_is_sign_wrapped(rb) } else { rg_is_wrapped(rb) };
    if wr { return rg_full(bw); }
    if sc_is_known_positive(step) && sc_is_known_predicate_via_constant_ranges(le, start, end) { return rb; }
    if sc_is_known_negative(step) && sc_is_known_predicate_via_constant_ranges(ge, start, end) { return rb; }
    return rg_full(bw);
}

// getRangeViaFactoring's SelectPattern: (recognized, condition, true value, false value)
recursive fn sc_select_pattern(bw: i64, s0: i32) -> bool, i32, AP, AP {
    var s = s0;
    var off = ap_zero(bw);
    var cast_kind: i64 = -1;
    if sc_kind(s) == SC_ADD && sc_nops(s) == 2 && sc_is_const(sc_op(s, 0)) { off = sc_ap(sc_op(s, 0)); s = sc_op(s, 1); }
    if sc_is_int_cast_kind(sc_kind(s)) { cast_kind = sc_kind(s); s = sc_op(s, 0); }
    if !sc_is_unknown(s) { return false, -1, off, off; }
    let v = sc_value(s);
    if !(is_inst(v) && iop(v) == OP_SELECT) { return false, -1, off, off; }
    let tv = op(v, 1);
    let fv = op(v, 2);
    if !(vals[tv].kind as i64 == VK_CINT) || !(vals[fv].kind as i64 == VK_CINT) { return false, -1, off, off; }
    var t = ap_from_cint(tv);
    var f = ap_from_cint(fv);
    if cast_kind == SC_TRUNC { t = ap_trunc(t, bw); f = ap_trunc(f, bw); }
    else if cast_kind == SC_ZEXT { t = ap_zext(t, bw); f = ap_zext(f, bw); }
    else if cast_kind == SC_SEXT { t = ap_sext(t, bw); f = ap_sext(f, bw); }
    return true, op(v, 0), ap_add(t, off), ap_add(f, off);
}

recursive fn sc_get_range_via_factoring(start: i32, step: i32, mbc: AP) -> CRange {
    let bw = mbc.w as i64;
    let ok1, c1, t1, f1 = sc_select_pattern(bw, start);
    if !ok1 { return rg_full(bw); }
    let ok2, c2, t2, f2 = sc_select_pattern(bw, step);
    if !ok2 { return rg_full(bw); }
    if c1 != c2 { return rg_full(bw); }
    let ts = sc_get_constant(t1);
    let tst = sc_get_constant(t2);
    let fs = sc_get_constant(f1);
    let fst = sc_get_constant(f2);
    let tr, tf = sc_get_range_for_affine_ar(ts, tst, mbc);
    let fr, ff = sc_get_range_for_affine_ar(fs, fst, mbc);
    return rg_union(tr, fr);
}

// isKnownToBeAPowerOfTwo
recursive fn sc_is_known_to_be_power_of_two(s: i32, or_zero: bool, or_neg: bool) -> bool {
    fn nonrec(x: i32) -> bool {
        if sc_is_const(x) {
            let c = sc_ap(x);
            return ap_is_pow2(c) || (or_neg && ap_is_pow2(ap_neg(c)));
        }
        return sc_kind(x) == SC_VSCALE;
    }
    if nonrec(s) { return true; }
    if sc_kind(s) != SC_MUL { return false; }
    for i in sc_nops(s) { if !nonrec(sc_op(s, i)) { return false; } }
    return or_zero || sc_is_known_non_zero(s);
}

recursive fn sc_aset_int(s: i32, k: i64) -> i64 { let a = aset_find(s, k); if a < 0 { return 0; } return attrs[a].i1 as i64; }

fn clz64(x: u64) -> i64 { var n: i64 = 0; var y = x; if y == 0 { return 64; } while (y & 0x8000000000000000) == 0 { y = y << 1; n++; } return n; }
