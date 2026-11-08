// InstCombine for add and sub: a port of llvm/lib/Transforms/InstCombine/InstCombineAddSub.cpp (visitAdd, visitSub,
// visitFAdd, visitFSub, visitFNeg and their helpers), plus getNoCommonBitsSetResult from
// llvm/lib/Analysis/ValueTracking.cpp. Folds are in LLVM's order; each block names the LLVM helper it ports.

// ---------------------------------------------------------------- haveNoCommonBitsSet (ValueTracking.cpp)

No_Common_Bits :: enum u8 { UNKNOWN; KNOWN; ONLY_IF_UNDEF_IGNORED; }

have_no_common_bits_set_special_cases :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> No_Common_Bits {
    nu :: (v: Value_Id, q: Simplify_Query) -> bool { return is_guaranteed_not_to_be_undef(v, q.ac, q.cxt, q.dt); }
    res :: (b: bool) -> No_Common_Bits { return ifx b then No_Common_Bits.KNOWN else .ONLY_IF_UNDEF_IGNORED; }
    // (X & ~M) op (Y & M)
    oka, la, lb := pm_binop(lhs, .AND);
    if oka {
        for side: 0..1 {
            nm := ifx side == 0 then la else lb;
            okn, m := pm_not(nm);
            if !okn continue;
            okr, rest := pm_c_binop_with(rhs, .AND, m);
            if okr return res(nu(m, q));
        }
    }
    // X op (Y & ~X)
    okr, ra, rb := pm_binop(rhs, .AND);
    if okr {
        okn1, n1 := pm_not(ra);
        okn2, n2 := pm_not(rb);
        if (okn1 && n1 == lhs) || (okn2 && n2 == lhs) return res(nu(lhs, q));
    }
    // X op ((X & Y) ^ Y)
    okx, xa, xb := pm_binop(rhs, .XOR);
    if okx {
        for side: 0..1 {
            andv := ifx side == 0 then xa else xb;
            yv := ifx side == 0 then xb else xa;
            oky, y := pm_c_binop_with(andv, .AND, lhs);
            if oky && y == yv return res(nu(lhs, q) && nu(y, q));
        }
    }
    // (ext Y) op ext(~Y)
    oke, y := pmi_zext_or_sext(lhs);
    if oke {
        oke2, ny := pmi_zext_or_sext(rhs);
        if oke2 { okn, nn := pm_not(ny); if okn && nn == y return res(nu(y, q)); }
    }
    // (A & B) op ~(A | B)
    ok1, a, b := pm_binop(lhs, .AND);
    if ok1 {
        okn, o := pm_not(rhs);
        if okn {
            oko, oa, ob := pm_binop(o, .OR);
            if oko && ((oa == a && ob == b) || (oa == b && ob == a)) return res(nu(a, q) && nu(b, q));
        }
    }
    // (X << V) op (Y >> (BitWidth - V)) or (X >> V) op (Y << (BitWidth - V))
    bw := scalar_bits(lhs);
    for form: 0..1 {
        ropc: Opcode = ifx form == 0 then Opcode.SHL else .LSHR;
        lopc: Opcode = ifx form == 0 then Opcode.LSHR else .SHL;
        oks, sx, samt := pm_binop(rhs, ropc);
        if !oks continue;
        oksub, rc, v := pm_binop(samt, .SUB);
        if !oksub continue;
        okc, r := pm_apint(rc);
        if !okc continue;
        okl, lx, lamt := pm_binop(lhs, lopc);
        if !okl || lamt != v continue;
        if ap_uge_u64(r, bw) return .KNOWN;
    }
    return .UNKNOWN;
}
get_no_common_bits_set_result :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> No_Common_Bits {
    r := have_no_common_bits_set_special_cases(lhs, rhs, q);
    if r == .KNOWN return .KNOWN;
    cr := have_no_common_bits_set_special_cases(rhs, lhs, q);
    if cr == .KNOWN return .KNOWN;
    if kb_have_no_common_bits_set(known_bits(lhs, q), known_bits(rhs, q)) return .KNOWN;
    if r == .ONLY_IF_UNDEF_IGNORED || cr == .ONLY_IF_UNDEF_IGNORED return .ONLY_IF_UNDEF_IGNORED;
    return .UNKNOWN;
}
have_no_common_bits_set :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> bool { return get_no_common_bits_set_result(lhs, rhs, q) == .KNOWN; }

// ---------------------------------------------------------------- add helpers

// checkForNegativeOperand
ic_check_for_negative_operand :: (i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    if !has_one_use(lhs) && !has_one_use(rhs) return NONE;
    x: Value_Id = NONE; y: Value_Id = NONE; z: Value_Id = NONE;
    ok, xa, xb := pm_binop(rhs, .ADD);
    if ok && pm_one(xb) { t := lhs; lhs = rhs; rhs = t; }
    ok, xa, xb = pm_binop(lhs, .ADD);
    if ok && pm_one(xb) {
        x = xa;
        okx, yy, c1v := pm_binop(rhs, .XOR);
        okc1, c1 := pm_apint(c1v);
        if okx && okc1 { t := x; x = rhs; rhs = t; }
        okx, yy, c1v = pm_binop(x, .XOR);
        okc1, c1 = pm_apint(c1v);
        if okx && okc1 {
            y = yy;
            oko, zz, c2v := pm_binop(y, .OR);
            okc2, c2 := pm_apint(c2v);
            if oko && okc2 && ap_eq(c2, ap_not(c1)) {
                na := icb_and(zz, const_int_ap(vtype(zz), c1));
                return icb_sub(rhs, na, "sub");
            }
            oka, za, c2a := pm_binop(y, .AND);
            okc2, c2 = pm_apint(c2a);
            if oka && okc2 && ap_eq(c1, c2) {
                no := icb_or(za, const_int_ap(vtype(za), ap_not(c1)));
                return icb_sub(rhs, no, "sub");
            }
        }
    }
    lhs = op(i, 0); rhs = op(i, 1);
    okx, yy, c1v := pm_binop(rhs, .XOR);
    okc1, c1 := pm_apint(c1v);
    if okx && okc1 { t := lhs; lhs = rhs; rhs = t; }
    okx, yy, c1v = pm_binop(lhs, .XOR);
    okc1, c1 = pm_apint(c1v);
    if okx && okc1 && ap_ctz(c1) == 0 {
        oka, za, c2v := pm_binop(yy, .AND);
        okc2, c2 := pm_apint(c2v);
        if oka && okc2 && ap_eq(c1, ap_add_u64(c2, 1)) {
            no := icb_or(za, const_int_ap(vtype(za), ap_not(c2)));
            return icb_sub(rhs, no, "sub");
        }
    }
    return NONE;
}

// foldNoWrapAdd
ic_fold_no_wrap_add :: (add: Value_Id) -> Value_Id {
    op0 := op(add, 0); op1 := op(add, 1);
    ty := vtype(add);
    if !pm_constant(op1) return NONE;
    okc1, c1 := pm_apint(op1);
    okz, za := pmi_cast(op0, .ZEXT);
    if okc1 && okz {
        okn, x, c2v := pm_nuw_add_like_i(za);
        okc2, c2 := pm_apint(c2v);
        if okn && okc2 && ap_is_negative(c1) && ap_sge(c1, ap_neg(ap_sext(c2, c1.bits))) {
            newc := ap_add(c2, ap_trunc(c1, c2.bits));
            if ap_is_zero(newc) return create_cast(.ZEXT, x, ty);
            if has_one_use(op0) return create_cast(.ZEXT, icb_add(x, const_int_ap(vtype(x), newc), "", true), ty);
        }
    }
    if has_one_use(op0) {
        oks, sx := pm_sext_like(op0);
        if oks && is_inst(op0) {
            okn, x, nc := pm_nsw_add_like_i(sx);
            if okn && pm_constant(nc) {
                widec := icb_sext(nc, ty);
                newc := icb_add(widec, op1);
                widex := icb_sext(x, ty);
                return create_binop(.ADD, widex, newc);
            }
        }
        okz2, zx := pmi_cast(op0, .ZEXT);
        if okz2 {
            okn, x, nc := pm_nuw_add_like_i(zx);
            if okn && pm_constant(nc) {
                widec := icb_zext(nc, ty);
                newc := icb_add(widec, op1);
                widex := icb_zext(x, ty);
                return create_binop(.ADD, widex, newc);
            }
        }
    }
    return NONE;
}

// foldAddWithConstant
ic_fold_add_with_constant :: (add: Value_Id) -> Value_Id {
    op0 := op(add, 0); op1 := op(add, 1);
    ty := vtype(add);
    if !pm_imm_constant(op1) return NONE;
    r := ic_fold_binop_into_select_or_phi(add); if r != NONE return r;
    r = ic_fold_binop_select_binop(add); if r != NONE return r;
    // add (sub C1, X), C2 --> sub (add C1, C2), X
    oks, sc, sx := pm_binop(op0, .SUB);
    if oks && pm_constant(sc) return create_binop(.SUB, ce_binop(.ADD, sc, op1, 0), sx);
    // add (sub X, Y), -1 --> add (not Y), X
    if oks && has_one_use(op0) && pm_all_ones(op1) return create_binop(.ADD, icb_not(sx), sc);
    // zext(bool) + C / sext(bool) + C
    okz, zx := pmi_cast(op0, .ZEXT);
    if okz && scalar_bits(zx) == 1 return ic_create_select_unknown_profile(zx, ic_add_one(op1), op1);
    okse, sxx := pmi_cast(op0, .SEXT);
    if okse && scalar_bits(sxx) == 1 return ic_create_select_unknown_profile(sxx, ic_sub_one(op1), op1);
    // ~X + C --> (C-1) - X
    okn, nx := pm_not(op0);
    if okn {
        cone := const_int_of(vtype(op1), 1);
        will_not_sov := ic_will_not_overflow_signed_sub(op1, cone, add);
        res := create_binop(.SUB, ce_binop(.SUB, op1, cone, 0), nx);
        set_nsw(res, has_nsw(add) && will_not_sov);
        return res;
    }
    bw := type_bits(scalar_type(ty));
    // (iN X s>> (N - 1)) + 1 --> zext (X > -1)
    oka, ax, aamt := pm_binop(op0, .ASHR);
    if oka && has_one_use(op0) && pm_specific_int_allow_poison(aamt, bw - 1) && pm_one(op1)
        return create_cast(.ZEXT, icb_cmp(ICMP_SGT, ax, const_all_ones_of(vtype(ax)), "isnotneg"), ty);
    okc, c := pm_apint(op1);
    if !okc return NONE;
    // (X | Op01C) + Op1C --> X + (Op01C + Op1C) iff disjoint
    okd, dx, dc := pm_disjoint_or(op0);
    if okd && pm_imm_constant(dc) {
        na := create_binop(.ADD, dx, ce_binop(.ADD, dc, op1, 0));
        set_nsw(na, has_nsw(add) && ic_will_not_overflow_signed_add(dc, op1, add));
        set_nuw(na, has_nuw(add));
        return na;
    }
    // (X | C2) + C --> (X | C2) ^ C2 iff (C2 == -C)
    oko, ox, oc := pm_binop(op0, .OR);
    okc2, c2 := pm_apint(oc);
    if oko && okc2 && ap_eq(c2, ap_neg(c)) return create_binop(.XOR, op0, const_int_ap(ty, c2));
    if ap_is_sign_mask(c) {
        if has_nsw(add) || has_nuw(add) return create_binop_flags(.OR, op0, op1, F_EXACT);
        return create_binop(.XOR, op0, op1);
    }
    // add(zext(xor i16 X, -32768), -32768) --> sext X
    if okz {
        okx, xv, xc := pm_binop(zx, .XOR);
        okxc, xcv := pm_apint(xc);
        if okx && okxc && ap_is_min_signed(xcv) && ap_eq(ap_sext(xcv, bw), c) return create_cast(.SEXT, xv, ty);
    }
    okx, xv, xc := pm_binop(op0, .XOR);
    okxc, xcv := pm_apint(xc);
    if okx && okxc {
        if ap_is_sign_mask(xcv) return create_binop(.ADD, xv, const_int_ap(ty, ap_xor(xcv, c)));
        lk := ic_known_bits(xv, add);
        if ap_is_all_ones(ap_or(xcv, lk.zero)) return create_binop(.SUB, const_int_ap(ty, ap_add(xcv, c)), xv);
        if has_one_use(op0) && ap_eq(xcv, ap_neg(c)) {
            sh: u32 = 0;
            if ap_is_power_of_2(c) sh = bw - ap_log2(c) - 1;
            else if ap_is_power_of_2(xcv) sh = bw - ap_log2(xcv) - 1;
            if sh != 0 && ic_masked_value_is_zero(xv, ap_high_bits_set(bw, sh), add) {
                shc := const_int_of(ty, sh);
                nshl := icb_shl(xv, shc, "sext");
                return create_binop(.ASHR, nshl, shc);
            }
        }
    }
    if ap_is_one(c) && has_one_use(op0) {
        if okse && scalar_bits(sxx) == 1 return create_cast(.ZEXT, icb_not(sxx), ty);
        oka2, shl, c3v := pm_binop(op0, .ASHR);
        if oka2 {
            okshl, shx, c2v := pm_binop(shl, .SHL);
            okc2b, c2b := pm_apint(c2v);
            okc3, c3 := pm_apint(c3v);
            // C2 == C3 compares the APInt pointers: equal values of the (same) type are one uniqued constant
            if okshl && okc2b && okc3 && ap_eq(c2b, c3) && ap_eq_u64(c2b, bw - 1) {
                notx := icb_not(shx);
                return create_binop(.AND, notx, const_int_of(ty, 1));
            }
        }
    }
    // umax(X, C) + -C --> usub.sat(X, C)
    if has_one_use(op0) {
        okm, mx, mc := pm_intrinsic2(op0, IID_UMAX);
        if okm && pm_specific_int_ap(mc, ap_neg(c))
            return ic_replace_inst_uses_with(add, icb_binary_intrinsic(IID_USUB_SAT, mx, const_int_ap(ty, ap_neg(c))));
    }
    // (add (zext (add X, -C)), C) -> (zext X) if X u>= C
    if okz {
        oki, ix, icv := pm_binop(zx, .ADD);
        oki2, innerc := pm_apint_ap(icv);
        if oki && oki2 {
            nbw := innerc.bits;
            if ap_active_bits(c) <= nbw {
                narrowc := ap_trunc(c, nbw);
                if ap_eq(innerc, ap_neg(narrowc)) {
                    cond := false;
                    if ap_is_one(narrowc) cond = is_known_non_zero(ix, ic_q(add));
                    else cond = ap_uge(kb_min_value(ic_known_bits(ix, add)), narrowc);
                    if cond return create_cast(.ZEXT, ix, ty);
                }
            }
        }
    }
    return NONE;
}

