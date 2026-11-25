// LoopCacheAnalysis: port of llvm/lib/Analysis/LoopCacheAnalysis.cpp (LLVM 23.1.5): IndexedReference, CacheCost and
// the print<loop-cache-cost> printer (LoopCachePrinterPass). Used by loop-interchange's `cache` profitability rule.
//
// Data layout: one CacheCost at a time; IndexedReference rows (Lc_Ref) hold their subscripts and sizes in temp
// arrays. CacheCostTy is InstructionCost (Lc_Cost): a valid flag and the raw value in units of 1/4
// (CostGranularity 4) with LLVM's saturating int64 arithmetic; tti.jai's `Cost` is a different, unscaled model.
// TTI::getCacheLineSize() is 0 for x86-64 and NoTTI (no cache model in the X86 subtarget) unless -cache-line-size.

lc_cl: struct {
    default_trip_count: s64 = 100;      // -default-trip-count
    temporal_reuse_threshold: s64 = 2;  // -temporal-reuse-threshold
};

lc_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_value :: (name: string, value: string, has_value: bool) -> s64 {
        v, ok := string_to_int(value);
        if !has_value || !ok || v < 0 fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == {
        case "default-trip-count"; lc_cl.default_trip_count = int_value(name, value, has_value); return true;
        case "temporal-reuse-threshold"; lc_cl.temporal_reuse_threshold = int_value(name, value, has_value); return true;
    }
    return false;
}

// TargetTransformInfo::getCacheLineSize
lc_cache_line_size :: () -> s64 { return li_cl.cache_line_size; }

// ---------------------------------------------------------------- InstructionCost (CostGranularity 4, saturating)

Lc_Cost :: struct { valid := true; v: s64; }
LC_MAX :: 0x7fff_ffff_ffff_ffff;
LC_MIN :: -0x7fff_ffff_ffff_ffff - 1;

lc_mul_ov :: (a: s64, b: s64) -> (s64, bool) {
    r := cast,no_check(s64) (cast,no_check(u64) a * cast,no_check(u64) b);
    if a == 0 || b == 0 return 0, false;
    if (a == -1 && b == LC_MIN) || (b == -1 && a == LC_MIN) return r, true;
    return r, r / b != a;
}
lc_cost :: (v: s64) -> Lc_Cost {
    r, o := lc_mul_ov(v, 4);
    if o return .{true, ifx v > 0 then LC_MAX else LC_MIN};
    return .{true, r};
}
LC_INVALID :: Lc_Cost.{false, 0};
lc_add :: (a: Lc_Cost, b: Lc_Cost) -> Lc_Cost {
    v: s64;
    if b.v > 0 && a.v > LC_MAX - b.v v = LC_MAX;
    else if b.v < 0 && a.v < LC_MIN - b.v v = LC_MIN;
    else v = a.v + b.v;
    return .{a.valid && b.valid, v};
}
lc_mul :: (a: Lc_Cost, b: Lc_Cost) -> Lc_Cost {
    r, o := lc_mul_ov(a.v, b.v);
    v: s64;
    if o v = ifx (a.v > 0 && b.v > 0) || (a.v < 0 && b.v < 0) then LC_MAX else LC_MIN;
    else v = r / 4;
    return .{a.valid && b.valid, v};
}
// InstructionCost::operator<: a valid cost is below every invalid one
lc_lt :: (a: Lc_Cost, b: Lc_Cost) -> bool {
    if a.valid != b.valid return a.valid;
    return a.v < b.v;
}
lc_eq :: (a: Lc_Cost, b: Lc_Cost) -> bool { return a.valid == b.valid && a.v == b.v; }
// InstructionCost::print
lc_cost_to_string :: (c: Lc_Cost) -> string {
    if !c.valid return "Invalid";
    neg := c.v < 0;
    abs := ifx neg then 0 - cast,no_check(u64) c.v else cast(u64) c.v;
    whole := abs / 4;
    h := ((abs % 4) * 100) / 4;
    while h % 10 == 0 && h != 0 h /= 10;
    if h != 0 return tprint("%1%2.%3", ifx neg then "-" else "", whole, h);
    return tprint("%1%2", ifx neg then "-" else "", whole);
}

