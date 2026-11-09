// GlobalOpt: optimize global variables (mark constant, localize, SRA, shrink to bool, delete dead), evaluate static
// constructors, resolve aliases and static ifuncs, fastcc for internal functions, remove empty atexit dtors.
// Ported from llvm/lib/Transforms/IPO/GlobalOpt.cpp (with Utils/Evaluator.cpp in evaluator.jai and
// Utils/CtorUtils.cpp, Utils/GlobalStatus.cpp in ipo_utils.jai).
// Not ported (fail loudly or unreachable for x86 / no target): OptimizeNonTrivialIFuncs needs
// TTI::isMultiversionedFunction, which is false except on AArch64, so it never changes anything here; coldcc needs
// TTI::useColdCCForColdCall, false on X86 (only -enable-coldcc-stress-test changes the calling convention).

go_opts: struct {
    enable_coldcc_stress_test := false;   // -enable-coldcc-stress-test
    coldcc_rel_freq: s64 = 2;             // -coldcc-rel-freq (only read by the BFI-based coldcc path)
    optimize_non_fmv_callers := true;     // -optimize-non-fmv-callers
    max_ifunc_versions: s64 = 5;          // -max-ifunc-versions
};

Global_Opt :: struct {
    not_discardable_comdats: Table(s32, bool);
    has_first_not_fully_evaluated_priority: bool;
    first_not_fully_evaluated_priority: u32;
}

// ---------------------------------------------------------------- small helpers

// the index of v in a module list, looking near `hint` first
list_index_of_hint :: (list: [..] Value_Id, v: Value_Id, hint: s64) -> s64 {
    for d: -2..2 { k := hint + d; if k >= 0 && k < list.count && list[k] == v return k; }
    for list if it == v return it_index;
    assert(false, "global not in its module list");
    return -1;
}

// User list of v in use-list order (Value::users()); a blockaddress is not a user of its function in LLVM 23
go_users :: (v: Value_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { if vkind(ir.u_user[u]) != .C_BLOCKADDR array_add(*out, ir.u_user[u]); u = ir.u_next[u]; }
    return out;
}
go_is_load :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .LOAD; }
go_is_store :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .STORE; }
go_is_simple :: (i: Value_Id) -> bool { r := inst(i); return r.ord1 == 0 && (r.flags & F_VOLATILE) == 0; }
// new LoadInst(Ty, Ptr, Name, isVolatile = false, Align, Order, SSID, InsertBefore)
go_new_load :: (ty: Type_Id, ptr: Value_Id, name: string, align: u64, ord: u8, sync: u32, before: Value_Id) -> Value_Id {
    i := new_inst(.LOAD, ty, 1);
    set_op(i, 0, ptr);
    inst(i).align = align; inst(i).ord1 = ord; inst(i).sync = sync;
    insert_at_position(i, inst_block(before), before, false);
    if name.count set_name(i, name);
    return i;
}
// new StoreInst(Val, Ptr, isVolatile = false, Align, Order, SSID, InsertBefore)
go_new_store :: (v: Value_Id, ptr: Value_Id, align: u64, ord: u8, sync: u32, before: Value_Id) -> Value_Id {
    i := new_inst(.STORE, ir.t_void, 2);
    set_op(i, 0, v); set_op(i, 1, ptr);
    inst(i).align = align; inst(i).ord1 = ord; inst(i).sync = sync;
    insert_at_position(i, inst_block(before), before, false);
    return i;
}
go_set_debug_loc_from :: (dst: Value_Id, src: Value_Id) { set_metadata(dst, MDK_DBG, get_metadata(src, MDK_DBG)); }

// RecursivelyDeleteTriviallyDeadInstructionsPermissive: true if anything was deleted
go_recursively_delete_permissive :: (list: [..] Value_Id) -> bool {
    any := false;
    for list if vkind(it) != .DEAD && is_inst(it) && is_instruction_trivially_dead(it) { any = true; break; }
    if !any return false;
    recursively_delete_trivially_dead_instructions(list);
    return true;
}

// ReplaceableMetadataImpl::SalvageDebugInfo(GV): debug-info nodes that use the global get poison instead
go_salvage_debug_info :: (gv: Value_Id) {
    md_as_value_deleted(gv, true);
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, gv);
    found, m := table_find(*ir.md_map, key_view(k));
    if !found return;
    p: Md_Id = NONE;
    for * row: ir.mds {
        if row.kind != .SPECIAL || row.nops == 0 continue;
        for x: 0..row.nops-1 if ir.md_ops[row.ops + x] == m {
            if p == NONE p = md_value(const_poison(vtype(gv)));
            ir.md_ops[row.ops + x] = p;
        }
    }
}

// ---------------------------------------------------------------- leak checker roots, cleanup of users

// isLeakCheckerRoot
go_is_leak_checker_root :: (gv: Value_Id) -> bool {
    if glob(gv).linkage == .PRIVATE return false;
    types: [..] Type_Id; types.allocator = temp;
    array_add(*types, glob(gv).value_type);
    limit := 20;
    while true {
        ty := pop(*types);
        k := type_kind(ty);
        if k == .PTR return true;
        if k == .VECTOR || k == .SVECTOR { if is_ptr_type(type_elem(ty)) return true; }
        else if k == .ARRAY array_add(*types, type_elem(ty));
        else if k == .STRUCT {
            if (ir.types[ty].flags & TYF_OPAQUE) != 0 return true;
            for e: 0..cast(s64) type_nsub(ty) - 1 {
                inner := type_sub(ty, cast(u32) e);
                ik := type_kind(inner);
                if ik == .PTR return true;
                if ik == .STRUCT || ik == .ARRAY || ik == .VECTOR || ik == .SVECTOR array_add(*types, inner);
            }
        }
        limit -= 1;
        if limit == 0 return true;
        if types.count == 0 break;
    }
    return false;
}

// IsSafeComputationToRemove
go_is_safe_computation_to_remove :: (v_in: Value_Id) -> bool {
    v := v_in;
    while true {
        if is_const(v) return true;
        if num_uses(v) != 1 return false;
        if go_is_load(v) || (is_inst(v) && inst_op(v) == .INVOKE) || vkind(v) == .ARGUMENT || is_global_value(vkind(v)) return false;
        if is_allocation_fn(v) return true;
        if may_have_side_effects(v) return false;
        if inst_op(v) == .GEP {
            if !gep_has_all_constant_indices(v) return false;
        } else if nops(v) != 1 return false;
        v = op(v, 0);
    }
    return false;
}

// CleanupPointerRootUsers
go_cleanup_pointer_root_users :: (gv: Value_Id) -> bool {
    changed := false;
    dead: [..] [2] Value_Id; dead.allocator = temp;
    worklist := go_users(gv);
    while worklist.count {
        u := pop(*worklist);
        if vkind(u) == .DEAD continue;
        if go_is_store(u) {
            v := op(u, 0);
            if is_const(v) { changed = true; erase_inst_with_metadata(u); }
            else if is_inst(v) { if num_uses(v) == 1 array_add(*dead, .[v, u]); }
        } else if is_inst(u) && is_memset_inst(u) {
            v := call_arg(u, 1);
            if is_const(v) { changed = true; erase_inst_with_metadata(u); }
            else if is_inst(v) { if num_uses(v) == 1 array_add(*dead, .[v, u]); }
        } else if is_inst(u) && inst_op(u) == .CALL && is_mem_transfer_inst(u) {
            src := mti_source(u);
            if vkind(src) == .GLOBAL_VAR && glob(src).is_const { changed = true; erase_inst_with_metadata(u); }
            else if is_inst(src) { if num_uses(src) == 1 array_add(*dead, .[src, u]); }
        } else if vkind(u) == .C_EXPR {
            if cexpr(u).op == .GEP { for go_users(u) array_add(*worklist, it); }
        }
    }
    for d: dead {
        i := d[0]; store := d[1];
        if vkind(i) == .DEAD || vkind(store) == .DEAD continue;
        if go_is_safe_computation_to_remove(i) {
            erase_inst_with_metadata(store);
            while true {
                if is_allocation_fn(i) break;
                j := op(i, 0);
                if !is_inst(j) break;
                erase_inst_with_metadata(i);
                i = j;
            }
            erase_inst_with_metadata(i);
            changed = true;
        }
    }
    remove_dead_constant_users(gv);
    return changed;
}

