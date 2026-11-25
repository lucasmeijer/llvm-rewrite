// ScalarizeMaskedMemIntrinPass (and the legacy pass in llc's IR pipeline): a port of
// llvm/lib/Transforms/Scalar/ScalarizeMaskedMemIntrin.cpp (complete), with SplitBlockAndInsertIfThenElse
// (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp) for a lazy DomTreeUpdater.

SMMI_DEBUG_TYPE :: "scalarize-masked-mem-intrin";
IID_EXPERIMENTAL_VECTOR_HISTOGRAM_ADD :: #run iid_by_name("llvm.experimental.vector.histogram.add");
IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UADD_SAT :: #run iid_by_name("llvm.experimental.vector.histogram.uadd.sat");
IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UMIN :: #run iid_by_name("llvm.experimental.vector.histogram.umin");
IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UMAX :: #run iid_by_name("llvm.experimental.vector.histogram.umax");

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable = false, BranchWeights, DTU): the new then-block's
// terminator
smmi_split_block_and_insert_if_then :: (cond: Value_Id, split_before: Value_Id, weights: Md_Id, dtu: *Dtu) -> Value_Id {
    head := inst_block(split_before);
    uniq: [..] Value_Id; uniq.allocator = temp;
    if dtu {
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(head, *succs);
        for s: succs { dup := false; for uniq if it == s dup = true; if !dup array_add(*uniq, s); }
    }
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    then_bb := create_block(f, "", tail);
    br := create_br(tail);
    block_append_inst(then_bb, br);
    dl := get_metadata(split_before, 0);
    set_metadata(br, 0, dl);
    old := block_terminator(head);
    nt := create_cond_br(cond, then_bb, tail);
    if weights != NONE set_metadata(nt, md_fixed("prof"), weights);
    // ReplaceInstWithInst
    insert_at_position(nt, head, old, false);
    if get_metadata(nt, 0) == NONE copy_debug_loc(nt, old);
    drop_all_references(old);
    erase_inst(old);
    if dtu {
        ups: [..] Dom_Update; ups.allocator = temp;
        array_add(*ups, .{true, head, then_bb});
        array_add(*ups, .{true, head, tail});
        array_add(*ups, .{true, then_bb, tail});
        for uniq array_add(*ups, .{true, tail, it});
        for uniq array_add(*ups, .{false, head, it});
        dtu_apply(dtu, ups);
    }
    return br;
}

// isConstantIntVector
smmi_is_constant_int_vector :: (mask: Value_Id) -> bool {
    if !is_const(mask) return false;
    n := type_count(vtype(mask));
    for i: 0..cast(s64) n - 1 {
        e := cf_elt(mask, cast(u64) i);
        if e == NONE || vkind(e) != .C_INT return false;
    }
    return true;
}
smmi_mask_elt_is_null :: (mask: Value_Id, i: u32) -> bool { return is_null_value(cf_elt(mask, cast(u64) i)); }

// CI->getParamAlign(i).valueOrOne()
smmi_param_align :: (ci: Value_Id, i: u32) -> u64 {
    a := call_param_align(ci, i);
    if a == 0 return 1;
    return a;
}

// Builder.CreateConstInBoundsGEP1_32
smmi_const_inbounds_gep :: (b: *Irb, ty: Type_Id, ptr: Value_Id, idx: u32, name: string = "") -> Value_Id {
    return irb_gep(b, ty, ptr, .[const_int(type_int(cast(u64) 32), idx)], name, F_INBOUNDS);
}
// the scalar-mask predicate: icmp ne (and %scalar_mask, 1 << Idx), 0  (little endian)
smmi_bit_predicate :: (b: *Irb, sclr_mask: Value_Id, width: u32, idx: u32) -> Value_Id {
    t := type_int(cast(u64) width);
    bit := ap_one_bit_set(width, idx);
    a := irb_binop(b, .AND, sclr_mask, const_int_ap(t, bit));
    return irb_icmp(b, ICMP_NE, a, const_int(t, 0));
}
smmi_align_for :: (align: u64, elt_ty: Type_Id) -> u64 { return sz_fragment_align(align, sz_primitive_bits(elt_ty) / 8); }

