// SLPVectorizer: HorizontalReduction (reduction matching and the reduction driver). Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class HorizontalReduction: getRdxKind, isVectorizable,
// matchAssociativeReduction, matchOrderedReduction, matchReductionForOperands, optimizeReducedVals,
// tryToReduce, tryToReduceOrdered; generateKeySubkey, arePointersCompatible).
//
// WORK IN PROGRESS: the code generation of a profitable reduction (emitReduction, emitScaleForReusedOps,
// emitReusedOps, the final reduction ops and their RAUW) is not ported; those paths fail loudly.
//
// hash_value / hash_combine keys of generateKeySubkey only matter for equality (they key MapVectors iterated in
// insertion order), so `hr_hash` is any well-mixed combine of the same inputs.

Hr_Rdx_Kind :: enum u8 {
    NONE; ADD; MUL; OR; AND; XOR; SMIN; SMAX; UMIN; UMAX; FADD; FMUL; FMIN; FMAX; FMINIMUM; FMAXIMUM;
    FMINIMUMNUM; FMAXIMUMNUM; FMULADD;
}
hr_is_int_min_max_kind :: (k: Hr_Rdx_Kind) -> bool { return k == .SMIN || k == .SMAX || k == .UMIN || k == .UMAX; }
hr_is_min_max_kind :: (k: Hr_Rdx_Kind) -> bool {
    return hr_is_int_min_max_kind(k) || k == .FMIN || k == .FMAX || k == .FMINIMUM || k == .FMAXIMUM || k == .FMINIMUMNUM || k == .FMAXIMUMNUM;
}

HR_UNORDERED : s32 : 0; HR_ORDERED : s32 : 1; HR_NONE : s32 : 2;

Hr_Reduction :: struct {
    reduction_ops: [..] [..] Value_Id;      // ReductionOpsListType
    reduced_vals: [..] [..] Value_Id;
    rv_to_ops_keys: [..] Value_Id;          // SmallDenseMap<Value *, SmallVector<Instruction *>> ReducedValsToOps
    rv_to_ops: [..] [..] Value_Id;
    root: Value_Id = NONE;                  // WeakTrackingVH ReductionRoot
    kind: Hr_Rdx_Kind;
    is_supported_identity_op: bool;
    reduction_limit: u32;
    rk: s32 = HR_NONE;
}

hr_init :: (h: *Hr_Reduction) {
    h.reduction_ops.allocator = temp; h.reduced_vals.allocator = temp;
    h.rv_to_ops_keys.allocator = temp; h.rv_to_ops.allocator = temp;
    h.reduction_limit = ifx slp_cl.non_power_of_2 then cast(u32) 3 else 4;
}
hr_new_list :: () -> [..] Value_Id { l: [..] Value_Id; l.allocator = temp; return l; }
vl_copy :: (a: [] Value_Id) -> [..] Value_Id { l: [..] Value_Id; l.allocator = temp; array_add(*l, ..a); return l; }
hr_rv_ops :: (h: *Hr_Reduction, v: Value_Id) -> *[..] Value_Id {
    for h.rv_to_ops_keys if it == v return *h.rv_to_ops[it_index];
    array_add(*h.rv_to_ops_keys, v);
    array_add(*h.rv_to_ops, hr_new_list());
    return *h.rv_to_ops[h.rv_to_ops.count - 1];
}
hr_rv_ops_find :: (h: *Hr_Reduction, v: Value_Id) -> *[..] Value_Id {
    for h.rv_to_ops_keys if it == v return *h.rv_to_ops[it_index];
    return null;
}

// HorizontalReduction(I, Ops)
hr_init_for_operands :: (h: *Hr_Reduction, i: Value_Id, ops: [] Value_Id) {
    hr_init(h);
    h.root = i;
    h.reduction_limit = 2;
    h.kind = hr_get_rdx_kind(i);
    l := hr_new_list(); array_add(*l, i);
    array_add(*h.reduction_ops, l);
    r := hr_new_list(); for ops array_add(*r, it);
    array_add(*h.reduced_vals, r);
    for ops array_add(hr_rv_ops(h, it), i);
}
// matchReductionForOperands
hr_match_reduction_for_operands :: (h: *Hr_Reduction) -> bool {
    two := true;
    for h.reduced_vals if it.count != 2 { two = false; break; }
    h.rk = hr_is_vectorizable(h.kind, h.root, two);
    return h.rk != HR_NONE;
}

// isCmpSelMinMax
hr_is_cmp_sel_min_max :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .SELECT || !is_cmp_inst(op(i, 0)) return false;
    return hr_is_min_max_kind(hr_get_rdx_kind(i));
}
// isBoolLogicOp
hr_is_bool_logic_op :: (i: Value_Id) -> bool {
    if !is_inst(i) || inst_op(i) != .SELECT return false;
    a := pm_logical_and(i);
    if a return true;
    o := pm_logical_or(i);
    return o;
}
// isVectorizable(Kind, I, TwoElementReduction)
hr_is_vectorizable :: (k: Hr_Rdx_Kind, i: Value_Id, two_element := false) -> s32 {
    if k == .NONE return HR_NONE;
    if hr_is_int_min_max_kind(k) || hr_is_bool_logic_op(i) return HR_UNORDERED;
    if two_element return HR_UNORDERED;
    if k == .FMAX || k == .FMIN return ifx (inst_fmf(i) & FMF_NNAN) != 0 then HR_UNORDERED else HR_ORDERED;
    if k == .FMAXIMUM || k == .FMINIMUM return HR_UNORDERED;
    if inst_is_associative(i) return HR_UNORDERED;
    return ifx slp_is_commutative(i) then HR_ORDERED else HR_NONE;
}
// getRdxOperand(I, Index)
hr_rdx_operand :: (i: Value_Id, index: u32) -> Value_Id {
    if hr_get_rdx_kind(i) == .OR && inst_op(i) == .SELECT && index == 1 return op(i, 2);
    return op(i, index);
}
hr_is_supported_ordered_reduction_op :: (i: Value_Id) -> bool { return inst_op(i) == .FADD; }

