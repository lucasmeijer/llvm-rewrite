// InstCombine demanded-bits simplification: a port of the integer half of
// llvm/lib/Transforms/InstCombine/InstCombineSimplifyDemanded.cpp (ShrinkDemandedConstant,
// simplifyShiftSelectingPackedElement, SimplifyDemandedInstructionBits, SimplifyDemandedBits,
// SimplifyDemandedUseBits, SimplifyMultipleUseDemandedBits, simplifyShrShlDemandedBits).
// SimplifyDemandedVectorElts and the FP-class half (SimplifyDemandedUseFPClass) are not ported yet.

// Constant::getIntegerValue for integer (vector) types
const_integer_value :: (t: Type_Id, a: APInt) -> Value_Id {
    if is_ptr_or_ptr_vector(t) {
        // ConstantInt::get(Ctx, V), then ConstantExpr::getIntToPtr (folded), then the splat
        st := scalar_type(t);
        c := cfo_constant(ce_cast(.INTTOPTR, const_int_ap(type_int(a.bits), a), st));
        if is_vector_type(t) c = cf_get_splat(t, c);
        return c;
    }
    return const_int_ap(t, a);
}

// ShrinkDemandedConstant
ic_shrink_demanded_constant :: (i: Value_Id, k: u32, demanded: APInt) -> bool {
    o := op(i, k);
    ok, c := pm_apint(o);
    if !ok return false;
    if ap_is_subset_of(c, demanded) return false;
    set_op(i, k, const_int_ap(vtype(o), ap_and(c, demanded)));
    return true;
}

// SimplifyDemandedInstructionBits(Inst) / (Inst, Known)
ic_simplify_demanded_instruction_bits :: (i: Value_Id) -> bool {
    known := kb_new(ic_demanded_bit_width(vtype(i)));
    return ic_simplify_demanded_instruction_bits_known(i, *known);
}
ic_simplify_demanded_instruction_bits_known :: (i: Value_Id, known: *Known_Bits) -> bool {
    demanded := ap_all_ones(kb_bits(known.*));
    v := ic_simplify_demanded_use_bits(i, demanded, known, ic_q(i), 0);
    if v == NONE return false;
    if v == i return true;
    ic_replace_inst_uses_with(i, v);
    return true;
}
// getBitWidth(Ty, DL)
ic_demanded_bit_width :: (t: Type_Id) -> u32 {
    st := scalar_type(t);
    if is_ptr_type(st) return cast(u32) dl_ptr_spec(cast(u32) ir.types[st].a).bits;
    return type_bits(st);
}

// SimplifyDemandedBits(I, OpNo, DemandedMask, Known, Q, Depth)
ic_simplify_demanded_bits :: (i: Value_Id, k: u32, demanded: APInt, known: *Known_Bits, q: Simplify_Query, depth: u32) -> bool {
    u := op_use(i, k);
    v := ir.u_val[u];
    if is_const(v) { known.* = known_bits(v, q, depth); return false; }
    kb_reset_all(known);
    if ap_is_zero(demanded) { ic_replace_use(u, const_undef(vtype(v))); return true; }
    if !is_inst(v) { known.* = known_bits(v, q, depth); return false; }
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return false;
    nv: Value_Id;
    if has_one_use(v) nv = ic_simplify_demanded_use_bits(v, demanded, known, q, depth);
    else nv = ic_simplify_multiple_use_demanded_bits(v, demanded, known, q, depth);
    if nv == NONE return false;
    if is_inst(ir.u_val[u]) salvage_debug_info(ir.u_val[u]);
    ic_replace_use(u, nv);
    return true;
}

