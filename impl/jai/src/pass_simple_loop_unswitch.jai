// SimpleLoopUnswitch: hoist loop-invariant control flow out of loops.
// Port of llvm/lib/Transforms/Scalar/SimpleLoopUnswitch.cpp (trivial branch/switch unswitching, non-trivial
// unswitching with loop cloning, partial (and/or) and partially-invariant conditions, injected invariant
// conditions, selects and guards turned into branches, the cost model and its multiplier, LPMUpdater interaction,
// `simple-loop-unswitch<nontrivial;trivial>` and the pass's cl::opts), plus hasPartialIVCondition
// (llvm/lib/Transforms/Utils/LoopUtils.cpp) and SplitBlockAndInsertIfThen with an eager DomTreeUpdater and LoopInfo
// (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp).
//
// ValueToValueMapTy here is a Value_Map whose values are read through slu_vlookup: an erased value (WeakTrackingVH
// nulled) reads as absent. The one RAUW of a map key while the maps are live (an exit-block phi replaced by its
// `.us-phi`) moves the key like ValueMap's FollowRAUW.
//
// Debug records: LLVM keeps a block's records in a "trailing" marker while it has no terminator; the next
// instruction inserted at the end adopts them. `slu.trailing` models that for the places where this pass erases a
// terminator and inserts a new one.

slu_opts: struct {
    enable_nontrivial := false;                 // -enable-nontrivial-unswitch
    threshold: s64 = 50;                        // -unswitch-threshold
    enable_cost_multiplier := true;             // -enable-unswitch-cost-multiplier
    siblings_toplevel_div: s64 = 2;             // -unswitch-siblings-toplevel-div
    parent_blocks_div: s64 = 8;                 // -unswitch-parent-blocks-div
    num_initial_unscaled_candidates: s64 = 8;   // -unswitch-num-initial-unscaled-candidates
    guards := true;                             // -simple-loop-unswitch-guards
    drop_non_trivial_implicit_null_checks := false;   // -simple-loop-unswitch-drop-non-trivial-implicit-null-checks
    mssa_threshold: s64 = 100;                  // -simple-loop-unswitch-memoryssa-threshold
    freeze_cond := true;                        // -freeze-loop-unswitch-cond
    inject_invariant_conditions := true;        // -simple-loop-unswitch-inject-invariant-conditions
    inject_hotness_threshold: s64 = 16;         // -simple-loop-unswitch-inject-invariant-condition-hotness-threshold
    estimate_profile := true;                   // -simple-loop-unswitch-estimate-profile
    profcheck_disable_metadata_fixes := false;  // -profcheck-disable-metadata-fixes (ProfDataUtils.cpp)
};

unswitch_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (p: *bool, name: string, value: string, has_value: bool) {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" p.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" p.* = false;
        else fatal("invalid boolean value '%' for option -%", value, name);
    }
    parse_int :: (p: *s64, name: string, value: string, has_value: bool) {
        if !has_value fatal("option -% needs a value", name);
        v, ok := string_to_int(value);
        if !ok fatal("invalid integer value '%' for option -%", value, name);
        p.* = v;
    }
    if name == {
        case "enable-nontrivial-unswitch"; parse_bool(*slu_opts.enable_nontrivial, name, value, has_value);
        case "unswitch-threshold"; parse_int(*slu_opts.threshold, name, value, has_value);
        case "enable-unswitch-cost-multiplier"; parse_bool(*slu_opts.enable_cost_multiplier, name, value, has_value);
        case "unswitch-siblings-toplevel-div"; parse_int(*slu_opts.siblings_toplevel_div, name, value, has_value);
        case "unswitch-parent-blocks-div"; parse_int(*slu_opts.parent_blocks_div, name, value, has_value);
        case "unswitch-num-initial-unscaled-candidates"; parse_int(*slu_opts.num_initial_unscaled_candidates, name, value, has_value);
        case "simple-loop-unswitch-guards"; parse_bool(*slu_opts.guards, name, value, has_value);
        case "simple-loop-unswitch-drop-non-trivial-implicit-null-checks"; parse_bool(*slu_opts.drop_non_trivial_implicit_null_checks, name, value, has_value);
        case "simple-loop-unswitch-memoryssa-threshold"; parse_int(*slu_opts.mssa_threshold, name, value, has_value);
        case "freeze-loop-unswitch-cond"; parse_bool(*slu_opts.freeze_cond, name, value, has_value);
        case "simple-loop-unswitch-inject-invariant-conditions"; parse_bool(*slu_opts.inject_invariant_conditions, name, value, has_value);
        case "simple-loop-unswitch-inject-invariant-condition-hotness-threshold"; parse_int(*slu_opts.inject_hotness_threshold, name, value, has_value);
        case "simple-loop-unswitch-estimate-profile"; parse_bool(*slu_opts.estimate_profile, name, value, has_value);
        case "profcheck-disable-metadata-fixes"; parse_bool(*slu_opts.profcheck_disable_metadata_fixes, name, value, has_value);
        case; return false;
    }
    return true;
}

SLU_DEBUG_TYPE :: "simple-loop-unswitch";

// pass-run state (temp)
slu: struct {
    li: *Loop_Info;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    mssau: *Mssa_Updater;
    lpm: *Lpm_Updater;
    trailing: Table(Value_Id, u32);
};

// ---------------------------------------------------------------- small helpers

slu_contains :: inline (l: Loop_Id, b: Value_Id) -> bool { return li_contains(slu.li, l, b); }
slu_invariant :: inline (l: Loop_Id, v: Value_Id) -> bool { return li_is_loop_invariant(slu.li, l, v); }

// ValueToValueMapTy::lookup with WeakTrackingVH values (erased = null)
slu_vlookup :: (vm: *Value_Map, k: Value_Id) -> Value_Id {
    found, v := table_find(*vm.map, k);
    if !found || v == NONE || vkind(v) == .DEAD return NONE;
    return v;
}

// a terminator is erased while the block keeps its debug records as trailing records
slu_erase_terminator_keep_trailing :: (t: Value_Id) {
    bb := inst_block(t);
    r := records_take(t);
    slu_add_trailing(bb, r);
    drop_all_references(t);
    erase_inst_with_metadata(t);
}
slu_add_trailing :: (bb: Value_Id, r: u32) {
    if r == 0 return;
    found, old := table_find(*slu.trailing, bb);
    if found && old != 0 {
        // absorbDebugValues(Src, InsertAtHead = false): the new records come after the old ones
        x := old;
        while dbgr(x).next != 0 x = dbgr(x).next;
        dbgr(x).next = r;
        table_set(*slu.trailing, bb, old);
    } else table_set(*slu.trailing, bb, r);
}
// an instruction was inserted at the end of bb: it adopts the trailing records
slu_adopt_trailing :: (bb: Value_Id, i: Value_Id) {
    found, r := table_find(*slu.trailing, bb);
    if !found || r == 0 return;
    table_remove(*slu.trailing, bb);
    attach_records_before(i, r);
}
slu_append :: (bb: Value_Id, i: Value_Id) {
    block_append_inst(bb, i);
    slu_adopt_trailing(bb, i);
}

// Instruction::moveBefore(BB, BB.end()) of a terminator (not preserving): its records stay behind as trailing
// records of the old block, it adopts the destination's trailing records
slu_move_terminator_to_end :: (t: Value_Id, dst: Value_Id) {
    src := inst_block(t);
    r := records_take(t);
    inst_unlink(t);
    slu_add_trailing(src, r);
    slu_append(dst, t);
}

// Helper to skip (select x, true, false)
skip_trivial_select :: (cond_in: Value_Id) -> Value_Id {
    cond := cond_in;
    while true {
        ok, c, t, f := pm_select(cond);
        if !ok || !pm_one(t) || !pm_zero(f) break;
        cond = c;
    }
    return cond;
}

is_logical_and :: (v: Value_Id) -> bool { ok := pm_logical_and(v); return ok; }
is_logical_or :: (v: Value_Id) -> bool { ok := pm_logical_or(v); return ok; }

// L.getUniqueLatchExitBlock()
li_unique_latch_exit_block :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    latch := li_loop_latch(li, l);
    t := block_terminator(latch);
    r: Value_Id = NONE;
    n := num_successors(t);
    for k: 0..cast(s64) n - 1 {
        s := get_successor(t, cast(u32) k);
        if li_contains(li, l, s) continue;
        if r != NONE return NONE;
        r = s;
    }
    return r;
}

// Log2_32
slu_log2_32 :: (v: u32) -> s64 {
    if v == 0 return -1;
    r: s64 = 0;
    x := v;
    while x > 1 { x >>= 1; r += 1; }
    return r;
}

slu_cost_sub :: (a: Cost, b: Cost) -> Cost {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    return a - b;
}

slu_block_any_side_effect_or_convergent :: (bb: Value_Id) -> bool {
    for i: block_insts(bb) {
        if is_call_base(i) && call_has_fn_attr(i, .Convergent) return true;
        if may_have_side_effects(i) return true;
    }
    return false;
}

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI = nullptr, MSSAU)
slu_recursively_delete_trivially_dead :: (v: Value_Id, mssau: *Mssa_Updater) {
    if !is_inst(v) || !is_instruction_trivially_dead_tli(v, false) return;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    while dead.count {
        i := pop(*dead);
        if i == NONE || vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, false) array_add(*dead, o);
        }
        if mssau mssau_remove_memory_access_inst(mssau, i);
        erase_inst_with_metadata(i);
    }
}

// erase_if on a loop's block vector + its block set
slu_erase_blocks_if :: (l: Loop_Id, pred: (b: Value_Id, data: *void) -> bool, data: *void) {
    bl := *slu.li.loops[l].blocks;
    w := 0;
    for k: 0..bl.count - 1 {
        b := bl.*[k];
        if pred(b, data) continue;
        bl.*[w] = b;
        w += 1;
    }
    bl.count = w;
}
slu_set_erase :: (l: Loop_Id, b: Value_Id) { table_remove(*slu.li.member, li_key(l, b)); }

// ---------------------------------------------------------------- collectHomogenousInstGraphLoopInvariants

collect_homogenous_inst_graph_loop_invariants :: (l: Loop_Id, root: Value_Id, out: *[..] Value_Id) {
    is_root_and := is_logical_and(root);
    is_root_or := is_logical_or(root);
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    array_add(*worklist, root);
    table_set(*visited, root, true);
    while worklist.count {
        i := pop(*worklist);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            opv := op(i, cast(u32) k);
            if is_constant_kind(vkind(opv)) continue;
            if slu_invariant(l, opv) { array_add(out, opv); continue; }
            opi := skip_trivial_select(opv);
            if !is_inst(opi) continue;
            if (is_root_and && is_logical_and(opi)) || (is_root_or && is_logical_or(opi)) {
                if !table_contains(*visited, opi) { table_set(*visited, opi, true); array_add(*worklist, opi); }
            }
        }
    }
}

replace_loop_invariant_uses :: (l: Loop_Id, invariant: Value_Id, replacement: Value_Id) {
    u := ir.v_first_use[invariant];
    while u != NONE {
        nx := ir.u_next[u];
        user := ir.u_user[u];
        if is_inst(user) && slu_contains(l, inst_block(user)) use_set(u, replacement);
        u = nx;
    }
}

are_loop_exit_phis_loop_invariant :: (l: Loop_Id, exiting: Value_Id, exit: Value_Id) -> bool {
    for i: block_insts(exit) {
        if inst_op(i) != .PHI return true;
        idx := phi_block_index(i, exiting);
        if !slu_invariant(l, phi_value(i, cast(u32) idx)) return false;
    }
    return true;
}

// ---------------------------------------------------------------- building the unswitched branches

build_partial_unswitch_conditional_branch :: (bb: Value_Id, invariants: [] Value_Id, direction: bool, unswitched_succ: Value_Id,
                                              normal_succ: Value_Id, insert_freeze: bool, ctx_i: Value_Id, ac: *Assumption_Cache,
                                              dt: *Dom_Tree, compute_prof_from: Value_Id) {
    has_bw := false;
    w0, w1: u64;
    if slu_opts.estimate_profile && !slu_opts.profcheck_disable_metadata_fixes {
        ok, ws := prof_extract_branch_weights(compute_prof_from);
        if ok && ws.count == 2 { has_bw = true; w0 = ws[0]; w1 = ws[1]; }
        else if ok has_bw = false;
    }
    if has_bw {
        sum := cast(u32) (cast,trunc(u32) w0 + cast,trunc(u32) w1);   // sum_of over uint32_t
        sel := ifx direction then w0 else w1;
        if cast(float64) cast,trunc(u32) sel / cast(float64) sum > 0.5 has_bw = false;
    }
    last_before := block_last(bb);
    b: Irb;
    irb_set_end(*b, bb);
    b.dbg = NONE;   // DebugLoc::getCompilerGenerated()
    frozen: [..] Value_Id; frozen.allocator = temp;
    for inv: invariants {
        v := inv;
        if insert_freeze && !is_guaranteed_not_to_be_undef_or_poison(v, ac, ctx_i, dt)
            v = irb_freeze(*b, v, tprint("%.fr", vname(v)));
        array_add(*frozen, v);
    }
    cond := frozen[0];
    for k: 1..frozen.count - 1 cond = irb_binop(*b, ifx direction then Opcode.OR else .AND, cond, frozen[k]);
    br := create_cond_br(cond, ifx direction then unswitched_succ else normal_succ, ifx direction then normal_succ else unswitched_succ);
    if has_bw {
        p := prof_md(compute_prof_from);
        if p != NONE set_metadata(br, md_kind_id(MD_PROF_NAME), p);
    }
    irb_insert(*b, br);
    first_new := ifx last_before == NONE then block_first(bb) else inst_next(last_before);
    if first_new != NONE slu_adopt_trailing(bb, first_new);
    if !has_bw set_explicitly_unknown_branch_weights_if_profiled(br, SLU_DEBUG_TYPE);
}

