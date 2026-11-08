// ScalarEvolution, part 3: ranges, constant multiples and no-wrap inference.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): getConstantMultiple(Impl), getMinTrailingZeros,
// GetRangeFromMetadata, getRangeForUnknownRecurrence, getRangeRefIter, getRangeRef, getRangeForAffineARHelper,
// getRangeForAffineAR, getRangeForAffineNoSelfWrappingAR, getRangeViaFactoring, inferNoWrapViaConstantRanges,
// proveNoSignedWrapViaInduction / proveNoUnsignedWrapViaInduction, isKnownNegative / Positive / NonZero ...,
// and ConstantRange::print.

HINT_UNSIGNED :: false;
HINT_SIGNED :: true;

// ConstantRange::print
cr_print_to :: (sb: *String_Builder, r: Const_Range) {
    if cr_is_full_set(r) { append(sb, "full-set"); return; }
    if cr_is_empty_set(r) { append(sb, "empty-set"); return; }
    append(sb, "["); append(sb, ap_to_string_signed(r.lo)); append(sb, ","); append(sb, ap_to_string_signed(r.hi)); append(sb, ")");
}

cr_heap :: (r: Const_Range) -> Const_Range {
    o: Const_Range;
    o.lo = ap_heap_copy(r.lo);
    o.hi = ap_heap_copy(r.hi);
    return o;
}
// setRange
sc_set_range :: (s: Scev_Id, signed: bool, r: Const_Range) -> Const_Range {
    h := cr_heap(r);
    if signed table_set(*se.signed_ranges, s, h); else table_set(*se.unsigned_ranges, s, h);
    return r;
}

sc_unsigned_range :: (s: Scev_Id) -> Const_Range { return sc_get_range_ref(s, HINT_UNSIGNED); }
sc_signed_range :: (s: Scev_Id) -> Const_Range { return sc_get_range_ref(s, HINT_SIGNED); }
sc_unsigned_range_min :: (s: Scev_Id) -> APInt { return cr_umin(sc_unsigned_range(s)); }
sc_unsigned_range_max :: (s: Scev_Id) -> APInt { return cr_umax(sc_unsigned_range(s)); }
sc_signed_range_min :: (s: Scev_Id) -> APInt { return cr_smin(sc_signed_range(s)); }
sc_signed_range_max :: (s: Scev_Id) -> APInt { return cr_smax(sc_signed_range(s)); }

sc_is_known_negative :: (s: Scev_Id) -> bool { return ap_is_negative(sc_signed_range_max(s)); }
sc_is_known_positive :: (s: Scev_Id) -> bool { return ap_is_strictly_positive(sc_signed_range_min(s)); }
sc_is_known_non_negative :: (s: Scev_Id) -> bool { return !ap_is_negative(sc_signed_range_min(s)); }
sc_is_known_non_positive :: (s: Scev_Id) -> bool { return !ap_is_strictly_positive(sc_signed_range_max(s)); }
sc_is_known_non_zero :: (s: Scev_Id) -> bool {
    if sc_is_sext(s) return sc_is_known_non_zero(sc_op(s, 0));
    return !ap_is_zero(sc_unsigned_range_min(s));
}
// isKnownToBeAPowerOfTwo
sc_is_known_to_be_a_power_of_two :: (s: Scev_Id, or_zero := false, or_negative := false) -> bool {
    non_recursive :: (s: Scev_Id, or_negative: bool) -> bool {
        if sc_is_const(s) { c := sc_ap(s); return ap_is_power_of_2(c) || (or_negative && ap_is_negated_power_of_2(c)); }
        return sc_kind(s) == .VSCALE;
    }
    if non_recursive(s, or_negative) return true;
    if !sc_is_mul(s) return false;
    for i: 0..cast(s64) sc_nops(s) - 1 if !non_recursive(sc_op(s, cast(u32) i), or_negative) return false;
    return or_zero || sc_is_known_non_zero(s);
}
// haveSameSign
sc_have_same_sign :: (a: Scev_Id, b: Scev_Id) -> bool {
    return (sc_is_known_non_negative(a) && sc_is_known_non_negative(b)) || (sc_is_known_negative(a) && sc_is_known_negative(b));
}

