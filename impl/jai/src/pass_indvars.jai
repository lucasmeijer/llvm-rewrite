// IndVarSimplify (indvars) and the LoopUtils helpers it uses.
// Port of llvm/lib/Transforms/Scalar/IndVarSimplify.cpp (LLVM 23.1.5): the floating-point IV rewrite
// (maybeFloatingPointRecurrence, tryConvertToIntegerIV, canonicalizeToIntegerIV, handleFloatingPointIV,
// rewriteNonIntegerIVs), rewriteFirstIterationLoopExitValues, visitIVCast (simplify_indvar.jai), simplifyAndExtend,
// LFTR (getLoopPhiForCounter, isLoopExitTestBasedOn, needsLFTR, hasConcreteDef, isLoopCounter, FindLoopCounter,
// genLoopLimit, linearFunctionTestReplace), sinkUnusedInvariants, the exit folding (replaceExitCond,
// createFoldedExitCond, foldExit, replaceLoopPHINodesWithPreheaderValues, createInvariantCond, createReplacement,
// optimizeLoopExitWithUnknownExitCount, canonicalizeExitCondition, optimizeLoopExits, crashingBBWithoutEffect,
// predicateLoopExits), IndVarSimplify::run and IndVarSimplifyPass::run.
// From llvm/lib/Transforms/Utils/LoopUtils.cpp: isAlmostDeadIV, hasHardUserWithinLoop, canLoopBeDeleted,
// rewriteLoopExitValues. From llvm/lib/Transforms/Utils/Local.cpp: RecursivelyDeleteTriviallyDeadInstructions (with
// TLI and MemorySSAUpdater), areAllUsesEqual, RecursivelyDeleteDeadPHINode; from BasicBlockUtils.cpp:
// DeleteDeadPHIs. From llvm/lib/Analysis/ValueTracking.cpp: mustExecuteUBIfPoisonOnPathTo.
//
// The pass state (class IndVarSimplify) is `Ivs`; the SCEVExpander is a Scev_Expander on run's stack; DeadInsts are
// value-handle slots (value_handles.jai), released when the run ends.

// ReplaceExitVal
REPL_NEVER :: 0; REPL_CHEAP :: 1; REPL_UNUSED_INDVAR_IN_LOOP :: 2; REPL_NO_HARD_USE :: 3; REPL_ALWAYS :: 4;

// cl::opts of IndVarSimplify.cpp (see passes.jai cl_opts())
indvars_opts: struct {
    replace_exit_value: s64 = REPL_CHEAP;         // replexitval
    use_post_increment_ranges := true;            // indvars-post-increment-ranges
    disable_lftr := false;                        // disable-lftr
    loop_predication := true;                     // indvars-predicate-loops
    loop_predication_traps := true;               // indvars-predicate-loop-traps
    allow_iv_widening := true;                    // indvars-widen-indvars
};

INDVARS_CL_OPT_COUNT :: 7;
add_indvars_cl_opts :: (list: [] Cl_Opt, start: s64) {
    list[start + 0] = .{"replexitval", .INT, null, *indvars_opts.replace_exit_value, null};   // parsed by name in parse_replexitval
    list[start + 1] = .{"indvars-post-increment-ranges", .BOOL, *indvars_opts.use_post_increment_ranges, null, null};
    list[start + 2] = .{"disable-lftr", .BOOL, *indvars_opts.disable_lftr, null, null};
    list[start + 3] = .{"indvars-predicate-loops", .BOOL, *indvars_opts.loop_predication, null, null};
    list[start + 4] = .{"indvars-predicate-loop-traps", .BOOL, *indvars_opts.loop_predication_traps, null, null};
    list[start + 5] = .{"indvars-widen-indvars", .BOOL, *indvars_opts.allow_iv_widening, null, null};
    list[start + 6] = .{"scev-cheap-expansion-budget", .INT, null, *scev_cheap_expansion_budget, null};
}
// -replexitval=never|cheap|unusedindvarinloop|noharduse|always (a cl::values enum option)
parse_replexitval :: (name: string, value: string, has_value: bool) -> bool {
    if name != "replexitval" return false;
    if !has_value fatal("option -replexitval needs a value");
    if value == "never" indvars_opts.replace_exit_value = REPL_NEVER;
    else if value == "cheap" indvars_opts.replace_exit_value = REPL_CHEAP;
    else if value == "unusedindvarinloop" indvars_opts.replace_exit_value = REPL_UNUSED_INDVAR_IN_LOOP;
    else if value == "noharduse" indvars_opts.replace_exit_value = REPL_NO_HARD_USE;
    else if value == "always" indvars_opts.replace_exit_value = REPL_ALWAYS;
    else fatal("invalid value '%' for option -replexitval", value);
    return true;
}

Ivs :: struct {
    fn: Value_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    tti: *Tti;
    mssau: *Mssa_Updater;
    dead: [..] Vh;
    widen_ind_vars: bool;
    run_unswitching: bool;
}

// ---------------------------------------------------------------- Local.cpp deletion helpers

// RecursivelyDeleteTriviallyDeadInstructions(V, TLI, MSSAU)
ivs_recursively_delete_trivially_dead :: (v: Value_Id, mssau: *Mssa_Updater) -> bool {
    if !is_inst(v) || !is_instruction_trivially_dead_tli(v, true) return false;
    dead: [..] Value_Id; dead.allocator = temp;
    array_add(*dead, v);
    while dead.count {
        i := pop(*dead);
        if vkind(i) == .DEAD continue;
        salvage_debug_info(i);
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, true) array_add(*dead, o);
        }
        if mssau mssau_remove_memory_access_inst(mssau, i);
        erase_inst_with_metadata(i);
    }
    return true;
}

// areAllUsesEqual
ivs_are_all_uses_equal :: (i: Value_Id) -> bool {
    u := ir.v_first_use[i];
    if u == NONE return true;
    the := ir.u_user[u];
    u = ir.u_next[u];
    while u != NONE { if ir.u_user[u] != the return false; u = ir.u_next[u]; }
    return true;
}

// RecursivelyDeleteDeadPHINode
ivs_recursively_delete_dead_phi_node :: (pn: Value_Id, mssau: *Mssa_Updater, known_non_dead: *Table(Value_Id, bool) = null) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    visited_phis: [..] Value_Id; visited_phis.allocator = temp;
    i := pn;
    while ivs_are_all_uses_equal(i) && !may_have_side_effects(i) {
        if !has_uses(i) return ivs_recursively_delete_trivially_dead(i, mssau);
        if table_contains(*visited, i) {
            rauw_with_metadata(i, const_poison(vtype(i)));
            ivs_recursively_delete_trivially_dead(i, mssau);
            return true;
        }
        table_set(*visited, i, true);
        if inst_op(i) == .PHI {
            if known_non_dead && table_contains(known_non_dead, i) break;
            array_add(*visited_phis, i);
        }
        i = ir.u_user[ir.v_first_use[i]];
    }
    if known_non_dead for visited_phis table_set(known_non_dead, it, true);
    return false;
}

// DeleteDeadPHIs
ivs_delete_dead_phis :: (bb: Value_Id, mssau: *Mssa_Updater) -> bool {
    phis: [..] Vh; phis.allocator = temp;
    for pn: block_insts(bb) { if inst_op(pn) != .PHI break; array_add(*phis, vh_new(pn)); }
    known: Table(Value_Id, bool); known.allocator = temp;
    changed := false;
    for h: phis {
        pn := vh_get(h);
        if pn == NONE || !is_phi(pn) continue;
        c := ivs_recursively_delete_dead_phi_node(pn, mssau, *known);
        changed |= c;
        if c table_reset(*known);
    }
    return changed;
}

