// InstrProfiling lowering (`instrprof`, InstrProfilingLoweringPass): lowers the llvm.instrprof.* intrinsics to
// counter updates, value-profiling runtime calls and the __profc_ / __profd_ / __llvm_prf_nm data.
// Ported from llvm/lib/Transforms/Instrumentation/InstrProfiling.cpp (InstrLowerer, PGOCounterPromoter[Helper],
// createProfileSamplingVar). GPU targets (isGPUProfTarget), vtable value profiling and -profile-correlate=binary are
// not ported (they fail loudly).

instrprof_lower_cl: struct {
    profile_correlate := 0;                 // -profile-correlate: 0 none, 1 debug-info, 2 binary
    hash_based_counter_split := true;       // -hash-based-counter-split
    runtime_counter_relocation := false;    // -runtime-counter-relocation
    runtime_counter_relocation_set := false;
    vp_static_alloc := true;                // -vp-static-alloc
    vp_counters_per_site: float64 = 1.0;    // -vp-counters-per-site
    atomic_counter_update_all := false;     // -instrprof-atomic-counter-update-all
    verify_atomic_promotion := false;       // -verify-atomic-counter-promoted
    atomic_counter_update_promoted := false;   // -atomic-counter-update-promoted
    atomic_first_counter := false;          // -atomic-first-counter
    conditional_counter_update := false;    // -conditional-counter-update
    do_counter_promotion := false;          // -do-counter-promotion
    do_counter_promotion_set := false;
    max_promotions_per_loop: s64 = 20;      // -max-counter-promotions-per-loop
    max_promotions: s64 = -1;               // -max-counter-promotions
    speculative_max_exiting: s64 = 3;       // -speculative-counter-promotion-max-exiting
    speculative_to_loop := false;           // -speculative-counter-promotion-to-loop
    iterative_promotion := true;            // -iterative-counter-promotion
    skip_ret_exit_block := true;            // -skip-ret-exit-block
    sampled_instr := false;                 // -sampled-instrumentation
    sampled_instr_set := false;
    sampled_period: s64 = 65536;            // -sampled-instr-period
    sampled_burst: s64 = 200;               // -sampled-instr-burst-duration
};

Ip_Profile_Data :: struct {
    num_value_sites: [IPVK_LAST + 1] u32;
    region_counters: Value_Id = NONE;
    data_var: Value_Id = NONE;
    region_bitmaps: Value_Id = NONE;
    num_bitmap_bytes: u32;
}

Instr_Lowerer :: struct {
    is_cs: bool;
    tt: Triple;
    data_referenced_by_code: bool;
    pd: [..] Ip_Profile_Data;
    pd_index: Table(Value_Id, s64);   // ProfileDataMap: name variable -> pd row
    bias_of: Table(Value_Id, Value_Id);   // FunctionToProfileBiasMap
    compiler_used_vars: [..] Value_Id;
    used_vars: [..] Value_Id;
    referenced_names: [..] Value_Id;
    names_var: Value_Id = NONE;
    names_size: s64;
    profile_data_ty: Type_Id = NONE;
    promotion_candidates: [..] [2] Value_Id;   // (load, store)
    total_promoted: s64;
}

ip_pd :: (il: *Instr_Lowerer, name: Value_Id) -> *Ip_Profile_Data {
    found, idx := table_find(*il.pd_index, name);
    if found return *il.pd[idx];
    array_add(*il.pd, .{});
    table_set(*il.pd_index, name, il.pd.count - 1);
    return *il.pd[il.pd.count - 1];
}

// the intrinsic kinds (InstrProfInstBase subclasses)
Ip_Kind :: enum u8 { NONE; INCREMENT; INCREMENT_STEP; COVER; TIMESTAMP; CALLSITE; VALUE_PROFILE; MCDC_PARAMETERS; MCDC_TVBITMAP_UPDATE; }
ip_kind :: (i: Value_Id) -> Ip_Kind {
    if !is_inst(i) || inst_op(i) != .CALL return .NONE;
    cf := call_called_function(i);
    if cf == NONE || !glob(cf).intrinsic return .NONE;
    n := vname(cf);
    if !begins_with(n, "llvm.instrprof.") return .NONE;
    if n == {
        case "llvm.instrprof.increment"; return .INCREMENT;
        case "llvm.instrprof.increment.step"; return .INCREMENT_STEP;
        case "llvm.instrprof.cover"; return .COVER;
        case "llvm.instrprof.timestamp"; return .TIMESTAMP;
        case "llvm.instrprof.callsite"; return .CALLSITE;
        case "llvm.instrprof.value.profile"; return .VALUE_PROFILE;
        case "llvm.instrprof.mcdc.parameters"; return .MCDC_PARAMETERS;
        case "llvm.instrprof.mcdc.tvbitmap.update"; return .MCDC_TVBITMAP_UPDATE;
    }
    return .NONE;
}
// InstrProfInstBase::getName
ip_name :: (i: Value_Id) -> Value_Id {
    v := strip_pointer_casts(op(i, 0));
    if vkind(v) != .GLOBAL_VAR fatal("instrprof: the name operand of % is not a global variable", vname(call_called_function(i)));
    return v;
}
ip_hash :: (i: Value_Id) -> u64 { return const_int_zext(op(i, 1)); }
ip_num_counters :: (i: Value_Id) -> u64 { return const_int_zext(op(i, 2)); }
ip_index :: (i: Value_Id) -> u64 { return const_int_zext(op(i, 3)); }
// InstrProfIncrementInst::getStep
ip_step :: (i: Value_Id) -> Value_Id {
    if ip_kind(i) == .INCREMENT_STEP return op(i, 4);
    return const_int(ir.t_i64, 1);
}
// InstrProfMCDCBitmapInstBase::getNumBitmapBytes
ip_num_bitmap_bytes :: (i: Value_Id) -> u64 { return (const_int_zext(op(i, 2)) + 7) / 8; }

il_is_gpu :: (il: *Instr_Lowerer) -> bool {
    a := il.tt.arch;
    return a == .amdgpu || a == .r600 || a == .nvptx || a == .nvptx64 || a == .spir || a == .spir64 || a == .spirv || a == .spirv32 || a == .spirv64;
}

// isRuntimeCounterRelocationEnabled
il_runtime_counter_relocation :: (il: *Instr_Lowerer) -> bool {
    if il.tt.obj == .MachO return false;
    if instrprof_lower_cl.runtime_counter_relocation_set return instrprof_lower_cl.runtime_counter_relocation;
    return il.tt.os == .Fuchsia;
}
il_sampling_enabled :: () -> bool {
    if instrprof_lower_cl.sampled_instr_set return instrprof_lower_cl.sampled_instr;
    return false;   // Options.Sampling
}
il_counter_promotion_enabled :: () -> bool {
    if instrprof_lower_cl.do_counter_promotion_set return instrprof_lower_cl.do_counter_promotion;
    return false;   // Options.DoCounterPromotion
}
il_is_atomic :: () -> bool { return instrprof_lower_cl.atomic_counter_update_all; }   // Options.Atomic || ...

