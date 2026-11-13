// InstCombine: loads, stores and allocas. A port of llvm/lib/Transforms/InstCombine/InstCombineLoadStoreAlloca.cpp
// (complete, in LLVM's order): isOnlyCopiedFromConstantMemory, simplifyAllocaArraySize, PointerReplacer,
// visitAllocaInst, combineLoadToNewType / combineStoreToNewValue, combineLoadToOperationType,
// unpackLoadToAggregate, isObjectSizeLessThanOrEq, canReplaceGEPIdxWithZero / replaceGEPIdxWithZero,
// canSimplifyNull{Store,Load}OrGEP, simplifyNonNullOperand, visitLoadInst, likeBitCastFromVector,
// combineStoreToValueType, unpackStoreToAggregate, equivalentAddressValues, visitStoreInst,
// mergeStoreIntoSuccessor. Also the IRBuilder methods these use (CreateLoad/Store/Alloca/GEP/PtrAdd/...),
// InstCombinerImpl::CreateNonTerminatorUnreachable and Local.cpp's getOrEnforceKnownAlignment/tryEnforceAlignment.

IID_PROTECTED_FIELD_PTR :: #run iid_by_name("llvm.protected.field.ptr");

// ---------------------------------------------------------------- IRBuilder methods

// CreateGEP(Ty, Ptr, IdxList, Name, NW) with TargetFolder::FoldGEP
icb_gep :: (srcty: Type_Id, ptr: Value_Id, idxs: [] Value_Id, name: string = "", nw: u32 = 0) -> Value_Id {
    flags := nw & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if (flags & F_INBOUNDS) != 0 flags &= ~cast(u32) F_NUSW;
    if is_const(ptr) && type_kind(srcty) != .SVECTOR && !type_is_scalable(srcty) {
        all := true;
        for idxs if !is_const(it) { all = false; break; }
        if all return cfo_constant(ce_gep(srcty, ptr, idxs, flags));
    }
    return icb_insert(create_gep(srcty, ptr, idxs, flags), name);
}
// GetElementPtrInst::Create (unlinked)
create_gep :: (srcty: Type_Id, ptr: Value_Id, idxs: [] Value_Id, nw: u32 = 0) -> Value_Id {
    flags := nw & cast(u32)(F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if (flags & F_INBOUNDS) != 0 flags &= ~cast(u32) F_NUSW;
    i := new_inst(.GEP, irb_gep_result_type(ptr, idxs), cast(u32)(1 + idxs.count));
    inst(i).flags = flags; inst(i).ty2 = srcty;
    set_op(i, 0, ptr);
    for idxs set_op(i, cast(u32)(1 + it_index), it);
    return i;
}
// CreatePtrAdd(Ptr, Offset, Name, NW)
icb_ptr_add :: (ptr: Value_Id, off: Value_Id, name: string = "", nw: u32 = 0) -> Value_Id { return icb_gep(ir.t_i8, ptr, .[off], name, nw); }
// CreateInBoundsPtrAdd
icb_inbounds_ptr_add :: (ptr: Value_Id, off: Value_Id, name: string = "") -> Value_Id { return icb_gep(ir.t_i8, ptr, .[off], name, F_INBOUNDS); }
// CreateLoad(Ty, Ptr, Properties, Name): align, volatile, ordering and syncscope from `props`
icb_load_props :: (ty: Type_Id, ptr: Value_Id, props: Value_Id, name: string = "") -> Value_Id {
    i := create_load_props(ty, ptr, props);
    return icb_insert(i, name);
}
create_load_props :: (ty: Type_Id, ptr: Value_Id, props: Value_Id) -> Value_Id {
    i := new_inst(.LOAD, ty, 1);
    set_op(i, 0, ptr);
    copy_load_store_properties(i, props);
    return i;
}
copy_load_store_properties :: (dst: Value_Id, src: Value_Id) {
    d := inst(dst); s := inst(src);
    d.align = s.align; d.ord1 = s.ord1; d.sync = s.sync;
    d.flags = (d.flags & ~cast(u32) F_VOLATILE) | (s.flags & cast(u32) F_VOLATILE);
}
// CreateAlignedLoad(Ty, Ptr, Align, Name)
icb_aligned_load :: (ty: Type_Id, ptr: Value_Id, align: u64, name: string = "") -> Value_Id {
    i := new_inst(.LOAD, ty, 1);
    set_op(i, 0, ptr);
    inst(i).align = ifx align then align else dl_abi_align(ty);   // MaybeAlign: none = the ABI alignment
    return icb_insert(i, name);
}
// CreateStore(V, Ptr, Properties)
icb_store_props :: (v: Value_Id, ptr: Value_Id, props: Value_Id) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, ptr);
    copy_load_store_properties(i, props);
    return icb_insert(i);
}
// CreateAlignedStore(V, Ptr, Align)
icb_aligned_store :: (v: Value_Id, ptr: Value_Id, align: u64) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, ptr);
    inst(i).align = ifx align then align else dl_abi_align(vtype(v));   // MaybeAlign: none = the ABI alignment
    return icb_insert(i);
}
// CreateAlloca(Ty, AddrSpace, ArraySize = nullptr, Name): align = DL.getPrefTypeAlign(Ty)
icb_alloca :: (ty: Type_Id, as: u32, name: string = "") -> Value_Id {
    i := new_inst(.ALLOCA, type_ptr(as), 1);
    set_op(i, 0, const_int(ir.t_i32, 1));
    inst(i).ty2 = ty; inst(i).addrspace = as;
    inst(i).align = dl_pref_align(ty);
    return icb_insert(i, name);
}
// CreateInsertValue(Agg, Val, Idxs, Name) (TargetFolder::FoldInsertValue)
icb_insert_value :: (agg: Value_Id, v: Value_Id, idxs: [] u32, name: string = "") -> Value_Id {
    if is_const(agg) && is_const(v) {
        c := cf_insert_value(agg, v, idxs);
        if c != NONE return c;
    }
    i := new_inst(.INSERTVALUE, vtype(agg), 2);
    set_op(i, 0, agg); set_op(i, 1, v);
    cp := NewArray(idxs.count, u32,, allocator = temp);   // idxs may be a view into ir.u32_pool
    for idxs cp[it_index] = it;
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) cp.count;
    for cp array_add(*ir.u32_pool, it);
    return icb_insert(i, name);
}
// CreateAddrSpaceCast
icb_addrspace_cast :: (v: Value_Id, t: Type_Id, name: string = "") -> Value_Id { return icb_cast(.ADDRSPACECAST, v, t, name); }

// InstCombinerImpl::CreateNonTerminatorUnreachable: store i1 true, ptr poison
ic_create_non_terminator_unreachable :: (at: Value_Id) {
    si := new_inst(.STORE, ir.t_void, 2);
    set_op(si, 0, const_int(ir.t_i1, 1));
    set_op(si, 1, const_poison(type_ptr(0)));
    inst(si).align = 1;
    ic_insert_new_inst_with(si, at);
}

