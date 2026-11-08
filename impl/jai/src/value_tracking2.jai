// ValueTracking, part 2: ComputeNumSignBits, isKnownNonEqual, matchSelectPattern, isKnownNegation,
// isImpliedCondition / isImpliedByDomCondition, computeConstantRange, computeOverflowFor*, canCreateUndefOrPoison,
// impliesPoison, propagatesPoison, isGuaranteedNotToBeUndefOrPoison, programUndefinedIfUndefOrPoison,
// getUnderlyingObject. A port of llvm/lib/Analysis/ValueTracking.cpp, plus Value::stripPointerCasts* and
// stripAndAccumulateConstantOffsets (llvm/lib/IR/Value.cpp) and GEPOperator::accumulateConstantOffset
// (llvm/lib/IR/Operator.cpp).

// ---------------------------------------------------------------- ComputeNumSignBits

num_sign_bits :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> u32 { return num_sign_bits_de(v, dem_all(vtype(v)), q, depth); }
num_sign_bits_ctx :: (v: Value_Id, cxt: Value_Id, dt: *Dom_Tree, ac: *Assumption_Cache, depth: u32 = 0) -> u32 {
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = safe_cxt(v, cxt);
    return num_sign_bits(v, q, depth);
}
// ComputeMaxSignificantBits
max_significant_bits :: (v: Value_Id, q: Simplify_Query, depth: u32 = 0) -> u32 {
    return type_bits(scalar_type(vtype(v))) - num_sign_bits(v, q, depth) + 1;
}

// computeNumSignBitsVectorConstant
num_sign_bits_vector_constant :: (v: Value_Id, de: APInt, ty_bits: u32) -> u32 {
    if !is_const(v) || type_kind(vtype(v)) != .VECTOR return 0;
    mn := ty_bits;
    n := type_count(vtype(v));
    for i: 0..cast(s64) n - 1 {
        if !ap_get_bit(de, cast(u32) i) continue;
        e := cf_elt(v, cast(u64) i);
        if e == NONE || vkind(e) != .C_INT return 0;
        mn = min(mn, ap_num_sign_bits(const_ap(e)));
    }
    return mn;
}