// matchesSquareSum<false>(I, m_SpecificInt(1), A, B) / foldSquareSumInt and the FP variant
ic_matches_square_sum :: (i: Value_Id, fp: bool) -> (bool, Value_Id, Value_Id) {
    mul_op: Opcode = ifx fp then Opcode.FMUL else .MUL;
    add_op: Opcode = ifx fp then Opcode.FADD else .ADD;
    mul2_op: Opcode = ifx fp then Opcode.FMUL else .SHL;
    is_m2 :: (v: Value_Id, fp: bool) -> bool { if fp return pm_specific_fp(v, 2.0); return pm_specific_int(v, 1); }
    // m_BinOp(Mul2Op, m_X, M2Rhs) (for fmul, commutative only via m_c_ where LLVM uses it)
    match_mul2 :: (v: Value_Id, x: Value_Id, op2: Opcode, fp: bool) -> bool {
        ok, a, b := pm_binop(v, op2);
        return ok && a == x && is_m2(b, fp);
    }
    if inst_op(i) != add_op return false, NONE, NONE;
    for side: 0..1 {
        l := op(i, cast(u32) side); r := op(i, cast(u32) (1 - side));
        // (a * a) + (((a * 2) + b) * b)
        okl, a1, a2 := pm_binop(l, mul_op);
        if okl && has_one_use(l) && a1 == a2 && has_one_use(r) {
            a := a1;
            okr, r0, r1 := pm_binop(r, mul_op);
            if okr {
                for rs: 0..1 {
                    inner := ifx rs == 0 then r0 else r1;
                    bv := ifx rs == 0 then r1 else r0;
                    oki, i0, i1 := pm_binop(inner, add_op);
                    if !oki continue;
                    if match_mul2(i0, a, mul2_op, fp) && i1 == bv return true, a, bv;
                    if match_mul2(i1, a, mul2_op, fp) && i0 == bv return true, a, bv;
                }
            }
        }
    }
    for side: 0..1 {
        l := op(i, cast(u32) side); r := op(i, cast(u32) (1 - side));
        a: Value_Id = NONE; b: Value_Id = NONE;
        if has_one_use(l) {
            ok1, m, two := pm_binop(l, mul2_op);
            if ok1 && is_m2(two, fp) { okm, ma, mb := pm_binop(m, mul_op); if okm { a = ma; b = mb; } }
            if a == NONE {
                ok2, p, q := pm_binop(l, mul_op);
                if ok2 {
                    for s2: 0..1 {
                        mm := ifx s2 == 0 then p else q;
                        other := ifx s2 == 0 then q else p;
                        ok3, ma, two2 := pm_binop(mm, mul2_op);
                        if ok3 && is_m2(two2, fp) { a = ma; b = other; break; }
                    }
                }
            }
        }
        if a == NONE || !has_one_use(r) continue;
        okr, r0, r1 := pm_binop(r, add_op);
        if !okr continue;
        sq :: (v: Value_Id, x: Value_Id, mul_op: Opcode) -> bool { ok, p, q := pm_binop(v, mul_op); return ok && p == x && q == x; }
        if (sq(r0, a, mul_op) && sq(r1, b, mul_op)) || (sq(r1, a, mul_op) && sq(r0, b, mul_op)) return true, a, b;
    }
    return false, NONE, NONE;
}
ic_fold_square_sum_int :: (i: Value_Id) -> Value_Id {
    ok, a, b := ic_matches_square_sum(i, false);
    if ok { ab := icb_add(a, b); return create_binop(.MUL, ab, ab); }
    return NONE;
}

// MatchMul / MatchRem / MatchDiv
match_mul_c :: (e: Value_Id) -> (bool, Value_Id, APInt) {
    ok, x, cv := pm_binop(e, .MUL);
    okc, c := pm_apint(cv);
    if ok && okc return true, x, c;
    ok, x, cv = pm_binop(e, .SHL);
    okc, c = pm_apint(cv);
    if ok && okc return true, x, ap_shl_ap(ap_one(c.bits), c);
    return false, NONE, .{};
}
match_rem_c :: (e: Value_Id) -> (bool, Value_Id, APInt, bool) {
    ok, x, cv := pm_binop(e, .SREM);
    okc, c := pm_apint(cv);
    if ok && okc return true, x, c, true;
    ok, x, cv = pm_binop(e, .UREM);
    okc, c = pm_apint(cv);
    if ok && okc return true, x, c, false;
    ok, x, cv = pm_binop(e, .AND);
    okc, c = pm_apint(cv);
    if ok && okc && ap_is_power_of_2(ap_add_u64(c, 1)) return true, x, ap_add_u64(c, 1), false;
    return false, NONE, .{}, false;
}
match_div_c :: (e: Value_Id, is_signed: bool) -> (bool, Value_Id, APInt) {
    if is_signed {
        ok, x, cv := pm_binop(e, .SDIV);
        okc, c := pm_apint(cv);
        if ok && okc return true, x, c;
    } else {
        ok, x, cv := pm_binop(e, .UDIV);
        okc, c := pm_apint(cv);
        if ok && okc return true, x, c;
        ok, x, cv = pm_binop(e, .LSHR);
        okc, c = pm_apint(cv);
        if ok && okc return true, x, ap_shl_ap(ap_one(c.bits), c);
    }
    return false, NONE, .{};
}
mul_will_overflow :: (c0: APInt, c1: APInt, is_signed: bool) -> bool {
    ov: bool;
    if is_signed _, ov = ap_smul_ov(c0, c1); else _, ov = ap_umul_ov(c0, c1);
    return ov;
}
// SimplifyAddWithRemainder
ic_simplify_add_with_remainder :: (i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    x: Value_Id; c0: APInt; is_signed: bool;
    mul_v: Value_Id; mul_c: APInt;
    matched := false;
    okr, rx, rc, rs := match_rem_c(lhs);
    if okr { okm, mv, mc := match_mul_c(rhs); if okm { matched = true; x = rx; c0 = rc; is_signed = rs; mul_v = mv; mul_c = mc; } }
    if !matched {
        okr, rx, rc, rs = match_rem_c(rhs);
        if okr { okm, mv, mc := match_mul_c(lhs); if okm { matched = true; x = rx; c0 = rc; is_signed = rs; mul_v = mv; mul_c = mc; } }
    }
    if matched && ap_eq(c0, mul_c) {
        okr2, rem_v, c1, rem2_signed := match_rem_c(mul_v);
        if okr2 && is_signed == rem2_signed {
            okd, div_v, div_c := match_div_c(rem_v, is_signed);
            if okd && x == div_v && ap_eq(c0, div_c) && !mul_will_overflow(c0, c1, is_signed) {
                nd := const_int_ap(vtype(x), ap_mul(c0, c1));
                if is_signed return icb_binop(.SREM, x, nd, "srem");
                return icb_binop(.UREM, x, nd, "urem");
            }
        }
    }
    fold_div_rem :: (i: Value_Id, div_side: Value_Id, rem_side: Value_Id) -> Value_Id {
        bw := scalar_bits(i);
        div, rem: Value_Id;
        c1, c2: APInt;
        okm, dv, dc := match_mul_c(div_side);
        if !has_one_use(div_side) || !okm { div = div_side; c1 = ap_one(bw); } else { div = dv; c1 = dc; }
        okm2, rv, rc := match_mul_c(rem_side);
        if !has_one_use(rem_side) || !okm2 { rem = rem_side; c2 = ap_one(bw); } else { rem = rv; c2 = rc; }
        okr, x, c0, is_signed := match_rem_c(rem);
        if !okr return NONE;
        okd, div_op, div_c := match_div_c(div, is_signed);
        if !okd || x != div_op || !ap_eq(c0, div_c) return NONE;
        if ap_is_one(c1) && !is_signed && ap_is_power_of_2(div_c) && !ap_eq_u64(div_c, 2) return NONE;
        newc := ap_sub(c1, ap_mul(c2, c0));
        if !ap_is_zero(newc) && !has_one_use(rem) return NONE;
        if !is_guaranteed_not_to_be_undef(x, ic.ac, i, ic.dt) return NONE;
        mul_xc2 := icb_mul(x, const_int_ap(vtype(x), c2));
        if ap_is_zero(newc) return mul_xc2;
        return icb_add(icb_mul(div, const_int_ap(vtype(x), newc)), mul_xc2);
    }
    v := fold_div_rem(i, lhs, rhs); if v != NONE return v;
    return fold_div_rem(i, rhs, lhs);
}

