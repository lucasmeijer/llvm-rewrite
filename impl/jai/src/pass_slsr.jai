// StraightLineStrengthReduce (slsr): port of llvm/lib/Transforms/Scalar/StraightLineStrengthReduce.cpp. Candidates
// `B + i * S`, `(B + i) * S` and `&B[i * S]` are rewritten relative to a dominating "basis" candidate that differs
// only in the index, the base or the stride (path compression, a dependency-ordered rewrite).

slsr_cl: struct { enable_poison_reuse_guard := true; };   // -enable-poison-reuse-guard

slsr_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name != "enable-poison-reuse-guard" return false;
    if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" slsr_cl.enable_poison_reuse_guard = true;
    else if value == "false" || value == "0" || value == "FALSE" || value == "False" slsr_cl.enable_poison_reuse_guard = false;
    else fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
    return true;
}

Slsr_Kind :: enum u8 { INVALID; ADD; MUL; GEP; }
Slsr_DKind :: enum u8 { INVALID_DELTA; INDEX_DELTA; BASE_DELTA; STRIDE_DELTA; }
// EfficiencyLevel
EFF_UNKNOWN :: 0; EFF_TWO_INST_TWO_VAR :: 1; EFF_TWO_INST_ONE_VAR :: 2; EFF_ONE_INST_TWO_VAR :: 3; EFF_ONE_INST_ONE_VAR :: 4; EFF_ZERO_INST :: 5;

Slsr_Cand :: struct {
    kind: Slsr_Kind;
    base: Scev_Id = SCEV_NULL;
    index: Value_Id = NONE;    // a ConstantInt
    stride: Value_Id = NONE;
    ins: Value_Id = NONE;
    basis: s32 = -1;
    delta_kind: Slsr_DKind;
    stride_scev: Scev_Id = SCEV_NULL;
    delta: Value_Id = NONE;
    drop_list: [..] Value_Id;
}

Slsr :: struct {
    dt: *Dom_Tree;
    t: *Tti;
    cands: [..] Slsr_Cand;                              // std::list<Candidate> (indices stay valid)
    scev_to_insts: Table(Scev_Id, [..] Value_Id);       // SmallSetVector
    dep_keys: [..] Value_Id;                            // DependencyGraph (MapVector): keys in insertion order
    dep_children: Table(Value_Id, [..] Value_Id);
    rewrite_cands: Table(Value_Id, [..] s32);
    dead: [..] Value_Id;
    // CandidateDict: key -> block -> candidates
    dict_index: Table(string, [..] s32);
    dict_base: Table(string, [..] s32);
    dict_stride: Table(string, [..] s32);
}

slsr_is_const_int :: (v: Value_Id) -> bool { return v != NONE && vkind(v) == .C_INT && !is_vector_type(vtype(v)); }

