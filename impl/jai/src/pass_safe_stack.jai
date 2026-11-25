// SafeStack: a port of llvm/lib/CodeGen/SafeStack.cpp (IsSafeStackAlloca with the SCEV access ranges, findInsts,
// moveStaticAllocasToUnsafeStack, createStackRestorePoints, moveDynamicAllocasToUnsafeStack, the stack guard check,
// TryInlinePointerAddress) and llvm/lib/CodeGen/SafeStackLayout.cpp (StackLayout: the greedy region layout), with
// replaceDbgValueForAlloca (llvm/lib/Transforms/Utils/Local.cpp). Live ranges come from stack_lifetime.jai
// (StackLifetime, May liveness); the x86 target hooks from hardening_target.jai.

ss_cl: struct {
    coloring := true;              // -safe-stack-coloring
    layout := true;                // -safe-stack-layout
    use_pointer_address := false;  // -safestack-use-pointer-address
};

SS_STACK_ALIGNMENT :: 16;

// StackLifetime::LiveRange: a bit vector
Ss_Range :: [..] bool;
ss_range_overlaps :: (a: Ss_Range, b: Ss_Range) -> bool {
    n := min(a.count, b.count);
    for k: 0..n-1 if a[k] && b[k] return true;
    return false;
}
ss_range_join :: (a: *Ss_Range, b: Ss_Range) {
    if a.allocator.proc == null a.allocator = temp;
    while a.count < b.count array_add(a, false);
    for k: 0..b.count-1 if b[k] a.*[k] = true;
}
ss_range_copy :: (a: Ss_Range) -> Ss_Range { r: Ss_Range; r.allocator = temp; for a array_add(*r, it); return r; }
ss_range_make :: (n: s64, set: bool) -> Ss_Range { r: Ss_Range; r.allocator = temp; for 0..n-1 array_add(*r, set); return r; }

// ---------------------------------------------------------------- SafeStackLayout.cpp

Ss_Object :: struct { handle: Value_Id; size: u64; align: u64; range: Ss_Range; }
Ss_Region :: struct { start: u64; end: u64; range: Ss_Range; }
Ss_Layout :: struct {
    max_align: u64;
    objects: [..] Ss_Object;
    regions: [..] Ss_Region;
    off_keys: [..] Value_Id;
    off_vals: [..] u64;
    align_keys: [..] Value_Id;
    align_vals: [..] u64;
}
ssl_add_object :: (l: *Ss_Layout, v: Value_Id, size: u64, align: u64, range: Ss_Range) {
    if l.objects.allocator.proc == null {
        l.objects.allocator = temp; l.regions.allocator = temp; l.off_keys.allocator = temp; l.off_vals.allocator = temp;
        l.align_keys.allocator = temp; l.align_vals.allocator = temp;
    }
    array_add(*l.objects, .{v, size & 0xFFFF_FFFF, align, ss_range_copy(range)});   // unsigned Size
    found := false;
    for l.align_keys if it == v { l.align_vals[it_index] = align; found = true; break; }
    if !found { array_add(*l.align_keys, v); array_add(*l.align_vals, align); }
    l.max_align = max(l.max_align, align);
}
ssl_set_offset :: (l: *Ss_Layout, v: Value_Id, off: u64) {
    for l.off_keys if it == v { l.off_vals[it_index] = off; return; }
    array_add(*l.off_keys, v); array_add(*l.off_vals, off);
}
ssl_get_offset :: (l: *Ss_Layout, v: Value_Id) -> u64 {
    for l.off_keys if it == v return l.off_vals[it_index];
    assert(false, "No offset for the object");
    return 0;
}
ssl_get_align :: (l: *Ss_Layout, v: Value_Id) -> u64 {
    for l.align_keys if it == v return l.align_vals[it_index];
    return 1;
}
// AdjustStackOffset (unsigned arithmetic)
ssl_adjust :: (offset: u64, size: u64, align: u64) -> u64 { return (align_to((offset + size) & 0xFFFF_FFFF, align) - size) & 0xFFFF_FFFF; }