// ---------------------------------------------------------------- constant multiples

sc_get_constant_multiple_impl :: (s: Scev_Id, cxt: Value_Id) -> APInt {
    bits := sc_bits(s);
    shifted :: (tz: u32, bits: u32) -> APInt {
        if tz >= bits return ap_zero(bits);
        return ap_one_bit_set(bits, tz);
    }
    gcd_multiple :: (n: Scev_Id, cxt: Value_Id) -> APInt {
        res := sc_get_constant_multiple(sc_op(n, 0), cxt);
        i: u32 = 1;
        while i < sc_nops(n) && !ap_is_one(res) {
            res = ap_gcd(res, sc_get_constant_multiple(sc_op(n, i), cxt));
            i += 1;
        }
        return res;
    }
    k := sc_kind(s);
    if k == {
        case .CONSTANT; return sc_ap(s);
        case .PTRTOADDR; #through;
        case .PTRTOINT; return sc_get_constant_multiple(sc_op(s, 0));
        case .UDIV; #through;
        case .VSCALE; return ap_one(bits);
        case .TRUNC; return shifted(sc_get_min_trailing_zeros(sc_op(s, 0), cxt), bits);
        case .ZEXT; return ap_zext(sc_get_constant_multiple(sc_op(s, 0), cxt), bits);
        case .SEXT; return shifted(sc_get_min_trailing_zeros(sc_op(s, 0), cxt), bits);
        case .MUL;
            if sc_has_nuw(s) {
                res := sc_get_constant_multiple(sc_op(s, 0), cxt);
                for i: 1..cast(s64) sc_nops(s) - 1 res = ap_mul(res, sc_get_constant_multiple(sc_op(s, cast(u32) i), cxt));
                return res;
            }
            tz: u32 = 0;
            for i: 0..cast(s64) sc_nops(s) - 1 tz += sc_get_min_trailing_zeros(sc_op(s, cast(u32) i), cxt);
            return shifted(tz, bits);
        case .ADD; #through;
        case .ADDREC;
            if sc_has_nuw(s) return gcd_multiple(s, cxt);
            tz := sc_get_min_trailing_zeros(sc_op(s, 0), cxt);
            for i: 1..cast(s64) sc_nops(s) - 1 tz = min(tz, sc_get_min_trailing_zeros(sc_op(s, cast(u32) i), cxt));
            return shifted(tz, bits);
        case .UMAX; #through; case .SMAX; #through; case .UMIN; #through; case .SMIN; #through;
        case .SEQ_UMIN; return gcd_multiple(s, cxt);
        case .UNKNOWN;
            v := sc_value(s);
            c := cxt;
            if c == NONE {
                if vkind(v) == .ARGUMENT c = block(fn_entry(se.fn)).first;
                else if is_inst(v) c = v;
            }
            q: Simplify_Query;
            q.dt = se.dt; q.ac = se.ac; q.cxt = c; q.allow_ephemerals = true;
            known := kb_count_min_trailing_zeros(known_bits(v, q));
            return shifted(known, bits);
    }
    fatal("ScalarEvolution: getConstantMultiple of CouldNotCompute");
    return ap_zero(1);
}
sc_get_constant_multiple :: (s: Scev_Id, cxt: Value_Id = NONE) -> APInt {
    if cxt != NONE return sc_get_constant_multiple_impl(s, cxt);
    found, r := table_find(*se.const_multiple, s);
    if found return r;
    res := sc_get_constant_multiple_impl(s, cxt);
    table_set(*se.const_multiple, s, ap_heap_copy(res));
    return res;
}
sc_get_non_zero_constant_multiple :: (s: Scev_Id) -> APInt {
    m := sc_get_constant_multiple(s);
    if ap_is_zero(m) return ap_one(m.bits);
    return m;
}
sc_get_min_trailing_zeros :: (s: Scev_Id, cxt: Value_Id = NONE) -> u32 {
    return min(ap_ctz(sc_get_constant_multiple(s, cxt)), sc_bits(s));
}

// ---------------------------------------------------------------- ranges

