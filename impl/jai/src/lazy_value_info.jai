// LazyValueInfo: a port of llvm/lib/Analysis/LazyValueInfo.cpp (LazyValueInfoCache, LazyValueInfoImpl, the
// LazyValueInfo query interface and the print<lazy-value-info> annotated writer). ValueLatticeElement is
// value_lattice.jai.
//
// The result is `*Lvi` (heap, Fn_Analyses.lvi, get_lvi(f)). Like LLVM's LazyValueInfo it is fully lazy: the Impl
// (cache, solver state, guard declaration) is created by the first query (`has_impl`), and the printer prints nothing
// but its header when no query was made. LVIValueHandle: every value inserted into the cache is registered in
// `lvi_value_handles`; erase_inst and replace_all_uses_with call lvi_note_erase / lvi_note_rauw (ir.jai), which
// erase it from the cache (CallbackVH::deleted / allUsesReplacedWith).
//
// Not ported: -lvi-per-pred-ranges (unknown flag, fails loudly), the legacy pass wrapper.

LVI_MAX_PROCESSED_PER_VALUE :: 500;

// LazyValueInfoCache::BlockCacheEntry
Lvi_Block_Entry :: struct {
    lattice: Table(Value_Id, Vle);       // LatticeElements
    overdefined: Table(Value_Id, bool);  // OverDefined
    nonnull_computed: bool;              // NonNullPointers has a value
    nonnull: Table(Value_Id, bool);      // NonNullPointers
    order: [..] Value_Id;                // insertion order of OverDefined (DenseSet order is only used for erasing)
}

Lvi :: struct {
    f: Value_Id;
    ac: *Assumption_Cache;
    has_impl: bool;                       // PImpl != nullptr
    guard_decl: Value_Id = NONE;          // GuardDecl
    blocks: Table(Value_Id, *Lvi_Block_Entry);   // BlockCache (by block)
    handles: Table(Value_Id, bool);       // ValueHandles
    stack: [..] [2] Value_Id;             // BlockValueStack: (BB, Val)
    stack_set: Table(u64, bool);          // BlockValueSet
}

lvi_value_handles: Table(Value_Id, *Lvi);   // which LVI holds an LVIValueHandle on a value

lvi_new :: (f: Value_Id, ac: *Assumption_Cache) -> *Lvi {
    l := New(Lvi);
    l.f = f;
    l.ac = ac;
    return l;
}
lvi_free :: (l: *Lvi) {
    lvi_clear(l);
    deinit(*l.blocks); deinit(*l.handles); array_free(l.stack); deinit(*l.stack_set);
    free(l);
}
lvi_block_entry_free :: (e: *Lvi_Block_Entry) {
    deinit(*e.lattice); deinit(*e.overdefined); deinit(*e.nonnull); array_free(e.order);
    free(e);
}

// LazyValueInfo::getOrCreateImpl
lvi_impl :: (l: *Lvi) -> *Lvi {
    if !l.has_impl {
        l.has_impl = true;
        g := lookup_global("llvm.experimental.guard");
        l.guard_decl = ifx g != NONE && vkind(g) == .FUNCTION then g else NONE;
    }
    return l;
}

// ---------------------------------------------------------------- LazyValueInfoCache

lvi_get_block_entry :: (l: *Lvi, bb: Value_Id) -> *Lvi_Block_Entry {
    found, e := table_find(*l.blocks, bb);
    if found return e;
    return null;
}
lvi_get_or_create_block_entry :: (l: *Lvi, bb: Value_Id) -> *Lvi_Block_Entry {
    e := lvi_get_block_entry(l, bb);
    if e return e;
    e = New(Lvi_Block_Entry);
    table_set(*l.blocks, bb, e);
    return e;
}
lvi_add_value_handle :: (l: *Lvi, v: Value_Id) {
    if table_contains(*l.handles, v) return;
    table_set(*l.handles, v, true);
    table_set(*lvi_value_handles, v, l);
}
lvi_insert_result :: (l: *Lvi, v: Value_Id, bb: Value_Id, r: Vle) {
    e := lvi_get_or_create_block_entry(l, bb);
    if r.tag == .OVERDEFINED {
        if !table_contains(*e.overdefined, v) { table_set(*e.overdefined, v, true); array_add(*e.order, v); }
    } else {
        if !table_contains(*e.lattice, v) table_set(*e.lattice, v, vle_heap_copy(r));
    }
    lvi_add_value_handle(l, v);
}
lvi_get_cached_value_info :: (l: *Lvi, v: Value_Id, bb: Value_Id) -> (bool, Vle) {
    e := lvi_get_block_entry(l, bb);
    if !e return false, .{};
    if table_contains(*e.overdefined, v) return true, vle_get_overdefined();
    found, r := table_find(*e.lattice, v);
    if !found return false, .{};
    return true, r;
}
lvi_cache_is_non_null_at_end_of_block :: (l: *Lvi, v: Value_Id, bb: Value_Id) -> bool {
    e := lvi_get_or_create_block_entry(l, bb);
    if !e.nonnull_computed {
        e.nonnull_computed = true;
        for i: block_insts(bb) lvi_add_non_null_pointers_by_instruction(i, *e.nonnull);
        for k, v: e.nonnull lvi_add_value_handle(l, v);
    }
    return table_contains(*e.nonnull, v);
}
// LazyValueInfoCache::clear
lvi_clear :: (l: *Lvi) {
    for e: l.blocks lvi_block_entry_free(e);
    table_reset(*l.blocks);
    for k, v: l.handles {
        found, o := table_find(*lvi_value_handles, v);
        if found && o == l table_remove(*lvi_value_handles, v);
    }
    table_reset(*l.handles);
}
// LazyValueInfoCache::eraseValue
lvi_erase_value :: (l: *Lvi, v: Value_Id) {
    for e: l.blocks {
        table_remove(*e.lattice, v);
        if table_remove(*e.overdefined, v) array_unordered_remove_by_value(*e.order, v);
        if e.nonnull_computed table_remove(*e.nonnull, v);
    }
    if table_remove(*l.handles, v) {
        found, o := table_find(*lvi_value_handles, v);
        if found && o == l table_remove(*lvi_value_handles, v);
    }
}
// LazyValueInfoCache::eraseBlock
lvi_erase_block :: (l: *Lvi, bb: Value_Id) {
    if !l.has_impl return;
    e := lvi_get_block_entry(l, bb);
    if !e return;
    table_remove(*l.blocks, bb);
    lvi_block_entry_free(e);
}
// LazyValueInfoCache::threadEdgeImpl
lvi_thread_edge :: (l: *Lvi, pred_bb: Value_Id, old_succ: Value_Id, new_succ: Value_Id) {
    if !l.has_impl return;
    e := lvi_get_block_entry(l, old_succ);
    if !e || e.overdefined.count == 0 return;
    vals_to_clear: [..] Value_Id; vals_to_clear.allocator = temp;
    for e.order array_add(*vals_to_clear, it);
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, old_succ);
    succs: [..] Value_Id; succs.allocator = temp;
    while worklist.count {
        to_update := pop(*worklist);
        if to_update == new_succ continue;
        we := lvi_get_block_entry(l, to_update);
        if !we || we.overdefined.count == 0 continue;
        changed := false;
        for v: vals_to_clear {
            if !table_remove(*we.overdefined, v) continue;
            array_unordered_remove_by_value(*we.order, v);
            changed = true;
        }
        if !changed continue;
        block_successors(to_update, *succs);
        for succs array_add(*worklist, it);
    }
}

