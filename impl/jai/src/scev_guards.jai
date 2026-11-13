// ScalarEvolution, part 6: loop and block dispositions, loop finiteness, loop guards.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): getLoopDisposition / computeLoopDisposition,
// isLoopUniform / isLoopInvariant / hasComputableLoopEvolution, getBlockDisposition / computeBlockDisposition,
// dominates / properlyDominates, loopIsFiniteByAssumption (with llvm::isFinite / isMustProgress /
// getBooleanLoopAttribute from llvm/lib/Analysis/LoopInfo.cpp), and LoopGuards (collect, collectFromPHI,
// collectFromBlock, the divisibility helpers, rewrite = SCEVLoopGuardRewriter) / applyLoopGuards.

// ---------------------------------------------------------------- dispositions

sc_get_loop_disposition :: (s: Scev_Id, l: Loop_Id) -> Loop_Disposition {
    p := table_find_pointer(*se.loop_disp, s);
    if !p { blank: [..] Disp_Entry; table_set(*se.loop_disp, s, blank); p = table_find_pointer(*se.loop_disp, s); }
    for p.* if it.key == l return cast(Loop_Disposition) it.d;
    array_add(p, .{l, cast(u8) Loop_Disposition.VARIANT});
    d := sc_compute_loop_disposition(s, l);
    p = table_find_pointer(*se.loop_disp, s);
    if p for < k: 0..p.count-1 if p.*[k].key == l { p.*[k].d = cast(u8) d; break; }
    return d;
}
sc_compute_loop_disposition :: (s: Scev_Id, l: Loop_Id) -> Loop_Disposition {
    k := sc_kind(s);
    if k == .CONSTANT || k == .VSCALE return .INVARIANT;
    if k == .ADDREC {
        if sc_loop(s) == l return .COMPUTABLE;
        if l == NONE return .VARIANT;
        al := sc_loop(s);
        if dt_dominates(se.dt, li_header(se.li, l), li_header(se.li, al)) {
            if li_contains_loop(se.li, l, al) {
                all_uniform := true;
                for i: 0..cast(s64) sc_nops(s) - 1 if !sc_is_loop_uniform(sc_op(s, cast(u32) i), l) { all_uniform = false; break; }
                if all_uniform return .UNIFORM;
            }
            return .VARIANT;
        }
        if li_contains_loop(se.li, al, l) return .INVARIANT;
        for i: 0..cast(s64) sc_nops(s) - 1 if !sc_is_loop_invariant(sc_op(s, cast(u32) i), l) return .VARIANT;
        return .INVARIANT;
    }
    if k == .UNKNOWN {
        v := sc_value(s);
        if is_inst(v) {
            if l != NONE && !li_contains(se.li, l, inst_block(v)) return .INVARIANT;
            return .VARIANT;
        }
        return .INVARIANT;
    }
    has_varying := false;
    has_uniform := false;
    for i: 0..cast(s64) sc_nops(s) - 1 {
        d := sc_get_loop_disposition(sc_op(s, cast(u32) i), l);
        if d == .VARIANT return .VARIANT;
        if d == .COMPUTABLE has_varying = true;
        if d == .UNIFORM has_uniform = true;
    }
    if has_varying { if has_uniform return .VARIANT; return .COMPUTABLE; }
    if has_uniform return .UNIFORM;
    return .INVARIANT;
}
sc_is_loop_uniform :: (s: Scev_Id, l: Loop_Id) -> bool { d := sc_get_loop_disposition(s, l); return d == .UNIFORM || d == .INVARIANT; }
sc_is_loop_invariant :: (s: Scev_Id, l: Loop_Id) -> bool { return sc_get_loop_disposition(s, l) == .INVARIANT; }
sc_has_computable_loop_evolution :: (s: Scev_Id, l: Loop_Id) -> bool { return sc_get_loop_disposition(s, l) == .COMPUTABLE; }

