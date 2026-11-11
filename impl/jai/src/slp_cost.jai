// SLPVectorizer: the per-entry cost model. Ported from llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp
// (BoUpSLP::getEntryCost, getOperandInfo, getCastContextHint, getLoopTripCount, getScaleToLoopIterations,
// getLoopNestScale, getGatherNodeEffectiveScale, getVectorSpillReloadCost, getGatherCost, getGEPCosts,
// canVectorStoreInsertValue, getInsertBuildVectorSrcTy, TreeEntry::getSplitMask / hasEqualOperands,
// getNumScalarInsts / getNumVectorInsts, isTreeNotExtendable, getRootNodeTypeWithNoCast, getReductionType,
// isReducedBitcastRoot / isReducedCmpBitcastRoot, the static getVectorInstrCost / getExtractWithExtendCost
// wrappers) and the X86TTIImpl / BasicTTIImplBase / TargetTransformInfoImplBase queries they make that tti*.jai
// does not have yet (getPointersChainCost, getExtractWithExtendCost, getCallInstrCost, getAltInstrCost,
// getRegisterClassSpillCost / ReloadCost, getCostOfKeepingLiveOverCall).
//
// The GetCostDiff / GetScalarCost / GetVectorCost lambdas of getEntryCost are `Slp_Ec` (their captured state) and the
// `ec_scalar_elt_cost` / `ec_vector_cost` switches on the entry's ShuffleOrOp.

cost_sub :: (a: Cost, b: Cost) -> Cost {
    if !cost_valid(a) || !cost_valid(b) return COST_INVALID;
    return a - b;
}
cost_scale :: (c: Cost, s: u64) -> Cost {
    if !cost_valid(c) return c;
    return c * cast(s64) s;
}

// ---------------------------------------------------------------- small TTI queries

// TTI::getPointersChainCost (X86TTIImpl over TargetTransformInfoImplCRTPBase)
PCI_UNIT_STRIDE :: 0; PCI_KNOWN_STRIDE :: 1; PCI_UNKNOWN_STRIDE :: 2;   // all "same base"
tti_pointers_chain_cost :: (t: *Tti, ptrs: [] Value_Id, base: Value_Id, info: s64, access_ty: Type_Id, kind: s64) -> Cost {
    if t.kind == .X86 && (info == PCI_UNIT_STRIDE || info == PCI_KNOWN_STRIDE) {
        if is_inst(base) && inst_op(base) == .GEP {
            idx: [..] Value_Id; idx.allocator = temp;
            for k: 1..cast(s64) nops(base) - 1 array_add(*idx, op(base, cast(u32) k));
            return tti_gep_cost(t, gep_source_type(base), op(base, 0), idx, NONE, kind);
        }
        return TCC_FREE;
    }
    cost: Cost = TCC_FREE;
    for v: ptrs {
        if !is_inst(v) || inst_op(v) != .GEP continue;
        if v != base {
            if gep_has_all_constant_indices(v) continue;
            cost = cost_add(cost, tti_arith_cost(t, .ADD, vtype(v), kind));
        } else {
            idx: [..] Value_Id; idx.allocator = temp;
            for k: 1..cast(s64) nops(v) - 1 array_add(*idx, op(v, cast(u32) k));
            cost = cost_add(cost, tti_gep_cost(t, gep_source_type(v), op(v, 0), idx, access_ty, kind));
        }
    }
    return cost;
}
// TTI::getExtractWithExtendCost (BasicTTIImplBase; X86 does not override it)
tti_extract_with_extend_cost :: (t: *Tti, opc: Opcode, dst: Type_Id, vec_ty: Type_Id, index: u32, kind := TCK_RECIP_THROUGHPUT) -> Cost {
    if t.kind != .X86 return 1;
    return cost_add(tti_vector_instr_cost(t, .EXTRACTELEMENT, vec_ty, kind, index),
                    tti_cast_cost(t, opc, dst, type_elem(vec_ty), CCH_NONE, kind));
}
// TTI::getCallInstrCost (BasicTTIImplBase: 10; NoTTI: 1)
tti_call_instr_cost :: (t: *Tti) -> Cost { return ifx t.kind == .X86 then 10 else 1; }
// TTI::getAltInstrCost (X86TTIImpl; the base returns Invalid)
tti_alt_instr_cost :: (t: *Tti, vec_ty: Type_Id, opc0: Opcode, opc1: Opcode, mask: [] bool) -> Cost {
    if t.kind == .X86 && tti_is_legal_alt_instr(t, vec_ty, opc0, opc1, mask) return TCC_BASIC;
    return COST_INVALID;
}
tti_register_class_spill_cost :: (t: *Tti, rc: u32) -> Cost { return TCC_BASIC; }
tti_register_class_reload_cost :: (t: *Tti, rc: u32) -> Cost { return TCC_BASIC; }
tti_cost_of_keeping_live_over_call :: (t: *Tti, ty: Type_Id) -> Cost { return 0; }

// ::getVectorInstrCost(TTI, ScalarTy, Opcode, Val, CostKind, Index, Scalar, ScalarUserAndIdx): X86 does not override
// the ScalarUserAndIdx form, BasicTTI forwards it without the scalar.
slp_vector_instr_cost :: (sty: Type_Id, opc: Opcode, val: Type_Id, index: u32) -> Cost {
    if is_vector_type(sty) slp_fail("REVEC extract costs");
    return tti_vector_instr_cost(slp.tti, opc, val, TCK_RECIP_THROUGHPUT, index);
}
// ::getExtractWithExtendCost
slp_extract_with_extend_cost :: (opc: Opcode, dst: Type_Id, vec_ty: Type_Id, index: u32) -> Cost {
    if is_vector_type(dst) slp_fail("REVEC extract-with-extend costs");
    return tti_extract_with_extend_cost(slp.tti, opc, dst, vec_ty, index);
}

// ---------------------------------------------------------------- BoUpSLP queries

// BoUpSLP::getOperandInfo(Ops)
slp_get_operand_info :: (ops: [] Value_Id) -> Op_Info {
    op0 := ops[0];
    is_c := true; is_u := true; is_p2 := true; is_np2 := true;
    for v: ops {
        if !(slp_is_constant(v) && !pm_undef_value(v)) is_c = false;
        if v != op0 is_u = false;
        if vkind(v) == .C_INT && !is_vector_type(vtype(v)) {
            a := cf_ap(v);
            if !ap_is_power_of_2(a) is_p2 = false;
            if !ap_is_negated_power_of_2(a) is_np2 = false;
        } else { is_p2 = false; is_np2 = false; }
    }
    vk: u8 = OK_ANY_VALUE;
    if is_c && is_u vk = OK_UNIFORM_CONSTANT_VALUE;
    else if is_c vk = OK_NON_UNIFORM_CONSTANT_VALUE;
    else if is_u vk = OK_UNIFORM_VALUE;
    vp: u8 = OP_NONE;
    if is_p2 vp = OP_POWER_OF_2;
    if is_np2 vp = OP_NEGATED_POWER_OF_2;
    return .{vk, vp};
}
slp_get_operand_info1 :: (v: Value_Id) -> Op_Info { a: [1] Value_Id; a[0] = v; return slp_get_operand_info(a); }

// BoUpSLP::getCastContextHint(TE)
slp_get_cast_context_hint :: (te: Te_Id) -> u8 {
    e := *slp.entries[te];
    if e.state == TE_SCATTER_VECTORIZE || e.state == TE_STRIDED_VECTORIZE return CCH_GATHER_SCATTER;
    if e.state == TE_COMPRESS_VECTORIZE return CCH_MASKED;
    if e.state == TE_VECTORIZE && te_opcode(te) == .LOAD && !is_alt_shuffle(e.s) {
        if e.reorder_indices.count == 0 return CCH_NORMAL;
        m := slp_inverse_permutation(e.reorder_indices);
        if svm_is_reverse(m, m.count) return CCH_REVERSED;
    }
    return CCH_NONE;
}

