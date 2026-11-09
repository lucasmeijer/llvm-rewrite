// SLPVectorizer: BlockScheduling (the dependency scheduler used while building the tree). Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class ScheduleEntity / ScheduleData / ScheduleBundle,
// struct BlockScheduling: clear, getScheduleData, schedule, initialFillReadyList, buildBundle, tryScheduleBundle,
// extendSchedulingRegion, initScheduleData, calculateDependencies, resetSchedule).
//
// Layout: the ScheduleEntity hierarchy is two row tables per block, `Sched_Data` (one per instruction, reused
// across regions by region id, like ScheduleDataMap) and `Sched_Bundle`; a `Sched_Ent` handle is a data index
// (>= 0) or -(bundle index + 1). ScheduleCopyableData (copyable elements that need their own schedule entity)
// is not ported: building a bundle with one fails loudly, so every copyable-data map of LLVM is empty here and
// the queries on them (getScheduleCopyableData, areAllOperandsReplacedByCopyableData) answer "none" / false.

SD_INVALID_DEPS :: -1;

Sched_Data :: struct {
    inst: Value_Id;
    next_load_store: s32 = -1;
    memory_deps: [..] s32;
    control_deps: [..] s32;
    region_id: s32;
    deps: s32 = SD_INVALID_DEPS;
    unsched_deps: s32 = SD_INVALID_DEPS;
    scheduled: bool;
    priority: s32;
}
Sched_Bundle :: struct {
    members: [..] s32;     // Sched_Data indices
    valid := true;
    te: Te_Id = TE_NONE;
    scheduled: bool;
    priority: s32;
}
Sched_Ent :: s32;
ent_of_bundle :: inline (b: s32) -> Sched_Ent { return -(b + 1); }
ent_is_bundle :: inline (e: Sched_Ent) -> bool { return e < 0; }
ent_bundle :: inline (e: Sched_Ent) -> s32 { return -e - 1; }

Block_Sched :: struct {
    bb: Value_Id;
    data: [..] Sched_Data;
    data_map: Table(Value_Id, s32);            // ScheduleDataMap
    bundles: [..] Sched_Bundle;                 // ScheduledBundlesList (+ popped rows, never referenced again)
    scheduled_bundles: Table(Value_Id, [..] s32);
    ready: [..] Sched_Ent;                      // SetVector<ScheduleEntity *> ReadyInsts
    schedule_start: Value_Id = NONE;
    schedule_end: Value_Id = NONE;
    first_load_store: s32 = -1;
    last_load_store: s32 = -1;
    region_has_stack_save: bool;
    region_size: s64;
    region_size_limit: s64;
    region_id: s32 = 1;
}

slp_block_sched :: (bb: Value_Id) -> *Block_Sched {
    for slpx.block_schedules if it.bb == bb return it;
    bs := New(Block_Sched,, temp);
    bs.bb = bb;
    bs.data.allocator = temp; bs.data_map.allocator = temp; bs.bundles.allocator = temp;
    bs.scheduled_bundles.allocator = temp; bs.ready.allocator = temp;
    bs.region_size_limit = slp_cl.schedule_budget;
    array_add(*slpx.block_schedules, bs);
    return bs;
}

// clear()
bs_clear :: (bs: *Block_Sched) {
    table_reset(*bs.scheduled_bundles);
    array_reset_keeping_memory(*bs.bundles);
    array_reset_keeping_memory(*bs.ready);
    bs.schedule_start = NONE;
    bs.schedule_end = NONE;
    bs.first_load_store = -1;
    bs.last_load_store = -1;
    bs.region_has_stack_save = false;
    bs.region_size_limit -= bs.region_size;
    if bs.region_size_limit < SLP_MIN_SCHEDULE_REGION_SIZE bs.region_size_limit = SLP_MIN_SCHEDULE_REGION_SIZE;
    bs.region_size = 0;
    bs.region_id += 1;
}

