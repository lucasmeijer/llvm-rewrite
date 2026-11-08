// PHITransAddr: port of llvm/lib/Analysis/PHITransAddr.cpp and llvm/include/llvm/Analysis/PHITransAddr.h
// (canPHITrans, isPotentiallyPHITranslatable, RemoveInstInputs, translateSubExpr incl. the select-condition
// resolution, both translateValue overloads, getSelectCondition, translateWithInsertion, insertTranslatedSubExpr,
// -gvn-add-phi-translation). Users: MemorySSA's upward_defs (phi_translate_value), MemoryDependenceAnalysis and
// GVN. The debug-only dump/verify are not ported.
//
// A PHITransAddr is copied by value in LLVM (its InstInputs SmallVector is copied too): use pta_copy, never a plain
// struct copy (the `inputs` array would be shared).

Phi_Trans_Addr :: struct {
    addr: Value_Id = NONE;
    inputs: [..] Value_Id;   // InstInputs
    ac: *Assumption_Cache;
}

pta_opts: struct {
    enable_add_phi_translation := false;   // -gvn-add-phi-translation
};

// PHITransAddr(Addr, DL, AC)
pta_make :: (addr: Value_Id, ac: *Assumption_Cache) -> Phi_Trans_Addr {
    t: Phi_Trans_Addr;
    t.addr = addr; t.ac = ac;
    t.inputs.allocator = temp;
    pta_add_as_input(*t, addr);
    return t;
}
// copy constructor
pta_copy :: (s: Phi_Trans_Addr) -> Phi_Trans_Addr {
    t: Phi_Trans_Addr;
    t.addr = s.addr; t.ac = s.ac;
    t.inputs.allocator = temp;
    for s.inputs array_add(*t.inputs, it);
    return t;
}
pta_add_as_input :: (t: *Phi_Trans_Addr, v: Value_Id) -> Value_Id {
    if v != NONE && is_inst(v) array_add(*t.inputs, v);
    return v;
}
pta_input_index :: (t: *Phi_Trans_Addr, v: Value_Id) -> s64 { for t.inputs if it == v return it_index; return -1; }

// needsPHITranslationFromBlock
pta_needs_phi_translation_from_block :: (t: *Phi_Trans_Addr, bb: Value_Id) -> bool {
    for t.inputs if inst_block(it) == bb return true;
    return false;
}
// isPotentiallyPHITranslatable
pta_is_potentially_phi_translatable :: (t: *Phi_Trans_Addr) -> bool {
    if t.addr == NONE || !is_inst(t.addr) return true;
    return can_phi_trans(t.addr);
}

// RemoveInstInputs
pta_remove_inst_inputs :: (t: *Phi_Trans_Addr, v: Value_Id) {
    if !is_inst(v) return;
    k := pta_input_index(t, v);
    if k >= 0 { array_ordered_remove_by_index(*t.inputs, k); return; }
    n := nops(v);
    if n > 0 for j: 0..n-1 { o := op(v, j); if is_inst(o) pta_remove_inst_inputs(t, o); }
}
// canPHITrans
can_phi_trans :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .PHI || o == .GEP || is_cast_op(o) return true;
    return o == .ADD && is_const_int(op(i, 1));
}