// StackLayout::layoutObject
ssl_layout_object :: (l: *Ss_Layout, obj: *Ss_Object) {
    if !ss_cl.layout {
        last_end := ifx l.regions.count then l.regions[l.regions.count - 1].end else 0;
        start := ssl_adjust(last_end, obj.size, obj.align);
        end := (start + obj.size) & 0xFFFF_FFFF;
        array_add(*l.regions, .{start, end, ss_range_copy(obj.range)});
        ssl_set_offset(l, obj.handle, end);
        return;
    }
    start := ssl_adjust(0, obj.size, obj.align);
    end := (start + obj.size) & 0xFFFF_FFFF;
    for r: l.regions {
        if start >= r.end continue;
        if ss_range_overlaps(obj.range, r.range) {
            start = ssl_adjust(r.end, obj.size, obj.align);
            end = (start + obj.size) & 0xFFFF_FFFF;
            continue;
        }
        if end <= r.end break;
    }
    last_end := ifx l.regions.count then l.regions[l.regions.count - 1].end else 0;
    if end > last_end {
        if start > last_end {
            array_add(*l.regions, .{last_end, start, ss_range_make(0, false)});
            last_end = start;
        }
        array_add(*l.regions, .{last_end, end, ss_range_copy(obj.range)});
        last_end = end;
    }
    // split starting and ending regions
    i := 0;
    while i < l.regions.count {
        r := *l.regions[i];
        if start > r.start && start < r.end {
            r0 := r.*; r0.range = ss_range_copy(r.range);
            r.start = start; r0.end = start;
            array_insert_at(*l.regions, r0, i);
            i += 1;
            continue;
        }
        if end > r.start && end < r.end {
            r0 := r.*; r0.range = ss_range_copy(r.range);
            r0.end = end; r.start = end;
            array_insert_at(*l.regions, r0, i);
            break;
        }
        i += 1;
    }
    for * r: l.regions {
        if start < r.end && end > r.start ss_range_join(*r.range, obj.range);
        if end <= r.end break;
    }
    ssl_set_offset(l, obj.handle, end);
}
// StackLayout::computeLayout
ssl_compute_layout :: (l: *Ss_Layout) {
    if l.objects.count > 2 {
        // stable_sort(drop_begin(StackObjects)) by size, largest first
        for x: 2..l.objects.count-1 {
            v := l.objects[x];
            y := x;
            while y > 1 && l.objects[y - 1].size < v.size { l.objects[y] = l.objects[y - 1]; y -= 1; }
            l.objects[y] = v;
        }
    }
    for * l.objects ssl_layout_object(l, it);
}
ssl_frame_size :: (l: *Ss_Layout) -> u64 { return ifx l.regions.count then l.regions[l.regions.count - 1].end else 0; }

// ---------------------------------------------------------------- SafeStack

Safe_Stack :: struct {
    f: Value_Id;
    h: Hd_Target;
    stack_ptr_ty: Type_Id;
    addr_ty: Type_Id;
    unsafe_stack_ptr: Value_Id = NONE;
}

ss_static_alloca_size :: (ai: Value_Id) -> u64 {
    if type_is_scalable(inst(ai).ty2) return 0;
    ok, s := alloca_allocation_size(ai);
    if ok return s;
    return 0;
}