smmi_unknown_weights :: (f: Value_Id) -> Md_Id {
    ok, ec := fn_entry_count(f);
    if !ok || ec == 0 return NONE;
    ops: [2] Md_Id;
    ops[0] = md_string("unknown");
    ops[1] = md_string(SMMI_DEBUG_TYPE);
    return md_tuple(ops, false);
}

// The common loop body of the predicated scalarizations: (predicate, cond block terminator)
smmi_predicate :: (b: *Irb, sclr_mask: Value_Id, mask: Value_Id, width: u32, idx: u32, named: bool) -> Value_Id {
    if sclr_mask != NONE return smmi_bit_predicate(b, sclr_mask, width, idx);
    return irb_extract_element(b, mask, idx, ifx named then tconcat("Mask", tdec(idx)) else "");
}
smmi_scalar_mask :: (b: *Irb, mask: Value_Id, width: u32) -> Value_Id {
    if width == 1 return NONE;   // HasBranchDivergence is false on our targets
    return irb_bitcast(b, mask, type_int(cast(u64) width), "scalar_mask");
}
smmi_erase :: (ci: Value_Id) { erase_inst_with_metadata(ci); }

// scalarizeMaskedLoad
smmi_masked_load :: (ci: Value_Id, dtu: *Dtu) -> bool {
    ptr := op(ci, 0); mask := op(ci, 1); src0 := op(ci, 2);
    align := smmi_param_align(ci, 0);
    vec_ty := vtype(ci);
    elt_ty := type_elem(vec_ty);
    b: Irb;
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    if is_const(mask) && cf_is_all_ones(mask) {
        ni := irb_load(*b, vec_ty, ptr, align);
        copy_metadata(ni, ci);
        ic_take_name(ni, ci);
        rauw_with_metadata(ci, ni);
        smmi_erase(ci);
        return false;
    }
    adj := smmi_align_for(align, elt_ty);
    width := cast(u32) type_count(vec_ty);
    vresult := src0;
    if smmi_is_constant_int_vector(mask) {
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            gep := smmi_const_inbounds_gep(*b, elt_ty, ptr, idx);
            load := irb_load(*b, elt_ty, gep, adj);
            vresult = irb_insert_element(*b, vresult, load, idx);
        }
        rauw_with_metadata(ci, vresult);
        smmi_erase(ci);
        return false;
    }
    if_block := inst_block(ci);
    if is_splat_value(mask, 0) {
        pred := irb_extract_element(*b, mask, 0, tconcat(vname(mask), ".first"));
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.load");
        irb_set_before(*b, block_terminator(cond_block));
        load := irb_load(*b, vec_ty, ptr, align, false, tconcat(vname(ci), ".cond.load"));
        copy_metadata(load, ci);
        post := get_successor(then_term, 0);
        irb_set_at(*b, post, block_first(post), true);
        phi := irb_phi(*b, vec_ty, 2);
        phi_add_incoming(phi, load, cond_block);
        phi_add_incoming(phi, src0, if_block);
        ic_take_name(phi, ci);
        rauw_with_metadata(ci, phi);
        smmi_erase(ci);
        return true;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, false);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.load");
        irb_set_before(*b, block_terminator(cond_block));
        gep := smmi_const_inbounds_gep(*b, elt_ty, ptr, idx);
        load := irb_load(*b, elt_ty, gep, adj);
        nv := irb_insert_element(*b, vresult, load, idx);
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        prev_if := if_block;
        if_block = new_if;
        irb_set_at(*b, new_if, block_first(new_if), true);
        phi := irb_phi(*b, vec_ty, 2, "res.phi.else");
        phi_add_incoming(phi, nv, cond_block);
        phi_add_incoming(phi, vresult, prev_if);
        vresult = phi;
    }
    rauw_with_metadata(ci, vresult);
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedStore
smmi_masked_store :: (ci: Value_Id, dtu: *Dtu) -> bool {
    src := op(ci, 0); ptr := op(ci, 1); mask := op(ci, 2);
    align := smmi_param_align(ci, 1);
    vec_ty := vtype(src);
    elt_ty := type_elem(vec_ty);
    b: Irb;
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    if is_const(mask) && cf_is_all_ones(mask) {
        st := irb_store(*b, src, ptr, align);
        ic_take_name(st, ci);
        copy_metadata(st, ci);
        smmi_erase(ci);
        return false;
    }
    adj := smmi_align_for(align, elt_ty);
    width := cast(u32) type_count(vec_ty);
    if smmi_is_constant_int_vector(mask) {
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            one := irb_extract_element(*b, src, idx);
            gep := smmi_const_inbounds_gep(*b, elt_ty, ptr, idx);
            irb_store(*b, one, gep, adj);
        }
        smmi_erase(ci);
        return false;
    }
    if is_splat_value(mask, 0) {
        pred := irb_extract_element(*b, mask, 0, tconcat(vname(mask), ".first"));
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.store");
        irb_set_before(*b, block_terminator(cond_block));
        st := irb_store(*b, src, ptr, align);
        ic_take_name(st, ci);
        copy_metadata(st, ci);
        smmi_erase(ci);
        return true;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, false);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.store");
        irb_set_before(*b, block_terminator(cond_block));
        one := irb_extract_element(*b, src, idx);
        gep := smmi_const_inbounds_gep(*b, elt_ty, ptr, idx);
        irb_store(*b, one, gep, adj);
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        irb_set_at(*b, new_if, block_first(new_if), true);
    }
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedGather
smmi_masked_gather :: (ci: Value_Id, dtu: *Dtu) -> bool {
    ptrs := op(ci, 0); mask := op(ci, 1); src0 := op(ci, 2);
    vec_ty := vtype(ci);
    elt_ty := type_elem(vec_ty);
    b: Irb;
    if_block := inst_block(ci);
    irb_set_before(*b, ci);
    align := smmi_param_align(ci, 0);
    b.dbg = get_metadata(ci, 0);
    vresult := src0;
    width := cast(u32) type_count(vec_ty);
    if smmi_is_constant_int_vector(mask) {
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
            load := irb_load(*b, elt_ty, p, align, false, tconcat("Load", tdec(idx)));
            vresult = irb_insert_element(*b, vresult, load, idx, tconcat("Res", tdec(idx)));
        }
        rauw_with_metadata(ci, vresult);
        smmi_erase(ci);
        return false;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, true);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, smmi_unknown_weights(block_fn(if_block)), dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.load");
        irb_set_before(*b, block_terminator(cond_block));
        p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
        load := irb_load(*b, elt_ty, p, align, false, tconcat("Load", tdec(idx)));
        nv := irb_insert_element(*b, vresult, load, idx, tconcat("Res", tdec(idx)));
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        prev_if := if_block;
        if_block = new_if;
        irb_set_at(*b, new_if, block_first(new_if), true);
        phi := irb_phi(*b, vec_ty, 2, "res.phi.else");
        phi_add_incoming(phi, nv, cond_block);
        phi_add_incoming(phi, vresult, prev_if);
        vresult = phi;
    }
    rauw_with_metadata(ci, vresult);
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedScatter
smmi_masked_scatter :: (ci: Value_Id, dtu: *Dtu) -> bool {
    src := op(ci, 0); ptrs := op(ci, 1); mask := op(ci, 2);
    b: Irb;
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    align := smmi_param_align(ci, 1);
    width := cast(u32) type_count(vtype(src));
    if smmi_is_constant_int_vector(mask) {
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            one := irb_extract_element(*b, src, idx, tconcat("Elt", tdec(idx)));
            p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
            irb_store(*b, one, p, align);
        }
        smmi_erase(ci);
        return false;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    f := block_fn(inst_block(ci));
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, true);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, smmi_unknown_weights(f), dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.store");
        irb_set_before(*b, block_terminator(cond_block));
        one := irb_extract_element(*b, src, idx, tconcat("Elt", tdec(idx)));
        p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
        irb_store(*b, one, p, align);
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        irb_set_at(*b, new_if, block_first(new_if), true);
    }
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedExpandLoad
smmi_masked_expand_load :: (ci: Value_Id, dtu: *Dtu) -> bool {
    ptr := op(ci, 0); mask := op(ci, 1); pass_thru := op(ci, 2);
    align := smmi_param_align(ci, 0);
    vec_ty := vtype(ci);
    elt_ty := type_elem(vec_ty);
    b: Irb;
    if_block := inst_block(ci);
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    width := cast(u32) type_count(vec_ty);
    vresult := pass_thru;
    adj := smmi_align_for(align, elt_ty);
    if smmi_is_constant_int_vector(mask) {
        mem_index: u32 = 0;
        vresult = const_poison(vec_ty);
        shuffle := NewArray(width, u32,, allocator = temp);
        for idx: 0..width - 1 {
            ins: Value_Id;
            if smmi_mask_elt_is_null(mask, idx) {
                ins = const_poison(elt_ty);
                shuffle[idx] = idx + width;
            } else {
                np := smmi_const_inbounds_gep(*b, elt_ty, ptr, mem_index);
                ins = irb_load(*b, elt_ty, np, adj, false, tconcat("Load", tdec(idx)));
                shuffle[idx] = idx;
                mem_index += 1;
            }
            vresult = irb_insert_element(*b, vresult, ins, idx, tconcat("Res", tdec(idx)));
        }
        vresult = irb_shuffle(*b, vresult, pass_thru, shuffle);
        rauw_with_metadata(ci, vresult);
        smmi_erase(ci);
        return false;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, true);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.load");
        irb_set_before(*b, block_terminator(cond_block));
        load := irb_load(*b, elt_ty, ptr, adj);
        nv := irb_insert_element(*b, vresult, load, idx);
        new_ptr: Value_Id = NONE;
        if idx + 1 != width new_ptr = smmi_const_inbounds_gep(*b, elt_ty, ptr, 1);
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        prev_if := if_block;
        if_block = new_if;
        irb_set_at(*b, new_if, block_first(new_if), true);
        rphi := irb_phi(*b, vec_ty, 2, "res.phi.else");
        phi_add_incoming(rphi, nv, cond_block);
        phi_add_incoming(rphi, vresult, prev_if);
        vresult = rphi;
        if idx + 1 != width {
            pphi := irb_phi(*b, vtype(ptr), 2, "ptr.phi.else");
            phi_add_incoming(pphi, new_ptr, cond_block);
            phi_add_incoming(pphi, ptr, prev_if);
            ptr = pphi;
        }
    }
    rauw_with_metadata(ci, vresult);
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedCompressStore
smmi_masked_compress_store :: (ci: Value_Id, dtu: *Dtu) -> bool {
    src := op(ci, 0); ptr := op(ci, 1); mask := op(ci, 2);
    align := smmi_param_align(ci, 1);
    vec_ty := vtype(src);
    b: Irb;
    if_block := inst_block(ci);
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    elt_ty := type_elem(vec_ty);
    adj := smmi_align_for(align, elt_ty);
    width := cast(u32) type_count(vec_ty);
    if smmi_is_constant_int_vector(mask) {
        mem_index: u32 = 0;
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            one := irb_extract_element(*b, src, idx, tconcat("Elt", tdec(idx)));
            np := smmi_const_inbounds_gep(*b, elt_ty, ptr, mem_index);
            irb_store(*b, one, np, adj);
            mem_index += 1;
        }
        smmi_erase(ci);
        return false;
    }
    sclr := smmi_scalar_mask(*b, mask, width);
    for idx: 0..width - 1 {
        pred := smmi_predicate(*b, sclr, mask, width, idx, true);
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.store");
        irb_set_before(*b, block_terminator(cond_block));
        one := irb_extract_element(*b, src, idx);
        irb_store(*b, one, ptr, adj);
        new_ptr: Value_Id = NONE;
        if idx + 1 != width new_ptr = smmi_const_inbounds_gep(*b, elt_ty, ptr, 1);
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        prev_if := if_block;
        if_block = new_if;
        irb_set_at(*b, new_if, block_first(new_if), true);
        if idx + 1 != width {
            pphi := irb_phi(*b, vtype(ptr), 2, "ptr.phi.else");
            phi_add_incoming(pphi, new_ptr, cond_block);
            phi_add_incoming(pphi, ptr, prev_if);
            ptr = pphi;
        }
    }
    smmi_erase(ci);
    return true;
}