// mustExecuteUBIfPoisonOnPathTo
must_execute_ub_if_poison_on_path_to :: (root: Value_Id, on_path_to: Value_Id, dt: *Dom_Tree) -> bool {
    known_poison: Table(Value_Id, bool); known_poison.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, root);
    while work.count {
        i := pop(*work);
        if must_trigger_ub(i, *known_poison) && dt_dominates_inst(dt, i, on_path_to) return true;
        if i != root {
            any := false;
            for k: 0..cast(s64) nops(i) - 1 {
                if table_contains(*known_poison, op(i, cast(u32) k)) && propagates_poison(i, cast(u32) k) { any = true; break; }
            }
            if !any continue;
        }
        if !table_contains(*known_poison, i) {
            table_set(*known_poison, i, true);
            for sx_users(i) array_add(*work, it);
        }
    }
    return false;
}

// ---------------------------------------------------------------- floating-point IVs

Fp_IV :: struct { init: Value_Id; incr: Value_Id; exit: Value_Id; compare: Value_Id; add: Value_Id; }
Int_IV :: struct { init: s64; incr: s64; exit: s64; pred: u8; }

// getIntegerPredicate
ivs_integer_predicate :: (p: u8) -> u8 {
    if p == FCMP_OEQ || p == FCMP_UEQ return ICMP_EQ;
    if p == FCMP_ONE || p == FCMP_UNE return ICMP_NE;
    if p == FCMP_OGT || p == FCMP_UGT return ICMP_SGT;
    if p == FCMP_OGE || p == FCMP_UGE return ICMP_SGE;
    if p == FCMP_OLT || p == FCMP_ULT return ICMP_SLT;
    if p == FCMP_OLE || p == FCMP_ULE return ICMP_SLE;
    return BAD_ICMP_PREDICATE;
}

// ConvertToSInt
ivs_convert_to_sint :: (c: Value_Id) -> (bool, s64) {
    k := type_kind(vtype(c));
    words, st, exact := fp_to_integer_rm(k, const_fp_value(c), 64, true, RM_TOWARD_ZERO);
    if st != 0 || !exact return false, 0;
    return true, cast,no_check(s64) words[0];
}

// isRepresentableAsExactInteger
ivs_is_representable_as_exact_integer :: (c: Value_Id, v: s64) -> bool {
    k := type_kind(vtype(c));
    prec: u32;
    if k == .HALF prec = 11; else if k == .BFLOAT prec = 8; else if k == .FLOAT prec = 24;
    else if k == .DOUBLE prec = 53; else if k == .FP128 prec = 113; else return false;
    a: u64 = ifx v < 0 then cast,no_check(u64) (-v) else cast(u64) v;
    if prec >= 64 return true;
    return a < ((cast(u64) 1) << prec);
}

// maybeFloatingPointRecurrence
ivs_maybe_floating_point_recurrence :: (s: *Ivs, l: Loop_Id, pn: Value_Id) -> (bool, Fp_IV) {
    r: Fp_IV;
    incoming: u32 = ifx li_contains(s.li, l, phi_block(pn, 0)) then cast(u32) 1 else 0;
    backedge := incoming ^ 1;
    init := phi_value(pn, incoming);
    if vkind(init) != .C_FP return false, r;
    incr := phi_value(pn, backedge);
    if !is_inst(incr) || inst_op(incr) != .FADD return false, r;
    inc_c := op(incr, 1);
    if vkind(inc_c) != .C_FP || op(incr, 0) != pn return false, r;
    if !has_n_uses(incr, 2) return false, r;
    compare: Value_Id = NONE;
    for sx_users(incr) if is_inst(it) && inst_op(it) == .FCMP { compare = it; break; }
    if compare == NONE return false, r;
    if !has_one_use(compare) return false, r;
    bi := ir.u_user[ir.v_first_use[compare]];
    if !is_inst(bi) || inst_op(bi) != .CONDBR return false, r;
    if !li_contains(s.li, l, inst_block(bi)) || (li_contains(s.li, l, get_successor(bi, 0)) && li_contains(s.li, l, get_successor(bi, 1))) return false, r;
    exitv := op(compare, 1);
    if vkind(exitv) != .C_FP return false, r;
    r.init = init; r.incr = inc_c; r.exit = exitv; r.compare = compare; r.add = incr;
    return true, r;
}

// tryConvertToIntegerIV
ivs_try_convert_to_integer_iv :: (f: Fp_IV) -> (bool, Int_IV) {
    r: Int_IV;
    new_pred := ivs_integer_predicate(inst_pred(f.compare));
    if new_pred == BAD_ICMP_PREDICATE return false, r;
    ok1, init := ivs_convert_to_sint(f.init);
    if !ok1 return false, r;
    ok2, incr := ivs_convert_to_sint(f.incr);
    if !ok2 return false, r;
    ok3, exitv := ivs_convert_to_sint(f.exit);
    if !ok3 return false, r;
    if !ivs_is_representable_as_exact_integer(f.init, init) || !ivs_is_representable_as_exact_integer(f.exit, exitv) return false, r;
    is_int32 :: (v: s64) -> bool { return v >= -0x8000_0000 && v <= 0x7fff_ffff; }
    if !is_int32(init) || !is_int32(incr) || !is_int32(exitv) return false, r;
    if incr == 0 return false, r;
    if incr > 0 {
        if init >= exitv return false, r;
        range := cast,trunc(u32) (exitv - init);
        if new_pred == ICMP_SLE || new_pred == ICMP_SGT {
            range += 1;
            if range == 0 return false, r;
        }
        leftover := range % cast,trunc(u32) incr;
        if (new_pred == ICMP_EQ || new_pred == ICMP_NE) && leftover != 0 return false, r;
        if leftover != 0 && cast,trunc(s32) (exitv + incr) < exitv return false, r;
    } else {
        if init <= exitv return false, r;
        range := cast,trunc(u32) (init - exitv);
        if new_pred == ICMP_SGE || new_pred == ICMP_SLT {
            range += 1;
            if range == 0 return false, r;
        }
        leftover := range % cast,trunc(u32) (-incr);
        if (new_pred == ICMP_EQ || new_pred == ICMP_NE) && leftover != 0 return false, r;
        if leftover != 0 && cast,trunc(s32) (exitv + incr) > exitv return false, r;
    }
    r.init = init; r.incr = incr; r.exit = exitv; r.pred = new_pred;
    return true, r;
}

// canonicalizeToIntegerIV
ivs_canonicalize_to_integer_iv :: (s: *Ivs, l: Loop_Id, pn: Value_Id, f: Fp_IV, iiv: Int_IV) {
    incoming: u32 = ifx li_contains(s.li, l, phi_block(pn, 0)) then cast(u32) 1 else 0;
    backedge := incoming ^ 1;
    i32 := ir.t_i32;
    incr := phi_value(pn, backedge);
    bi := ir.u_user[ir.v_first_use[f.compare]];
    new_phi := create_phi(i32, 2);
    siv_insert_before(new_phi, pn, tprint("%.int", vname(pn)));
    phi_add_incoming(new_phi, const_int(i32, cast,no_check(u64) iiv.init), phi_block(pn, incoming));
    copy_debug_loc(new_phi, pn);
    new_add := create_binop(.ADD, new_phi, const_int(i32, cast,no_check(u64) iiv.incr));
    siv_insert_before(new_add, incr, tprint("%.int", vname(incr)));
    copy_debug_loc(new_add, incr);
    phi_add_incoming(new_phi, new_add, phi_block(pn, backedge));
    new_cmp := create_icmp(iiv.pred, new_add, const_int(i32, cast,no_check(u64) iiv.exit));
    siv_insert_before(new_cmp, bi, vname(f.compare));
    copy_debug_loc(new_cmp, f.compare);
    ic_take_name(new_cmp, f.compare);
    rauw_with_metadata(f.compare, new_cmp);
    ivs_recursively_delete_trivially_dead(f.compare, s.mssau);
    rauw_with_metadata(incr, const_poison(vtype(incr)));
    ivs_recursively_delete_trivially_dead(incr, s.mssau);
    if vkind(pn) != .DEAD {
        conv := new_inst(.SITOFP, vtype(pn), 1);
        set_op(conv, 0, new_phi);
        bb := inst_block(pn);
        insert_at_position(conv, bb, block_first_insertion_pt(bb), true);
        set_name(conv, "indvar.conv");
        copy_debug_loc(conv, pn);
        rauw_with_metadata(pn, conv);
        ivs_recursively_delete_trivially_dead(pn, s.mssau);
    }
}

