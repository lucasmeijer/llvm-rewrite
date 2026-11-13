// LowerMemIntrinsics: a port of the parts of llvm/lib/Transforms/Utils/LowerMemIntrinsics.cpp that x86-64's
// PreISelIntrinsicLowering reaches: insertLoopExpansion, createMemCpyLoopUnknownSize (llvm.memcpy.inline with a
// non-constant length), createMemSetLoopUnknownSize (llvm.memset.inline with a non-constant length),
// createMemSetPatternLoop (llvm.experimental.memset.pattern), createMemSetSplat, getAverageMemOpLoopTripCount.
//
// x86's TTI does not override getMemcpyLoopLoweringType, so every loop operates on i8 (memset.pattern on the pattern
// type). Not ported: the known-size memcpy / memset loops and the memmove loops (x86-64 always has the memcpy,
// memmove and memset libcalls, so only the .inline variants with a variable length are expanded), atomic element
// memcpy, and ScalarEvolution-based overlap checks (PreISelIntrinsicLowering passes none: CanOverlap is true).

LMI_DEBUG_TYPE :: "lower-mem-intrinsics";

Lmi_Loop_Expansion :: struct {
    main_ip: Value_Id = NONE;
    main_index: Value_Id = NONE;
    residual_ip: Value_Id = NONE;
    residual_index: Value_Id = NONE;
}

// getValueProfDataFromInst(I, IPVK_MemOPSize, UINT32_MAX, Total): (total, sum of count * value)
lmi_mem_op_value_profile :: (i: Value_Id) -> (u64, u64) {
    m := prof_md(i);
    if m == NONE || md_nops(m) < 3 return 0, 0;
    s := md_op(m, 0);
    if s == NONE || ir.mds[s].kind != .STRING || ir.mds[s].str != "VP" return 0, 0;
    kind := const_int_zext(md_const_int_op(m, 1));
    if kind != 1 return 0, 0;   // IPVK_MemOPSize
    total := const_int_zext(md_const_int_op(m, 2));
    trip: u64 = 0;
    n := md_nops(m);
    k: u32 = 3;
    while k + 1 < n {
        v := const_int_zext(md_const_int_op(m, k));
        c := const_int_zext(md_const_int_op(m, k + 1));
        trip += c * v;
        k += 2;
    }
    return total, trip;
}
// getAverageMemOpLoopTripCount
lmi_average_trip_count :: (i: Value_Id) -> (bool, u64) {
    ok, ec := fn_entry_count(inst_fn(i));
    if !ok || ec == 0 return false, 0;
    len := call_arg(i, 2);
    if vkind(len) == .C_INT return true, const_int_zext(len);
    total, trip := lmi_mem_op_value_profile(i);
    if total == 0 return false, 0;
    q := cast(float64) trip / cast(float64) total;
    return true, cast(u64) (q + 0.5);   // std::round of a non-negative value
}

lmi_likely_branch_weights :: (br: Value_Id) { set_branch_weights(br, .[cast(u32) (1 << 20) - 1, 1]); }   // createLikelyBranchWeights