Sampled_Config :: struct { burst: u32; period: u32; use_short: bool; simple: bool; fast: bool; }
// getSampledInstrumentationConfig
sampled_config :: () -> Sampled_Config {
    c: Sampled_Config;
    c.burst = cast(u32) instrprof_lower_cl.sampled_burst;
    c.period = cast(u32) instrprof_lower_cl.sampled_period;
    if c.burst > c.period fatal("SampledBurstDuration must be less than or equal to SampledPeriod");
    if c.period == 0 || c.burst == 0 fatal("SampledPeriod and SampledBurstDuration must be greater than 0");
    c.simple = c.burst == 1;
    c.fast = !c.simple && c.period == 65536;
    c.use_short = c.period <= 65535 || c.fast;
    return c;
}

// makeAtomic
il_make_atomic :: (ld: Value_Id, st: Value_Id) {
    addition := op(st, 0);
    assert(is_inst(addition) && inst_op(addition) == .ADD);
    addend := op(addition, 1);
    b: Irb; irb_set_before(*b, ld);
    new_atomicrmw(*b, RMW_ADD, op(st, 1), addend, dl_type_store_size(vtype(addend)), ORD_MONOTONIC, 0);
    erase_inst_with_metadata(st);
    erase_inst_with_metadata(addition);
    erase_inst_with_metadata(ld);
}

// getIntModuleFlagOrZero
il_module_flag_or_zero :: (key: string) -> u64 { ok, v := mu_module_flag_int(key); return ifx ok then v else 0; }

// InstrLowerer::doSampling
il_do_sampling :: (il: *Instr_Lowerer, i: Value_Id) {
    if !il_sampling_enabled() return;
    c := sampled_config();
    get_const :: (c: Sampled_Config, v: u32) -> Value_Id { return const_int(ifx c.use_short then type_int(16) else ir.t_i32, v); }
    ty := ifx c.use_short then type_int(16) else ir.t_i32;
    sv := module_get_global_variable("__llvm_profile_sampling");
    assert(sv != NONE, "SamplingVar not set properly");
    cb: Irb; irb_set_before(*cb, i);
    load := irb_load(*cb, ty, sv, dl_alignment(ty, true));
    incr: Value_Id; new_val: Value_Id;
    if c.simple {
        ib: Irb; irb_set_before(*ib, i);
        new_val = irb_binop(*ib, .ADD, load, get_const(c, 1));
        incr = irb_store(*ib, new_val, sv, dl_alignment(ty, true));
    } else {
        cond := irb_icmp(*cb, ICMP_ULE, load, get_const(c, c.burst - 1));
        w := md_branch_weights(.[c.burst, c.period - c.burst], false);
        then_term := mu_split_block_and_insert_if_then(cond, i, false, w);
        ib: Irb; irb_set_before(*ib, i);
        new_val = irb_binop(*ib, .ADD, load, get_const(c, 1));
        incr = irb_store(*ib, new_val, sv, dl_alignment(ty, true));
        inst_move_before_dbg(i, then_term);
    }
    if c.fast return;
    pb: Irb; irb_set_before(*pb, incr);
    pc := irb_icmp(*pb, ICMP_UGE, new_val, get_const(c, c.period));
    w := md_branch_weights(.[1, c.period - 1], false);
    then_term, else_term := mu_split_block_and_insert_if_then_else(pc, incr, true, true, false, false, w);
    if c.simple inst_move_before_dbg(i, then_term);
    rb: Irb; irb_set_before(*rb, then_term);
    irb_store(*rb, get_const(c, 0), sv, dl_alignment(ty, true));
    inst_move_before_dbg(incr, else_term);
}

// InstrLowerer::lowerIntrinsics
il_lower_intrinsics :: (il: *Instr_Lowerer, f: Value_Id) -> bool {
    made_change := false;
    il.promotion_candidates.count = 0;
    insts: [..] Value_Id; insts.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) if ip_kind(i) != .NONE array_add(*insts, i);
    for i: insts {
        k := ip_kind(i);
        il_do_sampling(il, i);
        if k == {
            case .INCREMENT_STEP; #through;
            case .INCREMENT; il_lower_increment(il, i); made_change = true;
            case .TIMESTAMP; il_lower_timestamp(il, i); made_change = true;
            case .COVER; il_lower_cover(il, i); made_change = true;
            case .VALUE_PROFILE; il_lower_value_profile(il, i); made_change = true;
            case .MCDC_PARAMETERS; erase_inst_with_metadata(i); made_change = true;
            case .MCDC_TVBITMAP_UPDATE; il_lower_mcdc_tvbitmap_update(il, i); made_change = true;
        }
    }
    if !made_change return false;
    il_promote_counter_load_stores(il, f);
    return true;
}

// doAtomicCheck
il_do_atomic_check :: (f: Value_Id) {
    for b: fn_blocks(f) for i: block_insts(b) {
        addr: Value_Id = NONE;
        if inst_op(i) == .LOAD addr = op(i, 0);
        else if inst_op(i) == .STORE addr = op(i, 1);
        if addr != NONE && begins_with(vname(strip_in_bounds_offsets(addr)), "__profc_") fatal("Candidate load/store not converted to atomic");
    }
}

// ---------------------------------------------------------------- counter promotion (PGOCounterPromoter)

Ip_Promoter :: struct {
    il: *Instr_Lowerer;
    li: *Loop_Info;
    loop_cands: *Table(Loop_Id, [..] [2] Value_Id);
    l: Loop_Id;
    exit_blocks: [..] Value_Id;
    insert_pts: [..] Value_Id;
    is_atomic: bool;
}

ip_loop_cands :: (p: *Ip_Promoter, l: Loop_Id) -> *[..] [2] Value_Id {
    c := table_find_pointer(p.loop_cands, l);
    if c return c;
    e: [..] [2] Value_Id; e.allocator = temp;
    return table_add(p.loop_cands, l, e);
}

IID_CORO_SUSPEND_IP :: #run iid_by_name("llvm.coro.suspend");
// isPresplitCoroSuspendExitEdge(Src, Dest)
is_presplit_coro_suspend_exit_edge :: (src: Value_Id, dest: Value_Id) -> bool {
    f := block_fn(src);
    if !fn_has_fn_attr(f, .PresplitCoroutine) return false;
    sw := block_terminator(src);
    if sw == NONE || inst_op(sw) != .SWITCH return false;
    sus := sw_cond(sw);
    if !is_inst(sus) || call_iid(sus) != IID_CORO_SUSPEND_IP return false;
    // !SI->getDefaultDest()->... : the default destination is the suspend exit
    return sw_default(sw) == dest;
}