// rewriteNonIntegerIVs
ivs_rewrite_non_integer_ivs :: (s: *Ivs, l: Loop_Id) -> bool {
    phis: [..] Vh; phis.allocator = temp;
    for pn: block_insts(li_header(s.li, l)) { if inst_op(pn) != .PHI break; array_add(*phis, vh_new(pn)); }
    changed := false;
    for h: phis {
        pn := vh_get(h);
        if pn == NONE || !is_phi(pn) continue;
        ok, f := ivs_maybe_floating_point_recurrence(s, l, pn);
        if !ok continue;
        ok2, iiv := ivs_try_convert_to_integer_iv(f);
        if !ok2 continue;
        ivs_canonicalize_to_integer_iv(s, l, pn, f, iiv);
        changed = true;
    }
    if changed sc_forget_loop(l);
    return changed;
}

// ---------------------------------------------------------------- rewriteFirstIterationLoopExitValues

ivs_rewrite_first_iteration_loop_exit_values :: (s: *Ivs, l: Loop_Id) -> bool {
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(s.li, l, *exits);
    changed := false;
    for exit_bb: exits {
        for pn: block_insts(exit_bb) {
            if inst_op(pn) != .PHI break;
            n := phi_num_incoming(pn);
            for idx: 0..cast(s64) n - 1 {
                ib := phi_block(pn, cast(u32) idx);
                latch := li_loop_latch(s.li, l);
                if latch == NONE || !dt_dominates(s.dt, ib, latch) continue;
                term := block_terminator(ib);
                cond: Value_Id;
                if inst_op(term) == .CONDBR cond = op(term, 0);
                else if inst_op(term) == .SWITCH cond = op(term, 0);
                else continue;
                if !li_is_loop_invariant(s.li, l, cond) continue;
                exit_val := phi_value(pn, cast(u32) idx);
                if !is_phi(exit_val) || inst_block(exit_val) != li_header(s.li, l) continue;
                ph := li_loop_preheader(s.li, l);
                pidx := phi_block_index(exit_val, ph);
                if pidx != -1 {
                    changed = true;
                    phi_set_value(pn, cast(u32) idx, phi_value(exit_val, cast(u32) pidx));
                    sc_forget_value(pn);
                }
            }
        }
    }
    return changed;
}

// ---------------------------------------------------------------- simplifyAndExtend

ivs_simplify_and_extend :: (s: *Ivs, l: Loop_Id, rw: *Scev_Expander) -> bool {
    wide_ivs: [..] Wide_IV_Info; wide_ivs.allocator = temp;
    guard_decl := lookup_global("llvm.experimental.guard");
    has_guards := guard_decl != NONE && vkind(guard_decl) == .FUNCTION && has_uses(guard_decl);
    loop_phis: [..] Value_Id; loop_phis.allocator = temp;
    for pn: block_insts(li_header(s.li, l)) { if inst_op(pn) != .PHI break; array_add(*loop_phis, pn); }
    changed := false;
    while loop_phis.count {
        while true {
            curr_iv := pop(*loop_phis);
            wi: Wide_IV_Info;
            wi.narrow_iv = curr_iv;
            c, u := simplify_users_of_iv(curr_iv, s.li, s.dt, s.tti, *s.dead, rw, *wi);
            changed |= c;
            s.run_unswitching |= u;
            if wi.widest_native_type != NONE array_add(*wide_ivs, wi);
            if loop_phis.count == 0 break;
        }
        if !s.widen_ind_vars continue;
        while wide_ivs.count {
            wide_phi, _, _ := create_wide_iv(wide_ivs[wide_ivs.count - 1], s.li, rw, s.dt, *s.dead, has_guards, indvars_opts.use_post_increment_ranges);
            if wide_phi != NONE {
                changed = true;
                array_add(*loop_phis, wide_phi);
            }
            wide_ivs.count -= 1;
        }
    }
    return changed;
}

// ---------------------------------------------------------------- LFTR

// getLoopPhiForCounter
ivs_loop_phi_for_counter :: (s: *Ivs, inc_v: Value_Id, l: Loop_Id) -> Value_Id {
    if !is_inst(inc_v) return NONE;
    o := inst_op(inc_v);
    if o == .ADD || o == .SUB {}
    else if o == .GEP { if nops(inc_v) != 2 return NONE; }
    else return NONE;
    phi := op(inc_v, 0);
    if is_phi(phi) && inst_block(phi) == li_header(s.li, l) {
        if li_is_loop_invariant(s.li, l, op(inc_v, 1)) return phi;
        return NONE;
    }
    if o == .GEP return NONE;
    phi = op(inc_v, 1);
    if is_phi(phi) && inst_block(phi) == li_header(s.li, l) {
        if li_is_loop_invariant(s.li, l, op(inc_v, 0)) return phi;
    }
    return NONE;
}

// isLoopExitTestBasedOn
ivs_is_loop_exit_test_based_on :: (v: Value_Id, exiting: Value_Id) -> bool {
    bi := block_terminator(exiting);
    c := op(bi, 0);
    if !is_inst(c) || inst_op(c) != .ICMP return false;
    return op(c, 0) == v || op(c, 1) == v;
}

// needsLFTR
ivs_needs_lftr :: (s: *Ivs, l: Loop_Id, exiting: Value_Id) -> bool {
    bi := block_terminator(exiting);
    if li_is_loop_invariant(s.li, l, op(bi, 0)) return false;
    c := op(bi, 0);
    if !is_inst(c) || inst_op(c) != .ICMP return true;
    p := inst_pred(c);
    if p != ICMP_NE && p != ICMP_EQ return true;
    lhs := op(c, 0); rhs := op(c, 1);
    if !li_is_loop_invariant(s.li, l, rhs) {
        if !li_is_loop_invariant(s.li, l, lhs) return true;
        lhs, rhs = rhs, lhs;
    }
    phi := ifx is_phi(lhs) then lhs else ivs_loop_phi_for_counter(s, lhs, l);
    if phi == NONE return true;
    idx := phi_block_index(phi, li_loop_latch(s.li, l));
    if idx < 0 return true;
    inc_v := phi_value(phi, cast(u32) idx);
    return phi != ivs_loop_phi_for_counter(s, inc_v, l);
}

// hasConcreteDefImpl / hasConcreteDef
ivs_has_concrete_def_impl :: (v: Value_Id, visited: *Table(Value_Id, bool), depth: u32) -> bool {
    if is_constant_kind(vkind(v)) return vkind(v) != .C_UNDEF && vkind(v) != .C_POISON;
    if depth >= 6 return false;
    if !is_inst(v) return false;
    if may_read_from_memory(v) || inst_op(v) == .CALL || inst_op(v) == .INVOKE return false;
    for k: 0..cast(s64) nops(v) - 1 {
        o := op(v, cast(u32) k);
        if table_contains(visited, o) continue;
        table_set(visited, o, true);
        if !ivs_has_concrete_def_impl(o, visited, depth + 1) return false;
    }
    return true;
}
ivs_has_concrete_def :: (v: Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    table_set(*visited, v, true);
    return ivs_has_concrete_def_impl(v, *visited, 0);
}

