// LoopStrengthReduce, part 2: port of llvm/lib/Transforms/Scalar/LoopStrengthReduce.cpp: the LSRInstance state, Cost
// (RateRegister, RatePrimaryRegister, RateFormula, Lose, isLess), OptimizeShadowIV, FindIVUserForCond, OptimizeMax,
// OptimizeLoopTermCond, reconcileNewOffset, getUse, DeleteUse, FindUseWithSimilarFormula,
// CollectInterestingTypesAndFactors, and the IVUsers queries LSR makes (getExpr, getStride, AddUser,
// normalizeForPostIncUse from ScalarEvolutionNormalization.cpp).

Lsr_Cost :: struct {
    insns: u32; num_regs: u32; add_rec_cost: u32; num_iv_muls: u32; num_base_adds: u32; imm_cost: u32; setup_cost: u32; scale_cost: u32;
}

Lsr_State :: struct {
    l: Loop_Id;
    f: Value_Id;
    iu: *Iv_Users;
    dt: *Dom_Tree;
    li: *Loop_Info;
    changed: bool;
    hardware_loop_profitable: bool;
    preserve_lcssa: bool;
    iv_inc_insert_pos: Value_Id = NONE;
    factors: [..] s64;               // SetVector<int64_t>
    baseline_cost: Lsr_Cost;
    types: [..] Type_Id;             // SmallSetVector<Type *>
    uses: [..] Lsr_Use;
    reg_uses: Lsr_Reg_Uses;
    use_map_keys: [..] Lsr_Use_Key;  // UseMap (DenseMap<(SCEV, Kind), size_t>)
    use_map_vals: [..] s64;
    iv_chain_vec: [..] Lsr_Iv_Chain;
    iv_inc_set: [..] Use_Id;         // IVIncSet (SmallPtrSet<Use*>)
    scalar_evolution_ivs: [..] Value_Id;   // WeakVH
    inserted_non_lcssa_insts: [..] Value_Id;
    rewriter: Scev_Expander;
}
Lsr_Use_Key :: struct { s: Scev_Id; kind: Lsr_Kind; }
lsr: Lsr_State;
LSR_MAX_CHAINS :: 8;
LSR_MAX_IV_USERS :: 200;

// ---------------------------------------------------------------- IVUsers queries

iu_live :: (u: *Iv_Stride_Use) -> bool { return u.user != NONE && vkind(u.user) != .DEAD; }

// normalizeForPostIncUse(S, Loops, SE, CheckInvertible = true)
lsr_normalize_for_post_inc_use :: (s: Scev_Id, loops: *[..] Loop_Id) -> Scev_Id {
    if loops.count == 0 return s;
    c: Norm_Ctx; c.denormalize = false; c.loops = loops;
    normalized := normalize_rewrite(s, *c);
    denorm := denormalize_for_post_inc_use(normalized, loops);
    if denorm != s return SCEV_NULL;
    return normalized;
}
// IVUsers::getExpr
iu_get_expr :: (u: *Iv_Stride_Use) -> Scev_Id {
    return lsr_normalize_for_post_inc_use(sc_get_scev(u.operand), *u.post_inc_loops);
}
lsr_find_add_rec_for_loop :: (s: Scev_Id, l: Loop_Id) -> Scev_Id {
    if sc_kind(s) == .ADDREC {
        if sc_loop(s) == l return s;
        return lsr_find_add_rec_for_loop(sc_start(s), l);
    }
    if sc_kind(s) == .ADD {
        for k: 0..cast(s64) sc_nops(s) - 1 {
            ar := lsr_find_add_rec_for_loop(sc_op(s, cast(u32) k), l);
            if ar != SCEV_NULL return ar;
        }
        return SCEV_NULL;
    }
    return SCEV_NULL;
}
// IVUsers::getStride
iu_get_stride :: (u: *Iv_Stride_Use, l: Loop_Id) -> Scev_Id {
    e := iu_get_expr(u);
    if e == SCEV_NULL return SCEV_NULL;
    ar := lsr_find_add_rec_for_loop(e, l);
    if ar != SCEV_NULL return sc_step_recurrence(ar);
    return SCEV_NULL;
}
// IVUsers::AddUser
iu_add_user :: (iu: *Iv_Users, user: Value_Id, operand: Value_Id) -> s64 {
    nu: Iv_Stride_Use;
    nu.user = user; nu.operand = operand;
    nu.post_inc_loops.allocator = temp;
    array_add(*iu.uses, nu);
    return iu.uses.count - 1;
}
lsr_loops_insert :: (l: *[..] Loop_Id, x: Loop_Id) { for l.* if it == x return; array_add(l, x); }

