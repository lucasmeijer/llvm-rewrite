// ExpandReductions: port of llvm/lib/CodeGen/ExpandReductions.cpp (expandReductions) with the LoopUtils.cpp helpers it
// uses (getShuffleReduction, getOrderedReduction, createMinMaxOp, getArithmeticReductionInstruction,
// getMinMaxReductionRecurKind) and X86TTIImpl::shouldExpandReduction. expandReductionViaLoop (scalable vectors) is
// not ported (fails loudly).

// IRBuilder<> with FastMathFlags `fmf` (ConstantFolder)
er_binop :: (b: *Irb, opc: Opcode, l: Value_Id, r: Value_Id, fmf: u32, name: string) -> Value_Id {
    fp := opc == .FADD || opc == .FSUB || opc == .FMUL || opc == .FDIV || opc == .FREM;
    if irb_is_const(l) && irb_is_const(r) return irb_binop(b, opc, l, r, name);
    v := irb_binop(b, opc, l, r, name);
    if fp && is_inst(v) set_fmf(v, fmf);
    return v;
}
// CreateExtractElement(V, Builder.getInt32(Idx))
er_extract_i32 :: (b: *Irb, v: Value_Id, idx: u64) -> Value_Id {
    ix := const_int(ir.t_i32, idx);
    if irb_is_const(v) return ce_extract_element(v, ix);
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, ix);
    return irb_insert(b, i, "");
}

// createMinMaxOp(Builder, RK, L, R) for the kinds ExpandReductions passes (FMax, FMin, FMaximum, FMinimum)
er_min_max_op :: (b: *Irb, id: Intrinsic_Id, l: Value_Id, r: Value_Id, fmf: u32, f: Value_Id) -> Value_Id {
    ty := vtype(l);
    if id == IID_VECTOR_REDUCE_FMAXIMUM || id == IID_VECTOR_REDUCE_FMINIMUM {
        name := ifx id == IID_VECTOR_REDUCE_FMAXIMUM then "llvm.maximum" else "llvm.minimum";
        if irb_is_const(l) && irb_is_const(r) fatal("expand-reductions: constant-folding % is not supported yet", name);
        c := irb_intrinsic(b, name, .[ty], .[l, r]);
        set_fmf(c, fmf);
        set_name(c, "rdx.minmax");
        return c;
    }
    // FMax / FMin: fcmp ogt / olt + select
    pred: u8 = cast(u8) ifx id == IID_VECTOR_REDUCE_FMAX then FCMP_OGT else FCMP_OLT;
    cmp: Value_Id;
    if irb_is_const(l) && irb_is_const(r) {
        cmp = cf_compare(pred, l, r);
        if cmp == NONE fatal("expand-reductions: constant fcmp did not fold");
    } else cmp = irb_insert(b, create_fcmp(pred, l, r, fmf), "rdx.minmax.cmp");
    sel: Value_Id;
    if irb_is_const(cmp) && irb_is_const(l) && irb_is_const(r) {
        sel = cf_select(cmp, l, r);
        if sel == NONE fatal("expand-reductions: constant select did not fold");
    } else {
        sel = irb_insert(b, create_select(cmp, l, r), "rdx.minmax.select");
        set_fmf(sel, fmf);
        ok, ec := ic_fn_entry_count(f);
        if ok && ec != 0 fatal("expand-reductions: profiled functions (unknown branch weights) are not supported yet");
    }
    return sel;
}

// getShuffleReduction(Builder, Src, Op, SplitHalf, RK)
er_shuffle_reduction :: (b: *Irb, src: Value_Id, opc: Opcode, id: Intrinsic_Id, fmf: u32, f: Value_Id) -> Value_Id {
    vf := cast(u32) type_count(vtype(src));
    tmp := src;
    mask := NewArray(vf, u32,, temp);
    i := vf;
    while i != 1 {
        for j: 0..i/2-1 mask[j] = i / 2 + j;
        for j: i/2..vf-1 mask[j] = 0xFFFF_FFFF;
        shuf := irb_shuffle(b, tmp, NONE, mask, "rdx.shuf");
        if opc == .FCMP tmp = er_min_max_op(b, id, tmp, shuf, fmf, f);
        else tmp = er_binop(b, opc, tmp, shuf, fmf, "bin.rdx");
        i >>= 1;
    }
    return er_extract_i32(b, tmp, 0);
}

// getOrderedReduction(Builder, Acc, Src, Op, RK) (fadd / fmul only here)
er_ordered_reduction :: (b: *Irb, acc: Value_Id, src: Value_Id, opc: Opcode, fmf: u32) -> Value_Id {
    vf := type_count(vtype(src));
    result := acc;
    for k: 0..cast(s64) vf - 1 {
        ext := er_extract_i32(b, src, cast(u64) k);
        result = er_binop(b, opc, result, ext, fmf, "bin.rdx");
    }
    return result;
}

er_is_pow2 :: (n: u64) -> bool { return n != 0 && (n & (n - 1)) == 0; }

