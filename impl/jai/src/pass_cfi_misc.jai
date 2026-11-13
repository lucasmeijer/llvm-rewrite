// CrossDSOCFIPass, GlobalSplitPass and SimplifyTypeTestsPass.
// Ported from llvm/lib/Transforms/IPO/CrossDSOCFI.cpp, llvm/lib/Transforms/IPO/GlobalSplit.cpp and the
// SimplifyTypeTestsPass of llvm/lib/Transforms/IPO/LowerTypeTests.cpp (pass_lower_type_tests.jai has the rest).

// ---------------------------------------------------------------- CrossDSOCFI

// extractNumericTypeId: an i64 ConstantInt type id, NONE otherwise (vtables in anonymous namespaces)
cdc_extract_numeric_type_id :: (md: Md_Id) -> Value_Id {
    if ir.mds[md].kind != .TUPLE || ir.mds[md].nops < 2 return NONE;
    tm := md_op(md, 1);
    if tm == NONE || ir.mds[tm].kind != .VALUE return NONE;
    c := ir.mds[tm].value;
    if c == NONE || vkind(c) != .C_INT return NONE;
    if type_int_width(vtype(c)) != 64 return NONE;
    return c;
}

// buildCFICheck: emits __cfi_check
cdc_build_cfi_check :: () {
    type_ids: [..] u64; type_ids.allocator = temp;   // SetVector<uint64_t>
    add :: (ids: *[..] u64, c: Value_Id) { v := const_int_zext(c); if !array_find(ids.*, v) array_add(ids, v); }
    types: [..] Md_Id; types.allocator = temp;
    objects: [..] Value_Id; objects.allocator = temp;
    for ir.m_functions array_add(*objects, it);
    for ir.m_globals array_add(*objects, it);
    for go: objects {
        ltt_type_mds(go, *types);
        for t: types { c := cdc_extract_numeric_type_id(t); if c != NONE add(*type_ids, c); }
    }
    cfk := named_md_find("cfi.functions");
    if cfk >= 0 {
        for func: ir.named_md[cfk].ops {
            n := ir.mds[func].nops;
            if n < 3 fatal("cross-dso-cfi: malformed cfi.functions entry");
            for i: 3..n-1 { c := cdc_extract_numeric_type_id(md_op(func, i)); if c != NONE add(*type_ids, c); }
        }
    }
    pty := type_ptr(0);
    f := module_get_or_insert_function("__cfi_check", type_func(ir.t_void, .[ir.t_i64, pty, pty], false));
    if vkind(f) != .FUNCTION fatal("cross-dso-cfi: __cfi_check is not a function");
    if glob(f).value_type != type_func(ir.t_void, .[ir.t_i64, pty, pty], false) fatal("cross-dso-cfi: __cfi_check has an unexpected type");
    fn_delete_body(f);
    glob(f).align = 4096;
    t := triple_parse(ir.triple);
    if t.arch == .arm || t.arch == .armeb || t.arch == .thumb || t.arch == .thumbeb fn_add_fn_str_attr(f, "target-features", "+thumb-mode");
    call_site_type_id := fn_arg(f, 0);
    addr := fn_arg(f, 1);
    fail_data := fn_arg(f, 2);
    set_name(call_site_type_id, "CallSiteTypeId");
    set_name(addr, "Addr");
    set_name(fail_data, "CFICheckFailData");

    bb := create_block(f, "entry");
    exit_bb := create_block(f, "exit");
    trap_bb := create_block(f, "fail");
    b: Irb;
    irb_set_end(*b, trap_bb);
    fail_fn := module_get_or_insert_function("__cfi_check_fail", type_func(ir.t_void, .[pty, pty], false));
    if vkind(fail_fn) != .FUNCTION fatal("cross-dso-cfi: __cfi_check_fail is not a function");
    irb_call(*b, fail_fn, .[fail_data, addr]);
    irb_br(*b, exit_bb);
    irb_set_end(*b, exit_bb);
    irb_insert(*b, new_inst(.RET, ir.t_void, 0));

    irb_set_end(*b, bb);
    sw := new_inst(.SWITCH, ir.t_void, 2);
    grow_ops(sw, cast(u32) (2 + type_ids.count));
    set_op(sw, 0, call_site_type_id); set_op(sw, 1, trap_bb);
    irb_insert(*b, sw);
    likely := md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1048575)), md_value(const_int(ir.t_i32, 1))], false);
    for id: type_ids {
        case_id := const_int(ir.t_i64, id);
        test_bb := create_block(f, "test");
        tb: Irb;
        irb_set_end(*tb, test_bb);
        test := irb_intrinsic(*tb, "llvm.type.test", .[], .[addr, md_as_value(md_value(case_id))]);
        bi := irb_cond_br(*tb, test, exit_bb, trap_bb);
        set_metadata(bi, MDK_PROF, likely);
        add_op(sw, test_bb, case_id);
    }
}

