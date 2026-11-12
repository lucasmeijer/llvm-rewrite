// DependenceAnalysis: a port of llvm/lib/Analysis/DependenceAnalysis.cpp (LLVM 23.1.5): DependenceInfo::depends
// with the ZIV, strong/weak-crossing/exact/weak-zero SIV, exact RDIV, GCD MIV and Banerjee MIV tests, SameSD loop
// levels, delinearization (delinearization.jai), Da_Dependence::dump and print<da> (dumpExampleDependence, including
// <normalized-results>). Its cl::opts: -da-delinearize, -da-disable-delinearization-checks,
// -da-miv-max-level-threshold, -da-enable-dependence-test.
//
// A Dependence is one value type (Da_Dependence: `confused` marks the plain Dependence, otherwise a FullDependence);
// SmallBitVectors of loop levels are u64 masks (more than 63 levels fails loudly).

DV_NONE :: cast(u8) 0;
DV_LT   :: cast(u8) 1;
DV_EQ   :: cast(u8) 2;
DV_LE   :: cast(u8) 3;
DV_GT   :: cast(u8) 4;
DV_NE   :: cast(u8) 5;
DV_GE   :: cast(u8) 6;
DV_ALL  :: cast(u8) 7;

Dv_Entry :: struct {
    direction: u8 = DV_ALL;
    scalar := true;
    distance: Scev_Id = SCEV_NULL;
}

Da_Dependence :: struct {
    src: Value_Id;
    dst: Value_Id;
    confused := true;              // a plain Da_Dependence (isConfused); FullDependence otherwise
    assumptions: [..] u32;         // SCEVUnionPredicate
    levels: s64;
    same_sd_levels: s64;
    loop_independent: bool;
    dv: [..] Dv_Entry;
    dv_same_sd: [..] Dv_Entry;
}

Da_Test :: enum u8 { DEFAULT; ALL; STRONG_SIV; WEAK_CROSSING_SIV; EXACT_SIV; WEAK_ZERO_SIV; EXACT_RDIV; GCD_MIV; BANERJEE_MIV; }

da_opts: struct {
    delinearize := true;                       // -da-delinearize
    disable_delinearization_checks := false;   // -da-disable-delinearization-checks
    miv_max_level_threshold: s64 = 7;          // -da-miv-max-level-threshold
    enable_test := Da_Test.DEFAULT;            // -da-enable-dependence-test
};

da_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    bool_value :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == {
        case "da-delinearize"; da_opts.delinearize = bool_value(name, value, has_value); return true;
        case "da-disable-delinearization-checks"; da_opts.disable_delinearization_checks = bool_value(name, value, has_value); return true;
        case "delinearize-use-fixed-size-array-heuristic"; delin_opts.use_fixed_size_array_heuristic = bool_value(name, value, has_value); return true;
        case "da-miv-max-level-threshold";
            v, ok := string_to_int(value);
            if !has_value || !ok fatal("invalid integer value '%' for option -%", value, name);
            da_opts.miv_max_level_threshold = v;
            return true;
        case "da-enable-dependence-test";
            if value == {
                case "default"; da_opts.enable_test = .DEFAULT;
                case "all"; da_opts.enable_test = .ALL;
                case "strong-siv"; da_opts.enable_test = .STRONG_SIV;
                case "weak-crossing-siv"; da_opts.enable_test = .WEAK_CROSSING_SIV;
                case "exact-siv"; da_opts.enable_test = .EXACT_SIV;
                case "weak-zero-siv"; da_opts.enable_test = .WEAK_ZERO_SIV;
                case "exact-rdiv"; da_opts.enable_test = .EXACT_RDIV;
                case "gcd-miv"; da_opts.enable_test = .GCD_MIV;
                case "banerjee-miv"; da_opts.enable_test = .BANERJEE_MIV;
                case; fatal("invalid value '%' for option -da-enable-dependence-test", value);
            }
            return true;
    }
    return false;
}

// isDependenceTestEnabled
da_test_enabled :: (t: Da_Test) -> bool {
    if da_opts.enable_test == .ALL return true;
    if da_opts.enable_test == .DEFAULT return t != .BANERJEE_MIV;
    return da_opts.enable_test == t;
}

Da_Info :: struct {
    f: Value_Id;
    aar: Aa_Results;
    li: *Loop_Info;
    common_levels: s64;
    src_levels: s64;
    max_levels: s64;
    same_sd_levels: s64;
}

da_new :: (f: Value_Id, li: *Loop_Info) -> *Da_Info {
    di := New(Da_Info,, allocator = temp);
    di.f = f;
    di.aar = aa_results_for(f);
    di.li = li;
    return di;
}

// ---------------------------------------------------------------- Da_Dependence methods

dep_is_input :: (d: *Da_Dependence) -> bool { return may_read_from_memory(d.src) && may_read_from_memory(d.dst); }
dep_is_output :: (d: *Da_Dependence) -> bool { return may_write_to_memory(d.src) && may_write_to_memory(d.dst); }
dep_is_flow :: (d: *Da_Dependence) -> bool { return may_write_to_memory(d.src) && may_read_from_memory(d.dst); }
dep_is_anti :: (d: *Da_Dependence) -> bool { return may_read_from_memory(d.src) && may_write_to_memory(d.dst); }
dep_levels :: (d: *Da_Dependence) -> s64 { return ifx d.confused then 0 else d.levels; }
dep_same_sd_levels :: (d: *Da_Dependence) -> s64 { return ifx d.confused then 0 else d.same_sd_levels; }
dep_is_loop_independent :: (d: *Da_Dependence) -> bool { return ifx d.confused then true else d.loop_independent; }
dep_dv_entry :: (d: *Da_Dependence, level: s64, same_sd: bool) -> Dv_Entry {
    if !same_sd return d.dv[level - 1];
    return d.dv_same_sd[level - d.levels - 1];
}
dep_direction :: (d: *Da_Dependence, level: s64, same_sd := false) -> u8 {
    if d.confused return DV_ALL;
    return dep_dv_entry(d, level, same_sd).direction;
}
dep_distance :: (d: *Da_Dependence, level: s64, same_sd := false) -> Scev_Id {
    if d.confused return SCEV_NULL;
    return dep_dv_entry(d, level, same_sd).distance;
}
dep_is_scalar :: (d: *Da_Dependence, level: s64, same_sd := false) -> bool {
    if d.confused return false;
    return dep_dv_entry(d, level, same_sd).scalar;
}
dep_in_same_sd_loops :: (d: *Da_Dependence, level: s64) -> bool {
    if d.confused return false;
    return level > d.levels;
}

// FullDependence::isDirectionNegative
dep_is_direction_negative :: (d: *Da_Dependence) -> bool {
    if d.confused return false;
    for l: 1..d.levels {
        dir := d.dv[l - 1].direction;
        if dir == DV_EQ continue;
        if dir == DV_GT || dir == DV_GE return true;
        return false;
    }
    return false;
}
// FullDependence::negate
dep_negate :: (d: *Da_Dependence) {
    if d.confused return;
    t := d.src; d.src = d.dst; d.dst = t;
    for l: 1..d.levels {
        e := *d.dv[l - 1];
        dir := e.direction;
        rev := dir & DV_EQ;
        if dir & DV_LT rev |= DV_GT;
        if dir & DV_GT rev |= DV_LT;
        e.direction = rev;
        if e.distance != SCEV_NULL e.distance = sc_get_negative(e.distance);
    }
}
// FullDependence::normalize
dep_normalize :: (d: *Da_Dependence) -> bool {
    if !dep_is_direction_negative(d) return false;
    dep_negate(d);
    return true;
}

