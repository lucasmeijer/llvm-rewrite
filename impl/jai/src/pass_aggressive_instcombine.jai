// AggressiveInstCombine: port of llvm/lib/Transforms/AggressiveInstCombine/AggressiveInstCombine.cpp
// (TruncInstCombine.cpp is aic_trunc.jai). The pass uses AC, TLI, DT, TTI and AA like LLVM's
// AggressiveInstCombinePass::run; the per-call DomTreeUpdater of foldLibCalls is a lazy `Dtu` flushed when the
// call returns (LLVM's destructor). Two TTI queries that only this pass makes are here: haveFastSqrt
// (BasicTTIImpl) and allowsMisalignedMemoryAccesses (X86TargetLowering).

aic_cl: struct {
    max_instrs_to_scan: s64 = 64;       // -aggressive-instcombine-max-scan-instrs
    strncmp_inline_threshold: s64 = 3;  // -strncmp-inline-threshold
    memchr_inline_threshold: s64 = 3;   // -memchr-inline-threshold
}

aggressive_instcombine_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    p: *s64;
    if name == "aggressive-instcombine-max-scan-instrs" p = *aic_cl.max_instrs_to_scan;
    else if name == "strncmp-inline-threshold" p = *aic_cl.strncmp_inline_threshold;
    else if name == "memchr-inline-threshold" p = *aic_cl.memchr_inline_threshold;
    else return false;
    if !has_value fatal(tprint("opt: -% needs a value", name));
    n, ok := string_to_int(value);
    if !ok || n < 0 fatal(tprint("opt: invalid value '%' for -%", value, name));
    p.* = n;
    return true;
}

// ---------------------------------------------------------------- TTI queries

// BasicTTIImplBase::haveFastSqrt
tti_have_fast_sqrt :: (t: *Tti, ty: Type_Id) -> bool {
    if t.kind != .X86 return false;
    st := *t.xl;
    ok, e := x86_value_type(st, ty, true);
    if !ok || !xl_is_type_legal(st, e) return false;
    return is_op_legal_or_custom(st, ISD_FSQRT, e.m);
}
// BasicTTIImplBase::allowsMisalignedMemoryAccesses -> X86TargetLowering::allowsMisalignedMemoryAccesses: (allowed, fast)
tti_allows_misaligned_memory_accesses :: (t: *Tti, bit_width: u64, as: u32, align: u64) -> (bool, u32) {
    if t.kind != .X86 return false, 0;
    st := *t.xl;
    fast: u32 = 1;
    if bit_width == 128 fast = ifx xs_has(st, X86FLD_IsUnalignedMem16Slow) then cast(u32) 0 else 1;
    else if bit_width == 256 fast = ifx xs_has(st, X86FLD_IsUnalignedMem32Slow) then cast(u32) 0 else 1;
    return true, fast;
}

// ---------------------------------------------------------------- matcher helpers

// m_SpecificInt(APInt) / m_SpecificInt(uint64_t): a ConstantInt or a non-poison splat, compared with isSameValue
aic_specific_int :: (v: Value_Id, a: APInt) -> bool {
    ok, c := pm_apint(v);
    return ok && ap_same_value_unsigned(c, a);
}
aic_specific_int_u64 :: (v: Value_Id, x: u64) -> bool { return aic_specific_int(v, ap_from_u64(64, x)); }
// BinaryOp_match (operators: instructions and constant expressions)
aic_bin :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) {
    if v == NONE || opr_code(v) != opc return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}
// m_Trunc / m_ZExt / ... (CastInst_match: instructions)
aic_cast :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id) {
    if v == NONE || !is_inst(v) || inst_op(v) != opc return false, NONE;
    return true, op(v, 0);
}
// m_Intrinsic<ID>(m_Value(), m_Value())
aic_intrinsic2 :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id, Value_Id) {
    if v == NONE || !is_inst(v) || call_iid(v) != id return false, NONE, NONE;
    return true, call_arg(v, 0), call_arg(v, 1);
}
// m_ShlOrSelf / m_LShrOrSelf (ShiftLike_match): (ok, inner, amount); a shift by a non-constant does not match
aic_shift_or_self :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, u64) {
    if is_binary_operator(v) && inst_op(v) == opc {
        ok, amt := pm_constant_int_u64(op(v, 1));
        if !ok return false, NONE, 0;
        return true, op(v, 0), amt;
    }
    return true, v, 0;
}
// m_SpecificICmp(Pred, L, R): (ok, l, r)
aic_specific_icmp :: (v: Value_Id, pred: u8) -> (bool, Value_Id, Value_Id) {
    ok, p, ss, a, b := pm_icmp(v);
    if !ok return false, NONE, NONE;
    okm := cmp_get_matching(p, ss, pred, false);
    if !okm return false, NONE, NONE;
    return true, a, b;
}
aic_has_n_uses_or_more :: (v: Value_Id, n: int) -> bool { return !is_constant_data(v) && has_n_uses_or_more(v, n); }

aic_irb_intrinsic :: (b: *Irb, id: Intrinsic_Id, otys: [] Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    f := get_or_insert_intrinsic_declaration(id, otys);
    return irb_call(b, f, args, name);
}
aic_unlikely_branch_weights :: (i: Value_Id) {
    w := u32.[1, (1 << 20) - 1];   // MDBuilder::createUnlikelyBranchWeights
    prof_set_branch_weights(i, w, false);
}

// ---------------------------------------------------------------- split cttz / ctlz

// foldSelectSplitCTTZ
aic_fold_select_split_cttz :: (i: Value_Id, lo_trunc: Value_Id, hi_result: Value_Id, lo_result: Value_Id, half_ty: Type_Id) -> bool {
    half := type_int_width(half_ty);
    full := half * 2;
    ok, src := aic_cast(lo_trunc, .TRUNC);
    if !ok || !is_int_type_bits(vtype(src), full) return false;
    okl, la := aic_intrinsic2(lo_result, IID_CTTZ);
    if !okl || !value_has_one_use(lo_result) || la != lo_trunc return false;
    oka, cttz_hi, c := pm_add_like(hi_result);
    if !oka || !value_has_one_use(hi_result) || !aic_specific_int_u64(c, half) return false;
    okh, hi_arg := aic_intrinsic2(cttz_hi, IID_CTTZ);
    if !okh || !value_has_one_use(cttz_hi) return false;
    okt, sh := aic_cast(hi_arg, .TRUNC);
    if !okt return false;
    oks, x, amt := aic_bin(sh, .LSHR);
    if !oks || x != src || !aic_specific_int_u64(amt, half) return false;
    b: Irb;
    irb_set_before(*b, i);
    w := aic_irb_intrinsic(*b, IID_CTTZ, .[vtype(src)], .[src, const_int(ir.t_i1, 0)]);
    tr := irb_cast(*b, .TRUNC, w, half_ty);
    rauw_with_metadata(i, tr);
    return true;
}

// foldSelectSplitCTLZ
aic_fold_select_split_ctlz :: (i: Value_Id, hi_part_in: Value_Id, lo_result: Value_Id, hi_result: Value_Id, half_ty: Type_Id) -> bool {
    half := type_int_width(half_ty);
    full := half * 2;
    hi_part := hi_part_in;
    okt, s := aic_cast(hi_part, .TRUNC);
    if okt hi_part = s;
    oks, src, amt := aic_bin(hi_part, .LSHR);
    if !oks || !aic_specific_int_u64(amt, half) return false;
    if !is_int_type_bits(vtype(src), full) return false;
    okh, hi_arg := aic_intrinsic2(hi_result, IID_CTLZ);
    if !okh || !value_has_one_use(hi_result) return false;
    okt2, sh := aic_cast(hi_arg, .TRUNC);
    if !okt2 return false;
    oks2, x, amt2 := aic_bin(sh, .LSHR);
    if !oks2 || x != src || !aic_specific_int_u64(amt2, half) return false;
    oka, ctlz_lo, c := pm_add_like(lo_result);
    if !oka || !value_has_one_use(lo_result) || !aic_specific_int_u64(c, half) return false;
    okl, lo_arg := aic_intrinsic2(ctlz_lo, IID_CTLZ);
    if !okl || !value_has_one_use(ctlz_lo) return false;
    okt3, y := aic_cast(lo_arg, .TRUNC);
    if !okt3 || y != src return false;
    b: Irb;
    irb_set_before(*b, i);
    w := aic_irb_intrinsic(*b, IID_CTLZ, .[vtype(src)], .[src, const_int(ir.t_i1, 0)]);
    tr := irb_cast(*b, .TRUNC, w, half_ty);
    rauw_with_metadata(i, tr);
    return true;
}

// foldSelectSplitCTLZCTTZ
aic_fold_select_split_ctlz_cttz :: (i: Value_Id) -> bool {
    oks, cond, tv_in, fv_in := pm_select(i);
    if !oks return false;
    ty := vtype(i);
    if !is_int_type(ty) || type_int_width(ty) <= 2 return false;
    okc, pred, ss, cmp_op, z := pm_icmp(cond);
    if !okc || !pm_zero_int(z) || !icmp_is_equality(pred) return false;
    tv := tv_in; fv := fv_in;
    if pred == ICMP_NE { t := tv; tv = fv; fv = t; }
    return aic_fold_select_split_cttz(i, cmp_op, tv, fv, ty) || aic_fold_select_split_ctlz(i, cmp_op, tv, fv, ty);
}

// ---------------------------------------------------------------- guarded funnel shifts

// matchFunnelShift: (iid, ShVal0, ShVal1, ShAmt); NOT_INTRINSIC if no match
aic_match_funnel_shift :: (v: Value_Id) -> (Intrinsic_Id, Value_Id, Value_Id, Value_Id) {
    width := type_bits(scalar_type(vtype(v)));
    if !value_has_one_use(v) return NOT_INTRINSIC, NONE, NONE, NONE;
    oko, o0, o1 := aic_bin(v, .OR);
    if !oko return NOT_INTRINSIC, NONE, NONE, NONE;
    // fshl: (ShVal0 << ShAmt) | (ShVal1 >> (Width - ShAmt))
    for side: 0..1 {
        a := ifx side == 0 then o0 else o1;
        b := ifx side == 0 then o1 else o0;
        ok1, sv0, amt := aic_bin(a, .SHL);
        if !ok1 continue;
        ok2, sv1, s := aic_bin(b, .LSHR);
        if !ok2 continue;
        ok3, w, amt2 := aic_bin(s, .SUB);
        if !ok3 || !aic_specific_int_u64(w, width) || amt2 != amt continue;
        return IID_FSHL, sv0, sv1, amt;
    }
    // fshr: (ShVal0 << (Width - ShAmt)) | (ShVal1 >> ShAmt)
    for side: 0..1 {
        a := ifx side == 0 then o0 else o1;
        b := ifx side == 0 then o1 else o0;
        ok1, sv0, s := aic_bin(a, .SHL);
        if !ok1 continue;
        ok2, w, amt := aic_bin(s, .SUB);
        if !ok2 || !aic_specific_int_u64(w, width) continue;
        ok3, sv1, amt2 := aic_bin(b, .LSHR);
        if !ok3 || amt2 != amt continue;
        return IID_FSHR, sv0, sv1, amt;
    }
    return NOT_INTRINSIC, NONE, NONE, NONE;
}