// CleanupConstantGlobalUsers
go_cleanup_constant_global_users :: (gv: Value_Id) -> bool {
    init := gv_initializer(gv);
    worklist := go_users(gv);
    visited: Table(Value_Id, bool); visited.allocator = temp;
    changed := false;
    maybe_dead: [..] Value_Id; maybe_dead.allocator = temp;
    erase_from_parent :: (i: Value_Id, maybe_dead: *[..] Value_Id, changed: *bool) {
        for k: 0..cast(s64) nops(i) - 1 { o := op(i, cast(u32) k); if o != NONE && is_inst(o) array_add(maybe_dead, o); }
        erase_inst_with_metadata(i);
        changed.* = true;
    }
    while worklist.count {
        u := pop(*worklist);
        if table_contains(*visited, u) continue;
        table_add(*visited, u, true);
        if vkind(u) == .DEAD continue;
        o := opr_code(u);
        if o == .BITCAST for go_users(u) array_add(*worklist, it);
        if o == .ADDRSPACECAST { for go_users(u) array_add(*worklist, it); }
        else if o == .GEP { for go_users(u) array_add(*worklist, it); }
        else if go_is_load(u) {
            ty := vtype(u);
            res := cfo_load_from_uniform_value(init, ty);
            if res != NONE {
                ipo_rauw(u, res);
                erase_from_parent(u, *maybe_dead, *changed);
                continue;
            }
            ptr := op(u, 0);
            off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
            ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
            if is_inst(ptr) && is_call_base(ptr) && call_iid(ptr) == IID_THREADLOCAL_ADDRESS ptr = call_arg(ptr, 0);
            if ptr == gv {
                val := cfo_load_from_const(init, ty, off);
                if val != NONE {
                    ipo_rauw(u, val);
                    erase_from_parent(u, *maybe_dead, *changed);
                }
            }
        } else if go_is_store(u) {
            erase_from_parent(u, *maybe_dead, *changed);
        } else if is_mem_intrinsic_inst(u) {
            if get_underlying_object(call_arg(u, 0)) == gv erase_from_parent(u, *maybe_dead, *changed);
        } else if is_inst(u) && is_call_base(u) && call_iid(u) == IID_THREADLOCAL_ADDRESS {
            for go_users(u) array_add(*worklist, it);
        }
    }
    if go_recursively_delete_permissive(maybe_dead) changed = true;
    remove_dead_constant_users(gv);
    return changed;
}

// ---------------------------------------------------------------- SRA of globals

Go_Global_Part :: struct { offset: u64; ty: Type_Id; init: Value_Id = NONE; is_loaded: bool; is_stored: bool; }

go_find_part :: (parts: *[..] Go_Global_Part, off: u64) -> s64 {
    for parts.* if it.offset == off return it_index;
    return -1;
}

// collectSRATypes
go_collect_sra_types :: (parts: *[..] Go_Global_Part, gv: Value_Id) -> bool {
    worklist: [..] Use_Id; worklist.allocator = temp;
    visited: Table(Use_Id, bool); visited.allocator = temp;
    append_uses :: (v: Value_Id, worklist: *[..] Use_Id, visited: *Table(Use_Id, bool)) {
        u := ir.v_first_use[v];
        while u != NONE {
            if !table_contains(visited, u) { table_add(visited, u, true); array_add(worklist, u); }
            u = ir.u_next[u];
        }
    }
    append_uses(gv, *worklist, *visited);
    while worklist.count {
        u := pop(*worklist);
        v := ir.u_user[u];
        o := opr_code(v);
        if o == .BITCAST || o == .ADDRSPACECAST || (o == .GEP && gep_has_all_constant_indices(v)) {
            append_uses(v, *worklist, *visited);
            continue;
        }
        ptr := load_store_pointer_operand(v);
        if ptr != NONE {
            if go_is_store(v) && opno_of(u) == 0 return false;
            off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
            ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
            if ptr != gv || ap_active_bits(off) >= 64 return false;
            ty := ifx go_is_load(v) then vtype(v) else vtype(op(v, 0));
            offv := ap_zext_value(off);
            idx := go_find_part(parts, offv);
            inserted := idx < 0;
            if inserted { array_add(parts, .{offset = offv, ty = ty}); idx = parts.count - 1; }
            if ty != parts.*[idx].ty return false;
            if inserted {
                parts.*[idx].init = cfo_load_from_const(gv_initializer(gv), ty, off);
                if parts.*[idx].init == NONE return false;
            }
            if type_is_scalable(ty) return false;
            is_stored := false;
            if go_is_store(v) {
                sc := op(v, 0);
                if !is_const(sc) is_stored = true;
                else is_stored = parts.*[idx].init != sc;
            }
            parts.*[idx].is_loaded |= go_is_load(v);
            parts.*[idx].is_stored |= is_stored;
            continue;
        }
        if is_const(v) {
            if !is_safe_to_destroy_constant(v) return false;
            continue;
        }
        return false;
    }
    return true;
}

// DIExpression::extractIfOffset
diexpr_extract_if_offset :: (m: Md_Id) -> bool, s64 {
    ok, e := diexpr_single_location_elts(m);
    if !ok return false, 0;
    if e.count == 0 return true, 0;
    if e.count == 2 && e[0] == 0x23 return true, cast,no_check(s64) e[1];     // DW_OP_plus_uconst
    if e.count == 3 && e[0] == 0x10 {                                       // DW_OP_constu
        if e[2] == 0x22 return true, cast,no_check(s64) e[1];                // DW_OP_plus
        if e[2] == 0x1c return true, -cast,no_check(s64) e[1];               // DW_OP_minus
    }
    return false, 0;
}
// DIExpression::createFragmentExpression: (ok, expression)
diexpr_create_fragment_expression :: (expr: Md_Id, offset_in: u64, size: u64) -> bool, Md_Id {
    offset := offset_in;
    ops: [..] u64; ops.allocator = temp;
    can_split := true;
    emit_fragment := true;
    e := diexpr_elts(expr);
    i := 0;
    while i < e.count {
        o := e[i];
        sz := expr_op_size(o);
        if o == 0x25 || o == 0x26 || o == 0x24 || o == 0x22 || o == 0x23 || o == 0x1c {   // shr shra shl plus plus_uconst minus
            can_split = false;
        } else if o == 0x06 || o == 0x94 || o == 0xa6 || o == 0x18 || o == 0x95 || o == 0xa7 {   // deref*, xderef*
            can_split = true;
        } else if o == DW_OP_STACK_VALUE {
            if !can_split return false, NONE;
        } else if o == DW_OP_LLVM_FRAGMENT_ {
            if !emit_fragment return false, NONE;
            offset += e[i + 1];
            i += sz;
            continue;
        } else if o == DW_OP_LLVM_EXTRACT_BITS_ZEXT || o == DW_OP_LLVM_EXTRACT_BITS_SEXT {
            eo := e[i + 1]; es := e[i + 2];
            if eo >= offset && eo + es <= offset + size {
                array_add(*ops, o); array_add(*ops, eo - offset); array_add(*ops, es);
                emit_fragment = false;
                i += sz;
                continue;
            }
            return false, NONE;
        }
        for k: 0..sz-1 array_add(*ops, e[i + k]);
        i += sz;
    }
    if emit_fragment { array_add(*ops, DW_OP_LLVM_FRAGMENT_); array_add(*ops, offset); array_add(*ops, size); }
    return true, diexpr_get(ops);
}
// DIGlobalVariableExpression::get(Var, Expr)
di_gve_get :: (var: Md_Id, expr: Md_Id) -> Md_Id {
    ops: [2] Md_Id;
    ops[0] = var; ops[1] = expr;
    return di_get(.GLOBAL_VARIABLE_EXPRESSION, false, ops, .[]);
}
// DIVariable::getType()->getSizeInBits() of a DIGlobalVariable
go_divar_size_bits :: (var: Md_Id) -> u64 {
    ok, sz := divar_size_bits(var);
    if !ok return 0;
    return sz;
}