// IsAccessSafe(Addr, AccessSize, AllocaPtr, AllocaSize)
ss_is_access_safe :: (addr: Value_Id, access_size: u64, alloca_ptr: Value_Id, alloca_size: u64) -> bool {
    e := sc_get_scev(addr);
    base := sc_get_pointer_base(e);
    if !sc_is_unknown(base) || sc_value(base) != alloca_ptr return false;
    expr := sc_remove_pointer_base(e);
    bw := sc_bits(expr);
    start := sc_unsigned_range(expr);
    size_r := cr_new(ap_zero(bw), ap_from_u64(bw, access_size));
    access := cr_add(start, size_r);
    alloca_r := cr_new(ap_zero(bw), ap_from_u64(bw, alloca_size));
    return cr_contains_range(alloca_r, access);
}
// IsMemIntrinsicSafe
ss_is_mem_intrinsic_safe :: (mi: Value_Id, used: Value_Id, alloca_ptr: Value_Id, alloca_size: u64) -> bool {
    id := call_iid(mi);
    if id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE {
        if call_arg(mi, 1) != used && call_arg(mi, 0) != used return true;
    } else {
        if call_arg(mi, 0) != used return true;
    }
    len := call_arg(mi, 2);
    if !is_scalar_const_int(len) return false;
    return ss_is_access_safe(used, const_int_zext(len), alloca_ptr, alloca_size);
}
ss_is_mem_intrinsic :: (id: Intrinsic_Id) -> bool {
    return id == IID_MEMCPY || id == IID_MEMCPY_INLINE || id == IID_MEMMOVE || id == IID_MEMSET || id == IID_MEMSET_INLINE;
}

// IsSafeStackAlloca
ss_is_safe_stack_alloca :: (alloca_ptr: Value_Id, alloca_size: u64) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, alloca_ptr);
    while wl.count {
        v := pop(*wl);
        u := ir.v_first_use[v];
        while u != NONE {
            defer u = ir.u_next[u];
            i := ir.u_user[u];
            if !is_inst(i) fatal("safe-stack: a non-instruction user of a stack object");
            o := inst_op(i);
            if o == {
                case .LOAD;
                    if type_is_scalable(vtype(i)) return false;
                    if !ss_is_access_safe(v, dl_type_store_size(vtype(i)), alloca_ptr, alloca_size) return false;
                case .VAARG;
                case .STORE;
                    if v == op(i, 0) return false;
                    if type_is_scalable(vtype(op(i, 0))) return false;
                    if !ss_is_access_safe(v, dl_type_store_size(vtype(op(i, 0))), alloca_ptr, alloca_size) return false;
                case .RET; return false;
                case .CALL; #through; case .INVOKE;
                    if is_lifetime_start_or_end(i) continue;
                    if o == .CALL && ss_is_mem_intrinsic(call_iid(i)) {
                        if !ss_is_mem_intrinsic_safe(i, v, alloca_ptr, alloca_size) return false;
                        continue;
                    }
                    n := call_num_args(i);
                    for k: 0..cast(s64) n - 1 {
                        if call_arg(i, cast(u32) k) != v continue;
                        if !(call_does_not_capture(i, cast(u32) k) &&
                             (call_data_operand_does_not_access(i, cast(u32) k) || call_memory_effects(i) == 0)) return false;
                    }
                    continue;
                case;
                    if !table_contains(*visited, i) { table_set(*visited, i, true); array_add(*wl, i); }
            }
        }
    }
    return true;
}

// getStackGuard (SafeStack's: a plain load)
ss_get_stack_guard :: (s: *Safe_Stack, b: *Irb) -> Value_Id {
    g := hd_ir_stack_guard(*s.h);
    if g == NONE {
        hd_insert_ssp_declarations(*s.h);
        return irb_call(b, get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.stackguard")), .[]);
    }
    return irb_load(b, s.stack_ptr_ty, g, dl_abi_align(s.stack_ptr_ty), false, "StackGuard");
}

// checkStackGuard
ss_check_stack_guard :: (s: *Safe_Stack, b: *Irb, ri: Value_Id, slot: Value_Id, guard: Value_Id) {
    v := irb_load(b, s.stack_ptr_ty, slot, dl_abi_align(s.stack_ptr_ty));
    cmp := irb_icmp(b, ICMP_NE, guard, v);
    weights := md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 2147481600)), md_value(const_int(ir.t_i32, 2048))], false);
    term := sbi_if_then(cmp, ri, true, weights);
    chk := hd_stack_chk_fail_name(*s.h);
    if chk.count == 0 fatal("no libcall available for stackprotector check fail");
    fb: Irb; irb_set_before(*fb, term);
    callee := lookup_global(chk);
    fty := type_func(ir.t_void, .[], false);
    if callee == NONE callee = get_or_insert_function(chk, fty);
    irb_call_callee(*fb, callee, fty, .[]);
}

