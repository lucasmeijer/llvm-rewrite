// SLPVectorizer: InstructionsCompatibilityAnalysis (copyable-element detection, operand building) and PHIHandler.
// Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class InstructionsCompatibilityAnalysis, class
// PHIHandler, checkEVsForVecCalls). The analysis object of LLVM is a short-lived value holding MainOp/MainOpcode;
// here it is the `Ica_State` struct passed by pointer.

Ica_State :: struct {
    main_opcode: Opcode = .NONE_OP;
    main_op: Value_Id = NONE;
}

ica_is_supported_opcode :: (o: Opcode) -> bool {
    return o == .ADD || o == .SUB || o == .MUL || o == .ASHR || o == .LSHR || o == .SHL || o == .SDIV || o == .UDIV ||
           o == .AND || o == .OR || o == .XOR || o == .FADD || o == .FSUB || o == .FMUL || o == .FDIV;
}

dt_dfs_in :: (dt: *Dom_Tree, bb: Value_Id) -> u32 { return dt.nodes[dt_node(dt, bb)].dfs_in; }

// findAndSetMainInstruction
ica_find_and_set_main_instruction :: (a: *Ica_State, vl: [] Value_Id) {
    parent: Value_Id = NONE;
    is_supported :: (i: Value_Id, any_undef: bool) -> bool {
        o := inst_op(i);
        if any_undef && (is_int_div_rem(o) || o == .FDIV || o == .FREM || o == .CALL) return false;
        return ica_is_supported_opcode(o) && (!slp_does_not_need_to_be_scheduled(i) || !slp_is_vectorized(i));
    }
    operands: Table(Value_Id, bool); operands.allocator = temp;
    // SmallMapVector<opcode, SmallVector<Instruction *>>
    cand_ops: [..] Opcode; cand_ops.allocator = temp;
    cand_lists: [..] [..] Value_Id; cand_lists.allocator = temp;
    add_cand :: (ops: *[..] Opcode, lists: *[..] [..] Value_Id, i: Value_Id) {
        for ops.* if it == inst_op(i) { array_add(*lists.*[it_index], i); return; }
        array_add(ops, inst_op(i));
        l: [..] Value_Id; l.allocator = temp;
        array_add(*l, i);
        array_add(lists, l);
    }
    add_ops :: (t: *Table(Value_Id, bool), i: Value_Id) { for k: 0..cast(s64) nops(i) - 1 table_set(t, op(i, cast(u32) k), true); }
    any_undef := false;
    for v: vl {
        if !is_inst(v) { any_undef |= pm_undef_value(v); continue; }
        if !dt_is_reachable_from_entry(slp.dt, inst_block(v)) continue;
        if cand_ops.count == 0 {
            add_cand(*cand_ops, *cand_lists, v);
            parent = inst_block(v);
            add_ops(*operands, v);
            continue;
        }
        if parent == inst_block(v) {
            add_cand(*cand_ops, *cand_lists, v);
            add_ops(*operands, v);
            continue;
        }
        if dt_dfs_in(slp.dt, parent) < dt_dfs_in(slp.dt, inst_block(v)) {
            array_reset_keeping_memory(*cand_ops);
            array_reset_keeping_memory(*cand_lists);
            add_cand(*cand_ops, *cand_lists, v);
            parent = inst_block(v);
            table_reset(*operands);
            add_ops(*operands, v);
        }
    }
    best_num := 0;
    a.main_op = NONE;
    used_outside := false;
    for list: cand_lists {
        p_used_outside := true;
        for list if !slp_is_used_outside_block(it) { p_used_outside = false; break; }
        if used_outside && !p_used_outside continue;
        if !used_outside && p_used_outside best_num = 0;
        if list.count < best_num continue;
        if !p_used_outside {
            hit := false;
            for list if table_contains(*operands, it) { hit = true; break; }
            if hit continue;
        }
        if list.count == best_num {
            i := list[0];
            if a.main_op != NONE && is_binary_op(inst_op(a.main_op)) {
                m0 := op(a.main_op, 0); m1 := op(a.main_op, 1);
                if is_inst(m0) && inst_op(m0) == inst_op(i) && inst_block(m0) == inst_block(i) continue;
                if is_inst(m1) && inst_op(m1) == inst_op(i) && inst_block(m1) == inst_block(i) continue;
            }
        }
        used_outside = p_used_outside;
        for list {
            if is_supported(it, any_undef) { a.main_op = it; best_num = list.count; break; }
        }
    }
    if a.main_op != NONE {
        for v: vl {
            if is_inst(v) && inst_block(v) == inst_block(a.main_op) && is_terminator(inst_op(v)) { a.main_op = NONE; return; }
        }
        a.main_opcode = inst_op(a.main_op);
    }
}

