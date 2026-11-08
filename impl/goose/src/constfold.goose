// Constant folding at constant creation. Port of llvm/lib/IR/ConstantFold.cpp (ConstantFoldCastInstruction,
// FoldBitCast, ConstantFoldBinaryInstruction, ConstantFoldUnaryInstruction, ConstantFoldExtractElement/
// InsertElement/ShuffleVector/ExtractValue/InsertValueInstruction, ConstantFoldCompareInstruction,
// ConstantFoldGetElementPtr) and of the ConstantExpr::get* entry points of llvm/lib/IR/Constants.cpp that
// call them (plus CastInst::isEliminableCastPair from Instructions.cpp, Constant::getSplatValue,
// getAggregateElement, ConstantVector::getSplat).
//
// cf_* return -1 when LLVM's fold returns nullptr; ce_* always return a constant (folded or a new
// ConstantExpr), like ConstantExpr::get*. Integers of any width (apint.goose).
import std;
import ir;
import apfloat;
import bignum;
import fpu;
import apint;

// ---------------------------------------------------------------------------------------------
// Constant helpers

fn cf_is_poison(v: i32) -> bool { vals[v].kind == VK_POISON }
// isa<UndefValue> (poison included)
fn cf_is_undef(v: i32) -> bool { let k = vals[v].kind; k == VK_UNDEF || k == VK_POISON }
fn cf_is_cint(v: i32) -> bool { vals[v].kind == VK_CINT && !ty_is_vector(vals[v].ty) }
fn cf_is_cfp(v: i32) -> bool { vals[v].kind == VK_CFP && !ty_is_vector(vals[v].ty) }
fn cf_is_cexpr(v: i32) -> bool { vals[v].kind == VK_CEXPR }
fn cexpr_op(v: i32) -> i64 { csts[vals[v].sub].op as i64 }

// Constant::getAllOnesValue
recursive fn c_all_ones(ty: i32) -> i32 {
    let st = ty_scalar(ty);
    var e: i32 = -1;
    if ty_is_int(st) { e = ap_to_cint(st, ap_ones(ty_bits(st))); }
    else if ty_is_fp(st) {
        let f = fp_fmt(types[st].kind as i64);
        if f.total <= 64 { e = c_fp(st, if f.total == 64 { 0xFFFFFFFFFFFFFFFF } else { ((1 as u64) << f.total) - 1 }, 0); }
        else if types[st].kind == TK_X86_FP80 { e = c_fp(st, 0xFFFFFFFFFFFFFFFF, 0xFFFF); }
        else { e = c_fp(st, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF); }
    } else { fatal("getAllOnesValue of an unsupported type"); }
    if ty_is_vector(ty) { return c_splat(ty, e); }
    return e;
}

// Constant::isAllOnesValue
recursive fn is_all_ones_value(v: i32) -> bool {
    let k = vals[v].kind;
    if k == VK_CINT { return ap_is_all_ones(ap_from_cint(v)); }
    if k == VK_CFP {
        let st = ty_scalar(vals[v].ty);
        let f = fp_fmt(types[st].kind as i64);
        let c = csts[vals[v].sub];
        if f.total < 64 { return c.lo == ((1 as u64) << f.total) - 1; }
        if f.total == 64 { return c.lo == 0xFFFFFFFFFFFFFFFF; }
        if types[st].kind == TK_X86_FP80 { return c.lo == 0xFFFFFFFFFFFFFFFF && c.hi == 0xFFFF; }
        return c.lo == 0xFFFFFFFFFFFFFFFF && c.hi == 0xFFFFFFFFFFFFFFFF;
    }
    if ty_is_vector(vals[v].ty) {
        let s = c_splat_value(v);
        if s >= 0 { return is_all_ones_value(s); }
    }
    return false;
}

// Constant::getSplatValue (AllowPoison = false); -1 = not a splat
fn c_splat_value(v: i32) -> i32 {
    let ty = vals[v].ty;
    let k = vals[v].kind;
    let et = types[ty].a;
    if k == VK_POISON { return c_poison(et); }
    if k == VK_AGGZERO { return c_null(et); }
    if k == VK_CNULL { return c_null(et); }
    if k == VK_CINT && ty_is_vector(ty) { return ap_to_cint(et, ap_from_cint(v)); }
    if k == VK_CFP && ty_is_vector(ty) { return c_fp(et, cint_lo(v), cint_hi(v)); }
    if k == VK_CDVECTOR || k == VK_CVECTOR {
        let n = vals[v].nops as i64;
        if n == 0 { return -1; }
        let f = op(v, 0);
        for i in 1..n { if op(v, i) != f { return -1; } }
        return f;
    }
    if k == VK_CEXPR && cexpr_op(v) == OP_SHUFFLEVECTOR && cf_is_undef(op(v, 1)) {
        let ie = op(v, 0);
        if vals[ie].kind == VK_CEXPR && cexpr_op(ie) == OP_INSERTELEMENT && cf_is_undef(op(ie, 0)) {
            let idx = op(ie, 2);
            let c = csts[vals[v].sub];
            var allz = true;
            for i in c.naux { if ints[c.aux + i] != 0 { allz = false; } }
            if vals[idx].kind == VK_CINT && cint_is_zero(idx) && allz { return op(ie, 1); }
        }
    }
    return -1;
}

// Constant::getAggregateElement(k); -1 = none
fn c_aggregate_element(v: i32, k: i64) -> i32 {
    let ty = vals[v].ty;
    let kind = vals[v].kind;
    let n = types[ty].cnt;
    if kind == VK_CARRAY || kind == VK_CSTRUCT || kind == VK_CVECTOR || kind == VK_CDARRAY || kind == VK_CDVECTOR {
        if k < vals[v].nops as i64 { return op(v, k); }
        return -1;
    }
    let et = ty_index(ty, k);
    if kind == VK_AGGZERO { if k < n { return c_null(ty_index(ty, k)); } return -1; }
    if kind == VK_CNULL && ty_is_vector(ty) { if k < n { return c_null(et); } return -1; }
    if types[ty].kind == TK_SVEC { return -1; }
    if kind == VK_POISON { if k < n { return c_poison(et); } return -1; }
    if kind == VK_UNDEF { if k < n { return c_undef(et); } return -1; }
    return -1;
}

// ConstantVector::getSplat (element count and scalability from vty)
recursive fn c_splat(vty: i32, v: i32) -> i32 {
    let n = types[vty].cnt;
    let sc = types[vty].kind == TK_SVEC;
    let k = vals[v].kind;
    if k == VK_CNULL { return c_simple(VK_CNULL, ty_vector(vals[v].ty, n, sc)); }
    let ty = ty_vector(vals[v].ty, n, sc);
    if !sc {
        let mark = cf_stack.len;
        for i in n { cf_stack.push(v); }
        let r = c_aggregate(ty, cf_stack[mark..]);
        cf_stack.resize(mark);
        return r;
    }
    if is_null_value(v) { return c_simple(VK_AGGZERO, ty); }
    if k == VK_POISON { return c_poison(ty); }
    if k == VK_UNDEF { return c_undef(ty); }
    let pv = c_poison(ty);
    let ins = ce_insertelement(pv, v, c_int(T_I64, 0));
    let mark = cf_stack.len;
    for i in n { cf_stack.push(0); }
    let r = ce_shufflevector(ins, pv, cf_stack[mark..]);
    cf_stack.resize(mark);
    return r;
}

