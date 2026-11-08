// Constant folding without DataLayout: a port of llvm/lib/IR/ConstantFold.cpp (ConstantFoldCastInstruction,
// FoldBitCast, ConstantFoldSelectInstruction, ConstantFoldExtractElementInstruction,
// ConstantFoldInsertElementInstruction, ConstantFoldShuffleVectorInstruction, ConstantFoldExtractValueInstruction,
// ConstantFoldInsertValueInstruction, ConstantFoldUnaryInstruction, ConstantFoldBinaryInstruction,
// evaluateICmpRelation, ConstantFoldCompareInstruction, ConstantFoldGetElementPtr) plus the ConstantExpr::get*
// entry points of llvm/lib/IR/Constants.cpp that fold first and only then create a constant expression
// (ce_cast, ce_binop, ce_extract_element, ce_insert_element, ce_shuffle_vector, ce_gep), and
// CastInst::isEliminableCastPair (llvm/lib/IR/Instructions.cpp) without a DataLayout.
//
// The cf_* procedures return NONE when LLVM's would return nullptr ("can't fold"). Use them from passes the way
// LLVM uses ConstantFold*; the ce_* procedures always return a constant.

cf_is_undef  :: inline (c: Value_Id) -> bool { k := vkind(c); return k == .C_UNDEF || k == .C_POISON; }   // isa<UndefValue>
cf_is_poison :: inline (c: Value_Id) -> bool { return vkind(c) == .C_POISON; }
cf_is_cexpr  :: inline (c: Value_Id) -> bool { return vkind(c) == .C_EXPR; }
cf_is_int    :: inline (c: Value_Id) -> bool { return vkind(c) == .C_INT && !is_vector_type(vtype(c)); }  // isa<ConstantInt> (scalar)
cf_is_fp     :: inline (c: Value_Id) -> bool { return vkind(c) == .C_FP && !is_vector_type(vtype(c)); }
cf_ap :: (c: Value_Id) -> APInt { return ap_from_words(type_bits(scalar_type(vtype(c))), const_int_value(c)); }
cf_int :: (t: Type_Id, a: APInt) -> Value_Id { return const_int_words(t, ap_words(a)); }   // ConstantInt::get (splat for vectors)
cf_bool :: (t: Type_Id, b: bool) -> Value_Id { return const_int(t, ifx b then cast(u64) 1 else 0); }

// Constant::isAllOnesValue
cf_is_all_ones :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT return ap_is_all_ones(cf_ap(c));
    if k == .C_FP {
        bits := type_bits(scalar_type(vtype(c)));
        return ap_is_all_ones(ap_from_words(bits, const_fp_value(c)));
    }
    if is_vector_type(vtype(c)) {
        s := cf_splat(c);
        if s != NONE return cf_is_all_ones(s);
    }
    return false;
}

// Constant::getAllOnesValue
cf_all_ones :: (t: Type_Id) -> Value_Id {
    st := scalar_type(t);
    if is_int_type(st) return cf_int(t, ap_all_ones(type_int_width(st)));
    if type_kind(st) == .BYTE return cf_int(t, ap_all_ones(type_bits(st)));
    if is_fp_type(st) return const_fp_words(t, ap_words(ap_all_ones(type_bits(st))));
    if is_vector_type(t) return cf_get_splat(t, cf_all_ones(st));
    fatal("internal: getAllOnesValue of a non-integer, non-FP type");
    return NONE;
}

// ConstantFP::getNaN(Ty)
cf_nan :: (t: Type_Id) -> Value_Id { return const_fp_words(t, fp_default_nan(type_kind(scalar_type(t)))); }

// Constant::getAggregateElement(i)
cf_elt :: (c: Value_Id, i: u64) -> Value_Id {
    t := vtype(c);
    k := vkind(c);
    tk := type_kind(t);
    n: u64 = 0;
    elt_ty: Type_Id = NONE;
    if tk == .STRUCT { n = type_nsub(t); if i < n elt_ty = type_sub(t, cast(u32) i); }
    else if tk == .ARRAY || tk == .VECTOR || tk == .SVECTOR { n = type_count(t); elt_ty = type_elem(t); }
    else return NONE;
    if i >= n return NONE;
    if tk == .SVECTOR && k != .C_ZERO && k != .C_INT && k != .C_FP && k != .C_NULL return NONE;
    if k == {
        case .C_ZERO; #through;
        case .C_NULL; return const_null_value(elt_ty);
        case .C_UNDEF; return const_undef(elt_ty);
        case .C_POISON; return const_poison(elt_ty);
        case .C_INT; return const_int_words(elt_ty, const_int_value(c));
        case .C_FP; return const_fp_words(elt_ty, const_fp_value(c));
        case .C_DATA;
            w := NewArray(1, u64,, allocator = temp);
            w[0] = const_data_elt(c, i);
            if is_fp_type(elt_ty) return const_fp_words(elt_ty, w);
            return const_int_words(elt_ty, w);
        case .C_ARRAY; #through;
        case .C_STRUCT; #through;
        case .C_VECTOR; return op(c, cast(u32) i);
    }
    return NONE;
}

// Constant::getSplatValue(AllowPoison = false)
cf_splat :: (c: Value_Id) -> Value_Id {
    t := vtype(c);
    if !is_vector_type(t) return NONE;
    k := vkind(c);
    if k == .C_ZERO || k == .C_NULL return const_null_value(type_elem(t));
    if k == .C_INT || k == .C_FP return cf_elt(c, 0);
    if k == .C_DATA {
        n := const_data_count(c);
        e := const_data_elt(c, 0);
        for i: 1..cast(s64) n - 1 if const_data_elt(c, cast(u64) i) != e return NONE;
        return cf_elt(c, 0);
    }
    if k == .C_VECTOR {
        e := op(c, 0);
        for i: 1..cast(s64) nops(c) - 1 if op(c, cast(u32) i) != e return NONE;
        return e;
    }
    if k == .C_EXPR return cf_shuffle_splat_value(c);
    return NONE;
}

// ConstantExpr splat of the form ConstantVector::getSplat builds for scalable vectors:
// shufflevector (insertelement (poison, X, 0), poison, zeroinitializer)
cf_shuffle_splat_value :: (c: Value_Id) -> Value_Id {
    e := cexpr(c);
    if e.op != .SHUFFLEVECTOR return NONE;
    if e.nidx > 0 for i: 0..e.nidx-1 if ir.u32_pool[e.idx + i] != 0 return NONE;
    ins := op(c, 0);
    if vkind(ins) != .C_EXPR || cexpr(ins).op != .INSERTELEMENT return NONE;
    ix := op(ins, 2);
    if !(vkind(ix) == .C_INT && is_null_value(ix)) return NONE;
    return op(ins, 1);
}

