// InterleavedAccess (interleaved-access): port of llvm/lib/CodeGen/InterleavedAccessPass.cpp
// (InterleavedAccessImpl::runOnFunction, lowerInterleavedLoad, tryReplaceExtracts, replaceBinOpShuffles,
// lowerInterleavedStore, isDeInterleaveMask, isReInterleaveMask), ShuffleVectorInst::isInterleaveMask
// (llvm/lib/IR/Instructions.cpp), getMask / getGapMask, lowerDeinterleaveIntrinsic / lowerInterleaveIntrinsic (X86
// implements neither TLI hook, so only getMask's side effects remain). The X86 lowering of AVX factor-3/4 groups is
// x86_interleaved_access.jai.
// The DenseMap<ExtractElementInst *, ...> walk of tryReplaceExtracts creates the new extracts in pointer order, which
// only changes the order of the shuffles' use lists (each new extract goes in front of its old one); we use the order
// of the load's users.

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

// ShuffleVectorInst::isDeInterleaveMaskOfFactor(Mask, Factor, Index)
ia_deinterleave_index :: (mask: [] s32, factor: u32) -> (bool, u32) {
    for idx: 0..factor - 1 {
        i := 0;
        while i < mask.count {
            if mask[i] >= 0 && cast(u32) mask[i] != idx + cast(u32) i * factor break;
            i += 1;
        }
        if i == mask.count return true, idx;
    }
    return false, 0;
}

// ShuffleVectorInst::isInterleaveMask(Mask, Factor, NumInputElts, StartIndexes)
ia_interleave_start_indexes :: (mask: [] s32, factor: u32, num_input_elts: u32) -> (bool, [..] s64) {
    starts: [..] s64; starts.allocator = temp;
    num_elts := cast(u32) mask.count;
    if num_elts % factor return false, starts;
    lane_len := num_elts / factor;
    if lane_len == 0 || (lane_len & (lane_len - 1)) != 0 return false, starts;
    for i: 0..factor-1 {
        saved_lane_value: s64 = 0;
        saved_no_undefs: s64 = 0;
        j: u32 = 0;
        while j < lane_len - 1 {
            lane := j * factor + i;
            next_lane := lane + factor;
            lv := cast(s64) mask[lane];
            nv := cast(s64) mask[next_lane];
            if lv >= 0 && nv >= 0 && lv + 1 != nv break;
            if lv >= 0 && nv < 0 { saved_lane_value = lv; saved_no_undefs = 1; }
            if saved_no_undefs > 0 && lv < 0 {
                saved_no_undefs += 1;
                if nv >= 0 && saved_lane_value + saved_no_undefs != nv break;
            }
            j += 1;
        }
        if j < lane_len - 1 return false, starts;
        start: s64 = 0;
        if mask[i] >= 0 start = mask[i];
        else if mask[(lane_len - 1) * factor + i] >= 0 start = cast(s64) mask[(lane_len - 1) * factor + i] - cast(s64) j;
        else if saved_no_undefs > 0 start = saved_lane_value - (cast(s64) lane_len - 1 - saved_no_undefs);
        if start < 0 return false, starts;
        if start + lane_len > num_input_elts return false, starts;
        array_add(*starts, start);
    }
    return true, starts;
}