var cf_stack: i32[>..<];

// ---------------------------------------------------------------------------------------------
// Casts

fn is_desirable_cast_op(o: i64) -> bool { o == OP_TRUNC || o == OP_PTRTOADDR || o == OP_PTRTOINT || o == OP_INTTOPTR || o == OP_BITCAST || o == OP_ADDRSPACECAST }

// CastInst::isEliminableCastPair with DL = nullptr
let CAST_RESULTS: u8[] = [
    1, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,
    8, 1, 9,99,99, 2,17,99,99,99,99, 2, 3, 0,
    8, 0, 1,99,99, 0, 2,99,99,99,99, 0, 3, 0,
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,
    99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,
    99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,
    99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,
    99,99,99, 2, 2,99,99, 8, 2,99,99,99, 4, 0,
    1, 0, 0,99,99, 0, 0,99,99,99,99, 7, 3, 0,
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,
    99,99,99,99,99,99,99,99,99,11,11,99,15, 0,
    5, 5, 5, 0, 0, 5, 5, 0, 0,16,16, 5, 1,14,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,13,12];

fn eliminable_cast_pair(first: i64, second: i64, src: i32, mid: i32, dst: i32) -> i64 {
    let fb = first == OP_BITCAST;
    let sb = second == OP_BITCAST;
    if (fb && ty_is_vector(src) != ty_is_vector(mid)) || (sb && ty_is_vector(mid) != ty_is_vector(dst)) {
        if !(fb && sb) { return 0; }
    }
    let c = CAST_RESULTS[(first - OP_TRUNC) * 14 + (second - OP_TRUNC)] as i64;
    if c == 0 { return 0; }
    if c == 1 { return first; }
    if c == 2 { return second; }
    if c == 3 { if !ty_is_vector(src) && ty_is_int(dst) { return first; } return 0; }
    if c == 4 { if dst == mid { return first; } return 0; }
    if c == 5 { if ty_is_int(src) { return second; } return 0; }
    if c == 7 { return 0; }   // needs a DataLayout
    if c == 8 {
        let ss = cf_scalar_size(src);
        let ds = cf_scalar_size(dst);
        if src == dst { return OP_BITCAST; }
        if ss < ds { return first; }
        if ss > ds { return second; }
        return 0;
    }
    if c == 9 { return OP_ZEXT; }
    if c == 11 { return 0; }  // needs a DataLayout
    if c == 12 { if types[ty_scalar(src)].n != types[ty_scalar(dst)].n { return OP_ADDRSPACECAST; } return OP_BITCAST; }
    if c == 13 { if types[ty_scalar(dst)].kind != TK_PTR { return 0; } return first; }
    if c == 14 { if types[ty_scalar(src)].kind != TK_PTR { return 0; } return OP_ADDRSPACECAST; }
    if c == 15 { return first; }
    if c == 16 { return second; }
    if c == 17 { return OP_UITOFP; }
    fatal("invalid cast combination");
    return 0;
}

fn cf_scalar_size(t: i32) -> i64 {
    let s = ty_scalar(t);
    let k = types[s].kind;
    if k == TK_INT { return ty_bits(s); }
    if k == TK_HALF || k == TK_BFLOAT { return 16; }
    if k == TK_FLOAT { return 32; }
    if k == TK_DOUBLE { return 64; }
    if k == TK_X86_FP80 { return 80; }
    if k == TK_FP128 || k == TK_PPC_FP128 { return 128; }
    return 0;
}

recursive fn fold_maybe_undesirable_cast(opc: i64, v: i32, dty: i32) -> i32 {
    if is_desirable_cast_op(opc) { return ce_cast(opc, v, dty); }
    return cf_cast(opc, v, dty);
}

// FoldBitCast
recursive fn fold_bitcast(v: i32, dty: i32) -> i32 {
    let sty = vals[v].ty;
    if sty == dty { return v; }
    if is_all_ones_value(v) { return c_all_ones(dty); }
    let k = vals[v].kind;
    if k == VK_CINT && !ty_is_vector(sty) {
        if ty_is_vector(dty) { return ce_cast(OP_BITCAST, c_splat(ty_vector(sty, 1, false), v), dty); }
        let dst = ty_scalar(dty);
        if ty_is_fp(dst) && types[dst].kind != TK_PPC_FP128 && cf_scalar_size(dst) == cf_scalar_size(sty) {
            return c_fp(dty, cint_lo(v), cint_hi(v));
        }
        return -1;
    }
    if k == VK_CFP && !ty_is_vector(sty) {
        if !ty_is_vector(dty) && ty_is_fp(dty) { return c_fp(dty, cint_lo(v), cint_hi(v)); }
        if ty_is_vector(dty) { return ce_cast(OP_BITCAST, c_splat(ty_vector(sty, 1, false), v), dty); }
        if types[sty].kind == TK_PPC_FP128 { return -1; }
        if ty_is_int(ty_scalar(dty)) && cf_scalar_size(dty) == cf_scalar_size(sty) {
            return ap_to_cint(dty, ap_from_words(cf_scalar_size(dty), [cint_lo(v), cint_hi(v)]));
        }
        return -1;
    }
    return -1;
}

// ConstantFoldCastInstruction
recursive fn cf_cast(opc: i64, v: i32, dty: i32) -> i32 {
    if cf_is_poison(v) { return c_poison(dty); }
    if vals[v].kind == VK_UNDEF {
        if opc == OP_ZEXT || opc == OP_SEXT || opc == OP_UITOFP || opc == OP_SITOFP { return c_null(dty); }
        return c_undef(dty);
    }
    if is_null_value(v) && types[dty].kind != TK_X86_AMX && opc != OP_ADDRSPACECAST { return c_null(dty); }
    if cf_is_cexpr(v) && is_cast_op(cexpr_op(v)) {
        let nop = eliminable_cast_pair(cexpr_op(v), opc, vals[op(v, 0)].ty, vals[v].ty, dty);
        if nop != 0 { return fold_maybe_undesirable_cast(nop, op(v, 0), dty); }
    }
    let sty = vals[v].ty;
    if ty_is_vector(dty) && ty_is_vector(sty) && types[dty].cnt == types[sty].cnt && types[dty].kind == types[sty].kind {
        let det = types[dty].a;
        let sp = c_splat_value(v);
        if sp >= 0 {
            let r = fold_maybe_undesirable_cast(opc, sp, det);
            if r < 0 { return -1; }
            return c_splat(dty, r);
        }
        if types[dty].kind == TK_SVEC { return -1; }
        let mark = cf_stack.len;
        for i in types[sty].cnt {
            let e = ce_extractelement(v, c_int(T_I32, i));
            let c = fold_maybe_undesirable_cast(opc, e, det);
            if c < 0 { cf_stack.resize(mark); return -1; }
            cf_stack.push(c);
        }
        let r = c_aggregate(dty, cf_stack[mark..]);
        cf_stack.resize(mark);
        return r;
    }
    let k = vals[v].kind;
    let dst = ty_scalar(dty);
    if opc == OP_FPTRUNC || opc == OP_FPEXT {
        if k == VK_CFP {
            let lo, hi = fp_convert(types[ty_scalar(sty)].kind as i64, types[dst].kind as i64, cint_lo(v), cint_hi(v));
            return c_fp(dty, lo, hi);
        }
        return -1;
    }
    if opc == OP_FPTOUI || opc == OP_FPTOSI {
        if k == VK_CFP { return fold_fp_to_int(v, dty, opc == OP_FPTOSI); }
        return -1;
    }
    if opc == OP_UITOFP || opc == OP_SITOFP {
        if k == VK_CINT {
            let a = ap_from_cint(v);
            let neg = opc == OP_SITOFP && ap_is_neg(a);
            let m = if neg { ap_neg(a) } else { a };
            var num: u32[>..<] = [];
            var den: u32[>..<] = [];
            var mw: u64[>..] = [];
            for k in ap_nwords(m) { mw.push(ap_word(m, k)); }
            bn_from_words(num, mw);
            bn_set_u64(den, 1);
            let lo, hi = fp_round_rational(types[dst].kind as i64, neg, num, den);
            return c_fp(dty, lo, hi);
        }
        return -1;
    }
    if opc == OP_ZEXT { if k == VK_CINT { return ap_to_cint(dty, ap_zext(ap_from_cint(v), ty_bits(dst))); } return -1; }
    if opc == OP_SEXT { if k == VK_CINT { return ap_to_cint(dty, ap_sext(ap_from_cint(v), ty_bits(dst))); } return -1; }
    if opc == OP_TRUNC { if k == VK_CINT { return ap_to_cint(dty, ap_trunc(ap_from_cint(v), ty_bits(dst))); } return -1; }
    if opc == OP_BITCAST { return fold_bitcast(v, dty); }
    return -1;
}