// isLoopCounter
ivs_is_loop_counter :: (s: *Ivs, phi: Value_Id, l: Loop_Id) -> bool {
    if !sc_is_scevable(vtype(phi)) return false;
    sv := sc_get_scev(phi);
    if !sc_is_addrec(sv) || !sc_is_affine(sv) || !sc_is_one(sc_op(sv, 1)) || sc_loop(sv) != l return false;
    latch_idx := phi_block_index(phi, li_loop_latch(s.li, l));
    inc_v := phi_value(phi, cast(u32) latch_idx);
    return ivs_loop_phi_for_counter(s, inc_v, l) == phi && sc_is_addrec(sc_get_scev(inc_v));
}

// isAlmostDeadIV (LoopUtils.cpp)
is_almost_dead_iv :: (pn: Value_Id, latch: Value_Id, cond: Value_Id) -> bool {
    idx := phi_block_index(pn, latch);
    assert(idx != -1, "LatchBlock is not a case in this PHINode");
    inc_v := phi_value(pn, cast(u32) idx);
    for sx_users(pn) if it != cond && it != inc_v return false;
    for sx_users(inc_v) if it != cond && it != pn return false;
    return true;
}

// FindLoopCounter
ivs_find_loop_counter :: (s: *Ivs, l: Loop_Id, exiting: Value_Id, be_count: Scev_Id) -> Value_Id {
    bc_width := sc_type_bits(sc_type(be_count));
    cond := op(block_terminator(exiting), 0);
    best_phi: Value_Id = NONE;
    best_init := SCEV_NULL;
    latch := li_loop_latch(s.li, l);
    for phi: block_insts(li_header(s.li, l)) {
        if inst_op(phi) != .PHI break;
        if !ivs_is_loop_counter(s, phi, l) continue;
        ar := sc_get_scev(phi);
        phi_width := sc_type_bits(sc_type(ar));
        if phi_width < bc_width || !dl_is_legal_integer(phi_width) continue;
        if !ivs_has_concrete_def(phi) {
            inc_phi := phi_incoming_value_for_block(phi, latch);
            if !ivs_is_loop_exit_test_based_on(phi, exiting) && !ivs_is_loop_exit_test_based_on(inc_phi, exiting) continue;
        }
        if type_kind(vtype(phi)) != .INT && !must_execute_ub_if_poison_on_path_to(phi, block_terminator(exiting), s.dt) continue;
        init := sc_start(ar);
        if best_phi != NONE && !is_almost_dead_iv(best_phi, latch, cond) {
            if is_almost_dead_iv(phi, latch, cond) continue;
            if sc_is_zero(best_init) != sc_is_zero(init) {
                if sc_is_zero(best_init) continue;
            } else if phi_width <= sc_type_bits(vtype(best_phi)) continue;
        }
        best_phi = phi;
        best_init = init;
    }
    return best_phi;
}

// genLoopLimit
ivs_gen_loop_limit :: (s: *Ivs, ind_var: Value_Id, exiting: Value_Id, exit_count: Scev_Id, use_post_inc: bool, l: Loop_Id, rw: *Scev_Expander) -> Value_Id {
    ar := sc_get_scev(ind_var);
    if type_kind(vtype(ind_var)) == .INT && sc_type_bits(sc_type(ar)) > sc_type_bits(sc_type(exit_count)) {
        iv_init := sc_start(ar);
        if !sc_is_const(iv_init) || !sc_is_const(exit_count) {
            trunc_expr := sc_get_truncate(ar, sc_type(exit_count));
            if !sc_is_addrec(trunc_expr) return NONE;
            ar = trunc_expr;
        }
    }
    ar_base := ifx use_post_inc then sc_get_post_inc_expr(ar) else ar;
    iv_limit := evaluate_at_iteration(ar_base, exit_count);
    return sx_expand_code_for_at(rw, iv_limit, sc_type(ar_base), block_terminator(exiting));
}

// linearFunctionTestReplace
ivs_linear_function_test_replace :: (s: *Ivs, l: Loop_Id, exiting: Value_Id, exit_count: Scev_Id, ind_var: Value_Id, rw: *Scev_Expander) -> bool {
    latch := li_loop_latch(s.li, l);
    inc_var := phi_incoming_value_for_block(ind_var, latch);
    cmp_ind_var := ind_var;
    use_post_inc := false;
    if exiting == latch {
        safe := type_kind(vtype(ind_var)) == .INT || ivs_is_loop_exit_test_based_on(inc_var, exiting) ||
                must_execute_ub_if_poison_on_path_to(inc_var, block_terminator(exiting), s.dt);
        if safe { use_post_inc = true; cmp_ind_var = inc_var; }
    }
    exit_cnt := ivs_gen_loop_limit(s, ind_var, exiting, exit_count, use_post_inc, l, rw);
    if exit_cnt == NONE return false;
    if is_binary_operator(inc_var) {
        ar := sc_get_scev(inc_var);
        if sx_has_nuw(inc_var) sx_set_nuw(inc_var, sc_has_nuw(ar));
        if sx_has_nsw(inc_var) sx_set_nsw(inc_var, sc_has_nsw(ar));
    }
    bi := block_terminator(exiting);
    p: u8 = ifx li_contains(s.li, l, get_successor(bi, 0)) then cast(u8) ICMP_NE else ICMP_EQ;
    b: Irb;
    irb_set_before(*b, bi);
    c0 := op(bi, 0);
    if is_inst(c0) b.dbg = get_metadata(c0, 0);
    cmp_size := sc_type_bits(vtype(cmp_ind_var));
    exit_size := sc_type_bits(vtype(exit_cnt));
    if cmp_size > exit_size {
        extended := false;
        iv := sc_get_scev(cmp_ind_var);
        truncated := sc_get_truncate(iv, vtype(exit_cnt));
        zext_trunc := sc_get_zero_extend(truncated, vtype(cmp_ind_var));
        if zext_trunc == iv {
            extended = true;
            exit_cnt = irb_cast(*b, .ZEXT, exit_cnt, vtype(ind_var), "wide.trip.count");
        } else {
            sext_trunc := sc_get_sign_extend(truncated, vtype(cmp_ind_var));
            if sext_trunc == iv {
                extended = true;
                exit_cnt = irb_cast(*b, .SEXT, exit_cnt, vtype(ind_var), "wide.trip.count");
            }
        }
        if extended li_make_loop_invariant_no_se(s.li, l, exit_cnt);
        else cmp_ind_var = irb_cast(*b, .TRUNC, cmp_ind_var, vtype(exit_cnt), "lftr.wideiv");
    }
    cond := irb_icmp(*b, p, cmp_ind_var, exit_cnt, "exitcond");
    orig_cond := op(bi, 0);
    set_op(bi, 0, cond);
    dead_push(*s.dead, orig_cond);
    return true;
}

// ---------------------------------------------------------------- sinkUnusedInvariants

// Instruction::moveBefore(It) with It = getFirstInsertionPt() (head bit set): the records of i stay behind and
// i does not take the position's records
iv_move_before_head :: (i: Value_Id, pos: Value_Id, bb: Value_Id) {
    if inst(i).records {
        nx := inst_next(i);
        assert(nx != NONE, "moving a terminator with debug records");
        records_prepend(nx, records_take(i));
    }
    inst_unlink(i);
    if pos == NONE block_append_inst(bb, i); else inst_insert_before(i, pos);
}

