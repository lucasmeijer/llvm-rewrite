// StripDeadDebugInfoPass (`strip-dead-debug-info`): stripDeadDebugInfoImpl of llvm/lib/Transforms/IPO/StripSymbols.cpp,
// with DebugInfoFinder (llvm/lib/IR/DebugInfo.cpp: processModule, processCompileUnit, processSubprogram,
// processType, processScope, ...). Debug-info operands are in LLVM's operand order (debuginfo.jai), so the indices
// below are those of llvm/include/llvm/IR/DebugInfoMetadata.h.
//
// Address order: LiveCUs is a std::set<DICompileUnit *>; with dead CUs llvm.dbg.cu is rebuilt in pointer order:
// fails loudly when more than one CU stays live.

sddi_guess_address_order := false;   // -strip-dead-debug-info-guess-address-order (ours)

Dif :: struct {
    cus: [..] Md_Id;
    sps: [..] Md_Id;
    gvs: [..] Md_Id;
    tys: [..] Md_Id;
    scopes: [..] Md_Id;
    seen: Table(Md_Id, bool);   // NodesSeen
}
dif_init :: (d: *Dif) {
    d.cus.allocator = temp; d.sps.allocator = temp; d.gvs.allocator = temp; d.tys.allocator = temp;
    d.scopes.allocator = temp; d.seen.allocator = temp;
}
dif_is_di :: (m: Md_Id, k: DI_Kind) -> bool { return m != NONE && ir.mds[m].kind == .SPECIAL && di_kind(m) == k; }
dif_is_node :: (m: Md_Id) -> bool { return m != NONE && md_is_node(m); }
dif_seen :: (d: *Dif, m: Md_Id) -> bool {
    if table_contains(*d.seen, m) return true;
    table_set(*d.seen, m, true);
    return false;
}
// the elements of an MDTuple operand (NONE = no tuple)
dif_tuple :: (m: Md_Id, out: *[..] Md_Id) {
    out.count = 0;
    if m == NONE || !md_is_node(m) return;
    for k: 0..cast(s64) md_nops(m) - 1 array_add(out, md_op(m, cast(u32) k));
}

dif_add_compile_unit :: (d: *Dif, cu: Md_Id) -> bool {
    if cu == NONE return false;
    if dif_seen(d, cu) return false;
    array_add(*d.cus, cu);
    return true;
}