// transferSRADebugInfo
go_transfer_sra_debug_info :: (gv: Value_Id, ngv: Value_Id, frag_off: u64, frag_size: u64, var_size: u64) {
    gves: [..] Md_Id; gves.allocator = temp;
    gv_get_debug_info(gv, *gves);
    for gve: gves {
        var := md_op(gve, 0);
        expr := md_op(gve, 1);
        frag_end := frag_off + frag_size;
        ok, cur_off_bytes := diexpr_extract_if_offset(expr);
        if !ok continue;
        if cur_off_bytes < 0 continue;
        cur_off := 8 * cast(u64) cur_off_bytes;
        if cur_off >= frag_end continue;
        cur_size := go_divar_size_bits(var);
        cur_end := cur_off + cur_size;
        if cur_size != 0 && cur_end <= frag_off continue;
        if cur_size != 0 && cur_off >= frag_off && cur_end <= frag_end {
            in_frag := (cur_off - frag_off) / 8;
            if in_frag != 0 { e: [2] u64; e[0] = 0x23; e[1] = in_frag; expr = diexpr_get(e); }
            else expr = diexpr_get(.[]);
            gv_add_debug_info(ngv, di_gve_get(var, expr));
            continue;
        }
        if frag_size < var_size {
            if cur_off > frag_off continue;
            cfo := frag_off - cur_off;
            cfs := frag_size;
            if cur_size != 0 && cur_end < frag_end cfs -= (frag_end - cur_end);
            if cur_off expr = diexpr_get(.[]);
            fok, fe := diexpr_create_fragment_expression(expr, cfo, cfs);
            if fok expr = fe; else continue;
        }
        gv_add_debug_info(ngv, di_gve_get(var, expr));
    }
}

// SRAGlobal: true if the global was split
go_sra_global :: (gv: Value_Id) -> bool {
    assert(gv_has_local_linkage(gv));
    parts: [..] Go_Global_Part; parts.allocator = temp;
    if !go_collect_sra_types(*parts, gv) || parts.count == 0 return false;
    if parts.count == 1 && parts[0].ty == glob(gv).value_type return false;
    num := 0;
    for parts if it.is_loaded && it.is_stored num += 1;
    if num > 16 return false;
    // sort by offset
    for i: 1..parts.count-1 {
        x := parts[i]; j := i - 1;
        while j >= 0 && parts[j].offset > x.offset { parts[j + 1] = parts[j]; j -= 1; }
        parts[j + 1] = x;
    }
    offset: u64 = 0;
    for parts {
        if it.offset < offset return false;
        offset = it.offset + dl_type_alloc_size(it.ty);
    }
    if offset > dl_type_alloc_size(glob(gv).value_type) return false;

    start_align := glob(gv).align;
    if start_align == 0 start_align = dl_abi_align(glob(gv).value_type);   // getValueOrABITypeAlignment
    var_size := dl_type_size_bits(glob(gv).value_type);
    new_globals: [..] Value_Id; new_globals.allocator = temp;   // parallel to parts
    suffix := 0;
    for p: parts {
        ngv := gv_create(p.ty, false, .INTERNAL, p.init, tconcat(vname(gv), ".", tdec(cast(u64) suffix)), gv, glob(gv).tls, glob(gv).addrspace);
        suffix += 1;
        gv_copy_attributes_from(ngv, gv);
        array_add(*new_globals, ngv);
        glob(ngv).align = go_common_alignment(start_align, p.offset);
        go_transfer_sra_debug_info(gv, ngv, p.offset * 8, dl_type_alloc_size(p.ty) * 8, var_size);
    }

    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    dead_insts: [..] Value_Id; dead_insts.allocator = temp;
    append_users :: (v: Value_Id, worklist: *[..] Value_Id, visited: *Table(Value_Id, bool)) {
        u := ir.v_first_use[v];
        while u != NONE {
            usr := ir.u_user[u];
            if !table_contains(visited, usr) { table_add(visited, usr, true); array_add(worklist, usr); }
            u = ir.u_next[u];
        }
    }
    append_users(gv, *worklist, *visited);
    while worklist.count {
        v := pop(*worklist);
        o := opr_code(v);
        if o == .BITCAST || o == .ADDRSPACECAST || o == .GEP {
            append_users(v, *worklist, *visited);
            if is_inst(v) array_add(*dead_insts, v);
            continue;
        }
        ptr := load_store_pointer_operand(v);
        if ptr != NONE {
            off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
            ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
            assert(ptr == gv);
            idx := go_find_part(*parts, ap_zext_value(off));
            assert(idx >= 0);
            ngv := new_globals[idx];
            ls_ty := ifx go_is_load(v) then vtype(v) else vtype(op(v, 0));
            new_align := get_or_enforce_known_alignment(ngv, dl_pref_align(ls_ty), v, null, null);
            if go_is_load(v) { set_op(v, 0, ngv); inst(v).align = new_align; }
            else { set_op(v, 1, ngv); inst(v).align = new_align; }
            continue;
        }
    }
    recursively_delete_trivially_dead_instructions(dead_insts);
    remove_dead_constant_users(gv);
    gv_erase_from_parent(gv);
    return true;
}
// commonAlignment(A, Offset)
go_common_alignment :: (a: u64, offset: u64) -> u64 {
    if offset == 0 return a;
    low := offset & (~offset + 1);
    return min(a, low);
}

// ---------------------------------------------------------------- stored-once pointer globals

// AllUsesOfValueWillTrapIfNull
go_all_uses_of_value_will_trap_if_null :: (v: Value_Id, phis: *Table(Value_Id, bool)) -> bool {
    for u: go_users(v) {
        if is_inst(u) && null_pointer_is_defined(inst_fn(u)) return false;
        o := opr_code(u);
        if !is_inst(u) return false;
        if o == .LOAD {
        } else if o == .STORE {
            if op(u, 0) == v return false;
        } else if o == .CALL || o == .INVOKE {
            if call_callee(u) != v return false;
        } else if o == .ADDRSPACECAST || o == .GEP {
            if !go_all_uses_of_value_will_trap_if_null(u, phis) return false;
        } else if o == .PHI {
            if !table_contains(phis, u) {
                table_add(phis, u, true);
                if !go_all_uses_of_value_will_trap_if_null(u, phis) return false;
            }
        } else if o == .ICMP && !cmp_pred_is_signed(inst(u).pred) && go_is_load(op(u, 0)) && vkind(op(u, 1)) == .C_NULL {
            // compared against null: replaced with the init bool later
        } else return false;
    }
    return true;
}
cmp_pred_is_signed :: (p: u8) -> bool { return p == ICMP_SGT || p == ICMP_SGE || p == ICMP_SLT || p == ICMP_SLE; }

// allUsesOfLoadedValueWillTrapIfNull
go_all_uses_of_loaded_value_will_trap_if_null :: (gv: Value_Id) -> bool {
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, gv);
    while worklist.count {
        p := pop(*worklist);
        for u: go_users(p) {
            if go_is_load(u) {
                if !go_is_simple(u) return false;
                phis: Table(Value_Id, bool); phis.allocator = temp;
                if !go_all_uses_of_value_will_trap_if_null(u, *phis) return false;
            } else if go_is_store(u) {
                if !go_is_simple(u) return false;
                if op(u, 1) != p return false;
            } else if vkind(u) == .C_EXPR {
                if strip_pointer_casts(u) != gv return false;
                array_add(*worklist, u);
            } else return false;
        }
    }
    return true;
}

// allUsesOfLoadAndStores
go_all_uses_of_load_and_stores :: (gv: Value_Id, uses: *[..] Value_Id) {
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, gv);
    while worklist.count {
        p := pop(*worklist);
        for u: go_users(p) {
            if vkind(u) == .C_EXPR { array_add(*worklist, u); continue; }
            assert(go_is_load(u) || go_is_store(u));
            array_add(uses, u);
        }
    }
}

// OptimizeAwayTrappingUsesOfValue
go_optimize_away_trapping_uses_of_value :: (v: Value_Id, new_v: Value_Id) -> bool {
    changed := false;
    u := ir.v_first_use[v];
    while u != NONE {
        i := ir.u_user[u];
        u = ir.u_next[u];
        if null_pointer_is_defined(inst_fn(i)) return false;
        o := inst_op(i);
        if o == .LOAD {
            set_op(i, 0, new_v);
            changed = true;
        } else if o == .STORE {
            if op(i, 1) == v { set_op(i, 1, new_v); changed = true; }
        } else if o == .CALL || o == .INVOKE {
            if call_callee(i) == v {
                set_op(i, nops(i) - 1, new_v);
                changed = true;
                passed_as_arg := false;
                for k: 0..cast(s64) call_num_args(i) - 1 if call_arg(i, cast(u32) k) == v {
                    passed_as_arg = true;
                    set_op(i, cast(u32) k, new_v);
                }
                if passed_as_arg u = ir.v_first_use[v];
            }
        } else if o == .ADDRSPACECAST {
            changed |= go_optimize_away_trapping_uses_of_value(i, ce_cast(.ADDRSPACECAST, new_v, vtype(i)));
            if !has_uses(i) { changed = true; u = go_next_use_not_of(u, i); erase_inst_with_metadata(i); }
        } else if o == .GEP {
            idxs: [..] Value_Id; idxs.allocator = temp;
            for k: 1..cast(s64) nops(i) - 1 { c := op(i, cast(u32) k); if is_const(c) array_add(*idxs, c); else break; }
            if idxs.count == nops(i) - 1 {
                ce := ce_gep(inst(i).ty2, new_v, idxs, 0);
                changed |= go_optimize_away_trapping_uses_of_value(i, ce);
            }
            if !has_uses(i) { changed = true; u = go_next_use_not_of(u, i); erase_inst_with_metadata(i); }
        }
    }
    return changed;
}
// the saved next use may belong to the instruction about to be erased (it uses v twice)
go_next_use_not_of :: (u_in: Use_Id, i: Value_Id) -> Use_Id {
    u := u_in;
    while u != NONE && ir.u_user[u] == i u = ir.u_next[u];
    return u;
}