// GetRangeFromMetadata
get_range_from_metadata :: (v: Value_Id) -> (bool, Const_Range) {
    none: Const_Range;
    if is_inst(v) {
        md := inst_md(v, "range");
        if md != NONE return true, cr_from_range_md(md);
        if inst_op(v) == .CALL || inst_op(v) == .INVOKE || inst_op(v) == .CALLBR {
            ok, r := call_range(v);
            if ok return true, r;
        }
    }
    if vkind(v) == .ARGUMENT {
        ok, r := arg_range(v);
        if ok return true, r;
    }
    return false, none;
}

// getRangeForUnknownRecurrence
sc_get_range_for_unknown_recurrence :: (u: Scev_Id) -> Const_Range {
    bits := sc_bits(u);
    full := cr_full(bits);
    p := sc_value(u);
    if !is_inst(p) || inst_op(p) != .PHI return full;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(inst_block(p), *preds);
    for preds if !dt_is_reachable_from_entry(se.dt, it) return full;
    ok, bo, start, step := match_simple_recurrence(p);
    if !ok return full;
    l := li_loop_for(se.li, inst_block(p));
    if !li_contains(se.li, l, inst_block(bo)) return full;
    opc := inst_op(bo);
    if opc != .ASHR && opc != .LSHR && opc != .SHL return full;
    if op(bo, 0) != p return full;
    tc := sc_get_small_constant_max_trip_count(l);
    if tc == 0 || tc >= bits return full;
    known_start := known_bits_ctx(start, NONE, se.dt, se.ac);
    known_step := known_bits_ctx(step, NONE, se.dt, se.ac);
    max_shift_amt := kb_max_value(known_step);
    tcap := ap_from_u64(bits, cast(u64) (tc - 1));
    total_shift, overflow := ap_umul_ov(max_shift_amt, tcap);
    if overflow return full;
    total_kb := kb_make(ap_not(total_shift), total_shift);
    if opc == {
        case .ASHR;
            known_end := kb_ashr(known_start, total_kb);
            if kb_is_non_negative(known_start) return cr_non_empty(kb_min_value(known_end), ap_add_u64(kb_max_value(known_start), 1));
            if kb_is_negative(known_start) return cr_non_empty(kb_min_value(known_start), ap_add_u64(kb_max_value(known_end), 1));
        case .LSHR;
            known_end := kb_lshr(known_start, total_kb);
            return cr_non_empty(kb_min_value(known_end), ap_add_u64(kb_max_value(known_start), 1));
        case .SHL;
            known_end := kb_shl(known_start, total_kb);
            if ap_ult_u64(total_shift, cast(u64) kb_count_min_leading_zeros(known_start))
                return cr_new(kb_min_value(known_start), ap_add_u64(kb_max_value(known_end), 1));
    }
    return full;
}

// getRangeRefIter
sc_get_range_ref_iter :: (s: Scev_Id, signed: bool) -> Const_Range {
    cache := ifx signed then *se.signed_ranges else *se.unsigned_ranges;
    work: [..] Scev_Id; work.allocator = temp;
    seen: Table(Scev_Id, bool); seen.allocator = temp;
    add_to_worklist :: (e: Scev_Id, work: *[..] Scev_Id, seen: *Table(Scev_Id, bool), cache: *Table(Scev_Id, Const_Range)) {
        if table_contains(seen, e) return;
        table_set(seen, e, true);
        if table_contains(cache, e) return;
        if sc_is_unknown(e) {
            v := sc_value(e);
            if !(is_inst(v) && inst_op(v) == .PHI) return;
        }
        array_add(work, e);
    }
    add_to_worklist(s, *work, *seen, cache);
    i := 0;
    while i != work.count {
        p := work[i];
        i += 1;
        if !sc_is_unknown(p) {
            k := sc_kind(p);
            if k != .CONSTANT && k != .VSCALE
                for j: 0..cast(s64) sc_nops(p) - 1 add_to_worklist(sc_op(p, cast(u32) j), *work, *seen, cache);
            continue;
        }
        phi := sc_value(p);
        if is_inst(phi) && inst_op(phi) == .PHI {
            if !range_ref_phi_allowed_operands(phi) continue;
            for < j: 0..cast(s64) nops(phi) - 1 add_to_worklist(sc_get_scev(op(phi, cast(u32) j)), *work, *seen, cache);
        }
    }
    if work.count > 0 {
        for < j: 1..work.count-1 sc_get_range_ref(work[j], signed);
    }
    return sc_get_range_ref(s, signed, 0);
}