sc_get_block_disposition :: (s: Scev_Id, bb: Value_Id) -> Block_Disposition {
    p := table_find_pointer(*se.block_disp, s);
    if !p { blank: [..] Disp_Entry; table_set(*se.block_disp, s, blank); p = table_find_pointer(*se.block_disp, s); }
    for p.* if it.key == bb return cast(Block_Disposition) it.d;
    array_add(p, .{bb, cast(u8) Block_Disposition.DOES_NOT_DOMINATE});
    d := sc_compute_block_disposition(s, bb);
    p = table_find_pointer(*se.block_disp, s);
    if p for < k: 0..p.count-1 if p.*[k].key == bb { p.*[k].d = cast(u8) d; break; }
    return d;
}
sc_compute_block_disposition :: (s: Scev_Id, bb: Value_Id) -> Block_Disposition {
    k := sc_kind(s);
    if k == .CONSTANT || k == .VSCALE return .PROPERLY_DOMINATES;
    if k == .UNKNOWN {
        v := sc_value(s);
        if is_inst(v) {
            if inst_block(v) == bb return .DOMINATES;
            if dt_properly_dominates(se.dt, inst_block(v), bb) return .PROPERLY_DOMINATES;
            return .DOES_NOT_DOMINATE;
        }
        return .PROPERLY_DOMINATES;
    }
    if k == .ADDREC {
        if !dt_dominates(se.dt, li_header(se.li, sc_loop(s)), bb) return .DOES_NOT_DOMINATE;
    }
    proper := true;
    for i: 0..cast(s64) sc_nops(s) - 1 {
        d := sc_get_block_disposition(sc_op(s, cast(u32) i), bb);
        if d == .DOES_NOT_DOMINATE return .DOES_NOT_DOMINATE;
        if d == .DOMINATES proper = false;
    }
    return ifx proper then Block_Disposition.PROPERLY_DOMINATES else .DOMINATES;
}
sc_dominates :: (s: Scev_Id, bb: Value_Id) -> bool { return sc_get_block_disposition(s, bb) >= .DOMINATES; }
sc_properly_dominates :: (s: Scev_Id, bb: Value_Id) -> bool { return sc_get_block_disposition(s, bb) == .PROPERLY_DOMINATES; }
// hasOperand
sc_has_operand :: (s: Scev_Id, o: Scev_Id) -> bool {
    return sc_expr_contains(s, .CONTAINS_OPERAND, o);
}

// ---------------------------------------------------------------- finiteness

// getBooleanLoopAttribute(L, Name)
li_boolean_loop_attribute :: (l: Loop_Id, name: string) -> bool {
    md := find_option_md_for_loop_id(li_loop_id(se.li, l), name);
    if md == NONE return false;
    n := md_nops(md);
    if n == 1 return true;
    if n == 2 {
        o := md_op(md, 1);
        if o != NONE && ir.mds[o].kind == .VALUE {
            v := ir.mds[o].value;
            if is_const_int(v) return !ap_is_zero(const_ap(v));
        }
        return true;
    }
    fatal("ScalarEvolution: unexpected number of loop attribute operands");
    return false;
}
// loopIsFiniteByAssumption: isFinite(L) || (isMustProgress(L) && loopHasNoSideEffects(L))
sc_loop_is_finite_by_assumption :: (l: Loop_Id) -> bool {
    f := se.fn;
    if fn_has_fn_attr(f, .WillReturn) return true;
    must_progress := fn_has_fn_attr(f, .MustProgress) || fn_has_fn_attr(f, .WillReturn) || li_boolean_loop_attribute(l, "llvm.loop.mustprogress");
    return must_progress && sc_loop_has_no_side_effects(l);
}

// ---------------------------------------------------------------- loop guards

Loop_Guards :: struct {
    keys: [..] Scev_Id;      // RewriteMap (insertion order)
    vals: [..] Scev_Id;
    ne_a: [..] Scev_Id;      // NotEqual pairs
    ne_b: [..] Scev_Id;
    preserve_nuw: bool;
    preserve_nsw: bool;
}
lg_init :: (g: *Loop_Guards) {
    g.keys.allocator = temp; g.vals.allocator = temp; g.ne_a.allocator = temp; g.ne_b.allocator = temp;
}
lg_find :: (g: *Loop_Guards, k: Scev_Id) -> s64 { for g.keys if it == k return it_index; return -1; }
lg_lookup :: (g: *Loop_Guards, k: Scev_Id) -> Scev_Id { i := lg_find(g, k); if i < 0 return SCEV_NULL; return g.vals[i]; }
lg_set :: (g: *Loop_Guards, k: Scev_Id, v: Scev_Id) {
    i := lg_find(g, k);
    if i < 0 { array_add(*g.keys, k); array_add(*g.vals, v); } else g.vals[i] = v;
}
lg_erase :: (g: *Loop_Guards, k: Scev_Id) {
    i := lg_find(g, k);
    if i >= 0 { array_ordered_remove_by_index(*g.keys, i); array_ordered_remove_by_index(*g.vals, i); }
}
// the NotEqual pairs are ordered by pointer in LLVM; any canonical order works for set membership
lg_ne_contains :: (g: *Loop_Guards, a_in: Scev_Id, b_in: Scev_Id) -> bool {
    a := a_in; b := b_in;
    if a > b { t := a; a = b; b = t; }
    for g.ne_a if it == a && g.ne_b[it_index] == b return true;
    return false;
}
lg_ne_insert :: (g: *Loop_Guards, a_in: Scev_Id, b_in: Scev_Id) {
    a := a_in; b := b_in;
    if a > b { t := a; a = b; b = t; }
    if lg_ne_contains(g, a, b) return;
    array_add(*g.ne_a, a); array_add(*g.ne_b, b);
}