// OptimizeAwayTrappingUsesOfLoads
go_optimize_away_trapping_uses_of_loads :: (gv: Value_Id, lv: Value_Id) -> bool {
    changed := false;
    all_non_store_uses_gone := true;
    u := ir.v_first_use[gv];
    while u != NONE {
        gu := ir.u_user[u];
        u = ir.u_next[u];
        if go_is_load(gu) {
            changed |= go_optimize_away_trapping_uses_of_value(gu, lv);
            if !has_uses(gu) { u = go_next_use_not_of(u, gu); erase_inst_with_metadata(gu); changed = true; }
            else all_non_store_uses_gone = false;
        } else if go_is_store(gu) {
        } else {
            all_non_store_uses_gone = false;
        }
    }
    if all_non_store_uses_gone {
        if go_is_leak_checker_root(gv) changed |= go_cleanup_pointer_root_users(gv);
        else { changed = true; go_cleanup_constant_global_users(gv); }
        if !has_uses(gv) { changed = true; gv_erase_from_parent(gv); }
    }
    return changed;
}

// ConstantPropUsersOf
go_constant_prop_users_of :: (v: Value_Id) {
    u := ir.v_first_use[v];
    while u != NONE {
        i := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(i) continue;
        c := cfo_instruction(i);
        if c == NONE continue;
        ipo_rauw(i, c);
        u = go_next_use_not_of(u, i);
        if is_instruction_trivially_dead(i) erase_inst_with_metadata(i);
    }
}

// OptimizeGlobalAddressOfAllocation
go_optimize_global_address_of_allocation :: (gv: Value_Id, ci: Value_Id, alloc_size: u64, init_val: Value_Id) -> Value_Id {
    gty := type_array(alloc_size, ir.t_i8);
    new_gv := gv_create(gty, false, .INTERNAL, const_undef(gty), tconcat(vname(gv), ".body"), NONE, glob(gv).tls, dl_default_globals_addrspace());
    if !(vkind(init_val) == .C_UNDEF || vkind(init_val) == .C_POISON) {
        b: Irb;
        irb_set_before(*b, inst_next(ci));
        irb_memset(*b, new_gv, init_val, const_int(type_int(64), alloc_size), 0, false);
    }
    ipo_rauw(ci, new_gv);

    init_name := tconcat(vname(gv), ".init");
    init_bool := gv_create_detached(ir.t_i1, false, .INTERNAL, const_int(ir.t_i1, 0), glob(gv).tls, glob(gv).addrspace);
    init_bool_used := false;

    guses: [..] Value_Id; guses.allocator = temp;
    go_all_uses_of_load_and_stores(gv, *guses);
    for u: guses {
        if go_is_store(u) {
            sv := op(u, 0);
            nsi := go_new_store(const_int(ir.t_i1, ifx vkind(sv) != .C_NULL then cast(u64) 1 else 0), init_bool, 1, inst(u).ord1, inst(u).sync, u);
            go_set_debug_loc_from(nsi, u);
            erase_inst_with_metadata(u);
            continue;
        }
        li := u;
        while has_uses(li) {
            lu := ir.v_first_use[li];
            ici := ir.u_user[lu];
            if !(is_inst(ici) && inst_op(ici) == .ICMP) { use_set(lu, new_gv); continue; }
            lv := go_new_load(ir.t_i1, init_bool, tconcat(init_name, ".val"), 1, inst(li).ord1, inst(li).sync, li);
            go_set_debug_loc_from(lv, li);
            init_bool_used = true;
            p := inst(ici).pred;
            if p == ICMP_ULT lv = const_int(ir.t_i1, 0);
            else if p == ICMP_UGE lv = const_int(ir.t_i1, 1);
            else if p == ICMP_ULE || p == ICMP_EQ {
                nt := create_binop(.XOR, lv, const_int(ir.t_i1, 1));
                insert_at_position(nt, inst_block(ici), ici, false);
                set_name(nt, "notinit");
                go_set_debug_loc_from(nt, ici);
                lv = nt;
            } else if p == ICMP_NE || p == ICMP_UGT {
            } else fatal("globalopt: unknown icmp predicate");
            ipo_rauw(ici, lv);
            erase_inst_with_metadata(ici);
        }
        erase_inst_with_metadata(li);
    }
    if !init_bool_used {
        while has_uses(init_bool) erase_inst_with_metadata(ir.u_user[ir.v_first_use[init_bool]]);
        ir.v_kind[init_bool] = .DEAD;   // delete InitBool
    } else gv_insert_before(init_bool, gv, init_name);

    gv_erase_from_parent(gv);
    erase_inst_with_metadata(ci);
    go_constant_prop_users_of(new_gv);
    return new_gv;
}
dl_default_globals_addrspace :: () -> u32 { return dl.globals_as; }

// valueIsOnlyUsedLocallyOrStoredToOneGlobal
go_value_is_only_used_locally_or_stored_to_one_global :: (ci: Value_Id, gv: Value_Id) -> bool {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, ci);
    while worklist.count {
        v := pop(*worklist);
        if table_contains(*visited, v) continue;
        table_add(*visited, v, true);
        u := ir.v_first_use[v];
        while u != NONE {
            defer u = ir.u_next[u];
            usr := ir.u_user[u];
            if go_is_load(usr) || (is_inst(usr) && (inst_op(usr) == .ICMP || inst_op(usr) == .FCMP)) continue;
            if go_is_store(usr) {
                if op(usr, 0) == v && strip_pointer_casts(op(usr, 1)) != gv return false;
                continue;
            }
            if is_inst(usr) && inst_op(usr) == .GEP { array_add(*worklist, usr); continue; }
            return false;
        }
    }
    return true;
}

// tryToOptimizeStoreOfAllocationToGlobal
go_try_to_optimize_store_of_allocation_to_global :: (gv: Value_Id, ci: Value_Id) -> bool {
    if !is_removable_alloc(ci) return false;
    init_val := get_initial_value_of_allocation(ci, ir.t_i8);
    if init_val == NONE return false;
    os: Os_Opts;
    ok, alloc_size := get_object_size(ci, os);
    if !ok return false;
    if alloc_size >= 2048 return false;
    if !go_all_uses_of_loaded_value_will_trap_if_null(gv) return false;
    if !go_value_is_only_used_locally_or_stored_to_one_global(ci, gv) return false;
    go_optimize_global_address_of_allocation(gv, ci, alloc_size, init_val);
    return true;
}

// optimizeOnceStoredGlobal
go_optimize_once_stored_global :: (gv: Value_Id, sov: Value_Id) -> bool {
    init := gv_initializer(gv);
    if is_ptr_type(vtype(init)) && is_null_value(init) && is_ptr_type(vtype(sov)) &&
       !null_pointer_is_defined(NONE, ir.types[vtype(init)].a) {
        if is_const(sov) {
            if go_optimize_away_trapping_uses_of_loads(gv, sov) return true;
        } else if is_allocation_fn(sov) {
            if is_inst(sov) && inst_op(sov) == .CALL {
                if go_try_to_optimize_store_of_allocation_to_global(gv, sov) return true;
            }
        }
    }
    return false;
}

