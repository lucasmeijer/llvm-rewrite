// ScalarEvolution, part 4: backedge-taken counts, exit limits and values at scopes.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): BackedgeTakenInfo / ExitLimit / ExitLimitCache,
// getBackedgeTakenInfo / getPredicatedBackedgeTakenInfo, computeBackedgeTakenCount, computeExitLimit(FromCond,
// FromCondFromBinOp, FromICmp, FromSingleExitSwitch), computeShiftCompareExitLimit, the constant-evolution brute
// force (getConstantEvolvingPHI, EvaluateExpression, getConstantEvolutionLoopExitValue,
// computeExitCountExhaustively), getSCEVAtScope / computeSCEVAtScope / BuildConstantFromSCEV / getWithOperands,
// SolveLinEquationWithOverflow, the quadratic solvers (and APIntOps::SolveQuadraticEquationWrap from
// llvm/lib/Support/APInt.cpp), howFarToZero / howFarToNonZero, howManyLessThans / howManyGreaterThans,
// computeMaxBECountForLT, getNumIterationsInRange, getTripCountFromExitCount and the getSmallConstant* queries.

SCEV_NULL :: cast(Scev_Id) 0xFFFF_FFFF;   // nullptr where LLVM distinguishes it from CouldNotCompute

Exit_Not_Taken :: struct {
    exiting: Value_Id;
    exact: Scev_Id;
    cmax: Scev_Id;
    smax: Scev_Id;
    preds: [..] u32;
}
Backedge_Taken_Info :: struct {
    ent: [..] Exit_Not_Taken;
    constant_max: Scev_Id = SCEV_NULL;
    complete: bool;
    symbolic_max: Scev_Id = SCEV_NULL;
    max_or_zero: bool;
}
Exit_Limit :: struct {
    exact: Scev_Id;
    cmax: Scev_Id;
    smax: Scev_Id;
    max_or_zero: bool;
    preds: [..] u32;
}
// ExitLimit(E)
el_of :: (e: Scev_Id) -> Exit_Limit { return el_make(e, e, e, false); }
// ExitLimit(E, ConstantMax, SymbolicMax, MaxOrZero, PredLists)
el_make :: (e: Scev_Id, cmax: Scev_Id, smax: Scev_Id, max_or_zero: bool, p1: [] u32 = .[], p2: [] u32 = .[]) -> Exit_Limit {
    r: Exit_Limit;
    r.exact = e; r.cmax = cmax; r.smax = smax; r.max_or_zero = max_or_zero;
    r.preds.allocator = temp;
    if sc_is_zero(cmax) { r.exact = cmax; r.smax = cmax; }
    for p1 { found := false; for q: r.preds if q == it { found = true; break; } if !found array_add(*r.preds, it); }
    for p2 { found := false; for q: r.preds if q == it { found = true; break; } if !found array_add(*r.preds, it); }
    return r;
}
el_has_any_info :: (e: Exit_Limit) -> bool { return e.exact != SCEV_CNC || e.cmax != SCEV_CNC; }
el_has_full_info :: (e: Exit_Limit) -> bool { return e.exact != SCEV_CNC; }

pred_list_append :: (out: *[..] u32, src: [] u32) { if out for src array_add(out, it); }

// BackedgeTakenInfo::getExact(L)
bti_get_exact :: (bti: *Backedge_Taken_Info, l: Loop_Id, preds: *[..] u32 = null) -> Scev_Id {
    if !bti.complete || bti.ent.count == 0 return SCEV_CNC;
    if li_loop_latch(se.li, l) == NONE return SCEV_CNC;
    ops: [..] Scev_Id; ops.allocator = temp;
    for * bti.ent {
        array_add(*ops, it.exact);
        pred_list_append(preds, it.preds);
    }
    return sc_get_umin_from_mismatched_types(*ops, true);
}
// getExitNotTaken
bti_get_exit_not_taken :: (bti: *Backedge_Taken_Info, exiting: Value_Id, preds: *[..] u32) -> *Exit_Not_Taken {
    for * bti.ent {
        if it.exiting == exiting {
            if it.preds.count == 0 return it;
            if preds { pred_list_append(preds, it.preds); return it; }
        }
    }
    return null;
}
bti_get_exact_block :: (bti: *Backedge_Taken_Info, exiting: Value_Id, preds: *[..] u32 = null) -> Scev_Id {
    e := bti_get_exit_not_taken(bti, exiting, preds);
    if e return e.exact;
    return SCEV_CNC;
}
bti_get_constant_max_block :: (bti: *Backedge_Taken_Info, exiting: Value_Id, preds: *[..] u32 = null) -> Scev_Id {
    e := bti_get_exit_not_taken(bti, exiting, preds);
    if e return e.cmax;
    return SCEV_CNC;
}
bti_get_symbolic_max_block :: (bti: *Backedge_Taken_Info, exiting: Value_Id, preds: *[..] u32 = null) -> Scev_Id {
    e := bti_get_exit_not_taken(bti, exiting, preds);
    if e return e.smax;
    return SCEV_CNC;
}
// getConstantMax(SE, Predicates)
bti_get_constant_max :: (bti: *Backedge_Taken_Info, preds: *[..] u32 = null) -> Scev_Id {
    if bti.constant_max == SCEV_NULL return SCEV_CNC;
    for * bti.ent {
        if it.preds.count > 0 {
            if !preds return SCEV_CNC;
            pred_list_append(preds, it.preds);
        }
    }
    return bti.constant_max;
}
// getSymbolicMax(L, SE, Predicates)
bti_get_symbolic_max :: (bti: *Backedge_Taken_Info, l: Loop_Id, preds: *[..] u32 = null) -> Scev_Id {
    if bti.symbolic_max == SCEV_NULL {
        exit_counts: [..] Scev_Id; exit_counts.allocator = temp;
        for * bti.ent {
            if it.smax != SCEV_CNC {
                array_add(*exit_counts, it.smax);
                pred_list_append(preds, it.preds);
            }
        }
        if exit_counts.count == 0 bti.symbolic_max = SCEV_CNC;
        else bti.symbolic_max = sc_get_umin_from_mismatched_types(*exit_counts, true);
    }
    return bti.symbolic_max;
}
bti_is_constant_max_or_zero :: (bti: *Backedge_Taken_Info) -> bool {
    if !bti.max_or_zero return false;
    for * bti.ent if it.preds.count > 0 return false;
    return true;
}
bti_has_any_info :: (bti: *Backedge_Taken_Info) -> bool { return bti.ent.count > 0 || bti.constant_max != SCEV_CNC; }

// ---------------------------------------------------------------- public queries

sc_get_backedge_taken_info :: (l: Loop_Id) -> *Backedge_Taken_Info {
    found, p := table_find(*se.btc, l);
    if found return p;
    bti := New(Backedge_Taken_Info);
    table_set(*se.btc, l, bti);   // try_emplace: recursive queries see an empty info
    result := sc_compute_backedge_taken_count(l, false);
    if bti_has_any_info(result) {
        to_forget: [..] Scev_Id; to_forget.allocator = temp;
        lu := table_find_pointer(*se.loop_users, l);
        if lu for lu.* array_add(*to_forget, it);
        sc_forget_memoized_results(to_forget);
        for i: block_insts(li_header(se.li, l)) {
            if inst_op(i) != .PHI break;
            table_remove(*se.const_evolution, i);
        }
    }
    found, p = table_find(*se.btc, l);
    if !found { p = New(Backedge_Taken_Info); table_set(*se.btc, l, p); }
    p.* = result.*;
    return p;
}
sc_get_predicated_backedge_taken_info :: (l: Loop_Id) -> *Backedge_Taken_Info {
    bti := sc_get_backedge_taken_info(l);
    if bti.complete return bti;
    found, p := table_find(*se.pred_btc, l);
    if found return p;
    np := New(Backedge_Taken_Info);
    table_set(*se.pred_btc, l, np);
    result := sc_compute_backedge_taken_count(l, true);
    found, p = table_find(*se.pred_btc, l);
    if !found { p = New(Backedge_Taken_Info); table_set(*se.pred_btc, l, p); }
    p.* = result.*;
    return p;
}

sc_get_backedge_taken_count :: (l: Loop_Id) -> Scev_Id { return bti_get_exact(sc_get_backedge_taken_info(l), l); }
sc_get_constant_max_backedge_taken_count :: (l: Loop_Id) -> Scev_Id { return bti_get_constant_max(sc_get_backedge_taken_info(l)); }
sc_get_symbolic_max_backedge_taken_count :: (l: Loop_Id) -> Scev_Id { return bti_get_symbolic_max(sc_get_backedge_taken_info(l), l); }
sc_get_predicated_backedge_taken_count :: (l: Loop_Id, preds: *[..] u32) -> Scev_Id {
    return bti_get_exact(sc_get_predicated_backedge_taken_info(l), l, preds);
}
sc_get_predicated_symbolic_max_backedge_taken_count :: (l: Loop_Id, preds: *[..] u32) -> Scev_Id {
    return bti_get_symbolic_max(sc_get_predicated_backedge_taken_info(l), l, preds);
}
sc_get_predicated_constant_max_backedge_taken_count :: (l: Loop_Id, preds: *[..] u32) -> Scev_Id {
    return bti_get_constant_max(sc_get_predicated_backedge_taken_info(l), preds);
}
sc_is_backedge_taken_count_max_or_zero :: (l: Loop_Id) -> bool { return bti_is_constant_max_or_zero(sc_get_backedge_taken_info(l)); }
// hasLoopInvariantBackedgeTakenCount
sc_has_loop_invariant_backedge_taken_count :: (l: Loop_Id) -> bool { return sc_get_backedge_taken_count(l) != SCEV_CNC; }

Exit_Count_Kind :: enum u8 { EXACT; SYMBOLIC_MAX; CONSTANT_MAX; }
sc_get_exit_count :: (l: Loop_Id, exiting: Value_Id, kind := Exit_Count_Kind.EXACT) -> Scev_Id {
    bti := sc_get_backedge_taken_info(l);
    if kind == {
        case .EXACT; return bti_get_exact_block(bti, exiting);
        case .SYMBOLIC_MAX; return bti_get_symbolic_max_block(bti, exiting);
        case .CONSTANT_MAX; return bti_get_constant_max_block(bti, exiting);
    }
    return SCEV_CNC;
}
sc_get_predicated_exit_count :: (l: Loop_Id, exiting: Value_Id, preds: *[..] u32, kind := Exit_Count_Kind.EXACT) -> Scev_Id {
    bti := sc_get_predicated_backedge_taken_info(l);
    if kind == {
        case .EXACT; return bti_get_exact_block(bti, exiting, preds);
        case .SYMBOLIC_MAX; return bti_get_symbolic_max_block(bti, exiting, preds);
        case .CONSTANT_MAX; return bti_get_constant_max_block(bti, exiting, preds);
    }
    return SCEV_CNC;
}