// getComputationEfficiency
slsr_computation_efficiency :: (kind: Slsr_Kind, index: Value_Id, stride: Value_Id, base: Scev_Id = SCEV_NULL) -> s64 {
    is_constant_base := false; is_zero_base := false;
    if base != SCEV_NULL && sc_is_const(base) { is_constant_base = true; is_zero_base = ap_is_zero(sc_ap(base)); }
    is_constant_stride := slsr_is_const_int(stride);
    is_zero_stride := is_constant_stride && ap_is_zero(const_ap(stride));
    if is_constant_base && is_constant_stride return EFF_ZERO_INST;
    iv := const_ap(index);
    if kind == .MUL {
        if is_zero_stride return EFF_ZERO_INST;
        if ap_is_zero(iv) return ifx is_constant_stride || is_constant_base then EFF_ONE_INST_ONE_VAR else EFF_ONE_INST_TWO_VAR;
        if is_constant_base return ifx is_zero_base && (ap_is_one(iv) || ap_is_all_ones(iv)) then EFF_ZERO_INST else EFF_ONE_INST_ONE_VAR;
        if is_constant_stride {
            cv := const_ap(stride);
            return ifx ap_is_one(cv) || ap_is_all_ones(cv) then EFF_ONE_INST_ONE_VAR else EFF_TWO_INST_ONE_VAR;
        }
        return EFF_TWO_INST_TWO_VAR;
    }
    if ap_is_zero(iv) || is_zero_stride return EFF_ZERO_INST;
    simple_index := ap_is_one(iv) || ap_is_all_ones(iv);
    if is_constant_base return ifx is_zero_base then (ifx simple_index then EFF_ZERO_INST else EFF_ONE_INST_ONE_VAR) else (ifx simple_index then EFF_ONE_INST_ONE_VAR else EFF_TWO_INST_ONE_VAR);
    if is_constant_stride return ifx is_zero_stride then EFF_ZERO_INST else EFF_ONE_INST_ONE_VAR;
    if simple_index return EFF_ONE_INST_TWO_VAR;
    return EFF_TWO_INST_TWO_VAR;
}
// getRewriteEfficiency(Delta, DeltaKind)
slsr_rewrite_efficiency_of :: (c: *Slsr_Cand, delta: Value_Id, dk: Slsr_DKind) -> s64 {
    if dk == {
        case .BASE_DELTA; return slsr_computation_efficiency(c.kind, const_int(vtype(delta), 1), delta);
        case .STRIDE_DELTA; return slsr_computation_efficiency(c.kind, c.index, delta);
        case .INDEX_DELTA; return slsr_computation_efficiency(c.kind, delta, c.stride);
    }
    return EFF_UNKNOWN;
}
slsr_rewrite_efficiency :: (c: *Slsr_Cand) -> s64 { if c.basis >= 0 return slsr_rewrite_efficiency_of(c, c.delta, c.delta_kind); return EFF_UNKNOWN; }
slsr_is_profitable_rewrite :: (c: *Slsr_Cand, delta: Value_Id, dk: Slsr_DKind) -> bool {
    return slsr_computation_efficiency(c.kind, c.index, c.stride, c.base) <= slsr_rewrite_efficiency_of(c, delta, dk);
}
slsr_is_high_efficiency :: (c: *Slsr_Cand) -> bool { return slsr_computation_efficiency(c.kind, c.index, c.stride, c.base) >= EFF_ONE_INST_ONE_VAR; }

// mayHaveSignedWrap / isSignExtendedGepIndex / isSafeToFactorGepIndex
slsr_may_have_signed_wrap :: (v: Value_Id) -> bool {
    o := opr_code(v);
    if o != .ADD && o != .SUB && o != .MUL && o != .SHL return true;   // not an OverflowingBinaryOperator
    return (opr_flags(v) & F_NSW) == 0;
}
slsr_is_safe_to_factor_gep_index :: (idx: Value_Id, gep: Value_Id) -> bool {
    sign_extended := type_bits(vtype(idx)) < dl_index_size_bits(cast(u32) ir.types[scalar_type(vtype(gep))].a);
    return !sign_extended || !slsr_may_have_signed_wrap(idx);
}

// getAndRecordSCEV
slsr_get_and_record_scev :: (s: *Slsr, v: Value_Id) -> Scev_Id {
    x := sc_get_scev(v);
    if is_inst(v) && !(sc_is_cnc(x) || sc_is_unknown(x) || sc_is_const(x)) {
        p := table_find_pointer(*s.scev_to_insts, x);
        if !p { e: [..] Value_Id; e.allocator = temp; table_set(*s.scev_to_insts, x, e); p = table_find_pointer(*s.scev_to_insts, x); }
        found := false;
        for p.* if it == v { found = true; break; }
        if !found array_add(p, v);
    }
    return x;
}

// getNearestValueOfSCEV
slsr_nearest_value_of_scev :: (s: *Slsr, x: Scev_Id, ci: Value_Id) -> Value_Id {
    if sc_is_cnc(x) return NONE;
    if sc_is_unknown(x) || sc_is_const(x) return sc_value(x);
    p := table_find_pointer(*s.scev_to_insts, x);
    if !p return NONE;
    for < p.* if dt_dominates_inst(s.dt, it, ci) return it;
    return NONE;
}

// getDelta
slsr_get_delta :: (s: *Slsr, c: *Slsr_Cand, b: *Slsr_Cand, k: Slsr_DKind) -> Value_Id {
    if k == .INDEX_DELTA {
        idx := const_ap(c.index); bidx := const_ap(b.index);
        if idx.bits < bidx.bits idx = ap_sext(idx, bidx.bits);
        else if idx.bits > bidx.bits bidx = ap_sext(bidx, idx.bits);
        d := ap_sub(idx, bidx);
        return const_int_ap(type_int(d.bits), d);
    }
    if k == .BASE_DELTA || k == .STRIDE_DELTA {
        bp := ifx k == .BASE_DELTA then b.base else b.stride_scev;
        cp := ifx k == .BASE_DELTA then c.base else c.stride_scev;
        return slsr_nearest_value_of_scev(s, sc_get_minus(cp, bp), c.ins);
    }
    return NONE;
}

