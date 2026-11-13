// HotColdSplitting (`hotcoldsplit`): a port of llvm/lib/Transforms/IPO/HotColdSplitting.cpp (HotColdSplitting::run,
// outlineColdRegions, isBasicBlockCold / analyzeProfMetadata / unlikelyExecuted, mayExtractBlock, the
// OutliningRegion construction (inverse DFS over post-dominated predecessors, DFS over dominated successors) and
// takeSingleEntrySubRegion, isSplittingBeneficial with getOutliningBenefit / getOutliningPenalty,
// extractColdRegion, markFunctionCold). The extraction itself is code_extractor.jai. Optimization remarks are not
// emitted.

hcs_cl: struct {
    static_analysis := true;               // -hot-cold-static-analysis
    threshold: s64 = 2;                    // -hotcoldsplit-threshold
    enable_cold_section := false;          // -enable-cold-section
    cold_section_name := "__llvm_cold";    // -hotcoldsplit-cold-section-name
    max_params: s64 = 4;                   // -hotcoldsplit-max-params
    cold_prob_denom: s64 = 100;            // -hotcoldsplit-cold-probability-denom
    cold_prob_denom_given := false;        //   getNumOccurrences()
};

hot_cold_split_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: invalid boolean value '%' for option -%", value, name);
        return false;
    }
    parse_int :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("opt: -% needs a value", name);
        v, ok := string_to_int(value);
        if !ok fatal("opt: invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == "hot-cold-static-analysis" { hcs_cl.static_analysis = parse_bool(name, value, has_value); return true; }
    if name == "hotcoldsplit-threshold" { hcs_cl.threshold = parse_int(name, value, has_value); return true; }
    if name == "enable-cold-section" { hcs_cl.enable_cold_section = parse_bool(name, value, has_value); return true; }
    if name == "hotcoldsplit-cold-section-name" { hcs_cl.cold_section_name = copy_string(value); return true; }
    if name == "hotcoldsplit-max-params" { hcs_cl.max_params = parse_int(name, value, has_value); return true; }
    if name == "hotcoldsplit-cold-probability-denom" {
        hcs_cl.cold_prob_denom = parse_int(name, value, has_value);
        hcs_cl.cold_prob_denom_given = true;
        return true;
    }
    return false;
}

// ---------------------------------------------------------------- df_iterator / idf_iterator over the CFG

// depth_first / inverse_depth_first with skipChildren() and getPathLength() (the stack depth); children are listed
// lazily, when the walk first leaves a node (df_iterator::toNext).
Hcs_Dfs_Frame :: struct { n: Value_Id; children: [..] Value_Id; k: s64; started: bool; }
Hcs_Dfs :: struct {
    stack: [..] Hcs_Dfs_Frame;
    visited: Table(Value_Id, bool);
    inverse: bool;
}
hcs_dfs_init :: (w: *Hcs_Dfs, start: Value_Id, inverse: bool) {
    w.stack.allocator = temp; w.visited.allocator = temp;
    w.inverse = inverse;
    e: Hcs_Dfs_Frame; e.n = start; e.children.allocator = temp;
    array_add(*w.stack, e);
    table_set(*w.visited, start, true);
}
hcs_dfs_current :: (w: *Hcs_Dfs) -> Value_Id { if w.stack.count == 0 return NONE; return w.stack[w.stack.count - 1].n; }
hcs_dfs_path_length :: (w: *Hcs_Dfs) -> u32 { return cast(u32) w.stack.count; }
hcs_dfs_next :: (w: *Hcs_Dfs) {
    while w.stack.count {
        top := *w.stack[w.stack.count - 1];
        if !top.started {
            top.started = true;
            if w.inverse block_predecessors(top.n, *top.children); else block_successors(top.n, *top.children);
            top.k = 0;
        }
        while top.k < top.children.count {
            nx := top.children[top.k];
            top.k += 1;
            if !table_contains(*w.visited, nx) {
                table_set(*w.visited, nx, true);
                e: Hcs_Dfs_Frame; e.n = nx; e.children.allocator = temp;
                array_add(*w.stack, e);
                return;
            }
        }
        w.stack.count -= 1;
    }
}
hcs_dfs_skip_children :: (w: *Hcs_Dfs) {
    w.stack.count -= 1;
    if w.stack.count hcs_dfs_next(w);
}

