// UnrollLoop and the post-unroll cleanup.
// Port of llvm/lib/Transforms/Utils/LoopUnroll.cpp: needToInsertPhisForLCSSA, addClonedBlockToLoopInfo,
// isEpilogProfitable, loadCSE (getMatchingValue, StackNode over a ScopedHashTable), simplifyLoopAfterUnroll,
// fixProbContradiction, UnrollLoop, GetUnrollMetadata (pass_loop_unroll.jai). The parallel-reduction part
// (canParallelizeReductionWhenUnrolling, -unroll-add-parallel-reductions / AddAdditionalAccumulators, which no target
// we support enables) fails loudly. Uses LoopBlocksDFS = loop_blocks_rpo (pass_licm.jai).
//
// Reusable API:
//   unroll_loop(li, l, ulo, dt, ac, tti, preserve_lcssa, *remainder_loop, aa) -> Loop_Unroll_Result   UnrollLoop
//   simplify_loop_after_unroll(li, l, simplify_ivs, dt, ac, tti, blocks, aa)                         simplifyLoopAfterUnroll
//   add_cloned_block_to_loop_info(li, orig_bb, cloned_bb, *new_loops) -> Loop_Id                      addClonedBlockToLoopInfo
// The ScalarEvolution is the global `se`; scev_pass_se must be the same SE (LoopSimplify / LCSSA update it).

// UnrollLoopOptions
Unroll_Loop_Options :: struct {
    count: u32;
    force: bool;
    runtime: bool;
    allow_expensive_trip_count: bool;
    unroll_remainder: bool;
    forget_all_scev: bool;
    heart: Value_Id = NONE;
    scev_expansion_budget: u32;
    runtime_unroll_multi_exit: bool;
    add_additional_accumulators: bool;
}

// NewLoopsMap = SmallDenseMap<const Loop *, Loop *, 4>
New_Loops_Map :: struct { from: [..] Loop_Id; to: [..] Loop_Id; }
nlm_init :: (m: *New_Loops_Map) { m.from.allocator = temp; m.to.allocator = temp; }
nlm_lookup :: (m: *New_Loops_Map, l: Loop_Id) -> Loop_Id {
    for m.from if it == l return m.to[it_index];
    return NONE;
}
nlm_set :: (m: *New_Loops_Map, l: Loop_Id, v: Loop_Id) {
    for m.from if it == l { m.to[it_index] = v; return; }
    array_add(*m.from, l); array_add(*m.to, v);
}

// isInstructionTriviallyDead(I, TLI = nullptr)
is_trivially_dead_no_tli :: (i: Value_Id) -> bool { return !has_uses(i) && would_instruction_be_trivially_dead(i, false); }

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI = nullptr)
recursively_delete_trivially_dead_no_tli :: (v: Value_Id) -> bool {
    if !is_inst(v) || !is_trivially_dead_no_tli(v) return false;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    delete_dead_worklist_no_tli(*dead);
    return true;
}
// RecursivelyDeleteTriviallyDeadInstructions(SmallVectorImpl<WeakTrackingVH> &DeadInsts, TLI = nullptr): entries
// deleted meanwhile are null (DEAD rows)
delete_dead_worklist_no_tli :: (dead: *[..] Value_Id) {
    while dead.count {
        i := pop(dead);
        if i == NONE || vkind(i) != .INST continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_trivially_dead_no_tli(o) array_add(dead, o);
        }
        erase_inst_with_metadata(i);
    }
}

// needToInsertPhisForLCSSA(L, Blocks, LI)
need_to_insert_phis_for_lcssa :: (li: *Loop_Info, l: Loop_Id, blocks: [] Value_Id) -> bool {
    for bb: blocks {
        if li_loop_for(li, bb) == l continue;
        for i: block_insts(bb) {
            n := nops(i);
            for k: 0..cast(s64) n - 1 {
                d := op(i, cast(u32) k);
                if !is_inst(d) continue;
                dl := li_loop_for(li, inst_block(d));
                if dl == NONE continue;
                if li_contains_loop(li, dl, l) return true;
            }
        }
    }
    return false;
}

// addClonedBlockToLoopInfo(OriginalBB, ClonedBB, LI, NewLoops): the original loop when a new loop was created
add_cloned_block_to_loop_info :: (li: *Loop_Info, orig_bb: Value_Id, cloned_bb: Value_Id, new_loops: *New_Loops_Map) -> Loop_Id {
    old_loop := li_loop_for(li, orig_bb);
    nl := nlm_lookup(new_loops, old_loop);
    if nl == NONE {
        nl = li_alloc_loop(li);
        nlm_set(new_loops, old_loop, nl);
        np := nlm_lookup(new_loops, li_parent(li, old_loop));
        if np != NONE li_add_child_loop(li, np, nl);
        else li_add_top_level_loop(li, nl);
        li_add_basic_block_to_loop(li, nl, cloned_bb);
        return old_loop;
    }
    li_add_basic_block_to_loop(li, nl, cloned_bb);
    return NONE;
}

