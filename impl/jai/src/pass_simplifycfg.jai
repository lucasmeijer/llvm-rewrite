// SimplifyCFG: port of llvm/lib/Transforms/Utils/SimplifyCFG.cpp (SimplifyCFGOpt and its static helpers) and
// llvm/lib/Transforms/Scalar/SimplifyCFGPass.cpp (the pass, its options, removeUnreachableBlocks /
// tailMergeBlocksWithSimilarFunctionTerminators / iterativelySimplifyCFG).
// The Local.cpp helpers are in local_utils.jai, branch weights / switch API / DomTreeUpdater / DeleteDeadBlock in
// scfg_util.jai, switch-specific transforms in pass_simplifycfg_switch.jai, the cost model in tti.jai.
// What isn't ported fails loudly at the point where LLVM would transform (scfg_np).
//
// SimplifyCFGOpt's state (TTI, DTU, options, LoopHeaders, Resimplify) is a `Scfg` passed by pointer.

scfg_np :: (what: string) { fatal("simplifycfg: % is not supported yet", what); }

// ---------------------------------------------------------------- cl::opts (SimplifyCFG.cpp, SimplifyCFGPass.cpp)

opt_strip_debug := false;

scfg_cl: struct {
    require_and_preserve_domtree := false;     // -simplifycfg-require-and-preserve-domtree
    phi_node_folding_threshold: s64 = 2;       // -phi-node-folding-threshold
    two_entry_phi_node_folding_threshold: s64 = 4;
    hoist_common := true;                      // -simplifycfg-hoist-common
    hoist_loads_with_cond_faulting := true;
    hoist_stores_with_cond_faulting := true;
    hoist_loads_stores_with_cond_faulting_threshold: s64 = 6;
    hoist_common_skip_limit: s64 = 20;
    sink_common := true;                       // -simplifycfg-sink-common
    hoist_cond_stores := true;
    merge_cond_stores := true;
    merge_cond_stores_aggressively := false;
    speculate_one_expensive_inst := true;
    max_speculation_depth: s64 = 10;
    max_small_block_size: s64 = 10;
    branch_fold_threshold: s64 = 2;
    branch_fold_to_common_dest_vector_multiplier: s64 = 2;
    enable_merge_compatible_invokes := true;
    max_switch_cases_per_result: s64 = 16;
    max_jump_threading_live_blocks: s64 = 24;
    // SimplifyCFGPass.cpp user overrides: -1 = not given
    user_bonus_inst_threshold: s64 = -1;
    user_keep_loops: s64 = -1;
    user_switch_range_to_icmp: s64 = -1;
    user_switch_to_lookup: s64 = -1;
    user_forward_switch_cond: s64 = -1;
    user_hoist_common_insts: s64 = -1;
    user_hoist_loads_stores_with_cond_faulting: s64 = -1;
    user_sink_common_insts: s64 = -1;
    user_speculate_unpredictables: s64 = -1;
};

SCFG_CL_OPT_COUNT :: 31;
add_scfg_cl_opts :: (list: [] Cl_Opt, start: s64) {
    o := *scfg_cl;
    k := start;
    add :: (list: [] Cl_Opt, k: *s64, name: string, b: *bool, i: *s64) { list[k.*] = .{name, ifx b then Cl_Kind.BOOL else .INT, b, i, null}; k.* += 1; }
    add(list, *k, "simplifycfg-require-and-preserve-domtree", *o.require_and_preserve_domtree, null);
    add(list, *k, "phi-node-folding-threshold", null, *o.phi_node_folding_threshold);
    add(list, *k, "two-entry-phi-node-folding-threshold", null, *o.two_entry_phi_node_folding_threshold);
    add(list, *k, "simplifycfg-hoist-common", *o.hoist_common, null);
    add(list, *k, "simplifycfg-hoist-loads-with-cond-faulting", *o.hoist_loads_with_cond_faulting, null);
    add(list, *k, "simplifycfg-hoist-stores-with-cond-faulting", *o.hoist_stores_with_cond_faulting, null);
    add(list, *k, "hoist-loads-stores-with-cond-faulting-threshold", null, *o.hoist_loads_stores_with_cond_faulting_threshold);
    add(list, *k, "simplifycfg-hoist-common-skip-limit", null, *o.hoist_common_skip_limit);
    add(list, *k, "simplifycfg-sink-common", *o.sink_common, null);
    add(list, *k, "simplifycfg-hoist-cond-stores", *o.hoist_cond_stores, null);
    add(list, *k, "simplifycfg-merge-cond-stores", *o.merge_cond_stores, null);
    add(list, *k, "simplifycfg-merge-cond-stores-aggressively", *o.merge_cond_stores_aggressively, null);
    add(list, *k, "speculate-one-expensive-inst", *o.speculate_one_expensive_inst, null);
    add(list, *k, "max-speculation-depth", null, *o.max_speculation_depth);
    add(list, *k, "simplifycfg-max-small-block-size", null, *o.max_small_block_size);
    add(list, *k, "simplifycfg-branch-fold-threshold", null, *o.branch_fold_threshold);
    add(list, *k, "simplifycfg-branch-fold-common-dest-vector-multiplier", null, *o.branch_fold_to_common_dest_vector_multiplier);
    add(list, *k, "simplifycfg-merge-compatible-invokes", *o.enable_merge_compatible_invokes, null);
    add(list, *k, "max-switch-cases-per-result", null, *o.max_switch_cases_per_result);
    add(list, *k, "max-jump-threading-live-blocks", null, *o.max_jump_threading_live_blocks);
    add(list, *k, "max-phi-entries-increase-after-removing-empty-block", null, *local_opts.max_phi_entries_increase_after_removing_empty_block);
    add(list, *k, "strip-debug", *opt_strip_debug, null);   // opt -strip-debug (optdriver.cpp)
    // tri-state user overrides: parsed as INT with "true"/"false" accepted (see parse_cl_opt's TRISTATE kind)
    tri :: (list: [] Cl_Opt, k: *s64, name: string, i: *s64) { list[k.*] = .{name, .TRISTATE, null, i, null}; k.* += 1; }
    list[k] = .{"bonus-inst-threshold", .INT, null, *o.user_bonus_inst_threshold, null}; k += 1;
    tri(list, *k, "keep-loops", *o.user_keep_loops);
    tri(list, *k, "switch-range-to-icmp", *o.user_switch_range_to_icmp);
    tri(list, *k, "switch-to-lookup", *o.user_switch_to_lookup);
    tri(list, *k, "forward-switch-cond", *o.user_forward_switch_cond);
    tri(list, *k, "hoist-common-insts", *o.user_hoist_common_insts);
    tri(list, *k, "hoist-loads-stores-with-cond-faulting", *o.user_hoist_loads_stores_with_cond_faulting);
    tri(list, *k, "sink-common-insts", *o.user_sink_common_insts);
    tri(list, *k, "speculate-unpredictables", *o.user_speculate_unpredictables);
    assert(k == start + SCFG_CL_OPT_COUNT);
}

