// AAKernelInfo of llvm/lib/Transforms/IPO/OpenMPOpt.cpp: KernelInfoState (with BooleanStateWithSetVector), the
// KernelInfo:: kernel environment accessors, AAKernelInfoFunction (initialize with its simplification and virtual
// use callbacks, updateImpl, manifest: changeToSPMDMode with insertInstructionGuardsHelper /
// forceSingleThreadPerWorkgroupHelper, buildCustomStateMachine) and AAKernelInfoCallSite.

// ---------------------------------------------------------------- BooleanStateWithSetVector

Bsv :: struct {
    s: Bstate;                 // BooleanState
    set: [..] Value_Id;        // SetVector
    insert_invalidates: bool;
}
bsv_init :: (b: *Bsv, insert_invalidates: bool) {
    b.s = bs_new(1);
    b.set.allocator = atr_allocator();
    b.insert_invalidates = insert_invalidates;
}
bsv_contains :: (b: *Bsv, v: Value_Id) -> bool { return omp_contains(b.set, v); }
bsv_insert :: (b: *Bsv, v: Value_Id) -> bool {
    if b.insert_invalidates bs_pessimistic(*b.s);
    if bsv_contains(b, v) return false;
    array_add(*b.set, v);
    return true;
}
bsv_is_valid :: inline (b: *Bsv) -> bool { return bs_is_valid(b.s); }
bsv_is_fix :: inline (b: *Bsv) -> bool { return bs_is_fix(b.s); }
bsv_is_assumed :: inline (b: *Bsv) -> bool { return bs_is_assumed(b.s, 1); }
bsv_eq :: (a: *Bsv, b: *Bsv) -> bool {
    if a.s.known != b.s.known || a.s.assumed != b.s.assumed return false;
    if a.set.count != b.set.count return false;
    for a.set if it != b.set[it_index] return false;
    return true;
}
// operator^=: BooleanState::operator^= and Set.insert_range(RHS.Set)
bsv_merge :: (a: *Bsv, b: *Bsv) {
    bs_clamp(*a.s, b.s);
    for b.set if !bsv_contains(a, it) array_add(*a.set, it);
}
bsv_copy :: (dst: *Bsv, src: *Bsv) {
    dst.s = src.s;
    dst.insert_invalidates = src.insert_invalidates;
    fresh: [..] Value_Id;
    dst.set = fresh;
    dst.set.allocator = atr_allocator();
    for src.set array_add(*dst.set, it);
}

// ---------------------------------------------------------------- KernelInfoState

Kis_Ext :: struct {
    is_at_fixpoint: bool;
    known_prs: Bsv;            // ReachedKnownParallelRegions (InsertInvalidates = false)
    unknown_prs: Bsv;          // ReachedUnknownParallelRegions
    spmd: Bsv;                 // SPMDCompatibilityTracker (InsertInvalidates = false)
    kernel_init_cb: Value_Id = NONE;
    kernel_env_c: Value_Id = NONE;
    kernel_deinit_cb: Value_Id = NONE;
    is_kernel_entry: bool;
    reaching_kernel_entries: Bsv;   // (InsertInvalidates = false)
    parallel_levels: Bsv;      // BooleanStateWithSetVector<uint8_t> (never inserted into)
    nested_parallelism: bool;
    // AAKernelInfoFunction
    guarded: [..] Value_Id;    // GuardedInstructions (SmallPtrSet: membership only)
}
kis_ext :: inline (i: u32) -> *Kis_Ext { return cast(*Kis_Ext) aa(i).x; }
kis_init :: (k: *Kis_Ext) {
    bsv_init(*k.known_prs, false);
    bsv_init(*k.unknown_prs, true);
    bsv_init(*k.spmd, false);
    bsv_init(*k.reaching_kernel_entries, false);
    bsv_init(*k.parallel_levels, true);
    k.guarded.allocator = atr_allocator();
}
kis_pessimistic :: (k: *Kis_Ext) {
    k.is_at_fixpoint = true;
    bs_pessimistic(*k.parallel_levels.s);
    bs_pessimistic(*k.reaching_kernel_entries.s);
    bs_pessimistic(*k.spmd.s);
    bs_pessimistic(*k.known_prs.s);
    bs_pessimistic(*k.unknown_prs.s);
    k.nested_parallelism = true;
}
kis_optimistic :: (k: *Kis_Ext) {
    k.is_at_fixpoint = true;
    bs_optimistic(*k.parallel_levels.s);
    bs_optimistic(*k.reaching_kernel_entries.s);
    bs_optimistic(*k.spmd.s);
    bs_optimistic(*k.known_prs.s);
    bs_optimistic(*k.unknown_prs.s);
}
kis_may_contain_parallel_region :: (k: *Kis_Ext) -> bool { return k.known_prs.set.count != 0 || k.unknown_prs.set.count != 0; }
// operator==
kis_eq :: (a: *Kis_Ext, b: *Kis_Ext) -> bool {
    return bsv_eq(*a.spmd, *b.spmd) && bsv_eq(*a.known_prs, *b.known_prs) && bsv_eq(*a.unknown_prs, *b.unknown_prs) &&
           bsv_eq(*a.reaching_kernel_entries, *b.reaching_kernel_entries) && bsv_eq(*a.parallel_levels, *b.parallel_levels) &&
           a.nested_parallelism == b.nested_parallelism;
}
// operator^=
kis_merge :: (a: *Kis_Ext, b: *Kis_Ext) {
    if b.kernel_init_cb != NONE {
        if a.kernel_init_cb != NONE && a.kernel_init_cb != b.kernel_init_cb fatal("openmp-opt: Kernel that calls another kernel violates OpenMP-Opt assumptions.");
        a.kernel_init_cb = b.kernel_init_cb;
    }
    if b.kernel_deinit_cb != NONE {
        if a.kernel_deinit_cb != NONE && a.kernel_deinit_cb != b.kernel_deinit_cb fatal("openmp-opt: Kernel that calls another kernel violates OpenMP-Opt assumptions.");
        a.kernel_deinit_cb = b.kernel_deinit_cb;
    }
    if b.kernel_env_c != NONE {
        if a.kernel_env_c != NONE && a.kernel_env_c != b.kernel_env_c fatal("openmp-opt: Kernel that calls another kernel violates OpenMP-Opt assumptions.");
        a.kernel_env_c = b.kernel_env_c;
    }
    bsv_merge(*a.spmd, *b.spmd);
    bsv_merge(*a.known_prs, *b.known_prs);
    bsv_merge(*a.unknown_prs, *b.unknown_prs);
    a.nested_parallelism |= b.nested_parallelism;
}
// copy assignment of the KernelInfoState part (getState() = FnAA->getState(), KernelInfoState StateBefore = getState())
kis_assign :: (dst: *Kis_Ext, src: *Kis_Ext) {
    dst.is_at_fixpoint = src.is_at_fixpoint;
    bsv_copy(*dst.known_prs, *src.known_prs);
    bsv_copy(*dst.unknown_prs, *src.unknown_prs);
    bsv_copy(*dst.spmd, *src.spmd);
    dst.kernel_init_cb = src.kernel_init_cb;
    dst.kernel_env_c = src.kernel_env_c;
    dst.kernel_deinit_cb = src.kernel_deinit_cb;
    dst.is_kernel_entry = src.is_kernel_entry;
    bsv_copy(*dst.reaching_kernel_entries, *src.reaching_kernel_entries);
    bsv_copy(*dst.parallel_levels, *src.parallel_levels);
    dst.nested_parallelism = src.nested_parallelism;
}
kis_snapshot :: (src: *Kis_Ext) -> Kis_Ext {
    r: Kis_Ext;
    kis_assign(*r, src);
    return r;
}