build_partial_invariant_unswitch_conditional_branch :: (bb: Value_Id, to_duplicate: [] Value_Id, direction: bool,
                                                        unswitched_succ: Value_Id, normal_succ: Value_Id, l: Loop_Id,
                                                        mssau: *Mssa_Updater, original_branch: Value_Id) {
    vm: Value_Map; vmap_init(*vm);
    last_before := block_last(bb);
    for < k: 0..to_duplicate.count - 1 {
        v := to_duplicate[k];
        ni := inst_clone(v);
        map_atom_instance(v);
        block_append_inst(bb, ni);
        remap_instruction(*vm, ni, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        vmap_set(*vm, v, ni);
        if !mssau continue;
        m := mssau.mssa;
        ma := mssa_access_of(m, v);
        if ma >= 0 && ma_is_use(m, ma) {
            def := ma_defining(m, ma);
            while !is_live_on_entry(def) && slu_contains(l, ma_block(m, def)) {
                if ma_is_phi(m, def) def = mphi_value_for_block(m, def, li_loop_preheader(slu.li, l));
                else def = ma_defining(m, def);
            }
            mssau_create_memory_access_in_bb(mssau, ni, def, inst_block(ni), .BEFORE_TERMINATOR);
        }
    }
    cond := vmap_lookup(*vm, to_duplicate[0]);
    prof: Md_Id = NONE;
    if !slu_opts.profcheck_disable_metadata_fixes && to_duplicate[0] == skip_trivial_select(op(original_branch, 0))
        prof = prof_md(original_branch);
    br := create_cond_br(cond, ifx direction then unswitched_succ else normal_succ, ifx direction then normal_succ else unswitched_succ);
    if prof != NONE set_metadata(br, md_kind_id(MD_PROF_NAME), prof);
    block_append_inst(bb, br);
    first_new := ifx last_before == NONE then block_first(bb) else inst_next(last_before);
    if first_new != NONE slu_adopt_trailing(bb, first_new);
    if prof == NONE set_explicitly_unknown_branch_weights_if_profiled(br, SLU_DEBUG_TYPE);
}

rewrite_phi_nodes_for_unswitched_exit_block :: (unswitched_bb: Value_Id, old_exiting: Value_Id, old_ph: Value_Id) {
    for pn: block_insts(unswitched_bb) {
        if inst_op(pn) != .PHI break;
        n := nops(pn);
        for k: 0..cast(s64) n - 1 {
            assert(phi_block(pn, cast(u32) k) == old_exiting, "Found incoming block different from unique predecessor!");
            phi_set_block(pn, cast(u32) k, old_ph);
        }
    }
}

rewrite_phi_nodes_for_exit_and_unswitched_blocks :: (exit_bb: Value_Id, unswitched_bb: Value_Id, old_exiting: Value_Id,
                                                     old_ph: Value_Id, full_unswitch: bool) {
    insert_pt := block_first(unswitched_bb);   // UnswitchedBB.begin() (head bit)
    phis: [..] Value_Id; phis.allocator = temp;
    for pn: block_insts(exit_bb) { if inst_op(pn) != .PHI break; array_add(*phis, pn); }
    for pn: phis {
        np := create_phi(vtype(pn), 2);
        insert_at_position(np, unswitched_bb, insert_pt, true);
        set_name(np, tprint("%.split", vname(pn)));
        i := cast(s64) nops(pn) - 1;
        while i >= 0 {
            if phi_block(pn, cast(u32) i) == old_exiting {
                inc := phi_value(pn, cast(u32) i);
                if full_unswitch phi_remove_incoming(pn, cast(u32) i);
                phi_add_incoming(np, inc, old_ph);
            }
            i -= 1;
        }
        rauw_with_metadata(pn, np);
        phi_add_incoming(np, pn, exit_bb);
    }
}

// ---------------------------------------------------------------- hoistLoopToNewParent

hoist_loop_to_new_parent :: (l: Loop_Id, preheader: Value_Id) {
    li := slu.li;
    old_parent := li_parent(li, l);
    if old_parent == NONE return;
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(li, l, *exits);
    new_parent: Loop_Id = NONE;
    for e: exits {
        el := li_loop_for(li, e);
        if el != NONE && (new_parent == NONE || li_contains_loop(li, new_parent, el)) new_parent = el;
    }
    if new_parent == old_parent return;
    li_change_loop_for(li, preheader, new_parent);
    li_remove_child_loop(li, old_parent, l);
    if new_parent != NONE li_add_child_loop(li, new_parent, l);
    else li_add_top_level_loop(li, l);
    Ctx :: struct { l: Loop_Id; ph: Value_Id; }
    c := Ctx.{l, preheader};
    oc := old_parent;
    while oc != new_parent {
        slu_erase_blocks_if(oc, (b: Value_Id, d: *void) -> bool {
            c := cast(*Ctx) d;
            return b == c.ph || li_contains(slu.li, c.l, b);
        }, *c);
        slu_set_erase(oc, preheader);
        for b: li_blocks(li, l) slu_set_erase(oc, b);
        form_lcssa(li, oc, slu.dt);
        form_dedicated_exit_blocks(li, oc, slu.dt, slu.mssau, true);
        oc = li_parent(li, oc);
    }
}

get_top_most_exiting_loop :: (exit_bb: Value_Id) -> Loop_Id {
    li := slu.li;
    top := li_loop_for(li, exit_bb);
    cur := top;
    while cur != NONE {
        if li_is_loop_exiting(li, cur, exit_bb) top = cur;
        cur = li_parent(li, cur);
    }
    return top;
}

// SplitEdge(BB, Succ, DT, LI, MSSAU)
slu_split_edge :: (bb: Value_Id, succ: Value_Id) -> Value_Id {
    if !slu.mssau return split_edge(bb, succ, slu.dt, slu.li);
    t := block_terminator(bb);
    succ_num: u32 = 0;
    while get_successor(t, succ_num) != succ succ_num += 1;
    o: Crit_Edge_Options;
    if is_critical_edge(t, succ_num, o.merge_identical_edges) fatal("simple-loop-unswitch: SplitEdge of a critical edge with MemorySSA is not implemented yet");
    if block_single_predecessor(succ) != NONE fatal("simple-loop-unswitch: SplitEdge into a single-predecessor block with MemorySSA is not implemented yet");
    return split_block(bb, t, slu.dt, slu.li, slu.mssau);
}

// SplitBlock(BB, BB->begin(), DT, LI, MSSAU, "")
slu_split_block_at_begin :: (bb: Value_Id) -> Value_Id {
    return split_block(bb, block_first(bb), slu.dt, slu.li, slu.mssau, "", true);
}

// ---------------------------------------------------------------- unswitchTrivialBranch

unswitch_trivial_branch :: (l: Loop_Id, bi: Value_Id) -> bool {
    li := slu.li; dt := slu.dt; mssau := slu.mssau;
    invariants: [..] Value_Id; invariants.allocator = temp;
    full_unswitch := false;
    cond := skip_trivial_select(op(bi, 0));
    if slu_invariant(l, cond) {
        array_add(*invariants, cond);
        full_unswitch = true;
    } else {
        if is_inst(cond) collect_homogenous_inst_graph_loop_invariants(l, cond, *invariants);
        if invariants.count == 0 return false;
    }

    latch_idx: s64 = -1;
    loop_latch := li_loop_latch(li, l);
    ul_exit := li_unique_latch_exit_block(li, l);
    if full_unswitch && ul_exit != NONE {
        if get_successor(bi, 0) == loop_latch && slu_contains(l, get_successor(bi, 1)) latch_idx = 0;
        else if get_successor(bi, 1) == loop_latch && slu_contains(l, get_successor(bi, 0)) latch_idx = 1;
    }

    modified_branch := false;
    if latch_idx >= 0 && are_loop_exit_phis_loop_invariant(l, loop_latch, ul_exit) && !slu_block_any_side_effect_or_convergent(loop_latch) {
        max_be := sc_get_constant_max_backedge_taken_count(l);
        if !sc_is_cnc(max_be) {
            updates: [..] Dom_Update; updates.allocator = temp;
            array_add(*updates, .{false, inst_block(bi), get_successor(bi, cast(u32) latch_idx)});
            array_add(*updates, .{true, inst_block(bi), ul_exit});
            block_remove_predecessor(loop_latch, inst_block(bi));
            set_successor(bi, cast(u32) latch_idx, ul_exit);
            for pn: block_insts(ul_exit) {
                if inst_op(pn) != .PHI break;
                v := phi_value(pn, cast(u32) phi_block_index(pn, loop_latch));
                phi_add_incoming(pn, v, inst_block(bi));
            }
            if mssau mssau_apply_updates(mssau, updates, dt, true);
            else dt_apply_updates(dt, updates);
            modified_branch = true;
        }
    }

    exit_direction := true;
    loop_exit_succ_idx: u32 = 0;
    loop_exit_bb := get_successor(bi, 0);
    if slu_contains(l, loop_exit_bb) {
        exit_direction = false;
        loop_exit_succ_idx = 1;
        loop_exit_bb = get_successor(bi, 1);
        if slu_contains(l, loop_exit_bb) {
            assert(!modified_branch, "Modified the branch but didn't unswitch");
            return false;
        }
    }
    continue_bb := get_successor(bi, 1 - loop_exit_succ_idx);
    parent_bb := inst_block(bi);
    if !modified_branch && !are_loop_exit_phis_loop_invariant(l, parent_bb, loop_exit_bb) return false;

    if !full_unswitch {
        if ifx exit_direction then !is_logical_or(cond) else !is_logical_and(cond) {
            assert(!modified_branch, "Modified the branch but didn't unswitch");
            return false;
        }
    }

    {
        exit_l := get_top_most_exiting_loop(loop_exit_bb);
        if exit_l != NONE sc_forget_loop(exit_l);
        else sc_forget_topmost_loop(l);
        sc_forget_block_and_loop_dispositions();
    }

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    old_ph := li_loop_preheader(li, l);
    new_ph := slu_split_edge(old_ph, li_header(li, l));

    unswitched_bb: Value_Id;
    if full_unswitch && block_unique_predecessor(loop_exit_bb) != NONE {
        assert(block_unique_predecessor(loop_exit_bb) == inst_block(bi), "A branch's parent isn't a predecessor!");
        unswitched_bb = loop_exit_bb;
    } else {
        unswitched_bb = slu_split_block_at_begin(loop_exit_bb);
    }

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    slu_erase_terminator_keep_trailing(block_terminator(old_ph));
    if full_unswitch {
        slu_move_terminator_to_end(bi, old_ph);
        set_op(bi, 0, cond);
        if mssau {
            c := inst_clone(bi);
            slu_append(parent_bb, c);
        } else {
            nbi := create_br(continue_bb);
            slu_append(parent_bb, nbi);
            copy_debug_loc_or_clear(nbi, bi);
        }
        set_successor(bi, loop_exit_succ_idx, unswitched_bb);
        set_successor(bi, 1 - loop_exit_succ_idx, new_ph);
    } else {
        build_partial_unswitch_conditional_branch(old_ph, invariants, exit_direction, unswitched_bb, new_ph,
                                                  slu_opts.freeze_cond, block_terminator_or_null(old_ph), null, dt, bi);
    }

    dt_insert_edge(dt, old_ph, unswitched_bb);

    if mssau {
        updates: [..] Dom_Update; updates.allocator = temp;
        array_add(*updates, .{true, old_ph, unswitched_bb});
        gd: Graph_Diff;
        empty: [] Dom_Update;
        gd_init(*gd, empty, false, false);
        mssau_apply_insert_updates(mssau, updates, dt, *gd);
    }

    if full_unswitch {
        if mssau {
            term := block_terminator(parent_bb);
            nbi := create_br(continue_bb);
            block_append_inst(parent_bb, nbi);
            copy_debug_loc_or_clear(nbi, term);
            erase_inst_with_metadata(term);
            mssau_remove_edge(mssau, parent_bb, loop_exit_bb);
        }
        dt_delete_edge(dt, parent_bb, loop_exit_bb);
    }

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    if unswitched_bb == loop_exit_bb rewrite_phi_nodes_for_unswitched_exit_block(unswitched_bb, parent_bb, old_ph);
    else rewrite_phi_nodes_for_exit_and_unswitched_blocks(loop_exit_bb, unswitched_bb, parent_bb, old_ph, full_unswitch);

    replacement := ifx exit_direction then const_int(ir.t_i1, 0) else const_int(ir.t_i1, 1);
    for invariants replace_loop_invariant_uses(l, it, replacement);

    if full_unswitch hoist_loop_to_new_parent(l, new_ph);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
    return true;
}

// the terminator or NONE (getTerminatorOrNull)
block_terminator_or_null :: (bb: Value_Id) -> Value_Id {
    t := block_last(bb);
    if t == NONE || !is_terminator(inst_op(t)) return NONE;
    return t;
}


// ---------------------------------------------------------------- unswitchTrivialSwitch

unswitch_trivial_switch :: (l: Loop_Id, si: Value_Id) -> bool {
    li := slu.li; dt := slu.dt; mssau := slu.mssau;
    loop_cond := sw_cond(si);
    if !slu_invariant(l, loop_cond) return false;
    parent_bb := inst_block(si);

    is_trivially_unswitchable_exit_block :: (l: Loop_Id, parent_bb: Value_Id, bb: Value_Id) -> bool {
        if slu_contains(l, bb) return false;
        if !are_loop_exit_phis_loop_invariant(l, parent_bb, bb) return false;
        t := block_terminator(bb);
        is_unreachable := inst_op(t) == .UNREACHABLE;
        return !is_unreachable || block_first_non_phi_or_dbg(bb) != t;
    }

    exit_case_indices: [..] u32; exit_case_indices.allocator = temp;
    for k: 0..cast(s64) sw_num_cases(si) - 1
        if is_trivially_unswitchable_exit_block(l, parent_bb, sw_case_dest(si, cast(u32) k)) array_add(*exit_case_indices, cast(u32) k);
    default_exit_bb: Value_Id = NONE;
    has_dw, dw := sw_successor_weight(si, 0);
    if is_trivially_unswitchable_exit_block(l, parent_bb, sw_default(si)) default_exit_bb = sw_default(si);
    else if exit_case_indices.count == 0 return false;

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    outer_l := l;
    if default_exit_bb != NONE {
        exit_l := get_top_most_exiting_loop(default_exit_bb);
        if exit_l == NONE || li_contains_loop(li, exit_l, outer_l) outer_l = exit_l;
    }
    for idx: exit_case_indices {
        exit_l := get_top_most_exiting_loop(sw_case_dest(si, idx));
        if exit_l == NONE || li_contains_loop(li, exit_l, outer_l) outer_l = exit_l;
    }
    if outer_l != NONE sc_forget_loop(outer_l);
    else sc_forget_topmost_loop(l);

    if default_exit_bb != NONE sw_set_default(si, NONE);

    Exit_Case :: struct { val: Value_Id; bb: Value_Id; has_w: bool; w: u32; }
    exit_cases: [..] Exit_Case; exit_cases.allocator = temp;
    siw: Sw_Prof;
    sw_prof_init(*siw, si);
    for < k: 0..exit_case_indices.count - 1 {
        idx := exit_case_indices[k];
        hw, w := sw_prof_get_weight(*siw, idx + 1);
        array_add(*exit_cases, .{sw_case_value(si, idx), sw_case_dest(si, idx), hw, w});
        sw_prof_remove_case(*siw, idx);
    }

    common_succ: Value_Id = NONE;
    nc := sw_num_cases(si);
    if nc > 0 {
        all_same := true;
        first := sw_case_dest(si, 0);
        for k: 1..cast(s64) nc - 1 if sw_case_dest(si, cast(u32) k) != first { all_same = false; break; }
        if all_same common_succ = first;
    }
    if default_exit_bb == NONE {
        if nc == 0 common_succ = sw_default(si);
        else if sw_default(si) != common_succ common_succ = NONE;
    }

    old_ph := li_loop_preheader(li, l);
    new_ph := slu_split_edge(old_ph, li_header(li, l));
    slu_erase_terminator_keep_trailing(block_terminator(old_ph));

    new_si := create_switch(loop_cond, new_ph, cast(u32) exit_cases.count);
    slu_append(old_ph, new_si);
    copy_debug_loc_or_clear(new_si, si);
    new_siw: Sw_Prof;
    sw_prof_init(*new_siw, new_si);

    unswitched_exit_bbs: [..] Value_Id; unswitched_exit_bbs.allocator = temp;   // SmallPtrSet (insertion order)
    Split_Pair :: struct { exit: Value_Id; split: Value_Id; }
    split_map: [..] Split_Pair; split_map.allocator = temp;                    // SmallDenseMap (insertion order)
    find_split :: (m: [] Split_Pair, b: Value_Id) -> Value_Id { for m if it.exit == b return it.split; return NONE; }
    contains :: (a: [] Value_Id, b: Value_Id) -> bool { for a if it == b return true; return false; }

    if default_exit_bb != NONE {
        if !block_has_predecessors(default_exit_bb) {
            array_add(*unswitched_exit_bbs, default_exit_bb);
            rewrite_phi_nodes_for_unswitched_exit_block(default_exit_bb, parent_bb, old_ph);
        } else {
            split_bb := slu_split_block_at_begin(default_exit_bb);
            rewrite_phi_nodes_for_exit_and_unswitched_blocks(default_exit_bb, split_bb, parent_bb, old_ph, true);
            array_add(*split_map, .{default_exit_bb, split_bb});
            default_exit_bb = split_bb;
        }
    }
    for < k: 0..exit_cases.count - 1 {
        ec := *exit_cases[k];
        exit_bb := ec.bb;
        if !block_has_predecessors(exit_bb) {
            if !contains(unswitched_exit_bbs, exit_bb) {
                array_add(*unswitched_exit_bbs, exit_bb);
                rewrite_phi_nodes_for_unswitched_exit_block(exit_bb, parent_bb, old_ph);
            }
            continue;
        }
        split_exit := find_split(split_map, exit_bb);
        if split_exit == NONE {
            split_exit = slu_split_block_at_begin(exit_bb);
            rewrite_phi_nodes_for_exit_and_unswitched_blocks(exit_bb, split_exit, parent_bb, old_ph, true);
            array_add(*split_map, .{exit_bb, split_exit});
        }
        ec.bb = split_exit;
    }

    for < k: 0..exit_cases.count - 1 {
        ec := exit_cases[k];
        sw_prof_add_case(*new_siw, ec.val, ec.bb, ec.has_w, ec.w);
    }

    if default_exit_bb != NONE {
        sw_set_default(new_si, default_exit_bb);
        sw_prof_set_weight(*new_siw, 0, has_dw, dw);
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            hw, w := sw_prof_get_weight(*siw, cast(u32) k + 1);
            sw_prof_add_case(*new_siw, sw_case_value(si, cast(u32) k), new_ph, hw, w);
        }
    } else if has_dw {
        sw: u64 = dw;
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            hw, w := sw_prof_get_weight(*siw, cast(u32) k + 1);
            assert(hw, "case weight must be defined as default case weight is defined");
            sw += w;
        }
        sw_prof_set_weight(*new_siw, 0, true, cast,trunc(u32) sw);
    }

    if common_succ != NONE {
        bb := inst_block(si);
        skipped_first := default_exit_bb == NONE;
        for k: 0..cast(s64) sw_num_cases(si) - 1 {
            if !skipped_first { skipped_first = true; continue; }
            block_remove_predecessor(common_succ, bb, true);
        }
        nbi := create_br(common_succ);
        block_append_inst(bb, nbi);
        copy_debug_loc_or_clear(nbi, si);
        sw_prof_erase(*siw);
        drop_all_references(si);
        erase_inst_with_metadata(si);
    } else if default_exit_bb != NONE {
        last := sw_num_cases(si) - 1;
        sw_set_default(si, sw_case_dest(si, last));
        hw, w := sw_prof_get_weight(*siw, last + 1);
        sw_prof_set_weight(*siw, 0, hw, w);
        sw_prof_remove_case(*siw, last);
    }
    if vkind(si) != .DEAD sw_prof_done(*siw);
    sw_prof_done(*new_siw);

    dt_updates: [..] Dom_Update; dt_updates.allocator = temp;
    for unswitched_exit_bbs {
        array_add(*dt_updates, .{false, parent_bb, it});
        array_add(*dt_updates, .{true, old_ph, it});
    }
    for split_map {
        array_add(*dt_updates, .{false, parent_bb, it.exit});
        array_add(*dt_updates, .{true, old_ph, it.split});
    }
    if mssau {
        mssau_apply_updates(mssau, dt_updates, dt, true);
        if mssa_opts.verify mssa_verify(mssau.mssa);
    } else dt_apply_updates(dt, dt_updates);

    hoist_loop_to_new_parent(l, new_ph);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
    return true;
}

