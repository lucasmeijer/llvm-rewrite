// LoopDistribute: llvm/lib/Transforms/Scalar/LoopDistribute.cpp (InstPartition = `Ld_Part`, InstPartitionContainer =
// `Ld_Parts`, LoopDistributeForLoop = `ldist_process_loop`), with findDefsUsedOutsideOfLoop (LoopUtils.cpp).

ldist_opts: struct {
    verify := false;                       // -loop-distribute-verify (verification only)
    non_if_convertible := false;           // -loop-distribute-non-if-convertible
    scev_check_threshold: s64 = 8;         // -loop-distribute-scev-check-threshold
    pragma_scev_check_threshold: s64 = 128;   // -loop-distribute-scev-check-threshold-with-pragma
    enable := false;                       // -enable-loop-distribute
};
LDIST_CL_OPT_COUNT :: 5;
add_ldist_cl_opts :: (list: [] Cl_Opt, base: s64) {
    list[base + 0] = .{"loop-distribute-verify", .BOOL, *ldist_opts.verify, null, null};
    list[base + 1] = .{"loop-distribute-non-if-convertible", .BOOL, *ldist_opts.non_if_convertible, null, null};
    list[base + 2] = .{"loop-distribute-scev-check-threshold", .INT, null, *ldist_opts.scev_check_threshold, null};
    list[base + 3] = .{"loop-distribute-scev-check-threshold-with-pragma", .INT, null, *ldist_opts.pragma_scev_check_threshold, null};
    list[base + 4] = .{"enable-loop-distribute", .BOOL, *ldist_opts.enable, null, null};
}

Ld_Part :: struct {
    set: [..] Value_Id;          // SmallSetVector<Instruction *, 8>
    dep_cycle: bool;
    cloned: Loop_Id = NONE;
    cloned_blocks: [..] Value_Id;
    vm: Value_Map;
    removed: bool;               // erased from the std::list
}
ld_part_new :: (i: Value_Id, cycle: bool) -> Ld_Part {
    p: Ld_Part;
    p.set.allocator = temp; p.cloned_blocks.allocator = temp;
    vmap_init(*p.vm);
    array_add(*p.set, i);
    p.dep_cycle = cycle;
    return p;
}
ld_set_insert :: (s: *[..] Value_Id, i: Value_Id) -> bool { for s.* if it == i return false; array_add(s, i); return true; }
ld_move_to :: (from: *Ld_Part, to: *Ld_Part) {
    for from.set ld_set_insert(*to.set, it);
    from.set.count = 0;
    to.dep_cycle |= from.dep_cycle;
}

Ld_Parts :: struct {
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    parts: [..] Ld_Part;         // the std::list (removed entries are skipped)
    inst_to_part: Table(Value_Id, s64);
}
ld_live :: (c: *Ld_Parts) -> [..] s64 {
    r: [..] s64; r.allocator = temp;
    for p, k: c.parts if !p.removed array_add(*r, k);
    return r;
}
ld_size :: (c: *Ld_Parts) -> s64 { return ld_live(c).count; }
ld_add_to_cyclic :: (c: *Ld_Parts, i: Value_Id) {
    live := ld_live(c);
    if live.count == 0 || !c.parts[live[live.count - 1]].dep_cycle array_add(*c.parts, ld_part_new(i, true));
    else ld_set_insert(*c.parts[live[live.count - 1]].set, i);
}
ld_add_to_new_non_cyclic :: (c: *Ld_Parts, i: Value_Id) { array_add(*c.parts, ld_part_new(i, false)); }