// isPromotionPossible
ip_is_promotion_possible :: (p: *Ip_Promoter, l: Loop_Id, exits: [] Value_Id) -> bool {
    for exits { t := block_terminator(it); if t != NONE && inst_op(t) == .CATCHSWITCH return false; }
    if !li_has_dedicated_exits(p.li, l) return false;
    if li_loop_preheader(p.li, l) == NONE return false;
    return true;
}

// getMaxNumOfPromotionsInLoop
ip_max_promotions_in_loop :: (p: *Ip_Promoter, l: Loop_Id) -> u32 {
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(p.li, l, *exits);
    if !ip_is_promotion_possible(p, l, exits) return 0;
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(p.li, l, *exiting);
    // BFI is never set: Options.UseBFIInPromotion is false for the `instrprof` pass
    if exiting.count == 1 return cast(u32) instrprof_lower_cl.max_promotions_per_loop;
    if exiting.count > instrprof_lower_cl.speculative_max_exiting return 0;
    if instrprof_lower_cl.speculative_to_loop return cast(u32) instrprof_lower_cl.max_promotions_per_loop;
    max_prom := cast(u32) instrprof_lower_cl.max_promotions_per_loop;
    for target: exits {
        tl := li_loop_for(p.li, target);
        if tl == NONE continue;
        for_target := ip_max_promotions_in_loop(p, tl);
        pending := cast(u32) ip_loop_cands(p, tl).count;
        max_prom = min(max_prom, max(for_target, pending) - pending);
    }
    return max_prom;
}

ip_promoter_init :: (p: *Ip_Promoter) {
    p.exit_blocks.allocator = temp; p.insert_pts.allocator = temp;
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(p.li, p.l, *exits);
    if !ip_is_promotion_possible(p, p.l, exits) return;
    seen: [..] Value_Id; seen.allocator = temp;
    for eb: exits {
        if array_find(seen, eb) continue;
        array_add(*seen, eb);
        coro := false;
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(eb, *preds);
        for preds if is_presplit_coro_suspend_exit_edge(it, eb) { coro = true; break; }
        if coro continue;
        array_add(*p.exit_blocks, eb);
        array_add(*p.insert_pts, block_first_insertion_pt(eb));
    }
}

// PGOCounterPromoterHelper::doExtraRewritesBeforeFinalDeletion
ip_helper_extra_rewrites :: (p: *Ip_Promoter, ssa: *Ssa_Updater, store: Value_Id) {
    for eb, k: p.exit_blocks {
        pos := p.insert_pts[k];
        live_in := ssa_value_in_middle(ssa, eb);
        addr := op(store, 1);
        ty := vtype(live_in);
        b: Irb; irb_set_before(*b, pos);
        if is_inst(addr) && inst_op(addr) == .INTTOPTR {
            orig_bias := op(addr, 0);
            assert(is_inst(orig_bias) && inst_op(orig_bias) == .ADD);
            bias := irb_insert(*b, inst_clone(orig_bias));
            addr = irb_cast(*b, .INTTOPTR, bias, type_ptr(0));
        }
        target_loop := ifx instrprof_lower_cl.iterative_promotion then li_loop_for(p.li, eb) else NONE;
        if (p.is_atomic && target_loop == NONE) || instrprof_lower_cl.atomic_counter_update_promoted {
            new_atomicrmw(*b, RMW_ADD, addr, live_in, dl_type_store_size(ty), ORD_MONOTONIC, 0);
        } else {
            old := irb_load(*b, ty, addr, dl_alignment(ty, true), false, "pgocount.promoted");
            nv := irb_binop(*b, .ADD, old, live_in);
            ns := irb_store(*b, nv, addr, dl_alignment(ty, true));
            if target_loop != NONE array_add(ip_loop_cands(p, target_loop), .[old, ns]);
        }
    }
}

// promoteCandidates
ip_promote_candidates :: (p: *Ip_Promoter) -> bool {
    if p.exit_blocks.count == 0 return false;
    if instrprof_lower_cl.skip_ret_exit_block {
        for p.exit_blocks { t := block_terminator(it); if t != NONE && inst_op(t) == .RET return false; }
    }
    max_prom := ip_max_promotions_in_loop(p, p.l);
    if max_prom == 0 return false;
    promoted: u32 = 0;
    // LoopToCandidates[&L] may grow while promoting (exit blocks inside L itself are impossible): iterate by index
    k := 0;
    while k < ip_loop_cands(p, p.l).count {
        defer k += 1;
        cand := ip_loop_cands(p, p.l).*[k];
        ld := cand[0]; st := cand[1];
        if ld == NONE continue;
        ssa: Ssa_Updater;
        ssa_init(*ssa, vtype(ld), vname(ld));
        ssa_add_available(*ssa, li_loop_preheader(p.li, p.l), const_int(vtype(ld), 0));
        hooks: Lsp_Hooks; hooks.kind = .INSTRPROF; hooks.instrprof = p; hooks.instrprof_store = st;
        load_and_store_promote(.[ld, st], *ssa, NONE, hooks);
        ip_loop_cands(p, p.l).*[k] = .[NONE, NONE];
        promoted += 1;
        if promoted >= max_prom break;
        p.il.total_promoted += 1;
        if instrprof_lower_cl.max_promotions != -1 && p.il.total_promoted >= instrprof_lower_cl.max_promotions break;
    }
    return promoted != 0;
}

// InstrLowerer::promoteCounterLoadStores
il_promote_counter_load_stores :: (il: *Instr_Lowerer, f: Value_Id) {
    if !il_counter_promotion_enabled() return;
    dt := dt_new(false);
    dt_recalculate(dt, f);
    li := li_new(f);
    li_analyze(li, dt);
    loop_cands: Table(Loop_Id, [..] [2] Value_Id); loop_cands.allocator = temp;
    for c: il.promotion_candidates {
        parent := li_loop_for(li, inst(c[0]).parent);
        if parent == NONE {
            if il_is_atomic() il_make_atomic(c[0], c[1]);
            continue;
        }
        l := table_find_pointer(*loop_cands, parent);
        if !l { e: [..] [2] Value_Id; e.allocator = temp; l = table_add(*loop_cands, parent, e); }
        array_add(l, c);
    }
    loops: [..] Loop_Id; loops.allocator = temp;
    li_loops_in_preorder(li, *loops);
    for < l: loops {
        p: Ip_Promoter;
        p.il = il; p.li = li; p.loop_cands = *loop_cands; p.l = l; p.is_atomic = il_is_atomic();
        ip_promoter_init(*p);
        ip_promote_candidates(*p);
        if p.is_atomic {
            for c: ip_loop_cands(*p, l).* if c[0] != NONE && c[1] != NONE il_make_atomic(c[0], c[1]);
        }
    }
    if il_is_atomic() && instrprof_lower_cl.verify_atomic_promotion il_do_atomic_check(f);
}

// ---------------------------------------------------------------- lowering of the intrinsics

