// PartialInliner (`partial-inliner`): a port of llvm/lib/Transforms/IPO/PartialInlining.cpp (PartialInlinerImpl:
// run, unswitchFunction, computeOutliningInfo, FunctionCloner with normalizeReturnBlock and
// doSingleRegionFunctionOutlining, tryPartialInline, shouldPartialInline, computeBBInlineCost,
// computeOutliningCosts, getOutliningCallBBRelativeFreq, computeCallsiteToProfCountMap). The outlining is
// code_extractor.jai.
//
// Not ported (fails loudly): the multi-region (cold region) outlining that needs an instrumentation profile
// (computeOutliningColdRegionsInfo / doMultiRegionFunctionOutlining), forwarding varargs to the outlined function
// when inlining a vararg function (InlineFunction's ForwardVarArgsTo), functions referenced by a blockaddress.
// Optimization remarks are not emitted.

pi_cl: struct {
    disable := false;                    // -disable-partial-inlining
    disable_multi_region := false;       // -disable-mr-partial-inlining
    force_live_exit := false;            // -pi-force-live-exit-outline
    mark_cold_cc := false;               // -pi-mark-coldcc
    skip_cost_analysis := false;         // -skip-partial-inlining-cost-analysis
    max_num_inline_blocks: u32 = 5;      // -max-num-inline-blocks
    max_partial_inlining: s64 = -1;      // -max-partial-inlining
    outline_region_freq_percent: s64 = 75;   // -outline-region-freq-percent
    extra_penalty: s64 = 0;              // -partial-inlining-extra-penalty
};
pi_num_partial_inlining: s64;
pi_debug := false;

partial_inliner_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    parse_int :: (name: string, value: string) -> s64 {
        v, ok := string_to_int(value);
        if !ok fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == "disable-partial-inlining" { pi_cl.disable = parse_bool(name, value, has_value); return true; }
    if name == "disable-mr-partial-inlining" { pi_cl.disable_multi_region = parse_bool(name, value, has_value); return true; }
    if name == "pi-force-live-exit-outline" { pi_cl.force_live_exit = parse_bool(name, value, has_value); return true; }
    if name == "pi-mark-coldcc" { pi_cl.mark_cold_cc = parse_bool(name, value, has_value); return true; }
    if name == "skip-partial-inlining-cost-analysis" { pi_cl.skip_cost_analysis = parse_bool(name, value, has_value); return true; }
    if name == "max-num-inline-blocks" { pi_cl.max_num_inline_blocks = cast(u32) parse_int(name, value); return true; }
    if name == "max-partial-inlining" { pi_cl.max_partial_inlining = parse_int(name, value); return true; }
    if name == "outline-region-freq-percent" { pi_cl.outline_region_freq_percent = parse_int(name, value); return true; }
    if name == "partial-inlining-extra-penalty" { pi_cl.extra_penalty = parse_int(name, value); return true; }
    if name == "min-region-size-ratio" || name == "min-block-execution" || name == "cold-branch-ratio"
        fatal("partial-inliner: -% (multi-region outlining) is not supported yet", name);
    return false;
}

// FunctionOutliningInfo
Pi_Outlining_Info :: struct {
    entries: [..] Value_Id;
    return_block: Value_Id = NONE;
    non_return_block: Value_Id = NONE;
    return_block_preds: [..] Value_Id;
}
pi_num_inlined_blocks :: (oi: *Pi_Outlining_Info) -> u32 { return cast(u32) oi.entries.count + 1; }

// FunctionCloner
Pi_Cloner :: struct {
    orig: Value_Id;
    cloned: Value_Id;
    outlined: [..] [2] Value_Id;       // (outlined function, the block calling it)
    is_function_inlined: bool;
    outlined_region_cost: Cost;
    oi: Pi_Outlining_Info;             // ClonedOI
    bfi: *Bfi;                         // ClonedFuncBFI
    bpi: *Bpi;
}

// F.use_empty() / F.users() with LLVM's uses: a blockaddress is not a use of its function
pi_fn_has_uses :: (f: Value_Id) -> bool {
    u := ir.v_first_use[f];
    while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR return true; u = ir.u_next[u]; }
    return false;
}
pi_fn_users :: (f: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR array_add(*r, ir.u_user[u]); u = ir.u_next[u]; }
    return r;
}
// getSupportedCallBase
pi_supported_call_base :: (u: Value_Id) -> Value_Id {
    if is_inst(u) && (inst_op(u) == .CALL || inst_op(u) == .INVOKE) return u;
    fatal("partial-inliner: all uses must be calls");
    return NONE;
}