// forgetBackedgeTakenCounts(L, Predicated)
sc_forget_backedge_taken_counts :: (l: Loop_Id, predicated: bool) {
    tab := ifx predicated then *se.pred_btc else *se.btc;
    found, bti := table_find(tab, l);
    if !found return;
    key := ((cast(u64) l) << 1) | (ifx predicated then cast(u64) 1 else 0);
    for * bti.ent {
        for s: Scev_Id.[it.exact, it.smax] {
            if !sc_is_const(s) {
                u := table_find_pointer(*se.be_count_users, s);
                if u for u.* if it == key { array_unordered_remove_by_index(u, it_index); break; }
            }
        }
    }
    table_remove(tab, l);
}

// getTripCountFromExitCount(ExitCount)
sc_get_trip_count_from_exit_count :: (exit_count: Scev_Id) -> Scev_Id {
    if exit_count == SCEV_CNC return SCEV_CNC;
    eval_ty := type_int(1 + sc_bits(exit_count));
    return sc_get_trip_count_from_exit_count_ty(exit_count, eval_ty, NONE);
}
sc_get_trip_count_from_exit_count_ty :: (exit_count: Scev_Id, eval_ty: Type_Id, l: Loop_Id) -> Scev_Id {
    if exit_count == SCEV_CNC return SCEV_CNC;
    exit_count_size := sc_bits(exit_count);
    eval_size := type_int_width(eval_ty);
    can_add_one_without_overflow :: (exit_count: Scev_Id, exit_count_size: u32, l: Loop_Id) -> bool {
        r := sc_get_range_ref(exit_count, HINT_UNSIGNED);
        if !cr_contains(r, ap_all_ones(exit_count_size)) return true;
        return l != NONE && sc_is_loop_entry_guarded_by_cond(l, ICMP_NE, exit_count, sc_get_minus_one(sc_type(exit_count)));
    }
    if eval_size > exit_count_size && can_add_one_without_overflow(exit_count, exit_count_size, l)
        return sc_get_zero_extend(sc_get_add2(exit_count, sc_get_one(sc_type(exit_count))), eval_ty);
    return sc_get_add2(sc_get_truncate_or_zero_extend(exit_count, eval_ty), sc_get_one(eval_ty));
}
// getConstantTripCount
constant_trip_count :: (exit_count: Scev_Id) -> u32 {
    if !sc_is_const(exit_count) return 0;
    a := sc_ap(exit_count);
    if ap_active_bits(a) > 32 return 0;
    return cast,trunc(u32) ap_zext_value(a) + 1;
}
sc_get_small_constant_trip_count :: (l: Loop_Id) -> u32 { return constant_trip_count(sc_get_backedge_taken_count(l)); }
sc_get_small_constant_max_trip_count :: (l: Loop_Id) -> u32 { return constant_trip_count(sc_get_constant_max_backedge_taken_count(l)); }
// getSmallConstantTripMultiple(L)
sc_get_small_constant_trip_multiple :: (l: Loop_Id) -> u32 {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(se.li, l, *exiting);
    has := false;
    res: u32 = 0;
    for bb: exiting {
        multiple := sc_get_small_constant_trip_multiple_ec(l, sc_get_exit_count(l, bb));
        if !has { res = multiple; has = true; }
        res = gcd_u32(res, multiple);
    }
    if !has return 1;
    return res;
}
gcd_u32 :: (a_in: u32, b_in: u32) -> u32 {
    a := a_in; b := b_in;
    while b != 0 { t := a % b; a = b; b = t; }
    return a;
}
sc_get_small_constant_trip_multiple_ec :: (l: Loop_Id, exit_count: Scev_Id) -> u32 {
    if exit_count == SCEV_CNC return 1;
    tc_expr := sc_get_trip_count_from_exit_count(sc_apply_loop_guards(exit_count, l));
    multiple := sc_get_non_zero_constant_multiple(tc_expr);
    if ap_active_bits(multiple) > 32 return (cast(u32) 1) << min(31, ap_ctz(multiple));
    return cast,trunc(u32) ap_zext_value(multiple);
}

// ---------------------------------------------------------------- computeBackedgeTakenCount

sc_compute_backedge_taken_count :: (l: Loop_Id, allow_predicates: bool) -> *Backedge_Taken_Info {
    exiting_blocks: [..] Value_Id; exiting_blocks.allocator = temp;
    li_exiting_blocks(se.li, l, *exiting_blocks);
    Edge :: struct { bb: Value_Id; el: Exit_Limit; }
    exit_counts: [..] Edge; exit_counts.allocator = temp;
    could_compute := true;
    latch := li_loop_latch(se.li, l);
    must_exit_max: Scev_Id = SCEV_NULL;
    may_exit_max: Scev_Id = SCEV_NULL;
    must_exit_max_or_zero := false;
    is_only_exit := exiting_blocks.count == 1;
    for exit_bb: exiting_blocks {
        t := block_terminator(exit_bb);
        if inst_op(t) == .CONDBR && is_const_int(op(t, 0)) {
            exit_if_true := !li_contains(se.li, l, get_successor(t, 0));
            if exit_if_true == ap_is_zero(const_ap(op(t, 0))) continue;
        }
        el := sc_compute_exit_limit(l, exit_bb, is_only_exit, allow_predicates);
        if el.exact == SCEV_CNC could_compute = false;
        if el.smax != SCEV_CNC array_add(*exit_counts, .{exit_bb, el});
        if el.cmax != SCEV_CNC && latch != NONE && dt_dominates(se.dt, exit_bb, latch) {
            if must_exit_max == SCEV_NULL {
                must_exit_max = el.cmax;
                must_exit_max_or_zero = el.max_or_zero;
            } else must_exit_max = sc_get_umin_from_mismatched_types2(must_exit_max, el.cmax);
        } else if may_exit_max != SCEV_CNC {
            if may_exit_max == SCEV_NULL || el.cmax == SCEV_CNC may_exit_max = el.cmax;
            else may_exit_max = sc_get_umax_from_mismatched_types(may_exit_max, el.cmax);
        }
    }
    max_be := ifx must_exit_max != SCEV_NULL then must_exit_max else ifx may_exit_max != SCEV_NULL then may_exit_max else SCEV_CNC;
    max_or_zero := must_exit_max_or_zero && exiting_blocks.count == 1;
    key := ((cast(u64) l) << 1) | (ifx allow_predicates then cast(u64) 1 else 0);
    add_be_user :: (s: Scev_Id, key: u64) {
        p := table_find_pointer(*se.be_count_users, s);
        if !p { blank: [..] u64; table_set(*se.be_count_users, s, blank); p = table_find_pointer(*se.be_count_users, s); }
        for p.* if it == key return;
        array_add(p, key);
    }
    for exit_counts {
        if !sc_is_const(it.el.exact) add_be_user(it.el.exact, key);
        if !sc_is_const(it.el.smax) add_be_user(it.el.smax, key);
    }
    bti := New(Backedge_Taken_Info);
    for exit_counts {
        e: Exit_Not_Taken;
        e.exiting = it.bb; e.exact = it.el.exact; e.cmax = it.el.cmax; e.smax = it.el.smax;
        for p: it.el.preds array_add(*e.preds, p);
        array_add(*bti.ent, e);
    }
    bti.complete = could_compute;
    bti.constant_max = max_be;
    bti.max_or_zero = max_or_zero;
    return bti;
}

// computeExitLimit
sc_compute_exit_limit :: (l: Loop_Id, exiting: Value_Id, is_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    latch := li_loop_latch(se.li, l);
    if latch == NONE || !dt_dominates(se.dt, exiting, latch) return el_of(SCEV_CNC);
    t := block_terminator(exiting);
    if inst_op(t) == .CONDBR {
        exit_if_true := !li_contains(se.li, l, get_successor(t, 0));
        return sc_compute_exit_limit_from_cond(l, op(t, 0), exit_if_true, is_only_exit, allow_predicates);
    }
    if inst_op(t) == .SWITCH {
        exit: Value_Id = NONE;
        ns := num_successors(t);
        for i: 0..cast(s64) ns - 1 {
            sbb := get_successor(t, cast(u32) i);
            if !li_contains(se.li, l, sbb) {
                if exit != NONE return el_of(SCEV_CNC);
                exit = sbb;
            }
        }
        return sc_compute_exit_limit_from_single_exit_switch(l, t, exit, is_only_exit);
    }
    return el_of(SCEV_CNC);
}

Exit_Limit_Cache :: struct {
    keys: [..] u64;
    vals: [..] Exit_Limit;
}
// computeExitLimitFromCond
sc_compute_exit_limit_from_cond :: (l: Loop_Id, exit_cond: Value_Id, exit_if_true: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    cache: Exit_Limit_Cache;
    cache.keys.allocator = temp; cache.vals.allocator = temp;
    return sc_compute_exit_limit_from_cond_cached(*cache, l, exit_cond, exit_if_true, controls_only_exit, allow_predicates);
}
sc_compute_exit_limit_from_cond_cached :: (cache: *Exit_Limit_Cache, l: Loop_Id, exit_cond: Value_Id, exit_if_true: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    key := ((cast(u64) exit_cond) << 1) | (ifx controls_only_exit then cast(u64) 1 else 0);
    for cache.keys if it == key return cache.vals[it_index];
    el := sc_compute_exit_limit_from_cond_impl(cache, l, exit_cond, exit_if_true, controls_only_exit, allow_predicates);
    array_add(*cache.keys, key);
    array_add(*cache.vals, el);
    return el;
}

// m_LogicalAnd / m_LogicalOr: (and a, b), (select a, b, false) / (or a, b), (select a, true, b) on i1 (or vectors)
match_logical_and_or :: (v: Value_Id) -> (bool, bool, Value_Id, Value_Id) {
    if !is_inst(v) return false, false, NONE, NONE;
    o := inst_op(v);
    t := vtype(v);
    if !is_int_type_bits(scalar_type(t), 1) return false, false, NONE, NONE;
    if o == .AND return true, true, op(v, 0), op(v, 1);
    if o == .OR return true, false, op(v, 0), op(v, 1);
    if o == .SELECT && vtype(op(v, 0)) == t {
        tv := op(v, 1); fv := op(v, 2);
        if is_const(fv) && is_null_value(fv) return true, true, op(v, 0), tv;
        if is_const(tv) && cf_is_all_ones(tv) return true, false, op(v, 0), fv;
    }
    return false, false, NONE, NONE;
}

