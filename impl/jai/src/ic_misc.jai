// InstCombine: the visitor dispatch (InstVisitor<InstCombinerImpl>::visit as an opcode switch) and the visitors of
// the files that are not ported yet. Each partial visitor below ports the beginning of its LLVM counterpart (the
// InstSimplify call and the canonicalizations listed in its comment) and documents what it leaves out; extending
// one means porting the rest of its function in order (see DESIGN.md "InstCombine: how to add a fold").
// Ported from: InstructionCombining.cpp (visitReturnInst, visitUnreachableInst, visitUncondBrInst, visitCondBrInst,
// handlePotentiallyDeadSuccessors, visitExtractValueInst prologue, visitFreeze prologue, visitGetElementPtrInst
// prologue), InstCombineCompares.cpp (visitICmpInst/visitFCmpInst prologues), InstCombineSelect.cpp,
// InstCombineShifts.cpp, InstCombineAndOrXor.cpp, InstCombineCasts.cpp (commonCastTransforms), InstCombinePHI.cpp,
// InstCombineCalls.cpp, InstCombineVectorOps.cpp, InstCombineLoadStoreAlloca.cpp (prologues only).

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
        case .AND; #through;
        case .OR; #through;
        case .XOR; return ic_visit_bitwise(i);
        case .SHL; #through;
        case .LSHR; #through;
        case .ASHR; return ic_visit_shift(i);
        case .ICMP; return ic_visit_icmp(i);
        case .FCMP; return ic_visit_fcmp(i);
        case .SELECT; return ic_visit_select(i);
        case .PHI; return ic_visit_phi(i);
        case .GEP; return ic_visit_gep(i);
        case .CALL; return ic_visit_call(i);
        case .RET; return ic_visit_return(i);
        case .UNREACHABLE; return ic_visit_unreachable(i);
        case .BR; return ic_visit_uncond_br(i);
        case .CONDBR; return ic_visit_cond_br(i);
        case .FREEZE; return ic_visit_freeze(i);
        case .EXTRACTVALUE; return ic_visit_extract_value(i);
        case .LOAD; return ic_visit_load(i);
        case .EXTRACTELEMENT; #through;
        case .INSERTELEMENT; #through;
        case .INSERTVALUE; #through;
        case .SHUFFLEVECTOR; return ic_visit_simplify_only(i);
    }
    if is_cast_op(o) return ic_visit_cast(i);
    return NONE;   // visitInstruction
}

// The InstSimplify step every visitor starts with (when nothing else is ported for it).
ic_visit_simplify_only :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}

// visitAnd / visitOr / visitXor: InstSimplify, SimplifyAssociativeOrCommutative, foldVectorBinop,
// foldBinopWithPhiOperands, SimplifyDemandedInstructionBits (visitXor: after foldNot etc., not ported).
// Not ported: everything after SimplifyDemandedInstructionBits.
ic_visit_bitwise :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if ic_simplify_associative_or_commutative(i) return i;
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    if inst_op(i) != .XOR && ic_simplify_demanded_instruction_bits(i) return i;
    return NONE;
}