// getScheduleData(I)
bs_data :: (bs: *Block_Sched, v: Value_Id) -> s32 {
    if v == NONE || !is_inst(v) || inst_block(v) != bs.bb return -1;
    found, sd := table_find(*bs.data_map, v);
    if found && bs.data[sd].region_id == bs.region_id return sd;
    return -1;
}
bs_bundles :: (bs: *Block_Sched, v: Value_Id) -> [] s32 {
    if !is_inst(v) return .[];
    p := table_find_pointer(*bs.scheduled_bundles, v);
    if !p return .[];
    return p.*;
}
bs_bundle_in_region :: (bs: *Block_Sched, b: s32) -> bool {
    for bs.bundles[b].members if bs.data[it].region_id != bs.region_id return false;
    return true;
}

// ScheduleData / ScheduleBundle queries
sd_has_valid_deps :: inline (bs: *Block_Sched, sd: s32) -> bool { return bs.data[sd].deps != SD_INVALID_DEPS; }
sd_is_ready :: inline (bs: *Block_Sched, sd: s32) -> bool { return bs.data[sd].unsched_deps == 0 && !bs.data[sd].scheduled; }
sd_clear_direct_deps :: (bs: *Block_Sched, sd: s32) {
    d := *bs.data[sd];
    d.deps = SD_INVALID_DEPS; d.unsched_deps = SD_INVALID_DEPS; d.scheduled = false;
}
sd_clear_deps :: (bs: *Block_Sched, sd: s32) {
    sd_clear_direct_deps(bs, sd);
    array_reset_keeping_memory(*bs.data[sd].memory_deps);
    array_reset_keeping_memory(*bs.data[sd].control_deps);
}
sb_unscheduled_deps :: (bs: *Block_Sched, b: s32) -> s32 {
    sum: s32 = 0;
    for bs.bundles[b].members {
        u := bs.data[it].unsched_deps;
        if u == SD_INVALID_DEPS return SD_INVALID_DEPS;
        sum += u;
    }
    return sum;
}
sb_has_valid_deps :: (bs: *Block_Sched, b: s32) -> bool {
    for bs.bundles[b].members if !sd_has_valid_deps(bs, it) return false;
    return true;
}
sb_is_ready :: (bs: *Block_Sched, b: s32) -> bool { return sb_unscheduled_deps(bs, b) == 0 && !bs.bundles[b].scheduled; }
ent_is_ready :: (bs: *Block_Sched, e: Sched_Ent) -> bool { return ifx ent_is_bundle(e) then sb_is_ready(bs, ent_bundle(e)) else sd_is_ready(bs, e); }

ready_insert :: (bs: *Block_Sched, e: Sched_Ent) { for bs.ready if it == e return; array_add(*bs.ready, e); }
ready_remove :: (bs: *Block_Sched, e: Sched_Ent) { for bs.ready if it == e { array_ordered_remove_by_index(*bs.ready, it_index); return; } }

// DecrUnsched of schedule(): one fewer unscheduled dependency of `sd`
bs_decr_unsched :: (bs: *Block_Sched, sd: s32, is_control := false) {
    if (is_control || sd_has_valid_deps(bs, sd)) {
        bs.data[sd].unsched_deps -= 1;
        if bs.data[sd].unsched_deps != 0 return;
        bundles := bs_bundles(bs, bs.data[sd].inst);
        if bundles.count {
            for b: bundles if sb_unscheduled_deps(bs, b) == 0 ready_insert(bs, ent_of_bundle(b));
            return;
        }
        ready_insert(bs, sd);
    }
}