// computeExitLimitFromCondImpl
sc_compute_exit_limit_from_cond_impl :: (cache: *Exit_Limit_Cache, l: Loop_Id, exit_cond: Value_Id, exit_if_true: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    {
        ok, el := sc_compute_exit_limit_from_cond_from_bin_op(cache, l, exit_cond, exit_if_true, allow_predicates);
        if ok return el;
    }
    if is_inst(exit_cond) && inst_op(exit_cond) == .ICMP {
        el := sc_compute_exit_limit_from_icmp_inst(l, exit_cond, exit_if_true, controls_only_exit, false);
        if el_has_full_info(el) || !allow_predicates return el;
        return sc_compute_exit_limit_from_icmp_inst(l, exit_cond, exit_if_true, controls_only_exit, true);
    }
    if is_const_int(exit_cond) {
        if exit_if_true == ap_is_zero(const_ap(exit_cond)) return el_of(SCEV_CNC);
        return el_of(sc_get_zero(vtype(exit_cond)));
    }
    // extractvalue(with.overflow(X, C), 1)
    if is_inst(exit_cond) && inst_op(exit_cond) == .EXTRACTVALUE {
        idx := inst_indices(exit_cond);
        wo := op(exit_cond, 0);
        if idx.count == 1 && idx[0] == 1 && is_inst(wo) && is_with_overflow_inst(wo) && is_const_int(op(wo, 1)) {
            c := const_ap(op(wo, 1));
            id := call_iid(wo);
            bin: Opcode;
            unsigned: bool;
            if id == IID_SADD_WITH_OVERFLOW { bin = .ADD; unsigned = false; }
            else if id == IID_UADD_WITH_OVERFLOW { bin = .ADD; unsigned = true; }
            else if id == IID_SSUB_WITH_OVERFLOW { bin = .SUB; unsigned = false; }
            else if id == IID_USUB_WITH_OVERFLOW { bin = .SUB; unsigned = true; }
            else if id == IID_SMUL_WITH_OVERFLOW { bin = .MUL; unsigned = false; }
            else { bin = .MUL; unsigned = true; }
            nwr := cr_make_exact_no_wrap_region(bin, c, unsigned);
            pred, new_rhs_c, offset := cr_equivalent_icmp(nwr);
            if !exit_if_true pred = icmp_inverse(pred);
            lhs := sc_get_scev(op(wo, 0));
            if !ap_is_zero(offset) lhs = sc_get_add2(lhs, sc_get_constant(offset));
            el := sc_compute_exit_limit_from_icmp(l, pred, false, lhs, sc_get_constant(new_rhs_c), controls_only_exit, allow_predicates);
            if el_has_any_info(el) return el;
        }
    }
    return el_of(sc_compute_exit_count_exhaustively(l, exit_cond, exit_if_true));
}

// ConstantRange::makeExactNoWrapRegion
cr_make_exact_no_wrap_region :: (opc: Opcode, c: APInt, unsigned: bool) -> Const_Range {
    // makeGuaranteedNoWrapRegion(BinOp, ConstantRange(Other), NoWrapKind) for a single element
    return cr_guaranteed_no_wrap_region(opc, cr_single(c), unsigned);
}

// computeExitLimitFromCondFromBinOp
sc_compute_exit_limit_from_cond_from_bin_op :: (cache: *Exit_Limit_Cache, l: Loop_Id, exit_cond: Value_Id, exit_if_true: bool, allow_predicates: bool) -> (bool, Exit_Limit) {
    ok, is_and, op0, op1 := match_logical_and_or(exit_cond);
    if !ok { none: Exit_Limit; return false, none; }
    el0 := sc_compute_exit_limit_from_cond_cached(cache, l, op0, exit_if_true, false, allow_predicates);
    el1 := sc_compute_exit_limit_from_cond_cached(cache, l, op1, exit_if_true, false, allow_predicates);
    either_may_exit := is_and != exit_if_true;
    be_count := SCEV_CNC;
    cmax := SCEV_CNC;
    smax := SCEV_CNC;
    if either_may_exit {
        use_sequential_umin := !is_binary_operator(exit_cond);
        if el0.exact != SCEV_CNC && el1.exact != SCEV_CNC
            be_count = sc_get_umin_from_mismatched_types2(el0.exact, el1.exact, use_sequential_umin);
        if el0.cmax == SCEV_CNC cmax = el1.cmax;
        else if el1.cmax == SCEV_CNC cmax = el0.cmax;
        else cmax = sc_get_umin_from_mismatched_types2(el0.cmax, el1.cmax);
        if el0.smax == SCEV_CNC smax = el1.smax;
        else if el1.smax == SCEV_CNC smax = el0.smax;
        else smax = sc_get_umin_from_mismatched_types2(el0.smax, el1.smax, use_sequential_umin);
    } else {
        if el0.exact == el1.exact be_count = el0.exact;
    }
    if cmax == SCEV_CNC && be_count != SCEV_CNC cmax = sc_get_constant(sc_unsigned_range_max(be_count));
    if smax == SCEV_CNC smax = ifx be_count == SCEV_CNC then cmax else be_count;
    return true, el_make(be_count, cmax, smax, false, el0.preds, el1.preds);
}

// computeExitLimitFromICmp(L, ICmpInst *ExitCond, ...)
sc_compute_exit_limit_from_icmp_inst :: (l: Loop_Id, exit_cond: Value_Id, exit_if_true: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    pred := inst_pred(exit_cond);
    samesign := (opr_flags(exit_cond) & F_EXACT) != 0;
    if exit_if_true pred = icmp_inverse(pred);   // getInverseCmpPredicate keeps samesign
    original_pred := pred;
    lhs := sc_get_scev(op(exit_cond, 0));
    rhs := sc_get_scev(op(exit_cond, 1));
    el := sc_compute_exit_limit_from_icmp(l, pred, samesign, lhs, rhs, controls_only_exit, allow_predicates);
    if el_has_any_info(el) return el;
    exhaustive := sc_compute_exit_count_exhaustively(l, exit_cond, exit_if_true);
    if exhaustive != SCEV_CNC return el_of(exhaustive);
    return sc_compute_shift_compare_exit_limit(op(exit_cond, 0), op(exit_cond, 1), l, original_pred);
}

// computeExitLimitFromICmp(L, Pred, LHS, RHS, ...)
sc_compute_exit_limit_from_icmp :: (l: Loop_Id, pred_in: u8, samesign_in: bool, lhs_in: Scev_Id, rhs_in: Scev_Id, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    pred := pred_in;
    samesign := samesign_in;
    lhs := sc_get_scev_at_scope(lhs_in, l);
    rhs := sc_get_scev_at_scope(rhs_in, l);
    if sc_is_loop_invariant(lhs, l) && !sc_is_loop_invariant(rhs, l) {
        t := lhs; lhs = rhs; rhs = t;
        pred = icmp_swapped(pred);
    }
    controlling_finite_loop := controls_only_exit && sc_loop_has_no_abnormal_exits(l) && sc_loop_is_finite_by_assumption(l);
    sc_simplify_icmp_operands(*pred, *samesign, *lhs, *rhs, 0);

    if sc_is_const(rhs) && sc_is_addrec(lhs) && sc_loop(lhs) == l {
        comp_range := cr_exact_icmp_region(pred, sc_ap(rhs));
        ret := sc_get_num_iterations_in_range(lhs, comp_range);
        if ret != SCEV_CNC return el_of(ret);
    }

    if controlling_finite_loop && sc_is_loop_invariant(rhs, l) {
        inner_lhs := lhs;
        if sc_is_zext(lhs) inner_lhs = sc_op(lhs, 0);
        ar := inner_lhs;
        if sc_is_addrec(ar) && !sc_has_nw(ar) && sc_loop(ar) == l && sc_is_affine(ar) &&
           sc_is_known_to_be_a_power_of_two(sc_step_recurrence(ar), true, true) {
            flags := sc_flags(ar);
            flags = set_flags(flags, SF_NW);
            operands := sc_operands(ar);
            flags = strengthen_no_wrap_flags(.ADDREC, operands, flags);
            sc_set_no_wrap_flags(ar, flags);
        }
        if pred == ICMP_SLT || pred == ICMP_ULT {
            wrap_type := ifx pred == ICMP_SLT then SF_NSW else SF_NUW;
            ar2 := lhs;
            if sc_is_addrec(ar2) && sc_loop(ar2) == l && sc_is_affine(ar2) && sc_flags(ar2, wrap_type) == 0 && sc_has_nw(ar2) &&
               sc_is_known_positive(sc_step_recurrence(ar2)) {
                flags := sc_flags(ar2);
                flags = set_flags(flags, wrap_type);
                operands := sc_operands(ar2);
                flags = strengthen_no_wrap_flags(.ADDREC, operands, flags);
                sc_set_no_wrap_flags(ar2, flags);
            }
        }
    }

    if pred == {
        case ICMP_NE;
            if sc_is_ptr(lhs) { lhs = sc_get_lossless_ptr_to_int(lhs); if lhs == SCEV_CNC return el_of(lhs); }
            if sc_is_ptr(rhs) { rhs = sc_get_lossless_ptr_to_int(rhs); if rhs == SCEV_CNC return el_of(rhs); }
            el := sc_how_far_to_zero(sc_get_minus(lhs, rhs), l, controls_only_exit, allow_predicates);
            if el_has_any_info(el) return el;
        case ICMP_EQ;
            if sc_is_ptr(lhs) { lhs = sc_get_lossless_ptr_to_int(lhs); if lhs == SCEV_CNC return el_of(lhs); }
            if sc_is_ptr(rhs) { rhs = sc_get_lossless_ptr_to_int(rhs); if rhs == SCEV_CNC return el_of(rhs); }
            el := sc_how_far_to_non_zero(sc_get_minus(lhs, rhs), l);
            if el_has_any_info(el) return el;
        case ICMP_SLE; #through;
        case ICMP_ULE; #through;
        case ICMP_SLT; #through;
        case ICMP_ULT;
            for 0..0 {
                if pred == ICMP_SLE || pred == ICMP_ULE {
                    if !controlling_finite_loop || !sc_is_loop_invariant(rhs, l) {
                        if !is_int_type(sc_type(lhs)) break;
                        new_type := type_int(type_int_width(sc_type(lhs)) * 2);
                        if icmp_is_signed(pred) {
                            lhs = sc_get_sign_extend(lhs, new_type);
                            rhs = sc_get_sign_extend(rhs, new_type);
                        } else {
                            lhs = sc_get_zero_extend(lhs, new_type);
                            rhs = sc_get_zero_extend(rhs, new_type);
                        }
                    }
                    rhs = sc_get_add2(sc_get_one(sc_type(rhs)), rhs);
                }
                is_signed := icmp_is_signed(pred);
                el := sc_how_many_less_thans(lhs, rhs, l, is_signed, controls_only_exit, allow_predicates);
                if el_has_any_info(el) return el;
            }
        case ICMP_SGE; #through;
        case ICMP_UGE; #through;
        case ICMP_SGT; #through;
        case ICMP_UGT;
            for 0..0 {
                if pred == ICMP_SGE || pred == ICMP_UGE {
                    if !controlling_finite_loop || !sc_is_loop_invariant(rhs, l) break;
                    rhs = sc_get_add2(sc_get_minus_one(sc_type(rhs)), rhs);
                }
                is_signed := icmp_is_signed(pred);
                el := sc_how_many_greater_thans(lhs, rhs, l, is_signed, controls_only_exit, allow_predicates);
                if el_has_any_info(el) return el;
            }
    }
    return el_of(SCEV_CNC);
}