// ---------------------------------------------------------------- cold blocks

// blockEndsInUnreachable
hcs_block_ends_in_unreachable :: (bb: Value_Id) -> bool {
    t := block_terminator(bb);
    if t == NONE return true;
    if num_successors(t) != 0 return false;
    o := inst_op(t);
    return !(o == .RET || o == .INDIRECTBR);
}

// analyzeProfMetadata
hcs_analyze_prof_metadata :: (bb: Value_Id, cold_prob_thresh: u32, annotated: *Table(Value_Id, bool)) {
    t := block_terminator(bb);
    if inst_op(t) != .CONDBR return;
    ok, tw, fw := prof_extract_branch_weights_2(t);
    if !ok return;
    sum := tw + fw;
    if sum == 0 return;
    tp := bp_get(tw, sum);
    fp := bp_get(fw, sum);
    if tp <= cold_prob_thresh table_set(annotated, get_successor(t, 0), true);
    if fp <= cold_prob_thresh table_set(annotated, get_successor(t, 1), true);
}

// unlikelyExecuted
hcs_unlikely_executed :: (bb: Value_Id) -> bool {
    t := block_terminator(bb);
    if block_is_eh_pad(bb) || inst_op(t) == .RESUME return true;
    nosan := md_kind_id("nosanitize");
    for i: block_insts(bb) {
        o := inst_op(i);
        if o != .CALL && o != .INVOKE && o != .CALLBR continue;
        if call_has_fn_attr(i, .Cold) && get_metadata(i, nosan) == NONE return true;
    }
    if hcs_block_ends_in_unreachable(bb) {
        p := inst_prev(t);
        if p != NONE && inst_op(p) == .CALL && call_has_fn_attr(p, .NoReturn) return false;
        return true;
    }
    return false;
}

// mayExtractBlock
hcs_may_extract_block :: (bb: Value_Id) -> bool {
    if block_has_address_taken(bb) || block_is_eh_pad(bb) return false;
    t := block_terminator(bb);
    if inst_op(t) == .INVOKE || inst_op(t) == .RESUME return false;
    for i: block_insts(bb) if type_kind(vtype(i)) == .TOKEN return false;
    return true;
}

// markFunctionCold(F, UpdateEntryCount = true)
hcs_mark_function_cold :: (f: Value_Id) {
    if !fn_has_fn_attr(f, .Cold) fn_add_fn_attr_kind(f, .Cold);
    if !fn_has_fn_attr(f, .MinSize) fn_add_fn_attr_kind(f, .MinSize);
    fn_set_entry_count(f, 0);
}

// isFunctionCold
hcs_is_function_cold :: (f: Value_Id, psi: *Psi) -> bool {
    if fn_has_fn_attr(f, .Cold) return true;
    if glob(f).cc == CC_COLD return true;
    if psi_is_function_entry_cold(psi, f) return true;
    return false;
}

// shouldOutlineFrom
hcs_should_outline_from :: (f: Value_Id) -> bool {
    if fn_has_fn_attr(f, .AlwaysInline) return false;
    if fn_has_fn_attr(f, .NoInline) return false;
    if fn_has_fn_attr(f, .NoReturn) return false;
    if fn_has_fn_attr(f, .SanitizeAddress) || fn_has_fn_attr(f, .SanitizeHWAddress) ||
       fn_has_fn_attr(f, .SanitizeThread) || fn_has_fn_attr(f, .SanitizeMemory) return false;
    if glob(f).has_personality && is_scoped_eh_personality(classify_eh_personality(op(f, 0))) return false;
    return true;
}

// isBasicBlockCold
hcs_is_basic_block_cold :: (bb: Value_Id, cold_prob_thresh: u32, annotated: *Table(Value_Id, bool), bfi: *Bfi, psi: *Psi) -> bool {
    if bfi {
        // PSI->isColdBlock(BB, BFI)
        ok, c := bfi_block_profile_count(bfi, bb);
        if ok && psi_is_cold_count(psi, c) return true;
    } else {
        hcs_analyze_prof_metadata(bb, cold_prob_thresh, annotated);
        if table_contains(annotated, bb) return true;
    }
    if hcs_cl.static_analysis && hcs_unlikely_executed(bb) return true;
    return false;
}

