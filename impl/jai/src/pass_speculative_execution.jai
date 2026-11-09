// SpeculativeExecution: port of llvm/lib/Transforms/Scalar/SpeculativeExecution.cpp (runImpl, runOnBasicBlock,
// ComputeSpeculationCost, considerHoistingFromTo). Parameters: speculative-execution<only-if-divergent-target>.

se_cl: struct {
    max_speculation_cost: s64 = 7;          // -spec-exec-max-speculation-cost
    max_not_hoisted: s64 = 5;               // -spec-exec-max-not-hoisted
    only_if_divergent_target := false;      // -spec-exec-only-if-divergent-target
};

se_compute_speculation_cost :: (i: Value_Id, tti: *Tti) -> Cost {
    if inst_op(i) == {
        case .GEP; #through; case .ADD; #through; case .MUL; #through; case .AND; #through; case .OR; #through;
        case .SELECT; #through; case .SHL; #through; case .SUB; #through; case .LSHR; #through; case .ASHR; #through;
        case .XOR; #through; case .ZEXT; #through; case .SEXT; #through; case .CALL; #through; case .BITCAST; #through;
        case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .ADDRSPACECAST; #through;
        case .FPTOUI; #through; case .FPTOSI; #through; case .UITOFP; #through; case .SITOFP; #through;
        case .FPEXT; #through; case .FPTRUNC; #through; case .FADD; #through; case .FSUB; #through; case .FMUL; #through;
        case .FDIV; #through; case .FREM; #through; case .FNEG; #through; case .ICMP; #through; case .FCMP; #through;
        case .TRUNC; #through; case .FREEZE; #through; case .EXTRACTELEMENT; #through; case .INSERTELEMENT; #through;
        case .SHUFFLEVECTOR; #through; case .EXTRACTVALUE; #through; case .INSERTVALUE;
            return tti_instruction_cost(tti, i, TCK_SIZE_AND_LATENCY);
    }
    return COST_INVALID;
}

se_consider_hoisting_from_to :: (from: Value_Id, to: Value_Id, tti: *Tti) -> bool {
    not_hoisted: Table(Value_Id, bool); not_hoisted.allocator = temp;
    total: Cost = 0;
    not_hoisted_count: s64 = 0;
    for i: block_insts(from) {
        c := se_compute_speculation_cost(i, tti);
        ok := cost_valid(c) && is_safe_to_speculatively_execute(i);
        if ok {
            for k: 0..cast(s64) nops(i) - 1 {
                v := op(i, cast(u32) k);
                if is_inst(v) && table_contains(*not_hoisted, v) { ok = false; break; }
            }
        }
        if ok {
            total = cost_add(total, c);
            if total > se_cl.max_speculation_cost return false;
        } else {
            not_hoisted_count += 1;
            if not_hoisted_count > se_cl.max_not_hoisted return false;
            table_set(*not_hoisted, i, true);
        }
    }
    x := block_first(from);
    while x != NONE {
        cur := x;
        x = inst_next(x);
        if !table_contains(*not_hoisted, cur) {
            inst_move_before_dbg(cur, block_terminator(to));
            drop_location(cur);
        }
    }
    return true;
}

se_run_on_basic_block :: (b: Value_Id, tti: *Tti) -> bool {
    bi := block_terminator(b);
    if bi == NONE || inst_op(bi) != .CONDBR return false;
    s0 := get_successor(bi, 0); s1 := get_successor(bi, 1);
    if b == s0 || b == s1 || s0 == s1 return false;
    if block_single_predecessor(s0) != NONE && block_single_successor(s0) == s1 return se_consider_hoisting_from_to(s0, b, tti);
    if block_single_predecessor(s1) != NONE && block_single_successor(s1) == s0 return se_consider_hoisting_from_to(s1, b, tti);
    ss1 := block_single_successor(s1);
    if block_single_predecessor(s0) != NONE && block_single_predecessor(s1) != NONE && ss1 != NONE && ss1 != b &&
       ss1 == block_single_successor(s0) {
        if block_size(s1) == 1 return se_consider_hoisting_from_to(s0, b, tti);
        if block_size(s0) == 1 return se_consider_hoisting_from_to(s1, b, tti);
    }
    return false;
}

speculative_execution_run :: (f: Value_Id, name: string) -> Preserved {
    only_if_divergent := se_cl.only_if_divergent_target;
    if name != "speculative-execution" {
        if name == "speculative-execution<only-if-divergent-target>" only_if_divergent = true;
        else if name != "speculative-execution<>" fatal("invalid pass pipeline: invalid SpeculativeExecutionPass parameter in '%'", name);
    }
    tti := tti_get(f);
    // TTI::hasBranchDivergence: false for X86 and for NoTTI
    if only_if_divergent return PRESERVE_ALL;
    changed := false;
    for bb: fn_blocks(f) if se_run_on_basic_block(bb, tti) changed = true;
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}