// TryToShrinkGlobalToBoolean
go_try_to_shrink_global_to_boolean :: (gv: Value_Id, other_val: Value_Id) -> bool {
    el_ty := glob(gv).value_type;
    if el_ty == ir.t_i1 || is_fp_type(el_ty) || is_ptr_type(el_ty) || is_vector_type(el_ty) return false;
    for u: go_users(gv) {
        if !go_is_load(u) && !go_is_store(u) return false;
        lst := ifx go_is_load(u) then vtype(u) else vtype(op(u, 0));
        if lst != el_ty return false;
    }
    new_gv := gv_create_detached(ir.t_i1, false, .INTERNAL, const_int(ir.t_i1, 0), glob(gv).tls, glob(gv).addrspace);
    gv_copy_attributes_from(new_gv, gv);
    gv_insert_before(new_gv, gv, tconcat(vname(gv), ".b"));
    init_val := gv_initializer(gv);
    gves: [..] Md_Id; gves.allocator = temp;
    gv_get_debug_info(gv, *gves);

    is_one_zero := false;
    emit_one_or_zero := true;
    if vkind(other_val) == .C_INT && ap_active_bits(const_ap(other_val)) <= 64 {
        is_one_zero = is_null_value(init_val) && ap_is_one(const_ap(other_val));
        ci_init := gv_initializer(gv);
        if vkind(ci_init) == .C_INT && ap_active_bits(const_ap(ci_init)) <= 64 {
            val_init := const_int_zext(ci_init);
            val_other := const_int_zext(other_val);
            val_minus := val_other - val_init;
            for gve: gves {
                dgv := md_op(gve, 0);
                e := md_op(gve, 1);
                size_in_octets := dl_type_alloc_size(glob(new_gv).value_type);
                ops: [..] u64; ops.allocator = temp;
                // DW_OP_deref_size, size, DW_OP_constu, ValMinus, DW_OP_mul, DW_OP_constu, ValInit, DW_OP_plus
                array_add(*ops, 0x94); array_add(*ops, size_in_octets); array_add(*ops, 0x10); array_add(*ops, val_minus);
                array_add(*ops, 0x1e); array_add(*ops, 0x10); array_add(*ops, val_init); array_add(*ops, 0x22);
                e = diexpr_prepend_opcodes(e, *ops, true);
                gv_add_debug_info(new_gv, di_gve_get(dgv, e));
            }
            emit_one_or_zero = false;
        }
    }
    if emit_one_or_zero for gves gv_add_debug_info(new_gv, it);

    while has_uses(gv) {
        ui := ir.u_user[ir.v_first_use[gv]];
        if go_is_store(ui) {
            storing_other := op(ui, 0) == other_val;
            store_val: Value_Id;
            if storing_other || op(ui, 0) == init_val {
                store_val = const_int(ir.t_i1, ifx storing_other then cast(u64) 1 else 0);
            } else {
                stored := op(ui, 0);
                if go_is_load(stored) {
                    assert(op(stored, 0) == gv);
                    store_val = go_new_load(ir.t_i1, new_gv, tconcat(vname(stored), ".b"), 1, inst(stored).ord1, inst(stored).sync, stored);
                    go_set_debug_loc_from(store_val, stored);
                } else {
                    store_val = op(stored, 0);
                    assert(go_is_load(store_val));
                }
            }
            nsi := go_new_store(store_val, new_gv, 1, inst(ui).ord1, inst(ui).sync, ui);
            go_set_debug_loc_from(nsi, ui);
        } else {
            li := ui;
            nli := go_new_load(ir.t_i1, new_gv, tconcat(vname(li), ".b"), 1, inst(li).ord1, inst(li).sync, li);
            nsi: Value_Id;
            if is_one_zero nsi = create_cast(.ZEXT, nli, vtype(li));
            else {
                nsi = create_select(nli, other_val, init_val);
            }
            insert_at_position(nsi, inst_block(li), li, false);
            if !is_one_zero set_explicitly_unknown_branch_weights_if_profiled(nsi, "globalopt");
            ic_take_name(nsi, li);
            go_set_debug_loc_from(nli, li);
            go_set_debug_loc_from(nsi, li);
            ipo_rauw(li, nsi);
        }
        erase_inst_with_metadata(ui);
    }
    gv_take_name(new_gv, gv);
    gv_erase_from_parent(gv);
    return true;
}

// ---------------------------------------------------------------- deleteIfDead, localization, processGlobal

// deleteIfDead
go_delete_if_dead :: (go: *Global_Opt, gv: Value_Id) -> bool {
    remove_dead_constant_users(gv);
    if !gv_is_discardable_if_unused(gv) && !is_declaration(gv) return false;
    c := gv_comdat(gv);
    if c >= 0 && !gv_has_local_linkage(gv) && table_contains(*go.not_discardable_comdats, c) return false;
    dead: bool;
    if vkind(gv) == .FUNCTION dead = (is_declaration(gv) && fn_use_empty(gv)) || fn_is_def_trivially_dead(gv);
    else dead = !has_uses(gv);
    if !dead return false;
    go_salvage_debug_info(gv);
    gv_erase_from_parent(gv);
    return true;
}

// isPointerValueDeadOnEntryToFunction
go_is_pointer_value_dead_on_entry_to_function :: (f: Value_Id, gv: Value_Id) -> bool {
    loads: [..] Value_Id; loads.allocator = temp;
    stores: [..] Value_Id; stores.allocator = temp;
    for u: go_users(gv) {
        if !is_inst(u) return false;
        if go_is_load(u) array_add(*loads, u);
        else if go_is_store(u) array_add(*stores, u);
        else return false;
    }
    dt := get_domtree(f);
    if loads.count * stores.count > 100 return false;
    for l: loads {
        lty := vtype(l);
        found := false;
        for s: stores {
            sty := vtype(op(s, 0));
            if dt_dominates_inst(dt, s, l) && dl_type_store_size(lty) <= dl_type_store_size(sty) { found = true; break; }
        }
        if !found return false;
    }
    return true;
}

// forwardStoredOnceStore
go_forward_stored_once_store :: (gv: Value_Id, store: Value_Id) -> bool {
    sov := op(store, 0);
    if !is_const(sov) return false;
    f := inst_fn(store);
    loads: [..] Value_Id; loads.allocator = temp;
    for u: go_users(gv) {
        if go_is_load(u) && inst_fn(u) == f && vtype(u) == vtype(sov) && go_is_simple(u) array_add(*loads, u);
    }
    made_change := false;
    if loads.count {
        dt := get_domtree(f);
        for li: loads {
            if dt_dominates_inst(dt, store, li) {
                ipo_rauw(li, sov);
                erase_inst_with_metadata(li);
                made_change = true;
            }
        }
    }
    return made_change;
}

// processInternalGlobal
go_process_internal_global :: (gv_in: Value_Id, gs: *Global_Status) -> bool {
    gv := gv_in;
    vt := glob(gv).value_type;
    if !gs.has_multiple_accessing_functions && gs.accessing_function != NONE && is_single_value_type(vt) &&
       glob(gv).addrspace == dl.alloca_as && !glob(gv).ext_init && fn_does_not_recurse(gs.accessing_function) &&
       go_is_pointer_value_dead_on_entry_to_function(gs.accessing_function, gv) {
        entry := fn_entry(gs.accessing_function);
        first := block_first(entry);
        ai := new_inst(.ALLOCA, type_ptr(dl.alloca_as), 1);
        set_op(ai, 0, const_int(type_int(32), 1));
        inst(ai).ty2 = vt;
        inst(ai).align = dl_pref_align(vt);
        inst(ai).addrspace = dl.alloca_as;
        insert_at_position(ai, entry, first, true);
        set_name(ai, vname(gv));
        init := gv_initializer(gv);
        if !(vkind(init) == .C_UNDEF || vkind(init) == .C_POISON) {
            si := new_inst(.STORE, ir.t_void, 2);
            set_op(si, 0, init); set_op(si, 1, ai);
            inst(si).align = dl_abi_align(vtype(init));
            insert_at_position(si, entry, first, true);
        }
        ipo_rauw(gv, ai);
        gv_erase_from_parent(gv);
        return true;
    }
    changed := false;
    if !gs.is_loaded {
        if go_is_leak_checker_root(gv) changed = go_cleanup_pointer_root_users(gv);
        else changed = go_cleanup_constant_global_users(gv);
        if !has_uses(gv) { gv_erase_from_parent(gv); changed = true; }
        return changed;
    }
    if gs.stored_type <= .INITIALIZER_STORED {
        if gs.ordering == 0 {
            glob(gv).is_const = true;
            changed = true;
        }
        changed |= go_cleanup_constant_global_users(gv);
        if !has_uses(gv) { gv_erase_from_parent(gv); return true; }
    }
    if !is_single_value_type(vtype(gv_initializer(gv))) {
        if go_sra_global(gv) return true;
    }
    sov := gs_stored_once_value(gs);
    if gs.stored_type == .STORED_ONCE && sov != NONE {
        can_have_non_undef_init := glob(gv).addrspace == 0;   // TTI::canHaveNonUndefGlobalInitializerInAddressSpace
        sov_const := is_const(sov);
        init := gv_initializer(gv);
        init_undef := vkind(init) == .C_UNDEF || vkind(init) == .C_POISON;
        if sov_const && init_undef && dl_type_alloc_size(vtype(sov)) == dl_type_alloc_size(glob(gv).value_type) && can_have_non_undef_init {
            if vtype(sov) == glob(gv).value_type {
                gv_set_initializer(gv, sov);
            } else {
                ngv := gv_create(vtype(sov), glob(gv).is_const, glob(gv).linkage, sov, "", gv, glob(gv).tls, glob(gv).addrspace);
                gv_take_name(ngv, gv);
                gv_copy_attributes_from(ngv, gv);
                ipo_rauw(gv, ngv);
                gv_erase_from_parent(gv);
                gv = ngv;
            }
            go_cleanup_constant_global_users(gv);
            if !has_uses(gv) gv_erase_from_parent(gv);
            return true;
        }
        if go_optimize_once_stored_global(gv, sov) return true;
        if gs.num_stores == 1 {
            if go_forward_stored_once_store(gv, gs.stored_once_store) return true;
        }
        if sov_const && gs.ordering == 0 && (!init_undef || can_have_non_undef_init) {
            if go_try_to_shrink_global_to_boolean(gv, sov) return true;
        }
    }
    return changed;
}