// ---------------------------------------------------------------- IndexedReference

Lc_Ref :: struct {
    inst: Value_Id;
    valid: bool;
    base: Scev_Id = SCEV_NULL;
    subs: [..] Scev_Id;
    sizes: [..] Scev_Id;
}

lc_ptr_operand :: (i: Value_Id) -> Value_Id { return ifx inst_op(i) == .STORE then op(i, 1) else op(i, 0); }

// isOneDimensionalArray
lc_is_one_dimensional_array :: (afn: Scev_Id, es: Scev_Id, l: Loop_Id) -> bool {
    if !sc_is_addrec(afn) || !sc_is_affine(afn) return false;
    start := sc_start(afn);
    step := sc_step_recurrence(afn);
    if sc_is_addrec(start) || sc_is_addrec(step) return false;
    if !sc_is_loop_invariant(start, l) || !sc_is_loop_invariant(step, l) return false;
    sr := sc_step_recurrence(afn);
    if sc_is_known_negative(sr) sr = sc_get_negative(sr);
    return sr == es;
}

// computeTripCount
lc_compute_trip_count :: (l: Loop_Id, es: Scev_Id) -> Scev_Id {
    btc := sc_get_backedge_taken_count(l);
    if !sc_is_cnc(btc) && sc_is_const(btc) return sc_get_trip_count_from_exit_count(btc);
    return sc_get_constant_t(sc_type(es), cast(u64) lc_cl.default_trip_count);
}

// isSimpleAddRecurrence
lc_is_simple_add_recurrence :: (s: Scev_Id, l: Loop_Id) -> bool {
    if !sc_is_addrec(s) || !sc_is_affine(s) return false;
    return sc_is_loop_invariant(sc_start(s), l) && sc_is_loop_invariant(sc_step_recurrence(s), l);
}

// isCoeffForLoopZeroOrInvariant
lc_coeff_zero_or_invariant :: (s: Scev_Id, l: Loop_Id) -> bool {
    if sc_is_addrec(s) return sc_loop(s) != l;
    return sc_is_loop_invariant(s, l);
}

// IndexedReference(I, LI, SE) with delinearize(LI)
lc_ref_new :: (li: *Loop_Info, i: Value_Id) -> *Lc_Ref {
    r := New(Lc_Ref,, allocator = temp);
    r.inst = i;
    r.subs.allocator = temp; r.sizes.allocator = temp;
    es := sc_get_element_size(i);
    l := li_loop_for(li, inst_block(i));
    if l == NONE return r;
    afn := sc_get_scev_at_scope(sc_get_scev(lc_ptr_operand(i)), l);
    base := sc_get_pointer_base(afn);
    if sc_kind(base) != .UNKNOWN return r;
    r.base = base;
    afn = sc_get_minus(afn, base);
    fixed := delin_delinearize_fixed_size_array(afn, *r.subs, *r.sizes, es);
    if !fixed {
        r.sizes.count = 0;
        delin_delinearize(afn, *r.subs, *r.sizes, sc_get_element_size(i));
    }
    if r.subs.count == 0 || r.sizes.count == 0 || r.subs.count != r.sizes.count {
        if !lc_is_one_dimensional_array(afn, es, l) { r.subs.count = 0; r.sizes.count = 0; return r; }
        // reverse access: rebuild the access function with the absolute step
        if sc_is_addrec(afn) {
            sr := sc_step_recurrence(afn);
            if sc_is_known_negative(sr) afn = sc_get_add_rec(sc_start(afn), sc_get_negative(sr), sc_loop(afn), SF_ANY);
        }
        array_add(*r.subs, sc_get_udiv_exact(afn, es));
        array_add(*r.sizes, es);
    }
    r.valid = true;
    for r.subs if !lc_is_simple_add_recurrence(it, l) { r.valid = false; break; }
    return r;
}

// isAliased: AA.isMustAlias(MemoryLocation::get(I), MemoryLocation::get(Other))
lc_is_aliased :: (aar: *Aa_Results, a: *Lc_Ref, b: *Lc_Ref) -> bool {
    return aa_alias_once(aar, mloc_get(a.inst), mloc_get(b.inst)).kind == AR_MUST;
}