// getLoopTripCount(L, SE)
slp_loop_trip_count :: (l: Loop_Id) -> u64 {
    if slp_cl.loop_trip_count == 0 return 1;
    scale := cast(u64) sc_get_small_constant_trip_count(l);
    if scale == 0 {
        has, etc := li_loop_estimated_trip_count(slp.li, l);
        if has scale = etc;
    }
    if scale != 0 {
        if li_exiting_block(slp.li, l) == NONE return min(cast(u64) slp_cl.loop_trip_count, scale);
        return scale;
    }
    return cast(u64) slp_cl.loop_trip_count;
}
// getLoopNestScale(L)
slp_loop_nest_scale :: (l: Loop_Id) -> u64 {
    if l == NONE || slp_cl.loop_trip_count == 0 return 1;
    found, s := table_find(*slpx.loop_nest_scale_cache, l);
    if found return s;
    chain: [..] Loop_Id; chain.allocator = temp;
    cur := l;
    while cur != NONE {
        if table_contains(*slpx.loop_nest_scale_cache, cur) break;
        array_add(*chain, cur);
        cur = li_parent(slp.li, cur);
    }
    scale: u64 = 1;
    p := li_parent(slp.li, chain[chain.count - 1]);
    if p != NONE { _, scale = table_find(*slpx.loop_nest_scale_cache, p); }
    for < chain {
        tc := max(cast(u64) 1, slp_loop_trip_count(it));
        hi, lo := mul_u64_full(scale, tc);
        scale = ifx hi != 0 then 0xFFFF_FFFF_FFFF_FFFF else lo;
        table_set(*slpx.loop_nest_scale_cache, it, max(cast(u64) 1, scale));
    }
    return max(cast(u64) 1, scale);
}
// getScaleToLoopIterations(TE, Scalar, U)
slp_scale_to_loop_iterations :: (te: Te_Id, scalar: Value_Id = NONE, u: Value_Id = NONE) -> u64 {
    e := *slp.entries[te];
    parent: Value_Id = NONE;
    if u != NONE {
        if inst_op(u) == .PHI && scalar != NONE {
            if li_loop_for(slp.li, inst_block(u)) != NONE {
                for k: 0..cast(s64) phi_num_incoming(u) - 1 {
                    if phi_value(u, cast(u32) k) != scalar continue;
                    in_bb := phi_block(u, cast(u32) k);
                    if parent == NONE || li_block_depth(slp.li, in_bb) > li_block_depth(slp.li, parent) parent = in_bb;
                }
            }
        }
        if parent == NONE parent = inst_block(u);
    } else if te_is_gather(te) || e.state == TE_SPLIT_VECTORIZE {
        ei := e.user_tree_index;
        while ei.user != TE_NONE {
            ue := *slp.entries[ei.user];
            if te_is_gather(ei.user) || ue.state == TE_SPLIT_VECTORIZE { ei = ue.user_tree_index; continue; }
            if ue.state == TE_VECTORIZE && te_opcode(ei.user) == .PHI parent = phi_block(ue.s.main, ei.edge);
            else parent = inst_block(ue.s.main);
            break;
        }
        if parent == NONE return 1;
    } else {
        parent = inst_block(e.s.main);
    }
    l := li_loop_for(slp.li, parent);
    if l == NONE return 1;
    if scalar != NONE {
        a: [1] Value_Id; a[0] = scalar;
        return slp_loop_nest_scale(slp_find_innermost_non_invariant_loop(l, a));
    }
    return slp_loop_nest_scale(slp_find_innermost_non_invariant_loop(l, e.scalars));
}
// getGatherNodeEffectiveScale(TE, U)
slp_gather_node_effective_scale :: (te: Te_Id, u: Value_Id = NONE) -> u64 {
    base := slp_scale_to_loop_iterations(te, NONE, u);
    if !slp_cl.per_lane_gather_scale || slp_cl.loop_trip_count == 0 || base <= 1 return base;
    sum: u64 = 0;
    n: u64 = 0;
    for v: slp.entries[te].scalars {
        if slp_is_constant(v) continue;
        n += 1;
        ls := min(slp_scale_to_loop_iterations(te, v, u), base);
        if sum + ls < sum return base;
        sum += ls;
    }
    if n == 0 return base;
    if sum + (n - 1) < sum return base;
    avg := (sum + n - 1) / n;
    return clamp(avg, 1, base);
}

// TreeEntry::getSplitMask()
te_split_mask :: (te: Te_Id) -> [..] s32 {
    e := *slp.entries[te];
    back := cast(s64) e.combined_entries_with_indices[e.combined_entries_with_indices.count - 1][1];
    common_vf := max(back, e.scalars.count - back);
    mask := new_mask(te_vector_factor(te));
    for i, idx: e.reorder_indices mask[i] = cast(s32) (idx + ifx idx >= back then common_vf - back else 0);
    return mask;
}
// TreeEntry::hasEqualOperands(TE)
te_has_equal_operands :: (a: Te_Id, b: Te_Id) -> bool {
    ea := *slp.entries[a]; eb := *slp.entries[b];
    if eb.operands.count != ea.operands.count return false;
    n := ea.operands.count;
    used := NewArray(n, bool,, temp);
    for i: 0..n-1 {
        found := false;
        for k: 0..n-1 {
            if used[k] continue;
            if vl_equal(ea.operands[k], eb.operands[i]) { used[k] = true; found = true; break; }
        }
        if !found return false;
    }
    return true;
}
vl_equal :: (a: [] Value_Id, b: [] Value_Id) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}

// canVectorStoreInsertValue(E)
slp_can_vector_store_insert_value :: (te: Te_Id) -> bool {
    e := *slp.entries[te];
    if te_opcode(te) != .INSERTVALUE || e.state != TE_VECTORIZE return false;
    has_store := false;
    for v: e.scalars {
        if !is_inst(v) || inst_op(v) != .INSERTVALUE || slp_is_deleted(v) return false;
        has_ext := false;
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u]; u = ir.u_next[u];
            if is_inst(usr) && slp_is_deleted(usr) continue;
            if slp_has(e.scalars, usr) continue;
            has_ext = true;
            if !is_inst(usr) || inst_op(usr) != .STORE || !is_simple_load_store(usr) return false;
            has_store = true;
        }
        if has_ext && !has_one_use(v) return false;
    }
    return has_store;
}
// getInsertBuildVectorSrcTy(E)
slp_insert_build_vector_src_ty :: (te: Te_Id) -> Type_Id {
    e := *slp.entries[te];
    vl0 := e.s.main;
    if te_opcode(te) == .INSERTELEMENT return vtype(vl0);
    max_idx := cast(u64) e.scalars.count - 1;
    for v: e.scalars {
        if !is_inst(v) || inst_op(v) != .INSERTVALUE continue;
        max_idx = max(max_idx, cast(u64) ir.u32_pool[inst(v).idx]);
    }
    return slp_widened_type(slp_get_value_type(vl0), max_idx + 1);
}

// getRootNodeTypeWithNoCast(): (has, type, signed)
slp_root_node_type_with_no_cast :: () -> (bool, Type_Id, bool) {
    root := *slp.entries[0];
    if root.state != TE_VECTORIZE || is_alt_shuffle(root.s) || !is_int_type(vtype(root.scalars[0])) return false, NONE, false;
    found, bw := table_find(*slpx.min_bws, 0);
    if found return true, type_int(cast(u32) bw.bits), bw.signed;
    if te_opcode(0) == .ZEXT || te_opcode(0) == .SEXT return true, vtype(op(root.s.main, 0)), te_opcode(0) == .SEXT;
    return false, NONE, false;
}
// getReductionType()
slp_reduction_type :: () -> Type_Id {
    root := *slp.entries[0];
    t := vtype(root.scalars[0]);
    vf := cast(u64) te_vector_factor(0);
    if slpx.reduction_bit_width == 0 || !is_int_type(t) || slpx.reduction_bit_width >= dl_type_size_bits(t) return slp_widened_type(t, vf);
    return slp_widened_type(type_int(cast(u32) slpx.reduction_bit_width), vf);
}
// isReducedBitcastRoot() / isReducedCmpBitcastRoot()
slp_is_reduced_bitcast_root :: () -> bool {
    c := slp.entries[0].combined_op;
    return te_has_state(0) && (c == TE_REDUCED_BITCAST || c == TE_REDUCED_BITCAST_BSWAP || c == TE_REDUCED_BITCAST_LOADS ||
                               c == TE_REDUCED_BITCAST_BSWAP_LOADS) && slp.entries[0].state == TE_VECTORIZE;
}
slp_is_reduced_cmp_bitcast_root :: () -> bool {
    return te_has_state(0) && slp.entries[0].combined_op == TE_REDUCED_CMP_BITCAST && slp.entries[0].state == TE_VECTORIZE;
}
slp_min_bw_of :: (te: Te_Id) -> (bool, Min_Bw) {
    found, bw := table_find(*slpx.min_bws, te);
    return found, bw;
}