// Da_Dependence::dump
dep_dump :: (sb: *String_Builder, d: *Da_Dependence) {
    if d.confused append(sb, "confused");
    else {
        if dep_is_flow(d) append(sb, "flow");
        else if dep_is_output(d) append(sb, "output");
        else if dep_is_anti(d) append(sb, "anti");
        else if dep_is_input(d) append(sb, "input");
        dep_dump_imp(sb, d, false);
        if d.same_sd_levels > 0 {
            print_to_builder(sb, " / assuming % loop level(s) fused: ", d.same_sd_levels);
            dep_dump_imp(sb, d, true);
        }
    }
    append(sb, "!\n");
    if !sc_union_is_always_true(d.assumptions) {
        append(sb, "  Runtime Assumptions:\n");
        for d.assumptions sc_pred_print(sb, it, 2);
    }
}
// Da_Dependence::dumpImp
dep_dump_imp :: (sb: *String_Builder, d: *Da_Dependence, is_same_sd: bool) {
    level_num := dep_levels(d);
    if is_same_sd level_num += dep_same_sd_levels(d);
    on_same_sd := false;
    append(sb, " [");
    for ii: 1..level_num {
        if !on_same_sd && dep_in_same_sd_loops(d, ii) on_same_sd = true;
        dist := dep_distance(d, ii, on_same_sd);
        if dist != SCEV_NULL sc_print(sb, dist);
        else if dep_is_scalar(d, ii, on_same_sd) append(sb, "S");
        else {
            dir := dep_direction(d, ii, on_same_sd);
            if dir == DV_ALL append(sb, "*");
            else {
                if dir & DV_LT append(sb, "<");
                if dir & DV_EQ append(sb, "=");
                if dir & DV_GT append(sb, ">");
            }
        }
        if ii < level_num append(sb, " ");
    }
    if dep_is_loop_independent(d) append(sb, "|<");
    append(sb, "]");
}

// ---------------------------------------------------------------- helpers

// underlyingObjectsAlias
da_underlying_objects_alias :: (di: *Da_Info, loc_a: Mem_Loc, loc_b: Mem_Loc) -> u8 {
    q := aa_query_new(*di.aar);
    q.may_be_cross_iteration = true;   // BAA.enableCrossIterationMode()
    if aa_alias(q, mloc_before_or_after(loc_a.ptr, loc_a.tags), mloc_before_or_after(loc_b.ptr, loc_b.tags)).kind == AR_NO return AR_NO;
    a_obj := get_underlying_object(loc_a.ptr);
    b_obj := get_underlying_object(loc_b.ptr);
    if a_obj == b_obj return AR_MUST;
    if !is_identified_object(a_obj) || !is_identified_object(b_obj) return AR_MAY;
    return AR_NO;
}

// isLoadOrStore: LoadInst/StoreInst::isUnordered
da_is_load_or_store :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o != .LOAD && o != .STORE return false;
    r := inst(i);
    return r.ord1 <= ORD_UNORDERED && (r.flags & F_VOLATILE) == 0;
}

// DependenceInfo::haveSameSD
da_have_same_sd :: (di: *Da_Info, a: Loop_Id, b: Loop_Id) -> bool {
    if a == b return true;
    li := di.li;
    if li_depth(li, a) != li_depth(li, b) return false;
    if li_loop_latch(li, a) == NONE || li_loop_latch(li, b) == NONE return false;
    a_ub := sc_get_backedge_taken_count(a);
    b_ub := sc_get_backedge_taken_count(b);
    if a_ub == SCEV_CNC || b_ub == SCEV_CNC return false;
    wider := sc_get_wider_type(sc_type(a_ub), sc_type(b_ub));
    a_ub = sc_get_noop_or_zero_extend(a_ub, wider);
    b_ub = sc_get_noop_or_zero_extend(b_ub, wider);
    return a_ub == b_ub;
}

// DependenceInfo::establishNestingLevels
da_establish_nesting_levels :: (di: *Da_Info, src: Value_Id, dst: Value_Id) {
    li := di.li;
    src_level := cast(s64) li_block_depth(li, inst_block(src));
    dst_level := cast(s64) li_block_depth(li, inst_block(dst));
    src_loop := li_loop_for(li, inst_block(src));
    dst_loop := li_loop_for(li, inst_block(dst));
    di.src_levels = src_level;
    di.max_levels = src_level + dst_level;
    di.same_sd_levels = 0;
    while src_level > dst_level { src_loop = li_parent(li, src_loop); src_level -= 1; }
    while dst_level > src_level { dst_loop = li_parent(li, dst_loop); dst_level -= 1; }
    src_frontier: Loop_Id = NONE;
    dst_frontier: Loop_Id = NONE;
    while src_loop != dst_loop {
        src_frontier = src_loop; dst_frontier = dst_loop;
        src_loop = li_parent(li, src_loop);
        dst_loop = li_parent(li, dst_loop);
        src_level -= 1;
    }
    if src_frontier != NONE && dst_frontier != NONE && da_have_same_sd(di, src_frontier, dst_frontier) di.same_sd_levels = 1;
    di.common_levels = src_level;
    di.max_levels -= di.common_levels;
}

da_map_src_loop :: (di: *Da_Info, l: Loop_Id) -> s64 { return cast(s64) li_depth(di.li, l); }
da_map_dst_loop :: (di: *Da_Info, l: Loop_Id) -> s64 {
    d := cast(s64) li_depth(di.li, l);
    if d > di.common_levels return d - di.common_levels + di.src_levels;
    return d;
}

// DependenceInfo::isLoopInvariant
da_is_loop_invariant :: (di: *Da_Info, e: Scev_Id, nest: Loop_Id) -> bool {
    if nest == NONE return true;
    return sc_is_loop_invariant(e, li_outermost(di.li, nest));
}

da_bit :: (level: s64) -> u64 {
    if level > 63 fatal("da: more than 63 loop levels are not supported");
    return (cast(u64) 1) << cast(u64) level;
}
da_popcount :: (m: u64) -> s64 { n := 0; x := m; while x { n += 1; x &= x - 1; } return n; }

// DependenceInfo::collectCommonLoops
da_collect_common_loops :: (di: *Da_Info, e: Scev_Id, nest: Loop_Id, loops: *u64) {
    l := nest;
    while l != NONE {
        level := cast(s64) li_depth(di.li, l);
        if level <= di.common_levels && !sc_is_loop_invariant(e, l) loops.* |= da_bit(level);
        l = li_parent(di.li, l);
    }
}

// DependenceInfo::checkSubscript
da_check_subscript :: (di: *Da_Info, e: Scev_Id, nest: Loop_Id, loops: *u64, is_src: bool) -> bool {
    if !sc_is_addrec(e) return da_is_loop_invariant(di, e, nest);
    l := nest;
    while l != NONE && sc_loop(e) != l l = li_parent(di.li, l);
    if l == NONE return false;
    if !sc_has_nsw(e) return false;
    start := sc_start(e);
    step := sc_step_recurrence(e);
    if !da_is_loop_invariant(di, step, nest) return false;
    if is_src loops.* |= da_bit(da_map_src_loop(di, sc_loop(e)));
    else loops.* |= da_bit(da_map_dst_loop(di, sc_loop(e)));
    return da_check_subscript(di, start, nest, loops, is_src);
}