// ---------------------------------------------------------------- unswitchAllTrivialConditions

unswitch_all_trivial_conditions :: (l: Loop_Id) -> bool {
    changed := false;
    mssau := slu.mssau;
    current := li_header(slu.li, l);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    table_set(*visited, current, true);
    while true {
        if mssau {
            m := mssau.mssa;
            d := mssa_first_block_def(m, current);
            if d >= 0 && (!ma_is_phi(m, d) || m.acc[d].dnext >= 0) return changed;
        }
        if slu_block_any_side_effect_or_convergent(current) return changed;
        term := block_terminator(current);
        if inst_op(term) == .SWITCH {
            if is_constant_kind(vkind(sw_cond(term))) return changed;
            if !unswitch_trivial_switch(l, term) return changed;
            changed = true;
            t := block_terminator(current);
            if inst_op(t) != .BR return changed;
            current = get_successor(t, 0);
        } else {
            if inst_op(term) != .CONDBR return changed;
            if is_constant_kind(vkind(skip_trivial_select(op(term, 0)))) return changed;
            if !unswitch_trivial_branch(l, term) return changed;
            changed = true;
            t := block_terminator(current);
            if inst_op(t) == .CONDBR return changed;
            current = get_successor(t, 0);
        }
        if !slu_contains(l, current) break;
        if table_contains(*visited, current) break;
        table_set(*visited, current, true);
    }
    return changed;
}

// ---------------------------------------------------------------- buildClonedLoopBlocks

Dom_Succ_Map :: Table(Value_Id, Value_Id);