// APFloat::convertToInteger(rmTowardZero); invalid -> poison
fn fold_fp_to_int(v: i32, dty: i32, signed: bool) -> i32 {
    let st = ty_scalar(vals[v].ty);
    let w = ty_bits(ty_scalar(dty));
    let kind = types[st].kind as i64;
    let f = fp_fmt(kind);
    let p = fp_decompose(kind, cint_lo(v), cint_hi(v));
    if p.cat == FC_NAN || p.cat == FC_INF { return c_poison(dty); }
    if p.cat == FC_ZERO { return c_null(dty); }
    // integer part = sig * 2^(exponent - (p-1)), truncated
    // the magnitude is computed in w + 130 bits: a significand has at most 113 bits, and any shift that
    // would push it past w + 1 bits overflows anyway
    let mw = w + 130;
    let sig = ap_from_words(mw, [p.sig0, p.sig1]);
    let sh = p.exponent - (f.p - 1);
    var mag = ap_zero(mw);
    if sh >= 0 {
        if sh + (f.p) > w + 1 { return c_poison(dty); }
        mag = ap_shl(sig, sh);
    } else {
        mag = ap_lshr(sig, -sh);
    }
    // range check
    let maxbits = if signed { w - 1 } else { w };
    let abits = ap_active_bits(mag);
    if p.neg && !ap_is_zero(mag) {
        if !signed { return c_poison(dty); }
        // allow -2^(w-1)
        if abits > maxbits + 1 { return c_poison(dty); }
        if abits == maxbits + 1 && ap_countr_zero(mag) != abits - 1 { return c_poison(dty); }
        return ap_to_cint(dty, ap_neg(ap_trunc(mag, w)));
    }
    if abits > maxbits { return c_poison(dty); }
    return ap_to_cint(dty, ap_trunc(mag, w));
}

// ConstantExpr::getCast
recursive fn ce_cast(opc: i64, v: i32, dty: i32) -> i32 {
    let f = cf_cast(opc, v, dty);
    if f >= 0 { return f; }
    if !is_desirable_cast_op(opc) { fatal("cast constant expression of an unsupported opcode"); }
    let mark = cf_stack.len;
    cf_stack.push(v);
    let r = c_expr(opc, dty, cf_stack[mark..], 0, 0, -1, -1);
    cf_stack.resize(mark);
    return r;
}

// ---------------------------------------------------------------------------------------------
// Binary operators

fn cf_commutative(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR || o == OP_FADD || o == OP_FMUL }
fn cf_associative(o: i64) -> bool { o == OP_ADD || o == OP_MUL || o == OP_AND || o == OP_OR || o == OP_XOR }
fn is_desirable_binop(o: i64) -> bool { o == OP_ADD || o == OP_SUB || o == OP_XOR }
fn cf_int_divrem(o: i64) -> bool { o == OP_UDIV || o == OP_SDIV || o == OP_UREM || o == OP_SREM }

// ConstantExpr::getBinOpIdentity (NSZ = false); -1 = none
recursive fn binop_identity(o: i64, ty: i32, allow_rhs: bool) -> i32 {
    if o == OP_ADD || o == OP_OR || o == OP_XOR { return c_null(ty); }
    if o == OP_MUL { return ap_to_cint(ty, ap_u64(1, ty_bits(ty_scalar(ty)))); }
    if o == OP_AND { return c_all_ones(ty); }
    if o == OP_FADD { return c_fp_neg_zero_ty(ty); }
    if o == OP_FMUL { return c_fp_one_ty(ty); }
    if !allow_rhs { return -1; }
    if o == OP_SUB || o == OP_SHL || o == OP_LSHR || o == OP_ASHR { return c_null(ty); }
    if o == OP_FSUB { return c_null(ty); }
    if o == OP_SDIV || o == OP_UDIV { return ap_to_cint(ty, ap_u64(1, ty_bits(ty_scalar(ty)))); }
    if o == OP_FDIV { return c_fp_one_ty(ty); }
    return -1;
}

// ConstantExpr::getBinOpAbsorber
recursive fn binop_absorber(o: i64, ty: i32, allow_lhs: bool) -> i32 {
    if o == OP_OR { return c_all_ones(ty); }
    if o == OP_AND || o == OP_MUL { return c_null(ty); }
    if !allow_lhs { return -1; }
    if o == OP_SHL || o == OP_LSHR || o == OP_ASHR || o == OP_SDIV || o == OP_UDIV || o == OP_UREM || o == OP_SREM { return c_null(ty); }
    return -1;
}

recursive fn binop_dispatch(o: i64, a: i32, b: i32) -> i32 {
    if is_desirable_binop(o) { return ce_binop(o, a, b, 0); }
    return cf_binop(o, a, b);
}