// LoopGuards::collect
sc_loop_guards_collect :: (l: Loop_Id) -> Loop_Guards {
    g: Loop_Guards;
    lg_init(*g);
    header := li_header(se.li, l);
    pred := li_loop_predecessor(se.li, l);
    if pred == NONE return g;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    lg_collect_from_block(*g, header, pred, *visited, 0);
    return g;
}

Incoming_Guards :: struct { blocks: [..] Value_Id; guards: [..] *Loop_Guards; }

// collectFromPHI
lg_collect_from_phi :: (g: *Loop_Guards, phi: Value_Id, visited: *Table(Value_Id, bool), incoming: *Incoming_Guards, depth: u32) {
    if !sc_is_scevable(vtype(phi)) return;
    Min_Max_Pattern :: struct { c: Scev_Id; k: Scev_Kind; }
    get_min_max_const :: (phi: Value_Id, idx: u32, visited: *Table(Value_Id, bool), incoming: *Incoming_Guards, depth: u32) -> Min_Max_Pattern {
        none := Min_Max_Pattern.{SCEV_NULL, .CNC};
        in_block := phi_block(phi, idx);
        if table_contains(visited, in_block) return none;
        table_set(visited, in_block, true);
        if !dt_is_reachable_from_entry(se.dt, in_block) return none;
        gp: *Loop_Guards = null;
        for incoming.blocks if it == in_block { gp = incoming.guards[it_index]; break; }
        if !gp {
            gp = New(Loop_Guards,, allocator = temp);
            lg_init(gp);
            array_add(*incoming.blocks, in_block);
            array_add(*incoming.guards, gp);
            lg_collect_from_block(gp, inst_block(phi), in_block, visited, depth + 1);
        }
        if gp.keys.count == 0 return none;
        s := lg_lookup(gp, sc_get_scev(phi_value(phi, idx)));
        if s == SCEV_NULL return none;
        if !sc_is_minmax(s) return none;
        c0 := sc_op(s, 0);
        if sc_is_const(c0) return .{c0, sc_kind(s)};
        return none;
    }
    merge :: (p1: Min_Max_Pattern, p2: Min_Max_Pattern) -> Min_Max_Pattern {
        none := Min_Max_Pattern.{SCEV_NULL, .CNC};
        if p1.c == SCEV_NULL || p2.c == SCEV_NULL || p1.k != p2.k return none;
        c1 := sc_ap(p1.c); c2 := sc_ap(p2.c);
        if p1.k == {
            case .UMAX; return .{ifx ap_ult(c1, c2) then p1.c else p2.c, p1.k};
            case .SMAX; return .{ifx ap_slt(c1, c2) then p1.c else p2.c, p1.k};
            case .UMIN; return .{ifx ap_ugt(c1, c2) then p1.c else p2.c, p1.k};
            case .SMIN; return .{ifx ap_sgt(c1, c2) then p1.c else p2.c, p1.k};
        }
        return none;
    }
    p := get_min_max_const(phi, 0, visited, incoming, depth);
    i: u32 = 1;
    while i < nops(phi) {
        if p.c == SCEV_NULL break;
        p = merge(p, get_min_max_const(phi, i, visited, incoming, depth));
        i += 1;
    }
    if p.c != SCEV_NULL {
        lhs := sc_get_scev(phi);
        ops := sc_list(p.c, lhs);
        rhs := sc_get_min_max(p.k, *ops);
        if lg_find(g, lhs) < 0 lg_set(g, lhs, rhs);   // insert (no overwrite)
    }
}

