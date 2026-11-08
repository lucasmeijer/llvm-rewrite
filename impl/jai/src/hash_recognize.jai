// HashRecognize: llvm/lib/Analysis/HashRecognize.cpp (recognizeCRC, genSarwateTable, getResult and the
// print<hash-recognize> printer). Used by LoopIdiomRecognize's optimizeCRCLoop.

// RecurrenceInfo
Hr_Recurrence :: struct {
    l: Loop_Id;
    phi: Value_Id = NONE;
    bo: Value_Id = NONE;
    start: Value_Id = NONE;
    step: Value_Id = NONE;
    has_extra_const: bool;
    extra_const: APInt;
}
hr_ok :: (r: *Hr_Recurrence) -> bool { return r.bo != NONE; }   // operator bool

// PolynomialInfo
Hr_Poly :: struct {
    trip_count: u32;
    lhs: Value_Id;
    rhs: APInt;
    computed_value: Value_Id;
    is_big_endian: bool;
    lhs_aux: Value_Id = NONE;
}

// m_ZExtOrTruncOrSelf(m_Specific(P))
hr_zext_or_trunc_or_self_is :: (v: Value_Id, p: Value_Id) -> bool {
    if is_inst(v) && (inst_op(v) == .ZEXT || inst_op(v) == .TRUNC) && op(v, 0) == p return true;
    return v == p;
}
// m_c_Xor(m_ZExtOrTruncOrSelf(m_Specific(A)), m_ZExtOrTruncOrSelf(m_Specific(B)))
hr_is_xor_of :: (v: Value_Id, a: Value_Id, b: Value_Id) -> bool {
    if !is_inst(v) || inst_op(v) != .XOR return false;
    x := op(v, 0); y := op(v, 1);
    if hr_zext_or_trunc_or_self_is(x, a) && hr_zext_or_trunc_or_self_is(y, b) return true;
    return hr_zext_or_trunc_or_self_is(y, a) && hr_zext_or_trunc_or_self_is(x, b);
}
// m_c_Xor(m_Specific(X), m_SpecificInt(C))
hr_is_xor_with_const :: (v: Value_Id, x: Value_Id, c: APInt) -> bool {
    if !is_inst(v) || inst_op(v) != .XOR return false;
    for side: 0..1 {
        if op(v, cast(u32) side) != x continue;
        ok, k := pm_apint(op(v, cast(u32) (1 - side)));
        if ok && k.bits == c.bits && ap_eq(k, c) return true;
    }
    return false;
}

// containsUnreachable(L, Roots)
hr_contains_unreachable :: (li: *Loop_Info, l: Loop_Id, roots: [] Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    latch := li_loop_latch(li, l);
    work: [..] Value_Id; work.allocator = temp;
    for roots array_add(*work, it);
    while work.count {
        i := pop(*work);
        table_set(*visited, i, true);
        if inst_op(i) == .PHI continue;
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            ui := op(i, cast(u32) k);
            if !is_inst(ui) continue;
            if !li_contains(li, l, inst_block(ui)) return true;
            array_add(*work, ui);
        }
    }
    return block_num_insts(latch) != visited.count;
}
block_num_insts :: (b: Value_Id) -> s64 { n := 0; for block_insts(b) n += 1; return n; }

// isSignificantBitCheckWellFormed
hr_significant_bit_check_well_formed :: (cr: *Hr_Recurrence, sr: *Hr_Recurrence, big_endian: bool) -> bool {
    si := cr.step;
    oks, c, tv, fv := pm_select(si);
    if !oks || !is_inst(tv) || !is_inst(fv) return false;
    okc, pred, ss, lv, rv := pm_icmp(c);
    if !okc return false;
    okr, r := pm_apint(rv);
    if !okr return false;
    match_pred :: (v: Value_Id, cr: *Hr_Recurrence, sr: *Hr_Recurrence) -> bool {
        if v == cr.phi return true;
        return hr_is_xor_of(v, cr.phi, sr.phi);
    }
    well: bool;
    if big_endian well = match_pred(lv, cr, sr);
    else {
        well = false;
        if is_inst(lv) && inst_op(lv) == .AND {
            for side: 0..1 {
                if match_pred(op(lv, cast(u32) side), cr, sr) && pm_one(op(lv, cast(u32) (1 - side))) { well = true; break; }
            }
        }
    }
    if !well return false;
    bw := r.bits;
    rcr := cr_new(r, ap_add(r, ap_one(bw)));   // ConstantRange::fromKnownBits(makeConstant(R), false)
    allowed := cr_allowed_icmp_region_ss(pred, ss, rcr);
    check := cr_new(ap_zero(bw), ifx big_endian then ap_signed_min(bw) else ap_one(bw));
    bit_shift := cr.bo;
    if cr_eq(allowed, check) return tv == bit_shift && hr_is_xor_with_const(fv, bit_shift, cr.extra_const);
    if cr_eq(cr_inverse(allowed), check) return fv == bit_shift && hr_is_xor_with_const(tv, bit_shift, cr.extra_const);
    return false;
}