// getRdxKind(V)
hr_get_rdx_kind :: (v: Value_Id) -> Hr_Rdx_Kind {
    if !is_inst(v) return .NONE;
    o := inst_op(v);
    if o == .ADD return .ADD;
    if o == .MUL return .MUL;
    if o == .AND return .AND;
    if pm_logical_and(v) return .AND;
    if o == .OR return .OR;
    if pm_logical_or(v) return .OR;
    if o == .XOR return .XOR;
    if o == .FADD return .FADD;
    if o == .FMUL return .FMUL;
    id := call_iid(v);
    if id == IID_MAXNUM return .FMAX;
    if id == IID_MINNUM return .FMIN;
    if id == IID_MAXIMUM return .FMAXIMUM;
    if id == IID_MINIMUM return .FMINIMUM;
    // m_SMax / m_SMin / m_UMax / m_UMin match the intrinsics only in LLVM 23 (PatternMatch.h)
    if id == IID_SMAX return .SMAX;
    if id == IID_SMIN return .SMIN;
    if id == IID_UMAX return .UMAX;
    if id == IID_UMIN return .UMIN;
    if o == .SELECT {
        lhs := op(v, 1); rhs := op(v, 2); cond := op(v, 0);
        if !is_cmp_inst(cond) return .NONE;
        pred := inst(cond).pred;
        c0 := op(cond, 0); c1 := op(cond, 1);
        is_ee :: (x: Value_Id) -> bool { return is_inst(x) && inst_op(x) == .EXTRACTELEMENT; }
        if c0 == lhs && is_inst(c1) {
            if !is_ee(rhs) || !is_identical_to(c1, rhs) return .NONE;
        } else if is_inst(c0) && c1 == rhs {
            if !is_ee(lhs) || !is_identical_to(c0, lhs) return .NONE;
        } else {
            if !is_ee(lhs) || !is_ee(rhs) return .NONE;
            if !is_inst(c0) || !is_inst(c1) || !is_identical_to(c0, lhs) || !is_identical_to(c1, rhs) return .NONE;
        }
        if pred == ICMP_SGT || pred == ICMP_SGE return .SMAX;
        if pred == ICMP_SLT || pred == ICMP_SLE return .SMIN;
        if pred == ICMP_UGT || pred == ICMP_UGE return .UMAX;
        if pred == ICMP_ULT || pred == ICMP_ULE return .UMIN;
        return .NONE;
    }
    return .NONE;
}
hr_first_operand_index :: (i: Value_Id) -> u32 { return ifx hr_is_cmp_sel_min_max(i) then cast(u32) 1 else 0; }
hr_number_of_operands :: (i: Value_Id) -> u32 { return ifx hr_is_cmp_sel_min_max(i) then cast(u32) 3 else 2; }
hr_has_required_number_of_uses :: (is_cmp_sel_min_max: bool, i: Value_Id) -> bool {
    if is_cmp_sel_min_max {
        if inst_op(i) == .SELECT return has_n_uses(i, 2) && has_one_use(op(i, 0));
        return has_n_uses(i, 2);
    }
    return has_one_use(i);
}
hr_init_reduction_ops :: (h: *Hr_Reduction, i: Value_Id) {
    array_reset_keeping_memory(*h.reduction_ops);
    array_add(*h.reduction_ops, hr_new_list());
    if hr_is_cmp_sel_min_max(i) array_add(*h.reduction_ops, hr_new_list());
}
hr_add_reduction_ops :: (h: *Hr_Reduction, i: Value_Id) {
    if hr_is_cmp_sel_min_max(i) { array_add(*h.reduction_ops[0], op(i, 0)); array_add(*h.reduction_ops[1], i); }
    else array_add(*h.reduction_ops[0], i);
}
// isGoodForReduction(Data)
hr_is_good_for_reduction :: (data: [] Value_Id) -> bool {
    i := data[0];
    return data.count > 1 || slp_is_constant(i) || (is_inst(i) && inst_op(i) != .LOAD && slp_is_valid_for_alternation(inst_op(i)));
}
hr_mark_ops_analyzed :: (h: *Hr_Reduction) {
    for l: h.reduction_ops for l slp_analyzed_reduction_root(it);
}

// ---------------------------------------------------------------- keys

hr_hash :: (vals: ..u64) -> u64 {
    h: u64 = 0xcbf2_9ce4_8422_2325;
    for vals { h ^= it + 0x9e37_79b9_7f4a_7c15 + (h << 6) + (h >> 2); h *= 0x1000_0000_01b3; }
    return h;
}

// arePointersCompatible(Ptr1, Ptr2, TLI, CompareOpcodes)
slp_are_pointers_compatible :: (p1: Value_Id, p2: Value_Id, compare_opcodes := true) -> bool {
    d := cast(u32) slp_cl.recursion_max_depth;
    if get_underlying_object(p1, d) != get_underlying_object(p2, d) return false;
    g1 := is_inst(p1) && inst_op(p1) == .GEP; g2 := is_inst(p2) && inst_op(p2) == .GEP;
    return (!g1 || nops(p1) == 2) && (!g2 || nops(p2) == 2) &&
           (((!g1 || slp_is_constant(op(p1, 1))) && (!g2 || slp_is_constant(op(p2, 1)))) || !compare_opcodes ||
            (g1 && g2 && is_valid(slp_get_same_opcode(.[op(p1, 1), op(p2, 1)]))));
}

// The GenerateLoadsSubkey state of matchAssociativeReduction
Loads_Subkey_State :: struct {
    keys: [..] [2] u64;             // (Key, Ptr) of LoadsMap
    loads: [..] [..] Value_Id;
    key_used: [..] u64;
}
hr_loads_subkey :: (st: *Loads_Subkey_State, key_in: u64, li: Value_Id) -> u64 {
    key := hr_hash(cast(u64) block_number(inst_block(li)), key_in);
    ptr := get_underlying_object(op(li, 0), cast(u32) slp_cl.recursion_max_depth);
    used := false;
    for st.key_used if it == key { used = true; break; }
    if used {
        k := -1;
        for st.keys if it[0] == key && it[1] == ptr { k = it_index; break; }
        if k >= 0 {
            for rli: st.loads[k] {
                ok := get_pointers_diff(vtype(rli), op(rli, 0), vtype(li), op(li, 0), true);
                if ok return hr_hash(0x5555, op(rli, 0));
            }
            for rli: st.loads[k] if slp_are_pointers_compatible(op(rli, 0), op(li, 0)) return hr_hash(0x5555, op(rli, 0));
            if st.loads[k].count > 2 return hr_hash(0x5555, op(st.loads[k][st.loads[k].count - 1], 0));
        }
    } else array_add(*st.key_used, key);
    k := -1;
    for st.keys if it[0] == key && it[1] == ptr { k = it_index; break; }
    if k < 0 {
        array_add(*st.keys, .[key, cast(u64) ptr]);
        array_add(*st.loads, hr_new_list());
        k = st.keys.count - 1;
    }
    array_add(*st.loads[k], li);
    return hr_hash(0x5555, op(li, 0));
}

