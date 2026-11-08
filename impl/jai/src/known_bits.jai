// computeKnownBits: a partial port of llvm/lib/Analysis/ValueTracking.cpp (computeKnownBits,
// computeKnownBitsFromOperator) and llvm/lib/Support/KnownBits.cpp (shl, lshr, ashr).
//
// PARTIAL (see NOTES.md): constants, arguments with `range`, and/or/xor (without the and(x,-x)-style idioms of
// getKnownBitsFromAndXorOr), add/sub (computeKnownBitsAddSub), shl/lshr/ashr, trunc/zext/sext, select (without
// adjustKnownBitsForSelectArm), phi (recurrences and incoming values), load !range, call return `range`. Everything else (mul, div, intrinsics,
// assumptions, isKnownNonZero) returns "unknown", which is always correct but can be less precise than LLVM.
// The full port belongs with InstSimplify/InstCombine; replace this file then.

KB_MAX_DEPTH :: 6;   // MaxAnalysisRecursionDepth

kb_set_all_zero :: (k: *Known_Bits) { k.zero = ap_all_ones(kb_bits(k.*)); k.one = ap_zero(kb_bits(k.*)); }
kb_set_all_conflict :: (k: *Known_Bits) { k.zero = ap_all_ones(kb_bits(k.*)); k.one = ap_all_ones(kb_bits(k.*)); }

// ConstantRange(Lower, Upper): unsigned min/max (llvm/lib/IR/ConstantRange.cpp)
cr_is_full :: (lo: APInt, hi: APInt) -> bool { return ap_eq(lo, hi) && ap_is_all_ones(lo); }
cr_is_empty :: (lo: APInt, hi: APInt) -> bool { return ap_eq(lo, hi) && ap_is_zero(lo); }
cr_umax :: (lo: APInt, hi: APInt) -> APInt {
    if cr_is_full(lo, hi) || ap_ugt(lo, hi) return ap_all_ones(lo.bits);
    return ap_sub(hi, ap_from_u64(hi.bits, 1));
}
cr_umin :: (lo: APInt, hi: APInt) -> APInt {
    if cr_is_full(lo, hi) || (ap_ugt(lo, hi) && !ap_is_zero(hi)) return ap_zero(lo.bits);
    return lo;
}
// ConstantRange::toKnownBits
kb_from_range :: (bits: u32, lo: APInt, hi: APInt) -> Known_Bits {
    if cr_is_empty(lo, hi) return kb_new(bits);
    mn := cr_umin(lo, hi); mx := cr_umax(lo, hi);
    k := kb_from_const(mn);
    d := ap_xor(mn, mx);
    if !ap_is_zero(d) {
        msb := bits - 1 - ap_clz(d);
        low := ap_low_bits_set(bits, msb + 1);
        k.zero = ap_and(k.zero, ap_not(low));
        k.one = ap_and(k.one, ap_not(low));
    }
    return k;
}

kb_shift_amounts :: (rhs: Known_Bits, bits: u32, sh_amt_non_zero: bool) -> (min: u32, max_value: APInt) {
    mn := cast(u32) ap_limited(kb_min_value(rhs), bits);
    if mn == 0 && sh_amt_non_zero mn = 1;
    return mn, kb_max_value(rhs);
}
kb_max_shift_amount :: (max_value: APInt, bits: u32) -> u32 {
    if (bits & (bits - 1)) == 0 {
        lg: u32 = 0; while ((cast(u32) 1) << lg) < bits lg += 1;
        n := min(lg, max_value.bits);
        return cast(u32)(max_value.w[0] & (((cast(u64) 1) << cast(u64) n) - 1));
    }
    return cast(u32) ap_limited(max_value, bits - 1);
}
kb_amount_possible :: (rhs: Known_Bits, s: u32) -> bool {
    zm := cast(u32)(ap_zext_or_trunc(rhs.zero, 32).w[0]);
    om := cast(u32)(ap_zext_or_trunc(rhs.one, 32).w[0]);
    return (zm & s) == 0 && (om | s) == s;
}

