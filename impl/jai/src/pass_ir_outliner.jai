// IROutliner (`iroutliner`): a port of llvm/lib/Transforms/IPO/IROutliner.cpp (OutlinableRegion splitCandidate /
// reattachCandidate, the input/output and constant analysis, the PHINode output numbering, the cost model, extraction
// through the CodeExtractor, deduplicateExtractedSections with the output blocks and the switch, the overall
// function's debug info) on top of ir_similarity.jai (IRSimilarityIdentifier).
//
// LLVM keeps several DenseMap<Value *, BasicBlock *> (return value -> block). Every walk over them does independent
// work per key (blocks are created in the order of the sorted keys), so a plain table stands in for them. The exits of
// a region (a SmallPtrSet<BasicBlock *, 1>) are walked in pointer order when there are two or more; that order decides
// the order of the PHINode outputs, so more than one exit block contributing a PHINode fails loudly.

ior_cl: struct {
    enable_linkonceodr: bool;        // -enable-linkonceodr-ir-outlining
    no_cost: bool;                   // -ir-outlining-no-cost
};
ir_outliner_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: invalid boolean value '%' for option -%", value, name);
        return false;
    }
    if name == "enable-linkonceodr-ir-outlining" { ior_cl.enable_linkonceodr = parse_bool(name, value, has_value); return true; }
    if name == "ir-outlining-no-cost" { ior_cl.no_cost = parse_bool(name, value, has_value); return true; }
    return false;
}

Ior_Region :: struct {
    cand: u32;
    new_front: u32 = IRSIM_NULL;
    new_back: u32 = IRSIM_NULL;
    num_extracted_inputs: u32;
    output_block_num: u32 = 0xFFFF_FFFF;
    extracted_arg_to_agg: Table(u32, u32);
    agg_arg_to_extracted: Table(u32, u32);
    remapped_arguments: Table(Value_Id, Value_Id);
    changed_arg_order: bool;
    ends_in_branch: bool;
    phi_blocks: Table(Value_Id, Value_Id);
    agg_arg_to_constant: Table(u32, Value_Id);
    gvn_stores: [..] u32;
    ce: Code_Extractor;
    call: Value_Id = NONE;
    extracted_function: Value_Id = NONE;
    candidate_split: bool;
    ignore_region: bool;
    prev_bb: Value_Id = NONE;
    start_bb: Value_Id = NONE;
    end_bb: Value_Id = NONE;
    follow_bb: Value_Id = NONE;
    parent: u32;
}

Ior_Phi_Data :: struct { bb_canon: u32; agg_arg: u32; canons: [..] u32; }

Ior_Group :: struct {
    regions: [..] u32;
    argument_types: [..] Type_Id;
    outlined_function: Value_Id = NONE;
    ignore_group: bool;
    end_bbs: Table(Value_Id, Value_Id);
    phi_blocks: Table(Value_Id, Value_Id);
    output_gvn_combinations: [..] [..] u32;
    input_types_set: bool;
    num_aggregate_inputs: u32;
    canonical_number_to_agg_arg: Table(u32, u32);
    branches_to_outside: u32;
    phi_node_gvn_tracker: u32 = 0xFFFF_FFFD;
    phi_node_gvn_to_gvns: Table(u32, Ior_Phi_Data);
    gvns_to_phi_node_gvn: Table(string, u32);
    benefit: Cost;
    cost: Cost;
    swift_error_argument: s64 = -1;
}

Ior :: struct {
    sim: *Irsim;
    regions: [..] Ior_Region;
    groups: [..] Ior_Group;
    outlined: Table(u32, bool);
    output_mappings: Table(Value_Id, Value_Id);
    fn_allocas: Table(Value_Id, [..] Value_Id);   // the allocas per function during the analysis phase
    cost_model: bool;
    outline_from_linkonceodr: bool;
    // InstructionAllowed
    enable_branches: bool;
    enable_indirect_calls := true;
    enable_intrinsics: bool;
    enable_musttail_calls: bool;
}

ior_init_region :: (o: *Ior, c: u32, g: u32) -> u32 {
    r: Ior_Region;
    r.cand = c; r.parent = g;
    r.extracted_arg_to_agg.allocator = temp; r.agg_arg_to_extracted.allocator = temp;
    r.remapped_arguments.allocator = temp; r.phi_blocks.allocator = temp; r.agg_arg_to_constant.allocator = temp;
    r.gvn_stores.allocator = temp;
    r.start_bb = irsim_start_bb(o.sim, c);
    r.end_bb = inst_block(irsim_back_inst(o.sim, c));
    array_add(*o.regions, r);
    return cast(u32) o.regions.count - 1;
}
ior_init_group :: (g: *Ior_Group) {
    g.regions.allocator = temp; g.argument_types.allocator = temp; g.end_bbs.allocator = temp; g.phi_blocks.allocator = temp;
    g.output_gvn_combinations.allocator = temp; g.canonical_number_to_agg_arg.allocator = temp;
    g.phi_node_gvn_to_gvns.allocator = temp; g.gvns_to_phi_node_gvn.allocator = temp;
}

// InstructionAllowed::visit
ior_instruction_allowed :: (o: *Ior, i: Value_Id) -> bool {
    op := inst_op(i);
    if op == {
        case .BR; #through;
        case .CONDBR; #through;
        case .PHI; return o.enable_branches;
        case .ALLOCA; #through; case .VAARG; #through; case .LANDINGPAD; #through;
        case .CLEANUPPAD; #through; case .CATCHPAD; #through; case .FREEZE; #through;
        case .INVOKE; #through; case .CALLBR; return false;
        case .CALL;
            // (InstructionAllowed's `IntrinsicInst` member is no visit method: intrinsics reach visitCallInst)
            f := call_called_function(i);
            indirect := irsim_is_indirect_call(i);
            if indirect && !o.enable_indirect_calls return false;
            if f == NONE && !indirect return false;
            if call_has_fn_attr(i, .ReturnsTwice) return false;
            if call_has_fn_attr(i, .NoMerge) return false;
            tail_cc := irsim_is_tail_cc(i);
            if tail_cc && !o.enable_musttail_calls return false;
            if irsim_is_must_tail(i) && !o.enable_musttail_calls return false;
            if irsim_is_must_tail(i) && !tail_cc return false;
            return true;
    }
    if is_terminator(op) return false;
    return true;
}

ior_blocks_contains :: (bs: [] Value_Id, b: Value_Id) -> bool { for bs if it == b return true; return false; }

// replaceTargetsFromPHINode
ior_replace_targets_from_phi_node :: (pblock: Value_Id, find: Value_Id, replace: Value_Id, included: [] Value_Id) {
    for p: block_insts(pblock) {
        if inst_op(p) != .PHI break;
        for k: 0..cast(s64) phi_num_incoming(p) - 1 {
            inc := phi_block(p, cast(u32) k);
            if ior_blocks_contains(included, inc) replace_successor_with(block_terminator(inc), find, replace);
        }
    }
}
// BasicBlock::hasNPredecessors / hasNPredecessorsOrMore
ior_num_preds :: (b: Value_Id) -> s64 {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(b, *preds);
    return preds.count;
}

// OutlinableRegion::splitCandidate
ior_split_candidate :: (o: *Ior, rid: u32) {
    s := o.sim;
    r := *o.regions[rid];
    if r.candidate_split fatal("internal: iroutliner: candidate already split");
    back := irsim_back_inst(s, r.cand);
    f := inst_fn(back);
    end_inst: Value_Id = NONE;
    back_term := is_terminator(inst_op(back));
    if !back_term || inst_block(back) != glob(f).last_block {
        end_inst = s.data[irsim_cand_end(s, r.cand)].inst;
        if end_inst == NONE fatal("internal: iroutliner: expected an end instruction");
    }
    if !back_term && end_inst != inst_next(back) return;
    start_inst := irsim_front_inst(s, r.cand);
    r.start_bb = inst_block(start_inst);
    r.prev_bb = r.start_bb;
    bbs := irsim_cand_blocks(s, r.cand);
    it := start_inst;
    r.end_bb = inst_block(back);
    phi_pred_block: Value_Id = NONE;
    end_term_differs := block_terminator(r.end_bb) != back;
    while it != NONE && inst_op(it) == .PHI {
        outside := 0;
        for k: 0..cast(s64) phi_num_incoming(it) - 1 {
            inc := phi_block(it, cast(u32) k);
            if !ior_blocks_contains(bbs, inc) { phi_pred_block = inc; outside += 1; continue; }
            if inc == r.end_bb && end_term_differs { phi_pred_block = inc; outside += 1; }
        }
        if outside > 1 return;
        it = inst_next(it);
    }
    if inst_op(start_inst) == .PHI && start_inst != block_first(r.start_bb) return;
    if inst_op(back) == .PHI && back != inst_prev(block_first_insertion_pt(r.end_bb)) return;

    original := copy_string(vname(r.prev_bb),, allocator = temp);
    r.start_bb = split_basic_block(r.prev_bb, start_inst, tconcat(original, "_to_outline"));
    block_replace_successors_phi_uses_with(r.prev_bb, r.prev_bb, r.start_bb);
    if phi_pred_block != NONE block_replace_successors_phi_uses_with(r.prev_bb, phi_pred_block, r.prev_bb);
    r.candidate_split = true;
    if !back_term {
        r.end_bb = inst_block(end_inst);
        r.follow_bb = split_basic_block(r.end_bb, end_inst, tconcat(original, "_after_outline"));
        block_replace_successors_phi_uses_with(r.end_bb, r.end_bb, r.follow_bb);
        block_replace_successors_phi_uses_with(r.follow_bb, r.prev_bb, r.follow_bb);
    } else {
        r.end_bb = inst_block(back);
        r.ends_in_branch = true;
        r.follow_bb = NONE;
    }
    bbs = irsim_cand_blocks(s, r.cand);
    ior_replace_targets_from_phi_node(r.start_bb, r.prev_bb, r.start_bb, bbs);
    if r.follow_bb != NONE ior_replace_targets_from_phi_node(r.follow_bb, r.end_bb, r.follow_bb, bbs);
}