ivs_sink_unused_invariants :: (s: *Ivs, l: Loop_Id) -> bool {
    exit_block := li_exit_block(s.li, l);
    if exit_block == NONE return false;
    ph := li_loop_preheader(s.li, l);
    if ph == NONE return false;
    changed := false;
    i := block_last(ph);
    while i != NONE {
        prev := inst_prev(i);
        defer i = prev;
        if block_terminator(ph) == i continue;
        if inst_op(i) == .PHI break;
        if may_have_side_effects(i) || may_read_from_memory(i) continue;
        if is_debug_or_pseudo_inst(i) continue;
        if is_eh_pad(i) continue;
        if inst_op(i) == .ALLOCA continue;
        used_in_loop := false;
        u := ir.v_first_use[i];
        while u != NONE {
            user := ir.u_user[u];
            ubb := inst_block(user);
            if inst_op(user) == .PHI ubb = ir.u_aux[u];
            if ubb == ph || li_contains(s.li, l, ubb) { used_in_loop = true; break; }
            u = ir.u_next[u];
        }
        if used_in_loop continue;
        iv_move_before_head(i, block_first_insertion_pt(exit_block), exit_block);
        sc_forget_value(i);
        changed = true;
    }
    return changed;
}

// ---------------------------------------------------------------- exit folding

// replaceExitCond
ivs_replace_exit_cond :: (s: *Ivs, bi: Value_Id, new_cond: Value_Id) {
    old := op(bi, 0);
    set_op(bi, 0, new_cond);
    if !has_uses(old) dead_push(*s.dead, old);
}
// createFoldedExitCond
ivs_create_folded_exit_cond :: (s: *Ivs, l: Loop_Id, exiting: Value_Id, is_taken: bool) -> Value_Id {
    bi := block_terminator(exiting);
    exit_if_true := !li_contains(s.li, l, get_successor(bi, 0));
    v := ifx is_taken then exit_if_true else !exit_if_true;
    return const_int(vtype(op(bi, 0)), ifx v then cast(u64) 1 else 0);
}
// foldExit
ivs_fold_exit :: (s: *Ivs, l: Loop_Id, exiting: Value_Id, is_taken: bool) {
    bi := block_terminator(exiting);
    ivs_replace_exit_cond(s, bi, ivs_create_folded_exit_cond(s, l, exiting, is_taken));
}

// replaceLoopPHINodesWithPreheaderValues
ivs_replace_loop_phi_nodes_with_preheader_values :: (s: *Ivs, l: Loop_Id) {
    ph := li_loop_preheader(s.li, l);
    header := li_header(s.li, l);
    work: [..] Value_Id; work.allocator = temp;
    for pn: block_insts(header) {
        if inst_op(pn) != .PHI break;
        inc := phi_incoming_value_for_block(pn, ph);
        for sx_users(pn) array_add(*work, it);
        sc_forget_value(pn);
        rauw_with_metadata(pn, inc);
        dead_push(*s.dead, pn);
    }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    while work.count {
        i := pop(*work);
        if table_contains(*visited, i) continue;
        table_set(*visited, i, true);
        if vkind(i) == .DEAD || !li_contains_inst(s.li, l, i) continue;
        q: Simplify_Query; q.have_tli = false;
        res := simplify_instruction(i, q);
        if res != NONE && li_replacement_preserves_lcssa_form(s.li, i, res) {
            for sx_users(i) array_add(*work, it);
            rauw_with_metadata(i, res);
            dead_push(*s.dead, i);
        }
    }
}

// createInvariantCond
ivs_create_invariant_cond :: (s: *Ivs, l: Loop_Id, exiting: Value_Id, lip: Loop_Inv_Pred, rw: *Scev_Expander) -> Value_Id {
    pred := lip.pred;
    ph := li_loop_preheader(s.li, l);
    sx_set_insert_point(rw, block_terminator(ph));
    lhsv := sx_expand_code_for(rw, lip.lhs);
    rhsv := sx_expand_code_for(rw, lip.rhs);
    exit_if_true := !li_contains(s.li, l, get_successor(block_terminator(exiting), 0));
    if exit_if_true pred = icmp_inverse(pred);
    b: Irb;
    irb_set_before(*b, block_terminator(ph));
    bi := block_terminator(exiting);
    return irb_icmp(*b, pred, lhsv, rhsv, name_ref(vname(op(bi, 0))));
}

// createReplacement: (has value, value)
ivs_create_replacement :: (s: *Ivs, icmp: Value_Id, l: Loop_Id, exiting: Value_Id, max_iter_in: Scev_Id, inverted: bool, skip_last_iter: bool, rw: *Scev_Expander) -> (bool, Value_Id) {
    max_iter := max_iter_in;
    pred := inst_pred(icmp);
    lhs := op(icmp, 0); rhs := op(icmp, 1);
    bi := block_terminator(exiting);
    if inverted pred = icmp_inverse(pred);
    lhss := sc_get_scev_at_scope_value(lhs, l);
    rhss := sc_get_scev_at_scope_value(rhs, l);
    known, ev := sc_evaluate_predicate_at(pred, lhss, rhss, bi);
    if known return true, ivs_create_folded_exit_cond(s, l, exiting, !ev);
    ar_ty := sc_type(lhss);
    mi_ty := sc_type(max_iter);
    if sc_type_bits(ar_ty) > sc_type_bits(mi_ty) max_iter = sc_get_zero_extend(max_iter, ar_ty);
    else if sc_type_bits(ar_ty) < sc_type_bits(mi_ty) {
        minus_one := sc_get_minus_one(ar_ty);
        max_allowed := sc_get_zero_extend(minus_one, mi_ty);
        if sc_is_known_predicate_at(ICMP_ULE, max_iter, max_allowed, bi) max_iter = sc_get_truncate(max_iter, ar_ty);
    }
    if skip_last_iter {
        if sc_kind(max_iter) == .UMIN {
            elems: [..] Scev_Id; elems.allocator = temp;
            for o: sc_operands(max_iter) array_add(*elems, sc_get_minus(o, sc_get_one(sc_type(o))));
            max_iter = sc_get_umin_from_mismatched_types(*elems);
        } else max_iter = sc_get_minus(max_iter, sc_get_one(sc_type(max_iter)));
    }
    lip := sc_get_loop_invariant_exit_cond_during_first_iterations(pred, lhss, rhss, l, bi, max_iter);
    if !lip.ok return false, NONE;
    if sc_is_known_predicate_at(lip.pred, lip.lhs, lip.rhs, bi) return true, ivs_create_folded_exit_cond(s, l, exiting, false);
    return true, ivs_create_invariant_cond(s, l, exiting, lip, rw);
}

// optimizeLoopExitWithUnknownExitCount
ivs_optimize_loop_exit_with_unknown_exit_count :: (s: *Ivs, l: Loop_Id, bi: Value_Id, exiting: Value_Id, max_iter: Scev_Id, skip_last_iter: bool, rw: *Scev_Expander) -> bool {
    inverted := li_contains(s.li, l, get_successor(bi, 1));
    leaves: [..] Value_Id; leaves.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    old_cond := op(bi, 0);
    table_set(*visited, old_cond, true);
    array_add(*work, old_cond);
    while true {
        curr := pop(*work);
        if has_one_use(curr) {
            ok: bool; a, b: Value_Id;
            if inverted { ok, a, b = pm_logical_or(curr); }
            else { ok, a, b = pm_logical_and(curr); }
            if ok {
                if !table_contains(*visited, a) { table_set(*visited, a, true); array_add(*work, a); }
                if !table_contains(*visited, b) { table_set(*visited, b, true); array_add(*work, b); }
            } else if is_inst(curr) && inst_op(curr) == .ICMP array_add(*leaves, curr);
        }
        if work.count == 0 break;
    }
    failing_on_last: [..] Value_Id; failing_on_last.allocator = temp;   // SmallPtrSet
    if !skip_last_iter && leaves.count > 1 && sc_get_exit_count(l, exiting, .SYMBOLIC_MAX) == max_iter {
        for icmp: leaves {
            el := sc_compute_exit_limit_from_cond(l, icmp, inverted, false, false);
            exit_max := el.smax;
            if exit_max == SCEV_CNC continue;
            wider := sc_get_wider_type(sc_type(exit_max), sc_type(max_iter));
            wide_exit_max := sc_get_noop_or_zero_extend(exit_max, wider);
            wide_max_iter := sc_get_noop_or_zero_extend(max_iter, wider);
            if wide_exit_max == wide_max_iter {
                dup := false;
                for failing_on_last if it == icmp { dup = true; break; }
                if !dup array_add(*failing_on_last, icmp);
            }
        }
    }
    changed := false;
    for oc: leaves {
        optimistic := skip_last_iter;
        if !optimistic {
            if failing_on_last.count > 1 optimistic = true;
            else if failing_on_last.count == 1 {
                contains := false;
                for failing_on_last if it == oc contains = true;
                optimistic = !contains;
            }
        }
        has, new_cond := ivs_create_replacement(s, oc, l, exiting, max_iter, inverted, optimistic, rw);
        if has {
            changed = true;
            if is_inst(new_cond) set_name(new_cond, tprint("%.first_iter", vname(oc)));
            rauw_with_metadata(oc, new_cond);
            dead_push(*s.dead, oc);
            for failing_on_last if it == oc { array_ordered_remove_by_index(*failing_on_last, it_index); break; }
        }
    }
    return changed;
}

