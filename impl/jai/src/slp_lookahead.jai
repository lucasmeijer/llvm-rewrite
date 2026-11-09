// SLPVectorizer: BoUpSLP::LookAheadHeuristics (operand-pair scoring for reordering and root selection).
// Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class BoUpSLP::LookAheadHeuristics, complete).

LA_SCORE_CONSECUTIVE_LOADS :: 40;
LA_SCORE_SPLAT_LOADS :: 30;
LA_SCORE_REVERSED_LOADS :: 30;
LA_SCORE_MASKED_GATHER_CANDIDATE :: 10;
LA_SCORE_CONSECUTIVE_EXTRACTS :: 40;
LA_SCORE_REVERSED_EXTRACTS :: 30;
LA_SCORE_CONSTANTS :: 15;
LA_SCORE_SAME_CONSTANTS :: 17;
LA_SCORE_SAME_OPCODE :: 20;
LA_SCORE_ALT_OPCODES :: 10;
LA_SCORE_SPLAT :: 10;
LA_SCORE_UNDEF :: 10;
LA_SCORE_FAIL :: 0;
LA_SCORE_ALL_USER_VECTORIZED :: 10;

Look_Ahead :: struct {
    num_lanes: s64;
    max_level: s64;
}

// getShallowScore(V1, V2, U1, U2, MainAltOps)
la_shallow_score :: (la: *Look_Ahead, v1: Value_Id, v2: Value_Id, u1: Value_Id, u2: Value_Id, main_alt_ops: [] Value_Id) -> s64 {
    if !slp_is_valid_element_type(vtype(v1)) || !slp_is_valid_element_type(vtype(v2)) return LA_SCORE_FAIL;
    if v1 == v2 {
        if vc_is_op(v1, .LOAD) {
            all_users_internal :: (v1: Value_Id, v2: Value_Id, u1: Value_Id, u2: Value_Id) -> bool {
                if has_n_uses_or_more(v1, SLP_USES_LIMIT) || has_n_uses_or_more(v2, SLP_USES_LIMIT) return false;
                all_vec :: (v: Value_Id, u1: Value_Id, u2: Value_Id) -> bool {
                    u := ir.v_first_use[v];
                    while u != NONE {
                        usr := ir.u_user[u];
                        u = ir.u_next[u];
                        if usr != u1 && usr != u2 && !slp_is_vectorized(usr) return false;
                    }
                    return true;
                }
                return all_vec(v1, u1, u2) && all_vec(v2, u1, u2);
            }
            if tti_is_legal_broadcast_load(slp.tti, vtype(v1), cast(u64) la.num_lanes) &&
               (num_uses(v1) == la.num_lanes || all_users_internal(v1, v2, u1, u2))
                return LA_SCORE_SPLAT_LOADS;
        }
        if pm_undef_value(v1) return LA_SCORE_UNDEF;
        if slp_is_constant(v1) return LA_SCORE_SAME_CONSTANTS;
        return LA_SCORE_SPLAT;
    }
    check_same_entry_or_fail :: (v1: Value_Id, v2: Value_Id) -> s64 {
        tes1 := slp_get_tree_entries(v1);
        if tes1.count {
            tes2 := slp_get_tree_entries(v2);
            for e2: tes2 for e1: tes1 if e1 == e2 return LA_SCORE_SPLAT_LOADS;
        }
        return LA_SCORE_FAIL;
    }
    l1 := vc_is_op(v1, .LOAD); l2 := vc_is_op(v2, .LOAD);
    if l1 && l2 {
        if inst_block(v1) != inst_block(v2) || !is_simple_load_store(v1) || !is_simple_load_store(v2) return check_same_entry_or_fail(v1, v2);
        ok, dist := get_pointers_diff(vtype(v1), op(v1, 0), vtype(v2), op(v2, 0), true);
        if !ok || dist == 0 {
            if get_underlying_object(op(v1, 0)) == get_underlying_object(op(v2, 0)) &&
               tti_is_legal_masked_gather(slp.tti, slp_widened_type(vtype(v1), cast(u64) la.num_lanes), inst(v1).align)
                return LA_SCORE_MASKED_GATHER_CANDIDATE;
            return check_same_entry_or_fail(v1, v2);
        }
        if (ifx dist < 0 then -dist else dist) > la.num_lanes / 2 return LA_SCORE_MASKED_GATHER_CANDIDATE;
        return ifx dist > 0 then LA_SCORE_CONSECUTIVE_LOADS else LA_SCORE_REVERSED_LOADS;
    }
    c1 := is_const(v1); c2 := is_const(v2);
    if c1 && c2 return LA_SCORE_CONSTANTS;
    if (c1 && vc_is_op(v2, .INSERTELEMENT)) || (c2 && vc_is_op(v1, .INSERTELEMENT)) return LA_SCORE_SAME_OPCODE;
    if vc_is_op(v1, .EXTRACTELEMENT) && vkind(op(v1, 1)) == .C_INT {
        ev1 := op(v1, 0);
        if pm_undef_value(v2) {
            return ifx pm_poison(v2) || all_bits(slp_is_undef_vector(ev1)) then LA_SCORE_CONSECUTIVE_EXTRACTS else LA_SCORE_SAME_OPCODE;
        }
        if vc_is_op(v2, .EXTRACTELEMENT) && (vkind(op(v2, 1)) == .C_INT || pm_undef(op(v2, 1))) {
            ev2 := op(v2, 0);
            if vkind(op(v2, 1)) != .C_INT return LA_SCORE_CONSECUTIVE_EXTRACTS;
            if all_bits(slp_is_undef_vector(ev2)) && vtype(ev2) == vtype(ev1) return LA_SCORE_CONSECUTIVE_EXTRACTS;
            if ev2 == ev1 {
                i1 := cast(s32) ap_zext_value(cf_ap(op(v1, 1)));
                i2 := cast(s32) ap_zext_value(cf_ap(op(v2, 1)));
                dist := cast(s64) (i2 - i1);
                if dist == 0 return LA_SCORE_SPLAT;
                if (ifx dist < 0 then -dist else dist) > la.num_lanes / 2 return LA_SCORE_SAME_OPCODE;
                return ifx dist > 0 then LA_SCORE_CONSECUTIVE_EXTRACTS else LA_SCORE_REVERSED_EXTRACTS;
            }
            return LA_SCORE_ALT_OPCODES;
        }
        return check_same_entry_or_fail(v1, v2);
    }
    i1 := is_inst(v1); i2 := is_inst(v2);
    if i1 && i2 {
        if inst_block(v1) != inst_block(v2) return check_same_entry_or_fail(v1, v2);
        if (vc_is_op(v1, .ZEXT) && vc_is_op(v2, .SELECT) && vtype(op(v1, 0)) == vtype(op(v2, 0))) ||
           (vc_is_op(v2, .ZEXT) && vc_is_op(v1, .SELECT) && vtype(op(v2, 0)) == vtype(op(v1, 0)))
            return LA_SCORE_SAME_OPCODE;
        ops: [..] Value_Id; ops.allocator = temp;
        for main_alt_ops array_add(*ops, it);
        array_add(*ops, v1); array_add(*ops, v2);
        s := slp_get_same_opcode(ops);
        if is_valid(s) && (nops(s.main) <= 2 || main_alt_ops.count != 0 || !is_alt_shuffle(s)) {
            ok := true;
            for ops if !pm_poison(it) && nops(it) != nops(s.main) { ok = false; break; }
            if ok return ifx is_alt_shuffle(s) then LA_SCORE_ALT_OPCODES else LA_SCORE_SAME_OPCODE;
        }
    }
    if i1 && pm_poison(v2) return LA_SCORE_SAME_OPCODE;
    if pm_undef_value(v2) return LA_SCORE_UNDEF;
    return check_same_entry_or_fail(v1, v2);
}

