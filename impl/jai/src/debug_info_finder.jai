// DebugInfoFinder for print<module-debuginfo> (llvm/lib/IR/DebugInfo.cpp: processModule, processCompileUnit, processGlobalVariableExpression,
// processInstruction, processLocation, processDbgRecord, processVariable, processType, processImportedEntity,
// processMacroNode, processScope, processSubprogram, add*) and print<module-debuginfo>
// (llvm/lib/Analysis/ModuleDebugInfoPrinter.cpp).
// (pass_strip_dead_debug_info.jai has a second DebugInfoFinder port, without the macro files and scopes this printer
// needs: a design debt, see NOTES.md "Pass registry gaps")
// Operand positions are jai's DI layouts (debuginfo.jai parse_specialized_md), which follow LLVM's operand order.

Mdi_Finder :: struct {
    cus: [..] Md_Id;
    sps: [..] Md_Id;
    gvs: [..] Md_Id;         // DIGlobalVariableExpression
    tys: [..] Md_Id;
    scopes: [..] Md_Id;
    macros: [..] struct { macro: Md_Id; file: Md_Id; };
    seen: Table(Md_Id, bool);   // NodesSeen
}

mdi_init :: (d: *Mdi_Finder) {
    d.cus.allocator = temp; d.sps.allocator = temp; d.gvs.allocator = temp; d.tys.allocator = temp;
    d.scopes.allocator = temp; d.macros.allocator = temp; d.seen.allocator = temp;
}
mdi_seen_insert :: (d: *Mdi_Finder, m: Md_Id) -> bool {
    if table_contains(*d.seen, m) return false;
    table_set(*d.seen, m, true);
    return true;
}
// the elements of an MDTuple operand (null when absent)
mdi_tuple :: (t: Md_Id) -> [] Md_Id {
    r: [] Md_Id;
    if t == NONE || ir.mds[t].kind != .TUPLE return r;
    r.data = ir.md_ops.data + ir.mds[t].ops;
    r.count = ir.mds[t].nops;
    return r;
}

mdi_process_module :: (d: *Mdi_Finder) {
    // M.debug_compile_units(): DICompileUnitIterator skips CUs with emissionKind NoDebug
    for nm: ir.named_md if nm.name == "llvm.dbg.cu" for nm.ops if is_di(it, .COMPILE_UNIT) && di_int(it, 6) != 0 mdi_process_compile_unit(d, it);
    for f: ir.m_functions {
        sp := get_metadata(f, 0);
        if is_di(sp, .SUBPROGRAM) mdi_process_subprogram(d, sp);
        for i: fn_insts(f) {
            // processInstruction (debug intrinsics are records after the upgrade)
            dl := get_metadata(i, 0);
            if dl != NONE mdi_process_location(d, dl);
            r := inst(i).records;
            while r {
                rec := dbgr(r);
                if rec.kind != .LABEL mdi_process_variable_di(d, rec.var);
                if rec.dbg != NONE mdi_process_location(d, rec.dbg);
                r = rec.next;
            }
        }
    }
}

mdi_process_compile_unit :: (d: *Mdi_Finder, cu: Md_Id) {
    if !mdi_add_compile_unit(d, cu) return;
    for mdi_tuple(di_op(cu, 6)) mdi_process_gve(d, it);   // getGlobalVariables
    for mdi_tuple(di_op(cu, 4)) mdi_process_type(d, it);  // getEnumTypes
    for mdi_tuple(di_op(cu, 5)) {                         // getRetainedTypes
        if di_is_type(it) mdi_process_type(d, it);
        else mdi_process_subprogram(d, it);
    }
    for mdi_tuple(di_op(cu, 7)) mdi_process_imported_entity(d, it);
    for mdi_tuple(di_op(cu, 8)) mdi_process_macro_node(d, it, NONE);
}

mdi_process_gve :: (d: *Mdi_Finder, gve: Md_Id) {
    if !mdi_seen_insert(d, gve) return;   // addGlobalVariable
    array_add(*d.gvs, gve);
    gv := di_op(gve, 0);
    mdi_process_scope(d, di_op(gv, 0));
    mdi_process_type(d, di_op(gv, 3));
}

mdi_process_location :: (d: *Mdi_Finder, loc: Md_Id) {
    l := loc;
    while l != NONE && is_di(l, .LOCATION) {
        mdi_process_scope(d, di_op(l, 0));
        l = di_op(l, 1);   // getInlinedAt
    }
}

// processVariable(DIVariable *): only DILocalVariables
mdi_process_variable_di :: (d: *Mdi_Finder, v: Md_Id) { if is_di(v, .LOCAL_VARIABLE) mdi_process_local_variable(d, v); }

mdi_process_local_variable :: (d: *Mdi_Finder, v: Md_Id) {
    if !mdi_seen_insert(d, v) return;
    mdi_process_scope(d, di_op(v, 0));
    mdi_process_type(d, di_op(v, 3));
}