// generateKeySubkey(V, TLI, LoadsSubkeyGenerator, AllowAlternate)
slp_generate_key_subkey :: (v: Value_Id, st: *Loads_Subkey_State, allow_alternate: bool) -> (u64, u64) {
    key := hr_hash(1, slp_value_id(v) + 2);
    sub := hr_hash(2, 0);
    if is_inst(v) && inst_op(v) == .LOAD {
        key = hr_hash(3, vtype(v), cast(u64) Opcode.LOAD, key);
        if is_simple_load_store(v) sub = hr_hash(4, hr_loads_subkey(st, key, v));
        else { key = hr_hash(5, v); sub = key; }
    } else if slp_is_vector_like_inst_with_const_ops(v) {
        if (is_inst(v) && inst_op(v) == .EXTRACTELEMENT) || pm_undef_value(v) key = hr_hash(1, 0 + 1);   // UndefValueVal + 1
        if is_inst(v) && inst_op(v) == .EXTRACTELEMENT {
            if !all_bits(slp_is_undef_vector(op(v, 0))) && !pm_undef_value(op(v, 1)) sub = hr_hash(6, op(v, 0));
        }
    } else if is_inst(v) {
        o := inst_op(v);
        if (is_binary_op(o) || is_cast_op(o)) && slp_is_valid_for_alternation(o) {
            if allow_alternate key = hr_hash(7, cast(u64) is_binary_op(o));
            else key = hr_hash(8, cast(u64) o, key);
            sub = hr_hash(9, cast(u64) o, vtype(v), ifx is_binary_op(o) then vtype(v) else vtype(op(v, 0)));
            if is_cast_op(o) {
                k2, _ := slp_generate_key_subkey(op(v, 0), st, true);
                key = hr_hash(10, k2, key);
                sub = hr_hash(10, k2, sub);
            }
        } else if o == .ICMP || o == .FCMP {
            pred := inst(v).pred;
            if slp_is_commutative(v) pred = min(pred, cmp_inverse(pred));
            sp := swapped_predicate(pred);
            sub = hr_hash(11, cast(u64) o, pred, sp, vtype(op(v, 0)));
        } else if o == .CALL {
            id := get_vector_intrinsic_id_for_call(v);
            if is_trivially_vectorizable(id) sub = hr_hash(12, cast(u64) o, cast(u64) id);
            else if call_has_vector_variants(v) sub = hr_hash(13, cast(u64) o, call_called_function(v));
            else { key = hr_hash(14, v, key); sub = hr_hash(15, cast(u64) o, v); }
            if call_num_bundles(v) > 0 slp_fail("operand bundles in generateKeySubkey");
        } else if o == .GEP {
            if nops(v) == 2 && vkind(op(v, 1)) == .C_INT sub = hr_hash(16, op(v, 0));
            else sub = hr_hash(17, v);
        } else if is_int_div_rem(o) && vkind(op(v, 1)) != .C_INT {
            sub = hr_hash(18, v);
        } else {
            sub = hr_hash(19, cast(u64) o);
        }
        key = hr_hash(20, cast(u64) block_number(inst_block(v)), key);
    }
    return key, sub;
}

// ---------------------------------------------------------------- matching

// optimizeReducedVals(R, DT, DL, TTI, TLI)
hr_optimize_reduced_vals :: (h: *Hr_Reduction) {
    used_ops: [..] [2] s64; used_ops.allocator = temp;   // opcode -> first index
    for vals, idx: h.reduced_vals {
        if !is_inst(vals[0]) continue;
        o := cast(s64) inst_op(vals[0]);
        found := false;
        for used_ops if it[0] == o { found = true; break; }
        if !found array_add(*used_ops, .[o, idx]);
    }
    zext_idx := -1; sel_idx := -1;
    for used_ops { if it[0] == cast(s64) Opcode.ZEXT zext_idx = it[1]; if it[0] == cast(s64) Opcode.SELECT sel_idx = it[1]; }
    if zext_idx >= 0 && sel_idx >= 0 {
        z := h.reduced_vals[zext_idx][0];
        if vtype(op(z, 0)) == type_int(1) && vtype(z) == vtype(h.reduced_vals[sel_idx][0]) {
            for h.reduced_vals[sel_idx] array_add(*h.reduced_vals[zext_idx], it);
            array_ordered_remove_by_index(*h.reduced_vals, sel_idx);
        }
    }
    if h.reduced_vals.count == 2 && (h.reduced_vals[0].count == 1 || h.reduced_vals[1].count == 1) {
        ops := hr_new_list();
        for h.reduced_vals[0] array_add(*ops, it);
        for h.reduced_vals[1] array_add(*ops, it);
        // buildInstructionsState(Ops, R, /*TryCopyableElementsVectorization=*/true, /*WithProfitabilityCheck=*/true):
        // the two bools bind to WithProfitabilityCheck and SkipSameCodeCheck
        ops_s := ica_build_instructions_state(ops, true, true);
        if is_valid(ops_s) && ops_s.has_copyables && is_opcode(ops_s) == .SHL {
            if h.reduced_vals[1].count == 1 && h.reduced_vals[0].count != 1 {
                t := h.reduced_vals[0]; h.reduced_vals[0] = h.reduced_vals[1]; h.reduced_vals[1] = t;
            }
            back := h.reduced_vals[1];
            shl_c :: (v: Value_Id) -> (bool, u64) {
                if !is_inst(v) || inst_op(v) != .SHL || vkind(op(v, 1)) != .C_INT return false, 0;
                return true, ap_zext_value(cf_ap(op(v, 1)));
            }
            less :: (a: Value_Id, b: Value_Id) -> bool {
                oa, ca := shl_c(a);
                if !oa return false;
                ob, cb := shl_c(b);
                if !ob return true;
                return ca < cb;
            }
            gnu_stable_sort(back, less);
            for back array_add(*h.reduced_vals[0], it);
            h.reduced_vals.count -= 1;
        }
    }
}

hr_stable_sort_by_size_desc :: (lists: [] [..] Value_Id) {
    for i: 1..lists.count-1 {
        x := lists[i]; j := i;
        while j > 0 && x.count > lists[j - 1].count { lists[j] = lists[j - 1]; j -= 1; }
        lists[j] = x;
    }
}