// foldGuardedFunnelShift
aic_fold_guarded_funnel_shift :: (i: Value_Id, dt: *Dom_Tree) -> bool {
    if inst_op(i) != .PHI || nops(i) != 2 return false;
    bw := type_bits(scalar_type(vtype(i)));
    if bw == 0 || (bw & (bw - 1)) != 0 return false;
    funnel_op: u32 = 0; guard_op: u32 = 1;
    p0 := op(i, 0); p1 := op(i, 1);
    iid, sv0, sv1, amt := aic_match_funnel_shift(p0);
    if iid == NOT_INTRINSIC || (iid == IID_FSHL && sv0 != p1) || (iid == IID_FSHR && sv1 != p1) {
        iid, sv0, sv1, amt = aic_match_funnel_shift(p1);
        if iid == NOT_INTRINSIC || (iid == IID_FSHL && sv0 != p0) || (iid == IID_FSHR && sv1 != p0) return false;
        funnel_op = 1; guard_op = 0;
    }
    guard_bb := phi_block(i, guard_op);
    funnel_bb := phi_block(i, funnel_op);
    term := block_terminator(guard_bb);
    if !dt_dominates_inst(dt, sv0, term) || !dt_dominates_inst(dt, sv1, term) return false;
    phi_bb := inst_block(i);
    if inst_op(term) != .CONDBR return false;
    okc, l, r := aic_specific_icmp(op(term, 0), ICMP_EQ);
    if !okc || l != amt || !pm_zero_int(r) return false;
    if get_successor(term, 0) != phi_bb || get_successor(term, 1) != funnel_bb return false;

    b: Irb;
    irb_set_at(*b, phi_bb, block_first_insertion_pt(phi_bb), true);
    is_fshl := iid == IID_FSHL;
    if sv0 != sv1 {
        if is_fshl && !is_guaranteed_not_to_be_poison(sv1) sv1 = irb_freeze(*b, sv1);
        else if !is_fshl && !is_guaranteed_not_to_be_poison(sv0) sv0 = irb_freeze(*b, sv0);
    }
    call := aic_irb_intrinsic(*b, iid, .[vtype(i)], .[sv0, sv1, amt]);
    rauw_with_metadata(i, call);
    return true;
}

// ---------------------------------------------------------------- any/all bits set

Aic_Mask_Ops :: struct { root: Value_Id = NONE; mask: APInt; match_and_chain: bool; found_and1: bool; }

// matchAndOrChain
aic_match_and_or_chain :: (v: Value_Id, m: *Aic_Mask_Ops) -> bool {
    if m.match_and_chain {
        ok, a, b := aic_bin(v, .AND);
        if ok && pm_one(b) {
            m.found_and1 = true;
            return aic_match_and_or_chain(a, m);
        }
        if ok return aic_match_and_or_chain(a, m) && aic_match_and_or_chain(b, m);
    } else {
        ok, a, b := aic_bin(v, .OR);
        if ok return aic_match_and_or_chain(a, m) && aic_match_and_or_chain(b, m);
    }
    candidate := v;
    has_index := false;
    bit_index: APInt;
    oks, x, s := aic_bin(v, .LSHR);
    if oks {
        okc, c := pm_apint(s);
        if okc { candidate = x; bit_index = c; has_index = true; }
    }
    if m.root == NONE m.root = candidate;
    if has_index && ap_uge_u64(bit_index, m.mask.bits) return false;
    ap_set_bit(*m.mask, ifx has_index then cast(u32) ap_zext_value(bit_index) else 0);
    return m.root == candidate;
}

// foldAnyOrAllBitsSet
aic_fold_any_or_all_bits_set :: (i: Value_Id) -> bool {
    match_all := false; match_trunc := false;
    x: Value_Id;
    if is_int_or_int_vector_n(vtype(i), 1) {
        okt, src := aic_cast(i, .TRUNC);
        if !okt return false;
        oka := aic_bin(src, .AND);
        oko := aic_bin(src, .OR);
        if oka && value_has_one_use(src) match_all = true;
        else if oko && value_has_one_use(src) match_all = false;
        else return false;
        match_trunc = true;
        x = op(i, 0);
    } else {
        oka, a0, a1 := aic_bin(i, .AND);
        if !oka return false;
        found := false;
        for side: 0..1 {
            s := ifx side == 0 then a0 else a1;
            okin := aic_bin(s, .AND);
            if okin && value_has_one_use(s) { found = true; break; }
        }
        if found {
            x = i;
            match_all = true;
        } else {
            oko := aic_bin(a0, .OR);
            if oko && value_has_one_use(a0) && pm_one(a1) {
                x = op(i, 0);
                match_all = false;
            } else return false;
        }
        match_trunc = false;
    }
    ty := vtype(x);
    m: Aic_Mask_Ops;
    m.mask = ap_zero(type_bits(scalar_type(ty)));
    m.match_and_chain = match_all;
    if !aic_match_and_or_chain(x, *m) || (match_all && !match_trunc && !m.found_and1) return false;
    b: Irb;
    irb_set_before(*b, i);
    mask := cf_int(ty, m.mask);
    a := irb_binop(*b, .AND, m.root, mask);
    cmp := ifx match_all then irb_icmp(*b, ICMP_EQ, a, mask) else irb_icmp(*b, ICMP_NE, a, const_null_value(vtype(a)));
    z := ifx match_trunc then cmp else irb_cast(*b, .ZEXT, cmp, ty);
    rauw_with_metadata(i, z);
    return true;
}

// ---------------------------------------------------------------- popcount

// replaceWithPopCount
aic_replace_with_popcount :: (i: Value_Id, root: Value_Id) {
    root_ty := vtype(root);
    orig_ty := vtype(i);
    b: Irb;
    irb_set_before(*b, i);
    nv := aic_irb_intrinsic(*b, IID_CTPOP, .[root_ty], .[root]);
    if orig_ty != root_ty nv = irb_cast(*b, .TRUNC, nv, orig_ty);
    rauw_with_metadata(i, nv);
}

aic_q_dl :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }

// m_c_Add(m_LShr(m_Value(X), m_SpecificInt(S)), m_Deferred(X)): X
aic_match_add_shifted_self :: (v: Value_Id, s: u64) -> (bool, Value_Id) {
    ok, a, b := aic_bin(v, .ADD);
    if !ok return false, NONE;
    for side: 0..1 {
        l := ifx side == 0 then a else b;
        r := ifx side == 0 then b else a;
        oks, x, amt := aic_bin(l, .LSHR);
        if oks && aic_specific_int_u64(amt, s) && r == x return true, x;
    }
    return false, NONE;
}
// m_And(m_LShr(m_Value(X), m_SpecificInt(S)), M) with M checked by the caller: (ok, x, mask operand)
aic_match_and_lshr :: (v: Value_Id, s: u64) -> (bool, Value_Id, Value_Id) {
    ok, a, m := aic_bin(v, .AND);
    if !ok return false, NONE, NONE;
    oks, x, amt := aic_bin(a, .LSHR);
    if !oks || !aic_specific_int_u64(amt, s) return false, NONE, NONE;
    return true, x, m;
}

// matchPopCountBytes
aic_match_popcount_bytes :: (v: Value_Id, len: u32) -> Value_Id {
    mask55 := ap_get_splat(len, ap_from_u64(8, 0x55));
    mask33 := ap_get_splat(len, ap_from_u64(8, 0x33));
    mask0f := ap_get_splat(len, ap_from_u64(8, 0x0F));
    ok, a, m := aic_bin(v, .AND);
    if !ok || !aic_specific_int(m, mask0f) return NONE;
    oka, add2 := aic_match_add_shifted_self(a, 4);
    if !oka return NONE;

    sub1: Value_Id = NONE;
    matched := false;
    okadd, p, q := aic_bin(add2, .ADD);
    if okadd {
        for side: 0..1 {
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            okl, x, ml := aic_match_and_lshr(l, 2);
            if !okl || !aic_specific_int(ml, mask33) continue;
            okr, y, mr := aic_bin(r, .AND);
            if !okr || y != x || !aic_specific_int(mr, mask33) continue;
            sub1 = x; matched = true; break;
        }
        if !matched {
            neg_three := ap_from_s64(len, -3);
            okm, mm, c3 := aic_bin(p, .MUL);
            if okm && aic_specific_int(c3, neg_three) {
                okl, x, ml := aic_match_and_lshr(mm, 2);
                if okl && aic_specific_int(ml, mask33) && q == x { sub1 = x; matched = true; }
            }
        }
    }
    if !matched return NONE;

    oks, root, am := aic_bin(sub1, .SUB);
    if !oks return NONE;
    okn, lshr, and_mask := aic_bin(am, .AND);
    if !okn return NONE;
    okl, rr, one := aic_bin(lshr, .LSHR);
    if !okl || rr != root || !aic_specific_int_u64(one, 1) return NONE;
    okc, c := pm_apint(and_mask);
    if !okc return NONE;
    if !ap_eq(c, mask55) {
        if !ap_is_subset_of(c, mask55) return NONE;
        needed := ap_and(mask55, ap_not(c));
        if !masked_value_is_zero(lshr, needed, aic_q_dl()) return NONE;
    }
    return root;
}

// tryToRecognizePopCount
aic_try_popcount :: (i: Value_Id) -> bool {
    if inst_op(i) != .LSHR return false;
    ty := vtype(i);
    if !is_int_or_int_vector(ty) return false;
    len := type_bits(scalar_type(ty));
    if len > 128 || len <= 8 || len % 8 != 0 return false;
    mask01 := ap_get_splat(len, ap_from_u64(8, 0x01));
    okm, mul_op0, c := aic_bin(op(i, 0), .MUL);
    if !okm || !aic_specific_int(c, mask01) || !aic_specific_int_u64(op(i, 1), len - 8) return false;
    root := aic_match_popcount_bytes(mul_op0, len);
    if root == NONE return false;
    aic_replace_with_popcount(i, root);
    return true;
}

// m_c_Add(m_And(m_LShr(m_Value(X), m_SpecificInt(S)), m_APInt(M1)), m_And(m_Deferred(X), m_APInt(M2)))
aic_match_add_pair :: (v: Value_Id, s: u64) -> (bool, Value_Id, APInt, APInt) {
    z: APInt;
    ok, a, b := aic_bin(v, .ADD);
    if !ok return false, NONE, z, z;
    for side: 0..1 {
        l := ifx side == 0 then a else b;
        r := ifx side == 0 then b else a;
        okl, x, ml := aic_match_and_lshr(l, s);
        if !okl continue;
        ok1, m1 := pm_apint(ml);
        if !ok1 continue;
        okr, y, mr := aic_bin(r, .AND);
        if !okr || y != x continue;
        ok2, m2 := pm_apint(mr);
        if !ok2 continue;
        return true, x, m1, m2;
    }
    return false, NONE, z, z;
}