// the funnel-shift guard of the Shl/LShr cases: the one user is an `or` that convertOrOfShiftsToFunnelShift turns
// into a rotate (fshl/fshr with equal value operands)
ic_is_part_of_rotate :: (i: Value_Id) -> bool {
    if !has_one_use(i) return false;
    user := first_user(i);
    if !is_inst(user) || inst_op(user) != .OR return false;
    ok, args := ic_convert_or_of_shifts_to_funnel_shift(user);
    return ok && args[0] == args[1];
}
// convertOrOfShiftsToFunnelShift (InstCombineAndOrXor.cpp); returns the three funnel-shift arguments (the IID is
// not needed by the callers yet)
ic_convert_or_of_shifts_to_funnel_shift :: (orv: Value_Id) -> (bool, [3] Value_Id) {
    none: [3] Value_Id;
    width := scalar_bits(orv);
    or0 := op(orv, 0); or1 := op(orv, 1);
    if !is_inst(or0) || !is_inst(or1) return false, none;
    if is_binary_operator(or0) && is_binary_operator(or1) {
        is_ls :: (v: Value_Id) -> bool { return has_one_use(v) && (inst_op(v) == .SHL || inst_op(v) == .LSHR); }
        if !is_ls(or0) || !is_ls(or1) || inst_op(or0) == inst_op(or1) return false, none;
        if inst_op(or0) == .LSHR { t := or0; or0 = or1; or1 = t; }
        shv0 := op(or0, 0); sha0 := op(or0, 1);
        shv1 := op(or1, 0); sha1 := op(or1, 1);
        match_amt :: (l: Value_Id, r: Value_Id, width: u32, shv0: Value_Id, shv1: Value_Id, orv: Value_Id) -> Value_Id {
            okl, li := pm_apint_ap(l);
            okr, ri := pm_apint_ap(r);
            if okl && okr && ap_ult_u64(li, width) && ap_ult_u64(ri, width) && ap_eq_u64(ap_add(li, ri), width) return const_int_ap(vtype(l), li);
            if is_const(l) && is_const(r) {
                ult :: (a: APInt) -> bool { return ap_ult_u64(a, a.bits); }
                if pm_int_pred(l, ult) && pm_int_pred(r, ult) && pm_specific_int(ce_binop(.ADD, l, r, 0), width)
                    fatal("instcombine: convertOrOfShiftsToFunnelShift with non-splat constant amounts (mergeUndefsWith) is not supported yet");
            }
            oks, w, x := pm_binop(r, .SUB);
            if oks && has_one_use(r) && pm_specific_int(w, width) && x == l {
                kl := ic_known_bits(l, orv);
                if ap_ult_u64(kb_max_value(kl), width) return l;
                return NONE;
            }
            if shv0 != shv1 return NONE;
            if (width & (width - 1)) != 0 return NONE;
            mask := width - 1;
            neg_and :: (v: Value_Id, x: Value_Id, mask: u32) -> bool {
                ok, a, m := pm_binop(v, .AND);
                if !ok || !pm_specific_int(m, mask) return false;
                okn, nx := pm_neg(a);
                return okn && nx == x;
            }
            oka, ax, am := pm_binop(l, .AND);
            if oka && pm_specific_int(am, mask) && neg_and(r, ax, mask) return ax;
            if neg_and(r, l, mask) return l;
            okz, za := pmi_cast(l, .ZEXT);
            if okz {
                oka2, x2, m2 := pm_binop(za, .AND);
                if oka2 && pm_specific_int(m2, mask) {
                    okr2, ra, rm := pm_binop(r, .AND);
                    if okr2 && pm_specific_int(rm, mask) {
                        okn, nz := pm_neg(ra);
                        if okn {
                            okz2, za2 := pmi_cast(nz, .ZEXT);
                            if okz2 { okk, kx, km := pm_binop(za2, .AND); if okk && kx == x2 && pm_specific_int(km, mask) return l; }
                        }
                    }
                    okzr, zr := pmi_cast(r, .ZEXT);
                    if okzr {
                        okk, ka, km := pm_binop(zr, .AND);
                        if okk && pm_specific_int(km, mask) { okn, nx := pm_neg(ka); if okn && nx == x2 return l; }
                    }
                }
            }
            return NONE;
        }
        amt := match_amt(sha0, sha1, width, shv0, shv1, orv);
        if amt == NONE amt = match_amt(sha1, sha0, width, shv0, shv1, orv);
        if amt == NONE return false, none;
        r: [3] Value_Id; r[0] = shv0; r[1] = shv1; r[2] = amt;
        return true, r;
    }
    if inst_op(or0) == .ZEXT || inst_op(or1) == .ZEXT {
        if inst_op(or1) != .ZEXT { t := or0; or0 = or1; or1 = t; }
        oks, zh, amtv := pm_binop(or0, .SHL);
        okc, amt := pm_apint(amtv);
        if !oks || !has_one_use(or0) || !okc return false, none;
        okl, low := pmi_cast(or1, .ZEXT);
        okh, high := pmi_cast(zh, .ZEXT);
        if !okl || !okh return false, none;
        hs := scalar_bits(high); ls := scalar_bits(low);
        if ap_ult_u64(amt, ls) || ap_ugt_u64(amt, width - hs) return false, none;
        u := ir.v_first_use[zh];
        while u != NONE {
            defer u = ir.u_next[u];
            us := ir.u_user[u];
            oko, x, y := pm_binop(us, .OR);
            if !oko continue;
            if !is_inst(y) || inst_op(y) != .ZEXT { t := x; x = y; y = t; }
            oks2, sx, lamtv := pm_binop(x, .SHL);
            okc2, lamt := pm_apint(lamtv);
            if !oks2 || sx != or1 || !okc2 || y != zh || !dt_dominates_inst(ic.dt, us, orv) continue;
            if !ap_eq_u64(ap_add(lamt, amt), width) continue;
            drop_poison_generating_flags(us);
            drop_poison_generating_flags(x);
            r: [3] Value_Id; r[0] = us; r[1] = us; r[2] = const_int_ap(vtype(or0), amt);
            return true, r;
        }
        return false, none;
    }
    return false, none;
}