// ---------------------------------------------------------------- the kernel environment (namespace KernelInfo)

KE_CONFIGURATION :: 0;   // KernelEnvironmentTy members
KE_IDENT :: 1;
KE_USE_GENERIC_STATE_MACHINE :: 0;   // ConfigurationEnvironmentTy members
KE_MAY_USE_NESTED_PARALLELISM :: 1;
KE_EXEC_MODE :: 2;
KE_MIN_THREADS :: 3;
KE_MAX_THREADS :: 4;
KE_MIN_TEAMS :: 5;
KE_MAX_TEAMS :: 6;
OMP_TGT_EXEC_MODE_GENERIC :: 1;
OMP_TGT_EXEC_MODE_SPMD :: 2;
OMP_TGT_EXEC_MODE_GENERIC_SPMD :: 3;

// getKernelEnvironementGVFromKernelInitCB / getKernelEnvironementFromKernelInitCB
omp_kernel_env_gv_from_init_cb :: (cb: Value_Id) -> Value_Id {
    gv := strip_pointer_casts(call_arg(cb, 0));
    if vkind(gv) != .GLOBAL_VAR fatal("openmp-opt: the kernel environment of __kmpc_target_init is not a global variable");
    return gv;
}
omp_kernel_env_from_init_cb :: (cb: Value_Id) -> Value_Id {
    gv := omp_kernel_env_gv_from_init_cb(cb);
    if !glob(gv).has_init || vkind(gv_initializer(gv)) != .C_STRUCT fatal("openmp-opt: the kernel environment is not a constant struct");
    return gv_initializer(gv);
}
// getConfigurationFromKernelEnvironment / getIdentFromKernelEnvironment
omp_kernel_env_configuration :: (env: Value_Id) -> Value_Id {
    c := cf_elt(env, KE_CONFIGURATION);
    if vkind(c) != .C_STRUCT fatal("openmp-opt: the kernel configuration environment is not a constant struct");
    return c;
}
omp_kernel_env_ident :: (env: Value_Id) -> Value_Id { return cf_elt(env, KE_IDENT); }
// get<Member>FromKernelEnvironment (a ConstantInt, or NONE: dyn_cast<ConstantInt>)
omp_kernel_env_config_field :: (env: Value_Id, idx: u64) -> Value_Id {
    c := cf_elt(omp_kernel_env_configuration(env), idx);
    if vkind(c) != .C_INT return NONE;
    return c;
}
// set<Member>OfKernelEnvironment
ki_set_config_field :: (k: *Kis_Ext, idx: u64, v: Value_Id) {
    if v == NONE fatal("openmp-opt: a kernel configuration field is not a constant integer");
    config := omp_kernel_env_configuration(k.kernel_env_c);
    nc := cf_insert_value(config, v, .[cast(u32) idx]);
    if nc == NONE fatal("internal: openmp-opt: failed to create a new configuration environment");
    ne := cf_insert_value(k.kernel_env_c, nc, .[cast(u32) KE_CONFIGURATION]);
    if ne == NONE || vkind(ne) != .C_STRUCT fatal("internal: openmp-opt: failed to create a new kernel environment");
    k.kernel_env_c = ne;
}
ki_int_like :: (c: Value_Id, v: s64) -> Value_Id {
    if c == NONE fatal("openmp-opt: a kernel configuration field is not a constant integer");
    return const_int(vtype(c), cast,no_check(u64) v);
}

// ---------------------------------------------------------------- callbacks

// KernelConfigurationSimplifyCB (the GlobalVariableSimplificationCallback for the kernel environment)
ki_kernel_env_simplify_cb :: (i: u32, q: u32, uai: *bool) -> Value_Id {
    k := kis_ext(i);
    if !k.is_at_fixpoint {
        if q == NONE return NONE;
        uai.* = true;
        atr_record_dependence(i, q, DEP_OPTIONAL);
    }
    return k.kernel_env_c;
}
// CustomStateMachineUseCB / HWThreadIdUseCB / SPMDBarrierUseCB with AddDependence
ki_virtual_use_cb :: (kind: u8, i: u32, q: u32) -> bool {
    k := kis_ext(i);
    add_dependence :: (i: u32, q: u32) -> bool { if q != NONE atr_record_dependence(i, q, DEP_OPTIONAL); return true; }
    if kind == {
        case VU_CUSTOM_STATE_MACHINE;
            if bsv_is_valid(*k.spmd) return add_dependence(i, q);
            if !bsv_is_valid(*k.known_prs) return add_dependence(i, q);
            return false;
        case VU_HW_THREAD_ID;
            if !bsv_is_valid(*k.spmd) return add_dependence(i, q);
            return false;
        case VU_SPMD_BARRIER;
            if !bsv_is_valid(*k.spmd) return add_dependence(i, q);
            if k.spmd.set.count == 0 return add_dependence(i, q);
            if !kis_may_contain_parallel_region(k) return add_dependence(i, q);
            return false;
    }
    return true;
}

// ---------------------------------------------------------------- AAKernelInfoFunction

