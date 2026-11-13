// InductiveRangeCheckElimination (irce): port of llvm/lib/Transforms/Scalar/InductiveRangeCheckElimination.cpp
// (InductiveRangeCheck = `Irc`, InductiveRangeCheckElimination::run = irce_run_loop, IRCEPass::run = irce_run) and
// llvm/lib/Transforms/Utils/LoopConstrainer.cpp (LoopStructure = `Loop_Structure`, parseLoopStructure,
// LoopConstrainer = `Loop_Constrainer` with cloneLoop / changeIterationSpaceEnd / createPreheader /
// createClonedLoopStructure / run), plus the LoopUtils.cpp predicates isKnownNegativeInLoop & co. and
// InvertBranch (BasicBlockUtils.cpp).

irce_cl: struct {
    loop_size_cutoff: s64 = 64;                  // -irce-loop-size-cutoff
    print_changed_loops := false;                // -irce-print-changed-loops
    print_range_checks := false;                 // -irce-print-range-checks
    skip_profitability_checks := false;          // -irce-skip-profitability-checks
    min_eliminated_checks: s64 = 10;             // -irce-min-eliminated-checks
    allow_unsigned_latch_condition := true;      // -irce-allow-unsigned-latch
    allow_narrow_latch_condition := true;        // -irce-allow-narrow-latch
    max_type_size_for_overflow_check: s64 = 32;  // -irce-max-type-size-for-overflow-check
    print_scaled_boundary_range_checks := false; // -irce-print-scaled-boundary-range-checks
};

irce_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == {
        case "irce-loop-size-cutoff"; irce_cl.loop_size_cutoff = smisc_int(name, value, has_value);
        case "irce-print-changed-loops"; irce_cl.print_changed_loops = smisc_bool(name, value, has_value);
        case "irce-print-range-checks"; irce_cl.print_range_checks = smisc_bool(name, value, has_value);
        case "irce-skip-profitability-checks"; irce_cl.skip_profitability_checks = smisc_bool(name, value, has_value);
        case "irce-min-eliminated-checks"; irce_cl.min_eliminated_checks = smisc_int(name, value, has_value);
        case "irce-allow-unsigned-latch"; irce_cl.allow_unsigned_latch_condition = smisc_bool(name, value, has_value);
        case "irce-allow-narrow-latch"; irce_cl.allow_narrow_latch_condition = smisc_bool(name, value, has_value);
        case "irce-max-type-size-for-overflow-check"; irce_cl.max_type_size_for_overflow_check = smisc_int(name, value, has_value);
        case "irce-print-scaled-boundary-range-checks"; irce_cl.print_scaled_boundary_range_checks = smisc_bool(name, value, has_value);
        case; return false;
    }
    return true;
}

// ---------------------------------------------------------------- LoopUtils.cpp predicates

is_known_negative_in_loop :: (s: Scev_Id, l: Loop_Id) -> bool {
    zero := sc_get_zero(sc_type(s));
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, ICMP_SLT, s, zero);
}
is_known_non_negative_in_loop :: (s: Scev_Id, l: Loop_Id) -> bool {
    zero := sc_get_zero(sc_type(s));
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, ICMP_SGE, s, zero);
}
is_known_positive_in_loop :: (s: Scev_Id, l: Loop_Id) -> bool {
    zero := sc_get_zero(sc_type(s));
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, ICMP_SGT, s, zero);
}
is_known_non_positive_in_loop :: (s: Scev_Id, l: Loop_Id) -> bool {
    zero := sc_get_zero(sc_type(s));
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, ICMP_SLE, s, zero);
}
cannot_be_min_in_loop :: (s: Scev_Id, l: Loop_Id, signed: bool) -> bool {
    bw := sc_type_bits(sc_type(s));
    mn := ifx signed then ap_signed_min(bw) else ap_from_u64(bw, 0);
    pred := ifx signed then cast(u8) ICMP_SGT else cast(u8) ICMP_UGT;
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, pred, s, sc_get_constant(mn));
}
cannot_be_max_in_loop :: (s: Scev_Id, l: Loop_Id, signed: bool) -> bool {
    bw := sc_type_bits(sc_type(s));
    mx := ifx signed then ap_signed_max(bw) else ap_all_ones(bw);
    pred := ifx signed then cast(u8) ICMP_SLT else cast(u8) ICMP_ULT;
    return sc_is_available_at_loop_entry(s, l) && sc_is_loop_entry_guarded_by_cond(l, pred, s, sc_get_constant(mx));
}

// InvertBranch(PBI, Builder) (BasicBlockUtils.cpp)
invert_branch :: (pbi: Value_Id, b: *Irb) {
    nc := op(pbi, 0);
    if has_one_use(nc) && is_inst(nc) && (inst_op(nc) == .ICMP || inst_op(nc) == .FCMP) {
        inst(nc).pred = cmp_inverse(inst(nc).pred);
    } else {
        nc = irb_not(b, nc, tprint("%.not", vname(nc)));
    }
    set_op(pbi, 0, nc);
    condbr_swap_successors(pbi);
}

// BranchProbabilityInfo::swapSuccEdgesProbabilities
bpi_swap_succ_edges_probabilities :: (b: *Bpi, src: Value_Id) {
    p := table_find_pointer(*b.probs, src);
    if !p || p.count == 0 return;
    t := p.*[0]; p.*[0] = p.*[1]; p.*[1] = t;
}

// Value::setName, which does nothing on a value without a symbol table (a constant)
set_name_if_local :: (v: Value_Id, name: string) {
    if is_constant_kind(vkind(v)) return;
    set_name(v, name);
}

// ---------------------------------------------------------------- InductiveRangeCheck

Irc :: struct {
    begin: Scev_Id;
    step: Scev_Id;
    end: Scev_Id;
    check_user: Value_Id;   // CheckUse: the user and its operand number
    check_op: u32;
}
Irc_Range :: struct { begin: Scev_Id; end: Scev_Id; valid: bool; }

irc_range_is_empty :: (r: Irc_Range, signed: bool) -> bool {
    if r.begin == r.end return true;
    if signed return sc_is_known_predicate(ICMP_SGE, r.begin, r.end);
    return sc_is_known_predicate(ICMP_UGE, r.begin, r.end);
}

irc_print :: (sb: *String_Builder, c: Irc) {
    append(sb, "InductiveRangeCheck:\n");
    append(sb, "  Begin: "); sc_print(sb, c.begin);
    append(sb, "  Step: "); sc_print(sb, c.step);
    append(sb, "  End: "); sc_print(sb, c.end);
    append(sb, "\n  CheckUse: ");
    append(sb, inst_to_string(c.check_user));
    print_to_builder(sb, " Operand: %\n", c.check_op);
}