// replaceDbgValueForAlloca
ss_replace_dbg_value_for_alloca :: (f: Value_Id, ai: Value_Id, new_addr: Value_Id, offset: s64) {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(f, ai, *users);
    for r: users {
        rec := dbgr(r);
        if rec.kind != .VALUE continue;
        e := rec.expr;
        if e == NONE { continue; }
        elts := diexpr_elts(e);
        if elts.count < 1 || elts[0] != DW_OP_DEREF_ continue;
        if offset != 0 e = diexpr_prepend(e, 0, offset);
        dbgr(r).expr = e;
        dbgr_replace_variable_location_op_idx(r, 0, new_addr);
    }
}

// IRBuilder::CreatePtrAdd(Ptr, Offset, Name): getelementptr i8 (no flags)
irb_ptr_add_plain :: (b: *Irb, p: Value_Id, off: Value_Id, name: string = "") -> Value_Id { return irb_gep(b, ir.t_i8, p, .[off], name, 0); }
ss_i32_neg :: (x: u64) -> Value_Id { return const_int(ir.t_i32, (0 - x) & 0xFFFF_FFFF); }
// int(-Offset) of an unsigned Offset
ss_neg_int :: (x: u64) -> s64 { return cast(s64) cast,no_check(s32) cast,no_check(u32) ((0 - x) & 0xFFFF_FFFF); }

