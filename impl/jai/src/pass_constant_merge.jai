// ConstantMerge: merge identical internal constant globals.
// Ported from llvm/lib/Transforms/IPO/ConstantMerge.cpp.

// FindUsedValues
cm_find_used_values :: (name: string, used: *[..] Value_Id) {
    gv := module_get_global_variable(name);
    if gv == NONE return;
    inits := gv_initializer(gv);
    if vkind(inits) != .C_ARRAY fatal("constmerge: % initializer that is not a ConstantArray", name);
    for k: 0..nops(inits)-1 {
        g := strip_pointer_casts(op(inits, k));
        gdce_set_insert(used, g);
    }
}

// IsBetterCanonical
cm_is_better_canonical :: (a: Value_Id, b: Value_Id) -> bool {
    if !gv_has_local_linkage(a) && gv_has_local_linkage(b) return true;
    if gv_has_local_linkage(a) && !gv_has_local_linkage(b) return false;
    if gv_has_global_unnamed_addr(a) != gv_has_global_unnamed_addr(b) return gv_has_global_unnamed_addr(a);
    return glob(a).comdat < 0;
}

// isUnmergeableGlobal
cm_is_unmergeable :: (gv: Value_Id, used: [] Value_Id) -> bool {
    g := glob(gv);
    if !g.is_const || !gv_has_definitive_initializer(gv) || g.addrspace != 0 || g.section.count > 0 return true;
    if g.tls != 0 return true;
    for used if it == gv return true;
    return false;
}

// makeMergeable
cm_make_mergeable :: (old: Value_Id, new: Value_Id) -> bool {
    if !gv_has_global_unnamed_addr(old) && !gv_has_global_unnamed_addr(new) return false;
    if gv_has_metadata_other_than_dbg_and_guid(old) return false;
    if glob(old).comdat != glob(new).comdat && glob(new).comdat >= 0 return false;
    if !gv_has_global_unnamed_addr(old) glob(new).unnamed_addr = 0;
    return true;
}

// replace
cm_replace :: (old: Value_Id, new: Value_Id) {
    if glob(old).align != 0 || glob(new).align != 0 {
        // getAlign: GV->getAlign().value_or(DL.getPreferredAlign(GV))
        get_align :: (g: Value_Id) -> u64 { if glob(g).align != 0 return glob(g).align; return dl_preferred_align_gv(g); }
        glob(new).align = max(get_align(old), get_align(new));
    }
    // copyDebugLocMetadata
    mds: [..] Md_Id; mds.allocator = temp;
    gv_get_debug_info(old, *mds);
    for mds gv_add_debug_info(new, it);
    replace_all_uses_with(old, new);
    assert(gv_has_local_linkage(old));
    gv_erase_from_parent(old);
}

constant_merge_run :: () -> Preserved {
    used: [..] Value_Id; used.allocator = temp;
    cm_find_used_values("llvm.used", *used);
    cm_find_used_values("llvm.compiler.used", *used);

    cmap: Table(Value_Id, Value_Id); cmap.allocator = temp;
    repl: [..] [2] Value_Id; repl.allocator = temp;
    changes := 0;
    old_changes := 0;
    while true {
        i := 0;
        while i < ir.m_globals.count {
            gv := ir.m_globals[i];
            i += 1;
            remove_dead_constant_users(gv);
            if !has_uses(gv) && gv_has_local_linkage(gv) {
                gv_erase_from_parent(gv);
                i -= 1;
                changes += 1;
                continue;
            }
            if cm_is_unmergeable(gv, used) continue;
            if gv_is_weak_for_linker(gv) continue;
            if gv_has_metadata_other_than_dbg_and_guid(gv) continue;
            init := gv_initializer(gv);
            found, slot := table_find(*cmap, init);
            if !found || cm_is_better_canonical(gv, slot) table_set(*cmap, init, gv);
        }
        for gv: ir.m_globals {
            if cm_is_unmergeable(gv, used) continue;
            if !gv_has_local_linkage(gv) continue;
            init := gv_initializer(gv);
            found, slot := table_find(*cmap, init);
            if !found continue;
            if slot == gv continue;
            if !cm_make_mergeable(gv, slot) continue;
            array_add(*repl, .[gv, slot]);
        }
        for repl { cm_replace(it[0], it[1]); changes += 1; }
        if changes == old_changes break;
        old_changes = changes;
        repl.count = 0;
        table_reset(*cmap);
    }
    if changes { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}