is_const_int_value :: (v: Value_Id, x: s64) -> bool {
    if v == NONE || vkind(v) != .C_INT return false;
    a := const_ap(v);
    if x == 0 return ap_is_zero(a);
    if x == -1 return ap_is_all_ones(a);
    return false;
}

// parseIvAgaisntLimit
irc_parse_iv_against_limit :: (l: Loop_Id, lhs: Value_Id, rhs: Value_Id, pred: u8) -> (bool, Scev_Id, Scev_Id) {
    add_rec := sc_get_scev(lhs);
    if !sc_is_addrec(add_rec) return false, SCEV_NULL, SCEV_NULL;
    sint_max :: (t: Type_Id) -> Scev_Id { return sc_get_constant(ap_signed_max(sc_type_bits(t))); }
    if pred == {
        case ICMP_SGE;
            if is_const_int_value(rhs, 0) return true, add_rec, sint_max(sc_type(add_rec));
            return false, SCEV_NULL, SCEV_NULL;
        case ICMP_SGT;
            if is_const_int_value(rhs, -1) return true, add_rec, sint_max(sc_type(add_rec));
            return false, SCEV_NULL, SCEV_NULL;
        case ICMP_SLT; #through;
        case ICMP_ULT;
            return true, add_rec, sc_get_scev(rhs);
        case ICMP_SLE; #through;
        case ICMP_ULE;
            one := sc_get_one(vtype(rhs));
            rhss := sc_get_scev(rhs);
            signed := pred == ICMP_SLE;
            if sc_will_not_overflow(.ADD, signed, rhss, one) return true, add_rec, sc_get_add2(rhss, one);
            return false, SCEV_NULL, SCEV_NULL;
    }
    return false, SCEV_NULL, SCEV_NULL;
}

// reassociateSubLHS
irc_reassociate_sub_lhs :: (l: Loop_Id, variant_lhs: Value_Id, invariant_rhs: Value_Id, pred_in: u8) -> (bool, Scev_Id, Scev_Id) {
    pred := pred_in;
    if !is_inst(variant_lhs) || inst_op(variant_lhs) != .SUB return false, SCEV_NULL, SCEV_NULL;
    iv := sc_get_scev(op(variant_lhs, 0));
    offset := sc_get_scev(op(variant_lhs, 1));
    limit := sc_get_scev(invariant_rhs);
    offset_subtracted := false;
    if sc_is_loop_invariant(iv, l) { t := iv; iv = offset; offset = t; }
    else if sc_is_loop_invariant(offset, l) offset_subtracted = true;
    else return false, SCEV_NULL, SCEV_NULL;
    if !sc_is_addrec(iv) return false, SCEV_NULL, SCEV_NULL;
    add_rec := iv;

    scaled :: (bin_op: Opcode, a: Scev_Id, b: Scev_Id, pred: u8, cxt: Value_Id) -> Scev_Id {
        if sc_will_not_overflow(bin_op, cmp_is_signed(pred), a, b, cxt) {
            if bin_op == .ADD return sc_get_add2(a, b);
            return sc_get_minus(a, b);
        }
        bw := sc_type_bits(sc_type(a));
        if bw > irce_cl.max_type_size_for_overflow_check return SCEV_NULL;
        wide := type_int(bw * 2);
        wa := sc_get_sign_extend(a, wide);
        wb := sc_get_sign_extend(b, wide);
        if bin_op == .ADD return sc_get_add2(wa, wb);
        return sc_get_minus(wa, wb);
    }

    if offset_subtracted limit = scaled(.ADD, offset, limit, pred, variant_lhs);
    else {
        limit = scaled(.SUB, offset, limit, pred, variant_lhs);
        pred = cmp_swapped(pred);
    }
    if pred == ICMP_SLT || pred == ICMP_SLE {
        if pred == ICMP_SLE && limit != SCEV_NULL limit = scaled(.ADD, limit, sc_get_one(sc_type(limit)), pred, variant_lhs);
        if limit != SCEV_NULL return true, add_rec, limit;
    }
    return false, SCEV_NULL, SCEV_NULL;
}

// parseRangeCheckICmp
irc_parse_range_check_icmp :: (l: Loop_Id, ici: Value_Id) -> (bool, Scev_Id, Scev_Id) {
    pred := inst(ici).pred;
    lhs := op(ici, 0);
    rhs := op(ici, 1);
    if type_kind(vtype(lhs)) != .INT return false, SCEV_NULL, SCEV_NULL;
    if sc_is_loop_invariant(sc_get_scev(lhs), l) {
        t := lhs; lhs = rhs; rhs = t;
        pred = cmp_swapped(pred);
    } else if !sc_is_loop_invariant(sc_get_scev(rhs), l) return false, SCEV_NULL, SCEV_NULL;
    ok, index, end := irc_parse_iv_against_limit(l, lhs, rhs, pred);
    if ok return true, index, end;
    ok, index, end = irc_reassociate_sub_lhs(l, lhs, rhs, pred);
    if ok return true, index, end;
    return false, SCEV_NULL, SCEV_NULL;
}

// extractRangeChecksFromCond
irc_extract_from_cond :: (l: Loop_Id, user: Value_Id, opno: u32, checks: *[..] Irc, visited: *[..] Value_Id) {
    condition := op(user, opno);
    for visited.* if it == condition return;
    array_add(visited, condition);
    is_and, a, b := pm_logical_and(condition);
    if is_and {
        irc_extract_from_cond(l, condition, 0, checks, visited);
        irc_extract_from_cond(l, condition, 1, checks, visited);
        return;
    }
    if !is_inst(condition) || inst_op(condition) != .ICMP return;
    ok, index, end := irc_parse_range_check_icmp(l, condition);
    if !ok return;
    if sc_loop(index) != l || !sc_is_affine(index) return;
    c: Irc;
    c.end = end;
    c.begin = sc_start(index);
    c.step = sc_step_recurrence(index);
    c.check_user = user;
    c.check_op = opno;
    array_add(checks, c);
}

// extractRangeChecksFromBranch
irc_extract_from_branch :: (bi: Value_Id, l: Loop_Id, li: *Loop_Info, bpi: *Bpi, has_etc: bool, etc: u64,
                            checks: *[..] Irc, changed: *bool) {
    bb := inst_block(bi);
    if bb == li_loop_latch(li, l) return;
    index_loop_succ: u32 = ifx li_contains(li, l, get_successor(bi, 0)) then cast(u32) 0 else 1;
    if !irce_cl.skip_profitability_checks && bpi {
        success_probability := bpi_edge_probability_idx(bpi, bb, index_loop_succ);
        if has_etc {
            estimated_eliminated_checks := bp_scale(success_probability, etc);
            if estimated_eliminated_checks < cast(u64) irce_cl.min_eliminated_checks return;
        } else {
            if success_probability < bp_make(15, 16) return;
        }
    }
    if index_loop_succ != 0 {
        b: Irb; irb_set_before(*b, bi);
        invert_branch(bi, *b);
        if bpi bpi_swap_succ_edges_probabilities(bpi, bb);
        changed.* = true;
    }
    visited: [..] Value_Id; visited.allocator = temp;
    irc_extract_from_cond(l, bi, 0, checks, *visited);
}

