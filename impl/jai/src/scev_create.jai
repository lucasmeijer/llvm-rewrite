// ScalarEvolution, part 2: building SCEVs for IR values and the memoization bookkeeping.
// Port of llvm/lib/Analysis/ScalarEvolution.cpp (LLVM 23.1.5): getSCEV / getExistingSCEV / createSCEVIter /
// getOperandsToCreate / createSCEV, MatchBinaryOp, createNodeForPHI (createAddRecFromPHI, createSimpleAffineAddRec,
// SCEVBackedgeConditionFolder / SCEVShiftRewriter / SCEVInitRewriter / SCEVPostIncRewriter, select-like PHIs,
// PHIs with identical operands), createNodeForSelectOrPHI*, createNodeForGEP, getNoWrapFlagsFromUB,
// getDefiningScopeBound, isGuaranteedToTransferExecutionTo, isSCEVExprNeverPoison, isAddRecNeverPoison,
// getLoopProperties, insertValueToMap / eraseValueFromMap, registerUser / forgetMemoizedResults(Impl),
// and the generic SCEVRewriteVisitor (Sc_Rewriter).

IID_START_LOOP_ITERATIONS :: #run iid_by_name("llvm.start.loop.iterations");
IID_LOOP_DECREMENT_REG :: #run iid_by_name("llvm.loop.decrement.reg");

ac_has_assumptions :: (ac: *Assumption_Cache) -> bool { return ac != null && ac.assumes.count > 0; }

// ---------------------------------------------------------------- memoization bookkeeping

// registerUser(User, Ops): constants are not tracked
sc_register_user :: (user: Scev_Id, ops: [] Scev_Id) {
    for o: ops {
        if sc_is_const(o) continue;
        p := table_find_pointer(*se.users, o);
        if !p { blank: [..] Scev_Id; table_set(*se.users, o, blank); p = table_find_pointer(*se.users, o); }
        found := false;
        for p.* if it == user { found = true; break; }
        if !found array_add(p, user);
    }
}

// insertValueToMap
sc_insert_value_to_map :: (v: Value_Id, s: Scev_Id) {
    if table_contains(*se.value_expr, v) return;
    table_set(*se.value_expr, v, s);
    p := table_find_pointer(*se.expr_values, s);
    if !p { blank: [..] Value_Id; table_set(*se.expr_values, s, blank); p = table_find_pointer(*se.expr_values, s); }
    for p.* if it == v return;
    array_add(p, v);
}
// eraseValueFromMap
sc_erase_value_from_map :: (v: Value_Id) {
    found, s := table_find(*se.value_expr, v);
    if !found return;
    p := table_find_pointer(*se.expr_values, s);
    if p for p.* if it == v { array_ordered_remove_by_index(p, it_index); break; }
    table_remove(*se.value_expr, v);
}
// getExistingSCEV (SCEV_CNC = nullptr; a value never maps to CouldNotCompute)
sc_get_existing :: (v: Value_Id) -> Scev_Id {
    found, s := table_find(*se.value_expr, v);
    if found return s;
    return SCEV_CNC;
}
// getSCEVValues
sc_get_scev_values :: (s: Scev_Id) -> [] Value_Id {
    p := table_find_pointer(*se.expr_values, s);
    if !p return .[];
    return p.*;
}

// insertFoldCacheEntry
sc_insert_fold_cache :: (id: u64, s: Scev_Id) {
    found, old := table_find(*se.fold_cache, id);
    if found {
        up := table_find_pointer(*se.fold_cache_user, old);
        if up for up.* if it == id { up.*[it_index] = up.*[up.count - 1]; up.count -= 1; break; }
    }
    table_set(*se.fold_cache, id, s);
    p := table_find_pointer(*se.fold_cache_user, s);
    if !p { blank: [..] u64; table_set(*se.fold_cache_user, s, blank); p = table_find_pointer(*se.fold_cache_user, s); }
    array_add(p, id);
}

// forgetMemoizedResults(SCEVs)
sc_forget_memoized_results :: (scevs: [] Scev_Id) {
    to_forget: Table(Scev_Id, bool); to_forget.allocator = temp;
    order: [..] Scev_Id; order.allocator = temp;
    work: [..] Scev_Id; work.allocator = temp;
    for scevs if !table_contains(*to_forget, it) { table_set(*to_forget, it, true); array_add(*order, it); array_add(*work, it); }
    while work.count > 0 {
        curr := pop(*work);
        users := table_find_pointer(*se.users, curr);
        if users for u: users.* {
            if !table_contains(*to_forget, u) { table_set(*to_forget, u, true); array_add(*order, u); array_add(*work, u); }
        }
    }
    for order sc_forget_memoized_results_impl(it);
    // PredicatedSCEVRewrites.remove_if(key SCEV in ToForget)
    rm: [..] u64; rm.allocator = temp;
    for v, k: se.predicated_rewrites if table_contains(*to_forget, cast(Scev_Id) (k >> 32)) array_add(*rm, k);
    for rm table_remove(*se.predicated_rewrites, it);
}

sc_forget_memoized_results_impl :: (s: Scev_Id) {
    table_remove(*se.loop_disp, s);
    table_remove(*se.block_disp, s);
    table_remove(*se.unsigned_ranges, s);
    table_remove(*se.signed_ranges, s);
    table_remove(*se.has_rec, s);
    table_remove(*se.const_multiple, s);
    if sc_is_addrec(s) {
        table_remove(*se.unsigned_wrap_tried, s);
        table_remove(*se.signed_wrap_tried, s);
    }
    ev := table_find_pointer(*se.expr_values, s);
    if ev {
        for v: ev.* table_remove(*se.value_expr, v);
        table_remove(*se.expr_values, s);
    }
    scope := table_find_pointer(*se.values_at_scopes, s);
    if scope {
        for pair: scope.* {
            if pair.s != NONE && !sc_is_const(pair.s) {
                u := table_find_pointer(*se.values_at_scopes_users, pair.s);
                if u for u.* if it.l == pair.l && it.s == s { array_ordered_remove_by_index(u, it_index); break; }
            }
        }
        table_remove(*se.values_at_scopes, s);
    }
    scope_user := table_find_pointer(*se.values_at_scopes_users, s);
    if scope_user {
        for pair: scope_user.* {
            vs := table_find_pointer(*se.values_at_scopes, pair.s);
            if vs for vs.* if it.l == pair.l && it.s == s { array_ordered_remove_by_index(vs, it_index); break; }
        }
        table_remove(*se.values_at_scopes_users, s);
    }
    be := table_find_pointer(*se.be_count_users, s);
    if be {
        copy: [..] u64; copy.allocator = temp;
        for be.* array_add(*copy, it);
        for copy sc_forget_backedge_taken_counts(cast(Loop_Id) (it >> 1), (it & 1) != 0);
        table_remove(*se.be_count_users, s);
    }
    fu := table_find_pointer(*se.fold_cache_user, s);
    if fu {
        for fu.* table_remove(*se.fold_cache, it);
        table_remove(*se.fold_cache_user, s);
    }
}

// ---------------------------------------------------------------- the rewriter (SCEVRewriteVisitor)