// processGlobal
go_process_global :: (gv: Value_Id) -> bool {
    if begins_with(vname(gv), "llvm.") return false;
    gs: Global_Status;
    if analyze_global(gv, *gs) return false;
    changed := false;
    if !gs.is_compared && !gv_has_global_unnamed_addr(gv) {
        nu: u8 = ifx gv_has_local_linkage(gv) then cast(u8) 2 else 1;
        if nu != glob(gv).unnamed_addr { glob(gv).unnamed_addr = nu; changed = true; }
    }
    if !gv_has_local_linkage(gv) return changed;
    if vkind(gv) != .GLOBAL_VAR return changed;
    if glob(gv).is_const || !glob(gv).has_init return changed;
    return go_process_internal_global(gv, *gs) || changed;
}

// ---------------------------------------------------------------- functions: calling conventions, attributes

// CC_C is in ic_calls.jai, CC_COLD in inline_cost.jai
CC_FAST :: 8;
CC_X86_THISCALL :: 70;

// ChangeCalleesToFastCall
go_change_callees_to_fast_call :: (f: Value_Id) {
    for u: go_users(f) if is_inst(u) && is_call_base(u) && call_callee(u) == f inst(u).cc = CC_FAST;
}

// StripAttr: remove A at the first index (function, return, params) that has it
go_strip_attr :: (l: u32, k: Attr_Kind) -> u32 {
    if l == 0 return l;
    r := ir.attr_lists[l];
    if attr_set_has(r.fn, k) return attr_list_get(attr_set_remove(r.fn, k), r.ret, r.params);
    if attr_set_has(r.ret, k) return attr_list_get(r.fn, attr_set_remove(r.ret, k), r.params);
    for p, i: r.params if attr_set_has(p, k) return attr_list_with_param(l, cast(u32) i, attr_set_remove(p, k));
    return l;
}
// RemoveAttribute
go_remove_attribute :: (f: Value_Id, k: Attr_Kind) {
    glob(f).attrs = go_strip_attr(glob(f).attrs, k);
    for u: go_users(f) {
        if !(is_inst(u) && is_call_base(u)) fatal("globalopt: RemoveAttribute: a use of the function that is not a call");
        inst(u).attrs = go_strip_attr(inst(u).attrs, k);
    }
}

go_call_tail_kind :: (c: Value_Id) -> u32 { return (inst(c).flags >> 16) & 3; }

// hasChangeableCCImpl
go_has_changeable_cc_impl :: (f: Value_Id) -> bool {
    cc := glob(f).cc;
    if cc != CC_C && cc != CC_X86_THISCALL return false;
    if func_vararg(glob(f).value_type) return false;
    for u: go_users(f) {
        if !(is_inst(u) && inst_op(u) == .CALL) continue;
        if go_call_tail_kind(u) == 2 return false;
    }
    for b: fn_blocks(f) if block_terminating_must_tail_call(b) != NONE return false;
    return !fn_has_address_taken(f);
}
go_has_changeable_cc :: (cache: *Table(Value_Id, bool), f: Value_Id) -> bool {
    found, v := table_find(cache, f);
    if found return v;
    r := go_has_changeable_cc_impl(f);
    table_set(cache, f, r);
    return r;
}

// hasMustTailCallers
go_has_must_tail_callers :: (f: Value_Id) -> bool {
    for u: go_users(f) {
        if !(is_inst(u) && is_call_base(u)) fatal("globalopt: hasMustTailCallers: a use of the function that is not a call");
        if inst_op(u) == .CALL && go_call_tail_kind(u) == 2 return true;
    }
    return false;
}
// hasInvokeCallers
go_has_invoke_callers :: (f: Value_Id) -> bool {
    for u: go_users(f) if is_inst(u) && inst_op(u) == .INVOKE return true;
    return false;
}

// RemovePreallocated
go_remove_preallocated :: (f: Value_Id) {
    go_remove_attribute(f, .Preallocated);
    calls := go_users(f);
    for cb: calls {
        if !(is_inst(cb) && is_call_base(cb)) continue;
        setup: Value_Id = NONE;
        new_cb: Value_Id = NONE;
        for k: 0..cast(s64) call_num_bundles(cb) - 1 {
            if call_bundle_tag(cb, cast(u32) k) != "preallocated" continue;
            bb, ee := call_bundle_range(cb, cast(u32) k);
            setup = op(cb, bb);
            // CallBase::Create(CB, OpBundles, CB->getIterator()): the copy is created with CB's name
            new_cb = ic_call_remove_bundle_at(cb, cast(u32) k);
            insert_at_position(new_cb, inst_block(cb), cb, false);
            if vname(cb).count set_name(new_cb, vname(cb));
            break;
        }
        if setup == NONE fatal("globalopt: preallocated call without a preallocated bundle");
        ipo_rauw(cb, new_cb);
        ic_take_name(new_cb, cb);
        erase_inst_with_metadata(cb);
        arg_count := const_int_zext(call_arg(setup, 0));
        b: Irb;
        irb_set_before(*b, setup);
        stack_save := irb_intrinsic(*b, "llvm.stacksave", .[type_ptr(dl.alloca_as)], .[]);
        set_name(stack_save, "");
        irb_set_before(*b, inst_next(new_cb));
        irb_intrinsic(*b, "llvm.stackrestore", .[type_ptr(dl.alloca_as)], .[stack_save]);
        arg_allocas := NewArray(cast(s64) arg_count, Value_Id,, allocator = temp);
        for * arg_allocas it.* = NONE;
        for use_call: go_users(setup) {
            idx := const_int_zext(call_arg(use_call, 1));
            rep := arg_allocas[idx];
            if rep == NONE {
                as := ir.types[vtype(use_call)].a;
                pa := call_get_fn_attr(use_call, .Preallocated);
                arg_ty := pa.ty;
                irb_set_before(*b, inst_next(setup));
                ai := new_inst(.ALLOCA, type_ptr(cast(u32) as), 1);
                set_op(ai, 0, const_int(type_int(32), 1));
                inst(ai).ty2 = arg_ty;
                inst(ai).align = dl_pref_align(arg_ty);
                inst(ai).addrspace = cast(u32) as;
                irb_insert(*b, ai, "paarg");
                arg_allocas[idx] = ai;
                rep = ai;
            }
            ipo_rauw(use_call, rep);
            erase_inst_with_metadata(use_call);
        }
        erase_inst_with_metadata(setup);
    }
}

// X86TTIImpl::useFastCCForInternalCall: every direct caller has the same EGPR feature (true without a target)
go_use_fast_cc_for_internal_call :: (f: Value_Id) -> bool {
    t := tti_get(f);
    if t.kind != .X86 return true;
    has := xs_has(*t.xl, X86F_FeatureEGPR);
    for u: go_users(f) {
        if !(is_inst(u) && is_call_base(u)) || call_callee(u) != f continue;
        tc := tti_get(inst_fn(u));
        if tc.kind != .X86 continue;
        if xs_has(*tc.xl, X86F_FeatureEGPR) != has return false;
    }
    return true;
}