// Value handle callbacks (from ir.jai)
lvi_note_erase :: (v: Value_Id) {
    if lvi_value_handles.count == 0 return;
    found, l := table_find(*lvi_value_handles, v);
    if found lvi_erase_value(l, v);
}
lvi_note_rauw :: (old: Value_Id) { lvi_note_erase(old); }

// ---------------------------------------------------------------- LazyValueInfoImpl

lvi_push_block_value :: (l: *Lvi, bb: Value_Id, v: Value_Id) -> bool {
    key := ((cast(u64) bb) << 32) | cast(u64) v;
    if table_contains(*l.stack_set, key) return false;
    table_set(*l.stack_set, key, true);
    array_add(*l.stack, .[bb, v]);
    return true;
}

lvi_solve :: (l: *Lvi) {
    starting: [..] [2] Value_Id; starting.allocator = temp;
    for l.stack array_add(*starting, it);
    processed := 0;
    while l.stack.count {
        processed += 1;
        if processed > LVI_MAX_PROCESSED_PER_VALUE {
            while starting.count {
                e := pop(*starting);
                lvi_insert_result(l, e[1], e[0], vle_get_overdefined());
            }
            table_reset(*l.stack_set);
            l.stack.count = 0;
            return;
        }
        e := l.stack[l.stack.count - 1];
        if lvi_solve_block_value(l, e[1], e[0]) {
            l.stack.count -= 1;
            table_remove(*l.stack_set, ((cast(u64) e[0]) << 32) | cast(u64) e[1]);
        }
    }
}

lvi_get_block_value :: (l: *Lvi, v: Value_Id, bb: Value_Id, cxt: Value_Id) -> (bool, Vle) {
    if is_constant_kind(vkind(v)) return true, vle_get(v);
    found, r := lvi_get_cached_value_info(l, v, bb);
    if found {
        lvi_intersect_assume_or_guard_block_value_constant_range(l, v, *r, cxt);
        return true, r;
    }
    if !lvi_push_block_value(l, bb, v) return true, vle_get_overdefined();
    return false, .{};
}

// getFromRangeMetadata
lvi_get_from_range_metadata :: (i: Value_Id) -> Vle {
    o := inst_op(i);
    if o == .CALL || o == .INVOKE {
        ok, r := call_range(i);
        if ok return vle_get_range(r);
    }
    if o == .CALL || o == .INVOKE || o == .LOAD {
        m := get_metadata(i, md_kind_id("range"));
        if m != NONE && type_kind(vtype(i)) == .INT return vle_get_range(cr_from_range_md(m));
    }
    return vle_get_overdefined();
}

lvi_solve_block_value :: (l: *Lvi, v: Value_Id, bb: Value_Id) -> bool {
    ok, r := lvi_solve_block_value_impl(l, v, bb);
    if !ok return false;
    lvi_insert_result(l, v, bb, r);
    return true;
}

lvi_dl_query :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }   // SimplifyQuery(DL)

lvi_is_int_or_int_vector :: (t: Type_Id) -> bool { return is_int_type(scalar_type(t)); }

lvi_solve_block_value_impl :: (l: *Lvi, v: Value_Id, bb: Value_Id) -> (bool, Vle) {
    if !is_inst(v) || inst_block(v) != bb { ok_, r_ := lvi_solve_block_value_non_local(l, v, bb); return ok_, r_; }
    i := v;
    o := inst_op(i);
    if o == .PHI { ok_, r_ := lvi_solve_block_value_phi(l, i, bb); return ok_, r_; }
    if o == .SELECT { ok_, r_ := lvi_solve_block_value_select(l, i, bb); return ok_, r_; }
    t := vtype(i);
    if is_ptr_type(t) && is_known_non_zero(i, lvi_dl_query()) return true, vle_get_not(const_null_value(t));
    if lvi_is_int_or_int_vector(t) {
        if is_cast_op(o) { ok_, r_ := lvi_solve_block_value_cast(l, i, bb); return ok_, r_; }
        if is_binary_op(o) { ok_, r_ := lvi_solve_block_value_binary_op(l, i, bb); return ok_, r_; }
        if o == .INSERTELEMENT { ok_, r_ := lvi_solve_block_value_insert_element(l, i, bb); return ok_, r_; }
        if o == .EXTRACTVALUE { ok_, r_ := lvi_solve_block_value_extract_value(l, i, bb); return ok_, r_; }
        if call_iid(i) != NOT_INTRINSIC { ok_, r_ := lvi_solve_block_value_intrinsic(l, i, bb); return ok_, r_; }
    }
    return true, lvi_get_from_range_metadata(i);
}

// AddNonNullPointer
lvi_add_non_null_pointer :: (p: Value_Id, set: *Table(Value_Id, bool), dereferenced := true) {
    if type_addrspace(vtype(p)) == 0 {
        table_set(set, ifx dereferenced then get_underlying_object(p) else strip_in_bounds_offsets(p), true);
    }
}
// AddNonNullPointersByInstruction
lvi_add_non_null_pointers_by_instruction :: (i: Value_Id, set: *Table(Value_Id, bool)) {
    o := inst_op(i);
    if o == .LOAD { lvi_add_non_null_pointer(op(i, 0), set); return; }
    if o == .STORE { lvi_add_non_null_pointer(op(i, 1), set); return; }
    id := call_iid(i);
    if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE {
        // MemIntrinsic
        if !is_const_int(call_arg(i, 3)) fatal("lazy-value-info: memory intrinsic with a non-constant volatile flag");
        if !ap_is_zero(const_ap(call_arg(i, 3))) return;
        len := call_arg(i, 2);
        if !is_scalar_const_int(len) || ap_is_zero(const_ap(len)) return;
        lvi_add_non_null_pointer(call_arg(i, 0), set);
        if id != IID_MEMSET && id != IID_MEMSET_INLINE lvi_add_non_null_pointer(call_arg(i, 1), set);
        return;
    }
    if is_call_base(i) {
        n := call_num_args(i);
        for k: 0..cast(s64) n - 1 {
            a := call_arg(i, cast(u32) k);
            if is_ptr_type(vtype(a)) && lvi_param_has_non_null_attr(i, cast(u32) k, false)
                lvi_add_non_null_pointer(a, set, false);
        }
    }
}
// CallBase::paramHasNonNullAttr
lvi_param_has_non_null_attr :: (c: Value_Id, argno: u32, allow_undef_or_poison: bool) -> bool {
    if call_param_has_attr(c, argno, .NonNull) && (allow_undef_or_poison || call_param_has_attr(c, argno, .NoUndef)) return true;
    if call_param_has_attr(c, argno, .Dereferenceable) && !null_pointer_is_defined(inst_fn(c), type_addrspace(vtype(call_arg(c, argno)))) return true;
    return false;
}

lvi_is_non_null_at_end_of_block :: (l: *Lvi, v_in: Value_Id, bb: Value_Id) -> bool {
    if null_pointer_is_defined(block_fn(bb), type_addrspace(vtype(v_in))) return false;
    v := strip_in_bounds_offsets(v_in);
    return lvi_cache_is_non_null_at_end_of_block(l, v, bb);
}

