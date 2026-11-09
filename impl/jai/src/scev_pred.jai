// ScalarEvolution, part 7: SCEV predicates and predicated rewriting.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): getEqualPredicate / getComparePredicate /
// getWrapPredicate (UniquePreds), SCEVComparePredicate / SCEVWrapPredicate (implies, isAlwaysTrue, print,
// getImpliedFlags), SCEVPredicateRewriter (only the NewPreds form: convertSCEVToAddRecWithPredicates),
// isSimpleCastedPHI, createAddRecFromPHIWithCastsImpl / createAddRecFromPHIWithCasts.
//
// A predicate is a row of se.preds (id 0 unused); the uniquing key mirrors the FoldingSetNodeID.

Scev_Pred_Kind :: enum u8 { COMPARE; WRAP; }
Scev_Pred_Row :: struct {
    kind: Scev_Pred_Kind;
    pred: u8;          // compare: the predicate; wrap: IncrementWrapFlags
    a: Scev_Id;        // compare: LHS; wrap: the AddRec
    b: Scev_Id;        // compare: RHS
}
INCREMENT_NUSW :: cast(u8) 1;
INCREMENT_NSSW :: cast(u8) 2;

sc_pred_find_or_insert :: (kind: Scev_Pred_Kind, pred: u8, a: Scev_Id, b: Scev_Id) -> u32 {
    key := ((cast(u64) kind) << 62) ^ ((cast(u64) pred) << 54) ^ ((cast(u64) a) << 27) ^ cast(u64) b;
    key = sc_hash_mix(key, (cast(u64) a) * 31 + b);
    found, head := table_find(*se.pred_unique, key);
    if found {
        // collisions are resolved by a linear scan of the rows with the same key
        for i: 1..se.preds.count-1 {
            r := se.preds[i];
            if r.kind == kind && r.pred == pred && r.a == a && r.b == b return cast(u32) i;
        }
    }
    row: Scev_Pred_Row;
    row.kind = kind; row.pred = pred; row.a = a; row.b = b;
    id := cast(u32) se.preds.count;
    array_add(*se.preds, row);
    table_set(*se.pred_unique, key, id);
    return id;
}
sc_get_compare_predicate :: (pred: u8, lhs: Scev_Id, rhs: Scev_Id) -> u32 { return sc_pred_find_or_insert(.COMPARE, pred, lhs, rhs); }
sc_get_equal_predicate :: (lhs: Scev_Id, rhs: Scev_Id) -> u32 { return sc_get_compare_predicate(ICMP_EQ, lhs, rhs); }
sc_get_wrap_predicate :: (ar: Scev_Id, flags: u8) -> u32 { return sc_pred_find_or_insert(.WRAP, flags, ar, 0); }

// SCEVPredicate::implies
sc_pred_implies :: (p: u32, n: u32) -> bool {
    a := se.preds[p]; b := se.preds[n];
    if a.kind == .COMPARE {
        if b.kind != .COMPARE return false;
        if a.pred != ICMP_EQ return false;
        return b.a == a.a && b.b == a.b;
    }
    if b.kind != .WRAP || (a.pred | b.pred) != a.pred return false;
    if b.a == a.a return true;
    if a.pred != INCREMENT_NSSW && a.pred != INCREMENT_NUSW return false;
    start := sc_start(a.a);
    op_start := sc_start(b.a);
    if sc_is_ptr(start) != sc_is_ptr(op_start) return false;
    if sc_is_ptr(start) && sc_type(start) != sc_type(op_start) return false;
    if sc_bits(a.a) > sc_bits(b.a) return false;
    step := sc_step_recurrence(a.a);
    op_step := sc_step_recurrence(b.a);
    if !sc_is_known_positive(step) || !sc_is_known_positive(op_step) return false;
    wider := sc_wider_type(sc_type(step), sc_type(op_step));
    step = sc_get_noop_or_zero_extend(step, wider);
    op_step = sc_get_noop_or_zero_extend(op_step, wider);
    is_nuw := a.pred == INCREMENT_NUSW;
    op_start = ifx is_nuw then sc_get_noop_or_zero_extend(op_start, wider) else sc_get_noop_or_sign_extend(op_start, wider);
    start = ifx is_nuw then sc_get_noop_or_zero_extend(start, wider) else sc_get_noop_or_sign_extend(start, wider);
    pred := ifx is_nuw then cast(u8) ICMP_ULE else ICMP_SLE;
    return sc_is_known_predicate(pred, op_step, step) && sc_is_known_predicate(pred, op_start, start);
}

