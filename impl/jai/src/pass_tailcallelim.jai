// TailCallElim: port of llvm/lib/Transforms/Scalar/TailRecursionElimination.cpp (canTRE,
// AllocaDerivedValueTracker, markTails, canMoveAboveCall, canTransformAccumulatorRecursion,
// TailRecursionEliminator, TailCallElimPass::run) and FoldReturnIntoUncondBranch
// (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp). The DomTreeUpdater is eager over the cached DT and PDT
// (Tre_Dtu). Optimization remarks are not emitted.

tre_cl: struct {
    disable_entrycount_recompute := false;   // -tre-disable-entrycount-recompute
};

tre_round :: (x: float64) -> float64 #foreign cfc_libm "round";

// DomTreeUpdater(DT, PDT, Eager)
Tre_Dtu :: struct { dt: *Dom_Tree; pdt: *Dom_Tree; }
tre_dtu_apply :: (d: *Tre_Dtu, updates: [] Dom_Update) {
    if d.dt dt_apply_updates(d.dt, updates);
    if d.pdt dt_apply_updates(d.pdt, updates);
}
tre_dtu_recalculate :: (d: *Tre_Dtu, f: Value_Id) {
    if d.dt dt_recalculate(d.dt, f);
    if d.pdt dt_recalculate(d.pdt, f);
}
tre_dtu_delete_bb :: (d: *Tre_Dtu, bb: Value_Id) {
    validate_delete_bb(bb);
    if d.dt && dt_node(d.dt, bb) >= 0 dt_erase_node(d.dt, bb);
    if d.pdt && dt_node(d.pdt, bb) >= 0 dt_erase_node(d.pdt, bb);
    block_erase_from_parent(bb);
}

// tail call kinds in Inst_Row.flags (printer.jai): 1 tail, 2 musttail, 3 notail
tre_tail_kind :: (ci: Value_Id) -> u32 { return (inst(ci).flags >> TAIL_SHIFT) & 3; }
tre_is_tail_call :: (ci: Value_Id) -> bool { k := tre_tail_kind(ci); return k == 1 || k == 2; }
tre_set_tail_call :: (ci: Value_Id) { inst(ci).flags = (inst(ci).flags & ~(cast(u32) 3 << TAIL_SHIFT)) | (cast(u32) 1 << TAIL_SHIFT); }

// AllocaDerivedValueTracker
Tre_Tracker :: struct {
    alloca_users: Table(Value_Id, bool);
    escape_points: Table(Value_Id, bool);
}

tre_call_uses_local_stack :: (t: *Tre_Tracker, cb: Value_Id, is_nocapture: bool) {
    table_set(*t.alloca_users, cb, true);
    if is_nocapture return;
    if !call_only_reads_memory(cb) table_set(*t.escape_points, cb, true);
}

tre_walk :: (t: *Tre_Tracker, root: Value_Id) {
    wl: [..] Use_Id; wl.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    add_uses :: (v: Value_Id) #expand {
        u := ir.v_first_use[v];
        while u != NONE {
            if !table_contains(*visited, u) { table_set(*visited, u, true); array_add(*wl, u); }
            u = ir.u_next[u];
        }
    }
    add_uses(root);
    while wl.count {
        u := pop(*wl);
        i := ir.u_user[u];
        opno := u - ir.v_ops[i];
        o := inst_op(i);
        if o == .CALL || o == .INVOKE {
            nargs := call_num_args(i);
            if opno < nargs && call_is_byval_arg(i, opno) continue;
            // isDataOperand: an argument or a bundle operand (everything before the callee / successors)
            n_data := cast(u32) (cast(s64) nargs + call_num_bundle_operands(i));
            is_nocapture := opno < n_data && call_does_not_capture(i, opno);
            tre_call_uses_local_stack(t, i, is_nocapture);
            if is_nocapture continue;
        } else if o == .LOAD {
            continue;
        } else if o == .STORE {
            if opno == 0 table_set(*t.escape_points, i, true);
            continue;
        } else if o == .BITCAST || o == .GEP || o == .PHI || o == .SELECT || o == .ADDRSPACECAST {
        } else {
            table_set(*t.escape_points, i, true);
        }
        add_uses(i);
    }
}