// scalarizeMaskedVectorHistogram
smmi_masked_vector_histogram :: (ci: Value_Id, dtu: *Dtu) -> bool {
    ptrs := op(ci, 0); inc := op(ci, 1); mask := op(ci, 2);
    elt_ty := vtype(inc);
    b: Irb;
    irb_set_before(*b, ci);
    b.dbg = get_metadata(ci, 0);
    width := cast(u32) type_count(vtype(ptrs));
    id := call_iid(ci);
    update :: (b: *Irb, id: Intrinsic_Id, load: Value_Id, inc: Value_Id, elt_ty: Type_Id) -> Value_Id {
        if id == IID_EXPERIMENTAL_VECTOR_HISTOGRAM_ADD return irb_binop(b, .ADD, load, inc);
        iid: Intrinsic_Id;
        if id == IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UADD_SAT iid = IID_UADD_SAT;
        else if id == IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UMIN iid = IID_UMIN;
        else iid = IID_UMAX;
        f := get_or_insert_intrinsic_declaration(iid, .[elt_ty]);
        return irb_call(b, f, .[load, inc]);
    }
    if smmi_is_constant_int_vector(mask) {
        for idx: 0..width - 1 {
            if smmi_mask_elt_is_null(mask, idx) continue;
            p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
            load := irb_load(*b, elt_ty, p, dl_alignment(elt_ty, true), false, tconcat("Load", tdec(idx)));
            u := update(*b, id, load, inc, elt_ty);
            irb_store(*b, u, p, dl_alignment(elt_ty, true));
        }
        smmi_erase(ci);
        return false;
    }
    for idx: 0..width - 1 {
        pred := irb_extract_element(*b, mask, idx, tconcat("Mask", tdec(idx)));
        then_term := smmi_split_block_and_insert_if_then(pred, ci, NONE, dtu);
        cond_block := inst_block(then_term);
        set_name(cond_block, "cond.histogram.update");
        irb_set_before(*b, block_terminator(cond_block));
        p := irb_extract_element(*b, ptrs, idx, tconcat("Ptr", tdec(idx)));
        load := irb_load(*b, elt_ty, p, dl_alignment(elt_ty, true), false, tconcat("Load", tdec(idx)));
        u := update(*b, id, load, inc, elt_ty);
        irb_store(*b, u, p, dl_alignment(elt_ty, true));
        new_if := get_successor(then_term, 0);
        set_name(new_if, "else");
        irb_set_at(*b, new_if, block_first(new_if), true);
    }
    smmi_erase(ci);
    return true;
}