// isEpilogProfitable
is_epilog_profitable :: (li: *Loop_Info, l: Loop_Id) -> bool {
    ph := li_loop_preheader(li, l);
    for pn: block_insts(li_header(li, l)) {
        if !is_phi(pn) break;
        if vkind(phi_incoming_value_for_block(pn, ph)) == .C_INT return true;
    }
    return false;
}

// PHINode::setIncomingValueForBlock (every entry for the block)
phi_set_incoming_value_for_block :: (p: Value_Id, b: Value_Id, v: Value_Id) {
    n := phi_num_incoming(p);
    for k: 0..cast(s64) n - 1 if phi_block(p, cast(u32) k) == b phi_set_value(p, cast(u32) k, v);
}

// the dominator-tree children of b, copied
dt_child_blocks :: (dt: *Dom_Tree, b: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    n := dt_node(dt, b);
    if n < 0 return;
    c := dt.nodes[n].first_child;
    while c >= 0 { array_add(out, dt.nodes[c].block); c = dt.nodes[c].sibling; }
}

// ---------------------------------------------------------------- loadCSE

// loadCSE(L, DT, SE, LI, BAA, GetMSSA): a ScopedHashTable from pointer SCEVs to (load, generation), one scope per
// dominator-tree node on the stack
load_cse :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) {
    Load_Value :: struct { def: Value_Id = NONE; generation: u32; }
    Scope :: struct { keys: [..] Scev_Id; vals: [..] Load_Value; }
    Stack_Node :: struct {
        scope: s64;
        current_generation: u32;
        child_generation: u32;
        node: s32;
        child: s32;      // next child to visit (-1 = end)
        processed: bool;
    }
    scopes: [..] Scope; scopes.allocator = temp;
    lookup :: (scopes: [] Scope, k: Scev_Id) -> Load_Value {
        for < s: scopes for < s.keys if it == k return s.vals[it_index];
        lv: Load_Value;
        return lv;
    }
    nodes: [..] Stack_Node; nodes.allocator = temp;
    push_scope :: (scopes: *[..] Scope) -> s64 {
        s: Scope; s.keys.allocator = temp; s.vals.allocator = temp;
        array_add(scopes, s);
        return scopes.count - 1;
    }
    mssa: *Memory_SSA = null;
    aar: Aa_Results;
    baa: *Aa_Query;
    defer if mssa mssa_free(mssa);
    header_d := dt_node(dt, li_header(li, l));
    array_add(*nodes, .{push_scope(*scopes), 0, 0, header_d, dt.nodes[header_d].first_child, false});
    current_generation: u32 = 0;
    while nodes.count {
        np := *nodes[nodes.count - 1];
        current_generation = np.current_generation;
        if !np.processed {
            bb := dt.nodes[np.node].block;
            if block_single_predecessor(bb) == NONE current_generation += 1;
            for :early_inc i: block_insts(bb) {
                if inst_op(i) != .LOAD || !is_simple_load_store(i) {
                    if may_write_to_memory(i) current_generation += 1;
                    continue;
                }
                ptr_scev := sc_get_scev(op(i, 0));
                lv := lookup(scopes, ptr_scev);
                m: Value_Id = NONE;
                // getMatchingValue
                if lv.def != NONE && vtype(lv.def) == vtype(i) {
                    m = lv.def;
                    if lv.generation != current_generation {
                        // GetMSSA(): MemorySSA(*L, AA, DT), built on first use; BAA is one BatchAAResults
                        if !mssa {
                            mssa = mssa_build_loop(li, l, dt, aa_results_for(li.fn));
                            aar = mssa.aar;
                            baa = aa_query_new(*aar);
                        }
                        earlier_ma := mssa_access_of(mssa, lv.def);
                        later_def := mssa_get_clobbering_access_inst(mssa, i, baa);
                        if !mssa_dominates(mssa, later_def, earlier_ma) m = NONE;
                    }
                }
                if m != NONE {
                    if li_replacement_preserves_lcssa_form(li, i, m) {
                        rauw_with_metadata(i, m);
                        erase_inst_with_metadata(i);
                    }
                } else {
                    sc := *scopes[nodes[nodes.count - 1].scope];
                    array_add(*sc.keys, ptr_scev);
                    array_add(*sc.vals, .{i, current_generation});
                }
            }
            np = *nodes[nodes.count - 1];
            np.child_generation = current_generation;
            np.processed = true;
        } else if np.child >= 0 {
            child := np.child;
            np.child = dt.nodes[child].sibling;
            if !li_contains(li, l, dt.nodes[child].block) continue;
            cg := np.child_generation;
            array_add(*nodes, .{push_scope(*scopes), cg, cg, child, dt.nodes[child].first_child, false});
        } else {
            pop(*nodes);
            pop(*scopes);
        }
    }
}