// ---------------------------------------------------------------- Cost

lsr_cost_new :: () -> Lsr_Cost { return .{}; }
cost_is_loser :: (c: *Lsr_Cost) -> bool { return c.num_regs == 0xFFFF_FFFF; }
cost_lose :: (c: *Lsr_Cost) {
    c.insns = 0xFFFF_FFFF; c.num_regs = 0xFFFF_FFFF; c.add_rec_cost = 0xFFFF_FFFF; c.num_iv_muls = 0xFFFF_FFFF;
    c.num_base_adds = 0xFFFF_FFFF; c.imm_cost = 0xFFFF_FFFF; c.setup_cost = 0xFFFF_FFFF; c.scale_cost = 0xFFFF_FFFF;
}
// Cost::isLess: -lsr-insns-cost given explicitly and Insns differ, else TTI.isLSRCostLess
cost_is_less :: (a: *Lsr_Cost, b: *Lsr_Cost) -> bool {
    if lsr_cl.insns_cost_given && lsr_cl.insns_cost && a.insns != b.insns return a.insns < b.insns;
    if lsr_tti.kind == .X86 {
        // X86TTIImpl::isLSRCostLess: std::tie(Insns, NumRegs, AddRecCost, NumIVMuls, NumBaseAdds, ScaleCost, ImmCost, SetupCost)
        x := u32.[a.insns, a.num_regs, a.add_rec_cost, a.num_iv_muls, a.num_base_adds, a.scale_cost, a.imm_cost, a.setup_cost];
        y := u32.[b.insns, b.num_regs, b.add_rec_cost, b.num_iv_muls, b.num_base_adds, b.scale_cost, b.imm_cost, b.setup_cost];
        for k: 0..7 { if x[k] < y[k] return true; if x[k] > y[k] return false; }
        return false;
    }
    // TargetTransformInfoImplBase::isLSRCostLess: std::tie(NumRegs, AddRecCost, NumIVMuls, NumBaseAdds, ScaleCost, ImmCost, SetupCost)
    x := u32.[a.num_regs, a.add_rec_cost, a.num_iv_muls, a.num_base_adds, a.scale_cost, a.imm_cost, a.setup_cost];
    y := u32.[b.num_regs, b.add_rec_cost, b.num_iv_muls, b.num_base_adds, b.scale_cost, b.imm_cost, b.setup_cost];
    for k: 0..6 { if x[k] < y[k] return true; if x[k] > y[k] return false; }
    return false;
}

// getSetupCost
lsr_get_setup_cost :: (reg: Scev_Id, depth: u64) -> u32 {
    k := sc_kind(reg);
    if k == .UNKNOWN return 1;
    if k == .CONSTANT {
        // TTI.getIntImmCost(C, Ty, TCK_RecipThroughput) == TCC_Free
        // TargetTransformInfoImplBase::getIntImmCost: TCC_Basic
        free := ifx lsr_tti.kind == .X86 then x86_int_imm_cost(sc_ap(reg), sc_type(reg)) == TCC_FREE else false;
        return ifx free then cast(u32) 0 else 1;
    }
    if depth == 0 return 0;
    if k == .ADDREC return lsr_get_setup_cost(sc_start(reg), depth - 1);
    if k == .TRUNC || k == .ZEXT || k == .SEXT || k == .PTRTOINT || k == .PTRTOADDR return lsr_get_setup_cost(sc_op(reg, 0), depth - 1);
    if k == .ADD || k == .MUL || k == .UMAX || k == .SMAX || k == .UMIN || k == .SMIN || k == .SEQ_UMIN {
        sum: u32 = 0;
        for i: 0..cast(s64) sc_nops(reg) - 1 sum += lsr_get_setup_cost(sc_op(reg, cast(u32) i), depth - 1);
        return sum;
    }
    if k == .UDIV return lsr_get_setup_cost(sc_op(reg, 0), depth - 1) + lsr_get_setup_cost(sc_op(reg, 1), depth - 1);
    return 0;
}

