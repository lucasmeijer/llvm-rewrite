// LoopAccessAnalysis: llvm/lib/Analysis/LoopAccessAnalysis.cpp. So far the free functions other passes use:
// getPointersDiff and isConsecutiveAccess (LoopIdiomRecognize, SLP).

// getLoadStoreType
load_store_type :: (i: Value_Id) -> Type_Id {
    if inst_op(i) == .LOAD return vtype(i);
    return vtype(op(i, 0));
}

// getPointersDiff(ElemTyA, PtrA, ElemTyB, PtrB, DL, SE, StrictCheck, CheckType)
get_pointers_diff :: (elem_a: Type_Id, ptr_a: Value_Id, elem_b: Type_Id, ptr_b: Value_Id, strict_check := false, check_type := true) -> (bool, s64) {
    if ptr_a == ptr_b return true, 0;
    if check_type && elem_a != elem_b return false, 0;
    asa := ptr_addrspace(vtype(ptr_a));
    asb := ptr_addrspace(vtype(ptr_b));
    if asa != asb return false, 0;
    idx_w := dl_index_size_bits(asa);
    off_a := ap_zero(idx_w); off_b := ap_zero(idx_w);
    a1, b1: Value_Id;
    a1, off_a = strip_and_accumulate_constant_offsets(ptr_a, off_a, true);
    b1, off_b = strip_and_accumulate_constant_offsets(ptr_b, off_b, true);
    val: s64;
    if a1 == b1 {
        asa = ptr_addrspace(vtype(a1));
        asb = ptr_addrspace(vtype(b1));
        if asa != asb return false, 0;
        idx_w = dl_index_size_bits(asa);
        off_a = ap_sext_or_trunc(off_a, idx_w);
        off_b = ap_sext_or_trunc(off_b, idx_w);
        off_b = ap_sub(off_b, off_a);
        if ap_min_signed_bits(off_b) > 64 return false, 0;   // trySExtValue
        val = ap_sext_value(off_b);
    } else {
        // getSCEV(PtrA) before getSCEV(PtrB): the creation order decides ExprValueMap's order (SCEVExpander reuse)
        sa := sc_get_scev(ptr_a);
        sb := sc_get_scev(ptr_b);
        ok, diff := sc_compute_constant_difference(sb, sa);
        if !ok return false, 0;
        if ap_min_signed_bits(diff) > 64 return false, 0;
        val = ap_sext_value(diff);
    }
    size := cast(s64) dl_type_store_size(elem_a);
    dist := val / size;
    if !strict_check || dist * size == val return true, dist;
    return false, 0;
}

// isConsecutiveAccess(A, B, DL, SE, CheckType)
is_consecutive_access :: (a: Value_Id, b: Value_Id, check_type := true) -> bool {
    pa := load_store_pointer_operand(a);
    pb := load_store_pointer_operand(b);
    if pa == NONE || pb == NONE return false;
    ok, d := get_pointers_diff(load_store_type(a), pa, load_store_type(b), pb, true, check_type);
    return ok && d == 1;
}

// ---------------------------------------------------------------- options (VectorizerParams and LAA cl::opts)

laa_opts: struct {
    force_vector_width: s64;               // -force-vector-width (VectorizerParams::VectorizationFactor: known minimum)
    force_vector_width_scalable: bool;     // -force-vector-width=vscale x N
    force_vector_interleave: s64;          // -force-vector-interleave
    runtime_memory_check_threshold: s64 = 8;   // -runtime-memory-check-threshold
    memory_check_merge_threshold: s64 = 100;   // -memory-check-merge-threshold
    max_dependences: s64 = 100;            // -max-dependences
    enable_mem_access_versioning := true;  // -enable-mem-access-versioning
    forwarding_conflict_detection := true; // -store-to-load-forwarding-conflict-detection
    max_forked_scev_depth: s64 = 5;        // -max-forked-scev-depth
    speculate_unit_stride := true;         // -laa-speculate-unit-stride
    hoist_runtime_checks := true;          // -hoist-runtime-checks
};
LAA_CL_OPT_COUNT :: 10;
add_laa_cl_opts :: (list: [] Cl_Opt, base: s64) {
    list[base + 0] = .{"force-vector-width", .INT, null, *laa_opts.force_vector_width, null};
    list[base + 1] = .{"force-vector-interleave", .INT, null, *laa_opts.force_vector_interleave, null};
    list[base + 2] = .{"runtime-memory-check-threshold", .INT, null, *laa_opts.runtime_memory_check_threshold, null};
    list[base + 3] = .{"memory-check-merge-threshold", .INT, null, *laa_opts.memory_check_merge_threshold, null};
    list[base + 4] = .{"max-dependences", .INT, null, *laa_opts.max_dependences, null};
    list[base + 5] = .{"enable-mem-access-versioning", .BOOL, *laa_opts.enable_mem_access_versioning, null, null};
    list[base + 6] = .{"store-to-load-forwarding-conflict-detection", .BOOL, *laa_opts.forwarding_conflict_detection, null, null};
    list[base + 7] = .{"max-forked-scev-depth", .INT, null, *laa_opts.max_forked_scev_depth, null};
    list[base + 8] = .{"laa-speculate-unit-stride", .BOOL, *laa_opts.speculate_unit_stride, null, null};
    list[base + 9] = .{"hoist-runtime-checks", .BOOL, *laa_opts.hoist_runtime_checks, null, null};
}
LAA_MAX_VECTOR_WIDTH :: 64;   // VectorizerParams::MaxVectorWidth

// ---------------------------------------------------------------- MemAccessInfo and EquivalenceClasses

// MemAccessInfo = PointerIntPair<Value *, 1, bool IsWrite>
Mai :: u64;
mai :: (ptr: Value_Id, is_write: bool) -> Mai { return ((cast(u64) ptr) << 1) | cast(u64) is_write; }
mai_ptr :: (m: Mai) -> Value_Id { return cast(Value_Id) (m >> 1); }
mai_write :: (m: Mai) -> bool { return (m & 1) != 0; }

// EquivalenceClasses<MemAccessInfo>: every class is the leader's member list (union appends the second list)
Eqc :: struct {
    leader: Table(Mai, Mai);              // TheMapping (value -> its leader)
    members: Table(Mai, [..] Mai);        // leader -> the class in iteration order
}
eqc_init :: (e: *Eqc) { e.leader.allocator = temp; e.members.allocator = temp; }
eqc_contains :: (e: *Eqc, v: Mai) -> bool { return table_contains(*e.leader, v); }
eqc_insert :: (e: *Eqc, v: Mai) {
    if eqc_contains(e, v) return;
    table_set(*e.leader, v, v);
    l: [..] Mai; l.allocator = temp;
    array_add(*l, v);
    table_set(*e.members, v, l);
}
eqc_find_leader :: (e: *Eqc, v: Mai) -> Mai { _, l := table_find(*e.leader, v); return l; }
eqc_class :: (e: *Eqc, v: Mai) -> [] Mai { l := table_find_pointer(*e.members, eqc_find_leader(e, v)); return l.*; }
eqc_union :: (e: *Eqc, a: Mai, b: Mai) {
    eqc_insert(e, a); eqc_insert(e, b);
    l1 := eqc_find_leader(e, a); l2 := eqc_find_leader(e, b);
    if l1 == l2 return;
    m2 := table_find_pointer(*e.members, l2).*;
    m1 := table_find_pointer(*e.members, l1);
    for m2 { array_add(m1, it); table_set(*e.leader, it, l1); }
    table_remove(*e.members, l2);
}
eqc_erase_class :: (e: *Eqc, v: Mai) {
    if !eqc_contains(e, v) return;
    l := eqc_find_leader(e, v);
    m := table_find_pointer(*e.members, l).*;
    for m table_remove(*e.leader, it);
    table_remove(*e.members, l);
}
eqc_clear :: (e: *Eqc) { table_reset(*e.leader); table_reset(*e.members); }

// ---------------------------------------------------------------- MemoryDepChecker

Dep_Type :: enum u8 { NoDep; Unknown; IndirectUnsafe; InvariantUnsafe; Forward; ForwardButPreventsForwarding; Backward;
                      BackwardVectorizable; BackwardVectorizableButPreventsForwarding; }
Vec_Safety :: enum u8 { SAFE; POSSIBLY_SAFE_WITH_RT_CHECKS; UNSAFE; }
Dependence :: struct { source: u32; destination: u32; type: Dep_Type; }

dep_is_safe_for_vectorization :: (t: Dep_Type) -> Vec_Safety {
    if t == .NoDep || t == .Forward || t == .BackwardVectorizable return .SAFE;
    if t == .Unknown return .POSSIBLY_SAFE_WITH_RT_CHECKS;
    return .UNSAFE;
}

Mdc :: struct {
    pse: *Pse;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    l: Loop_Id;                                  // InnermostLoop
    symbolic_strides: *Table(Value_Id, Scev_Id);
    max_target_vector_width_in_bits: u64;
    loop_guards: *Laa_Loop_Guards;
    accesses: Table(Mai, [..] u32);              // DenseMap<MemAccessInfo, std::vector<unsigned>>
    inst_map: [..] Value_Id;
    access_idx: u32;
    min_dep_dist_bytes: u64;
    max_safe_vector_width_in_bits: u64 = 0xFFFF_FFFF;
    max_store_load_forward_safe_distance_in_bits: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    should_retry_with_runtime_checks: bool;
    status: Vec_Safety;
    record_dependences := true;
    dependences: [..] Dependence;
    pointer_bounds: Table(u64, [2] Scev_Id);     // (PtrExpr, EltSize) -> (Start, End)
}
Laa_Loop_Guards :: struct { has: bool; g: Loop_Guards; }
laa_guards :: (g: *Laa_Loop_Guards, l: Loop_Id) -> *Loop_Guards {
    if !g.has { g.g = sc_loop_guards_collect(l); g.has = true; }
    return *g.g;
}

// visitPointers
laa_visit_pointers :: (start: Value_Id, li: *Loop_Info, l: Loop_Id, out: *[..] Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, start);
    while work.count {
        p := pop(*work);
        if table_contains(*visited, p) continue;
        table_set(*visited, p, true);
        if is_inst(p) && inst_op(p) == .PHI && li_contains(li, l, inst_block(p)) && inst_block(p) != li_header(li, l) {
            n := nops(p);
            for k: 0..cast(s64) n - 1 array_add(*work, op(p, cast(u32) k));
        } else array_add(out, p);
    }
}
mdc_add_access :: (d: *Mdc, li: *Loop_Info, i: Value_Id) {
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    is_write := inst_op(i) == .STORE;
    laa_visit_pointers(load_store_pointer_operand(i), li, d.l, *ptrs);
    for p: ptrs {
        k := mai(p, is_write);
        e := table_find_pointer(*d.accesses, k);
        if !e { l: [..] u32; l.allocator = temp; table_set(*d.accesses, k, l); e = table_find_pointer(*d.accesses, k); }
        array_add(e, d.access_idx);
        array_add(*d.inst_map, i);
        d.access_idx += 1;
    }
}
mdc_order_for_access :: (d: *Mdc, ptr: Value_Id, is_write: bool) -> [] u32 {
    e := table_find_pointer(*d.accesses, mai(ptr, is_write));
    if !e return .[];
    return e.*;
}
mdc_merge_in_status :: (d: *Mdc, s: Vec_Safety) { if d.status < s d.status = s; }
mdc_is_safe_for_vectorization :: (d: *Mdc) -> bool { return d.status == .SAFE; }
mdc_should_retry_with_runtime_checks :: (d: *Mdc) -> bool { return d.should_retry_with_runtime_checks && d.status == .POSSIBLY_SAFE_WITH_RT_CHECKS; }