// ConstantVector::getSplat
cf_get_splat :: (vt: Type_Id, elt: Value_Id) -> Value_Id {
    k := vkind(elt);
    if k == .C_NULL return const_null(vt);
    if k == .C_INT && type_kind(vtype(elt)) == .BYTE return const_int_words(vt, const_int_value(elt));   // ConstantByte
    if k == .C_FP return const_fp_words(vt, const_fp_value(elt));
    if type_kind(vt) != .SVECTOR {
        if !is_null_value(elt) && opts.use_constant_int_for_fixed_length_splat && k == .C_INT return const_int_words(vt, const_int_value(elt));
    }
    if type_kind(vt) == .SVECTOR {
        // NOTE: LLVM (flag off) builds a shufflevector splat expression here; we keep the ConstantInt-style
        // representation for scalable splats of ints (prints identically, and pm_apint sees through it like
        // getSplatValue does).
        if is_null_value(elt) return const_zero(vt);
        if k == .C_INT return const_int_words(vt, const_int_value(elt));
        if k == .C_UNDEF return const_undef(vt);
        if k == .C_POISON return const_poison(vt);
        // shufflevector (insertelement (poison, elt, 0), poison, zeroinitializer)
        pv := const_poison(vt);
        ins := const_expr(.INSERTELEMENT, vt, 0, NONE, .[pv, elt, const_int(ir.t_i64, 0)]);
        mask := NewArray(cast(s64) type_count(vt), u32,, allocator = temp);
        return ce_shuffle_raw(ins, pv, vt, mask);
    }
    n := type_count(vt);
    elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for * elts it.* = elt;
    return const_aggregate(.C_VECTOR, vt, elts);
}

cf_vector :: (vt: Type_Id, elts: [] Value_Id) -> Value_Id { return const_aggregate(.C_VECTOR, vt, elts); }

vector_with_elt :: (vt: Type_Id, et: Type_Id) -> Type_Id { return type_vector(type_count(vt), et, type_kind(vt) == .SVECTOR); }

// ---------------------------------------------------------------- casts

CAST_RESULTS :: u8.[
    1, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,  // Trunc
    8, 1, 9,99,99, 2,17,99,99,99,99, 2, 3, 0,  // ZExt
    8, 0, 1,99,99, 0, 2,99,99,99,99, 0, 3, 0,  // SExt
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,  // FPToUI
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,  // FPToSI
   99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,  // UIToFP
   99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,  // SIToFP
   99,99,99, 0, 0,99,99, 0, 0,99,99,99, 4, 0,  // FPTrunc
   99,99,99, 2, 2,99,99, 8, 2,99,99,99, 4, 0,  // FPExt
    1, 0, 0,99,99, 0, 0,99,99,99,99, 7, 3, 0,  // PtrToInt
    0, 0, 0,99,99, 0, 0,99,99,99,99, 0, 3, 0,  // PtrToAddr
   99,99,99,99,99,99,99,99,99,11,11,99,15, 0,  // IntToPtr
    5, 5, 5, 0, 0, 5, 5, 0, 0,16,16, 5, 1,14,  // BitCast
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,13,12,  // AddrSpaceCast
];

is_ptr_or_ptr_vector :: (t: Type_Id) -> bool { return is_ptr_type(scalar_type(t)); }

// CastInst::isEliminableCastPair with DL = nullptr; returns NONE_OP when not eliminable
is_eliminable_cast_pair :: (first: Opcode, second: Opcode, src: Type_Id, mid: Type_Id, dst: Type_Id) -> Opcode {
    first_bc := first == .BITCAST; second_bc := second == .BITCAST;
    if (first_bc && is_vector_type(src) != is_vector_type(mid)) || (second_bc && is_vector_type(mid) != is_vector_type(dst))
        if !(first_bc && second_bc) return .NONE_OP;
    c := CAST_RESULTS[(cast(s64) first - cast(s64) Opcode.TRUNC) * 14 + (cast(s64) second - cast(s64) Opcode.TRUNC)];
    if c == {
        case 0; return .NONE_OP;
        case 1; return first;
        case 2; return second;
        case 3; if !is_vector_type(src) && is_int_type(dst) return first; return .NONE_OP;
        case 4; if dst == mid return first; return .NONE_OP;
        case 5; if is_int_type(src) return second; return .NONE_OP;
        case 7; return .NONE_OP;   // needs a DataLayout
        case 8;
            ss := type_bits(scalar_type(src)); ds := type_bits(scalar_type(dst));
            if src == dst return .BITCAST;
            if ss < ds return first;
            if ss > ds return second;
            return .NONE_OP;
        case 9; return .ZEXT;
        case 11; return .NONE_OP;  // needs a DataLayout
        case 12;
            if ir.types[scalar_type(src)].a != ir.types[scalar_type(dst)].a return .ADDRSPACECAST;
            return .BITCAST;
        case 13; if !is_ptr_or_ptr_vector(dst) return .NONE_OP; return first;
        case 14; if !is_ptr_or_ptr_vector(src) return .NONE_OP; return .ADDRSPACECAST;
        case 15; return first;
        case 16; return second;
        case 17; return .UITOFP;
    }
    fatal("internal: invalid cast combination");
    return .NONE_OP;
}

is_desirable_cast_op :: (opc: Opcode) -> bool {
    return opc == .TRUNC || opc == .PTRTOADDR || opc == .PTRTOINT || opc == .INTTOPTR || opc == .BITCAST || opc == .ADDRSPACECAST;
}
is_desirable_bin_op :: (opc: Opcode) -> bool { return opc == .ADD || opc == .SUB || opc == .XOR; }

fold_maybe_undesirable_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id) -> Value_Id {
    if is_desirable_cast_op(opc) return ce_cast(opc, v, dt);
    return cf_cast(opc, v, dt);
}

// FoldBitCast
cf_fold_bitcast :: (v: Value_Id, dt: Type_Id) -> Value_Id {
    st := vtype(v);
    if st == dt return v;
    if cf_is_all_ones(v) return cf_all_ones(dt);
    k := vkind(v);
    dst := scalar_type(dt); sst := scalar_type(st);
    if k == .C_INT {
        if is_vector_type(dt) && !is_vector_type(st) return ce_cast(.BITCAST, cf_vector(type_vector(1, st, false), .[v]), dt);
        if type_kind(sst) == .BYTE {   // ConstantByte -> Constant{Int, FP}
            if is_int_type(dst) && type_bits(dst) == type_bits(sst) return const_int_words(dt, const_int_value(v));
            if is_fp_type(dst) && type_kind(dst) != .PPC_FP128 && type_bits(dst) == type_bits(sst) return const_fp_words(dt, const_int_value(v));
            return NONE;
        }
        if type_kind(dst) == .BYTE && type_bits(dst) == type_bits(sst) return const_int_words(dt, const_int_value(v));
        if is_fp_type(dst) && type_kind(dst) != .PPC_FP128 && type_bits(dst) == type_bits(sst) return const_fp_words(dt, const_int_value(v));
        return NONE;
    }
    if k == .C_FP {
        if !is_vector_type(st) && is_fp_type(dt) return const_fp_words(dt, const_fp_value(v));   // half <-> bfloat
        if is_vector_type(dt) && !is_vector_type(st) return ce_cast(.BITCAST, cf_vector(type_vector(1, st, false), .[v]), dt);
        if type_kind(sst) == .PPC_FP128 return NONE;
        if (is_int_type(dst) || type_kind(dst) == .BYTE) && type_bits(dst) == type_bits(sst) return const_int_words(dt, const_fp_value(v));
        return NONE;
    }
    return NONE;
}