irce_noop_or_extend :: (s: Scev_Id, ty: Type_Id, signed: bool) -> Scev_Id {
    if signed return sc_get_noop_or_sign_extend(s, ty);
    return sc_get_noop_or_zero_extend(s, ty);
}

// computeSafeIterationSpace
irc_compute_safe_iteration_space :: (c: Irc, ind_var: Scev_Id, is_latch_signed: bool, li: *Loop_Info) -> Irc_Range {
    none: Irc_Range;
    iv_type := sc_type(ind_var);
    rc_type := sc_type(c.begin);
    end_type := sc_type(c.end);
    if type_kind(iv_type) != .INT || type_kind(rc_type) != .INT return none;
    if type_int_width(iv_type) > type_int_width(rc_type) return none;
    if !sc_is_affine(ind_var) return none;
    a := irce_noop_or_extend(sc_start(ind_var), rc_type, is_latch_signed);
    b := irce_noop_or_extend(sc_step_recurrence(ind_var), rc_type, is_latch_signed);
    if !sc_is_const(b) return none;
    cc := c.begin;
    if !sc_is_const(c.step) || c.step != b return none;
    bw := type_int_width(rc_type);
    sint_max := sc_get_constant(ap_signed_max(bw));
    sint_min := sc_get_constant(ap_signed_min(bw));

    clamped_subtract :: (x: Scev_Id, y: Scev_Id, is_latch_signed: bool, sint_max: Scev_Id) -> Scev_Id {
        if is_latch_signed {
            x_minus_sint_max := sc_get_minus(x, sint_max);
            return sc_get_minus(x, sc_get_smax2(y, x_minus_sint_max), SF_NSW);
        }
        return sc_get_minus(x, sc_get_smin2(x, y), SF_NUW);
    }
    m := sc_get_minus(cc, a);
    zero := sc_get_zero(sc_type(m));
    l := sc_loop(ind_var);

    check_non_negative :: (x: Scev_Id, l: Loop_Id) -> Scev_Id {
        zero := sc_get_zero(sc_type(x));
        one := sc_get_one(sc_type(x));
        if is_known_non_negative_in_loop(x, l) return one;
        else if is_known_negative_in_loop(x, l) return zero;
        neg_one := sc_get_negative(one);
        return sc_get_add2(sc_get_smax2(sc_get_smin2(x, zero), neg_one), one);
    }
    check_will_not_overflow :: (x: Scev_Id, l: Loop_Id, sint_max: Scev_Id, sint_min: Scev_Id) -> Scev_Id {
        sint_max_ext := sc_get_sign_extend(sint_max, sc_type(x));
        overflow_check := check_non_negative(sc_get_minus(sint_max_ext, x), l);
        sint_min_ext := sc_get_sign_extend(sint_min, sc_type(x));
        underflow_check := check_non_negative(sc_get_minus(x, sint_min_ext), l);
        return sc_get_mul2(overflow_check, underflow_check);
    }

    r_end := c.end;
    end_will_not_overflow := sc_get_one(rc_type);
    if type_int_width(end_type) > type_int_width(rc_type) {
        if irce_cl.print_scaled_boundary_range_checks {
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "irce: in function %, in ", vname(block_fn(li_header(li, l))));
            li_print_loop(li, l, *sb);
            append(*sb, "there is range check with scaled boundary:\n");
            irc_print(*sb, c);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
        }
        end_will_not_overflow = sc_get_truncate(check_will_not_overflow(r_end, l, sint_max, sint_min), rc_type);
        r_end = sc_get_truncate(r_end, rc_type);
    }
    runtime_checks := sc_get_mul2(check_non_negative(r_end, l), end_will_not_overflow);
    begin := sc_get_mul2(clamped_subtract(zero, m, is_latch_signed, sint_max), runtime_checks);
    end := sc_get_mul2(clamped_subtract(r_end, m, is_latch_signed, sint_max), runtime_checks);
    return .{begin, end, true};
}

// IntersectSignedRange / IntersectUnsignedRange
irc_intersect_range :: (r1: Irc_Range, r2: Irc_Range, signed: bool) -> Irc_Range {
    none: Irc_Range;
    if irc_range_is_empty(r2, signed) return none;
    if !r1.valid return r2;
    if sc_type(r1.begin) != sc_type(r2.begin) return none;
    nb, ne: Scev_Id;
    if signed { nb = sc_get_smax2(r1.begin, r2.begin); ne = sc_get_smin2(r1.end, r2.end); }
    else { nb = sc_get_umax2(r1.begin, r2.begin); ne = sc_get_umin2(r1.end, r2.end); }
    ret := Irc_Range.{nb, ne, true};
    if irc_range_is_empty(ret, signed) return none;
    return ret;
}

// ---------------------------------------------------------------- LoopStructure (LoopConstrainer.cpp)

Loop_Structure :: struct {
    tag: string;
    header: Value_Id = NONE;
    latch: Value_Id = NONE;
    latch_br: Value_Id = NONE;
    latch_exit: Value_Id = NONE;
    latch_br_exit_idx: u32 = 0xFFFF_FFFF;
    ind_var_base: Value_Id = NONE;
    ind_var_start: Value_Id = NONE;
    ind_var_step: Value_Id = NONE;
    loop_exit_at: Value_Id = NONE;
    ind_var_increasing: bool;
    is_signed_predicate := true;
    exit_count_ty: Type_Id = NONE;
}

LC_CLONED_LOOP_TAG :: "loop_constrainer.loop.clone";

// isLoopEntryGuardedByCond (LoopConstrainer.cpp)
lc_is_loop_entry_guarded_by_cond :: (l: Loop_Id, pred: u8, start: Scev_Id, bound: Scev_Id) -> bool {
    if sc_is_loop_entry_guarded_by_cond(l, pred, start, bound) return true;
    start_lg := sc_apply_loop_guards(start, l);
    bound_lg := sc_apply_loop_guards(bound, l);
    return sc_is_loop_entry_guarded_by_cond(l, pred, start_lg, bound_lg);
}

lc_is_relational_strict :: (pred: u8) -> bool {
    return pred == ICMP_SLT || pred == ICMP_SGT || pred == ICMP_ULT || pred == ICMP_UGT;
}

