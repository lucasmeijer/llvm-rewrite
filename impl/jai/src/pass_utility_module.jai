// More utility passes (L1.extra.utility):
//   reg2mem             llvm/lib/Transforms/Scalar/Reg2Mem.cpp (complete), with DemoteRegToStack /
//                       DemotePHIToStack (llvm/lib/Transforms/Utils/DemoteRegToStack.cpp)
//   lower-global-dtors  llvm/lib/Transforms/Utils/LowerGlobalDtors.cpp (complete)
//   lower-ifunc         llvm/lib/Transforms/Utils/LowerIFunc.cpp (complete), with
//                       lowerGlobalIFuncUsersAsGlobalCtor (llvm/lib/Transforms/Utils/ModuleUtils.cpp)
//   fatlto-cleanup      llvm/lib/Transforms/IPO/FatLTOCleanup.cpp (complete)
//   hipstdpar-*         llvm/lib/Transforms/HipStdPar/HipStdPar.cpp (interpose-alloc, math-fixup)
//   ctx-prof-flatten    llvm/lib/Transforms/Instrumentation/PGOCtxProfFlattening.cpp (without a contextual profile)

// ---------------------------------------------------------------- reg2mem

r2m_new_alloca :: (ty: Type_Id, name: string, before: Value_Id, head := false) -> Value_Id {
    a := create_alloca_unlinked(ty, dl.alloca_as, dl_pref_align(ty));   // computeAllocaDefaultAlign
    insert_at_position(a, inst_block(before), before, head);   // InsertPosition = an instruction: adopts its records
    if name.count set_name(a, name);
    return a;
}
r2m_new_load :: (ty: Type_Id, ptr: Value_Id, name: string, pos: Value_Id, head := false, bb: Value_Id = NONE, volatile := false) -> Value_Id {
    l := new_inst(.LOAD, ty, 1);
    set_op(l, 0, ptr);
    if volatile inst(l).flags |= F_VOLATILE;
    inst(l).align = dl_alignment(ty, true);   // computeLoadStoreDefaultAlign
    insert_at_position(l, ifx bb != NONE then bb else inst_block(pos), pos, head);
    set_name(l, name);
    return l;
}
r2m_new_store :: (v: Value_Id, ptr: Value_Id, bb: Value_Id, pos: Value_Id, head: bool) -> Value_Id {
    s := new_inst(.STORE, ir.t_void, 2);
    set_op(s, 0, v); set_op(s, 1, ptr);
    inst(s).align = dl_alignment(vtype(v), true);
    insert_at_position(s, bb, pos, head);
    return s;
}

// DemoteRegToStack(I, VolatileLoads, AllocaPoint); alloca_head: AllocaPoint is an iterator with the head bit
// (no AllocaPoint: F->getEntryBlock().begin())
demote_reg_to_stack :: (i: Value_Id, alloca_point: Value_Id, volatile_loads := false, alloca_head := false) -> Value_Id {
    if !has_uses(i) { erase_inst_with_metadata(i); return NONE; }
    slot := r2m_new_alloca(vtype(i), tconcat(vname(i), ".reg2mem"), alloca_point, alloca_head);
    o: Crit_Edge_Options;
    if inst_op(i) == .INVOKE {
        nd := get_successor(i, 0);
        if block_single_predecessor(nd) == NONE {
            // GetSuccessorNumber(II->getParent(), II->getNormalDest())
            sn: u32 = 0;
            while get_successor(i, sn) != nd sn += 1;
            split_critical_edge(i, sn, *o);
        }
    } else if inst_op(i) == .CALLBR {
        n := num_successors(i);
        for k: 0..n - 1 {
            s := get_successor(i, k);
            if block_single_predecessor(s) == NONE split_critical_edge(i, k, *o);
        }
    }
    reload := tconcat(vname(i), ".reload");
    while has_uses(i) {
        u := ir.v_first_use[i];   // user_back()
        user := ir.u_user[u];
        if inst_op(user) == .PHI {
            Ld :: struct { bb: Value_Id; v: Value_Id; }
            loads: [..] Ld; loads.allocator = temp;
            n := nops(user);
            for k: 0..n - 1 {
                if phi_value(user, k) != i continue;
                pb := phi_block(user, k);
                v: Value_Id = NONE;
                for loads if it.bb == pb { v = it.v; break; }
                if v == NONE {
                    v = r2m_new_load(vtype(i), slot, reload, block_terminator(pb), volatile = volatile_loads);
                    array_add(*loads, .{pb, v});
                }
                phi_set_value(user, k, v);
            }
        } else {
            v := r2m_new_load(vtype(i), slot, reload, user, volatile = volatile_loads);
            replace_uses_of_with(user, i, v);
        }
    }
    if !is_terminator(inst_op(i)) {
        pt := inst_next(i);
        while pt != NONE && (inst_op(pt) == .PHI || is_eh_pad(pt)) {
            if inst_op(pt) == .CATCHSWITCH break;
            pt = inst_next(pt);
        }
        if pt != NONE && inst_op(pt) == .CATCHSWITCH {
            n := num_successors(pt);
            for k: 0..n - 1 {
                h := get_successor(pt, k);
                r2m_new_store(i, slot, h, block_first_insertion_pt(h), true);
            }
            return slot;
        }
        r2m_new_store(i, slot, inst_block(i), pt, false);
    } else if inst_op(i) == .INVOKE {
        nd := get_successor(i, 0);
        r2m_new_store(i, slot, nd, block_first_insertion_pt(nd), true);
    } else if inst_op(i) == .CALLBR {
        n := num_successors(i);
        for k: 0..n - 1 {
            s := get_successor(i, k);
            r2m_new_store(i, slot, s, block_first_insertion_pt(s), true);
        }
    } else {
        fatal("Unsupported terminator for Reg2Mem");
    }
    return slot;
}