// schedule(...)::ProcessBundleMember(BundleMember, Bundles): `bundle_tes` are the tree entries of Bundles
bs_process_bundle_member :: (bs: *Block_Sched, s: Inst_State, sd: s32, bundle_tes: [] Te_Id) {
    in := bs.data[sd].inst;
    if bundle_tes.count {
        // OperandsUses: operand instruction -> remaining uses
        use_keys: [..] Value_Id; use_keys.allocator = temp;
        use_cnts: [..] u32; use_cnts.allocator = temp;
        total: u32 = 0;
        for k: 0..cast(s64) nops(in) - 1 {
            o := op(in, cast(u32) k);
            if !is_inst(o) continue;
            idx := -1;
            for use_keys if it == o { idx = it_index; break; }
            if idx < 0 { array_add(*use_keys, o); array_add(*use_cnts, 0); idx = use_keys.count - 1; }
            extra: u32 = 1;
            for te: bundle_tes if slp_te_is_expanded_bin_op(te, in) extra += 1;
            use_cnts[idx] += extra;
            total += extra;
        }
        Checked :: struct { sd: s32; op: u32; }
        checked: [..] Checked; checked.allocator = temp;
        decr_for_inst :: (bs: *Block_Sched, i: Value_Id, op_idx: u32, checked: *[..] Checked, use_keys: [] Value_Id, use_cnts: [] u32, total: *u32, is_expanded_operand: bool) {
            idx := -1;
            for use_keys if it == i { idx = it_index; break; }
            if idx < 0 fatal("internal: slp: operand not found while scheduling");
            if use_cnts[idx] > 0 {
                op_sd := bs_data(bs, i);
                if op_sd >= 0 {
                    if !is_expanded_operand {
                        for checked.* if it.sd == op_sd && it.op == op_idx return;
                        array_add(checked, .{op_sd, op_idx});
                    }
                    use_cnts[idx] -= 1;
                    total.* -= 1;
                    bs_decr_unsched(bs, op_sd);
                } else {
                    use_cnts[idx] -= 1;
                    total.* -= 1;
                }
            }
        }
        for te: bundle_tes {
            if total == 0 break;
            e := *slp.entries[te];
            parents_unique: [..] Value_Id; parents_unique.allocator = temp;
            non_sched_phi := slp_te_is_non_schedulable_with_parent_phi(te);
            k := 0;
            while k < e.scalars.count && e.scalars[k] != in k += 1;
            while k < e.scalars.count {
                lane := k;
                if (inst_op(in) == .STORE || inst_op(in) == .INSERTVALUE) && e.reorder_indices.count lane = cast(s64) e.reorder_indices[lane];
                skip := false;
                if non_sched_phi {
                    user := slp.entries[e.user_tree_index.user].scalars[lane];
                    for parents_unique if it == user { skip = true; break; }
                    if !skip array_add(*parents_unique, user);
                }
                if !skip {
                    for op_idx: 0..e.operands.count-1 {
                        x := e.operands[op_idx][lane];
                        if is_inst(x) decr_for_inst(bs, x, cast(u32) op_idx, *checked, use_keys, use_cnts, *total, slp_te_is_expanded_operand(te, in, cast(u32) op_idx));
                    }
                    if slp_te_is_copyable(te, in) break;
                }
                k += 1;
                while k < e.scalars.count && e.scalars[k] != in k += 1;
            }
        }
        if total > 0 && inst_op(in) == .CALL {
            id := get_vector_intrinsic_id_for_call(in);
            for a: 0..cast(s64) call_num_args(in) - 1 {
                if !vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) a) continue;
                o := call_arg(in, cast(u32) a);
                if !is_inst(o) continue;
                idx := -1;
                for use_keys if it == o { idx = it_index; break; }
                if idx < 0 || use_cnts[idx] == 0 continue;
                use_cnts[idx] -= 1;
                total -= 1;
                op_sd := bs_data(bs, o);
                if op_sd >= 0 bs_decr_unsched(bs, op_sd);
            }
        }
    } else {
        for k: 0..cast(s64) nops(in) - 1 {
            o := op(in, cast(u32) k);
            if !is_inst(o) continue;
            op_sd := bs_data(bs, o);
            if op_sd >= 0 bs_decr_unsched(bs, op_sd);
        }
    }
    visited: [..] s32; visited.allocator = temp;
    for dep: bs.data[sd].memory_deps {
        dup := false; for visited if it == dep { dup = true; break; }
        if dup continue;
        array_add(*visited, dep);
        bs_decr_unsched(bs, dep);
    }
    array_reset_keeping_memory(*visited);
    for dep: bs.data[sd].control_deps {
        dup := false; for visited if it == dep { dup = true; break; }
        if dup continue;
        array_add(*visited, dep);
        bs_decr_unsched(bs, dep, true);
    }
}