// canonicalizeLowbitMask
ic_canonicalize_lowbit_mask :: (i: Value_Id) -> Value_Id {
    shl := op(i, 0);
    ok, one, nbits := pm_binop(shl, .SHL);
    if !ok || !has_one_use(shl) || !pm_one(one) || !pm_all_ones(op(i, 1)) return NONE;
    minus_one := const_all_ones_of(vtype(nbits));
    not_mask := icb_shl(minus_one, nbits, "notmask");
    if is_binary_operator(not_mask) { set_nsw(not_mask); set_nuw(not_mask, has_nuw(i)); }
    r := create_not(not_mask);
    set_name(r, vname(i));
    return r;
}
// foldToUnsignedSaturatedAdd
ic_fold_to_unsigned_saturated_add :: (i: Value_Id) -> Value_Id {
    ty := vtype(i);
    for side: 0..1 {
        mn := op(i, cast(u32) side); y := op(i, cast(u32) (1 - side));
        okm, m0, m1 := pm_intrinsic2(mn, IID_UMIN);
        if !okm continue;
        okn, ny := pm_not(m1);
        if okn && ny == y return create_intrinsic_call(IID_UADD_SAT, .[ty], .[m0, y]);
        okn, ny = pm_not(m0);
        if okn && ny == y return create_intrinsic_call(IID_UADD_SAT, .[ty], .[m1, y]);
    }
    okm, x, ncv := pm_intrinsic2(op(i, 0), IID_UMIN);
    oknc, notc := pm_apint(ncv);
    okc, c := pm_apint(op(i, 1));
    if okm && oknc && okc && ap_eq(c, ap_not(notc)) return create_intrinsic_call(IID_UADD_SAT, .[ty], .[x, const_int_ap(ty, c)]);
    return NONE;
}
// combineAddSubWithShlAddSub
ic_combine_add_sub_with_shl_add_sub :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        shl := op(i, cast(u32) side); a := op(i, cast(u32) (1 - side));
        ok, ng, cnt := pm_binop(shl, .SHL);
        if !ok || !has_one_use(shl) || !has_one_use(ng) continue;
        okn, b := pm_neg(ng);
        if !okn continue;
        nshl := icb_shl(b, cnt);
        return create_binop(.SUB, a, nshl);
    }
    return NONE;
}
// foldAddToAshr
ic_fold_add_to_ashr :: (add: Value_Id) -> Value_Id {
    ok, x, dcv := pm_binop(op(add, 0), .SDIV);
    okp, divc := pm_power2_ap(dcv);
    if !ok || !okp || ap_is_negative(divc) return NONE;
    oks, cmp := pmi_cast(op(add, 1), .SEXT);
    if !oks return NONE;
    okc, pred, ss, ca, cb := pm_icmp(cmp);
    if !okc return NONE;
    oka, ax, mcv := pm_binop(ca, .AND);
    okm, maskc := pm_apint(mcv);
    okmc, maskccmp := pm_apint(cb);
    if !oka || ax != x || !okm || !okmc return NONE;
    if (pred != ICMP_UGT || !ap_is_sign_mask(maskccmp)) && (pred != ICMP_EQ || !ap_eq(maskccmp, maskc)) return NONE;
    smin := ap_signed_min(scalar_bits(add));
    valid: bool;
    if pred == ICMP_UGT valid = ap_eq(maskc, ap_or(smin, ap_sub_u64(divc, 1)));
    else valid = ap_eq_u64(divc, 2) && ap_eq(maskc, ap_add_u64(smin, 1));
    if !valid return NONE;
    return create_binop(.ASHR, x, const_int_of(vtype(add), cast(u64) ap_exact_log2(divc)));
}

// foldAddLikeCommutative
ic_fold_add_like_commutative :: (lhs: Value_Id, rhs: Value_Id, nsw: bool, nuw: bool) -> Value_Id {
    ok, a, b := pm_binop(lhs, .SUB);
    if ok {
        ok2, c, a2 := pm_binop(rhs, .SUB);
        if ok2 && a2 == a {
            r := create_binop(.SUB, c, b);
            nsw_out := nsw && has_nsw(lhs) && has_nsw(rhs);
            nuw_out := has_nuw(lhs) && has_nuw(rhs);
            set_nsw(r, nsw_out); set_nuw(r, nuw_out);
            return r;
        }
    }
    // ((X s/ C1) << C2) + X => X s% -C1 where -C1 is 1 << C2
    oks, sd, c2v := pm_binop(lhs, .SHL);
    okc2, c2 := pm_apint(c2v);
    if oks && okc2 {
        okd, dx, c1v := pm_binop(sd, .SDIV);
        okc1, c1 := pm_apint(c1v);
        if okd && dx == rhs && okc1 {
            minus_c1 := ap_neg(c1);
            if ap_eq(minus_c1, ap_shl_ap(ap_one(c2.bits), c2)) return create_binop(.SREM, rhs, const_int_ap(vtype(rhs), minus_c1));
        }
    }
    // (A + C) + (B & ~C) == A + (B | C)
    oka, aa, ab := pm_binop(lhs, .ADD);
    if oka {
        av, c1v: Value_Id;
        okc, c1 := pm_apint(ab);
        if okc { av = aa; } else { okc, c1 = pm_apint(aa); av = ab; }
        if okc {
            okb, b2 := pm_binop(rhs, .AND);
            if okb {
                bv: Value_Id = NONE;
                if pm_specific_int_ap(op(rhs, 1), ap_not(c1)) bv = op(rhs, 0);
                else if pm_specific_int_ap(op(rhs, 0), ap_not(c1)) bv = op(rhs, 1);
                if bv != NONE {
                    if !has_one_use(lhs) && !has_one_use(rhs) return NONE;
                    nsw_out := nsw && has_nsw(lhs);
                    nuw_out := nuw && has_nuw(lhs);
                    no := icb_or(bv, const_int_ap(vtype(lhs), c1));
                    na := create_binop(.ADD, av, no);
                    set_nsw(na, nsw_out); set_nuw(na, nuw_out);
                    return na;
                }
            }
        }
    }
    return NONE;
}

// canonicalizeCondSignextOfHighBitExtractToSignextHighBitExtract
ic_canonicalize_cond_signext_of_high_bit_extract :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        if inst_op(i) == .SUB && side == 1 break;   // the select must be the RHS of a sub
        ext_v := op(i, cast(u32) side);
        sel := op(i, cast(u32) (1 - side));
        extract := trunc_or_self_i(ext_v);
        okl, x, low := pm_binop(extract, .LSHR);
        if !okl || !is_inst(low) continue;
        if inst_op(i) == .SUB && op(i, 1) != sel continue;
        xty := vtype(x);
        had_trunc := vtype(i) != xty;
        if had_trunc && !has_one_use(op(i, 0)) && !has_one_use(op(i, 1)) continue;
        lb := zext_or_self_i(low);
        oks, bwv, nb := pm_binop(lb, .SUB);
        if !oks || !pm_specific_int(bwv, scalar_bits(x)) continue;
        nbits := zext_or_self_i(nb);
        skip :: (v: Value_Id, is_sub: bool) -> Value_Id { if is_sub return zext_or_self_i(v); return sext_or_self_i(v); }
        is_sub := inst_op(i) == .SUB;
        s := skip(sel, is_sub);
        okse, cond, sev, zero := pm_select(s);
        if !okse continue;
        okc, pred, ss, cx, thrv := pm_icmp(cond);
        okt, thr := pm_apint(thrv);
        if !okc || cx != x || !okt continue;
        is_check, should_signext := is_sign_bit_check(pred, thr);
        if !is_check continue;
        if !should_signext { t := sev; sev = zero; zero = t; }
        if !pm_zero(zero) continue;
        sev = skip(sev, is_sub);
        okshl, basec, shamt := pm_binop(sev, .SHL);
        if !okshl || !pm_constant(basec) || zext_or_self_i(shamt) != nbits continue;
        if is_sub { if !pm_one(basec) continue; } else { if !pm_all_ones(basec) continue; }
        na := create_binop(.ASHR, x, low);
        set_name(na, tprint("%.sext", vname(extract)));
        copy_ir_flags(na, extract);
        if !had_trunc return na;
        icb_insert(na);
        return create_cast(ifx type_bits(scalar_type(vtype(i))) == type_bits(scalar_type(xty)) then Opcode.BITCAST else .TRUNC, na, vtype(i));
    }
    return NONE;
}

// factorizeMathWithShlOps
ic_factorize_math_with_shl_ops :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    if !is_binary_operator(op0) || !is_binary_operator(op1) || !(has_one_use(op0) || has_one_use(op1)) return NONE;
    ok0, x, shamt := pm_binop(op0, .SHL);
    ok1, y, shamt1 := pm_binop(op1, .SHL);
    if !ok0 || !ok1 || shamt1 != shamt return NONE;
    nsw := has_nsw(i) && has_nsw(op0) && has_nsw(op1);
    nuw := has_nuw(i) && has_nuw(op0) && has_nuw(op1);
    nm := icb_binop(inst_op(i), x, y);
    if is_binary_operator(nm) { set_nsw(nm, nsw); set_nuw(nm, nuw); }
    ns := create_binop(.SHL, nm, shamt);
    set_nsw(ns, nsw); set_nuw(ns, nuw);
    return ns;
}

// foldBoxMultiply
ic_fold_box_multiply :: (i: Value_Id) -> Value_Id {
    bw := scalar_bits(i);
    if (bw & 1) != 0 return NONE;
    half := bw >> 1;
    half_mask := ap_zext(ap_all_ones(half), bw);
    for side: 0..1 {
        shl := op(i, cast(u32) side); mul := op(i, cast(u32) (1 - side));
        oks, cross, hb := pm_binop(shl, .SHL);
        if !oks || !pm_specific_int(hb, half) continue;
        okm, ylo, xlo := pm_binop(mul, .MUL);
        if !okm || !has_one_use(mul) continue;
        okx, x, xm := pm_binop(xlo, .AND);
        oky, y, ym := pm_binop(ylo, .AND);
        if !okx || !pm_specific_int_ap(xm, half_mask) || !oky || !pm_specific_int_ap(ym, half_mask) return NONE;
        // CrossSum = (X' * (Y >> Halfbits)) + (Y' * (X >> HalfBits))
        oka, s0, s1 := pm_binop(cross, .ADD);
        if !oka return NONE;
        match_cm :: (m: Value_Id, shv: Value_Id, other1: Value_Id, other2: Value_Id, half: u32) -> bool {
            ok, a, b := pm_binop(m, .MUL);
            if !ok return false;
            for k: 0..1 {
                l := ifx k == 0 then a else b;
                r := ifx k == 0 then b else a;
                okl, lx, la := pm_binop(l, .LSHR);
                if okl && lx == shv && pm_specific_int(la, half) && (r == other1 || r == other2) return true;
            }
            return false;
        }
        if (match_cm(s0, y, x, xlo, half) && match_cm(s1, x, y, ylo, half)) || (match_cm(s1, y, x, xlo, half) && match_cm(s0, x, y, ylo, half))
            return create_binop(.MUL, x, y);
        return NONE;
    }
    return NONE;
}

// checkDivCeilNUW / foldDivCeil
ic_fold_div_ceil :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        divp := op(i, cast(u32) side); zc := op(i, cast(u32) (1 - side));
        if !has_one_use(divp) continue;
        ud := zext_or_self_i(divp);
        if ud != divp && !has_one_use(ud) continue;
        okd, x, y := pm_binop(ud, .UDIV);
        if !okd || !has_one_use(ud) continue;
        okz, cmp := pmi_cast(zc, .ZEXT);
        if !okz || !has_one_use(zc) || !has_one_use(cmp) continue;
        okc, ur, z := pm_specific_icmp(cmp, ICMP_NE);
        if !okc || !pm_zero(z) || !has_one_use(ur) continue;
        oku, ux, uy := pm_binop(ur, .UREM);
        if !oku || ux != x || uy != y continue;
        q: Simplify_Query = ic.sq;
        crx := compute_constant_range(x, false, q);
        cry := compute_constant_range(y, false, q);
        min_y := cr_umin(cry); max_x := cr_umax(crx); max_y := cr_umax(cry);
        if ap_is_zero(min_y) || ap_ugt(max_x, ap_neg(max_y)) return NONE;
        ym1 := icb_add(y, const_all_ones_of(vtype(y)));
        nuw_add := icb_add(x, ym1, "", true);
        if vtype(x) != vtype(i) {
            div := icb_udiv(nuw_add, y);
            return create_cast(.ZEXT, div, vtype(i));
        }
        return create_binop(.UDIV, nuw_add, y);
    }
    return NONE;
}