// isSafeDecreasingBound
lc_is_safe_decreasing_bound :: (start: Scev_Id, bound: Scev_Id, step: Scev_Id, pred: u8, latch_br_exit_idx: u32, l: Loop_Id) -> bool {
    if !lc_is_relational_strict(pred) return false;
    if !sc_is_available_at_loop_entry(bound, l) return false;
    is_signed := cmp_is_signed(pred);
    bound_pred := ifx is_signed then cast(u8) ICMP_SGT else cast(u8) ICMP_UGT;
    if latch_br_exit_idx == 1 return lc_is_loop_entry_guarded_by_cond(l, bound_pred, start, bound);
    step_plus_one := sc_get_add2(step, sc_get_one(sc_type(step)));
    bw := sc_type_bits(sc_type(bound));
    mn := ifx is_signed then ap_signed_min(bw) else ap_from_u64(bw, 0);
    limit := sc_get_minus(sc_get_constant(mn), step_plus_one);
    minus_one := sc_get_minus(bound, sc_get_one(sc_type(bound)));
    return lc_is_loop_entry_guarded_by_cond(l, bound_pred, start, minus_one) &&
           lc_is_loop_entry_guarded_by_cond(l, bound_pred, bound, limit);
}

// isSafeIncreasingBound
lc_is_safe_increasing_bound :: (start: Scev_Id, bound: Scev_Id, step: Scev_Id, pred: u8, latch_br_exit_idx: u32, l: Loop_Id) -> bool {
    if !lc_is_relational_strict(pred) return false;
    if !sc_is_available_at_loop_entry(bound, l) return false;
    is_signed := cmp_is_signed(pred);
    bound_pred := ifx is_signed then cast(u8) ICMP_SLT else cast(u8) ICMP_ULT;
    if latch_br_exit_idx == 1 return lc_is_loop_entry_guarded_by_cond(l, bound_pred, start, bound);
    step_minus_one := sc_get_minus(step, sc_get_one(sc_type(step)));
    bw := sc_type_bits(sc_type(bound));
    mx := ifx is_signed then ap_signed_max(bw) else ap_all_ones(bw);
    limit := sc_get_minus(sc_get_constant(mx), step_minus_one);
    return lc_is_loop_entry_guarded_by_cond(l, bound_pred, start, sc_get_add2(bound, step)) &&
           lc_is_loop_entry_guarded_by_cond(l, bound_pred, bound, limit);
}

// getNarrowestLatchMaxTakenCountEstimate
lc_narrowest_latch_max_taken_count :: (l: Loop_Id, li: *Loop_Info) -> Scev_Id {
    from_block := sc_get_exit_count(l, li_loop_latch(li, l), .SYMBOLIC_MAX);
    if from_block == SCEV_CNC return sc_get_symbolic_max_backedge_taken_count(l);
    return from_block;
}