// OutlinableRegion::reattachCandidate
ior_reattach_candidate :: (o: *Ior, rid: u32) {
    s := o.sim;
    r := *o.regions[rid];
    if !r.candidate_split fatal("internal: iroutliner: candidate is not split");
    start_inst := s.data[s.cands[r.cand].first].inst;
    if inst_op(start_inst) == .PHI && ior_num_preds(r.prev_bb) != 0 {
        if ior_num_preds(r.prev_bb) >= 2 fatal("internal: iroutliner: PrevBB has more than one predecessor");
        before_prev := block_single_predecessor(r.prev_bb);
        block_replace_successors_phi_uses_with(r.prev_bb, r.prev_bb, before_prev);
    }
    erase_inst(block_terminator(r.prev_bb));
    if r.extracted_function == NONE {
        bbs := irsim_cand_blocks(s, r.cand);
        ior_replace_targets_from_phi_node(r.start_bb, r.start_bb, r.prev_bb, bbs);
        if !r.ends_in_branch ior_replace_targets_from_phi_node(r.follow_bb, r.follow_bb, r.end_bb, bbs);
    }
    block_move_all_insts_to_end(r.prev_bb, r.start_bb);
    placement := r.prev_bb;
    if r.start_bb != r.end_bb placement = r.end_bb;
    if !r.ends_in_branch && block_unique_successor(placement) != NONE {
        if r.follow_bb == NONE fatal("internal: iroutliner: FollowBB for Candidate is not defined");
        erase_inst(block_terminator(placement));
        block_move_all_insts_to_end(placement, r.follow_bb);
        block_replace_successors_phi_uses_with(placement, r.follow_bb, placement);
        block_erase_from_parent(r.follow_bb);
    }
    block_replace_successors_phi_uses_with(r.prev_bb, r.start_bb, r.prev_bb);
    block_erase_from_parent(r.start_bb);
    r.start_bb = r.prev_bb;
    r.end_bb = NONE;
    r.prev_bb = NONE;
    r.follow_bb = NONE;
    r.candidate_split = false;
}

// findCorrespondingValueIn
ior_find_corresponding_value_in :: (o: *Ior, rid: u32, other: u32, v: Value_Id) -> Value_Id {
    s := o.sim;
    c := o.regions[rid].cand;
    oc := o.regions[other].cand;
    f1, gvn := irsim_get_gvn(s, c, v);
    if !f1 fatal("internal: iroutliner: no GVN for incoming value");
    f2, canon := irsim_canon(s, c, gvn);
    if !f2 fatal("internal: iroutliner: no canonical number");
    f3, first := irsim_from_canon(s, oc, canon);
    if !f3 fatal("internal: iroutliner: no corresponding GVN");
    f4, val := irsim_from_gvn(s, oc, first);
    if !f4 return NONE;
    return val;
}
// findCorrespondingBlockIn
ior_find_corresponding_block_in :: (o: *Ior, rid: u32, other: u32, bb: Value_Id) -> Value_Id {
    first := block_first_non_phi(bb);
    if first == NONE fatal("internal: iroutliner: block is empty");
    v := ior_find_corresponding_value_in(o, rid, other, first);
    if v == NONE return NONE;
    return inst_block(v);
}

// getBenefit
ior_get_benefit :: (o: *Ior, rid: u32) -> Cost {
    s := o.sim;
    t := tti_get(block_fn(o.regions[rid].start_bb));
    benefit: Cost = 0;
    for d: irsim_cand_rows(s, o.regions[rid].cand) {
        i := s.data[d].inst;
        op := inst_op(i);
        if op == .FDIV || op == .FREM || op == .SDIV || op == .SREM || op == .UDIV || op == .UREM benefit = cost_add(benefit, 1);
        else benefit = cost_add(benefit, tti_instruction_cost(t, i, TCK_CODE_SIZE));
    }
    return benefit;
}

ior_find_output_mapping :: (o: *Ior, v: Value_Id) -> Value_Id {
    f, m := table_find(*o.output_mappings, v);
    if f return m;
    return v;
}

// collectRegionsConstants
ior_collect_regions_constants :: (o: *Ior, rid: u32, gvn_to_constant: *Table(u32, Value_Id), not_same: *Table(u32, bool)) -> bool {
    s := o.sim;
    c := o.regions[rid].cand;
    same := true;
    for d: irsim_cand_rows(s, c) {
        for v: s.data[d].ops {
            f, gvn := irsim_get_gvn(s, c, v);
            if !f fatal("internal: iroutliner: expected a GVN for an operand");
            if table_contains(not_same, gvn) {
                if is_const(v) same = false;
                continue;
            }
            if is_const(v) {
                found, cst := table_find(gvn_to_constant, gvn);
                if !found { table_set(gvn_to_constant, gvn, v); continue; }
                if cst == v continue;
                same = false;
            }
            if table_contains(gvn_to_constant, gvn) same = false;
            table_set(not_same, gvn, true);
        }
    }
    return same;
}

// getSubprogramOrNull
ior_subprogram_or_null :: (o: *Ior, g: *Ior_Group) -> Md_Id {
    for rid: g.regions {
        f := inst_fn(o.regions[rid].call);
        sp := get_metadata(f, MDK_DBG);
        if sp != NONE return sp;
    }
    return NONE;
}