// matchAssociativeReduction(R, Root, SE, DT, DL, TTI, TLI)
hr_match_associative_reduction :: (h: *Hr_Reduction, root: Value_Id) -> bool {
    h.kind = hr_get_rdx_kind(root);
    h.rk = hr_is_vectorizable(h.kind, root);
    if h.rk == HR_NONE return false;
    ty := vtype(root);
    if !slp_is_valid_element_type(ty) || is_ptr_type(ty) return false;
    if inst_op(root) == .SELECT && !has_one_use(op(root, 0)) h.rk = HR_ORDERED;
    h.root = root;
    bb := inst_block(root);
    is_csmm := hr_is_cmp_sel_min_max(root);
    Item :: struct { i: Value_Id; level: s64; }
    worklist: [..] Item; worklist.allocator = temp;
    array_add(*worklist, .{root, 0});
    operands: Table(Value_Id, bool); operands.allocator = temp;
    possible_ordered: [..] Item; possible_ordered.allocator = temp;
    hr_init_reduction_ops(h, root);
    st: Loads_Subkey_State;
    st.keys.allocator = temp; st.loads.allocator = temp; st.key_used.allocator = temp;
    candidates := hr_new_list();
    adjusted_to_ordered := false;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    while worklist.count {
        top := pop(*worklist);
        tree_n := top.i; level := top.level;
        if table_contains(*visited, tree_n) continue;
        table_set(*visited, tree_n, true);
        possible_red_vals := hr_new_list();
        possible_red_ops := hr_new_list();
        // CheckOperands
        {
            fi := cast(s64) hr_first_operand_index(tree_n);
            n := cast(s64) hr_number_of_operands(tree_n);
            k := n - 1;
            while k >= fi {
                defer k -= 1;
                edge_val := hr_rdx_operand(tree_n, cast(u32) k);
                array_add(hr_rv_ops(h, edge_val), tree_n);
                edge_inst := ifx is_inst(edge_val) then edge_val else NONE;
                is_reduced := edge_inst == NONE || level > slp_cl.recursion_max_depth || hr_get_rdx_kind(edge_inst) != h.kind ||
                              is_csmm != hr_is_cmp_sel_min_max(edge_inst);
                cur_rk := ifx is_reduced then HR_NONE else hr_is_vectorizable(h.kind, edge_inst);
                if !is_reduced && cur_rk == HR_UNORDERED && h.rk == HR_UNORDERED && !hr_has_required_number_of_uses(is_csmm, edge_inst) {
                    is_reduced = true;
                    cur_rk = HR_NONE;
                    if possible_red_vals.count < cast(s64) h.reduction_limit && !table_contains(*operands, edge_inst)
                        array_add(*possible_ordered, .{edge_inst, level});
                }
                all_const := false;
                if edge_inst != NONE && slp_is_analyzed_reduction_root(edge_inst) {
                    all_const = true;
                    for j: 0..cast(s64) nops(edge_inst) - 1 if !is_constant_kind(vkind(op(edge_inst, cast(u32) j))) { all_const = false; break; }
                }
                if cur_rk == HR_NONE || (edge_inst != NONE && table_contains(*operands, edge_inst)) || all_const {
                    array_add(*possible_red_vals, edge_val);
                    if edge_inst != NONE && !hr_is_cmp_sel_min_max(edge_inst)
                        for j: 0..cast(s64) nops(edge_inst) - 1 table_set(*operands, op(edge_inst, cast(u32) j), true);
                    continue;
                }
                if cur_rk == HR_ORDERED h.rk = HR_ORDERED;
                array_add(*possible_red_ops, edge_inst);
            }
        }
        hr_add_reduction_ops(h, tree_n);
        for possible_red_vals array_add(*candidates, it);
        for < possible_red_ops array_add(*worklist, .{it, ifx inst_block(it) == bb then 0 else level + 1});
        if worklist.count == 0 && candidates.count < cast(s64) h.reduction_limit && possible_ordered.count && h.rk == HR_UNORDERED {
            h.rk = HR_ORDERED;
            adjusted_to_ordered = true;
            k := 0;
            while k < candidates.count {
                c := candidates[k];
                hit := false;
                if is_inst(c) for possible_ordered if it.i == c { hit = true; break; }
                if hit array_ordered_remove_by_index(*candidates, k); else k += 1;
            }
            for possible_ordered array_add(*worklist, it);
            array_reset_keeping_memory(*possible_ordered);
        }
    }
    REDUCED_VALS_LIMIT :: 1024;
    if candidates.count > REDUCED_VALS_LIMIT && adjusted_to_ordered && is_int_or_int_vector(vtype(candidates[0])) return false;
    // PossibleReducedVals: MapVector<Key, MapVector<SubKey, MapVector<Value *, count>>>
    Sub_Group :: struct { sub: u64; vals: [..] Value_Id; counts: [..] u32; }
    Key_Group :: struct { key: u64; subs: [..] Sub_Group; }
    groups: [..] Key_Group; groups.allocator = temp;
    for v: candidates {
        if h.rk == HR_ORDERED && !is_inst(v) continue;
        key, sub := slp_generate_key_subkey(v, *st, false);
        g: *Key_Group = null;
        for * groups if it.key == key { g = it; break; }
        if !g { array_add(*groups, .{key = key}); g = *groups[groups.count - 1]; g.subs.allocator = temp; }
        s: *Sub_Group = null;
        for * g.subs if it.sub == sub { s = it; break; }
        if !s { array_add(*g.subs, .{sub = sub}); s = *g.subs[g.subs.count - 1]; s.vals.allocator = temp; s.counts.allocator = temp; }
        found := false;
        for s.vals if it == v { s.counts[it_index] += 1; found = true; break; }
        if !found { array_add(*s.vals, v); array_add(*s.counts, 1); }
    }
    for g: groups {
        vect: [..] [..] Value_Id; vect.allocator = temp;
        for s: g.subs {
            // stable_sort(RedValsVect, less_second())
            n := s.vals.count;
            vals := array_copy(s.vals,, temp); cnts := array_copy(s.counts,, temp);
            for i: 1..n-1 {
                xv := vals[i]; xc := cnts[i]; j := i;
                while j > 0 && xc < cnts[j - 1] { vals[j] = vals[j - 1]; cnts[j] = cnts[j - 1]; j -= 1; }
                vals[j] = xv; cnts[j] = xc;
            }
            l := hr_new_list();
            for v, k: vals for 1..cnts[k] array_add(*l, v);
            array_add(*vect, l);
        }
        hr_stable_sort_by_size_desc(vect);
        first := true;
        for data: vect {
            if first {
                first = false;
                array_add(*h.reduced_vals, hr_new_list());
            } else if !hr_is_good_for_reduction(data) {
                li := data[0];
                last_li := h.reduced_vals[h.reduced_vals.count - 1][0];
                is_ld :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .LOAD; }
                if !is_ld(li) || !is_ld(last_li) || get_underlying_object(op(li, 0)) != get_underlying_object(op(last_li, 0))
                    array_add(*h.reduced_vals, hr_new_list());
            }
            back := *h.reduced_vals[h.reduced_vals.count - 1];
            for < data array_add(back, it);
        }
    }
    hr_optimize_reduced_vals(h);
    hr_stable_sort_by_size_desc(h.reduced_vals);
    return true;
}