// One kind per SCEVRewriteVisitor subclass we emulate, plus that kind's state. sc_rewrite_dispatch is the one
// place LLVM makes the virtual visit call: each kind's visit procedure may handle a node itself (handled = true);
// everything else gets the default rewrite.
Sc_Rewriter_Kind :: enum u8 {
    INIT;            // SCEVInitRewriter                   (scev_create.jai)
    POST_INC;        // SCEVPostIncRewriter                (scev_create.jai)
    SHIFT;           // SCEVShiftRewriter                  (scev_create.jai)
    BACKEDGE_FOLD;   // SCEVBackedgeConditionFolder        (scev_create.jai)
    LOOP_GUARDS;     // LoopGuards::rewrite's SCEVLoopGuardRewriter (scev_guards.jai)
    PREDICATE;       // SCEVPredicateRewriter                        (scev_pred.jai)
    NORMALIZE;       // NormalizeDenormalizeRewriter                 (iv_users.jai)
    UNIFORMITY;      // SCEVAddRecForUniformityRewriter              (lv_legality.jai)
    PTR_TO_ADDR;     // SCEVPtrToAddrRewriter (LoopUtils.cpp)        (lv_execute.jai)
    PARAMETER;       // SCEVParameterRewriter                         (lv_plan.jai)
}
Sc_Rewriter :: struct {
    kind: Sc_Rewriter_Kind;
    memo: Table(Scev_Id, Scev_Id);
    l: Loop_Id = NONE;                  // INIT, POST_INC, SHIFT, BACKEDGE_FOLD, PREDICATE
    seen_loop_variant_unknown: bool;    // INIT, POST_INC, SHIFT
    seen_other_loops: bool;             // INIT, POST_INC
    invalid: bool;                      // SHIFT (!Valid)
    be_cond: Value_Id = NONE;           // BACKEDGE_FOLD: BackedgeCond
    is_positive_be_cond: bool;          // BACKEDGE_FOLD
    guards: *Loop_Guards;               // LOOP_GUARDS
    flag_mask: u8;                      // LOOP_GUARDS: FlagMask
    new_preds: *[..] u32;               // PREDICATE: NewPreds (null = none)
    pred_union: [] u32;                 // PREDICATE: Pred, a SCEVUnionPredicate (has_pred)
    has_pred: bool;                     // PREDICATE
    norm: *Norm_Ctx;                    // NORMALIZE
    step_multiplier: u64;               // UNIFORMITY
    offset: u64;                        // UNIFORMITY
    cannot_analyze: bool;               // UNIFORMITY
    param_map: *Table(Value_Id, Scev_Id);   // PARAMETER
}
sc_rewriter_init :: (rw: *Sc_Rewriter, kind: Sc_Rewriter_Kind) { rw.kind = kind; rw.memo.allocator = temp; }
sc_rewrite :: (rw: *Sc_Rewriter, s: Scev_Id) -> Scev_Id {
    found, r := table_find(*rw.memo, s);
    if found return r;
    res := sc_rewrite_dispatch(rw, s);
    table_set(*rw.memo, s, res);
    return res;
}
sc_rewrite_dispatch :: (rw: *Sc_Rewriter, s: Scev_Id) -> Scev_Id {
    handled: bool;
    r: Scev_Id;
    if #complete rw.kind == {
        case .INIT;          handled, r = sc_rw_init_visit(rw, s);
        case .POST_INC;      handled, r = sc_rw_post_inc_visit(rw, s);
        case .SHIFT;         handled, r = sc_rw_shift_visit(rw, s);
        case .BACKEDGE_FOLD; handled, r = sc_rw_backedge_fold_visit(rw, s);
        case .LOOP_GUARDS;   handled, r = sc_rw_loop_guards_visit(rw, s);
        case .PREDICATE;     handled, r = sc_rw_predicate_visit(rw, s);
        case .NORMALIZE;     handled, r = sc_rw_normalize_visit(rw, s);
        case .UNIFORMITY;    handled, r = sc_rw_uniformity_visit(rw, s);
        case .PTR_TO_ADDR;   handled, r = sc_rw_ptr_to_addr_visit(rw, s);
        case .PARAMETER;
            if sc_kind(s) == .UNKNOWN {
                found, m := table_find(rw.param_map, sc_value(s));
                handled = true; r = ifx found then m else s;
            }
    }
    if handled return r;
    return sc_rewrite_default(rw, s);
}
sc_rewrite_default :: (rw: *Sc_Rewriter, s: Scev_Id) -> Scev_Id {
    k := sc_kind(s);
    if k == {
        case .CONSTANT; #through;
        case .VSCALE; #through;
        case .UNKNOWN; #through;
        case .CNC; return s;
        case .PTRTOADDR;
            o := sc_rewrite(rw, sc_op(s, 0));
            if o == sc_op(s, 0) return s;
            return sc_get_ptr_to_addr(o);
        case .PTRTOINT;
            o := sc_rewrite(rw, sc_op(s, 0));
            if o == sc_op(s, 0) return s;
            return sc_get_ptr_to_int(o, sc_type(s));
        case .TRUNC;
            o := sc_rewrite(rw, sc_op(s, 0));
            if o == sc_op(s, 0) return s;
            return sc_get_truncate(o, sc_type(s));
        case .ZEXT;
            o := sc_rewrite(rw, sc_op(s, 0));
            if o == sc_op(s, 0) return s;
            return sc_get_zero_extend(o, sc_type(s));
        case .SEXT;
            o := sc_rewrite(rw, sc_op(s, 0));
            if o == sc_op(s, 0) return s;
            return sc_get_sign_extend(o, sc_type(s));
        case .UDIV;
            a := sc_rewrite(rw, sc_op(s, 0));
            b := sc_rewrite(rw, sc_op(s, 1));
            if a == sc_op(s, 0) && b == sc_op(s, 1) return s;
            return sc_get_udiv(a, b);
    }
    ops: [..] Scev_Id; ops.allocator = temp;
    changed := false;
    n := sc_nops(s);
    for i: 0..cast(s64) n - 1 {
        o := sc_op(s, cast(u32) i);
        r := sc_rewrite(rw, o);
        array_add(*ops, r);
        changed |= r != o;
    }
    if !changed return s;
    if k == {
        case .ADD; return sc_get_add(*ops);
        case .MUL; return sc_get_mul(*ops);
        case .ADDREC; return sc_get_add_rec_ops(*ops, sc_loop(s), sc_flags(s));
        case .SMAX; #through;
        case .UMAX; #through;
        case .SMIN; #through;
        case .UMIN; return sc_get_min_max(k, *ops);
        case .SEQ_UMIN; return sc_get_umin(*ops, true);
    }
    return s;
}

// SCEVInitRewriter
sc_rw_init_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if sc_is_unknown(s) { if !sc_is_loop_invariant(s, rw.l) rw.seen_loop_variant_unknown = true; return true, s; }
    if sc_is_addrec(s) {
        if sc_loop(s) == rw.l return true, sc_start(s);
        rw.seen_other_loops = true;
        return true, s;
    }
    return false, 0;
}
// SCEVInitRewriter::rewrite
scev_init_rewrite :: (s: Scev_Id, l: Loop_Id, ignore_other_loops := true) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .INIT);
    rw.l = l;
    result := sc_rewrite(*rw, s);
    if rw.seen_loop_variant_unknown return SCEV_CNC;
    if rw.seen_other_loops && !ignore_other_loops return SCEV_CNC;
    return result;
}
// SCEVPostIncRewriter
sc_rw_post_inc_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if sc_is_unknown(s) { if !sc_is_loop_invariant(s, rw.l) rw.seen_loop_variant_unknown = true; return true, s; }
    if sc_is_addrec(s) {
        if sc_loop(s) == rw.l return true, sc_get_post_inc_expr(s);
        rw.seen_other_loops = true;
        return true, s;
    }
    return false, 0;
}
// SCEVPostIncRewriter::rewrite
scev_post_inc_rewrite :: (s: Scev_Id, l: Loop_Id) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .POST_INC);
    rw.l = l;
    result := sc_rewrite(*rw, s);
    if rw.seen_loop_variant_unknown return SCEV_CNC;
    return result;
}
// SCEVShiftRewriter
sc_rw_shift_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if sc_is_unknown(s) { if !sc_is_loop_invariant(s, rw.l) rw.invalid = true; return true, s; }
    if sc_is_addrec(s) {
        if sc_loop(s) == rw.l && sc_is_affine(s) return true, sc_get_minus(s, sc_step_recurrence(s));
        rw.invalid = true;
        return true, s;
    }
    return false, 0;
}
// SCEVShiftRewriter::rewrite
scev_shift_rewrite :: (s: Scev_Id, l: Loop_Id) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .SHIFT);
    rw.l = l;
    result := sc_rewrite(*rw, s);
    if rw.invalid return SCEV_CNC;
    return result;
}
// SCEVBackedgeConditionFolder::visitUnknown
sc_rw_backedge_fold_visit :: (rw: *Sc_Rewriter, s: Scev_Id) -> (bool, Scev_Id) {
    if !sc_is_unknown(s) return false, 0;
    result := s;
    if !sc_is_loop_invariant(s, rw.l) {
        i := sc_value(s);
        compare :: (rw: *Sc_Rewriter, ic: Value_Id) -> (bool, Scev_Id) {
            if rw.be_cond == ic {
                if rw.is_positive_be_cond return true, sc_get_one(type_int(1));
                return true, sc_get_zero(type_int(1));
            }
            return false, 0;
        }
        if inst_op(i) == .SELECT {
            ok, res := compare(rw, op(i, 0));
            if ok {
                is_one := sc_is_one(res);
                result = sc_get_scev(ifx is_one then op(i, 1) else op(i, 2));
            }
        } else {
            ok, res := compare(rw, i);
            if ok result = res;
        }
    }
    return true, result;
}
// SCEVBackedgeConditionFolder::rewrite
scev_backedge_condition_fold :: (s: Scev_Id, l: Loop_Id) -> Scev_Id {
    rw: Sc_Rewriter; sc_rewriter_init(*rw, .BACKEDGE_FOLD);
    rw.l = l;
    latch := li_loop_latch(se.li, l);
    if latch != NONE {
        t := block_terminator(latch);
        if inst_op(t) == .CONDBR {
            rw.be_cond = op(t, 0);
            rw.is_positive_be_cond = get_successor(t, 0) == li_header(se.li, l);
        } else return s;
    }
    return sc_rewrite(*rw, s);
}

