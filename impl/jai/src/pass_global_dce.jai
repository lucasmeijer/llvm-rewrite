// GlobalDCE: dead global elimination, with virtual function elimination.
// Ported from llvm/lib/Transforms/IPO/GlobalDCE.cpp, and getPointerAtOffset / replaceRelativePointerUsersWithZero
// from llvm/lib/Analysis/TypeMetadataUtils.cpp.

gdce_opts: struct {
    enable_vfe := true;   // -enable-vfe
};

Gdce :: struct {
    alive: Table(Value_Id, bool);
    // GVDependencies: GV -> the globals that become live with it (insertion order; a set)
    deps: Table(Value_Id, [..] Value_Id);
    const_deps_cache: Table(Value_Id, [] Value_Id);   // ConstantDependenciesCache
    comdat_members: Table(s32, [..] Value_Id);
    type_id_map: Table(Md_Id, [..] Gdce_Vtable_Entry);
    vfe_safe: Table(Value_Id, bool);
    in_lto_post_link: bool;
}
Gdce_Vtable_Entry :: struct { gv: Value_Id; offset: u64; }

// isEmptyFunction
gdce_is_empty_function :: (f: Value_Id) -> bool {
    if is_declaration(f) return false;
    for i: block_insts(fn_entry(f)) {
        if is_debug_or_pseudo_inst(i) continue;
        if inst_op(i) == .RET return nops(i) == 0;
        break;
    }
    return false;
}

gdce_set_insert :: (list: *[..] Value_Id, v: Value_Id) -> bool {
    for list.* if it == v return false;
    array_add(list, v);
    return true;
}

// ComputeDependencies
gdce_compute_dependencies :: (s: *Gdce, v: Value_Id, deps: *[..] Value_Id) {
    k := vkind(v);
    if k == .INST { gdce_set_insert(deps, inst_fn(v)); return; }
    if is_global_value(k) { gdce_set_insert(deps, v); return; }
    if is_constant_kind(k) {
        found, cached := table_find(*s.const_deps_cache, v);
        if !found {
            local: [..] Value_Id;
            u := ir.v_first_use[v];
            while u != NONE { gdce_compute_dependencies(s, ir.u_user[u], *local); u = ir.u_next[u]; }
            cached = local;
            table_set(*s.const_deps_cache, v, cached);
        }
        for cached gdce_set_insert(deps, it);
    }
}

// UpdateGVDependencies
gdce_update_gv_dependencies :: (s: *Gdce, gv: Value_Id) {
    deps: [..] Value_Id; deps.allocator = temp;
    u := ir.v_first_use[gv];
    while u != NONE { gdce_compute_dependencies(s, ir.u_user[u], *deps); u = ir.u_next[u]; }
    for gvu: deps {
        if gvu == gv continue;   // self-reference
        if table_contains(*s.vfe_safe, gvu) && vkind(gv) == .FUNCTION continue;
        gdce_add_dep(s, gvu, gv);
    }
}
gdce_add_dep :: (s: *Gdce, from: Value_Id, to: Value_Id) {
    p := table_find_pointer(*s.deps, from);
    if !p { e: [..] Value_Id; table_set(*s.deps, from, e); p = table_find_pointer(*s.deps, from); }
    gdce_set_insert(p, to);
}

// MarkLive
gdce_mark_live :: (s: *Gdce, gv: Value_Id, updates: *[..] Value_Id) {
    if table_contains(*s.alive, gv) return;
    table_add(*s.alive, gv, true);
    if updates array_add(updates, gv);
    c := gv_comdat(gv);
    if c >= 0 {
        members := table_find_pointer(*s.comdat_members, c);
        if members for m: members.* gdce_mark_live(s, m, updates);
    }
}

gdce_add_comdat_member :: (s: *Gdce, c: s32, g: Value_Id) {
    p := table_find_pointer(*s.comdat_members, c);
    if !p { e: [..] Value_Id; table_set(*s.comdat_members, c, e); p = table_find_pointer(*s.comdat_members, c); }
    array_add(p, g);
}

