// The `debugify` and `check-debugify` module passes (synthetic mode), opt's -enable-debugify (-strip-debug is in pass_simplifycfg.jai).
// Ported from llvm/lib/Transforms/Utils/Debugify.cpp (applyDebugifyMetadata, checkDebugifyMetadata,
// diagnoseMisSizedDbgValue, stripDebugifyMetadata, NewPMDebugifyPass::run, NewPMCheckDebugifyPass::run) with the
// DIBuilder calls it makes (llvm/lib/IR/DIBuilder.cpp: createFile, createCompileUnit, createSubroutineType,
// createFunction, createBasicType, createAutoVariable, insertDbgValueIntrinsic, finalize/finalizeSubprogram) and
// llvm/tools/opt/optdriver.cpp / NewPMDriver.cpp (-strip-debug, -enable-debugify).
//
// Not ported (fail loudly): the "original debuginfo" mode (-verify-each-debuginfo-preserve,
// -verify-debuginfo-preserve), -debugify-each, mir-debugify.

dbgify_opts: struct {
    level_locations_only := false;   // -debugify-level=locations
    quiet := false;                  // -debugify-quiet
    atoms := false;                  // -debugify-atoms
    enable := false;                 // opt -enable-debugify
    level_text: string;
};
DBGIFY_CL_OPT_COUNT :: 5;
add_dbgify_cl_opts :: (list: [] Cl_Opt, start: s64) {
    o := *dbgify_opts;
    list[start + 0] = .{"debugify-quiet", .BOOL, *o.quiet, null, null};
    list[start + 1] = .{"debugify-atoms", .BOOL, *o.atoms, null, null};
    list[start + 2] = .{"enable-debugify", .BOOL, *o.enable, null, null};
    list[start + 3] = .{"debugify-level", .STRING, null, null, *o.level_text};
    list[start + 4] = .{"instcombine-lower-dbg-declare", .BOOL, *opts.instcombine_lower_dbg_declare, null, null};
}
dbgify_check_level :: () {
    t := dbgify_opts.level_text;
    if t.count == 0 return;
    if t == "locations" dbgify_opts.level_locations_only = true;
    else if t == "location+variables" dbgify_opts.level_locations_only = false;
    else fatal("Cannot find option named '%' for -debugify-level", t);
}

dbgify_out :: (fmt: string, args: .. Any) {
    if dbgify_opts.quiet return;
    s := tprint(fmt, ..args);
    write_string(s, to_standard_error = true);
}

// isFunctionSkipped: declarations and functions without an exact definition (GlobalValue::hasExactDefinition)
dbgify_function_skipped :: (f: Value_Id) -> bool {
    if is_declaration(f) return true;
    l := glob(f).linkage;
    if l == .AVAILABLE_EXTERNALLY return true;          // isDeclarationForLinker
    if l == .WEAK_ODR || l == .LINKONCE_ODR return true; // mayBeDerefined
    if gv_is_interposable(f) return true;
    if fn_has_fn_attr(f, .NoBuiltin) return true;        // isNobuiltinFnDef
    return false;
}

// findTerminatingInstruction: a musttail call or a deoptimize call before the terminator count as the terminator
dbgify_terminating_inst :: (bb: Value_Id) -> Value_Id {
    i := block_terminating_must_tail_call(bb);
    if i != NONE return i;
    i = block_terminating_deoptimize_call(bb);
    if i != NONE return i;
    return block_terminator(bb);
}

named_md_find :: (name: string) -> s64 {
    for ir.named_md if it.name == name return it_index;
    return -1;
}
// Module::getOrInsertNamedMetadata
named_md_get_or_insert :: (name: string) -> s64 {
    k := named_md_find(name);
    if k >= 0 return k;
    n: Named_Md;
    n.name = copy_string(name);
    array_add(*ir.named_md, n);
    return ir.named_md.count - 1;
}

// (module_has_flag = Module::getModuleFlag(Key) != nullptr is in pass_sroa.jai)