// PartialInlinerPass::run
partial_inliner_run :: () -> Preserved {
    if pi_cl.disable return PRESERVE_ALL;
    psi := psi_require();
    pi_debug = getenv("JAI_PI_DEBUG") != null;
    pi_num_partial_inlining = 0;
    worklist: [..] Value_Id; worklist.allocator = temp;
    for f: ir.m_functions if pi_fn_has_uses(f) && !is_declaration(f) array_add(*worklist, f);
    changed := false;
    while worklist.count {
        f := pop(*worklist);
        if !pi_fn_has_uses(f) continue;
        ok, outlined := pi_unswitch_function(f, psi);
        if outlined != NONE array_add(*worklist, outlined);
        changed |= ok;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// unswitchFunction
pi_unswitch_function :: (f: Value_Id, psi: *Psi) -> (bool, Value_Id) {
    if fn_has_address_taken(f) return false, NONE;
    if fn_has_fn_attr(f, .AlwaysInline) return false, NONE;
    if fn_has_fn_attr(f, .NoInline) return false, NONE;
    if psi_is_function_entry_cold(psi, f) return false, NONE;
    if !pi_fn_has_uses(f) return false, NONE;
    if psi.has_summary && function_entry_count_present(f) && !pi_cl.disable_multi_region && psi_has_instrumentation_profile(psi)
        fatal("partial-inliner: multi-region (cold region) outlining with an instrumentation profile is not supported yet");
    ok, oi := pi_compute_outlining_info(f);
    if !ok return false, NONE;
    // a blockaddress would be redirected by the RAUW to the clone (it is not a use in LLVM)
    u := ir.v_first_use[f];
    while u != NONE { if vkind(ir.u_user[u]) == .C_BLOCKADDR fatal("partial-inliner: a function referenced by a blockaddress is not supported yet"); u = ir.u_next[u]; }
    c: Pi_Cloner;
    pi_cloner_init(*c, f, *oi);
    pi_normalize_return_block(*c);
    outlined := pi_do_single_region_function_outlining(*c);
    if outlined == NONE { pi_cloner_destroy(*c); return false, NONE; }
    if pi_try_partial_inline(*c, psi) { pi_cloner_destroy(*c); return true, outlined; }
    pi_cloner_destroy(*c);
    return false, NONE;
}

// computeOutliningInfo
pi_compute_outlining_info :: (f: Value_Id) -> (bool, Pi_Outlining_Info) {
    oi: Pi_Outlining_Info;
    oi.entries.allocator = temp; oi.return_block_preds.allocator = temp;
    entry := fn_entry(f);
    t := block_terminator(entry);
    if t == NONE || inst_op(t) != .CONDBR return false, oi;
    is_successor :: (s: Value_Id, b: Value_Id) -> bool {
        t := block_terminator(b);
        if t == NONE return false;
        for k: 0..cast(s64) num_successors(t) - 1 if get_successor(t, cast(u32) k) == s return true;
        return false;
    }
    is_return_block :: (b: Value_Id) -> bool { t := block_terminator(b); return t != NONE && inst_op(t) == .RET; }
    get_return_block :: (s1: Value_Id, s2: Value_Id) -> (Value_Id, Value_Id) {
        if is_return_block(s1) return s1, s2;
        if is_return_block(s2) return s2, s1;
        return NONE, NONE;
    }
    get_common_succ :: (s1: Value_Id, s2: Value_Id) -> (Value_Id, Value_Id) {
        if is_successor(s1, s2) return s1, s2;
        if is_successor(s2, s1) return s2, s1;
        return NONE, NONE;
    }
    succ2 :: (b: Value_Id) -> (bool, Value_Id, Value_Id) {
        t := block_terminator(b);
        if t == NONE || num_successors(t) != 2 return false, NONE, NONE;
        return true, get_successor(t, 0), get_successor(t, 1);
    }
    cur := entry;
    found := false;
    while true {
        if pi_num_inlined_blocks(*oi) >= pi_cl.max_num_inline_blocks break;
        ok, s1, s2 := succ2(cur);
        if !ok break;
        rb, nrb := get_return_block(s1, s2);
        if rb != NONE {
            array_add(*oi.entries, cur);
            oi.return_block = rb;
            oi.non_return_block = nrb;
            found = true;
            break;
        }
        cs, other := get_common_succ(s1, s2);
        if cs == NONE break;
        array_add(*oi.entries, cur);
        cur = other;
    }
    if !found return false, oi;
    entries: Table(Value_Id, bool); entries.allocator = temp;
    for oi.entries table_set(*entries, it, true);
    has_non_entry_pred :: (b: Value_Id, entries: *Table(Value_Id, bool)) -> bool {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(b, *preds);
        for preds if !table_contains(entries, it) return true;
        return false;
    }
    // CheckAndNormalizeCandidate
    succs: [..] Value_Id; succs.allocator = temp;
    for e: oi.entries {
        succs.count = 0;
        block_successors(e, *succs);
        for s: succs {
            if table_contains(*entries, s) continue;
            if s == oi.return_block array_add(*oi.return_block_preds, e);
            else if s != oi.non_return_block return false, oi;
        }
        if has_non_entry_pred(e, *entries) return false, oi;
    }
    while pi_num_inlined_blocks(*oi) < pi_cl.max_num_inline_blocks {
        cand := oi.non_return_block;
        ok, s1, s2 := succ2(cand);
        if !ok break;
        if has_non_entry_pred(cand, *entries) break;
        rb, nrb := get_return_block(s1, s2);
        if rb == NONE || rb != oi.return_block break;
        if block_single_predecessor(nrb) != cand break;
        array_add(*oi.entries, cand);
        oi.non_return_block = nrb;
        array_add(*oi.return_block_preds, cand);
        // Entries.insert(Cand): HasNonEntryPred captured Entries by value before this loop, so the growing set is
        // never consulted
    }
    return true, oi;
}

// FunctionCloner::FunctionCloner (single region)
pi_cloner_init :: (c: *Pi_Cloner, f: Value_Id, oi: *Pi_Outlining_Info) {
    c.orig = f;
    c.outlined.allocator = temp;
    c.oi.entries.allocator = temp; c.oi.return_block_preds.allocator = temp;
    vm: Value_Map; vmap_init(*vm);
    c.cloned = clone_function(f, *vm);
    c.oi.return_block = vmap_get(*vm, oi.return_block);
    c.oi.non_return_block = vmap_get(*vm, oi.non_return_block);
    for oi.entries array_add(*c.oi.entries, vmap_get(*vm, it));
    for oi.return_block_preds array_add(*c.oi.return_block_preds, vmap_get(*vm, it));
    ipo_rauw(f, c.cloned);
}
// FunctionCloner::~FunctionCloner
pi_cloner_destroy :: (c: *Pi_Cloner) {
    ipo_rauw(c.cloned, c.orig);
    gv_erase_from_parent(c.cloned);
    if !c.is_function_inlined for c.outlined gv_erase_from_parent(it[0]);
    if c.bfi bfi_free(c.bfi);
    if c.bpi bpi_free(c.bpi);
}

// FunctionCloner::normalizeReturnBlock
pi_normalize_return_block :: (c: *Pi_Cloner) {
    pre_return := c.oi.return_block;
    first_phi := block_first(pre_return);
    if first_phi != NONE && inst_op(first_phi) != .PHI first_phi = NONE;
    num_preds_from_entries := c.oi.return_block_preds.count;
    if first_phi == NONE || nops(first_phi) <= cast(u32) num_preds_from_entries + 1 return;
    c.oi.return_block = split_basic_block(pre_return, block_first_non_phi(pre_return), "");
    i := block_first(pre_return);
    ins := block_first(c.oi.return_block);
    dead: [..] Value_Id; dead.allocator = temp;
    while i != NONE && inst_op(i) == .PHI {
        old_phi := i;
        ret_phi := create_phi(vtype(old_phi), cast(u32) num_preds_from_entries + 1);
        inst_insert_before(ret_phi, ins);
        replace_all_uses_with(old_phi, ret_phi);
        ins = block_first_non_phi(c.oi.return_block);
        phi_add_incoming(ret_phi, old_phi, pre_return);
        for e: c.oi.return_block_preds {
            phi_add_incoming(ret_phi, phi_incoming_value_for_block(old_phi, e), e);
            phi_remove_incoming_block(old_phi, e);
        }
        all_equal := true;
        for k: 1..cast(s64) nops(old_phi) - 1 if op(old_phi, cast(u32) k) != op(old_phi, 0) { all_equal = false; break; }
        if all_equal {
            replace_all_uses_with(old_phi, op(old_phi, 0));
            array_add(*dead, old_phi);
        }
        i = inst_next(i);
    }
    for dead erase_inst(it);
    for e: c.oi.return_block_preds replace_uses_of_with(block_terminator(e), pre_return, c.oi.return_block);
}

// computeBBInlineCost
pi_compute_bb_inline_cost :: (bb: Value_Id, t: *Tti) -> Cost {
    cost: Cost = 0;
    instr_cost := ic_opts.instr_cost;
    for i: block_insts(bb) {
        o := inst_op(i);
        if o == .BITCAST || o == .PTRTOINT || o == .INTTOPTR || o == .ALLOCA || o == .PHI continue;
        if o == .GEP && gep_has_all_zero_indices_v(i) continue;
        if is_lifetime_start_or_end(i) continue;
        if o == .CALL && call_iid(i) != NOT_INTRINSIC {
            tys: [..] Type_Id; tys.allocator = temp;
            for k: 0..cast(s64) call_num_args(i) - 1 array_add(*tys, vtype(call_arg(i, cast(u32) k)));
            fmf: u32 = 0;
            if is_fp_math_inst(i) fmf = inst_fmf(i);
            ica := ica_types(call_iid(i), vtype(i), tys, fmf);
            cost = cost_add(cost, tti_intrinsic_cost(t, *ica, TCK_SIZE_AND_LATENCY));
            continue;
        }
        if o == .CALL || o == .INVOKE { cost = cost_add(cost, get_callsite_cost(t, i)); continue; }
        if o == .SWITCH { cost = cost_add(cost, (cast(s64) switch_num_cases(i) + 1) * instr_cost); continue; }
        cost = cost_add(cost, instr_cost);
    }
    return cost;
}

// FunctionCloner::doSingleRegionFunctionOutlining
pi_do_single_region_function_outlining :: (c: *Pi_Cloner) -> Value_Id {
    cf := c.cloned;
    dt := dt_new(false);
    dt_recalculate(dt, cf);
    li := li_new(cf);
    li_analyze(li, dt);
    c.bpi = bpi_calculate(cf, li, null, null, no_tli = true);
    c.bfi = bfi_calculate(cf, c.bpi, li);
    to_be_inlined :: (c: *Pi_Cloner, b: Value_Id) -> bool {
        if b == c.oi.return_block return true;
        for c.oi.entries if it == b return true;
        return false;
    }
    to_extract: [..] Value_Id; to_extract.allocator = temp;
    t := tti_get(cf);
    array_add(*to_extract, c.oi.non_return_block);
    c.outlined_region_cost = cost_add(c.outlined_region_cost, pi_compute_bb_inline_cost(c.oi.non_return_block, t));
    dfs: [..] Value_Id; dfs.allocator = temp;
    cfg_depth_first(fn_entry(cf), *dfs);
    for b: dfs if !to_be_inlined(c, b) && b != c.oi.non_return_block {
        array_add(*to_extract, b);
        c.outlined_region_cost = cost_add(c.outlined_region_cost, pi_compute_bb_inline_cost(b, t));
    }
    cache := ce_cache_new(cf);
    ce := ce_new(to_extract, dt, c.bfi, c.bpi, cached_assumption_cache(cf), true, false, "", false);
    outlined := ce_extract_code_region(*ce, *cache);
    if outlined != NONE {
        users := pi_fn_users(outlined);
        call := pi_supported_call_base(users[0]);
        array_add(*c.outlined, .[outlined, inst_block(call)]);
    }
    dt_free(dt);
    li_free(li);
    return outlined;
}

// computeOutliningCosts: (OutliningFuncCallCost, OutliningRuntimeOverhead)
pi_compute_outlining_costs :: (c: *Pi_Cloner) -> (Cost, Cost) {
    call_cost: Cost = 0;
    fn_cost: Cost = 0;
    for pair: c.outlined {
        t := tti_get(pair[0]);
        call_cost = cost_add(call_cost, pi_compute_bb_inline_cost(pair[1], t));
        for b: fn_blocks(pair[0]) fn_cost = cost_add(fn_cost, pi_compute_bb_inline_cost(b, t));
    }
    fn_cost -= 2 * ic_opts.instr_cost * cast(s64) c.outlined.count;
    overhead := call_cost + (fn_cost - c.outlined_region_cost) + pi_cl.extra_penalty;
    if !cost_valid(call_cost) || !cost_valid(fn_cost) fatal("partial-inliner: invalid outlining cost");
    return call_cost, overhead;
}

// hasProfileData
pi_has_profile_data :: (f: Value_Id, oi: *Pi_Outlining_Info) -> bool {
    if function_entry_count_present(f) return true;
    for e: oi.entries {
        t := block_terminator(e);
        if t != NONE && inst_op(t) == .CONDBR && prof_has_branch_weight_md(t) return true;
    }
    return false;
}

// getOutliningCallBBRelativeFreq
pi_outlining_call_bb_relative_freq :: (c: *Pi_Cloner) -> u32 {
    call_bb := c.outlined[c.outlined.count - 1][1];
    entry_freq := bfi_get_block_freq(c.bfi, fn_entry(c.cloned));
    call_freq := bfi_get_block_freq(c.bfi, call_bb);
    if call_freq > entry_freq call_freq = entry_freq;
    rel := bp_get(call_freq, entry_freq);
    if pi_has_profile_data(c.orig, *c.oi) return rel;
    if rel < bp_make(45, 100) return rel;
    floor := bp_make(cast(u64) pi_cl.outline_region_freq_percent, 100);
    return ifx rel > floor then rel else floor;
}

// shouldPartialInline
pi_should_partial_inline :: (cb: Value_Id, c: *Pi_Cloner, weighted_rcost: u64) -> bool {
    callee := call_called_function(cb);
    if pi_cl.skip_cost_analysis return is_inline_viable(callee).ok;
    ic := get_inline_cost(cb, get_inline_params());
    if ic.cost == IC_ALWAYS_COST return false;
    if ic.cost == IC_NEVER_COST return false;
    if !(ic.cost < ic.threshold) return false;
    savings := get_callsite_cost(tti_get(callee), cb);
    if pi_debug print("PI: ic cost=% threshold=% savings=%\n", ic.cost, ic.threshold, savings);
    if cast,no_check(u64) savings < weighted_rcost return false;
    return true;
}

// tryPartialInline
pi_try_partial_inline :: (c: *Pi_Cloner, psi: *Psi) -> bool {
    if c.outlined.count == 0 return false;
    size_cost, non_weighted_rcost := pi_compute_outlining_costs(c);
    rel := pi_outlining_call_bb_relative_freq(c);
    weighted_rcost := bp_scale(rel, cast,no_check(u64) non_weighted_rcost);
    if pi_debug { print("PI: size_cost=% rcost=% rel=% weighted=% region=%\n", size_cost, non_weighted_rcost, rel, weighted_rcost, c.outlined_region_cost); print("%", print_module_fresh()); }
    if !pi_cl.skip_cost_analysis && c.outlined_region_cost < size_cost return false;
    users := pi_fn_users(c.cloned);
    count_map: Table(Value_Id, u64); count_map.allocator = temp;
    has_entry_count, callee_entry_count := function_entry_count(c.orig);
    if has_entry_count pi_compute_callsite_to_prof_count_map(c.cloned, *count_map);
    count_v: u64 = ifx has_entry_count then callee_entry_count else 0;
    any_inline := false;
    for usr: users {
        cb := pi_supported_call_base(usr);
        if pi_cl.max_partial_inlining != -1 && pi_num_partial_inlining >= pi_cl.max_partial_inlining continue;
        if !pi_should_partial_inline(cb, c, weighted_rcost) continue;
        if func_vararg(glob(c.cloned).value_type)
            fatal("partial-inliner: forwarding varargs to the outlined function (InlineFunction ForwardVarArgsTo) is not supported yet");
        ifi: Inline_Function_Info;
        ifi_reset(*ifi);
        ifi.use_assumption_cache = true;
        ifi.psi = psi;
        r := inline_function(cb, *ifi, false, null, true, true);
        if !r.ok continue;
        if count_v {
            found, n := table_find(*count_map, usr);
            if found count_v -= min(count_v, n);
        }
        any_inline = true;
        pi_num_partial_inlining += 1;
    }
    if any_inline {
        c.is_function_inlined = true;
        if has_entry_count fn_set_entry_count(c.orig, count_v);
    }
    return any_inline;
}

// computeCallsiteToProfCountMap
pi_compute_callsite_to_prof_count_map :: (dup: Value_Id, map: *Table(Value_Id, u64)) {
    users := pi_fn_users(dup);
    for usr: users {
        cb := pi_supported_call_base(usr);
        bfi := get_bfi(inst_fn(cb));
        ok, n := bfi_block_profile_count(bfi, inst_block(cb));
        table_set(map, usr, ifx ok then n else 0);
    }
}
