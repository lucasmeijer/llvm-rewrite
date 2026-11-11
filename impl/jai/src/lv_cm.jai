// LoopVectorizationCostModel: per-VF widening decisions, uniforms, scalars, predication queries.
// Ported from llvm/lib/Transforms/Vectorize/LoopVectorize.cpp (LoopVectorizationCostModel) (LLVM 23.1.5).
// The costs themselves (getInstructionCost and friends) are in lv_cost.jai.

Lv_Widening :: enum u8 { UNKNOWN; WIDEN; WIDEN_REVERSE; INTERLEAVE; GATHER_SCATTER; SCALARIZE; INVALIDATED; }

Lv_Decision :: struct { w: Lv_Widening; cost: s64; }

Lv_Cm_Vf :: struct {
    vf: Ec;
    uniforms: Iset;
    scalars: Iset;
    forced_scalars: [..] Value_Id;
    insts_to_scalarize: [..] Value_Id;         // MapVector keys of InstsToScalarize[VF]
    insts_to_scalarize_cost: [..] Cost;        // ... and their scalar costs
    predicated_bbs: Iset;                      // PredicatedBBsAfterVectorization[VF]
    scalars_done: bool;                        // Scalars.contains(VF)
}

lv_cm_vf_state :: (cm: *Lv_Cm, vf: Ec, create := false) -> *Lv_Cm_Vf {
    for *cm.per_vf if ec_eq(it.vf, vf) return it;
    if !create return null;
    s: Lv_Cm_Vf;
    s.vf = vf; s.uniforms = iset_new(); s.scalars = iset_new(); s.predicated_bbs = iset_new();
    s.forced_scalars.allocator = temp; s.insts_to_scalarize.allocator = temp; s.insts_to_scalarize_cost.allocator = temp;
    array_add(*cm.per_vf, s);
    return *cm.per_vf[cm.per_vf.count - 1];
}
lv_dec_key :: (i: Value_Id, vf: Ec) -> u64 { return ((cast(u64) i) << 32) | vf.n | (ifx vf.scalable then (cast(u64) 1) << 31 else 0); }

lv_cm_set_widening_decision :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, w: Lv_Widening, cost: s64) {
    table_set(*cm.decisions, lv_dec_key(i, vf), .{w, cost});
}
lv_cm_widening_decision :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> Lv_Widening {
    found, d := table_find(*cm.decisions, lv_dec_key(i, vf));
    if !found return .UNKNOWN;
    return d.w;
}
lv_cm_is_mask_required :: (cm: *Lv_Cm, i: Value_Id) -> bool { return lvl_is_mask_required(cm.lvl, i, lv_cm_fold_tail_by_masking(cm)); }
lv_cm_block_needs_predication_for_any_reason :: (cm: *Lv_Cm, bb: Value_Id) -> bool {
    return lv_cm_fold_tail_by_masking(cm) || lvl_block_needs_predication(cm.lvl, bb);
}

// isPredicatedInst
lv_cm_is_predicated_inst :: (cm: *Lv_Cm, i: Value_Id) -> bool {
    o := inst_op(i);
    if lv_is_safe_to_speculatively_execute(i) || ((o == .LOAD || o == .STORE || o == .CALL) && !lv_cm_is_mask_required(cm, i)) ||
       o == .BR || o == .CONDBR || o == .SWITCH || o == .PHI || o == .ALLOCA
        return false;
    if lvl_block_needs_predication(cm.lvl, inst_block(i)) return true;
    if !lv_cm_fold_tail_by_masking(cm) && !lvl_has_uncountable_exit_with_side_effects(cm.lvl) return false;
    if o == {
        case .CALL; return true;
        case .LOAD; return !lvl_is_invariant(cm.lvl, op(i, 0));
        case .STORE; return !(lvl_is_invariant(cm.lvl, op(i, 1)) && li_is_loop_invariant(cm.li, cm.l, op(i, 0)));
        case .UDIV; #through; case .UREM; return !lvl_is_invariant(cm.lvl, op(i, 1));
        case .SDIV; #through; case .SREM; return true;
    }
    fatal("internal: instruction should have been considered by earlier checks");
    return false;
}