// Cost::RateRegister
cost_rate_register :: (c: *Lsr_Cost, f: *Lsr_Formula, reg: Scev_Id, regs: *[..] Scev_Id, lu: *Lsr_Use) {
    if sc_kind(reg) == .ADDREC {
        if sc_loop(reg) != lsr.l {
            // AMK & AMK_PostIndexed: the preferred addressing mode is AMK_None on X86
            if lsr_is_existing_phi(reg) return;
            if !li_contains_loop(lsr.li, sc_loop(reg), lsr.l) { cost_lose(c); return; }
            c.num_regs += 1;
            return;
        }
        loop_cost: u32 = 1;
        // isIndexedLoadLegal / isIndexedStoreLegal (MIM_PostInc): false on X86
        if lu.kind == .ICMP_ZERO && lf_counts_down_to_zero(f) && lsr.hardware_loop_profitable loop_cost = 0;
        c.add_rec_cost += loop_cost;
        step_reg := sc_op(reg, 1);
        if !sc_is_affine(reg) || !sc_is_const(step_reg) {
            is_vscale_step := sc_kind(step_reg) == .MUL && sc_nops(step_reg) == 2 && sc_is_const(sc_op(step_reg, 0)) && sc_kind(sc_op(step_reg, 1)) == .VSCALE;
            if is_vscale_step fatal("loop-reduce: vscale steps are not supported");
            if !lsr_set_contains(regs.*, step_reg) {
                cost_rate_register(c, f, step_reg, regs, lu);
                if cost_is_loser(c) return;
            }
        }
    }
    c.num_regs += 1;
    c.setup_cost += lsr_get_setup_cost(reg, lsr_cl.setup_cost_depth_limit);
    c.setup_cost = min(c.setup_cost, cast(u32) (1 << 16));
    if sc_kind(reg) == .MUL && sc_has_computable_loop_evolution(reg, lsr.l) c.num_iv_muls += 1;
}

// Cost::RatePrimaryRegister
cost_rate_primary_register :: (c: *Lsr_Cost, f: *Lsr_Formula, reg: Scev_Id, regs: *[..] Scev_Id, lu: *Lsr_Use, loser_regs: *[..] Scev_Id) {
    if loser_regs && lsr_set_contains(loser_regs.*, reg) { cost_lose(c); return; }
    if lsr_set_insert(regs, reg) {
        cost_rate_register(c, f, reg, regs, lu);
        if loser_regs && cost_is_loser(c) lsr_set_insert(loser_regs, reg);
    }
}

