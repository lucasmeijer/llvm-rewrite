// Constant folding with DataLayout: port of llvm/lib/Analysis/ConstantFolding.cpp (ConstantFoldInstOperands,
// ConstantFoldConstant, ConstantFoldCompareInstOperands, ConstantFoldBinaryOpOperands,
// ConstantFoldFPInstOperands, ConstantFoldCastOperand, ConstantFoldIntegerCast, SymbolicallyEvaluateBinop,
// SymbolicallyEvaluateGEP, CastGEPIndices, IsConstantOffsetFromGlobal, canConstantFoldCallTo,
// ConstantFoldCall (integer intrinsics), ConstantFoldLoadFromConstPtr (uniform values)).
// Builds on constfold.goose (lib/IR/ConstantFold.cpp). Functions return a constant id or -1.
// Unported folds (FP libcalls and FP intrinsics, loads that reinterpret bytes, bitcasts that change the
// vector element count) fail loudly.
import std;
import ir;
import memloc;
import irutil;
import calls;
import instinfo;
import gen_attrs;
import gen_iids;
import intrinsics;
import datalayout;
import apfloat;
import fpu;
import constfold;
import apint;
import hostmath;
import binary;
import bignum;
import knownbits;
import pm;
import vt;
import poison;
import tli;
import instsimplify;

fn cfa_not_ported(what: const u8[:]) { fatal(str("ConstantFolding: ", what, " is not ported yet")); }

fn is_cexpr(v: i32) -> bool { vals[v].kind == VK_CEXPR }

// IsConstantOffsetFromGlobal: global id (or -1) and the offset (vt_off)
recursive fn constant_offset_from_global(c: i32) -> i32 {
    if is_global(c) { vt_off = 0; return c; }
    if vals[c].kind == VK_DSOLOCAL { cfa_not_ported("dso_local_equivalent offsets"); }
    if !is_cexpr(c) { return -1; }
    let o = cexpr_op(c);
    if o == OP_PTRTOINT || o == OP_PTRTOADDR { return constant_offset_from_global(op(c, 0)); }
    if o != OP_GEP { return -1; }
    let g = constant_offset_from_global(op(c, 0));
    if g < 0 { return -1; }
    let base_off = vt_off;
    let ok, off = gep_accumulate_constant_offset(c);
    if !ok { return -1; }
    let iw = dl_ptr(ptr_as(vals[c].ty)).idx;
    vt_off = sext64(((base_off + off) as! u64) & wmask64(iw), iw);
    return g;
}

// SymbolicallyEvaluateBinop
recursive fn symbolic_binop(o: i64, a: i32, b: i32) -> i32 {
    if o == OP_AND {
        let save = kb_cxt;
        kb_cxt = -1;
        let k0 = kb_compute_all(a, 0);
        let k1 = kb_compute_all(b, 0);
        kb_cxt = save;
        if ap_is_all_ones(ap_or(k1.o, k0.z)) { return a; }
        if ap_is_all_ones(ap_or(k0.o, k1.z)) { return b; }
        let k = kb_and(k0, k1);
        if kb_is_constant(k) { return c_int_ap(vals[a].ty, k.o); }
    }
    if o == OP_SUB {
        let g1 = constant_offset_from_global(a);
        let o1 = vt_off;
        if g1 >= 0 {
            let g2 = constant_offset_from_global(b);
            let o2 = vt_off;
            if g2 >= 0 && g1 == g2 {
                let sz = dl_size_bits(vals[a].ty);
                return c_int_ty(vals[a].ty, ((o1 - o2) as! u64) & wmask64(sz));
            }
        }
    }
    return -1;
}

// ConstantFoldBinaryOpOperands
recursive fn cf_fold_binop_operands(o: i64, a: i32, b: i32) -> i32 {
    if is_cexpr(a) || is_cexpr(b) {
        let c = symbolic_binop(o, a, b);
        if c >= 0 { return c; }
    }
    if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
    return cf_binop(o, a, b);
}

// FlushFPConstant / function denormal modes: only the IEEE default is supported.
fn cf_check_denormal_mode(cxt: i32) {
    if cxt < 0 { return; }
    let f = inst_func(cxt);
    if func_has_fn_attr(f, AK_DenormalFPEnv) { cfa_not_ported("denormal_fpenv denormal flushing"); }
}

// ConstantFoldFPInstOperands
recursive fn cf_fold_fp_inst_operands(o: i64, a0: i32, b0: i32, cxt: i32, allow_nondet: bool) -> i32 {
    // flush denormal inputs (FlushFPConstant with IsOutput = false)
    let a = cf_flush_fp(a0, cxt, false);
    if a < 0 { return -1; }
    let b = cf_flush_fp(b0, cxt, false);
    if b < 0 { return -1; }
    if !allow_nondet && cxt >= 0 && is_fp_math_operator(cxt) {
        let f = insts[inst_of(cxt)].fmf;
        if (f & (FMF_NSZ | FMF_REASSOC | FMF_CONTRACT | FMF_ARCP)) != 0 { return -1; }
    }
    let c0 = cf_fold_binop_operands(o, a, b);
    if c0 < 0 { return -1; }
    let c = cf_flush_fp(c0, cxt, true);
    if c < 0 { return -1; }
    if !allow_nondet && const_is_nan_cf(c) { return -1; }
    return c;
}
recursive fn const_is_nan_cf(c: i32) -> bool {
    if vals[c].kind == VK_CFP && !ty_is_vector(vals[c].ty) { return fp_decompose(fp_kind_ty(vals[c].ty), cint_lo(c), cint_hi(c)).cat == FC_NAN; }
    if ty_is_vector(vals[c].ty) {
        if ty_kind(vals[c].ty) == TK_FVEC {
            for i in ty_count(vals[c].ty) {
                let e = agg_elem(c, i);
                if e < 0 || vals[e].kind != VK_CFP || fp_decompose(fp_kind_ty(vals[e].ty), cint_lo(e), cint_hi(e)).cat != FC_NAN { return false; }
            }
            return true;
        }
        let s = splat_value(c, false);
        if s >= 0 && vals[s].kind == VK_CFP { return const_is_nan_cf(s); }
    }
    return false;
}

fn cf_fold_unary(o: i64, c: i32) -> i32 { cf_unary(o, c) }

// ConstantFoldIntegerCast
recursive fn cf_fold_integer_cast(c: i32, ty: i32, signed: bool) -> i32 {
    let st = vals[c].ty;
    if st == ty { return c; }
    if ty_scalar_bits(st) > ty_scalar_bits(ty) { return cf_fold_cast_operand(OP_TRUNC, c, ty); }
    if signed { return cf_fold_cast_operand(OP_SEXT, c, ty); }
    return cf_fold_cast_operand(OP_ZEXT, c, ty);
}

// DL.getIntPtrType(PtrTy)
fn int_ptr_type_of(t: i32) -> i32 {
    let s = ty_scalar(t);
    let it = ty_int(dl_ptr(types[s].n as i64).bits);
    if ty_is_vector(t) { return ty_vector(it, ty_count(t), ty_kind(t) == TK_SVEC); }
    return it;
}

// CastInst::isEliminableCastPair(..., &DL): the DataLayout-dependent cases 7 (ptrtoint, inttoptr) and 11
// (inttoptr, ptrtoint/ptrtoaddr); the rest is eliminable_cast_pair (constfold.goose)
fn eliminable_cast_pair_dl(first: i64, second: i64, src: i32, mid: i32, dst: i32) -> i64 {
    let fb = first == OP_BITCAST;
    let sb = second == OP_BITCAST;
    if (fb && ty_is_vector(src) != ty_is_vector(mid)) || (sb && ty_is_vector(mid) != ty_is_vector(dst)) {
        if !(fb && sb) { return 0; }
    }
    let c = CAST_RESULTS[(first - OP_TRUNC) * 14 + (second - OP_TRUNC)] as i64;
    if c == 7 {
        if src != dst { return 0; }
        if cf_scalar_size(mid) < dl_ptr(types[ty_scalar(src)].n as i64).bits { return 0; }
        return OP_BITCAST;
    }
    if c == 11 {
        let ps = dl_ptr(types[ty_scalar(mid)].n as i64);
        let ms = if second == OP_PTRTOADDR { ps.idx } else { ps.bits };
        let ss = cf_scalar_size(src);
        let ds = cf_scalar_size(dst);
        if ms < ss && ms < ds { return 0; }
        if ds < ss { return OP_TRUNC; }
        if ds > ss { return OP_ZEXT; }
        return OP_BITCAST;
    }
    return eliminable_cast_pair(first, second, src, mid, dst);
}

// ConstantFoldCastOperand
recursive fn cf_fold_cast_operand(o: i64, c: i32, ty: i32) -> i32 {
    if is_cexpr(c) && is_cast_op(cexpr_op(c)) {
        let nop = eliminable_cast_pair_dl(cexpr_op(c), o, vals[op(c, 0)].ty, vals[c].ty, ty);
        if nop != 0 { return cf_fold_cast_operand(nop, op(c, 0), ty); }
    }
    if o == OP_PTRTOADDR || o == OP_PTRTOINT {
        if is_cexpr(c) {
            var folded: i32 = -1;
            let co = cexpr_op(c);
            if co == OP_INTTOPTR {
                let mid = if o == OP_PTRTOINT { address_type_of(vals[c].ty) } else { int_ptr_type_of(vals[c].ty) };
                folded = cf_fold_integer_cast(op(c, 0), mid, false);
            } else if co == OP_GEP {
                let iw = dl_ptr(ptr_as(vals[c].ty)).idx;
                let base = strip_and_accumulate_offsets(c, true, false, false);
                let off = vt_off;
                if is_null_value(base) {
                    folded = c_int_words(ty_int(iw), (off as! u64) & wmask64(iw), 0);
                } else {
                    let st = csts[vals[c].sub].ty2;
                    if nops(c) == 2 && ty_is_int(st) && ty_bits(st) == 8 {
                        let ptr = op(c, 0);
                        let sub = op(c, 1);
                        let it = index_type_of(vals[ptr].ty);
                        if is_cexpr(sub) && vals[sub].ty == it && cexpr_op(sub) == OP_SUB && is_null_value(op(sub, 0)) {
                            folded = ce_binop(OP_SUB, ce_cast(o, ptr, it), op(sub, 1), 0);
                        }
                    }
                }
            }
            if folded >= 0 { return cf_fold_integer_cast(folded, ty, false); }
        }
    } else if o == OP_INTTOPTR {
        if is_cexpr(c) && cexpr_op(c) == OP_PTRTOINT {
            let sp = op(c, 0);
            let sps = dl_ptr(ptr_as(vals[sp].ty)).bits;
            let mis = ty_scalar_bits(vals[c].ty);
            if mis >= sps && ptr_as(vals[sp].ty) == ptr_as(ty) { return cf_fold_bitcast_dl(sp, ty); }
        }
    } else if o == OP_BITCAST {
        return cf_fold_bitcast_dl(c, ty);
    }
    if is_desirable_cast_op(o) { return ce_cast(o, c, ty); }
    return cf_cast(o, c, ty);
}