mdi_process_type :: (d: *Mdi_Finder, t: Md_Id) {
    if !mdi_add_type(d, t) return;
    mdi_process_scope(d, di_op(t, 1));
    k := di_kind(t);
    if k == .SUBROUTINE_TYPE {
        for mdi_tuple(di_op(t, 5)) mdi_process_type(d, it);
        return;
    }
    if k == .COMPOSITE_TYPE {
        mdi_process_type(d, di_op(t, 5));    // getBaseType
        mdi_process_type(d, di_op(t, 7));    // getVTableHolder
        mdi_process_type(d, di_op(t, 10));   // getDiscriminator
        mdi_process_type(d, di_op(t, 16));   // getSpecification
        mdi_process_variable_di(d, di_op(t, 11));   // getDataLocation (a DIVariable or null)
        mdi_process_variable_di(d, di_op(t, 12));   // getAssociated
        mdi_process_variable_di(d, di_op(t, 13));   // getAllocated
        for e: mdi_tuple(di_op(t, 6)) {
            if e == NONE continue;
            if di_is_type(e) mdi_process_type(d, e);
            else if is_di(e, .SUBPROGRAM) mdi_process_subprogram(d, e);
            else if is_di(e, .SUBRANGE) || is_di(e, .GENERIC_SUBRANGE) {
                // VisitBound(LowerBound), (Count), (UpperBound), (Stride): ops are (count, lower, upper, stride)
                for idx: u32.[1, 0, 2, 3] mdi_process_variable_di(d, di_op(e, idx));
            }
        }
        return;
    }
    if k == .STRING_TYPE { mdi_process_variable_di(d, di_op(t, 5)); return; }   // getStringLength
    if k == .SUBRANGE_TYPE {
        mdi_process_type(d, di_op(t, 5));
        for idx: u32.[6, 7, 8, 9] {   // lower, upper, stride, bias: a DIVariable or a DIDerivedType
            b := di_op(t, idx);
            if is_di(b, .LOCAL_VARIABLE) || is_di(b, .GLOBAL_VARIABLE) mdi_process_variable_di(d, b);
            else if is_di(b, .DERIVED_TYPE) mdi_process_type(d, b);
        }
        return;
    }
    if k == .DERIVED_TYPE mdi_process_type(d, di_op(t, 5));
}

mdi_process_imported_entity :: (d: *Mdi_Finder, ie: Md_Id) {
    e := di_op(ie, 1);
    if e == NONE return;
    if di_is_type(e) mdi_process_type(d, e);
    else if is_di(e, .SUBPROGRAM) mdi_process_subprogram(d, e);
    else if is_di(e, .NAMESPACE) || is_di(e, .MODULE) mdi_process_scope(d, di_op(e, 1));
}

mdi_process_macro_node :: (d: *Mdi_Finder, m: Md_Id, cur_file: Md_Id) {
    if m == NONE return;
    if is_di(m, .MACRO) {
        if mdi_seen_insert(d, m) array_add(*d.macros, .{m, cur_file});   // addMacro
        return;
    }
    if !is_di(m, .MACRO_FILE) fatal("print<module-debuginfo>: unexpected macro node");
    if !mdi_seen_insert(d, m) return;
    for mdi_tuple(di_op(m, 1)) mdi_process_macro_node(d, it, m);
}

mdi_process_scope :: (d: *Mdi_Finder, s: Md_Id) {
    if s == NONE || ir.mds[s].kind != .SPECIAL return;
    if di_is_type(s) { mdi_process_type(d, s); return; }
    k := di_kind(s);
    if k == .COMPILE_UNIT { mdi_add_compile_unit(d, s); return; }
    if k == .SUBPROGRAM { mdi_process_subprogram(d, s); return; }
    // addScope (no DI scope has zero operands in LLVM's layouts)
    if !mdi_seen_insert(d, s) return;
    array_add(*d.scopes, s);
    if k == .LEXICAL_BLOCK || k == .LEXICAL_BLOCK_FILE || k == .NAMESPACE || k == .MODULE mdi_process_scope(d, di_op(s, 1));
}

mdi_process_subprogram :: (d: *Mdi_Finder, sp: Md_Id) {
    if sp == NONE || !mdi_seen_insert(d, sp) return;   // addSubprogram
    array_add(*d.sps, sp);
    mdi_process_scope(d, di_op(sp, 1));
    mdi_process_compile_unit(d, di_op(sp, 5));
    mdi_process_type(d, di_op(sp, 4));
    for mdi_tuple(di_op(sp, 9)) {
        if is_di(it, .TEMPLATE_TYPE_PARAMETER) || is_di(it, .TEMPLATE_VALUE_PARAMETER) mdi_process_type(d, di_op(it, 1));
    }
    // forEachRetainedNode
    for n: mdi_tuple(di_op(sp, 7)) {
        if n == NONE continue;
        if is_di(n, .LOCAL_VARIABLE) mdi_process_local_variable(d, n);
        else if is_di(n, .LABEL) {}
        else if is_di(n, .IMPORTED_ENTITY) mdi_process_imported_entity(d, n);
        else if di_is_type(n) mdi_process_type(d, n);
        else if is_di(n, .GLOBAL_VARIABLE_EXPRESSION) mdi_process_gve(d, n);
        else fatal("print<module-debuginfo>: unexpected retained node");
    }
}