ki_fn_initialize :: (i: u32) {
    k := kis_ext(i);
    fnv := irp_anchor_scope(aa(i).pos);
    init_rfi := omp_rfi(.__kmpc_target_init);
    deinit_rfi := omp_rfi(.__kmpc_target_deinit);
    store_call_base :: (u: Use_Id, rfi: *Omp_Rfi, storage: *Value_Id) {
        cb := omp_call_if_regular_call_use(u, rfi);
        if cb == NONE fatal("openmp-opt: unexpected use of __kmpc_target_init or __kmpc_target_deinit");
        if storage.* != NONE fatal("openmp-opt: multiple uses of __kmpc_target_init or __kmpc_target_deinit");
        storage.* = cb;
    }
    for u: omp_rfi_uses_in(init_rfi, *fnv) store_call_base(u, init_rfi, *k.kernel_init_cb);
    for u: omp_rfi_uses_in(deinit_rfi, *fnv) store_call_base(u, deinit_rfi, *k.kernel_deinit_cb);
    if k.kernel_init_cb == NONE || k.kernel_deinit_cb == NONE return;
    bsv_insert(*k.reaching_kernel_entries, fnv);
    k.is_kernel_entry = true;
    k.kernel_env_c = omp_kernel_env_from_init_cb(k.kernel_init_cb);
    env_gv := omp_kernel_env_gv_from_init_cb(k.kernel_init_cb);
    table_set(*atr.gv_simplification_cbs, env_gv, i);
    can_change_to_spmd := omp_runtime_fns_available(.[.__kmpc_get_hardware_thread_id_in_block, .__kmpc_barrier_simple_spmd]);
    exec_mode := omp_kernel_env_config_field(k.kernel_env_c, KE_EXEC_MODE);
    if exec_mode == NONE fatal("openmp-opt: the kernel exec mode is not a constant integer");
    assumed_exec_mode := ki_int_like(exec_mode, const_int_sext(exec_mode) | OMP_TGT_EXEC_MODE_GENERIC_SPMD);
    if const_int_sext(exec_mode) & OMP_TGT_EXEC_MODE_SPMD bs_optimistic(*k.spmd.s);
    else if omp_opts.disable_spmdization || !can_change_to_spmd bs_pessimistic(*k.spmd.s);
    else ki_set_config_field(k, KE_EXEC_MODE, assumed_exec_mode);
    i32 := type_int(32);
    min_threads, max_threads := omp_read_thread_bounds_for_kernel(fnv);
    if min_threads != 0 ki_set_config_field(k, KE_MIN_THREADS, const_int(i32, cast,no_check(u64) cast(s64) min_threads));
    if max_threads != 0 ki_set_config_field(k, KE_MAX_THREADS, const_int(i32, cast,no_check(u64) cast(s64) max_threads));
    min_teams, max_teams := omp_read_team_bounds_for_kernel(fnv);
    if min_teams != 0 ki_set_config_field(k, KE_MIN_TEAMS, const_int(i32, cast,no_check(u64) cast(s64) min_teams));
    if max_teams != 0 ki_set_config_field(k, KE_MAX_TEAMS, const_int(i32, cast,no_check(u64) cast(s64) max_teams));
    nested := omp_kernel_env_config_field(k.kernel_env_c, KE_MAY_USE_NESTED_PARALLELISM);
    ki_set_config_field(k, KE_MAY_USE_NESTED_PARALLELISM, ki_int_like(nested, ifx k.nested_parallelism then 1 else 0));
    if !omp_opts.disable_state_machine_rewrite {
        usm := omp_kernel_env_config_field(k.kernel_env_c, KE_USE_GENERIC_STATE_MACHINE);
        ki_set_config_field(k, KE_USE_GENERIC_STATE_MACHINE, ki_int_like(usm, 0));
    }
    register_virtual_use :: (r: Omp_Rtl, kind: u8, i: u32) {
        d := omp_rfi(r).declaration;
        if d == NONE return;
        atr_register_virtual_use_callback(d, kind, i);
    }
    if !is_declaration(call_called_function(k.kernel_init_cb)) {
        register_virtual_use(.__kmpc_get_hardware_num_threads_in_block, VU_CUSTOM_STATE_MACHINE, i);
        register_virtual_use(.__kmpc_get_warp_size, VU_CUSTOM_STATE_MACHINE, i);
        register_virtual_use(.__kmpc_barrier_simple_generic, VU_CUSTOM_STATE_MACHINE, i);
        register_virtual_use(.__kmpc_kernel_parallel, VU_CUSTOM_STATE_MACHINE, i);
        register_virtual_use(.__kmpc_kernel_end_parallel, VU_CUSTOM_STATE_MACHINE, i);
    }
    if bsv_is_fix(*k.spmd) return;
    register_virtual_use(.__kmpc_get_hardware_thread_id_in_block, VU_HW_THREAD_ID, i);
    register_virtual_use(.__kmpc_barrier_simple_spmd, VU_SPMD_BARRIER, i);
}

// UpdateKernelEnvCRAII::~UpdateKernelEnvCRAII
ki_update_kernel_env_raii :: (i: u32) {
    k := kis_ext(i);
    if k.kernel_env_c == NONE return;
    existing := omp_kernel_env_from_init_cb(k.kernel_init_cb);
    // isValidState() of a KernelInfoState is always true
    if !bsv_is_valid(*k.known_prs)
        ki_set_config_field(k, KE_USE_GENERIC_STATE_MACHINE, omp_kernel_env_config_field(existing, KE_USE_GENERIC_STATE_MACHINE));
    if !bsv_is_valid(*k.spmd)
        ki_set_config_field(k, KE_EXEC_MODE, omp_kernel_env_config_field(existing, KE_EXEC_MODE));
    nested := omp_kernel_env_config_field(k.kernel_env_c, KE_MAY_USE_NESTED_PARALLELISM);
    ki_set_config_field(k, KE_MAY_USE_NESTED_PARALLELISM, ki_int_like(nested, ifx k.nested_parallelism then 1 else 0));
}

// AAKernelInfoFunction::updateImpl
ki_fn_update :: (i: u32) -> bool {
    k := kis_ext(i);
    before := kis_snapshot(k);
    defer ki_update_kernel_env_raii(i);
    uai_rw := false;
    if !bsv_is_fix(*k.spmd) {
        ok := true;
        for x: atr_rw_insts(i, *uai_rw, *ok) {
            if is_call_base(x) continue;
            if !may_write_to_memory(x) continue;
            if inst_op(x) == .STORE {
                uo := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(op(x, 1)), i, DEP_OPTIONAL);
                hs := atr_get_aa(.HEAP_TO_STACK, irp_function(inst_fn(x)), i, DEP_OPTIONAL);
                if uo != NONE {
                    objs: [..] Value_Id; objs.allocator = temp;
                    uo_objects(uo, false, *objs);
                    all := true;
                    for obj: objs {
                        if atr_is_assumed_thread_local_object(obj, i) continue;
                        if is_inst(obj) && is_call_base(obj) && hs != NONE && h2s_is_assumed_heap_to_stack(hs, obj) continue;
                        all = false;
                        break;
                    }
                    if all continue;
                }
            }
            bsv_insert(*k.spmd, x);
        }
        if !ok bs_pessimistic(*k.spmd.s);
    }
    uai_reaching := false;
    if !k.is_kernel_entry {
        ki_update_parallel_levels(i);
        all_known := true;
        ki_update_reaching_kernel_entries(i, *all_known);
        uai_reaching = !all_known;
        if k.spmd.set.count != 0 {
            if !bsv_is_valid(*k.parallel_levels) bs_pessimistic(*k.spmd.s);
            else if !bsv_is_valid(*k.reaching_kernel_entries) bs_pessimistic(*k.spmd.s);
            else {
                spmd, generic := 0, 0;
                for kernel: k.reaching_kernel_entries.set {
                    cbaa := atr_get_aa(.KERNEL_INFO, irp_function(kernel), i, DEP_OPTIONAL);
                    if cbaa != NONE && bsv_is_valid(*kis_ext(cbaa).spmd) && bsv_is_assumed(*kis_ext(cbaa).spmd) spmd += 1;
                    else generic += 1;
                    if cbaa == NONE || !bsv_is_fix(*kis_ext(cbaa).spmd) uai_reaching = true;
                }
                if spmd != 0 && generic != 0 bs_pessimistic(*k.spmd.s);
            }
        }
    }
    all_pr_fixed := true;
    all_spmd_fixed := true;
    uai_call := false;
    ok := true;
    for cb: atr_call_like_insts(i, *uai_call, *ok) {
        cbaa := atr_get_aa(.KERNEL_INFO, irp_cs_function(cb), i, DEP_OPTIONAL);
        if cbaa == NONE { ok = false; break; }
        c := kis_ext(cbaa);
        kis_merge(k, c);
        all_spmd_fixed &= bsv_is_fix(*c.spmd);
        all_pr_fixed &= bsv_is_fix(*c.known_prs);
        all_pr_fixed &= bsv_is_fix(*c.unknown_prs);
    }
    if !ok return aa_pessimistic(i);
    if !uai_call && all_pr_fixed {
        bs_optimistic(*k.known_prs.s);
        bs_optimistic(*k.unknown_prs.s);
    }
    if !uai_rw && !uai_call && !uai_reaching && all_spmd_fixed bs_optimistic(*k.spmd.s);
    return ifx kis_eq(*before, k) then ATR_UNCHANGED else ATR_CHANGED;
}

