// LoopFlatten (loop-flatten, a LoopNest pass): port of llvm/lib/Transforms/Scalar/LoopFlatten.cpp. A pair of
// perfectly nested counted loops whose IVs are only used as `outer * InnerTripCount + inner` is turned into one loop
// of OuterTripCount * InnerTripCount iterations (widening the IVs first when that proves the product cannot
// overflow, or versioning the loop on an umul.with.overflow check).

lf_cl: struct {
    repeated_instruction_threshold: s64 = 2;   // -loop-flatten-cost-threshold
    assume_no_overflow := false;               // -loop-flatten-assume-no-overflow
    widen_iv := true;                          // -loop-flatten-widen-iv
    version_loops := true;                     // -loop-flatten-version-loops
};

lf_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_b :: (dst: *bool, value: string, has_value: bool, name: string) {
        if !has_value { dst.* = true; return; }
        if value == "true" || value == "1" || value == "TRUE" || value == "True" dst.* = true;
        else if value == "false" || value == "0" || value == "FALSE" || value == "False" dst.* = false;
        else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
    }
    if name == {
        case "loop-flatten-assume-no-overflow"; parse_b(*lf_cl.assume_no_overflow, value, has_value, name);
        case "loop-flatten-widen-iv"; parse_b(*lf_cl.widen_iv, value, has_value, name);
        case "loop-flatten-version-loops"; parse_b(*lf_cl.version_loops, value, has_value, name);
        case "loop-flatten-cost-threshold";
            if !has_value fatal("opt: for the --% option: requires a value!", name);
            v, ok, rest := string_to_int(value);
            if !ok || rest.count || v < 0 fatal("opt: for the --% option: '%' value invalid for uint argument!", name, value);
            lf_cl.repeated_instruction_threshold = v;
        case; return false;
    }
    return true;
}

// FlattenInfo
Flatten_Info :: struct {
    outer_loop: Loop_Id = NONE;
    inner_loop: Loop_Id = NONE;
    inner_induction_phi: Value_Id = NONE;
    outer_induction_phi: Value_Id = NONE;
    inner_trip_count: Value_Id = NONE;
    outer_trip_count: Value_Id = NONE;
    linear_iv_uses: [..] Value_Id;          // SmallPtrSet<Value *, 4> (insertion order; see lf_do_flatten_loop_pair)
    inner_increment: Value_Id = NONE;
    outer_increment: Value_Id = NONE;
    inner_branch: Value_Id = NONE;
    outer_branch: Value_Id = NONE;
    inner_phis_to_transform: [..] Value_Id; // SmallPtrSet<PHINode *, 4> (only removeIncomingValue: order-free)
    widened: bool;
    narrow_inner_induction_phi: Value_Id = NONE;
    narrow_outer_induction_phi: Value_Id = NONE;
    new_trip_count: Value_Id = NONE;
}

lf_set_insert :: (s: *[..] Value_Id, v: Value_Id) -> bool {
    for s.* if it == v return false;
    array_add(s, v);
    return true;
}
lf_set_contains :: (s: [] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }

lf_is_narrow_induction_phi :: (fi: *Flatten_Info, phi: Value_Id) -> bool {
    if !fi.widened return false;
    return fi.narrow_inner_induction_phi == phi || fi.narrow_outer_induction_phi == phi;
}

// checkOuterInductionPhiUsers
lf_check_outer_induction_phi_users :: (fi: *Flatten_Info, valid_outer_phi_uses: [] Value_Id) -> bool {
    for u: sx_users(fi.outer_induction_phi) {
        if u == fi.outer_increment continue;
        if is_inst(u) && inst_op(u) == .TRUNC {
            for k: sx_users(u) if !lf_set_contains(valid_outer_phi_uses, k) return false;
            continue;
        }
        if !lf_set_contains(valid_outer_phi_uses, u) return false;
    }
    return true;
}

// match(V, m_c_<Opc>(m_Specific(X), m_Value(Bound))) for a binary instruction: (matched, bound)
lf_match_c_binop_specific :: (v: Value_Id, opc: Opcode, x: Value_Id, trunc_of_x: bool) -> (bool, Value_Id) {
    if !is_inst(v) || inst_op(v) != opc return false, NONE;
    is_x :: (o: Value_Id, x: Value_Id, trunc_of_x: bool) -> bool {
        if !trunc_of_x return o == x;
        return is_inst(o) && inst_op(o) == .TRUNC && op(o, 0) == x;   // m_Trunc(m_Specific(X))
    }
    if is_x(op(v, 0), x, trunc_of_x) return true, op(v, 1);
    if is_x(op(v, 1), x, trunc_of_x) return true, op(v, 0);
    return false, NONE;
}