tre_calls_function_that_returns_twice :: (f: Value_Id) -> bool {
    for i: fn_insts(f) if is_call_base(i) && call_has_fn_attr(i, .ReturnsTwice) return true;
    return false;
}

tre_mark_tails :: (f: Value_Id) -> bool {
    if tre_calls_function_that_returns_twice(f) return false;
    t: Tre_Tracker;
    t.alloca_users.allocator = temp; t.escape_points.allocator = temp;
    for k: 0..cast(s64) fn_nargs(f) - 1 {
        a := fn_arg(f, cast(u32) k);
        if arg_has_attr(a, .ByVal) tre_walk(*t, a);
    }
    for i: fn_insts(f) if inst_op(i) == .ALLOCA tre_walk(*t, i);

    modified := false;
    UNVISITED :: 0; UNESCAPED :: 1; ESCAPED :: 2;
    visited: Table(Value_Id, u8); visited.allocator = temp;
    visit_get :: (b: Value_Id) -> *u8 #expand {
        p := table_find_pointer(*visited, b);
        if !p { table_set(*visited, b, UNVISITED); p = table_find_pointer(*visited, b); }
        return p;
    }
    wl_unescaped: [..] Value_Id; wl_unescaped.allocator = temp;
    wl_escaped: [..] Value_Id; wl_escaped.allocator = temp;
    deferred: [..] Value_Id; deferred.allocator = temp;
    bb := fn_entry(f);
    escaped: u8 = UNESCAPED;
    while bb != NONE {
        for i: block_insts(bb) {
            if table_contains(*t.escape_points, i) escaped = ESCAPED;
            if inst_op(i) != .CALL || tre_is_tail_call(i) || call_iid(i) == IID_PSEUDOPROBE continue;
            if call_iid(i) == IID_STACKRESTORE continue;
            is_no_tail := tre_tail_kind(i) == 3 || call_has_bundles_other_than(i, .["clang.arc.attachedcall", "ptrauth", "kcfi"]);
            if !is_no_tail && call_memory_effects(i) == ME_NONE {
                // LLVM checks isa<Constant>/isa<Argument> of Arg.getUser(), which is the call itself: only a call
                // without arguments is safe here
                if call_num_args(i) == 0 {
                    tre_set_tail_call(i);
                    modified = true;
                    continue;
                }
            }
            if !is_no_tail && escaped == UNESCAPED && !table_contains(*t.alloca_users, i) array_add(*deferred, i);
        }
        succs: [..] Value_Id; succs.allocator = temp;
        block_successors(bb, *succs);
        for s: succs {
            state := visit_get(s);
            if state.* < escaped {
                state.* = escaped;
                if escaped == ESCAPED array_add(*wl_escaped, s); else array_add(*wl_unescaped, s);
            }
        }
        if wl_escaped.count {
            bb = pop(*wl_escaped);
            escaped = ESCAPED;
        } else {
            bb = NONE;
            while wl_unescaped.count {
                nb := pop(*wl_unescaped);
                if visit_get(nb).* == UNESCAPED { bb = nb; escaped = UNESCAPED; break; }
            }
        }
    }
    for ci: deferred {
        if visit_get(inst_block(ci)).* != ESCAPED {
            tre_set_tail_call(ci);
            modified = true;
        }
    }
    return modified;
}

tre_can_move_above_call :: (i: Value_Id, ci: Value_Id, aar: *Aa_Results) -> bool {
    if call_iid(i) == IID_LIFETIME_END return true;
    if may_have_side_effects(i) return false;
    if inst_op(i) == .LOAD {
        if may_have_side_effects(ci) {
            if aa_mod_ref_inst_loc(aa_query_new(aar), ci, mloc_get(i)) & MR_MOD return false;
            if !ld_is_safe_to_load_unconditionally_ty(op(i, 0), vtype(i), inst(i).align, i) return false;
        }
    }
    for k: 0..cast(s64) nops(i) - 1 if op(i, cast(u32) k) == ci return false;
    return true;
}