// SCEVAddRecExpr::getPostIncExpr
sc_get_post_inc_expr :: (ar: Scev_Id) -> Scev_Id {
    ops: [..] Scev_Id; ops.allocator = temp;
    n := sc_nops(ar);
    for i: 0..cast(s64) n - 2 array_add(*ops, sc_get_add2(sc_op(ar, cast(u32) i), sc_op(ar, cast(u32) i + 1)));
    array_add(*ops, sc_op(ar, n - 1));
    return sc_get_add_rec_ops(*ops, sc_loop(ar), SF_ANY);
}

// ---------------------------------------------------------------- getSCEV

sc_get_scev :: (v: Value_Id) -> Scev_Id {
    s := sc_get_existing(v);
    if s != SCEV_CNC return s;
    return sc_create_scev_iter(v);
}

// createSCEVIter
sc_create_scev_iter :: (v: Value_Id) -> Scev_Id {
    Entry :: struct { v: Value_Id; ready: bool; }
    stack: [..] Entry; stack.allocator = temp;
    array_add(*stack, .{v, false});
    while stack.count > 0 {
        e := stack[stack.count - 1];
        cur := e.v;
        if sc_get_existing(cur) != SCEV_CNC { stack.count -= 1; continue; }
        ops: [..] Value_Id; ops.allocator = temp;
        created: Scev_Id = SCEV_CNC;
        if e.ready created = sc_create_scev(cur);
        else created = sc_get_operands_to_create(cur, *ops);
        if created != SCEV_CNC {
            sc_insert_value_to_map(cur, created);
            stack.count -= 1;
        } else {
            stack[stack.count - 1].ready = true;
            for ops array_add(*stack, .{it, false});
        }
    }
    return sc_get_existing(v);
}

// MatchBinaryOp
Binary_Op :: struct {
    opcode: Opcode;
    lhs: Value_Id;
    rhs: Value_Id;
    is_nsw: bool;
    is_nuw: bool;
    op: Value_Id = NONE;   // the Operator, or NONE
}
binary_op_of :: (o: Value_Id) -> Binary_Op {
    r: Binary_Op;
    r.opcode = opr_code(o);
    r.lhs = op(o, 0);
    r.rhs = op(o, 1);
    r.op = o;
    if r.opcode == .ADD || r.opcode == .SUB || r.opcode == .MUL || r.opcode == .SHL {
        f := opr_flags(o);
        r.is_nsw = (f & F_NSW) != 0;
        r.is_nuw = (f & F_NUW) != 0;
    }
    return r;
}
match_binary_op :: (v: Value_Id, cxt: Value_Id) -> (bool, Binary_Op) {
    none: Binary_Op;
    k := vkind(v);
    if k != .INST && k != .C_EXPR return false, none;
    opc := opr_code(v);
    if opc == {
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .UDIV; #through; case .UREM; #through;
        case .AND; #through; case .ASHR; #through; case .SHL;
            return true, binary_op_of(v);
        case .OR;
            if opr_flags(v) & F_EXACT {
                r: Binary_Op;
                r.opcode = .ADD; r.lhs = op(v, 0); r.rhs = op(v, 1); r.is_nsw = true; r.is_nuw = true; r.op = v;
                return true, r;
            }
            return true, binary_op_of(v);
        case .XOR;
            rhs := op(v, 1);
            if vkind(rhs) == .C_INT && type_kind(vtype(rhs)) == .INT {
                a := ap_from_words(type_int_width(vtype(rhs)), const_int_value(rhs));
                if ap_is_sign_mask(a) {
                    r: Binary_Op; r.opcode = .ADD; r.lhs = op(v, 0); r.rhs = rhs;
                    return true, r;
                }
            }
            if type_kind(vtype(v)) == .INT && type_int_width(vtype(v)) == 1 {
                r: Binary_Op; r.opcode = .ADD; r.lhs = op(v, 0); r.rhs = op(v, 1);
                return true, r;
            }
            return true, binary_op_of(v);
        case .LSHR;
            sa := op(v, 1);
            if vkind(sa) == .C_INT && type_kind(vtype(sa)) == .INT {
                bits := type_int_width(vtype(v));
                sav := ap_from_words(type_int_width(vtype(sa)), const_int_value(sa));
                if ap_ult_u64(sav, cast(u64) bits) {
                    x := const_int_words(type_int(bits), ap_words(ap_one_bit_set(bits, cast(u32) ap_zext_value(sav))));
                    r: Binary_Op; r.opcode = .UDIV; r.lhs = op(v, 0); r.rhs = x;
                    return true, r;
                }
            }
            return true, binary_op_of(v);
        case .EXTRACTVALUE;
            if k != .INST return false, none;
            idx := inst_indices(v);
            if idx.count != 1 || idx[0] != 0 return false, none;
            wo := op(v, 0);
            if !is_inst(wo) || !is_with_overflow_inst(wo) return false, none;
            id := call_iid(wo);
            bin: Opcode;
            signed := false;
            if id == IID_SADD_WITH_OVERFLOW { bin = .ADD; signed = true; }
            else if id == IID_UADD_WITH_OVERFLOW bin = .ADD;
            else if id == IID_SSUB_WITH_OVERFLOW { bin = .SUB; signed = true; }
            else if id == IID_USUB_WITH_OVERFLOW bin = .SUB;
            else if id == IID_SMUL_WITH_OVERFLOW { bin = .MUL; signed = true; }
            else bin = .MUL;
            r: Binary_Op; r.opcode = bin; r.lhs = op(wo, 0); r.rhs = op(wo, 1);
            if bin == .MUL || !is_overflow_intrinsic_no_wrap(wo, se.dt) return true, r;
            r.is_nsw = signed; r.is_nuw = !signed;
            return true, r;
    }
    if k == .INST && opc == .CALL && call_iid(v) == IID_LOOP_DECREMENT_REG {
        r: Binary_Op; r.opcode = .SUB; r.lhs = op(v, 0); r.rhs = op(v, 1);
        return true, r;
    }
    return false, none;
}

// isOverflowIntrinsicNoWrap (ValueTracking.cpp)
is_overflow_intrinsic_no_wrap :: (wo: Value_Id, dt: *Dom_Tree) -> bool {
    guarding: [..] Value_Id; guarding.allocator = temp;
    results: [..] Value_Id; results.allocator = temp;
    u := ir.v_first_use[wo];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && inst_op(user) == .EXTRACTVALUE {
            if inst_indices(user)[0] == 0 array_add(*results, user);
            else {
                u2 := ir.v_first_use[user];
                while u2 != NONE {
                    b := ir.u_user[u2];
                    if is_inst(b) && inst_op(b) == .CONDBR array_add(*guarding, b);
                    u2 = ir.u_next[u2];
                }
            }
        } else return false;
        u = ir.u_next[u];
    }
    for bi: guarding {
        start := inst_block(bi);
        end := get_successor(bi, 1);
        all_guarded := true;
        for r: results {
            if dt_dominates_edge_block(dt, start, end, inst_block(r)) continue;
            ru := ir.v_first_use[r];
            while ru != NONE {
                if !dt_dominates_edge_use(dt, start, end, ru) { all_guarded = false; break; }
                ru = ir.u_next[ru];
            }
            if !all_guarded break;
        }
        if all_guarded return true;
    }
    return false;
}

is_int_type_bits :: (t: Type_Id, bits: u32) -> bool { return type_kind(t) == .INT && type_int_width(t) == bits; }