// couldPreventStoreLoadForward
mdc_could_prevent_store_load_forward :: (d: *Mdc, distance: u64, type_byte_size: u64, common_stride: u64 = 0) -> bool {
    num_iters := 8 * type_byte_size;
    max_vf := min(LAA_MAX_VECTOR_WIDTH * type_byte_size, d.max_store_load_forward_safe_distance_in_bits);
    vf := 2 * type_byte_size;
    while vf <= max_vf {
        if distance % vf != 0 && distance / vf < num_iters { max_vf = vf >> 1; break; }
        vf *= 2;
    }
    if max_vf < 2 * type_byte_size return true;
    if common_stride != 0 && max_vf < d.max_store_load_forward_safe_distance_in_bits && max_vf != LAA_MAX_VECTOR_WIDTH * type_byte_size {
        x := max_vf / common_stride;
        mvf: u64 = 0;
        if x { mvf = 1; while mvf * 2 <= x mvf *= 2; }   // bit_floor
        bits := mvf * type_byte_size * 8;
        d.max_store_load_forward_safe_distance_in_bits = min(d.max_store_load_forward_safe_distance_in_bits, bits);
    }
    return false;
}

// isSafeDependenceDistance
laa_is_safe_dependence_distance :: (max_btc: Scev_Id, dist: Scev_Id, max_stride: u64) -> bool {
    step := sc_get_constant(ap_from_u64(sc_type_bits(sc_type(max_btc)), max_stride));
    product := sc_get_mul2(max_btc, step);
    casted_dist := dist; casted_product := product;
    if dl_type_size_bits(sc_type(dist)) > dl_type_size_bits(sc_type(product)) casted_product = sc_get_zero_extend(product, sc_type(dist));
    else casted_dist = sc_get_noop_or_sign_extend(dist, sc_type(product));
    minus := sc_get_minus(casted_dist, casted_product);
    if sc_is_known_positive(minus) return true;
    neg := sc_get_negative(casted_dist);
    minus = sc_get_minus(neg, casted_product);
    return sc_is_known_positive(minus);
}
// areStridedAccessesIndependent
laa_strided_independent :: (distance: u64, stride: u64, type_byte_size: u64) -> bool {
    if distance % type_byte_size != 0 return false;
    return distance % stride != 0;
}

// getStartAndEndForAccess (SCEV_CNC pair = could not compute)
laa_start_and_end_for_access :: (l: Loop_Id, ptr_expr: Scev_Id, access_ty: Type_Id, btc: Scev_Id, max_btc: Scev_Id,
                                 bounds: *Table(u64, [2] Scev_Id), dt: *Dom_Tree, ac: *Assumption_Cache, lg: *Laa_Loop_Guards) -> (Scev_Id, Scev_Id) {
    idx_ty := dl_index_type(sc_type(ptr_expr));
    elt := sc_get_store_size_of(idx_ty, access_ty);
    a, b := laa_start_and_end_for_access_size(l, ptr_expr, elt, btc, max_btc, bounds, dt, ac, lg);
    return a, b;
}
laa_start_and_end_for_access_size :: (l: Loop_Id, ptr_expr: Scev_Id, elt: Scev_Id, btc: Scev_Id, max_btc: Scev_Id,
                                      bounds: *Table(u64, [2] Scev_Id), dt: *Dom_Tree, ac: *Assumption_Cache, lg: *Laa_Loop_Guards) -> (Scev_Id, Scev_Id) {
    key := ((cast(u64) ptr_expr) << 32) | cast(u64) elt;
    if bounds {
        found, v := table_find(bounds, key);
        if found return v[0], v[1];
        table_set(bounds, key, .[SCEV_CNC, SCEV_CNC]);
    }
    sc_start_, sc_end: Scev_Id;
    if sc_is_loop_invariant(ptr_expr, l) {
        sc_start_ = ptr_expr; sc_end = ptr_expr;
    } else if sc_is_addrec(ptr_expr) {
        ar := ptr_expr;
        sc_start_ = sc_start(ar);
        if btc != SCEV_CNC sc_end = sc_evaluate_at_iteration(ar, btc);
        else {
            if laa_eval_ptr_addrec_at_max_btc_will_not_wrap(ar, max_btc, elt, dt, ac, lg) sc_end = sc_evaluate_at_iteration(ar, max_btc);
            else {
                all_ones := const_all_ones_of(sc_type(elt));
                sc_end = sc_get_add2(sc_get_negative(elt), sc_get_scev(ce_cast(.INTTOPTR, all_ones, sc_type(ar))));
            }
        }
        step := sc_step_recurrence(ar);
        if sc_is_const(step) {
            if ap_is_negative(sc_ap(step)) { t := sc_start_; sc_start_ = sc_end; sc_end = t; }
        } else {
            sc_start_ = sc_get_umin2(sc_start_, sc_end);
            sc_end = sc_get_umax2(sc_start(ar), sc_end);
        }
    } else return SCEV_CNC, SCEV_CNC;
    sc_end = sc_get_add2(sc_end, elt);
    if bounds table_set(bounds, key, .[sc_start_, sc_end]);
    return sc_start_, sc_end;
}
sc_evaluate_at_iteration :: (ar: Scev_Id, it: Scev_Id) -> Scev_Id { ops := sc_operands(ar); return evaluate_at_iteration_ops(ops, it); }

// addSCEVNoOverflow / mulSCEVNoOverflow
laa_add_no_overflow :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
    if !sc_will_not_overflow(.ADD, false, a, b) return SCEV_NULL;
    return sc_get_add2(a, b);
}
laa_mul_no_overflow :: (a: Scev_Id, b: Scev_Id) -> Scev_Id {
    if !sc_will_not_overflow(.MUL, false, a, b) return SCEV_NULL;
    return sc_get_mul2(a, b);
}

// evaluatePtrAddRecAtMaxBTCWillNotWrap
laa_eval_ptr_addrec_at_max_btc_will_not_wrap :: (ar: Scev_Id, max_btc_in: Scev_Id, elt: Scev_Id, dt: *Dom_Tree, ac: *Assumption_Cache, lg: *Laa_Loop_Guards) -> bool {
    max_btc := max_btc_in;
    base := sc_get_pointer_base(sc_start(ar));
    if !sc_is_unknown(base) return false;
    l := sc_loop(ar);
    start_v := sc_value(base);
    can_be_null, deref := pointer_dereferenceable_bytes(start_v);
    if deref != 0 && can_be_null return false;
    step := sc_step_recurrence(ar);
    wider := sc_get_wider_type(sc_type(max_btc), sc_type(step));
    deref_scev := sc_get_constant(ap_from_u64(sc_type_bits(wider), deref));
    deref_scev = laa_deref_from_assumptions(start_v, ac, dt, se.li, l, deref_scev);
    if sc_is_zero(deref_scev) return false;
    nonneg := sc_is_known_non_negative(step);
    if !nonneg && !sc_is_known_negative(step) return false;
    step = sc_get_noop_or_sign_extend(step, wider);
    max_btc = sc_get_noop_or_zero_extend(max_btc, wider);
    if !sc_is_known_predicate(ICMP_UGE, sc_start(ar), base) return false;
    start_offset := sc_get_noop_or_zero_extend(sc_get_minus(sc_start(ar), base), wider);
    g := laa_guards(lg, l);
    max_btc = sc_apply_loop_guards_with(max_btc, g);
    off_last := laa_mul_no_overflow(max_btc, sc_get_abs(step, false));
    if off_last == SCEV_NULL {
        max_btc = sc_get_constant_max_backedge_taken_count(l);
        if sc_is_cnc(max_btc) return false;
        max_btc = sc_get_noop_or_zero_extend(max_btc, wider);
        off_last = laa_mul_no_overflow(max_btc, sc_get_abs(step, false));
        if off_last == SCEV_NULL return false;
    }
    off_end := laa_add_no_overflow(off_last, sc_get_noop_or_zero_extend(elt, wider));
    if off_end == SCEV_NULL return false;
    if nonneg {
        end_bytes := laa_add_no_overflow(start_offset, off_end);
        if end_bytes == SCEV_NULL return false;
        deref_scev = sc_apply_loop_guards_with(deref_scev, g);
        return sc_is_known_predicate(ICMP_ULE, end_bytes, deref_scev);
    }
    return sc_is_known_predicate(ICMP_SGE, start_offset, off_end) && sc_is_known_predicate(ICMP_ULE, start_offset, deref_scev);
}
// getKnowledgeForValue(V, {Dereferenceable}, AC, Filter) with the filter of evaluatePtrAddRecAtMaxBTCWillNotWrap:
// every assumption valid at the loop's context instruction raises DerefBytesSCEV to a umax (the filter never
// "accepts", so all are visited)
laa_deref_from_assumptions :: (v: Value_Id, ac: *Assumption_Cache, dt: *Dom_Tree, li: *Loop_Info, l: Loop_Id, deref_in: Scev_Id) -> Scev_Id {
    deref := deref_in;
    if !ac return deref;
    h := li_header(li, l);
    cxt := block_first_non_phi(h);
    pred := li_loop_predecessor(li, l);
    if pred != NONE {
        t := block_terminator(pred);
        if t != NONE && (inst_op(t) == .BR || inst_op(t) == .CONDBR) cxt = t;
    }
    for e: ac_assumptions_for(ac, v) {
        a := e.assume;
        if a == NONE || vkind(a) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
        ok, rk := knowledge_from_bundle(a, e.index);
        if !ok || rk.was_on != v || rk.kind != .Dereferenceable continue;
        if !is_valid_assume_for_context(a, cxt, dt) continue;
        begin := ir.u32_pool[inst(a).idx + 3 * e.index + 1];
        end := ir.u32_pool[inst(a).idx + 3 * e.index + 2];
        if end - begin < 2 fatal("loop-accesses: a dereferenceable bundle without a size");
        rk_scev := sc_get_scev(op(a, begin + 1));
        common := sc_get_wider_type(sc_type(deref), sc_type(rk_scev));
        deref = sc_get_noop_or_zero_extend(deref, common);
        rk_scev = sc_get_noop_or_zero_extend(rk_scev, common);
        deref = sc_get_umax2(deref, rk_scev);
    }
    return deref;
}

// getStrideFromAddRec
laa_stride_from_add_rec :: (ar: Scev_Id, l: Loop_Id, access_ty: Type_Id) -> (bool, s64) {
    if type_kind(access_ty) == .SVECTOR return false, 0;
    if l != sc_loop(ar) return false, 0;
    step := sc_step_recurrence(ar);
    if !sc_is_const(step) return false, 0;
    size := cast(s64) dl_type_alloc_size(access_ty);
    sv := sc_ap(step);
    if ap_min_signed_bits(sv) > 64 return false, 0;
    v := ap_sext_value(sv);
    if v % size != 0 return false, 0;
    return true, v / size;
}