// ConstantFoldCastInstruction
cf_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id) -> Value_Id {
    if cf_is_poison(v) return const_poison(dt);
    if cf_is_undef(v) {
        if opc == .ZEXT || opc == .SEXT || opc == .UITOFP || opc == .SITOFP return const_null_value(dt);
        return const_undef(dt);
    }
    if is_null_value(v) && type_kind(dt) != .X86_AMX && opc != .ADDRSPACECAST return const_null_value(dt);
    if vkind(v) == .C_EXPR && is_cast_op(cexpr(v).op) {
        e := cexpr(v);
        n := is_eliminable_cast_pair(e.op, opc, vtype(op(v, 0)), vtype(v), dt);
        if n != .NONE_OP return fold_maybe_undesirable_cast(n, op(v, 0), dt);
    }
    st := vtype(v);
    if is_vector_type(dt) && is_vector_type(st) && type_count(dt) == type_count(st) && type_kind(dt) == type_kind(st) {
        det := type_elem(dt);
        s := cf_splat(v);
        if s != NONE {
            r := fold_maybe_undesirable_cast(opc, s, det);
            if r == NONE return NONE;
            return cf_get_splat(dt, r);
        }
        if type_kind(dt) == .SVECTOR return NONE;
        n := type_count(st);
        res := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for i: 0..cast(s64) n - 1 {
            c := ce_extract_element(v, const_int(ir.t_i32, cast(u64) i));
            r := fold_maybe_undesirable_cast(opc, c, det);
            if r == NONE return NONE;
            res[i] = r;
        }
        return cf_vector(dt, res);
    }
    k := vkind(v);
    dk := type_kind(scalar_type(dt));
    if opc == {
        case .FPTRUNC; #through;
        case .FPEXT;
            if k != .C_FP return NONE;
            w, exact := fp_convert(type_kind(scalar_type(st)), dk, const_fp_value(v));
            return const_fp_words(dt, w);
        case .FPTOUI; #through;
        case .FPTOSI;
            if k != .C_FP return NONE;
            bits := type_bits(scalar_type(dt));
            w, ok := fp_to_integer(type_kind(scalar_type(st)), const_fp_value(v), bits, opc == .FPTOSI);
            if !ok return const_poison(dt);
            return const_int_words(dt, w);
        case .UITOFP; #through;
        case .SITOFP;
            if k != .C_INT return NONE;
            w := fp_from_integer(dk, const_int_value(v), type_bits(scalar_type(st)), opc == .SITOFP);
            return const_fp_words(dt, w);
        case .ZEXT;
            if k != .C_INT return NONE;
            return cf_int(dt, ap_zext(cf_ap(v), type_bits(scalar_type(dt))));
        case .SEXT;
            if k != .C_INT return NONE;
            return cf_int(dt, ap_sext(cf_ap(v), type_bits(scalar_type(dt))));
        case .TRUNC;
            if k != .C_INT return NONE;
            return cf_int(dt, ap_trunc(cf_ap(v), type_bits(scalar_type(dt))));
        case .BITCAST;
            return cf_fold_bitcast(v, dt);
    }
    return NONE;   // addrspacecast, inttoptr, ptrtoaddr, ptrtoint
}

// ConstantExpr::getCast (getFoldedCast)
ce_cast :: (opc: Opcode, v: Value_Id, dt: Type_Id) -> Value_Id {
    if !is_desirable_cast_op(opc) fatal("internal: '%' is not supported as a constant expression", opcode_name(opc));
    f := cf_cast(opc, v, dt);
    if f != NONE return f;
    return const_expr(opc, dt, 0, NONE, .[v]);
}

// ---------------------------------------------------------------- select / vectors / aggregates

// ConstantFoldSelectInstruction
cf_select :: (cond: Value_Id, v1: Value_Id, v2: Value_Id) -> Value_Id {
    if is_null_value(cond) return v2;
    if cf_is_all_ones(cond) return v1;
    if vkind(cond) == .C_VECTOR {
        n := nops(cond);
        res: [..] Value_Id; res.allocator = temp;
        for i: 0..cast(s64) n - 1 {
            e1 := ce_extract_element(v1, const_int(ir.t_i32, cast(u64) i));
            e2 := ce_extract_element(v2, const_int(ir.t_i32, cast(u64) i));
            c := op(cond, cast(u32) i);
            v: Value_Id;
            if cf_is_poison(c) v = const_poison(vtype(e1));
            else if e1 == e2 v = e1;
            else if cf_is_undef(c) v = ifx cf_is_undef(e1) then e1 else e2;
            else {
                if !cf_is_int(c) break;
                v = ifx is_null_value(c) then e2 else e1;
            }
            array_add(*res, v);
        }
        if res.count == cast(s64) n return cf_vector(vtype(v1), res);
    }
    if cf_is_poison(cond) return const_poison(vtype(v1));
    if cf_is_undef(cond) { if cf_is_undef(v1) return v1; return v2; }
    if v1 == v2 return v1;
    if cf_is_poison(v1) return v2;
    if cf_is_poison(v2) return v1;
    not_poison :: (c: Value_Id) -> bool {
        k := vkind(c);
        if k == .C_POISON || k == .C_EXPR return false;
        if (k == .C_INT || k == .C_FP || k == .C_NULL) && !is_vector_type(vtype(c)) return true;
        if k == .GLOBAL_VAR || k == .FUNCTION return true;
        if is_vector_type(vtype(c)) return !cf_contains_poison_element(c) && !cf_contains_constant_expression(c);
        return false;
    }
    if cf_is_undef(v1) && not_poison(v2) return v2;
    if cf_is_undef(v2) && not_poison(v1) return v1;
    return NONE;
}

// Constant::containsPoisonElement / containsConstantExpression (vectors)
cf_contains_poison_element :: (c: Value_Id) -> bool {
    if cf_is_poison(c) return true;
    if vkind(c) == .C_VECTOR for i: 0..cast(s64) nops(c) - 1 if cf_is_poison(op(c, cast(u32) i)) return true;
    return false;
}
cf_contains_constant_expression :: (c: Value_Id) -> bool {
    if vkind(c) == .C_VECTOR for i: 0..cast(s64) nops(c) - 1 if vkind(op(c, cast(u32) i)) == .C_EXPR return true;
    return false;
}

// ConstantFoldExtractElementInstruction
cf_extract_element :: (val: Value_Id, idx: Value_Id) -> Value_Id {
    vt := vtype(val);
    et := type_elem(vt);
    if cf_is_poison(val) || cf_is_undef(idx) return const_poison(et);
    if cf_is_undef(val) return const_undef(et);
    if !cf_is_int(idx) return NONE;
    ia := cf_ap(idx);
    if type_kind(vt) == .VECTOR && !ap_ult(ia, ap_from_u64(ia.bits, type_count(vt))) && ia.bits <= 64 return const_poison(et);
    if type_kind(vt) == .VECTOR && ia.bits > 64 && !ap_ult(ia, ap_zext(ap_from_u64(64, type_count(vt)), ia.bits)) return const_poison(et);
    if vkind(val) == .C_EXPR {
        e := cexpr(val);
        if e.op == .GEP {
            ops: [..] Value_Id; ops.allocator = temp;
            for i: 0..cast(s64) nops(val) - 1 {
                o := op(val, cast(u32) i);
                if is_vector_type(vtype(o)) {
                    s := ce_extract_element(o, idx);
                    array_add(*ops, s);
                } else array_add(*ops, o);
            }
            extra: [] u32;
            extra.data = ir.u32_pool.data + e.idx; extra.count = e.nidx;
            return const_expr(.GEP, et, e.flags, e.ty2, ops, extra);   // CE->getWithOperands (no refolding)
        } else if e.op == .INSERTELEMENT {
            ie := op(val, 2);
            if cf_is_int(ie) {
                if ap_same_value_unsigned(cf_ap(ie), ia) return op(val, 1);
                return ce_extract_element(op(val, 0), idx);
            }
        }
    }
    i := ap_limited(ia);
    if ia.bits > 64 { for w: 1..ia.w.count-1 if ia.w[w] != 0 i = 0xFFFF_FFFF_FFFF_FFFF; }
    c := cf_elt(val, i);
    if c != NONE return c;
    if i < type_count(vt) {
        s := cf_splat(val);
        if s != NONE return s;
    }
    return NONE;
}

