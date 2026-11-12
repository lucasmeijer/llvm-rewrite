// LoopStrengthReduce, part 3: port of llvm/lib/Transforms/Scalar/LoopStrengthReduce.cpp: IV chains (findIVOperand,
// getWideOperand, getExprBase, IVChain::isProfitableIncrement, isProfitableChain, ChainInstruction, CollectChains,
// FinalizeChain, canFoldIVIncExpr, GenerateIVChain), CollectFixupsAndInitialFormulae, InsertInitialFormula,
// InsertSupplementalFormula, CountRegisters, InsertFormula, IsFixupExecutedEachIncrement,
// CollectLoopInvariantFixupsAndFormulae.

Lsr_Iv_Inc :: struct { user_inst: Value_Id; iv_operand: Value_Id; inc_expr: Scev_Id; }
Lsr_Iv_Chain :: struct { incs: [..] Lsr_Iv_Inc; expr_base: Scev_Id = SCEV_NULL; }
Lsr_Chain_Users :: struct { far_users: [..] Value_Id; near_users: [..] Value_Id; }

// findIVOperand: the first operand index >= from computed by an AddRec of L (nops = none)
lsr_find_iv_operand :: (i: Value_Id, from: u32) -> u32 {
    n := nops(i);
    k := from;
    while k < n {
        o := op(i, k);
        if is_inst(o) && sc_is_scevable(vtype(o)) {
            ar := sc_get_scev(o);
            if sc_kind(ar) == .ADDREC && sc_loop(ar) == lsr.l break;
        }
        k += 1;
    }
    return k;
}
lsr_get_wide_operand :: (o: Value_Id) -> Value_Id {
    if is_inst(o) && inst_op(o) == .TRUNC return op(o, 0);
    return o;
}
// getExprBase
lsr_get_expr_base :: (s: Scev_Id) -> Scev_Id {
    k := sc_kind(s);
    if k == .CONSTANT || k == .VSCALE return SCEV_NULL;
    if k == .TRUNC || k == .ZEXT || k == .SEXT return lsr_get_expr_base(sc_op(s, 0));
    if k == .ADD {
        i := cast(s64) sc_nops(s) - 1;
        while i >= 0 {
            sub := sc_op(s, cast(u32) i);
            if sc_kind(sub) == .ADD return lsr_get_expr_base(sub);
            if sc_kind(sub) != .MUL return sub;
            i -= 1;
        }
        return s;
    }
    if k == .ADDREC return lsr_get_expr_base(sc_start(s));
    return s;
}
// IVChain::isProfitableIncrement
lsr_chain_is_profitable_increment :: (c: *Lsr_Iv_Chain, oper_expr: Scev_Id, inc_expr: Scev_Id) -> bool {
    if !sc_is_const(inc_expr) {
        head_expr := sc_get_scev(lsr_get_wide_operand(c.incs[0].iv_operand));
        if sc_is_const(sc_get_minus(oper_expr, head_expr)) return false;
    }
    processed: Table(Scev_Id, bool); processed.allocator = temp;
    return !lsr_is_high_cost_expansion(inc_expr, *processed);
}
// isProfitableChain (TTI.isProfitableLSRChainElement: false on X86)
lsr_is_profitable_chain :: (c: *Lsr_Iv_Chain, users: [] Value_Id) -> bool {
    if c.incs.count < 2 return false;
    if users.count return false;
    cost := 1;
    tail := c.incs[c.incs.count - 1].user_inst;
    if is_phi(tail) && sc_get_scev(tail) == c.incs[0].inc_expr cost -= 1;
    last_inc_expr: Scev_Id = SCEV_NULL;
    num_const := 0; num_var := 0; num_reused := 0;
    for k: 1..c.incs.count-1 {
        inc := c.incs[k];
        if sc_is_zero(inc.inc_expr) continue;
        if sc_is_const(inc.inc_expr) { num_const += 1; continue; }
        if inc.inc_expr == last_inc_expr num_reused += 1;
        else num_var += 1;
        last_inc_expr = inc.inc_expr;
    }
    if num_const > 1 cost -= 1;
    cost += num_var;
    cost -= num_reused;
    return cost < 0;
}