// selectBestIdempotentValue
ica_select_best_idempotent_value :: (a: *Ica_State) -> Value_Id {
    return cf_binop_identity(a.main_opcode, vtype(a.main_op), !inst_is_commutative(a.main_op));
}

// getOperands(S, V)
ica_get_operands :: (a: *Ica_State, s: Inst_State, v: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    if pm_poison(v) { array_add(*r, v, v); return r; }
    if !is_copyable_element(s, v) { _, ops := slp_convert_to(v, s); return ops; }
    array_add(*r, v, ica_select_best_idempotent_value(a));
    return r;
}

new_value_list :: (n: s64, fill: Value_Id = NONE) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    array_resize(*r, n, false);
    for * r it.* = fill;
    return r;
}
new_operand_lists :: (nops_: s64, n: s64) -> [..] [..] Value_Id {
    r: [..] [..] Value_Id; r.allocator = temp;
    for 1..nops_ array_add(*r, new_value_list(n));
    return r;
}

// PHIHandler(DT, Main, Phis).buildOperands(); Operands[I] for each incoming index
phi_handler_build_operands :: (main: Value_Id, phis: [] Value_Id) -> [..] [..] Value_Id {
    n_in := cast(s64) phi_num_incoming(main);
    ops := new_operand_lists(n_in, phis.count);
    FAST_LIMIT :: 4;
    if n_in <= FAST_LIMIT {
        for i: 0..n_in-1 {
            in_bb := phi_block(main, cast(u32) i);
            if !dt_is_reachable_from_entry(slp.dt, in_bb) {
                for * ops[i] it.* = const_poison(vtype(main));
                continue;
            }
            for v, idx: phis {
                if !is_inst(v) || inst_op(v) != .PHI { ops[i][idx] = v; continue; }
                if phi_block(v, cast(u32) i) == in_bb ops[i][idx] = phi_value(v, cast(u32) i);
                else ops[i][idx] = phi_incoming_value_for_block(v, in_bb);
            }
        }
        return ops;
    }
    blocks_keys: [..] Value_Id; blocks_keys.allocator = temp;
    blocks_vals: [..] [..] s64; blocks_vals.allocator = temp;
    find_block :: (keys: [] Value_Id, b: Value_Id) -> s64 { for keys if it == b return it_index; return -1; }
    for i: 0..n_in-1 {
        in_bb := phi_block(main, cast(u32) i);
        if !dt_is_reachable_from_entry(slp.dt, in_bb) {
            for * ops[i] it.* = const_poison(vtype(main));
            continue;
        }
        k := find_block(blocks_keys, in_bb);
        if k < 0 {
            array_add(*blocks_keys, in_bb);
            l: [..] s64; l.allocator = temp;
            array_add(*blocks_vals, l);
            k = blocks_keys.count - 1;
        }
        array_add(*blocks_vals[k], i);
    }
    for v, idx: phis {
        if pm_poison(v) { for i: 0..n_in-1 ops[i][idx] = v; continue; }
        for i: 0..cast(s64) phi_num_incoming(v) - 1 {
            in_bb := phi_block(v, cast(u32) i);
            if in_bb == phi_block(main, cast(u32) i) {
                if ops[i][idx] != NONE && pm_poison(ops[i][idx]) continue;
                ops[i][idx] = phi_value(v, cast(u32) i);
                continue;
            }
            k := find_block(blocks_keys, in_bb);
            if k < 0 continue;
            ops[blocks_vals[k][0]][idx] = phi_value(v, cast(u32) i);
        }
    }
    for list: blocks_vals {
        if list.count <= 1 continue;
        basic := list[0];
        for j: 1..list.count-1 ops[list[j]] = vl_copy(ops[basic]);
    }
    return ops;
}

