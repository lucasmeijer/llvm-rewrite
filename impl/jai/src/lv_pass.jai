// LoopVectorizePass: the pass driver (runImpl, processLoop), the parts of LoopVectorizationCostModel and
// VFSelectionContext that decide the maximum VF, and the cl::opts.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp and LoopVectorizationPlanner.cpp (LLVM 23.1.5).
//
// Status: legality and the maximum-VF computation are ported. Whenever LLVM would build a VPlan for a vector VF
// or interleave, the port fails loudly (VPlan is not ported yet, see NOTES.md "LoopVectorize").

// ---------------------------------------------------------------- cl::opts

Lv_Opt_Int :: struct { v: s64; set: bool; }

lv_opts: struct {
    enable_epilogue_vectorization := true;          // -enable-epilogue-vectorization
    epilogue_force_vf: Lv_Opt_Int = .{1, false};    // -epilogue-vectorization-force-VF
    epilogue_min_vf: Lv_Opt_Int;                    // -epilogue-vectorization-minimum-VF
    tiny_trip_count_threshold: s64 = 16;            // -vectorizer-min-trip-count
    memory_check_threshold: s64 = 128;              // -vectorize-memory-check-threshold
    force_partial_aliasing := false;                // -force-partial-aliasing-vectorization
    tail_folding_policy: Lv_Opt_Int;                // -tail-folding-policy (0 dont-fold-tail, 1 prefer, 2 must)
    epilogue_tail_folding_policy: Lv_Opt_Int;       // -epilogue-tail-folding-policy
    force_tail_folding_style: Lv_Opt_Int;           // -force-tail-folding-style (Tail_Folding_Style)
    enable_wide_lane_mask := false;                 // -enable-wide-lane-mask
    enable_interleaved_mem_accesses: Lv_Opt_Int;    // -enable-interleaved-mem-accesses
    enable_masked_interleaved_mem_accesses: Lv_Opt_Int; // -enable-masked-interleaved-mem-accesses
    force_target_num_scalar_regs: Lv_Opt_Int;
    force_target_num_vector_regs: Lv_Opt_Int;
    force_target_max_scalar_interleave: Lv_Opt_Int;
    force_target_max_vector_interleave: Lv_Opt_Int;
    force_target_instruction_cost: Lv_Opt_Int;
    small_loop_cost: s64 = 20;
    with_block_frequency := true;                   // -loop-vectorize-with-block-frequency
    loadstore_runtime_interleave := true;           // -enable-loadstore-runtime-interleave
    num_stores_to_predicate: s64 = 1;               // -vectorize-num-stores-pred
    scev_check_threshold: s64 = 16;                 // -vectorize-scev-check-threshold
    pragma_scev_check_threshold: s64 = 128;         // -pragma-vectorize-scev-check-threshold
    ind_var_register_heur := true;                  // -enable-ind-var-reg-heur
    max_nested_scalar_reduction_ic: s64 = 2;        // -max-nested-scalar-reduction-interleave
    force_ordered_reductions: Lv_Opt_Int;           // -force-ordered-reductions
    prefer_predicated_reduction_select := false;
    enable_vplan_native_path := false;
    vplan_build_outerloop_stress_test := false;
    interleave_loops := true;                       // -interleave-loops
    vectorize_loops := true;                        // -vectorize-loops
    force_masked_divrem: Lv_Opt_Int;                // -force-widen-divrem-via-masked-intrinsic (BOU_UNSET when !set)
    enable_early_exit := true;                      // -enable-early-exit-vectorization
    enable_early_exit_with_side_effects := false;
    // LoopVectorizationPlanner.cpp
    maximize_bandwidth: Lv_Opt_Int;                 // -vectorizer-maximize-bandwidth
    wider_vf_if_call_variants := true;              // -vectorizer-maximize-bandwidth-for-vector-calls
    consider_reg_pressure: Lv_Opt_Int;              // -vectorizer-consider-reg-pressure
    force_target_supports_scalable_vectors := false;
    prefer_inloop_reductions := false;              // -prefer-inloop-reductions
    force_target_supports_masked_memory_ops := false;
    force_target_supports_gather_scatter_ops := false;
    // VectorUtils.cpp
    max_interleave_group_factor: s64 = 8;           // -max-interleave-group-factor
    vplan_verify_each := false;                     // -vplan-verify-each (verification only)
};