// isSimilar
slsr_is_similar :: (c: *Slsr_Cand, b: *Slsr_Cand, k: Slsr_DKind) -> bool {
    same_type := false;
    if k == .STRIDE_DELTA same_type = sc_type(c.stride_scev) == sc_type(b.stride_scev);
    else if k == .BASE_DELTA same_type = sc_type(c.base) == sc_type(b.base);
    else if k == .INDEX_DELTA same_type = true;
    return same_type && b.ins != c.ins && b.kind == c.kind;
}

// candidatePredicate
slsr_candidate_predicate :: (s: *Slsr, bi: s32, c: *Slsr_Cand, k: Slsr_DKind) -> bool {
    b := *s.cands[bi];
    if !slsr_is_similar(c, b, k) return false;
    delta := slsr_get_delta(s, c, b, k);
    if delta == NONE return false;
    if k == .STRIDE_DELTA && c.kind == .GEP && slsr_is_const_int(delta) {
        if !slsr_is_safe_to_factor_gep_index(b.stride, b.ins) return false;
    }
    if k == .INDEX_DELTA && !slsr_is_profitable_rewrite(c, delta, .INDEX_DELTA) return false;
    for b.drop_list drop_poison_generating_annotations(it);
    if c.delta == NONE || slsr_is_const_int(delta) {
        c.delta = delta;
        c.basis = bi;
        c.delta_kind = k;
    }
    return slsr_is_const_int(c.delta);
}

// the CandidateDict keys (tuple of SCEV / ConstantInt / Type, then the block)
slsr_dict_key :: (a: u32, b: u32, t: Type_Id, bb: Value_Id) -> string { return tprint("%:%:%:%", a, b, t, bb); }

// searchFrom
slsr_search_from :: (s: *Slsr, dict: *Table(string, [..] s32), ka: u32, kb: u32, c: *Slsr_Cand, k: Slsr_DKind) -> bool {
    if c.kind == .MUL && k != .INDEX_DELTA return false;
    bb := inst_block(c.ins);
    while bb != NONE {
        p := table_find_pointer(dict, slsr_dict_key(ka, kb, vtype(c.ins), bb));
        if p for < p.* if slsr_candidate_predicate(s, it, c, k) return true;
        n := dt_node(s.dt, bb);
        if n < 0 break;
        idom := dt_idom(s.dt, n);
        bb = ifx idom >= 0 then dt_block(s.dt, idom) else NONE;
    }
    return false;
}

// setBasisAndDeltaFor (getCandidatesWithDeltaKind: the key must have some block entry, searchFrom walks the blocks)
slsr_set_basis_and_delta_for :: (s: *Slsr, c: *Slsr_Cand) {
    if slsr_search_from(s, *s.dict_base, c.stride_scev, c.index, c, .BASE_DELTA) return;
    if slsr_search_from(s, *s.dict_stride, c.base, c.index, c, .STRIDE_DELTA) return;
    if slsr_search_from(s, *s.dict_index, c.base, c.stride_scev, c, .INDEX_DELTA) return;
}

// compressPath: (found, root, kind, delta)
slsr_compress_path :: (s: *Slsr, c: *Slsr_Cand, basis: s32) -> (bool, s32, Slsr_DKind, Value_Id) {
    if basis < 0 || s.cands[basis].basis < 0 || c.kind == .MUL return false, -1, .INVALID_DELTA, NONE;
    root := basis;
    new_delta: Value_Id = NONE;
    new_kind := Slsr_DKind.INVALID_DELTA;
    while s.cands[root].basis >= 0 {
        next_root := s.cands[root].basis;
        nr := *s.cands[next_root];
        if c.base == nr.base && c.stride_scev == nr.stride_scev && slsr_is_similar(c, nr, .INDEX_DELTA) {
            ci := slsr_get_delta(s, c, nr, .INDEX_DELTA);
            cv := const_ap(ci);
            if ap_is_zero(cv) || ap_is_one(cv) || sc_is_const(c.stride_scev) {
                root = next_root;
                new_kind = .INDEX_DELTA;
                new_delta = ci;
                continue;
            }
        }
        cand_part, basis_part: Scev_Id;
        curr_kind: Slsr_DKind;
        if c.base == nr.base && c.index == nr.index {
            cand_part = c.stride_scev; basis_part = nr.stride_scev; curr_kind = .STRIDE_DELTA;
        } else if c.stride_scev == nr.stride_scev && c.index == nr.index {
            cand_part = c.base; basis_part = nr.base; curr_kind = .BASE_DELTA;
        } else break;
        if !slsr_is_similar(c, nr, curr_kind) break;
        if curr_kind == .STRIDE_DELTA && c.kind == .GEP && !slsr_is_safe_to_factor_gep_index(nr.stride, nr.ins) break;
        dv := sc_get_minus(cand_part, basis_part);
        if sc_is_const(dv) {
            root = next_root;
            new_delta = sc_value(dv);
            new_kind = curr_kind;
        } else break;
    }
    if root != basis return true, root, new_kind, new_delta;
    return false, -1, .INVALID_DELTA, NONE;
}

