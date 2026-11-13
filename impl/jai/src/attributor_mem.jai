// AAHeapToStackFunction and AAPrivatizablePtr (Argument, Floating, CallSiteArgument, CallSiteReturned, Returned):
// a port of their parts of llvm/lib/Transforms/IPO/AttributorAttributes.cpp, with getAllocSize from
// llvm/lib/Analysis/MemoryBuiltins.cpp (with the Attributor's constant mapper).

// ---------------------------------------------------------------- AAHeapToStack

H2S_STACK_DUE_TO_USE :: cast(u8) 0;
H2S_STACK_DUE_TO_FREE :: cast(u8) 1;
H2S_INVALID :: cast(u8) 2;
H2s_Alloc :: struct {
    cb: Value_Id;
    globalized_local: bool;
    status: u8;
    has_potentially_freeing_unknown_uses: bool;
    move_alloca_into_entry: bool = true;
    free_calls: [..] Value_Id;           // PotentialFreeCalls (SmallSetVector)
}
H2s_Dealloc :: struct {
    cb: Value_Id;
    freed_op: Value_Id;
    might_free_unknown: bool;
    alloc_calls: [..] Value_Id;          // PotentialAllocationCalls (SmallSetVector)
}
H2s_Ext :: struct {
    allocs: [..] *H2s_Alloc;             // MapVector<CallBase *, AllocationInfo *> (in insertion order)
    alloc_idx: Table(Value_Id, s64);
    deallocs: [..] *H2s_Dealloc;
    dealloc_idx: Table(Value_Id, s64);
}
h2s_ext :: inline (i: u32) -> *H2s_Ext { return cast(*H2s_Ext) aa(i).x; }
h2s_construct :: (i: u32) { aa(i).x = New(H2s_Ext); }
h2s_alloc_of :: (e: *H2s_Ext, cb: Value_Id) -> *H2s_Alloc { found, k := table_find(*e.alloc_idx, cb); if !found return null; return e.allocs[k]; }
h2s_dealloc_of :: (e: *H2s_Ext, cb: Value_Id) -> *H2s_Dealloc { found, k := table_find(*e.dealloc_idx, cb); if !found return null; return e.deallocs[k]; }
h2s_is_globalized_local :: (cb: Value_Id) -> bool {
    for attr_set_items(call_fn_attrs(cb)) if it.kind == .STRING_ATTR && it.key == "alloc-family" return it.val == "__kmpc_alloc_shared";
    return false;
}

h2s_initialize :: (i: u32) {
    e := h2s_ext(i);
    uai := false;
    ok := true;
    for cb: atr_call_like_insts(i, *uai, *ok, false, true) {
        fo := get_freed_operand(cb);
        if fo != NONE {
            if !table_contains(*e.dealloc_idx, cb) {
                d := New(H2s_Dealloc);
                d.cb = cb; d.freed_op = fo;
                array_add(*e.deallocs, d);
                table_set(*e.dealloc_idx, cb, e.deallocs.count - 1);
            } else {
                d := h2s_dealloc_of(e, cb);
                d.* = .{}; d.cb = cb; d.freed_op = fo;
            }
            continue;
        }
        if is_removable_alloc(cb) {
            if get_initial_value_of_allocation(cb, ir.t_i8) != NONE {
                a := New(H2s_Alloc);
                a.cb = cb;
                a.globalized_local = h2s_is_globalized_local(cb);
                if !table_contains(*e.alloc_idx, cb) {
                    array_add(*e.allocs, a);
                    table_set(*e.alloc_idx, cb, e.allocs.count - 1);
                } else {
                    found, k := table_find(*e.alloc_idx, cb);
                    e.allocs[k] = a;
                }
            }
        }
    }
    for e.allocs atr_register_simplification_callback(irp_cs_returned(it.cb));
    for e.deallocs atr_register_simplification_callback(irp_cs_returned(it.cb));
}