Da_Class :: enum u8 { ZIV; SIV; RDIV; MIV; NON_LINEAR; }

// DependenceInfo::classifyPair
da_classify_pair :: (di: *Da_Info, src: Scev_Id, src_nest: Loop_Id, dst: Scev_Id, dst_nest: Loop_Id, loops: *u64) -> Da_Class {
    src_loops: u64; dst_loops: u64;
    if !da_check_subscript(di, src, src_nest, *src_loops, true) return .NON_LINEAR;
    if !da_check_subscript(di, dst, dst_nest, *dst_loops, false) return .NON_LINEAR;
    loops.* = src_loops | dst_loops;
    n := da_popcount(loops.*);
    if n == 0 return .ZIV;
    if n == 1 return .SIV;
    if n == 2 && da_popcount(src_loops) == 1 && da_popcount(dst_loops) == 1 return .RDIV;
    return .MIV;
}

// DependenceInfo::collectUpperBound
da_collect_upper_bound :: (l: Loop_Id, t: Type_Id) -> Scev_Id {
    if sc_has_loop_invariant_backedge_taken_count(l) return sc_get_truncate_or_zero_extend(sc_get_backedge_taken_count(l), t);
    return SCEV_NULL;
}
// DependenceInfo::collectNonNegativeConstantUpperBound
da_collect_non_negative_constant_upper_bound :: (l: Loop_Id, t: Type_Id) -> (bool, APInt) {
    ub := da_collect_upper_bound(l, t);
    if ub != SCEV_NULL && sc_is_const(ub) {
        r := sc_ap(ub);
        if ap_is_non_negative(r) return true, r;
    }
    return false, .{};
}

// minusSCEVNoSignedOverflow
da_minus_no_signed_overflow :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
    if sc_will_not_overflow(.SUB, true, a, b) return sc_get_minus(a, b);
    return SCEV_NULL;
}

// OverflowSafeSignedAPInt: `ok` false = unknown
Osa :: struct { ok: bool; v: APInt; }
osa :: (v: APInt) -> Osa { r: Osa; r.ok = true; r.v = v; return r; }
osa_add :: (a: Osa, b: Osa) -> Osa { if !a.ok || !b.ok return .{}; r, ov := ap_sadd_ov(a.v, b.v); if ov return .{}; return osa(r); }
osa_sub :: (a: Osa, b: Osa) -> Osa { if !a.ok || !b.ok return .{}; r, ov := ap_ssub_ov(a.v, b.v); if ov return .{}; return osa(r); }
osa_mul :: (a: Osa, b: Osa) -> Osa { if !a.ok || !b.ok return .{}; r, ov := ap_smul_ov(a.v, b.v); if ov return .{}; return osa(r); }
osa_neg :: (a: Osa) -> Osa { if !a.ok return .{}; if ap_is_min_signed(a.v) return .{}; return osa(ap_neg(a.v)); }
osa_add_int :: (a: Osa, n: s64) -> Osa { if !a.ok return .{}; return osa_add(a, osa(ap_from_s64(a.v.bits, n))); }

// APInt::sdivrem
da_sdivrem :: (a: APInt, b: APInt) -> (APInt, APInt) {
    if ap_is_zero(b) fatal("da: division by zero");
    return ap_sdiv(a, b), ap_srem(a, b);
}

// floorOfQuotient / ceilingOfQuotient
da_floor_of_quotient :: (oa: Osa, ob: Osa) -> Osa {
    if !oa.ok || !ob.ok return .{};
    a := oa.v; b := ob.v;
    q, r := da_sdivrem(a, b);
    if ap_is_zero(r) return osa(q);
    if (ap_is_strictly_positive(a) && ap_is_strictly_positive(b)) || (ap_is_negative(a) && ap_is_negative(b)) return osa(q);
    return osa_add_int(osa(q), -1);
}
da_ceiling_of_quotient :: (oa: Osa, ob: Osa) -> Osa {
    if !oa.ok || !ob.ok return .{};
    a := oa.v; b := ob.v;
    q, r := da_sdivrem(a, b);
    if ap_is_zero(r) return osa(q);
    if (ap_is_strictly_positive(a) && ap_is_strictly_positive(b)) || (ap_is_negative(a) && ap_is_negative(b)) return osa_add_int(osa(q), 1);
    return osa(q);
}

// inferDomainOfAffine
da_infer_domain_of_affine :: (a: Osa, b: Osa, ub: Osa) -> (Osa, Osa) {
    tl, tu: Osa;
    if ap_is_strictly_positive(a.v) {
        tl = da_ceiling_of_quotient(osa_neg(b), a);
        tu = da_floor_of_quotient(osa_sub(ub, b), a);
    } else {
        tu = da_floor_of_quotient(osa_neg(b), a);
        tl = da_ceiling_of_quotient(osa_sub(ub, b), a);
    }
    return tl, tu;
}

// findGCD: (computed, disproved); G, X, Y
da_find_gcd :: (bits: u32, am: APInt, bm: APInt, delta: APInt) -> (ok: bool, disproved: bool, g: APInt, x: APInt, y: APInt) {
    a0 := ap_from_s64(bits, 1); a1 := ap_from_s64(bits, 0);
    b0 := ap_from_s64(bits, 0); b1 := ap_from_s64(bits, 1);
    if ap_is_min_signed(am) || ap_is_min_signed(bm) return false, false, .{}, .{}, .{};
    g0 := ap_abs(am);
    g1 := ap_abs(bm);
    q, r := da_sdivrem(g0, g1);
    while !ap_is_zero(r) {
        a2 := ap_sub(a0, ap_mul(q, a1)); a0 = a1; a1 = a2;
        b2 := ap_sub(b0, ap_mul(q, b1)); b0 = b1; b1 = b2;
        g0 = g1; g1 = r;
        q, r = da_sdivrem(g0, g1);
    }
    g := g1;
    x := ifx ap_is_negative(am) then ap_neg(a1) else a1;
    y := ifx ap_is_negative(bm) then b1 else ap_neg(b1);
    r = ap_srem(delta, g);
    if !ap_is_zero(r) return true, true, g, x, y;
    return true, false, g, x, y;
}

// ---------------------------------------------------------------- the tests

// testZIV
da_test_ziv :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id) -> bool {
    if sc_is_known_predicate(ICMP_EQ, src, dst) return false;
    if sc_is_known_predicate(ICMP_NE, src, dst) return true;
    return false;
}