// KnownBits::shl
kb_shl :: (lhs: Known_Bits, rhs: Known_Bits, nuw: bool, nsw: bool, sh_amt_non_zero: bool) -> Known_Bits {
    bits := kb_bits(lhs);
    by_const :: (lhs: Known_Bits, s: u32, nuw: bool, nsw: bool) -> Known_Bits {
        bits := kb_bits(lhs);
        k: Known_Bits;
        out_zero := s >= bits || s > ap_clz(lhs.zero);   // APInt::ushl_ov overflow
        out_one := s >= bits || s > ap_clz(lhs.one);
        k.zero = ap_shl(lhs.zero, s);
        ap_set_bits(*k.zero, 0, min(s, bits));
        k.one = ap_shl(lhs.one, s);
        if nsw {
            if nuw && s != 0 out_zero = true;
            if out_zero kb_make_non_negative(*k);
            else if out_one kb_make_negative(*k);
        }
        return k;
    }
    known := kb_new(bits);
    mn, maxv := kb_shift_amounts(rhs, bits, sh_amt_non_zero);
    if kb_is_unknown(lhs) {
        ap_set_bits(*known.zero, 0, min(mn, bits));
        if nuw && nsw && mn != 0 kb_make_non_negative(*known);
        return known;
    }
    mx := kb_max_shift_amount(maxv, bits);
    if nuw && nsw mx = min(mx, kb_count_max_leading_zeros(lhs) - 1);
    if nuw mx = min(mx, kb_count_max_leading_zeros(lhs));
    if nsw mx = min(mx, max(kb_count_max_leading_zeros(lhs), ap_clo(ap_not(lhs.zero))) - 1);
    if mn == 0 && mx == bits - 1 && (bits & (bits - 1)) == 0 {
        ap_set_bits(*known.zero, 0, kb_count_min_trailing_zeros(lhs));
        if ap_is_all_ones(lhs.one) ap_set_sign_bit(*known.one);
        if nsw {
            if kb_is_non_negative(lhs) kb_make_non_negative(*known);
            if kb_is_negative(lhs) kb_make_negative(*known);
        }
        return known;
    }
    kb_set_all_conflict(*known);
    s := mn;
    while s <= mx && s < 0x8000_0000 {
        if kb_amount_possible(rhs, s) {
            known = kb_intersect(known, by_const(lhs, s, nuw, nsw));
            if kb_is_unknown(known) break;
        }
        s += 1;
    }
    if kb_has_conflict(known) kb_set_all_zero(*known);
    return known;
}

kb_shr :: (lhs: Known_Bits, rhs: Known_Bits, sh_amt_non_zero: bool, exact: bool, arith: bool) -> Known_Bits {
    bits := kb_bits(lhs);
    known := kb_new(bits);
    mn, maxv := kb_shift_amounts(rhs, bits, sh_amt_non_zero);
    if kb_is_unknown(lhs) {
        if !arith { ap_set_bits(*known.zero, bits - min(mn, bits), bits); return known; }
        if mn == bits kb_set_all_zero(*known);
        return known;
    }
    mx := kb_max_shift_amount(maxv, bits);
    if exact {
        first_one := kb_count_max_trailing_zeros(lhs);
        if first_one < mn { kb_set_all_zero(*known); return known; }
        mx = min(mx, first_one);
    }
    kb_set_all_conflict(*known);
    s := mn;
    while s <= mx && s < 0x8000_0000 {
        if kb_amount_possible(rhs, s) {
            k: Known_Bits;
            if arith { k.zero = ap_ashr(lhs.zero, s); k.one = ap_ashr(lhs.one, s); }
            else {
                k.zero = ap_lshr(lhs.zero, s); k.one = ap_lshr(lhs.one, s);
                ap_set_bits(*k.zero, bits - min(s, bits), bits);
            }
            known = kb_intersect(known, k);
            if kb_is_unknown(known) break;
        }
        s += 1;
    }
    if kb_has_conflict(known) kb_set_all_zero(*known);
    return known;
}

// Integer bit width of a value's scalar type (pointers: 64 on x86-64)
kb_scalar_bits :: (t: Type_Id) -> u32 {
    st := scalar_type(t);
    if type_kind(st) == .INT return type_int_width(st);
    if type_kind(st) == .PTR return cast(u32) dl_type_size_bits(st);
    return 0;
}

