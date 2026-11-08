// InstCombine x86 target intrinsics: port of llvm/lib/Target/X86/X86InstCombineIntrinsic.cpp
// (simplifyDemandedUseBitsIntrinsic, simplifyDemandedVectorEltsIntrinsic; instCombineIntrinsic is ic_x86_intr.goose).
namespace ic;
import std;
import ir;
import irutil;
import calls;
import instinfo;
import gen_iids;
import intrinsics;
import pm;
import apint;
import ic;
import ic_builder;
import ic_common;
import ic_demanded_elts;
import ic_calls;
import tti;
import ic_x86_intr;

// X86TTIImpl::instCombineIntrinsic(IC, II): (result, handled)
fn x86_inst_combine_intrinsic(ii: i32) -> i32, bool { let r, h = x86_inst_combine_intrinsic_impl(ii); return r, h; }

// The function's module has an x86 triple (TTIForTargetIntrinsicsOnly is X86TTIImpl); a non-x86 target triple
// fails loudly, no triple is the NoTTIImpl (no target folds).
fn x86_tti_active(ii: i32) -> bool {
    let fv = inst_func(ii);
    let m = globs[glob_of(fv)].module;
    let t = modules[m].triple;
    let ts = if t < 0 { "" } else { sbytes(t) };
    if ts.len == 0 { return false; }
    if starts_with(ts, "x86_64") || starts_with(ts, "i386") || starts_with(ts, "i686") || starts_with(ts, "i586") ||
       starts_with(ts, "i486") || starts_with(ts, "x86") {
        return true;
    }
    ic_not_ported(str("target intrinsic folds for triple '", ts, "'"));
    return false;
}
fn x86_id_in(id: i32, names: const u8[:][:]) -> bool {
    let nm = intr_name(id as i64);
    for n in names { if nm == n { return true; } }
    return false;
}

// X86TTIImpl::simplifyDemandedUseBitsIntrinsic(IC, II, DemandedMask, Known, KnownBitsComputed):
// (handled, value, known, known_computed)
fn x86_sdub_intrinsic(ii: i32, demanded: AP, known: KB) -> bool, i32, KB, bool {
    if !x86_tti_active(ii) { return false, -1, known, false; }
    let id = call_iid(ii);
    if x86_id_in(id, ["llvm.x86.mmx.pmovmskb", "llvm.x86.sse.movmsk.ps", "llvm.x86.sse2.movmsk.pd", "llvm.x86.sse2.pmovmskb.128",
                      "llvm.x86.avx.movmsk.ps.256", "llvm.x86.avx.movmsk.pd.256", "llvm.x86.avx2.pmovmskb"]) {
        var aw: i64 = 8;
        if intr_name(id as i64) != "llvm.x86.mmx.pmovmskb" { aw = ty_count(vals[cb_arg(ii, 0)].ty); }
        let de = ap_zext_or_trunc(demanded, aw);
        if ap_is_zero(de) { return true, c_null(vals[ii].ty), known, false; }
        let w = kb_bw(known);
        let k2 = KB { z: ap_or(known.z, ap_bits_from(w, aw)), o: known.o };
        return false, -1, k2, true;
    }
    return false, -1, known, false;
}