// RecurrenceInfo::matchSimpleRecurrence
hr_match_simple_recurrence :: (r: *Hr_Recurrence, p: Value_Id) -> bool {
    ok, bo, start, step := match_simple_recurrence(p);
    if ok { r.bo = bo; r.start = start; r.step = step; r.phi = p; return true; }
    return false;
}

// RecurrenceInfo::digRecurrence (BOWithConstOpToMatch = Xor or none)
hr_dig_recurrence :: (r: *Hr_Recurrence, li: *Loop_Info, v: Value_Id, match_xor: bool) -> Value_Id {
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, v);
    while work.count {
        i := pop(*work);
        if inst_op(i) == .PHI continue;
        if is_binary_op(inst_op(i)) && (op(i, 0) == r.phi || op(i, 1) == r.phi) return i;   // m_c_BinOp(m_Value(), m_Specific(Phi))
        if match_xor && inst_op(i) == .XOR {
            if r.has_extra_const return NONE;
            for side: 0..1 {
                ok, c := pm_apint(op(i, cast(u32) side));
                if ok { r.has_extra_const = true; r.extra_const = c; break; }
            }
        }
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            ui := op(i, cast(u32) k);
            if is_inst(ui) && li_contains(li, r.l, inst_block(ui)) array_add(*work, ui);
        }
    }
    return NONE;
}

// RecurrenceInfo::matchConditionalRecurrence(P, Xor)
hr_match_conditional_recurrence :: (r: *Hr_Recurrence, li: *Loop_Info, p: Value_Id) -> bool {
    r.phi = p;
    if nops(p) != 2 return false;
    for idx: 0..1 {
        found_step := op(p, cast(u32) idx);
        found_start := op(p, cast(u32) (1 - idx));
        oks, c, tv, fv := pm_select(found_step);
        if !oks || !is_inst(c) || !(inst_op(c) == .ICMP || inst_op(c) == .FCMP) || !is_inst(tv) || !is_inst(fv) continue;
        found_bo := hr_dig_recurrence(r, li, tv, true);
        alt_bo := hr_dig_recurrence(r, li, fv, true);
        if found_bo == NONE || found_bo != alt_bo return false;
        if !r.has_extra_const return false;
        r.bo = found_bo; r.start = found_start; r.step = found_step;
        return true;
    }
    return false;
}

// isConditionalOnXorOfPHIs
hr_conditional_on_xor_of_phis :: (li: *Loop_Info, l: Loop_Id, si: Value_Id, p1: Value_Id, p2: Value_Id) -> bool {
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, op(si, 0));
    while work.count {
        i := pop(*work);
        if inst_op(i) == .PHI continue;
        if hr_is_xor_of(i, p1, p2) return true;
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            ui := op(i, cast(u32) k);
            if is_inst(ui) && li_contains(li, l, inst_block(ui)) array_add(*work, ui);
        }
    }
    return false;
}

// isBigEndianBitShift: 1 = big endian, 0 = little endian, -1 = neither
hr_big_endian_bit_shift :: (v: Value_Id) -> s32 {
    if !is_int_type(vtype(v)) return -1;
    e := sc_get_scev(v);
    if sc_is_udiv(e) && sc_nops(e) == 2 && sc_is_const(sc_op(e, 1)) && ap_fits_u64(sc_ap(sc_op(e, 1))) && ap_zext_value(sc_ap(sc_op(e, 1))) == 2 return 0;
    if sc_is_mul(e) && sc_nops(e) == 2 && sc_is_const(sc_op(e, 0)) && ap_fits_u64(sc_ap(sc_op(e, 0))) && ap_zext_value(sc_ap(sc_op(e, 0))) == 2 return 1;
    return -1;
}