// FoldBitCast(C, DestTy, DL) (Analysis/ConstantFolding.cpp). Byte-typed vectors fail loudly.
recursive fn cf_fold_bitcast_dl(c0: i32, ty: i32) -> i32 {
    var c = c0;
    let u = cf_fold_load_from_uniform(c, ty);
    if u >= 0 { return u; }
    let st = vals[c].ty;
    if ty_is_vector(st) && (ty_is_int(ty) || ty_is_fp(ty)) {
        // vector -> scalar integer/fp (foldConstVectorToAPInt)
        if ty_kind(st) == TK_SVEC { cfa_not_ported("bitcast of a scalable vector constant to a scalar"); }
        let nse = ty_count(st);
        let set0 = ty_elem(st);
        if ty_kind(set0) == TK_BYTE { cfa_not_ported("bitcast of a byte vector constant"); }
        var cv = c;
        if ty_is_fp(set0) { cv = ce_cast(OP_BITCAST, c, ty_vector(ty_int(dl_size_bits(set0)), nse, false)); }
        let rw = dl_size_bits(ty);
        var res = ap_zero(rw);
        let bshift = dl_size_bits(set0);
        for i in nse {
            let e = agg_elem(cv, if dl_big_endian { i } else { nse - i - 1 });
            if e >= 0 && is_undef_val(e) { res = ap_shl(res, bshift); continue; }
            if e < 0 || vals[e].kind != VK_CINT { return ce_cast(OP_BITCAST, cv, ty); }
            res = ap_shl(res, bshift);
            res = ap_or(res, ap_zext(ap_from_cint(e), rw));
        }
        if ty_is_int(ty) { return ap_to_cint(ty, res); }
        return c_fp(ty, ap_word(res, 0), if rw > 64 { ap_word(res, 1) } else { 0 });
    }
    if !ty_is_vector(ty) { return ce_cast(OP_BITCAST, c, ty); }
    let k = vals[c].kind;
    if !ty_is_vector(st) && (k == VK_CFP || k == VK_CINT) {
        let v1 = c_aggregate(ty_vector(st, 1, false), [c]);
        return cf_fold_bitcast_dl(v1, ty);
    }
    if ty_kind(st) != TK_FVEC { return ce_cast(OP_BITCAST, c, ty); }
    if k != VK_CDVECTOR && k != VK_CVECTOR && k != VK_CINT && k != VK_CFP { return ce_cast(OP_BITCAST, c, ty); }
    if ty_count(ty) == ty_count(st) { return ce_cast(OP_BITCAST, c, ty); }
    let ndst = ty_count(ty);
    let nsrc = ty_count(st);
    let set = ty_elem(st);
    let det = ty_elem(ty);
    if ty_kind(set) == TK_BYTE || ty_kind(det) == TK_BYTE { cfa_not_ported("bitcast of a byte vector constant"); }
    if ty_is_fp(det) {
        let divt = ty_vector(ty_int(dl_size_bits(det)), ndst, false);
        let ci = cf_fold_bitcast_dl(c, divt);
        return ce_cast(OP_BITCAST, ci, ty);
    }
    var cv = c;
    if ty_is_fp(set) { cv = ce_cast(OP_BITCAST, c, ty_vector(ty_int(dl_size_bits(set)), nsrc, false)); }
    let little = !dl_big_endian;
    let sbits = dl_size_bits(set);
    let dbits = dl_size_bits(det);
    let bw = 2 * (if sbits > dbits { sbits } else { dbits });
    var buf = ap_zero(bw);
    var umask = ap_zero(bw);
    var pmask = ap_zero(bw);
    var bbits: i64 = 0;
    var se: i64 = 0;
    var res: i32[>..<] = [];
    while res.len != ndst {
        while bbits < dbits {
            let e = agg_elem(cv, se);
            se++;
            if e < 0 { return ce_cast(OP_BITCAST, cv, ty); }
            if !little { buf = ap_shl(buf, sbits); umask = ap_shl(umask, sbits); pmask = ap_shl(pmask, sbits); }
            let pos = if little { bbits } else { 0 };
            var sv = ap_zero(sbits);
            if is_undef_val(e) {
                umask = ap_or(umask, ap_shl(ap_low_bits(bw, sbits), pos));
                if vals[e].kind == VK_POISON { pmask = ap_or(pmask, ap_shl(ap_low_bits(bw, sbits), pos)); }
            } else {
                if vals[e].kind != VK_CINT { return ce_cast(OP_BITCAST, cv, ty); }
                sv = ap_from_cint(e);
            }
            // insertBits(SrcValue, pos)
            buf = ap_and(buf, ap_not(ap_shl(ap_low_bits(bw, sbits), pos)));
            buf = ap_or(buf, ap_shl(ap_zext(sv, bw), pos));
            bbits += sbits;
        }
        while bbits >= dbits {
            let sh = if little { 0 } else { bbits - dbits };
            let um = ap_trunc(ap_lshr(umask, sh), dbits);
            if ap_is_all_ones(um) {
                let pm = ap_trunc(ap_lshr(pmask, sh), dbits);
                if !ap_is_zero(pm) { res.push(c_poison(det)); } else { res.push(c_undef(det)); }
            } else {
                res.push(ap_to_cint(det, ap_trunc(ap_lshr(buf, sh), dbits)));
            }
            if little { buf = ap_lshr(buf, dbits); umask = ap_lshr(umask, dbits); pmask = ap_lshr(pmask, dbits); }
            bbits -= dbits;
        }
    }
    return c_aggregate(ty, res);
}

// ConstantFoldLoadFromUniformValue
recursive fn cf_fold_load_from_uniform(c: i32, ty: i32) -> i32 {
    if is_undef_val(c) {
        if vals[c].kind == VK_POISON { return c_poison(ty); }
        return c_undef(ty);
    }
    // padding when storing C to memory: not uniform (DL.typeSizeEqualsStoreSize)
    if dl_size_bits(vals[c].ty) != dl_store_size(vals[c].ty) * 8 { return -1; }
    if is_null_value(c) && !ty_is_x86_amx(ty) { return c_null(ty); }
    if is_all_ones_value(c) {
        if ty_is_int(ty_scalar(ty)) || ty_is_fp(ty_scalar(ty)) || ty_kind(ty_scalar(ty)) == TK_BYTE { return c_all_ones(ty); }
    }
    return -1;
}
fn ty_is_x86_amx(t: i32) -> bool { types[t].kind == TK_X86_AMX }

// ConstantFoldLoadFromConstPtr(C, Ty, Offset): off is the starting offset (0 for the overload without one)
recursive fn cf_fold_load_from_const_ptr(c0: i32, ty: i32, off0: i64, have_off: bool) -> i32 {
    let gv = get_underlying_object(c0, 10);
    if !is_gvar(gv) { return -1; }
    let g = globs[glob_of(gv)];
    if g.is_const == 0 || !gv_has_definitive_initializer(gv) { return -1; }
    let c = strip_and_accumulate_offsets(c0, true, false, false);
    let off = off0 + vt_off;
    if c == gv {
        let r = cf_fold_load_from_const(op(gv, 0), ty, off);
        if r >= 0 { return r; }
    }
    return cf_fold_load_from_uniform(op(gv, 0), ty);
}

// getConstantAtOffset(Base, Offset)
recursive fn cf_constant_at_offset(base: i32, off0: i64) -> i32 {
    if off0 == 0 { return base; }
    let k = vals[base].kind;
    if !(k == VK_CARRAY || k == VK_CSTRUCT || k == VK_CVECTOR || k == VK_CDARRAY || k == VK_CDVECTOR) { return -1; }
    // DL.getGEPIndicesForOffset(ElemTy, Offset)
    var et = vals[base].ty;
    var off = off0;
    let first = cf_element_index(dl_alloc_size(et), off);
    off = cf_ei_off;
    if first != 0 { return -1; }
    var c = base;
    while off != 0 {
        var idx: i64 = 0;
        let tk = ty_kind(et);
        if tk == TK_ARRAY {
            et = ty_elem(et);
            idx = cf_element_index(dl_alloc_size(et), off);
            off = cf_ei_off;
        } else if tk == TK_STRUCT {
            if off < 0 || off >= dl_struct_size(et) { break; }
            idx = cf_struct_element_containing(et, off);
            off -= dl_struct_offset(et, idx);
            et = ty_field(et, idx);
        } else {
            break;
        }
        if idx < 0 || idx >= 2147483648 { return -1; }
        c = agg_elem(c, idx);
        if c < 0 { return -1; }
    }
    if off != 0 { return -1; }
    return c;
}
// getElementIndex(ElemSize, Offset): the index; the remaining offset in cf_ei_off
var cf_ei_off: i64 = 0;
fn cf_element_index(esz: i64, off: i64) -> i64 {
    cf_ei_off = off;
    if esz == 0 { return 0; }
    var idx = off / esz;
    var rem = off - idx * esz;
    if rem < 0 { idx -= 1; rem += esz; }
    cf_ei_off = rem;
    return idx;
}
// StructLayout::getElementContainingOffset
fn cf_struct_element_containing(t: i32, off: i64) -> i64 {
    var idx: i64 = 0;
    for k in ty_count(t) { if dl_struct_offset(t, k) <= off { idx = k; } }
    return idx;
}

// Type::getPrimitiveSizeInBits
recursive fn cf_prim_bits(t: i32) -> i64 {
    let k = ty_kind(t);
    if k == TK_FVEC || k == TK_SVEC { return ty_count(t) * cf_prim_bits(ty_elem(t)); }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    if k == TK_X86_AMX { return 8192; }
    if k == TK_INT || k == TK_BYTE { return ty_bits(t); }
    return 0;
}
fn cf_ty_is_byte_or_byte_vec(t: i32) -> bool { ty_kind(ty_scalar(t)) == TK_BYTE }
fn cf_ty_is_ptr_or_ptr_vec(t: i32) -> bool { ty_kind(ty_scalar(t)) == TK_PTR }
fn cf_vec_count(t: i32) -> i64 { if ty_is_vector(t) { ty_count(t) } else { 0 } }
// CastInst::castIsValid for BitCast / IntToPtr / PtrToInt
fn cf_cast_is_valid(o: i64, st: i32, dt: i32) -> bool {
    if !ty_is_first_class(st) || !ty_is_first_class(dt) || ty_is_aggregate(st) || ty_is_aggregate(dt) { return false; }
    let sv = ty_is_vector(st);
    let dv = ty_is_vector(dt);
    let sec = cf_vec_count(st);
    let dec = cf_vec_count(dt);
    let ssc = ty_kind(st) == TK_SVEC;
    let dsc = ty_kind(dt) == TK_SVEC;
    if o == OP_PTRTOINT { return sec == dec && ssc == dsc && cf_ty_is_ptr_or_ptr_vec(st) && is_int_or_int_vec(dt); }
    if o == OP_INTTOPTR { return sec == dec && ssc == dsc && is_int_or_int_vec(st) && cf_ty_is_ptr_or_ptr_vec(dt); }
    let sp = cf_ty_is_ptr_or_ptr_vec(st);
    let dp = cf_ty_is_ptr_or_ptr_vec(dt);
    if (sp && cf_ty_is_byte_or_byte_vec(dt)) || (cf_ty_is_byte_or_byte_vec(st) && dp) { return true; }
    if sp != dp { return false; }
    if !sp { return cf_prim_bits(st) == cf_prim_bits(dt); }
    if ptr_as(ty_scalar(st)) != ptr_as(ty_scalar(dt)) { return false; }
    if sv && dv { return sec == dec && ssc == dsc; }
    if sv { return sec == 1 && !ssc; }
    if dv { return dec == 1 && !dsc; }
    return true;
}

// ConstantFoldLoadThroughBitcast(C, DestTy)
recursive fn cf_fold_load_through_bitcast(c0: i32, dty: i32) -> i32 {
    var c = c0;
    while c >= 0 {
        let st = vals[c].ty;
        if st == dty { return c; }
        // TypeSize: known-minimum bits, scalable flag
        let dsz = dl_size_bits(dty);
        let ssz = dl_size_bits(st);
        let dsc = ty_size_scalable(dty);
        let ssc = ty_size_scalable(st);
        // TypeSize::isKnownGE(SrcSize, DestSize)
        if ssz < dsz || (dsc && !ssc) { return -1; }
        let u = cf_fold_load_from_uniform(c, dty);
        if u >= 0 { return u; }
        if ssz == dsz && ssc == dsc && cf_is_nonintegral_ptr_ty(st) == cf_is_nonintegral_ptr_ty(dty) {
            var o = OP_BITCAST;
            if ty_is_int(st) && ty_kind(dty) == TK_PTR { o = OP_INTTOPTR; }
            else if ty_kind(st) == TK_PTR && ty_is_int(dty) { o = OP_PTRTOINT; }
            if cf_cast_is_valid(o, st, dty) { return cf_fold_cast_operand(o, c, dty); }
        }
        if !ty_is_aggregate(st) && !ty_is_vector(st) { return -1; }
        if ty_kind(st) == TK_STRUCT {
            var e: i64 = 0;
            var ec: i32 = -1;
            while true {
                ec = agg_elem(c, e);
                e++;
                if ec < 0 || dl_size_bits(vals[ec].ty) != 0 { break; }
            }
            c = ec;
        } else {
            if ty_is_vector(st) && dl_size_bits(ty_elem(st)) != dl_store_size(ty_elem(st)) * 8 { return -1; }
            c = agg_elem(c, 0);
        }
    }
    return -1;
}

// ConstantFoldLoadFromConst(C, Ty, Offset)
recursive fn cf_fold_load_from_const(c: i32, ty: i32, off: i64) -> i32 {
    let at = cf_constant_at_offset(c, off);
    if at >= 0 {
        let r = cf_fold_load_through_bitcast(at, ty);
        if r >= 0 { return r; }
    }
    if ty_kind(vals[c].ty) != TK_SVEC && off >= dl_alloc_size(vals[c].ty) { return c_poison(ty); }
    let u = cf_fold_load_from_uniform(c, ty);
    if u >= 0 { return u; }
    return cf_fold_reinterpret_load(c, ty, ty, off);
}