// OptimizeFunctions
go_optimize_functions :: (go: *Global_Opt) -> bool {
    changed := false;
    cache: Table(Value_Id, bool); cache.allocator = temp;
    // hasOnlyColdCalls / AllCallsCold only matter when TTI::useColdCCForColdCall is true (never on X86)
    // make_early_inc_range(M): the next function is fixed before the body runs
    next_f: Value_Id = ifx ir.m_functions.count then ir.m_functions[0] else NONE;
    pos := 0;
    while next_f != NONE {
        f := next_f;
        pos = list_index_of_hint(ir.m_functions, f, pos);
        next_f = ifx pos + 1 < ir.m_functions.count then ir.m_functions[pos + 1] else NONE;
        if fn_has_fn_attr(f, .Naked) continue;
        if vname(f).count == 0 && !is_declaration(f) && !gv_has_local_linkage(f) gv_set_linkage(f, .INTERNAL);
        if go_delete_if_dead(go, f) { changed = true; continue; }
        if !is_declaration(f) {
            if remove_unreachable_blocks(f, null) {
                changed = true;
                fam_invalidate(f, PRESERVE_NONE);
            }
        }
        changed |= go_process_global(f);
        if !gv_has_local_linkage(f) continue;
        if !gv_is_definition_exact(f) continue;
        if fn_has_attr_somewhere(f, .InAlloca) && !fn_has_address_taken(f) && !go_has_must_tail_callers(f) && !func_vararg(glob(f).value_type) {
            go_remove_attribute(f, .InAlloca);
            changed = true;
        }
        if fn_has_attr_somewhere(f, .Preallocated) {
            if !fn_has_address_taken(f) && !go_has_must_tail_callers(f) && !go_has_invoke_callers(f) {
                go_remove_preallocated(f);
                changed = true;
            }
            continue;
        }
        if go_has_changeable_cc(*cache, f) {
            if go_opts.enable_coldcc_stress_test {
                table_remove(*cache, f);
                glob(f).cc = CC_COLD;
                for u: go_users(f) if is_inst(u) && is_call_base(u) && call_callee(u) == f inst(u).cc = CC_COLD;
                changed = true;
            }
        }
        if go_has_changeable_cc(*cache, f) {
            if go_use_fast_cc_for_internal_call(f) {
                glob(f).cc = CC_FAST;
                go_change_callees_to_fast_call(f);
                changed = true;
            }
        }
        if fn_has_attr_somewhere(f, .Nest) && !fn_has_address_taken(f) {
            go_remove_attribute(f, .Nest);
            changed = true;
        }
    }
    return changed;
}

// OptimizeGlobalVars
go_optimize_global_vars :: (go: *Global_Opt) -> bool {
    changed := false;
    i := 0;
    while i < ir.m_globals.count {
        gv := ir.m_globals[i];
        // make_early_inc_range: the next global is fixed before the body runs (new globals are inserted before gv)
        next := ifx i + 1 < ir.m_globals.count then ir.m_globals[i + 1] else NONE;
        if vname(gv).count == 0 && !is_declaration(gv) && !gv_has_local_linkage(gv) gv_set_linkage(gv, .INTERNAL);
        if glob(gv).has_init {
            c := gv_initializer(gv);
            nc := cfo_constant(c);
            if nc != c gv_set_initializer(gv, nc);
        }
        if go_delete_if_dead(go, gv) changed = true;
        else changed |= go_process_global(gv);
        if next == NONE break;
        i = list_index_of_hint(ir.m_globals, next, i);
    }
    return changed;
}

// EvaluateStaticConstructor
go_evaluate_static_constructor :: (f: Value_Id) -> bool {
    if is_declaration(f) return false;
    ev: Evaluator;
    ev_init(*ev);
    ok, ret := ev_evaluate_function(*ev, f, .[]);
    if ok {
        for gv: ev.mutated_order {
            found, mv := table_find(*ev.mutated, gv);
            gv_set_initializer(gv, ev_mv_to_constant(*ev, mv));
        }
        for ev.invariants glob(it).is_const = true;
    }
    ev_destroy(*ev);
    return ok;
}

// the ShouldRemove callback of optimizeGlobalsInModule's optimizeGlobalCtorsList call
go_ctor_should_remove :: (go: *Global_Opt, prio: u32, f: Value_Id) -> bool {
    if go.has_first_not_fully_evaluated_priority && go.first_not_fully_evaluated_priority != prio return false;
    evaluated := go_evaluate_static_constructor(f);
    if !evaluated { go.has_first_not_fully_evaluated_priority = true; go.first_not_fully_evaluated_priority = prio; }
    return evaluated;
}

// ---------------------------------------------------------------- aliases (LLVMUsed)

Go_Used :: struct {
    used: [..] Value_Id;
    compiler_used: [..] Value_Id;
    used_v: Value_Id;
    compiler_used_v: Value_Id;
}
go_set_erase :: (s: *[..] Value_Id, v: Value_Id) -> bool {
    for s.* if it == v { array_ordered_remove_by_index(s, it_index); return true; }
    return false;
}
go_set_count :: (s: [..] Value_Id, v: Value_Id) -> bool { for s if it == v return true; return false; }

// setUsedInitializer
go_set_used_initializer :: (v: Value_Id, init: [..] Value_Id) {
    if init.count == 0 { gv_erase_from_parent(v); return; }
    vat := glob(v).value_type;
    ptr_ty := type_ptr(cast(u32) ir.types[type_elem(vat)].a);
    arr: [..] Value_Id; arr.allocator = temp;
    for gv: init array_add(*arr, ce_pointer_bitcast_or_addrspacecast(gv, ptr_ty));
    // array_pod_sort by the stripped names
    for i: 1..arr.count-1 {
        x := arr[i]; j := i - 1;
        while j >= 0 && compare(vname(strip_pointer_casts(arr[j])), vname(strip_pointer_casts(x))) > 0 { arr[j + 1] = arr[j]; j -= 1; }
        arr[j + 1] = x;
    }
    aty := type_array(cast(u64) arr.count, ptr_ty);
    remove_from_list(*ir.m_globals, v);
    nv := gv_create(aty, false, .APPENDING, const_aggregate(.C_ARRAY, aty, arr), "", NONE, 0, glob(v).addrspace);
    gv_take_name(nv, v);
    glob(nv).section = "llvm.metadata";
    // delete V
    md_global_value_deleted(v);
    drop_all_references(v);
    ir.v_kind[v] = .DEAD;
}

// hasUseOtherThanLLVMUsed
go_has_use_other_than_llvm_used :: (ga: Value_Id, u: *Go_Used) -> bool {
    if !has_uses(ga) return false;
    if num_uses(ga) != 1 return true;
    return !go_set_count(u.used, ga) && !go_set_count(u.compiler_used, ga);
}
// mayHaveOtherReferences
go_may_have_other_references :: (gv: Value_Id, u: *Go_Used) -> bool {
    if !gv_has_local_linkage(gv) return true;
    return go_set_count(u.used, gv) || go_set_count(u.compiler_used, gv);
}
// hasUsesToReplace: (ret, rename_target)
go_has_uses_to_replace :: (ga: Value_Id, u: *Go_Used) -> bool, bool {
    if gv_is_weak_for_linker(ga) return false, false;
    ret := false;
    if go_has_use_other_than_llvm_used(ga, u) ret = true;
    if !go_may_have_other_references(ga, u) return ret, false;
    target := strip_pointer_casts(op(ga, 0));
    if go_may_have_other_references(target, u) return ret, false;
    return true, true;
}