// getPreviousSCEVDivisibleByDivisor
get_previous_scev_divisible_by_divisor :: (e: Scev_Id, divisor: APInt) -> Scev_Id {
    if !sc_is_const(e) return e;
    ev := sc_ap(e);
    if ap_is_negative(ev) || ap_is_non_positive(divisor) return e;
    rem := ap_urem(ev, divisor);
    return sc_get_constant(ap_sub(ev, rem));
}
// getNextSCEVDivisibleByDivisor
get_next_scev_divisible_by_divisor :: (e: Scev_Id, divisor: APInt) -> Scev_Id {
    if !sc_is_const(e) return e;
    ev := sc_ap(e);
    if ap_is_negative(ev) || ap_is_non_positive(divisor) return e;
    rem := ap_urem(ev, divisor);
    if ap_is_zero(rem) return e;
    return sc_get_constant(ap_sub(ap_add(ev, divisor), rem));
}
// applyDivisibilityOnMinMaxExpr
apply_divisibility_on_min_max_expr :: (e: Scev_Id, divisor: APInt) -> Scev_Id {
    if !sc_is_minmax(e) || sc_nops(e) != 2 return e;
    c := sc_op(e, 0);
    if !sc_is_const(c) || ap_is_negative(sc_ap(c)) return e;
    k := sc_kind(e);
    lhs := c; rhs := sc_op(e, 1);
    is_min := k == .SMIN || k == .UMIN;
    divisible := ifx is_min then get_previous_scev_divisible_by_divisor(lhs, divisor) else get_next_scev_divisible_by_divisor(lhs, divisor);
    ops := sc_list(apply_divisibility_on_min_max_expr(rhs, divisor), divisible);
    return sc_get_min_max(k, *ops);
}

Guard_Term :: struct { cond: Value_Id; enter_if_true: bool; }
Guard_Cond :: struct { pred: u8; lhs: Scev_Id; rhs: Scev_Id; }