// ---------------------------------------------------------------- visitAdd

ic_visit_add :: (i: Value_Id) -> Value_Id {
    v := simplify_add_inst(op(i, 0), op(i, 1), has_nsw(i), has_nuw(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r = ic_fold_box_multiply(i); if r != NONE return r;
    r = ic_factorize_math_with_shl_ops(i); if r != NONE return r;
    r = ic_fold_add_with_constant(i); if r != NONE return r;
    r = ic_fold_no_wrap_add(i); if r != NONE return r;
    r = ic_fold_binop_shift_with_shift(i); if r != NONE return r;
    r = ic_combine_add_sub_with_shl_add_sub(i); if r != NONE return r;
    lhs := op(i, 0); rhs := op(i, 1);
    r = ic_fold_add_like_commutative(lhs, rhs, has_nsw(i), has_nuw(i)); if r != NONE return r;
    r = ic_fold_add_like_commutative(rhs, lhs, has_nsw(i), has_nuw(i)); if r != NONE return r;
    ty := vtype(i);
    if is_int_or_int_vector_n(ty, 1) return create_binop(.XOR, lhs, rhs);
    // X + X --> X << 1
    if lhs == rhs {
        shl := create_binop(.SHL, lhs, const_int_of(ty, 1));
        set_nsw(shl, has_nsw(i)); set_nuw(shl, has_nuw(i));
        return shl;
    }
    okna, a := pm_neg(lhs);
    if okna {
        oknb, b := pm_neg(rhs);
        if oknb return create_neg(icb_add(a, b));
        sub := create_binop(.SUB, rhs, a);
        set_nsw(sub, has_nsw(i) && has_nsw(lhs));
        return sub;
    }
    oknb, b := pm_neg(rhs);
    if oknb {
        sub := create_binop(.SUB, lhs, b);
        set_nsw(sub, has_nsw(i) && has_nsw(rhs));
        return sub;
    }
    v = ic_check_for_negative_operand(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    // (A + 1) + ~B --> A - B (and the commuted forms)
    for side: 0..1 {
        ad := op(i, cast(u32) side); nt := op(i, cast(u32) (1 - side));
        ok, aa, one := pm_binop(ad, .ADD);
        okn, bb := pm_not(nt);
        if ok && pm_one(one) && okn return create_binop(.SUB, aa, bb);
    }
    {
        okad, x0, x1 := pm_binop(lhs, .ADD);
        if okad && pm_one(rhs) {
            okn0, nb0 := pm_not(x0);
            if okn0 return create_binop(.SUB, x1, nb0);
            okn1, nb1 := pm_not(x1);
            if okn1 return create_binop(.SUB, x0, nb1);
        }
    }
    // (A + C) + ~B --> A - B + (C-1)
    for side: 0..1 {
        ad := op(i, cast(u32) side); nt := op(i, cast(u32) (1 - side));
        ok, aa, cv := pm_binop(ad, .ADD);
        okc, c := pm_apint_ap(cv);
        okn, bb := pm_not(nt);
        if ok && has_one_use(ad) && okc && okn {
            sub := icb_sub(aa, bb);
            return create_binop(.ADD, sub, const_int_ap(ty, ap_sub_u64(c, 1)));
        }
    }
    {
        okad, x0, x1 := pm_binop(lhs, .ADD);
        okc, c := pm_apint_ap(rhs);
        if okad && has_one_use(lhs) && okc {
            okn0, nb0 := pm_not(x0);
            aa, bb: Value_Id = NONE;
            if okn0 { bb = nb0; aa = x1; }
            else { okn1, nb1 := pm_not(x1); if okn1 { bb = nb1; aa = x0; } }
            if bb != NONE {
                sub := icb_sub(aa, bb);
                return create_binop(.ADD, sub, const_int_ap(ty, ap_sub_u64(c, 1)));
            }
        }
    }
    // (A + RHS) + RHS --> A + (RHS << 1)
    if has_one_use(lhs) { ok, aa := pm_c_binop_with(lhs, .ADD, rhs); if ok return create_binop(.ADD, aa, icb_shl_c(rhs, 1, "reass.add")); }
    // LHS + (A + LHS) --> A + (LHS << 1)
    if has_one_use(rhs) { ok, aa := pm_c_binop_with(rhs, .ADD, lhs); if ok return create_binop(.ADD, aa, icb_shl_c(lhs, 1, "reass.add")); }
    {
        // (A + C1) + (C2 - B) --> (A - B) + (C1 + C2)
        for side: 0..1 {
            ad := op(i, cast(u32) side); sb := op(i, cast(u32) (1 - side));
            ok, aa, c1 := pm_binop(ad, .ADD);
            oks, c2, bb := pm_binop(sb, .SUB);
            if ok && pm_imm_constant(c1) && oks && pm_imm_constant(c2) && (has_one_use(lhs) || has_one_use(rhs)) {
                sub := icb_sub(aa, bb);
                return create_binop(.ADD, sub, ce_binop(.ADD, c1, c2, 0));
            }
        }
        // (C1 - A) + B --> (B - A) + C1
        for side: 0..1 {
            sb := op(i, cast(u32) side); bb := op(i, cast(u32) (1 - side));
            oks, c1, aa := pm_binop(sb, .SUB);
            if oks && has_one_use(sb) && pm_imm_constant(c1) {
                sub := icb_sub(bb, aa, "reass.sub");
                return create_binop(.ADD, sub, c1);
            }
        }
    }
    v = ic_simplify_add_with_remainder(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    // (A & 2^C1) + A => A & (2^C1 - 1) iff bit C1 in A is a sign bit
    for side: 0..1 {
        an := op(i, cast(u32) side); other := op(i, cast(u32) (1 - side));
        ok, aa, cv := pm_binop(an, .AND);
        okc, c1 := pm_apint(cv);
        if ok && okc && aa == other && ap_is_power_of_2(c1) && ic_num_sign_bits(aa, i) > ap_clz(c1)
            return create_binop(.AND, aa, const_int_ap(vtype(rhs), ap_sub_u64(c1, 1)));
    }
    // ZExt (B - A) + ZExt(A) --> ZExt(B)
    {
        okr, ra := pmi_cast(rhs, .ZEXT);
        okl, la := pmi_cast(lhs, .ZEXT);
        if okr && okl {
            oks, sb, sa := pm_ob(la, .SUB, F_NUW);
            if oks && sa == ra return create_cast(.ZEXT, sb, vtype(lhs));
            oks, sb, sa = pm_ob(ra, .SUB, F_NUW);
            if oks && sa == la return create_cast(.ZEXT, sb, vtype(lhs));
        }
    }
    // zext(A) + sext(A) --> 0 if A is i1
    for side: 0..1 {
        okz, za := pmi_cast(op(i, cast(u32) side), .ZEXT);
        oks, sa := pmi_cast(op(i, cast(u32) (1 - side)), .SEXT);
        if okz && oks && za == sa && is_int_or_int_vector_n(vtype(za), 1) return ic_replace_inst_uses_with(i, const_null_value(vtype(i)));
    }
    // sext(A < B) + zext(A > B) => ucmp/scmp(A, B)
    for side: 0..1 {
        oks, sc := pmi_cast(op(i, cast(u32) side), .SEXT);
        okz, zc := pmi_cast(op(i, cast(u32) (1 - side)), .ZEXT);
        if !oks || !okz continue;
        ok1, ltp, ss1, a1, b1 := pm_icmp(sc);
        ok2, gtp, ss2, a2, b2 := pm_icmp(zc);
        if !ok1 || !ok2 continue;
        // m_c_ICmp(GTPred, m_Deferred(A), m_Deferred(B)): the second compare may have swapped operands
        if a2 == a1 && b2 == b1 {}
        else if a2 == b1 && b2 == a1 gtp = swapped_predicate(gtp);
        else continue;
        if !is_int_or_int_vector(vtype(a1)) continue;
        aa := a1; bb := b1;
        if icmp_is_gt(ltp) { t := ltp; ltp = gtp; gtp = t; t2 := aa; aa = bb; bb = t2; }
        if icmp_is_lt(ltp) && icmp_is_gt(gtp) && icmp_is_signed(ltp) == icmp_is_signed(gtp)
            return ic_replace_inst_uses_with(i, icb_intrinsic(ifx icmp_is_signed(ltp) then IID_SCMP else IID_UCMP, .[ty, vtype(aa)], .[aa, bb]));
        break;
    }
    // A+B --> A|B iff A and B have no bits set in common
    ncb := get_no_common_bits_set_result(lhs, rhs, ic_q(i));
    if ncb == .KNOWN return create_binop_flags(.OR, lhs, rhs, F_EXACT);
    if ncb == .ONLY_IF_UNDEF_IGNORED return create_binop(.OR, lhs, rhs);
    r = ic_narrow_math_if_no_overflow(i); if r != NONE return r;
    // (add (xor A, B) (and A, B)) --> (or A, B)
    for side: 0..1 {
        okx, xa, xb := pm_binop(op(i, cast(u32) side), .XOR);
        oka, aa, ab := pm_binop(op(i, cast(u32) (1 - side)), .AND);
        if okx && oka && ((aa == xa && ab == xb) || (aa == xb && ab == xa)) return create_binop(.OR, xa, xb);
    }
    // (add (or A, B) (and A, B)) --> (add A, B)
    for side: 0..1 {
        oko, oa, ob := pm_binop(op(i, cast(u32) side), .OR);
        oka, aa, ab := pm_binop(op(i, cast(u32) (1 - side)), .AND);
        if oko && oka && ((aa == oa && ab == ob) || (aa == ob && ab == oa)) {
            ic_replace_operand(i, 0, oa);
            ic_replace_operand(i, 1, ob);
            return i;
        }
    }
    // (add A (or A, -A)) --> (and (add A, -1) A)
    for side: 0..1 {
        aa := op(i, cast(u32) side); orv := op(i, cast(u32) (1 - side));
        oko, o0, o1 := pm_binop(orv, .OR);
        if !oko || !has_one_use(orv) continue;
        okn0, n0 := pm_neg(o0);
        okn1, n1 := pm_neg(o1);
        if (okn0 && n0 == aa && o1 == aa) || (okn1 && n1 == aa && o0 == aa) {
            add := icb_add(aa, const_all_ones_of(vtype(aa)), "", has_nuw(i), has_nsw(i));
            return create_binop(.AND, add, aa);
        }
    }
    // ((A & -A) - 1) --> ((A - 1) & ~A)
    {
        oka, a0, a1 := pm_binop(lhs, .AND);
        if oka && has_one_use(lhs) && pm_all_ones(rhs) {
            aa: Value_Id = NONE;
            okn, n := pm_neg(a1);
            if okn && has_one_use(a1) && n == a0 aa = a0;
            else { okn, n = pm_neg(a0); if okn && has_one_use(a0) && n == a1 aa = a1; }
            if aa != NONE {
                all_ones := const_all_ones_of(vtype(rhs));
                dec := icb_add(aa, all_ones);
                nt := icb_xor(aa, all_ones);
                return create_binop(.AND, dec, nt);
            }
        }
    }
    // ~(A * C1) + A --> (A * (1 - C1)) - 1
    for side: 0..1 {
        nt := op(i, cast(u32) side); aa := op(i, cast(u32) (1 - side));
        okn, m := pm_not(nt);
        if !okn || !has_one_use(nt) || !has_one_use(m) continue;
        okm, ma, mc := pm_binop(m, .MUL);
        okc, c1 := pm_apint(mc);
        if okm && okc && ma == aa {
            nmc := const_int_ap(ty, ap_sub(ap_one(c1.bits), c1));
            nm := icb_mul(aa, nmc);
            return create_binop(.ADD, nm, const_all_ones_of(ty));
        }
    }
    // (A * -2**C) + B --> B - (A << C)
    for side: 0..1 {
        m := op(i, cast(u32) side); bb := op(i, cast(u32) (1 - side));
        okm, ma, mc := pm_binop(m, .MUL);
        if !okm || !has_one_use(m) continue;
        okp, np2 := pm_apint_pred(mc, ap_is_negated_power_of_2);
        if !okp continue;
        shc := const_int_of(ty, ap_ctz(np2));
        shl := icb_shl(ma, shc);
        return create_binop(.SUB, bb, shl);
    }
    // (A s>> (BW - 1)) + (zext (A s> 0)) --> (A s>> (BW - 1)) | (zext (A != 0))
    bw := type_bits(scalar_type(ty));
    {
        oka, aa, sa := pm_binop(lhs, .ASHR);
        okz, zc := pmi_cast(rhs, .ZEXT);
        if oka && pm_specific_int_allow_poison(sa, bw - 1) && okz && has_one_use(rhs) && has_one_use(zc) {
            okc, ca, cz := pm_specific_icmp(zc, ICMP_SGT);
            if okc && ca == aa && pm_zero_int(cz) {
                nz := icb_is_not_null(aa, "isnotnull");
                zx := icb_zext(nz, ty, "isnotnull.zext");
                return create_binop(.OR, lhs, zx);
            }
        }
    }
    // (add X, (sext/zext (icmp eq X, C))) -> (select (icmp eq X, C), (add C, (sext/zext 1)), X)
    for side: 0..1 {
        aa := op(i, cast(u32) side); ext := op(i, cast(u32) (1 - side));
        oke, cond := pmi_zext_or_sext(ext);
        if !oke continue;
        okc, ca, cc := pm_specific_icmp(cond, ICMP_EQ);
        if !okc || ca != aa || !pm_imm_constant(cc) continue;
        if !has_one_use(ext) continue;
        addc := ifx inst_op(ext) == .ZEXT then ic_add_one(cc) else ic_sub_one(cc);
        return ic_replace_inst_uses_with(i, icb_select(cond, addc, aa));
    }
    // (add (add A, 1), (sext (icmp ne A, 0))) => call umax(A, 1)
    {
        oka, aa, one := pm_binop(lhs, .ADD);
        oks, sc := pmi_cast(rhs, .SEXT);
        if oka && pm_one(one) && oks && has_one_use(rhs) && has_one_use(sc) {
            okc, ca, cz := pm_specific_icmp(sc, ICMP_NE);
            if okc && ca == aa && pm_zero_int(cz)
                return ic_replace_inst_uses_with(i, icb_binary_intrinsic(IID_UMAX, aa, const_int_of(vtype(aa), 1)));
        }
    }
    r = ic_fold_add_to_ashr(i); if r != NONE return r;
    // (X >> log2(N)) + zext(X & (N-1) != 0) --> (X + (N-1)) >> log2(N)
    for side: 0..1 {
        sh := op(i, cast(u32) side); zc := op(i, cast(u32) (1 - side));
        okl, x, sav := pm_binop(sh, .LSHR);
        oksa, shamt := pm_apint(sav);
        if !okl || !has_one_use(sh) || !oksa continue;
        okz, cmp := pmi_cast(zc, .ZEXT);
        if !okz continue;
        okc, an, z := pm_specific_icmp(cmp, ICMP_NE);
        if !okc || !pm_zero_int(z) continue;
        oka, ax, mv := pm_binop(an, .AND);
        okm, mask := pm_low_bit_mask_ap(mv);
        if !oka || ax != x || !okm continue;
        if !ap_eq_u64(shamt, ap_popcount(mask)) continue;
        maskc := const_int_ap(vtype(x), mask);
        if ic_will_not_overflow_unsigned_add(x, maskc, i) {
            add := icb_add(x, maskc, "", true);
            return create_binop(.LSHR, add, const_int_ap(vtype(x), shamt));
        }
    }
    // (~X) + (~Y) --> -2 - (X + Y)
    {
        free_l, cons_l := ic_is_free_to_invert(lhs, has_one_use(lhs));
        if free_l && cons_l {
            free_r, cons_r := ic_is_free_to_invert(rhs, has_one_use(rhs));
            if free_r && cons_r {
                nl := ic_get_freely_inverted(lhs, has_one_use(lhs), true);
                nr := ic_get_freely_inverted(rhs, has_one_use(rhs), true);
                lr := icb_add(nl, nr);
                return create_binop(.SUB, const_int_signed(vtype(rhs), -2), lr);
            }
        }
    }
    r = ic_try_fold_inst_with_ctpop_with_not(i); if r != NONE return r;
    changed := false;
    if !has_nsw(i) && ic_will_not_overflow_signed_add(lhs, rhs, i) { changed = true; set_nsw(i); }
    if !has_nuw(i) && ic_will_not_overflow_unsigned_add(lhs, rhs, i) { changed = true; set_nuw(i); }
    r = ic_canonicalize_lowbit_mask(i); if r != NONE return r;
    r = ic_canonicalize_cond_signext_of_high_bit_extract(i); if r != NONE return r;
    r = ic_fold_to_unsigned_saturated_add(i); if r != NONE return r;
    // usub.sat(A, B) + B => umax(A, B)
    for side: 0..1 {
        us := op(i, cast(u32) side); bb := op(i, cast(u32) (1 - side));
        oku, ua, ub := pm_intrinsic2(us, IID_USUB_SAT);
        if oku && has_one_use(us) && ub == bb return ic_replace_inst_uses_with(i, icb_intrinsic(IID_UMAX, .[vtype(i)], .[ua, ub]));
    }
    // ctpop(A) + ctpop(B) => ctpop(A | B) if A and B have no bits set in common
    {
        okl, la := pm_ctpop(lhs);
        okr, ra := pm_ctpop(rhs);
        if okl && has_one_use(lhs) && okr && has_one_use(rhs) && have_no_common_bits_set(la, ra, ic_q(i))
            return ic_replace_inst_uses_with(i, icb_intrinsic(IID_CTPOP, .[vtype(i)], .[icb_disjoint_or(la, ra)]));
    }
    // zext(ctpop(A) >u/!= 1) + (ctlz(A, true) ^ (BW - 1)) --> BW - ctlz(A - 1, false)
    for side: 0..1 {
        zc := op(i, cast(u32) side); other := op(i, cast(u32) (1 - side));
        okz, cmp := pmi_cast(zc, .ZEXT);
        if !okz continue;
        okc, pred, ss, ct, one := pm_icmp(cmp);
        if !okc || !pm_one(one) continue;
        okp, aa := pm_ctpop(ct);
        if !okp continue;
        if !has_one_use(other) continue;
        xo := zext_or_self_i(other);
        if xo != other && !has_one_use(xo) continue;
        okx, tr, xcv := pm_binop(xo, .XOR);
        okxc, xorc := pm_apint(xcv);
        if !okx || !has_one_use(xo) || !okxc || !has_one_use(tr) continue;
        cz := trunc_or_self_i(tr);
        if cz != tr && !has_one_use(cz) continue;
        okcl, cla, clb := pm_intrinsic2(cz, IID_CTLZ);
        if !okcl || cla != aa || !pm_one(clb) continue;
        if (pred == ICMP_UGT || pred == ICMP_NE) && ap_eq_u64(xorc, scalar_bits(aa) - 1) {
            sub := icb_add(aa, const_all_ones_of(vtype(aa)));
            ctlz := icb_intrinsic(IID_CTLZ, .[vtype(aa)], .[sub, get_false(ir.t_i1)]);
            ret := icb_sub(const_int_of(vtype(aa), scalar_bits(aa)), ctlz, "", true, true);
            return ic_replace_inst_uses_with(i, icb_zext_or_trunc(ret, vtype(i)));
        }
        break;
    }
    r = ic_fold_square_sum_int(i); if r != NONE return r;
    r = ic_fold_binop_of_displaced_shifts(i); if r != NONE return r;
    r = ic_fold_binop_of_select_and_cast_of_select_condition(i); if r != NONE return r;
    r = ic_fold_div_ceil(i); if r != NONE return r;
    if changed {
        ok, pn, start, step := match_simple_recurrence_bo(i);
        if ok wl_push_users(pn);
    }
    return ifx changed then i else NONE;
}
icmp_is_gt :: (p: u8) -> bool { return p == ICMP_SGT || p == ICMP_UGT; }
icmp_is_lt :: (p: u8) -> bool { return p == ICMP_SLT || p == ICMP_ULT; }

// foldBinOpOfDisplacedShifts (InstCombineAndOrXor.cpp)
ic_fold_binop_of_displaced_shifts :: (i: Value_Id) -> Value_Id {
    bw := scalar_bits(i);
    for side: 0..1 {
        s0 := op(i, cast(u32) side); s1 := op(i, cast(u32) (1 - side));
        if !is_inst(s0) || !is_shift_op(inst_op(s0)) || !is_inst(s1) || !is_shift_op(inst_op(s1)) continue;
        c1 := op(s0, 0); shamt := op(s0, 1);
        c2 := op(s1, 0);
        if !pm_imm_constant(c1) || !pm_imm_constant(c2) continue;
        oka, aa, addc := pm_add_like(op(s1, 1));
        if !oka continue;
        if aa != shamt {
            if addc == shamt { t := aa; aa = addc; addc = t; } else continue;
        }
        if !pm_imm_constant(addc) continue;
        ult_bw :: (a: APInt) -> bool { return ap_ult_u64(a, a.bits); }
        if !pm_int_pred(addc, ult_bw) return NONE;
        sh := inst_op(s0);
        if sh != inst_op(s1) return NONE;
        if inst_op(i) == .ADD && sh != .SHL return NONE;
        newc := icb_binop(inst_op(i), c1, icb_binop(sh, c2, addc));
        return create_binop(sh, newc, shamt);
    }
    return NONE;
}

// ---------------------------------------------------------------- pointer differences

// GEPNoWrapFlags::intersectForOffsetAdd: nuw and nusw survive when both have them; inbounds only if both have
// it and nuw ... (GEPNoWrapFlags.h): (NW & Other) with inbounds dropped unless both are inbounds
gep_nw_intersect_for_offset_add :: (a: u32, b: u32) -> u32 {
    r := a & b & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if (r & F_INBOUNDS) == 0 && (r & F_NUSW) != 0 r &= ~cast(u32)(F_INBOUNDS | F_NUSW);
    return r;
}
gep_nw_bits :: (g: Value_Id) -> u32 {
    f := opr_flags(g) & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if (f & F_INBOUNDS) != 0 f |= F_NUSW;
    return f;
}
is_gep_operator :: (v: Value_Id) -> bool { return opr_code(v) == .GEP; }

// llvm::emitGEPOffset (llvm/lib/Analysis/Local.cpp)
ic_emit_gep_offset_raw :: (g: Value_Id, no_assumptions := false) -> Value_Id {
    idx_ty := dl_index_type(vtype(g));
    result: Value_Id = NONE;
    nw := gep_nw_bits(g);
    nsw := (nw & F_NUSW) != 0 && !no_assumptions;
    nuw := (nw & F_GEP_NUW) != 0 && !no_assumptions;
    add_offset :: (result: *Value_Id, off: Value_Id, g: Value_Id, nuw: bool, nsw: bool) {
        if result.* != NONE result.* = icb_add(result.*, off, tprint("%.offs", vname(g)), nuw, nsw);
        else result.* = off;
    }
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        o := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, o);
        defer cur = indexed;
        if is_const(o) {
            if is_null_value(o) continue;
            if is_struct {
                c := o;
                if is_vector_type(vtype(c)) c = get_splat_value(c);
                size := dl_struct_offset(cur, cast(u32) ap_zext_value(const_ap(c)));
                if size == 0 continue;
                add_offset(*result, const_int_of(idx_ty, size), g, nuw, nsw);
                continue;
            }
        }
        if is_vector_type(idx_ty) && !is_vector_type(vtype(o)) fatal("instcombine: emitGEPOffset of a vector GEP with scalar indices is not supported yet");
        if vtype(o) != idx_ty o = icb_int_cast(o, idx_ty, true, tprint("%.c", vname(o)));
        if type_is_scalable(indexed) fatal("instcombine: emitGEPOffset with scalable strides is not supported yet");
        stride := gep_seq_stride(cur, k, indexed);
        if stride != 1 {
            scale := const_int_of(scalar_type(idx_ty), stride);
            if is_vector_type(idx_ty) scale = cf_get_splat(idx_ty, scale);
            o = icb_mul(o, scale, tprint("%.idx", vname(g)), nuw, nsw);
        }
        add_offset(*result, o, g, nuw, nsw);
    }
    if result == NONE return const_null_value(idx_ty);
    return result;
}
// InstCombinerImpl::EmitGEPOffset(GEP, RewriteGEP = false)
ic_emit_gep_offset :: (g: Value_Id) -> Value_Id { return ic_emit_gep_offset_raw(g); }

// EmitGEPOffsets
ic_emit_gep_offsets :: (geps: [] Value_Id, nw: u32, idx_ty: Type_Id, rewrite: bool) -> Value_Id {
    add :: (sum: Value_Id, off: Value_Id, nw: u32) -> Value_Id {
        if sum != NONE return icb_add(sum, off, "", (nw & F_GEP_NUW) != 0, (nw & F_INBOUNDS) != 0);
        return off;
    }
    sum: Value_Id = NONE;
    one_use_sum: Value_Id = NONE;
    one_use_base: Value_Id = NONE;
    ALL :: cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    one_use_flags: u32 = ALL;
    for < k: 0..geps.count-1 {
        g := geps[k];
        off: Value_Id;
        {
            saved := ic.b;
            defer ic.b = saved;
            if rewrite && is_inst(g) irb_set_before(*ic.b, g);
            off = ic_emit_gep_offset_raw(g);
            if vtype(off) != idx_ty fatal("instcombine: EmitGEPOffsets with vector index types is not supported yet");
            if has_one_use(g) {
                one_use_sum = add(one_use_sum, off, nw);
                one_use_flags = gep_nw_intersect_for_offset_add(one_use_flags, gep_nw_bits(g));
                if one_use_base == NONE one_use_base = op(g, 0);
                continue;
            }
            if one_use_sum != NONE off = add(one_use_sum, off, nw);
            if rewrite && is_inst(g) && is_vector_type(vtype(off)) == is_vector_type(vtype(g)) &&
               !(is_int_or_int_vector_n(opr_gep_source_type(g), 8) && !is_vector_type(opr_gep_source_type(g)) && op(g, 1) == off) {
                base := ifx one_use_base != NONE then one_use_base else op(g, 0);
                np := icb_gep_i8(base, off, "", gep_nw_intersect_for_offset_add(one_use_flags, gep_nw_bits(g)));
                ic_replace_inst_uses_with(g, np);
                ic_erase_inst(g);
            }
        }
        sum = add(sum, off, nw);
        one_use_sum = NONE; one_use_base = NONE;
        one_use_flags = ALL;
    }
    if one_use_sum != NONE sum = add(sum, one_use_sum, nw);
    if sum == NONE return const_null_value(idx_ty);
    return sum;
}
// CreatePtrAdd(Ptr, Offset, Name, NW) = CreateGEP(i8, Ptr, Offset)
icb_gep_i8 :: (ptr: Value_Id, off: Value_Id, name: string, nw: u32) -> Value_Id {
    flags := nw;
    if (flags & F_INBOUNDS) != 0 flags &= ~cast(u32) F_NUSW;   // inbounds implies nusw: printed as inbounds only
    if is_const(ptr) && is_const(off) return cfo_constant(ce_gep(ir.t_i8, ptr, .[off], flags));
    i := new_inst(.GEP, irb_gep_result_type(ptr, .[off]), 2);
    inst(i).flags = flags; inst(i).ty2 = ir.t_i8;
    set_op(i, 0, ptr); set_op(i, 1, off);
    return icb_insert(i, name);
}

// CommonPointerBase::compute + isExpensive, OptimizePointerDifference
ic_optimize_pointer_difference :: (lhs_in: Value_Id, rhs_in: Value_Id, ty: Type_Id, is_nuw: bool) -> Value_Id {
    lhs := lhs_in; rhs := rhs_in;
    if vtype(lhs) != vtype(rhs) return NONE;
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    p := lhs;
    while true { array_add(*ptrs, p); if is_gep_operator(p) p = op(p, 0); else break; }
    contains :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }
    base: Value_Id = NONE;
    rgeps: [..] Value_Id; rgeps.allocator = temp;
    lgeps: [..] Value_Id; lgeps.allocator = temp;
    rnw: u32 = 0; lnw: u32 = 0;
    first := true;
    while true {
        if contains(ptrs, rhs) { base = rhs; break; }
        if is_gep_operator(rhs) {
            array_add(*rgeps, rhs);
            if first { first = false; rnw = gep_nw_bits(rhs); } else rnw = gep_nw_intersect_for_offset_add(rnw, gep_nw_bits(rhs));
            rhs = op(rhs, 0);
        } else return NONE;
    }
    first = true;
    while lhs != base {
        array_add(*lgeps, lhs);
        if first { first = false; lnw = gep_nw_bits(lhs); } else lnw = gep_nw_intersect_for_offset_add(lnw, gep_nw_bits(lhs));
        lhs = op(lhs, 0);
    }
    // isExpensive
    num := 0;
    process :: (geps: [] Value_Id, num: *int) {
        seen := false;
        for geps if !has_one_use(it) { if seen num.* += 1; seen = true; }
    }
    process(lgeps, *num); process(rgeps, *num);
    if num > 2 return NONE;
    rewrite := lgeps.count > 0 && rgeps.count > 0;
    idx_ty := dl_index_type(vtype(lhs_in));
    result := ic_emit_gep_offsets(lgeps, lnw, idx_ty, rewrite);
    offset2 := ic_emit_gep_offsets(rgeps, rnw, idx_ty, rewrite);
    if is_inst(result) && is_overflowing_binop(result) {
        ri := result;
        if is_nuw && pm_zero(offset2) && (lnw & F_INBOUNDS) != 0 && (!has_uses(ri) || has_one_use(ri)) && has_nsw(ri) && !has_nuw(ri) &&
           ((inst_op(ri) == .MUL && pm_non_negative(op(ri, 1))) || inst_op(ri) == .SHL)
            set_nuw(ri);
    }
    if !pm_zero(offset2)
        result = icb_sub(result, offset2, "gepdiff", is_nuw && (lnw & F_GEP_NUW) != 0 && (rnw & F_GEP_NUW) != 0, (lnw & F_INBOUNDS) != 0 && (rnw & F_INBOUNDS) != 0);
    return icb_int_cast(result, ty, true);
}

// foldSubOfMinMax
ic_fold_sub_of_min_max :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    id := call_iid(op1);
    if !is_min_max_intrinsic(id) return NONE;
    x := op(op1, 0); y := op(op1, 1);
    oka, a0, a1 := pm_binop(op0, .ADD);
    if oka && ((a0 == x && a1 == y) || (a0 == y && a1 == x)) && (has_one_use(op0) || has_one_use(op1))
        return create_intrinsic_call(inverse_min_max_intrinsic(id), .[ty], .[x, y]);
    if id == IID_UMIN && has_one_use(op1) {
        yy := op(op1, 0); z := op(op1, 1);
        if has_one_use(op0) {
            ok, xv := pm_c_binop_with(op0, .ADD, yy);
            if ok { us := icb_intrinsic(IID_USUB_SAT, .[ty], .[yy, z]); return create_binop(.ADD, xv, us); }
            ok, xv = pm_c_binop_with(op0, .ADD, z);
            if ok { us := icb_intrinsic(IID_USUB_SAT, .[ty], .[z, yy]); return create_binop(.ADD, xv, us); }
        }
    }
    if (id == IID_SMAX || id == IID_SMIN) && pm_zero_int(y) {
        oks, s0, z := pm_ob(x, .SUB, F_NSW);
        if oks && s0 == op0 return create_intrinsic_call(inverse_min_max_intrinsic(id), .[ty], .[op0, z]);
    }
    return NONE;
}

