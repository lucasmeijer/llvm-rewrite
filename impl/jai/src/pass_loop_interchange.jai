// LoopInterchangePass: a port of llvm/lib/Transforms/Scalar/LoopInterchange.cpp (LLVM 23.1.5), a LoopNest pass in
// default<O1..O3> (PTO.LoopInterchange = -enable-loopinterchange, on by default): populateDependencyMatrix (with
// DependenceInfo, dependence_analysis.jai), LoopInterchangeLegality, LoopInterchangeProfitability (the instorder
// and vectorize rules) and LoopInterchangeTransform.
//
// Not ported, failing loudly: the `cache` profitability rule (CacheCost, LoopCacheAnalysis.cpp) and
// -loop-interchange-reduction-to-mem (reduction2Memory). Optimization remarks are never printed, so they are left
// out.

Li_Rule :: enum u8 { CACHE; INSTORDER; VECTORIZE; IGNORE; }

li_cl: struct {
    cost_threshold: s64 = 0;          // -loop-interchange-threshold
    max_mem_instr_ratio: s64 = 4;     // -loop-interchange-max-mem-instr-ratio
    min_loop_nest_depth: s64 = 2;     // -loop-interchange-min-loop-nest-depth
    max_loop_nest_depth: s64 = 10;    // -loop-interchange-max-loop-nest-depth
    rules: [..] Li_Rule;              // -loop-interchange-profitabilities (cl::list, CommaSeparated)
    rules_set: bool;                  // a user value replaced the list_init default
    reduction_to_mem := false;        // -loop-interchange-reduction-to-mem
    cache_line_size: s64 = 0;         // TargetTransformInfo.cpp -cache-line-size (only CacheCost reads it)
};

li_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    int_value :: (name: string, value: string, has_value: bool) -> s64 {
        v, ok := string_to_int(value);
        if !has_value || !ok fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == {
        case "loop-interchange-threshold"; li_cl.cost_threshold = int_value(name, value, has_value); return true;
        case "loop-interchange-max-mem-instr-ratio"; li_cl.max_mem_instr_ratio = int_value(name, value, has_value); return true;
        case "loop-interchange-min-loop-nest-depth"; li_cl.min_loop_nest_depth = int_value(name, value, has_value); return true;
        case "loop-interchange-max-loop-nest-depth"; li_cl.max_loop_nest_depth = int_value(name, value, has_value); return true;
        case "cache-line-size"; li_cl.cache_line_size = int_value(name, value, has_value); return true;
        case "loop-interchange-reduction-to-mem";
            if !has_value || value == "true" || value == "1" li_cl.reduction_to_mem = true;
            else if value == "false" || value == "0" li_cl.reduction_to_mem = false;
            else fatal("invalid boolean value '%' for option -%", value, name);
            return true;
        case "loop-interchange-profitabilities";
            if !li_cl.rules_set { li_cl.rules.count = 0; li_cl.rules_set = true; }
            for p: split(value, ",") {
                if p == {
                    case "cache"; array_add(*li_cl.rules, .CACHE);
                    case "instorder"; array_add(*li_cl.rules, .INSTORDER);
                    case "vectorize"; array_add(*li_cl.rules, .VECTORIZE);
                    case "ignore"; array_add(*li_cl.rules, .IGNORE);
                    case; fatal("invalid value '%' for option -loop-interchange-profitabilities", p);
                }
            }
            return true;
    }
    return false;
}
li_rules :: () -> [] Li_Rule {
    if li_cl.rules_set return li_cl.rules;
    return .[.INSTORDER, .VECTORIZE];
}

// LoopNest::getLoops(): breadth_first(&Root)
loop_nest_loops_bfs :: (li: *Loop_Info, root: Loop_Id) -> [..] Loop_Id {
    out: [..] Loop_Id; out.allocator = temp;
    array_add(*out, root);
    i := 0;
    while i < out.count {
        for li_subloops(li, out[i]) array_add(*out, it);
        i += 1;
    }
    return out;
}

// A direction vector: N loop directions plus the forward flag ('<' or '*')
Li_Dep_Row :: [..] u8;

Li_Ctx :: struct {
    li: *Loop_Info;
    dt: *Dom_Tree;
    di: *Da_Info;
    f: Value_Id;
}