lv_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pbool :: (p: *bool, name: string, value: string, has_value: bool) {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" p.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" p.* = false;
        else fatal("invalid boolean value '%' for option -%", value, name);
    }
    pint :: (p: *s64, name: string, value: string, has_value: bool) {
        if !has_value fatal("option -% requires a value", name);
        v, ok := string_to_int(value);
        if !ok || v < 0 fatal("invalid value '%' for option -%", value, name);
        p.* = cast(s64) v;
    }
    pocc_bool :: (p: *Lv_Opt_Int, name: string, value: string, has_value: bool) {
        b: bool; pbool(*b, name, value, has_value); p.v = cast(s64) b; p.set = true;
    }
    pocc_int :: (p: *Lv_Opt_Int, name: string, value: string, has_value: bool) { pint(*p.v, name, value, has_value); p.set = true; }
    o := *lv_opts;
    if name == "force-vector-interleave" {
        pint(*laa_opts.force_vector_interleave, name, value, has_value);
        lvl_opts.force_vector_interleave_set = true;
        return true;
    }
    if name == "force-vector-width" {
        if has_value && begins_with(value, "vscale") fatal("loop-vectorize: scalable -force-vector-width is not supported yet");
        pint(*laa_opts.force_vector_width, name, value, has_value);
        return true;
    }
    if name == "enable-epilogue-vectorization" { pbool(*o.enable_epilogue_vectorization, name, value, has_value); return true; }
    if name == "epilogue-vectorization-force-VF" {
        if has_value && begins_with(value, "vscale") fatal("loop-vectorize: scalable -epilogue-vectorization-force-VF is not supported yet");
        pocc_int(*o.epilogue_force_vf, name, value, has_value); return true;
    }
    if name == "epilogue-vectorization-minimum-VF" { pocc_int(*o.epilogue_min_vf, name, value, has_value); return true; }
    if name == "vectorizer-min-trip-count" { pint(*o.tiny_trip_count_threshold, name, value, has_value); return true; }
    if name == "vectorize-memory-check-threshold" { pint(*o.memory_check_threshold, name, value, has_value); return true; }
    if name == "force-partial-aliasing-vectorization" { pbool(*o.force_partial_aliasing, name, value, has_value); return true; }
    if name == "tail-folding-policy" || name == "epilogue-tail-folding-policy" {
        p := ifx name == "tail-folding-policy" then *o.tail_folding_policy else *o.epilogue_tail_folding_policy;
        if value == "dont-fold-tail" p.v = 0;
        else if value == "prefer-fold-tail" p.v = 1;
        else if value == "must-fold-tail" && name == "tail-folding-policy" p.v = 2;
        else fatal("invalid value '%' for option -%", value, name);
        p.set = true;
        return true;
    }
    if name == "force-tail-folding-style" {
        if value == "none" o.force_tail_folding_style.v = xx Tail_Folding_Style.NONE;
        else if value == "data" o.force_tail_folding_style.v = xx Tail_Folding_Style.DATA;
        else if value == "data-without-lane-mask" o.force_tail_folding_style.v = xx Tail_Folding_Style.DATA_WITHOUT_LANE_MASK;
        else if value == "data-and-control" o.force_tail_folding_style.v = xx Tail_Folding_Style.DATA_AND_CONTROL_FLOW;
        else if value == "data-with-evl" o.force_tail_folding_style.v = xx Tail_Folding_Style.DATA_WITH_EVL;
        else fatal("invalid value '%' for option -%", value, name);
        o.force_tail_folding_style.set = true;
        return true;
    }
    if name == "enable-wide-lane-mask" { pbool(*o.enable_wide_lane_mask, name, value, has_value); return true; }
    if name == "enable-interleaved-mem-accesses" { pocc_bool(*o.enable_interleaved_mem_accesses, name, value, has_value); return true; }
    if name == "enable-masked-interleaved-mem-accesses" { pocc_bool(*o.enable_masked_interleaved_mem_accesses, name, value, has_value); return true; }
    if name == "force-target-num-scalar-regs" { pocc_int(*o.force_target_num_scalar_regs, name, value, has_value); return true; }
    if name == "force-target-num-vector-regs" { pocc_int(*o.force_target_num_vector_regs, name, value, has_value); return true; }
    if name == "force-target-max-scalar-interleave" { pocc_int(*o.force_target_max_scalar_interleave, name, value, has_value); return true; }
    if name == "force-target-max-vector-interleave" { pocc_int(*o.force_target_max_vector_interleave, name, value, has_value); return true; }
    if name == "force-target-instruction-cost" { pocc_int(*o.force_target_instruction_cost, name, value, has_value); return true; }
    if name == "small-loop-cost" { pint(*o.small_loop_cost, name, value, has_value); return true; }
    if name == "loop-vectorize-with-block-frequency" { pbool(*o.with_block_frequency, name, value, has_value); return true; }
    if name == "enable-loadstore-runtime-interleave" { pbool(*o.loadstore_runtime_interleave, name, value, has_value); return true; }
    if name == "vectorize-num-stores-pred" { pint(*o.num_stores_to_predicate, name, value, has_value); return true; }
    if name == "vectorize-scev-check-threshold" { pint(*o.scev_check_threshold, name, value, has_value); return true; }
    if name == "pragma-vectorize-scev-check-threshold" { pint(*o.pragma_scev_check_threshold, name, value, has_value); return true; }
    if name == "enable-ind-var-reg-heur" { pbool(*o.ind_var_register_heur, name, value, has_value); return true; }
    if name == "max-nested-scalar-reduction-interleave" { pint(*o.max_nested_scalar_reduction_ic, name, value, has_value); return true; }
    if name == "force-ordered-reductions" { pocc_bool(*o.force_ordered_reductions, name, value, has_value); return true; }
    if name == "prefer-predicated-reduction-select" { pbool(*o.prefer_predicated_reduction_select, name, value, has_value); return true; }
    if name == "enable-vplan-native-path" { pbool(*o.enable_vplan_native_path, name, value, has_value); return true; }
    if name == "vplan-build-outerloop-stress-test" { pbool(*o.vplan_build_outerloop_stress_test, name, value, has_value); return true; }
    if name == "interleave-loops" { pbool(*o.interleave_loops, name, value, has_value); return true; }
    if name == "vectorize-loops" { pbool(*o.vectorize_loops, name, value, has_value); return true; }
    if name == "force-widen-divrem-via-masked-intrinsic" { pocc_bool(*o.force_masked_divrem, name, value, has_value); return true; }
    if name == "enable-early-exit-vectorization" { pbool(*o.enable_early_exit, name, value, has_value); return true; }
    if name == "enable-early-exit-vectorization-with-side-effects" { pbool(*o.enable_early_exit_with_side_effects, name, value, has_value); return true; }
    if name == "vectorizer-maximize-bandwidth" { pocc_bool(*o.maximize_bandwidth, name, value, has_value); return true; }
    if name == "vectorizer-maximize-bandwidth-for-vector-calls" { pbool(*o.wider_vf_if_call_variants, name, value, has_value); return true; }
    if name == "vectorizer-consider-reg-pressure" { pocc_bool(*o.consider_reg_pressure, name, value, has_value); return true; }
    if name == "force-target-supports-scalable-vectors" { pbool(*o.force_target_supports_scalable_vectors, name, value, has_value); return true; }
    if name == "prefer-inloop-reductions" { pbool(*o.prefer_inloop_reductions, name, value, has_value); return true; }
    if name == "force-target-supports-masked-memory-ops" { pbool(*o.force_target_supports_masked_memory_ops, name, value, has_value); return true; }
    if name == "force-target-supports-gather-scatter-ops" { pbool(*o.force_target_supports_gather_scatter_ops, name, value, has_value); return true; }
    if name == "max-interleave-group-factor" { pint(*o.max_interleave_group_factor, name, value, has_value); return true; }
    if name == "vplan-verify-each" { pbool(*o.vplan_verify_each, name, value, has_value); return true; }
    // LoopVectorizationLegality.cpp
    if name == "enable-if-conversion" { pbool(*lvl_opts.enable_if_conversion, name, value, has_value); return true; }
    if name == "lv-strided-pointer-ivs" { pbool(*lvl_opts.allow_strided_pointer_ivs, name, value, has_value); return true; }
    if name == "hints-allow-reordering" { pbool(*lvl_opts.hints_allow_reordering, name, value, has_value); return true; }
    if name == "enable-histogram-loop-vectorization" { pbool(*lvl_opts.enable_histogram, name, value, has_value); return true; }
    if name == "scalable-vectorization" {
        if value == "off" lvl_opts.scalable_vectorization = SK_FIXED_WIDTH_ONLY;
        else if value == "preferred" || value == "on" lvl_opts.scalable_vectorization = SK_PREFER_SCALABLE;
        else if value == "always" lvl_opts.scalable_vectorization = SK_ALWAYS_SCALABLE;
        else fatal("invalid value '%' for option -%", value, name);
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- ElementCount

Ec :: struct { n: u64; scalable: bool; }
ec_fixed :: (n: u64) -> Ec { return .{n, false}; }
ec_scalable :: (n: u64) -> Ec { return .{n, true}; }
ec_is_scalar :: (e: Ec) -> bool { return !e.scalable && e.n == 1; }
ec_is_vector :: (e: Ec) -> bool { return (e.scalable && e.n > 0) || (!e.scalable && e.n > 1); }
ec_nonzero :: (e: Ec) -> bool { return e.n != 0; }
ec_eq :: (a: Ec, b: Ec) -> bool { return a.n == b.n && a.scalable == b.scalable; }
ec_known_lt :: (a: Ec, b: Ec) -> bool { if a.scalable && !b.scalable return false; return a.n < b.n; }
ec_known_le :: (a: Ec, b: Ec) -> bool { if a.scalable && !b.scalable return a.n == 0; return a.n <= b.n; }
ec_known_gt :: (a: Ec, b: Ec) -> bool { return ec_known_lt(b, a); }

Vf_Pair :: struct { fixed: Ec = .{0, false}; scalable: Ec = .{0, true}; }   // FixedScalableVFPair
vfp_ok :: (p: Vf_Pair) -> bool { return p.fixed.n != 0 || p.scalable.n != 0; }
vfp_none :: () -> Vf_Pair { return .{}; }

Epilogue_Lowering :: enum u8 {
    ALLOWED; NOT_ALLOWED_OPT_SIZE; NOT_ALLOWED_LOW_TRIP_LOOP; NOT_NEEDED_FOLD_TAIL; NOT_ALLOWED_FOLD_TAIL;
}
Tail_Folding_Style :: enum u8 { NONE; DATA; DATA_AND_CONTROL_FLOW; DATA_AND_CONTROL_FLOW_WITHOUT_RUNTIME_CHECK; DATA_WITHOUT_LANE_MASK; DATA_WITH_EVL; }
Alias_Masking_Status :: enum u8 { NOT_DECIDED; DISABLED; ENABLED; }

// ---------------------------------------------------------------- trip-count helpers

// getSmallConstantTripCount (LoopVectorize.cpp); scalable trip counts (vscale) are never formed for x86 / NoTTI
lv_small_constant_trip_count :: (l: Loop_Id) -> Ec {
    tc := sc_get_small_constant_trip_count(l);
    if tc return ec_fixed(tc);
    btc := sc_get_backedge_taken_count(l);
    if sc_is_cnc(btc) return ec_fixed(0);
    ec := sc_get_trip_count_from_exit_count_ty(btc, sc_type(btc), l);
    if sc_kind(ec) == .VSCALE fatal("loop-vectorize: vscale trip counts are not supported yet");
    return ec_fixed(0);
}
// PredicatedScalarEvolution::getSmallConstantMaxTripCount
lv_pse_small_constant_max_trip_count :: (cm: *Lv_Cm) -> u32 {
    if !cm.has_small_constant_max_tc {
        preds: [..] u32; preds.allocator = temp;
        cm.small_constant_max_tc = constant_trip_count(sc_get_predicated_constant_max_backedge_taken_count(cm.l, *preds));
        pse_add_predicates(cm.pse, preds);
        cm.has_small_constant_max_tc = true;
    }
    return cm.small_constant_max_tc;
}
// getMaxTCFromNonZeroRange
lv_max_tc_from_non_zero_range :: (pse: *Pse, l: Loop_Id) -> u32 {
    btc := pse_get_backedge_taken_count(pse);
    if sc_is_cnc(btc) return 0;
    tc := sc_get_trip_count_from_exit_count_ty(btc, sc_type(btc), l);
    r := sc_unsigned_range(tc);
    m := cr_umax(r);
    if !ap_is_zero(m) && ap_active_bits(m) <= 32 return cast(u32) ap_zext_value(m);
    return 0;
}
// getSmallBestKnownTC: (known, trip count)
lv_small_best_known_tc :: (cm: *Lv_Cm, l: Loop_Id, can_use_constant_max := true, can_exclude_zero_trips := false,
                            compute_upper_bound_only := false) -> (bool, Ec) {
    tc := lv_small_constant_trip_count(l);
    if tc.n return true, tc;
    if lv_opts.with_block_frequency && !compute_upper_bound_only {
        ok, est := li_loop_estimated_trip_count(cm.li, l);
        if ok return true, ec_fixed(est);
    }
    if !can_use_constant_max return false, .{};
    mtc := lv_pse_small_constant_max_trip_count(cm);
    if mtc return true, ec_fixed(mtc);
    if can_use_constant_max && can_exclude_zero_trips {
        r := lv_max_tc_from_non_zero_range(cm.pse, l);
        if r return true, ec_fixed(r);
    }
    return false, .{};
}

// ---------------------------------------------------------------- TTI queries of the loop vectorizer

// TTI::getMaxInterleaveFactor
lv_tti_max_interleave_factor :: (t: *Tti, vf: Ec, has_unordered_reductions: bool) -> u64 {
    if t.kind != .X86 return 1;
    if ec_is_scalar(vf) return 1;
    st := *t.xl;
    if st_isAtom(st) return 1;
    if st_hasAVX(st) return 4;
    return 2;
}
// TTI::enableInterleavedAccessVectorization
lv_tti_enable_interleaved_access_vectorization :: (t: *Tti) -> bool {
    if t.kind != .X86 return false;
    return !st_isAtom(*t.xl);
}
// TTI::enableMaskedInterleavedAccessVectorization
lv_tti_enable_masked_interleaved_access_vectorization :: (t: *Tti) -> bool {
    if t.kind != .X86 return false;
    fatal("loop-vectorize: X86TTIImpl::enableMaskedInterleavedAccessVectorization is not ported yet");
    return false;
}
// useMaskedInterleavedAccesses
lv_use_masked_interleaved_accesses :: (t: *Tti) -> bool {
    if lv_opts.enable_masked_interleaved_mem_accesses.set return lv_opts.enable_masked_interleaved_mem_accesses.v != 0;
    return lv_tti_enable_masked_interleaved_access_vectorization(t);
}

// ---------------------------------------------------------------- LoopVectorizationCostModel + VFSelectionContext

Lv_Cm :: struct {
    f: Value_Id;
    l: Loop_Id;
    li: *Loop_Info;
    pse: *Pse;
    tti: *Tti;
    lvl: *Lvl;
    hints: *Lv_Hints;
    ac: *Assumption_Cache;
    opt_for_size: bool;
    sel: Epilogue_Lowering;
    tail_folding_style: Tail_Folding_Style;
    alias_masking: Alias_Masking_Status;
    values_to_ignore: Iset;
    vec_values_to_ignore: Iset;
    element_types: [..] Type_Id;               // VFSelectionContext::ElementTypesInLoop
    max_safe_elements: u64;                    // 0 = none
    max_permissible_fixed: Ec;                 // MaxPermissibleVFWithoutMaxBW.FixedVF
    has_small_constant_max_tc: bool;
    small_constant_max_tc: u32;
    uses_interleaved_access_info: bool;        // IAI.analyzeInterleaving was run (not ported: no groups)
    per_vf: [..] Lv_Cm_Vf;                     // Uniforms / Scalars / ForcedScalars / InstsToScalarize per VF
    decisions: Table(u64, Lv_Decision);        // WideningDecisions
    num_pred_stores: s64;
}

// requiresScalarEpilogue
lv_cm_requires_scalar_epilogue :: (cm: *Lv_Cm, is_vectorizing: bool) -> bool {
    if cm.sel != .ALLOWED return false;
    if li_exiting_block(cm.li, cm.l) != li_loop_latch(cm.li, cm.l) && !(lv_opts.enable_early_exit && lvl_has_uncountable_early_exit(cm.lvl))
        return true;
    // InterleaveInfo.requiresScalarEpilogue(): no interleave groups are formed (IAI not ported, see processLoop)
    return false;
}

// collectValuesToIgnore
lv_cm_collect_values_to_ignore :: (cm: *Lv_Cm) {
    li := cm.li; l := cm.l;
    eph: Table(Value_Id, bool); eph.allocator = temp;
    collect_ephemeral_values(li, l, cm.ac, *eph);
    for v, k: eph iset_insert(*cm.values_to_ignore, k);
    dead_ops: [..] Value_Id; dead_ops.allocator = temp;
    req_epi := lv_cm_requires_scalar_epilogue(cm, true);
    is_live_out_dead :: (cm: *Lv_Cm, u: Value_Id, req: bool) -> bool { return req && !li_contains(cm.li, cm.l, inst_block(u)); }
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    for < bb: rpo {
        i := block_last(bb);
        while i != NONE {
            prev := inst(i).prev;
            defer i = prev;
            if iset_has(*cm.vec_values_to_ignore, i) || iset_has(*cm.values_to_ignore, i) continue;
            if would_instruction_be_trivially_dead(i) {
                all := true;
                u := ir.v_first_use[i];
                while u != NONE {
                    usr := ir.u_user[u];
                    if !(iset_has(*cm.vec_values_to_ignore, usr) || iset_has(*cm.values_to_ignore, usr) || is_live_out_dead(cm, usr, req_epi)) { all = false; break; }
                    u = ir.u_next[u];
                }
                if all array_add(*dead_ops, i);
            }
            // isAccessInterleaved: no interleave groups (IAI not ported)
            if inst_op(i) == .CONDBR array_add(*dead_ops, i);
        }
    }
    header := li_header(li, l);
    is_empty_block :: (cm: *Lv_Cm, bb: Value_Id) -> bool {
        for i: block_insts(bb) if !(iset_has(*cm.values_to_ignore, i) || iset_has(*cm.vec_values_to_ignore, i) || inst_op(i) == .BR) return false;
        return true;
    }
    k := 0;
    while k < dead_ops.count {
        x := dead_ops[k];
        k += 1;
        if is_inst(x) && inst_op(x) == .CONDBR {
            then_bb := get_successor(x, 0); else_bb := get_successor(x, 1);
            if !li_contains(li, l, then_bb) || !li_contains(li, l, else_bb) continue;
            te := is_empty_block(cm, then_bb); ee := is_empty_block(cm, else_bb);
            if (te && ee) || (te && block_get_single_successor(then_bb) == else_bb && !block_has_phis(else_bb)) ||
               (ee && block_get_single_successor(else_bb) == then_bb && !block_has_phis(then_bb)) {
                iset_insert(*cm.vec_values_to_ignore, x);
                array_add(*dead_ops, op(x, 0));
            }
            continue;
        }
        if !is_inst(x) || !li_contains_inst(li, l, x) || (inst_op(x) == .PHI && inst_block(x) == header) || !would_instruction_be_trivially_dead(x) continue;
        bad := false;
        u := ir.v_first_use[x];
        while u != NONE {
            usr := ir.u_user[u];
            if !iset_has(*cm.vec_values_to_ignore, usr) && !iset_has(*cm.values_to_ignore, usr) && !is_live_out_dead(cm, usr, req_epi) { bad = true; break; }
            u = ir.u_next[u];
        }
        if bad continue;
        all_ign := true;
        u = ir.v_first_use[x];
        while u != NONE { if !iset_has(*cm.values_to_ignore, ir.u_user[u]) { all_ign = false; break; } u = ir.u_next[u]; }
        if all_ign iset_insert(*cm.values_to_ignore, x);
        iset_insert(*cm.vec_values_to_ignore, x);
        for j: 0..cast(s64) nops(x) - 1 array_add(*dead_ops, op(x, cast(u32) j));
    }
    for *cm.lvl.reductions for c: it.d.casts iset_insert(*cm.vec_values_to_ignore, c);
    for *cm.lvl.inductions for c: it.d.casts iset_insert(*cm.vec_values_to_ignore, c);
}


// VFSelectionContext::useOrderedReductions
lv_use_ordered_reductions :: (cm: *Lv_Cm, rd: *Rdx_Desc) -> bool { return !lvh_allow_reordering(cm.hints) && rd.is_ordered; }
// TTI::preferInLoopReduction (false for X86 and the base implementation)
lv_tti_prefer_in_loop_reduction :: (t: *Tti, k: Recur_Kind, ty: Type_Id) -> bool { return false; }

// VFSelectionContext::collectElementTypesForWidening
lv_collect_element_types_for_widening :: (cm: *Lv_Cm) {
    cm.element_types.count = 0;
    add :: (cm: *Lv_Cm, t: Type_Id) { if !array_find(cm.element_types, t) array_add(*cm.element_types, t); }
    for bb: li_blocks(cm.li, cm.l) for i: block_insts(bb) {
        t := vtype(i);
        if iset_has(*cm.values_to_ignore, i) continue;
        o := inst_op(i);
        if o != .LOAD && o != .STORE && o != .PHI continue;
        if o == .PHI {
            rd := lvl_find_reduction(cm.lvl, i);
            if !rd continue;
            if lv_opts.prefer_inloop_reductions || lv_use_ordered_reductions(cm, rd) || lv_tti_prefer_in_loop_reduction(cm.tti, rd.kind, rd.recur_type) continue;
            t = rd.recur_type;
        }
        if o == .STORE t = vtype(op(i, 0));
        add(cm, t);
    }
}

// VFSelectionContext::getSmallestAndWidestTypes
lv_smallest_and_widest_types :: (cm: *Lv_Cm) -> (u64, u64) {
    min_w: u64 = 0xFFFF_FFFF; max_w: u64 = 8;
    if cm.element_types.count == 0 && cm.lvl.reductions.count {
        for *cm.lvl.reductions {
            rb := cast(u64) type_bits(scalar_type(it.d.recur_type));
            min_w = min(min_w, min(cast(u64) it.d.min_width_cast, rb));
            max_w = max(max_w, rb);
        }
    } else {
        for cm.element_types {
            b := dl_type_size_bits(scalar_type(it));
            min_w = min(min_w, b); max_w = max(max_w, b);
        }
    }
    return min_w, max_w;
}

// VFSelectionContext::supportsScalableVectors
lv_supports_scalable_vectors :: () -> bool { return lv_opts.force_target_supports_scalable_vectors; }

// VFSelectionContext::useMaxBandwidth
lv_use_max_bandwidth :: (cm: *Lv_Cm, scalable: bool) -> bool {
    if lv_opts.maximize_bandwidth.set return lv_opts.maximize_bandwidth.v != 0;
    // TTI.shouldMaximizeVectorBandwidth is false for X86 and the base implementation
    return lv_opts.wider_vf_if_call_variants && cm.lvl.vec_call_variants_found;
}

// VFSelectionContext::clampVFByMaxTripCount
lv_clamp_vf_by_max_trip_count :: (vf: Ec, max_tc_in: u32, user_ic: u64, fold_tail: bool, req_epi: bool) -> Ec {
    est := vf.n;
    if vf.scalable fatal("loop-vectorize: scalable VFs are not supported yet");
    max_tc := max_tc_in;
    if max_tc > 0 && req_epi max_tc -= 1;
    ic := ifx user_ic > 0 then user_ic else 1;
    if max_tc && cast(u64) max_tc <= est * ic && (!fold_tail || (max_tc & (max_tc - 1)) == 0) {
        clamped := bit_floor(cast(u64) max_tc / ic);
        if clamped == 0 clamped = 1;
        return .{clamped, ifx fold_tail then vf.scalable else false};
    }
    return vf;
}

// VFSelectionContext::getMaximizedVFForTarget
lv_maximized_vf_for_target :: (cm: *Lv_Cm, max_tc: u32, smallest: u64, widest: u64, max_safe: Ec, user_ic: u64, fold_tail: bool, req_epi: bool) -> Ec {
    if max_safe.scalable return ec_fixed(1);   // RGK_ScalableVector register width is 0 for X86 and NoTTI
    widest_reg := tti_register_bit_width(cm.tti, RGK_FIXED_WIDTH_VECTOR);
    mvec := ec_fixed(bit_floor(widest_reg / widest));
    if !ec_known_lt(mvec, max_safe) mvec = max_safe;
    if mvec.n == 0 return ec_fixed(1);
    max_vf := lv_clamp_vf_by_max_trip_count(mvec, max_tc, user_ic, fold_tail, req_epi);
    if !ec_eq(max_vf, mvec) return max_vf;
    cm.max_permissible_fixed = max_vf;
    if lv_use_max_bandwidth(cm, false) {
        bw := ec_fixed(bit_floor(widest_reg / smallest));
        max_vf = ifx ec_known_lt(bw, max_safe) then bw else max_safe;
        // TTI.getMinimumVF is 0 for X86 and NoTTI
        max_vf = lv_clamp_vf_by_max_trip_count(max_vf, max_tc, user_ic, fold_tail, req_epi);
    }
    return max_vf;
}

// VFSelectionContext::isScalableVectorizationAllowed / getMaxLegalScalableVF
lv_max_legal_scalable_vf :: (cm: *Lv_Cm, max_safe_elements: u64) -> Ec {
    if !lv_supports_scalable_vectors() return ec_scalable(0);
    fatal("loop-vectorize: scalable vectorization is not supported yet");
    return ec_scalable(0);
}

// VFSelectionContext::computeFeasibleMaxVF
lv_compute_feasible_max_vf :: (cm: *Lv_Cm, max_tc: u32, user_vf: Ec, user_ic: u64, fold_tail: bool, req_epi: bool) -> Vf_Pair {
    smallest, widest := lv_smallest_and_widest_types(cm);
    max_safe_p2 := bit_floor(lvl_max_safe_vector_width_in_bits(cm.lvl) / widest);
    if !lvl_is_safe_for_any_store_load_forward_distances(cm.lvl) {
        sl := lvl_max_store_load_forward_safe_distance_in_bits(cm.lvl);
        max_safe_p2 = min(max_safe_p2, sl / widest);
    }
    max_safe_fixed := ec_fixed(max_safe_p2);
    max_safe_scalable := lv_max_legal_scalable_vf(cm, max_safe_p2);
    if !lvl_is_safe_for_any_vector_width(cm.lvl) cm.max_safe_elements = max_safe_p2;
    if user_vf.n {
        msu := ifx user_vf.scalable then max_safe_scalable else max_safe_fixed;
        if ec_known_le(user_vf, msu) {
            if user_vf.scalable return .{ec_fixed(user_vf.n), user_vf};
            r: Vf_Pair; r.fixed = user_vf; return r;
        }
        if !user_vf.scalable { r: Vf_Pair; r.fixed = max_safe_fixed; return r; }
    }
    result: Vf_Pair = .{ec_fixed(1), ec_scalable(0)};
    mv := lv_maximized_vf_for_target(cm, max_tc, smallest, widest, max_safe_fixed, user_ic, fold_tail, req_epi);
    if mv.n result.fixed = mv;
    mv2 := lv_maximized_vf_for_target(cm, max_tc, smallest, widest, max_safe_scalable, user_ic, fold_tail, req_epi);
    if mv2.n && mv2.scalable result.scalable = mv2;
    return result;
}

// VFSelectionContext::runtimeChecksRequired
lv_runtime_checks_required :: (cm: *Lv_Cm) -> bool {
    if lvl_needs_runtime_ptr_checks(cm.lvl) return true;
    if !sc_union_is_always_true(cm.pse.preds) return true;
    if cm.lvl.laa.symbolic_strides.count return true;
    return false;
}

// setTailFoldingStyle
lv_cm_set_tail_folding_style :: (cm: *Lv_Cm, is_scalable_vf: bool, user_ic: u64) {
    if !lvl_can_fold_tail_by_masking(cm.lvl) { cm.tail_folding_style = .NONE; return; }
    // TTI.getPreferredTailFoldingStyle() is DataWithoutLaneMask for X86 and the base implementation
    cm.tail_folding_style = .DATA_WITHOUT_LANE_MASK;
    if lv_opts.force_tail_folding_style.set cm.tail_folding_style = xx lv_opts.force_tail_folding_style.v;
    if cm.tail_folding_style != .DATA_WITH_EVL return;
    // EVL is never legal: TTI.hasActiveVectorLength() is false for X86 and NoTTI
    if cm.sel == .ALLOWED || cm.sel == .NOT_NEEDED_FOLD_TAIL cm.tail_folding_style = .NONE;
    else cm.tail_folding_style = .DATA_WITHOUT_LANE_MASK;
}
lv_cm_fold_tail_by_masking :: (cm: *Lv_Cm) -> bool { return cm.tail_folding_style != .NONE; }
lv_cm_fold_tail_with_evl :: (cm: *Lv_Cm) -> bool { return cm.tail_folding_style == .DATA_WITH_EVL; }

// tryToEnablePartialAliasMasking
lv_cm_try_to_enable_partial_alias_masking :: (cm: *Lv_Cm) {
    cm.alias_masking = .DISABLED;
    if !lv_opts.force_partial_aliasing || cm.lvl.fixed_order_recurrences.count return;
    rt := *cm.lvl.laa.rt;
    if !rt.can_use_diff_check || rt.diff_checks.count == 0 return;
    fatal("loop-vectorize: -force-partial-aliasing-vectorization is not supported yet");
}

// LoopVectorizationCostModel::computeMaxVF
lv_cm_compute_max_vf :: (cm: *Lv_Cm, user_vf: Ec, user_ic: u64) -> Vf_Pair {
    defer if cm.alias_masking == .NOT_DECIDED cm.alias_masking = .DISABLED;
    li := cm.li; l := cm.l;
    // TTI.hasBranchDivergence() is false for X86 and NoTTI
    tc := lv_small_constant_trip_count(l);
    max_tc := lv_pse_small_constant_max_trip_count(cm);
    if !max_tc && cm.sel == .ALLOWED max_tc = lv_max_tc_from_non_zero_range(cm.pse, l);
    if ec_is_scalar(tc) return vfp_none();
    btc := sc_get_backedge_taken_count(l);
    if !sc_is_cnc(btc) && type_bits(sc_type(btc)) >= type_bits(cm.lvl.widest_ind_ty) &&
       sc_is_known_predicate(ICMP_EQ, btc, sc_get_minus_one(sc_type(btc)))
        return vfp_none();
    if cm.sel == {
        case .ALLOWED;
            return lv_compute_feasible_max_vf(cm, max_tc, user_vf, user_ic, false, lv_cm_requires_scalar_epilogue(cm, true));
        case .NOT_ALLOWED_FOLD_TAIL; #through;
        case .NOT_NEEDED_FOLD_TAIL;
        case .NOT_ALLOWED_LOW_TRIP_LOOP; #through;
        case .NOT_ALLOWED_OPT_SIZE;
            if lv_runtime_checks_required(cm) return vfp_none();
    }
    // !useMaskedInterleavedAccesses(TTI): InterleaveInfo.invalidateGroupsRequiringScalarEpilogue() (no groups)
    max_factors := lv_compute_feasible_max_vf(cm, max_tc, user_vf, user_ic, true, lv_cm_requires_scalar_epilogue(cm, true));
    has_p2: bool = true;
    max_p2 := max_factors.fixed.n;
    if max_factors.scalable.n has_p2 = false;   // getMaxVScale is unknown for X86 and NoTTI
    no_scalar_epilogue_needed :: (cm: *Lv_Cm, max_vf: u64, user_ic: u64) -> bool {
        if li_exiting_block(cm.li, cm.l) != li_loop_latch(cm.li, cm.l) && !lvl_has_uncountable_early_exit(cm.lvl) return false;
        m := ifx user_ic then max_vf * user_ic else max_vf;
        btc := pse_get_symbolic_max_backedge_taken_count(cm.pse);
        ty := sc_type(btc);
        ec := sc_get_add2(btc, sc_get_one(ty));
        rem := sc_get_urem(sc_apply_loop_guards(ec, cm.l), sc_get_constant(ap_from_u64(sc_type_bits(ty), m)));
        return sc_is_zero(rem);
    }
    if has_p2 && max_p2 > 0 {
        if no_scalar_epilogue_needed(cm, max_p2, user_ic) return max_factors;
    }
    known, etc := lv_small_best_known_tc(cm, l);
    // TTI.getMinTripCountTailFoldingThreshold() is 0 for X86 and NoTTI
    if known && !etc.scalable && etc.n <= 0 {
        if has_p2 && max_p2 > 0 {
            if cm.sel == .NOT_ALLOWED_LOW_TRIP_LOOP && no_scalar_epilogue_needed(cm, max_factors.fixed.n, user_ic) {
                max_factors.scalable = ec_scalable(0);
                return max_factors;
            }
        }
        return vfp_none();
    }
    contains_scalable := max_factors.scalable.n != 0;
    lv_cm_set_tail_folding_style(cm, contains_scalable, user_ic);
    if lv_cm_fold_tail_by_masking(cm) {
        if lv_cm_fold_tail_with_evl(cm) max_factors.fixed = ec_fixed(1);
        else lv_cm_try_to_enable_partial_alias_masking(cm);
        return max_factors;
    }
    if cm.sel == .NOT_NEEDED_FOLD_TAIL { cm.sel = .ALLOWED; return max_factors; }
    if cm.sel == .NOT_ALLOWED_FOLD_TAIL return vfp_none();
    if tc.n == 0 return vfp_none();
    return vfp_none();
}

// getEpilogueLowering
lv_get_epilogue_lowering :: (f: Value_Id, hints: *Lv_Hints, opt_for_size: bool) -> Epilogue_Lowering {
    if fn_has_opt_size(f) || (opt_for_size && lvh_force(hints) != FK_ENABLED) return .NOT_ALLOWED_OPT_SIZE;
    if lv_opts.tail_folding_policy.set {
        if lv_opts.tail_folding_policy.v == 0 return .ALLOWED;
        if lv_opts.tail_folding_policy.v == 1 return .NOT_NEEDED_FOLD_TAIL;
        return .NOT_ALLOWED_FOLD_TAIL;
    }
    if hints.predicate == FK_ENABLED return .NOT_NEEDED_FOLD_TAIL;
    if hints.predicate == FK_DISABLED return .ALLOWED;
    // TTI.preferTailFoldingOverEpilogue is false for X86 and NoTTI
    return .ALLOWED;
}


// ---------------------------------------------------------------- the pass

Lv_Pass :: struct {
    f: Value_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    db: *Demanded_Bits;
    tti: *Tti;
    tli: *Tli;
    interleave_only_when_forced: bool;
    vectorize_only_when_forced: bool;
}

// isExplicitVecOuterLoop
lv_is_explicit_vec_outer_loop :: (p: *Lv_Pass, l: Loop_Id) -> bool {
    h: Lv_Hints;
    lvh_init(*h, p.li, l, true, false);
    if lvh_force(*h) == FK_UNDEFINED return false;
    if !lvh_allow_vectorization(*h, true) return false;
    if lvh_interleave(*h) > 1 return false;
    return true;
}

// collectSupportedLoops
lv_collect_supported_loops :: (p: *Lv_Pass, l: Loop_Id, out: *[..] Loop_Id) {
    if li_is_innermost(p.li, l) || lv_opts.vplan_build_outerloop_stress_test || (lv_opts.enable_vplan_native_path && lv_is_explicit_vec_outer_loop(p, l)) {
        rpo: [..] Value_Id; rpo.allocator = temp;
        loop_blocks_rpo(p.li, l, *rpo);
        if !contains_irreducible_cfg_rpo(p.li, rpo) {
            array_add(out, l);
            return;
        }
    }
    for li_subloops(p.li, l) lv_collect_supported_loops(p, it, out);
}

lv_unported :: (what: string) { fatal("loop-vectorize: % is not supported yet", what); }

// LoopVectorizePass::processLoop
lv_process_loop :: (p: *Lv_Pass, l: Loop_Id) -> bool {
    hints: Lv_Hints;
    lvh_init(*hints, p.li, l, p.interleave_only_when_forced, true);
    f := p.f;
    if !lvh_allow_vectorization(*hints, p.vectorize_only_when_forced) return false;
    pse: Pse;
    pse_init(*pse, l);
    opt_for_size := fn_has_opt_size(f);
    lvl: Lvl;
    lvl_init(*lvl);
    lvl.f = f; lvl.l = l; lvl.li = p.li; lvl.dt = p.dt; lvl.pse = *pse; lvl.tti = p.tti; lvl.tli = p.tli; lvl.ac = p.ac;
    lvl.db = p.db; lvl.hints = *hints; lvl.allow_runtime_scev_checks = !opt_for_size;
    if !lvl_can_vectorize(*lvl, lv_opts.enable_vplan_native_path) return false;
    is_inner := li_is_innermost(p.li, l);
    if !is_inner lv_unported("outer-loop vectorization");
    if lvl_has_uncountable_early_exit(*lvl) {
        if !lv_opts.enable_early_exit return false;
        if lvl_has_uncountable_exit_with_side_effects(*lvl) && !lv_opts.enable_early_exit_with_side_effects return false;
    }
    use_interleaved := is_inner && lv_tti_enable_interleaved_access_vectorization(p.tti);
    if lv_opts.enable_interleaved_mem_accesses.set use_interleaved = is_inner && lv_opts.enable_interleaved_mem_accesses.v != 0;
    if use_interleaved lv_unported("interleaved access analysis (InterleavedAccessInfo)");
    cm: Lv_Cm;
    cm.f = f; cm.l = l; cm.li = p.li; cm.pse = *pse; cm.tti = p.tti; cm.lvl = *lvl; cm.hints = *hints; cm.ac = p.ac;
    cm.opt_for_size = opt_for_size;
    cm.values_to_ignore = iset_new(); cm.vec_values_to_ignore = iset_new(); cm.element_types.allocator = temp;
    cm.per_vf.allocator = temp; cm.decisions.allocator = temp;
    cm.sel = lv_get_epilogue_lowering(f, *hints, opt_for_size);
    known, etc := lv_small_best_known_tc(*cm, l);
    if known && !etc.scalable && etc.n < cast(u64) lv_opts.tiny_trip_count_threshold {
        if lvh_force(*hints) != FK_ENABLED && cm.sel != .NOT_NEEDED_FOLD_TAIL cm.sel = .NOT_ALLOWED_LOW_TRIP_LOOP;
    }
    if fn_has_fn_attr(f, .NoImplicitFloat) return false;
    // TTI.isFPVectorizationPotentiallyUnsafe() is false for X86 and NoTTI
    allow_ordered := ifx lv_opts.force_ordered_reductions.set then lv_opts.force_ordered_reductions.v != 0 else false;
    if !lvl_can_vectorize_fp_math(*lvl, allow_ordered) return false;
    // getEpilogueTailLowering only produces a remark here
    user_vf := Ec.{lvh_width(*hints), lvh_width_scalable(*hints)};
    user_ic := lvh_interleave(*hints);
    if user_ic > 1 && !lvl_is_safe_for_any_vector_width(*lvl) user_ic = 1;

    // LoopVectorizationPlanner::plan
    lv_cm_collect_values_to_ignore(*cm);
    lv_collect_element_types_for_widening(*cm);
    max_factors := lv_cm_compute_max_vf(*cm, user_vf, user_ic);
    if !vfp_ok(max_factors) {
        // no VPlan: computeBestVF gives VF 1 without a plan, so neither vectorization nor interleaving happens
        return false;
    }
    if max_factors.scalable.n lv_unported("scalable vectorization");
    max_user_vf := ifx user_vf.scalable then max_factors.scalable else max_factors.fixed;
    if (user_vf.n && ec_known_le(user_vf, max_user_vf) && !ec_is_scalar(user_vf)) || ec_is_vector(max_factors.fixed) {
        lp: Lv_Planner;
        lp.p = p; lp.l = l; lp.li = p.li; lp.lvl = *lvl; lp.cm = *cm; lp.hints = *hints; lp.pse = *pse;
        lp.vplans.allocator = temp; lp.in_loop_reductions.allocator = temp;
        lvp_collect_in_loop_reductions(*lp);
        return lvp_plan_and_vectorize(*lp, user_vf, user_ic, max_factors);
    }
    // Only VF 1 is a candidate. LLVM builds a scalar VPlan; computeBestVF returns VF 1 without costing, and
    // selectInterleaveCount clamps the interleave count by TTI.getMaxInterleaveFactor(VF=1), which is 1 for X86 and
    // NoTTI. So the loop is neither vectorized nor interleaved unless the user asked for an interleave count.
    if user_ic > 1 lv_unported("interleaving with a user-specified interleave count (VPlan)");
    if lv_opts.force_target_max_scalar_interleave.set && lv_opts.force_target_max_scalar_interleave.v > 1
        lv_unported("-force-target-max-scalar-interleave (VPlan interleave-count selection)");
    if lv_tti_max_interleave_factor(p.tti, ec_fixed(1), false) > 1 lv_unported("scalar interleaving (VPlan)");
    return false;
}

// LoopVectorizePass::run + runImpl
loop_vectorize_run :: (f: Value_Id, name: string) -> Preserved {
    p: Lv_Pass;
    p.f = f;
    lv_parse_pass_params(*p, name);
    p.interleave_only_when_forced |= !lv_opts.interleave_loops;
    p.vectorize_only_when_forced |= !lv_opts.vectorize_loops;
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    s := get_scev(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    p.li = li;
    p.tti = tti_get(f);
    p.dt = get_domtree(f);
    p.tli = tli_for(f);
    p.ac = get_assumption_cache(f);
    p.db = get_demanded_bits(f);
    vclass := tti_register_class_for_type(p.tti, true);
    if tti_number_of_registers(p.tti, vclass) == 0 &&
       (lv_tti_max_interleave_factor(p.tti, ec_fixed(1), false) < 2 || lv_tti_max_interleave_factor(p.tti, ec_fixed(1), true) < 2)
        return PRESERVE_ALL;
    changed := false; cfg_changed := false;
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    for tops {
        c := simplify_loop(li, it, p.dt, p.ac, null, false);
        changed |= c; cfg_changed |= c;
    }
    worklist: [..] Loop_Id; worklist.allocator = temp;
    for li.top_level lv_collect_supported_loops(*p, it, *worklist);
    while worklist.count {
        l := pop(*worklist);
        changed |= form_lcssa_recursively(li, l, p.dt);
        c := lv_process_loop(*p, l);
        changed |= c; cfg_changed |= c;
    }
    if !changed return PRESERVE_ALL;
    if assignment_tracking_enabled() for b: fn_blocks(f) remove_redundant_dbg_instrs(b);
    pa: Preserved;
    preserve(*pa, .LOOPS);
    preserve(*pa, .DOMTREE);
    preserve(*pa, .SCEV);
    if !cfg_changed pa.cfg = true;
    return pa;
}

// loop-vectorize<[no-]interleave-forced-only;[no-]vectorize-forced-only>
lv_parse_pass_params :: (p: *Lv_Pass, name: string) {
    lt := find_index_from_left(name, #char "<");
    if lt < 0 return;
    params := slice(name, lt + 1, name.count - lt - 2);
    for part: split(params, ";") {
        if part == "" continue;
        if part == "interleave-forced-only" p.interleave_only_when_forced = true;
        else if part == "no-interleave-forced-only" p.interleave_only_when_forced = false;
        else if part == "vectorize-forced-only" p.vectorize_only_when_forced = true;
        else if part == "no-vectorize-forced-only" p.vectorize_only_when_forced = false;
        else fatal("invalid LoopVectorize parameter '%'", part);
    }
}