// m_PtrToIntOrAddr / m_PtrToIntSameSize
pm_ptrtoint_or_addr_v :: (v: Value_Id) -> (bool, Value_Id) {
    o := opr_code(v);
    if o == .PTRTOINT || o == .PTRTOADDR return true, op(v, 0);
    return false, NONE;
}

// ---------------------------------------------------------------- visitSub

ic_visit_sub :: (i: Value_Id) -> Value_Id {
    v := simplify_sub_inst(op(i, 0), op(i, 1), has_nsw(i), has_nuw(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(i);
    // x - (-A) --> x + A
    nv := ic_dyn_cast_neg_val(op1);
    if nv != NONE {
        res := create_binop(.ADD, op0, nv);
        if is_binary_operator(op1) { if has_nsw(op1) && has_nsw(i) set_nsw(res); }
        else if const_is_not_min_signed_value(op1) && has_nsw(i) set_nsw(res);
        return res;
    }
    r = ic_factorize_math_with_shl_ops(i); if r != NONE return r;
    if pm_imm_constant(op0) {
        c := op0;
        oka, x, c2 := pm_add_like(op1);
        if oka && pm_imm_constant(c2) {
            will_not_sov := ic_will_not_overflow_signed_sub(c, c2, i);
            res := create_binop(.SUB, ce_binop(.SUB, c, c2, 0), x);
            op1_nsw := true; op1_nuw := true;
            if is_overflowing_binop(op1) { op1_nsw = has_nsw(op1); op1_nuw = has_nuw(op1); }
            set_nsw(res, has_nsw(i) && op1_nsw && will_not_sov);
            set_nuw(res, has_nuw(i) && op1_nuw);
            return res;
        }
    }
    try_narrow_deduce_flags :: (i: Value_Id, op0: Value_Id, op1: Value_Id) -> Value_Id {
        e := ic_narrow_math_if_no_overflow(i);
        if e != NONE return e;
        changed := false;
        if !has_nsw(i) && ic_will_not_overflow_signed_sub(op0, op1, i) { changed = true; set_nsw(i); }
        if !has_nuw(i) && ic_will_not_overflow_unsigned_sub(op0, op1, i) { changed = true; set_nuw(i); }
        return ifx changed then i else NONE;
    }
    is_negation := pm_zero_int(op0);
    abs_like := false;
    if is_negation {
        u := ir.v_first_use[i];
        while u != NONE {
            us := ir.u_user[u];
            oks, sc, st, sf := pm_select(us);
            if oks && ((st == op1 && sf == i) || (st == i && sf == op1)) { abs_like = true; break; }
            u = ir.u_next[u];
        }
    }
    if !is_negation || !abs_like {
        neg1 := negator_negate(is_negation, is_negation && has_nsw(i), op1);
        if neg1 != NONE return create_binop(.ADD, neg1, op0);
    }
    if is_negation return try_narrow_deduce_flags(i, op0, op1);
    v = ic_fold_using_distributive_laws(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_int_or_int_vector_n(ty, 1) return create_binop(.XOR, op0, op1);
    if pm_all_ones(op0) return create_not(op1);
    // (X + -1) - Y --> ~Y + X
    {
        oka, x, m1 := pm_binop(op0, .ADD);
        if oka && has_one_use(op0) && pm_all_ones(m1) return create_binop(.ADD, icb_not(op1), x);
    }
    // (X & C1) - (X & C2) -> X & (C1 ^ C2) if (C1 & C2) == C2
    {
        ok0, x, c1 := pm_binop(op0, .AND);
        ok1, x1, c2 := pm_binop(op1, .AND);
        if ok0 && ok1 && x1 == x && pm_imm_constant(c1) && pm_imm_constant(c2) {
            andc := cf_binary(.AND, c1, c2);
            if const_is_element_wise_equal(c2, andc) return create_binop(.AND, x, cf_binary(.XOR, c1, c2));
        }
    }
    // ((X - Y) + Z) - Op1 --> (X + Z) - (Y + Op1)
    if has_one_use(op0) {
        oka, a0, a1 := pm_binop(op0, .ADD);
        if oka {
            for side: 0..1 {
                sb := ifx side == 0 then a0 else a1;
                z := ifx side == 0 then a1 else a0;
                oks, x, y := pm_binop(sb, .SUB);
                if oks && has_one_use(sb) {
                    xz := icb_add(x, z);
                    yw := icb_add(y, op1);
                    return create_binop(.SUB, xz, yw);
                }
            }
        }
    }
    // ((X - Y) - Op1) --> X - (Y + Op1)
    {
        oks, x, y := pm_binop(op0, .SUB);
        if oks && has_one_use(op0) {
            nuw := has_nuw(i) && has_nuw(op0);
            nsw := nuw && has_nsw(i) && has_nsw(op0);
            add := icb_add(y, op1, "", nuw, nsw);
            sub := create_binop(.SUB, x, add);
            set_nuw(sub, nuw); set_nsw(sub, nsw);
            return sub;
        }
    }
    // (X + C0) - (Y + C1) --> (X - Y) + (C0 - C1)
    {
        ok0, x, cx := pm_binop(op0, .ADD);
        ok1, y, cy := pm_binop(op1, .ADD);
        if ok0 && has_one_use(op0) && pm_imm_constant(cx) && ok1 && has_one_use(op1) && pm_imm_constant(cy) {
            ops_sub := icb_sub(x, y);
            return create_binop(.ADD, ops_sub, ce_binop(.SUB, cx, cy, 0));
        }
    }
    // (X + Z) - (Y + Z) --> (X - Y)
    {
        ok0, w, x := pm_add_like(op0);
        ok1, y, z := pm_add_like(op1);
        if ok0 && ok1 {
            rr: Value_Id = NONE;
            if w == y rr = create_binop(.SUB, x, z);
            else if w == z rr = create_binop(.SUB, x, y);
            else if x == y rr = create_binop(.SUB, w, z);
            else if x == z rr = create_binop(.SUB, w, y);
            if rr != NONE {
                n0, _a, _b := pm_nsw_add_like_i(op0);
                n1, _c, _d := pm_nsw_add_like_i(op1);
                u1, _e, _f := pm_nuw_add_like_i(op1);
                set_nsw(rr, has_nsw(i) && n0 && n1);
                set_nuw(rr, has_nuw(i) && u1);
                return rr;
            }
        }
    }
    // (~X) - (~Y) --> Y - X
    {
        f0, c0 := ic_is_free_to_invert(op0, has_one_use(op0));
        if f0 {
            f1, c1 := ic_is_free_to_invert(op1, has_one_use(op1));
            if f1 && (c0 || c1) {
                n0 := ic_get_freely_inverted(op0, has_one_use(op0), true);
                n1 := ic_get_freely_inverted(op1, has_one_use(op1), true);
                return create_binop(.SUB, n1, n0);
            }
        }
    }
    // add_rdx(V0) - add_rdx(V1) --> add_rdx(V0 - V1)
    {
        ok0, v0 := pm_intrinsic1(op0, IID_VECTOR_REDUCE_ADD);
        ok1, v1 := pm_intrinsic1(op1, IID_VECTOR_REDUCE_ADD);
        if ok0 && has_one_use(op0) && ok1 && has_one_use(op1) && vtype(v0) == vtype(v1) {
            sub := icb_sub(v0, v1);
            rdx := icb_intrinsic(IID_VECTOR_REDUCE_ADD, .[vtype(sub)], .[sub]);
            return ic_replace_inst_uses_with(i, rdx);
        }
    }
    if is_const(op0) {
        c := op0;
        okz, x := pmi_cast(op1, .ZEXT);
        if okz && is_int_or_int_vector_n(vtype(x), 1) return create_select(x, ic_sub_one(c), c);
        oks, sx := pmi_cast(op1, .SEXT);
        if oks && is_int_or_int_vector_n(vtype(sx), 1) return create_select(sx, ic_add_one(c), c);
        okn, nx := pm_not(op1);
        if okn return create_binop(.ADD, nx, ic_add_one(c));
        if is_inst(op1) && inst_op(op1) == .SELECT { rr := ic_fold_op_into_select(i, op1); if rr != NONE return rr; }
        if is_phi(op1) { rr := ic_fold_op_into_phi(i, op1); if rr != NONE return rr; }
        oksub, c2, x2 := pm_binop(op1, .SUB);
        if oksub && pm_imm_constant(c2) return create_binop(.ADD, x2, ce_binop(.SUB, c, c2, 0));
    }
    okc0, op0c := pm_apint(op0);
    if okc0 {
        if ap_is_mask(op0c) {
            q := ic_q(i); q.dc = null;   // getWithoutDomCondCache
            rk := known_bits(op1, q);
            if ap_is_all_ones(ap_or(op0c, rk.zero)) return create_binop(.XOR, op1, op0);
        }
        oka, inner, c2v := pm_binop(op1, .AND);
        okc2, c2 := pm_apint(c2v);
        if oka && has_one_use(op1) && okc2 && is_binary_operator(inner) {
            oks, c3v, x := pm_binop(inner, .SUB);
            okc3, c3 := pm_apint(c3v);
            if oks && okc3 && (has_nuw(inner) || ap_is_negated_power_of_2(c2)) {
                c2c3 := ap_and(c2, c3);
                c2c3m1 := ap_sub_u64(c2c3, 1);
                c2pc3 := ap_add(c2, c3);
                if ap_is_power_of_2(ap_sub(c3, c2c3m1)) && ap_is_subset_of(c2c3m1, c2pc3) {
                    an := icb_and(x, const_int_ap(ty, c2));
                    return create_binop(.ADD, an, const_int_ap(ty, ap_sub(op0c, c2c3)));
                }
            }
        }
    }
    // X-(X+Y) == -Y
    { ok, y := pm_c_binop_with(op1, .ADD, op0); if ok return create_neg(y); }
    // (X-Y)-X == -Y
    { ok, x, y := pm_binop(op0, .SUB); if ok && x == op1 return create_neg(y); }
    is_c_pair :: (v: Value_Id, opc: Opcode, a: Value_Id, b: Value_Id) -> bool {
        ok, x, y := pm_binop(v, opc);
        return ok && ((x == a && y == b) || (x == b && y == a));
    }
    { ok, a, b := pm_binop(op1, .AND); if ok && is_c_pair(op0, .OR, a, b) return create_binop(.XOR, a, b); }
    { ok, a, b := pm_binop(op0, .ADD); if ok && is_c_pair(op1, .OR, a, b) return create_binop(.AND, a, b); }
    { ok, a, b := pm_binop(op0, .ADD); if ok && is_c_pair(op1, .AND, a, b) return create_binop(.OR, a, b); }
    { ok, a, b := pm_binop(op0, .AND); if ok && is_c_pair(op1, .OR, a, b) && (has_one_use(op0) || has_one_use(op1)) return create_neg(icb_xor(a, b)); }
    { ok, a, b := pm_binop(op1, .XOR); if ok && is_c_pair(op0, .OR, a, b) return create_binop(.AND, a, b); }
    { ok, a, b := pm_binop(op0, .XOR); if ok && is_c_pair(op1, .OR, a, b) && (has_one_use(op0) || has_one_use(op1)) return create_neg(icb_and(a, b)); }
    // ((X | Y) - X) --> (~X & Y)
    if has_one_use(op0) { ok, y := pm_c_binop_with(op0, .OR, op1); if ok return create_binop(.AND, y, icb_not(op1, tprint("%.not", vname(op1)))); }
    // (sub (and Op1, (neg X)), Op1) --> neg (and Op1, (add X, -1))
    if has_one_use(op0) {
        ok, ng := pm_c_binop_with(op0, .AND, op1);
        if ok && has_one_use(ng) {
            okn, x := pm_neg(ng);
            if okn return create_neg(icb_and(op1, icb_add(x, const_all_ones_of(ty))));
        }
    }
    // (sub (and Op1, C), Op1) --> neg (and Op1, ~C)
    {
        ok, a, c := pm_binop(op0, .AND);
        if ok && has_one_use(op0) && a == op1 && pm_constant(c) return create_neg(icb_and(op1, icb_not(c)));
    }
    // (sub (xor X, (sext C)), (sext C)) => (select C, (neg X), X) and the reverse
    {
        sub_xor_cmp :: (lhs: Value_Id, rhs: Value_Id) -> (bool, Value_Id, Value_Id) {
            if !has_one_use(lhs) return false, NONE, NONE;
            ok, x := pm_c_binop_with(lhs, .XOR, rhs);
            if !ok return false, NONE, NONE;
            oks, c := pmi_cast(rhs, .SEXT);
            if !oks || scalar_bits(c) != 1 return false, NONE, NONE;
            return true, c, x;
        }
        ok, c, x := sub_xor_cmp(op0, op1);
        if ok return ic_create_select_unknown_profile(c, icb_neg(x), x);
        ok, c, x = sub_xor_cmp(op1, op0);
        if ok return ic_create_select_unknown_profile(c, x, icb_neg(x));
    }
    r = ic_try_fold_inst_with_ctpop_with_not(i); if r != NONE return r;
    r = ic_fold_sub_of_min_max(i); if r != NONE return r;
    // sink the sub into select hands
    {
        sink :: (sel: Value_Id, other: Value_Id, sel_is_lhs: bool, ty: Type_Id) -> Value_Id {
            ok, cond, tv, fv := pm_select(sel);
            if !ok || !has_one_use(sel) return NONE;
            if other != tv && other != fv return NONE;
            other_is_tv := other == tv;
            hand := ifx other_is_tv then fv else tv;
            nsub := ifx sel_is_lhs then icb_sub(hand, other) else icb_sub(other, hand);
            zero := const_null_value(ty);
            ns := create_select(cond, ifx other_is_tv then zero else nsub, ifx other_is_tv then nsub else zero);
            copy_metadata(ns, sel);
            return ns;
        }
        ns := sink(op0, op1, true, ty); if ns != NONE return ns;
        ns = sink(op1, op0, false, ty); if ns != NONE return ns;
    }
    // (X - (X & Y)) --> (X & ~Y)
    {
        ok, y := pm_c_binop_with(op1, .AND, op0);
        if ok && (has_one_use(op1) || is_const(y)) return create_binop(.AND, op0, icb_not(y, tprint("%.not", vname(y))));
    }
    // ~X - Min/Max(~X, Y) -> ~Min/Max(X, ~Y) - X, and the mirrored form
    {
        okn, x := pm_not(op0);
        if okn && is_min_max_intrinsic(call_iid(op1)) {
            y: Value_Id = NONE;
            if op(op1, 0) == op0 y = op(op1, 1); else if op(op1, 1) == op0 y = op(op1, 0);
            if y != NONE && !has_n_uses_or_more(op0, 3) {
                free, _c := ic_is_free_to_invert(y, has_one_use(y));
                if free return create_binop(.SUB, icb_not(op1), x);
            }
        }
        okn, x = pm_not(op1);
        if okn && is_min_max_intrinsic(call_iid(op0)) {
            y: Value_Id = NONE;
            if op(op0, 0) == op1 y = op(op0, 1); else if op(op0, 1) == op1 y = op(op0, 0);
            if y != NONE && !has_n_uses_or_more(op1, 3) {
                free, _c := ic_is_free_to_invert(y, has_one_use(y));
                if free return create_binop(.SUB, x, icb_not(op0));
            }
        }
    }
    // min(X+1, Y) - min(X, Y) --> zext X < Y
    for kind: 0..1 {
        id := ifx kind == 0 then IID_SMIN else IID_UMIN;
        if call_iid(op0) != id || call_iid(op1) != id || scalar_bits(i) == 1 || !(has_one_use(op0) || has_one_use(op1)) continue;
        found := false;
        x, y: Value_Id;
        for side: 0..1 {
            a := op(op0, cast(u32) side); yy := op(op0, cast(u32) (1 - side));
            ok: bool; ax, one: Value_Id;
            if kind == 0 { ok, ax, one = pm_nsw_add_like_i(a); } else { ok, ax, one = pm_nuw_add_like_i(a); }
            if !ok || !pm_one(one) continue;
            b0 := op(op1, 0); b1 := op(op1, 1);
            if (b0 == ax && b1 == yy) || (b0 == yy && b1 == ax) { found = true; x = ax; y = yy; break; }
        }
        if found {
            cond := icb_cmp(cast(u8) ifx kind == 0 then ICMP_SLT else ICMP_ULT, x, y);
            return create_cast(.ZEXT, cond, ty);
        }
    }
    // pointer differences
    {
        okl, lop := pm_ptrtoint_or_addr_v(op0);
        okr, rop := pm_ptrtoint_or_addr_v(op1);
        if okl && okr {
            res := ic_optimize_pointer_difference(lop, rop, ty, has_nuw(i));
            if res != NONE return ic_replace_inst_uses_with(i, res);
        }
        okt0, t0 := pmi_cast(op0, .TRUNC);
        okt1, t1 := pmi_cast(op1, .TRUNC);
        if okt0 && okt1 {
            okl, lop = pm_ptrtoint_or_addr_v(t0);
            okr, rop = pm_ptrtoint_or_addr_v(t1);
            if okl && okr {
                res := ic_optimize_pointer_difference(lop, rop, ty, false);
                if res != NONE return ic_replace_inst_uses_with(i, res);
            }
        }
        lhs_op, rhs_op: Value_Id = NONE;
        matched := false;
        okz0, z0 := pmi_cast(op0, .ZEXT);
        okz1, z1 := pmi_cast(op1, .ZEXT);
        if okz0 {
            ok0, p0 := pm_ptrtoint_same_size(z0);
            if ok0 && okz1 { ok1, p1 := pm_ptrtoint_same_size(z1); if ok1 { matched = true; lhs_op = p0; rhs_op = p1; } }
            if !matched && okz1 && opr_code(z0) == .PTRTOADDR && opr_code(z1) == .PTRTOADDR { matched = true; lhs_op = op(z0, 0); rhs_op = op(z1, 0); }
            if !matched && ok0 && opr_code(op1) == .PTRTOINT { matched = true; lhs_op = p0; rhs_op = op(op1, 0); }
        }
        if matched && is_gep_operator(lhs_op) && op(lhs_op, 0) == rhs_op {
            g := lhs_op;
            nw := gep_nw_bits(g);
            if (nw & F_GEP_NUW) != 0 || (nw & F_NUSW) != 0 {
                off := ic_emit_gep_offset(g);
                res: Value_Id;
                if (nw & F_GEP_NUW) != 0 res = icb_zext(off, ty, "", (nw & F_NUSW) != 0);
                else res = icb_sext(off, ty);
                return ic_replace_inst_uses_with(i, res);
            }
        }
    }
    bw := type_bits(scalar_type(ty));
    // shifty abs
    {
        oka, a, shv := pm_binop(op1, .ASHR);
        okc, shamt := pm_apint(shv);
        if oka && okc && has_n_uses(op1, 2) && ap_eq_u64(shamt, bw - 1) && has_one_use(op0) && is_c_pair(op0, .XOR, a, op1) {
            is_neg := icb_cmp(ICMP_SLT, a, const_null_value(vtype(a)));
            nega := ifx has_nuw(i) then const_null_value(vtype(a)) else icb_neg(a, "", has_nsw(i));
            return create_select(is_neg, nega, a);
        }
    }
    // sub (X + AddC), (X & AndC) --> and (X + AddC), ~AndC
    {
        oka, x, acv := pm_binop(op0, .ADD);
        okac, addc := pm_apint(acv);
        okn, x2, ancv := pm_binop(op1, .AND);
        okanc, andc := pm_apint(ancv);
        if oka && okac && okn && okanc && x2 == x {
            cttz := ap_ctz(addc);
            high := ap_high_bits_set(bw, bw - cttz);
            if ap_is_zero(ap_and(high, andc)) return create_binop(.AND, op0, const_int_ap(ty, ap_not(andc)));
        }
    }
    r = ic_canonicalize_cond_signext_of_high_bit_extract(i); if r != NONE return r;
    // X - usub.sat(X, Y) => umin(X, Y)
    {
        ok, a, y := pm_intrinsic2(op1, IID_USUB_SAT);
        if ok && has_one_use(op1) && a == op0 return ic_replace_inst_uses_with(i, icb_intrinsic(IID_UMIN, .[ty], .[op0, y]));
    }
    // umax(X, Op1) - Op1 --> usub.sat(X, Op1)
    if has_one_use(op0) { ok, x := pm_c_min_max_with(op0, IID_UMAX, op1); if ok return ic_replace_inst_uses_with(i, icb_intrinsic(IID_USUB_SAT, .[ty], .[x, op1])); }
    // Op0 - umin(X, Op0) --> usub.sat(Op0, X)
    if has_one_use(op1) { ok, x := pm_c_min_max_with(op1, IID_UMIN, op0); if ok return ic_replace_inst_uses_with(i, icb_intrinsic(IID_USUB_SAT, .[ty], .[op0, x])); }
    // Op0 - umax(X, Op0) --> 0 - usub.sat(X, Op0)
    if has_one_use(op1) { ok, x := pm_c_min_max_with(op1, IID_UMAX, op0); if ok { us := icb_intrinsic(IID_USUB_SAT, .[ty], .[x, op0]); return create_neg(us); } }
    // umin(X, Op1) - Op1 --> 0 - usub.sat(Op1, X)
    if has_one_use(op0) { ok, x := pm_c_min_max_with(op0, IID_UMIN, op1); if ok { us := icb_intrinsic(IID_USUB_SAT, .[ty], .[op1, x]); return create_neg(us); } }
    // C - ctpop(X) => ctpop(~X) if C is bitwidth
    if pm_specific_int(op0, bw) {
        ok, x := pm_ctpop(op1);
        if ok && has_one_use(op1) return ic_replace_inst_uses_with(i, icb_intrinsic(IID_CTPOP, .[ty], .[icb_not(x)]));
    }
    // (X * X) - (Y * Y) --> (X + Y) * (X - Y)
    {
        ok0, x, x2 := pm_binop(op0, .MUL);
        ok1, y, y2 := pm_binop(op1, .MUL);
        if ok0 && has_one_use(op0) && x == x2 && ok1 && has_one_use(op1) && y == y2 {
            pnsw := has_nsw(i) && has_nsw(op0) && has_nsw(op1) && bw > 2;
            pnuw := has_nuw(i) && has_nuw(op0) && has_nuw(op1) && bw > 1;
            add := icb_add(x, y, "add", pnuw, pnsw);
            sub := icb_sub(x, y, "sub", pnuw, pnsw);
            mul := icb_mul(add, sub, "", pnuw, pnsw);
            return ic_replace_inst_uses_with(i, mul);
        }
    }
    // max(X,Y) nsw/nuw - min(X,Y) --> abs(X nsw - Y)
    if call_iid(op0) == IID_SMAX && has_one_use(op0) && call_iid(op1) == IID_SMIN && has_one_use(op1) {
        x := op(op0, 0); y := op(op0, 1);
        if (op(op1, 0) == x && op(op1, 1) == y) || (op(op1, 0) == y && op(op1, 1) == x) {
            if has_nuw(i) || has_nsw(i) {
                sub := icb_sub(x, y, "sub", false, true);
                call := icb_binary_intrinsic(IID_ABS, sub, get_true(ir.t_i1));
                return ic_replace_inst_uses_with(i, call);
            }
        }
    }
    r = ic_fold_binop_of_select_and_cast_of_select_condition(i); if r != NONE return r;
    // (sub (sext (add nsw (X, Y)), sext (X))) --> (sext (Y))
    {
        ok1, x := pm_sext_like(op1);
        ok0, a := pm_sext_like(op0);
        if ok1 && is_inst(op1) && ok0 && is_inst(op0) {
            oka, a0, a1 := pm_ob(a, .ADD, F_NSW);
            if oka && (a0 == x || a1 == x) {
                y := ifx a0 == x then a1 else a0;
                return ic_replace_inst_uses_with(i, icb_sext(y, ty));
            }
        }
    }
    // (sub[ nsw] (sext (add nsw (X, Y)), sext (add nsw (X, Z)))) --> (sub[ nsw] (sext (Y), sext (Z)))
    {
        ok0, add0 := pm_sext_like(op0);
        ok1, add1 := pm_sext_like(op1);
        if ok0 && is_inst(op0) && ok1 && is_inst(op1) {
            okx, p0, p1 := pm_ob(add0, .ADD, F_NSW);
            oky, q0, q1 := pm_ob(add1, .ADD, F_NSW);
            x, y, z: Value_Id = NONE;
            if okx && oky {
                // (m_NSWAdd(X, Y) && m_c_NSWAdd(X, Z)) || (m_NSWAdd(Y, X) && m_c_NSWAdd(X, Z))
                for form: 0..1 {
                    xv := ifx form == 0 then p0 else p1;
                    yy := ifx form == 0 then p1 else p0;
                    if q0 == xv { x = xv; y = yy; z = q1; break; }
                    if q1 == xv { x = xv; y = yy; z = q0; break; }
                }
            }
            if x != NONE {
                new_instrs := (ifx !is_const(y) then 1 else 0) + (ifx !is_const(z) then 1 else 0);
                dead := 0;
                if has_one_use(op0) { dead += 1; if has_one_use(add0) dead += 1; }
                if has_one_use(op1) { dead += 1; if has_one_use(add1) dead += 1; }
                if dead >= new_instrs {
                    sy := icb_sext(y, ty);
                    sz := icb_sext(z, ty);
                    sub := icb_sub(sy, sz, "", false, has_nsw(i));
                    return ic_replace_inst_uses_with(i, sub);
                }
            }
        }
    }
    return try_narrow_deduce_flags(i, op0, op1);
}

// Constant::isElementWiseEqual
const_is_element_wise_equal :: (a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    if vtype(a) != vtype(b) return false;
    if !is_int_or_int_vector(vtype(a)) && !is_fp_type(scalar_type(vtype(a))) return false;
    // ICmp eq of the two constants, all true (undef-friendly: m_One with poison allowed)
    c := cfo_compare_inst_operands(ICMP_EQ, a, b);
    if is_fp_type(scalar_type(vtype(a))) {
        ia := cfo_cast_operand(.BITCAST, a, int_type_like(vtype(a)));
        ib := cfo_cast_operand(.BITCAST, b, int_type_like(vtype(b)));
        c = cfo_compare_inst_operands(ICMP_EQ, ia, ib);
    }
    return c != NONE && pm_one(c);
}
int_type_like :: (t: Type_Id) -> Type_Id {
    it := type_int(type_bits(scalar_type(t)));
    if is_vector_type(t) return vector_with_elt(t, it);
    return it;
}
