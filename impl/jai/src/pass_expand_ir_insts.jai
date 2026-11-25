// ExpandIRInsts (`expand-ir-insts`, `expand-ir-insts<O0..O3>`; llc's ExpandIRInstsLegacyPass): port of
// llvm/lib/CodeGen/ExpandIRInsts.cpp (runImpl, scalarize, expandPow2DivRem, expandFPToI, expandIToFP) and of
// llvm/lib/Transforms/Utils/IntegerDivision.cpp (expandDivision, expandRemainder and the generate*Code helpers).
// X86TargetLowering: getMaxDivRemBitWidthSupported is 128 on x86-64 (64 on 32-bit x86), getMaxLargeFPConvertBitWidth
// 128. FREM is a libcall for every FRemExpander::ExpandableTypes type on x86, so the frem expansion (FRemExpander)
// never runs (DisableFrem).

eii_cl: struct {
    fp_convert_bits: u64 = EII_MAX_INT_BITS;   // -expand-fp-convert-bits
    div_rem_bits: u64 = EII_MAX_INT_BITS;      // -expand-div-rem-bits
}
EII_MAX_INT_BITS :: 8388608;   // IntegerType::MAX_INT_BITS
EII_LIKELY :: 0xFFFFF;         // MDBuilder::kLikelyBranchWeight = (1 << 20) - 1
EII_UNLIKELY :: 1;

eii_prof_fixes :: () -> bool { return !slu_opts.profcheck_disable_metadata_fixes; }   // ProfcheckDisableMetadataFixes
// applyProfMetadataIfEnabled(V, createUnlikelyBranchWeights / createLikelyBranchWeights)
eii_set_weights :: (v: Value_Id, likely: bool) {
    if !eii_prof_fixes() || !is_inst(v) return;
    w: [2] u32;
    if likely { w[0] = EII_LIKELY; w[1] = EII_UNLIKELY; } else { w[0] = EII_UNLIKELY; w[1] = EII_LIKELY; }
    prof_set_branch_weights(v, w, false);
}
eii_set_unknown :: (v: Value_Id, pass_name: string) {
    if !eii_prof_fixes() || !is_inst(v) return;
    set_explicitly_unknown_branch_weights_if_profiled(v, pass_name);
}
// CreateSelectWithUnknownProfile(C, T, F, PassName): the select's !prof only when the function has a profile
eii_select_unknown :: (b: *Irb, c: Value_Id, t: Value_Id, f: Value_Id, pass_name: string) -> Value_Id {
    s := irb_select(b, c, t, f);
    if is_inst(s) && inst_op(s) == .SELECT set_explicitly_unknown_branch_weights_if_profiled(s, pass_name);
    return s;
}

eii_c :: (bits: u32, v: s64) -> Value_Id { return const_int(type_int(bits), cast,no_check(u64) v); }
eii_fcmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    if irb_is_const(l) && irb_is_const(r) { f := cf_compare(pred, l, r); if f != NONE return f; }
    return irb_insert(b, create_fcmp(pred, l, r), name);
}
eii_zext_or_trunc :: (b: *Irb, v: Value_Id, t: Value_Id) -> Value_Id {
    vb := type_bits(vtype(v)); tb := type_bits(t);
    if vb < tb return irb_cast(b, .ZEXT, v, t);
    if vb > tb return irb_cast(b, .TRUNC, v, t);
    return v;
}
// CreateIntCast(V, Ty, isSigned)
eii_int_cast :: (b: *Irb, v: Value_Id, t: Type_Id, signed: bool) -> Value_Id {
    vb := type_bits(vtype(v)); tb := type_bits(t);
    if vb == tb return v;
    if vb > tb return irb_cast(b, .TRUNC, v, t);
    return irb_cast(b, ifx signed then Opcode.SEXT else .ZEXT, v, t);
}
eii_logical_or :: (b: *Irb, a: Value_Id, c: Value_Id) -> Value_Id { return irb_select(b, a, const_int(ir.t_i1, 1), c); }
eii_ctlz :: (b: *Irb, v: Value_Id) -> Value_Id {
    f := get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.ctlz"), .[vtype(v)]);
    return irb_call(b, f, .[v, const_int(ir.t_i1, 1)]);
}
// Entry->splitBasicBlock(InsertPoint) and erase the new branch (its debug records go to the next terminator built
// at the end of the entry block, like trailing records)
eii_split :: (entry: Value_Id, at: Value_Id, name: string) -> (Value_Id, u32) {
    endb := split_basic_block(entry, at, name);
    br := block_last(entry);
    r := records_take(br);
    erase_inst_with_metadata(br);
    return endb, r;
}
eii_cond_br :: (b: *Irb, c: Value_Id, t: Value_Id, f: Value_Id, records: *u32) -> Value_Id {
    br := irb_insert(b, create_cond_br(c, t, f));
    if records.* { attach_records_before(br, records.*); records.* = 0; }
    return br;
}
eii_replace :: (old: Value_Id, new: Value_Id) {
    rauw_with_metadata(old, new);
    drop_all_references(old);
    erase_inst_with_metadata(old);
}

// ---------------------------------------------------------------- div / rem by a power of two

eii_is_const_pow2 :: (v: Value_Id, signed: bool) -> bool {
    if !is_constant_int(v) return false;
    a := const_ap(v);
    if signed && ap_is_negative(a) a = ap_neg(a);
    return ap_is_power_of_2(a);
}