// SimplifyCFGOptions
Scfg_Options :: struct {
    bonus_inst_threshold: s64 = 1;
    forward_switch_cond_to_phi := false;
    convert_switch_range_to_icmp := false;
    convert_switch_to_arithmetic := false;
    convert_switch_to_lookup_table := false;
    need_canonical_loop := true;
    hoist_common_insts := false;
    hoist_loads_stores_with_cond_faulting := false;
    sink_common_insts := false;
    simplify_cond_branch := true;
    speculate_blocks := true;
    speculate_unpredictables := false;
    ac: *Assumption_Cache;
}

// parseSimplifyCFGOptions (PassBuilder.cpp) on the text between '<' and '>'
scfg_parse_options :: (params: string) -> Scfg_Options {
    r: Scfg_Options;
    p := params;
    while p.count {
        name := p;
        semi := find_index_from_left(p, #char ";");
        if semi >= 0 { name = slice(p, 0, semi); p = slice(p, semi + 1, p.count - semi - 1); } else p = "";
        enable := true;
        if begins_with(name, "no-") { enable = false; name = slice(name, 3, name.count - 3); }
        if name == "speculate-blocks" r.speculate_blocks = enable;
        else if name == "simplify-cond-branch" r.simplify_cond_branch = enable;
        else if name == "forward-switch-cond" r.forward_switch_cond_to_phi = enable;
        else if name == "switch-range-to-icmp" r.convert_switch_range_to_icmp = enable;
        else if name == "switch-to-arithmetic" r.convert_switch_to_arithmetic = enable;
        else if name == "switch-to-lookup" r.convert_switch_to_lookup_table = enable;
        else if name == "keep-loops" r.need_canonical_loop = enable;
        else if name == "hoist-common-insts" r.hoist_common_insts = enable;
        else if name == "hoist-loads-stores-with-cond-faulting" r.hoist_loads_stores_with_cond_faulting = enable;
        else if name == "sink-common-insts" r.sink_common_insts = enable;
        else if name == "speculate-unpredictables" r.speculate_unpredictables = enable;
        else if enable && begins_with(name, "bonus-inst-threshold=") {
            v, ok := string_to_int(slice(name, 21, name.count - 21));
            if !ok fatal("invalid argument to SimplifyCFG pass bonus-threshold parameter: '%'", slice(name, 21, name.count - 21));
            r.bonus_inst_threshold = v;
        } else fatal("invalid SimplifyCFG pass parameter '%'", name);
    }
    return r;
}
// applyCommandLineOverridesToOptions
scfg_apply_cl_overrides :: (o: *Scfg_Options) {
    c := *scfg_cl;
    if c.user_bonus_inst_threshold >= 0 o.bonus_inst_threshold = c.user_bonus_inst_threshold;
    if c.user_forward_switch_cond >= 0 o.forward_switch_cond_to_phi = c.user_forward_switch_cond != 0;
    if c.user_switch_range_to_icmp >= 0 o.convert_switch_range_to_icmp = c.user_switch_range_to_icmp != 0;
    if c.user_switch_to_lookup >= 0 o.convert_switch_to_lookup_table = c.user_switch_to_lookup != 0;
    if c.user_keep_loops >= 0 o.need_canonical_loop = c.user_keep_loops != 0;
    if c.user_hoist_common_insts >= 0 o.hoist_common_insts = c.user_hoist_common_insts != 0;
    if c.user_hoist_loads_stores_with_cond_faulting >= 0 o.hoist_loads_stores_with_cond_faulting = c.user_hoist_loads_stores_with_cond_faulting != 0;
    if c.user_sink_common_insts >= 0 o.sink_common_insts = c.user_sink_common_insts != 0;
    if c.user_speculate_unpredictables >= 0 o.speculate_unpredictables = c.user_speculate_unpredictables != 0;
}

Scfg :: struct {
    tti: *Tti;
    dtu: *Dtu;              // null without -simplifycfg-require-and-preserve-domtree
    opts: *Scfg_Options;
    loop_headers: [] Value_Id;
    resimplify: bool;
}
request_resimplify :: (s: *Scfg) -> bool { s.resimplify = true; return true; }
is_loop_header :: (s: *Scfg, b: Value_Id) -> bool { for s.loop_headers if it == b return true; return false; }

// ---------------------------------------------------------------- BranchProbability

BP_D :: cast(u64) 1 << 31;
BP_UNKNOWN :: 0xFFFF_FFFF;
// BranchProbability(N, D)
bp_make :: (n: u64, d: u64) -> u32 {
    if d == BP_D return cast(u32) n;
    return cast(u32) ((n * BP_D + d / 2) / d);
}
// BranchProbability::getBranchProbability(uint64_t N, uint64_t D)
bp_get :: (n0: u64, d0: u64) -> u32 {
    n := n0; d := d0;
    scale := 0;
    while d > 0xFFFF_FFFF { d >>= 1; scale += 1; }
    return bp_make(n >> cast(u64) scale, d);
}
bp_compl :: (p: u32) -> u32 { return cast(u32) BP_D - p; }
tti_likely :: (s: *Scfg) -> u32 { return bp_make(cast(u64) tti_predictable_branch_threshold(s.tti), 100); }

// ---------------------------------------------------------------- small helpers

is_const_int_value :: (v: Value_Id) -> bool { return is_const_int(v) && !is_vector_type(vtype(v)); }
block_unique_successor_of :: (b: Value_Id) -> Value_Id {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    if succs.count == 0 return NONE;
    for succs if it != succs[0] return NONE;
    return succs[0];
}
block_single_successor_of :: (b: Value_Id) -> Value_Id {
    t := block_terminator(b);
    if t == NONE || num_successors(t) != 1 return NONE;
    return get_successor(t, 0);
}
unique_successors :: (b: Value_Id) -> [..] Value_Id {
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(b, *succs);
    u: [..] Value_Id; u.allocator = temp;
    for succs if !block_set_contains(u, it) array_add(*u, it);
    return u;
}
is_pseudo_probe :: (i: Value_Id) -> bool { return call_iid(i) == IID_PSEUDOPROBE; }
// CallBase::cannotMerge / cannotDuplicate / isConvergent
call_cannot_merge :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .NoMerge); }
call_cannot_duplicate :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .NoDuplicate); }
call_is_convergent :: (i: Value_Id) -> bool { return call_has_fn_attr(i, .Convergent); }
fn_has_min_size :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .MinSize); }
fn_has_opt_size :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .OptimizeForSize) || fn_has_min_size(f); }