icmp_pred_name :: (p: u8) -> string {
    if p == {
        case ICMP_EQ; return "eq"; case ICMP_NE; return "ne";
        case ICMP_UGT; return "ugt"; case ICMP_UGE; return "uge"; case ICMP_ULT; return "ult"; case ICMP_ULE; return "ule";
        case ICMP_SGT; return "sgt"; case ICMP_SGE; return "sge"; case ICMP_SLT; return "slt"; case ICMP_SLE; return "sle";
    }
    return "unknown";
}

// SCEVPredicate::print(OS, Depth)
sc_pred_print :: (sb: *String_Builder, p: u32, depth: s64) {
    r := se.preds[p];
    for 1..depth append(sb, " ");
    if r.kind == .COMPARE {
        if r.pred == ICMP_EQ {
            append(sb, "Equal predicate: "); sc_print(sb, r.a); append(sb, " == "); sc_print(sb, r.b); append(sb, "\n");
        } else {
            append(sb, "Compare predicate: "); sc_print(sb, r.a); append(sb, " "); append(sb, icmp_pred_name(r.pred));
            append(sb, ") "); sc_print(sb, r.b); append(sb, "\n");
        }
        return;
    }
    sc_print(sb, r.a);
    append(sb, " Added Flags: ");
    if r.pred & INCREMENT_NUSW append(sb, "<nusw>");
    if r.pred & INCREMENT_NSSW append(sb, "<nssw>");
    append(sb, "\n");
}

// ---------------------------------------------------------------- SCEVPredicateRewriter

// addOverflowAssumption(P)
sc_rw_add_overflow_assumption :: (rw: *Sc_Rewriter, p: u32) -> bool {
    if !rw.new_preds return rw.has_pred && sc_union_implies(rw.pred_union, p);
    array_add(rw.new_preds, p);
    return true;
}
sc_rw_predicate_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    k := sc_kind(s);
    if k == .UNKNOWN {
        if rw.has_pred {
            for p: rw.pred_union {
                r := se.preds[p];
                if r.kind == .COMPARE && r.a == s && r.pred == ICMP_EQ return true, r.b;
            }
        }
        // convertToAddRecWithPreds
        v := sc_value(s);
        if !is_inst(v) || inst_op(v) != .PHI return true, s;
        ok, res, preds := sc_create_add_rec_from_phi_with_casts(s);
        if !ok return true, s;
        for p: preds {
            if se.preds[p].kind == .WRAP && rw.l != sc_loop(se.preds[p].a) return true, s;
            if !sc_rw_add_overflow_assumption(rw, p) return true, s;
        }
        return true, res;
    }
    if k == .ZEXT || k == .SEXT {
        operand := sc_rewrite(rw, sc_op(s, 0));
        ty := sc_type(s);
        if sc_is_addrec(operand) && sc_loop(operand) == rw.l && sc_is_affine(operand) {
            step := sc_step_recurrence(operand);
            flag := ifx k == .ZEXT then INCREMENT_NUSW else INCREMENT_NSSW;
            if sc_rw_add_overflow_assumption(rw, sc_get_wrap_predicate(operand, flag)) {
                start := ifx k == .ZEXT then sc_get_zero_extend(sc_start(operand), ty) else sc_get_sign_extend(sc_start(operand), ty);
                return true, sc_get_add_rec(start, sc_get_sign_extend(step, ty), rw.l, sc_flags(operand));
            }
        }
        if k == .ZEXT return true, sc_get_zero_extend(operand, ty);
        return true, sc_get_sign_extend(operand, ty);
    }
    return false, 0;
}
scev_predicate_rewrite :: (s: Scev_Id, l: Loop_Id, new_preds: *[..] u32) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .PREDICATE);
    rw.l = l;
    rw.new_preds = new_preds;
    return sc_rewrite(*rw, s);
}
// ScalarEvolution::rewriteUsingPredicate(S, L, Preds) with a SCEVUnionPredicate
sc_rewrite_using_predicate :: (s: Scev_Id, l: Loop_Id, preds: [] u32) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .PREDICATE);
    rw.l = l;
    rw.has_pred = true;
    rw.pred_union = preds;
    return sc_rewrite(*rw, s);
}

// ---------------------------------------------------------------- SCEVUnionPredicate (a list of predicate rows)

