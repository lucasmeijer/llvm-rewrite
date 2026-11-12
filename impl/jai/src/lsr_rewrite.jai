// LoopStrengthReduce, part 5: port of llvm/lib/Transforms/Scalar/LoopStrengthReduce.cpp: HoistInsertPosition,
// AdjustInsertPositionForExpand, Expand, RewriteForPHI, Rewrite, getFixupInsertPos, ImplementSolution, the
// LSRInstance constructor (the driver), ReduceLoopStrength and LoopStrengthReducePass::run.
// Debug-value salvaging (DbgGatherSalvagableDVI / DbgRewriteSalvageableDVIs) is not ported: when a gathered
// #dbg_value becomes a kill location (the only case where LLVM rewrites it), the pass fails loudly.

// CastInst::getCastOpcode(V, /*SrcIsSigned=*/false, DestTy, /*DstIsSigned=*/false) for scalar int/ptr types
lsr_cast_opcode :: (src: Type_Id, dst: Type_Id) -> Opcode {
    sk := type_kind(src); dk := type_kind(dst);
    if sk == .INT && dk == .INT {
        sb := type_bits(src); db := type_bits(dst);
        if db < sb return .TRUNC;
        if db > sb return .ZEXT;
        return .BITCAST;
    }
    if sk == .PTR && dk == .INT return .PTRTOINT;
    if sk == .INT && dk == .PTR return .INTTOPTR;
    if sk == .PTR && dk == .PTR return ifx type_addrspace(src) != type_addrspace(dst) then Opcode.ADDRSPACECAST else .BITCAST;
    fatal("loop-reduce: unsupported cast in expansion");
    return .BITCAST;
}
lsr_create_cast_before :: (v: Value_Id, ty: Type_Id, name: string, before: Value_Id) -> Value_Id {
    c := create_cast(lsr_cast_opcode(vtype(v), ty), v, ty);
    insert_at_position(c, inst_block(before), before, false);
    set_name(c, name);
    return c;
}

// HoistInsertPosition
lsr_hoist_insert_position :: (ip_in: Value_Id, inputs: [] Value_Id) -> Value_Id {
    ip := ip_in;
    tentative := ip;
    while true {
        all_dominate := true;
        better_pos: Value_Id = NONE;
        if inst_op(tentative) == .CATCHSWITCH return ip;
        for i: inputs {
            if i == tentative || !dt_dominates_inst(lsr.dt, i, tentative) { all_dominate = false; break; }
            if inst_block(tentative) == inst_block(i) && (better_pos == NONE || !dt_dominates_inst(lsr.dt, i, better_pos))
                better_pos = inst_next(i);
        }
        if !all_dominate break;
        ip = ifx better_pos != NONE then better_pos else tentative;
        ip_loop := li_loop_for(lsr.li, inst_block(ip));
        ip_loop_depth := ifx ip_loop != NONE then li_depth(lsr.li, ip_loop) else 0;
        idom: Value_Id = NONE;
        rung := dt_node(lsr.dt, inst_block(ip));
        while true {
            if rung < 0 return ip;
            rung = dt_idom(lsr.dt, rung);
            if rung < 0 return ip;
            idom = lsr.dt.nodes[rung].block;
            idom_loop := li_loop_for(lsr.li, idom);
            idom_depth := ifx idom_loop != NONE then li_depth(lsr.li, idom_loop) else 0;
            if idom_depth <= ip_loop_depth && (idom_depth != ip_loop_depth || idom_loop == ip_loop) break;
        }
        tentative = block_terminator(idom);
    }
    return ip;
}