// createFunction
ior_create_function :: (o: *Ior, gid: u32, suffix: u32) {
    g := *o.groups[gid];
    ret := ir.t_void;
    for rid: g.regions {
        et := func_ret(glob(o.regions[rid].extracted_function).value_type);
        if (ret == ir.t_void && et != ir.t_void) || (ret == type_int(cast(u64) 1) && et == type_int(cast(u64) 16)) ret = et;
    }
    ft := type_func(ret, g.argument_types, false);
    nf := new_function(ft, "", dl.program_as);   // Function::Create(.., M): the program address space
    gv_set_linkage(nf, .INTERNAL);
    array_add(*ir.m_functions, nf);
    set_name(nf, tprint("outlined_ir_func_%", suffix));
    g.outlined_function = nf;
    if g.swift_error_argument >= 0 fn_add_param_attr_kind(nf, cast(u32) g.swift_error_argument, .SwiftError);
    fn_add_fn_attr_kind(nf, .OptimizeForSize);
    fn_add_fn_attr_kind(nf, .MinSize);
    sp := ior_subprogram_or_null(o, g);
    if sp != NONE {
        // DIBuilder(M, true, CU).createFunction(Unit, Name, Mangled name, Unit, 0, createSubroutineType({}), 0,
        // FlagArtificial, SPFlagDefinition | SPFlagOptimized): distinct, scope = the file, unit = the CU
        unit := di_op(sp, 5);
        file := di_op(sp, 0);
        sp_type := di_get(.SUBROUTINE_TYPE, false, .[NONE, NONE, NONE, NONE, NONE, md_tuple(.[], false)], .[0, 0]);
        name := md_string(vname(nf));
        linkage := md_string(ior_mangled_name(nf));
        new_sp := di_get(.SUBPROGRAM, true, .[file, file, name, linkage, sp_type, unit, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
                         .[0, 0, 0, 0, DI_FLAG_ARTIFICIAL, SPFLAG_DEFINITION | SPFLAG_OPTIMIZED, 0]);
        set_metadata(nf, MDK_DBG, new_sp);
    }
}
// Mangler::getNameWithPrefix(F, CannotUsePrivateLabel = false): an internal function gets the data layout's global
// prefix (none for ELF, '_' for Mach-O)
ior_mangled_name :: (f: Value_Id) -> string {
    for part: split(ir.datalayout, "-",, allocator = temp) {
        if part == "m:o" || part == "m:x" return tconcat("_", vname(f));
    }
    return vname(f);
}

// updateLoopMetadataDebugLocations with moveFunctionData's updater (a location becomes line:col in the new
// subprogram, without inlinedAt; nothing changes without a subprogram)
ior_update_loop_metadata :: (i: Value_Id, sp: Md_Id) {
    k_loop := md_fixed("llvm.loop");
    orig := get_metadata(i, k_loop);
    if orig == NONE return;
    updater :: (m: Md_Id, sp: Md_Id) -> Md_Id {
        if sp != NONE && m != NONE && is_di(m, .LOCATION) return di_location_get(diloc_line(m), diloc_col(m), sp, NONE);
        return m;
    }
    recursive :: (m: Md_Id, sp: Md_Id) -> Md_Id {
        if m == NONE || ir.mds[m].kind != .TUPLE || md_nops(m) < 1 return m;
        o0 := md_op(m, 0);
        if o0 == NONE || ir.mds[o0].kind != .STRING return m;
        updated := false;
        ops: [..] Md_Id; ops.allocator = temp;
        array_add(*ops, o0);
        for k: 1..cast(s64) md_nops(m) - 1 {
            x := md_op(m, cast(u32) k);
            if x == NONE { array_add(*ops, NONE); continue; }
            nx := updater(recursive(x, sp), sp);
            if nx != NONE array_add(*ops, nx);
            updated |= nx != x;
        }
        if updated return md_tuple(ops, false);
        return m;
    }
    ops: [..] Md_Id; ops.allocator = temp;
    array_add(*ops, NONE);
    n := cast(s64) md_nops(orig);
    if is_di(orig, .LOCATION) && diloc_inlined_at(orig) == NONE n = 1;
    for k: 1..n - 1 {
        x := md_op(orig, cast(u32) k);
        if x == NONE { array_add(*ops, NONE); continue; }
        nx := updater(recursive(x, sp), sp);
        if nx != NONE array_add(*ops, nx);
    }
    nl := md_tuple(ops, true);
    ir.md_ops[ir.mds[nl].ops] = nl;
    set_metadata(i, k_loop, nl);
}

// moveFunctionData
ior_move_function_data :: (old: Value_Id, nf: Value_Id, new_ends: *Table(Value_Id, Value_Id)) {
    sp := get_metadata(nf, MDK_DBG);
    b := glob(old).first_block;
    while b != NONE {
        nb := block(b).next;
        fn_unlink_block(old, b);
        fn_append_block(nf, b);
        t := block_terminator(b);
        if inst_op(t) == .RET {
            rv := ifx nops(t) > 0 then op(t, 0) else NONE;
            if !table_contains(new_ends, rv) table_set(new_ends, rv, b);
        }
        for i: block_insts(b) {
            drop_dbg_records(i);
            if inst_op(i) != .CALL {
                set_metadata(i, 0, NONE);
                ior_update_loop_metadata(i, sp);
                continue;
            }
            if sp != NONE set_metadata(i, 0, di_location_get(0, 0, sp, NONE));
        }
        b = nb;
    }
}

// findConstants
ior_find_constants :: (o: *Ior, c: u32, not_same: *Table(u32, bool), inputs: *[..] u32) {
    s := o.sim;
    seen: Table(u32, bool); seen.allocator = temp;
    for d: irsim_cand_rows(s, c) for v: s.data[d].ops {
        _, gvn := irsim_get_gvn(s, c, v);
        if is_const(v) && table_contains(not_same, gvn) && !table_contains(*seen, gvn) {
            table_set(*seen, gvn, true);
            array_add(inputs, gvn);
        }
    }
}

// getCodeExtractorArguments
ior_get_code_extractor_arguments :: (o: *Ior, rid: u32, input_gvns: *[..] u32, not_same: *Table(u32, bool), arg_inputs: *Value_Set, outputs: *Value_Set) {
    s := o.sim;
    r := *o.regions[rid];
    c := r.cand;
    overall: Value_Set; vset_init(*overall);
    premapped: Value_Set; vset_init(*premapped);
    sink: Value_Set; vset_init(*sink);
    hoist: Value_Set; vset_init(*hoist);
    dummy: Value_Set; vset_init(*dummy);
    ce_find_inputs_outputs(*r.ce, *overall, *dummy, *sink);
    orig_f := block_fn(r.start_bb);
    // CodeExtractorAnalysisCache CEAC(*OrigF): nothing changes the IR before its queries here, so it is built lazily
    // over the function's allocas (which splitting and reattaching candidates never change)
    allocas := table_find_pointer(*o.fn_allocas, orig_f);
    if !allocas allocas = table_set(*o.fn_allocas, orig_f, ce_function_allocas(orig_f));
    cache := ce_cache_lazy(allocas.*);
    if !ce_is_eligible(*r.ce) { r.ignore_region = true; return; }
    ce_find_allocas(*r.ce, *cache, *sink, *hoist);
    ce_find_inputs_outputs(*r.ce, *premapped, outputs, *sink);
    if overall.list.count != premapped.list.count { r.ignore_region = true; return; }
    ior_find_constants(o, c, not_same, input_gvns);
    // mapInputsToGVNs
    for input: overall.list {
        v := ior_find_output_mapping(o, input);
        f, gvn := irsim_get_gvn(s, c, v);
        if !f fatal("internal: iroutliner: could not find a numbering for the given input");
        array_add(input_gvns, gvn);
    }
    // remapExtractedInputs
    for input: premapped.list vset_insert(arg_inputs, ior_find_output_mapping(o, input));
    // stable_sort(InputGVNs)
    quick_sort(input_gvns.*, (a: u32, b: u32) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
}

// findExtractedInputToOverallInputMapping
ior_find_extracted_input_to_overall_input_mapping :: (o: *Ior, rid: u32, input_gvns: [] u32, arg_inputs: *Value_Set) {
    s := o.sim;
    r := *o.regions[rid];
    c := r.cand;
    g := *o.groups[r.parent];
    type_index: u32 = 0;
    original_index: u32 = 0;
    for input_val: input_gvns {
        f1, canon := irsim_canon(s, c, input_val);
        if !f1 fatal("internal: iroutliner: canonical number not found");
        f2, input := irsim_from_gvn(s, c, input_val);
        if !f2 fatal("internal: iroutliner: global value number not found");
        has_agg, agg := table_find(*g.canonical_number_to_agg_arg, canon);
        if !g.input_types_set {
            array_add(*g.argument_types, vtype(input));
            if is_swift_error(input) {
                // (an assertion in LLVM; a release build keeps the last one)
                g.swift_error_argument = type_index;
            }
        }
        if is_const(input) {
            if has_agg { if !table_contains(*r.agg_arg_to_constant, agg) table_set(*r.agg_arg_to_constant, agg, input); }
            else {
                table_set(*g.canonical_number_to_agg_arg, canon, type_index);
                if !table_contains(*r.agg_arg_to_constant, type_index) table_set(*r.agg_arg_to_constant, type_index, input);
            }
            type_index += 1;
            continue;
        }
        if !vset_contains(arg_inputs, input) fatal("internal: iroutliner: input cannot be found");
        if has_agg {
            if original_index != agg r.changed_arg_order = true;
            if !table_contains(*r.extracted_arg_to_agg, original_index) table_set(*r.extracted_arg_to_agg, original_index, agg);
            if !table_contains(*r.agg_arg_to_extracted, agg) table_set(*r.agg_arg_to_extracted, agg, original_index);
        } else {
            table_set(*g.canonical_number_to_agg_arg, canon, type_index);
            if !table_contains(*r.extracted_arg_to_agg, original_index) table_set(*r.extracted_arg_to_agg, original_index, type_index);
            if !table_contains(*r.agg_arg_to_extracted, type_index) table_set(*r.agg_arg_to_extracted, type_index, original_index);
        }
        original_index += 1;
        type_index += 1;
    }
    if !g.input_types_set {
        g.num_aggregate_inputs = type_index;
        g.input_types_set = true;
    }
    r.num_extracted_inputs = original_index;
}

// outputHasNonPHI
ior_output_has_non_phi :: (v: Value_Id, phi_loc: u32, pn: Value_Id, exits: [] Value_Id, blocks: [] Value_Id) -> bool {
    for k: 0..cast(s64) phi_num_incoming(pn) - 1 {
        if cast(u32) k != phi_loc && v == op(pn, cast(u32) k) && !ior_blocks_contains(blocks, phi_block(pn, cast(u32) k)) return true;
    }
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(usr) continue;
        parent := inst_block(usr);
        if ior_blocks_contains(blocks, parent) continue;
        if inst_op(usr) != .PHI return true;
        if !ior_blocks_contains(exits, parent) return true;
    }
    return false;
}

// analyzeExitPHIsForOutputUses
ior_analyze_exit_phis :: (exit_bb: Value_Id, exits: [] Value_Id, blocks: [] Value_Id, outputs: *Value_Set,
                          replaced_by_phi: *Table(Value_Id, bool), with_non_phi: *Table(Value_Id, bool)) -> bool {
    added_phi := false;
    for pn: block_insts(exit_bb) {
        if inst_op(pn) != .PHI break;
        incoming: [..] u32; incoming.allocator = temp;
        for k: 0..cast(s64) phi_num_incoming(pn) - 1 if ior_blocks_contains(blocks, phi_block(pn, cast(u32) k)) array_add(*incoming, cast(u32) k);
        if incoming.count == 0 continue;
        if incoming.count == 1 {
            v := op(pn, incoming[0]);
            table_set(with_non_phi, v, true);
            table_remove(replaced_by_phi, v);
            continue;
        }
        vset_insert(outputs, pn);
        added_phi = true;
        for idx: incoming {
            v := op(pn, idx);
            if !is_const(v) && ior_output_has_non_phi(v, idx, pn, exits, blocks) {
                table_set(with_non_phi, v, true);
                table_remove(replaced_by_phi, v);
                continue;
            }
            if !table_contains(with_non_phi, v) table_set(replaced_by_phi, v, true);
        }
    }
    return added_phi;
}

ior_phi_key :: (d: *Ior_Phi_Data) -> string {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "%,%:", d.bb_canon, d.agg_arg);
    for d.canons print_to_builder(*sb, "%,", it);
    return builder_to_string(*sb,, allocator = temp);
}

