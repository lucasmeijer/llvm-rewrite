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

// ---------------------------------------------------------------- SimplifyDemandedVectorElts

IC_SIMPLIFY_DEMANDED_VECTOR_ELTS_DEPTH_LIMIT :: 10;   // -instcombine-simplify-vector-elts-depth

// canSkipDemandedEltsInInsertChain
ic_can_skip_demanded_elts_in_insert_chain :: (ie: Value_Id, vwidth: u32, depth_limit: u32) -> bool {
    if !has_one_use(ie) return false;
    u := first_user(ie);
    if !is_inst(u) || inst_op(u) != .INSERTELEMENT || op(u, 0) != ie return false;
    seen := NewArray(cast(s64) vwidth, bool,, allocator = temp);
    cur := ie;
    for k: 0..cast(s64) depth_limit - 1 {
        idx := op(cur, 2);
        if vkind(idx) != .C_INT || is_vector_type(vtype(idx)) return false;
        a := const_ap(idx);
        if !ap_ult_u64(a, cast(u64) vwidth) return false;
        index := ap_zext_value(a);
        if seen[index] return false;
        seen[index] = true;
        base := op(cur, 0);
        if pm_poison(base) return true;
        if !is_inst(base) || inst_op(base) != .INSERTELEMENT || !has_one_use(base) return false;
        cur = base;
    }
    return true;
}

// InsertElementInst::Create(Vec, Elt, Idx) (unlinked)
ic_create_insert_element :: (v: Value_Id, e: Value_Id, idx: Value_Id) -> Value_Id {
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return i;
}