num_sign_bits_de :: (v: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> u32 {
    r := num_sign_bits_impl(v, de, q, depth);
    assert(r > 0);
    return r;
}
num_sign_bits_impl :: (v: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> u32 {
    ty := vtype(v);
    st := scalar_type(ty);
    ty_bits := ifx is_ptr_type(st) then dl_ptr_spec(cast(u32) ir.types[st].a).bits else cast(u32) dl_type_size_bits(st);
    first_answer: u32 = 1;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return 1;
    k := vkind(v);
    if k == .INST || k == .C_EXPR {
        o0 := op(v, 0);
        opc := opr_code(v);
        while true {   // (a loop so that `break` leaves the switch, like the C++ switch's break)
        if opc == {
            case .BITCAST;
                src := o0;
                sty := vtype(src);
                if !is_int_type(scalar_type(sty)) break;
                src_bits := type_bits(scalar_type(sty));
                if (src_bits % ty_bits) != 0 break;
                if type_kind(ty) == .VECTOR {
                    t := num_sign_bits(src, q, depth + 1);
                    if t == src_bits return ty_bits;
                }
            case .SEXT;
                t := ty_bits - type_bits(scalar_type(vtype(o0)));
                return num_sign_bits_de(o0, de, q, depth + 1) + t;
            case .SDIV;
                ok, d := pm_apint(op(v, 1));
                if ok {
                    if !ap_is_strictly_positive(d) break;
                    nb := num_sign_bits_de(o0, de, q, depth + 1);
                    return min(ty_bits, nb + ap_log2(d));
                }
            case .SREM;
                t := num_sign_bits_de(o0, de, q, depth + 1);
                ok, d := pm_apint(op(v, 1));
                if ok && ap_is_strictly_positive(d) {
                    res_bits := ty_bits - ap_ceil_log2(d);
                    t = max(t, res_bits);
                }
                return t;
            case .ASHR;
                t := num_sign_bits_de(o0, de, q, depth + 1);
                ok, sh := pm_apint(op(v, 1));
                if ok {
                    if ap_uge_u64(sh, ty_bits) break;
                    t += cast(u32) ap_zext_value(sh);
                    if t > ty_bits t = ty_bits;
                }
                return t;
            case .SHL;
                ok, sh := pm_apint(op(v, 1));
                if ok {
                    if ap_uge_u64(sh, ty_bits) break;
                    t: u32;
                    okz, x := pm_cast(o0, .ZEXT);
                    if okz && ap_uge_u64(sh, ty_bits - type_bits(scalar_type(vtype(x)))) {
                        t = num_sign_bits_de(x, de, q, depth + 1);
                        t += ty_bits - type_bits(scalar_type(vtype(x)));
                    } else t = num_sign_bits_de(o0, de, q, depth + 1);
                    if ap_uge_u64(sh, t) break;
                    return t - cast(u32) ap_zext_value(sh);
                }
            case .AND; #through; case .OR; #through; case .XOR;
                t := num_sign_bits_de(o0, de, q, depth + 1);
                if t != 1 {
                    t2 := num_sign_bits_de(op(v, 1), de, q, depth + 1);
                    first_answer = min(t, t2);
                }
            case .SELECT;
                okc, x, clow, chigh := is_signed_min_max_clamp(v);
                if okc return min(ap_num_sign_bits(clow), ap_num_sign_bits(chigh));
                t := num_sign_bits_de(op(v, 1), de, q, depth + 1);
                if t == 1 break;
                t2 := num_sign_bits_de(op(v, 2), de, q, depth + 1);
                return min(t, t2);
            case .ADD;
                t := num_sign_bits(o0, q, depth + 1);
                if t == 1 break;
                c := op(v, 1);
                if is_const(c) && cf_is_all_ones(c) {
                    known := known_bits_de(o0, de, q, depth + 1);
                    z := ap_copy(known.zero); ap_set_bit(*z, 0);
                    if ap_is_all_ones(z) return ty_bits;
                    if kb_is_non_negative(known) return t;
                }
                t2 := num_sign_bits_de(op(v, 1), de, q, depth + 1);
                if t2 == 1 break;
                return min(t, t2) - 1;
            case .SUB;
                t2 := num_sign_bits_de(op(v, 1), de, q, depth + 1);
                if t2 == 1 break;
                if is_const(o0) && is_null_value(o0) {
                    known := known_bits_de(op(v, 1), de, q, depth + 1);
                    z := ap_copy(known.zero); ap_set_bit(*z, 0);
                    if ap_is_all_ones(z) return ty_bits;
                    if kb_is_non_negative(known) return t2;
                }
                t := num_sign_bits_de(o0, de, q, depth + 1);
                if t == 1 break;
                return min(t, t2) - 1;
            case .MUL;
                s0 := num_sign_bits_de(o0, de, q, depth + 1);
                if s0 == 1 break;
                s1 := num_sign_bits_de(op(v, 1), de, q, depth + 1);
                if s1 == 1 break;
                out_valid := (ty_bits - s0 + 1) + (ty_bits - s1 + 1);
                return ifx out_valid > ty_bits then cast(u32) 1 else ty_bits - out_valid + 1;
            case .PHI;
                n := nops(v);
                if n > 4 || n == 0 break;
                rq := q; rq.cc = null;
                t := ty_bits;
                for i: 0..n-1 {
                    if t == 1 return t;
                    rq.cxt = block_terminator(phi_block(v, i));
                    t = min(t, num_sign_bits_de(phi_value(v, i), de, rq, depth + 1));
                }
                return t;
            case .TRUNC;
                t := num_sign_bits(o0, q, depth + 1);
                op_bits := type_bits(scalar_type(vtype(o0)));
                if t > op_bits - ty_bits return t - (op_bits - ty_bits);
                return 1;
            case .EXTRACTELEMENT;
                return num_sign_bits(o0, q, depth + 1);
            case .SHUFFLEVECTOR;
                if !is_inst(v) return 1;
                ok, dlhs, drhs := shuffle_demanded_elts(v, de);
                if !ok return 1;
                t: u32 = 0xFFFF_FFFF;
                if !ap_is_zero(dlhs) t = num_sign_bits_de(o0, dlhs, q, depth + 1);
                if t == 1 break;
                if !ap_is_zero(drhs) t = min(t, num_sign_bits_de(op(v, 1), drhs, q, depth + 1));
                if t == 1 break;
                return t;
            case .CALL;
                id := call_iid(v);
                if id == IID_ABS {
                    t := num_sign_bits_de(o0, de, q, depth + 1);
                    if t == 1 break;
                    return t - 1;
                }
                if id == IID_SMIN || id == IID_SMAX {
                    okc, clow, chigh := is_signed_min_max_intrinsic_clamp(v);
                    if okc return min(ap_num_sign_bits(clow), ap_num_sign_bits(chigh));
                }
        }
        break;
        }
    }
    vsb := num_sign_bits_vector_constant(v, de, ty_bits);
    if vsb != 0 return vsb;
    known := known_bits_de(v, de, q, depth);
    return max(first_answer, kb_count_min_sign_bits(known));
}
ap_ceil_log2 :: (a: APInt) -> u32 {
    // ceilLogBase2: bits - countl_zero(this - 1)
    return a.bits - ap_clz(ap_sub_u64(a, 1));
}

// isSignedMinMaxClamp
is_signed_min_max_clamp :: (sel: Value_Id) -> (bool, Value_Id, APInt, APInt) {
    no: APInt;
    spf, lhs, rhs := match_select_pattern(sel);
    if spf.flavor != .SMAX && spf.flavor != .SMIN return false, NONE, no, no;
    ok1, clow := pm_apint(rhs);
    if !ok1 return false, NONE, no, no;
    spf2, lhs2, rhs2 := match_select_pattern(lhs);
    if inverse_min_max_flavor(spf.flavor) != spf2.flavor return false, NONE, no, no;
    ok2, chigh := pm_apint(rhs2);
    if !ok2 return false, NONE, no, no;
    if spf.flavor == .SMIN { t := clow; clow = chigh; chigh = t; }
    return ap_sle(clow, chigh), lhs2, clow, chigh;
}
// isSignedMinMaxIntrinsicClamp
is_signed_min_max_intrinsic_clamp :: (ii: Value_Id) -> (bool, APInt, APInt) {
    no: APInt;
    id := call_iid(ii);
    inv := inverse_min_max_intrinsic(id);
    inner := op(ii, 0);
    if call_iid(inner) != inv return false, no, no;
    ok1, clow := pm_apint(op(ii, 1));
    ok2, chigh := pm_apint(op(inner, 1));
    if !ok1 || !ok2 return false, no, no;
    if id == IID_SMIN { t := clow; clow = chigh; chigh = t; }
    return ap_sle(clow, chigh), clow, chigh;
}

// ---------------------------------------------------------------- isKnownNonEqual

// getInvertibleOperands
invertible_operands :: (op1: Value_Id, op2: Value_Id) -> (bool, Value_Id, Value_Id) {
    o := opr_code(op1);
    if o != opr_code(op2) return false, NONE, NONE;
    if o == {
        case .OR;
            if (opr_flags(op1) & F_EXACT) == 0 || (opr_flags(op2) & F_EXACT) == 0 return false, NONE, NONE;
            #through;
        case .XOR; #through;
        case .ADD;
            ok, other := pm_c_binop_with(op2, opr_code(op2), op(op1, 0));
            if ok return true, op(op1, 1), other;
            ok, other = pm_c_binop_with(op2, opr_code(op2), op(op1, 1));
            if ok return true, op(op1, 0), other;
        case .SUB;
            if op(op1, 0) == op(op2, 0) return true, op(op1, 1), op(op2, 1);
            if op(op1, 1) == op(op2, 1) return true, op(op1, 0), op(op2, 0);
        case .MUL;
            f1 := opr_flags(op1); f2 := opr_flags(op2);
            if ((f1 & F_NUW) == 0 || (f2 & F_NUW) == 0) && ((f1 & F_NSW) == 0 || (f2 & F_NSW) == 0) return false, NONE, NONE;
            c := op(op1, 1);
            if c == op(op2, 1) && is_const_int(c) && !ap_is_zero(const_ap(c)) return true, op(op1, 0), op(op2, 0);
        case .SHL;
            f1 := opr_flags(op1); f2 := opr_flags(op2);
            if ((f1 & F_NUW) == 0 || (f2 & F_NUW) == 0) && ((f1 & F_NSW) == 0 || (f2 & F_NSW) == 0) return false, NONE, NONE;
            if op(op1, 1) == op(op2, 1) return true, op(op1, 0), op(op2, 0);
        case .ASHR; #through;
        case .LSHR;
            if (opr_flags(op1) & F_EXACT) == 0 || (opr_flags(op2) & F_EXACT) == 0 return false, NONE, NONE;
            if op(op1, 1) == op(op2, 1) return true, op(op1, 0), op(op2, 0);
        case .SEXT; #through;
        case .ZEXT;
            if vtype(op(op1, 0)) == vtype(op(op2, 0)) return true, op(op1, 0), op(op2, 0);
        case .PHI;
            if inst_block(op1) != inst_block(op2) return false, NONE, NONE;
            ok1, bo1, s1, st1 := match_simple_recurrence(op1);
            if !ok1 return false, NONE, NONE;
            ok2, bo2, s2, st2 := match_simple_recurrence(op2);
            if !ok2 return false, NONE, NONE;
            okv, a, b := invertible_operands(bo1, bo2);
            if !okv || a != op1 || b != op2 return false, NONE, NONE;
            return true, s1, s2;
    }
    return false, NONE, NONE;
}
is_modifying_binop_of_non_zero :: (v1: Value_Id, v2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    if !is_binary_operator(v1) return false;
    o := inst_op(v1);
    if o == .OR && (inst(v1).flags & F_EXACT) == 0 return false;
    if o != .OR && o != .XOR && o != .ADD return false;
    x: Value_Id;
    if v2 == op(v1, 0) x = op(v1, 1);
    else if v2 == op(v1, 1) x = op(v1, 0);
    else return false;
    return is_known_non_zero_de(x, de, q, depth + 1);
}
is_non_equal_mul :: (v1: Value_Id, v2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    if !is_overflowing_binop(v2) return false;
    ok, a, b := pm_binop(v2, .MUL);
    if !ok || a != v1 return false;
    okc, c := pm_apint(b);
    return okc && (opr_flags(v2) & (F_NUW | F_NSW)) != 0 && !ap_is_zero(c) && !ap_is_one(c) && is_known_non_zero_de(v1, de, q, depth + 1);
}
is_non_equal_shl :: (v1: Value_Id, v2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    if !is_overflowing_binop(v2) return false;
    ok, a, b := pm_binop(v2, .SHL);
    if !ok || a != v1 return false;
    okc, c := pm_apint(b);
    return okc && (opr_flags(v2) & (F_NUW | F_NSW)) != 0 && !ap_is_zero(c) && is_known_non_zero_de(v1, de, q, depth + 1);
}
is_non_equal_phis :: (pn1: Value_Id, pn2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    if inst_block(pn1) != inst_block(pn2) return false;
    visited: [..] Value_Id; visited.allocator = temp;
    used_full := false;
    n := nops(pn1);
    for k: 0..n-1 {
        bb := phi_block(pn1, k);
        seen := false;
        for visited if it == bb { seen = true; break; }
        if seen continue;
        array_add(*visited, bb);
        iv1 := phi_value(pn1, k);
        idx := phi_block_index(pn2, bb);
        iv2 := phi_value(pn2, cast(u32) idx);
        ok1, c1 := pm_apint(iv1); ok2, c2 := pm_apint(iv2);
        if ok1 && ok2 && !ap_eq(c1, c2) continue;
        if used_full return false;
        rq := q; rq.cc = null; rq.cxt = block_terminator(bb);
        if !is_known_non_equal_de(iv1, iv2, de, rq, depth + 1) return false;
        used_full = true;
    }
    return true;
}
is_non_equal_select :: (v1: Value_Id, v2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    ok1, c1, t1, f1 := pm_select(v1);
    if !ok1 return false;
    ok2, c2, t2, f2 := pm_select(v2);
    if ok2 && c1 == c2
        return is_known_non_equal_de(t1, t2, de, q, depth + 1) && is_known_non_equal_de(f1, f2, de, q, depth + 1);
    return is_known_non_equal_de(t1, v2, de, q, depth + 1) && is_known_non_equal_de(f1, v2, de, q, depth + 1);
}
is_non_equal_pointers_with_recursive_gep :: (a: Value_Id, b_in: Value_Id, q: Simplify_Query) -> bool {
    b := b_in;
    if !is_ptr_type(vtype(a)) || !is_ptr_type(vtype(b)) return false;
    if opr_code(a) != .GEP || nops(a) != 2 || !is_const(op(a, 1)) return false;
    pn := op(a, 0);
    if !is_phi(pn) || nops(pn) != 2 return false;
    start: Value_Id;
    step := a;
    if phi_value(pn, 0) == step start = phi_value(pn, 1);
    else if phi_value(pn, 1) == step start = phi_value(pn, 0);
    else return false;
    iw := dl_index_bits(vtype(start));
    start_off := ap_zero(iw);
    start, start_off = strip_and_accumulate_inbounds_constant_offsets(start, start_off);
    step_off := ap_zero(iw);
    step, step_off = strip_and_accumulate_inbounds_constant_offsets(step, step_off);
    if step != pn return false;
    off_b := ap_zero(iw);
    b, off_b = strip_and_accumulate_inbounds_constant_offsets(b, off_b);
    return start == b && ((ap_sge(start_off, off_b) && ap_is_strictly_positive(step_off)) || (ap_sle(start_off, off_b) && ap_is_negative(step_off)));
}
is_known_non_equal_from_context :: (v1: Value_Id, v2: Value_Id, q: Simplify_Query, depth: u32) -> bool {
    if q.cxt == NONE return false;
    if q.dc && q.dt {
        cb := inst_block(q.cxt);
        from_dom :: (v: Value_Id, v1: Value_Id, v2: Value_Id, q: Simplify_Query, depth: u32, cb: Value_Id) -> bool {
            for br: dc_conditions_for(q.dc, v) {
                if vkind(br) == .DEAD continue;
                c := op(br, 0); bb := inst_block(br);
                if dt_dominates_edge_block(q.dt, bb, get_successor(br, 0), cb) && is_implied_condition_pred(c, ICMP_NE, false, v1, v2, true, depth) == 1 return true;
                if dt_dominates_edge_block(q.dt, bb, get_successor(br, 1), cb) && is_implied_condition_pred(c, ICMP_NE, false, v1, v2, false, depth) == 1 return true;
            }
            return false;
        }
        if from_dom(v1, v1, v2, q, depth, cb) || from_dom(v2, v1, v2, q, depth, cb) return true;
    }
    if !q.ac return false;
    for e: ac_assumptions_for(q.ac, v1) {
        if vkind(e.assume) == .DEAD continue;
        i := e.assume;
        if is_implied_condition_pred(op(i, 0), ICMP_NE, false, v1, v2, true, depth) == 1 && is_valid_assume_q(i, q) return true;
    }
    return false;
}
is_known_non_equal :: (v1: Value_Id, v2: Value_Id, q: Simplify_Query, depth: u32 = 0) -> bool {
    if v1 == v2 || vtype(v1) != vtype(v2) return false;
    return is_known_non_equal_de(v1, v2, dem_all(vtype(v1)), q, depth);
}
is_known_non_equal_de :: (v1: Value_Id, v2: Value_Id, de: APInt, q: Simplify_Query, depth: u32) -> bool {
    if v1 == v2 return false;
    if vtype(v1) != vtype(v2) return false;
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return false;
    o1 := opr_code(v1); o2 := opr_code(v2);
    if o1 != .NONE_OP && o1 == o2 {
        ok, a, b := invertible_operands(v1, v2);
        if ok return is_known_non_equal_de(a, b, de, q, depth + 1);
        if is_phi(v1) && is_non_equal_phis(v1, v2, de, q, depth) return true;
    }
    if is_modifying_binop_of_non_zero(v1, v2, de, q, depth) || is_modifying_binop_of_non_zero(v2, v1, de, q, depth) return true;
    if is_non_equal_mul(v1, v2, de, q, depth) || is_non_equal_mul(v2, v1, de, q, depth) return true;
    if is_non_equal_shl(v1, v2, de, q, depth) || is_non_equal_shl(v2, v1, de, q, depth) return true;
    if is_int_type(scalar_type(vtype(v1))) {
        k1 := known_bits_de(v1, de, q, depth);
        if !kb_is_unknown(k1) {
            k2 := known_bits_de(v2, de, q, depth);
            if ap_intersects(k1.zero, k2.one) || ap_intersects(k2.zero, k1.one) return true;
        }
    }
    if is_non_equal_select(v1, v2, de, q, depth) || is_non_equal_select(v2, v1, de, q, depth) return true;
    if is_non_equal_pointers_with_recursive_gep(v1, v2, q) || is_non_equal_pointers_with_recursive_gep(v2, v1, q) return true;
    oka, a := pm_ptrtoint_same_size(v1);
    okb, b := pm_ptrtoint_same_size(v2);
    if oka && okb return is_known_non_equal_de(a, b, de, q, depth + 1);
    if is_known_non_equal_from_context(v1, v2, q, depth) return true;
    return false;
}
// m_PtrToIntSameSize(DL, m_Value(X))
pm_ptrtoint_same_size :: (v: Value_Id) -> (bool, Value_Id) {
    if opr_code(v) != .PTRTOINT return false, NONE;
    x := op(v, 0);
    if type_bits(scalar_type(vtype(v))) != vt_bit_width(vtype(x)) return false, NONE;
    return true, x;
}

// ---------------------------------------------------------------- matchSelectPattern

Select_Flavor :: enum u8 { UNKNOWN; SMIN; UMIN; SMAX; UMAX; FMINNUM; FMAXNUM; ABS; NABS; }
Select_Nan_Behavior :: enum u8 { NA; RETURNS_NAN; RETURNS_OTHER; RETURNS_ANY; }
Select_Pattern :: struct { flavor: Select_Flavor; nan: Select_Nan_Behavior; ordered: bool; }
spf_is_min_or_max :: (f: Select_Flavor) -> bool { return f != .UNKNOWN && f != .ABS && f != .NABS; }
inverse_min_max_flavor :: (f: Select_Flavor) -> Select_Flavor {
    if f == .SMIN return .SMAX; if f == .UMIN return .UMAX; if f == .SMAX return .SMIN; if f == .UMAX return .UMIN;
    fatal("internal: getInverseMinMaxFlavor of a non-min/max flavor");
    return .UNKNOWN;
}
// getInverseMinMaxIntrinsic
inverse_min_max_intrinsic :: (id: Intrinsic_Id) -> Intrinsic_Id {
    if id == {
        case IID_SMAX; return IID_SMIN; case IID_SMIN; return IID_SMAX;
        case IID_UMAX; return IID_UMIN; case IID_UMIN; return IID_UMAX;
        case IID_MAXIMUM; return IID_MINIMUM; case IID_MINIMUM; return IID_MAXIMUM;
        case IID_MAXNUM; return IID_MINNUM; case IID_MINNUM; return IID_MAXNUM;
        case IID_MAXIMUMNUM; return IID_MINIMUMNUM; case IID_MINIMUMNUM; return IID_MAXIMUMNUM;
    }
    fatal("internal: getInverseMinMaxIntrinsic of an unexpected intrinsic");
    return 0;
}
// getMinMaxPred
min_max_pred :: (f: Select_Flavor, ordered := false) -> u8 {
    if f == .SMIN return ICMP_SLT; if f == .UMIN return ICMP_ULT; if f == .SMAX return ICMP_SGT; if f == .UMAX return ICMP_UGT;
    if f == .FMINNUM return xx ifx ordered then FCMP_OLT else FCMP_ULT;
    if f == .FMAXNUM return xx ifx ordered then FCMP_OGT else FCMP_UGT;
    fatal("internal: getMinMaxPred unhandled");
    return 0;
}
// getMinMaxIntrinsic
min_max_intrinsic :: (f: Select_Flavor) -> Intrinsic_Id {
    if f == .UMIN return IID_UMIN; if f == .UMAX return IID_UMAX; if f == .SMIN return IID_SMIN; if f == .SMAX return IID_SMAX;
    fatal("internal: getMinMaxIntrinsic unexpected flavor");
    return 0;
}
spr :: (f: Select_Flavor, nan := Select_Nan_Behavior.NA, ordered := false) -> Select_Pattern { r: Select_Pattern; r.flavor = f; r.nan = nan; r.ordered = ordered; return r; }

// isKnownNegation
is_known_negation :: (x: Value_Id, y: Value_Id, need_nsw := false, allow_poison := true) -> bool {
    is_negation_of :: (x: Value_Id, y: Value_Id, need_nsw: bool, allow_poison: bool) -> bool {
        ok, z := pm_neg(x);
        if !ok || z != y return false;
        if need_nsw && (opr_flags(x) & F_NSW) == 0 return false;
        if !allow_poison && !is_null_value(op(x, 0)) return false;
        return true;
    }
    if is_negation_of(x, y, need_nsw, allow_poison) || is_negation_of(y, x, need_nsw, allow_poison) return true;
    okx, a, b := pm_binop(x, .SUB);
    oky, c, d := pm_binop(y, .SUB);
    if !okx || !oky || c != b || d != a return false;
    if !need_nsw return true;
    return (opr_flags(x) & F_NSW) != 0 && (opr_flags(y) & F_NSW) != 0;
}
// isKnownInversion
is_known_inversion :: (x: Value_Id, y: Value_Id) -> bool {
    ok1, p1, ss1, a, b := pm_icmp(x);
    if !ok1 return false;
    ok2, p2, ss2, ya, yb := pm_icmp(y);
    if !ok2 return false;
    c: Value_Id;
    if ya == a c = yb; else if yb == a { c = ya; p2 = cmp_swapped(p2); } else return false;
    if ss1 != ss2 return false;
    if b == c return p1 == cmp_inverse(p2);
    okc1, r1 := pm_apint(b);
    okc2, r2 := pm_apint(c);
    if !okc1 || !okc2 return false;
    if ss1 && ap_is_non_negative(r1) != ap_is_non_negative(r2) return false;
    cr1 := cr_exact_icmp_region(p1, r1);
    cr2 := cr_exact_icmp_region(p2, r2);
    return cr_eq(cr_inverse(cr1), cr2);
}
// getSelectPattern
get_select_pattern :: (pred: u8, nan: Select_Nan_Behavior, ordered: bool) -> Select_Pattern {
    if pred == {
        case ICMP_UGT; #through; case ICMP_UGE; return spr(.UMAX);
        case ICMP_SGT; #through; case ICMP_SGE; return spr(.SMAX);
        case ICMP_ULT; #through; case ICMP_ULE; return spr(.UMIN);
        case ICMP_SLT; #through; case ICMP_SLE; return spr(.SMIN);
        case FCMP_UGT; #through; case FCMP_UGE; #through; case FCMP_OGT; #through; case FCMP_OGE; return spr(.FMAXNUM, nan, ordered);
        case FCMP_ULT; #through; case FCMP_ULE; #through; case FCMP_OLT; #through; case FCMP_OLE; return spr(.FMINNUM, nan, ordered);
    }
    return spr(.UNKNOWN);
}
// matchClamp
match_clamp :: (pred_in: u8, cmp_lhs: Value_Id, cmp_rhs: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> Select_Pattern {
    pred := pred_in; tv := tv_in; fv := fv_in;
    if cmp_rhs != tv { pred = cmp_swapped(pred); t := tv; tv = fv; fv = t; }
    ok1, c1 := pm_apint(cmp_rhs);
    if cmp_rhs == tv && ok1 {
        m :: (fv: Value_Id, id: Intrinsic_Id, x: Value_Id) -> (bool, APInt) {
            no: APInt;
            if call_iid(fv) != id || op(fv, 0) != x return false, no;
            ok, c := pm_apint(op(fv, 1));
            return ok, c;
        }
        ok, c2 := m(fv, IID_SMIN, cmp_lhs);
        if ok && ap_slt(c1, c2) && pred == ICMP_SLT return spr(.SMAX);
        ok, c2 = m(fv, IID_SMAX, cmp_lhs);
        if ok && ap_sgt(c1, c2) && pred == ICMP_SGT return spr(.SMIN);
        ok, c2 = m(fv, IID_UMIN, cmp_lhs);
        if ok && ap_ult(c1, c2) && pred == ICMP_ULT return spr(.UMAX);
        ok, c2 = m(fv, IID_UMAX, cmp_lhs);
        if ok && ap_ugt(c1, c2) && pred == ICMP_UGT return spr(.UMIN);
    }
    return spr(.UNKNOWN);
}
// matchMinMaxOfMinMax
match_min_max_of_min_max :: (pred_in: u8, cmp_lhs_in: Value_Id, cmp_rhs_in: Value_Id, tval: Value_Id, fval: Value_Id, depth: u32) -> Select_Pattern {
    pred := pred_in; cl := cmp_lhs_in; cr := cmp_rhs_in;
    l, a, b := match_select_pattern(tval, depth + 1);
    if !spf_is_min_or_max(l.flavor) return spr(.UNKNOWN);
    r, c, d := match_select_pattern(fval, depth + 1);
    if l.flavor != r.flavor return spr(.UNKNOWN);
    swp :: () #expand { `pred = cmp_swapped(`pred); t := `cl; `cl = `cr; `cr = t; }
    if l.flavor == {
        case .SMIN;
            if pred == ICMP_SGT || pred == ICMP_SGE swp();
            if !(pred == ICMP_SLT || pred == ICMP_SLE) return spr(.UNKNOWN);
        case .SMAX;
            if pred == ICMP_SLT || pred == ICMP_SLE swp();
            if !(pred == ICMP_SGT || pred == ICMP_SGE) return spr(.UNKNOWN);
        case .UMIN;
            if pred == ICMP_UGT || pred == ICMP_UGE swp();
            if !(pred == ICMP_ULT || pred == ICMP_ULE) return spr(.UNKNOWN);
        case .UMAX;
            if pred == ICMP_ULT || pred == ICMP_ULE swp();
            if !(pred == ICMP_UGT || pred == ICMP_UGE) return spr(.UNKNOWN);
        case; return spr(.UNKNOWN);
    }
    is_not_of :: (x: Value_Id, y: Value_Id) -> bool { ok, z := pm_not(x); return ok && z == y; }
    if d == b && ((cl == a && cr == c) || (is_not_of(c, cl) && is_not_of(a, cr))) return spr(l.flavor);
    if c == b && ((cl == a && cr == d) || (is_not_of(d, cl) && is_not_of(a, cr))) return spr(l.flavor);
    if d == a && ((cl == b && cr == c) || (is_not_of(c, cl) && is_not_of(b, cr))) return spr(l.flavor);
    if c == a && ((cl == b && cr == d) || (is_not_of(d, cl) && is_not_of(b, cr))) return spr(l.flavor);
    return spr(.UNKNOWN);
}
// getNotValue: ~V as a value (an existing `not` operand, or a folded constant)
get_not_value :: (v: Value_Id) -> Value_Id {
    ok, x := pm_not(v);
    if ok return x;
    okc, c := pm_apint(v);
    if okc return cf_int(vtype(v), ap_not(c));
    return NONE;
}
// matchMinMax
match_min_max :: (pred: u8, cl: Value_Id, cr: Value_Id, tv: Value_Id, fv: Value_Id, depth: u32) -> (Select_Pattern, Value_Id, Value_Id) {
    lhs := tv; rhs := fv;
    s := match_clamp(pred, cl, cr, tv, fv);
    if s.flavor != .UNKNOWN return s, lhs, rhs;
    s = match_min_max_of_min_max(pred, cl, cr, tv, fv, depth);
    if s.flavor != .UNKNOWN return s, lhs, rhs;
    ntv := get_not_value(tv); nfv := get_not_value(fv);
    if cl == ntv && cr == nfv {
        if pred == ICMP_SGT return spr(.SMIN), lhs, rhs;
        if pred == ICMP_SLT return spr(.SMAX), lhs, rhs;
        if pred == ICMP_UGT return spr(.UMIN), lhs, rhs;
        if pred == ICMP_ULT return spr(.UMAX), lhs, rhs;
    }
    if cl == nfv && cr == ntv {
        if pred == ICMP_SGT return spr(.SMAX), lhs, rhs;
        if pred == ICMP_SLT return spr(.SMIN), lhs, rhs;
        if pred == ICMP_UGT return spr(.UMAX), lhs, rhs;
        if pred == ICMP_ULT return spr(.UMIN), lhs, rhs;
    }
    if pred != ICMP_SGT && pred != ICMP_SLT return spr(.UNKNOWN), lhs, rhs;
    ok1, c1 := pm_apint(cr);
    if !ok1 return spr(.UNKNOWN), lhs, rhs;
    c2: APInt; ok2 := false;
    if cl == tv { ok2, c2 = pm_apint(fv); }
    if !ok2 && cl == fv { ok2, c2 = pm_apint(tv); }
    if ok2 {
        if pred == ICMP_SLT && ap_is_zero(c1) && ap_is_max_signed(c2) return spr(ifx cl == tv then Select_Flavor.UMAX else .UMIN), lhs, rhs;
        if pred == ICMP_SGT && ap_is_all_ones(c1) && ap_is_min_signed(c2) return spr(ifx cl == fv then Select_Flavor.UMAX else .UMIN), lhs, rhs;
    }
    return spr(.UNKNOWN), lhs, rhs;
}
// isKnownNonNaN (ValueTracking.cpp static helper of matchSelectPattern)
spf_is_known_non_nan :: (v: Value_Id, fmf: u32) -> bool {
    if fmf & FMF_NNAN return true;
    k := vkind(v);
    if k == .C_FP return !apf_is_nan(apf_from_const(v));
    if k == .C_DATA && type_kind(vtype(v)) == .VECTOR {
        if !is_fp_type(type_elem(vtype(v))) return false;
        n := type_count(vtype(v));
        for e: 0..cast(s64) n - 1 if apf_is_nan(apf_from_const(cf_elt(v, cast(u64) e))) return false;
        return true;
    }
    if k == .C_ZERO return true;   // ConstantAggregateZero
    return false;
}
// isKnownNonZero (ValueTracking.cpp static helper of matchSelectPattern; FP constants only)
spf_is_known_non_zero :: (v: Value_Id) -> bool {
    k := vkind(v);
    if k == .C_FP return !apf_is_zero(apf_from_const(v));
    if k == .C_DATA && type_kind(vtype(v)) == .VECTOR {
        if !is_fp_type(type_elem(vtype(v))) return false;
        n := type_count(vtype(v));
        for e: 0..cast(s64) n - 1 if apf_is_zero(apf_from_const(cf_elt(v, cast(u64) e))) return false;
        return true;
    }
    return false;
}
// FMaxMin_match<L, R, {o,u}f{max,min}_pred_ty>: "(x pred y) ? x : y" or "(x pred y) ? y : x" with an fcmp
pm_fmaxmin_select :: (v: Value_Id, is_max: bool, ordered: bool) -> (bool, Value_Id, Value_Id) {
    if !is_inst(v) || inst_op(v) != .SELECT return false, NONE, NONE;
    c := op(v, 0);
    if !is_inst(c) || inst_op(c) != .FCMP return false, NONE, NONE;
    tv := op(v, 1); fv := op(v, 2);
    l := op(c, 0); r := op(c, 1);
    if (tv != l || fv != r) && (tv != r || fv != l) return false, NONE, NONE;
    pred := ifx l == tv then inst_pred(c) else cmp_inverse(inst_pred(c));
    ok: bool;
    if is_max ok = ifx ordered then (pred == FCMP_OGT || pred == FCMP_OGE) else (pred == FCMP_UGT || pred == FCMP_UGE);
    else ok = ifx ordered then (pred == FCMP_OLT || pred == FCMP_OLE) else (pred == FCMP_ULT || pred == FCMP_ULE);
    if !ok return false, NONE, NONE;
    return true, l, r;
}
// m_OrdOrUnordFMax / m_OrdOrUnordFMin
pm_ord_or_unord_fmax :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ok, l, r := pm_fmaxmin_select(v, true, true); if ok return true, l, r;
    ok, l, r = pm_fmaxmin_select(v, true, false); return ok, l, r;
}
pm_ord_or_unord_fmin :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    ok, l, r := pm_fmaxmin_select(v, false, true); if ok return true, l, r;
    ok, l, r = pm_fmaxmin_select(v, false, false); return ok, l, r;
}
// matchFastFloatClamp
match_fast_float_clamp :: (pred_in: u8, cl: Value_Id, cr: Value_Id, tv_in: Value_Id, fv_in: Value_Id) -> (Select_Pattern, Value_Id, Value_Id) {
    pred := pred_in; tv := tv_in; fv := fv_in;
    if cr == fv { t := tv; tv = fv; fv = t; pred = cmp_inverse(pred); }
    lhs := tv; rhs := fv;
    ok1, fc1 := pm_apfloat(cr);
    if cr != tv || !ok1 || !apf_is_finite(fc1) return spr(.UNKNOWN), lhs, rhs;
    if pred == {
        case FCMP_OLT; #through; case FCMP_OLE; #through; case FCMP_ULT; #through; case FCMP_ULE;
            ok, a, b := pm_ord_or_unord_fmin(fv);
            if ok && a == cl { okc, fc2 := pm_apfloat(b); if okc && apf_compare(fc1, fc2) == .LESS return spr(.FMAXNUM, .RETURNS_ANY, false), lhs, rhs; }
            if call_iid(fv) == IID_MINNUM && op(fv, 0) == cl { okc, fc2 := pm_apfloat(op(fv, 1)); if okc && apf_compare(fc1, fc2) == .LESS return spr(.FMAXNUM, .RETURNS_ANY, false), lhs, rhs; }
        case FCMP_OGT; #through; case FCMP_OGE; #through; case FCMP_UGT; #through; case FCMP_UGE;
            ok, a, b := pm_ord_or_unord_fmax(fv);
            if ok && a == cl { okc, fc2 := pm_apfloat(b); if okc && apf_compare(fc1, fc2) == .GREATER return spr(.FMINNUM, .RETURNS_ANY, false), lhs, rhs; }
            if call_iid(fv) == IID_MAXNUM && op(fv, 0) == cl { okc, fc2 := pm_apfloat(op(fv, 1)); if okc && apf_compare(fc1, fc2) == .GREATER return spr(.FMINNUM, .RETURNS_ANY, false), lhs, rhs; }
    }
    return spr(.UNKNOWN), lhs, rhs;
}
// static matchSelectPattern(Pred, FMF, CmpLHS, CmpRHS, TrueVal, FalseVal, LHS, RHS, Depth)
match_select_pattern_impl :: (pred_in: u8, fmf: u32, cmp_lhs_in: Value_Id, cmp_rhs_in: Value_Id, tv: Value_Id, fv: Value_Id, depth: u32) -> (Select_Pattern, Value_Id, Value_Id) {
    pred := pred_in; cl := cmp_lhs_in; cr := cmp_rhs_in;
    has_mismatched_zeros := false;
    if is_fp_predicate(pred) {
        out_zero: Value_Id = NONE;
        if pm_any_zero_fp(tv) && !pm_any_zero_fp(fv) && !contains_undef_or_poison_element(tv) out_zero = tv;
        else if pm_any_zero_fp(fv) && !pm_any_zero_fp(tv) && !contains_undef_or_poison_element(fv) out_zero = fv;
        if out_zero != NONE {
            if pm_any_zero_fp(cl) && cl != out_zero { has_mismatched_zeros = true; cl = out_zero; }
            if pm_any_zero_fp(cr) && cr != out_zero { has_mismatched_zeros = true; cr = out_zero; }
        }
    }
    lhs := cl; rhs := cr;
    check_zero := false;
    if pred == {
        case FCMP_OGT; #through; case FCMP_OLT; #through; case FCMP_UGT; #through; case FCMP_ULT;
            check_zero = has_mismatched_zeros;
        case FCMP_OGE; #through; case FCMP_OLE; #through; case FCMP_UGE; #through; case FCMP_ULE;
            check_zero = true;
    }
    if check_zero && (fmf & FMF_NSZ) == 0 && !spf_is_known_non_zero(cl) && !spf_is_known_non_zero(cr) return spr(.UNKNOWN), lhs, rhs;
    nan := Select_Nan_Behavior.NA;
    ordered := false;
    if is_fp_predicate(pred) {
        lsafe := spf_is_known_non_nan(cl, fmf);
        rsafe := spf_is_known_non_nan(cr, fmf);
        if lsafe && rsafe { nan = .RETURNS_ANY; ordered = cmp_is_ordered(pred); }
        else if cmp_is_ordered(pred) {
            ordered = true;
            if lsafe nan = .RETURNS_NAN;
            else if rsafe nan = .RETURNS_OTHER;
            else return spr(.UNKNOWN), lhs, rhs;
        } else {
            ordered = false;
            if lsafe nan = .RETURNS_OTHER;
            else if rsafe nan = .RETURNS_NAN;
            else return spr(.UNKNOWN), lhs, rhs;
        }
    }
    if tv == cr && fv == cl {
        t := cl; cl = cr; cr = t; pred = cmp_swapped(pred);
        if nan == .RETURNS_NAN nan = .RETURNS_OTHER;
        else if nan == .RETURNS_OTHER nan = .RETURNS_NAN;
        ordered = !ordered;
    }
    if tv == cl && fv == cr return get_select_pattern(pred, nan, ordered), lhs, rhs;
    if is_known_negation(tv, fv) {
        cmp_lhs_or_sext :: (v: Value_Id, cl: Value_Id) -> bool {
            if v == cl return true;
            ok, x := pm_cast(v, .SEXT);
            return ok && x == cl;
        }
        maybe_sext_or_mul :: (v: Value_Id, cl: Value_Id) -> bool {
            if cmp_lhs_or_sext(v, cl) return true;
            if opr_code(v) == .MUL && (opr_flags(v) & F_NSW) != 0 && cmp_lhs_or_sext(op(v, 0), cl) && pm_strictly_positive(op(v, 1)) return true;
            if opr_code(v) == .SHL && (opr_flags(v) & F_NSW) != 0 && cmp_lhs_or_sext(op(v, 0), cl) return true;
            return false;
        }
        zero_or_all_ones :: (v: Value_Id) -> bool { return pm_zero_int(v) || pm_all_ones(v); }
        zero_or_one :: (v: Value_Id) -> bool { return pm_zero_int(v) || pm_one(v); }
        is_neg_of :: (x: Value_Id, y: Value_Id) -> bool { ok, z := pm_neg(x); return ok && z == y; }
        if maybe_sext_or_mul(tv, cl) {
            lhs = tv; rhs = fv;
            if is_neg_of(cl, fv) { t := lhs; lhs = rhs; rhs = t; }
            if pred == ICMP_SGT && zero_or_all_ones(cr) return spr(.ABS), lhs, rhs;
            if pred == ICMP_SGE && zero_or_one(cr) return spr(.ABS), lhs, rhs;
            if pred == ICMP_SLT && zero_or_one(cr) return spr(.NABS), lhs, rhs;
        } else if maybe_sext_or_mul(fv, cl) {
            lhs = fv; rhs = tv;
            if is_neg_of(cl, tv) { t := lhs; lhs = rhs; rhs = t; }
            if pred == ICMP_SGT && zero_or_all_ones(cr) return spr(.NABS), lhs, rhs;
            if pred == ICMP_SLT && zero_or_one(cr) return spr(.ABS), lhs, rhs;
        }
    }
    if is_int_predicate(pred) {
        s, l2, r2 := match_min_max(pred, cl, cr, tv, fv, depth);
        return s, l2, r2;
    }
    if nan != .RETURNS_ANY || ((fmf & FMF_NSZ) == 0 && !spf_is_known_non_zero(cl) && !spf_is_known_non_zero(cr)) return spr(.UNKNOWN), lhs, rhs;
    s, l2, r2 := match_fast_float_clamp(pred, cl, cr, tv, fv);
    return s, l2, r2;
}
// lookThroughCastConst
look_through_cast_const :: (cmp: Value_Id, src_ty: Type_Id, c: Value_Id, cast_op: Opcode) -> Value_Id {
    casted_to: Value_Id = NONE;
    pred := inst_pred(cmp);
    if cast_op == {
        case .ZEXT; if cmp_is_unsigned(pred) casted_to = ce_cast(.TRUNC, c, src_ty);
        case .SEXT; if cmp_is_signed(pred) casted_to = cf_cast(.TRUNC, c, src_ty);
        case .TRUNC;
            cc := op(cmp, 1);
            if is_const(cc) && vtype(cc) == src_ty casted_to = cc;
            else casted_to = cfo_cast_operand(ifx cmp_is_signed(pred) then Opcode.SEXT else .ZEXT, c, src_ty);
        case .FPTRUNC; casted_to = cfo_cast_operand(.FPEXT, c, src_ty);
        case .FPEXT; casted_to = cfo_cast_operand(.FPTRUNC, c, src_ty);
        case .FPTOUI; casted_to = cfo_cast_operand(.UITOFP, c, src_ty);
        case .FPTOSI; casted_to = cfo_cast_operand(.SITOFP, c, src_ty);
        case .UITOFP; casted_to = cfo_cast_operand(.FPTOUI, c, src_ty);
        case .SITOFP; casted_to = cfo_cast_operand(.FPTOSI, c, src_ty);
    }
    if casted_to == NONE return NONE;
    back := cfo_cast_operand(cast_op, casted_to, vtype(c));
    if back != NONE && back != c return NONE;
    return casted_to;
}
// lookThroughCast: (new second value, cast opcode)
look_through_cast :: (cmp: Value_Id, v1: Value_Id, v2: Value_Id) -> (Value_Id, Opcode) {
    if !is_inst(v1) || !is_cast_op(inst_op(v1)) return NONE, .NONE_OP;
    cast_op := inst_op(v1);
    src_ty := vtype(op(v1, 0));
    if is_inst(v2) && is_cast_op(inst_op(v2)) {
        if cast_op == inst_op(v2) && src_ty == vtype(op(v2, 0)) return op(v2, 0), cast_op;
        return NONE, cast_op;
    }
    if is_const(v2) return look_through_cast_const(cmp, src_ty, v2, cast_op), cast_op;
    if cast_op == .TRUNC {
        ok, x := pmi_zext_or_sext(op(cmp, 1));
        if ok && x == v2 return op(cmp, 1), cast_op;
    }
    return NONE, cast_op;
}
// matchDecomposedSelectPattern(CmpI, TrueVal, FalseVal, LHS, RHS, FMF, CastOp, Depth): the last result is the
// cast opcode (CastOp; only written when `want_cast` and a cast was looked through, else NONE_OP)
match_decomposed_select_pattern_full :: (cmp: Value_Id, tv: Value_Id, fv: Value_Id, fmf_in: u32, want_cast: bool, depth: u32) -> (Select_Pattern, Value_Id, Value_Id, Opcode) {
    fmf := fmf_in;
    pred := inst_pred(cmp);
    cl := op(cmp, 0); cr := op(cmp, 1);
    if inst_op(cmp) == .FCMP && (get_fmf(cmp) & FMF_NNAN) != 0 fmf |= FMF_NNAN;
    cast_op := Opcode.NONE_OP;
    if cmp_is_equality(pred) return spr(.UNKNOWN), NONE, NONE, cast_op;
    if want_cast && vtype(cl) != vtype(tv) {
        c, co := look_through_cast(cmp, tv, fv);
        if co != .NONE_OP cast_op = co;
        if c != NONE {
            if cast_op == .FPTOSI || cast_op == .FPTOUI fmf |= FMF_NSZ;
            s, l, r := match_select_pattern_impl(pred, fmf, cl, cr, op(tv, 0), c, depth);
            return s, l, r, cast_op;
        }
        c, co = look_through_cast(cmp, fv, tv);
        if co != .NONE_OP cast_op = co;
        if c != NONE {
            if cast_op == .FPTOSI || cast_op == .FPTOUI fmf |= FMF_NSZ;
            s, l, r := match_select_pattern_impl(pred, fmf, cl, cr, c, op(fv, 0), depth);
            return s, l, r, cast_op;
        }
    }
    s, l, r := match_select_pattern_impl(pred, fmf, cl, cr, tv, fv, depth);
    return s, l, r, cast_op;
}
// SelectInst::getFastMathFlagsOrNone
select_fmf_or_none :: (si: Value_Id) -> u32 { if is_fp_math_inst(si) return get_fmf(si); return 0; }
// matchSelectPattern(V, LHS, RHS, CastOp, Depth)
match_select_pattern_cast :: (v: Value_Id, want_cast: bool, depth: u32 = 0) -> (Select_Pattern, Value_Id, Value_Id, Opcode) {
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return spr(.UNKNOWN), NONE, NONE, .NONE_OP;
    ok, c, t, f := pm_select(v);
    if !ok || !is_cmp_inst(c) return spr(.UNKNOWN), NONE, NONE, .NONE_OP;
    s, l, r, co := match_decomposed_select_pattern_full(c, t, f, select_fmf_or_none(v), want_cast, depth);
    return s, l, r, co;
}
// matchSelectPattern(V, LHS, RHS) (CastOp = nullptr)
match_select_pattern :: (v: Value_Id, depth: u32 = 0) -> (Select_Pattern, Value_Id, Value_Id) {
    s, l, r := match_select_pattern_cast(v, false, depth);
    return s, l, r;
}

// ---------------------------------------------------------------- isImpliedCondition

// isTruePredicate
is_true_predicate :: (pred: u8, lhs: Value_Id, rhs: Value_Id) -> bool {
    if cmp_is_true_when_equal(pred) && lhs == rhs return true;
    if pred == ICMP_SLE {
        ok, a, b := pm_binop(rhs, .ADD);
        if ok && (opr_flags(rhs) & F_NSW) != 0 && a == lhs { okc, c := pm_apint(b); if okc return !ap_is_negative(c); }
        ok, a, b = pm_binop(rhs, .OR);
        if ok && a == lhs { okc, c := pm_apint(b); if okc return !ap_is_negative(c); }
        okm, _ := pm_c_min_max_with(rhs, IID_SMAX, lhs); if okm return true;
        okm, _ = pm_c_min_max_with(lhs, IID_SMIN, rhs); if okm return true;
        ok1, x1, cl := pm_nsw_add_like(lhs);
        if ok1 {
            ok2, x2, crr := pm_nsw_add_like(rhs);
            if ok2 && x2 == x1 {
                oka, ca := pm_apint(cl); okb, cb := pm_apint(crr);
                if oka && okb return ap_sle(ca, cb);
            }
        }
        return false;
    }
    if pred == ICMP_ULE {
        okc, _ := pm_c_binop_with(rhs, .ADD, lhs);
        if okc && (opr_flags(rhs) & F_NUW) != 0 return true;
        okc, _ = pm_c_binop_with(rhs, .OR, lhs); if okc return true;
        okm, _ := pm_c_min_max_with(rhs, IID_UMAX, lhs); if okm return true;
        okl, la, _ := pm_binop(lhs, .LSHR); if okl && la == rhs return true;
        okd, da, db := pm_binop(lhs, .UDIV);
        if okd && da == rhs { okk, c := pm_apint(db); if okk && ap_ugt_u64(c, 1) return true; }
        okc, _ = pm_c_binop_with(lhs, .AND, rhs); if okc return true;
        okm, _ = pm_c_min_max_with(lhs, IID_UMIN, rhs); if okm return true;
        ok1, x1, cl := pm_nuw_add_like(lhs);
        if ok1 {
            ok2, x2, crr := pm_nuw_add_like(rhs);
            if ok2 && x2 == x1 {
                oka, ca := pm_apint(cl); okb, cb := pm_apint(crr);
                if oka && okb return ap_ule(ca, cb);
            }
        }
        return false;
    }
    return false;
}
// m_NSWAddLike / m_NUWAddLike: add nsw / add nuw, or `or disjoint`
pm_nsw_add_like :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    o := opr_code(v); f := opr_flags(v);
    if o == .ADD && (f & F_NSW) != 0 return true, op(v, 0), op(v, 1);
    if o == .OR && (f & F_EXACT) != 0 return true, op(v, 0), op(v, 1);
    return false, NONE, NONE;
}
pm_nuw_add_like :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    o := opr_code(v); f := opr_flags(v);
    if o == .ADD && (f & F_NUW) != 0 return true, op(v, 0), op(v, 1);
    if o == .OR && (f & F_EXACT) != 0 return true, op(v, 0), op(v, 1);
    return false, NONE, NONE;
}
// isImpliedCondOperands
is_implied_cond_operands :: (pred: u8, alhs: Value_Id, arhs: Value_Id, blhs: Value_Id, brhs: Value_Id) -> s8 {
    if pred == {
        case ICMP_SLT; #through; case ICMP_SLE;
            if is_true_predicate(ICMP_SLE, blhs, alhs) && is_true_predicate(ICMP_SLE, arhs, brhs) return 1;
        case ICMP_SGT; #through; case ICMP_SGE;
            if is_true_predicate(ICMP_SLE, alhs, blhs) && is_true_predicate(ICMP_SLE, brhs, arhs) return 1;
        case ICMP_ULT; #through; case ICMP_ULE;
            if is_true_predicate(ICMP_ULE, blhs, alhs) && is_true_predicate(ICMP_ULE, arhs, brhs) return 1;
        case ICMP_UGT; #through; case ICMP_UGE;
            if is_true_predicate(ICMP_ULE, alhs, blhs) && is_true_predicate(ICMP_ULE, brhs, arhs) return 1;
    }
    return -1;
}
// isImpliedCondCommonOperandWithCR
is_implied_cond_common_operand_with_cr :: (lp_in: u8, lss: bool, lcr: Const_Range, rp_in: u8, rss: bool, rcr: Const_Range) -> s8 {
    lp := lp_in; rp := rp_in;
    cr_implies :: (c: Const_Range, pred: u8, rcr: Const_Range) -> s8 {
        if cr_icmp(c, pred, rcr) return 1;
        if cr_icmp(c, cmp_inverse(pred), rcr) return 0;
        return -1;
    }
    r := cr_implies(cr_allowed_icmp_region_ss(lp, lss, lcr), rp, rcr);
    if r >= 0 return r;
    if lss != rss {
        lp = ifx lss then icmp_flipped_signedness(lp) else lp;
        rp = ifx rss then icmp_flipped_signedness(rp) else rp;
        return cr_implies(cr_allowed_icmp_region(lp, lcr), rp, rcr);
    }
    return -1;
}
// isImpliedCondICmps
is_implied_cond_icmps :: (lp_in: u8, lss: bool, l0_in: Value_Id, l1_in: Value_Id, rp_in: u8, rss: bool, r0_in: Value_Id, r1_in: Value_Id, lhs_is_true: bool) -> s8 {
    lp := lp_in; rp := rp_in; l0 := l0_in; l1 := l1_in; r0 := r0_in; r1 := r1_in;
    if !lhs_is_true lp = cmp_inverse(lp);
    if l0 == r1 { t := r0; r0 = r1; r1 = t; rp = cmp_swapped(rp); }
    if r0 == l1 { t := l0; l0 = l1; l1 = t; lp = cmp_swapped(lp); }
    if l1 == r1 {
        if l0 != r0 || pm_imm_constant(l0) {
            t := l0; l0 = l1; l1 = t; lp = cmp_swapped(lp);
            t = r0; r0 = r1; r1 = t; rp = cmp_swapped(rp);
        }
    }
    oka, _ := pm_apint(l1); okb, _ := pm_apint(r1);
    if l0 == r0 && (oka || okb) {
        sq: Simplify_Query;
        lcr := compute_constant_range(l1, icmp_is_signed(lp), sq, MAX_ANALYSIS_RECURSION_DEPTH - 1);
        rcr := compute_constant_range(r1, icmp_is_signed(rp), sq, MAX_ANALYSIS_RECURSION_DEPTH - 1);
        r := is_implied_cond_common_operand_with_cr(lp, lss, lcr, rp, rss, rcr);
        if r >= 0 return r;
        if oka && okb return -1;
    }
    if l0 == r0 && l1 == r1 return icmp_implied_by_matching_cmp(lp, lss, rp, rss);
    slp := icmp_preferred_signed_predicate(lp, lss);
    is_nsw_sub_of :: (r0: Value_Id, l0: Value_Id, l1: Value_Id) -> bool {
        ok, a, b := pm_binop(r0, .SUB);
        return ok && (opr_flags(r0) & F_NSW) != 0 && a == l0 && b == l1;
    }
    if (slp == ICMP_SGT || slp == ICMP_SGE) && is_nsw_sub_of(r0, l0, l1) {
        if pm_non_positive(r1) && icmp_implied_by_matching_cmp(slp, false, rp, rss) == 0 return 0;
    }
    if (slp == ICMP_SLT || slp == ICMP_SLE) && is_nsw_sub_of(r0, l0, l1) {
        if pm_non_negative(r1) && icmp_implied_by_matching_cmp(slp, false, rp, rss) == 1 return 1;
    }
    okc, l1c := pm_apint(l1);
    if lp == ICMP_EQ && icmp_is_equality(rp) && okc && !ap_is_zero(l1c) {
        oks, a, b := pm_binop(l0, .SUB);
        if oks {
            ptr_of :: (x: Value_Id, p: Value_Id) -> bool { o := opr_code(x); return (o == .PTRTOINT || o == .PTRTOADDR) && op(x, 0) == p; }
            if (a == r0 && b == r1) || (a == r1 && b == r0) || (ptr_of(a, r0) && ptr_of(b, r1)) || (ptr_of(a, r1) && ptr_of(b, r0))
                return ifx rp == ICMP_NE then cast(s8) 1 else 0;
        }
    }
    if l0 == r0 && (lp == ICMP_ULT || lp == ICMP_UGE) && (rp == ICMP_ULT || rp == ICMP_UGE) {
        oka2, x, y := pm_binop(l0, .ADD);
        if oka2 && ((x == l1 && y == r1) || (x == r1 && y == l1)) {
            okm, _, _ := cmp_get_matching(lp, lss, rp, rss);
            return ifx okm then cast(s8) 1 else 0;
        }
    }
    okm, p, _ := cmp_get_matching(lp, lss, rp, rss);
    if okm return is_implied_cond_operands(p, l0, l1, r0, r1);
    return -1;
}
// isImpliedCondFCmps
is_implied_cond_fcmps :: (lp_in: u8, l0_in: Value_Id, l1_in: Value_Id, rp_in: u8, r0_in: Value_Id, r1_in: Value_Id, lhs_is_true: bool) -> s8 {
    lp := lp_in; rp := rp_in; l0 := l0_in; l1 := l1_in; r0 := r0_in; r1 := r1_in;
    if !lhs_is_true lp = cmp_inverse(lp);
    if l0 == r1 { t := r0; r0 = r1; r1 = t; rp = cmp_swapped(rp); }
    if r0 == l1 { t := l0; l0 = l1; l1 = t; lp = cmp_swapped(lp); }
    if l1 == r1 {
        if l0 != r0 || pm_imm_constant(l0) {
            t := l0; l0 = l1; l1 = t; lp = cmp_swapped(lp);
            t = r0; r0 = r1; r1 = t; rp = cmp_swapped(rp);
        }
    }
    if l0 == r0 && l1 == r1 {
        if (lp & rp) == lp return 1;
        if (lp & ~rp) == lp return 0;
    }
    ok1, l1c := pm_apfloat(l1);
    ok2, r1c := pm_apfloat(r1);
    if l0 == r0 && ok1 && ok2 {
        okd, dom := cfr_make_exact_fcmp_region(lp, l1c);
        if okd {
            oki, imp := cfr_make_exact_fcmp_region(rp, r1c);
            if oki && cfr_contains_range(imp, dom) return 1;
            oki2, imp2 := cfr_make_exact_fcmp_region(cmp_inverse(rp), r1c);
            if oki2 && cfr_contains_range(imp2, dom) return 0;
        }
    }
    return -1;
}
// isImpliedCondAndOr
is_implied_cond_and_or :: (lhs: Value_Id, rp: u8, rss: bool, r0: Value_Id, r1: Value_Id, lhs_is_true: bool, depth: u32) -> s8 {
    a, b: Value_Id; ok := false;
    if !lhs_is_true { ok, a, b = pm_logical_or(lhs); }
    else { ok, a, b = pm_logical_and(lhs); }
    if ok {
        r := is_implied_condition_pred(a, rp, rss, r0, r1, lhs_is_true, depth + 1);
        if r >= 0 return r;
        r = is_implied_condition_pred(b, rp, rss, r0, r1, lhs_is_true, depth + 1);
        if r >= 0 return r;
    }
    return -1;
}
// m_ICmpLike: icmp, or `trunc nuw X to i1` as `icmp ne X, 0`
pm_icmp_like :: (v: Value_Id) -> (bool, u8, bool, Value_Id, Value_Id) {
    ok, p, ss, a, b := pm_icmp(v);
    if ok return true, p, ss, a, b;
    if is_bool_ty(vtype(v)) && is_inst(v) && inst_op(v) == .TRUNC && (inst(v).flags & F_NUW) != 0 {
        x := op(v, 0);
        return true, ICMP_NE, false, x, const_null_value(vtype(x));
    }
    return false, 0, false, NONE, NONE;
}
// isImpliedCondition(LHS, RHSPred, RHSOp0, RHSOp1, DL, LHSIsTrue, Depth): 1 true, 0 false, -1 unknown
is_implied_condition_pred :: (lhs_in: Value_Id, rp: u8, rss: bool, r0: Value_Id, r1: Value_Id, lhs_is_true_in: bool, depth: u32 = 0) -> s8 {
    lhs := lhs_in; lhs_is_true := lhs_is_true_in;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return -1;
    if is_vector_type(vtype(r0)) != is_vector_type(vtype(lhs)) return -1;
    okn, x := pm_not(lhs);
    if okn { lhs = x; lhs_is_true = !lhs_is_true; }
    st := scalar_type(vtype(r0));
    if is_int_type(st) || is_ptr_type(st) {
        ok, lp, lss, l0, l1 := pm_icmp_like(lhs);
        if ok return is_implied_cond_icmps(lp, lss, l0, l1, rp, rss, r0, r1, lhs_is_true);
    } else {
        if is_inst(lhs) && inst_op(lhs) == .FCMP return is_implied_cond_fcmps(inst_pred(lhs), op(lhs, 0), op(lhs, 1), rp, r0, r1, lhs_is_true);
    }
    if is_inst(lhs) {
        o := inst_op(lhs);
        if o == .AND || o == .OR || o == .SELECT return is_implied_cond_and_or(lhs, rp, rss, r0, r1, lhs_is_true, depth);
    }
    return -1;
}
// isImpliedCondition(LHS, RHS, DL, LHSIsTrue, Depth)
is_implied_condition :: (lhs: Value_Id, rhs_in: Value_Id, lhs_is_true: bool, depth: u32 = 0) -> s8 {
    rhs := rhs_in;
    if lhs == rhs return ifx lhs_is_true then cast(s8) 1 else 0;
    invert := false;
    okn, x := pm_not(rhs);
    if okn {
        rhs = x;
        if lhs == rhs return ifx lhs_is_true then cast(s8) 0 else 1;
        invert = true;
    }
    inv :: (r: s8, invert: bool) -> s8 { if r < 0 return r; if invert return 1 - r; return r; }
    ok, rp, rss, r0, r1 := pm_icmp_like(rhs);
    if ok return inv(is_implied_condition_pred(lhs, rp, rss, r0, r1, lhs_is_true, depth), invert);
    if is_inst(rhs) && inst_op(rhs) == .FCMP return inv(is_implied_condition_pred(lhs, inst_pred(rhs), false, op(rhs, 0), op(rhs, 1), lhs_is_true, depth), invert);
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return -1;
    oko, a, b := pm_logical_or(rhs);
    if oko {
        if is_implied_condition(lhs, a, lhs_is_true, depth + 1) == 1 return ifx invert then cast(s8) 0 else 1;
        if is_implied_condition(lhs, b, lhs_is_true, depth + 1) == 1 return ifx invert then cast(s8) 0 else 1;
    }
    oka, a2, b2 := pm_logical_and(rhs);
    if oka {
        if is_implied_condition(lhs, a2, lhs_is_true, depth + 1) == 0 return ifx invert then cast(s8) 1 else 0;
        if is_implied_condition(lhs, b2, lhs_is_true, depth + 1) == 0 return ifx invert then cast(s8) 1 else 0;
    }
    return -1;
}
// getDomPredecessorCondition
dom_predecessor_condition :: (cxt: Value_Id) -> (Value_Id, bool) {
    if cxt == NONE || inst(cxt).parent == NONE return NONE, false;
    bb := inst_block(cxt);
    pred := block_single_predecessor(bb);
    if pred == NONE return NONE, false;
    t := block_terminator(pred);
    if t == NONE || inst_op(t) != .CONDBR return NONE, false;
    tb := op(t, 1); fb := op(t, 2);
    if tb == fb return NONE, false;
    return op(t, 0), tb == bb;
}
is_implied_by_dom_condition :: (cond: Value_Id, cxt: Value_Id) -> s8 {
    c, t := dom_predecessor_condition(cxt);
    if c != NONE return is_implied_condition(c, cond, t);
    return -1;
}
is_implied_by_dom_condition_pred :: (pred: u8, ss: bool, lhs: Value_Id, rhs: Value_Id, cxt: Value_Id) -> s8 {
    c, t := dom_predecessor_condition(cxt);
    if c != NONE return is_implied_condition_pred(c, pred, ss, lhs, rhs, t);
    return -1;
}