// ConstantFoldBinaryInstruction
recursive fn cf_binop(o: i64, c1: i32, c2: i32) -> i32 {
    let ty = vals[c1].ty;
    if cf_commutative(o) {
        let id = binop_identity(o, ty, false);
        if c1 == id { return c2; }
        if c2 == id { return c1; }
    } else {
        let id = binop_identity(o, ty, true);
        if id >= 0 && c2 == id { return c1; }
    }
    if cf_is_poison(c1) || cf_is_poison(c2) { return c_poison(ty); }
    let scal = !ty_is_vector(ty) || types[ty].kind == TK_SVEC;
    let u1 = cf_is_undef(c1);
    let u2 = cf_is_undef(c2);
    if scal && (u1 || u2) {
        if o == OP_XOR { if u1 && u2 { return c_null(ty); } return c_undef(ty); }
        if o == OP_ADD || o == OP_SUB { return c_undef(ty); }
        if o == OP_AND { if u1 && u2 { return c1; } return c_null(ty); }
        if o == OP_MUL {
            if u1 && u2 { return c1; }
            let other = if u1 { c2 } else { c1 };
            var ov = other;
            if ty_is_vector(vals[other].ty) { ov = c_splat_value(other); }
            if ov >= 0 && vals[ov].kind == VK_CINT && (cint_lo(ov) & 1) != 0 { return c_undef(ty); }
            return c_null(ty);
        }
        if o == OP_SDIV || o == OP_UDIV || o == OP_UREM || o == OP_SREM {
            if u2 || is_zero_or_zero_splat(c2) { return c_poison(vals[c2].ty); }
            return c_null(ty);
        }
        if o == OP_OR { if u1 && u2 { return c1; } return c_all_ones(ty); }
        if o == OP_LSHR || o == OP_ASHR || o == OP_SHL { if u2 { return c_poison(vals[c2].ty); } return c_null(ty); }
        // FP: -0.0 - undef --> undef; [any flop] undef, undef -> undef; otherwise NaN
        if o == OP_FSUB && u2 && fp_const_is_neg_zero(c1) { return c2; }
        if u1 && u2 { return c1; }
        return c_fp_nan_ty(ty);
    }
    if cf_is_cint(c2) {
        let ab = binop_absorber(o, vals[c2].ty, false);
        if ab >= 0 && c2 == ab { return c2; }
        if o == OP_UDIV || o == OP_SDIV { if cint_is_zero(c2) { return c_poison(vals[c2].ty); } }
        if o == OP_UREM || o == OP_SREM {
            if ap_is_one(ap_from_cint(c2)) { return c_null(vals[c2].ty); }
            if cint_is_zero(c2) { return c_poison(vals[c2].ty); }
        }
        if o == OP_AND && cf_is_cexpr(c1) && (cexpr_op(c1) == OP_PTRTOINT || cexpr_op(c1) == OP_PTRTOADDR) && is_global(op(c1, 0)) {
            fatal("constant folding of and(ptrtoint(@global), C) needs global alignment (not supported yet)");
        }
    } else if cf_is_cint(c1) {
        if cf_commutative(o) { return binop_dispatch(o, c2, c1); }
    }
    if cf_is_cint(c1) {
        if cf_is_cint(c2) {
            let a = ap_from_cint(c1);
            let b = ap_from_cint(c2);
            if o == OP_ADD { return ap_to_cint(ty, ap_add(a, b)); }
            if o == OP_SUB { return ap_to_cint(ty, ap_sub(a, b)); }
            if o == OP_MUL { return ap_to_cint(ty, ap_mul(a, b)); }
            if o == OP_UDIV { return ap_to_cint(ty, ap_udiv(a, b)); }
            if o == OP_SDIV { if ap_is_all_ones(b) && ap_is_min_signed(a) { return c_poison(ty); } return ap_to_cint(ty, ap_sdiv(a, b)); }
            if o == OP_UREM { return ap_to_cint(ty, ap_urem(a, b)); }
            if o == OP_SREM { if ap_is_all_ones(b) && ap_is_min_signed(a) { return c_poison(ty); } return ap_to_cint(ty, ap_srem(a, b)); }
            if o == OP_AND { return ap_to_cint(ty, ap_and(a, b)); }
            if o == OP_OR { return ap_to_cint(ty, ap_or(a, b)); }
            if o == OP_XOR { return ap_to_cint(ty, ap_xor(a, b)); }
            let w = a.w as i64;
            if (o == OP_SHL || o == OP_LSHR || o == OP_ASHR) && ap_uge_u64(b, w as u64) { return c_poison(ty); }
            let sh = ap_lo64(b) as i64;
            if o == OP_SHL { return ap_to_cint(ty, ap_shl(a, sh)); }
            if o == OP_LSHR { return ap_to_cint(ty, ap_lshr(a, sh)); }
            if o == OP_ASHR { return ap_to_cint(ty, ap_ashr(a, sh)); }
        }
        let ab = binop_absorber(o, ty, true);
        if ab >= 0 && c1 == ab { return c1; }
    } else if cf_is_cfp(c1) && cf_is_cfp(c2) {
        var fo: i64 = -1;
        if o == OP_FADD { fo = FOP_ADD; } else if o == OP_FSUB { fo = FOP_SUB; } else if o == OP_FMUL { fo = FOP_MUL; }
        else if o == OP_FDIV { fo = FOP_DIV; } else if o == OP_FREM { fo = FOP_MOD; }
        if fo >= 0 {
            let k = types[ty].kind as i64;
            let lo, hi = fp_arith(k, fo, cint_lo(c1), cint_hi(c1), cint_lo(c2), cint_hi(c2));
            return c_fp(ty, lo, hi);
        }
    }
    if ty_is_vector(ty) {
        let s2 = c_splat_value(c2);
        if s2 >= 0 {
            if cf_int_divrem(o) && is_null_value(s2) { return c_poison(ty); }
            let s1 = c_splat_value(c1);
            if s1 >= 0 {
                let r = binop_dispatch(o, s1, s2);
                if r < 0 { return -1; }
                return c_splat(ty, r);
            }
        }
        if types[ty].kind == TK_FVEC {
            let mark = cf_stack.len;
            for i in types[ty].cnt {
                let ix = c_int(T_I32, i);
                let l = ce_extractelement(c1, ix);
                let r = ce_extractelement(c2, ix);
                let e = binop_dispatch(o, l, r);
                if e < 0 { cf_stack.resize(mark); return -1; }
                cf_stack.push(e);
            }
            let r = c_aggregate(ty, cf_stack[mark..]);
            cf_stack.resize(mark);
            return r;
        }
    }
    if cf_is_cexpr(c1) {
        if cf_associative(o) && cexpr_op(c1) == o {
            let t = ce_binop(o, op(c1, 1), c2, 0);
            if !cf_is_cexpr(t) || cexpr_op(t) != o { return ce_binop(o, op(c1, 0), t, 0); }
        }
    } else if cf_is_cexpr(c2) {
        if cf_commutative(o) { return cf_binop(o, c2, c1); }
    }
    if ty_is_int(ty) && ty_bits(ty) == 1 {
        if o == OP_ADD || o == OP_SUB { return ce_binop(OP_XOR, c1, c2, 0); }
        if o == OP_SHL || o == OP_LSHR || o == OP_ASHR || o == OP_SDIV || o == OP_UDIV { return c1; }
        if o == OP_UREM || o == OP_SREM { return c_false(); }
    }
    return -1;
}

fn is_zero_or_zero_splat(v: i32) -> bool {
    if is_null_value(v) { return true; }
    if ty_is_vector(vals[v].ty) { let s = c_splat_value(v); return s >= 0 && is_null_value(s); }
    return false;
}