// Instruction::isAssociative (IntrinsicInst::isAssociative for intrinsic calls)
tre_is_associative :: (i: Value_Id) -> bool {
    id := call_iid(i);
    if id != NOT_INTRINSIC return id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN;
    if is_call_base(i) return false;
    return inst_is_associative(i);
}
// ConstantExpr::getIntrinsicIdentity
tre_intrinsic_identity :: (id: Intrinsic_Id, t: Type_Id) -> Value_Id {
    bits := type_bits(scalar_type(t));
    if id == IID_UMAX return const_null_value(t);
    if id == IID_UMIN return cf_all_ones(t);
    if id == IID_SMAX return const_int_ap(t, ap_signed_min(bits));
    if id == IID_SMIN return const_int_ap(t, ap_signed_max(bits));
    return NONE;
}
// ConstantExpr::getIdentity(I, Ty) (AllowRHSConstant = false, NSZ = false)
tre_identity :: (i: Value_Id, t: Type_Id) -> Value_Id {
    if is_binary_op(inst_op(i)) return cf_binop_identity(inst_op(i), t, false);
    id := call_iid(i);
    if id != NOT_INTRINSIC return tre_intrinsic_identity(id, t);
    return NONE;
}

tre_can_transform_accumulator_recursion :: (i: Value_Id, ci: Value_Id) -> bool {
    if !tre_is_associative(i) || !inst_is_commutative(i) return false;
    id := call_iid(i);
    if id != NOT_INTRINSIC && tre_intrinsic_identity(id, vtype(i)) == NONE return false;
    a := op(i, 0) == ci; b := op(i, 1) == ci;
    if a == b return false;
    if !has_one_use(i) return false;
    usr := ir.u_user[ir.v_first_use[i]];
    return is_inst(usr) && inst_op(usr) == .RET;
}

Tre :: struct {
    f: Value_Id;
    aar: Aa_Results;
    dtu: Tre_Dtu;
    bfi: *Bfi;
    orig_entry_bb_freq: u64;
    orig_entry_count: u64;
    header_bb: Value_Id = NONE;
    argument_phis: [..] Value_Id;
    ret_pn: Value_Id = NONE;
    ret_known_pn: Value_Id = NONE;
    ret_selects: [..] Value_Id;
    acc_pn: Value_Id = NONE;
    acc_rec_instr: Value_Id = NONE;
}

tre_find_candidate :: (s: *Tre, bb: Value_Id) -> Value_Id {
    ti := block_terminator(bb);
    if block_first(bb) == ti return NONE;
    ci := ti;
    while true {
        if inst_op(ci) == .CALL && call_called_function(ci) == s.f break;
        if ci == block_first(bb) return NONE;
        ci = inst_prev(ci);
    }
    if !tre_is_tail_call(ci) return NONE;
    callee := call_called_function(ci);
    if bb == fn_entry(s.f) && block_first(bb) == ci && inst_next(ci) == ti && callee != NONE && !tti_is_lowered_to_call(callee) {
        na := call_num_args(ci); nf := fn_nargs(s.f);
        k: u32 = 0;
        while k < na && k < nf { if op(ci, k) != fn_arg(s.f, k) break; k += 1; }
        if k == na && k == nf return NONE;
    }
    return ci;
}

tre_create_header :: (s: *Tre, ci: Value_Id) {
    f := s.f;
    s.header_bb = fn_entry(f);
    new_entry := create_block(f, "", s.header_bb);
    take_name(new_entry, s.header_bb);
    set_name(s.header_bb, "tailrecurse");
    bi := create_br(s.header_bb);
    block_append_inst(new_entry, bi);   // no debug location (DebugLoc::getCompilerGenerated)
    // move the fixed-size allocas to NewEntry (before the branch, NEBI = NewEntry->begin())
    x := block_first(s.header_bb);
    while x != NONE {
        nx := inst_next(x);
        if inst_op(x) == .ALLOCA && vkind(op(x, 0)) == .C_INT iv_move_before_head(x, bi, new_entry);
        x = nx;
    }
    insert_pos := block_first(s.header_bb);
    for k: 0..cast(s64) fn_nargs(f) - 1 {
        a := fn_arg(f, cast(u32) k);
        pn := create_phi(vtype(a), 2);
        insert_at_position(pn, s.header_bb, insert_pos, true);
        set_name(pn, tconcat(vname(a), ".tr"));
        rauw_with_metadata(a, pn);
        phi_add_incoming(pn, a, new_entry);
        array_add(*s.argument_phis, pn);
    }
    rt := func_ret(glob(f).value_type);
    if rt != ir.t_void {
        s.ret_pn = create_phi(rt, 2);
        insert_at_position(s.ret_pn, s.header_bb, insert_pos, true);
        set_name(s.ret_pn, "ret.tr");
        s.ret_known_pn = create_phi(ir.t_i1, 2);
        insert_at_position(s.ret_known_pn, s.header_bb, insert_pos, true);
        set_name(s.ret_known_pn, "ret.known.tr");
        phi_add_incoming(s.ret_pn, const_poison(rt), new_entry);
        phi_add_incoming(s.ret_known_pn, const_int(ir.t_i1, 0), new_entry);
    }
    tre_dtu_recalculate(*s.dtu, f);
}