Ld_Merge_Kind :: enum u8 { NON_CYCLIC; NON_IF_CONVERTIBLE; }
ld_merge_pred :: (c: *Ld_Parts, p: *Ld_Part, kind: Ld_Merge_Kind) -> bool {
    if kind == .NON_CYCLIC return !p.dep_cycle;
    if p.dep_cycle return true;
    seen_store := false;
    for i: p.set if inst_op(i) == .STORE {
        seen_store = true;
        if !laa_block_needs_predication(inst_block(i), c.li, c.l, c.dt) return false;
    }
    return seen_store;
}
// mergeAdjacentPartitionsIf
ld_merge_adjacent_if :: (c: *Ld_Parts, kind: Ld_Merge_Kind) {
    prev := -1;
    for k: ld_live(c) {
        m := ld_merge_pred(c, *c.parts[k], kind);
        if prev < 0 && m prev = k;
        else if prev >= 0 && m { ld_move_to(*c.parts[k], *c.parts[prev]); c.parts[k].removed = true; }
        else prev = -1;
    }
}
// mergeToAvoidDuplicatedLoads
ld_merge_to_avoid_duplicated_loads :: (c: *Ld_Parts) -> bool {
    load_to_part: Table(Value_Id, s64); load_to_part.allocator = temp;
    // EquivalenceClasses<InstPartition *>: Members in insertion order, classes as leader lists
    leader: Table(s64, s64); leader.allocator = temp;
    members: [..] s64; members.allocator = temp;
    classes: Table(s64, [..] s64); classes.allocator = temp;
    ec_insert :: (leader: *Table(s64, s64), members: *[..] s64, classes: *Table(s64, [..] s64), v: s64) {
        if table_contains(leader, v) return;
        table_set(leader, v, v);
        array_add(members, v);
        l: [..] s64; l.allocator = temp; array_add(*l, v);
        table_set(classes, v, l);
    }
    live := ld_live(c);
    for li_idx: 0..live.count-1 {
        pi := live[li_idx];
        for i: c.parts[pi].set {
            if inst_op(i) != .LOAD continue;
            found, other := table_find(*load_to_part, i);
            if !found { table_set(*load_to_part, i, pi); continue; }
            j := li_idx;
            while true {
                j -= 1;
                pj := live[j];
                ec_insert(*leader, *members, *classes, pi); ec_insert(*leader, *members, *classes, pj);
                _, l1 := table_find(*leader, pi); _, l2 := table_find(*leader, pj);
                if l1 != l2 {
                    m2 := table_find_pointer(*classes, l2).*;
                    m1 := table_find_pointer(*classes, l1);
                    for m2 { array_add(m1, it); table_set(*leader, it, l1); }
                    table_remove(*classes, l2);
                }
                if pj == other break;
            }
        }
    }
    if members.count == 0 return false;
    for m: members {
        _, l := table_find(*leader, m);
        if l != m continue;
        cls := table_find_pointer(*classes, m).*;
        for k: 1..cls.count-1 ld_move_to(*c.parts[cls[k]], *c.parts[m]);
    }
    for * c.parts if !it.removed && it.set.count == 0 it.removed = true;
    return true;
}
// setupPartitionIdOnInstructions
ld_setup_partition_ids :: (c: *Ld_Parts) {
    id: s64 = 0;
    for k: ld_live(c) {
        for i: c.parts[k].set {
            found, _ := table_find(*c.inst_to_part, i);
            if found table_set(*c.inst_to_part, i, -1); else table_set(*c.inst_to_part, i, id);
        }
        id += 1;
    }
}
// InstPartition::populateUsedSet
ld_populate_used_set :: (c: *Ld_Parts, p: *Ld_Part) {
    for b: li_blocks(c.li, c.l) ld_set_insert(*p.set, block_terminator(b));
    work: [..] Value_Id; work.allocator = temp;
    for p.set array_add(*work, it);
    while work.count {
        i := pop(*work);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            if o != NONE && is_inst(o) && li_contains(c.li, c.l, inst_block(o)) && ld_set_insert(*p.set, o) array_add(*work, o);
        }
    }
}
// setNewLoopID
ld_set_new_loop_id :: (c: *Ld_Parts, orig: Md_Id, p: *Ld_Part) {
    fu := string.["llvm.loop.distribute.followup_all", ifx p.dep_cycle then "llvm.loop.distribute.followup_sequential" else "llvm.loop.distribute.followup_coincident"];
    ok, id := make_followup_loop_id(orig, fu);
    if ok li_set_loop_id(c.li, ifx p.cloned != NONE then p.cloned else c.l, id);
}
ld_distributed_loop :: (c: *Ld_Parts, p: *Ld_Part) -> Loop_Id { return ifx p.cloned != NONE then p.cloned else c.l; }
// cloneLoops
ld_clone_loops :: (c: *Ld_Parts) {
    li := c.li;
    orig_ph := li_loop_preheader(li, c.l);
    pred := block_single_predecessor(orig_ph);
    exit := li_exit_block(li, c.l);
    orig_id := li_loop_id(li, c.l);
    top_ph := orig_ph;
    live := ld_live(c);
    index := live.count - 1;
    k := live.count - 2;
    while k >= 0 {
        p := *c.parts[live[k]];
        p.cloned = clone_loop_with_preheader(top_ph, pred, c.l, *p.vm, tprint(".ldist%", index), li, c.dt, *p.cloned_blocks);
        vmap_set(*p.vm, exit, top_ph);
        remap_instructions_in_blocks(p.cloned_blocks, *p.vm);
        ld_set_new_loop_id(c, orig_id, p);
        index -= 1;
        top_ph = li_loop_preheader(li, p.cloned);
        k -= 1;
    }
    t := block_terminator(pred);
    n := nops(t);
    for j: 0..cast(s64) n - 1 if op(t, cast(u32) j) == orig_ph set_op(t, cast(u32) j, top_ph);   // replaceUsesOfWith
    ld_set_new_loop_id(c, orig_id, *c.parts[live[live.count - 1]]);
    for j: 0..live.count-2 {
        cur := *c.parts[live[j]]; nxt := *c.parts[live[j + 1]];
        dt_change_idom(c.dt, li_loop_preheader(li, ld_distributed_loop(c, nxt)), li_exiting_block(li, ld_distributed_loop(c, cur)));
    }
}
// InstPartition::removeUnusedInsts
ld_remove_unused_insts :: (c: *Ld_Parts, p: *Ld_Part) {
    unused: [..] Value_Id; unused.allocator = temp;
    has_map := p.vm.map.count > 0;
    for b: li_blocks(c.li, c.l) for i: block_insts(b) {
        in_set := false;
        for p.set if it == i { in_set = true; break; }
        if in_set continue;
        ni := i;
        if has_map ni = vmap_lookup(*p.vm, i);
        array_add(*unused, ni);
    }
    for < i: unused {
        salvage_debug_info(i);
        if has_uses(i) rauw_with_metadata(i, const_poison(vtype(i)));
        erase_inst_with_metadata(i);
    }
}
// computePartitionSetForPointers
ld_partition_set_for_pointers :: (c: *Ld_Parts, lai: *Laa) -> [..] s64 {
    r: [..] s64; r.allocator = temp;
    for p: lai.rt.pointers {
        insts: [..] Value_Id; insts.allocator = temp;
        for mdc_order_for_access(*lai.dc, p.ptr, true) array_add(*insts, lai.dc.inst_map[it]);
        for mdc_order_for_access(*lai.dc, p.ptr, false) array_add(*insts, lai.dc.inst_map[it]);
        part: s64 = -2;
        for i: insts {
            _, this := table_find(*c.inst_to_part, i);   // operator[]: 0 when missing
            if part == -2 part = this;
            else if part == -1 break;
            else if part != this part = -1;
        }
        array_add(*r, part);
    }
    return r;
}