// ReadDataFromGlobal: bytes go to cf_raw[cur .. cur + left)
var cf_raw: u8[>..<] = [];
fn cint_word(c: i32, k: i64) -> u64 {
    let bits = ty_bits(vals[c].ty);
    if bits <= 128 { return if k == 0 { cint_lo(c) } else if k == 1 { cint_hi(c) } else { 0 }; }
    return words[csts[vals[c].sub].ext + k];
}
recursive fn cf_read_data(c0: i32, boff0: i64, cur0: i64, left0: i64, byte_load: bool) -> bool {
    var c = c0;
    var boff = boff0;
    var cur = cur0;
    var left = left0;
    let ct = vals[c].ty;
    if boff >= dl_store_size(ct) { return true; }
    let k = vals[c].kind;
    if k == VK_AGGZERO || k == VK_UNDEF || k == VK_POISON { return true; }
    if k == VK_CINT && ty_is_int(ct) {
        let bw = ty_bits(ct);
        if (bw & 7) != 0 { return false; }
        let nb = bw / 8;
        var i: i64 = 0;
        while i != left && boff != nb {
            var n = boff;
            if dl_big_endian { n = nb - n - 1; }
            cf_raw[cur + i] = ((cint_word(c, n / 8) >> ((n % 8) * 8)) & 255) as u8;
            boff++;
            i++;
        }
        return true;
    }
    if k == VK_CFP && ty_is_fp(ct) {
        let fk = ty_kind(ct);
        var it: i32 = -1;
        if fk == TK_DOUBLE { it = ty_int(64); } else if fk == TK_FLOAT { it = ty_int(32); } else if fk == TK_HALF { it = ty_int(16); }
        if it < 0 { return false; }
        return cf_read_data(cf_fold_bitcast_dl(c, it), boff, cur, left, byte_load);
    }
    if k == VK_CSTRUCT {
        var idx = cf_struct_element_containing(ct, boff);
        var cur_elt_off = dl_struct_offset(ct, idx);
        boff -= cur_elt_off;
        while true {
            let e = op(c, idx);
            let esz = dl_alloc_size(vals[e].ty);
            if boff < esz && !cf_read_data(e, boff, cur, left, byte_load) { return false; }
            idx++;
            if idx == ty_count(ct) { return true; }
            let next = dl_struct_offset(ct, idx);
            if left <= next - cur_elt_off - boff { return true; }
            cur += next - cur_elt_off - boff;
            left -= next - cur_elt_off - boff;
            boff = 0;
            cur_elt_off = next;
        }
    }
    if k == VK_CARRAY || k == VK_CVECTOR || k == VK_CDARRAY || k == VK_CDVECTOR || k == VK_CINT || k == VK_CFP {
        var n: i64 = 0;
        var esz: i64 = 0;
        if ty_kind(ct) == TK_ARRAY {
            n = ty_count(ct);
            esz = dl_alloc_size(ty_elem(ct));
        } else {
            if ty_kind(ct) != TK_FVEC { return false; }
            n = ty_count(ct);
            let et = ty_elem(ct);
            if dl_size_bits(et) != dl_store_size(et) * 8 { return false; }
            esz = dl_store_size(et);
        }
        var index = boff / esz;
        var o = boff - index * esz;
        while index != n {
            let e = agg_elem(c, index);
            if e < 0 { return false; }
            if !cf_read_data(e, o, cur, left, byte_load) { return false; }
            let written = esz - o;
            if written >= left { return true; }
            o = 0;
            left -= written;
            cur += written;
            index++;
        }
        return true;
    }
    if is_cexpr(c) && cexpr_op(c) == OP_INTTOPTR && vals[op(c, 0)].ty == int_ptr_type_of(ct) {
        if byte_load { return false; }
        return cf_read_data(op(c, 0), boff, cur, left, byte_load);
    }
    return false;
}

// FoldReinterpretLoadFromConst(C, LoadTy, OrigLoadTy, Offset)
recursive fn cf_fold_reinterpret_load(c: i32, lty: i32, orig: i32, off0: i64) -> i32 {
    if ty_kind(lty) == TK_SVEC { return -1; }
    if !ty_is_int(lty) {
        if !ty_is_fp(lty) && ty_kind(lty) != TK_PTR && ty_kind(lty) != TK_BYTE && !ty_is_vector(lty) { return -1; }
        let mt = ty_int(dl_size_bits(lty));
        var r = cf_fold_reinterpret_load(c, mt, orig, off0);
        if r < 0 { return -1; }
        if is_null_value(r) && !ty_is_x86_amx(lty) { return c_null(lty); }
        let cast_ty = if cf_ty_is_ptr_or_ptr_vec(lty) { int_ptr_type_of(lty) } else { lty };
        r = cf_fold_bitcast_dl(r, cast_ty);
        if cf_ty_is_ptr_or_ptr_vec(lty) {
            if is_null_value(r) && !ty_is_x86_amx(lty) { return c_null(lty); }
            if must_not_introduce_inttoptr(lty) { return -1; }
            r = ce_cast(OP_INTTOPTR, r, lty);
        }
        return r;
    }
    var off = off0;
    let bw = ty_bits(lty);
    let nb = (bw + 7) / 8;
    if nb > 128 || nb == 0 { return -1; }
    if nb > 32 && ty_is_int(orig) { return -1; }
    if off <= -nb { return c_poison(lty); }
    if ty_kind(vals[c].ty) == TK_SVEC { return -1; }
    if off >= dl_alloc_size(vals[c].ty) { return c_poison(lty); }
    let mark = cf_raw.len;
    for i in nb { cf_raw.push(0); }
    var cur = mark;
    var left = nb;
    if off < 0 { cur += -off; left += off; off = 0; }
    let ok = cf_read_data(c, off, cur, left, cf_ty_is_byte_or_byte_vec(orig));
    if !ok { cf_raw.resize(mark); return -1; }
    // assemble the little/big-endian value into 64-bit words
    let nw = (bw + 63) / 64;
    var ws: u64[>..] = [];
    for k in nw { ws.push(0); }
    for i in nb {
        let b = if dl_big_endian { cf_raw[mark + nb - 1 - i] } else { cf_raw[mark + i] };
        ws[i / 8] |= (b as u64) << ((i % 8) * 8);
    }
    cf_raw.resize(mark);
    if bw <= 128 { return c_int_words(lty, ws[0], if nw > 1 { ws[1] } else { 0 }); }
    return c_int_wide(lty, ws);
}

// SymbolicallyEvaluateGEP (+ CastGEPIndices): gep constant expression or instruction with constant operands
recursive fn symbolic_gep(srcty: i32, rty: i32, flags0: u8, inr: i32, mark: i64, n: i64) -> i32 {
    if !ty_is_sized_cf(srcty) || ty_kind(srcty) == TK_SVEC { return -1; }
    // CastGEPIndices
    let iit = index_type_of(rty);
    let iis = ty_scalar(iit);
    var any = false;
    var cur = srcty;
    for k in 1..n {
        let x = is_ops[mark + k];
        let is_struct_idx = k > 1 && ty_is_struct(cur);
        if !is_struct_idx && ty_scalar(vals[x].ty) != iis { any = true; }
        if k > 1 { cur = if ty_is_struct(cur) { ty_field(cur, ci_val(m_apint(x)) as i64) } else { types[cur].a }; }
    }
    if any {
        let m2 = is_ops.len;
        cur = srcty;
        for k in 1..n {
            let x = is_ops[mark + k];
            let is_struct_idx = k > 1 && ty_is_struct(cur);
            if !is_struct_idx && ty_scalar(vals[x].ty) != iis {
                let nt = if ty_is_vector(vals[x].ty) { iit } else { iis };
                let sb = ty_scalar_bits(vals[x].ty);
                let db = ty_bits(iis);
                let co = if sb > db { OP_TRUNC } else if sb < db { OP_SEXT } else { OP_BITCAST };
                let ni = cf_fold_cast_operand(co, x, nt);
                if ni < 0 { is_ops.resize(m2); return -1; }
                is_ops.push(ni);
            } else { is_ops.push(x); }
            if k > 1 { cur = if ty_is_struct(cur) { ty_field(cur, ci_val(m_apint(x)) as i64) } else { types[cur].a }; }
        }
        let g = ce_gep(srcty, is_ops[mark], is_ops[m2..], flags0, inr);
        is_ops.resize(m2);
        return cf_fold_constant(g);
    }
    var ptr = is_ops[mark];
    if ty_kind(vals[ptr].ty) != TK_PTR { return -1; }
    for k in 1..n {
        let x = is_ops[mark + k];
        if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { return -1; }
    }
    let bw = dl_size_bits(iit);
    if bw > 64 { cfa_not_ported("index widths over 64 bits"); }
    // DL.getIndexedOffsetInType
    var offset: i64 = 0;
    cur = srcty;
    for k in 1..n {
        let x = is_ops[mark + k];
        if k == 1 { offset += ci_sval(x) * dl_alloc_size(cur); continue; }
        if ty_is_struct(cur) {
            let fi = ci_val(x) as i64;
            offset += dl_struct_offset(cur, fi);
            cur = ty_field(cur, fi);
        } else {
            let et = types[cur].a;
            offset += ci_sval(x) * dl_gep_stride(cur, et);
            cur = et;
        }
    }
    offset = sext64((offset as! u64) & wmask64(bw), bw);
    if inr >= 0 { cfa_not_ported("inrange GEP folding"); }
    var nw = flags0;
    var overflow = false;
    while is_cexpr(ptr) && cexpr_op(ptr) == OP_GEP {
        nw &= csts[vals[ptr].sub].flags;
        var allci = true;
        for k in 1..nops(ptr) { let x = op(ptr, k); if vals[x].kind != VK_CINT || ty_is_vector(vals[x].ty) { allci = false; } }
        if !allci { break; }
        if csts[vals[ptr].sub].inr >= 0 { cfa_not_ported("inrange GEP folding"); }
        let st2 = csts[vals[ptr].sub].ty2;
        var o2: i64 = 0;
        var c2 = st2;
        for k in 1..nops(ptr) {
            let x = op(ptr, k);
            if k == 1 { o2 += ci_sval(x) * dl_alloc_size(c2); continue; }
            if ty_is_struct(c2) { let fi = ci_val(x) as i64; o2 += dl_struct_offset(c2, fi); c2 = ty_field(c2, fi); }
            else { let et = types[c2].a; o2 += ci_sval(x) * dl_gep_stride(c2, et); c2 = et; }
        }
        o2 = sext64((o2 as! u64) & wmask64(bw), bw);
        let sum = offset + o2;
        let wr = sext64((sum as! u64) & wmask64(bw), bw);
        if wr != sum || ((offset > 0 && o2 > 0 && sum < 0) || (offset < 0 && o2 < 0 && sum >= 0)) { overflow = true; }
        offset = wr;
        ptr = op(ptr, 0);
    }
    if (nw & GEP_NUSW) != 0 && (nw & GEP_INBOUNDS) == 0 && overflow { nw &= ~(GEP_NUSW | GEP_INBOUNDS); }
    // literal integer base
    let pbits = dl_ptr(ptr_as(vals[ptr].ty)).bits;
    var base_int: u64 = 0;
    if is_cexpr(ptr) && cexpr_op(ptr) == OP_INTTOPTR {
        let b = op(ptr, 0);
        if vals[b].kind == VK_CINT && !ty_is_vector(vals[b].ty) { base_int = ap_lo64(ap_zext_or_trunc(ci_ap(b), pbits)); }
    }
    if (is_null_value(ptr) || base_int != 0) && !cf_must_not_introduce_inttoptr_dl(vals[ptr].ty) {
        let low = ((base_int & wmask64(bw)) + (offset as! u64)) & wmask64(bw);
        let v = (base_int & ~wmask64(bw)) | low;
        let ci = c_int_words(ty_int(pbits), v, 0);
        return ce_cast(OP_INTTOPTR, ci, rty);
    }
    if (nw & GEP_INBOUNDS) == 0 && offset >= 0 {
        let db, cbn = pointer_deref_bytes(ptr);
        if db != 0 && !cbn && (offset as u64) <= db { nw |= GEP_INBOUNDS | GEP_NUSW; }
    }
    if (nw & GEP_NUSW) != 0 && offset >= 0 { nw |= GEP_NUW; }
    // ConstantExpr::getPtrAdd(Ptr, Offset, NW, InRange)
    let oc = c_int_words(ty_int(bw), (offset as! u64) & wmask64(bw), 0);
    return ce_gep(T_I8, ptr, [oc], nw, -1);
}
// DL.isNonIntegralPointerType(LoadTy->getScalarType()) (FoldReinterpretLoadFromConst)
fn must_not_introduce_inttoptr(t: i32) -> bool { cf_is_nonintegral_ptr_ty(t) }
// DataLayout::mustNotIntroduceIntToPtr(Ty)
fn cf_must_not_introduce_inttoptr_dl(t: i32) -> bool {
    let s = ty_scalar(t);
    if ty_kind(s) != TK_PTR { return false; }
    let a = types[s].n as i64;
    return dl_has_unstable_repr(a) || dl_has_external_state(a);
}
fn cf_is_nonintegral_ptr_ty(t: i32) -> bool {
    let s = ty_scalar(t);
    return ty_kind(s) == TK_PTR && dl_is_nonintegral_as(types[s].n as i64);
}
recursive fn ty_is_sized_cf(t: i32) -> bool { cf_ty_is_sized(t) }

// ConstantFoldInstOperandsImpl for a constant expression (CE->getWithOperands for the rest)
recursive fn cf_fold_cexpr_operands(ce: i32, mark: i64, n: i64) -> i32 {
    let o = cexpr_op(ce);
    if is_binary_op(o) { return cf_fold_binop_operands(o, is_ops[mark], is_ops[mark + 1]); }
    if is_cast_op(o) { return cf_fold_cast_operand(o, is_ops[mark], vals[ce].ty); }
    if o == OP_GEP {
        let c = csts[vals[ce].sub];
        let r = symbolic_gep(c.ty2, vals[ce].ty, c.flags, c.inr, mark, n);
        if r >= 0 { return r; }
        return ce_gep(c.ty2, is_ops[mark], is_ops[mark + 1..mark + n], c.flags, c.inr);
    }
    // getWithOperands
    if o == OP_EXTRACTELEMENT { return ce_extractelement(is_ops[mark], is_ops[mark + 1]); }
    if o == OP_INSERTELEMENT { return ce_insertelement(is_ops[mark], is_ops[mark + 1], is_ops[mark + 2]); }
    if o == OP_SHUFFLEVECTOR {
        let c = csts[vals[ce].sub];
        return ce_shufflevector(is_ops[mark], is_ops[mark + 1], ints[c.aux..c.aux + c.naux]);
    }
    cfa_not_ported("constant expression rebuild for this opcode");
    return -1;
}