// getOperandsToCreate (SCEV_CNC = nullptr)
sc_get_operands_to_create :: (v: Value_Id, ops: *[..] Value_Id) -> Scev_Id {
    if !sc_is_scevable(vtype(v)) return sc_get_unknown(v);
    k := vkind(v);
    if k == .INST {
        if !dt_is_reachable_from_entry(se.dt, inst_block(v)) return sc_get_unknown(const_poison(vtype(v)));
    } else if is_const_int(v) return sc_get_constant_value(v);
    else if k == .ALIAS return sc_get_unknown(v);
    else if k != .C_EXPR return sc_get_unknown(v);

    cxt := ifx k == .INST then v else NONE;
    ok, bo := match_binary_op(v, cxt);
    if ok {
        is_const_arg := is_const_int(bo.rhs);
        if bo.opcode == {
            case .ADD; #through;
            case .MUL;
                while true {
                    if bo.op != NONE {
                        if bo.op != v && sc_get_existing(bo.op) != SCEV_CNC { array_add(ops, bo.op); break; }
                    }
                    array_add(ops, bo.rhs);
                    ok2, new_bo := match_binary_op(bo.lhs, cxt);
                    if !ok2 || (bo.opcode == .ADD && (new_bo.opcode != .ADD && new_bo.opcode != .SUB)) ||
                       (bo.opcode == .MUL && new_bo.opcode != .MUL) {
                        array_add(ops, bo.lhs);
                        break;
                    }
                    if bo.op != NONE && (bo.is_nsw || bo.is_nuw) {
                        if is_inst(bo.op) && program_undefined_if_poison(bo.op) { array_add(ops, bo.lhs); break; }
                    }
                    bo = new_bo;
                }
                return SCEV_CNC;
            case .SUB; #through; case .UDIV; #through; case .UREM;
            case .ASHR; #through; case .SHL; #through; case .XOR;
                if !is_const_arg return SCEV_CNC;
            case .AND; #through; case .OR;
                if !is_const_arg && !is_int_type_bits(vtype(bo.lhs), 1) return SCEV_CNC;
            case .LSHR;
                return sc_get_unknown(v);
            case;
                fatal("ScalarEvolution: unhandled binop in getOperandsToCreate");
        }
        array_add(ops, bo.lhs);
        array_add(ops, bo.rhs);
        return SCEV_CNC;
    }

    opc := opr_code(v);
    if opc == {
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .PTRTOADDR; #through; case .PTRTOINT;
            array_add(ops, op(v, 0));
            return SCEV_CNC;
        case .BITCAST;
            if sc_is_scevable(vtype(v)) && sc_is_scevable(vtype(op(v, 0))) { array_add(ops, op(v, 0)); return SCEV_CNC; }
            return sc_get_unknown(v);
        case .SDIV; #through; case .SREM;
            array_add(ops, op(v, 0)); array_add(ops, op(v, 1));
            return SCEV_CNC;
        case .GEP;
            for i: 0..cast(s64) nops(v) - 1 array_add(ops, op(v, cast(u32) i));
            return SCEV_CNC;
        case .INTTOPTR;
            return sc_get_unknown(v);
        case .PHI;
            sv := simplify_instruction(v, scev_simplify_query());
            if sv != NONE { array_add(ops, sv); return SCEV_CNC; }
            ci := get_common_inst_for_phi(v);
            if ci != NONE { array_add(ops, ci); return SCEV_CNC; }
            {
                ok3, cond, lhs, rhs := get_operands_for_select_like_phi(v);
                if ok3 {
                    if is_inst(cond) && inst_op(cond) == .ICMP { array_add(ops, op(cond, 0)); array_add(ops, op(cond, 1)); }
                    array_add(ops, cond); array_add(ops, lhs); array_add(ops, rhs);
                    return SCEV_CNC;
                }
            }
            if range_ref_phi_allowed_operands(v) {
                for i: 0..cast(s64) nops(v) - 1 array_add(ops, op(v, cast(u32) i));
                return SCEV_CNC;
            }
            return SCEV_CNC;
        case .SELECT;
            can_simplify_to_unknown :: (u: Value_Id) -> bool {
                if is_int_type_bits(vtype(u), 1) || is_const_int(op(u, 0)) return false;
                ici := op(u, 0);
                if !(is_inst(ici) && inst_op(ici) == .ICMP) return false;
                lhs := op(ici, 0); rhs := op(ici, 1);
                p := inst_pred(ici);
                if p == ICMP_EQ || p == ICMP_NE {
                    if !(is_const_int(rhs) && ap_is_zero(const_ap(rhs))) return true;
                } else if sc_type_bits(vtype(lhs)) > sc_type_bits(vtype(u)) return true;
                return false;
            }
            if can_simplify_to_unknown(v) return sc_get_unknown(v);
            for i: 0..cast(s64) nops(v) - 1 array_add(ops, op(v, cast(u32) i));
            return SCEV_CNC;
        case .CALL; #through; case .INVOKE;
            rv := call_returned_arg(v);
            if rv != NONE { array_add(ops, rv); return SCEV_CNC; }
            id := call_iid(v);
            if id == IID_ABS { array_add(ops, op(v, 0)); return SCEV_CNC; }
            if id == IID_UMAX || id == IID_UMIN || id == IID_SMAX || id == IID_SMIN || id == IID_USUB_SAT || id == IID_UADD_SAT {
                array_add(ops, op(v, 0)); array_add(ops, op(v, 1));
                return SCEV_CNC;
            }
            if id == IID_START_LOOP_ITERATIONS || id == IID_ANNOTATION || id == IID_PTR_ANNOTATION {
                array_add(ops, op(v, 0));
                return SCEV_CNC;
            }
    }
    return SCEV_CNC;
}

// The SimplifyQuery createNodeForPHI / getOperandsToCreate pass to simplifyInstruction
scev_simplify_query :: () -> Simplify_Query {
    q: Simplify_Query;
    q.dt = se.dt;
    q.ac = se.ac;
    q.cxt = NONE;
    q.use_instr_info = true;
    q.can_use_undef = false;
    return q;
}