// containsProfilingIntrinsics
il_contains_profiling_intrinsics :: () -> bool {
    for string.["llvm.instrprof.cover", "llvm.instrprof.increment", "llvm.instrprof.increment.step",
                "llvm.instrprof.timestamp", "llvm.instrprof.value.profile"] {
        f := module_get_function(it);
        if f != NONE && has_uses(f) return true;
    }
    return false;
}

// getOrInsertValueProfilingCall
il_value_profiling_call :: (memop: bool) -> Value_Id {
    attrs: u32 = 0;
    ak := tli_ext_attr_for_i32_param(false);
    ft := type_func(ir.t_void, .[ir.t_i64, type_ptr(0), ir.t_i32], false);
    name := ifx memop then "__llvm_profile_instrument_memop" else "__llvm_profile_instrument_target";
    f := lookup_global(name);
    if f != NONE return f;
    f = module_get_or_insert_function(name, ft);
    if ak != .NONE_ATTR fn_add_param_attr(f, 2, attr_enum(ak));
    return f;
}

// computeNumValueSiteCounts
il_compute_num_value_site_counts :: (il: *Instr_Lowerer, ind: Value_Id) {
    kind := const_int_zext(op(ind, 3));
    index := const_int_zext(op(ind, 4));
    pd := ip_pd(il, ip_name(ind));
    pd.num_value_sites[kind] = max(pd.num_value_sites[kind], cast(u32) (index + 1));
}

// lowerValueProfileInst
il_lower_value_profile :: (il: *Instr_Lowerer, ind: Value_Id) {
    found, idx := table_find(*il.pd_index, ip_name(ind));
    assert(found && il.pd[idx].data_var != NONE, "value profiling detected in function with no counter increment");
    data_var := il.pd[idx].data_var;
    kind := const_int_zext(op(ind, 3));
    index := const_int_zext(op(ind, 4));
    for k: 0..cast(s64) kind - 1 index += il.pd[idx].num_value_sites[k];
    b: Irb; irb_set_before(*b, ind);
    is_memop := kind == IPVK_MEMOP_SIZE;
    data_ptr := ce_pointer_bitcast_or_addrspacecast(data_var, type_ptr(0));
    callee := il_value_profiling_call(is_memop);
    args := Value_Id.[op(ind, 2), data_ptr, const_int(ir.t_i32, index)];
    c: Value_Id;
    if call_num_bundles(ind) > 0 c = irb_call_with_bundles_of(*b, callee, args, ind);
    else c = irb_call(*b, callee, args);
    ak := tli_ext_attr_for_i32_param(false);
    if ak != .NONE_ATTR call_add_param_attr_kind(c, 2, ak);
    rauw_with_metadata(ind, c);
    erase_inst_with_metadata(ind);
}

// getOrCreateBiasVar
il_get_or_create_bias_var :: (il: *Instr_Lowerer, name: string) -> Value_Id {
    b := module_get_global_variable(name);
    if b != NONE return b;
    b = gv_create(ir.t_i64, false, .LINKONCE_ODR, const_null_value(ir.t_i64), name, NONE, 0, dl.globals_as);
    gv_set_visibility(b, 1);
    if triple_supports_comdat() glob(b).comdat = get_comdat(name);
    return b;
}

// getCounterAddress
il_counter_address :: (il: *Instr_Lowerer, i: Value_Id) -> Value_Id {
    counters := il_get_or_create_region_counters(il, i);
    b: Irb; irb_set_before(*b, i);
    if ip_kind(i) == .TIMESTAMP glob(counters).align = 8;
    addr := irb_gep(*b, glob(counters).value_type, counters, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, ip_index(i))], "", F_INBOUNDS);
    if !il_runtime_counter_relocation(il) return addr;
    f := block_fn(inst(i).parent);
    found, bias_li := table_find(*il.bias_of, f);
    if !found {
        eb: Irb; irb_set_before(*eb, block_first(fn_entry(f)));
        bias := il_get_or_create_bias_var(il, "__llvm_profile_counter_bias");
        bias_li = irb_load(*eb, ir.t_i64, bias, dl_alignment(ir.t_i64, true), false, "profc_bias");
        set_metadata(bias_li, MDK_INVARIANT_LOAD, md_tuple(.[], false));
        table_set(*il.bias_of, f, bias_li);
    }
    add := irb_binop(*b, .ADD, irb_cast(*b, .PTRTOINT, addr, ir.t_i64), bias_li);
    return irb_cast(*b, .INTTOPTR, add, vtype(addr));
}

// getBitmapAddress
il_bitmap_address :: (il: *Instr_Lowerer, i: Value_Id) -> Value_Id {
    bitmaps := il_get_or_create_region_bitmaps(il, i);
    if !il_runtime_counter_relocation(il) return bitmaps;
    f := block_fn(inst(i).parent);
    eb: Irb; irb_set_before(*eb, block_first(fn_entry(f)));
    bias := il_get_or_create_bias_var(il, "__llvm_profile_bitmap_bias");
    bias_li := irb_load(*eb, ir.t_i64, bias, dl_alignment(ir.t_i64, true), false, "profbm_bias");
    set_metadata(bias_li, MDK_INVARIANT_LOAD, md_tuple(.[], false));
    b: Irb; irb_set_before(*b, i);
    return irb_gep(*b, ir.t_i8, bitmaps, .[bias_li], "profbm_addr");   // CreatePtrAdd
}

// lowerCover
il_lower_cover :: (il: *Instr_Lowerer, ci: Value_Id) {
    addr := il_counter_address(il, ci);
    b: Irb; irb_set_before(*b, ci);
    if instrprof_lower_cl.conditional_counter_update {
        split_before := inst(ci).next;
        ld := irb_load(*b, ir.t_i8, addr, 1, false, "pgocount");
        cmp := irb_icmp(*b, ICMP_NE, ld, const_null_value(ir.t_i8), "pgocount.ifnonzero");
        then_br := mu_split_block_and_insert_if_then(cmp, split_before, false);
        irb_set_before(*b, then_br);
    }
    irb_store(*b, const_int(ir.t_i8, 0), addr, 1);
    erase_inst_with_metadata(ci);
}

// lowerTimestamp
il_lower_timestamp :: (il: *Instr_Lowerer, ti: Value_Id) {
    addr := il_counter_address(il, ti);
    b: Irb; irb_set_before(*b, ti);
    callee := module_get_or_insert_function("__llvm_profile_set_timestamp", type_func(ir.t_void, .[vtype(addr)], false));
    irb_call(*b, callee, .[addr]);
    erase_inst_with_metadata(ti);
}