// computeExitLimitFromSingleExitSwitch
sc_compute_exit_limit_from_single_exit_switch :: (l: Loop_Id, sw: Value_Id, exiting: Value_Id, controls_only_exit: bool) -> Exit_Limit {
    if get_successor(sw, 0) == exiting return el_of(SCEV_CNC);
    lhs := sc_get_scev_at_scope_value(op(sw, 0), l);
    // SwitchInst::findCaseDest: the unique case value branching to the block
    case_val: Value_Id = NONE;
    ns := num_successors(sw);
    for i: 1..cast(s64) ns - 1 {
        if get_successor(sw, cast(u32) i) == exiting {
            if case_val != NONE { case_val = NONE; break; }
            case_val = switch_case_value(sw, cast(u32) i - 1);
        }
    }
    if case_val == NONE fatal("ScalarEvolution: SwitchInst::findCaseDest returned null");
    rhs := sc_get_constant_value(case_val);
    el := sc_how_far_to_zero(sc_get_minus(lhs, rhs), l, controls_only_exit);
    if el_has_any_info(el) return el;
    return el_of(SCEV_CNC);
}
// the case value of case `k` (successor k + 1)
switch_case_value :: (sw: Value_Id, k: u32) -> Value_Id { return ir.u_aux[ir.v_ops[sw] + 2 + k]; }

// EvaluateConstantChrecAtConstant
evaluate_constant_chrec_at_constant :: (ar: Scev_Id, c: APInt) -> APInt {
    val := evaluate_at_iteration(ar, sc_get_constant(c));
    if !sc_is_const(val) fatal("ScalarEvolution: evaluation of SCEV at constant didn't fold");
    return sc_ap(val);
}

// computeShiftCompareExitLimit
sc_compute_shift_compare_exit_limit :: (lhs_in: Value_Id, rhsv: Value_Id, l: Loop_Id, pred: u8) -> Exit_Limit {
    lhs := lhs_in;
    if !is_const_int(rhsv) return el_of(SCEV_CNC);
    rhs := rhsv;
    latch := li_loop_latch(se.li, l);
    if latch == NONE return el_of(SCEV_CNC);
    predecessor := li_loop_predecessor(se.li, l);
    if predecessor == NONE return el_of(SCEV_CNC);

    match_positive_shift :: (v: Value_Id) -> (bool, Value_Id, Opcode, u32) {
        if !is_binary_operator(v) && vkind(v) != .C_EXPR return false, NONE, .NONE_OP, 0;
        o := opr_code(v);
        if o != .LSHR && o != .ASHR && o != .SHL return false, NONE, .NONE_OP, 0;
        sa := op(v, 1);
        if !is_const_int(sa) return false, NONE, .NONE_OP, 0;
        out_lhs := op(v, 0);
        amt := ap_limited(const_ap(sa));
        if amt == 0 || amt >= cast(u64) type_bits(scalar_type(vtype(out_lhs))) return false, NONE, .NONE_OP, 0;
        return true, out_lhs, o, cast(u32) amt;
    }
    has_post := false;
    post_opc: Opcode;
    {
        ok, v, opc, amt := match_positive_shift(lhs);
        if ok { has_post = true; post_opc = opc; lhs = v; }
    }
    pn := lhs;
    if !is_inst(pn) || inst_op(pn) != .PHI || inst_block(pn) != li_header(se.li, l) return el_of(SCEV_CNC);
    be_value := phi_incoming_value_for_block(pn, latch);
    ok, op_lhs, opcode, shift_amt := match_positive_shift(be_value);
    if !(ok && op_lhs == pn && (!has_post || post_opc == opcode)) return el_of(SCEV_CNC);

    ty := vtype(rhs);
    stable_value: Value_Id;
    if opcode == .ASHR {
        first_value := phi_incoming_value_for_block(pn, predecessor);
        known := known_bits_ctx(first_value, block_terminator(predecessor), se.dt, se.ac);
        if kb_is_non_negative(known) stable_value = const_int(ty, 0);
        else if kb_is_negative(known) stable_value = const_int_words(ty, ap_words(ap_all_ones(type_int_width(ty))));
        else return el_of(SCEV_CNC);
    } else {
        stable_value = const_int(ty, 0);
    }
    result := cfo_compare_inst_operands(pred, stable_value, rhs);
    if result != NONE && is_null_value(result) {
        bits := sc_type_bits(ty);
        max_btc := bits;
        if opcode == .LSHR || opcode == .ASHR {
            start_value := phi_incoming_value_for_block(pn, predecessor);
            start_scev := sc_get_scev(start_value);
            max_start := sc_unsigned_range_max(start_scev);
            if ap_is_strictly_positive(max_start) {
                active := ap_active_bits(max_start);
                range_btc := (active + shift_amt - 1) / shift_amt;
                max_btc = min(max_btc, range_btc);
            }
        }
        upper_bound := sc_get_constant_t(sc_effective_type(ty), cast(u64) max_btc);
        return el_make(SCEV_CNC, upper_bound, upper_bound, false);
    }
    return el_of(SCEV_CNC);
}

// ---------------------------------------------------------------- constant evolution

// CanConstantFold
can_constant_fold :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if is_binary_op(o) || o == .ICMP || o == .FCMP || o == .SELECT || is_cast_op(o) || o == .GEP || o == .LOAD || o == .EXTRACTVALUE
        return true;
    if o == .CALL {
        f := call_called_function(i);
        if f != NONE return can_constant_fold_call_to(i, f);
    }
    return false;
}
// canConstantEvolve
can_constant_evolve :: (i: Value_Id, l: Loop_Id) -> bool {
    if !li_contains(se.li, l, inst_block(i)) return false;
    if inst_op(i) == .PHI return li_header(se.li, l) == inst_block(i);
    return can_constant_fold(i);
}
// getConstantEvolvingPHIOperands
get_constant_evolving_phi_operands :: (use_inst: Value_Id, l: Loop_Id, phi_map: *Table(Value_Id, Value_Id), depth: u32) -> Value_Id {
    if cast(u64) depth > scev_opts.max_constant_evolving_depth return NONE;
    phi: Value_Id = NONE;
    for k: 0..cast(s64) nops(use_inst) - 1 {
        o := op(use_inst, cast(u32) k);
        if is_const(o) continue;
        if !is_inst(o) || !can_constant_evolve(o, l) return NONE;
        p: Value_Id = NONE;
        if inst_op(o) == .PHI p = o;
        if p == NONE { found, pv := table_find(phi_map, o); if found p = pv; }
        if p == NONE {
            p = get_constant_evolving_phi_operands(o, l, phi_map, depth + 1);
            table_set(phi_map, o, p);
        }
        if p == NONE return NONE;
        if phi != NONE && phi != p return NONE;
        phi = p;
    }
    return phi;
}
// getConstantEvolvingPHI
get_constant_evolving_phi :: (v: Value_Id, l: Loop_Id) -> Value_Id {
    if !is_inst(v) || !can_constant_evolve(v, l) return NONE;
    if inst_op(v) == .PHI return v;
    phi_map: Table(Value_Id, Value_Id); phi_map.allocator = temp;
    return get_constant_evolving_phi_operands(v, l, *phi_map, 0);
}
// EvaluateExpression (NONE = nullptr)
evaluate_expression :: (v: Value_Id, l: Loop_Id, vals: *Table(Value_Id, Value_Id)) -> Value_Id {
    if is_const(v) return v;
    if !is_inst(v) return NONE;
    {
        found, c := table_find(vals, v);
        if found && c != NONE return c;
    }
    if !can_constant_evolve(v, l) return NONE;
    if inst_op(v) == .PHI return NONE;
    n := nops(v);
    operands := NewArray(n, Value_Id,, allocator = temp);
    for k: 0..cast(s64) n - 1 {
        o := op(v, cast(u32) k);
        if !is_inst(o) {
            if !is_const(o) return NONE;
            operands[k] = o;
            continue;
        }
        c := evaluate_expression(o, l, vals);
        table_set(vals, o, c);
        if c == NONE return NONE;
        operands[k] = c;
    }
    return cfo_inst_operands(v, operands, false);
}
// getOtherIncomingValue
get_other_incoming_value :: (pn: Value_Id, bb: Value_Id) -> Value_Id {
    incoming: Value_Id = NONE;
    for i: 0..cast(s64) nops(pn) - 1 {
        if phi_block(pn, cast(u32) i) == bb continue;
        cur := phi_value(pn, cast(u32) i);
        if !is_const(cur) return NONE;
        if incoming != cur {
            if incoming != NONE return NONE;
            incoming = cur;
        }
    }
    return incoming;
}
// getConstantEvolutionLoopExitValue (NONE = nullptr)
sc_get_constant_evolution_loop_exit_value :: (pn: Value_Id, bes: APInt, l: Loop_Id) -> Value_Id {
    {
        found, v := table_find(*se.const_evolution, pn);
        if found return v;
    }
    table_set(*se.const_evolution, pn, NONE);
    if ap_ugt_u64(bes, scev_opts.max_brute_force_iterations) return NONE;
    header := li_header(se.li, l);
    latch := li_loop_latch(se.li, l);
    if latch == NONE return NONE;
    cur: Table(Value_Id, Value_Id); cur.allocator = temp;
    for phi: block_insts(header) {
        if inst_op(phi) != .PHI break;
        sc := get_other_incoming_value(phi, latch);
        if sc != NONE table_set(*cur, phi, sc);
    }
    if !table_contains(*cur, pn) { table_set(*se.const_evolution, pn, NONE); return NONE; }
    be_value := phi_incoming_value_for_block(pn, latch);
    num_iterations := cast(u32) ap_zext_value(bes);
    iteration: u32 = 0;
    while true {
        if iteration == num_iterations {
            found, r := table_find(*cur, pn);
            if !found r = NONE;
            table_set(*se.const_evolution, pn, r);
            return r;
        }
        next: Table(Value_Id, Value_Id); next.allocator = temp;
        next_phi := evaluate_expression(be_value, l, *cur);
        if next_phi == NONE return NONE;
        table_set(*next, pn, next_phi);
        f0, cur_pn := table_find(*cur, pn);
        stopped := next_phi == cur_pn;
        to_compute: [..] Value_Id; to_compute.allocator = temp;
        to_compute_vals: [..] Value_Id; to_compute_vals.allocator = temp;
        for v, k: cur {
            if !(is_inst(k) && inst_op(k) == .PHI) || k == pn || inst_block(k) != header continue;
            array_add(*to_compute, k); array_add(*to_compute_vals, v);
        }
        for phi, j: to_compute {
            found, np := table_find(*next, phi);
            if !found || np == NONE {
                bev := phi_incoming_value_for_block(phi, latch);
                np = evaluate_expression(bev, l, *cur);
                table_set(*next, phi, np);
            }
            if np != to_compute_vals[j] stopped = false;
        }
        if stopped {
            found, r := table_find(*cur, pn);
            if !found r = NONE;
            table_set(*se.const_evolution, pn, r);
            return r;
        }
        cur = next;
        iteration += 1;
    }
    return NONE;
}

