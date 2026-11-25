// pgo-memop-opt (PGOMemOPSizeOpt): size-specialize memcpy / memset (and memcmp / bcmp) calls from their
// !prof "VP" memop-size value profiles. Ported from llvm/lib/Transforms/Instrumentation/PGOMemOPSizeOpt.cpp
// and setProfMetadata (llvm/lib/Transforms/Instrumentation/PGOInstrumentation.cpp, downscaleWeights from
// llvm/lib/IR/ProfDataUtils.cpp). Optimization remarks are not emitted.

memop_cl: struct {
    count_threshold: u64 = 1000;   // -pgo-memop-count-threshold
    disable := false;              // -disable-memop-opt
    percent_threshold: u64 = 40;   // -pgo-memop-percent-threshold
    max_version: u32 = 3;          // -pgo-memop-max-version
    scale_count := true;           // -pgo-memop-scale-count
    max_opt_size: s64 = 128;       // -memop-value-prof-max-opt-size
}
INSTR_PROF_NUM_BUCKETS :: 22;

memop_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    o := *memop_cl;
    if name == {
        case "pgo-memop-count-threshold"; o.count_threshold = cast(u64) smisc_int(name, value, has_value);
        case "disable-memop-opt"; o.disable = smisc_bool(name, value, has_value);
        case "pgo-memop-percent-threshold"; o.percent_threshold = cast(u64) smisc_int(name, value, has_value);
        case "pgo-memop-max-version"; o.max_version = cast(u32) smisc_int(name, value, has_value);
        case "pgo-memop-scale-count"; o.scale_count = smisc_bool(name, value, has_value);
        case "memop-value-prof-max-opt-size"; o.max_opt_size = smisc_int(name, value, has_value);
        case; return false;
    }
    return true;
}
memop_takes_value :: (n: string) -> bool {
    return n == "pgo-memop-count-threshold" || n == "pgo-memop-percent-threshold" || n == "pgo-memop-max-version" ||
           n == "memop-value-prof-max-opt-size";
}

// InstrProfIsSingleValRange (InstrProfData.inc)
instrprof_is_single_val_range :: (v: u64) -> bool { return v <= 8 || popcount(v) == 1; }

memop_is_profitable :: (count: u64, total: u64) -> bool {
    if count < memop_cl.count_threshold return false;
    if count < total * memop_cl.percent_threshold / 100 return false;
    return true;
}
memop_scaled_count :: (count: u64, num: u64, denom: u64) -> u64 {
    if !memop_cl.scale_count return count;
    s, _ := saturating_multiply_add(count, num, 0);   // SaturatingMultiply
    return s / denom;
}

// setProfMetadata(TI, EdgeCounts, MaxCount)
pgo_set_prof_metadata :: (ti: Value_Id, counts: [] u64, max_count: u64) {
    scale := pgo_count_scale(max_count);
    w := NewArray(counts.count, u32,, allocator = temp);
    for counts w[it_index] = pgo_scale_branch_count(it, scale);
    prof_set_branch_weights(ti, w, false);
}