// hasSpacialReuse: -1 = std::nullopt
lc_has_spacial_reuse :: (aar: *Aa_Results, a: *Lc_Ref, b: *Lc_Ref, cls: s64) -> s64 {
    if a.base != b.base && !lc_is_aliased(aar, a, b) return 0;
    n := a.subs.count;
    if n != b.subs.count return 0;
    for k: 0..n - 2 if a.subs[k] != b.subs[k] return 0;
    d := sc_get_minus(a.subs[n - 1], b.subs[n - 1]);
    if !sc_is_const(d) return -1;
    return ifx ap_sext_value(sc_ap(d)) < cls then 1 else 0;
}

// hasTemporalReuse: -1 = std::nullopt
lc_has_temporal_reuse :: (di: *Da_Info, a: *Lc_Ref, b: *Lc_Ref, max_dist: s64, l: Loop_Id) -> s64 {
    if a.base != b.base && !lc_is_aliased(*di.aar, a, b) return 0;
    d := da_depends(di, a.inst, b.inst);
    if !d return 0;
    if dep_is_loop_independent(d) return 1;
    depth := cast(s64) li_depth(di.li, l);
    levels := dep_levels(d);
    for level: 1..levels {
        dist := dep_distance(d, level);
        if dist == SCEV_NULL || !sc_is_const(dist) return -1;
        cv := sc_ap(dist);
        if level != depth && !ap_is_zero(cv) return 0;
        else if level == depth && ap_sext_value(cv) > max_dist return 0;
    }
    return 1;
}

// computeRefCost(L, CLS)
lc_compute_ref_cost :: (r: *Lc_Ref, l: Loop_Id, cls: s64) -> Lc_Cost {
    // isLoopInvariant(L)
    if sc_is_loop_invariant(sc_get_scev(lc_ptr_operand(r.inst)), l) return lc_cost(1);
    inv := true;
    for r.subs if !lc_coeff_zero_or_invariant(it, l) { inv = false; break; }
    if inv return lc_cost(1);
    es := r.sizes[r.sizes.count - 1];
    tc := lc_compute_trip_count(l, es);
    n := r.subs.count;
    last := r.subs[n - 1];
    // isConsecutive(L, Stride, CLS)
    consecutive := true;
    for s: r.subs { if s == last continue; if !lc_coeff_zero_or_invariant(s, l) { consecutive = false; break; } }
    stride := SCEV_NULL;
    if consecutive {
        coeff := sc_step_recurrence(last);
        wt := sc_get_wider_type(sc_type(coeff), sc_type(es));
        stride = sc_get_mul2(sc_get_noop_or_sign_extend(coeff, wt), sc_get_noop_or_sign_extend(es, wt));
        cl := sc_get_constant_t(sc_type(stride), cast(u64) cls);
        if sc_is_known_negative(stride) stride = sc_get_negative(stride);
        consecutive = sc_is_known_predicate(ICMP_ULT, stride, cl);
    }
    cost: Scev_Id;
    if consecutive {
        wt := sc_get_wider_type(sc_type(stride), sc_type(tc));
        cl := sc_get_constant_t(wt, cast(u64) cls);
        stride = sc_get_noop_or_any_extend(stride, wt);
        tc = sc_get_noop_or_zero_extend(tc, wt);
        cost = sc_get_udiv_ceil(sc_get_mul2(stride, tc), cl);
    } else {
        cost = tc;
        idx := -1;
        for s, k: r.subs if sc_is_addrec(s) && sc_loop(s) == l { idx = k; break; }
        if idx < 0 fatal("loop-cache-cost: no subscript recurs in the loop (LLVM asserts here)");
        for i: idx + 1..n - 2 {
            ar := r.subs[i];
            tc2 := lc_compute_trip_count(sc_loop(ar), es);
            wt := sc_get_wider_type(sc_type(cost), sc_type(tc2));
            wt = type_int(2 * sc_type_bits(wt));   // getExtendedType
            cost = sc_get_mul2(sc_get_noop_or_zero_extend(cost, wt), sc_get_noop_or_zero_extend(tc2, wt));
        }
    }
    if sc_is_const(cost) {
        a := sc_ap(cost);
        if ap_active_bits(a) > 63 return lc_cost(LC_MAX);   // getLimitedValue(INT64_MAX)
        return lc_cost(cast(s64) ap_zext_value(a));
    }
    return LC_INVALID;
}