// schedule(R, S, EI, Data, ReadyList)
bs_schedule :: (bs: *Block_Sched, s: Inst_State, e: Sched_Ent) {
    if !ent_is_bundle(e) {
        sd := e;
        bs.data[sd].scheduled = true;
        in := bs.data[sd].inst;
        tes: [..] Te_Id; tes.allocator = temp;
        for te: slp_get_tree_entries(in) {
            o := inst_op(in);
            if !(o == .EXTRACTVALUE || o == .EXTRACTELEMENT || is_call_base(in)) && nops(in) != slp.entries[te].operands.count continue;
            array_add(*tes, te);
        }
        bs_process_bundle_member(bs, s, sd, tes);
        return;
    }
    b := ent_bundle(e);
    bs.bundles[b].scheduled = true;
    for sd: bs.bundles[b].members {
        sdb := bs_bundles(bs, bs.data[sd].inst);
        all := sdb.count > 0;
        for sdb if !bs.bundles[it].scheduled { all = false; break; }
        if !all continue;
        bs.data[sd].scheduled = true;
        tes: [..] Te_Id; tes.allocator = temp;
        for sdb array_add(*tes, bs.bundles[it].te);
        bs_process_bundle_member(bs, s, sd, tes);
    }
}

// initialFillReadyList(ReadyInsts)
bs_initial_fill_ready_list :: (bs: *Block_Sched) {
    visited: [..] s32; visited.allocator = temp;
    i := bs.schedule_start;
    while i != bs.schedule_end {
        defer i = inst_next(i);
        sd := bs_data(bs, i);
        if sd >= 0 && sd_has_valid_deps(bs, sd) && sd_is_ready(bs, sd) {
            bundles := bs_bundles(bs, i);
            if bundles.count {
                for b: bundles {
                    dup := false; for visited if it == b { dup = true; break; }
                    if dup continue;
                    array_add(*visited, b);
                    if sb_has_valid_deps(bs, b) && sb_is_ready(bs, b) ready_insert(bs, ent_of_bundle(b));
                }
                continue;
            }
            ready_insert(bs, sd);
        }
    }
}

// buildBundle(VL, S, EI)
bs_build_bundle :: (bs: *Block_Sched, vl: [] Value_Id, s: Inst_State) -> s32 {
    nb: Sched_Bundle;
    nb.members.allocator = temp;
    array_add(*bs.bundles, nb);
    b := cast(s32) (bs.bundles.count - 1);
    for v: vl {
        if is_non_schedulable(s, v) continue;
        if is_copyable_element(s, v) slp_fail("scheduling copyable elements (ScheduleCopyableData)");
        sd := bs_data(bs, v);
        if sd < 0 fatal("internal: slp: no ScheduleData for bundle member");
        array_add(*bs.bundles[b].members, sd);
        p := table_find_pointer(*bs.scheduled_bundles, v);
        if !p { l: [..] s32; l.allocator = temp; table_set(*bs.scheduled_bundles, v, l); p = table_find_pointer(*bs.scheduled_bundles, v); }
        array_add(p, b);
    }
    return b;
}

// allocateScheduleDataChunks + ScheduleDataMap[I]
bs_new_data :: (bs: *Block_Sched, i: Value_Id) -> s32 {
    d: Sched_Data;
    d.memory_deps.allocator = temp; d.control_deps.allocator = temp;
    array_add(*bs.data, d);
    sd := cast(s32) (bs.data.count - 1);
    table_set(*bs.data_map, i, sd);
    return sd;
}