sc_get_range_ref :: (s: Scev_Id, signed: bool, depth: u32 = 0) -> Const_Range {
    cache := ifx signed then *se.signed_ranges else *se.unsigned_ranges;
    range_type := ifx signed then Preferred_Range.SIGNED else .UNSIGNED;
    found, cached := table_find(cache, s);
    if found return cached;
    if sc_is_const(s) return sc_set_range(s, signed, cr_single(sc_ap(s)));
    if cast(u64) depth > scev_opts.range_iter_threshold return sc_get_range_ref_iter(s, signed);

    bits := sc_bits(s);
    conservative := cr_full(bits);
    if !signed {
        multiple := sc_get_non_zero_constant_multiple(s);
        remainder := ap_urem(ap_all_ones(bits), multiple);
        if !ap_is_zero(remainder) conservative = cr_new(ap_zero(bits), ap_add_u64(ap_sub(ap_all_ones(bits), remainder), 1));
    } else {
        tz := sc_get_min_trailing_zeros(s);
        if tz != 0 conservative = cr_new(ap_signed_min(bits), ap_add_u64(ap_shl(ap_ashr(ap_signed_max(bits), tz), tz), 1));
    }

    k := sc_kind(s);
    if k == {
        case .VSCALE; return sc_set_range(s, signed, get_vscale_range(se.fn, bits));
        case .TRUNC;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            return sc_set_range(s, signed, cr_intersect(conservative, cr_truncate(x, bits), range_type));
        case .ZEXT;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            return sc_set_range(s, signed, cr_intersect(conservative, cr_zero_extend(x, bits), range_type));
        case .SEXT;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            return sc_set_range(s, signed, cr_intersect(conservative, cr_sign_extend(x, bits), range_type));
        case .PTRTOADDR; #through;
        case .PTRTOINT;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            return sc_set_range(s, signed, x);
        case .ADD;
            if !signed {
                ok, ul, ur := match_urem(s);
                if ok {
                    lr := sc_get_range_ref(ul, signed, depth + 1);
                    rr := sc_get_range_ref(ur, signed, depth + 1);
                    conservative = cr_intersect(conservative, cr_urem(lr, rr), range_type);
                }
            }
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            wrap_type: u32 = 0;
            if sc_has_nsw(s) wrap_type |= NW_NSW;
            if sc_has_nuw(s) wrap_type |= NW_NUW;
            for i: 1..cast(s64) sc_nops(s) - 1
                x = cr_add_with_no_wrap(x, sc_get_range_ref(sc_op(s, cast(u32) i), signed, depth + 1), wrap_type, range_type);
            return sc_set_range(s, signed, cr_intersect(conservative, x, range_type));
        case .MUL;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            for i: 1..cast(s64) sc_nops(s) - 1 x = cr_multiply(x, sc_get_range_ref(sc_op(s, cast(u32) i), signed, depth + 1));
            return sc_set_range(s, signed, cr_intersect(conservative, x, range_type));
        case .UDIV;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            y := sc_get_range_ref(sc_op(s, 1), signed, depth + 1);
            return sc_set_range(s, signed, cr_intersect(conservative, cr_udiv(x, y), range_type));
        case .ADDREC;
            add_rec := s;
            if sc_has_nuw(add_rec) {
                umin := sc_unsigned_range_min(sc_start(add_rec));
                if !ap_is_zero(umin) conservative = cr_intersect(conservative, cr_new(umin, ap_zero(bits)), range_type);
            }
            if sc_has_nsw(add_rec) {
                all_non_neg := true;
                all_non_pos := true;
                for i: 1..cast(s64) sc_nops(add_rec) - 1 {
                    o := sc_op(add_rec, cast(u32) i);
                    if !sc_is_known_non_negative(o) all_non_neg = false;
                    if !sc_is_known_non_positive(o) all_non_pos = false;
                }
                if all_non_neg
                    conservative = cr_intersect(conservative, cr_non_empty(sc_signed_range_min(sc_start(add_rec)), ap_signed_min(bits)), range_type);
                else if all_non_pos
                    conservative = cr_intersect(conservative, cr_non_empty(ap_signed_min(bits), ap_add_u64(sc_signed_range_max(sc_start(add_rec)), 1)), range_type);
            }
            if sc_is_affine(add_rec) {
                max_be_scev := sc_get_constant_max_backedge_taken_count(sc_loop(add_rec));
                if max_be_scev != SCEV_CNC {
                    max_be_count := sc_ap(max_be_scev);
                    if max_be_count.bits > bits && ap_active_bits(max_be_count) <= bits max_be_count = ap_trunc(max_be_count, bits);
                    else if max_be_count.bits < bits max_be_count = ap_zext(max_be_count, bits);
                    if max_be_count.bits == bits {
                        range_from_affine, flags := sc_get_range_for_affine_ar(sc_start(add_rec), sc_step_recurrence(add_rec), max_be_count);
                        conservative = cr_intersect(conservative, range_from_affine, range_type);
                        // SCEVAddRecExpr::setNoWrapFlags (the caches are not cleared)
                        f := flags;
                        if f & (SF_NUW | SF_NSW) f |= SF_NW;
                        if SCEV_DEBUG && (sc_row(add_rec).flags | f) != sc_row(add_rec).flags print("range flags % += %\n", sc_to_string(add_rec), f);
                        sc_row(add_rec).flags |= f;
                        range_from_factoring := sc_get_range_via_factoring(sc_start(add_rec), sc_step_recurrence(add_rec), max_be_count);
                        conservative = cr_intersect(conservative, range_from_factoring, range_type);
                    }
                }
                if scev_opts.use_expensive_range_sharpening {
                    symbolic_max := sc_get_symbolic_max_backedge_taken_count(sc_loop(add_rec));
                    if symbolic_max != SCEV_CNC && sc_bits(max_be_scev_or(max_be_scev, symbolic_max)) <= bits && sc_has_nw(add_rec) {
                        r := sc_get_range_for_affine_no_self_wrapping_ar(add_rec, symbolic_max, bits, signed);
                        conservative = cr_intersect(conservative, r, range_type);
                    }
                }
            }
            return sc_set_range(add_rec, signed, conservative);
        case .UMAX; #through; case .SMAX; #through; case .UMIN; #through; case .SMIN; #through;
        case .SEQ_UMIN;
            x := sc_get_range_ref(sc_op(s, 0), signed, depth + 1);
            for i: 1..cast(s64) sc_nops(s) - 1 {
                y := sc_get_range_ref(sc_op(s, cast(u32) i), signed, depth + 1);
                if k == {
                    case .UMAX; x = cr_umax_op(x, y);
                    case .SMAX; x = cr_smax_op(x, y);
                    case .SMIN; x = cr_smin_op(x, y);
                    case; x = cr_umin_op(x, y);
                }
            }
            return sc_set_range(s, signed, cr_intersect(conservative, x, range_type));
        case .UNKNOWN;
            v := sc_value(s);
            {
                ok, mdr := get_range_from_metadata(v);
                if ok conservative = cr_intersect(conservative, mdr, range_type);
            }
            cr := sc_get_range_for_unknown_recurrence(s);
            conservative = cr_intersect(conservative, cr);
            known := known_bits_ctx(v, NONE, se.dt, se.ac);
            if known.zero.bits != bits known = kb_zext_or_trunc(known, bits);
            ns := num_sign_bits_ctx(v, NONE, se.dt, se.ac);
            if type_kind(vtype(v)) == .PTR {
                ptr_size := dl_ptr_spec(cast(u32) ir.types[vtype(v)].a).bits;
                ptr_idx_diff := cast(s64) ptr_size - cast(s64) bits;
                if ptr_idx_diff > 0 && ptr_size > bits && cast(s64) ns > ptr_idx_diff ns -= cast(u32) ptr_idx_diff;
            }
            if ns > 1 {
                if !ap_is_zero(ap_get_hi_bits(known.zero, ns)) ap_set_high_bits(*known.zero, ns);
                if !ap_is_zero(ap_get_hi_bits(known.one, ns)) ap_set_high_bits(*known.one, ns);
            }
            if !ap_eq(kb_min_value(known), ap_add_u64(kb_max_value(known), 1))
                conservative = cr_intersect(conservative, cr_new(kb_min_value(known), ap_add_u64(kb_max_value(known), 1)), range_type);
            if ns > 1
                conservative = cr_intersect(conservative, cr_new(ap_ashr(ap_signed_min(bits), ns - 1), ap_add_u64(ap_ashr(ap_signed_max(bits), ns - 1), 1)), range_type);
            if type_kind(vtype(v)) == .PTR && !signed {
                can_be_null, deref_bytes := pointer_dereferenceable_bytes(v);
                if deref_bytes > 1 && (bits >= 64 || deref_bytes <= ((cast(u64) 1) << bits) - 1) {
                    max_val := ap_sub(ap_all_ones(bits), ap_from_u64(bits, deref_bytes));
                    align := pointer_alignment(v);
                    rem := ap_urem_u64(max_val, align);
                    max_val = ap_sub(max_val, ap_from_u64(bits, rem));
                    min_val := ap_zero(bits);
                    q: Simplify_Query;
                    if is_known_non_zero(v, q) min_val = ap_from_u64(bits, align);
                    conservative = cr_intersect(conservative, cr_non_empty(min_val, ap_add_u64(max_val, 1)), range_type);
                }
            }
            if is_inst(v) && inst_op(v) == .PHI {
                pv := sc_get_scev(v);
                if sc_is_addrec(pv) return sc_get_range_ref(pv, signed, depth + 1);
                if range_ref_phi_allowed_operands(v) {
                    range_from_ops := cr_empty(bits);
                    for i: 0..cast(s64) nops(v) - 1 {
                        op_range := sc_get_range_ref(sc_get_scev(op(v, cast(u32) i)), signed, depth + 1);
                        range_from_ops = cr_union(range_from_ops, op_range);
                        if cr_is_full_set(range_from_ops) break;
                    }
                    conservative = cr_intersect(conservative, range_from_ops, range_type);
                }
            }
            if is_inst(v) && inst_op(v) == .CALL && call_iid(v) == IID_VSCALE
                conservative = cr_difference(conservative, cr_single(ap_zero(bits)));
            return sc_set_range(s, signed, conservative);
    }
    return sc_set_range(s, signed, conservative);
}
max_be_scev_or :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
    // getTypeSizeInBits(MaxBEScev->getType()): MaxBEScev may be CouldNotCompute in LLVM (a bug that reads the
    // type of SCEVCouldNotCompute); only reached with -scalar-evolution-use-expensive-range-sharpening
    if a == SCEV_CNC { fatal("ScalarEvolution: expensive range sharpening with an unknown constant max backedge-taken count"); }
    return a;
}