// llvm::applyDebugifyMetadata over all functions of the module (ModuleDebugify)
apply_debugify_metadata :: () -> bool {
    banner := "ModuleDebugify: ";
    if named_md_find("llvm.dbg.cu") >= 0 {
        dbgify_out("%Skipping module with debug info\n", banner);
        return false;
    }
    DW_ATE_UNSIGNED :: 7;
    DW_LANG_C :: 2;

    // getCachedDIType: one DIBasicType per alloc size in bits
    type_cache: Table(u64, Md_Id); type_cache.allocator = temp;
    cached_di_type :: (cache: *Table(u64, Md_Id), ty: Type_Id) -> Md_Id {
        size: u64 = 0;
        if type_is_sized(ty) size = dl_type_alloc_size(ty) * 8;
        found, t := table_find(cache, size);
        if found return t;
        name := tprint("ty%", size);
        // DIBasicType::get(DW_TAG_base_type, Name, Size, 0, Encoding, 0, 0, FlagZero)
        t = di_get(.BASIC_TYPE, false, .[NONE, NONE, md_str_or_null(name), md_i64(size), NONE],
                   .[DW_TAG_BASE_TYPE, 0, 0, DW_ATE_UNSIGNED, 0, 0, 0]);
        table_add(cache, size, t);
        return t;
    }

    next_line: u64 = 1;
    next_var: u64 = 1;
    file := di_get(.FILE, false, .[md_str_or_null(ir.module_id), md_str_or_null("/"), NONE, NONE], .[0]);
    // createCompileUnit(DW_LANG_C, File, "debugify", isOptimized=true, Flags "", RV 0): FullDebug, split inlining
    cu := di_get(.COMPILE_UNIT, true,
        .[file, md_str_or_null("debugify"), NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
        .[DW_LANG_C, 0, 0, 0, 1, 0, 1, 0, 1, 0, 0, 0]);
    cuk := named_md_get_or_insert("llvm.dbg.cu");
    array_add(*ir.named_md[cuk].ops, cu);

    i32_zero := const_int(ir.t_i32, 0);
    for f: ir.m_functions {
        if dbgify_function_skipped(f) continue;
        inserted := false;
        // createSubroutineType(getOrCreateTypeArray({}))
        sp_type := di_get(.SUBROUTINE_TYPE, false, .[NONE, NONE, NONE, NONE, NONE, md_tuple(.[], false)], .[0, 0]);
        spflags: u64 = SPFLAG_DEFINITION | SPFLAG_OPTIMIZED;
        l := glob(f).linkage;
        if l == .PRIVATE || l == .INTERNAL spflags |= SPFLAG_LOCAL_TO_UNIT;
        name := md_str_or_null(vname(f));
        sp := di_get(.SUBPROGRAM, true,
            .[file, NONE, name, name, sp_type, cu, NONE, NONE, NONE, NONE, NONE, NONE, NONE],
            .[next_line, next_line, 0, 0, 0, spflags, cast(u64) ifx dbgify_opts.atoms then 1 else 0]);
        set_metadata(f, 0, sp);
        retained: [..] Md_Id; retained.allocator = temp;

        insert_dbg_val :: (tmpl: Value_Id, before: Value_Id, sp: Md_Id, file: Md_Id, next_var: *u64,
                           retained: *[..] Md_Id, cache: *Table(u64, Md_Id), i32_zero: Value_Id) {
            name := tprint("%", next_var.*);
            next_var.* += 1;
            v := tmpl;
            if vtype(tmpl) == ir.t_void v = i32_zero;
            loc := get_metadata(tmpl, 0);
            // createAutoVariable(SP, Name, File, Line, Ty, AlwaysPreserve=true)
            var := di_get(.LOCAL_VARIABLE, false, .[sp, md_str_or_null(name), file, cached_di_type(cache, vtype(v)), NONE],
                          .[diloc_line(loc), 0, 0, 0]);
            array_add(retained, var);
            dbgr_insert_value_before(v, var, di_get(.EXPRESSION, false, .[], .[]), loc, before);
        }

        for bb: fn_blocks(f) {
            for i: block_insts(bb) {
                group: u64 = ifx dbgify_opts.atoms then next_line else 0;
                rank: u64 = ifx dbgify_opts.atoms then cast(u64) 1 else 0;
                line := next_line;
                next_line += 1;
                set_metadata(i, 0, di_location_get(line, 1, sp, NONE, 0, group, rank));
            }
            if dbgify_opts.level_locations_only continue;
            if block_is_eh_pad(bb) continue;
            last := dbgify_terminating_inst(bb);
            // the insertion point (records are appended to the records of the instruction at it)
            pt := block_first_insertion_pt(bb);
            i := block(bb).first;
            while i != last {
                nx := inst(i).next;
                if vtype(i) != ir.t_void {
                    if inst_op(i) != .PHI && !is_eh_pad(i) pt = nx;
                    insert_dbg_val(i, pt, sp, file, *next_var, *retained, *type_cache, i32_zero);
                    inserted = true;
                }
                i = nx;
            }
        }
        if !dbgify_opts.level_locations_only && !inserted {
            term := dbgify_terminating_inst(fn_entry(f));
            insert_dbg_val(term, term, sp, file, *next_var, *retained, *type_cache, i32_zero);
        }
        // DIBuilder::finalizeSubprogram: retainedNodes = the preserved variables (if any were tracked)
        if retained.count {
            RETAINED_NODES_OP :: 7;
            t := md_tuple(retained, false);
            ir.md_ops[ir.mds[sp].ops + RETAINED_NODES_OP] = t;
            md_add_use(t, sp, RETAINED_NODES_OP);
        }
    }

    nmd := named_md_get_or_insert("llvm.debugify");
    array_add(*ir.named_md[nmd].ops, md_tuple(.[md_value(const_int(ir.t_i32, next_line - 1))], false));
    array_add(*ir.named_md[nmd].ops, md_tuple(.[md_value(const_int(ir.t_i32, next_var - 1))], false));

    if !module_has_flag("Debug Info Version") {
        // Module::addModuleFlag(Warning, "Debug Info Version", DEBUG_METADATA_VERSION)
        k := named_md_get_or_insert("llvm.module.flags");
        flag := md_tuple(.[md_value(const_int(ir.t_i32, 2)), md_string("Debug Info Version"), md_value(const_int(ir.t_i32, 3))], false);
        array_add(*ir.named_md[k].ops, flag);
    }
    return true;
}

// diagnoseMisSizedDbgValue
dbgify_mis_sized :: (r: u32) -> bool {
    rec := dbgr(r);
    if rec.expr != NONE && ir.mds[rec.expr].nints != 0 return false;
    if rec.loc == NONE || ir.mds[rec.loc].kind != .VALUE return false;
    v := ir.mds[rec.loc].value;
    ty := vtype(v);
    vsize: u64 = 0;
    if type_is_sized(ty) vsize = dl_type_alloc_size(ty) * 8;
    ok, var_size := divar_size_bits(rec.var);
    if !vsize || !ok return false;
    bad := false;
    if is_int_type(ty) {
        known, signed := divar_signedness(rec.var);
        if known && signed bad = vsize < var_size;
    } else bad = vsize != var_size;
    if bad {
        // DbgVariableRecord::print: the record line without indentation and newline
        printer_begin_function(value_function(rec.owner), true);
        start := W.buf.count;
        print_dbg_record(rec.*);
        text := copy_string(slice_of_buf(start),, allocator = temp);
        W.buf.count = start;
        text = trim(text);
        dbgify_out("ERROR: dbg.value operand has size %, but its variable has size %: %\n", vsize, var_size, text);
    }
    return bad;
}

// checkDebugifyMetadata (module, Strip = false, no statistics)
check_debugify_metadata :: (pass_name: string, banner: string) -> bool {
    nk := named_md_find("llvm.debugify");
    if nk < 0 {
        dbgify_out("%: Skipping module without debugify metadata\n", banner);
        return false;
    }
    operand :: (nk: s64, idx: s64) -> u64 {
        n := ir.named_md[nk].ops[idx];
        return const_int_zext(ir.mds[md_op(n, 0)].value);
    }
    orig_lines := operand(nk, 0);
    orig_vars := operand(nk, 1);
    has_errors := false;
    missing_lines := NewArray(cast(s64) orig_lines, bool,, allocator = temp);
    missing_vars := NewArray(cast(s64) orig_vars, bool,, allocator = temp);
    for * missing_lines it.* = true;
    for * missing_vars it.* = true;
    for f: ir.m_functions {
        if dbgify_function_skipped(f) continue;
        for bb: fn_blocks(f) for i: block_insts(bb) {
            dl := get_metadata(i, 0);
            if dl != NONE && diloc_line(dl) != 0 {
                if diloc_line(dl) <= orig_lines missing_lines[diloc_line(dl) - 1] = false;   // BitVector::reset
                continue;
            }
            if inst_op(i) != .PHI && dl == NONE
                dbgify_out("WARNING: Instruction with empty DebugLoc in function % --%\n", vname(f), inst_to_string(i));
        }
        for bb: fn_blocks(f) for i: block_insts(bb) {
            r := inst(i).records;
            while r != 0 {
                rec := dbgr(r);
                if rec.kind == .VALUE || rec.kind == .ASSIGN {
                    var_name := md_str_of(di_op(rec.var, 1));
                    v, ok := string_to_int(var_name);
                    bad := dbgify_mis_sized(r);
                    if !bad && ok && v >= 1 && v <= cast(s64) orig_vars missing_vars[v - 1] = false;
                    has_errors |= bad;
                }
                r = rec.next;
            }
        }
    }
    for missing_lines if it dbgify_out("WARNING: Missing line %\n", it_index + 1);
    for missing_vars if it dbgify_out("WARNING: Missing variable %\n", it_index + 1);
    dbgify_out("%", banner);
    if pass_name.count dbgify_out(" [%]", pass_name);
    dbgify_out(": %\n", ifx has_errors then "FAIL" else "PASS");
    return false;
}

// NewPMDebugifyPass::run (synthetic mode, no ApplyToMF): preserves only CFG analyses
run_debugify_pass :: () {
    apply_debugify_metadata();
    pa := preserved_cfg();
    for ir.m_functions if !is_declaration(it) fam_invalidate(it, pa);
    printer_note_ir_changed();
}