// DemotePHIToStack(P, AllocaPoint); alloca_head as for demote_reg_to_stack
demote_phi_to_stack :: (p: Value_Id, alloca_point: Value_Id, alloca_head := false) -> Value_Id {
    if !has_uses(p) { erase_inst_with_metadata(p); return NONE; }
    slot := r2m_new_alloca(vtype(p), tconcat(vname(p), ".reg2mem"), alloca_point, alloca_head);
    n := nops(p);
    for k: 0..n - 1 {
        pb := phi_block(p, k);
        t := block_terminator(pb);
        r2m_new_store(phi_value(p, k), slot, pb, t, false);
    }
    pt := p;
    while pt != NONE && (inst_op(pt) == .PHI || is_eh_pad(pt)) {
        if inst_op(pt) == .CATCHSWITCH break;
        pt = inst_next(pt);
    }
    reload := tconcat(vname(p), ".reload");
    if pt != NONE && inst_op(pt) == .CATCHSWITCH {
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[p];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for usr: users {
            v := r2m_new_load(vtype(p), slot, reload, usr);
            replace_uses_of_with(usr, p, v);
        }
    } else {
        v := r2m_new_load(vtype(p), slot, reload, pt, false, inst_block(p));
        rauw_with_metadata(p, v);
    }
    erase_inst_with_metadata(p);
    return slot;
}

// valueEscapes
r2m_value_escapes :: (i: Value_Id) -> bool {
    if !type_is_sized(vtype(i)) return false;
    bb := inst_block(i);
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if inst_block(user) != bb || inst_op(user) == .PHI return true;
        u = ir.u_next[u];
    }
    return false;
}

reg2mem_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    li := get_loop_info(f);
    o: Crit_Edge_Options;
    o.dt = dt; o.li = li;
    n := split_all_critical_edges(f, *o);
    // runPass
    entry := fn_entry(f);
    i := block_first(entry);
    skipped := false;
    while i != NONE && inst_op(i) == .ALLOCA { i = inst_next(i); skipped = true; }
    point := new_inst(.BITCAST, ir.t_i32, 1);
    set_op(point, 0, const_int(ir.t_i32, 0));
    insert_at_position(point, entry, i, !skipped);   // begin() has the head bit, ++ drops it
    set_name(point, "reg2mem alloca point");
    work: [..] Value_Id; work.allocator = temp;
    for x: fn_insts(f) {
        if inst_op(x) == .ALLOCA && inst_block(x) == entry continue;
        if r2m_value_escapes(x) array_add(*work, x);
    }
    for < work demote_reg_to_stack(it, point);   // std::list push_front
    work.count = 0;
    for bb: fn_blocks(f) for x: block_insts(bb) { if inst_op(x) != .PHI break; array_add(*work, x); }
    for < work demote_phi_to_stack(it, point);
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    return pa;
}

// ---------------------------------------------------------------- lower-global-dtors