// addPredecessorToBlock
add_predecessor_to_block :: (succ: Value_Id, new_pred: Value_Id, exist_pred: Value_Id) {
    for pn: block_insts(succ) {
        if inst_op(pn) != .PHI break;
        phi_add_incoming(pn, phi_incoming_value_for_block(pn, exist_pred), new_pred);
    }
}
// incomingValuesAreCompatible(BB, {A, B}, EquivalenceSet)
incoming_values_are_compatible :: (bb: Value_Id, a: Value_Id, b: Value_Id, equiv: [] Value_Id = .[]) -> bool {
    for pn: block_insts(bb) {
        if inst_op(pn) != .PHI break;
        v0 := phi_incoming_value_for_block(pn, a);
        v1 := phi_incoming_value_for_block(pn, b);
        if v0 == v1 continue;
        if equiv.count && block_set_contains(equiv, v0) && block_set_contains(equiv, v1) continue;
        return false;
    }
    return true;
}
// safeToMergeTerminators(SI1, SI2, FailBlocks)
scfg_safe_to_merge_terminators :: (si1: Value_Id, si2: Value_Id, fail_blocks: *[..] Value_Id = null) -> bool {
    if si1 == si2 return false;
    b1 := inst_block(si1); b2 := inst_block(si2);
    s1 := unique_successors(b1);
    succs2: [..] Value_Id; succs2.allocator = temp;
    block_successors(b2, *succs2);
    fail := false;
    for s: succs2 {
        if !block_set_contains(s1, s) continue;
        if incoming_values_are_compatible(s, b1, b2) continue;
        fail = true;
        if fail_blocks { if !block_set_contains(fail_blocks.*, s) array_add(fail_blocks, s); }
        else break;
    }
    return !fail;
}

