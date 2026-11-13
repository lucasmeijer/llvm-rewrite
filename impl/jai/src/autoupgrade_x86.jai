// The x86 call rewrites of AutoUpgrade: upgradeX86IntrinsicCall and its helpers.
// Ported from llvm/lib/IR/AutoUpgrade.cpp (upgradeX86PSLLDQIntrinsics, upgradeX86PSRLDQIntrinsics, getX86MaskVec,
// emitX86Select, emitX86ScalarSelect, upgradeX86ALIGNIntrinsics, upgradeX86VPERMT2Intrinsics,
// upgradeX86BinaryIntrinsics, upgradeX86Rotate, upgradeX86vpcom, upgradeX86ConcatShift, upgradeMaskedStore,
// upgradeMaskedLoad, upgradeAbs, upgradePMULDQ, applyX86MaskOn1BitsVec, upgradeMaskedCompare,
// upgradeX86MaskedShift, upgradeMaskedMove, upgradeMaskToInt, upgradeAVX512MaskToSelect, upgradeX86IntrinsicCall)
// with the IRBuilder<ConstantFolder> methods they use (llvm/include/llvm/IR/IRBuilder.h).

// ---------------------------------------------------------------- IRBuilder methods (Builder of autoupgrade.jai)

xu_name :: (i: Value_Id, name: string) { if name.count && vkind(i) == .INST set_name(i, name); }

xb_binop :: (b: *Builder, opc: Opcode, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    v := builder_binop(b, opc, l, r);
    if vkind(v) == .INST && name.count set_name(v, name);
    return v;
}
xb_and :: (b: *Builder, l: Value_Id, r: Value_Id) -> Value_Id { return builder_binop(b, .AND, l, r); }
xb_or :: (b: *Builder, l: Value_Id, r: Value_Id) -> Value_Id { return builder_binop(b, .OR, l, r); }
xb_xor :: (b: *Builder, l: Value_Id, r: Value_Id) -> Value_Id { return builder_binop(b, .XOR, l, r); }
// CreateNot: xor with all ones
xb_not :: (b: *Builder, v: Value_Id) -> Value_Id { return builder_binop(b, .XOR, v, cf_all_ones(vtype(v))); }
// CreateFNeg (UnaryOperator with the builder's fast-math flags)
xb_fneg :: (b: *Builder, v: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(v)) { f := cf_unary(.FNEG, v); if f != NONE return f; }
    i := new_inst(.FNEG, vtype(v), 1);
    set_op(i, 0, v);
    builder_insert(b, i);
    builder_set_fmf(b, i);
    return i;
}
xb_cast :: (b: *Builder, opc: Opcode, v: Value_Id, t: Type_Id, name := "") -> Value_Id {
    r := builder_cast(b, opc, v, t, name);
    // FPMathOperator casts (fptrunc / fpext) take the builder's fast-math flags
    if (opc == .FPEXT || opc == .FPTRUNC) && vkind(r) == .INST && r != v builder_set_fmf(b, r);
    return r;
}
// CreateIntCast
xb_int_cast :: (b: *Builder, v: Value_Id, t: Type_Id, is_signed: bool) -> Value_Id {
    opc: Opcode;
    if type_bits(scalar_type(vtype(v))) > type_bits(scalar_type(t)) opc = .TRUNC;
    else opc = ifx is_signed then Opcode.SEXT else .ZEXT;
    return builder_cast(b, opc, v, t);
}
// CreateExtractElement(Vec, uint64_t Idx) (an i64 index)
xb_extract :: (b: *Builder, v: Value_Id, idx: u64, name := "") -> Value_Id {
    r := builder_extract_element(b, v, const_int(ir.t_i64, idx));
    xu_name(r, name);
    return r;
}
xb_insert :: (b: *Builder, v: Value_Id, e: Value_Id, idx: u64) -> Value_Id {
    return builder_insert_element(b, v, e, const_int(ir.t_i64, idx));
}
xb_shuffle :: (b: *Builder, v1: Value_Id, v2: Value_Id, mask: [] u32, name := "") -> Value_Id {
    r := builder_shuffle(b, v1, v2, mask);
    xu_name(r, name);
    return r;
}
// CreateShuffleVector(V, Mask): the second operand is poison
xb_shuffle1 :: (b: *Builder, v: Value_Id, mask: [] u32, name := "") -> Value_Id {
    return xb_shuffle(b, v, const_poison(vtype(v)), mask, name);
}
// CreateVectorSplat(NumElts, V, Name = "")
xb_splat :: (b: *Builder, n: u64, v: Value_Id) -> Value_Id {
    poison := const_poison(type_vector(n, vtype(v), false));
    ins := builder_insert_element(b, poison, v, const_int(ir.t_i64, 0));
    xu_name(ins, ".splatinsert");
    zeros := NewArray(cast(s64) n, u32,, allocator = temp);
    return xb_shuffle1(b, ins, zeros, ".splat");
}
xb_select :: (b: *Builder, c: Value_Id, t: Value_Id, f: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(c)) && is_constant_kind(vkind(t)) && is_constant_kind(vkind(f)) {
        r := cf_select(c, t, f);
        if r != NONE return r;
    }
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, f);
    builder_insert(b, i);
    // SelectInst is an FPMathOperator for FP results
    if is_fp_math_type(vtype(t)) builder_set_fmf(b, i);
    return i;
}
xb_load :: (b: *Builder, t: Type_Id, p: Value_Id, align: u64) -> Value_Id {
    i := new_inst(.LOAD, t, 1);
    set_op(i, 0, p);
    inst(i).align = align;
    builder_insert(b, i);
    return i;
}
// CreateIntrinsic (no folding with IRBuilder<>'s ConstantFolder)
xb_intrinsic :: (b: *Builder, name: string, otys: [] Type_Id, args: [] Value_Id, vname := "") -> Value_Id {
    r := builder_call(b, decl(name, otys), args);
    xu_name(r, vname);
    return r;
}
xb_icmp :: (b: *Builder, pred: u8, l: Value_Id, r: Value_Id) -> Value_Id { return builder_icmp(b, pred, l, r); }

// StoreInst through the builder (CreateAlignedStore)
builder_store :: (b: *Builder, v: Value_Id, p: Value_Id, align: u64) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, p);
    inst(i).align = align;
    builder_insert(b, i);
    return i;
}

xu_vec_bits :: (t: Type_Id) -> u32 { s, sc := prim_size_bits(t); return cast(u32) s; }
xu_elt_bits :: (t: Type_Id) -> u32 { return type_bits(scalar_type(t)); }
xu_nelts :: (t: Type_Id) -> u32 { return cast(u32) type_count(t); }
xu_is_cint :: (v: Value_Id) -> bool { return vkind(v) == .C_INT; }
xu_imm :: (v: Value_Id) -> u64 {
    if !xu_is_cint(v) fatal("auto-upgrade: expected a constant integer immediate");
    return const_int_zext(v);
}
// VectorType::getInteger
xu_int_vec_type :: (t: Type_Id) -> Type_Id { return type_vector(type_count(t), type_int(xu_elt_bits(t)), false); }
xu_iota :: (n: u32) -> [] u32 { r := NewArray(n, u32,, allocator = temp); for i: 0..cast(s64) n - 1 r[i] = cast(u32) i; return r; }

// reportFatalUsageErrorWithCI
xu_fatal_ci :: (msg: string, ci: Value_Id) {
    write_string(tprint("%\n", inst_to_string(ci)), to_standard_error = true);
    write_string(tprint("LLVM ERROR: %\n", msg), to_standard_error = true);
    exit(1);
}

// ---------------------------------------------------------------- helpers

// getX86MaskVec
x86_mask_vec :: (b: *Builder, mask: Value_Id, n: u32) -> Value_Id {
    mt := type_vector(type_bits(vtype(mask)), ir.t_i1, false);
    m := builder_cast(b, .BITCAST, mask, mt);
    if n <= 4 m = xb_shuffle(b, m, m, xu_iota(n), "extract");
    return m;
}
// emitX86Select
emit_x86_select :: (b: *Builder, mask: Value_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(mask)) && cf_is_all_ones(mask) return op0;
    m := x86_mask_vec(b, mask, cast(u32) type_count(vtype(op0)));
    return xb_select(b, m, op0, op1);
}
// emitX86ScalarSelect
emit_x86_scalar_select :: (b: *Builder, mask: Value_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
    if is_constant_kind(vkind(mask)) && cf_is_all_ones(mask) return op0;
    m := builder_cast(b, .BITCAST, mask, type_vector(type_bits(vtype(mask)), ir.t_i1, false));
    m = xb_extract(b, m, 0);
    return xb_select(b, m, op0, op1);
}

// upgradeX86PSLLDQIntrinsics / upgradeX86PSRLDQIntrinsics (byte shifts as shuffles)
upgrade_x86_byte_shift :: (b: *Builder, op_in: Value_Id, shift: u64, left: bool) -> Value_Id {
    rt := vtype(op_in);
    n := xu_nelts(rt) * 8;
    vt := type_vector(n, ir.t_i8, false);
    op := builder_cast(b, .BITCAST, op_in, vt, "cast");
    res := const_null_value(vt);
    if shift < 16 {
        idxs := NewArray(n, u32,, allocator = temp);
        sh := cast(u32) shift;
        l: u32 = 0;
        while l != n {
            for i: 0..cast(u32) 15 {
                idx: u32;
                if left {
                    idx = n + i - sh;
                    if idx < n idx -= n - 16;
                } else {
                    idx = i + sh;
                    if idx >= 16 idx += n - 16;
                }
                idxs[l + i] = idx + l;
            }
            l += 16;
        }
        if left res = xb_shuffle(b, res, op, idxs);
        else res = xb_shuffle(b, op, res, idxs);
    }
    return builder_cast(b, .BITCAST, res, rt, "cast");
}

// upgradeX86ALIGNIntrinsics
upgrade_x86_align :: (b: *Builder, op0_in: Value_Id, op1_in: Value_Id, shift: Value_Id, passthru: Value_Id, mask: Value_Id, is_valign: bool) -> Value_Id {
    op0 := op0_in; op1 := op1_in;
    sv := cast(u32) xu_imm(shift);
    n := xu_nelts(vtype(op0));
    if is_valign sv &= n - 1;
    if sv >= 32 return const_null_value(vtype(op0));
    if sv > 16 { sv -= 16; op1 = op0; op0 = const_null_value(vtype(op0)); }
    idx := NewArray(n, u32,, allocator = temp);
    l: u32 = 0;
    while l < n {
        for i: 0..cast(u32) 15 {
            if l + i >= n break;   // VALIGN has fewer than 16 elements
            j := sv + i;
            if !is_valign && j >= 16 j += n - 16;
            idx[l + i] = j + l;
        }
        l += 16;
    }
    al := xb_shuffle(b, op1, op0, idx, "palignr");
    return emit_x86_select(b, mask, al, passthru);
}