// checkEVsForVecCalls(VL, S, TLI, Indices, Calls)
slp_check_evs_for_vec_calls :: (vl: [] Value_Id, s: Inst_State) -> (bool, [..] Value_Id) {
    calls: [..] Value_Id; calls.allocator = temp;
    for vl if !is_inst(it) || inst_op(it) != .EXTRACTVALUE return false, calls;
    vl0 := s.main;
    for v: vl {
        if v == vl0 { array_add(*calls, op(vl0, 0)); continue; }
        if inst(v).nidx != inst(vl0).nidx return false, calls;
        for k: 0..cast(s64) inst(v).nidx - 1 if ir.u32_pool[inst(v).idx + cast(u32) k] != ir.u32_pool[inst(vl0).idx + cast(u32) k] return false, calls;
        if type_kind(vtype(v)) == .SVECTOR return false, calls;
        array_add(*calls, op(v, 0));
    }
    agg := slp_get_same_opcode(calls);
    if is_valid(agg) && is_opcode(agg) == .CALL && !is_alt_shuffle(agg) && type_kind(vtype(agg.main)) == .STRUCT &&
       slp_all_same_block(calls) {
        for c: calls {
            u := ir.v_first_use[c];
            while u != NONE {
                usr := ir.u_user[u]; u = ir.u_next[u];
                if !is_inst(usr) || inst_op(usr) != .EXTRACTVALUE return false, calls;
            }
        }
        return true, calls;
    }
    return false, calls;
}