// Cost::RateFormula
cost_rate_formula :: (c: *Lsr_Cost, f: *Lsr_Formula, regs: *[..] Scev_Id, visited_regs: *Table(Scev_Id, bool), lu: *Lsr_Use, loser_regs: *[..] Scev_Id = null) {
    if cost_is_loser(c) return;
    prev_add_rec_cost := c.add_rec_cost;
    prev_num_regs := c.num_regs;
    prev_num_base_adds := c.num_base_adds;
    if f.scaled_reg != SCEV_NULL {
        if table_contains(visited_regs, f.scaled_reg) { cost_lose(c); return; }
        cost_rate_primary_register(c, f, f.scaled_reg, regs, lu, loser_regs);
        if cost_is_loser(c) return;
    }
    for br: f.base_regs {
        if table_contains(visited_regs, br) { cost_lose(c); return; }
        cost_rate_primary_register(c, f, br, regs, lu, loser_regs);
        if cost_is_loser(c) return;
    }
    num_base_parts := lf_num_regs(f);
    if num_base_parts > 1
        c.num_base_adds += cast(u32) (num_base_parts - (1 + (ifx f.scale != 0 && lsr_is_am_completely_folded_lu(lu, f) then 1 else 0)));
    c.num_base_adds += ifx imm_nz(f.unfolded_offset) then cast(u32) 1 else 0;
    c.scale_cost += cast(u32) lsr_get_scaling_factor_cost(lu, f);
    for * fx: lu.fixups {
        if imm_compatible(fx.offset, f.base_offset) {
            offset := imm_add_unsigned(fx.offset, f.base_offset);
            if f.base_gv != NONE c.imm_cost += 64;
            else if imm_nz(offset) c.imm_cost += ap_significant_bits(ap_from_u64(64, cast,no_check(u64) offset.v));
            if lu.kind == .ADDRESS && imm_nz(offset) &&
               !lsr_is_am_completely_folded_kind(.ADDRESS, lu.access_ty, f.base_gv, offset, f.has_base_reg, f.scale)
                c.num_base_adds += 1;
        } else c.imm_cost += 2048;
    }
    if !lsr_cl.insns_cost return;
    tti_reg_num := lsr_num_registers_for(lf_type(f)) - 1;
    if c.num_regs > tti_reg_num {
        if prev_num_regs > tti_reg_num c.insns += (c.num_regs - prev_num_regs);
        else c.insns += (c.num_regs - tti_reg_num);
    }
    if lu.kind == .ICMP_ZERO && !lf_has_zero_end(f) && !lsr_can_macro_fuse_cmp() c.insns += 1;
    c.insns += (c.add_rec_cost - prev_add_rec_cost);
    if lu.kind != .ICMP_ZERO c.insns += c.num_base_adds - prev_num_base_adds;
}
// TTI->getNumberOfRegisters(TTI->getRegisterClassForType(false, Ty))
lsr_num_registers_for :: (ty: Type_Id) -> u32 {
    rc := tti_register_class_for_type(lsr_tti, false, ty);
    return cast(u32) tti_number_of_registers(lsr_tti, rc);
}

// ---------------------------------------------------------------- OptimizeShadowIV