lvi_solve_block_value_non_local :: (l: *Lvi, v: Value_Id, bb: Value_Id) -> (bool, Vle) {
    result: Vle;
    if bb == fn_entry(block_fn(bb)) {
        assert(vkind(v) == .ARGUMENT, "Unknown live-in to the entry block");
        ok, r := arg_range(v);
        if ok return true, vle_get_range(r);
        return true, vle_get_overdefined();
    }
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    for pred: preds {
        if pred == bb continue;
        ok, er := lvi_get_edge_value(l, v, pred, bb);
        if !ok return false, .{};
        vle_merge_in(*result, er);
        if result.tag == .OVERDEFINED return true, result;
    }
    return true, result;
}

lvi_solve_block_value_phi :: (l: *Lvi, pn: Value_Id, bb: Value_Id) -> (bool, Vle) {
    result: Vle;
    n := phi_num_incoming(pn);
    for k: 0..cast(s64) n - 1 {
        phi_bb := phi_block(pn, cast(u32) k);
        phi_val := phi_value(pn, cast(u32) k);
        ok, er := lvi_get_edge_value(l, phi_val, phi_bb, bb, pn);
        if !ok return false, .{};
        vle_merge_in(*result, er);
        if result.tag == .OVERDEFINED return true, result;
    }
    return true, result;
}

lvi_intersect_assume_or_guard_block_value_constant_range :: (l: *Lvi, v: Value_Id, bblv: *Vle, bbi_in: Value_Id) {
    bbi := bbi_in;
    if bbi == NONE { if is_inst(v) bbi = v; else return; }
    bb := inst_block(bbi);
    for e: ac_assumptions_for(l.ac, v) {
        if vkind(e.assume) == .DEAD continue;
        i := e.assume;
        if inst_block(i) != bb || !is_valid_assume_for_context(i, bbi, null) continue;
        if e.index != AC_EXPR_RESULT_IDX {
            if assume_bundle_implies_non_null(v, inst_fn(bbi), i, e.index)
                bblv.* = vle_intersect(bblv.*, vle_get_not(const_null_value(vtype(v))));
        } else {
            _, c := lvi_get_value_from_condition(l, v, call_arg(i, 0), true, false);
            bblv.* = vle_intersect(bblv.*, c);
        }
    }
    if l.guard_decl != NONE && has_uses(l.guard_decl) && bbi != block_first(bb) {
        x := inst_prev(bbi);
        while x != NONE {
            if call_iid(x) == IID_EXPERIMENTAL_GUARD {
                _, c := lvi_get_value_from_condition(l, v, call_arg(x, 0), true, false);
                bblv.* = vle_intersect(bblv.*, c);
            }
            x = inst_prev(x);
        }
    }
    if bblv.tag == .OVERDEFINED {
        t := vtype(v);
        if is_ptr_type(t) && block_terminator(bb) == bbi && lvi_is_non_null_at_end_of_block(l, v, bb)
            bblv.* = vle_get_not(const_null_value(t));
    }
}