// buildOriginalOperands(S, VL, Operands)
ica_build_original_operands :: (a: *Ica_State, s: Inst_State, vl: [] Value_Id) -> [..] [..] Value_Id {
    vl0 := s.main;
    shuffle_or_op := ifx is_alt_shuffle(s) then Opcode.SHUFFLEVECTOR else is_opcode(s);
    if shuffle_or_op == {
        case .PHI;
            return phi_handler_build_operands(vl0, vl);
        case .EXTRACTVALUE; #through;
        case .EXTRACTELEMENT;
            if shuffle_or_op == .EXTRACTVALUE {
                ok, calls := slp_check_evs_for_vec_calls(vl, s);
                if ok {
                    r: [..] [..] Value_Id; r.allocator = temp;
                    array_add(*r, calls);
                    return r;
                }
            }
            r: [..] [..] Value_Id; r.allocator = temp;
            array_add(*r, new_value_list(vl.count, op(vl0, 0)));
            return r;
        case .INSERTVALUE; #through;
        case .INSERTELEMENT;
            r := new_operand_lists(2, vl.count);
            for v, idx: vl for k: 0..1 r[k][idx] = op(v, cast(u32) k);
            return r;
        case .LOAD;
            r: [..] [..] Value_Id; r.allocator = temp;
            array_add(*r, new_value_list(vl.count, const_poison(vtype(op(vl0, 0)))));
            for v, idx: vl if is_inst(v) && inst_op(v) == .LOAD r[0][idx] = op(v, 0);
            return r;
        case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
        case .FPEXT; #through; case .PTRTOINT; #through; case .INTTOPTR; #through; case .SITOFP; #through;
        case .UITOFP; #through; case .TRUNC; #through; case .FPTRUNC; #through; case .BITCAST; #through;
        case .ICMP; #through; case .FCMP; #through; case .FNEG; #through; case .ADD; #through; case .FADD; #through;
        case .SUB; #through; case .FSUB; #through; case .MUL; #through; case .FMUL; #through; case .UDIV; #through;
        case .SDIV; #through; case .FDIV; #through; case .UREM; #through; case .SREM; #through; case .FREM; #through;
        case .SHL; #through; case .LSHR; #through; case .ASHR; #through; case .AND; #through; case .OR; #through;
        case .XOR; #through; case .FREEZE; #through; case .STORE; #through; case .SHUFFLEVECTOR;
            n := cast(s64) nops(vl0);
            r := new_operand_lists(n, vl.count);
            for v, idx: vl {
                if !is_inst(v) {
                    for k: 0..n-1 r[k][idx] = const_poison(vtype(op(vl0, cast(u32) k)));
                    continue;
                }
                _, conv := slp_convert_to(v, s);
                for k: 0..n-1 r[k][idx] = conv[k];
            }
            return r;
        case .SELECT;
            n := cast(s64) nops(vl0);
            r := new_operand_lists(n, vl.count);
            for v, idx: vl {
                if !is_inst(v) {
                    for k: 0..n-1 r[k][idx] = const_poison(vtype(op(vl0, cast(u32) k)));
                    continue;
                }
                if inst_op(v) == .ZEXT {
                    r[0][idx] = op(v, 0);
                    r[1][idx] = const_int(vtype(v), 1);
                    r[2][idx] = const_null_value(vtype(v));
                    continue;
                }
                _, conv := slp_convert_to(v, s);
                for k: 0..n-1 r[k][idx] = conv[k];
            }
            return r;
        case .GEP;
            r := new_operand_lists(2, vl.count);
            INDEX_IDX :: 1;
            vl0_ty := vtype(op(vl0, INDEX_IDX));
            same := true;
            for v: vl if is_inst(v) && inst_op(v) == .GEP && vtype(op(v, INDEX_IDX)) != vl0_ty { same = false; break; }
            ty := ifx same then vl0_ty else dl_index_type(scalar_type(vtype(op(vl0, 0))));
            for v, idx: vl {
                if !is_inst(v) || inst_op(v) != .GEP {
                    r[0][idx] = v;
                    r[1][idx] = const_null_value(ty);
                    continue;
                }
                r[0][idx] = op(v, 0);
                o := op(v, INDEX_IDX);
                if vkind(o) == .C_INT r[1][idx] = cfo_integer_cast(o, ty, ap_is_negative(cf_ap(o)));
                else r[1][idx] = o;
            }
            return r;
        case .CALL;
            r: [..] [..] Value_Id; r.allocator = temp;
            id := get_vector_intrinsic_id_for_call(vl0);
            for k: 0..cast(s64) call_num_args(vl0) - 1 {
                if vu_is_vector_intrinsic_with_scalar_op_at_arg(id, cast(u32) k) continue;
                l: [..] Value_Id; l.allocator = temp;
                for v: vl array_add(*l, ifx is_inst(v) then op(v, cast(u32) k) else const_poison(vtype(op(vl0, cast(u32) k))));
                array_add(*r, l);
            }
            return r;
    }
    fatal("internal: slp: unexpected vectorization of the instructions");
    r: [..] [..] Value_Id;
    return r;
}