// matchOrderedReduction(R, Root, MatchLHS)
hr_match_ordered_reduction :: (h: *Hr_Reduction, root: Value_Id, match_lhs: bool) -> bool {
    array_reset_keeping_memory(*h.reduced_vals);
    array_reset_keeping_memory(*h.rv_to_ops_keys); array_reset_keeping_memory(*h.rv_to_ops);
    array_reset_keeping_memory(*h.reduction_ops);
    h.kind = hr_get_rdx_kind(root);
    if h.kind != .FADD return false;
    if hr_is_vectorizable(h.kind, root) != HR_ORDERED return false;
    if hr_is_cmp_sel_min_max(root) || hr_is_bool_logic_op(root) return false;
    ty := vtype(root);
    if !slp_is_valid_element_type(ty) || is_ptr_type(ty) return false;
    h.rk = HR_ORDERED;
    h.root = root;
    bb := inst_block(root);
    fi := hr_first_operand_index(root);
    chain_idx := ifx match_lhs then fi else fi + 1;
    leaf_idx := ifx match_lhs then fi + 1 else fi;
    hr_init_reduction_ops(h, root);
    array_add(*h.reduced_vals, hr_new_list());
    back := *h.reduced_vals[0];
    visited: Table(Value_Id, bool); visited.allocator = temp;
    tree_n := root;
    depth := 0;
    complete := false;
    MAX_REDUCED_VALS :: 1024;
    while tree_n != NONE {
        if depth > slp_cl.recursion_max_depth break;
        depth += 1;
        if back.count >= MAX_REDUCED_VALS break;
        if table_contains(*visited, tree_n) break;
        table_set(*visited, tree_n, true);
        if hr_get_rdx_kind(tree_n) != h.kind break;
        if inst_block(tree_n) != bb break;
        hr_add_reduction_ops(h, tree_n);
        leaf := hr_rdx_operand(tree_n, leaf_idx);
        chain := hr_rdx_operand(tree_n, chain_idx);
        array_add(hr_rv_ops(h, leaf), tree_n);
        array_add(hr_rv_ops(h, chain), tree_n);
        array_add(back, leaf);
        if !is_inst(chain) || hr_get_rdx_kind(chain) != h.kind || !hr_has_required_number_of_uses(false, chain) {
            array_add(back, chain);
            complete = true;
            break;
        }
        tree_n = chain;
    }
    if !complete || back.count < cast(s64) h.reduction_limit {
        hr_mark_ops_analyzed(h);
        h.reduced_vals.count -= 1;
        array_reset_keeping_memory(*h.rv_to_ops_keys); array_reset_keeping_memory(*h.rv_to_ops);
        array_reset_keeping_memory(*h.reduction_ops);
        return false;
    }
    n := back.count;
    for k: 0..n/2-1 { t := back.*[k]; back.*[k] = back.*[n - 1 - k]; back.*[n - 1 - k] = t; }
    return true;
}

// GetVectorFactor of tryToReduce / tryToReduceOrdered
hr_vector_factor :: (sty: Type_Id, redux_in: u64) -> u64 {
    redux := slp_floor_full_vector_number_of_elements(slp.tti, sty, redux_in);
    tp := slp_widened_type(sty, redux);
    num_parts := slp_number_of_parts(slp.tti, tp, sty);
    num_regs := cast(u64) tti_number_of_registers(slp.tti, tti_register_class_for_type(slp.tti, true, tp));
    while num_parts > num_regs {
        redux = bit_floor(redux - 1);
        tp = slp_widened_type(sty, redux);
        num_parts = slp_number_of_parts(slp.tti, tp, sty);
        num_regs = cast(u64) tti_number_of_registers(slp.tti, tti_register_class_for_type(slp.tti, true, tp));
    }
    if num_parts > num_regs / 2 redux = bit_floor(redux);
    return redux;
}