// getGVNForPHINode
ior_get_gvn_for_phi_node :: (o: *Ior, rid: u32, pn: Value_Id, blocks: [] Value_Id, agg_arg_idx: u32) -> bool, u32 {
    s := o.sim;
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    c := r.cand;
    phi_bb := inst_block(pn);
    data: Ior_Phi_Data; data.canons.allocator = temp;
    for k: 0..cast(s64) phi_num_incoming(pn) - 1 {
        incoming := op(pn, cast(u32) k);
        inc_block := phi_block(pn, cast(u32) k);
        if !ior_blocks_contains(blocks, inc_block) continue;
        f, gvn := irsim_get_gvn(s, c, incoming);
        if !f { r.ignore_region = true; return false, 0; }
        f2, canon := irsim_canon(s, c, gvn);
        if !f2 fatal("internal: iroutliner: no GVN found for incoming value");
        array_add(*data.canons, canon);
        fb, bgvn := irsim_get_gvn(s, c, inc_block);
        if !fb {
            if irsim_start_bb(s, c) != inc_block fatal("internal: iroutliner: unknown basic block used in exit path PHINode");
            preds: [..] Value_Id; preds.allocator = temp;
            block_predecessors(inc_block, *preds);
            prev: Value_Id = NONE;
            for p: preds if !ior_blocks_contains(blocks, p) { prev = p; break; }
            if prev == NONE fatal("internal: iroutliner: expected a predecessor not in the region");
            fb, bgvn = irsim_get_gvn(s, c, prev);
        }
        f3, bcanon := irsim_canon(s, c, bgvn);
        if !fb || !f3 fatal("internal: iroutliner: no GVN found for incoming block");
        array_add(*data.canons, bcanon);
    }
    fbb, bb_gvn := irsim_get_gvn(s, c, phi_bb);
    if !fbb fatal("internal: iroutliner: could not find GVN for the incoming block");
    fbc, bb_canon := irsim_canon(s, c, bb_gvn);
    if !fbc fatal("internal: iroutliner: could not find canonical number for the incoming block");
    data.bb_canon = bb_canon;
    data.agg_arg = agg_arg_idx;
    key := ior_phi_key(*data);
    found, num := table_find(*g.gvns_to_phi_node_gvn, key);
    if !found {
        if !table_contains(*g.phi_node_gvn_to_gvns, g.phi_node_gvn_tracker) table_set(*g.phi_node_gvn_to_gvns, g.phi_node_gvn_tracker, data);
        num = g.phi_node_gvn_tracker;
        table_set(*g.gvns_to_phi_node_gvn, key, num);
        g.phi_node_gvn_tracker -= 1;
    }
    return true, num;
}

// findExtractedOutputToOverallOutputMapping
ior_find_extracted_output_to_overall_output_mapping :: (o: *Ior, rid: u32, outputs: *Value_Set) {
    s := o.sim;
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    c := r.cand;
    blocks := irsim_cand_blocks(s, c);
    exits: [..] Value_Id; exits.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    for b: blocks {
        succs.count = 0;
        block_successors(b, *succs);
        for sc: succs if !ior_blocks_contains(blocks, sc) && !ior_blocks_contains(exits, sc) array_add(*exits, sc);
    }
    replaced_by_phi: Table(Value_Id, bool); replaced_by_phi.allocator = temp;
    with_non_phi: Table(Value_Id, bool); with_non_phi.allocator = temp;
    phi_exits := 0;
    for e: exits if ior_analyze_exit_phis(e, exits, blocks, outputs, *replaced_by_phi, *with_non_phi) phi_exits += 1;
    if exits.count > 1 && phi_exits > 1
        fatal("iroutliner: the order of the PHINode outputs of a region with several exit blocks depends on the heap address order in LLVM (SmallPtrSet of blocks); not reproducible");
    original_index := r.num_extracted_inputs;
    type_index := g.num_aggregate_inputs;
    agg_args_used: Table(u32, bool); agg_args_used.allocator = temp;
    for output: outputs.list {
        type_found := false;
        arg_size := cast(u32) g.argument_types.count;
        if table_contains(*replaced_by_phi, output) continue;
        agg_arg_idx: u32 = 0;
        jdx := type_index;
        while jdx < arg_size {
            defer jdx += 1;
            if !is_ptr_type(g.argument_types[jdx]) continue;
            if table_contains(*agg_args_used, jdx) continue;
            table_set(*agg_args_used, jdx, true);
            type_found = true;
            if !table_contains(*r.extracted_arg_to_agg, original_index) table_set(*r.extracted_arg_to_agg, original_index, jdx);
            if !table_contains(*r.agg_arg_to_extracted, jdx) table_set(*r.agg_arg_to_extracted, jdx, original_index);
            agg_arg_idx = jdx;
            break;
        }
        if !type_found {
            array_add(*g.argument_types, type_ptr(dl_alloca_addrspace()));
            idx := cast(u32) g.argument_types.count - 1;
            table_set(*agg_args_used, idx, true);
            if !table_contains(*r.extracted_arg_to_agg, original_index) table_set(*r.extracted_arg_to_agg, original_index, idx);
            if !table_contains(*r.agg_arg_to_extracted, idx) table_set(*r.agg_arg_to_extracted, idx, original_index);
            agg_arg_idx = idx;
        }
        gvn: u32;
        if is_inst(output) && inst_op(output) == .PHI && !ior_blocks_contains(blocks, inst_block(output)) {
            ok, n := ior_get_gvn_for_phi_node(o, rid, output, blocks, agg_arg_idx);
            if !ok return;
            gvn = n;
        } else {
            f1, n := irsim_get_gvn(s, c, output);
            f2, cn := irsim_canon(s, c, n);
            if !f1 || !f2 fatal("internal: iroutliner: no canonical number for an output");
            gvn = cn;
        }
        array_add(*r.gvn_stores, gvn);
        original_index += 1;
        type_index += 1;
    }
    quick_sort(r.gvn_stores, (a: u32, b: u32) -> s64 { return ifx a < b then -1 else ifx a > b then 1 else 0; });
}

// findAddInputsOutputs
ior_find_add_inputs_outputs :: (o: *Ior, rid: u32, not_same: *Table(u32, bool)) {
    inputs: [..] u32; inputs.allocator = temp;
    arg_inputs: Value_Set; vset_init(*arg_inputs);
    outputs: Value_Set; vset_init(*outputs);
    ior_get_code_extractor_arguments(o, rid, *inputs, not_same, *arg_inputs, *outputs);
    if o.regions[rid].ignore_region return;
    ior_find_extracted_input_to_overall_input_mapping(o, rid, inputs, *arg_inputs);
    ior_find_extracted_output_to_overall_output_mapping(o, rid, *outputs);
}

// replaceCalledFunction
ior_replace_called_function :: (o: *Ior, rid: u32) -> Value_Id {
    s := o.sim;
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    call := r.call;
    agg := g.outlined_function;
    nargs := func_nparams(glob(agg).value_type);
    if !r.changed_arg_order && nargs == call_arg_count(call) {
        call_set_called_function(call, agg);
        return call;
    }
    args: [..] Value_Id; args.allocator = temp;
    for agg_idx: 0..cast(s64) nargs - 1 {
        ai := cast(u32) agg_idx;
        if ai == nargs - 1 && g.output_gvn_combinations.count > 1 {
            array_add(*args, const_int(type_int(cast(u64) 32), cast(u64) r.output_block_num));
            continue;
        }
        f, ext := table_find(*r.agg_arg_to_extracted, ai);
        if f { array_add(*args, call_arg(call, ext)); continue; }
        fc, cst := table_find(*r.agg_arg_to_constant, ai);
        if fc { array_add(*args, cst); continue; }
        array_add(*args, const_null(vtype(fn_arg(agg, ai))));
    }
    nc := create_call_fn(agg, args);
    // CallInst::Create(.., Call->getIterator()): without the head bit the new call adopts the debug records in
    // front of the old one
    inst_insert_before(nc, call);
    recs := records_take(call);
    if recs attach_records_before(nc, recs);
    old := r.call;
    if s.data[r.new_front].inst == old s.data[r.new_front].inst = nc;
    if s.data[r.new_back].inst == old s.data[r.new_back].inst = nc;
    set_metadata(nc, 0, get_metadata(old, 0));
    replace_all_uses_with(old, nc);
    erase_inst(old);
    r.call = nc;
    if g.swift_error_argument >= 0 call_add_param_attr_kind(nc, cast(u32) g.swift_error_argument, .SwiftError);
    return nc;
}