// optimizeCallInst: (changed, modified_dt)
smmi_optimize_call_inst :: (ci: Value_Id, t: *Tti, dtu: *Dtu) -> bool, bool {
    id := call_iid(ci);
    if id == NOT_INTRINSIC return false, false;
    if type_kind(vtype(ci)) == .SVECTOR return false, false;
    na := call_arg_count(ci);
    for k: 0..cast(s64) na - 1 if type_kind(vtype(op(ci, cast(u32) k))) == .SVECTOR return false, false;
    x86 := t.kind == .X86;
    if id == {
        case IID_EXPERIMENTAL_VECTOR_HISTOGRAM_ADD; #through;
        case IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UADD_SAT; #through;
        case IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UMIN; #through;
        case IID_EXPERIMENTAL_VECTOR_HISTOGRAM_UMAX;
            // isLegalMaskedVectorHistogram: false for X86 and the base implementation
            return true, smmi_masked_vector_histogram(ci, dtu);
        case IID_MASKED_LOAD;
            ty := vtype(ci);
            if x86 && x86_is_legal_masked_load(*t.xl, ty) return false, false;
            return true, smmi_masked_load(ci, dtu);
        case IID_MASKED_STORE;
            ty := vtype(op(ci, 0));
            if x86 && x86_is_legal_masked_load(*t.xl, ty) return false, false;
            return true, smmi_masked_store(ci, dtu);
        case IID_MASKED_GATHER;
            ty := vtype(ci);
            if x86 && x86_is_legal_masked_gather(*t.xl, ty) && !x86_force_scalarize_masked_gather(*t.xl, ty) return false, false;
            return true, smmi_masked_gather(ci, dtu);
        case IID_MASKED_SCATTER;
            ty := vtype(op(ci, 0));
            if x86 && x86_is_legal_masked_scatter(*t.xl, ty) && !x86_force_scalarize_masked_scatter(*t.xl, ty) return false, false;
            return true, smmi_masked_scatter(ci, dtu);
        case IID_MASKED_EXPANDLOAD;
            if x86 && x86_is_legal_masked_expand_load(*t.xl, vtype(ci)) return false, false;
            return true, smmi_masked_expand_load(ci, dtu);
        case IID_MASKED_COMPRESSSTORE;
            if x86 && x86_is_legal_masked_compress_store(*t.xl, vtype(op(ci, 0))) return false, false;
            return true, smmi_masked_compress_store(ci, dtu);
    }
    return false, false;
}