// canonicalizeExitCondition
ivs_canonicalize_exit_condition :: (s: *Ivs, l: Loop_Id) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(s.li, l, *exiting);
    changed := false;
    for eb: exiting {
        bi := block_terminator(eb);
        if inst_op(bi) != .CONDBR continue;
        icmp := op(bi, 0);
        if !is_inst(icmp) || inst_op(icmp) != .ICMP || !has_one_use(icmp) continue;
        lhs := op(icmp, 0); rhs := op(icmp, 1);
        if !li_is_loop_invariant(s.li, l, rhs) {
            if !li_is_loop_invariant(s.li, l, lhs) continue;
            lhs, rhs = rhs, lhs;
        }
        if !is_inst(lhs) || inst_op(lhs) != .ZEXT || !icmp_is_signed(inst_pred(icmp)) continue;
        lhs_op := op(lhs, 0);
        inner := dl_type_size_bits(vtype(lhs_op));
        outer := dl_type_size_bits(vtype(rhs));
        full := cr_zero_extend(cr_full(cast(u32) inner), cast(u32) outer);
        rhs_cr := sc_unsigned_range(sc_apply_loop_guards(sc_get_scev(rhs), l));
        if cr_contains_range(full, rhs_cr) {
            inst(icmp).pred = icmp_unsigned_predicate(inst_pred(icmp));
            changed = true;
            continue;
        }
    }
    for eb: exiting {
        bi := block_terminator(eb);
        if inst_op(bi) != .CONDBR continue;
        icmp := op(bi, 0);
        if !is_inst(icmp) || inst_op(icmp) != .ICMP || !has_one_use(icmp) || !icmp_is_unsigned(inst_pred(icmp)) continue;
        swapped := false;
        lhs := op(icmp, 0); rhs := op(icmp, 1);
        if li_is_loop_invariant(s.li, l, lhs) == li_is_loop_invariant(s.li, l, rhs) continue;
        if li_is_loop_invariant(s.li, l, lhs) { swapped = true; lhs, rhs = rhs, lhs; }
        if !is_inst(lhs) || inst_op(lhs) != .ZEXT continue;
        lhs_op := op(lhs, 0);
        if !has_one_use(lhs) && !sc_is_addrec(sc_get_scev(lhs_op)) continue;
        inner := dl_type_size_bits(vtype(lhs_op));
        outer := dl_type_size_bits(vtype(rhs));
        full := cr_zero_extend(cr_full(cast(u32) inner), cast(u32) outer);
        rhs_cr := sc_unsigned_range(sc_apply_loop_guards(sc_get_scev(rhs), l));
        if cr_contains_range(full, rhs_cr) {
            // doRotateTransform
            new_rhs := new_inst(.TRUNC, vtype(lhs_op), 1);
            set_op(new_rhs, 0, rhs);
            t := block_terminator(li_loop_preheader(s.li, l));
            insert_at_position(new_rhs, inst_block(t), t, false);
            set_metadata(new_rhs, 0, NONE);   // DebugLoc::getDropped()
            set_op(icmp, ifx swapped then cast(u32) 1 else 0, lhs_op);
            set_op(icmp, ifx swapped then cast(u32) 0 else 1, new_rhs);
            inst(icmp).flags &= ~cast(u32) F_EXACT;   // setSameSign(false)
            if !has_uses(lhs) dead_push(*s.dead, lhs);
            changed = true;
            continue;
        }
    }
    return changed;
}

// sort exiting blocks by dominance (llvm::sort with "A properly dominates B" as less)
ivs_sort_by_dominance :: (s: *Ivs, blocks: *[..] Value_Id) {
    for i: 1..blocks.count - 1 {
        v := blocks.*[i];
        j := i - 1;
        while j >= 0 && dt_properly_dominates(s.dt, v, blocks.*[j]) { blocks.*[j + 1] = blocks.*[j]; j -= 1; }
        blocks.*[j + 1] = v;
    }
}

// optimizeLoopExits
ivs_optimize_loop_exits :: (s: *Ivs, l: Loop_Id, rw: *Scev_Expander) -> bool {
    all: [..] Value_Id; all.allocator = temp;
    li_exiting_blocks(s.li, l, *all);
    exiting: [..] Value_Id; exiting.allocator = temp;
    for eb: all {
        if li_loop_for(s.li, eb) != l continue;
        bi := block_terminator(eb);
        if inst_op(bi) != .CONDBR continue;
        if !dt_dominates(s.dt, eb, li_loop_latch(s.li, l)) continue;
        c := op(bi, 0);
        if vkind(c) == .C_INT {
            if !li_contains(s.li, l, get_successor(bi, ifx ap_is_zero(const_ap(c)) then cast(u32) 1 else 0))
                ivs_replace_loop_phi_nodes_with_preheader_values(s, l);
            continue;
        }
        array_add(*exiting, eb);
    }
    if exiting.count == 0 return false;
    max_be_count := sc_get_symbolic_max_backedge_taken_count(l);
    if max_be_count == SCEV_CNC return false;
    ivs_sort_by_dominance(s, *exiting);
    changed := false;
    skip_last_iter := false;
    curr_max_exit := SCEV_CNC;
    update_skip_last_iter :: (max_exit_count: Scev_Id, skip_last_iter: *bool, curr_max_exit: *Scev_Id, max_be_count: Scev_Id) {
        if skip_last_iter.* || max_exit_count == SCEV_CNC return;
        if curr_max_exit.* == SCEV_CNC curr_max_exit.* = max_exit_count;
        else curr_max_exit.* = sc_get_umin_from_mismatched_types2(curr_max_exit.*, max_exit_count);
        if curr_max_exit.* == max_be_count skip_last_iter.* = true;
    }
    dominating_exact: [..] Scev_Id; dominating_exact.allocator = temp;
    for eb: exiting {
        exact := sc_get_exit_count(l, eb);
        max_exit := sc_get_exit_count(l, eb, .SYMBOLIC_MAX);
        if exact == SCEV_CNC {
            bi := block_terminator(eb);
            if ivs_optimize_loop_exit_with_unknown_exit_count(s, l, bi, eb, max_be_count, false, rw) changed = true;
            else if skip_last_iter && ivs_optimize_loop_exit_with_unknown_exit_count(s, l, bi, eb, max_be_count, true, rw) changed = true;
            update_skip_last_iter(max_exit, *skip_last_iter, *curr_max_exit, max_be_count);
            continue;
        }
        update_skip_last_iter(exact, *skip_last_iter, *curr_max_exit, max_be_count);
        if sc_is_zero(exact) {
            ivs_fold_exit(s, l, eb, true);
            ivs_replace_loop_phi_nodes_with_preheader_values(s, l);
            changed = true;
            continue;
        }
        wider := sc_get_wider_type(sc_type(max_be_count), sc_type(exact));
        exact = sc_get_noop_or_zero_extend(exact, wider);
        max_be_count = sc_get_noop_or_zero_extend(max_be_count, wider);
        if sc_is_loop_entry_guarded_by_cond(l, ICMP_ULT, max_be_count, exact) {
            ivs_fold_exit(s, l, eb, false);
            changed = true;
            continue;
        }
        dup := false;
        for dominating_exact if it == exact { dup = true; break; }
        if dup {
            ivs_fold_exit(s, l, eb, false);
            changed = true;
            continue;
        }
        array_add(*dominating_exact, exact);
    }
    return changed;
}