// initScheduleData(FromI, ToI, PrevLoadStore, NextLoadStore)
bs_init_schedule_data :: (bs: *Block_Sched, from: Value_Id, to: Value_Id, prev_ls: s32, next_ls: s32) {
    cur_ls := prev_ls;
    i := from;
    inv_load := md_kind_id("invariant.load");
    while i != to {
        defer i = inst_next(i);
        if inst_op(i) == .PHI continue;
        found, sd := table_find(*bs.data_map, i);
        if !found sd = bs_new_data(bs, i);
        d := *bs.data[sd];
        d.next_load_store = -1;
        d.scheduled = false;
        d.region_id = bs.region_id;
        sd_clear_deps(bs, sd);
        d.inst = i;
        can_ignore_load := inst_op(i) == .LOAD && is_simple_load_store(i) && get_metadata(i, inv_load) != NONE;
        id := call_iid(i);
        if may_read_or_write_memory(i) && !can_ignore_load && (id == NOT_INTRINSIC || (id != IID_SIDEEFFECT && id != IID_PSEUDOPROBE)) {
            if cur_ls >= 0 bs.data[cur_ls].next_load_store = sd;
            else bs.first_load_store = sd;
            cur_ls = sd;
        }
        if id == IID_STACKSAVE || id == IID_STACKRESTORE bs.region_has_stack_save = true;
    }
    if next_ls >= 0 {
        if cur_ls >= 0 bs.data[cur_ls].next_load_store = next_ls;
    } else {
        bs.last_load_store = cur_ls;
    }
}

// extendSchedulingRegion(V, S)
bs_extend_scheduling_region :: (bs: *Block_Sched, v: Value_Id, s: Inst_State) -> bool {
    i := v;
    if bs_data(bs, i) >= 0 return true;
    if bs.schedule_start == NONE {
        bs_init_schedule_data(bs, i, inst_next(i), -1, -1);
        bs.schedule_start = i;
        bs.schedule_end = inst_next(i);
        return true;
    }
    is_assume_like :: (x: Value_Id) -> bool { return call_iid(x) != NOT_INTRINSIC && is_assume_like_intrinsic(x); }
    up := inst_prev(bs.schedule_start);
    down := bs.schedule_end;
    while up != NONE && is_assume_like(up) up = inst_prev(up);
    while down != NONE && is_assume_like(down) down = inst_next(down);
    while up != NONE && down != NONE && up != i && down != i {
        bs.region_size += 1;
        if bs.region_size > bs.region_size_limit return false;
        up = inst_prev(up);
        down = inst_next(down);
        while up != NONE && is_assume_like(up) up = inst_prev(up);
        while down != NONE && is_assume_like(down) down = inst_next(down);
    }
    if down == NONE || (up != NONE && up == i) {
        bs_init_schedule_data(bs, i, bs.schedule_start, -1, bs.first_load_store);
        bs.schedule_start = i;
        return true;
    }
    bs_init_schedule_data(bs, bs.schedule_end, inst_next(i), bs.last_load_store, -1);
    bs.schedule_end = inst_next(i);
    return true;
}

// isSimple(I) for the source of a memory dependency; getLocation(I)
slp_get_location :: (i: Value_Id) -> (bool, Mem_Loc) {
    if inst_op(i) == .STORE || inst_op(i) == .LOAD return true, mloc_get(i);
    return false, .{};
}
// BoUpSLP::isAliased(Loc1, Inst1, Inst2) with the AliasCache
slp_is_aliased :: (loc: Mem_Loc, i1: Value_Id, i2: Value_Id) -> bool {
    key := (cast(u64) i1 << 32) | cast(u64) i2;
    found, r := table_find(*slpx.alias_cache, key);
    if found return r;
    aliased := aa_mod_ref_inst_loc(slpx.batch_aa, i2, loc) != 0;
    table_set(*slpx.alias_cache, key, aliased);
    return aliased;
}