// tryToRecognizePopCount1
aic_try_popcount1 :: (i: Value_Id) -> bool {
    if inst_op(i) != .ADD return false;
    ty := vtype(i);
    if !is_int_or_int_vector(ty) return false;
    len := type_bits(scalar_type(ty));
    if len > 64 || len <= 8 || len % 8 != 0 return false;
    if (len & (len - 1)) != 0 return false;
    mask55 := ap_get_splat(len, ap_from_u64(8, 0x55));
    mask33 := ap_get_splat(len, ap_from_u64(8, 0x33));
    sq := aic_q_dl();
    is_valid_narrowed :: (captured: APInt, expected: APInt, operand: Value_Id, sq: Simplify_Query) -> bool {
        if ap_eq(captured, expected) return true;
        if !ap_is_subset_of(captured, expected) return false;
        return masked_value_is_zero(operand, ap_and(expected, ap_not(captured)), sq);
    }
    pair_ok :: (base: APInt, shift: u32, val: Value_Id, m1: APInt, m2: APInt, sq: Simplify_Query) -> bool {
        if !ap_is_subset_of(m1, base) || !ap_is_subset_of(m2, base) return false;
        needed_shifted := ap_shl(ap_and(base, ap_not(m1)), shift);
        needed_unshifted := ap_and(base, ap_not(m2));
        all := ap_or(needed_shifted, needed_unshifted);
        return ap_is_zero(all) || masked_value_is_zero(val, all, sq);
    }
    start := i;
    shift_op: Value_Id;
    k := len;
    while k >= 8 {
        defer k /= 2;
        mask := ap_get_splat(len, ap_low_bits_set(k, k / 2));
        okp, x, m1, m2 := aic_match_add_pair(start, k / 2);
        if okp {
            shift_op = x;
            if !pair_ok(mask, k / 2, x, m1, m2, sq) return false;
        } else {
            // m_c_Add(m_LShr(m_Value(X), m_SpecificInt(S)), m_And(m_Deferred(X), m_APInt(M1)))
            found := false;
            oka, a, b := aic_bin(start, .ADD);
            if oka for side: 0..1 {
                l := ifx side == 0 then a else b;
                r := ifx side == 0 then b else a;
                oks, sx_, amt := aic_bin(l, .LSHR);
                if !oks || !aic_specific_int_u64(amt, k / 2) continue;
                okr, y, mr := aic_bin(r, .AND);
                if !okr || y != sx_ continue;
                okm, m := pm_apint(mr);
                if !okm continue;
                shift_op = sx_;
                if !is_valid_narrowed(m, mask, sx_, sq) return false;
                found = true;
                break;
            }
            if !found return false;
        }
        start = shift_op;
    }
    okp, x, m1, m2 := aic_match_add_pair(start, 2);
    if !okp || !pair_ok(mask33, 2, x, m1, m2, sq) return false;
    start = x;
    okr, root, n1, n2 := aic_match_add_pair(start, 1);
    if !okr || !pair_ok(mask55, 1, root, n1, n2, sq) return false;
    aic_replace_with_popcount(i, root);
    return true;
}

// tryToRecognizePopCount2n3
aic_try_popcount2n3 :: (i: Value_Id) -> bool {
    if inst_op(i) != .AND return false;
    ty := vtype(i);
    if !is_int_or_int_vector(ty) return false;
    len := type_bits(scalar_type(ty));
    add1: Value_Id;
    if len == 8 {
        add1 = i;
    } else {
        ok, a, mres := aic_bin(i, .AND);
        if !ok return false;
        okm, mask_res := pm_apint(mres);
        if !okm return false;
        add1 = a;
        okt, tsrc := aic_cast(add1, .TRUNC);
        if okt && value_has_one_use(add1) {
            add1 = tsrc;
            len = type_bits(scalar_type(vtype(add1)));
        }
        if len > 64 || len <= 8 || len % 8 != 0 return false;
        if (len & (len - 1)) != 0 return false;
        num_len_bits := ap_log2_u32(len) + 1;
        if ap_cto(mask_res) < num_len_bits || ap_active_bits(mask_res) > 8 return false;
        k := len;
        while k >= 16 {
            defer k /= 2;
            oks, add2 := aic_match_add_shifted_self(add1, k / 2);
            if !oks return false;
            add1 = add2;
        }
    }
    root := aic_match_popcount_bytes(add1, len);
    if root == NONE return false;
    aic_replace_with_popcount(i, root);
    return true;
}
ap_log2_u32 :: (x: u32) -> u32 { r: u32 = 0; y := x; while y > 1 { y >>= 1; r += 1; } return r; }

// ---------------------------------------------------------------- fptosi.sat

// tryToFPToSat
aic_try_fp_to_sat :: (i: Value_Id, tti: *Tti) -> bool {
    inner_match :: (v: Value_Id, id: Intrinsic_Id) -> (bool, Value_Id, APInt) {
        z: APInt;
        if !value_has_one_use(v) return false, NONE, z;
        ok, l, r := pm_max_min(v, id);
        if !ok || !value_has_one_use(l) return false, NONE, z;
        okf, inp := aic_cast(l, .FPTOSI);
        if !okf return false, NONE, z;
        okc, c := pm_apint(r);
        if !okc return false, NONE, z;
        return true, inp, c;
    }
    inp: Value_Id; min_c: APInt; max_c: APInt;
    matched := false;
    {
        ok, l, r := pm_max_min(i, IID_SMAX);
        if ok {
            oki, x, c := inner_match(l, IID_SMIN);
            okc, c2 := pm_apint(r);
            if oki && okc { inp = x; min_c = c; max_c = c2; matched = true; }
        }
    }
    if !matched {
        ok, l, r := pm_max_min(i, IID_SMIN);
        if ok {
            oki, x, c := inner_match(l, IID_SMAX);
            okc, c2 := pm_apint(r);
            if oki && okc { inp = x; max_c = c; min_c = c2; matched = true; }
        }
    }
    if !matched return false;
    min1 := ap_add_u64(min_c, 1);
    if !ap_is_power_of_2(min1) || !ap_eq(ap_neg(max_c), min1) return false;
    int_ty := vtype(i);
    fp_ty := vtype(inp);
    sat_ty := type_int(cast(u64) ap_exact_log2(min1) + 1);
    if is_vector_type(int_ty) sat_ty = type_vector(type_count(int_ty), sat_ty, type_kind(int_ty) == .SVECTOR);

    ica: Ica;
    ica.id = IID_FPTOSI_SAT; ica.ret = sat_ty;
    args := NewArray(1, Value_Id,, allocator = temp); args[0] = inp;
    tys := NewArray(1, Type_Id,, allocator = temp); tys[0] = fp_ty;
    ica.args = args; ica.tys = tys;
    sat_cost := tti_intrinsic_cost(tti, *ica, TCK_RECIP_THROUGHPUT);
    sat_cost = cost_add(sat_cost, tti_cast_cost(tti, .SEXT, int_ty, sat_ty, CCH_NONE, TCK_RECIP_THROUGHPUT));
    mm_cost := tti_cast_cost(tti, .FPTOSI, int_ty, fp_ty, CCH_NONE, TCK_RECIP_THROUGHPUT);
    smin := ica_types(IID_SMIN, int_ty, .[int_ty]);
    mm_cost = cost_add(mm_cost, tti_intrinsic_cost(tti, *smin, TCK_RECIP_THROUGHPUT));
    smax := ica_types(IID_SMAX, int_ty, .[int_ty]);
    mm_cost = cost_add(mm_cost, tti_intrinsic_cost(tti, *smax, TCK_RECIP_THROUGHPUT));
    if sat_cost >= mm_cost return false;

    b: Irb;
    irb_set_before(*b, i);
    sat := aic_irb_intrinsic(*b, IID_FPTOSI_SAT, .[sat_ty, fp_ty], .[inp]);
    rauw_with_metadata(i, irb_cast(*b, .SEXT, sat, int_ty));
    return true;
}

// ---------------------------------------------------------------- sqrt

// foldSqrt
aic_fold_sqrt :: (call: Value_Id, tti: *Tti, ac: *Assumption_Cache, dt: *Dom_Tree) -> bool {
    ty := vtype(call);
    arg := call_arg(call, 0);
    if !tti_have_fast_sqrt(tti, ty) return false;
    if (get_fmf(call) & FMF_NNAN) == 0 {
        q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = call; q.have_tli = true;
        k := compute_known_fp_class(arg, KFPC_ORDERED_LESS_THAN_ZERO_MASK, q);
        if !kfpc_cannot_be_ordered_less_than_zero(k) return false;
    }
    b: Irb;
    irb_set_before(*b, call);
    ns := aic_irb_intrinsic(*b, IID_SQRT, .[ty], .[arg], "sqrt");
    set_fmf(ns, get_fmf(call));
    rauw_with_metadata(call, ns);
    erase_inst_with_metadata(call);
    return true;
}

// ---------------------------------------------------------------- table-based cttz / log2

// ConstantFoldLoadFromConst(C, Ty, DL): offset 0 in the index width
aic_load_from_const0 :: (c: Value_Id, ty: Type_Id) -> Value_Id { return cfo_load_from_const(c, ty, ap_zero(dl_index_size_bits(0))); }

// isCTTZTable
aic_is_cttz_table :: (table: Value_Id, mul: APInt, shift: APInt, and_mask: APInt, access_ty: Type_Id, input_bits: u32, factor: APInt) -> bool {
    for idx: 0..input_bits - 1 {
        index := ap_and(ap_lshr_ap(ap_mul(ap_one_bit_set(input_bits, idx), mul), shift), and_mask);
        c := cfo_load_from_const(table, access_ty, ap_mul(index, factor));
        if c == NONE || vkind(c) != .C_INT || !ap_eq_u64(const_ap(c), idx) return false;
    }
    return true;
}

// isLog2Table
aic_is_log2_table :: (table: Value_Id, mul: APInt, shift: APInt, access_ty: Type_Id, input_bits: u32, factor: APInt) -> bool {
    for idx: 0..input_bits - 1 {
        index := ap_lshr_ap(ap_mul(ap_low_bits_set(input_bits, idx + 1), mul), shift);
        c := cfo_load_from_const(table, access_ty, ap_mul(index, factor));
        if c == NONE || vkind(c) != .C_INT || !ap_eq_u64(const_ap(c), idx) return false;
    }
    if !ap_is_zero(ap_lshr_ap(mul, shift)) return false;
    return true;
}

// m_CastOrSelf(P): the operand of any cast instruction that matches, else V itself
aic_cast_or_self_candidates :: (v: Value_Id) -> (Value_Id, Value_Id) {
    if is_inst(v) && is_cast_op(inst_op(v)) return op(v, 0), v;
    return v, NONE;
}

// m_LShr(m_Mul(m_c_And(m_Neg(m_Value(X)), m_Deferred(X)), m_APInt(Mul)), m_APInt(Shift))
aic_match_cttz_inner :: (v: Value_Id) -> (bool, Value_Id, APInt, APInt) {
    z: APInt;
    ok, m, s := aic_bin(v, .LSHR);
    if !ok return false, NONE, z, z;
    okm, a, mc := aic_bin(m, .MUL);
    if !okm return false, NONE, z, z;
    oka, p, q := aic_bin(a, .AND);
    if !oka return false, NONE, z, z;
    x: Value_Id = NONE;
    for side: 0..1 {
        l := ifx side == 0 then p else q;
        r := ifx side == 0 then q else p;
        okn, nz, nx := aic_bin(l, .SUB);
        if okn && pm_zero_int(nz) && r == nx { x = nx; break; }
    }
    if x == NONE return false, NONE, z, z;
    ok1, mul := pm_apint(mc);
    if !ok1 return false, NONE, z, z;
    ok2, sh := pm_apint(s);
    if !ok2 return false, NONE, z, z;
    return true, x, mul, sh;
}

