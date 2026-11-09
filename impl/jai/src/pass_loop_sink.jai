// LoopSink: port of llvm/lib/Transforms/Scalar/LoopSink.cpp (adjustedSumFreq, findBBsToSinkInto, sinkInstruction,
// sinkLoopInvariantInstructions, LoopSinkPass::run). LICM's canSinkOrHoistInst (with SinkAndHoistLICMFlags(IsSink,
// L, MSSA)) is licm_can_sink_or_hoist_inst on a Licm state built for the loop.

ls_cl: struct {
    sink_freq_percent_threshold: s64 = 90;   // -sink-freq-percent-threshold
    max_uses_for_sinking: s64 = 30;          // -max-uses-for-sinking
};

// BlockFrequency += (saturating)
ls_freq_add :: (a: u64, b: u64) -> u64 { s := a + b; if s < a return 0xFFFF_FFFF_FFFF_FFFF; return s; }

ls_adjusted_sum_freq :: (bbs: [] Value_Id, bfi: *Bfi) -> u64 {
    t: u64 = 0;
    for bbs t = ls_freq_add(t, bfi_get_block_freq(bfi, it));
    if bbs.count > 1 {
        // T /= BranchProbability(SinkFrequencyPercentThreshold, 100): Prob.scaleByInverse(T)
        n := cast(u32) ((cast(u64) ls_cl.sink_freq_percent_threshold * BP_D + 50) / 100);
        t = bp_scale_nd(t, cast(u32) BP_D, n);
    }
    return t;
}

ls_set_contains :: (s: [] Value_Id, b: Value_Id) -> bool { for s if it == b return true; return false; }

ls_find_bbs_to_sink_into :: (li: *Loop_Info, l: Loop_Id, use_bbs: [] Value_Id, cold: [] Value_Id, dt: *Dom_Tree, bfi: *Bfi) -> [..] Value_Id {
    to: [..] Value_Id; to.allocator = temp;
    if use_bbs.count == 0 return to;
    for use_bbs array_add(*to, it);
    dominated: [..] Value_Id; dominated.allocator = temp;
    for coldest: cold {
        dominated.count = 0;
        for to if dt_dominates(dt, coldest, it) array_add(*dominated, it);
        if dominated.count == 0 continue;
        if ls_adjusted_sum_freq(dominated, bfi) > bfi_get_block_freq(bfi, coldest) {
            k := 0;
            while k < to.count { if ls_set_contains(dominated, to[k]) array_ordered_remove_by_index(*to, k); else k += 1; }
            if !ls_set_contains(to, coldest) array_add(*to, coldest);
            continue;
        }
        if ls_adjusted_sum_freq(to, bfi) <= bfi_get_block_freq(bfi, coldest) break;
    }
    for to if block_first_insertion_pt(it) == NONE { to.count = 0; break; }
    if ls_adjusted_sum_freq(to, bfi) > bfi_get_block_freq(bfi, li_loop_preheader(li, l)) to.count = 0;
    return to;
}

ls_sink_instruction :: (li: *Loop_Info, l: Loop_Id, i: Value_Id, cold: [] Value_Id, number: *Table(Value_Id, s64), dt: *Dom_Tree, bfi: *Bfi, mssau: *Mssa_Updater) -> bool {
    bbs: [..] Value_Id; bbs.allocator = temp;   // SmallPtrSet: only membership and count matter
    u := ir.v_first_use[i];
    while u != NONE {
        defer u = ir.u_next[u];
        ui := ir.u_user[u];
        if !li_contains_loop(li, l, li_loop_for(li, inst_block(ui))) return false;
        if inst_op(ui) != .PHI {
            if !ls_set_contains(bbs, inst_block(ui)) array_add(*bbs, inst_block(ui));
            continue;
        }
        phi_bb := ir.u_aux[u];
        if li_loop_preheader(li, l) == phi_bb return false;
        if !ls_set_contains(bbs, phi_bb) array_add(*bbs, phi_bb);
    }
    if bbs.count > ls_cl.max_uses_for_sinking return false;
    to := ls_find_bbs_to_sink_into(li, l, bbs, cold, dt, bfi);
    if to.count == 0 return false;
    if to.count > 1 for to if !table_contains(number, it) return false;
    sorted: [..] Value_Id; sorted.allocator = temp;
    for to array_add(*sorted, it);
    if sorted.count > 1 {
        for a: 1..sorted.count - 1 {
            x := sorted[a];
            _, nx := table_find(number, x);
            b := a - 1;
            while b >= 0 { _, nb := table_find(number, sorted[b]); if nb <= nx break; sorted[b + 1] = sorted[b]; b -= 1; }
            sorted[b + 1] = x;
        }
    }
    move_bb := sorted[0];
    m := mssau.mssa;
    for k: 1..sorted.count - 1 {
        n := sorted[k];
        ic := ic_clone_inst(i);
        insert_at_position(ic, n, block_first_insertion_pt(n), true);
        if vname(i).count set_name(ic, vname(i));
        if mssa_access_of(m, i) >= 0 {
            na := mssau_create_memory_access_in_bb(mssau, ic, -1, n, .BEGINNING);
            if na >= 0 {
                if ma_is_def(m, na) mssau_insert_def(mssau, na, true);
                else mssau_insert_use(mssau, na, true);
            }
        }
        // I.replaceUsesWithIf(IC, in N and not a phi)
        uu := ir.v_first_use[i];
        while uu != NONE {
            nu := ir.u_next[uu];
            usr := ir.u_user[uu];
            if inst_block(usr) == n && inst_op(usr) != .PHI set_op(usr, cast(u32) (uu - ir.v_ops[usr]), ic);
            uu = nu;
        }
        // replaceDominatedUsesWith(&I, IC, DT, N)
        uu = ir.v_first_use[i];
        while uu != NONE {
            nu := ir.u_next[uu];
            usr := ir.u_user[uu];
            if !(is_inst(usr) && call_iid(usr) == IID_FAKE_USE) {
                dom: bool;
                if inst_op(usr) == .PHI dom = dt_dominates(dt, n, ir.u_aux[uu]);
                else dom = dt_properly_dominates(dt, n, inst_block(usr));
                if dom set_op(usr, cast(u32) (uu - ir.v_ops[usr]), ic);
            }
            uu = nu;
        }
    }
    iv_move_before_head(i, block_first_insertion_pt(move_bb), move_bb);   // moveBefore(getFirstInsertionPt())
    old := mssa_access_of(m, i);
    if old >= 0 mssau_move_to_place(mssau, old, move_bb, .BEGINNING);
    return true;
}