lsr_optimize_shadow_iv :: () {
    btc := sc_get_backedge_taken_count(lsr.l);
    if sc_is_cnc(btc) return;
    ui := 0;
    while ui < lsr.iu.uses.count {
        cand := *lsr.iu.uses[ui];
        ui += 1;
        if !iu_live(cand) continue;
        shadow_use := cand.user;
        dest_ty: Type_Id = NONE;
        is_signed := false;
        if inst_op(shadow_use) == .UITOFP { is_signed = false; dest_ty = vtype(shadow_use); }
        else if inst_op(shadow_use) == .SITOFP { is_signed = true; dest_ty = vtype(shadow_use); }
        if dest_ty == NONE continue;
        if !tti_is_type_legal(lsr_tti, dest_ty) continue;
        ph := op(shadow_use, 0);
        if !is_phi(ph) continue;
        if nops(ph) != 2 continue;
        ar := sc_get_scev(ph);
        if sc_kind(ar) != .ADDREC continue;
        if is_signed && !sc_has_nsw(ar) continue;
        if !is_signed && !sc_has_nuw(ar) continue;
        src_ty := vtype(ph);
        mantissa := fp_mantissa_width(dest_ty);
        if mantissa == -1 continue;
        if cast(s64) sc_type_bits(src_ty) > cast(s64) mantissa continue;
        entry, latch: u32;
        if phi_block(ph, 0) == li_loop_preheader(lsr.li, lsr.l) { entry = 0; latch = 1; } else { entry = 1; latch = 0; }
        init := phi_value(ph, entry);
        if vkind(init) != .C_INT continue;
        init_v := ifx is_signed then cast(float64) ap_sext_value(const_ap(init)) else cast(float64) ap_zext_value(const_ap(init));
        new_init := fp_from_double(dest_ty, init_v);
        incr := phi_value(ph, latch);
        if !is_binary_operator(incr) continue;
        if inst_op(incr) != .ADD && inst_op(incr) != .SUB continue;
        cv: Value_Id = NONE;
        if op(incr, 0) == ph cv = op(incr, 1);
        else if op(incr, 1) == ph cv = op(incr, 0);
        else continue;
        if vkind(cv) != .C_INT continue;
        if !ap_is_strictly_positive(const_ap(cv)) continue;
        new_ph := create_phi(dest_ty, 2);
        insert_at_position(new_ph, inst_block(ph), ph, false);
        set_name(new_ph, "IV.S.");
        set_metadata(new_ph, 0, get_metadata(ph, 0));
        cfp := fp_from_double(dest_ty, cast(float64) ap_zext_value(const_ap(cv)));
        new_incr := create_binop(ifx inst_op(incr) == .ADD then Opcode.FADD else .FSUB, new_ph, cfp);
        insert_at_position(new_incr, inst_block(incr), incr, false);
        set_name(new_incr, "IV.S.next.");
        set_metadata(new_incr, 0, get_metadata(incr, 0));
        phi_add_incoming(new_ph, new_init, phi_block(ph, entry));
        phi_add_incoming(new_ph, new_incr, phi_block(ph, latch));
        rauw_with_metadata(shadow_use, new_ph);
        erase_inst_with_metadata(shadow_use);   // IVStrideUse::deleted: the use leaves IVUsers (iu_live)
        lsr.changed = true;
        break;
    }
}
// FindIVUserForCond -> index into IU (or -1)
lsr_find_iv_user_for_cond :: (cond: Value_Id) -> s64 {
    for * lsr.iu.uses if iu_live(it) && it.user == cond return it_index;
    return -1;
}

// OptimizeMax (CondUse is an index into IU)
lsr_optimize_max :: (cond: Value_Id, cond_use: s64) -> Value_Id {
    p := inst_pred(cond);
    if p != ICMP_EQ && p != ICMP_NE return cond;
    sel := op(cond, 1);
    if !(is_inst(sel) && inst_op(sel) == .SELECT) || !has_one_use(sel) return cond;
    btc := sc_get_backedge_taken_count(lsr.l);
    if sc_is_cnc(btc) return cond;
    one := sc_get_constant_t(sc_type(btc), 1);
    iteration_count := sc_get_add2(one, btc);
    if iteration_count != sc_get_scev(sel) return cond;
    pred: u8 = 0;
    mx: Scev_Id = SCEV_NULL;
    if sc_kind(btc) == .SMAX { pred = ICMP_SLE; mx = btc; }
    else if sc_kind(iteration_count) == .SMAX { pred = ICMP_SLT; mx = iteration_count; }
    else if sc_kind(iteration_count) == .UMAX { pred = ICMP_ULT; mx = iteration_count; }
    else return cond;
    if sc_nops(mx) != 2 return cond;
    max_lhs := sc_op(mx, 0); max_rhs := sc_op(mx, 1);
    if cmp_is_true_when_equal(pred) { if !sc_is_zero(max_lhs) return cond; }
    else if max_lhs != one return cond;
    iv := sc_get_scev(op(cond, 0));
    if !(sc_kind(iv) == .ADDREC && sc_is_affine(iv) && sc_is_const(sc_start(iv)) && ap_is_one(sc_ap(sc_start(iv))) &&
         sc_is_const(sc_op(iv, 1)) && ap_is_one(sc_ap(sc_op(iv, 1)))) return cond;
    new_rhs: Value_Id = NONE;
    if cmp_is_true_when_equal(pred) {
        for k: 1..2 {
            bo := op(sel, cast(u32) k);
            if opr_code(bo) == .ADD {
                c1 := op(bo, 1);
                if vkind(c1) == .C_INT && ap_is_one(const_ap(c1)) && sc_get_scev(op(bo, 0)) == max_rhs new_rhs = op(bo, 0);
            }
        }
        if new_rhs == NONE return cond;
    } else if sc_get_scev(op(sel, 1)) == max_rhs new_rhs = op(sel, 1);
    else if sc_get_scev(op(sel, 2)) == max_rhs new_rhs = op(sel, 2);
    else if sc_kind(max_rhs) == .UNKNOWN new_rhs = sc_value(max_rhs);
    else return cond;
    if inst_pred(cond) == ICMP_EQ pred = icmp_inverse(pred);
    new_cond := create_icmp(pred, op(cond, 0), new_rhs);
    insert_at_position(new_cond, inst_block(cond), cond, false);
    set_name(new_cond, "scmp");
    set_metadata(new_cond, 0, get_metadata(cond, 0));
    rauw_with_metadata(cond, new_cond);
    lsr.iu.uses[cond_use].user = new_cond;   // CondUse->setUser(NewCond)
    cmp := op(sel, 0);
    erase_inst_with_metadata(cond);
    erase_inst_with_metadata(sel);
    if !has_uses(cmp) {
        salvage_debug_info(cmp);
        erase_inst_with_metadata(cmp);
    }
    return new_cond;
}