// AdjustInsertPositionForExpand
lsr_adjust_insert_position_for_expand :: (lowest_ip: Value_Id, lf: *Lsr_Fixup, lu: *Lsr_Use) -> Value_Id {
    inputs: [..] Value_Id; inputs.allocator = temp;
    if is_inst(lf.operand_val_to_replace) array_add(*inputs, lf.operand_val_to_replace);
    if lu.kind == .ICMP_ZERO {
        o1 := op(lf.user_inst, 1);
        if is_inst(o1) array_add(*inputs, o1);
    }
    has_l := false;
    for lf.post_inc_loops if it == lsr.l has_l = true;
    if has_l {
        if lsr_fixup_is_use_fully_outside_loop(lf, lsr.l) array_add(*inputs, block_terminator(li_loop_latch(lsr.li, lsr.l)));
        else array_add(*inputs, lsr.iv_inc_insert_pos);
    }
    for pil: lf.post_inc_loops {
        if pil == lsr.l continue;
        exiting: [..] Value_Id; exiting.allocator = temp;
        li_exiting_blocks(lsr.li, pil, *exiting);
        if exiting.count {
            bb := exiting[0];
            for i: 1..exiting.count-1 bb = dt_find_nca(lsr.dt, bb, exiting[i]);
            array_add(*inputs, block_terminator(bb));
        }
    }
    ip := lsr_hoist_insert_position(lowest_ip, inputs);
    while inst_op(ip) == .PHI ip = inst_next(ip);
    while is_eh_pad(ip) ip = inst_next(ip);
    while sx_is_inserted_instruction(*lsr.rewriter, ip) && ip != lowest_ip ip = inst_next(ip);
    return ip;
}

// Expand
lsr_expand :: (lu: *Lsr_Use, lf: *Lsr_Fixup, f: *Lsr_Formula, ip_in: Value_Id, dead: *[..] Vh) -> Value_Id {
    if lu.rigid_formula return lf.operand_val_to_replace;
    x := *lsr.rewriter;
    ip := lsr_adjust_insert_position_for_expand(ip_in, lf, lu);
    sx_set_insert_point(x, ip);
    sx_set_post_inc(x, lf.post_inc_loops);
    op_ty := vtype(lf.operand_val_to_replace);
    ty := lf_type(f);
    if ty == NONE ty = op_ty;
    else if sc_effective_type(ty) == sc_effective_type(op_ty) ty = op_ty;
    int_ty := sc_effective_type(ty);
    if lu.kind == .ICMP_ZERO && type_kind(op_ty) == .PTR { op_ty = int_ty; ty = int_ty; }
    ops: [..] Scev_Id; ops.allocator = temp;
    for reg: f.base_regs {
        r := denormalize_for_post_inc_use(reg, *lf.post_inc_loops);
        array_add(*ops, sc_get_unknown(sx_expand_code_for(x, r)));
    }
    icmp_scaled_v: Value_Id = NONE;
    if f.scale != 0 {
        scaled_s := denormalize_for_post_inc_use(f.scaled_reg, *lf.post_inc_loops);
        if lu.kind == .ICMP_ZERO {
            if f.scale == 1 array_add(*ops, sc_get_unknown(sx_expand_code_for(x, scaled_s)));
            else icmp_scaled_v = sx_expand_code_for(x, scaled_s);
        } else {
            if ops.count && lu.kind == .ADDRESS && lsr_is_am_completely_folded_lu(lu, f) {
                full_v := sx_expand_code_for(x, sc_get_add(*ops));
                ops.count = 0;
                array_add(*ops, sc_get_unknown(full_v));
            }
            scaled_s = sc_get_unknown(sx_expand_code_for(x, scaled_s));
            if f.scale != 1 scaled_s = sc_get_mul2(scaled_s, sc_get_constant_t(sc_type(scaled_s), cast,no_check(u64) f.scale, true));
            array_add(*ops, scaled_s);
        }
    }
    if f.base_gv != NONE {
        if ops.count {
            full_v := sx_expand_code_for(x, sc_get_add(*ops), int_ty);
            ops.count = 0;
            array_add(*ops, sc_get_unknown(full_v));
        }
        array_add(*ops, sc_get_unknown(f.base_gv));
    }
    if ops.count {
        full_v := sx_expand_code_for(x, sc_get_add(*ops), ty);
        ops.count = 0;
        array_add(*ops, sc_get_unknown(full_v));
    }
    offset := imm_add_unsigned(f.base_offset, lf.offset);
    if imm_nz(offset) {
        if lu.kind == .ICMP_ZERO {
            if icmp_scaled_v == NONE {
                icmp_scaled_v = const_int_signed(int_ty, cast,no_check(s64) (0 - cast,no_check(u64) offset.v));
            } else {
                array_add(*ops, sc_get_unknown(icmp_scaled_v));
                icmp_scaled_v = const_int_signed(int_ty, offset.v);
            }
        } else array_add(*ops, imm_unknown_scev(offset, int_ty));
    }
    if imm_nz(f.unfolded_offset) array_add(*ops, imm_unknown_scev(f.unfolded_offset, int_ty));
    full_s := ifx ops.count == 0 then sc_get_constant_t(int_ty, 0) else sc_get_add(*ops);
    full_v := sx_expand_code_for(x, full_s, ty);
    sx_clear_post_inc(x);
    if lu.kind == .ICMP_ZERO {
        ci := lf.user_inst;
        o1 := op(ci, 1);
        if is_inst(o1) array_add(dead, vh_new(o1));
        if f.scale == -1 {
            if vtype(icmp_scaled_v) != op_ty icmp_scaled_v = lsr_create_cast_before(icmp_scaled_v, op_ty, "tmp", ci);
            set_op(ci, 1, icmp_scaled_v);
        } else {
            c := const_int_signed(sc_effective_type(op_ty), cast,no_check(s64) (0 - cast,no_check(u64) offset.v));
            if vtype(c) != op_ty c = cf_cast(lsr_cast_opcode(vtype(c), op_ty), c, op_ty);
            set_op(ci, 1, c);
        }
    }
    return full_v;
}