// MemIntrinsic accessors
mi_is_volatile :: (mi: Value_Id) -> bool { v := call_arg(mi, 3); return !is_null_value(v); }
mi_param_align :: (mi: Value_Id, k: u32) -> u64 { a := attr_set_find(attr_list_param(inst(mi).attrs, k), .Alignment); if a return a.ival; return 0; }
is_mem_transfer_inst :: (i: Value_Id) -> bool {
    id := call_iid(i);
    return id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMCPY_INLINE;
}
// MemTransferInst::getSource: getRawSource()->stripPointerCasts()
mti_source :: (mti: Value_Id) -> Value_Id { return strip_pointer_casts(call_arg(mti, 1)); }


// ---------------------------------------------------------------- Local.cpp: alignment

// tryEnforceAlignment
try_enforce_alignment :: (v_in: Value_Id, pref_in: u64) -> u64 {
    pref := pref_in;
    v := strip_pointer_casts(v_in);
    if is_inst(v) && inst_op(v) == .ALLOCA {
        cur := inst(v).align;
        if pref <= cur return cur;
        if dl.stack_natural != 0 && pref > dl.stack_natural return cur;
        inst(v).align = pref;
        return pref;
    }
    if vkind(v) == .GLOBAL_VAR {
        cur := pointer_alignment(v);
        if pref <= cur return cur;
        if !gv_can_increase_alignment(v) return cur;
        if glob(v).tls != 0 fatal("tryEnforceAlignment of a thread-local global (Module::getMaxTLSAlignment) is not supported yet");
        glob(v).align = pref;
        return pref;
    }
    return 1;
}
// GlobalObject::canIncreaseAlignment (ELF, not XCOFF)
gv_can_increase_alignment :: (g: Value_Id) -> bool {
    if !gv_is_strong_definition_for_linker(g) return false;
    if glob(g).section.count > 0 && glob(g).align != 0 return false;
    // only ELF (also the default for an unknown triple) can't increase the alignment of a non-dso_local global
    obj := triple_parse(ir.triple).obj;
    if obj == .ELF && !glob(g).dso_local return false;
    if obj == .XCOFF fatal("canIncreaseAlignment: XCOFF (the toc-data attribute) is not supported yet");
    return true;
}
// getOrEnforceKnownAlignment(V, PrefAlign, DL, CxtI, AC, DT); pref_align 0 = none (getKnownAlignment)
get_or_enforce_known_alignment :: (v: Value_Id, pref_align: u64, cxt: Value_Id, ac: *Assumption_Cache, dt: *Dom_Tree) -> u64 {
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = cxt;
    known := known_bits(v, q);
    tz := kb_count_min_trailing_zeros(known);
    tz = min(tz, 32);   // Value::MaxAlignmentExponent
    bw := kb_bits(known);
    a := (cast(u64) 1) << min(bw - 1, tz);
    if pref_align != 0 && pref_align > a a = max(a, try_enforce_alignment(v, pref_align));
    return a;
}

// ---------------------------------------------------------------- allocas

MAX_COPIED_FROM_CONSTANT_USERS :: 300;   // -instcombine-max-copied-from-constant-users

// isOnlyCopiedFromConstantMemory: the copy (or NONE), lifetime markers to delete in `to_delete`
ic_is_only_copied_from_constant_memory :: (ai: Value_Id, to_delete: *[..] Value_Id) -> Value_Id {
    Elem :: struct { v: Value_Id; off: bool; }
    work: [..] Elem; work.allocator = temp;
    visited: [..] Elem; visited.allocator = temp;
    the_copy: Value_Id = NONE;
    array_add(*work, .{ai, false});
    while work.count {
        e := pop(*work);
        seen := false;
        for visited if it.v == e.v && it.off == e.off { seen = true; break; }
        if seen continue;
        array_add(*visited, e);
        if visited.count > MAX_COPIED_FROM_CONSTANT_USERS return NONE;
        u := ir.v_first_use[e.v];
        while u != NONE {
            defer u = ir.u_next[u];
            i := ir.u_user[u];
            o := inst_op(i);
            if o == .LOAD {
                if !inst_is_simple(i) return NONE;
                continue;
            }
            if o == .PHI || o == .SELECT { array_add(*work, .{i, true}); continue; }
            if o == .BITCAST || o == .ADDRSPACECAST { array_add(*work, .{i, e.off}); continue; }
            if o == .GEP { array_add(*work, .{i, e.off || !gep_has_all_zero_indices(i)}); continue; }
            opno := use_operand_no(u);
            if is_call_base(i) {
                if opno == nops(i) - 1 continue;   // isCallee
                is_arg := opno < call_num_args(i);
                if is_arg && call_param_has_attr(i, opno, .InAlloca) return NONE;
                no_capture := call_does_not_capture(i, opno);
                if no_capture && (call_only_reads_memory(i) || call_data_operand_only_reads(i, opno)) continue;
            }
            if is_lifetime_start_or_end(i) { array_add(to_delete, i); continue; }
            if !is_mem_transfer_inst(i) return NONE;
            if mi_is_volatile(i) return NONE;
            if opno == 1 continue;
            if the_copy != NONE return NONE;
            if e.off return NONE;
            if opno != 0 return NONE;
            if (ic_points_to_const_mem_mask(mti_source(i)) & MR_MOD) != 0 return NONE;
            the_copy = i;
        }
    }
    return the_copy;
}


// isDereferenceableForAllocaSize
ic_is_dereferenceable_for_alloca_size :: (v: Value_Id, ai: Value_Id) -> bool {
    ok, size := alloca_allocation_size(ai);
    if !ok || type_is_scalable(inst(ai).ty2) return false;
    q: Simplify_Query;   // SimplifyQuery(DL): no context
    return is_dereferenceable_and_aligned_pointer(v, inst(ai).align, ap_from_u64(64, size), q);
}

// simplifyAllocaArraySize
ic_simplify_alloca_array_size :: (ai: Value_Id) -> Value_Id {
    n := op(ai, 0);
    if !alloca_is_array_allocation(ai) {
        if is_int_type(vtype(n)) && type_int_width(vtype(n)) == 32 return NONE;
        return ic_replace_operand(ai, 0, const_int(ir.t_i32, 1));
    }
    if is_scalar_const_int(n) && ap_active_bits(const_ap(n)) <= 64 {
        nt := type_array(ap_zext_value(const_ap(n)), inst(ai).ty2);
        new := icb_alloca(nt, inst(ai).addrspace, name_ref(vname(ai)));
        inst(new).align = inst(ai).align;
        inst(new).flags = (inst(new).flags & ~cast(u32) F_INALLOCA) | (inst(ai).flags & cast(u32) F_INALLOCA);
        ic_replace_all_dbg_uses_with(ai, new, new);
        return ic_replace_inst_uses_with(ai, new);
    }
    if vkind(n) == .C_UNDEF || vkind(n) == .C_POISON return ic_replace_inst_uses_with(ai, const_poison(vtype(ai)));
    pit := dl_index_type(vtype(ai));
    if vtype(n) != pit {
        v := icb_int_cast(n, pit, false);
        return ic_replace_operand(ai, 0, v);
    }
    return NONE;
}

