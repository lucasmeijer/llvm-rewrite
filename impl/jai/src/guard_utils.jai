// Guards and widenable conditions: port of llvm/lib/Analysis/GuardUtils.cpp (isGuard, isWidenableCondition,
// isWidenableBranch, isGuardAsWidenableBranch, parseWidenableBranch, parseWidenableGuard,
// extractWidenableCondition) and of widenWidenableBranch / setWidenableBranchCond from
// llvm/lib/Transforms/Utils/GuardUtils.cpp (makeGuardControlFlowExplicit is in pass_make_guards_explicit.jai), plus
// the small passes llvm/lib/Transforms/Scalar/LowerGuardIntrinsic.cpp and
// llvm/lib/Transforms/Scalar/LowerWidenableCondition.cpp.

// match(V, m_Intrinsic<ID>()): a CallInst whose callee is the intrinsic
gu_is_intrinsic_call :: (v: Value_Id, id: Intrinsic_Id) -> bool {
    return v != NONE && is_inst(v) && inst_op(v) == .CALL && call_iid(v) == id;
}
gu_is_guard :: (u: Value_Id) -> bool { return gu_is_intrinsic_call(u, IID_EXPERIMENTAL_GUARD); }
gu_is_widenable_condition :: (v: Value_Id) -> bool { return gu_is_intrinsic_call(v, IID_EXPERIMENTAL_WIDENABLE_CONDITION); }

// match(V, m_And(m_Value(A), m_Value(B))): a binary `and` instruction
gu_match_and :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
    if v == NONE || !is_inst(v) || inst_op(v) != .AND return false, NONE, NONE;
    return true, op(v, 0), op(v, 1);
}

// parseWidenableBranch(User *U, Use *&C, Use *&WC, IfTrueBB, IfFalseBB): uses as (user, operand number);
// c_user == NONE means no C
Gu_Widenable_Branch :: struct {
    c_user: Value_Id = NONE; c_op: u32;
    wc_user: Value_Id = NONE; wc_op: u32;
    if_true: Value_Id = NONE; if_false: Value_Id = NONE;
}
gu_parse_widenable_branch :: (u: Value_Id) -> (bool, Gu_Widenable_Branch) {
    r: Gu_Widenable_Branch;
    if u == NONE || !is_inst(u) || inst_op(u) != .CONDBR return false, r;
    cond := op(u, 0);
    if !has_one_use(cond) return false, r;
    r.if_true = get_successor(u, 0);
    r.if_false = get_successor(u, 1);
    if gu_is_widenable_condition(cond) {
        r.wc_user = u; r.wc_op = 0;
        return true, r;
    }
    ok, a, b := gu_match_and(cond);
    if !ok return false, r;
    if gu_is_widenable_condition(a) && has_one_use(a) {
        r.wc_user = cond; r.wc_op = 0;
        r.c_user = cond; r.c_op = 1;
        return true, r;
    }
    if gu_is_widenable_condition(b) && has_one_use(b) {
        r.wc_user = cond; r.wc_op = 1;
        r.c_user = cond; r.c_op = 0;
        return true, r;
    }
    return false, r;
}
// parseWidenableBranch(const User *U, Value *&Condition, Value *&WidenableCondition, ...)
gu_parse_widenable_branch_values :: (u: Value_Id) -> (bool, cond: Value_Id, wc: Value_Id, if_true: Value_Id, if_false: Value_Id) {
    ok, r := gu_parse_widenable_branch(u);
    if !ok return false, NONE, NONE, NONE, NONE;
    c := ifx r.c_user != NONE then op(r.c_user, r.c_op) else const_int(type_int(1), 1);
    return true, c, op(r.wc_user, r.wc_op), r.if_true, r.if_false;
}

gu_is_widenable_branch :: (u: Value_Id) -> bool {
    ok := gu_parse_widenable_branch(u);
    return ok;
}

gu_is_guard_as_widenable_branch :: (u: Value_Id) -> bool {
    if !gu_is_widenable_branch(u) return false;
    deopt_bb := get_successor(u, 1);
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, deopt_bb);
    while true {
        for insn: block_insts(deopt_bb) {
            if gu_is_intrinsic_call(insn, IID_EXPERIMENTAL_DEOPTIMIZE) return true;
            if may_have_side_effects(insn) return false;
        }
        deopt_bb = block_unique_successor(deopt_bb);
        if deopt_bb == NONE return false;
        seen := false;
        for visited if it == deopt_bb { seen = true; break; }
        if seen break;
        array_add(*visited, deopt_bb);
    }
    return false;
}

// parseCondition(Condition, RecordCheckOrWidenableCond); the callback kind: 0 = parseWidenableGuard (collect the
// non-WC checks), 1 = extractWidenableCondition (stop at the first single-use WC)
gu_parse_condition :: (condition: Value_Id, kind: u8, checks: *[..] Value_Id) -> Value_Id {
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*worklist, condition);
    array_add(*visited, condition);
    seen :: (vs: *[..] Value_Id, v: Value_Id) -> bool { for vs.* if it == v return true; array_add(vs, v); return false; }
    while true {
        check := pop(*worklist);
        ok, lhs, rhs := gu_match_and(check);
        if ok {
            if !seen(*visited, lhs) array_add(*worklist, lhs);
            if !seen(*visited, rhs) array_add(*worklist, rhs);
        } else if kind == 0 {
            if !gu_is_widenable_condition(check) array_add(checks, check);
        } else {
            if gu_is_widenable_condition(check) && has_one_use(check) return check;
        }
        if worklist.count == 0 break;
    }
    return NONE;
}