// VFSelectionContext::isLegalMaskedLoadOrStore / isLegalGatherOrScatter
lv_is_legal_masked_load_or_store :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if lv_opts.force_target_supports_masked_memory_ops return true;
    if cm.tti.kind != .X86 return false;
    ty := load_store_type(i);
    if inst_op(i) == .LOAD return x86_is_legal_masked_load(*cm.tti.xl, ty);
    return x86_is_legal_masked_store(*cm.tti.xl, ty);
}
lv_is_legal_gather_or_scatter :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    o := inst_op(i);
    if o != .LOAD && o != .STORE return false;
    if lv_opts.force_target_supports_gather_scatter_ops return true;
    if cm.tti.kind != .X86 return false;
    ty := load_store_type(i);
    if ec_is_vector(vf) ty = type_vector(vf.n, ty, vf.scalable);
    if o == .LOAD return x86_is_legal_masked_gather(*cm.tti.xl, ty);
    return x86_is_legal_masked_scatter(*cm.tti.xl, ty);
}

// isScalarWithPredication
lv_cm_is_scalar_with_predication :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if !lv_cm_is_predicated_inst(cm, i) return false;
    o := inst_op(i);
    if o == {
        case .CALL;
            if ec_is_scalar(vf) return true;
            return get_vector_intrinsic_id_for_call(i) == NOT_INTRINSIC;   // no vector library variants
        case .LOAD; #through; case .STORE;
            cons := lvl_is_consecutive_ptr(cm.lvl, load_store_type(i), load_store_pointer_operand(i)) != 0;
            return !(cons && lv_is_legal_masked_load_or_store(cm, i, vf)) && !lv_is_legal_gather_or_scatter(cm, i, vf);
        case .UDIV; #through; case .SDIV; #through; case .SREM; #through; case .UREM;
            sc, mc := lv_cm_div_rem_speculation_cost(cm, i, vf);
            return lv_cm_is_div_rem_scalar_with_predication(sc, mc);
    }
    return true;
}

// hasIrregularType
lv_has_irregular_type :: (t: Type_Id) -> bool { return dl_type_alloc_size(t) * 8 != dl_type_size_bits(t); }

// memoryInstructionCanBeWidened
lv_cm_memory_instruction_can_be_widened :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> (bool, Lv_Widening) {
    ptr := load_store_pointer_operand(i);
    ty := load_store_type(i);
    stride := lvl_is_consecutive_ptr(cm.lvl, ty, ptr);
    if stride == 0 return false, .UNKNOWN;
    if lv_cm_is_scalar_with_predication(cm, i, vf) return false, .UNKNOWN;
    if lv_has_irregular_type(ty) return false, .UNKNOWN;
    return true, ifx stride == 1 then Lv_Widening.WIDEN else .WIDEN_REVERSE;
}

// LoopVectorizationCostModel::isUniform / isUniformMemOp (PartialAliasMaskingStatus is Disabled: pass the VF)
lv_cm_is_uniform :: (cm: *Lv_Cm, v: Value_Id, vf: Ec) -> bool {
    assert(cm.alias_masking != .NOT_DECIDED, "alias-mask status must be decided already");
    return lvl_is_uniform(cm.lvl, v, vf, cm.alias_masking == .DISABLED);
}
lv_cm_is_uniform_mem_op :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    return lvl_is_uniform_mem_op(cm.lvl, i, vf, cm.alias_masking == .DISABLED);
}