eii_expand_pow2_divrem :: (bo: Value_Id) {
    opc := inst_op(bo);
    is_div := opc == .UDIV || opc == .SDIV;
    signed := opc == .SDIV || opc == .SREM;
    exact := is_div && (inst(bo).flags & F_EXACT) != 0;
    x := op(bo, 0);
    dv := const_ap(op(bo, 1));
    ty := vtype(bo);
    bw := type_bits(ty);
    neg_div := signed && ap_is_negative(dv);
    shift := ap_ctz(dv);
    b: Irb; irb_set_before(*b, bo);
    neg :: (b: *Irb, v: Value_Id) -> Value_Id { return irb_binop(b, .SUB, const_null_value(vtype(v)), v); }   // CreateNeg
    result: Value_Id;
    if shift == 0 {
        if is_div result = ifx neg_div then neg(*b, x) else x;
        else result = const_int(ty, 0);
    } else if signed {
        if !exact && !is_guaranteed_not_to_be_undef_or_poison(x) x = irb_freeze(*b, x, tconcat(vname(x), ".fr"));
        dividend := x;
        if !exact {
            sign := irb_binop(*b, .ASHR, x, eii_c(bw, bw - 1), "sign");
            bias := irb_binop(*b, .LSHR, sign, eii_c(bw, bw - cast(s64) shift), "bias");
            dividend = irb_binop(*b, .ADD, x, bias, "adjusted");
        }
        q := irb_binop(*b, .ASHR, dividend, eii_c(bw, shift), ifx is_div && neg_div then "pre.neg" else "shifted", ifx exact then cast(u32) F_EXACT else 0);
        if is_div result = ifx neg_div then neg(*b, q) else q;
        else {
            t := irb_binop(*b, .SHL, q, eii_c(bw, shift), "truncated");
            result = irb_binop(*b, .SUB, x, t);
        }
    } else {
        if is_div result = irb_binop(*b, .LSHR, x, eii_c(bw, shift), "", ifx exact then cast(u32) F_EXACT else 0);
        else result = irb_binop(*b, .AND, x, const_int_ap(ty, ap_low_bits_set(bw, shift)));
    }
    rauw_with_metadata(bo, result);
    if result != x && is_inst(result) take_name(result, bo);
    drop_all_references(bo);
    erase_inst_with_metadata(bo);
}

// ---------------------------------------------------------------- IntegerDivision.cpp

