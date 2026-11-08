// InstCombine: the visitor dispatch (InstVisitor<InstCombinerImpl>::visit as an opcode switch) and the visitors of
// the files that are not ported yet. Each partial visitor below ports the beginning of its LLVM counterpart (the
// InstSimplify call and the canonicalizations listed in its comment) and documents what it leaves out; extending
// one means porting the rest of its function in order (see DESIGN.md "InstCombine: how to add a fold").
// Ported from: InstructionCombining.cpp (visitReturnInst, visitUnreachableInst, visitUncondBrInst, visitCondBrInst,
// handlePotentiallyDeadSuccessors, visitExtractValueInst prologue, visitFreeze prologue, visitGetElementPtrInst
// prologue),
// InstCombineLoadStoreAlloca.cpp (mergeStoreIntoSuccessor). The cast visitors are in ic_casts.jai, the call
// visitors in ic_calls.jai.

ic_visit :: (i: Value_Id) -> Value_Id {
    o := inst_op(i);
    if o == {
        case .ADD; return ic_visit_add(i);
        case .SUB; return ic_visit_sub(i);
        case .MUL; return ic_visit_mul(i);
        case .UDIV; return ic_visit_udiv(i);
        case .SDIV; return ic_visit_sdiv(i);
        case .UREM; return ic_visit_urem(i);
        case .SREM; return ic_visit_srem(i);
        case .FADD; return ic_visit_fadd(i);
        case .FSUB; return ic_visit_fsub(i);
        case .FMUL; return ic_visit_fmul(i);
        case .FDIV; return ic_visit_fdiv(i);
        case .FREM; return ic_visit_frem(i);
        case .FNEG; return ic_visit_fneg(i);
        case .AND; return ic_visit_and(i);
        case .OR; return ic_visit_or(i);
        case .XOR; return ic_visit_xor(i);
        case .SHL; return ic_visit_shl(i);
        case .LSHR; return ic_visit_lshr(i);
        case .ASHR; return ic_visit_ashr(i);
        case .ICMP; return ic_visit_icmp(i);
        case .FCMP; return ic_visit_fcmp(i);
        case .SELECT; return ic_visit_select(i);
        case .PHI; return ic_visit_phi(i);
        case .GEP; return ic_visit_gep(i);
        case .CALL; return ic_visit_call(i);
        case .INVOKE; return ic_visit_invoke(i);
        case .CALLBR; return ic_visit_callbr(i);
        case .FENCE; return ic_visit_fence(i);
        case .RET; return ic_visit_return(i);
        case .UNREACHABLE; return ic_visit_unreachable(i);
        case .BR; return ic_visit_uncond_br(i);
        case .CONDBR; return ic_visit_cond_br(i);
        case .FREEZE; return ic_visit_freeze(i);
        case .EXTRACTVALUE; return ic_visit_extract_value(i);
        case .LOAD; return ic_visit_load(i);
        case .STORE; return ic_visit_store(i);
        case .ALLOCA; return ic_visit_alloca(i);
        case .SWITCH; return ic_visit_switch(i);
        case .LANDINGPAD; return ic_visit_landing_pad(i);
        case .EXTRACTELEMENT; return ic_visit_extract_element(i);
        case .INSERTELEMENT; return ic_visit_insert_element(i);
        case .INSERTVALUE; return ic_visit_insert_value(i);
        case .SHUFFLEVECTOR; return ic_visit_shuffle_vector(i);
    }
    if o == {
        case .UITOFP; return ic_visit_uitofp(i);
        case .SITOFP; return ic_visit_sitofp(i);
        case .ZEXT; return ic_visit_zext(i);
        case .SEXT; return ic_visit_sext(i);
        case .TRUNC; return ic_visit_trunc(i);
        case .FPTRUNC; return ic_visit_fptrunc(i);
        case .FPEXT; return ic_visit_fpext(i);
        case .FPTOUI; return ic_visit_fptoui(i);
        case .FPTOSI; return ic_visit_fptosi(i);
        case .INTTOPTR; return ic_visit_int_to_ptr(i);
        case .PTRTOINT; return ic_visit_ptr_to_int(i);
        case .PTRTOADDR; return ic_visit_ptr_to_addr(i);
        case .BITCAST; return ic_visit_bitcast(i);
        case .ADDRSPACECAST; return ic_visit_addr_space_cast(i);
    }
    if is_cast_op(o) return ic_common_cast_transforms(i);
    return NONE;   // visitInstruction
}

// The InstSimplify step every visitor starts with (when nothing else is ported for it).
ic_visit_simplify_only :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}