// isTreeNotExtendable()
slp_is_tree_not_extendable :: () -> bool {
    n := slp.entries.count;
    if cast(s64) slp_canonical_graph_size() != n {
        SMALL_TREE :: 3;
        if !has_single_bit(cast(u64) slp.entries[0].scalars.count) && slp_canonical_graph_size() <= SMALL_TREE {
            cnt := 0;
            for k: cast(s64) slp_canonical_graph_size()..n-1 {
                te := cast(Te_Id) k;
                if te_is_gather(te) && te_has_state(te) && te_opcode(te) == .LOAD && !slp_all_same_block(slp.entries[te].scalars) cnt += 1;
            }
            if cnt == 1 return true;
        }
        return false;
    }
    res := false;
    for k: 0..n-1 {
        te := cast(Te_Id) k;
        e := *slp.entries[te];
        if e.state == TE_SPLIT_VECTORIZE return false;
        if !te_is_gather(te) continue;
        all_ee_ld := true;
        for e.scalars if !(is_inst(it) && (inst_op(it) == .EXTRACTELEMENT || inst_op(it) == .LOAD)) { all_ee_ld = false; break; }
        if (te_has_state(te) && te_opcode(te) != .LOAD) || (!te_has_state(te) && all_ee_ld) ||
           (is_inst(e.scalars[0]) && inst_op(e.scalars[0]) == .EXTRACTELEMENT && is_valid(slp_get_same_opcode(array_view(e.scalars, 1))))
            return false;
        if slp_is_splat(e.scalars) || slp_all_constant(e.scalars) continue;
        res = true;
    }
    return res;
}

// getGatherCost(VL, ForPoisonSrc, ScalarTy)
slp_get_gather_cost :: (vl: [] Value_Id, for_poison_src: bool, sty: Type_Id) -> Cost {
    vf := vl.count;
    vec_ty := slp_widened_type(sty, cast(u64) vf);
    dem := NewArray(vf, bool,, temp);
    cost: Cost = 0;
    csm := new_mask(vf);
    for i: 0..vf-1 csm[i] = cast(s32) i;
    any_dem := false;
    for v, i: vl {
        if (for_poison_src && slp_is_constant(v)) || pm_undef_value(v) continue;
        if slp_is_constant(v) { csm[i] = cast(s32) (i + vf); continue; }
        dem[i] = true; any_dem = true;
        if vtype(v) != sty cost = cost_add(cost, tti_cast_cost(slp.tti, .TRUNC, sty, vtype(v), CCH_NONE, TCK_RECIP_THROUGHPUT));
    }
    any_non_undef_const := false;
    for v: vl if !pm_undef_value(v) && slp_is_constant(v) { any_non_undef_const = true; break; }
    if !for_poison_src && any_non_undef_const
        cost = cost_add(cost, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, vec_ty, csm));
    if any_dem
        cost = cost_add(cost, slp_get_scalarization_overhead(sty, vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT,
                                                             for_poison_src && !any_non_undef_const, vl));
    return cost;
}

// getGEPCosts(TTI, Ptrs, BasePtr, Opcode, CostKind, ScalarTy, VecTy): (scalar, vector)
slp_gep_costs :: (ptrs: [] Value_Id, base: Value_Id, opc: Opcode, sty: Type_Id, vec_ty: Type_Id) -> (Cost, Cost) {
    t := slp.tti;
    scalar: Cost = 0; vec: Cost = 0;
    if opc == .LOAD || opc == .STORE {
        scalar = tti_pointers_chain_cost(t, ptrs, base, PCI_UNIT_STRIDE, sty, TCK_RECIP_THROUGHPUT);
        retained: [..] Value_Id; retained.allocator = temp;
        for v: ptrs {
            if v == base { array_add(*retained, v); continue; }
            if !(is_inst(v) && inst_op(v) == .GEP) || !has_one_use(v) array_add(*retained, v);
        }
        if retained.count == ptrs.count return TCC_FREE, TCC_FREE;
        vec = tti_pointers_chain_cost(t, retained, base, PCI_KNOWN_STRIDE, vec_ty, TCK_RECIP_THROUGHPUT);
    } else {
        all_var := true;
        for v: ptrs if !(is_inst(v) && inst_op(v) == .GEP && !gep_has_all_constant_indices(v)) { all_var = false; break; }
        scalar = tti_pointers_chain_cost(t, ptrs, base, ifx all_var then PCI_UNKNOWN_STRIDE else PCI_KNOWN_STRIDE, sty, TCK_RECIP_THROUGHPUT);
        base_gep: Value_Id = NONE;
        if slp_is_gep_operator(base) base_gep = base;
        else for v: ptrs if slp_is_gep_operator(v) { base_gep = v; break; }
        if base_gep != NONE {
            idx: [..] Value_Id; idx.allocator = temp;
            for k: 1..cast(s64) nops(base_gep) - 1 array_add(*idx, op(base_gep, cast(u32) k));
            vec = tti_gep_cost(t, opr_gep_source_type(base_gep), op(base_gep, 0), idx, vec_ty, TCK_RECIP_THROUGHPUT);
        }
    }
    return scalar, vec;
}

// ---------------------------------------------------------------- getVectorSpillReloadCost

slp_entry_vec_ty :: (te: Te_Id) -> (Type_Id, Type_Id) {
    sty := slp_get_value_type(slp.entries[te].scalars[0]);
    found, bw := table_find(*slpx.min_bws, te);
    if found {
        if is_vector_type(sty) slp_fail("REVEC minimum bit widths");
        sty = type_int(cast(u32) bw.bits);
    }
    return sty, slp_widened_type(sty, cast(u64) te_vector_factor(te));
}
// getVectorSpillReloadCost(E, ScalarTy, VecTy, FinalVecTy, CostKind)
slp_vector_spill_reload_cost :: (te: Te_Id, sty: Type_Id, vec_ty: Type_Id, final_vec_ty: Type_Id) -> Cost {
    e := *slp.entries[te];
    spills: Cost = 0;
    if !te_has_state(te) return spills;
    o := te_opcode(te);
    if o == .STORE || o == .EXTRACTELEMENT || o == .EXTRACTVALUE || o == .FREEZE || (o == .LOAD && e.state != TE_SCATTER_VECTORIZE) return spills;
    is_phi := e.state == TE_VECTORIZE && o == .PHI;
    counted: [..] Te_Id; counted.allocator = temp;
    rc_keys: [..] u32; rc_keys.allocator = temp;   // SmallDenseMap<unsigned, unsigned>: only sums/compares, order irrelevant
    rc_vals: [..] u32; rc_vals.allocator = temp;
    add_parts :: (keys: *[..] u32, vals: *[..] u32, rc: u32, parts: u32, take_max := false) {
        for keys.* if it == rc { if take_max vals.*[it_index] = max(vals.*[it_index], parts); else vals.*[it_index] += parts; return; }
        array_add(keys, rc); array_add(vals, parts);
    }
    if e.state == TE_SPLIT_VECTORIZE {
        for cei: e.combined_entries_with_indices {
            op_te := cast(Te_Id) cei[0];
            if slp_has(counted, op_te) continue;
            array_add(*counted, op_te);
            osty, ovt := slp_entry_vec_ty(op_te);
            parts := cast(u32) slp_number_of_parts(slp.tti, ovt, osty);
            if parts == 0 continue;
            add_parts(*rc_keys, *rc_vals, tti_register_class_for_type(slp.tti, true, ovt), parts);
        }
    } else if is_phi {
        mk: [..] u32; mk.allocator = temp; mv: [..] u32; mv.allocator = temp;
        for idx: 0..e.operands.count-1 {
            op_te := slp_get_operand_entry(te, cast(u32) idx);
            osty, ovt := slp_entry_vec_ty(op_te);
            parts := cast(u32) slp_number_of_parts(slp.tti, ovt, osty);
            if parts == 0 continue;
            add_parts(*mk, *mv, tti_register_class_for_type(slp.tti, true, ovt), parts, true);
        }
        for mk add_parts(*rc_keys, *rc_vals, it, mv[it_index]);
    } else {
        for idx: 0..e.operands.count-1 {
            if (o == .INSERTELEMENT || o == .INSERTVALUE) && idx == 0 continue;
            ops := e.operands[idx];
            if ops.count == 0 || slp_all_constant(ops) || slp_is_splat(ops) continue;
            op0 := ops[0];
            if op0 == NONE continue;
            op_te := slp_get_operand_entry(te, cast(u32) idx);
            if slp_has(counted, op_te) continue;
            array_add(*counted, op_te);
            ovt := slp_widened_type(vtype(op0), cast(u64) ops.count);
            parts := cast(u32) slp_number_of_parts(slp.tti, ovt, vtype(op0));
            if parts == 0 continue;
            add_parts(*rc_keys, *rc_vals, tti_register_class_for_type(slp.tti, true, ovt), parts);
        }
    }
    if o != .LOAD {
        rp := cast(u32) slp_number_of_parts(slp.tti, vec_ty, sty);
        if rp != 0 add_parts(*rc_keys, *rc_vals, tti_register_class_for_type(slp.tti, true, vec_ty), rp);
        if vec_ty != final_vec_ty {
            fp := cast(u32) slp_number_of_parts(slp.tti, final_vec_ty, sty);
            if fp != 0 add_parts(*rc_keys, *rc_vals, tti_register_class_for_type(slp.tti, true, final_vec_ty), fp);
        }
    }
    for rc: rc_keys {
        used := rc_vals[it_index];
        avail := tti_number_of_registers(slp.tti, rc);
        if avail == 0 || used <= avail continue;
        spill_count := used - avail;
        single := tti_register_class_reload_cost(slp.tti, rc);
        if te > 0 || !slpx.has_user_ignore_list || type_kind(vtype(e.scalars[0])) != .VOID
            single = cost_add(single, tti_register_class_spill_cost(slp.tti, rc));
        spills = cost_add(spills, cost_mul(single, cast(s64) spill_count));
    }
    return spills;
}