// RewriteForPHI
lsr_rewrite_for_phi :: (pn: Value_Id, lu: *Lsr_Use, lf: *Lsr_Fixup, f: *Lsr_Formula, dead: *[..] Vh) {
    Ins :: struct { bb: Value_Id; v: Value_Id; }
    inserted: [..] Ins; inserted.allocator = temp;
    i: u32 = 0;
    e := phi_num_incoming(pn);
    while i != e {
        defer i += 1;
        if phi_value(pn, i) != lf.operand_val_to_replace continue;
        need_update_fixups := false;
        bb := phi_block(pn, i);
        term := block_terminator(bb);
        if e != 1 && num_successors(term) > 1 && inst_op(term) != .INDIRECTBR && inst_op(term) != .CATCHSWITCH {
            parent := inst_block(pn);
            pn_loop := li_loop_for(lsr.li, parent);
            if pn_loop == NONE || parent != li_header(lsr.li, pn_loop) {
                new_bb: Value_Id = NONE;
                if !block_is_landing_pad(parent) {
                    o: Crit_Edge_Options;
                    o.dt = lsr.dt; o.li = lsr.li;
                    o.merge_identical_edges = true; o.keep_one_input_phis = true;
                    o.preserve_lcssa = lsr.preserve_lcssa;
                    succ_idx: u32 = 0;
                    for s: 0..cast(s64) num_successors(term) - 1 if get_successor(term, cast(u32) s) == parent { succ_idx = cast(u32) s; break; }
                    new_bb = split_critical_edge(term, succ_idx, *o);
                } else {
                    fatal("loop-reduce: splitting landing pad predecessors is not supported yet");
                }
                if new_bb != NONE {
                    if li_contains(lsr.li, lsr.l, bb) && !li_contains_inst(lsr.li, lsr.l, pn) block_move_before(new_bb, inst_block(pn));
                    e = phi_num_incoming(pn);
                    bb = new_bb;
                    i = cast(u32) phi_block_index(pn, bb);
                    need_update_fixups = true;
                }
            }
        }
        found := -1;
        for inserted if it.bb == bb { found = it_index; break; }
        if found >= 0 phi_set_value(pn, i, inserted[found].v);
        else {
            full_v := lsr_expand(lu, lf, f, block_terminator(bb), dead);
            op_ty := vtype(lf.operand_val_to_replace);
            if vtype(full_v) != op_ty full_v = lsr_create_cast_before(full_v, op_ty, "tmp", block_terminator(bb));
            if is_inst(full_v) && li_contains_inst(lsr.li, lsr.l, full_v) && !li_contains(lsr.li, lsr.l, bb)
                lsr_set_insert_v(*lsr.inserted_non_lcssa_insts, full_v);
            phi_set_value(pn, i, full_v);
            array_add(*inserted, .{bb, full_v});
        }
        if need_update_fixups {
            for * u: lsr.uses for * fx: u.fixups {
                if fx.user_inst != pn continue;
                found_in_orig := false;
                for k: 0..phi_num_incoming(pn)-1 if phi_value(pn, k) == fx.operand_val_to_replace { found_in_orig = true; break; }
                if found_in_orig continue;
                for k: 0..phi_num_incoming(pn)-1 {
                    blk := phi_block(pn, k);
                    for np: block_insts(blk) {
                        if inst_op(np) != .PHI break;
                        for q: 0..phi_num_incoming(np)-1 if phi_value(np, q) == fx.operand_val_to_replace fx.user_inst = np;
                    }
                }
            }
        }
    }
}