// APSInt::isSameValue for two unsigned APSInts (possibly different widths)
ap_same_value_unsigned :: (a: APInt, b: APInt) -> bool {
    w := max(a.bits, b.bits);
    return ap_eq(ap_zext(a, w), ap_zext(b, w));
}

ce_extract_element :: (val: Value_Id, idx: Value_Id) -> Value_Id {
    f := cf_extract_element(val, idx);
    if f != NONE return f;
    return const_expr(.EXTRACTELEMENT, type_elem(vtype(val)), 0, NONE, .[val, idx]);
}

// ConstantFoldInsertElementInstruction
cf_insert_element :: (val: Value_Id, elt: Value_Id, idx: Value_Id) -> Value_Id {
    if cf_is_undef(idx) return const_poison(vtype(val));
    if is_null_value(val) && is_null_value(elt) return val;
    if !cf_is_int(idx) return NONE;
    vt := vtype(val);
    if type_kind(vt) == .SVECTOR return NONE;
    n := type_count(vt);
    ia := cf_ap(idx);
    if ia.bits > 64 || ap_limited(ia) >= n return const_poison(vt);
    iv := ap_limited(ia);
    res := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    for i: 0..cast(s64) n - 1 {
        if cast(u64) i == iv { res[i] = elt; continue; }
        res[i] = ce_extract_element(val, const_int(ir.t_i32, cast(u64) i));
    }
    return cf_vector(vt, res);
}

ce_insert_element :: (val: Value_Id, elt: Value_Id, idx: Value_Id) -> Value_Id {
    f := cf_insert_element(val, elt, idx);
    if f != NONE return f;
    return const_expr(.INSERTELEMENT, vtype(val), 0, NONE, .[val, elt, idx]);
}

POISON_MASK_ELEM :: 0xFFFF_FFFF;   // -1 in the u32 mask encoding

// ConstantFoldShuffleVectorInstruction (mask elements: u32, POISON_MASK_ELEM = -1)
cf_shuffle_vector :: (v1: Value_Id, v2: Value_Id, mask: [] u32) -> Value_Id {
    vt := vtype(v1);
    et := type_elem(vt);
    scalable := type_kind(vt) == .SVECTOR;
    rt := type_vector(cast(u64) mask.count, et, scalable);
    all_poison := true; all_zero := true;
    for mask { if it != POISON_MASK_ELEM all_poison = false; if it != 0 all_zero = false; }
    if all_poison return const_poison(rt);
    if all_zero {
        e := ce_extract_element(v1, const_int(ir.t_i32, 0));
        if !scalable || is_null_value(e) || cf_is_undef(e) return cf_get_splat(rt, e);
    }
    if scalable return NONE;
    src_n := type_count(vt);
    res := NewArray(mask.count, Value_Id,, allocator = temp);
    for m, i: mask {
        if m == POISON_MASK_ELEM { res[i] = const_undef(et); continue; }
        if cast(u64) m >= src_n * 2 res[i] = const_undef(et);
        else if cast(u64) m >= src_n res[i] = ce_extract_element(v2, const_int(ir.t_i32, cast(u64) m - src_n));
        else res[i] = ce_extract_element(v1, const_int(ir.t_i32, cast(u64) m));
    }
    return cf_vector(rt, res);
}

ce_shuffle_raw :: (v1: Value_Id, v2: Value_Id, rt: Type_Id, mask: [] u32) -> Value_Id {
    return const_expr(.SHUFFLEVECTOR, rt, 0, NONE, .[v1, v2], mask);
}

ce_shuffle_vector :: (v1: Value_Id, v2: Value_Id, mask: [] u32) -> Value_Id {
    f := cf_shuffle_vector(v1, v2, mask);
    if f != NONE return f;
    vt := vtype(v1);
    rt := type_vector(cast(u64) mask.count, type_elem(vt), type_kind(vt) == .SVECTOR);
    return ce_shuffle_raw(v1, v2, rt, mask);
}

// ConstantFoldExtractValueInstruction
cf_extract_value :: (agg: Value_Id, idxs: [] u32) -> Value_Id {
    if idxs.count == 0 return agg;
    c := cf_elt(agg, idxs[0]);
    if c == NONE return NONE;
    rest: [] u32; rest.data = idxs.data + 1; rest.count = idxs.count - 1;
    return cf_extract_value(c, rest);
}

// ConstantFoldInsertValueInstruction
cf_insert_value :: (agg: Value_Id, val: Value_Id, idxs: [] u32) -> Value_Id {
    if idxs.count == 0 return val;
    t := vtype(agg);
    n := ifx type_kind(t) == .STRUCT then cast(u64) type_nsub(t) else type_count(t);
    res := NewArray(cast(s64) n, Value_Id,, allocator = temp);
    rest: [] u32; rest.data = idxs.data + 1; rest.count = idxs.count - 1;
    for i: 0..cast(s64) n - 1 {
        c := cf_elt(agg, cast(u64) i);
        if c == NONE return NONE;
        if cast(s64) idxs[0] == i c = cf_insert_value(c, val, rest);
        res[i] = c;
    }
    if type_kind(t) == .STRUCT return const_aggregate(.C_STRUCT, t, res);
    return const_aggregate(.C_ARRAY, t, res);
}

// ---------------------------------------------------------------- unary / binary

// ConstantFoldUnaryInstruction (fneg)
cf_unary :: (opc: Opcode, c: Value_Id) -> Value_Id {
    t := vtype(c);
    scalable := type_kind(t) == .SVECTOR;
    if (!is_vector_type(t) || scalable) && cf_is_undef(c) return c;   // -undef -> undef
    if cf_is_fp(c) return const_fp_words(t, fp_neg(type_kind(t), const_fp_value(c)));
    if is_vector_type(t) {
        s := cf_splat(c);
        if s != NONE {
            e := cf_unary(opc, s);
            if e != NONE return cf_get_splat(t, e);
        }
        if !scalable {
            n := type_count(t);
            res := NewArray(cast(s64) n, Value_Id,, allocator = temp);
            for i: 0..cast(s64) n - 1 {
                e := ce_extract_element(c, const_int(ir.t_i32, cast(u64) i));
                r := cf_unary(opc, e);
                if r == NONE return NONE;
                res[i] = r;
            }
            return cf_vector(t, res);
        }
    }
    return NONE;
}

is_commutative_op :: (opc: Opcode) -> bool {
    return opc == .ADD || opc == .MUL || opc == .AND || opc == .OR || opc == .XOR || opc == .FADD || opc == .FMUL;
}
is_associative_op :: (opc: Opcode) -> bool {
    return opc == .AND || opc == .OR || opc == .XOR || opc == .ADD || opc == .MUL;
}
is_int_div_rem :: (opc: Opcode) -> bool { return opc == .UDIV || opc == .SDIV || opc == .UREM || opc == .SREM; }