// matchLinearIVUser
lf_match_linear_iv_user :: (fi: *Flatten_Info, u: Value_Id, inner_trip_count: Value_Id, valid_outer_phi_uses: *[..] Value_Id) -> bool {
    matched_mul: Value_Id = NONE;
    matched_it_count: Value_Id = NONE;
    // the m_Value bindings persist from one pattern to the next, as in LLVM
    is_add := false;
    {
        ok, m := lf_match_c_binop_specific(u, .ADD, fi.inner_induction_phi, false);
        if ok {
            matched_mul = m;
            ok2, c := lf_match_c_binop_specific(matched_mul, .MUL, fi.outer_induction_phi, false);
            if ok2 { matched_it_count = c; is_add = true; }
        }
    }
    is_add_trunc := false;
    {
        ok, m := lf_match_c_binop_specific(u, .ADD, fi.inner_induction_phi, true);
        if ok {
            matched_mul = m;
            ok2, c := lf_match_c_binop_specific(matched_mul, .MUL, fi.outer_induction_phi, true);
            if ok2 { matched_it_count = c; is_add_trunc = true; }
        }
    }
    is_gep := false;
    // m_GEP(m_GEP(m_Value(), m_Value(MatchedMul)), m_Specific(InnerInductionPHI)): operands left to right, so
    // MatchedMul is bound before the outer index is checked
    if is_inst(u) && inst_op(u) == .GEP && nops(u) == 2 {
        inner := op(u, 0);
        if is_inst(inner) && inst_op(inner) == .GEP && nops(inner) == 2 {
            matched_mul = op(inner, 1);
            if op(u, 1) == fi.inner_induction_phi {
                ok2, c := lf_match_c_binop_specific(matched_mul, .MUL, fi.outer_induction_phi, false);
                if ok2 { matched_it_count = c; is_gep = true; }
            }
        }
    }
    if matched_it_count == NONE return false;
    live := 0;
    for x: sx_users(matched_mul) if !is_instruction_trivially_dead(x) live += 1;
    if live > 1 return false;
    if fi.widened && (is_add || is_gep) && is_inst(matched_it_count) &&
       (inst_op(matched_it_count) == .SEXT || inst_op(matched_it_count) == .ZEXT)
        matched_it_count = op(matched_it_count, 0);
    if (is_add || is_add_trunc || is_gep) && matched_it_count == inner_trip_count {
        lf_set_insert(valid_outer_phi_uses, matched_mul);
        lf_set_insert(*fi.linear_iv_uses, u);
        return true;
    }
    return false;
}

// checkInnerInductionPhiUsers
lf_check_inner_induction_phi_users :: (fi: *Flatten_Info, valid_outer_phi_uses: *[..] Value_Id) -> bool {
    sext_inner_trip_count := fi.inner_trip_count;
    if fi.widened && is_inst(fi.inner_trip_count) && (inst_op(fi.inner_trip_count) == .SEXT || inst_op(fi.inner_trip_count) == .ZEXT)
        sext_inner_trip_count = op(fi.inner_trip_count, 0);
    for u_in: sx_users(fi.inner_induction_phi) {
        u := u_in;
        if u == fi.inner_increment continue;
        if is_inst(u) && inst_op(u) == .TRUNC {
            if !has_one_use(u) return false;
            u = ir.u_user[ir.v_first_use[u]];
        }
        if op(fi.inner_branch, 0) == u continue;   // isInnerLoopTest
        if !lf_match_linear_iv_user(fi, u, sext_inner_trip_count, valid_outer_phi_uses) return false;
    }
    return true;
}