// ChainInstruction
lsr_chain_instruction :: (user_inst: Value_Id, iv_oper: Value_Id, chain_users: *[..] Lsr_Chain_Users) {
    next_iv := lsr_get_wide_operand(iv_oper);
    oper_expr := sc_get_scev(next_iv);
    oper_expr_base := lsr_get_expr_base(oper_expr);
    chain_idx := 0;
    n_chains := lsr.iv_chain_vec.count;
    last_inc_expr: Scev_Id = SCEV_NULL;
    while chain_idx < n_chains {
        c := *lsr.iv_chain_vec[chain_idx];
        found := false;
        while true {
            if c.expr_base != oper_expr_base break;
            prev_iv := lsr_get_wide_operand(c.incs[c.incs.count - 1].iv_operand);
            if vtype(prev_iv) != vtype(next_iv) break;
            if is_phi(user_inst) && is_phi(c.incs[c.incs.count - 1].user_inst) break;
            prev_expr := sc_get_scev(prev_iv);
            inc_expr := sc_get_minus(oper_expr, prev_expr);
            if sc_is_cnc(inc_expr) || !sc_is_loop_invariant(inc_expr, lsr.l) break;
            if lsr_chain_is_profitable_increment(c, oper_expr, inc_expr) {
                last_inc_expr = inc_expr;
                found = true;
            }
            break;
        }
        if found break;
        chain_idx += 1;
    }
    if chain_idx == n_chains {
        if is_phi(user_inst) return;
        if n_chains >= LSR_MAX_CHAINS return;
        last_inc_expr = oper_expr;
        if sc_kind(last_inc_expr) != .ADDREC return;
        n_chains += 1;
        nc: Lsr_Iv_Chain;
        nc.incs.allocator = temp;
        array_add(*nc.incs, .{user_inst, iv_oper, last_inc_expr});
        nc.expr_base = oper_expr_base;
        array_add(*lsr.iv_chain_vec, nc);
        while chain_users.count < n_chains {
            cu: Lsr_Chain_Users; cu.far_users.allocator = temp; cu.near_users.allocator = temp;
            array_add(chain_users, cu);
        }
    } else {
        array_add(*lsr.iv_chain_vec[chain_idx].incs, .{user_inst, iv_oper, last_inc_expr});
    }
    c := *lsr.iv_chain_vec[chain_idx];
    cu := *chain_users.*[chain_idx];
    if !sc_is_zero(last_inc_expr) {
        for cu.near_users lsr_set_insert_v(*cu.far_users, it);
        cu.near_users.count = 0;
    }
    u := ir.v_first_use[iv_oper];
    while u != NONE {
        other := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(other) continue;
        in_chain := false;
        for c.incs if it.user_inst == other { in_chain = true; break; }
        if in_chain continue;
        if sc_is_scevable(vtype(other)) && sc_kind(sc_get_scev(other)) != .UNKNOWN && table_contains(*lsr.iu.processed, other) continue;
        lsr_set_insert_v(*cu.near_users, other);
    }
    for cu.far_users if it == user_inst { array_ordered_remove_by_index(*cu.far_users, it_index); break; }
}

// CollectChains
lsr_collect_chains :: () {
    chain_users: [..] Lsr_Chain_Users; chain_users.allocator = temp;
    latch_path: [..] Value_Id; latch_path.allocator = temp;
    header := li_header(lsr.li, lsr.l);
    rung := dt_node(lsr.dt, li_loop_latch(lsr.li, lsr.l));
    while lsr.dt.nodes[rung].block != header {
        array_add(*latch_path, lsr.dt.nodes[rung].block);
        rung = dt_idom(lsr.dt, rung);
    }
    array_add(*latch_path, header);
    k := latch_path.count - 1;
    while k >= 0 {
        bb := latch_path[k];
        k -= 1;
        for i: block_insts(bb) {
            if inst_op(i) == .PHI || !table_contains(*lsr.iu.processed, i) continue;
            if table_contains(*lsr.iu.eph, i) continue;
            if sc_is_scevable(vtype(i)) && sc_kind(sc_get_scev(i)) != .UNKNOWN continue;
            for * cu: chain_users {
                for cu.near_users if it == i { array_ordered_remove_by_index(*cu.near_users, it_index); break; }
            }
            unique_ops: [..] Value_Id; unique_ops.allocator = temp;
            n := nops(i);
            opi := lsr_find_iv_operand(i, 0);
            while opi < n {
                iv_op_inst := op(i, opi);
                if lsr_set_insert_v(*unique_ops, iv_op_inst) lsr_chain_instruction(i, iv_op_inst, *chain_users);
                opi = lsr_find_iv_operand(i, opi + 1);
            }
        }
    }
    latch := li_loop_latch(lsr.li, lsr.l);
    for pn: block_insts(header) {
        if inst_op(pn) != .PHI break;
        if !sc_is_scevable(vtype(pn)) continue;
        inc_v := phi_incoming_value_for_block(pn, latch);
        if is_inst(inc_v) lsr_chain_instruction(pn, inc_v, *chain_users);
    }
    chain_idx := 0;
    for users_idx: 0..lsr.iv_chain_vec.count-1 {
        if !lsr_is_profitable_chain(*lsr.iv_chain_vec[users_idx], chain_users[users_idx].far_users) continue;
        if chain_idx != users_idx lsr.iv_chain_vec[chain_idx] = lsr.iv_chain_vec[users_idx];
        lsr_finalize_chain(*lsr.iv_chain_vec[chain_idx]);
        chain_idx += 1;
    }
    lsr.iv_chain_vec.count = chain_idx;
}