expand_reductions_run :: (f: Value_Id) -> Preserved {
    worklist: [..] Value_Id; worklist.allocator = temp;
    for i: fn_insts(f) {
        id := call_iid(i);
        if id == IID_VECTOR_REDUCE_FADD || id == IID_VECTOR_REDUCE_FMUL || id == IID_VECTOR_REDUCE_ADD ||
           id == IID_VECTOR_REDUCE_AND || id == IID_VECTOR_REDUCE_OR || id == IID_VECTOR_REDUCE_XOR ||
           id == IID_VECTOR_REDUCE_FMAX || id == IID_VECTOR_REDUCE_FMIN || id == IID_VECTOR_REDUCE_FMAXIMUM ||
           id == IID_VECTOR_REDUCE_FMINIMUM {
            // X86TTIImpl::shouldExpandReduction: true except mul / smax / smin / umax / umin
            array_add(*worklist, i);
        } else if id == IID_VECTOR_REDUCE_MUL || id == IID_VECTOR_REDUCE_SMAX || id == IID_VECTOR_REDUCE_SMIN ||
                  id == IID_VECTOR_REDUCE_UMAX || id == IID_VECTOR_REDUCE_UMIN {
            if tti_get(f).kind != .X86 array_add(*worklist, i);
        }
    }
    changed := false;
    for ii: worklist {
        fmf := ifx is_fp_math_operator(ii) then inst_fmf(ii) else 0;   // getFastMathFlagsOrNone
        id := call_iid(ii);
        b: Irb;
        irb_set_before(*b, ii);
        rdx: Value_Id = NONE;
        if id == IID_VECTOR_REDUCE_FADD || id == IID_VECTOR_REDUCE_FMUL {
            acc := call_arg(ii, 0);
            vec := call_arg(ii, 1);
            opc := ifx id == IID_VECTOR_REDUCE_FADD then Opcode.FADD else .FMUL;
            if type_kind(vtype(vec)) == .SVECTOR fatal("expand-reductions: scalable-vector reductions (expandReductionViaLoop) are not supported yet");
            if (fmf & FMF_REASSOC) == 0 rdx = er_ordered_reduction(*b, acc, vec, opc, fmf);
            else {
                if !er_is_pow2(type_count(vtype(vec))) continue;
                rdx = er_shuffle_reduction(*b, vec, opc, id, fmf, f);
                rdx = er_binop(*b, opc, acc, rdx, fmf, "bin.rdx");
            }
        } else if id == IID_VECTOR_REDUCE_AND || id == IID_VECTOR_REDUCE_OR {
            vec := call_arg(ii, 0);
            n := type_count(vtype(vec));
            if !er_is_pow2(n) continue;
            if type_elem(vtype(vec)) == ir.t_i1 {
                rdx = irb_bitcast(*b, vec, type_int(n));
                if id == IID_VECTOR_REDUCE_AND rdx = irb_icmp(*b, ICMP_EQ, rdx, cf_all_ones(vtype(rdx)));
                else rdx = irb_icmp(*b, ICMP_NE, rdx, const_null_value(vtype(rdx)));
            } else {
                rdx = er_shuffle_reduction(*b, vec, ifx id == IID_VECTOR_REDUCE_AND then Opcode.AND else .OR, id, fmf, f);
            }
        } else if id == IID_VECTOR_REDUCE_ADD || id == IID_VECTOR_REDUCE_XOR || id == IID_VECTOR_REDUCE_MUL {
            vec := call_arg(ii, 0);
            if type_kind(vtype(vec)) == .SVECTOR fatal("expand-reductions: scalable-vector reductions (expandReductionViaLoop) are not supported yet");
            if !er_is_pow2(type_count(vtype(vec))) continue;
            opc := ifx id == IID_VECTOR_REDUCE_ADD then Opcode.ADD else ifx id == IID_VECTOR_REDUCE_XOR then Opcode.XOR else .MUL;
            rdx = er_shuffle_reduction(*b, vec, opc, id, fmf, f);
        } else if id == IID_VECTOR_REDUCE_FMAX || id == IID_VECTOR_REDUCE_FMIN {
            vec := call_arg(ii, 0);
            if !er_is_pow2(type_count(vtype(vec))) || (fmf & FMF_NNAN) == 0 continue;
            rdx = er_shuffle_reduction(*b, vec, .FCMP, id, fmf, f);
        } else if id == IID_VECTOR_REDUCE_FMAXIMUM || id == IID_VECTOR_REDUCE_FMINIMUM {
            vec := call_arg(ii, 0);
            if !er_is_pow2(type_count(vtype(vec))) continue;
            rdx = er_shuffle_reduction(*b, vec, .FCMP, id, fmf, f);
        } else {
            fatal("expand-reductions: integer min/max reductions are not supported yet");
        }
        replace_all_uses_with(ii, rdx);
        erase_inst(ii);
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    // the legacy pass preserves the DominatorTree and LoopInfo (no CFG change without expandReductionViaLoop)
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    return pa;
}