// LoopStructure::parseLoopStructure
parse_loop_structure :: (l: Loop_Id, li: *Loop_Info, allow_unsigned_latch_cond: bool) -> (bool, Loop_Structure, string) {
    r: Loop_Structure;
    if !li_is_loop_simplify_form(li, l) return false, r, "loop not in LoopSimplify form";
    latch := li_loop_latch(li, l);
    if get_metadata(block_terminator(latch), md_kind(LC_CLONED_LOOP_TAG)) != NONE return false, r, "loop has already been cloned";
    if !li_is_loop_exiting(li, l, latch) return false, r, "no loop latch";
    header := li_header(li, l);
    preheader := li_loop_preheader(li, l);
    if preheader == NONE return false, r, "no preheader";
    latch_br := block_terminator(latch);
    if inst_op(latch_br) != .CONDBR return false, r, "latch terminator not conditional branch";
    latch_br_exit_idx: u32 = ifx get_successor(latch_br, 0) == header then cast(u32) 1 else 0;
    ici := op(latch_br, 0);
    if !is_inst(ici) || inst_op(ici) != .ICMP || type_kind(vtype(op(ici, 0))) != .INT
        return false, r, "latch terminator branch not conditional on integral icmp";
    max_be_taken_count := lc_narrowest_latch_max_taken_count(l, li);
    if max_be_taken_count == SCEV_CNC return false, r, "could not compute latch count";

    pred := inst(ici).pred;
    left_value := op(ici, 0);
    left_scev := sc_get_scev(left_value);
    ind_var_ty := vtype(left_value);
    right_value := op(ici, 1);
    right_scev := sc_get_scev(right_value);
    if !sc_is_addrec(left_scev) {
        if sc_is_addrec(right_scev) {
            t := left_scev; left_scev = right_scev; right_scev = t;
            tv := left_value; left_value = right_value; right_value = tv;
            pred = cmp_swapped(pred);
        } else return false, r, "no add recurrences in the icmp";
    }

    has_no_signed_wrap :: (ar: Scev_Id) -> bool {
        if sc_has_nsw(ar) return true;
        wide := type_int(sc_type_bits(sc_type(ar)) * 2);
        extend_after_op := sc_get_sign_extend(ar, wide);
        if sc_is_addrec(extend_after_op) {
            extended_start := sc_get_sign_extend(sc_start(ar), wide);
            extended_step := sc_get_sign_extend(sc_step_recurrence(ar), wide);
            if sc_start(extend_after_op) == extended_start && sc_step_recurrence(extend_after_op) == extended_step return true;
        }
        return sc_has_nsw(ar);
    }

    ind_var_base := left_scev;
    if sc_loop(ind_var_base) != l return false, r, "LHS in cmp is not an AddRec for this loop";
    if !sc_is_affine(ind_var_base) return false, r, "LHS in icmp not induction variable";
    step_rec := sc_step_recurrence(ind_var_base);
    if !sc_is_const(step_rec) return false, r, "LHS in icmp not induction variable";
    step_ap := sc_ap(step_rec);
    step_ci := sc_value(step_rec);
    if cmp_is_equality(inst(ici).pred) && !has_no_signed_wrap(ind_var_base) return false, r, "LHS in icmp needs nsw for equality predicates";

    is_increasing := !ap_is_negative(step_ap);
    is_signed_predicate: bool;
    start_next := sc_start(ind_var_base);
    addend := sc_get_negative(sc_step_recurrence(ind_var_base));
    ind_var_start := sc_get_add2(start_next, addend);
    step := sc_get_scev(step_ci);
    fixed_right_scev := SCEV_NULL;
    if is_inst(right_value) && li_contains(li, l, inst_block(right_value)) fixed_right_scev = right_scev;

    if is_increasing {
        decreased_right_value_by_one := false;
        if ap_is_one(step_ap) {
            if pred == ICMP_NE && latch_br_exit_idx == 1 {
                if is_known_non_negative_in_loop(ind_var_start, l) && is_known_non_negative_in_loop(right_scev, l) pred = ICMP_ULT;
                else pred = ICMP_SLT;
            } else if pred == ICMP_EQ && latch_br_exit_idx == 0 {
                if sc_has_nuw(ind_var_base) && cannot_be_min_in_loop(right_scev, l, false) {
                    pred = ICMP_UGT;
                    right_scev = sc_get_minus(right_scev, sc_get_one(sc_type(right_scev)));
                    decreased_right_value_by_one = true;
                } else if cannot_be_min_in_loop(right_scev, l, true) {
                    pred = ICMP_SGT;
                    right_scev = sc_get_minus(right_scev, sc_get_one(sc_type(right_scev)));
                    decreased_right_value_by_one = true;
                }
            }
        }
        lt_pred := pred == ICMP_SLT || pred == ICMP_ULT;
        gt_pred := pred == ICMP_SGT || pred == ICMP_UGT;
        if !((lt_pred && latch_br_exit_idx == 1) || (gt_pred && latch_br_exit_idx == 0))
            return false, r, "expected icmp slt semantically, found something else";
        is_signed_predicate = cmp_is_signed(pred);
        if !is_signed_predicate && !allow_unsigned_latch_cond return false, r, "unsigned latch conditions are explicitly prohibited";
        if !lc_is_safe_increasing_bound(ind_var_start, right_scev, step, pred, latch_br_exit_idx, l) return false, r, "Unsafe loop bounds";
        if latch_br_exit_idx == 0 {
            if !decreased_right_value_by_one fixed_right_scev = sc_get_add2(right_scev, sc_get_one(sc_type(right_scev)));
        }
    } else {
        increased_right_value_by_one := false;
        if ap_is_all_ones(step_ap) {
            if pred == ICMP_NE && latch_br_exit_idx == 1 pred = ICMP_SGT;
            else if pred == ICMP_EQ && latch_br_exit_idx == 0 {
                if sc_has_nuw(ind_var_base) && cannot_be_max_in_loop(right_scev, l, false) {
                    pred = ICMP_ULT;
                    right_scev = sc_get_add2(right_scev, sc_get_one(sc_type(right_scev)));
                    increased_right_value_by_one = true;
                } else if cannot_be_max_in_loop(right_scev, l, true) {
                    pred = ICMP_SLT;
                    right_scev = sc_get_add2(right_scev, sc_get_one(sc_type(right_scev)));
                    increased_right_value_by_one = true;
                }
            }
        }
        lt_pred := pred == ICMP_SLT || pred == ICMP_ULT;
        gt_pred := pred == ICMP_SGT || pred == ICMP_UGT;
        if !((gt_pred && latch_br_exit_idx == 1) || (lt_pred && latch_br_exit_idx == 0))
            return false, r, "expected icmp sgt semantically, found something else";
        is_signed_predicate = pred == ICMP_SLT || pred == ICMP_SGT;
        if !is_signed_predicate && !allow_unsigned_latch_cond return false, r, "unsigned latch conditions are explicitly prohibited";
        if !lc_is_safe_decreasing_bound(ind_var_start, right_scev, step, pred, latch_br_exit_idx, l) return false, r, "Unsafe bounds";
        if latch_br_exit_idx == 0 {
            if !increased_right_value_by_one fixed_right_scev = sc_get_minus(right_scev, sc_get_one(sc_type(right_scev)));
        }
    }
    latch_exit := get_successor(latch_br, latch_br_exit_idx);

    expander: Scev_Expander;
    sx_init(*expander, "loop-constrainer");
    ins := block_terminator(preheader);
    if fixed_right_scev != SCEV_NULL
        right_value = sx_expand_code_for_at(*expander, fixed_right_scev, sc_type(fixed_right_scev), ins);
    ind_var_start_v := sx_expand_code_for_at(*expander, ind_var_start, ind_var_ty, ins);
    set_name_if_local(ind_var_start_v, "indvar.start");
    sx_clear(*expander);

    r.tag = "main";
    r.header = header;
    r.latch = latch;
    r.latch_br = latch_br;
    r.latch_exit = latch_exit;
    r.latch_br_exit_idx = latch_br_exit_idx;
    r.ind_var_start = ind_var_start_v;
    r.ind_var_step = step_ci;
    r.ind_var_base = left_value;
    r.ind_var_increasing = is_increasing;
    r.loop_exit_at = right_value;
    r.is_signed_predicate = is_signed_predicate;
    r.exit_count_ty = sc_type(max_be_taken_count);
    return true, r, "";
}

// ---------------------------------------------------------------- LoopConstrainer

Lc_Sub_Ranges :: struct { low_limit := SCEV_NULL; high_limit := SCEV_NULL; }

Lc_Cloned_Loop :: struct {
    blocks: [..] Value_Id;
    map: Value_Map;
    structure: Loop_Structure;
}

Lc_Rewritten_Range_Info :: struct {
    pseudo_exit: Value_Id = NONE;
    exit_selector: Value_Id = NONE;
    phi_values_at_pseudo_exit: [..] Value_Id;
    ind_var_end: Value_Id = NONE;
}

Loop_Constrainer :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    li: *Loop_Info;
    original_loop: Loop_Id;
    original_preheader: Value_Id = NONE;
    main_loop_preheader: Value_Id = NONE;
    range_ty: Type_Id;
    main_loop_structure: Loop_Structure;
    sr: Lc_Sub_Ranges;
}

// DisableAllLoopOptsOnLoop
lc_disable_all_loop_opts_on_loop :: (li: *Loop_Info, l: Loop_Id) {
    md_tuple(.[], false);   // Dummy (the operand replaced by the self reference)
    disable_unroll := md_tuple(.[md_string("llvm.loop.unroll.disable")], false);
    false_val := md_value(const_int(type_int(1), 0));
    disable_vectorize := md_tuple(.[md_string("llvm.loop.vectorize.enable"), false_val], false);
    disable_licm_versioning := md_tuple(.[md_string("llvm.loop.licm_versioning.disable")], false);
    disable_distribution := md_tuple(.[md_string("llvm.loop.distribute.enable"), false_val], false);
    li_set_loop_id(li, l, md_self_ref_loop_id(.[NONE, disable_unroll, disable_vectorize, disable_licm_versioning, disable_distribution]));
}

lc_cloned_value :: (r: *Lc_Cloned_Loop, v: Value_Id) -> Value_Id {
    found, m := vmap_find(*r.map, v);
    if !found return v;
    return m;
}

lc_map_structure :: (s: Loop_Structure, r: *Lc_Cloned_Loop) -> Loop_Structure {
    m := s;
    m.header = lc_cloned_value(r, s.header);
    m.latch = lc_cloned_value(r, s.latch);
    m.latch_br = lc_cloned_value(r, s.latch_br);
    m.latch_exit = lc_cloned_value(r, s.latch_exit);
    m.ind_var_base = lc_cloned_value(r, s.ind_var_base);
    m.ind_var_start = lc_cloned_value(r, s.ind_var_start);
    m.ind_var_step = lc_cloned_value(r, s.ind_var_step);
    m.loop_exit_at = lc_cloned_value(r, s.loop_exit_at);
    return m;
}