// MemorySSA::MemorySSA(Loop &L, AA, DT) + buildMemorySSA(BAA, L.blocks())
mssa_build_loop :: (li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree, aar: Aa_Results) -> *Memory_SSA {
    m := New(Memory_SSA);
    m.f = li.fn; m.dt = dt; m.aar = aar;
    q := aa_query_new(*m.aar);
    blocks := li_blocks(li, l);
    new_access(m, .DEF, NONE, blocks[0]);   // liveOnEntry (id 0), in the starting block
    def_blocks: [..] Value_Id; def_blocks.allocator = temp;
    def_set: Table(Value_Id, bool); def_set.allocator = temp;
    for b: blocks {
        insert_into_def := false;
        for i: block_insts(b) {
            a := mssa_create_new_access(m, i, q);
            if a < 0 continue;
            list_push_back(m, b, a);
            if m.acc[a].kind == .DEF { insert_into_def = true; defs_push_back(m, b, a); }
        }
        if insert_into_def && !table_contains(*def_set, b) { table_set(*def_set, b, true); array_add(*def_blocks, b); }
    }
    idf: [..] Value_Id; idf.allocator = temp;
    idf_calculate(dt, def_blocks, *def_set, null, *idf);
    for idf mssa_create_phi(m, it);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    ph := li_loop_preheader(li, l);
    p := mssa_access_of(m, ph);
    if p >= 0 {
        uses: [..] s32; uses.allocator = temp;
        ma_uses(m, p, *uses);
        for uses mu_set(m, it, MSSA_LIVE_ON_ENTRY);
        mssa_remove_from_lists(m, p);
    }
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(li, l, *exits);
    for exits table_set(*visited, it, true);
    mssa_rename_pass(m, dt_node(dt, ph), MSSA_LIVE_ON_ENTRY, *visited);
    for b: blocks if !table_contains(*visited, b) mssa_mark_unreachable_as_live_on_entry(m, b);
    return m;
}

// ---------------------------------------------------------------- simplifyLoopAfterUnroll

simplify_loop_after_unroll :: (li: *Loop_Info, l: Loop_Id, simplify_ivs: bool, dt: *Dom_Tree, ac: *Assumption_Cache, t: *Tti,
                               blocks: [] Value_Id, aa: bool) {
    if simplify_ivs {
        dead: [..] Vh; dead.allocator = temp;
        simplify_loop_ivs(l, li, dt, t, *dead);
        while dead.count {
            v := vh_get(pop(*dead));
            if is_inst(v) recursively_delete_trivially_dead_no_tli(v);
        }
        if aa load_cse(li, l, dt);
    }
    has_sp := get_metadata(li.fn, 0) != NONE;
    dead: [..] Value_Id; dead.allocator = temp;
    for bb: blocks {
        if has_sp remove_redundant_dbg_instrs(bb);
        for :early_inc i: block_insts(bb) {
            q: Simplify_Query; q.dt = dt; q.ac = ac; q.have_tli = false;
            v := simplify_instruction(i, q);
            if v != NONE && li_replacement_preserves_lcssa_form(li, i, v) rauw_with_metadata(i, v);
            if is_trivially_dead_no_tli(i) array_add(*dead, i);
            // Fold ((add X, C1), C2) to (add X, C1+C2)
            if inst_op(i) == .ADD {
                inner := op(i, 0);
                c2 := op(i, 1);
                if is_inst(inner) && inst_op(inner) == .ADD && is_const_int_or_splat(c2) && is_const_int_or_splat(op(inner, 1)) {
                    x := op(inner, 0);
                    a1 := const_int_or_splat_ap(op(inner, 1));
                    a2 := const_int_or_splat_ap(c2);
                    nc, overflow := ap_sadd_ov(a1, a2);
                    inner_nuw := has_nuw(inner);
                    inner_nsw := has_nsw(inner);
                    set_op(i, 0, x);
                    set_op(i, 1, const_int_of_type_ap(vtype(i), nc));
                    set_nuw(i, has_nuw(i) && inner_nuw);
                    set_nsw(i, has_nsw(i) && inner_nsw && !overflow);
                    if is_trivially_dead_no_tli(inner) array_add(*dead, inner);
                }
            }
        }
        delete_dead_worklist_no_tli(*dead);
    }
}
// m_APInt: a ConstantInt or a splat of one (poison lanes not allowed)
is_const_int_or_splat :: (v: Value_Id) -> bool {
    if vkind(v) == .C_INT return true;
    if is_vector_type(vtype(v)) && is_constant_kind(vkind(v)) {
        s := get_splat_value(v);
        return s != NONE && vkind(s) == .C_INT;
    }
    return false;
}
const_int_or_splat_ap :: (v: Value_Id) -> APInt {
    if vkind(v) == .C_INT return const_ap(v);
    return const_ap(get_splat_value(v));
}
// ConstantInt::get(Ty, APInt) (a splat for vector types)
const_int_of_type_ap :: (t: Type_Id, a: APInt) -> Value_Id {
    return cf_int(t, a);
}