// createSCEV
sc_create_scev :: (v: Value_Id) -> Scev_Id {
    if !sc_is_scevable(vtype(v)) return sc_get_unknown(v);
    k := vkind(v);
    if k == .INST {
        if !dt_is_reachable_from_entry(se.dt, inst_block(v)) return sc_get_unknown(const_poison(vtype(v)));
    } else if is_const_int(v) return sc_get_constant_value(v);
    else if k == .ALIAS return sc_get_unknown(v);
    else if k != .C_EXPR return sc_get_unknown(v);

    cxt := ifx k == .INST then v else NONE;
    ok, bo := match_binary_op(v, cxt);
    if ok {
        if bo.opcode == {
            case .ADD;
                add_ops: [..] Scev_Id; add_ops.allocator = temp;
                while true {
                    if bo.op != NONE {
                        e := sc_get_existing(bo.op);
                        if e != SCEV_CNC { array_add(*add_ops, e); break; }
                        rhs := sc_get_scev(bo.rhs);
                        flags := sc_get_no_wrap_flags_from_ub(bo.op);
                        if flags != SF_ANY {
                            lhs := sc_get_scev(bo.lhs);
                            if bo.opcode == .SUB array_add(*add_ops, sc_get_minus(lhs, rhs, flags));
                            else array_add(*add_ops, sc_get_add2(lhs, rhs, flags));
                            break;
                        }
                    }
                    if bo.opcode == .SUB array_add(*add_ops, sc_get_negative(sc_get_scev(bo.rhs)));
                    else array_add(*add_ops, sc_get_scev(bo.rhs));
                    ok2, new_bo := match_binary_op(bo.lhs, cxt);
                    if !ok2 || (new_bo.opcode != .ADD && new_bo.opcode != .SUB) {
                        array_add(*add_ops, sc_get_scev(bo.lhs));
                        break;
                    }
                    bo = new_bo;
                }
                return sc_get_add(*add_ops);
            case .MUL;
                mul_ops: [..] Scev_Id; mul_ops.allocator = temp;
                while true {
                    if bo.op != NONE {
                        e := sc_get_existing(bo.op);
                        if e != SCEV_CNC { array_add(*mul_ops, e); break; }
                        flags := sc_get_no_wrap_flags_from_ub(bo.op);
                        if flags != SF_ANY {
                            lhs := sc_get_scev(bo.lhs);
                            rhs := sc_get_scev(bo.rhs);
                            array_add(*mul_ops, sc_get_mul2(lhs, rhs, flags));
                            break;
                        }
                    }
                    array_add(*mul_ops, sc_get_scev(bo.rhs));
                    ok2, new_bo := match_binary_op(bo.lhs, cxt);
                    if !ok2 || new_bo.opcode != .MUL {
                        array_add(*mul_ops, sc_get_scev(bo.lhs));
                        break;
                    }
                    bo = new_bo;
                }
                return sc_get_mul(*mul_ops);
            case .UDIV;
                lhs := sc_get_scev(bo.lhs); rhs := sc_get_scev(bo.rhs);
                return sc_get_udiv(lhs, rhs);
            case .UREM;
                lhs := sc_get_scev(bo.lhs); rhs := sc_get_scev(bo.rhs);
                return sc_get_urem(lhs, rhs);
            case .SUB;
                flags := SF_ANY;
                if bo.op != NONE flags = sc_get_no_wrap_flags_from_ub(bo.op);
                lhs := sc_get_scev(bo.lhs); rhs := sc_get_scev(bo.rhs);
                return sc_get_minus(lhs, rhs, flags);
            case .AND;
                if is_const_int(bo.rhs) {
                    a := const_ap(bo.rhs);
                    if ap_is_zero(a) return sc_get_scev(bo.rhs);
                    if ap_is_all_ones(a) return sc_get_scev(bo.lhs);
                    lz := ap_clz(a); tz := ap_ctz(a);
                    bits := a.bits;
                    known := known_bits_ctx(bo.lhs, NONE, se.dt, se.ac);
                    effective_mask := ap_shl(ap_low_bits_set(bits, bits - lz - tz), tz);
                    if (lz != 0 || tz != 0) && ap_is_zero(ap_and(ap_and(ap_not(a), ap_not(known.zero)), effective_mask)) {
                        mul_count := sc_get_constant(ap_one_bit_set(bits, tz));
                        lhs := sc_get_scev(bo.lhs);
                        shifted_lhs: Scev_Id = SCEV_CNC;
                        if sc_is_mul(lhs) && sc_is_const(sc_op(lhs, 0)) {
                            opc := sc_ap(sc_op(lhs, 0));
                            mul_zeros := ap_ctz(opc);
                            gcd := min(mul_zeros, tz);
                            div_amt := ap_one_bit_set(bits, tz - gcd);
                            mul_ops := sc_operands(lhs);
                            mul_ops[0] = sc_get_constant(ap_ashr(opc, gcd));
                            new_mul := sc_get_mul(*mul_ops, sc_flags(lhs));
                            shifted_lhs = sc_get_udiv(new_mul, sc_get_constant(div_amt));
                        }
                        if shifted_lhs == SCEV_CNC shifted_lhs = sc_get_udiv(lhs, mul_count);
                        return sc_get_mul2(sc_get_zero_extend(sc_get_truncate(shifted_lhs, type_int(bits - lz - tz)), vtype(bo.lhs)), mul_count);
                    }
                }
                if is_int_type_bits(vtype(bo.lhs), 1) {
                    lhs := sc_get_scev(bo.lhs); rhs := sc_get_scev(bo.rhs);
                    return sc_get_umin2(lhs, rhs);
                }
            case .OR;
                if is_int_type_bits(vtype(bo.lhs), 1) {
                    lhs := sc_get_scev(bo.lhs); rhs := sc_get_scev(bo.rhs);
                    return sc_get_umax2(lhs, rhs);
                }
            case .XOR;
                if is_const_int(bo.rhs) {
                    ca := const_ap(bo.rhs);
                    if ap_is_all_ones(ca) return sc_get_not(sc_get_scev(bo.lhs));
                    lbo := bo.lhs;
                    if is_binary_operator(lbo) && is_const_int(op(lbo, 1)) && inst_op(lbo) == .AND && ap_eq(const_ap(op(lbo, 1)), ca) {
                        z := sc_get_scev(bo.lhs);
                        if sc_is_zext(z) {
                            uty := vtype(bo.lhs);
                            z0 := sc_op(z, 0);
                            z0_size := sc_bits(z0);
                            if ap_is_mask_n(ca, z0_size) return sc_get_zero_extend(sc_get_not(z0), uty);
                            tr := ap_trunc(ca, z0_size);
                            if ap_eq(ap_zext(tr, sc_type_bits(uty)), ca) && ap_is_sign_mask(tr)
                                return sc_get_zero_extend(sc_get_add2(z0, sc_get_constant(tr)), uty);
                        }
                    }
                }
            case .SHL;
                if is_const_int(bo.rhs) {
                    sa := const_ap(bo.rhs);
                    bits := sa.bits;
                    if !ap_uge_u64(sa, cast(u64) bits) {
                        flags := SF_ANY;
                        if bo.op != NONE {
                            mul_flags := sc_get_no_wrap_flags_from_ub(bo.op);
                            if (mul_flags & SF_NSW) && ((mul_flags & SF_NUW) || ap_ult_u64(sa, cast(u64) (bits - 1))) flags |= SF_NSW;
                            if mul_flags & SF_NUW flags |= SF_NUW;
                        }
                        x := sc_get_constant(ap_one_bit_set(bits, cast(u32) ap_zext_value(sa)));
                        return sc_get_mul2(sc_get_scev(bo.lhs), x, flags);
                    }
                }
            case .ASHR;
                for 0..0 {
                    ci := bo.rhs;
                    if !is_const_int(ci) break;
                    outer_ty := vtype(bo.lhs);
                    bits := sc_type_bits(outer_ty);
                    cia := const_ap(ci);
                    if ap_uge_u64(cia, cast(u64) bits) break;
                    if ap_is_zero(cia) return sc_get_scev(bo.lhs);
                    ashr_amt := cast(u32) ap_zext_value(cia);
                    trunc_ty := type_int(bits - ashr_amt);
                    l := bo.lhs;
                    lk := vkind(l);
                    is_opr := lk == .INST || lk == .C_EXPR;
                    add_truncate_expr: Scev_Id = SCEV_CNC;
                    shl_amt_ci: Value_Id = NONE;
                    add_constant: Scev_Id = SCEV_CNC;
                    if is_opr && opr_code(l) == .ADD {
                        lshift := op(l, 0);
                        add_operand_ci := op(l, 1);
                        lsk := vkind(lshift);
                        if (lsk == .INST || lsk == .C_EXPR) && opr_code(lshift) == .SHL {
                            if is_const_int(add_operand_ci) {
                                shl_op0 := sc_get_scev(op(lshift, 0));
                                if is_const_int(op(lshift, 1)) shl_amt_ci = op(lshift, 1);
                                add_operand := ap_ashr(const_ap(add_operand_ci), ashr_amt);
                                add_constant = sc_get_constant(ap_trunc(add_operand, bits - ashr_amt));
                                add_truncate_expr = sc_get_truncate(shl_op0, trunc_ty);
                            }
                        }
                    } else if is_opr && opr_code(l) == .SHL {
                        shl_op0 := sc_get_scev(op(l, 0));
                        if is_const_int(op(l, 1)) shl_amt_ci = op(l, 1);
                        add_truncate_expr = sc_get_truncate(shl_op0, trunc_ty);
                    }
                    if add_truncate_expr != SCEV_CNC && shl_amt_ci != NONE {
                        shl_amt := const_ap(shl_amt_ci);
                        if ap_ult_u64(shl_amt, cast(u64) bits) && ap_uge_u64(shl_amt, cast(u64) ashr_amt) {
                            mul := ap_one_bit_set(bits - ashr_amt, cast(u32) ap_zext_value(shl_amt) - ashr_amt);
                            composite := sc_get_mul2(add_truncate_expr, sc_get_constant(mul));
                            if opr_code(l) != .SHL composite = sc_get_add2(composite, add_constant);
                            return sc_get_sign_extend(composite, outer_ty);
                        }
                    }
                }
        }
    }

    opc := opr_code(v);
    if opc == {
        case .TRUNC; return sc_get_truncate(sc_get_scev(op(v, 0)), vtype(v));
        case .ZEXT; return sc_get_zero_extend(sc_get_scev(op(v, 0)), vtype(v));
        case .SEXT;
            ok2, bo2 := match_binary_op(op(v, 0), cxt);
            if ok2 && bo2.opcode == .SUB && bo2.is_nsw {
                ty := vtype(v);
                v1 := sc_get_sign_extend(sc_get_scev(bo2.lhs), ty);
                v2 := sc_get_sign_extend(sc_get_scev(bo2.rhs), ty);
                return sc_get_minus(v1, v2, SF_NSW);
            }
            return sc_get_sign_extend(sc_get_scev(op(v, 0)), vtype(v));
        case .BITCAST;
            if sc_is_scevable(vtype(v)) && sc_is_scevable(vtype(op(v, 0))) return sc_get_scev(op(v, 0));
        case .PTRTOADDR;
            int_op := sc_get_ptr_to_addr(sc_get_scev(op(v, 0)));
            if int_op == SCEV_CNC return sc_get_unknown(v);
            return int_op;
        case .PTRTOINT;
            o := sc_get_scev(op(v, 0));
            int_op := sc_get_ptr_to_int(o, vtype(v));
            if int_op == SCEV_CNC return sc_get_unknown(v);
            return int_op;
        case .INTTOPTR; return sc_get_unknown(v);
        case .SDIV;
            if sc_is_known_non_negative(sc_get_scev(op(v, 0))) && sc_is_known_non_negative(sc_get_scev(op(v, 1)))
                return sc_get_udiv(sc_get_scev(op(v, 0)), sc_get_scev(op(v, 1)));
        case .SREM;
            if sc_is_known_non_negative(sc_get_scev(op(v, 0))) && sc_is_known_non_negative(sc_get_scev(op(v, 1)))
                return sc_get_urem(sc_get_scev(op(v, 0)), sc_get_scev(op(v, 1)));
        case .GEP; return sc_create_node_for_gep(v);
        case .PHI; return sc_create_node_for_phi(v);
        case .SELECT; return sc_create_node_for_select_or_phi(v, op(v, 0), op(v, 1), op(v, 2));
        case .CALL; #through;
        case .INVOKE;
            rv := call_returned_arg(v);
            if rv != NONE return sc_get_scev(rv);
            id := call_iid(v);
            if id == IID_ABS return sc_get_abs(sc_get_scev(op(v, 0)), ap_is_one(const_ap(op(v, 1))));
            if id == IID_UMAX { l := sc_get_scev(op(v, 0)); r := sc_get_scev(op(v, 1)); return sc_get_umax2(l, r); }
            if id == IID_UMIN { l := sc_get_scev(op(v, 0)); r := sc_get_scev(op(v, 1)); return sc_get_umin2(l, r); }
            if id == IID_SMAX { l := sc_get_scev(op(v, 0)); r := sc_get_scev(op(v, 1)); return sc_get_smax2(l, r); }
            if id == IID_SMIN { l := sc_get_scev(op(v, 0)); r := sc_get_scev(op(v, 1)); return sc_get_smin2(l, r); }
            if id == IID_USUB_SAT {
                x := sc_get_scev(op(v, 0)); y := sc_get_scev(op(v, 1));
                clamped_y := sc_get_umin2(x, y);
                return sc_get_minus(x, clamped_y, SF_NUW);
            }
            if id == IID_UADD_SAT {
                x := sc_get_scev(op(v, 0)); y := sc_get_scev(op(v, 1));
                clamped_x := sc_get_umin2(x, sc_get_not(y));
                return sc_get_add2(clamped_x, y, SF_NUW);
            }
            if id == IID_START_LOOP_ITERATIONS || id == IID_ANNOTATION || id == IID_PTR_ANNOTATION return sc_get_scev(op(v, 0));
            if id == IID_VSCALE return sc_get_vscale(vtype(v));
    }
    return sc_get_unknown(v);
}