// SimplifyDemandedUseBits
ic_simplify_demanded_use_bits :: (i: Value_Id, demanded: APInt, known: *Known_Bits, q: Simplify_Query, depth: u32) -> Value_Id {
    bw := demanded.bits;
    vty := vtype(i);
    lk := kb_new(bw); rk := kb_new(bw);
    disable_wrap :: (i: Value_Id, nlz: u32) -> Value_Id {
        if nlz > 0 { set_nsw(i, false); set_nuw(i, false); }
        return i;
    }
    o := inst_op(i);
    computed := false;   // `break` out of the switch with Known set
    if o == {
        case .AND;
            if ic_simplify_demanded_bits(i, 1, demanded, *rk, q, depth + 1) ||
               ic_simplify_demanded_bits(i, 0, ap_and(demanded, ap_not(rk.zero)), *lk, q, depth + 1) return i;
            known.* = known_bits_and_xor_or(i, dem_all(vty), lk, rk, q, depth);
            if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(vty, known.one);
            if ap_is_subset_of(demanded, ap_or(lk.zero, rk.one)) return op(i, 0);
            if ap_is_subset_of(demanded, ap_or(rk.zero, lk.one)) return op(i, 1);
            if ic_shrink_demanded_constant(i, 1, ap_and(demanded, ap_not(lk.zero))) return i;
            computed = true;
        case .OR;
            if ic_simplify_demanded_bits(i, 1, demanded, *rk, q, depth + 1) ||
               ic_simplify_demanded_bits(i, 0, ap_and(demanded, ap_not(rk.one)), *lk, q, depth + 1) {
                drop_poison_generating_flags(i);
                return i;
            }
            known.* = known_bits_and_xor_or(i, dem_all(vty), lk, rk, q, depth);
            if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(vty, known.one);
            if ap_is_subset_of(demanded, ap_or(lk.one, rk.zero)) return op(i, 0);
            if ap_is_subset_of(demanded, ap_or(rk.one, lk.zero)) return op(i, 1);
            if ic_shrink_demanded_constant(i, 1, demanded) return i;
            if (inst(i).flags & F_EXACT) == 0 {
                no_common := have_no_common_bits_set_special_cases(op(i, 0), op(i, 1), q) == .KNOWN ||
                             have_no_common_bits_set_special_cases(op(i, 1), op(i, 0), q) == .KNOWN ||
                             kb_have_no_common_bits_set(lk, rk);
                if no_common {
                    set_flag(i, F_EXACT, true);
                    return i;
                }
            }
            computed = true;
        case .XOR;
            if ic_simplify_demanded_bits(i, 1, demanded, *rk, q, depth + 1) ||
               ic_simplify_demanded_bits(i, 0, demanded, *lk, q, depth + 1) return i;
            {
                okl, l := pm_ctpop(op(i, 0));
                okr, r := pm_ctpop(op(i, 1));
                if ap_eq_u64(demanded, 1) && okl && okr {
                    saved := ic.b; defer ic.b = saved;
                    irb_set_before(*ic.b, i);
                    x := icb_xor(l, r);
                    return icb_unary_intrinsic(IID_CTPOP, x);
                }
            }
            known.* = known_bits_and_xor_or(i, dem_all(vty), lk, rk, q, depth);
            if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(vty, known.one);
            if ap_is_subset_of(demanded, rk.zero) return op(i, 0);
            if ap_is_subset_of(demanded, lk.zero) return op(i, 1);
            if ap_is_subset_of(demanded, ap_or(rk.zero, lk.zero)) {
                orv := create_binop(.OR, op(i, 0), op(i, 1));
                if ap_is_all_ones(demanded) set_flag(orv, F_EXACT, true);
                ic_take_name(orv, i);
                return ic_insert_new_inst_with(orv, i);
            }
            if ap_is_subset_of(demanded, ap_or(rk.zero, rk.one)) && ap_is_subset_of(rk.one, lk.one) {
                andc := const_integer_value(vty, ap_and(ap_not(rk.one), demanded));
                an := create_binop(.AND, op(i, 0), andc);
                return ic_insert_new_inst_with(an, i);
            }
            okc, c := pm_apint(op(i, 1));
            if okc && !ap_is_all_ones(c) {
                if ap_is_all_ones(ap_or(c, ap_not(demanded))) { set_op(i, 1, const_all_ones_of(vty)); return i; }
                if ic_shrink_demanded_constant(i, 1, demanded) return i;
            }
            lhs := op(i, 0);
            if is_inst(lhs) && inst_op(lhs) == .AND && has_one_use(lhs) && is_const_int(op(i, 1)) && is_const_int(op(lhs, 1)) &&
               !ap_is_zero(ap_and(ap_and(lk.one, rk.one), demanded)) {
                new_mask := ap_not(ap_and(ap_and(lk.one, rk.one), demanded));
                andc := const_int_ap(vty, ap_and(new_mask, const_ap(op(lhs, 1))));
                na := create_binop(.AND, op(i, 0), andc);
                ic_insert_new_inst_with(na, i);
                xorc := const_int_ap(vty, ap_and(new_mask, const_ap(op(i, 1))));
                nx := create_binop(.XOR, na, xorc);
                return ic_insert_new_inst_with(nx, i);
            }
            computed = true;
        case .SELECT;
            if ic_simplify_demanded_bits(i, 2, demanded, *rk, q, depth + 1) ||
               ic_simplify_demanded_bits(i, 1, demanded, *lk, q, depth + 1) return i;
            canon :: (i: Value_Id, k: u32, demanded: APInt) -> bool {
                oks, selc := pm_apint(op(i, k));
                if !oks return false;
                okc, pred, ss, x, cmpcv := pm_icmp(op(i, 0));
                okcc, cmpc := pm_apint(cmpcv);
                if !okc || !okcc || is_const(x) || cmpc.bits != selc.bits return ic_shrink_demanded_constant(i, k, demanded);
                if ap_eq(cmpc, selc) return false;
                if ap_eq(ap_and(cmpc, demanded), ap_and(selc, demanded)) { set_op(i, k, const_int_ap(vtype(i), cmpc)); return true; }
                return ic_shrink_demanded_constant(i, k, demanded);
            }
            if canon(i, 1, demanded) || canon(i, 2, demanded) return i;
            adjust_known_bits_for_select_arm(*lk, op(i, 0), op(i, 1), false, q, depth);
            adjust_known_bits_for_select_arm(*rk, op(i, 0), op(i, 2), true, q, depth);
            known.* = kb_intersect(lk, rk);
            computed = true;
        case .TRUNC; #through;
        case .ZEXT;
            if o == .TRUNC {
                ok, x, cv := pm_binop(op(i, 0), .LSHR);
                okc, c := pm_apint(cv);
                if ok && has_one_use(op(i, 0)) && okc {
                    if ap_ult_u64(c, scalar_bits(i)) && ap_ule_u64(c, ap_clz(demanded)) {
                        saved := ic.b; defer ic.b = saved;
                        irb_set_before(*ic.b, i);
                        tr := icb_trunc(x, vty);
                        return icb_lshr(tr, const_int_of(vtype(tr), ap_zext_value(c)));
                    }
                }
            }
            src_bw := scalar_bits(op(i, 0));
            in_dem := ap_zext_or_trunc(demanded, src_bw);
            in_known := kb_new(src_bw);
            if ic_simplify_demanded_bits(i, 0, in_dem, *in_known, q, depth + 1) {
                drop_poison_generating_flags(i);
                return i;
            }
            if o == .ZEXT && (inst(i).flags & F_EXACT) != 0 && !kb_is_negative(in_known) kb_make_non_negative(*in_known);
            known.* = kb_zext_or_trunc(in_known, bw);
            computed = true;
        case .SEXT;
            src_bw := scalar_bits(op(i, 0));
            in_dem := ap_trunc(demanded, src_bw);
            if ap_active_bits(demanded) > src_bw ap_set_bit(*in_dem, src_bw - 1);
            in_known := kb_new(src_bw);
            if ic_simplify_demanded_bits(i, 0, in_dem, *in_known, q, depth + 1) return i;
            if kb_is_non_negative(in_known) || ap_active_bits(demanded) <= src_bw {
                nc := create_cast(.ZEXT, op(i, 0), vty);
                ic_take_name(nc, i);
                return ic_insert_new_inst_with(nc, i);
            }
            known.* = kb_sext(in_known, bw);
            computed = true;
        case .ADD;
            if !ap_get_bit(demanded, 0) {
                for side: 0..1 {
                    z := op(i, cast(u32) side); s := op(i, cast(u32) (1 - side));
                    okz, x := pmi_cast(z, .ZEXT);
                    oks, y := pmi_cast(s, .SEXT);
                    if okz && has_one_use(z) && oks && has_one_use(s) && is_int_or_int_vector_n(vtype(x), 1) && vtype(x) == vtype(y) {
                        saved := ic.b; defer ic.b = saved;
                        irb_set_before(*ic.b, i);
                        and_not := icb_and(icb_not(x), y);
                        return icb_sext(and_not, vty);
                    }
                }
                oks0, x := pmi_cast(op(i, 0), .SEXT);
                oks1, y := pmi_cast(op(i, 1), .SEXT);
                if oks0 && oks1 && is_int_or_int_vector_n(vtype(x), 1) && vtype(x) == vtype(y) && (has_one_use(op(i, 0)) || has_one_use(op(i, 1))) {
                    saved := ic.b; defer ic.b = saved;
                    irb_set_before(*ic.b, i);
                    orv := icb_or(x, y);
                    return icb_sext(orv, vty);
                }
            }
            nlz := ap_clz(demanded);
            dfo := ap_low_bits_set(bw, bw - nlz);
            if ic_shrink_demanded_constant(i, 1, dfo) || ic_simplify_demanded_bits(i, 1, dfo, *rk, q, depth + 1) return disable_wrap(i, nlz);
            ntz := ap_cto(ap_and(ap_not(demanded), rk.zero));
            dfl := ap_copy(dfo); ap_clear_low_bits(*dfl, ntz);
            if ic_shrink_demanded_constant(i, 0, dfl) || ic_simplify_demanded_bits(i, 0, dfl, *lk, q, depth + 1) return disable_wrap(i, nlz);
            ntzl := ap_cto(ap_and(ap_not(demanded), lk.zero));
            dfr := ap_copy(dfo); ap_clear_low_bits(*dfr, ntzl);
            if ic_shrink_demanded_constant(i, 1, dfr) return disable_wrap(i, nlz);
            if ap_is_subset_of(dfo, rk.zero) return op(i, 0);
            if ap_is_subset_of(dfo, lk.zero) return op(i, 1);
            {
                okc, c := pm_apint(op(i, 1));
                if okc && ap_active_bits(demanded) > 0 && ap_eq(c, ap_one_bit_set(c.bits, ap_active_bits(demanded) - 1)) {
                    saved := ic.b; defer ic.b = saved;
                    irb_set_before(*ic.b, i);
                    return icb_xor(op(i, 0), const_int_ap(vty, c));
                }
            }
            known.* = kb_add(lk, rk, has_nsw(i), has_nuw(i));
            computed = true;
        case .SUB;
            nlz := ap_clz(demanded);
            dfo := ap_low_bits_set(bw, bw - nlz);
            if ic_shrink_demanded_constant(i, 1, dfo) || ic_simplify_demanded_bits(i, 1, dfo, *rk, q, depth + 1) return disable_wrap(i, nlz);
            ntz := ap_cto(ap_and(ap_not(demanded), rk.zero));
            dfl := ap_copy(dfo); ap_clear_low_bits(*dfl, ntz);
            if ic_shrink_demanded_constant(i, 0, dfl) || ic_simplify_demanded_bits(i, 0, dfl, *lk, q, depth + 1) return disable_wrap(i, nlz);
            if ap_is_subset_of(dfo, rk.zero) return op(i, 0);
            if ap_is_one(dfo) && ap_is_subset_of(dfo, lk.zero) return op(i, 1);
            {
                okm, lhsc := pm_low_bit_mask_ap(op(i, 0));
                if okm && ap_is_subset_of(dfo, lhsc) {
                    saved := ic.b; defer ic.b = saved;
                    irb_set_before(*ic.b, i);
                    return icb_not(op(i, 1));
                }
            }
            known.* = kb_sub(lk, rk, has_nsw(i), has_nuw(i));
            computed = true;
        case .MUL;
            {
                nlz := ap_clz(demanded);
                dfo := ap_low_bits_set(bw, bw - nlz);
                if ic_shrink_demanded_constant(i, 0, dfo) || ic_simplify_demanded_bits(i, 0, dfo, *lk, q, depth + 1) ||
                   ic_shrink_demanded_constant(i, 1, dfo) || ic_simplify_demanded_bits(i, 1, dfo, *rk, q, depth + 1) {
                    disable_wrap(i, nlz);
                    return i;
                }
            }
            if ap_is_power_of_2(demanded) {
                ctz := ap_ctz(demanded);
                okc, c := pm_apint(op(i, 1));
                if okc && ap_ctz(c) == ctz {
                    shl := create_binop(.SHL, op(i, 0), const_int_of(vty, ctz));
                    return ic_insert_new_inst_with(shl, i);
                }
            }
            if op(i, 0) == op(i, 1) && ap_ult_u64(demanded, 4) {
                and1 := create_binop(.AND, op(i, 0), const_int_of(vty, 1));
                return ic_insert_new_inst_with(and1, i);
            }
            known.* = known_bits(i, q, depth);
            computed = true;
        case .SHL;
            oksa, sa := pm_apint(op(i, 1));
            if oksa {
                op0 := op(i, 0);
                if is_inst(op0) && is_shr_op(inst_op(op0)) {
                    oks, shramt := pm_apint(op(op0, 1));
                    if oks {
                        rv := ic_simplify_shr_shl_demanded_bits(op0, shramt, i, sa, demanded, known);
                        if rv != NONE return rv;
                    }
                }
                if ic_is_part_of_rotate(i) { known.* = known_bits(i, q, depth); computed = true; }
                else {
                    shift_amt := ap_limited(sa, bw - 1);
                    if ap_ctz(demanded) >= shift_amt {
                        if has_nsw(i) {
                            num_hi := bw - ap_ctz(demanded);
                            sb := ic_num_sign_bits(op(i, 0), q.cxt, depth + 1);
                            if sb > shift_amt && sb - shift_amt >= num_hi return op(i, 0);
                        }
                        okl, c, x := pm_binop(op(i, 0), .LSHR);
                        if okl && pm_imm_constant(c) {
                            lsc := const_int_of(vty, shift_amt);
                            newc := cfo_binary_op_operands(.SHL, c, lsc);
                            if cfo_binary_op_operands(.LSHR, newc, lsc) == c {
                                lshr := create_binop(.LSHR, newc, x);
                                return ic_insert_new_inst_with(lshr, i);
                            }
                        }
                    }
                    dmi := ap_lshr(demanded, cast(u32) shift_amt);
                    if has_nsw(i) ap_set_high_bits(*dmi, cast(u32) shift_amt + 1);
                    else if has_nuw(i) ap_set_high_bits(*dmi, cast(u32) shift_amt);
                    if ic_simplify_demanded_bits(i, 0, dmi, known, q, depth + 1) return i;
                    known.* = kb_shl(known.*, kb_from_const(ap_from_u64(bw, shift_amt)), has_nuw(i), has_nsw(i));
                    computed = true;
                }
            } else {
                ctlz := ap_clz(demanded);
                if ctlz != 0 {
                    dfo := ap_low_bits_set(bw, bw - ctlz);
                    if ic_simplify_demanded_bits(i, 0, dfo, known, q, depth + 1) { drop_poison_generating_flags(i); return i; }
                }
                known.* = known_bits(i, q, depth);
                computed = true;
            }
        case .LSHR;
            oksa, sa := pm_apint(op(i, 1));
            if oksa {
                shift_amt := ap_limited(sa, bw - 1);
                if ic_is_part_of_rotate(i) { known.* = known_bits(i, q, depth); computed = true; }
                else {
                    if ap_clz(demanded) >= shift_amt {
                        num_hi := bw - ap_ctz(demanded);
                        sb := ic_num_sign_bits(op(i, 0), q.cxt, depth + 1);
                        if sb >= num_hi return op(i, 0);
                        oks, c, x := pm_binop(op(i, 0), .SHL);
                        if oks && pm_imm_constant(c) {
                            rsc := const_int_of(vty, shift_amt);
                            newc := cfo_binary_op_operands(.LSHR, c, rsc);
                            if cfo_binary_op_operands(.SHL, newc, rsc) == c {
                                shl := create_binop(.SHL, newc, x);
                                return ic_insert_new_inst_with(shl, i);
                            }
                        }
                        okm, mx, fv := pm_binop(op(i, 0), .MUL);
                        okf, factor := pm_apint(fv);
                        if okm && has_one_use(op(i, 0)) && okf && ap_ctz(factor) >= shift_amt {
                            mul := create_binop(.MUL, mx, const_int_ap(vtype(mx), ap_lshr(factor, cast(u32) shift_amt)));
                            return ic_insert_new_inst_with(mul, i);
                        }
                    }
                    dmi := ap_shl(demanded, cast(u32) shift_amt);
                    if ic_simplify_demanded_bits(i, 0, dmi, known, q, depth + 1) { drop_poison_generating_flags(i); return i; }
                    known.* = kb_lshr_const(known.*, cast(u32) shift_amt);
                    if shift_amt != 0 { known.zero = ap_copy(known.zero); ap_set_high_bits(*known.zero, cast(u32) shift_amt); }
                    computed = true;
                }
            } else {
                rv := ic_simplify_shift_selecting_packed_element(i, demanded, depth);
                if rv != NONE return rv;
                known.* = known_bits(i, q, depth);
                computed = true;
            }
        case .ASHR;
            sb := ic_num_sign_bits(op(i, 0), q.cxt, depth + 1);
            num_hi := bw - ap_ctz(demanded);
            if sb >= num_hi return op(i, 0);
            if ap_is_one(demanded) {
                nv := create_binop(.LSHR, op(i, 0), op(i, 1));
                set_name(nv, vname(i));
                return ic_insert_new_inst_with(nv, i);
            }
            oksa, sa := pm_apint(op(i, 1));
            if oksa {
                shift_amt := cast(u32) ap_limited(sa, bw - 1);
                dmi := ap_shl(demanded, shift_amt);
                shifted_in := ap_clz(demanded) < shift_amt;
                if shifted_in ap_set_sign_bit(*dmi);
                if ic_simplify_demanded_bits(i, 0, dmi, known, q, depth + 1) { drop_poison_generating_flags(i); return i; }
                if ap_get_bit(known.zero, bw - 1) || !shifted_in {
                    lshr := create_binop(.LSHR, op(i, 0), op(i, 1));
                    set_exact(lshr, is_exact(i));
                    ic_take_name(lshr, i);
                    return ic_insert_new_inst_with(lshr, i);
                }
                known.* = kb_ashr(known.*, kb_from_const(ap_from_u64(bw, shift_amt)), shift_amt != 0, is_exact(i));
            } else known.* = known_bits(i, q, depth);
            computed = true;
        case .UDIV;
            oksa, sa := pm_apint(op(i, 1));
            if oksa {
                rtz := ap_ctz(sa);
                dmi := ap_high_bits_set(bw, bw - rtz);
                if ic_simplify_demanded_bits(i, 0, dmi, *lk, q, depth + 1) { drop_poison_generating_flags(i); return i; }
                known.* = kb_udiv(lk, kb_from_const(sa), is_exact(i));
            } else known.* = known_bits(i, q, depth);
            computed = true;
        case .SREM;
            okr, rem := pm_apint(op(i, 1));
            if okr && ap_is_power_of_2(rem) {
                if ap_ult(demanded, rem) return op(i, 0);
                low := ap_sub_u64(rem, 1);
                mask2 := ap_or(low, ap_signed_min(bw));
                if ic_simplify_demanded_bits(i, 0, mask2, *lk, q, depth + 1) return i;
                known.* = kb_srem(lk, kb_from_const(rem));
            } else known.* = known_bits(i, q, depth);
            computed = true;
        case .CALL;
            kcomputed := false;
            id := call_iid(i);
            if id == IID_ABS {
                if ap_eq_u64(demanded, 1) return op(i, 0);
            } else if id == IID_CTPOP {
                okn, x := pm_not(op(i, 0));
                if ap_eq_u64(demanded, 1) && scalar_bits(i) % 2 == 0 && okn
                    return ic_insert_new_inst_with(create_intrinsic_call(IID_CTPOP, .[vty], .[x]), i);
            } else if id == IID_BSWAP {
                nlz := (ap_clz(demanded) / 8) * 8;
                ntz := (ap_ctz(demanded) / 8) * 8;
                if bw - nlz - ntz == 8 {
                    nv: Value_Id;
                    if nlz > ntz nv = create_binop(.LSHR, op(i, 0), const_int_of(vty, nlz - ntz));
                    else nv = create_binop(.SHL, op(i, 0), const_int_of(vty, ntz - nlz));
                    ic_take_name(nv, i);
                    return ic_insert_new_inst_with(nv, i);
                }
            } else if id == IID_PTRMASK {
                fatal("instcombine: SimplifyDemandedBits of llvm.ptrmask is not supported yet");
            } else if id == IID_FSHL || id == IID_FSHR {
                oksa, sa := pm_apint(op(i, 2));
                if oksa {
                    shift_amt := ap_urem_u64(sa, bw);
                    if id == IID_FSHR shift_amt = bw - shift_amt;
                    dml := ap_lshr(demanded, cast(u32) shift_amt);
                    dmr := ap_shl(demanded, cast(u32)(bw - shift_amt));
                    if op(i, 0) != op(i, 1) {
                        if ic_simplify_demanded_bits(i, 0, dml, *lk, q, depth + 1) || ic_simplify_demanded_bits(i, 1, dmr, *rk, q, depth + 1) {
                            drop_poison_generating_annotations(i);
                            return i;
                        }
                    } else {
                        lk = ic_known_bits(op(i, 0), i, depth + 1);
                        if ap_is_subset_of(dml, ap_or(lk.zero, lk.one)) && !pm_specific_int_ap(op(i, 0), lk.one) {
                            ic_replace_operand(i, 0, const_integer_value(vty, lk.one));
                            return i;
                        }
                        rk = ic_known_bits(op(i, 1), i, depth + 1);
                        if ap_is_subset_of(dmr, ap_or(rk.zero, rk.one)) && !pm_specific_int_ap(op(i, 1), rk.one) {
                            ic_replace_operand(i, 1, const_integer_value(vty, rk.one));
                            return i;
                        }
                    }
                    lk = kb_shl_const(lk, cast(u32) shift_amt);
                    rk = kb_lshr_const(rk, cast(u32)(bw - shift_amt));
                    known.* = kb_union(lk, rk);
                    kcomputed = true;
                }
            } else if id == IID_UMAX {
                okc, c := pm_apint(op(i, 1));
                if okc && ap_ctz(demanded) >= ap_active_bits(c) return op(i, 0);
            } else if id == IID_UMIN {
                okc, c := pm_apint(op(i, 1));
                if okc && ap_ctz(demanded) >= c.bits - ap_clo(c) return op(i, 0);
            }
            if !kcomputed known.* = known_bits(i, q, depth);
            computed = true;
        case;
            known.* = known_bits(i, q, depth);
            computed = true;
    }
    if is_ptr_type(vty) {
        al := pointer_alignment(i);
        known.zero = ap_copy(known.zero);
        ap_set_low_bits(*known.zero, log2_u64(al));
    }
    if !is_ptr_type(vty) && ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(vty, known.one);
    return NONE;
}