// ---------------------------------------------------------------- fixProbContradiction

fix_prob_contradiction :: (li: *Loop_Info, l: Loop_Id, ulo: Unroll_Loop_Options, original_loop_prob: Bprob, completely_unroll: bool,
                           iter_counts: [] u32, cond_latches: [] Value_Id, cond_latch_nexts: [] Value_Id) {
    if ulo.runtime return;
    if cond_latches.count == 0 return;
    if original_loop_prob == bprob_one() return;
    freq_desired: float64 = 1.0 / (1.0 - bprob_to_double(original_loop_prob));
    get_prob :: (i: s64, cl: [] Value_Id, cn: [] Value_Id) -> float64 {
        b := block_terminator(cl[i]);
        first_is_next := get_successor(b, 0) == cn[i];
        return bprob_to_double(cond_br_probability(b, first_is_next));
    }
    set_prob :: (i: s64, p: float64, cl: [] Value_Id, cn: [] Value_Id) {
        b := block_terminator(cl[i]);
        first_is_next := get_successor(b, 0) == cn[i];
        set_cond_br_probability(b, bprob_from_double(p), first_is_next);
    }
    FREQ_PREC :: 0.000001;
    if cond_latches.count == 1 {
        a: float64 = cast(float64) iter_counts[1] + ifx completely_unroll then cast(float64) 0 else freq_desired;
        b := cast(float64) iter_counts[0] - freq_desired;
        prob := -b / a;
        prob = max(prob, cast(float64) 0); prob = min(prob, cast(float64) 1);
        set_prob(0, prob, cond_latches, cond_latch_nexts);
    } else if cond_latches.count == 2 {
        a: float64 = cast(float64) iter_counts[2] + ifx completely_unroll then cast(float64) 0 else freq_desired;
        b := cast(float64) iter_counts[1];
        c := cast(float64) iter_counts[0] - freq_desired;
        prob := (-b + cfc_sqrt(b * b - 4 * a * c)) / (2 * a);
        prob = max(prob, cast(float64) 0); prob = min(prob, cast(float64) 1);
        for k: 0..1 set_prob(k, prob, cond_latches, cond_latch_nexts);
    } else {
        prob_before: float64 = -1; prob_after: float64 = -1; freq_before: float64 = -1; freq_after: float64 = -1;
        for ci: 0..cond_latches.count - 1 {
            // AdjustProb(ComputeIdx = ci)
            compute_after :: (ci: s64, prob_after: *float64, freq_after: *float64, ic: [] u32, cl: [] Value_Id, cn: [] Value_Id) {
                prob_after.* = 1;
                freq_after.* = cast(float64) ic[ci + 1];
                for k: ci + 1..cl.count - 1 {
                    p := get_prob(k, cl, cn);
                    prob_after.* *= p;
                    if p == 0 break;
                    freq_after.* += cast(float64) ic[k + 1] * prob_after.*;
                }
            }
            if ci == 0 {
                prob_before = 1;
                freq_before = cast(float64) iter_counts[0];
                compute_after(ci, *prob_after, *freq_after, iter_counts, cond_latches, cond_latch_nexts);
            } else {
                prob_old := get_prob(ci, cond_latches, cond_latch_nexts);
                if prob_old > 0 {
                    freq_after -= cast(float64) iter_counts[ci] * prob_before;
                    prob_after /= prob_old;
                    freq_after /= prob_old;
                } else {
                    compute_after(ci, *prob_after, *freq_after, iter_counts, cond_latches, cond_latch_nexts);
                }
                prob_before *= get_prob(ci - 1, cond_latches, cond_latch_nexts);
                freq_before += cast(float64) iter_counts[ci] * prob_before;
            }
            prob_reaching_backedge: float64 = ifx completely_unroll then cast(float64) 0 else prob_before * prob_after;
            num := freq_desired - freq_before;
            den := freq_after + freq_desired * prob_reaching_backedge;
            prob_compute: float64 = -1;
            if num <= 0 prob_compute = 0;
            else if den == 0 prob_compute = 1;
            else {
                prob_compute = num / den;
                prob_compute = max(prob_compute, cast(float64) 0); prob_compute = min(prob_compute, cast(float64) 1);
            }
            set_prob(ci, prob_compute, cond_latches, cond_latch_nexts);
            freq_compute: float64 = -1;
            if prob_reaching_backedge * prob_compute == 1 freq_compute = 0h7FF00000_00000000;
            else freq_compute = (freq_before + freq_after * prob_compute) / (1 - prob_reaching_backedge * prob_compute);
            diff := freq_compute - freq_desired;
            if diff < 0 diff = -diff;
            if diff < FREQ_PREC break;
        }
    }
}