mdi_add_type :: (d: *Mdi_Finder, t: Md_Id) -> bool {
    if t == NONE || !di_is_type(t) return false;
    if !mdi_seen_insert(d, t) return false;
    array_add(*d.tys, t);
    return true;
}
mdi_add_compile_unit :: (d: *Mdi_Finder, cu: Md_Id) -> bool {
    if cu == NONE || !mdi_seen_insert(d, cu) return false;
    array_add(*d.cus, cu);
    return true;
}

// ---------------------------------------------------------------- ModuleDebugInfoPrinterPass

dwarf_name_lookup :: (table: [] Dwarf_Name, v: u64) -> string {
    for table if it.value == v return it.name;
    return "";
}

print_module_debuginfo_run :: () {
    d: Mdi_Finder;
    mdi_init(*d);
    mdi_process_module(*d);
    sb: String_Builder; sb.allocator = temp;
    print_file :: (sb: *String_Builder, file: Md_Id, line: u64 = 0) {
        if file == NONE return;
        fname := md_str_of(di_op(file, 0));
        if fname.count == 0 return;
        dir := md_str_of(di_op(file, 1));
        append(sb, " from ");
        if dir.count { append(sb, dir); append(sb, "/"); }
        append(sb, fname);
        if line print_to_builder(sb, ":%", line);
    }
    file_of :: (n: Md_Id, op_index: u32) -> Md_Id { f := di_op(n, op_index); if is_di(f, .FILE) return f; return NONE; }
    for cu: d.cus {
        append(*sb, "Compile unit: ");
        lname := di_int(cu, 0);
        ls := ifx di_int(cu, 3) then dwarf_name_lookup(DW_LNAME_NAMES, lname) else dwarf_name_lookup(DW_LANG_NAMES, lname);
        if ls.count append(*sb, ls); else print_to_builder(*sb, "unknown-language(%)", lname);
        print_file(*sb, file_of(cu, 0));
        append(*sb, "\n");
    }
    for sp: d.sps {
        print_to_builder(*sb, "Subprogram: %", md_str_of(di_op(sp, 2)));
        print_file(*sb, file_of(sp, 0), di_int(sp, 0));
        ln := md_str_of(di_op(sp, 3));
        if ln.count print_to_builder(*sb, " ('%')", ln);
        append(*sb, "\n");
    }
    for gve: d.gvs {
        gv := di_op(gve, 0);
        print_to_builder(*sb, "Global variable: %", md_str_of(di_op(gv, 1)));
        print_file(*sb, file_of(gv, 2), di_int(gv, 0));
        ln := md_str_of(di_op(gv, 5));
        if ln.count print_to_builder(*sb, " ('%')", ln);
        append(*sb, "\n");
    }
    for t: d.tys {
        k := di_kind(t);
        append(*sb, "Type:");
        name := ifx k == .SUBROUTINE_TYPE then "" else md_str_of(di_op(t, 2));
        if name.count { append(*sb, " "); append(*sb, name); }
        line: u64 = ifx k == .SUBROUTINE_TYPE || k == .STRING_TYPE then cast(u64) 0 else di_int(t, 1);
        print_file(*sb, file_of(t, 0), line);
        if k == .BASIC_TYPE || k == .FIXED_POINT_TYPE {
            enc := di_int(t, 3);
            es := dwarf_name_lookup(DW_ATE_NAMES, enc);
            append(*sb, " ");
            if es.count append(*sb, es); else print_to_builder(*sb, "unknown-encoding(%)", enc);
        } else {
            tag: u64 = ifx k == .SUBROUTINE_TYPE then cast(u64) 0x15 else di_int(t, 0);
            ts := dwarf_name_lookup(DW_TAG_NAMES, tag);
            append(*sb, " ");
            if ts.count append(*sb, ts); else print_to_builder(*sb, "unknown-tag(%)", tag);
        }
        if k == .COMPOSITE_TYPE {
            id := di_op(t, 9);
            if id != NONE print_to_builder(*sb, " (identifier: '%')", md_str_of(id));
        }
        append(*sb, "\n");
    }
    for d.macros {
        m := it.macro;
        append(*sb, "Macro: ");
        mt := di_int(m, 0);
        ms := dwarf_name_lookup(DW_MACINFO_NAMES, mt);
        if ms.count append(*sb, ms); else print_to_builder(*sb, "unknown-macinfo(%)", mt);
        print_to_builder(*sb, " '%'", md_str_of(di_op(m, 0)));
        v := md_str_of(di_op(m, 1));
        if v.count print_to_builder(*sb, " = '%'", v);
        if it.file != NONE && di_op(it.file, 0) != NONE print_file(*sb, di_op(it.file, 0), di_int(it.file, 1));
        else print_to_builder(*sb, " at line %", di_int(m, 1));
        append(*sb, "\n");
    }
    write_string(builder_to_string(*sb,, allocator = temp), to_standard_error = true);
}