// ---------------------------------------------------------------- computeConstantRange

set_limits_for_binop :: (bo: Value_Id, lower: *APInt, upper: *APInt, q: Simplify_Query, prefer_signed: bool) {
    width := lower.bits;
    o0 := op(bo, 0); o1 := op(bo, 1);
    if inst_op(bo) == {
        case .SUB;
            ok, c := pm_apint(o0);
            if ok {
                nsw := iiq_nsw(q, bo); nuw := iiq_nuw(q, bo);
                if prefer_signed && nsw && nuw nuw = false;
                if nuw upper.* = ap_add_u64(c, 1);
                else if nsw {
                    if ap_is_negative(c) { lower.* = ap_signed_min(width); upper.* = ap_sub(c, ap_signed_max(width)); }
                    else { lower.* = ap_sub(c, ap_signed_max(width)); upper.* = ap_signed_min(width); }
                }
            }
        case .ADD;
            ok, c := pm_apint(o1);
            if ok && !ap_is_zero(c) {
                nsw := iiq_nsw(q, bo); nuw := iiq_nuw(q, bo);
                if prefer_signed && nsw && nuw nuw = false;
                if nuw lower.* = c;
                else if nsw {
                    if ap_is_negative(c) { lower.* = ap_signed_min(width); upper.* = ap_add_u64(ap_add(ap_signed_max(width), c), 1); }
                    else { lower.* = ap_add(ap_signed_min(width), c); upper.* = ap_add_u64(ap_signed_max(width), 1); }
                }
            }
        case .AND;
            ok, c := pm_apint(o1);
            if ok upper.* = ap_add_u64(c, 1);
            okn0, x0 := pm_neg(o0); okn1, x1 := pm_neg(o1);
            if (okn0 && x0 == o1) || (okn1 && x1 == o0) upper.* = ap_add_u64(ap_signed_min(width), 1);
        case .OR;
            ok, c := pm_apint(o1);
            if ok lower.* = c;
        case .ASHR;
            ok, c := pm_apint(o1);
            if ok && ap_ult_u64(c, width) {
                lower.* = ap_ashr_ap(ap_signed_min(width), c);
                upper.* = ap_add_u64(ap_ashr_ap(ap_signed_max(width), c), 1);
            } else {
                ok2, c2 := pm_apint(o0);
                if ok2 {
                    sh := width - 1;
                    if !ap_is_zero(c2) && iiq_exact(q, bo) sh = ap_ctz(c2);
                    if ap_is_negative(c2) { lower.* = c2; upper.* = ap_add_u64(ap_ashr(c2, sh), 1); }
                    else { lower.* = ap_ashr(c2, sh); upper.* = ap_add_u64(c2, 1); }
                }
            }
        case .LSHR;
            ok, c := pm_apint(o1);
            if ok && ap_ult_u64(c, width) upper.* = ap_add_u64(ap_lshr_ap(ap_all_ones(width), c), 1);
            else {
                ok2, c2 := pm_apint(o0);
                if ok2 {
                    sh := width - 1;
                    if !ap_is_zero(c2) && iiq_exact(q, bo) sh = ap_ctz(c2);
                    lower.* = ap_lshr(c2, sh);
                    upper.* = ap_add_u64(c2, 1);
                }
            }
        case .SHL;
            ok, c := pm_apint(o0);
            if ok {
                if iiq_nuw(q, bo) {
                    lower.* = c;
                    upper.* = ap_add_u64(ap_shl(c, ap_clz(c)), 1);
                } else if (inst(bo).flags & F_NSW) != 0 {
                    if ap_is_negative(c) {
                        sh := ap_clo(c) - 1;
                        lower.* = ap_shl(c, sh); upper.* = ap_add_u64(c, 1);
                    } else {
                        sh := ap_clz(c) - 1;
                        lower.* = c; upper.* = ap_add_u64(ap_shl(c, sh), 1);
                    }
                } else {
                    if ap_get_bit(c, 0) lower.* = ap_one_bit_set(width, 0);
                    upper.* = ap_add_u64(ap_high_bits_set(width, ap_popcount(c)), 1);
                }
            } else {
                ok2, c2 := pm_apint(o1);
                if ok2 && ap_ult_u64(c2, width) upper.* = ap_add_u64(ap_bits_set_from(width, cast(u32) ap_zext_value(c2)), 1);
            }
        case .SDIV;
            ok, c := pm_apint(o1);
            if ok {
                imin := ap_signed_min(width); imax := ap_signed_max(width);
                if ap_is_all_ones(c) { lower.* = ap_add_u64(imin, 1); upper.* = ap_add_u64(imax, 1); }
                else if ap_clz(c) < width - 1 {
                    lower.* = ap_sdiv(imin, c); upper.* = ap_sdiv(imax, c);
                    if ap_sgt(lower.*, upper.*) { t := lower.*; lower.* = upper.*; upper.* = t; }
                    upper.* = ap_add_u64(upper.*, 1);
                }
            } else {
                ok2, c2 := pm_apint(o0);
                if ok2 {
                    if ap_is_min_signed(c2) { lower.* = c2; upper.* = ap_add_u64(ap_lshr(c2, 1), 1); }
                    else { upper.* = ap_add_u64(ap_abs(c2), 1); lower.* = ap_add_u64(ap_neg(upper.*), 1); }
                }
            }
        case .UDIV;
            ok, c := pm_apint(o1);
            if ok && !ap_is_zero(c) upper.* = ap_add_u64(ap_udiv(ap_all_ones(width), c), 1);
            else {
                ok2, c2 := pm_apint(o0);
                if ok2 upper.* = ap_add_u64(c2, 1);
            }
        case .SREM;
            ok, c := pm_apint(o1);
            if ok { upper.* = ap_abs(c); lower.* = ap_add_u64(ap_neg(upper.*), 1); }
            else {
                ok2, c2 := pm_apint(o0);
                if ok2 {
                    if ap_is_negative(c2) { upper.* = ap_one(width); lower.* = c2; }
                    else upper.* = ap_add_u64(c2, 1);
                }
            }
        case .UREM;
            ok, c := pm_apint(o1);
            if ok upper.* = c;
            else {
                ok2, c2 := pm_apint(o0);
                if ok2 upper.* = ap_add_u64(c2, 1);
            }
    }
}
// getRangeForIntrinsic
range_for_intrinsic :: (ii: Value_Id, use_instr_info: bool) -> Const_Range {
    width := type_bits(scalar_type(vtype(ii)));
    id := call_iid(ii);
    o0 := op(ii, 0);
    if id == {
        case IID_CTLZ; #through;
        case IID_CTTZ;
            upper := ap_from_u64(width, width);
            if !use_instr_info || !pm_one(op(ii, 1)) upper = ap_add_u64(upper, 1);
            return cr_non_empty(ap_zero(width), upper);
        case IID_CTPOP; return cr_non_empty(ap_zero(width), ap_add_u64(ap_from_u64(width, width), 1));
        case IID_UADD_SAT;
            ok, c := pm_apint(o0); if !ok { ok, c = pm_apint(op(ii, 1)); }
            if ok return cr_non_empty(c, ap_zero(width));
        case IID_SADD_SAT;
            ok, c := pm_apint(o0); if !ok { ok, c = pm_apint(op(ii, 1)); }
            if ok {
                if ap_is_negative(c) return cr_non_empty(ap_signed_min(width), ap_add_u64(ap_add(ap_signed_max(width), c), 1));
                return cr_non_empty(ap_add(ap_signed_min(width), c), ap_add_u64(ap_signed_max(width), 1));
            }
        case IID_USUB_SAT;
            ok, c := pm_apint(o0);
            if ok return cr_non_empty(ap_zero(width), ap_add_u64(c, 1));
            ok, c = pm_apint(op(ii, 1));
            if ok return cr_non_empty(ap_zero(width), ap_add_u64(ap_sub(ap_all_ones(width), c), 1));
        case IID_SSUB_SAT;
            ok, c := pm_apint(o0);
            if ok {
                if ap_is_negative(c) return cr_non_empty(ap_signed_min(width), ap_add_u64(ap_sub(c, ap_signed_min(width)), 1));
                return cr_non_empty(ap_sub(c, ap_signed_max(width)), ap_add_u64(ap_signed_max(width), 1));
            }
            ok, c = pm_apint(op(ii, 1));
            if ok {
                if ap_is_negative(c) return cr_non_empty(ap_sub(ap_signed_min(width), c), ap_add_u64(ap_signed_max(width), 1));
                return cr_non_empty(ap_signed_min(width), ap_add_u64(ap_sub(ap_signed_max(width), c), 1));
            }
        case IID_UMIN; #through; case IID_UMAX; #through; case IID_SMIN; #through; case IID_SMAX;
            ok, c := pm_apint(o0); if !ok { ok, c = pm_apint(op(ii, 1)); }
            if !ok return cr_full(width);
            if id == IID_UMIN return cr_non_empty(ap_zero(width), ap_add_u64(c, 1));
            if id == IID_UMAX return cr_non_empty(c, ap_zero(width));
            if id == IID_SMIN return cr_non_empty(ap_signed_min(width), ap_add_u64(c, 1));
            return cr_non_empty(c, ap_add_u64(ap_signed_max(width), 1));
        case IID_ABS;
            if pm_one(op(ii, 1)) return cr_non_empty(ap_zero(width), ap_add_u64(ap_signed_max(width), 1));
            return cr_non_empty(ap_zero(width), ap_add_u64(ap_signed_min(width), 1));
        case IID_VSCALE;
            if inst(ii).parent == NONE return cr_full(width);
            return get_vscale_range(inst_fn(ii), width);
    }
    return cr_full(width);
}
// getRangeForSelectPattern
range_for_select_pattern :: (si: Value_Id, q: Simplify_Query) -> Const_Range {
    bw := type_bits(scalar_type(vtype(si)));
    r, lhs, rhs := match_select_pattern(si);
    if r.flavor == .UNKNOWN return cr_full(bw);
    if r.flavor == .ABS {
        okn, x := pm_neg(rhs);
        if okn && x == lhs && iiq_nsw(q, rhs) return cr_non_empty(ap_zero(bw), ap_add_u64(ap_signed_max(bw), 1));
        return cr_non_empty(ap_zero(bw), ap_add_u64(ap_signed_min(bw), 1));
    }
    if r.flavor == .NABS return cr_non_empty(ap_signed_min(bw), ap_one(bw));
    ok, c := pm_apint(lhs); if !ok { ok, c = pm_apint(rhs); }
    if !ok return cr_full(bw);
    if r.flavor == {
        case .UMIN; return cr_non_empty(ap_zero(bw), ap_add_u64(c, 1));
        case .UMAX; return cr_non_empty(c, ap_zero(bw));
        case .SMIN; return cr_non_empty(ap_signed_min(bw), ap_add_u64(c, 1));
        case .SMAX; return cr_non_empty(c, ap_add_u64(ap_signed_max(bw), 1));
    }
    return cr_full(bw);
}
// Constant::toConstantRange
constant_to_range :: (c: Value_Id) -> Const_Range {
    if vkind(c) == .C_INT return cr_single(const_ap(c));
    bw := type_bits(scalar_type(vtype(c)));
    if !is_vector_type(vtype(c)) return cr_full(bw);
    s := get_splat_value(c, true);
    if s != NONE && vkind(s) == .C_INT return cr_single(const_ap(s));
    if vkind(c) == .C_DATA && is_int_type(scalar_type(vtype(c))) {
        r := cr_empty(bw);
        n := const_data_count(c);
        for i: 0..cast(s64) n - 1 r = cr_union(r, cr_single(ap_from_u64(bw, const_data_elt(c, cast(u64) i))));
        return r;
    }
    if vkind(c) == .C_VECTOR {
        r := cr_empty(bw);
        n := nops(c);
        for i: 0..cast(s64) n - 1 {
            e := op(c, cast(u32) i);
            if vkind(e) == .C_POISON continue;
            if vkind(e) != .C_INT return cr_full(bw);
            r = cr_union(r, cr_single(const_ap(e)));
        }
        return r;
    }
    return cr_full(bw);
}
// computeConstantRange
compute_constant_range :: (v: Value_Id, for_signed: bool, q: Simplify_Query, depth: u32 = 0) -> Const_Range {
    bw := type_bits(scalar_type(vtype(v)));
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return cr_full(bw);
    if is_const(v) return constant_to_range(v);
    r := cr_full(bw);
    if is_binary_operator(v) {
        lower := ap_zero(bw); upper := ap_zero(bw);
        set_limits_for_binop(v, *lower, *upper, q, for_signed);
        r = cr_non_empty(lower, upper);
    } else if call_iid(v) != NOT_INTRINSIC {
        r = range_for_intrinsic(v, q.use_instr_info);
    } else if is_inst(v) && inst_op(v) == .SELECT {
        rt := compute_constant_range(op(v, 1), for_signed, q, depth + 1);
        rf := compute_constant_range(op(v, 2), for_signed, q, depth + 1);
        r = cr_union(rt, rf);
        r = cr_intersect(r, range_for_select_pattern(v, q));
    } else if is_inst(v) && inst_op(v) == .TRUNC {
        src := compute_constant_range(op(v, 0), for_signed, q, depth + 1);
        r = cr_truncate(src, bw);
    } else if is_inst(v) && (inst_op(v) == .FPTOUI || inst_op(v) == .FPTOSI) {
        lower := ap_zero(bw); upper := ap_zero(bw);
        if type_kind(scalar_type(vtype(op(v, 0)))) == .HALF {
            if inst_op(v) == .FPTOSI && bw >= 17 { lower = ap_from_s64(bw, -65504); upper = ap_from_u64(bw, 65505); }
            if inst_op(v) == .FPTOUI && bw >= 16 upper = ap_from_u64(bw, 65505);
        }
        r = cr_non_empty(lower, upper);
    } else if vkind(v) == .ARGUMENT {
        okr, ar := arg_range(v);
        if okr r = ar;
    }
    if is_inst(v) {
        m := iiq_metadata(q, v, "range");
        if m != NONE r = cr_intersect(r, cr_from_range_md(m));
        if is_call_base(v) {
            okr, cr := call_range(v);
            if okr r = cr_intersect(r, cr);
        } else if inst_op(v) == .EXTRACTVALUE && inst(v).nidx == 1 && ir.u32_pool[inst(v).idx] == 1 && call_iid(op(v, 0)) == IID_FREXP {
            fatal("computeConstantRange of a frexp exponent is not supported yet");
        }
    }
    if q.cxt != NONE && q.ac {
        for e: ac_assumptions_for(q.ac, v) {
            if vkind(e.assume) == .DEAD continue;
            i := e.assume;
            if !is_valid_assume_q(i, q) continue;
            arg := op(i, 0);
            if !is_inst(arg) || inst_op(arg) != .ICMP || op(arg, 0) != v continue;
            rhs := compute_constant_range(op(arg, 1), false, sq_with_instruction(q, i), depth + 1);
            r = cr_intersect(r, cr_allowed_icmp_region_ss(inst_pred(arg), (inst(arg).flags & F_EXACT) != 0, rhs));
        }
    }
    return r;
}
// computeConstantRangeIncludingKnownBits
compute_constant_range_including_known_bits :: (v: Value_Id, for_signed: bool, q: Simplify_Query) -> Const_Range {
    cr1 := cr_from_known_bits(known_bits(v, q), for_signed);
    cr2 := compute_constant_range(v, for_signed, q);
    return cr_intersect(cr1, cr2, ifx for_signed then Preferred_Range.SIGNED else .UNSIGNED);
}