// processCompileUnit
dif_process_compile_unit :: (d: *Dif, cu: Md_Id) {
    if !dif_add_compile_unit(d, cu) return;
    l: [..] Md_Id; l.allocator = temp;
    dif_tuple(di_op(cu, 6), *l); for l dif_process_global_variable_expression(d, it);
    dif_tuple(di_op(cu, 4), *l); for l dif_process_type(d, it);
    dif_tuple(di_op(cu, 5), *l);
    for l {
        if di_is_type(it) dif_process_type(d, it);
        else dif_process_subprogram(d, it);
    }
    dif_tuple(di_op(cu, 7), *l); for l dif_process_imported_entity(d, it);
    dif_tuple(di_op(cu, 8), *l); for l dif_process_macro_node(d, it);
}
// processGlobalVariableExpression
dif_process_global_variable_expression :: (d: *Dif, gve: Md_Id) {
    if gve == NONE || dif_seen(d, gve) return;
    array_add(*d.gvs, gve);
    gv := di_op(gve, 0);
    if gv == NONE return;
    dif_process_scope(d, di_op(gv, 0));
    dif_process_type(d, di_op(gv, 3));
}
// processVariable(DIVariable *)
dif_process_variable :: (d: *Dif, v: Md_Id) {
    if !dif_is_di(v, .LOCAL_VARIABLE) return;
    if dif_seen(d, v) return;
    dif_process_scope(d, di_op(v, 0));
    dif_process_type(d, di_op(v, 3));
}
// processType
dif_process_type :: (d: *Dif, t: Md_Id) {
    if t == NONE || !di_is_type(t) return;
    if dif_seen(d, t) return;
    array_add(*d.tys, t);
    dif_process_scope(d, di_op(t, 1));
    k := di_kind(t);
    if k == .SUBROUTINE_TYPE {
        l: [..] Md_Id; l.allocator = temp;
        dif_tuple(di_op(t, 5), *l);
        for l dif_process_type(d, it);
        return;
    }
    if k == .COMPOSITE_TYPE {
        dif_process_type(d, di_op(t, 5));
        dif_process_type(d, di_op(t, 7));
        dif_process_type(d, di_op(t, 10));
        dif_process_type(d, di_op(t, 16));
        dif_process_variable(d, di_op(t, 11));
        dif_process_variable(d, di_op(t, 12));
        dif_process_variable(d, di_op(t, 13));
        l: [..] Md_Id; l.allocator = temp;
        dif_tuple(di_op(t, 6), *l);
        for e: l {
            if di_is_type(e) dif_process_type(d, e);
            else if dif_is_di(e, .SUBPROGRAM) dif_process_subprogram(d, e);
            else if dif_is_di(e, .SUBRANGE) || dif_is_di(e, .GENERIC_SUBRANGE) {
                for b: 0..3 dif_process_variable(d, di_op(e, cast(u32) b));
            }
        }
        return;
    }
    if k == .STRING_TYPE { dif_process_variable(d, di_op(t, 5)); return; }
    if k == .SUBRANGE_TYPE {
        dif_process_type(d, di_op(t, 5));
        for b: 6..9 {
            x := di_op(t, cast(u32) b);
            if dif_is_di(x, .LOCAL_VARIABLE) || dif_is_di(x, .GLOBAL_VARIABLE) dif_process_variable(d, x);
            else if dif_is_di(x, .DERIVED_TYPE) dif_process_type(d, x);
        }
        return;
    }
    if k == .DERIVED_TYPE dif_process_type(d, di_op(t, 5));
}
// processImportedEntity
dif_process_imported_entity :: (d: *Dif, ie: Md_Id) {
    if !dif_is_di(ie, .IMPORTED_ENTITY) return;
    e := di_op(ie, 1);
    if di_is_type(e) dif_process_type(d, e);
    else if dif_is_di(e, .SUBPROGRAM) dif_process_subprogram(d, e);
    else if dif_is_di(e, .NAMESPACE) dif_process_scope(d, di_op(e, 1));
    else if dif_is_di(e, .MODULE) dif_process_scope(d, di_op(e, 1));
}
// processMacroNode
dif_process_macro_node :: (d: *Dif, m: Md_Id) {
    if m == NONE return;
    if dif_is_di(m, .MACRO) return;   // addMacro: not needed here
    if !dif_is_di(m, .MACRO_FILE) return;
    if dif_seen(d, m) return;
    l: [..] Md_Id; l.allocator = temp;
    dif_tuple(di_op(m, 1), *l);
    for l dif_process_macro_node(d, it);
}
// processScope
dif_process_scope :: (d: *Dif, s: Md_Id) {
    if s == NONE || ir.mds[s].kind != .SPECIAL return;
    if di_is_type(s) { dif_process_type(d, s); return; }
    k := di_kind(s);
    if k == .COMPILE_UNIT { dif_add_compile_unit(d, s); return; }
    if k == .SUBPROGRAM { dif_process_subprogram(d, s); return; }
    // addScope
    if md_nops(s) == 0 return;
    if dif_seen(d, s) return;
    array_add(*d.scopes, s);
    if k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE dif_process_scope(d, di_op(s, 1));
    else if k == .NAMESPACE dif_process_scope(d, di_op(s, 1));
    else if k == .MODULE dif_process_scope(d, di_op(s, 1));
}
// processSubprogram
dif_process_subprogram :: (d: *Dif, sp: Md_Id) {
    if !dif_is_di(sp, .SUBPROGRAM) return;
    if dif_seen(d, sp) return;
    array_add(*d.sps, sp);
    dif_process_scope(d, di_op(sp, 1));
    dif_process_compile_unit(d, di_op(sp, 5));
    dif_process_type(d, di_op(sp, 4));
    l: [..] Md_Id; l.allocator = temp;
    dif_tuple(di_op(sp, 9), *l);
    for e: l {
        if dif_is_di(e, .TEMPLATE_TYPE_PARAMETER) || dif_is_di(e, .TEMPLATE_VALUE_PARAMETER) dif_process_type(d, di_op(e, 1));
    }
    // forEachRetainedNode
    dif_tuple(di_op(sp, 7), *l);
    for e: l {
        if dif_is_di(e, .LOCAL_VARIABLE) dif_process_variable(d, e);
        else if dif_is_di(e, .IMPORTED_ENTITY) dif_process_imported_entity(d, e);
        else if di_is_type(e) dif_process_type(d, e);
        else if dif_is_di(e, .GLOBAL_VARIABLE_EXPRESSION) dif_process_global_variable_expression(d, e);
    }
}
// processLocation
dif_process_location :: (d: *Dif, loc: Md_Id) {
    l := loc;
    while l != NONE {
        dif_process_scope(d, di_op(l, 0));
        l = di_op(l, 1);
    }
}
// processInstruction (debug records; there are no debug intrinsics in our IR)
dif_process_instruction :: (d: *Dif, i: Value_Id) {
    dl := get_metadata(i, 0);
    if dl != NONE dif_process_location(d, dl);
    x := inst(i).records;
    while x != 0 {
        rec := ir.dbg_records[x - 1];
        if rec.kind != .LABEL dif_process_variable(d, rec.var);
        dif_process_location(d, rec.dbg);
        x = rec.next;
    }
}
// the compile units of llvm.dbg.cu (Module::debug_compile_units: NoDebug units are skipped)
dif_module_cus :: (out: *[..] Md_Id) {
    k := named_md_find("llvm.dbg.cu");
    if k < 0 return;
    for ir.named_md[k].ops {
        if !dif_is_di(it, .COMPILE_UNIT) continue;
        if di_int(it, 6) == 0 continue;   // emissionKind == DICompileUnit::NoDebug
        array_add(out, it);
    }
}