// verifyTripCount (with setLoopComponents): (ok, TripCount)
lf_verify_trip_count :: (rhs: Value_Id, l: Loop_Id, increment: Value_Id, iteration_instructions: *[..] Value_Id, is_widened: bool) -> (bool, Value_Id) {
    btc := sc_get_backedge_taken_count(l);
    if sc_is_cnc(btc) return false, NONE;
    scev_trip_count := sc_get_trip_count_from_exit_count_ty(btc, sc_type(btc), l);
    scev_rhs := sc_get_scev(rhs);
    if scev_rhs == scev_trip_count { lf_set_insert(iteration_instructions, increment); return true, rhs; }
    if vkind(rhs) == .C_INT {
        btc_ext: Scev_Id = SCEV_CNC;
        has_ext := false;
        if is_widened {
            btc_ext = sc_get_zero_extend(btc, vtype(rhs));
            has_ext = true;
            trip_ext := sc_get_trip_count_from_exit_count_ty(btc_ext, vtype(rhs), l);
            if scev_rhs != btc_ext && scev_rhs != trip_ext return false, NONE;
        }
        if (has_ext && scev_rhs == btc_ext) || scev_rhs == btc {
            new_rhs := const_int_ap(vtype(rhs), ap_add(const_ap(rhs), ap_one(type_bits(vtype(rhs)))));
            lf_set_insert(iteration_instructions, increment);
            return true, new_rhs;
        }
        lf_set_insert(iteration_instructions, increment);
        return true, rhs;
    }
    if !is_widened return false, NONE;
    if !is_inst(rhs) return false, NONE;
    if (inst_op(rhs) != .ZEXT && inst_op(rhs) != .SEXT) || sc_get_scev(op(rhs, 0)) != scev_trip_count return false, NONE;
    lf_set_insert(iteration_instructions, increment);
    return true, rhs;
}

// Loop::isCanonical(SE)
lf_loop_is_canonical :: (l: Loop_Id) -> bool {
    iv := li_induction_variable(l);
    if iv == NONE return false;
    ok, start, step, bo := is_induction_phi(iv, l);
    if !ok return false;
    if start == NONE || vkind(start) != .C_INT || !ap_is_zero(const_ap(start)) return false;
    if bo == NONE || inst_op(bo) != .ADD return false;
    if !sc_is_const(step) || !ap_is_one(sc_ap(step)) return false;
    return true;
}

// findLoopComponents: (ok, InductionPHI, TripCount, Increment, BackBranch)
lf_find_loop_components :: (li: *Loop_Info, l: Loop_Id, iteration_instructions: *[..] Value_Id, is_widened: bool) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id) {
    if !li_is_loop_simplify_form(li, l) return false, NONE, NONE, NONE, NONE;
    if !lf_loop_is_canonical(l) return false, NONE, NONE, NONE, NONE;
    latch := li_loop_latch(li, l);
    if li_exiting_block(li, l) != latch return false, NONE, NONE, NONE, NONE;
    induction_phi := li_induction_variable(l);
    if induction_phi == NONE return false, NONE, NONE, NONE, NONE;
    continue_on_true := li_contains(li, l, get_successor(block_terminator(latch), 0));
    compare := li_latch_cmp_inst(li, l);
    if compare == NONE return false, NONE, NONE, NONE, NONE;
    up := icmp_unsigned_predicate(inst(compare).pred);
    valid := ifx continue_on_true then (up == ICMP_NE || up == ICMP_ULT) else up == ICMP_EQ;
    if !valid || has_n_uses_or_more(compare, 2) return false, NONE, NONE, NONE, NONE;
    back_branch := block_terminator(latch);
    lf_set_insert(iteration_instructions, back_branch);
    lf_set_insert(iteration_instructions, compare);
    increment := phi_incoming_value_for_block(induction_phi, latch);
    if (op(compare, 0) != increment || !has_n_uses(increment, 2)) && !has_n_uses(increment, 1) return false, NONE, NONE, NONE, NONE;
    rhs := op(compare, 1);
    ok, tc := lf_verify_trip_count(rhs, l, increment, iteration_instructions, is_widened);
    return ok, induction_phi, tc, increment, back_branch;
}

// checkPHIs
lf_check_phis :: (fi: *Flatten_Info, li: *Loop_Info) -> bool {
    safe_outer_phis: [..] Value_Id; safe_outer_phis.allocator = temp;
    array_add(*safe_outer_phis, fi.outer_induction_phi);
    for inner_phi: block_insts(li_header(li, fi.inner_loop)) {
        if inst_op(inner_phi) != .PHI break;
        if inner_phi == fi.inner_induction_phi continue;
        if lf_is_narrow_induction_phi(fi, inner_phi) continue;
        pre_header_value := phi_incoming_value_for_block(inner_phi, li_loop_preheader(li, fi.inner_loop));
        latch_value := phi_incoming_value_for_block(inner_phi, li_loop_latch(li, fi.inner_loop));
        outer_phi := pre_header_value;
        if !is_inst(outer_phi) || inst_op(outer_phi) != .PHI || inst_block(outer_phi) != li_header(li, fi.outer_loop) return false;
        lcssa_phi := phi_incoming_value_for_block(outer_phi, li_loop_latch(li, fi.outer_loop));
        if !is_inst(lcssa_phi) || inst_op(lcssa_phi) != .PHI return false;
        if phi_has_constant_value(lcssa_phi) != latch_value return false;
        lf_set_insert(*safe_outer_phis, outer_phi);
        lf_set_insert(*fi.inner_phis_to_transform, inner_phi);
    }
    for outer_phi: block_insts(li_header(li, fi.outer_loop)) {
        if inst_op(outer_phi) != .PHI break;
        if lf_is_narrow_induction_phi(fi, outer_phi) continue;
        if !lf_set_contains(safe_outer_phis, outer_phi) return false;
    }
    return true;
}