tre_insert_accumulator :: (s: *Tre, acc: Value_Id) {
    s.acc_rec_instr = acc;
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(s.header_bb, *preds);
    s.acc_pn = create_phi(func_ret(glob(s.f).value_type), cast(u32) preds.count + 1);
    insert_at_position(s.acc_pn, s.header_bb, block_first(s.header_bb), true);
    set_name(s.acc_pn, "accumulator.tr");
    for p: preds {
        if p == fn_entry(s.f) phi_add_incoming(s.acc_pn, tre_identity(acc, vtype(acc)), p);
        else phi_add_incoming(s.acc_pn, s.acc_pn, p);
    }
}

tre_copy_byval_into_temp :: (s: *Tre, ci: Value_Id, k: u32) {
    agg := call_param_byval_type(ci, k);
    align := max(call_param_align(ci, k), 1);
    a := create_alloca_unlinked(agg, dl_alloca_addrspace(), align);
    entry := fn_entry(s.f);
    insert_at_position(a, entry, block_first(entry), true);   // F.getEntryBlock().begin()
    set_name(a, vname(op(ci, k)));
    b: Irb; irb_set_before(*b, ci);
    size := const_int(type_int(64), dl_type_alloc_size(agg));
    irb_memcpy(*b, a, align, op(ci, k), align, size, false);
    set_op(ci, k, a);
}
tre_copy_temp_into_argument :: (s: *Tre, ci: Value_Id, k: u32) {
    agg := call_param_byval_type(ci, k);
    align := max(call_param_align(ci, k), 1);
    b: Irb; irb_set_before(*b, ci);
    size := const_int(type_int(64), dl_type_alloc_size(agg));
    irb_memcpy(*b, fn_arg(s.f, k), align, op(ci, k), align, size, false);
}

tre_fn_remove_param_attr :: (f: Value_Id, k: u32, kind: Attr_Kind) {
    l := glob(f).attrs;
    np := fn_nargs(f);
    ps := NewArray(cast(s64) np, u32,, allocator = temp);
    for x: 0..cast(s64) np - 1 ps[x] = attr_list_param(l, cast(u32) x);
    if !attr_set_has(ps[k], kind) return;
    ps[k] = attr_set_remove(ps[k], kind);
    glob(f).attrs = attr_list_get(attr_list_fn(l), attr_list_ret(l), ps);
}