// findOrCreatePHIBlock
ior_find_or_create_phi_block :: (o: *Ior, gid: u32, ret_val: Value_Id) -> Value_Id {
    g := *o.groups[gid];
    f, existing := table_find(*g.phi_blocks, ret_val);
    if f return existing;
    fr, ret_bb := table_find(*g.end_bbs, ret_val);
    if !fr fatal("internal: iroutliner: could not find output value");
    pb := create_block(block_fn(ret_bb), "phi_block");
    table_set(*g.phi_blocks, ret_val, pb);
    // ReturnBB->replaceAllUsesWith(PHIBlock) (Value::doRAUW also rewires the successors' phis; a return block has none)
    replace_all_uses_with(ret_bb, pb);
    block_append_inst(pb, create_br(ret_bb));
    return pb;
}

// findCanonNumsForPHI
ior_find_canon_nums_for_phi :: (o: *Ior, pn: Value_Id, rid: u32, canons: *[..] u32, blocks: *[..] Value_Id, replaced_with_outlined_call: bool) {
    s := o.sim;
    r := *o.regions[rid];
    for k: 0..cast(s64) phi_num_incoming(pn) - 1 {
        ival := op(pn, cast(u32) k);
        iblock := phi_block(pn, cast(u32) k);
        if vkind(ival) == .ARGUMENT {
            argno := arg_numbers[ir.v_aux[ival]];
            if replaced_with_outlined_call ival = call_arg(r.call, argno);
            else {
                fc, cst := table_find(*r.agg_arg_to_constant, argno);
                if fc ival = cst;
                else {
                    _, ext := table_find(*r.agg_arg_to_extracted, argno);
                    ival = call_arg(r.call, ext);
                }
            }
        }
        ival = ior_find_output_mapping(o, ival);
        f1, gvn := irsim_get_gvn(s, r.cand, ival);
        if !f1 fatal("internal: iroutliner: no GVN for incoming value");
        f2, canon := irsim_canon(s, r.cand, gvn);
        if !f2 fatal("internal: iroutliner: no canonical number for GVN");
        array_add(canons, canon);
        array_add(blocks, iblock);
    }
}

// findOrCreatePHIInBlock
ior_find_or_create_phi_in_block :: (o: *Ior, pn: Value_Id, rid: u32, overall_phi_block: Value_Id, used_phis: *Table(Value_Id, bool)) -> Value_Id {
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    pn_canons: [..] u32; pn_canons.allocator = temp;
    pn_blocks: [..] Value_Id; pn_blocks.allocator = temp;
    ior_find_canon_nums_for_phi(o, pn, rid, *pn_canons, *pn_blocks, false);
    first := g.regions[0];
    cur_canons: [..] u32; cur_canons.allocator = temp;
    cur_blocks: [..] Value_Id; cur_blocks.allocator = temp;
    for cur: block_insts(overall_phi_block) {
        if inst_op(cur) != .PHI break;
        if table_contains(used_phis, cur) continue;
        cur_canons.count = 0; cur_blocks.count = 0;
        ior_find_canon_nums_for_phi(o, cur, first, *cur_canons, *cur_blocks, true);
        if pn_canons.count != cur_canons.count continue;
        match := true;
        for k: 0..pn_canons.count - 1 {
            if cur_canons[k] != pn_canons[k] { match = false; break; }
            cb := ior_find_corresponding_block_in(o, rid, first, pn_blocks[k]);
            if cb == NONE fatal("internal: iroutliner: found block is nullptr");
            if cb != cur_blocks[k] { match = false; break; }
        }
        if match {
            table_set(used_phis, cur, true);
            return cur;
        }
    }
    np := inst_clone(pn);
    inst_insert_before(np, block_first(overall_phi_block));
    for k: 0..cast(s64) phi_num_incoming(np) - 1 {
        iv := op(np, cast(u32) k);
        ib := phi_block(np, cast(u32) k);
        phi_set_block(np, cast(u32) k, ior_find_corresponding_block_in(o, rid, first, ib));
        if vkind(iv) == .ARGUMENT {
            set_op(np, cast(u32) k, fn_arg(g.outlined_function, arg_numbers[ir.v_aux[iv]]));
            continue;
        }
        iv = ior_find_output_mapping(o, iv);
        v := ior_find_corresponding_value_in(o, rid, first, iv);
        if v == NONE fatal("internal: iroutliner: value is nullptr");
        fr, rm := table_find(*o.regions[first].remapped_arguments, v);
        if fr v = rm;
        set_op(np, cast(u32) k, v);
    }
    return np;
}

// replaceArgumentUses
ior_replace_argument_uses :: (o: *Ior, rid: u32, output_bbs: *Table(Value_Id, Value_Id), first_function := false) {
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    s := o.sim;
    ef := r.extracted_function;
    dom_fn := ifx first_function then g.outlined_function else ef;
    dt := dt_new(false);
    dt_recalculate(dt, dom_fn);
    used_phis: Table(Value_Id, bool); used_phis.allocator = temp;
    nargs := func_nparams(glob(ef).value_type);
    for arg_idx: 0..cast(s64) nargs - 1 {
        ai := cast(u32) arg_idx;
        fm, agg_idx := table_find(*r.extracted_arg_to_agg, ai);
        if !fm fatal("internal: iroutliner: no mapping from extracted to outlined");
        agg_arg := fn_arg(g.outlined_function, agg_idx);
        arg := fn_arg(ef, ai);
        if ai < r.num_extracted_inputs {
            replace_all_uses_with(arg, agg_arg);
            v := call_arg(r.call, ai);
            if !table_contains(*r.remapped_arguments, v) table_set(*r.remapped_arguments, v, agg_arg);
            continue;
        }
        u0 := ir.v_first_use[arg];
        if u0 == NONE || ir.u_next[u0] != NONE fatal("internal: iroutliner: output argument can only have one use");
        i := ir.u_user[u0];
        bb := inst_block(i);
        desc: [..] Value_Id; desc.allocator = temp;
        dt_get_descendants(dt, bb, *desc);
        edge_added := false;
        if desc.count == 0 {
            edge_added = true;
            dt_insert_edge(dt, fn_entry(dom_fn), bb);
            dt_get_descendants(dt, bb, *desc);
        }
        for d: desc {
            t := block_terminator(d);
            if inst_op(t) != .RET continue;
            ret_val := ifx nops(t) > 0 then op(t, 0) else NONE;
            fo, out_bb := table_find(output_bbs, ret_val);
            if !fo fatal("internal: iroutliner: could not find output value");
            if inst_op(i) != .STORE fatal("internal: iroutliner: an output argument used by a non-store");
            value_operand := op(i, 0);
            ni := inst_clone(i);
            set_metadata(ni, 0, NONE);
            block_append_inst(out_bb, ni);
            has_gvn, _ := irsim_get_gvn(s, r.cand, value_operand);
            if !(is_inst(value_operand) && inst_op(value_operand) == .PHI) || has_gvn {
                if first_function continue;
                corr := ior_find_corresponding_value_in(o, rid, g.regions[0], value_operand);
                if corr == NONE fatal("internal: iroutliner: value is nullptr");
                set_op(ni, 0, corr);
                continue;
            }
            pn := value_operand;
            if !table_contains(*r.phi_blocks, ret_val) table_set(*r.phi_blocks, ret_val, inst_block(pn));
            if first_function {
                if !table_contains(*g.phi_blocks, ret_val) table_set(*g.phi_blocks, ret_val, inst_block(pn));
                continue;
            }
            overall := ior_find_or_create_phi_block(o, r.parent, ret_val);
            np := ior_find_or_create_phi_in_block(o, pn, rid, overall, *used_phis);
            set_op(ni, 0, np);
        }
        if edge_added dt_delete_edge(dt, fn_entry(dom_fn), bb);
        erase_inst(i);
        replace_all_uses_with(arg, agg_arg);
    }
}

// replaceConstants: RemapFunction(*OutlinedFunction, VMap, RF_NoModuleLevelChanges | RF_IgnoreMissingLocals)
ior_replace_constants :: (o: *Ior, rid: u32) {
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    vm: Value_Map; vmap_init(*vm);
    for cst, agg: r.agg_arg_to_constant vmap_set(*vm, cst, fn_arg(g.outlined_function, agg));
    flags: u32 = RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS;
    for b: fn_blocks(g.outlined_function) for i: block_insts(b) {
        remap_instruction(*vm, i, flags);
        remap_dbg_record_range(*vm, i, flags);
    }
}

