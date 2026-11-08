// LoopNest and print<loopnest>.
// Port of llvm/lib/Analysis/LoopNestAnalysis.cpp (LLVM 23.1.5): LoopNest (breadth_first loops, getMaxPerfectDepth),
// arePerfectlyNested / analyzeLoopNestForPerfectNest, checkLoopsStructure, checkSafeInstruction,
// getOuterLoopLatchCmp / getInnerLoopGuardCmp, skipEmptyBlockUntil, operator<<(LoopNest), LoopNestPrinterPass;
// and of the Loop queries it needs from llvm/lib/Analysis/LoopInfo.cpp: getLatchCmpInst, findFinalIVValue,
// LoopBounds::getBounds, getBounds, getInductionVariable, getLoopGuardBranch, isRotatedForm; plus
// InductionDescriptor::isInductionPHI(Phi, L, SE, D) (llvm/lib/Analysis/IVDescriptors.cpp) and the load case of
// isSafeToSpeculativelyExecute (llvm/lib/Analysis/ValueTracking.cpp).

// Loop::getLatchCmpInst (NONE = nullptr)
li_latch_cmp_inst :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    latch := li_loop_latch(li, l);
    if latch == NONE return NONE;
    t := block_terminator(latch);
    if t == NONE || inst_op(t) != .CONDBR return NONE;
    c := op(t, 0);
    if is_inst(c) && inst_op(c) == .ICMP return c;
    return NONE;
}

// InductionDescriptor::isInductionPHI(Phi, TheLoop, SE, D): (ok, start value, step SCEV, induction binop or NONE)
is_induction_phi :: (phi: Value_Id, l: Loop_Id) -> (bool, Value_Id, Scev_Id, Value_Id) {
    li := se.li;
    if !sc_is_scevable(vtype(phi)) return false, NONE, 0, NONE;
    phi_scev := sc_get_scev(phi);
    if !(sc_is_addrec(phi_scev) && sc_is_affine(phi_scev) && sc_loop(phi_scev) == l) return false, NONE, 0, NONE;
    step := sc_op(phi_scev, 1);
    ph := li_loop_preheader(li, l);
    if ph == NONE return false, NONE, 0, NONE;
    start := phi_incoming_value_for_block(phi, ph);
    latch := li_loop_latch(li, l);
    if latch == NONE return false, NONE, 0, NONE;
    if type_kind(vtype(phi)) == .INT {
        bo := phi_incoming_value_for_block(phi, latch);
        if !is_binary_operator(bo) bo = NONE;
        return true, start, step, bo;
    }
    return true, start, step, NONE;
}

// Loop::getInductionVariable (NONE = nullptr)
li_induction_variable :: (l: Loop_Id) -> Value_Id {
    li := se.li;
    if !li_is_loop_simplify_form(li, l) return NONE;
    header := li_header(li, l);
    cmp := li_latch_cmp_inst(li, l);
    if cmp == NONE return NONE;
    op0 := op(cmp, 0); op1 := op(cmp, 1);
    for iv: block_insts(header) {
        if inst_op(iv) != .PHI break;
        ok, start, step, bo := is_induction_phi(iv, l);
        if !ok continue;
        latch := li_loop_latch(li, l);
        step_inst := phi_incoming_value_for_block(iv, latch);
        if step_inst == op0 || step_inst == op1 return iv;
        if iv == op0 || iv == op1 return iv;
    }
    return NONE;
}

