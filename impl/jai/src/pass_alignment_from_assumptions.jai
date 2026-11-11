// AlignmentFromAssumptions: port of llvm/lib/Transforms/Scalar/AlignmentFromAssumptions.cpp
// (getNewAlignmentDiff, getNewAlignment, extractAlignmentInfo, processAssumption, runImpl, run).
// Alignments are byte values (0 = none / MaybeAlign()).

afa_new_alignment_diff :: (diff: Scev_Id, align: Scev_Id) -> u64 {
    du := sc_get_urem(diff, align);
    if sc_kind(du) == .CONSTANT {
        d := ap_sext_value(const_ap(se.nodes[du].val));
        if d == 0 return const_int_zext(se.nodes[align].val);   // getAlignValue
        a := ifx d < 0 then cast(u64) -d else cast(u64) d;
        if a != 0 && (a & (a - 1)) == 0 return a;
    }
    return 0;
}

afa_new_alignment :: (aa: Scev_Id, align: Scev_Id, off: Scev_Id, ptr: Value_Id) -> u64 {
    p := sc_get_scev(ptr);
    diff := sc_get_minus(p, aa);
    if diff == SCEV_CNC || sc_kind(diff) == .CNC return 1;
    diff = sc_get_noop_or_sign_extend(diff, se.nodes[off].type);
    ops: [..] Scev_Id; ops.allocator = temp;
    array_add(*ops, diff); array_add(*ops, off);
    diff = sc_get_add(*ops);
    na := afa_new_alignment_diff(diff, align);
    if na != 0 return na;
    if sc_kind(diff) == .ADDREC {
        start := se.ops[se.nodes[diff].ops];
        inc := sc_step_recurrence(diff);
        a := afa_new_alignment_diff(start, align);
        b := afa_new_alignment_diff(inc, align);
        if a == 0 || b == 0 return 1;
        if a > b return b;
        return a;
    }
    return 1;
}

afa_process_assumption :: (acall: Value_Id, idx: u32) -> bool {
    i64 := type_int(64);
    if call_bundle_tag(acall, idx) != "align" return false;
    b, e := call_bundle_range(acall, idx);
    aaptr := strip_pointer_casts_same_representation(op(acall, b));
    align := sc_get_truncate_or_zero_extend(sc_get_scev(op(acall, b + 1)), i64);
    if sc_kind(align) != .CONSTANT return false;
    av := const_ap(se.nodes[align].val);
    if !ap_is_power_of_2(av) return false;
    if ap_active_bits(av) > 33 || ap_zext_value(av) > (cast(u64) 1 << 32) return false;   // ugt(Value::MaximumAlignment)
    off: Scev_Id;
    if e - b == 3 off = sc_get_scev(op(acall, b + 2));
    else off = sc_get_zero(i64);
    off = sc_get_truncate_or_zero_extend(off, i64);
    if is_constant_data(aaptr) return false;
    aa := sc_get_scev(aaptr);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    f := inst_fn(acall);
    u := ir.v_first_use[aaptr];
    while u != NONE {
        j := ir.u_user[u];
        if j != acall && is_inst(j) && inst_fn(j) == f array_add(*wl, j);
        u = ir.u_next[u];
    }
    dt := se.dt;
    while wl.count {
        j := pop(*wl);
        o := inst_op(j);
        if o == .LOAD || o == .STORE {
            if !is_valid_assume_for_context(acall, j, dt) continue;
            na := afa_new_alignment(aa, align, off, load_store_pointer_operand(j));
            if na > inst(j).align inst(j).align = na;
        } else if is_call_base(j) && is_mem_intrinsic_call(j) {
            if !is_valid_assume_for_context(acall, j, dt) continue;
            nd := afa_new_alignment(aa, align, off, op(j, 0));
            if nd > max(call_param_align(j, 0), 1) add_param_align(j, 0, nd);
            id := intrinsic_id_of_call(j);
            if id == "llvm.memcpy" || id == "llvm.memmove" || id == "llvm.memcpy.inline" {   // MemTransferInst
                ns := afa_new_alignment(aa, align, off, op(j, 1));
                if ns > max(call_param_align(j, 1), 1) add_param_align(j, 1, ns);
            }
        }
        table_set(*visited, j, true);
        if o == .GEP || o == .PHI {
            uu := ir.v_first_use[j];
            while uu != NONE {
                defer uu = ir.u_next[uu];
                if type_kind(vtype(ir.u_val[uu])) != .PTR continue;
                k := ir.u_user[uu];
                if inst_op(k) == .STORE && uu - ir.v_ops[k] != 1 continue;   // getPointerOperandIndex
                if !table_contains(*visited, k) array_add(*wl, k);
            }
        }
    }
    return true;
}

alignment_from_assumptions_run :: (f: Value_Id) -> Preserved {
    ac := get_assumption_cache(f);
    get_scev(f);
    get_domtree(f);
    changed := false;
    for a: ac.assumes {
        if a == NONE || vkind(a) == .DEAD continue;
        n := call_num_bundles(a);
        for k: 0..cast(s64) n - 1 if afa_process_assumption(a, cast(u32) k) changed = true;
    }
    if !changed return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .SCEV);
    return pa;
}