// setCostBasedWideningDecision
lv_cm_set_cost_based_widening_decision :: (cm: *Lv_Cm, vf: Ec) {
    if ec_is_scalar(vf) return;
    cm.num_pred_stores = 0;
    for bb: li_blocks(cm.li, cm.l) for i: block_insts(bb)
        if inst_op(i) == .STORE && lv_cm_is_scalar_with_predication(cm, i, vf) cm.num_pred_stores += 1;
    for bb: li_blocks(cm.li, cm.l) for i: block_insts(bb) {
        ptr := load_store_pointer_operand(i);
        if ptr == NONE continue;
        if lv_cm_is_uniform_mem_op(cm, i, vf) {
            legal_to_scalarize := !vf.scalable || !lv_cm_fold_tail_by_masking(cm) || inst_op(i) == .LOAD || li_is_loop_invariant(cm.li, cm.l, op(i, 0));
            gs := ifx lv_is_legal_gather_or_scatter(cm, i, vf) then lv_cm_gather_scatter_cost(cm, i, vf) else COST_INVALID;
            sc := ifx legal_to_scalarize then lv_cm_uniform_mem_op_cost(cm, i, vf) else COST_INVALID;
            if gs < sc lv_cm_set_widening_decision(cm, i, vf, .GATHER_SCATTER, gs);
            else lv_cm_set_widening_decision(cm, i, vf, .SCALARIZE, sc);
            continue;
        }
        ok, dec := lv_cm_memory_instruction_can_be_widened(cm, i, vf);
        if ok { lv_cm_set_widening_decision(cm, i, vf, dec, lv_cm_consecutive_mem_op_cost(cm, i, vf, dec)); continue; }
        // interleave groups: processLoop fails loudly when InterleavedAccessInfo forms any group
        num_accesses: s64 = 1;
        gs := ifx lv_is_legal_gather_or_scatter(cm, i, vf) then lc_mul(lv_cm_gather_scatter_cost(cm, i, vf), num_accesses) else COST_INVALID;
        sc := lc_mul(lv_cm_mem_inst_scalarization_cost(cm, i, vf), num_accesses);
        if gs < sc lv_cm_set_widening_decision(cm, i, vf, .GATHER_SCATTER, gs);
        else lv_cm_set_widening_decision(cm, i, vf, .SCALARIZE, sc);
    }
    if lv_tti_prefers_vectorized_addressing(cm.tti) return;
    addr_defs: [..] Value_Id; addr_defs.allocator = temp;   // SmallSetVector
    add_def :: (s: *[..] Value_Id, v: Value_Id) -> bool { if array_find(s.*, v) return false; array_add(s, v); return true; }
    for bb: li_blocks(cm.li, cm.l) for i: block_insts(bb) {
        pd := load_store_pointer_operand(i);
        if pd == NONE || !is_inst(pd) || !li_contains_inst(cm.li, cm.l, pd) continue;
        if lv_cm_widening_decision(cm, i, vf) == .GATHER_SCATTER continue;
        add_def(*addr_defs, pd);
    }
    wl: [..] Value_Id; wl.allocator = temp;
    for addr_defs array_add(*wl, it);
    while wl.count {
        i := pop(*wl);
        for k: 0..cast(s64) nops(i) - 1 {
            o := op(i, cast(u32) k);
            if is_inst(o) && li_contains_inst(cm.li, cm.l, o) && inst_op(o) != .PHI && add_def(*addr_defs, o) array_add(*wl, o);
        }
    }
    update_mem_op_user_cost :: (cm: *Lv_Cm, li_: Value_Id, vf: Ec) {
        u := ir.v_first_use[li_];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if inst_op(usr) != .LOAD && inst_op(usr) != .STORE continue;
            if lv_cm_widening_decision(cm, usr, vf) != .SCALARIZE continue;
            lv_cm_set_widening_decision(cm, usr, vf, .SCALARIZE, lv_cm_mem_inst_scalarization_cost(cm, usr, vf));
        }
    }
    st := lv_cm_vf_state(cm, vf);
    for i: addr_defs {
        if inst_op(i) == .LOAD {
            dec := lv_cm_widening_decision(cm, i, vf);
            if !lv_cm_is_predicated_inst(cm, i) && (dec == .WIDEN || dec == .WIDEN_REVERSE || (!lv_cm_is_uniform_mem_op(cm, i, vf) && dec == .SCALARIZE)) {
                lv_cm_set_widening_decision(cm, i, vf, .SCALARIZE, lc_mul(lv_cm_memory_instruction_cost(cm, i, ec_fixed(1)), cast(s64) vf.n));
                update_mem_op_user_cost(cm, i, vf);
            }
            // interleave groups fail loudly before the cost model runs
            continue;
        }
        if inst_op(i) == .PHI && lvl_is_fixed_order_recurrence(cm.lvl, i) continue;
        if !array_find(st.forced_scalars, i) array_add(*st.forced_scalars, i);
    }
}
// TTI::prefersVectorizedAddressing: true for NoTTI; X86 returns supportsGather()
lv_tti_prefers_vectorized_addressing :: (t: *Tti) -> bool {
    if t.kind != .X86 return true;
    return x86_supports_gather(*t.xl);
}