// updateReachingKernelEntries (AllReachingKernelsKnown is checkForAllCallSites' UsedAssumedInformation, which
// starts out true here)
ki_update_reaching_kernel_entries :: (i: u32, all_known: *bool) {
    k := kis_ext(i);
    ok := true;
    for cb: atr_call_sites(i, true, all_known, *ok) {
        caller := inst_fn(cb);
        caa := atr_get_aa(.KERNEL_INFO, irp_function(caller), i, DEP_REQUIRED);
        if caa != NONE && bsv_is_valid(*kis_ext(caa).reaching_kernel_entries) {
            bsv_merge(*k.reaching_kernel_entries, *kis_ext(caa).reaching_kernel_entries);
            continue;
        }
        bs_pessimistic(*k.reaching_kernel_entries.s);
    }
    if !ok bs_pessimistic(*k.reaching_kernel_entries.s);
}
// updateParallelLevels
ki_update_parallel_levels :: (i: u32) {
    k := kis_ext(i);
    p60 := omp_rfi(.__kmpc_parallel_60);
    all_known := true;
    ok := true;
    for cb: atr_call_sites(i, true, *all_known, *ok) {
        caller := inst_fn(cb);
        caa := atr_get_aa(.KERNEL_INFO, irp_function(caller), NONE, DEP_REQUIRED);
        if caa != NONE && bsv_is_valid(*kis_ext(caa).parallel_levels) {
            if caller == p60.declaration { bs_pessimistic(*k.parallel_levels.s); continue; }
            bsv_merge(*k.parallel_levels, *kis_ext(caa).parallel_levels);
            continue;
        }
        bs_pessimistic(*k.parallel_levels.s);
    }
    if !ok bs_pessimistic(*k.parallel_levels.s);
}