// findDuplicateOutputBlock
ior_find_duplicate_output_block :: (output_bbs: *Table(Value_Id, Value_Id), store_bbs: *[..] Table(Value_Id, Value_Id)) -> bool, u32 {
    matching: u32 = 0;
    for * comp: store_bbs.* {
        mismatch := false;
        for comp_bb, key: comp.* {
            fo, out_bb := table_find(output_bbs, key);
            if !fo { mismatch = true; break; }
            if ior_block_size(comp_bb) - 1 != ior_block_size(out_bb) { mismatch = true; break; }
            n := block_first(out_bb);
            for x: block_insts(comp_bb) {
                if inst_op(x) == .BR || inst_op(x) == .CONDBR continue;
                if !inst_identical_to(x, n) { mismatch = true; break; }
                n = inst_next(n);
            }
            if mismatch break;
        }
        if !mismatch return true, matching;
        matching += 1;
    }
    return false, 0;
}
ior_block_size :: (b: Value_Id) -> s64 { n := 0; for block_insts(b) n += 1; return n; }
// Instruction::isIdenticalTo: isIdenticalToWhenDefined plus the same SubclassOptionalData
inst_identical_to :: (a: Value_Id, b: Value_Id) -> bool {
    if (inst(a).flags & OPTIONAL_FLAG_MASK) != (inst(b).flags & OPTIONAL_FLAG_MASK) return false;
    return inst_identical_when_defined(a, b);
}

// analyzeAndPruneOutputBlocks
ior_analyze_and_prune_output_blocks :: (o: *Ior, blocks: *Table(Value_Id, Value_Id), rid: u32) -> bool {
    all_removed := true;
    to_remove: [..] Value_Id; to_remove.allocator = temp;
    for bb, rv: blocks.* {
        if block_first(bb) == NONE {
            block_erase_from_parent(bb);
            array_add(*to_remove, rv);
            continue;
        }
        all_removed = false;
    }
    for to_remove table_remove(blocks, it);
    if all_removed o.regions[rid].output_block_num = 0xFFFF_FFFF;
    return all_removed;
}

// alignOutputBlockWithAggFunc
ior_align_output_block_with_agg_func :: (o: *Ior, gid: u32, rid: u32, output_bbs: *Table(Value_Id, Value_Id), end_bbs: *Table(Value_Id, Value_Id), store_bbs: *[..] Table(Value_Id, Value_Id)) {
    if ior_analyze_and_prune_output_blocks(o, output_bbs, rid) return;
    found, m := ior_find_duplicate_output_block(output_bbs, store_bbs);
    if found {
        o.regions[rid].output_block_num = m;
        for bb: output_bbs.* block_erase_from_parent(bb);
        return;
    }
    o.regions[rid].output_block_num = cast(u32) store_bbs.count;
    nt: Table(Value_Id, Value_Id); nt.allocator = temp;
    for bb, rv: output_bbs.* {
        _, eb := table_find(end_bbs, rv);
        block_append_inst(bb, create_br(eb));
        table_set(*nt, rv, bb);
    }
    array_add(store_bbs, nt);
}

// getSortedConstantKeys + createAndInsertBasicBlocks
ior_create_and_insert_basic_blocks :: (old_map: *Table(Value_Id, Value_Id), new_map: *Table(Value_Id, Value_Id), parent: Value_Id, base: string) {
    keys: [..] Value_Id; keys.allocator = temp;
    for _, k: old_map.* array_add(*keys, k);
    if keys.count != 1 {
        for keys if it == NONE || vkind(it) != .C_INT fatal("internal: iroutliner: expected constant integer return values");
        // stable_sort by getLimitedValue (the keys are distinct constants)
        quick_sort(keys, (a: Value_Id, b: Value_Id) -> s64 {
            x := const_int_limited_value(a); y := const_int_limited_value(b);
            return ifx x < y then -1 else ifx x > y then 1 else 0;
        });
    }
    for rv, idx: keys {
        nb := create_block(parent, tprint("%_%", base, idx));
        table_set(new_map, rv, nb);
    }
}
const_int_limited_value :: (c: Value_Id) -> u64 {
    // getLimitedValue(): the value if it fits in 64 bits (these are i1 / i16 / i32 switch values)
    return const_int_zext(c);
}

// createSwitchStatement
ior_create_switch_statement :: (o: *Ior, gid: u32, end_bbs: *Table(Value_Id, Value_Id), store_bbs: *[..] Table(Value_Id, Value_Id)) {
    g := *o.groups[gid];
    if g.output_gvn_combinations.count > 1 {
        agg := g.outlined_function;
        return_bbs: Table(Value_Id, Value_Id); return_bbs.allocator = temp;
        ior_create_and_insert_basic_blocks(*g.end_bbs, *return_bbs, agg, "final_block");
        nargs := func_nparams(glob(agg).value_type);
        for return_block, rv: return_bbs {
            _, end_bb := table_find(*g.end_bbs, rv);
            term := block_terminator(end_bb);
            inst_unlink(term);
            block_append_inst(return_block, term);
            sw := create_switch(fn_arg(agg, nargs - 1), return_block, cast(u32) store_bbs.count);
            block_append_inst(end_bb, sw);
            idx: u64 = 0;
            for * osbb: store_bbs.* {
                fb, bb := table_find(osbb, rv);
                if !fb continue;
                sw_add_case(sw, const_int(type_int(cast(u64) 32), idx), bb);
                set_successor(block_terminator(bb), 0, return_block);
                idx += 1;
            }
        }
        return;
    }
    if store_bbs.count >= 2 fatal("internal: iroutliner: different store sets not handled");
    if store_bbs.count == 1 {
        for out_bb, rv: store_bbs.*[0] {
            fe, end_bb := table_find(end_bbs, rv);
            if !fe fatal("internal: iroutliner: could not find end block");
            erase_inst(block_terminator(out_bb));
            term := block_terminator(end_bb);
            block_move_all_insts_to_end(end_bb, out_bb);
            inst_unlink(term);
            block_append_inst(end_bb, term);
            block_erase_from_parent(out_bb);
        }
    }
}

// fillOverallFunction
ior_fill_overall_function :: (o: *Ior, gid: u32, store_bbs: *[..] Table(Value_Id, Value_Id), funcs_to_remove: *[..] Value_Id) {
    g := *o.groups[gid];
    rid := g.regions[0];
    ef := o.regions[rid].extracted_function;
    ior_move_function_data(ef, g.outlined_function, *g.end_bbs);
    // TTI.shouldCopyAttributeWhenOutliningFrom: true on X86
    // (a copy: adding attributes can move the attribute pool the items point into)
    items: [..] Attr; items.allocator = temp;
    for at: attr_set_items(attr_list_fn(glob(ef).attrs)) array_add(*items, at);
    for at: items {
        // (fn_add_fn_attr replaces by kind: every string attribute is one kind there)
        if at.kind == .STRING_ATTR fn_add_fn_str_attr(g.outlined_function, at.key, at.val);
        else fn_add_fn_attr(g.outlined_function, at);
    }
    new_bbs: Table(Value_Id, Value_Id); new_bbs.allocator = temp;
    ior_create_and_insert_basic_blocks(*g.end_bbs, *new_bbs, g.outlined_function, "output_block_0");
    o.regions[rid].output_block_num = 0;
    ior_replace_argument_uses(o, rid, *new_bbs, true);
    ior_replace_constants(o, rid);
    if !ior_analyze_and_prune_output_blocks(o, *new_bbs, rid) {
        nt: Table(Value_Id, Value_Id); nt.allocator = temp;
        for bb, rv: new_bbs {
            _, eb := table_find(*g.end_bbs, rv);
            block_append_inst(bb, create_br(eb));
            table_set(*nt, rv, bb);
        }
        array_add(store_bbs, nt);
    }
    o.regions[rid].call = ior_replace_called_function(o, rid);
    array_add(funcs_to_remove, ef);
}

// deduplicateExtractedSections
ior_deduplicate_extracted_sections :: (o: *Ior, gid: u32, funcs_to_remove: *[..] Value_Id, num: *u32) {
    ior_create_function(o, gid, num.*);
    store_bbs: [..] Table(Value_Id, Value_Id); store_bbs.allocator = temp;
    ior_fill_overall_function(o, gid, *store_bbs, funcs_to_remove);
    g := *o.groups[gid];
    for idx: 1..g.regions.count - 1 {
        rid := g.regions[idx];
        merge_attributes_for_inlining(g.outlined_function, o.regions[rid].extracted_function);
        new_bbs: Table(Value_Id, Value_Id); new_bbs.allocator = temp;
        ior_create_and_insert_basic_blocks(*g.end_bbs, *new_bbs, g.outlined_function, tprint("output_block_%", idx));
        ior_replace_argument_uses(o, rid, *new_bbs);
        ior_align_output_block_with_agg_func(o, gid, rid, *new_bbs, *g.end_bbs, *store_bbs);
        o.regions[rid].call = ior_replace_called_function(o, rid);
        array_add(funcs_to_remove, o.regions[rid].extracted_function);
    }
    ior_create_switch_statement(o, gid, *g.end_bbs, *store_bbs);
    num.* += 1;
}