// FinalizeChain: IVIncSet gets the Use of each increment's IV operand (the first operand slot holding it)
lsr_finalize_chain :: (c: *Lsr_Iv_Chain) {
    for k: 1..c.incs.count-1 {
        inc := c.incs[k];
        n := nops(inc.user_inst);
        for j: 0..cast(s64) n - 1 {
            if op(inc.user_inst, cast(u32) j) == inc.iv_operand {
                u := ir.v_ops[inc.user_inst] + cast(u32) j;
                found := false;
                for lsr.iv_inc_set if it == u { found = true; break; }
                if !found array_add(*lsr.iv_inc_set, u);
                break;
            }
        }
    }
}

// canFoldIVIncExpr
lsr_can_fold_iv_inc_expr :: (inc_expr: Scev_Id, user_inst: Value_Id, operand: Value_Id) -> bool {
    inc_offset := IMM_ZERO;
    if sc_is_const(inc_expr) {
        if ap_significant_bits(sc_ap(inc_expr)) > 64 return false;
        inc_offset = imm_fixed(ap_sext_value(sc_ap(inc_expr)));
    } else {
        // mul(vscale, constant): no vscale on X86
        return false;
    }
    if !lsr_is_address_use(user_inst, operand) return false;
    at := lsr_get_access_type(user_inst, operand);
    if !lsr_is_always_foldable(.ADDRESS, at, NONE, inc_offset, false) return false;
    return true;
}