// OptimizeLoopTermCond
lsr_optimize_loop_term_cond :: () {
    post_incs: [..] Value_Id; post_incs.allocator = temp;
    latch := li_loop_latch(lsr.li, lsr.l);
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(lsr.li, lsr.l, *exiting);
    latch_exits := false;
    for exiting if it == latch latch_exits = true;
    if !latch_exits {
        lsr.iv_inc_insert_pos = block_terminator(latch);
        return;
    }
    for exiting_block: exiting {
        term_br := block_terminator(exiting_block);
        if inst_op(term_br) != .CONDBR continue;
        cond := op(term_br, 0);
        if !is_inst(cond) cond = NONE;
        extract: Value_Id = NONE;
        if cond != NONE && inst_op(cond) == .EXTRACTELEMENT {
            extract = cond;
            cond = op(extract, 0);
            if !is_inst(cond) cond = NONE;
        }
        if cond == NONE continue;
        cond_use := lsr_find_iv_user_for_cond(cond);
        if cond_use < 0 continue;
        if inst_op(cond) == .ICMP cond = lsr_optimize_max(cond, cond_use);
        if !dt_dominates(lsr.dt, exiting_block, latch) continue;
        decline := false;
        if latch != exiting_block {
            for * ui: lsr.iu.uses {
                if decline break;
                if !iu_live(ui) || it_index == cond_use continue;
                if dt_properly_dominates(lsr.dt, inst_block(ui.user), exiting_block) continue;
                a := iu_get_stride(*lsr.iu.uses[cond_use], lsr.l);
                b := iu_get_stride(ui, lsr.l);
                if a == SCEV_NULL || b == SCEV_NULL continue;
                if sc_type_bits(sc_type(a)) != sc_type_bits(sc_type(b)) {
                    if sc_type_bits(sc_type(a)) > sc_type_bits(sc_type(b)) b = sc_get_sign_extend(b, sc_type(a));
                    else a = sc_get_sign_extend(a, sc_type(b));
                }
                d := lsr_get_exact_sdiv(b, a);
                if d != SCEV_NULL && sc_is_const(d) {
                    cv := sc_ap(d);
                    if ap_is_one(cv) || ap_is_all_ones(cv) { decline = true; break; }
                    if ap_significant_bits(cv) >= 64 || ap_is_min_signed(cv) { decline = true; break; }
                    if lsr_is_address_use(ui.user, ui.operand) {
                        at := lsr_get_access_type(ui.user, ui.operand);
                        scale := ap_sext_value(cv);
                        if lsr_is_legal_addressing_mode(at.mem_ty, NONE, 0, true, scale, at.as, 0) { decline = true; break; }
                        scale = -scale;
                        if lsr_is_legal_addressing_mode(at.mem_ty, NONE, 0, true, scale, at.as, 0) { decline = true; break; }
                    }
                }
            }
        }
        if decline continue;
        o := inst_op(cond);
        if (o == .ICMP || o == .FCMP) && inst_next(cond) != term_br && extract == NONE {
            if has_one_use(cond) {
                inst_move_before_dbg(cond, term_br);
            } else {
                old_cond := cond;
                cond = ic_clone_inst(cond);
                set_name(cond, tconcat(vname(li_header(lsr.li, lsr.l)), ".termcond"));
                insert_at_position(cond, exiting_block, term_br, false);
                cond_use = iu_add_user(lsr.iu, cond, lsr.iu.uses[cond_use].operand);
                replace_uses_of_with(term_br, old_cond, cond);
            }
        }
        lsr_loops_insert(*lsr.iu.uses[cond_use].post_inc_loops, lsr.l);   // transformToPostInc(L)
        lsr.changed = true;
        lsr_set_insert_v(*post_incs, cond);
    }
    lsr.iv_inc_insert_pos = block_terminator(li_loop_latch(lsr.li, lsr.l));
    for inst: post_incs lsr.iv_inc_insert_pos = dt_find_nearest_common_dominator_inst(lsr.dt, lsr.iv_inc_insert_pos, inst);
}
lsr_set_insert_v :: (l: *[..] Value_Id, v: Value_Id) -> bool { for l.* if it == v return false; array_add(l, v); return true; }