// ---------------------------------------------------------------- cost model

// getOutliningBenefit
hcs_outlining_benefit :: (region: [] Value_Id, t: *Tti) -> Cost {
    benefit: Cost = 0;
    for bb: region for i: block_insts(bb) {
        if i == block_terminator(bb) continue;
        benefit = cost_add(benefit, tti_instruction_cost(t, i, TCK_CODE_SIZE));
    }
    return benefit;
}

// getOutliningPenalty
hcs_outlining_penalty :: (region: [] Value_Id, num_inputs: s64, num_outputs: s64) -> s64 {
    penalty := hcs_cl.threshold;
    if hcs_cl.threshold <= 0 return penalty;
    in_region :: (region: [] Value_Id, b: Value_Id) -> bool { for region if it == b return true; return false; }
    no_blocks_return := true;
    succs_outside: [..] Value_Id; succs_outside.allocator = temp;   // SmallPtrSet: only its size is read
    succs: [..] Value_Id; succs.allocator = temp;
    for bb: region {
        succs.count = 0;
        block_successors(bb, *succs);
        if succs.count == 0 {
            no_blocks_return = no_blocks_return && inst_op(block_terminator(bb)) == .UNREACHABLE;
            continue;
        }
        for s: succs if !in_region(region, s) {
            no_blocks_return = false;
            if !block_set_contains(succs_outside, s) array_add(*succs_outside, s);
        }
    }
    num_split_exit_phis := 0;
    for exit_bb: succs_outside {
        p := block_first(exit_bb);
        while p != NONE && inst_op(p) == .PHI {
            n := 0;
            for k: 0..cast(s64) nops(p) - 1 if in_region(region, phi_block(p, cast(u32) k)) {
                n += 1;
                if n > 1 { num_split_exit_phis += 1; break; }
            }
            p = inst_next(p);
        }
    }
    num_outputs_and_split_phis := num_outputs + num_split_exit_phis;
    num_params := num_inputs + num_outputs_and_split_phis;
    if num_params > hcs_cl.max_params return 0x7FFF_FFFF;
    penalty += 2 * num_params;                      // CostForArgMaterialization = 2 * TCC_Basic
    penalty += 3 * num_outputs_and_split_phis;      // CostForRegionOutput = 3 * TCC_Basic
    if no_blocks_return penalty -= region.count;
    if succs_outside.count > 1 penalty += succs_outside.count - 1;
    return penalty;
}

// isSplittingBeneficial
hcs_is_splitting_beneficial :: (ce: *Code_Extractor, region: [] Value_Id, t: *Tti) -> bool {
    inputs: Value_Set; vset_init(*inputs);
    outputs: Value_Set; vset_init(*outputs);
    sinks: Value_Set; vset_init(*sinks);
    ce_find_inputs_outputs(ce, *inputs, *outputs, *sinks);
    benefit := hcs_outlining_benefit(region, t);
    penalty := hcs_outlining_penalty(region, inputs.list.count, outputs.list.count);
    if !cost_valid(benefit) || benefit <= penalty return false;
    return true;
}

// ---------------------------------------------------------------- OutliningRegion

Hcs_Block :: struct { bb: Value_Id; score: u32; }
Hcs_Region :: struct {
    blocks: [..] Hcs_Block;
    suggested_entry: Value_Id = NONE;
    entire_function_cold: bool;
}