// LoopAccessInfo::blockNeedsPredication
laa_block_needs_predication :: (bb: Value_Id, li: *Loop_Info, l: Loop_Id, dt: *Dom_Tree) -> bool {
    return !dt_dominates(dt, bb, li_loop_latch(li, l));
}

// isNoWrap
laa_is_no_wrap :: (pse: *Pse, li: *Loop_Info, ar: Scev_Id, ptr: Value_Id, access_ty: Type_Id, l: Loop_Id, dt: *Dom_Tree,
                   has_stride := false, stride_in: s64 = 0, preds: *[..] u32 = null) -> bool {
    if sc_flags(ar, SF_NUW | SF_NSW | SF_NW) != 0 return true;
    if ptr != NONE && pse_has_no_overflow(pse, ptr, INCREMENT_NUSW) return true;
    if ptr != NONE && is_inst(ptr) && inst_op(ptr) == .GEP && (inst(ptr).flags & (F_NUSW | F_INBOUNDS)) != 0 {   // hasNoUnsignedSignedWrap (inbounds implies nusw)
        if li_header(li, l) == li_loop_latch(li, l) return true;
        u := ir.v_first_use[ptr];
        while u != NONE {
            usr := ir.u_user[u];
            u = ir.u_next[u];
            if load_store_pointer_operand(usr) != ptr continue;
            ubb := inst_block(usr);
            if !li_contains(li, l, ubb) continue;
            if !laa_block_needs_predication(ubb, li, l, dt) return true;
        }
    }
    has_stride_ := has_stride; stride := stride_in;
    if !has_stride_ { has_stride_, stride = laa_stride_from_add_rec(ar, l, access_ty); }
    if has_stride_ {
        as := ptr_addrspace(sc_type(ar));
        if !null_pointer_is_defined(li.fn, as) && (stride == 1 || stride == -1) return true;
    }
    if ptr != NONE && preds {
        flags := INCREMENT_NUSW & ~sc_wrap_implied_flags(ar);
        array_add(preds, sc_get_wrap_predicate(ar, flags));
        return true;
    }
    return false;
}

// replaceSymbolicStrideSCEV
laa_replace_symbolic_stride_scev :: (pse: *Pse, strides: *Table(Value_Id, Scev_Id), ptr: Value_Id) -> Scev_Id {
    orig := pse_get_scev(pse, ptr);
    found, stride := table_find(strides, ptr);
    if !found return orig;
    ct := sc_get_one(sc_type(stride));
    pse_add_predicate(pse, sc_get_equal_predicate(stride, ct));
    return pse_get_scev(pse, ptr);
}

// getPtrStride(PSE, AccessTy, Ptr, Lp, DT, StridesMap, ShouldCheckWrap, Predicates)
laa_get_ptr_stride :: (pse: *Pse, li: *Loop_Info, access_ty: Type_Id, ptr: Value_Id, l: Loop_Id, dt: *Dom_Tree,
                       strides: *Table(Value_Id, Scev_Id), should_check_wrap: bool, preds: *[..] u32) -> (bool, s64) {
    ptr_scev := laa_replace_symbolic_stride_scev(pse, strides, ptr);
    if sc_is_loop_invariant(ptr_scev, l) return true, 0;
    ar := ptr_scev;
    if preds && !sc_is_addrec(ar) {
        ar = sc_convert_scev_to_add_rec_with_predicates(ptr_scev, l, preds);
        if ar == SCEV_CNC return false, 0;
    }
    if !sc_is_addrec(ar) return false, 0;
    ok, stride := laa_stride_from_add_rec(ar, l, access_ty);
    if !should_check_wrap || !ok return ok, stride;
    if laa_is_no_wrap(pse, li, ar, ptr, access_ty, l, dt, true, stride, preds) return true, stride;
    return false, 0;
}
// getPtrStride(..., Assume, ShouldCheckWrap)
laa_get_ptr_stride_assume :: (pse: *Pse, li: *Loop_Info, access_ty: Type_Id, ptr: Value_Id, l: Loop_Id, dt: *Dom_Tree,
                              strides: *Table(Value_Id, Scev_Id), assume: bool, should_check_wrap: bool) -> (bool, s64) {
    preds: [..] u32; preds.allocator = temp;
    ok, s := laa_get_ptr_stride(pse, li, access_ty, ptr, l, dt, strides, should_check_wrap, ifx assume then *preds else null);
    pse_add_predicates(pse, preds);
    return ok, s;
}

// areAccessesCompletelyBeforeOrAfter
mdc_completely_before_or_after :: (d: *Mdc, src: Scev_Id, src_ty: Type_Id, sink: Scev_Id, sink_ty: Type_Id) -> bool {
    btc := pse_get_backedge_taken_count(d.pse);
    smax := pse_get_symbolic_max_backedge_taken_count(d.pse);
    ss, se_ := laa_start_and_end_for_access(d.l, src, src_ty, btc, smax, *d.pointer_bounds, d.dt, d.ac, d.loop_guards);
    if sc_is_cnc(ss) || sc_is_cnc(se_) return false;
    ks, ke := laa_start_and_end_for_access(d.l, sink, sink_ty, btc, smax, *d.pointer_bounds, d.dt, d.ac, d.loop_guards);
    if sc_is_cnc(ks) || sc_is_cnc(ke) return false;
    g := laa_guards(d.loop_guards, d.l);
    src_end := sc_apply_loop_guards_with(se_, g);
    sink_start := sc_apply_loop_guards_with(ks, g);
    if sc_is_known_predicate(ICMP_ULE, src_end, sink_start) return true;
    sink_end := sc_apply_loop_guards_with(ke, g);
    src_start := sc_apply_loop_guards_with(ss, g);
    return sc_is_known_predicate(ICMP_ULE, sink_end, src_start);
}

Dep_Info :: struct {
    dist: Scev_Id;
    max_stride: u64;
    has_common_stride: bool;
    common_stride: u64;
    type_byte_size: u64;
    a_is_write: bool;
    b_is_write: bool;
}
// getDependenceDistanceStrideAndSize: (is_type, type, info)
mdc_dependence_distance_stride_and_size :: (d: *Mdc, li: *Loop_Info, a: Mai, a_inst_in: Value_Id, b: Mai, b_inst_in: Value_Id) -> (bool, Dep_Type, Dep_Info) {
    info: Dep_Info;
    a_inst := a_inst_in; b_inst := b_inst_in;
    a_ptr := mai_ptr(a); b_ptr := mai_ptr(b);
    a_w := mai_write(a); b_w := mai_write(b);
    if !a_w && !b_w return true, .NoDep, info;
    a_ty := load_store_type(a_inst); b_ty := load_store_type(b_inst);
    if ptr_addrspace(vtype(a_ptr)) != ptr_addrspace(vtype(b_ptr)) return true, .Unknown, info;
    preds: [..] u32; preds.allocator = temp;
    oka, sa := laa_get_ptr_stride(d.pse, li, a_ty, a_ptr, d.l, d.dt, d.symbolic_strides, true, *preds);
    okb, sb := laa_get_ptr_stride(d.pse, li, b_ty, b_ptr, d.l, d.dt, d.symbolic_strides, true, *preds);
    pse_add_predicates(d.pse, preds);
    src := pse_get_scev(d.pse, a_ptr);
    sink := pse_get_scev(d.pse, b_ptr);
    if oka && sa < 0 {
        t := src; src = sink; sink = t;
        ti := a_inst; a_inst = b_inst; b_inst = ti;
        tt := a_ty; a_ty = b_ty; b_ty = tt;
        to := oka; oka = okb; okb = to;
        ts := sa; sa = sb; sb = ts;
    }
    dist := sc_get_minus(sink, src);
    if !oka || !okb return true, .IndirectUnsafe, info;
    if sa == 0 || sb == 0 {
        if sa == 0 && sb == 0 && sc_is_zero(dist) return true, .InvariantUnsafe, info;
        return true, .Unknown, info;
    }
    if (sa > 0) != (sb > 0) return true, .Unknown, info;
    a_store := dl_type_store_size(a_ty); b_store := dl_type_store_size(b_ty);
    asz := dl_type_alloc_size(a_ty); bsz := dl_type_alloc_size(b_ty);
    type_byte_size: u64 = ifx a_store == b_store then bsz else 0;
    a_scaled := cast(u64) (ifx sa < 0 then -sa else sa) * asz;
    b_scaled := cast(u64) (ifx sb < 0 then -sb else sb) * bsz;
    info.max_stride = max(a_scaled, b_scaled);
    if a_scaled == b_scaled { info.has_common_stride = true; info.common_stride = a_scaled; }
    if !sc_is_const(dist) d.should_retry_with_runtime_checks |= sa == sb;
    if sc_is_cnc(dist) return true, .Unknown, info;
    info.dist = dist;
    info.type_byte_size = type_byte_size;
    info.a_is_write = a_w; info.b_is_write = b_w;
    return false, .NoDep, info;
}

// isDependent
mdc_is_dependent :: (d: *Mdc, li: *Loop_Info, a: Mai, a_idx: u32, b: Mai, b_idx: u32) -> Dep_Type {
    check_completely :: (d: *Mdc, a: Mai, a_idx: u32, b: Mai, b_idx: u32) -> bool {
        a_ty := load_store_type(d.inst_map[a_idx]);
        b_ty := load_store_type(d.inst_map[b_idx]);
        src := pse_get_scev(d.pse, mai_ptr(a));
        sink := pse_get_scev(d.pse, mai_ptr(b));
        return mdc_completely_before_or_after(d, src, a_ty, sink, b_ty);
    }
    is_type, t, info := mdc_dependence_distance_stride_and_size(d, li, a, d.inst_map[a_idx], b, d.inst_map[b_idx]);
    if is_type {
        if t == .Unknown && check_completely(d, a, a_idx, b, b_idx) return .NoDep;
        return t;
    }
    dist := info.dist;
    has_same_size := info.type_byte_size > 0;
    if has_same_size && laa_is_safe_dependence_distance(pse_get_symbolic_max_backedge_taken_count(d.pse), dist, info.max_stride) return .NoDep;
    has_ap_dist := sc_is_const(dist);
    const_dist: u64 = 0;
    if has_ap_dist {
        ad := ap_abs(sc_ap(dist));
        if !ap_fits_u64(ad) return .Unknown;
        const_dist = ap_zext_value(ad);
    }
    if has_ap_dist {
        if const_dist > 0 && info.has_common_stride && info.common_stride > 1 && has_same_size &&
           laa_strided_independent(const_dist, info.common_stride, info.type_byte_size) return .NoDep;
    } else {
        dist = sc_apply_loop_guards_with(dist, laa_guards(d.loop_guards, d.l));
    }
    if sc_is_known_non_positive(dist) {
        if sc_is_known_non_negative(dist) {
            if has_same_size return .Forward;
            return .Unknown;
        }
        is_true_data_dep := info.a_is_write && !info.b_is_write;
        if is_true_data_dep && laa_opts.forwarding_conflict_detection {
            if const_dist == 0 return ifx check_completely(d, a, a_idx, b, b_idx) then Dep_Type.NoDep else .Unknown;
            if !has_same_size || mdc_could_prevent_store_load_forward(d, const_dist, info.type_byte_size) return .ForwardButPreventsForwarding;
        }
        return .Forward;
    }
    mins := sc_signed_range_min(dist);
    if ap_min_signed_bits(mins) > 64 return .Unknown;
    min_distance := ap_sext_value(mins);
    if min_distance <= 0 return ifx check_completely(d, a, a_idx, b, b_idx) then Dep_Type.NoDep else .Unknown;
    if !has_same_size {
        if check_completely(d, a, a_idx, b, b_idx) return .NoDep;
        return .Unknown;
    }
    min_forced_factor := max(cast(u64) 1, cast(u64) laa_opts.force_vector_width);
    forced_unroll: u64 = ifx laa_opts.force_vector_interleave != 0 then cast(u64) laa_opts.force_vector_interleave else 1;
    min_num_iter := max(min_forced_factor * forced_unroll, 2);
    min_distance_needed := info.max_stride * (min_num_iter - 1) + info.type_byte_size;
    if min_distance_needed > cast(u64) min_distance {
        if const_dist == 0 return ifx check_completely(d, a, a_idx, b, b_idx) then Dep_Type.NoDep else .Unknown;
        return .Backward;
    }
    if min_distance_needed > d.min_dep_dist_bytes return .Backward;
    d.min_dep_dist_bytes = min(cast(u64) min_distance, d.min_dep_dist_bytes);
    is_true_data_dep := !info.a_is_write && info.b_is_write;
    if is_true_data_dep && laa_opts.forwarding_conflict_detection && const_dist != 0 &&
       mdc_could_prevent_store_load_forward(d, cast(u64) min_distance, info.type_byte_size, info.common_stride)
        return .BackwardVectorizableButPreventsForwarding;
    max_vf := d.min_dep_dist_bytes / info.max_stride;
    max_vf_in_bits := max_vf * info.type_byte_size * 8;
    if const_dist == 0 && max_vf_in_bits < d.max_target_vector_width_in_bits
        return ifx check_completely(d, a, a_idx, b, b_idx) then Dep_Type.NoDep else .Unknown;
    if check_completely(d, a, a_idx, b, b_idx) return .NoDep;
    d.max_safe_vector_width_in_bits = min(d.max_safe_vector_width_in_bits, max_vf_in_bits);
    return .BackwardVectorizable;
}