// ---------------------------------------------------------------- overflow

compute_overflow_for_unsigned_mul :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query, is_nsw := false) -> Overflow_Result {
    lr := compute_constant_range_including_known_bits(lhs, false, q);
    rr := compute_constant_range_including_known_bits(rhs, false, q);
    if is_nsw && cr_is_all_non_negative(lr) && cr_is_all_non_negative(rr) return .NEVER_OVERFLOWS;
    return cr_unsigned_mul_may_overflow(lr, rr);
}
compute_overflow_for_signed_mul :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Overflow_Result {
    bw := type_bits(scalar_type(vtype(lhs)));
    sb := num_sign_bits(lhs, q) + num_sign_bits(rhs, q);
    if sb > bw + 1 return .NEVER_OVERFLOWS;
    if sb == bw + 1 {
        lk := known_bits(lhs, q); rk := known_bits(rhs, q);
        if kb_is_non_negative(lk) || kb_is_non_negative(rk) return .NEVER_OVERFLOWS;
    }
    return .MAY_OVERFLOW;
}
compute_overflow_for_unsigned_add :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Overflow_Result {
    lr := compute_constant_range_including_known_bits(lhs, false, q);
    rr := compute_constant_range_including_known_bits(rhs, false, q);
    return cr_unsigned_add_may_overflow(lr, rr);
}
compute_overflow_for_signed_add_impl :: (lhs: Value_Id, rhs: Value_Id, add: Value_Id, q: Simplify_Query) -> Overflow_Result {
    if add != NONE && (opr_flags(add) & F_NSW) != 0 return .NEVER_OVERFLOWS;
    if num_sign_bits(lhs, q) > 1 && num_sign_bits(rhs, q) > 1 return .NEVER_OVERFLOWS;
    lr := compute_constant_range_including_known_bits(lhs, true, q);
    rr := compute_constant_range_including_known_bits(rhs, true, q);
    o := cr_signed_add_may_overflow(lr, rr);
    if o != .MAY_OVERFLOW return o;
    if add == NONE return .MAY_OVERFLOW;
    nneg := cr_is_all_non_negative(lr) || cr_is_all_non_negative(rr);
    neg := cr_is_all_negative(lr) || cr_is_all_negative(rr);
    if nneg || neg {
        ak := kb_new(cr_bits(lr));
        known_bits_from_context(add, *ak, q, 0);
        if (kb_is_non_negative(ak) && nneg) || (kb_is_negative(ak) && neg) return .NEVER_OVERFLOWS;
    }
    return .MAY_OVERFLOW;
}
compute_overflow_for_signed_add :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Overflow_Result { return compute_overflow_for_signed_add_impl(lhs, rhs, NONE, q); }
compute_overflow_for_signed_add_op :: (add: Value_Id, q: Simplify_Query) -> Overflow_Result { return compute_overflow_for_signed_add_impl(op(add, 0), op(add, 1), add, q); }
compute_overflow_for_unsigned_sub :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Overflow_Result {
    oku, ua, _ := pm_binop(rhs, .UREM);
    oks, sa, _ := pm_binop(rhs, .SUB);
    if (oku && ua == lhs) || (oks && (opr_flags(rhs) & F_NUW) != 0 && sa == lhs)
        if is_guaranteed_not_to_be_undef(lhs, q.ac, q.cxt, q.dt) return .NEVER_OVERFLOWS;
    c := is_implied_by_dom_condition_pred(ICMP_UGE, false, lhs, rhs, q.cxt);
    if c >= 0 { if c == 1 return .NEVER_OVERFLOWS; return .ALWAYS_OVERFLOWS_LOW; }
    lr := compute_constant_range_including_known_bits(lhs, false, q);
    rr := compute_constant_range_including_known_bits(rhs, false, q);
    return cr_unsigned_sub_may_overflow(lr, rr);
}
compute_overflow_for_signed_sub :: (lhs: Value_Id, rhs: Value_Id, q: Simplify_Query) -> Overflow_Result {
    oku, ua, _ := pm_binop(rhs, .SREM);
    oks, sa, _ := pm_binop(rhs, .SUB);
    if (oku && ua == lhs) || (oks && (opr_flags(rhs) & F_NSW) != 0 && sa == lhs)
        if is_guaranteed_not_to_be_undef(lhs, q.ac, q.cxt, q.dt) return .NEVER_OVERFLOWS;
    if num_sign_bits(lhs, q) > 1 && num_sign_bits(rhs, q) > 1 return .NEVER_OVERFLOWS;
    lr := compute_constant_range_including_known_bits(lhs, true, q);
    rr := compute_constant_range_including_known_bits(rhs, true, q);
    return cr_signed_sub_may_overflow(lr, rr);
}