// collectFromBlock
lg_collect_from_block :: (g: *Loop_Guards, blk: Value_Id, pred_bb: Value_Id, visited: *Table(Value_Id, bool), depth: u32) {
    exprs_to_rewrite: [..] Scev_Id; exprs_to_rewrite.allocator = temp;
    terms: [..] Guard_Term; terms.allocator = temp;
    if se.ac for ci: ac_assumptions(se.ac).* {
        if vkind(ci) == .DEAD continue;
        if !dt_dominates_inst_block(se.dt, ci, blk) continue;
        array_add(*terms, .{op(ci, 0), true});
    }
    guard_decl := lookup_global("llvm.experimental.guard");
    if guard_decl != NONE {
        u := ir.v_first_use[guard_decl];
        while u != NONE {
            gi := ir.u_user[u];
            if is_inst(gi) && inst_op(gi) == .CALL && call_iid(gi) == IID_EXPERIMENTAL_GUARD && inst_fn(gi) == block_fn(blk) &&
               dt_dominates_inst_block(se.dt, gi, blk)
                array_add(*terms, .{op(gi, 0), true});
            u = ir.u_next[u];
        }
    }
    num_collected := 0;
    table_set(visited, blk, true);
    first := pred_bb; second := blk;
    while first != NONE {
        table_set(visited, second, true);
        t := block_terminator(first);
        if inst_op(t) == .CONDBR {
            array_add(*terms, .{op(t, 0), get_successor(t, 0) == second});
            num_collected += 1;
            if depth > 0 && num_collected == 2 break;
        }
        first, second = sc_get_predecessor_with_unique_successor(first);
    }
    if block_has_n_predecessors_or_more(second, 2) && cast(u64) depth < scev_opts.max_loop_guard_collection_depth {
        incoming: Incoming_Guards;
        incoming.blocks.allocator = temp; incoming.guards.allocator = temp;
        for phi: block_insts(second) {
            if inst_op(phi) != .PHI break;
            lg_collect_from_phi(g, phi, visited, *incoming, depth);
        }
    }

    guards_to_process: [..] Guard_Cond; guards_to_process.allocator = temp;
    for < ti: 0..terms.count-1 {
        term := terms[ti];
        work: [..] Value_Id; work.allocator = temp;
        seen: Table(Value_Id, bool); seen.allocator = temp;
        array_add(*work, term.cond);
        while work.count > 0 {
            cond := pop(*work);
            if table_contains(*seen, cond) continue;
            table_set(*seen, cond, true);
            if is_inst(cond) && inst_op(cond) == .ICMP {
                p := ifx term.enter_if_true then inst_pred(cond) else icmp_inverse(inst_pred(cond));
                lhs := sc_get_scev(op(cond, 0));
                rhs := sc_get_scev(op(cond, 1));
                if sc_is_const(lhs) { t := lhs; lhs = rhs; rhs = t; p = icmp_swapped(p); }
                array_add(*guards_to_process, .{p, lhs, rhs});
                continue;
            }
            ok, is_and, l, r := match_logical_and_or(cond);
            if ok && is_and == term.enter_if_true {
                array_add(*work, l);
                array_add(*work, r);
            }
        }
    }

    // divisibility information
    mult_keys: [..] Scev_Id; mult_keys.allocator = temp;
    mult_vals: [..] APInt; mult_vals.allocator = temp;
    div_guards: Loop_Guards; lg_init(*div_guards);
    for gc: guards_to_process {
        // isDivisibilityGuard
        okd, x, y := match_urem(gc.lhs);
        if !(okd && sc_is_zero(gc.rhs)) continue;
        // collectDivisibilityInformation
        if gc.pred != ICMP_EQ || !sc_is_zero(gc.rhs) continue;
        if !sc_is_unknown(x) continue;
        multiple := sc_get_mul2(sc_get_udiv(x, y), y);
        lg_set(*div_guards, x, multiple);
        if sc_is_const(y) {
            found := false;
            for mult_keys if it == x { mult_vals[it_index] = sc_ap(y); found = true; break; }
            if !found { array_add(*mult_keys, x); array_add(*mult_vals, sc_ap(y)); }
        }
    }

    for gc: guards_to_process lg_collect_condition(g, gc.pred, gc.lhs, gc.rhs, *div_guards, *exprs_to_rewrite);

    for k, ki: mult_keys {
        divisor := mult_vals[ki];
        divisor_scev := sc_get_constant(divisor);
        lg_set(g, k, sc_get_mul2(sc_get_udiv(apply_divisibility_on_min_max_expr(lg_rewrite(g, k), divisor), divisor_scev), divisor_scev));
        array_add(*exprs_to_rewrite, k);
    }

    g.preserve_nuw = true;
    g.preserve_nsw = true;
    for e: exprs_to_rewrite {
        rewrite_to := lg_lookup(g, e);
        if rewrite_to == SCEV_NULL { lg_set(g, e, SCEV_NULL); rewrite_to = SCEV_NULL; }
        g.preserve_nuw &= cr_contains_range(sc_unsigned_range(e), sc_unsigned_range(rewrite_to));
        g.preserve_nsw &= cr_contains_range(sc_signed_range(e), sc_signed_range(rewrite_to));
    }
    if exprs_to_rewrite.count > 1 {
        for e: exprs_to_rewrite {
            rewrite_to := lg_lookup(g, e);
            lg_erase(g, e);
            r := lg_rewrite(g, rewrite_to);
            lg_set(g, e, r);
        }
    }
}

block_has_n_predecessors_or_more :: (b: Value_Id, n: s64) -> bool {
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(b, *preds);
    return preds.count >= n;
}