// nextIRInstructionDataMatchesNextInst
ior_next_data_matches_next_inst :: (o: *Ior, d: u32) -> bool {
    s := o.sim;
    nd := s.data[d].next;
    if nd == IRSIM_NULL fatal("internal: iroutliner: walked off the instruction data list");
    next_idl_inst := s.data[nd].inst;
    next_module_inst: Value_Id = NONE;
    i := s.data[d].inst;
    if !is_terminator(inst_op(i)) next_module_inst = inst_next(i);
    else if next_idl_inst != NONE next_module_inst = block_first(inst_block(next_idl_inst));
    if next_idl_inst != NONE && next_idl_inst != next_module_inst return false;
    return true;
}

// isCompatibleWithAlreadyOutlinedCode
ior_is_compatible_with_already_outlined_code :: (o: *Ior, rid: u32) -> bool {
    s := o.sim;
    c := o.regions[rid].cand;
    for idx: s.cands[c].start_idx..irsim_end_idx(s, c) if table_contains(*o.outlined, idx) return false;
    back := irsim_back_inst(s, c);
    if !is_terminator(inst_op(back)) {
        new_end := inst_next(back);
        if new_end == NONE fatal("internal: iroutliner: next instruction is a nullptr");
        if s.data[irsim_cand_end(s, c)].inst != new_end {
            nd := irsim_new_data(s, new_end, ior_instruction_allowed(o, new_end));
            irsim_ilist_insert_before(s, irsim_cand_end(s, c), nd);
        }
    }
    for d: irsim_cand_rows(s, c) {
        if !ior_next_data_matches_next_inst(o, d) return false;
        if !ior_instruction_allowed(o, s.data[d].inst) return false;
    }
    return true;
}

// pruneIncompatibleRegions
ior_prune_incompatible_regions :: (o: *Ior, cands: *[..] u32, gid: u32) {
    s := o.sim;
    // stable_sort by start index
    Keyed :: struct { c: u32; pos: s64; }
    ks: [..] Keyed; ks.allocator = temp;
    for cands.* array_add(*ks, .{it, it_index});
    quick_sort(ks, (a: Keyed, b: Keyed) -> s64 {
        sa := irsim.cands[a.c].start_idx; sb := irsim.cands[b.c].start_idx;
        if sa != sb return ifx sa < sb then -1 else 1;
        return a.pos - b.pos;
    });
    for ks cands.*[it_index] = it.c;
    first := cands.*[0];
    if s.cands[first].len == 2 {
        fi := irsim_front_inst(s, first); bi := irsim_back_inst(s, first);
        if inst_op(fi) == .CALL && (inst_op(bi) == .BR || inst_op(bi) == .CONDBR) return;
    }
    current_end: u32 = 0;
    for c: cands.* {
        start := s.cands[c].start_idx;
        end := irsim_end_idx(s, c);
        f := irsim_function(s, c);
        prev_outlined := false;
        for idx: start..end if table_contains(*o.outlined, idx) { prev_outlined = true; break; }
        if prev_outlined continue;
        rows := irsim_cand_rows(s, c);
        addr_taken := false;
        for d: rows if block_has_address_taken(inst_block(s.data[d].inst)) { addr_taken = true; break; }
        if addr_taken continue;
        if fn_has_fn_attr(f, .OptimizeNone) continue;
        if fn_has_fn_attr(f, .NoOutline) continue;
        if glob(f).linkage == .LINKONCE_ODR && !o.outline_from_linkonceodr continue;
        if current_end != 0 && start <= current_end continue;
        bad := false;
        for d: rows {
            if !ior_next_data_matches_next_inst(o, d) { bad = true; break; }
            if !ior_instruction_allowed(o, s.data[d].inst) { bad = true; break; }
        }
        if bad continue;
        rid := ior_init_region(o, c, gid);
        array_add(*o.groups[gid].regions, rid);
        current_end = end;
    }
}
irsim_function :: (s: *Irsim, c: u32) -> Value_Id { return block_fn(irsim_start_bb(s, c)); }

// findBenefitFromAllRegions
ior_find_benefit_from_all_regions :: (o: *Ior, gid: u32) -> Cost {
    b: Cost = 0;
    for rid: o.groups[gid].regions b = cost_add(b, ior_get_benefit(o, rid));
    return b;
}
// findOutputValueInRegion
ior_find_output_value_in_region :: (o: *Ior, rid: u32, canon_in: u32) -> Value_Id {
    s := o.sim;
    r := *o.regions[rid];
    g := *o.groups[r.parent];
    canon := canon_in;
    if canon > g.phi_node_gvn_tracker {
        p := table_find_pointer(*g.phi_node_gvn_to_gvns, canon);
        if !p || p.canons.count == 0 fatal("internal: iroutliner: could not find GVN set for PHINode number");
        canon = p.canons[0];
    }
    f1, gvn := irsim_from_canon(s, r.cand, canon);
    if !f1 fatal("internal: iroutliner: could not find GVN for canonical number");
    f2, v := irsim_from_gvn(s, r.cand, gvn);
    if !f2 fatal("internal: iroutliner: could not find value for GVN");
    return v;
}
// findCostOutputReloads
ior_find_cost_output_reloads :: (o: *Ior, gid: u32) -> Cost {
    c: Cost = 0;
    for rid: o.groups[gid].regions {
        t := tti_get(block_fn(o.regions[rid].start_bb));
        for canon: o.regions[rid].gvn_stores {
            v := ior_find_output_value_in_region(o, rid, canon);
            c = cost_add(c, tti_memory_op_cost(t, .LOAD, vtype(v), 1, 0, TCK_CODE_SIZE));
        }
    }
    return c;
}
// findCostForOutputBlocks
ior_find_cost_for_output_blocks :: (o: *Ior, gid: u32, t: *Tti) -> Cost {
    s := o.sim;
    g := *o.groups[gid];
    cost: Cost = 0;
    num_output_branches: u32 = 0;
    first := g.regions[0];
    c := o.regions[first].cand;
    blocks := irsim_cand_blocks(s, c);
    found: [..] Value_Id; found.allocator = temp;
    for d: irsim_cand_rows(s, c) {
        op := inst_op(s.data[d].inst);
        if op != .BR && op != .CONDBR continue;
        for v: s.data[d].ops {
            if !ior_blocks_contains(blocks, v) && !ior_blocks_contains(found, v) { array_add(*found, v); num_output_branches += 1; }
        }
    }
    g.branches_to_outside = num_output_branches;
    for use: g.output_gvn_combinations {
        for canon: use {
            v := ior_find_output_value_in_region(o, first, canon);
            sc := tti_memory_op_cost(t, .LOAD, vtype(v), 1, 0, TCK_CODE_SIZE);
            cost = cost_add(cost, cost_mul(sc, num_output_branches));
        }
        bc := tti_cf_cost(t, .BR, TCK_CODE_SIZE);
        cost = cost_add(cost, cost_mul(bc, num_output_branches));
    }
    if g.output_gvn_combinations.count > 1 {
        i32t := type_int(cast(u64) 32);
        cc := tti_cmp_sel_cost(t, .ICMP, i32t, i32t, BAD_ICMP_PREDICATE, TCK_CODE_SIZE);
        bc := tti_cf_cost(t, .CONDBR, TCK_CODE_SIZE);
        total := cost_mul(cost_mul(cc, bc), g.output_gvn_combinations.count);
        cost = cost_add(cost, cost_mul(total, num_output_branches));
    }
    return cost;
}
// findCostBenefit
ior_find_cost_benefit :: (o: *Ior, gid: u32) {
    g := *o.groups[gid];
    region_benefit := ior_find_benefit_from_all_regions(o, gid);
    g.benefit = cost_add(g.benefit, region_benefit);
    g.cost = cost_add(g.cost, ior_find_cost_output_reloads(o, gid));
    avg := region_benefit;
    if cost_valid(avg) avg = region_benefit / g.regions.count;
    num_args := g.argument_types.count;
    num_regions := g.regions.count;
    t := tti_get(irsim_function(o.sim, o.regions[g.regions[0]].cand));
    g.cost = cost_add(g.cost, avg);
    g.cost = cost_add(g.cost, num_args * TCC_BASIC);
    g.cost = cost_add(g.cost, 2 * num_args * TCC_BASIC * num_regions);
    g.cost = cost_add(g.cost, ior_find_cost_for_output_blocks(o, gid, t));
}
// InstructionCost::operator>= (an invalid cost is larger than every valid one)
ior_cost_ge :: (a: Cost, b: Cost) -> bool {
    va := cost_valid(a); vb := cost_valid(b);
    if va != vb return !va;
    return a >= b;
}

// updateOutputMapping
ior_update_output_mapping :: (o: *Ior, rid: u32, outputs: [] Value_Id, li: Value_Id) {
    r := *o.regions[rid];
    operand := op(li, 0);
    idx: s64 = -1;
    for k: r.num_extracted_inputs..call_arg_count(r.call) - 1 {
        if operand == call_arg(r.call, k) { idx = cast(s64) (k - r.num_extracted_inputs); break; }
    }
    if idx < 0 return;
    out := outputs[idx];
    f, orig := table_find(*o.output_mappings, out);
    if !table_contains(*o.output_mappings, li) table_set(*o.output_mappings, li, ifx f then orig else out);
}