// computeExitCountExhaustively
sc_compute_exit_count_exhaustively :: (l: Loop_Id, cond: Value_Id, exit_when: bool) -> Scev_Id {
    pn := get_constant_evolving_phi(cond, l);
    if pn == NONE return SCEV_CNC;
    if nops(pn) != 2 return SCEV_CNC;
    header := li_header(se.li, l);
    latch := li_loop_latch(se.li, l);
    cur: Table(Value_Id, Value_Id); cur.allocator = temp;
    for phi: block_insts(header) {
        if inst_op(phi) != .PHI break;
        sc := get_other_incoming_value(phi, latch);
        if sc != NONE table_set(*cur, phi, sc);
    }
    if !table_contains(*cur, pn) return SCEV_CNC;
    max_iterations := scev_opts.max_brute_force_iterations;
    iteration: u64 = 0;
    while iteration != max_iterations {
        cv := evaluate_expression(cond, l, *cur);
        if cv == NONE || !is_const_int(cv) return SCEV_CNC;
        if ap_eq_u64(const_ap(cv), ifx exit_when then cast(u64) 1 else 0) return sc_get_constant_t(type_int(32), iteration);
        next: Table(Value_Id, Value_Id); next.allocator = temp;
        to_compute: [..] Value_Id; to_compute.allocator = temp;
        for v, k: cur {
            if !(is_inst(k) && inst_op(k) == .PHI) || inst_block(k) != header continue;
            array_add(*to_compute, k);
        }
        for phi: to_compute {
            found, np := table_find(*next, phi);
            if found && np != NONE continue;
            bev := phi_incoming_value_for_block(phi, latch);
            np = evaluate_expression(bev, l, *cur);
            table_set(*next, phi, np);
        }
        cur = next;
        iteration += 1;
    }
    return SCEV_CNC;
}

// ---------------------------------------------------------------- values at scopes

sc_get_scev_at_scope_value :: (v: Value_Id, l: Loop_Id) -> Scev_Id { return sc_get_scev_at_scope(sc_get_scev(v), l); }

sc_get_scev_at_scope :: (v: Scev_Id, l: Loop_Id) -> Scev_Id {
    p := table_find_pointer(*se.values_at_scopes, v);
    if !p { blank: [..] Scope_Entry; table_set(*se.values_at_scopes, v, blank); p = table_find_pointer(*se.values_at_scopes, v); }
    for p.* if it.l == l { if it.s == NONE return v; return it.s; }
    array_add(p, .{l, NONE});
    c := sc_compute_scev_at_scope(v, l);
    p = table_find_pointer(*se.values_at_scopes, v);
    if p {
        for < k: 0..p.count-1 {
            if p.*[k].l == l {
                p.*[k].s = c;
                if !sc_is_const(c) {
                    u := table_find_pointer(*se.values_at_scopes_users, c);
                    if !u { blank: [..] Scope_Entry; table_set(*se.values_at_scopes_users, c, blank); u = table_find_pointer(*se.values_at_scopes_users, c); }
                    array_add(u, .{l, v});
                }
                break;
            }
        }
    }
    return c;
}

// BuildConstantFromSCEV (NONE = nullptr)
build_constant_from_scev :: (v: Scev_Id) -> Value_Id {
    k := sc_kind(v);
    if k == {
        case .CONSTANT; return sc_value(v);
        case .UNKNOWN; if is_const(sc_value(v)) return sc_value(v); return NONE;
        case .PTRTOADDR;
            c := build_constant_from_scev(sc_op(v, 0));
            if c != NONE return ce_cast(.PTRTOADDR, c, sc_type(v));
            return NONE;
        case .PTRTOINT;
            c := build_constant_from_scev(sc_op(v, 0));
            if c != NONE return ce_cast(.PTRTOINT, c, sc_type(v));
            return NONE;
        case .TRUNC;
            c := build_constant_from_scev(sc_op(v, 0));
            if c != NONE return ce_cast(.TRUNC, c, sc_type(v));
            return NONE;
        case .ADD;
            c: Value_Id = NONE;
            for i: 0..cast(s64) sc_nops(v) - 1 {
                opc := build_constant_from_scev(sc_op(v, cast(u32) i));
                if opc == NONE return NONE;
                if c == NONE { c = opc; continue; }
                if type_kind(vtype(opc)) == .PTR c = ce_gep(type_int(8), opc, .[c], 0);
                else c = ce_binop(.ADD, c, opc, 0);
            }
            return c;
    }
    return NONE;
}

// getWithOperands
sc_get_with_operands :: (s: Scev_Id, new_ops: *[..] Scev_Id) -> Scev_Id {
    k := sc_kind(s);
    if k == {
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .PTRTOADDR; #through; case .PTRTOINT;
            return sc_get_cast(k, new_ops.*[0], sc_type(s));
        case .ADDREC; return sc_get_add_rec_ops(new_ops, sc_loop(s), sc_flags(s));
        case .ADD; return sc_get_add(new_ops, sc_flags(s));
        case .MUL; return sc_get_mul(new_ops, sc_flags(s));
        case .UDIV; return sc_get_udiv(new_ops.*[0], new_ops.*[1]);
        case .UMAX; #through; case .SMAX; #through; case .UMIN; #through; case .SMIN; return sc_get_min_max(k, new_ops);
        case .SEQ_UMIN; return sc_get_sequential_min_max(k, new_ops);
    }
    return s;
}

// computeSCEVAtScope
sc_compute_scev_at_scope :: (v: Scev_Id, l: Loop_Id) -> Scev_Id {
    k := sc_kind(v);
    if k == .CONSTANT || k == .VSCALE return v;
    if k == .ADDREC {
        add_rec := v;
        n := sc_nops(add_rec);
        i: u32 = 0;
        while i != n {
            op_at_scope := sc_get_scev_at_scope(sc_op(add_rec, i), l);
            if op_at_scope == sc_op(add_rec, i) { i += 1; continue; }
            new_ops: [..] Scev_Id; new_ops.allocator = temp;
            for j: 0..cast(s64) i - 1 array_add(*new_ops, sc_op(add_rec, cast(u32) j));
            array_add(*new_ops, op_at_scope);
            i += 1;
            while i != n { array_add(*new_ops, sc_get_scev_at_scope(sc_op(add_rec, i), l)); i += 1; }
            folded := sc_get_add_rec_ops(*new_ops, sc_loop(add_rec), sc_flags(add_rec, SF_NW));
            if !sc_is_addrec(folded) return folded;
            add_rec = folded;
            break;
        }
        if !li_contains_loop(se.li, sc_loop(add_rec), l) {
            btc := sc_get_backedge_taken_count(sc_loop(add_rec));
            if btc == SCEV_CNC return add_rec;
            return evaluate_at_iteration(add_rec, btc);
        }
        return add_rec;
    }
    if k == .UNKNOWN {
        i := sc_value(v);
        if !is_inst(i) return v;
        if inst_op(i) == .PHI {
            curr := li_loop_for(se.li, inst_block(i));
            if curr != NONE && li_parent(se.li, curr) == l && inst_block(i) == li_header(se.li, curr) {
                btc := sc_get_backedge_taken_count(curr);
                if sc_is_zero(btc) {
                    init_value: Value_Id = NONE;
                    multiple := false;
                    for j: 0..cast(s64) nops(i) - 1 {
                        if !li_contains(se.li, curr, phi_block(i, cast(u32) j)) {
                            if init_value == NONE init_value = phi_value(i, cast(u32) j);
                            else if init_value != phi_value(i, cast(u32) j) { multiple = true; break; }
                        }
                    }
                    if !multiple && init_value != NONE return sc_get_scev(init_value);
                }
                if btc != SCEV_CNC && sc_is_known_non_zero(btc) && nops(i) == 2 {
                    in_loop_pred: u32 = ifx li_contains(se.li, curr, phi_block(i, 0)) then cast(u32) 0 else 1;
                    be_val := phi_value(i, in_loop_pred);
                    if li_is_loop_invariant(se.li, curr, be_val) return sc_get_scev(be_val);
                }
                if sc_is_const(btc) {
                    rv := sc_get_constant_evolution_loop_exit_value(i, sc_ap(btc), curr);
                    if rv != NONE return sc_get_scev(rv);
                }
            }
        }
        if !can_constant_fold(i) return v;
        operands: [..] Value_Id; operands.allocator = temp;
        made_improvement := false;
        for j: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) j);
            if is_const(o) { array_add(*operands, o); continue; }
            if !sc_is_scevable(vtype(o)) return v;
            orig := sc_get_scev(o);
            opv := sc_get_scev_at_scope(orig, l);
            made_improvement |= orig != opv;
            c := build_constant_from_scev(opv);
            if c == NONE return v;
            array_add(*operands, c);
        }
        if !made_improvement return v;
        c := cfo_inst_operands(i, operands, false);
        if c == NONE return v;
        return sc_get_scev(c);
    }
    // casts, add, mul, udiv, min/max
    n := sc_nops(v);
    for i: 0..cast(s64) n - 1 {
        op_at_scope := sc_get_scev_at_scope(sc_op(v, cast(u32) i), l);
        if op_at_scope != sc_op(v, cast(u32) i) {
            new_ops: [..] Scev_Id; new_ops.allocator = temp;
            for j: 0..i-1 array_add(*new_ops, sc_op(v, cast(u32) j));
            array_add(*new_ops, op_at_scope);
            for j: i+1..cast(s64) n - 1 array_add(*new_ops, sc_get_scev_at_scope(sc_op(v, cast(u32) j), l));
            return sc_get_with_operands(v, *new_ops);
        }
    }
    return v;
}