// isAssumedHeapToStack / isAssumedHeapToStackRemovedFree
h2s_is_assumed_heap_to_stack :: (i: u32, cb: Value_Id) -> bool {
    if !aa_is_valid(i) return false;
    a := h2s_alloc_of(h2s_ext(i), cb);
    return a != null && a.status != H2S_INVALID;
}
h2s_is_assumed_removed_free :: (i: u32, cb: Value_Id) -> bool {
    if !aa_is_valid(i) return false;
    for a: h2s_ext(i).allocs {
        if a.status == H2S_INVALID continue;
        if copies_contains(*a.free_calls, cb) return true;
    }
    return false;
}

// getAPInt: (has value, value)
h2s_get_apint :: (i: u32, v: Value_Id) -> (bool, APInt) {
    uai := false;
    c := atr_get_assumed_constant_value(v, i, *uai);
    if c == OV_NOVAL return true, ap_zero(64);
    if c != NONE && vkind(c) == .C_INT return true, const_ap(c);
    none: APInt;
    return false, none;
}
// getSize: getAllocSize(CB, TLI, Mapper) with the assumed-constant mapper
h2s_get_size :: (i: u32, cb: Value_Id) -> (bool, APInt) {
    none: APInt;
    ok, d := mb_allocation_size_data(cb);
    if !ok return false, none;
    bits := dl_index_type_size_bits(vtype(cb));
    mapper :: (i: u32, v: Value_Id) -> Value_Id {
        uai := false;
        c := atr_get_assumed_constant_value(v, i, *uai);
        if c != OV_NOVAL && c != NONE return c;
        return v;
    }
    if d.ty == AT_STRDUP {
        size := ap_from_u64(bits, get_string_length(mapper(i, call_arg(cb, 0))));
        if ap_is_zero(size) return false, none;
        if d.fst > 0 {
            a := mapper(i, call_arg(cb, cast(u32) d.fst));
            if vkind(a) != .C_INT return false, none;
            max_size := ap_zext(const_ap(a), bits);
            if ap_ugt(size, max_size) size = ap_add(max_size, ap_from_u64(bits, 1));
        }
        return true, size;
    }
    a := mapper(i, call_arg(cb, cast(u32) d.fst));
    if vkind(a) != .C_INT return false, none;
    size := const_ap(a);
    if !mb_checked_zext_or_trunc(*size, bits) return false, none;
    if d.snd < 0 return true, size;
    b := mapper(i, call_arg(cb, cast(u32) d.snd));
    if vkind(b) != .C_INT return false, none;
    ne := const_ap(b);
    if !mb_checked_zext_or_trunc(*ne, bits) return false, none;
    r, ov := ap_umul_ov(size, ne);
    if ov return false, none;
    return true, r;
}