// ---------------------------------------------------------------- UnrollLoop

Exit_Info :: struct {
    trip_count: u32;
    trip_multiple: u32;
    breakout_trip: u32;
    exit_on_true: bool;
    first_exiting_block: Value_Id = NONE;
    exiting_blocks: [..] Value_Id;
}

unroll_loop :: (li: *Loop_Info, l_in: Loop_Id, ulo_in: Unroll_Loop_Options, dt_in: *Dom_Tree, ac: *Assumption_Cache, t: *Tti,
                preserve_lcssa: bool, remainder_loop: *Loop_Id, aa: bool) -> Loop_Unroll_Result {
    l := l_in;
    ulo := ulo_in;
    dt := dt_in;
    f := li.fn;
    if li_loop_preheader(li, l) == NONE return .UNMODIFIED;
    if li_loop_latch(li, l) == NONE return .UNMODIFIED;
    if !li_is_safe_to_clone(li, l) return .UNMODIFIED;
    if block_has_address_taken(li_header(li, l)) return .UNMODIFIED;

    preheader := li_loop_preheader(li, l);
    header := li_header(li, l);
    latch_block := li_loop_latch(li, l);
    exit_blocks: [..] Value_Id; exit_blocks.allocator = temp;
    li_exit_blocks(li, l, *exit_blocks);
    original_loop_blocks: [..] Value_Id; original_loop_blocks.allocator = temp;
    for li_blocks(li, l) array_add(*original_loop_blocks, it);

    max_trip_count := sc_get_small_constant_max_trip_count(l);
    max_or_zero := sc_is_backedge_taken_count_max_or_zero(l);
    has_otc, original_trip_count := li_loop_estimated_trip_count(li, l);
    original_loop_prob := li_loop_probability(li, l);

    if max_trip_count && ulo.count > max_trip_count ulo.count = max_trip_count;

    // MapVector<BasicBlock *, ExitInfo>
    exit_keys: [..] Value_Id; exit_keys.allocator = temp;
    exit_infos: [..] Exit_Info; exit_infos.allocator = temp;
    exiting_blocks: [..] Value_Id; exiting_blocks.allocator = temp;
    li_exiting_blocks(li, l, *exiting_blocks);
    for eb: exiting_blocks {
        bi := block_terminator(eb);
        if inst_op(bi) != .CONDBR continue;
        idx := -1;
        for exit_keys if it == eb { idx = it_index; break; }
        if idx < 0 {
            e: Exit_Info; e.exiting_blocks.allocator = temp;
            array_add(*exit_keys, eb); array_add(*exit_infos, e);
            idx = exit_infos.count - 1;
        }
        info := *exit_infos[idx];
        info.trip_count = sc_small_constant_trip_count_exiting(l, eb);
        info.trip_multiple = sc_small_constant_trip_multiple_exiting(l, eb);
        if info.trip_count != 0 {
            info.breakout_trip = info.trip_count % ulo.count;
            info.trip_multiple = 0;
        } else {
            g := gcd_u32(ulo.count, info.trip_multiple);
            info.breakout_trip = g; info.trip_multiple = g;
        }
        info.exit_on_true = !li_contains(li, l, get_successor(bi, 0));
        array_add(*info.exiting_blocks, eb);
    }

    completely_unroll := ulo.count == max_trip_count;
    preserve_only_first := completely_unroll && max_or_zero;
    if completely_unroll ulo.runtime = false;

    need_to_fix_lcssa := false;
    if preserve_lcssa && completely_unroll {
        for exit_blocks if is_phi(block_first(it)) { need_to_fix_lcssa = true; break; }
    }

    latch_term := block_terminator(latch_block);
    latch_is_exiting := li_is_loop_exiting(li, l, latch_block);
    if inst_op(latch_term) != .BR && !(inst_op(latch_term) == .CONDBR && latch_is_exiting) return .UNMODIFIED;

    epilog_profitability := ifx lu_cl.unroll_runtime_epilog.given then lu_cl.unroll_runtime_epilog.v != 0 else is_epilog_profitable(li, l);

    if ulo.runtime {
        ok := unroll_runtime_loop_remainder(li, l, ulo.count, ulo.allow_expensive_trip_count, epilog_profitability, ulo.unroll_remainder,
                                            ulo.forget_all_scev, dt, ac, t, preserve_lcssa, ulo.scev_expansion_budget,
                                            ulo.runtime_unroll_multi_exit, remainder_loop, has_otc, original_trip_count, original_loop_prob);
        if !ok {
            if ulo.force ulo.runtime = false;
            else return .UNMODIFIED;
        }
    }

    if ulo.forget_all_scev sc_forget_all_loops();
    else {
        sc_forget_topmost_loop(l);
        sc_forget_block_and_loop_dispositions();
    }

    orig_phi_node: [..] Value_Id; orig_phi_node.allocator = temp;
    for i: block_insts(header) { if !is_phi(i) break; array_add(*orig_phi_node, i); }

    // Reductions: CanAddAdditionalAccumulators
    want_acc := ifx lu_cl.unroll_add_parallel_reductions.given then lu_cl.unroll_add_parallel_reductions.v != 0 else ulo.add_additional_accumulators;
    if want_acc && !completely_unroll && li_num_blocks(li, l) == 1 {
        hdr_info := -1;
        for exit_keys if it == header hdr_info = it_index;
        if ulo.runtime || (hdr_info >= 0 && exit_infos[hdr_info].trip_count != 0 && exit_infos[hdr_info].breakout_trip == 0)
            if ulo.count <= 4 fatal("loop-unroll: parallel reduction phis (-unroll-add-parallel-reductions) are not implemented yet");
    }

    headers: [..] Value_Id; headers.allocator = temp;
    latches: [..] Value_Id; latches.allocator = temp;
    array_add(*headers, header);
    array_add(*latches, latch_block);

    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(li, l, *rpo);

    unrolled_loop_blocks: [..] Value_Id; unrolled_loop_blocks.allocator = temp;
    for li_blocks(li, l) array_add(*unrolled_loop_blocks, it);

    loops_to_simplify: [..] Loop_Id; loops_to_simplify.allocator = temp;   // SmallSetVector
    add_loop_to_simplify :: (v: *[..] Loop_Id, x: Loop_Id) { for v.* if it == x return; array_add(v, x); }
    for li_subloops(li, l) add_loop_to_simplify(*loops_to_simplify, it);

    if get_metadata(f, 0) != NONE && module_debug_info_for_profiling()
        fatal("loop-unroll: discriminators for debug-info-for-profiling (cloneByMultiplyingDuplicationFactor) are not implemented yet");

    no_alias_scopes: [..] Md_Id; no_alias_scopes.allocator = temp;
    identify_no_alias_scopes_to_clone(li_blocks(li, l), *no_alias_scopes);

    last_value_map: Value_Map; vmap_init(*last_value_map);
    block_insert_pt := block(latch_block).next;   // std::next(LatchBlock->getIterator()) (NONE = end())
    for it_num: 1..cast(s64) ulo.count - 1 {
        new_blocks: [..] Value_Id; new_blocks.allocator = temp;
        new_loops: New_Loops_Map; nlm_init(*new_loops);
        nlm_set(*new_loops, l, l);
        for bb: rpo {
            vm: Value_Map; vmap_init(*vm);
            nb := clone_basic_block(bb, *vm, tprint(".%", it_num), map_atoms = true);
            fn_insert_detached_block_before(f, block_insert_pt, nb);
            old_loop := add_cloned_block_to_loop_info(li, bb, nb, *new_loops);
            if old_loop != NONE add_loop_to_simplify(*loops_to_simplify, nlm_lookup(*new_loops, old_loop));
            if bb == header {
                for orig_phi: orig_phi_node {
                    new_phi := vmap_get(*vm, orig_phi);
                    in_val := phi_incoming_value_for_block(new_phi, latch_block);
                    if is_inst(in_val) && it_num > 1 && li_contains_inst(li, l, in_val) in_val = vmap_get(*last_value_map, in_val);
                    vmap_set(*vm, orig_phi, in_val);
                    erase_inst_with_metadata(new_phi);
                }
                if ulo.heart != NONE {
                    hc := vmap_get(*vm, ulo.heart);
                    erase_inst_with_metadata(hc);
                    vmap_erase(*vm, ulo.heart);
                }
            }
            // remap the source atoms now (remapInstructionsInBlocks runs later with LastValueMap, whose AtomMap is
            // empty, so all clones would otherwise share the atom group)
            if vm.atoms.count for i: block_insts(nb) atom_remap_source(vm.atoms, i);
            vmap_set(*last_value_map, bb, nb);
            for v, k: vm.map vmap_set(*last_value_map, k, v);
            // add phi entries for newly created values to all exit blocks
            term := block_terminator(bb);
            ns := num_successors(term);
            for s: 0..cast(s64) ns - 1 {
                succ := get_successor(term, cast(u32) s);
                if li_contains(li, l, succ) continue;
                for pn: block_insts(succ) {
                    if !is_phi(pn) break;
                    incoming := phi_incoming_value_for_block(pn, bb);
                    found, mv := vmap_find(*last_value_map, incoming);
                    if found incoming = mv;
                    phi_add_incoming(pn, incoming, nb);
                    sc_forget_lcssa_phi_with_new_predecessor(l, pn);
                }
            }
            if bb == header array_add(*headers, nb);
            if bb == latch_block array_add(*latches, nb);
            for exit_keys if it == bb { array_add(*exit_infos[it_index].exiting_blocks, nb); break; }
            array_add(*new_blocks, nb);
            array_add(*unrolled_loop_blocks, nb);
            if bb == header dt_add_new_block(dt, nb, latches[it_num - 1]);
            else {
                orig_idom := dt_idom_block(dt, bb);
                dt_add_new_block(dt, nb, vmap_get(*last_value_map, orig_idom));
            }
        }
        remap_instructions_in_blocks(new_blocks, *last_value_map);
        for nb: new_blocks for i: block_insts(nb) if call_iid(i) == IID_ASSUME ac_register_assumption(ac, i);
        clone_and_adapt_no_alias_scopes(no_alias_scopes, new_blocks, tprint("It%", it_num));
    }

    for pn: orig_phi_node {
        if completely_unroll {
            sc_forget_value(pn);
            rauw_with_metadata(pn, phi_incoming_value_for_block(pn, preheader));
            erase_inst_with_metadata(pn);
        } else if ulo.count > 1 {
            in_val := phi_remove_incoming_block(pn, latch_block, false);
            if is_inst(in_val) && li_contains_inst(li, l, in_val) in_val = vmap_get(*last_value_map, in_val);
            phi_add_incoming(pn, in_val, latches[latches.count - 1]);
        }
    }

    for i: 0..latches.count - 1 {
        j := (i + 1) % latches.count;
        replace_successor_with(block_terminator(latches[i]), headers[i], headers[j]);
    }
    e := latches.count - ifx completely_unroll then 0 else 1;
    for i: 0..e - 1 set_metadata(block_terminator(latches[i]), MD_LOOP_KIND, NONE);

    if ulo.count > 1 {
        children: [..] Value_Id; children.allocator = temp;
        to_update: [..] Value_Id; to_update.allocator = temp;
        for bb: original_loop_blocks {
            dt_child_blocks(dt, bb, *children);
            to_update.count = 0;
            for children if !li_contains(li, l, it) array_add(*to_update, it);
            new_idom := dt_find_nca(dt, bb, latch_block);
            for to_update dt_change_idom(dt, it, new_idom);
        }
    }

    dt_updates: [..] Dom_Update; dt_updates.allocator = temp;
    set_dest :: (src: Value_Id, will_exit: bool, exit_on_true: bool, upd: *[..] Dom_Update) {
        term := block_terminator(src);
        idx := cast(u32) ifx exit_on_true != will_exit then 1 else 0;
        dest := get_successor(term, idx);
        dead_succ := get_successor(term, 1 - idx);
        block_remove_predecessor(dead_succ, src, true);
        bi := create_br(dest);
        insert_at_position(bi, src, term, false);
        copy_debug_loc(bi, term);
        drop_all_references(term);
        erase_inst_with_metadata(term);
        array_add(upd, .{false, src, dead_succ});
    }
    // WillExit: 0 = false, 1 = true, 2 = nullopt
    will_exit :: (info: *Exit_Info, i: s64, j: s64, is_latch: bool, completely_unroll: bool, preserve_only_first: bool, runtime: bool) -> u8 {
        if completely_unroll {
            if preserve_only_first {
                if i == 0 return 2;
                return ifx j == 0 then cast(u8) 1 else 0;
            }
            if j == 0 return 1;
            if info.trip_count && cast(u32) j != info.trip_count return 0;
            return 2;
        }
        if runtime {
            if is_latch && j != 0 return 0;
            return 2;
        }
        if cast(u32) j != info.breakout_trip && (info.trip_multiple == 0 || cast(u32) j % info.trip_multiple != 0) return 0;
        return 2;
    }
    prob_update_required := false;
    for * info: exit_infos {
        key := exit_keys[it_index];
        n := info.exiting_blocks.count;
        for i: 0..n - 1 {
            j := (i + 1) % n;
            is_latch := key == latch_block;
            kwe := will_exit(info, i, j, is_latch, completely_unroll, preserve_only_first, ulo.runtime);
            if kwe == 2 {
                if info.first_exiting_block == NONE info.first_exiting_block = info.exiting_blocks[i];
                continue;
            }
            if kwe == 1 && !is_latch {
                if info.first_exiting_block == NONE info.first_exiting_block = info.exiting_blocks[i];
                continue;
            }
            if !bprob_is_unknown(original_loop_prob) && is_latch {
                actual := ifx kwe == 1 then bprob_zero() else bprob_one();
                prob_update_required |= original_loop_prob != actual;
            }
            set_dest(info.exiting_blocks[i], kwe == 1, info.exit_on_true, *dt_updates);
        }
    }

    lazy: Lazy_Dtu; lazy.dt = dt; lazy.pending.allocator = temp; lazy.deleted.allocator = temp;
    use_lazy := true;
    if exiting_blocks.count == 1 && exit_infos.count == 1 {
        use_lazy = false;
        info := *exit_infos[0];
        original_exit := exit_keys[0];
        if info.first_exiting_block == NONE info.first_exiting_block = info.exiting_blocks[info.exiting_blocks.count - 1];
        children: [..] Value_Id; children.allocator = temp;
        dt_child_blocks(dt, original_exit, *children);
        for c: children {
            if li_contains(li, l, c) continue;
            dt_set_idom(dt, dt_node(dt, c), dt_node(dt, info.first_exiting_block));
        }
    } else {
        for dt_updates if it.from != it.to array_add(*lazy.pending, it);
    }

    if !latch_is_exiting && completely_unroll change_to_unreachable(block_terminator(latches[latches.count - 1]), preserve_lcssa, null);

    iter_counts: [..] u32; iter_counts.allocator = temp;
    array_add(*iter_counts, 0);
    cond_latches: [..] Value_Id; cond_latches.allocator = temp;
    cond_latch_nexts: [..] Value_Id; cond_latch_nexts.allocator = temp;
    for li_idx: 0..latches.count - 1 {
        latch := latches[li_idx];
        iter_counts[iter_counts.count - 1] += 1;
        term := block_terminator(latch);
        if inst_op(term) == .BR {
            dest := get_successor(term, 0);
            fold := block_unique_predecessor(dest);
            merged: bool;
            if use_lazy merged = merge_block_into_predecessor(dest, dt, li, null, false, *lazy);
            else merged = merge_block_into_predecessor(dest, null, li, null, false, null, dt);
            if merged {
                for * latches if it.* == dest it.* = fold;
                for unrolled_loop_blocks if it == dest { array_ordered_remove_by_index(*unrolled_loop_blocks, it_index); break; }
            }
        } else if inst_op(term) == .CONDBR {
            array_add(*iter_counts, 0);
            array_add(*cond_latches, latch);
            array_add(*cond_latch_nexts, headers[(li_idx + 1) % latches.count]);
        }
    }

    if prob_update_required fix_prob_contradiction(li, l, ulo, original_loop_prob, completely_unroll, iter_counts, cond_latches, cond_latch_nexts);

    if use_lazy lazy_dtu_flush(*lazy);

    outer_l := li_parent(li, l);
    blocks: [..] Value_Id; blocks.allocator = temp;
    if completely_unroll {
        for li_blocks(li, l) array_add(*blocks, it);
        li_erase(li, l);
        simplify_loop_after_unroll(li, NONE, false, dt, ac, t, blocks, aa);
        l = NONE;
    } else {
        for li_blocks(li, l) array_add(*blocks, it);
        simplify_loop_after_unroll(li, l, ulo.count > 1, dt, ac, t, blocks, aa);
    }

    if !completely_unroll {
        if !bprob_is_unknown(original_loop_prob) && ulo.runtime && epilog_profitability
            li_set_loop_probability(li, l, bprob_pow(original_loop_prob, ulo.count));
        if has_otc {
            new_tc := original_trip_count / ulo.count;
            if !ulo.runtime && original_trip_count % ulo.count != 0 new_tc += 1;
            li_set_loop_estimated_trip_count(li, l, new_tc);
        }
    }

    if preserve_lcssa && outer_l != NONE && completely_unroll && !need_to_fix_lcssa
        need_to_fix_lcssa |= need_to_insert_phis_for_lcssa(li, outer_l, unrolled_loop_blocks);

    if outer_l != NONE {
        if need_to_fix_lcssa {
            latch_loop := li_loop_for(li, latches[latches.count - 1]);
            fix_l := outer_l;
            if !(latch_loop != NONE && li_contains_loop(li, fix_l, latch_loop))
                while li_parent(li, fix_l) != latch_loop fix_l = li_parent(li, fix_l);
            form_lcssa_recursively(li, fix_l, dt);
        }
        simplify_loop(li, outer_l, dt, ac, null, preserve_lcssa);
    } else {
        for loops_to_simplify simplify_loop(li, it, dt, ac, null, preserve_lcssa);
    }
    return ifx completely_unroll then Loop_Unroll_Result.FULLY_UNROLLED else .PARTIALLY_UNROLLED;
}

// Function::shouldEmitDebugInfoForProfiling, approximated by "a compile unit asks for it"
module_debug_info_for_profiling :: () -> bool {
    for m: ir.mds {
        if m.kind == .SPECIAL && m.sub == cast(u8) DI_Kind.COMPILE_UNIT && ir.md_ints[m.ints + 9] != 0 return true;
    }
    return false;
}