// getFlippedStrictnessPredicateAndConstant (ValueTracking.cpp)
flipped_strictness_predicate_and_constant :: (pred: u8, c: Value_Id) -> (bool, u8, Value_Id) {
    if pm_undef_value(c) return false, 0, NONE;
    t := vtype(c);
    is_signed := icmp_is_signed(pred);
    up := icmp_unsigned_predicate(pred);
    will_inc := up == ICMP_ULE || up == ICMP_UGT;
    ok_c :: (ci: Value_Id, will_inc: bool, is_signed: bool) -> bool {
        a := const_ap(ci);
        if will_inc return !(ifx is_signed then ap_is_max_signed(a) else ap_is_all_ones(a));
        return !(ifx is_signed then ap_is_min_signed(a) else ap_is_zero(a));
    }
    safe: Value_Id = NONE;
    k := vkind(c);
    if k == .C_INT && !is_vector_type(t) {
        if !ok_c(c, will_inc, is_signed) return false, 0, NONE;
    } else if type_kind(t) == .VECTOR {
        n := type_count(t);
        for e: 0..cast(s64) n - 1 {
            elt := cf_elt(c, cast(u64) e);
            if elt == NONE return false, 0, NONE;
            if pm_undef_value(elt) continue;
            if vkind(elt) != .C_INT || !ok_c(elt, will_inc, is_signed) return false, 0, NONE;
            if safe == NONE safe = elt;
        }
    } else if is_vector_type(t) {
        s := get_splat_value(c);
        if s == NONE || vkind(s) != .C_INT || !ok_c(s, will_inc, is_signed) return false, 0, NONE;
    } else return false, 0, NONE;
    cc := c;
    if contains_undef_or_poison_element(cc) {
        n := type_count(t);
        elts := NewArray(cast(s64) n, Value_Id,, allocator = temp);
        for e: 0..cast(s64) n - 1 { elt := cf_elt(cc, cast(u64) e); elts[e] = ifx pm_undef_value(elt) then safe else elt; }
        cc = cf_vector(t, elts);
    }
    np := icmp_flipped_strictness(pred);
    one := const_int_signed(t, ifx will_inc then 1 else -1);
    return true, np, ce_binop(.ADD, cc, one, 0);
}
// CmpInst::getFlippedStrictnessPredicate
icmp_flipped_strictness :: (p: u8) -> u8 {
    if p == {
        case ICMP_SGT; return ICMP_SGE; case ICMP_SLT; return ICMP_SLE; case ICMP_SGE; return ICMP_SGT; case ICMP_SLE; return ICMP_SLT;
        case ICMP_UGT; return ICMP_UGE; case ICMP_ULT; return ICMP_ULE; case ICMP_UGE; return ICMP_UGT; case ICMP_ULE; return ICMP_ULT;
    }
    return p;
}
// canFreelyInvertAllUsersOf
can_freely_invert_all_users_of :: (v: Value_Id, ignored: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        us := ir.u_user[u];
        defer u = ir.u_next[u];
        if us == ignored continue;
        if inst_op(us) == {
            case .SELECT;
                if u - ir.v_ops[us] != 0 return false;
                if should_avoid_absorbing_not_into_select(us) return false;
            case .CONDBR;
            case .XOR;
                ok, x := pm_not(us);
                if !ok return false;
            case; return false;
        }
    }
    return true;
}
// freelyInvertAllUsersOf
ic_freely_invert_all_users_of :: (v: Value_Id, ignored: Value_Id = NONE) {
    u := ir.v_first_use[v];
    while u != NONE {
        nu := ir.u_next[u];
        us := ir.u_user[u];
        if us != ignored {
            if inst_op(us) == {
                case .SELECT;
                    use_swap(op_use(us, 1), op_use(us, 2));
                    swap_prof_metadata(us);
                case .CONDBR;
                    swap_successors(us);
                case .XOR;
                    ic_replace_inst_uses_with(us, v);
                    wl_push(us);
                case; fatal("internal: freelyInvertAllUsersOf out of sync");
            }
        }
        u = nu;
    }
    users: [..] u32; users.allocator = temp;
    find_dbg_users(ic.f, v, *users);
    if users.count fatal("instcombine: freelyInvertAllUsersOf with debug users (DW_OP_not) is not supported yet");
}

// CallBase::addFnAttr(Kind)
call_add_fn_attr :: (i: Value_Id, k: Attr_Kind) {
    l := inst(i).attrs;
    fs := attr_list_fn(l);
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(fs) array_add(*items, it);
    a: Attr; a.kind = k; a.ty = NONE;
    array_add(*items, a);
    nfs := attr_set_get(items);
    inst(i).attrs = attr_list_with_fn(l, nfs);
}