// stripInjectiveFunctions
strip_injective_functions :: (s: Scev_Id) -> Scev_Id {
    if sc_is_zext(s) || sc_is_sext(s) return strip_injective_functions(sc_op(s, 0));
    return s;
}

// ---------------------------------------------------------------- equation solvers

// SolveLinEquationWithOverflow
solve_lin_equation_with_overflow :: (a: APInt, b: Scev_Id, preds: *[..] u32, l: Loop_Id) -> Scev_Id {
    bw := a.bits;
    mult2 := ap_ctz(a);
    min_tz := sc_get_min_trailing_zeros(b);
    if min_tz < mult2 && li_loop_predecessor(se.li, l) != NONE
        min_tz = sc_get_min_trailing_zeros(b, block_terminator(li_loop_predecessor(se.li, l)));
    if min_tz < mult2 {
        urem := sc_get_urem(b, sc_get_constant(ap_one_bit_set(bw, mult2)));
        zero := sc_get_zero(sc_type(b));
        if !sc_is_known_predicate(ICMP_EQ, urem, zero) {
            if !preds return SCEV_CNC;
            if sc_is_known_predicate(ICMP_NE, urem, zero) return SCEV_CNC;
            array_add(preds, sc_get_equal_predicate(urem, zero));
        }
    }
    ad := ap_trunc(ap_lshr(a, mult2), bw - mult2);
    i := ap_zext(ap_multiplicative_inverse(ad), bw);
    d := sc_get_constant(ap_one_bit_set(bw, mult2));
    return sc_get_udiv_exact(sc_get_mul2(b, sc_get_constant(i)), d);
}

// APIntOps::SolveQuadraticEquationWrap (llvm/lib/Support/APInt.cpp); has = false is std::nullopt
solve_quadratic_equation_wrap :: (a_in: APInt, b_in: APInt, c_in: APInt, range_width: u32) -> (bool, APInt) {
    coeff_width := a_in.bits;
    if ap_is_zero(ap_sext_or_trunc(c_in, range_width)) return true, ap_zero(coeff_width);
    coeff_width *= 3;
    a := ap_sext(a_in, coeff_width);
    b := ap_sext(b_in, coeff_width);
    c := ap_sext(c_in, coeff_width);
    if ap_is_negative(a) { a = ap_neg(a); b = ap_neg(b); c = ap_neg(c); }
    r := ap_one_bit_set(coeff_width, range_width);
    two_a := ap_mul(ap_from_u64(coeff_width, 2), a);
    sqr_b := ap_mul(b, b);
    pick_low: bool;
    round_up :: (v: APInt, a: APInt) -> APInt {
        t := ap_urem(ap_abs(v), a);
        if ap_is_zero(t) return v;
        if ap_is_negative(v) return ap_add(v, t);
        return ap_add(v, ap_sub(a, t));
    }
    if !ap_is_negative(b) {
        c = ap_srem(c, r);
        if ap_is_strictly_positive(c) c = ap_sub(c, r);
        pick_low = false;
    } else {
        lowk_r := ap_sub(c, ap_udiv(sqr_b, ap_mul(ap_from_u64(coeff_width, 2), two_a)));
        lowk_r = round_up(lowk_r, r);
        if ap_sgt(c, lowk_r) {
            c = ap_sub(c, ap_neg(round_up(ap_neg(c), r)));
            pick_low = true;
        } else {
            c = ap_sub(c, lowk_r);
            pick_low = false;
        }
    }
    d := ap_sub(sqr_b, ap_mul(ap_mul(ap_from_u64(coeff_width, 4), a), c));
    sq := ap_sqrt(d);
    q := ap_mul(sq, sq);
    inexact_sq := !ap_eq(q, d);
    x, rem: APInt;
    if pick_low {
        num := ap_sub(ap_neg(b), ap_add(sq, ap_from_u64(coeff_width, ifx inexact_sq then cast(u64) 1 else 0)));
        x = ap_sdiv(num, two_a); rem = ap_srem(num, two_a);
    } else {
        num := ap_add(ap_neg(b), sq);
        x = ap_sdiv(num, two_a); rem = ap_srem(num, two_a);
    }
    if !inexact_sq && ap_is_zero(rem) return true, x;
    vx := ap_add(ap_mul(ap_add(ap_mul(a, x), b), x), c);
    vy := ap_add(ap_add(ap_add(vx, ap_mul(two_a, x)), a), b);
    sign_change := ap_is_negative(vx) != ap_is_negative(vy) || ap_is_zero(vx) != ap_is_zero(vy);
    if !sign_change return false, ap_zero(1);
    return true, ap_add_u64(x, 1);
}

// GetQuadraticEquation
Quadratic :: struct { a: APInt; b: APInt; c: APInt; m: APInt; bits: u32; }
get_quadratic_equation :: (ar: Scev_Id) -> (bool, Quadratic) {
    q: Quadratic;
    lc := sc_op(ar, 0); mc := sc_op(ar, 1); nc := sc_op(ar, 2);
    if !sc_is_const(lc) || !sc_is_const(mc) || !sc_is_const(nc) return false, q;
    bits := sc_ap(lc).bits;
    nw := bits + 1;
    n := ap_sext(sc_ap(nc), nw);
    m := ap_sext(sc_ap(mc), nw);
    l := ap_sext(sc_ap(lc), nw);
    q.a = n;
    q.b = ap_sub(ap_mul(ap_from_u64(nw, 2), m), q.a);
    q.c = ap_mul(ap_from_u64(nw, 2), l);
    q.m = ap_from_u64(nw, 2);
    q.bits = bits;
    return true, q;
}
// MinOptional
min_optional :: (hx: bool, x: APInt, hy: bool, y: APInt) -> (bool, APInt) {
    if hx && hy {
        w := max(x.bits, y.bits);
        if ap_slt(ap_sext(x, w), ap_sext(y, w)) return true, x;
        return true, y;
    }
    if !hx && !hy return false, x;
    if hx return true, x;
    return true, y;
}
// TruncIfPossible
trunc_if_possible :: (hx: bool, x: APInt, bits: u32) -> (bool, APInt) {
    if !hx return false, x;
    w := x.bits;
    if bits > 1 && bits < w && ap_active_bits(x) <= bits return true, ap_trunc(x, bits);
    return true, x;
}
// SolveQuadraticAddRecExact
solve_quadratic_add_rec_exact :: (ar: Scev_Id) -> (bool, APInt) {
    ok, q := get_quadratic_equation(ar);
    if !ok return false, ap_zero(1);
    hx, x := solve_quadratic_equation_wrap(q.a, q.b, q.c, q.bits + 1);
    if !hx return false, x;
    v := evaluate_constant_chrec_at_constant(ar, x);
    if !ap_is_zero(v) return false, x;
    o, r := trunc_if_possible(true, x, q.bits);
    return o, r;
}
// SolveQuadraticAddRecRange
solve_quadratic_add_rec_range :: (ar: Scev_Id, range: Const_Range) -> (bool, APInt) {
    ok, q := get_quadratic_equation(ar);
    if !ok return false, ap_zero(1);
    solve_for_boundary :: (bound_in: APInt, q: Quadratic, ar: Scev_Id, range: Const_Range) -> (has: bool, x: APInt, ok: bool) {
        bound := ap_mul(bound_in, q.m);
        hso := false; so: APInt;
        if q.bits > 1 hso, so = solve_quadratic_equation_wrap(q.a, q.b, ap_neg(bound), q.bits);
        huo, uo := solve_quadratic_equation_wrap(q.a, q.b, ap_neg(bound), q.bits + 1);
        leaves_range :: (x: APInt, ar: Scev_Id, range: Const_Range) -> bool {
            v0 := evaluate_constant_chrec_at_constant(ar, x);
            if cr_contains(range, v0) return false;
            v1 := evaluate_constant_chrec_at_constant(ar, ap_sub_u64(x, 1));
            if cr_contains(range, v1) return true;
            return false;
        }
        if !hso || !huo return false, so, false;
        hmin, mn := min_optional(hso, so, huo, uo);
        if leaves_range(mn, ar, range) return true, mn, true;
        mx := ifx ap_eq(mn, so) then uo else so;
        if leaves_range(mx, ar, range) return true, mx, true;
        return false, mn, true;
    }
    lower := ap_sub_u64(ap_sext(range.lo, q.a.bits), 1);
    upper := ap_sext(range.hi, q.a.bits);
    sl_has, sl_x, sl_ok := solve_for_boundary(lower, q, ar, range);
    su_has, su_x, su_ok := solve_for_boundary(upper, q, ar, range);
    if !sl_ok || !su_ok return false, ap_zero(1);
    hm, m := min_optional(sl_has, sl_x, su_has, su_x);
    o, r := trunc_if_possible(hm, m, q.bits);
    return o, r;
}

// SCEVAddRecExpr::getNumIterationsInRange
sc_get_num_iterations_in_range :: (ar: Scev_Id, range: Const_Range) -> Scev_Id {
    if cr_is_full_set(range) return SCEV_CNC;
    start := sc_start(ar);
    if sc_is_const(start) && !sc_is_zero(start) {
        operands := sc_operands(ar);
        operands[0] = sc_get_zero(sc_type(start));
        shifted := sc_get_add_rec_ops(*operands, sc_loop(ar), sc_flags(ar, SF_NW));
        if sc_is_addrec(shifted) return sc_get_num_iterations_in_range(shifted, cr_subtract(range, sc_ap(start)));
        return SCEV_CNC;
    }
    for i: 0..cast(s64) sc_nops(ar) - 1 if !sc_is_const(sc_op(ar, cast(u32) i)) return SCEV_CNC;
    bits := sc_bits(ar);
    if !cr_contains(range, ap_zero(bits)) return sc_get_zero(sc_type(ar));
    if sc_is_affine(ar) {
        a := sc_ap(sc_op(ar, 1));
        end := ifx ap_sge(a, ap_one(a.bits)) then ap_sub_u64(range.hi, 1) else range.lo;
        exit_val := ap_udiv(ap_add(end, a), a);
        val := evaluate_constant_chrec_at_constant(ar, exit_val);
        if cr_contains(range, val) return SCEV_CNC;
        return sc_get_constant(exit_val);
    }
    if sc_is_quadratic(ar) {
        ok, s := solve_quadratic_add_rec_range(ar, range);
        if ok return sc_get_constant(s);
    }
    return SCEV_CNC;
}