// OutliningRegion::create
hcs_region_create :: (sink_bb: Value_Id, dt: *Dom_Tree, pdt: *Dom_Tree) -> [..] Hcs_Region {
    regions: [..] Hcs_Region; regions.allocator = temp;
    region_blocks: Table(Value_Id, bool); region_blocks.allocator = temp;
    new_region :: (regions: *[..] Hcs_Region) -> s64 {
        r: Hcs_Region; r.blocks.allocator = temp;
        array_add(regions, r);
        return regions.count - 1;
    }
    cur := new_region(*regions);
    add_block :: (regions: *[..] Hcs_Region, cur: s64, region_blocks: *Table(Value_Id, bool), bb: Value_Id, score: u32) {
        table_set(region_blocks, bb, true);
        array_add(*regions.*[cur].blocks, .{bb, score});
    }
    score_of :: (bb: Value_Id, score: u32) -> u32 { return ifx hcs_may_extract_block(bb) then score else 0; }

    sink_score := score_of(sink_bb, 1);   // ScoreForSinkBlock
    regions[cur].suggested_entry = ifx sink_score > 0 then sink_bb else NONE;
    best_score := sink_score;

    preds: [..] Value_Id; preds.allocator = temp;
    w: Hcs_Dfs;
    hcs_dfs_init(*w, sink_bb, true);
    hcs_dfs_next(*w);
    while w.stack.count {
        pred_bb := hcs_dfs_current(*w);
        sink_post_dom := dt_dominates(pdt, sink_bb, pred_bb);
        preds.count = 0;
        block_predecessors(pred_bb, *preds);
        if sink_post_dom && preds.count == 0 {
            regions[cur].entire_function_cold = true;
            return regions;
        }
        if !sink_post_dom || !hcs_may_extract_block(pred_bb) {
            hcs_dfs_skip_children(*w);
            continue;
        }
        pred_score := score_of(pred_bb, hcs_dfs_path_length(*w));
        if pred_score > best_score {
            regions[cur].suggested_entry = pred_bb;
            best_score = pred_score;
        }
        add_block(*regions, cur, *region_blocks, pred_bb, pred_score);
        hcs_dfs_next(*w);
    }

    if hcs_may_extract_block(sink_bb) {
        add_block(*regions, cur, *region_blocks, sink_bb, sink_score);
        preds.count = 0;
        block_predecessors(sink_bb, *preds);
        if preds.count == 0 {
            regions[cur].entire_function_cold = true;
            return regions;
        }
    } else {
        cur = new_region(*regions);
        best_score = 0;
    }

    s: Hcs_Dfs;
    hcs_dfs_init(*s, sink_bb, false);
    hcs_dfs_next(*s);
    while s.stack.count {
        succ_bb := hcs_dfs_current(*s);
        sink_dom := dt_dominates(dt, sink_bb, succ_bb);
        duplicate := table_contains(*region_blocks, succ_bb);
        if duplicate || !sink_dom || !hcs_may_extract_block(succ_bb) {
            hcs_dfs_skip_children(*s);
            continue;
        }
        succ_score := score_of(succ_bb, 1);   // ScoreForSuccBlock
        if succ_score > best_score {
            regions[cur].suggested_entry = succ_bb;
            best_score = succ_score;
        }
        add_block(*regions, cur, *region_blocks, succ_bb, succ_score);
        hcs_dfs_next(*s);
    }
    return regions;
}

// OutliningRegion::takeSingleEntrySubRegion
hcs_take_single_entry_sub_region :: (r: *Hcs_Region, dt: *Dom_Tree) -> [..] Value_Id {
    sub: [..] Value_Id; sub.allocator = temp;
    entry := r.suggested_entry;
    array_add(*sub, entry);
    next_entry: Value_Id = NONE;
    next_score: u32 = 0;
    k := 0;
    for blk: r.blocks {
        in_sub := blk.bb == entry || dt_dominates(dt, entry, blk.bb);
        if !in_sub && blk.score > next_score { next_entry = blk.bb; next_score = blk.score; }
        if in_sub && blk.bb != entry array_add(*sub, blk.bb);
        if !in_sub { r.blocks[k] = blk; k += 1; }
    }
    r.blocks.count = k;
    r.suggested_entry = next_entry;
    return sub;
}

// ---------------------------------------------------------------- driver