lvi_solve_block_value_select :: (l: *Lvi, si: Value_Id, bb: Value_Id) -> (bool, Vle) {
    tv := op(si, 1); fv := op(si, 2);
    ok1, true_val := lvi_get_block_value(l, tv, bb, si);
    if !ok1 return false, .{};
    ok2, false_val := lvi_get_block_value(l, fv, bb, si);
    if !ok2 return false, .{};
    if vle_is_constant_range(true_val) || vle_is_constant_range(false_val) {
        true_cr := vle_as_constant_range(true_val, vtype(si));
        false_cr := vle_as_constant_range(false_val, vtype(si));
        spr, lhs, rhs := match_select_pattern(si);
        if spf_is_min_or_max(spr.flavor) && ((lhs == tv && rhs == fv) || (rhs == tv && lhs == fv)) {
            res: Const_Range;
            if spr.flavor == {
                case .SMIN; res = cr_smin_op(true_cr, false_cr);
                case .UMIN; res = cr_umin_op(true_cr, false_cr);
                case .SMAX; res = cr_smax_op(true_cr, false_cr);
                case .UMAX; res = cr_umax_op(true_cr, false_cr);
                case; assert(false, "unexpected minmax type!");
            }
            return true, vle_get_range(res, true_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF || false_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
        }
        if spr.flavor == .ABS {
            if lhs == tv return true, vle_get_range(cr_abs(true_cr), true_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
            if lhs == fv return true, vle_get_range(cr_abs(false_cr), false_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
        }
        if spr.flavor == .NABS {
            zero := cr_single(ap_zero(cr_bits(true_cr)));
            if lhs == tv return true, vle_get_range(cr_sub(zero, cr_abs(true_cr)), false_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
            if lhs == fv return true, vle_get_range(cr_sub(zero, cr_abs(false_cr)), false_val.tag == .CONSTANTRANGE_INCLUDING_UNDEF);
        }
    }
    cond := op(si, 0);
    if is_guaranteed_not_to_be_undef(cond, l.ac) {
        _, tc := lvi_get_value_from_condition(l, tv, cond, true, false);
        true_val = vle_intersect(true_val, tc);
        _, fc := lvi_get_value_from_condition(l, fv, cond, false, false);
        false_val = vle_intersect(false_val, fc);
    }
    vle_merge_in(*true_val, false_val);
    return true, true_val;
}

lvi_get_range_for :: (l: *Lvi, v: Value_Id, cxt: Value_Id, bb: Value_Id) -> (bool, Const_Range) {
    ok, r := lvi_get_block_value(l, v, bb, cxt);
    if !ok return false, .{};
    return true, vle_as_constant_range(r, vtype(v));
}

lvi_solve_block_value_cast :: (l: *Lvi, ci: Value_Id, bb: Value_Id) -> (bool, Vle) {
    o := inst_op(ci);
    if o != .TRUNC && o != .SEXT && o != .ZEXT return true, vle_get_overdefined();
    ok, lhs := lvi_get_range_for(l, op(ci, 0), ci, bb);
    if !ok return false, .{};
    bw := type_bits(scalar_type(vtype(ci)));
    res: Const_Range;
    if o == .TRUNC res = cr_truncate(lhs, bw, (opr_flags(ci) & F_NUW) != 0);
    else res = cr_cast_op(lhs, o, bw);
    return true, vle_get_range(res);
}

// The OpFn of solveBlockValueBinaryOpImpl: binaryOp / overflowingBinaryOp with the instruction's flags
Lvi_Binop_Fn :: struct { opc: Opcode; nw: u32; overflowing: bool; }
lvi_binop_apply :: (fn: Lvi_Binop_Fn, a: Const_Range, b: Const_Range) -> Const_Range {
    if fn.overflowing return cr_overflowing_binary_op(a, fn.opc, b, fn.nw);
    return cr_binary_op(a, fn.opc, b);
}

lvi_solve_block_value_binary_op_impl :: (l: *Lvi, i: Value_Id, bb: Value_Id, fn: Lvi_Binop_Fn) -> (bool, Vle) {
    lhs := op(i, 0); rhs := op(i, 1);
    thread_over_select :: (l: *Lvi, x: Value_Id, crx: Const_Range, y: Value_Id, x_is_lhs: bool, fn: Lvi_Binop_Fn) -> (bool, Vle) {
        cond := op(y, 0);
        true_c := op(y, 1);
        if !is_constant_kind(vkind(true_c)) return false, .{};
        false_c := op(y, 2);
        if !is_constant_kind(vkind(false_c)) return false, .{};
        if !is_guaranteed_not_to_be_undef(cond, l.ac) return false, .{};
        _, tc := lvi_get_value_from_condition(l, x, cond, true, false);
        true_x := cr_intersect(crx, vle_as_constant_range(tc, vtype(x)));
        _, fc := lvi_get_value_from_condition(l, x, cond, false, false);
        false_x := cr_intersect(crx, vle_as_constant_range(fc, vtype(x)));
        true_y := constant_to_range(true_c);
        false_y := constant_to_range(false_c);
        if x_is_lhs return true, vle_get_range(cr_union(lvi_binop_apply(fn, true_x, true_y), lvi_binop_apply(fn, false_x, false_y)));
        return true, vle_get_range(cr_union(lvi_binop_apply(fn, true_y, true_x), lvi_binop_apply(fn, false_y, false_x)));
    }
    ok1, lhs_r := lvi_get_range_for(l, lhs, i, bb);
    if !ok1 return false, .{};
    if is_inst(rhs) && inst_op(rhs) == .SELECT {
        ok, r := thread_over_select(l, lhs, lhs_r, rhs, true, fn);
        if ok return true, r;
    }
    ok2, rhs_r := lvi_get_range_for(l, rhs, i, bb);
    if !ok2 return false, .{};
    if is_inst(lhs) && inst_op(lhs) == .SELECT {
        ok, r := thread_over_select(l, rhs, rhs_r, lhs, false, fn);
        if ok return true, r;
    }
    return true, vle_get_range(lvi_binop_apply(fn, lhs_r, rhs_r));
}

lvi_solve_block_value_binary_op :: (l: *Lvi, bo: Value_Id, bb: Value_Id) -> (bool, Vle) {
    fn: Lvi_Binop_Fn;
    fn.opc = inst_op(bo);
    if is_overflowing_binop(bo) {
        fn.overflowing = true;
        f := opr_flags(bo);
        if f & F_NUW fn.nw |= NW_NUW;
        if f & F_NSW fn.nw |= NW_NSW;
    }
    ok, r := lvi_solve_block_value_binary_op_impl(l, bo, bb, fn);
    return ok, r;
}

lvi_solve_block_value_overflow_intrinsic :: (l: *Lvi, wo: Value_Id, bb: Value_Id) -> (bool, Vle) {
    fn: Lvi_Binop_Fn;
    fn.opc = wo_binary_op(call_iid(wo));
    ok, r := lvi_solve_block_value_binary_op_impl(l, wo, bb, fn);
    return ok, r;
}

// ConstantRange::isIntrinsicSupported
cr_is_intrinsic_supported :: (id: Intrinsic_Id) -> bool {
    return id == IID_UADD_SAT || id == IID_USUB_SAT || id == IID_SADD_SAT || id == IID_SSUB_SAT ||
           id == IID_UMIN || id == IID_UMAX || id == IID_SMIN || id == IID_SMAX ||
           id == IID_ABS || id == IID_CTLZ || id == IID_CTTZ || id == IID_CTPOP;
}
// ConstantRange::intrinsic
cr_intrinsic :: (id: Intrinsic_Id, ops: [] Const_Range) -> Const_Range {
    bool_of :: (r: Const_Range) -> bool {
        ok, e := cr_single_element(r);
        assert(ok, "Must be known (immarg)");
        return !ap_is_zero(e);
    }
    if id == {
        case IID_UADD_SAT; return cr_uadd_sat(ops[0], ops[1]);
        case IID_USUB_SAT; return cr_usub_sat(ops[0], ops[1]);
        case IID_SADD_SAT; return cr_sadd_sat(ops[0], ops[1]);
        case IID_SSUB_SAT; return cr_ssub_sat(ops[0], ops[1]);
        case IID_UMIN; return cr_umin_op(ops[0], ops[1]);
        case IID_UMAX; return cr_umax_op(ops[0], ops[1]);
        case IID_SMIN; return cr_smin_op(ops[0], ops[1]);
        case IID_SMAX; return cr_smax_op(ops[0], ops[1]);
        case IID_ABS; return cr_abs(ops[0], bool_of(ops[1]));
        case IID_CTLZ; return cr_ctlz(ops[0], bool_of(ops[1]));
        case IID_CTTZ; return cr_cttz(ops[0], bool_of(ops[1]));
        case IID_CTPOP; return cr_ctpop(ops[0]);
    }
    assert(false, "Unsupported intrinsic");
    return .{};
}

lvi_solve_block_value_intrinsic :: (l: *Lvi, ii: Value_Id, bb: Value_Id) -> (bool, Vle) {
    md := lvi_get_from_range_metadata(ii);
    id := call_iid(ii);
    if !cr_is_intrinsic_supported(id) return true, md;
    ranges: [..] Const_Range; ranges.allocator = temp;
    n := call_num_args(ii);
    for k: 0..cast(s64) n - 1 {
        ok, r := lvi_get_range_for(l, call_arg(ii, cast(u32) k), ii, bb);
        if !ok return false, .{};
        array_add(*ranges, r);
    }
    return true, vle_intersect(vle_get_range(cr_intrinsic(id, ranges)), md);
}

lvi_solve_block_value_insert_element :: (l: *Lvi, iei: Value_Id, bb: Value_Id) -> (bool, Vle) {
    ok1, res := lvi_get_block_value(l, op(iei, 1), bb, iei);
    if !ok1 return false, .{};
    ok2, vec := lvi_get_block_value(l, op(iei, 0), bb, iei);
    if !ok2 return false, .{};
    if res.tag == .CONSTANT return true, vle_get_overdefined();
    vle_merge_in(*res, vec);
    return true, res;
}

lvi_is_with_overflow_inst :: (v: Value_Id) -> bool {
    id := call_iid(v);
    return id == IID_SADD_WITH_OVERFLOW || id == IID_UADD_WITH_OVERFLOW || id == IID_SSUB_WITH_OVERFLOW ||
           id == IID_USUB_WITH_OVERFLOW || id == IID_SMUL_WITH_OVERFLOW || id == IID_UMUL_WITH_OVERFLOW;
}

lvi_solve_block_value_extract_value :: (l: *Lvi, evi: Value_Id, bb: Value_Id) -> (bool, Vle) {
    agg := op(evi, 0);
    idx := inst_indices(evi);
    if lvi_is_with_overflow_inst(agg) && idx.count == 1 && idx[0] == 0 {
        ok, r := lvi_solve_block_value_overflow_intrinsic(l, agg, bb);
        return ok, r;
    }
    v := simplify_extract_value_inst(agg, idx, lvi_dl_query());
    if v != NONE { ok, r := lvi_get_block_value(l, v, bb, evi); return ok, r; }
    return true, vle_get_overdefined();
}

// matchICmpOperand
lvi_match_icmp_operand :: (offset: *APInt, lhs: Value_Id, v: Value_Id, pred: u8) -> bool {
    if lhs == v return true;
    ok, a, b := pm_add_like(lhs);
    if ok && a == v { okc, c := pm_apint(b); if okc { offset.* = c; return true; } }
    ok, a, b = pm_add_like(v);
    if ok && a == lhs { okc, c := pm_apint(b); if okc { offset.* = ap_neg(c); return true; } }
    if is_inst(lhs) && inst_op(lhs) == .OR && (op(lhs, 0) == v || op(lhs, 1) == v) && (pred == ICMP_ULT || pred == ICMP_ULE) return true;
    if is_inst(lhs) && inst_op(lhs) == .AND && (op(lhs, 0) == v || op(lhs, 1) == v) && (pred == ICMP_UGT || pred == ICMP_UGE) return true;
    return false;
}

// getValueFromSimpleICmpCondition
lvi_get_value_from_simple_icmp_condition :: (l: *Lvi, pred: u8, rhs: Value_Id, offset: APInt, cxt: Value_Id, use_block_value: bool) -> (bool, Vle) {
    rhs_range := cr_full(type_bits(scalar_type(vtype(rhs))));
    if is_constant_kind(vkind(rhs)) {
        rhs_range = constant_to_range(rhs);
    } else if use_block_value {
        ok, r := lvi_get_block_value(l, rhs, inst_block(cxt), cxt);
        if !ok return false, .{};
        rhs_range = vle_as_constant_range(r, vtype(rhs));
    }
    true_values := cr_allowed_icmp_region(pred, rhs_range);
    return true, vle_get_range(cr_subtract(true_values, offset));
}

// getRangeViaSLT with the ashr callback of getValueFromICmpCondition
lvi_range_via_slt_ashr :: (pred_in: u8, rhs_in: APInt, sh_amt: APInt) -> (bool, Const_Range) {
    pred := pred_in; rhs := rhs_in;
    invert := false;
    if pred == ICMP_SGT || pred == ICMP_SGE { pred = icmp_inverse(pred); invert = true; }
    if pred == ICMP_SLE {
        pred = ICMP_SLT;
        if ap_is_max_signed(rhs) return false, .{};
        rhs = ap_add_u64(rhs, 1);
    }
    assert(pred == ICMP_SLT, "Must be signed predicate");
    nw := ap_shl_ap(rhs, sh_amt);
    if !ap_eq(ap_ashr_ap(nw, sh_amt), rhs) return false, .{};
    cr := cr_non_empty(ap_signed_min(nw.bits), nw);
    if invert return true, cr_inverse(cr);
    return true, cr;
}

// getValueFromICmpCtpop
lvi_get_value_from_icmp_ctpop :: (pred: u8, rhs: Value_Id) -> Vle {
    bw := type_bits(scalar_type(vtype(rhs)));
    if !is_scalar_const_int(rhs) return vle_get_overdefined();
    res := cr_exact_icmp_region(pred, const_ap(rhs));
    res_min := cast(u32) ap_limited(cr_umin(res), bw);
    res_max := cast(u32) ap_limited(cr_umax(res), bw);
    vmin := ap_low_bits_set(bw, res_min);
    vmax := ap_high_bits_set(bw, res_max);
    return vle_get_range(cr_non_empty(vmin, ap_add_u64(vmax, 1)));
}

lvi_get_value_from_icmp_condition :: (l: *Lvi, v: Value_Id, ici: Value_Id, is_true_dest: bool, use_block_value: bool) -> (bool, Vle) {
    lhs := op(ici, 0); rhs := op(ici, 1);
    pred := inst_pred(ici);
    edge_pred := ifx is_true_dest then pred else icmp_inverse(pred);
    if is_constant_kind(vkind(rhs)) {
        if icmp_is_equality(pred) && lhs == v {
            if edge_pred == ICMP_EQ return true, vle_get(rhs);
            else if vkind(rhs) != .C_UNDEF && vkind(rhs) != .C_POISON return true, vle_get_not(rhs);
        }
    }
    ty := vtype(v);
    if !lvi_is_int_or_int_vector(ty) return true, vle_get_overdefined();
    bw := type_bits(scalar_type(ty));
    offset := ap_zero(bw);
    if lvi_match_icmp_operand(*offset, lhs, v, edge_pred) {
        ok, r := lvi_get_value_from_simple_icmp_condition(l, edge_pred, rhs, offset, ici, use_block_value);
        return ok, r;
    }
    swapped := icmp_swapped(edge_pred);
    if lvi_match_icmp_operand(*offset, rhs, v, swapped) {
        ok, r := lvi_get_value_from_simple_icmp_condition(l, swapped, lhs, offset, ici, use_block_value);
        return ok, r;
    }
    okp, px := pm_ctpop(lhs);
    if okp && px == v return true, lvi_get_value_from_icmp_ctpop(edge_pred, rhs);
    if is_inst(lhs) && inst_op(lhs) == .AND && op(lhs, 0) == v {
        okm, mask := pm_apint(op(lhs, 1));
        okc, c := pm_apint(rhs);
        if okm && okc {
            if edge_pred == ICMP_EQ {
                known: Known_Bits;
                known.zero = ap_and(ap_not(c), mask);
                known.one = ap_and(c, mask);
                return true, vle_get_range(cr_from_known_bits(known, false));
            }
            if edge_pred == ICMP_NE return true, vle_get_range(cr_make_mask_not_equal_range(mask, c));
        }
    }
    {
        // m_CombineOr(m_URem(m_Specific(Val), m_Value()), m_Trunc(m_Specific(Val)))
        m := false;
        if opr_code(lhs) == .UREM && op(lhs, 0) == v m = true;
        else { okt, tx := pm_cast(lhs, .TRUNC); if okt && tx == v m = true; }
        if m {
            okc, c := pm_apint(rhs);
            if okc {
                cr := cr_exact_icmp_region(edge_pred, c);
                if !cr_is_empty_set(cr) return true, vle_get_range(cr_non_empty(ap_zext(cr_umin(cr), bw), ap_zero(bw)));
            }
        }
    }
    if icmp_is_signed(edge_pred) && opr_code(lhs) == .ASHR && op(lhs, 0) == v {
        oks, sh := pm_apint(op(lhs, 1));
        okc, c := pm_apint(rhs);
        if oks && okc {
            ok, cr := lvi_range_via_slt_ashr(edge_pred, c, sh);
            if ok return true, vle_get_range(cr);
        }
    }
    if icmp_is_equality(pred) && opr_code(v) == .SUB {
        x := op(v, 0); y := op(v, 1);
        // Peek through ptrtoints (m_PtrToIntSameSize)
        okx, px := pm_ptrtoint_same_size(x); if okx x = px;
        oky, py := pm_ptrtoint_same_size(y); if oky y = py;
        if (x == lhs && y == rhs) || (x == rhs && y == lhs) {
            nv := const_null_value(vtype(v));
            if edge_pred == ICMP_EQ return true, vle_get(nv);
            return true, vle_get_not(nv);
        }
    }
    return true, vle_get_overdefined();
}

// getValueFromTrunc
lvi_get_value_from_trunc :: (v: Value_Id, trunc: Value_Id, is_true_dest: bool) -> Vle {
    if op(trunc, 0) != v return vle_get_overdefined();
    ty := vtype(v);
    if (opr_flags(trunc) & F_NUW) != 0 {
        if is_true_dest return vle_get(const_int(ty, 1));
        return vle_get(const_null_value(ty));
    }
    if is_true_dest return vle_get_not(const_null_value(ty));
    return vle_get_not(cf_all_ones(ty));
}

// getValueFromOverflowCondition
lvi_get_value_from_overflow_condition :: (v: Value_Id, wo: Value_Id, is_true_dest: bool) -> Vle {
    okc, c := pm_apint(call_arg(wo, 1));
    if call_arg(wo, 0) != v || !okc return vle_get_overdefined();
    id := call_iid(wo);
    nwr := cr_make_exact_no_wrap_region(wo_binary_op(id), c, !wo_is_signed(id));
    if is_true_dest nwr = cr_inverse(nwr);
    return vle_get_range(nwr);
}

lvi_get_value_from_condition :: (l: *Lvi, v: Value_Id, cond: Value_Id, is_true_dest: bool, use_block_value: bool, depth_in: u32 = 0) -> (bool, Vle) {
    depth := depth_in;
    if is_inst(cond) && inst_op(cond) == .ICMP {
        ok, r := lvi_get_value_from_icmp_condition(l, v, cond, is_true_dest, use_block_value);
        return ok, r;
    }
    if is_inst(cond) && inst_op(cond) == .TRUNC return true, lvi_get_value_from_trunc(v, cond, is_true_dest);
    if is_inst(cond) && inst_op(cond) == .EXTRACTVALUE {
        agg := op(cond, 0);
        idx := inst_indices(cond);
        if lvi_is_with_overflow_inst(agg) && idx.count == 1 && idx[0] == 1
            return true, lvi_get_value_from_overflow_condition(v, agg, is_true_dest);
    }
    depth += 1;
    if depth == MAX_ANALYSIS_RECURSION_DEPTH return true, vle_get_overdefined();
    okn, n := pm_not(cond);
    if okn {
        ok, r := lvi_get_value_from_condition(l, v, n, !is_true_dest, use_block_value, depth);
        return ok, r;
    }
    is_and: bool;
    ok, a, b := pm_logical_and(cond);
    if ok is_and = true;
    else {
        ok, a, b = pm_logical_or(cond);
        if !ok return true, vle_get_overdefined();
        is_and = false;
    }
    ok1, lv := lvi_get_value_from_condition(l, v, a, is_true_dest, use_block_value, depth);
    if !ok1 return false, .{};
    ok2, rv := lvi_get_value_from_condition(l, v, b, is_true_dest, use_block_value, depth);
    if !ok2 return false, .{};
    if is_true_dest != is_and {
        vle_merge_in(*lv, rv);
        return true, lv;
    }
    return true, vle_intersect(lv, rv);
}

// usesOperand
lvi_uses_operand :: (usr: Value_Id, o: Value_Id) -> bool {
    n := nops(usr);
    for k: 0..cast(s64) n - 1 if op(usr, cast(u32) k) == o return true;
    return false;
}
// isOperationFoldable
lvi_is_operation_foldable :: (usr: Value_Id) -> bool {
    if !is_inst(usr) return false;
    o := inst_op(usr);
    return is_cast_op(o) || is_binary_op(o) || o == .FREEZE;
}
// constantFoldUser
lvi_constant_fold_user :: (usr: Value_Id, o: Value_Id, op_const_val: APInt) -> Vle {
    op_const := const_int_ap(vtype(o), op_const_val);   // Constant::getIntegerValue
    opc := inst_op(usr);
    if is_cast_op(opc) {
        c := simplify_cast_inst(opc, op_const, vtype(usr), lvi_dl_query());
        if c != NONE && vkind(c) == .C_INT return vle_get_range(cr_single(const_ap(c)));
    } else if is_binary_op(opc) {
        a := ifx op(usr, 0) == o then op_const else op(usr, 0);
        b := ifx op(usr, 1) == o then op_const else op(usr, 1);
        c := simplify_binop(opc, a, b, lvi_dl_query());
        if c != NONE && vkind(c) == .C_INT return vle_get_range(cr_single(const_ap(c)));
    } else if opc == .FREEZE {
        return vle_get_range(cr_single(op_const_val));
    }
    return vle_get_overdefined();
}

lvi_get_edge_value_local :: (l: *Lvi, v: Value_Id, bb_from: Value_Id, bb_to: Value_Id, use_block_value: bool) -> (bool, Vle) {
    term := block_terminator(bb_from);
    if inst_op(term) == .CONDBR {
        s0 := get_successor(term, 0); s1 := get_successor(term, 1);
        if s0 != s1 {
            is_true_dest := s0 == bb_to;
            condition := op(term, 0);
            if condition == v return true, vle_get(const_int(ir.t_i1, ifx is_true_dest then cast(u64) 1 else 0));
            ok, result := lvi_get_value_from_condition(l, v, condition, is_true_dest, use_block_value);
            if !ok return false, .{};
            if result.tag != .OVERDEFINED return true, result;
            usr := v;
            if (is_inst(usr) || vkind(usr) == .C_EXPR) && type_kind(vtype(usr)) == .INT && lvi_is_operation_foldable(usr) {
                if lvi_uses_operand(usr, condition) {
                    result = lvi_constant_fold_user(usr, condition, ap_from_u64(1, ifx is_true_dest then cast(u64) 1 else 0));
                } else if inst_op(usr) == .TRUNC || inst_op(usr) == .ZEXT || inst_op(usr) == .SEXT {
                    _, olv := lvi_get_value_from_condition(l, op(usr, 0), condition, is_true_dest, false);
                    if vle_is_constant_range(olv) {
                        rbw := type_bits(scalar_type(vtype(usr)));
                        if inst_op(usr) == .TRUNC return true, vle_get_range(cr_truncate(olv.r, rbw, (opr_flags(usr) & F_NUW) != 0));
                        return true, vle_get_range(cr_cast_op(olv.r, inst_op(usr), rbw));
                    }
                    if olv.tag == .CONSTANT {
                        cc := cfo_cast_operand(inst_op(usr), olv.c, vtype(usr));
                        if cc != NONE return true, vle_get(cc);
                    }
                    return true, vle_get_overdefined();
                } else {
                    n := nops(usr);
                    for k: 0..cast(s64) n - 1 {
                        o := op(usr, cast(u32) k);
                        _, olv := lvi_get_value_from_condition(l, o, condition, is_true_dest, false);
                        okc, oc := vle_as_constant_integer(olv);
                        if okc {
                            result = lvi_constant_fold_user(usr, o, oc);
                            break;
                        }
                    }
                }
            }
            if result.tag != .OVERDEFINED return true, result;
        }
    }
    if inst_op(term) == .SWITCH {
        condition := sw_cond(term);
        if type_kind(vtype(v)) != .INT return true, vle_get_overdefined();
        val_uses_condition := false;
        if condition != v {
            if (is_inst(v) || vkind(v) == .C_EXPR) val_uses_condition = lvi_is_operation_foldable(v) && lvi_uses_operand(v, condition);
            if !val_uses_condition return true, vle_get_overdefined();
        }
        default_case := sw_default(term) == bb_to;
        bw := type_int_width(vtype(v));
        edges_vals := ifx default_case then cr_full(bw) else cr_empty(bw);
        n := sw_num_cases(term);
        for k: 0..cast(s64) n - 1 {
            case_value := const_ap(sw_case_value(term, cast(u32) k));
            edge_val := cr_single(case_value);
            if val_uses_condition {
                elv := lvi_constant_fold_user(v, condition, case_value);
                if elv.tag == .OVERDEFINED return true, vle_get_overdefined();
                edge_val = elv.r;
            }
            if default_case {
                if sw_case_dest(term, cast(u32) k) != bb_to && condition == v edges_vals = cr_difference(edges_vals, edge_val);
            } else if sw_case_dest(term, cast(u32) k) == bb_to {
                edges_vals = cr_union(edges_vals, edge_val);
            }
        }
        return true, vle_get_range(edges_vals);
    }
    return true, vle_get_overdefined();
}

lvi_get_edge_value :: (l: *Lvi, v: Value_Id, bb_from: Value_Id, bb_to: Value_Id, cxt: Value_Id = NONE) -> (bool, Vle) {
    if is_constant_kind(vkind(v)) return true, vle_get(v);
    ok, local := lvi_get_edge_value_local(l, v, bb_from, bb_to, true);
    if !ok return false, .{};
    if vle_has_single_value(local) return true, local;
    ok2, in_block := lvi_get_block_value(l, v, bb_from, block_terminator(bb_from));
    if !ok2 return false, .{};
    lvi_intersect_assume_or_guard_block_value_constant_range(l, v, *in_block, cxt);
    return true, vle_intersect(local, in_block);
}

// LazyValueInfoImpl::getValueInBlock
lvi_get_value_in_block :: (l: *Lvi, v: Value_Id, bb: Value_Id, cxt: Value_Id = NONE) -> Vle {
    assert(l.stack.count == 0 && l.stack_set.count == 0);
    ok, r := lvi_get_block_value(l, v, bb, cxt);
    if !ok {
        lvi_solve(l);
        ok, r = lvi_get_block_value(l, v, bb, cxt);
        assert(ok, "Value not available after solving");
    }
    return r;
}
// LazyValueInfoImpl::getValueAt
lvi_get_value_at :: (l: *Lvi, v: Value_Id, cxt: Value_Id) -> Vle {
    if is_constant_kind(vkind(v)) return vle_get(v);
    result := vle_get_overdefined();
    if is_inst(v) result = lvi_get_from_range_metadata(v);
    lvi_intersect_assume_or_guard_block_value_constant_range(l, v, *result, cxt);
    return result;
}
// LazyValueInfoImpl::getValueOnEdge
lvi_get_value_on_edge :: (l: *Lvi, v: Value_Id, from: Value_Id, to: Value_Id, cxt: Value_Id = NONE) -> Vle {
    ok, r := lvi_get_edge_value(l, v, from, to, cxt);
    while !ok {
        lvi_solve(l);
        ok, r = lvi_get_edge_value(l, v, from, to, cxt);
    }
    return r;
}
// LazyValueInfoImpl::getValueAtUse
lvi_get_value_at_use :: (l: *Lvi, u: Use_Id) -> Vle {
    v := ir.u_val[u];
    cxt := ir.u_user[u];
    vl := lvi_get_value_in_block(l, v, inst_block(cxt), cxt);
    curr := u;
    MAX_USES_TO_INSPECT :: 3;
    for 1..MAX_USES_TO_INSPECT {
        has_cond := false;
        cond_val: Vle;
        curr_i := ir.u_user[curr];
        o := inst_op(curr_i);
        if o == .SELECT {
            if !is_guaranteed_not_to_be_undef(op(curr_i, 0), l.ac) break;
            opno := curr - ir.v_ops[curr_i];
            if opno == 1 { _, cond_val = lvi_get_value_from_condition(l, v, op(curr_i, 0), true, false); has_cond = true; }
            else if opno == 2 { _, cond_val = lvi_get_value_from_condition(l, v, op(curr_i, 0), false, false); has_cond = true; }
        } else if o == .PHI {
            _, cond_val = lvi_get_edge_value_local(l, v, ir.u_aux[curr], inst_block(curr_i), false);
            has_cond = true;
        }
        if has_cond vl = vle_intersect(vl, cond_val);
        if !has_one_use(curr_i) || !lvi_is_safe_to_speculatively_execute_with_variable_replaced(curr_i) break;
        if is_vector_type(vtype(v)) && !is_not_cross_lane_operation(curr_i) break;
        curr = ir.v_first_use[curr_i];
    }
    return vl;
}
// isSafeToSpeculativelyExecuteWithVariableReplaced(I, /*IgnoreUBImplyingAttrs=*/false)
lvi_is_safe_to_speculatively_execute_with_variable_replaced :: (i: Value_Id) -> bool {
    if inst_op(i) == .LOAD return false;
    return is_safe_to_speculatively_execute(i, false);
}

// ---------------------------------------------------------------- LazyValueInfo (the query interface)

// isKnownNonConstant
lvi_is_known_non_constant :: (v_in: Value_Id) -> bool {
    v := strip_pointer_casts(v_in);
    return is_inst(v) && inst_op(v) == .ALLOCA;
}

// ConstantInt::get(V->getType(), SingleVal)
lvi_const_of_single :: (t: Type_Id, a: APInt) -> Value_Id { return const_int_ap(t, a); }

// LazyValueInfo::getConstant
lvi_get_constant :: (lv: *Lvi, v: Value_Id, cxt: Value_Id) -> Value_Id {
    if lvi_is_known_non_constant(v) return NONE;
    l := lvi_impl(lv);
    r := lvi_get_value_in_block(l, v, inst_block(cxt), cxt);
    if r.tag == .CONSTANT return r.c;
    if vle_is_constant_range(r) {
        ok, e := cr_single_element(r.r);
        if ok return lvi_const_of_single(vtype(v), e);
    }
    return NONE;
}
// LazyValueInfo::getConstantRange
lvi_get_constant_range :: (lv: *Lvi, v: Value_Id, cxt: Value_Id, undef_allowed: bool) -> Const_Range {
    l := lvi_impl(lv);
    r := lvi_get_value_in_block(l, v, inst_block(cxt), cxt);
    return vle_as_constant_range(r, vtype(v), undef_allowed);
}
// LazyValueInfo::getConstantRangeAtUse
lvi_get_constant_range_at_use :: (lv: *Lvi, u: Use_Id, undef_allowed: bool) -> Const_Range {
    l := lvi_impl(lv);
    r := lvi_get_value_at_use(l, u);
    return vle_as_constant_range(r, vtype(ir.u_val[u]), undef_allowed);
}
// LazyValueInfo::getConstantOnEdge
lvi_get_constant_on_edge :: (lv: *Lvi, v: Value_Id, from: Value_Id, to: Value_Id, cxt: Value_Id = NONE) -> Value_Id {
    l := lvi_impl(lv);
    r := lvi_get_value_on_edge(l, v, from, to, cxt);
    if r.tag == .CONSTANT return r.c;
    if vle_is_constant_range(r) {
        ok, e := cr_single_element(r.r);
        if ok return lvi_const_of_single(vtype(v), e);
    }
    return NONE;
}
// LazyValueInfo::getConstantRangeOnEdge
lvi_get_constant_range_on_edge :: (lv: *Lvi, v: Value_Id, from: Value_Id, to: Value_Id, cxt: Value_Id = NONE) -> Const_Range {
    l := lvi_impl(lv);
    r := lvi_get_value_on_edge(l, v, from, to, cxt);
    return vle_as_constant_range(r, vtype(v), true);
}

// CmpInst::makeCmpResultType
lvi_cmp_result_type :: (t: Type_Id) -> Type_Id {
    if is_vector_type(t) return intern_type(type_kind(t), 0, type_count(t), .[ir.t_i1]);
    return ir.t_i1;
}

// getPredicateResult
lvi_get_predicate_result :: (pred: u8, c: Value_Id, val: Vle) -> Value_Id {
    if val.tag == .CONSTANT return cfo_compare_inst_operands(pred, val.c, c);
    res_ty := lvi_cmp_result_type(vtype(c));
    if vle_is_constant_range(val) {
        rhs := constant_to_range(c);
        if cr_icmp(val.r, pred, rhs) return const_int(res_ty, 1);
        if cr_icmp(val.r, icmp_inverse(pred), rhs) return const_int(res_ty, 0);
        return NONE;
    }
    if val.tag == .NOTCONSTANT {
        if pred == ICMP_EQ {
            res := cfo_compare_inst_operands(ICMP_NE, val.c, c);
            if res != NONE && is_null_value(res) return const_int(res_ty, 0);
        } else if pred == ICMP_NE {
            res := cfo_compare_inst_operands(ICMP_NE, val.c, c);
            if res != NONE && is_null_value(res) return const_int(res_ty, 1);
        }
        return NONE;
    }
    return NONE;
}

// LazyValueInfo::getPredicateOnEdge
lvi_get_predicate_on_edge :: (lv: *Lvi, pred: u8, v: Value_Id, c: Value_Id, from: Value_Id, to: Value_Id, cxt: Value_Id = NONE) -> Value_Id {
    l := lvi_impl(lv);
    r := lvi_get_value_on_edge(l, v, from, to, cxt);
    return lvi_get_predicate_result(pred, c, r);
}

// LazyValueInfo::getPredicateAt(Pred, V, Constant *C, CxtI, UseBlockValue)
lvi_get_predicate_at_const :: (lv: *Lvi, pred: u8, v: Value_Id, c: Value_Id, cxt: Value_Id, use_block_value: bool) -> Value_Id {
    if is_ptr_type(vtype(v)) && is_null_value(c) && is_known_non_zero(strip_pointer_casts_same_representation(v), lvi_dl_query()) {
        res_ty := lvi_cmp_result_type(vtype(c));
        if pred == ICMP_EQ return const_int(res_ty, 0);
        else if pred == ICMP_NE return const_int(res_ty, 1);
    }
    l := lvi_impl(lv);
    result := ifx use_block_value then lvi_get_value_in_block(l, v, inst_block(cxt), cxt) else lvi_get_value_at(l, v, cxt);
    ret := lvi_get_predicate_result(pred, c, result);
    if ret != NONE return ret;
    bb := inst_block(cxt);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    if preds.count == 0 return NONE;
    if is_inst(v) && inst_op(v) == .PHI && inst_block(v) == bb {
        baseline: Value_Id = NONE;
        n := phi_num_incoming(v);
        for k: 0..cast(s64) n - 1 {
            incoming := phi_value(v, cast(u32) k);
            pred_bb := phi_block(v, cast(u32) k);
            r := lvi_get_predicate_on_edge(lv, pred, incoming, c, pred_bb, bb, cxt);
            baseline = ifx k == 0 then r else (ifx baseline == r then baseline else NONE);
            if baseline == NONE break;
        }
        if baseline != NONE return baseline;
    }
    if !is_inst(v) || inst_block(v) != bb {
        baseline := lvi_get_predicate_on_edge(lv, pred, v, c, preds[0], bb, cxt);
        if baseline != NONE {
            all := true;
            for k: 1..preds.count - 1 {
                r := lvi_get_predicate_on_edge(lv, pred, v, c, preds[k], bb, cxt);
                if r != baseline { all = false; break; }
            }
            if all return baseline;
        }
    }
    return NONE;
}

// LazyValueInfo::getPredicateAt(Pred, LHS, RHS, CxtI, UseBlockValue)
lvi_get_predicate_at :: (lv: *Lvi, pred: u8, lhs: Value_Id, rhs: Value_Id, cxt: Value_Id, use_block_value: bool) -> Value_Id {
    if is_constant_kind(vkind(rhs)) return lvi_get_predicate_at_const(lv, pred, lhs, rhs, cxt, use_block_value);
    if is_constant_kind(vkind(lhs)) return lvi_get_predicate_at_const(lv, icmp_swapped(pred), rhs, lhs, cxt, use_block_value);
    if use_block_value {
        l := lvi_impl(lv);
        lr := lvi_get_value_in_block(l, lhs, inst_block(cxt), cxt);
        if lr.tag == .OVERDEFINED return NONE;
        rr := lvi_get_value_in_block(l, rhs, inst_block(cxt), cxt);
        return vle_get_compare(lr, pred, lvi_cmp_result_type(vtype(lhs)), rr);
    }
    return NONE;
}

// LazyValueInfo::forgetValue / eraseBlock / clear
lvi_forget_value :: (lv: *Lvi, v: Value_Id) { if lv.has_impl lvi_erase_value(lv, v); }
lvi_clear_cache :: (lv: *Lvi) { if lv.has_impl lvi_clear(lv); }

// ---------------------------------------------------------------- print<lazy-value-info>

lvi_print_ctx: struct {
    l: *Lvi;
    dt: *Dom_Tree;
};

// LazyValueInfoAnnotatedWriter::emitBasicBlockStartAnnot
lvi_annot_block :: (bb: Value_Id) {
    l := lvi_print_ctx.l;
    f := block_fn(bb);
    n := glob(f).nargs;
    for k: 0..cast(s64) n - 1 {
        a := fn_arg(f, cast(u32) k);
        r := lvi_get_value_in_block(l, a, bb);
        if r.tag == .UNKNOWN continue;
        out("; LatticeVal for: '"); write_operand(a, true); out("' is: "); out(vle_to_string(r)); out("\n");
    }
}
// LazyValueInfoAnnotatedWriter::emitInstructionAnnot
lvi_annot_inst :: (i: Value_Id) {
    l := lvi_print_ctx.l;
    dt := lvi_print_ctx.dt;
    parent := inst_block(i);
    printed: [..] Value_Id; printed.allocator = temp;
    print_result :: (l: *Lvi, i: Value_Id, bb: Value_Id, printed: *[..] Value_Id) {
        for printed.* if it == bb return;
        array_add(printed, bb);
        r := lvi_get_value_in_block(l, i, bb);
        out("; LatticeVal for: '");
        if is_referencing_md_node(i) out(printer_isolated_inst_to_string(i));   // a fresh SlotTracker numbering all metadata
        else print_instruction(i);
        out("' in BB: '"); write_operand(bb, false);
        out("' is: "); out(vle_to_string(r)); out("\n");
    }
    print_result(l, i, parent, *printed);
    succs: [..] Value_Id; succs.allocator = temp;
    block_successors(parent, *succs);
    for s: succs if dt_dominates(dt, parent, s) print_result(l, i, s, *printed);
    u := ir.v_first_use[i];
    while u != NONE {
        usr := ir.u_user[u];
        if is_inst(usr) {
            if inst_op(usr) != .PHI || dt_dominates(dt, parent, inst_block(usr)) print_result(l, i, inst_block(usr), *printed);
        }
        u = ir.u_next[u];
    }
}

// LazyValueInfoPrinterPass::run
print_lazy_value_info_run :: (f: Value_Id) -> Preserved {
    write_string(tprint("LVI for function '%':\n", vname(f)), to_standard_error = true);
    lv := get_lvi(f);
    dt := get_domtree(f);
    if !lv.has_impl return PRESERVE_ALL;
    lvi_print_ctx.l = lv;
    lvi_print_ctx.dt = dt;
    printer_begin_function(f);
    start := W.buf.count;
    print_annot_block = lvi_annot_block;
    print_annot_inst = lvi_annot_inst;
    print_function(f);
    print_annot_block = null;
    print_annot_inst = null;
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    write_string(s, to_standard_error = true);
    return PRESERVE_ALL;
}