// tryToRecognizeTableBasedCttz
aic_try_table_cttz :: (li: Value_Id, access_ty: Type_Id, table: Value_Id, gep_idx: Value_Id, scale: APInt) -> bool {
    x1: Value_Id; mul: APInt; sh: APInt; and_c: APInt; has_and := false;
    matched := false;
    for attempt: 0..1 {
        c1, c2 := aic_cast_or_self_candidates(gep_idx);
        for cand: Value_Id.[c1, c2] {
            if cand == NONE continue;
            if attempt == 0 {
                ok, x, m, s := aic_match_cttz_inner(cand);
                if ok { x1 = x; mul = m; sh = s; matched = true; break; }
            } else {
                oka, inner, ac := aic_bin(cand, .AND);
                if !oka continue;
                ok, x, m, s := aic_match_cttz_inner(inner);
                if !ok continue;
                okc, c := pm_apint(ac);
                if !okc continue;
                x1 = x; mul = m; sh = s; and_c = c; has_and = true; matched = true; break;
            }
        }
        if matched break;
    }
    if !matched return false;
    input_bits := type_bits(scalar_type(vtype(x1)));
    if input_bits != 16 && input_bits != 32 && input_bits != 64 && input_bits != 128 return false;
    init := gv_initializer(table);
    if ap_active_bits(scale) > input_bits ||
       !aic_is_cttz_table(init, mul, sh, ifx has_and then and_c else ap_all_ones(input_bits), access_ty, input_bits,
                          ap_zext_or_trunc(scale, input_bits))
        return false;
    zero_elem := aic_load_from_const0(init, access_ty);
    if zero_elem == NONE || vkind(zero_elem) != .C_INT fatal("aggressive-instcombine: cttz table element 0 does not fold to a ConstantInt");
    defined_for_zero := ap_eq_u64(const_ap(zero_elem), input_bits);
    b: Irb;
    irb_set_before(*b, li);
    bool_c := const_int(ir.t_i1, ifx defined_for_zero then cast(u64) 0 else 1);
    xt := vtype(x1);
    cttz := aic_irb_intrinsic(*b, IID_CTTZ, .[xt], .[x1, bool_c]);
    res := irb_zext_or_trunc_any(*b, cttz, access_ty);
    if !defined_for_zero {
        cmp := irb_icmp(*b, ICMP_EQ, x1, const_int(xt, 0));
        res = irb_select(*b, cmp, zero_elem, res);
        if is_inst(res) aic_unlikely_branch_weights(res);
    }
    rauw_with_metadata(li, res);
    return true;
}

// CreateZExtOrTrunc
irb_zext_or_trunc_any :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    vb := type_bits(scalar_type(vtype(v))); tb := type_bits(scalar_type(t));
    if vb < tb return irb_cast(b, .ZEXT, v, t);
    if vb > tb return irb_cast(b, .TRUNC, v, t);
    return v;
}

// tryToRecognizeTableBasedLog2
aic_try_table_log2 :: (li: Value_Id, access_ty: Type_Id, table: Value_Id, gep_idx: Value_Id, scale: APInt, tti: *Tti) -> bool {
    x: Value_Id; mul: APInt; sh: APInt;
    matched := false;
    c1, c2 := aic_cast_or_self_candidates(gep_idx);
    for cand: Value_Id.[c1, c2] {
        if cand == NONE continue;
        ok, m, s := aic_bin(cand, .LSHR);
        if !ok continue;
        okm, sx_, mc := aic_bin(m, .MUL);
        if !okm continue;
        ok1, mv := pm_apint(mc);
        if !ok1 continue;
        ok2, sv := pm_apint(s);
        if !ok2 continue;
        x = sx_; mul = mv; sh = sv; matched = true; break;
    }
    if !matched return false;
    isolated_msb := false;
    {
        oks, v, l := aic_bin(x, .SUB);
        if oks {
            okl, vv, one := aic_bin(l, .LSHR);
            if okl && vv == v && aic_specific_int_u64(one, 1) { isolated_msb = true; x = v; }
        }
    }
    input_bits := type_bits(scalar_type(vtype(x)));
    if input_bits != 16 && input_bits != 32 && input_bits != 64 && input_bits != 128 return false;
    if !ap_eq_u64(sh, cast(u64) (input_bits - ap_log2_u32(input_bits))) return false;
    amt := input_bits / 2;
    while amt != 0 {
        defer amt /= 2;
        oko, p, q := aic_bin(x, .OR);
        if !oko return false;
        found := false;
        for side: 0..1 {
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            okl, y, s := aic_bin(l, .LSHR);
            if okl && aic_specific_int_u64(s, amt) && r == y { x = y; found = true; break; }
        }
        if !found return false;
    }
    if ap_active_bits(scale) > input_bits return false;
    init := gv_initializer(table);
    factor := ap_zext_or_trunc(scale, input_bits);
    if isolated_msb {
        if !aic_is_cttz_table(init, mul, sh, ap_all_ones(input_bits), access_ty, input_bits, factor) return false;
    } else {
        if !aic_is_log2_table(init, mul, sh, access_ty, input_bits, factor) return false;
    }
    zero_elem := aic_load_from_const0(init, access_ty);
    if zero_elem == NONE || vkind(zero_elem) != .C_INT fatal("aggressive-instcombine: log2 table element 0 does not fold to a ConstantInt");
    xt := vtype(x);
    bool_c := const_int(ir.t_i1, 1);
    ica: Ica;
    ica.id = IID_CTLZ; ica.ret = xt;
    args := NewArray(2, Value_Id,, allocator = temp); args[0] = const_poison(xt); args[1] = bool_c;
    tys := NewArray(2, Type_Id,, allocator = temp); tys[0] = xt; tys[1] = ir.t_i1;
    ica.args = args; ica.tys = tys;
    cost := tti_intrinsic_cost(tti, *ica, TCK_SIZE_AND_LATENCY);
    if cost > TCC_BASIC return false;
    b: Irb;
    irb_set_before(*b, li);
    ctlz := aic_irb_intrinsic(*b, IID_CTLZ, .[xt], .[x, bool_c]);
    sub := irb_binop(*b, .SUB, const_int(xt, cast(u64) (input_bits - 1)), ctlz);
    cmp := irb_icmp(*b, ICMP_EQ, x, const_int(xt, 0));
    zext_zero := irb_cast(*b, .ZEXT, zero_elem, xt);
    sel := irb_select(*b, cmp, zext_zero, sub);
    if is_inst(sel) aic_unlikely_branch_weights(sel);
    res := irb_zext_or_trunc_any(*b, sel, access_ty);
    rauw_with_metadata(li, res);
    return true;
}

// tryToRecognizeTableBasedCttzOrLog2
aic_try_table_cttz_or_log2 :: (i: Value_Id, tti: *Tti) -> bool {
    if inst_op(i) != .LOAD return false;
    access_ty := vtype(i);
    if !is_int_type(access_ty) return false;
    gep := op(i, 0);
    if !is_inst(gep) || inst_op(gep) != .GEP || (ce_gep_nw(gep) & F_NUSW) == 0 return false;
    table := op(gep, 0);
    if vkind(table) != .GLOBAL_VAR || !glob(table).has_init || !glob(table).is_const return false;
    bw := dl_index_type_size_bits(vtype(gep));
    ok, vars, off := gep_operator_collect_offset(gep, bw);
    if !ok || vars.count != 1 || !ap_is_zero(off) return false;
    if aic_try_table_cttz(i, access_ty, table, vars[0].v, vars[0].scale) return true;
    return aic_try_table_log2(i, access_ty, table, vars[0].v, vars[0].scale, tti);
}

// ---------------------------------------------------------------- consecutive loads

Aic_Load_Ops :: struct {
    root: Value_Id = NONE;
    root_insert: Value_Id = NONE;
    found_root: bool;
    load_size: u64;
    shift: u64;
    zext_type: Type_Id;
    tags: AA_Tags;
}

// m_OneUse(m_ShlOrSelf(m_OneUse(m_ZExt(m_Instruction(L))), ShAmt)): (ok, L, ShAmt)
aic_match_shl_zext_inst :: (v: Value_Id) -> (bool, Value_Id, u64) {
    if !value_has_one_use(v) return false, NONE, 0;
    ok, inner, amt := aic_shift_or_self(v, .SHL);
    if !ok return false, NONE, amt;
    if !value_has_one_use(inner) return false, NONE, amt;
    okz, l := aic_cast(inner, .ZEXT);
    if !okz || !is_inst(l) return false, NONE, amt;
    return true, l, amt;
}

aa_tags_concat :: (a: AA_Tags, b: AA_Tags) -> AA_Tags {
    r: AA_Tags;
    r.scope = md_most_generic_alias_scope(a.scope, b.scope);
    r.noalias = md_intersect(a.noalias, b.noalias);
    r.noalias_as = md_most_generic_noalias_addrspace(a.noalias_as, b.noalias_as);
    return r;
}

// foldLoadsRecursive
aic_fold_loads_recursive :: (v: Value_Id, lops: *Aic_Load_Ops, aar: *Aa_Results, is_root := false) -> bool {
    if !is_root && !value_has_one_use(v) return false;
    oko, o0, o1 := aic_bin(v, .OR);
    if !oko return false;
    x: Value_Id = NONE; l2: Value_Id = NONE; sh_amt2: u64 = 0;
    {
        ok, l, a := aic_match_shl_zext_inst(o1);
        if ok { x = o0; l2 = l; sh_amt2 = a; }
        else {
            ok, l, a = aic_match_shl_zext_inst(o0);
            if ok { x = o1; l2 = l; sh_amt2 = a; }
            else return false;
        }
    }
    if !aic_fold_loads_recursive(x, lops, aar, false) && lops.found_root return false;

    li1 := lops.root;
    sh_amt1 := lops.shift;
    if !lops.found_root {
        ok, l1, a := aic_match_shl_zext_inst(x);
        sh_amt1 = a;
        if ok li1 = ifx inst_op(l1) == .LOAD then l1 else NONE;
    }
    li2 := ifx inst_op(l2) == .LOAD then l2 else NONE;
    if li1 == li2 || li1 == NONE || li2 == NONE || !load_is_simple(li1) || !load_is_simple(li2) ||
       ptr_addrspace(vtype(op(li1, 0))) != ptr_addrspace(vtype(op(li2, 0))) return false;
    if inst_block(li1) != inst_block(li2) return false;
    big_endian := dl.big_endian;

    p1, off1 := strip_and_accumulate_constant_offsets(op(li1, 0), ap_zero(dl_index_type_size_bits(vtype(op(li1, 0)))), true);
    p2, off2 := strip_and_accumulate_constant_offsets(op(li2, 0), ap_zero(dl_index_type_size_bits(vtype(op(li2, 0)))), true);
    size1 := cast(u64) type_bits(vtype(li1));
    size2 := cast(u64) type_bits(vtype(li2));
    if p1 != p2 return false;
    if !dl_type_size_equals_store_size(vtype(li1)) || !dl_type_size_equals_store_size(vtype(li2)) return false;

    start := ifx lops.found_root then lops.root_insert else li1;
    end := li2;
    loc: Mem_Loc;
    if !comes_before(start, end) {
        t := start; start = end; end = t;
        if lops.found_root loc = mloc(op(lops.root, 0), ls_precise(dl_type_store_size(type_int(lops.load_size))), lops.tags);
        else loc = mloc_get(end);
    } else loc = mloc_get(end);
    scanned := 0;
    it := start;
    while it != end {
        if may_write_to_memory(it) {
            q := aa_query_new(aar);
            if (aa_mod_ref_inst_loc(q, it, loc) & MR_MOD) != 0 return false;
        }
        scanned += 1;
        if scanned > aic_cl.max_instrs_to_scan return false;
        it = inst_next(it);
    }

    reverse := false;
    if ap_slt(off2, off1) {
        t := li1; li1 = li2; li2 = t;
        a := sh_amt1; sh_amt1 = sh_amt2; sh_amt2 = a;
        o := off1; off1 = off2; off2 = o;
        p := p1; p1 = p2; p2 = p;
        s := size1; size1 = size2; size2 = s;
        reverse = true;
    }
    if big_endian { a := sh_amt1; sh_amt1 = sh_amt2; sh_amt2 = a; }
    if lops.found_root {
        if !reverse size1 = lops.load_size;
        else size2 = lops.load_size;
    }
    shift_diff := ifx big_endian then size2 else size1;
    prev_size := dl_type_store_size(type_int(size1));
    diff := ap_sub(off2, off1);
    if (sh_amt2 - sh_amt1) != shift_diff || !(ap_active_bits(diff) <= 64 && ap_zext_value(diff) == prev_size) return false;
    if size1 + size2 > type_bits(scalar_type(vtype(x))) return false;

    tags1 := lops.tags;
    tags2 := get_aa_metadata(li2);
    if !lops.found_root {
        lops.found_root = true;
        tags1 = get_aa_metadata(li1);
    }
    lops.load_size = size1 + size2;
    lops.root_insert = start;
    lops.tags = aa_tags_concat(tags1, tags2);
    lops.root = li1;
    lops.shift = sh_amt1;
    lops.zext_type = vtype(x);
    return true;
}

