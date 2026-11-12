// llc's IR pipeline up to instruction selection: port of llvm/tools/llc/llc.cpp (argument handling, the
// SetDataLayout callback, setFunctionAttributes) and of the IR half of llvm/lib/CodeGen/TargetPassConfig.cpp
// (addISelPasses -> addIRPasses, addCodeGenPrepare, addPassesToHandleExceptions, addISelPrepare) with
// llvm/lib/Target/X86/X86TargetMachine.cpp (X86PassConfig::addIRPasses / addISelPrepare).
//
// The legacy pass manager runs consecutive function passes as one FPPassManager: every pass on the first function,
// then every pass on the second, ... Module passes (PreISelIntrinsicLowering) split the function pass runs. Each pass
// is a `Cg_Pass` value and `cg_run_function_pass` is the switch that runs it on one function.

Cg_Pass :: enum u8 {
    OBJC_ARC_CONTRACT;
    PRE_ISEL_INTRINSIC_LOWERING;   // module pass
    EXPAND_IR_INSTS;
    ATOMIC_EXPAND;
    X86_LOWER_AMX_INTRINSICS;
    X86_LOWER_AMX_TYPE;
    LOOP_SIMPLIFY;                 // required by the loop pass manager below
    LSR_LOOP_PM;                   // LPPassManager { canon-freeze, IVUsers, loop-reduce }
    GC_LOWERING;
    SHADOW_STACK_GC_LOWERING;      // a module pass in LLVM, but it only looks at functions with gc "shadow-stack"
    UNREACHABLE_BLOCK_ELIM;
    CONSTANT_HOISTING;
    REPLACE_WITH_VECLIB;
    PARTIALLY_INLINE_LIBCALLS;
    POST_INLINE_EE_INSTRUMENT;
    SCALARIZE_MASKED_MEM_INTRIN;
    EXPAND_REDUCTIONS;
    INTERLEAVED_ACCESS;
    X86_PARTIAL_REDUCTION;
    INDIRECTBR_EXPAND;
    CODEGENPREPARE;
    DWARF_EH_PREPARE;
    INLINE_ASM_PREPARE;
    SAFE_STACK;
    STACK_PROTECTOR;
}

llc_opts: struct {
    opt_level := 2;          // CodeGenOptLevel: 0 None, 1 Less, 2 Default, 3 Aggressive
    disable_lsr: bool;       // -disable-lsr
    disable_cgp: bool;       // -disable-cgp
    disable_consthoist: bool;  // -disable-constant-hoisting
    disable_partial_libcall_inlining: bool;  // -disable-partial-libcall-inlining
    disable_expand_reductions: bool;  // -disable-expand-reductions
    disable_replace_with_veclib: bool;   // -disable-replace-with-veclib
    disable_interleaved_access: bool;  // -lower-interleaved-accesses=false
}

// The pass list of TargetPassConfig::addISelPasses for X86 up to (not including) x86-isel.
cg_build_pipeline :: (out: *[..] Cg_Pass) {
    o := llc_opts.opt_level;
    // TargetPassConfig::addISelPasses: ObjCARCContract (-O1+), PreISelIntrinsicLowering, ExpandIRInsts, addIRPasses()
    // (X86PassConfig: AtomicExpand, the two AMX passes, TargetPassConfig::addIRPasses, then InterleavedAccess and
    // X86PartialReduction at -O1+, IndirectBrExpand), addCodeGenPrepare, addPassesToHandleExceptions (DwarfEHPrepare
    // on ELF), addISelPrepare (InlineAsmPrepare, SafeStack, StackProtector). SelectOptimize is off
    // (-disable-select-optimize defaults to true), LoopTermFold too (-enable-loop-term-fold=false).
    if o > 0 array_add(out, .OBJC_ARC_CONTRACT);
    array_add(out, .PRE_ISEL_INTRINSIC_LOWERING);
    array_add(out, .EXPAND_IR_INSTS);
    array_add(out, .ATOMIC_EXPAND);
    array_add(out, .X86_LOWER_AMX_INTRINSICS);
    array_add(out, .X86_LOWER_AMX_TYPE);
    if o > 0 && !llc_opts.disable_lsr { array_add(out, .LOOP_SIMPLIFY); array_add(out, .LSR_LOOP_PM); }
    array_add(out, .GC_LOWERING);
    array_add(out, .SHADOW_STACK_GC_LOWERING);
    array_add(out, .UNREACHABLE_BLOCK_ELIM);
    if o > 0 && !llc_opts.disable_consthoist array_add(out, .CONSTANT_HOISTING);
    if o > 0 && !llc_opts.disable_replace_with_veclib array_add(out, .REPLACE_WITH_VECLIB);
    if o > 0 && !llc_opts.disable_partial_libcall_inlining array_add(out, .PARTIALLY_INLINE_LIBCALLS);
    array_add(out, .POST_INLINE_EE_INSTRUMENT);
    array_add(out, .SCALARIZE_MASKED_MEM_INTRIN);
    if !llc_opts.disable_expand_reductions array_add(out, .EXPAND_REDUCTIONS);
    if o > 0 {
        if !llc_opts.disable_interleaved_access array_add(out, .INTERLEAVED_ACCESS);
        array_add(out, .X86_PARTIAL_REDUCTION);
    }
    array_add(out, .INDIRECTBR_EXPAND);
    if o > 0 && !llc_opts.disable_cgp array_add(out, .CODEGENPREPARE);
    array_add(out, .DWARF_EH_PREPARE);
    array_add(out, .INLINE_ASM_PREPARE);
    array_add(out, .SAFE_STACK);
    array_add(out, .STACK_PROTECTOR);
}
cg_is_module_pass :: (p: Cg_Pass) -> bool { return p == .PRE_ISEL_INTRINSIC_LOWERING; }