// cloneLoop
lc_clone_loop :: (c: *Loop_Constrainer, result: *Lc_Cloned_Loop, tag: string) {
    li := c.li;
    result.blocks.allocator = temp;
    vmap_init(*result.map);
    for bb: li_blocks(li, c.original_loop) {
        clone := clone_basic_block(bb, *result.map, tprint(".%", tag), c.f, map_atoms = true);
        array_add(*result.blocks, clone);
        vmap_set(*result.map, bb, clone);
    }
    cloned_latch := lc_cloned_value(result, li_loop_latch(li, c.original_loop));
    set_metadata(block_terminator(cloned_latch), md_kind(LC_CLONED_LOOP_TAG), md_tuple(.[], false));
    result.structure = lc_map_structure(c.main_loop_structure, result);
    result.structure.tag = tag;
    orig_blocks := li_blocks(li, c.original_loop);
    succs: [..] Value_Id; succs.allocator = temp;
    for i: 0..result.blocks.count - 1 {
        cloned_bb := result.blocks[i];
        original_bb := orig_blocks[i];
        for ins: block_insts(cloned_bb) remap_instruction(*result.map, ins, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        succs.count = 0;
        block_successors(original_bb, *succs);
        for sbb: succs {
            if li_contains(li, c.original_loop, sbb) continue;
            for pn: block_insts(sbb) {
                if inst_op(pn) != .PHI break;
                old_incoming := phi_incoming_value_for_block(pn, original_bb);
                phi_add_incoming(pn, lc_cloned_value(result, old_incoming), cloned_bb);
                sc_forget_lcssa_phi_with_new_predecessor(c.original_loop, pn);
            }
        }
    }
}

// changeIterationSpaceEnd
lc_change_iteration_space_end :: (c: *Loop_Constrainer, ls: *Loop_Structure, preheader: Value_Id, exit_subloop_at: Value_Id,
                                  continuation_block: Value_Id) -> Lc_Rewritten_Range_Info {
    rri: Lc_Rewritten_Range_Info;
    rri.phi_values_at_pseudo_exit.allocator = temp;
    bb_insert_location := block(ls.latch).next;
    rri.exit_selector = create_block(c.f, tprint("%.exit.selector", ls.tag), bb_insert_location);
    rri.pseudo_exit = create_block(c.f, tprint("%.pseudo.exit", ls.tag), bb_insert_location);
    preheader_jump := block_terminator(preheader);
    increasing := ls.ind_var_increasing;
    is_signed_predicate := ls.is_signed_predicate;
    b: Irb; irb_set_before(*b, preheader_jump);
    noop_or_ext :: (b: *Irb, v: Value_Id, range_ty: Type_Id, signed: bool) -> Value_Id {
        if vtype(v) == range_ty return v;
        name := tprint("wide.%", vname(v));
        if signed return irb_cast(b, .SEXT, v, range_ty, name);
        return irb_cast(b, .ZEXT, v, range_ty, name);
    }
    pred: u8;
    if increasing pred = ifx is_signed_predicate then cast(u8) ICMP_SLT else cast(u8) ICMP_ULT;
    else pred = ifx is_signed_predicate then cast(u8) ICMP_SGT else cast(u8) ICMP_UGT;
    ind_var_start := noop_or_ext(*b, ls.ind_var_start, c.range_ty, is_signed_predicate);
    enter_loop_cond := irb_icmp(*b, pred, ind_var_start, exit_subloop_at);
    irb_cond_br(*b, enter_loop_cond, ls.header, rri.pseudo_exit);
    erase_inst(preheader_jump);

    set_successor(ls.latch_br, ls.latch_br_exit_idx, rri.exit_selector);
    irb_set_before(*b, ls.latch_br);
    ind_var_base := noop_or_ext(*b, ls.ind_var_base, c.range_ty, is_signed_predicate);
    take_backedge_loop_cond := irb_icmp(*b, pred, ind_var_base, exit_subloop_at);
    cond_for_branch := ifx ls.latch_br_exit_idx == 1 then take_backedge_loop_cond else irb_not(*b, take_backedge_loop_cond);
    set_op(ls.latch_br, 0, cond_for_branch);

    irb_set_end(*b, rri.exit_selector);
    loop_exit_at := noop_or_ext(*b, ls.loop_exit_at, c.range_ty, is_signed_predicate);
    iterations_left := irb_icmp(*b, pred, ind_var_base, loop_exit_at);
    irb_cond_br(*b, iterations_left, rri.pseudo_exit, ls.latch_exit);

    branch_to_continuation := create_br(continuation_block);
    block_append_inst(rri.pseudo_exit, branch_to_continuation);

    for pn: block_insts(ls.header) {
        if inst_op(pn) != .PHI break;
        new_phi := create_phi(vtype(pn), 2);
        inst_insert_before(new_phi, branch_to_continuation);
        set_name(new_phi, tprint("%.copy", vname(pn)));
        phi_add_incoming(new_phi, phi_incoming_value_for_block(pn, preheader), preheader);
        phi_add_incoming(new_phi, phi_incoming_value_for_block(pn, ls.latch), rri.exit_selector);
        array_add(*rri.phi_values_at_pseudo_exit, new_phi);
    }
    rri.ind_var_end = create_phi(vtype(ind_var_base), 2);
    inst_insert_before(rri.ind_var_end, branch_to_continuation);
    set_name(rri.ind_var_end, "indvar.end");
    phi_add_incoming(rri.ind_var_end, ind_var_start, preheader);
    phi_add_incoming(rri.ind_var_end, ind_var_base, rri.exit_selector);

    block_replace_phi_uses_with(ls.latch_exit, ls.latch, rri.exit_selector);
    return rri;
}

// rewriteIncomingValuesForPHIs
lc_rewrite_incoming_values_for_phis :: (ls: *Loop_Structure, continuation_block: Value_Id, rri: *Lc_Rewritten_Range_Info) {
    phi_index := 0;
    for pn: block_insts(ls.header) {
        if inst_op(pn) != .PHI break;
        phi_set_incoming_value_for_block(pn, continuation_block, rri.phi_values_at_pseudo_exit[phi_index]);
        phi_index += 1;
    }
    ls.ind_var_start = rri.ind_var_end;
}

// createPreheader
lc_create_preheader :: (c: *Loop_Constrainer, ls: *Loop_Structure, old_preheader: Value_Id, tag: string) -> Value_Id {
    preheader := create_block(c.f, tag, ls.header);
    block_append_inst(preheader, create_br(ls.header));
    block_replace_phi_uses_with(ls.header, old_preheader, preheader);
    return preheader;
}

// createClonedLoopStructure
lc_create_cloned_loop_structure :: (c: *Loop_Constrainer, original: Loop_Id, parent: Loop_Id, vm: *Value_Map, is_subloop: bool) -> Loop_Id {
    li := c.li;
    nl := li_alloc_loop(li);
    if parent != NONE li_add_child_loop(li, parent, nl);
    else li_add_top_level_loop(li, nl);
    // LPMAddNewLoop(&New, IsSubloop): appendLoopsToWorklist(*NL, Worklist) appends the new loop's subloops, and it
    // has none yet, so nothing is added
    obl: [..] Value_Id; obl.allocator = temp;
    for li_blocks(li, original) array_add(*obl, it);
    for bb: obl if li_loop_for(li, bb) == original li_add_basic_block_to_loop(li, nl, vmap_get(vm, bb));
    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(li, original) array_add(*subs, it);
    for sub: subs lc_create_cloned_loop_structure(c, sub, nl, vm, true);
    return nl;
}

// LoopConstrainer::run
lc_run :: (c: *Loop_Constrainer) -> bool {
    li := c.li;
    preheader := li_loop_preheader(li, c.original_loop);
    c.original_preheader = preheader;
    c.main_loop_preheader = preheader;
    is_signed_predicate := c.main_loop_structure.is_signed_predicate;
    increasing := c.main_loop_structure.ind_var_increasing;
    iv_ty := c.range_ty;

    expander: Scev_Expander;
    sx_init(*expander, "loop-constrainer");
    defer sx_clear(*expander);
    insert_pt := block_terminator(c.original_preheader);

    pre_loop, post_loop: Lc_Cloned_Loop;
    needs_pre_loop := ifx increasing then c.sr.low_limit != SCEV_NULL else c.sr.high_limit != SCEV_NULL;
    needs_post_loop := ifx increasing then c.sr.high_limit != SCEV_NULL else c.sr.low_limit != SCEV_NULL;
    exit_pre_loop_at: Value_Id = NONE;
    exit_main_loop_at: Value_Id = NONE;
    minus_one_s := sc_get_constant(ap_all_ones(type_int_width(iv_ty)));

    if needs_pre_loop {
        s: Scev_Id;
        if increasing s = c.sr.low_limit;
        else if cannot_be_min_in_loop(c.sr.high_limit, c.original_loop, is_signed_predicate) s = sc_get_add2(c.sr.high_limit, minus_one_s);
        else return false;
        if !sx_is_safe_to_expand_at(*expander, s, insert_pt) return false;
        exit_pre_loop_at = sx_expand_code_for_at(*expander, s, iv_ty, insert_pt);
        set_name_if_local(exit_pre_loop_at, "exit.preloop.at");
    }
    if needs_post_loop {
        s: Scev_Id;
        if increasing s = c.sr.high_limit;
        else if cannot_be_min_in_loop(c.sr.low_limit, c.original_loop, is_signed_predicate) s = sc_get_add2(c.sr.low_limit, minus_one_s);
        else return false;
        if !sx_is_safe_to_expand_at(*expander, s, insert_pt) return false;
        exit_main_loop_at = sx_expand_code_for_at(*expander, s, iv_ty, insert_pt);
        set_name_if_local(exit_main_loop_at, "exit.mainloop.at");
    }

    if needs_pre_loop lc_clone_loop(c, *pre_loop, "preloop");
    if needs_post_loop lc_clone_loop(c, *post_loop, "postloop");

    pre_loop_rri: Lc_Rewritten_Range_Info;
    if needs_pre_loop {
        replace_uses_of_with(block_terminator(preheader), c.main_loop_structure.header, pre_loop.structure.header);
        c.main_loop_preheader = lc_create_preheader(c, *c.main_loop_structure, preheader, "mainloop");
        pre_loop_rri = lc_change_iteration_space_end(c, *pre_loop.structure, preheader, exit_pre_loop_at, c.main_loop_preheader);
        lc_rewrite_incoming_values_for_phis(*c.main_loop_structure, c.main_loop_preheader, *pre_loop_rri);
    }
    post_loop_preheader: Value_Id = NONE;
    post_loop_rri: Lc_Rewritten_Range_Info;
    if needs_post_loop {
        post_loop_preheader = lc_create_preheader(c, *post_loop.structure, preheader, "postloop");
        post_loop_rri = lc_change_iteration_space_end(c, *c.main_loop_structure, c.main_loop_preheader, exit_main_loop_at, post_loop_preheader);
        lc_rewrite_incoming_values_for_phis(*post_loop.structure, post_loop_preheader, *post_loop_rri);
    }
    new_main_loop_preheader := ifx c.main_loop_preheader != preheader then c.main_loop_preheader else NONE;
    new_blocks := Value_Id.[post_loop_preheader, pre_loop_rri.pseudo_exit, pre_loop_rri.exit_selector,
                            post_loop_rri.pseudo_exit, post_loop_rri.exit_selector, new_main_loop_preheader];
    parent_loop := li_parent(li, c.original_loop);
    if parent_loop != NONE for new_blocks if it != NONE li_add_basic_block_to_loop(li, parent_loop, it);

    dt_recalculate(c.dt, c.f);

    pre_l: Loop_Id = NONE;
    post_l: Loop_Id = NONE;
    if pre_loop.blocks.count pre_l = lc_create_cloned_loop_structure(c, c.original_loop, li_parent(li, c.original_loop), *pre_loop.map, false);
    if post_loop.blocks.count post_l = lc_create_cloned_loop_structure(c, c.original_loop, li_parent(li, c.original_loop), *post_loop.map, false);

    canonicalize_loop :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, is_original_loop: bool) {
        form_lcssa_recursively(li, l, dt);
        simplify_loop(li, l, dt, null, null, true);
        if !is_original_loop lc_disable_all_loop_opts_on_loop(li, l);
    }
    if pre_l != NONE canonicalize_loop(li, pre_l, c.dt, false);
    if post_l != NONE canonicalize_loop(li, post_l, c.dt, false);
    canonicalize_loop(li, c.original_loop, c.dt, true);

    base := c.main_loop_structure.ind_var_base;
    if is_inst(base) && is_overflowing_binop(base) && is_signed_predicate set_nsw(base);
    return true;
}