// getRangeForAffineARHelper
get_range_for_affine_ar_helper :: (step_in: APInt, start_range: Const_Range, max_be_count: APInt, signed: bool) -> (Const_Range, bool) {
    step := step_in;
    bits := step.bits;
    if ap_is_zero(step) || ap_is_zero(max_be_count) return start_range, true;
    if cr_is_full_set(start_range) return cr_full(bits), false;
    descending := signed && ap_is_negative(step);
    if signed step = ap_abs(step);
    if ap_ult(ap_udiv(ap_all_ones(bits), step), max_be_count) return cr_full(bits), false;
    offset := ap_mul(step, max_be_count);
    start_lower := start_range.lo;
    start_upper := ap_sub_u64(start_range.hi, 1);
    overflow: bool;
    moved_boundary: APInt;
    if signed {
        if descending {
            moved_boundary = ap_sub(start_lower, offset);
            overflow = ap_sgt(moved_boundary, start_lower) || cr_is_sign_wrapped_set(start_range);
        } else {
            moved_boundary = ap_add(start_upper, offset);
            overflow = ap_slt(moved_boundary, start_upper) || cr_is_sign_wrapped_set(start_range);
        }
    } else {
        moved_boundary, overflow = ap_uadd_ov(start_upper, offset);
        overflow |= cr_is_wrapped_set(start_range);
    }
    if cr_contains(start_range, moved_boundary) return cr_full(bits), false;
    new_lower := ifx descending then moved_boundary else start_lower;
    new_upper := ifx descending then start_upper else moved_boundary;
    new_upper = ap_add_u64(new_upper, 1);
    return cr_non_empty(new_lower, new_upper), !overflow;
}