// collectLoopUniforms
lv_cm_collect_loop_uniforms :: (cm: *Lv_Cm, vf: Ec) {
    st := lv_cm_vf_state(cm, vf, true);
    li := cm.li; l := cm.l;
    wl: [..] Value_Id; wl.allocator = temp;
    inwl := iset_new();
    out_of_scope :: (cm: *Lv_Cm, v: Value_Id) -> bool { return !is_inst(v) || !li_contains_inst(cm.li, cm.l, v); }
    add_if_allowed :: (cm: *Lv_Cm, i: Value_Id, wl: *[..] Value_Id, inwl: *Iset) {
        if out_of_scope(cm, i) return;
        if lv_cm_is_predicated_inst(cm, i) return;
        if iset_insert(inwl, i) array_add(wl, i);
    }
    exiting: [..] Value_Id; exiting.allocator = temp;
    li_exiting_blocks(li, l, *exiting);
    for e: exiting {
        if lvl_has_uncountable_early_exit(cm.lvl) && li_loop_latch(li, l) != e continue;
        t := block_terminator(e);
        if nops(t) == 0 continue;
        c := op(t, 0);
        if is_inst(c) && li_contains_inst(li, l, c) && has_one_use(c) add_if_allowed(cm, c, *wl, *inwl);
    }
    prev_vf := Ec.{vf.n / 2, vf.scalable};
    is_uniform_mem_op_use :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, prev_vf: Ec) -> bool {
        if ec_is_vector(prev_vf) {
            ps := lv_cm_vf_state(cm, prev_vf);
            if ps && !iset_has(*ps.uniforms, i) return false;
        }
        if !lv_cm_is_uniform_mem_op(cm, i, vf) return false;
        if inst_op(i) == .LOAD return true;
        return li_is_loop_invariant(cm.li, cm.l, op(i, 0));
    }
    is_uniform_decision :: (cm: *Lv_Cm, i: Value_Id, vf: Ec, prev_vf: Ec) -> bool {
        d := lv_cm_widening_decision(cm, i, vf);
        if is_uniform_mem_op_use(cm, i, vf, prev_vf) return true;
        return d == .WIDEN || d == .WIDEN_REVERSE || d == .INTERLEAVE;
    }
    is_vectorized_mem_access_use :: (cm: *Lv_Cm, i: Value_Id, ptr: Value_Id, vf: Ec, prev_vf: Ec) -> bool {
        if inst_op(i) == .STORE && op(i, 0) == ptr return false;
        return load_store_pointer_operand(i) == ptr && (is_uniform_decision(cm, i, vf, prev_vf) || lvl_is_invariant(cm.lvl, ptr));
    }
    has_uniform_use: [..] Value_Id; has_uniform_use.allocator = temp;
    for bb: li_blocks(li, l) for i: block_insts(bb) {
        id := call_iid(i);
        if inst_op(i) == .CALL && (id == IID_SIDEEFFECT || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL || id == IID_ASSUME ||
                                   id == IID_LIFETIME_START || id == IID_LIFETIME_END) {
            if li_has_loop_invariant_operands(li, l, i) add_if_allowed(cm, i, *wl, *inwl);
        }
        if inst_op(i) == .EXTRACTVALUE {
            if out_of_scope(cm, op(i, 0)) { add_if_allowed(cm, i, *wl, *inwl); continue; }
        }
        ptr := load_store_pointer_operand(i);
        if ptr == NONE continue;
        if is_inst(ptr) && lv_cm_is_uniform(cm, ptr, vf) add_if_allowed(cm, ptr, *wl, *inwl);
        if is_uniform_mem_op_use(cm, i, vf, prev_vf) add_if_allowed(cm, i, *wl, *inwl);
        if is_vectorized_mem_access_use(cm, i, ptr, vf, prev_vf) && !array_find(has_uniform_use, ptr) array_add(*has_uniform_use, ptr);
    }
    for v: has_uniform_use {
        if out_of_scope(cm, v) continue;
        all := true;
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u];
            if !(li_contains_inst(li, l, usr) && is_vectorized_mem_access_use(cm, usr, v, vf, prev_vf)) { all = false; break; }
            u = ir.u_next[u];
        }
        if all add_if_allowed(cm, v, *wl, *inwl);
    }
    idx := 0;
    while idx < wl.count {
        i := wl[idx]; idx += 1;
        for k: 0..cast(s64) nops(i) - 1 {
            ov := op(i, cast(u32) k);
            if inst_op(i) == .PHI && false {}
            if out_of_scope(cm, ov) continue;
            if is_phi(ov) && lvl_is_fixed_order_recurrence(cm.lvl, ov) continue;
            all := true;
            u := ir.v_first_use[ov];
            while u != NONE {
                j := ir.u_user[u];
                if !(iset_has(*inwl, j) || is_vectorized_mem_access_use(cm, j, ov, vf, prev_vf)) { all = false; break; }
                u = ir.u_next[u];
            }
            if all add_if_allowed(cm, ov, *wl, *inwl);
        }
    }
    latch := li_loop_latch(li, l);
    for *cm.lvl.inductions {
        ind := it.phi;
        upd := phi_incoming_value_for_block(ind, latch);
        ok := true;
        u := ir.v_first_use[ind];
        while u != NONE {
            usr := ir.u_user[u];
            if !(usr == upd || !li_contains_inst(li, l, usr) || iset_has(*inwl, usr) || is_vectorized_mem_access_use(cm, usr, ind, vf, prev_vf)) { ok = false; break; }
            u = ir.u_next[u];
        }
        if !ok continue;
        u = ir.v_first_use[upd];
        while u != NONE {
            usr := ir.u_user[u];
            if !(usr == ind || iset_has(*inwl, usr) || is_vectorized_mem_access_use(cm, usr, upd, vf, prev_vf)) { ok = false; break; }
            u = ir.u_next[u];
        }
        if !ok continue;
        add_if_allowed(cm, ind, *wl, *inwl);
        add_if_allowed(cm, upd, *wl, *inwl);
    }
    for wl iset_insert(*st.uniforms, it);
}