// foldConsecutiveLoads
aic_fold_consecutive_loads :: (i: Value_Id, tti: *Tti, aar: *Aa_Results, dt: *Dom_Tree) -> bool {
    if is_vector_type(vtype(i)) return false;
    lops: Aic_Load_Ops;
    if !aic_fold_loads_recursive(i, *lops, aar, true) || !lops.found_root return false;
    li1 := lops.root;
    wider := type_int(lops.load_size);
    if !tti_is_type_legal(tti, wider) return false;
    as := ptr_addrspace(vtype(op(li1, 0)));
    allowed, fast := tti_allows_misaligned_memory_accesses(tti, lops.load_size, as, inst(li1).align);
    if !allowed || !fast return false;
    load1_ptr := op(li1, 0);
    b: Irb;
    irb_set_before(*b, lops.root_insert);
    if !dt_dominates_inst(dt, load1_ptr, lops.root_insert) {
        p, off := strip_and_accumulate_constant_offsets(load1_ptr, ap_zero(dl_index_type_size_bits(vtype(load1_ptr))), true);
        load1_ptr = irb_gep(*b, ir.t_i8, p, .[const_int_ap(type_int(off.bits), off)]);
    }
    nl := irb_load(*b, wider, load1_ptr, inst(li1).align, (inst(li1).flags & F_VOLATILE) != 0);
    ic_take_name(nl, li1);
    if !aa_tags_empty(lops.tags) set_aa_metadata(nl, lops.tags);
    nop := irb_cast(*b, .ZEXT, nl, lops.zext_type);
    if lops.shift nop = irb_binop(*b, .SHL, nop, const_int(vtype(nop), lops.shift));
    rauw_with_metadata(i, nop);
    return true;
}

// ---------------------------------------------------------------- consecutive stores

Aic_Part_Store :: struct {
    base: Value_Id;
    off: APInt;
    val: Value_Id;
    val_offset: u64;
    val_width: u64;
    store: Value_Id;
}

// matchPartStore
aic_match_part_store :: (i: Value_Id) -> (bool, Aic_Part_Store) {
    r: Aic_Part_Store;
    if inst_op(i) != .STORE || !is_simple_load_store(i) return false, r;
    stored := op(i, 0);
    st := vtype(stored);
    if !is_int_type(st) || !dl_type_size_equals_store_size(st) return false, r;
    vw := cast(u64) type_bits(st);
    okt, src := aic_cast(stored, .TRUNC);
    if !okt return false, r;
    oks, val, voff := aic_shift_or_self(src, .LSHR);
    if !oks return false, r;
    ptr := op(i, 1);
    base, off := strip_and_accumulate_constant_offsets(ptr, ap_zero(dl_index_type_size_bits(vtype(ptr))), true);
    r = .{base, off, val, voff, vw, i};
    return true, r;
}

// mergeConsecutivePartStores
aic_merge_consecutive_part_stores :: (parts: [] Aic_Part_Store, width: u64, tti: *Tti) -> bool {
    if parts.count < 2 return false;
    first := parts[0];
    new_ty := type_int(width);
    as := ptr_addrspace(vtype(op(first.store, 1)));
    if !tti_is_type_legal(tti, new_ty) return false;
    allowed, fast := tti_allows_misaligned_memory_accesses(tti, width, as, inst(first.store).align);
    if !allowed || !fast return false;
    b: Irb;
    irb_set_before(*b, first.store);
    val := first.val;
    if first.val_offset != 0 val = irb_binop(*b, .LSHR, val, const_int(vtype(val), first.val_offset));
    val = irb_zext_or_trunc_any(*b, val, new_ty);
    st := irb_store(*b, val, op(first.store, 1), inst(first.store).align);
    tags := get_aa_metadata(first.store);
    dbg := get_metadata(first.store, 0);
    k_assign := md_kind_id("DIAssignID");
    for p, k: parts {
        if k > 0 {
            tags = aa_tags_concat(tags, get_aa_metadata(p.store));
            if dbg != NONE dbg = merged_location(dbg, get_metadata(p.store, 0));
        }
        if get_metadata(p.store, k_assign) != NONE fatal("aggressive-instcombine: merging stores with DIAssignID is not supported yet");
    }
    set_aa_metadata(st, tags);
    set_metadata(st, 0, dbg);
    for parts erase_inst_with_metadata(it.store);
    return true;
}

// mergePartStores
aic_merge_part_stores :: (parts: *[..] Aic_Part_Store, tti: *Tti) -> bool {
    if parts.count < 2 return false;
    changed := false;
    // llvm::sort by PtrOffset.slt (std::sort; an insertion sort gives the same order for distinct offsets)
    for k: 1..parts.count - 1 {
        x := parts.*[k];
        j := k - 1;
        while j >= 0 && ap_slt(x.off, parts.*[j].off) { parts.*[j + 1] = parts.*[j]; j -= 1; }
        parts.*[j + 1] = x;
    }
    last_end: s64 = 0;
    first := 0;
    for k: 0..parts.count - 1 {
        part := parts.*[k];
        ptr_from_first := ap_sub(part.off, parts.*[first].off);
        val_from_first := cast,no_check(s64) (part.val_offset - parts.*[first].val_offset);
        p8 := ap_mul(ptr_from_first, ap_from_u64(ptr_from_first.bits, 8));
        same := ap_active_bits(p8) <= 64 && ap_zext_value(p8) == cast,no_check(u64) val_from_first;
        if !same || last_end != val_from_first {
            if aic_merge_consecutive_part_stores(array_view(parts.*, first, k - first), cast,no_check(u64) last_end, tti) changed = true;
            first = k;
            last_end = cast(s64) part.val_width;
            continue;
        }
        last_end = val_from_first + cast(s64) part.val_width;
    }
    if aic_merge_consecutive_part_stores(array_view(parts.*, first, parts.count - first), cast,no_check(u64) last_end, tti) changed = true;
    return changed;
}

// foldConsecutiveStores
aic_fold_consecutive_stores :: (bb: Value_Id, tti: *Tti, aar: *Aa_Results) -> bool {
    if dl.big_endian return false;
    q := aa_query_new(aar);
    parts: [..] Aic_Part_Store; parts.allocator = temp;
    changed := false;
    for :early_inc i: block_insts(bb) {
        ok, part := aic_match_part_store(i);
        if ok {
            if parts.count == 0 || (part.base == parts[0].base && part.val == parts[0].val) {
                array_add(*parts, part);
                continue;
            }
            if aic_merge_part_stores(*parts, tti) changed = true;
            parts.count = 0;
            array_add(*parts, part);
            continue;
        }
        if parts.count == 0 continue;
        if may_throw(i) || (may_read_or_write_memory(i) && aa_mod_ref_inst_loc(q, i, mloc_before_or_after(parts[0].base)) != 0) {
            if aic_merge_part_stores(*parts, tti) changed = true;
            parts.count = 0;
            continue;
        }
    }
    if aic_merge_part_stores(*parts, tti) changed = true;
    return changed;
}

// ---------------------------------------------------------------- icmp of or chains

// optimizeShiftInOrChain
aic_optimize_shift_in_or_chain :: (v: Value_Id, b: *Irb) -> Value_Id {
    if !is_inst(v) || inst_op(v) != .OR || !value_has_one_use(v) return NONE;
    strip :: (x: Value_Id, b: *Irb) -> Value_Id {
        ok, a := pm_ob(x, .SHL, F_NSW);
        if ok return a;
        ok, a = pm_ob(x, .SHL, F_NUW);
        if ok return a;
        n := aic_optimize_shift_in_or_chain(x, b);
        if n != NONE return n;
        return x;
    }
    o0 := strip(op(v, 0), b);
    o1 := strip(op(v, 1), b);
    if o0 != op(v, 0) || o1 != op(v, 1) return irb_binop(b, .OR, o0, o1);
    return NONE;
}