// computeSpeculationCost
compute_speculation_cost :: (s: *Scfg, i: Value_Id) -> Cost { return tti_instruction_cost(s.tti, i, TCK_SIZE_AND_LATENCY); }

// isSafeToSpeculativelyExecute(I, CtxI, AC) (ValueTracking.cpp), with the load case
is_safe_to_speculatively_execute_cx :: (i: Value_Id, ctx: Value_Id, ac: *Assumption_Cache) -> bool {
    if inst_op(i) == .LOAD {
        if !is_unordered(i) return false;   // mustSuppressSpeculation
        fa := attr_list_fn(glob(inst_fn(i)).attrs);
        if attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;
        q: Simplify_Query; q.ac = ac; q.cxt = ctx; q.have_tli = false;
        return is_dereferenceable_and_aligned_pointer_ty(op(i, 0), vtype(i), inst(i).align, q);
    }
    return is_safe_to_speculatively_execute(i);
}

// dominatesMergePoint
dominates_merge_point :: (s: *Scfg, v: Value_Id, bb: Value_Id, insert_pt: Value_Id, aggressive: *[..] Value_Id, cost: *Cost,
                          budget: Cost, zero_cost: *[..] Value_Id, depth: s64 = 0) -> bool {
    if depth == scfg_cl.max_speculation_depth return false;
    if !is_inst(v) return true;
    i := v;
    pbb := inst_block(i);
    if pbb == bb return false;
    bi := block_terminator(pbb);
    if inst_op(bi) != .BR || get_successor(bi, 0) != bb return true;
    if block_set_contains(aggressive.*, i) return true;
    if !is_safe_to_speculatively_execute_cx(i, insert_pt, s.opts.ac) return false;
    // m_ExtractValue<1>(m_OneUse(m_WithOverflowInst(OverflowInst)))
    ov: Value_Id = NONE;
    if inst_op(i) == .EXTRACTVALUE && inst(i).nidx == 1 && ir.u32_pool[inst(i).idx] == 1 {
        a := op(i, 0);
        if is_with_overflow_inst(a) && num_uses(a) == 1 ov = a;
    }
    if ov != NONE {
        if !block_set_contains(zero_cost.*, ov) array_add(zero_cost, ov);
        cost.* = cost_add(cost.*, 1);
    } else if !block_set_contains(zero_cost.*, i) cost.* = cost_add(cost.*, compute_speculation_cost(s, i));
    if cost.* > budget && (!scfg_cl.speculate_one_expensive_inst || aggressive.count != 0 || depth > 0 || !cost_valid(cost.*))
        return false;
    for k: 0..cast(s64) nops(i) - 1
        if !dominates_merge_point(s, op(i, cast(u32) k), bb, insert_pt, aggressive, cost, budget, zero_cost, depth + 1) return false;
    array_add(aggressive, i);
    return true;
}