Loop_Bounds :: struct { ok: bool; initial: Value_Id; step_inst: Value_Id; step_value: Value_Id; final: Value_Id; }
// Loop::getBounds -> LoopBounds::getBounds
li_get_bounds :: (l: Loop_Id) -> Loop_Bounds {
    r: Loop_Bounds;
    iv := li_induction_variable(l);
    if iv == NONE return r;
    ok, initial, step, step_inst := is_induction_phi(iv, l);
    if !ok return r;
    if initial == NONE || step_inst == NONE return r;
    step_value: Value_Id = NONE;
    if sc_get_scev(op(step_inst, 1)) == step step_value = op(step_inst, 1);
    else if sc_get_scev(op(step_inst, 0)) == step step_value = op(step_inst, 0);
    // findFinalIVValue
    cmp := li_latch_cmp_inst(se.li, l);
    if cmp == NONE return r;
    final: Value_Id = NONE;
    o0 := op(cmp, 0); o1 := op(cmp, 1);
    if o0 == iv || o0 == step_inst final = o1;
    else if o1 == iv || o1 == step_inst final = o0;
    if final == NONE return r;
    r.ok = true; r.initial = initial; r.step_inst = step_inst; r.step_value = step_value; r.final = final;
    return r;
}

// Loop::isRotatedForm
li_is_rotated_form :: (li: *Loop_Info, l: Loop_Id) -> bool {
    latch := li_loop_latch(li, l);
    return latch != NONE && li_is_loop_exiting(li, l, latch);
}

// Loop::getLoopGuardBranch (NONE = nullptr)
li_loop_guard_branch :: (li: *Loop_Info, l: Loop_Id) -> Value_Id {
    if !li_is_loop_simplify_form(li, l) return NONE;
    preheader := li_loop_preheader(li, l);
    if !li_is_rotated_form(li, l) return NONE;
    exit_from_latch := li_unique_exit_block(li, l);
    if exit_from_latch == NONE return NONE;
    guard_bb := block_unique_predecessor(preheader);
    if guard_bb == NONE return NONE;
    guard_bi := block_terminator(guard_bb);
    if inst_op(guard_bi) != .CONDBR return NONE;
    other := ifx get_successor(guard_bi, 0) == preheader then get_successor(guard_bi, 1) else get_successor(guard_bi, 0);
    if skip_empty_block_until(exit_from_latch, other, true) == other return guard_bi;
    return NONE;
}

block_inst_count :: (b: Value_Id) -> s64 { n := 0; for block_insts(b) n += 1; return n; }

// LoopNest::skipEmptyBlockUntil
skip_empty_block_until :: (from: Value_Id, end: Value_Id, check_unique_pred := false) -> Value_Id {
    if from == end || block_unique_successor(from) == NONE return from;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    bb := block_unique_successor(from);
    pred_bb := from;
    while bb != NONE && bb != end && block_inst_count(bb) == 1 && !table_contains(*visited, bb) &&
          (!check_unique_pred || block_unique_predecessor(bb) != NONE) {
        table_set(*visited, bb, true);
        pred_bb = bb;
        bb = block_unique_successor(bb);
    }
    if bb == end return end;
    return pred_bb;
}