// getVectorInstrContextHint(VL, DemandedElts): the hint is only consumed by BasicTTI's getVectorInstrCost, which
// ignores it (knowledge/llvm/vectorizers.md), so it is not modelled.

// ---------------------------------------------------------------- getEntryCost

Slp_Ec :: struct {
    te: Te_Id;
    shuffle_or_op: s32;               // Opcode, or TE_MIN_MAX.. for combined nodes, or SHUFFLE for alternates
    vl0: Value_Id;
    sty: Type_Id;
    orig_sty: Type_Id;
    vec_ty: Type_Id;
    final_vec_ty: Type_Id;
    has_bw: bool;
    bw: Min_Bw;
    common_cost: Cost;
    spills: Cost;
    unique_values: [..] Value_Id;
    unique_indexes: [..] s64;
    used_scalars: [] bool;
    // ExtractElement / ExtractValue
    dem: [] bool;
    src_vec_ty: Type_Id = NONE;
    // compares / selects
    vec_pred: u8;
    swapped_vec_pred: u8;
    // casts
    cast_opc: Opcode;
    vec_cast_opc: Opcode;
    src_cast_vec_ty: Type_Id;
}
EC_SHUFFLE : s32 : -2;

ec_op_s32 :: (o: Opcode) -> s32 { return cast(s32) o; }

// getEntryCost(E, VectorizedVals, CheckedExtracts)
slp_get_entry_cost :: (te: Te_Id, vectorized_vals: [] Value_Id, checked_extracts: *[..] Value_Id) -> Cost {
    e := *slp.entries[te];
    vl := e.scalars;
    sty := slp_get_value_type(vl[0]);
    if !slp_is_valid_element_type(sty) return COST_INVALID;
    c: Slp_Ec;
    c.te = te;
    c.has_bw, c.bw = slp_min_bw_of(te);
    c.orig_sty = sty;
    if c.has_bw {
        if is_vector_type(sty) slp_fail("REVEC minimum bit widths");
        sty = type_int(cast(u32) c.bw.bits);
    } else if te == 0 && slp_is_reduced_bitcast_root() {
        zext := slp_get_operand_entry(te, 0);
        sty = vtype(op(slp.entries[zext].s.main, 0));
    }
    c.sty = sty;
    c.vec_ty = slp_widened_type(sty, cast(u64) vl.count);
    entry_vf := te_vector_factor(te);
    c.final_vec_ty = slp_widened_type(sty, cast(u64) entry_vf);
    c.spills = slp_vector_spill_reload_cost(te, sty, c.vec_ty, c.final_vec_ty);
    if te_is_gather(te) || table_contains(*slp.transformed_to_gather_nodes, te) {
        if slp_all_constant(vl) return 0;
        if is_inst(vl[0]) && (inst_op(vl[0]) == .INSERTELEMENT || inst_op(vl[0]) == .INSERTVALUE) return COST_INVALID;
        return cost_add(c.spills, slp_build_vector_cost(te, sty, vectorized_vals, checked_extracts));
    }
    if e.state == TE_SPLIT_VECTORIZE {
        vector_cost: Cost;
        cei := e.combined_entries_with_indices;
        if e.reorder_indices.count == 0 {
            vector_cost = slp_shuffle_cost(SK_INSERT_SUBVECTOR, c.final_vec_ty, .[], TCK_RECIP_THROUGHPUT, cei[cei.count-1][1],
                                           slp_widened_type(sty, cast(u64) te_vector_factor(cast(Te_Id) cei[cei.count-1][0])));
        } else {
            common_vf := max(te_vector_factor(cast(Te_Id) cei[0][0]), te_vector_factor(cast(Te_Id) cei[cei.count-1][0]));
            vector_cost = slp_shuffle_cost(SK_PERMUTE_TWO_SRC, slp_widened_type(sty, cast(u64) common_vf), te_split_mask(te));
        }
        return cost_add(vector_cost, c.spills);
    }
    mask := new_mask();
    if e.reorder_indices.count && e.state != TE_COMPRESS_VECTORIZE && (e.state != TE_STRIDED_VECTORIZE || !slp_is_reverse_order(e.reorder_indices)) {
        nm: [..] s32;
        if te_opcode(te) == .STORE { nm = new_mask(); for e.reorder_indices array_add(*nm, cast(s32) it); }
        else nm = slp_inverse_permutation(e.reorder_indices);
        slp_add_mask(*mask, nm);
    }
    if e.reuse_shuffle_indices.count slp_add_mask(*mask, e.reuse_shuffle_indices);
    if mask.count && !svm_is_identity(mask, mask.count)
        c.common_cost = slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, c.final_vec_ty, mask, TCK_RECIP_THROUGHPUT, 0, c.vec_ty);
    c.vl0 = e.s.main;
    c.shuffle_or_op = ifx is_alt_shuffle(e.s) then EC_SHUFFLE else ec_op_s32(te_opcode(te));
    if e.combined_op != TE_NOT_COMBINED c.shuffle_or_op = e.combined_op;
    c.unique_values.allocator = temp; c.unique_indexes.allocator = temp;
    for v, idx: vl if !slp_has(c.unique_values, v) { array_add(*c.unique_values, v); array_add(*c.unique_indexes, idx); }
    sz := c.unique_values.count;
    c.used_scalars = NewArray(sz, bool,, temp);
    for i: 0..sz-1 {
        u := c.unique_values[i];
        if is_inst(u) && !slp_te_is_copyable(te, u) {
            ents := slp_get_tree_entries(u);
            if ents.count && ents[0] == te continue;
        }
        c.used_scalars[i] = true;
    }
    s := c.shuffle_or_op;
    if s == ec_op_s32(.PHI) {
        scalar: Cost = 0;
        counted: [..] Te_Id; counted.allocator = temp;
        for v: c.unique_values {
            if !is_inst(v) || inst_op(v) != .PHI continue;
            ops: [..] Value_Id; ops.allocator = temp;
            for k: 0..cast(s64) phi_num_incoming(v) - 1 array_add(*ops, phi_value(v, cast(u32) k));
            op_te := slp_get_same_values_tree_entry(ops[0], ops);
            if op_te != TE_NONE && !slp_has(counted, op_te) {
                array_add(*counted, op_te);
                oe := *slp.entries[op_te];
                if oe.reuse_shuffle_indices.count scalar += TCC_BASIC * (oe.reuse_shuffle_indices.count - oe.scalars.count);
            }
        }
        return cost_add(cost_sub(c.common_cost, scalar), c.spills);
    }
    if s == ec_op_s32(.EXTRACTVALUE) || s == ec_op_s32(.EXTRACTELEMENT) {
        if s == ec_op_s32(.EXTRACTVALUE) && e.struct_ev_indices.count return c.common_cost;
        return ec_cost_diff(*c);
    }
    if s == ec_op_s32(.INSERTVALUE) || s == ec_op_s32(.INSERTELEMENT) return ec_insert_cost(*c);
    if s == ec_op_s32(.GEP) {
        gs, gv := slp_gep_costs(vl, c.vl0, te_opcode(te), c.orig_sty, c.vec_ty);
        return cost_add(c.common_cost, cost_add(cost_sub(gv, gs), c.spills));
    }
    if s == ec_op_s32(.LOAD) {
        cost := ec_cost_diff(*c);
        if e.state == TE_SCATTER_VECTORIZE return cost;
        ptrs: [..] Value_Id; ptrs.allocator = temp;
        for v: vl array_add(*ptrs, op(v, 0));
        gs, gv := slp_gep_costs(ptrs, op(c.vl0, 0), .LOAD, c.orig_sty, c.vec_ty);
        return cost_add(cost, cost_add(cost_sub(gv, gs), c.spills));
    }
    if s == ec_op_s32(.STORE) {
        is_reorder := e.reorder_indices.count > 0;
        base_si := ifx is_reorder then vl[e.reorder_indices[0]] else c.vl0;
        ptrs := NewArray(vl.count, Value_Id,, temp);
        for v, i: vl { idx := ifx is_reorder then cast(s64) e.reorder_indices[i] else i; ptrs[idx] = op(v, 1); }
        gs, gv := slp_gep_costs(ptrs, op(base_si, 1), .STORE, c.orig_sty, c.vec_ty);
        return cost_add(ec_cost_diff(*c), cost_add(cost_sub(gv, gs), c.spills));
    }
    if s == ec_op_s32(.FREEZE) return c.common_cost;
    if ec_is_cast(s) {
        src_found, src_bw := slp_min_bw_of(slp_get_operand_entry(te, 0));
        src_sty := vtype(op(c.vl0, 0));
        c.src_cast_vec_ty = slp_widened_type(src_sty, cast(u64) vl.count);
        c.cast_opc = cast(Opcode) s;
        c.vec_cast_opc = c.cast_opc;
        if !is_fp_or_fp_vector_ty(c.sty) && !is_fp_or_fp_vector_ty(src_sty) && (src_found || c.has_bw) {
            src_bw_sz := dl_type_size_bits(scalar_type(src_sty));
            if src_found {
                src_bw_sz = src_bw.bits;
                if is_vector_type(src_sty) slp_fail("REVEC minimum bit widths");
                src_sty = type_int(cast(u32) src_bw_sz);
                c.src_cast_vec_ty = slp_widened_type(src_sty, cast(u64) vl.count);
            }
            bw_sz := dl_type_size_bits(scalar_type(c.sty));
            if bw_sz == src_bw_sz c.vec_cast_opc = .BITCAST;
            else if bw_sz < src_bw_sz c.vec_cast_opc = .TRUNC;
            else if c.has_bw c.vec_cast_opc = ifx c.bw.signed then .SEXT else .ZEXT;
            else if src_found c.vec_cast_opc = ifx src_bw.signed then .SEXT else .ZEXT;
        } else if c.vec_cast_opc == .SITOFP && src_found && !src_bw.signed {
            c.vec_cast_opc = .UITOFP;
        }
    }
    if s == ec_op_s32(.ICMP) || s == ec_op_s32(.FCMP) {
        c.sty = slp_get_value_type(c.vl0, true);
        c.orig_sty = c.sty;
        c.vec_ty = slp_widened_type(c.sty, cast(u64) vl.count);
    }
    if s == ec_op_s32(.ICMP) || s == ec_op_s32(.FCMP) || s == ec_op_s32(.SELECT) {
        vl0 := c.vl0;
        is_cmp :: (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .ICMP || inst_op(v) == .FCMP); }
        if inst_op(vl0) == .SELECT && is_cmp(op(vl0, 0)) { c.vec_pred = inst(op(vl0, 0)).pred; c.swapped_vec_pred = swapped_predicate(c.vec_pred); }
        else if is_cmp(vl0) { c.vec_pred = inst(vl0).pred; c.swapped_vec_pred = swapped_predicate(c.vec_pred); }
        else { c.vec_pred = cast(u8) ifx is_fp_type(c.sty) then BAD_FCMP_PREDICATE else BAD_ICMP_PREDICATE; c.swapped_vec_pred = c.vec_pred; }
    }
    return ec_cost_diff(*c);
}