// PointerReplacer
Ptr_Replacer :: struct {
    root: Value_Id;
    from_as: u32;
    users_to_replace: [..] Value_Id;   // SmallSetVector
    work_keys: [..] Value_Id;          // MapVector
    work_vals: [..] Value_Id;
}
pr_contains :: (s: [] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }
pr_insert :: (s: *[..] Value_Id, v: Value_Id) -> bool { if pr_contains(s.*, v) return false; array_add(s, v); return true; }
pr_lookup :: (pr: *Ptr_Replacer, v: Value_Id) -> Value_Id { for pr.work_keys if it == v return pr.work_vals[it_index]; return NONE; }
pr_set :: (pr: *Ptr_Replacer, k: Value_Id, v: Value_Id) {
    for pr.work_keys if it == k { pr.work_vals[it_index] = v; return; }
    array_add(*pr.work_keys, k); array_add(*pr.work_vals, v);
}
pr_is_available :: (pr: *Ptr_Replacer, i: Value_Id) -> bool { return i == pr.root || pr_contains(pr.users_to_replace, i); }
pr_is_equal_or_valid_asc :: (pr: *Ptr_Replacer, i: Value_Id, from_as: u32) -> bool {
    if inst_op(i) != .ADDRSPACECAST return false;
    to_as := type_addrspace(vtype(i));
    return from_as == to_as;   // || TTI.isValidAddrSpaceCast(FromAS, ToAS): false on X86
}

// PointerReplacer::collectUsers
pr_collect_users :: (pr: *Ptr_Replacer) -> bool {
    work: [..] Value_Id; work.allocator = temp;
    revisit: [..] Value_Id; revisit.allocator = temp;
    push_users :: (pr: *Ptr_Replacer, x: Value_Id, work: *[..] Value_Id, revisit: *[..] Value_Id) {
        u := ir.v_first_use[x];
        while u != NONE {
            us := ir.u_user[u];
            if is_inst(us) && !pr_is_available(pr, us) && !pr_contains(revisit.*, us) array_add(work, us);
            u = ir.u_next[u];
        }
    }
    try_push_operand :: (pr: *Ptr_Replacer, x: Value_Id, work: *[..] Value_Id, revisit: *[..] Value_Id) -> bool {
        if !pr_contains(pr.users_to_replace, x) {
            if !pr_insert(revisit, x) return false;
            array_add(work, x);
        }
        return true;
    }
    push_users(pr, pr.root, *work, *revisit);
    while work.count {
        i := pop(*work);
        o := inst_op(i);
        if o == .LOAD {
            if inst(i).flags & F_VOLATILE return false;
            pr_insert(*pr.users_to_replace, i);
        } else if o == .PHI {
            n := nops(i);
            replaceable := true;
            for k: 0..cast(s64) n - 1 if !is_inst(op(i, cast(u32) k)) { replaceable = false; break; }
            all_avail := replaceable;
            if replaceable for k: 0..cast(s64) n - 1 if !pr_is_available(pr, op(i, cast(u32) k)) { all_avail = false; break; }
            if all_avail {
                pr_insert(*pr.users_to_replace, i);
                push_users(pr, i, *work, *revisit);
                continue;
            }
            if !replaceable || !pr_insert(*revisit, i) return false;
            array_add(*work, i);
            for k: 0..cast(s64) n - 1 if !try_push_operand(pr, op(i, cast(u32) k), *work, *revisit) return false;
        } else if o == .SELECT {
            t := op(i, 1); f := op(i, 2);
            if !is_inst(t) || !is_inst(f) return false;
            if pr_is_available(pr, t) && pr_is_available(pr, f) {
                pr_insert(*pr.users_to_replace, i);
                push_users(pr, i, *work, *revisit);
                continue;
            }
            array_add(*work, i);
            if !try_push_operand(pr, t, *work, *revisit) || !try_push_operand(pr, f, *work, *revisit) return false;
        } else if o == .GEP {
            p := op(i, 0);
            if !is_inst(p) return false;
            if pr_is_available(pr, p) {
                pr_insert(*pr.users_to_replace, i);
                push_users(pr, i, *work, *revisit);
                continue;
            }
            array_add(*work, i);
            if !try_push_operand(pr, p, *work, *revisit) return false;
        } else if is_mem_transfer_inst(i) {
            if mi_is_volatile(i) return false;
            pr_insert(*pr.users_to_replace, i);
        } else if pr_is_equal_or_valid_asc(pr, i, pr.from_as) {
            pr_insert(*pr.users_to_replace, i);
            push_users(pr, i, *work, *revisit);
        } else if is_lifetime_start_or_end(i) {
            continue;
        } else return false;
    }
    return true;
}

// PointerReplacer::replacePointer
pr_replace_pointer :: (pr: *Ptr_Replacer, v: Value_Id) {
    pr_set(pr, pr.root, v);
    work: [..] Value_Id; work.allocator = temp;
    post: [..] Value_Id; post.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*work, pr.root);
    while work.count {
        i := work[work.count - 1];
        if pr_insert(*visited, i) {
            u := ir.v_first_use[i];
            while u != NONE {
                us := ir.u_user[u];
                if pr_contains(pr.users_to_replace, us) && !pr_contains(visited, us) array_add(*work, us);
                u = ir.u_next[u];
            }
        } else {
            pr_insert(*post, i);
            pop(*work);
        }
    }
    for < k: 0..post.count-1 pr_replace(pr, post[k]);
}