// isFoldable
slsr_is_foldable :: (s: *Slsr, c: *Slsr_Cand) -> bool {
    if c.kind == .ADD {
        iv := const_ap(c.index);
        return iv.bits <= 64 && tti_is_legal_addressing_mode(s.t, sc_type(c.base), NONE, 0, true, ap_sext_value(iv), 0xFFFF_FFFF);
    }
    if c.kind == .GEP {
        idx: [..] Value_Id; idx.allocator = temp;
        for k: 1..cast(s64) nops(c.ins) - 1 array_add(*idx, op(c.ins, cast(u32) k));
        return tti_gep_cost(s.t, opr_gep_source_type(c.ins), op(c.ins, 0), idx, NONE, TCK_SIZE_AND_LATENCY) == TCC_FREE;
    }
    return false;
}

slsr_dict_push :: (d: *Table(string, [..] s32), key: string, ci: s32) {
    p := table_find_pointer(d, key);
    if !p { e: [..] s32; e.allocator = temp; table_set(d, key, e); p = table_find_pointer(d, key); }
    array_add(p, ci);
}

// allocateCandidatesAndFindBasis(CT, B, Idx, S, I)
slsr_allocate :: (s: *Slsr, kind: Slsr_Kind, b: Scev_Id, idx: Value_Id, stride: Value_Id, i: Value_Id) {
    is_safe := kind != .GEP || slsr_is_safe_to_factor_gep_index(stride, i);
    c: Slsr_Cand;
    c.kind = kind; c.base = b; c.index = idx; c.stride = stride; c.ins = i;
    c.stride_scev = slsr_get_and_record_scev(s, stride);
    c.drop_list.allocator = temp;
    if is_safe && !slsr_is_foldable(s, *c) && !slsr_is_high_efficiency(*c) {
        slsr_set_basis_and_delta_for(s, *c);
        ok, root, k, d := slsr_compress_path(s, *c, c.basis);
        if ok { c.basis = root; c.delta_kind = k; c.delta = d; }
    }
    array_add(*s.cands, c);
    ci := cast(s32) (s.cands.count - 1);
    p := table_find_pointer(*s.rewrite_cands, i);
    if !p { e: [..] s32; e.allocator = temp; table_set(*s.rewrite_cands, i, e); p = table_find_pointer(*s.rewrite_cands, i); }
    array_add(p, ci);
    cc := *s.cands[ci];
    if !slsr_cl.enable_poison_reuse_guard || sc_can_reuse_instruction(sc_get_scev(i), i, *cc.drop_list) {
        // CandidateDict.add
        t := vtype(cc.ins); bb := inst_block(cc.ins);
        slsr_dict_push(*s.dict_index, slsr_dict_key(cc.base, cc.stride_scev, t, bb), ci);
        slsr_dict_push(*s.dict_base, slsr_dict_key(cc.stride_scev, cc.index, t, bb), ci);
        slsr_dict_push(*s.dict_stride, slsr_dict_key(cc.base, cc.index, t, bb), ci);
    }
}