// findDefsUsedOutsideOfLoop
find_defs_used_outside_of_loop :: (li: *Loop_Info, l: Loop_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for b: li_blocks(li, l) for i: block_insts(b) {
        u := ir.v_first_use[i];
        while u != NONE { if !li_contains(li, l, inst_block(ir.u_user[u])) { array_add(*r, i); break; } u = ir.u_next[u]; }
    }
    return r;
}

// LoopDistributeForLoop::processLoop
ldist_process_loop :: (l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, forced: bool, has_forced: bool) -> bool {
    f := li.fn;
    if li_exit_block(li, l) == NONE return false;
    if !li_is_loop_simplify_form(li, l) return false;
    if !li_is_rotated_form(li, l) return false;
    ph := li_loop_preheader(li, l);
    lai := laa_cached_info(f, l, li, dt, ac, false);
    if lai.can_vec_mem return false;
    if !lai.dc.record_dependences || lai.dc.dependences.count == 0 return false;
    c: Ld_Parts;
    c.l = l; c.li = li; c.dt = dt;
    c.parts.allocator = temp; c.inst_to_part.allocator = temp;
    // MemoryInstructionDependences
    n := lai.dc.inst_map.count;
    counts := NewArray(n, s64,, allocator = temp);
    for dep: lai.dc.dependences {
        t := dep.type;
        if dep_is_backward(t) || t == .Unknown || t == .IndirectUnsafe || t == .InvariantUnsafe {   // isPossiblyBackward
            counts[dep.source] += 1;
            counts[dep.destination] -= 1;
        }
    }
    active: s64 = 0;
    for i, k: lai.dc.inst_map {
        if active != 0 || counts[k] > 0 ld_add_to_cyclic(*c, i);
        else ld_add_to_new_non_cyclic(*c, i);
        active += counts[k];
    }
    defs := find_defs_used_outside_of_loop(li, l);
    for defs ld_add_to_new_non_cyclic(*c, it);
    if ld_size(*c) < 2 return false;
    ld_merge_adjacent_if(*c, .NON_CYCLIC);
    if !ldist_opts.non_if_convertible ld_merge_adjacent_if(*c, .NON_IF_CONVERTIBLE);
    if ld_size(*c) < 2 return false;
    for k: ld_live(*c) ld_populate_used_set(*c, *c.parts[k]);
    if ld_merge_to_avoid_duplicated_loads(*c) {
        if ld_size(*c) < 2 return false;
    }
    always_true := sc_union_is_always_true(lai.pse.preds);
    if lai.has_convergent_op && !always_true return false;
    limit := ifx has_forced && forced then ldist_opts.pragma_scev_check_threshold else ldist_opts.scev_check_threshold;
    if lai.pse.preds.count > limit return false;
    if !(has_forced && forced) && li_has_disable_all_transforms_hint(li, l) return false;
    ld_setup_partition_ids(*c);
    ptr_to_part := ld_partition_set_for_pointers(*c, lai);
    // includeOnlyCrossPartitionChecks
    checks: [..] s64; checks.allocator = temp;
    rt := *lai.rt;
    for chk, ci: rt.checks {
        need := false;
        for i1: rt.groups[chk[0]].members {
            for i2: rt.groups[chk[1]].members {
                same_part := ptr_to_part[i1] != -1 && ptr_to_part[i1] == ptr_to_part[i2];
                if rpc_needs_checking(rt, i1, i2) && !same_part { need = true; break; }
            }
            if need break;
        }
        if need array_add(*checks, ci);
    }
    if lai.has_convergent_op && checks.count != 0 return false;
    if block_single_predecessor(ph) == NONE || block_first(ph) != block_terminator(ph) split_block(ph, block_terminator(ph), dt, li, null);
    if !always_true || checks.count != 0 {
        orig_id := li_loop_id(li, l);
        if !li_is_recursively_lcssa_form(li, l, dt) form_lcssa_recursively(li, l, dt);
        lv: Lver;
        lv.versioned = l; lv.lai = lai; lv.checks = checks; lv.li = li; lv.dt = dt;
        lver_version_loop(*lv, defs);
        lver_annotate_loop_with_no_alias(*lv);
        prefix := "llvm.loop.distribute.";
        _, unversioned_id := make_followup_loop_id(orig_id, string.["llvm.loop.distribute.followup_all", "llvm.loop.distribute.followup_fallback"], *prefix, true);
        li_set_loop_id(li, lv.non_versioned, unversioned_id);
        add_string_metadata_to_loop(li, lv.non_versioned, "llvm.loop.isdistributed", 1);
    }
    ld_clone_loops(*c);
    for k: ld_live(*c) ld_remove_unused_insts(*c, *c.parts[k]);
    return true;
}