// ---------------------------------------------------------------- howFarToZero & co.

// howFarToZero
sc_how_far_to_zero :: (v: Scev_Id, l: Loop_Id, controls_only_exit: bool, allow_predicates := false) -> Exit_Limit {
    predicates: [..] u32; predicates.allocator = temp;
    if sc_is_const(v) {
        if sc_is_zero(v) return el_of(v);
        return el_of(SCEV_CNC);
    }
    add_rec := strip_injective_functions(v);
    if !sc_is_addrec(add_rec) add_rec = SCEV_CNC;
    if add_rec == SCEV_CNC && allow_predicates add_rec = sc_convert_scev_to_add_rec_with_predicates(v, l, *predicates);
    if add_rec == SCEV_CNC || sc_loop(add_rec) != l return el_of(SCEV_CNC);

    if sc_is_quadratic(add_rec) && is_int_type(sc_type(add_rec)) {
        ok, s := solve_quadratic_add_rec_exact(add_rec);
        if ok {
            r := sc_get_constant(s);
            return el_make(r, r, r, false, predicates);
        }
        return el_of(SCEV_CNC);
    }
    if !sc_is_affine(add_rec) return el_of(SCEV_CNC);

    parent := li_parent(se.li, l);
    start := sc_get_scev_at_scope(sc_start(add_rec), parent);
    step := sc_get_scev_at_scope(sc_op(add_rec, 1), parent);
    if !sc_is_loop_invariant(step, l) return el_of(SCEV_CNC);

    guards := sc_loop_guards_collect(l);
    step_wlg := sc_apply_loop_guards_with(step, *guards);
    count_down := sc_is_known_negative(step_wlg);
    if !count_down && !sc_is_known_non_negative(step_wlg) return el_of(SCEV_CNC);
    distance := ifx count_down then start else sc_get_negative(start);

    if sc_is_one(step) || sc_is_all_ones(step) {
        max_be := sc_unsigned_range_max(sc_apply_loop_guards_with(distance, *guards));
        max_be = ap_umin(max_be, sc_unsigned_range_max(distance));
        zero := sc_get_zero(sc_type(distance));
        one := sc_get_one(sc_type(distance));
        distance_plus_one := sc_get_add2(distance, one);
        if sc_is_loop_entry_guarded_by_cond(l, ICMP_NE, distance_plus_one, zero) {
            cr := sc_unsigned_range(distance_plus_one);
            max_be = ap_umin(max_be, ap_sub_u64(cr_umax(cr), 1));
        }
        return el_make(distance, sc_get_constant(max_be), distance, false, predicates);
    }

    if controls_only_exit && sc_has_nw(add_rec) && sc_loop_has_no_abnormal_exits(sc_loop(add_rec)) {
        if !(sc_loop_is_finite_by_assumption(l) && sc_is_known_non_zero(start)) && !sc_is_known_non_zero(step_wlg)
            return el_of(SCEV_CNC);
        exact := sc_get_udiv(distance, ifx count_down then sc_get_negative(step) else step);
        constant_max := SCEV_CNC;
        if exact != SCEV_CNC {
            max_int := sc_unsigned_range_max(sc_apply_loop_guards_with(exact, *guards));
            constant_max = sc_get_constant(ap_umin(max_int, sc_unsigned_range_max(exact)));
        }
        symbolic_max := ifx exact == SCEV_CNC then constant_max else exact;
        return el_make(exact, constant_max, symbolic_max, false, predicates);
    }

    if !sc_is_const(step) || sc_is_zero(step) return el_of(SCEV_CNC);
    e := solve_lin_equation_with_overflow(sc_ap(step), sc_get_negative(start), ifx allow_predicates then *predicates else null, l);
    m := e;
    if e != SCEV_CNC {
        max_with_guards := sc_unsigned_range_max(sc_apply_loop_guards_with(e, *guards));
        m = sc_get_constant(ap_umin(max_with_guards, sc_unsigned_range_max(e)));
    }
    s := ifx e == SCEV_CNC then m else e;
    return el_make(e, m, s, false, predicates);
}

// howFarToNonZero
sc_how_far_to_non_zero :: (v: Scev_Id, l: Loop_Id) -> Exit_Limit {
    if sc_is_const(v) {
        if !sc_is_zero(v) return el_of(sc_get_zero(sc_type(v)));
        return el_of(SCEV_CNC);
    }
    return el_of(SCEV_CNC);
}

// canIVOverflowOnLT
sc_can_iv_overflow_on_lt :: (rhs: Scev_Id, stride: Scev_Id, is_signed: bool) -> bool {
    bits := sc_bits(rhs);
    one := sc_get_one(sc_type(stride));
    if is_signed {
        max_rhs := sc_signed_range_max(rhs);
        max_value := ap_signed_max(bits);
        max_stride_minus_one := sc_signed_range_max(sc_get_minus(stride, one));
        return ap_slt(ap_sub(max_value, max_stride_minus_one), max_rhs);
    }
    max_rhs := sc_unsigned_range_max(rhs);
    max_value := ap_all_ones(bits);
    max_stride_minus_one := sc_unsigned_range_max(sc_get_minus(stride, one));
    return ap_ult(ap_sub(max_value, max_stride_minus_one), max_rhs);
}
// canIVOverflowOnGT
sc_can_iv_overflow_on_gt :: (rhs: Scev_Id, stride: Scev_Id, is_signed: bool) -> bool {
    bits := sc_bits(rhs);
    one := sc_get_one(sc_type(stride));
    if is_signed {
        min_rhs := sc_signed_range_min(rhs);
        min_value := ap_signed_min(bits);
        max_stride_minus_one := sc_signed_range_max(sc_get_minus(stride, one));
        return ap_sgt(ap_add(min_value, max_stride_minus_one), min_rhs);
    }
    min_rhs := sc_unsigned_range_min(rhs);
    min_value := ap_zero(bits);
    max_stride_minus_one := sc_unsigned_range_max(sc_get_minus(stride, one));
    return ap_ugt(ap_add(min_value, max_stride_minus_one), min_rhs);
}
// getUDivCeilSCEV
sc_get_udiv_ceil :: (n: Scev_Id, d: Scev_Id) -> Scev_Id {
    min_n_one := sc_get_umin2(n, sc_get_one(sc_type(n)));
    n_minus_one := sc_get_minus(n, min_n_one);
    return sc_get_add2(min_n_one, sc_get_udiv(n_minus_one, d));
}
// computeMaxBECountForLT
sc_compute_max_be_count_for_lt :: (start: Scev_Id, stride: Scev_Id, end: Scev_Id, bits: u32, is_signed: bool) -> Scev_Id {
    if is_signed && bits == 1 return sc_get_zero(sc_type(stride));
    if is_signed && sc_is_known_negative(stride) return SCEV_CNC;
    min_start := ifx is_signed then sc_signed_range_min(start) else sc_unsigned_range_min(start);
    min_stride := ifx is_signed then sc_signed_range_min(stride) else sc_unsigned_range_min(stride);
    one := ap_one(bits);
    stride_for_max := ifx is_signed then ap_smax(one, min_stride) else ap_umax(one, min_stride);
    max_value := ifx is_signed then ap_signed_max(bits) else ap_all_ones(bits);
    limit := ap_sub(max_value, ap_sub_u64(stride_for_max, 1));
    max_end := ifx is_signed then ap_smin(sc_signed_range_max(end), limit) else ap_umin(sc_unsigned_range_max(end), limit);
    max_end = ifx is_signed then ap_smax(max_end, min_start) else ap_umax(max_end, min_start);
    return sc_get_udiv_ceil(sc_get_constant(ap_sub(max_end, min_start)), sc_get_constant(stride_for_max));
}