// ConstantFoldConstant (ConstantFoldConstantImpl without the FoldedOps memo: the result is the same)
recursive fn cf_fold_constant(c: i32) -> i32 {
    let k = vals[c].kind;
    if k != VK_CVECTOR && k != VK_CEXPR { return c; }
    let mark = is_ops.len;
    let n = nops(c);
    for i in n {
        let o = op(c, i);
        let ok = vals[o].kind;
        if ok == VK_CVECTOR || ok == VK_CEXPR {
            let nc = cf_fold_constant(o);
            is_ops.push(nc);
        } else { is_ops.push(o); }
    }
    if k == VK_CEXPR {
        let r = cf_fold_cexpr_operands(c, mark, n);
        is_ops.resize(mark);
        if r >= 0 { return r; }
        return c;
    }
    let r = c_aggregate(vals[c].ty, is_ops[mark..mark + n]);
    is_ops.resize(mark);
    return r;
}

// ConstantFoldCompareInstOperands
recursive fn cf_fold_cmp_operands(p0: i64, a: i32, b: i32, cxt: i32) -> i32 {
    let p = p0 & 255;
    if is_cexpr(a) {
        let ao = cexpr_op(a);
        if is_null_value(b) {
            if ao == OP_INTTOPTR {
                let ipt = int_ptr_type_of(vals[a].ty);
                let c = cf_fold_integer_cast(op(a, 0), ipt, false);
                if c >= 0 { return cf_fold_cmp_operands(p, c, c_null(vals[c].ty), -1); }
            }
            if ao == OP_PTRTOINT || ao == OP_PTRTOADDR {
                let at = address_type_of(vals[op(a, 0)].ty);
                if vals[a].ty == at {
                    let c = op(a, 0);
                    return cf_fold_cmp_operands(p, c, c_null(vals[c].ty), -1);
                }
            }
        }
        if is_cexpr(b) && cexpr_op(b) == ao {
            if ao == OP_INTTOPTR {
                let ipt = int_ptr_type_of(vals[a].ty);
                let c0 = cf_fold_integer_cast(op(a, 0), ipt, false);
                let c1 = cf_fold_integer_cast(op(b, 0), ipt, false);
                if c0 >= 0 && c1 >= 0 { return cf_fold_cmp_operands(p, c0, c1, -1); }
            }
            if ao == OP_PTRTOINT || ao == OP_PTRTOADDR {
                let at = address_type_of(vals[op(a, 0)].ty);
                if vals[a].ty == at && vals[op(a, 0)].ty == vals[op(b, 0)].ty {
                    return cf_fold_cmp_operands(p, op(a, 0), op(b, 0), -1);
                }
            }
        }
        if ty_kind(vals[a].ty) == TK_PTR && !(p >= 38 && p <= 41) {
            let eq = p == 32 || p == 33;
            let s0 = strip_and_accumulate_offsets(a, eq, false, eq);
            let o0 = vt_off;
            let s1 = strip_and_accumulate_offsets(b, eq, false, eq);
            let o1 = vt_off;
            if s0 == s1 {
                let iw = dl_ptr(ptr_as(vals[a].ty)).idx;
                let sp = if p >= 34 && p <= 37 { p + 4 } else { p };
                return c_bool_ty(T_I1, icmp_compare((o0 as! u64) & wmask64(iw), (o1 as! u64) & wmask64(iw), sp, iw));
            }
        }
    } else if is_cexpr(b) {
        let sp = if p >= 32 { pred_swapped(p) } else { pred_swap_any(p) };
        return cf_fold_cmp_operands(sp, b, a, -1);
    }
    if p < 32 {
        // FlushFPConstant(Op, I, IsOutput = false); without I the mode is Dynamic and a denormal stops the fold
        let fa = cf_flush_fp(a, cxt, false);
        if fa < 0 { return -1; }
        let fb = cf_flush_fp(b, cxt, false);
        if fb < 0 { return -1; }
        return cf_compare(p, fa, fb);
    }
    return cf_compare(p, a, b);
}

// getInstrDenormalMode(CtxI, Ty) as (input, output) kinds: 0 IEEE, 1 PreserveSign, 2 PositiveZero, 3 Dynamic.
// No context instruction: Dynamic. denormal_fpenv's low nibble is the default mode, the next one f32's.
fn cf_denormal_mode(cxt: i32, ty: i32, is_output: bool) -> i64 {
    if cxt < 0 { return 3; }
    let f = inst_func(cxt);
    if f < 0 { return 3; }
    let at = aset_find(alist_fn(globs[glob_of(f)].attrs), AK_DenormalFPEnv);
    if at < 0 { return 0; }
    var m = (attrs[at].i1 & 15) as! i64;
    if ty_kind(ty_scalar(ty)) == TK_FLOAT { m = ((attrs[at].i1 >> 4) & 15) as! i64; }
    return if is_output { m & 3 } else { (m >> 2) & 3 };
}
// flushDenormalConstantFP: -1 = nullptr
fn cf_flush_denormal_fp(c: i32, cxt: i32, is_output: bool) -> i32 {
    if !fp_is_denormal(c) { return c; }
    let mode = cf_denormal_mode(cxt, vals[c].ty, is_output);
    if mode == 0 { return c; }
    if mode == 3 { return -1; }
    let neg = cfp_parts(c).neg;
    if mode == 1 && neg { return c_fp_neg_zero_ty(vals[c].ty); }
    return c_null(vals[c].ty);
}
// FlushFPConstant(Operand, Inst, IsOutput): -1 = nullptr
fn cf_flush_fp(c: i32, cxt: i32, is_output: bool) -> i32 {
    let k = vals[c].kind;
    let ty = vals[c].ty;
    if k == VK_CFP && !ty_is_vector(ty) { return cf_flush_denormal_fp(c, cxt, is_output); }
    if k == VK_AGGZERO || k == VK_UNDEF || k == VK_POISON { return c; }
    if ty_is_vector(ty) {
        var s0 = c_splat_value(c);
        if s0 < 0 && k == VK_CFP { s0 = splat_value(c, false); }
        if s0 >= 0 && vals[s0].kind == VK_CFP {
            let f = cf_flush_denormal_fp(s0, cxt, is_output);
            if f < 0 { return -1; }
            if f == s0 { return c; }
            return c_splat(ty, f);
        }
    }
    if k == VK_CEXPR { return c; }
    if k == VK_CVECTOR || k == VK_CDVECTOR {
        var elems: i32[>..<] = [];
        var changed = false;
        for i in nops(c) {
            let e = op(c, i);
            if vals[e].kind == VK_UNDEF || vals[e].kind == VK_POISON { elems.push(e); continue; }
            if vals[e].kind != VK_CFP { return -1; }
            let f = cf_flush_denormal_fp(e, cxt, is_output);
            if f < 0 { return -1; }
            if f != e { changed = true; }
            elems.push(f);
        }
        if !changed { return c; }
        return c_aggregate(ty, elems);
    }
    return -1;
}

// Type::isScalableTy (scalable vectors, also inside structs and arrays)
recursive fn cf_ty_is_scalable(t: i32) -> bool {
    let k = ty_kind(t);
    if k == TK_SVEC { return true; }
    if k == TK_ARRAY { return cf_ty_is_scalable(ty_elem(t)); }
    if k == TK_STRUCT { for i in ty_count(t) { if cf_ty_is_scalable(ty_field(t, i)) { return true; } } }
    if k == TK_TARGETEXT { return false; }
    return false;
}

// ConstantFoldInstOperands(I, Ops) with the operands on is_ops
recursive fn cf_fold_inst_operands(i: i32, mark: i64, n: i64, allow_nondet: bool) -> i32 {
    let o = iop(i);
    if o == OP_FNEG { return cf_fold_unary(o, is_ops[mark]); }
    if is_binary_op(o) {
        if o == OP_FADD || o == OP_FSUB || o == OP_FMUL || o == OP_FDIV || o == OP_FREM {
            return cf_fold_fp_inst_operands(o, is_ops[mark], is_ops[mark + 1], i, allow_nondet);
        }
        return cf_fold_binop_operands(o, is_ops[mark], is_ops[mark + 1]);
    }
    if is_cast_op(o) { return cf_fold_cast_operand(o, is_ops[mark], vals[i].ty); }
    let x = insts[inst_of(i)];
    if o == OP_GEP {
        // ConstantExpr::isSupportedGetElementPtr: not for scalable source element types
        if cf_ty_is_scalable(x.ty2) { return -1; }
        let r = symbolic_gep(x.ty2, vals[i].ty, x.flags, -1, mark, n);
        if r >= 0 { return r; }
        return ce_gep(x.ty2, is_ops[mark], is_ops[mark + 1..mark + n], x.flags, -1);
    }
    if o == OP_ICMP || o == OP_FCMP { return cf_fold_cmp_operands(x.pred as i64, is_ops[mark], is_ops[mark + 1], i); }
    if o == OP_FREEZE {
        let v = is_ops[mark];
        if is_guaranteed_not_to_be_undef_or_poison(v, -1, 0) { return v; }
        return -1;
    }
    if o == OP_CALL {
        let f = is_ops[mark + n - 1];
        if is_func(f) && can_constant_fold_call_to(i, f) {
            return cf_fold_call(i, f, mark, n - 1, allow_nondet);
        }
        return -1;
    }
    if o == OP_SELECT { return cf_select(is_ops[mark], is_ops[mark + 1], is_ops[mark + 2]); }
    if o == OP_EXTRACTELEMENT { return ce_extractelement(is_ops[mark], is_ops[mark + 1]); }
    if o == OP_EXTRACTVALUE { return cf_extractvalue(is_ops[mark], ints[x.aux..x.aux + x.naux]); }
    if o == OP_INSERTELEMENT { return ce_insertelement(is_ops[mark], is_ops[mark + 1], is_ops[mark + 2]); }
    if o == OP_INSERTVALUE { return cf_insertvalue(is_ops[mark], is_ops[mark + 1], ints[x.aux..x.aux + x.naux]); }
    if o == OP_SHUFFLEVECTOR { return ce_shufflevector(is_ops[mark], is_ops[mark + 1], ints[x.aux..x.aux + x.naux]); }
    if o == OP_LOAD {
        if inst_is_volatile(i) { return -1; }
        return cf_fold_load_from_const_ptr(is_ops[mark], vals[i].ty, 0, false);
    }
    return -1;
}

// ---------------------------------------------------------------------------------------------
// Calls

fn ty_is_fp_scalar(t: i32) -> bool { ty_is_fp(t) }