// checkLoopsStructure
check_loops_structure :: (outer: Loop_Id, inner: Loop_Id) -> bool {
    li := se.li;
    if li_subloops(li, outer).count != 1 || li_parent(li, inner) != outer return false;
    if !li_is_loop_simplify_form(li, outer) || !li_is_loop_simplify_form(li, inner) return false;
    outer_header := li_header(li, outer);
    outer_latch := li_loop_latch(li, outer);
    inner_preheader := li_loop_preheader(li, inner);
    inner_latch := li_loop_latch(li, inner);
    inner_exit := li_exit_block(li, inner);
    if li_exiting_block(li, outer) != outer_latch || li_exiting_block(li, inner) != inner_latch || inner_exit == NONE return false;
    contains_lcssa_phi :: (b: Value_Id) -> bool {
        for pn: block_insts(b) { if inst_op(pn) != .PHI break; if nops(pn) == 1 return true; }
        return false;
    }
    is_extra_phi_block :: (b: Value_Id, inner_exit: Value_Id, outer_header: Value_Id) -> bool {
        first := block_first_non_phi(b);
        if first != block_terminator(b) return false;
        for pn: block_insts(b) {
            if inst_op(pn) != .PHI break;
            for k: 0..cast(s64) nops(pn) - 1 {
                ib := phi_block(pn, cast(u32) k);
                if ib != inner_exit && ib != outer_header return false;
            }
        }
        return true;
    }
    extra_phi_block: Value_Id = NONE;
    if outer_header != inner_preheader {
        single_succ := skip_empty_block_until(outer_header, inner_preheader);
        if single_succ != inner_preheader {
            bi := block_terminator(single_succ);
            if inst_op(bi) != .CONDBR || bi != li_loop_guard_branch(li, inner) return false;
            inner_exit_contains_lcssa := contains_lcssa_phi(inner_exit);
            for k: 0..1 {
                succ := get_successor(bi, cast(u32) k);
                potential_inner_preheader := succ;
                potential_outer_latch := succ;
                if block_inst_count(succ) == 1 {
                    potential_inner_preheader = skip_empty_block_until(succ, inner_preheader);
                    potential_outer_latch = skip_empty_block_until(succ, outer_latch);
                }
                if potential_inner_preheader == inner_preheader continue;
                if potential_outer_latch == outer_latch continue;
                if inner_exit_contains_lcssa && is_extra_phi_block(succ, inner_exit, outer_header) &&
                   block_get_single_successor(succ) == outer_latch {
                    extra_phi_block = succ;
                    continue;
                }
                return false;
            }
        }
    }
    if (extra_phi_block == NONE || skip_empty_block_until(li_exit_block(li, inner), extra_phi_block) != extra_phi_block) &&
       skip_empty_block_until(li_exit_block(li, inner), outer_latch) != outer_latch
        return false;
    return true;
}

// isSafeToSpeculativelyExecute(I) with its load case (the other cases: pass_loop_simplify.jai)
is_safe_to_speculatively_execute_full :: (i: Value_Id) -> bool {
    if inst_op(i) == .LOAD {
        // mustSuppressSpeculation
        if !is_unordered(i) return false;
        fa := attr_list_fn(glob(inst_fn(i)).attrs);
        if attr_set_has(fa, .SanitizeThread) || attr_set_has(fa, .SanitizeAddress) || attr_set_has(fa, .SanitizeHWAddress) return false;
        ty := vtype(i);
        if !type_is_sized(ty) || sc_type_is_scalable(ty) return false;
        visited: [..] Value_Id; visited.allocator = temp;
        return deref_and_aligned(op(i, 0), inst(i).align, dl_type_store_size(ty), NONE, *visited, 16);
    }
    return is_safe_to_speculatively_execute(i);
}

// checkSafeInstruction
check_safe_instruction :: (i: Value_Id, inner_guard_cmp: Value_Id, outer_latch_cmp: Value_Id, outer_lb: Loop_Bounds) -> bool {
    o := inst_op(i);
    allowed := is_safe_to_speculatively_execute_full(i) || o == .PHI || o == .BR || o == .CONDBR;
    if !allowed return false;
    if (is_binary_operator(i) && i != outer_lb.step_inst) || ((o == .ICMP || o == .FCMP) && i != outer_latch_cmp && i != inner_guard_cmp)
        return false;
    return true;
}

Loop_Nest_Enum :: enum u8 { PERFECT; IMPERFECT; INVALID_STRUCTURE; OUTER_LOWER_BOUND_UNKNOWN; }