// ---------------------------------------------------------------- calculateSubRanges

irce_calculate_sub_ranges :: (range: Irc_Range, ls: *Loop_Structure) -> (bool, Lc_Sub_Ranges) {
    result: Lc_Sub_Ranges;
    rty := sc_type(range.begin);
    if !irce_cl.allow_narrow_latch_condition && rty != ls.exit_count_ty return false, result;
    if type_int_width(rty) < type_int_width(ls.exit_count_ty) return false, result;
    is_signed := ls.is_signed_predicate;
    start := irce_noop_or_extend(sc_get_scev(ls.ind_var_start), rty, is_signed);
    end := irce_noop_or_extend(sc_get_scev(ls.loop_exit_at), rty, is_signed);
    increasing := ls.ind_var_increasing;
    smallest, greatest, greatest_seen: Scev_Id;
    one := sc_get_one(rty);
    if increasing {
        smallest = start;
        greatest = end;
        greatest_seen = sc_get_minus(end, one);
    } else {
        smallest = sc_get_add2(end, one);
        greatest = sc_get_add2(start, one);
        greatest_seen = start;
    }
    clamp :: (s: Scev_Id, smallest: Scev_Id, greatest: Scev_Id, signed: bool) -> Scev_Id {
        if signed return sc_get_smax2(smallest, sc_get_smin2(greatest, s));
        return sc_get_umax2(smallest, sc_get_umin2(greatest, s));
    }
    pred_le := ifx is_signed then cast(u8) ICMP_SLE else cast(u8) ICMP_ULE;
    pred_lt := ifx is_signed then cast(u8) ICMP_SLT else cast(u8) ICMP_ULT;
    provably_no_preloop := sc_is_known_predicate(pred_le, range.begin, smallest);
    if !provably_no_preloop result.low_limit = clamp(range.begin, smallest, greatest, is_signed);
    provably_no_postloop := sc_is_known_predicate(pred_lt, greatest_seen, range.end);
    if !provably_no_postloop result.high_limit = clamp(range.end, smallest, greatest, is_signed);
    return true, result;
}