// upgradeX86VPERMT2Intrinsics
upgrade_x86_vpermt2 :: (b: *Builder, ci: Value_Id, zero_mask: bool, index_form: bool) -> Value_Id {
    ty := vtype(ci);
    vw := xu_vec_bits(ty); ew := xu_elt_bits(ty);
    is_float := is_fp_type(scalar_type(ty));
    name: string;
    if vw == 128 && ew == 32 && is_float name = "ps.128";
    else if vw == 128 && ew == 32 && !is_float name = "d.128";
    else if vw == 128 && ew == 64 && is_float name = "pd.128";
    else if vw == 128 && ew == 64 && !is_float name = "q.128";
    else if vw == 256 && ew == 32 && is_float name = "ps.256";
    else if vw == 256 && ew == 32 && !is_float name = "d.256";
    else if vw == 256 && ew == 64 && is_float name = "pd.256";
    else if vw == 256 && ew == 64 && !is_float name = "q.256";
    else if vw == 512 && ew == 32 && is_float name = "ps.512";
    else if vw == 512 && ew == 32 && !is_float name = "d.512";
    else if vw == 512 && ew == 64 && is_float name = "pd.512";
    else if vw == 512 && ew == 64 && !is_float name = "q.512";
    else if vw == 128 && ew == 16 name = "hi.128";
    else if vw == 256 && ew == 16 name = "hi.256";
    else if vw == 512 && ew == 16 name = "hi.512";
    else if vw == 128 && ew == 8 name = "qi.128";
    else if vw == 256 && ew == 8 name = "qi.256";
    else if vw == 512 && ew == 8 name = "qi.512";
    else fatal("Unexpected intrinsic");
    args := Value_Id.[call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2)];
    if !index_form { t := args[0]; args[0] = args[1]; args[1] = t; }
    v := xb_intrinsic(b, tprint("llvm.x86.avx512.vpermi2var.%", name), .[], args);
    pass := ifx zero_mask then const_null_value(ty) else builder_cast(b, .BITCAST, call_arg(ci, 1), ty);
    return emit_x86_select(b, call_arg(ci, 3), v, pass);
}

// upgradeX86BinaryIntrinsics
upgrade_x86_binary :: (b: *Builder, ci: Value_Id, iid: string) -> Value_Id {
    ty := vtype(ci);
    res := xb_intrinsic(b, iid, .[ty], .[call_arg(ci, 0), call_arg(ci, 1)]);
    if call_nargs(ci) == 4 res = emit_x86_select(b, call_arg(ci, 3), res, call_arg(ci, 2));
    return res;
}

// upgradeX86Rotate
upgrade_x86_rotate :: (b: *Builder, ci: Value_Id, right: bool) -> Value_Id {
    ty := vtype(ci);
    src := call_arg(ci, 0);
    amt := call_arg(ci, 1);
    if vtype(amt) != ty {
        amt = xb_int_cast(b, amt, scalar_type(ty), false);
        amt = xb_splat(b, type_count(ty), amt);
    }
    res := xb_intrinsic(b, ifx right then "llvm.fshr" else "llvm.fshl", .[ty], .[src, src, amt]);
    if call_nargs(ci) == 4 res = emit_x86_select(b, call_arg(ci, 3), res, call_arg(ci, 2));
    return res;
}

// upgradeX86vpcom
upgrade_x86_vpcom :: (b: *Builder, ci: Value_Id, imm: u64, signed: bool) -> Value_Id {
    ty := vtype(ci);
    pred: u8;
    if imm == {
        case 0; pred = ifx signed then cast(u8) ICMP_SLT else ICMP_ULT;
        case 1; pred = ifx signed then cast(u8) ICMP_SLE else ICMP_ULE;
        case 2; pred = ifx signed then cast(u8) ICMP_SGT else ICMP_UGT;
        case 3; pred = ifx signed then cast(u8) ICMP_SGE else ICMP_UGE;
        case 4; pred = ICMP_EQ;
        case 5; pred = ICMP_NE;
        case 6; return const_null_value(ty);
        case 7; return cf_all_ones(ty);
        case; fatal("Unknown XOP vpcom/vpcomu predicate");
    }
    c := xb_icmp(b, pred, call_arg(ci, 0), call_arg(ci, 1));
    return builder_cast(b, .SEXT, c, ty);
}

// upgradeX86ConcatShift
upgrade_x86_concat_shift :: (b: *Builder, ci: Value_Id, right: bool, zero_mask: bool) -> Value_Id {
    ty := vtype(ci);
    op0 := call_arg(ci, 0); op1 := call_arg(ci, 1); amt := call_arg(ci, 2);
    if right { t := op0; op0 = op1; op1 = t; }
    if vtype(amt) != ty {
        amt = xb_int_cast(b, amt, scalar_type(ty), false);
        amt = xb_splat(b, type_count(ty), amt);
    }
    res := xb_intrinsic(b, ifx right then "llvm.fshr" else "llvm.fshl", .[ty], .[op0, op1, amt]);
    na := call_nargs(ci);
    if na >= 4 {
        src := ifx na == 5 then call_arg(ci, 3) else ifx zero_mask then const_null_value(ty) else call_arg(ci, 0);
        res = emit_x86_select(b, call_arg(ci, na - 1), res, src);
    }
    return res;
}

// add `align N` to parameter `p` of a call
xu_param_align :: (c: Value_Id, p: u32, align: u64) { add_param_align(c, p, align); }

// upgradeMaskedStore
upgrade_masked_store :: (b: *Builder, ptr: Value_Id, data: Value_Id, mask_in: Value_Id, aligned: bool) {
    align: u64 = 1;
    if aligned align = xu_vec_bits(vtype(data)) / 8;
    if is_constant_kind(vkind(mask_in)) && cf_is_all_ones(mask_in) { builder_store(b, data, ptr, align); return; }
    mask := x86_mask_vec(b, mask_in, xu_nelts(vtype(data)));
    c := xb_intrinsic(b, "llvm.masked.store", .[vtype(data), vtype(ptr)], .[data, ptr, mask]);
    xu_param_align(c, 1, align);
}

// upgradeMaskedLoad
upgrade_masked_load :: (b: *Builder, ptr: Value_Id, passthru: Value_Id, mask_in: Value_Id, aligned: bool) -> Value_Id {
    vt := vtype(passthru);
    align: u64 = 1;
    if aligned align = xu_vec_bits(vt) / 8;
    if is_constant_kind(vkind(mask_in)) && cf_is_all_ones(mask_in) return xb_load(b, vt, ptr, align);
    mask := x86_mask_vec(b, mask_in, xu_nelts(vt));
    c := xb_intrinsic(b, "llvm.masked.load", .[vt, vtype(ptr)], .[ptr, mask, passthru]);
    xu_param_align(c, 0, align);
    return c;
}

// upgradeAbs
upgrade_x86_abs :: (b: *Builder, ci: Value_Id) -> Value_Id {
    ty := vtype(ci);
    res := xb_intrinsic(b, "llvm.abs", .[ty], .[call_arg(ci, 0), const_int(ir.t_i1, 0)]);
    if call_nargs(ci) == 3 res = emit_x86_select(b, call_arg(ci, 2), res, call_arg(ci, 1));
    return res;
}

// upgradePMULDQ
upgrade_pmuldq :: (b: *Builder, ci: Value_Id, signed: bool) -> Value_Id {
    ty := vtype(ci);
    lhs := builder_cast(b, .BITCAST, call_arg(ci, 0), ty);
    rhs := builder_cast(b, .BITCAST, call_arg(ci, 1), ty);
    if signed {
        sh := const_int(ty, 32);
        lhs = builder_binop(b, .SHL, lhs, sh); lhs = builder_binop(b, .ASHR, lhs, sh);
        rhs = builder_binop(b, .SHL, rhs, sh); rhs = builder_binop(b, .ASHR, rhs, sh);
    } else {
        m := const_int(ty, 0xffffffff);
        lhs = builder_binop(b, .AND, lhs, m);
        rhs = builder_binop(b, .AND, rhs, m);
    }
    res := builder_binop(b, .MUL, lhs, rhs);
    if call_nargs(ci) == 4 res = emit_x86_select(b, call_arg(ci, 3), res, call_arg(ci, 2));
    return res;
}

// applyX86MaskOn1BitsVec (mask NONE = no mask)
apply_x86_mask_on_1bits_vec :: (b: *Builder, vec_in: Value_Id, mask: Value_Id) -> Value_Id {
    vec := vec_in;
    n := xu_nelts(vtype(vec));
    if mask != NONE {
        if !(is_constant_kind(vkind(mask)) && cf_is_all_ones(mask)) vec = xb_and(b, vec, x86_mask_vec(b, mask, n));
    }
    if n < 8 {
        idx: [8] u32;
        for i: 0..n-1 idx[i] = i;
        for i: n..cast(u32) 7 idx[i] = n + i % n;
        vec = xb_shuffle(b, vec, const_null_value(vtype(vec)), idx);
    }
    return builder_cast(b, .BITCAST, vec, type_int(max(n, 8)));
}

// upgradeMaskedCompare
upgrade_masked_compare :: (b: *Builder, ci: Value_Id, cc: u64, signed: bool) -> Value_Id {
    op0 := call_arg(ci, 0);
    n := xu_nelts(vtype(op0));
    cmp: Value_Id;
    if cc == 3 cmp = const_null_value(type_vector(n, ir.t_i1, false));
    else if cc == 7 cmp = cf_all_ones(type_vector(n, ir.t_i1, false));
    else {
        pred: u8;
        if cc == {
            case 0; pred = ICMP_EQ;
            case 1; pred = ifx signed then cast(u8) ICMP_SLT else ICMP_ULT;
            case 2; pred = ifx signed then cast(u8) ICMP_SLE else ICMP_ULE;
            case 4; pred = ICMP_NE;
            case 5; pred = ifx signed then cast(u8) ICMP_SGE else ICMP_UGE;
            case 6; pred = ifx signed then cast(u8) ICMP_SGT else ICMP_UGT;
            case; fatal("Unknown condition code");
        }
        cmp = xb_icmp(b, pred, op0, call_arg(ci, 1));
    }
    return apply_x86_mask_on_1bits_vec(b, cmp, call_arg(ci, call_nargs(ci) - 1));
}

// upgradeX86MaskedShift
upgrade_x86_masked_shift :: (b: *Builder, ci: Value_Id, iid: string) -> Value_Id {
    rep := xb_intrinsic(b, iid, .[], .[call_arg(ci, 0), call_arg(ci, 1)]);
    return emit_x86_select(b, call_arg(ci, 3), rep, call_arg(ci, 2));
}

// upgradeMaskedMove
upgrade_masked_move :: (b: *Builder, ci: Value_Id) -> Value_Id {
    a := call_arg(ci, 0); bb := call_arg(ci, 1); src := call_arg(ci, 2); mask := call_arg(ci, 3);
    and_node := xb_and(b, mask, const_int(type_int(8), 1));
    cmp := xb_icmp(b, ICMP_NE, and_node, const_null_value(vtype(and_node)));
    e1 := xb_extract(b, bb, 0);
    e2 := xb_extract(b, src, 0);
    sel := xb_select(b, cmp, e1, e2);
    return xb_insert(b, a, sel, 0);
}

// upgradeMaskToInt
upgrade_mask_to_int :: (b: *Builder, ci: Value_Id) -> Value_Id {
    mask := x86_mask_vec(b, call_arg(ci, 0), xu_nelts(vtype(ci)));
    return builder_cast(b, .SEXT, mask, vtype(ci), "vpmovm2");
}