// populateDependencyMatrix
li_populate_dependency_matrix :: (c: *Li_Ctx, dep_matrix: *[..] Li_Dep_Row, level: s64, l: Loop_Id) -> bool {
    mem_instr: [..] Value_Id; mem_instr.allocator = temp;
    num_insts := 0;
    for b: li_blocks(c.li, l) {
        for i: block_insts(b) {
            num_insts += 1;
            o := inst_op(i);
            if o == .LOAD || o == .STORE {
                if !inst_is_simple(i) return false;
                array_add(*mem_instr, i);
            }
        }
    }
    n := mem_instr.count;
    if li_cl.max_mem_instr_ratio * num_insts < n * n return false;
    seen: Table(string, s64); seen.allocator = temp;
    for ii: 0..n - 1 {
        for jj: ii..n - 1 {
            src := mem_instr[ii]; dst := mem_instr[jj];
            if inst_op(src) == .LOAD && inst_op(dst) == .LOAD continue;
            d := da_depends(c.di, src, dst);
            if !d continue;
            dep_normalize(d);
            dep: [..] u8; dep.allocator = temp;
            levels := dep_levels(d);
            for k: 1..levels {
                dir := dep_direction(d, k);
                ch: u8;
                if dir == DV_LT ch = #char "<";
                else if dir == DV_GT ch = #char ">";
                else if dir == DV_EQ ch = #char "=";
                else ch = #char "*";
                array_add(*dep, ch);
            }
            if d.confused { dep.count = 0; for 1..level array_add(*dep, #char "*"); }
            while dep.count != level array_add(*dep, #char "I");
            all_star := true;
            for dep if it != #char "*" { all_star = false; break; }
            if all_star return false;
            is_known_forward := true;
            if inst_block(src) != inst_block(dst) is_known_forward = false;
            else if d.src != src is_known_forward = false;
            array_add(*dep, #char "<");
            key := copy_string(cast(string) array_view(dep, 0, dep.count - 1),, allocator = temp);
            found, idx := table_find(*seen, key);
            if !found { idx = dep_matrix.count; table_set(*seen, key, idx); array_add(dep_matrix, dep); }
            if !is_known_forward { row := *dep_matrix.*[idx]; row.*[row.count - 1] = #char "*"; }
        }
    }
    return true;
}

li_interchange_dependencies :: (dep_matrix: *[..] Li_Dep_Row, from: s64, to: s64) {
    for * row: dep_matrix.* { t := row.*[to]; row.*[to] = row.*[from]; row.*[from] = t; }
}

// isLexicographicallyPositive: 1 = true, 0 = false, -1 = nullopt
li_is_lex_positive :: (dv: [] u8, begin: s64, end: s64) -> s64 {
    for k: begin..end - 1 {
        if dv[k] == #char "<" return 1;
        if dv[k] == #char ">" || dv[k] == #char "*" return 0;
    }
    return -1;
}

// isLegalToInterChangeLoops
li_is_legal_to_interchange :: (dep_matrix: [] Li_Dep_Row, inner_id: s64, outer_id: s64) -> bool {
    for row: dep_matrix {
        cur := array_copy(row,, allocator = temp);
        if li_is_lex_positive(cur, 0, outer_id) == 1 continue;
        if li_is_lex_positive(cur, outer_id, cur.count - 1) == 0 return false;
        t := cur[inner_id]; cur[inner_id] = cur[outer_id]; cur[outer_id] = t;
        if li_is_lex_positive(cur, outer_id, cur.count - 1) == 0 return false;
    }
    return true;
}

// isComputableLoopNest
li_is_computable_loop_nest :: (li: *Loop_Info, loops: [] Loop_Id) -> bool {
    for x: loops {
        if sc_get_backedge_taken_count(x) == SCEV_CNC return false;
        if li_num_back_edges(li, x) != 1 return false;
        if li_exiting_block(li, x) == NONE return false;
    }
    return true;
}

// ---------------------------------------------------------------- legality

Li_Legality :: struct {
    outer: Loop_Id;
    inner: Loop_Id;
    outer_inner_reductions: [..] Value_Id;   // SmallPtrSet
    inner_loop_inductions: [..] Value_Id;
    has_no_wrap_reductions: [..] Value_Id;
    has_no_inf_insts: [..] Value_Id;
}

value_users :: (v: Value_Id, out: *[..] Value_Id) {
    out.count = 0;
    u := ir.v_first_use[v];
    while u != NONE { array_add(out, ir.u_user[u]); u = ir.u_next[u]; }
}
contains_value :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }

// containsUnsafeInstructions
li_contains_unsafe_instructions :: (bb: Value_Id, skip: Value_Id) -> bool {
    for i: block_insts(bb) {
        if i == skip continue;
        if may_have_side_effects(i) || may_read_from_memory(i) return true;
    }
    return false;
}

// tightlyNested
li_tightly_nested :: (c: *Li_Ctx, outer: Loop_Id, inner: Loop_Id) -> bool {
    li := c.li;
    outer_header := li_header(li, outer);
    inner_ph := li_loop_preheader(li, inner);
    outer_latch := li_loop_latch(li, outer);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(outer_header, *succs);
    for succs if it != inner_ph && it != li_header(li, inner) return false;
    skip: Value_Id = NONE;
    if li_contains_unsafe_instructions(outer_header, skip) || li_contains_unsafe_instructions(outer_latch, skip) return false;
    if inner_ph != outer_header && li_contains_unsafe_instructions(inner_ph, skip) return false;
    inner_exit := li_exit_block(li, inner);
    succ_inner := skip_empty_block_until(inner_exit, outer_latch);
    if succ_inner != outer_latch return false;
    if li_contains_unsafe_instructions(inner_exit, skip) return false;
    return true;
}

// isLoopStructureUnderstood
li_is_loop_structure_understood :: (c: *Li_Ctx, lg: *Li_Legality) -> bool {
    li := c.li;
    inner_ph := li_loop_preheader(li, lg.inner);
    for ind: lg.inner_loop_inductions {
        for k: 0..cast(s64) nops(ind) - 1 {
            v := op(ind, cast(u32) k);
            if is_const(v) continue;
            if !is_inst(v) return false;
            if phi_block(ind, cast(u32) k) == inner_ph && !li_is_loop_invariant(li, lg.outer, v) return false;
        }
    }
    inner_latch := li_loop_latch(li, lg.inner);
    t := block_terminator(inner_latch);
    if inst_op(t) != .CONDBR return false;
    cmp := op(t, 0);
    if !is_inst(cmp) || (inst_op(cmp) != .ICMP && inst_op(cmp) != .FCMP) return false;
    op0 := op(cmp, 0); op1 := op(cmp, 1);
    is_path :: (v: Value_Id, inductions: [] Value_Id) -> bool {
        if contains_value(inductions, v) return true;
        if is_const(v) return true;
        if !is_inst(v) return false;
        if is_cast_op(inst_op(v)) return is_path(op(v, 0), inductions);
        if is_binary_op(inst_op(v)) return is_path(op(v, 0), inductions) && is_path(op(v, 1), inductions);
        return false;
    }
    p0 := is_path(op0, lg.inner_loop_inductions);
    p1 := is_path(op1, lg.inner_loop_inductions);
    if p0 && p1 return true;
    left: Value_Id = NONE; right: Value_Id = NONE;
    if p0 && !is_const(op0) { left = op0; right = op1; }
    else if p1 && !is_const(op1) { left = op1; right = op0; }
    if left == NONE return false;
    s := sc_get_scev(right);
    if !sc_is_loop_invariant(s, lg.outer) return false;
    return true;
}

// followLCSSA
li_follow_lcssa :: (v: Value_Id) -> Value_Id {
    if !is_inst(v) || inst_op(v) != .PHI return v;
    if phi_num_incoming(v) != 1 return v;
    return li_follow_lcssa(phi_value(v, 0));
}

// checkReductionKind
li_check_reduction_kind :: (c: *Li_Ctx, l: Loop_Id, phi: Value_Id, no_wrap: *[..] Value_Id, no_inf: *[..] Value_Id) -> bool {
    rd: Rdx_Desc;
    if !rdx_is_reduction_phi(phi, c.li, l, *rd, null, null, null, false) return false;
    if rd.exact_fp != NONE return false;
    if rd.kind == {
        case .OR; #through; case .AND; #through; case .XOR; #through;
        case .SMIN; #through; case .SMAX; #through; case .UMIN; #through; case .UMAX;
            return true;
        case .ANYOF; return false;
        case .FADD; #through; case .FMUL; #through; case .FMIN; #through; case .FMAX; #through;
        case .FMINIMUM; #through; case .FMAXIMUM; #through; case .FMINIMUMNUM; #through; case .FMAXIMUMNUM; #through;
        case .FMULADD;
            for i: rdx_get_reduction_op_chain(*rd, phi)
                if is_fp_math_op_value(i) && (get_fmf(i) & FMF_NINF) array_add(no_inf, i);
            return true;
        case .ADD; #through; case .MUL;
            ops := rdx_get_reduction_op_chain(*rd, phi);
            if ops.count == 0 return false;
            for i: ops if has_nsw(i) || has_nuw(i) array_add(no_wrap, i);
            return true;
    }
    return false;
}

// findInnerReductionPhi
li_find_inner_reduction_phi :: (c: *Li_Ctx, l: Loop_Id, v: Value_Id, no_wrap: *[..] Value_Id, no_inf: *[..] Value_Id) -> Value_Id {
    if is_const(v) return NONE;
    users: [..] Value_Id; users.allocator = temp;
    value_users(v, *users);
    for u: users {
        if is_inst(u) && inst_op(u) == .PHI {
            if phi_num_incoming(u) == 1 continue;
            if li_check_reduction_kind(c, l, u, no_wrap, no_inf) return u;
            return NONE;
        }
    }
    return NONE;
}

// checkInductionsAndReductions
li_check_inductions_and_reductions :: (c: *Li_Ctx, lg: *Li_Legality, outer: Loop_Id) -> bool {
    li := c.li;
    child :: (li: *Loop_Info, l: Loop_Id) -> Loop_Id { s := li_subloops(li, l); return ifx s.count == 0 then NONE else s[0]; }
    inner := child(li, outer);
    cur := outer;
    users: [..] Value_Id; users.allocator = temp;
    while cur != NONE {
        header := li_header(li, cur);
        for phi: block_insts(header) {
            if inst_op(phi) != .PHI break;
            id: Ind_Desc;
            if ind_is_induction_phi_se(phi, li, cur, *id, .[], SCEV_NULL) {
                if cur == inner {
                    if !sc_is_loop_invariant(id.step, outer) return false;
                    array_add(*lg.inner_loop_inductions, phi);
                }
                continue;
            }
            if cur == outer {
                if phi_num_incoming(phi) != 2 return false;
                v := li_follow_lcssa(phi_incoming_value_for_block(phi, li_loop_latch(li, outer)));
                inner_red := li_find_inner_reduction_phi(c, inner, v, *lg.has_no_wrap_reductions, *lg.has_no_inf_insts);
                ok := inner_red != NONE;
                if ok {
                    found := false;
                    for k: 0..phi_num_incoming(inner_red) - 1 if phi_value(inner_red, cast(u32) k) == phi { found = true; break; }
                    ok = found;
                }
                if ok {
                    value_users(phi, *users);
                    for users if it != inner_red { ok = false; break; }
                }
                if !ok return false;
                if !contains_value(lg.outer_inner_reductions, phi) array_add(*lg.outer_inner_reductions, phi);
                if !contains_value(lg.outer_inner_reductions, inner_red) array_add(*lg.outer_inner_reductions, inner_red);
            } else {
                if contains_value(lg.outer_inner_reductions, phi) {
                } else if li_cl.reduction_to_mem {
                    fatal("loop-interchange: -loop-interchange-reduction-to-mem (isInnerReduction, reduction2Memory) is not implemented yet");
                } else return false;
            }
        }
        cur = child(li, cur);
    }
    return lg.inner_loop_inductions.count != 0;
}

// currentLimitations
li_current_limitations :: (c: *Li_Ctx, lg: *Li_Legality) -> bool {
    li := c.li;
    inner_latch := li_loop_latch(li, lg.inner);
    outer_latch := li_loop_latch(li, lg.outer);
    if li_exiting_block(li, lg.inner) != inner_latch || li_exiting_block(li, lg.outer) != outer_latch ||
       inst_op(block_terminator(inner_latch)) != .CONDBR || inst_op(block_terminator(outer_latch)) != .CONDBR return true;
    if !li_is_loop_structure_understood(c, lg) return true;
    preds: [..] Value_Id; preds.allocator = temp;
    for l: Loop_Id.[lg.outer, lg.inner] {
        block_predecessors(li_header(li, l), *preds);
        for p: preds {
            if li_contains(li, l, p) continue;
            if inst_op(block_terminator(p)) == .INDIRECTBR return true;
        }
    }
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(li_header(li, lg.inner), *succs);
    for i: 0..succs.count - 1 for j: 0..i - 1 if succs[i] == succs[j] return true;
    return false;
}

// areInnerLoopExitPHIsSupported
li_are_inner_loop_exit_phis_supported :: (c: *Li_Ctx, outer: Loop_Id, inner: Loop_Id, reductions: [] Value_Id) -> bool {
    li := c.li;
    inner_exit := li_unique_exit_block(li, inner);
    users: [..] Value_Id; users.allocator = temp;
    for phi: block_insts(inner_exit) {
        if inst_op(phi) != .PHI break;
        if phi_num_incoming(phi) > 1 return false;
        value_users(phi, *users);
        for u: users {
            if !(is_inst(u) && inst_op(u) == .PHI) return false;
            if contains_value(reductions, u) continue;
            pb := inst_block(u);
            if !li_contains(li, outer, pb) continue;
            if pb != li_loop_latch(li, outer) return false;
        }
    }
    return true;
}

// areOuterLoopExitPHIsSupported
li_are_outer_loop_exit_phis_supported :: (c: *Li_Ctx, outer: Loop_Id) -> bool {
    li := c.li;
    nest_exit := li_unique_exit_block(li, outer);
    outer_latch := li_loop_latch(li, outer);
    for phi: block_insts(nest_exit) {
        if inst_op(phi) != .PHI break;
        for k: 0..phi_num_incoming(phi) - 1 {
            v := phi_value(phi, cast(u32) k);
            if !is_inst(v) || inst_block(v) != outer_latch continue;
            if block_unique_predecessor(outer_latch) == NONE return false;
        }
    }
    return true;
}

// areInnerLoopLatchPHIsSupported
li_are_inner_loop_latch_phis_supported :: (c: *Li_Ctx, inner: Loop_Id) -> bool {
    li := c.li;
    if li_subloops(li, inner).count == 0 return true;
    inner_latch := li_loop_latch(li, inner);
    t := block_terminator(inner_latch);
    if inst_op(t) != .CONDBR return true;
    cond := op(t, 0);
    if !is_inst(cond) return true;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, cond);
    i := 0;
    while i < wl.count {
        cur := wl[i];
        i += 1;
        if inst_op(cur) == .PHI && inst_block(cur) == inner_latch return false;
        for k: 0..cast(s64) nops(cur) - 1 {
            o := op(cur, cast(u32) k);
            if is_inst(o) && li_contains_inst(li, inner, o) && !contains_value(wl, o) array_add(*wl, o);
        }
    }
    return true;
}

// canInterchangeLoops
li_can_interchange_loops :: (c: *Li_Ctx, lg: *Li_Legality, inner_id: s64, outer_id: s64, dep_matrix: [] Li_Dep_Row) -> bool {
    li := c.li;
    if !li_is_legal_to_interchange(dep_matrix, inner_id, outer_id) return false;
    for b: li_blocks(li, lg.outer) for i: block_insts(b) {
        o := inst_op(i);
        if o == .LOAD || o == .STORE || is_pseudo_probe(i) continue;
        if !may_have_side_effects(i) && !may_read_from_memory(i) continue;
        return false;
    }
    if !li_check_inductions_and_reductions(c, lg, lg.outer) return false;
    if !li_are_inner_loop_latch_phis_supported(c, lg.inner) return false;
    if li_current_limitations(c, lg) return false;
    if !li_tightly_nested(c, lg.outer, lg.inner) return false;
    if !li_are_inner_loop_exit_phis_supported(c, lg.outer, lg.inner, lg.outer_inner_reductions) return false;
    if !li_are_outer_loop_exit_phis_supported(c, lg.outer) return false;
    outer_latch := li_loop_latch(li, lg.outer);
    for phi: block_insts(outer_latch) {
        if inst_op(phi) != .PHI break;
        if phi_num_incoming(phi) != 1 return false;
    }
    if li_exit_block(li, lg.inner) != outer_latch {
        users: [..] Value_Id; users.allocator = temp;
        for phi: block_insts(outer_latch) {
            if inst_op(phi) != .PHI break;
            value_users(phi, *users);
            for users if !(is_inst(it) && inst_op(it) == .PHI) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- profitability

// getAddRecCoefficient: (determined, coefficient or SCEV_NULL)
li_get_add_rec_coefficient :: (s: Scev_Id, l: Loop_Id) -> (bool, Scev_Id) {
    if !sc_is_addrec(s) {
        if sc_is_loop_invariant(s, l) return true, SCEV_NULL;
        return false, SCEV_NULL;
    }
    if !sc_is_affine(s) return false, SCEV_NULL;
    ok, coeff := li_get_add_rec_coefficient(sc_start(s), l);
    if !ok return false, SCEV_NULL;
    if sc_loop(s) == l coeff = sc_step_recurrence(s);
    return true, coeff;
}

// getInstrOrderCost
li_get_instr_order_cost :: (c: *Li_Ctx, outer: Loop_Id, inner: Loop_Id) -> s64 {
    good: [..] Scev_Id; good.allocator = temp;
    bad: [..] Scev_Id; bad.allocator = temp;
    add_unique :: (a: *[..] Scev_Id, s: Scev_Id) { for a.* if it == s return; array_add(a, s); }
    for b: li_blocks(c.li, inner) for i: block_insts(b) {
        o := inst_op(i);
        if o != .LOAD && o != .STORE continue;
        access := sc_get_scev(load_store_pointer_operand(i));
        base := sc_get_pointer_base(access);
        ok_o, outer_coeff := li_get_add_rec_coefficient(access, outer);
        ok_i, inner_coeff := li_get_add_rec_coefficient(access, inner);
        if !ok_o || outer_coeff == SCEV_NULL || !ok_i || inner_coeff == SCEV_NULL continue;
        outer_step := sc_get_abs(outer_coeff, false);
        inner_step := sc_get_abs(inner_coeff, false);
        if sc_is_known_predicate(ICMP_SLT, inner_step, outer_step) add_unique(*good, base);
        else if sc_is_known_predicate(ICMP_SLT, outer_step, inner_step) add_unique(*bad, base);
    }
    return good.count - bad.count;
}

// canVectorize
li_can_vectorize :: (dep_matrix: [] Li_Dep_Row, loop_id: s64) -> bool {
    for dep: dep_matrix {
        dir := dep[loop_id];
        dep_type := dep[dep.count - 1];
        if dir == #char "=" || dir == #char "I" continue;
        if dir == #char "<" && dep_type == #char "<" continue;
        return false;
    }
    return true;
}

// isProfitable
li_is_profitable :: (c: *Li_Ctx, inner: Loop_Id, outer: Loop_Id, inner_id: s64, outer_id: s64, dep_matrix: [] Li_Dep_Row) -> bool {
    inner_btc := sc_get_backedge_taken_count(inner);
    outer_btc := sc_get_backedge_taken_count(outer);
    if sc_is_zero(inner_btc) return false;
    if sc_is_zero(outer_btc) return false;
    rules := li_rules();
    if rules.count == 1 && rules[0] == .IGNORE return true;
    should := -1;   // nullopt
    for r: rules {
        if r == {
            case .CACHE; fatal("loop-interchange: the 'cache' profitability rule (CacheCost, LoopCacheAnalysis) is not implemented yet");
            case .INSTORDER;
                cost := li_get_instr_order_cost(c, outer, inner);
                if cost < 0 && cost < li_cl.cost_threshold should = 1;
            case .VECTORIZE;
                if !li_can_vectorize(dep_matrix, outer_id) should = 0;
                else if !li_can_vectorize(dep_matrix, inner_id) should = 1;
            case .IGNORE; fatal("loop-interchange: option 'ignore' is not supported with other options");
        }
        if should >= 0 break;
    }
    return should == 1;
}

// ---------------------------------------------------------------- transform

// Instruction::removeFromParent (records fall onto the next instruction)
li_remove_from_parent :: (i: Value_Id) {
    if inst(i).records {
        nx := inst_next(i);
        if nx == NONE fatal("loop-interchange: removing a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
}

// moveBBContents(FromBB, InsertBefore): splice everything but the terminator
li_move_bb_contents :: (from: Value_Id, insert_before: Value_Id) {
    t := block_terminator(from);
    if block_first(from) == t return;
    block_splice(insert_before, false, from, block_first(from), true, t);
}

// swapBBContents
li_swap_bb_contents :: (bb1: Value_Id, bb2: Value_Id) {
    temps: [..] Value_Id; temps.allocator = temp;
    t1 := block_terminator(bb1);
    for i: block_insts(bb1) if i != t1 array_add(*temps, i);
    for temps li_remove_from_parent(it);
    li_move_bb_contents(bb2, block_terminator(bb1));
    for temps inst_insert_before_adopt(it, block_terminator(bb2));
}

// updateSuccessor
li_update_successor :: (term: Value_Id, old: Value_Id, new: Value_Id, updates: *[..] Dom_Update) {
    changed := false;
    for k: 0..cast(s64) nops(term) - 1 if op(term, cast(u32) k) == old { set_op(term, cast(u32) k, new); changed = true; }
    if changed {
        array_add(updates, .{true, inst_block(term), new});
        array_add(updates, .{false, inst_block(term), old});
    }
    if !changed fatal("internal: loop-interchange updateSuccessor: expected a successor to be updated");
}

li_phis :: (b: Value_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    for i: block_insts(b) { if inst_op(i) != .PHI break; array_add(*out, i); }
    return out;
}

// PHINode::moveBefore(BB->getFirstNonPHIIt())
li_move_phi_to_first_non_phi :: (p: Value_Id, bb: Value_Id) {
    if inst(p).records fatal("loop-interchange: moving a phi with debug records");
    pos := block_first_non_phi(bb);
    inst_unlink(p);
    if pos == NONE block_append_inst(bb, p); else inst_insert_before(p, pos);
}

// moveLCSSAPhis
li_move_lcssa_phis :: (c: *Li_Ctx, inner_exit: Value_Id, inner_header: Value_Id, inner_latch: Value_Id, outer_header: Value_Id,
                       outer_latch: Value_Id, outer_exit: Value_Id, inner: Loop_Id) {
    li := c.li;
    for p: li_phis(inner_exit) {
        incoming := phi_incoming_value_for_block(p, inner_latch);
        if !is_inst(incoming) {
            replace_all_uses_with(p, incoming);
            erase_inst(p);
            continue;
        }
        inner_most := li_follow_lcssa(incoming);
        if !is_inst(inner_most) || (inst_block(inner_most) != inner_latch && inst_block(inner_most) != inner_header) continue;
        replace_all_uses_with(p, incoming);
        erase_inst(p);
    }
    lcssa_inner_exit := li_phis(inner_exit);
    lcssa_inner_latch := li_phis(inner_latch);
    for lcssa_inner_exit li_move_phi_to_first_non_phi(it, inner_latch);
    for lcssa_inner_latch li_move_phi_to_first_non_phi(it, inner_exit);
    if outer_exit != NONE {
        preds: [..] Value_Id; preds.allocator = temp;
        for p: li_phis(outer_exit) {
            if phi_num_incoming(p) != 1 continue;
            i := phi_value(p, 0);
            if !is_inst(i) || li_loop_for(li, inst_block(i)) == inner continue;
            new_phi := inst_clone(p);
            phi_set_value(new_phi, 0, phi_value(p, 0));
            phi_set_block(new_phi, 0, outer_latch);
            block_predecessors(inner_latch, *preds);
            for pr: preds {
                if pr == outer_latch continue;
                phi_add_incoming(new_phi, phi_value(p, 0), pr);
            }
            li_insert_phi_at_first_non_phi(new_phi, inner_latch);
            phi_set_value(p, 0, new_phi);
        }
    }
    block_replace_phi_uses_with(inner_latch, inner_latch, outer_latch);
}

// PHINode::insertBefore(BB->getFirstNonPHIIt())
li_insert_phi_at_first_non_phi :: (p: Value_Id, bb: Value_Id) {
    pos := block_first_non_phi(bb);
    if pos == NONE block_append_inst(bb, p); else inst_insert_before(p, pos);
}

// simplifyLCSSAPhis
li_simplify_lcssa_phis :: (c: *Li_Ctx, outer: Loop_Id, inner: Loop_Id) {
    li := c.li;
    inner_exit := li_exit_block(li, inner);
    outer_latch := li_loop_latch(li, outer);
    if outer_latch == inner_exit return;
    for phi: li_phis(outer_latch) {
        replace_all_uses_with(phi, phi_value(phi, 0));
        erase_inst(phi);
    }
}

// restructureLoops
li_restructure_loops :: (c: *Li_Ctx, outer_loop: Loop_Id, new_inner: Loop_Id, new_outer: Loop_Id, orig_inner_ph: Value_Id, orig_outer_ph: Value_Id) {
    li := c.li;
    outer_parent := li_parent(li, outer_loop);
    li_remove_block_from_loop(li, new_inner, orig_inner_ph);
    li_change_loop_for(li, orig_inner_ph, outer_parent);
    if outer_parent != NONE {
        li_remove_child_loop(li, outer_parent, new_inner);
        li_remove_child_loop(li, new_inner, new_outer);
        li_add_child_loop(li, outer_parent, new_outer);
    } else {
        li_remove_child_loop(li, new_inner, new_outer);
        li_change_top_level_loop(li, new_inner, new_outer);
    }
    while !li_is_innermost(li, new_outer) {
        ch := li_subloops(li, new_outer)[0];
        li_remove_child_loop(li, new_outer, ch);
        li_add_child_loop(li, new_inner, ch);
    }
    li_add_child_loop(li, new_outer, new_inner);
    orig_inner_bbs := array_copy(li_blocks(li, new_outer),, allocator = temp);
    for b: array_copy(li_blocks(li, new_inner),, allocator = temp)
        if li_loop_for(li, b) == new_inner li_add_block_entry(li, new_outer, b);
    outer_header := li_header(li, new_outer);
    outer_latch := li_loop_latch(li, new_outer);
    for b: orig_inner_bbs {
        if li_loop_for(li, b) != new_outer continue;
        if b == outer_header || b == outer_latch li_remove_block_from_loop(li, new_inner, b);
        else li_change_loop_for(li, b, new_inner);
    }
    li_add_block_entry(li, new_outer, orig_outer_ph);
    li_change_loop_for(li, orig_outer_ph, new_outer);
    sc_forget_loop(new_outer);
}

// adjustLoopBranches
li_adjust_loop_branches :: (c: *Li_Ctx, lg: *Li_Legality) {
    li := c.li;
    dt := c.dt;
    outer := lg.outer; inner := lg.inner;
    updates: [..] Dom_Update; updates.allocator = temp;
    outer_ph := li_loop_preheader(li, outer);
    inner_ph := li_loop_preheader(li, inner);
    li_simplify_lcssa_phis(c, outer, inner);
    if inst_op(block_first(outer_ph)) == .PHI || block_unique_predecessor(outer_ph) == NONE
        outer_ph = insert_preheader_for_loop(li, outer, dt, null, true);
    if inner_ph == li_header(li, outer)
        inner_ph = insert_preheader_for_loop(li, inner, dt, null, true);
    inner_header := li_header(li, inner);
    outer_header := li_header(li, outer);
    inner_latch := li_loop_latch(li, inner);
    outer_latch := li_loop_latch(li, outer);
    outer_pred := block_unique_predecessor(outer_ph);
    inner_latch_pred := block_unique_predecessor(inner_latch);
    outer_latch_bi := block_terminator(outer_latch);
    inner_latch_bi := block_terminator(inner_latch);
    outer_header_bi := block_terminator(outer_header);
    inner_header_bi := block_terminator(inner_header);
    if outer_pred == NONE || inner_latch_pred == NONE fatal("internal: loop-interchange: failed to find a unique predecessor");
    inner_latch_pred_bi := block_terminator(inner_latch_pred);
    outer_pred_bi := block_terminator(outer_pred);
    inner_header_succ := block_unique_successor(inner_header);
    if inner_header_succ == NONE fatal("internal: loop-interchange: the inner loop header has no unique successor");

    li_update_successor(outer_pred_bi, outer_ph, inner_ph, *updates);
    if succ_contains(outer_header, outer_latch) li_update_successor(outer_header_bi, outer_latch, inner_latch, *updates);
    li_update_successor(outer_header_bi, inner_ph, inner_header_succ, *updates);
    block_replace_phi_uses_with(inner_header_succ, inner_header, outer_header);
    li_update_successor(inner_header_bi, inner_header_succ, outer_ph, *updates);

    inner_latch_succ := ifx get_successor(inner_latch_bi, 0) == inner_header then get_successor(inner_latch_bi, 1) else get_successor(inner_latch_bi, 0);
    li_update_successor(inner_latch_pred_bi, inner_latch, inner_latch_succ, *updates);
    outer_latch_succ := ifx get_successor(outer_latch_bi, 0) == outer_header then get_successor(outer_latch_bi, 1) else get_successor(outer_latch_bi, 0);
    li_update_successor(inner_latch_bi, inner_latch_succ, outer_latch_succ, *updates);
    li_update_successor(outer_latch_bi, outer_latch_succ, inner_latch, *updates);

    dt_apply_updates(dt, updates);
    li_restructure_loops(c, outer, outer, inner, inner_ph, outer_ph);

    li_move_lcssa_phis(c, inner_latch_succ, inner_header, inner_latch, outer_header, outer_latch, li_exit_block(li, inner), inner);
    block_replace_phi_uses_with(outer_latch_succ, outer_latch, inner_latch);

    inner_phis: [..] Value_Id; inner_phis.allocator = temp;
    outer_phis: [..] Value_Id; outer_phis.allocator = temp;
    for li_phis(inner_header) if contains_value(lg.outer_inner_reductions, it) array_add(*inner_phis, it);
    for li_phis(outer_header) if contains_value(lg.outer_inner_reductions, it) array_add(*outer_phis, it);
    for outer_phis li_move_phi_to_first_non_phi(it, inner_header);
    for inner_phis li_move_phi_to_first_non_phi(it, outer_header);
    block_replace_phi_uses_with(outer_header, inner_ph, outer_ph);
    block_replace_phi_uses_with(outer_header, inner_latch, outer_latch);
    block_replace_phi_uses_with(inner_header, outer_ph, inner_ph);
    block_replace_phi_uses_with(inner_header, outer_latch, inner_latch);

    may_need: [..] Value_Id; may_need.allocator = temp;
    t := block_terminator(outer_header);
    for i: block_insts(outer_header) if i != t array_add(*may_need, i);
    // formLCSSAForInstructions takes a worklist it pops from the back
    cache: Lcssa_Exit_Cache;
    form_lcssa_for_instructions(*may_need, dt, li, *cache);
}

// LoopInterchangeTransform::transform
li_transform :: (c: *Li_Ctx, lg: *Li_Legality) {
    li := c.li;
    dt := c.dt;
    outer := lg.outer; inner := lg.inner;
    inductions := lg.inner_loop_inductions;
    inner_index_vars: [..] Value_Id; inner_index_vars.allocator = temp;
    for phi: inductions {
        incoming := phi_incoming_value_for_block(phi, li_loop_latch(li, inner));
        if !is_inst(incoming) fatal("internal: loop-interchange: the latch incoming value isn't an instruction");
        if contains_value(inductions, incoming) continue;
        array_add(*inner_index_vars, incoming);
    }
    inner_latch := li_loop_latch(li, inner);
    new_latch := split_block(inner_latch, block_terminator(inner_latch), dt, li);

    work_list: [..] Value_Id; work_list.allocator = temp;   // SmallSetVector
    wi := 0;
    insert :: (wl: *[..] Value_Id, v: Value_Id) { if !contains_value(wl.*, v) array_add(wl, v); }
    move_instructions :: (c: *Li_Ctx, wl: *[..] Value_Id, wi: *s64, inner: Loop_Id, inductions: [] Value_Id, new_latch: Value_Id) {
        li := c.li;
        while wi.* < wl.count {
            cur := wl.*[wi.*];
            if inst_op(cur) == .PHI fatal("internal: loop-interchange MoveInstructions on a phi");
            new_i := inst_clone(cur);
            insert_at_position(new_i, new_latch, block_first_non_phi(new_latch), true);
            u := ir.v_first_use[cur];
            while u != NONE {
                nx := ir.u_next[u];
                user := ir.u_user[u];
                ub := inst_block(user);
                if !li_contains(li, inner, ub) || ub == new_latch || contains_value(inductions, user) use_set(u, new_i);
                u = nx;
            }
            for k: 0..cast(s64) nops(cur) - 1 {
                o := op(cur, cast(u32) k);
                if !is_inst(o) || li_loop_for(li, inst_block(o)) != inner || contains_value(inductions, o) continue;
                if !contains_value(wl.*, o) array_add(wl, o);
            }
            wi.* += 1;
        }
    }
    cond := op(block_terminator(li_loop_latch(li, inner)), 0);
    if is_inst(cond) insert(*work_list, cond);
    move_instructions(c, *work_list, *wi, inner, inductions, new_latch);
    for inner_index_vars insert(*work_list, it);
    move_instructions(c, *work_list, *wi, inner, inductions, new_latch);

    inner_header := li_header(li, inner);
    split_block(inner_header, block_first_non_phi(inner_header), dt, li, null, "", true);

    inner_ph := li_loop_preheader(li, inner);
    outer_header := li_header(li, outer);
    if inner_ph != outer_header {
        for p: li_phis(inner_ph) {
            replace_all_uses_with(p, phi_value(p, 0));
            erase_inst(p);
        }
        t := block_terminator(inner_ph);
        moving: [..] Value_Id; moving.allocator = temp;
        for i: block_insts(inner_ph) if i != t array_add(*moving, i);
        // moveBeforePreserving(OuterLoopHeader->getTerminator()): the records travel with the instruction
        for moving { inst_unlink(it); inst_insert_before(it, block_terminator(outer_header)); }
    }

    li_adjust_loop_branches(c, lg);
    li_swap_bb_contents(li_loop_preheader(li, outer), li_loop_preheader(li, inner));

    for lg.has_no_wrap_reductions { set_nsw(it, false); set_nuw(it, false); }
    for lg.has_no_inf_insts set_fmf(it, get_fmf(it) & ~cast(u32) FMF_NINF);
}

// ---------------------------------------------------------------- driver

// LoopInterchange::processLoop
li_process_loop :: (c: *Li_Ctx, loops: *[..] Loop_Id, inner_id: s64, outer_id: s64, dep_matrix: *[..] Li_Dep_Row) -> bool {
    outer := loops.*[outer_id];
    inner := loops.*[inner_id];
    lg: Li_Legality;
    lg.outer = outer; lg.inner = inner;
    lg.outer_inner_reductions.allocator = temp; lg.inner_loop_inductions.allocator = temp;
    lg.has_no_wrap_reductions.allocator = temp; lg.has_no_inf_insts.allocator = temp;
    if !li_can_interchange_loops(c, *lg, inner_id, outer_id, dep_matrix.*) return false;
    if !li_is_profitable(c, inner, outer, inner_id, outer_id, dep_matrix.*) return false;
    li_transform(c, *lg);
    form_lcssa_recursively(c.li, outer, c.dt);
    t := loops.*[outer_id]; loops.*[outer_id] = loops.*[inner_id]; loops.*[inner_id] = t;
    li_interchange_dependencies(dep_matrix, inner_id, outer_id);
    return true;
}

// LoopInterchange::processLoopList
li_process_loop_list :: (c: *Li_Ctx, loops: *[..] Loop_Id) -> bool {
    changed := false;
    depth := loops.count;
    dep_matrix: [..] Li_Dep_Row; dep_matrix.allocator = temp;
    outermost := loops.*[0];
    if !li_populate_dependency_matrix(c, *dep_matrix, depth, outermost) return false;
    if li_exit_block(c.li, outermost) == NONE return false;
    sel := loops.count - 1;
    j := sel;
    while j > 0 {
        changed_per_iter := false;
        i := sel;
        while i > sel - j {
            x := li_process_loop(c, loops, i, i - 1, *dep_matrix);
            changed_per_iter |= x;
            changed |= x;
            i -= 1;
        }
        if !changed_per_iter break;
        j -= 1;
    }
    return changed;
}

loop_interchange_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    li := lar.li;
    loops := loop_nest_loops_bfs(li, l);
    // hasSupportedLoopDepth
    if loops.count < li_cl.min_loop_nest_depth || loops.count > li_cl.max_loop_nest_depth return PRESERVE_ALL;
    se = lar.se;
    if !li_is_computable_loop_nest(li, loops) return PRESERVE_ALL;
    c: Li_Ctx;
    c.li = li; c.dt = lar.dt; c.f = lar.fn;
    c.di = da_new(lar.fn, li);
    // LoopInterchange::run(LoopNest &): the loops must form a single chain
    for i: 1..loops.count - 1 if li_parent(li, loops[i]) != loops[i - 1] return PRESERVE_ALL;
    if !li_process_loop_list(*c, *loops) return PRESERVE_ALL;
    // U.markLoopNestChanged(true): the LoopNest is rebuilt for the next loop-nest pass (none follows in the pipelines)
    return loop_pass_preserved();
}