// getRangeForAffineAR
sc_get_range_for_affine_ar :: (start: Scev_Id, step: Scev_Id, max_be_count: APInt) -> (Const_Range, u8) {
    start_srange := sc_signed_range(start);
    step_srange := sc_signed_range(step);
    sr1, nsw1 := get_range_for_affine_ar_helper(cr_smin(step_srange), start_srange, max_be_count, true);
    sr2, nsw2 := get_range_for_affine_ar_helper(cr_smax(step_srange), start_srange, max_be_count, true);
    sr := cr_union(sr1, sr2);
    ur, nuw := get_range_for_affine_ar_helper(sc_unsigned_range_max(step), sc_unsigned_range(start), max_be_count, false);
    flags := SF_ANY;
    if nuw flags = set_flags(flags, SF_NUW);
    if nsw1 && nsw2 flags = set_flags(flags, SF_NSW);
    return cr_intersect(sr, ur, .SMALLEST), flags;
}

// getRangeForAffineNoSelfWrappingAR
sc_get_range_for_affine_no_self_wrapping_ar :: (add_rec: Scev_Id, max_be_count_in: Scev_Id, bits: u32, signed: bool) -> Const_Range {
    step := sc_step_recurrence(add_rec);
    if !sc_is_const(step) return cr_full(bits);
    if sc_bits(max_be_count_in) > sc_bits(add_rec) return cr_full(bits);
    max_be_count := sc_get_noop_or_zero_extend(max_be_count_in, sc_type(add_rec));
    range_width := sc_get_minus_one(sc_type(add_rec));
    step_abs := sc_get_umin2(step, sc_get_negative(step));
    max_iters := sc_get_udiv(range_width, step_abs);
    if !sc_is_known_predicate_via_constant_ranges(ICMP_ULE, max_be_count, max_iters) return cr_full(bits);
    le_pred := ifx signed then cast(u8) ICMP_SLE else ICMP_ULE;
    ge_pred := ifx signed then cast(u8) ICMP_SGE else ICMP_UGE;
    end := evaluate_at_iteration(add_rec, max_be_count);
    start := sc_apply_loop_guards(sc_start(add_rec), sc_loop(add_rec));
    start_range := sc_get_range_ref(start, signed);
    end_range := sc_get_range_ref(end, signed);
    between := cr_union(start_range, end_range);
    if cr_is_full_set(between) return between;
    wrapped := ifx signed then cr_is_sign_wrapped_set(between) else cr_is_wrapped_set(between);
    if wrapped return cr_full(bits);
    if sc_is_known_positive(step) && sc_is_known_predicate_via_constant_ranges(le_pred, start, end) return between;
    if sc_is_known_negative(step) && sc_is_known_predicate_via_constant_ranges(ge_pred, start, end) return between;
    return cr_full(bits);
}