strip_dead_debug_info_run :: () -> Preserved {
    changed := false;
    f: Dif; dif_init(*f);
    // processModule
    cus: [..] Md_Id; cus.allocator = temp;
    dif_module_cus(*cus);
    for cus dif_process_compile_unit(*f, it);
    for fn: ir.m_functions {
        sp := get_metadata(fn, 0);
        if sp != NONE dif_process_subprogram(*f, sp);
        if !is_declaration(fn) for i: fn_insts(fn) dif_process_instruction(*f, i);
    }
    live_gvs: Table(Md_Id, bool); live_gvs.allocator = temp;
    for gv: ir.m_globals {
        mds: [..] Kind_Md; mds.allocator = temp;
        get_all_metadata(gv, *mds);
        for mds if it.kind == 0 table_set(*live_gvs, it.md, true);   // GlobalVariable::getDebugInfo: the !dbg attachments
    }
    live_cu_finder: Dif; dif_init(*live_cu_finder);
    for fn: ir.m_functions {
        sp := get_metadata(fn, 0);
        if dif_is_di(sp, .SUBPROGRAM) dif_process_subprogram(*live_cu_finder, sp);
        if !is_declaration(fn) for i: fn_insts(fn) dif_process_instruction(*live_cu_finder, i);
    }
    live_cus: [..] Md_Id; live_cus.allocator = temp;   // std::set: membership + (pointer) order
    add_cu :: (l: *[..] Md_Id, c: Md_Id) { for l.* if it == c return; array_add(l, c); }
    for live_cu_finder.cus add_cu(*live_cus, it);
    has_dead_cus := false;
    visited: Table(Md_Id, bool); visited.allocator = temp;
    live_globals: [..] Md_Id; live_globals.allocator = temp;
    for dic: f.cus {
        gv_change := false;
        l: [..] Md_Id; l.allocator = temp;
        dif_tuple(di_op(dic, 6), *l);
        for dig: l {
            expr := di_op(dig, 1);
            if expr != NONE && di_expression_is_constant(expr) && !strip_global_constants table_set(*live_gvs, dig, true);
            if table_contains(*visited, dig) continue;
            table_set(*visited, dig, true);
            if table_contains(*live_gvs, dig) array_add(*live_globals, dig);
            else gv_change = true;
        }
        if live_globals.count add_cu(*live_cus, dic);
        else {
            found := false;
            for live_cus if it == dic found = true;
            if !found has_dead_cus = true;
        }
        if gv_change {
            // replaceGlobalVariables(MDTuple::get(C, LiveGlobalVariables))
            md_uniqued_replace_operand(dic, 6, md_tuple(live_globals, false));
            changed = true;
        }
        live_globals.count = 0;
    }
    if has_dead_cus {
        if live_cus.count > 1 {
            if !sddi_guess_address_order fatal("strip-dead-debug-info: llvm.dbg.cu is rebuilt from a std::set<DICompileUnit *> (pointer address order) with more than one compile unit (use -strip-dead-debug-info-guess-address-order to guess)");
            // guess: nodes are allocated in creation order
            quick_sort(live_cus, (a: Md_Id, b: Md_Id) -> s64 { return cast(s64) a - cast(s64) b; });
        }
        k := named_md_get_or_insert("llvm.dbg.cu");
        ir.named_md[k].ops.count = 0;
        for live_cus array_add(*ir.named_md[k].ops, it);
        changed = true;
    }
    if changed printer_note_ir_changed();
    return preserved_cfg();
}

// DIExpression::isConstant
di_expression_is_constant :: (e: Md_Id) -> bool {
    n := ir.mds[e].nints;
    if (n != 2 && n != 3 && n != 6) return false;
    e0 := di_int(e, 0);
    if e0 != DW_OP_CONSTS && e0 != DW_OP_CONSTU return false;
    if n == 2 && e0 == DW_OP_CONSTS return true;
    if (n == 3 && di_int(e, 2) != DW_OP_STACK_VALUE) || (n == 6 && (di_int(e, 2) != DW_OP_STACK_VALUE || di_int(e, 3) != DW_OP_LLVM_FRAGMENT)) return false;
    return true;
}