// extractSection
ior_extract_section :: (o: *Ior, rid: u32) -> bool {
    s := o.sim;
    r := *o.regions[rid];
    initial_start := r.start_bb;
    orig_f := block_fn(r.start_bb);
    cache := ce_cache_new(orig_f);
    inputs: [..] Value_Id; inputs.allocator = temp;
    outputs: [..] Value_Id; outputs.allocator = temp;
    if ior_debug write_string(tprint("== before extraction\n%", print_module_fresh()), to_standard_error = true);
    r.extracted_function = ce_extract_code_region(*r.ce, *cache, *inputs, *outputs);
    if ior_debug write_string(tprint("== after extraction\n%", print_module_fresh()), to_standard_error = true);
    if r.extracted_function == NONE {
        ior_reattach_candidate(o, rid);
        return false;
    }
    usr := ir.u_user[ir.v_first_use[r.extracted_function]];
    rewritten := inst_block(usr);
    r.prev_bb = block_single_predecessor(rewritten);
    if r.prev_bb == NONE fatal("internal: iroutliner: PrevBB is nullptr");
    if r.prev_bb == initial_start {
        new_prev := block_single_predecessor(initial_start);
        erase_inst(block_terminator(new_prev));
        block_move_all_insts_to_end(new_prev, initial_start);
        r.prev_bb = new_prev;
        block_erase_from_parent(initial_start);
    }
    r.start_bb = rewritten;
    r.end_bb = rewritten;
    c := r.cand;
    begin_rewritten := block_first(rewritten);
    r.new_front = irsim_new_data(s, begin_rewritten, ior_instruction_allowed(o, begin_rewritten));
    r.new_back = irsim_new_data(s, begin_rewritten, ior_instruction_allowed(o, begin_rewritten));
    irsim_ilist_insert_before(s, s.cands[c].first, r.new_front);
    irsim_ilist_insert_before(s, irsim_cand_end(s, c), r.new_back);
    // IDL->erase(Candidate->begin(), std::prev(Candidate->end()))
    end := irsim_cand_end(s, c);
    irsim_ilist_erase_range(s, s.cands[c].first, s.data[end].prev);
    for i: block_insts(rewritten) {
        if inst_op(i) == .CALL {
            if call_called_function(i) == r.extracted_function r.call = i;
        } else if inst_op(i) == .LOAD {
            ior_update_output_mapping(o, rid, outputs, i);
        }
    }
    ior_reattach_candidate(o, rid);
    if ior_debug write_string(tprint("== after reattach\n%", print_module_fresh()), to_standard_error = true);
    return true;
}
ior_debug := false;

// IROutliner::doOutline
ior_do_outline :: (o: *Ior) -> u32 {
    s := o.sim;
    o.enable_branches = !irsim_cl.disable_branches;
    o.enable_indirect_calls = !irsim_cl.disable_indirect_calls;
    o.enable_intrinsics = !irsim_cl.disable_intrinsics;
    // stable_sort of the groups by length * count, largest first
    if s.groups.count > 1 {
        Keyed :: struct { g: [..] u32; w: u64; pos: s64; }
        ks: [..] Keyed; ks.allocator = temp;
        for s.groups array_add(*ks, .{it, cast(u64) s.cands[it[0]].len * cast(u64) it.count, it_index});
        quick_sort(ks, (a: Keyed, b: Keyed) -> s64 {
            if a.w != b.w return ifx a.w > b.w then -1 else 1;
            return a.pos - b.pos;
        });
        for ks s.groups[it_index] = it.g;
    }
    num: u32 = 0;
    array_resize(*o.groups, s.groups.count);
    for * o.groups ior_init_group(it);
    not_same: Table(u32, bool); not_same.allocator = temp;
    negative_cost_groups: [..] u32; negative_cost_groups.allocator = temp;
    outlined_regions: [..] u32; outlined_regions.allocator = temp;
    for * cand_vec, gid: s.groups {
        ior_prune_incompatible_regions(o, cand_vec, cast(u32) gid);
        g := *o.groups[gid];
        if g.regions.count < 2 continue;
        table_reset(*not_same);
        // findSameConstants
        gvn_to_constant: Table(u32, Value_Id); gvn_to_constant.allocator = temp;
        for rid: g.regions ior_collect_regions_constants(o, rid, *gvn_to_constant, *not_same);
        if g.ignore_group continue;
        outlined_regions.count = 0;
        for rid: g.regions {
            ior_split_candidate(o, rid);
            if !o.regions[rid].candidate_split continue;
            be := irsim_cand_blocks(s, o.regions[rid].cand);
            o.regions[rid].ce = ce_new(be, null, null, null, null, false, false, "outlined");
            ior_find_add_inputs_outputs(o, rid, *not_same);
            if !o.regions[rid].ignore_region array_add(*outlined_regions, rid);
            ior_reattach_candidate(o, rid);
        }
        g.regions.count = 0;
        for outlined_regions array_add(*g.regions, it);
        if g.regions.count == 0 continue;
        // collectGVNStoreSets
        for rid: g.regions {
            stores := o.regions[rid].gvn_stores;
            dup := false;
            for g.output_gvn_combinations {
                if it.count != stores.count continue;
                same := true;
                for x, k: it if x != stores[k] { same = false; break; }
                if same { dup = true; break; }
            }
            if !dup array_add(*g.output_gvn_combinations, stores);
        }
        if g.output_gvn_combinations.count > 1 array_add(*g.argument_types, type_int(cast(u64) 32));
        if o.cost_model ior_find_cost_benefit(o, cast(u32) gid);
        if o.cost_model && ior_cost_ge(g.cost, g.benefit) continue;
        array_add(*negative_cost_groups, cast(u32) gid);
    }
    if negative_cost_groups.count > 1 {
        Keyed2 :: struct { g: u32; d: Cost; pos: s64; }
        ks: [..] Keyed2; ks.allocator = temp;
        for negative_cost_groups array_add(*ks, .{it, cost_sub(o.groups[it].benefit, o.groups[it].cost), it_index});
        quick_sort(ks, (a: Keyed2, b: Keyed2) -> s64 {
            if a.d != b.d return ifx ior_cost_gt(a.d, b.d) then -1 else 1;
            return a.pos - b.pos;
        });
        for ks negative_cost_groups[it_index] = it.g;
    }
    funcs_to_remove: [..] Value_Id; funcs_to_remove.allocator = temp;
    for gid: negative_cost_groups {
        g := *o.groups[gid];
        outlined_regions.count = 0;
        for rid: g.regions if ior_is_compatible_with_already_outlined_code(o, rid) array_add(*outlined_regions, rid);
        if outlined_regions.count < 2 continue;
        g.regions.count = 0;
        for outlined_regions array_add(*g.regions, it);
        if o.cost_model {
            g.benefit = 0;
            g.cost = 0;
            ior_find_cost_benefit(o, gid);
            if ior_cost_ge(g.cost, g.benefit) continue;
        }
        outlined_regions.count = 0;
        for rid: g.regions {
            ior_split_candidate(o, rid);
            if !o.regions[rid].candidate_split continue;
            array_add(*outlined_regions, rid);
        }
        g.regions.count = 0;
        for outlined_regions array_add(*g.regions, it);
        if g.regions.count < 2 {
            for rid: g.regions ior_reattach_candidate(o, rid);
            continue;
        }
        outlined_regions.count = 0;
        for rid: g.regions {
            be := irsim_cand_blocks(s, o.regions[rid].cand);
            o.regions[rid].ce = ce_new(be, null, null, null, null, false, false, "outlined");
            if ior_extract_section(o, rid) {
                c := o.regions[rid].cand;
                for idx: s.cands[c].start_idx..irsim_end_idx(s, c) table_set(*o.outlined, idx, true);
                array_add(*outlined_regions, rid);
            }
        }
        g.regions.count = 0;
        for outlined_regions array_add(*g.regions, it);
        if g.regions.count == 0 continue;
        ior_deduplicate_extracted_sections(o, gid, *funcs_to_remove, *num);
    }
    for f: funcs_to_remove erase_function(f);
    return num;
}
ior_cost_gt :: (a: Cost, b: Cost) -> bool { return ior_cost_ge(a, b) && a != b; }

irsim: *Irsim;   // the identifier of the running iroutliner (pruneIncompatibleRegions' sort comparator reads it)

// IROutlinerPass::run
ir_outliner_run :: () -> Preserved {
    o: Ior;
    o.regions.allocator = temp; o.groups.allocator = temp; o.outlined.allocator = temp; o.output_mappings.allocator = temp;
    o.fn_allocas.allocator = temp;
    ior_debug = getenv("JAI_IOR_DEBUG") != null;
    o.sim = irsim_find_similarity();
    irsim = o.sim;
    o.cost_model = !ior_cl.no_cost;
    o.outline_from_linkonceodr = ior_cl.enable_linkonceodr;
    n := ior_do_outline(*o);
    irsim = null;
    if n == 0 return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