// Rewrite
lsr_rewrite :: (lu: *Lsr_Use, lf: *Lsr_Fixup, f: *Lsr_Formula, dead: *[..] Vh) {
    if is_phi(lf.user_inst) {
        lsr_rewrite_for_phi(lf.user_inst, lu, lf, f, dead);
    } else {
        full_v := lsr_expand(lu, lf, f, lf.user_inst, dead);
        op_ty := vtype(lf.operand_val_to_replace);
        if vtype(full_v) != op_ty && !(lu.kind == .ICMP_ZERO && type_kind(op_ty) == .PTR)
            full_v = lsr_create_cast_before(full_v, op_ty, "tmp", lf.user_inst);
        if lu.kind == .ICMP_ZERO set_op(lf.user_inst, 0, full_v);
        else replace_uses_of_with(lf.user_inst, lf.operand_val_to_replace, full_v);
    }
    if is_inst(lf.operand_val_to_replace) array_add(dead, vh_new(lf.operand_val_to_replace));
}

// RecursivelyDeleteTriviallyDeadInstructionsPermissive(DeadInsts, TLI, MSSAU)
lsr_delete_dead_permissive :: (dead_in: *[..] Vh) -> bool {
    dead: [..] Value_Id; dead.allocator = temp;
    for h: dead_in.* {
        v := vh_get(h);
        if v == NONE || !is_inst(v) || vkind(v) == .DEAD continue;
        if !is_instruction_trivially_dead_tli(v, true) continue;
        array_add(*dead, v);
    }
    dead_in.count = 0;
    if dead.count == 0 return false;
    recursively_delete_trivially_dead_list(*dead, null);
    return true;
}

// ImplementSolution
lsr_implement_solution :: (solution: [] s64) {
    dead: [..] Vh; dead.allocator = temp;
    x := *lsr.rewriter;
    for * c: lsr.iv_chain_vec {
        tail := c.incs[c.incs.count - 1].user_inst;
        if is_phi(tail) sx_set_chained_phi(x, tail);
    }
    for lu_idx: 0..lsr.uses.count-1 {
        k := 0;
        while k < lsr.uses[lu_idx].fixups.count {
            lu := *lsr.uses[lu_idx];
            sx_set_iv_inc_insert_pos(x, lsr.l, lsr.iv_inc_insert_pos);   // getFixupInsertPos: no post-inc on X86
            lsr_rewrite(lu, *lu.fixups[k], *lu.formulae[solution[lu_idx]], *dead);
            lsr.changed = true;
            k += 1;
        }
    }
    inserted := lsr.inserted_non_lcssa_insts;
    empty: [..] Value_Id; empty.allocator = temp;
    lsr.inserted_non_lcssa_insts = empty;
    if inserted.count {
        cache: Lcssa_Exit_Cache;
        form_lcssa_for_instructions(*inserted, lsr.dt, lsr.li, *cache);
    }
    for * c: lsr.iv_chain_vec {
        lsr_generate_iv_chain(c, *dead);
        lsr.changed = true;
    }
    for iv: x.inserted_ivs if iv != NONE && vkind(iv) != .DEAD && inst_block(iv) != NONE array_add(*lsr.scalar_evolution_ivs, iv);
    sx_clear(x);
    lsr.changed |= lsr_delete_dead_permissive(*dead);
    header := li_header(lsr.li, lsr.l);
    for pn: block_insts(header) {
        if inst_op(pn) != .PHI break;
        ok, bo, start, step := match_simple_recurrence(pn);
        if !ok continue;
        o := inst_op(bo);
        if o == .SUB { if op(bo, 0) != pn continue; }
        else if o != .ADD continue;
        if !is_const(step) continue;
        if inst_block(bo) == inst_block(lsr.iv_inc_insert_pos) continue;
        all_dom := true;
        u := ir.v_first_use[bo];
        while u != NONE {
            if !dt_dominates_use(lsr.dt, lsr.iv_inc_insert_pos, u) { all_dom = false; break; }
            u = ir.u_next[u];
        }
        if !all_dom continue;
        inst_move_before_dbg(bo, lsr.iv_inc_insert_pos);
        lsr.changed = true;
    }
}

