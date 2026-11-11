// SLPVectorizer: HorizontalReduction (reduction matching and the reduction driver). Ported from
// llvm/lib/Transforms/Vectorize/SLPVectorizer.cpp (class HorizontalReduction: getRdxKind, isVectorizable,
// matchAssociativeReduction, matchOrderedReduction, matchReductionForOperands, optimizeReducedVals,
// tryToReduce, tryToReduceOrdered; generateKeySubkey, arePointersCompatible).
//
// The code generation of a profitable reduction (emitReduction, createSingleOp, createOp, emitScaleForReusedOps,
// emitReusedOps, the final reduction ops and their RAUW) is at the end of this file.
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
    // the reduction's own IRBuilder<TargetFolder>
    hb: Hr_Builder;
    irb_set_before(*hb.b, h.root);
    tracked: Table(Value_Id, Vh); tracked.allocator = temp;   // TrackedVals (WeakTrackingVH)
    any_bool_logic_op := false;
    for h.reduction_ops[h.reduction_ops.count - 1] if hr_is_bool_logic_op(it) { any_bool_logic_op = true; break; }
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
    for rv: h.reduced_vals for v: rv if !table_contains(*tracked, v) table_set(*tracked, v, vh_new(v));
    tv :: (t: *Table(Value_Id, Vh), v: Value_Id) -> Value_Id { found, x := table_find(t, v); if !found fatal("internal: slp: untracked reduced value"); return vh_get(x); }
    vectorized_vals_keys: [..] Value_Id; vectorized_vals_keys.allocator = temp;   // DenseMap<Value *, unsigned> VectorizedVals
    vectorized_vals_cnt: [..] u32; vectorized_vals_cnt.allocator = temp;
    vv_lookup :: (k: [] Value_Id, c: [] u32, v: Value_Id) -> u32 { for k if it == v return c[it_index]; return 0; }
    vv_slot :: (k: *[..] Value_Id, c: *[..] u32, v: Value_Id) -> *u32 {
        for k.* if it == v return *c.*[it_index];
        array_add(k, v); array_add(c, 0);
        return *c.*[c.count - 1];
    }
    required_extract: [..] Value_Id; required_extract.allocator = temp;
    vectorized_tree := vh_new(NONE);
    vvs: [..] Hr_Vvs; vvs.allocator = temp;                     // VectorValuesAndScales
    check_for_reused := false;
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
    e := h.reduced_vals.count;
    i := 0;
    while i < e {
        defer i += 1;
        orig := h.reduced_vals[i];
        s := states[i];
        candidates := hr_new_list();
        tracked_to_orig := hr_new_list();
        excluded := hr_new_list();
        for reduced_val: orig {
            rv := tv(*tracked, reduced_val);
            if is_inst(rv) && slp_is_deleted(rv) continue;
            if is_inst(rv) && slp_is_vector_like_inst_with_const_ops(rv) &&
               (!is_valid(s) || (is_matching_main_or_alt(s, rv) == NONE && !is_copyable_element(s, rv))) {
                array_add(*excluded, rv);
                continue;
            }
            if is_valid(s) && !is_inst(rv) && !pm_undef_value(rv) && !is_copyable_element(s, rv) continue;
            array_add(*candidates, rv);
            array_add(*tracked_to_orig, reduced_val);
        }
        shuffled_extracts := false;
        if is_valid(s) && is_opcode(s) == .EXTRACTELEMENT && !is_alt_shuffle(s) && i + 1 < e {
            common := vl_copy(candidates);
            for x: h.reduced_vals[i + 1] {
                rv := tv(*tracked, x);
                if !is_inst(rv) || inst_op(rv) != .EXTRACTELEMENT continue;
                array_add(*common, rv);
                array_add(*tracked_to_orig, x);
            }
            fixed := slp_is_fixed_vector_shuffle(common, slp.ac);
            if fixed {
                i += 1;
                candidates = common;
                shuffled_extracts = true;
            }
        }
        if candidates.count > 1 && slp_all_constant(candidates) {
            if h.rk == HR_ORDERED continue;
            res := candidates[0];
            vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, tracked_to_orig[0]).* += 1;
            for k: 1..candidates.count-1 {
                res = hr_create_op(h, *hb, res, candidates[k], "const.rdx");
                vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, tracked_to_orig[k]).* += 1;
                if is_inst(res) slp_analyzed_reduction_root(res);
            }
            vh_set(vectorized_tree, hr_new_vectorized_tree(h, *hb, vh_get(vectorized_tree), res, any_bool_logic_op));
            continue;
        }
        num_reduced := cast(u64) candidates.count;
        if num_reduced < h.reduction_limit && (num_reduced < 2 || !slp_is_splat(candidates)) continue;
        h.is_supported_identity_op = h.rk == HR_UNORDERED && h.kind != .MUL && h.kind != .FMUL && h.kind != .FMULADD;
        same_keys := hr_new_list();                                 // SmallMapVector<Value *, unsigned> SameValuesCounter
        same_cnts: [..] u32; same_cnts.allocator = temp;
        if h.is_supported_identity_op for v, idx: candidates vv_slot(*same_keys, *same_cnts, tracked_to_orig[idx]).* += 1;
        same_scale := false;
        opt_reused := h.is_supported_identity_op && same_keys.count != candidates.count;
        externally_used := vl_copy(excluded);                       // ExternallyUsedValues
        if opt_reused {
            same_scale = h.kind == .ADD || h.kind == .FADD || h.kind == .XOR;
            if same_scale for k: 1..same_cnts.count-1 if same_cnts[k] != same_cnts[0] { same_scale = false; break; }
            candidates = hr_new_list();
            for same_keys array_add(*candidates, tv(*tracked, it));
            tracked_to_orig = vl_copy(same_keys);
            num_reduced = cast(u64) candidates.count;
            if num_reduced == 1 {
                orig_v := tracked_to_orig[0];
                cnt := same_cnts[0];
                red_val := hr_emit_scale_for_reused_ops(h, *hb, candidates[0], cnt);
                vh_set(vectorized_tree, hr_new_vectorized_tree(h, *hb, vh_get(vectorized_tree), red_val, any_bool_logic_op));
                p := vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, orig_v);
                if p.* == 0 p.* = cnt;   // try_emplace (a fresh slot is 0; a count is never 0 here)
                set_add_v(*externally_used, orig_v);
                continue;
            }
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
        any_vectorized := false;
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
            local_ext := vl_copy(externally_used);
            set_add_v(*local_ext, h.root);
            for cnt: 0..h.reduced_vals.count-1 {
                if cnt == i || (shuffled_extracts && cnt == i - 1) continue;
                for v: h.reduced_vals[cnt] if is_inst(v) set_add_v(*local_ext, tv(*tracked, v));
            }
            if !h.is_supported_identity_op {
                for cnt: 0..cast(s64) num_reduced - 1 {
                    if cast(u64) cnt >= pos && cast(u64) cnt < pos + redux continue;
                    vv_slot(*same_keys, *same_cnts, tracked_to_orig[cnt]).* += 1;
                }
            }
            slp_transform_nodes();
            slp_compute_minimum_value_sizes();
            tree_cost := slp_calculate_tree_cost_and_trim_non_profitable(vl);
            {
                visited := hr_new_list();
                for cnt: 0..cast(s64) num_reduced - 1 {
                    if cast(u64) cnt >= pos && cast(u64) cnt < pos + redux continue;
                    rdx := tv(*tracked, candidates[cnt]);
                    if slp_has(visited, rdx) continue;
                    array_add(*visited, rdx);
                    if !slp_has(vl, rdx) && slp_is_vectorized(rdx) { set_add_v(*local_ext, rdx); continue; }
                    orig_v := tracked_to_orig[cnt];
                    num_ops := vv_lookup(vectorized_vals_keys, vectorized_vals_cnt, orig_v) + vv_lookup(same_keys, same_cnts, orig_v);
                    rops := hr_rv_ops_find(h, orig_v);
                    if !rops fatal("internal: slp: reduced value without reduction ops");
                    if cast(s64) num_ops != rops.count set_add_v(*local_ext, rdx);
                }
            }
            if !h.is_supported_identity_op { array_reset_keeping_memory(*same_keys); array_reset_keeping_memory(*same_cnts); }
            for rdx: vl if slp_has(required_extract, rdx) set_add_v(*local_ext, rdx);
            slp_build_external_uses(local_ext);
            reduction_cost: Cost = 0;
            if !(h.rk == HR_ORDERED || slp_is_reduced_bitcast_root() || slp_is_reduced_cmp_bitcast_root())
                reduction_cost = hr_get_reduction_cost(h, vl, same_keys, same_cnts, is_csmm, rdx_fmf, vvs.count);
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
            // vectorize the tree
            hb.fmf = rdx_fmf;
            vvs_vals: [..] Value_Id; vvs_vals.allocator = temp;
            for vvs array_add(*vvs_vals, vh_get(it.vec));
            vectorized_root := slp_vectorize_tree_full(insert_pt, vvs_vals);
            if h.rk == HR_ORDERED {
                for rdx: vl vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, rdx).* += 1;
                pos += redux;
                start = pos;
                redux = num_reduced - pos;
                if redux > 1 redux = hr_vector_factor(sty, num_reduced - pos);
                any_vectorized = true;
                vh_set(vectorized_tree, h.root);
                continue;
            }
            irb_set_before(*hb.b, insert_pt);
            if any_bool_logic_op && !is_guaranteed_not_to_be_poison(vectorized_root, slp.ac) vectorized_root = hrb_freeze(*hb, vectorized_root);
            if opt_reused && !same_scale {
                root_vl := slp.entries[0].scalars;
                root_tracked_to_orig := NewArray(root_vl.count, Value_Id,, temp);
                for val, idx: array_view(candidates, cast(s64) pos, cast(s64) redux)
                    root_tracked_to_orig[te_find_lane_for_value(0, val)] = tracked_to_orig[cast(s64) pos + idx];
                vectorized_root = hr_emit_reused_ops(h, *hb, vectorized_root, same_keys, same_cnts, root_tracked_to_orig);
            }
            st := vtype(vl[0]);
            red_sty := scalar_type(vtype(vectorized_root));
            x: Hr_Vvs;
            x.vec = vh_new(vectorized_root);
            x.scale = ifx opt_reused && same_scale then same_cnts[0] else 1;
            x.is_signed = ifx red_sty != scalar_type(st) then slp_is_signed_min_bitwidth_root_node() else true;
            x.reduced_in_tree = slp_is_reduced_bitcast_root() || slp_is_reduced_cmp_bitcast_root();
            array_add(*vvs, x);
            for rdx, idx: vl {
                orig_v := tracked_to_orig[cast(s64) pos + idx];
                if h.is_supported_identity_op {
                    p := vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, orig_v);
                    if p.* == 0 p.* = vv_lookup(same_keys, same_cnts, orig_v);   // try_emplace
                    continue;
                }
                vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, orig_v).* += 1;
                if !slp_is_vectorized(rdx) set_add_v(*required_extract, rdx);
            }
            pos += redux;
            start = pos;
            redux = num_reduced - pos;
            if redux > 1 redux = hr_vector_factor(sty, num_reduced - pos);
            any_vectorized = true;
        }
        if opt_reused && !any_vectorized {
            for k, idx: same_keys {
                rdx_val := tv(*tracked, k);
                red_val := hr_emit_scale_for_reused_ops(h, *hb, rdx_val, same_cnts[idx]);
                vh_set(vectorized_tree, hr_new_vectorized_tree(h, *hb, vh_get(vectorized_tree), red_val, any_bool_logic_op));
                p := vv_slot(*vectorized_vals_keys, *vectorized_vals_cnt, k);
                if p.* == 0 p.* = same_cnts[idx];
            }
            continue;
        }
    }
    if h.rk == HR_ORDERED return vh_get(vectorized_tree);
    if vvs.count vh_set(vectorized_tree, hr_new_vectorized_tree(h, *hb, vh_get(vectorized_tree), hr_emit_reduction_all(h, *hb, vvs, vtype(h.root)), any_bool_logic_op));
    if vh_get(vectorized_tree) == NONE {
        if !check_for_reused hr_mark_ops_analyzed(h);
        return NONE;
    }
    // finish the reduction: the extra (not vectorized) reduced values
    Inst_Val :: struct { i: Value_Id; v: Value_Id; }
    extra: [..] Inst_Val; extra.allocator = temp;
    array_add(*extra, .{h.root, vh_get(vectorized_tree)});
    visited := hr_new_list();
    for cands: h.reduced_vals for rdx: cands {
        if slp_has(visited, rdx) continue;
        array_add(*visited, rdx);
        num_ops := vv_lookup(vectorized_vals_keys, vectorized_vals_cnt, rdx);
        ops := hr_rv_ops_find(h, rdx);
        if !ops fatal("internal: slp: reduced value without reduction ops");
        for k: 0..ops.count - cast(s64) num_ops - 1 array_add(*extra, .{ops.*[k], rdx});
    }
    vt_final := vh_get(vectorized_tree);
    init_step := true;
    while extra.count > 1 {
        sz := extra.count;
        new_reds: [..] Inst_Val; new_reds.allocator = temp;
        array_resize(*new_reds, sz / 2 + sz % 2);
        k := 0;
        while k < (sz / 2) * 2 {
            red_op := extra[k + 1].i;
            hb.b.dbg = get_metadata(red_op, 0);
            v1 := extra[k].v;
            s1 := v1;
            found1, t1 := table_find(*tracked, v1);
            if found1 s1 = vh_get(t1);
            v2 := extra[k + 1].v;
            s2 := v2;
            found2, t2 := table_find(*tracked, v2);
            if found2 s2 = vh_get(t2);
            hr_fix_bool_logical_ops(h, *hb, *s1, *s2, extra[k].i, red_op, init_step, any_bool_logic_op, vt_final);
            r := hr_create_op(h, *hb, s1, s2, "op.rdx");
            new_reds[k / 2] = .{extra[k].i, r};
            k += 2;
        }
        if sz % 2 == 1 new_reds[sz / 2] = extra[sz - 1];
        extra = new_reds;
        init_step = false;
    }
    result := extra[0].v;
    replace_all_uses_with(h.root, result);
    vvs_vals: [..] Value_Id; vvs_vals.allocator = temp;
    for vvs array_add(*vvs_vals, vh_get(it.vec));
    for rdx_ops: h.reduction_ops {
        for ign: rdx_ops {
            if ign == NONE continue;
            if has_uses(ign) replace_all_uses_with(ign, const_poison(vtype(ign)));
        }
        slp_remove_instructions_and_operands(rdx_ops, vvs_vals);
    }
    return result;
}