// sanitizeForGlobalName
omp_sanitize_for_global_name :: (s: string) -> string {
    r := copy_string(s,, temp);
    for * cast([] u8) r {
        c := it.*;
        if !((c >= #char "a" && c <= #char "z") || (c >= #char "A" && c <= #char "Z") || (c >= #char "0" && c <= #char "9") || c == #char "_") it.* = #char ".";
    }
    return r;
}

// AAKernelInfoFunction::manifest
ki_fn_manifest :: (i: u32) -> bool {
    k := kis_ext(i);
    if k.kernel_init_cb == NONE || k.kernel_deinit_cb == NONE return ATR_UNCHANGED;
    changed := ATR_UNCHANGED;
    has_built_state_machine := true;
    if !ki_change_to_spmd_mode(i, *changed) {
        if !is_declaration(call_called_function(k.kernel_init_cb)) has_built_state_machine = ki_build_custom_state_machine(i, *changed);
        else has_built_state_machine = false;
    }
    existing := omp_kernel_env_from_init_cb(k.kernel_init_cb);
    old_usm := omp_kernel_env_config_field(existing, KE_USE_GENERIC_STATE_MACHINE);
    if !has_built_state_machine ki_set_config_field(k, KE_USE_GENERIC_STATE_MACHINE, old_usm);
    env_gv := omp_kernel_env_gv_from_init_cb(k.kernel_init_cb);
    if gv_initializer(env_gv) != k.kernel_env_c {
        gv_set_initializer(env_gv, k.kernel_env_c);
        changed = ATR_CHANGED;
    }
    return changed;
}

// insertInstructionGuardsHelper
ki_insert_instruction_guards_helper :: (i: u32) {
    k := kis_ext(i);
    create_guarded_region :: (region_start: Value_Id, region_end: Value_Id) {
        parent_bb := inst_block(region_start);
        f := block_fn(parent_bb);
        region_end_bb := split_block(parent_bb, inst_next(region_end), null, null, null, "region.guarded.end");
        region_barrier_bb := split_block(region_end_bb, block_first_insertion_pt(region_end_bb), null, null, null, "region.barrier");
        region_exit_bb := split_block(region_barrier_bb, block_first_insertion_pt(region_barrier_bb), null, null, null, "region.exit");
        region_start_bb := split_block(parent_bb, region_start, null, null, null, "region.guarded");
        if block_unique_successor(parent_bb) != region_start_bb fatal("internal: openmp-opt: expected a different CFG");
        region_check_tid_bb := split_block(parent_bb, block_terminator(parent_bb), null, null, null, "region.check.tid");
        atr_register_manifest_added_block(region_end_bb);
        atr_register_manifest_added_block(region_barrier_bb);
        atr_register_manifest_added_block(region_exit_bb);
        atr_register_manifest_added_block(region_start_bb);
        atr_register_manifest_added_block(region_check_tid_bb);
        has_broadcast_values := false;
        for x: block_insts(region_start_bb) {
            outside: [..] Use_Id; outside.allocator = temp;
            u := ir.v_first_use[x];
            while u != NONE {
                usr := ir.u_user[u];
                if inst_block(usr) != region_start_bb array_add(*outside, u);
                u = ir.u_next[u];
            }
            if outside.count == 0 continue;
            has_broadcast_values = true;
            ty := vtype(x);
            shared := gv_create(ty, false, .INTERNAL, const_undef(ty),
                                omp_sanitize_for_global_name(tconcat(vname(x), ".guarded.output.alloc")), NONE, 0, OMP_AS_SHARED);
            st := create_store_raw(x, shared, dl_abi_align(ty));
            insert_before_named(st, block_terminator(region_end_bb), "");
            ld := new_inst(.LOAD, ty, 1);
            set_op(ld, 0, shared);
            inst(ld).align = dl_abi_align(ty);
            insert_before_named(ld, block_terminator(region_barrier_bb), tconcat(vname(x), ".guarded.output.load"));
            for outside atr_change_use_after_manifest(it, ld);
        }
        dl_md := get_metadata(block_terminator(parent_bb), MDK_DBG);
        erase_inst(block_terminator(parent_bb));
        src_loc_str, size := omp_get_or_create_src_loc_str_dl(*omp_ic.b, dl_md, f);
        ident := omp_get_or_create_ident(*omp_ic.b, src_loc_str, size);
        br := create_br(region_check_tid_bb);
        insert_at_end_named(br, parent_bb, "");
        if dl_md != NONE set_metadata(br, MDK_DBG, dl_md);
        erase_inst(block_terminator(region_check_tid_bb));
        b: Irb;
        irb_set_end(*b, region_check_tid_bb);
        b.dbg = dl_md;
        hw_tid_fn := omp_get_or_create_runtime_function(.__kmpc_get_hardware_thread_id_in_block);
        tid := irb_call(*b, hw_tid_fn, .[]);
        omp_set_calling_convention(hw_tid_fn, tid);
        tid_check := irb_insert(*b, create_icmp(ICMP_EQ, tid, const_null_value(vtype(tid))));
        irb_insert(*b, create_cond_br(tid_check, region_start_bb, region_barrier_bb));
        barrier_fn := omp_get_or_create_runtime_function(.__kmpc_barrier_simple_spmd);
        irb_set_at(*b, region_barrier_bb, block_first_insertion_pt(region_barrier_bb), false);
        b.dbg = dl_md;
        barrier := irb_call(*b, barrier_fn, .[ident, tid]);
        omp_set_calling_convention(barrier_fn, barrier);
        if has_broadcast_values {
            b2 := create_call_fn(barrier_fn, .[ident, tid]);
            insert_before_named(b2, block_terminator(region_barrier_bb), "");
            if dl_md != NONE set_metadata(b2, MDK_DBG, dl_md);
            omp_set_calling_convention(barrier_fn, b2);
        }
    }
    alloc_shared := omp_rfi(.__kmpc_alloc_shared);
    visited: [..] Value_Id; visited.allocator = temp;
    for guarded_i: k.spmd.set {
        bb := inst_block(guarded_i);
        if omp_contains(visited, bb) continue;
        array_add(*visited, bb);
        reorders: [..] [2] Value_Id; reorders.allocator = temp;
        last_effect: Value_Id = NONE;
        // BasicBlock::reverse_iterator IP = BB->rbegin(); while (++IP != IPEnd): the terminator is skipped
        ip := block_last(bb);
        while true {
            ip = inst_prev(ip);
            if ip == NONE break;
            if !may_have_side_effects(ip) && !may_read_from_memory(ip) continue;
            if omp_call_if_regular_call(ip, alloc_shared) != NONE continue;
            if has_uses(ip) || !bsv_contains(*k.spmd, ip) { last_effect = NONE; continue; }
            if last_effect != NONE array_add(*reorders, .[ip, last_effect]);
            last_effect = ip;
        }
        for reorders inst_move_before(it[0], it[1]);
    }
    regions: [..] [2] Value_Id; regions.allocator = temp;
    for guarded_i: k.spmd.set {
        bb := inst_block(guarded_i);
        callee_aa := atr_lookup(.KERNEL_INFO, irp_function(inst_fn(guarded_i)), NONE, DEP_NONE);
        if callee_aa == NONE fatal("internal: openmp-opt: expected a callee AAKernelInfo");
        ce := kis_ext(callee_aa);
        if omp_contains(ce.guarded, guarded_i) continue;
        start, end_: Value_Id = NONE;
        for x: block_insts(bb) {
            if bsv_contains(*k.spmd, x) {
                ed_set_add(*ce.guarded, x);
                if start != NONE end_ = x;
                else { start = x; end_ = x; }
                continue;
            }
            if start != NONE {
                array_add(*regions, .[start, end_]);
                start = NONE; end_ = NONE;
            }
        }
    }
    for regions create_guarded_region(it[0], it[1]);
}

// forceSingleThreadPerWorkgroupHelper
ki_force_single_thread_per_workgroup_helper :: (i: u32) {
    k := kis_ext(i);
    kernel := irp_assoc_fn(aa(i).pos);
    init_bb := inst_block(k.kernel_init_cb);
    user_code_bb := split_basic_block(init_bb, inst_next(k.kernel_init_cb), "main.thread.user_code");
    return_bb := create_block(kernel, "exit.threads", user_code_bb);
    atr_register_manifest_added_block(init_bb);
    atr_register_manifest_added_block(user_code_bb);
    atr_register_manifest_added_block(return_bb);
    dloc := get_metadata(k.kernel_init_cb, MDK_DBG);
    ret := new_inst(.RET, ir.t_void, 0);
    insert_at_end_named(ret, return_bb, "");
    if dloc != NONE set_metadata(ret, MDK_DBG, dloc);
    erase_inst(block_terminator(init_bb));
    fnv := omp_get_or_create_runtime_function(.__kmpc_get_hardware_thread_id_in_block);
    tid := create_call_fn(fnv, .[]);
    insert_at_end_named(tid, init_bb, "thread_id.in.block");
    omp_set_calling_convention(fnv, tid);
    if dloc != NONE set_metadata(tid, MDK_DBG, dloc);
    is_main := create_icmp(ICMP_NE, tid, const_int(vtype(tid), 0));
    insert_at_end_named(is_main, init_bb, "thread.is_main");
    if dloc != NONE set_metadata(is_main, MDK_DBG, dloc);
    insert_at_end_named(create_cond_br(is_main, return_bb, user_code_bb), init_bb, "");
}

// changeToSPMDMode
ki_change_to_spmd_mode :: (i: u32, changed: *bool) -> bool {
    k := kis_ext(i);
    if !bsv_is_assumed(*k.spmd) return false;   // (the OMP121 remarks)
    kernel := irp_anchor_scope(aa(i).pos);
    if gv_has_local_linkage(kernel) {
        if !has_one_use(kernel) fatal("openmp-opt: unexpected use of debug kernel wrapper");
        cb := ir.u_user[ir.v_first_use[kernel]];
        kernel = inst_fn(cb);
    }
    if !omp_is_kernel(kernel) fatal("internal: openmp-opt: expected a kernel function");
    existing := omp_kernel_env_from_init_cb(k.kernel_init_cb);
    exec_mode := omp_kernel_env_config_field(existing, KE_EXEC_MODE);
    val := cast,no_check(s8) const_int_sext(exec_mode);
    if val != OMP_TGT_EXEC_MODE_GENERIC return true;
    changed.* = ATR_CHANGED;
    if kis_may_contain_parallel_region(k) ki_insert_instruction_guards_helper(i);
    else ki_force_single_thread_per_workgroup_helper(i);
    ki_set_config_field(k, KE_EXEC_MODE, ki_int_like(exec_mode, val | OMP_TGT_EXEC_MODE_GENERIC_SPMD));
    return true;
}

// buildCustomStateMachine
ki_build_custom_state_machine :: (i: u32, changed: *bool) -> bool {
    k := kis_ext(i);
    if omp_opts.disable_state_machine_rewrite return false;
    if !bsv_is_valid(*k.known_prs) return false;
    if !omp_runtime_fns_available(.[.__kmpc_get_hardware_num_threads_in_block, .__kmpc_get_warp_size,
                                    .__kmpc_barrier_simple_generic, .__kmpc_kernel_parallel, .__kmpc_kernel_end_parallel]) return false;
    existing := omp_kernel_env_from_init_cb(k.kernel_init_cb);
    usm := omp_kernel_env_config_field(existing, KE_USE_GENERIC_STATE_MACHINE);
    mode := omp_kernel_env_config_field(existing, KE_EXEC_MODE);
    if usm == NONE || mode == NONE fatal("openmp-opt: the kernel configuration is not constant");
    if ap_is_zero(const_ap(usm)) || (const_int_sext(mode) & OMP_TGT_EXEC_MODE_SPMD) != 0 return false;
    changed.* = ATR_CHANGED;
    ki_set_config_field(k, KE_USE_GENERIC_STATE_MACHINE, ki_int_like(usm, 0));
    if !kis_may_contain_parallel_region(k) return true;
    kernel := irp_assoc_fn(aa(i).pos);
    init_cb := k.kernel_init_cb;
    init_bb := inst_block(init_cb);
    user_code_entry_bb := split_basic_block(init_bb, inst_next(init_cb), "thread.user_code.check");
    is_worker_check_bb := create_block(kernel, "is_worker_check", user_code_entry_bb);
    sm_begin_bb := create_block(kernel, "worker_state_machine.begin", user_code_entry_bb);
    sm_finished_bb := create_block(kernel, "worker_state_machine.finished", user_code_entry_bb);
    sm_is_active_check_bb := create_block(kernel, "worker_state_machine.is_active.check", user_code_entry_bb);
    sm_if_cascade_current_bb := create_block(kernel, "worker_state_machine.parallel_region.check", user_code_entry_bb);
    sm_end_parallel_bb := create_block(kernel, "worker_state_machine.parallel_region.end", user_code_entry_bb);
    sm_done_barrier_bb := create_block(kernel, "worker_state_machine.done.barrier", user_code_entry_bb);
    for bb: Value_Id.[init_bb, user_code_entry_bb, is_worker_check_bb, sm_begin_bb, sm_finished_bb, sm_is_active_check_bb,
                      sm_if_cascade_current_bb, sm_end_parallel_bb, sm_done_barrier_bb] atr_register_manifest_added_block(bb);
    dloc := get_metadata(init_cb, MDK_DBG);
    with_dl :: (x: Value_Id, dloc: Md_Id) -> Value_Id { if dloc != NONE set_metadata(x, MDK_DBG, dloc); return x; }
    with_dl(insert_at_end_named(new_inst(.RET, ir.t_void, 0), sm_finished_bb, ""), dloc);
    erase_inst(block_terminator(init_bb));
    is_worker := create_icmp(ICMP_NE, init_cb, const_all_ones_of(vtype(init_cb)));
    with_dl(insert_at_end_named(is_worker, init_bb, "thread.is_worker"), dloc);
    insert_at_end_named(create_cond_br(is_worker, is_worker_check_bb, user_code_entry_bb), init_bb, "");
    block_hw_size_fn := omp_get_or_create_runtime_function(.__kmpc_get_hardware_num_threads_in_block);
    warp_size_fn := omp_get_or_create_runtime_function(.__kmpc_get_warp_size);
    block_hw_size := create_call_fn(block_hw_size_fn, .[]);
    insert_at_end_named(block_hw_size, is_worker_check_bb, "block.hw_size");
    omp_set_calling_convention(block_hw_size_fn, block_hw_size);
    with_dl(block_hw_size, dloc);
    warp_size := create_call_fn(warp_size_fn, .[]);
    insert_at_end_named(warp_size, is_worker_check_bb, "warp.size");
    omp_set_calling_convention(warp_size_fn, warp_size);
    with_dl(warp_size, dloc);
    block_size := create_binop(.SUB, block_hw_size, warp_size);
    with_dl(insert_at_end_named(block_size, is_worker_check_bb, "block.size"), dloc);
    is_main_or_worker := create_icmp(ICMP_SLT, init_cb, block_size);
    with_dl(insert_at_end_named(is_main_or_worker, is_worker_check_bb, "thread.is_main_or_worker"), dloc);
    insert_at_end_named(create_cond_br(is_main_or_worker, sm_begin_bb, sm_finished_bb), is_worker_check_bb, "");
    // the work function pointer storage
    void_ptr := ir.t_ptr;
    work_fn_ai := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
    inst(work_fn_ai).ty2 = void_ptr;
    inst(work_fn_ai).align = dl_pref_align(void_ptr);
    inst(work_fn_ai).addrspace = dl.alloca_as;
    set_op(work_fn_ai, 0, const_int(type_int(32), 1));
    entry := fn_entry(kernel);
    if block_first(entry) != NONE insert_before_named(work_fn_ai, block_first(entry), "worker.work_fn.addr");
    else insert_at_end_named(work_fn_ai, entry, "worker.work_fn.addr");
    with_dl(work_fn_ai, dloc);
    ident := omp_kernel_env_ident(k.kernel_env_c);
    gtid := init_cb;
    barrier_fn := omp_get_or_create_runtime_function(.__kmpc_barrier_simple_generic);
    barrier := create_call_fn(barrier_fn, .[ident, gtid]);
    insert_at_end_named(barrier, sm_begin_bb, "");
    omp_set_calling_convention(barrier_fn, barrier);
    with_dl(barrier, dloc);
    if dl.alloca_as != 0 {
        cast_ai := create_cast(.ADDRSPACECAST, work_fn_ai, type_ptr(0));
        with_dl(insert_at_end_named(cast_ai, sm_begin_bb, tconcat(vname(work_fn_ai), ".generic")), dloc);
        work_fn_ai = cast_ai;
    }
    kernel_parallel_fn := omp_get_or_create_runtime_function(.__kmpc_kernel_parallel);
    is_active_worker := create_call_fn(kernel_parallel_fn, .[work_fn_ai]);
    insert_at_end_named(is_active_worker, sm_begin_bb, "worker.is_active");
    omp_set_calling_convention(kernel_parallel_fn, is_active_worker);
    with_dl(is_active_worker, dloc);
    work_fn := new_inst(.LOAD, void_ptr, 1);
    set_op(work_fn, 0, work_fn_ai);
    inst(work_fn).align = dl_abi_align(void_ptr);
    with_dl(insert_at_end_named(work_fn, sm_begin_bb, "worker.work_fn"), dloc);
    parallel_region_fn_ty := type_func(ir.t_void, .[type_int(16), type_int(32)], false);
    is_done := create_icmp(ICMP_EQ, work_fn, const_null(void_ptr));
    with_dl(insert_at_end_named(is_done, sm_begin_bb, "worker.is_done"), dloc);
    with_dl(insert_at_end_named(create_cond_br(is_done, sm_finished_bb, sm_is_active_check_bb), sm_begin_bb, ""), dloc);
    with_dl(insert_at_end_named(create_cond_br(is_active_worker, sm_if_cascade_current_bb, sm_done_barrier_bb), sm_is_active_check_bb, ""), dloc);
    zero_arg := const_null_value(type_int(16));
    wrapper_function_arg_no :: 6;
    e := k.known_prs.set.count;
    for idx: 0..e - 1 {
        cb := k.known_prs.set[idx];
        parallel_region := strip_pointer_casts(call_arg(cb, wrapper_function_arg_no));
        if vkind(parallel_region) != .FUNCTION fatal("openmp-opt: a known parallel region without a function");
        pr_execute_bb := create_block(kernel, "worker_state_machine.parallel_region.execute", sm_end_parallel_bb);
        with_dl(insert_at_end_named(create_call_fn(parallel_region, .[zero_arg, gtid]), pr_execute_bb, ""), dloc);
        with_dl(insert_at_end_named(create_br(sm_end_parallel_bb), pr_execute_bb, ""), dloc);
        pr_next_bb := create_block(kernel, "worker_state_machine.parallel_region.check", sm_end_parallel_bb);
        atr_register_manifest_added_block(pr_execute_bb);
        atr_register_manifest_added_block(pr_next_bb);
        is_pr: Value_Id;
        if idx + 1 < e || k.unknown_prs.set.count != 0 {
            cmp := create_icmp(ICMP_EQ, work_fn, parallel_region);
            with_dl(insert_at_end_named(cmp, sm_if_cascade_current_bb, "worker.check_parallel_region"), dloc);
            is_pr = cmp;
        } else {
            is_pr = const_int(ir.t_i1, 1);
        }
        with_dl(insert_at_end_named(create_cond_br(is_pr, pr_execute_bb, pr_next_bb), sm_if_cascade_current_bb, ""), dloc);
        sm_if_cascade_current_bb = pr_next_bb;
    }
    if k.unknown_prs.set.count != 0 {
        set_name(sm_if_cascade_current_bb, "worker_state_machine.parallel_region.fallback.execute");
        indirect := new_inst(.CALL, ir.t_void, 3);
        inst(indirect).ty2 = parallel_region_fn_ty;
        set_op(indirect, 0, zero_arg); set_op(indirect, 1, gtid); set_op(indirect, 2, work_fn);
        with_dl(insert_at_end_named(indirect, sm_if_cascade_current_bb, ""), dloc);
    }
    with_dl(insert_at_end_named(create_br(sm_end_parallel_bb), sm_if_cascade_current_bb, ""), dloc);
    end_parallel_fn := omp_get_or_create_runtime_function(.__kmpc_kernel_end_parallel);
    end_parallel := create_call_fn(end_parallel_fn, .[]);
    insert_at_end_named(end_parallel, sm_end_parallel_bb, "");
    omp_set_calling_convention(end_parallel_fn, end_parallel);
    with_dl(end_parallel, dloc);
    with_dl(insert_at_end_named(create_br(sm_done_barrier_bb), sm_end_parallel_bb, ""), dloc);
    with_dl(insert_at_end_named(create_call_fn(barrier_fn, .[ident, gtid]), sm_done_barrier_bb, ""), dloc);
    with_dl(insert_at_end_named(create_br(sm_begin_bb), sm_done_barrier_bb, ""), dloc);
    return true;
}

// ---------------------------------------------------------------- AAKernelInfoCallSite

ki_cs_initialize :: (i: u32) {
    k := kis_ext(i);
    cb := irp_assoc_value(aa(i).pos);
    asi := atr_get_aa(.ASSUMPTION_INFO, irp_cs_function(cb), i, DEP_OPTIONAL);
    if asi != NONE && asi_has_assumption(asi, "ompx_spmd_amenable") { kis_optimistic(k); return; }
    if !may_write_to_memory(cb) || (inst_op(cb) == .CALL && call_iid(cb) != NOT_INTRINSIC) { kis_optimistic(k); return; }
    check_callee :: (i: u32, cb: Value_Id, callee: Value_Id, num_callees: s64, asi: u32) {
        k := kis_ext(i);
        found, rf := table_find(*omp_ic.rtf_id, callee);
        if !found || callee == NONE {
            if callee == NONE || !atr_is_ipo_amendable(callee) {
                if asi == NONE || !(asi_has_assumption(asi, "omp_no_openmp") || asi_has_assumption(asi, "omp_no_parallelism"))
                    bsv_insert(*k.unknown_prs, cb);
                if !bsv_is_fix(*k.spmd) {
                    bs_pessimistic(*k.spmd.s);
                    bsv_insert(*k.spmd, cb);
                }
                kis_optimistic(k);
            }
            return;
        }
        if num_callees > 1 { kis_pessimistic(k); return; }
        spmd_incompatible :: (k: *Kis_Ext, cb: Value_Id) { bs_pessimistic(*k.spmd.s); bsv_insert(*k.spmd, cb); }
        if rf == {
            case .__kmpc_is_spmd_exec_mode; #through; case .__kmpc_distribute_static_fini; #through;
            case .__kmpc_for_static_fini; #through; case .__kmpc_global_thread_num; #through;
            case .__kmpc_get_hardware_num_threads_in_block; #through; case .__kmpc_get_hardware_num_blocks; #through;
            case .__kmpc_single; #through; case .__kmpc_end_single; #through; case .__kmpc_master; #through;
            case .__kmpc_end_master; #through; case .__kmpc_barrier; #through;
            case .__kmpc_nvptx_parallel_reduce_nowait_v2; #through; case .__kmpc_gpu_xteam_reduce_nowait; #through;
            case .__kmpc_error; #through; case .__kmpc_flush; #through;
            case .__kmpc_get_hardware_thread_id_in_block; #through; case .__kmpc_get_warp_size; #through;
            case .omp_get_thread_num; #through; case .omp_get_num_threads; #through; case .omp_get_max_threads; #through;
            case .omp_in_parallel; #through; case .omp_get_dynamic; #through; case .omp_get_cancellation; #through;
            case .omp_get_nested; #through; case .omp_get_schedule; #through; case .omp_get_thread_limit; #through;
            case .omp_get_supported_active_levels; #through; case .omp_get_max_active_levels; #through;
            case .omp_get_level; #through; case .omp_get_ancestor_thread_num; #through; case .omp_get_team_size; #through;
            case .omp_get_active_level; #through; case .omp_in_final; #through; case .omp_get_proc_bind; #through;
            case .omp_get_num_places; #through; case .omp_get_num_procs; #through; case .omp_get_place_proc_ids; #through;
            case .omp_get_place_num; #through; case .omp_get_partition_num_places; #through;
            case .omp_get_partition_place_nums; #through; case .omp_get_wtime;
                // compatible with SPMD mode
            case .__kmpc_distribute_static_init_4; #through; case .__kmpc_distribute_static_init_4u; #through;
            case .__kmpc_distribute_static_init_8; #through; case .__kmpc_distribute_static_init_8u; #through;
            case .__kmpc_for_static_init_4; #through; case .__kmpc_for_static_init_4u; #through;
            case .__kmpc_for_static_init_8; #through; case .__kmpc_for_static_init_8u;
                sched := call_arg(cb, 2);
                v: u64 = ifx vkind(sched) == .C_INT then const_int_zext(sched) else 0;
                // UnorderedStatic, UnorderedStaticChunked, OrderedDistribute, OrderedDistributeChunked
                if !(v == 34 || v == 33 || v == 92 || v == 91) spmd_incompatible(k, cb);
            case .__kmpc_target_init; k.kernel_init_cb = cb;
            case .__kmpc_target_deinit; k.kernel_deinit_cb = cb;
            case .__kmpc_parallel_60;
                if !ki_handle_parallel60(i, cb) kis_pessimistic(k);
                return;
            case .__kmpc_omp_task;
                spmd_incompatible(k, cb);
                bsv_insert(*k.unknown_prs, cb);
            case .__kmpc_alloc_shared; #through; case .__kmpc_free_shared;
                return;
            case .__kmpc_distribute_static_loop_4; #through; case .__kmpc_distribute_static_loop_4u; #through;
            case .__kmpc_distribute_static_loop_8; #through; case .__kmpc_distribute_static_loop_8u; #through;
            case .__kmpc_distribute_for_static_loop_4; #through; case .__kmpc_distribute_for_static_loop_4u; #through;
            case .__kmpc_distribute_for_static_loop_8; #through; case .__kmpc_distribute_for_static_loop_8u; #through;
            case .__kmpc_for_static_loop_4; #through; case .__kmpc_for_static_loop_4u; #through;
            case .__kmpc_for_static_loop_8; #through; case .__kmpc_for_static_loop_8u;
                bsv_insert(*k.unknown_prs, cb);
                spmd_incompatible(k, cb);
            case;
                spmd_incompatible(k, cb);
        }
        kis_optimistic(k);
    }
    ace := atr_get_aa(.CALL_EDGES, aa(i).pos, i, DEP_OPTIONAL);
    if ace == NONE || !aa_is_valid(ace) || aa(ace).unknown_callee {
        check_callee(i, cb, irp_assoc_fn(aa(i).pos), 1, asi);
        return;
    }
    edges: [..] Value_Id; edges.allocator = temp;
    for aa(ace).callees array_add(*edges, it);
    for callee: edges {
        check_callee(i, cb, callee, edges.count, asi);
        if k.is_at_fixpoint break;
    }
}

ki_cs_update :: (i: u32) -> bool {
    k := kis_ext(i);
    before := kis_snapshot(k);
    cb := irp_assoc_value(aa(i).pos);
    check_callee :: (i: u32, cb: Value_Id, f: Value_Id, num_callees: s64, before: *Kis_Ext) {
        k := kis_ext(i);
        found, rf := table_find(*omp_ic.rtf_id, f);
        if !found {
            fn_aa := atr_get_aa(.KERNEL_INFO, irp_function(f), i, DEP_REQUIRED);
            if fn_aa == NONE { kis_pessimistic(k); return; }
            if kis_eq(k, kis_ext(fn_aa)) return;
            kis_assign(k, kis_ext(fn_aa));
            return;
        }
        if num_callees > 1 { kis_pessimistic(k); return; }
        if rf == .__kmpc_parallel_60 {
            if !ki_handle_parallel60(i, cb) kis_pessimistic(k);
            return;
        }
        if rf != .__kmpc_alloc_shared && rf != .__kmpc_free_shared fatal("internal: openmp-opt: expected a __kmpc_alloc_shared or __kmpc_free_shared runtime call");
        caller := inst_fn(cb);
        h2s := atr_get_aa(.HEAP_TO_STACK, irp_function(caller), i, DEP_OPTIONAL);
        h2sh := atr_get_aa(.HEAP_TO_SHARED, irp_function(caller), i, DEP_OPTIONAL);
        if rf == .__kmpc_alloc_shared {
            if (h2s == NONE || !h2s_is_assumed_heap_to_stack(h2s, cb)) && (h2sh == NONE || !h2sh_is_assumed_heap_to_shared(h2sh, cb))
                bsv_insert(*k.spmd, cb);
        } else {
            if (h2s == NONE || !h2s_is_assumed_removed_free(h2s, cb)) && (h2sh == NONE || !h2sh_is_assumed_removed_free(h2sh, cb))
                bsv_insert(*k.spmd, cb);
        }
    }
    ace := atr_get_aa(.CALL_EDGES, aa(i).pos, i, DEP_OPTIONAL);
    if ace == NONE || !aa_is_valid(ace) || aa(ace).unknown_callee {
        f := irp_assoc_fn(aa(i).pos);
        if f != NONE check_callee(i, cb, f, 1, *before);
    } else {
        edges: [..] Value_Id; edges.allocator = temp;
        for aa(ace).callees array_add(*edges, it);
        for callee: edges {
            check_callee(i, cb, callee, edges.count, *before);
            if k.is_at_fixpoint break;
        }
    }
    return ifx kis_eq(*before, k) then ATR_UNCHANGED else ATR_CHANGED;
}

// handleParallel60
ki_handle_parallel60 :: (i: u32, cb: Value_Id) -> bool {
    k := kis_ext(i);
    arg_no: u32 = ifx bsv_is_assumed(*k.spmd) then cast(u32) 5 else 6;
    pr := strip_pointer_casts(call_arg(cb, arg_no));
    if vkind(pr) != .FUNCTION return false;
    bsv_insert(*k.known_prs, cb);
    fn_aa := atr_get_aa(.KERNEL_INFO, irp_function(pr), i, DEP_OPTIONAL);
    if fn_aa == NONE { k.nested_parallelism = true; return true; }
    fk := kis_ext(fn_aa);
    k.nested_parallelism |= fk.known_prs.set.count != 0 || !bsv_is_valid(*fk.known_prs) || !bsv_is_valid(*fk.unknown_prs) ||
                            fk.unknown_prs.set.count != 0;
    return true;
}

// ---------------------------------------------------------------- getUniqueKernelFor / rewriteDeviceCodeStateMachine

// OpenMPOpt::getUniqueKernelFor(Function &F)
omp_get_unique_kernel_for :: (f: Value_Id) -> Value_Id {
    if omp_ic.cgscc.count != 0 && !table_contains(*omp_ic.cgscc_set, f) return NONE;
    found, cached := table_find(*oo.unique_kernel_map, f);
    if found && cached != OV_NOVAL return cached;
    if omp_is_kernel(f) { table_set(*oo.unique_kernel_map, f, f); return f; }
    table_set(*oo.unique_kernel_map, f, NONE);
    if !gv_has_local_linkage(f) return NONE;   // (the OMP100 remark)
    // GetUniqueKernelForUse
    for_use :: (u: Use_Id) -> Value_Id {
        usr := ir.u_user[u];
        if is_inst(usr) && inst_op(usr) == .ICMP {
            if cmp_is_equality(usr) return omp_get_unique_kernel_for(inst_fn(usr));
            return NONE;
        }
        if is_inst(usr) && is_call_base(usr) {
            if u == op_use(usr, nops(usr) - 1) return omp_get_unique_kernel_for(inst_fn(usr));
            if omp_call_if_regular_call(usr, omp_rfi(.__kmpc_parallel_60)) != NONE return omp_get_unique_kernel_for(inst_fn(usr));
            return NONE;
        }
        return NONE;
    }
    potential: [..] Value_Id; potential.allocator = temp;
    work: [..] Use_Id; work.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*work, u); u = ir.u_next[u]; }
    idx := 0;
    while idx < work.count {
        w := work[idx];
        idx += 1;
        usr := ir.u_user[w];
        if vkind(usr) == .C_EXPR {
            x := ir.v_first_use[usr];
            while x != NONE { array_add(*work, x); x = ir.u_next[x]; }
            continue;
        }
        kk := for_use(w);
        if !omp_contains(potential, kk) array_add(*potential, kk);
    }
    kernel: Value_Id = NONE;
    if potential.count == 1 kernel = potential[0];
    table_set(*oo.unique_kernel_map, f, kernel);
    return kernel;
}