// LSRInstance::LSRInstance
lsr_instance_run :: (l: Loop_Id, iu: *Iv_Users, dt: *Dom_Tree, li: *Loop_Info, tti: *Tti, preserve_lcssa: bool) {
    lsr = .{};
    lsr.l = l; lsr.iu = iu; lsr.dt = dt; lsr.li = li; lsr.preserve_lcssa = preserve_lcssa;
    lsr.f = block_fn(li_header(li, l));
    lsr.factors.allocator = temp; lsr.types.allocator = temp; lsr.uses.allocator = temp;
    lsr.use_map_keys.allocator = temp; lsr.use_map_vals.allocator = temp; lsr.iv_chain_vec.allocator = temp;
    lsr.iv_inc_set.allocator = temp; lsr.scalar_evolution_ivs.allocator = temp; lsr.inserted_non_lcssa_insts.allocator = temp;
    lsr.reg_uses.map.allocator = temp; lsr.reg_uses.used_by.allocator = temp; lsr.reg_uses.sequence.allocator = temp;
    lsr_tti = tti;
    sx_init(*lsr.rewriter, "lsr", preserve_lcssa);
    if !li_is_loop_simplify_form(li, l) return;
    iu_empty :: () -> bool { for * lsr.iu.uses if iu_live(it) return false; return true; }
    if iu_empty() return;
    num_users := 0;
    for * u: iu.uses {
        if !iu_live(u) continue;
        num_users += 1;
        if num_users > LSR_MAX_IV_USERS return;
        if is_phi(u.user) {
            first_non_phi := block_first_non_phi(inst_block(u.user));
            fo := inst_op(first_non_phi);
            if fo == .CATCHPAD || fo == .CLEANUPPAD || fo == .CATCHSWITCH {
                for k: 0..phi_num_incoming(u.user)-1 {
                    if inst_op(block_first_non_phi(phi_block(u.user, k))) == .CATCHSWITCH return;
                }
            }
        }
    }
    lsr.hardware_loop_profitable = false;   // TTI.isHardwareLoopProfitable: false on X86
    sx_disable_canonical_mode(*lsr.rewriter);
    sx_enable_lsr_mode(*lsr.rewriter);
    lsr_optimize_shadow_iv();
    lsr_optimize_loop_term_cond();
    if iu_empty() return;
    if !li_is_innermost(li, l) return;
    lsr_collect_chains();   // TTI.isNumRegsMajorCostOfLSR(): true
    lsr_collect_interesting_types_and_factors();
    lsr_collect_fixups_and_initial_formulae();
    lsr_collect_loop_invariant_fixups_and_formulae();
    if lsr.uses.count == 0 return;
    lsr_debug_dump("LSR found uses");
    lsr_generate_all_reuse_formulae();
    lsr_debug_dump("After generating reuse formulae");
    lsr_filter_out_undesirable_dedicated_registers();
    lsr_debug_dump("After filtering out undesirable candidates");
    lsr_narrow_search_space_using_heuristics();
    lsr_debug_dump("After pre-selection");
    solution := lsr_solve();
    if lsr_debug_enabled() {
        sb: String_Builder; sb.allocator = temp;
        append(*sb, "Baseline: "); lsr_debug_cost(*sb, *lsr.baseline_cost); append(*sb, "\nSolution:\n");
        for solution { print_to_builder(*sb, "  use %: ", it_index); lsr_debug_formula(*sb, *lsr.uses[it_index].formulae[it]); append(*sb, "\n"); }
        write_string(builder_to_string(*sb,, temp), to_standard_error = true);
    }
    lsr.factors.count = 0;
    lsr.types.count = 0;
    if solution.count == 0 return;
    lsr_implement_solution(solution);
}

