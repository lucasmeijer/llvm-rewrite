// NaryReassociate (nary-reassociate): port of llvm/lib/Transforms/Scalar/NaryReassociate.cpp. `(a + b) + c` (also
// `*`, GEP indices and smax/smin/umax/umin) is rewritten as `(a + c) + b` when `a + c` already exists in a dominating
// instruction, found by its SCEV.

Nary :: struct {
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    t: *Tti;
    seen: Table(Scev_Id, [..] Value_Id);   // SeenExprs
}

// depth_first(DT): the dominator tree's blocks in preorder (children in order)
dt_blocks_preorder :: (dt: *Dom_Tree, out: *[..] Value_Id) {
    root := dt_node(dt, fn_entry(dt.fn));
    if root < 0 return;
    stack: [..] s32; stack.allocator = temp;
    array_add(*stack, root);
    while stack.count {
        n := pop(*stack);
        array_add(out, dt_block(dt, n));
        kids: [..] s32; kids.allocator = temp;
        c := dt.nodes[n].first_child;
        while c >= 0 { array_add(*kids, c); c = dt.nodes[c].sibling; }
        for < kids array_add(*stack, it);
    }
}

nr_seen_push :: (c: *Nary, s: Scev_Id, v: Value_Id) {
    p := table_find_pointer(*c.seen, s);
    if !p { e: [..] Value_Id; e.allocator = temp; table_set(*c.seen, s, e); p = table_find_pointer(*c.seen, s); }
    array_add(p, v);
}

// NaryReassociatePass::runImpl
nary_reassociate_run :: (f: Value_Id) -> Preserved {
    c: Nary;
    c.ac = get_assumption_cache(f);
    c.dt = get_domtree(f);
    s := get_scev(f);
    c.t = tti_get(f);
    se = s;
    saved := scev_pass_se;
    scev_pass_se = s;
    defer scev_pass_se = saved;
    c.seen.allocator = temp;
    changed := false;
    while true {
        it_changed := nr_do_one_iteration(*c, f);
        changed |= it_changed;
        if !it_changed break;
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    pa.cfg = true;
    preserve(*pa, .SCEV);
    return pa;
}

// doOneIteration
nr_do_one_iteration :: (c: *Nary, f: Value_Id) -> bool {
    changed := false;
    table_reset(*c.seen);
    dead: [..] Vh; dead.allocator = temp;
    blocks: [..] Value_Id; blocks.allocator = temp;
    dt_blocks_preorder(c.dt, *blocks);
    for bb: blocks {
        i := block_first(bb);
        while i != NONE {
            orig_i := i;
            orig_scev: Scev_Id = SCEV_NULL;
            new_i := nr_try_reassociate(c, orig_i, *orig_scev);
            if new_i != NONE {
                changed = true;
                replace_all_uses_with(orig_i, new_i);
                array_add(*dead, vh_new(orig_i));
                new_scev := sc_get_scev(new_i);
                nr_seen_push(c, new_scev, new_i);
                if new_scev != orig_scev nr_seen_push(c, orig_scev, new_i);
            } else if orig_scev != SCEV_NULL nr_seen_push(c, orig_scev, orig_i);
            i = inst_next(orig_i);
        }
    }
    nr_delete_dead_permissive(*dead);
    return changed;
}

// RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadInsts, TLI, nullptr, SE->forgetValue)
nr_delete_dead_permissive :: (dead: *[..] Vh) {
    alive := 0;
    for h: dead.* {
        i := vh_get(h);
        if i == NONE || !is_inst(i) || !is_instruction_trivially_dead_tli(i, false) { vh_set(h, NONE); alive += 1; }
    }
    if alive == dead.count return;
    while dead.count {
        i := vh_get(pop(dead));
        if i == NONE continue;
        salvage_debug_info(i);
        sc_forget_value(i);
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            set_op(i, cast(u32) k, NONE);
            if o == NONE || has_uses(o) continue;
            if is_inst(o) && is_instruction_trivially_dead_tli(o, true) array_add(dead, vh_new(o));
        }
        erase_inst_with_metadata(i);
    }
}