// getNoWrapFlagsFromUB
sc_get_no_wrap_flags_from_ub :: (v: Value_Id) -> u8 {
    if vkind(v) == .C_EXPR return SF_ANY;
    flags := SF_ANY;
    f := opr_flags(v);
    if inst_op(v) == .OR && (f & F_EXACT) {
        flags = SF_NUW | SF_NSW;
    } else {
        if f & F_NUW flags |= SF_NUW;
        if f & F_NSW flags |= SF_NSW;
    }
    if flags == SF_ANY return SF_ANY;
    if sc_is_scev_expr_never_poison(v) return flags;
    return SF_ANY;
}

// getNonTrivialDefiningScopeBound
sc_get_non_trivial_defining_scope_bound :: (s: Scev_Id) -> Value_Id {
    if sc_is_addrec(s) return block(li_header(se.li, sc_loop(s))).first;
    if sc_is_unknown(s) && is_inst(sc_value(s)) return sc_value(s);
    return NONE;
}
// getDefiningScopeBound(Ops, Precise)
sc_get_defining_scope_bound :: (ops: [] Scev_Id) -> Value_Id {
    b, p := sc_get_defining_scope_bound_precise(ops);
    return b;
}
sc_get_defining_scope_bound_precise :: (ops: [] Scev_Id) -> (Value_Id, bool) {
    precise := true;
    visited: Table(Scev_Id, bool); visited.allocator = temp;
    work: [..] Scev_Id; work.allocator = temp;
    push_op :: (s: Scev_Id, visited: *Table(Scev_Id, bool), work: *[..] Scev_Id, precise: *bool) {
        if table_contains(visited, s) return;
        table_set(visited, s, true);
        if visited.count > 30 { precise.* = false; return; }
        array_add(work, s);
    }
    for ops push_op(it, *visited, *work, *precise);
    bound: Value_Id = NONE;
    while work.count > 0 {
        s := pop(*work);
        def_i := sc_get_non_trivial_defining_scope_bound(s);
        if def_i != NONE {
            if bound == NONE || dt_dominates_inst(se.dt, bound, def_i) bound = def_i;
        } else {
            k := sc_kind(s);
            if k != .CONSTANT && k != .VSCALE && k != .UNKNOWN
                for i: 0..cast(s64) sc_nops(s) - 1 push_op(sc_op(s, cast(u32) i), *visited, *work, *precise);
        }
    }
    if bound == NONE bound = block(fn_entry(se.fn)).first;
    return bound, precise;
}

// isGuaranteedToTransferExecutionTo(A, B)
sc_is_guaranteed_to_transfer_execution_to :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_block(a) == inst_block(b) && is_guaranteed_to_transfer_execution_range(a, b, 32) return true;
    b_loop := li_loop_for(se.li, inst_block(b));
    if b_loop != NONE && li_header(se.li, b_loop) == inst_block(b) && li_loop_preheader(se.li, b_loop) == inst_block(a) &&
       is_guaranteed_to_transfer_execution_range(a, NONE, 32) &&
       is_guaranteed_to_transfer_execution_range(block(inst_block(b)).first, b, 32)
        return true;
    return false;
}

// isGuaranteedNotToBePoison(const SCEV *)
sc_is_guaranteed_not_to_be_poison :: (s: Scev_Id) -> bool {
    pc: [..] Scev_Id; pc.allocator = temp;
    poison_collect(s, true, *pc);
    return pc.count == 0;
}
// isGuaranteedNotToCauseUB
sc_is_guaranteed_not_to_cause_ub :: (s: Scev_Id) -> bool { return !sc_expr_contains(s, .CONTAINS_UB_UDIV); }
// isGuaranteedNotToCauseUB's predicate: a udiv whose divisor may be zero or poison
sc_udiv_may_cause_ub :: (x: Scev_Id) -> bool {
    if !sc_is_udiv(x) return false;
    op1 := sc_op(x, 1);
    return !sc_is_known_non_zero(op1) || !sc_is_guaranteed_not_to_be_poison(op1);
}

// isSCEVExprNeverPoison
sc_is_scev_expr_never_poison :: (i: Value_Id) -> bool {
    if !program_undefined_if_poison(i) return false;
    scev_ops: [..] Scev_Id; scev_ops.allocator = temp;
    for k: 0..cast(s64) nops(i) - 1 {
        o := op(i, cast(u32) k);
        if sc_is_scevable(vtype(o)) array_add(*scev_ops, sc_get_scev(o));
    }
    def_i := sc_get_defining_scope_bound(scev_ops);
    return sc_is_guaranteed_to_transfer_execution_to(def_i, i);
}

// isAddRecNeverPoison
sc_is_add_rec_never_poison :: (i: Value_Id, l: Loop_Id) -> bool {
    if sc_is_scev_expr_never_poison(i) return true;
    exiting_bb := li_exiting_block(se.li, l);
    if exiting_bb == NONE || !sc_loop_has_no_abnormal_exits(l) return false;
    known_poison: Table(Value_Id, bool); known_poison.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    table_set(*known_poison, i, true);
    array_add(*work, i);
    while work.count > 0 {
        poison := pop(*work);
        u := ir.v_first_use[poison];
        while u != NONE {
            pu := ir.u_user[u];
            if must_trigger_ub(pu, *known_poison) && dt_dominates(se.dt, inst_block(pu), exiting_bb) return true;
            if propagates_poison(pu, cast(u32) (u - ir.v_ops[pu])) && li_contains(se.li, l, inst_block(pu)) {
                if !table_contains(*known_poison, pu) { table_set(*known_poison, pu, true); array_add(*work, pu); }
            }
            u = ir.u_next[u];
        }
    }
    return false;
}

// getLoopProperties
sc_get_loop_properties :: (l: Loop_Id) -> Loop_Properties {
    found, lp := table_find(*se.loop_props, l);
    if found return lp;
    has_side_effects :: (i: Value_Id) -> bool {
        if inst_op(i) == .STORE return !inst_is_simple(i);
        if may_throw(i) return true;
        if inst_op(i) == .CALL && is_mem_intrinsic_call(i) && !is_volatile(i) return false;
        return may_write_to_memory(i);
    }
    r: Loop_Properties;
    r.has_no_abnormal_exits = true;
    r.has_no_side_effects = true;
    for bb: li_blocks(se.li, l) {
        for i: block_insts(bb) {
            if !is_guaranteed_to_transfer_execution(i) r.has_no_abnormal_exits = false;
            if has_side_effects(i) r.has_no_side_effects = false;
            if !r.has_no_abnormal_exits && !r.has_no_side_effects break;
        }
    }
    table_set(*se.loop_props, l, r);
    return r;
}
sc_loop_has_no_abnormal_exits :: (l: Loop_Id) -> bool { return sc_get_loop_properties(l).has_no_abnormal_exits; }
sc_loop_has_no_side_effects :: (l: Loop_Id) -> bool { return sc_get_loop_properties(l).has_no_side_effects; }