// getScoreAtLevelRec(LHS, RHS, U1, U2, CurrLevel, MainAltOps)
la_score_at_level_rec :: (la: *Look_Ahead, lhs: Value_Id, rhs: Value_Id, u1: Value_Id, u2: Value_Id, level: s64, main_alt_ops: [] Value_Id) -> s64 {
    score := la_shallow_score(la, lhs, rhs, u1, u2, main_alt_ops);
    i1 := is_inst(lhs); i2 := is_inst(rhs);
    if level == la.max_level || !(i1 && i2) || lhs == rhs || score == LA_SCORE_FAIL return score;
    if ((vc_is_op(lhs, .LOAD) && vc_is_op(rhs, .LOAD)) || (nops(lhs) > 2 && nops(rhs) > 2) ||
        (vc_is_op(lhs, .EXTRACTELEMENT) && vc_is_op(rhs, .EXTRACTELEMENT))) && score != 0
        return score;
    used: [..] u32; used.allocator = temp;
    if nops(lhs) != nops(rhs) return LA_SCORE_SAME_OPCODE;
    n1 := nops(lhs);
    comm := slp_is_commutative(rhs);
    for o1: 0..cast(s64) n1 - 1 {
        max_tmp: s64 = 0;
        max_o2: u32 = 0;
        found := false;
        from: s64 = ifx comm then 0 else o1;
        to: s64 = ifx comm then cast(s64) nops(rhs) else min(cast(s64) nops(rhs), o1 + 1);
        for o2: from..to-1 {
            skip := false; for used if it == cast(u32) o2 { skip = true; break; }
            if skip continue;
            tmp := la_score_at_level_rec(la, op(lhs, cast(u32) o1), op(rhs, cast(u32) o2), lhs, rhs, level + 1, .[]);
            if tmp > LA_SCORE_FAIL && tmp > max_tmp { max_tmp = tmp; max_o2 = cast(u32) o2; found = true; }
        }
        if found { array_add(*used, max_o2); score += max_tmp; }
    }
    return score;
}