// MemOPSizeOpt::perform(MemOp)
memop_perform :: (f: Value_Id, bfi: *Bfi, mo: Value_Id, is_mi: bool) -> bool {
    if is_mi && call_iid(mo) == IID_MEMMOVE return false;
    if !is_mi && !pgo_gen_cl.memop_optimize_memcmp_bcmp return false;
    vds, _, total_count := vp_get_value_prof_data(mo, IPVK_MEMOP_SIZE, INSTR_PROF_NUM_BUCKETS, false);
    if vds.count == 0 return false;
    actual_count := total_count;
    saved_total_count := total_count;
    if memop_cl.scale_count {
        ok, c := bfi_block_profile_count(bfi, inst_block(mo));
        if !ok return false;
        actual_count = c;
    }
    if actual_count < memop_cl.count_threshold return false;
    if total_count == 0 return false;
    total_count = actual_count;
    remain_count := total_count;
    saved_remain_count := saved_total_count;
    size_ids: [..] u64; size_ids.allocator = temp;
    case_counts: [..] u64; case_counts.allocator = temp;
    max_count: u64 = 0;
    version: u32 = 0;
    array_add(*case_counts, 0);
    remaining: [..] Vp_Data; remaining.allocator = temp;
    for k: 0..vds.count - 1 {
        vd := vds[k];
        v := cast(s64) vd.value;
        c := vd.count;
        if memop_cl.scale_count c = memop_scaled_count(c, actual_count, saved_total_count);
        if !instrprof_is_single_val_range(vd.value) || v > memop_cl.max_opt_size { array_add(*remaining, vd); continue; }
        if !memop_is_profitable(c, remain_count) {
            for j: k..vds.count - 1 array_add(*remaining, vds[j]);
            break;
        }
        array_add(*size_ids, vd.value);
        array_add(*case_counts, c);
        if c > max_count max_count = c;
        remain_count -= c;
        saved_remain_count -= vd.count;
        version += 1;
        if version >= memop_cl.max_version && memop_cl.max_version != 0 {
            for j: k + 1..vds.count - 1 array_add(*remaining, vds[j]);
            break;
        }
    }
    if version == 0 return false;
    case_counts[0] = remain_count;
    if remain_count > max_count max_count = remain_count;

    bb := inst_block(mo);
    orig_freq := bfi_get_block_freq(bfi, bb);
    default_bb := split_block(bb, mo, null, null);
    merge_bb := split_block(default_bb, inst_next(mo), null, null);
    set_name(merge_bb, "MemOP.Merge");
    bfi_set_block_freq(bfi, merge_bb, orig_freq);
    set_name(default_bb, "MemOP.Default");
    erase_inst(block_terminator(bb));
    size_var := op(mo, 2);   // MemIntrinsic::getLength / getArgOperand(2)
    si := create_switch(size_var, default_bb, cast(u32) size_ids.count);
    block_append_inst(bb, si);
    memop_ty := vtype(mo);
    phi: Value_Id = NONE;
    if memop_ty != ir.t_void {
        phi = create_phi(memop_ty, cast(u32) size_ids.count + 1);
        first := block_first_non_phi(merge_bb);
        if first != NONE { d := get_metadata(first, 0); if d != NONE set_metadata(phi, 0, d); }
        insert_at_position(phi, merge_bb, first, false);
        set_name(phi, "MemOP.RVMerge");
        replace_all_uses_with(mo, phi);
        phi_add_incoming(phi, mo, default_bb);
    }
    set_metadata(mo, md_fixed("prof"), NONE);
    if saved_remain_count > 0 || version != cast(u32) vds.count
        vp_annotate_value_site(mo, remaining, saved_remain_count, IPVK_MEMOP_SIZE, cast(u32) vds.count);
    size_ty := vtype(size_var);
    for size_id: size_ids {
        case_bb := create_block(f, tprint("MemOP.Case.%", size_id), default_bb);
        nmo := ic_clone_inst(mo);
        case_size := const_int(size_ty, size_id);
        set_op(nmo, 2, case_size);
        block_append_inst(case_bb, nmo);
        block_append_inst(case_bb, create_br(merge_bb));
        sw_add_case(si, case_size, case_bb);
        if memop_ty != ir.t_void phi_add_incoming(phi, nmo, case_bb);
    }
    if max_count pgo_set_prof_metadata(si, case_counts, max_count);
    return true;
}

// PGOMemOPSizeOpt::run / PGOMemOPSizeOptImpl
pgo_memop_opt_run :: (f: Value_Id) -> Preserved {
    if memop_cl.disable return PRESERVE_ALL;
    if fn_has_opt_size(f) return PRESERVE_ALL;
    bfi := get_bfi(f);
    Mo :: struct { i: Value_Id; is_mi: bool; }
    work: [..] Mo; work.allocator = temp;
    for b: fn_blocks(f) for i: block_insts(b) {
        if inst_op(i) != .CALL continue;
        if is_mem_intrinsic_inst(i) {   // visitMemIntrinsic
            if vkind(op(i, 2)) == .C_INT continue;
            array_add(*work, .{i, true});
            continue;
        }
        ok, lf := tli_lookup_call(i);   // visitCallInst
        if ok && (lf == .memcmp || lf == .bcmp) && vkind(op(i, 2)) != .C_INT array_add(*work, .{i, false});
    }
    changed := false;
    for work if memop_perform(f, bfi, it.i, it.is_mi) changed = true;
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}