// HashRecognize::recognizeCRC: (found, info, reason)
hash_recognize_crc :: (li: *Loop_Info, l: Loop_Id) -> (bool, Hr_Poly, string) {
    info: Hr_Poly;
    if li_subloops(li, l).count != 0 return false, info, "Loop is not innermost";
    latch := li_loop_latch(li, l);
    exit := li_exit_block(li, l);
    ind_var := li_canonical_induction_variable(li, l);
    if latch == NONE || exit == NONE || ind_var == NONE || li_blocks(li, l).count != 1 return false, info, "Loop not in canonical form";
    tc := sc_get_small_constant_trip_count(l);
    if tc == 0 || tc % 8 != 0 return false, info, "Unable to find a small constant byte-multiple trip count";
    // getRecurrences
    num_phis := 0;
    for i: block_insts(latch) { if inst_op(i) != .PHI break; num_phis += 1; }
    if num_phis != 2 && num_phis != 3 return false, info, "Found stray PHI";
    sr: Hr_Recurrence; sr.l = l;
    cr: Hr_Recurrence; cr.l = l;
    for p: block_insts(latch) {
        if inst_op(p) != .PHI break;
        if p == ind_var continue;
        if !hr_ok(*sr) hr_match_simple_recurrence(*sr, p);
        if !hr_ok(*cr) hr_match_conditional_recurrence(*cr, li, p);
    }
    if num_phis == 3 && (!hr_ok(*sr) || !hr_ok(*cr)) return false, info, "Found stray PHI";
    if !hr_ok(*cr) return false, info, "Unable to find conditional recurrence";
    be := hr_big_endian_bit_shift(cr.bo);
    if be < 0 return false, info, "Loop with non-unit bitshifts";
    if hr_ok(*sr) {
        if hr_big_endian_bit_shift(sr.bo) != be return false, info, "Loop with non-unit bitshifts";
        if !has_n_uses(cr.phi, 2) || !has_n_uses(sr.phi, 2) || unique_undroppable_user(sr.bo) != sr.phi
            return false, info, "Recurrences have stray uses";
        if !hr_conditional_on_xor_of_phis(li, l, cr.step, sr.phi, cr.phi) return false, info, "Recurrences not intertwined with XOR";
    }
    lhs := cr.start;
    lhs_aux: Value_Id = ifx hr_ok(*sr) then sr.start else NONE;
    if be == 1 && lhs_aux != NONE && type_int_width(vtype(lhs_aux)) < type_int_width(vtype(lhs)) lhs_aux = NONE;
    limit := ifx lhs_aux != NONE then type_int_width(vtype(lhs_aux)) else type_int_width(vtype(lhs));
    if tc > limit return false, info, "Loop iterations exceed bitwidth of data";
    computed := cr.step;
    used_in_exit := false;
    u := ir.v_first_use[computed];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) && inst_block(usr) == exit { used_in_exit = true; break; }
        u = ir.u_next[u];
    }
    if !used_in_exit return false, info, "Unable to find use of computed value in loop exit block";
    if !hr_significant_bit_check_well_formed(*cr, *sr, be == 1) return false, info, "Malformed significant-bit check";
    roots: [..] Value_Id; roots.allocator = temp;
    array_add(*roots, computed);
    array_add(*roots, phi_incoming_for_block(ind_var, latch));
    array_add(*roots, li_latch_cmp_inst(li, l));
    array_add(*roots, block_terminator(latch));
    if hr_ok(*sr) array_add(*roots, sr.bo);
    if hr_contains_unreachable(li, l, roots) return false, info, "Found stray unvisited instructions";
    info.trip_count = tc;
    info.lhs = lhs;
    info.rhs = cr.extra_const;
    info.computed_value = computed;
    info.is_big_endian = be == 1;
    info.lhs_aux = lhs_aux;
    return true, info, "";
}

// Value::getUniqueUndroppableUser
unique_undroppable_user :: (v: Value_Id) -> Value_Id {
    result: Value_Id = NONE;
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        if !(is_inst(usr) && inst_is_droppable(usr)) {
            if result != NONE && result != usr return NONE;
            result = usr;
        }
        u = ir.u_next[u];
    }
    return result;
}

// HashRecognize::genSarwateTable
hr_gen_sarwate_table :: (gen_poly: APInt, big_endian: bool) -> [256] APInt {
    bw := gen_poly.bits;
    t: [256] APInt;
    t[0] = ap_zero(bw);
    if big_endian {
        crc := ap_signed_min(bw);
        i := 1;
        while i < 256 {
            crc = ap_xor(ap_shl(crc, 1), ifx ap_is_negative(crc) then gen_poly else ap_zero(bw));
            for j: 0..i-1 t[i + j] = ap_xor(crc, t[j]);
            i <<= 1;
        }
        return t;
    }
    crc := ap_one(bw);
    i := 128;
    while i > 0 {
        crc = ap_xor(ap_lshr(crc, 1), ifx ap_get_bit(crc, 0) then gen_poly else ap_zero(bw));
        j := 0;
        while j < 256 { t[i + j] = ap_xor(crc, t[j]); j += i << 1; }
        i >>= 1;
    }
    return t;
}
