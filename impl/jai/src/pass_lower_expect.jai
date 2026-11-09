// LowerExpectIntrinsic: port of llvm/lib/Transforms/Scalar/LowerExpectIntrinsic.cpp (getBranchWeight,
// handleSwitchExpect, handlePhiDef, handleBrSelExpect, lowerExpectIntrinsic). misexpect:: checks only emit
// diagnostics (-pgo-warn-misexpect / remarks) and are not ported.

le_ceil :: (x: float64) -> float64 #foreign cfc_libm "ceil";

le_cl: struct {
    likely_branch_weight: u32 = 2000;    // -likely-branch-weight
    unlikely_branch_weight: u32 = 1;     // -unlikely-branch-weight
};

// true if `c` is a call of llvm.expect / llvm.expect.with.probability (CallInst with a called Function)
le_is_expect_call :: (c: Value_Id) -> bool {
    if !is_inst(c) || inst_op(c) != .CALL return false;
    id := fn_iid(call_called_function(c));
    return id == IID_EXPECT || id == IID_EXPECT_WITH_PROBABILITY;
}

le_confidence :: (ci: Value_Id) -> float64 {
    c := op(ci, 2);
    assert(vkind(c) == .C_FP, "expect with probability needs a ConstantFP");
    return fp_to_f64(type_kind(vtype(c)), const_fp_value(c));
}

// getBranchWeight
le_branch_weight :: (id: Intrinsic_Id, ci: Value_Id, branch_count: s64) -> (u32, u32) {
    if id == IID_EXPECT return le_cl.likely_branch_weight, le_cl.unlikely_branch_weight;
    true_prob := le_confidence(ci);
    false_prob := (1.0 - true_prob) / cast(float64) (branch_count - 1);
    INT32_MAX :: 2147483647.0;
    likely := cast(u32) le_ceil(true_prob * (INT32_MAX - 1) + 1.0);
    unlikely := cast(u32) le_ceil(false_prob * (INT32_MAX - 1) + 1.0);
    return likely, unlikely;
}

le_handle_switch_expect :: (si: Value_Id) -> bool {
    ci := sw_cond(si);
    if !le_is_expect_call(ci) return false;
    id := fn_iid(call_called_function(ci));
    arg := op(ci, 0);
    expected := op(ci, 1);
    if vkind(expected) != .C_INT return false;
    k := sw_find_case_value(si, expected);
    n := cast(s64) sw_num_cases(si);
    likely, unlikely := le_branch_weight(id, ci, n + 1);
    w := NewArray(n + 1, u32,, allocator = temp);
    for * w it.* = unlikely;
    index := ifx k < 0 then 0 else k + 1;
    w[index] = likely;
    set_op(si, 0, arg);
    prof_set_branch_weights(si, w, true);
    return true;
}

