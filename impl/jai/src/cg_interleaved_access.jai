// InterleavedAccess (interleaved-access): port of llvm/lib/CodeGen/InterleavedAccessPass.cpp
// (InterleavedAccessImpl::runOnFunction, lowerInterleavedLoad, tryReplaceExtracts, replaceBinOpShuffles,
// lowerInterleavedStore, isDeInterleaveMask, isReInterleaveMask), ShuffleVectorInst::isInterleaveMask
// (llvm/lib/IR/Instructions.cpp) and X86InterleavedAccessGroup::isSupported (X86InterleavedAccess.cpp).
// Not ported: X86InterleavedAccessGroup::lowerIntoOptimizedSequence (AVX, factor 3/4 groups), which fails loudly.

IA_MAX_FACTOR :: 4;   // X86TargetLowering::getMaxSupportedInterleaveFactor
ia_opts: struct { lower_interleaved_accesses := true; }   // -lower-interleaved-accesses

// ShuffleVectorInst::isInterleaveMask(Mask, Factor, NumInputElts)
sv_is_interleave_mask :: (mask: [] s32, factor: u32, num_input_elts: u32) -> bool {
    num_elts := cast(u32) mask.count;
    if num_elts % factor return false;
    lane_len := num_elts / factor;
    if lane_len == 0 || (lane_len & (lane_len - 1)) != 0 return false;
    for i: 0..factor-1 {
        saved_lane_value: s64 = 0;
        saved_no_undefs: s64 = 0;
        j: u32 = 0;
        while j < lane_len - 1 {
            lane := j * factor + i;
            next_lane := lane + factor;
            lane_value := cast(s64) mask[lane];
            next_lane_value := cast(s64) mask[next_lane];
            if lane_value >= 0 && next_lane_value >= 0 && lane_value + 1 != next_lane_value break;
            if lane_value >= 0 && next_lane_value < 0 { saved_lane_value = lane_value; saved_no_undefs = 1; }
            if saved_no_undefs > 0 && lane_value < 0 {
                saved_no_undefs += 1;
                if next_lane_value >= 0 && saved_lane_value + saved_no_undefs != next_lane_value break;
            }
            j += 1;
        }
        if j < lane_len - 1 return false;
        start_mask: s64 = 0;
        if mask[i] >= 0 start_mask = mask[i];
        else if mask[(lane_len - 1) * factor + i] >= 0 start_mask = cast(s64) mask[(lane_len - 1) * factor + i] - cast(s64) j;
        else if saved_no_undefs > 0 start_mask = saved_lane_value - (cast(s64) lane_len - 1 - saved_no_undefs);
        if start_mask < 0 return false;
        if start_mask + lane_len > num_input_elts return false;
    }
    return true;
}

ia_is_poison_or_undef :: (v: Value_Id) -> bool { k := vkind(v); return k == .C_UNDEF || k == .C_POISON; }

// X86InterleavedAccessGroup::isSupported (llvm/lib/Target/X86/X86InterleavedAccess.cpp)
ia_x86_is_supported :: (st: *X86_Lowering, i: Value_Id, shuffle0: Value_Id, factor: u32) -> bool {
    if !st_hasAVX(st) || (factor != 4 && factor != 3) return false;
    shuffle_elem_size := dl_type_size_bits(type_elem(vtype(shuffle0)));
    wide_inst_size: u64;
    if inst_op(i) == .LOAD {
        wide_inst_size = dl_type_size_bits(vtype(i));
        if type_addrspace(vtype(op(i, 0))) != 0 return false;
    } else wide_inst_size = dl_type_size_bits(vtype(shuffle0));
    if shuffle_elem_size == 64 && wide_inst_size == 1024 && factor == 4 return true;
    if shuffle_elem_size == 8 && inst_op(i) == .STORE && factor == 4 &&
       (wide_inst_size == 256 || wide_inst_size == 512 || wide_inst_size == 1024 || wide_inst_size == 2048) return true;
    if shuffle_elem_size == 8 && factor == 3 && (wide_inst_size == 384 || wide_inst_size == 768 || wide_inst_size == 1536) return true;
    return false;
}