// getRangeViaFactoring
Sc_Select_Pattern :: struct { condition: Value_Id = NONE; true_value: APInt; false_value: APInt; }
select_pattern_of :: (bits: u32, s_in: Scev_Id) -> Sc_Select_Pattern {
    r: Sc_Select_Pattern;
    s := s_in;
    has_cast := false;
    cast_op: Scev_Kind;
    offset := ap_zero(bits);
    if sc_is_add(s) && sc_nops(s) == 2 && sc_is_const(sc_op(s, 0)) { offset = sc_ap(sc_op(s, 0)); s = sc_op(s, 1); }
    if sc_is_integral_cast(s) { has_cast = true; cast_op = sc_kind(s); s = sc_op(s, 0); }
    if !sc_is_unknown(s) return r;
    v := sc_value(s);
    if !is_inst(v) || inst_op(v) != .SELECT return r;
    tv := op(v, 1); fv := op(v, 2);
    if !is_const_int(tv) || !is_const_int(fv) return r;
    r.condition = op(v, 0);
    r.true_value = const_ap(tv);
    r.false_value = const_ap(fv);
    if has_cast {
        if cast_op == {
            case .TRUNC; r.true_value = ap_trunc(r.true_value, bits); r.false_value = ap_trunc(r.false_value, bits);
            case .ZEXT; r.true_value = ap_zext(r.true_value, bits); r.false_value = ap_zext(r.false_value, bits);
            case .SEXT; r.true_value = ap_sext(r.true_value, bits); r.false_value = ap_sext(r.false_value, bits);
        }
    }
    r.true_value = ap_add(r.true_value, offset);
    r.false_value = ap_add(r.false_value, offset);
    return r;
}
sc_get_range_via_factoring :: (start: Scev_Id, step: Scev_Id, max_be_count: APInt) -> Const_Range {
    bits := max_be_count.bits;
    sp := select_pattern_of(bits, start);
    if sp.condition == NONE return cr_full(bits);
    stp := select_pattern_of(bits, step);
    if stp.condition == NONE return cr_full(bits);
    if sp.condition != stp.condition return cr_full(bits);
    true_start := sc_get_constant(sp.true_value);
    true_step := sc_get_constant(stp.true_value);
    false_start := sc_get_constant(sp.false_value);
    false_step := sc_get_constant(stp.false_value);
    tr, f1 := sc_get_range_for_affine_ar(true_start, true_step, max_be_count);
    fr, f2 := sc_get_range_for_affine_ar(false_start, false_step, max_be_count);
    return cr_union(tr, fr);
}