fp_const :: (t: Type_Id, v: s64) -> Value_Id {   // ConstantFP::get(Ty, small integer)
    st := scalar_type(t);
    w := ap_from_s64(64, v);
    return const_fp_words(t, fp_from_integer(type_kind(st), ap_words(w), 64, true));
}

// ConstantExpr::getBinOpIdentity (NSZ = false)
cf_binop_identity :: (opc: Opcode, t: Type_Id, allow_rhs: bool) -> Value_Id {
    if is_commutative_op(opc) {
        if opc == {
            case .ADD; #through; case .OR; #through; case .XOR; return const_null_value(t);
            case .MUL; return const_int(t, 1);
            case .AND; return cf_all_ones(t);
            case .FADD; return const_fp_words(t, fp_zero(type_kind(scalar_type(t)), true));
            case .FMUL; return fp_const(t, 1);
        }
    }
    if !allow_rhs return NONE;
    if opc == {
        case .SUB; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
        case .FSUB; return const_null_value(t);
        case .SDIV; #through; case .UDIV; return const_int(t, 1);
        case .FDIV; return fp_const(t, 1);
    }
    return NONE;
}

// ConstantExpr::getBinOpAbsorber
cf_binop_absorber :: (opc: Opcode, t: Type_Id, allow_lhs: bool) -> Value_Id {
    if opc == .OR return cf_all_ones(t);
    if opc == .AND || opc == .MUL return const_null_value(t);
    if !allow_lhs return NONE;
    if opc == .SHL || opc == .LSHR || opc == .ASHR || opc == .SDIV || opc == .UDIV || opc == .UREM || opc == .SREM return const_null_value(t);
    return NONE;
}

// m_APInt: a scalar ConstantInt or a splat of one
cf_match_apint :: (c: Value_Id) -> (bool, APInt) {
    if vkind(c) == .C_INT return true, cf_ap(c);
    if is_vector_type(vtype(c)) {
        s := cf_splat(c);
        if s != NONE && vkind(s) == .C_INT return true, cf_ap(s);
    }
    z: APInt;
    return false, z;
}

// ConstantFoldBinaryInstruction
cf_binary :: (opc: Opcode, c1: Value_Id, c2: Value_Id) -> Value_Id {
    t := vtype(c1);
    id := cf_binop_identity(opc, t, false);
    if id != NONE {
        if c1 == id return c2;
        if c2 == id return c1;
    } else {
        id = cf_binop_identity(opc, t, true);
        if id != NONE && c2 == id return c1;
    }
    if cf_is_poison(c1) || cf_is_poison(c2) return const_poison(t);
    scalable := type_kind(t) == .SVECTOR;
    if (!is_vector_type(t) || scalable) && (cf_is_undef(c1) || cf_is_undef(c2)) {
        u1 := cf_is_undef(c1); u2 := cf_is_undef(c2);
        is_zero_or_undef :: (c: Value_Id) -> bool {
            if cf_is_undef(c) return true;
            ok, a := cf_match_apint(c);
            return ok && ap_is_zero(a);
        }
        if opc == {
            case .XOR;
                if u1 && u2 return const_null_value(t);
                return const_undef(t);
            case .ADD; #through;
            case .SUB; return const_undef(t);
            case .AND;
                if u1 && u2 return c1;
                return const_null_value(t);
            case .MUL;
                if u1 && u2 return c1;
                ok, cv := cf_match_apint(c1);
                if !ok { ok, cv = cf_match_apint(c2); }
                if ok && ap_get_bit(cv, 0) return const_undef(t);
                return const_null_value(t);
            case .SDIV; #through; case .UDIV; #through; case .UREM; #through; case .SREM;
                if is_zero_or_undef(c2) return const_poison(vtype(c2));
                return const_null_value(t);
            case .OR;
                if u1 && u2 return c1;
                return cf_all_ones(t);
            case .LSHR; #through; case .ASHR; #through; case .SHL;
                if u2 return const_poison(vtype(c2));
                return const_null_value(t);
            case .FSUB;
                if u2 && vkind(c1) == .C_FP {
                    d := fp_decode(type_kind(scalar_type(t)), const_fp_value(c1));
                    if d.cat == .ZERO && d.neg return c2;   // -0.0 - undef --> undef
                }
                #through;
            case .FADD; #through; case .FMUL; #through; case .FDIV; #through; case .FREM;
                if u1 && u2 return c1;
                return cf_nan(t);
        }
    }

    if cf_is_int(c2) {
        if c2 == cf_binop_absorber(opc, vtype(c2), false) return c2;
        a2 := cf_ap(c2);
        if opc == {
            case .UDIV; #through; case .SDIV;
                if ap_is_zero(a2) return const_poison(vtype(c2));
            case .UREM; #through; case .SREM;
                if ap_is_one(a2) return const_null_value(vtype(c2));
                if ap_is_zero(a2) return const_poison(vtype(c2));
            case .AND;
                if vkind(c1) == .C_EXPR {
                    e := cexpr(c1);
                    if (e.op == .PTRTOINT || e.op == .PTRTOADDR) && is_global_value(vkind(op(c1, 0))) {
                        gv := op(c1, 0);
                        for split(ir.datalayout, "-",, allocator = temp) if begins_with(it, "F")
                            fatal("constant folding 'and' of a global's address with a function pointer alignment ('%') in the datalayout is not supported yet", it);
                        gv_align: u64 = pointer_alignment(gv);
                        if vkind(gv) == .FUNCTION gv_align = 4;   // no DL.getFunctionPtrAlign(): assume 4 (ConstantFold.cpp)
                        if gv_align > 1 {
                            dst_width := a2.bits;
                            lg: u32 = 0; while ((cast(u64) 1) << (lg + 1)) <= gv_align lg += 1;
                            src_width := min(dst_width, lg);
                            bits_not_set := ap_low_bits_set(dst_width, src_width);
                            if ap_eq(ap_and(a2, bits_not_set), a2) return const_null_value(vtype(c2));
                        }
                    }
                }
        }
    } else if cf_is_int(c1) {
        if is_commutative_op(opc) {
            if is_desirable_bin_op(opc) return ce_binop(opc, c2, c1, 0);
            return cf_binary(opc, c2, c1);
        }
    }

    if cf_is_int(c1) {
        if cf_is_int(c2) {
            a := cf_ap(c1); b := cf_ap(c2);
            if opc == {
                case .ADD; return cf_int(t, ap_add(a, b));
                case .SUB; return cf_int(t, ap_sub(a, b));
                case .MUL; return cf_int(t, ap_mul(a, b));
                case .UDIV; return cf_int(t, ap_udiv(a, b));
                case .SDIV;
                    if ap_is_all_ones(b) && ap_eq(a, ap_signed_min(a.bits)) return const_poison(t);
                    return cf_int(t, ap_sdiv(a, b));
                case .UREM; return cf_int(t, ap_urem(a, b));
                case .SREM;
                    if ap_is_all_ones(b) && ap_eq(a, ap_signed_min(a.bits)) return const_poison(t);
                    return cf_int(t, ap_srem(a, b));
                case .AND; return cf_int(t, ap_and(a, b));
                case .OR;  return cf_int(t, ap_or(a, b));
                case .XOR; return cf_int(t, ap_xor(a, b));
                case .SHL; #through; case .LSHR; #through; case .ASHR;
                    if !ap_ult(b, ap_from_u64(b.bits, a.bits)) return const_poison(t);   // too big shift is poison
                    s := cast(u32) ap_limited(b);
                    if opc == .SHL return cf_int(t, ap_shl(a, s));
                    if opc == .LSHR return cf_int(t, ap_lshr(a, s));
                    return cf_int(t, ap_ashr(a, s));
            }
        }
        if c1 == cf_binop_absorber(opc, t, true) return c1;
    } else if cf_is_fp(c1) {
        if cf_is_fp(c2) {
            k := type_kind(t);
            a := const_fp_value(c1); b := const_fp_value(c2);
            r: [] u64; st: Fp_Status;
            if opc == {
                case .FADD; r, st = fp_add_sub(k, a, b, false); return const_fp_words(t, r);
                case .FSUB; r, st = fp_add_sub(k, a, b, true); return const_fp_words(t, r);
                case .FMUL; r, st = fp_mul(k, a, b); return const_fp_words(t, r);
                case .FDIV; r, st = fp_div(k, a, b); return const_fp_words(t, r);
                case .FREM; r, st = fp_mod(k, a, b); return const_fp_words(t, r);
            }
        }
    }

    if is_vector_type(t) {
        s2 := cf_splat(c2);
        if s2 != NONE {
            if is_int_div_rem(opc) && is_null_value(s2) return const_poison(t);
            s1 := cf_splat(c1);
            if s1 != NONE {
                res: Value_Id;
                if is_desirable_bin_op(opc) res = ce_binop(opc, s1, s2, 0);
                else res = cf_binary(opc, s1, s2);
                if res == NONE return NONE;
                return cf_get_splat(t, res);
            }
        }
        if !scalable {
            n := type_count(t);
            out := NewArray(cast(s64) n, Value_Id,, allocator = temp);
            for i: 0..cast(s64) n - 1 {
                ix := const_int(ir.t_i32, cast(u64) i);
                l := ce_extract_element(c1, ix);
                r := ce_extract_element(c2, ix);
                res: Value_Id;
                if is_desirable_bin_op(opc) res = ce_binop(opc, l, r, 0);
                else res = cf_binary(opc, l, r);
                if res == NONE return NONE;
                out[i] = res;
            }
            return cf_vector(t, out);
        }
    }

    if vkind(c1) == .C_EXPR {
        e := cexpr(c1);
        if is_associative_op(opc) && e.op == opc {
            tt := ce_binop(opc, op(c1, 1), c2, 0);
            if vkind(tt) != .C_EXPR || cexpr(tt).op != opc return ce_binop(opc, op(c1, 0), tt, 0);
        }
    } else if vkind(c2) == .C_EXPR {
        if is_commutative_op(opc) return cf_binary(opc, c2, c1);
    }

    if t == ir.t_i1 {
        if opc == {
            case .ADD; #through; case .SUB; return ce_binop(.XOR, c1, c2, 0);
            case .SHL; #through; case .LSHR; #through; case .ASHR; return c1;
            case .SDIV; #through; case .UDIV; return c1;
            case .UREM; #through; case .SREM; return const_int(ir.t_i1, 0);
        }
    }
    return NONE;
}