// DbgGatherSalvagableDVI (the records only; see the note at the top)
lsr_gather_salvageable_dvi :: (l: Loop_Id, li: *Loop_Info, out: *[..] u32) {
    for bb: li.loops[l].blocks for i: block_insts(bb) {
        r := inst(i).records;
        while r != 0 {
            rec := ir.dbg_records[r - 1];
            if (rec.kind == .VALUE || rec.kind == .ASSIGN) && !dbgr_is_kill_location(r) {
                vals: [..] Value_Id; vals.allocator = temp;
                dbgr_values_of_loc(rec.loc, *vals);
                ok := true;
                for vals {
                    if it == NONE || !sc_is_scevable(vtype(it)) { ok = false; break; }
                    if sc_contains_undefs(sc_get_scev(it)) { ok = false; break; }
                }
                if ok array_add(out, r);
            }
            r = rec.next;
        }
    }
}

// ReduceLoopStrength
reduce_loop_strength :: (l: Loop_Id, lar: *Loop_Std_Results, preserve_lcssa: bool) -> bool {
    li := lar.li; dt := lar.dt;
    tti := tti_get(lar.fn);
    salvageable: [..] u32; salvageable.allocator = temp;
    lsr_gather_salvageable_dvi(l, li, *salvageable);
    iu: Iv_Users;
    iv_users_compute(*iu, l, lar);
    changed := false;
    lsr_instance_run(l, *iu, dt, li, tti, preserve_lcssa);
    changed |= lsr.changed;
    header := li_header(li, l);
    changed |= ivs_delete_dead_phis(header, null);
    if lsr_cl.enable_phi_elim && li_is_loop_simplify_form(li, l) {
        dead: [..] Vh; dead.allocator = temp;
        rw: Scev_Expander;
        sx_init(*rw, "lsr", false);
        num_folded := sx_replace_congruent_ivs(*rw, l, *dead, tti);
        sx_clear(*rw);
        if num_folded {
            changed = true;
            lsr_delete_dead_permissive(*dead);
            ivs_delete_dead_phis(header, null);
        }
    }
    if li_is_recursively_lcssa_form(li, l, dt) && li_exit_block(li, l) != NONE {
        dead: [..] Vh; dead.allocator = temp;
        rw: Scev_Expander;
        sx_init(*rw, "lsr", true);
        rewrites := rewrite_loop_exit_values(l, li, tti, *rw, dt, REPL_UNUSED_INDVAR_IN_LOOP, *dead);
        sx_clear(*rw);
        if rewrites {
            changed = true;
            lsr_delete_dead_permissive(*dead);
            ivs_delete_dead_phis(header, null);
        }
    }
    for r: salvageable {
        if dbgr(r).owner != NONE && dbgr_is_kill_location(r)
            fatal("loop-reduce: salvaging debug values with SCEV (DbgRewriteSalvageableDVIs) is not supported yet");
    }
    return changed;
}

// LoopStrengthReducePass::run
loop_reduce_run :: (node: *Pass_Node, l: Loop_Id, lar: *Loop_Std_Results, u: *Lpm_Updater) -> Preserved {
    se = lar.se;
    changed := reduce_loop_strength(l, lar, true);
    vh_release_all();
    if !changed return PRESERVE_ALL;
    pa := loop_pass_preserved();
    if lar.mssa preserve(*pa, .MEMORYSSA);
    return pa;
}

// ScalarEvolution::containsUndefs: a SCEVUnknown of an UndefValue (undef or poison)
sc_contains_undefs :: (s: Scev_Id) -> bool {
    visited: Table(Scev_Id, bool); visited.allocator = temp;
    work: [..] Scev_Id; work.allocator = temp;
    array_add(*work, s);
    while work.count {
        x := pop(*work);
        if table_contains(*visited, x) continue;
        table_set(*visited, x, true);
        k := sc_kind(x);
        if k == .UNKNOWN { vk := vkind(sc_value(x)); if vk == .C_UNDEF || vk == .C_POISON return true; continue; }
        if k == .CONSTANT || k == .VSCALE || k == .CNC continue;
        for i: 0..cast(s64) sc_nops(x) - 1 array_add(*work, sc_op(x, cast(u32) i));
    }
    return false;
}