// the InsertElement / InsertValue case of getEntryCost
ec_insert_cost :: (c: *Slp_Ec) -> Cost {
    te := c.te;
    e := *slp.entries[te];
    vl := e.scalars;
    src_vec_ty := slp_insert_build_vector_src_ty(te);
    num_elts := cast(s64) slp_num_elements(src_vec_ty);
    num_scalars := vl.count;
    num_parts := cast(s64) slp_number_of_parts(slp.tti, src_vec_ty, vtype(op(c.vl0, 1)));
    insert_mask := new_mask(num_elts);
    _, ob := slp_element_index(vl[0]);
    offset_beg := cast(s64) ob;
    offset_end := offset_beg;
    insert_mask[offset_beg] = 0;
    for k: 1..vl.count-1 {
        _, ix := slp_element_index(vl[k]);
        idx := cast(s64) ix;
        if offset_beg > idx offset_beg = idx;
        else if offset_end < idx offset_end = idx;
        insert_mask[idx] = cast(s32) k;
    }
    vec_scalars_sz := cast(s64) slp_power_of_2_ceil(cast(u64) num_elts);
    if num_parts > 0 && num_parts < num_elts vec_scalars_sz = cast(s64) slp_power_of_2_ceil(cast(u64) ((num_elts + num_parts - 1) / num_parts));
    vec_sz := (1 + offset_end / vec_scalars_sz - offset_beg / vec_scalars_sz) * vec_scalars_sz;
    offset := vec_scalars_sz * (offset_beg / vec_scalars_sz);
    insert_vec_sz := min(cast(s64) slp_power_of_2_ceil(cast(u64) (offset_end - offset_beg + 1)),
                         ((offset_end - offset_beg + vec_scalars_sz) / vec_scalars_sz) * vec_scalars_sz);
    is_whole_subvector := offset_beg == offset && ((offset_end + 1) % vec_scalars_sz == 0);
    if offset_beg + insert_vec_sz > vec_sz {
        // alignDown(OffsetBeg, VecSz, Offset)
        offset_beg = ((offset_beg - offset) / vec_sz) * vec_sz + offset;
        insert_vec_sz = vec_sz;
    }
    dem := NewArray(num_elts, bool,, temp);
    mask := new_mask();
    if e.reorder_indices.count {
        mask = slp_inverse_permutation(e.reorder_indices);
        while mask.count < insert_vec_sz array_add(*mask, PME);
    } else {
        mask = new_mask(vec_sz);
        for i: 0..insert_vec_sz-1 mask[i] = cast(s32) i;
    }
    is_identity := true;
    prev_mask := mask;
    mask = new_mask(insert_vec_sz);
    adjusted := NewArray(num_elts, Value_Id,, temp);
    for * adjusted it.* = const_poison(c.sty);
    for i: 0..num_scalars-1 {
        _, ii := slp_element_index(vl[prev_mask[i]]);
        insert_idx := cast(s64) ii;
        dem[insert_idx] = true;
        adjusted[insert_idx] = vl[prev_mask[i]];
        is_identity &= insert_idx - offset_beg == i;
        mask[insert_idx - offset_beg] = cast(s32) i;
    }
    cost: Cost = 0;
    insert_vec_ty := slp_widened_type(c.sty, cast(u64) insert_vec_sz);
    if !is_identity cost = cost_add(cost, slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, insert_vec_ty, mask));
    first_insert: Value_Id = NONE;
    for v: vl if !slp_has(vl, op(v, 0)) { first_insert = v; break; }
    in_mask := slp_is_undef_vector(op(first_insert, 0), slp_build_use_mask(num_elts, insert_mask, SLP_USE_MASK_UNDEFS_AS_MASK));
    in_all := all_bits(in_mask);
    cost = cost_sub(cost, slp_get_scalarization_overhead(c.sty, src_vec_ty, dem, true, false, TCK_RECIP_THROUGHPUT, in_all, adjusted));
    if !in_all && num_scalars != num_elts && !is_whole_subvector {
        if insert_vec_sz != vec_sz {
            actual := slp_widened_type(c.sty, cast(u64) vec_sz);
            cost = cost_add(cost, slp_shuffle_cost(SK_INSERT_SUBVECTOR, actual, .[], TCK_RECIP_THROUGHPUT, offset_beg - offset, insert_vec_ty));
        } else {
            for i: 0..offset_beg - offset - 1 mask[i] = ifx in_mask[i] then PME else cast(s32) i;
            for i: offset_beg - offset..offset_end - offset if mask[i] != PME mask[i] = cast(s32) (i + vec_sz);
            for i: offset_end + 1 - offset..vec_sz-1 mask[i] = ifx (i >= in_mask.count || in_mask[i]) then PME else cast(s32) i;
            cost = cost_add(cost, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, insert_vec_ty, mask));
        }
    }
    if c.shuffle_or_op == ec_op_s32(.INSERTVALUE) && !slp_can_vector_store_insert_value(te) {
        align := max(dl_pref_align(src_vec_ty), dl_pref_align(vtype(c.vl0)));
        cost = cost_add(cost, cost_add(tti_memory_op_cost(slp.tti, .STORE, src_vec_ty, align, 0, TCK_RECIP_THROUGHPUT),
                                       tti_memory_op_cost(slp.tti, .LOAD, vtype(c.vl0), align, 0, TCK_RECIP_THROUGHPUT)));
    }
    return cost_add(cost, c.spills);
}