// strongSIVtest
da_strong_siv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, level_in: s64, result: *Da_Dependence, under_rt: bool) -> bool {
    if !da_test_enabled(.STRONG_SIV) return false;
    coeff := sc_step_recurrence(src);
    src_const := sc_start(src);
    dst_const := sc_start(dst);
    level := level_in - 1;
    delta := da_minus_no_signed_overflow(src_const, dst_const);
    if delta == SCEV_NULL return false;
    e := *result.dv[level];
    if sc_is_const(delta) && sc_is_const(coeff) {
        distance, remainder := da_sdivrem(sc_ap(delta), sc_ap(coeff));
        if !ap_is_zero(remainder) return true;
        e.distance = sc_get_constant(distance);
        if ap_is_strictly_positive(distance) e.direction &= DV_LT;
        else if ap_is_negative(distance) e.direction &= DV_GT;
        else e.direction &= DV_EQ;
    } else if sc_is_zero(delta) {
        if !sc_is_known_non_zero(coeff) {
            if under_rt {
                p := sc_get_compare_predicate(ICMP_NE, coeff, sc_get_zero(sc_type(coeff)));
                sc_union_add(*result.assumptions, p);
            } else return false;
        }
        e.distance = delta;
        e.direction &= DV_EQ;
    } else {
        if sc_is_one(coeff) e.distance = delta;
        delta_maybe_zero := !sc_is_known_non_zero(delta);
        delta_maybe_positive := !sc_is_known_non_positive(delta);
        delta_maybe_negative := !sc_is_known_non_negative(delta);
        coeff_maybe_positive := !sc_is_known_non_positive(coeff);
        coeff_maybe_negative := !sc_is_known_non_negative(coeff);
        new_dir := DV_NONE;
        if (delta_maybe_positive && coeff_maybe_positive) || (delta_maybe_negative && coeff_maybe_negative) new_dir = DV_LT;
        if delta_maybe_zero new_dir |= DV_EQ;
        if (delta_maybe_negative && coeff_maybe_positive) || (delta_maybe_positive && coeff_maybe_negative) new_dir |= DV_GT;
        e.direction &= new_dir;
    }
    return false;
}

// weakCrossingSIVtest
da_weak_crossing_siv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, level_in: s64, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.WEAK_CROSSING_SIV) return false;
    coeff := sc_step_recurrence(src);
    src_const := sc_start(src);
    dst_const := sc_start(dst);
    level := level_in - 1;
    delta := da_minus_no_signed_overflow(dst_const, src_const);
    if delta == SCEV_NULL return false;
    if !sc_is_const(coeff) return false;
    if !sc_is_const(delta) return false;
    src_range := sc_signed_range(src);
    dst_range := sc_signed_range(dst);
    e := *result.dv[level];
    if cr_is_single_element(cr_intersect(src_range, dst_range)) {
        e.direction &= ~DV_LT;
        e.direction &= ~DV_GT;
        if !e.direction return true;
        e.distance = sc_get_zero(sc_type(delta));
        return false;
    }
    distance, remainder := da_sdivrem(sc_ap(delta), sc_ap(coeff));
    if !ap_is_zero(remainder) return true;
    if ap_get_bit(distance, 0) e.direction &= ~DV_EQ;
    return false;
}

// exactSIVtest
da_exact_siv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, level_in: s64, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.EXACT_SIV) return false;
    return da_exact_test_impl(di, src, dst, result, level_in - 1);
}

// weakZeroSIVtestImpl
da_weak_zero_siv_test_impl :: (di: *Da_Info, ar: Scev_Id, c: Scev_Id, level: s64, result: *Da_Dependence) -> bool {
    ar_coeff := sc_step_recurrence(ar);
    ar_const := sc_start(ar);
    if c == ar_const && sc_is_known_non_zero(ar_coeff) {
        if level < di.common_levels result.dv[level].direction &= DV_LE;
        return false;
    }
    delta := da_minus_no_signed_overflow(c, ar_const);
    if delta == SCEV_NULL return false;
    if !sc_is_const(ar_coeff) return false;
    ub := da_collect_upper_bound(sc_loop(ar), sc_type(delta));
    if ub != SCEV_NULL {
        overlap_at_last := false;
        if sc_is_known_non_zero(ar_coeff) {
            last := evaluate_at_iteration(ar, ub);
            overlap_at_last = last == c;
        }
        if overlap_at_last {
            if level < di.common_levels result.dv[level].direction &= DV_GE;
            return false;
        }
    }
    if sc_is_const(delta) && !ap_is_zero(ap_srem(sc_ap(delta), sc_ap(ar_coeff))) return true;
    return false;
}

// weakZeroSrcSIVtest
da_weak_zero_src_siv_test :: (di: *Da_Info, src_const: Scev_Id, dst: Scev_Id, level_in: s64, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.WEAK_ZERO_SIV) return false;
    level := level_in - 1;
    dep_negate(result);
    res := da_weak_zero_siv_test_impl(di, dst, src_const, level, result);
    dep_negate(result);
    return res;
}
// weakZeroDstSIVtest
da_weak_zero_dst_siv_test :: (di: *Da_Info, src: Scev_Id, dst_const: Scev_Id, level_in: s64, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.WEAK_ZERO_SIV) return false;
    return da_weak_zero_siv_test_impl(di, src, dst_const, level_in - 1, result);
}

// exactRDIVtest
da_exact_rdiv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.EXACT_RDIV) return false;
    return da_exact_test_impl(di, src, dst, result, -1);
}

// exactTestImpl (level < 0: std::nullopt)
da_exact_test_impl :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, result: *Da_Dependence, level: s64) -> bool {
    src_coeff := sc_step_recurrence(src);
    src_const := sc_start(src);
    dst_coeff := sc_step_recurrence(dst);
    dst_const := sc_start(dst);
    delta := da_minus_no_signed_overflow(dst_const, src_const);
    if delta == SCEV_NULL return false;
    if !sc_is_const(delta) || !sc_is_const(src_coeff) || !sc_is_const(dst_coeff) return false;
    am := sc_ap(src_coeff);
    bm := sc_ap(dst_coeff);
    cm := sc_ap(delta);
    bits := am.bits;
    ok, disproved, g, x, y := da_find_gcd(bits, am, bm, cm);
    if !ok return false;
    if disproved return true;
    has_src_um, src_um := da_collect_non_negative_constant_upper_bound(sc_loop(src), sc_type(delta));
    has_dst_um, dst_um := da_collect_non_negative_constant_upper_bound(sc_loop(dst), sc_type(delta));
    tc := osa(ap_sdiv(cm, g));
    tx := osa_mul(osa(x), tc);
    ty := osa_mul(osa(y), tc);
    if !tc.ok || !tx.ok || !ty.ok return false;
    tb := ap_sdiv(bm, g);
    ta := ap_sdiv(am, g);
    src_um_o: Osa; if has_src_um src_um_o = osa(src_um);
    dst_um_o: Osa; if has_dst_um dst_um_o = osa(dst_um);
    tl0, tu0 := da_infer_domain_of_affine(osa(tb), tx, src_um_o);
    tl1, tu1 := da_infer_domain_of_affine(osa(ta), ty, dst_um_o);
    get_max_or_min :: (v0: Osa, v1: Osa, is_min: bool) -> Osa {
        if v0.ok && v1.ok return osa(ifx is_min then ap_smin(v0.v, v1.v) else ap_smax(v0.v, v1.v));
        if v0.ok return v0;
        if v1.ok return v1;
        return .{};
    }
    opt_tl := get_max_or_min(tl0, tl1, false);
    opt_tu := get_max_or_min(tu0, tu1, true);
    if !opt_tl.ok || !opt_tu.ok return false;
    tl := opt_tl.v; tu := opt_tu.v;
    if ap_sgt(tl, tu) return true;
    if level < 0 return false;
    new_dir := DV_NONE;
    lower, upper: Osa;
    oty := ty; otx := tx; ota := osa(ta); otb := osa(tb); otl := osa(tl); otu := osa(tu);
    if ap_sgt(ta, tb) {
        lower = osa_add(osa_sub(oty, otx), osa_mul(osa_sub(ota, otb), otl));
        upper = osa_add(osa_sub(oty, otx), osa_mul(osa_sub(ota, otb), otu));
    } else {
        lower = osa_add(osa_sub(oty, otx), osa_mul(osa_sub(ota, otb), otu));
        upper = osa_add(osa_sub(oty, otx), osa_mul(osa_sub(ota, otb), otl));
    }
    if !lower.ok || !upper.ok return false;
    if ap_is_non_positive(lower.v) && ap_is_non_negative(upper.v) new_dir |= DV_EQ;
    if ap_is_negative(lower.v) new_dir |= DV_GT;
    if ap_is_strictly_positive(upper.v) new_dir |= DV_LT;
    result.dv[level].direction &= new_dir;
    return result.dv[level].direction == DV_NONE;
}