h2s_update :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    e := h2s_ext(i);
    f := irp_anchor_scope(aa(i).pos);
    lv := atr_get_aa(.IS_DEAD, irp_function(f), i, DEP_NONE);
    stack_shared := atr_stack_is_accessible_by_other_threads();
    li := atr_li(f);
    irreducible_known := false;
    irreducible := false;
    is_in_loop :: (bb: Value_Id, f: Value_Id, li: *Loop_Info, known: *bool, irr: *bool) -> bool {
        if fn_entry(f) == bb return false;
        if !known.* { irr.* = mbe_may_contain_irreducible_control(f, li); known.* = true; }
        if irr.* return true;
        if !li return true;
        return li_loop_for(li, bb) != NONE;
    }
    has_updated_frees := false;
    update_frees :: (i: u32, e: *H2s_Ext, lv: u32) {
        for di: e.deallocs {
            if di.might_free_unknown continue;
            uai := false;
            if atr_is_assumed_dead_inst(di.cb, i, lv, *uai, true) continue;
            obj := get_underlying_object(di.freed_op);
            if obj == NONE { di.might_free_unknown = true; continue; }
            if vkind(obj) == .C_NULL || is_undef_value(obj) continue;
            if !irp_is_call(obj) { di.might_free_unknown = true; continue; }
            a := h2s_alloc_of(e, obj);
            if !a { di.might_free_unknown = true; continue; }
            copies_insert(*di.alloc_calls, obj);
        }
    }
    free_check :: (i: u32, e: *H2s_Ext, a: *H2s_Alloc, lv: u32, stack_shared: bool, has_updated: *bool) -> bool {
        if !stack_shared {
            ns, _ := atr_has_assumed_ir_attr(.NoSync, i, aa(i).pos, DEP_OPTIONAL);
            if !ns return false;
        }
        if !has_updated.* { has_updated.* = true; update_frees(i, e, lv); }
        if a.free_calls.count != 1 return false;
        unique := a.free_calls[0];
        di := h2s_dealloc_of(e, unique);
        if !di return false;
        if di.might_free_unknown return false;
        if di.alloc_calls.count == 0 return true;
        if di.alloc_calls.count > 1 return false;
        if di.alloc_calls[0] != a.cb return false;
        if !a.globalized_local {
            ctx := ifx inst_op(a.cb) == .INVOKE then a.cb else inst_next(a.cb);
            if !mbe_find_in_context_of_pp(unique, ctx) return false;
        }
        return true;
    }
    uses_check :: (i: u32, e: *H2s_Ext, a: *H2s_Alloc) -> bool {
        valid := true;
        ok, w := atr_uses_begin(i, a.cb, false, DEP_OPTIONAL, true, EQU_HEAP_TO_STACK);
        if !ok return false;
        while true {
            u := atr_uses_next(*w);
            if u == NONE break;
            user := ir.u_user[u];
            follow := false;
            o := inst_op(user);
            if o == .LOAD { }
            else if o == .STORE { if op(user, 0) == ir.u_val[u] valid = false; }
            else if is_call_base(user) {
                if !call_is_arg_operand(user, u) || call_is_lifetime_start_or_end(user) { }
                else if h2s_dealloc_of(e, user) { copies_insert(*a.free_calls, user); }
                else {
                    cp := irp_cs_argument(user, use_arg_no(u));
                    nc, _ := atr_has_assumed_ir_attr(.Captures, i, cp, DEP_OPTIONAL);
                    nf, _ := atr_has_assumed_ir_attr(.NoFree, i, cp, DEP_OPTIONAL);
                    if !nc || (!a.globalized_local && !nf) {
                        a.has_potentially_freeing_unknown_uses |= !nf;
                        valid = false;
                    }
                }
            } else if o == .GEP || o == .BITCAST || o == .PHI || o == .SELECT {
                follow = true;
            } else {
                valid = false;
            }
            if follow atr_uses_follow(*w, u);
        }
        if w.failed return false;
        return valid;
    }
    for a: e.allocs {
        if a.status == H2S_INVALID continue;
        al := get_alloc_alignment(a.cb);
        if al != NONE {
            ok, ap := h2s_get_apint(i, al);
            if !ok { a.status = H2S_INVALID; changed = ATR_CHANGED; continue; }
            if ap_ugt_u64(ap, 1 << 32) || !ap_is_power_of_2(ap) { a.status = H2S_INVALID; changed = ATR_CHANGED; continue; }
        }
        has_size, size := h2s_get_size(i, a.cb);
        if !a.globalized_local && atr_max_heap_to_stack_size != -1 {
            if !has_size || ap_ugt_u64(size, cast(u64) atr_max_heap_to_stack_size) {
                a.status = H2S_INVALID;
                changed = ATR_CHANGED;
                continue;
            }
        }
        if a.status == H2S_STACK_DUE_TO_USE {
            if !uses_check(i, e, a) {
                a.status = H2S_STACK_DUE_TO_FREE;
                if !free_check(i, e, a, lv, stack_shared, *has_updated_frees) { a.status = H2S_INVALID; changed = ATR_CHANGED; }
            }
        } else if a.status == H2S_STACK_DUE_TO_FREE {
            if !free_check(i, e, a, lv, stack_shared, *has_updated_frees) { a.status = H2S_INVALID; changed = ATR_CHANGED; }
        }
        if a.move_alloca_into_entry && (!has_size || (!a.globalized_local && is_in_loop(inst_block(a.cb), f, li, *irreducible_known, *irreducible)))
            a.move_alloca_into_entry = false;
    }
    return changed;
}
call_is_lifetime_start_or_end :: (cb: Value_Id) -> bool {
    if !call_is_intrinsic(cb) return false;
    id := call_iid(cb);
    return id == IID_LIFETIME_START || id == IID_LIFETIME_END;
}