// SimplifyMultipleUseDemandedBits
ic_simplify_multiple_use_demanded_bits :: (i: Value_Id, demanded: APInt, known: *Known_Bits, q: Simplify_Query, depth: u32) -> Value_Id {
    bw := demanded.bits;
    ity := vtype(i);
    o := inst_op(i);
    if o == .AND || o == .OR || o == .XOR {
        rk := known_bits(op(i, 1), q, depth + 1);
        lk := known_bits(op(i, 0), q, depth + 1);
        known.* = known_bits_and_xor_or(i, dem_all(ity), lk, rk, q, depth);
        known_bits_from_context(i, known, q, depth);
        if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(ity, known.one);
        if o == .AND {
            if ap_is_subset_of(demanded, ap_or(lk.zero, rk.one)) return op(i, 0);
            if ap_is_subset_of(demanded, ap_or(rk.zero, lk.one)) return op(i, 1);
        } else if o == .OR {
            if ap_is_subset_of(demanded, ap_or(lk.one, rk.zero)) return op(i, 0);
            if ap_is_subset_of(demanded, ap_or(rk.one, lk.zero)) return op(i, 1);
        } else {
            if ap_is_subset_of(demanded, rk.zero) return op(i, 0);
            if ap_is_subset_of(demanded, lk.zero) return op(i, 1);
        }
        return NONE;
    }
    if o == .ADD {
        nlz := ap_clz(demanded);
        dfo := ap_low_bits_set(bw, bw - nlz);
        rk := known_bits(op(i, 1), q, depth + 1);
        if ap_is_subset_of(dfo, rk.zero) return op(i, 0);
        lk := known_bits(op(i, 0), q, depth + 1);
        if ap_is_subset_of(dfo, lk.zero) return op(i, 1);
        known.* = kb_add(lk, rk, has_nsw(i), has_nuw(i));
        known_bits_from_context(i, known, q, depth);
        return NONE;
    }
    if o == .SUB {
        nlz := ap_clz(demanded);
        dfo := ap_low_bits_set(bw, bw - nlz);
        rk := known_bits(op(i, 1), q, depth + 1);
        if ap_is_subset_of(dfo, rk.zero) return op(i, 0);
        lk := known_bits(op(i, 0), q, depth + 1);
        known.* = kb_sub(lk, rk, has_nsw(i), has_nuw(i));
        known_bits_from_context(i, known, q, depth);
        return NONE;
    }
    if o == .ASHR {
        known.* = known_bits(i, q, depth);
        if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(ity, known.one);
        oks, x, lc := pm_binop(op(i, 0), .SHL);
        if oks {
            okl, shl_c := pm_apint(lc);
            okr, shr_c := pm_apint(op(i, 1));
            // ShiftLC == ShiftRC compares APInt pointers: the same uniqued constant
            if okl && okr && ap_eq(shl_c, shr_c) && ap_ult_u64(shl_c, bw) &&
               ap_is_subset_of(demanded, ap_low_bits_set(bw, bw - cast(u32) ap_zext_value(shr_c))) return x;
        }
        return NONE;
    }
    known.* = known_bits(i, q, depth);
    if ap_is_subset_of(demanded, ap_or(known.zero, known.one)) return const_integer_value(ity, known.one);
    return NONE;
}