// PointerReplacer::replace
pr_replace :: (pr: *Ptr_Replacer, i: Value_Id) {
    if pr_lookup(pr, i) != NONE return;
    o := inst_op(i);
    if o == .LOAD {
        v := pr_lookup(pr, op(i, 0));
        assert(v != NONE, "Operand not replaced");
        ni := create_load_props(vtype(i), v, i);
        ic_take_name(ni, i);
        copy_metadata(ni, i);
        ic_insert_new_inst_with(ni, i);
        ic_replace_inst_uses_with(i, ni);
        pr_set(pr, ni, ni);
    } else if o == .PHI {
        v0 := pr_lookup(pr, op(i, 0));
        ir.v_type[i] = ifx v0 != NONE then vtype(v0) else vtype(op(i, 0));   // mutateType
        n := nops(i);
        for k: 0..cast(s64) n - 1 {
            x := pr_lookup(pr, op(i, cast(u32) k));
            set_op(i, cast(u32) k, ifx x != NONE then x else op(i, cast(u32) k));
        }
        pr_set(pr, i, i);
    } else if o == .GEP {
        v := pr_lookup(pr, op(i, 0));
        assert(v != NONE, "Operand not replaced");
        idxs: [..] Value_Id; idxs.allocator = temp;
        for k: 1..cast(s64) nops(i) - 1 array_add(*idxs, op(i, cast(u32) k));
        ni := create_gep(inst(i).ty2, v, idxs);
        ic_insert_new_inst_with(ni, i);
        ic_take_name(ni, i);
        inst(ni).flags = inst(i).flags;
        pr_set(pr, i, ni);
    } else if o == .SELECT {
        t := op(i, 1); f := op(i, 2);
        rt := pr_lookup(pr, t); if rt != NONE t = rt;
        rf := pr_lookup(pr, f); if rf != NONE f = rf;
        ns := create_select_md_from(op(i, 0), t, f, i);
        ic_insert_new_inst_with(ns, i);
        ic_take_name(ns, i);
        pr_set(pr, i, ns);
    } else if is_mem_transfer_inst(i) {
        d := call_arg(i, 0); s := call_arg(i, 1);
        rd := pr_lookup(pr, d); if rd != NONE d = rd;
        rs := pr_lookup(pr, s); if rs != NONE s = rs;
        icb_set_insert_point(i);
        ni := icb_mem_transfer(call_iid(i), d, mi_param_align(i, 0), s, mi_param_align(i, 1), call_arg(i, 2), mi_is_volatile(i));
        tags := get_aa_metadata(i);
        if aa_any(tags) set_aa_metadata(ni, tags);
        ic_erase_inst(i);
        pr_set(pr, i, ni);
    } else if o == .ADDRSPACECAST {
        v := pr_lookup(pr, op(i, 0));
        assert(v != NONE, "Operand not replaced");
        if type_addrspace(vtype(v)) != type_addrspace(vtype(i)) {
            ni := create_cast(.ADDRSPACECAST, v, vtype(i));
            ic_take_name(ni, i);
            ic_insert_new_inst_with(ni, i);
            pr_set(pr, i, ni);
        } else pr_set(pr, i, v);
    } else fatal("internal: PointerReplacer::replace reached an unexpected instruction");
}
// IRBuilder::CreateMemTransferInst(IntrID, Dst, DstAlign, Src, SrcAlign, Size, isVolatile)
icb_mem_transfer :: (id: Intrinsic_Id, dst: Value_Id, dst_align: u64, src: Value_Id, src_align: u64, size: Value_Id, volatile: bool) -> Value_Id {
    ci := icb_intrinsic(id, .[vtype(dst), vtype(src), vtype(size)], .[dst, src, size, const_int(ir.t_i1, ifx volatile then cast(u64) 1 else 0)]);
    if dst_align add_param_align(ci, 0, dst_align);
    if src_align add_param_align(ci, 1, src_align);
    return ci;
}

// visitAllocaInst
ic_visit_alloca :: (ai: Value_Id) -> Value_Id {
    r := ic_simplify_alloca_array_size(ai); if r != NONE return r;
    ok, size := alloca_allocation_size(ai);
    if ok && size == 0 {
        if alloca_is_array_allocation(ai) return ic_replace_operand(ai, 0, const_int(vtype(op(ai, 0)), 1));
        entry := fn_entry(ic.f);
        first := block_first_non_phi_or_dbg(entry);
        if first != ai {
            entry_ai: Value_Id = NONE;
            if first != NONE && inst_op(first) == .ALLOCA entry_ai = first;
            eok := false; esize: u64 = 1;
            if entry_ai != NONE eok, esize = alloca_allocation_size(entry_ai);
            if !eok || esize != 0 {
                inst_move_before_dbg(ai, first);
                return ai;
            }
            inst(entry_ai).align = max(inst(entry_ai).align, inst(ai).align);
            return ic_replace_inst_uses_with(ai, entry_ai);
        }
    }
    to_delete: [..] Value_Id; to_delete.allocator = temp;
    copy := ic_is_only_copied_from_constant_memory(ai, *to_delete);
    if copy != NONE {
        the_src := mti_source(copy);
        alloca_align := inst(ai).align;
        source_align := get_or_enforce_known_alignment(the_src, alloca_align, ai, ic.ac, ic.dt);
        if alloca_align <= source_align && ic_is_dereferenceable_for_alloca_size(the_src, ai) && !is_inst(the_src) {
            src_as := type_addrspace(vtype(the_src));
            if inst(ai).addrspace == src_as {
                for to_delete ic_erase_inst(it);
                ni := ic_replace_inst_uses_with(ai, the_src);
                ic_erase_inst(copy);
                return ni;
            }
            pr: Ptr_Replacer;
            pr.root = ai; pr.from_as = src_as;
            pr.users_to_replace.allocator = temp; pr.work_keys.allocator = temp; pr.work_vals.allocator = temp;
            if pr_collect_users(*pr) {
                for to_delete ic_erase_inst(it);
                pr_replace_pointer(*pr, the_src);
            }
        }
    }
    return ic_visit_alloc_site(ai);
}

// ---------------------------------------------------------------- loads

// isSupportedAtomicType
is_supported_atomic_type :: (t: Type_Id) -> bool { return is_int_type(t) || is_ptr_type(t) || is_fp_type(t); }

// combineLoadToNewType(LI, NewTy, Suffix)
ic_combine_load_to_new_type :: (li: Value_Id, nt: Type_Id, suffix := "") -> Value_Id {
    nl := icb_load_props(nt, op(li, 0), li, name_ref(tprint("%1%2", vname(li), suffix)));
    copy_metadata_for_load(nl, li);
    return nl;
}

// combineStoreToNewValue
ic_combine_store_to_new_value :: (si: Value_Id, v: Value_Id) -> Value_Id {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(si, *all);
    ns := icb_store_props(v, op(si, 1), si);
    for all {
        name := ir.md_kind_names[it.kind];
        if name == "dbg" || name == "DIAssignID" || name == "tbaa" || name == "prof" || name == "fpmath" ||
           name == "tbaa.struct" || name == "alias.scope" || name == "noalias" || name == "nontemporal" ||
           name == "llvm.mem.parallel_loop_access" || name == "llvm.access.group"
            set_metadata(ns, it.kind, it.md);
    }
    return ns;
}

// Value::isSwiftError
is_swift_error :: (v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return attr_set_has(arg_attrs(v), .SwiftError);
    if is_inst(v) && inst_op(v) == .ALLOCA return (inst(v).flags & F_SWIFTERR) != 0;
    return false;
}
// CastInst::isNoopCast(DL)
cast_is_noop :: (c: Value_Id) -> bool {
    o := inst_op(c);
    if o == .BITCAST return true;
    if o == .PTRTOINT || o == .PTRTOADDR return dl_type_size_bits(scalar_type(vtype(c))) == dl_type_size_bits(scalar_type(vtype(op(c, 0))));
    if o == .INTTOPTR return dl_type_size_bits(scalar_type(vtype(op(c, 0)))) == dl_type_size_bits(scalar_type(vtype(c)));
    return false;
}

// combineLoadToOperationType
ic_combine_load_to_operation_type :: (load: Value_Id) -> Value_Id {
    if !is_unordered(load) return NONE;
    if !has_uses(load) return NONE;
    if is_swift_error(op(load, 0)) return NONE;
    if has_one_use(load) {
        lt := vtype(load);
        u := first_user(load);
        if inst_op(u) == .BITCAST && type_kind(vtype(u)) == .X86_AMX return NONE;
        if is_cast_op(inst_op(u)) {
            dt := vtype(u);
            if cast_is_noop(u) && is_ptr_or_ptr_vector(lt) == is_ptr_or_ptr_vector(dt) &&
               (inst(load).ord1 == 0 || is_supported_atomic_type(dt)) {
                nl := ic_combine_load_to_new_type(load, dt);
                rauw_with_metadata(u, nl);   // CastUser->replaceAllUsesWith (no worklist bookkeeping)
                ic_erase_inst(u);
                return load;
            }
        }
    }
    return NONE;
}

