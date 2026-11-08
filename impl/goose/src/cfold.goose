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
recursive fn cf_fold_fp_inst_operands(o: i64, a: i32, b: i32, cxt: i32, allow_nondet: bool) -> i32 {
    cf_check_denormal_mode(cxt);
    if !allow_nondet && cxt >= 0 && is_fp_math_operator(cxt) {
        let f = insts[inst_of(cxt)].fmf;
        if (f & (FMF_NSZ | FMF_REASSOC | FMF_CONTRACT | FMF_ARCP)) != 0 { return -1; }
    }
    let c = cf_fold_binop_operands(o, a, b);
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

// ConstantFoldCastOperand
recursive fn cf_fold_cast_operand(o: i64, c: i32, ty: i32) -> i32 {
    if is_cexpr(c) && is_cast_op(cexpr_op(c)) {
        let nop = eliminable_cast_pair(cexpr_op(c), o, vals[op(c, 0)].ty, vals[c].ty, ty);
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

// FoldBitCast(C, DestTy, DL)
recursive fn cf_fold_bitcast_dl(c: i32, ty: i32) -> i32 {
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
        if ty_is_int(ty_scalar(ty)) || ty_is_fp(ty_scalar(ty)) { return c_all_ones(ty); }
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
        if ty_kind(st) == TK_SVEC || ty_kind(dty) == TK_SVEC { cfa_not_ported("loads through bitcasts of scalable vectors"); }
        let dsz = dl_size_bits(dty);
        let ssz = dl_size_bits(st);
        if ssz < dsz { return -1; }
        let u = cf_fold_load_from_uniform(c, dty);
        if u >= 0 { return u; }
        if ssz == dsz {
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
        if vals[b].kind == VK_CINT && !ty_is_vector(vals[b].ty) { base_int = ci_val(b) & wmask64(pbits); }
    }
    if (is_null_value(ptr) || base_int != 0) && !must_not_introduce_inttoptr(vals[ptr].ty) {
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
fn must_not_introduce_inttoptr(t: i32) -> bool {
    // non-integral pointer address spaces (ni:) are not modelled by datalayout.goose
    let d = modules[cur_module].datalayout;
    if d >= 0 && (find(sbytes(d), "ni:") >= 0 || find(sbytes(d), "pu") >= 0 || find(sbytes(d), "pe") >= 0) { cfa_not_ported("non-integral / unstable / external-state address spaces"); }
    return false;
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
        // FlushFPConstant(Op, I = nullptr): getInstrDenormalMode gives Dynamic, so a denormal input stops the fold
        if cxt < 0 {
            if !cf_flush_fp_dynamic_ok(a) || !cf_flush_fp_dynamic_ok(b) { return -1; }
        } else {
            cf_check_denormal_mode(cxt);
        }
    }
    return cf_compare(p, a, b);
}

// FlushFPConstant(Operand, Inst = nullptr, IsOutput = false) != nullptr (the result equals Operand otherwise)
fn cf_flush_fp_dynamic_ok(c: i32) -> bool {
    let k = vals[c].kind;
    let ty = vals[c].ty;
    if k == VK_CFP && !ty_is_vector(ty) { return !fp_is_denormal(c); }
    if k == VK_AGGZERO || k == VK_UNDEF || k == VK_POISON { return true; }
    if ty_is_vector(ty) {
        let s = c_splat_value(c);
        if s >= 0 && vals[s].kind == VK_CFP { return !fp_is_denormal(s); }
        if k == VK_CFP { return !fp_is_denormal(splat_value(c, false)); }
    }
    if k == VK_CEXPR { return true; }
    if k == VK_CVECTOR {
        for i in nops(c) {
            let e = op(c, i);
            if vals[e].kind == VK_UNDEF || vals[e].kind == VK_POISON { continue; }
            if vals[e].kind != VK_CFP || fp_is_denormal(e) { return false; }
        }
        return true;
    }
    if k == VK_CDVECTOR {
        for i in nops(c) { if fp_is_denormal(op(c, i)) { return false; } }
        return true;
    }
    return false;
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
fn is_x86_cvt_iid(id: i32) -> bool {
    let nm = intr_name(id as i64);
    return starts_with(nm, "llvm.x86.sse.cvt") || starts_with(nm, "llvm.x86.sse2.cvt") || starts_with(nm, "llvm.x86.avx512.vcvt") ||
           starts_with(nm, "llvm.x86.avx512.cvtt");
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
        if id == IID_frexp || id == IID_sincos { cfa_not_ported("constant folding of frexp/sincos"); }
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
    if id == 0 { cfa_not_ported(str("constant folding of the library call ", sbytes(vals[called_function(c)].name))); }
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
            if is_x86_cvt_iid(id) { cfa_not_ported("x86 SSE conversion folding"); }
        }
        return -1;
    }
    if n == 2 {
        let a = is_ops[mark];
        let b = is_ops[mark + 1];
        if ty_is_fp(ty) && is_minmax_fp_iid(id) {
            if is_undef_val(a) { return b; }
            if is_undef_val(b) { return a; }
        }
        if ty_is_fp(ty) && vals[a].kind == VK_CFP && vals[b].kind == VK_CFP && !ty_is_vector(vals[a].ty) &&
           vals[a].ty == vals[b].ty && !is_constrained_fp_iid(id) {
            let r = cf_fp_binary_intrinsic(id, a, b);
            if r >= 0 { return r; }
        }
        if ty_is_fp(ty) || is_fp_or_fp_vec(vals[a].ty) {
            if id == IID_powi || id == IID_ldexp || id == IID_is_fpclass || id == IID_copysign || is_minmax_fp_iid(id) || id == IID_pow || id == IID_atan2 {
                cfa_not_ported(str("constant folding of ", intr_name(id as i64)));
            }
            if vals[a].kind == VK_CFP || vals[b].kind == VK_CFP || is_undef_val(a) || is_undef_val(b) {
                cfa_not_ported(str("constant folding of ", intr_name(id as i64)));
            }
            return -1;
        }
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
        if is_x86_cvt_iid(id) || id == IID_experimental_cttz_elts || id == IID_get_active_lane_mask { cfa_not_ported(str("constant folding of ", intr_name(id as i64))); }
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

// ConstantFoldScalarCall1 for a ConstantFP operand (only the bit-exact operations are ported)
fn cf_fold_fp_unary_intrinsic(id: i32, ty: i32, a: i32) -> i32 {
    let k = fp_kind_ty(vals[a].ty);
    if id == IID_fabs {
        let lo, hi = fp_with_sign(k, cint_lo(a), cint_hi(a), false);
        return c_fp(ty, lo, hi);
    }
    cfa_not_ported(str("constant folding of ", intr_name(id as i64)));
    return -1;
}