// ---------------------------------------------------------------- CacheCost

Lc_Result :: struct {
    ok: bool;                 // the unique_ptr<CacheCost> is non-null
    loops: [..] Loop_Id;      // getLoopCosts() order (sorted, largest cost first)
    costs: [..] Lc_Cost;
}

// CacheCost::getLoopCost: -1 when the loop has no cost
lc_loop_cost :: (r: *Lc_Result, l: Loop_Id) -> Lc_Cost {
    for r.loops if it == l return r.costs[it_index];
    return lc_cost(-1);
}
lc_loop_index :: (r: *Lc_Result, l: Loop_Id) -> s64 {
    for r.loops if it == l return it_index;
    return -1;
}

// getCacheCostImpl(Root, ...) and the CacheCost constructor (calculateCacheFootprint)
lc_compute :: (li: *Loop_Info, di: *Da_Info, root: Loop_Id) -> Lc_Result {
    res: Lc_Result;
    res.loops.allocator = temp; res.costs.allocator = temp;
    if !li_is_outermost(li, root) return res;
    loops: [..] Loop_Id; loops.allocator = temp;
    array_add(*loops, root);
    k := 0;
    while k < loops.count { for li_subloops(li, loops[k]) array_add(*loops, it); k += 1; }
    // getInnerMostLoop: breadth-first order is always sorted by depth, so this is the last loop
    inner := loops[loops.count - 1];
    res.ok = true;
    tcs: [..] s64; tcs.allocator = temp;
    for loops {
        t := cast(s64) sc_get_small_constant_trip_count(it);
        array_add(*tcs, ifx t == 0 then lc_cl.default_trip_count else t);
    }
    // populateReferenceGroups (only the representative of each group matters for the costs)
    cls := lc_cache_line_size();
    groups: [..] *Lc_Ref; groups.allocator = temp;
    for b: li_blocks(li, inner) for i: block_insts(b) {
        o := inst_op(i);
        if o != .STORE && o != .LOAD continue;
        r := lc_ref_new(li, i);
        if !r.valid continue;
        added := false;
        for g: groups {
            t := lc_has_temporal_reuse(di, r, g, lc_cl.temporal_reuse_threshold, inner);
            s := lc_has_spacial_reuse(*di.aar, r, g, cls);
            if t == 1 || s == 1 { added = true; break; }
        }
        if !added array_add(*groups, r);
    }
    if groups.count == 0 return res;
    for l: loops {
        prod := lc_cost(1);
        for j: 0..loops.count - 1 if loops[j] != l prod = lc_mul(prod, lc_cost(tcs[j]));
        c := lc_cost(0);
        for g: groups c = lc_add(c, lc_mul(lc_compute_ref_cost(g, l, cls), prod));
        array_add(*res.loops, l);
        array_add(*res.costs, c);
    }
    // sortLoopCosts: stable_sort, larger cost first
    for i: 1..res.loops.count - 1 {
        tl := res.loops[i]; tc := res.costs[i];
        j := i;
        while j > 0 && lc_lt(res.costs[j - 1], tc) { res.loops[j] = res.loops[j - 1]; res.costs[j] = res.costs[j - 1]; j -= 1; }
        res.loops[j] = tl; res.costs[j] = tc;
    }
    return res;
}

// LoopCachePrinterPass
loop_cache_printer_run :: (f: Value_Id) -> Preserved {
    // the header goes out before the analyses are requested: creating the subtarget for TTI can warn on stderr
    print_stderr("Printing analysis 'Loop Cache Analysis' for function '%':\n", vname(f));
    sb: String_Builder; sb.allocator = temp;
    li := get_loop_info(f);
    se = get_scev(f);
    tti_get(f);   // FAM.getResult<TargetIRAnalysis>(F)
    di := da_new(f, li);
    for li.top_level {
        r := lc_compute(li, di, it);
        if !r.ok continue;
        for l, k: r.loops print_to_builder(*sb, "Loop '%' has cost = %\n", li_loop_name(li, l), lc_cost_to_string(r.costs[k]));
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