// isCopyablePreferable(VL, R, S, CopyableS)
ica_is_copyable_preferable :: (a: *Ica_State, vl: [] Value_Id, s: Inst_State, copyable_s: Inst_State) -> bool {
    all_vec := true;
    for vl if !pm_poison(it) && !slp_is_vectorized(it) { all_vec = false; break; }
    if all_vec return false;
    s_main := s.main;
    s_alt := ifx is_alt_shuffle(s) then s.alt else NONE;
    is_comm := slp_is_commutative(s_main);
    is_alt_comm := ifx is_alt_shuffle(s) then slp_is_commutative(s_alt) else false;
    is_main_comm := slp_is_commutative(a.main_op);
    ops := ica_build_original_operands(a, s, .[s_main]);
    if ops.count != 2 return false;
    check_operands :: (o: Value_Id, s_main_op: Value_Id) -> bool {
        if !is_inst(o) || !is_binary_op(inst_op(o)) return false;
        if !is_inst(s_main_op) || !is_binary_op(inst_op(s_main_op)) return true;
        for k: 0..cast(s64) nops(o) - 1 {
            x := op(o, cast(u32) k);
            if is_inst(x) && inst_op(x) == inst_op(s_main_op) return true;
        }
        return false;
    }
    operands: Table(Value_Id, bool); operands.allocator = temp;
    for v: vl {
        if !is_inst(v) || v == s_main continue;
        if is_matching_main_or_alt(s, v) != s_main continue;
        vops := ica_build_original_operands(a, s, .[v]);
        for k: 0..cast(s64) nops(v) - 1 table_set(*operands, op(v, cast(u32) k), true);
        if check_operands(vops[0][0], ops[0][0]) || check_operands(vops[1][0], ops[1][0]) ||
           (is_comm && (check_operands(vops[0][0], ops[1][0]) || check_operands(vops[1][0], ops[0][0]))) {
            s_main = v;
            ops = vops;
            break;
        }
    }
    main_ops := ica_build_original_operands(a, s, .[a.main_op]);
    first_cands :: (c: *[..] [2] Value_Id, ops: [] [..] Value_Id, op0: Value_Id, op1: Value_Id, comm: bool) {
        array_add(c, .[ops[0][0], op0]);
        if comm array_add(c, .[ops[0][0], op1]);
    }
    second_cands :: (c: *[..] [2] Value_Id, ops: [] [..] Value_Id, prev_best: s64, op0: Value_Id, op1: Value_Id, comm: bool) {
        if prev_best != 1 array_add(c, .[ops[1][0], op1]);
        if prev_best != 0 && comm array_add(c, .[ops[1][0], op0]);
    }
    // FindBestCandidate: (index or -1, is_const, score)
    find_best :: (c: [] [2] Value_Id) -> (s64, bool, s64) {
        idx, score := slp_find_best_root_pair(c);
        i0 := ifx idx < 0 then 0 else idx;
        is_const := score == LA_SCORE_CONSTANTS && slp_is_constant(c[i0][0]) && slp_is_constant(c[i0][1]);
        if is_const {
            for p, k: c {
                if !slp_is_constant(p[0]) && !slp_is_constant(p[1]) && p[1] == p[0] {
                    idx = k;
                    is_const = false;
                    score = ifx is_inst(c[idx][0]) && inst_op(c[idx][0]) == .LOAD then LA_SCORE_SPLAT_LOADS else LA_SCORE_SPLAT;
                    break;
                }
            }
        }
        return idx, is_const, score;
    }
    for v: vl {
        if !is_inst(v) || (v == a.main_op && (!is_alt_shuffle(s) || v == s_main)) || (!is_alt_shuffle(s) && v == s_main) continue;
        vops := ica_build_original_operands(a, s, .[ifx v == s_main then a.main_op else v]);
        copyable_ops := ica_get_operands(a, copyable_s, ifx v == a.main_op then s_main else v);
        if copyable_ops.count == vops.count {
            same := true;
            for k: 0..copyable_ops.count-1 if copyable_ops[k] != vops[k][0] { same = false; break; }
            if same continue;
        }
        cands: [..] [2] Value_Id; cands.allocator = temp;
        first_cands(*cands, main_ops, copyable_ops[0], copyable_ops[1], is_main_comm);
        op_size := cands.count;
        matching := ifx is_matching_main_or_alt(s, v) == s.main then s_main else s_alt;
        is_comm_inst := (ifx matching == s_main then is_comm else is_alt_comm) || slp_is_commutative_with(v, matching);
        if is_alt_shuffle(s) && matching == s_alt {
            for vo: vops {
                x := vo[0];
                if is_inst(x) && is_binary_op(inst_op(x)) && table_contains(*operands, x) return false;
            }
        }
        if is_alt_shuffle(s) && matching == s_main for k: 0..cast(s64) nops(v) - 1 table_set(*operands, op(v, cast(u32) k), true);
        first_cands(*cands, ops, vops[0][0], vops[1][0], is_comm_inst);
        best_op, is_best_const, score := find_best(cands);
        is_original_better := (ifx best_op < 0 then op_size else best_op) >= op_size;
        array_reset_keeping_memory(*cands);
        second_cands(*cands, main_ops, ifx is_original_better then -1 else best_op, copyable_ops[0], copyable_ops[1], is_main_comm);
        second_op_size := cands.count;
        // BestOp.value_or(OpSize - 1) - OpSize as unsigned -> int
        prev2 := ifx is_original_better then (ifx best_op < 0 then op_size - 1 else best_op) - op_size else -1;
        second_cands(*cands, ops, prev2, vops[0][0], vops[1][0], is_comm_inst);
        second_best_op, is_second_best_const, second_score := find_best(cands);
        if best_op < 0 && second_best_op < 0 return false;
        is_second_original_better := (ifx second_best_op < 0 then second_op_size else second_best_op) >= second_op_size;
        if is_original_better && is_second_original_better return false;
        if best_op < 0 && is_second_original_better return false;
        if second_best_op < 0 && is_original_better return false;
        if !is_original_better && is_best_const && is_second_original_better && !is_second_best_const return false;
        if best_op >= 0 && is_original_better && !is_best_const && !is_second_original_better && is_second_best_const return false;
        if ((score > second_score || (score <= LA_SCORE_ALT_OPCODES && score == second_score)) && is_original_better) ||
           (is_second_original_better && (second_score > score || (score <= LA_SCORE_ALT_OPCODES && score == second_score)))
            return false;
    }
    return true;
}