// lowerIncrement
il_lower_increment :: (il: *Instr_Lowerer, inc: Value_Id) {
    if il_is_gpu(il) fatal("instrprof: GPU profile targets are not supported");
    b: Irb; irb_set_before(*b, inc);
    addr := il_counter_address(il, inc);
    step := ip_step(inc);
    if (!il_counter_promotion_enabled() && il_is_atomic()) || (ip_index(inc) == 0 && instrprof_lower_cl.atomic_first_counter) {
        new_atomicrmw(*b, RMW_ADD, addr, step, dl_type_store_size(vtype(step)), ORD_MONOTONIC, 0);
    } else {
        ld := irb_load(*b, vtype(step), addr, dl_alignment(vtype(step), true), false, "pgocount");
        cnt := irb_binop(*b, .ADD, ld, ip_step(inc));
        st := irb_store(*b, cnt, addr, dl_alignment(vtype(cnt), true));
        if il_counter_promotion_enabled() array_add(*il.promotion_candidates, .[ld, st]);
    }
    erase_inst_with_metadata(inc);
}

// lowerCoverageData
il_lower_coverage_data :: (il: *Instr_Lowerer, cov: Value_Id) {
    names := gv_initializer(cov);
    if vkind(names) != .C_ARRAY fatal("instrprof: __llvm_coverage_names is not a ConstantArray");
    for k: 0..nops(names)-1 {
        nc := op(names, k);
        v := strip_pointer_casts(nc);
        assert(vkind(v) == .GLOBAL_VAR, "Missing reference to function name");
        gv_set_linkage(v, .PRIVATE);
        array_add(*il.referenced_names, v);
    }
    gv_erase_from_parent(cov);
}

// lowerMCDCTestVectorBitmapUpdate
il_lower_mcdc_tvbitmap_update :: (il: *Instr_Lowerer, u: Value_Id) {
    b: Irb; irb_set_before(*b, u);
    cond_addr := op(u, 3);
    bitmap_addr := il_bitmap_address(il, u);
    temp_ld := irb_load(*b, ir.t_i32, cond_addr, 4, false, "mcdc.temp");
    temp := irb_binop(*b, .ADD, temp_ld, op(u, 2));
    byte_off := irb_binop(*b, .LSHR, temp, const_int(ir.t_i32, 3));
    byte_addr := irb_gep(*b, ir.t_i8, bitmap_addr, .[byte_off], "", F_INBOUNDS);   // CreateInBoundsPtrAdd
    bit := irb_cast(*b, .TRUNC, irb_binop(*b, .AND, temp, const_int(ir.t_i32, 7)), ir.t_i8);
    shifted := irb_binop(*b, .SHL, const_int(ir.t_i8, 1), bit);
    bits := irb_load(*b, ir.t_i8, byte_addr, 1, false, "mcdc.bits");
    if il_is_atomic() {
        masked := irb_binop(*b, .AND, bits, shifted);
        should := irb_icmp(*b, ICMP_NE, masked, shifted);
        then_br := mu_split_block_and_insert_if_then(should, u, false, md_branch_weights(.[1, (1 << 20) - 1], false));
        irb_set_before(*b, then_br);
        new_atomicrmw(*b, RMW_OR, byte_addr, shifted, 1, ORD_MONOTONIC, 0);
    } else {
        r := irb_binop(*b, .OR, bits, shifted);
        irb_store(*b, r, byte_addr, 1);
    }
    erase_inst_with_metadata(u);
}

// getVarName(Inc, Prefix, Renamed)
il_var_name :: (inc: Value_Id, prefix: string) -> (string, bool) {
    full := vname(ip_name(inc));
    name := slice(full, INSTR_PROF_NAME_VAR_PREFIX.count, full.count - INSTR_PROF_NAME_VAR_PREFIX.count);
    f := block_fn(inst(inc).parent);
    if !instrprof_lower_cl.hash_based_counter_split || !is_irpgo_flag_set() || !can_rename_comdat_func(f) return tconcat(prefix, name), false;
    h := ip_hash(inc);
    if ends_with(name, tprint(".%", h)) return tconcat(prefix, name), true;
    return tprint("%1%2.%3", prefix, name, h), true;
}

// shouldRecordFunctionAddr
il_should_record_function_addr :: (f: Value_Id) -> bool {
    if !il_prof_data_referenced_by_code() return false;
    l := glob(f).linkage;
    is_linkonce := l == .LINKONCE_ANY || l == .LINKONCE_ODR;
    avail := l == .AVAILABLE_EXTERNALLY;
    if !is_linkonce && !is_local_linkage(l) && !avail return true;
    if avail && fn_has_fn_attr(f, .AlwaysInline) return false;
    if is_local_linkage(l) && glob(f).comdat >= 0 return false;
    return fn_has_address_taken(f) || is_linkonce;
}
// enablesValueProfiling / profDataReferencedByCode
il_prof_data_referenced_by_code :: () -> bool { return is_irpgo_flag_set() || il_module_flag_or_zero("EnableValueProfiling") != 0; }

// shouldUsePublicSymbol
il_should_use_public_symbol :: (f: Value_Id) -> bool {
    if gv_is_declaration_for_linker(f) return true;
    if gv_has_local_linkage(f) return true;
    if get_metadata(f, md_fixed("type")) != NONE return true;
    if glob(f).comdat >= 0 && glob(f).visibility == 1 return true;
    return false;
}

// getFuncAddrForProfData
il_func_addr_for_prof_data :: (il: *Instr_Lowerer, f: Value_Id) -> Value_Id {
    if !il_should_record_function_addr(f) return const_null_value(type_ptr(0));
    if il_should_use_public_symbol(f) return f;
    // GlobalAlias::create(PrivateLinkage, Fn->getName() + ".local", Fn)
    vt := glob(f).value_type; as := glob(f).addrspace;
    ga := new_global(.ALIAS, vt, as, 1);
    gv_set_linkage(ga, .PRIVATE);
    set_op(ga, 0, f);
    array_add(*ir.m_aliases, ga);
    set_name(ga, tconcat(vname(f), ".local"));
    if glob(f).comdat >= 0 {
        gv_set_linkage(ga, glob(f).linkage);
        gv_set_visibility(ga, 1);
    }
    return ga;
}

// needsRuntimeRegistrationOfSectionRange
il_needs_runtime_registration :: (il: *Instr_Lowerer) -> bool {
    if il.tt.arch == .nvptx || il.tt.arch == .nvptx64 return true;
    o := il.tt.obj;
    if o == .ELF || o == .COFF || o == .MachO || o == .XCOFF || o == .Wasm return false;
    return true;
}

// maybeSetComdat
il_maybe_set_comdat :: (il: *Instr_Lowerer, gv: Value_Id, go: Value_Id, group: string) {
    need := needs_comdat_for_counter(go);
    use := need || il.tt.obj == .ELF;
    if !use return;
    gname := ifx il.tt.obj == .COFF && il.data_referenced_by_code then vname(gv) else group;
    c := get_comdat(gname);
    if !need ir.comdats[c].kind = 3;   // Comdat::NoDeduplicate
    glob(gv).comdat = c;
    if il.tt.obj == .COFF && glob(gv).linkage == .PRIVATE gv_set_linkage(gv, .INTERNAL);
}