// getInterleaveIntrinsicFactor / getDeinterleaveIntrinsicFactor
ia_interleave_factor :: (id: Intrinsic_Id, de: bool) -> u32 {
    if id == NOT_INTRINSIC return 0;
    n := iid_name(id);
    prefix := ifx de then "llvm.vector.deinterleave" else "llvm.vector.interleave";
    if !begins_with(n, prefix) || n.count != prefix.count + 1 return 0;
    d := n[prefix.count];
    if d < #char "2" || d > #char "8" return 0;
    return cast(u32) (d - #char "0");
}

// getMaskOperand
ia_mask_operand :: (ii: Value_Id) -> Value_Id {
    id := call_iid(ii);
    if id == IID_VP_LOAD || id == IID_MASKED_LOAD return op(ii, 1);
    return op(ii, 2);
}

// getMask(WideMask, Factor, LeafValueEC) -> (Mask or NONE, GapMask as a bit set of Factor bits)
ia_get_mask :: (wide: Value_Id, factor: u32, leaf_n: u64, leaf_scalable: bool) -> (Value_Id, u64) {
    gap: u64 = (cast(u64) 1 << factor) - 1;
    if is_inst(wide) && inst_op(wide) == .CALL {
        f := ia_interleave_factor(call_iid(wide), false);
        if f != 0 && f == factor {
            ref: Value_Id = NONE;
            for k: 0..cast(s64) call_num_args(wide) - 1 {
                a := op(wide, cast(u32) k);
                if is_constant_kind(vkind(a)) && is_null_value(a) { gap &= ~(cast(u64) 1 << cast(u64) k); continue; }
                if ref == NONE ref = a;
                else if ref != a return NONE, gap;
            }
            return ifx ref != NONE then ref else op(wide, 0), gap;
        }
    }
    if is_inst(wide) && inst_op(wide) == .AND {
        ml, gl := ia_get_mask(op(wide, 0), factor, leaf_n, leaf_scalable);
        mr, gr := ia_get_mask(op(wide, 1), factor, leaf_n, leaf_scalable);
        if ml == NONE || mr == NONE return NONE, gap;
        b: Irb; irb_set_before(*b, wide);   // IRBuilder<>(AndOp).CreateAnd
        return irb_binop(*b, .AND, ml, mr), gl & gr;
    }
    if is_constant_kind(vkind(wide)) {
        splat := get_splat_value(wide);
        if splat != NONE return cf_get_splat(type_vector(leaf_n, vtype(splat), leaf_scalable), splat), gap;
        if !leaf_scalable {
            len := leaf_n;
            // getGapMask
            for f: 0..cast(u64) factor - 1 {
                all_zero := true;
                for idx: 0..len - 1 if !is_null_value(cf_elt(wide, f + idx * factor)) { all_zero = false; break; }
                if all_zero gap &= ~(cast(u64) 1 << f);
            }
            leaf := NewArray(cast(s64) len, Value_Id,, allocator = temp);
            for * leaf it.* = NONE;
            for idx: 0..len * factor - 1 {
                if (gap >> (idx % factor)) & 1 == 0 continue;
                c := cf_elt(wide, idx);
                if leaf[idx / factor] != NONE && leaf[idx / factor] != c return NONE, gap;
                leaf[idx / factor] = c;
            }
            return const_vector_of(leaf), gap;
        }
    }
    if is_inst(wide) && inst_op(wide) == .SHUFFLEVECTOR {
        op1_ty := vtype(op(wide, 1));
        if type_kind(op1_ty) != .VECTOR return NONE, gap;
        num_src := cast(u32) type_count(op1_ty);
        mask := shuf_mask(wide);
        ok, starts := ia_interleave_start_indexes(mask, factor, num_src * 2);
        all_ok := ok;
        if ok for starts if it != 0 { all_ok = false; break; }
        if all_ok for mask if it >= cast(s32) num_src { all_ok = false; break; }
        if all_ok {
            b: Irb; irb_set_before(*b, wide);
            leaf_ty := type_vector(leaf_n, ir.t_i1, leaf_scalable);
            ex := vp_intrinsic(*b, intrinsic_id_by_name("llvm.vector.extract"), .[leaf_ty, vtype(op(wide, 0))], .[op(wide, 0), const_int(ir.t_i64, 0)]);
            return ex, gap;
        }
    }
    return NONE, gap;
}

ia_popcount :: (x: u64) -> u32 { n: u32 = 0; v := x; while v { n += cast(u32) (v & 1); v >>= 1; } return n; }

ia_dead_add :: (dead: *[..] Value_Id, i: Value_Id) { for dead.* if it == i return; array_add(dead, i); }   // SmallSetVector

// lowerInterleavedLoad
ia_lower_interleaved_load :: (load: Value_Id, st: *X86_Lowering, dt: *Dom_Tree, dead: *[..] Value_Id) -> bool {
    ty := vtype(load);
    if type_kind(ty) == .SVECTOR return false;
    is_load := inst_op(load) == .LOAD;
    if is_load && !load_is_simple(load) return false;
    shuffles: [..] Value_Id; shuffles.allocator = temp;
    extracts: [..] Value_Id; extracts.allocator = temp;
    bin_op_shuffles: [..] Value_Id; bin_op_shuffles.allocator = temp;
    for user: sx_users(load) {
        if is_inst(user) && inst_op(user) == .EXTRACTELEMENT && is_constant_int(op(user, 1)) { array_add(*extracts, user); continue; }
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
    indices: [..] u32; indices.allocator = temp;
    vec_ty := vtype(first);
    for s: shuffles {
        if vtype(s) != vec_ty return false;
        ok, index := ia_deinterleave_index(shuf_mask(s), factor);
        if !ok return false;
        array_add(*indices, index);
    }
    for s: bin_op_shuffles {
        if vtype(s) != vec_ty return false;
        ok, index := ia_deinterleave_index(shuf_mask(s), factor);
        if !ok return false;
        bi := op(s, 0);
        if op(bi, 0) == load array_add(*indices, index);
        if op(bi, 1) == load array_add(*indices, index);
    }
    if !ia_try_replace_extracts(extracts, shuffles, dt) return false;
    bin_op_shuffle_changed := ia_replace_bin_op_shuffles(bin_op_shuffles, *shuffles, load);
    if !is_load {
        m, _ := ia_get_mask(ia_mask_operand(load), factor, type_count(vec_ty), false);
        if m == NONE return false;
    }
    // X86TargetLowering::lowerInterleavedLoad: only a LoadInst is lowered
    if !x86_lower_interleaved_load(st, load, shuffles, indices, factor) return extracts.count > 0 || bin_op_shuffle_changed;
    for shuffles ia_dead_add(dead, it);
    ia_dead_add(dead, load);
    return true;
}

// lowerInterleavedStore
ia_lower_interleaved_store :: (store: Value_Id, st: *X86_Lowering, dead: *[..] Value_Id) -> bool {
    stored: Value_Id;
    is_store := inst_op(store) == .STORE;
    if is_store {
        if !load_is_simple(store) return false;
        stored = op(store, 0);
    } else stored = call_arg(store, 0);
    if !(is_inst(stored) && inst_op(stored) == .SHUFFLEVECTOR) || !has_one_use(stored) || type_is_scalable(vtype(stored)) return false;
    mask := shuf_mask(stored);
    if mask.count < 4 return false;
    op_ty := vtype(op(stored, 0));
    // isReInterleaveMask: SVI->isInterleave(Factor) (a scalable operand never matches)
    factor: u32 = 0;
    if type_kind(op_ty) == .VECTOR {
        for f: 2..IA_MAX_FACTOR if sv_is_interleave_mask(mask, cast(u32) f, cast(u32) vec_count(op_ty) * 2) { factor = cast(u32) f; break; }
    }
    if factor == 0 return false;
    if !is_store {
        m, _ := ia_get_mask(ia_mask_operand(store), factor, cast(u64) mask.count / factor, false);
        if m == NONE return false;
    }
    if !x86_lower_interleaved_store(st, store, stored, factor) return false;
    ia_dead_add(dead, store);
    ia_dead_add(dead, stored);
    return true;
}

// lowerDeinterleaveIntrinsic: X86 has no lowerDeinterleaveIntrinsicToLoad; only getMask's side effects remain
ia_lower_deinterleave_intrinsic :: (di: Value_Id, factor: u32) -> bool {
    lv := op(di, 0);
    if !is_inst(lv) || !has_one_use(lv) return false;
    if inst_op(lv) == .LOAD return false;   // the TLI hook refuses
    if inst_op(lv) != .CALL || call_iid(lv) == NOT_INTRINSIC return false;
    id := call_iid(lv);
    if id != IID_MASKED_LOAD && id != IID_VP_LOAD return false;
    leaf := type_sub(vtype(di), 0);   // getDeinterleavedVectorType
    ia_get_mask(ia_mask_operand(lv), factor, type_count(leaf), type_kind(leaf) == .SVECTOR);
    return false;
}
// lowerInterleaveIntrinsic: X86 has no lowerInterleaveIntrinsicToStore
ia_lower_interleave_intrinsic :: (int_ii: Value_Id, factor: u32) -> bool {
    if !has_one_use(int_ii) return false;
    by := ir.u_user[ir.v_first_use[int_ii]];
    if !is_inst(by) return false;
    if inst_op(by) == .STORE return false;
    if inst_op(by) != .CALL || call_iid(by) == NOT_INTRINSIC return false;
    id := call_iid(by);
    if id != IID_MASKED_STORE && id != IID_VP_STORE return false;
    v0 := vtype(op(int_ii, 0));
    m, gap := ia_get_mask(ia_mask_operand(by), factor, type_count(v0), type_kind(v0) == .SVECTOR);
    if m == NONE return false;
    if ia_popcount(gap) != factor return true;
    return false;
}

// InterleavedAccessImpl::runOnFunction
interleaved_access_run :: (f: Value_Id) -> Preserved {
    if tool_name == "llc" && (cg_skip_function(f) || !ia_opts.lower_interleaved_accesses) return PRESERVE_ALL;
    t := tti_get(f);
    if t.kind != .X86 fatal("interleaved-access needs a target machine (an x86 target triple)");
    st := *t.xl;
    dt := get_domtree(f);
    changed := false;
    dead: [..] Value_Id; dead.allocator = temp;
    // instructions(F): new instructions only go in front of the current one, or in front of later extracts and
    // shuffles (not memory operations)
    for bb: fn_blocks(f) {
        i := block(bb).first;
        while i != NONE {
            cur := i;
            o := inst_op(cur);
            id := ifx o == .CALL then call_iid(cur) else NOT_INTRINSIC;
            if o == .LOAD || id == IID_VP_LOAD || id == IID_MASKED_LOAD changed |= ia_lower_interleaved_load(cur, st, dt, *dead);
            if o == .STORE || id == IID_VP_STORE || id == IID_MASKED_STORE changed |= ia_lower_interleaved_store(cur, st, *dead);
            if id != NOT_INTRINSIC {
                df := ia_interleave_factor(id, true);
                if df != 0 changed |= ia_lower_deinterleave_intrinsic(cur, df);
                else {
                    inf := ia_interleave_factor(id, false);
                    if inf != 0 changed |= ia_lower_interleave_intrinsic(cur, inf);
                }
            }
            i = inst(cur).next;
        }
    }
    for dead erase_inst_with_metadata(it);
    if changed return preserved_cfg();
    return PRESERVE_ALL;
}