tre_eliminate_call :: (s: *Tre, ci: Value_Id) -> bool {
    ret := block_terminator(inst_block(ci));
    acc: Value_Id = NONE;
    x := inst_next(ci);
    while x != ret {
        defer x = inst_next(x);
        if tre_can_move_above_call(x, ci, *s.aar) continue;
        if s.acc_pn != NONE || !tre_can_transform_accumulator_recursion(x, ci) return false;
        acc = x;
    }
    bb := inst_block(ret);
    if s.header_bb == NONE tre_create_header(s, ci);
    na := call_num_args(ci);
    for k: 0..cast(s64) na - 1 if call_is_byval_arg(ci, cast(u32) k) tre_copy_byval_into_temp(s, ci, cast(u32) k);
    for k: 0..cast(s64) na - 1 {
        kk := cast(u32) k;
        if call_is_byval_arg(ci, kk) {
            tre_copy_temp_into_argument(s, ci, kk);
            tre_fn_remove_param_attr(s.f, kk, .ReadOnly);
            phi_add_incoming(s.argument_phis[k], fn_arg(s.f, kk), bb);
        } else phi_add_incoming(s.argument_phis[k], op(ci, kk), bb);
    }
    if acc != NONE {
        tre_insert_accumulator(s, acc);
        set_op(acc, ifx op(acc, 0) != ci then cast(u32) 1 else 0, s.acc_pn);
        drop_poison_generating_annotations(acc);
    }
    if s.ret_pn != NONE {
        rv := ifx nops(ret) > 0 then op(ret, 0) else NONE;
        if rv == ci || acc != NONE {
            phi_add_incoming(s.ret_pn, s.ret_pn, bb);
            phi_add_incoming(s.ret_known_pn, s.ret_known_pn, bb);
        } else {
            si := create_select(s.ret_known_pn, s.ret_pn, rv);
            insert_at_position(si, bb, ret, false);
            set_name(si, "current.ret.tr");
            copy_debug_loc(si, ret);
            array_add(*s.ret_selects, si);
            phi_add_incoming(s.ret_pn, si, bb);
            phi_add_incoming(s.ret_known_pn, const_int(ir.t_i1, 1), bb);
        }
        if s.acc_pn != NONE phi_add_incoming(s.acc_pn, ifx acc != NONE then acc else s.acc_pn, bb);
    }
    nbi := create_br(s.header_bb);
    insert_at_position(nbi, bb, ret, false);
    copy_debug_loc(nbi, ci);
    erase_inst_with_metadata(ret);
    erase_inst_with_metadata(ci);
    tre_dtu_apply(*s.dtu, .[.{true, bb, s.header_bb}]);
    if s.orig_entry_bb_freq != 0 {
        rel := cast(float64) bfi_get_block_freq(s.bfi, bb) / cast(float64) s.orig_entry_bb_freq;
        to_subtract := cast(u64) tre_round(rel * cast(float64) s.orig_entry_count);
        _, old := function_entry_count(s.f);
        if old > to_subtract fn_set_entry_count(s.f, old - to_subtract);
    }
    return true;
}

tre_cleanup_and_finalize :: (s: *Tre) {
    for pn: s.argument_phis {
        q: Simplify_Query; q.have_tli = false; q.no_tli_libcalls = true;
        v := simplify_instruction(pn, sq_with_instruction(q, pn));
        if v != NONE {
            rauw_with_metadata(pn, v);
            erase_inst_with_metadata(pn);
        }
    }
    if s.ret_pn == NONE return;
    clone_acc :: (s: *Tre, other: Value_Id, before: Value_Id) -> Value_Id {
        a := s.acc_rec_instr;
        n := ic_clone_inst(a);
        set_op(n, ifx op(a, 0) == s.acc_pn then cast(u32) 1 else 0, other);
        insert_at_position(n, inst_block(before), before, false);
        set_name(n, "accumulator.ret.tr");
        drop_location(n);
        return n;
    }
    if s.ret_selects.count == 0 {
        drop_all_references(s.ret_pn); erase_inst_with_metadata(s.ret_pn);
        drop_all_references(s.ret_known_pn); erase_inst_with_metadata(s.ret_known_pn);
        if s.acc_pn != NONE {
            for bb: fn_blocks(s.f) {
                ri := block_terminator(bb);
                if ri == NONE || inst_op(ri) != .RET continue;
                n := clone_acc(s, op(ri, 0), ri);
                set_op(ri, 0, n);
            }
        }
    } else {
        for bb: fn_blocks(s.f) {
            ri := block_terminator(bb);
            if ri == NONE || inst_op(ri) != .RET continue;
            si := create_select(s.ret_known_pn, s.ret_pn, op(ri, 0));
            insert_at_position(si, bb, ri, false);
            set_name(si, "current.ret.tr");
            set_metadata(si, 0, NONE);
            array_add(*s.ret_selects, si);
            set_op(ri, 0, si);
        }
        if s.acc_pn != NONE {
            for si: s.ret_selects {
                n := clone_acc(s, op(si, 2), si);
                set_op(si, 2, n);
            }
        }
    }
}