// Debugging aid (not part of LLVM's behaviour): with JAI_LSR_DEBUG set in the environment, the uses, formulae and
// costs are printed to stderr in the format of LSRInstance::print_uses / Cost::print.
lsr_debug_enabled :: () -> bool {
    #import "POSIX";
    return getenv("JAI_LSR_DEBUG") != null;
}
lsr_debug_formula :: (sb: *String_Builder, f: *Lsr_Formula) {
    first := true;
    sep :: (sb: *String_Builder, first: *bool) { if !first.* append(sb, " + "); first.* = false; }
    if f.base_gv != NONE { sep(sb, *first); append(sb, "@gv"); }
    if imm_nz(f.base_offset) { sep(sb, *first); print_to_builder(sb, "%", f.base_offset.v); }
    for f.base_regs { sep(sb, *first); append(sb, "reg("); sc_print(sb, it); append(sb, ")"); }
    if f.has_base_reg && f.base_regs.count == 0 { sep(sb, *first); append(sb, "**error: HasBaseReg**"); }
    if f.scale != 0 || f.scaled_reg != SCEV_NULL {
        sep(sb, *first);
        print_to_builder(sb, "%*reg(", f.scale);
        if f.scaled_reg != SCEV_NULL sc_print(sb, f.scaled_reg); else append(sb, "nullptr");
        append(sb, ")");
    }
    if imm_nz(f.unfolded_offset) { sep(sb, *first); print_to_builder(sb, "imm(%)", f.unfolded_offset.v); }
}
lsr_debug_cost :: (sb: *String_Builder, c: *Lsr_Cost) {
    print_to_builder(sb, "{Insns=% NumRegs=% AddRec=% IVMuls=% BaseAdds=% Imm=% Setup=% Scale=%}", c.insns, c.num_regs, c.add_rec_cost,
        c.num_iv_muls, c.num_base_adds, c.imm_cost, c.setup_cost, c.scale_cost);
}
lsr_debug_dump :: (title: string) {
    if !lsr_debug_enabled() return;
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "%:\n", title);
    for * lu, i: lsr.uses {
        print_to_builder(*sb, "  LSR Use %: Kind=% Offsets={%..%} fixups=% outside=% uncond=%\n", i, lu.kind, lu.min_offset.v, lu.max_offset.v,
            lu.fixups.count, lu.all_fixups_outside_loop, lu.all_fixups_unconditional);
        for * f: lu.formulae { append(*sb, "    "); lsr_debug_formula(*sb, f); append(*sb, "\n"); }
    }
    write_string(builder_to_string(*sb,, temp), to_standard_error = true);
}

// llc's LPPassManager { CanonicalizeFreezeInLoops, IVUsers, LoopStrengthReduce } (TargetPassConfig::addIRPasses):
// LPPassManager::runOnFunction (llvm/lib/Analysis/LoopPass.cpp). Loops are queued by addLoopIntoQueue over
// reverse(LoopInfo) and popped from the back; LoopStrengthReduce::runOnLoop does not preserve LCSSA.
lsr_loop_pm_run :: (f: Value_Id) -> Preserved {
    li := get_loop_info(f);
    if li.top_level.count == 0 return PRESERVE_ALL;
    if cg_skip_function(f) return PRESERVE_ALL;   // skipLoop
    lq: [..] Loop_Id; lq.allocator = temp;
    add_loop_into_queue :: (li: *Loop_Info, l: Loop_Id, lq: *[..] Loop_Id) {
        array_add(lq, l);
        subs := li_subloops(li, l);
        for < subs add_loop_into_queue(li, it, lq);
    }
    for < li.top_level add_loop_into_queue(li, it, *lq);
    lar: Loop_Std_Results;
    lar.fn = f;
    lar.ac = get_assumption_cache(f);
    lar.dt = get_domtree(f);
    lar.li = li;
    lar.se = get_scev(f);
    saved_se := scev_pass_se;
    scev_pass_se = lar.se;
    defer scev_pass_se = saved_se;
    changed := false;
    while lq.count {
        l := pop(*lq);
        se = lar.se;
        changed |= canon_freeze_impl(l, li, lar.dt);
        se = lar.se;
        changed |= reduce_loop_strength(l, *lar, false);
        vh_release_all();
    }
    if !changed return PRESERVE_ALL;
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    return pa;
}