build_cloned_loop_blocks :: (l: Loop_Id, loop_ph: Value_Id, split_bb: Value_Id, exit_blocks: [] Value_Id, parent_bb: Value_Id,
                             unswitched_succ: Value_Id, continue_succ: Value_Id, dominating_succ: *Dom_Succ_Map,
                             vm: *Value_Map, dt_updates: *[..] Dom_Update) -> Value_Id {
    li := slu.li; mssau := slu.mssau;
    new_blocks: [..] Value_Id; new_blocks.allocator = temp;
    f := block_fn(loop_ph);
    clone_block :: (old: Value_Id, vm: *Value_Map, loop_ph: Value_Id, f: Value_Id, new_blocks: *[..] Value_Id) -> Value_Id {
        nb := clone_basic_block(old, vm, ".us", f);
        block_move_before(nb, loop_ph);
        array_add(new_blocks, nb);
        vmap_set(vm, old, nb);
        return nb;
    }
    skip_block :: (dominating_succ: *Dom_Succ_Map, unswitched_succ: Value_Id, bb: Value_Id) -> bool {
        found, s := table_find(dominating_succ, bb);
        return found && s != unswitched_succ;
    }

    cloned_ph := clone_block(loop_ph, vm, loop_ph, f, *new_blocks);
    for bb: li_blocks(li, l) if !skip_block(dominating_succ, unswitched_succ, bb) clone_block(bb, vm, loop_ph, f, *new_blocks);

    for exit_bb: exit_blocks {
        if skip_block(dominating_succ, unswitched_succ, exit_bb) continue;
        merge_bb := slu_split_block_at_begin(exit_bb);
        ic_take_name(merge_bb, exit_bb);
        set_name(exit_bb, tprint("%.split", vname(merge_bb)));
        cloned_exit := clone_block(exit_bb, vm, loop_ph, f, *new_blocks);
        assert(num_successors(block_terminator(cloned_exit)) == 1, "Exit block should have been split to have one successor!");
        i := block_first(exit_bb);
        ci := block_first(cloned_exit);
        while i != block_terminator(exit_bb) && ci != block_terminator(cloned_exit) {
            nx := inst_next(i); cnx := inst_next(ci);
            if inst_op(i) == .PHI sc_forget_lcssa_phi_with_new_predecessor(l, i);
            insert_pt := block_first_insertion_pt(merge_bb);
            mp := create_phi(vtype(i), 2);
            insert_at_position(mp, merge_bb, insert_pt, true);
            set_name(mp, ".us-phi");
            if insert_pt != NONE copy_debug_loc_or_clear(mp, insert_pt);
            rauw_with_metadata(i, mp);
            // ValueMap FollowRAUW: the key moves to the new value
            {
                found, target := table_find(*vm.map, i);
                if found {
                    table_remove(*vm.map, i);
                    if !table_contains(*vm.map, mp) table_set(*vm.map, mp, target);
                }
            }
            phi_add_incoming(mp, i, exit_bb);
            phi_add_incoming(mp, ci, cloned_exit);
            i = nx; ci = cnx;
        }
    }

    for cb: new_blocks for i: block_insts(cb) {
        remap_dbg_record_range(vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        remap_instruction(vm, i, RF_NO_MODULE_LEVEL_CHANGES | RF_IGNORE_MISSING_LOCALS);
        if call_iid(i) == IID_ASSUME ac_register_assumption(slu.ac, i);
    }

    succs: [..] Value_Id; succs.allocator = temp;
    for bb: li_blocks(li, l) {
        if !skip_block(dominating_succ, unswitched_succ, bb) continue;
        block_successors(bb, *succs);
        for s: succs {
            cs := slu_vlookup(vm, s);
            if cs == NONE continue;
            for pn: block_insts(cs) {
                if inst_op(pn) != .PHI break;
                phi_remove_incoming_block(pn, bb, false);
            }
        }
    }

    cloned_parent := slu_vlookup(vm, parent_bb);
    block_successors(parent_bb, *succs);
    for s: succs {
        if s == unswitched_succ continue;
        cs := slu_vlookup(vm, s);
        if cs == NONE continue;
        block_remove_predecessor(cs, cloned_parent, true);
    }

    cloned_succ := slu_vlookup(vm, unswitched_succ);
    cloned_term := block_terminator(cloned_parent);
    cond_to_erase: Value_Id = NONE;
    if inst_op(cloned_term) == .CONDBR || inst_op(cloned_term) == .SWITCH cond_to_erase = op(cloned_term, 0);
    nbi := create_br(cloned_succ);
    block_append_inst(cloned_parent, nbi);
    copy_debug_loc_or_clear(nbi, cloned_term);
    drop_all_references(cloned_term);
    erase_inst_with_metadata(cloned_term);
    if cond_to_erase != NONE slu_recursively_delete_trivially_dead(cond_to_erase, mssau);

    for pn: block_insts(cloned_succ) {
        if inst_op(pn) != .PHI break;
        found := false;
        k := cast(s64) nops(pn) - 1;
        while k >= 0 {
            if phi_block(pn, cast(u32) k) == cloned_parent {
                if !found found = true;
                else phi_remove_incoming(pn, cast(u32) k, false);
            }
            k -= 1;
        }
    }

    for cb: new_blocks {
        block_successors(cb, *succs);
        seen: [..] Value_Id; seen.allocator = temp;
        for s: succs {
            dup := false;
            for seen if it == s { dup = true; break; }
            if dup continue;
            array_add(*seen, s);
            array_add(dt_updates, .{true, cb, s});
        }
    }
    return cloned_ph;
}

// ---------------------------------------------------------------- cloneLoopNest / buildClonedLoops

clone_loop_nest :: (orig_root: Loop_Id, root_parent: Loop_Id, vm: *Value_Map) -> Loop_Id {
    li := slu.li;
    add_cloned_blocks_to_loop :: (orig: Loop_Id, cl: Loop_Id, vm: *Value_Map) {
        li := slu.li;
        for bb: li_blocks(li, orig) {
            cbb := slu_vlookup(vm, bb);
            li_add_block_entry(li, cl, cbb);
            if li_loop_for(li, bb) == orig li_change_loop_for(li, cbb, cl);
        }
    }
    cloned_root := li_alloc_loop(li);
    if root_parent != NONE li_add_child_loop(li, root_parent, cloned_root);
    else li_add_top_level_loop(li, cloned_root);
    add_cloned_blocks_to_loop(orig_root, cloned_root, vm);
    if li_is_innermost(li, orig_root) return cloned_root;
    Pair :: struct { cp: Loop_Id; l: Loop_Id; }
    to_clone: [..] Pair; to_clone.allocator = temp;
    for < li_subloops(li, orig_root) array_add(*to_clone, .{cloned_root, it});
    while to_clone.count {
        p := pop(*to_clone);
        cl := li_alloc_loop(li);
        li_add_child_loop(li, p.cp, cl);
        add_cloned_blocks_to_loop(p.l, cl, vm);
        for < li_subloops(li, p.l) array_add(*to_clone, .{cl, it});
    }
    return cloned_root;
}

build_cloned_loops :: (orig_l: Loop_Id, exit_blocks: [] Value_Id, vm: *Value_Map, non_child_cloned: *[..] Loop_Id) {
    li := slu.li;
    cloned_l: Loop_Id = NONE;
    orig_ph := li_loop_preheader(li, orig_l);
    orig_header := li_header(li, orig_l);
    cloned_ph := slu_vlookup(vm, orig_ph);
    cloned_header := slu_vlookup(vm, orig_header);

    parent_l: Loop_Id = NONE;
    cloned_exits_in_loops: [..] Value_Id; cloned_exits_in_loops.allocator = temp;
    exit_loop_map: Table(Value_Id, Loop_Id); exit_loop_map.allocator = temp;
    for exit_bb: exit_blocks {
        ce := slu_vlookup(vm, exit_bb);
        if ce == NONE continue;
        el := li_loop_for(li, exit_bb);
        if el == NONE continue;
        table_set(*exit_loop_map, ce, el);
        array_add(*cloned_exits_in_loops, ce);
        if parent_l == NONE || (parent_l != el && li_contains_loop(li, parent_l, el)) parent_l = el;
    }

    cloned_loop_blocks: [..] Value_Id; cloned_loop_blocks.allocator = temp;   // SmallSetVector
    clb_set: Table(Value_Id, bool); clb_set.allocator = temp;
    for bb: li_blocks(li, orig_l) {
        cbb := slu_vlookup(vm, bb);
        if cbb != NONE && !table_contains(*clb_set, cbb) { table_set(*clb_set, cbb, true); array_add(*cloned_loop_blocks, cbb); }
    }

    worklist: [..] Value_Id; worklist.allocator = temp;
    in_cloned: Table(Value_Id, bool); in_cloned.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(cloned_header, *preds);
    for p: preds {
        if p == cloned_ph continue;
        assert(table_contains(*clb_set, p), "Found a predecessor of the loop header other than the preheader that is not part of the loop!");
        if !table_contains(*in_cloned, p) {
            table_set(*in_cloned, p, true);
            if p != cloned_header array_add(*worklist, p);
        }
    }

    if in_cloned.count > 0 {
        table_set(*in_cloned, cloned_header, true);
        while worklist.count {
            bb := pop(*worklist);
            block_predecessors(bb, *preds);
            for p: preds {
                if table_contains(*clb_set, p) && !table_contains(*in_cloned, p) {
                    table_set(*in_cloned, p, true);
                    array_add(*worklist, p);
                }
            }
        }
        cloned_l = li_alloc_loop(li);
        if parent_l != NONE {
            li_add_basic_block_to_loop(li, parent_l, cloned_ph);
            li_add_child_loop(li, parent_l, cloned_l);
        } else li_add_top_level_loop(li, cloned_l);
        array_add(non_child_cloned, cloned_l);

        for bb: li_blocks(li, orig_l) {
            cbb := slu_vlookup(vm, bb);
            if cbb == NONE || !table_contains(*in_cloned, cbb) continue;
            if li_loop_for(li, bb) == orig_l { li_add_basic_block_to_loop(li, cloned_l, cbb); continue; }
            pl := cloned_l;
            while pl != NONE { li_add_block_entry(li, pl, cbb); pl = li_parent(li, pl); }
        }
        subs: [..] Loop_Id; subs.allocator = temp;
        for li_subloops(li, orig_l) array_add(*subs, it);
        for child: subs {
            ch := slu_vlookup(vm, li_header(li, child));
            if ch == NONE || !table_contains(*in_cloned, ch) continue;
            clone_loop_nest(child, cloned_l, vm);
        }
    }

    unlooped: Table(Value_Id, bool); unlooped.allocator = temp;
    if in_cloned.count == 0 table_set(*unlooped, cloned_ph, true);
    for cloned_loop_blocks if !table_contains(*in_cloned, it) table_set(*unlooped, it, true);

    ordered: [..] Value_Id; ordered.allocator = temp;
    for cloned_exits_in_loops array_add(*ordered, it);
    // llvm::sort by ascending exit-loop depth (small inputs: insertion sort, i.e. stable)
    for i: 1..ordered.count - 1 {
        x := ordered[i];
        _, xl := table_find(*exit_loop_map, x);
        dx := li_depth(li, xl);
        j := i - 1;
        while j >= 0 {
            _, yl := table_find(*exit_loop_map, ordered[j]);
            if li_depth(li, yl) <= dx break;
            ordered[j + 1] = ordered[j];
            j -= 1;
        }
        ordered[j + 1] = x;
    }

    while unlooped.count > 0 && ordered.count > 0 {
        exit_bb := pop(*ordered);
        _, exit_l := table_find(*exit_loop_map, exit_bb);
        array_add(*worklist, exit_bb);
        while worklist.count {
            bb := pop(*worklist);
            if bb == cloned_ph continue;
            block_predecessors(bb, *preds);
            for p: preds {
                if !table_contains(*unlooped, p) continue;
                table_remove(*unlooped, p);
                assert(!table_contains(*exit_loop_map, p), "Should only visit an unlooped block once!");
                table_set(*exit_loop_map, p, exit_l);
                array_add(*worklist, p);
            }
        }
    }

    place :: (bb: Value_Id, exit_loop_map: *Table(Value_Id, Loop_Id)) {
        found, ol := table_find(exit_loop_map, bb);
        if found && ol != NONE li_add_basic_block_to_loop(slu.li, ol, bb);
    }
    place(cloned_ph, *exit_loop_map);
    for cloned_loop_blocks place(it, *exit_loop_map);
    for cloned_exits_in_loops place(it, *exit_loop_map);

    subs: [..] Loop_Id; subs.allocator = temp;
    for li_subloops(li, orig_l) array_add(*subs, it);
    for child: subs {
        ch := slu_vlookup(vm, li_header(li, child));
        if ch == NONE || table_contains(*in_cloned, ch) continue;
        found, pl := table_find(*exit_loop_map, ch);
        if !found pl = NONE;
        array_add(non_child_cloned, clone_loop_nest(child, pl, vm));
    }
}

// ---------------------------------------------------------------- dead blocks

slu_drop_block_references :: (bb: Value_Id) { for i: block_insts(bb) drop_all_references(i); }

delete_dead_cloned_blocks :: (l: Loop_Id, exit_blocks: [] Value_Id, vms: [] *Value_Map) {
    li := slu.li; dt := slu.dt;
    dead: [..] Value_Id; dead.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    visit :: (bb: Value_Id, vms: [] *Value_Map, dead: *[..] Value_Id, succs: *[..] Value_Id) {
        for vm: vms {
            cbb := slu_vlookup(vm, bb);
            if cbb == NONE || dt_is_reachable_from_entry(slu.dt, cbb) continue;
            block_successors(cbb, succs);
            for s: succs.* block_remove_predecessor(s, cbb);
            array_add(dead, cbb);
        }
    }
    for bb: li_blocks(li, l) visit(bb, vms, *dead, *succs);
    for bb: exit_blocks visit(bb, vms, *dead, *succs);
    if slu.mssau {
        set: [..] Value_Id; set.allocator = temp;
        for dead { dup := false; for x: set if x == it { dup = true; break; } if !dup array_add(*set, it); }
        mssau_remove_blocks(slu.mssau, set);
    }
    for dead slu_drop_block_references(it);
    for dead block_erase_from_parent(it);
}

delete_dead_blocks_from_loop :: (l: Loop_Id, exit_blocks: *[..] Value_Id) {
    li := slu.li; dt := slu.dt;
    dead_set: [..] Value_Id; dead_set.allocator = temp;     // SmallSetVector
    dead_tab: Table(Value_Id, bool); dead_tab.allocator = temp;
    cands: [..] Value_Id; cands.allocator = temp;
    for exit_blocks.* array_add(*cands, it);
    for li_blocks(li, l) array_add(*cands, it);
    succs: [..] Value_Id; succs.allocator = temp;
    while cands.count {
        bb := pop(*cands);
        if !table_contains(*dead_tab, bb) && !dt_is_reachable_from_entry(dt, bb) {
            block_successors(bb, *succs);
            for s: succs {
                block_remove_predecessor(s, bb);
                array_add(*cands, s);
            }
            table_set(*dead_tab, bb, true);
            array_add(*dead_set, bb);
        }
    }
    if slu.mssau mssau_remove_blocks(slu.mssau, dead_set);

    {
        w := 0;
        for exit_blocks.* { if table_contains(*dead_tab, it) continue; exit_blocks.*[w] = it; w += 1; }
        exit_blocks.count = w;
    }

    pl := l;
    while pl != NONE {
        for dead_set slu_set_erase(pl, it);
        slu_erase_blocks_if(pl, (b: Value_Id, d: *void) -> bool { return table_contains(cast(*Table(Value_Id, bool)) d, b); }, *dead_tab);
        pl = li_parent(li, pl);
    }

    {
        sl := *li.loops[l].subloops;
        w := 0;
        for k: 0..sl.count - 1 {
            child := sl.*[k];
            if !table_contains(*dead_tab, li_header(li, child)) { sl.*[w] = child; w += 1; continue; }
            lpm_mark_loop_as_deleted(slu.lpm, child);
            sc_forget_block_and_loop_dispositions();
            li_destroy_recursive(li, child);
        }
        sl.count = w;
    }

    for bb: dead_set {
        assert(dt_node(dt, bb) < 0, "Should already have cleared domtree!");
        li_change_loop_for(li, bb, NONE);
        for i: block_insts(bb) if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        slu_drop_block_references(bb);
    }
    for bb: dead_set block_erase_from_parent(bb);
}

// ---------------------------------------------------------------- recomputeLoopBlockSet / rebuildLoopAfterUnswitch

recompute_loop_block_set :: (l: Loop_Id, set: *Table(Value_Id, bool)) {
    li := slu.li;
    ph := li_loop_preheader(li, l);
    header := li_header(li, l);
    worklist: [..] Value_Id; worklist.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(header, *preds);
    for p: preds {
        if p == ph continue;
        assert(slu_contains(l, p), "Found a predecessor of the loop header other than the preheader that is not part of the loop!");
        if !table_contains(set, p) {
            table_set(set, p, true);
            if p != header array_add(*worklist, p);
        }
    }
    if set.count == 0 return;
    while worklist.count {
        bb := pop(*worklist);
        if bb == header continue;
        inner := li_loop_for(li, bb);
        if inner != NONE && inner != l {
            inner_ph := li_loop_preheader(li, inner);
            if table_contains(set, inner_ph) continue;
            table_set(set, inner_ph, true);
            for ib: li_blocks(li, inner) { if ib == bb continue; table_set(set, ib, true); }
            array_add(*worklist, inner_ph);
            continue;
        }
        block_predecessors(bb, *preds);
        for p: preds if slu_contains(l, p) && !table_contains(set, p) { table_set(set, p, true); array_add(*worklist, p); }
    }
}

rebuild_loop_after_unswitch :: (l: Loop_Id, exit_blocks: [] Value_Id, hoisted: *[..] Loop_Id) -> bool {
    li := slu.li;
    ph := li_loop_preheader(li, l);
    parent_l: Loop_Id = NONE;
    exits_in_loops: [..] Value_Id; exits_in_loops.allocator = temp;
    for e: exit_blocks {
        el := li_loop_for(li, e);
        if el == NONE continue;
        array_add(*exits_in_loops, e);
        if parent_l == NONE || (parent_l != el && li_contains_loop(li, parent_l, el)) parent_l = el;
    }
    lbs: Table(Value_Id, bool); lbs.allocator = temp;
    recompute_loop_block_set(l, *lbs);

    Ctx :: struct { l: Loop_Id; ph: Value_Id; }
    if lbs.count > 0 && li_parent(li, l) != parent_l {
        il := li_parent(li, l);
        c := Ctx.{l, ph};
        while il != parent_l {
            slu_set_erase(il, ph);
            for b: li_blocks(li, l) slu_set_erase(il, b);
            slu_erase_blocks_if(il, (b: Value_Id, d: *void) -> bool {
                c := cast(*Ctx) d;
                return b == c.ph || li_contains(slu.li, c.l, b);
            }, *c);
            il = li_parent(li, il);
        }
        li_change_loop_for(li, ph, parent_l);
        li_remove_child_loop(li, li_parent(li, l), l);
        if parent_l != NONE li_add_child_loop(li, parent_l, l);
        else li_add_top_level_loop(li, l);
    }

    // stable_partition of the block vector
    blocks := *li.loops[l].blocks;
    kept: [..] Value_Id; kept.allocator = temp;
    unlooped_list: [..] Value_Id; unlooped_list.allocator = temp;
    for blocks.* {
        if lbs.count > 0 && table_contains(*lbs, it) array_add(*kept, it);
        else array_add(*unlooped_list, it);
    }
    unlooped: Table(Value_Id, bool); unlooped.allocator = temp;
    for unlooped_list table_set(*unlooped, it, true);
    if lbs.count == 0 table_set(*unlooped, ph, true);
    for unlooped_list slu_set_erase(l, it);
    blocks.count = 0;
    for kept array_add(blocks, it);

    // stable_sort by ascending block loop depth
    for i: 1..exits_in_loops.count - 1 {
        x := exits_in_loops[i];
        dx := li_block_depth(li, x);
        j := i - 1;
        while j >= 0 && li_block_depth(li, exits_in_loops[j]) > dx { exits_in_loops[j + 1] = exits_in_loops[j]; j -= 1; }
        exits_in_loops[j + 1] = x;
    }

    remove_unlooped_blocks_from_loop :: (rl: Loop_Id, unlooped: *Table(Value_Id, bool)) {
        for unlooped.* slu_set_erase(rl, it_index);
        slu_erase_blocks_if(rl, (b: Value_Id, d: *void) -> bool { return table_contains(cast(*Table(Value_Id, bool)) d, b); }, unlooped);
    }

    new_exit_loop_blocks: [..] Value_Id; new_exit_loop_blocks.allocator = temp;
    nelb_set: Table(Value_Id, bool); nelb_set.allocator = temp;
    prev_exit_l := li_parent(li, l);
    worklist: [..] Value_Id; worklist.allocator = temp;
    preds: [..] Value_Id; preds.allocator = temp;
    while unlooped.count > 0 && exits_in_loops.count > 0 {
        exit_bb := pop(*exits_in_loops);
        exit_l := li_loop_for(li, exit_bb);
        assert(li_contains_loop(li, exit_l, l), "Exit loop must contain the inner loop!");
        while prev_exit_l != exit_l { remove_unlooped_blocks_from_loop(prev_exit_l, *unlooped); prev_exit_l = li_parent(li, prev_exit_l); }
        array_add(*worklist, exit_bb);
        while worklist.count {
            bb := pop(*worklist);
            if bb == ph continue;
            block_predecessors(bb, *preds);
            for p: preds {
                if !table_contains(*unlooped, p) continue;
                table_remove(*unlooped, p);
                table_set(*nelb_set, p, true);
                array_add(*new_exit_loop_blocks, p);
                array_add(*worklist, p);
            }
        }
        for bb: new_exit_loop_blocks {
            bbl := li_loop_for(li, bb);
            if bbl != NONE && (bbl == l || !li_contains_loop(li, l, bbl)) li_change_loop_for(li, bb, exit_l);
        }
        new_exit_loop_blocks.count = 0;
        table_reset(*nelb_set);
    }
    while prev_exit_l != NONE { remove_unlooped_blocks_from_loop(prev_exit_l, *unlooped); prev_exit_l = li_parent(li, prev_exit_l); }
    for unlooped {
        bb := it_index;
        bbl := li_loop_for(li, bb);
        if bbl != NONE && (bbl == l || !li_contains_loop(li, l, bbl)) li_change_loop_for(li, bb, NONE);
    }

    // sink the child loops whose headers left the loop
    subs := *li.loops[l].subloops;
    kept_l: [..] Loop_Id; kept_l.allocator = temp;
    hoisted_here: [..] Loop_Id; hoisted_here.allocator = temp;
    for subs.* {
        if lbs.count > 0 && table_contains(*lbs, li_header(li, it)) array_add(*kept_l, it);
        else array_add(*hoisted_here, it);
    }
    for hl: hoisted_here {
        array_add(hoisted, hl);
        li.loops[hl].parent = NONE;
        np := li_loop_for(li, li_loop_preheader(li, hl));
        if np != NONE li_add_child_loop(li, np, hl);
        else li_add_top_level_loop(li, hl);
    }
    subs.count = 0;
    for kept_l array_add(subs, it);

    if li.loops[l].blocks.count == 0 {
        assert(li.loops[l].subloops.count == 0, "Failed to remove all subloops from the original loop!");
        pl := li_parent(li, l);
        if pl != NONE li_remove_child_loop(li, pl, l);
        else li_remove_top_level_loop(li, l);
        sc_forget_block_and_loop_dispositions();
        li_destroy(li, l);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- postUnswitch

post_unswitch :: (l: Loop_Id, current_loop_valid: bool, partially_invariant: bool, injected_condition: bool, new_loops: [] Loop_Id) {
    if new_loops.count lpm_add_sibling_loops(slu.lpm, slu.li, new_loops);
    if current_loop_valid {
        if partially_invariant li_add_string_loop_attribute(slu.li, l, "llvm.loop.unswitch.partial.disable", .["llvm.loop.unswitch.partial"]);
        else if injected_condition li_add_string_loop_attribute(slu.li, l, "llvm.loop.unswitch.injection.disable", .["llvm.loop.unswitch.injection"]);
        else lpm_revisit_current_loop(slu.lpm);
    } else lpm_mark_loop_as_deleted(slu.lpm, l);
}

// ---------------------------------------------------------------- unswitchNontrivialInvariants

Iv_Condition_Info :: struct {
    inst_to_duplicate: [..] Value_Id;
    known_value: Value_Id = NONE;
    path_is_noop := true;
    exit_for_path: Value_Id = NONE;
}

unswitch_nontrivial_invariants :: (l: Loop_Id, ti: Value_Id, invariants: [] Value_Id, partial_iv: *Iv_Condition_Info,
                                   insert_freeze: bool, injected_condition: bool) {
    li := slu.li; dt := slu.dt; mssau := slu.mssau;
    parent_bb := inst_block(ti);
    is_bi := inst_op(ti) == .CONDBR;
    is_si := !is_bi;
    assert(is_bi || inst_op(ti) == .SWITCH, "Can only unswitch switches and conditional branch!");
    partially_invariant := partial_iv.inst_to_duplicate.count > 0;
    full_unswitch := is_si || (skip_trivial_select(op(ti, 0)) == invariants[0] && !partially_invariant);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    direction := true;
    cloned_succ: u32 = 0;
    if !full_unswitch {
        cond := skip_trivial_select(op(ti, 0));
        if !is_logical_or(cond) {
            if is_logical_and(cond) || (partially_invariant && !is_one_value(partial_iv.known_value)) {
                direction = false;
                cloned_succ = 1;
            }
        }
    }

    retained_succ := ifx is_bi then get_successor(ti, 1 - cloned_succ) else sw_default(ti);
    unswitched_succs: [..] Value_Id; unswitched_succs.allocator = temp;   // SmallSetVector
    add_unique :: (a: *[..] Value_Id, b: Value_Id) { for a.* if it == b return; array_add(a, b); }
    if is_bi add_unique(*unswitched_succs, get_successor(ti, cloned_succ));
    else for k: 0..cast(s64) sw_num_cases(ti) - 1 {
        s := sw_case_dest(ti, cast(u32) k);
        if s != retained_succ add_unique(*unswitched_succs, s);
    }

    assert(li_loop_for(li, parent_bb) == l, "Branch in an inner loop!");

    parent_l := li_parent(li, l);
    lbrpo: [..] Value_Id; lbrpo.allocator = temp;
    if mssau loop_blocks_rpo(li, l, *lbrpo);

    outer_exit_l := l;
    exit_blocks: [..] Value_Id; exit_blocks.allocator = temp;
    li_unique_exit_blocks(li, l, *exit_blocks);
    for e: exit_blocks {
        noel := get_top_most_exiting_loop(e);
        if noel == NONE { outer_exit_l = NONE; break; }
        if noel != outer_exit_l && li_contains_loop(li, noel, outer_exit_l) outer_exit_l = noel;
    }

    if outer_exit_l != NONE sc_forget_loop(outer_exit_l);
    else sc_forget_topmost_loop(l);
    sc_forget_block_and_loop_dispositions();

    dominating_succ: Dom_Succ_Map; dominating_succ.allocator = temp;
    {
        succ_list: [..] Value_Id; succ_list.allocator = temp;
        array_add(*succ_list, retained_succ);
        for unswitched_succs array_add(*succ_list, it);
        preds: [..] Value_Id; preds.allocator = temp;
        for s: succ_list {
            ok := block_unique_predecessor(s) != NONE;
            if !ok {
                ok = true;
                block_predecessors(s, *preds);
                for p: preds if !(p == parent_bb || dt_dominates(dt, s, p)) { ok = false; break; }
            }
            if !ok continue;
            // visitDomSubTree
            wl: [..] s32; wl.allocator = temp;
            array_add(*wl, dt_node(dt, s));
            while wl.count {
                n := pop(*wl);
                table_set(*dominating_succ, dt.nodes[n].block, s);
                c := dt.nodes[n].first_child;
                while c >= 0 { array_add(*wl, c); c = dt.nodes[c].sibling; }
            }
        }
    }

    split_bb := li_loop_preheader(li, l);
    loop_ph := slu_split_edge(split_bb, li_header(li, l));

    dt_updates: [..] Dom_Update; dt_updates.allocator = temp;

    vms: [..] *Value_Map; vms.allocator = temp;
    cloned_phs: [..] Value_Id; cloned_phs.allocator = temp;   // parallel to unswitched_succs
    for s: unswitched_succs {
        vm := New(Value_Map,, allocator = temp);
        vmap_init(vm);
        array_add(*vms, vm);
        array_add(*cloned_phs, build_cloned_loop_blocks(l, loop_ph, split_bb, exit_blocks, parent_bb, s, retained_succ,
                                                        *dominating_succ, vm, *dt_updates));
    }
    cloned_ph_of :: (succs: [] Value_Id, phs: [] Value_Id, s: Value_Id) -> Value_Id {
        for succs if it == s return phs[it_index];
        return NONE;
    }

    mi := md_fixed("make.implicit");
    if get_metadata(ti, mi) != NONE {
        if slu_opts.drop_non_trivial_implicit_null_checks set_metadata(ti, mi, NONE);
        else {
            safety: Loop_Safety_Info;
            lsi_compute(*safety, li, l);
            if !lsi_is_guaranteed_to_execute(*safety, ti, dt, l) set_metadata(ti, mi, NONE);
        }
    }

    slu_erase_terminator_keep_trailing(block_terminator(split_bb));
    if full_unswitch {
        new_ti := inst_clone(ti);
        block_append_inst(parent_bb, new_ti);
        // TI.moveBefore(*SplitBB, SplitBB->end()): its records fall onto the next instruction (NewTI)
        r := records_take(ti);
        if r records_prepend(new_ti, r);
        inst_unlink(ti);
        slu_append(split_bb, ti);
        drop_location(ti);

        if is_bi {
            cph := cloned_phs[0];
            set_successor(ti, cloned_succ, cph);
            set_successor(ti, 1 - cloned_succ, loop_ph);
            cond := skip_trivial_select(op(ti, 0));
            if insert_freeze {
                fr := new_inst(.FREEZE, vtype(cond), 1);
                set_op(fr, 0, cond);
                insert_at_position(fr, split_bb, ti, false);
                set_name(fr, tprint("%.fr", vname(cond)));
                cond = fr;
            }
            set_op(ti, 0, cond);
            array_add(*dt_updates, .{true, split_bb, cph});
        } else {
            assert(sw_default(ti) == retained_succ, "Not retaining default successor!");
            sw_set_default(ti, loop_ph);
            for k: 0..cast(s64) sw_num_cases(ti) - 1 {
                s := sw_case_dest(ti, cast(u32) k);
                if s == retained_succ sw_set_case_dest(ti, cast(u32) k, loop_ph);
                else sw_set_case_dest(ti, cast(u32) k, cloned_ph_of(unswitched_succs, cloned_phs, s));
            }
            if insert_freeze {
                c := sw_cond(ti);
                fr := new_inst(.FREEZE, vtype(c), 1);
                set_op(fr, 0, c);
                insert_at_position(fr, split_bb, ti, false);
                set_name(fr, tprint("%.fr", vname(c)));
                set_op(ti, 0, fr);
            }
            for s: unswitched_succs array_add(*dt_updates, .{true, split_bb, cloned_ph_of(unswitched_succs, cloned_phs, s)});
        }

        if mssau {
            dt_apply_updates(dt, dt_updates);
            dt_updates.count = 0;
            mssau_remove_duplicate_phi_edges_between(mssau, parent_bb, retained_succ);
            for s: unswitched_succs mssau_remove_duplicate_phi_edges_between(mssau, parent_bb, s);
            maps: [..] *Table(Value_Id, Value_Id); maps.allocator = temp;
            for vm: vms {
                mssau_update_for_cloned_loop(mssau, lbrpo, exit_blocks, *vm.map, true);
                array_add(*maps, *vm.map);
            }
            mssau_update_exit_blocks_for_cloned_loop(mssau, exit_blocks, maps, dt);
            for s: unswitched_succs mssau_remove_edge(mssau, parent_bb, s);
        }

        if is_bi {
            us := unswitched_succs[0];
            block_remove_predecessor(us, parent_bb, true);
            array_add(*dt_updates, .{false, parent_bb, us});
        } else {
            assert(sw_default(new_ti) == retained_succ, "Not retaining default successor!");
            for k: 0..cast(s64) sw_num_cases(new_ti) - 1 block_remove_predecessor(sw_case_dest(new_ti, cast(u32) k), parent_bb, true);
            for s: unswitched_succs array_add(*dt_updates, .{false, parent_bb, s});
        }

        nbi := create_br(retained_succ);
        block_append_inst(parent_bb, nbi);
        copy_debug_loc_or_clear(nbi, new_ti);
        drop_all_references(new_ti);
        erase_inst_with_metadata(new_ti);
    } else {
        assert(is_bi, "Only branches have partial unswitching.");
        cph := cloned_phs[0];
        if partially_invariant
            build_partial_invariant_unswitch_conditional_branch(split_bb, invariants, direction, cph, loop_ph, l, mssau, ti);
        else
            build_partial_unswitch_conditional_branch(split_bb, invariants, direction, cph, loop_ph, slu_opts.freeze_cond, ti, slu.ac, dt, ti);
        array_add(*dt_updates, .{true, split_bb, cph});
        if mssau {
            dt_apply_updates(dt, dt_updates);
            dt_updates.count = 0;
            maps: [..] *Table(Value_Id, Value_Id); maps.allocator = temp;
            for vm: vms {
                mssau_update_for_cloned_loop(mssau, lbrpo, exit_blocks, *vm.map, true);
                array_add(*maps, *vm.map);
            }
            mssau_update_exit_blocks_for_cloned_loop(mssau, exit_blocks, maps, dt);
        }
    }

    dt_apply_updates(dt, dt_updates);

    delete_dead_cloned_blocks(l, exit_blocks, vms);

    non_child_cloned: [..] Loop_Id; non_child_cloned.allocator = temp;
    for vm: vms build_cloned_loops(l, exit_blocks, vm, *non_child_cloned);

    delete_dead_blocks_from_loop(l, *exit_blocks);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    hoisted: [..] Loop_Id; hoisted.allocator = temp;
    is_still_loop := rebuild_loop_after_unswitch(l, exit_blocks, *hoisted);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);

    if is_bi && !partially_invariant {
        cph := cloned_phs[0];
        replace_unswitched := full_unswitch || invariants.count == 1 || partially_invariant;
        unswitched_repl := const_int(ir.t_i1, ifx direction then cast(u64) 1 else 0);
        continue_repl := const_int(ir.t_i1, ifx direction then cast(u64) 0 else 1);
        for inv: invariants {
            assert(!is_constant_kind(vkind(inv)), "Should not be replacing constant values!");
            u := ir.v_first_use[inv];
            while u != NONE {
                nx := ir.u_next[u];
                user := ir.u_user[u];
                if is_inst(user) {
                    ub := inst_block(user);
                    if dt_dominates(dt, loop_ph, ub) use_set(u, continue_repl);
                    else if replace_unswitched && dt_dominates(dt, cph, ub) use_set(u, unswitched_repl);
                }
                u = nx;
            }
        }
    }

    update_loop :: (ul: Loop_Id) {
        form_lcssa(slu.li, ul, slu.dt);
        form_dedicated_exit_blocks(slu.li, ul, slu.dt, slu.mssau, true);
    }
    for ul: non_child_cloned { update_loop(ul); if li_is_outermost(li, ul) outer_exit_l = NONE; }
    for ul: hoisted { update_loop(ul); if li_is_outermost(li, ul) outer_exit_l = NONE; }
    if is_still_loop {
        update_loop(l);
        if li_is_outermost(li, l) outer_exit_l = NONE;
    }
    if outer_exit_l != l {
        ol := parent_l;
        while ol != outer_exit_l { update_loop(ol); ol = li_parent(li, ol); }
    }

    sib: [..] Loop_Id; sib.allocator = temp;
    for ul: non_child_cloned if li_parent(li, ul) == parent_l array_add(*sib, ul);
    for ul: hoisted if li_parent(li, ul) == parent_l array_add(*sib, ul);
    post_unswitch(l, is_still_loop, partially_invariant, injected_condition, sib);

    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
}

// ---------------------------------------------------------------- cost model

compute_dom_subtree_cost :: (n: s32, bb_cost: *Table(Value_Id, Cost), dt_cost: *Table(s32, Cost)) -> Cost {
    dt := slu.dt;
    found, c := table_find(bb_cost, dt.nodes[n].block);
    if !found return 0;
    f2, memo := table_find(dt_cost, n);
    if f2 return memo;
    cost := c;
    ch := dt.nodes[n].first_child;
    while ch >= 0 { cost = cost_add(cost, compute_dom_subtree_cost(ch, bb_cost, dt_cost)); ch = dt.nodes[ch].sibling; }
    table_set(dt_cost, n, cost);
    return cost;
}

// turnSelectIntoBranch
turn_select_into_branch :: (si: Value_Id) -> Value_Id {
    li := slu.li; dt := slu.dt; mssau := slu.mssau;
    head := inst_block(si);
    then_bb, tail := slu_split_block_and_insert_if_then(op(si, 0), si, false, get_metadata(si, md_kind_id(MD_PROF_NAME)));
    cbr := block_terminator(head);
    then_bb = get_successor(cbr, 0);
    tail = get_successor(cbr, 1);
    if mssau mssau_move_all_after_splice_blocks(mssau, head, tail, si);
    phi := create_phi(vtype(si), 2);
    insert_at_position(phi, tail, si, false);
    set_name(phi, "unswitched.select");
    phi_add_incoming(phi, op(si, 1), then_bb);
    phi_add_incoming(phi, op(si, 2), head);
    copy_debug_loc_or_clear(phi, si);
    rauw_with_metadata(si, phi);
    erase_inst_with_metadata(si);
    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
    return cbr;
}

// turnGuardIntoBranch
turn_guard_into_branch :: (gi: Value_Id, l: Loop_Id) -> Value_Id {
    mssau := slu.mssau;
    check_bb := inst_block(gi);
    if mssau && mssa_opts.verify mssa_verify(mssau.mssa);
    weights: Md_Id = NONE;
    if !slu_opts.profcheck_disable_metadata_fixes && slu_opts.estimate_profile {
        ops: [3] Md_Id;
        ops[0] = md_string("branch_weights");
        ops[1] = md_value(const_int(ir.t_i32, 1));
        ops[2] = md_value(const_int(ir.t_i32, (1 << 20) - 1));
        weights = md_tuple(ops, false);
    }
    deopt_bb, tail := slu_split_block_and_insert_if_then(call_arg(gi, 0), gi, true, weights);
    deopt_term := block_terminator(deopt_bb);
    check_bi := block_terminator(check_bb);
    condbr_swap_successors(check_bi);
    guarded := get_successor(check_bi, 0);
    set_name(guarded, "guarded");
    set_name(get_successor(check_bi, 1), "deopt");
    deopt_block := get_successor(check_bi, 1);
    if mssau mssau_move_all_after_splice_blocks(mssau, check_bb, guarded, gi);
    inst_move_before_dbg(gi, deopt_term);
    set_op(gi, 0, const_int(ir.t_i1, 0));
    if mssau {
        md := mssa_access_of(mssau.mssa, gi);
        mssau_move_to_place(mssau, md, deopt_block, .BEFORE_TERMINATOR);
        if mssa_opts.verify mssa_verify(mssau.mssa);
    }
    return check_bi;
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore (no head bit), Unreachable, BranchWeights, DTU (eager), LI):
// (then block, tail)
slu_split_block_and_insert_if_then :: (cond: Value_Id, split_before: Value_Id, unreachable: bool, weights: Md_Id) -> (Value_Id, Value_Id) {
    li := slu.li; dt := slu.dt;
    head := inst_block(split_before);
    orig: [..] Value_Id; orig.allocator = temp;
    {
        tmp: [..] Value_Id; tmp.allocator = temp;
        block_successors(head, *tmp);
        for tmp { dup := false; for x: orig if x == it { dup = true; break; } if !dup array_add(*orig, it); }
    }
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    bb := create_block(f, "", tail);
    then_to_tail := false;
    t: Value_Id;
    if unreachable {
        t = new_inst(.UNREACHABLE, ir.t_void, 0);
        block_append_inst(bb, t);
    } else {
        t = create_br(tail);
        block_append_inst(bb, t);
        then_to_tail = true;
    }
    copy_debug_loc_or_clear(t, split_before);
    old := block_terminator(head);
    nt := create_cond_br(cond, bb, tail);
    if weights != NONE set_metadata(nt, md_kind_id(MD_PROF_NAME), weights);
    if get_metadata(nt, 0) == NONE copy_debug_loc(nt, old);
    insert_at_position(nt, head, old, false);
    erase_terminator(old);
    ups: [..] Dom_Update; ups.allocator = temp;
    array_add(*ups, .{true, head, bb});
    array_add(*ups, .{true, head, tail});
    if then_to_tail array_add(*ups, .{true, bb, tail});
    for orig array_add(*ups, .{true, tail, it});
    for orig array_add(*ups, .{false, head, it});
    dt_apply_updates(dt, ups);
    l := li_loop_for(li, head);
    if l != NONE {
        if then_to_tail li_add_basic_block_to_loop(li, l, bb);
        li_add_basic_block_to_loop(li, l, tail);
    }
    return bb, tail;
}

Slu_Candidate :: struct {
    ti: Value_Id;
    invariants: [..] Value_Id;
    has_cost: bool;
    cost: Cost;
    has_injection: bool;
    inj_pred: u8;
    inj_lhs: Value_Id;
    inj_rhs: Value_Id;
    inj_in_loop_succ: Value_Id;
}

slu_candidate :: (ti: Value_Id, invs: [] Value_Id) -> Slu_Candidate {
    c: Slu_Candidate;
    c.ti = ti;
    c.invariants.allocator = temp;
    for invs array_add(*c.invariants, it);
    return c;
}

calculate_unswitch_cost_multiplier :: (ti: Value_Id, l: Loop_Id, cands: [] Slu_Candidate) -> s64 {
    li := slu.li; dt := slu.dt;
    latch := li_loop_latch(li, l);
    cond_block := inst_block(ti);
    if dt_dominates(dt, cond_block, latch) {
        if is_guard(ti) return 1;
        if is_terminator(inst_op(ti)) {
            n := 0;
            ns := num_successors(ti);
            for k: 0..cast(s64) ns - 1 if slu_contains(l, get_successor(ti, cast(u32) k)) n += 1;
            if n <= 1 return 1;
        }
    }
    parent_l := li_parent(li, l);
    parent_size_mult: s64 = 1;
    if parent_l != NONE parent_size_mult = max(cast(s64) li_num_blocks(li, parent_l) / slu_opts.parent_blocks_div, 1);
    siblings := ifx parent_l != NONE then cast(s64) li_subloops(li, parent_l).count else cast(s64) li.top_level.count;
    clones: s64 = 0;
    for c: cands {
        ci := c.ti;
        cb := inst_block(ci);
        skip_exiting := dt_dominates(dt, cb, latch);
        if inst_op(ci) == .SELECT { clones += 1; continue; }
        if is_guard(ci) { if !skip_exiting clones += 1; continue; }
        t := block_terminator(cb);
        non_exiting: u32 = 0;
        ns := num_successors(t);
        for k: 0..cast(s64) ns - 1 if !skip_exiting || slu_contains(l, get_successor(t, cast(u32) k)) non_exiting += 1;
        clones += slu_log2_32(non_exiting);
    }
    clones_power: u32 = cast(u32) max(clones - slu_opts.num_initial_unscaled_candidates, 0);
    siblings_mult := max(ifx parent_l != NONE then siblings else siblings / slu_opts.siblings_toplevel_div, 1);
    thr := slu_opts.threshold;
    log2_thr: u64 = ifx cast,trunc(u32) thr == 0 then 0xFFFF_FFFF else cast(u64) slu_log2_32(cast,trunc(u32) thr);
    if cast(u64) clones_power > log2_thr || siblings_mult > thr || parent_size_mult > thr return thr;
    return min(siblings_mult * ((cast(s64) 1) << clones_power), thr);
}

slu_cmp_predicate :: (pred: u8) -> u8 { return pred; }

collect_unswitch_candidates :: (cands: *[..] Slu_Candidate, partial_iv: *Iv_Condition_Info, partial_iv_cond_branch: *Value_Id,
                                l: Loop_Id) {
    li := slu.li; mssau := slu.mssau;
    add_for_inst :: (cands: *[..] Slu_Candidate, l: Loop_Id, i: Value_Id, cond_in: Value_Id) {
        cond := skip_trivial_select(cond_in);
        if is_constant_kind(vkind(cond)) return;
        if slu_invariant(l, cond) { array_add(cands, slu_candidate(i, .[cond])); return; }
        if is_logical_and(cond) || is_logical_or(cond) {
            invs: [..] Value_Id; invs.allocator = temp;
            collect_homogenous_inst_graph_loop_invariants(l, cond, *invs);
            if invs.count array_add(cands, slu_candidate(i, invs));
        }
    }
    collect_guards := false;
    if slu_opts.guards {
        for f: ir.m_functions if vkind(f) == .FUNCTION && vname(f) == "llvm.experimental.guard" && has_uses(f) { collect_guards = true; break; }
    }
    for bb: li_blocks(li, l) {
        if li_loop_for(li, bb) != l continue;
        for i: block_insts(bb) {
            if inst_op(i) == .SELECT {
                c := op(i, 0);
                if vtype(c) == ir.t_i1 && vtype(i) != ir.t_i1 add_for_inst(cands, l, i, c);
            } else if collect_guards && is_guard(i) {
                c := skip_trivial_select(call_arg(i, 0));
                if !is_constant_kind(vkind(c)) && slu_invariant(l, c) array_add(cands, slu_candidate(i, .[c]));
            }
        }
        t := block_terminator(bb);
        if inst_op(t) == .SWITCH {
            c := sw_cond(t);
            if !is_constant_kind(vkind(c)) && slu_invariant(l, c) && block_unique_successor(bb) == NONE
                array_add(cands, slu_candidate(t, .[c]));
            continue;
        }
        if inst_op(t) != .CONDBR || get_successor(t, 0) == get_successor(t, 1) continue;
        add_for_inst(cands, l, t, op(t, 0));
    }

    if mssau && find_option_md_for_loop_id(li_loop_id(li, l), "llvm.loop.unswitch.partial.disable") == NONE {
        hdr_term := block_terminator(li_header(li, l));
        any := false;
        for cands.* if it.ti == hdr_term { any = true; break; }
        if !any {
            info: Iv_Condition_Info;
            info.inst_to_duplicate.allocator = temp;
            if has_partial_iv_condition(l, slu_opts.mssa_threshold, mssau.mssa, *info) {
                partial_iv.* = info;
                partial_iv_cond_branch.* = hdr_term;
                array_add(cands, slu_candidate(hdr_term, info.inst_to_duplicate));
            }
        }
    }
}

// hasPartialIVCondition (LoopUtils.cpp)
has_partial_iv_condition :: (l: Loop_Id, mssa_threshold: s64, m: *Memory_SSA, out: *Iv_Condition_Info) -> bool {
    li := slu.li;
    ti := block_terminator(li_header(li, l));
    if inst_op(ti) != .CONDBR return false;
    cond_i := op(ti, 0);
    if !is_inst(cond_i) return false;
    co := inst_op(cond_i);
    if !(co == .ICMP || co == .FCMP || co == .TRUNC) || !slu_contains(l, inst_block(cond_i)) return false;

    inst_to_dup: [..] Value_Id; inst_to_dup.allocator = temp;
    array_add(*inst_to_dup, cond_i);
    worklist: [..] Value_Id; worklist.allocator = temp;
    for k: 0..cast(s64) nops(cond_i) - 1 array_add(*worklist, op(cond_i, cast(u32) k));
    accesses: [..] s32; accesses.allocator = temp;
    locs: [..] Mem_Loc; locs.allocator = temp;
    while worklist.count {
        i := pop(*worklist);
        if !is_inst(i) || !slu_contains(l, inst_block(i)) continue;
        o := inst_op(i);
        if o != .LOAD && o != .GEP return false;
        if o == .LOAD && (is_volatile(i) || inst_is_atomic(i)) return false;
        array_add(*inst_to_dup, i);
        ma := mssa_access_of(m, i);
        if ma >= 0 {
            if ma_is_use(m, ma) {
                array_add(*accesses, ma_defining(m, ma));
                array_add(*locs, mloc_get(i));
            } else return false;
        }
        for k: 0..cast(s64) nops(i) - 1 array_add(*worklist, op(i, cast(u32) k));
    }
    if inst_to_dup.count == 0 return false;

    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    aar := aa_results_for(li.fn);

    has_no_clobbers_on_path :: (l: Loop_Id, succ: Value_Id, header: Value_Id, accesses_in: [] s32, locs: [] Mem_Loc,
                                exiting: [] Value_Id, m: *Memory_SSA, aar: *Aa_Results, mssa_threshold: s64) -> (bool, bool, Value_Id) {
        path_is_noop := true;
        exit_for_path: Value_Id = NONE;
        wl: [..] Value_Id; wl.allocator = temp;
        array_add(*wl, succ);
        array_add(*wl, header);
        seen: Table(Value_Id, bool); seen.allocator = temp;
        table_set(*seen, header, true);
        no_side :: (bb: Value_Id) -> bool { for block_insts(bb) if may_have_side_effects(it) return false; return true; }
        path_is_noop &&= no_side(header);
        succs: [..] Value_Id; succs.allocator = temp;
        while wl.count {
            cur := pop(*wl);
            if !slu_contains(l, cur) continue;
            if table_contains(*seen, cur) continue;
            table_set(*seen, cur, true);
            path_is_noop &&= no_side(cur);
            block_successors(cur, *succs);
            for succs array_add(*wl, it);
        }
        if seen.count < 2 return false, false, NONE;
        to_check: [..] s32; to_check.allocator = temp;
        for accesses_in array_add(*to_check, it);
        seen_acc: Table(s32, bool); seen_acc.allocator = temp;
        users: [..] s32; users.allocator = temp;
        while to_check.count {
            cur := pop(*to_check);
            if table_contains(*seen_acc, cur) continue;
            table_set(*seen_acc, cur, true);
            if !table_contains(*seen, ma_block(m, cur)) continue;
            if cast(s64) seen_acc.count >= mssa_threshold return false, false, NONE;
            if ma_is_use(m, cur) continue;
            if ma_is_def(m, cur) {
                for loc: locs {
                    q := aa_query_new(aar);
                    if mr_is_mod_set(aa_mod_ref_inst_loc(q, ma_inst(m, cur), loc)) return false, false, NONE;
                }
            }
            ma_users(m, cur, *users);
            for users array_add(*to_check, it);
        }
        path_is_noop &&= (fn_must_progress(slu.li.fn) || li_has_must_progress(l));
        if path_is_noop {
            for ex: exiting {
                if !table_contains(*seen, ex) continue;
                block_successors(ex, *succs);
                for s: succs {
                    if slu_contains(l, s) continue;
                    has_phi := block_first(s) != NONE && inst_op(block_first(s)) == .PHI;
                    path_is_noop &&= !has_phi && (exit_for_path == NONE || exit_for_path == s);
                    if !path_is_noop break;
                    exit_for_path = s;
                }
            }
        }
        if exit_for_path == NONE path_is_noop = false;
        return true, path_is_noop, exit_for_path;
    }

    if get_successor(ti, 0) == get_successor(ti, 1) return false;
    for k: 0..1 {
        ok, noop, ex := has_no_clobbers_on_path(l, get_successor(ti, cast(u32) k), li_header(li, l), accesses, locs, exiting, m, *aar, mssa_threshold);
        if ok {
            out.path_is_noop = noop;
            out.exit_for_path = ex;
            for inst_to_dup array_add(*out.inst_to_duplicate, it);
            out.known_value = const_int(ir.t_i1, ifx k == 0 then cast(u64) 1 else 0);
            return true;
        }
    }
    return false;
}

// canonicalizeForInvariantConditionInjection
canonicalize_for_invariant_condition_injection :: (pred: *u8, lhs: *Value_Id, rhs: *Value_Id, if_true: *Value_Id, if_false: *Value_Id, l: Loop_Id) {
    if !slu_contains(l, if_true.*) {
        pred.* = cmp_inverse(pred.*);
        t := if_true.*; if_true.* = if_false.*; if_false.* = t;
    }
    if slu_invariant(l, lhs.*) {
        pred.* = cmp_swapped(pred.*);
        t := lhs.*; lhs.* = rhs.*; rhs.* = t;
    }
    if pred.* == ICMP_SGE && pm_zero(rhs.*) {
        pred.* = ICMP_ULT;
        t := vtype(rhs.*);
        rhs.* = const_int_ap(t, ap_signed_min(type_int_width(t)));
    }
}

should_try_inject_invariant_condition :: (pred: u8, lhs: Value_Id, rhs: Value_Id, if_true: Value_Id, if_false: Value_Id, l: Loop_Id) -> bool {
    if slu_invariant(l, lhs) || !slu_invariant(l, rhs) return false;
    if pred != ICMP_ULT return false;
    if !slu_contains(l, if_true) || slu_contains(l, if_false) return false;
    if li_header(slu.li, l) == if_true return false;
    return true;
}

should_try_inject_basing_on_metadata :: (bi: Value_Id, taken_succ: Value_Id) -> bool {
    ok, ws := prof_extract_branch_weights(bi);
    if !ok return false;
    assert(ws.count == 2, "Unexpected profile data!");
    t := cast,trunc(u32) slu_opts.inject_hotness_threshold;
    likely_taken := bprob_get(cast(u64) (t - 1), cast(u64) t);
    idx := ifx get_successor(bi, 0) == taken_succ then 0 else 1;
    num := cast,trunc(u32) ws[idx];
    denom := cast,trunc(u32) ws[0] + cast,trunc(u32) ws[1];
    if denom == 0 || num > denom return false;
    actual := bprob_get(cast(u64) num, cast(u64) denom);
    if likely_taken > actual return false;
    return true;
}

inject_pending_invariant_conditions :: (c: *Slu_Candidate, l: Loop_Id) -> Slu_Candidate {
    li := slu.li; dt := slu.dt; mssau := slu.mssau;
    preheader := li_loop_preheader(li, l);
    pred := c.inj_pred;
    lhs := c.inj_lhs;
    rhs := c.inj_rhs;
    in_loop_succ := c.inj_in_loop_succ;
    ti := c.ti;
    bb := inst_block(ti);
    out_of_loop_succ := ifx in_loop_succ == get_successor(ti, 0) then get_successor(ti, 1) else get_successor(ti, 0);
    assert(slu_contains(l, in_loop_succ) && !slu_contains(l, out_of_loop_succ), "Not supported yet!");
    b: Irb;
    irb_set_before(*b, block_terminator(preheader));
    if vtype(lhs) != vtype(rhs) {
        if type_int_width(vtype(lhs)) < type_int_width(vtype(rhs)) lhs = irb_cast(*b, .ZEXT, lhs, vtype(rhs), tprint("%.wide", vname(lhs)));
        else rhs = irb_cast(*b, .ZEXT, rhs, vtype(lhs), tprint("%.wide", vname(rhs)));
    }
    injected := create_icmp(pred, lhs, rhs);
    insert_at_position(injected, preheader, block_terminator(preheader), false);
    set_name(injected, "injected.cond");

    f := block_fn(bb);
    check := create_block(f, tprint("%.check", vname(bb)), in_loop_succ);
    irb_set_before(*b, ti);
    inv_br := irb_insert(*b, create_cond_br(injected, in_loop_succ, check));
    set_explicitly_unknown_branch_weights_if_profiled(inv_br, SLU_DEBUG_TYPE);
    irb_set_end(*b, check);
    nbr := create_cond_br(op(ti, 0), get_successor(ti, 0), get_successor(ti, 1));
    if !slu_opts.profcheck_disable_metadata_fixes {
        p := prof_md(ti);
        if p != NONE set_metadata(nbr, md_kind_id(MD_PROF_NAME), p);
    }
    irb_insert(*b, nbr);
    drop_all_references(ti);
    erase_inst_with_metadata(ti);

    for pn: block_insts(in_loop_succ) {
        if inst_op(pn) != .PHI break;
        inc := phi_value(pn, cast(u32) phi_block_index(pn, bb));
        phi_add_incoming(pn, inc, check);
    }
    block_replace_phi_uses_with(out_of_loop_succ, bb, check);

    ups: [..] Dom_Update; ups.allocator = temp;
    array_add(*ups, .{true, bb, check});
    array_add(*ups, .{true, check, in_loop_succ});
    array_add(*ups, .{true, check, out_of_loop_succ});
    array_add(*ups, .{false, bb, out_of_loop_succ});
    dt_apply_updates(dt, ups);
    if mssau mssau_apply_updates(mssau, ups, dt, false);
    li_add_basic_block_to_loop(li, l, check);

    r := slu_candidate(inv_br, .[injected]);
    r.has_cost = c.has_cost; r.cost = c.cost;
    return r;
}

collect_unswitch_candidates_with_injections :: (cands: *[..] Slu_Candidate, l: Loop_Id) -> bool {
    li := slu.li; dt := slu.dt;
    if !slu_opts.inject_invariant_conditions return false;
    if !dt_is_reachable_from_entry(dt, li_header(li, l)) return false;
    latch := li_loop_latch(li, l);
    if latch == NONE return false;
    Compare_Desc :: struct { term: Value_Id; invariant: Value_Id; in_loop_succ: Value_Id; }
    Group :: struct { key: Value_Id; descs: [..] Compare_Desc; }
    groups: [..] Group; groups.allocator = temp;   // DenseMap<Value *, ...> (iterated in first-insertion order here)
    n := dt_node(dt, latch);
    while slu_contains(l, dt.nodes[n].block) {
        bb := dt.nodes[n].block;
        defer n = dt.nodes[n].idom;
        if li_loop_for(li, bb) != l continue;
        term := block_terminator(bb);
        if inst_op(term) != .CONDBR continue;
        ok, pred, _, lhs, rhs := pm_icmp(op(term, 0));
        if !ok continue;
        if_true := get_successor(term, 0);
        if_false := get_successor(term, 1);
        if !is_int_type(vtype(lhs)) continue;
        canonicalize_for_invariant_condition_injection(*pred, *lhs, *rhs, *if_true, *if_false, l);
        if !should_try_inject_invariant_condition(pred, lhs, rhs, if_true, if_false, l) continue;
        if !should_try_inject_basing_on_metadata(term, if_true) continue;
        desc := Compare_Desc.{term, rhs, if_true};
        while opr_code(lhs) == .ZEXT && is_inst(lhs) lhs = op(lhs, 0);
        g: *Group = null;
        for * groups if it.key == lhs { g = it; break; }
        if !g {
            ng: Group; ng.key = lhs; ng.descs.allocator = temp;
            array_add(*groups, ng);
            g = *groups[groups.count - 1];
        }
        array_add(*g.descs, desc);
    }
    found := false;
    for g: groups {
        if g.descs.count < 2 continue;
        non_strict := cmp_non_strict(ICMP_ULT);
        for k: 0..g.descs.count - 2 {
            prev := g.descs[k]; next := g.descs[k + 1];
            c := slu_candidate(prev.term, .[next.invariant, prev.invariant]);
            c.has_injection = true;
            c.inj_pred = non_strict;
            c.inj_lhs = next.invariant;
            c.inj_rhs = prev.invariant;
            c.inj_in_loop_succ = prev.in_loop_succ;
            array_add(cands, c);
        }
        found = true;
    }
    return found;
}

is_safe_for_non_trivial_unswitching :: (l: Loop_Id) -> bool {
    li := slu.li;
    if !li_is_safe_to_clone(li, l) return false;
    for bb: li_blocks(li, l) for i: block_insts(bb) {
        if type_kind(vtype(i)) == .TOKEN && is_used_outside_of_block(i, bb) return false;
        if is_call_base(i) && call_has_fn_attr(i, .Convergent) return false;
    }
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);
    if contains_irreducible_cfg_rpo(li, rpo) return false;
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits);
    for e: exits {
        x := block_first_non_phi(e);
        if x != NONE && (inst_op(x) == .CLEANUPPAD || inst_op(x) == .CATCHSWITCH) return false;
    }
    return true;
}