// ---------------------------------------------------------------- poison and undef

Undef_Poison_Kind :: enum u8 { POISON_ONLY :: 1; UNDEF_ONLY :: 2; UNDEF_OR_POISON :: 3; }
includes_poison :: inline (k: Undef_Poison_Kind) -> bool { return (cast(u8) k & 1) != 0; }
includes_undef :: inline (k: Undef_Poison_Kind) -> bool { return (cast(u8) k & 2) != 0; }

// shiftAmountKnownInRange
shift_amount_known_in_range :: (amt: Value_Id) -> bool {
    if !is_const(amt) return false;
    t := vtype(amt);
    if type_kind(t) == .SVECTOR return false;
    check :: (c: Value_Id) -> bool { return c != NONE && vkind(c) == .C_INT && ap_ult_u64(const_ap(c), type_int_width(scalar_type(vtype(c)))); }
    if type_kind(t) == .VECTOR {
        n := type_count(t);
        for i: 0..cast(s64) n - 1 if !check(cf_elt(amt, cast(u64) i)) return false;
        return true;
    }
    return check(amt);
}
// Operator::hasPoisonGeneratingAnnotations: flags, poison-generating return attributes, !range/!nonnull/!align
has_poison_generating_annotations :: (v: Value_Id) -> bool {
    if has_poison_generating_flags(v) return true;
    if !is_inst(v) return false;
    if is_call_base(v) {
        // Instruction::hasPoisonGeneratingAttributes: the call site's return and parameter attributes only
        has :: (s: u32) -> bool { for k: Attr_Kind.[.Range, .Alignment, .NonNull, .NoFPClass] if attr_set_has(s, k) return true; return false; }
        if has(attr_list_ret(inst(v).attrs)) return true;
        n := call_num_args(v);
        if n > 0 for a: 0..n-1 if has(attr_list_param(inst(v).attrs, a)) return true;
    }
    // Metadata::PoisonGeneratingIDs
    return inst_md(v, "range") != NONE || inst_md(v, "nonnull") != NONE || inst_md(v, "align") != NONE || inst_md(v, "nofpclass") != NONE;
}
// Operator::hasPoisonGeneratingFlags
has_poison_generating_flags :: (v: Value_Id) -> bool {
    o := opr_code(v);
    f := opr_flags(v);
    if o == {
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .SHL; return (f & (F_NUW | F_NSW)) != 0;
        case .UDIV; #through; case .SDIV; #through; case .ASHR; #through; case .LSHR; return (f & F_EXACT) != 0;
        case .OR; return (f & F_EXACT) != 0;
        case .GEP; return (f & (F_INBOUNDS | F_NUSW | F_GEP_NUW)) != 0 || (f & F_INRANGE) != 0;
        case .UITOFP; #through; case .ZEXT; return (f & F_EXACT) != 0;
        case .TRUNC; return (f & (F_NUW | F_NSW)) != 0;
        case .ICMP; return (f & F_EXACT) != 0;
    }
    if is_fp_math_operator(v) { fm := inst_fmf(v); return (fm & (FMF_NNAN | FMF_NINF)) != 0; }
    return false;
}
// canCreateUndefOrPoison
can_create_undef_or_poison_kind :: (v: Value_Id, kind: Undef_Poison_Kind, consider_flags: bool) -> bool {
    if consider_flags && includes_poison(kind) && has_poison_generating_annotations(v) return true;
    opc := opr_code(v);
    if opc == {
        case .SHL; #through; case .ASHR; #through; case .LSHR;
            return includes_poison(kind) && !shift_amount_known_in_range(op(v, 1));
        case .FPTOSI; #through; case .FPTOUI; return true;
        case .CALL;
            id := call_iid(v);
            if id == IID_CTLZ || id == IID_CTTZ || id == IID_ABS return false;
            if id == IID_SSHL_SAT || id == IID_USHL_SAT {
                if !includes_poison(kind) || shift_amount_known_in_range(op(v, 1)) return false;
            }
            #through;
        case .CALLBR; #through;
        case .INVOKE;
            return !call_has_ret_attr(v, .NoUndef) && !call_has_fn_attr(v, .NoCreateUndefOrPoison);
        case .INSERTELEMENT; #through;
        case .EXTRACTELEMENT;
            vt := vtype(op(v, 0));
            idx := op(v, ifx opc == .INSERTELEMENT then cast(u32) 2 else 1);
            if includes_poison(kind) return !is_scalar_const_int(idx) || ap_uge_u64(const_ap(idx), type_count(vt));
            return false;
        case .SHUFFLEVECTOR;
            if !includes_poison(kind) return false;
            for shuffle_mask(v) if it == POISON_MASK_ELEM return true;
            return false;
        case .FNEG; #through; case .PHI; #through; case .SELECT; #through; case .EXTRACTVALUE; #through;
        case .INSERTVALUE; #through; case .FREEZE; #through; case .ICMP; #through; case .FCMP; #through; case .GEP;
            return false;
        case .ADDRSPACECAST; return true;
    }
    if is_cast_op(opc) return false;
    if is_binary_op(opc) return false;
    return true;
}
can_create_undef_or_poison :: (v: Value_Id, consider_flags := true) -> bool { return can_create_undef_or_poison_kind(v, .UNDEF_OR_POISON, consider_flags); }
can_create_poison :: (v: Value_Id, consider_flags := true) -> bool { return can_create_undef_or_poison_kind(v, .POISON_ONLY, consider_flags); }