// canConstantFoldCallTo
fn can_constant_fold_call_to(c: i32, f: i32) -> bool {
    if call_is_nobuiltin(c) { return false; }
    if insts[inst_of(c)].ty2 != globs[glob_of(f)].vty { return false; }
    if flag_bool("disable-fp-call-folding", false) { cfa_not_ported("-disable-fp-call-folding"); }
    let id = func_iid(f) as i32;
    if id != 0 {
        if id == IID_bswap || id == IID_ctpop || id == IID_ctlz || id == IID_cttz || id == IID_fshl || id == IID_fshr ||
           id == IID_clmul || id == IID_pdep || id == IID_pext || id == IID_launder_invariant_group ||
           id == IID_strip_invariant_group || id == IID_masked_load || id == IID_get_active_lane_mask || id == IID_abs ||
           id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin || id == IID_scmp || id == IID_ucmp ||
           id == IID_sadd_with_overflow || id == IID_uadd_with_overflow || id == IID_ssub_with_overflow ||
           id == IID_usub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow ||
           id == IID_sadd_sat || id == IID_uadd_sat || id == IID_ssub_sat || id == IID_usub_sat || id == IID_smul_fix ||
           id == IID_smul_fix_sat || id == IID_bitreverse || id == IID_is_constant || id == IID_vector_reduce_add ||
           id == IID_vector_reduce_mul || id == IID_vector_reduce_and || id == IID_vector_reduce_or ||
           id == IID_vector_reduce_xor || id == IID_vector_reduce_smin || id == IID_vector_reduce_smax ||
           id == IID_vector_reduce_umin || id == IID_vector_reduce_umax || id == IID_vector_extract ||
           id == IID_vector_insert || interleave_factor_cf(id) != 0 || deinterleave_factor_cf(id) != 0 {
            return true;
        }
        if id == IID_minnum || id == IID_maxnum || id == IID_minimum || id == IID_maximum || id == IID_minimumnum ||
           id == IID_maximumnum || id == IID_log || id == IID_log2 || id == IID_log10 || id == IID_exp || id == IID_exp2 ||
           id == IID_exp10 || id == IID_sqrt || id == IID_sin || id == IID_cos || id == IID_sincos || id == IID_sinh ||
           id == IID_cosh || id == IID_atan || id == IID_pow || id == IID_powi || id == IID_ldexp || id == IID_fma ||
           id == IID_fmuladd || id == IID_frexp || id == IID_fptoui_sat || id == IID_fptosi_sat || is_x86_cvt_iid(id) {
            return !call_is_strictfp(c);
        }
        if id == IID_fabs || id == IID_copysign || id == IID_is_fpclass || id == IID_ceil || id == IID_floor ||
           id == IID_round || id == IID_roundeven || id == IID_trunc || id == IID_nearbyint || id == IID_rint ||
           id == IID_canonicalize || id == IID_experimental_constrained_fma || id == IID_experimental_constrained_fmuladd ||
           id == IID_experimental_constrained_fadd || id == IID_experimental_constrained_fsub ||
           id == IID_experimental_constrained_fmul || id == IID_experimental_constrained_fdiv ||
           id == IID_experimental_constrained_frem || id == IID_experimental_constrained_ceil ||
           id == IID_experimental_constrained_floor || id == IID_experimental_constrained_round ||
           id == IID_experimental_constrained_roundeven || id == IID_experimental_constrained_trunc ||
           id == IID_experimental_constrained_nearbyint || id == IID_experimental_constrained_rint ||
           id == IID_experimental_constrained_fcmp || id == IID_experimental_constrained_fcmps ||
           id == IID_experimental_cttz_elts {
            return true;
        }
        return false;
    }
    if vals[f].name < 0 || call_is_strictfp(c) { return false; }
    let nm = sbytes(vals[f].name);
    return nm == "acos" || nm == "acosf" || nm == "asin" || nm == "asinf" || nm == "atan" || nm == "atanf" ||
        nm == "atan2" || nm == "atan2f" || nm == "ceil" || nm == "ceilf" || nm == "cos" || nm == "cosf" ||
        nm == "cosh" || nm == "coshf" || nm == "exp" || nm == "expf" || nm == "exp2" || nm == "exp2f" ||
        nm == "erf" || nm == "erff" || nm == "fabs" || nm == "fabsf" || nm == "floor" || nm == "floorf" ||
        nm == "fmod" || nm == "fmodf" || nm == "ilogb" || nm == "ilogbf" || nm == "log" || nm == "logf" ||
        nm == "logl" || nm == "log2" || nm == "log2f" || nm == "log10" || nm == "log10f" || nm == "logb" ||
        nm == "logbf" || nm == "log1p" || nm == "log1pf" || nm == "nearbyint" || nm == "nearbyintf" ||
        nm == "nextafter" || nm == "nextafterf" || nm == "nexttoward" || nm == "nexttowardf" || nm == "pow" ||
        nm == "powf" || nm == "remainder" || nm == "remainderf" || nm == "rint" || nm == "rintf" ||
        nm == "round" || nm == "roundf" || nm == "roundeven" || nm == "roundevenf" || nm == "sin" ||
        nm == "sinf" || nm == "sinh" || nm == "sinhf" || nm == "sqrt" || nm == "sqrtf" || nm == "tan" ||
        nm == "tanf" || nm == "tanh" || nm == "tanhf" || nm == "trunc" || nm == "truncf" ||
        nm == "__acos_finite" || nm == "__acosf_finite" || nm == "__asin_finite" || nm == "__asinf_finite" ||
        nm == "__atan2_finite" || nm == "__atan2f_finite" || nm == "__cosh_finite" || nm == "__coshf_finite" ||
        nm == "__exp_finite" || nm == "__expf_finite" || nm == "__exp2_finite" || nm == "__exp2f_finite" ||
        nm == "__log_finite" || nm == "__logf_finite" || nm == "__log10_finite" || nm == "__log10f_finite" ||
        nm == "__pow_finite" || nm == "__powf_finite" || nm == "__sinh_finite" || nm == "__sinhf_finite";
}
// The x86 scalar conversion intrinsics ConstantFolding folds: 0 = not one of them, 1 = SSE (one operand),
// 2 = AVX-512 (operand 1 is the rounding mode); with roundTowardZero and IsSigned as LLVM passes them.
fn x86_cvt_info(id: i32) -> i64, bool, bool {
    if id == IID_x86_sse_cvtss2si || id == IID_x86_sse_cvtss2si64 || id == IID_x86_sse2_cvtsd2si || id == IID_x86_sse2_cvtsd2si64 { return 1, false, true; }
    if id == IID_x86_sse_cvttss2si || id == IID_x86_sse_cvttss2si64 || id == IID_x86_sse2_cvttsd2si || id == IID_x86_sse2_cvttsd2si64 { return 1, true, true; }
    if id == IID_x86_avx512_vcvtss2si32 || id == IID_x86_avx512_vcvtss2si64 || id == IID_x86_avx512_vcvtsd2si32 || id == IID_x86_avx512_vcvtsd2si64 { return 2, false, true; }
    if id == IID_x86_avx512_vcvtss2usi32 || id == IID_x86_avx512_vcvtss2usi64 || id == IID_x86_avx512_vcvtsd2usi32 || id == IID_x86_avx512_vcvtsd2usi64 { return 2, false, false; }
    if id == IID_x86_avx512_cvttss2si || id == IID_x86_avx512_cvttss2si64 || id == IID_x86_avx512_cvttsd2si || id == IID_x86_avx512_cvttsd2si64 { return 2, true, true; }
    if id == IID_x86_avx512_cvttss2usi || id == IID_x86_avx512_cvttss2usi64 || id == IID_x86_avx512_cvttsd2usi || id == IID_x86_avx512_cvttsd2usi64 { return 2, true, false; }
    return 0, false, false;
}
// isa<ConstantFP> on a vector operand: LLVM 23 makes FP splats (and the FP null vector) vector-typed
// ConstantFPs; here they are CDVECTOR/CVECTOR with equal elements, or the flagged AGGZERO (c_is_vector_cfp, ir.goose)
fn cf_is_vector_constant_fp(v: i32) -> bool { c_is_vector_cfp(v) }
fn is_x86_cvt_iid(id: i32) -> bool {
    let k, rtz, sg = x86_cvt_info(id);
    return k != 0;
}
// ConstantFoldSSEConvertToInt: APFloat::convertToInteger(rmTowardZero or rmNearestTiesToEven); null (-1)
// unless the status is opOK (or opInexact when rounding toward zero)
fn cf_sse_convert_to_int(fpv: i32, ty: i32, rtz: bool, signed: bool) -> i32 {
    let kind = types[vals[fpv].ty].kind as i64;
    let w = ty_bits(ty);
    let f = fp_fmt(kind);
    let p = fp_decompose(kind, cint_lo(fpv), cint_hi(fpv));
    if p.cat == FC_NAN || p.cat == FC_INF { return -1; }
    if p.cat == FC_ZERO { return c_null(ty); }
    let mw = w + 130;
    let sig = ap_from_words(mw, [p.sig0, p.sig1]);
    let sh = p.exponent - (f.p - 1);
    var mag = ap_zero(mw);
    var inexact = false;
    if sh >= 0 {
        if sh + f.p > w + 1 { return -1; }
        mag = ap_shl(sig, sh);
    } else if -sh >= mw {
        inexact = true;
    } else {
        mag = ap_lshr(sig, -sh);
        inexact = !ap_eq(ap_shl(mag, -sh), sig);
    }
    if inexact && !rtz { return -1; }
    let maxbits = if signed { w - 1 } else { w };
    let abits = ap_active_bits(mag);
    if p.neg && !ap_is_zero(mag) {
        if !signed { return -1; }
        if abits > maxbits + 1 { return -1; }
        if abits == maxbits + 1 && ap_countr_zero(mag) != abits - 1 { return -1; }
        return ap_to_cint(ty, ap_neg(ap_trunc(mag, w)));
    }
    if abits > maxbits { return -1; }
    return ap_to_cint(ty, ap_trunc(mag, w));
}
fn interleave_factor_cf(id: i32) -> i64 {
    if id == IID_vector_interleave2 { return 2; } if id == IID_vector_interleave3 { return 3; }
    if id == IID_vector_interleave4 { return 4; } if id == IID_vector_interleave5 { return 5; }
    if id == IID_vector_interleave6 { return 6; } if id == IID_vector_interleave7 { return 7; }
    if id == IID_vector_interleave8 { return 8; }
    return 0;
}
fn deinterleave_factor_cf(id: i32) -> i64 {
    if id == IID_vector_deinterleave2 { return 2; } if id == IID_vector_deinterleave3 { return 3; }
    if id == IID_vector_deinterleave4 { return 4; } if id == IID_vector_deinterleave5 { return 5; }
    if id == IID_vector_deinterleave6 { return 6; } if id == IID_vector_deinterleave7 { return 7; }
    if id == IID_vector_deinterleave8 { return 8; }
    return 0;
}

// ConstantFoldCall(Call, F, Operands); operands on is_ops[mark..mark+n)
recursive fn cf_fold_call(c: i32, f: i32, mark: i64, n: i64, allow_nondet: bool) -> i32 {
    if call_is_nobuiltin(c) { return -1; }
    if vals[f].name < 0 { return -1; }
    let id = func_iid(f) as i32;
    if id == 0 {
        if sq_no_tli || tli_get_libfunc(f) < 0 { return -1; }
    }
    let rty = ty_fn_ret(globs[glob_of(f)].vty);
    if !allow_nondet && is_fp_or_fp_vec(rty) { return -1; }
    if ty_kind(rty) == TK_FVEC { return cf_fold_fixed_vector_call(c, id, rty, mark, n); }
    if ty_kind(rty) == TK_SVEC { cfa_not_ported("constant folding of scalable vector calls"); }
    if ty_is_struct(rty) {
        if id == IID_frexp || id == IID_sincos {
            if intrinsic_propagates_poison(id) { for k in n { if is_poison(is_ops[mark + k]) { return c_poison(rty); } } }
            return cf_fold_frexp_sincos(id, rty, is_ops[mark]);
        }
        if deinterleave_factor_cf(id) != 0 { cfa_not_ported("constant folding of vector.deinterleave"); }
        return cf_fold_scalar_call(c, id, rty, mark, n);
    }
    return cf_fold_scalar_call(c, id, rty, mark, n);
}

fn vec_intrinsic_scalar_op_at(id: i32, k: i64) -> bool {
    if id == IID_abs || id == IID_ctlz || id == IID_cttz || id == IID_is_fpclass || id == IID_powi || id == IID_vector_extract { return k == 1; }
    if id == IID_smul_fix || id == IID_smul_fix_sat || id == IID_umul_fix || id == IID_umul_fix_sat ||
       id == IID_vector_splice_left || id == IID_vector_splice_right { return k == 2; }
    return false;
}

recursive fn cf_fold_fixed_vector_call(c: i32, id: i32, vty: i32, mark: i64, n: i64) -> i32 {
    let et = types[vty].a;
    if id == IID_masked_load || id == IID_get_active_lane_mask || id == IID_vector_extract || id == IID_vector_insert ||
       interleave_factor_cf(id) != 0 {
        cfa_not_ported(str("constant folding of ", intr_name(id as i64)));
    }
    let ne = ty_count(vty);
    let rm = is_ops.len;
    for i in ne {
        let lm = is_ops.len;
        for j in n {
            let opj = is_ops[mark + j];
            if vec_intrinsic_scalar_op_at(id, j) { is_ops.push(opj); continue; }
            let a = agg_elem(opj, i);
            if a < 0 { is_ops.resize(rm); return -1; }
            is_ops.push(a);
        }
        let folded = cf_fold_scalar_call(c, id, et, lm, n);
        is_ops.resize(lm);
        if folded < 0 { is_ops.resize(rm); return -1; }
        is_ops.push(folded);
    }
    let r = c_aggregate(vty, is_ops[rm..rm + ne]);
    is_ops.resize(rm);
    return r;
}

// getConstIntOrUndef: 1 = ConstantInt, 0 = undef, -1 = neither
fn const_int_or_undef(v: i32) -> i64 {
    if vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) { return 1; }
    if is_undef_val(v) { return 0; }
    return -1;
}