// TTI::isLegalAltInstr(VecTy, Opcode0, Opcode1, OpcodeMask)
tti_is_legal_alt_instr :: (t: *Tti, vec_ty: Type_Id, opc0: Opcode, opc1: Opcode, mask: [] bool) -> bool {
    if t.kind != .X86 return false;
    n := cast(s64) type_count(vec_ty);
    if !has_single_bit(cast(u64) n) return false;
    for lane: 0..n-1 {
        o := ifx mask[lane] then opc1 else opc0;
        if lane % 2 == 0 && o != .FSUB return false;
        if lane % 2 == 1 && o != .FADD return false;
    }
    e := type_elem(vec_ty);
    if type_kind(e) == .FLOAT return st_hasSSE3(*t.xl) && n % 4 == 0;
    if type_kind(e) == .DOUBLE return st_hasSSE3(*t.xl) && n % 2 == 0;
    return false;
}

// buildInstructionsState(VL, R, WithProfitabilityCheck, SkipSameCodeCheck)
ica_build_instructions_state :: (vl: [] Value_Id, with_profitability_check := false, skip_same_code_check := false) -> Inst_State {
    a: Ica_State;
    return ica_build_instructions_state_a(*a, vl, with_profitability_check, skip_same_code_check);
}
ica_build_instructions_state_a :: (a: *Ica_State, vl: [] Value_Id, with_profitability_check := false, skip_same_code_check := false) -> Inst_State {
    s := ifx skip_same_code_check || !slp_all_same_block(vl) then IS_INVALID else slp_get_same_opcode(vl);
    select_op: Value_Id = NONE;
    if !is_valid(s) && slp_all_same_block(vl) {
        all := true;
        for v: vl {
            if is_inst(v) && inst_op(v) == .SELECT { if select_op == NONE select_op = v; continue; }
            if (is_inst(v) && inst_op(v) == .ZEXT && vtype(op(v, 0)) == type_int(1)) || pm_poison(v) continue;
            all = false; break;
        }
        if all && select_op != NONE return .{select_op, select_op, false};
    }
    if is_valid(s) && is_alt_shuffle(s) {
        sty := vtype(s.main);
        vec_ty := slp_widened_type(sty, cast(u64) vl.count);
        mask := slp_alt_instr_mask(vl, sty, is_opcode(s), is_alt_opcode(s));
        if tti_is_legal_alt_instr(slp.tti, vec_ty, is_opcode(s), is_alt_opcode(s), mask) return s;
    } else if is_valid(s) {
        ok := !slp_cl.copyable || !is_binary_op(is_opcode(s));
        if !ok {
            ok = true;
            for v: vl {
                if !is_inst(v) || inst_op(v) == is_opcode(s) || (is_opcode(s) == .ADD && inst_op(v) == .SHL) continue;
                ok = false; break;
            }
        }
        if ok return s;
    }
    if !slp_cl.copyable return s;
    ica_find_and_set_main_instruction(a, vl);
    if a.main_op == NONE return s;
    orig_s := s;
    s = .{a.main_op, a.main_op, true};
    if is_valid(orig_s) && !ica_is_copyable_preferable(a, vl, orig_s, s) return orig_s;
    if !with_profitability_check return s;
    operands := ica_build_operands(a, s, vl);
    build_cands :: (c: *[..] [2] Value_Id, v1: Value_Id, v2: Value_Id) {
        if v1 != v2 && is_inst(v1) && inst_op(v1) == .PHI return;
        i1 := is_inst(v1); i2 := is_inst(v2);
        if i1 && i2 && inst_op(v1) == inst_op(v2) && inst_block(v1) != inst_block(v2) return;
        array_add(c, .[v1, ifx i1 || i2 then v2 else v1]);
    }
    if vl.count == 2 {
        c1: [..] [2] Value_Id; c1.allocator = temp;
        c2: [..] [2] Value_Id; c2.allocator = temp;
        build_cands(*c1, operands[0][0], operands[0][1]);
        build_cands(*c2, operands[1][0], operands[1][1]);
        res := c1.count > 0 && c2.count > 0 && slp_find_best_root_pair(c1) >= 0 && slp_find_best_root_pair(c2) >= 0;
        if !res && slp_is_commutative(a.main_op) {
            array_reset_keeping_memory(*c1); array_reset_keeping_memory(*c2);
            build_cands(*c1, operands[0][0], operands[1][1]);
            build_cands(*c2, operands[1][0], operands[0][1]);
            res = c1.count > 0 && c2.count > 0 && slp_find_best_root_pair(c1) >= 0 && slp_find_best_root_pair(c2) >= 0;
        }
        if !res return orig_s;
        scalar_cost := tti_instruction_cost(slp.tti, s.main, TCK_RECIP_THROUGHPUT);
        vec_ty := slp_widened_type(vtype(s.main), cast(u64) vl.count);
        vector_cost: Cost;
        if ica_is_supported_opcode(a.main_opcode) vector_cost = tti_arith_cost(slp.tti, a.main_opcode, vec_ty, TCK_RECIP_THROUGHPUT);
        else fatal("internal: slp: unexpected instruction");
        if vector_cost > scalar_cost return orig_s;
        return s;
    }
    copyable_num := 0;
    for vl if is_copyable_element(s, it) copyable_num += 1;
    if copyable_num < vl.count / 2 return s;
    limit := vl.count / 24;
    if copyable_num >= vl.count - limit || (copyable_num >= vl.count - 1 && vl.count > 4) || copyable_num >= SLP_MAX_PHI_NUM_OPERANDS {
        all := true;
        for v: vl if !((is_inst(v) && inst_op(v) == .PHI) || !is_copyable_element(s, v)) { all = false; break; }
        if all return orig_s;
    }
    if slp_is_commutative(a.main_op) {
        best_front: Value_Id = NONE;
        for k: 0..operands[0].count-1 {
            l := *operands[0][k]; r := *operands[operands.count - 1][k];
            if !is_inst(l.*) && is_inst(r.*) {
                best_front = r.*;
                t := l.*; l.* = r.*; r.* = t;
                continue;
            }
            if (is_constant_kind(vkind(l.*)) && !pm_zero(r.*)) || pm_zero(l.*) {
                if is_inst(r.*) best_front = r.*;
                t := l.*; l.* = r.*; r.* = t;
                continue;
            }
            if is_inst(l.*) best_front = l.*;
        }
        if best_front != NONE && is_inst(best_front) {
            best_opc := inst_op(best_front);
            for k: 0..operands[0].count-1 {
                l := *operands[0][k]; r := *operands[operands.count - 1][k];
                if !is_inst(r.*) continue;
                if inst_op(r.*) == best_opc { t := l.*; l.* = r.*; r.* = t; }
            }
        }
    }
    n_inst := 0;
    for operands[operands.count - 1] if is_inst(it) n_inst += 1;
    if n_inst > 1 return orig_s;
    check_operand :: (ops: [] Value_Id, front_size: s64, vl_size: s64) -> bool {
        if slp_all_constant(ops) || slp_is_splat(ops) return true;
        LIMIT :: 4;
        if front_size >= LIMIT {
            keys: [..] Value_Id; keys.allocator = temp;
            counts: [..] s64; counts.allocator = temp;
            for v: ops {
                if pm_undef_value(v) continue;
                found := false;
                for keys if it == v { counts[it_index] += 1; found = true; break; }
                if !found { array_add(*keys, v); array_add(*counts, 1); }
            }
            if keys.count == 2 { for counts if it == 1 return true; }
        }
        ops_s := ica_build_instructions_state(ops);
        if !is_valid(ops_s) || (is_opcode(ops_s) == .PHI && !slp_all_same_block(ops)) return false;
        cn := 0;
        for ops if is_copyable_element(ops_s, it) cn += 1;
        return cn <= vl_size / 2;
    }
    if !check_operand(operands[0], operands[0].count, vl.count) return orig_s;
    return s;
}