// ConstantExpr::get(Opcode, C1, C2, Flags)
ce_binop :: (opc: Opcode, c1: Value_Id, c2: Value_Id, flags: u32) -> Value_Id {
    f := cf_binary(opc, c1, c2);
    if f != NONE return f;
    if !is_desirable_bin_op(opc) fatal("internal: '%' is not supported as a constant expression", opcode_name(opc));
    return const_expr(opc, vtype(c1), flags, NONE, .[c1, c2]);
}

ce_not :: (c: Value_Id) -> Value_Id { return ce_binop(.XOR, c, cf_all_ones(vtype(c)), 0); }

// ---------------------------------------------------------------- compares

// CmpInst::Predicate numbering: FCMP 0..15, ICMP 32..41
ICMP_EQ :: 32; ICMP_NE :: 33; ICMP_UGT :: 34; ICMP_UGE :: 35; ICMP_ULT :: 36; ICMP_ULE :: 37;
ICMP_SGT :: 38; ICMP_SGE :: 39; ICMP_SLT :: 40; ICMP_SLE :: 41; BAD_ICMP_PREDICATE :: 42;
FCMP_FALSE :: 0; FCMP_OEQ :: 1; FCMP_OGT :: 2; FCMP_OGE :: 3; FCMP_OLT :: 4; FCMP_OLE :: 5; FCMP_ONE :: 6;
FCMP_ORD :: 7; FCMP_UNO :: 8; FCMP_UEQ :: 9; FCMP_UGT :: 10; FCMP_UGE :: 11; FCMP_ULT :: 12; FCMP_ULE :: 13;
FCMP_UNE :: 14; FCMP_TRUE :: 15;

is_int_predicate :: (p: u8) -> bool { return p >= 32 && p <= 41; }
is_equality_pred :: (p: u8) -> bool { return p == ICMP_EQ || p == ICMP_NE || p == FCMP_OEQ || p == FCMP_ONE || p == FCMP_UEQ || p == FCMP_UNE; }
is_true_when_equal :: (p: u8) -> bool {
    return p == ICMP_EQ || p == ICMP_UGE || p == ICMP_ULE || p == ICMP_SGE || p == ICMP_SLE ||
           p == FCMP_TRUE || p == FCMP_UEQ || p == FCMP_UGE || p == FCMP_ULE || p == FCMP_OEQ || p == FCMP_OGE || p == FCMP_OLE;
}
is_unordered_pred :: (p: u8) -> bool { return p == FCMP_UNO || p == FCMP_UEQ || p == FCMP_UGT || p == FCMP_UGE || p == FCMP_ULT || p == FCMP_ULE || p == FCMP_UNE || p == FCMP_TRUE; }
swapped_predicate :: (p: u8) -> u8 {
    if p == {
        case ICMP_UGT; return ICMP_ULT; case ICMP_ULT; return ICMP_UGT; case ICMP_UGE; return ICMP_ULE; case ICMP_ULE; return ICMP_UGE;
        case ICMP_SGT; return ICMP_SLT; case ICMP_SLT; return ICMP_SGT; case ICMP_SGE; return ICMP_SLE; case ICMP_SLE; return ICMP_SGE;
        case FCMP_OGT; return FCMP_OLT; case FCMP_OLT; return FCMP_OGT; case FCMP_OGE; return FCMP_OLE; case FCMP_OLE; return FCMP_OGE;
        case FCMP_UGT; return FCMP_ULT; case FCMP_ULT; return FCMP_UGT; case FCMP_UGE; return FCMP_ULE; case FCMP_ULE; return FCMP_UGE;
    }
    return p;
}

// ICmpInst::compare
icmp_compare :: (a: APInt, b: APInt, p: u8) -> bool {
    if p == {
        case ICMP_EQ; return ap_eq(a, b);
        case ICMP_NE; return !ap_eq(a, b);
        case ICMP_UGT; return ap_ugt(a, b);
        case ICMP_UGE; return !ap_ult(a, b);
        case ICMP_ULT; return ap_ult(a, b);
        case ICMP_ULE; return ap_ule(a, b);
        case ICMP_SGT; return ap_slt(b, a);
        case ICMP_SGE; return !ap_slt(a, b);
        case ICMP_SLT; return ap_slt(a, b);
        case ICMP_SLE; return !ap_slt(b, a);
    }
    return false;
}