// areDepsSafe
mdc_are_deps_safe :: (d: *Mdc, li: *Loop_Info, dep_cands: *Eqc, check_deps: [] Mai) -> bool {
    d.min_dep_dist_bytes = 0xFFFF_FFFF_FFFF_FFFF;
    visited: Table(Mai, bool); visited.allocator = temp;
    for cur: check_deps {
        if table_contains(*visited, cur) continue;
        cls := eqc_class(dep_cands, cur);
        for ai_idx: 0..cls.count-1 {
            ai := cls[ai_idx];
            table_set(*visited, ai, true);
            ai_write := mai_write(ai);
            oi_idx := ifx ai_write then ai_idx else ai_idx + 1;
            while oi_idx < cls.count {
                oi := cls[oi_idx];
                acc := mdc_order_for_access(d, mai_ptr(ai), mai_write(ai));
                for i1: 0..acc.count-1 {
                    other := ifx oi_idx == ai_idx then acc else mdc_order_for_access(d, mai_ptr(oi), mai_write(oi));
                    start := ifx oi_idx == ai_idx then i1 + 1 else 0;
                    for i2: start..other.count-1 {
                        am := ai; ax := acc[i1];
                        bm := oi; bx := other[i2];
                        if ax > bx { tm := am; am = bm; bm = tm; tx := ax; ax = bx; bx = tx; }
                        t := mdc_is_dependent(d, li, am, ax, bm, bx);
                        mdc_merge_in_status(d, dep_is_safe_for_vectorization(t));
                        if d.record_dependences {
                            if t != .NoDep array_add(*d.dependences, .{ax, bx, t});
                            if d.dependences.count >= laa_opts.max_dependences {
                                d.record_dependences = false;
                                d.dependences.count = 0;
                            }
                        }
                        if !d.record_dependences && !mdc_is_safe_for_vectorization(d) return false;
                    }
                }
                oi_idx += 1;
            }
        }
    }
    return mdc_is_safe_for_vectorization(d);
}

// ---------------------------------------------------------------- RuntimePointerChecking

Rt_Pointer :: struct {        // PointerInfo
    ptr: Value_Id;
    start: Scev_Id;
    end: Scev_Id;
    is_write: bool;
    dep_set_id: u32;
    alias_set_id: u32;
    expr: Scev_Id;
    needs_freeze: bool;
}
Rt_Group :: struct {          // RuntimeCheckingPtrGroup
    high: Scev_Id;
    low: Scev_Id;
    members: [..] u32;
    addrspace: u32;
    needs_freeze: bool;
}
Rt_Diff_Check :: struct { src_start: Scev_Id; sink_start: Scev_Id; access_size: u64; needs_freeze: bool; }
Rpc :: struct {
    dc: *Mdc;
    need: bool;
    can_use_diff_check := true;
    pointers: [..] Rt_Pointer;
    groups: [..] Rt_Group;              // CheckingGroups
    checks: [..] [2] s32;               // pairs of group indices
    diff_checks: [..] Rt_Diff_Check;
}
rpc_reset :: (r: *Rpc) {
    r.need = false; r.can_use_diff_check = true;
    r.pointers.count = 0; r.checks.count = 0; r.diff_checks.count = 0; r.groups.count = 0;
}
rpc_group_new :: (r: *Rpc, index: u32) -> Rt_Group {
    g: Rt_Group;
    p := r.pointers[index];
    g.high = p.end; g.low = p.start;
    g.addrspace = ptr_addrspace(vtype(p.ptr));
    g.needs_freeze = p.needs_freeze;
    g.members.allocator = temp;
    array_add(*g.members, index);
    return g;
}
// RuntimePointerChecking::insert
rpc_insert :: (r: *Rpc, l: Loop_Id, ptr: Value_Id, ptr_expr: Scev_Id, access_ty: Type_Id, is_write: bool, dep_id: u32, as_id: u32, pse: *Pse, needs_freeze: bool) {
    smax := pse_get_symbolic_max_backedge_taken_count(pse);
    btc := pse_get_backedge_taken_count(pse);
    s, e := laa_start_and_end_for_access(l, ptr_expr, access_ty, btc, smax, *r.dc.pointer_bounds, r.dc.dt, r.dc.ac, r.dc.loop_guards);
    array_add(*r.pointers, .{ptr, s, e, is_write, dep_id, as_id, ptr_expr, needs_freeze});
}
// getMinFromExprs (SCEV_NULL = unknown)
laa_min_from_exprs :: (i: Scev_Id, j: Scev_Id) -> Scev_Id {
    ok, diff := sc_compute_constant_difference(j, i);
    if !ok return SCEV_NULL;
    return ifx ap_is_negative(diff) then j else i;
}
// RuntimeCheckingPtrGroup::addPointer
rpc_group_add_pointer :: (r: *Rpc, g: *Rt_Group, index: u32) -> bool {
    p := r.pointers[index];
    min0 := laa_min_from_exprs(p.start, g.low);
    if min0 == SCEV_NULL return false;
    min1 := laa_min_from_exprs(p.end, g.high);
    if min1 == SCEV_NULL return false;
    if min0 == p.start g.low = p.start;
    if min1 != p.end g.high = p.end;
    array_add(*g.members, index);
    g.needs_freeze |= p.needs_freeze;
    return true;
}
// needsChecking(I, J)
rpc_needs_checking :: (r: *Rpc, i: u32, j: u32) -> bool {
    a := r.pointers[i]; b := r.pointers[j];
    if !a.is_write && !b.is_write return false;
    if a.dep_set_id == b.dep_set_id return false;
    return a.alias_set_id == b.alias_set_id;
}
rpc_groups_need_checking :: (r: *Rpc, m: *Rt_Group, n: *Rt_Group) -> bool {
    for i: m.members for j: n.members if rpc_needs_checking(r, i, j) return true;
    return false;
}
// groupChecks
rpc_group_checks :: (r: *Rpc, dep_cands: *Eqc) {
    r.groups.count = 0;
    total_comparisons := 0;
    position: Table(Value_Id, [..] u32); position.allocator = temp;
    for p, idx: r.pointers {
        e := table_find_pointer(*position, p.ptr);
        if !e { l: [..] u32; l.allocator = temp; table_set(*position, p.ptr, l); e = table_find_pointer(*position, p.ptr); }
        array_add(e, cast(u32) idx);
    }
    seen: Table(u32, bool); seen.allocator = temp;
    for i: 0..r.pointers.count-1 {
        if table_contains(*seen, cast(u32) i) continue;
        access := mai(r.pointers[i].ptr, r.pointers[i].is_write);
        if !eqc_contains(dep_cands, access) { array_add(*r.groups, rpc_group_new(r, cast(u32) i)); continue; }
        groups: [..] Rt_Group; groups.allocator = temp;
        for m: eqc_class(dep_cands, access) {
            pi := table_find_pointer(*position, mai_ptr(m));
            if !pi continue;
            for ptr_idx: pi.* {
                merged := false;
                table_set(*seen, ptr_idx, true);
                for * g: groups {
                    if total_comparisons > laa_opts.memory_check_merge_threshold break;
                    total_comparisons += 1;
                    if rpc_group_add_pointer(r, g, ptr_idx) { merged = true; break; }
                }
                if !merged array_add(*groups, rpc_group_new(r, ptr_idx));
            }
        }
        for groups array_add(*r.groups, it);
    }
}
// tryToCreateDiffCheck
rpc_try_to_create_diff_check :: (r: *Rpc, cgi: *Rt_Group, cgj: *Rt_Group, li: *Loop_Info) -> bool {
    if cgi.members.count != 1 || cgj.members.count != 1 return false;
    dc := r.dc;
    src := *r.pointers[cgi.members[0]];
    sink := *r.pointers[cgj.members[0]];
    if mdc_order_for_access(dc, src.ptr, !src.is_write).count != 0 || mdc_order_for_access(dc, sink.ptr, !sink.is_write).count != 0 return false;
    acc_src := mdc_order_for_access(dc, src.ptr, src.is_write);
    acc_sink := mdc_order_for_access(dc, sink.ptr, sink.is_write);
    if acc_src.count != 1 || acc_sink.count != 1 return false;
    if acc_sink[0] < acc_src[0] { t := src; src = sink; sink = t; }
    inner := dc.l;
    se_ := src.expr; ke := sink.expr;
    if !sc_is_addrec(se_) || !sc_is_affine(se_) || sc_loop(se_) != inner || !sc_is_const(sc_op(se_, 1)) return false;
    step := sc_op(se_, 1);
    if !sc_is_addrec(ke) || !sc_is_affine(ke) || sc_loop(ke) != inner || sc_op(ke, 1) != step return false;
    src_start := sc_start(se_); sink_start := sc_start(ke);
    src_ty := load_store_type(dc.inst_map[mdc_order_for_access(dc, src.ptr, src.is_write)[0]]);
    dst_ty := load_store_type(dc.inst_map[mdc_order_for_access(dc, sink.ptr, sink.is_write)[0]]);
    if type_kind(src_ty) == .SVECTOR || type_kind(dst_ty) == .SVECTOR return false;
    alloc := max(dl_type_alloc_size(src_ty), dl_type_alloc_size(dst_ty));
    sap := ap_abs(sc_ap(step));
    if !(ap_fits_u64(sap) && ap_zext_value(sap) == alloc) return false;
    if ap_is_negative(sc_ap(step)) { t := sink_start; sink_start = src_start; src_start = t; }
    sink_int := sc_get_ptr_to_addr(sink_start);
    src_int := sc_get_ptr_to_addr(src_start);
    if sc_is_cnc(sink_int) || sc_is_cnc(src_int) return false;
    parent := li_parent(li, inner);
    if laa_opts.hoist_runtime_checks && parent != NONE && sc_is_addrec(sink_int) && sc_is_addrec(src_int) {
        if sc_loop(src_int) == sc_loop(sink_int) && sc_loop(src_int) == parent && sc_step_recurrence(src_int) != sc_step_recurrence(sink_int) return false;
    }
    array_add(*r.diff_checks, .{src_int, sink_int, alloc, src.needs_freeze || sink.needs_freeze});
    return true;
}
// generateChecks(DepCands)
rpc_generate_checks :: (r: *Rpc, dep_cands: *Eqc, li: *Loop_Info) {
    rpc_group_checks(r, dep_cands);
    for i: 0..r.groups.count-1 for j: i+1..r.groups.count-1 {
        if rpc_groups_need_checking(r, *r.groups[i], *r.groups[j]) {
            r.can_use_diff_check = r.can_use_diff_check && rpc_try_to_create_diff_check(r, *r.groups[i], *r.groups[j], li);
            array_add(*r.checks, .[cast(s32) i, cast(s32) j]);
        }
    }
}