// calculateDependencies(Bundle, InsertInReadyList, SLP, ExpandedOps, ControlDeps); bundle -1 = invalid bundle
bs_calculate_dependencies :: (bs: *Block_Sched, bundle: s32, insert_in_ready_list: bool, expanded_ops: [] Value_Id, control_deps: [] s32) {
    worklist: [..] s32; worklist.allocator = temp;   // ScheduleData indices
    process_node :: (bs: *Block_Sched, sd: s32, insert_in_ready_list: bool, expanded_ops: [] Value_Id, worklist: *[..] s32) {
        if sd_has_valid_deps(bs, sd) return;
        bs.data[sd].deps = 0;
        bs.data[sd].unsched_deps = 0;
        in := bs.data[sd].inst;
        add_dep :: (bs: *Block_Sched, sd: s32, dest: s32, n: s32, insert_in_ready_list: bool, worklist: *[..] s32) {
            bs.data[sd].deps += n;
            if !bs.data[dest].scheduled bs.data[sd].unsched_deps += n;
            if !sd_has_valid_deps(bs, dest) || (insert_in_ready_list && sd_is_ready(bs, dest)) array_add(worklist, dest);
        }
        // users
        u := ir.v_first_use[in];
        while u != NONE {
            usr := ir.u_user[u]; u = ir.u_next[u];
            if is_inst(usr) && inst_op(usr) == .PHI continue;
            use_sd := bs_data(bs, usr);
            if use_sd < 0 continue;
            // areAllOperandsReplacedByCopyableData: no copyable data
            extra: s32 = 1;
            for te: slp_get_tree_entries(usr) if slp_te_is_expanded_bin_op(te, usr) extra += 1;
            for expanded_ops if it == usr { extra += 1; break; }
            add_dep(bs, sd, use_sd, extra, insert_in_ready_list, worklist);
        }
        visited: [..] Value_Id; visited.allocator = temp;
        make_control_dependent :: (bs: *Block_Sched, sd: s32, i: Value_Id, visited: *[..] Value_Id, insert_in_ready_list: bool, worklist: *[..] s32) {
            for visited.* if it == i return;
            array_add(visited, i);
            dest := bs_data(bs, i);
            if dest < 0 fatal("internal: slp: control dependency outside the schedule window");
            array_add(*bs.data[dest].control_deps, sd);
            add_dep(bs, sd, dest, 1, insert_in_ready_list, worklist);
        }
        if !is_guaranteed_to_transfer_execution(in) {
            first := block_first(bs.bb);
            i := inst_next(in);
            while i != bs.schedule_end {
                defer i = inst_next(i);
                if is_safe_to_speculatively_execute_cx(i, first, slp.ac) continue;
                make_control_dependent(bs, sd, i, *visited, insert_in_ready_list, worklist);
                if !is_guaranteed_to_transfer_execution(i) break;
            }
        }
        if bs.region_has_stack_save {
            is_ss :: (x: Value_Id) -> bool { id := call_iid(x); return id == IID_STACKSAVE || id == IID_STACKRESTORE; }
            if is_ss(in) {
                i := inst_next(in);
                while i != bs.schedule_end {
                    defer i = inst_next(i);
                    if is_ss(i) break;
                    if inst_op(i) != .ALLOCA continue;
                    make_control_dependent(bs, sd, i, *visited, insert_in_ready_list, worklist);
                }
            }
            if inst_op(in) == .ALLOCA || may_read_or_write_memory(in) {
                i := inst_next(in);
                while i != bs.schedule_end {
                    defer i = inst_next(i);
                    if !is_ss(i) continue;
                    make_control_dependent(bs, sd, i, *visited, insert_in_ready_list, worklist);
                    break;
                }
            }
        }
        next_ls := bs.data[sd].next_load_store;
        if next_ls < 0 return;
        has_loc, src_loc := slp_get_location(in);
        src_may_write := may_write_to_memory(in);
        num_aliased: u32 = 0;
        dist: u32 = 1;
        non_simple_src := !has_loc || !slp_is_simple(in);
        dest := next_ls;
        while dest >= 0 {
            defer dest = bs.data[dest].next_load_store;
            di := bs.data[dest].inst;
            if dist >= SLP_MAX_MEM_DEP_DISTANCE ||
               ((src_may_write || may_write_to_memory(di)) &&
                (non_simple_src || num_aliased >= SLP_ALIASED_CHECK_LIMIT || slp_is_aliased(src_loc, in, di))) {
                num_aliased += 1;
                array_add(*bs.data[dest].memory_deps, sd);
                add_dep(bs, sd, dest, 1, insert_in_ready_list, worklist);
            }
            if dist >= 2 * SLP_MAX_MEM_DEP_DISTANCE break;
            dist += 1;
        }
    }
    if bundle >= 0 array_add(*worklist, bs.bundles[bundle].members[0]);
    for control_deps array_add(*worklist, it);
    visited: [..] s32; visited.allocator = temp;
    while worklist.count {
        sd := pop(*worklist);
        bundles := bs_bundles(bs, bs.data[sd].inst);
        if bundles.count == 0 {
            if !sd_has_valid_deps(bs, sd) process_node(bs, sd, insert_in_ready_list, expanded_ops, *worklist);
            if insert_in_ready_list && sd_is_ready(bs, sd) ready_insert(bs, sd);
            continue;
        }
        for b: bundles {
            if sb_has_valid_deps(bs, b) continue;
            dup := false; for visited if it == b { dup = true; break; }
            if dup continue;
            array_add(*visited, b);
            for m: bs.bundles[b].members process_node(bs, m, insert_in_ready_list, expanded_ops, *worklist);
        }
        if insert_in_ready_list && sd_is_ready(bs, sd) {
            for b: bundles if sb_is_ready(bs, b) ready_insert(bs, ent_of_bundle(b));
        }
    }
}