// FCmpInst::compare
fcmp_compare :: (k: Type_Kind, a: [] u64, b: [] u64, p: u8) -> bool {
    r := fp_compare(k, a, b);
    if p == {
        case FCMP_FALSE; return false;
        case FCMP_TRUE; return true;
        case FCMP_UNO; return r == .UNORDERED;
        case FCMP_ORD; return r != .UNORDERED;
        case FCMP_UEQ; return r == .UNORDERED || r == .EQUAL;
        case FCMP_OEQ; return r == .EQUAL;
        case FCMP_UNE; return r != .EQUAL;
        case FCMP_ONE; return r == .LESS || r == .GREATER;
        case FCMP_ULT; return r == .UNORDERED || r == .LESS;
        case FCMP_OLT; return r == .LESS;
        case FCMP_UGT; return r == .UNORDERED || r == .GREATER;
        case FCMP_OGT; return r == .GREATER;
        case FCMP_ULE; return r != .GREATER;
        case FCMP_OLE; return r == .LESS || r == .EQUAL;
        case FCMP_UGE; return r != .LESS;
        case FCMP_OGE; return r == .GREATER || r == .EQUAL;
    }
    return false;
}

// GlobalValue::isInterposable (no -fsemantic-interposition module flag handling)
// Module::getSemanticInterposition: the "SemanticInterposition" module flag
module_semantic_interposition :: () -> bool {
    for * ir.named_md {
        if it.name != "llvm.module.flags" continue;
        for m: it.ops {
            if ir.mds[m].nops < 3 continue;
            k := md_op(m, 1);
            if k == NONE || ir.mds[k].kind != .STRING || ir.mds[k].str != "SemanticInterposition" continue;
            v := md_op(m, 2);
            if v == NONE || ir.mds[v].kind != .VALUE || vkind(ir.mds[v].value) != .C_INT return false;
            return const_int_zext(ir.mds[v].value) != 0;
        }
    }
    return false;
}
// GlobalValue::isInterposable (CheckNoIPA = true)
gv_is_interposable :: (g: Value_Id) -> bool {
    if vkind(g) == .FUNCTION && !is_declaration(g) && fn_has_fn_attr(g, .NoIPA) return true;   // isNoipaFnDef
    l := glob(g).linkage;
    if !glob(g).dso_local && module_semantic_interposition() return true;
    if l == .WEAK_ANY || l == .LINKONCE_ANY || l == .COMMON || l == .EXTERN_WEAK return true;
    return false;
}

// areGlobalsPotentiallyEqual
globals_potentially_equal :: (g1: Value_Id, g2: Value_Id) -> u8 {
    unsafe :: (g: Value_Id) -> bool {
        if gv_is_interposable(g) || glob(g).unnamed_addr == 2 return true;
        if vkind(g) == .GLOBAL_VAR {
            t := glob(g).value_type;
            if !type_is_sized(t) return true;
            if type_is_empty(t) return true;
        }
        return false;
    }
    if vkind(g1) != .ALIAS && vkind(g2) != .ALIAS
        if !unsafe(g1) && !unsafe(g2) return ICMP_NE;
    return BAD_ICMP_PREDICATE;
}

// Type::isSized (without visited set; recursive named structs are not expected here)
type_is_sized :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .INT || k == .BYTE || is_fp_kind(k) || k == .PTR || k == .X86_AMX return true;
    if k == .ARRAY || k == .VECTOR || k == .SVECTOR return type_is_sized(type_elem(t));
    if k == .STRUCT {
        if ir.types[t].flags & TYF_OPAQUE return false;
        for i: 0..cast(s64) type_nsub(t) - 1 if !type_is_sized(type_sub(t, cast(u32) i)) return false;
        return true;
    }
    if k == .TARGET_EXT return type_kind(target_ext_layout_type(t)) != .VOID;
    return false;
}
// Type::isEmptyTy
type_is_empty :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .ARRAY return type_count(t) == 0 || type_is_empty(type_elem(t));
    if k == .STRUCT {
        for i: 0..cast(s64) type_nsub(t) - 1 if !type_is_empty(type_sub(t, cast(u32) i)) return false;
        return true;
    }
    return false;
}

gep_has_all_zero_indices :: (g: Value_Id) -> bool {
    for i: 1..cast(s64) nops(g) - 1 if !(vkind(op(g, cast(u32) i)) == .C_INT && is_null_value(op(g, cast(u32) i))) return false;
    return true;
}

// evaluateICmpRelation
evaluate_icmp_relation :: (v1: Value_Id, v2: Value_Id) -> u8 {
    if v1 == v2 return ICMP_EQ;
    if !is_ptr_type(vtype(v1)) return BAD_ICMP_PREDICATE;
    complexity :: (v: Value_Id) -> int {
        k := vkind(v);
        if k == .C_EXPR return 3;
        if is_global_value(k) return 2;
        if k == .C_BLOCKADDR return 1;
        return 0;
    }
    if complexity(v1) < complexity(v2) {
        r := evaluate_icmp_relation(v2, v1);
        if r != BAD_ICMP_PREDICATE return swapped_predicate(r);
        return BAD_ICMP_PREDICATE;
    }
    k1 := vkind(v1); k2 := vkind(v2);
    if k1 == .C_BLOCKADDR {
        if k2 == .C_BLOCKADDR { if op(v1, 0) != op(v2, 0) return ICMP_NE; }
        else if k2 == .C_NULL return ICMP_NE;
    } else if is_global_value(k1) {
        if is_global_value(k2) return globals_potentially_equal(v1, v2);
        if k2 == .C_BLOCKADDR return ICMP_NE;
        if k2 == .C_NULL {
            // NullPointerIsDefined(nullptr, AS) is AS != 0
            if glob(v1).linkage != .EXTERN_WEAK && k1 != .ALIAS && ir.types[vtype(v1)].a == 0 return ICMP_UGT;
        }
    } else if k1 == .C_EXPR {
        e := cexpr(v1);
        if e.op == .GEP {
            b1 := op(v1, 0);
            if k2 == .C_NULL {
                if is_global_value(vkind(b1)) && glob(b1).linkage != .EXTERN_WEAK && (e.flags & F_INBOUNDS) return ICMP_UGT;
            } else if is_global_value(k2) {
                if is_global_value(vkind(b1)) && b1 != v2 {
                    if gep_has_all_zero_indices(v1) return globals_potentially_equal(b1, v2);
                    return BAD_ICMP_PREDICATE;
                }
            } else if k2 == .C_EXPR && cexpr(v2).op == .GEP {
                b2 := op(v2, 0);
                if is_global_value(vkind(b1)) && is_global_value(vkind(b2)) && b1 != b2 {
                    if gep_has_all_zero_indices(v1) && gep_has_all_zero_indices(v2) return globals_potentially_equal(b1, b2);
                    return BAD_ICMP_PREDICATE;
                }
            }
        }
    }
    return BAD_ICMP_PREDICATE;
}