compute_known_bits :: (v: Value_Id, depth: u32 = 0) -> Known_Bits {
    bits := kb_scalar_bits(vtype(v));
    k := vkind(v);
    if k == .C_INT return kb_from_const(ap_from_words(bits, const_int_value(v)));
    if k == .C_NULL || k == .C_ZERO { r := kb_new(bits); kb_set_all_zero(*r); return r; }
    if k == .C_DATA && type_kind(scalar_type(vtype(v))) == .INT {
        r := kb_new(bits); kb_set_all_conflict(*r);
        n := const_data_count(v);
        for e: 0..cast(s64)n-1 {
            elt := ap_from_u64(bits, const_data_elt(v, cast(u64) e));
            r.zero = ap_and(r.zero, ap_not(elt));
            r.one = ap_and(r.one, elt);
        }
        if kb_has_conflict(r) return kb_new(bits);
        return r;
    }
    if k == .C_VECTOR {
        r := kb_new(bits); kb_set_all_conflict(*r);
        n := nops(v);
        for e: 0..n-1 {
            c := op(v, e);
            if vkind(c) == .C_POISON continue;
            if vkind(c) != .C_INT return kb_new(bits);
            elt := ap_from_words(bits, const_int_value(c));
            r.zero = ap_and(r.zero, ap_not(elt));
            r.one = ap_and(r.one, elt);
        }
        if kb_has_conflict(r) return kb_new(bits);
        return r;
    }
    known := kb_new(bits);
    if k == .C_UNDEF || k == .C_POISON return known;
    if k == .ARGUMENT {
        f := arg_parent(v);
        a := attr_set_find(attr_list_param(glob(f).attrs, arg_numbers[ir.v_aux[v]]), .Range);
        if a known = kb_from_range(bits, ap_from_words(bits, a.lo), ap_from_words(bits, a.hi));
    }
    if depth == KB_MAX_DEPTH return known;
    if k == .INST known = kb_from_operator(v, bits, depth);
    return known;
}

kb_from_operator :: (i: Value_Id, bits: u32, depth: u32) -> Known_Bits {
    r := inst(i);
    known := kb_new(bits);
    if r.op == {
        case .LOAD;
            found, rk := table_find(*ir.md_kind_map, "range");
            if found {
                m := get_metadata(i, rk);
                if m != NONE known = kb_from_range_md(m, bits);
            }
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            rhs := compute_known_bits(op(i, 1), depth + 1);
            lhs := compute_known_bits(op(i, 0), depth + 1);
            if r.op == .AND known = kb_and(lhs, rhs);
            else if r.op == .OR known = kb_or(lhs, rhs);
            else known = kb_xor(lhs, rhs);
        case .ADD; #through;
        case .SUB;
            // computeKnownBitsAddSub
            nsw := (r.flags & F_NSW) != 0; nuw := (r.flags & F_NUW) != 0;
            k2 := compute_known_bits(op(i, 1), depth + 1);
            k1 := compute_known_bits(op(i, 0), depth + 1);
            known = kb_compute_for_add_sub(r.op == .ADD, nsw, nuw, k1, k2);
        case .SHL;
            nuw := (r.flags & F_NUW) != 0; nsw := (r.flags & F_NSW) != 0;
            k2 := compute_known_bits(op(i, 0), depth + 1);
            amt := compute_known_bits(op(i, 1), depth + 1);
            known = kb_shl(k2, amt, nuw, nsw, kb_is_non_zero(amt));
            c := op(i, 0);
            if vkind(c) == .C_INT ap_set_bits(*known.zero, 0, ap_ctz(ap_from_words(bits, const_int_value(c))));
        case .LSHR; #through;
        case .ASHR;
            exact := (r.flags & F_EXACT) != 0;
            k2 := compute_known_bits(op(i, 0), depth + 1);
            amt := compute_known_bits(op(i, 1), depth + 1);
            known = kb_shr(k2, amt, kb_is_non_zero(amt), exact, r.op == .ASHR);
            c := op(i, 0);
            if vkind(c) == .C_INT {
                cv := ap_from_words(bits, const_int_value(c));
                if r.op == .LSHR ap_set_bits(*known.zero, bits - ap_clz(cv), bits);
                else {
                    // AShr: leading sign bits of a constant never decrease
                    n := ap_num_sign_bits(cv);
                    if ap_is_negative(cv) ap_set_bits(*known.one, bits - n, bits);
                    else ap_set_bits(*known.zero, bits - n, bits);
                }
            }
        case .TRUNC; #through;
        case .ZEXT; #through;
        case .PTRTOINT; #through;
        case .INTTOPTR;
            src_bits := kb_scalar_bits(vtype(op(i, 0)));
            k := compute_known_bits(op(i, 0), depth + 1);
            if r.op == .ZEXT && (r.flags & F_EXACT) != 0 && !kb_is_negative(k) kb_make_non_negative(*k);
            known = kb_zext_or_trunc(k, bits);
        case .SEXT;
            k := compute_known_bits(op(i, 0), depth + 1);
            known = kb_sext(k, bits);
        case .BITCAST;
            st := vtype(op(i, 0));
            if (type_kind(st) == .INT || type_kind(st) == .PTR) && !is_vector_type(vtype(i))
                known = compute_known_bits(op(i, 0), depth + 1);
        case .SELECT;
            a := compute_known_bits(op(i, 1), depth + 1);
            b := compute_known_bits(op(i, 2), depth + 1);
            known = kb_intersect(a, b);
        case .PHI; known = kb_from_phi(i, bits, depth);
        case .CALL; #through;
        case .INVOKE;
            ra := attr_set_find(attr_list_ret(r.attrs), .Range);
            f := call_called_function(i);
            if !ra && f != NONE ra = attr_set_find(attr_list_ret(glob(f).attrs), .Range);
            if ra known = kb_from_range(bits, ap_from_words(bits, ra.lo), ap_from_words(bits, ra.hi));
    }
    return known;
}