// translateSubExpr(V, CurBB, PredBB, DT, Cond, CondVal)
pta_translate_sub_expr :: (t: *Phi_Trans_Addr, v: Value_Id, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree,
                           cond: Value_Id = NONE, cond_val := false) -> Value_Id {
    if !is_inst(v) return v;
    i := v;
    k := pta_input_index(t, i);
    if k >= 0 {
        if inst_block(i) != cur_bb return i;
        array_ordered_remove_by_index(*t.inputs, k);
        if inst_op(i) == .PHI {
            incoming := phi_incoming_value_for_block(i, pred_bb);
            if cond != NONE && is_inst(incoming) && inst_op(incoming) == .SELECT && op(incoming, 0) == cond
                return pta_add_as_input(t, ifx cond_val then op(incoming, 1) else op(incoming, 2));
            return pta_add_as_input(t, incoming);
        }
        if !can_phi_trans(i) return NONE;
        n := nops(i);
        if n > 0 for j: 0..n-1 pta_add_as_input(t, op(i, j));
    }
    sq: Simplify_Query; sq.dt = dt; sq.ac = t.ac;
    o := inst_op(i);
    if is_cast_op(o) {
        phi_in := pta_translate_sub_expr(t, op(i, 0), cur_bb, pred_bb, dt, cond, cond_val);
        if phi_in == NONE return NONE;
        if phi_in == op(i, 0) return i;
        s := simplify_cast_inst(o, phi_in, vtype(i), sq);
        if s != NONE { pta_remove_inst_inputs(t, phi_in); return pta_add_as_input(t, s); }
        u := ir.v_first_use[phi_in];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == o && vtype(usr) == vtype(i) && (!dt || dt_dominates(dt, inst_block(usr), pred_bb)) return usr;
            u = ir.u_next[u];
        }
        return NONE;
    }
    if o == .GEP {
        n := nops(i);
        ops: [..] Value_Id; ops.allocator = temp;
        any_changed := false;
        for j: 0..n-1 {
            x := pta_translate_sub_expr(t, op(i, j), cur_bb, pred_bb, dt, cond, cond_val);
            if x == NONE return NONE;
            any_changed = any_changed || x != op(i, j);
            array_add(*ops, x);
        }
        if !any_changed return i;
        idxs: [] Value_Id; idxs.data = ops.data + 1; idxs.count = ops.count - 1;
        s := simplify_gep_inst(inst(i).ty2, ops[0], idxs, inst(i).flags & (F_INBOUNDS | F_NUSW | F_GEP_NUW), sq);
        if s != NONE { for ops pta_remove_inst_inputs(t, it); return pta_add_as_input(t, s); }
        aphi := ops[0];
        if is_constant_data(aphi) return NONE;
        u := ir.v_first_use[aphi];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == .GEP && vtype(usr) == vtype(i) && inst(usr).ty2 == inst(i).ty2 && nops(usr) == cast(u32) ops.count &&
               inst_fn(usr) == block_fn(cur_bb) && (!dt || dt_dominates(dt, inst_block(usr), pred_bb)) {
                same := true;
                for ops if op(usr, cast(u32) it_index) != it { same = false; break; }
                if same return usr;
            }
            u = ir.u_next[u];
        }
        return NONE;
    }
    if o == .ADD && is_const_int(op(i, 1)) {
        rhs := op(i, 1);
        is_nsw := (inst(i).flags & F_NSW) != 0;
        is_nuw := (inst(i).flags & F_NUW) != 0;
        lhs := pta_translate_sub_expr(t, op(i, 0), cur_bb, pred_bb, dt, cond, cond_val);
        if lhs == NONE return NONE;
        if is_inst(lhs) && inst_op(lhs) == .ADD && is_const_int(op(lhs, 1)) {
            bop := lhs;
            lhs = op(bop, 0);
            rhs = ce_add_const(rhs, op(bop, 1));
            is_nsw = false; is_nuw = false;
            if pta_input_index(t, bop) >= 0 { pta_remove_inst_inputs(t, bop); pta_add_as_input(t, lhs); }
        }
        s := simplify_add_inst(lhs, rhs, is_nsw, is_nuw, sq);
        if s != NONE { pta_remove_inst_inputs(t, lhs); return pta_add_as_input(t, s); }
        if lhs == op(i, 0) && rhs == op(i, 1) return i;
        u := ir.v_first_use[lhs];
        while u != NONE {
            usr := ir.u_user[u];
            if is_inst(usr) && inst_op(usr) == .ADD && op(usr, 0) == lhs && op(usr, 1) == rhs &&
               inst_fn(usr) == block_fn(cur_bb) && (!dt || dt_dominates(dt, inst_block(usr), pred_bb)) return usr;
            u = ir.u_next[u];
        }
        return NONE;
    }
    return NONE;
}