// reconcileNewOffset
lsr_reconcile_new_offset :: (lu: *Lsr_Use, new_offset: Lsr_Imm, has_base_reg: bool, kind: Lsr_Kind, at: Lsr_Mem_Ty) -> bool {
    new_min := lu.min_offset; new_max := lu.max_offset;
    new_at := at;
    if lu.kind != kind return false;
    if kind == .ADDRESS && at.mem_ty != lu.access_ty.mem_ty new_at = lsr_mem_unknown(at.as);
    if imm_known_lt(new_offset, lu.min_offset) {
        if !lsr_is_always_foldable(kind, new_at, NONE, imm_sub_unsigned(lu.max_offset, new_offset), has_base_reg) return false;
        new_min = new_offset;
    } else if imm_known_gt(new_offset, lu.max_offset) {
        if !lsr_is_always_foldable(kind, new_at, NONE, imm_sub_unsigned(new_offset, lu.min_offset), has_base_reg) return false;
        new_max = new_offset;
    }
    if new_at.mem_ty != NONE && type_kind(new_at.mem_ty) == .VOID && (new_min.scalable || new_max.scalable) return false;
    lu.min_offset = new_min;
    lu.max_offset = new_max;
    lu.access_ty = new_at;
    return true;
}

// getUse(Expr, Kind, AccessTy) -> (LUIdx, Offset); Expr is updated
lsr_get_use :: (expr: *Scev_Id, kind: Lsr_Kind, at: Lsr_Mem_Ty) -> (s64, Lsr_Imm) {
    copy := expr.*;
    offset := lsr_extract_immediate(expr);
    if !lsr_is_always_foldable(kind, at, NONE, offset, true) {
        expr.* = copy;
        offset = imm_fixed(0);
    }
    key := Lsr_Use_Key.{expr.*, kind};
    found := -1;
    for lsr.use_map_keys if it.s == key.s && it.kind == key.kind { found = it_index; break; }
    if found >= 0 {
        lu_idx := lsr.use_map_vals[found];
        if lsr_reconcile_new_offset(*lsr.uses[lu_idx], offset, true, kind, at) return lu_idx, offset;
    }
    lu_idx := lsr.uses.count;
    if found >= 0 lsr.use_map_vals[found] = lu_idx;
    else { array_add(*lsr.use_map_keys, key); array_add(*lsr.use_map_vals, lu_idx); }
    array_add(*lsr.uses, lsr_use_new(kind, at));
    lu := *lsr.uses[lu_idx];
    lu.min_offset = offset;
    lu.max_offset = offset;
    return lu_idx, offset;
}