// LoopDistributePass::run
loop_distribute_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    dt := get_domtree(f);
    s := get_scev(f);
    ac := get_assumption_cache(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    worklist: [..] Loop_Id; worklist.allocator = temp;
    tops: [..] Loop_Id; tops.allocator = temp;
    for li.top_level array_add(*tops, it);
    for top: tops {
        pre: [..] Loop_Id; pre.allocator = temp;
        li_loops_in_preorder_of(li, top, *pre);
        for pre if li_subloops(li, it).count == 0 array_add(*worklist, it);
    }
    changed := false;
    for l: worklist {
        md := li_find_string_metadata_operand(li, l, "llvm.loop.distribute.enable");
        has_forced := md != NONE;
        forced := has_forced && const_int_zext(md) != 0;
        has, v := li_optional_bool_loop_attribute(li, l, "llvm.loop.isdistributed");
        if has && v continue;
        run := ifx has_forced then forced else ldist_opts.enable;
        if run {
            ok := ldist_process_loop(l, li, dt, ac, forced, has_forced);
            // Ctx.diagnose(DiagnosticInfoOptimizationFailure): a warning; the source location prefix is not printed here
            if !ok && has_forced && forced print_stderr("warning: loop not distributed: failed explicitly specified loop distribution\n");
            changed |= ok;
        }
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .LOOPS);
    preserve(*pa, .DOMTREE);
    return pa;
}