// setupProfileSection
il_setup_profile_section :: (il: *Instr_Lowerer, inc: Value_Id, k: Ipsk) -> Value_Id {
    name_ptr := ip_name(inc);
    f := block_fn(inst(inc).parent);
    linkage := glob(name_ptr).linkage;
    vis := glob(name_ptr).visibility;
    if instrprof_lower_cl.profile_correlate == 1 && il.tt.obj == .MachO && linkage == .PRIVATE linkage = .INTERNAL;
    if il.tt.obj == .XCOFF { linkage = .PRIVATE; vis = 0; }
    var_name: string;
    ptr: Value_Id;
    if k == .CNTS {
        var_name = il_var_name(inc, "__profc_");
        ptr = il_create_region_counters(inc, var_name, linkage);
    } else {
        var_name = il_var_name(inc, "__profbm_");
        ptr = il_create_region_bitmaps(inc, var_name, linkage);
    }
    gv_set_visibility(ptr, vis);
    glob(ptr).section = instrprof_section_name(k, il.tt.obj);
    gv_set_linkage(ptr, linkage);
    il_maybe_set_comdat(il, ptr, f, var_name);
    return ptr;
}

// createRegionBitmaps
il_create_region_bitmaps :: (inc: Value_Id, name: string, linkage: Linkage) -> Value_Id {
    ty := type_array(ip_num_bitmap_bytes(inc), ir.t_i8);
    gv := gv_create(ty, false, linkage, const_null_value(ty), name, NONE, 0, dl.globals_as);
    glob(gv).align = 1;
    return gv;
}

// getOrCreateRegionBitmaps
il_get_or_create_region_bitmaps :: (il: *Instr_Lowerer, inc: Value_Id) -> Value_Id {
    name_ptr := ip_name(inc);
    pd := ip_pd(il, name_ptr);
    if pd.region_bitmaps != NONE return pd.region_bitmaps;
    bp := il_setup_profile_section(il, inc, .BITMAP);
    pd = ip_pd(il, name_ptr);
    pd.region_bitmaps = bp;
    pd.num_bitmap_bytes = cast(u32) ip_num_bitmap_bytes(inc);
    if pd.num_bitmap_bytes && instrprof_lower_cl.profile_correlate == 1 {
        f := block_fn(inst(inc).parent);
        sp := fn_subprogram(f);
        if sp != NONE {
            annots := Md_Id.[
                md_tuple(.[md_string("Function Name"), md_string(pgo_func_name_var_initializer(name_ptr))], false),
                md_tuple(.[md_string("Num Bitmap Bits"), md_value(op(inc, 2))], false)];
            il_add_correlation_debug_info(bp, sp, "Profile Bitmap Type", annots);
        }
        array_add(*il.compiler_used_vars, bp);
    }
    return bp;
}

// The DIBuilder part of getOrCreateRegionCounters / getOrCreateRegionBitmaps with -profile-correlate=debug-info:
// a local DIGlobalVariable (createGlobalVariableExpression in the subprogram's scope, with the annotations),
// attached to the variable and added to the subprogram's retainedNodes (finalizeSubprogram).
il_add_correlation_debug_info :: (gv: Value_Id, sp: Md_Id, type_name: string, annots: [] Md_Id) {
    DW_TAG_UNSPECIFIED_TYPE :: 0x3b;
    ty := di_get(.BASIC_TYPE, false, .[NONE, NONE, md_string(type_name), NONE, NONE], .[DW_TAG_UNSPECIFIED_TYPE, 0, 0, 0, 0, 0, 0]);
    name := md_str_or_null(vname(gv));
    file := di_op(sp, 0);
    is_local: u64 = ifx gv_has_local_linkage(gv) then cast(u64) 1 else 0;
    dgv := di_get(.GLOBAL_VARIABLE, true, .[sp, name, file, ty, name, NONE, NONE, NONE, md_tuple(annots, false)], .[0, is_local, 1, 0]);
    expr := di_get(.EXPRESSION, false, .[], .[]);
    gve := di_get(.GLOBAL_VARIABLE_EXPRESSION, false, .[dgv, expr], .[]);
    gv_add_debug_info(gv, gve);
    // finalizeSubprogram: the old retained nodes, then the tracked ones (a SetVector)
    retained: [..] Md_Id; retained.allocator = temp;
    old := di_op(sp, 7);
    if old != NONE for k: 0..cast(s64) md_nops(old)-1 { n := md_op(old, cast(u32) k); if !array_find(retained, n) array_add(*retained, n); }
    if !array_find(retained, gve) array_add(*retained, gve);
    retained_t := md_tuple(retained, false);   // md_tuple can grow ir.md_ops: build it before indexing
    ir.md_ops[ir.mds[sp].ops + 7] = retained_t;
}

// createRegionCounters
il_create_region_counters :: (inc: Value_Id, name: string, linkage: Linkage) -> Value_Id {
    n := ip_num_counters(inc);
    gv: Value_Id;
    if ip_kind(inc) == .COVER {
        ty := type_array(n, ir.t_i8);
        elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for * elts it.* = const_int(ir.t_i8, 0xFF);
        gv = gv_create(ty, false, linkage, const_aggregate(.C_ARRAY, ty, elts), name, NONE, 0, dl.globals_as);
        glob(gv).align = 1;
    } else {
        ty := type_array(n, ir.t_i64);
        gv = gv_create(ty, false, linkage, const_null_value(ty), name, NONE, 0, dl.globals_as);
        glob(gv).align = 8;
    }
    return gv;
}

// getOrCreateRegionCounters
il_get_or_create_region_counters :: (il: *Instr_Lowerer, inc: Value_Id) -> Value_Id {
    name_ptr := ip_name(inc);
    pd := ip_pd(il, name_ptr);
    if pd.region_counters != NONE return pd.region_counters;
    cp := il_setup_profile_section(il, inc, .CNTS);
    pd = ip_pd(il, name_ptr);
    pd.region_counters = cp;
    if instrprof_lower_cl.profile_correlate == 1 {
        f := block_fn(inst(inc).parent);
        sp := fn_subprogram(f);
        if sp != NONE {
            annots := Md_Id.[
                md_tuple(.[md_string("Function Name"), md_string(pgo_func_name_var_initializer(name_ptr))], false),
                md_tuple(.[md_string("CFG Hash"), md_value(op(inc, 1))], false),
                md_tuple(.[md_string("Num Counters"), md_value(op(inc, 2))], false)];
            il_add_correlation_debug_info(cp, sp, "Profile Data Type", annots);
        }
        array_add(*il.compiler_used_vars, cp);
    }
    // getOrCreateUniformCounters: GPU only
    il_create_data_variable(il, inc);
    return cp;
}

// getProfileDataTy
il_profile_data_ty :: (il: *Instr_Lowerer) -> Type_Id {
    if il.profile_data_ty != NONE return il.profile_data_ty;
    intptr := type_int(dl_ptr_spec(0).bits);
    i16a := type_array(IPVK_LAST + 1, type_int(16));
    il.profile_data_ty = type_literal_struct(.[ir.t_i64, ir.t_i64, intptr, intptr, intptr, type_ptr(0), type_ptr(0), ir.t_i32, i16a, type_int(16), ir.t_i32], false);
    return il.profile_data_ty;
}