// upgradeAVX512MaskToSelect (name without "avx512.mask."); false = not one of these
upgrade_avx512_mask_to_select :: (name: string, b: *Builder, ci: Value_Id) -> bool, Value_Id {
    ty := vtype(ci);
    vw := xu_vec_bits(ty); ew := xu_elt_bits(ty);
    iid: string;
    by_width :: (vw: u32, w128: string, w256: string, w512: string) -> string {
        if vw == 128 return w128;
        if vw == 256 return w256;
        if vw == 512 return w512;
        fatal("Unexpected intrinsic");
        return "";
    }
    if begins_with(name, "max.p") {
        if vw == 128 && ew == 32 iid = "sse.max.ps"; else if vw == 128 && ew == 64 iid = "sse2.max.pd";
        else if vw == 256 && ew == 32 iid = "avx.max.ps.256"; else if vw == 256 && ew == 64 iid = "avx.max.pd.256";
        else fatal("Unexpected intrinsic");
    } else if begins_with(name, "min.p") {
        if vw == 128 && ew == 32 iid = "sse.min.ps"; else if vw == 128 && ew == 64 iid = "sse2.min.pd";
        else if vw == 256 && ew == 32 iid = "avx.min.ps.256"; else if vw == 256 && ew == 64 iid = "avx.min.pd.256";
        else fatal("Unexpected intrinsic");
    } else if begins_with(name, "pshuf.b.") iid = by_width(vw, "ssse3.pshuf.b.128", "avx2.pshuf.b", "avx512.pshuf.b.512");
    else if begins_with(name, "pmul.hr.sw.") iid = by_width(vw, "ssse3.pmul.hr.sw.128", "avx2.pmul.hr.sw", "avx512.pmul.hr.sw.512");
    else if begins_with(name, "pmulh.w.") iid = by_width(vw, "sse2.pmulh.w", "avx2.pmulh.w", "avx512.pmulh.w.512");
    else if begins_with(name, "pmulhu.w.") iid = by_width(vw, "sse2.pmulhu.w", "avx2.pmulhu.w", "avx512.pmulhu.w.512");
    else if begins_with(name, "pmaddw.d.") iid = by_width(vw, "sse2.pmadd.wd", "avx2.pmadd.wd", "avx512.pmaddw.d.512");
    else if begins_with(name, "pmaddubs.w.") iid = by_width(vw, "ssse3.pmadd.ub.sw.128", "avx2.pmadd.ub.sw", "avx512.pmaddubs.w.512");
    else if begins_with(name, "packsswb.") iid = by_width(vw, "sse2.packsswb.128", "avx2.packsswb", "avx512.packsswb.512");
    else if begins_with(name, "packssdw.") iid = by_width(vw, "sse2.packssdw.128", "avx2.packssdw", "avx512.packssdw.512");
    else if begins_with(name, "packuswb.") iid = by_width(vw, "sse2.packuswb.128", "avx2.packuswb", "avx512.packuswb.512");
    else if begins_with(name, "packusdw.") iid = by_width(vw, "sse41.packusdw", "avx2.packusdw", "avx512.packusdw.512");
    else if begins_with(name, "vpermilvar.") {
        if vw == 128 && ew == 32 iid = "avx.vpermilvar.ps"; else if vw == 128 && ew == 64 iid = "avx.vpermilvar.pd";
        else if vw == 256 && ew == 32 iid = "avx.vpermilvar.ps.256"; else if vw == 256 && ew == 64 iid = "avx.vpermilvar.pd.256";
        else if vw == 512 && ew == 32 iid = "avx512.vpermilvar.ps.512"; else if vw == 512 && ew == 64 iid = "avx512.vpermilvar.pd.512";
        else fatal("Unexpected intrinsic");
    } else if name == "cvtpd2dq.256" iid = "avx.cvt.pd2dq.256";
    else if name == "cvtpd2ps.256" iid = "avx.cvt.pd2.ps.256";
    else if name == "cvttpd2dq.256" iid = "avx.cvtt.pd2dq.256";
    else if name == "cvttps2dq.128" iid = "sse2.cvttps2dq";
    else if name == "cvttps2dq.256" iid = "avx.cvtt.ps2dq.256";
    else if begins_with(name, "permvar.") {
        is_float := is_fp_type(scalar_type(ty));
        if vw == 256 && ew == 32 && is_float iid = "avx2.permps";
        else if vw == 256 && ew == 32 && !is_float iid = "avx2.permd";
        else if vw == 256 && ew == 64 && is_float iid = "avx512.permvar.df.256";
        else if vw == 256 && ew == 64 && !is_float iid = "avx512.permvar.di.256";
        else if vw == 512 && ew == 32 && is_float iid = "avx512.permvar.sf.512";
        else if vw == 512 && ew == 32 && !is_float iid = "avx512.permvar.si.512";
        else if vw == 512 && ew == 64 && is_float iid = "avx512.permvar.df.512";
        else if vw == 512 && ew == 64 && !is_float iid = "avx512.permvar.di.512";
        else if vw == 128 && ew == 16 iid = "avx512.permvar.hi.128";
        else if vw == 256 && ew == 16 iid = "avx512.permvar.hi.256";
        else if vw == 512 && ew == 16 iid = "avx512.permvar.hi.512";
        else if vw == 128 && ew == 8 iid = "avx512.permvar.qi.128";
        else if vw == 256 && ew == 8 iid = "avx512.permvar.qi.256";
        else if vw == 512 && ew == 8 iid = "avx512.permvar.qi.512";
        else fatal("Unexpected intrinsic");
    } else if begins_with(name, "dbpsadbw.") iid = by_width(vw, "avx512.dbpsadbw.128", "avx512.dbpsadbw.256", "avx512.dbpsadbw.512");
    else if begins_with(name, "pmultishift.qb.") iid = by_width(vw, "avx512.pmultishift.qb.128", "avx512.pmultishift.qb.256", "avx512.pmultishift.qb.512");
    else if begins_with(name, "conflict.") {
        if name[9] == #char "d" iid = by_width(vw, "avx512.conflict.d.128", "avx512.conflict.d.256", "avx512.conflict.d.512");
        else if name[9] == #char "q" iid = by_width(vw, "avx512.conflict.q.128", "avx512.conflict.q.256", "avx512.conflict.q.512");
        else fatal("Unexpected intrinsic");
    } else if begins_with(name, "pavg.") {
        if name[5] == #char "b" iid = by_width(vw, "sse2.pavg.b", "avx2.pavg.b", "avx512.pavg.b.512");
        else if name[5] == #char "w" iid = by_width(vw, "sse2.pavg.w", "avx2.pavg.w", "avx512.pavg.w.512");
        else fatal("Unexpected intrinsic");
    } else return false, NONE;
    na := call_nargs(ci);
    args := NewArray(na - 2, Value_Id,, allocator = temp);
    for i: 0..na - 3 args[i] = call_arg(ci, i);
    rep := xb_intrinsic(b, tprint("llvm.x86.%", iid), .[], args);
    rep = emit_x86_select(b, call_arg(ci, na - 1), rep, call_arg(ci, na - 2));
    return true, rep;
}

// the shift intrinsic of avx512.mask.psll / psrl / psra (kind 'l' = psll, 'r' = psrl, 'a' = psra)
avx512_masked_shift_iid :: (name: string, kind: u8, ci: Value_Id) -> string {
    is_imm := name[16] == #char "i" || (name.count > 18 && name[18] == #char "i");
    is_var := name[16] == #char "v";
    size: u8;
    if name[16] == #char "." size = name[17];
    else if name[17] == #char "." size = name[18];
    else if name[18] == #char "." size = name[19];
    else size = name[20];
    op := ifx kind == #char "l" then "sll" else ifx kind == #char "r" then "srl" else "sra";
    bad :: () #expand { xu_fatal_ci("Intrinsic has unexpected size", `ci); }
    if is_var && name[17] != #char "." {
        n17 := name[17];
        if kind != #char "a" && size == #char "d" && n17 == #char "2" return tprint("avx2.p%v.q", op);
        if kind != #char "a" && size == #char "d" && n17 == #char "4" return tprint("avx2.p%v.q.256", op);
        if size == #char "s" && n17 == #char "4" return tprint("avx2.p%v.d", op);
        if size == #char "s" && n17 == #char "8" return tprint("avx2.p%v.d.256", op);
        if size == #char "h" && n17 == #char "8" return tprint("avx512.p%v.w.128", op);
        if size == #char "h" && n17 == #char "1" return tprint("avx512.p%v.w.256", op);
        if n17 == #char "3" && name[18] == #char "2" return tprint("avx512.p%v.w.512", op);
        bad();
    } else if ends_with(name, ".128") {
        if size == #char "d" return ifx is_imm then tprint("sse2.p%i.d", op) else tprint("sse2.p%.d", op);
        if size == #char "q" {
            if kind == #char "a" return ifx is_imm then "avx512.psrai.q.128" else ifx is_var then "avx512.psrav.q.128" else "avx512.psra.q.128";
            return ifx is_imm then tprint("sse2.p%i.q", op) else tprint("sse2.p%.q", op);
        }
        if size == #char "w" return ifx is_imm then tprint("sse2.p%i.w", op) else tprint("sse2.p%.w", op);
        bad();
    } else if ends_with(name, ".256") {
        if size == #char "d" return ifx is_imm then tprint("avx2.p%i.d", op) else tprint("avx2.p%.d", op);
        if size == #char "q" {
            if kind == #char "a" return ifx is_imm then "avx512.psrai.q.256" else ifx is_var then "avx512.psrav.q.256" else "avx512.psra.q.256";
            return ifx is_imm then tprint("avx2.p%i.q", op) else tprint("avx2.p%.q", op);
        }
        if size == #char "w" return ifx is_imm then tprint("avx2.p%i.w", op) else tprint("avx2.p%.w", op);
        bad();
    } else {
        if size == #char "d" return ifx is_imm then tprint("avx512.p%i.d.512", op) else ifx is_var then tprint("avx512.p%v.d.512", op) else tprint("avx512.p%.d.512", op);
        if size == #char "q" return ifx is_imm then tprint("avx512.p%i.q.512", op) else ifx is_var then tprint("avx512.p%v.q.512", op) else tprint("avx512.p%.q.512", op);
        if size == #char "w" return ifx is_imm then tprint("avx512.p%i.w.512", op) else tprint("avx512.p%.w.512", op);
        bad();
    }
    return "";
}

// ---------------------------------------------------------------- upgradeX86IntrinsicCall

