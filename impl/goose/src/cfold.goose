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
        let m = wmask64(k0.w as i64);
        if (k1.o | k0.z) == m { return a; }
        if (k0.o | k1.z) == m { return b; }
        let k = kb_and(k0, k1);
        if kb_is_constant(k) { return c_int_ty(vals[a].ty, k.o); }
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
        cfa_not_ported("bitcast of a vector constant to a scalar");
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
    cfa_not_ported("bitcast of a vector constant that changes the element count");
    return -1;
}

// ConstantFoldLoadFromUniformValue
recursive fn cf_fold_load_from_uniform(c: i32, ty: i32) -> i32 {
    if is_undef_val(c) {
        if vals[c].kind == VK_POISON { return c_poison(ty); }
        return c_undef(ty);
    }
    if is_null_value(c) && !ty_is_x86_amx(ty) { return c_null(ty); }
    if is_all_ones_value(c) {
        if ty_is_int(ty_scalar(ty)) || ty_is_fp(ty_scalar(ty)) { return c_all_ones(ty); }
    }
    return -1;
}
fn ty_is_x86_amx(t: i32) -> bool { types[t].kind == TK_X86_AMX }

// ConstantFoldLoadFromConstPtr(C, Ty, Offset) with have_off = explicit offset
recursive fn cf_fold_load_from_const_ptr(c0: i32, ty: i32, off0: i64, have_off: bool) -> i32 {
    var c = c0;
    var off = off0;
    if !have_off {
        // ConstantFoldLoadFromConstPtr(C, Ty, DL): strip to a global with an offset
        c = strip_and_accumulate_offsets(c0, true, false, false);
        off = vt_off;
    }
    if is_gvar(c) {
        let g = globs[glob_of(c)];
        if g.is_const != 0 && gv_has_definitive_initializer(c) {
            let init = op(c, 0);
            let r = cf_fold_load_from_const(init, ty, off);
            if r >= 0 { return r; }
        }
    }
    // ConstantFoldLoadFromUniformValue on the underlying object's initializer
    let u = get_underlying_object(c0, 6);
    if is_gvar(u) {
        let g = globs[glob_of(u)];
        if g.is_const != 0 && gv_has_definitive_initializer(u) {
            return cf_fold_load_from_uniform(op(u, 0), ty);
        }
    }
    return -1;
}