// crashingBBWithoutEffect
ivs_crashing_bb_without_effect :: (bb: Value_Id) -> bool {
    for i: block_insts(bb) {
        if is_call_base(i) && me_without_loc(call_memory_effects(i), LOC_INACCESSIBLE) == 0 continue;
        if inst_op(i) == .UNREACHABLE continue;
        return false;
    }
    return true;
}

// predicateLoopExits
ivs_predicate_loop_exits :: (s: *Ivs, l: Loop_Id, rw: *Scev_Expander) -> bool {
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(s.li, l, *exiting);
    if !indvars_opts.loop_predication return false;
    exact_btc := sc_get_backedge_taken_count(l);
    if exact_btc == SCEV_CNC || !sx_is_safe_to_expand(rw, exact_btc) return false;
    bad_exit :: (s: *Ivs, l: Loop_Id, eb: Value_Id, rw: *Scev_Expander) -> bool {
        if li_loop_for(s.li, eb) != l return true;
        bi := block_terminator(eb);
        if inst_op(bi) != .CONDBR return true;
        if is_constant_kind(vkind(op(bi, 0))) return true;
        exit_block := get_successor(bi, ifx li_contains(s.li, l, get_successor(bi, 0)) then cast(u32) 1 else 0);
        if inst_op(block_first(exit_block)) == .PHI return true;
        ec := sc_get_exit_count(l, eb);
        if ec == SCEV_CNC || !sx_is_safe_to_expand(rw, ec) return true;
        return false;
    }
    latch := li_loop_latch(s.li, l);
    for eb: exiting if !dt_dominates(s.dt, eb, latch) return false;
    ivs_sort_by_dominance(s, *exiting);
    for i: 0..exiting.count - 1 {
        if bad_exit(s, l, exiting[i], rw) { exiting.count = i; break; }
    }
    if exiting.count == 0 return false;
    has_thread_local_side_effects := false;
    for bb: li_blocks(s.li, l) {
        for i: block_insts(bb) {
            if may_have_side_effects(i) {
                if !indvars_opts.loop_predication_traps return false;
                has_thread_local_side_effects = true;
                if inst_op(i) == .STORE {
                    if !inst_is_simple(i) return false;
                } else return false;
            }
            if type_kind(vtype(i)) == .TOKEN {
                for u: sx_users(i) if is_inst(u) && !li_contains_inst(s.li, l, u) return false;
            }
        }
    }
    changed := false;
    ph := li_loop_preheader(s.li, l);
    sx_set_insert_point(rw, block_terminator(ph));
    b: Irb;
    irb_set_before(*b, block_terminator(ph));
    exact_btcv: Value_Id = NONE;
    for eb: exiting {
        ec := sc_get_exit_count(l, eb);
        bi := block_terminator(eb);
        if has_thread_local_side_effects {
            unreachable_bb: Value_Id = NONE;
            for k: 0..1 {
                succ := get_successor(bi, cast(u32) k);
                if inst_op(block_terminator(succ)) == .UNREACHABLE unreachable_bb = succ;
            }
            if unreachable_bb == NONE || !ivs_crashing_bb_without_effect(unreachable_bb) return changed;
        }
        new_cond: Value_Id;
        if ec == exact_btc {
            new_cond = const_int(ir.t_i1, ifx li_contains(s.li, l, get_successor(bi, 0)) then cast(u64) 0 else 1);
        } else {
            ecv := sx_expand_code_for(rw, ec);
            if exact_btcv == NONE exact_btcv = sx_expand_code_for(rw, exact_btc);
            rhs := exact_btcv;
            if vtype(ecv) != vtype(rhs) {
                wider := sc_get_wider_type(vtype(ecv), vtype(rhs));
                ecv = irb_cast(*b, .ZEXT, ecv, wider);
                rhs = irb_cast(*b, .ZEXT, rhs, wider);
            }
            pred: u8 = ifx li_contains(s.li, l, get_successor(bi, 0)) then cast(u8) ICMP_NE else ICMP_EQ;
            new_cond = irb_icmp(*b, pred, ecv, rhs);
        }
        old_cond := op(bi, 0);
        set_op(bi, 0, new_cond);
        if !has_uses(old_cond) dead_push(*s.dead, old_cond);
        changed = true;
        s.run_unswitching = true;
    }
    return changed;
}

// ---------------------------------------------------------------- rewriteLoopExitValues (LoopUtils.cpp)

// hasHardUserWithinLoop
has_hard_user_within_loop :: (li: *Loop_Info, l: Loop_Id, i: Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    table_set(*visited, i, true);
    array_add(*work, i);
    while work.count {
        curr := pop(*work);
        if !li_contains_inst(li, l, curr) continue;
        if may_have_side_effects(curr) return true;
        for u: sx_users(curr) if !table_contains(*visited, u) { table_set(*visited, u, true); array_add(*work, u); }
    }
    return false;
}

Rewrite_Phi :: struct { pn: Value_Id; ith: u32; expansion_scev: Scev_Id; expansion_point: Value_Id; high_cost: bool; }

// canLoopBeDeleted
can_loop_be_deleted :: (li: *Loop_Info, l: Loop_Id, set: [] Rewrite_Phi) -> bool {
    ph := li_loop_preheader(li, l);
    if ph == NONE return false;
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits);
    if exits.count != 1 || exiting.count != 1 return false;
    for p: block_insts(exits[0]) {
        if inst_op(p) != .PHI break;
        incoming := phi_incoming_value_for_block(p, exiting[0]);
        found := false;
        for rp: set if rp.pn == p && phi_value(rp.pn, rp.ith) == incoming { found = true; break; }
        if !found && is_inst(incoming) && !li_has_loop_invariant_operands(li, l, incoming) return false;
    }
    for bb: li_blocks(li, l) for i: block_insts(bb) if may_have_side_effects(i) return false;
    return true;
}

// checkIsIndPhi: (ok, induction binop)
rlev_check_is_ind_phi :: (li: *Loop_Info, l: Loop_Id, phi: Value_Id) -> (bool, Value_Id) {
    if phi == NONE || !is_phi(phi) return false, NONE;
    if li_loop_preheader(li, l) == NONE return false, NONE;
    if inst_block(phi) != li_header(li, l) return false, NONE;
    ok, start, step, bo := is_induction_phi(phi, l);
    if !ok return false, NONE;
    // InductionDescriptor::isInductionPHI: the step must be a constant or loop invariant
    if !sc_is_const(step) && !sc_is_loop_invariant(step, l) return false, NONE;
    return true, bo;
}
// rewriteLoopExitValues, ReplaceExitValue == UnusedIndVarInLoop: the instruction must be an induction PHI used only by
// PHIs and its update, or the update of an induction PHI used only by that PHI and `pn`
rlev_unused_indvar_ok :: (li: *Loop_Info, l: Loop_Id, pn: Value_Id, i: Value_Id) -> bool {
    if is_phi(i) {
        ok, bo := rlev_check_is_ind_phi(li, l, i);
        if !ok return false;
        for u: sx_users(i) {
            if !is_phi(u) && !is_binary_operator(u) return false;
            if is_binary_operator(u) && u != bo return false;
        }
        return true;
    }
    if !is_binary_operator(i) return false;
    id_bo: Value_Id = NONE;
    for u: sx_users(i) {
        if u == pn continue;
        ok, bo := rlev_check_is_ind_phi(li, l, ifx is_phi(u) then u else NONE);
        if !ok return false;
        id_bo = bo;
    }
    return i == id_bo;
}