// GetCastContextHint(V) of getEntryCost
ec_cast_context_hint :: (c: *Slp_Ec, v: Value_Id) -> u8 {
    ents := slp_get_tree_entries(v);
    if ents.count == 1 return slp_get_cast_context_hint(ents[0]);
    ss := slp_get_same_opcode(slp.entries[c.te].operands[0]);
    if is_valid(ss) && is_opcode(ss) == .LOAD && !is_alt_shuffle(ss) return CCH_GATHER_SCATTER;
    return CCH_NONE;
}
// GetMinMaxCost(Ty, VI)
ec_min_max_cost :: (c: *Slp_Ec, ty: Type_Id, vi: Value_Id = NONE) -> Cost {
    id: Intrinsic_Id; select_only: bool;
    if vi != NONE { a: [1] Value_Id; a[0] = vi; id, select_only = slp_can_convert_to_min_or_max_intrinsic(a); }
    else id, select_only = slp_can_convert_to_min_or_max_intrinsic(slp.entries[c.te].scalars);
    if id == NOT_INTRINSIC return COST_INVALID;
    canon := ty;
    if type_kind(scalar_type(canon)) == .PTR {
        it := type_int(cast(u32) dl_type_size_bits(scalar_type(canon)));
        canon = ifx is_vector_type(canon) then type_vector(type_count(canon), it, false) else it;
    }
    ica := ica_types(id, canon, .[canon, canon]);
    ic := tti_intrinsic_cost(slp.tti, *ica, TCK_RECIP_THROUGHPUT);
    if vi != NONE && select_only {
        ci := op(vi, 0);
        ic = cost_sub(ic, tti_cmp_sel_cost(slp.tti, inst_op(ci), ty, type_int(1), inst(ci).pred, TCK_RECIP_THROUGHPUT, OI_ANY, OI_ANY, ci));
    }
    return ic;
}

// GetCostDiff(ScalarEltCost, VectorCost)
ec_cost_diff :: (c: *Slp_Ec) -> Cost {
    te := c.te;
    e := *slp.entries[te];
    sz := c.unique_values.count;
    scalar: Cost = 0;
    used := 0;
    for c.used_scalars if it used += 1;
    if is_inst(c.vl0) && (is_cast_op(inst_op(c.vl0)) || inst_op(c.vl0) == .CALL) {
        scalar = cost_mul(cast(s64) (sz - used), ec_scalar_elt_cost(c, 0));
    } else {
        for i: 0..sz-1 {
            if c.used_scalars[i] continue;
            scalar = cost_add(scalar, ec_scalar_elt_cost(c, i));
        }
    }
    vec := ec_vector_cost(c, c.common_cost);
    o := te_opcode(te);
    if c.has_bw && !is_cast_op(o) && te != 0 && (o != .LOAD || e.user_tree_index.user != TE_NONE) {
        ei := e.user_tree_index;
        ue := *slp.entries[ei.user];
        if !te_has_state(ei.user) || te_opcode(ei.user) != .SELECT || ei.edge != 0 {
            ufound, ubw := slp_min_bw_of(ei.user);
            user_sty := ifx te_is_gather(ei.user) || ue.state == TE_SPLIT_VECTORIZE then vtype(ue.scalars[0]) else vtype(ue.operands[ei.edge][0]);
            if ufound user_sty = type_int(cast(u32) ubw.bits);
            if c.sty != user_sty {
                bw_sz := dl_type_size_bits(c.sty);
                src_bw_sz := dl_type_size_bits(user_sty);
                user_vec_ty := slp_widened_type(user_sty, cast(u64) e.scalars.count);
                vo: Opcode = ifx bw_sz > src_bw_sz then .TRUNC else ifx c.bw.signed then .SEXT else .ZEXT;
                cch := ec_cast_context_hint(c, c.vl0);
                vec = cost_add(vec, tti_cast_cost(slp.tti, vo, user_vec_ty, c.vec_ty, cch, TCK_RECIP_THROUGHPUT));
            }
        }
    }
    vec = cost_add(vec, c.spills);
    #if DEBUG_SLP print("DBG entry % cost common=% vec=% scalar=% minbw=% %\n", te, c.common_cost, cost_sub(vec, c.common_cost), scalar, c.has_bw, c.bw);
    return cost_sub(vec, scalar);
}

ec_is_arith :: (s: s32) -> bool {
    if s < 0 || s >= TE_MIN_MAX return false;
    o := cast(Opcode) s;
    return o == .FNEG || is_binary_op(o);
}
ec_is_cast :: (s: s32) -> bool {
    if s < 0 || s >= TE_MIN_MAX return false;
    return is_cast_op(cast(Opcode) s);
}

// GetScalarCost(Idx) of each case
ec_scalar_elt_cost :: (c: *Slp_Ec, idx: s64) -> Cost {
    te := c.te;
    e := *slp.entries[te];
    t := slp.tti;
    K :: TCK_RECIP_THROUGHPUT;
    s := c.shuffle_or_op;
    uv := c.unique_values[idx];
    if s == ec_op_s32(.EXTRACTVALUE) || s == ec_op_s32(.EXTRACTELEMENT) {
        if pm_poison(uv) return TCC_FREE;
        if c.src_vec_ty == NONE {
            if s == ec_op_s32(.EXTRACTELEMENT) c.src_vec_ty = vtype(op(uv, 0));
            else {
                agg := vtype(op(uv, 0));
                n := ifx type_kind(agg) == .ARRAY then type_count(agg) else cast(u64) type_nsub(agg);
                c.src_vec_ty = slp_widened_type(c.orig_sty, n);
            }
        }
        _, eidx := slp_extract_index(uv);
        if has_one_use(uv) {
            ext := first_user(uv);
            if is_inst(ext) && (inst_op(ext) == .SEXT || inst_op(ext) == .ZEXT) && all_users_are_geps(ext) {
                cost := tti_extract_with_extend_cost(t, inst_op(ext), vtype(ext), c.src_vec_ty, cast(u32) eidx, K);
                return cost_sub(cost, tti_cast_cost(t, inst_op(ext), vtype(ext), vtype(uv), tti_cast_context_hint(ext), K, ext));
            }
        }
        if c.dem.count == 0 c.dem = NewArray(cast(s64) slp_num_elements(c.src_vec_ty), bool,, temp);
        c.dem[eidx] = true;
        return TCC_FREE;
    }
    if ec_is_cast(s) {
        vl0 := c.vl0;
        return tti_cast_cost(t, cast(Opcode) s, vtype(vl0), vtype(op(vl0, 0)), tti_cast_context_hint(vl0), K, vl0);
    }
    if s == ec_op_s32(.ICMP) || s == ec_op_s32(.FCMP) || s == ec_op_s32(.SELECT) {
        if pm_poison(uv) return TCC_FREE;
        if !is_inst(uv) || inst_op(uv) != .SELECT return tti_instruction_cost(t, uv, K);
        vi := uv;
        bad: u8 = cast(u8) ifx is_fp_type(c.sty) then BAD_FCMP_PREDICATE else BAD_ICMP_PREDICATE;
        cur_pred := bad;
        lhs: Value_Id = NONE; rhs: Value_Id = NONE;
        is_select := false;
        cond := op(vi, 0);
        matched_cmp := false;
        if s == ec_op_s32(.SELECT) {
            if is_inst(cond) && (inst_op(cond) == .ICMP || inst_op(cond) == .FCMP) { cur_pred = inst(cond).pred; matched_cmp = true; }
            lhs = op(vi, 1); rhs = op(vi, 2);
            is_select = true;
        }
        if (!is_select && !matched_cmp) || (cur_pred != c.vec_pred && cur_pred != c.swapped_vec_pred) {
            c.vec_pred = bad; c.swapped_vec_pred = bad;
        }
        sc := COST_INVALID;
        if is_select && vtype(lhs) == vtype(op(vi, 0)) {
            if pm_all_ones(lhs) sc = tti_arith_cost(t, .OR, vtype(lhs), K, slp_get_operand_info1(op(vi, 0)), slp_get_operand_info1(rhs));
            else if pm_zero(rhs) sc = tti_arith_cost(t, .AND, vtype(lhs), K, slp_get_operand_info1(op(vi, 0)), slp_get_operand_info1(lhs));
        }
        if !cost_valid(sc) {
            is_sel_case := s == ec_op_s32(.SELECT);
            sc = tti_cmp_sel_cost(t, te_opcode(te), c.orig_sty, ifx is_sel_case then vtype(op(c.vl0, 0)) else vtype(c.vl0), cur_pred, K,
                                  slp_get_operand_info1(op(vi, cast(u32) ifx is_sel_case then 1 else 0)), slp_get_operand_info1(op(vi, cast(u32) ifx is_sel_case then 2 else 1)), vi);
        }
        ic := ec_min_max_cost(c, c.orig_sty, vi);
        if cost_valid(ic) sc = ic;
        return sc;
    }
    if s == TE_MIN_MAX return ec_min_max_cost(c, c.orig_sty);
    if s == TE_FMULADD {
        if pm_poison(uv) return TCC_FREE;
        a: [1] Value_Id; a[0] = uv;
        return slp_can_convert_to_fma(a, e.s);
    }
    if s == TE_REDUCED_BITCAST || s == TE_REDUCED_BITCAST_BSWAP || s == TE_REDUCED_BITCAST_LOADS || s == TE_REDUCED_BITCAST_BSWAP_LOADS {
        if pm_poison(uv) || !is_inst(uv) return TCC_FREE;
        sc := tti_instruction_cost(t, uv, K);
        zext := op(uv, 0);
        if !is_inst(zext) return sc;
        sc = cost_add(sc, tti_instruction_cost(t, zext, K));
        if s == TE_REDUCED_BITCAST || s == TE_REDUCED_BITCAST_BSWAP return sc;
        ld := op(zext, 0);
        if !is_inst(ld) return sc;
        return cost_add(sc, tti_instruction_cost(t, ld, K));
    }
    if s == TE_REDUCED_CMP_BITCAST {
        if pm_poison(uv) || !is_inst(uv) return TCC_FREE;
        return tti_instruction_cost(t, uv, K);
    }
    if ec_is_arith(s) {
        if pm_poison(uv) return TCC_FREE;
        lane := c.unique_indexes[idx];
        op1 := e.operands[0][lane];
        op2: Value_Id;
        ops: [2] Value_Id; nops_ := 1;
        ops[0] = op1;
        if is_inst(uv) && inst_op(uv) == .FNEG op2 = op1;
        else { op2 = e.operands[1][lane]; ops[1] = op2; nops_ = 2; }
        sc := tti_arith_cost(t, cast(Opcode) s, c.orig_sty, K, tti_operand_info(op1), tti_operand_info(op2), array_view(ops, 0, nops_));
        if is_inst(uv) && (s == ec_op_s32(.FADD) || s == ec_op_s32(.FSUB)) {
            a: [1] Value_Id; a[0] = uv;
            ic := slp_can_convert_to_fma(a, e.s);
            if cost_valid(ic) sc = ic;
        }
        return sc;
    }
    if s == ec_op_s32(.LOAD) {
        return tti_memory_op_cost(t, .LOAD, c.orig_sty, load_store_align(uv), ptr_addrspace(vtype(op(uv, 0))), K, OI_ANY, uv);
    }
    if s == ec_op_s32(.STORE) {
        vi := e.scalars[idx];
        return tti_memory_op_cost(t, .STORE, c.orig_sty, load_store_align(vi), ptr_addrspace(vtype(op(vi, 1))), K, tti_operand_info(op(vi, 0)), vi);
    }
    if s == ec_op_s32(.CALL) {
        ci := uv;
        id := get_vector_intrinsic_id_for_call(ci);
        if id != NOT_INTRINSIC {
            ica := ica_from_call(ci, false, 1);
            ica.id = id;
            if call_iid(ci) == NOT_INTRINSIC ica.inst = NONE;
            return tti_intrinsic_cost(t, *ica, K);
        }
        return tti_call_instr_cost(t);
    }
    if s == EC_SHUFFLE {
        if pm_poison(uv) return TCC_FREE;
        return tti_instruction_cost(t, uv, K);
    }
    slp_fail(tprint("getEntryCost of opcode %", s));
    return COST_INVALID;
}
all_users_are_geps :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u]; u = ir.u_next[u];
        if !is_inst(usr) || inst_op(usr) != .GEP return false;
    }
    return true;
}

