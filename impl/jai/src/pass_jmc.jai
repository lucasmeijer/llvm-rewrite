// JMCInstrumenter: a port of llvm/lib/CodeGen/JMCInstrumenter.cpp ("jmc-instrumenter": a
// __CheckForDebuggerJustMyCode(flag) call at every function entry, one flag per source file, ELF and MSVC flavours),
// with the DIBuilder calls it makes (createBasicType, createGlobalVariableExpression, finalize: the CU's globals).

// getFlagName
jmc_flag_name :: (sp: Md_Id, x86_fastcall: bool) -> string {
    file := di_op(sp, 0);
    dir, fname: string;   // DIScope::getDirectory / getFilename: "" without a file
    if file != NONE { dir = md_str_of(di_op(file, 1)); fname = md_str_of(di_op(file, 0)); }
    win := sp_has_root_name(dir, true) || contains(dir, "\\") || contains(fname, "\\");
    p := sp_append(dir, fname, win);
    p = sp_native(p, win);
    p = sp_remove_dots(p, true, win);
    suffix := copy_string(sp_filename(p, win),, temp);
    for i: 0..suffix.count - 1 if suffix[i] == #char "." suffix[i] = #char "@";
    p = sp_remove_filename(p, win);
    h: u32 = 5381;   // djbHash
    for i: 0..p.count - 1 h = (h << 5) + h + p[i];
    return tprint("%1%2_%3", ifx x86_fastcall then "_" else "__", jmc_hex8(h), suffix);
}

// utohexstr(X, /*LowerCase=*/false, /*Width=*/8)
jmc_hex8 :: (h: u32) -> string {
    r := alloc_string(8,, temp);
    for i: 0..7 r[7 - i] = "0123456789ABCDEF"[(h >> (4 * i)) & 15];
    return r;
}

// attachDebugInfo: DIBuilder(M, false, CU) + createGlobalVariableExpression + finalize
jmc_attach_debug_info :: (gv: Value_Id, sp: Md_Id) {
    cu := di_op(sp, 5);
    if cu == NONE fatal("internal: jmc-instrumenter: a subprogram without a unit");
    DINODE_FLAG_ARTIFICIAL :: 64;
    dty := dib_basic_type("unsigned char", 8, DWATE_UNSIGNED_CHAR, DINODE_FLAG_ARTIFICIAL);
    name := md_str_or_null(vname(gv));
    dgv := di_get(.GLOBAL_VARIABLE, true, .[cu, name, di_op(sp, 0), dty, NONE, NONE, NONE, NONE, NONE], .[0, 1, 1, 0]);
    gve := di_get(.GLOBAL_VARIABLE_EXPRESSION, false, .[dgv, di_get(.EXPRESSION, false, .[], .[])], .[]);
    gv_add_debug_info(gv, gve);
    // finalize: replaceGlobalVariables(AllGVs), AllGVs = the CU's globals + the new expression
    all: [..] Md_Id; all.allocator = temp;
    old := di_op(cu, 6);
    if old != NONE for k: 0..cast(s64) md_nops(old) - 1 array_add(*all, md_op(old, cast(u32) k));
    array_add(*all, gve);
    all_t := md_tuple(all, false);   // md_tuple can grow ir.md_ops: build it before indexing
    ir.md_ops[ir.mds[cu].ops + 6] = all_t;
}

// createDefaultCheckFunction
jmc_create_default_check_function :: (x86_fastcall: bool) -> Value_Id {
    ft := type_func(ir.t_void, .[type_ptr(0)], false);
    f := new_function(ft, ifx x86_fastcall then "_JustMyCode_Default" else "__JustMyCode_Default", dl.program_as);
    array_add(*ir.m_functions, f);
    glob(f).unnamed_addr = 2;
    fn_add_param_attr_kind(f, 0, .NoUndef);
    if x86_fastcall fn_add_param_attr_kind(f, 0, .InReg);
    bb := create_block(f, "");
    block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
    return f;
}

jmc_run :: () -> Preserved {
    t := san_triple();
    is_msvc := t.os == .Win32 && t.env == .MSVC;
    is_elf := t.obj == .ELF;
    if !is_elf && !is_msvc fatal("jmc-instrumenter: Unsupported triple for JMC");
    x86_fastcall := is_msvc && t.arch == .x86;
    section := ifx is_elf then ".data.just.my.code" else ".msvcjmc";
    check: Value_Id = NONE;
    ft := type_func(ir.t_void, .[type_ptr(0)], false);
    saved: Table(Md_Id, Value_Id); saved.allocator = temp;
    changed := false;
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if is_declaration(f) continue;
        sp := fn_subprogram(f);
        if sp == NONE continue;
        found, flag := table_find(*saved, sp);
        if !found {
            name := jmc_flag_name(sp, x86_fastcall);
            flag = lookup_global(name);
            if flag == NONE || vkind(flag) != .GLOBAL_VAR {
                flag = gv_create(ir.t_i8, false, .INTERNAL, const_int(ir.t_i8, 1), name, NONE, 0, dl.globals_as);
                glob(flag).section = section;
                glob(flag).align = 1;
                glob(flag).unnamed_addr = 2;
                jmc_attach_debug_info(flag, sp);
            }
            table_set(*saved, sp, flag);
        }
        if check == NONE {
            def := jmc_create_default_check_function(x86_fastcall);
            if is_elf {
                set_name(def, "__CheckForDebuggerJustMyCode");
                gv_set_linkage(def, .WEAK_ANY);
                check = def;
            } else {
                if lookup_global("__CheckForDebuggerJustMyCode") != NONE fatal("jmc-instrumenter: JMC instrument more than once?");
                cf := module_get_or_insert_function("__CheckForDebuggerJustMyCode", ft);
                glob(cf).unnamed_addr = 2;
                fn_add_param_attr_kind(cf, 0, .NoUndef);
                if x86_fastcall {
                    glob(cf).cc = 65;
                    fn_add_param_attr_kind(cf, 0, .InReg);
                }
                check = cf;
                append_to_used(def);
                c := get_comdat(vname(def));
                ir.comdats[c].kind = 0;   // Comdat::Any
                glob(def).comdat = c;
                opt := tconcat("/alternatename:__CheckForDebuggerJustMyCode=", vname(def));
                nm := lk_get_or_insert_named_md("llvm.linker.options");
                array_add(*ir.named_md[nm].ops, md_tuple(.[md_string(opt)], false));
            }
        }
        // CallInst::Create(..., F.begin()->getFirstInsertionPt()): no debug location, before the records there
        entry := fn_entry(f);
        ci := new_inst(.CALL, ir.t_void, 2);
        inst(ci).ty2 = ft;
        set_op(ci, 0, flag);
        set_op(ci, 1, check);
        insert_at_position(ci, entry, block_first_insertion_pt(entry), true);
        call_add_param_attr_kind(ci, 0, .NoUndef);
        if x86_fastcall {
            inst(ci).cc = 65;
            call_add_param_attr_kind(ci, 0, .InReg);
        }
        changed = true;
    }
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