// DeleteUse(LU, LUIdx)
lsr_delete_use :: (lu_idx: s64) {
    last := lsr.uses.count - 1;
    if lu_idx != last { t := lsr.uses[lu_idx]; lsr.uses[lu_idx] = lsr.uses[last]; lsr.uses[last] = t; }
    lsr.uses.count -= 1;
    ru_swap_and_drop_use(*lsr.reg_uses, lu_idx, lsr.uses.count);
}

// FindUseWithSimilarFormula -> use index or -1
lsr_find_use_with_similar_formula :: (orig_f: *Lsr_Formula, orig_lu: s64) -> s64 {
    olu := *lsr.uses[orig_lu];
    for * lu, lu_i: lsr.uses {
        if lu_i != orig_lu && lu.kind != .ICMP_ZERO && lu.kind == olu.kind && olu.access_ty.mem_ty == lu.access_ty.mem_ty &&
           olu.access_ty.as == lu.access_ty.as && lu_has_formula_with_same_regs(lu, orig_f) {
            for * f: lu.formulae {
                if lsr_key_eq(f.base_regs, orig_f.base_regs) && f.scaled_reg == orig_f.scaled_reg && f.base_gv == orig_f.base_gv &&
                   f.scale == orig_f.scale && imm_eq(f.unfolded_offset, orig_f.unfolded_offset) {
                    if imm_is_zero(f.base_offset) return lu_i;
                    break;
                }
            }
        }
    }
    return -1;
}

// CollectInterestingTypesAndFactors
lsr_collect_interesting_types_and_factors :: () {
    strides: [..] Scev_Id; strides.allocator = temp;
    worklist: [..] Scev_Id; worklist.allocator = temp;
    for * u: lsr.iu.uses {
        if !iu_live(u) continue;
        e := iu_get_expr(u);
        if e == SCEV_NULL continue;
        t := sc_effective_type(sc_type(e));
        dup := false;
        for lsr.types if it == t dup = true;
        if !dup array_add(*lsr.types, t);
        array_add(*worklist, e);
        while worklist.count {
            s := pop(*worklist);
            if sc_kind(s) == .ADDREC {
                if sc_loop(s) == lsr.l lsr_set_insert(*strides, sc_step_recurrence(s));
                array_add(*worklist, sc_start(s));
            } else if sc_kind(s) == .ADD {
                for k: 0..cast(s64) sc_nops(s) - 1 array_add(*worklist, sc_op(s, cast(u32) k));
            }
        }
    }
    add_factor :: (v: s64) { for lsr.factors if it == v return; array_add(*lsr.factors, v); }
    for i: 0..strides.count-1 {
        for j: i+1..strides.count-1 {
            old_stride := strides[i]; new_stride := strides[j];
            if sc_type_bits(sc_type(old_stride)) != sc_type_bits(sc_type(new_stride)) {
                if sc_type_bits(sc_type(old_stride)) > sc_type_bits(sc_type(new_stride)) new_stride = sc_get_sign_extend(new_stride, sc_type(old_stride));
                else old_stride = sc_get_sign_extend(old_stride, sc_type(new_stride));
            }
            f1 := lsr_get_exact_sdiv(new_stride, old_stride, true);
            if f1 != SCEV_NULL && sc_is_const(f1) {
                if ap_significant_bits(sc_ap(f1)) <= 64 && !sc_is_zero(f1) add_factor(ap_sext_value(sc_ap(f1)));
            } else {
                f2 := lsr_get_exact_sdiv(old_stride, new_stride, true);
                if f2 != SCEV_NULL && sc_is_const(f2) {
                    if ap_significant_bits(sc_ap(f2)) <= 64 && !sc_is_zero(f2) add_factor(ap_sext_value(sc_ap(f2)));
                }
            }
        }
    }
    if lsr.types.count == 1 lsr.types.count = 0;
}