// buildOperands(S, VL)
ica_build_operands :: (a: *Ica_State, s: Inst_State, vl: [] Value_Id) -> [..] [..] Value_Id {
    if !s.has_copyables return ica_build_original_operands(a, s, vl);
    a.main_op = s.main;
    a.main_opcode = is_opcode(s);
    is_comm := slp_is_commutative(a.main_op) && nops(a.main_op) == 2;
    operands := new_operand_lists(nops(a.main_op), vl.count);
    for v, idx: vl {
        ofv := ica_get_operands(a, s, v);
        for o, k: ofv operands[k][idx] = o;
    }
    if is_comm {
        can_swap :: (s: Inst_State, v: Value_Id) -> bool { return slp_is_commutative_with(is_matching_main_or_alt(s, v), v); }
        Pair_Info :: struct { k0: u32; k1: u32; fwd: u32; rev: u32; }
        pairs: [..] Pair_Info; pairs.allocator = temp;
        maj0: u32 = 0; maj1: u32 = 0;
        for v, idx: vl {
            if is_copyable_element(s, v) || pm_poison(v) continue;
            id0 := slp_value_id(operands[0][idx]); id1 := slp_value_id(operands[1][idx]);
            if id0 == id1 continue;
            mn := min(id0, id1); mx := max(id0, id1);
            pi: *Pair_Info = null;
            for * pairs if it.k0 == mn && it.k1 == mx { pi = it; break; }
            if !pi { array_add(*pairs, .{mn, mx, 0, 0}); pi = *pairs[pairs.count - 1]; }
            if id0 < id1 pi.fwd += 1; else pi.rev += 1;
        }
        best_count: u32 = 0;
        for p: pairs {
            total := p.fwd + p.rev;
            if total > best_count {
                best_count = total;
                if p.fwd >= p.rev { maj0 = p.k0; maj1 = p.k1; } else { maj0 = p.k1; maj1 = p.k0; }
            }
        }
        lat0 := 0; lat1 := 0; total_nc := 0;
        is_load :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .LOAD; }
        for v, idx: vl {
            if is_copyable_element(s, v) || pm_poison(v) continue;
            if best_count > 0 {
                id0 := slp_value_id(operands[0][idx]); id1 := slp_value_id(operands[1][idx]);
                if id0 == maj1 && id1 == maj0 && can_swap(s, v) { t := operands[0][idx]; operands[0][idx] = operands[1][idx]; operands[1][idx] = t; }
            }
            total_nc += 1;
            lat0 += cast(s64) is_load(operands[0][idx]);
            lat1 += cast(s64) is_load(operands[1][idx]);
        }
        if total_nc > 1 && lat1 > lat0 && lat1 * 2 > total_nc {
            for v, idx: vl {
                if is_copyable_element(s, v) || pm_poison(v) continue;
                if !is_load(operands[0][idx]) && is_load(operands[1][idx]) && can_swap(s, v) {
                    t := operands[0][idx]; operands[0][idx] = operands[1][idx]; operands[1][idx] = t;
                }
            }
        }
    }
    return operands;
}