// collectLoopScalars
lv_cm_collect_loop_scalars :: (cm: *Lv_Cm, vf: Ec) {
    st := lv_cm_vf_state(cm, vf, true);
    if vf.scalable vp_unported("scalable VFs");
    li := cm.li; l := cm.l;
    wl: [..] Value_Id; wl.allocator = temp;
    inwl := iset_new();
    add :: (wl: *[..] Value_Id, inwl: *Iset, i: Value_Id) { if iset_insert(inwl, i) array_add(wl, i); }
    scalar_ptrs: [..] Value_Id; scalar_ptrs.allocator = temp;
    possible_non_scalar := iset_new();
    latch := li_loop_latch(li, l);
    is_scalar_use :: (cm: *Lv_Cm, mem: Value_Id, ptr: Value_Id, vf: Ec) -> bool {
        d := lv_cm_widening_decision(cm, mem, vf);
        if inst_op(mem) == .STORE && ptr == op(mem, 0) return d == .SCALARIZE;
        return d != .GATHER_SCATTER;
    }
    is_loop_varying_gep :: (cm: *Lv_Cm, v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .GEP && !li_is_loop_invariant(cm.li, cm.l, v); }
    evaluate_ptr_use :: (cm: *Lv_Cm, mem: Value_Id, ptr: Value_Id, vf: Ec, inwl: *Iset, scalar_ptrs: *[..] Value_Id, pns: *Iset) {
        if !is_loop_varying_gep(cm, ptr) return;
        if iset_has(inwl, ptr) return;
        all_mem := true;
        u := ir.v_first_use[ptr];
        while u != NONE { o := inst_op(ir.u_user[u]); if o != .LOAD && o != .STORE { all_mem = false; break; } u = ir.u_next[u]; }
        if is_scalar_use(cm, mem, ptr, vf) && all_mem { if !array_find(scalar_ptrs.*, ptr) array_add(scalar_ptrs, ptr); }
        else iset_insert(pns, ptr);
    }
    for k: 0..1 {}   // (Worklist starts with Uniforms[VF], in insertion order)
    for i: lv_iset_ordered(*st.uniforms, cm) add(*wl, *inwl, i);
    for bb: li_blocks(li, l) for i: block_insts(bb) {
        if inst_op(i) == .LOAD evaluate_ptr_use(cm, i, op(i, 0), vf, *inwl, *scalar_ptrs, *possible_non_scalar);
        else if inst_op(i) == .STORE {
            evaluate_ptr_use(cm, i, op(i, 1), vf, *inwl, *scalar_ptrs, *possible_non_scalar);
            evaluate_ptr_use(cm, i, op(i, 0), vf, *inwl, *scalar_ptrs, *possible_non_scalar);
        }
    }
    for scalar_ptrs if !iset_has(*possible_non_scalar, it) add(*wl, *inwl, it);
    for st.forced_scalars add(*wl, *inwl, it);
    idx := 0;
    while idx < wl.count {
        dst := wl[idx]; idx += 1;
        if nops(dst) == 0 || !is_loop_varying_gep(cm, op(dst, 0)) continue;
        src := op(dst, 0);
        all := true;
        u := ir.v_first_use[src];
        while u != NONE {
            j := ir.u_user[u];
            if !(!li_contains_inst(li, l, j) || iset_has(*inwl, j) || ((inst_op(j) == .LOAD || inst_op(j) == .STORE) && is_scalar_use(cm, j, src, vf))) { all = false; break; }
            u = ir.u_next[u];
        }
        if all add(*wl, *inwl, src);
    }
    for *cm.lvl.inductions {
        ind := it.phi;
        upd := phi_incoming_value_for_block(ind, latch);
        if ind == cm.lvl.primary_induction && lv_cm_fold_tail_by_masking(cm) continue;
        is_ptr_ind := it.d.kind == .PTR;
        direct :: (cm: *Lv_Cm, indvar: Value_Id, i: Value_Id, is_ptr_ind: bool, vf: Ec) -> bool {
            return is_ptr_ind && (inst_op(i) == .LOAD || inst_op(i) == .STORE) && indvar == load_store_pointer_operand(i) && is_scalar_use(cm, i, indvar, vf);
        }
        ok := true;
        u := ir.v_first_use[ind];
        while u != NONE {
            usr := ir.u_user[u];
            if !(usr == upd || !li_contains_inst(li, l, usr) || iset_has(*inwl, usr) || direct(cm, ind, usr, is_ptr_ind, vf)) { ok = false; break; }
            u = ir.u_next[u];
        }
        if !ok continue;
        if is_phi(upd) && lvl_is_fixed_order_recurrence(cm.lvl, upd) continue;
        u = ir.v_first_use[upd];
        while u != NONE {
            usr := ir.u_user[u];
            if !(usr == ind || !li_contains_inst(li, l, usr) || iset_has(*inwl, usr) || direct(cm, upd, usr, is_ptr_ind, vf)) { ok = false; break; }
            u = ir.u_next[u];
        }
        if !ok continue;
        add(*wl, *inwl, ind);
        add(*wl, *inwl, upd);
    }
    for wl iset_insert(*st.scalars, it);
    st.scalars_done = true;
}
// the members of a set in loop-instruction order (only membership is used afterwards)
lv_iset_ordered :: (s: *Iset, cm: *Lv_Cm) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    for bb: li_blocks(cm.li, cm.l) for i: block_insts(bb) if iset_has(s, i) array_add(*out, i);
    return out;
}