// foldICmpOrChain
aic_fold_icmp_or_chain :: (i: Value_Id, tti: *Tti, aar: *Aa_Results, dt: *Dom_Tree) -> bool {
    ok, pred, ss, op0, z := pm_icmp(i);
    if !ok || !pm_zero(z) || !icmp_is_equality(pred) return false;
    if is_inst(op0) && inst_op(op0) == .OR && aic_fold_consecutive_loads(op0, tti, aar, dt) return true;
    b: Irb;
    irb_set_before(*b, i);
    res := aic_optimize_shift_in_or_chain(op0, *b);
    if res != NONE {
        rauw_with_metadata(i, irb_icmp(*b, pred, res, op(i, 1)));
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- patterned loads

// getStrideAndModOffsetOfGEP: (stride, mod offset)
aic_stride_and_mod_offset :: (ptr_in: Value_Id) -> (APInt, APInt) {
    ptr := ptr_in;
    bw := dl_index_type_size_bits(vtype(ptr));
    has_stride := false;
    stride: APInt;
    mod_off := ap_zero(bw);
    while opr_code(ptr) == .GEP {
        ok, vars, off := gep_operator_collect_offset(ptr, bw);
        if !ok break;
        mod_off = ap_add(mod_off, off);
        for vars {
            scale := it.scale;
            if (ce_gep_nw(ptr) & F_NUSW) == 0 scale = ap_one_bit_set(scale.bits, ap_ctz(scale));
            if !has_stride { stride = scale; has_stride = true; }
            else stride = ap_gcd(stride, scale);
        }
        ptr = op(ptr, 0);
    }
    if vkind(ptr) != .GLOBAL_VAR || !has_stride return ap_from_u64(bw, 1), ap_zero(bw);
    mod_off = ap_srem(mod_off, stride);
    if ap_is_negative(mod_off) mod_off = ap_add(mod_off, stride);
    return stride, mod_off;
}

// foldPatternedLoads
aic_fold_patterned_loads :: (i: Value_Id) -> bool {
    if inst_op(i) != .LOAD || (inst(i).flags & F_VOLATILE) != 0 return false;
    ptr := op(i, 0);
    gv := get_underlying_object(ptr);
    if vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return false;
    c := gv_initializer(gv);
    gv_size := dl_type_alloc_size(vtype(c));
    if gv_size == 0 || 4096 < gv_size return false;
    load_ty := vtype(i);
    bw := dl_index_type_size_bits(vtype(ptr));
    stride, const_off := aic_stride_and_mod_offset(ptr);
    la := inst(i).align;
    gv_align := glob(gv).align;
    if gv_align == 0 gv_align = 1;
    if la <= gv_align && ap_zext_value(stride) < la {
        const_off = ap_zero(bw);
        stride = ap_from_u64(bw, la);
    }
    ca := cfo_load_from_const(c, load_ty, const_off);
    if ca == NONE return false;
    e := cast,no_check(u32) (gv_size - dl_type_store_size(load_ty));
    while ap_zext_value(const_off) <= cast(u64) e {
        if ca != cfo_load_from_const(c, load_ty, const_off) return false;
        const_off = ap_add(const_off, stride);
    }
    rauw_with_metadata(i, ca);
    return true;
}

// ---------------------------------------------------------------- strncmp / memchr

// SplitBlock(Old, SplitPt, DTU, LI = nullptr, MSSAU = nullptr, BBName) (the DomTreeUpdater path)
split_block_dtu :: (old: Value_Id, split_pt: Value_Id, dtu: *Dtu, name := "") -> Value_Id {
    it := split_pt;
    while inst_op(it) == .PHI || is_eh_pad(it) it = inst_next(it);
    nm := name;
    if nm.count == 0 nm = tprint("%.split", vname(old));
    nb := split_basic_block(old, it, nm);
    if dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        array_add(*ups, .{true, old, nb});
        seen: [..] Value_Id; seen.allocator = temp;
        t := block_terminator(nb);
        for k: 0..cast(s64) num_successors(t) - 1 {
            s := get_successor(t, cast(u32) k);
            dup := false;
            for seen if it == s { dup = true; break; }
            if dup continue;
            array_add(*seen, s);
            array_add(*ups, .{true, nb, s});
            array_add(*ups, .{false, old, s});
        }
        dtu_apply(dtu, ups);
    }
    return nb;
}

// StrNCmpInliner::optimizeStrNCmp
aic_optimize_strncmp :: (ci: Value_Id, is_strncmp: bool, dtu: *Dtu) -> bool {
    if aic_cl.strncmp_inline_threshold < 2 return false;
    if !is_only_used_in_zero_comparison(ci) return false;
    s1p := call_arg(ci, 0); s2p := call_arg(ci, 1);
    if s1p == s2p return false;
    has1, str1 := get_constant_string_info(s1p, false);
    has2, str2 := get_constant_string_info(s2p, false);
    if has1 == has2 return false;
    str := ifx has1 then str1 else str2;
    strp := ifx has1 then s2p else s1p;
    idx := -1;
    for k: 0..str.count - 1 if str[k] == 0 { idx = k; break; }
    n: u64 = ifx idx < 0 then 0xFFFF_FFFF_FFFF_FFFF else cast(u64) idx + 1;
    if is_strncmp {
        len_arg := call_arg(ci, 2);
        if vkind(len_arg) == .C_INT && !is_vector_type(vtype(len_arg)) n = min(n, const_int_zext(len_arg));
        else return false;
    }
    if n > cast(u64) str.count || n < 2 || n > cast(u64) aic_cl.strncmp_inline_threshold return false;
    _, deref := pointer_dereferenceable_bytes(strp);
    if deref > 1 return false;
    aic_inline_compare(ci, strp, str, n, has1, dtu);
    return true;
}

// StrNCmpInliner::inlineCompare
aic_inline_compare :: (ci: Value_Id, lhs: Value_Id, rhs: string, n: u64, swapped: bool, dtu: *Dtu) {
    b: Irb;
    b.dbg = get_metadata(ci, 0);
    bbci := inst_block(ci);
    f := block_fn(bbci);
    bb_tail := split_block_dtu(bbci, ci, dtu, tprint("%.tail", vname(bbci)));
    subs: [..] Value_Id; subs.allocator = temp;
    for k: 0..n - 1 array_add(*subs, create_block(f, tprint("sub_%", k), bb_tail));
    bb_ne := create_block(f, "ne", bb_tail);
    set_successor(block_terminator(bbci), 0, subs[0]);

    irb_set_end(*b, bb_ne);
    ty := vtype(ci);
    phi := irb_phi(*b, ty, cast(u32) n);
    irb_insert(*b, create_br(bb_tail));

    base := lhs;
    for k: 0..n - 1 {
        irb_set_end(*b, subs[k]);
        gp := irb_inbounds_ptr_add(*b, base, const_int(ir.t_i64, k));
        ld := irb_load(*b, ir.t_i8, gp, dl_abi_align(ir.t_i8));
        vl := irb_cast(*b, .ZEXT, ld, ty);
        vr := const_int(ty, cast(u64) rhs[k]);
        sub := ifx swapped then irb_binop(*b, .SUB, vr, vl) else irb_binop(*b, .SUB, vl, vr);
        if k < n - 1 {
            cmp := irb_icmp(*b, ICMP_NE, sub, const_int(ty, 0));
            br := irb_insert(*b, create_cond_br(cmp, bb_ne, subs[k + 1]));
            ok, ec := fn_entry_count(f);
            if ok && ec > 0 aic_set_explicitly_unknown_branch_weights(br, "aggressive-instcombine");
        } else {
            irb_insert(*b, create_br(bb_ne));
        }
        phi_add_incoming(phi, sub, subs[k]);
    }
    rauw_with_metadata(ci, phi);
    erase_inst_with_metadata(ci);

    if dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        array_add(*ups, .{true, bbci, subs[0]});
        for k: 0..n - 1 {
            if k < n - 1 array_add(*ups, .{true, subs[k], subs[k + 1]});
            array_add(*ups, .{true, subs[k], bb_ne});
        }
        array_add(*ups, .{true, bb_ne, bb_tail});
        array_add(*ups, .{false, bbci, bb_tail});
        dtu_apply(dtu, ups);
    }
}

// setExplicitlyUnknownBranchWeights(I, PassName)
aic_set_explicitly_unknown_branch_weights :: (i: Value_Id, pass_name: string) {
    ops: [2] Md_Id;
    ops[0] = md_string("unknown");
    ops[1] = md_string(pass_name);
    set_metadata(i, md_kind_id("prof"), md_tuple(ops, false));
}

// foldMemChr
aic_fold_memchr :: (call: Value_Id, dtu: *Dtu) -> bool {
    if is_constant_kind(vkind(call_arg(call, 1))) return false;
    base := call_arg(call, 0);
    ok, str := get_constant_string_info(base, false);
    if !ok return false;
    n := cast(u64) str.count;
    len_arg := call_arg(call, 2);
    if vkind(len_arg) == .C_INT && !is_vector_type(vtype(len_arg)) {
        val := const_int_zext(len_arg);
        if val > n return false;
        n = val;
    } else return false;
    if n > cast(u64) aic_cl.memchr_inline_threshold return false;

    bb := inst_block(call);
    f := block_fn(bb);
    bb_next := split_block_dtu(bb, call, dtu);
    b: Irb;
    irb_set_end(*b, bb);
    b.dbg = get_metadata(call, 0);
    old_term := block_terminator(bb);
    erase_inst_with_metadata(old_term);
    byte_ty := ir.t_i8;
    tr := irb_cast(*b, .TRUNC, call_arg(call, 1), byte_ty);
    si := irb_insert(*b, create_switch(tr, bb_next, cast(u32) n));
    set_explicitly_unknown_branch_weights_if_profiled(si, "aggressive-instcombine");
    index_ty := type_int(dl_index_type_size_bits(vtype(call)));
    ups: [..] Dom_Update; ups.allocator = temp;

    bb_success := create_block(f, "memchr.success", bb_next);
    irb_set_end(*b, bb_success);
    index_phi := irb_phi(*b, index_ty, cast(u32) n, "memchr.idx");
    first_loc := irb_inbounds_ptr_add(*b, base, index_phi);
    irb_insert(*b, create_br(bb_next));
    if dtu array_add(*ups, .{true, bb_success, bb_next});

    cases: [..] Value_Id; cases.allocator = temp;
    for k: 0..cast(s64) n - 1 {
        cv := const_int(byte_ty, cast(u64) str[k]);
        dup := false;
        for cases if it == cv { dup = true; break; }
        if dup continue;
        array_add(*cases, cv);
        bb_case := create_block(f, "memchr.case", bb_success);
        sw_add_case(si, cv, bb_case);
        irb_set_end(*b, bb_case);
        phi_add_incoming(index_phi, const_int(index_ty, cast(u64) k), bb_case);
        irb_insert(*b, create_br(bb_success));
        if dtu {
            array_add(*ups, .{true, bb, bb_case});
            array_add(*ups, .{true, bb_case, bb_success});
        }
    }

    phi := create_phi(vtype(call), 2);
    insert_at_position(phi, bb_next, block_first(bb_next), true);
    if vname(call).count set_name(phi, vname(call));
    phi_add_incoming(phi, const_null_value(vtype(call)), bb);
    phi_add_incoming(phi, first_loc, bb_success);
    rauw_with_metadata(call, phi);
    erase_inst_with_metadata(call);
    if dtu dtu_apply(dtu, ups);
    return true;
}

// foldLibCalls
aic_fold_lib_calls :: (i: Value_Id, tti: *Tti, ac: *Assumption_Cache, dt: *Dom_Tree, made_cfg_change: *bool) -> bool {
    if inst_op(i) != .CALL || call_is_no_builtin(i) return false;
    callee := call_called_function(i);
    if callee == NONE return false;
    tli := tli_for(inst_fn(i));
    ok, lf := tli_lookup_fn(callee);
    if !ok || !is_lib_func_emittable(tli, lf) return false;
    dtu: Dtu;
    dtu.dt = dt; dtu.lazy = true;
    dtu.pending.allocator = temp; dtu.deleted.allocator = temp; dtu.deleted_set.allocator = temp;
    defer dtu_flush(*dtu);
    if lf == {
        case .sqrt; #through; case .sqrtf; #through; case .sqrtl;
            return aic_fold_sqrt(i, tti, ac, dt);
        case .strcmp; #through; case .strncmp;
            if aic_optimize_strncmp(i, lf == .strncmp, *dtu) { made_cfg_change.* = true; return true; }
        case .memchr;
            if aic_fold_memchr(i, *dtu) { made_cfg_change.* = true; return true; }
    }
    return false;
}

// ---------------------------------------------------------------- long multiplication