// checkOuterLoopInsts
lf_check_outer_loop_insts :: (fi: *Flatten_Info, li: *Loop_Info, iteration_instructions: [] Value_Id, tti: *Tti) -> bool {
    repeated: Cost = 0;
    for b: li_blocks(li, fi.outer_loop) {
        if li_contains(li, fi.inner_loop, b) continue;
        for i: block_insts(b) {
            if inst_op(i) != .PHI && !is_terminator(inst_op(i)) && !is_safe_to_speculatively_execute_cx(i, NONE, null) return false;
            if lf_set_contains(iteration_instructions, i) continue;
            if inst_op(i) == .BR && get_successor(i, 0) == li_header(li, fi.inner_loop) continue;
            if inst_op(i) == .MUL && ((op(i, 0) == fi.outer_induction_phi && op(i, 1) == fi.inner_trip_count) ||
                                     (op(i, 1) == fi.outer_induction_phi && op(i, 0) == fi.inner_trip_count)) continue;
            repeated += tti_instruction_cost(tti, i, TCK_SIZE_AND_LATENCY);
        }
    }
    if repeated > lf_cl.repeated_instruction_threshold return false;
    return true;
}

// checkIVUsers
lf_check_iv_users :: (fi: *Flatten_Info) -> bool {
    valid: [..] Value_Id; valid.allocator = temp;
    if !lf_check_inner_induction_phi_users(fi, *valid) return false;
    if !lf_check_outer_induction_phi_users(fi, valid) return false;
    return true;
}

// checkOverflow
lf_check_overflow :: (fi: *Flatten_Info, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache) -> Overflow_Result {
    if lf_cl.assume_no_overflow return .NEVER_OVERFLOWS;
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = block_terminator(li_loop_preheader(li, fi.outer_loop)); q.have_tli = false;
    r := compute_overflow_for_unsigned_mul(fi.inner_trip_count, fi.outer_trip_count, q);
    if r != .MAY_OVERFLOW return r;
    check_gep :: (gep: Value_Id, gep_operand: Value_Id, fi: *Flatten_Info, li: *Loop_Info) -> bool {
        for gu: sx_users(gep) {
            if !(inst_op(gu) == .LOAD) && !(inst_op(gu) == .STORE && op(gu, 1) == gep) continue;
            if !is_guaranteed_to_execute_for_every_iteration(gu, li, fi.inner_loop) continue;
            if gep_is_inbounds(gep) && cast(u64) type_bits(vtype(gep_operand)) >= dl_pointer_type_size_bits(vtype(gep)) return true;
        }
        return false;
    }
    for v: fi.linear_iv_uses {
        if is_inst(v) && inst_op(v) == .GEP && nops(v) == 2 && check_gep(v, op(v, 1), fi, li) return .NEVER_OVERFLOWS;
        for u: sx_users(v) if is_inst(u) && inst_op(u) == .GEP && check_gep(u, v, fi, li) return .NEVER_OVERFLOWS;
    }
    return .MAY_OVERFLOW;
}

// CanFlattenLoopPair
lf_can_flatten_loop_pair :: (fi: *Flatten_Info, li: *Loop_Info, tti: *Tti) -> bool {
    iteration_instructions: [..] Value_Id; iteration_instructions.allocator = temp;
    ok: bool;
    ok, fi.inner_induction_phi, fi.inner_trip_count, fi.inner_increment, fi.inner_branch =
        lf_find_loop_components(li, fi.inner_loop, *iteration_instructions, fi.widened);
    if !ok return false;
    ok, fi.outer_induction_phi, fi.outer_trip_count, fi.outer_increment, fi.outer_branch =
        lf_find_loop_components(li, fi.outer_loop, *iteration_instructions, fi.widened);
    if !ok return false;
    if !li_is_loop_invariant(li, fi.outer_loop, fi.inner_trip_count) return false;
    if !li_is_loop_invariant(li, fi.outer_loop, fi.outer_trip_count) return false;
    if !lf_check_phis(fi, li) return false;
    if vtype(fi.inner_induction_phi) != vtype(fi.outer_induction_phi) return false;
    if !lf_check_outer_loop_insts(fi, li, iteration_instructions, tti) return false;
    if !lf_check_iv_users(fi) return false;
    return true;
}