// createDataVariable
il_create_data_variable :: (il: *Instr_Lowerer, inc: Value_Id) {
    if instrprof_lower_cl.profile_correlate == 1 return;
    name_ptr := ip_name(inc);
    pd := ip_pd(il, name_ptr);
    if pd.data_var != NONE return;
    f := block_fn(inst(inc).parent);
    linkage := glob(name_ptr).linkage;
    vis := glob(name_ptr).visibility;
    if il.tt.obj == .XCOFF { linkage = .PRIVATE; vis = 0; }
    need_comdat := needs_comdat_for_counter(f);
    cnts_name, _ := il_var_name(inc, "__profc_");
    data_name, renamed := il_var_name(inc, "__profd_");
    values_ptr := const_null_value(type_ptr(0));
    ns: u64 = 0;
    for pd.num_value_sites ns += it;
    if ns > 0 && instrprof_lower_cl.vp_static_alloc && !il_needs_runtime_registration(il) {
        vty := type_array(ns, ir.t_i64);
        vname_, _ := il_var_name(inc, "__profvp_");
        vv := gv_create(vty, false, linkage, const_null_value(vty), vname_, NONE, 0, dl.globals_as);
        gv_set_visibility(vv, vis);
        set_global_variable_large_section(vv);
        glob(vv).section = instrprof_section_name(.VALS, il.tt.obj);
        glob(vv).align = 8;
        il_maybe_set_comdat(il, vv, f, cnts_name);
        values_ptr = ce_pointer_bitcast_or_addrspacecast(vv, type_ptr(0));
    }
    pd = ip_pd(il, name_ptr);
    num_counters := ip_num_counters(inc);
    counter_ptr := pd.region_counters;
    num_bitmap_bytes := pd.num_bitmap_bytes;
    intptr := type_int(dl_ptr_spec(0).bits);
    i16 := type_int(16);
    i16a := type_array(IPVK_LAST + 1, i16);
    data_ty := il_profile_data_ty(il);
    func_addr := il_func_addr_for_prof_data(il, f);
    pd = ip_pd(il, name_ptr);
    i16vals: [IPVK_LAST + 1] Value_Id;
    for k: 0..IPVK_LAST i16vals[k] = const_int(i16, pd.num_value_sites[k]);
    if il_is_gpu(il) fatal("instrprof: GPU profile targets are not supported");
    if ns == 0 && !(il.data_referenced_by_code && need_comdat && !renamed) && (il.tt.obj == .ELF || (!il.data_referenced_by_code && il.tt.obj == .COFF)) {
        linkage = .PRIVATE; vis = 0;
    }
    data := gv_create(data_ty, false, linkage, NONE, data_name, NONE, 0, dl.globals_as);
    rel_counter: Value_Id;
    bitmap_ptr := pd.region_bitmaps;
    rel_bitmap := const_int(intptr, 0);
    rel_uniform := const_int(intptr, 0);
    if instrprof_lower_cl.profile_correlate == 2 fatal("instrprof: -profile-correlate=binary is not supported");
    if il.tt.arch == .nvptx || il.tt.arch == .nvptx64 fatal("instrprof: NVPTX is not supported");
    rel_counter = ce_binop(.SUB, ce_cast(.PTRTOINT, counter_ptr, intptr), ce_cast(.PTRTOINT, data, intptr), 0);
    if bitmap_ptr != NONE rel_bitmap = ce_binop(.SUB, ce_cast(.PTRTOINT, bitmap_ptr, intptr), ce_cast(.PTRTOINT, data, intptr), 0);
    name_ref := md5_hash_u64(pgo_func_name_var_initializer(name_ptr));
    vals := Value_Id.[
        const_int(ir.t_i64, name_ref),
        const_int(ir.t_i64, ip_hash(inc)),
        rel_counter,
        rel_uniform,
        rel_bitmap,
        func_addr,
        values_ptr,
        const_int(ir.t_i32, num_counters),
        const_aggregate(.C_ARRAY, i16a, i16vals),
        const_int(i16, 0),
        const_int(ir.t_i32, num_bitmap_bytes)];
    gv_set_initializer(data, const_aggregate(.C_STRUCT, data_ty, vals));
    gv_set_visibility(data, vis);
    glob(data).section = instrprof_section_name(.DATA, il.tt.obj);
    glob(data).align = 8;
    il_maybe_set_comdat(il, data, f, cnts_name);
    pd = ip_pd(il, name_ptr);
    pd.data_var = data;
    array_add(*il.compiler_used_vars, data);
    gv_set_linkage(name_ptr, .PRIVATE);
    array_add(*il.referenced_names, name_ptr);
}

// emitVNodes
il_emit_vnodes :: (il: *Instr_Lowerer) {
    if !instrprof_lower_cl.vp_static_alloc return;
    if il_needs_runtime_registration(il) return;
    total: u64 = 0;
    for il.pd for k: it.num_value_sites total += k;
    if !total return;
    n := cast(u64) (cast(float64) total * instrprof_lower_cl.vp_counters_per_site);
    if n < 10 n = cast(u64) max(10, cast(s64) (cast(s32) n) * 2);
    node_ty := type_literal_struct(.[ir.t_i64, ir.t_i64, type_ptr(0)], false);
    nodes_ty := type_array(n, node_ty);
    v := gv_create(nodes_ty, false, .PRIVATE, const_null_value(nodes_ty), "__llvm_prf_vnodes", NONE, 0, dl.globals_as);
    set_global_variable_large_section(v);
    glob(v).section = instrprof_section_name(.VNODES, il.tt.obj);
    glob(v).align = dl_alignment(nodes_ty, true);
    array_add(*il.used_vars, v);
}

// emitNameData
il_emit_name_data :: (il: *Instr_Lowerer) {
    if il.referenced_names.count == 0 return;
    names: [..] string; names.allocator = temp;
    for il.referenced_names array_add(*names, pgo_func_name_var_initializer(it));
    s := collect_global_object_name_strings(names, instrprof_cl.do_name_compression);
    val := c_string_const(s, false);
    il.names_var = gv_create(vtype(val), true, .PRIVATE, val, "__llvm_prf_nm", NONE, 0, dl.globals_as);
    il.names_size = s.count;
    set_global_variable_large_section(il.names_var);
    glob(il.names_var).section = instrprof_section_name(ifx instrprof_lower_cl.profile_correlate == 2 then Ipsk.COVNAME else .NAME, il.tt.obj);
    glob(il.names_var).align = 1;
    array_add(*il.used_vars, il.names_var);
    for il.referenced_names gv_erase_from_parent(it);
}