// insertLoopExpansion
lmi_insert_loop_expansion :: (insert_before: Value_Id, len: Value_Id, main_step: u64, residual_step: u64, prefix: string, has_expected: bool, expected: u64) -> Lmi_Loop_Expansion {
    lei: Lmi_Loop_Expansion;
    if vkind(len) == .C_INT && const_int_zext(len) == 0 return lei;
    pre := inst_block(insert_before);
    post := split_basic_block(pre, insert_before, tconcat(prefix, "-post-expansion"));
    f := block_fn(pre);
    dbg := get_metadata(insert_before, MDK_DBG);
    pb: Irb; irb_set_before(*pb, block_terminator(pre)); pb.dbg = dbg;
    lt := vtype(len);
    zero := const_int(lt, 0);
    must_main := false; may_main := true; must_res := false; may_res := true;
    loop_units := len;
    residual_units: Value_Id = NONE;
    if main_step != 1 {
        if vkind(len) == .C_INT {
            total := const_int_zext(len);
            end := total - total % main_step;
            res := total - end;
            loop_units = const_int(lt, end);
            residual_units = const_int(lt, res);
            must_main = end > 0; may_main = must_main;
            must_res = res > 0; may_res = must_res;
        } else {
            step_c := const_int(lt, main_step);
            if (main_step & (main_step - 1)) == 0 residual_units = irb_binop(*pb, .AND, len, const_int(lt, main_step - 1));
            else residual_units = irb_binop(*pb, .UREM, len, step_c);
            loop_units = irb_binop(*pb, .SUB, len, residual_units);
        }
    } else if vkind(len) == .C_INT {
        must_main = const_int_zext(len) > 0; may_main = must_main;
    }
    main_bb: Value_Id = NONE;
    main_br: Value_Id = NONE;
    if may_main {
        main_bb = create_block(f, tconcat(prefix, "-expansion-main-body"), post);
        lb: Irb; irb_set_end(*lb, main_bb); lb.dbg = dbg;
        idx := irb_phi(*lb, lt, 2, "loop-index");
        lei.main_index = idx;
        phi_add_incoming(idx, const_int(lt, 0), pre);
        nidx := irb_binop(*lb, .ADD, idx, const_int(lt, main_step));
        phi_add_incoming(idx, nidx, main_bb);
        lei.main_ip = nidx;
        cmp := irb_insert(*lb, create_icmp(ICMP_ULT, nidx, loop_units));
        main_br = irb_insert(*lb, create_cond_br(cmp, main_bb, post));
        if has_expected {
            btc := expected / main_step;
            if btc > 0 btc -= 1;
            set_fitted_branch_weights(main_br, .[btc, 1]);
        } else set_explicitly_unknown_branch_weights_if_profiled(main_br, LMI_DEBUG_TYPE);
    }
    res_requested := residual_step > 0 && residual_step < main_step;
    res_bb: Value_Id = NONE;
    res_cond_bb: Value_Id = NONE;
    if res_requested && may_res {
        res_bb = create_block(f, tconcat(prefix, "-expansion-residual-body"), post);
        pred_of_res := pre;
        if main_bb != NONE {
            if must_res {
                set_successor(main_br, 1, res_bb);
                pred_of_res = main_bb;
            } else {
                res_cond_bb = create_block(f, tconcat(prefix, "-expansion-residual-cond"), res_bb);
                rc: Irb; irb_set_end(*rc, res_cond_bb); rc.dbg = dbg;
                c := irb_insert(*rc, create_icmp(ICMP_NE, residual_units, zero));
                br := irb_insert(*rc, create_cond_br(c, res_bb, post));
                if has_expected lmi_likely_branch_weights(br);
                else set_explicitly_unknown_branch_weights_if_profiled(br, LMI_DEBUG_TYPE);
                set_successor(main_br, 1, res_cond_bb);
                pred_of_res = res_cond_bb;
            }
        }
        rb: Irb; irb_set_end(*rb, res_bb); rb.dbg = dbg;
        ridx := irb_phi(*rb, lt, 2, "residual-loop-index");
        phi_add_incoming(ridx, zero, pred_of_res);
        if main_bb != NONE lei.residual_index = irb_binop(*rb, .ADD, loop_units, ridx);
        else lei.residual_index = ridx;
        rnidx := irb_binop(*rb, .ADD, ridx, const_int(lt, residual_step));
        phi_add_incoming(ridx, rnidx, res_bb);
        lei.residual_ip = rnidx;
        c := irb_insert(*rb, create_icmp(ICMP_ULT, rnidx, residual_units));
        br := irb_insert(*rb, create_cond_br(c, res_bb, post));
        if has_expected {
            btc := (expected % main_step) / residual_step;
            if btc > 0 btc -= 1;
            set_fitted_branch_weights(br, .[btc, 1]);
        } else set_explicitly_unknown_branch_weights_if_profiled(br, LMI_DEBUG_TYPE);
    }
    if must_main {
        irb_insert(*pb, create_br(main_bb));
    } else if main_bb == NONE && res_bb != NONE {
        if must_res irb_insert(*pb, create_br(res_bb));
        else {
            c := irb_insert(*pb, create_icmp(ICMP_NE, residual_units, zero));
            br := irb_insert(*pb, create_cond_br(c, res_bb, post));
            if has_expected lmi_likely_branch_weights(br);
            else set_explicitly_unknown_branch_weights_if_profiled(br, LMI_DEBUG_TYPE);
        }
    } else {
        false_bb := post;
        if res_cond_bb != NONE false_bb = res_cond_bb;
        else if res_bb != NONE false_bb = res_bb;
        c := irb_insert(*pb, create_icmp(ICMP_NE, loop_units, zero));
        br := irb_insert(*pb, create_cond_br(c, main_bb, false_bb));
        if has_expected lmi_likely_branch_weights(br);
        else set_explicitly_unknown_branch_weights_if_profiled(br, LMI_DEBUG_TYPE);
    }
    // delete the unconditional branch splitBasicBlock inserted
    t := block_terminator(pre);
    erase_inst(t);
    return lei;
}

// commonAlignment(A, Offset)
lmi_common_alignment :: (a: u64, offset: u64) -> u64 { return min_align(a, offset); }