// GetVectorCost(CommonCost) of each case
ec_vector_cost :: (c: *Slp_Ec, common: Cost) -> Cost {
    te := c.te;
    e := *slp.entries[te];
    t := slp.tti;
    K :: TCK_RECIP_THROUGHPUT;
    s := c.shuffle_or_op;
    vl := e.scalars;
    if s == ec_op_s32(.EXTRACTVALUE) || s == ec_op_s32(.EXTRACTELEMENT) {
        any := false; for c.dem if it { any = true; break; }
        if !any return common;
        return cost_sub(common, tti_scalarization_overhead(t, c.src_vec_ty, c.dem, false, true, K));
    }
    if ec_is_cast(s) {
        if c.vec_cast_opc != c.cast_opc && c.vec_cast_opc == .BITCAST return common;
        vi := ifx inst_op(c.vl0) == c.cast_opc then c.vl0 else NONE;
        cch := ec_cast_context_hint(c, op(c.vl0, 0));
        is_arith_ext_red := false;
        if te == 0 && slpx.has_user_ignore_list {
            is_arith_ext_red = true;
            for v: slpx.user_ignore_list {
                o := inst_op(v);
                if !(o == .ADD || o == .FADD || o == .MUL || o == .FMUL || o == .AND || o == .OR || o == .XOR) { is_arith_ext_red = false; break; }
            }
        }
        if is_arith_ext_red && (c.vec_cast_opc == .ZEXT || c.vec_cast_opc == .SEXT) return common;
        return cost_add(common, tti_cast_cost(t, c.vec_cast_opc, c.vec_ty, c.src_cast_vec_ty, cch, K, ifx c.vec_cast_opc == c.cast_opc then vi else NONE));
    }
    if s == ec_op_s32(.ICMP) || s == ec_op_s32(.FCMP) || s == ec_op_s32(.SELECT) {
        is_sel := s == ec_op_s32(.SELECT);
        mask_ty := slp_widened_type(ifx is_sel then vtype(op(c.vl0, 0)) else vtype(c.vl0), cast(u64) vl.count);
        vc := COST_INVALID;
        if is_sel {
            cond := e.operands[0]; lhs := e.operands[1]; rhs := e.operands[2];
            if vtype(cond[0]) == vtype(lhs[0]) {
                all_ones := true; for lhs if !pm_all_ones(it) { all_ones = false; break; }
                all_zero := true; for rhs if !pm_zero(it) { all_zero = false; break; }
                if all_ones vc = tti_arith_cost(t, .OR, c.vec_ty, K, slp_get_operand_info(cond), slp_get_operand_info(rhs));
                else if all_zero vc = tti_arith_cost(t, .AND, c.vec_ty, K, slp_get_operand_info(cond), slp_get_operand_info(lhs));
            }
        }
        if !cost_valid(vc) {
            vc = tti_cmp_sel_cost(t, te_opcode(te), c.vec_ty, mask_ty, c.vec_pred, K,
                                  slp_get_operand_info(e.operands[ifx is_sel then 1 else 0]), slp_get_operand_info(e.operands[ifx is_sel then 2 else 1]), c.vl0);
            if inst_op(c.vl0) == .SELECT {
                cn := slp_num_elements(mask_ty); vn := slp_num_elements(c.vec_ty);
                if cn != vn slp_fail("REVEC select condition replication");
            }
        }
        return cost_add(vc, common);
    }
    if s == TE_MIN_MAX return cost_add(ec_min_max_cost(c, c.vec_ty), common);
    if s == TE_FMULADD {
        fmf: u32 = FMF_ALL;
        for v: e.scalars {
            if !is_fp_math_op_value(v) continue;
            fmf &= get_fmf(v);
            if is_fp_math_op_value(op(v, 0)) fmf &= get_fmf(op(v, 0));
        }
        ica := ica_types(IID_FMULADD, c.vec_ty, .[c.vec_ty, c.vec_ty, c.vec_ty], fmf);
        return cost_add(tti_intrinsic_cost(t, *ica, K), common);
    }
    if s == TE_REDUCED_BITCAST || s == TE_REDUCED_BITCAST_BSWAP {
        lhs := slp_get_operand_entry(te, 0);
        cast_ctx := slp_get_cast_context_hint(slp_get_operand_entry(lhs, 0));
        src_sty := vtype(op(slp.entries[lhs].s.main, 0));
        src_vec_ty := slp_widened_type(src_sty, cast(u64) te_vector_factor(lhs));
        bc := tti_cast_cost(t, .BITCAST, c.sty, src_vec_ty, cast_ctx, K);
        if s == TE_REDUCED_BITCAST_BSWAP {
            src_type := type_int(cast(u32) (dl_type_size_bits(src_sty) * cast(u64) te_vector_factor(te)));
            ica := ica_types(IID_BSWAP, src_type, .[src_type]);
            bc = cost_add(bc, tti_intrinsic_cost(t, *ica, K));
            if src_type != c.sty bc = cost_add(bc, tti_cast_cost(t, .ZEXT, c.sty, src_type, CCH_NONE, K));
        }
        return cost_add(bc, common);
    }
    if s == TE_REDUCED_BITCAST_LOADS || s == TE_REDUCED_BITCAST_BSWAP_LOADS {
        lhs := slp_get_operand_entry(te, 0);
        load_te := slp_get_operand_entry(lhs, 0);
        li0 := slp.entries[load_te].s.main;
        src_type := type_int(cast(u32) (dl_type_size_bits(vtype(li0)) * cast(u64) te_vector_factor(te)));
        lc := tti_memory_op_cost(t, .LOAD, src_type, load_store_align(li0), ptr_addrspace(vtype(op(li0, 0))), K);
        if s == TE_REDUCED_BITCAST_BSWAP_LOADS {
            ica := ica_types(IID_BSWAP, src_type, .[src_type]);
            lc = cost_add(lc, tti_intrinsic_cost(t, *ica, K));
            if src_type != c.sty lc = cost_add(lc, tti_cast_cost(t, .ZEXT, c.sty, src_type, CCH_NONE, K));
        }
        return cost_add(lc, common);
    }
    if s == TE_REDUCED_CMP_BITCAST {
        cmp_ty := make_cmp_result_type(c.vec_ty);
        dst := type_int(cast(u32) te_vector_factor(te));
        bc := tti_cast_cost(t, .BITCAST, dst, cmp_ty, CCH_NONE, K);
        if dst != c.sty bc = cost_add(bc, tti_cast_cost(t, .ZEXT, c.sty, dst, CCH_NONE, K));
        return cost_add(bc, common);
    }
    if ec_is_arith(s) {
        if s == ec_op_s32(.AND) && c.has_bw {
            for ops: e.operands {
                all := true;
                for o: ops {
                    if vkind(o) != .C_INT || is_vector_type(vtype(o)) { all = false; break; }
                    if cast(u64) ap_cto(cf_ap(o)) < c.bw.bits { all = false; break; }
                }
                if all return common;
            }
        }
        op_idx := ifx inst_op(c.vl0) == .FNEG then 0 else 1;
        return cost_add(tti_arith_cost(t, cast(Opcode) s, c.vec_ty, K, slp_get_operand_info(e.operands[0]), slp_get_operand_info(e.operands[op_idx])), common);
    }
    if s == ec_op_s32(.LOAD) {
        li0 := c.vl0;
        vc: Cost;
        if e.state == TE_VECTORIZE {
            if e.interleave_factor != 0 slp_fail("interleaved load costs");
            vc = tti_memory_op_cost(t, .LOAD, c.vec_ty, load_store_align(li0), ptr_addrspace(vtype(op(li0, 0))), K);
        } else if e.state == TE_COMPRESS_VECTORIZE {
            scalars := vl_copy(vl);
            if e.reorder_indices.count {
                m := new_mask(); for e.reorder_indices array_add(*m, cast(s32) it);
                slp_reorder_scalars(*scalars, m);
            }
            ptrs := hr_new_list();
            for scalars array_add(*ptrs, op(it, 0));
            mc := slp_is_masked_load_compress(scalars, ptrs, e.reorder_indices, true);
            if !table_contains(*slpx.compress_data, c.te) table_set(*slpx.compress_data, c.te, mc);
            align := load_store_align(li0);
            as := ptr_addrspace(vtype(op(li0, 0)));
            if mc.interleave_factor != 0 slp_fail("interleaved load costs");
            if mc.is_masked {
                m: Mica;
                m.id = IID_MASKED_LOAD; m.data_ty = mc.load_vec_ty; m.align = align; m.addrspace = as;
                vc = x86_mem_intrinsic_cost(t, *m, K);
            } else {
                vc = tti_memory_op_cost(t, .LOAD, mc.load_vec_ty, align, as, K);
            }
            vc = cost_add(vc, slp_shuffle_cost(SK_PERMUTE_SINGLE_SRC, mc.load_vec_ty, mc.compress_mask));
        } else if e.state == TE_SCATTER_VECTORIZE {
            common_align: u64 = 0;
            for v: c.unique_values if is_inst(v) && inst_op(v) == .LOAD { a := load_store_align(v); if common_align == 0 || a < common_align common_align = a; }
            m: Mica;
            m.id = IID_MASKED_GATHER; m.data_ty = c.vec_ty; m.ptr = op(li0, 0); m.variable_mask = false; m.align = common_align;
            vc = x86_mem_intrinsic_cost(t, *m, K);
        } else slp_fail("costs of strided load nodes");
        return cost_add(vc, common);
    }
    if s == ec_op_s32(.STORE) {
        is_reorder := e.reorder_indices.count > 0;
        base_si := ifx is_reorder then vl[e.reorder_indices[0]] else c.vl0;
        if e.state == TE_EXPAND_VECTORIZE {
            found, mst := table_find(*slpx.expand_store_ty, te);
            if !found fatal("internal: slp: expanded store without a masked store type");
            common_align: u64 = 0;
            for v: c.unique_values if is_inst(v) && inst_op(v) == .STORE { a := load_store_align(v); if common_align == 0 || a < common_align common_align = a; }
            m: Mica;
            m.id = IID_MASKED_STORE; m.data_ty = mst; m.align = common_align; m.addrspace = ptr_addrspace(vtype(op(base_si, 1)));
            return cost_add(x86_mem_intrinsic_cost(t, *m, K), common);
        }
        if e.state != TE_VECTORIZE slp_fail("costs of strided store nodes");
        if e.interleave_factor != 0 slp_fail("interleaved store costs");
        vc := tti_memory_op_cost(t, .STORE, c.vec_ty, load_store_align(base_si), ptr_addrspace(vtype(op(base_si, 1))), K, slp_get_operand_info(e.operands[0]));
        return cost_add(vc, common);
    }
    if s == ec_op_s32(.CALL) {
        ci := c.vl0;
        id := get_vector_intrinsic_id_for_call(ci);
        arg_tys := slp_build_intrinsic_arg_types(ci, id, slp_num_elements(c.vec_ty), ifx c.has_bw then cast(u32) c.bw.bits else 0);
        ic, lc := slp_vector_call_costs(ci, c.vec_ty, arg_tys);
        return cost_add(min(ic, lc), common);
    }
    if s == EC_SHUFFLE {
        vc: Cost = 0;
        main_opc := te_opcode(te);
        alt_opc := inst_op(e.s.alt);
        found_equal := false;
        for k: 0..te-1 {
            o := cast(Te_Id) k;
            if te_has_state(o) && is_alt_shuffle(slp.entries[o].s) &&
               ((te_opcode(o) == main_opc && inst_op(slp.entries[o].s.alt) == alt_opc) || (te_opcode(o) == alt_opc && inst_op(slp.entries[o].s.alt) == main_opc)) &&
               te_has_equal_operands(o, te) { found_equal = true; break; }
        }
        if found_equal {
        } else if is_binary_op(main_opc) {
            vc = cost_add(tti_arith_cost(t, main_opc, c.vec_ty, K), tti_arith_cost(t, alt_opc, c.vec_ty, K));
        } else if main_opc == .ICMP || main_opc == .FCMP {
            mask_ty := slp_widened_type(type_int(1), cast(u64) vl.count);
            vc = tti_cmp_sel_cost(t, main_opc, c.vec_ty, mask_ty, inst(c.vl0).pred, K, OI_ANY, OI_ANY, c.vl0);
            vc = cost_add(vc, tti_cmp_sel_cost(t, main_opc, c.vec_ty, mask_ty, inst(e.s.alt).pred, K, OI_ANY, OI_ANY, e.s.alt));
        } else {
            src_scl := vtype(op(e.s.main, 0));
            src_ty := slp_widened_type(src_scl, cast(u64) vl.count);
            if is_int_type(src_scl) && is_int_type(c.sty) {
                ofound, obw := slp_min_bw_of(slp_get_operand_entry(te, 0));
                bw_sz := dl_type_size_bits(c.sty);
                src_bw_sz := dl_type_size_bits(vtype(op(e.s.main, 0)));
                if ofound {
                    src_bw_sz = obw.bits;
                    src_scl = type_int(cast(u32) src_bw_sz);
                    src_ty = slp_widened_type(src_scl, cast(u64) vl.count);
                }
                if bw_sz <= src_bw_sz {
                    if bw_sz < src_bw_sz vc = tti_cast_cost(t, .TRUNC, c.vec_ty, src_ty, CCH_NONE, K);
                    return vc;
                }
            }
            vc = cost_add(tti_cast_cost(t, main_opc, c.vec_ty, src_ty, CCH_NONE, K), tti_cast_cost(t, alt_opc, c.vec_ty, src_ty, CCH_NONE, K));
        }
        mask, _, _ := te_build_alt_op_shuffle_mask(te);
        vc = cost_add(vc, slp_shuffle_cost(SK_PERMUTE_TWO_SRC, c.final_vec_ty, mask));
        om := slp_alt_instr_mask(e.scalars, c.sty, main_opc, alt_opc);
        if tti_is_legal_alt_instr(t, c.vec_ty, main_opc, alt_opc, om) {
            avc := tti_alt_instr_cost(t, c.vec_ty, main_opc, alt_opc, om);
            return ifx avc < vc then avc else vc;
        }
        return vc;
    }
    slp_fail(tprint("getEntryCost (vector) of opcode %", s));
    return COST_INVALID;
}

slp_has :: (a: [] $T, v: T) -> bool { for a if it == v return true; return false; }
PME : s32 : -1;