// CollectCondition
lg_collect_condition :: (g: *Loop_Guards, pred_in: u8, lhs_in: Scev_Id, rhs_in: Scev_Id, div_guards: *Loop_Guards, exprs_to_rewrite: *[..] Scev_Id) {
    pred := pred_in; lhs := lhs_in; rhs := rhs_in;
    // MatchRangeCheckIdiom: (C1 + X) pred C2
    if sc_is_add(lhs) && sc_nops(lhs) == 2 && sc_is_const(sc_op(lhs, 0)) && sc_is_unknown(sc_op(lhs, 1)) && sc_is_const(rhs) {
        c1 := sc_ap(sc_op(lhs, 0));
        lhs_unknown := sc_op(lhs, 1);
        exact_region := cr_sub(cr_exact_icmp_region(pred, sc_ap(rhs)), cr_single(c1));
        if !cr_is_wrapped_set(exact_region) && !cr_is_full_set(exact_region) {
            idx := lg_find(g, lhs_unknown);
            rewritten_lhs := ifx idx < 0 then lhs_unknown else g.vals[idx];
            v := sc_get_umax2(sc_get_constant(cr_umin(exact_region)), sc_get_umin2(rewritten_lhs, sc_get_constant(cr_umax(exact_region))));
            lg_set(g, lhs_unknown, v);
            array_add(exprs_to_rewrite, lhs_unknown);
            return;
        }
    }
    if sc_is_const(lhs) || sc_contains_add_recurrence(rhs) return;
    if !sc_is_unknown(lhs) && sc_is_unknown(rhs) {
        t := lhs; lhs = rhs; rhs = t;
        pred = icmp_swapped(pred);
    }
    get_maybe_rewritten :: (g: *Loop_Guards, s: Scev_Id) -> Scev_Id { r := lg_lookup(g, s); if r == SCEV_NULL return s; return r; }
    rewritten_lhs := get_maybe_rewritten(g, lhs);
    divides_by := sc_get_constant_multiple(lg_rewrite(div_guards, rewritten_lhs));
    one := sc_get_one(sc_type(rhs));
    if pred == {
        case ICMP_ULT;
            if sc_is_ptr(rhs) return;
            rhs = sc_get_umax2(rhs, one);
            rhs = sc_get_minus(rhs, one);
            rhs = get_previous_scev_divisible_by_divisor(rhs, divides_by);
        case ICMP_SLT;
            rhs = sc_get_minus(rhs, one);
            rhs = get_previous_scev_divisible_by_divisor(rhs, divides_by);
        case ICMP_UGT; #through;
        case ICMP_SGT;
            rhs = sc_get_add2(rhs, one);
            rhs = get_next_scev_divisible_by_divisor(rhs, divides_by);
        case ICMP_ULE; #through;
        case ICMP_SLE;
            rhs = get_previous_scev_divisible_by_divisor(rhs, divides_by);
        case ICMP_UGE; #through;
        case ICMP_SGE;
            rhs = get_next_scev_divisible_by_divisor(rhs, divides_by);
    }
    work: [..] Scev_Id; work.allocator = temp;
    seen: Table(Scev_Id, bool); seen.allocator = temp;
    array_add(*work, lhs);
    enqueue :: (work: *[..] Scev_Id, s: Scev_Id) { for i: 0..cast(s64) sc_nops(s) - 1 array_add(work, sc_op(s, cast(u32) i)); }
    while work.count > 0 {
        from := pop(*work);
        if sc_is_const(from) continue;
        if table_contains(*seen, from) continue;
        table_set(*seen, from, true);
        from_rewritten := get_maybe_rewritten(g, from);
        to := SCEV_NULL;
        if pred == {
            case ICMP_ULT; #through;
            case ICMP_ULE;
                to = sc_get_umin2(from_rewritten, rhs);
                if sc_kind(from_rewritten) == .UMAX enqueue(*work, from_rewritten);
            case ICMP_SLT; #through;
            case ICMP_SLE;
                to = sc_get_smin2(from_rewritten, rhs);
                if sc_kind(from_rewritten) == .SMAX enqueue(*work, from_rewritten);
            case ICMP_UGT; #through;
            case ICMP_UGE;
                to = sc_get_umax2(from_rewritten, rhs);
                if sc_kind(from_rewritten) == .UMIN enqueue(*work, from_rewritten);
            case ICMP_SGT; #through;
            case ICMP_SGE;
                to = sc_get_smax2(from_rewritten, rhs);
                if sc_kind(from_rewritten) == .SMIN enqueue(*work, from_rewritten);
            case ICMP_EQ;
                if sc_is_const(rhs) to = rhs;
            case ICMP_NE;
                if sc_is_zero(rhs) {
                    one_aligned_up := get_next_scev_divisible_by_divisor(one, divides_by);
                    to = sc_get_umax2(from_rewritten, one_aligned_up);
                } else {
                    skip := false;
                    if sc_is_ptr(lhs) {
                        lhs = sc_get_lossless_ptr_to_int(lhs);
                        rhs = sc_get_lossless_ptr_to_int(rhs);
                        if lhs == SCEV_CNC || rhs == SCEV_CNC skip = true;
                    }
                    if !skip {
                        if sc_is_add(rhs) && sc_nops(rhs) == 2 && sc_is_const(sc_op(rhs, 0)) &&
                           sc_is_add(lhs) && sc_nops(lhs) == 2 && sc_op(lhs, 0) == sc_op(rhs, 0) {
                            a := sc_op(rhs, 1); b := sc_op(lhs, 1);
                            rhs = a; lhs = b;
                        }
                        lg_ne_insert(g, lhs, rhs);
                        continue;
                    }
                }
        }
        if to != SCEV_NULL {
            if from == from_rewritten array_add(exprs_to_rewrite, from);
            lg_set(g, from, to);
        }
    }
}