// tryToReduce(V, DL, TTI, TLI, AC, DT)
hr_try_to_reduce :: (h: *Hr_Reduction) -> Value_Id {
    REG_MAX_NUMBER :: 4;
    red_vals_max: u64 = ifx h.rk == HR_ORDERED && is_int_or_int_vector(vtype(h.root)) then cast(u64) 48 else 128;
    {
        num: u64 = 0;
        for h.reduced_vals if hr_is_good_for_reduction(it) num += cast(u64) it.count;
        all := true;
        for rv: h.reduced_vals if !(rv.count < 2 || !slp_all_constant(rv) || !slp_is_splat(rv)) { all = false; break; }
        if num < h.reduction_limit && all { hr_mark_ops_analyzed(h); return NONE; }
    }
    ignore_list: [..] Value_Id; ignore_list.allocator = temp;
    for l: h.reduction_ops for l if it != NONE {
        dup := false;
        for x: ignore_list if x == it { dup = true; break; }
        if !dup array_add(*ignore_list, it);
    }
    rdx_fmf: u32 = FMF_ALL;
    for ignore_list if is_fp_math_inst(it) rdx_fmf &= inst_fmf(it);
    if h.rk == HR_ORDERED array_reset_keeping_memory(*ignore_list);
    is_csmm := hr_is_cmp_sel_min_max(h.root);
    // TrackedVals: no vectorization happens before the first buildTree here, so every value maps to itself.
    vectorized_vals_keys: [..] Value_Id; vectorized_vals_keys.allocator = temp;
    vectorized_vals_cnt: [..] u32; vectorized_vals_cnt.allocator = temp;
    states: [..] Inst_State; states.allocator = temp;
    local: [..] [..] Value_Id; local.allocator = temp;
    two_groups_only := h.reduced_vals.count == 2;
    two_small := two_groups_only && h.reduced_vals[0].count == h.reduced_vals[1].count && h.reduced_vals[0].count < cast(s64) h.reduction_limit;
    for rv: h.reduced_vals {
        if pm_undef_value(rv[0]) && (states.count == 0 || !is_valid(states[states.count - 1]) || is_opcode(states[states.count - 1]) == .LOAD) {
            l := vl_copy(rv);
            array_add(*local, l); array_add(*states, IS_INVALID);
            continue;
        }
        if local.count && pm_undef_value(local[local.count - 1][0]) && is_inst(rv[0]) && inst_op(rv[0]) == .LOAD {
            l := vl_copy(rv);
            array_add(*local, l); array_add(*states, slp_get_same_opcode(rv));
            continue;
        }
        if !two_small {
            ops := hr_new_list();
            if local.count for local[local.count - 1] array_add(*ops, it);
            for rv array_add(*ops, it);
            ops_s := ica_build_instructions_state(ops, true);
            if is_valid(ops_s) {
                if local.count == 0 { array_add(*local, ops); array_add(*states, ops_s); continue; }
                local[local.count - 1] = ops;
                states[states.count - 1] = ops_s;
                continue;
            }
            if two_groups_only {
                main, alt := slp_main_alt_ops_no_state_vl(ops);
                if main != NONE && alt != NONE {
                    ops_s = .{main, alt, false};
                    if slp_can_build_split_node(ops, ops_s) {
                        if local.count == 0 { array_add(*local, ops); array_add(*states, ops_s); continue; }
                        local[local.count - 1] = ops;
                        states[states.count - 1] = ops_s;
                        continue;
                    }
                }
            }
        }
        l := vl_copy(rv);
        array_add(*local, l); array_add(*states, slp_get_same_opcode(rv));
    }
    h.reduced_vals = local;
    check_for_reused := false;
    e := h.reduced_vals.count;
    i := 0;
    while i < e {
        defer i += 1;
        orig := h.reduced_vals[i];
        s := states[i];
        candidates := hr_new_list();
        excluded := hr_new_list();
        for rv: orig {
            if is_inst(rv) && slp_is_deleted(rv) continue;
            if is_inst(rv) && slp_is_vector_like_inst_with_const_ops(rv) &&
               (!is_valid(s) || (is_matching_main_or_alt(s, rv) == NONE && !is_copyable_element(s, rv))) {
                array_add(*excluded, rv);
                continue;
            }
            if is_valid(s) && !is_inst(rv) && !pm_undef_value(rv) && !is_copyable_element(s, rv) continue;
            array_add(*candidates, rv);
        }
        shuffled_extracts := false;
        if is_valid(s) && is_opcode(s) == .EXTRACTELEMENT && !is_alt_shuffle(s) && i + 1 < e {
            common := vl_copy(candidates);
            for rv: h.reduced_vals[i + 1] if is_inst(rv) && inst_op(rv) == .EXTRACTELEMENT array_add(*common, rv);
            fixed := slp_is_fixed_vector_shuffle(common, slp.ac);
            if fixed {
                i += 1;
                candidates = common;
                shuffled_extracts = true;
            }
        }
        if candidates.count > 1 && slp_all_constant(candidates) {
            if h.rk == HR_ORDERED continue;
            slp_fail("constant-folded reduced values in a horizontal reduction (const.rdx)");
        }
        num_reduced := cast(u64) candidates.count;
        if num_reduced < h.reduction_limit && (num_reduced < 2 || !slp_is_splat(candidates)) continue;
        h.is_supported_identity_op = h.rk == HR_UNORDERED && h.kind != .MUL && h.kind != .FMUL && h.kind != .FMULADD;
        same_keys := hr_new_list();
        same_cnts: [..] u32; same_cnts.allocator = temp;
        if h.is_supported_identity_op for v: candidates {
            found := false;
            for same_keys if it == v { same_cnts[it_index] += 1; found = true; break; }
            if !found { array_add(*same_keys, v); array_add(*same_cnts, 1); }
        }
        opt_reused := h.is_supported_identity_op && same_keys.count != candidates.count;
        if opt_reused {
            candidates = vl_copy(same_keys);
            num_reduced = cast(u64) candidates.count;
            if num_reduced == 1 slp_fail("a horizontal reduction of one repeated value (emitScaleForReusedOps)");
        }
        max_elts := clamp(bit_floor(slp.max_vec_reg_size / slp_get_vector_element_size(candidates[0])), red_vals_max, REG_MAX_NUMBER * red_vals_max);
        redux := num_reduced;
        sty := vtype(candidates[0]);
        if !slp_is_allowed_non_power_of_2_vf(redux) redux = hr_vector_factor(sty, redux);
        redux = min(redux, max_elts);
        start: u64 = 0;
        pos := start;
        prev_redux := redux;
        check_local := false;
        adjust :: (h: *Hr_Reduction, ignore_vl: bool, ignore_list: [] Value_Id, check_local: *bool, prev_redux: u64, redux: *u64, pos: *u64,
                   start: u64, num_reduced: u64, sty: Type_Id) -> bool {
            any_gathered := !ignore_vl && (h.rk == HR_ORDERED || slp_is_any_gathered(ignore_list));
            if !check_local.* && prev_redux == redux.* check_local.* |= any_gathered;
            pos.* += 1;
            if pos.* < num_reduced - redux.* + 1 return any_gathered;
            pos.* = start;
            redux.* -= 1;
            if redux.* > 1 redux.* = hr_vector_factor(sty, redux.*);
            return any_gathered;
        }
        ignored: [..] [2] u64; ignored.allocator = temp;
        is_ignored :: (l: [] [2] u64, a: u64, b: u64) -> bool { for l if it[0] == a && it[1] == b return true; return false; }
        while pos < num_reduced - redux + 1 && redux >= h.reduction_limit {
            if check_local && prev_redux != redux && start == 0 { check_for_reused = true; break; }
            prev_redux = redux;
            vl := array_view(candidates, cast(s64) pos, cast(s64) redux);
            if is_ignored(ignored, pos, redux) ||
               (!has_single_bit(redux) && (is_ignored(ignored, pos, bit_floor(redux)) || is_ignored(ignored, pos + (redux - bit_floor(redux)), bit_floor(redux)))) ||
               slp_are_analyzed_reduction_vals(vl) {
                adjust(h, true, ignore_list, *check_local, prev_redux, *redux, *pos, start, num_reduced, sty);
                continue;
            }
            any_del := false;
            for vl if is_inst(it) && slp_is_deleted(it) { any_del = true; break; }
            if any_del break;
            if h.rk == HR_ORDERED slp_build_tree(vl);
            else slp_build_tree_with_ignore(vl, ignore_list);
            if slp_is_tree_tiny_and_not_fully_vectorizable(h.rk == HR_UNORDERED) {
                CANDIDATES_LIMIT :: 64;
                if !adjust(h, h.rk == HR_ORDERED && candidates.count >= CANDIDATES_LIMIT, ignore_list, *check_local, prev_redux, *redux, *pos, start, num_reduced, sty)
                    slp_analyzed_reduction_vals(vl);
                continue;
            }
            slp_reorder_top_to_bottom();
            slp_reorder_bottom_to_top((rdx_fmf & FMF_REASSOC) != 0 || is_int_or_int_vector(vtype(vl[0])) || h.reduction_limit > 2 || h.rk == HR_ORDERED);
            // LocalExternallyUsedValues (TrackedVals map every value to itself: nothing was vectorized yet)
            local_ext := vl_copy(excluded);
            set_add_v(*local_ext, h.root);
            for cnt: 0..h.reduced_vals.count-1 {
                if cnt == i || (shuffled_extracts && cnt == i - 1) continue;
                for v: h.reduced_vals[cnt] if is_inst(v) set_add_v(*local_ext, v);
            }
            nsv_keys := hr_new_list(); nsv_cnts: [..] u32; nsv_cnts.allocator = temp;
            if !h.is_supported_identity_op {
                for cnt: 0..cast(s64) num_reduced - 1 {
                    if cast(u64) cnt >= pos && cast(u64) cnt < pos + redux continue;
                    orig := candidates[cnt];
                    found := false;
                    for nsv_keys if it == orig { nsv_cnts[it_index] += 1; found = true; break; }
                    if !found { array_add(*nsv_keys, orig); array_add(*nsv_cnts, 1); }
                }
            }
            slp_transform_nodes();
            slp_compute_minimum_value_sizes();
            tree_cost := slp_calculate_tree_cost_and_trim_non_profitable(vl);
            {
                visited := hr_new_list();
                for cnt: 0..cast(s64) num_reduced - 1 {
                    if cast(u64) cnt >= pos && cast(u64) cnt < pos + redux continue;
                    rdx := candidates[cnt];
                    if slp_has(visited, rdx) continue;
                    array_add(*visited, rdx);
                    if !slp_has(vl, rdx) && slp_is_vectorized(rdx) { set_add_v(*local_ext, rdx); continue; }
                    num_ops: u32 = 0;
                    if h.is_supported_identity_op { for same_keys if it == rdx { num_ops = same_cnts[it_index]; break; } }
                    else { for nsv_keys if it == rdx { num_ops = nsv_cnts[it_index]; break; } }
                    rops := hr_rv_ops_find(h, rdx);
                    if !rops || cast(s64) num_ops != rops.count set_add_v(*local_ext, rdx);
                }
            }
            slp_build_external_uses(local_ext);
            reduction_cost: Cost = 0;
            if !(h.rk == HR_ORDERED || slp_is_reduced_bitcast_root() || slp_is_reduced_cmp_bitcast_root()) {
                if h.is_supported_identity_op reduction_cost = hr_get_reduction_cost(h, vl, same_keys, same_cnts, is_csmm, rdx_fmf);
                else reduction_cost = hr_get_reduction_cost(h, vl, .[], .[], is_csmm, rdx_fmf);
            }
            insert_pt := h.root;
            if is_csmm insert_pt = op(h.root, 0);
            cost := slp_get_tree_cost(tree_cost, vl, reduction_cost, insert_pt);
            #if DEBUG_SLP print("SLP: Found cost = % for reduction\n", cost_to_string(cost));
            if !cost_valid(cost) break;
            if cost >= -slp_cl.threshold {
                if !adjust(h, false, ignore_list, *check_local, prev_redux, *redux, *pos, start, num_reduced, sty) {
                    slp_analyzed_reduction_vals(vl);
                    offset := ifx pos == start then pos else pos - 1;
                    if redux > h.reduction_limit && slp_is_tree_not_extendable() {
                        vf := slp_floor_full_vector_number_of_elements(slp.tti, vtype(vl[0]), redux - 1);
                        while vf >= h.reduction_limit {
                            defer vf = slp_floor_full_vector_number_of_elements(slp.tti, vtype(vl[0]), vf - 1);
                            if has_single_bit(vf) && slp_canonical_graph_size() != cast(u32) slp.entries.count continue;
                            for idx: 0..cast(s64) (redux - vf) - 1 array_add(*ignored, .[offset + cast(u64) idx, vf]);
                        }
                    }
                }
                continue;
            }
            slp_fail("vectorizeTree of a horizontal reduction");
        }
        // nothing vectorized (AnyVectorized is false): reused scalars are still emitted as scaled values
        if opt_reused slp_fail("scaled reused values of a horizontal reduction (emitScaleForReusedOps)");
    }
    if h.rk == HR_ORDERED return NONE;
    if !check_for_reused hr_mark_ops_analyzed(h);   // nothing was vectorized: VectorizedTree is null
    return NONE;
}