h2s_manifest :: (i: u32) -> bool {
    changed := ATR_UNCHANGED;
    f := irp_anchor_scope(aa(i).pos);
    e := h2s_ext(i);
    for a: e.allocs {
        if a.status == H2S_INVALID continue;
        for fc: a.free_calls { atr_delete_inst_after_manifest(fc); changed = ATR_CHANGED; }
        if a.globalized_local atr_emit_remark_inst(a.cb, "OMP110", "Moving globalized variable to the stack.");
        else atr_emit_remark_inst(a.cb, "HeapToStack", "Moving memory allocation from the heap to the stack.");
        size: Value_Id;
        has_size, sz := h2s_get_size(i, a.cb);
        if has_size {
            size = const_int_ap(type_int(sz.bits), sz);
        } else {
            ev: Os_Evaluator;
            okc, s, o := ose_compute(*ev, a.cb);
            if !okc fatal("internal: attributor: no object size for a heap-to-stack allocation");
            size = s;
        }
        alignment: u64 = 1;
        ra := call_ret_align(a.cb);
        if ra != 0 alignment = max(alignment, ra);
        al := get_alloc_alignment(a.cb);
        if al != NONE {
            ok, ap := h2s_get_apint(i, al);
            if !ok || ap_zext_value(ap) == 0 fatal("internal: attributor: expected an alignment during the heap-to-stack manifest");
            alignment = max(alignment, ap_zext_value(ap));
        }
        as := dl_alloca_addrspace();
        alloca := new_inst(.ALLOCA, type_ptr(as), 1);
        set_op(alloca, 0, size);
        inst(alloca).ty2 = ir.t_i8;
        inst(alloca).addrspace = cast(u32) as;
        inst(alloca).align = alignment;
        name := tconcat(vname(a.cb), ".h2s");
        if a.move_alloca_into_entry insert_at_position(alloca, fn_entry(f), block_first(fn_entry(f)), true);
        else insert_at_position(alloca, inst_block(a.cb), a.cb, false);
        set_name(alloca, name);
        repl := alloca;
        if vtype(alloca) != vtype(a.cb) {
            c := create_cast(.ADDRSPACECAST, alloca, vtype(a.cb));
            insert_before_named(c, a.cb, "malloc_cast");
            repl = c;
        }
        init := get_initial_value_of_allocation(a.cb, ir.t_i8);
        if init == NONE fatal("internal: attributor: no initial value for a heap-to-stack allocation");
        atr_change_after_manifest(irp_inst(a.cb), repl);
        if inst_op(a.cb) == .INVOKE {
            br := create_br(invoke_normal_dest(a.cb));
            block_append_inst(inst_block(a.cb), br);
            atr_delete_inst_after_manifest(a.cb);
        } else {
            atr_delete_inst_after_manifest(a.cb);
        }
        if !is_undef_value(init) {
            b: Irb;
            irb_set_before(*b, inst_next(alloca));
            irb_memset(*b, alloca, init, size, 0, false);
        }
        changed = ATR_CHANGED;
    }
    return changed;
}