// moveStaticAllocasToUnsafeStack
ss_move_static_allocas :: (s: *Safe_Stack, b: *Irb, statics: [] Value_Id, byvals: [] Value_Id, base_ptr_in: Value_Id, guard_slot: Value_Id) -> Value_Id {
    base_ptr := base_ptr_in;
    f := s.f;
    if statics.count == 0 && byvals.count == 0 return base_ptr;
    // StackLifetime's constructor collects the markers (and numbers the instructions) even when run() is not
    // called (-safe-stack-coloring=0); the live ranges are only used with coloring
    sl := stack_lifetime_run(f, statics, true);
    for bi: 0..sl.blocks.count - 1 for m: sl.markers[bi] erase_inst_with_metadata(m.inst);
    full := ss_range_make(sl.n_insts, true);
    no_coloring := ss_range_make(1, true);
    l: Ss_Layout;
    l.max_align = 1;
    if guard_slot != NONE ssl_add_object(*l, guard_slot, ss_static_alloca_size(guard_slot), inst(guard_slot).align, full);
    for arg: byvals {
        ty := attr_set_find(arg_attrs(arg), .ByVal).ty;
        size := dl_type_store_size(ty);
        if size == 0 size = 1;
        al := dl_pref_align(ty);
        pa := fn_param_align(s.f, arg_no(arg));
        if pa al = max(al, pa);
        ssl_add_object(*l, arg, size, al, full);
    }
    for ai, k: statics {
        size := ss_static_alloca_size(ai);
        if size == 0 size = 1;
        r := ifx ss_cl.coloring then sl.ranges[k] else no_coloring;
        ssl_add_object(*l, ai, size, inst(ai).align, r);
    }
    ssl_compute_layout(*l);
    frame_align := l.max_align;
    if frame_align > SS_STACK_ALIGNMENT {
        irb_set_before(b, inst(base_ptr).next);
        mask := const_int(s.addr_ty, ~(frame_align - 1));
        base_ptr = irb_call(b, get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.ptrmask"), .[s.stack_ptr_ty, s.addr_ty]), .[base_ptr, mask]);
    }
    irb_set_before(b, inst(base_ptr).next);
    if guard_slot != NONE {
        off := ssl_get_offset(*l, guard_slot);
        o := irb_ptr_add_plain(b, base_ptr, ss_i32_neg(off));
        // CreateBitCast(Off, Ty, "StackGuardSlot"): the GEP itself when the types agree
        if vtype(o) != vtype(guard_slot) o = irb_cast(b, .BITCAST, o, vtype(guard_slot), "StackGuardSlot");
        rauw_with_metadata(guard_slot, o);
        erase_inst_with_metadata(guard_slot);
    }
    for arg: byvals {
        off := ssl_get_offset(*l, arg);
        al := ssl_get_align(*l, arg);
        ty := attr_set_find(arg_attrs(arg), .ByVal).ty;
        size := dl_type_store_size(ty);
        if size == 0 size = 1;
        o := irb_ptr_add_plain(b, base_ptr, ss_i32_neg(off));
        new_arg := o;
        if vtype(o) != vtype(arg) new_arg = irb_cast(b, .BITCAST, o, vtype(arg), tconcat(vname(arg), ".unsafe-byval"));
        replace_dbg_declare(f, arg, base_ptr, DIEXPR_APPLY_OFFSET, ss_neg_int(off));
        rauw_with_metadata(arg, new_arg);
        irb_set_before(b, inst(new_arg).next);
        irb_memcpy(b, o, al, arg, fn_param_align(s.f, arg_no(arg)), const_int(ir.t_i64, size), false);
    }
    for ai: statics {
        irb_set_before(b, ai);
        off := ssl_get_offset(*l, ai);
        replace_dbg_declare(f, ai, base_ptr, DIEXPR_APPLY_OFFSET, ss_neg_int(off));
        ss_replace_dbg_value_for_alloca(f, ai, base_ptr, ss_neg_int(off));
        while has_uses(ai) {
            u := ir.v_first_use[ai];
            usr := ir.u_user[u];
            if is_lifetime_start_or_end(usr) { erase_inst_with_metadata(usr); continue; }
            before := usr;
            ib: Value_Id = NONE;
            if is_phi(usr) { ib = ir.u_aux[u]; before = block_terminator(ib); }
            ub: Irb; irb_set_before(*ub, before);
            o := irb_ptr_add_plain(*ub, base_ptr, ss_i32_neg(off));
            // CreateAddrSpaceCast(Off, AI->getType(), Name): the GEP itself when the types agree
            if vtype(o) != vtype(ai) o = irb_cast(*ub, .ADDRSPACECAST, o, vtype(ai), tconcat(vname(ai), ".unsafe"));
            if is_phi(usr) phi_set_incoming_value_for_block(usr, ib, o);
            else use_set(u, o);
        }
        erase_inst_with_metadata(ai);
    }
    frame_size := align_to(ssl_frame_size(*l), SS_STACK_ALIGNMENT) & 0xFFFF_FFFF;   // unsigned FrameSize
    md := md_tuple(.[md_string("unsafe-stack-size"), md_value(const_int(ir.t_i32, frame_size))], false);
    set_metadata(f, MD_ANNOTATION_KIND, md);
    irb_set_before(b, inst(base_ptr).next);
    static_top := irb_ptr_add_plain(b, base_ptr, ss_i32_neg(frame_size), "unsafe_stack_static_top");
    irb_store(b, static_top, s.unsafe_stack_ptr, dl_abi_align(vtype(static_top)));
    return static_top;
}

// createStackRestorePoints
ss_create_stack_restore_points :: (s: *Safe_Stack, b: *Irb, points: [] Value_Id, static_top: Value_Id, need_dynamic_top: bool) -> Value_Id {
    if points.count == 0 return NONE;
    dyn_top: Value_Id = NONE;
    if need_dynamic_top {
        dyn_top = irb_alloca(b, s.stack_ptr_ty, NONE, "unsafe_stack_dynamic_ptr");
        irb_store(b, static_top, dyn_top, dl_abi_align(vtype(static_top)));
    }
    for i: points {
        irb_set_before(b, inst(i).next);
        cur := ifx dyn_top != NONE then irb_load(b, s.stack_ptr_ty, dyn_top, dl_abi_align(s.stack_ptr_ty)) else static_top;
        irb_store(b, cur, s.unsafe_stack_ptr, dl_abi_align(vtype(cur)));
    }
    return dyn_top;
}

// moveDynamicAllocasToUnsafeStack
ss_move_dynamic_allocas :: (s: *Safe_Stack, dyn_top: Value_Id, dynamics: [] Value_Id) {
    f := s.f;
    for ai: dynamics {
        b: Irb; irb_set_before(*b, ai);
        size := irb_allocation_size(*b, s.addr_ty, ai);
        sp := irb_load(*b, s.stack_ptr_ty, s.unsafe_stack_ptr, dl_abi_align(s.stack_ptr_ty));
        neg := irb_binop(*b, .SUB, const_null_value(vtype(size)), size);
        sp = irb_ptr_add_plain(*b, sp, neg);
        al := max(inst(ai).align, SS_STACK_ALIGNMENT);
        new_top := irb_call(*b, get_or_insert_intrinsic_declaration(intrinsic_id_by_name("llvm.ptrmask"), .[s.stack_ptr_ty, s.addr_ty]), .[sp, const_int(s.addr_ty, ~(al - 1))]);
        irb_store(*b, new_top, s.unsafe_stack_ptr, dl_abi_align(s.stack_ptr_ty));
        if dyn_top != NONE irb_store(*b, new_top, dyn_top, dl_abi_align(s.stack_ptr_ty));
        new_ai := new_top;
        if vtype(new_top) != vtype(ai) new_ai = irb_pointer_cast(*b, new_top, vtype(ai));   // CreatePointerCast
        if vname(ai).count && is_inst(new_ai) take_name(new_ai, ai);
        replace_dbg_declare(f, ai, new_ai, DIEXPR_APPLY_OFFSET, 0);
        rauw_with_metadata(ai, new_ai);
        erase_inst_with_metadata(ai);
    }
    if dynamics.count {
        for :early_inc i: fn_insts(f) {
            id := call_iid(i);
            if id == IID_ARC_STACKSAVE {
                b: Irb; irb_set_before(*b, i);
                li := irb_load(*b, s.stack_ptr_ty, s.unsafe_stack_ptr, dl_abi_align(s.stack_ptr_ty));
                take_name(li, i);
                rauw_with_metadata(i, li);
                erase_inst_with_metadata(i);
            } else if id == IID_ARC_STACKRESTORE {
                b: Irb; irb_set_before(*b, i);
                si := irb_store(*b, call_arg(i, 0), s.unsafe_stack_ptr, dl_abi_align(vtype(call_arg(i, 0))));
                erase_inst_with_metadata(i);
            }
        }
    }
}

// TryInlinePointerAddress
ss_try_inline_pointer_address :: (s: *Safe_Stack) {
    ci := s.unsafe_stack_ptr;
    if !is_inst(ci) || inst_op(ci) != .CALL return;
    if fn_has_fn_attr(s.f, .OptimizeNone) return;
    callee := call_called_function(ci);
    if callee == NONE || is_declaration(callee) return;
    fatal("safe-stack: inlining the unsafe stack pointer address function is not supported yet");
}

// SafeStack::run
ss_run :: (s: *Safe_Stack) -> bool {
    f := s.f;
    statics: [..] Value_Id; statics.allocator = temp;
    dynamics: [..] Value_Id; dynamics.allocator = temp;
    byvals: [..] Value_Id; byvals.allocator = temp;
    returns: [..] Value_Id; returns.allocator = temp;
    restore_points: [..] Value_Id; restore_points.allocator = temp;
    // findInsts
    for i: fn_insts(f) {
        o := inst_op(i);
        if o == .ALLOCA {
            size := ss_static_alloca_size(i);
            if ss_is_safe_stack_alloca(i, size) continue;
            if is_static_alloca(i) array_add(*statics, i); else array_add(*dynamics, i);
        } else if o == .RET {
            mt := block_terminating_must_tail_call(inst_block(i));
            array_add(*returns, ifx mt != NONE then mt else i);
        } else if o == .CALL {
            if call_called_function(i) != NONE && call_has_fn_attr(i, .ReturnsTwice) array_add(*restore_points, i);
            else if call_iid(i) == IID_GCROOT fatal("gcroot intrinsic not compatible with safestack attribute");
        } else if o == .LANDINGPAD array_add(*restore_points, i);
    }
    np := func_nparams(glob(f).value_type);
    for k: 0..cast(s64) np - 1 {
        a := fn_arg(f, cast(u32) k);
        if !arg_has_attr(a, .ByVal) continue;
        size := dl_type_store_size(attr_set_find(arg_attrs(a), .ByVal).ty);
        if ss_is_safe_stack_alloca(a, size) continue;
        array_add(*byvals, a);
    }
    if statics.count == 0 && dynamics.count == 0 && byvals.count == 0 && restore_points.count == 0 return false;
    entry := fn_entry(f);
    b: Irb; irb_set_at(*b, entry, block_first_insertion_pt(entry), true);
    sp := fn_subprogram(f);
    if sp != NONE b.dbg = di_location_get(ir.md_ints[ir.mds[sp].ints + 1], 0, sp, NONE);
    if ss_cl.use_pointer_address {
        fn := get_or_insert_function("__safestack_pointer_address", type_func(type_ptr(0), .[], false));
        s.unsafe_stack_ptr = irb_call(*b, fn, .[]);
    } else {
        s.unsafe_stack_ptr = hd_safe_stack_pointer_location(*s.h, *b);
    }
    base_ptr := irb_load(*b, s.stack_ptr_ty, s.unsafe_stack_ptr, dl_abi_align(s.stack_ptr_ty), false, "unsafe_stack_ptr");
    guard_slot: Value_Id = NONE;
    if fn_has_fn_attr(f, .StackProtect) || fn_has_fn_attr(f, .StackProtectStrong) || fn_has_fn_attr(f, .StackProtectReq) {
        guard := ss_get_stack_guard(s, *b);
        guard_slot = irb_alloca(*b, s.stack_ptr_ty, NONE);
        irb_store(*b, guard, guard_slot, dl_abi_align(s.stack_ptr_ty));
        for ri: returns {
            rb: Irb; irb_set_before(*rb, ri);
            ss_check_stack_guard(s, *rb, ri, guard_slot, guard);
        }
    }
    static_top := ss_move_static_allocas(s, *b, statics, byvals, base_ptr, guard_slot);
    dyn_top := ss_create_stack_restore_points(s, *b, restore_points, static_top, dynamics.count > 0);
    ss_move_dynamic_allocas(s, dyn_top, dynamics);
    for ri: returns {
        irb_set_before(*b, ri);
        irb_store(*b, base_ptr, s.unsafe_stack_ptr, dl_abi_align(s.stack_ptr_ty));
    }
    ss_try_inline_pointer_address(s);
    return true;
}

safe_stack_run :: (f: Value_Id) -> Preserved {
    if !fn_has_fn_attr(f, .SafeStack) return PRESERVE_ALL;
    if is_declaration(f) return PRESERVE_ALL;
    s: Safe_Stack;
    s.f = f;
    s.h = hd_target("safe-stack");
    get_domtree(f);
    get_scev(f);
    if !libcall_lowering_info_cached fatal("'LibcallLoweringModuleAnalysis' analysis required");
    s.stack_ptr_ty = type_ptr(dl.alloca_as);
    s.addr_ty = type_int(dl_index_bits(s.stack_ptr_ty));
    changed := ss_run(*s);
    if !changed return PRESERVE_ALL;
    return PRESERVE_NONE;
}