// runImpl
smmi_run_impl :: (f: Value_Id, dt: *Dom_Tree) -> bool {
    t := tti_get(f);
    dtu_storage: Dtu;
    dtu: *Dtu = null;
    if dt { dtu_storage.dt = dt; dtu_storage.lazy = true; dtu_storage.pending.allocator = temp; dtu_storage.deleted.allocator = temp; dtu = *dtu_storage; }
    ever := false;
    made := true;
    while made {
        made = false;
        bb := fn_entry(f);
        while bb != NONE {
            nbb := block(bb).next;   // make_early_inc_range(F)
            modified_dt := false;
            // optimizeBlock
            i := block_first(bb);
            while i != NONE {
                ci := i;
                i = inst_next(i);
                if inst_op(ci) == .CALL {
                    changed, mdt := smmi_optimize_call_inst(ci, t, dtu);
                    made |= changed;
                    if mdt { modified_dt = true; break; }
                }
            }
            if modified_dt break;
            bb = nbb;
        }
        ever |= made;
    }
    if dtu dtu_flush(dtu);   // ~DomTreeUpdater
    return ever;
}

// ScalarizeMaskedMemIntrinPass::run (opt): the cached dominator tree
scalarize_masked_mem_intrin_opt_run :: (f: Value_Id) -> Preserved {
    if !smmi_run_impl(f, cached_domtree(f)) return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
// The legacy pass in llc's IR pipeline: getAnalysisIfAvailable<DominatorTreeWrapperPass>
scalarize_masked_mem_intrin_run :: (f: Value_Id) -> Preserved {
    if !smmi_run_impl(f, cached_domtree(f)) return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}