// tryReassociate
nr_try_reassociate :: (c: *Nary, i: Value_Id, orig_scev: *Scev_Id) -> Value_Id {
    if !sc_is_scevable(vtype(i)) return NONE;
    o := inst_op(i);
    if o == .ADD || o == .MUL {
        orig_scev.* = sc_get_scev(i);
        return nr_try_reassociate_binary_op(c, i);
    }
    if o == .GEP {
        orig_scev.* = sc_get_scev(i);
        return nr_try_reassociate_gep(c, i);
    }
    id := call_iid(i);
    if o == .CALL && (id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN) {
        orig_scev.* = sc_get_scev(i);
        r := nr_try_reassociate_min_or_max(c, i);
        if r != NONE && !is_inst(r) return NONE;   // dyn_cast_or_null<Instruction>
        return r;
    }
    return NONE;
}

// tryReassociateGEP
nr_try_reassociate_gep :: (c: *Nary, gep: Value_Id) -> Value_Id {
    idx: [..] Value_Id; idx.allocator = temp;
    for k: 1..cast(s64) nops(gep) - 1 array_add(*idx, op(gep, cast(u32) k));
    if tti_gep_cost(c.t, opr_gep_source_type(gep), op(gep, 0), idx, NONE, TCK_SIZE_AND_LATENCY) == TCC_FREE return NONE;   // isGEPFoldable
    // gep_type_iterator
    cur: Type_Id = NONE;
    for k: 1..cast(s64) nops(gep) - 1 {
        indexed: Type_Id;
        sequential: bool;
        if k == 1 { indexed = opr_gep_source_type(gep); sequential = true; }
        else {
            sequential = type_kind(cur) != .STRUCT;
            if sequential indexed = type_elem(cur);
            else indexed = type_sub(cur, cast(u32) const_int_zext(op(gep, cast(u32) k)));
        }
        if sequential {
            n := nr_try_reassociate_gep_at_index(c, gep, cast(u32) (k - 1), indexed);
            if n != NONE return n;
        }
        cur = indexed;
    }
    return NONE;
}

// requiresSignExtension
nr_requires_sign_extension :: (index: Value_Id, gep: Value_Id) -> bool {
    return type_bits(vtype(index)) < dl_index_size_bits(cast(u32) ir.types[scalar_type(vtype(gep))].a);
}

nr_sq :: (c: *Nary, cxt: Value_Id) -> Simplify_Query { q: Simplify_Query; q.dt = c.dt; q.ac = c.ac; q.cxt = cxt; q.have_tli = false; return q; }

// tryReassociateGEPAtIndex(GEP, I, IndexedType)
nr_try_reassociate_gep_at_index :: (c: *Nary, gep: Value_Id, i: u32, indexed_type: Type_Id) -> Value_Id {
    sq := nr_sq(c, gep);
    index_to_split := op(gep, i + 1);
    if is_inst(index_to_split) && inst_op(index_to_split) == .SEXT index_to_split = op(index_to_split, 0);
    else if is_inst(index_to_split) && inst_op(index_to_split) == .ZEXT {
        if is_known_non_negative(op(index_to_split, 0), sq) index_to_split = op(index_to_split, 0);
    }
    // dyn_cast<AddOperator>: an add instruction or constant expression
    if opr_code(index_to_split) != .ADD return NONE;
    if nr_requires_sign_extension(index_to_split, gep) && compute_overflow_for_signed_add_op(index_to_split, sq) != .NEVER_OVERFLOWS return NONE;
    lhs := op(index_to_split, 0); rhs := op(index_to_split, 1);
    n := nr_try_reassociate_gep_at_index_lr(c, gep, i, lhs, rhs, indexed_type);
    if n != NONE return n;
    if lhs != rhs {
        n = nr_try_reassociate_gep_at_index_lr(c, gep, i, rhs, lhs, indexed_type);
        if n != NONE return n;
    }
    return NONE;
}