// intrinsicPropagatesPoison
intrinsic_propagates_poison :: (id: Intrinsic_Id) -> bool {
    if id == {
        case IID_SADD_WITH_OVERFLOW; #through; case IID_SSUB_WITH_OVERFLOW; #through; case IID_SMUL_WITH_OVERFLOW; #through;
        case IID_UADD_WITH_OVERFLOW; #through; case IID_USUB_WITH_OVERFLOW; #through; case IID_UMUL_WITH_OVERFLOW; #through;
        case IID_CTPOP; #through; case IID_CTLZ; #through; case IID_CTTZ; #through; case IID_ABS; #through;
        case IID_SMAX; #through; case IID_SMIN; #through; case IID_UMAX; #through; case IID_UMIN; #through;
        case IID_SCMP; #through; case IID_IS_FPCLASS; #through; case IID_PTRMASK; #through; case IID_UCMP; #through;
        case IID_BITREVERSE; #through; case IID_BSWAP; #through; case IID_SADD_SAT; #through; case IID_SSUB_SAT; #through;
        case IID_SSHL_SAT; #through; case IID_UADD_SAT; #through; case IID_USUB_SAT; #through; case IID_USHL_SAT; #through;
        case IID_SMUL_FIX; #through; case IID_SMUL_FIX_SAT; #through; case IID_UMUL_FIX; #through; case IID_UMUL_FIX_SAT; #through;
        case IID_POW; #through; case IID_POWI; #through; case IID_SIN; #through; case IID_SINH; #through; case IID_COS; #through;
        case IID_COSH; #through; case IID_SINCOS; #through; case IID_SINCOSPI; #through; case IID_TAN; #through; case IID_TANH; #through;
        case IID_ASIN; #through; case IID_ACOS; #through; case IID_ATAN; #through; case IID_ATAN2; #through;
        case IID_CANONICALIZE; #through; case IID_SQRT; #through; case IID_EXP; #through; case IID_EXP2; #through; case IID_EXP10; #through;
        case IID_LOG; #through; case IID_LOG2; #through; case IID_LOG10; #through; case IID_MODF; #through; case IID_FLOOR; #through;
        case IID_CEIL; #through; case IID_TRUNC; #through; case IID_RINT; #through; case IID_NEARBYINT; #through; case IID_ROUND; #through;
        case IID_ROUNDEVEN; #through; case IID_LRINT; #through; case IID_LLRINT; #through; case IID_FSHL; #through; case IID_FSHR; #through;
        case IID_FREXP; #through; case IID_GET_ACTIVE_LANE_MASK;
            return true;
    }
    return false;
}
// propagatesPoison(const Use &)
propagates_poison :: (user: Value_Id, opno: u32) -> bool {
    o := opr_code(user);
    if o == {
        case .FREEZE; #through; case .PHI; #through; case .INVOKE; return false;
        case .SELECT; return opno == 0;
        case .CALL;
            id := call_iid(user);
            if id != NOT_INTRINSIC return intrinsic_propagates_poison(id);
            return false;
        case .ICMP; #through; case .FCMP; #through; case .GEP; return true;
    }
    if is_inst(user) && (is_binary_op(o) || o == .FNEG || is_cast_op(o)) return true;
    return false;
}
// directlyImpliesPoison
directly_implies_poison :: (val: Value_Id, v: Value_Id, depth: u32) -> bool {
    if val == v return true;
    if depth >= 2 return false;
    if is_inst(v) {
        n := nops(v);
        for k: 0..cast(s64) n - 1 {
            if propagates_poison(v, cast(u32) k) && directly_implies_poison(val, op(v, cast(u32) k), depth + 1) return true;
        }
        // m_ExtractValue(m_WithOverflowInst(II))
        if inst_op(v) == .EXTRACTVALUE && is_with_overflow_inst(op(v, 0)) {
            ii := op(v, 0);
            if is_inst(val) && inst_op(val) == .EXTRACTVALUE && op(val, 0) == ii return true;
            na := call_num_args(ii);
            for k: 0..cast(s64) na - 1 if op(ii, cast(u32) k) == val return true;
        }
    }
    return false;
}
is_with_overflow_inst :: (v: Value_Id) -> bool {
    id := call_iid(v);
    return id == IID_SADD_WITH_OVERFLOW || id == IID_UADD_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW ||
           id == IID_USUB_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW;
}
implies_poison_impl :: (val: Value_Id, v: Value_Id, depth: u32) -> bool {
    if is_guaranteed_not_to_be_poison(val) return true;
    if directly_implies_poison(val, v, 0) return true;
    if depth >= 2 return false;
    if is_inst(val) && !can_create_poison(val) {
        n := nops(val);
        for k: 0..cast(s64) n - 1 if !implies_poison_impl(op(val, cast(u32) k), v, depth + 1) return false;
        return true;
    }
    return false;
}
// impliesPoison
implies_poison :: (val_assumed_poison: Value_Id, v: Value_Id) -> bool { return implies_poison_impl(val_assumed_poison, v, 0); }