// simplifyShrShlDemandedBits
ic_simplify_shr_shl_demanded_bits :: (shr: Value_Id, shr_op1: APInt, shl: Value_Id, shl_op1: APInt, demanded: APInt, known: *Known_Bits) -> Value_Id {
    if ap_is_zero(shl_op1) || ap_is_zero(shr_op1) return NONE;
    varx := op(shr, 0);
    ty := vtype(varx);
    bw := scalar_bits(varx);
    if ap_uge_u64(shl_op1, bw) || ap_uge_u64(shr_op1, bw) return NONE;
    shl_amt := cast(u32) ap_zext_value(shl_op1);
    shr_amt := cast(u32) ap_zext_value(shr_op1);
    known.one = ap_zero(bw);
    known.zero = ap_copy(known.zero);
    ap_set_low_bits(*known.zero, shl_amt - 1);
    known.zero = ap_and(known.zero, demanded);
    is_lshr := inst_op(shr) == .LSHR;
    bm1 := ap_all_ones(bw);
    bm2 := ap_all_ones(bw);
    bm1 = ap_shl(ifx is_lshr then ap_lshr(bm1, shr_amt) else ap_ashr(bm1, shr_amt), shl_amt);
    if shr_amt <= shl_amt bm2 = ap_shl(bm2, shl_amt - shr_amt);
    else bm2 = ifx is_lshr then ap_lshr(bm2, shr_amt - shl_amt) else ap_ashr(bm2, shr_amt - shl_amt);
    if ap_eq(ap_and(bm1, demanded), ap_and(bm2, demanded)) {
        if shr_amt == shl_amt return varx;
        if !has_one_use(shr) return NONE;
        nw: Value_Id;
        if shr_amt < shl_amt {
            nw = create_binop(.SHL, varx, const_int_of(ty, shl_amt - shr_amt));
            set_nsw(nw, has_nsw(shl)); set_nuw(nw, has_nuw(shl));
        } else {
            nw = create_binop(ifx is_lshr then Opcode.LSHR else .ASHR, varx, const_int_of(ty, shr_amt - shl_amt));
            if is_exact(shr) set_exact(nw);
        }
        return ic_insert_new_inst_with(nw, shl);
    }
    return NONE;
}