recursive fn cf_fold_scalar_call(c: i32, id: i32, ty: i32, mark: i64, n: i64) -> i32 {
    if id != 0 && intrinsic_propagates_poison(id) {
        for k in n { if is_poison(is_ops[mark + k]) { return c_poison(ty); } }
    }
    if id == 0 { return cf_fold_libcall(c, ty, mark, n); }
    if (id == IID_experimental_constrained_fcmp || id == IID_experimental_constrained_fcmps) && n == 2 {
        let a = is_ops[mark];
        let b = is_ops[mark + 1];
        if vals[a].kind == VK_CFP && vals[b].kind == VK_CFP && !ty_is_vector(vals[a].ty) {
            return cf_constrained_fcmp(c, id, a, b, ty);
        }
    }
    if n == 1 {
        let a = is_ops[mark];
        if id == IID_is_constant { cfa_not_ported("llvm.is.constant folding"); }
        if is_undef_val(a) {
            if id == IID_cos || id == IID_ctpop || id == IID_fptoui_sat || id == IID_fptosi_sat || id == IID_canonicalize { return c_null(ty); }
            if id == IID_bswap || id == IID_bitreverse || id == IID_launder_invariant_group || id == IID_strip_invariant_group { return a; }
        }
        if vals[a].kind == VK_CNULL && !ty_is_vector(vals[a].ty) {
            if id == IID_launder_invariant_group || id == IID_strip_invariant_group {
                if !null_pointer_is_defined(inst_func(c), ptr_as(vals[a].ty)) { return a; }
                return -1;
            }
        }
        if vals[a].kind == VK_CFP && !ty_is_vector(vals[a].ty) {
            return cf_fold_fp_unary_intrinsic(id, ty, a);
        }
        // a vector-typed ConstantFP also takes the ConstantFP branch, which folds nothing with a vector operand
        // (llvm.x86.sse.cvttss2si(<4 x float> zeroinitializer) stays)
        if c_is_vector_cfp(a) { return -1; }
        if vals[a].kind == VK_CINT && !ty_is_vector(vals[a].ty) {
            let x = ci_ap(a);
            if id == IID_bswap { return c_int_ap(ty, ap_byte_swap(x)); }
            if id == IID_ctpop { return c_int_ty(ty, ap_popcount(x) as u64); }
            if id == IID_bitreverse { return c_int_ap(ty, ap_reverse_bits(x)); }
            return -1;
        }
        if ty_is_vector(vals[a].ty) {
            if id == IID_vector_reduce_add || id == IID_vector_reduce_mul || id == IID_vector_reduce_and ||
               id == IID_vector_reduce_or || id == IID_vector_reduce_xor || id == IID_vector_reduce_smin ||
               id == IID_vector_reduce_smax || id == IID_vector_reduce_umin || id == IID_vector_reduce_umax {
                return cf_vector_reduce(id, a);
            }
            let xk, rtz, sg = x86_cvt_info(id);
            if xk == 1 {
                // a vector ConstantFP goes through ConstantFoldScalarCall1's ConstantFP case (no x86 folds)
                if cf_is_vector_constant_fp(a) { return -1; }
                let e = c_aggregate_element(a, 0);
                if e >= 0 && vals[e].kind == VK_CFP { return cf_sse_convert_to_int(e, ty, rtz, sg); }
                return -1;
            }
        }
        return -1;
    }
    if n == 2 {
        let a = is_ops[mark];
        let b = is_ops[mark + 1];
        let xk, rtz, sg = x86_cvt_info(id);
        if xk == 2 {
            // ConstantVector / ConstantDataVector operand and the default rounding mode (4)
            let vk = vals[a].kind;
            if (vk == VK_CVECTOR || vk == VK_CDVECTOR) && !cf_is_vector_constant_fp(a) && vals[b].kind == VK_CINT && ap_eq(ci_ap(b), ap_u64(4, ty_bits(vals[b].ty))) {
                let e = c_aggregate_element(a, 0);
                if e >= 0 && vals[e].kind == VK_CFP { return cf_sse_convert_to_int(e, ty, rtz, sg); }
            }
            return -1;
        }
        if ty_is_fp(ty) && is_minmax_fp_iid(id) {
            if is_undef_val(a) { return b; }
            if is_undef_val(b) { return a; }
        }
        if ty_is_fp(ty) && vals[a].kind == VK_CFP && vals[b].kind == VK_CFP && !ty_is_vector(vals[a].ty) &&
           vals[a].ty == vals[b].ty && !is_constrained_fp_iid(id) {
            let r = cf_fp_binary_intrinsic(id, a, b);
            if r >= 0 { return r; }
        }
        if vals[a].kind == VK_CFP && !ty_is_vector(vals[a].ty) { return cf_fold_fp_binary_rest(id, ty, a, b); }
        if ty_is_fp(ty) || is_fp_or_fp_vec(vals[a].ty) { return -1; }
        if ty_is_int(vals[a].ty) && ty_is_int(vals[b].ty) {
            let k0 = const_int_or_undef(a);
            let k1 = const_int_or_undef(b);
            if k0 < 0 || k1 < 0 { return -1; }
            let w = ci_w_or(a);
            let x0 = if k0 == 1 { ci_ap(a) } else { ap_zero(w) };
            let x1 = if k1 == 1 { ci_ap(b) } else { ap_zero(ci_w_or(b)) };
            let both = k0 == 1 && k1 == 1;
            if id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin {
                if !both { return c_int_ap(ty, minmax_saturation_ap(id, w)); }
                return c_int_ap(ty, if ap_icmp(x0, x1, minmax_pred(id)) { x0 } else { x1 });
            }
            if id == IID_scmp || id == IID_ucmp {
                if !both { return c_int_ty(ty, 0); }
                let r = if id == IID_scmp { ap_scmp(x0, x1) } else { ap_ucmp(x0, x1) };
                return c_int_ty_s(ty, r);
            }
            if id == IID_usub_with_overflow || id == IID_ssub_with_overflow || id == IID_uadd_with_overflow ||
               id == IID_sadd_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow {
                if !both {
                    if id == IID_usub_with_overflow || id == IID_ssub_with_overflow || id == IID_smul_with_overflow || id == IID_umul_with_overflow { return c_null(ty); }
                    let m = is_ops.len;
                    is_ops.push(c_all_ones(ty_field(ty, 0)));
                    is_ops.push(c_null(ty_field(ty, 1)));
                    let r = c_aggregate(ty, is_ops[m..]);
                    is_ops.resize(m);
                    return r;
                }
                let res, ov = overflow_op(id, x0, x1);
                let rc = ap_to_cint(ty_field(ty, 0), res);
                let m = is_ops.len;
                is_ops.push(rc);
                is_ops.push(c_int_words(T_I1, if ov { 1 } else { 0 }, 0));
                let r = c_aggregate(ty, is_ops[m..]);
                is_ops.resize(m);
                return r;
            }
            if id == IID_uadd_sat || id == IID_sadd_sat {
                if !both { return c_all_ones(ty); }
                if id == IID_uadd_sat { return c_int_ap(ty, ap_uadd_sat(x0, x1)); }
                return c_int_ap(ty, ap_sadd_sat(x0, x1));
            }
            if id == IID_usub_sat || id == IID_ssub_sat {
                if !both { return c_null(ty); }
                if id == IID_usub_sat { return c_int_ap(ty, ap_usub_sat(x0, x1)); }
                return c_int_ap(ty, ap_ssub_sat(x0, x1));
            }
            if id == IID_cttz || id == IID_ctlz {
                if ap_is_one(x1) && (k0 == 0 || ap_is_zero(x0)) { return c_poison(ty); }
                if k0 == 0 { return c_null(ty); }
                if id == IID_cttz { return c_int_ty(ty, ap_countr_zero(x0) as u64); }
                return c_int_ty(ty, ap_countl_zero(x0) as u64);
            }
            if id == IID_abs {
                if ap_is_one(x1) && (k0 == 0 || ap_is_min_signed(x0)) { return c_poison(ty); }
                if k0 == 0 { return c_null(ty); }
                return c_int_ap(ty, ap_abs(x0));
            }
            if id == IID_clmul {
                if !both { return c_null(ty); }
                return c_int_ap(ty, ap_clmul(x0, x1));
            }
            if id == IID_pdep || id == IID_pext { cfa_not_ported("pdep/pext folding"); }
            return -1;
        }
        if id == IID_experimental_cttz_elts || id == IID_get_active_lane_mask { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
        return -1;
    }
    if n == 3 {
        if id == IID_smul_fix || id == IID_smul_fix_sat {
            let a = is_ops[mark];
            let b = is_ops[mark + 1];
            let k0 = const_int_or_undef(a);
            let k1 = const_int_or_undef(b);
            if k0 < 0 || k1 < 0 { return -1; }
            if k0 == 0 || k1 == 0 { return c_null(ty); }
            cfa_not_ported("smul.fix folding");
        }
        if id == IID_fshl || id == IID_fshr {
            let a = is_ops[mark];
            let b = is_ops[mark + 1];
            let s = is_ops[mark + 2];
            let k0 = const_int_or_undef(a);
            let k1 = const_int_or_undef(b);
            let k2 = const_int_or_undef(s);
            if k0 < 0 || k1 < 0 || k2 < 0 { return -1; }
            let right = id == IID_fshr;
            if k2 == 0 { return if right { b } else { a }; }
            if k0 == 0 && k1 == 0 { return c_undef(ty); }
            let w = ci_w(s);
            let sv = ci_ap(s);
            let sh = ap_rot_amount(ap_zero(w), sv);
            if sh == 0 { return if right { b } else { a }; }
            let lshr_amt = if right { sh } else { w - sh };
            let shl_amt = if !right { sh } else { w - sh };
            if k0 == 0 { return c_int_ap(ty, ap_lshr(ci_ap(b), lshr_amt)); }
            if k1 == 0 { return c_int_ap(ty, ap_shl(ci_ap(a), shl_amt)); }
            return c_int_ap(ty, ap_or(ap_shl(ci_ap(a), shl_amt), ap_lshr(ci_ap(b), lshr_amt)));
        }
        let a = is_ops[mark];
        if (id == IID_fma || id == IID_fmuladd) && !is_constrained_fp_iid(id) { return cf_fold_fma(id, ty, a, is_ops[mark + 1], is_ops[mark + 2]); }
        if is_fp_or_fp_vec(vals[a].ty) && (vals[a].kind == VK_CFP || is_undef_val(a)) {
            cfa_not_ported(str("constant folding of ", intr_name(id as i64)));
        }
        if is_constrained_fp_iid(id) { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
        return -1;
    }
    if id == IID_vector_interleave2 || interleave_factor_cf(id) != 0 { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
    return -1;
}
fn is_reduce_iid(id: i32) -> bool {
    return id == IID_vector_reduce_add || id == IID_vector_reduce_mul || id == IID_vector_reduce_and ||
           id == IID_vector_reduce_or || id == IID_vector_reduce_xor || id == IID_vector_reduce_smin ||
           id == IID_vector_reduce_smax || id == IID_vector_reduce_umin || id == IID_vector_reduce_umax;
}
fn ci_w_or(v: i32) -> i64 { ty_scalar_bits(vals[v].ty) }
// ConstantFoldIntrinsicCall2: two ConstantFP operands (copysign and the min/max family; APFloat.h minnum etc.)
fn cf_fp_binary_intrinsic(id: i32, a: i32, b: i32) -> i32 {
    let kind = fp_kind_ty(vals[a].ty);
    let pa = fp_decompose(kind, cint_lo(a), cint_hi(a));
    let pb = fp_decompose(kind, cint_lo(b), cint_hi(b));
    if id == IID_copysign {
        if pa.neg == pb.neg { return a; }
        let lo, hi = fp_neg_bits(kind, cint_lo(a), cint_hi(a));
        return c_fp(vals[a].ty, lo, hi);
    }
    if !is_minmax_fp_iid(id) { return -1; }
    let an = pa.cat == FC_NAN;
    let bn = pb.cat == FC_NAN;
    let a_s = an && cfp_is_signaling(a);
    let b_s = bn && cfp_is_signaling(b);
    let zeros_differ = pa.cat == FC_ZERO && pb.cat == FC_ZERO && pa.neg != pb.neg;
    let is_min = id == IID_minnum || id == IID_minimum || id == IID_minimumnum;
    if id == IID_minnum || id == IID_maxnum {
        if a_s { return c_fp_quiet(a); }
        if b_s { return c_fp_quiet(b); }
        if an { return b; }
        if bn { return a; }
    } else if id == IID_minimum || id == IID_maximum {
        if an { return c_fp_quiet(a); }
        if bn { return c_fp_quiet(b); }
    } else {
        if an { return if bn { c_fp_quiet(b) } else { b }; }
        if bn { return a; }
    }
    if zeros_differ {
        if is_min { return if pa.neg { a } else { b }; }
        return if pa.neg { b } else { a };
    }
    if is_min { return if fp_cmp_lt(b, a) { b } else { a }; }
    return if fp_cmp_lt(a, b) { b } else { a };
}
fn is_minmax_fp_iid(id: i32) -> bool {
    return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum || id == IID_minimumnum;
}

fn overflow_op(id: i32, a: AP, b: AP) -> AP, bool {
    if id == IID_uadd_with_overflow { let r, o = ap_uadd_ov(a, b); return r, o; }
    if id == IID_usub_with_overflow { let r, o = ap_usub_ov(a, b); return r, o; }
    if id == IID_sadd_with_overflow { let r, o = ap_sadd_ov(a, b); return r, o; }
    if id == IID_ssub_with_overflow { let r, o = ap_ssub_ov(a, b); return r, o; }
    if id == IID_umul_with_overflow { let r, o = ap_umul_ov(a, b); return r, o; }
    let r, o = ap_smul_ov(a, b);
    return r, o;
}

// Constant::containsPoisonElement
fn contains_poison_element(c: i32) -> bool {
    if vals[c].kind == VK_POISON { return true; }
    if vals[c].kind == VK_CVECTOR { for i in nops(c) { if vals[op(c, i)].kind == VK_POISON { return true; } } }
    return false;
}

// constantFoldVectorReduce
fn cf_vector_reduce(id: i32, v: i32) -> i32 {
    let ty = vals[v].ty;
    let et = types[ty].a;
    if contains_poison_element(v) { return c_poison(et); }
    let sv = splat_value(v, false);
    if sv >= 0 {
        if id == IID_vector_reduce_and || id == IID_vector_reduce_or || id == IID_vector_reduce_smin ||
           id == IID_vector_reduce_smax || id == IID_vector_reduce_umin || id == IID_vector_reduce_umax { return sv; }
        if id == IID_vector_reduce_add { if is_null_value(sv) { return sv; } }
        if id == IID_vector_reduce_mul { if is_null_value(sv) || is_one_value(sv) { return sv; } }
        if id == IID_vector_reduce_xor {
            if is_null_value(sv) { return sv; }
            if (ty_count(ty) % 2) == 0 { return c_null(et); }
        }
    }
    if ty_kind(ty) != TK_FVEC { return -1; }
    let e0 = agg_elem(v, 0);
    if e0 < 0 || vals[e0].kind != VK_CINT { return -1; }
    var acc = ci_ap(e0);
    for i in 1..ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 || vals[e].kind != VK_CINT { return -1; }
        let x = ci_ap(e);
        if id == IID_vector_reduce_add { acc = ap_add(acc, x); }
        else if id == IID_vector_reduce_mul { acc = ap_mul(acc, x); }
        else if id == IID_vector_reduce_and { acc = ap_and(acc, x); }
        else if id == IID_vector_reduce_or { acc = ap_or(acc, x); }
        else if id == IID_vector_reduce_xor { acc = ap_xor(acc, x); }
        else if id == IID_vector_reduce_smin { acc = ap_smin(acc, x); }
        else if id == IID_vector_reduce_smax { acc = ap_smax(acc, x); }
        else if id == IID_vector_reduce_umin { acc = ap_umin(acc, x); }
        else if id == IID_vector_reduce_umax { acc = ap_umax(acc, x); }
    }
    return ap_to_cint(et, acc);
}

// ---------------------------------------------------------------------------------------------
// Floating-point calls (ConstantFoldScalarCall1/2/3, ConstantFoldLibCall2, ConstantFoldStructCall):
// rounding, scalbn, fma and fptoi.sat are exact (fpu.goose); the transcendental functions call the host
// libm like LLVM does (hostmath.goose).

fn cf_ty_is_hfd(ty: i32) -> bool { let k = ty_kind(ty); k == TK_HALF || k == TK_FLOAT || k == TK_DOUBLE }
fn cf_fp_is_finite(c: i32) -> bool { let p = fp_decompose(fp_kind_ty(vals[c].ty), cint_lo(c), cint_hi(c)); p.cat != FC_NAN && p.cat != FC_INF }
fn cf_fp_parts(c: i32) -> FpParts { fp_decompose(fp_kind_ty(vals[c].ty), cint_lo(c), cint_hi(c)) }
// APFloat::isExactlyValue(1.0) (U.isOne())
fn cf_fp_is_one(c: i32) -> bool {
    let k = fp_kind_ty(vals[c].ty);
    let olo, ohi = fp_from_f64(k, 1.0);
    return cint_lo(c) == olo && cint_hi(c) == ohi;
}
// convertToDouble (exact for half/float/double)
fn cf_fp_to_double_bits(c: i32) -> u64 {
    let k = fp_kind_ty(vals[c].ty);
    if k == TK_DOUBLE { return cint_lo(c); }
    let lo, hi = fp_convert(k, TK_DOUBLE, cint_lo(c), cint_hi(c));
    return lo;
}
// GetConstantFoldFPValue(V, Ty)
fn cf_fp_from_double_bits(ty: i32, d: u64) -> i32 {
    let k = fp_kind_ty(ty);
    if k == TK_DOUBLE { return c_fp(ty, d, 0); }
    let lo, hi = fp_convert(TK_DOUBLE, k, d, 0);
    return c_fp(ty, lo, hi);
}
// ConstantFoldFP(NativeFP, V, Ty) with the IEEE denormal mode
fn cf_host1(hid: i64, a: i32, ty: i32) -> i32 {
    let r, ok = hm_call1(hid, cf_fp_to_double_bits(a));
    if !ok { return -1; }
    return cf_fp_from_double_bits(ty, r);
}
// ConstantFoldBinaryFP(NativeFP, V, W, Ty)
fn cf_host2_bits(hid: i64, x: u64, y: u64, ty: i32) -> i32 {
    let r, ok = hm_call2(hid, x, y);
    if !ok { return -1; }
    return cf_fp_from_double_bits(ty, r);
}
fn cf_host2(hid: i64, a: i32, b: i32, ty: i32) -> i32 { cf_host2_bits(hid, cf_fp_to_double_bits(a), cf_fp_to_double_bits(b), ty) }
fn cf_round_integral(a: i32, ty: i32, mode: i64) -> i32 {
    let lo, hi = fp_round_to_integral(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), mode);
    return c_fp(ty, lo, hi);
}
fn cf_fp_inf(ty: i32, neg: bool) -> i32 { let lo, hi = fp_encode(fp_kind_ty(ty), neg, 0, 0, 0, true); return c_fp(ty, lo, hi); }
fn cf_fp_zero(ty: i32, neg: bool) -> i32 { let lo, hi = fp_encode(fp_kind_ty(ty), neg, 0, 0, 0, false); return c_fp(ty, lo, hi); }
// ilogb(APFloat) of a finite non-zero value: the unbiased exponent of the leading bit
fn cf_fp_ilogb(p: FpParts, kind: i64) -> i64 {
    let f = fp_fmt(kind);
    var ab: i64 = 0;
    if p.sig1 != 0 { ab = 128 - clz(p.sig1); } else { ab = 64 - clz(p.sig0); }
    return p.exponent - (f.p - 1) + (ab - 1);
}

// convertToInteger(rmTowardZero) with saturation (fptoui.sat / fptosi.sat): NaN -> 0
fn cf_fp_to_int_sat(a: i32, ty: i32, signed: bool) -> i32 {
    let w = ty_bits(ty_scalar(ty));
    let p = cf_fp_parts(a);
    if p.cat == FC_NAN { return ap_to_cint(ty, ap_zero(w)); }
    if p.cat == FC_INF {
        if signed { return ap_to_cint(ty, if p.neg { ap_smin_val(w) } else { ap_smax_val(w) }); }
        return ap_to_cint(ty, if p.neg { ap_zero(w) } else { ap_ones(w) });
    }
    var mag: u32[>..<] = [];
    let neg = fp_trunc_magnitude(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), mag);
    let ab = bn_active_bits(mag);
    if !signed {
        if neg { return ap_to_cint(ty, ap_zero(w)); }
        if ab > w { return ap_to_cint(ty, ap_ones(w)); }
    } else {
        if neg {
            // -mag >= -2^(w-1)
            if ab > w || (ab == w && bn_ctz(mag) != w - 1) { return ap_to_cint(ty, ap_smin_val(w)); }
        } else if ab > w - 1 { return ap_to_cint(ty, ap_smax_val(w)); }
    }
    var ws: u64[>..] = [];
    for k in (ab + 63) / 64 { ws.push(bn_word(mag, k)); }
    let m = ap_from_words(w, ws);
    return ap_to_cint(ty, if neg { ap_neg(m) } else { m });
}