// ScanVTables
gdce_scan_vtables :: (s: *Gdce) {
    k_type := md_kind_id("type");
    k_vis := md_kind_id("vcall_visibility");
    for gv: ir.m_globals {
        types: [..] Md_Id; types.allocator = temp;
        a := ir.v_md[gv];
        while a != NONE { if ir.attaches[a].kind == k_type array_add(*types, ir.attaches[a].md); a = ir.attaches[a].next; }
        if is_declaration(gv) || types.count == 0 continue;
        for t: types {
            type_id := md_op(t, 1);
            off_md := md_op(t, 0);
            offset := const_int_zext(ir.mds[off_md].value);
            p := table_find_pointer(*s.type_id_map, type_id);
            if !p { e: [..] Gdce_Vtable_Entry; table_set(*s.type_id_map, type_id, e); p = table_find_pointer(*s.type_id_map, type_id); }
            dup := false;
            for p.* if it.gv == gv && it.offset == offset dup = true;
            if !dup array_add(p, .{gv, offset});
        }
        // GlobalObject::getVCallVisibility
        vis: u64 = 0;
        vm := get_metadata(gv, k_vis);
        if vm != NONE vis = const_int_zext(ir.mds[md_op(vm, 0)].value);
        if vis == 2 || (s.in_lto_post_link && vis == 1) table_set(*s.vfe_safe, gv, true);
    }
}

// getPointerAtOffset (TypeMetadataUtils.cpp)
get_pointer_at_offset :: (i_in: Value_Id, offset: u64, top_level: Value_Id) -> Value_Id {
    i := i_in;
    if vkind(i) == .C_DSO_EQUIV i = op(i, 0);
    if is_ptr_type(vtype(i)) return ifx offset == 0 then i else NONE;
    k := vkind(i);
    if k == .C_STRUCT {
        t := vtype(i);
        sz, al := dl_struct_layout(t);
        if offset >= sz return NONE;
        o := dl_struct_element_containing_offset(t, offset);
        return get_pointer_at_offset(op(i, o), offset - dl_struct_offset(t, o), top_level);
    }
    if k == .C_ARRAY {
        es := dl_type_alloc_size(type_elem(vtype(i)));
        o := offset / es;
        if o >= nops(i) return NONE;
        return get_pointer_at_offset(op(i, cast(u32) o), offset % es, top_level);
    }
    if k == .C_INT { if offset == 0 && is_null_value(i) return i; }
    if k == .C_EXPR {
        o := cexpr(i).op;
        if o == .TRUNC || o == .PTRTOINT return get_pointer_at_offset(op(i, 0), offset, top_level);
        if o == .SUB {
            o1 := get_pointer_at_offset(op(i, 1), 0, NONE);
            if o1 != NONE && vkind(o1) == .C_EXPR && cexpr(o1).op == .GEP o1 = op(o1, 0);
            if o1 != top_level return NONE;
            return get_pointer_at_offset(op(i, 0), offset, top_level);
        }
        return NONE;
    }
    return NONE;
}

// ScanVTableLoad
gdce_scan_vtable_load :: (s: *Gdce, caller: Value_Id, type_id: Md_Id, call_offset: u64) {
    p := table_find_pointer(*s.type_id_map, type_id);
    if !p { e: [..] Gdce_Vtable_Entry; table_set(*s.type_id_map, type_id, e); return; }
    for info: p.* {
        vt := info.gv;
        ptr := get_pointer_at_offset(gv_initializer(vt), info.offset + call_offset, vt);
        if ptr == NONE { table_remove(*s.vfe_safe, vt); continue; }
        callee := strip_pointer_casts(ptr);
        if vkind(callee) != .FUNCTION { table_remove(*s.vfe_safe, vt); continue; }
        gdce_add_dep(s, caller, callee);
    }
}

// ScanTypeCheckedLoadIntrinsics
gdce_scan_type_checked_loads :: (s: *Gdce) {
    for name: string.["llvm.type.checked.load", "llvm.type.checked.load.relative"] {
        f := module_get_function(name);
        if f == NONE continue;
        u := ir.v_first_use[f];
        while u != NONE {
            ci := ir.u_user[u];
            u = ir.u_next[u];
            if !is_inst(ci) || inst_op(ci) != .CALL continue;
            off := call_arg(ci, 1);
            tid := ir.v_aux[call_arg(ci, 2)];   // MetadataAsValue -> its metadata
            if vkind(off) == .C_INT gdce_scan_vtable_load(s, inst_fn(ci), tid, const_int_zext(off));
            else {
                p := table_find_pointer(*s.type_id_map, tid);
                if p for p.* table_remove(*s.vfe_safe, it.gv);
            }
        }
    }
}

// AddVirtualFunctionDependencies
gdce_add_virtual_function_dependencies :: (s: *Gdce) {
    if !gdce_opts.enable_vfe return;
    m := module_flag("Virtual Function Elim");
    if m == NONE || ir.mds[m].kind != .VALUE || vkind(ir.mds[m].value) != .C_INT || is_null_value(ir.mds[m].value) return;
    gdce_scan_vtables(s);
    if s.vfe_safe.count == 0 return;
    gdce_scan_type_checked_loads(s);
}