// computeKnownBitsFromRangeMetadata
kb_from_range_md :: (m: Md_Id, bits: u32) -> Known_Bits {
    known := kb_new(bits);
    kb_set_all_conflict(*known);
    n := ir.mds[m].nops / 2;
    for p: 0..cast(s64)n-1 {
        lo_md := md_op(m, cast(u32)(2 * p)); hi_md := md_op(m, cast(u32)(2 * p + 1));
        lo := ap_from_words(bits, const_int_value(ir.mds[lo_md].value));
        hi := ap_from_words(bits, const_int_value(ir.mds[hi_md].value));
        umax := cr_umax(lo, hi);
        common := ap_clz(ap_xor(umax, cr_umin(lo, hi)));
        mask := ap_high_bits_set(bits, common);
        known.one = ap_and(known.one, ap_and(umax, mask));
        known.zero = ap_and(known.zero, ap_and(ap_not(umax), mask));
    }
    return known;
}

// matchSimpleRecurrence (matchTwoInputRecurrence over BinaryOperator)
match_simple_recurrence :: (p: Value_Id) -> (ok: bool, bo: Value_Id, start: Value_Id, step: Value_Id) {
    if nops(p) != 2 return false, NONE, NONE, NONE;
    for k: 0..1 {
        o := phi_value(p, cast(u32) k);
        if !is_inst(o) || !is_binary_op(inst_op(o)) continue;
        lhs := op(o, 0); rhs := op(o, 1);
        if lhs != p && rhs != p continue;
        return true, o, phi_value(p, cast(u32)(1 - k)), ifx lhs == p then rhs else lhs;
    }
    return false, NONE, NONE, NONE;
}

// ConstantRange::makeExactICmpRegion(Pred, C).toKnownBits()
kb_from_icmp_region :: (pred: u8, c: APInt) -> Known_Bits {
    bits := c.bits;
    one := ap_from_u64(bits, 1);
    lo, hi: APInt;
    full := false; empty := false;
    if pred == {
        case 32; lo = c; hi = ap_add(c, one);                                     // eq
        case 33; lo = ap_add(c, one); hi = c;                                     // ne
        case 36; if ap_is_zero(c) empty = true; else { lo = ap_zero(bits); hi = c; }     // ult
        case 37; if ap_is_all_ones(c) full = true; else { lo = ap_zero(bits); hi = ap_add(c, one); }   // ule
        case 34; if ap_is_all_ones(c) empty = true; else { lo = ap_add(c, one); hi = ap_zero(bits); }  // ugt
        case 35; if ap_is_zero(c) full = true; else { lo = c; hi = ap_zero(bits); }      // uge
        case 40; smin := ap_signed_min(bits); if ap_eq(c, smin) empty = true; else { lo = smin; hi = c; }   // slt
        case 41; smin := ap_signed_min(bits); if ap_eq(c, ap_signed_max(bits)) full = true; else { lo = smin; hi = ap_add(c, one); }
        case 38; smin := ap_signed_min(bits); if ap_eq(c, ap_signed_max(bits)) empty = true; else { lo = ap_add(c, one); hi = smin; }
        case 39; smin := ap_signed_min(bits); if ap_eq(c, smin) full = true; else { lo = c; hi = smin; }
    }
    if empty || full return kb_new(bits);
    return kb_from_range(bits, lo, hi);
}
icmp_inverse :: (p: u8) -> u8 {
    if p == {
        case 32; return 33; case 33; return 32; case 34; return 37; case 37; return 34;
        case 35; return 36; case 36; return 35; case 38; return 41; case 41; return 38;
        case 39; return 40; case 40; return 39;
    }
    return p;
}
icmp_swapped :: (p: u8) -> u8 {
    if p == {
        case 34; return 36; case 36; return 34; case 35; return 37; case 37; return 35;
        case 38; return 40; case 40; return 38; case 39; return 41; case 41; return 39;
    }
    return p;
}