// ---------------------------------------------------------------- InductiveRangeCheckElimination

Irce :: struct {
    f: Value_Id;
    bpi: *Bpi;
    dt: *Dom_Tree;
    li: *Loop_Info;
}

// estimatedTripCount: the new pass manager always passes GetBFI
irce_estimated_trip_count :: (c: *Irce, l: Loop_Id) -> (bool, u64) {
    bfi := get_bfi(c.f);
    se = get_scev(c.f);
    h_freq := bfi_get_block_freq(bfi, li_header(c.li, l));
    ph_freq := bfi_get_block_freq(bfi, li_loop_preheader(c.li, l));
    if ph_freq == 0 || h_freq == 0 return false, 0;
    return true, h_freq / ph_freq;
}

irce_run_loop :: (c: *Irce, l: Loop_Id) -> bool {
    li := c.li;
    if li_blocks(li, l).count >= irce_cl.loop_size_cutoff return false;
    preheader := li_loop_preheader(li, l);
    if preheader == NONE return false;
    has_etc, etc := irce_estimated_trip_count(c, l);
    if !irce_cl.skip_profitability_checks && has_etc && etc < cast(u64) irce_cl.min_eliminated_checks return false;

    range_checks: [..] Irc; range_checks.allocator = temp;
    changed := false;
    blocks: [..] Value_Id; blocks.allocator = temp;
    for li_blocks(li, l) array_add(*blocks, it);
    for bbi: blocks {
        t := block_terminator(bbi);
        if t != NONE && inst_op(t) == .CONDBR irc_extract_from_branch(t, l, li, c.bpi, has_etc, etc, *range_checks, *changed);
    }
    if range_checks.count == 0 return changed;

    if irce_cl.print_range_checks {
        sb: String_Builder; sb.allocator = temp;
        append(*sb, "irce: looking at loop "); li_print_loop(li, l, *sb);
        print_to_builder(*sb, "irce: loop has % inductive range checks: \n", range_checks.count);
        for range_checks irc_print(*sb, it);
        write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    }

    ok, ls, failure := parse_loop_structure(l, li, irce_cl.allow_unsigned_latch_condition);
    if !ok return changed;
    ind_var := sc_get_minus(sc_get_scev(ls.ind_var_base), sc_get_scev(ls.ind_var_step));
    if !sc_is_addrec(ind_var) fatal("irce: the induction variable is not an add recurrence (cast<SCEVAddRecExpr> fails in LLVM)");

    safe_iter_range: Irc_Range;
    to_eliminate: [..] Irc; to_eliminate.allocator = temp;
    for irc: range_checks {
        result := irc_compute_safe_iteration_space(irc, ind_var, ls.is_signed_predicate, li);
        if result.valid {
            maybe := irc_intersect_range(safe_iter_range, result, ls.is_signed_predicate);
            if maybe.valid {
                array_add(*to_eliminate, irc);
                safe_iter_range = maybe;
            }
        }
    }
    if !safe_iter_range.valid return changed;

    sr_ok, sr := irce_calculate_sub_ranges(safe_iter_range, *ls);
    if !sr_ok return false;

    lc: Loop_Constrainer;
    lc.f = c.f; lc.dt = c.dt; lc.li = li;
    lc.original_loop = l;
    lc.range_ty = sc_type(safe_iter_range.begin);
    lc.main_loop_structure = ls;
    lc.sr = sr;
    if lc_run(*lc) {
        changed = true;
        if irce_cl.print_changed_loops {
            sb: String_Builder; sb.allocator = temp;
            print_to_builder(*sb, "irce: in function %: constrained ", vname(c.f));
            li_print_loop(li, l, *sb);
            write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
        }
        t := const_int(type_int(1), 1);
        for to_eliminate set_op(it.check_user, it.check_op, t);
    }
    return changed;
}

// IRCEPass::run
irce_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    s := get_scev(f);
    bpi := get_bpi(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;

    c: Irce;
    c.f = f; c.bpi = bpi; c.dt = dt; c.li = li;
    changed := false;
    {
        cfg_changed := false;
        // `for (const auto &L : LI)`: L refers to the TopLevelLoops slot, so when simplifyLoop separates a nested loop
        // (changeTopLevelLoop puts the new outer loop into the slot) LCSSA is formed for the new outer loop
        n := li.top_level.count;
        for i: 0..n - 1 {
            se = s;
            cfg_changed |= simplify_loop(li, li.top_level[i], dt, null, null, false);
            se = s;
            changed |= form_lcssa_recursively(li, li.top_level[i], dt);
        }
        changed |= cfg_changed;
        if cfg_changed && !irce_cl.skip_profitability_checks fam_invalidate_one(f, .BFI);
    }
    w: Loop_Worklist;
    lwl_init(*w);
    append_loops_to_worklist_li(li, *w);
    while !lwl_empty(*w) {
        l := lwl_pop(*w);
        se = s;
        if irce_run_loop(*c, l) {
            changed = true;
            if !irce_cl.skip_profitability_checks fam_invalidate_one(f, .BFI);
        }
    }
    vh_release_all();
    if !changed return PRESERVE_ALL;
    return loop_pass_preserved();
}