// LoopGuards::rewrite's SCEVLoopGuardRewriter (visit*)
sc_rw_loop_guards_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    g := rw.guards;
    k := sc_kind(s);
    if k == {
        case .ADDREC; return true, s;
        case .UNKNOWN; r := lg_lookup(g, s); if r == SCEV_NULL return true, s; return true, r;
        case .ZEXT;
            r := lg_lookup(g, s);
            if r != SCEV_NULL return true, r;
            ty := sc_type(s);
            o := sc_op(s, 0);
            bits := type_int_width(ty) / 2;
            while bits % 8 == 0 && bits >= 8 && bits > type_bits(sc_type(o)) {
                narrow_ext := sc_get_zero_extend(o, type_int(bits));
                r2 := lg_lookup(g, narrow_ext);
                if r2 != SCEV_NULL return true, sc_get_zero_extend(r2, ty);
                bits /= 2;
            }
            return false, 0;
        case .SEXT; #through;
        case .UMIN; #through;
        case .SMIN;
            r := lg_lookup(g, s);
            if r != SCEV_NULL return true, r;
            return false, 0;
        case .ADD;
            rewrite_subtraction :: (s: Scev_Id, g: *Loop_Guards) -> Scev_Id {
                ok, l, r := match_binary_sub(s);
                if ok && lg_ne_contains(g, l, r) {
                    one_aligned_up := get_next_scev_divisible_by_divisor(sc_get_one(sc_type(s)), sc_get_constant_multiple(s));
                    return sc_get_umax2(one_aligned_up, s);
                }
                return SCEV_NULL;
            }
            rr := rewrite_subtraction(s, g);
            if rr != SCEV_NULL return true, rr;
            if sc_is_const(sc_op(s, 0)) && sc_nops(s) == 3 {
                add := sc_get_add2(sc_op(s, 1), sc_op(s, 2));
                r2 := rewrite_subtraction(add, g);
                if r2 != SCEV_NULL return true, sc_get_add2(sc_op(s, 0), r2, mask_flags(sc_flags(s), rw.flag_mask));
                r3 := lg_lookup(g, add);
                if r3 != SCEV_NULL return true, sc_get_add2(sc_op(s, 0), r3);
            }
            ops: [..] Scev_Id; ops.allocator = temp;
            changed := false;
            for i: 0..cast(s64) sc_nops(s) - 1 {
                o := sc_op(s, cast(u32) i);
                r := sc_rewrite(rw, o);
                array_add(*ops, r);
                changed |= r != o;
            }
            if !changed return true, s;
            return true, sc_get_add(*ops, mask_flags(sc_flags(s), rw.flag_mask));
        case .MUL;
            ops: [..] Scev_Id; ops.allocator = temp;
            changed := false;
            for i: 0..cast(s64) sc_nops(s) - 1 {
                o := sc_op(s, cast(u32) i);
                r := sc_rewrite(rw, o);
                array_add(*ops, r);
                changed |= r != o;
            }
            if !changed return true, s;
            return true, sc_get_mul(*ops, mask_flags(sc_flags(s), rw.flag_mask));
    }
    return false, 0;
}
// LoopGuards::rewrite
lg_rewrite :: (g: *Loop_Guards, e: Scev_Id) -> Scev_Id {
    if g.keys.count == 0 && g.ne_a.count == 0 return e;
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .LOOP_GUARDS);
    rw.guards = g;
    rw.flag_mask = SF_ANY;
    if g.preserve_nuw rw.flag_mask = set_flags(rw.flag_mask, SF_NUW);
    if g.preserve_nsw rw.flag_mask = set_flags(rw.flag_mask, SF_NSW);
    return sc_rewrite(*rw, e);
}

sc_apply_loop_guards :: (e: Scev_Id, l: Loop_Id) -> Scev_Id {
    g := sc_loop_guards_collect(l);
    return lg_rewrite(*g, e);
}
sc_apply_loop_guards_with :: (e: Scev_Id, g: *Loop_Guards) -> Scev_Id { return lg_rewrite(g, e); }