ls_sink_loop_invariant_instructions :: (f: Value_Id, l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, bfi: *Bfi, mssa: *Memory_SSA, aar: Aa_Results) -> bool {
    preheader := li_loop_preheader(li, l);
    pf := bfi_get_block_freq(bfi, preheader);
    all_hotter := true;
    for li_blocks(li, l) if bfi_get_block_freq(bfi, it) <= pf { all_hotter = false; break; }
    if all_hotter return false;
    mssau: Mssa_Updater;
    mssau.mssa = mssa;
    c: Licm;
    c.f = f; c.l = l; c.li = li; c.dt = dt; c.mssa = mssa; c.mssau = *mssau; c.aar = aar;
    c.ac = get_assumption_cache(f);
    c.tti = tti_get(f);
    // SinkAndHoistLICMFlags(/*IsSink=*/true, L, MSSA)
    c.opt_cap = cast(u32) licm_opts.mssa_opt_cap;
    c.no_acc_cap = cast(u32) licm_opts.mssa_no_acc_for_promotion_cap;
    c.is_sink = true;
    {
        count: u32 = 0;
        for b: li_blocks(li, l) {
            a := mssa_first_access(mssa, b);
            while a >= 0 {
                count += 1;
                if count > c.no_acc_cap { c.too_many_mem_acc = true; break; }
                a = mssa.acc[a].next;
            }
            if c.too_many_mem_acc break;
        }
    }
    changed := false;
    cold: [..] Value_Id; cold.allocator = temp;
    number: Table(Value_Id, s64); number.allocator = temp;
    k: s64 = 0;
    for b: li_blocks(li, l) {
        if bfi_get_block_freq(bfi, b) < bfi_get_block_freq(bfi, preheader) {
            array_add(*cold, b);
            k += 1;
            table_set(*number, b, k);
        }
    }
    // stable_sort by frequency
    for a: 1..cold.count - 1 {
        x := cold[a]; fx := bfi_get_block_freq(bfi, x);
        b := a - 1;
        while b >= 0 && bfi_get_block_freq(bfi, cold[b]) > fx { cold[b + 1] = cold[b]; b -= 1; }
        cold[b + 1] = x;
    }
    i := block_last(preheader);
    while i != NONE {
        prev := inst_prev(i);
        defer i = prev;
        if inst_op(i) == .PHI continue;
        if !licm_can_sink_or_hoist_inst(*c, i, false) continue;
        if ls_sink_instruction(li, l, i, cold, *number, dt, bfi, *mssau) changed = true;
    }
    return changed;
}

loop_sink_run :: (f: Value_Id) -> Preserved {
    has_profile, _ := function_entry_count(f);   // Function::hasProfileData
    if !has_profile return PRESERVE_ALL;
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    aar := aa_results_for(f);
    dt := get_domtree(f);
    bfi := get_bfi(f);
    mssa := get_memoryssa(f);
    pre: [..] Loop_Id; pre.allocator = temp;
    li_loops_in_preorder(li, *pre);
    changed := false;
    while pre.count {
        l := pop(*pre);
        if li_loop_preheader(li, l) == NONE continue;
        if ls_sink_loop_invariant_instructions(f, l, li, dt, bfi, mssa, aar) changed = true;
    }
    if !changed return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .MEMORYSSA);
    if mssa_opts.verify mssa_verify(mssa);
    return pa;
}