find_best_non_trivial_unswitch_candidate :: (cands: [] Slu_Candidate, l: Loop_Id, partial_iv: *Iv_Condition_Info) -> Slu_Candidate {
    li := slu.li; dt := slu.dt;
    eph: Table(Value_Id, bool); eph.allocator = temp;
    collect_ephemeral_values(li, l, slu.ac, *eph);
    bb_cost: Table(Value_Id, Cost); bb_cost.allocator = temp;
    f := li.fn;
    kind := ifx fn_has_min_size(f) then TCK_CODE_SIZE else TCK_SIZE_AND_LATENCY;
    tti := tti_get(f);
    loop_cost: Cost = 0;
    for bb: li_blocks(li, l) {
        c: Cost = 0;
        for i: block_insts(bb) {
            if table_contains(*eph, i) continue;
            c = cost_add(c, tti_instruction_cost(tti, i, kind));
        }
        loop_cost = cost_add(loop_cost, c);
        table_set(*bb_cost, bb, c);
    }
    dt_cost: Table(s32, Cost); dt_cost.allocator = temp;

    compute_unswitched_cost :: (ti: Value_Id, full_unswitch: bool, loop_cost: Cost, bb_cost: *Table(Value_Id, Cost),
                                dt_cost: *Table(s32, Cost), partial_iv: *Iv_Condition_Info) -> Cost {
        dt := slu.dt;
        if inst_op(ti) == .SELECT return loop_cost;
        bb := inst_block(ti);
        visited: [..] Value_Id; visited.allocator = temp;
        cost: Cost = 0;
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        preds: [..] Value_Id; preds.allocator = temp;
        for s: succs {
            dup := false;
            for visited if it == s { dup = true; break; }
            if dup continue;
            array_add(*visited, s);
            if !full_unswitch {
                cond := skip_trivial_select(op(ti, 0));
                if is_logical_and(cond) { if s == get_successor(ti, 1) continue; }
                else if is_logical_or(cond) { if s == get_successor(ti, 0) continue; }
                else if (is_one_value(partial_iv.known_value) && s == get_successor(ti, 0)) ||
                        (!is_one_value(partial_iv.known_value) && s == get_successor(ti, 1)) continue;
            }
            ok := block_unique_predecessor(s) != NONE;
            if !ok {
                ok = true;
                block_predecessors(s, *preds);
                for p: preds if !(p == bb || dt_dominates(dt, s, p)) { ok = false; break; }
            }
            if ok cost = cost_add(cost, compute_dom_subtree_cost(dt_node(dt, s), bb_cost, dt_cost));
        }
        succ_count: s64 = ifx is_guard(ti) then 2 else visited.count;
        assert(succ_count > 1, "Cannot unswitch a condition without multiple distinct successors!");
        return cost_mul(slu_cost_sub(loop_cost, cost), succ_count - 1);
    }

    best_idx := -1;
    best_cost: Cost;
    for * c: cands {
        ti := c.ti;
        is_bi := inst_op(ti) == .CONDBR;
        full := !is_bi || c.has_injection || (c.invariants.count == 1 && c.invariants[0] == skip_trivial_select(op(ti, 0)));
        cc := compute_unswitched_cost(ti, full, loop_cost, *bb_cost, *dt_cost, partial_iv);
        if slu_opts.enable_cost_multiplier {
            mult := calculate_unswitch_cost_multiplier(ti, l, cands);
            cc = cost_mul(cc, mult);
        }
        if best_idx < 0 || cc < best_cost { best_idx = it_index; best_cost = cc; }
    }
    assert(best_idx >= 0, "Must be!");
    best := cands[best_idx];
    best.has_cost = true;
    best.cost = best_cost;
    return best;
}