lmi_dest_align :: (mi: Value_Id) -> u64 {
    a := call_param_attr(mi, 0, .Alignment);
    if a return a.ival;
    return 1;
}
lmi_src_align :: (mi: Value_Id) -> u64 {
    a := call_param_attr(mi, 1, .Alignment);
    if a return a.ival;
    return 1;
}
lmi_is_volatile :: (mi: Value_Id) -> bool { v := call_arg(mi, 3); return vkind(v) == .C_INT && !is_null_value(v); }

lmi_store :: (b: *Irb, v: Value_Id, ptr: Value_Id, align: u64, volatile: bool) -> Value_Id { return irb_store(b, v, ptr, align, volatile); }

// expandMemCpyAsLoop for a non-constant length: createMemCpyLoopUnknownSize (CanOverlap, no atomic element size)
lmi_expand_memcpy_unknown_size :: (mi: Value_Id) {
    dst := call_arg(mi, 0); src := call_arg(mi, 1); len := call_arg(mi, 2);
    src_align := lmi_src_align(mi); dst_align := lmi_dest_align(mi);
    volatile := lmi_is_volatile(mi);
    has_tc, tc := lmi_average_trip_count(mi);
    // the anonymous alias scope domain and scope are created but unused (CanOverlap)
    i8 := type_int(8);
    lei := lmi_insert_loop_expansion(mi, len, 1, 1, "dynamic-memcpy", has_tc, tc);
    mb: Irb; irb_set_before(*mb, lei.main_ip);
    psa := lmi_common_alignment(src_align, 1);
    pda := lmi_common_alignment(dst_align, 1);
    sg := irb_gep(*mb, i8, src, .[lei.main_index], "", F_INBOUNDS);
    ld := irb_load(*mb, i8, sg, psa, volatile);
    dg := irb_gep(*mb, i8, dst, .[lei.main_index], "", F_INBOUNDS);
    lmi_store(*mb, ld, dg, pda, volatile);
    if lei.residual_ip != NONE fatal("internal: lower-mem-intrinsics: unexpected residual loop for an i8 memcpy loop");
}

// createMemSetSplat
lmi_mem_set_splat :: (b: *Irb, v: Value_Id, dst_type: Type_Id) -> Value_Id {
    dst_size := dl_type_store_size(dst_type);
    vt := vtype(v);
    vsize := dl_type_store_size(vt);
    r := v;
    if dst_size != vsize {
        if !is_int_type(vt) && !is_fp_type(vt) r = irb_bitcast(b, r, type_int(cast(u32) (vsize * 8)), "setvalue.toint");
        r = irb_vector_splat(b, dst_size / vsize, r, "setvalue.splat");
    }
    return irb_bitcast(b, r, dst_type, "setvalue.splat.cast");
}

// expandMemSetAsLoop for a non-constant length: createMemSetLoopUnknownSize
lmi_expand_memset_unknown_size :: (mi: Value_Id) {
    dst := call_arg(mi, 0); val := call_arg(mi, 1); len := call_arg(mi, 2);
    dst_align := lmi_dest_align(mi);
    volatile := lmi_is_volatile(mi);
    has_tc, tc := lmi_average_trip_count(mi);
    i8 := type_int(8);
    pre: Irb; irb_set_before(*pre, mi);
    splat := lmi_mem_set_splat(*pre, val, i8);
    lei := lmi_insert_loop_expansion(mi, len, 1, 1, "dynamic-memset", has_tc, tc);
    mb: Irb; irb_set_before(*mb, lei.main_ip);
    pda := lmi_common_alignment(dst_align, 1);
    dg := irb_gep(*mb, i8, dst, .[lei.main_index], "", F_INBOUNDS);
    lmi_store(*mb, splat, dg, pda, volatile);
    if lei.residual_ip != NONE fatal("internal: lower-mem-intrinsics: unexpected residual loop for an i8 memset loop");
}

// expandMemSetPatternAsLoop: createMemSetPatternLoop (the preferred loop type is i8, so the pattern type is used)
lmi_expand_memset_pattern :: (mi: Value_Id) {
    dst := call_arg(mi, 0); val := call_arg(mi, 1); len := call_arg(mi, 2);
    if vkind(len) == .C_INT && const_int_zext(len) == 0 return;
    dst_align := lmi_dest_align(mi);
    volatile := lmi_is_volatile(mi);
    has_tc, tc := lmi_average_trip_count(mi);
    ot := vtype(val);
    alloc := dl_type_alloc_size(ot);
    lei := lmi_insert_loop_expansion(mi, len, 1, 0, "memset.pattern", has_tc, tc);
    pda := lmi_common_alignment(dst_align, alloc);
    if lei.main_ip != NONE {
        mb: Irb; irb_set_before(*mb, lei.main_ip);
        dg := irb_gep(*mb, ot, dst, .[lei.main_index], "", F_INBOUNDS);
        lmi_store(*mb, val, dg, pda, volatile);
    }
}