lower_global_dtors_run :: () -> Preserved {
    gv := module_get_global_variable("llvm.global_dtors", true);
    if gv == NONE || !glob(gv).has_init return PRESERVE_ALL;
    init := op(gv, 0);
    if vkind(init) != .C_ARRAY return PRESERVE_ALL;
    ety := type_elem(vtype(init));
    if type_kind(ety) != .STRUCT || type_nsub(ety) != 3 || !is_int_type(type_sub(ety, 0)) ||
       type_kind(type_sub(ety, 1)) != .PTR || type_kind(type_sub(ety, 2)) != .PTR return PRESERVE_ALL;
    // std::map<uint16_t, vector<pair<Associated, vector<Dtor>>>>: ordered by priority
    Group :: struct { assoc: Value_Id; dtors: [..] Value_Id; }
    Prio :: struct { prio: u16; groups: [..] Group; }
    dtor_funcs: [..] Prio; dtor_funcs.allocator = temp;
    for k: 0..cast(s64) nops(init) - 1 {
        cs := op(init, cast(u32) k);
        if vkind(cs) != .C_STRUCT continue;
        pr := op(cs, 0);
        if vkind(pr) != .C_INT continue;
        pv := cast(u16) ap_limited(const_ap(pr), 0xFFFF);
        dtor := op(cs, 1);
        if is_null_value(dtor) break;
        assoc := strip_pointer_casts(op(cs, 2));
        p: *Prio = null;
        for * dtor_funcs if it.prio == pv { p = it; break; }
        if !p {
            np: Prio; np.prio = pv; np.groups.allocator = temp;
            // insert sorted
            pos := dtor_funcs.count;
            for dtor_funcs if it.prio > pv { pos = it_index; break; }
            array_insert_at(*dtor_funcs, np, pos);
            p = *dtor_funcs[pos];
        }
        if p.groups.count == 0 || p.groups[p.groups.count - 1].assoc != assoc {
            g: Group; g.assoc = assoc; g.dtors.allocator = temp;
            array_add(*g.dtors, dtor);
            array_add(*p.groups, g);
        } else {
            array_add(*p.groups[p.groups.count - 1].dtors, dtor);
        }
    }
    if dtor_funcs.count == 0 return PRESERVE_ALL;
    void_star := type_ptr(0);
    atexit_fn_ty := type_func(ir.t_void, .[void_star], false);
    atexit := san_get_or_insert_function("__cxa_atexit", type_func(ir.t_i32, .[type_ptr(0), void_star, void_star], false));
    if vkind(atexit) == .FUNCTION && !is_declaration(atexit) && gv_has_exact_definition(atexit) && !has_uses(fn_arg(atexit, 0)) {
        gv_erase_from_parent(gv);
        printer_note_ir_changed();
        return preserved_cfg();
    }
    dso := lookup_global("__dso_handle");
    if dso == NONE || vkind(dso) != .GLOBAL_VAR {
        dso = gv_create(ir.t_i8, true, .EXTERN_WEAK, NONE, "__dso_handle", NONE, 0, dl.globals_as);
        glob(dso).visibility = 1;   // HiddenVisibility
    }
    void_void := type_func(ir.t_void, .[], false);
    for * pm: dtor_funcs {
        prio := pm.prio;
        id: u64 = 0;
        for * am: pm.groups {
            this_id := id; id += 1;
            suffix := "";
            if prio != 0xFFFF suffix = tconcat(suffix, ".", tdec(prio));
            if pm.groups.count > 1 suffix = tconcat(suffix, "$", tdec(this_id));
            if !is_null_value(am.assoc) suffix = tconcat(suffix, ".", vname(am.assoc));
            call_dtors := new_function(atexit_fn_ty, tconcat("call_dtors", suffix), dl.program_as);
            glob(call_dtors).linkage = .PRIVATE;
            array_add(*ir.m_functions, call_dtors);
            bb := create_block(call_dtors, "body");
            for < am.dtors {
                c := new_inst(.CALL, ir.t_void, 1);
                inst(c).ty2 = void_void;
                set_op(c, 0, it);
                block_append_inst(bb, c);
            }
            block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
            reg := new_function(void_void, tconcat("register_call_dtors", suffix), dl.program_as);
            glob(reg).linkage = .PRIVATE;
            array_add(*ir.m_functions, reg);
            entry_bb := create_block(reg, "entry");
            fail_bb := create_block(reg, "fail");
            ret_bb := create_block(reg, "return");
            nullp := const_null_value(void_star);
            call := new_inst(.CALL, ir.t_i32, 4);
            inst(call).ty2 = glob(atexit).value_type;
            set_op(call, 0, call_dtors); set_op(call, 1, nullp); set_op(call, 2, dso); set_op(call, 3, atexit);
            insert_at_end_named(call, entry_bb, "call");
            cmp := create_icmp(ICMP_NE, call, const_null_value(ir.t_i32));
            block_append_inst(entry_bb, cmp);
            block_append_inst(entry_bb, create_cond_br(cmp, fail_bb, ret_bb));
            trap := get_or_insert_intrinsic_declaration(IID_TRAP);
            tc := new_inst(.CALL, ir.t_void, 1);
            inst(tc).ty2 = glob(trap).value_type;
            set_op(tc, 0, trap);
            block_append_inst(fail_bb, tc);
            block_append_inst(fail_bb, new_inst(.UNREACHABLE, ir.t_void, 0));
            block_append_inst(ret_bb, new_inst(.RET, ir.t_void, 0));
            append_to_global_ctors(reg, prio, am.assoc);
        }
    }
    gv_erase_from_parent(gv);
    printer_note_ir_changed();
    return preserved_cfg();
}