// InstCombinerImpl::SimplifyDemandedVectorElts
ic_simplify_demanded_vector_elts :: (v: Value_Id, demanded_in: APInt, poison: *APInt, depth: u32 = 0, allow_multiple_users := false) -> Value_Id {
    demanded := demanded_in;
    vt := vtype(v);
    if type_kind(vt) == .SVECTOR return NONE;
    vwidth := cast(u32) type_count(vt);
    elt_mask := ap_all_ones(vwidth);
    if pm_poison(v) { poison.* = elt_mask; return NONE; }
    if ap_is_zero(demanded) { poison.* = elt_mask; return const_poison(vt); }
    poison.* = ap_zero(vwidth);
    if is_const(v) {
        if ap_is_all_ones(demanded) return NONE;
        et := type_elem(vt);
        pz := const_poison(et);
        elts := NewArray(cast(s64) vwidth, Value_Id,, allocator = temp);
        for i: 0..cast(s64) vwidth - 1 {
            if !ap_get_bit(demanded, cast(u32) i) { elts[i] = pz; ap_set_bit(poison, cast(u32) i); continue; }
            e := cf_elt(v, cast(u64) i);
            if e == NONE return NONE;
            elts[i] = e;
            if vkind(e) == .C_POISON ap_set_bit(poison, cast(u32) i);
        }
        ncv := cf_vector(vt, elts);
        return ifx ncv != v then ncv else NONE;
    }
    if depth == IC_SIMPLIFY_DEMANDED_VECTOR_ELTS_DEPTH_LIMIT return NONE;
    if !allow_multiple_users && !has_one_use(v) {
        if depth != 0 return NONE;
        demanded = elt_mask;
    }
    if !is_inst(v) return NONE;
    i := v;
    made_change := false;
    simplify_and_set_op :: (inst_: Value_Id, opnum: u32, dem: APInt, und: *APInt, depth: u32, made_change: *bool) {
        o := op(inst_, opnum);   // getArgOperand(OpNum) == getOperand(OpNum) for calls
        nv := ic_simplify_demanded_vector_elts(o, dem, und, depth + 1);
        if nv != NONE { ic_replace_operand(inst_, opnum, nv); made_change.* = true; }
    }
    poison2 := ap_zero(vwidth);
    poison3 := ap_zero(vwidth);
    for 0..0 { if inst_op(i) == {
        case .GEP;
            may_index_struct := false;
            t := inst(i).ty2;
            for k: 2..nops(i) - 1 {
                if type_kind(t) == .STRUCT { may_index_struct = true; break; }
                if type_kind(t) == .ARRAY || is_vector_type(t) t = type_elem(t);
                else break;
            }
            if may_index_struct break;
            for k: 0..nops(i) - 1 {
                o := op(i, k);
                if ifx k == 0 then pm_undef(o) else pm_poison(o) { poison.* = elt_mask; return NONE; }
                if is_vector_type(vtype(o)) {
                    pop := ap_zero(vwidth);
                    simplify_and_set_op(i, k, demanded, *pop, depth, *made_change);
                    if k == 0 poison.* = ap_or(poison.*, pop);
                }
            }
        case .INSERTELEMENT;
            if depth == 0 && ap_is_all_ones(demanded) && vwidth > IC_SIMPLIFY_DEMANDED_VECTOR_ELTS_DEPTH_LIMIT &&
               ic_can_skip_demanded_elts_in_insert_chain(i, vwidth, IC_SIMPLIFY_DEMANDED_VECTOR_ELTS_DEPTH_LIMIT) return NONE;
            idx := op(i, 2);
            if vkind(idx) != .C_INT || is_vector_type(vtype(idx)) {
                simplify_and_set_op(i, 0, demanded, *poison2, depth, *made_change);
                break;
            }
            idx_no := ap_zext_value(const_ap(idx));
            pre := ap_copy(demanded);
            if idx_no < cast(u64) vwidth ap_clear_bit(*pre, cast(u32) idx_no);
            if ap_is_zero(pre) {
                e1 := op(i, 1);
                if is_inst(e1) && inst_op(e1) == .EXTRACTELEMENT && pm_specific_int(op(e1, 1), idx_no) && vtype(op(e1, 0)) == vtype(i) return op(e1, 0);
            }
            simplify_and_set_op(i, 0, pre, poison, depth, *made_change);
            if idx_no >= cast(u64) vwidth || !ap_get_bit(demanded, cast(u32) idx_no) { wl_push(i); return op(i, 0); }
            ap_clear_bit(poison, cast(u32) idx_no);
        case .SHUFFLEVECTOR;
            op_width := cast(u32) type_count(vtype(op(i, 0)));
            mask := shuffle_mask(i);
            all_zero := true;
            for mask if it != 0 { all_zero = false; break; }
            if all_zero && ap_is_all_ones(demanded) {
                if !pm_poison(op(i, 1)) { set_op(i, 1, const_poison(vtype(op(i, 1)))); made_change = true; }
                left := ap_from_u64(op_width, 1);
                lp := ap_zero(op_width);
                simplify_and_set_op(i, 0, left, *lp, depth, *made_change);
                if ap_get_bit(lp, 0) poison.* = elt_mask; else poison.* = ap_zero(vwidth);
                break;
            }
            left := ap_zero(op_width); right := ap_zero(op_width);
            for k: 0..vwidth - 1 {
                if ap_get_bit(demanded, k) {
                    mv := mask[k];
                    if mv != 0xFFFF_FFFF {
                        if mv < op_width ap_set_bit(*left, mv); else ap_set_bit(*right, mv - op_width);
                    }
                }
            }
            lp := ap_zero(op_width);
            simplify_and_set_op(i, 0, left, *lp, depth, *made_change);
            rp := ap_zero(op_width);
            simplify_and_set_op(i, 1, right, *rp, depth, *made_change);
            mask = shuffle_mask(i);
            if vwidth == op_width {
                is_identity := true;
                for k: 0..vwidth - 1 if ap_get_bit(demanded, k) && k != mask[k] { is_identity = false; break; }
                if is_identity return op(i, 0);
            }
            new_poison := false;
            NO :: 0xFFFF_FFFF;
            lhs_idx, lhs_val_idx, rhs_idx, rhs_val_idx: u32 = NO, NO, NO, NO;
            lhs_uniform := true; rhs_uniform := true;
            for k: 0..vwidth - 1 {
                mv := mask[k];
                if mv == NO ap_set_bit(poison, k);
                else if !ap_get_bit(demanded, k) { new_poison = true; ap_set_bit(poison, k); }
                else if mv < op_width {
                    if ap_get_bit(lp, mv) { new_poison = true; ap_set_bit(poison, k); }
                    else {
                        lhs_idx = ifx lhs_idx == NO then k else op_width;
                        lhs_val_idx = ifx lhs_val_idx == NO then mv else op_width;
                        lhs_uniform = lhs_uniform && mv == k;
                    }
                } else {
                    if ap_get_bit(rp, mv - op_width) { new_poison = true; ap_set_bit(poison, k); }
                    else {
                        rhs_idx = ifx rhs_idx == NO then k else op_width;
                        rhs_val_idx = ifx rhs_val_idx == NO then mv - op_width else op_width;
                        rhs_uniform = rhs_uniform && mv - op_width == k;
                    }
                }
            }
            if op_width == cast(u32) type_count(vtype(i)) {
                o: Value_Id = NONE; val: Value_Id = NONE; idx: u32 = NO;
                if lhs_idx < op_width && rhs_uniform && vkind(op(i, 0)) == .C_VECTOR {
                    o = op(i, 1); val = op(op(i, 0), lhs_val_idx); idx = lhs_idx;
                }
                if rhs_idx < op_width && lhs_uniform && vkind(op(i, 1)) == .C_VECTOR {
                    o = op(i, 0); val = op(op(i, 1), rhs_val_idx); idx = rhs_idx;
                }
                if o != NONE && val != NONE {
                    nw := ic_create_insert_element(o, val, const_int(ir.t_i64, cast(u64) idx));
                    set_name(nw, vname(i));
                    ic_insert_new_inst_with(nw, i);
                    return nw;
                }
            }
            if new_poison {
                elts := NewArray(cast(s64) vwidth, u32,, allocator = temp);
                for k: 0..vwidth - 1 elts[k] = ifx ap_get_bit(poison.*, k) then cast(u32) NO else mask[k];
                r := inst(i);
                r.idx = cast(u32) ir.u32_pool.count; r.nidx = vwidth;
                for elts array_add(*ir.u32_pool, it);
                made_change = true;
            }
        case .SELECT;
            cond := op(i, 0);
            if is_vector_type(vtype(cond)) simplify_and_set_op(i, 0, demanded, poison, depth, *made_change);
            dl := ap_copy(demanded); dr := ap_copy(demanded);
            cond = op(i, 0);
            if vkind(cond) == .C_VECTOR {
                for k: 0..vwidth - 1 {
                    ce := cf_elt(cond, cast(u64) k);
                    if is_null_value(ce) ap_clear_bit(*dl, k);
                    else if is_one_value(ce) ap_clear_bit(*dr, k);
                }
            }
            simplify_and_set_op(i, 1, dl, *poison2, depth, *made_change);
            simplify_and_set_op(i, 2, dr, *poison3, depth, *made_change);
            poison.* = ap_and(poison2, poison3);
        case .BITCAST;
            st := vtype(op(i, 0));
            if !is_vector_type(st) break;
            in_w := cast(u32) type_count(st);
            in_dem := ap_zero(in_w);
            poison2 = ap_zero(in_w);
            ratio: u32;
            if vwidth == in_w { ratio = 1; in_dem = demanded; }
            else if vwidth % in_w == 0 {
                ratio = vwidth / in_w;
                for k: 0..vwidth - 1 if ap_get_bit(demanded, k) ap_set_bit(*in_dem, k / ratio);
            } else if in_w % vwidth == 0 {
                ratio = in_w / vwidth;
                for k: 0..in_w - 1 if ap_get_bit(demanded, k / ratio) ap_set_bit(*in_dem, k);
            } else break;
            simplify_and_set_op(i, 0, in_dem, *poison2, depth, *made_change);
            if vwidth == in_w poison.* = poison2;
            else if vwidth % in_w == 0 {
                for k: 0..vwidth - 1 if ap_get_bit(poison2, k / ratio) ap_set_bit(poison, k);
            } else {
                for k: 0..vwidth - 1 {
                    all := true;
                    for j: 0..ratio - 1 if !ap_get_bit(poison2, k * ratio + j) { all = false; break; }
                    if all ap_set_bit(poison, k);
                }
            }
        case .FPTRUNC; #through;
        case .FPEXT;
            simplify_and_set_op(i, 0, demanded, poison, depth, *made_change);
        case .CALL;
            id := call_iid(i);
            if id == NOT_INTRINSIC break;
            if id == IID_MASKED_GATHER || id == IID_MASKED_LOAD {
                dptrs := ap_all_ones(vwidth); dpass := ap_copy(demanded);
                cm := op(i, 1);
                if is_const(cm) {
                    for k: 0..vwidth - 1 {
                        ce := cf_elt(cm, cast(u64) k);
                        if ce != NONE {
                            if is_null_value(ce) ap_clear_bit(*dptrs, k);
                            else if vkind(ce) == .C_INT && ap_is_all_ones(const_ap(ce)) ap_clear_bit(*dpass, k);
                        }
                    }
                }
                if id == IID_MASKED_GATHER simplify_and_set_op(i, 0, dptrs, *poison2, depth, *made_change);
                simplify_and_set_op(i, 2, dpass, *poison3, depth, *made_change);
                poison.* = ap_and(poison2, poison3);
            } else if begins_with(intrinsic_name(id), "llvm.x86.") {
                fatal("instcombine: X86 simplifyDemandedVectorEltsIntrinsic is not supported yet");
            }
    } }
    if ic_is_binop_any(i) && !is_int_div_rem(inst_op(i)) && !is_shift_op(inst_op(i)) {
        x := op(i, 0); y := op(i, 1);
        if ap_eq_u64(demanded, 1) && !has_one_use(x) && !has_one_use(y) && has_one_use(i) {
            find_shuf_bo :: (bo: Value_Id, x: Value_Id, y: Value_Id, as_op0: bool) -> Value_Id {
                other := ifx as_op0 then y else x;
                shuf_op := ifx as_op0 then x else y;
                opc := inst_op(bo);
                u := ir.v_first_use[other];
                while u != NONE {
                    us := ir.u_user[u];
                    u = ir.u_next[u];
                    if !is_inst(us) || inst_op(us) != opc continue;
                    is_shuf :: (s: Value_Id, shuf_op: Value_Id) -> bool {
                        ok, a, _, m := pm_shuffle(s);
                        if !ok || a != shuf_op return false;
                        for m if it != 0 && it != 0xFFFF_FFFF return false;
                        return m.count > 0 && m[0] != 0xFFFF_FFFF;
                    }
                    matched: bool;
                    if is_commutative_op(opc) matched = (is_shuf(op(us, 0), shuf_op) && op(us, 1) == other) || (is_shuf(op(us, 1), shuf_op) && op(us, 0) == other);
                    else if as_op0 matched = is_shuf(op(us, 0), shuf_op) && op(us, 1) == other;
                    else matched = op(us, 0) == other && is_shuf(op(us, 1), shuf_op);
                    if matched && dt_dominates_inst(ic.dt, us, bo) return us;
                }
                return NONE;
            }
            sb := find_shuf_bo(i, x, y, true);
            if sb == NONE sb = find_shuf_bo(i, x, y, false);
            if sb != NONE {
                and_ir_flags(sb, i);
                wl_add(sb);
                return sb;
            }
        }
        simplify_and_set_op(i, 0, demanded, poison, depth, *made_change);
        simplify_and_set_op(i, 1, demanded, *poison2, depth, *made_change);
        poison.* = ap_and(poison.*, poison2);
    }
    if ap_is_all_ones(poison.*) return const_poison(vtype(i));
    return ifx made_change then i else NONE;
}
ic_is_binop_any :: (v: Value_Id) -> bool { return is_inst(v) && is_binary_operator(v); }