// analyzeLoopNestForPerfectNest
analyze_loop_nest_for_perfect_nest :: (outer: Loop_Id, inner: Loop_Id) -> Loop_Nest_Enum {
    li := se.li;
    if !check_loops_structure(outer, inner) return .INVALID_STRUCTURE;
    outer_lb := li_get_bounds(outer);
    if !outer_lb.ok return .OUTER_LOWER_BOUND_UNKNOWN;
    // getOuterLoopLatchCmp
    outer_latch_cmp: Value_Id = NONE;
    {
        t := block_terminator(li_loop_latch(li, outer));
        c := op(t, 0);
        if is_inst(c) && (inst_op(c) == .ICMP || inst_op(c) == .FCMP) outer_latch_cmp = c;
    }
    // getInnerLoopGuardCmp
    inner_guard_cmp: Value_Id = NONE;
    {
        g := li_loop_guard_branch(li, inner);
        if g != NONE {
            c := op(g, 0);
            if is_inst(c) && (inst_op(c) == .ICMP || inst_op(c) == .FCMP) inner_guard_cmp = c;
        }
    }
    only_safe :: (b: Value_Id, igc: Value_Id, olc: Value_Id, lb: Loop_Bounds) -> bool {
        for i: block_insts(b) if !check_safe_instruction(i, igc, olc, lb) return false;
        return true;
    }
    outer_header := li_header(li, outer);
    outer_latch := li_loop_latch(li, outer);
    inner_preheader := li_loop_preheader(li, inner);
    if !only_safe(outer_header, inner_guard_cmp, outer_latch_cmp, outer_lb) ||
       !only_safe(outer_latch, inner_guard_cmp, outer_latch_cmp, outer_lb) ||
       (inner_preheader != outer_header && !only_safe(inner_preheader, inner_guard_cmp, outer_latch_cmp, outer_lb)) ||
       !only_safe(li_exit_block(li, inner), inner_guard_cmp, outer_latch_cmp, outer_lb)
        return .IMPERFECT;
    return .PERFECT;
}
are_perfectly_nested :: (outer: Loop_Id, inner: Loop_Id) -> bool { return analyze_loop_nest_for_perfect_nest(outer, inner) == .PERFECT; }

// LoopNest::getMaxPerfectDepth
get_max_perfect_depth :: (root: Loop_Id) -> u32 {
    li := se.li;
    current := root;
    depth: u32 = 1;
    while li_subloops(li, current).count == 1 {
        inner := li_subloops(li, current)[0];
        if !are_perfectly_nested(current, inner) break;
        current = inner;
        depth += 1;
    }
    return depth;
}

// LoopNestPrinterPass::run: LoopNest::getLoopNest(L, AR.SE), then OS << *LN
loop_nest_printer_run :: (l: Loop_Id, lar: *Loop_Std_Results) -> Preserved {
    se = lar.se;
    li := lar.li;
    max_perfect_depth := get_max_perfect_depth(l);
    // Loops: breadth_first(&Root)
    loops: [..] Loop_Id; loops.allocator = temp;
    array_add(*loops, l);
    k := 0;
    while k < loops.count {
        for li_subloops(li, loops[k]) array_add(*loops, it);
        k += 1;
    }
    nest_depth := li_depth(li, loops[loops.count - 1]) - li_depth(li, loops[0]) + 1;
    sb: String_Builder; sb.allocator = temp;
    append(*sb, "IsPerfect=");
    append(*sb, ifx max_perfect_depth == nest_depth then "true" else "false");
    print_to_builder(*sb, ", Depth=%", nest_depth);
    append(*sb, ", OutermostLoop: "); append(*sb, li_loop_name(li, l));
    append(*sb, ", Loops: ( ");
    for loops { append(*sb, li_loop_name(li, it)); append(*sb, " "); }
    append(*sb, ")\n");
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}

// BasicBlock::getSingleSuccessor: exactly one successor edge (value_tracking2.jai's block_single_successor is
// getUniqueSuccessor-like)
block_get_single_successor :: (b: Value_Id) -> Value_Id {
    t := block_terminator(b);
    if t == NONE || num_successors(t) != 1 return NONE;
    return get_successor(t, 0);
}

// Loop::getName
li_loop_name :: (li: *Loop_Info, l: Loop_Id) -> string {
    n := vname(li_header(li, l));
    if n.count return n;
    return "<unnamed loop>";
}