// rewriteLoopExitValues: the number of replaced exit values
rewrite_loop_exit_values :: (l: Loop_Id, li: *Loop_Info, tti: *Tti, rw: *Scev_Expander, dt: *Dom_Tree, mode: s64, dead: *[..] Vh) -> s64 {
    exits: [..] Value_Id; exits.allocator = temp;
    li_unique_exit_blocks(li, l, *exits);
    set: [..] Rewrite_Phi; set.allocator = temp;
    for exit_bb: exits {
        first := block_first(exit_bb);
        if first == NONE || inst_op(first) != .PHI continue;
        num_preds := phi_num_incoming(first);
        pn := first;
        while pn != NONE && inst_op(pn) == .PHI {
            cur := pn;
            pn = inst_next(pn);
            if !has_uses(cur) continue;
            if !sc_is_scevable(vtype(cur)) continue;
            for i: 0..cast(s64) num_preds - 1 {
                in_val := phi_value(cur, cast(u32) i);
                if !is_inst(in_val) continue;
                if li_loop_for(li, phi_block(cur, cast(u32) i)) != l continue;
                inst_v := in_val;
                if !li_contains_inst(li, l, inst_v) continue;
                if mode == REPL_UNUSED_INDVAR_IN_LOOP && !rlev_unused_indvar_ok(li, l, cur, inst_v) continue;
                exit_value := sc_get_scev_at_scope_value(inst_v, li_parent(li, l));
                if exit_value == SCEV_CNC || !sc_is_loop_invariant(exit_value, l) || !sx_is_safe_to_expand(rw, exit_value) {
                    exit_count := sc_get_exit_count(l, phi_block(cur, cast(u32) i));
                    if exit_count == SCEV_CNC continue;
                    ar := sc_get_scev(inst_v);
                    if sc_is_addrec(ar) && sc_loop(ar) == l exit_value = evaluate_at_iteration(ar, exit_count);
                    if exit_value == SCEV_CNC || !sc_is_loop_invariant(exit_value, l) || !sx_is_safe_to_expand(rw, exit_value) continue;
                }
                if mode != REPL_ALWAYS && !sc_is_const(exit_value) && !sc_is_unknown(exit_value) && has_hard_user_within_loop(li, l, inst_v) continue;
                high_cost := sx_is_high_cost_expansion(rw, .[exit_value], l, scev_cheap_expansion_budget, tti, inst_v);
                o := inst_op(inst_v);
                insert_pt := ifx o == .PHI || o == .LANDINGPAD then block_first_insertion_pt(inst_block(inst_v)) else inst_v;
                array_add(*set, .{cur, cast(u32) i, exit_value, insert_pt, high_cost});
            }
        }
    }
    loop_can_be_del := can_loop_be_deleted(li, l, set);
    num_replaced := 0;
    for rp: set {
        pn := rp.pn;
        if (mode == REPL_CHEAP || mode == REPL_UNUSED_INDVAR_IN_LOOP) && !loop_can_be_del && rp.high_cost continue;
        exit_val := sx_expand_code_for_at(rw, rp.expansion_scev, vtype(pn), rp.expansion_point);
        num_replaced += 1;
        inst_v := phi_value(pn, rp.ith);
        phi_set_value(pn, rp.ith, exit_val);
        sc_forget_value(pn);
        if is_instruction_trivially_dead_tli(inst_v, true) dead_push(dead, inst_v);
        if phi_num_incoming(pn) == 1 && li_replacement_preserves_lcssa_form(li, pn, exit_val) {
            rauw_with_metadata(pn, exit_val);
            erase_inst_with_metadata(pn);
        }
    }
    sx_clear_insert_point(rw);
    return num_replaced;
}

// ---------------------------------------------------------------- driver

// IndVarSimplify::run
ivs_run :: (s: *Ivs, l: Loop_Id) -> bool {
    if !li_is_loop_simplify_form(s.li, l) return false;
    changed := false;
    changed |= ivs_rewrite_non_integer_ivs(s, l);
    rw: Scev_Expander;
    sx_init(*rw, "indvars");
    sx_disable_canonical_mode(*rw);
    changed |= ivs_simplify_and_extend(s, l, *rw);
    if indvars_opts.replace_exit_value != REPL_NEVER {
        rewrites := rewrite_loop_exit_values(l, s.li, s.tti, *rw, s.dt, indvars_opts.replace_exit_value, *s.dead);
        if rewrites changed = true;
    }
    sx_replace_congruent_ivs(*rw, l, *s.dead, s.tti);
    changed |= ivs_canonicalize_exit_condition(s, l);
    if ivs_optimize_loop_exits(s, l, *rw) {
        changed = true;
        sc_forget_topmost_loop(l);
    }
    if ivs_predicate_loop_exits(s, l, *rw) {
        changed = true;
        sc_forget_loop(l);
    }
    if !indvars_opts.disable_lftr {
        ph := li_loop_preheader(s.li, l);
        exiting: [..] Value_Id; exiting.allocator = temp;
        li_exiting_blocks(s.li, l, *exiting);
        for eb: exiting {
            if inst_op(block_terminator(eb)) != .CONDBR continue;
            if li_loop_for(s.li, eb) != l continue;
            if !ivs_needs_lftr(s, l, eb) continue;
            exit_count := sc_get_exit_count(l, eb);
            if exit_count == SCEV_CNC continue;
            if sc_is_zero(exit_count) continue;
            ind_var := ivs_find_loop_counter(s, l, eb, exit_count);
            if ind_var == NONE continue;
            if sx_is_high_cost_expansion(*rw, .[exit_count], l, scev_cheap_expansion_budget, s.tti, block_terminator(ph)) continue;
            if !sx_is_safe_to_expand(*rw, exit_count) continue;
            changed |= ivs_linear_function_test_replace(s, l, eb, exit_count, ind_var, *rw);
        }
    }
    sx_clear(*rw);
    while s.dead.count {
        v := vh_get(pop(*s.dead));
        if is_phi(v) changed |= ivs_recursively_delete_dead_phi_node(v, s.mssau);
        else if is_inst(v) changed |= ivs_recursively_delete_trivially_dead(v, s.mssau);
    }
    changed |= ivs_sink_unused_invariants(s, l);
    changed |= ivs_rewrite_first_iteration_loop_exit_values(s, l);
    changed |= ivs_delete_dead_phis(li_header(s.li, l), s.mssau);
    if s.mssau && mssa_opts.verify mssa_verify(s.mssau.mssa);
    return changed;
}

// IndVarSimplifyPass::run
indvars_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    s: Ivs;
    s.fn = lar.fn;
    s.li = lar.li;
    s.dt = lar.dt;
    s.tti = tti_get(lar.fn);
    s.dead.allocator = temp;
    mssau_storage: Mssa_Updater;
    if lar.mssa { mssau_storage.mssa = lar.mssa; s.mssau = *mssau_storage; }
    s.widen_ind_vars = indvars_opts.allow_iv_widening;
    se = lar.se;
    changed := ivs_run(*s, l);
    vh_release_all();
    if !changed return PRESERVE_ALL;
    pa := loop_pass_preserved();
    pa.cfg = true;
    // AM.getResult<ShouldRunExtraSimpleLoopUnswitch>(L, AR) (loop_pm.jai)
    if s.run_unswitching table_set(*extra_unswitch_marker, l, true);
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}