// ---------------------------------------------------------------- AAPrivatizablePtr

Priv_Ext :: struct { ty: Value_Id = OV_NOVAL; }   // PrivatizableType: OV_NOVAL nullopt, NONE nullptr, else a Type_Id
priv_ext :: inline (i: u32) -> *Priv_Ext { return cast(*Priv_Ext) aa(i).x; }
priv_construct :: (i: u32) { aa(i).x = New(Priv_Ext); }
// combineTypes
priv_combine_types :: (t0: Value_Id, t1: Value_Id) -> Value_Id {
    if t0 == OV_NOVAL return t1;
    if t1 == OV_NOVAL return t0;
    if t0 == t1 return t0;
    return NONE;
}

priv_initialize :: (i: u32) {
    pk := aa(i).pk;
    if pk == .ARGUMENT return;
    if pk == .CALL_SITE_ARGUMENT {
        if atr_has_attr(aa(i).pos, .[.ByVal]) aa_optimistic(i);
        return;
    }
    aa_pessimistic(i);
}

// isDenselyPacked
is_densely_packed :: (t: Type_Id) -> bool {
    if !type_is_sized(t) return false;
    if dl_type_size_bits(t) != dl_type_alloc_size(t) * 8 return false;
    k := type_kind(t);
    if is_vector_type(t) || k == .ARRAY return is_densely_packed(type_elem(t));
    if k != .STRUCT return true;
    start: u64 = 0;
    for e: 0..cast(s64) type_nsub(t) - 1 {
        et := type_sub(t, cast(u32) e);
        if !is_densely_packed(et) return false;
        if start != dl_struct_offset(t, cast(u32) e) * 8 return false;
        start += dl_type_alloc_size(et) * 8;
    }
    return true;
}
// identifyReplacementTypes
priv_replacement_types :: (t: Type_Id, out: *[..] Type_Id) {
    k := type_kind(t);
    if k == .STRUCT { for e: 0..cast(s64) type_nsub(t) - 1 array_add(out, type_sub(t, cast(u32) e)); return; }
    if k == .ARRAY { for e: 0..cast(s64) type_count(t) - 1 array_add(out, type_elem(t)); return; }
    array_add(out, t);
}

// AAPrivatizablePtrArgument::identifyPrivatizableType
priv_arg_identify_type :: (i: u32) -> Value_Id {
    uai := false;
    p := aa(i).pos;
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.ByVal], *attrs, true);
    if attrs.count != 0 && atr_all_call_sites_known(i, *uai) return attrs[0].ty;
    ty := OV_NOVAL;
    argno := cast(u32) irp_cs_arg_no(p);
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        cp := irp_acs_argument(cb, argno);
        if irp_kind(cp) == .INVALID { ok = false; break; }
        o := atr_get_aa(.PRIVATIZABLE_PTR, cp, i, DEP_REQUIRED);
        if o == NONE { ok = false; break; }
        ty = priv_combine_types(ty, priv_ext(o).ty);
        if !(ty == OV_NOVAL || ty != NONE) { ok = false; break; }
    }
    if !ok return NONE;
    return ty;
}
// AAPrivatizablePtrFloating::identifyPrivatizableType
priv_floating_identify_type :: (i: u32) -> Value_Id {
    obj := get_underlying_object(irp_assoc_value(aa(i).pos));
    if obj == NONE return NONE;
    if is_inst(obj) && inst_op(obj) == .ALLOCA {
        n := op(obj, 0);
        if vkind(n) == .C_INT && ap_is_one(const_ap(n)) return inst(obj).ty2;
    }
    if vkind(obj) == .ARGUMENT {
        o := atr_get_aa(.PRIVATIZABLE_PTR, irp_argument(obj), i, DEP_REQUIRED);
        if o != NONE && bs_is_assumed(aa(o).s, 1) return priv_ext(o).ty;
    }
    return NONE;
}