// SCEVWrapPredicate::getImpliedFlags
sc_wrap_implied_flags :: (ar: Scev_Id) -> u8 {
    implied: u8 = 0;
    f := sc_flags(ar);
    if (f & SF_NSW) == SF_NSW implied = INCREMENT_NSSW;
    if (f & SF_NUW) == SF_NUW {
        step := sc_step_recurrence(ar);
        if sc_is_const(step) && !ap_is_negative(sc_ap(step)) implied |= INCREMENT_NUSW;
    }
    return implied;
}
// SCEVPredicate::isAlwaysTrue
sc_pred_is_always_true :: (p: u32) -> bool {
    r := se.preds[p];
    if r.kind == .COMPARE return false;
    flags := r.pred;
    if (sc_flags(r.a) & SF_NSW) == SF_NSW flags &= ~INCREMENT_NSSW;
    return flags == 0;
}
sc_union_is_always_true :: (preds: [] u32) -> bool { for preds if !sc_pred_is_always_true(it) return false; return true; }
// SCEVUnionPredicate::implies(N) for a compare or wrap predicate N
sc_union_implies :: (preds: [] u32, n: u32) -> bool {
    for preds if sc_pred_implies(it, n) return true;
    if se.preds[n].kind != .WRAP return false;
    l := sc_loop(se.preds[n].a);
    for preds {
        if se.preds[it].kind != .WRAP continue;
        rw := sc_rewrite_using_predicate(se.preds[it].a, l, preds);
        if !sc_is_addrec(rw) continue;
        if sc_pred_implies(sc_get_wrap_predicate(rw, se.preds[it].pred), n) return true;
    }
    return false;
}
// SCEVUnionPredicate::add(N)
sc_union_add :: (preds: *[..] u32, n: u32) {
    check_implies := preds.count < 16;
    if check_implies && sc_union_implies(preds.*, n) return;
    pruned: [..] u32; pruned.allocator = preds.allocator;
    for preds.* {
        if check_implies && sc_pred_implies(n, it) continue;
        array_add(*pruned, it);
    }
    array_add(*pruned, n);
    preds.* = pruned;
}

// ---------------------------------------------------------------- PredicatedScalarEvolution