// ---------------------------------------------------------------- PHIs

// getLoop for a header PHI: isIntegerLoopHeaderPHI
is_integer_loop_header_phi :: (pn: Value_Id) -> Loop_Id {
    if type_kind(vtype(pn)) != .INT return NONE;
    l := li_loop_for(se.li, inst_block(pn));
    if l == NONE || li_header(se.li, l) != inst_block(pn) return NONE;
    return l;
}

// createSimpleAffineAddRec (SCEV_CNC = nullptr)
sc_create_simple_affine_add_rec :: (pn: Value_Id, be_value_v: Value_Id, start_value_v: Value_Id) -> Scev_Id {
    l := li_loop_for(se.li, inst_block(pn));
    ok, bo := match_binary_op(be_value_v, pn);
    if !ok return SCEV_CNC;
    if bo.opcode != .ADD return SCEV_CNC;
    accum: Scev_Id = SCEV_CNC;
    if bo.lhs == pn && li_is_loop_invariant(se.li, l, bo.rhs) accum = sc_get_scev(bo.rhs);
    else if bo.rhs == pn && li_is_loop_invariant(se.li, l, bo.lhs) accum = sc_get_scev(bo.lhs);
    if accum == SCEV_CNC return SCEV_CNC;
    flags := SF_ANY;
    if bo.is_nuw flags = set_flags(flags, SF_NUW);
    if bo.is_nsw flags = set_flags(flags, SF_NSW);
    start_val := sc_get_scev(start_value_v);
    phi_scev := sc_get_add_rec(start_val, accum, l, flags);
    sc_insert_value_to_map(pn, phi_scev);
    if sc_is_addrec(phi_scev) sc_infer_no_wrap_via_constant_ranges(phi_scev);
    if is_inst(be_value_v) {
        if sc_is_add_rec_never_poison(be_value_v, l) sc_get_add_rec(sc_get_add2(start_val, accum), accum, l, flags);
    }
    return phi_scev;
}

// createAddRecFromPHI (SCEV_CNC = nullptr)
sc_create_add_rec_from_phi :: (pn: Value_Id) -> Scev_Id {
    l := li_loop_for(se.li, inst_block(pn));
    if l == NONE || li_header(se.li, l) != inst_block(pn) return SCEV_CNC;
    be_value_v: Value_Id = NONE;
    start_value_v: Value_Id = NONE;
    n := nops(pn);
    for i: 0..cast(s64) n - 1 {
        v := phi_value(pn, cast(u32) i);
        if li_contains(se.li, l, phi_block(pn, cast(u32) i)) {
            if be_value_v == NONE be_value_v = v;
            else if be_value_v != v { be_value_v = NONE; break; }
        } else if start_value_v == NONE start_value_v = v;
        else if start_value_v != v { start_value_v = NONE; break; }
    }
    if be_value_v == NONE || start_value_v == NONE return SCEV_CNC;

    {
        s := sc_create_simple_affine_add_rec(pn, be_value_v, start_value_v);
        if s != SCEV_CNC return s;
    }

    symbolic_name := sc_get_unknown(pn);
    sc_insert_value_to_map(pn, symbolic_name);
    be_value := sc_get_scev(be_value_v);

    if sc_is_add(be_value) {
        add := be_value;
        an := sc_nops(add);
        found_index := an;
        for i: 0..cast(s64) an - 1 if sc_op(add, cast(u32) i) == symbolic_name { found_index = cast(u32) i; break; }
        if found_index != an {
            ops: [..] Scev_Id; ops.allocator = temp;
            for i: 0..cast(s64) an - 1 if cast(u32) i != found_index array_add(*ops, scev_backedge_condition_fold(sc_op(add, cast(u32) i), l));
            accum := sc_get_add(*ops);
            if sc_is_loop_invariant(accum, l) || (sc_is_addrec(accum) && sc_loop(accum) == l) {
                flags := SF_ANY;
                okb, bo := match_binary_op(be_value_v, pn);
                if okb {
                    if bo.opcode == .ADD && bo.lhs == pn {
                        if bo.is_nuw flags = set_flags(flags, SF_NUW);
                        if bo.is_nsw flags = set_flags(flags, SF_NSW);
                    }
                } else if opr_code(be_value_v) == .GEP {
                    if op(be_value_v, 0) == pn {
                        nw := opr_flags(be_value_v) & (F_INBOUNDS | F_NUSW | F_GEP_NUW);
                        if nw != 0 flags = set_flags(flags, SF_NW);
                        if (nw & F_GEP_NUW) || ((nw & (F_NUSW | F_INBOUNDS)) && sc_is_known_non_negative(accum))
                            flags = set_flags(flags, SF_NUW);
                    }
                }
                start_val := sc_get_scev(start_value_v);
                phi_scev := sc_get_add_rec(start_val, accum, l, flags);
                sc_forget_memoized_results(.[symbolic_name]);
                sc_insert_value_to_map(pn, phi_scev);
                if sc_is_addrec(phi_scev) sc_infer_no_wrap_via_constant_ranges(phi_scev);
                if is_inst(be_value_v) {
                    if sc_is_loop_invariant(accum, l) && sc_is_add_rec_never_poison(be_value_v, l)
                        sc_get_add_rec(sc_get_add2(start_val, accum), accum, l, flags);
                }
                return phi_scev;
            }
        }
    } else {
        shifted := scev_shift_rewrite(be_value, l);
        start := scev_init_rewrite(shifted, l, false);
        if shifted != SCEV_CNC && start != SCEV_CNC && sc_is_guaranteed_not_to_cause_ub(shifted) && sc_implies_poison(shifted, start) {
            start_val := sc_get_scev(start_value_v);
            if start == start_val {
                sc_forget_memoized_results(.[symbolic_name]);
                sc_insert_value_to_map(pn, shifted);
                return shifted;
            }
        }
    }
    sc_erase_value_from_map(pn);
    return SCEV_CNC;
}

// BrPHIToSelect
br_phi_to_select :: (bi: Value_Id, merge: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    c := op(bi, 0);
    bb := inst_block(bi);
    s0 := get_successor(bi, 0);
    s1 := get_successor(bi, 1);
    left_use := op_use(merge, 0);
    right_use := op_use(merge, 1);
    if dt_dominates_edge_use(se.dt, bb, s0, left_use) && dt_dominates_edge_use(se.dt, bb, s1, right_use)
        return true, c, op(merge, 0), op(merge, 1);
    if dt_dominates_edge_use(se.dt, bb, s0, right_use) && dt_dominates_edge_use(se.dt, bb, s1, left_use)
        return true, c, op(merge, 1), op(merge, 0);
    return false, NONE, NONE, NONE;
}
// getOperandsForSelectLikePHI
get_operands_for_select_like_phi :: (pn: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    if nops(pn) == 2 {
        for i: 0..1 if !dt_is_reachable_from_entry(se.dt, phi_block(pn, cast(u32) i)) return false, NONE, NONE, NONE;
        idom := dt_idom_block(se.dt, inst_block(pn));
        t := block_terminator(idom);
        if t == NONE || inst_op(t) != .CONDBR return false, NONE, NONE, NONE;
        ok, c, l, r := br_phi_to_select(t, pn);
    return ok, c, l, r;
    }
    return false, NONE, NONE, NONE;
}
// createNodeFromSelectLikePHI
sc_create_node_from_select_like_phi :: (pn: Value_Id) -> Scev_Id {
    ok, cond, lhs, rhs := get_operands_for_select_like_phi(pn);
    if ok && sc_properly_dominates(sc_get_scev(lhs), inst_block(pn)) && sc_properly_dominates(sc_get_scev(rhs), inst_block(pn))
        return sc_create_node_for_select_or_phi(pn, cond, lhs, rhs);
    return SCEV_CNC;
}
// getCommonInstForPHI (NONE = nullptr)
get_common_inst_for_phi :: (pn: Value_Id) -> Value_Id {
    common: Value_Id = NONE;
    for i: 0..cast(s64) nops(pn) - 1 {
        inc := phi_value(pn, cast(u32) i);
        if !is_binary_operator(inc) return NONE;
        if common != NONE {
            // isIdenticalToWhenDefined: same opcode, type and operands (flags ignored)
            if inst_op(common) != inst_op(inc) || vtype(common) != vtype(inc) || op(common, 0) != op(inc, 0) || op(common, 1) != op(inc, 1)
                return NONE;
        } else common = inc;
    }
    return common;
}
// createNodeForPHIWithIdenticalOperands
sc_create_node_for_phi_with_identical_operands :: (pn: Value_Id) -> Scev_Id {
    common := get_common_inst_for_phi(pn);
    if common == NONE return SCEV_CNC;
    common_scev := sc_get_scev(common);
    for i: 1..cast(s64) nops(pn) - 1 if common_scev != sc_get_scev(phi_value(pn, cast(u32) i)) return SCEV_CNC;
    return common_scev;
}
// createNodeForPHI
sc_create_node_for_phi :: (pn: Value_Id) -> Scev_Id {
    s := sc_create_add_rec_from_phi(pn);
    if s != SCEV_CNC return s;
    v := simplify_instruction(pn, scev_simplify_query());
    if v != NONE return sc_get_scev(v);
    s = sc_create_node_for_phi_with_identical_operands(pn);
    if s != SCEV_CNC return s;
    s = sc_create_node_from_select_like_phi(pn);
    if s != SCEV_CNC return s;
    return sc_get_unknown(pn);
}