// testSIV
da_test_siv :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, result: *Da_Dependence, under_rt: bool) -> bool {
    src_ar := sc_is_addrec(src);
    dst_ar := sc_is_addrec(dst);
    if src_ar && dst_ar {
        src_coeff := sc_step_recurrence(src);
        dst_coeff := sc_step_recurrence(dst);
        level := da_map_src_loop(di, sc_loop(src));
        disproven := false;
        if src_coeff == dst_coeff disproven = da_strong_siv_test(di, src, dst, level, result, under_rt);
        else if src_coeff == sc_get_negative(dst_coeff) disproven = da_weak_crossing_siv_test(di, src, dst, level, result);
        return disproven || da_exact_siv_test(di, src, dst, level, result);
    }
    if src_ar return da_weak_zero_dst_siv_test(di, src, dst, da_map_src_loop(di, sc_loop(src)), result);
    if dst_ar return da_weak_zero_src_siv_test(di, src, dst, da_map_dst_loop(di, sc_loop(dst)), result);
    fatal("internal: SIV test expected at least one AddRec");
    return false;
}

// testRDIV
da_test_rdiv :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, result: *Da_Dependence) -> bool {
    return da_exact_rdiv_test(di, src, dst, result) || da_gcd_miv_test(di, src, dst, result);
}
// testMIV
da_test_miv :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, loops: u64, result: *Da_Dependence) -> bool {
    return da_gcd_miv_test(di, src, dst, result) || da_banerjee_miv_test(di, src, dst, loops, result);
}

// getConstantCoefficient
da_get_constant_coefficient :: (e: Scev_Id) -> (bool, APInt) {
    if sc_is_const(e) return true, sc_ap(e);
    if sc_is_mul(e) && sc_is_const(sc_op(e, 0)) && sc_has_nsw(e) return true, sc_ap(sc_op(e, 0));
    return false, .{};
}

// accumulateCoefficientsGCD (SCEV_NULL = nullptr)
da_accumulate_coefficients_gcd :: (di: *Da_Info, e: Scev_Id, cur_loop: Loop_Id, cur_loop_coeff: *Scev_Id, running_gcd: *APInt) -> Scev_Id {
    if !sc_is_addrec(e) return e;
    start := sc_start(e);
    step := sc_step_recurrence(e);
    if sc_loop(e) == cur_loop {
        cur_loop_coeff.* = step;
    } else {
        ok, c := da_get_constant_coefficient(step);
        if !ok return SCEV_NULL;
        running_gcd.* = ap_gcd(running_gcd.*, ap_abs(c));
    }
    return da_accumulate_coefficients_gcd(di, start, cur_loop, cur_loop_coeff, running_gcd);
}

// gcdMIVtest
da_gcd_miv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.GCD_MIV) return false;
    bit_width := sc_bits(src);
    running_gcd := ap_zero(bit_width);
    dummy := SCEV_NULL;
    src_const := da_accumulate_coefficients_gcd(di, src, NONE, *dummy, *running_gcd);
    if src_const == SCEV_NULL return false;
    dst_const := da_accumulate_coefficients_gcd(di, dst, NONE, *dummy, *running_gcd);
    if dst_const == SCEV_NULL return false;
    delta := da_minus_no_signed_overflow(dst_const, src_const);
    if delta == SCEV_NULL return false;
    if !sc_is_const(delta) return false;
    const_delta := sc_ap(delta);
    if ap_is_zero(const_delta) return false;
    if ap_is_zero(running_gcd) fatal("da: GCD MIV test with a zero GCD");
    remainder := ap_srem(const_delta, running_gcd);
    if !ap_is_zero(remainder) return true;
    coefficients := src;
    while sc_is_addrec(coefficients) {
        ar := coefficients;
        coefficients = sc_start(ar);
        cur_loop := sc_loop(ar);
        running_gcd = ap_zero(bit_width);
        src_coeff := sc_step_recurrence(ar);
        dst_coeff := sc_get_minus(src_coeff, src_coeff);
        if da_accumulate_coefficients_gcd(di, src, cur_loop, *src_coeff, *running_gcd) == SCEV_NULL ||
           da_accumulate_coefficients_gcd(di, dst, cur_loop, *dst_coeff, *running_gcd) == SCEV_NULL return false;
        delta = da_minus_no_signed_overflow(dst_coeff, src_coeff);
        if delta == SCEV_NULL continue;
        ok, c := da_get_constant_coefficient(delta);
        if !ok continue;
        running_gcd = ap_gcd(running_gcd, ap_abs(c));
        if !ap_is_zero(running_gcd) {
            remainder = ap_srem(const_delta, running_gcd);
            if !ap_is_zero(remainder) {
                level := da_map_src_loop(di, cur_loop);
                result.dv[level - 1].direction &= ~DV_EQ;
            }
        }
    }
    return false;
}

// ---------------------------------------------------------------- Banerjee

Da_Coeff_Info :: struct { coeff: Scev_Id; pos_part: Scev_Id; neg_part: Scev_Id; iterations: Scev_Id; }
Da_Bound_Info :: struct {
    iterations: Scev_Id;
    upper: [8] Scev_Id;
    lower: [8] Scev_Id;
    direction: u8;
    dir_set: u8;
}

da_positive_part :: (x: Scev_Id) -> Scev_Id { return sc_get_smax2(x, sc_get_zero(sc_type(x))); }
da_negative_part :: (x: Scev_Id) -> Scev_Id { return sc_get_smin2(x, sc_get_zero(sc_type(x))); }

// collectCoeffInfo
da_collect_coeff_info :: (di: *Da_Info, subscript_in: Scev_Id, src_flag: bool) -> (Scev_Id, [] Da_Coeff_Info) {
    zero := sc_get_zero(sc_type(subscript_in));
    ci := NewArray(di.max_levels + 1, Da_Coeff_Info,, allocator = temp);
    for k: 1..di.max_levels { ci[k].coeff = zero; ci[k].pos_part = zero; ci[k].neg_part = zero; ci[k].iterations = SCEV_NULL; }
    subscript := subscript_in;
    while sc_is_addrec(subscript) {
        l := sc_loop(subscript);
        k := ifx src_flag then da_map_src_loop(di, l) else da_map_dst_loop(di, l);
        ci[k].coeff = sc_step_recurrence(subscript);
        ci[k].pos_part = da_positive_part(ci[k].coeff);
        ci[k].neg_part = da_negative_part(ci[k].coeff);
        ci[k].iterations = da_collect_upper_bound(l, sc_type(subscript));
        subscript = sc_start(subscript);
    }
    return subscript, ci;
}