Pse_Entry :: struct { generation: u32; s: Scev_Id = SCEV_NULL; }
Pse :: struct {
    l: Loop_Id;
    preds: [..] u32;                         // the SCEVUnionPredicate
    rewrite_map: Table(Scev_Id, Pse_Entry);
    generation: u32;
    backedge_count: Scev_Id = SCEV_NULL;
    symbolic_max_backedge_count: Scev_Id = SCEV_NULL;
}
pse_init :: (p: *Pse, l: Loop_Id) {
    p.l = l;
    p.preds.allocator = temp;
    p.rewrite_map.allocator = temp;
}
pse_get_predicated_scev :: (p: *Pse, expr_in: Scev_Id) -> Scev_Id {
    expr := expr_in;
    e := table_find_pointer(*p.rewrite_map, expr);
    if !e { table_set(*p.rewrite_map, expr, .{}); e = table_find_pointer(*p.rewrite_map, expr); }
    if e.s != SCEV_NULL && p.generation == e.generation return e.s;
    if e.s != SCEV_NULL expr = e.s;
    new := sc_rewrite_using_predicate(expr, p.l, p.preds);
    e = table_find_pointer(*p.rewrite_map, expr_in);   // the rewrite may have grown the table
    e.* = .{p.generation, new};
    return new;
}
pse_get_scev :: (p: *Pse, v: Value_Id) -> Scev_Id { return pse_get_predicated_scev(p, sc_get_scev(v)); }
pse_add_predicate :: (p: *Pse, pred: u32) {
    if sc_union_implies(p.preds, pred) return;
    new_preds: [..] u32; new_preds.allocator = temp;
    for p.preds array_add(*new_preds, it);
    array_add(*new_preds, pred);
    u: [..] u32; u.allocator = temp;
    for new_preds sc_union_add(*u, it);
    p.preds = u;
    p.generation += 1;   // updateGeneration (no wrap-around in practice)
}
pse_add_predicates :: (p: *Pse, preds: [] u32) { for preds pse_add_predicate(p, it); }
pse_get_backedge_taken_count :: (p: *Pse) -> Scev_Id {
    if p.backedge_count == SCEV_NULL {
        preds: [..] u32; preds.allocator = temp;
        p.backedge_count = sc_get_predicated_backedge_taken_count(p.l, *preds);
        for preds pse_add_predicate(p, it);
    }
    return p.backedge_count;
}
pse_get_symbolic_max_backedge_taken_count :: (p: *Pse) -> Scev_Id {
    if p.symbolic_max_backedge_count == SCEV_NULL {
        preds: [..] u32; preds.allocator = temp;
        p.symbolic_max_backedge_count = sc_get_predicated_symbolic_max_backedge_taken_count(p.l, *preds);
        for preds pse_add_predicate(p, it);
    }
    return p.symbolic_max_backedge_count;
}
// hasNoOverflow(V, Flags)
pse_has_no_overflow :: (p: *Pse, v: Value_Id, flags_in: u8) -> bool {
    ar := pse_get_scev(p, v);
    if !sc_is_addrec(ar) return false;
    flags := flags_in & ~sc_wrap_implied_flags(ar);
    return flags == 0;
}
// getAsAddRec(V, ExtraPreds): SCEV_NULL when no AddRec
pse_get_as_add_rec :: (p: *Pse, v: Value_Id, extra_preds: *[..] u32 = null) -> Scev_Id {
    expr := pse_get_scev(p, v);
    new_preds: [..] u32; new_preds.allocator = temp;
    new := sc_convert_scev_to_add_rec_with_predicates(expr, p.l, *new_preds);
    if new == SCEV_CNC return SCEV_NULL;
    if extra_preds { for new_preds array_add(extra_preds, it); return new; }
    pse_add_predicates(p, new_preds);
    table_set(*p.rewrite_map, sc_get_scev(v), .{p.generation, new});
    return new;
}
// PredicatedScalarEvolution::print
pse_print :: (sb: *String_Builder, p: *Pse, li: *Loop_Info, depth: s64) {
    for bb: li_blocks(li, p.l) for i: block_insts(bb) {
        if !sc_is_scevable(vtype(i)) continue;
        expr := sc_get_scev(i);
        found, e := table_find(*p.rewrite_map, expr);
        if !found || e.s == expr continue;
        for 1..depth append(sb, " ");
        append(sb, "[PSE]"); append(sb, inst_to_string(i)); append(sb, ":\n");
        for 1..depth+2 append(sb, " ");
        sc_print(sb, expr); append(sb, "\n");
        for 1..depth+2 append(sb, " ");
        append(sb, "--> "); sc_print(sb, e.s); append(sb, "\n");
    }
}

// convertSCEVToAddRecWithPredicates (SCEV_CNC = nullptr)
sc_convert_scev_to_add_rec_with_predicates :: (s_in: Scev_Id, l: Loop_Id, preds: *[..] u32) -> Scev_Id {
    transform_preds: [..] u32; transform_preds.allocator = temp;
    s := scev_predicate_rewrite(s_in, l, *transform_preds);
    if !sc_is_addrec(s) return SCEV_CNC;
    for p: transform_preds {
        r := se.preds[p];
        if r.kind != .WRAP || r.pred != INCREMENT_NSSW continue;
        ar := r.a;
        exit_count := sc_get_backedge_taken_count(sc_loop(ar));
        if exit_count == SCEV_CNC continue;
        step := sc_step_recurrence(ar);
        if !sc_is_one(step) continue;
        exit_count = sc_get_truncate_or_sign_extend(exit_count, sc_type(step));
        add := sc_get_add2(sc_start(ar), exit_count);
        if sc_is_known_predicate(ICMP_SLT, add, sc_start(ar)) return SCEV_CNC;
    }
    for transform_preds array_add(preds, it);
    return s;
}

// isSimpleCastedPHI: (TruncTy or NONE, Signed)
is_simple_casted_phi :: (o: Scev_Id, symbolic_phi: Scev_Id) -> (Type_Id, bool) {
    if o == symbolic_phi return NONE, false;
    if sc_bits(symbolic_phi) != sc_bits(o) return NONE, false;
    if (sc_is_sext(o) || sc_is_zext(o)) && sc_is_trunc(sc_op(o, 0)) && sc_op(sc_op(o, 0), 0) == symbolic_phi
        return sc_type(sc_op(o, 0)), sc_is_sext(o);
    return NONE, false;
}