// collectNonVectorizedAndSetWideningDecisions
lv_cm_collect_non_vectorized_and_set_widening_decisions :: (cm: *Lv_Cm, vf: Ec) {
    if ec_is_scalar(vf) return;
    if lv_cm_vf_state(cm, vf) return;
    lv_cm_vf_state(cm, vf, true);
    lv_cm_set_cost_based_widening_decision(cm, vf);
    lv_cm_collect_loop_uniforms(cm, vf);
    lv_cm_collect_loop_scalars(cm, vf);
    lv_cm_collect_insts_to_scalarize(cm, vf);
}

lv_cm_is_uniform_after_vectorization :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if ec_is_scalar(vf) return true;
    if call_iid(i) == IID_PSEUDOPROBE return false;
    st := lv_cm_vf_state(cm, vf);
    return iset_has(*st.uniforms, i);
}
lv_cm_is_scalar_after_vectorization :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if ec_is_scalar(vf) return true;
    st := lv_cm_vf_state(cm, vf);
    return iset_has(*st.scalars, i);
}
lv_cm_is_profitable_to_scalarize :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    st := lv_cm_vf_state(cm, vf);
    return array_find(st.insts_to_scalarize, i);
}
// isOptimizableIVTruncate
lv_cm_is_optimizable_iv_truncate :: (cm: *Lv_Cm, i: Value_Id, vf: Ec) -> bool {
    if !is_inst(i) || inst_op(i) != .TRUNC return false;
    o := op(i, 0);
    if o != cm.lvl.primary_induction && lv_tti_is_truncate_free(cm.tti, lv_to_vector_ty(vtype(o), vf), lv_to_vector_ty(vtype(i), vf)) return false;
    return lvl_is_induction_phi(cm.lvl, o);
}
lv_tti_is_truncate_free :: (t: *Tti, src: Type_Id, dst: Type_Id) -> bool {
    if t.kind != .X86 return false;
    return tti_is_truncate_free(t, src, dst);
}
// toVectorTy
lv_to_vector_ty :: (t: Type_Id, vf: Ec) -> Type_Id {
    if ec_is_scalar(vf) || type_kind(t) == .VOID return t;
    if type_kind(t) == .STRUCT vp_unported("struct-typed values in toVectorTy");
    return type_vector(vf.n, t, vf.scalable);
}