// Value::stripPointerCastsSameRepresentation (and the other PSK_* modes)
Strip_Kind :: enum u8 { ZERO_INDICES; ZERO_INDICES_SAME_REPRESENTATION; IN_BOUNDS_CONSTANT_INDICES; IN_BOUNDS; }
strip_pointer_casts_kind :: (v_in: Value_Id, kind: Strip_Kind) -> Value_Id {
    v := v_in;
    if !is_ptr_type(vtype(v)) return v;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        o := opr_code(v);
        if o == .GEP {
            if kind == .ZERO_INDICES || kind == .ZERO_INDICES_SAME_REPRESENTATION {
                if !gep_has_all_zero_indices_v(v) return v;
            } else {
                if kind == .IN_BOUNDS_CONSTANT_INDICES && !gep_has_all_constant_indices(v) return v;
                if (opr_flags(v) & F_INBOUNDS) == 0 return v;
            }
            v = op(v, 0);
        } else if o == .BITCAST {
            nv := op(v, 0);
            if !is_ptr_type(vtype(nv)) return v;
            v = nv;
        } else if kind != .ZERO_INDICES_SAME_REPRESENTATION && o == .ADDRSPACECAST {
            v = op(v, 0);
        } else {
            if is_inst(v) && is_call_base(v) {
                rv := call_returned_arg(v);
                if rv != NONE {
                    v = rv;
                    for visited if it == v return v;
                    array_add(*visited, v);
                    continue;
                }
            }
            return v;
        }
        for visited if it == v return v;
        array_add(*visited, v);
    }
    return v;
}
gep_has_all_zero_indices_v :: (g: Value_Id) -> bool {
    n := nops(g);
    for k: 1..cast(s64) n - 1 { x := op(g, cast(u32) k); if !(is_const(x) && is_null_value(x)) return false; }
    return true;
}
gep_has_all_constant_indices :: (g: Value_Id) -> bool {
    n := nops(g);
    for k: 1..cast(s64) n - 1 if !is_const_int(op(g, cast(u32) k)) return false;
    return true;
}
strip_pointer_casts_same_representation :: (v: Value_Id) -> Value_Id { return strip_pointer_casts_kind(v, .ZERO_INDICES_SAME_REPRESENTATION); }
strip_in_bounds_constant_offsets :: (v: Value_Id) -> Value_Id { return strip_pointer_casts_kind(v, .IN_BOUNDS_CONSTANT_INDICES); }
strip_in_bounds_offsets :: (v: Value_Id) -> Value_Id { return strip_pointer_casts_kind(v, .IN_BOUNDS); }

// GEPOperator::accumulateConstantOffset (no ExternalAnalysis)
gep_accumulate_constant_offset :: (g: Value_Id, offset_in: APInt) -> (bool, APInt) {
    offset := offset_in;
    src := opr_gep_source_type(g);
    n := nops(g);
    if is_int_type(src) && type_int_width(src) == 8 && n > 1 {
        c := op(g, 1);
        if is_scalar_const_int(c) return true, ap_add(offset, ap_sext_or_trunc(const_ap(c), offset.bits));
        return false, offset;
    }
    cur := src;
    for k: 1..cast(s64) n - 1 {
        index := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, index);
        defer cur = indexed;
        scalable := type_is_scalable(indexed);
        if is_scalar_const_int(index) {
            ci := const_ap(index);
            if ap_is_zero(ci) continue;
            if scalable return false, offset;
            if is_struct {
                offset = ap_add(offset, ap_from_u64(offset.bits, dl_struct_offset(cur, cast(u32) ap_zext_value(ci))));
                continue;
            }
            idx := ap_sext_or_trunc(ci, offset.bits);
            offset = ap_add(offset, ap_mul(idx, ap_from_u64(offset.bits, gep_seq_stride(cur, k, indexed))));
            continue;
        }
        return false, offset;
    }
    return true, offset;
}
// gep_type_iterator::getSequentialElementStride: the store size of a vector's element, else the alloc size
// (operand k of the GEP indexes `container`; operand 1 indexes the source type "as an array")
gep_seq_stride :: (container: Type_Id, k: s64, indexed: Type_Id) -> u64 {
    if k > 1 && is_vector_type(container) return dl_type_store_size(indexed);
    return dl_type_alloc_size(indexed);
}
type_is_scalable :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .SVECTOR return true;
    if k == .STRUCT || k == .ARRAY { n := type_nsub(t); for i: 0..cast(s64) n - 1 if type_is_scalable(type_sub(t, cast(u32) i)) return true; }
    return false;
}
// Value::stripAndAccumulateConstantOffsets (ExternalAnalysis = null)
strip_and_accumulate_constant_offsets :: (v_in: Value_Id, offset_in: APInt, allow_non_inbounds: bool, allow_invariant_group := false, look_through_int_to_ptr := false) -> (Value_Id, APInt) {
    v := v_in; offset := offset_in;
    if !is_ptr_type(scalar_type(vtype(v))) return v, offset;
    bw := offset.bits;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        o := opr_code(v);
        if o == .GEP {
            if !allow_non_inbounds && (opr_flags(v) & F_INBOUNDS) == 0 return v, offset;
            ok, go := gep_accumulate_constant_offset(v, ap_zero(dl_index_bits(vtype(v))));
            if !ok return v, offset;
            if ap_min_signed_bits(go) > bw return v, offset;
            offset = ap_add(offset, ap_sext_or_trunc(go, bw));
            v = op(v, 0);
        } else if o == .BITCAST {
            s := op(v, 0);
            if !is_ptr_type(scalar_type(vtype(s))) return v, offset;
            v = s;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else if vkind(v) == .ALIAS {
            if !gv_is_interposable(v) v = op(v, 0);
        } else if is_inst(v) && is_call_base(v) {
            rv := call_returned_arg(v);
            if rv != NONE v = rv;
            if allow_invariant_group {
                id := call_iid(v);
                if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP v = op(v, 0);
            }
        } else if o != .NONE_OP {
            if !allow_non_inbounds || !look_through_int_to_ptr || o != .INTTOPTR || type_bits(scalar_type(vtype(op(v, 0)))) != bw return v, offset;
            add := op(v, 0);
            if opr_code(add) != .ADD return v, offset;
            p2i := op(add, 0); ci := op(add, 1);
            if opr_code(p2i) != .PTRTOINT || !is_scalar_const_int(ci) return v, offset;
            offset = ap_add(offset, const_ap(ci));
            v = op(p2i, 0);
        } else return v, offset;
        for visited if it == v return v, offset;
        array_add(*visited, v);
    }
    return v, offset;
}
strip_and_accumulate_inbounds_constant_offsets :: (v: Value_Id, offset: APInt) -> (Value_Id, APInt) {
    r, o := strip_and_accumulate_constant_offsets(v, offset, false);
    return r, o;
}