// ConstantExpr::get(Opcode, C1, C2, Flags)
recursive fn ce_binop(o: i64, c1: i32, c2: i32, flags: u8) -> i32 {
    let f = cf_binop(o, c1, c2);
    if f >= 0 { return f; }
    if !is_desirable_binop(o) { fatal("binary constant expression of an unsupported opcode"); }
    let mark = cf_stack.len;
    cf_stack.push(c1);
    cf_stack.push(c2);
    let r = c_expr(o, vals[c1].ty, cf_stack[mark..], flags, 0, -1, -1);
    cf_stack.resize(mark);
    return r;
}

// ConstantExpr::getNot
recursive fn ce_not(c: i32) -> i32 { return ce_binop(OP_XOR, c, c_all_ones(vals[c].ty), 0); }

// ---------------------------------------------------------------------------------------------
// Vector element operations

// ConstantFoldExtractElementInstruction
recursive fn cf_extractelement(v: i32, idx: i32) -> i32 {
    let vty = vals[v].ty;
    let et = types[vty].a;
    if cf_is_poison(v) || cf_is_undef(idx) { return c_poison(et); }
    if vals[v].kind == VK_UNDEF { return c_undef(et); }
    if !cf_is_cint(idx) { return -1; }
    let ia = ap_from_cint(idx);
    if types[vty].kind == TK_FVEC {
        if ap_uge_u64(ia, types[vty].cnt as! u64) { return c_poison(et); }
    }
    if cf_is_cexpr(v) {
        let o = cexpr_op(v);
        if o == OP_GEP {
            let mark = cf_stack.len;
            for i in nops(v) {
                let x = op(v, i);
                if ty_is_vector(vals[x].ty) {
                    let s = ce_extractelement(x, idx);
                    cf_stack.push(s);
                } else { cf_stack.push(x); }
            }
            let c = csts[vals[v].sub];
            let r = c_gep_expr(c.ty2, cf_stack[mark..], c.flags, c.inr, et);
            cf_stack.resize(mark);
            return r;
        }
        if o == OP_INSERTELEMENT {
            let ii = op(v, 2);
            if cf_is_cint(ii) {
                let ib = ap_from_cint(ii);
                if ap_same_value_u(ib, ia) { return op(v, 1); }
                return ce_extractelement(op(v, 0), idx);
            }
        }
    }
    let e = if ap_ult_u64(ia, 0x7FFFFFFF) { c_aggregate_element(v, ap_lo64(ia) as! i64) } else { -1 };
    if e >= 0 { return e; }
    if ap_ult_u64(ia, types[vty].cnt as! u64) {
        let s = c_splat_value(v);
        if s >= 0 { return s; }
    }
    return -1;
}

recursive fn ce_extractelement(v: i32, idx: i32) -> i32 {
    let f = cf_extractelement(v, idx);
    if f >= 0 { return f; }
    let mark = cf_stack.len;
    cf_stack.push(v);
    cf_stack.push(idx);
    let r = c_expr(OP_EXTRACTELEMENT, types[vals[v].ty].a, cf_stack[mark..], 0, 0, -1, -1);
    cf_stack.resize(mark);
    return r;
}

// ConstantFoldInsertElementInstruction
recursive fn cf_insertelement(v: i32, elt: i32, idx: i32) -> i32 {
    let vty = vals[v].ty;
    if cf_is_undef(idx) { return c_poison(vty); }
    if is_null_value(v) && is_null_value(elt) { return v; }
    if !cf_is_cint(idx) { return -1; }
    if types[vty].kind == TK_SVEC { return -1; }
    let n = types[vty].cnt;
    let ia = ap_from_cint(idx);
    if ap_uge_u64(ia, n as! u64) { return c_poison(vty); }
    let iv = ap_lo64(ia) as! i64;
    let mark = cf_stack.len;
    for i in n {
        if i == iv { cf_stack.push(elt); continue; }
        let c = ce_extractelement(v, c_int(T_I32, i));
        cf_stack.push(c);
    }
    let r = c_aggregate(vty, cf_stack[mark..]);
    cf_stack.resize(mark);
    return r;
}

recursive fn ce_insertelement(v: i32, elt: i32, idx: i32) -> i32 {
    let f = cf_insertelement(v, elt, idx);
    if f >= 0 { return f; }
    let mark = cf_stack.len;
    cf_stack.push(v);
    cf_stack.push(elt);
    cf_stack.push(idx);
    let r = c_expr(OP_INSERTELEMENT, vals[v].ty, cf_stack[mark..], 0, 0, -1, -1);
    cf_stack.resize(mark);
    return r;
}

// ConstantFoldShuffleVectorInstruction; mask: -1 = poison
recursive fn cf_shufflevector(v1: i32, v2: i32, mask: const i32[:]) -> i32 {
    let v1t = vals[v1].ty;
    let sc = types[v1t].kind == TK_SVEC;
    let et = types[v1t].a;
    let rt = ty_vector(et, mask.len, sc);
    var allp = true;
    var allz = true;
    for m in mask { if m != -1 { allp = false; } if m != 0 { allz = false; } }
    if allp { return c_poison(rt); }
    if allz {
        let e = ce_extractelement(v1, c_int(T_I32, 0));
        if !sc || is_null_value(e) || cf_is_undef(e) { return c_splat(rt, e); }
    }
    if sc { return -1; }
    let sn = types[v1t].cnt;
    let mark = cf_stack.len;
    for m in mask {
        if m == -1 { cf_stack.push(c_undef(et)); continue; }
        var e: i32 = -1;
        if m as i64 >= sn * 2 { e = c_undef(et); }
        else if m as i64 >= sn { e = ce_extractelement(v2, c_int(T_I32, m as i64 - sn)); }
        else { e = ce_extractelement(v1, c_int(T_I32, m as i64)); }
        cf_stack.push(e);
    }
    let r = c_aggregate(rt, cf_stack[mark..]);
    cf_stack.resize(mark);
    return r;
}

recursive fn ce_shufflevector(v1: i32, v2: i32, mask: const i32[:]) -> i32 {
    let f = cf_shufflevector(v1, v2, mask);
    if f >= 0 { return f; }
    let v1t = vals[v1].ty;
    let rt = ty_vector(types[v1t].a, mask.len, types[v1t].kind == TK_SVEC);
    var c = cst_none();
    c.op = OP_SHUFFLEVECTOR as u8;
    c.aux = ints.len as i32;
    c.naux = mask.len as i32;
    for m in mask { ints.push(m); }
    let mark = cf_stack.len;
    cf_stack.push(v1);
    cf_stack.push(v2);
    let r = cst_get(VK_CEXPR, rt, c, cf_stack[mark..]);
    cf_stack.resize(mark);
    return r;
}

// ---------------------------------------------------------------------------------------------
// Aggregates (for passes)

recursive fn cf_extractvalue(agg: i32, idxs: const i32[:]) -> i32 {
    if idxs.len == 0 { return agg; }
    let c = c_aggregate_element(agg, idxs[0] as i64);
    if c < 0 { return -1; }
    return cf_extractvalue(c, idxs[1..]);
}

// ---------------------------------------------------------------------------------------------
// getelementptr

// GetElementPtrInst::getGEPReturnType for constants
fn gep_ret_type(base: i32, idxs: const i32[:]) -> i32 {
    let bt = vals[base].ty;
    if ty_is_vector(bt) { return bt; }
    for x in idxs {
        let it = vals[x].ty;
        if ty_is_vector(it) { return ty_vector(bt, types[it].cnt, types[it].kind == TK_SVEC); }
    }
    return bt;
}