// tryToReduceOrdered(V, DL, TTI, TLI, AC, DT)
hr_try_to_reduce_ordered :: (h: *Hr_Reduction) -> Value_Id {
    REG_MAX_NUMBER :: 4;
    RED_VALS_MAX_NUMBER :: 128;
    hb: Hr_Builder;
    irb_set_before(*hb.b, h.root);
    tracked: Table(Value_Id, Vh); tracked.allocator = temp;
    for rv: h.reduced_vals for v: rv if !table_contains(*tracked, v) table_set(*tracked, v, vh_new(v));
    tv :: (t: *Table(Value_Id, Vh), v: Value_Id) -> Value_Id { found, x := table_find(t, v); if !found fatal("internal: slp: untracked reduced value"); return vh_get(x); }
    candidates := vl_copy(h.reduced_vals[h.reduced_vals.count - 1]);
    rdx_fmf: u32 = FMF_ALL;
    for c: candidates { p := hr_rv_ops_find(h, c); if p for o: p.* if is_fp_math_inst(o) rdx_fmf &= inst_fmf(o); }
    rdx_fmf &= ~cast(u32) FMF_REASSOC;
    max_elts := clamp(bit_floor(slp.max_vec_reg_size / slp_get_vector_element_size(candidates[0])), RED_VALS_MAX_NUMBER, REG_MAX_NUMBER * RED_VALS_MAX_NUMBER);
    sty := vtype(candidates[0]);
    success_start: u64 = 0; success_width: u64 = 0;
    success_root: Value_Id = NONE;
    try_window :: (h: *Hr_Reduction, hb: *Hr_Builder, candidates: [] Value_Id, start: u64, width: u64, rdx_fmf: u32, success_root: *Value_Id) -> bool {
        vl := array_view(candidates, cast(s64) start, cast(s64) width);
        if slp_are_analyzed_reduction_vals(vl) return false;
        for vl if is_inst(it) && slp_is_deleted(it) return false;
        ignore_list: [..] Value_Id; ignore_list.allocator = temp;
        for l: h.reduction_ops for l if it != NONE && !slp_has(ignore_list, it) array_add(*ignore_list, it);
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
        reduction_cost := hr_get_reduction_cost(h, vl, .[], .[], false, rdx_fmf, 0);
        cost := slp_get_tree_cost(tree_cost, vl, reduction_cost, h.root);
        #if DEBUG_SLP print("SLP: Found cost = % for ordered reduction\n", cost_to_string(cost));
        if cost > -slp_cl.threshold { slp_analyzed_reduction_vals(vl); return false; }
        hb.fmf = rdx_fmf;
        success_root.* = slp_vectorize_tree_full(h.root, .[]);
        return true;
    }
    n := cast(u64) candidates.count;
    redux := n;
    if !slp_cl.non_power_of_2 || !has_single_bit(redux + 1) redux = hr_vector_factor(sty, redux);
    redux = min(redux, max_elts);
    while redux >= h.reduction_limit {
        if try_window(h, *hb, candidates, 0, redux, rdx_fmf, *success_root) { success_start = 0; success_width = redux; break; }
        back_start := n - redux;
        if back_start != 0 && try_window(h, *hb, candidates, back_start, redux, rdx_fmf, *success_root) { success_start = back_start; success_width = redux; break; }
        redux -= 1;
        if redux > 1 redux = hr_vector_factor(sty, redux);
    }
    if success_root == NONE {
        hr_mark_ops_analyzed(h);
        return NONE;
    }
    dest_ty := vtype(h.root);
    vectorized_tree := vh_new(NONE);
    for k: 0..cast(s64) success_start - 1 {
        rdx := candidates[k];
        hb.b.dbg = get_metadata(hr_rv_ops_find(h, rdx).*[0], 0);
        if vh_get(vectorized_tree) == NONE vh_set(vectorized_tree, tv(*tracked, rdx));
        else vh_set(vectorized_tree, hr_create_op(h, *hb, vh_get(vectorized_tree), tv(*tracked, rdx), "op.rdx"));
    }
    hb.b.dbg = get_metadata(h.root, 0);
    vh_set(vectorized_tree, hr_create_single_op(h, *hb, success_root, 1, false, dest_ty, false, vh_get(vectorized_tree)));
    for k: cast(s64) (success_start + success_width)..candidates.count-1 {
        rdx := candidates[k];
        hb.b.dbg = get_metadata(hr_rv_ops_find(h, rdx).*[0], 0);
        vh_set(vectorized_tree, hr_create_op(h, *hb, vh_get(vectorized_tree), tv(*tracked, rdx), "op.rdx"));
    }
    result := vh_get(vectorized_tree);
    replace_all_uses_with(h.root, result);
    for rdx_ops: h.reduction_ops {
        for ign: rdx_ops {
            if ign == NONE continue;
            if has_uses(ign) replace_all_uses_with(ign, const_poison(vtype(ign)));
        }
        slp_remove_instructions_and_operands(rdx_ops, .[]);
    }
    return result;
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
hr_get_reduction_cost :: (h: *Hr_Reduction, reduced: [] Value_Id, svc_keys: [] Value_Id, svc_cnts: [] u32, is_csmm: bool, fmf: u32, num_vvs: s64) -> Cost {
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
    does_require_reduction_op := !all_consts && num_vvs == 0;
    k := h.kind;
    if k == .ADD || k == .MUL || k == .OR || k == .AND || k == .XOR || k == .FADD || k == .FMUL {
        rdx_opc := hr_kind_opcode(k);
        if !all_consts {
            if is_vector_type(sty) slp_fail("REVEC reductions");
            red_ty := type_elem(vec_ty);
            has, rtype, signed := slp_root_node_type_with_no_cast();
            if !has { rtype = red_ty; signed = true; }
            if does_require_reduction_op {
                if rtype == red_ty vector_cost = tti_arithmetic_reduction_cost(t, rdx_opc, vec_ty, true, fmf, K);
                else vector_cost = tti_extended_reduction_cost(t, rdx_opc, !signed, red_ty, slp_widened_type(rtype, cast(u64) redux), true, fmf, K);
            } else {
                rvec_ty := slp_widened_type(rtype, cast(u64) redux);
                fma_cost := COST_INVALID;
                if k == .FADD {
                    ops := hr_new_list();
                    ffmf: u32 = FMF_ALL;
                    for rv: reduced {
                        if !has_one_use(rv) { array_reset_keeping_memory(*ops); break; }
                        if is_inst(rv) && is_fp_math_inst(rv) ffmf &= inst_fmf(rv);
                        array_add(*ops, first_user(rv));
                    }
                    if ops.count {
                        fma_cost = slp_can_convert_to_fma(ops, slp_get_same_opcode(ops));
                        if cost_valid(fma_cost) {
                            ica := ica_types(IID_FMULADD, rvec_ty, .[rvec_ty, rvec_ty, rvec_ty], ffmf);
                            fma_cost = tti_intrinsic_cost(t, *ica, K);
                            fma_cost = cost_sub(fma_cost, tti_arith_cost(t, .FMUL, rvec_ty, K));
                        }
                    }
                }
                if cost_valid(fma_cost) vector_cost = cost_add(vector_cost, fma_cost);
                else vector_cost = cost_add(vector_cost, tti_arith_cost(t, rdx_opc, rvec_ty, K));
                if rtype != red_ty {
                    opc: Opcode = .TRUNC;
                    if type_bits(scalar_type(red_ty)) > type_bits(scalar_type(rtype)) opc = ifx signed then .SEXT else .ZEXT;
                    vector_cost = cost_add(vector_cost, tti_cast_cost(t, opc, vec_ty, rvec_ty, CCH_NONE, K));
                }
            }
        }
        scalar_cost = evaluate_scalar_cost(h, reduced, svc_keys, svc_cnts, is_csmm, sty, fmf);
    } else if hr_is_min_max_kind(k) && k != .FMINIMUMNUM && k != .FMAXIMUMNUM {
        id := hr_kind_min_max_intrinsic(k);
        if !all_consts {
            if does_require_reduction_op vector_cost = tti_min_max_reduction_cost(t, id, vec_ty, fmf, K);
            else {
                red_ty := type_elem(vec_ty);
                has, rtype, signed := slp_root_node_type_with_no_cast();
                if !has { rtype = red_ty; signed = true; }
                rvec_ty := slp_widened_type(rtype, cast(u64) redux);
                ica := ica_types(id, rvec_ty, .[rvec_ty, rvec_ty], fmf);
                vector_cost = cost_add(vector_cost, tti_intrinsic_cost(t, *ica, K));
                if rtype != red_ty {
                    opc: Opcode = .TRUNC;
                    if type_bits(scalar_type(red_ty)) > type_bits(scalar_type(rtype)) opc = ifx signed then .SEXT else .ZEXT;
                    vector_cost = cost_add(vector_cost, tti_cast_cost(t, opc, vec_ty, rvec_ty, CCH_NONE, K));
                }
            }
        }
        scalar_cost = evaluate_scalar_cost(h, reduced, svc_keys, svc_cnts, is_csmm, sty, fmf);
    } else {
        fatal("internal: slp: expected arithmetic or min/max reduction operation");
    }
    #if DEBUG_SLP print("DBG reduction cost vec=% scalar=%\n", cost_to_string(vector_cost), cost_to_string(scalar_cost));
    return cost_sub(vector_cost, scalar_cost);
}

// ---------------------------------------------------------------- the reduction's code generation

// tryToReduce's IRBuilder<TargetFolder> (with the fast-math flags setFastMathFlags gives it)
Hr_Builder :: struct { b: Irb; fmf: u32; }
// VectorValuesAndScales: (WeakTrackingVH, scale, is signed, reduced in tree)
Hr_Vvs :: struct { vec: Vh; scale: u32; is_signed: bool; reduced_in_tree: bool; }

// make the sgb_* calls use the reduction's builder for the rest of the caller's scope
hrb_use :: (hb: *Hr_Builder) #expand {
    `__saved_cb := slpg.cb; `__saved_fmf := slpg.cfmf;
    slpg.cb = *hb.b; slpg.cfmf = hb.fmf;
    `defer { slpg.cb = __saved_cb; slpg.cfmf = __saved_fmf; }
}
hrb_freeze :: (hb: *Hr_Builder, v: Value_Id) -> Value_Id { hrb_use(hb); return sgb_freeze(v); }

slp_const_int_splat :: (t: Type_Id, n: u64) -> Value_Id {
    if is_vector_type(t) return cf_get_splat(t, const_int(type_elem(t), n));
    return const_int(t, n);
}
slp_const_fp_splat :: (t: Type_Id, n: s64) -> Value_Id {
    if is_vector_type(t) return cf_get_splat(t, fp_const(type_elem(t), n));
    return fp_const(t, n);
}

// isSignedMinBitwidthRootNode()
slp_is_signed_min_bitwidth_root_node :: () -> bool {
    found, bw := slp_min_bw_of(0);
    if !found fatal("internal: slp: the root node has no minimum bit width");
    return bw.signed;
}

// getMinMaxReductionPredicate(Kind)
hr_min_max_predicate :: (k: Hr_Rdx_Kind) -> u8 {
    if k == {
        case .SMAX; return ICMP_SGT; case .SMIN; return ICMP_SLT; case .UMAX; return ICMP_UGT; case .UMIN; return ICMP_ULT;
    }
    fatal("internal: slp: not an integer min/max reduction kind");
    return 0;
}

// createOp(Builder, Kind, LHS, RHS, Name, UseSelect)
hr_create_basic_op :: (k: Hr_Rdx_Kind, l: Value_Id, r: Value_Id, name: string, use_select: bool) -> Value_Id {
    ty := vtype(l);
    if k == {
    case .OR;
        if use_select && ty == make_cmp_result_type(ty) return sgb_select_unknown_profile(l, cf_all_ones(make_cmp_result_type(ty)), r, name);
        return sgb_binop(.OR, l, r, name);
    case .AND;
        if use_select && ty == make_cmp_result_type(ty) return sgb_select_unknown_profile(l, r, const_null_value(make_cmp_result_type(ty)), name);
        return sgb_binop(.AND, l, r, name);
    case .ADD; #through; case .MUL; #through; case .XOR; #through; case .FADD; #through; case .FMUL;
        return sgb_binop(hr_kind_opcode(k), l, r, name);
    case .SMAX; #through; case .SMIN; #through; case .UMAX; #through; case .UMIN;
        if use_select {
            c := sgb_cmp(hr_min_max_predicate(k), l, r, name);
            return sgb_select_unknown_profile(c, l, r, name);
        }
    }
    if hr_is_min_max_kind(k) {
        id := hr_kind_min_max_intrinsic(k);
        if is_const(l) && is_const(r) {   // TargetFolder::FoldIntrinsic
            if is_vector_type(ty) slp_fail("constant folding of vector min/max intrinsics");
            x := cfo_intrinsic(id, .[l, r], ty);
            if x != NONE return x;
        }
        f := get_or_insert_intrinsic_declaration(id, .[ty]);
        fty := glob(f).value_type;
        c := new_inst(.CALL, func_ret(fty), 3);
        inst(c).ty2 = fty;
        set_op(c, 0, l); set_op(c, 1, r); set_op(c, 2, f);
        return sgb_insert(c);
    }
    fatal("internal: slp: unknown reduction operation");
    return NONE;
}

// createOp(Builder, RdxKind, LHS, RHS, Name, ReductionOps): the IR flags of the reduction ops, without nuw/nsw
hr_create_op :: (h: *Hr_Reduction, hb: *Hr_Builder, l: Value_Id, r: Value_Id, name: string) -> Value_Id {
    hrb_use(hb);
    ops := h.reduction_ops;
    use_select := ops.count == 2;
    if !use_select && ops.count == 1 for ops[0] if is_inst(it) && inst_op(it) == .SELECT { use_select = true; break; }
    o := hr_create_basic_op(h.kind, l, r, name, use_select);
    if hr_is_int_min_max_kind(h.kind) && is_inst(o) && inst_op(o) == .SELECT {
        slp_propagate_ir_flags(op(o, 0), ops[0], false);
        slp_propagate_ir_flags(o, ops[1], false);
        return o;
    }
    slp_propagate_ir_flags(o, ops[0], false);
    return o;
}

// the GetNewVectorizedTree lambda of tryToReduce
hr_new_vectorized_tree :: (h: *Hr_Reduction, hb: *Hr_Builder, vt_in: Value_Id, res_in: Value_Id, any_bool_logic_op: bool) -> Value_Id {
    vt := vt_in; res := res_in;
    if vt == NONE return res;
    hb.b.dbg = get_metadata(h.reduction_ops[0][0], 0);
    if any_bool_logic_op {
        it := hr_rv_ops_find(h, vt);
        it1 := hr_rv_ops_find(h, res);
        any_first :: (l: *[..] Value_Id, x: Value_Id) -> bool {
            if !l return false;
            for l.* if hr_is_bool_logic_op(it) && hr_rdx_operand(it, 0) == x return true;
            return false;
        }
        if (!it && !it1) || is_guaranteed_not_to_be_poison(vt, slp.ac) || any_first(it, vt) {
        } else if is_guaranteed_not_to_be_poison(res, slp.ac) || any_first(it1, res) {
            t := vt; vt = res; res = t;
        } else {
            vt = hrb_freeze(hb, vt);
        }
    }
    return hr_create_op(h, hb, vt, res, "op.rdx");
}

// the FixBoolLogicalOps lambda of tryToReduce (`vt` is the VectorizedTree it captured)
hr_fix_bool_logical_ops :: (h: *Hr_Reduction, hb: *Hr_Builder, lhs: *Value_Id, rhs: *Value_Id, red_op1: Value_Id, red_op2: Value_Id, init_step: bool,
                            any_bool_logic_op: bool, vt: Value_Id) {
    if !any_bool_logic_op return;
    if hr_is_bool_logic_op(red_op1) && ((!init_step && lhs.* == vt) || hr_rdx_operand(red_op1, 0) == lhs.* || is_guaranteed_not_to_be_poison(lhs.*, slp.ac)) return;
    need_freeze := lhs.* != vt;
    if hr_is_bool_logic_op(red_op2) && ((!init_step && rhs.* == vt) || hr_rdx_operand(red_op2, 0) == rhs.* || is_guaranteed_not_to_be_poison(rhs.*, slp.ac)) {
        c := (init_step || rhs.* != vt) && hr_rdx_operand(red_op2, 0) == rhs.*;
        if c {
            c2 := hr_is_bool_logic_op(red_op1) && hr_rdx_operand(red_op1, 1) == red_op2;
            if !c2 for l: h.reduction_ops for o: l if is_inst(o) && hr_is_bool_logic_op(o) && hr_rdx_operand(o, 1) == red_op2 { c2 = true; break; }
            c = c2;
        }
        if c need_freeze = false;
        else { t := lhs.*; lhs.* = rhs.*; rhs.* = t; return; }
    }
    if need_freeze lhs.* = hrb_freeze(hb, lhs.*);
}

// emitScaleForReusedOps(VectorizedValue, Builder, Cnt)
hr_emit_scale_for_reused_ops :: (h: *Hr_Reduction, hb: *Hr_Builder, v: Value_Id, cnt: u32) -> Value_Id {
    hrb_use(hb);
    if cnt == 1 return v;
    if h.kind == {
        case .ADD; return sgb_binop(.MUL, v, slp_const_int_splat(vtype(v), cnt));
        case .XOR; if cnt % 2 == 0 return const_null_value(vtype(v)); return v;
        case .FADD; return sgb_binop(.FMUL, v, slp_const_fp_splat(vtype(v), cast(s64) cnt));
        case .AND; #through; case .OR; #through; case .SMAX; #through; case .SMIN; #through; case .UMAX; #through; case .UMIN; #through;
        case .FMAX; #through; case .FMIN; #through; case .FMAXIMUM; #through; case .FMINIMUM; return v;
    }
    fatal("internal: slp: unexpected reduction kind for a repeated scalar");
    return NONE;
}

// emitReusedOps(VectorizedValue, Builder, R, SameValuesCounter, TrackedToOrig)
hr_emit_reused_ops :: (h: *Hr_Reduction, hb: *Hr_Builder, v_in: Value_Id, svc_keys: [] Value_Id, svc_cnts: [] u32, tracked_to_orig: [] Value_Id) -> Value_Id {
    hrb_use(hb);
    v := v_in;
    vl := slp.entries[0].scalars;
    if type_elem(vtype(v)) != vtype(vl[0]) v = sgb_int_cast(v, slp_widened_type(vtype(vl[0]), type_count(vtype(v))), slp_is_signed_min_bitwidth_root_node());
    lookup :: (k: [] Value_Id, c: [] u32, x: Value_Id) -> u32 { for k if it == x return c[it_index]; return 0; }
    if h.kind == {
    case .ADD;
        vals: [..] Value_Id; vals.allocator = temp;
        for x, idx: vl array_add(*vals, const_int(vtype(x), lookup(svc_keys, svc_cnts, tracked_to_orig[idx])));
        return sgb_binop(.MUL, v, const_vector_of(vals));
    case .AND; #through; case .OR; #through; case .SMAX; #through; case .SMIN; #through; case .UMAX; #through; case .UMIN; #through;
    case .FMAX; #through; case .FMIN; #through; case .FMAXIMUM; #through; case .FMINIMUM;
        return v;
    case .XOR;
        n := cast(s64) type_count(vtype(v));
        mask := new_mask(n);
        for * mask it.* = cast(s32) it_index;
        need := false;
        for x, idx: vl if lookup(svc_keys, svc_cnts, tracked_to_orig[idx]) % 2 == 0 { mask[idx] = cast(s32) vl.count; need = true; }
        if need v = sgb_shuffle(v, const_null_value(vtype(v)), mask);
        return v;
    case .FADD;
        vals: [..] Value_Id; vals.allocator = temp;
        for x, idx: vl array_add(*vals, fp_const(vtype(x), cast(s64) lookup(svc_keys, svc_cnts, tracked_to_orig[idx])));
        return sgb_binop(.FMUL, v, const_vector_of(vals));
    }
    fatal("internal: slp: unexpected reduction kind for reused scalars");
    return NONE;
}

// getReductionIntrinsicID(RdxKind)
hr_reduction_intrinsic :: (k: Hr_Rdx_Kind) -> Intrinsic_Id {
    if k == {
        case .ADD; return IID_VECTOR_REDUCE_ADD; case .MUL; return IID_VECTOR_REDUCE_MUL; case .AND; return IID_VECTOR_REDUCE_AND;
        case .OR; return IID_VECTOR_REDUCE_OR; case .XOR; return IID_VECTOR_REDUCE_XOR; case .SMAX; return IID_VECTOR_REDUCE_SMAX;
        case .SMIN; return IID_VECTOR_REDUCE_SMIN; case .UMAX; return IID_VECTOR_REDUCE_UMAX; case .UMIN; return IID_VECTOR_REDUCE_UMIN;
        case .FMAX; return IID_VECTOR_REDUCE_FMAX; case .FMIN; return IID_VECTOR_REDUCE_FMIN; case .FMAXIMUM; return IID_VECTOR_REDUCE_FMAXIMUM;
        case .FMINIMUM; return IID_VECTOR_REDUCE_FMINIMUM; case .FADD; return IID_VECTOR_REDUCE_FADD; case .FMUL; return IID_VECTOR_REDUCE_FMUL;
    }
    fatal("internal: slp: unhandled reduction kind");
    return NOT_INTRINSIC;
}
// CreateIntrinsic(ID, {OverloadTy}, Args) through createCallHelper (no constant folding of reductions here)
hr_intrinsic_call :: (id: Intrinsic_Id, oty: Type_Id, args: [] Value_Id) -> Value_Id {
    all_const := true; for args if !is_const(it) { all_const = false; break; }
    f := get_or_insert_intrinsic_declaration(id, .[oty]);
    fty := glob(f).value_type;
    if all_const {   // TargetFolder::FoldIntrinsic (ConstantFoldIntrinsic)
        rt := func_ret(fty);
        if is_vector_type(rt) slp_fail("constant folding of vector-typed intrinsics");
        x := cfo_intrinsic(id, args, rt);
        if x != NONE return x;
    }
    c := new_inst(.CALL, func_ret(fty), cast(u32) (args.count + 1));
    inst(c).ty2 = fty;
    for args set_op(c, cast(u32) it_index, it);
    set_op(c, cast(u32) args.count, f);
    return sgb_insert(c);
}

// emitReduction(VectorizedValue, Builder, TTI, DestTy, Start)
hr_emit_reduction :: (h: *Hr_Reduction, hb: *Hr_Builder, v: Value_Id, dest_ty: Type_Id, start: Value_Id = NONE) -> Value_Id {
    hrb_use(hb);
    fty := vtype(v);
    if start == NONE && type_elem(fty) == ir.t_i1 && h.kind == .ADD && scalar_type(dest_ty) != type_elem(fty) {
        x := sgb_cast(.BITCAST, v, type_int(cast(u32) type_count(fty)));
        return hr_intrinsic_call(IID_CTPOP, vtype(x), .[x]);
    }
    if start != NONE return hr_intrinsic_call(IID_VECTOR_REDUCE_FADD, fty, .[start, v]);
    k := h.kind;
    elt := type_elem(fty);
    if k == .FADD return hr_intrinsic_call(IID_VECTOR_REDUCE_FADD, fty, .[const_fp_words(elt, fp_zero(type_kind(elt), (hb.fmf & FMF_NSZ) == 0)), v]);
    if k == .FMUL return hr_intrinsic_call(IID_VECTOR_REDUCE_FMUL, fty, .[fp_const(elt, 1), v]);
    return hr_intrinsic_call(hr_reduction_intrinsic(k), fty, .[v]);
}

// createSingleOp(Builder, TTI, Vec, Scale, IsSigned, DestTy, ReducedInTree, Start)
hr_create_single_op :: (h: *Hr_Reduction, hb: *Hr_Builder, vec: Value_Id, scale: u32, is_signed: bool, dest_ty: Type_Id, reduced_in_tree: bool, start: Value_Id = NONE) -> Value_Id {
    rdx: Value_Id;
    if reduced_in_tree rdx = vec;
    else {
        if is_vector_type(dest_ty) slp_fail("REVEC reductions");
        rdx = hr_emit_reduction(h, hb, vec, dest_ty, start);
    }
    if vtype(rdx) != dest_ty { hrb_use(hb); rdx = sgb_int_cast(rdx, dest_ty, is_signed); }
    if scale > 1 rdx = hr_emit_scale_for_reused_ops(h, hb, rdx, scale);
    return rdx;
}

// emitReduction(Builder, TTI, DestTy): combines VectorValuesAndScales
hr_emit_reduction_all :: (h: *Hr_Reduction, hb: *Hr_Builder, vvs: [] Hr_Vvs, dest_ty: Type_Id) -> Value_Id {
    reduced_sub_tree: Value_Id = NONE;
    create_single :: (h: *Hr_Reduction, hb: *Hr_Builder, rst: *Value_Id, vec: Value_Id, scale: u32, is_signed: bool, rit: bool, dest_ty: Type_Id) {
        rdx := hr_create_single_op(h, hb, vec, scale, is_signed, dest_ty, rit);
        if rst.* != NONE rst.* = hr_create_op(h, hb, rst.*, rdx, "op.rdx");
        else rst.* = rdx;
    }
    if vvs.count == 1 {
        x := vvs[0];
        create_single(h, hb, *reduced_sub_tree, vh_get(x.vec), x.scale, x.is_signed, x.reduced_in_tree, dest_ty);
        return reduced_sub_tree;
    }
    vec_res: Value_Id = NONE;
    vec_res_signed := false;
    for x: vvs {
        vec := vh_get(x.vec);
        cnt := x.scale;
        if x.reduced_in_tree { create_single(h, hb, *reduced_sub_tree, vec, cnt, x.is_signed, true, dest_ty); continue; }
        hrb_use(hb);
        sty := scalar_type(vtype(vec));
        if cnt > 1 {
            if h.kind == {
            case .ADD;
                if sty == ir.t_i1 && sty != dest_ty {
                    vf := cast(s64) type_count(vtype(vec));
                    m := new_mask(cast(s64) cnt * vf);
                    for k: 0..cast(s64) cnt - 1 for j: 0..vf-1 m[vf * k + j] = cast(s32) j;
                    vec = sgb_shuffle(vec, NONE, m);
                } else {
                    if sty != scalar_type(dest_ty) vec = sgb_int_cast(vec, slp_widened_type(dest_ty, type_count(vtype(vec))), x.is_signed);
                    vec = sgb_binop(.MUL, vec, cf_get_splat(vtype(vec), const_int(scalar_type(dest_ty), cnt)));
                }
            case .XOR; if cnt % 2 == 0 vec = const_null_value(vtype(vec));
            case .FADD; vec = sgb_binop(.FMUL, vec, cf_get_splat(vtype(vec), fp_const(sty, cast(s64) cnt)));
            case .AND; #through; case .OR; #through; case .SMAX; #through; case .SMIN; #through; case .UMAX; #through; case .UMIN; #through;
            case .FMAX; #through; case .FMIN; #through; case .FMAXIMUM; #through; case .FMINIMUM;
            case; fatal("internal: slp: unexpected reduction kind for a repeated scalar");
            }
        }
        if vec_res == NONE { vec_res = vec; vec_res_signed = x.is_signed; continue; }
        if sty == ir.t_i1 && sty != dest_ty && scalar_type(vtype(vec_res)) == ir.t_i1 {
            vrvf := cast(s64) type_count(vtype(vec_res)); vvf := cast(s64) type_count(vtype(vec));
            m := new_mask(vrvf + vvf);
            for * m it.* = cast(s32) it_index;
            if vrvf < vvf { t := vec_res; vec_res = vec; vec = t; t2 := vrvf; vrvf = vvf; vvf = t2; }
            if vrvf != vvf {
                rm := new_mask(vrvf);
                for k: 0..vvf-1 rm[k] = cast(s32) k;
                vec = sgb_shuffle(vec, NONE, rm);
            }
            vec_res = sgb_shuffle(vec_res, vec, m, "rdx.op");
            continue;
        }
        if scalar_type(vtype(vec_res)) != scalar_type(dest_ty)
            vec_res = sgb_int_cast(vec_res, slp_widened_type(scalar_type(dest_ty), type_count(vtype(vec_res))), vec_res_signed);
        if sty != scalar_type(dest_ty)
            vec = sgb_int_cast(vec, slp_widened_type(scalar_type(dest_ty), type_count(vtype(vec))), x.is_signed);
        vrvf := cast(s64) type_count(vtype(vec_res)); vvf := cast(s64) type_count(vtype(vec));
        if vrvf < vvf { t := vec_res; vec_res = vec; vec = t; t2 := vrvf; vrvf = vvf; vvf = t2; }
        o := vec_res;
        if vrvf != vvf {
            m := new_mask(vvf);
            for k: 0..vvf-1 m[k] = cast(s32) k;
            o = sgb_shuffle(vec_res, NONE, m);
        }
        o = hr_create_op(h, hb, o, vec, "rdx.op");
        if vrvf != vvf o = slp_create_insert_vector(vec_res, o, 0);
        vec_res = o;
    }
    create_single(h, hb, *reduced_sub_tree, vec_res, 1, false, false, dest_ty);
    return reduced_sub_tree;
}