// ---------------------------------------------------------------- AccessAnalysis

Laa_Access :: struct {        // one PtrAccessMap entry: MapVector<MemAccessInfo, SmallSetVector<Type *, 1>>
    key: Mai;
    types: [..] Type_Id;
}
Access_Analysis :: struct {
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    dep_cands: *Eqc;
    pse: *Pse;
    loop_alias_scopes: *[..] Md_Id;
    q: *Aa_Query;                       // BatchAAResults in cross-iteration mode
    ast: Alias_Set_Tracker;
    accesses: [..] Laa_Access;
    check_deps: [..] Mai;
    read_only_ptr: Table(Value_Id, bool);
    is_rt_check_analysis_needed: bool;
}
aa_access_find :: (list: *[..] Laa_Access, k: Mai) -> *Laa_Access {
    for * list.* if it.key == k return it;
    return null;
}
aa_access_insert :: (list: *[..] Laa_Access, k: Mai, ty: Type_Id, with_type := true) {
    e := aa_access_find(list, k);
    if !e {
        a: Laa_Access; a.key = k; a.types.allocator = temp;
        array_add(list, a);
        e = *list.*[list.count - 1];
    }
    if !with_type return;
    for e.types if it == ty return;
    array_add(*e.types, ty);
}
// adjustAliasScopeList
aacc_adjust_scope_list :: (a: *Access_Analysis, scope_list: Md_Id) -> Md_Id {
    if scope_list == NONE return NONE;
    n := md_nops(scope_list);
    for k: 0..cast(s64) n - 1 {
        sc := md_op(scope_list, cast(u32) k);
        for a.loop_alias_scopes.* if it == sc return NONE;
    }
    return scope_list;
}
// adjustLoc
aacc_adjust_loc :: (a: *Access_Analysis, loc_in: Mem_Loc) -> Mem_Loc {
    loc := loc_in;
    loc.size = LS_BEFORE_OR_AFTER;
    loc.tags.scope = aacc_adjust_scope_list(a, loc.tags.scope);
    loc.tags.noalias = aacc_adjust_scope_list(a, loc.tags.noalias);
    return loc;
}
aacc_add_load :: (a: *Access_Analysis, loc: Mem_Loc, ty: Type_Id, is_read_only: bool) {
    ast_add_memory_location(*a.ast, aacc_adjust_loc(a, loc), AST_NO_ACCESS);
    aa_access_insert(*a.accesses, mai(loc.ptr, false), ty);
    if is_read_only table_set(*a.read_only_ptr, loc.ptr, true);
}
aacc_add_store :: (a: *Access_Analysis, loc: Mem_Loc, ty: Type_Id) {
    ast_add_memory_location(*a.ast, aacc_adjust_loc(a, loc), AST_NO_ACCESS);
    aa_access_insert(*a.accesses, mai(loc.ptr, true), ty);
}
// AliasSet::getPointers
ast_set_pointers :: (s: *Alias_Set) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    for l: s.locs { seen := false; for r if it == l.ptr { seen = true; break; } if !seen array_add(*r, l.ptr); }
    return r;
}

// findForkedSCEVs: (scev, needs freeze) pairs
Forked_Scev :: struct { s: Scev_Id; freeze: bool; }
laa_find_forked_scevs :: (li: *Loop_Info, l: Loop_Id, ptr: Value_Id, out: *[..] Forked_Scev, depth_in: s64) {
    depth := depth_in;
    scev := sc_get_scev(ptr);
    if sc_is_addrec(scev) || li_is_loop_invariant(li, l, ptr) || !is_inst(ptr) || depth == 0 {
        array_add(out, .{scev, !is_guaranteed_not_to_be_undef_or_poison(ptr)});
        return;
    }
    depth -= 1;
    any_freeze :: (l: [] Forked_Scev) -> bool { for l if it.freeze return true; return false; }
    i := ptr;
    o := inst_op(i);
    if o == .GEP {
        src_ty := inst(i).ty2;
        if nops(i) != 2 || is_vector_type(src_ty) { array_add(out, .{scev, !is_guaranteed_not_to_be_undef_or_poison(i)}); return; }
        bases: [..] Forked_Scev; bases.allocator = temp;
        offs: [..] Forked_Scev; offs.allocator = temp;
        laa_find_forked_scevs(li, l, op(i, 0), *bases, depth);
        laa_find_forked_scevs(li, l, op(i, 1), *offs, depth);
        nf := any_freeze(bases) || any_freeze(offs);
        if offs.count == 2 && bases.count == 1 array_add(*bases, bases[0]);
        else if bases.count == 2 && offs.count == 1 array_add(*offs, offs[0]);
        else { array_add(out, .{scev, nf}); return; }
        int_ptr_ty := dl_index_type(vtype(op(i, 0)));   // getEffectiveSCEVType(pointer operand type)
        size := sc_get_size_of(int_ptr_ty, src_ty);
        for k: 0..1 {
            scaled := sc_get_mul2(size, sc_get_truncate_or_sign_extend(offs[k].s, int_ptr_ty));
            array_add(out, .{sc_get_add2(bases[k].s, scaled), nf});
        }
        return;
    }
    if o == .SELECT || o == .PHI {
        child: [..] Forked_Scev; child.allocator = temp;
        if o == .SELECT {
            laa_find_forked_scevs(li, l, op(i, 1), *child, depth);
            laa_find_forked_scevs(li, l, op(i, 2), *child, depth);
        } else if nops(i) == 2 {
            laa_find_forked_scevs(li, l, op(i, 0), *child, depth);
            laa_find_forked_scevs(li, l, op(i, 1), *child, depth);
        }
        if child.count == 2 { for child array_add(out, it); }
        else array_add(out, .{scev, !is_guaranteed_not_to_be_undef_or_poison(ptr)});
        return;
    }
    if o == .ADD || o == .SUB {
        ls: [..] Forked_Scev; ls.allocator = temp;
        rs: [..] Forked_Scev; rs.allocator = temp;
        laa_find_forked_scevs(li, l, op(i, 0), *ls, depth);
        laa_find_forked_scevs(li, l, op(i, 1), *rs, depth);
        nf := any_freeze(ls) || any_freeze(rs);
        if ls.count == 2 && rs.count == 1 array_add(*rs, rs[0]);
        else if rs.count == 2 && ls.count == 1 array_add(*ls, ls[0]);
        else { array_add(out, .{scev, nf}); return; }
        for k: 0..1 array_add(out, .{ifx o == .ADD then sc_get_add2(ls[k].s, rs[k].s) else sc_get_minus(ls[k].s, rs[k].s), nf});
        return;
    }
    array_add(out, .{scev, !is_guaranteed_not_to_be_undef_or_poison(ptr)});
}

// createCheckForAccess
aacc_create_check_for_access :: (a: *Access_Analysis, rt: *Rpc, access: Mai, access_ty: Type_Id, strides: *Table(Value_Id, Scev_Id),
                                 dep_set_id: *Table(Value_Id, u32), running_dep_id: *u32, as_id: u32, assume: bool) -> bool {
    ptr := mai_ptr(access);
    l := a.l;
    rt_ptrs: [..] Forked_Scev; rt_ptrs.allocator = temp;
    laa_find_forked_scevs(a.li, l, ptr, *rt_ptrs, laa_opts.max_forked_scev_depth);
    inv_or_ar :: (s: Scev_Id, l: Loop_Id) -> bool { return sc_is_loop_invariant(s, l) || sc_is_addrec(s); }
    if !(rt_ptrs.count == 2 && inv_or_ar(rt_ptrs[0].s, l) && inv_or_ar(rt_ptrs[1].s, l)) {
        rt_ptrs.count = 0;
        array_add(*rt_ptrs, .{laa_replace_symbolic_stride_scev(a.pse, strides, ptr), false});
    }
    preds: [..] u32; preds.allocator = temp;
    for * p: rt_ptrs {
        if sc_is_loop_invariant(p.s, l) continue;
        ar := p.s;
        if !sc_is_addrec(ar) && assume ar = pse_get_as_add_rec(a.pse, ptr, *preds);
        if ar == SCEV_NULL || !sc_is_addrec(ar) || !sc_is_affine(ar) return false;
        if rt_ptrs.count == 1 {
            pse_add_predicates(a.pse, preds);
            preds.count = 0;
            sar := laa_replace_symbolic_stride_scev(a.pse, strides, ptr);
            if sc_is_addrec(sar) ar = sar;
            p.s = ar;
        }
        if !laa_is_no_wrap(a.pse, a.li, ar, ifx rt_ptrs.count == 1 then ptr else NONE, access_ty, l, a.dt, false, 0, ifx assume then *preds else null)
            return false;
    }
    pse_add_predicates(a.pse, preds);
    for p: rt_ptrs {
        dep_id: u32;
        if eqc_contains(a.dep_cands, access) {
            leader := mai_ptr(eqc_find_leader(a.dep_cands, access));
            e := table_find_pointer(dep_set_id, leader);
            if !e { table_set(dep_set_id, leader, 0); e = table_find_pointer(dep_set_id, leader); }
            if e.* == 0 { e.* = running_dep_id.*; running_dep_id.* += 1; }
            dep_id = e.*;
        } else {
            dep_id = running_dep_id.*; running_dep_id.* += 1;
        }
        rpc_insert(rt, l, ptr, p.s, access_ty, mai_write(access), dep_id, as_id, a.pse, p.freeze);
    }
    return true;
}