// OpenMPOpt::rewriteDeviceCodeStateMachine
omp_rewrite_device_code_state_machine :: () -> bool {
    kp := omp_rfi(.__kmpc_parallel_60);
    changed := false;
    if kp.declaration == NONE return changed;
    if omp_opts.disable_state_machine_rewrite return changed;
    for f: oo.scc {
        unknown_use := false;
        kernel_parallel_use := false;
        num_direct_calls := 0;
        to_replace: [..] Use_Id; to_replace.allocator = temp;
        work: [..] Use_Id; work.allocator = temp;
        u := ir.v_first_use[f];
        while u != NONE { array_add(*work, u); u = ir.u_next[u]; }
        idx := 0;
        while idx < work.count {
            w := work[idx];
            idx += 1;
            usr := ir.u_user[w];
            if vkind(usr) == .C_EXPR {
                x := ir.v_first_use[usr];
                while x != NONE { array_add(*work, x); x = ir.u_next[x]; }
                continue;
            }
            if is_inst(usr) && is_call_base(usr) && w == op_use(usr, nops(usr) - 1) { num_direct_calls += 1; continue; }
            if is_inst(usr) && inst_op(usr) == .ICMP { array_add(*to_replace, w); continue; }
            ci := omp_call_if_regular_call(usr, kp);
            if !kernel_parallel_use && ci != NONE && use_arg_no(w) == 6 {
                kernel_parallel_use = true;
                array_add(*to_replace, w);
                continue;
            }
            unknown_use = true;
        }
        if !kernel_parallel_use continue;
        if unknown_use || num_direct_calls != 1 || to_replace.count > 2 continue;   // (the OMP101 remark)
        kernel := omp_get_unique_kernel_for(f);
        if kernel == NONE continue;   // (the OMP102 remark)
        id := gv_create(ir.t_i8, true, .PRIVATE, const_undef(ir.t_i8), tconcat(vname(f), ".ID"), NONE, 0, dl_default_globals_as());
        for to_replace use_set(it, ce_pointer_bitcast_or_addrspacecast(id, vtype(ir.u_val[it])));
        changed = true;
    }
    return changed;
}