// ---------------------------------------------------------------- terminators (InstructionCombining.cpp)

// visitReturnInst. Not ported: SimplifyDemandedFPClass (fails loudly when it applies).
ic_visit_return :: (i: Value_Id) -> Value_Id {
    if nops(i) == 0 return NONE;
    rv := op(i, 0);
    rt := vtype(rv);
    f := ic.f;
    ret_attrs := attr_list_ret(glob(f).attrs);
    if is_ptr_type(rt) {
        has_deref := attr_set_has(ret_attrs, .Dereferenceable);
        if attr_set_has(ret_attrs, .NonNull) || (has_deref && !null_pointer_is_defined(f, ir.types[rt].a))
        {
            v := ic_simplify_non_null_operand(rv, has_deref);
            if v != NONE return ic_replace_operand(i, 0, v);
        }
    }
    if attr_set_has(ret_attrs, .NoFPClass) fatal("instcombine: SimplifyDemandedFPClass (nofpclass return) is not supported yet");
    return NONE;
}

// removeInstructionsBeforeUnreachable / visitUnreachableInst
ic_visit_unreachable :: (i: Value_Id) -> Value_Id {
    while true {
        prev := inst(i).prev;
        if prev == NONE break;
        if is_eh_pad(prev) break;
        if !is_guaranteed_to_transfer_execution(prev) break;
        ic_replace_inst_uses_with(prev, const_poison(vtype(prev)));
        ic_erase_inst(prev);
    }
    return NONE;
}

// visitUncondBrInst (mergeStoreIntoSuccessor is not ported: fail loudly when its preconditions hold)
ic_visit_uncond_br :: (i: Value_Id) -> Value_Id {
    first := block_first(inst_block(i));
    x := i;
    while true {
        if x != first x = inst(x).prev;
        if x == first || !is_debug_or_pseudo_inst(x) break;
    }
    if inst_op(x) == .STORE && x != i && ic_merge_store_into_successor(x) return i;
    return NONE;
}

// CreateBitOrPointerCast
icb_bit_or_pointer_cast :: (v: Value_Id, t: Type_Id, name: string = "") -> Value_Id {
    if vtype(v) == t return v;
    st := vtype(v);
    if is_ptr_or_ptr_vector(st) && !is_ptr_or_ptr_vector(t) return icb_cast(.PTRTOINT, v, t, name);
    if !is_ptr_or_ptr_vector(st) && is_ptr_or_ptr_vector(t) return icb_cast(.INTTOPTR, v, t, name);
    return icb_cast(.BITCAST, v, t, name);
}

// CondBrInst::swapSuccessors (+ Instruction::swapProfMetadata)
swap_successors :: (br: Value_Id) {
    use_swap(op_use(br, 1), op_use(br, 2));
    swap_prof_metadata(br);
}
swap_prof_metadata :: (i: Value_Id) {
    k := md_kind_id("prof");
    m := get_metadata(i, k);
    if m == NONE return;
    if ir.mds[m].kind != .TUPLE || ir.mds[m].nops < 1 return;
    tag := md_op(m, 0);
    if tag == NONE || ir.mds[tag].kind != .STRING || ir.mds[tag].str != "branch_weights" return;
    first: u32 = 1;
    if ir.mds[m].nops > 1 { e := md_op(m, 1); if e != NONE && ir.mds[e].kind == .STRING && ir.mds[e].str == "expected" first = 2; }
    if ir.mds[m].nops != 2 + first return;
    ops: [..] Md_Id; ops.allocator = temp;
    for x: 0..first-1 array_add(*ops, md_op(m, x));
    array_add(*ops, md_op(m, first + 1));
    array_add(*ops, md_op(m, first));
    set_metadata(i, k, md_tuple(ops, false));
}