// extractColdRegion
hcs_extract_cold_region :: (ce: *Code_Extractor, cache: *Ce_Cache, orig: Value_Id) -> Value_Id {
    out := ce_extract_code_region(ce, cache);
    if out == NONE return NONE;
    // the only user: the call in codeRepl
    ci := ir.u_user[ir.v_first_use[out]];
    // TTI.useColdCCForColdCall: false on X86
    call_add_fn_attr(ci, .NoInline);
    if hcs_cl.enable_cold_section glob(out).section = hcs_cl.cold_section_name;
    else if glob(orig).section.count glob(out).section = glob(orig).section;
    hcs_mark_function_cold(out);
    return out;
}

// outlineColdRegions
hcs_outline_cold_regions :: (f: Value_Id, has_profile_summary: bool, psi: *Psi) -> bool {
    cold_blocks: Table(Value_Id, bool); cold_blocks.allocator = temp;
    cannot_be_outlined: Table(Value_Id, bool); cannot_be_outlined.allocator = temp;
    annotated: Table(Value_Id, bool); annotated.allocator = temp;
    Work :: struct { entry: Value_Id; ce: Code_Extractor; }
    worklist: [..] Work; worklist.allocator = temp;

    po: [..] Value_Id; po.allocator = temp;
    cfg_post_order(fn_entry(f), *po);
    dt: *Dom_Tree = null;
    pdt: *Dom_Tree = null;
    bfi: *Bfi = null;
    if has_profile_summary bfi = get_bfi(f);
    t := tti_get(f);
    ac := cached_assumption_cache(f);
    cold_prob_thresh := bp_compl(bp_make(cast(u64) tti_predictable_branch_threshold(t), 100));
    if hcs_cl.cold_prob_denom_given cold_prob_thresh = bp_make(1, cast(u64) hcs_cl.cold_prob_denom);

    outlined_function_id := 1;
    for < bb: po {
        if table_contains(*cold_blocks, bb) continue;
        if table_contains(*cannot_be_outlined, bb) continue;
        if !hcs_is_basic_block_cold(bb, cold_prob_thresh, *annotated, bfi, psi) continue;
        if !dt { dt = dt_new(false); dt_recalculate(dt, f); }
        if !pdt { pdt = dt_new(true); dt_recalculate(pdt, f); }
        regions := hcs_region_create(bb, dt, pdt);
        for * region: regions {
            if region.suggested_entry == NONE continue;
            if region.entire_function_cold return false;
            while true {
                sub := hcs_take_single_entry_sub_region(region, dt);
                ce := ce_new(sub, dt, null, null, ac, false, false, tprint("cold.%", outlined_function_id), false);
                overlaps := false;
                for sub if table_contains(*cold_blocks, it) { overlaps = true; break; }
                if ce_is_eligible(*ce) && hcs_is_splitting_beneficial(*ce, sub, t) && !overlaps {
                    for sub table_set(*cold_blocks, it, true);
                    array_add(*worklist, .{sub[0], ce});
                    outlined_function_id += 1;
                } else {
                    for blk: sub {
                        if (dt_dominates(dt, bb, blk) && dt_dominates(pdt, blk, bb)) || (dt_dominates(pdt, bb, blk) && dt_dominates(dt, blk, bb))
                            table_set(*cannot_be_outlined, blk, true);
                    }
                }
                if region.suggested_entry == NONE break;
            }
        }
    }
    if worklist.count == 0 return false;
    cache := ce_cache_new(f);
    for * w: worklist {
        out := hcs_extract_cold_region(*w.ce, *cache, f);
        if out == NONE fatal("hotcoldsplit: internal: a cold region selected for outlining was not extracted");
    }
    return true;
}

// HotColdSplitting::run
hot_cold_split_run :: () -> Preserved {
    psi := psi_require();
    has_profile_summary := psi.has_summary;
    changed := false;
    k := 0;
    // `for (Function &F : M)` also visits the functions outlined on the way (they are cold and skipped)
    while k < ir.m_functions.count {
        f := ir.m_functions[k];
        k += 1;
        if is_declaration(f) continue;
        if fn_has_fn_attr(f, .OptimizeNone) continue;
        if hcs_is_function_cold(f, psi) continue;
        if !hcs_should_outline_from(f) continue;
        changed |= hcs_outline_cold_regions(f, has_profile_summary, psi);
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