cross_dso_cfi_run :: () -> Preserved {
    if module_flag("Cross-DSO CFI") == NONE return PRESERVE_ALL;
    cdc_build_cfi_check();
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- GlobalSplit

gs_split_global :: (gv: Value_Id) -> bool {
    if !gv_has_local_linkage(gv) return false;
    if !glob(gv).has_init return false;
    init := gv_initializer(gv);
    if vkind(init) != .C_STRUCT return false;
    sty := vtype(init);
    nmem := cast(u32) type_nsub(sty);
    size_in_bytes := dl_type_alloc_size(sty);   // StructLayout::getSizeInBytes
    w := dl_index_type_size_bits(vtype(gv));
    if w > 64 fatal("globalsplit: index widths above 64 bits are not supported");
    mask: u64 = ifx w == 64 then 0xFFFF_FFFF_FFFF_FFFF else ((cast(u64) 1) << w) - 1;
    member_offset :: (sty: Type_Id, i: u32) -> u64 { return dl_struct_offset(sty, i); }

    Gs_Info :: struct { gep: Value_Id; member: u32; rel: u64; }
    infos: [..] Gs_Info; infos.allocator = temp;
    u := ir.v_first_use[gv];
    while u != NONE {
        defer u = ir.u_next[u];
        usr := ir.u_user[u];
        if opr_code(usr) != .GEP return false;
        // GEPOperator::getInRange: only constant GEPs carry one
        if vkind(usr) != .C_EXPR || (cexpr(usr).flags & F_INRANGE) == 0 return false;
        e := cexpr(usr);
        lo := (cast(u64) ir.u32_pool[e.idx]) | ((cast(u64) ir.u32_pool[e.idx + 1]) << 32);
        hi := (cast(u64) ir.u32_pool[e.idx + 2]) | ((cast(u64) ir.u32_pool[e.idx + 3]) << 32);
        ok, ap := gep_accumulate_constant_offset(usr, ap_zero(w));
        if !ok return false;
        off := ap_zext_value(ap) & mask;
        // SrcInRange = InRange.sextOrTrunc(IndexWidth).add(Offset)
        full := (lo & mask) == (hi & mask);
        l := (lo + off) & mask; h := (hi + off) & mask;
        contains: bool;
        if full contains = true;
        else if l < h contains = l <= off && off < h;
        else contains = off >= l || off < h;
        lower := ifx full then mask else l;
        upper := ifx full then mask else h;
        if !contains && upper != off return false;
        if lower >= size_in_bytes return false;
        mi := dl_struct_element_containing_offset(sty, lower);
        ms := member_offset(sty, mi);
        me := ifx mi == nmem - 1 then size_in_bytes else member_offset(sty, mi + 1);
        if lower != ms || upper != me return false;
        array_add(*infos, .{usr, mi, (off - ms) & mask});
    }

    types: [..] Md_Id; types.allocator = temp;
    ltt_type_mds(gv, *types);
    split: [..] Value_Id; split.allocator = temp;
    vk := md_fixed("vcall_visibility");
    for i: 0..nmem-1 {
        elt := op(init, i);
        sg := gv_create(vtype(elt), glob(gv).is_const, .PRIVATE, elt, tprint("%.%", vname(gv), i), NONE, 0, glob(gv).addrspace);
        array_add(*split, sg);
        begin := member_offset(sty, i);
        end := ifx i == nmem - 1 then size_in_bytes else member_offset(sty, i + 1);
        for t: types {
            byte_offset := ltt_type_offset(t);
            attached := ifx byte_offset == 0 then byte_offset else byte_offset - 1;
            if attached < begin || attached >= end continue;
            add_metadata(sg, md_fixed("type"), md_tuple(.[md_value(const_int(ir.t_i32, byte_offset - begin)), md_op(t, 1)], false));
        }
        vm := get_metadata(gv, vk);
        if vm != NONE {
            // getVCallVisibility / setVCallVisibilityMetadata (always an i64)
            v := const_int_zext(ir.mds[md_op(vm, 0)].value);
            set_metadata(sg, vk, NONE);
            add_metadata(sg, vk, md_tuple(.[md_value(const_int(ir.t_i64, v))], false));
        }
    }
    for infos {
        ng := ce_gep(ir.t_i8, split[it.member], .[const_int(type_int(w), it.rel)], cexpr(it.gep).flags & F_INBOUNDS);
        ipo_rauw(it.gep, ng);
    }
    if has_uses(gv) ipo_rauw(gv, const_poison(vtype(gv)));
    gv_erase_from_parent(gv);
    return true;
}

global_split_run :: () -> Preserved {
    if !lto_used_decl("llvm.type.test") && !lto_used_decl("llvm.type.checked.load") && !lto_used_decl("llvm.type.checked.load.relative")
        return PRESERVE_ALL;
    changed := false;
    // make_early_inc_range(M.globals()): the globals the pass appends are visited too
    i := 0;
    while i < ir.m_globals.count {
        gv := ir.m_globals[i];
        changed |= gs_split_global(gv);
        if i < ir.m_globals.count && ir.m_globals[i] == gv i += 1;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}

// ---------------------------------------------------------------- SimplifyTypeTests

simplify_type_tests_run :: () -> Preserved {
    changed := false;
    globals := array_copy(ir.m_globals,, allocator = temp);
    for gv: globals {
        if vkind(gv) != .GLOBAL_VAR continue;
        name := vname(gv);
        if !begins_with(name, "__typeid_") || !ends_with(name, "_global_addr") continue;
        md := md_string(slice(name, 9, name.count - 21));
        may_simplify_ptr :: (md: Md_Id, p_in: Value_Id) -> bool {
            p := p_in;
            if is_global_value(vkind(p)) {
                cfi := lookup_global(tconcat(vname(p), ".cfi"));
                if cfi != NONE p = cfi;
            }
            return ltt_is_known_type_id_member(md, p, 0);
        }
        may_simplify_int :: (md: Md_Id, o: Value_Id) -> bool {
            if vkind(o) != .C_EXPR || cexpr(o).op != .PTRTOINT return false;
            return may_simplify_ptr(md, op(o, 0));
        }
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[gv];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for usr: users {
            if vkind(usr) == .DEAD continue;
            if is_inst(usr) && inst_op(usr) == .ICMP {
                if inst(usr).pred == ICMP_EQ && may_simplify_ptr(md, op(usr, 0)) {
                    ipo_rauw(usr, const_int(ir.t_i1, 1));
                    erase_inst(usr);
                    changed = true;
                    continue;
                }
            }
            if vkind(usr) != .C_EXPR || cexpr(usr).op != .PTRTOINT continue;
            cuses: [..] Use_Id; cuses.allocator = temp;
            x := ir.v_first_use[usr];
            while x != NONE { array_add(*cuses, x); x = ir.u_next[x]; }
            for cu: cuses {
                cusr := ir.u_user[cu];
                if vkind(cusr) == .DEAD continue;
                if opno_of(cu) == 0 && vkind(cusr) == .C_EXPR && cexpr(cusr).op == .SUB && may_simplify_int(md, op(cusr, 1)) {
                    ipo_rauw(cusr, const_int(vtype(cusr), 0));
                    changed = true;
                }
                if opno_of(cu) == 1 && is_inst(cusr) && inst_op(cusr) == .ICMP && inst(cusr).pred == ICMP_EQ && may_simplify_int(md, op(cusr, 0)) {
                    ipo_rauw(cusr, const_int(ir.t_i1, 1));
                    erase_inst(cusr);
                    changed = true;
                }
            }
        }
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    preserve(*pa, .POSTDOMTREE);
    preserve(*pa, .LOOPS);
    return pa;
}