// ConstantFoldGetElementPtr
recursive fn cf_gep(srcty: i32, base: i32, idxs: const i32[:], inr: i32) -> i32 {
    if idxs.len == 0 { return base; }
    let gt = gep_ret_type(base, idxs);
    if cf_is_poison(base) { return c_poison(gt); }
    if vals[base].kind == VK_UNDEF { return c_undef(gt); }
    if inr < 0 {
        var noop = true;
        for x in idxs { if !(is_null_value(x) || cf_is_undef(x)) { noop = false; } }
        if noop {
            if ty_is_vector(gt) && !ty_is_vector(vals[base].ty) { return c_splat(gt, base); }
            return base;
        }
    }
    return -1;
}

// The GEP expression node for already-folded operands (base, indices), splatting scalar sequential indices
// when the result is a vector and taking the splat value of vector struct indices (getGetElementPtr).
recursive fn c_gep_expr(srcty: i32, opsv: const i32[:], flags: u8, inr: i32, rt: i32) -> i32 {
    let mark = cf_stack.len;
    cf_stack.push(opsv[0]);
    var cur = srcty;
    let vec = ty_is_vector(rt);
    for k in 1..opsv.len {
        var x = opsv[k];
        // the first index steps over the source type (sequential); later ones index into cur
        let is_struct = k > 1 && types[cur].kind == TK_STRUCT;
        if is_struct && ty_is_vector(vals[x].ty) { x = c_splat_value(x); }
        else if !is_struct && vec && !ty_is_vector(vals[x].ty) { x = c_splat(ty_vector(vals[x].ty, types[rt].cnt, types[rt].kind == TK_SVEC), x); }
        cf_stack.push(x);
        if k > 1 {
            if types[cur].kind == TK_STRUCT { cur = ty_field(cur, cint_lo(x) as! i64); } else { cur = types[cur].a; }
        }
    }
    let r = c_expr(OP_GEP, rt, cf_stack[mark..], flags, 0, srcty, inr);
    cf_stack.resize(mark);
    return r;
}

// ConstantExpr::getGetElementPtr
recursive fn ce_gep(srcty: i32, base: i32, idxs: const i32[:], flags: u8, inr: i32) -> i32 {
    let f = cf_gep(srcty, base, idxs, inr);
    if f >= 0 { return f; }
    let rt = gep_ret_type(base, idxs);
    let mark = cf_stack.len;
    cf_stack.push(base);
    for x in idxs { cf_stack.push(x); }
    let r = c_gep_expr(srcty, cf_stack[mark..], flags, inr, rt);
    cf_stack.resize(mark);
    return r;
}

// inrange(lo, hi) of a GEP constant expression: index into gep_inranges (pairs), deduplicated.
var gep_inranges: i64[>..];
fn inrange_id(lo: i64, hi: i64) -> i32 {
    var k = 0;
    while k < gep_inranges.len {
        if gep_inranges[k] == lo && gep_inranges[k + 1] == hi { return (k / 2) as i32; }
        k += 2;
    }
    gep_inranges.push(lo);
    gep_inranges.push(hi);
    return ((gep_inranges.len - 2) / 2) as i32;
}

// ---------------------------------------------------------------------------------------------
// FP constants

fn fp_kind_ty(ty: i32) -> i64 { types[ty_scalar(ty)].kind as i64 }
fn c_fp_bits_ty(ty: i32, lo: u64, hi: u64) -> i32 {
    let e = c_fp(ty_scalar(ty), lo, hi);
    if ty_is_vector(ty) { return c_splat(ty, e); }
    return e;
}
// ConstantFP::getNaN(Ty)
fn c_fp_nan_ty(ty: i32) -> i32 { let lo, hi = fp_default_nan(fp_kind_ty(ty)); return c_fp_bits_ty(ty, lo, hi); }
fn c_fp_nan(ty: i32) -> i32 { c_fp_nan_ty(ty) }
// ConstantFP::getNegativeZero / getZero(Ty, Negative)
fn c_fp_neg_zero_ty(ty: i32) -> i32 { let lo, hi = fp_neg_bits(fp_kind_ty(ty), 0, 0); return c_fp_bits_ty(ty, lo, hi); }
fn c_fp_neg_zero(ty: i32) -> i32 { c_fp_neg_zero_ty(ty) }
fn c_fp_one_ty(ty: i32) -> i32 { let lo, hi = fp_from_f64(fp_kind_ty(ty), 1.0); return c_fp_bits_ty(ty, lo, hi); }
// ConstantFP::get(Ty, double)
fn c_fp_from_f64(ty: i32, d: f64) -> i32 { let lo, hi = fp_from_f64(fp_kind_ty(ty), d); return c_fp_bits_ty(ty, lo, hi); }
// ConstantFP::get(Ty, V.makeQuiet()) for a scalar ConstantFP c
fn c_fp_quiet(c: i32) -> i32 {
    let ty = vals[c].ty;
    let lo, hi = fp_make_quiet(fp_kind_ty(ty), cint_lo(c), cint_hi(c));
    return c_fp(ty, lo, hi);
}
fn fp_const_is_neg_zero(c: i32) -> bool {
    var s = c;
    if ty_is_vector(vals[c].ty) {
        if vals[c].kind == VK_CFP { s = c_fp(ty_scalar(vals[c].ty), cint_lo(c), cint_hi(c)); }
        else { s = c_splat_value(c); }
        if s < 0 { return false; }
    }
    if vals[s].kind != VK_CFP { return false; }
    let p = fp_decompose(fp_kind_ty(vals[s].ty), cint_lo(s), cint_hi(s));
    return p.cat == FC_ZERO && p.neg;
}
fn cfp_is_largest(c: i32) -> bool { fp_is_largest(fp_kind_ty(vals[c].ty), cint_lo(c), cint_hi(c)) }
fn fp_cmp_gt(a: i32, b: i32) -> bool { fp_compare(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), cint_lo(b), cint_hi(b)) == 2 }
fn fp_cmp_lt(a: i32, b: i32) -> bool { fp_compare(fp_kind_ty(vals[a].ty), cint_lo(a), cint_hi(a), cint_lo(b), cint_hi(b)) == 0 }

// ConstantFoldUnaryInstruction (FNeg)
recursive fn cf_unary(o: i64, c: i32) -> i32 {
    let ty = vals[c].ty;
    let sc = types[ty].kind == TK_SVEC;
    if (!ty_is_vector(ty) || sc) && cf_is_undef(c) { return c; }
    if vals[c].kind == VK_CFP && !ty_is_vector(ty) {
        let lo, hi = fp_neg_bits(fp_kind_ty(ty), cint_lo(c), cint_hi(c));
        return c_fp(ty, lo, hi);
    }
    if ty_is_vector(ty) {
        var s: i32 = -1;
        if vals[c].kind == VK_CFP { s = c_fp(ty_scalar(ty), cint_lo(c), cint_hi(c)); } else { s = c_splat_value(c); }
        if s >= 0 {
            let e = cf_unary(o, s);
            if e >= 0 { return c_splat(ty, e); }
        }
        if types[ty].kind == TK_FVEC {
            let mark = cf_stack.len;
            for i in types[ty].cnt {
                let e = ce_extractelement(c, c_int(T_I32, i));
                let r = cf_unary(o, e);
                if r < 0 { cf_stack.resize(mark); return -1; }
                cf_stack.push(r);
            }
            let r = c_aggregate(ty, cf_stack[mark..]);
            cf_stack.resize(mark);
            return r;
        }
    }
    return -1;
}