// parseWidenableGuard(U, Checks)
gu_parse_widenable_guard :: (u: Value_Id, checks: *[..] Value_Id) {
    condition := ifx gu_is_guard(u) then call_arg(u, 0) else op(u, 0);
    gu_parse_condition(condition, 0, checks);
}

// extractWidenableCondition(U)
gu_extract_widenable_condition :: (u: Value_Id) -> Value_Id {
    if u == NONE || !is_inst(u) || inst_op(u) != .CONDBR return NONE;
    condition := op(u, 0);
    if !has_one_use(condition) return NONE;
    return gu_parse_condition(condition, 1, null);
}

// IRBuilder::CreateAnd(LHS, RHS, Name): only ConstantFolder::FoldBinOp (both constant); `and X, true` is not folded
gu_irb_and :: (b: *Irb, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    return irb_binop(b, .AND, l, r, name);
}
// IRBuilder::CreateAnd(ArrayRef<Value *> Ops)
gu_irb_and_list :: (b: *Irb, ops: [] Value_Id) -> Value_Id {
    accum := ops[0];
    for i: 1..ops.count - 1 accum = gu_irb_and(b, accum, ops[i]);
    return accum;
}

// widenWidenableBranch(WidenableBR, NewCond)
gu_widen_widenable_branch :: (br: Value_Id, new_cond: Value_Id) {
    _, r := gu_parse_widenable_branch(br);
    b: Irb; irb_set_before(*b, br);
    if r.c_user == NONE {
        set_op(br, 0, gu_irb_and(*b, new_cond, op(r.wc_user, r.wc_op)));
    } else {
        set_op(r.c_user, r.c_op, gu_irb_and(*b, new_cond, op(r.c_user, r.c_op)));
        wc_and := op(br, 0);
        inst_move_before_dbg(wc_and, br);   // moveBefore(WidenableBR->getIterator())
    }
}
// setWidenableBranchCond(WidenableBR, NewCond)
gu_set_widenable_branch_cond :: (br: Value_Id, new_cond: Value_Id) {
    _, r := gu_parse_widenable_branch(br);
    if r.c_user == NONE {
        b: Irb; irb_set_before(*b, br);
        set_op(br, 0, gu_irb_and(*b, new_cond, op(r.wc_user, r.wc_op)));
    } else {
        wc_and := op(br, 0);
        inst_move_before_dbg(wc_and, br);   // moveBefore(WidenableBR->getIterator())
        set_op(r.c_user, r.c_op, new_cond);
    }
}

// The users of `v` in use-list order (Value::users())
gu_users :: (v: Value_Id, out: *[..] Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE { array_add(out, ir.u_user[u]); u = ir.u_next[u]; }
}

// LowerGuardIntrinsicPass::run
lower_guard_intrinsic_run :: (f: Value_Id) -> Preserved {
    guard_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_GUARD);
    if guard_decl == NONE || !has_uses(guard_decl) return PRESERVE_ALL;
    users: [..] Value_Id; users.allocator = temp;
    gu_users(guard_decl, *users);
    to_lower: [..] Value_Id; to_lower.allocator = temp;
    for users if is_inst(it) && inst_op(it) == .CALL && inst_fn(it) == f array_add(*to_lower, it);
    if to_lower.count == 0 return PRESERVE_ALL;
    deopt_fn := get_or_insert_intrinsic_declaration(IID_EXPERIMENTAL_DEOPTIMIZE, .[func_ret(glob(f).value_type)]);
    glob(deopt_fn).cc = glob(guard_decl).cc;
    for ci: to_lower {
        make_guard_control_flow_explicit(deopt_fn, ci, false);
        erase_inst(ci);
    }
    return PRESERVE_NONE;
}

// LowerWidenableConditionPass::run
lower_widenable_condition_run :: (f: Value_Id) -> Preserved {
    wc_decl := intrinsic_declaration_if_exists(IID_EXPERIMENTAL_WIDENABLE_CONDITION);
    if wc_decl == NONE || !has_uses(wc_decl) return PRESERVE_ALL;
    users: [..] Value_Id; users.allocator = temp;
    gu_users(wc_decl, *users);
    to_lower: [..] Value_Id; to_lower.allocator = temp;
    for users if is_inst(it) && inst_op(it) == .CALL && inst_fn(it) == f array_add(*to_lower, it);
    if to_lower.count == 0 return PRESERVE_ALL;
    t := const_int(type_int(1), 1);
    for ci: to_lower {
        replace_all_uses_with(ci, t);
        erase_inst(ci);
    }
    return PRESERVE_NONE;
}