// ConstantFoldScalarCall1 for a ConstantFP operand of an intrinsic
fn cf_fold_fp_unary_intrinsic(id: i32, ty: i32, a: i32) -> i32 {
    if id == IID_fptoui_sat || id == IID_fptosi_sat { return cf_fp_to_int_sat(a, ty, id == IID_fptosi_sat); }
    if id == IID_canonicalize { cfa_not_ported("constant folding of llvm.canonicalize"); }
    if ty_kind(ty) == TK_FP128 && id == IID_log { cfa_not_ported("constant folding of fp128 log (logf128)"); }
    if !cf_ty_is_hfd(ty) && !ty_is_int(ty) { return -1; }
    if id == IID_nearbyint || id == IID_rint || id == IID_roundeven { return cf_round_integral(a, ty, FRM_NEAREST_EVEN); }
    if id == IID_round { return cf_round_integral(a, ty, FRM_NEAREST_AWAY); }
    if id == IID_ceil { return cf_round_integral(a, ty, FRM_UP); }
    if id == IID_floor { return cf_round_integral(a, ty, FRM_DOWN); }
    if id == IID_trunc { return cf_round_integral(a, ty, FRM_ZERO); }
    if id == IID_fabs {
        let lo, hi = fp_with_sign(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), false);
        return c_fp(ty, lo, hi);
    }
    if is_constrained_fp_iid(id) { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
    let nm = intr_name(id as i64);
    if starts_with(nm, "llvm.nvvm.") || starts_with(nm, "llvm.amdgcn.") || starts_with(nm, "llvm.wasm.") {
        cfa_not_ported(str("constant folding of ", nm));
    }
    if !cf_fp_is_finite(a) { return -1; }
    let p = cf_fp_parts(a);
    if id == IID_log || id == IID_log2 || id == IID_log10 {
        if p.cat == FC_ZERO { return cf_fp_inf(ty, true); }
        if p.neg { return c_fp_nan_ty(ty); }
        if cf_fp_is_one(a) { return cf_fp_zero(ty, false); }
        return cf_host1(if id == IID_log { HM1_LOG } else if id == IID_log2 { HM1_LOG2 } else { HM1_LOG10 }, a, ty);
    }
    if id == IID_exp { return cf_host1(HM1_EXP, a, ty); }
    if id == IID_exp2 { return cf_host2_bits(HM2_POW, binary::bits_of_f64(2.0), cf_fp_to_double_bits(a), ty); }
    if id == IID_exp10 { return cf_host2_bits(HM2_POW, binary::bits_of_f64(10.0), cf_fp_to_double_bits(a), ty); }
    if id == IID_sin { return cf_host1(HM1_SIN, a, ty); }
    if id == IID_cos { return cf_host1(HM1_COS, a, ty); }
    if id == IID_sinh { return cf_host1(HM1_SINH, a, ty); }
    if id == IID_cosh { return cf_host1(HM1_COSH, a, ty); }
    if id == IID_atan {
        if p.cat == FC_ZERO { return c_fp(ty, cint_lo(a), cint_hi(a)); }
        return cf_host1(HM1_ATAN, a, ty);
    }
    if id == IID_sqrt { return cf_host1(HM1_SQRT, a, ty); }
    return -1;
}