// ConstantFoldCompareInstruction
cf_compare :: (pred_in: u8, c1: Value_Id, c2: Value_Id) -> Value_Id {
    pred := pred_in;
    t1 := vtype(c1);
    rt := ifx is_vector_type(t1) then vector_with_elt(t1, ir.t_i1) else ir.t_i1;
    if pred == FCMP_FALSE return const_null_value(rt);
    if pred == FCMP_TRUE return cf_all_ones(rt);
    if cf_is_poison(c1) || cf_is_poison(c2) return const_poison(rt);
    if cf_is_undef(c1) || cf_is_undef(c2) {
        is_int := is_int_predicate(pred);
        if pred == ICMP_EQ || pred == ICMP_NE || (is_int && c1 == c2) return const_undef(rt);   // ICmpInst::isEquality
        if is_int return cf_bool(rt, is_true_when_equal(pred));
        return cf_bool(rt, is_unordered_pred(pred));
    }
    if is_null_value(c2) {
        if pred == ICMP_UGE return cf_all_ones(rt);
        if pred == ICMP_ULT return const_null_value(rt);
    }
    if scalar_type(t1) == ir.t_i1 {
        if pred == ICMP_EQ {
            if vkind(c1) == .C_EXPR return ce_binop(.XOR, c1, ce_not(c2), 0);
            return ce_binop(.XOR, ce_not(c1), c2, 0);
        }
        if pred == ICMP_NE return ce_binop(.XOR, c1, c2, 0);
    }
    if cf_is_int(c1) && cf_is_int(c2) return cf_bool(rt, icmp_compare(cf_ap(c1), cf_ap(c2), pred));
    if cf_is_fp(c1) && cf_is_fp(c2) return cf_bool(rt, fcmp_compare(type_kind(t1), const_fp_value(c1), const_fp_value(c2), pred));
    if is_vector_type(t1) {
        s1 := cf_splat(c1);
        if s1 != NONE {
            s2 := cf_splat(c2);
            if s2 != NONE {
                e := cf_compare(pred, s1, s2);
                if e != NONE return cf_get_splat(rt, e);
            }
        }
        if type_kind(t1) == .SVECTOR return NONE;
        n := type_count(t1);
        res := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for i: 0..cast(s64) n - 1 {
            ix := const_int(ir.t_i32, cast(u64) i);
            e := cf_compare(pred, ce_extract_element(c1, ix), ce_extract_element(c2, ix));
            if e == NONE return NONE;
            res[i] = e;
        }
        return cf_vector(rt, res);
    }
    if is_fp_type(scalar_type(t1)) {
        if c1 == c2 {
            if pred == FCMP_ONE return const_int(rt, 0);
            if pred == FCMP_UEQ return const_int(rt, 1);
        }
    } else {
        result := -1;
        rel := evaluate_icmp_relation(c1, c2);
        p := pred;
        if rel == {
            case ICMP_EQ; result = xx is_true_when_equal(p);
            case ICMP_ULT;
                if p == ICMP_ULT || p == ICMP_NE || p == ICMP_ULE result = 1;
                if p == ICMP_UGT || p == ICMP_EQ || p == ICMP_UGE result = 0;
            case ICMP_SLT;
                if p == ICMP_SLT || p == ICMP_NE || p == ICMP_SLE result = 1;
                if p == ICMP_SGT || p == ICMP_EQ || p == ICMP_SGE result = 0;
            case ICMP_UGT;
                if p == ICMP_UGT || p == ICMP_NE || p == ICMP_UGE result = 1;
                if p == ICMP_ULT || p == ICMP_EQ || p == ICMP_ULE result = 0;
            case ICMP_SGT;
                if p == ICMP_SGT || p == ICMP_NE || p == ICMP_SGE result = 1;
                if p == ICMP_SLT || p == ICMP_EQ || p == ICMP_SLE result = 0;
            case ICMP_ULE;
                if p == ICMP_UGT result = 0;
                if p == ICMP_ULT || p == ICMP_ULE result = 1;
            case ICMP_SLE;
                if p == ICMP_SGT result = 0;
                if p == ICMP_SLT || p == ICMP_SLE result = 1;
            case ICMP_UGE;
                if p == ICMP_ULT result = 0;
                if p == ICMP_UGT || p == ICMP_UGE result = 1;
            case ICMP_SGE;
                if p == ICMP_SLT result = 0;
                if p == ICMP_SGT || p == ICMP_SGE result = 1;
            case ICMP_NE;
                if p == ICMP_EQ result = 0;
                if p == ICMP_NE result = 1;
        }
        if result != -1 return const_int(rt, cast(u64) result);
        if (vkind(c1) != .C_EXPR && vkind(c2) == .C_EXPR) || (is_null_value(c1) && !is_null_value(c2))
            return cf_compare(swapped_predicate(pred), c2, c1);
    }
    return NONE;
}

// ---------------------------------------------------------------- getelementptr

// GetElementPtrInst::getGEPReturnType
gep_return_type :: (base: Value_Id, idxs: [] Value_Id) -> Type_Id {
    bt := vtype(base);
    if is_vector_type(bt) return bt;
    for idxs if is_vector_type(vtype(it)) return type_vector(type_count(vtype(it)), bt, type_kind(vtype(it)) == .SVECTOR);
    return bt;
}

// ConstantFoldGetElementPtr
cf_gep :: (srcty: Type_Id, base: Value_Id, has_inrange: bool, idxs: [] Value_Id) -> Value_Id {
    if idxs.count == 0 return base;
    rt := gep_return_type(base, idxs);
    if cf_is_poison(base) return const_poison(rt);
    if cf_is_undef(base) return const_undef(rt);
    if !has_inrange {
        noop := true;
        for idxs if !(is_null_value(it) || cf_is_undef(it)) { noop = false; break; }
        if noop {
            if is_vector_type(rt) && !is_vector_type(vtype(base)) return cf_get_splat(rt, base);
            return base;
        }
    }
    return NONE;
}

// ConstantExpr::getGetElementPtr: fold, else create with sequential indices splatted to the result's element
// count and struct indices unsplatted. `extra` carries the inrange words.
ce_gep :: (srcty: Type_Id, base: Value_Id, idxs: [] Value_Id, flags: u32, extra: [] u32 = .[]) -> Value_Id {
    f := cf_gep(srcty, base, (flags & F_INRANGE) != 0, idxs);
    if f != NONE return f;
    rt := gep_return_type(base, idxs);
    ops: [..] Value_Id; ops.allocator = temp;
    array_add(*ops, base);
    cur := srcty;
    for idx, i: idxs {
        // gep_type_iterator: the first index steps over the source type (sequential); then into cur
        is_struct := i > 0 && type_kind(cur) == .STRUCT;
        x := idx;
        if is_struct && is_vector_type(vtype(x)) x = cf_splat(x);
        else if !is_struct && is_vector_type(rt) && !is_vector_type(vtype(x)) x = cf_get_splat(vector_with_elt(rt, vtype(x)), x);
        array_add(*ops, x);
        if i > 0 {
            if type_kind(cur) == .STRUCT cur = type_sub(cur, cast(u32) const_int_zext(ifx vkind(idx) == .C_INT then idx else cf_splat(idx)));
            else if type_kind(cur) == .ARRAY || is_vector_type(cur) cur = type_elem(cur);
        }
    }
    return const_expr(.GEP, rt, flags, srcty, ops, extra);
}