// allocateCandidatesAndFindBasisForAdd(LHS, RHS, I)
slsr_allocate_for_add_lr :: (s: *Slsr, lhs: Value_Id, rhs: Value_Id, i: Value_Id) {
    if is_inst(rhs) && inst_op(rhs) == .MUL && slsr_is_const_int(op(rhs, 1)) {
        slsr_allocate(s, .ADD, sc_get_scev(lhs), op(rhs, 1), op(rhs, 0), i);
    } else if is_inst(rhs) && inst_op(rhs) == .SHL && slsr_is_const_int(op(rhs, 1)) {
        sh := const_ap(op(rhs, 1));
        one := ap_one(sh.bits);
        amt := ifx ap_ult(sh, ap_from_u64(sh.bits, sh.bits)) then cast(u32) ap_zext_value(sh) else sh.bits;   // APInt::shl(APInt): getLimitedValue(BitWidth)
        idx := const_int_ap(type_int(sh.bits), ifx amt >= sh.bits then ap_zero(sh.bits) else ap_shl(one, amt));
        slsr_allocate(s, .ADD, sc_get_scev(lhs), idx, op(rhs, 0), i);
    } else {
        slsr_allocate(s, .ADD, sc_get_scev(lhs), const_int(vtype(i), 1), rhs, i);
    }
}

// allocateCandidatesAndFindBasisForMul(LHS, RHS, I)
slsr_allocate_for_mul_lr :: (s: *Slsr, lhs: Value_Id, rhs: Value_Id, i: Value_Id) {
    // matchesAdd / matchesOr: m_c_Add / m_c_Or (m_Value(B), m_ConstantInt(C))
    match_c :: (v: Value_Id, opc: Opcode) -> (bool, Value_Id, Value_Id) {
        if !is_inst(v) || inst_op(v) != opc return false, NONE, NONE;
        if slsr_is_const_int(op(v, 1)) return true, op(v, 0), op(v, 1);
        if slsr_is_const_int(op(v, 0)) return true, op(v, 1), op(v, 0);
        return false, NONE, NONE;
    }
    ok, b, idx := match_c(lhs, .ADD);
    if ok { slsr_allocate(s, .MUL, sc_get_scev(b), idx, rhs, i); return; }
    ok, b, idx = match_c(lhs, .OR);
    if ok {
        q: Simplify_Query; q.have_tli = false;
        if have_no_common_bits_set(b, idx, q) { slsr_allocate(s, .MUL, sc_get_scev(b), idx, rhs, i); return; }
    }
    slsr_allocate(s, .MUL, sc_get_scev(lhs), const_int(vtype(i), 0), rhs, i);
}