// Returns the replacement value (NONE = none).
upgrade_x86_intrinsic_call :: (name_in: string, ci: Value_Id, b: *Builder) -> Value_Id {
    name := name_in;
    na := call_nargs(ci);
    a :: (i: u32) -> Value_Id #expand { return call_arg(`ci, i); }
    cty := vtype(ci);
    nontemporal :: () -> Md_Id { return md_tuple(.[md_value(const_int(ir.t_i32, 1))], false); }
    x86 :: (s: string) -> string { return tprint("llvm.x86.%", s); }
    imm_not_4 :: (v: Value_Id) -> bool { return !xu_is_cint(v) || const_int_zext(v) != 4; }
    rep: Value_Id = NONE;

    if begins_with(name, "sse4a.movnt.") {
        ex := xb_extract(b, a(1), 0, "extractelement");
        si := builder_store(b, ex, a(0), 1);
        set_metadata(si, md_kind_id("nontemporal"), nontemporal());
    } else if begins_with(name, "avx.movnt.") || begins_with(name, "avx512.storent.") {
        si := builder_store(b, a(1), a(0), xu_vec_bits(vtype(a(1))) / 8);
        set_metadata(si, md_kind_id("nontemporal"), nontemporal());
    } else if name == "sse2.storel.dq" {
        bc := builder_cast(b, .BITCAST, a(1), type_vector(2, ir.t_i64, false), "cast");
        el := xb_extract(b, bc, 0);
        builder_store(b, el, a(0), 1);
    } else if begins_with(name, "sse.storeu.") || begins_with(name, "sse2.storeu.") || begins_with(name, "avx.storeu.") {
        builder_store(b, a(1), a(0), 1);
    } else if name == "avx512.mask.store.ss" {
        mask := xb_and(b, a(2), const_int(type_int(8), 1));
        upgrade_masked_store(b, a(0), a(1), mask, false);
    } else if begins_with(name, "avx512.mask.store") {
        aligned := name[17] != #char "u";
        upgrade_masked_store(b, a(0), a(1), a(2), aligned);
    } else if begins_with(name, "sse2.pcmp") || begins_with(name, "avx2.pcmp") {
        cmp_eq := name[9] == #char "e";
        rep = xb_icmp(b, ifx cmp_eq then cast(u8) ICMP_EQ else ICMP_SGT, a(0), a(1));
        rep = builder_cast(b, .SEXT, rep, cty);
    } else if begins_with(name, "avx512.broadcastm") {
        ext := ir.t_i32;
        if vtype(a(0)) == ir.t_i8 ext = ir.t_i64;
        n := xu_vec_bits(cty) / type_bits(ext);
        rep = builder_cast(b, .ZEXT, a(0), ext);
        rep = xb_splat(b, n, rep);
    } else if name == "sse.sqrt.ss" || name == "sse2.sqrt.sd" {
        vec := a(0);
        e0 := xb_extract(b, vec, 0);
        e0 = xb_intrinsic(b, "llvm.sqrt", .[vtype(e0)], .[e0]);
        rep = xb_insert(b, vec, e0, 0);
    } else if begins_with(name, "avx.sqrt.p") || begins_with(name, "sse2.sqrt.p") || begins_with(name, "sse.sqrt.p") {
        rep = xb_intrinsic(b, "llvm.sqrt", .[cty], .[a(0)]);
    } else if begins_with(name, "avx512.mask.sqrt.p") {
        if na == 4 && imm_not_4(a(3)) {
            iid := ifx name[18] == #char "s" then "avx512.sqrt.ps.512" else "avx512.sqrt.pd.512";
            rep = xb_intrinsic(b, x86(iid), .[], .[a(0), a(3)]);
        } else rep = xb_intrinsic(b, "llvm.sqrt", .[cty], .[a(0)]);
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.ptestm") || begins_with(name, "avx512.ptestnm") {
        op0 := a(0); op1 := a(1); mask := a(2);
        rep = xb_and(b, op0, op1);
        zero := const_null_value(vtype(op0));
        pred := ifx begins_with(name, "avx512.ptestm") then cast(u8) ICMP_NE else ICMP_EQ;
        rep = xb_icmp(b, pred, rep, zero);
        rep = apply_x86_mask_on_1bits_vec(b, rep, mask);
    } else if begins_with(name, "avx512.mask.pbroadcast") {
        n := type_count(vtype(a(1)));
        rep = xb_splat(b, n, a(0));
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.kunpck") {
        n := type_bits(cty);
        lhs := x86_mask_vec(b, a(0), n);
        rhs := x86_mask_vec(b, a(1), n);
        lhs = xb_shuffle(b, lhs, lhs, xu_iota(n / 2));
        rhs = xb_shuffle(b, rhs, rhs, xu_iota(n / 2));
        rep = xb_shuffle(b, rhs, lhs, xu_iota(n));   // operands swapped to match the intrinsic definition
        rep = builder_cast(b, .BITCAST, rep, cty);
    } else if name == "avx512.kand.w" || name == "avx512.kandn.w" || name == "avx512.kor.w" || name == "avx512.kxor.w" || name == "avx512.kxnor.w" {
        lhs := x86_mask_vec(b, a(0), 16);
        rhs := x86_mask_vec(b, a(1), 16);
        if name == "avx512.kand.w" rep = xb_and(b, lhs, rhs);
        else if name == "avx512.kandn.w" { lhs = xb_not(b, lhs); rep = xb_and(b, lhs, rhs); }
        else if name == "avx512.kor.w" rep = xb_or(b, lhs, rhs);
        else if name == "avx512.kxor.w" rep = xb_xor(b, lhs, rhs);
        else { lhs = xb_not(b, lhs); rep = xb_xor(b, lhs, rhs); }
        rep = builder_cast(b, .BITCAST, rep, cty);
    } else if name == "avx512.knot.w" {
        rep = x86_mask_vec(b, a(0), 16);
        rep = xb_not(b, rep);
        rep = builder_cast(b, .BITCAST, rep, cty);
    } else if name == "avx512.kortestz.w" || name == "avx512.kortestc.w" {
        lhs := x86_mask_vec(b, a(0), 16);
        rhs := x86_mask_vec(b, a(1), 16);
        rep = xb_or(b, lhs, rhs);
        i16 := type_int(16);
        rep = builder_cast(b, .BITCAST, rep, i16);
        c := ifx name[14] == #char "c" then cf_all_ones(i16) else const_null_value(i16);
        rep = xb_icmp(b, ICMP_EQ, rep, c);
        rep = builder_cast(b, .ZEXT, rep, ir.t_i32);
    } else if name == "sse.add.ss" || name == "sse2.add.sd" || name == "sse.sub.ss" || name == "sse2.sub.sd" ||
              name == "sse.mul.ss" || name == "sse2.mul.sd" || name == "sse.div.ss" || name == "sse2.div.sd" {
        z := const_int(ir.t_i32, 0);
        e0 := builder_extract_element(b, a(0), z);
        e1 := builder_extract_element(b, a(1), z);
        opc: Opcode;
        if contains(name, ".add.") opc = .FADD;
        else if contains(name, ".sub.") opc = .FSUB;
        else if contains(name, ".mul.") opc = .FMUL;
        else opc = .FDIV;
        r := builder_binop(b, opc, e0, e1);
        rep = builder_insert_element(b, a(0), r, z);
    } else if begins_with(name, "avx512.mask.pcmp") {
        cmp_eq := name[16] == #char "e";
        rep = upgrade_masked_compare(b, ci, ifx cmp_eq then cast(u64) 0 else 6, true);
    } else if begins_with(name, "avx512.mask.vpshufbitqmb.") {
        vw := xu_vec_bits(vtype(a(0)));
        if vw != 128 && vw != 256 && vw != 512 xu_fatal_ci("Unexpected intrinsic", ci);
        rep = xb_intrinsic(b, x86(tprint("avx512.vpshufbitqmb.%", vw)), .[], .[a(0), a(1)]);
        rep = apply_x86_mask_on_1bits_vec(b, rep, a(2));
    } else if begins_with(name, "avx512.mask.fpclass.p") {
        ot := vtype(a(0));
        vw := xu_vec_bits(ot); ew := xu_elt_bits(ot);
        if (vw != 128 && vw != 256 && vw != 512) || (ew != 32 && ew != 64) xu_fatal_ci("Unexpected intrinsic", ci);
        rep = xb_intrinsic(b, x86(tprint("avx512.fpclass.%.%", ifx ew == 32 then "ps" else "pd", vw)), .[], .[a(0), a(1)]);
        rep = apply_x86_mask_on_1bits_vec(b, rep, a(2));
    } else if begins_with(name, "avx512.cmp.p") {
        args: [..] Value_Id; args.allocator = temp;
        for i: 0..na - 1 array_add(*args, a(i));
        ot := vtype(args[0]);
        vw := xu_vec_bits(ot); ew := xu_elt_bits(ot);
        if (vw != 128 && vw != 256 && vw != 512) || (ew != 32 && ew != 64) xu_fatal_ci("Unexpected intrinsic", ci);
        mask := cf_all_ones(cty);
        if vw == 512 { t := mask; mask = args[args.count - 1]; args[args.count - 1] = t; }
        array_add(*args, mask);
        rep = xb_intrinsic(b, x86(tprint("avx512.mask.cmp.%.%", ifx ew == 32 then "ps" else "pd", vw)), .[], args);
    } else if begins_with(name, "avx512.mask.cmp.") {
        rep = upgrade_masked_compare(b, ci, xu_imm(a(2)), true);
    } else if begins_with(name, "avx512.mask.ucmp.") {
        rep = upgrade_masked_compare(b, ci, xu_imm(a(2)), false);
    } else if begins_with(name, "avx512.cvtb2mask.") || begins_with(name, "avx512.cvtw2mask.") ||
              begins_with(name, "avx512.cvtd2mask.") || begins_with(name, "avx512.cvtq2mask.") {
        op := a(0);
        rep = xb_icmp(b, ICMP_SLT, op, const_null_value(vtype(op)));
        rep = apply_x86_mask_on_1bits_vec(b, rep, NONE);
    } else if name == "ssse3.pabs.b.128" || name == "ssse3.pabs.w.128" || name == "ssse3.pabs.d.128" ||
              begins_with(name, "avx2.pabs") || begins_with(name, "avx512.mask.pabs") {
        rep = upgrade_x86_abs(b, ci);
    } else if name == "sse41.pmaxsb" || name == "sse2.pmaxs.w" || name == "sse41.pmaxsd" ||
              begins_with(name, "avx2.pmaxs") || begins_with(name, "avx512.mask.pmaxs") {
        rep = upgrade_x86_binary(b, ci, "llvm.smax");
    } else if name == "sse2.pmaxu.b" || name == "sse41.pmaxuw" || name == "sse41.pmaxud" ||
              begins_with(name, "avx2.pmaxu") || begins_with(name, "avx512.mask.pmaxu") {
        rep = upgrade_x86_binary(b, ci, "llvm.umax");
    } else if name == "sse41.pminsb" || name == "sse2.pmins.w" || name == "sse41.pminsd" ||
              begins_with(name, "avx2.pmins") || begins_with(name, "avx512.mask.pmins") {
        rep = upgrade_x86_binary(b, ci, "llvm.smin");
    } else if name == "sse2.pminu.b" || name == "sse41.pminuw" || name == "sse41.pminud" ||
              begins_with(name, "avx2.pminu") || begins_with(name, "avx512.mask.pminu") {
        rep = upgrade_x86_binary(b, ci, "llvm.umin");
    } else if name == "sse2.pmulu.dq" || name == "avx2.pmulu.dq" || name == "avx512.pmulu.dq.512" ||
              begins_with(name, "avx512.mask.pmulu.dq.") {
        rep = upgrade_pmuldq(b, ci, false);
    } else if name == "sse41.pmuldq" || name == "avx2.pmul.dq" || name == "avx512.pmul.dq.512" ||
              begins_with(name, "avx512.mask.pmul.dq.") {
        rep = upgrade_pmuldq(b, ci, true);
    } else if name == "sse.cvtsi2ss" || name == "sse2.cvtsi2sd" || name == "sse.cvtsi642ss" || name == "sse2.cvtsi642sd" {
        rep = builder_cast(b, .SITOFP, a(1), type_elem(cty));
        rep = xb_insert(b, a(0), rep, 0);
    } else if name == "avx512.cvtusi2sd" {
        rep = builder_cast(b, .UITOFP, a(1), type_elem(cty));
        rep = xb_insert(b, a(0), rep, 0);
    } else if name == "sse2.cvtss2sd" {
        rep = xb_extract(b, a(1), 0);
        rep = xb_cast(b, .FPEXT, rep, type_elem(cty));
        rep = xb_insert(b, a(0), rep, 0);
    } else if name == "sse2.cvtdq2pd" || name == "sse2.cvtdq2ps" || name == "avx.cvtdq2.pd.256" || name == "avx.cvtdq2.ps.256" ||
              begins_with(name, "avx512.mask.cvtdq2pd.") || begins_with(name, "avx512.mask.cvtudq2pd.") ||
              begins_with(name, "avx512.mask.cvtdq2ps.") || begins_with(name, "avx512.mask.cvtudq2ps.") ||
              begins_with(name, "avx512.mask.cvtqq2pd.") || begins_with(name, "avx512.mask.cvtuqq2pd.") ||
              name == "avx512.mask.cvtqq2ps.256" || name == "avx512.mask.cvtqq2ps.512" ||
              name == "avx512.mask.cvtuqq2ps.256" || name == "avx512.mask.cvtuqq2ps.512" || name == "sse2.cvtps2pd" ||
              name == "avx.cvt.ps2.pd.256" || name == "avx512.mask.cvtps2pd.128" || name == "avx512.mask.cvtps2pd.256" {
        dt := cty;
        rep = a(0);
        st := vtype(rep);
        if type_count(dt) < type_count(st) rep = xb_shuffle(b, rep, rep, .[0, 1]);
        is_ps2pd := type_elem(st) == type_simple(.FLOAT);
        is_unsigned := contains(name, "cvtu");
        if is_ps2pd rep = xb_cast(b, .FPEXT, rep, dt, "cvtps2pd");
        else if na == 4 && imm_not_4(a(3)) {
            iid := ifx is_unsigned then "llvm.x86.avx512.uitofp.round" else "llvm.x86.avx512.sitofp.round";
            rep = xb_intrinsic(b, iid, .[dt, st], .[rep, a(3)]);
        } else {
            rep = builder_cast(b, ifx is_unsigned then Opcode.UITOFP else .SITOFP, rep, dt, "cvt");
        }
        if na >= 3 rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.mask.vcvtph2ps.") || begins_with(name, "vcvtph2ps.") {
        dt := cty;
        rep = a(0);
        st := vtype(rep);
        n := type_count(dt);
        if n != type_count(st) rep = xb_shuffle(b, rep, rep, .[0, 1, 2, 3]);
        rep = builder_cast(b, .BITCAST, rep, type_vector(n, type_simple(.HALF), false));
        rep = xb_cast(b, .FPEXT, rep, dt, "cvtph2ps");
        if na >= 3 rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.mask.load") {
        aligned := name[16] != #char "u";
        rep = upgrade_masked_load(b, a(0), a(1), a(2), aligned);
    } else if begins_with(name, "avx512.mask.expand.load.") {
        rt := cty;
        pt := vtype(a(0));
        mv := x86_mask_vec(b, a(2), xu_nelts(rt));
        rep = xb_intrinsic(b, "llvm.masked.expandload", .[rt, pt], .[a(0), mv, a(1)]);
    } else if begins_with(name, "avx512.mask.compress.store.") {
        rt := vtype(a(1));
        pt := vtype(a(0));
        mv := x86_mask_vec(b, a(2), xu_nelts(rt));
        rep = xb_intrinsic(b, "llvm.masked.compressstore", .[rt, pt], .[a(1), a(0), mv]);
    } else if begins_with(name, "avx512.mask.compress.") || begins_with(name, "avx512.mask.expand.") {
        rt := cty;
        mv := x86_mask_vec(b, a(2), xu_nelts(rt));
        is_compress := name[12] == #char "c";
        rep = xb_intrinsic(b, ifx is_compress then "llvm.x86.avx512.mask.compress" else "llvm.x86.avx512.mask.expand", .[rt], .[a(0), a(1), mv]);
    } else if begins_with(name, "xop.vpcom") {
        signed: bool;
        if ends_with(name, "ub") || ends_with(name, "uw") || ends_with(name, "ud") || ends_with(name, "uq") signed = false;
        else if ends_with(name, "b") || ends_with(name, "w") || ends_with(name, "d") || ends_with(name, "q") signed = true;
        else xu_fatal_ci("Intrinsic has unknown suffix", ci);
        imm: u64;
        if na == 3 imm = xu_imm(a(2));
        else {
            s := slice(name, 9, name.count - 9);
            if begins_with(s, "lt") imm = 0; else if begins_with(s, "le") imm = 1;
            else if begins_with(s, "gt") imm = 2; else if begins_with(s, "ge") imm = 3;
            else if begins_with(s, "eq") imm = 4; else if begins_with(s, "ne") imm = 5;
            else if begins_with(s, "false") imm = 6; else if begins_with(s, "true") imm = 7;
            else fatal("Unknown condition");
        }
        rep = upgrade_x86_vpcom(b, ci, imm, signed);
    } else if begins_with(name, "xop.vpcmov") {
        sel := a(2);
        not_sel := xb_not(b, sel);
        sel0 := xb_and(b, a(0), sel);
        sel1 := xb_and(b, a(1), not_sel);
        rep = xb_or(b, sel0, sel1);
    } else if begins_with(name, "xop.vprot") || begins_with(name, "avx512.prol") || begins_with(name, "avx512.mask.prol") {
        rep = upgrade_x86_rotate(b, ci, false);
    } else if begins_with(name, "avx512.pror") || begins_with(name, "avx512.mask.pror") {
        rep = upgrade_x86_rotate(b, ci, true);
    } else if begins_with(name, "avx512.vpshld.") || begins_with(name, "avx512.mask.vpshld") || begins_with(name, "avx512.maskz.vpshld") {
        rep = upgrade_x86_concat_shift(b, ci, false, name[11] == #char "z");
    } else if begins_with(name, "avx512.vpshrd.") || begins_with(name, "avx512.mask.vpshrd") || begins_with(name, "avx512.maskz.vpshrd") {
        rep = upgrade_x86_concat_shift(b, ci, true, name[11] == #char "z");
    } else if name == "sse42.crc32.64.8" {
        t0 := builder_cast(b, .TRUNC, a(0), ir.t_i32);
        rep = xb_intrinsic(b, "llvm.x86.sse42.crc32.32.8", .[], .[t0, a(1)]);
        rep = builder_cast(b, .ZEXT, rep, cty);
    } else if begins_with(name, "avx.vbroadcast.s") || begins_with(name, "avx512.vbroadcast.s") {
        et := type_elem(cty);
        n := type_count(cty);
        ld := xb_load(b, et, a(0), dl_abi_align(et));
        rep = const_poison(cty);
        for i: 0..cast(s64) n - 1 rep = builder_insert_element(b, rep, ld, const_int(ir.t_i32, cast(u64) i));
    } else if begins_with(name, "sse41.pmovsx") || begins_with(name, "sse41.pmovzx") || begins_with(name, "avx2.pmovsx") ||
              begins_with(name, "avx2.pmovzx") || begins_with(name, "avx512.mask.pmovsx") || begins_with(name, "avx512.mask.pmovzx") {
        n := xu_nelts(cty);
        sv := xb_shuffle1(b, a(0), xu_iota(n));
        rep = builder_cast(b, ifx contains(name, "pmovsx") then Opcode.SEXT else .ZEXT, sv, cty);
        if na == 3 rep = emit_x86_select(b, a(2), rep, a(1));
    } else if name == "avx512.mask.pmov.qd.256" || name == "avx512.mask.pmov.qd.512" ||
              name == "avx512.mask.pmov.wb.256" || name == "avx512.mask.pmov.wb.512" {
        rep = builder_cast(b, .TRUNC, a(0), vtype(a(1)));
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx.vbroadcastf128") || name == "avx2.vbroadcasti128" {
        et := type_elem(cty);
        nsrc := 128 / type_bits(et);
        vt := type_vector(nsrc, et, false);
        ld := xb_load(b, vt, a(0), 1);
        if nsrc == 2 rep = xb_shuffle1(b, ld, .[0, 1, 0, 1]);
        else rep = xb_shuffle1(b, ld, .[0, 1, 2, 3, 0, 1, 2, 3]);
    } else if begins_with(name, "avx512.mask.shuf.i") || begins_with(name, "avx512.mask.shuf.f") {
        imm := cast(u32) xu_imm(a(2));
        nlanes := xu_vec_bits(cty) / 128;
        nel := 128 / xu_elt_bits(cty);
        ctl_mask := nlanes - 1;
        nctl := nlanes / 2;
        m: [..] u32; m.allocator = temp;
        for l: 0..nlanes - 1 {
            lm := (imm >> (l * nctl)) & ctl_mask;
            if l >= nlanes / 2 lm += nlanes;
            for i: 0..nel - 1 array_add(*m, lm * nel + i);
        }
        rep = xb_shuffle(b, a(0), a(1), m);
        rep = emit_x86_select(b, a(4), rep, a(3));
    } else if begins_with(name, "avx512.mask.broadcastf") || begins_with(name, "avx512.mask.broadcasti") {
        nsrc := xu_nelts(vtype(a(0)));
        ndst := xu_nelts(cty);
        m := NewArray(ndst, u32,, allocator = temp);
        for i: 0..ndst - 1 m[i] = i % nsrc;
        rep = xb_shuffle(b, a(0), a(0), m);
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx2.pbroadcast") || begins_with(name, "avx2.vbroadcast") ||
              begins_with(name, "avx512.pbroadcast") || begins_with(name, "avx512.mask.broadcast.s") {
        n := xu_nelts(cty);
        rep = xb_shuffle1(b, a(0), NewArray(n, u32,, allocator = temp));
        if na == 3 rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "sse2.padds.") || begins_with(name, "avx2.padds.") || begins_with(name, "avx512.padds.") ||
              begins_with(name, "avx512.mask.padds.") {
        rep = upgrade_x86_binary(b, ci, "llvm.sadd.sat");
    } else if begins_with(name, "sse2.psubs.") || begins_with(name, "avx2.psubs.") || begins_with(name, "avx512.psubs.") ||
              begins_with(name, "avx512.mask.psubs.") {
        rep = upgrade_x86_binary(b, ci, "llvm.ssub.sat");
    } else if begins_with(name, "sse2.paddus.") || begins_with(name, "avx2.paddus.") || begins_with(name, "avx512.mask.paddus.") {
        rep = upgrade_x86_binary(b, ci, "llvm.uadd.sat");
    } else if begins_with(name, "sse2.psubus.") || begins_with(name, "avx2.psubus.") || begins_with(name, "avx512.mask.psubus.") {
        rep = upgrade_x86_binary(b, ci, "llvm.usub.sat");
    } else if begins_with(name, "avx512.mask.palignr.") {
        rep = upgrade_x86_align(b, a(0), a(1), a(2), a(3), a(4), false);
    } else if begins_with(name, "avx512.mask.valign.") {
        rep = upgrade_x86_align(b, a(0), a(1), a(2), a(3), a(4), true);
    } else if name == "sse2.psll.dq" || name == "avx2.psll.dq" {
        rep = upgrade_x86_byte_shift(b, a(0), xu_imm(a(1)) / 8, true);
    } else if name == "sse2.psrl.dq" || name == "avx2.psrl.dq" {
        rep = upgrade_x86_byte_shift(b, a(0), xu_imm(a(1)) / 8, false);
    } else if name == "sse2.psll.dq.bs" || name == "avx2.psll.dq.bs" || name == "avx512.psll.dq.512" {
        rep = upgrade_x86_byte_shift(b, a(0), xu_imm(a(1)), true);
    } else if name == "sse2.psrl.dq.bs" || name == "avx2.psrl.dq.bs" || name == "avx512.psrl.dq.512" {
        rep = upgrade_x86_byte_shift(b, a(0), xu_imm(a(1)), false);
    } else if name == "sse41.pblendw" || begins_with(name, "sse41.blendp") || begins_with(name, "avx.blend.p") ||
              name == "avx2.pblendw" || begins_with(name, "avx2.pblendd.") {
        imm := xu_imm(a(2));
        n := xu_nelts(cty);
        idxs := NewArray(n, u32,, allocator = temp);
        for i: 0..n - 1 idxs[i] = ifx ((imm >> (i % 8)) & 1) != 0 then i + n else i;
        rep = xb_shuffle(b, a(0), a(1), idxs);
    } else if begins_with(name, "avx.vinsertf128.") || name == "avx2.vinserti128" || begins_with(name, "avx512.mask.insert") {
        op0 := a(0); op1 := a(1);
        imm := cast(u32) xu_imm(a(2));
        dn := xu_nelts(cty);
        sn := xu_nelts(vtype(op1));
        scale := dn / sn;
        imm = imm % scale;
        idxs := NewArray(dn, u32,, allocator = temp);
        for i: 0..sn - 1 idxs[i] = i;
        for i: sn..dn - 1 idxs[i] = sn;
        rep = xb_shuffle1(b, op1, idxs);
        idxs2 := NewArray(dn, u32,, allocator = temp);
        for i: 0..dn - 1 idxs2[i] = i;
        for i: 0..sn - 1 idxs2[i + imm * sn] = i + dn;
        rep = xb_shuffle(b, op0, rep, idxs2);
        if na == 5 rep = emit_x86_select(b, a(4), rep, a(3));
    } else if begins_with(name, "avx.vextractf128.") || name == "avx2.vextracti128" || begins_with(name, "avx512.mask.vextract") {
        op0 := a(0);
        imm := cast(u32) xu_imm(a(1));
        dn := xu_nelts(cty);
        sn := xu_nelts(vtype(op0));
        scale := sn / dn;
        imm = imm % scale;
        idxs := NewArray(dn, u32,, allocator = temp);
        for i: 0..dn - 1 idxs[i] = i + imm * dn;
        rep = xb_shuffle(b, op0, op0, idxs);
        if na == 4 rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.perm.df.") || begins_with(name, "avx512.mask.perm.di.") {
        op0 := a(0);
        imm := cast(u32) xu_imm(a(1));
        n := xu_nelts(cty);
        idxs := NewArray(n, u32,, allocator = temp);
        for i: 0..n - 1 idxs[i] = (i & ~cast(u32) 3) + ((imm >> (2 * (i & 3))) & 3);
        rep = xb_shuffle(b, op0, op0, idxs);
        if na == 4 rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx.vperm2f128.") || name == "avx2.vperm2i128" {
        imm := cast(u8) (xu_imm(a(2)) & 0xff);
        n := xu_nelts(cty);
        half := n / 2;
        m := NewArray(n, u32,, allocator = temp);
        v0 := ifx imm & 0x02 then a(1) else a(0);
        v1 := ifx imm & 0x20 then a(1) else a(0);
        if imm & 0x08 v0 = const_null_value(cty);
        if imm & 0x80 v1 = const_null_value(cty);
        start: u32 = ifx imm & 0x01 then half else 0;
        for i: 0..half - 1 m[i] = start + i;
        start = ifx imm & 0x10 then half else 0;
        for i: 0..half - 1 m[i + half] = n + start + i;
        rep = xb_shuffle(b, v0, v1, m);
    } else if begins_with(name, "avx.vpermil.") || name == "sse2.pshuf.d" || begins_with(name, "avx512.mask.vpermil.p") ||
              begins_with(name, "avx512.mask.pshuf.d.") {
        op0 := a(0);
        imm := cast(u32) xu_imm(a(1));
        n := xu_nelts(cty);
        isz := 64 / xu_elt_bits(cty);
        imask := (cast(u32) 1 << isz) - 1;
        idxs := NewArray(n, u32,, allocator = temp);
        for i: 0..n - 1 idxs[i] = ((imm >> ((i * isz) % 8)) & imask) | (i & ~imask);
        rep = xb_shuffle(b, op0, op0, idxs);
        if na == 4 rep = emit_x86_select(b, a(3), rep, a(2));
    } else if name == "sse2.pshufl.w" || begins_with(name, "avx512.mask.pshufl.w.") ||
              name == "sse2.pshufh.w" || begins_with(name, "avx512.mask.pshufh.w.") {
        high := name == "sse2.pshufh.w" || begins_with(name, "avx512.mask.pshufh.w.");
        op0 := a(0);
        imm := cast(u32) xu_imm(a(1));
        n := xu_nelts(cty);
        if (name == "sse2.pshufl.w" || name == "sse2.pshufh.w") && n % 8 != 0 xu_fatal_ci("Intrinsic has invalid signature", ci);
        idxs := NewArray(n, u32,, allocator = temp);
        l: u32 = 0;
        while l != n {
            if high {
                for i: 0..cast(u32) 3 idxs[i + l] = i + l;
                for i: 0..cast(u32) 3 idxs[i + l + 4] = ((imm >> (2 * i)) & 3) + 4 + l;
            } else {
                for i: 0..cast(u32) 3 idxs[i + l] = ((imm >> (2 * i)) & 3) + l;
                for i: 4..cast(u32) 7 idxs[i + l] = i + l;
            }
            l += 8;
        }
        rep = xb_shuffle(b, op0, op0, idxs);
        if na == 4 rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.shuf.p") {
        op0 := a(0); op1 := a(1);
        imm := cast(u32) xu_imm(a(2));
        n := xu_nelts(cty);
        nle := 128 / xu_elt_bits(cty);
        hle := nle / 2;
        idxs := NewArray(n, u32,, allocator = temp);
        for i: 0..n - 1 {
            idxs[i] = i - (i % nle);
            if (i % nle) >= hle idxs[i] += n;
            idxs[i] += (imm >> ((i * hle) % 8)) & ((cast(u32) 1 << hle) - 1);
        }
        rep = xb_shuffle(b, op0, op1, idxs);
        rep = emit_x86_select(b, a(4), rep, a(3));
    } else if begins_with(name, "avx512.mask.movddup") || begins_with(name, "avx512.mask.movshdup") || begins_with(name, "avx512.mask.movsldup") {
        op0 := a(0);
        n := xu_nelts(cty);
        nle := 128 / xu_elt_bits(cty);
        off: u32 = ifx begins_with(name, "avx512.mask.movshdup.") then cast(u32) 1 else 0;
        idxs := NewArray(n, u32,, allocator = temp);
        l: u32 = 0;
        while l != n {
            i: u32 = 0;
            while i != nle { idxs[i + l] = i + l + off; idxs[i + l + 1] = i + l + off; i += 2; }
            l += nle;
        }
        rep = xb_shuffle(b, op0, op0, idxs);
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.mask.punpckl") || begins_with(name, "avx512.mask.unpckl.") ||
              begins_with(name, "avx512.mask.punpckh") || begins_with(name, "avx512.mask.unpckh.") {
        high := begins_with(name, "avx512.mask.punpckh") || begins_with(name, "avx512.mask.unpckh.");
        op0 := a(0); op1 := a(1);
        n := xu_nelts(cty);
        nle := 128 / xu_elt_bits(cty);
        idxs := NewArray(n, u32,, allocator = temp);
        l: u32 = 0;
        while l != n {
            for i: 0..nle - 1 idxs[i + l] = (ifx high then nle / 2 else 0) + l + (i / 2) + n * (i % 2);
            l += nle;
        }
        rep = xb_shuffle(b, op0, op1, idxs);
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.and.") || begins_with(name, "avx512.mask.pand.") ||
              begins_with(name, "avx512.mask.andn.") || begins_with(name, "avx512.mask.pandn.") ||
              begins_with(name, "avx512.mask.or.") || begins_with(name, "avx512.mask.por.") ||
              begins_with(name, "avx512.mask.xor.") || begins_with(name, "avx512.mask.pxor.") {
        fty := cty;
        ity := xu_int_vec_type(fty);
        if begins_with(name, "avx512.mask.andn.") || begins_with(name, "avx512.mask.pandn.") {
            rep = xb_not(b, builder_cast(b, .BITCAST, a(0), ity));
            rep = xb_and(b, rep, builder_cast(b, .BITCAST, a(1), ity));
        } else {
            l := builder_cast(b, .BITCAST, a(0), ity);
            r := builder_cast(b, .BITCAST, a(1), ity);
            if begins_with(name, "avx512.mask.and.") || begins_with(name, "avx512.mask.pand.") rep = xb_and(b, l, r);
            else if begins_with(name, "avx512.mask.or.") || begins_with(name, "avx512.mask.por.") rep = xb_or(b, l, r);
            else rep = xb_xor(b, l, r);
        }
        rep = builder_cast(b, .BITCAST, rep, fty);
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.padd.") {
        rep = builder_binop(b, .ADD, a(0), a(1));
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.psub.") {
        rep = builder_binop(b, .SUB, a(0), a(1));
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.pmull.") {
        rep = builder_binop(b, .MUL, a(0), a(1));
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.add.p") || begins_with(name, "avx512.mask.div.p") ||
              begins_with(name, "avx512.mask.mul.p") || begins_with(name, "avx512.mask.sub.p") {
        op := slice(name, 12, 3);   // add / div / mul / sub
        if ends_with(name, ".512") {
            iid := tprint("llvm.x86.avx512.%.%.512", op, ifx name[17] == #char "s" then "ps" else "pd");
            rep = xb_intrinsic(b, iid, .[], .[a(0), a(1), a(4)]);
        } else {
            opc: Opcode;
            if op == "add" opc = .FADD; else if op == "div" opc = .FDIV; else if op == "mul" opc = .FMUL; else opc = .FSUB;
            rep = builder_binop(b, opc, a(0), a(1));
        }
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if (begins_with(name, "avx512.mask.max.p") || begins_with(name, "avx512.mask.min.p")) && name.count >= 18 &&
              slice(name, 18, name.count - 18) == ".512" {
        is_double := name[17] == #char "d";
        is_min := name[13] == #char "i";
        iid := tprint("llvm.x86.avx512.%.%.512", ifx is_min then "min" else "max", ifx is_double then "pd" else "ps");
        rep = xb_intrinsic(b, iid, .[], .[a(0), a(1), a(4)]);
        rep = emit_x86_select(b, a(3), rep, a(2));
    } else if begins_with(name, "avx512.mask.lzcnt.") {
        rep = xb_intrinsic(b, "llvm.ctlz", .[cty], .[a(0), const_int(ir.t_i1, 0)]);
        rep = emit_x86_select(b, a(2), rep, a(1));
    } else if begins_with(name, "avx512.mask.psll") {
        rep = upgrade_x86_masked_shift(b, ci, x86(avx512_masked_shift_iid(name, #char "l", ci)));
    } else if begins_with(name, "avx512.mask.psrl") {
        rep = upgrade_x86_masked_shift(b, ci, x86(avx512_masked_shift_iid(name, #char "r", ci)));
    } else if begins_with(name, "avx512.mask.psra") {
        rep = upgrade_x86_masked_shift(b, ci, x86(avx512_masked_shift_iid(name, #char "a", ci)));
    } else if begins_with(name, "avx512.mask.move.s") {
        rep = upgrade_masked_move(b, ci);
    } else if begins_with(name, "avx512.cvtmask2") {
        rep = upgrade_mask_to_int(b, ci);
    } else if ends_with(name, ".movntdqa") {
        li := xb_load(b, cty, a(0), xu_vec_bits(cty) / 8);
        set_metadata(li, md_kind_id("nontemporal"), nontemporal());
        rep = li;
    } else if begins_with(name, "fma.vfmadd.") || begins_with(name, "fma.vfmsub.") || begins_with(name, "fma.vfnmadd.") ||
              begins_with(name, "fma.vfnmsub.") {
        neg_mul := name[6] == #char "n";
        neg_acc := ifx neg_mul then name[8] == #char "s" else name[7] == #char "s";
        is_scalar := ifx neg_mul then name[12] == #char "s" else name[11] == #char "s";
        ops := Value_Id.[a(0), a(1), a(2)];
        if is_scalar { ops[0] = xb_extract(b, ops[0], 0); ops[1] = xb_extract(b, ops[1], 0); ops[2] = xb_extract(b, ops[2], 0); }
        if neg_mul && !is_scalar ops[0] = xb_fneg(b, ops[0]);
        if neg_mul && is_scalar ops[1] = xb_fneg(b, ops[1]);
        if neg_acc ops[2] = xb_fneg(b, ops[2]);
        rep = xb_intrinsic(b, "llvm.fma", .[vtype(ops[0])], ops);
        if is_scalar rep = xb_insert(b, a(0), rep, 0);
    } else if begins_with(name, "fma4.vfmadd.s") {
        ops := Value_Id.[xb_extract(b, a(0), 0), NONE, NONE];
        ops[1] = xb_extract(b, a(1), 0);
        ops[2] = xb_extract(b, a(2), 0);
        rep = xb_intrinsic(b, "llvm.fma", .[vtype(ops[0])], ops);
        rep = xb_insert(b, const_null_value(cty), rep, 0);
    } else if begins_with(name, "avx512.mask.vfmadd.s") || begins_with(name, "avx512.maskz.vfmadd.s") ||
              begins_with(name, "avx512.mask3.vfmadd.s") || begins_with(name, "avx512.mask3.vfmsub.s") ||
              begins_with(name, "avx512.mask3.vfnmsub.s") {
        is_mask3 := name[11] == #char "3";
        is_maskz := name[11] == #char "z";
        n := ifx is_mask3 || is_maskz then 13 else 12;
        nm := slice(name, n, name.count - n);
        neg_mul := nm[2] == #char "n";
        neg_acc := ifx neg_mul then nm[4] == #char "s" else nm[3] == #char "s";
        av := a(0); bv := a(1); cv := a(2);
        if neg_mul && (is_mask3 || is_maskz) av = xb_fneg(b, av);
        if neg_mul && !(is_mask3 || is_maskz) bv = xb_fneg(b, bv);
        if neg_acc cv = xb_fneg(b, cv);
        av = xb_extract(b, av, 0);
        bv = xb_extract(b, bv, 0);
        cv = xb_extract(b, cv, 0);
        if imm_not_4(a(4)) {
            iid := ifx nm[nm.count - 1] == #char "d" then "llvm.x86.avx512.vfmadd.f64" else "llvm.x86.avx512.vfmadd.f32";
            rep = xb_intrinsic(b, iid, .[], .[av, bv, cv, a(4)]);
        } else rep = xb_intrinsic(b, "llvm.fma", .[vtype(av)], .[av, bv, cv]);
        pass := ifx is_maskz then const_null_value(vtype(rep)) else ifx is_mask3 then cv else av;
        if neg_acc && is_mask3 pass = xb_extract(b, a(2), 0);
        rep = emit_x86_scalar_select(b, a(3), rep, pass);
        rep = xb_insert(b, a(ifx is_mask3 then cast(u32) 2 else 0), rep, 0);
    } else if begins_with(name, "avx512.mask.vfmadd.p") || begins_with(name, "avx512.mask.vfnmadd.p") ||
              begins_with(name, "avx512.mask.vfnmsub.p") || begins_with(name, "avx512.mask3.vfmadd.p") ||
              begins_with(name, "avx512.mask3.vfmsub.p") || begins_with(name, "avx512.mask3.vfnmsub.p") ||
              begins_with(name, "avx512.maskz.vfmadd.p") {
        is_mask3 := name[11] == #char "3";
        is_maskz := name[11] == #char "z";
        n := ifx is_mask3 || is_maskz then 13 else 12;
        nm := slice(name, n, name.count - n);
        neg_mul := nm[2] == #char "n";
        neg_acc := ifx neg_mul then nm[4] == #char "s" else nm[3] == #char "s";
        av := a(0); bv := a(1); cv := a(2);
        if neg_mul && (is_mask3 || is_maskz) av = xb_fneg(b, av);
        if neg_mul && !(is_mask3 || is_maskz) bv = xb_fneg(b, bv);
        if neg_acc cv = xb_fneg(b, cv);
        if na == 5 && imm_not_4(a(4)) {
            iid := ifx nm[nm.count - 5] == #char "s" then "llvm.x86.avx512.vfmadd.ps.512" else "llvm.x86.avx512.vfmadd.pd.512";
            rep = xb_intrinsic(b, iid, .[], .[av, bv, cv, a(4)]);
        } else rep = xb_intrinsic(b, "llvm.fma", .[vtype(av)], .[av, bv, cv]);
        pass := ifx is_maskz then const_null_value(cty) else ifx is_mask3 then a(2) else a(0);
        rep = emit_x86_select(b, a(3), rep, pass);
    } else if begins_with(name, "fma.vfmsubadd.p") {
        vw := xu_vec_bits(cty); ew := xu_elt_bits(cty);
        iid: string;
        if vw == 128 && ew == 32 iid = "fma.vfmaddsub.ps"; else if vw == 256 && ew == 32 iid = "fma.vfmaddsub.ps.256";
        else if vw == 128 && ew == 64 iid = "fma.vfmaddsub.pd"; else if vw == 256 && ew == 64 iid = "fma.vfmaddsub.pd.256";
        else xu_fatal_ci("Unexpected intrinsic", ci);
        ops := Value_Id.[a(0), a(1), a(2)];
        ops[2] = xb_fneg(b, ops[2]);
        rep = xb_intrinsic(b, x86(iid), .[], ops);
    } else if begins_with(name, "avx512.mask.vfmaddsub.p") || begins_with(name, "avx512.mask3.vfmaddsub.p") ||
              begins_with(name, "avx512.maskz.vfmaddsub.p") || begins_with(name, "avx512.mask3.vfmsubadd.p") {
        is_mask3 := name[11] == #char "3";
        is_maskz := name[11] == #char "z";
        n := ifx is_mask3 || is_maskz then 13 else 12;
        nm := slice(name, n, name.count - n);
        is_subadd := nm[3] == #char "s";
        if na == 5 {
            iid := ifx nm[nm.count - 5] == #char "s" then "llvm.x86.avx512.vfmaddsub.ps.512" else "llvm.x86.avx512.vfmaddsub.pd.512";
            ops := Value_Id.[a(0), a(1), a(2), a(4)];
            if is_subadd ops[2] = xb_fneg(b, ops[2]);
            rep = xb_intrinsic(b, iid, .[], ops);
        } else {
            ne := xu_nelts(cty);
            ops := Value_Id.[a(0), a(1), a(2)];
            fma := decl("llvm.fma", .[vtype(ops[0])]);
            odd := builder_call(b, fma, ops);
            ops[2] = xb_fneg(b, ops[2]);
            even := builder_call(b, fma, ops);
            if is_subadd { t := even; even = odd; odd = t; }
            idxs := NewArray(ne, u32,, allocator = temp);
            for i: 0..ne - 1 idxs[i] = i + (i % 2) * ne;
            rep = xb_shuffle(b, even, odd, idxs);
        }
        pass := ifx is_maskz then const_null_value(cty) else ifx is_mask3 then a(2) else a(0);
        rep = emit_x86_select(b, a(3), rep, pass);
    } else if begins_with(name, "avx512.mask.pternlog.") || begins_with(name, "avx512.maskz.pternlog.") {
        zero_mask := name[11] == #char "z";
        vw := xu_vec_bits(cty); ew := xu_elt_bits(cty);
        if (vw != 128 && vw != 256 && vw != 512) || (ew != 32 && ew != 64) xu_fatal_ci("Unexpected intrinsic", ci);
        rep = xb_intrinsic(b, x86(tprint("avx512.pternlog.%.%", ifx ew == 32 then "d" else "q", vw)), .[], .[a(0), a(1), a(2), a(3)]);
        pass := ifx zero_mask then const_null_value(cty) else a(0);
        rep = emit_x86_select(b, a(4), rep, pass);
    } else if begins_with(name, "avx512.mask.vpmadd52") || begins_with(name, "avx512.maskz.vpmadd52") {
        zero_mask := name[11] == #char "z";
        high := name[20] == #char "h" || name[21] == #char "h";
        vw := xu_vec_bits(cty);
        if vw != 128 && vw != 256 && vw != 512 xu_fatal_ci("Unexpected intrinsic", ci);
        rep = xb_intrinsic(b, x86(tprint("avx512.vpmadd52%.uq.%", ifx high then "h" else "l", vw)), .[], .[a(0), a(1), a(2)]);
        pass := ifx zero_mask then const_null_value(cty) else a(0);
        rep = emit_x86_select(b, a(3), rep, pass);
    } else if begins_with(name, "avx512.mask.vpermi2var.") || begins_with(name, "avx512.mask.vpermt2var.") ||
              begins_with(name, "avx512.maskz.vpermt2var.") {
        rep = upgrade_x86_vpermt2(b, ci, name[11] == #char "z", name[17] == #char "i");
    } else if begins_with(name, "avx512.mask.vpdpbusd.") || begins_with(name, "avx512.maskz.vpdpbusd.") ||
              begins_with(name, "avx512.mask.vpdpbusds.") || begins_with(name, "avx512.maskz.vpdpbusds.") ||
              begins_with(name, "avx512.mask.vpdpwssd.") || begins_with(name, "avx512.maskz.vpdpwssd.") ||
              begins_with(name, "avx512.mask.vpdpwssds.") || begins_with(name, "avx512.maskz.vpdpwssds.") {
        zero_mask := name[11] == #char "z";
        saturating := name[ifx zero_mask then 21 else 20] == #char "s";
        is_bytes := contains(name, "vpdpbusd");
        vw := xu_vec_bits(cty);
        if vw != 128 && vw != 256 && vw != 512 xu_fatal_ci("Unexpected intrinsic", ci);
        iid := x86(tprint("avx512.%0%.%", ifx is_bytes then "vpdpbusd" else "vpdpwssd", ifx saturating then "s" else "", vw));
        args := Value_Id.[a(0), a(1), a(2)];
        is_i32_vec :: (t: Type_Id) -> bool { return is_vector_type(t) && type_elem(t) == ir.t_i32; }
        if is_i32_vec(vtype(args[1])) && is_i32_vec(vtype(args[2])) {
            elt: u32 = ifx is_bytes then cast(u32) 8 else 16;
            nt := type_vector(vw / elt, type_int(elt), false);
            args[1] = builder_cast(b, .BITCAST, args[1], nt);
            args[2] = builder_cast(b, .BITCAST, args[2], nt);
        }
        rep = xb_intrinsic(b, iid, .[], args);
        pass := ifx zero_mask then const_null_value(cty) else a(0);
        rep = emit_x86_select(b, a(3), rep, pass);
    } else if name == "addcarryx.u32" || name == "addcarryx.u64" || name == "addcarry.u32" || name == "addcarry.u64" ||
              name == "subborrow.u32" || name == "subborrow.u64" {
        last := name[name.count - 1];
        iid: string;
        if name[0] == #char "a" && last == #char "2" iid = "addcarry.32";
        else if name[0] == #char "a" && last == #char "4" iid = "addcarry.64";
        else if name[0] == #char "s" && last == #char "2" iid = "subborrow.32";
        else iid = "subborrow.64";
        nc := xb_intrinsic(b, x86(iid), .[], .[a(0), a(1), a(2)]);
        data := builder_extractvalue(b, nc, 1);
        builder_store(b, data, a(3), 1);
        cf := builder_extractvalue(b, nc, 0);
        replace_all_uses_with(ci, cf);
        rep = NONE;
    } else if begins_with(name, "avx512.mask.") {
        ok, r := upgrade_avx512_mask_to_select(slice(name, 12, name.count - 12), b, ci);
        if !ok xu_fatal_ci("Unexpected intrinsic", ci);
        rep = r;
    } else if begins_with(name, "bmi.pdep.") {
        rep = upgrade_x86_binary(b, ci, "llvm.pdep");
    } else if begins_with(name, "bmi.pext.") {
        rep = upgrade_x86_binary(b, ci, "llvm.pext");
    } else xu_fatal_ci("Unexpected intrinsic", ci);
    return rep;
}

// ---------------------------------------------------------------- upgradeX86IntrinsicFunction

// upgradeX86IntrinsicFunction (name without "llvm."): calls rewritten (new_fn NONE), or a declaration that
// replaces one with an old signature (the old one is renamed to <name>.old)
upgrade_x86_intrinsic_function :: (f: Value_Id, name_in: string) -> Upgrade_Result {
    name := name_in;
    res: Upgrade_Result;
    if !consume_front(*name, "x86.") return res;
    if should_upgrade_x86_intrinsic(f, name) { res.upgraded = true; return res; }   // calls are rewritten
    ft := glob(f).value_type;
    replace :: (f: Value_Id, new_name: string) -> Upgrade_Result {
        rename_old(f);
        return found(decl(new_name));
    }
    if name == "rdtscp" {
        if func_nparams(ft) == 0 return res;
        return replace(f, "llvm.x86.rdtscp");
    }
    if consume_front(*name, "sse41.ptest") {
        if name == "c" || name == "z" || name == "nzc" {
            // upgradePTESTIntrinsic: the arguments were v4f32
            if func_param(ft, 0) != type_vector(4, type_simple(.FLOAT), false) return res;
            return replace(f, tprint("llvm.x86.sse41.ptest%", name));
        }
        return res;
    }
    if name == "sse41.insertps" || name == "sse41.dppd" || name == "sse41.dpps" || name == "sse41.mpsadbw" ||
       name == "avx.dp.ps.256" || name == "avx2.mpsadbw" {
        // upgradeX86IntrinsicsWith8BitMask: the last argument was i32
        if func_param(ft, func_nparams(ft) - 1) != ir.t_i32 return res;
        return replace(f, tprint("llvm.x86.%", name));
    }
    full := tprint("llvm.x86.%", name);
    elt := x86_multiply_add_input_elt_bits(name);
    if begins_with(name, "avx512.") {
        rest := slice(name, 7, name.count - 7);
        if begins_with(rest, "mask.cmp.") {
            s := slice(rest, 9, rest.count - 9);
            if s == "pd.128" || s == "pd.256" || s == "pd.512" || s == "ps.128" || s == "ps.256" || s == "ps.512" {
                // upgradeX86MaskedFPCompare: the result was a scalar mask
                if is_vector_type(func_ret(ft)) return res;
                return replace(f, full);
            }
        } else if elt {
            // upgradeX86MultiplyAddBytes / Words: the inputs were i32 vectors
            a1 := func_param(ft, 1); a2 := func_param(ft, 2);
            ok_ty :: (t: Type_Id, bits: u32) -> bool { return is_vector_type(t) && type_elem(t) == type_int(bits); }
            if ok_ty(a1, elt) && ok_ty(a2, elt) return res;
            return replace(f, full);
        }
        return res;
    }
    if begins_with(name, "avx2.") || begins_with(name, "avx10.") {
        if elt {
            a1 := func_param(ft, 1); a2 := func_param(ft, 2);
            ok_ty :: (t: Type_Id, bits: u32) -> bool { return is_vector_type(t) && type_elem(t) == type_int(bits); }
            if ok_ty(a1, elt) && ok_ty(a2, elt) return res;
            return replace(f, full);
        }
        return res;
    }
    if consume_front(*name, "avx512bf16.") {
        if name == "cvtne2ps2bf16.128" || name == "cvtne2ps2bf16.256" || name == "cvtne2ps2bf16.512" ||
           name == "mask.cvtneps2bf16.128" || name == "cvtneps2bf16.256" || name == "cvtneps2bf16.512" {
            // upgradeX86BF16Intrinsic
            if scalar_type(func_ret(ft)) == type_simple(.BFLOAT) return res;
            return replace(f, full);
        }
        if name == "dpbf16ps.128" || name == "dpbf16ps.256" || name == "dpbf16ps.512" {
            // upgradeX86BF16DPIntrinsic
            if scalar_type(func_param(ft, 1)) == type_simple(.BFLOAT) return res;
            return replace(f, full);
        }
        return res;
    }
    if consume_front(*name, "xop.") {
        new_name: string;
        if begins_with(name, "vpermil2") {
            idx := func_param(ft, 2);
            if is_fp_type(scalar_type(idx)) {
                isz := xu_vec_bits(idx); esz := xu_elt_bits(idx);
                if esz == 64 && isz == 128 new_name = "llvm.x86.xop.vpermil2pd";
                else if esz == 32 && isz == 128 new_name = "llvm.x86.xop.vpermil2ps";
                else if esz == 64 && isz == 256 new_name = "llvm.x86.xop.vpermil2pd.256";
                else new_name = "llvm.x86.xop.vpermil2ps.256";
            }
        } else if func_nparams(ft) == 2 {
            if name == "vfrcz.ss" new_name = "llvm.x86.xop.vfrcz.ss";
            else if name == "vfrcz.sd" new_name = "llvm.x86.xop.vfrcz.sd";
        }
        if new_name.count return replace(f, new_name);
        return res;
    }
    if name == "seh.recoverfp" return found(decl("llvm.eh.recoverfp"));
    return res;
}

// The x86 cases of UpgradeIntrinsicCall's switch on NewFn's intrinsic (false = not one of them)
upgrade_x86_call_to_new_fn :: (ci: Value_Id, f: Value_Id, new_fn: Value_Id, b: *Builder) -> bool {
    nname := vname(new_fn);
    if !begins_with(nname, "llvm.x86.") return false;
    n := slice(nname, 9, nname.count - 9);
    na := call_nargs(ci);
    a :: (i: u32) -> Value_Id #expand { return call_arg(`ci, i); }
    args :: () -> [..] Value_Id #expand {
        r: [..] Value_Id; r.allocator = temp;
        for i: 0..cast(s64) `na - 1 array_add(*r, call_arg(`ci, cast(u32) i));
        return r;
    }
    new_call: Value_Id = NONE;
    if n == "xop.vfrcz.ss" || n == "xop.vfrcz.sd" {
        new_call = builder_call(b, new_fn, .[a(1)]);
    } else if begins_with(n, "xop.vpermil2") {
        r := args();
        r[2] = builder_cast(b, .BITCAST, r[2], xu_int_vec_type(vtype(r[2])));
        new_call = builder_call(b, new_fn, r);
    } else if n == "sse41.ptestc" || n == "sse41.ptestz" || n == "sse41.ptestnzc" {
        if vtype(a(0)) != type_vector(4, type_simple(.FLOAT), false) return true;
        nt := type_vector(2, ir.t_i64, false);
        bc0 := builder_cast(b, .BITCAST, a(0), nt, "cast");
        bc1 := builder_cast(b, .BITCAST, a(1), nt, "cast");
        new_call = builder_call(b, new_fn, .[bc0, bc1]);
    } else if n == "rdtscp" {
        if nops(ci) == 0 return true;   // (CI->getNumOperands() counts the callee: never 0)
        new_call = builder_call(b, new_fn, .[]);
        data := builder_extractvalue(b, new_call, 1);
        builder_store(b, data, a(0), 1);
        tsc := builder_extractvalue(b, new_call, 0);
        take_name(new_call, ci);
        replace_and_erase(ci, tsc);
        return true;
    } else if n == "sse41.insertps" || n == "sse41.dppd" || n == "sse41.dpps" || n == "sse41.mpsadbw" ||
              n == "avx.dp.ps.256" || n == "avx2.mpsadbw" {
        r := args();
        r[r.count - 1] = builder_cast(b, .TRUNC, r[r.count - 1], ir.t_i8, "trunc");
        new_call = builder_call(b, new_fn, r);
    } else if begins_with(n, "avx512.mask.cmp.p") {
        r := args();
        r[3] = x86_mask_vec(b, r[3], xu_nelts(vtype(r[0])));
        new_call = builder_call(b, new_fn, r);
        res := apply_x86_mask_on_1bits_vec(b, new_call, NONE);
        take_name(new_call, ci);
        replace_and_erase(ci, res);
        return true;
    } else if begins_with(n, "avx512bf16.cvtne2ps2bf16.") || n == "avx512bf16.mask.cvtneps2bf16.128" ||
              n == "avx512bf16.cvtneps2bf16.256" || n == "avx512bf16.cvtneps2bf16.512" {
        r := args();
        ne := type_count(vtype(ci));
        if n == "avx512bf16.mask.cvtneps2bf16.128" r[1] = builder_cast(b, .BITCAST, r[1], type_vector(ne, type_simple(.BFLOAT), false));
        new_call = builder_call(b, new_fn, r);
        res := builder_cast(b, .BITCAST, new_call, type_vector(ne, type_int(16), false));
        take_name(new_call, ci);
        replace_and_erase(ci, res);
        return true;
    } else if begins_with(n, "avx512bf16.dpbf16ps.") {
        r := args();
        ne := type_count(vtype(ci)) * 2;
        bt := type_vector(ne, type_simple(.BFLOAT), false);
        r[1] = builder_cast(b, .BITCAST, r[1], bt);
        r[2] = builder_cast(b, .BITCAST, r[2], bt);
        new_call = builder_call(b, new_fn, r);
    } else return false;
    take_name(new_call, ci);
    replace_and_erase(ci, new_call);
    return true;
}