// ---------------------------------------------------------------- lower-ifunc

lower_ifunc_run :: () -> Preserved {
    if ir.m_ifuncs.count == 0 return PRESERVE_ALL;
    ifuncs: [..] Value_Id; ifuncs.allocator = temp;
    for ir.m_ifuncs array_add(*ifuncs, it);
    entry_ty := type_ptr(dl.program_as);
    table_ty := type_array(cast(u64) ifuncs.count, entry_ty);
    ptr_align := dl_alignment(entry_ty, true);
    table := gv_create(table_ty, false, .INTERNAL, const_poison(table_ty), "", NONE, 0, dl.globals_as);
    glob(table).align = ptr_align;
    ctor := new_function(type_func(ir.t_void, .[], false), "", dl.program_as);
    glob(ctor).linkage = .INTERNAL;
    array_add(*ir.m_functions, ctor);
    bb := create_block(ctor, "");
    ib: Irb; irb_set_end(*ib, bb);
    table_index: u64 = 0;
    for gi: ifuncs {
        // getResolverFunction: stripPointerCastsAndAliases
        resolver := strip_pointer_casts(op(gi, 0));
        while vkind(resolver) == .ALIAS resolver = strip_pointer_casts(op(resolver, 0));
        if vkind(resolver) != .FUNCTION fatal("lower-ifunc: an ifunc resolver that is not a function is not supported");
        if func_nparams(glob(resolver).value_type) != 0 continue;
        rf := irb_call(*ib, resolver, .[]);
        casted := irb_pointer_bitcast_or_addrspacecast(*ib, rf, entry_ty);
        gep := ce_gep(table_ty, table, .[const_int(ir.t_i32, 0), const_int(ir.t_i32, table_index)], F_INBOUNDS);
        table_index += 1;
        irb_store(*ib, casted, gep, ptr_align);
        u := ir.v_first_use[gi];
        while u != NONE {
            nx := ir.u_next[u];
            user := ir.u_user[u];
            u = nx;
            if !is_inst(user) continue;
            ub: Irb; irb_set_before(*ub, user);
            t := irb_load(*ub, entry_ty, gep, ptr_align);
            c := irb_pointer_bitcast_or_addrspacecast(*ub, t, vtype(gi));
            replace_uses_of_with(user, gi, c);
            // make_early_inc_range(GI->users()): the next use was read before the body; if the body moved it to
            // the cast's use list (a user with two uses of the ifunc), the walk continues there, like LLVM's
        }
        if !has_uses(gi) gv_erase_from_parent(gi);
    }
    irb_insert(*ib, new_inst(.RET, ir.t_void, 0));
    append_to_global_ctors(ctor, 10, const_null_value(type_ptr(0)));
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- fatlto-cleanup
// llvm/lib/Transforms/IPO/FatLTOCleanup.cpp (complete)

IID_TYPE_CHECKED_LOAD :: #run iid_by_name("llvm.type.checked.load");
IID_TYPE_CHECKED_LOAD_RELATIVE :: #run iid_by_name("llvm.type.checked.load.relative");

fatlto_clean_up_type_checked_load :: (fn: Value_Id, is_relative: bool) -> bool {
    changed := false;
    u := ir.v_first_use[fn];
    while u != NONE {
        nx := ir.u_next[u];   // make_early_inc_range(users())
        defer u = nx;
        i := ir.u_user[u];
        if !is_inst(i) continue;
        b: Irb; irb_set_before(*b, i);
        ptr := op(i, 0);
        off := op(i, 1);
        ptr_ty := type_sub(vtype(i), 0);
        load: Value_Id;
        if is_relative {
            // CreateIntrinsicWithoutFolding(load_relative, {Offset type}, {Ptr, Offset}, nullptr, "rel_load")
            lf := get_or_insert_intrinsic_declaration(IID_LOAD_RELATIVE, .[vtype(off)]);
            load = irb_call(*b, lf, .[ptr, off], "rel_load");
        } else {
            pa := irb_gep(*b, ir.t_i8, ptr, .[off]);   // CreatePtrAdd
            load = irb_load(*b, ptr_ty, pa, dl_alignment(ptr_ty, true), false, "vfunc");
        }
        r := const_poison(vtype(i));
        r = irb_insert_value(*b, r, const_int(ir.t_i1, 1), .[1]);
        r = irb_insert_value(*b, r, load, .[0]);
        rauw_with_metadata(i, r);
        erase_inst_with_metadata(i);
        changed = true;
    }
    if changed gv_erase_from_parent(fn);
    return changed;
}

fatlto_cleanup_run :: () -> Preserved {
    a := intrinsic_declaration_if_exists(IID_TYPE_CHECKED_LOAD);
    r := intrinsic_declaration_if_exists(IID_TYPE_CHECKED_LOAD_RELATIVE);
    changed := false;
    if a != NONE changed |= fatlto_clean_up_type_checked_load(a, false);
    if r != NONE changed |= fatlto_clean_up_type_checked_load(r, true);
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- hipstdpar-interpose-alloc, hipstdpar-math-fixup
// llvm/lib/Transforms/HipStdPar/HipStdPar.cpp (HipStdParAllocationInterpositionPass, HipStdParMathFixupPass;
// not HipStdParAcceleratorCodeSelectionPass)

HSP_REPLACE_MAP :: [2] string.[
    .["aligned_alloc", "__hipstdpar_aligned_alloc"], .["calloc", "__hipstdpar_calloc"], .["free", "__hipstdpar_free"],
    .["malloc", "__hipstdpar_malloc"], .["memalign", "__hipstdpar_aligned_alloc"], .["mmap", "__hipstdpar_mmap"],
    .["munmap", "__hipstdpar_munmap"], .["posix_memalign", "__hipstdpar_posix_aligned_alloc"],
    .["realloc", "__hipstdpar_realloc"], .["reallocarray", "__hipstdpar_realloc_array"],
    .["_ZdaPv", "__hipstdpar_operator_delete"], .["_ZdaPvm", "__hipstdpar_operator_delete_sized"],
    .["_ZdaPvSt11align_val_t", "__hipstdpar_operator_delete_aligned"],
    .["_ZdaPvmSt11align_val_t", "__hipstdpar_operator_delete_aligned_sized"],
    .["_ZdlPv", "__hipstdpar_operator_delete"], .["_ZdlPvm", "__hipstdpar_operator_delete_sized"],
    .["_ZdlPvSt11align_val_t", "__hipstdpar_operator_delete_aligned"],
    .["_ZdlPvmSt11align_val_t", "__hipstdpar_operator_delete_aligned_sized"],
    .["_Znam", "__hipstdpar_operator_new"], .["_ZnamRKSt9nothrow_t", "__hipstdpar_operator_new_nothrow"],
    .["_ZnamSt11align_val_t", "__hipstdpar_operator_new_aligned"],
    .["_ZnamSt11align_val_tRKSt9nothrow_t", "__hipstdpar_operator_new_aligned_nothrow"],
    .["_Znwm", "__hipstdpar_operator_new"], .["_ZnwmRKSt9nothrow_t", "__hipstdpar_operator_new_nothrow"],
    .["_ZnwmSt11align_val_t", "__hipstdpar_operator_new_aligned"],
    .["_ZnwmSt11align_val_tRKSt9nothrow_t", "__hipstdpar_operator_new_aligned_nothrow"],
    .["__builtin_calloc", "__hipstdpar_calloc"], .["__builtin_free", "__hipstdpar_free"],
    .["__builtin_malloc", "__hipstdpar_malloc"], .["__builtin_operator_delete", "__hipstdpar_operator_delete"],
    .["__builtin_operator_new", "__hipstdpar_operator_new"], .["__builtin_realloc", "__hipstdpar_realloc"],
    .["__libc_calloc", "__hipstdpar_calloc"], .["__libc_free", "__hipstdpar_free"],
    .["__libc_malloc", "__hipstdpar_malloc"], .["__libc_memalign", "__hipstdpar_aligned_alloc"],
    .["__libc_realloc", "__hipstdpar_realloc"],
];
HSP_HIDDEN_MAP :: [2] string.[
    .["__hipstdpar_hidden_malloc", "__libc_malloc"], .["__hipstdpar_hidden_free", "__libc_free"],
    .["__hipstdpar_hidden_memalign", "__libc_memalign"], .["__hipstdpar_hidden_mmap", "mmap"],
    .["__hipstdpar_hidden_munmap", "munmap"],
];
HSP_MATH_MAP :: [2] string.[
    .["acosh", "__hipstdpar_acosh_f64"], .["acoshf", "__hipstdpar_acosh_f32"], .["asinh", "__hipstdpar_asinh_f64"],
    .["asinhf", "__hipstdpar_asinh_f32"], .["atanh", "__hipstdpar_atanh_f64"], .["atanhf", "__hipstdpar_atanh_f32"],
    .["cbrt", "__hipstdpar_cbrt_f64"], .["cbrtf", "__hipstdpar_cbrt_f32"], .["erf", "__hipstdpar_erf_f64"],
    .["erff", "__hipstdpar_erf_f32"], .["erfc", "__hipstdpar_erfc_f64"], .["erfcf", "__hipstdpar_erfc_f32"],
    .["fdim", "__hipstdpar_fdim_f64"], .["fdimf", "__hipstdpar_fdim_f32"], .["expm1", "__hipstdpar_expm1_f64"],
    .["expm1f", "__hipstdpar_expm1_f32"], .["hypot", "__hipstdpar_hypot_f64"], .["hypotf", "__hipstdpar_hypot_f32"],
    .["ilogb", "__hipstdpar_ilogb_f64"], .["ilogbf", "__hipstdpar_ilogb_f32"], .["lgamma", "__hipstdpar_lgamma_f64"],
    .["lgammaf", "__hipstdpar_lgamma_f32"], .["log1p", "__hipstdpar_log1p_f64"], .["log1pf", "__hipstdpar_log1p_f32"],
    .["logb", "__hipstdpar_logb_f64"], .["logbf", "__hipstdpar_logb_f32"], .["nextafter", "__hipstdpar_nextafter_f64"],
    .["nextafterf", "__hipstdpar_nextafter_f32"], .["nexttoward", "__hipstdpar_nexttoward_f64"],
    .["nexttowardf", "__hipstdpar_nexttoward_f32"], .["remainder", "__hipstdpar_remainder_f64"],
    .["remainderf", "__hipstdpar_remainder_f32"], .["remquo", "__hipstdpar_remquo_f64"],
    .["remquof", "__hipstdpar_remquo_f32"], .["scalbln", "__hipstdpar_scalbln_f64"],
    .["scalblnf", "__hipstdpar_scalbln_f32"], .["scalbn", "__hipstdpar_scalbn_f64"],
    .["scalbnf", "__hipstdpar_scalbn_f32"], .["tgamma", "__hipstdpar_tgamma_f64"],
    .["tgammaf", "__hipstdpar_tgamma_f32"],
];

// Module::getOrInsertFunction(Name, Ty, Attrs): an existing global of that name, else a new declaration
hsp_get_or_insert_function :: (name: string, ty: Type_Id, attrs: u32) -> Value_Id {
    g := lookup_global(name);
    if g != NONE return g;
    f := new_function(ty, name, dl.program_as);
    array_add(*ir.m_functions, f);
    if glob(f).intrinsic set_intrinsic_attributes(f, function_intrinsic_id(f));
    else glob(f).attrs = attrs;
    return f;
}
hsp_erase_from_module :: (g: Value_Id) {
    rauw_with_metadata(g, const_poison(vtype(g)));
    gv_erase_from_parent(g);
}

hipstdpar_interpose_alloc_run :: () -> Preserved {
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        name := vname(f);
        if name.count == 0 continue;
        repl := "";
        for HSP_REPLACE_MAP if it[0] == name { repl = it[1]; break; }
        if repl.count == 0 continue;
        r := lookup_global(repl);
        if r != NONE && vkind(r) == .FUNCTION {
            rauw_with_metadata(f, r);
        } else {
            print_stderr("warning: %: cannot be interposed, missing: %. Tried to run the allocation interposition pass without the replacement functions available.\n", name, repl);
        }
    }
    for hr: HSP_HIDDEN_MAP {
        f := lookup_global(hr[0]);
        if f == NONE || vkind(f) != .FUNCTION continue;
        r := hsp_get_or_insert_function(hr[1], glob(f).value_type, glob(f).attrs);
        rauw_with_metadata(f, r);
        hsp_erase_from_module(f);
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

Hsp_Rep :: struct { f: Value_Id; name: string; }
// ToReplace.emplace_back(&F, N); replace '.' with '_'; string::replace(0, 4, "__hipstdpar")
hsp_add_llvm_renamed :: (to_replace: *[..] Hsp_Rep, f: Value_Id, n: string) {
    nn := copy_string(n,, allocator = temp);
    for i: 0..nn.count - 1 if nn[i] == #char "." nn[i] = #char "_";
    k := min(4, nn.count);
    array_add(to_replace, .{f, tconcat("__hipstdpar", slice(nn, k, nn.count - k))});
}

hipstdpar_math_fixup_run :: () -> Preserved {
    if ir.m_functions.count == 0 return PRESERVE_ALL;
    Rep :: Hsp_Rep;
    to_replace: [..] Rep; to_replace.allocator = temp;
    for f: ir.m_functions {
        n := vname(f);
        if n.count == 0 continue;
        id := ifx glob(f).intrinsic then fn_iid(f) else NOT_INTRINSIC;
        if id == NOT_INTRINSIC {
            repl := "";
            for HSP_MATH_MAP if it[0] == n { repl = it[1]; break; }
            if repl.count == 0 continue;
            array_add(*to_replace, .{f, repl});
            // `break` leaves only the switch: the name is also pushed with "llvm" (its first 4 characters)
            // replaced, e.g. remainder -> __hipstdparinder, erf -> __hipstdpar
            hsp_add_llvm_renamed(*to_replace, f, n);
            continue;
        }
        if id == IID_ACOS || id == IID_ASIN || id == IID_ATAN || id == IID_ATAN2 || id == IID_COSH || id == IID_MODF ||
           id == IID_SINH || id == IID_TAN || id == IID_TANH {
        } else {
            if type_kind(func_ret(glob(f).value_type)) != .DOUBLE continue;
            if !(id == IID_COS || id == IID_EXP || id == IID_EXP2 || id == IID_LOG || id == IID_LOG10 || id == IID_LOG2 ||
                 id == IID_POW || id == IID_SIN) continue;
        }
        hsp_add_llvm_renamed(*to_replace, f, n);
    }
    for to_replace {
        r := hsp_get_or_insert_function(it.name, glob(it.f).value_type, 0);
        rauw_with_metadata(it.f, r);
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- ctx-prof-flatten
// PGOCtxProfFlatteningPass (llvm/lib/Transforms/Instrumentation/PGOCtxProfFlattening.cpp) without a contextual
// profile (-use-ctx-profile is not supported, so CtxProfAnalysis is always empty): the module is not the
// specialized one, and the pass only removes the instrumentation (removeInstrumentation on scope exit).
ctx_prof_flatten_run :: () -> Preserved {
    for f: ir.m_functions {
        if is_declaration(f) continue;
        for bb: fn_blocks(f) {
            i := block_first(bb);
            while i != NONE {
                nx := inst(i).next;
                if inst_op(i) == .CALL {
                    callee := call_called_function(i);
                    // InstrProfCntrInstBase::classof (isCounterBase)
                    if callee != NONE && glob(callee).intrinsic {
                        n := intrinsic_lookup(vname(callee));
                        if n == "llvm.instrprof.cover" || n == "llvm.instrprof.increment" || n == "llvm.instrprof.increment.step" ||
                           n == "llvm.instrprof.callsite" || n == "llvm.instrprof.timestamp" || n == "llvm.instrprof.value.profile"
                            erase_inst(i);
                    }
                }
                i = nx;
            }
        }
    }
    return PRESERVE_NONE;
}