// FoldReturnIntoUncondBranch(RI, BB, Pred, DTU)
tre_fold_return_into_uncond_branch :: (ri: Value_Id, bb: Value_Id, pred: Value_Id, dtu: *Tre_Dtu) -> Value_Id {
    uncond := block_terminator(pred);
    new_ret := ic_clone_inst(ri);
    block_append_inst(pred, new_ret);
    for k: 0..cast(s64) nops(new_ret) - 1 {
        kk := cast(u32) k;
        v := op(new_ret, kk);
        new_bc: Value_Id = NONE;
        if is_inst(v) && inst_op(v) == .BITCAST {
            v = op(v, 0);
            new_bc = ic_clone_inst(op(new_ret, kk));
            insert_at_position(new_bc, pred, new_ret, false);
            set_op(new_ret, kk, new_bc);
        }
        new_ev: Value_Id = NONE;
        if is_inst(v) && inst_op(v) == .EXTRACTVALUE {
            evi := v;
            v = op(evi, 0);
            new_ev = ic_clone_inst(evi);
            if new_bc != NONE {
                set_op(new_bc, 0, new_ev);
                insert_at_position(new_ev, pred, new_bc, false);
            } else {
                insert_at_position(new_ev, pred, new_ret, false);
                set_op(new_ret, kk, new_ev);
            }
        }
        if is_phi(v) && inst_block(v) == bb {
            iv := phi_incoming_value_for_block(v, pred);
            if new_ev != NONE set_op(new_ev, 0, iv);
            else if new_bc != NONE set_op(new_bc, 0, iv);
            else set_op(new_ret, kk, iv);
        }
    }
    block_remove_predecessor(bb, pred);
    erase_inst_with_metadata(uncond);
    tre_dtu_apply(dtu, .[.{false, pred, bb}]);
    return new_ret;
}

tre_process_block :: (s: *Tre, bb: Value_Id) -> bool {
    ti := block_terminator(bb);
    if inst_op(ti) == .BR {
        succ := get_successor(ti, 0);
        r := block_first_non_phi_or_dbg_skip_pseudo(succ);
        if r == NONE || inst_op(r) != .RET return false;
        ci := tre_find_candidate(s, bb);
        if ci == NONE return false;
        tre_fold_return_into_uncond_branch(r, succ, bb, *s.dtu);
        if !block_has_predecessors(succ) tre_dtu_delete_bb(*s.dtu, succ);
        tre_eliminate_call(s, ci);
        return true;
    } else if inst_op(ti) == .RET {
        ci := tre_find_candidate(s, bb);
        if ci != NONE return tre_eliminate_call(s, ci);
    }
    return false;
}

tailcallelim_run :: (f: Value_Id) -> Preserved {
    aar := aa_results_for(f);
    has_count, count := function_entry_count(f);
    bfi: *Bfi = null;
    if !tre_cl.disable_entrycount_recompute && has_count && count != 0 bfi = get_bfi(f);
    s: Tre;
    s.f = f; s.aar = aar; s.bfi = bfi;
    s.dtu.dt = cached_domtree(f);
    s.dtu.pdt = cached_postdomtree(f);
    s.argument_phis.allocator = temp; s.ret_selects.allocator = temp;
    changed := false;
    if fn_str_attr_bool(f, "disable-tail-calls") return PRESERVE_ALL;
    changed |= tre_mark_tails(f);
    if !func_vararg(glob(f).value_type) {
        can_tre := true;
        for i: fn_insts(f) if inst_op(i) == .ALLOCA && !alloca_is_static(i) { can_tre = false; break; }
        if can_tre {
            if bfi { s.orig_entry_bb_freq = bfi_get_block_freq(bfi, fn_entry(f)); s.orig_entry_count = count; }
            bb := fn_entry(f);
            while bb != NONE {
                if tre_process_block(*s, bb) changed = true;
                bb = block(bb).next;
            }
            tre_cleanup_and_finalize(*s);
        }
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .POSTDOMTREE);
    return pa;
}
