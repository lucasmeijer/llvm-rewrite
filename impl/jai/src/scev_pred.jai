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

// ---------------------------------------------------------------- SCEVPredicateRewriter (NewPreds form)

Pred_Rewrite_Ctx :: struct { new_preds: *[..] u32; }
scev_predicate_rewrite :: (s: Scev_Id, l: Loop_Id, new_preds: *[..] u32) -> Scev_Id {
    ctx: Pred_Rewrite_Ctx;
    ctx.new_preds = new_preds;
    rw: Sc_Rewriter; sc_rewriter_init(*rw);
    rw.l = l;
    rw.data = *ctx;
    rw.hook = (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
        c := cast(*Pred_Rewrite_Ctx) rw.data;
        k := sc_kind(s);
        if k == .UNKNOWN {
            // convertToAddRecWithPreds
            v := sc_value(s);
            if !is_inst(v) || inst_op(v) != .PHI return true, s;
            ok, res, preds := sc_create_add_rec_from_phi_with_casts(s);
            if !ok return true, s;
            for p: preds {
                if se.preds[p].kind == .WRAP && rw.l != sc_loop(se.preds[p].a) return true, s;
                array_add(c.new_preds, p);
            }
            return true, res;
        }
        if k == .ZEXT || k == .SEXT {
            operand := sc_rewrite(rw, sc_op(s, 0));
            ty := sc_type(s);
            if sc_is_addrec(operand) && sc_loop(operand) == rw.l && sc_is_affine(operand) {
                step := sc_step_recurrence(operand);
                flag := ifx k == .ZEXT then INCREMENT_NUSW else INCREMENT_NSSW;
                array_add(c.new_preds, sc_get_wrap_predicate(operand, flag));
                start := ifx k == .ZEXT then sc_get_zero_extend(sc_start(operand), ty) else sc_get_sign_extend(sc_start(operand), ty);
                return true, sc_get_add_rec(start, sc_get_sign_extend(step, ty), rw.l, sc_flags(operand));
            }
            if k == .ZEXT return true, sc_get_zero_extend(operand, ty);
            return true, sc_get_sign_extend(operand, ty);
        }
        return false, 0;
    };
    return sc_rewrite(*rw, s);
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