// evaluateCompare(Op1, Op2, ConstrainedFPCmpIntrinsic) with mayFoldConstrained
fn cf_constrained_fcmp(c: i32, id: i32, a: i32, b: i32, ty: i32) -> i32 {
    // getPredicate: the metadata string in argument 2
    var p: i64 = -1;
    if cb_nargs(c) >= 3 {
        let m = cb_arg(c, 2);
        if vals[m].kind == VK_MDVAL && mds[vals[m].sub].kind == MK_STRING { p = cf_fcmp_pred_name(sbytes(mds[vals[m].sub].extra)); }
    }
    if p < 0 { cfa_not_ported("constrained fcmp with an invalid predicate"); }
    let pa = cfp_parts(a);
    let pb = cfp_parts(b);
    var invalid = false;
    if id == IID_experimental_constrained_fcmps {
        if pa.cat == FC_NAN || pb.cat == FC_NAN { invalid = true; }
    } else {
        if (pa.cat == FC_NAN && cfp_is_signaling(a)) || (pb.cat == FC_NAN && cfp_is_signaling(b)) { invalid = true; }
    }
    let kind = cfp_kind(a);
    let r = fp_fcmp(kind, p, cint_lo(a), cint_hi(a), cint_lo(b), cint_hi(b));
    if invalid {
        // mayFoldConstrained: no rounding argument (not Dynamic); fold unless the exception behaviour is
        // strict or absent
        let n = cb_nargs(c);
        var eb: i64 = -1;
        if n >= 4 {
            let m = cb_arg(c, 3);
            if vals[m].kind == VK_MDVAL && mds[vals[m].sub].kind == MK_STRING {
                let sname = sbytes(mds[vals[m].sub].extra);
                if sname == "fpexcept.ignore" { eb = 0; } else if sname == "fpexcept.maytrap" { eb = 1; } else if sname == "fpexcept.strict" { eb = 2; }
            }
        }
        if eb < 0 || eb == 2 { return -1; }
    }
    return c_int(ty_scalar(ty), if r { 1 } else { 0 });
}
fn cf_fcmp_pred_name(s: const u8[:]) -> i64 {
    let names: const u8[:][] = ["false", "oeq", "ogt", "oge", "olt", "ole", "one", "ord", "uno", "ueq", "ugt", "uge", "ult", "ule", "une", "true"];
    for x, i in names { if x == s { return i as i64; } }
    return -1;
}
// ConstantFoldScalarCall1 / ConstantFoldLibCall2 for library functions (TLI names)
recursive fn cf_fold_libcall(c: i32, ty: i32, mark: i64, n: i64) -> i32 {
    let f = called_function(c);
    if f < 0 || vals[f].name < 0 { return -1; }
    var nm = sbytes(vals[f].name);
    if nm.len > 0 && nm[0] == 1 { nm = nm[1..]; }
    let lf = tli_lookup_name(nm);
    if lf < 0 { return -1; }
    if n == 1 {
        let a = is_ops[mark];
        if vals[a].kind != VK_CFP || ty_is_vector(vals[a].ty) { return -1; }
        if ty_kind(ty) == TK_FP128 && lf == LF_logl { cfa_not_ported("constant folding of fp128 logl (logf128)"); }
        if !cf_ty_is_hfd(ty) && !ty_is_int(ty) { return -1; }
        if !cf_fp_is_finite(a) { return -1; }
        let p = cf_fp_parts(a);
        let has = tli_has(lf);
        if lf == LF_acos || lf == LF_acosf || lf == LF_acos_finite || lf == LF_acosf_finite { if has { return cf_host1(HM1_ACOS, a, ty); } return -1; }
        if lf == LF_asin || lf == LF_asinf || lf == LF_asin_finite || lf == LF_asinf_finite { if has { return cf_host1(HM1_ASIN, a, ty); } return -1; }
        if lf == LF_atan || lf == LF_atanf {
            if p.cat == FC_ZERO { return c_fp(ty, cint_lo(a), cint_hi(a)); }
            if has { return cf_host1(HM1_ATAN, a, ty); }
            return -1;
        }
        if lf == LF_ceil || lf == LF_ceilf { if has { return cf_round_integral(a, ty, FRM_UP); } return -1; }
        if lf == LF_cos || lf == LF_cosf { if has { return cf_host1(HM1_COS, a, ty); } return -1; }
        if lf == LF_cosh || lf == LF_coshf || lf == LF_cosh_finite || lf == LF_coshf_finite { if has { return cf_host1(HM1_COSH, a, ty); } return -1; }
        if lf == LF_exp || lf == LF_expf || lf == LF_exp_finite || lf == LF_expf_finite { if has { return cf_host1(HM1_EXP, a, ty); } return -1; }
        if lf == LF_exp2 || lf == LF_exp2f || lf == LF_exp2_finite || lf == LF_exp2f_finite {
            if has { return cf_host2_bits(HM2_POW, binary::bits_of_f64(2.0), cf_fp_to_double_bits(a), ty); }
            return -1;
        }
        if lf == LF_fabs || lf == LF_fabsf {
            if has { let lo, hi = fp_with_sign(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), false); return c_fp(ty, lo, hi); }
            return -1;
        }
        if lf == LF_floor || lf == LF_floorf { if has { return cf_round_integral(a, ty, FRM_DOWN); } return -1; }
        let pos = !p.neg && p.cat != FC_ZERO;
        if lf == LF_log || lf == LF_logf || lf == LF_log_finite || lf == LF_logf_finite { if pos && has { return cf_host1(HM1_LOG, a, ty); } return -1; }
        if lf == LF_log2 || lf == LF_log2f || lf == LF_log2_finite || lf == LF_log2f_finite { if pos && has { return cf_host1(HM1_LOG2, a, ty); } return -1; }
        if lf == LF_log10 || lf == LF_log10f || lf == LF_log10_finite || lf == LF_log10f_finite { if pos && has { return cf_host1(HM1_LOG10, a, ty); } return -1; }
        if lf == LF_ilogb || lf == LF_ilogbf {
            if p.cat != FC_ZERO && has { return ap_to_cint(ty, ap_i64(cf_fp_ilogb(p, fp_kind_ty(vals[a].ty)), ty_bits(ty))); }
            return -1;
        }
        if lf == LF_logb || lf == LF_logbf { if p.cat != FC_ZERO && has { return cf_host1(HM1_LOGB, a, ty); } return -1; }
        if lf == LF_log1p || lf == LF_log1pf {
            if p.cat == FC_ZERO { return c_fp(ty, cint_lo(a), cint_hi(a)); }
            // APF > -1.0
            let k = fp_kind_ty(vals[a].ty);
            let mlo, mhi = fp_from_f64(k, -1.0);
            if fp_compare(k, cint_lo(a), cint_hi(a), mlo, mhi) == 2 && has { return cf_host1(HM1_LOG1P, a, ty); }
            return -1;
        }
        if lf == LF_logl { return -1; }
        if lf == LF_erf || lf == LF_erff { if has { return cf_host1(HM1_ERF, a, ty); } return -1; }
        if lf == LF_nearbyint || lf == LF_nearbyintf || lf == LF_rint || lf == LF_rintf || lf == LF_roundeven || lf == LF_roundevenf {
            if has { return cf_round_integral(a, ty, FRM_NEAREST_EVEN); }
            return -1;
        }
        if lf == LF_round || lf == LF_roundf { if has { return cf_round_integral(a, ty, FRM_NEAREST_AWAY); } return -1; }
        if lf == LF_sin || lf == LF_sinf { if has { return cf_host1(HM1_SIN, a, ty); } return -1; }
        if lf == LF_sinh || lf == LF_sinhf || lf == LF_sinh_finite || lf == LF_sinhf_finite { if has { return cf_host1(HM1_SINH, a, ty); } return -1; }
        if lf == LF_sqrt || lf == LF_sqrtf { if !p.neg && has { return cf_host1(HM1_SQRT, a, ty); } return -1; }
        if lf == LF_tan || lf == LF_tanf { if has { return cf_host1(HM1_TAN, a, ty); } return -1; }
        if lf == LF_tanh || lf == LF_tanhf { if has { return cf_host1(HM1_TANH, a, ty); } return -1; }
        if lf == LF_trunc || lf == LF_truncf { if has { return cf_round_integral(a, ty, FRM_ZERO); } return -1; }
        return -1;
    }
    if n == 2 {
        // ConstantFoldLibCall2
        let a = is_ops[mark];
        let b = is_ops[mark + 1];
        if vals[a].kind != VK_CFP || ty_is_vector(vals[a].ty) || vals[b].kind != VK_CFP || ty_is_vector(vals[b].ty) { return -1; }
        let has = tli_has(lf);
        if lf == LF_pow || lf == LF_powf || lf == LF_pow_finite || lf == LF_powf_finite { if has { return cf_host2(HM2_POW, a, b, ty); } return -1; }
        if lf == LF_fmod || lf == LF_fmodf {
            if !has { return -1; }
            // APFloat::mod returns opOK except for signaling NaNs, x = inf, y = 0
            let pa = cf_fp_parts(a);
            let pb = cf_fp_parts(b);
            let k = fp_kind_ty(vals[a].ty);
            if (pa.cat == FC_NAN && cfp_is_signaling(a)) || (pb.cat == FC_NAN && cfp_is_signaling(b)) { return -1; }
            if pa.cat != FC_NAN && pb.cat != FC_NAN && (pa.cat == FC_INF || pb.cat == FC_ZERO) { return -1; }
            let lo, hi = fp_arith(k, FOP_MOD, cint_lo(a), cint_hi(a), cint_lo(b), cint_hi(b));
            return c_fp(ty, lo, hi);
        }
        if lf == LF_remainder || lf == LF_remainderf { if has { cfa_not_ported("constant folding of remainder (APFloat::remainder)"); } return -1; }
        if lf == LF_atan2 || lf == LF_atan2f {
            if cf_fp_parts(a).cat == FC_ZERO && cf_fp_parts(b).cat == FC_ZERO { return -1; }
            if has { return cf_host2(HM2_ATAN2, a, b, ty); }
            return -1;
        }
        if lf == LF_atan2_finite || lf == LF_atan2f_finite { if has { return cf_host2(HM2_ATAN2, a, b, ty); } return -1; }
        if lf == LF_nextafter || lf == LF_nextafterf || lf == LF_nexttoward || lf == LF_nexttowardf {
            if has { cfa_not_ported("constant folding of nextafter/nexttoward"); }
            return -1;
        }
        return -1;
    }
    return -1;
}

// ConstantFoldIntrinsicCall2 for two ConstantFP operands or (ConstantFP, ConstantInt), after the min/max family
fn cf_fold_fp_binary_rest(id: i32, ty: i32, a: i32, b: i32) -> i32 {
    if vals[a].kind != VK_CFP || ty_is_vector(vals[a].ty) { return -1; }
    if vals[b].kind == VK_CFP && !ty_is_vector(vals[b].ty) {
        if vals[b].ty != vals[a].ty { return -1; }
        if is_constrained_fp_iid(id) { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
        let nm = intr_name(id as i64);
        if starts_with(nm, "llvm.nvvm.") || starts_with(nm, "llvm.amdgcn.") { cfa_not_ported(str("constant folding of ", nm)); }
        if !cf_ty_is_hfd(ty) { return -1; }
        if id == IID_pow { return cf_host2(HM2_POW, a, b, ty); }
        return -1;
    }
    if vals[b].kind == VK_CINT && !ty_is_vector(vals[b].ty) {
        let k = fp_kind_ty(vals[a].ty);
        if id == IID_ldexp {
            var e = ci_ap(b);
            e = if (e.w as i64) < 32 { ap_sext(e, 32) } else { ap_trunc_ssat(e, 32) };
            let lo, hi = fp_scalbn(k, cint_lo(a), cint_hi(a), ap_sext64(e));
            return c_fp(ty, lo, hi);
        }
        if id == IID_is_fpclass {
            let mask = ap_zext64(ci_ap(b));
            let r = (mask & cfp_class(a)) != 0;
            return c_int_ty(ty, if r { 1 } else { 0 });
        }
        if id == IID_powi {
            // (float)std::pow(Op1V.convertToFloat(), Exp) for half/float, std::pow(double, int) for double
            let ex = ap_sext64(ap_trunc(ci_ap(b), 32)) as f64;
            let eb = binary::bits_of_f64(ex);
            if ty_kind(ty) == TK_HALF || ty_kind(ty) == TK_FLOAT {
                let r = hm_pow_noexc(cf_fp_to_double_bits(a), eb);
                let flo, fhi = fp_convert(TK_DOUBLE, TK_FLOAT, r, 0);
                if ty_kind(ty) == TK_FLOAT { return c_fp(ty, flo, fhi); }
                let hlo, hhi = fp_convert(TK_FLOAT, TK_HALF, flo, fhi);
                return c_fp(ty, hlo, hhi);
            }
            if ty_kind(ty) == TK_DOUBLE { return c_fp(ty, hm_pow_noexc(cint_lo(a), eb), 0); }
            return -1;
        }
    }
    return -1;
}

// ConstantFoldStructCall for frexp and sincos
fn cf_frexp_scalar(op0: i32, ity: i32) -> i32, i32 {
    if vals[op0].kind != VK_CFP || ty_is_vector(vals[op0].ty) { return -1, -1; }
    let t = vals[op0].ty;
    let k = fp_kind_ty(t);
    let p = cf_fp_parts(op0);
    if p.cat == FC_NAN { let lo, hi = fp_make_quiet(k, cint_lo(op0), cint_hi(op0)); return c_fp(t, lo, hi), c_null(ity); }
    if p.cat == FC_INF { return op0, c_null(ity); }
    if p.cat == FC_ZERO { return op0, c_null(ity); }
    let e = cf_fp_ilogb(p, k) + 1;
    let lo, hi = fp_scalbn(k, cint_lo(op0), cint_hi(op0), -e);
    return c_fp(t, lo, hi), ap_to_cint(ity, ap_i64(e, ty_bits(ity)));
}
// ConstantFoldScalarCall(Name, sin/cos, Ty, {Op}) for one lane
fn cf_sincos_lane(id: i32, ty: i32, op0: i32) -> i32 {
    if is_undef_val(op0) { return if id == IID_cos { c_null(ty) } else { -1 }; }
    if vals[op0].kind != VK_CFP { return -1; }
    return cf_fold_fp_unary_intrinsic(id, ty, op0);
}
fn cf_fold_frexp_sincos(id: i32, sty: i32, op0: i32) -> i32 {
    let t0 = ty_field(sty, 0);
    let t1 = ty_field(sty, 1);
    let mark = is_ops.len;
    if ty_kind(t0) == TK_FVEC {
        let ne = ty_count(t0);
        for i in ne {
            let lane = agg_elem(op0, i);
            if lane < 0 { is_ops.resize(mark); return -1; }
            var r0: i32 = -1;
            var r1: i32 = -1;
            if id == IID_frexp { let x, y = cf_frexp_scalar(lane, ty_scalar(t1)); r0 = x; r1 = y; }
            else { r0 = cf_sincos_lane(IID_sin, ty_scalar(t0), lane); r1 = cf_sincos_lane(IID_cos, ty_scalar(t0), lane); }
            if r0 < 0 || r1 < 0 { is_ops.resize(mark); return -1; }
            is_ops.push(r0);
            is_ops.push(r1);
        }
        let m2 = is_ops.len;
        for i in ne { is_ops.push(is_ops[mark + 2 * i]); }
        let v0 = c_aggregate(t0, is_ops[m2..m2 + ne]);
        is_ops.resize(m2);
        for i in ne { is_ops.push(is_ops[mark + 2 * i + 1]); }
        let v1 = c_aggregate(t1, is_ops[m2..m2 + ne]);
        is_ops.resize(mark);
        let r = c_aggregate(sty, [v0, v1]);
        return r;
    }
    if ty_kind(t0) == TK_SVEC { cfa_not_ported("constant folding of scalable frexp/sincos"); }
    var r0: i32 = -1;
    var r1: i32 = -1;
    if id == IID_frexp { let x, y = cf_frexp_scalar(op0, t1); r0 = x; r1 = y; }
    else {
        if !ty_is_fp(t0) { return -1; }
        r0 = cf_sincos_lane(IID_sin, t0, op0);
        r1 = cf_sincos_lane(IID_cos, t0, op0);
    }
    if r0 < 0 || r1 < 0 { return -1; }
    return c_aggregate(sty, [r0, r1]);
}

// fma / fmuladd (ConstantFoldScalarCall3): APFloat::fusedMultiplyAdd, rmNearestTiesToEven
fn cf_fold_fma(id: i32, ty: i32, a: i32, b: i32, c3: i32) -> i32 {
    if vals[a].kind != VK_CFP || vals[b].kind != VK_CFP || vals[c3].kind != VK_CFP { return -1; }
    if ty_is_vector(vals[a].ty) || ty_is_vector(vals[b].ty) || ty_is_vector(vals[c3].ty) { return -1; }
    let k = fp_kind_ty(vals[a].ty);
    let lo, hi = fp_fma(k, cint_lo(a), cint_hi(a), cint_lo(b), cint_hi(b), cint_lo(c3), cint_hi(c3));
    return c_fp(ty, lo, hi);
}