// getConstantInt(V, DL): a ConstantInt, or a pointer constant seen as a pointer-sized integer
scfg_get_constant_int :: (v: Value_Id) -> Value_Id {
    if is_const_int(v) return v;
    if !is_constant_kind(vkind(v)) || type_kind(vtype(v)) != .PTR return NONE;
    if dl_unstable_repr(vtype(v)) return NONE;
    ip := dl_int_ptr_type(vtype(v));
    if vkind(v) == .C_NULL return const_int(ip, 0);
    if vkind(v) == .C_EXPR && cexpr(v).op == .INTTOPTR {
        c := op(v, 0);
        if is_const_int(c) {
            if vtype(c) == ip return c;
            // ConstantFoldIntegerCast(CI, IntPtrTy, /*isSigned=*/false)
            return cfo_integer_cast(c, ip, false);
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- ConstantComparesGatherer

Ccg :: struct {
    comp_value: Value_Id = NONE;
    extra: Value_Id = NONE;
    vals: [..] Value_Id;
    used_icmps: s64;
    is_eq: bool;
    ignore_first_match: bool;
    multiple_matches: bool;
}
ccg_set_value_once :: (g: *Ccg, v: Value_Id) -> bool {
    if g.ignore_first_match { g.ignore_first_match = false; return false; }
    if g.comp_value != NONE && g.comp_value != v { g.multiple_matches = true; return false; }
    g.comp_value = v;
    return true;
}
ccg_match_instruction :: (g: *Ccg, i_in: Value_Id, is_eq_in: bool) -> bool {
    i := i_in;
    is_eq := is_eq_in;
    // m_Not(m_Instruction(I))
    if inst_op(i) == .XOR && is_inst(op(i, 0)) && pm_all_ones(op(i, 1)) { i = op(i, 0); is_eq = !is_eq; }
    if inst_op(i) == .TRUNC && (inst(i).flags & F_NUW) != 0 {
        v := op(i, 0);
        if !ccg_set_value_once(g, v) return false;
        g.used_icmps += 1;
        array_add(*g.vals, const_int(vtype(v), ifx is_eq then cast(u64) 1 else 0));
        return true;
    }
    if inst_op(i) != .ICMP return false;
    c := scfg_get_constant_int(op(i, 1));
    if c == NONE return false;
    pred := inst(i).pred;
    if pred == (ifx is_eq then cast(u8) ICMP_EQ else ICMP_NE) {
        lhs := op(i, 0);
        if is_inst(lhs) && inst_op(lhs) == .AND {
            ok, rhsc := pm_apint(op(lhs, 1));
            if ok {
                mask := ap_not(rhsc);
                cv := cf_ap(c);
                if ap_is_power_of_2(mask) && ap_eq(ap_and(cv, ap_not(mask)), cv) {
                    if !ccg_set_value_once(g, op(lhs, 0)) return false;
                    array_add(*g.vals, c);
                    array_add(*g.vals, const_int_words(vtype(c), ap_words(ap_or(cv, mask))));
                    g.used_icmps += 1;
                    return true;
                }
            }
        }
        if is_inst(lhs) && inst_op(lhs) == .OR {
            ok, rhsc := pm_apint(op(lhs, 1));
            if ok {
                mask := rhsc;
                cv := cf_ap(c);
                if ap_is_power_of_2(mask) && ap_eq(ap_or(cv, mask), cv) {
                    if !ccg_set_value_once(g, op(lhs, 0)) return false;
                    array_add(*g.vals, c);
                    array_add(*g.vals, const_int_words(vtype(c), ap_words(ap_and(cv, ap_not(mask)))));
                    g.used_icmps += 1;
                    return true;
                }
            }
        }
        if !ccg_set_value_once(g, op(i, 0)) return false;
        g.used_icmps += 1;
        array_add(*g.vals, c);
        return true;
    }
    span := cr_exact_icmp_region(pred, cf_ap(c));
    candidate := op(i, 0);
    a := op(i, 0);
    if is_inst(a) && inst_op(a) == .ADD {
        ok, rc := pm_apint(op(a, 1));
        if ok { span = cr_subtract(span, rc); candidate = op(a, 0); }
    }
    if !is_eq span = cr_inverse(span);
    if cr_is_size_larger_than(span, 8) || cr_is_empty_set(span) return false;
    if !ccg_set_value_once(g, candidate) return false;
    tmp := span.lo;
    while true {
        array_add(*g.vals, const_int_words(vtype(c), ap_words(tmp)));
        tmp = ap_add(tmp, ap_from_u64(tmp.bits, 1));
        if ap_eq(tmp, span.hi) break;
    }
    g.used_icmps += 1;
    return true;
}
ccg_gather :: (g: *Ccg, v_in: Value_Id) {
    v := v_in;
    ok_or, o0, o1 := pm_logical_or(v);
    if ok_or g.is_eq = true;
    else {
        ok_and, a0, a1 := pm_logical_and(v);
        if !ok_and return;
        g.is_eq = false; o0 = a0; o1 = a1;
    }
    dft: [..] Value_Id; dft.allocator = temp;
    array_add(*dft, o0); array_add(*dft, o1);
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v); if !block_set_contains(visited, o0) array_add(*visited, o0); if !block_set_contains(visited, o1) array_add(*visited, o1);
    while dft.count {
        v = pop(*dft);
        if is_inst(v) {
            m: bool; p0, p1: Value_Id;
            if g.is_eq { m, p0, p1 = pm_logical_or(v); } else { m, p0, p1 = pm_logical_and(v); }
            if m {
                if !block_set_contains(visited, p1) { array_add(*visited, p1); array_add(*dft, p1); }
                if !block_set_contains(visited, p0) { array_add(*visited, p0); array_add(*dft, p0); }
                continue;
            }
            if ccg_match_instruction(g, v, g.is_eq) continue;
        }
        if g.extra == NONE { g.extra = v; continue; }
        g.comp_value = NONE;
        break;
    }
}
ccg_init :: (g: *Ccg, cond: Value_Id) {
    g.vals.allocator = temp;
    ccg_gather(g, cond);
    if g.comp_value != NONE || !g.multiple_matches return;
    g.extra = NONE;
    g.vals.count = 0;
    g.used_icmps = 0;
    g.ignore_first_match = true;
    ccg_gather(g, cond);
}

// eraseTerminatorAndDCECond
erase_terminator_and_dce_cond :: (ti: Value_Id) {
    c: Value_Id = NONE;
    o := inst_op(ti);
    if o == .SWITCH || o == .CONDBR || o == .INDIRECTBR c = op(ti, 0);
    erase_terminator(ti);
    if is_inst(c) recursively_delete_trivially_dead_value(c);
}

// ---------------------------------------------------------------- value equality comparisons

Vecc :: struct { value: Value_Id; dest: Value_Id; }   // ValueEqualityComparisonCase

// isValueEqualityComparison
is_value_equality_comparison :: (ti: Value_Id) -> Value_Id {
    cv: Value_Id = NONE;
    if inst_op(ti) == .SWITCH {
        if !block_has_n_predecessors_or_more(inst_block(ti), 128 / cast(s64) num_successors(ti)) cv = sw_cond(ti);
    } else if inst_op(ti) == .CONDBR {
        c := op(ti, 0);
        if is_inst(c) && num_uses(c) == 1 {
            if inst_op(c) == .ICMP {
                if is_equality_pred(inst(c).pred) && scfg_get_constant_int(op(c, 1)) != NONE cv = op(c, 0);
            } else if inst_op(c) == .TRUNC {
                if inst(c).flags & F_NUW cv = op(c, 0);
            }
        }
    }
    if cv != NONE && is_inst(cv) && inst_op(cv) == .PTRTOINT {
        p := op(cv, 0);
        if dl_unstable_repr(vtype(p)) return cv;
        if vtype(cv) == dl_int_ptr_type(vtype(p)) cv = p;
    }
    return cv;
}
// getValueEqualityComparisonCases: the default destination
get_value_equality_comparison_cases :: (ti: Value_Id, cases: *[..] Vecc) -> Value_Id {
    if inst_op(ti) == .SWITCH {
        for k: 0..cast(s64) sw_num_cases(ti) - 1 array_add(cases, .{sw_case_value(ti, cast(u32) k), sw_case_dest(ti, cast(u32) k)});
        return sw_default(ti);
    }
    c := op(ti, 0);
    pred: u8;
    cv: Value_Id;
    if inst_op(c) == .ICMP { pred = inst(c).pred; cv = scfg_get_constant_int(op(c, 1)); }
    else { pred = ICMP_NE; cv = const_int(vtype(op(c, 0)), 0); }
    succ := get_successor(ti, ifx pred == ICMP_NE then cast(u32) 1 else 0);
    array_add(cases, .{cv, succ});
    return get_successor(ti, ifx pred == ICMP_EQ then cast(u32) 1 else 0);
}
eliminate_block_cases :: (bb: Value_Id, cases: *[..] Vecc) {
    k := 0;
    while k < cases.count { if cases.*[k].dest == bb array_ordered_remove_by_index(cases, k); else k += 1; }
}
values_overlap :: (c1: [] Vecc, c2: [] Vecc) -> bool {
    for a: c1 for b: c2 if a.value == b.value return true;
    return false;
}

// simplifyEqualityComparisonWithOnlyPredecessor
simplify_equality_comparison_with_only_predecessor :: (s: *Scfg, ti: Value_Id, pred: Value_Id, b: *Irb) -> bool {
    pred_val := is_value_equality_comparison(block_terminator(pred));
    if pred_val == NONE return false;
    this_val := is_value_equality_comparison(ti);
    if this_val != pred_val return false;
    pred_cases: [..] Vecc; pred_cases.allocator = temp;
    pred_def := get_value_equality_comparison_cases(block_terminator(pred), *pred_cases);
    eliminate_block_cases(pred_def, *pred_cases);
    this_cases: [..] Vecc; this_cases.allocator = temp;
    this_def := get_value_equality_comparison_cases(ti, *this_cases);
    eliminate_block_cases(this_def, *this_cases);
    if pred_def == inst_block(ti) {
        if !values_overlap(pred_cases, this_cases) return false;
        if inst_op(ti) == .CONDBR {
            irb_br(b, this_def);
            block_remove_predecessor(this_cases[0].dest, pred_def);
            dest := this_cases[0].dest;
            erase_terminator_and_dce_cond(ti);
            dtu_apply1(s.dtu, false, pred_def, dest);
            return true;
        }
        p: Sw_Prof;
        sw_prof_init(*p, ti);
        dead: [..] Value_Id; dead.allocator = temp;
        for pred_cases if !block_set_contains(dead, it.value) array_add(*dead, it.value);
        per_succ_keys: [..] Value_Id; per_succ_keys.allocator = temp;
        per_succ_cnt: [..] s64; per_succ_cnt.allocator = temp;
        k := cast(s64) sw_num_cases(ti);
        while k > 0 {
            k -= 1;
            succ := sw_case_dest(ti, cast(u32) k);
            idx := -1;
            if s.dtu {
                for per_succ_keys if it == succ idx = it_index;
                if idx < 0 { array_add(*per_succ_keys, succ); array_add(*per_succ_cnt, 0); idx = per_succ_keys.count - 1; }
                per_succ_cnt[idx] += 1;
            }
            if block_set_contains(dead, sw_case_value(ti, cast(u32) k)) {
                block_remove_predecessor(succ, pred_def);
                sw_prof_remove_case(*p, cast(u32) k);
                if s.dtu per_succ_cnt[idx] -= 1;
            }
        }
        sw_prof_done(*p);
        if s.dtu {
            ups: [..] Dom_Update; ups.allocator = temp;
            for per_succ_keys if per_succ_cnt[it_index] == 0 array_add(*ups, .{false, pred_def, it});
            dtu_apply(s.dtu, ups);
        }
        return true;
    }
    tiv: Value_Id = NONE;
    tibb := inst_block(ti);
    for pred_cases if it.dest == tibb {
        if tiv != NONE return false;
        tiv = it.value;
    }
    real_dest: Value_Id = NONE;
    for this_cases if it.value == tiv { real_dest = it.dest; break; }
    if real_dest == NONE real_dest = this_def;
    removed: [..] Value_Id; removed.allocator = temp;
    check := real_dest;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(tibb, *succs);
    for sc: succs {
        if sc != check {
            if sc != real_dest && !block_set_contains(removed, sc) array_add(*removed, sc);
            block_remove_predecessor(sc, tibb);
        } else check = NONE;
    }
    irb_br(b, real_dest);
    erase_terminator_and_dce_cond(ti);
    if s.dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        for removed array_add(*ups, .{false, tibb, it});
        dtu_apply(s.dtu, ups);
    }
    return true;
}

// getBranchWeights (SimplifyCFG's static helper)
scfg_get_branch_weights :: (ti: Value_Id) -> [..] u64 {
    w: [..] u64; w.allocator = temp;
    for prof_weights_of_md(prof_md(ti)) array_add(*w, it);
    if inst_op(ti) == .CONDBR {
        c := op(ti, 0);
        if is_inst(c) && inst_op(c) == .ICMP && inst(c).pred == ICMP_EQ { t := w[0]; w[0] = w[w.count - 1]; w[w.count - 1] = t; }
    }
    return w;
}

// sort ConstantInts by unsigned value (std::set<ConstantInt*, ConstantIntOrdering> iteration order)
sorted_insert_ult :: (set: *[..] Value_Id, c: Value_Id) {
    for set.* if it == c return;
    k := 0;
    while k < set.count && ap_ult(cf_ap(set.*[k]), cf_ap(c)) k += 1;
    array_insert_at(set, c, k);
}
set_remove_value :: (set: *[..] Value_Id, c: Value_Id) {
    for set.* if it == c { array_ordered_remove_by_index(set, it_index); return; }
}

// performValueComparisonIntoPredecessorFolding
perform_value_comparison_into_predecessor_folding :: (s: *Scfg, ti: Value_Id, cv_io: *Value_Id, pti: Value_Id, b: *Irb) -> bool {
    bb := inst_block(ti);
    pred := inst_block(pti);
    updates: [..] Dom_Update; updates.allocator = temp;
    bb_cases: [..] Vecc; bb_cases.allocator = temp;
    bb_default := get_value_equality_comparison_cases(ti, *bb_cases);
    pred_cases: [..] Vecc; pred_cases.allocator = temp;
    pred_default := get_value_equality_comparison_cases(pti, *pred_cases);
    ns_keys: [..] Value_Id; ns_keys.allocator = temp;    // SmallMapVector<BB, int> NewSuccessors
    ns_cnt: [..] s64; ns_cnt.allocator = temp;
    inc_ns :: (k: *[..] Value_Id, c: *[..] s64, b: Value_Id) {
        for k.* if it == b { c.*[it_index] += 1; return; }
        array_add(k, b); array_add(c, 1);
    }
    weights: [..] u64; weights.allocator = temp;
    pred_hw := prof_has_branch_weight_md(pti);
    succ_hw := prof_has_branch_weight_md(ti);
    if pred_hw {
        weights = scfg_get_branch_weights(pti);
        if weights.count != 1 + pred_cases.count { pred_hw = false; succ_hw = false; }
    } else if succ_hw {
        for 0..pred_cases.count array_add(*weights, 1);
    }
    succ_w: [..] u64; succ_w.allocator = temp;
    if succ_hw {
        succ_w = scfg_get_branch_weights(ti);
        if succ_w.count != 1 + bb_cases.count { pred_hw = false; succ_hw = false; }
    } else if pred_hw {
        for 0..bb_cases.count array_add(*succ_w, 1);
    }
    hw := pred_hw || succ_hw;
    if pred_default == bb {
        handled: [..] Value_Id; handled.allocator = temp;
        i := 0; e := pred_cases.count;
        while i != e {
            if pred_cases[i].dest != bb { sorted_insert_ult(*handled, pred_cases[i].value); i += 1; continue; }
            t := pred_cases[i]; pred_cases[i] = pred_cases[pred_cases.count - 1]; pred_cases[pred_cases.count - 1] = t;
            if hw {
                weights[0] += weights[i + 1];
                tw := weights[i + 1]; weights[i + 1] = weights[weights.count - 1]; weights[weights.count - 1] = tw;
                weights.count -= 1;
            }
            pred_cases.count -= 1;
            e -= 1;
        }
        if pred_default != bb_default {
            block_remove_predecessor(pred_default, pred);
            if s.dtu && pred_default != bb array_add(*updates, .{false, pred, pred_default});
            pred_default = bb_default;
            inc_ns(*ns_keys, *ns_cnt, bb_default);
        }
        cases_from_pred := weights.count;
        valid_total: u64 = 0;
        for c, k: bb_cases {
            if !block_set_contains(handled, c.value) && c.dest != bb_default {
                array_add(*pred_cases, c);
                inc_ns(*ns_keys, *ns_cnt, c.dest);
                if hw {
                    array_add(*weights, weights[0] * succ_w[k + 1]);
                    valid_total += succ_w[k + 1];
                }
            }
        }
        if hw {
            valid_total += succ_w[0];
            for k: 1..cases_from_pred - 1 weights[k] *= valid_total;
            weights[0] *= succ_w[0];
        }
    } else {
        handled: [..] Value_Id; handled.allocator = temp;
        wfh_k: [..] Value_Id; wfh_k.allocator = temp;   // std::map<ConstantInt*, uint64_t> WeightsForHandled
        wfh_v: [..] u64; wfh_v.allocator = temp;
        i := 0; e := pred_cases.count;
        while i != e {
            if pred_cases[i].dest != bb { i += 1; continue; }
            sorted_insert_ult(*handled, pred_cases[i].value);
            if hw {
                array_add(*wfh_k, pred_cases[i].value); array_add(*wfh_v, weights[i + 1]);
                tw := weights[i + 1]; weights[i + 1] = weights[weights.count - 1]; weights[weights.count - 1] = tw;
                weights.count -= 1;
            }
            t := pred_cases[i]; pred_cases[i] = pred_cases[pred_cases.count - 1]; pred_cases[pred_cases.count - 1] = t;
            pred_cases.count -= 1;
            e -= 1;
        }
        wfh :: (k: [] Value_Id, v: [] u64, c: Value_Id) -> u64 { for k if it == c return v[it_index]; return 0; }
        for c: bb_cases {
            if block_set_contains(handled, c.value) {
                if hw array_add(*weights, wfh(wfh_k, wfh_v, c.value));
                array_add(*pred_cases, c);
                inc_ns(*ns_keys, *ns_cnt, c.dest);
                set_remove_value(*handled, c.value);
            }
        }
        for h: handled {
            if hw array_add(*weights, wfh(wfh_k, wfh_v, h));
            array_add(*pred_cases, .{h, bb_default});
            inc_ns(*ns_keys, *ns_cnt, bb_default);
        }
    }
    succs_of_pred: [..] Value_Id; succs_of_pred.allocator = temp;
    if s.dtu succs_of_pred = unique_successors(pred);
    for nk, k: ns_keys {
        for 0..ns_cnt[k] - 1 add_predecessor_to_block(nk, pred, bb);
        if s.dtu && !block_set_contains(succs_of_pred, nk) array_add(*updates, .{true, pred, nk});
    }
    irb_set_before(b, pti);
    cv := cv_io.*;
    if type_kind(vtype(cv)) == .PTR {
        cv = irb_cast(b, .PTRTOINT, cv, dl_int_ptr_type(vtype(cv)), "magicptr");
        cv_io.* = cv;
    }
    nsi := create_switch(cv, pred_default, cast(u32) pred_cases.count);
    irb_insert(b, nsi);
    copy_debug_loc_or_clear(nsi, pti);
    for pred_cases sw_add_case(nsi, it.value, it.dest);
    if hw prof_set_fitted_branch_weights(nsi, weights, false, true);
    erase_terminator_and_dce_cond(pti);
    inf: Value_Id = NONE;
    for k: 0..cast(s64) num_successors(nsi) - 1 {
        if get_successor(nsi, cast(u32) k) == bb {
            if inf == NONE {
                inf = create_block(block_fn(bb), "infloop");
                block_append_inst(inf, create_br(inf));
                if s.dtu array_add(*updates, .{true, inf, inf});
            }
            set_successor(nsi, cast(u32) k, inf);
        }
    }
    if s.dtu {
        if inf != NONE array_add(*updates, .{true, pred, inf});
        array_add(*updates, .{false, pred, bb});
        dtu_apply(s.dtu, updates);
    }
    return true;
}

// foldValueComparisonIntoPredecessors
fold_value_comparison_into_predecessors :: (s: *Scfg, ti: Value_Id, b: *Irb) -> bool {
    bb := inst_block(ti);
    cv := is_value_equality_comparison(ti);
    changed := false;
    preds_all: [..] Value_Id; preds_all.allocator = temp;
    block_predecessors(bb, *preds_all);
    preds: [..] Value_Id; preds.allocator = temp;   // SmallSetVector
    for preds_all if !block_set_contains(preds, it) array_add(*preds, it);
    while preds.count {
        pred := pop(*preds);
        pti := block_terminator(pred);
        if pred == bb continue;
        pcv := is_value_equality_comparison(pti);
        if pcv != cv continue;
        fail_blocks: [..] Value_Id; fail_blocks.allocator = temp;
        if !scfg_safe_to_merge_terminators(ti, pti, *fail_blocks) {
            for fb: fail_blocks {
                pa := Value_Id.[inst_block(ti)];
                if scfg_split_block_predecessors(s, fb, pa, ".fold.split") == NONE return false;
            }
        }
        perform_value_comparison_into_predecessor_folding(s, ti, *cv, pti, b);
        changed = true;
    }
    return changed;
}

// SplitBlockPredecessors(BB, Preds, Suffix, DTU)
scfg_split_block_predecessors :: (s: *Scfg, bb: Value_Id, preds: [] Value_Id, suffix: string) -> Value_Id {
    return split_block_predecessors(bb, preds, suffix, ifx s.dtu then s.dtu.dt else null, null, null, false);
}