// unpackLoadToAggregate
ic_unpack_load_to_aggregate :: (li: Value_Id) -> Value_Id {
    if !inst_is_simple(li) return NONE;
    t := vtype(li);
    k := type_kind(t);
    if k != .STRUCT && k != .ARRAY return NONE;
    name := vname(li);
    inv := md_fixed("invariant.load");
    if k == .STRUCT {
        n := type_nsub(t);
        if n == 1 {
            nl := ic_combine_load_to_new_type(li, type_sub(t, 0), ".unpack");
            set_aa_metadata(nl, get_aa_metadata(li));
            m := get_metadata(li, inv); if m != NONE set_metadata(nl, inv, m);
            return ic_replace_inst_uses_with(li, icb_insert_value(const_poison(t), nl, .[0], name_ref(name)));
        }
        if dl_struct_has_padding(t) return NONE;
        al := inst(li).align;
        addr := op(li, 0);
        idx_ty := dl_index_type(vtype(addr));
        v := const_poison(t);
        if n > 0 for e: 0..n-1 {
            off := dl_struct_offset(t, e);
            p := icb_inbounds_ptr_add(addr, icb_type_size(idx_ty, off, type_is_scalable(t)), tprint("%.elt", name));   // CreateTypeSize(IdxType, getElementOffset(i))
            l := icb_aligned_load(type_sub(t, e), p, common_alignment(al, off), tprint("%.unpack", name));
            set_aa_metadata(l, get_aa_metadata(li));
            m := get_metadata(li, inv); if m != NONE set_metadata(l, inv, m);
            v = icb_insert_value(v, l, .[e]);
        }
        set_name(v, name);
        return ic_replace_inst_uses_with(li, v);
    }
    et := type_elem(t);
    n := type_count(t);
    if n == 1 {
        nl := ic_combine_load_to_new_type(li, et, ".unpack");
        set_aa_metadata(nl, get_aa_metadata(li));
        return ic_replace_inst_uses_with(li, icb_insert_value(const_poison(t), nl, .[0], name_ref(name)));
    }
    if n > ic.max_array_size return NONE;
    esz := dl_type_alloc_size(et);
    al := inst(li).align;
    addr := op(li, 0);
    zero := const_int(ir.t_i64, 0);
    v := const_poison(t);
    offset: u64 = 0;
    if n > 0 for e: 0..n-1 {
        p := icb_gep(t, addr, .[zero, const_int(ir.t_i64, e)], tprint("%.elt", name), F_INBOUNDS);
        l := icb_aligned_load(et, p, common_alignment(al, offset), tprint("%.unpack", name));
        set_aa_metadata(l, get_aa_metadata(li));
        v = icb_insert_value(v, l, .[cast(u32) e]);
        offset += esz;
    }
    set_name(v, name);
    return ic_replace_inst_uses_with(li, v);
}
// StructLayout::hasPadding
dl_struct_has_padding :: (t: Type_Id) -> bool {
    size, al := dl_struct_layout(t);
    sum: u64 = 0;
    n := type_nsub(t);
    if n > 0 for e: 0..n-1 {
        et := type_sub(t, e);
        if dl_struct_offset(t, e) != sum return true;
        sum += dl_type_alloc_size(et);
    }
    return sum != size;
}

// isObjectSizeLessThanOrEq
ic_is_object_size_less_than_or_eq :: (v: Value_Id, max_size: u64) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    array_add(*work, v);
    while work.count {
        p := strip_pointer_casts(pop(*work));
        if pr_contains(visited, p) continue;
        array_add(*visited, p);
        if is_inst(p) && inst_op(p) == .SELECT { array_add(*work, op(p, 1)); array_add(*work, op(p, 2)); continue; }
        if is_phi(p) { for k: 0..cast(s64) nops(p) - 1 array_add(*work, op(p, cast(u32) k)); continue; }
        if vkind(p) == .ALIAS {
            if gv_is_interposable(p) return false;
            array_add(*work, op(p, 0));
            continue;
        }
        if is_inst(p) && inst_op(p) == .ALLOCA {
            ok, sz := alloca_allocation_size(p);
            if !ok || type_is_scalable(inst(p).ty2) || sz > max_size return false;
            continue;
        }
        if vkind(p) == .GLOBAL_VAR {
            if !gv_has_definitive_initializer(p) || !glob(p).is_const return false;
            if dl_type_alloc_size(glob(p).value_type) > max_size return false;
            continue;
        }
        return false;
    }
    return true;
}

// canReplaceGEPIdxWithZero: the operand index to zero, or 0
ic_can_replace_gep_idx_with_zero :: (gepi: Value_Id, mem_i: Value_Id) -> u32 {
    n := nops(gepi);
    if n < 2 return 0;
    idx: u32 = 1;
    while idx < n {
        v := op(gepi, idx);
        if is_scalar_const_int(v) && is_null_value(v) { idx += 1; continue; }
        break;
    }
    if idx == n return 0;
    if is_const(op(gepi, idx)) return 0;
    src := inst(gepi).ty2;
    if type_is_scalable(src) return 0;
    front: [..] Value_Id; front.allocator = temp;
    for k: 1..idx-1 array_add(*front, op(gepi, k));
    alloc_ty := gep_indexed_type_n(src, front);
    if alloc_ty == NONE || !type_is_sized(alloc_ty) return 0;
    ty_alloc_size := dl_type_alloc_size(alloc_ty);
    if idx + 1 != n && (inst(gepi).flags & F_INBOUNDS) == 0 return 0;
    if !ic_is_object_size_less_than_or_eq(op(gepi, 0), ty_alloc_size) return 0;
    for k: idx+1..n-1 {
        known := ic_known_bits(op(gepi, k), mem_i);
        if !kb_is_non_negative(known) return 0;
    }
    return idx;
}

// replaceGEPIdxWithZero
ic_replace_gep_idx_with_zero :: (ptr: Value_Id, mem_i: Value_Id) -> Value_Id {
    if !is_inst(ptr) || inst_op(ptr) != .GEP return NONE;
    idx := ic_can_replace_gep_idx_with_zero(ptr, mem_i);
    if idx == 0 return NONE;
    ng := ic_clone_inst(ptr);
    set_op(ng, idx, const_int(vtype(op(ptr, idx)), 0));
    ic_insert_new_inst_before(ng, ptr);
    if inst_block(ptr) == inst_block(mem_i) && is_guaranteed_to_transfer_execution_range(ptr, mem_i, 32) {
        ic_replace_inst_uses_with(ptr, ng);
        ic_erase_inst(ptr);
    }
    return ng;
}