should_insert_freeze :: (l: Loop_Id, ti: Value_Id) -> bool {
    if !slu_opts.freeze_cond return false;
    safety: Loop_Safety_Info;
    lsi_compute(*safety, slu.li, l);
    if lsi_is_guaranteed_to_execute(*safety, ti, slu.dt, l) return false;
    cond := skip_trivial_select(op(ti, 0));
    return !is_guaranteed_not_to_be_undef_or_poison(cond, slu.ac, block_terminator(li_loop_preheader(slu.li, l)), slu.dt);
}

unswitch_best_condition :: (l: Loop_Id) -> bool {
    li := slu.li;
    cands: [..] Slu_Candidate; cands.allocator = temp;
    partial_iv: Iv_Condition_Info;
    partial_iv.inst_to_duplicate.allocator = temp;
    partial_iv_cond_branch: Value_Id = NONE;
    collect_unswitch_candidates(*cands, *partial_iv, *partial_iv_cond_branch, l);
    if find_option_md_for_loop_id(li_loop_id(li, l), "llvm.loop.unswitch.injection.disable") == NONE
        collect_unswitch_candidates_with_injections(*cands, l);
    if cands.count == 0 return false;

    best := find_best_non_trivial_unswitch_candidate(cands, l, *partial_iv);
    if !cost_valid(best.cost) || best.cost >= slu_opts.threshold return false;

    injected := false;
    if best.has_injection {
        best = inject_pending_invariant_conditions(*best, l);
        injected = true;
    }
    if best.ti != partial_iv_cond_branch partial_iv.inst_to_duplicate.count = 0;

    insert_freeze: bool;
    if inst_op(best.ti) == .SELECT {
        insert_freeze = !is_guaranteed_not_to_be_undef_or_poison(op(best.ti, 0), slu.ac, block_terminator(li_loop_preheader(li, l)), slu.dt);
        best.ti = turn_select_into_branch(best.ti);
    } else {
        if is_guard(best.ti) best.ti = turn_guard_into_branch(best.ti, l);
        insert_freeze = should_insert_freeze(l, best.ti);
    }
    unswitch_nontrivial_invariants(l, best.ti, best.invariants, *partial_iv, insert_freeze, injected);
    return true;
}