// howManyLessThans
sc_how_many_less_thans :: (lhs: Scev_Id, rhs_in: Scev_Id, l: Loop_Id, is_signed: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    rhs := rhs_in;
    predicates: [..] u32; predicates.allocator = temp;
    iv := ifx sc_is_addrec(lhs) then lhs else SCEV_CNC;
    predicated_iv := false;
    if iv == SCEV_CNC {
        if sc_is_zext(lhs) {
            ar := sc_op(lhs, 0);
            if sc_is_addrec(ar) && sc_loop(ar) == l && sc_is_affine(ar) {
                can_prove_nuw :: (ar: Scev_Id, rhs: Scev_Id, l: Loop_Id, controls_only_exit: bool) -> bool {
                    if !controls_only_exit return false;
                    if !sc_is_loop_invariant(rhs, l) return false;
                    if !sc_is_known_non_zero(sc_step_recurrence(ar)) return false;
                    inner_bits := sc_bits(ar);
                    outer_bits := sc_bits(rhs);
                    stride_max := sc_unsigned_range_max(sc_step_recurrence(ar));
                    limit := ap_sub(ap_all_ones(inner_bits), ap_sub_u64(stride_max, 1));
                    limit = ap_zext(limit, outer_bits);
                    return ap_ule(sc_unsigned_range_max(sc_apply_loop_guards(rhs, l)), limit);
                }
                flags := sc_flags(ar);
                if !has_flags(flags, SF_NUW) && can_prove_nuw(ar, rhs, l, controls_only_exit) flags = set_flags(flags, SF_NUW);
                sc_set_no_wrap_flags(ar, flags);
                if sc_has_nuw(ar) {
                    step := sc_step_recurrence(ar);
                    ty := sc_type(lhs);
                    s := sc_get_add_rec(get_extend_add_rec_start(ar, ty, 0, false), sc_get_zero_extend(step, ty, 0), l, sc_flags(ar));
                    if sc_is_addrec(s) iv = s;
                }
            }
        }
    }
    if iv == SCEV_CNC && allow_predicates {
        iv = sc_convert_scev_to_add_rec_with_predicates(lhs, l, *predicates);
        predicated_iv = true;
    }
    if iv == SCEV_CNC || sc_loop(iv) != l || !sc_is_affine(iv) return el_of(SCEV_CNC);

    wrap_type := ifx is_signed then SF_NSW else SF_NUW;
    no_wrap := controls_only_exit && sc_flags(iv, wrap_type) != 0;
    cond := ifx is_signed then cast(u8) ICMP_SLT else ICMP_ULT;
    stride := sc_step_recurrence(iv);
    positive_stride := sc_is_known_positive(stride);

    if !positive_stride {
        if predicated_iv || !no_wrap || !sc_loop_is_finite_by_assumption(l) || !sc_loop_has_no_abnormal_exits(l) return el_of(SCEV_CNC);
        if !sc_is_known_non_zero(stride) {
            if !sc_is_loop_invariant(rhs, l) return el_of(SCEV_CNC);
            start_if_zero := sc_get_minus(sc_start(iv), stride);
            would_zero_stride_be_ub := sc_is_loop_entry_guarded_by_cond(l, cond, start_if_zero, rhs);
            if !would_zero_stride_be_ub stride = sc_get_umax2(stride, sc_get_one(sc_type(stride)));
        }
    } else if !no_wrap {
        if sc_can_iv_overflow_on_lt(rhs, stride, is_signed) return el_of(SCEV_CNC);
    }

    start := sc_start(iv);
    orig_start := start;
    orig_rhs := rhs;
    if sc_is_ptr(start) {
        start = sc_get_lossless_ptr_to_int(start);
        if start == SCEV_CNC return el_of(start);
    }
    if sc_is_ptr(rhs) {
        rhs = sc_get_lossless_ptr_to_int(rhs);
        if rhs == SCEV_CNC return el_of(rhs);
    }

    end := SCEV_NULL;
    be_count := SCEV_NULL;
    be_count_if_taken := SCEV_NULL;
    if !sc_is_loop_invariant(rhs, l) {
        rhs_ar := rhs;
        if positive_stride && sc_is_addrec(rhs_ar) && sc_loop(rhs_ar) == l && sc_flags(rhs_ar) != 0 {
            rhs_start := sc_start(rhs_ar);
            rhs_stride := sc_step_recurrence(rhs_ar);
            if sc_is_known_negative(rhs_stride) && sc_will_not_overflow(.SUB, true, stride, rhs_stride) {
                denominator := sc_get_minus(stride, rhs_stride);
                if sc_is_known_positive(denominator) {
                    end = ifx is_signed then sc_get_smax2(rhs_start, start) else sc_get_umax2(rhs_start, start);
                    delta := sc_get_minus(end, start);
                    be_count = sc_get_udiv_ceil(delta, denominator);
                    be_count_if_taken = sc_get_udiv_ceil(sc_get_minus(rhs_start, start), denominator);
                }
            }
        }
        if be_count == SCEV_NULL {
            max_be := sc_compute_max_be_count_for_lt(start, stride, rhs, sc_bits(lhs), is_signed);
            return el_make(SCEV_CNC, max_be, max_be, false, predicates);
        }
    } else {
        orig_start_minus_stride := sc_get_minus(orig_start, stride);
        if sc_is_loop_entry_guarded_by_cond(l, cond, orig_start_minus_stride, orig_start) &&
           sc_is_loop_entry_guarded_by_cond(l, cond, orig_start_minus_stride, orig_rhs) {
            minus_one := sc_get_minus_one(sc_type(stride));
            numerator := sc_get_minus(sc_get_add2(rhs, minus_one), sc_get_minus(start, stride));
            be_count = sc_get_udiv(numerator, stride);
        }
        if be_count == SCEV_NULL {
            can_prove_rhs_ge_start :: (orig_rhs: Scev_Id, orig_start: Scev_Id, l: Loop_Id, is_signed: bool) -> bool {
                cond_ge := ifx is_signed then cast(u8) ICMP_SGE else ICMP_UGE;
                guarded_rhs := sc_apply_loop_guards(orig_rhs, l);
                guarded_start := sc_apply_loop_guards(orig_start, l);
                if sc_is_loop_entry_guarded_by_cond(l, cond_ge, orig_rhs, orig_start) || sc_is_known_predicate(cond_ge, guarded_rhs, guarded_start)
                    return true;
                cond_gt := ifx is_signed then cast(u8) ICMP_SGT else ICMP_UGT;
                start_minus_one := sc_get_add2(orig_start, sc_get_minus_one(sc_type(orig_start)));
                return sc_is_loop_entry_guarded_by_cond(l, cond_gt, orig_rhs, start_minus_one);
            }
            if can_prove_rhs_ge_start(orig_rhs, orig_start, l, is_signed) {
                end = rhs;
            } else {
                end = ifx is_signed then sc_get_smax2(rhs, start) else sc_get_umax2(rhs, start);
                be_count_if_taken = sc_get_udiv_ceil(sc_get_minus(rhs, start), stride);
            }
            one := sc_get_one(sc_type(stride));
            may_add_overflow := true;
            if sc_is_known_to_be_a_power_of_two(stride) may_add_overflow = false;
            else if start == stride || start == sc_get_minus(stride, one) may_add_overflow = false;
            delta := sc_get_minus(end, start);
            if !may_add_overflow be_count = sc_get_udiv(sc_get_add2(delta, sc_get_minus(stride, one)), stride);
            else be_count = sc_get_udiv_ceil(delta, stride);
        }
    }

    constant_max: Scev_Id;
    max_or_zero := false;
    if sc_is_const(be_count) constant_max = be_count;
    else if be_count_if_taken != SCEV_NULL && sc_is_const(be_count_if_taken) {
        constant_max = be_count_if_taken;
        max_or_zero = true;
    } else {
        constant_max = sc_compute_max_be_count_for_lt(start, stride, rhs, sc_bits(lhs), is_signed);
    }
    if constant_max == SCEV_CNC && be_count != SCEV_CNC constant_max = sc_get_constant(sc_unsigned_range_max(be_count));
    symbolic_max := ifx be_count == SCEV_CNC then constant_max else be_count;
    return el_make(be_count, constant_max, symbolic_max, max_or_zero, predicates);
}

// howManyGreaterThans
sc_how_many_greater_thans :: (lhs: Scev_Id, rhs: Scev_Id, l: Loop_Id, is_signed: bool, controls_only_exit: bool, allow_predicates: bool) -> Exit_Limit {
    predicates: [..] u32; predicates.allocator = temp;
    if !sc_is_loop_invariant(rhs, l) return el_of(SCEV_CNC);
    iv := ifx sc_is_addrec(lhs) then lhs else SCEV_CNC;
    if iv == SCEV_CNC && allow_predicates iv = sc_convert_scev_to_add_rec_with_predicates(lhs, l, *predicates);
    if iv == SCEV_CNC || sc_loop(iv) != l || !sc_is_affine(iv) return el_of(SCEV_CNC);
    wrap_type := ifx is_signed then SF_NSW else SF_NUW;
    no_wrap := controls_only_exit && sc_flags(iv, wrap_type) != 0;
    cond := ifx is_signed then cast(u8) ICMP_SGT else ICMP_UGT;
    stride := sc_get_negative(sc_step_recurrence(iv));
    if !sc_is_known_positive(stride) return el_of(SCEV_CNC);
    if !sc_is_one(stride) && !no_wrap {
        if sc_can_iv_overflow_on_gt(rhs, stride, is_signed) return el_of(SCEV_CNC);
    }
    start := sc_start(iv);
    end := rhs;
    if !sc_is_loop_entry_guarded_by_cond(l, cond, sc_get_add2(start, stride), rhs) {
        if sc_is_loop_entry_guarded_by_cond(l, ifx is_signed then cast(u8) ICMP_SGE else ICMP_UGE, start, rhs) end = rhs;
        else end = ifx is_signed then sc_get_smin2(rhs, start) else sc_get_umin2(rhs, start);
    }
    if sc_is_ptr(start) {
        start = sc_get_lossless_ptr_to_int(start);
        if start == SCEV_CNC return el_of(start);
    }
    if sc_is_ptr(end) {
        end = sc_get_lossless_ptr_to_int(end);
        if end == SCEV_CNC return el_of(end);
    }
    one := sc_get_one(sc_type(stride));
    be_count := sc_get_udiv(sc_get_add2(sc_get_minus(start, end), sc_get_minus(stride, one)), stride);
    max_start := ifx is_signed then sc_signed_range_max(start) else sc_unsigned_range_max(start);
    min_stride := ifx is_signed then sc_signed_range_min(stride) else sc_unsigned_range_min(stride);
    bits := sc_bits(lhs);
    limit := ifx is_signed then ap_add(ap_signed_min(bits), ap_sub_u64(min_stride, 1)) else ap_add(ap_zero(bits), ap_sub_u64(min_stride, 1));
    min_end := ifx is_signed then ap_smax(sc_signed_range_min(rhs), limit) else ap_umax(sc_unsigned_range_min(rhs), limit);
    constant_max := ifx sc_is_const(be_count) then be_count else sc_get_udiv_ceil(sc_get_constant(ap_sub(max_start, min_end)), sc_get_constant(min_stride));
    if constant_max == SCEV_CNC constant_max = be_count;
    symbolic_max := ifx be_count == SCEV_CNC then constant_max else be_count;
    return el_make(be_count, constant_max, symbolic_max, false, predicates);
}

// willNotOverflow(BinOp, Signed, LHS, RHS, CtxI)
sc_will_not_overflow :: (bin_op: Opcode, signed: bool, lhs: Scev_Id, rhs: Scev_Id, cxt: Value_Id = NONE) -> bool {
    operation :: (bin_op: Opcode, a: Scev_Id, b: Scev_Id) -> Scev_Id {
        if bin_op == .ADD return sc_get_add2(a, b, SF_ANY, 0);
        if bin_op == .SUB return sc_get_minus(a, b, SF_ANY, 0);
        return sc_get_mul2(a, b, SF_ANY, 0);
    }
    narrow := sc_type(lhs);
    wide_ty := type_int(type_int_width(narrow) * 2);
    a := sc_get_extend(operation(bin_op, lhs, rhs), wide_ty, 0, signed);
    lhsb := sc_get_extend(lhs, wide_ty, 0, signed);
    rhsb := sc_get_extend(rhs, wide_ty, 0, signed);
    b := operation(bin_op, lhsb, rhsb);
    if a == b return true;
    if cxt == NONE return false;
    if bin_op == .MUL return false;
    if !sc_is_const(rhs) return false;
    c := sc_ap(rhs);
    num_bits := c.bits;
    is_sub := bin_op == .SUB;
    is_negative_const := signed && ap_is_negative(c);
    overflow_down := is_sub != is_negative_const;
    magnitude := c;
    if is_negative_const {
        if ap_is_min_signed(c) return false;
        magnitude = ap_neg(c);
    }
    pred := ifx signed then cast(u8) ICMP_SLE else ICMP_ULE;
    if overflow_down {
        mn := ifx signed then ap_signed_min(num_bits) else ap_zero(num_bits);
        limit := ap_add(mn, magnitude);
        return sc_is_known_predicate_at(pred, sc_get_constant(limit), lhs, cxt);
    }
    mx := ifx signed then ap_signed_max(num_bits) else ap_all_ones(num_bits);
    limit := ap_sub(mx, magnitude);
    return sc_is_known_predicate_at(pred, lhs, sc_get_constant(limit), cxt);
}