// allocateCandidatesAndFindBasisForGEP
slsr_allocate_for_gep :: (s: *Slsr, gep: Value_Id) {
    if is_vector_type(vtype(gep)) return;
    index_exprs: [..] Scev_Id; index_exprs.allocator = temp;
    for k: 1..cast(s64) nops(gep) - 1 array_add(*index_exprs, sc_get_scev(op(gep, cast(u32) k)));
    nw := opr_flags(gep) & (F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if nw != 0 && !sc_is_scev_expr_never_poison(gep) nw = 0;
    g: Scof_Gti;
    idx_bits := dl_index_size_bits(cast(u32) ir.types[scalar_type(vtype(gep))].a);
    for k: 1..cast(s64) nops(gep) - 1 {
        indexed, sequential := scof_gti_step(*g, gep, k);
        if !sequential continue;
        orig := index_exprs[k - 1];
        index_exprs[k - 1] = sc_get_zero(sc_type(orig));
        base_expr := sc_get_gep(sc_get_scev(op(gep, 0)), index_exprs, opr_gep_source_type(gep), nw, .[]);
        array_idx := op(gep, cast(u32) k);
        element_size := dl_type_alloc_size(indexed);
        ptr_idx_ty := dl_index_type(vtype(gep));
        element_size_idx := const_int_ap(ptr_idx_ty, ap_from_s64(type_bits(ptr_idx_ty), cast(s64) element_size));   // getSigned, ImplicitTrunc
        if type_bits(vtype(array_idx)) <= idx_bits slsr_allocate(s, .GEP, base_expr, element_size_idx, array_idx, gep);
        if is_inst(array_idx) && inst_op(array_idx) == .SEXT && type_bits(vtype(op(array_idx, 0))) <= idx_bits
            slsr_allocate(s, .GEP, base_expr, element_size_idx, op(array_idx, 0), gep);
        index_exprs[k - 1] = orig;
    }
}

// allocateCandidatesAndFindBasis(I)
slsr_allocate_for_inst :: (s: *Slsr, i: Value_Id) {
    o := inst_op(i);
    if o == .ADD {
        if type_kind(vtype(i)) != .INT return;
        lhs := op(i, 0); rhs := op(i, 1);
        slsr_allocate_for_add_lr(s, lhs, rhs, i);
        if lhs != rhs slsr_allocate_for_add_lr(s, rhs, lhs, i);
    } else if o == .MUL {
        if type_kind(vtype(i)) != .INT return;
        lhs := op(i, 0); rhs := op(i, 1);
        slsr_allocate_for_mul_lr(s, lhs, rhs, i);
        if lhs != rhs slsr_allocate_for_mul_lr(s, rhs, lhs, i);
    } else if o == .GEP {
        slsr_allocate_for_gep(s, i);
    }
}

slsr_dep_add :: (s: *Slsr, key: Value_Id, child: Value_Id) {
    p := table_find_pointer(*s.dep_children, key);
    if !p {
        e: [..] Value_Id; e.allocator = temp;
        table_set(*s.dep_children, key, e);
        array_add(*s.dep_keys, key);
        p = table_find_pointer(*s.dep_children, key);
    }
    if child != NONE array_add(p, child);
}

// addDependency
slsr_add_dependency :: (s: *Slsr, c: *Slsr_Cand) {
    if c.basis >= 0 slsr_dep_add(s, s.cands[c.basis].ins, c.ins);
    propagate :: (s: *Slsr, inst_: Value_Id, c: *Slsr_Cand) {
        p := table_find_pointer(*s.rewrite_cands, inst_);
        if !p return;
        any := false;
        for p.* if s.cands[it].basis >= 0 { any = true; break; }
        if any slsr_dep_add(s, inst_, c.ins);
    }
    if c.delta != NONE && is_inst(c.delta) propagate(s, c.delta, c);
    if is_inst(c.stride) propagate(s, c.stride, c);
}

// sortCandidateInstructions
slsr_sort_candidate_instructions :: (s: *Slsr) -> [..] Value_Id {
    sorted: [..] Value_Id; sorted.allocator = temp;
    in_degree: Table(Value_Id, s64); in_degree.allocator = temp;
    for k: s.dep_keys {
        if !table_contains(*in_degree, k) table_set(*in_degree, k, 0);
        for child: table_find_pointer(*s.dep_children, k).* {
            found, d := table_find(*in_degree, child);
            table_set(*in_degree, child, ifx found then d + 1 else 1);
        }
    }
    queue: [..] Value_Id; queue.allocator = temp;
    head := 0;
    for k: s.dep_keys { _, d := table_find(*in_degree, k); if d == 0 array_add(*queue, k); }
    visited: Table(Value_Id, bool); visited.allocator = temp;
    while head < queue.count {
        i := queue[head]; head += 1;
        if table_contains(*visited, i) continue;
        table_set(*visited, i, true);
        array_add(*sorted, i);
        // DependencyGraph[I]: operator[] default-inserts a key that has no children
        p := table_find_pointer(*s.dep_children, i);
        if !p { slsr_dep_add(s, i, NONE); p = table_find_pointer(*s.dep_children, i); }
        for next: p.* {
            _, d := table_find(*in_degree, next);
            d -= 1;
            table_set(*in_degree, next, d);
            if d == 0 array_add(*queue, next);
        }
    }
    return sorted;
}

// pickRewriteCandidate
slsr_pick_rewrite_candidate :: (s: *Slsr, i: Value_Id) -> s32 {
    p := table_find_pointer(*s.rewrite_cands, i);
    if !p return -1;
    best: s32 = -1;
    best_eff := EFF_UNKNOWN;
    for < ci: p.* {
        c := *s.cands[ci];
        if c.basis >= 0 {
            e := slsr_rewrite_efficiency(c);
            if e > best_eff { best_eff = e; best = ci; }
        }
    }
    return best;
}

slsr_sext_or_trunc :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    vb := type_bits(vtype(v)); tb := type_bits(t);
    if vb == tb return v;
    return irb_cast(b, ifx vb < tb then Opcode.SEXT else .TRUNC, v, t);
}
slsr_neg :: (b: *Irb, v: Value_Id) -> Value_Id { return irb_binop(b, .SUB, const_null_value(vtype(v)), v); }   // CreateNeg