// computeKnownBitsFromOperator, case Instruction::PHI
kb_from_phi :: (p: Value_Id, bits: u32, depth: u32) -> Known_Bits {
    known := kb_new(bits);
    ok, bo, r, l := match_simple_recurrence(p);
    if ok {
        opc := inst_op(bo);
        if opc == .LSHR || opc == .ASHR || opc == .SHL || opc == .UDIV || opc == .UREM {
            if opc == .UREM || op(bo, 0) == p {
                k2 := compute_known_bits(r, depth + 1);
                if opc == .SHL ap_set_bits(*known.zero, 0, kb_count_min_trailing_zeros(k2));
                else if opc == .ASHR {
                    ap_set_bits(*known.zero, bits - kb_count_min_leading_zeros(k2), bits);
                    ap_set_bits(*known.one, bits - kb_count_min_leading_ones(k2), bits);
                } else ap_set_bits(*known.zero, bits - kb_count_min_leading_zeros(k2), bits);
            }
        } else if opc == .ADD || opc == .SUB || opc == .AND || opc == .OR || opc == .MUL {
            k2 := compute_known_bits(r, depth + 1);
            k3 := compute_known_bits(l, depth + 1);
            ap_set_bits(*known.zero, 0, min(kb_count_min_trailing_zeros(k2), kb_count_min_trailing_zeros(k3)));
            if (opc == .ADD || opc == .SUB || opc == .MUL) && (inst(bo).flags & F_NSW) != 0 {
                if opc == .ADD {
                    if kb_is_non_negative(k2) && kb_is_non_negative(k3) kb_make_non_negative(*known);
                    else if kb_is_negative(k2) && kb_is_negative(k3) kb_make_negative(*known);
                } else if opc == .SUB {
                    if op(bo, 0) == p {
                        if kb_is_non_negative(k2) && kb_is_negative(k3) kb_make_non_negative(*known);
                        else if kb_is_negative(k2) && kb_is_non_negative(k3) kb_make_negative(*known);
                    }
                } else {
                    if kb_is_non_negative(k2) && kb_is_non_negative(k3) kb_make_non_negative(*known);
                }
            }
        }
    }
    n := nops(p);
    if n == 0 return known;
    if depth < KB_MAX_DEPTH - 1 && kb_is_unknown(known) {
        cv := phi_has_constant_value(p);
        if cv != NONE && (vkind(cv) == .C_UNDEF || vkind(cv) == .C_POISON) return known;
        kb_set_all_conflict(*known);
        for k: 0..n-1 {
            // breakSelfRecursivePHI
            inc := phi_value(p, k);
            if inc == p continue;
            cxt := block_terminator(phi_block(p, k));
            cxt_phi := p;
            if is_inst(inc) && inst_op(inc) == .SELECT {
                if op(inc, 1) == p inc = op(inc, 2);
                else if op(inc, 2) == p inc = op(inc, 1);
            }
            if is_phi(inc) && nops(inc) == 2 {
                for idx: 0..1 {
                    if phi_value(inc, cast(u32) idx) == p {
                        nv := phi_value(inc, cast(u32)(1 - idx));
                        cxt_phi = inc;
                        cxt = block_terminator(phi_block(inc, cast(u32)(1 - idx)));
                        inc = nv;
                        break;
                    }
                }
            }
            if inc == p continue;
            k2 := compute_known_bits(inc, KB_MAX_DEPTH - 1);
            if !kb_is_constant(k2) && cxt != NONE && inst_op(cxt) == .CONDBR {
                c := op(cxt, 0);
                if is_inst(c) && inst_op(c) == .ICMP {
                    pred := inst(c).pred;
                    rhs: Value_Id = NONE;
                    if op(c, 0) == inc rhs = op(c, 1);
                    else if op(c, 1) == inc { rhs = op(c, 0); pred = icmp_swapped(pred); }
                    if rhs != NONE {
                        okc, rc := match_apint(rhs);
                        if okc {
                            tsucc := op(cxt, 1); fsucc := op(cxt, 2);
                            pb := inst_block(cxt_phi);
                            if (tsucc == pb) != (fsucc == pb) {
                                if fsucc == pb pred = icmp_inverse(pred);
                                u := kb_union(k2, kb_from_icmp_region(pred, rc));
                                if kb_has_conflict(u) return kb_new(bits);
                                k2 = u;
                            }
                        }
                    }
                }
            }
            known = kb_intersect(known, k2);
            if kb_is_unknown(known) break;
        }
    }
    return known;
}