// DoFlattenLoopPair
lf_do_flatten_loop_pair :: (fi: *Flatten_Info, li: *Loop_Info, dt: *Dom_Tree, u: *Lpm_Updater, mssau: *Mssa_Updater) -> bool {
    // LinearIVUses is a SmallPtrSet<Value *, 4>: past 4 elements it iterates in pointer order, and the new
    // instructions below are created in that order
    if fi.linear_iv_uses.count > 4
        fatal("loop-flatten: more than 4 linear IV uses: LLVM visits them in pointer order (SmallPtrSet), not reproducible");
    for fi.linear_iv_uses if vkind(it) == .DEAD fatal("loop-flatten: a linear IV use was deleted by IV widening (LLVM reads freed memory here)");
    for fi.inner_phis_to_transform if vkind(it) == .DEAD fatal("loop-flatten: an inner phi to transform was deleted by IV widening (LLVM reads freed memory here)");
    if fi.new_trip_count == NONE {
        t := block_terminator(li_loop_preheader(li, fi.outer_loop));
        m := create_binop(.MUL, fi.inner_trip_count, fi.outer_trip_count);
        insert_at_position(m, inst_block(t), t, false);
        set_name(m, "flatten.tripcount");
        fi.new_trip_count = m;
    }
    inner_latch := li_loop_latch(li, fi.inner_loop);
    phi_remove_incoming_block(fi.inner_induction_phi, inner_latch);
    for fi.inner_phis_to_transform phi_remove_incoming_block(it, inner_latch);
    set_op(op(fi.outer_branch, 0), 1, fi.new_trip_count);

    inner_exit_block := li_exit_block(li, fi.inner_loop);
    inner_exiting_block := li_exiting_block(li, fi.inner_loop);
    term := block_terminator(inner_exiting_block);
    bi := create_br(inner_exit_block);
    block_append_inst(inner_exiting_block, bi);
    copy_debug_loc(bi, term);
    erase_inst_with_metadata(term);
    inner_header := li_header(li, fi.inner_loop);
    dt_delete_edge(dt, inner_exiting_block, inner_header);
    if mssau mssau_remove_edge(mssau, inner_exiting_block, inner_header);

    b: Irb; irb_set_before(*b, block_terminator(inst_block(fi.outer_induction_phi)));
    for v: fi.linear_iv_uses {
        outer_value := fi.outer_induction_phi;
        if fi.widened {
            if type_kind(vtype(v)) != .INT fatal("loop-flatten: truncating the widened IV to the non-integer type of a linear IV use");
            outer_value = irb_cast(*b, .TRUNC, fi.outer_induction_phi, vtype(v), "flatten.trunciv");
        }
        if inst_op(v) == .GEP {
            inner_gep := op(v, 0);
            base := op(inner_gep, 0);
            if !dt_dominates_inst(dt, base, b.pt) irb_set_before(*b, v);
            flags: u32 = ifx gep_is_inbounds(v) && gep_is_inbounds(inner_gep) then cast(u32) F_INBOUNDS else 0;
            outer_value = irb_gep(*b, opr_gep_source_type(v), base, .[outer_value], tconcat("flatten.", vname(v)), flags);
        }
        replace_all_uses_with(v, outer_value);
    }
    sc_forget_loop(fi.outer_loop);
    sc_forget_block_and_loop_dispositions();
    if u lpm_mark_loop_as_deleted(u, fi.inner_loop);
    li_erase(li, fi.inner_loop);
    return true;
}