// findBoundsALL / findBoundsEQ / findBoundsLT / findBoundsGT
da_find_bounds_all :: (a: [] Da_Coeff_Info, b: [] Da_Coeff_Info, bound: [] Da_Bound_Info, k: s64) {
    bound[k].lower[DV_ALL] = SCEV_NULL;
    bound[k].upper[DV_ALL] = SCEV_NULL;
    if bound[k].iterations != SCEV_NULL {
        bound[k].lower[DV_ALL] = sc_get_mul2(sc_get_minus(a[k].neg_part, b[k].pos_part), bound[k].iterations);
        bound[k].upper[DV_ALL] = sc_get_mul2(sc_get_minus(a[k].pos_part, b[k].neg_part), bound[k].iterations);
    } else {
        if sc_is_known_predicate(ICMP_EQ, a[k].neg_part, b[k].pos_part) bound[k].lower[DV_ALL] = sc_get_zero(sc_type(a[k].coeff));
        if sc_is_known_predicate(ICMP_EQ, a[k].pos_part, b[k].neg_part) bound[k].upper[DV_ALL] = sc_get_zero(sc_type(a[k].coeff));
    }
}
da_find_bounds_eq :: (a: [] Da_Coeff_Info, b: [] Da_Coeff_Info, bound: [] Da_Bound_Info, k: s64) {
    bound[k].lower[DV_EQ] = SCEV_NULL;
    bound[k].upper[DV_EQ] = SCEV_NULL;
    if bound[k].iterations != SCEV_NULL {
        delta := sc_get_minus(a[k].coeff, b[k].coeff);
        neg := da_negative_part(delta);
        bound[k].lower[DV_EQ] = sc_get_mul2(neg, bound[k].iterations);
        pos := da_positive_part(delta);
        bound[k].upper[DV_EQ] = sc_get_mul2(pos, bound[k].iterations);
    } else {
        delta := sc_get_minus(a[k].coeff, b[k].coeff);
        neg := da_negative_part(delta);
        if sc_is_zero(neg) bound[k].lower[DV_EQ] = neg;
        pos := da_positive_part(delta);
        if sc_is_zero(pos) bound[k].upper[DV_EQ] = pos;
    }
}
da_find_bounds_lt :: (a: [] Da_Coeff_Info, b: [] Da_Coeff_Info, bound: [] Da_Bound_Info, k: s64) {
    bound[k].lower[DV_LT] = SCEV_NULL;
    bound[k].upper[DV_LT] = SCEV_NULL;
    if bound[k].iterations != SCEV_NULL {
        iter_1 := sc_get_minus(bound[k].iterations, sc_get_one(sc_type(bound[k].iterations)));
        neg := da_negative_part(sc_get_minus(a[k].neg_part, b[k].coeff));
        bound[k].lower[DV_LT] = sc_get_minus(sc_get_mul2(neg, iter_1), b[k].coeff);
        pos := da_positive_part(sc_get_minus(a[k].pos_part, b[k].coeff));
        bound[k].upper[DV_LT] = sc_get_minus(sc_get_mul2(pos, iter_1), b[k].coeff);
    } else {
        neg := da_negative_part(sc_get_minus(a[k].neg_part, b[k].coeff));
        if sc_is_zero(neg) bound[k].lower[DV_LT] = sc_get_negative(b[k].coeff);
        pos := da_positive_part(sc_get_minus(a[k].pos_part, b[k].coeff));
        if sc_is_zero(pos) bound[k].upper[DV_LT] = sc_get_negative(b[k].coeff);
    }
}
da_find_bounds_gt :: (a: [] Da_Coeff_Info, b: [] Da_Coeff_Info, bound: [] Da_Bound_Info, k: s64) {
    bound[k].lower[DV_GT] = SCEV_NULL;
    bound[k].upper[DV_GT] = SCEV_NULL;
    if bound[k].iterations != SCEV_NULL {
        iter_1 := sc_get_minus(bound[k].iterations, sc_get_one(sc_type(bound[k].iterations)));
        neg := da_negative_part(sc_get_minus(a[k].coeff, b[k].pos_part));
        bound[k].lower[DV_GT] = sc_get_add2(sc_get_mul2(neg, iter_1), a[k].coeff);
        pos := da_positive_part(sc_get_minus(a[k].coeff, b[k].neg_part));
        bound[k].upper[DV_GT] = sc_get_add2(sc_get_mul2(pos, iter_1), a[k].coeff);
    } else {
        neg := da_negative_part(sc_get_minus(a[k].coeff, b[k].pos_part));
        if sc_is_zero(neg) bound[k].lower[DV_GT] = a[k].coeff;
        pos := da_positive_part(sc_get_minus(a[k].coeff, b[k].neg_part));
        if sc_is_zero(pos) bound[k].upper[DV_GT] = a[k].coeff;
    }
}

// getLowerBound / getUpperBound
da_get_lower_bound :: (di: *Da_Info, bound: [] Da_Bound_Info) -> Scev_Id {
    sum := bound[1].lower[bound[1].direction];
    k := 2;
    while sum != SCEV_NULL && k <= di.max_levels {
        x := bound[k].lower[bound[k].direction];
        if x != SCEV_NULL sum = sc_get_add2(sum, x); else sum = SCEV_NULL;
        k += 1;
    }
    return sum;
}
da_get_upper_bound :: (di: *Da_Info, bound: [] Da_Bound_Info) -> Scev_Id {
    sum := bound[1].upper[bound[1].direction];
    k := 2;
    while sum != SCEV_NULL && k <= di.max_levels {
        x := bound[k].upper[bound[k].direction];
        if x != SCEV_NULL sum = sc_get_add2(sum, x); else sum = SCEV_NULL;
        k += 1;
    }
    return sum;
}

// testBounds
da_test_bounds :: (di: *Da_Info, dir_kind: u8, level: s64, bound: [] Da_Bound_Info, delta: Scev_Id) -> bool {
    bound[level].direction = dir_kind;
    lb := da_get_lower_bound(di, bound);
    if lb != SCEV_NULL && sc_is_known_predicate(ICMP_SGT, lb, delta) return false;
    ub := da_get_upper_bound(di, bound);
    if ub != SCEV_NULL && sc_is_known_predicate(ICMP_SGT, delta, ub) return false;
    return true;
}

// exploreDirections
da_explore_directions :: (di: *Da_Info, level: s64, a: [] Da_Coeff_Info, b: [] Da_Coeff_Info, bound: [] Da_Bound_Info, loops: u64,
                          depth_expanded: *s64, delta: Scev_Id) -> s64 {
    if di.common_levels > da_opts.miv_max_level_threshold {
        for k: 1..di.common_levels if loops & da_bit(k) bound[k].dir_set = DV_ALL;
        return 1;
    }
    if level > di.common_levels {
        for k: 1..di.common_levels if loops & da_bit(k) bound[k].dir_set |= bound[k].direction;
        return 1;
    }
    if loops & da_bit(level) {
        if level > depth_expanded.* {
            depth_expanded.* = level;
            da_find_bounds_lt(a, b, bound, level);
            da_find_bounds_gt(a, b, bound, level);
            da_find_bounds_eq(a, b, bound, level);
        }
        new_deps := 0;
        if da_test_bounds(di, DV_LT, level, bound, delta) new_deps += da_explore_directions(di, level + 1, a, b, bound, loops, depth_expanded, delta);
        if da_test_bounds(di, DV_EQ, level, bound, delta) new_deps += da_explore_directions(di, level + 1, a, b, bound, loops, depth_expanded, delta);
        if da_test_bounds(di, DV_GT, level, bound, delta) new_deps += da_explore_directions(di, level + 1, a, b, bound, loops, depth_expanded, delta);
        bound[level].direction = DV_ALL;
        return new_deps;
    }
    return da_explore_directions(di, level + 1, a, b, bound, loops, depth_expanded, delta);
}