// ConstantFoldSelectInstruction
recursive fn cf_select(cond: i32, v1: i32, v2: i32) -> i32 {
    if is_null_value(cond) { return v2; }
    if is_all_ones_value(cond) { return v1; }
    if vals[cond].kind == VK_CVECTOR {
        let n = types[vals[cond].ty].cnt;
        let mark = cf_stack.len;
        var ok = true;
        for i in n {
            let e1 = ce_extractelement(v1, c_int(T_I32, i));
            let e2 = ce_extractelement(v2, c_int(T_I32, i));
            let c = op(cond, i);
            var v: i32 = -1;
            if cf_is_poison(c) { v = c_poison(vals[e1].ty); }
            else if e1 == e2 { v = e1; }
            else if cf_is_undef(c) { v = if cf_is_undef(e1) { e1 } else { e2 }; }
            else {
                if vals[c].kind != VK_CINT { ok = false; break; }
                v = if is_null_value(c) { e2 } else { e1 };
            }
            cf_stack.push(v);
        }
        if ok {
            let r = c_aggregate(vals[v1].ty, cf_stack[mark..]);
            cf_stack.resize(mark);
            return r;
        }
        cf_stack.resize(mark);
    }
    if cf_is_poison(cond) { return c_poison(vals[v1].ty); }
    if cf_is_undef(cond) { if cf_is_undef(v1) { return v1; } return v2; }
    if v1 == v2 { return v1; }
    if cf_is_poison(v1) { return v2; }
    if cf_is_poison(v2) { return v1; }
    if cf_is_undef(v1) && cf_select_not_poison(v2) { return v2; }
    if cf_is_undef(v2) && cf_select_not_poison(v1) { return v1; }
    return -1;
}
recursive fn cf_contains_kind(c: i32, k: i64) -> bool {
    let kind = vals[c].kind;
    if kind == k { return true; }
    if kind == VK_CVECTOR { for i in nops(c) { if cf_contains_kind(op(c, i), k) { return true; } } }
    return false;
}
fn cf_select_not_poison(c: i32) -> bool {
    let k = vals[c].kind;
    if k == VK_POISON { return false; }
    if k == VK_CEXPR { return false; }
    if (k == VK_CINT || k == VK_CFP || k == VK_CNULL) && !ty_is_vector(vals[c].ty) { return true; }
    if k == VK_GVAR || k == VK_FUNC { return true; }
    if ty_is_vector(vals[c].ty) { return !cf_contains_kind(c, VK_POISON) && !cf_contains_kind(c, VK_CEXPR); }
    return false;
}

// ConstantFoldInsertValueInstruction
recursive fn cf_insertvalue(agg: i32, val: i32, idxs: const i32[:]) -> i32 {
    if idxs.len == 0 { return val; }
    let ty = vals[agg].ty;
    let n = types[ty].cnt;
    let mark = cf_stack.len;
    for i in n {
        var c = c_aggregate_element(agg, i);
        if c < 0 { cf_stack.resize(mark); return -1; }
        if idxs[0] as i64 == i { c = cf_insertvalue(c, val, idxs[1..]); if c < 0 { cf_stack.resize(mark); return -1; } }
        cf_stack.push(c);
    }
    let r = c_aggregate(ty, cf_stack[mark..]);
    cf_stack.resize(mark);
    return r;
}

// ---------------------------------------------------------------------------------------------
// ConstantFoldCompareInstruction

fn global_unsafe_for_equality(g: i32) -> bool {
    let x = globs[glob_of(g)];
    let l = x.linkage as i64;
    if l == LK_LINKONCE_ANY || l == LK_WEAK_ANY || l == LK_COMMON || l == LK_EXTERN_WEAK { return true; }
    if x.unnamed == 1 { return true; }
    if vals[g].kind == VK_GVAR {
        let t = x.vty;
        if !cf_ty_is_sized(t) { return true; }
        if cf_ty_is_empty(t) { return true; }
    }
    return false;
}
recursive fn cf_ty_is_sized(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_VOID || k == TK_LABEL || k == TK_METADATA || k == TK_FUNC || k == TK_TOKEN { return false; }
    if k == TK_STRUCT { if (types[t].flags & TF_OPAQUE) != 0 { return false; } for i in types[t].cnt { if !cf_ty_is_sized(ty_field(t, i)) { return false; } } return true; }
    if k == TK_ARRAY || k == TK_FVEC || k == TK_SVEC { return cf_ty_is_sized(types[t].a); }
    return true;
}
// Type::isEmptyTy
recursive fn cf_ty_is_empty(t: i32) -> bool {
    let k = types[t].kind;
    if k == TK_ARRAY { return types[t].cnt == 0 || cf_ty_is_empty(types[t].a); }
    if k == TK_STRUCT { for i in types[t].cnt { if !cf_ty_is_empty(ty_field(t, i)) { return false; } } return true; }
    return false;
}
fn globals_potentially_equal(a: i32, b: i32) -> i64 {
    if vals[a].kind != VK_ALIAS && vals[b].kind != VK_ALIAS {
        if !global_unsafe_for_equality(a) && !global_unsafe_for_equality(b) { return 33; }
    }
    return -1;
}
fn cf_complexity(v: i32) -> i64 {
    let k = vals[v].kind;
    if k == VK_CEXPR { return 3; }
    if is_global(v) { return 2; }
    if k == VK_BLOCKADDR { return 1; }
    return 0;
}
fn cf_pred_swap(p: i64) -> i64 { match p { 34 => 36, 35 => 37, 36 => 34, 37 => 35, 38 => 40, 39 => 41, 40 => 38, 41 => 39, _ => p } }
fn gep_all_zero_indices(g: i32) -> bool {
    for k in 1..nops(g) { let x = op(g, k); if !(vals[x].kind == VK_CINT && cint_is_zero(x)) && !(is_null_value(x)) { return false; } }
    return true;
}
// evaluateICmpRelation: an icmp predicate or -1
recursive fn evaluate_icmp_relation(v1: i32, v2: i32) -> i64 {
    if v1 == v2 { return 32; }
    if types[vals[v1].ty].kind != TK_PTR { return -1; }
    if cf_complexity(v1) < cf_complexity(v2) {
        let r = evaluate_icmp_relation(v2, v1);
        if r >= 0 { return cf_pred_swap(r); }
        return -1;
    }
    let k1 = vals[v1].kind;
    let k2 = vals[v2].kind;
    if k1 == VK_BLOCKADDR {
        if k2 == VK_BLOCKADDR {
            if op(v1, 0) != op(v2, 0) { return 33; }
        } else if k2 == VK_CNULL { return 33; }
    } else if is_global(v1) {
        if is_global(v2) { return globals_potentially_equal(v1, v2); }
        if k2 == VK_BLOCKADDR { return 33; }
        if k2 == VK_CNULL {
            let g = globs[glob_of(v1)];
            if g.linkage as i64 != LK_EXTERN_WEAK && k1 != VK_ALIAS && types[vals[v1].ty].n == 0 { return 34; }
        }
    } else if k1 == VK_CEXPR {
        let o = cexpr_op(v1);
        let b = op(v1, 0);
        if o == OP_GEP {
            if k2 == VK_CNULL {
                if is_global(b) {
                    if globs[glob_of(b)].linkage as i64 != LK_EXTERN_WEAK && (csts[vals[v1].sub].flags & GEP_INBOUNDS) != 0 { return 34; }
                }
            } else if is_global(v2) {
                if is_global(b) && b != v2 {
                    if gep_all_zero_indices(v1) { return globals_potentially_equal(b, v2); }
                    return -1;
                }
            } else if k2 == VK_CEXPR && cexpr_op(v2) == OP_GEP {
                let b2 = op(v2, 0);
                if is_global(b) && is_global(b2) && b != b2 {
                    if gep_all_zero_indices(v1) && gep_all_zero_indices(v2) { return globals_potentially_equal(b, b2); }
                    return -1;
                }
            }
        }
    }
    return -1;
}