// GenerateIVChain
lsr_generate_iv_chain :: (c: *Lsr_Iv_Chain, dead_insts: *[..] Vh) {
    head := c.incs[0];
    n := nops(head.user_inst);
    opi := lsr_find_iv_operand(head.user_inst, 0);
    iv_src: Value_Id = NONE;
    while opi < n {
        iv_src = lsr_get_wide_operand(op(head.user_inst, opi));
        if sc_get_scev(op(head.user_inst, opi)) == head.inc_expr || sc_get_scev(iv_src) == head.inc_expr break;
        opi = lsr_find_iv_operand(head.user_inst, opi + 1);
    }
    if opi == n return;
    iv_ty := vtype(iv_src);
    int_ty := sc_effective_type(iv_ty);
    left_over: Scev_Id = SCEV_NULL;
    accum := sc_get_zero(int_ty);
    Base :: struct { s: Scev_Id; v: Value_Id; }
    bases: [..] Base; bases.allocator = temp;
    array_add(*bases, .{accum, iv_src});
    x := *lsr.rewriter;
    for k: 1..c.incs.count-1 {
        inc := c.incs[k];
        insert_pt := inc.user_inst;
        if is_phi(insert_pt) insert_pt = block_terminator(li_loop_latch(lsr.li, lsr.l));
        iv_oper := iv_src;
        if !sc_is_zero(inc.inc_expr) {
            ie := sc_get_noop_or_sign_extend(inc.inc_expr, int_ty);
            accum = sc_get_add2(accum, ie);
            left_over = ifx left_over != SCEV_NULL then sc_get_add2(left_over, ie) else ie;
        }
        found_base := false;
        bi := bases.count - 1;
        while bi >= 0 {
            b := bases[bi];
            bi -= 1;
            remainder := sc_get_minus(accum, b.s);
            if lsr_can_fold_iv_inc_expr(remainder, inc.user_inst, inc.iv_operand) {
                if !sc_is_zero(remainder) {
                    sx_clear_post_inc(x);
                    inc_v := sx_expand_code_for_at(x, remainder, int_ty, insert_pt);
                    iv_oper_expr := sc_get_add2(sc_get_unknown(b.v), sc_get_unknown(inc_v));
                    iv_oper = sx_expand_code_for_at(x, iv_oper_expr, iv_ty, insert_pt);
                } else iv_oper = b.v;
                found_base = true;
                break;
            }
        }
        if !found_base && left_over != SCEV_NULL && !sc_is_zero(left_over) {
            sx_clear_post_inc(x);
            inc_v := sx_expand_code_for_at(x, left_over, int_ty, insert_pt);
            iv_oper_expr := sc_get_add2(sc_get_unknown(iv_src), sc_get_unknown(inc_v));
            iv_oper = sx_expand_code_for_at(x, iv_oper_expr, iv_ty, insert_pt);
            if !lsr_can_fold_iv_inc_expr(left_over, inc.user_inst, inc.iv_operand) {
                array_add(*bases, .{accum, iv_oper});
                iv_src = iv_oper;
                left_over = SCEV_NULL;
            }
        }
        oper_ty := vtype(inc.iv_operand);
        if iv_ty != oper_ty {
            b: Irb; irb_set_before(*b, insert_pt);
            // CreateTruncOrBitCast
            opc := ifx type_bits(scalar_type(iv_ty)) == type_bits(scalar_type(oper_ty)) then Opcode.BITCAST else .TRUNC;
            iv_oper = irb_cast(*b, opc, iv_oper, oper_ty, "lsr.chain");
        }
        replace_uses_of_with(inc.user_inst, inc.iv_operand, iv_oper);
        if is_inst(inc.iv_operand) array_add(dead_insts, vh_new(inc.iv_operand));
    }
    tail := c.incs[c.incs.count - 1].user_inst;
    if is_phi(tail) {
        latch := li_loop_latch(lsr.li, lsr.l);
        for phi: block_insts(li_header(lsr.li, lsr.l)) {
            if inst_op(phi) != .PHI break;
            if vtype(phi) != vtype(iv_src) continue;
            post_inc_v := phi_incoming_value_for_block(phi, latch);
            if !is_inst(post_inc_v) || sc_get_scev(post_inc_v) != sc_get_scev(iv_src) continue;
            iv_oper := iv_src;
            post_inc_ty := vtype(post_inc_v);
            if iv_ty != post_inc_ty {
                b: Irb; irb_set_before(*b, block_terminator(latch));
                b.dbg = get_metadata(post_inc_v, 0);
                iv_oper = cgp_create_pointer_cast(*b, iv_src, post_inc_ty, "lsr.chain");
            }
            replace_uses_of_with(phi, post_inc_v, iv_oper);
            array_add(dead_insts, vh_new(post_inc_v));
        }
    }
}

// ---------------------------------------------------------------- fixups and formulae