// foldMulHigh
aic_fold_mul_high :: (i: Value_Id) -> bool {
    ty := vtype(i);
    if !is_int_or_int_vector(ty) return false;
    bw := type_bits(scalar_type(ty));
    if bw % 2 != 0 return false;
    low_mask := ap_low_bits_set(bw, bw / 2);
    half := cast(u64) (bw / 2);

    st: Aic_Mul_High;
    st.i = i; st.ty = ty; st.bw = bw; st.low_mask = low_mask; st.half = half;

    // HiHi = m_OneUse(m_Mul(m_LShr(m_Value(X), half), m_LShr(m_Value(Y), half)))
    hihi :: (v: Value_Id, half: u64) -> (bool, Value_Id, Value_Id) {
        if !value_has_one_use(v) return false, NONE, NONE;
        ok, a, b := aic_bin(v, .MUL);
        if !ok return false, NONE, NONE;
        ok1, x, s1 := aic_bin(a, .LSHR);
        if !ok1 || !aic_specific_int_u64(s1, half) return false, NONE, NONE;
        ok2, y, s2 := aic_bin(b, .LSHR);
        if !ok2 || !aic_specific_int_u64(s2, half) return false, NONE, NONE;
        return true, x, y;
    }
    // m_c_Add(L, R) operands of v: (ok, op0, op1)
    is_add :: (v: Value_Id) -> (bool, Value_Id, Value_Id) { ok, a, b := aic_bin(v, .ADD); return ok, a, b; }

    x, y, a, b, c: Value_Id;
    // (match(I, m_c_Add(HiHi, m_OneUse(m_Add(m_Instruction(A), m_Instruction(B))))) ||
    //  match(I, m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(HiHi, m_Instruction(B)))))) && A, B one use
    matched := false;
    {
        ok, p, q := is_add(i);
        if ok {
            for side: 0..1 {
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                okh, hx, hy := hihi(l, half);
                if !okh continue;
                x = hx; y = hy;
                if !value_has_one_use(r) continue;
                oka, ra, rb := aic_bin(r, .ADD);
                if !oka || !is_inst(ra) || !is_inst(rb) continue;
                a = ra; b = rb; matched = true; break;
            }
            if !matched for side: 0..1 {
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if !is_inst(l) continue;
                a = l;
                if !value_has_one_use(r) continue;
                oka, ra, rb := is_add(r);
                if !oka continue;
                found := false;
                for s2: 0..1 {
                    hl := ifx s2 == 0 then ra else rb;
                    hr := ifx s2 == 0 then rb else ra;
                    okh, hx, hy := hihi(hl, half);
                    if !okh continue;
                    x = hx; y = hy;
                    if !is_inst(hr) continue;
                    b = hr; found = true; break;
                }
                if found { matched = true; break; }
            }
        }
    }
    if matched && value_has_one_use(a) && value_has_one_use(b) {
        if aic_mh_carry(*st, x, y, a, b) || aic_mh_ladder(*st, x, y, a, b) return true;
    }

    matched = false;
    // four alternatives with three extra operands
    {
        ok, p, q := is_add(i);
        if ok {
            // (1) m_c_Add(HiHi, m_OneUse(m_c_Add(m_Instruction(A), m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))))
            for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                okh, hx, hy := hihi(l, half);
                if !okh continue;
                x = hx; y = hy;
                if !value_has_one_use(r) continue;
                oka, ra, rb := is_add(r);
                if !oka continue;
                for s2: 0..1 {
                    il := ifx s2 == 0 then ra else rb;
                    ir_ := ifx s2 == 0 then rb else ra;
                    if !is_inst(il) continue;
                    a = il;
                    if !value_has_one_use(ir_) continue;
                    okb, bb_, cc := aic_bin(ir_, .ADD);
                    if !okb || !is_inst(bb_) || !is_inst(cc) continue;
                    b = bb_; c = cc; matched = true; break;
                }
            }
            // (2) m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(HiHi, m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))))
            if !matched for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if !is_inst(l) continue;
                a = l;
                if !value_has_one_use(r) continue;
                oka, ra, rb := is_add(r);
                if !oka continue;
                for s2: 0..1 {
                    hl := ifx s2 == 0 then ra else rb;
                    hr := ifx s2 == 0 then rb else ra;
                    okh, hx, hy := hihi(hl, half);
                    if !okh continue;
                    x = hx; y = hy;
                    if !value_has_one_use(hr) continue;
                    okb, bb_, cc := aic_bin(hr, .ADD);
                    if !okb || !is_inst(bb_) || !is_inst(cc) continue;
                    b = bb_; c = cc; matched = true; break;
                }
            }
            // (3) m_c_Add(m_Instruction(A), m_OneUse(m_c_Add(m_Instruction(B), m_OneUse(m_c_Add(HiHi, m_Instruction(C))))))
            if !matched for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if !is_inst(l) continue;
                a = l;
                if !value_has_one_use(r) continue;
                oka, ra, rb := is_add(r);
                if !oka continue;
                for s2: 0..1 {
                    if matched break;
                    bl := ifx s2 == 0 then ra else rb;
                    br := ifx s2 == 0 then rb else ra;
                    if !is_inst(bl) continue;
                    b = bl;
                    if !value_has_one_use(br) continue;
                    okc, ca, cb := is_add(br);
                    if !okc continue;
                    for s3: 0..1 {
                        hl := ifx s3 == 0 then ca else cb;
                        hr := ifx s3 == 0 then cb else ca;
                        okh, hx, hy := hihi(hl, half);
                        if !okh continue;
                        x = hx; y = hy;
                        if !is_inst(hr) continue;
                        c = hr; matched = true; break;
                    }
                }
            }
            // (4) m_c_Add(m_OneUse(m_c_Add(HiHi, m_Instruction(A))), m_OneUse(m_Add(m_Instruction(B), m_Instruction(C))))
            if !matched for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if !value_has_one_use(l) continue;
                oka, la, lb := is_add(l);
                if !oka continue;
                found := false;
                for s2: 0..1 {
                    hl := ifx s2 == 0 then la else lb;
                    hr := ifx s2 == 0 then lb else la;
                    okh, hx, hy := hihi(hl, half);
                    if !okh continue;
                    x = hx; y = hy;
                    if !is_inst(hr) continue;
                    a = hr; found = true; break;
                }
                if !found continue;
                if !value_has_one_use(r) continue;
                okb, bb_, cc := aic_bin(r, .ADD);
                if !okb || !is_inst(bb_) || !is_inst(cc) continue;
                b = bb_; c = cc; matched = true;
            }
        }
    }
    if matched && value_has_one_use(a) && value_has_one_use(b) && value_has_one_use(c)
        return aic_mh_carry4(*st, x, y, a, b, c) || aic_mh_ladder4(*st, x, y, a, b, c);
    return false;
}

Aic_Mul_High :: struct { i: Value_Id; ty: Type_Id; bw: u32; low_mask: APInt; half: u64; }

// CreateMulHigh
aic_mh_create :: (s: *Aic_Mul_High, x: Value_Id, y: Value_Id) -> bool {
    b: Irb;
    irb_set_before(*b, s.i);
    nty := type_with_new_bit_width(s.ty, s.bw * 2);
    xe := irb_cast(*b, .ZEXT, x, nty);
    ye := irb_cast(*b, .ZEXT, y, nty);
    mul := irb_binop(*b, .MUL, xe, ye, "", F_NUW);
    high := irb_binop(*b, .LSHR, mul, const_int(nty, cast(u64) s.bw));
    res := irb_trunc_flags(*b, high, s.ty, "", true, false);
    ic_take_name(res, s.i);
    rauw_with_metadata(s.i, res);
    return true;
}
// m_And(m_Specific(V), m_SpecificInt(LowMask))
aic_mh_and_low :: (s: *Aic_Mul_High, v: Value_Id, spec: Value_Id) -> bool {
    ok, a, m := aic_bin(v, .AND);
    return ok && a == spec && aic_specific_int(m, s.low_mask);
}
// m_LShr(m_Specific(V), m_SpecificInt(half))
aic_mh_shr_half :: (s: *Aic_Mul_High, v: Value_Id, spec: Value_Id) -> bool {
    ok, a, m := aic_bin(v, .LSHR);
    return ok && a == spec && aic_specific_int_u64(m, s.half);
}
// m_LShr(m_Value(X), m_SpecificInt(half)): X
aic_mh_shr_half_any :: (s: *Aic_Mul_High, v: Value_Id) -> (bool, Value_Id) {
    ok, a, m := aic_bin(v, .LSHR);
    if ok && aic_specific_int_u64(m, s.half) return true, a;
    return false, NONE;
}
// CheckLoLo
aic_mh_check_lolo :: (s: *Aic_Mul_High, v: Value_Id, x: Value_Id, y: Value_Id) -> bool {
    ok, a, b := aic_bin(v, .MUL);
    if !ok return false;
    return (aic_mh_and_low(s, a, x) && aic_mh_and_low(s, b, y)) || (aic_mh_and_low(s, b, x) && aic_mh_and_low(s, a, y));
}
// CheckHiLo
aic_mh_check_hilo :: (s: *Aic_Mul_High, v: Value_Id, x: Value_Id, y: Value_Id) -> bool {
    ok, a, b := aic_bin(v, .MUL);
    if !ok return false;
    return (aic_mh_shr_half(s, a, x) && aic_mh_and_low(s, b, y)) || (aic_mh_shr_half(s, b, x) && aic_mh_and_low(s, a, y));
}
// m_OneUse(m_Select(m_OneUse(m_SpecificICmp(ULT, m_Value(A), m_Value(B))), m_SpecificInt(1 << half), m_Zero())): (ok, a, b)
aic_mh_carry_select :: (s: *Aic_Mul_High, v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if !value_has_one_use(v) return false, NONE, NONE;
    oks, cond, t, f := pm_select(v);
    if !oks || !value_has_one_use(cond) return false, NONE, NONE;
    okc, a, b := aic_specific_icmp(cond, ICMP_ULT);
    if !okc return false, NONE, NONE;
    if !aic_specific_int(t, ap_one_bit_set(s.bw, cast(u32) s.half)) || !pm_zero(f) return false, NONE, NONE;
    return true, a, b;
}

// FoldMulHighCarry
aic_mh_carry :: (s: *Aic_Mul_High, x_in: Value_Id, y_in: Value_Id, carry_in: Value_Id, b_in: Value_Id) -> bool {
    x := x_in; y := y_in; carry := carry_in; b := b_in;
    if inst_op(carry) != .SELECT { t := carry; carry = b; b = t; }
    okc, low_sum, xhyl := aic_mh_carry_select(s, carry);
    if !okc return false;
    if !aic_mh_check_hilo(s, xhyl, x, y) {
        if aic_mh_check_hilo(s, xhyl, y, x) { t := x; x = y; y = t; }
        else return false;
    }
    if aic_has_n_uses_or_more(xhyl, 3) return false;
    if !value_has_one_use(b) || !aic_mh_shr_half(s, b, low_sum) || aic_has_n_uses_or_more(low_sum, 3) return false;
    // LowSum = XhYl + XlYh + XlYl>>32
    xlyh: Value_Id = NONE; xlyl: Value_Id = NONE;
    found := false;
    ok, p, q := aic_bin(low_sum, .ADD);
    if ok {
        // m_c_Add(m_Specific(XhYl), m_OneUse(m_c_Add(m_OneUse(m_Value(XlYh)), XlYlHi)))
        for side: 0..1 {
            if found break;
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            if l != xhyl || !value_has_one_use(r) continue;
            oki, ia, ib := aic_bin(r, .ADD);
            if !oki continue;
            for s2: 0..1 {
                il := ifx s2 == 0 then ia else ib;
                ir_ := ifx s2 == 0 then ib else ia;
                if !value_has_one_use(il) continue;
                okh, v := aic_mh_shr_half_any(s, ir_);
                if !okh continue;
                xlyh = il; xlyl = v; found = true; break;
            }
        }
        // m_c_Add(m_OneUse(m_Value(XlYh)), m_OneUse(m_c_Add(m_Specific(XhYl), XlYlHi)))
        if !found for side: 0..1 {
            if found break;
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            if !value_has_one_use(l) || !value_has_one_use(r) continue;
            oki, ia, ib := aic_bin(r, .ADD);
            if !oki continue;
            for s2: 0..1 {
                il := ifx s2 == 0 then ia else ib;
                ir_ := ifx s2 == 0 then ib else ia;
                if il != xhyl continue;
                okh, v := aic_mh_shr_half_any(s, ir_);
                if !okh continue;
                xlyh = l; xlyl = v; found = true; break;
            }
        }
        // m_c_Add(XlYlHi, m_OneUse(m_c_Add(m_Specific(XhYl), m_OneUse(m_Value(XlYh)))))
        if !found for side: 0..1 {
            if found break;
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            okh, v := aic_mh_shr_half_any(s, l);
            if !okh || !value_has_one_use(r) continue;
            oki, ia, ib := aic_bin(r, .ADD);
            if !oki continue;
            for s2: 0..1 {
                il := ifx s2 == 0 then ia else ib;
                ir_ := ifx s2 == 0 then ib else ia;
                if il != xhyl || !value_has_one_use(ir_) continue;
                xlyh = ir_; xlyl = v; found = true; break;
            }
        }
    }
    if !found return false;
    if !aic_mh_check_lolo(s, xlyl, x, y) return false;
    if !aic_mh_check_hilo(s, xlyh, y, x) return false;
    return aic_mh_create(s, x, y);
}