le_handle_phi_def :: (expect: Value_Id) {
    arg := op(expect, 0);
    expected := op(expect, 1);
    if vkind(expected) != .C_INT return;
    expected_phi_value := const_ap(expected);
    expected_is_likely := true;
    id := fn_iid(call_called_function(expect));
    if id == IID_EXPECT_WITH_PROBABILITY expected_is_likely = le_confidence(expect) > 0.5;

    v := arg;
    operations: [..] Value_Id; operations.allocator = temp;
    while !is_phi(v) {
        if is_inst(v) && (inst_op(v) == .ZEXT || inst_op(v) == .SEXT) {
            array_add(*operations, v);
            v = op(v, 0);
            continue;
        }
        if !is_inst(v) || inst_op(v) != .XOR return;
        c := op(v, 1);
        if vkind(c) != .C_INT return;
        array_add(*operations, v);
        v = op(v, 0);
    }
    apply_operations :: (operations: [] Value_Id, value: APInt) -> APInt {
        r := value;
        k := operations.count;
        while k > 0 {
            k -= 1;
            o := operations[k];
            if inst_op(o) == {
                case .XOR; r = ap_xor(r, const_ap(op(o, 1)));
                case .ZEXT; r = ap_zext(r, type_int_width(vtype(o)));
                case .SEXT; r = ap_sext(r, type_int_width(vtype(o)));
                case; assert(false, "Unexpected operation");
            }
        }
        return r;
    }
    phi_def := v;
    get_dom_conditional :: (phi_def: Value_Id, i: u32) -> Value_Id {
        bb := phi_block(phi_def, i);
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .CONDBR return t;
        bb = block_single_predecessor(bb);
        if bb == NONE return NONE;
        t = block_terminator(bb);
        if t != NONE && inst_op(t) == .CONDBR return t;
        return NONE;
    }
    n := phi_num_incoming(phi_def);
    for i: 0..cast(s64) n - 1 {
        phi_opnd := phi_value(phi_def, cast(u32) i);
        if vkind(phi_opnd) != .C_INT continue;
        current := apply_operations(operations, const_ap(phi_opnd));
        if expected_is_likely == ap_eq(expected_phi_value, current) continue;
        bi := get_dom_conditional(phi_def, cast(u32) i);
        if bi == NONE continue;
        opnd_incoming_bb := phi_block(phi_def, cast(u32) i);
        is_opnd_coming_from_successor :: (succ: Value_Id) -> bool #expand {
            if opnd_incoming_bb == succ return true;
            if opnd_incoming_bb == inst_block(bi) && succ == inst_block(phi_def) return true;
            return false;
        }
        likely, unlikely := le_branch_weight(id, expect, 2);
        if !expected_is_likely { t := likely; likely = unlikely; unlikely = t; }
        if is_opnd_coming_from_successor(get_successor(bi, 1)) prof_set_branch_weights(bi, .[likely, unlikely], true);
        else if is_opnd_coming_from_successor(get_successor(bi, 0)) prof_set_branch_weights(bi, .[unlikely, likely], true);
    }
}

// handleBrSelExpect (CondBrInst or SelectInst: the condition is operand 0 of both)
le_handle_br_sel_expect :: (bsi: Value_Id) -> bool {
    ci: Value_Id;
    cond := op(bsi, 0);
    cmpi: Value_Id = ifx is_inst(cond) && inst_op(cond) == .ICMP then cond else NONE;
    predicate: u8;
    cmp_const: Value_Id = NONE;
    if cmpi == NONE {
        ci = cond;
        predicate = ICMP_NE;
    } else {
        predicate = inst_pred(cmpi);
        if predicate != ICMP_NE && predicate != ICMP_EQ return false;
        cmp_const = op(cmpi, 1);
        if vkind(cmp_const) != .C_INT return false;
        ci = op(cmpi, 0);
    }
    if !is_inst(ci) || inst_op(ci) != .CALL return false;
    value_compared_to: u64 = 0;
    if cmp_const != NONE {
        if type_bits(scalar_type(vtype(cmp_const))) > 64 return false;
        value_compared_to = const_int_zext(cmp_const);
    }
    if !le_is_expect_call(ci) return false;
    id := fn_iid(call_called_function(ci));
    arg := op(ci, 0);
    expected := op(ci, 1);
    if vkind(expected) != .C_INT return false;
    likely, unlikely := le_branch_weight(id, ci, 2);
    w: [2] u32;
    if (const_int_zext(expected) == value_compared_to) == (predicate == ICMP_EQ) { w[0] = likely; w[1] = unlikely; }
    else { w[0] = unlikely; w[1] = likely; }
    if cmpi != NONE set_op(cmpi, 0, arg);
    else set_op(bsi, 0, arg);
    prof_set_branch_weights(bsi, w, true);
    return true;
}

lower_expect_run :: (f: Value_Id) -> Preserved {
    changed := false;
    for bb: fn_blocks(f) {
        t := block_terminator(bb);
        if t != NONE && inst_op(t) == .CONDBR le_handle_br_sel_expect(t);
        else if t != NONE && inst_op(t) == .SWITCH le_handle_switch_expect(t);
        // remove llvm.expect intrinsics, iterating backwards so that selects are handled first
        it := block_last(bb);
        while it != NONE {
            prev := inst_prev(it);
            defer it = prev;
            if inst_op(it) != .CALL {
                if inst_op(it) == .SELECT le_handle_br_sel_expect(it);
                continue;
            }
            if le_is_expect_call(it) {
                le_handle_phi_def(it);
                rauw_with_metadata(it, op(it, 0));
                erase_inst_with_metadata(it);
                changed = true;
            }
        }
    }
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}