// banerjeeMIVtest
da_banerjee_miv_test :: (di: *Da_Info, src: Scev_Id, dst: Scev_Id, loops: u64, result: *Da_Dependence) -> bool {
    if !da_test_enabled(.BANERJEE_MIV) return false;
    a0, a := da_collect_coeff_info(di, src, true);
    b0, b := da_collect_coeff_info(di, dst, false);
    bound := NewArray(di.max_levels + 1, Da_Bound_Info,, allocator = temp);
    delta := da_minus_no_signed_overflow(b0, a0);
    if delta == SCEV_NULL return false;
    for k: 1..di.max_levels {
        bound[k].iterations = ifx a[k].iterations != SCEV_NULL then a[k].iterations else b[k].iterations;
        bound[k].direction = DV_ALL;
        bound[k].dir_set = DV_NONE;
        da_find_bounds_all(a, b, bound, k);
    }
    disproved := false;
    if da_test_bounds(di, DV_ALL, 0, bound, delta) {
        depth_expanded := 0;
        new_deps := da_explore_directions(di, 1, a, b, bound, loops, *depth_expanded, delta);
        if new_deps > 0 {
            for k: 1..di.common_levels {
                if loops & da_bit(k) {
                    old := result.dv[k - 1].direction;
                    result.dv[k - 1].direction = old & bound[k].dir_set;
                    if !result.dv[k - 1].direction { disproved = true; break; }
                }
            }
        } else disproved = true;
    } else disproved = true;
    return disproved;
}

// ---------------------------------------------------------------- delinearization

// tryDelinearizeFixedSize
da_try_delinearize_fixed_size :: (di: *Da_Info, src: Value_Id, dst: Value_Id, src_fn: Scev_Id, dst_fn: Scev_Id,
                                  src_subs: *[..] Scev_Id, dst_subs: *[..] Scev_Id) -> bool {
    elem_size := sc_get_element_size(src);
    src_sizes: [..] Scev_Id; src_sizes.allocator = temp;
    dst_sizes: [..] Scev_Id; dst_sizes.allocator = temp;
    if !delin_delinearize_fixed_size_array(sc_remove_pointer_base(src_fn), src_subs, *src_sizes, elem_size) ||
       !delin_delinearize_fixed_size_array(sc_remove_pointer_base(dst_fn), dst_subs, *dst_sizes, elem_size) return false;
    same := src_sizes.count == dst_sizes.count;
    if same for src_sizes if it != dst_sizes[it_index] { same = false; break; }
    if !same { src_subs.count = 0; dst_subs.count = 0; return false; }
    if !da_opts.disable_delinearization_checks {
        if !delin_validate(src_sizes, src_subs.*) || !delin_validate(dst_sizes, dst_subs.*) {
            src_subs.count = 0; dst_subs.count = 0;
            return false;
        }
    }
    return true;
}

// tryDelinearizeParametricSize
da_try_delinearize_parametric_size :: (di: *Da_Info, src: Value_Id, dst: Value_Id, src_fn: Scev_Id, dst_fn: Scev_Id,
                                       src_subs: *[..] Scev_Id, dst_subs: *[..] Scev_Id) -> bool {
    src_base := sc_get_pointer_base(src_fn);
    dst_base := sc_get_pointer_base(dst_fn);
    elem_size := sc_get_element_size(src);
    if elem_size != sc_get_element_size(dst) return false;
    src_scev := sc_get_minus(src_fn, src_base);
    dst_scev := sc_get_minus(dst_fn, dst_base);
    if !sc_is_addrec(src_scev) || !sc_is_addrec(dst_scev) || !sc_is_affine(src_scev) || !sc_is_affine(dst_scev) return false;
    terms: [..] Scev_Id; terms.allocator = temp;
    delin_collect_parametric_terms(src_scev, *terms);
    delin_collect_parametric_terms(dst_scev, *terms);
    sizes: [..] Scev_Id; sizes.allocator = temp;
    delin_find_array_dimensions(*terms, *sizes, elem_size);
    delin_compute_access_functions(src_scev, src_subs, *sizes);
    delin_compute_access_functions(dst_scev, dst_subs, *sizes);
    if src_subs.count < 2 || dst_subs.count < 2 || src_subs.count != dst_subs.count return false;
    if !da_opts.disable_delinearization_checks
        if !delin_validate(sizes, src_subs.*) || !delin_validate(sizes, dst_subs.*) return false;
    return true;
}

Da_Subscript :: struct { src: Scev_Id; dst: Scev_Id; classification: Da_Class; loops: u64; }

// tryDelinearize
da_try_delinearize :: (di: *Da_Info, src: Value_Id, dst: Value_Id, pair: *[..] Da_Subscript) -> bool {
    src_ptr := load_store_pointer_operand(src);
    dst_ptr := load_store_pointer_operand(dst);
    src_loop := li_loop_for(di.li, inst_block(src));
    dst_loop := li_loop_for(di.li, inst_block(dst));
    src_fn := sc_get_scev_at_scope(sc_get_scev(src_ptr), src_loop);
    dst_fn := sc_get_scev_at_scope(sc_get_scev(dst_ptr), dst_loop);
    src_base := sc_get_pointer_base(src_fn);
    dst_base := sc_get_pointer_base(dst_fn);
    if !sc_is_unknown(src_base) || !sc_is_unknown(dst_base) || src_base != dst_base return false;
    src_subs: [..] Scev_Id; src_subs.allocator = temp;
    dst_subs: [..] Scev_Id; dst_subs.allocator = temp;
    if !da_try_delinearize_fixed_size(di, src, dst, src_fn, dst_fn, *src_subs, *dst_subs) &&
       !da_try_delinearize_parametric_size(di, src, dst, src_fn, dst_fn, *src_subs, *dst_subs) return false;
    pair.count = 0;
    for k: 0..src_subs.count - 1 {
        s: Da_Subscript;
        s.src = src_subs[k]; s.dst = dst_subs[k];
        array_add(pair, s);
    }
    return true;
}

// ---------------------------------------------------------------- depends

da_confused :: (src: Value_Id, dst: Value_Id, assume: [] u32) -> *Da_Dependence {
    d := New(Da_Dependence,, allocator = temp);
    d.src = src; d.dst = dst;
    d.confused = true;
    d.assumptions.allocator = temp;
    for assume sc_union_add(*d.assumptions, it);
    return d;
}