// canSimplifyNullStoreOrGEP
ic_can_simplify_null_store_or_gep :: (si: Value_Id) -> bool {
    as := type_addrspace(vtype(op(si, 1)));
    if null_pointer_is_defined(ic.f, as) return false;
    p := op(si, 1);
    if is_inst(p) && inst_op(p) == .GEP p = op(p, 0);
    return vkind(p) == .C_NULL && !null_pointer_is_defined(ic.f, as);
}
// canSimplifyNullLoadOrGEP
ic_can_simplify_null_load_or_gep :: (li: Value_Id, o: Value_Id) -> bool {
    if is_inst(o) && inst_op(o) == .GEP {
        g0 := op(o, 0);
        if vkind(g0) == .C_NULL && !null_pointer_is_defined(ic.f, type_addrspace(vtype(o))) return true;
    }
    if vkind(o) == .C_UNDEF || vkind(o) == .C_POISON ||
       (vkind(o) == .C_NULL && !null_pointer_is_defined(ic.f, type_addrspace(vtype(o)))) return true;
    return false;
}

// simplifyNonNullOperand
ic_simplify_non_null_operand :: (v: Value_Id, has_deref: bool, depth: u32 = 0) -> Value_Id {
    if is_inst(v) && inst_op(v) == .SELECT {
        if vkind(op(v, 1)) == .C_NULL return op(v, 2);
        if vkind(op(v, 2)) == .C_NULL return op(v, 1);
    }
    if !has_one_use(v) return NONE;
    RECURSION_LIMIT :: 3;
    if depth == RECURSION_LIMIT return NONE;
    if is_inst(v) && inst_op(v) == .GEP {
        if has_deref || (inst(v).flags & F_INBOUNDS) != 0 {
            r := ic_simplify_non_null_operand(op(v, 0), has_deref, depth + 1);
            if r != NONE {
                ic_replace_operand(v, 0, r);
                wl_add(v);
                return NONE;
            }
        }
    }
    if is_phi(v) {
        changed := false;
        for k: 0..cast(s64) nops(v) - 1 {
            r := ic_simplify_non_null_operand(op(v, cast(u32) k), has_deref, RECURSION_LIMIT);
            if r != NONE {
                ic_replace_use(op_use(v, cast(u32) k), r);
                changed = true;
            }
        }
        if changed wl_add(v);
        return NONE;
    }
    return NONE;
}

// visitLoadInst
ic_visit_load :: (li: Value_Id) -> Value_Id {
    o := op(li, 0);
    res := simplify_load_inst(li, o, ic_q(li));
    if res != NONE return ic_replace_inst_uses_with(li, res);
    r := ic_combine_load_to_operation_type(li); if r != NONE return r;
    ng := ic_replace_gep_idx_with_zero(o, li);
    if ng != NONE return ic_replace_operand(li, 0, ng);
    r = ic_unpack_load_to_aggregate(li); if r != NONE return r;
    is_load_cse := false;
    aaq := aa_query_new(ic_aa());
    avail := find_available_loaded_value(li, aaq, *is_load_cse);
    if avail != NONE {
        if is_load_cse combine_metadata_for_cse(avail, li, false);
        return ic_replace_inst_uses_with(li, icb_bit_or_pointer_cast(avail, vtype(li), tprint("%.cast", vname(li))));
    }
    if !is_unordered(li) return NONE;
    if ic_can_simplify_null_load_or_gep(li, o) {
        ic_create_non_terminator_unreachable(li);
        return ic_replace_inst_uses_with(li, const_poison(vtype(li)));
    }
    if has_one_use(o) {
        asc: Value_Id = NONE;
        if is_inst(o) && inst_op(o) == .ADDRSPACECAST asc = o;
        sel_op := o;
        if asc != NONE && has_one_use(op(asc, 0)) sel_op = op(asc, 0);
        if is_inst(sel_op) && inst_op(sel_op) == .SELECT {
            si := sel_op;
            al := inst(li).align;
            if ld_is_safe_to_load_unconditionally_ty(op(si, 1), vtype(li), al, si) &&
               ld_is_safe_to_load_unconditionally_ty(op(si, 2), vtype(li), al, si) {
                maybe_cast :: (x: Value_Id, asc: Value_Id) -> Value_Id {
                    if asc != NONE return icb_addrspace_cast(x, vtype(asc), tprint("%.cast", vname(x)));
                    return x;
                }
                lo1 := maybe_cast(op(si, 1), asc);
                v1 := icb_load_props(vtype(li), lo1, li, tprint("%.val", vname(lo1)));
                lo2 := maybe_cast(op(si, 2), asc);
                v2 := icb_load_props(vtype(li), lo2, li, tprint("%.val", vname(lo2)));
                copy_poison_generating_metadata(v1, li);
                copy_poison_generating_metadata(v2, li);
                return create_select_md_from(op(si, 0), v1, v2, si);
            }
        }
    }
    if !null_pointer_is_defined(ic.f, type_addrspace(vtype(o))) {
        v := ic_simplify_non_null_operand(o, true);
        if v != NONE return ic_replace_operand(li, 0, v);
    }
    // load(llvm.protected.field.ptr(ptr)) -> llvm.ptrauth.auth(load(ptr))
    if is_ptr_type(vtype(li)) && is_inst(o) && call_iid(o) == IID_PROTECTED_FIELD_PTR {
        ds := ic_deactivation_symbol_bundle(o);
        saved := ic.b; defer ic.b = saved;   // InsertPointGuard
        icb_set_insert_point(li);
        nli := ic_clone_inst(li);
        set_op(nli, 0, op(o, 0));
        icb_insert(nli);
        auth_fn := get_or_insert_intrinsic_declaration(IID_PTRAUTH_AUTH);
        li_int := icb_cast(.PTRTOINT, nli, ir.t_i64);
        auth := icb_call_fn_bundle(auth_fn, .[li_int, const_int(ir.t_i32, 2), op(o, 1)], "deactivation-symbol", ds);   // AArch64PACKey::DA
        auth = icb_cast(.INTTOPTR, auth, type_ptr_as(0));
        return ic_replace_inst_uses_with(li, auth);
    }
    return NONE;
}
// copyMetadata(LI, Metadata::PoisonGeneratingIDs) (also the debug location: WL doesn't contain MD_dbg, so no)
copy_poison_generating_metadata :: (dst: Value_Id, src: Value_Id) {
    for n: string.["range", "nonnull", "align", "nofpclass"] {
        k := md_kind_id(n);
        m := get_metadata(src, k);
        if m != NONE set_metadata(dst, k, m);
    }
}

// ---------------------------------------------------------------- stores

// likeBitCastFromVector
ic_like_bit_cast_from_vector :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    u: Value_Id = NONE;
    while is_inst(v) && inst_op(v) == .INSERTVALUE {
        e := op(v, 1);
        if !is_inst(e) || inst_op(e) != .EXTRACTELEMENT return NONE;
        w := op(e, 0);
        if u == NONE u = w;
        else if u != w return NONE;
        ci := op(e, 1);
        if !is_scalar_const_int(ci) || inst(v).nidx != 1 || ap_zext_value(const_ap(ci)) != cast(u64) ir.u32_pool[inst(v).idx] return NONE;
        v = op(v, 0);
    }
    if !pm_undef(v) || u == NONE return NONE;
    ut := vtype(u); vt := vtype(v);
    if dl_type_store_size(ut) * 8 != dl_type_store_size(vt) * 8 return NONE;   // getTypeStoreSizeInBits
    if type_kind(vt) == .ARRAY {
        if type_count(vt) != type_count(ut) return NONE;
    } else {
        if cast(u64) type_nsub(vt) != type_count(ut) return NONE;
        for e: 0..cast(s64) type_nsub(vt) - 1 if type_sub(vt, cast(u32) e) != type_elem(ut) return NONE;
    }
    return u;
}