// translateValue(CurBB, PredBB, DT, MustDominate)
pta_translate_value :: (t: *Phi_Trans_Addr, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree, must_dominate: bool) -> Value_Id {
    if dt && dt_is_reachable_from_entry(dt, pred_bb) t.addr = pta_translate_sub_expr(t, t.addr, cur_bb, pred_bb, dt);
    else t.addr = NONE;
    if must_dominate && t.addr != NONE && is_inst(t.addr) && !dt_dominates(dt, inst_block(t.addr), pred_bb) t.addr = NONE;
    return t.addr;
}
// translateValue(CurBB, PredBB, DT, Cond): the addresses for the two sides of the select on Cond
pta_translate_value_select :: (t: *Phi_Trans_Addr, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree, cond: Value_Id) -> (Value_Id, Value_Id) {
    if !dt || !dt_is_reachable_from_entry(dt, pred_bb) return NONE, NONE;
    t1 := pta_copy(t.*);
    a := pta_translate_sub_expr(*t1, t1.addr, cur_bb, pred_bb, dt, cond, true);
    t2 := pta_copy(t.*);
    b := pta_translate_sub_expr(*t2, t2.addr, cur_bb, pred_bb, dt, cond, false);
    return a, b;
}
// getSelectCondition
pta_select_condition :: (t: *Phi_Trans_Addr) -> Value_Id {
    for t.inputs if inst_op(it) == .SELECT return op(it, 0);
    return NONE;
}

// PHITransAddr(Addr).translateValue(CurBB, PredBB, DT, MustDominate) with a null AssumptionCache (MemorySSA)
phi_translate_value :: (addr: Value_Id, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree, must_dominate: bool) -> Value_Id {
    t := pta_make(addr, null);
    return pta_translate_value(*t, cur_bb, pred_bb, dt, must_dominate);
}

// translateWithInsertion(CurBB, PredBB, DT, NewInsts)
pta_translate_with_insertion :: (t: *Phi_Trans_Addr, cur_bb: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree, new_insts: *[..] Value_Id) -> Value_Id {
    nisize := new_insts.count;
    t.addr = pta_insert_translated_sub_expr(t, t.addr, cur_bb, pred_bb, dt, new_insts);
    if t.addr != NONE return t.addr;
    while new_insts.count != nisize {
        i := pop(new_insts);
        erase_inst_with_metadata(i);
    }
    return NONE;
}

// insertTranslatedSubExpr
pta_insert_translated_sub_expr :: (t: *Phi_Trans_Addr, in_val: Value_Id, cur_bb_in: Value_Id, pred_bb: Value_Id, dt: *Dom_Tree,
                                   new_insts: *[..] Value_Id) -> Value_Id {
    cur_bb := cur_bb_in;
    tmp := pta_make(in_val, t.ac);
    a := pta_translate_value(*tmp, cur_bb, pred_bb, dt, true);
    if a != NONE return a;
    if !is_inst(in_val) return NONE;
    i := in_val;
    o := inst_op(i);
    term := block_terminator(pred_bb);
    if is_cast_op(o) {
        opv := pta_insert_translated_sub_expr(t, op(i, 0), cur_bb, pred_bb, dt, new_insts);
        if opv == NONE return NONE;
        n := create_cast(o, opv, vtype(in_val));
        insert_at_position(n, pred_bb, term, false);
        set_name(n, tprint("%.phi.trans.insert", vname(in_val)));
        copy_debug_loc(n, i);
        array_add(new_insts, n);
        return n;
    }
    if o == .GEP {
        ops: [..] Value_Id; ops.allocator = temp;
        cur_bb = inst_block(i);   // LLVM shadows CurBB with the GEP's own block here
        for k: 0..cast(s64) nops(i) - 1 {
            opv := pta_insert_translated_sub_expr(t, op(i, cast(u32) k), cur_bb, pred_bb, dt, new_insts);
            if opv == NONE return NONE;
            array_add(*ops, opv);
        }
        idxs: [] Value_Id; idxs.data = ops.data + 1; idxs.count = ops.count - 1;
        r := create_gep(inst(i).ty2, ops[0], idxs);
        insert_at_position(r, pred_bb, term, false);
        set_name(r, tprint("%.phi.trans.insert", vname(in_val)));
        copy_debug_loc(r, i);
        inst(r).flags = inst(i).flags & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);   // setNoWrapFlags
        array_add(new_insts, r);
        return r;
    }
    if pta_opts.enable_add_phi_translation && o == .ADD && is_const_int(op(i, 1)) {
        opv := pta_insert_translated_sub_expr(t, op(i, 0), cur_bb, pred_bb, dt, new_insts);
        if opv == NONE return NONE;
        r := create_binop(.ADD, opv, op(i, 1));
        insert_at_position(r, pred_bb, term, false);
        set_name(r, tprint("%.phi.trans.insert", vname(in_val)));
        inst(r).flags = inst(i).flags & cast(u32)(F_NSW | F_NUW);
        array_add(new_insts, r);
        return r;
    }
    return NONE;
}