// replaceRelativePointerUsersWithZero (TypeMetadataUtils.cpp)
replace_relative_pointer_users_with_zero :: (c: Value_Id) {
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[c];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for usr: users {
        if vkind(usr) == .DEAD continue;
        if vkind(usr) == .C_DSO_EQUIV { replace_relative_pointer_users_with_zero(usr); continue; }
        if vkind(usr) != .C_EXPR || cexpr(usr).op != .PTRTOINT continue;
        subs: [..] Value_Id; subs.allocator = temp;
        x := ir.v_first_use[usr];
        while x != NONE { array_add(*subs, ir.u_user[x]); x = ir.u_next[x]; }
        for sub: subs {
            if vkind(sub) != .C_EXPR || cexpr(sub).op != .SUB break;
            replace_all_uses_with(sub, const_int(vtype(sub), 0));
        }
    }
}

// GlobalDCEPass::run
global_dce_run :: (node: *Pass_Node) -> Preserved {
    s: Gdce;
    if node.name == "globaldce<vfe-linkage-unit-visibility>" s.in_lto_post_link = true;
    else if node.name != "globaldce" fatal("invalid GlobalDCE pass parameter in '%'", node.name);
    changed := false;

    changed |= optimize_global_ctors_list(.EMPTY_FUNCTION);

    for f: ir.m_functions { c := glob(f).comdat; if c >= 0 gdce_add_comdat_member(*s, c, f); }
    for g: ir.m_globals { c := glob(g).comdat; if c >= 0 gdce_add_comdat_member(*s, c, g); }
    for a: ir.m_aliases { c := gv_comdat(a); if c >= 0 gdce_add_comdat_member(*s, c, a); }

    gdce_add_virtual_function_dependencies(*s);

    // global_objects(): functions, then global variables
    objs: [..] Value_Id; objs.allocator = temp;
    for ir.m_functions array_add(*objs, it);
    for ir.m_globals array_add(*objs, it);
    for go: objs {
        remove_dead_constant_users(go);
        if !is_declaration(go) && !gv_is_discardable_if_unused(go) gdce_mark_live(*s, go, null);
        gdce_update_gv_dependencies(*s, go);
    }
    for ga: ir.m_aliases {
        remove_dead_constant_users(ga);
        if !gv_is_discardable_if_unused(ga) gdce_mark_live(*s, ga, null);
        gdce_update_gv_dependencies(*s, ga);
    }
    for gi: ir.m_ifuncs {
        remove_dead_constant_users(gi);
        if !gv_is_discardable_if_unused(gi) gdce_mark_live(*s, gi, null);
        gdce_update_gv_dependencies(*s, gi);
    }

    new_live: [..] Value_Id; new_live.allocator = temp;
    for v, k: s.alive array_add(*new_live, k);
    while new_live.count {
        lgv := pop(*new_live);
        p := table_find_pointer(*s.deps, lgv);
        if p {
            list := p.*;   // MarkLive never adds dependencies
            for list gdce_mark_live(*s, it, *new_live);
        }
    }

    dead_vars: [..] Value_Id; dead_vars.allocator = temp;
    for gv: ir.m_globals if !table_contains(*s.alive, gv) {
        array_add(*dead_vars, gv);
        if glob(gv).has_init {
            init := gv_initializer(gv);
            gv_set_initializer(gv, NONE);
            if is_safe_to_destroy_constant(init) constant_destroy(init);
        }
    }
    dead_fns: [..] Value_Id; dead_fns.allocator = temp;
    for f: ir.m_functions if !table_contains(*s.alive, f) {
        array_add(*dead_fns, f);
        if !is_declaration(f) fn_delete_body(f);
    }
    dead_aliases: [..] Value_Id; dead_aliases.allocator = temp;
    for ga: ir.m_aliases if !table_contains(*s.alive, ga) { array_add(*dead_aliases, ga); set_op(ga, 0, NONE); }
    dead_ifuncs: [..] Value_Id; dead_ifuncs.allocator = temp;
    for gi: ir.m_ifuncs if !table_contains(*s.alive, gi) { array_add(*dead_ifuncs, gi); set_op(gi, 0, NONE); }

    erase_unused :: (gv: Value_Id) {
        remove_dead_constant_users(gv);
        gv_erase_from_parent(gv);
    }
    for f: dead_fns {
        if has_uses(f) {
            replace_relative_pointer_users_with_zero(f);
            replace_all_uses_with(f, const_null_value(vtype(f)));
        }
        erase_unused(f);
        changed = true;
    }
    for dead_vars { erase_unused(it); changed = true; }
    for dead_aliases { erase_unused(it); changed = true; }
    for dead_ifuncs { erase_unused(it); changed = true; }

    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