// generateSignedRemainderCode: (srem, the urem to expand or NONE)
eii_signed_remainder :: (b: *Irb, dividend_in: Value_Id, divisor_in: Value_Id) -> (Value_Id, Value_Id) {
    bw := type_bits(vtype(dividend_in));
    sh := eii_c(bw, bw - 1);
    dividend := irb_freeze(b, dividend_in);
    divisor := irb_freeze(b, divisor_in);
    dvd_sgn := irb_binop(b, .ASHR, dividend, sh);
    dvs_sgn := irb_binop(b, .ASHR, divisor, sh);
    dvd_xor := irb_binop(b, .XOR, dividend, dvd_sgn);
    dvs_xor := irb_binop(b, .XOR, divisor, dvs_sgn);
    ud := irb_binop(b, .SUB, dvd_xor, dvd_sgn);
    us := irb_binop(b, .SUB, dvs_xor, dvs_sgn);
    urem := irb_binop(b, .UREM, ud, us);
    xored := irb_binop(b, .XOR, urem, dvd_sgn);
    srem := irb_binop(b, .SUB, xored, dvd_sgn);
    if is_inst(urem) { irb_set_before(b, urem); return srem, urem; }
    return srem, NONE;
}
// generateUnsignedRemainderCode: (remainder, the udiv to expand or NONE)
eii_unsigned_remainder :: (b: *Irb, dividend_in: Value_Id, divisor_in: Value_Id) -> (Value_Id, Value_Id) {
    dividend := irb_freeze(b, dividend_in);
    divisor := irb_freeze(b, divisor_in);
    q := irb_binop(b, .UDIV, dividend, divisor);
    p := irb_binop(b, .MUL, divisor, q);
    r := irb_binop(b, .SUB, dividend, p);
    if is_inst(q) { irb_set_before(b, q); return r, q; }
    return r, NONE;
}
// generateSignedDivisionCode
eii_signed_division :: (b: *Irb, dividend_in: Value_Id, divisor_in: Value_Id) -> (Value_Id, Value_Id) {
    bw := type_bits(vtype(dividend_in));
    sh := eii_c(bw, bw - 1);
    dividend := irb_freeze(b, dividend_in);
    divisor := irb_freeze(b, divisor_in);
    tmp := irb_binop(b, .ASHR, dividend, sh);
    tmp1 := irb_binop(b, .ASHR, divisor, sh);
    tmp2 := irb_binop(b, .XOR, tmp, dividend);
    u_dvnd := irb_binop(b, .SUB, tmp2, tmp);
    tmp3 := irb_binop(b, .XOR, tmp1, divisor);
    u_dvsr := irb_binop(b, .SUB, tmp3, tmp1);
    q_sgn := irb_binop(b, .XOR, tmp1, tmp);
    q_mag := irb_binop(b, .UDIV, u_dvnd, u_dvsr);
    tmp4 := irb_binop(b, .XOR, q_mag, q_sgn);
    q := irb_binop(b, .SUB, tmp4, q_sgn);
    if is_inst(q_mag) { irb_set_before(b, q_mag); return q, q_mag; }
    return q, NONE;
}
// generateUnsignedDivisionCode (the builder is positioned at the udiv)
eii_unsigned_division :: (b: *Irb, dividend_in: Value_Id, divisor_in: Value_Id) -> Value_Id {
    div_ty := vtype(dividend_in);
    bw := type_bits(div_ty);
    zero := const_int(div_ty, 0);
    one := const_int(div_ty, 1);
    neg_one := const_all_ones_of(div_ty);
    msb := const_int(div_ty, cast(u64) (bw - 1));
    special := b.bb;
    f := block_fn(special);
    set_name(special, tconcat(vname(special), "_udiv-special-cases"));
    endb, recs := eii_split(special, b.pt, "udiv-end");
    loop_exit := create_block(f, "udiv-loop-exit", endb);
    do_while := create_block(f, "udiv-do-while", endb);
    preheader := create_block(f, "udiv-preheader", endb);
    bb1 := create_block(f, "udiv-bb1", endb);

    irb_set_end(b, special);
    divisor := irb_freeze(b, divisor_in);
    dividend := irb_freeze(b, dividend_in);
    ret0_1 := irb_icmp(b, ICMP_EQ, divisor, zero);
    ret0_2 := irb_icmp(b, ICMP_EQ, dividend, zero);
    ret0_3 := irb_binop(b, .OR, ret0_1, ret0_2);
    tmp0 := eii_ctlz(b, divisor);
    tmp1 := eii_ctlz(b, dividend);
    sr := irb_binop(b, .SUB, tmp0, tmp1);
    ret0_4 := irb_icmp(b, ICMP_UGT, sr, msb);
    ret0 := eii_logical_or(b, ret0_3, ret0_4);
    eii_set_weights(ret0, false);
    ret_dividend := irb_icmp(b, ICMP_EQ, sr, msb);
    ret_val := irb_select(b, ret0, zero, dividend);
    eii_set_unknown(ret_val, "integer-division");
    early_ret := eii_logical_or(b, ret0, ret_dividend);
    eii_set_unknown(early_ret, "integer-division");
    br_special := eii_cond_br(b, early_ret, endb, bb1, *recs);
    eii_set_weights(br_special, false);

    irb_set_end(b, bb1);
    sr_1 := irb_binop(b, .ADD, sr, one);
    tmp2 := irb_binop(b, .SUB, msb, sr);
    q := irb_binop(b, .SHL, dividend, tmp2);
    skip_loop := irb_icmp(b, ICMP_EQ, sr_1, zero);
    br_bb1 := irb_insert(b, create_cond_br(skip_loop, loop_exit, preheader));
    eii_set_weights(br_bb1, false);

    irb_set_end(b, preheader);
    tmp3 := irb_binop(b, .LSHR, dividend, sr_1);
    tmp4 := irb_binop(b, .ADD, divisor, neg_one);
    irb_br(b, do_while);

    irb_set_end(b, do_while);
    carry_1 := irb_phi(b, div_ty, 2);
    sr_3 := irb_phi(b, div_ty, 2);
    r_1 := irb_phi(b, div_ty, 2);
    q_2 := irb_phi(b, div_ty, 2);
    tmp5 := irb_binop(b, .SHL, r_1, one);
    tmp6 := irb_binop(b, .LSHR, q_2, msb);
    tmp7 := irb_binop(b, .OR, tmp5, tmp6);
    tmp8 := irb_binop(b, .SHL, q_2, one);
    q_1 := irb_binop(b, .OR, carry_1, tmp8);
    tmp9 := irb_binop(b, .SUB, tmp4, tmp7);
    tmp10 := irb_binop(b, .ASHR, tmp9, msb);
    carry := irb_binop(b, .AND, tmp10, one);
    tmp11 := irb_binop(b, .AND, tmp10, divisor);
    r := irb_binop(b, .SUB, tmp7, tmp11);
    sr_2 := irb_binop(b, .ADD, sr_3, neg_one);
    tmp12 := irb_icmp(b, ICMP_EQ, sr_2, zero);
    br_do := irb_insert(b, create_cond_br(tmp12, loop_exit, do_while));
    eii_set_weights(br_do, false);

    irb_set_end(b, loop_exit);
    carry_2 := irb_phi(b, div_ty, 2);
    q_3 := irb_phi(b, div_ty, 2);
    tmp13 := irb_binop(b, .SHL, q_3, one);
    q_4 := irb_binop(b, .OR, carry_2, tmp13);
    irb_br(b, endb);

    irb_set_at(b, endb, block(endb).first, true);
    q_5 := irb_phi(b, div_ty, 2);
    phi_add_incoming(carry_1, zero, preheader); phi_add_incoming(carry_1, carry, do_while);
    phi_add_incoming(sr_3, sr_1, preheader); phi_add_incoming(sr_3, sr_2, do_while);
    phi_add_incoming(r_1, tmp3, preheader); phi_add_incoming(r_1, r, do_while);
    phi_add_incoming(q_2, q, preheader); phi_add_incoming(q_2, q_1, do_while);
    phi_add_incoming(carry_2, zero, bb1); phi_add_incoming(carry_2, carry, do_while);
    phi_add_incoming(q_3, q, bb1); phi_add_incoming(q_3, q_1, do_while);
    phi_add_incoming(q_5, q_4, loop_exit); phi_add_incoming(q_5, ret_val, special);
    return q_5;
}