// emitRegistration
il_emit_registration :: (il: *Instr_Lowerer) {
    if !il_needs_runtime_registration(il) return;
    reg_f := new_function(type_func(ir.t_void, .[], false), "", dl.program_as);
    array_add(*ir.m_functions, reg_f);
    gv_set_linkage(reg_f, .INTERNAL);
    set_name(reg_f, "__llvm_profile_register_functions");
    glob(reg_f).unnamed_addr = 2;
    rt := new_function(type_func(ir.t_void, .[type_ptr(0)], false), "", dl.program_as);
    array_add(*ir.m_functions, rt);
    set_name(rt, "__llvm_profile_register_function");
    b: Irb; irb_set_end(*b, create_block(reg_f, ""));
    for il.compiler_used_vars if vkind(it) != .FUNCTION irb_call(*b, rt, .[irb_pointer_bitcast_or_addrspacecast(*b, it, type_ptr(0))]);
    for il.used_vars if it != il.names_var && vkind(it) != .FUNCTION irb_call(*b, rt, .[irb_pointer_bitcast_or_addrspacecast(*b, it, type_ptr(0))]);
    if il.names_var != NONE {
        nr := new_function(type_func(ir.t_void, .[type_ptr(0), ir.t_i64], false), "", dl.program_as);
        array_add(*ir.m_functions, nr);
        set_name(nr, "__llvm_profile_register_names_function");
        irb_call(*b, nr, .[irb_pointer_bitcast_or_addrspacecast(*b, il.names_var, type_ptr(0)), const_int(ir.t_i64, cast(u64) il.names_size)]);
    }
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));
}

// emitRuntimeHook
il_emit_runtime_hook :: (il: *Instr_Lowerer) -> bool {
    if il_is_gpu(il) return false;
    if il.tt.os == .Linux || il.tt.os == .AIX return false;
    if module_get_global_variable("__llvm_profile_runtime") != NONE return false;
    v := gv_create(ir.t_i32, false, .EXTERNAL, NONE, "__llvm_profile_runtime", NONE, 0, dl.globals_as);
    gv_set_visibility(v, 1);
    if il.tt.obj == .ELF && !triple_is_ps(*il.tt) {
        array_add(*il.compiler_used_vars, v);
    } else {
        user := new_function(type_func(ir.t_i32, .[], false), "", dl.program_as);
        array_add(*ir.m_functions, user);
        gv_set_linkage(user, .LINKONCE_ODR);
        set_name(user, "__llvm_profile_runtime_user");
        fn_add_fn_attr_kind(user, .NoInline);
        gv_set_visibility(user, 1);
        if triple_supports_comdat() glob(user).comdat = get_comdat(vname(user));
        fn_set_entry_count(user, 0);
        b: Irb; irb_set_end(*b, create_block(user, ""));
        ld := irb_load(*b, ir.t_i32, v, dl_alignment(ir.t_i32, true));
        r := new_inst(.RET, ir.t_void, 1);
        set_op(r, 0, ld);
        irb_insert(*b, r);
        array_add(*il.compiler_used_vars, user);
    }
    return true;
}

// emitUses
il_emit_uses :: (il: *Instr_Lowerer) {
    o := il.tt.obj;
    if o == .ELF || o == .MachO || (o == .COFF && !il.data_referenced_by_code) mu_append_to_used_list("llvm.compiler.used", il.compiler_used_vars);
    else mu_append_to_used_list("llvm.used", il.compiler_used_vars);
    mu_append_to_used_list("llvm.used", il.used_vars);
}

// emitInitialization
il_emit_initialization :: (il: *Instr_Lowerer) {
    // createProfileFileNameVar(M, Options.InstrProfileOutput): empty for the `instrprof` pass
    reg_f := module_get_function("__llvm_profile_register_functions");
    if reg_f == NONE return;
    f := new_function(type_func(ir.t_void, .[], false), "", dl.program_as);
    array_add(*ir.m_functions, f);
    gv_set_linkage(f, .INTERNAL);
    set_name(f, "__llvm_profile_init");
    glob(f).unnamed_addr = 2;
    fn_add_fn_attr_kind(f, .NoInline);
    b: Irb; irb_set_end(*b, create_block(f, ""));
    irb_call(*b, reg_f, .[]);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));
    append_to_global_ctors(f, 0);
}

// createProfileSamplingVar
create_profile_sampling_var :: () {
    c := sampled_config();
    ty := ifx c.use_short then type_int(16) else ir.t_i32;
    v := gv_create(ty, false, .WEAK_ANY, const_int(ty, 0), "__llvm_profile_sampling", NONE, 0, dl.globals_as);
    gv_set_visibility(v, 0);
    glob(v).tls = 1;
    if triple_supports_comdat() {
        gv_set_linkage(v, .EXTERNAL);
        glob(v).comdat = get_comdat("__llvm_profile_sampling");
    }
    append_to_compiler_used(v);
}

// InstrLowerer::lower
instrprof_lower :: (is_cs := false) -> bool {
    il: Instr_Lowerer;
    il.is_cs = is_cs;
    il.tt = triple_parse(ir.triple);
    il.data_referenced_by_code = il_prof_data_referenced_by_code();
    il.pd.allocator = temp; il.pd_index.allocator = temp; il.bias_of.allocator = temp;
    il.compiler_used_vars.allocator = temp; il.used_vars.allocator = temp; il.referenced_names.allocator = temp;
    il.promotion_candidates.allocator = temp;
    if instrprof_cl.enable_vtable_value_profiling fatal("instrprof: -enable-vtable-value-profiling is not supported");
    made_change := false;
    needs_runtime_hook := il.tt.os != .Fuchsia;
    if needs_runtime_hook made_change = il_emit_runtime_hook(*il);
    if !is_cs && il_sampling_enabled() create_profile_sampling_var();
    contains := il_contains_profiling_intrinsics();
    cov := lookup_global("__llvm_coverage_names");
    if cov != NONE && vkind(cov) != .GLOBAL_VAR cov = NONE;
    if !contains && cov == NONE return made_change;
    for f: ir.m_functions {
        first: Value_Id = NONE;
        for b: fn_blocks(f) for i: block_insts(b) {
            k := ip_kind(i);
            if k == .VALUE_PROFILE il_compute_num_value_site_counts(*il, i);
            else {
                if first == NONE && (k == .INCREMENT || k == .INCREMENT_STEP || k == .COVER) first = i;
                if k == .MCDC_PARAMETERS il_get_or_create_region_bitmaps(*il, i);
            }
        }
        if first != NONE il_get_or_create_region_counters(*il, first);
    }
    for f: ir.m_functions made_change |= il_lower_intrinsics(*il, f);
    if cov != NONE { il_lower_coverage_data(*il, cov); made_change = true; }
    if !made_change return false;
    il_emit_vnodes(*il);
    il_emit_name_data(*il);
    if !needs_runtime_hook && contains il_emit_runtime_hook(*il);
    il_emit_registration(*il);
    il_emit_uses(*il);
    il_emit_initialization(*il);
    return true;
}

instrprof_run :: () -> Preserved {
    if !instrprof_lower() return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