// CollectFixupsAndInitialFormulae
lsr_collect_fixups_and_initial_formulae :: () {
    // TTI.canSaveCmp: false (no X86 override)
    regs: [..] Scev_Id; regs.allocator = temp;
    visited_regs: Table(Scev_Id, bool); visited_regs.allocator = temp;
    visited_lsr_use: Table(s64, bool); visited_lsr_use.allocator = temp;
    ui := 0;
    while ui < lsr.iu.uses.count {
        u := *lsr.iu.uses[ui];
        ui += 1;
        if !iu_live(u) continue;
        user_inst := u.user;
        // find(UserInst->operands(), OperandValToReplace)
        use_i: Use_Id = NONE;
        for j: 0..cast(s64) nops(user_inst) - 1 if op(user_inst, cast(u32) j) == u.operand { use_i = ir.v_ops[user_inst] + cast(u32) j; break; }
        in_chain := false;
        for lsr.iv_inc_set if it == use_i { in_chain = true; break; }
        if in_chain continue;
        kind := Lsr_Kind.BASIC;
        at: Lsr_Mem_Ty;
        if lsr_is_address_use(user_inst, u.operand) {
            kind = .ADDRESS;
            at = lsr_get_access_type(user_inst, u.operand);
        }
        s := iu_get_expr(u);
        if s == SCEV_NULL continue;
        tmp_post_inc: [..] Loop_Id; tmp_post_inc.allocator = temp;
        for u.post_inc_loops array_add(*tmp_post_inc, it);
        if inst_op(user_inst) == .ICMP && icmp_is_equality(inst_pred(user_inst)) {
            ci := user_inst;
            nv := op(ci, 1);
            if nv == u.operand {
                a := op(ci, 0);
                set_op(ci, 1, a);
                set_op(ci, 0, nv);
                nv = op(ci, 1);
                lsr.changed = true;
            }
            n := sc_get_scev(nv);
            if sc_is_loop_invariant(n, lsr.l) && sx_is_safe_to_expand(*lsr.rewriter, n) &&
               (type_kind(vtype(nv)) != .PTR || sc_get_pointer_base(n) == sc_get_pointer_base(s)) {
                n = lsr_normalize_for_post_inc_use(n, *tmp_post_inc);
                if n == SCEV_NULL continue;
                kind = .ICMP_ZERO;
                s = sc_get_minus(n, s);
            } else if li_is_loop_invariant(lsr.li, lsr.l, nv) && (!is_inst(nv) || dt_dominates_inst_block(lsr.dt, nv, li_header(lsr.li, lsr.l))) &&
                      type_kind(vtype(nv)) != .PTR {
                n = sc_get_unknown(nv);
                n = lsr_normalize_for_post_inc_use(n, *tmp_post_inc);
                if n == SCEV_NULL continue;
                kind = .ICMP_ZERO;
                s = sc_get_minus(n, s);
            }
            e := lsr.factors.count;
            for i: 0..e-1 {
                if lsr.factors[i] != -1 {
                    v := cast,no_check(s64) (0 - cast,no_check(u64) lsr.factors[i]);
                    dup := false;
                    for lsr.factors if it == v dup = true;
                    if !dup array_add(*lsr.factors, v);
                }
            }
            dup := false;
            for lsr.factors if it == -1 dup = true;
            if !dup array_add(*lsr.factors, -1);
        }
        lu_idx, offset := lsr_get_use(*s, kind, at);
        lu := *lsr.uses[lu_idx];
        lf := lu_new_fixup(lu);
        lf.user_inst = user_inst;
        lf.operand_val_to_replace = u.operand;
        for tmp_post_inc array_add(*lf.post_inc_loops, it);
        lf.offset = offset;
        lu.all_fixups_outside_loop &= lsr_fixup_is_use_fully_outside_loop(lf, lsr.l);
        lu.all_fixups_unconditional &= lsr_is_fixup_executed_each_increment(lf);
        if !table_contains(*visited_lsr_use, lu_idx) && !lsr_fixup_is_use_fully_outside_loop(lf, lsr.l) {
            f := lf_new();
            lf_initial_match(*f, s, lsr.l);
            cost_rate_formula(*lsr.baseline_cost, *f, *regs, *visited_regs, lu);
            table_set(*visited_lsr_use, lu_idx, true);
        }
        if lu.formulae.count == 0 {
            lsr_insert_initial_formula(s, lu, lu_idx);
            lsr_count_registers(*lu.formulae[lu.formulae.count - 1], lu_idx);
        }
    }
}
lsr_insert_initial_formula :: (s: Scev_Id, lu: *Lsr_Use, lu_idx: s64) {
    if !sx_is_safe_to_expand(*lsr.rewriter, s) lu.rigid_formula = true;
    f := lf_new();
    lf_initial_match(*f, s, lsr.l);
    ins := lsr_insert_formula(lu, lu_idx, *f);
    if !ins fatal("loop-reduce: Initial formula already exists!");
}
lsr_insert_supplemental_formula :: (s: Scev_Id, lu: *Lsr_Use, lu_idx: s64) {
    f := lf_new();
    array_add(*f.base_regs, s);
    f.has_base_reg = true;
    ins := lsr_insert_formula(lu, lu_idx, *f);
    if !ins fatal("loop-reduce: Supplemental formula already exists!");
}
lsr_count_registers :: (f: *Lsr_Formula, lu_idx: s64) {
    if f.scaled_reg != SCEV_NULL ru_count_register(*lsr.reg_uses, f.scaled_reg, lu_idx);
    for f.base_regs ru_count_register(*lsr.reg_uses, it, lu_idx);
}
lsr_insert_formula :: (lu: *Lsr_Use, lu_idx: s64, f: *Lsr_Formula) -> bool {
    if !lu_insert_formula(lu, f, lsr.l) return false;
    lsr_count_registers(f, lu_idx);
    return true;
}
lsr_is_fixup_executed_each_increment :: (lf: *Lsr_Fixup) -> bool {
    return dt_dominates(lsr.dt, inst_block(lf.user_inst), inst_block(lsr.iv_inc_insert_pos));
}