// expandDivision
eii_expand_division :: (div_in: Value_Id) {
    div := div_in;
    b: Irb; irb_set_before(*b, div);
    if inst_op(div) == .SDIV {
        q, udiv := eii_signed_division(*b, op(div, 0), op(div, 1));
        eii_replace(div, q);
        if udiv == NONE return;
        div = udiv;
    }
    q := eii_unsigned_division(*b, op(div, 0), op(div, 1));
    eii_replace(div, q);
}
// expandRemainder
eii_expand_remainder :: (rem_in: Value_Id) {
    rem := rem_in;
    b: Irb; irb_set_before(*b, rem);
    if inst_op(rem) == .SREM {
        r, urem := eii_signed_remainder(*b, op(rem, 0), op(rem, 1));
        eii_replace(rem, r);
        if urem == NONE return;
        rem = urem;
    }
    r, udiv := eii_unsigned_remainder(*b, op(rem, 0), op(rem, 1));
    eii_replace(rem, r);
    if udiv != NONE && inst_op(udiv) == .UDIV eii_expand_division(udiv);
}

// ---------------------------------------------------------------- fp <-> int

// Type::getFPMantissaWidth
eii_fp_mantissa_width :: (t: Type_Id) -> u32 {
    k := type_kind(t);
    if k == .HALF return 11;
    if k == .BFLOAT return 8;
    if k == .FLOAT return 24;
    if k == .DOUBLE return 53;
    if k == .X86_FP80 return 64;
    if k == .FP128 return 113;
    fatal("expand-ir-insts: no mantissa width for %", type_to_string(t));
    return 0;
}
eii_pow2_ceil :: (x: u64) -> u64 { r: u64 = 1; while r < x r <<= 1; return r; }

eii_expand_fp_to_i :: (fptoi: Value_Id, saturating: bool, signed: bool) {
    b: Irb; irb_set_before(*b, fptoi);
    float_val := op(fptoi, 0);
    int_ty := vtype(fptoi);
    bw := type_bits(int_ty);
    mw := eii_fp_mantissa_width(vtype(float_val)) - 1;
    if type_kind(vtype(float_val)) == .HALF && bw >= 32 {
        a1: Value_Id;
        // the saturating intrinsics have no opcode here: CreateFPToUI / CreateFPToSI on the call's own opcode
        if inst_op(fptoi) == .FPTOUI {
            a0 := irb_cast(*b, .FPTOUI, float_val, ir.t_i32);
            a1 = irb_cast(*b, .ZEXT, a0, int_ty);
        } else {
            a0 := irb_cast(*b, .FPTOSI, float_val, ir.t_i32);
            a1 = irb_cast(*b, .SEXT, a0, int_ty);
        }
        eii_replace(fptoi, a1);
        return;
    }
    mw = ifx mw == 63 then cast(u32) 112 else mw;
    float_width := cast(u32) eii_pow2_ceil(cast(u64) type_bits(scalar_type(vtype(float_val))));
    exp_width := float_width - mw - 1;
    exp_bias := (cast(u64) 1 << (exp_width - 1)) - 1;
    fit := type_int(float_width);
    implicit_bit := const_int_ap(fit, ap_one_bit_set(float_width, mw));
    sig_mask := const_int_ap(fit, ap_low_bits_set(float_width, mw));

    entry := b.bb;
    f := block_fn(entry);
    set_name(entry, tconcat(vname(entry), "fp-to-i-entry"));
    endb, recs := eii_split(entry, b.pt, "fp-to-i-cleanup");
    check_sat, sat: Value_Id = NONE;
    if saturating {
        check_sat = create_block(f, "fp-to-i-if-check.saturate", endb);
        sat = create_block(f, "fp-to-i-if-saturate", endb);
    }
    check_exp := create_block(f, "fp-to-i-if-check.exp.size", endb);
    exp_small := create_block(f, "fp-to-i-if-exp.small", endb);
    exp_large := create_block(f, "fp-to-i-if-exp.large", endb);

    irb_set_end(*b, entry);
    if !is_guaranteed_not_to_be_undef_or_poison(float_val) float_val = irb_freeze(*b, float_val);
    if type_kind(vtype(float_val)) == .X86_FP80 float_val = irb_cast(*b, .FPEXT, float_val, type_simple(.FP128));
    arep := irb_cast(*b, .BITCAST, float_val, fit);
    pos_or_neg, sign: Value_Id = NONE;
    if signed {
        pos_or_neg = irb_icmp(*b, ICMP_SGT, arep, const_all_ones_of(fit));
        sign = eii_select_unknown(*b, pos_or_neg, const_int(int_ty, 1), const_all_ones_of(int_ty), "sign");
    }
    and := irb_binop(*b, .LSHR, arep, const_int(fit, mw));
    biased_exp := irb_binop(*b, .AND, and, const_int(fit, (cast(u64) 1 << exp_width) - 1), "biased.exp");
    abs := irb_binop(*b, .AND, arep, sig_mask);
    significand := irb_binop(*b, .OR, abs, implicit_bit, "significand");
    zero_cond := irb_icmp(*b, ICMP_ULT, biased_exp, const_int(fit, exp_bias), "exp.is.negative");
    if saturating {
        is_nan := eii_fcmp(*b, FCMP_UNO, float_val, float_val, "is.nan");
        zero_cond = irb_binop(*b, .OR, zero_cond, is_nan);
        if !signed {
            is_neg := irb_icmp(*b, ICMP_SLT, arep, const_null_value(fit));   // CreateIsNeg
            zero_cond = irb_binop(*b, .OR, zero_cond, is_neg);
        }
    }
    cond_br := eii_cond_br(*b, zero_cond, endb, ifx saturating then check_sat else check_exp, *recs);
    set_explicitly_unknown_branch_weights_if_profiled(cond_br, "expand-ir-insts");

    saturated: Value_Id = NONE;
    if saturating {
        irb_set_end(*b, check_sat);
        sat_exp := exp_bias + cast(u64) bw - (ifx signed then cast(u64) 1 else 0);
        max_exp := (cast(u64) 1 << exp_width) - 1;
        if sat_exp > max_exp sat_exp = max_exp;
        cmp3 := irb_icmp(*b, ICMP_UGE, biased_exp, const_int(fit, sat_exp));
        br_sat := irb_insert(*b, create_cond_br(cmp3, sat, check_exp));
        eii_set_weights(br_sat, false);
        irb_set_end(*b, sat);
        if signed {
            smax := const_int_ap(int_ty, ap_signed_max(bw));
            smin := const_int_ap(int_ty, ap_signed_min(bw));
            saturated = eii_select_unknown(*b, pos_or_neg, smax, smin, "saturated");
        } else saturated = const_all_ones_of(int_ty);
        irb_br(*b, endb);
    }

    irb_set_end(*b, check_exp);
    smaller := irb_icmp(*b, ICMP_ULT, biased_exp, const_int(fit, exp_bias + mw), "exp.smaller.mantissa.width");
    br2 := irb_insert(*b, create_cond_br(smaller, exp_small, exp_large));
    eii_set_unknown(br2, "expand-ir-insts");

    irb_set_end(*b, exp_small);
    sub13 := irb_binop(*b, .SUB, const_int(fit, exp_bias + mw), biased_exp);
    small_res := eii_zext_or_trunc(*b, irb_binop(*b, .LSHR, significand, sub13), int_ty);
    if signed small_res = irb_binop(*b, .MUL, small_res, sign);
    irb_br(*b, endb);

    irb_set_end(*b, exp_large);
    sub15 := irb_binop(*b, .ADD, biased_exp, const_int_ap(fit, ap_from_s64(float_width, -cast(s64) (exp_bias + mw))));
    sig_cast := eii_zext_or_trunc(*b, significand, int_ty);
    large_res := irb_binop(*b, .SHL, sig_cast, eii_zext_or_trunc(*b, sub15, int_ty));
    if signed large_res = irb_binop(*b, .MUL, large_res, sign);
    irb_br(*b, endb);

    irb_set_at(*b, endb, block(endb).first, true);
    ret := irb_phi(*b, int_ty, cast(u32) (3 + ifx saturating then 1 else 0));
    if saturating phi_add_incoming(ret, saturated, sat);
    phi_add_incoming(ret, small_res, exp_small);
    phi_add_incoming(ret, large_res, exp_large);
    phi_add_incoming(ret, const_int(int_ty, 0), entry);
    eii_replace(fptoi, ret);
}