// addDeadEdge / handleUnreachableFrom / handlePotentiallyDeadBlocks / handlePotentiallyDeadSuccessors
ic_add_dead_edge :: (from: Value_Id, to: Value_Id, work: *[..] Value_Id) {
    key := edge_key(from, to);
    if table_contains(*ic.dead_edges, key) return;
    table_set(*ic.dead_edges, key, true);
    for p: block_insts(to) {
        if inst_op(p) != .PHI break;
        for k: 0..cast(s64) nops(p) - 1 {
            if phi_block(p, cast(u32) k) == from && !pm_poison(op(p, cast(u32) k)) {
                ic_replace_use(op_use(p, cast(u32) k), const_poison(vtype(p)));
                wl_push(p);
                ic.made_ir_change = true;
            }
        }
    }
    array_add(work, to);
}
ic_handle_unreachable_from :: (i: Value_Id, work: *[..] Value_Id) {
    bb := inst_block(i);
    term := block_terminator(bb);
    // instructions from the one before the terminator back to i, in reverse order
    x := inst(term).prev;
    stop := inst(i).prev;
    while x != stop && x != NONE {
        prev := inst(x).prev;
        if has_uses(x) && type_kind(vtype(x)) != .TOKEN { ic_replace_inst_uses_with(x, const_poison(vtype(x))); ic.made_ir_change = true; }
        if !(is_eh_pad(x) || type_kind(vtype(x)) == .TOKEN) {
            drop_dbg_records(x);
            ic_erase_inst(x);
            ic.made_ir_change = true;
        }
        x = prev;
    }
    // handleUnreachableTerminator
    drop_dbg_records(term);
    changed: [..] Value_Id; changed.allocator = temp;
    for k: 0..cast(s64) nops(term) - 1 {
        o := op(term, cast(u32) k);
        if is_inst(o) && type_kind(vtype(o)) != .TOKEN { set_op(term, cast(u32) k, const_poison(vtype(o))); array_add(*changed, o); }
    }
    if changed.count { ic.made_ir_change = true; for changed wl_add(it); }
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs ic_add_dead_edge(bb, s, work);
}
ic_handle_potentially_dead_blocks :: (work: *[..] Value_Id) {
    preds: [..] Value_Id; preds.allocator = temp;
    while work.count {
        bb := pop(work);
        preds.count = 0;
        block_predecessors(bb, *preds);
        all := true;
        for p: preds if !(table_contains(*ic.dead_edges, edge_key(p, bb)) || dt_dominates(ic.dt, bb, p)) { all = false; break; }
        if !all continue;
        ic_handle_unreachable_from(block_first(bb), work);
    }
}
ic_handle_potentially_dead_successors :: (bb: Value_Id, live: Value_Id) {
    work: [..] Value_Id; work.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(bb, *succs);
    for s: succs { if s == live continue; ic_add_dead_edge(bb, s, *work); }
    ic_handle_potentially_dead_blocks(*work);
}

// visitCondBrInst
ic_visit_cond_br :: (i: Value_Id) -> Value_Id {
    cond := op(i, 0);
    okn, x := pm_not(cond);
    if okn && !is_const(x) {
        swap_successors(i);
        return ic_replace_operand(i, 0, x);
    }
    if is_inst(cond) && inst_op(cond) == .SELECT && has_one_use(cond) {
        okl, lx, nly := pm_logical_and(cond);
        if okl && has_one_use(nly) {
            okn2, y := pm_not(nly);
            if okn2 {
                notx := icb_not(lx, tprint("not.%", vname(lx)));
                or := icb_select(notx, get_true(vtype(notx)), y);
                if is_inst(or) && get_metadata(cond, md_kind_id("prof")) != NONE fatal("instcombine: branch weights of a canonicalized logical and are not supported yet");
                swap_successors(i);
                return ic_replace_operand(i, 0, or);
            }
        }
    }
    if vkind(cond) != .C_INT && get_successor(i, 0) == get_successor(i, 1)
        return ic_replace_operand(i, 0, get_false(vtype(cond)));
    okf, pred, a, b := pm_fcmp(cond);
    if okf && has_one_use(cond) && !is_canonical_predicate(pred) {
        inst(cond).pred = cmp_inverse(pred);
        swap_successors(i);
        wl_push(cond);
        return i;
    }
    if pm_undef_value(cond) { ic_handle_potentially_dead_successors(inst_block(i), NONE); return NONE; }
    if vkind(cond) == .C_INT {
        cv := !ap_is_zero(const_ap(cond));
        ic_handle_potentially_dead_successors(inst_block(i), get_successor(i, ifx cv then cast(u32) 0 else 1));
        return NONE;
    }
    if !is_const(cond) && get_successor(i, 0) != get_successor(i, 1) {
        bb := inst_block(i);
        u := ir.v_first_use[cond];
        while u != NONE {
            nu := ir.u_next[u];
            if dt_dominates_edge_use(ic.dt, bb, get_successor(i, 0), u) {
                user := ir.u_user[u];
                ic_replace_use(u, get_true(vtype(cond)));
                wl_add(user);
            } else if dt_dominates_edge_use(ic.dt, bb, get_successor(i, 1), u) {
                user := ir.u_user[u];
                ic_replace_use(u, get_false(vtype(cond)));
                wl_add(user);
            }
            u = nu;
        }
    }
    dc_register_branch(*ic.dc, i);
    return NONE;
}