// tryReassociateGEPAtIndex(GEP, I, LHS, RHS, IndexedType)
nr_try_reassociate_gep_at_index_lr :: (c: *Nary, gep: Value_Id, i: u32, lhs: Value_Id, rhs_in: Value_Id, indexed_type: Type_Id) -> Value_Id {
    rhs := rhs_in;
    index_exprs: [..] Scev_Id; index_exprs.allocator = temp;
    for k: 1..cast(s64) nops(gep) - 1 array_add(*index_exprs, sc_get_scev(op(gep, cast(u32) k)));
    index_exprs[i] = sc_get_scev(lhs);
    gep_arg_type := sc_effective_type(vtype(op(gep, i)));   // GEP->getOperand(I): as in LLVM, the operand before the index
    lhs_type := sc_effective_type(vtype(lhs));
    lhs_size := dl_type_size_bits(lhs_type);
    gep_arg_size := dl_type_size_bits(gep_arg_type);
    if is_known_non_negative(lhs, nr_sq(c, gep)) && lhs_size < gep_arg_size
        index_exprs[i] = sc_get_zero_extend(index_exprs[i], gep_arg_type);
    // getGEPExpr(cast<GEPOperator>(GEP), IndexExprs)
    nw := opr_flags(gep) & (F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if nw != 0 && (!is_inst(gep) || !sc_is_scev_expr_never_poison(gep)) nw = 0;
    candidate_expr := sc_get_gep(sc_get_scev(op(gep, 0)), index_exprs, opr_gep_source_type(gep), nw, .[]);
    candidate := nr_find_closest_matching_dominator(c, candidate_expr, gep);
    if candidate == NONE return NONE;
    b: Irb; irb_set_before(*b, gep);
    indexed_size := dl_type_alloc_size(indexed_type);
    element_type := gep_result_element_type(gep);
    element_size := dl_type_alloc_size(element_type);
    if element_size == 0 || indexed_size % element_size != 0 return NONE;
    ptr_idx_ty := dl_index_type(vtype(gep));
    if vtype(rhs) != ptr_idx_ty {
        rb := type_bits(vtype(rhs)); pb := type_bits(ptr_idx_ty);
        rhs = irb_cast(*b, ifx rb < pb then Opcode.SEXT else .TRUNC, rhs, ptr_idx_ty);   // CreateSExtOrTrunc
    }
    if indexed_size != element_size rhs = irb_binop(*b, .MUL, rhs, const_int(ptr_idx_ty, indexed_size / element_size));
    new_gep := irb_gep(*b, element_type, candidate, .[rhs]);
    if !is_inst(new_gep) fatal("nary-reassociate: the new GEP folded to a constant (LLVM casts it to GetElementPtrInst)");
    // setIsInBounds(GEP->isInBounds()): sets or clears inbounds (nusw/nuw untouched; CreateGEP gave none)
    if gep_is_inbounds(gep) inst(new_gep).flags |= F_INBOUNDS;
    else inst(new_gep).flags &= ~cast(u32) F_INBOUNDS;
    take_name(new_gep, gep);
    return new_gep;
}

// tryReassociateBinaryOp(I)
nr_try_reassociate_binary_op :: (c: *Nary, i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    if sc_is_zero(sc_get_scev(i)) return NONE;
    n := nr_try_reassociate_binary_op_lr(c, lhs, rhs, i);
    if n != NONE return n;
    return nr_try_reassociate_binary_op_lr(c, rhs, lhs, i);
}

// tryReassociateBinaryOp(LHS, RHS, I)
nr_try_reassociate_binary_op_lr :: (c: *Nary, lhs: Value_Id, rhs: Value_Id, i: Value_Id) -> Value_Id {
    // matchTernaryOp: m_Add / m_Mul (instructions only)
    if !has_one_use(lhs) || !is_inst(lhs) || inst_op(lhs) != inst_op(i) return NONE;
    a := op(lhs, 0); b := op(lhs, 1);
    a_expr := sc_get_scev(a); b_expr := sc_get_scev(b);
    rhs_expr := sc_get_scev(rhs);
    if b_expr != rhs_expr {
        n := nr_try_reassociated_binary_op(c, nr_binary_scev(i, a_expr, rhs_expr), b, i);
        if n != NONE return n;
    }
    if a_expr != rhs_expr {
        n := nr_try_reassociated_binary_op(c, nr_binary_scev(i, b_expr, rhs_expr), a, i);
        if n != NONE return n;
    }
    return NONE;
}

// tryReassociatedBinaryOp
nr_try_reassociated_binary_op :: (c: *Nary, lhs_expr: Scev_Id, rhs: Value_Id, i: Value_Id) -> Value_Id {
    lhs := nr_find_closest_matching_dominator(c, lhs_expr, i);
    if lhs == NONE return NONE;
    n := create_binop(inst_op(i), lhs, rhs);
    insert_at_position(n, inst_block(i), i, false);
    set_metadata(n, 0, get_metadata(i, 0));
    take_name(n, i);
    return n;
}

// getBinarySCEV
nr_binary_scev :: (i: Value_Id, l: Scev_Id, r: Scev_Id) -> Scev_Id {
    if inst_op(i) == .ADD return sc_get_add2(l, r);
    return sc_get_mul2(l, r);
}

// findClosestMatchingDominator
nr_find_closest_matching_dominator :: (c: *Nary, expr: Scev_Id, dominatee: Value_Id) -> Value_Id {
    p := table_find_pointer(*c.seen, expr);
    if !p return NONE;
    while p.count {
        cand := pop(p);
        if cand == NONE || vkind(cand) == .DEAD continue;
        if !dt_dominates_inst(c.dt, cand, dominatee) continue;
        drops: [..] Value_Id; drops.allocator = temp;
        if !sc_can_reuse_instruction(expr, cand, *drops) continue;
        for drops drop_poison_generating_annotations(it);
        return cand;
    }
    return NONE;
}

// tryReassociateMinOrMax
nr_try_reassociate_min_or_max :: (c: *Nary, i: Value_Id) -> Value_Id {
    id := call_iid(i);
    lhs := call_arg(i, 0); rhs := call_arg(i, 1);
    if is_inst(rhs) && inst_op(rhs) == .CALL && call_iid(rhs) == id lhs, rhs = rhs, lhs;
    if !(is_inst(lhs) && inst_op(lhs) == .CALL && call_iid(lhs) == id) return NONE;
    a := call_arg(lhs, 0); b := call_arg(lhs, 1);
    if has_n_uses_or_more(lhs, 3) return NONE;
    for u: sx_users(lhs) {
        if u == i continue;
        if !(has_one_user(u) && ir.u_user[ir.v_first_use[u]] == i) return NONE;
    }
    kind: Scev_Kind;
    if id == IID_SMAX kind = .SMAX; else if id == IID_UMAX kind = .UMAX; else if id == IID_SMIN kind = .SMIN; else kind = .UMIN;
    try_combination :: (c: *Nary, i: Value_Id, kind: Scev_Kind, a_expr: Scev_Id, b_expr: Scev_Id, cv: Value_Id) -> Value_Id {
        ops1: [..] Scev_Id; ops1.allocator = temp;
        array_add(*ops1, b_expr); array_add(*ops1, a_expr);
        r1_expr := sc_get_min_max(kind, *ops1);
        r1 := nr_find_closest_matching_dominator(c, r1_expr, i);
        if r1 == NONE return NONE;
        ops2: [..] Scev_Id; ops2.allocator = temp;
        array_add(*ops2, sc_get_unknown(cv)); array_add(*ops2, sc_get_unknown(r1));
        r2_expr := sc_get_min_max(kind, *ops2);
        x: Scev_Expander; sx_init(*x, "nary-reassociate");
        nm := sx_expand_code_for_at(*x, r2_expr, vtype(i), i);
        if is_inst(nm) || vkind(nm) == .ARGUMENT set_name(nm, tconcat(vname(i), ".nary"));   // setName is a no-op on a constant
        return nm;
    }
    a_expr := sc_get_scev(a); b_expr := sc_get_scev(b); rhs_expr := sc_get_scev(rhs);
    if b_expr != rhs_expr {
        n := try_combination(c, i, kind, a_expr, rhs_expr, b);
        if n != NONE return n;
    }
    if a_expr != rhs_expr {
        n := try_combination(c, i, kind, rhs_expr, b_expr, a);
        if n != NONE return n;
    }
    return NONE;
}