// tryReplaceExtracts
ia_try_replace_extracts :: (extracts: [] Value_Id, shuffles: [] Value_Id, dt: *Dom_Tree) -> bool {
    if extracts.count == 0 return true;
    Repl :: struct { extract: Value_Id; vector: Value_Id; index: u64; }
    repl: [..] Repl; repl.allocator = temp;
    for extract: extracts {
        index := ap_sext_value(const_ap(op(extract, 1)));
        found := false;
        for shuffle: shuffles {
            if !dt_dominates_inst(dt, shuffle, extract) continue;
            indices := shuf_mask(shuffle);
            for idx, k: indices if cast(s64) idx == index {
                array_add(*repl, .{extract, shuffle, cast(u64) k});
                found = true;
                break;
            }
            if found break;
        }
        if !found return false;
    }
    for r: repl {
        b: Irb; irb_set_before(*b, r.extract);
        ne := irb_extract_element(*b, r.vector, r.index);
        rauw_with_metadata(r.extract, ne);
        erase_inst_with_metadata(r.extract);
    }
    return true;
}

// replaceBinOpShuffles
ia_replace_bin_op_shuffles :: (bin_op_shuffles: [] Value_Id, shuffles: *[..] Value_Id, load: Value_Id) -> bool {
    for svi: bin_op_shuffles {
        bi := op(svi, 0);
        mask := shuf_mask(svi);
        b: Irb; irb_set_before(*b, svi);
        name := vname(svi);
        new_svi1 := new_inst(.SHUFFLEVECTOR, type_vector(cast(u64) mask.count, type_elem(vtype(op(bi, 0))), false), 2);
        set_op(new_svi1, 0, op(bi, 0)); set_op(new_svi1, 1, const_poison(vtype(op(bi, 0))));
        ia_set_mask(new_svi1, mask);
        irb_insert(*b, new_svi1, name);
        new_svi2 := new_inst(.SHUFFLEVECTOR, type_vector(cast(u64) mask.count, type_elem(vtype(op(bi, 1))), false), 2);
        set_op(new_svi2, 0, op(bi, 1)); set_op(new_svi2, 1, const_poison(vtype(op(bi, 1))));
        ia_set_mask(new_svi2, mask);
        irb_insert(*b, new_svi2, name);
        // BinaryOperator::CreateWithCopiedFlags(Opc, V1, V2, BI, Name, InsertPt)
        new_bi := new_inst(inst_op(bi), vtype(new_svi1), 2);
        set_op(new_bi, 0, new_svi1); set_op(new_bi, 1, new_svi2);
        inst(new_bi).flags = inst(bi).flags;
        irb_insert(*b, new_bi, vname(bi));
        rauw_with_metadata(svi, new_bi);
        recursively_delete_trivially_dead_value(svi);
        if op(new_svi1, 0) == load array_add(shuffles, new_svi1);
        if op(new_svi2, 0) == load array_add(shuffles, new_svi2);
    }
    return bin_op_shuffles.count > 0;
}
ia_set_mask :: (sv: Value_Id, mask: [] s32) {
    r := inst(sv);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) mask.count;
    for mask array_add(*ir.u32_pool, cast,no_check(u32) it);
}