// simplifyShiftSelectingPackedElement
ic_simplify_shift_selecting_packed_element :: (i: Value_Id, demanded: APInt, depth: u32) -> Value_Id {
    o0 := op(i, 0);
    if !has_one_use(o0) return NONE;
    okd, a, b := pm_disjoint_or(o0);
    if !okd return NONE;
    upper, lower: Value_Id = NONE;
    shl_amt: u64;
    for side: 0..1 {
        s := ifx side == 0 then a else b;
        other := ifx side == 0 then b else a;
        oks, u, amt := pm_binop(s, .SHL);
        okc, c := pm_constant_int_u64(amt);
        if oks && has_one_use(s) && okc { upper = u; lower = other; shl_amt = c; break; }
    }
    if upper == NONE return NONE;
    if shl_amt == 0 || (shl_amt & (shl_amt - 1)) != 0 return NONE;
    dbw := cast(u64) ap_active_bits(demanded);
    if dbw > shl_amt return NONE;
    if cast(u64) scalar_bits(upper) < shl_amt + dbw return NONE;
    klow := ic_known_bits(lower, i, depth);
    if ap_active_bits(kb_max_value(klow)) > shl_amt return NONE;
    shr_amt := op(i, 1);
    kshr := ic_known_bits(shr_amt, i, depth);
    if !ap_eq_u64(ap_not(kshr.zero), shl_amt) return NONE;
    saved := ic.b; defer ic.b = saved;
    irb_set_before(*ic.b, i);
    z := icb_cmp(ICMP_EQ, shr_amt, const_null_value(vtype(shr_amt)), tprint("%.z", vname(shr_amt)));
    sel := icb_select(z, lower, upper);
    if is_inst(sel) ic_set_unknown_profile_if_profiled(sel);
    ic_take_name(sel, i);
    return sel;
}