// tryToReduceOrdered(V, DL, TTI, TLI, AC, DT)
hr_try_to_reduce_ordered :: (h: *Hr_Reduction) -> Value_Id {
    REG_MAX_NUMBER :: 4;
    RED_VALS_MAX_NUMBER :: 128;
    candidates := h.reduced_vals[h.reduced_vals.count - 1];
    max_elts := clamp(bit_floor(slp.max_vec_reg_size / slp_get_vector_element_size(candidates[0])), RED_VALS_MAX_NUMBER, REG_MAX_NUMBER * RED_VALS_MAX_NUMBER);
    sty := vtype(candidates[0]);
    ignore_list: [..] Value_Id; ignore_list.allocator = temp;
    for l: h.reduction_ops for l if it != NONE {
        dup := false;
        for x: ignore_list if x == it { dup = true; break; }
        if !dup array_add(*ignore_list, it);
    }
    try_window :: (h: *Hr_Reduction, candidates: [] Value_Id, start: u64, width: u64, ignore_list: [] Value_Id) -> bool {
        vl := array_view(candidates, cast(s64) start, cast(s64) width);
        if slp_are_analyzed_reduction_vals(vl) return false;
        for vl if is_inst(it) && slp_is_deleted(it) return false;
        slp_build_tree_with_ignore(vl, ignore_list);
        if slp_is_tree_tiny_and_not_fully_vectorizable(true) { slp_analyzed_reduction_vals(vl); return false; }
        slp_reorder_bottom_to_top();
        local_ext := hr_new_list();
        set_add_v(*local_ext, h.root);
        for c, cnt: candidates {
            if cast(u64) cnt >= start && cast(u64) cnt < start + width continue;
            if is_inst(c) set_add_v(*local_ext, c);
        }
        slp_transform_nodes();
        slp_compute_minimum_value_sizes();
        tree_cost := slp_calculate_tree_cost_and_trim_non_profitable(vl, h.root);
        slp_build_external_uses(local_ext);
        // RdxFMF: the flags of the reduction ops of the candidates, without reassoc
        fmf: u32 = FMF_ALL;
        for c: candidates { p := hr_rv_ops_find(h, c); if p for o: p.* if is_fp_math_inst(o) fmf &= inst_fmf(o); }
        fmf &= ~cast(u32) FMF_REASSOC;
        reduction_cost := hr_get_reduction_cost(h, vl, .[], .[], false, fmf);
        cost := slp_get_tree_cost(tree_cost, vl, reduction_cost, h.root);
        #if DEBUG_SLP print("SLP: Found cost = % for ordered reduction\n", cost_to_string(cost));
        if cost > -slp_cl.threshold { slp_analyzed_reduction_vals(vl); return false; }
        slp_fail("vectorizeTree of an ordered horizontal reduction");
        return false;
    }
    n := cast(u64) candidates.count;
    redux := n;
    if !slp_cl.non_power_of_2 || !has_single_bit(redux + 1) redux = hr_vector_factor(sty, redux);
    redux = min(redux, max_elts);
    while redux >= h.reduction_limit {
        if try_window(h, candidates, 0, redux, ignore_list) break;
        back_start := n - redux;
        if back_start != 0 && try_window(h, candidates, back_start, redux, ignore_list) break;
        redux -= 1;
        if redux > 1 redux = hr_vector_factor(sty, redux);
    }
    hr_mark_ops_analyzed(h);
    return NONE;
}

// ---------------------------------------------------------------- the cost of a reduction