eii_expand_i_to_fp :: (itofp: Value_Id) {
    b: Irb; irb_set_before(*b, itofp);
    int_val := op(itofp, 0);
    int_ty := vtype(int_val);
    bw := type_bits(int_ty);
    fp_ty := vtype(itofp);
    mw := eii_fp_mantissa_width(fp_ty) - 1;
    mw = ifx mw == 63 then cast(u32) 112 else mw;
    mw = ifx mw == 10 then cast(u32) 23 else mw;
    mw = ifx mw == 7 then cast(u32) 23 else mw;
    fw := cast(u32) eii_pow2_ceil(mw);
    signed := inst_op(itofp) == .SITOFP;
    if !is_guaranteed_not_to_be_undef_or_poison(int_val) int_val = irb_freeze(*b, int_val);
    if bw < fw {
        bw = fw;
        int_ty = type_int(bw);
        int_val = eii_int_cast(*b, int_val, int_ty, signed);
    }
    temp1 := irb_binop(*b, .SHL, eii_c(bw, 1), eii_c(bw, mw + 3));

    entry := b.bb;
    f := block_fn(entry);
    set_name(entry, tconcat(vname(entry), "itofp-entry"));
    endb, recs := eii_split(entry, b.pt, "itofp-return");
    if_end := create_block(f, "itofp-if-end", endb);
    if_then4 := create_block(f, "itofp-if-then4", endb);
    sw_bb := create_block(f, "itofp-sw-bb", endb);
    sw_default := create_block(f, "itofp-sw-default", endb);
    sw_epilog := create_block(f, "itofp-sw-epilog", endb);
    if_then20 := create_block(f, "itofp-if-then20", endb);
    if_else := create_block(f, "itofp-if-else", endb);
    if_end26 := create_block(f, "itofp-if-end26", endb);

    irb_set_end(*b, entry);
    cmp := irb_icmp(*b, ICMP_EQ, int_val, const_int(int_ty, 0));
    br_entry := eii_cond_br(*b, cmp, endb, if_end, *recs);
    eii_set_weights(br_entry, false);

    irb_set_end(*b, if_end);
    shr := irb_binop(*b, .ASHR, int_val, eii_c(bw, bw - 1));
    xor := irb_binop(*b, .XOR, shr, int_val);
    sub := irb_binop(*b, .SUB, xor, shr);
    src := ifx signed then sub else int_val;
    call := eii_ctlz(*b, src);
    cast_ := irb_cast(*b, .TRUNC, call, ir.t_i32);
    bwn: u32 = ifx fw == 128 then bw else 32;
    cc := ifx fw == 128 then call else cast_;
    sub1 := irb_binop(*b, .SUB, eii_c(bwn, bw), cc);
    sub2 := irb_binop(*b, .SUB, eii_c(bwn, bw - 1), cc);
    cmp3 := irb_icmp(*b, ICMP_SGT, sub1, eii_c(bwn, mw + 1));
    br_if_end := irb_insert(*b, create_cond_br(cmp3, if_then4, if_else));
    eii_set_weights(br_if_end, true);

    irb_set_end(*b, if_then4);
    si := create_switch(sub1, sw_default, 10);   // CreateSwitch(V, Dest, NumCases = 10)
    irb_insert(*b, si);
    sw_add_case(si, eii_c(bwn, mw + 2), sw_bb);
    sw_add_case(si, eii_c(bwn, mw + 3), sw_epilog);
    if eii_prof_fixes() { w := u32.[EII_LIKELY, EII_UNLIKELY, EII_UNLIKELY]; prof_set_branch_weights(si, w, false); }

    irb_set_end(*b, sw_bb);
    shl := irb_binop(*b, .SHL, src, eii_c(bw, 1));
    irb_br(*b, sw_epilog);

    irb_set_end(*b, sw_default);
    sub5 := irb_binop(*b, .SUB, eii_c(bwn, cast(s64) bw - mw - 3), cc);
    sh_prom := irb_cast(*b, .ZEXT, sub5, int_ty);
    shr6 := irb_binop(*b, .LSHR, src, ifx fw == 128 then sub5 else sh_prom);
    sub8 := irb_binop(*b, .ADD, cc, eii_c(bwn, mw + 3));
    sh_prom9 := irb_cast(*b, .ZEXT, sub8, int_ty);
    shr9 := irb_binop(*b, .LSHR, const_all_ones_of(int_ty), ifx fw == 128 then sub8 else sh_prom9);
    and := irb_binop(*b, .AND, shr9, src);
    cmp10 := irb_icmp(*b, ICMP_NE, and, eii_c(bw, 0));
    conv11 := irb_cast(*b, .ZEXT, cmp10, int_ty);
    or := irb_binop(*b, .OR, shr6, conv11);
    irb_br(*b, sw_epilog);

    irb_set_end(*b, sw_epilog);
    aaddr0 := irb_phi(*b, int_ty, 3);
    phi_add_incoming(aaddr0, or, sw_default);
    phi_add_incoming(aaddr0, src, if_then4);
    phi_add_incoming(aaddr0, shl, sw_bb);
    a0 := irb_cast(*b, .TRUNC, aaddr0, ir.t_i32);
    a1 := irb_binop(*b, .LSHR, a0, eii_c(32, 2));
    a2 := irb_binop(*b, .AND, a1, eii_c(32, 1));
    conv16 := irb_cast(*b, .ZEXT, a2, int_ty);
    or17 := irb_binop(*b, .OR, aaddr0, conv16);
    inc := irb_binop(*b, .ADD, or17, eii_c(bw, 1));
    shr18 := irb_binop(*b, ifx signed then Opcode.ASHR else .LSHR, inc, eii_c(bw, 2));
    a3 := irb_binop(*b, .AND, inc, temp1, "a3");
    pos_or_neg := irb_icmp(*b, ICMP_EQ, a3, eii_c(bw, 0));
    extract_t60 := irb_cast(*b, .TRUNC, shr18, type_int(fw));
    extract63 := irb_binop(*b, .LSHR, shr18, eii_c(bw, 32));
    extract_t64: Value_Id;
    if fw > 80 extract_t64 = irb_cast(*b, .TRUNC, sub2, ir.t_i64);
    else extract_t64 = irb_cast(*b, .TRUNC, extract63, ir.t_i32);
    br_ep := irb_insert(*b, create_cond_br(pos_or_neg, if_end26, if_then20));
    eii_set_weights(br_ep, true);

    irb_set_end(*b, if_then20);
    shr21 := irb_binop(*b, ifx signed then Opcode.ASHR else .LSHR, inc, eii_c(bw, 3));
    extract_t := irb_cast(*b, .TRUNC, shr21, type_int(fw));
    extract := irb_binop(*b, .LSHR, shr21, eii_c(bw, 32));
    extract_t62: Value_Id;
    if fw > 80 extract_t62 = irb_cast(*b, .TRUNC, sub1, ir.t_i64);
    else extract_t62 = irb_cast(*b, .TRUNC, extract, ir.t_i32);
    irb_br(*b, if_end26);

    irb_set_end(*b, if_else);
    sub24 := irb_binop(*b, .ADD, cc, eii_c(bwn, -cast(s64) (bw - mw - 1)));
    sh_prom25 := irb_cast(*b, .ZEXT, sub24, int_ty);
    shl26 := irb_binop(*b, .SHL, src, ifx fw == 128 then sub24 else sh_prom25);
    extract_t61 := irb_cast(*b, .TRUNC, shl26, type_int(fw));
    extract65 := irb_binop(*b, .LSHR, shl26, eii_c(bw, 32));
    extract_t66: Value_Id;
    if fw > 80 extract_t66 = irb_cast(*b, .TRUNC, sub2, ir.t_i64);
    else extract_t66 = irb_cast(*b, .TRUNC, extract65, ir.t_i32);
    irb_br(*b, if_end26);

    irb_set_end(*b, if_end26);
    aaddr1_off0 := irb_phi(*b, type_int(fw), 3);
    phi_add_incoming(aaddr1_off0, extract_t, if_then20);
    phi_add_incoming(aaddr1_off0, extract_t60, sw_epilog);
    phi_add_incoming(aaddr1_off0, extract_t61, if_else);
    aaddr1_off32: Value_Id = NONE;
    if fw > 32 {
        aaddr1_off32 = irb_phi(*b, type_int(ifx fw > 80 then cast(u32) 64 else 32), 3);
        phi_add_incoming(aaddr1_off32, extract_t62, if_then20);
        phi_add_incoming(aaddr1_off32, extract_t64, sw_epilog);
        phi_add_incoming(aaddr1_off32, extract_t66, if_else);
    }
    e0: Value_Id = NONE;
    if fw <= 80 {
        e0 = irb_phi(*b, type_int(bwn), 3);
        phi_add_incoming(e0, sub1, if_then20);
        phi_add_incoming(e0, sub2, sw_epilog);
        phi_add_incoming(e0, sub2, if_else);
    }
    and29: Value_Id;
    if fw > 80 {
        temp2 := irb_binop(*b, .SHL, eii_c(bw, 1), eii_c(bw, 63));
        and29 = irb_binop(*b, .AND, shr, temp2, "and29");
    } else {
        conv28 := irb_cast(*b, .TRUNC, shr, ir.t_i32);
        and29 = irb_binop(*b, .AND, conv28, const_int(ir.t_i32, 0x8000_0000));
    }
    temp_mod := mw % 32;
    and34, shl30: Value_Id;
    if fw > 80 {
        temp_mod += 32;
        add := irb_binop(*b, .SHL, aaddr1_off32, eii_c(64, temp_mod));
        shl30 = irb_binop(*b, .ADD, add, const_int(ir.t_i64, ((cast(u64) 1 << (62 - cast(u64) temp_mod)) - 1) << cast(u64) temp_mod));
        and34 = irb_cast(*b, .ZEXT, shl30, type_int(128));
    } else {
        add := irb_binop(*b, .SHL, e0, eii_c(32, temp_mod));
        shl30 = irb_binop(*b, .ADD, add, const_int(ir.t_i32, cast(u64) (((cast(u32) 1 << (30 - temp_mod)) - 1) << temp_mod)));
        and34 = irb_binop(*b, .AND, ifx fw > 32 then aaddr1_off32 else aaddr1_off0, const_int(ir.t_i32, cast(u64) ((cast(u32) 1 << temp_mod) - 1)));
    }
    or35: Value_Id;
    if fw > 80 {
        and29_trunc := irb_cast(*b, .TRUNC, and29, type_int(128));
        or31 := irb_binop(*b, .OR, and29_trunc, and34);
        or34 := irb_binop(*b, .SHL, or31, eii_c(128, 64));
        temp3 := irb_binop(*b, .SHL, eii_c(128, 1), eii_c(128, mw));
        temp4 := irb_binop(*b, .SUB, temp3, eii_c(128, 1));
        a6 := irb_binop(*b, .AND, aaddr1_off0, temp4);
        or35 = irb_binop(*b, .OR, or34, a6);
    } else {
        or31 := irb_binop(*b, .OR, and34, and29);
        or35 = irb_binop(*b, .OR, ifx signed then or31 else and34, shl30);
    }
    a4: Value_Id;
    fk := type_kind(fp_ty);
    if fk == .DOUBLE {
        zext1 := irb_cast(*b, .ZEXT, or35, type_int(fw));
        shl1 := irb_binop(*b, .SHL, zext1, eii_c(fw, 32));
        and1 := irb_binop(*b, .AND, aaddr1_off0, eii_c(fw, 0xFFFF_FFFF));
        or1 := irb_binop(*b, .OR, shl1, and1);
        a4 = irb_cast(*b, .BITCAST, or1, fp_ty);
    } else if fk == .X86_FP80 {
        a40 := irb_cast(*b, .BITCAST, or35, type_simple(.FP128));
        a4 = irb_cast(*b, .FPTRUNC, a40, fp_ty);
    } else if fk == .HALF || fk == .BFLOAT {
        a40 := irb_cast(*b, .BITCAST, or35, type_simple(.FLOAT));
        a4 = irb_cast(*b, .FPTRUNC, a40, fp_ty);
    } else a4 = irb_cast(*b, .BITCAST, or35, fp_ty);

    exp_width := fw - mw - 1;
    min_inf_exp := cast(u64) 1 << (exp_width - 1);
    if cast(u64) bw - 1 >= min_inf_exp {
        min_inf := eii_c(bwn, cast(s64) min_inf_exp);
        overflow := irb_icmp(*b, ICMP_UGE, sub2, min_inf);
        inf := const_fp_inf(fp_ty, false);
        if signed {
            neg_inf := const_fp_inf(fp_ty, true);
            is_neg := irb_icmp(*b, ICMP_SLT, int_val, const_null_value(int_ty));
            inf = eii_select_unknown(*b, is_neg, neg_inf, inf, "expand-ir-insts");
        }
        a4 = irb_select(*b, overflow, inf, a4);
        eii_set_weights(a4, false);
    }
    irb_br(*b, endb);

    irb_set_at(*b, endb, block(endb).first, true);
    ret := irb_phi(*b, fp_ty, 2);
    phi_add_incoming(ret, a4, if_end26);
    phi_add_incoming(ret, const_null_value(fp_ty), entry);   // ConstantFP::getZero(Ty, false)
    eii_replace(itofp, ret);
}