// combineStoreToValueType
ic_combine_store_to_value_type :: (si: Value_Id) -> bool {
    if !is_unordered(si) return false;
    if is_swift_error(op(si, 1)) return false;
    v := op(si, 0);
    if is_inst(v) && inst_op(v) == .BITCAST {
        v = op(v, 0);
        if type_kind(vtype(v)) == .X86_AMX return false;
        if inst(si).ord1 == 0 || is_supported_atomic_type(vtype(v)) {
            ic_combine_store_to_new_value(si, v);
            return true;
        }
    }
    u := ic_like_bit_cast_from_vector(v);
    if u != NONE && (inst(si).ord1 == 0 || is_supported_atomic_type(vtype(u))) {
        ic_combine_store_to_new_value(si, u);
        return true;
    }
    return false;
}

// unpackStoreToAggregate
ic_unpack_store_to_aggregate :: (si: Value_Id) -> bool {
    if !inst_is_simple(si) return false;
    v := op(si, 0);
    t := vtype(v);
    k := type_kind(t);
    if k != .STRUCT && k != .ARRAY return false;
    if k == .STRUCT {
        n := type_nsub(t);
        if n == 1 {
            ev := icb_extract_value(v, .[0]);
            ic_combine_store_to_new_value(si, ev);
            return true;
        }
        if dl_struct_has_padding(t) return false;
        al := inst(si).align;
        elt_name := tprint("%.elt", vname(v));
        addr := op(si, 1);
        addr_name := tprint("%.repack", vname(addr));
        idx_ty := dl_index_type(vtype(addr));
        if n > 0 for e: 0..n-1 {
            off := dl_struct_offset(t, e);
            p := icb_inbounds_ptr_add(addr, icb_type_size(idx_ty, off, type_is_scalable(t)), addr_name);
            val := icb_extract_value(v, .[e], elt_name);
            ns := icb_aligned_store(val, p, common_alignment(al, off));
            set_aa_metadata(ns, get_aa_metadata(si));
        }
        return true;
    }
    n := type_count(t);
    if n == 1 {
        ev := icb_extract_value(v, .[0]);
        ic_combine_store_to_new_value(si, ev);
        return true;
    }
    if n > ic.max_array_size return false;
    esz := dl_type_alloc_size(type_elem(t));
    al := inst(si).align;
    elt_name := tprint("%.elt", vname(v));
    addr := op(si, 1);
    addr_name := tprint("%.repack", vname(addr));
    zero := const_int(ir.t_i64, 0);
    offset: u64 = 0;
    if n > 0 for e: 0..n-1 {
        p := icb_gep(t, addr, .[zero, const_int(ir.t_i64, e)], addr_name, F_INBOUNDS);
        val := icb_extract_value(v, .[cast(u32) e], elt_name);
        ns := icb_aligned_store(val, p, common_alignment(al, offset));
        set_aa_metadata(ns, get_aa_metadata(si));
        offset += esz;
    }
    return true;
}

// equivalentAddressValues (this file's: binary operators too)
ic_equivalent_address_values :: (a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    if is_inst(a) && (is_binary_op(inst_op(a)) || is_cast_op(inst_op(a)) || inst_op(a) == .PHI || inst_op(a) == .GEP) && is_inst(b)
        if is_identical_to_when_defined(a, b) return true;
    return false;
}

// visitStoreInst
ic_visit_store :: (si: Value_Id) -> Value_Id {
    val := op(si, 0);
    ptr := op(si, 1);
    if ic_combine_store_to_value_type(si) return ic_erase_inst(si);
    if ic_unpack_store_to_aggregate(si) return ic_erase_inst(si);
    ng := ic_replace_gep_idx_with_zero(ptr, si);
    if ng != NONE return ic_replace_operand(si, 1, ng);
    if !is_unordered(si) return NONE;
    if has_one_use(ptr) {
        if is_inst(ptr) && inst_op(ptr) == .ALLOCA return ic_erase_inst(si);
        if is_inst(ptr) && inst_op(ptr) == .GEP {
            b := op(ptr, 0);
            if is_inst(b) && inst_op(b) == .ALLOCA && has_one_use(b) return ic_erase_inst(si);
        }
    }
    if (ic_points_to_const_mem_mask(ptr) & MR_MOD) == 0 return ic_erase_inst(si);
    // really simple DSE
    bbi := si;
    scan := 6;
    first := block_first(inst_block(si));
    while bbi != first && scan > 0 {
        scan -= 1;
        bbi = inst(bbi).prev;
        if is_debug_or_pseudo_inst(bbi) { scan += 1; continue; }
        if inst_op(bbi) == .STORE {
            prev := bbi;
            if is_unordered(prev) && ic_equivalent_address_values(op(prev, 1), op(si, 1)) && vtype(op(prev, 0)) == vtype(op(si, 0)) {
                wl_push(si);
                ic_erase_inst(prev);
                return NONE;
            }
            break;
        }
        if inst_op(bbi) == .LOAD {
            if bbi == val && ic_equivalent_address_values(op(bbi, 0), ptr) return ic_erase_inst(si);
            break;
        }
        if may_write_to_memory(bbi) || may_read_from_memory(bbi) || may_throw(bbi) break;
    }
    if ic_can_simplify_null_store_or_gep(si) {
        if vkind(val) != .C_POISON return ic_replace_operand(si, 0, const_poison(vtype(val)));
        return NONE;
    }
    if vkind(ptr) == .C_UNDEF || vkind(ptr) == .C_POISON {
        ic_remove_instructions_before_unreachable(si);
        work: [..] Value_Id; work.allocator = temp;
        ic_handle_unreachable_from(inst(si).next, *work);
        ic_handle_potentially_dead_blocks(*work);
        return NONE;
    }
    if vkind(val) == .C_UNDEF || vkind(val) == .C_POISON return ic_erase_inst(si);
    if type_kind(scalar_type(vtype(val))) == .BYTE && pm_imm_constant(val) {
        bt := vtype(val);
        it := type_int(type_bits(scalar_type(bt)));   // Type::getIntFromByteType
        if is_vector_type(bt) it = type_vector(type_count(bt), it, type_kind(bt) == .SVECTOR);
        return ic_replace_operand(si, 0, ce_cast(.BITCAST, val, it));
    }
    if !null_pointer_is_defined(ic.f, type_addrspace(vtype(ptr))) {
        v := ic_simplify_non_null_operand(ptr, true);
        if v != NONE return ic_replace_operand(si, 1, v);
    }
    // store(ptr1, llvm.protected.field.ptr(ptr2)) -> store(llvm.ptrauth.sign(ptr1), ptr2)
    if is_ptr_type(vtype(val)) && is_inst(ptr) && call_iid(ptr) == IID_PROTECTED_FIELD_PTR {
        ds := ic_deactivation_symbol_bundle(ptr);
        saved := ic.b; defer ic.b = saved;   // InsertPointGuard
        icb_set_insert_point(si);
        sign_fn := get_or_insert_intrinsic_declaration(IID_PTRAUTH_SIGN);
        val_int := icb_cast(.PTRTOINT, val, ir.t_i64);
        sign := icb_call_fn_bundle(sign_fn, .[val_int, const_int(ir.t_i32, 2), op(ptr, 1)], "deactivation-symbol", ds);
        sign = icb_cast(.INTTOPTR, sign, type_ptr_as(0));
        ic_replace_operand(si, 0, sign);
        ic_replace_operand(si, 1, op(ptr, 0));
        return si;
    }
    return NONE;
}