priv_update :: (i: u32) -> bool {
    pk := aa(i).pk;
    p := aa(i).pos;
    e := priv_ext(i);
    if pk == .CALL_SITE_ARGUMENT {
        e.ty = priv_floating_identify_type(i);
        if e.ty == OV_NOVAL return ATR_UNCHANGED;
        if e.ty == NONE return aa_pessimistic(i);
        nc, _ := atr_has_assumed_ir_attr(.Captures, i, p, DEP_REQUIRED);
        if !nc return aa_pessimistic(i);
        na, _ := atr_has_assumed_ir_attr(.NoAlias, i, p, DEP_REQUIRED);
        if !na return aa_pessimistic(i);
        ro, _ := atr_is_assumed_read_only(p, i);
        if !ro return aa_pessimistic(i);
        return ATR_UNCHANGED;
    }
    if pk != .ARGUMENT fatal("internal: attributor: AAPrivatizablePtr(Floating|Returned|CallSiteReturned)::updateImpl");
    e.ty = priv_arg_identify_type(i);
    if e.ty == OV_NOVAL return ATR_UNCHANGED;
    if e.ty == NONE return aa_pessimistic(i);
    atr_get_aa(.ALIGN, irp_value(irp_assoc_value(p)), i, DEP_OPTIONAL);
    pt := cast(Type_Id) e.ty;
    if !atr_has_attr(p, .[.ByVal]) && !is_densely_packed(pt) return aa_pessimistic(i);
    repl: [..] Type_Id; repl.allocator = temp;
    priv_replacement_types(pt, *repl);
    uai := false;
    ok := true;
    for cb: atr_call_sites(i, true, *uai, *ok) {
        callee := call_callee(cb);
        if !ap_are_types_abi_compatible_for(inst_fn(cb), ifx vkind(callee) == .FUNCTION then callee else NONE, repl) { ok = false; break; }
    }
    if !ok return aa_pessimistic(i);
    arg := irp_assoc_arg(p);
    if !atr_is_valid_function_signature_rewrite(arg, repl) return aa_pessimistic(i);
    // IsCompatiblePrivArgOfOtherCallSite: only direct calls (no callbacks), and they have no callback uses
    ok = true;
    for cb: atr_call_sites(i, true, *uai, *ok) {}
    if !ok return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

priv_manifest :: (i: u32) -> bool {
    if aa(i).pk != .ARGUMENT return ATR_UNCHANGED;
    e := priv_ext(i);
    if e.ty == OV_NOVAL || e.ty == NONE return ATR_UNCHANGED;
    tail_calls: [..] Value_Id;
    uai := false;
    ok := true;
    for ci: atr_insts(i, .[.CALL], *uai, *ok) if ((inst(ci).flags >> TAIL_SHIFT) & 3) != 0 array_add(*tail_calls, ci);
    if !ok return ATR_UNCHANGED;
    arg := irp_assoc_arg(aa(i).pos);
    al := atr_get_aa(.ALIGN, irp_value(arg), i, DEP_NONE);
    repl: [..] Type_Id;
    priv_replacement_types(cast(Type_Id) e.ty, *repl);
    ari: Arg_Replacement;
    ari.types = repl;
    ari.repair = ARI_PRIV;
    ari.priv_ty = cast(Type_Id) e.ty;
    ari.priv_arg = arg;
    ari.priv_align = ifx al != NONE then aa(al).s.assumed else 0;
    ari.tail_calls = tail_calls;
    if atr_register_function_signature_rewrite_ari(arg, ari) return ATR_CHANGED;
    return ATR_UNCHANGED;
}

// constructPointer (IRBuilder<NoFolder>: a ptradd named "<ptr>.b<offset>")
priv_construct_pointer :: (ptr: Value_Id, offset: s64, pos: Value_Id) -> Value_Id {
    if offset == 0 return ptr;
    g := new_inst(.GEP, vtype(ptr), 2);
    inst(g).ty2 = ir.t_i8;
    set_op(g, 0, ptr);
    set_op(g, 1, const_int(ir.t_i64, cast(u64) offset));
    insert_before_named(g, pos, tprint("%.b%", vname(ptr), offset));
    return g;
}
// createInitialization: stores of the new arguments into the private copy, before `pos`
priv_create_initialization :: (pt: Type_Id, base: Value_Id, f: Value_Id, argno: u32, pos: Value_Id) {
    store :: (v: Value_Id, ptr: Value_Id, pos: Value_Id) {
        s := new_inst(.STORE, ir.t_void, 2);
        set_op(s, 0, v); set_op(s, 1, ptr);
        inst(s).align = dl_abi_align(vtype(v));
        inst_insert_before(s, pos);
    }
    k := type_kind(pt);
    if k == .STRUCT {
        for u: 0..cast(s64) type_nsub(pt) - 1 {
            ptr := priv_construct_pointer(base, cast(s64) dl_struct_offset(pt, cast(u32) u), pos);
            store(fn_arg(f, argno + cast(u32) u), ptr, pos);
        }
    } else if k == .ARRAY {
        et := type_elem(pt);
        sz := dl_type_store_size(et);
        for u: 0..cast(s64) type_count(pt) - 1 {
            ptr := priv_construct_pointer(base, cast(s64) (cast(u64) u * sz), pos);
            store(fn_arg(f, argno + cast(u32) u), ptr, pos);
        }
    } else {
        store(fn_arg(f, argno), base, pos);
    }
}
// createReplacementValues: loads of the private copy before the call site
priv_create_replacement_values :: (alignment: u64, pt: Type_Id, cb: Value_Id, base: Value_Id, out: *[..] Value_Id) {
    load :: (ty: Type_Id, ptr: Value_Id, alignment: u64, cb: Value_Id) -> Value_Id {
        l := new_inst(.LOAD, ty, 1);
        set_op(l, 0, ptr);
        inst(l).align = ifx alignment != 0 then alignment else 1;
        inst_insert_before(l, cb);
        return l;
    }
    k := type_kind(pt);
    if k == .STRUCT {
        for u: 0..cast(s64) type_nsub(pt) - 1 {
            ptr := priv_construct_pointer(base, cast(s64) dl_struct_offset(pt, cast(u32) u), cb);
            array_add(out, load(type_sub(pt, cast(u32) u), ptr, alignment, cb));
        }
    } else if k == .ARRAY {
        et := type_elem(pt);
        sz := dl_type_store_size(et);
        for u: 0..cast(s64) type_count(pt) - 1 {
            ptr := priv_construct_pointer(base, cast(s64) (cast(u64) u * sz), cb);
            array_add(out, load(et, ptr, alignment, cb));
        }
    } else {
        array_add(out, load(pt, base, alignment, cb));
    }
}

// TTI->areTypesABICompatible(Caller, Callee, Types) for one call site (X86TTIImpl::areTypesABICompatible)
ap_are_types_abi_compatible_for :: (caller: Value_Id, callee: Value_Id, types: [] Type_Id) -> bool {
    tc := tti_get(caller);
    if tc.kind != .X86 {
        if !ap_same_str_attr(caller, callee, "target-cpu") || !ap_same_str_attr(caller, callee, "target-features") return false;
        return true;
    }
    te := tti_get(callee);
    if tc == te return true;
    cc := glob(callee).cc;
    for ty: types {
        vts: [..] Evt; vts.allocator = temp;
        ap_compute_value_vts(*tc.xl, ty, *vts);
        for vt: vts {
            if ap_x86_register_type_for_cc(*tc.xl, cc, vt) != ap_x86_register_type_for_cc(*te.xl, cc, vt) return false;
        }
    }
    return true;
}