// canCheckPtrAtRT: (can do rt if needed, uncomputable ptr)
aacc_can_check_ptr_at_rt :: (a: *Access_Analysis, rt: *Rpc, strides: *Table(Value_Id, Scev_Id), allow_partial: bool, dc: *Mdc) -> (bool, Value_Id) {
    uncomputable: Value_Id = NONE;
    can_do_rt := true;
    may_need := false;
    if !a.is_rt_check_analysis_needed return true, uncomputable;
    if dc.record_dependences {
        for dep: dc.dependences {
            if dep.type != .Unknown continue;
            s := dc.inst_map[dep.source]; d := dc.inst_map[dep.destination];
            eqc_erase_class(a.dep_cands, mai(load_store_pointer_operand(s), may_write_to_memory(s)));
            eqc_erase_class(a.dep_cands, mai(load_store_pointer_operand(d), may_write_to_memory(d)));
        }
    } else {
        a.check_deps.count = 0;
        eqc_clear(a.dep_cands);
    }
    as_id: u32 = 0;
    for * aset: a.ast.sets {
        if aset.removed continue;
        nreads := 0; nwrites := 0;
        can_do_set := true;
        as_id += 1;
        ptrs := ast_set_pointers(aset);
        running: u32 = 1;
        dep_set_id: Table(Value_Id, u32); dep_set_id.allocator = temp;
        Retry :: struct { access: Mai; ty: Type_Id; }
        retries: [..] Retry; retries.allocator = temp;
        infos: [..] Mai; infos.allocator = temp;
        for p: ptrs {
            w := aa_access_find(*a.accesses, mai(p, true)) != null;
            if w nwrites += 1; else nreads += 1;
            array_add(*infos, mai(p, w));
        }
        if nwrites == 0 || (nwrites == 1 && nreads == 0) continue;
        for acc: infos {
            e := aa_access_find(*a.accesses, acc);
            if !e { aa_access_insert(*a.accesses, acc, NONE, false); e = aa_access_find(*a.accesses, acc); }   // Accesses[Access]
            for ty: e.types {
                if !aacc_create_check_for_access(a, rt, acc, ty, strides, *dep_set_id, *running, as_id, false) {
                    array_add(*retries, .{acc, ty});
                    can_do_set = false;
                }
            }
        }
        needs := running > 2 || retries.count > 0;
        if needs && !can_do_set {
            can_do_set = true;
            for r: retries {
                if !aacc_create_check_for_access(a, rt, r.access, r.ty, strides, *dep_set_id, *running, as_id, true) {
                    can_do_set = false;
                    uncomputable = mai_ptr(r.access);
                    if !allow_partial break;
                }
            }
        }
        can_do_rt &= can_do_set;
        may_need |= needs;
        as_id += 1;
    }
    n := rt.pointers.count;
    for i: 0..n-1 for j: i+1..n-1 {
        if rt.pointers[i].dep_set_id == rt.pointers[j].dep_set_id continue;
        if rt.pointers[i].alias_set_id != rt.pointers[j].alias_set_id continue;
        if ptr_addrspace(vtype(rt.pointers[i].ptr)) != ptr_addrspace(vtype(rt.pointers[j].ptr)) return false, uncomputable;
    }
    if may_need && (can_do_rt || allow_partial) rpc_generate_checks(rt, a.dep_cands, a.li);
    rt.need = ifx can_do_rt then rt.checks.count != 0 else may_need;
    can_if_needed := !rt.need || can_do_rt;
    if !can_if_needed && !allow_partial rpc_reset(rt);
    return can_if_needed, uncomputable;
}

// getUnderlyingObjects(V, Objects, LI)
get_underlying_objects_li :: (v: Value_Id, out: *[..] Value_Id, li: *Loop_Info) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, v);
    while work.count {
        p := get_underlying_object(pop(*work));
        if table_contains(*visited, p) continue;
        table_set(*visited, p, true);
        if is_inst(p) && inst_op(p) == .SELECT { array_add(*work, op(p, 1)); array_add(*work, op(p, 2)); continue; }
        if is_inst(p) && inst_op(p) == .PHI {
            if !li_is_loop_header(li, inst_block(p)) || laa_same_underlying_object_in_loop(p, li) {
                n := nops(p);
                for k: 0..cast(s64) n - 1 array_add(*work, op(p, cast(u32) k));
            } else array_add(out, p);
            continue;
        }
        array_add(out, p);
    }
}
// isSameUnderlyingObjectInLoop
laa_same_underlying_object_in_loop :: (pn: Value_Id, li: *Loop_Info) -> bool {
    l := li_loop_for(li, inst_block(pn));
    if nops(pn) != 2 return true;
    prev := op(pn, 0);
    if !is_inst(prev) || li_loop_for(li, inst_block(prev)) != l prev = op(pn, 1);
    if !is_inst(prev) || li_loop_for(li, inst_block(prev)) != l return true;
    if inst_op(prev) == .LOAD && !li_is_loop_invariant(li, l, op(prev, 0)) return false;
    return true;
}