cg_run_pipeline :: (passes: [] Cg_Pass) {
    i := 0;
    while i < passes.count {
        if cg_is_module_pass(passes[i]) {
            cg_run_module_pass(passes[i]);
            i += 1;
            continue;
        }
        j := i;
        while j < passes.count && !cg_is_module_pass(passes[j]) j += 1;
        // FPPassManager::runOnModule: functions in module order (a snapshot: passes don't add definitions)
        fns: [..] Value_Id;
        for ir.m_functions array_add(*fns, it);
        for f: fns {
            if vkind(f) != .FUNCTION || is_declaration(f) continue;
            for k: i..j-1 {
                pa := cg_run_function_pass(passes[k], f);
                fam_invalidate(f, pa);
                reset_temporary_storage();
            }
        }
        array_free(fns);
        i = j;
    }
}

cg_run_module_pass :: (p: Cg_Pass) {
    if p == {
        case .PRE_ISEL_INTRINSIC_LOWERING;
            if pre_isel_intrinsic_lowering_run() {
                for ir.m_functions fam_invalidate(it, PRESERVE_NONE);
            }
        case; fatal("internal: % is not a module pass", p);
    }
    reset_temporary_storage();
}

// skipFunction(F) of a legacy FunctionPass: optnone (OptBisect is not used by llc here)
cg_skip_function :: (f: Value_Id) -> bool { return fn_has_fn_attr(f, .OptimizeNone); }

cg_run_function_pass :: (p: Cg_Pass, f: Value_Id) -> Preserved {
    if p == {
        case .OBJC_ARC_CONTRACT; return objc_arc_contract_check(f);
        case .EXPAND_IR_INSTS; return expand_ir_insts_run(f);
        case .ATOMIC_EXPAND; return atomic_expand_run(f);
        case .X86_LOWER_AMX_INTRINSICS; return x86_lower_amx_check(f, true);
        case .X86_LOWER_AMX_TYPE; return x86_lower_amx_check(f, false);
        case .LOOP_SIMPLIFY; return loop_simplify_run(f);
        case .LSR_LOOP_PM; return lsr_loop_pm_run(f);
        case .GC_LOWERING; return gc_lowering_check(f);
        case .SHADOW_STACK_GC_LOWERING; return PRESERVE_ALL;   // checked by gc_lowering_check
        case .UNREACHABLE_BLOCK_ELIM; return unreachable_block_elim_run(f);
        case .CONSTANT_HOISTING; return consthoist_run(f);
        case .REPLACE_WITH_VECLIB; return replace_with_veclib_run(f);
        case .PARTIALLY_INLINE_LIBCALLS; return partially_inline_libcalls_run(f);
        case .POST_INLINE_EE_INSTRUMENT; return ee_instrument_run(f, "ee-instrument<post-inline>");   // PostInlineEntryExitInstrumenter
        case .SCALARIZE_MASKED_MEM_INTRIN; return scalarize_masked_mem_intrin_run(f);
        case .EXPAND_REDUCTIONS; return expand_reductions_run(f);
        case .INTERLEAVED_ACCESS; return interleaved_access_run(f);
        case .X86_PARTIAL_REDUCTION; return x86_partial_reduction_run(f);
        case .INDIRECTBR_EXPAND; return indirectbr_expand_run(f);
        case .CODEGENPREPARE; return codegenprepare_run(f);
        case .DWARF_EH_PREPARE; return dwarf_eh_prepare_run(f);
        case .INLINE_ASM_PREPARE; return inline_asm_prepare_run(f);
        case .SAFE_STACK; return safe_stack_check(f);
        case .STACK_PROTECTOR; return stack_protector_check(f);
        case .PRE_ISEL_INTRINSIC_LOWERING; fatal("internal: pre-isel-intrinsic-lowering is a module pass");
    }
    return PRESERVE_ALL;
}

// codegen target triple: llc's TheTriple (the module's, else -mtriple, else the default triple). TTI queries use it
// even when the module itself has no triple (TargetLibraryInfo still uses the module's).
LLC_DEFAULT_TRIPLE :: "x86_64-unknown-linux-gnu";