// getArgumentAliasingToReturnedPointer / isIntrinsicReturningPointerAliasingArgumentWithoutCapturing
argument_aliasing_to_returned_pointer :: (c: Value_Id, must_preserve_offset: bool) -> Value_Id {
    rv := call_returned_arg(c);
    if rv != NONE return rv;
    id := call_iid(c);
    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP return op(c, 0);
    if id == IID_PTRMASK && !must_preserve_offset return op(c, 0);
    if id == IID_THREADLOCAL_ADDRESS {
        if fn_has_fn_attr(inst_fn(c), .PresplitCoroutine) return NONE;
        return op(c, 0);
    }
    return NONE;
}
// getUnderlyingObject(V, MaxLookup = MaxLookupSearchDepth = 10)
get_underlying_object :: (v_in: Value_Id, max_lookup: u32 = 10) -> Value_Id {
    v := v_in;
    count: u32 = 0;
    while max_lookup == 0 || count < max_lookup {
        count += 1;
        o := opr_code(v);
        if o == .GEP {
            p := op(v, 0);
            if !is_ptr_type(vtype(p)) return v;
            v = p;
        } else if o == .BITCAST || o == .ADDRSPACECAST {
            nv := op(v, 0);
            if !is_ptr_type(vtype(nv)) return v;
            v = nv;
        } else if vkind(v) == .ALIAS {
            if gv_is_interposable(v) return v;
            v = op(v, 0);
        } else {
            if is_phi(v) {
                if nops(v) == 1 { v = phi_value(v, 0); continue; }
            } else if is_inst(v) && is_call_base(v) {
                rp := argument_aliasing_to_returned_pointer(v, false);
                if rp != NONE { v = rp; continue; }
            }
            return v;
        }
    }
    return v;
}

// handleGuaranteedWellDefinedOps: calls `handle` on the operands that must not be undef or poison
handle_guaranteed_well_defined_ops :: (i: Value_Id, data: *void, handle: (*void, Value_Id) -> bool) -> bool {
    o := inst_op(i);
    if o == {
        case .STORE; if handle(data, op(i, 1)) return true;
        case .LOAD; if handle(data, op(i, 0)) return true;
        case .CMPXCHG; if handle(data, op(i, 0)) return true;
        case .ATOMICRMW; if handle(data, op(i, 0)) return true;
        case .CALL; #through;
        case .INVOKE;
            callee := call_callee(i);
            if !is_const(callee) && vkind(callee) != .INLINE_ASM && handle(data, callee) return true;   // isIndirectCall
            n := call_num_args(i);
            for k: 0..cast(s64) n - 1 {
                kk := cast(u32) k;
                if (call_param_has_attr(i, kk, .NoUndef) || call_param_has_attr(i, kk, .Dereferenceable) || call_param_has_attr(i, kk, .DereferenceableOrNull)) && handle(data, op(i, kk)) return true;
            }
        case .RET;
            if nops(i) > 0 && attr_set_has(attr_list_ret(glob(inst_fn(i)).attrs), .NoUndef) && handle(data, op(i, 0)) return true;
        case .SWITCH; if handle(data, op(i, 0)) return true;
        case .CONDBR; if handle(data, op(i, 0)) return true;
    }
    return false;
}
handle_guaranteed_non_poison_ops :: (i: Value_Id, data: *void, handle: (*void, Value_Id) -> bool) -> bool {
    if handle_guaranteed_well_defined_ops(i, data, handle) return true;
    o := inst_op(i);
    if o == .UDIV || o == .SDIV || o == .UREM || o == .SREM return handle(data, op(i, 1));
    return false;
}
// mustTriggerUB(I, KnownPoison)
must_trigger_ub :: (i: Value_Id, known_poison: *Table(Value_Id, bool)) -> bool {
    h :: (d: *void, v: Value_Id) -> bool { return table_contains(cast(*Table(Value_Id, bool)) d, v); }
    return handle_guaranteed_non_poison_ops(i, known_poison, h);
}
// programUndefinedIfUndefOrPoison(V, PoisonOnly)
program_undefined_if_undef_or_poison :: (v: Value_Id, poison_only: bool) -> bool {
    bb: Value_Id; begin: Value_Id;
    if is_inst(v) { bb = inst_block(v); begin = inst_next(v); }
    else if vkind(v) == .ARGUMENT {
        f := arg_parent(v);
        if is_declaration(f) return false;
        bb = fn_entry(f); begin = block_first(bb);
    } else return false;
    scan_limit: u32 = 32;
    if !poison_only {
        x := begin;
        while x != NONE {
            scan_limit -= 1;
            if scan_limit == 0 break;
            target := v;
            h :: (d: *void, w: Value_Id) -> bool { return w == (cast(*Value_Id) d).*; }
            if handle_guaranteed_well_defined_ops(x, *target, h) return true;
            if !is_guaranteed_to_transfer_execution(x) break;
            x = inst_next(x);
        }
        return false;
    }
    yields: Table(Value_Id, bool); yields.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    table_set(*yields, v, true);
    array_add(*visited, bb);
    while true {
        x := begin;
        while x != NONE {
            scan_limit -= 1;
            if scan_limit == 0 return false;
            if must_trigger_ub(x, *yields) return true;
            if !is_guaranteed_to_transfer_execution(x) return false;
            n := nops(x);
            for k: 0..cast(s64) n - 1 {
                if table_contains(*yields, op(x, cast(u32) k)) && propagates_poison(x, cast(u32) k) { table_set(*yields, x, true); break; }
            }
            if inst_op(x) == .SELECT && table_contains(*yields, op(x, 1)) && table_contains(*yields, op(x, 2)) table_set(*yields, x, true);
            x = inst_next(x);
        }
        bb = block_single_successor(bb);
        if bb == NONE break;
        for visited if it == bb return false;
        array_add(*visited, bb);
        begin = block_first_non_phi(bb);
    }
    return false;
}
// BasicBlock::getSingleSuccessor
block_single_successor :: (b: Value_Id) -> Value_Id {
    t := block_terminator(b);
    if t == NONE return NONE;
    n := num_successors(t);
    if n == 0 return NONE;
    s := get_successor(t, 0);
    for i: 1..cast(s64) n - 1 if get_successor(t, cast(u32) i) != s return NONE;
    return s;
}
program_undefined_if_poison :: (i: Value_Id) -> bool { return program_undefined_if_undef_or_poison(i, true); }

// Constant::containsUndefElement / containsPoisonElement / containsUndefOrPoisonElement
contains_undef_element :: (c: Value_Id) -> bool {
    if pm_undef_value(c) return true;
    if vkind(c) == .C_VECTOR { n := nops(c); for i: 0..cast(s64) n - 1 if pm_undef_value(op(c, cast(u32) i)) return true; }
    return false;
}
contains_poison_element :: (c: Value_Id) -> bool {
    if vkind(c) == .C_POISON return true;
    if vkind(c) == .C_VECTOR { n := nops(c); for i: 0..cast(s64) n - 1 if vkind(op(c, cast(u32) i)) == .C_POISON return true; }
    return false;
}

// isGuaranteedNotToBeUndefOrPoison
is_guaranteed_not_to_be_undef_or_poison_kind :: (v: Value_Id, ac: *Assumption_Cache, cxt: Value_Id, dt: *Dom_Tree, depth: u32, kind: Undef_Poison_Kind) -> bool {
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return false;
    k := vkind(v);
    if k == .MD_VALUE return false;
    if k == .ARGUMENT {
        s := arg_attrs(v);
        if attr_set_has(s, .NoUndef) || attr_set_has(s, .Dereferenceable) || attr_set_has(s, .DereferenceableOrNull) return true;
    }
    if is_constant_kind(k) {
        if k == .C_POISON return !includes_poison(kind);
        if k == .C_UNDEF return !includes_undef(kind);
        if k == .C_INT || k == .GLOBAL_VAR || k == .C_FP || k == .C_NULL || k == .FUNCTION {
            if !(k == .C_NULL && is_vector_type(vtype(v))) return true;
        }
        if is_vector_type(vtype(v)) {
            if k == .C_EXPR {
                s := get_splat_value(v);
                if s != NONE && (vkind(s) == .C_INT || vkind(s) == .C_FP) return true;
            } else {
                if includes_undef(kind) && contains_undef_element(v) return false;
                if includes_poison(kind) && contains_poison_element(v) return false;
                return !contains_constant_expression(v);
            }
        }
    }
    sv := strip_pointer_casts_same_representation(v);
    sk := vkind(sv);
    if (is_inst(sv) && inst_op(sv) == .ALLOCA) || sk == .GLOBAL_VAR || sk == .FUNCTION || (sk == .C_NULL && !is_vector_type(vtype(sv))) return true;
    if k == .INST || k == .C_EXPR {
        if is_inst(v) && inst_op(v) == .FREEZE return true;
        if is_inst(v) && is_call_base(v) {
            if call_has_ret_attr(v, .NoUndef) || call_has_ret_attr(v, .Dereferenceable) || call_has_ret_attr(v, .DereferenceableOrNull) return true;
        }
        if !can_create_undef_or_poison_kind(v, kind, true) {
            if is_phi(v) {
                n := nops(v);
                well := true;
                for i: 0..n-1 {
                    inc := phi_value(v, i);
                    if inc == v continue;
                    ti := block_terminator(phi_block(v, i));
                    if !is_guaranteed_not_to_be_undef_or_poison_kind(inc, ac, ti, dt, depth + 1, kind) { well = false; break; }
                }
                if well return true;
            } else if is_inst(v) && inst_op(v) == .SHUFFLEVECTOR && vt_get_splat_value(v) != NONE {
                if is_guaranteed_not_to_be_undef_or_poison_kind(vt_get_splat_value(v), ac, cxt, dt, depth + 1, kind) return true;
            } else {
                all := true;
                n := nops(v);
                for i: 0..cast(s64) n - 1 {
                    if !is_guaranteed_not_to_be_undef_or_poison_kind(op(v, cast(u32) i), ac, cxt, dt, depth + 1, kind) { all = false; break; }
                }
                if all return true;
            }
        }
    }
    if is_inst(v) && inst_op(v) == .LOAD {
        if inst_md(v, "noundef") != NONE || inst_md(v, "dereferenceable") != NONE || inst_md(v, "dereferenceable_or_null") != NONE return true;
    }
    if program_undefined_if_undef_or_poison(v, !includes_undef(kind)) return true;
    if cxt == NONE || inst(cxt).parent == NONE || !dt return false;
    n := dt_node(dt, inst_block(cxt));
    if n < 0 return false;
    dom := dt_idom(dt, n);
    if !includes_undef(kind) || is_int_type(vtype(v)) {
        while dom >= 0 && !dt_is_virtual_root(dt, dom) {
            bb := dt_block(dt, dom);
            ti := block_terminator(bb);
            cond: Value_Id = NONE;
            if ti != NONE && (inst_op(ti) == .CONDBR || inst_op(ti) == .SWITCH) cond = op(ti, 0);
            if cond != NONE {
                if cond == v return true;
                if !includes_undef(kind) && opr_code(cond) != .NONE_OP {
                    cn := nops(cond);
                    for kk: 0..cast(s64) cn - 1 if op(cond, cast(u32) kk) == v && propagates_poison(cond, cast(u32) kk) return true;
                }
            }
            dom = dt_idom(dt, dom);
        }
    }
    if ac {
        for e: ac_assumptions_for(ac, v) {
            if vkind(e.assume) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
            i := e.assume;
            kb := e.index;
            if call_bundle_tag(i, kb) != "noundef" continue;
            begin := ir.u32_pool[inst(i).idx + 3 * kb + 1];
            end := ir.u32_pool[inst(i).idx + 3 * kb + 2];
            if end == begin || op(i, begin) != v continue;
            if is_valid_assume_for_context(i, cxt, dt) return true;
        }
    }
    return false;
}
is_guaranteed_not_to_be_undef_or_poison :: (v: Value_Id, ac: *Assumption_Cache = null, cxt: Value_Id = NONE, dt: *Dom_Tree = null, depth: u32 = 0) -> bool {
    return is_guaranteed_not_to_be_undef_or_poison_kind(v, ac, cxt, dt, depth, .UNDEF_OR_POISON);
}
is_guaranteed_not_to_be_poison :: (v: Value_Id, ac: *Assumption_Cache = null, cxt: Value_Id = NONE, dt: *Dom_Tree = null, depth: u32 = 0) -> bool {
    return is_guaranteed_not_to_be_undef_or_poison_kind(v, ac, cxt, dt, depth, .POISON_ONLY);
}
is_guaranteed_not_to_be_undef :: (v: Value_Id, ac: *Assumption_Cache = null, cxt: Value_Id = NONE, dt: *Dom_Tree = null, depth: u32 = 0) -> bool {
    return is_guaranteed_not_to_be_undef_or_poison_kind(v, ac, cxt, dt, depth, .UNDEF_ONLY);
}