// RangeRefPHIAllowedOperands
range_ref_phi_allowed_operands :: (phi: Value_Id) -> bool {
    ok, c, l, r := get_operands_for_select_like_phi(phi);
    if ok return true;
    for i: 0..cast(s64) nops(phi) - 1 if !dt_dominates_inst(se.dt, op(phi, cast(u32) i), phi) return false;
    return true;
}

// ---------------------------------------------------------------- selects

// SCEVMinMaxExprContains
sc_vis_min_max_contains_follow :: (v: *Sc_Visitor, s: Scev_Id) -> bool {
    v.found = s == v.operand;
    k := sc_kind(s);
    return !v.found && (k == v.root_kind || k == .UMIN || k == .ZEXT);
}
scev_min_max_expr_contains :: (root: Scev_Id, operand: Scev_Id, root_kind: Scev_Kind) -> bool {
    v: Sc_Visitor;
    v.kind = .MIN_MAX_CONTAINS;
    v.operand = operand;
    v.root_kind = root_kind;
    sc_visit_all(root, *v);
    return v.found;
}

// createNodeForSelectOrPHIInstWithICmpInstCond (SCEV_CNC = std::nullopt)
sc_create_node_for_select_icmp :: (ty: Type_Id, ici: Value_Id, true_val_in: Value_Id, false_val_in: Value_Id) -> Scev_Id {
    lhs := op(ici, 0);
    rhs := op(ici, 1);
    true_val := true_val_in;
    false_val := false_val_in;
    pred := inst_pred(ici);
    if pred == ICMP_SLT || pred == ICMP_SLE || pred == ICMP_ULT || pred == ICMP_ULE || pred == ICMP_SGT || pred == ICMP_SGE ||
       pred == ICMP_UGT || pred == ICMP_UGE {
        if pred == ICMP_SLT || pred == ICMP_SLE || pred == ICMP_ULT || pred == ICMP_ULE { t := lhs; lhs = rhs; rhs = t; }
        if sc_type_bits(vtype(lhs)) <= sc_type_bits(ty) {
            signed := icmp_is_signed(pred);
            la := sc_get_scev(true_val);
            ra := sc_get_scev(false_val);
            ls := sc_get_scev(lhs);
            rs := sc_get_scev(rhs);
            if sc_is_ptr(la) {
                if la == ls && ra == rs { if signed return sc_get_smax2(ls, rs); return sc_get_umax2(ls, rs); }
                if la == rs && ra == ls { if signed return sc_get_smin2(ls, rs); return sc_get_umin2(ls, rs); }
            }
            coerce :: (o_in: Scev_Id, signed: bool, ty: Type_Id) -> Scev_Id {
                o := o_in;
                if sc_is_ptr(o) {
                    o = sc_get_lossless_ptr_to_int(o);
                    if o == SCEV_CNC return o;
                }
                if signed return sc_get_noop_or_sign_extend(o, ty);
                return sc_get_noop_or_zero_extend(o, ty);
            }
            ls = coerce(ls, signed, ty);
            rs = coerce(rs, signed, ty);
            if ls == SCEV_CNC || rs == SCEV_CNC return SCEV_CNC;
            ldiff := sc_get_minus(la, ls);
            rdiff := sc_get_minus(ra, rs);
            if ldiff == rdiff return sc_get_add2(ifx signed then sc_get_smax2(ls, rs) else sc_get_umax2(ls, rs), ldiff);
            ldiff = sc_get_minus(la, rs);
            rdiff = sc_get_minus(ra, ls);
            if ldiff == rdiff return sc_get_add2(ifx signed then sc_get_smin2(ls, rs) else sc_get_umin2(ls, rs), ldiff);
        }
        return SCEV_CNC;
    }
    if pred == ICMP_NE || pred == ICMP_EQ {
        if pred == ICMP_NE { t := true_val; true_val = false_val; false_val = t; }
        if sc_type_bits(vtype(lhs)) <= sc_type_bits(ty) && is_const_int(rhs) && ap_is_zero(const_ap(rhs)) {
            x := sc_get_noop_or_zero_extend(sc_get_scev(lhs), ty);
            true_val_expr := sc_get_scev(true_val);
            false_val_expr := sc_get_scev(false_val);
            y := sc_get_minus(false_val_expr, x);
            c := sc_get_minus(true_val_expr, y);
            if sc_is_const(c) && ap_ule_u64(sc_ap(c), 1) return sc_get_add2(sc_get_umax2(x, c), y);
        }
        if is_const_int(rhs) && ap_is_zero(const_ap(rhs)) && is_const_int(true_val) && ap_is_zero(const_ap(true_val)) {
            x := sc_get_scev(lhs);
            while sc_is_zext(x) x = sc_op(x, 0);
            if sc_bits(x) <= sc_type_bits(ty) {
                false_val_expr := sc_get_scev(false_val);
                if scev_min_max_expr_contains(false_val_expr, x, .SEQ_UMIN)
                    return sc_get_umin2(sc_get_noop_or_zero_extend(x, ty), false_val_expr, true);
            }
        }
    }
    return SCEV_CNC;
}

// createNodeForSelectViaUMinSeq(SE, CondExpr, TrueExpr, FalseExpr)
create_node_for_select_via_umin_seq_exprs :: (cond_expr_in: Scev_Id, true_expr: Scev_Id, false_expr: Scev_Id) -> Scev_Id {
    cond_expr := cond_expr_in;
    if !sc_is_const(true_expr) && !sc_is_const(false_expr) return SCEV_CNC;
    x, c: Scev_Id;
    if sc_is_const(true_expr) {
        cond_expr = sc_get_not(cond_expr);
        x = false_expr; c = true_expr;
    } else {
        x = true_expr; c = false_expr;
    }
    return sc_get_add2(c, sc_get_umin2(cond_expr, sc_get_minus(x, c), true));
}
sc_create_node_for_select_or_phi_via_umin_seq :: (v: Value_Id, cond: Value_Id, true_val: Value_Id, false_val: Value_Id) -> Scev_Id {
    if !is_int_type_bits(vtype(v), 1) return sc_get_unknown(v);
    if is_const_int(true_val) || is_const_int(false_val) {
        sc_cond := sc_get_scev(cond);
        sc_true := sc_get_scev(true_val);
        sc_false := sc_get_scev(false_val);
        s := create_node_for_select_via_umin_seq_exprs(sc_cond, sc_true, sc_false);
        if s != SCEV_CNC return s;
    }
    return sc_get_unknown(v);
}
// createNodeForSelectOrPHI
sc_create_node_for_select_or_phi :: (v: Value_Id, cond: Value_Id, true_val: Value_Id, false_val: Value_Id) -> Scev_Id {
    if is_const_int(cond) return sc_get_scev(ifx ap_is_one(const_ap(cond)) then true_val else false_val);
    if is_inst(v) {
        if is_inst(cond) && inst_op(cond) == .ICMP {
            s := sc_create_node_for_select_icmp(vtype(v), cond, true_val, false_val);
            if s != SCEV_CNC return s;
        }
    }
    return sc_create_node_for_select_or_phi_via_umin_seq(v, cond, true_val, false_val);
}

// createNodeForGEP / getGEPExpr(GEPOperator *, IndexExprs)
sc_create_node_for_gep :: (gep: Value_Id) -> Scev_Id {
    index_exprs: [..] Scev_Id; index_exprs.allocator = temp;
    index_values: [..] Value_Id; index_values.allocator = temp;
    for i: 1..cast(s64) nops(gep) - 1 {
        array_add(*index_exprs, sc_get_scev(op(gep, cast(u32) i)));
        array_add(*index_values, op(gep, cast(u32) i));
    }
    base_expr := sc_get_scev(op(gep, 0));
    nw := opr_flags(gep) & (F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if nw != 0 {
        if !is_inst(gep) || !sc_is_scev_expr_never_poison(gep) nw = 0;
    }
    return sc_get_gep(base_expr, index_exprs, opr_gep_source_type(gep), nw, index_values);
}