// OptimizeGlobalAliases
go_optimize_global_aliases :: (go: *Global_Opt) -> bool {
    changed := false;
    used: Go_Used;
    used.used.allocator = temp; used.compiler_used.allocator = temp;
    {
        vec: [..] Value_Id; vec.allocator = temp;
        used.used_v = collect_used_global_variables(*vec, false);
        for vec if !go_set_count(used.used, it) array_add(*used.used, it);
        vec.count = 0;
        used.compiler_used_v = collect_used_global_variables(*vec, true);
        for vec if !go_set_count(used.compiler_used, it) array_add(*used.compiler_used, it);
    }
    for used.used go_set_erase(*used.compiler_used, it);

    is_module_local :: (gv: Value_Id) -> bool {
        return !linkage_is_interposable(glob(gv).linkage) && (glob(gv).dso_local || gv_is_implicit_dso_local(gv));
    }
    i := 0;
    while i < ir.m_aliases.count {
        j := ir.m_aliases[i];
        i += 1;
        if vname(j).count == 0 && !is_declaration(j) && !gv_has_local_linkage(j) gv_set_linkage(j, .INTERNAL);
        if go_delete_if_dead(go, j) { i -= 1; changed = true; continue; }
        if !is_module_local(j) continue;
        aliasee := op(j, 0);
        target := strip_pointer_casts(aliasee);
        if !is_global_value(vkind(target)) || !is_module_local(target) continue;
        remove_dead_constant_users(target);
        ok, rename_target := go_has_uses_to_replace(j, *used);
        if !ok continue;
        ipo_rauw(j, aliasee);
        changed = true;
        if rename_target {
            gv_take_name(target, j);
            gv_set_linkage(target, glob(j).linkage);
            glob(target).dso_local = glob(j).dso_local;
            gv_set_visibility(target, glob(j).visibility);
            glob(target).dll = glob(j).dll;
            if go_set_erase(*used.used, j) && !go_set_count(used.used, target) array_add(*used.used, target);
            if go_set_erase(*used.compiler_used, j) && !go_set_count(used.compiler_used, target) array_add(*used.compiler_used, target);
        } else if go_may_have_other_references(j, *used) continue;
        // M.eraseAlias(&J)
        i -= 1;
        gv_erase_from_parent(j);
        changed = true;
    }
    if used.used_v != NONE go_set_used_initializer(used.used_v, used.used);
    if used.compiler_used_v != NONE go_set_used_initializer(used.compiler_used_v, used.compiler_used);
    return changed;
}

// ---------------------------------------------------------------- atexit, ifuncs

// FindAtExitLibFunc
go_find_at_exit_lib_func :: (name: string) -> Value_Id {
    if ir.m_functions.count == 0 return NONE;
    ok, lf := tli_lookup_name(name);
    assert(ok);
    if !tli_func_has(tli_for(ir.m_functions[0]), lf) return NONE;
    fn := module_get_function(name);
    if fn == NONE return NONE;
    if !tli_func_has(tli_for(fn), lf) return NONE;
    if !tli_valid_proto_for(glob(fn).value_type, lf) return NONE;
    return fn;
}
// IsEmptyAtExitFunction
go_is_empty_at_exit_function :: (f: Value_Id) -> bool {
    if is_declaration(f) return false;
    for i: block_insts(fn_entry(f)) {
        if is_debug_or_pseudo_inst(i) continue;
        if inst_op(i) == .RET return true;
        break;
    }
    return false;
}
// OptimizeEmptyGlobalAtExitDtors
go_optimize_empty_global_at_exit_dtors :: (fn: Value_Id) -> bool {
    changed := false;
    for u: go_users(fn) {
        if vkind(u) == .DEAD || !(is_inst(u) && inst_op(u) == .CALL) continue;
        dtor := strip_pointer_casts(call_arg(u, 0));
        if vkind(dtor) != .FUNCTION || !go_is_empty_at_exit_function(dtor) continue;
        ipo_rauw(u, const_null_value(vtype(u)));
        erase_inst_with_metadata(u);
        changed = true;
    }
    return changed;
}

// GlobalIFunc::getResolverFunction
go_ifunc_resolver_function :: (gi: Value_Id) -> Value_Id {
    r := op(gi, 0);
    // stripPointerCastsAndAliases
    while true {
        r = strip_pointer_casts(r);
        if vkind(r) == .ALIAS { r = op(r, 0); continue; }
        break;
    }
    return ifx vkind(r) == .FUNCTION then r else NONE;
}
// hasSideeffectFreeStaticResolution
go_has_sideeffect_free_static_resolution :: (gi: Value_Id) -> Value_Id {
    if gv_is_interposable(gi) return NONE;
    resolver := go_ifunc_resolver_function(gi);
    if resolver == NONE return NONE;
    if gv_is_interposable(resolver) return NONE;
    if fn_num_blocks(resolver) != 1 return NONE;
    bb := fn_entry(resolver);
    for i: block_insts(bb) if may_have_side_effects(i) return NONE;
    ret := block_terminator(bb);
    if inst_op(ret) != .RET || nops(ret) == 0 return NONE;
    rv := op(ret, 0);
    return ifx vkind(rv) == .FUNCTION then rv else NONE;
}
// OptimizeStaticIFuncs
go_optimize_static_ifuncs :: () -> bool {
    changed := false;
    for gi: ir.m_ifuncs {
        callee := go_has_sideeffect_free_static_resolution(gi);
        if callee == NONE || !has_uses(gi) continue;
        any_alias := false;
        for u: go_users(gi) if vkind(u) == .ALIAS any_alias = true;
        if !is_declaration(callee) || !any_alias {
            ipo_rauw(gi, callee);
            changed = true;
        }
    }
    return changed;
}
// DeleteDeadIFuncs
go_delete_dead_ifuncs :: (go: *Global_Opt) -> bool {
    changed := false;
    i := 0;
    while i < ir.m_ifuncs.count {
        gi := ir.m_ifuncs[i];
        i += 1;
        if go_delete_if_dead(go, gi) { i -= 1; changed = true; }
    }
    return changed;
}

// ---------------------------------------------------------------- driver

// optimizeGlobalsInModule
go_optimize_globals_in_module :: () -> bool {
    go: Global_Opt;
    go.not_discardable_comdats.allocator = temp;
    changed := false;
    local_change := true;
    while local_change {
        local_change = false;
        table_reset(*go.not_discardable_comdats);
        for gv: ir.m_globals {
            c := gv_comdat(gv);
            if c >= 0 && (!gv_is_discardable_if_unused(gv) || has_uses(gv)) table_set(*go.not_discardable_comdats, c, true);
        }
        for f: ir.m_functions {
            c := gv_comdat(f);
            if c >= 0 && !fn_is_def_trivially_dead(f) table_set(*go.not_discardable_comdats, c, true);
        }
        for ga: ir.m_aliases {
            c := gv_comdat(ga);
            if c >= 0 && (!gv_is_discardable_if_unused(ga) || has_uses(ga)) table_set(*go.not_discardable_comdats, c, true);
        }
        local_change |= go_optimize_functions(*go);
        local_change |= optimize_global_ctors_list(.GLOBALOPT_EVALUATE, *go);
        local_change |= go_optimize_global_vars(*go);
        local_change |= go_optimize_global_aliases(*go);
        cxa := go_find_at_exit_lib_func("__cxa_atexit");
        if cxa != NONE local_change |= go_optimize_empty_global_at_exit_dtors(cxa);
        ae := go_find_at_exit_lib_func("atexit");
        if ae != NONE local_change |= go_optimize_empty_global_at_exit_dtors(ae);
        local_change |= go_optimize_static_ifuncs();
        // OptimizeNonTrivialIFuncs: no function is multiversioned without an AArch64 TTI
        local_change |= go_delete_dead_ifuncs(*go);
        changed |= local_change;
    }
    return changed;
}

global_opt_run :: () -> Preserved {
    if !go_optimize_globals_in_module() return PRESERVE_ALL;
    printer_note_ir_changed();
    pa := preserved_cfg();   // FunctionAnalysisManagerModuleProxy and CFG analyses
    return pa;
}

globals_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    parse_bool :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("invalid boolean value '%' for option -%", value, name);
        return false;
    }
    parse_int :: (name: string, value: string, has_value: bool) -> s64 {
        if !has_value fatal("option -% needs a value", name);
        v, ok := string_to_int(value);
        if !ok fatal("invalid integer value '%' for option -%", value, name);
        return v;
    }
    if name == "enable-coldcc-stress-test" { go_opts.enable_coldcc_stress_test = parse_bool(name, value, has_value); return true; }
    if name == "coldcc-rel-freq" { go_opts.coldcc_rel_freq = parse_int(name, value, has_value); return true; }
    if name == "optimize-non-fmv-callers" { go_opts.optimize_non_fmv_callers = parse_bool(name, value, has_value); return true; }
    if name == "max-ifunc-versions" { go_opts.max_ifunc_versions = parse_int(name, value, has_value); return true; }
    if name == "enable-vfe" { gdce_opts.enable_vfe = parse_bool(name, value, has_value); return true; }
    if name == "avail-extern-to-local" { eae_opts.convert_to_local = parse_bool(name, value, has_value); return true; }
    if name == "avail-extern-gv-in-addrspace-to-local" { eae_opts.gv_in_addrspace_to_local = parse_int(name, value, has_value); return true; }
    if internalize_parse_cl_opt(name, value, has_value) return true;
    return false;
}