// lowerInterleavedLoad
ia_lower_interleaved_load :: (load: Value_Id, st: *X86_Lowering, dt: *Dom_Tree) -> bool {
    ty := vtype(load);
    if type_kind(ty) != .VECTOR return false;
    is_load := inst_op(load) == .LOAD;
    if is_load && !load_is_simple(load) return false;
    shuffles: [..] Value_Id; shuffles.allocator = temp;
    extracts: [..] Value_Id; extracts.allocator = temp;
    bin_op_shuffles: [..] Value_Id; bin_op_shuffles.allocator = temp;
    for user: sx_users(load) {
        if is_inst(user) && inst_op(user) == .EXTRACTELEMENT && vkind(op(user, 1)) == .C_INT { array_add(*extracts, user); continue; }
        if is_binary_operator(user) {
            us := sx_users(user);
            all_shuf := us.count > 0;
            for u: us if !(is_inst(u) && inst_op(u) == .SHUFFLEVECTOR && ia_is_poison_or_undef(op(u, 1))) { all_shuf = false; break; }
            if all_shuf {
                for u: us { dup := false; for bin_op_shuffles if it == u dup = true; if !dup array_add(*bin_op_shuffles, u); }
                continue;
            }
        }
        if !(is_inst(user) && inst_op(user) == .SHUFFLEVECTOR) || !ia_is_poison_or_undef(op(user, 1)) return false;
        array_add(*shuffles, user);
    }
    if shuffles.count == 0 && bin_op_shuffles.count == 0 return false;
    num_load_elements := cast(u64) vec_count(ty);
    first := ifx shuffles.count then shuffles[0] else bin_op_shuffles[0];
    // isDeInterleaveMask
    mask := shuf_mask(first);
    if mask.count < 2 return false;
    factor: u32 = 0;
    found := false;
    for f: 2..IA_MAX_FACTOR {
        if cast(u64) mask.count * cast(u64) f > num_load_elements return false;
        if svm_is_deinterleave_mask_of_factor(mask, cast(u32) f) { factor = cast(u32) f; found = true; break; }
    }
    if !found return false;
    vec_ty := vtype(first);
    for s: shuffles {
        if vtype(s) != vec_ty return false;
        if !svm_is_deinterleave_mask_of_factor(shuf_mask(s), factor) return false;
    }
    for s: bin_op_shuffles {
        if vtype(s) != vec_ty return false;
        if !svm_is_deinterleave_mask_of_factor(shuf_mask(s), factor) return false;
    }
    if !ia_try_replace_extracts(extracts, shuffles, dt) return false;
    bin_op_shuffle_changed := ia_replace_bin_op_shuffles(bin_op_shuffles, *shuffles, load);
    // masked / vp loads: getMask, then X86TargetLowering::lowerInterleavedLoad refuses anything but a LoadInst
    if is_load && ia_x86_is_supported(st, load, shuffles[0], factor)
        fatal("interleaved-access: X86 lowering of an interleaved load (X86InterleavedAccessGroup) is not supported yet (in function '%')", vname(inst_fn(load)));
    return extracts.count > 0 || bin_op_shuffle_changed;
}

// lowerInterleavedStore
ia_store_would_change :: (store: Value_Id, st: *X86_Lowering) -> bool {
    stored: Value_Id;
    if inst_op(store) == .STORE {
        if !load_is_simple(store) return false;
        stored = op(store, 0);
    } else stored = call_arg(store, 0);
    if !(is_inst(stored) && inst_op(stored) == .SHUFFLEVECTOR) || !has_one_use(stored) || type_is_scalable(vtype(stored)) return false;
    mask := shuf_mask(stored);
    if mask.count < 4 return false;
    op_ty := vtype(op(stored, 0));
    if type_kind(op_ty) != .VECTOR || type_is_scalable(op_ty) return false;
    for f: 2..IA_MAX_FACTOR if sv_is_interleave_mask(mask, cast(u32) f, cast(u32) vec_count(op_ty) * 2) {
        // X86TargetLowering::lowerInterleavedStore: only a StoreInst whose group isSupported is rewritten
        return inst_op(store) == .STORE && ia_x86_is_supported(st, store, stored, cast(u32) f);
    }
    return false;
}


// InterleavedAccessImpl::runOnFunction
interleaved_access_run :: (f: Value_Id) -> Preserved {
    if cg_skip_function(f) || !ia_opts.lower_interleaved_accesses return PRESERVE_ALL;
    st := *tti_get(f).xl;
    dt := get_domtree(f);
    changed := false;
    insts: [..] Value_Id; insts.allocator = temp;
    for bb: fn_blocks(f) for i: block_insts(bb) array_add(*insts, i);
    for i: insts {
        if vkind(i) != .INST continue;
        o := inst_op(i);
        id := ifx o == .CALL then call_iid(i) else NOT_INTRINSIC;
        if o == .LOAD || id == IID_VP_LOAD || id == IID_MASKED_LOAD {
            changed |= ia_lower_interleaved_load(i, st, dt);
        }
        if o == .STORE || id == IID_VP_STORE || id == IID_MASKED_STORE {
            if ia_store_would_change(i, st) fatal("interleaved-access: lowering an interleaved store is not supported yet (in function '%')", vname(f));
        }
        // lowerDeinterleaveIntrinsic / lowerInterleaveIntrinsic: X86 implements neither TLI hook, so no change
    }
    if changed return preserved_cfg();
    return PRESERVE_ALL;
}