// ---------------------------------------------------------------- no-wrap inference

// inferNoWrapViaConstantRanges
sc_infer_no_wrap_via_constant_ranges :: (ar: Scev_Id) {
    if !sc_is_affine(ar) return;
    if !sc_has_nsw(ar) sc_signed_range(ar);
    if !sc_has_nuw(ar) sc_unsigned_range(ar);
    if !sc_has_nw(ar) {
        be_count := sc_get_constant_max_backedge_taken_count(sc_loop(ar));
        if sc_is_const(be_count) {
            step_cr := sc_signed_range(sc_step_recurrence(ar));
            be_ap := sc_ap(be_count);
            no_overflow_bits := ap_active_bits(be_ap) + cr_min_signed_bits(step_cr);
            if no_overflow_bits <= sc_bits(ar) sc_row(ar).flags |= SF_NW;
        }
    }
}

// proveNoSignedWrapViaInduction
prove_no_signed_wrap_via_induction :: (ar: Scev_Id) -> u8 {
    result := sc_flags(ar);
    if sc_has_nsw(ar) return result;
    if !sc_is_affine(ar) return result;
    if table_contains(*se.signed_wrap_tried, ar) return result;
    table_set(*se.signed_wrap_tried, ar, true);
    step := sc_step_recurrence(ar);
    l := sc_loop(ar);
    max_be_count := sc_get_constant_max_backedge_taken_count(l);
    if max_be_count == SCEV_CNC && !se.has_guards && !ac_has_assumptions(se.ac) return result;
    limit, pred := overflow_limit_for_step(step, true);
    if limit != SCEV_CNC && (sc_is_loop_backedge_guarded_by_cond(l, pred, ar, limit) || sc_is_known_on_every_iteration(pred, ar, limit))
        result = set_flags(result, SF_NSW);
    return result;
}

// proveNoUnsignedWrapViaInduction
prove_no_unsigned_wrap_via_induction :: (ar: Scev_Id) -> u8 {
    result := sc_flags(ar);
    if sc_has_nuw(ar) return result;
    if !sc_is_affine(ar) return result;
    if table_contains(*se.unsigned_wrap_tried, ar) return result;
    table_set(*se.unsigned_wrap_tried, ar, true);
    step := sc_step_recurrence(ar);
    bits := sc_bits(ar);
    l := sc_loop(ar);
    max_be_count := sc_get_constant_max_backedge_taken_count(l);
    if max_be_count == SCEV_CNC && !se.has_guards && !ac_has_assumptions(se.ac) return result;
    if sc_is_known_positive(step) {
        n := sc_get_constant(ap_sub(ap_zero(bits), sc_unsigned_range_max(step)));
        if sc_is_loop_backedge_guarded_by_cond(l, ICMP_ULT, ar, n) || sc_is_known_on_every_iteration(ICMP_ULT, ar, n)
            result = set_flags(result, SF_NUW);
    }
    return result;
}