// CanWidenIV
lf_can_widen_iv :: (fi: *Flatten_Info, li: *Loop_Info, dt: *Dom_Tree, tti: *Tti) -> bool {
    if !lf_cl.widen_iv return false;
    inner_type := vtype(fi.inner_induction_phi);
    outer_type := vtype(fi.outer_induction_phi);
    max_legal_size := dl_largest_legal_int_bits();
    if inner_type != outer_type || cast(u64) type_bits(inner_type) >= max_legal_size ||
       max_legal_size < cast(u64) type_bits(inner_type) * 2 return false;
    max_legal_type := type_int(cast(u32) max_legal_size);
    rw: Scev_Expander;
    sx_init(*rw, "loopflatten");
    dead: [..] Vh; dead.allocator = temp;   // DeadInsts: never cleaned up
    create :: (narrow: Value_Id, ty: Type_Id, li: *Loop_Info, rw: *Scev_Expander, dt: *Dom_Tree, dead: *[..] Vh) -> (bool, deleted: bool) {
        wi: Wide_IV_Info;
        wi.narrow_iv = narrow; wi.widest_native_type = ty; wi.is_signed = false;
        wide_phi := create_wide_iv(wi, li, rw, dt, dead, true, true);
        if wide_phi == NONE return false, false;
        return true, ivs_recursively_delete_dead_phi_node(narrow, null);
    }
    ok, deleted := create(fi.inner_induction_phi, max_legal_type, li, *rw, dt, *dead);
    if !ok return false;
    if !deleted lf_set_insert(*fi.inner_phis_to_transform, fi.inner_induction_phi);
    ok, deleted = create(fi.outer_induction_phi, max_legal_type, li, *rw, dt, *dead);
    if !ok return false;
    fi.widened = true;
    fi.narrow_inner_induction_phi = fi.inner_induction_phi;
    fi.narrow_outer_induction_phi = fi.outer_induction_phi;
    return lf_can_flatten_loop_pair(fi, li, tti);
}

// FlattenLoopPair
lf_flatten_loop_pair :: (fi: *Flatten_Info, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, tti: *Tti, u: *Lpm_Updater,
                         mssau: *Mssa_Updater, lai: *Laa) -> bool {
    if !lf_can_flatten_loop_pair(fi, li, tti) return false;
    can_flatten := lf_can_widen_iv(fi, li, dt, tti);
    if fi.widened && !can_flatten return true;
    if can_flatten return lf_do_flatten_loop_pair(fi, li, dt, u, mssau);
    r := lf_check_overflow(fi, li, dt, ac);
    if r == .ALWAYS_OVERFLOWS_HIGH || r == .ALWAYS_OVERFLOWS_LOW return false;
    if r == .MAY_OVERFLOW {
        if !lf_cl.version_loops return false;
        if !dl_is_legal_integer(type_bits(scalar_type(vtype(fi.outer_trip_count)))) return false;
        check_block := li_loop_preheader(li, fi.outer_loop);
        lv: Lver;
        lv.versioned = fi.outer_loop; lv.lai = lai; lv.checks = .[]; lv.li = li; lv.dt = dt;
        defs := find_defs_used_outside_of_loop(li, fi.outer_loop);
        lver_version_loop(*lv, defs);
        br := block_terminator(check_block);
        b: Irb; irb_set_before(*b, br);
        call := irb_intrinsic(*b, "llvm.umul.with.overflow", .[vtype(fi.outer_trip_count)], .[fi.outer_trip_count, fi.inner_trip_count]);
        set_name(call, "flatten.mul");
        fi.new_trip_count = irb_extract_value(*b, call, .[0], "flatten.tripcount");
        overflow := irb_extract_value(*b, call, .[1], "flatten.overflow");
        set_op(br, 0, overflow);
    }
    return lf_do_flatten_loop_pair(fi, li, dt, u, mssau);
}

// LoopFlattenPass::run(LoopNest &LN, ...)
loop_flatten_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    li := lar.li;
    mssau_storage: Mssa_Updater;
    mssau: *Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; mssau = *mssau_storage; }
    tti := tti_get(lar.fn);
    changed := false;
    loops := loop_nest_loops_bfs(li, l);
    for inner: loops {
        outer := li_parent(li, inner);
        if outer == NONE continue;
        // LAIM.getInfo(*OuterLoop) (the outer loop is never innermost: LoopAccessInfo stops at canAnalyzeLoop)
        lai := New(Laa,, allocator = temp);
        laa_compute(lai, outer, li, lar.dt, lar.ac);
        fi: Flatten_Info;
        fi.outer_loop = outer; fi.inner_loop = inner;
        fi.linear_iv_uses.allocator = temp; fi.inner_phis_to_transform.allocator = temp;
        changed |= lf_flatten_loop_pair(*fi, li, lar.dt, lar.ac, tti, u, mssau, lai);
    }
    if !changed return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