// CollectLoopInvariantFixupsAndFormulae
lsr_collect_loop_invariant_fixups_and_formulae :: () {
    worklist: [..] Scev_Id; worklist.allocator = temp;
    for lsr.reg_uses.sequence array_add(*worklist, it);
    visited: Table(Scev_Id, bool); visited.allocator = temp;
    // AMK == AMK_PostIndexed: never on X86
    header := li_header(lsr.li, lsr.l);
    f := block_fn(header);
    while worklist.count {
        s := pop(*worklist);
        if table_contains(*visited, s) continue;
        table_set(*visited, s, true);
        k := sc_kind(s);
        if k == .ADD || k == .MUL || k == .ADDREC || k == .UMAX || k == .SMAX || k == .UMIN || k == .SMIN || k == .SEQ_UMIN {
            for i: 0..cast(s64) sc_nops(s) - 1 array_add(*worklist, sc_op(s, cast(u32) i));
        } else if k == .TRUNC || k == .ZEXT || k == .SEXT || k == .PTRTOINT || k == .PTRTOADDR {
            array_add(*worklist, sc_op(s, 0));
        } else if k == .UDIV {
            array_add(*worklist, sc_op(s, 0));
            array_add(*worklist, sc_op(s, 1));
        } else if k == .UNKNOWN {
            v := sc_value(s);
            if is_inst(v) {
                if li_contains_inst(lsr.li, lsr.l, v) continue;
            } else if is_const(v) continue;
            u := ir.v_first_use[v];
            while u != NONE {
                defer u = ir.u_next[u];
                user_inst := ir.u_user[u];
                if !is_inst(user_inst) continue;
                if is_eh_pad(user_inst) continue;
                if inst_fn(user_inst) != f continue;
                use_bb := ifx inst_op(user_inst) != .PHI then inst_block(user_inst) else ir.u_aux[u];
                if !dt_dominates(lsr.dt, header, use_bb) continue;
                if is_eh_pad(block_terminator(use_bb)) continue;
                if inst_op(user_inst) == .PHI {
                    incompatible := false;
                    for pk: 0..cast(s64) nops(user_inst) - 1 {
                        if phi_value(user_inst, cast(u32) pk) == v && is_eh_pad(block_terminator(phi_block(user_inst, cast(u32) pk))) { incompatible = true; break; }
                    }
                    if incompatible continue;
                }
                if inst_op(block_terminator(inst_block(user_inst))) == .CATCHSWITCH continue;
                if sc_is_scevable(vtype(user_inst)) {
                    user_s := sc_get_scev(user_inst);
                    if sc_kind(user_s) != .UNKNOWN continue;
                    if user_s == s {
                        array_add(*worklist, sc_get_unknown(user_inst));
                        continue;
                    }
                }
                if inst_op(user_inst) == .ICMP {
                    other_idx: u32 = ifx use_operand_no(u) == 0 then cast(u32) 1 else 0;
                    other_op := op(user_inst, other_idx);
                    if sc_has_computable_loop_evolution(sc_get_scev(other_op), lsr.l) continue;
                }
                if is_lifetime_start_or_end(user_inst) continue;
                ss := s;
                lu_idx, offset := lsr_get_use(*ss, .BASIC, Lsr_Mem_Ty.{});
                lu := *lsr.uses[lu_idx];
                lf := lu_new_fixup(lu);
                lf.user_inst = user_inst;
                lf.operand_val_to_replace = v;
                lf.offset = offset;
                lu.all_fixups_outside_loop &= lsr_fixup_is_use_fully_outside_loop(lf, lsr.l);
                lu.all_fixups_unconditional &= lsr_is_fixup_executed_each_increment(lf);
                lsr_insert_supplemental_formula(s, lu, lu_idx);
                lsr_count_registers(*lu.formulae[lu.formulae.count - 1], lsr.uses.count - 1);
                break;
            }
        }
    }
}