// visitShl / visitLShr / visitAShr: InstSimplify, foldVectorBinop, the start of commonShiftTransforms
// (foldBinopWithPhiOperands, sext shift amount, SimplifyDemandedInstructionBits). Not ported: the rest.
ic_visit_shift :: (i: Value_Id) -> Value_Id {
    v := simplify_instruction(i, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r := ic_fold_vector_binop(i); if r != NONE return r;
    r = ic_fold_binop_with_phi_operands(i); if r != NONE return r;
    op1 := op(i, 1);
    oks, y := pmi_cast(op1, .SEXT);
    if oks && has_one_use(op1) {
        ne := icb_zext(y, vtype(i), name_ref(vname(op1)));
        return create_binop(inst_op(i), op(i, 0), ne);
    }
    if ic_simplify_demanded_instruction_bits(i) return i;
    return NONE;
}

// visitICmpInst: operand complexity order, InstSimplify. Not ported: everything after.
ic_visit_icmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    if ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { cmp_swap_operands(i); changed = true; }
    v := simplify_icmp_inst(inst_pred(i), (inst(i).flags & F_EXACT) != 0, op(i, 0), op(i, 1), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if changed return i;
    return NONE;
}
// visitFCmpInst: operand complexity order, InstSimplify. Not ported: everything after.
ic_visit_fcmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    if ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { cmp_swap_operands(i); changed = true; }
    v := simplify_fcmp_inst(inst_pred(i), op(i, 0), op(i, 1), get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if changed return i;
    return NONE;
}
// visitSelectInst: InstSimplify. Not ported: everything after.
ic_visit_select :: (i: Value_Id) -> Value_Id {
    fmf: u32 = 0;
    if is_fp_math_inst(i) fmf = get_fmf(i);
    v := simplify_select_inst(op(i, 0), op(i, 1), op(i, 2), fmf, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}
// visitPHINode: InstSimplify. Not ported: everything after.
ic_visit_phi :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitGetElementPtrInst: InstSimplify. Not ported: everything after.
ic_visit_gep :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitLoadInst: InstSimplify. Not ported: everything after.
ic_visit_load :: (i: Value_Id) -> Value_Id { return ic_visit_simplify_only(i); }
// visitFreeze: InstSimplify, foldOpIntoPhi. Not ported: everything after.
ic_visit_freeze :: (i: Value_Id) -> Value_Id {
    v := simplify_freeze_inst(op(i, 0), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_phi(op(i, 0)) { r := ic_fold_op_into_phi(i, op(i, 0)); if r != NONE return r; }
    return NONE;
}
// visitExtractValueInst: no indices, InstSimplify. Not ported: everything after.
ic_visit_extract_value :: (i: Value_Id) -> Value_Id {
    if inst(i).nidx == 0 return ic_replace_inst_uses_with(i, op(i, 0));
    return ic_visit_simplify_only(i);
}

// commonCastTransforms: InstSimplify, cast-of-cast elimination, FoldOpIntoSelect, foldOpIntoPhi.
// Not ported: the shuffle canonicalization and every visitTrunc/ZExt/... specific fold.
ic_visit_cast :: (i: Value_Id) -> Value_Id {
    src := op(i, 0);
    ty := vtype(i);
    opc := inst_op(i);
    v := simplify_cast_inst(opc, src, ty, ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if is_inst(src) && is_cast_op(inst_op(src)) {
        nopc := ic_is_eliminable_cast_pair(src, i);
        if nopc != .NONE_OP {
            if has_one_use(src) {
                users: [..] u32; users.allocator = temp;
                find_dbg_users(ic.f, src, *users);
                if users.count fatal("instcombine: replaceAllDbgUsesWith of an eliminated cast is not supported yet");
            }
            return create_cast(nopc, op(src, 0), ty);
        }
    }
    if is_inst(src) && inst_op(src) == .SELECT {
        cmp := op(src, 0);
        if !is_cmp_inst(cmp) || vtype(op(cmp, 0)) != vtype(src) || (opc == .TRUNC && ic_should_change_type(vtype(src), ty)) {
            okb, x := pm_elementwise_bitcast(i);
            if opc != .BITCAST || okb {
                nv := ic_fold_op_into_select(i, src);
                if nv != NONE {
                    users: [..] u32; users.allocator = temp;
                    find_dbg_users(ic.f, src, *users);
                    if users.count fatal("instcombine: replaceAllDbgUsesWith of a select folded into a cast is not supported yet");
                    return nv;
                }
            }
        }
    }
    if is_phi(src) {
        if !is_int_type(vtype(src)) || !is_int_type(ty) || ic_should_change_type(vtype(src), ty) {
            nv := ic_fold_op_into_phi(i, src);
            if nv != NONE return nv;
        }
    }
    return NONE;
}
// InstCombinerImpl::isEliminableCastPair
ic_is_eliminable_cast_pair :: (ci1: Value_Id, ci2: Value_Id) -> Opcode {
    src := vtype(op(ci1, 0)); mid := vtype(ci1); dst := vtype(ci2);
    res := is_eliminable_cast_pair_dl(inst_op(ci1), inst_op(ci2), src, mid, dst);
    if res == .INTTOPTR && (!is_ptr_or_ptr_vector(dst) || src != irb_int_ptr_type(dst)) res = .NONE_OP;
    if res == .PTRTOINT && (!is_ptr_or_ptr_vector(src) || dst != irb_int_ptr_type(src)) res = .NONE_OP;
    return res;
}

// visitCallInst: InstSimplify (calls with uses), the nounwind inference. Not ported: everything after.
ic_visit_call :: (i: Value_Id) -> Value_Id {
    if has_uses(i) {
        args: [..] Value_Id; args.allocator = temp;
        n := call_num_args(i);
        if n > 0 for k: 0..n-1 array_add(*args, op(i, k));
        v := simplify_call(i, call_callee(i), args, ic_q(i));
        if v != NONE return ic_replace_inst_uses_with(i, v);
    }
    if get_freed_operand(i) != NONE fatal("instcombine: visitFree is not supported yet");
    if fn_has_fn_attr(ic.f, .NoUnwind) && !call_has_fn_attr(i, .NoUnwind) {
        call_add_fn_attr(i, .NoUnwind);
        return i;
    }
    return NONE;
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

// visitReturnInst. Not ported: simplifyNonNullOperand and SimplifyDemandedFPClass (fail loudly when they apply).
ic_visit_return :: (i: Value_Id) -> Value_Id {
    if nops(i) == 0 return NONE;
    rv := op(i, 0);
    rt := vtype(rv);
    f := ic.f;
    ret_attrs := attr_list_ret(glob(f).attrs);
    if is_ptr_type(rt) {
        has_deref := attr_set_has(ret_attrs, .Dereferenceable);
        if attr_set_has(ret_attrs, .NonNull) || (has_deref && !null_pointer_is_defined(f, ir.types[rt].a))
            if !is_const(rv) && !is_argument(rv) fatal("instcombine: simplifyNonNullOperand (nonnull return) is not supported yet");
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

// mergeStoreIntoSuccessor (InstCombineLoadStoreAlloca.cpp)
ic_merge_store_into_successor :: (si: Value_Id) -> bool {
    if !is_unordered(si) return false;
    store_bb := inst_block(si);
    dest := get_successor(block_terminator(store_bb), 0);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(dest, *preds);
    if preds.count != 2 return false;
    other_bb := preds[0];
    if other_bb == store_bb other_bb = preds[1];
    if store_bb == dest || other_bb == dest return false;
    bbi := block_terminator(other_bb);
    if bbi == block_first(other_bb) return false;
    mergeable :: (os: Value_Id, si: Value_Id) -> bool {
        if os == NONE || !is_inst(os) || inst_op(os) != .STORE || op(os, 1) != op(si, 1) return false;
        st := vtype(op(si, 0)); ot := vtype(op(os, 0));
        if st != ot fatal("instcombine: mergeStoreIntoSuccessor with differently typed stores is not supported yet");
        a := inst(si); b := inst(os);
        return (a.flags & F_VOLATILE) == (b.flags & F_VOLATILE) && a.align == b.align && a.ord1 == b.ord1 && a.sync == b.sync;
    }
    other: Value_Id = NONE;
    if inst_op(bbi) == .BR {
        bbi = inst(bbi).prev;
        while is_debug_or_pseudo_inst(bbi) {
            if bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        other = bbi;
        if !mergeable(other, si) return false;
    } else if inst_op(bbi) == .CONDBR {
        if get_successor(bbi, 0) != store_bb && get_successor(bbi, 1) != store_bb return false;
        while true {
            if mergeable(bbi, si) { other = bbi; break; }
            if may_read_from_memory(bbi) || may_throw(bbi) || may_write_to_memory(bbi) || bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        x := block_first(store_bb);
        while x != si {
            if may_read_from_memory(x) || may_throw(x) || may_write_to_memory(x) return false;
            x = inst(x).next;
        }
    } else return false;
    for k: 0..1 {
        s := ifx k == 0 then si else other;
        if get_metadata(s, md_kind_id("tbaa")) != NONE || get_metadata(s, md_kind_id("tbaa.struct")) != NONE ||
           get_metadata(s, md_kind_id("alias.scope")) != NONE || get_metadata(s, md_kind_id("noalias")) != NONE ||
           get_metadata(s, md_kind_id("DIAssignID")) != NONE
            fatal("instcombine: mergeStoreIntoSuccessor with AA metadata or DIAssignID is not supported yet");
    }
    merged_val := op(other, 0);
    merged_loc := merged_debug_loc(get_metadata(si, 0), get_metadata(other, 0));
    if merged_val != op(si, 0) {
        pn := create_phi(vtype(op(si, 0)), 2);
        set_name(pn, "storemerge");
        phi_add_incoming(pn, op(si, 0), inst_block(si));
        icb_set_insert_point(other);
        phi_add_incoming(pn, icb_bit_or_pointer_cast(merged_val, vtype(pn)), other_bb);
        merged_val = ic_insert_new_inst_before(pn, block_first(dest));
        set_metadata(pn, 0, merged_loc);
    }
    pos := block_first_insertion_pt(dest);
    nsi := new_inst(.STORE, ir.t_void, 2);
    set_op(nsi, 0, merged_val); set_op(nsi, 1, op(si, 1));
    r := inst(nsi); src := inst(si);
    r.align = src.align; r.flags = src.flags & cast(u32) F_VOLATILE; r.ord1 = src.ord1; r.sync = src.sync;
    if pos == NONE { ic_link_at_end(nsi, dest); wl_add(nsi); }
    else ic_insert_new_inst_before(nsi, pos);
    set_metadata(nsi, 0, merged_loc);
    ic_erase_inst(si);
    ic_erase_inst(other);
    return true;
}
// CreateBitOrPointerCast
icb_bit_or_pointer_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    if vtype(v) == t return v;
    st := vtype(v);
    if is_ptr_or_ptr_vector(st) && !is_ptr_or_ptr_vector(t) return icb_cast(.PTRTOINT, v, t);
    if !is_ptr_or_ptr_vector(st) && is_ptr_or_ptr_vector(t) return icb_cast(.INTTOPTR, v, t);
    return icb_cast(.BITCAST, v, t);
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