// ConstantFoldLoadFromConst(C, Ty, Offset)
recursive fn cf_fold_load_from_const(c: i32, ty: i32, off: i64) -> i32 {
    // getConstantAtOffset + ConstantFoldLoadThroughBitcast
    if off == 0 && vals[c].ty == ty { return c; }
    let u = cf_fold_load_from_uniform(c, ty);
    if u >= 0 { return u; }
    cfa_not_ported("loads from constant aggregates at an offset (getConstantAtOffset / FoldReinterpretLoadFromConst)");
    return -1;
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
            offset += ci_sval(x) * dl_alloc_size(et);
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
            else { let et = types[c2].a; o2 += ci_sval(x) * dl_alloc_size(et); c2 = et; }
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
    if p < 32 { cf_check_denormal_mode(cxt); }
    return cf_compare(p, a, b);
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
        if !ty_is_sized_cf(x.ty2) && false { return -1; }
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

fn bswap_w(x: u64, w: i64) -> u64 {
    var r: u64 = 0;
    for b in w / 8 { r |= ((x >> (8 * b)) & 0xFF) << (8 * (w / 8 - 1 - b)); }
    return r;
}
fn bitrev_w(x: u64, w: i64) -> u64 {
    var r: u64 = 0;
    for b in w { if ((x >> b) & 1) != 0 { r |= (1 as u64) << (w - 1 - b); } }
    return r;
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
            let w = ci_w(a);
            let x = ci_val(a);
            if id == IID_bswap { return c_int_ty(ty, bswap_w(x, w)); }
            if id == IID_ctpop { return c_int_ty(ty, popcount(x) as u64); }
            if id == IID_bitreverse { return c_int_ty(ty, bitrev_w(x, w)); }
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
            let x0 = if k0 == 1 { ci_val(a) } else { 0 };
            let x1 = if k1 == 1 { ci_val(b) } else { 0 };
            let both = k0 == 1 && k1 == 1;
            if id == IID_smax || id == IID_smin || id == IID_umax || id == IID_umin {
                if !both { return c_int_ty(ty, minmax_saturation(id, w)); }
                return c_int_ty(ty, if icmp_compare(x0, x1, minmax_pred(id), w) { x0 } else { x1 });
            }
            if id == IID_scmp || id == IID_ucmp {
                if !both { return c_int_ty(ty, 0); }
                var r: i64 = 0;
                if id == IID_scmp { r = if sext64(x0, w) > sext64(x1, w) { 1 } else if sext64(x0, w) < sext64(x1, w) { -1 } else { 0 }; }
                else { r = if x0 > x1 { 1 } else if x0 < x1 { -1 } else { 0 }; }
                return c_int_ty(ty, r as! u64);
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
                let res, ov = overflow_op(id, x0, x1, w);
                let m = is_ops.len;
                is_ops.push(c_int_words(ty_field(ty, 0), res, 0));
                is_ops.push(c_int_words(T_I1, if ov { 1 } else { 0 }, 0));
                let r = c_aggregate(ty, is_ops[m..]);
                is_ops.resize(m);
                return r;
            }
            if id == IID_uadd_sat || id == IID_sadd_sat {
                if !both { return c_all_ones(ty); }
                if id == IID_uadd_sat { return c_int_ty(ty, uadd_sat_w(x0, x1, w)); }
                return c_int_ty(ty, sadd_sat_w(x0, x1, w));
            }
            if id == IID_usub_sat || id == IID_ssub_sat {
                if !both { return c_null(ty); }
                if id == IID_usub_sat { return c_int_ty(ty, usub_sat_w(x0, x1)); }
                return c_int_ty(ty, ssub_sat_w(x0, x1, w));
            }
            if id == IID_cttz || id == IID_ctlz {
                if x1 == 1 && (k0 == 0 || x0 == 0) { return c_poison(ty); }
                if k0 == 0 { return c_null(ty); }
                if id == IID_cttz { return c_int_ty(ty, ctz_w(x0, w) as u64); }
                return c_int_ty(ty, clz_w(x0, w) as u64);
            }
            if id == IID_abs {
                if x1 == 1 && (k0 == 0 || x0 == sbit64(w)) { return c_poison(ty); }
                if k0 == 0 { return c_null(ty); }
                let s = sext64(x0, w);
                return c_int_ty(ty, (if s < 0 { (0 as u64) - x0 } else { x0 }) & wmask64(w));
            }
            if id == IID_clmul {
                if !both { return c_null(ty); }
                return c_int_ty(ty, clmul_w(x0, x1, w));
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
            let sh = (ci_val(s) % (w as u64)) as i64;
            if sh == 0 { return if right { b } else { a }; }
            let lshr_amt = if right { sh } else { w - sh };
            let shl_amt = if !right { sh } else { w - sh };
            if k0 == 0 { return c_int_ty(ty, ci_val(b) >> lshr_amt); }
            if k1 == 0 { return c_int_ty(ty, (ci_val(a) << shl_amt) & wmask64(w)); }
            return c_int_ty(ty, ((ci_val(a) << shl_amt) & wmask64(w)) | (ci_val(b) >> lshr_amt));
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
fn is_minmax_fp_iid(id: i32) -> bool {
    return id == IID_maxnum || id == IID_minnum || id == IID_maximum || id == IID_minimum || id == IID_maximumnum || id == IID_minimumnum;
}

fn overflow_op(id: i32, a: u64, b: u64, w: i64) -> u64, bool {
    let m = wmask64(w);
    if id == IID_uadd_with_overflow { let r = (a + b) & m; return r, r < a; }
    if id == IID_usub_with_overflow { return (a - b) & m, a < b; }
    if id == IID_sadd_with_overflow {
        let r = (a + b) & m;
        let sa = sext64(a, w);
        let sb = sext64(b, w);
        let sr = sext64(r, w);
        return r, (sa >= 0 && sb >= 0 && sr < 0) || (sa < 0 && sb < 0 && sr >= 0);
    }
    if id == IID_ssub_with_overflow {
        let r = (a - b) & m;
        let sa = sext64(a, w);
        let sb = sext64(b, w);
        let sr = sext64(r, w);
        return r, (sa >= 0 && sb < 0 && sr < 0) || (sa < 0 && sb >= 0 && sr >= 0);
    }
    if id == IID_umul_with_overflow {
        let lo, hi = cf_mul64(a, b);
        let r = lo & m;
        let ov = if w == 64 { hi != 0 } else { hi != 0 || (lo >> w) != 0 };
        return r, ov;
    }
    // smul
    let sa = sext64(a, w);
    let sb = sext64(b, w);
    let r = (a * b) & m;
    if w < 32 {
        let p = sa * sb;
        return r, p != sext64(r, w);
    }
    // exact signed product via magnitudes
    let ua = if sa < 0 { (0 as u64) - (sa as! u64) } else { sa as! u64 };
    let ub = if sb < 0 { (0 as u64) - (sb as! u64) } else { sb as! u64 };
    let lo, hi = cf_mul64(ua, ub);
    let neg = (sa < 0) != (sb < 0);
    // the magnitude must fit in w-1 bits (or equal 2^(w-1) when negative)
    var ov = false;
    if w == 64 {
        if hi != 0 { ov = true; }
        else if neg { ov = lo > sbit64(64); }
        else { ov = lo >= sbit64(64); }
    } else {
        if hi != 0 || (lo >> w) != 0 { ov = true; }
        else if neg { ov = lo > sbit64(w); }
        else { ov = lo >= sbit64(w); }
    }
    return r, ov;
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
    let w = ty_bits(et);
    if w > 64 { pm_wide(); }
    let e0 = agg_elem(v, 0);
    if e0 < 0 || vals[e0].kind != VK_CINT { return -1; }
    var acc = ci_val(e0);
    for i in 1..ty_count(ty) {
        let e = agg_elem(v, i);
        if e < 0 || vals[e].kind != VK_CINT { return -1; }
        let x = ci_val(e);
        if id == IID_vector_reduce_add { acc = (acc + x) & wmask64(w); }
        else if id == IID_vector_reduce_mul { acc = (acc * x) & wmask64(w); }
        else if id == IID_vector_reduce_and { acc &= x; }
        else if id == IID_vector_reduce_or { acc |= x; }
        else if id == IID_vector_reduce_xor { acc ^= x; }
        else if id == IID_vector_reduce_smin { if sext64(x, w) < sext64(acc, w) { acc = x; } }
        else if id == IID_vector_reduce_smax { if sext64(x, w) > sext64(acc, w) { acc = x; } }
        else if id == IID_vector_reduce_umin { if x < acc { acc = x; } }
        else if id == IID_vector_reduce_umax { if x > acc { acc = x; } }
    }
    return c_int_words(et, acc, 0);
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