// ---------------------------------------------------------------- driver

// scalarize(I, Worklist)
eii_scalarize :: (i: Value_Id, work: *[..] Value_Id) {
    vty := vtype(i);
    b: Irb; irb_set_before(*b, i);
    n := type_count(vty);
    result := const_poison(vty);
    for idx: 0..cast(s64) n - 1 {
        ext := irb_extract_element(*b, op(i, 0), cast(u64) idx);
        new_op: Value_Id;
        o := inst_op(i);
        if is_binary_op(o) new_op = irb_binop(*b, o, ext, irb_extract_element(*b, op(i, 1), cast(u64) idx));
        else if is_cast_op(o) new_op = irb_cast(*b, o, ext, scalar_type(vty));
        else new_op = vp_intrinsic_ret(*b, scalar_type(vty), call_iid(i), .[ext]);
        result = irb_insert_element(*b, result, new_op, cast(u64) idx);
        if is_inst(new_op) {
            copy_ir_flags(new_op, i);
            array_add(work, new_op);
        }
    }
    eii_replace(i, result);
}

eii_run_impl :: (f: Value_Id, st: *X86_Lowering) -> bool {
    max_fp: u64 = 128;                                     // getMaxLargeFPConvertBitWidthSupported
    if eii_cl.fp_convert_bits != EII_MAX_INT_BITS max_fp = eii_cl.fp_convert_bits;
    max_divrem: u64 = ifx st_is64Bit(st) then cast(u64) 128 else 64;   // getMaxDivRemBitWidthSupported
    if eii_cl.div_rem_bits != EII_MAX_INT_BITS max_divrem = eii_cl.div_rem_bits;
    disable_fp := max_fp >= EII_MAX_INT_BITS;
    disable_divrem := max_divrem >= EII_MAX_INT_BITS;
    // DisableFrem: FRemExpander::shouldExpandAnyFremType is false on x86 (FREM is a libcall for f16/f32/f64)
    if disable_fp && disable_divrem return false;
    should_handle :: (i: Value_Id, max_fp: u64, max_divrem: u64, disable_fp: bool, disable_divrem: bool) -> bool {
        ty := vtype(i);
        if type_kind(ty) == .SVECTOR return false;
        o := inst_op(i);
        if o == .FPTOUI || o == .FPTOSI return !disable_fp && cast(u64) type_bits(scalar_type(ty)) > max_fp;
        if o == .UITOFP || o == .SITOFP return !disable_fp && cast(u64) type_bits(scalar_type(vtype(op(i, 0)))) > max_fp;
        if o == .UDIV || o == .SDIV || o == .UREM || o == .SREM return !disable_divrem && cast(u64) type_bits(scalar_type(ty)) > max_divrem;
        if o == .CALL {
            id := call_iid(i);
            if id == IID_FPTOUI_SAT || id == IID_FPTOSI_SAT return !disable_fp && cast(u64) type_bits(scalar_type(ty)) > max_fp;
        }
        return false;
    }
    work: [..] Value_Id; work.allocator = temp;
    modified := false;
    bb := fn_entry(f);
    while bb != NONE {
        i := block(bb).first;
        while i != NONE {
            cur := i;
            i = inst(cur).next;
            if !should_handle(cur, max_fp, max_divrem, disable_fp, disable_divrem) continue;
            if is_vector_type(vtype(op(cur, 0))) eii_scalarize(cur, *work);
            else array_add(*work, cur);
            modified = true;
        }
        bb = block(bb).next;
    }
    while work.count {
        i := pop(*work);
        o := inst_op(i);
        if o == {
            case .FPTOUI; eii_expand_fp_to_i(i, false, false);
            case .FPTOSI; eii_expand_fp_to_i(i, false, true);
            case .UITOFP; #through;
            case .SITOFP; eii_expand_i_to_fp(i);
            case .UDIV; #through; case .SDIV; #through; case .UREM; #through; case .SREM;
                if eii_is_const_pow2(op(i, 1), o == .SDIV || o == .SREM) eii_expand_pow2_divrem(i);
                else if o == .UDIV || o == .SDIV eii_expand_division(i);
                else eii_expand_remainder(i);
            case .CALL;
                eii_expand_fp_to_i(i, true, call_iid(i) == IID_FPTOSI_SAT);
            case; fatal("internal: expand-ir-insts: unexpected instruction");
        }
    }
    return modified;
}

expand_ir_insts_run :: (f: Value_Id) -> Preserved {
    t := tti_get(f);
    if t.kind != .X86 fatal("expand-ir-insts needs a target machine (an x86 target triple)");
    if tool_name != "llc" && !libcall_lowering_info_cached fatal("'LibcallLoweringModuleAnalysis' analysis required");
    if !eii_run_impl(f, *t.xl) return PRESERVE_ALL;
    return .{};   // PreservedAnalyses::none() (the legacy pass preserves AA, which nothing here caches)
}
