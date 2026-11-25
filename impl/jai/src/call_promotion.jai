// Call promotion: ported from llvm/lib/Transforms/Utils/CallPromotionUtils.cpp (isLegalToPromote, versionCallSite,
// versionCallSiteWithCond, createRetPHINode, fixupPHINodeFor{Normal,Unwind}Dest, promoteCallWithIfThenElse;
// promoteCall is atr_promote_call in attributor_cleanup.jai) and pgo::promoteIndirectCall
// (llvm/lib/Transforms/Instrumentation/IndirectCallPromotion.cpp), createBranchWeights / calculateCountScale /
// scaleBranchCount (llvm/include/llvm/Transforms/Instrumentation/PGOInstrumentation.h, PGOInstrumentation.cpp).

// isLegalToPromote, with the target feature check
cp_is_legal_to_promote :: (cb: Value_Id, callee: Value_Id) -> bool {
    if !atr_is_legal_to_promote(cb, callee) return false;
    callee_feats := sp_fn_str_attr(callee, "target-features");
    caller_feats := sp_fn_str_attr(inst_fn(cb), "target-features");
    s := callee_feats;
    while true {
        k := sr_find(s, #char ",");
        feat := sr_substr(s, 0, k);
        if begins_with(feat, "+") && sr_find_str(caller_feats, feat) == SR_NPOS return false;
        if k == SR_NPOS break;
        s = sr_substr(s, k + 1);
    }
    return true;
}

// calculateCountScale / scaleBranchCount / createBranchWeights(Ctx, TrueWeight, FalseWeight)
pgo_count_scale :: (max_count: u64) -> u64 { if max_count < 0xFFFF_FFFF return 1; return max_count / 0xFFFF_FFFF + 1; }
pgo_scale_branch_count :: (c: u64, scale: u64) -> u32 { return cast(u32) (c / scale); }
pgo_create_branch_weights :: (t: u64, f: u64) -> Md_Id {
    scale := pgo_count_scale(max(t, f));
    i32 := ir.t_i32;
    return md_tuple(.[md_string("branch_weights"), md_value(const_int(i32, pgo_scale_branch_count(t, scale))),
                      md_value(const_int(i32, pgo_scale_branch_count(f, scale)))], false);
}

// fixupPHINodeForNormalDest
cp_fixup_phi_normal :: (invoke: Value_Id, orig: Value_Id, merge: Value_Id) {
    dest := get_successor(invoke, 0);
    for p: block_insts(dest) {
        if inst_op(p) != .PHI break;
        k := phi_block_index(p, orig);
        if k < 0 continue;
        phi_set_incoming_block(p, cast(u32) k, merge);
    }
}
// fixupPHINodeForUnwindDest
cp_fixup_phi_unwind :: (invoke: Value_Id, orig: Value_Id, then_b: Value_Id, else_b: Value_Id) {
    dest := get_successor(invoke, 1);
    for p: block_insts(dest) {
        if inst_op(p) != .PHI break;
        k := phi_block_index(p, orig);
        if k < 0 continue;
        v := op(p, cast(u32) k);
        phi_set_incoming_block(p, cast(u32) k, then_b);
        phi_add_incoming(p, v, else_b);
    }
}
phi_set_incoming_block :: (p: Value_Id, k: u32, b: Value_Id) { ir.u_aux[ir.v_ops[p] + k] = b; }

// createRetPHINode
cp_create_ret_phi :: (orig: Value_Id, new: Value_Id, merge: Value_Id) {
    if vtype(orig) == ir.t_void || ir.v_first_use[orig] == NONE return;
    phi := create_phi(vtype(orig), 0);
    first := block_first(merge);
    // IRBuilder::SetInsertPoint(MergeBlock, begin()) takes the first instruction's debug location
    if first != NONE { d := get_metadata(first, 0); if d != NONE set_metadata(phi, 0, d); }
    insert_at_position(phi, merge, first, true);
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[orig];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for users replace_uses_of_with(it, orig, phi);
    phi_add_incoming(phi, orig, inst_block(orig));
    phi_add_incoming(phi, new, inst_block(new));
}

// versionCallSite + versionCallSiteWithCond: the new call (in the "then" block)
cp_version_call_site :: (cb: Value_Id, callee: Value_Id, weights: Md_Id) -> Value_Id {
    called := call_callee(cb);
    c := callee;
    if vtype(called) != vtype(c) fatal("call promotion: a callee of another pointer type (bitcast) is not supported");
    cond := create_icmp(ICMP_EQ, called, c);
    // IRBuilder<> Builder(&CB): inserted before the call with its debug location
    d := get_metadata(cb, 0);
    if d != NONE set_metadata(cond, 0, d);
    insert_at_position(cond, inst_block(cb), cb, false);
    orig_block := inst_block(cb);
    if call_is_must_tail(cb) {
        then_term := sbi_if_then(cond, cb, false, weights);
        then_b := inst_block(then_term);
        set_name(then_b, "if.true.direct_targ");
        ni := ic_clone_inst(cb);
        inst_insert_before(ni, then_term);
        new_ret := ni;
        next := inst_next(cb);
        if next != NONE && inst_op(next) == .BITCAST {
            nb := ic_clone_inst(next);
            replace_uses_of_with(nb, cb, ni);
            inst_insert_before(nb, then_term);
            new_ret = nb;
            next = inst_next(next);
        }
        nr := ic_clone_inst(next);
        if nops(next) > 0 replace_uses_of_with(nr, op(next, 0), new_ret);
        inst_insert_before(nr, then_term);
        erase_inst(then_term);
        return ni;
    }
    then_term, else_term := sbi_if_then_else(cond, cb, true, false, true, false, weights);
    then_b := inst_block(then_term);
    else_b := inst_block(else_term);
    merge := inst_block(cb);
    set_name(then_b, "if.true.direct_targ");
    set_name(else_b, "if.false.orig_indirect");
    set_name(merge, "if.end.icp");
    ni := ic_clone_inst(cb);
    inst_move_before(cb, else_term);
    inst_insert_before(ni, then_term);
    if inst_op(cb) == .INVOKE {
        erase_inst(then_term);
        erase_inst(else_term);
        normal := get_successor(cb, 0);
        br := create_br(normal);
        block_append_inst(merge, br);
        cp_fixup_phi_normal(cb, orig_block, merge);
        cp_fixup_phi_unwind(cb, merge, then_b, else_b);
        set_successor(cb, 0, merge);
        set_successor(ni, 0, merge);
    }
    cp_create_ret_phi(cb, ni, merge);
    return ni;
}

// promoteCallWithIfThenElse
cp_promote_call_with_if_then_else :: (cb: Value_Id, callee: Value_Id, weights: Md_Id) -> Value_Id {
    ni := cp_version_call_site(cb, callee, weights);
    atr_promote_call(ni, callee);
    return ni;
}

// pgo::promoteIndirectCall
pgo_promote_indirect_call :: (cb: Value_Id, callee: Value_Id, count: u64, total: u64, attach_prof: bool) -> Value_Id {
    ni := cp_promote_call_with_if_then_else(cb, callee, pgo_create_branch_weights(count, total - count));
    if attach_prof prof_set_fitted_branch_weights(ni, .[count], false);
    return ni;
}