// createAddRecFromPHIWithCastsImpl
sc_create_add_rec_from_phi_with_casts_impl :: (symbolic_phi: Scev_Id) -> (bool, Scev_Id, [..] u32) {
    predicates: [..] u32; predicates.allocator = context.default_allocator;
    pn := sc_value(symbolic_phi);
    l := is_integer_loop_header_phi(pn);
    be_value_v: Value_Id = NONE; start_value_v: Value_Id = NONE;
    for i: 0..cast(s64) nops(pn) - 1 {
        v := phi_value(pn, cast(u32) i);
        if li_contains(se.li, l, phi_block(pn, cast(u32) i)) {
            if be_value_v == NONE be_value_v = v;
            else if be_value_v != v { be_value_v = NONE; break; }
        } else if start_value_v == NONE start_value_v = v;
        else if start_value_v != v { start_value_v = NONE; break; }
    }
    if be_value_v == NONE || start_value_v == NONE return false, 0, predicates;
    be_value := sc_get_scev(be_value_v);
    if !sc_is_add(be_value) return false, 0, predicates;
    add := be_value;
    n := sc_nops(add);
    found_index := n;
    trunc_ty: Type_Id = NONE;
    signed := false;
    for i: 0..cast(s64) n - 1 {
        tt, sg := is_simple_casted_phi(sc_op(add, cast(u32) i), symbolic_phi);
        if tt != NONE { trunc_ty = tt; signed = sg; found_index = cast(u32) i; break; }
    }
    if found_index == n return false, 0, predicates;
    ops: [..] Scev_Id; ops.allocator = temp;
    for i: 0..cast(s64) n - 1 if cast(u32) i != found_index array_add(*ops, sc_op(add, cast(u32) i));
    accum := sc_get_add(*ops);
    if !sc_is_loop_invariant(accum, l) return false, 0, predicates;
    start_val := sc_get_scev(start_value_v);
    phi_scev := sc_get_add_rec(sc_get_truncate(start_val, trunc_ty), sc_get_truncate(accum, trunc_ty), l, SF_ANY);
    if sc_is_addrec(phi_scev) {
        added := ifx signed then INCREMENT_NSSW else INCREMENT_NUSW;
        array_add(*predicates, sc_get_wrap_predicate(phi_scev, added));
    }
    get_extended_expr :: (e: Scev_Id, sign: bool, trunc_ty: Type_Id) -> Scev_Id {
        t := sc_get_truncate(e, trunc_ty);
        if sign return sc_get_sign_extend(t, sc_type(e));
        return sc_get_zero_extend(t, sc_type(e));
    }
    pred_is_known_false :: (e: Scev_Id, ext: Scev_Id) -> bool { return e != ext && sc_is_known_predicate(ICMP_NE, e, ext); }
    start_extended := get_extended_expr(start_val, signed, trunc_ty);
    if pred_is_known_false(start_val, start_extended) return false, 0, predicates;
    accum_extended := get_extended_expr(accum, true, trunc_ty);
    if pred_is_known_false(accum, accum_extended) return false, 0, predicates;
    if start_val != start_extended && !sc_is_known_predicate(ICMP_EQ, start_val, start_extended)
        array_add(*predicates, sc_get_equal_predicate(start_val, start_extended));
    if accum != accum_extended && !sc_is_known_predicate(ICMP_EQ, accum, accum_extended)
        array_add(*predicates, sc_get_equal_predicate(accum, accum_extended));
    new_ar := sc_get_add_rec(start_val, accum, l, SF_ANY);
    pr: Pred_Rewrite;
    pr.s = new_ar;
    for predicates array_add(*pr.preds, it);
    key := ((cast(u64) symbolic_phi) << 32) | cast(u64) l;
    table_set(*se.predicated_rewrites, key, pr);
    return true, new_ar, predicates;
}

// createAddRecFromPHIWithCasts: (ok, rewritten SCEV, predicates)
sc_create_add_rec_from_phi_with_casts :: (symbolic_phi: Scev_Id) -> (bool, Scev_Id, [] u32) {
    pn := sc_value(symbolic_phi);
    l := is_integer_loop_header_phi(pn);
    if l == NONE return false, 0, .[];
    key := ((cast(u64) symbolic_phi) << 32) | cast(u64) l;
    found, rw := table_find(*se.predicated_rewrites, key);
    if found {
        if rw.s == symbolic_phi return false, 0, .[];
        return true, rw.s, rw.preds;
    }
    ok, s, preds := sc_create_add_rec_from_phi_with_casts_impl(symbolic_phi);
    if !ok {
        pr: Pred_Rewrite;
        pr.s = symbolic_phi;
        table_set(*se.predicated_rewrites, key, pr);
        return false, 0, .[];
    }
    return true, s, preds;
}