// RecurrenceDescriptor::getOpcode(RdxKind)
hr_kind_opcode :: (k: Hr_Rdx_Kind) -> Opcode {
    if k == {
        case .ADD; return .ADD; case .MUL; return .MUL; case .OR; return .OR; case .AND; return .AND; case .XOR; return .XOR;
        case .FADD; return .FADD; case .FMUL; return .FMUL;
    }
    fatal("internal: slp: getOpcode of a min/max reduction kind");
    return .NONE_OP;
}
// getMinMaxReductionIntrinsicOp(RdxKind)
hr_kind_min_max_intrinsic :: (k: Hr_Rdx_Kind) -> Intrinsic_Id {
    if k == {
        case .SMAX; return IID_SMAX; case .SMIN; return IID_SMIN; case .UMAX; return IID_UMAX; case .UMIN; return IID_UMIN;
        case .FMAX; return IID_MAXNUM; case .FMIN; return IID_MINNUM; case .FMAXIMUM; return IID_MAXIMUM; case .FMINIMUM; return IID_MINIMUM;
    }
    fatal("internal: slp: getMinMaxReductionIntrinsicOp of a non-min/max kind");
    return NOT_INTRINSIC;
}

// HorizontalReduction::getReductionCost(TTI, ReducedVals, SameValuesCounter, IsCmpSelMinMax, FMF, R, DT, DL, TLI)
hr_get_reduction_cost :: (h: *Hr_Reduction, reduced: [] Value_Id, svc_keys: [] Value_Id, svc_cnts: [] u32, is_csmm: bool, fmf: u32) -> Cost {
    t := slp.tti;
    K :: TCK_RECIP_THROUGHPUT;
    sty := vtype(reduced[0]);
    redux := reduced.count;
    vec_ty := slp_reduction_type();
    vector_cost: Cost = 0;
    scalar_cost: Cost;
    all_consts := slp_all_constant(reduced);
    svc :: (keys: [] Value_Id, cnts: [] u32, v: Value_Id) -> u32 { for keys if it == v return cnts[it_index]; return 0; }
    get_reduction_op :: (h: *Hr_Reduction, v: Value_Id) -> Value_Id {
        p := hr_rv_ops_find(h, v);
        if p return p.*[0];
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u]; u = ir.u_next[u];
            if hr_get_rdx_kind(usr) == h.kind return usr;
        }
        return v;
    }
    // EvaluateScalarCost(GenCostFn): GenCostFn is the per-kind scalar op cost (gen_cost below)
    gen_cost :: (h: *Hr_Reduction, rdx_op: Value_Id, sty: Type_Id, fmf: u32) -> Cost {
        if hr_is_min_max_kind(h.kind) {
            id := hr_kind_min_max_intrinsic(h.kind);
            ica := ica_types(id, sty, .[sty, sty], fmf);
            return tti_intrinsic_cost(slp.tti, *ica, TCK_RECIP_THROUGHPUT);
        }
        return tti_arith_cost(slp.tti, hr_kind_opcode(h.kind), sty, TCK_RECIP_THROUGHPUT,
                              tti_operand_info(op(rdx_op, 0)), tti_operand_info(op(rdx_op, 1)), .[], rdx_op);
    }
    evaluate_scalar_cost :: (h: *Hr_Reduction, reduced: [] Value_Id, svc_keys: [] Value_Id, svc_cnts: [] u32, is_csmm: bool, sty: Type_Id, fmf: u32) -> Cost {
        cost: Cost = 0;
        cnt := reduced.count;
        for rdx_val: reduced {
            if !is_inst(rdx_val) continue;
            rdx_op := get_reduction_op(h, rdx_val);
            if cnt == 1 {
                sv := svc(svc_keys, svc_cnts, rdx_val);
                cost = cost_add(cost, cost_mul(cast(s64) (ifx sv != 0 then sv - 1 else 0), gen_cost(h, rdx_op, sty, fmf)));
                break;
            }
            cnt -= 1;
            if has_n_uses_or_more(rdx_val, ifx is_csmm then 3 else 2) {
                sv := svc(svc_keys, svc_cnts, rdx_val);
                cost = cost_add(cost, cost_mul(cast(s64) (ifx sv != 0 then sv else 1), gen_cost(h, rdx_op, sty, fmf)));
                continue;
            }
            sc: Cost = 0;
            u := ir.v_first_use[rdx_val];
            while u != NONE {
                ro := ir.u_user[u]; u = ir.u_next[u];
                if hr_has_required_number_of_uses(is_csmm, ro) {
                    if h.kind == .FADD {
                        a: [1] Value_Id; a[0] = ro;
                        fma := slp_can_convert_to_fma(a, slp_get_same_opcode(a));
                        if cost_valid(fma) {
                            fma = cost_sub(fma, tti_instruction_cost(slp.tti, rdx_val, TCK_RECIP_THROUGHPUT));
                            sc = cost_add(sc, fma);
                            continue;
                        }
                    }
                    sc = cost_add(sc, tti_instruction_cost(slp.tti, ro, TCK_RECIP_THROUGHPUT));
                    continue;
                }
                sc = COST_INVALID;
                break;
            }
            if cost_valid(sc) cost = cost_add(cost, sc);
            else cost = cost_add(cost, gen_cost(h, rdx_op, sty, fmf));
        }
        return cost;
    }
    does_require_reduction_op := !all_consts;   // VectorValuesAndScales is empty: nothing was vectorized before
    k := h.kind;
    if k == .ADD || k == .MUL || k == .OR || k == .AND || k == .XOR || k == .FADD || k == .FMUL {
        rdx_opc := hr_kind_opcode(k);
        if !all_consts {
            if is_vector_type(sty) slp_fail("REVEC reductions");
            red_ty := type_elem(vec_ty);
            has, rtype, signed := slp_root_node_type_with_no_cast();
            if !has { rtype = red_ty; signed = true; }
            if rtype == red_ty vector_cost = tti_arithmetic_reduction_cost(t, rdx_opc, vec_ty, true, fmf, K);
            else vector_cost = tti_extended_reduction_cost(t, rdx_opc, !signed, red_ty, slp_widened_type(rtype, cast(u64) redux), true, fmf, K);
        }
        scalar_cost = evaluate_scalar_cost(h, reduced, svc_keys, svc_cnts, is_csmm, sty, fmf);
    } else if hr_is_min_max_kind(k) && k != .FMINIMUMNUM && k != .FMAXIMUMNUM {
        id := hr_kind_min_max_intrinsic(k);
        if !all_consts vector_cost = tti_min_max_reduction_cost(t, id, vec_ty, fmf, K);
        scalar_cost = evaluate_scalar_cost(h, reduced, svc_keys, svc_cnts, is_csmm, sty, fmf);
    } else {
        fatal("internal: slp: expected arithmetic or min/max reduction operation");
    }
    #if DEBUG_SLP print("DBG reduction cost vec=% scalar=%\n", cost_to_string(vector_cost), cost_to_string(scalar_cost));
    return cost_sub(vector_cost, scalar_cost);
}