// removeInstructionsBeforeUnreachable (returns whether anything changed)
ic_remove_instructions_before_unreachable :: (i: Value_Id) -> bool {
    changed := false;
    while true {
        prev := inst(i).prev;
        if prev == NONE break;
        if is_eh_pad(prev) break;
        if !is_guaranteed_to_transfer_execution(prev) break;
        ic_replace_inst_uses_with(prev, const_poison(vtype(prev)));
        ic_erase_inst(prev);
        changed = true;
    }
    return changed;
}

// Instruction::hasSameSpecialState for two stores
stores_same_special_state :: (a: Value_Id, b: Value_Id) -> bool {
    x := inst(a); y := inst(b);
    return (x.flags & F_VOLATILE) == (y.flags & F_VOLATILE) && x.align == y.align && x.ord1 == y.ord1 && x.sync == y.sync;
}

// mergeStoreIntoSuccessor
ic_merge_store_into_successor :: (si: Value_Id) -> bool {
    if !is_unordered(si) return false;
    store_bb := inst_block(si);
    dest := get_successor(block_terminator(store_bb), 0);
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(dest, *preds);
    if preds.count != 2 return false;
    other_bb := preds[0];
    if other_bb == store_bb other_bb = preds[1];
    if store_bb == dest || other_bb == dest return false;
    bbi := block_terminator(other_bb);
    if bbi == block_first(other_bb) return false;
    mergeable :: (os: Value_Id, si: Value_Id) -> bool {
        if os == NONE || !is_inst(os) || inst_op(os) != .STORE || op(os, 1) != op(si, 1) return false;
        return is_bit_or_noop_pointer_castable(vtype(op(os, 0)), vtype(op(si, 0))) && stores_same_special_state(si, os);
    }
    other: Value_Id = NONE;
    if inst_op(bbi) == .BR {
        bbi = inst(bbi).prev;
        while is_debug_or_pseudo_inst(bbi) {
            if bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        other = bbi;
        if !mergeable(other, si) return false;
    } else if inst_op(bbi) == .CONDBR {
        if get_successor(bbi, 0) != store_bb && get_successor(bbi, 1) != store_bb return false;
        while true {
            if mergeable(bbi, si) { other = bbi; break; }
            if may_read_from_memory(bbi) || may_throw(bbi) || may_write_to_memory(bbi) || bbi == block_first(other_bb) return false;
            bbi = inst(bbi).prev;
        }
        x := block_first(store_bb);
        while x != si {
            if may_read_from_memory(x) || may_throw(x) || may_write_to_memory(x) return false;
            x = inst(x).next;
        }
    } else return false;
    for k: 0..1 {
        s := ifx k == 0 then si else other;
        if get_metadata(s, md_fixed("DIAssignID")) != NONE
            fatal("instcombine: mergeStoreIntoSuccessor with DIAssignID is not supported yet");
    }
    merged_val := op(other, 0);
    merged_loc := merged_debug_loc(get_metadata(si, 0), get_metadata(other, 0));
    if merged_val != op(si, 0) {
        pn := create_phi(vtype(op(si, 0)), 2);
        set_name(pn, "storemerge");
        phi_add_incoming(pn, op(si, 0), inst_block(si));
        icb_set_insert_point(other);
        phi_add_incoming(pn, icb_bit_or_pointer_cast(merged_val, vtype(pn)), other_bb);
        merged_val = ic_insert_new_inst_before(pn, block_first(dest), true);   // BasicBlock::begin() has the head bit
        set_metadata(pn, 0, merged_loc);
    }
    pos := block_first_insertion_pt(dest);
    nsi := new_inst(.STORE, ir.t_void, 2);
    set_op(nsi, 0, merged_val); set_op(nsi, 1, op(si, 1));
    copy_load_store_properties(nsi, si);
    if pos == NONE { ic_link_at_end(nsi, dest); wl_add(nsi); }
    else ic_insert_new_inst_before(nsi, pos, true);
    set_metadata(nsi, 0, merged_loc);
    tags := get_aa_metadata(si);
    if aa_any(tags) set_aa_metadata(nsi, aa_merge(tags, get_aa_metadata(other)));
    ic_erase_inst(si);
    ic_erase_inst(other);
    return true;
}

// AAMDNodes::merge
aa_merge :: (a: AA_Tags, b: AA_Tags) -> AA_Tags {
    r: AA_Tags;
    r.tbaa = tbaa_most_generic(a.tbaa, b.tbaa);
    r.tbaa_struct = NONE;
    r.scope = md_most_generic_alias_scope(a.scope, b.scope);
    r.noalias = md_intersect(a.noalias, b.noalias);
    if a.noalias_as != b.noalias_as && a.noalias_as != NONE && b.noalias_as != NONE
        fatal("instcombine: MDNode::getMostGenericNoaliasAddrspace is not supported yet");
    r.noalias_as = ifx a.noalias_as == b.noalias_as then a.noalias_as else NONE;
    return r;
}

// II->getOperandBundle(OB_deactivation_symbol): its inputs (the global), empty when absent
ic_deactivation_symbol_bundle :: (ii: Value_Id) -> [] Value_Id {
    nb := call_num_bundles(ii);
    if nb > 0 for k: 0..nb-1 {
        if call_bundle_tag(ii, cast(u32) k) != "deactivation-symbol" continue;
        b0 := ir.u32_pool[inst(ii).idx + 3 * cast(u32) k + 1];
        r := NewArray(1, Value_Id,, allocator = temp);
        r[0] = op(ii, b0);
        return r;
    }
    return .[];
}
// Builder.CreateCall(F, Args, {OperandBundleDef(Tag, Inputs)}) (no bundle when Inputs is empty)
icb_call_fn_bundle :: (f: Value_Id, args: [] Value_Id, tag: string, inputs: [] Value_Id) -> Value_Id {
    if inputs.count == 0 return icb_call_fn(f, args);
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + inputs.count + 1));
    r := inst(i);
    r.ty2 = fty;
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
    array_add(*ir.u32_pool, bundle_tag_id(tag));
    array_add(*ir.u32_pool, cast(u32) args.count);
    array_add(*ir.u32_pool, cast(u32)(args.count + inputs.count));
    for args set_op(i, cast(u32) it_index, it);
    for inputs set_op(i, cast(u32)(args.count + it_index), it);
    set_op(i, cast(u32)(args.count + inputs.count), f);
    return icb_insert(i);
}