fn cf_icmp_ap(p: i64, a: AP, b: AP) -> bool {
    return match p {
        32 => ap_eq(a, b), 33 => !ap_eq(a, b), 34 => ap_ult(b, a), 35 => !ap_ult(a, b), 36 => ap_ult(a, b), 37 => !ap_ult(b, a),
        38 => ap_slt(b, a), 39 => !ap_slt(a, b), 40 => ap_slt(a, b), _ => !ap_slt(b, a),
    };
}
fn cf_true_when_equal(p: i64) -> bool { p == 32 || p == 35 || p == 37 || p == 39 || p == 41 || p == 15 || p == 9 || p == 11 || p == 13 }

recursive fn cf_compare(p0: i64, c10: i32, c20: i32) -> i32 {
    let p = p0;
    let c1 = c10;
    let c2 = c20;
    let t1 = vals[c1].ty;
    var rt = T_I1;
    if ty_is_vector(t1) { rt = ty_vector(T_I1, types[t1].cnt, types[t1].kind == TK_SVEC); }
    if p == 0 { return c_null(rt); }
    if p == 15 { return c_all_ones(rt); }
    if cf_is_poison(c1) || cf_is_poison(c2) { return c_poison(rt); }
    if cf_is_undef(c1) || cf_is_undef(c2) {
        let is_int = p >= 32;
        if p == 32 || p == 33 || (is_int && c1 == c2) { return c_undef(rt); }
        if is_int { return cf_bool(rt, cf_true_when_equal(p)); }
        return cf_bool(rt, p >= 8 && p <= 14);
    }
    if is_null_value(c2) {
        if p == 35 { return c_all_ones(rt); }
        if p == 36 { return c_null(rt); }
    }
    let st = ty_scalar(t1);
    if types[st].kind == TK_INT && types[st].n == 1 {
        if p == 32 {
            if cf_is_cexpr(c1) { return ce_binop(OP_XOR, c1, ce_not(c2), 0); }
            return ce_binop(OP_XOR, ce_not(c1), c2, 0);
        }
        if p == 33 { return ce_binop(OP_XOR, c1, c2, 0); }
    }
    if cf_is_cint(c1) && cf_is_cint(c2) { return cf_bool(rt, cf_icmp_ap(p, ap_from_cint(c1), ap_from_cint(c2))); }
    if vals[c1].kind == VK_CINT && vals[c2].kind == VK_CINT && ty_is_vector(t1) {
        return c_splat(rt, cf_bool(T_I1, cf_icmp_ap(p, ap_from_cint(c1), ap_from_cint(c2))));
    }
    if cf_is_cfp(c1) && cf_is_cfp(c2) {
        return cf_bool(rt, fp_fcmp(types[st].kind as i64, p, cint_lo(c1), cint_hi(c1), cint_lo(c2), cint_hi(c2)));
    }
    if ty_is_vector(t1) {
        var s1 = c_splat_value_any(c1);
        var s2 = c_splat_value_any(c2);
        if s1 >= 0 && s2 >= 0 {
            let e = cf_compare(p, s1, s2);
            if e >= 0 { return c_splat(rt, e); }
        }
        if types[t1].kind == TK_SVEC { return -1; }
        let mark = cf_stack.len;
        for i in types[t1].cnt {
            let a = ce_extractelement(c1, c_int(T_I32, i));
            let b = ce_extractelement(c2, c_int(T_I32, i));
            let e = cf_compare(p, a, b);
            if e < 0 { cf_stack.resize(mark); return -1; }
            cf_stack.push(e);
        }
        let r = c_aggregate(rt, cf_stack[mark..]);
        cf_stack.resize(mark);
        return r;
    }
    if ty_is_fp(st) {
        if c1 == c2 {
            if p == 6 { return cf_bool(rt, false); }
            if p == 9 { return cf_bool(rt, true); }
        }
        return -1;
    }
    var res: i64 = -1;
    let rel = evaluate_icmp_relation(c1, c2);
    if rel == 32 { res = if cf_true_when_equal(p) { 1 } else { 0 }; }
    else if rel == 36 { if p == 36 || p == 33 || p == 37 { res = 1; } else if p == 34 || p == 32 || p == 35 { res = 0; } }
    else if rel == 40 { if p == 40 || p == 33 || p == 41 { res = 1; } else if p == 38 || p == 32 || p == 39 { res = 0; } }
    else if rel == 34 { if p == 34 || p == 33 || p == 35 { res = 1; } else if p == 36 || p == 32 || p == 37 { res = 0; } }
    else if rel == 38 { if p == 38 || p == 33 || p == 39 { res = 1; } else if p == 40 || p == 32 || p == 41 { res = 0; } }
    else if rel == 37 { if p == 34 { res = 0; } if p == 36 || p == 37 { res = 1; } }
    else if rel == 41 { if p == 38 { res = 0; } if p == 40 || p == 41 { res = 1; } }
    else if rel == 35 { if p == 36 { res = 0; } if p == 34 || p == 35 { res = 1; } }
    else if rel == 39 { if p == 40 { res = 0; } if p == 38 || p == 39 { res = 1; } }
    else if rel == 33 { if p == 32 { res = 0; } if p == 33 { res = 1; } }
    if res != -1 { return cf_bool(rt, res == 1); }
    if (!cf_is_cexpr(c1) && cf_is_cexpr(c2)) || (is_null_value(c1) && !is_null_value(c2)) {
        return cf_compare(cf_pred_swap(p), c2, c1);
    }
    return -1;
}
fn cf_bool(rt: i32, b: bool) -> i32 { if b { c_all_ones(rt) } else { c_null(rt) } }
// getSplatValue that also handles vector-typed ConstantInt/ConstantFP
fn c_splat_value_any(v: i32) -> i32 {
    let k = vals[v].kind;
    let ty = vals[v].ty;
    if k == VK_CINT && ty_is_vector(ty) { return ap_to_cint(ty_scalar(ty), ap_from_cint(v)); }
    if k == VK_CFP && ty_is_vector(ty) { return c_fp(ty_scalar(ty), cint_lo(v), cint_hi(v)); }
    return c_splat_value(v);
}