// DependenceInfo::depends; null = no dependence
da_depends :: (di: *Da_Info, src: Value_Id, dst: Value_Id, under_rt := false) -> *Da_Dependence {
    assume: [..] u32; assume.allocator = temp;
    possibly_loop_independent := src != dst;
    if !(may_read_or_write_memory(src) && may_read_or_write_memory(dst)) return null;
    if !da_is_load_or_store(src) || !da_is_load_or_store(dst) return da_confused(src, dst, assume);
    dst_loc := mloc_get(dst);
    src_loc := mloc_get(src);
    if da_underlying_objects_alias(di, dst_loc, src_loc) == {
        case AR_MAY; #through;
        case AR_PARTIAL; return da_confused(src, dst, assume);
        case AR_NO; return null;
    }
    if dst_loc.size != src_loc.size || !ls_is_precise(dst_loc.size) || !ls_is_precise(src_loc.size) return da_confused(src, dst, assume);
    src_ptr := load_store_pointer_operand(src);
    dst_ptr := load_store_pointer_operand(dst);
    src_scev := sc_get_scev(src_ptr);
    dst_scev := sc_get_scev(dst_ptr);
    src_base := sc_get_pointer_base(src_scev);
    dst_base := sc_get_pointer_base(dst_scev);
    if src_base != dst_base return da_confused(src, dst, assume);
    src_loop := li_loop_for(di.li, inst_block(src));
    dst_loop := li_loop_for(di.li, inst_block(dst));
    if !da_is_loop_invariant(di, src_base, src_loop) || !da_is_loop_invariant(di, dst_base, dst_loop) return da_confused(src, dst, assume);
    elt_size := src_loc.size;   // LocationSize::toRaw (precise here)
    src_ev := sc_get_minus(src_scev, src_base);
    dst_ev := sc_get_minus(dst_scev, dst_base);
    if !sc_is_known_multiple_of(src_ev, elt_size, *assume) || !sc_is_known_multiple_of(dst_ev, elt_size, *assume) return da_confused(src, dst, assume);
    if assume.count != 0 && !under_rt return da_confused(src, dst, assume);

    pair: [..] Da_Subscript; pair.allocator = temp;
    p0: Da_Subscript; p0.src = src_ev; p0.dst = dst_ev;
    array_add(*pair, p0);
    if da_opts.delinearize da_try_delinearize(di, src, dst, *pair);
    pairs := pair.count;

    da_establish_nesting_levels(di, src, dst);
    di.common_levels += di.same_sd_levels;
    di.max_levels -= di.same_sd_levels;
    if di.same_sd_levels > 0 {
        for p: 0..pairs - 1 {
            loops: u64;
            c := da_classify_pair(di, pair[p].src, src_loop, pair[p].dst, dst_loop, *loops);
            if c != .ZIV && c != .SIV && c != .RDIV {
                di.common_levels -= di.same_sd_levels;
                di.max_levels += di.same_sd_levels;
                di.same_sd_levels = 0;
                break;
            }
        }
    }
    if di.max_levels >= 63 fatal("da: more than 62 loop levels are not supported");

    result := New(Da_Dependence,, allocator = temp);
    result.src = src; result.dst = dst;
    result.confused = false;
    result.assumptions.allocator = temp;
    for assume sc_union_add(*result.assumptions, it);
    result.levels = di.common_levels;
    result.same_sd_levels = 0;
    result.loop_independent = possibly_loop_independent;
    result.dv.allocator = temp; result.dv_same_sd.allocator = temp;
    for 1..di.common_levels array_add(*result.dv, .{});

    for p: 0..pairs - 1 {
        pair[p].loops = 0;
        pair[p].classification = da_classify_pair(di, pair[p].src, src_loop, pair[p].dst, dst_loop, *pair[p].loops);
    }

    for si: 0..pairs - 1 {
        src_range := sc_signed_range(pair[si].src);
        dst_range := sc_signed_range(pair[si].dst);
        if cr_is_empty_set(cr_intersect(src_range, dst_range)) return null;
        if pair[si].classification == {
            case .NON_LINEAR;
                da_collect_common_loops(di, pair[si].src, src_loop, *pair[si].loops);
                da_collect_common_loops(di, pair[si].dst, dst_loop, *pair[si].loops);
            case .ZIV; if da_test_ziv(di, pair[si].src, pair[si].dst) return null;
            case .SIV; if da_test_siv(di, pair[si].src, pair[si].dst, result, under_rt) return null;
            case .RDIV; if da_test_rdiv(di, pair[si].src, pair[si].dst, result) return null;
            case .MIV; if da_test_miv(di, pair[si].src, pair[si].dst, pair[si].loops, result) return null;
        }
    }

    complete_loops: u64;
    for si: 0..pairs - 1 complete_loops |= pair[si].loops;
    for ii: 1..di.common_levels if complete_loops & da_bit(ii) result.dv[ii - 1].scalar = false;

    for ii: 1..result.levels {
        if result.dv[ii - 1].direction == DV_EQ {
            if result.dv[ii - 1].distance == SCEV_NULL result.dv[ii - 1].distance = sc_get_zero(sc_type(src_scev));
        }
    }

    if di.same_sd_levels > 0 {
        di.common_levels -= di.same_sd_levels;
        di.max_levels += di.same_sd_levels;
        for k: 0..di.same_sd_levels - 1 array_add(*result.dv_same_sd, result.dv[di.common_levels + k]);
        result.dv.count = di.common_levels;
        result.levels = di.common_levels;
        result.same_sd_levels = di.same_sd_levels;
    }

    if possibly_loop_independent {
        for ii: 1..di.common_levels {
            if !(dep_direction(result, ii) & DV_EQ) { result.loop_independent = false; break; }
        }
    } else {
        all_equal := true;
        for ii: 1..di.common_levels if dep_direction(result, ii) != DV_EQ { all_equal = false; break; }
        if all_equal && result.assumptions.count == 0 return null;
    }
    return result;
}

// ScalarEvolution::isKnownMultipleOf(S, M, Assumptions)
sc_is_known_multiple_of :: (s: Scev_Id, m: u64, assumptions: *[..] u32) -> bool {
    if m == 0 return false;
    if m == 1 return true;
    if sc_is_addrec(s) return sc_is_known_multiple_of(sc_start(s), m, assumptions) && sc_is_known_multiple_of(sc_step_recurrence(s), m, assumptions);
    if sc_is_const(s) return ap_urem_u64(sc_ap(s), m) == 0;
    sty := sc_type(s);
    if type_kind(sty) != .INT fatal("isKnownMultipleOf on a non-integer SCEV");
    smod_m := sc_get_urem(s, sc_get_constant_t(sty, m));
    zero := sc_get_zero(sty);
    if sc_is_known_predicate(ICMP_EQ, smod_m, zero) return true;
    if sc_is_known_predicate(ICMP_NE, smod_m, zero) return false;
    p := sc_get_compare_predicate(ICMP_EQ, smod_m, zero);
    for assumptions.* if sc_pred_implies(it, p) return true;
    array_add(assumptions, p);
    return true;
}

// ---------------------------------------------------------------- print<da>

// dumpExampleDependence
da_printer_run :: (f: Value_Id, normalize: bool) -> Preserved {
    li := get_loop_info(f);
    se = get_scev(f);
    di := da_new(f, li);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Dependence Analysis' for function '%':\n", vname(f));
    insts: [..] Value_Id; insts.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) array_add(*insts, i);
    for si: 0..insts.count - 1 {
        s := insts[si];
        if !may_read_or_write_memory(s) continue;
        for dj: si..insts.count - 1 {
            d := insts[dj];
            if !may_read_or_write_memory(d) continue;
            append(*sb, "Src:"); append(*sb, inst_to_string(s)); append(*sb, " --> Dst:"); append(*sb, inst_to_string(d)); append(*sb, "\n");
            append(*sb, "  da analyze - ");
            dep := da_depends(di, s, d, true);
            if dep {
                if normalize && dep_normalize(dep) append(*sb, "normalized - ");
                dep_dump(*sb, dep);
            } else append(*sb, "none!\n");
        }
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