// emitBump
slsr_emit_bump :: (s: *Slsr, basis: *Slsr_Cand, c: *Slsr_Cand, b: *Irb) -> Value_Id {
    create_mul :: (b: *Irb, lhs: Value_Id, rhs: Value_Id) -> Value_Id {
        if slsr_is_const_int(rhs) {
            cr := const_ap(rhs);
            dt := type_int(cr.bits);
            if ap_is_power_of_2(cr) return irb_binop(b, .SHL, lhs, const_int(dt, ap_log2(cr)));
            if ap_is_negated_power_of_2(cr) return slsr_neg(b, irb_binop(b, .SHL, lhs, const_int(dt, ap_log2(ap_neg(cr)))));
        }
        return irb_binop(b, .MUL, lhs, rhs);
    }
    delta := c.delta;
    if slsr_is_const_int(delta) && ap_is_zero(const_ap(delta)) return NONE;
    if c.delta_kind == .INDEX_DELTA {
        id := const_ap(c.delta);
        if ap_is_one(id) return c.stride;
        if ap_is_all_ones(id) return slsr_neg(b, c.stride);
        ext := slsr_sext_or_trunc(b, c.stride, type_int(id.bits));
        return create_mul(b, ext, c.delta);
    }
    bump := c.delta;
    if c.delta_kind == .STRIDE_DELTA {
        if c.kind == .GEP bump = slsr_sext_or_trunc(b, bump, dl_index_type(scalar_type(vtype(op(c.ins, 0)))));
        if !ap_is_one(const_ap(c.index)) {
            ext_index := slsr_sext_or_trunc(b, c.index, vtype(bump));
            bump = create_mul(b, bump, ext_index);
        }
    }
    return bump;
}

// rewriteCandidate
slsr_rewrite_candidate :: (s: *Slsr, c: *Slsr_Cand) {
    basis := *s.cands[c.basis];
    b: Irb; irb_set_before(*b, c.ins);
    bump := slsr_emit_bump(s, basis, c, *b);
    reduced: Value_Id;
    if bump == NONE reduced = basis.ins;
    else {
        if c.kind == .ADD || c.kind == .MUL {
            // m_Neg(m_Value(NegBump)): sub 0, X (instructions only)
            if is_inst(bump) && inst_op(bump) == .SUB && is_constant_kind(vkind(op(bump, 0))) && is_null_value(op(bump, 0)) {
                reduced = irb_binop(*b, .SUB, basis.ins, op(bump, 1));
                recursively_delete_trivially_dead_no_tli(bump);
            } else reduced = irb_binop(*b, .ADD, basis.ins, bump);
        } else {
            fl: u32 = ifx gep_is_inbounds(c.ins) then cast(u32) F_INBOUNDS else 0;
            reduced = irb_gep(*b, ir.t_i8, basis.ins, .[bump], "", fl);
        }
        take_name(reduced, c.ins);
    }
    replace_all_uses_with(c.ins, reduced);
    array_add(*s.dead, c.ins);
}

// StraightLineStrengthReducePass::run
slsr_run :: (f: Value_Id) -> Preserved {
    s: Slsr;
    s.dt = get_domtree(f);
    sc := get_scev(f);
    s.t = tti_get(f);
    se = sc;
    saved := scev_pass_se;
    scev_pass_se = sc;
    defer scev_pass_se = saved;
    s.cands.allocator = temp; s.scev_to_insts.allocator = temp; s.dep_keys.allocator = temp; s.dep_children.allocator = temp;
    s.rewrite_cands.allocator = temp; s.dead.allocator = temp;
    s.dict_index.allocator = temp; s.dict_base.allocator = temp; s.dict_stride.allocator = temp;
    blocks: [..] Value_Id; blocks.allocator = temp;
    dt_blocks_preorder(s.dt, *blocks);
    for bb: blocks for i: block_insts(bb) slsr_allocate_for_inst(*s, i);
    for * c: s.cands {
        slsr_dep_add(*s, c.ins, NONE);   // DependencyGraph.try_emplace(C.Ins)
        slsr_add_dependency(*s, c);
    }
    sorted := slsr_sort_candidate_instructions(*s);
    for < i: sorted {
        ci := slsr_pick_rewrite_candidate(*s, i);
        if ci >= 0 slsr_rewrite_candidate(*s, *s.cands[ci]);
    }
    for d: s.dead if vkind(d) == .INST && inst_block(d) != NONE recursively_delete_trivially_dead_no_tli(d);
    if s.dead.count == 0 return PRESERVE_ALL;
    pa: Preserved;
    pa.cfg = true;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .SCEV);
    return pa;
}