// The first `target triple = "..."` among the module's leading target definitions (what LLParser has parsed when it
// calls the DataLayout callback).
llc_prescan_triple :: (src: string) -> string {
    s := src;
    while s.count {
        nl := find_index_from_left(s, #char "\n");
        line := ifx nl < 0 then s else slice(s, 0, nl);
        s = ifx nl < 0 then "" else slice(s, nl + 1, s.count - nl - 1);
        t := trim(line);
        if t.count == 0 || t[0] == #char ";" continue;
        if begins_with(t, "source_filename") continue;
        if begins_with(t, "target") {
            rest := trim(slice(t, 6, t.count - 6));
            if begins_with(rest, "triple") {
                q := find_index_from_left(rest, #char "\"");
                if q < 0 return "";
                r := slice(rest, q + 1, rest.count - q - 1);
                e := find_index_from_left(r, #char "\"");
                if e < 0 return "";
                return slice(r, 0, e);
            }
            continue;
        }
        break;
    }
    return "";
}

llc_main :: () {
    tool_name = "llc";
    args := get_command_line_arguments();
    input := "";
    output := "-";
    stop_before := "";
    i := 1;
    while i < args.count {
        a := args[i];
        i += 1;
        if a == "-o" { if i >= args.count fatal("-o needs a file"); output = args[i]; i += 1; continue; }
        if a == "-O0" || a == "--O0" { llc_opts.opt_level = 0; continue; }
        if a == "-O1" || a == "--O1" { llc_opts.opt_level = 1; continue; }
        if a == "-O2" || a == "--O2" { llc_opts.opt_level = 2; continue; }
        if a == "-O3" || a == "--O3" { llc_opts.opt_level = 3; continue; }
        if begins_with(a, "-stop-before=") || begins_with(a, "--stop-before=") {
            stop_before = slice(a, find_index_from_left(a, #char "=") + 1, a.count - find_index_from_left(a, #char "=") - 1);
            continue;
        }
        if a == "-mtriple" || a == "--mtriple" { if i >= args.count fatal("-mtriple needs a value"); opts.mtriple = args[i]; i += 1; continue; }
        if a == "-disable-lsr" || a == "--disable-lsr" { llc_opts.disable_lsr = true; continue; }
        if a == "-disable-cgp" || a == "--disable-cgp" { llc_opts.disable_cgp = true; continue; }
        if a == "-disable-constant-hoisting" || a == "--disable-constant-hoisting" { llc_opts.disable_consthoist = true; continue; }
        if a == "-disable-partial-libcall-inlining" || a == "--disable-partial-libcall-inlining" { llc_opts.disable_partial_libcall_inlining = true; continue; }
        if a == "-disable-expand-reductions" || a == "--disable-expand-reductions" { llc_opts.disable_expand_reductions = true; continue; }
        if a == "-disable-replace-with-veclib" || a == "--disable-replace-with-veclib" { llc_opts.disable_replace_with_veclib = true; continue; }
        if begins_with(a, "-") && a != "-" {
            if parse_cl_opt(a) continue;
            fatal("unsupported option '%'", a);
        }
        input = a;
    }
    if stop_before != "x86-isel" {
        if stop_before.count fatal("-stop-before=% is not supported (only -stop-before=x86-isel)", stop_before);
        fatal("code generation (assembly output) is not implemented; only -stop-before=x86-isel is supported");
    }
    if input.count == 0 fatal("no input file");
    if input == "-" fatal("reading from stdin is not supported");
    src, ok := read_entire_file(input);
    if !ok fatal("could not open input file '%'", input);
    // llc.cpp SetDataLayout: the target's data layout replaces the module's
    tt := ifx opts.mtriple.count then normalize_triple(opts.mtriple) else llc_prescan_triple(src);
    if tt.count == 0 tt = LLC_DEFAULT_TRIPLE;
    if !tti_is_x86_triple(tt) fatal("target triple '%' is not supported (only x86)", tt);
    dl, dl_ok := compute_default_datalayout(tt);
    if !dl_ok fatal("no data layout for target triple '%'", tt);
    cl_data_layout = dl;
    ir_init();
    ir.module_id = input;
    parse_module(src, input);
    if opts.mtriple.count ir.triple = normalize_triple(opts.mtriple);
    codegen_triple = ifx ir.triple.count then ir.triple else tt;
    if !tti_is_x86_triple(codegen_triple) fatal("target triple '%' is not supported (only x86)", codegen_triple);
    if !triple_is_x86_64_elf(codegen_triple) fatal("target triple '%' is not supported (only x86-64 ELF)", codegen_triple);
    tti_create_target_machine();
    opt_set_function_attributes();
    if ir.source_filename.count == 0 && !saw_source_filename ir.source_filename = input;
    passes: [..] Cg_Pass;
    cg_build_pipeline(*passes);
    cg_run_pipeline(passes);
    text := print_module_fresh();
    if output == "-" write_string(text);
    else if !write_entire_file(output, text) fatal("could not write '%'", output);
}

triple_is_x86_64_elf :: (t: string) -> bool {
    tr := triple_parse(t);
    return tr.arch == .x86_64 && tr.obj == .ELF && tr.env != .GNUX32;
}