// buildDependenceSets
aacc_build_dependence_sets :: (a: *Access_Analysis) {
    for * aset: a.ast.sets {
        if aset.removed continue;
        has_write := false;
        obj_to_last: Table(u64, Mai); obj_to_last.allocator = temp;   // (underlying object, address space) -> access
        deferred: [..] Laa_Access; deferred.allocator = temp;
        ptrs := ast_set_pointers(aset);
        for use_deferred: 0..1 {
            s := ifx use_deferred then *deferred else *a.accesses;
            for p: ptrs {
                for k: 0..s.count-1 {
                    key := s.*[k].key;
                    if mai_ptr(key) != p continue;
                    is_write := mai_write(key);
                    is_ro := table_contains(*a.read_only_ptr, p) && !is_write;
                    if use_deferred && !is_ro continue;
                    access := mai(p, is_write);
                    eqc_insert(a.dep_cands, access);
                    if !use_deferred && is_ro { aa_access_insert(*deferred, access, NONE, false); continue; }
                    if (is_write || is_ro) && has_write {
                        array_add(*a.check_deps, access);
                        a.is_rt_check_analysis_needed = true;
                    }
                    if is_write has_write = true;
                    uos: [..] Value_Id; uos.allocator = temp;
                    get_underlying_objects_li(p, *uos, a.li);
                    for uo: uos {
                        if vkind(uo) == .C_NULL && !null_pointer_is_defined(a.li.fn, ptr_addrspace(vtype(uo))) continue;
                        okey := ((cast(u64) uo) << 32) | cast(u64) ptr_addrspace(vtype(p));
                        found, last := table_find(*obj_to_last, okey);
                        if found eqc_union(a.dep_cands, access, last);
                        table_set(*obj_to_last, okey, access);
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------- LoopAccessInfo

Laa :: struct {
    l: Loop_Id;
    li: *Loop_Info;
    dt: *Dom_Tree;
    ac: *Assumption_Cache;
    aar: Aa_Results;
    tli: *Tli;
    pse: Pse;
    dc: Mdc;
    rt: Rpc;
    loop_guards: Laa_Loop_Guards;
    symbolic_strides: Table(Value_Id, Scev_Id);
    allow_partial: bool;
    can_vec_mem: bool;
    has_convergent_op: bool;
    has_complete_ptr_rt_checking: bool;
    report: string;                     // the remark message ("" = none)
    has_report: bool;
    num_loads: u32;
    num_stores: u32;
    stores_to_invariant_addresses: [..] Value_Id;
    has_store_store_dep_inv: bool;      // HasStoreStoreDependenceInvolvingLoopInvariantAddress
    has_load_store_dep_inv: bool;       // HasLoadStoreDependenceInvolvingLoopInvariantAddress
}
laa_record_analysis :: (a: *Laa, msg: string) { a.has_report = true; a.report = msg; }

// LoopAccessInfo::isInvariant
laa_is_invariant :: (a: *Laa, v: Value_Id) -> bool {
    if li_is_loop_invariant(a.li, a.l, v) return true;
    if !sc_is_scevable(vtype(v)) return false;
    return sc_is_loop_invariant(sc_get_scev(v), a.l);
}

// getLoopVariantGEPOperand
laa_loop_variant_gep_operand :: (ptr: Value_Id, l: Loop_Id) -> Value_Id {
    if !is_inst(ptr) || inst_op(ptr) != .GEP return ptr;
    v := ptr;
    n := nops(ptr);
    for k: 0..cast(s64) n - 1 {
        u := op(ptr, cast(u32) k);
        if !sc_is_loop_invariant(sc_get_scev(u), l) {
            if v == ptr v = u;
            else return ptr;
        }
    }
    return v;
}
// getStrideFromPointer (SCEV_NULL = none)
laa_stride_from_pointer :: (ptr_in: Value_Id, l: Loop_Id) -> Scev_Id {
    if type_kind(vtype(ptr_in)) != .PTR return SCEV_NULL;
    orig := ptr_in;
    ptr := laa_loop_variant_gep_operand(ptr_in, l);
    v := sc_get_scev(ptr);
    if ptr != orig { while sc_is_integral_cast(v) v = sc_op(v, 0); }
    if !sc_is_addrec(v) || !sc_is_affine(v) || sc_loop(v) != l return SCEV_NULL;
    v = sc_op(v, 1);
    if !sc_is_loop_invariant(v, l) return SCEV_NULL;
    if sc_is_unknown(v) return v;
    if sc_is_mul(v) && sc_nops(v) == 2 && sc_is_const(sc_op(v, 0)) v = sc_op(v, 1);
    if sc_is_integral_cast(v) && sc_is_unknown(sc_op(v, 0)) return v;
    return SCEV_NULL;
}
// collectStridedAccess
laa_collect_strided_access :: (a: *Laa, mem: Value_Id) {
    ptr := load_store_pointer_operand(mem);
    if ptr == NONE return;
    stride := laa_stride_from_pointer(ptr, a.l);
    if stride == SCEV_NULL return;
    if sc_is_unknown(stride) && is_undef_value(sc_value(stride)) return;   // m_scev_UndefOrPoison
    if !laa_opts.speculate_unit_stride return;
    max_btc := pse_get_symbolic_max_backedge_taken_count(*a.pse);
    stride_bits := dl_type_size_bits(sc_type(stride));
    be_bits := dl_type_size_bits(sc_type(max_btc));
    casted_stride := stride; casted_be := max_btc;
    if be_bits >= stride_bits casted_stride = sc_get_noop_or_sign_extend(stride, sc_type(max_btc));
    else casted_be = sc_get_zero_extend(max_btc, sc_type(stride));
    if sc_is_known_positive(sc_get_minus(casted_stride, casted_be)) return;
    base := stride;
    if sc_is_integral_cast(base) base = sc_op(base, 0);
    table_set(*a.symbolic_strides, ptr, base);
}

// canAnalyzeLoop
laa_can_analyze_loop :: (a: *Laa) -> bool {
    if li_subloops(a.li, a.l).count != 0 { laa_record_analysis(a, "loop is not the innermost loop"); return false; }
    if li_num_back_edges(a.li, a.l) != 1 { laa_record_analysis(a, "loop control flow is not understood by analyzer"); return false; }
    if sc_is_cnc(pse_get_symbolic_max_backedge_taken_count(*a.pse)) {
        laa_record_analysis(a, "could not determine number of loop iterations");
        return false;
    }
    return true;
}

// isTriviallyVectorizable (VectorUtils.cpp)
TRIVIALLY_VECTORIZABLE :: string.[
    "llvm.abs", "llvm.bswap", "llvm.bitreverse", "llvm.ctpop", "llvm.ctlz", "llvm.cttz", "llvm.fshl", "llvm.fshr",
    "llvm.smax", "llvm.smin", "llvm.umax", "llvm.umin", "llvm.sadd.sat", "llvm.ssub.sat", "llvm.uadd.sat",
    "llvm.usub.sat", "llvm.smul.fix", "llvm.smul.fix.sat", "llvm.umul.fix", "llvm.umul.fix.sat",
    "llvm.uadd.with.overflow", "llvm.sadd.with.overflow", "llvm.usub.with.overflow", "llvm.ssub.with.overflow",
    "llvm.umul.with.overflow", "llvm.smul.with.overflow", "llvm.sqrt", "llvm.asin", "llvm.acos", "llvm.atan",
    "llvm.atan2", "llvm.sin", "llvm.cos", "llvm.sincos", "llvm.sincospi", "llvm.tan", "llvm.sinh", "llvm.cosh",
    "llvm.tanh", "llvm.exp", "llvm.exp10", "llvm.exp2", "llvm.frexp", "llvm.ldexp", "llvm.log", "llvm.log10",
    "llvm.log2", "llvm.fabs", "llvm.minnum", "llvm.maxnum", "llvm.minimum", "llvm.maximum", "llvm.minimumnum",
    "llvm.maximumnum", "llvm.modf", "llvm.copysign", "llvm.floor", "llvm.ceil", "llvm.trunc", "llvm.rint",
    "llvm.nearbyint", "llvm.round", "llvm.roundeven", "llvm.pow", "llvm.fma", "llvm.fmuladd", "llvm.is.fpclass",
    "llvm.powi", "llvm.canonicalize", "llvm.fptosi.sat", "llvm.fptoui.sat", "llvm.lround", "llvm.llround",
    "llvm.lrint", "llvm.llrint", "llvm.ucmp", "llvm.scmp", "llvm.clmul"];
// getIntrinsicForCallSite's library-function table (ValueTracking.cpp): f / l suffixes map to the same intrinsic
LIBFUNC_INTRINSICS :: string.["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp",
    "exp2", "exp10", "log", "log10", "log2", "fabs", "copysign", "floor", "ceil", "trunc", "rint", "nearbyint",
    "round", "roundeven", "pow", "sqrt"];
// getVectorIntrinsicIDForCall: true when the call is not a real memory access for LAA
laa_is_vector_intrinsic_call :: (c: Value_Id, tli: *Tli) -> bool {
    f := call_called_function(c);
    if f == NONE return false;
    name: string;
    if glob(f).intrinsic {
        if fn_iid(f) == 0 return false;
        name = iid_name(fn_iid(f));
    }
    else {
        if is_local_linkage(glob(f).linkage) return false;
        ok, lf := tli_lookup_call(c);
        if !ok || !call_only_reads_memory(c) return false;
        n := tli_func_name(tli, lf);
        base := n;
        if n == "fmin" || n == "fminf" || n == "fminl" return true;   // minnum
        if n == "fmax" || n == "fmaxf" || n == "fmaxl" return true;   // maxnum
        found := false;
        for LIBFUNC_INTRINSICS {
            if n == it || n == tprint("%f", it) || n == tprint("%l", it) { found = true; break; }
        }
        return found;   // every mapped intrinsic is trivially vectorizable
    }
    for TRIVIALLY_VECTORIZABLE if name == it return true;
    id := fn_iid(f);
    return id == IID_LIFETIME_START || id == IID_LIFETIME_END || id == IID_ASSUME || id == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL ||
           id == IID_SIDEEFFECT || id == IID_PSEUDOPROBE;
}

// analyzeLoop
laa_analyze_loop :: (a: *Laa) -> bool {
    loads: [..] Value_Id; loads.allocator = temp;
    stores: [..] Value_Id; stores.allocator = temp;
    loop_alias_scopes: [..] Md_Id; loop_alias_scopes.allocator = temp;
    num_reads := 0; num_read_writes := 0;
    has_complex := false;
    a.has_convergent_op = false;
    a.rt.pointers.count = 0;
    a.rt.need = false;
    is_parallel := li_is_annotated_parallel(a.li, a.l);
    versioning := laa_opts.enable_mem_access_versioning && !fn_has_opt_size(a.li.fn);
    rpo: [..] Value_Id; rpo.allocator = temp;
    loop_blocks_rpo(a.li, a.l, *rpo);
    for bb: rpo for i: block_insts(bb) {
        if is_call_base(i) && call_is_convergent(i) a.has_convergent_op = true;
        if has_complex && a.has_convergent_op return false;
        if has_complex continue;
        if call_iid(i) == IID_EXPERIMENTAL_NOALIAS_SCOPE_DECL {
            md := ir.v_aux[call_arg(i, 0)];   // the MetadataAsValue scope list
            n := md_nops(md);
            for k: 0..cast(s64) n - 1 array_add(*loop_alias_scopes, md_op(md, cast(u32) k));
        }
        is_call := inst_op(i) == .CALL;
        if is_call && laa_is_vector_intrinsic_call(i, a.tli) continue;
        if may_read_from_memory(i) {
            if is_call && !call_is_no_builtin(i) && call_called_function(i) != NONE {
                has_ptr_args := false;
                for k: 0..cast(s64) call_num_args(i) - 1 if type_kind(vtype(call_arg(i, cast(u32) k))) == .PTR has_ptr_args = true;
                if !has_ptr_args && call_has_vector_variants(i) continue;
            }
            if inst_op(i) != .LOAD { laa_record_analysis(a, "instruction cannot be vectorized"); has_complex = true; continue; }
            if !inst_is_simple(i) && !is_parallel { laa_record_analysis(a, "read with atomic ordering or volatile read"); has_complex = true; continue; }
            a.num_loads += 1;
            array_add(*loads, i);
            mdc_add_access(*a.dc, a.li, i);
            if versioning laa_collect_strided_access(a, i);
            continue;
        }
        if may_write_to_memory(i) {
            if inst_op(i) != .STORE { laa_record_analysis(a, "instruction cannot be vectorized"); has_complex = true; continue; }
            if !inst_is_simple(i) && !is_parallel { laa_record_analysis(a, "write with atomic ordering or volatile write"); has_complex = true; continue; }
            a.num_stores += 1;
            array_add(*stores, i);
            mdc_add_access(*a.dc, a.li, i);
            if versioning laa_collect_strided_access(a, i);
        }
    }
    if has_complex return false;
    if stores.count == 0 return true;
    dep_cands: Eqc; eqc_init(*dep_cands);
    acc: Access_Analysis;
    acc.l = a.l; acc.li = a.li; acc.dt = a.dt; acc.dep_cands = *dep_cands; acc.pse = *a.pse;
    acc.loop_alias_scopes = *loop_alias_scopes;
    acc.q = aa_query_new(*a.aar);
    acc.q.may_be_cross_iteration = true;   // enableCrossIterationMode
    ast_init(*acc.ast, acc.q);
    acc.accesses.allocator = temp; acc.check_deps.allocator = temp; acc.read_only_ptr.allocator = temp;
    seen: [..] [2] u32; seen.allocator = temp;   // SmallSet<(Value *, Type *)>
    seen_insert :: (s: *[..] [2] u32, p: Value_Id, t: Type_Id) -> bool { for s.* if it[0] == p && it[1] == t return false; array_add(s, .[p, t]); return true; }
    uniform_stores: Table(Value_Id, bool); uniform_stores.allocator = temp;
    for st: stores {
        ptr := op(st, 1);
        if laa_is_invariant(a, ptr) {
            array_add(*a.stores_to_invariant_addresses, st);
            if table_contains(*uniform_stores, ptr) a.has_store_store_dep_inv = true;
            table_set(*uniform_stores, ptr, true);
        }
        ty := load_store_type(st);
        if seen_insert(*seen, ptr, ty) {
            num_read_writes += 1;
            loc := mloc_get(st);
            if laa_block_needs_predication(inst_block(st), a.li, a.l, a.dt) loc.tags.tbaa = NONE;
            ptrs: [..] Value_Id; ptrs.allocator = temp;
            laa_visit_pointers(loc.ptr, a.li, a.l, *ptrs);
            for p: ptrs { nl := loc; nl.ptr = p; aacc_add_store(*acc, nl, ty); }
        }
    }
    if is_parallel return true;
    for ld: loads {
        ptr := op(ld, 0);
        is_ro := false;
        ty := load_store_type(ld);
        if seen_insert(*seen, ptr, ty) { num_reads += 1; is_ro = true; }
        else {
            ok, _ := laa_get_ptr_stride_assume(*a.pse, a.li, ty, ptr, a.l, a.dt, *a.symbolic_strides, false, true);
            if !ok { num_reads += 1; is_ro = true; }
        }
        if table_contains(*uniform_stores, ptr) a.has_load_store_dep_inv = true;
        loc := mloc_get(ld);
        if laa_block_needs_predication(inst_block(ld), a.li, a.l, a.dt) loc.tags.tbaa = NONE;
        ptrs: [..] Value_Id; ptrs.allocator = temp;
        laa_visit_pointers(loc.ptr, a.li, a.l, *ptrs);
        for p: ptrs { nl := loc; nl.ptr = p; aacc_add_load(*acc, nl, ty, is_ro); }
    }
    if num_read_writes == 1 && num_reads == 0 return true;
    aacc_build_dependence_sets(*acc);
    ok, unc := aacc_can_check_ptr_at_rt(*acc, *a.rt, *a.symbolic_strides, a.allow_partial, *a.dc);
    a.has_complete_ptr_rt_checking = ok;
    if !ok { laa_record_analysis(a, "cannot identify array bounds"); return false; }
    deps_safe := true;
    if acc.check_deps.count != 0 {
        deps_safe = mdc_are_deps_safe(*a.dc, a.li, *dep_cands, acc.check_deps);
        if !deps_safe && mdc_should_retry_with_runtime_checks(*a.dc) {
            rpc_reset(*a.rt);
            a.rt.need = true;
            ok2, unc2 := aacc_can_check_ptr_at_rt(*acc, *a.rt, *a.symbolic_strides, a.allow_partial, *a.dc);
            a.has_complete_ptr_rt_checking = ok2;
            if !ok2 { laa_record_analysis(a, "cannot check memory dependencies at runtime"); return false; }
            acc.check_deps.count = 0;          // resetDepChecks
            a.dc.dependences.count = 0;
            deps_safe = true;
        }
    }
    if a.dc.record_dependences {
        for dep: a.dc.dependences {
            if dep.type != .InvariantUnsafe continue;
            s := a.dc.inst_map[dep.source]; d := a.dc.inst_map[dep.destination];
            if (inst_op(s) == .LOAD) != (inst_op(d) == .LOAD) a.has_load_store_dep_inv = true;
            else a.has_store_store_dep_inv = true;
        }
    }
    if a.has_convergent_op { laa_record_analysis(a, "cannot add control dependency to convergent operation"); return false; }
    if deps_safe return true;
    laa_emit_unsafe_dependence_remark(a);
    return false;
}

// emitUnsafeDependenceRemark
laa_emit_unsafe_dependence_remark :: (a: *Laa) {
    if !a.dc.record_dependences return;
    found := -1;
    for dep, k: a.dc.dependences if dep_is_safe_for_vectorization(dep.type) != .SAFE { found = k; break; }
    if found < 0 return;
    dep := a.dc.dependences[found];
    forced := false;
    md := li_find_string_metadata_operand(a.li, a.l, "llvm.loop.distribute.enable");
    if md != NONE forced = const_int_zext(md) != 0;
    sb: String_Builder; sb.allocator = temp;
    if forced append(*sb, "unsafe dependent memory operations in loop.");
    else append(*sb, "unsafe dependent memory operations in loop. Use #pragma clang loop distribute(enable) to allow loop distribution to attempt to isolate the offending operations into a separate loop");
    if dep.type == {
        case .Backward; append(*sb, "\nBackward loop carried data dependence.");
        case .ForwardButPreventsForwarding; append(*sb, "\nForward loop carried data dependence that prevents store-to-load forwarding.");
        case .BackwardVectorizableButPreventsForwarding; append(*sb, "\nBackward loop carried data dependence that prevents store-to-load forwarding.");
        case .IndirectUnsafe; append(*sb, "\nUnsafe indirect dependence.");
        case .InvariantUnsafe; append(*sb, "\nUnsafe dependence on loop-invariant address.");
        case .Unknown; append(*sb, "\nUnknown data dependence.");
    }
    src := a.dc.inst_map[dep.source];
    loc := get_metadata(src, 0);
    pd := load_store_pointer_operand(src);
    if pd != NONE && is_inst(pd) loc = get_metadata(pd, 0);
    if loc != NONE { append(*sb, " Memory location is the same as accessed at "); append(*sb, diloc_remark_string(loc)); }
    laa_record_analysis(a, builder_to_string(*sb));
}
// DebugLoc as printed by ore::NV("Location", DL): "<file>:<line>:<col>"
diloc_remark_string :: (loc: Md_Id) -> string {
    scope := diloc_scope(loc);
    file := ifx is_di(scope, .FILE) then scope else di_op(scope, 0);
    name := "";
    if file != NONE { fname := di_op(file, 0); if fname != NONE name = ir.mds[fname].str; }
    r := tprint("%:%", name, diloc_line(loc));
    if diloc_col(loc) != 0 r = tprint("%:%", r, diloc_col(loc));
    ia := diloc_inlined_at(loc);
    if ia != NONE r = tprint("% @[ % ]", r, diloc_remark_string(ia));
    return r;
}
// findStringMetadataForLoop(L, Name): the first operand after the name (a ConstantInt here), NONE if absent
li_find_string_metadata_operand :: (li: *Loop_Info, l: Loop_Id, name: string) -> Value_Id {
    id := li_loop_id(li, l);
    if id == NONE return NONE;
    n := md_nops(id);
    for k: 1..cast(s64) n - 1 {
        m := md_op(id, cast(u32) k);
        if m == NONE || !md_is_node(m) || md_nops(m) == 0 continue;
        s := md_op(m, 0);
        if s == NONE || ir.mds[s].kind != .STRING || ir.mds[s].str != name continue;
        if md_nops(m) < 2 return NONE;
        v := md_op(m, 1);
        if ir.mds[v].kind != .VALUE return NONE;
        return ir.mds[v].value;
    }
    return NONE;
}

// LoopAccessInfo::LoopAccessInfo
laa_compute :: (a: *Laa, l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, allow_partial := false) {
    f := li.fn;
    a.l = l; a.li = li; a.dt = dt; a.ac = ac;
    a.aar = aa_results_for(f);
    a.tli = tli_for(f);
    a.allow_partial = allow_partial;
    pse_init(*a.pse, l);
    a.symbolic_strides.allocator = temp;
    a.stores_to_invariant_addresses.allocator = temp;
    tti := tti_get(f);
    max_width: u64 = 0xFFFF_FFFF;
    // TTI->enableScalableVectorization() is false for X86 and NoTTI
    max_width = tti_fixed_vector_register_bit_width(tti) * 2;
    d := *a.dc;
    d.pse = *a.pse; d.ac = ac; d.dt = dt; d.l = l; d.symbolic_strides = *a.symbolic_strides;
    d.max_target_vector_width_in_bits = max_width;
    d.loop_guards = *a.loop_guards;
    d.accesses.allocator = temp; d.inst_map.allocator = temp; d.dependences.allocator = temp; d.pointer_bounds.allocator = temp;
    a.rt.dc = d;
    a.rt.pointers.allocator = temp; a.rt.groups.allocator = temp; a.rt.checks.allocator = temp; a.rt.diff_checks.allocator = temp;
    if laa_can_analyze_loop(a) a.can_vec_mem = laa_analyze_loop(a);
}
// TTI::getRegisterBitWidth(RGK_FixedWidthVector)
tti_fixed_vector_register_bit_width :: (t: *Tti) -> u64 {
    if t.kind != .X86 return 32;
    st := *t.xl;
    pvw := st_getPreferVectorWidth(st);
    if st_hasAVX512(st) && pvw >= 512 return 512;
    if st_hasAVX(st) && pvw >= 256 return 256;
    if st_hasSSE1(st) && pvw >= 128 return 128;
    return 0;
}

// ---------------------------------------------------------------- printing (LoopAccessInfo::print, print<access-info>)

laa_value_print :: (v: Value_Id) -> string {
    if is_inst(v) return inst_to_string(v);   // starts with two spaces, like Instruction::print
    if vkind(v) == .ARGUMENT return value_as_operand_typed(v);
    if vkind(v) == .GLOBAL_VAR {
        // Value::print of a GlobalVariable: AssemblyWriter::printGlobal (without the trailing newline)
        start := W.buf.count;
        print_global(v);
        g := copy_string(slice_of_buf(start),, allocator = temp);
        W.buf.count = start;
        while g.count && g[g.count - 1] == #char "\n" g.count -= 1;
        return g;
    }
    fatal("loop-accesses: printing a non-instruction pointer is not supported yet");
    return "";
}
laa_indent :: (sb: *String_Builder, n: s64) { for 1..n append(sb, " "); }
laa_print :: (sb: *String_Builder, a: *Laa, depth: s64) {
    d := *a.dc;
    if a.can_vec_mem {
        laa_indent(sb, depth); append(sb, "Memory dependences are safe");
        if d.max_safe_vector_width_in_bits != 0xFFFF_FFFF print_to_builder(sb, " with a maximum safe vector width of % bits", d.max_safe_vector_width_in_bits);
        if d.max_store_load_forward_safe_distance_in_bits != 0xFFFF_FFFF_FFFF_FFFF
            print_to_builder(sb, ", with a maximum safe store-load forward width of % bits", d.max_store_load_forward_safe_distance_in_bits);
        if a.rt.need append(sb, " with run-time checks");
        append(sb, "\n");
    }
    if a.has_convergent_op { laa_indent(sb, depth); append(sb, "Has convergent operation in loop\n"); }
    if a.has_report { laa_indent(sb, depth); append(sb, "Report: "); append(sb, a.report); append(sb, "\n"); }
    if d.record_dependences {
        laa_indent(sb, depth); append(sb, "Dependences:\n");
        for dep: d.dependences {
            laa_indent(sb, depth + 2); print_to_builder(sb, "%:\n", dep.type);
            laa_indent(sb, depth + 4); append(sb, laa_value_print(d.inst_map[dep.source])); append(sb, " -> \n");
            laa_indent(sb, depth + 4); append(sb, laa_value_print(d.inst_map[dep.destination])); append(sb, "\n");
            append(sb, "\n");
        }
    } else { laa_indent(sb, depth); append(sb, "Too many dependences, not recorded\n"); }
    // RuntimePointerChecking::print
    r := *a.rt;
    laa_indent(sb, depth); append(sb, "Run-time memory checks:\n");
    for c, n: r.checks {
        laa_indent(sb, depth); print_to_builder(sb, "Check %:\n", n);
        laa_indent(sb, depth + 2); print_to_builder(sb, "Comparing group GRP%:\n", c[0]);
        for k: r.groups[c[0]].members { laa_indent(sb, depth + 2); append(sb, laa_value_print(r.pointers[k].ptr)); append(sb, "\n"); }
        laa_indent(sb, depth + 2); print_to_builder(sb, "Against group GRP%:\n", c[1]);
        for k: r.groups[c[1]].members { laa_indent(sb, depth + 2); append(sb, laa_value_print(r.pointers[k].ptr)); append(sb, "\n"); }
    }
    laa_indent(sb, depth); append(sb, "Grouped accesses:\n");
    for g, gi: r.groups {
        laa_indent(sb, depth + 2); print_to_builder(sb, "Group GRP%:\n", gi);
        laa_indent(sb, depth + 4); append(sb, "(Low: "); sc_print(sb, g.low); append(sb, " High: "); sc_print(sb, g.high); append(sb, ")\n");
        for m: g.members { laa_indent(sb, depth + 6); append(sb, "Member: "); sc_print(sb, r.pointers[m].expr); append(sb, "\n"); }
    }
    if r.need && !a.has_complete_ptr_rt_checking { laa_indent(sb, depth); append(sb, "Generated run-time checks are incomplete\n"); }
    append(sb, "\n");
    laa_indent(sb, depth);
    print_to_builder(sb, "Non vectorizable stores to invariant address were %found in loop.\n", ifx a.has_store_store_dep_inv || a.has_load_store_dep_inv then "" else "not ");
    laa_indent(sb, depth); append(sb, "SCEV assumptions:\n");
    for a.pse.preds sc_pred_print(sb, it, depth);
    append(sb, "\n");
    laa_indent(sb, depth); append(sb, "Expressions re-written:\n");
    pse_print(sb, *a.pse, a.li, depth);
}

// LoopAccessInfoPrinterPass::run (print<access-info>)
access_info_printer_run :: (f: Value_Id, name: string) -> Preserved {
    // parseLoopAccessInfoPrinterOptions: "allow-partial" / "no-allow-partial"
    allow_partial := false;
    if name != "print<access-info>" {
        params := slice(name, 19, name.count - 20);
        for p: split(params, ";") {
            if p == "allow-partial" allow_partial = true;
            else if p == "no-allow-partial" allow_partial = false;
            else fatal("invalid LoopAccessInfoPrinter pass parameter '%'", p);
        }
    }
    li := get_loop_info(f);
    dt := get_domtree(f);
    ac := get_assumption_cache(f);
    se = get_scev(f);
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "Printing analysis 'Loop Access Analysis' for function '%':\n", vname(f));
    w: Loop_Worklist;
    lwl_init(*w);
    append_loops_to_worklist_li(li, *w);
    while !lwl_empty(*w) {
        l := lwl_pop(*w);
        laa_indent(*sb, 2); print_to_builder(*sb, "%:\n", vname(li_header(li, l)));
        // LoopAccessInfoManager::getInfo: one LoopAccessInfo per loop, computed once
        a := laa_cached_info(f, l, li, dt, ac, allow_partial);
        laa_print(*sb, a, 4);
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
    return PRESERVE_ALL;
}
// The LoopAccessAnalysis result of this printer run (the printer is the only user so far: a fresh manager per run)
laa_cached_info :: (f: Value_Id, l: Loop_Id, li: *Loop_Info, dt: *Dom_Tree, ac: *Assumption_Cache, allow_partial: bool) -> *Laa {
    a := New(Laa,, allocator = temp);
    laa_compute(a, l, li, dt, ac, allow_partial);
    return a;
}