// FoldMulHighLadder
aic_mh_ladder :: (s: *Aic_Mul_High, x: Value_Id, y: Value_Id, a: Value_Id, b: Value_Id) -> bool {
    ok1, c2 := aic_mh_shr_half_any(s, a);
    if !ok1 return false;
    ok2, c3 := aic_mh_shr_half_any(s, b);
    if !ok2 return false;
    // if (match(C3, m_c_Add(m_Add(m_Value(), m_Value()), m_Value()))) swap
    {
        ok, p, q := aic_bin(c3, .ADD);
        if ok {
            pa := aic_bin(p, .ADD);
            qa := aic_bin(q, .ADD);
            if pa || qa { t := c2; c2 = c3; c3 = t; }
        }
    }
    xlyh: Value_Id = NONE; xhyl: Value_Id = NONE; xlyl: Value_Id = NONE;
    matched := false;
    {
        ok, p, q := aic_bin(c2, .ADD);
        if ok {
            // m_c_Add(m_c_Add(m_And(m_Specific(C3), LowMask), m_Value(XlYh)), m_LShr(m_Value(XlYl), half))
            for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                oki, ia, ib := aic_bin(l, .ADD);
                if !oki continue;
                okh, v := aic_mh_shr_half_any(s, r);
                if !okh continue;
                for s2: 0..1 {
                    il := ifx s2 == 0 then ia else ib;
                    ir_ := ifx s2 == 0 then ib else ia;
                    if !aic_mh_and_low(s, il, c3) continue;
                    xlyh = ir_; xlyl = v; matched = true; break;
                }
            }
            // m_c_Add(m_c_Add(m_And(m_Specific(C3), LowMask), m_LShr(m_Value(XlYl), half)), m_Value(XlYh))
            if !matched for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                oki, ia, ib := aic_bin(l, .ADD);
                if !oki continue;
                for s2: 0..1 {
                    il := ifx s2 == 0 then ia else ib;
                    ir_ := ifx s2 == 0 then ib else ia;
                    if !aic_mh_and_low(s, il, c3) continue;
                    okh, v := aic_mh_shr_half_any(s, ir_);
                    if !okh continue;
                    xlyl = v; xlyh = r; matched = true; break;
                }
            }
            // m_c_Add(m_c_Add(m_LShr(m_Value(XlYl), half), m_Value(XlYh)), m_And(m_Specific(C3), LowMask))
            if !matched for side: 0..1 {
                if matched break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                oki, ia, ib := aic_bin(l, .ADD);
                if !oki continue;
                if !aic_mh_and_low(s, r, c3) continue;
                for s2: 0..1 {
                    il := ifx s2 == 0 then ia else ib;
                    ir_ := ifx s2 == 0 then ib else ia;
                    okh, v := aic_mh_shr_half_any(s, il);
                    if !okh continue;
                    xlyl = v; xlyh = ir_; matched = true; break;
                }
            }
        }
    }
    if matched {
        xhyl = c3;
    } else {
        // c3 = c2&LowMask + xl*yh
        and_c2 :: (s: *Aic_Mul_High, v: Value_Id, c2: Value_Id, need_one_use: bool) -> (bool, Value_Id) {
            ok, p, q := aic_bin(v, .ADD);
            if !ok return false, NONE;
            for side: 0..1 {
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if need_one_use && !value_has_one_use(l) continue;
                if aic_mh_and_low(s, l, c2) return true, r;
            }
            return false, NONE;
        }
        okm := and_c2(s, c3, c2, false);
        if !okm { t := c2; c2 = c3; c3 = t; }
        okm2, v := and_c2(s, c3, c2, true);
        if !okm2 || !value_has_one_use(c3) || aic_has_n_uses_or_more(c2, 3) return false;
        xlyh = v;
        // c2 = xh*yl + (xl*yl >> 32)
        found := false;
        ok, p, q := aic_bin(c2, .ADD);
        if ok for side: 0..1 {
            l := ifx side == 0 then p else q;
            r := ifx side == 0 then q else p;
            okh, w := aic_mh_shr_half_any(s, l);
            if !okh continue;
            xlyl = w; xhyl = r; found = true; break;
        }
        if !found return false;
    }
    if !aic_mh_check_hilo(s, xlyh, y, x) { t := xlyh; xlyh = xhyl; xhyl = t; }
    if !aic_mh_check_hilo(s, xlyh, y, x) return false;
    if !aic_mh_check_hilo(s, xhyl, x, y) return false;
    if !aic_mh_check_lolo(s, xlyl, x, y) return false;
    return aic_mh_create(s, x, y);
}

// FoldMulHighLadder4
aic_mh_ladder4 :: (s: *Aic_Mul_High, x: Value_Id, y: Value_Id, a_in: Value_Id, b_in: Value_Id, c_in: Value_Id) -> bool {
    a := a_in; b := b_in; c := c_in;
    shift_add :: (s: *Aic_Mul_High, v: Value_Id) -> bool {
        ok, w := aic_mh_shr_half_any(s, v);
        if !ok return false;
        oka := aic_bin(w, .ADD);
        return oka;
    }
    if !shift_add(s, a) { t := a; a = b; b = t; }
    if !shift_add(s, a) { t := a; a = c; c = t; }
    ok, low := aic_mh_shr_half_any(s, a);
    if !ok || !value_has_one_use(low) return false;
    okb, xhyl := aic_mh_shr_half_any(s, b);
    if !okb return false;
    okc, xlyh := aic_mh_shr_half_any(s, c);
    if !okc return false;
    if !aic_mh_check_hilo(s, xhyl, x, y) { t := xhyl; xhyl = xlyh; xlyh = t; }
    if !aic_mh_check_hilo(s, xhyl, x, y) || aic_has_n_uses_or_more(xhyl, 3) return false;
    if !aic_mh_check_hilo(s, xlyh, y, x) || aic_has_n_uses_or_more(xlyh, 3) return false;
    // Low = XlYl>>32 + XhYl&Low + XlYh&Low (three groupings)
    one_and :: (s: *Aic_Mul_High, v: Value_Id, spec: Value_Id) -> bool { return value_has_one_use(v) && aic_mh_and_low(s, v, spec); }
    one_shr :: (s: *Aic_Mul_High, v: Value_Id) -> (bool, Value_Id) {
        if !value_has_one_use(v) return false, NONE;
        ok, w := aic_mh_shr_half_any(s, v);
        return ok, w;
    }
    xlyl: Value_Id = NONE;
    found := false;
    okl, p, q := aic_bin(low, .ADD);
    if okl {
        for alt: 0..2 {
            if found break;
            for side: 0..1 {
                if found break;
                l := ifx side == 0 then p else q;
                r := ifx side == 0 then q else p;
                if !value_has_one_use(l) continue;
                oki, ia, ib := aic_bin(l, .ADD);
                if !oki continue;
                for s2: 0..1 {
                    il := ifx s2 == 0 then ia else ib;
                    ir_ := ifx s2 == 0 then ib else ia;
                    if alt == 0 {
                        if !one_and(s, il, xhyl) || !one_and(s, ir_, xlyh) continue;
                        oks, w := one_shr(s, r);
                        if !oks continue;
                        xlyl = w; found = true; break;
                    } else if alt == 1 {
                        if !one_and(s, il, xhyl) continue;
                        oks, w := one_shr(s, ir_);
                        if !oks || !one_and(s, r, xlyh) continue;
                        xlyl = w; found = true; break;
                    } else {
                        if !one_and(s, il, xlyh) continue;
                        oks, w := one_shr(s, ir_);
                        if !oks || !one_and(s, r, xhyl) continue;
                        xlyl = w; found = true; break;
                    }
                }
            }
        }
    }
    if !found return false;
    if !aic_mh_check_lolo(s, xlyl, x, y) return false;
    return aic_mh_create(s, x, y);
}

// FoldMulHighCarry4
aic_mh_carry4 :: (s: *Aic_Mul_High, x_in: Value_Id, y_in: Value_Id, carry_in: Value_Id, b_in: Value_Id, c_in: Value_Id) -> bool {
    x := x_in; y := y_in; carry := carry_in; b := b_in; c := c_in;
    if inst_op(carry) != .SELECT { t := carry; carry = b; b = t; }
    if inst_op(carry) != .SELECT { t := carry; carry = c; c = t; }
    okc, cross, xhyl := aic_mh_carry_select(s, carry);
    if !okc return false;
    if !aic_mh_shr_half(s, b, cross) { t := b; b = c; c = t; }
    if !aic_mh_shr_half(s, b, cross) return false;
    oka, low_accum := aic_mh_shr_half_any(s, c);
    if !oka return false;
    xlyl: Value_Id = NONE;
    found := false;
    ok, p, q := aic_bin(low_accum, .ADD);
    if ok for side: 0..1 {
        l := ifx side == 0 then p else q;
        r := ifx side == 0 then q else p;
        if !value_has_one_use(l) continue;
        okh, w := aic_mh_shr_half_any(s, l);
        if !okh || !value_has_one_use(r) || !aic_mh_and_low(s, r, cross) continue;
        xlyl = w; found = true; break;
    }
    if !found || aic_has_n_uses_or_more(low_accum, 3) return false;
    if !aic_mh_check_lolo(s, xlyl, x, y) return false;
    if !aic_mh_check_hilo(s, xhyl, x, y) { t := x; x = y; y = t; }
    if !aic_mh_check_hilo(s, xhyl, x, y) return false;
    xlyh: Value_Id = NONE;
    found = false;
    ok, p, q = aic_bin(cross, .ADD);
    if ok for side: 0..1 {
        l := ifx side == 0 then p else q;
        r := ifx side == 0 then q else p;
        if l != xhyl || !value_has_one_use(r) continue;
        xlyh = r; found = true; break;
    }
    if !found || !aic_mh_check_hilo(s, xlyh, y, x) || aic_has_n_uses_or_more(cross, 4) || aic_has_n_uses_or_more(xhyl, 3)
        return false;
    return aic_mh_create(s, x, y);
}

// ---------------------------------------------------------------- driver

// foldUnusualPatterns
aic_fold_unusual_patterns :: (f: Value_Id, dt: *Dom_Tree, tti: *Tti, aar: *Aa_Results, ac: *Assumption_Cache, made_cfg_change: *bool) -> bool {
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        defer bb = block(bb).next;
        if !dt_is_reachable_from_entry(dt, bb) continue;
        i := block(bb).last;
        while i != NONE {
            prev := inst(i).prev;
            if aic_fold_any_or_all_bits_set(i) changed = true;
            if aic_fold_guarded_funnel_shift(i, dt) changed = true;
            if aic_fold_select_split_ctlz_cttz(i) changed = true;
            if aic_try_popcount(i) changed = true;
            if aic_try_popcount1(i) changed = true;
            if aic_try_popcount2n3(i) changed = true;
            if aic_try_fp_to_sat(i, tti) changed = true;
            if aic_try_table_cttz_or_log2(i, tti) changed = true;
            if aic_fold_consecutive_loads(i, tti, aar, dt) changed = true;
            if aic_fold_patterned_loads(i) changed = true;
            if aic_fold_icmp_or_chain(i, tti, aar, dt) changed = true;
            if aic_fold_mul_high(i) changed = true;
            if aic_fold_lib_calls(i, tti, ac, dt, made_cfg_change) changed = true;
            i = prev;
        }
        if aic_fold_consecutive_stores(bb, tti, aar) changed = true;
    }
    if changed {
        for b: fn_blocks(f) simplify_instructions_in_block(b, use_tli = false);
    }
    return changed;
}

aggressive_instcombine_run :: (f: Value_Id) -> Preserved {
    ac := get_assumption_cache(f);
    tli_for(f);
    dt := get_domtree(f);
    tti := tti_get(f);
    aar := aa_results_for(f);
    made_cfg_change := false;
    changed := tic_run(f, ac, dt);
    if aic_fold_unusual_patterns(f, dt, tti, *aar, ac, *made_cfg_change) changed = true;
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    if made_cfg_change preserve(*pa, .DOMTREE);
    else pa = preserved_cfg();
    return pa;
}