// resetSchedule()
bs_reset_schedule :: (bs: *Block_Sched) {
    for * d: bs.data {
        if d.region_id == bs.region_id && inst_block(d.inst) == bs.bb {
            d.scheduled = false;
            d.unsched_deps = d.deps;
        }
    }
    for b: 0..bs.bundles.count-1 if bs_bundle_in_region(bs, cast(s32) b) bs.bundles[b].scheduled = false;
    array_reset_keeping_memory(*bs.ready);
}

// tryScheduleBundle(VL, SLP, S, EI): (has_value, bundle or -1 = nullptr)
bs_try_schedule_bundle :: (bs: *Block_Sched, vl: [] Value_Id, s: Inst_State, ei: Edge_Info) -> (bool, s32) {
    if inst_op(s.main) == .PHI || slp_is_vector_like_inst_with_const_ops(s.main) return true, -1;
    has_copyables := s.has_copyables;
    all_non_sched := true;
    for vl if !is_non_schedulable(s, it) { all_non_sched = false; break; }
    does_not_require := (!has_copyables && slp_does_not_need_to_schedule(vl)) || all_non_sched;
    if has_copyables slp_fail("bundles of instructions with copyable elements in tryScheduleBundle");
    if ei.user != TE_NONE {
        ue := *slp.entries[ei.user];
        if ue.state == TE_VECTORIZE && inst_op(ue.s.main) == .PHI {
            for v: vl {
                if !is_inst(v) || (has_copyables && is_copyable_element(s, v)) continue;
                for * te: slp.entries {
                    if te.user_tree_index.user != TE_NONE && slp.entries[te.user_tree_index.user].state == TE_VECTORIZE &&
                       inst_op(slp.entries[te.user_tree_index.user].s.main) == .PHI && slp_te_is_copyable(cast(Te_Id) it_index, v)
                        return false, -1;
                }
            }
        }
    }
    if does_not_require {
        for v: vl {
            if !is_inst(v) || (has_copyables && is_copyable_element(s, v)) continue;
            if is_expanded_bin_op(s, v) {
                for k: 0..cast(s64) nops(v) - 1 {
                    if inst_op(v) == .SHL && k == 1 continue;   // isExpandedOperand
                    o := op(v, cast(u32) k);
                    if !is_inst(o) continue;
                    if !has_one_use(o) return false, -1;
                    sd := bs_data(bs, o);
                    if sd >= 0 && sd_has_valid_deps(bs, sd) return false, -1;
                }
            }
            // areAllOperandsReplacedByCopyableData is false without copyable data
        }
        return true, -1;
    }
    old_end := bs.schedule_end;
    try_impl :: (bs: *Block_Sched, vl: [] Value_Id, s: Inst_State, re_schedule_in: bool, bundle: s32, old_end: Value_Id) {
        re_schedule := re_schedule_in;
        control_dependent: [..] s32; control_dependent.allocator = temp;
        if old_end != NONE && bs.schedule_end != old_end {
            for * d, k: bs.data if d.region_id == bs.region_id && inst_block(d.inst) == bs.bb sd_clear_deps(bs, cast(s32) k);
            re_schedule = true;
        }
        expanded: [..] Value_Id; expanded.allocator = temp;
        for v: vl if is_expanded_bin_op(s, v) array_add(*expanded, v);
        if bundle >= 0 && bs.bundles[bundle].members.count {
            if expanded.count bs_check_if_need_to_clear_deps(bs, s, bundle, *control_dependent);
            bs_calculate_dependencies(bs, bundle, !re_schedule, expanded, control_dependent);
        } else if control_dependent.count {
            bs_calculate_dependencies(bs, -1, !re_schedule, expanded, control_dependent);
        }
        if re_schedule {
            bs_reset_schedule(bs);
            bs_initial_fill_ready_list(bs);
        }
        while ((bundle < 0 && re_schedule) || (bundle >= 0 && !sb_is_ready(bs, bundle))) && bs.ready.count {
            picked := pop(*bs.ready);
            bs_schedule(bs, s, picked);
            if bundle >= 0 && picked == ent_of_bundle(bundle) break;
        }
    }
    for v: vl {
        if is_non_schedulable(s, v) continue;
        if !bs_extend_scheduling_region(bs, v, s) {
            try_impl(bs, vl, s, false, -1, old_end);
            return false, -1;
        }
    }
    re_schedule := false;
    for v: vl {
        if is_non_schedulable(s, v) continue;
        member := bs_data(bs, v);
        if member < 0 continue;
        ready_remove(bs, member);
        for b: bs_bundles(bs, v) ready_remove(bs, ent_of_bundle(b));
        if !is_copyable_element(s, v) && !is_expanded_bin_op(s, v) && !bs.data[member].scheduled continue;
        re_schedule = true;
    }
    bundle := bs_build_bundle(bs, vl, s);
    try_impl(bs, vl, s, re_schedule, bundle, old_end);
    if !sb_is_ready(bs, bundle) {
        for m: bs.bundles[bundle].members {
            if sd_is_ready(bs, m) {
                bundles := bs_bundles(bs, bs.data[m].inst);
                if bundles.count == 0 { ready_insert(bs, m); continue; }
                for b: bundles if sb_is_ready(bs, b) ready_insert(bs, ent_of_bundle(b));
            }
        }
        // ScheduledBundlesList.pop_back(): the row stays, nothing references it any more
        control_dependent: [..] s32; control_dependent.allocator = temp;
        for v: vl {
            if is_non_schedulable(s, v) continue;
            if is_expanded_bin_op(s, v) {
                for k: 0..cast(s64) nops(v) - 1 {
                    op_sd := bs_data(bs, op(v, cast(u32) k));
                    if op_sd >= 0 && sd_has_valid_deps(bs, op_sd) { sd_clear_direct_deps(bs, op_sd); array_add(*control_dependent, op_sd); }
                }
            }
            p := table_find_pointer(*bs.scheduled_bundles, v);
            p.count -= 1;
        }
        if control_dependent.count bs_calculate_dependencies(bs, -1, false, .[], control_dependent);
        return false, -1;
    }
    return true, bundle;
}

// TryScheduleBundleImpl::CheckIfNeedToClearDeps without copyable data (only the expanded-binop operands)
bs_check_if_need_to_clear_deps :: (bs: *Block_Sched, s: Inst_State, bundle: s32, control_dependent: *[..] s32) {
    for sd: bs.bundles[bundle].members {
        in := bs.data[sd].inst;
        if !is_expanded_bin_op(s, in) continue;
        for k: 0..cast(s64) nops(in) - 1 {
            op_sd := bs_data(bs, op(in, cast(u32) k));
            if op_sd >= 0 && sd_has_valid_deps(bs, op_sd) {
                sd_clear_direct_deps(bs, op_sd);
                array_add(control_dependent, op_sd);
            }
        }
    }
}