unswitch_loop :: (l: Loop_Id, trivial: bool, non_trivial: bool) -> bool {
    li := slu.li;
    if !li_is_loop_simplify_form(li, l) return false;
    if trivial && unswitch_all_trivial_conditions(l) {
        post_unswitch(l, true, false, false, .[]);
        return true;
    }
    f := li.fn;
    // TTI.hasBranchDivergence is false for X86 and without a target
    if !(slu_opts.enable_nontrivial || non_trivial) return false;
    if fn_has_opt_size(f) return false;
    if !is_safe_for_non_trivial_unswitching(l) return false;
    if unswitch_best_condition(l) return true;
    return false;
}

// SimpleLoopUnswitchPass::run (+ parseLoopUnswitchOptions)
simple_loop_unswitch_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    non_trivial := false;
    trivial := true;
    name := node.name;
    if name != "simple-loop-unswitch" {
        params := slice(name, "simple-loop-unswitch<".count, name.count - "simple-loop-unswitch<".count - 1);
        while params.count {
            p := params;
            semi := find_index_from_left(params, #char ";");
            if semi >= 0 { p = slice(params, 0, semi); params = slice(params, semi + 1, params.count - semi - 1); }
            else params = "";
            enable := true;
            if begins_with(p, "no-") { enable = false; p = slice(p, 3, p.count - 3); }
            if p == "nontrivial" non_trivial = enable;
            else if p == "trivial" trivial = enable;
            else fatal("invalid LoopUnswitch pass parameter '%'", p);
        }
    }
    mssau_storage: Mssa_Updater;
    slu.li = lar.li; slu.dt = lar.dt; slu.ac = lar.ac; slu.lpm = u;
    slu.mssau = null;
    slu.trailing.allocator = temp;
    table_reset(*slu.trailing);
    if lar.mssa {
        mssau_storage.mssa = lar.mssa;
        slu.mssau = *mssau_storage;
        if mssa_opts.verify mssa_verify(lar.mssa);
    }
    se = lar.se;
    if !unswitch_loop(l, trivial, non_trivial) return PRESERVE_ALL;
    if slu.trailing.count fatal("simple-loop-unswitch: debug records were left without a terminator");
    if lar.mssa && mssa_opts.verify mssa_verify(lar.mssa);
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