// X86TTIImpl::simplifyDemandedVectorEltsIntrinsic(IC, II, DemandedElts, UndefElts, UndefElts2, UndefElts3,
// simplifyAndSetOp): (handled, value, UndefElts)
recursive fn x86_sdve_intrinsic(ii: i32, demanded0: AP, undef0: AP, depth: i64) -> bool, i32, AP {
    var undef = undef0;
    if !x86_tti_active(ii) { return false, -1, undef; }
    let vw = ty_count(vals[ii].ty);
    let id = call_iid(ii);
    let nm = intr_name(id as i64);
    var demanded = demanded0;
    let one = ap_u64(1, vw);
    if nm == "llvm.x86.xop.vfrcz.ss" || nm == "llvm.x86.xop.vfrcz.sd" {
        if !ap_get_bit(demanded, 0) {
            icw_add(ii);
            return true, c_null(vals[ii].ty), undef;
        }
        demanded = one;
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        undef = if ap_get_bit(undef, 0) { one } else { ap_zero(vw) };
        return false, -1, undef;
    }
    if nm == "llvm.x86.sse.rcp.ss" || nm == "llvm.x86.sse.rsqrt.ss" {
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        if !ap_get_bit(demanded, 0) { icw_add(ii); return true, cb_arg(ii, 0), undef; }
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse.min.ss", "llvm.x86.sse.max.ss", "llvm.x86.sse.cmp.ss", "llvm.x86.sse2.min.sd",
                      "llvm.x86.sse2.max.sd", "llvm.x86.sse2.cmp.sd"]) {
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        if !ap_get_bit(demanded, 0) { icw_add(ii); return true, cb_arg(ii, 0), undef; }
        demanded = one;
        let u2 = sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        if !ap_get_bit(u2, 0) { undef = ap_clear_bit(undef, 0); }
        return false, -1, undef;
    }
    if nm == "llvm.x86.sse41.round.ss" || nm == "llvm.x86.sse41.round.sd" {
        let d2 = ap_clear_bit(demanded, 0);
        undef = sde_set_op(ii, 0, d2, undef, depth);
        if !ap_get_bit(demanded, 0) { icw_add(ii); return true, cb_arg(ii, 0), undef; }
        demanded = one;
        let u2 = sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        undef = ap_clear_bit(undef, 0);
        if ap_get_bit(u2, 0) { undef = ap_or(undef, one); }
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.avx512.mask.add.ss.round", "llvm.x86.avx512.mask.div.ss.round", "llvm.x86.avx512.mask.mul.ss.round",
                      "llvm.x86.avx512.mask.sub.ss.round", "llvm.x86.avx512.mask.max.ss.round", "llvm.x86.avx512.mask.min.ss.round",
                      "llvm.x86.avx512.mask.add.sd.round", "llvm.x86.avx512.mask.div.sd.round", "llvm.x86.avx512.mask.mul.sd.round",
                      "llvm.x86.avx512.mask.sub.sd.round", "llvm.x86.avx512.mask.max.sd.round", "llvm.x86.avx512.mask.min.sd.round"]) {
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        if !ap_get_bit(demanded, 0) { icw_add(ii); return true, cb_arg(ii, 0), undef; }
        demanded = one;
        let u2 = sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        let u3 = sde_set_op(ii, 2, demanded, ap_zero(vw), depth);
        if !ap_get_bit(u2, 0) || !ap_get_bit(u3, 0) { undef = ap_clear_bit(undef, 0); }
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse3.addsub.pd", "llvm.x86.sse3.addsub.ps", "llvm.x86.avx.addsub.pd.256", "llvm.x86.avx.addsub.ps.256"]) {
        let sub = ap_splat(vw, ap_u64(1, 2));
        let add = ap_splat(vw, ap_u64(2, 2));
        let so = ap_is_subset_of(demanded, sub);
        let ao = ap_is_subset_of(demanded, add);
        if so || ao {
            let sp = icb_pos; let sb = icb_bb; let sd = icb_dl;
            icb_set_insert_point(ii);
            let r = icx_fbinop(if so { OP_FSUB } else { OP_FADD }, cb_arg(ii, 0), cb_arg(ii, 1), icb_fmf, "");
            icb_pos = sp; icb_bb = sb; icb_dl = sd;
            return true, r, undef;
        }
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        let u2 = sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        undef = ap_and(undef, u2);
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.avx2.psllv.d", "llvm.x86.avx2.psllv.d.256", "llvm.x86.avx2.psllv.q", "llvm.x86.avx2.psllv.q.256",
                      "llvm.x86.avx2.psrlv.d", "llvm.x86.avx2.psrlv.d.256", "llvm.x86.avx2.psrlv.q", "llvm.x86.avx2.psrlv.q.256",
                      "llvm.x86.avx2.psrav.d", "llvm.x86.avx2.psrav.d.256"]) {
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        let u2 = sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        undef = ap_and(undef, u2);
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse2.pmulh.w", "llvm.x86.avx2.pmulh.w", "llvm.x86.avx512.pmulh.w.512", "llvm.x86.sse2.pmulhu.w",
                      "llvm.x86.avx2.pmulhu.w", "llvm.x86.avx512.pmulhu.w.512", "llvm.x86.ssse3.pmul.hr.sw.128",
                      "llvm.x86.avx2.pmul.hr.sw", "llvm.x86.avx512.pmul.hr.sw.512"]) {
        undef = sde_set_op(ii, 0, demanded, undef, depth);
        sde_set_op(ii, 1, demanded, ap_zero(vw), depth);
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse2.packssdw.128", "llvm.x86.sse2.packsswb.128", "llvm.x86.sse2.packuswb.128",
                      "llvm.x86.sse41.packusdw", "llvm.x86.avx2.packssdw", "llvm.x86.avx2.packsswb", "llvm.x86.avx2.packusdw",
                      "llvm.x86.avx2.packuswb", "llvm.x86.avx512.packssdw.512", "llvm.x86.avx512.packsswb.512",
                      "llvm.x86.avx512.packusdw.512", "llvm.x86.avx512.packuswb.512"]) {
        let t0 = vals[cb_arg(ii, 0)].ty;
        let ivw = ty_count(t0);
        let nl = ty_count(t0) * ty_scalar_bits(t0) / 128;
        let vwpl = vw / nl;
        let ivwpl = ivw / nl;
        for opn in 2 {
            var od = ap_zero(ivw);
            for lane in nl {
                let li = lane * vwpl;
                for e in ivwpl {
                    let idx = li + e + ivwpl * opn;
                    if ap_get_bit(demanded, idx) { od = ap_set_bit(od, lane * ivwpl + e); }
                }
            }
            var ou = sde_set_op(ii, opn, od, ap_zero(ivw), depth);
            ou = ap_zext(ou, vw);
            for lane in nl {
                var le = ap_lshr(ou, ivwpl * lane);
                le = ap_lo_bits(le, ivwpl);
                le = ap_shl(le, ivwpl * (2 * lane + opn));
                undef = ap_or(undef, le);
            }
        }
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse2.pmadd.wd", "llvm.x86.avx2.pmadd.wd", "llvm.x86.avx512.pmaddw.d.512",
                      "llvm.x86.ssse3.pmadd.ub.sw.128", "llvm.x86.avx2.pmadd.ub.sw", "llvm.x86.avx512.pmaddubs.w.512"]) {
        let ivw = ty_count(vals[cb_arg(ii, 0)].ty);
        let od = ap_scale_bit_mask(demanded, ivw);
        sde_set_op(ii, 0, od, ap_zero(ivw), depth);
        sde_set_op(ii, 1, od, ap_zero(ivw), depth);
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.ssse3.pshuf.b.128", "llvm.x86.avx2.pshuf.b", "llvm.x86.avx512.pshuf.b.512",
                      "llvm.x86.avx.vpermilvar.ps", "llvm.x86.avx.vpermilvar.ps.256", "llvm.x86.avx512.vpermilvar.ps.512",
                      "llvm.x86.avx.vpermilvar.pd", "llvm.x86.avx.vpermilvar.pd.256", "llvm.x86.avx512.vpermilvar.pd.512",
                      "llvm.x86.avx2.permd", "llvm.x86.avx2.permps"]) {
        undef = sde_set_op(ii, 1, demanded, undef, depth);
        return false, -1, undef;
    }
    if x86_id_in(id, ["llvm.x86.sse4a.extrq", "llvm.x86.sse4a.extrqi", "llvm.x86.sse4a.insertq", "llvm.x86.sse4a.insertqi"]) {
        undef = ap_or(undef, ap_high_bits(vw, vw / 2));
        return false, -1, undef;
    }
    return false, -1, undef;
}

// APIntOps::ScaleBitMask(A, NewBitWidth, MatchAllBits = false)
fn ap_scale_bit_mask(a: AP, nw: i64) -> AP {
    let ow = a.w as i64;
    if ow == nw { return a; }
    var r = ap_zero(nw);
    if nw > ow {
        let s = nw / ow;
        for i in ow { if ap_get_bit(a, i) { for j in s { r = ap_set_bit(r, i * s + j); } } }
    } else {
        let s = ow / nw;
        for i in nw {
            var any = false;
            for j in s { if ap_get_bit(a, i * s + j) { any = true; } }
            if any { r = ap_set_bit(r, i); }
        }
    }
    return r;
}
