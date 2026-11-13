// The IR Verifier. Ported from llvm/lib/IR/Verifier.cpp (class Verifier, VerifierSupport of VerifierInternal.h,
// verifyModule / verifyFunction, VerifierPass / VerifierAnalysis), with the TBAA verifier (TBAAVerifier, same file),
// the convergence-control verifier (llvm/lib/IR/ConvergenceVerifier.cpp, include/llvm/IR/
// GenericConvergenceVerifierImpl.h) and how opt drives it (tools/opt/optdriver.cpp: the input check and
// "input module is broken!", NewPMDriver.cpp: the VerifierPass at the end of the pipeline, -verify-each through
// StandardInstrumentations.cpp VerifyInstrumentation, lib/IR/AutoUpgrade.cpp UpgradeDebugInfo: broken debug info
// is stripped with "warning: ignoring invalid debug info in <file>").
//
// Files: verifier.jai (state, diagnostics, the module/function drivers, global values, functions, blocks and
// non-call instructions, EH pads, dominance), verifier_md.jai (metadata: generic, debug info, TBAA, !prof and the
// instruction attachments, module flags), verifier_calls.jai (calls, attributes, intrinsics, inline asm,
// statepoints, musttail, the convergence verifier).
//
// Data-oriented: the Verifier object is the global `vf` (one run at a time); LLVM's pointer sets are stamp arrays
// indexed by Value_Id / Md_Id (`vf.gen` is bumped per run, `vf.bb_gen` per block), maps are Tables. The C++ `Check`
// macro is `vcheck` (prints, marks the module broken, returns from the caller), `CheckDI` is `vcheck_di`.
//
// Diagnostics are printed the way VerifierSupport::Write does: instructions with Value::print through the verifier's
// own ModuleSlotTracker (`vst`, below: module slots once, a function's slots when it is incorporated, metadata
// slots accumulate over the run and are never purged), other values with printAsOperand(PrintType=true), metadata
// with Metadata::print (`!N = <body>`), types as " <type>".

// ---------------------------------------------------------------- the verifier's ModuleSlotTracker

// vst_need: something to process before the next slot lookup (printer.jai calls vst_lazy at every lookup); the
// module part (with all metadata) is processed at the first lookup, a function's local slots at the first lookup
// after it was incorporated, like SlotTracker::initializeIfNeeded.
vst: struct {
    active: bool;
    module_done: bool;
    types_done: bool;
    fn: Value_Id = NONE;        // ModuleSlotTracker::F
    pending: Value_Id = NONE;   // incorporated, not processed yet
};
vst_need := false;

vst_lazy :: inline () { if vst_need vst_flush(); }

vst_flush :: () {
    vst_need = false;
    vst_types();
    if !vst.module_done {
        // ModuleSlotTracker(&M) initializes all metadata (ShouldInitializeAllMetadata defaults to true): every
        // function's metadata gets its slot when the module is processed, in function order
        vst.module_done = true;
        process_module();
        for g: ir.m_functions process_function(g);
        for W.ftouched W.fslot[it] = -1;
        W.ftouched.count = 0;
    }
    if vst.pending != NONE {
        f := vst.pending;
        vst.pending = NONE;
        process_function(f);   // fresh local slots (its metadata already has slots)
    }
}

// TypePrinting (numbered struct types) is set up at the first print, not per run
vst_types :: () { if !vst.types_done { vst.types_done = true; type_printing_init(); } }

vst_begin :: () {
    printer_reset();
    print_state.dirty = true;
    vst = .{};
    vst.active = true;
    vst_need = true;
}

vst_end :: () {
    vst.active = false;
    vst_need = false;
    printer_reset();
    print_state.dirty = true;
    current_function = NONE;
}

// ModuleSlotTracker::incorporateFunction
vst_incorporate :: (f: Value_Id) {
    if vst.fn == f return;
    vst.fn = f;
    // purgeFunction: the local slots of the previous function are gone right away
    ensure_slot_arrays();
    for W.ftouched W.fslot[it] = -1;
    W.ftouched.count = 0;
    vst.pending = f;
    vst_need = true;
    current_function = f;
}

// ---------------------------------------------------------------- diagnostics (VerifierSupport)

VArg_Kind :: enum u8 { VALUE; MD; TYPE; NAMED_MD; RECORD; UINT; TEXT; MODULE; LOC_TYPE; FN_DECL; }
VArg :: struct {
    kind: VArg_Kind;
    id: u32 = NONE;       // Value_Id / Md_Id / Type_Id / named md index / record index (1-based)
    u: u64;
    s: string;
}
vq_val :: inline (v: Value_Id) -> VArg { r: VArg; r.kind = .VALUE; r.id = v; return r; }
vq_md :: inline (m: Md_Id) -> VArg { r: VArg; r.kind = .MD; r.id = m; return r; }
vq_ty :: inline (t: Type_Id) -> VArg { r: VArg; r.kind = .TYPE; r.id = t; return r; }
vq_nmd :: inline (n: s64) -> VArg { r: VArg; r.kind = .NAMED_MD; r.id = cast(u32) n; return r; }
vq_rec :: inline (rec: u32) -> VArg { r: VArg; r.kind = .RECORD; r.id = rec; return r; }
vq_uint :: inline (u: u64) -> VArg { r: VArg; r.kind = .UINT; r.u = u; return r; }
vq_text :: inline (s: string) -> VArg { r: VArg; r.kind = .TEXT; r.s = s; return r; }   // already formatted, with '\n'
vq_mod :: inline () -> VArg { r: VArg; r.kind = .MODULE; return r; }
vq_loc_type :: inline (k: Dbg_Record_Kind) -> VArg { r: VArg; r.kind = .LOC_TYPE; r.u = cast(u64) k; return r; }
vq_fn_decl :: inline (f: Value_Id) -> VArg { r: VArg; r.kind = .FN_DECL; r.id = f; return r; }

vf_err :: (s: string) { if vf.os write_string(s, to_standard_error = true); }

// Write(const Value *) etc.
vf_write :: (a: VArg) {
    if a.kind == {
      case .VALUE;
        if a.id == NONE return;
        v := a.id;
        start := W.buf.count;
        if vkind(v) == .INST {
            f: Value_Id = NONE;
            b := inst(v).parent;
            if b != NONE f = block(b).parent;
            if f != NONE vst_incorporate(f);
            print_instruction(v);
        } else {
            vst_lazy();
            write_operand(v, true);
        }
        outc(#char "\n");
        vf_err(slice_of_buf(start));
        W.buf.count = start;
      case .MD;
        if a.id == NONE return;
        start := W.buf.count;
        vf_print_metadata(a.id);
        outc(#char "\n");
        vf_err(slice_of_buf(start));
        W.buf.count = start;
      case .TYPE;
        if a.id == NONE return;
        vf_err(" ");
        vf_err(vf_type_string(a.id));
      case .NAMED_MD;
        start := W.buf.count;
        vst_lazy();
        nm := *ir.named_md[a.id];
        outc(#char "!");
        print_metadata_identifier(nm.name);
        out(" = !{");
        for nm.ops {
            if it_index > 0 out(", ");
            if it == NONE { out("null"); continue; }
            write_md_operand(it, false);
        }
        out("}\n\n");
        vf_err(slice_of_buf(start));
        W.buf.count = start;
      case .RECORD;
        if a.id == 0 return;
        r := *ir.dbg_records[a.id - 1];
        if r.owner != NONE {
            b := inst(r.owner).parent;
            if b != NONE && block(b).parent != NONE vst_incorporate(block(b).parent);
        }
        vst_lazy();
        start := W.buf.count;
        print_dbg_record(r.*);   // printDbgRecordLine: "    " + record + "\n"; Write prints the record and '\n'
        s := slice_of_buf(start);
        vf_err(slice(s, 4, s.count - 4));
        W.buf.count = start;
      case .UINT;
        vf_err(tprint("%\n", a.u));
      case .TEXT;
        vf_err(a.s);
      case .MODULE;
        vf_err(tprint("; ModuleID = '%'\n", ir.module_id));
      case .LOC_TYPE;
        k := cast(Dbg_Record_Kind) a.u;
        if k == {
            case .VALUE; vf_err("value"); case .DECLARE; vf_err("declare"); case .DECLARE_VALUE; vf_err("declare_value");
            case .ASSIGN; vf_err("assign"); case; vf_err("any");
        }
      case .FN_DECL;
        // Printable PrintDecl([&F](raw_ostream &OS) { F.print(OS); }): a fresh SlotTracker, then the declaration
        vf_err(vf_function_decl_string(a.id));
    }
}

// Type::print(OS): a named struct type is followed by its body ("%T = type { i32 }")
vf_type_string :: (t: Type_Id) -> string {
    vst_types();
    s := type_to_string(t);
    r := ir.types[t];
    if r.kind == .STRUCT && !(r.flags & TYF_LITERAL) {
        start := W.buf.count;
        out(" = type ");
        print_struct_body(t);
        s = tconcat(s, slice_of_buf(start));
        W.buf.count = start;
    }
    return s;
}

// Metadata::print(OS, MST, M)
vf_print_metadata :: (m: Md_Id) {
    vst_lazy();
    r := ir.mds[m];
    if is_inline_md(m) { write_di_node(m); return; }
    if is_md_node(m) {
        found, s := table_find(*W.md_slot, m);
        if found { outc(#char "!"); out_s64(s); }
        else if is_di(m, .LOCATION) write_di_node(m);
        else out("<badref>");   // LLVM prints the node's address here
        out(" = ");
        if r.distinct out("distinct ");
        if r.kind == .SPECIAL write_di_node(m); else write_md_tuple(m);
        return;
    }
    if r.kind == .STRING { out("!\""); print_escaped_string(r.str); outc(#char "\""); return; }
    write_operand(r.value, true);
}

// F.print(OS) of a declaration: AssemblyWriter::printFunction with a fresh SlotTracker
vf_function_decl_string :: (f: Value_Id) -> string {
    save_fn := vst.fn; save_pending := vst.pending; save_done := vst.module_done; save_need := vst_need;
    saved_w := W;
    W = .{};
    vst.active = false; vst_need = false;
    type_printing_init();
    process_module();
    start := W.buf.count;
    print_function(f);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W = saved_w;
    vst.active = true; vst.fn = save_fn; vst.pending = save_pending; vst.module_done = save_done; vst_need = save_need;
    current_function = save_fn;
    return s;
}

check_failed :: (msg: string, args: ..VArg) {
    vf.fail_count += 1;
    vf_err(msg); vf_err("\n");
    vf.broken = true;
    for args vf_write(it);
}
di_check_failed :: (msg: string, args: ..VArg) {
    vf.fail_count += 1;
    vf_err(msg); vf_err("\n");
    if vf.treat_di_as_error vf.broken = true;
    vf.broken_di = true;
    for args vf_write(it);
}

// Check(C, ...) / CheckDI(C, ...): on failure print and return from the calling visit function. The message and
// the values are Code, evaluated only when the check fails (like the C++ macros' Twine and arguments).
vcheck :: (vc_cond: bool, $vc_msg: Code, $vc_args: ..Code) #expand {
    if !vc_cond {
        #insert -> string { return vf_check_call_text("check_failed", vc_args.count); }
        `return;
    }
}
vcheck_di :: (vc_cond: bool, $vc_msg: Code, $vc_args: ..Code) #expand {
    if !vc_cond {
        #insert -> string { return vf_check_call_text("di_check_failed", vc_args.count); }
        `return;
    }
}
// the call `<fn>(#insert msg, #insert args[0], ...);`
vf_check_call_text :: (fn: string, n: s64) -> string {
    sb: String_Builder;
    append(*sb, fn);
    append(*sb, "(#insert vc_msg");
    for k: 0..n-1 print_to_builder(*sb, ", #insert vc_args[%]", k);
    append(*sb, ");");
    return builder_to_string(*sb);
}

// ---------------------------------------------------------------- state

Frame_Escape :: struct { f: Value_Id; escaped: u32; max_recovered: u32; }
Tbaa_Summary :: struct { invalid: bool; bit_width: u32; }

Verifier_State :: struct {
    os: bool = true;                 // OS != nullptr
    broken: bool;
    broken_di: bool;
    treat_di_as_error: bool = true;

    gen: u32;                        // stamp of the current run for the module-wide sets
    md_seen: [..] u32;               // MDNodes
    cexpr_seen: [..] u32;            // ConstantExprVisited
    gv_seen: [..] u32;               // GlobalValueVisited
    bb_gen: u32;
    in_block: [..] u32;              // InstsInThisBlock (== bb_gen)

    sp_attach: Table(Md_Id, Value_Id);         // DISubprogramAttachments
    frame_escape: [..] Frame_Escape;           // FrameEscapeInfo
    sibling_funclet: [..] [2] Value_Id;        // SiblingFuncletInfo (MapVector: pad -> terminator)
    deopt_decls: [..] Value_Id;                // DeoptimizeDeclarations
    debug_fn_args: [..] Md_Id;                 // DebugFnArgs
    noalias_decls: [..] Value_Id;              // NoAliasScopeDecls
    landing_pad_ty: Type_Id = NONE;            // LandingPadResultTy
    saw_frame_escape: bool;
    has_debug_info: bool;

    fn: Value_Id = NONE;             // function being verified
    dt: *Dom_Tree;                   // its DominatorTree, computed on first use (LLVM computes it up front)
    eh_colors_done: bool;            // BlockEHFuncletColors computed for fn
    eh_colors: Table(Value_Id, [..] Value_Id);

    tbaa_base: Table(Md_Id, Tbaa_Summary);     // TBAAVerifier::TBAABaseNodes
    tbaa_scalar: Table(Md_Id, bool);           // TBAAVerifier::TBAAScalarNodes

    // GenericConvergenceVerifier<SSAContext>
    conv_tokens: Table(Value_Id, Value_Id);    // Tokens (instruction -> token definition)
    conv_kind: u8;                   // 0 none, 1 controlled, 2 uncontrolled
    conv_seen_first: bool;           // SeenFirstConvOp

    have_logical_ptr_flag: bool;     // the "require-logical-pointer" module flag (read once per run)
    logical_ptr_flag: u64;
    kind_reqd_wg: u32;               // md kind ids looked up by name (NONE: not registered)
    kind_amdgpu_lanes: u32;
    iid_cache: [..] s32;
    fail_count: u64;                 // failed checks so far (to tell whether a cached computation passed)             // Function::getIntrinsicID per value id (-1 = not computed)
    cu_visited: [..] Md_Id;          // CUVisited
    tbaa_ok: Table(Md_Id, bool);     // access tags whose struct-path walk succeeded (the walk only depends on the tag)
    attrs_ok: Table(u64, bool);      // call-site (attribute list, function type) pairs that verified without failures

    cc_failed: bool;                 // a Check in the inlined calling-convention switch of visitFunction failed
    inst_md_failed: bool;            // a Check of visitInstruction's metadata part failed (returns from visitInstruction)
}

vf: Verifier_State;

stamp_get :: inline (arr: *[..] u32, i: u32) -> u32 { if i >= arr.count return 0; return arr.data[i]; }
stamp_set :: inline (arr: *[..] u32, i: u32, g: u32) {
    if i >= arr.count {
        n := arr.count;
        want := ifx i + 1 > n * 2 then cast(s64) i + 1 else n * 2;
        array_resize(arr, want, initialize = false);
        memset(arr.data + n, 0, (want - n) * size_of(u32));
    }
    arr.data[i] = g;
}
// SmallPtrSet::insert(...).second
md_seen_insert :: inline (m: Md_Id) -> bool {
    if stamp_get(*vf.md_seen, m) == vf.gen return false;
    stamp_set(*vf.md_seen, m, vf.gen);
    return true;
}

vf_reset_run :: () {
    vf.have_logical_ptr_flag, vf.logical_ptr_flag = vf_module_flag_int("require-logical-pointer");
    vf.kind_reqd_wg = md_kind_id_lookup("reqd_work_group_size");
    vf.kind_amdgpu_lanes = md_kind_id_lookup("amdgpu.expected.active.lanes");
    table_reset(*vf.tbaa_ok);
    table_reset(*vf.attrs_ok);
    vf.iid_cache.count = 0;
    vf.gen += 1;
    if vf.gen == 0 { vf.gen = 1; memset(vf.md_seen.data, 0, vf.md_seen.count * 4); memset(vf.cexpr_seen.data, 0, vf.cexpr_seen.count * 4); memset(vf.gv_seen.data, 0, vf.gv_seen.count * 4); }
    vf.broken = false;
    vf.broken_di = false;
    table_reset(*vf.sp_attach);
    vf.frame_escape.count = 0;
    vf.cu_visited.count = 0;
    vf.deopt_decls.count = 0;
    table_reset(*vf.tbaa_base);
    table_reset(*vf.tbaa_scalar);
}

vf_dt :: () -> *Dom_Tree {
    if !vf.dt {
        vf.dt = dt_new(false);
        dt_recalculate(vf.dt, vf.fn);
    }
    return vf.dt;
}

// ---------------------------------------------------------------- entry points

// llvm::verifyModule(M, OS, BrokenDebugInfo): returns true if the module is broken. With want_broken_di, broken
// debug info is not an error (it is reported in the second result) — UpgradeDebugInfo and VerifierAnalysis use that.
verify_module :: (want_broken_di := false, os := true) -> (broken: bool, broken_di: bool) {
    vst_begin();
    defer vst_end();
    vf.os = os;
    vf.treat_di_as_error = !want_broken_di;
    vf_reset_run();
    broken := false;
    for f: ir.m_functions if !vf_verify_function(f) broken = true;
    if !vf_verify_module_level() broken = true;
    return broken, vf.broken_di;
}

// llvm::verifyFunction(F, OS)
verify_function :: (f: Value_Id) -> bool {
    vst_begin();
    defer vst_end();
    vf.os = true;
    vf.treat_di_as_error = true;
    vf_reset_run();
    return !vf_verify_function(f);
}

// Verifier::verify(const Function &F)
vf_verify_function :: (f: Value_Id) -> bool {
    // every block needs a terminator before the CFG can be inspected
    for b: fn_blocks(f) {
        l := block(b).last;
        if l != NONE && is_terminator(inst_op(l)) continue;
        vf_err(tprint("Basic Block in function '%' does not have terminator!\n", vname(f)));
        start := W.buf.count;
        vst_lazy();
        write_operand(b, true);
        outc(#char "\n");
        vf_err(slice_of_buf(start));
        W.buf.count = start;
        return false;
    }
    vf.fn = f;
    if vf.dt { dt_free(vf.dt); vf.dt = null; }
    defer { if vf.dt { dt_free(vf.dt); vf.dt = null; } vf.fn = NONE; }
    vf.eh_colors_done = false;
    table_reset(*vf.conv_tokens);
    vf.conv_kind = 0;
    saw_tokens := false;

    vf.broken = false;
    vf_visit_function(f);
    for b: fn_blocks(f) {
        vf_visit_basic_block(b);
        for i: block_insts(b) {
            vf_visit(i);
            if vf_conv_op(i) != .NONE || table_contains(*vf.conv_tokens, i) saw_tokens = true;
        }
    }
    vf_verify_sibling_funclet_unwinds();
    if saw_tokens || vf.conv_tokens.count > 0 vf_conv_verify(f);

    vf.debug_fn_args.count = 0;
    vf.landing_pad_ty = NONE;
    vf.saw_frame_escape = false;
    vf.sibling_funclet.count = 0;
    vf_verify_noalias_scope_decl();
    vf.noalias_decls.count = 0;
    return !vf.broken;
}

// Verifier::verify() (the module)
vf_verify_module_level :: () -> bool {
    vf.broken = false;
    for f: ir.m_functions if vf_iid(f) == VI_experimental_deoptimize array_add(*vf.deopt_decls, f);
    vf_verify_frame_recover_indices();
    for g: ir.m_globals vf_visit_global_variable(g);
    for a: ir.m_aliases vf_visit_global_alias(a);
    for i: ir.m_ifuncs vf_visit_global_ifunc(i);
    for nm, nmi: ir.named_md vf_visit_named_md(nmi);
    for c: ir.comdats vf_visit_comdat(c);
    vf_visit_module_flags();
    vf_visit_module_idents("llvm.ident", "incorrect number of operands in llvm.ident metadata",
        "invalid value for llvm.ident metadata entry operand(the operand should be a string)");
    vf_visit_module_idents("llvm.commandline", "incorrect number of operands in llvm.commandline metadata",
        "invalid value for llvm.commandline metadata entry operand(the operand should be a string)");
    vf_visit_module_errno_tbaa();
    vf_verify_compile_units();
    vf_verify_deoptimize_calling_convs();
    table_reset(*vf.sp_attach);
    return !vf.broken;
}

// ---------------------------------------------------------------- the opt driver

// optdriver.cpp after parsing: verifyModule(*M, &errs()) unless -disable-verify
opt_verify_input :: (input: string) {
    broken := verify_module();
    if broken {
        write_string(tprint("opt: %: error: input module is broken!\n", input), to_standard_error = true);
        exit(1);
    }
}

// report_fatal_error: "LLVM ERROR: <msg>", then LLVM aborts with a crash report
verifier_fatal :: (msg: string) {
    write_string(tprint("LLVM ERROR: %\n", msg), to_standard_error = true);
    exit(134);
}

// VerifierAnalysis result of the module (cached while no pass changes the IR; RequireAnalysisPass<VerifierAnalysis>
// computes it, VerifierPass uses it)
verifier_analysis: struct { valid: bool; ir_broken: bool; di_broken: bool; };
verifier_note_ir_changed :: inline () { verifier_analysis.valid = false; }

verifier_module_result :: () -> (bool, bool) {
    if !verifier_analysis.valid {
        b, d := verify_module(want_broken_di = true);
        verifier_analysis = .{true, b, d};
    }
    return verifier_analysis.ir_broken, verifier_analysis.di_broken;
}

// VerifierPass::run(Module &)
run_verifier_pass_module :: () {
    b, d := verifier_module_result();
    if b || d verifier_fatal("Broken module found, compilation aborted!");
}
// VerifierPass::run(Function &)
run_verifier_pass_function :: (f: Value_Id) {
    if verify_function(f) verifier_fatal("Broken function found, compilation aborted!");
}

// ---------------------------------------------------------------- global values

// forEachUser(&GV, GlobalValueVisited, ...): every instruction / function user must be in this module. With one
// module per process that always holds; the walk only fills GlobalValueVisited like LLVM's does.
vf_visit_global_value :: (gv: Value_Id) {
    g := glob(gv);
    k := vkind(gv);
    decl := is_declaration(gv);
    vcheck(!decl || gv_has_valid_declaration_linkage(gv), "Global is external, but doesn't have external or weak linkage!", vq_val(gv));

    if k == .GLOBAL_VAR || k == .FUNCTION || k == .IFUNC {
        assoc := get_metadata(gv, MDV_ASSOCIATED);
        if assoc != NONE {
            vcheck(ir.mds[assoc].nops == 1, "associated metadata must have one operand", vq_val(gv), vq_md(assoc));
            op0 := md_op(assoc, 0);
            vcheck(op0 != NONE, "associated metadata must have a global value", vq_val(gv), vq_md(assoc));
            vcheck(ir.mds[op0].kind == .VALUE, "associated metadata must be ValueAsMetadata", vq_val(gv), vq_md(assoc));
            val := ir.mds[op0].value;
            vcheck(is_ptr_type(vtype(val)), "associated value must be pointer typed", vq_val(gv), vq_md(assoc));
            stripped := vf_strip_pointer_casts_and_aliases(val);
            vcheck(is_global_object(stripped) || is_constant_kind(vkind(stripped)), "associated metadata must point to a GlobalObject", vq_val(gv), vq_val(stripped));
            vcheck(stripped != gv, "global values should not associate to themselves", vq_val(gv), vq_md(assoc));
        }
        abs := get_metadata(gv, MDV_ABSOLUTE_SYMBOL);
        if abs != NONE vf_verify_range_like_metadata(gv, abs, vf_dl_int_ptr_type(vtype(gv)), .ABSOLUTE_SYMBOL);

        impl_kind: u32 = MDV_IMPLICIT_REF;
        has_ref := false;
        for vf_all_attachments(gv) if it.kind == impl_kind { has_ref = true; break; }
        if has_ref {
            vcheck(!decl, "ref metadata must not be placed on a declaration", vq_val(gv));
            for att: vf_all_attachments(gv) {
                if att.kind != impl_kind continue;
                m := att.md;
                vcheck(ir.mds[m].nops == 1, "ref metadata must have one operand", vq_val(gv), vq_md(m));
                op0 := md_op(m, 0);
                vcheck(op0 != NONE && ir.mds[op0].kind == .VALUE, "ref metadata must be ValueAsMetadata", vq_val(gv), vq_md(m));
                val := ir.mds[op0].value;
                vcheck(is_ptr_type(vtype(val)), "ref value must be pointer typed", vq_val(gv), vq_md(m));
                stripped := vf_strip_pointer_casts_and_aliases(val);
                vcheck(is_global_object(stripped) || is_constant_kind(vkind(stripped)), "ref metadata must point to a GlobalObject", vq_val(gv), vq_val(stripped));
                vcheck(stripped != gv, "values should not reference themselves", vq_val(gv), vq_md(m));
            }
        }

        props := get_metadata(gv, MDV_ELF_SECTION_PROPERTIES);
        if props != NONE {
            vcheck(ir.mds[props].nops == 2, "elf_section_properties metadata must have two operands", vq_val(gv), vq_md(props));
            t := md_op(props, 0);
            vcheck(t != NONE && ir.mds[t].kind == .VALUE && is_constant_kind(vkind(ir.mds[t].value)), "type field must be ConstantAsMetadata", vq_val(gv), vq_md(props));
            vcheck(vkind(ir.mds[t].value) == .C_INT, "type field must be ConstantInt", vq_val(gv), vq_md(props));
            e := md_op(props, 1);
            vcheck(e != NONE && ir.mds[e].kind == .VALUE && is_constant_kind(vkind(ir.mds[e].value)), "entsize field must be ConstantAsMetadata", vq_val(gv), vq_md(props));
            vcheck(vkind(ir.mds[e].value) == .C_INT, "entsize field must be ConstantInt", vq_val(gv), vq_md(props));
        }
    }

    vcheck(g.linkage != .APPENDING || k == .GLOBAL_VAR, "Only global variables can have appending linkage!", vq_val(gv));
    if g.linkage == .APPENDING {
        vcheck(k == .GLOBAL_VAR && type_kind(g.value_type) == .ARRAY, "Only global arrays can have appending linkage!", vq_val(ifx k == .GLOBAL_VAR then gv else NONE));
    }
    if gv_is_declaration_for_linker(gv) vcheck(g.comdat < 0 || k == .ALIAS, "Declaration may not be in a Comdat!", vq_val(gv));

    if g.dll == 2 vcheck(g.visibility != 1, "dllexport GlobalValue must have default or protected visibility", vq_val(gv));
    if g.dll == 1 {
        vcheck(g.visibility == 0, "dllimport GlobalValue must have default visibility", vq_val(gv));
        vcheck(!g.dso_local, "GlobalValue with DLLImport Storage is dso_local!", vq_val(gv));
        vcheck((decl && (g.linkage == .EXTERNAL || g.linkage == .EXTERN_WEAK)) || g.linkage == .AVAILABLE_EXTERNALLY,
            "Global is marked as dllimport, but not external", vq_val(gv));
    }
    // "GlobalValue with local linkage or non-default visibility must be dso_local!": GlobalValue::setLinkage and
    // setVisibility make such a value dso_local, so LLVM can't produce one from IR text or in its passes. Our
    // tables don't keep the bit for implicitly dso_local values (the printer derives it), so the check is the same
    // as LLVM's only when read as `dso_local || isImplicitDSOLocal()`, which always holds.

    // forEachUser: every reached user is in this module (one module per process); fill the visited set
    if stamp_get(*vf.gv_seen, gv) != vf.gen {
        stamp_set(*vf.gv_seen, gv, vf.gen);
        work: [..] Value_Id; work.allocator = temp;
        u := ir.v_first_use[gv];
        while u != NONE { array_add(*work, ir.u_user[u]); u = ir.u_next[u]; }
        while work.count {
            cur := pop(*work);
            if stamp_get(*vf.gv_seen, cur) == vf.gen continue;
            stamp_set(*vf.gv_seen, cur, vf.gen);
            ck := vkind(cur);
            if ck == .INST || ck == .FUNCTION continue;
            u = ir.v_first_use[cur];
            while u != NONE { array_add(*work, ir.u_user[u]); u = ir.u_next[u]; }
        }
    }
}

// fixed metadata kind ids (FixedMetadataKinds.def; ir_init registers them first, in this order)
MDV_PROF :: 2; MDV_FPMATH :: 3; MDV_RANGE :: 4; MDV_INVARIANT_LOAD :: 6; MDV_ALIAS_SCOPE :: 7; MDV_NOALIAS :: 8;
MDV_NONNULL :: 11; MDV_DEREFERENCEABLE :: 12; MDV_DEREFERENCEABLE_OR_NULL :: 13; MDV_INVARIANT_GROUP :: 16;
MDV_ALIGN :: 17; MDV_LOOP :: 18; MDV_ABSOLUTE_SYMBOL :: 21; MDV_ASSOCIATED :: 22; MDV_ACCESS_GROUP :: 25;
MDV_NOUNDEF :: 29; MDV_ANNOTATION :: 30; MDV_MEMPROF :: 34; MDV_CALLSITE :: 35; MDV_KCFI_TYPE :: 36;
MDV_DIASSIGNID :: 38; MDV_MMRA :: 40; MDV_NOALIAS_ADDRSPACE :: 41; MDV_CALLEE_TYPE :: 42; MDV_NOFREE :: 43;
MDV_CAPTURES :: 44; MDV_ALLOC_TOKEN :: 45; MDV_IMPLICIT_REF :: 46; MDV_NOFPCLASS :: 47; MDV_INLINE_HISTORY :: 49;
MDV_ELF_SECTION_PROPERTIES :: 50; MDV_MEM_CACHE_HINT :: 52;
#run {
    assert(FIXED_MD_KINDS[MDV_MEM_CACHE_HINT] == "mem.cache_hint" && FIXED_MD_KINDS[MDV_IMPLICIT_REF] == "implicit.ref");
    assert(FIXED_MD_KINDS[MDV_NOFPCLASS] == "nofpclass" && FIXED_MD_KINDS[MDV_CAPTURES] == "captures");
    assert(FIXED_MD_KINDS[MDV_DIASSIGNID] == "DIAssignID" && FIXED_MD_KINDS[MDV_ASSOCIATED] == "associated");
}

is_global_object :: inline (v: Value_Id) -> bool { k := vkind(v); return k == .GLOBAL_VAR || k == .FUNCTION || k == .IFUNC; }

// GlobalValue::hasValidDeclarationLinkage (isValidDeclarationLinkage)
gv_has_valid_declaration_linkage :: (gv: Value_Id) -> bool {
    l := glob(gv).linkage;
    return l == .EXTERN_WEAK || l == .EXTERNAL;
}


vf_all_attachments :: (v: Value_Id) -> [] Kind_Md {
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(v, *mds);
    return mds;
}

// Value::stripPointerCastsAndAliases
vf_strip_pointer_casts_and_aliases :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    visited: [..] Value_Id; visited.allocator = temp;
    while true {
        for visited if it == v return v;
        array_add(*visited, v);
        k := vkind(v);
        if k == .ALIAS { a := op(v, 0); if a == NONE return v; v = a; continue; }
        if k == .INST || k == .C_EXPR {
            o := ifx k == .INST then inst_op(v) else cexpr(v).op;
            if o == .BITCAST || o == .ADDRSPACECAST { v = op(v, 0); continue; }
            if o == .GEP && gep_all_zero(v) { v = op(v, 0); continue; }
        }
        return v;
    }
    return v;
}

// DataLayout::getIntPtrType(GO->getType())
vf_dl_int_ptr_type :: (t: Type_Id) -> Type_Id {
    as := cast(u32) ir.types[scalar_type(t)].a;
    it := type_int(cast(u32) dl_ptr_spec(as).bits);
    if is_vector_type(t) return type_vector(type_count(t), it, type_kind(t) == .SVECTOR);
    return it;
}

vf_visit_global_variable :: (gv: Value_Id) {
    g := glob(gv);
    ty := g.value_type;
    if g.align vcheck(g.align <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(gv));
    if g.has_init {
        init := op(gv, 0);
        vcheck(vtype(init) == ty, "Global variable initializer type does not match global variable type!", vq_val(gv));
        vcheck(vf_type_is_sized(vtype(init)), "Global variable initializer must be sized", vq_val(gv));
        vf_visit_constant_exprs_recursively(init);
        if g.linkage == .COMMON {
            vcheck(is_null_value(init), "'common' global must have a zero initializer!", vq_val(gv));
            vcheck(!g.is_const, "'common' global may not be marked constant!", vq_val(gv));
            vcheck(g.comdat < 0, "'common' global may not be in a Comdat!", vq_val(gv));
        }
    }
    name := vname(gv);
    if name == "llvm.global_ctors" || name == "llvm.global_dtors" {
        vcheck(!g.has_init || g.linkage == .APPENDING, "invalid linkage for intrinsic global variable", vq_val(gv));
        vcheck(ir.v_first_use[gv] == NONE, "invalid uses of intrinsic global variable", vq_val(gv));
        if type_kind(ty) == .ARRAY {
            st := type_elem(ty);
            is_st := type_kind(st) == .STRUCT && !(ir.types[st].flags & TYF_OPAQUE);
            vcheck(is_st && (type_nsub(st) == 2 || type_nsub(st) == 3) && type_kind(type_sub(st, 0)) == .INT && type_int_width(type_sub(st, 0)) == 32 &&
                type_sub(st, 1) == type_ptr(dl.program_as), "wrong type for intrinsic global variable", vq_val(gv));
            vcheck(type_nsub(st) == 3, "the third field of the element type is mandatory, specify ptr null to migrate from the obsoleted 2-field form");
            vcheck(is_ptr_type(type_sub(st, 2)), "wrong type for intrinsic global variable", vq_val(gv));
        }
        if g.has_init && vkind(op(gv, 0)) == .C_ARRAY {
            init := op(gv, 0);
            for k: 0..cast(s64) nops(init) - 1 {
                s := op(init, cast(u32) k);
                if vkind(s) != .C_STRUCT || nops(s) != 3 continue;
                vcheck(vkind(op(s, 1)) != .C_PTRAUTH, "signing of ctors/dtors should be requested via module flags");
            }
        }
    }
    if name == "llvm.used" || name == "llvm.compiler.used" {
        vcheck(!g.has_init || g.linkage == .APPENDING, "invalid linkage for intrinsic global variable", vq_val(gv));
        vcheck(ir.v_first_use[gv] == NONE, "invalid uses of intrinsic global variable", vq_val(gv));
        if type_kind(ty) == .ARRAY {
            vcheck(is_ptr_type(type_elem(ty)), "wrong type for intrinsic global variable", vq_val(gv));
            if g.has_init {
                init := op(gv, 0);
                vcheck(vkind(init) == .C_ARRAY, "wrong initializer for intrinsic global variable", vq_val(init));
                for k: 0..cast(s64) nops(init) - 1 {
                    v := strip_pointer_casts(op(init, cast(u32) k));
                    vk := vkind(v);
                    vcheck(vk == .GLOBAL_VAR || vk == .FUNCTION || vk == .ALIAS, tprint("invalid % member", name), vq_val(v));
                    vcheck(vname(v).count > 0, tprint("members of % must be named", name), vq_val(v));
                }
            }
        }
    }
    // debug info attachments
    for att: vf_all_attachments(gv) {
        if att.kind != 0 continue;
        if is_di(att.md, .GLOBAL_VARIABLE_EXPRESSION) vf_visit_di_global_variable_expression(att.md);
        else vcheck_di(false, "!dbg attachment of global variable must be a DIGlobalVariableExpression");
    }
    vcheck(!type_is_scalable(ty), "Globals cannot contain scalable types", vq_val(gv));
    vcheck(!type_contains_non_global_target_ext(ty), tprint("Global @% has illegal target extension type", name), vq_ty(ty));
    if vf_type_is_sized(ty) {
        bits := dl_ptr_spec(g.addrspace).bits;   // getAddressSizeInBits
        size := dl_type_alloc_size(ty);          // GlobalVariable::getGlobalSize
        vcheck(bits >= 64 || size < (cast(u64) 1 << bits), "Global variable is too large to fit into the address space", vq_val(gv), vq_ty(ty));
    }
    if !g.has_init { vf_visit_global_value(gv); return; }
    vf_visit_constant_exprs_recursively(op(gv, 0));
    vf_visit_global_value(gv);
}

MAXIMUM_ALIGNMENT :: cast(u64) 1 << 32;   // Value::MaximumAlignment

vf_visit_aliasee_sub_expr :: (visited: *[..] Value_Id, ga: Value_Id, c: Value_Id) {
    if glob(ga).linkage == .AVAILABLE_EXTERNALLY {
        vcheck(is_global_value(vkind(c)) && glob(c).linkage == .AVAILABLE_EXTERNALLY,
            "available_externally alias must point to available_externally global value", vq_val(ga));
    }
    if is_global_value(vkind(c)) {
        if glob(ga).linkage != .AVAILABLE_EXTERNALLY
            vcheck(!gv_is_declaration_for_linker(c), "Alias must point to a definition", vq_val(ga));
        if vkind(c) == .ALIAS {
            seen := false;
            for visited.* if it == c { seen = true; break; }
            if !seen array_add(visited, c);
            vcheck(!seen, "Aliases cannot form a cycle", vq_val(ga));
            vcheck(!gv_is_interposable(c), "Alias cannot point to an interposable alias", vq_val(ga));
        } else {
            return;   // do not recurse into global initializers
        }
    }
    if vkind(c) == .C_EXPR vf_visit_constant_exprs_recursively(c);
    n := nops(c);
    if n > 0 for k: 0..n-1 {
        v := op(c, k);
        if v == NONE continue;
        if vkind(v) == .ALIAS vf_visit_aliasee_sub_expr(visited, ga, op(v, 0));
        else if is_constant_kind(vkind(v)) vf_visit_aliasee_sub_expr(visited, ga, v);
    }
}

vf_visit_global_alias :: (ga: Value_Id) {
    l := glob(ga).linkage;
    vcheck(l == .EXTERNAL || l == .INTERNAL || l == .PRIVATE || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .WEAK_ANY ||
        l == .WEAK_ODR || l == .AVAILABLE_EXTERNALLY,
        "Alias should have private, internal, linkonce, weak, linkonce_odr, weak_odr, external, or available_externally linkage!", vq_val(ga));
    aliasee := op(ga, 0);
    vcheck(aliasee != NONE, "Aliasee cannot be NULL!", vq_val(ga));
    vcheck(vtype(ga) == vtype(aliasee), "Alias and aliasee types should match!", vq_val(ga));
    vcheck(is_global_value(vkind(aliasee)) || vkind(aliasee) == .C_EXPR, "Aliasee should be either GlobalValue or ConstantExpr", vq_val(ga));
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, ga);
    vf_visit_aliasee_sub_expr(*visited, ga, aliasee);
    vf_visit_global_value(ga);
}

vf_visit_global_ifunc :: (gi: Value_Id) {
    vf_visit_global_value(gi);
    for vf_all_attachments(gi) {
        vcheck_di(it.kind != 0, "an ifunc may not have a !dbg attachment", vq_val(gi));
        vcheck(it.kind != MDV_PROF, "an ifunc may not have a !prof attachment", vq_val(gi));
        vf_visit_md_node(it.md, false);
    }
    l := glob(gi).linkage;
    vcheck(l == .EXTERNAL || l == .INTERNAL || l == .PRIVATE || l == .LINKONCE_ANY || l == .LINKONCE_ODR || l == .WEAK_ANY || l == .WEAK_ODR,
        "IFunc should have private, internal, linkonce, weak, linkonce_odr, weak_odr, or external linkage!", vq_val(gi));
    // getResolverFunction: through constant expressions and aliases
    resolver := vf_strip_pointer_casts_and_aliases(op(gi, 0));
    vcheck(resolver != NONE && vkind(resolver) == .FUNCTION, "IFunc must have a Function resolver", vq_val(gi));
    vcheck(!gv_is_declaration_for_linker(resolver), "IFunc resolver must be a definition", vq_val(gi));
    vcheck(is_ptr_type(func_ret(glob(resolver).value_type)), "IFunc resolver must return a pointer", vq_val(gi));
    vcheck(vtype(op(gi, 0)) == type_ptr(glob(gi).addrspace), "IFunc resolver has incorrect type", vq_val(gi));
}

vf_visit_comdat :: (c: Comdat_Row) {
    // only COFF modules: a comdat's global value may not have private linkage
    if !triple_is_os_bin_format_coff(ir.triple) return;
    found, gv := table_find(*ir.m_symtab, c.name);
    if !found return;
    vcheck(glob(gv).linkage != .PRIVATE, "comdat global value has private linkage", vq_val(gv));
}

// Triple::isOSBinFormatCOFF: the object format is COFF (Windows targets without an explicit -elf/-macho environment)
triple_is_os_bin_format_coff :: (triple: string) -> bool {
    parts := split(triple, "-",, allocator = temp);
    if parts.count < 3 return false;
    os := parts[2];
    env := ifx parts.count > 3 then parts[3] else "";
    if ends_with(env, "elf") || ends_with(env, "macho") || ends_with(triple, "-elf") return false;
    if begins_with(os, "windows") || begins_with(os, "win32") || begins_with(os, "mingw32") || begins_with(os, "cygwin") || begins_with(os, "uefi") return true;
    return false;
}

// ---------------------------------------------------------------- constants

vf_visit_constant_exprs_recursively :: (entry: Value_Id) {
    if nops(entry) == 0 return;
    if stamp_get(*vf.cexpr_seen, entry) == vf.gen return;
    stamp_set(*vf.cexpr_seen, entry, vf.gen);
    stack: [..] Value_Id; stack.allocator = temp;
    array_add(*stack, entry);
    while stack.count {
        c := pop(*stack);
        k := vkind(c);
        if k == .C_EXPR vf_visit_constant_expr(c);
        if k == .C_PTRAUTH vf_visit_constant_ptr_auth(c);
        if is_global_value(k) continue;   // "Referencing global in another module!" can't happen with one module
        n := nops(c);
        if n > 0 for i: 0..n-1 {
            o := op(c, i);
            if o == NONE || !is_constant_kind(vkind(o)) continue;
            if stamp_get(*vf.cexpr_seen, o) == vf.gen continue;
            stamp_set(*vf.cexpr_seen, o, vf.gen);
            array_add(*stack, o);
        }
    }
}

vf_visit_constant_expr :: (ce: Value_Id) {
    o := cexpr(ce).op;
    if o == .BITCAST vcheck(cast_is_valid_bitcast(vtype(op(ce, 0)), vtype(ce)), "Invalid bitcast", vq_val(ce));
    else if o == .PTRTOADDR vf_check_ptr_to_addr(vtype(op(ce, 0)), vtype(ce), ce);
}

// ConstantPtrAuth operands: pointer, key, discriminator, address discriminator, deactivation symbol
vf_visit_constant_ptr_auth :: (c: Value_Id) {
    ptr := op(c, 0);
    vcheck(is_ptr_type(vtype(ptr)), "signed ptrauth constant base pointer must have pointer type");
    vcheck(vtype(c) == vtype(ptr), "signed ptrauth constant must have same type as its base pointer");
    vcheck(type_int_width(vtype(op(c, 1))) == 32, "signed ptrauth constant key must be i32 constant integer");
    vcheck(is_ptr_type(vtype(op(c, 3))), "signed ptrauth constant address discriminator must be a pointer");
    vcheck(type_int_width(vtype(op(c, 2))) == 64, "signed ptrauth constant discriminator must be i64 constant integer");
    ds := op(c, 4);
    vcheck(is_ptr_type(vtype(ds)), "signed ptrauth constant deactivation symbol must be a pointer");
    vcheck(is_global_value(vkind(ds)) || vkind(ds) == .C_NULL, "signed ptrauth constant deactivation symbol must be a global value or null");
}

// CastInst::castIsValid(Instruction::BitCast, SrcTy, DstTy)
cast_is_valid_bitcast :: (src: Type_Id, dst: Type_Id) -> bool {
    if !is_first_class(src) || !is_first_class(dst) || is_aggregate(src) || is_aggregate(dst) return false;
    sv := is_vector_type(src); dv := is_vector_type(dst);
    sp := is_ptr_type(scalar_type(src)); dp := is_ptr_type(scalar_type(dst));
    // you can't cast pointers to anything but pointers or bytes
    if (sp && type_kind(scalar_type(dst)) == .BYTE) || (type_kind(scalar_type(src)) == .BYTE && dp) return true;
    if sp != dp return false;
    if !sp {
        // getPrimitiveSizeInBits: a TypeSize, scalable or fixed
        return vf_primitive_size_bits(src) == vf_primitive_size_bits(dst) && (type_kind(src) == .SVECTOR) == (type_kind(dst) == .SVECTOR);
    }
    if ir.types[scalar_type(src)].a != ir.types[scalar_type(dst)].a return false;
    if sv && dv return vf_same_ec(src, dst);
    if sv return type_kind(src) == .VECTOR && type_count(src) == 1;
    if dv return type_kind(dst) == .VECTOR && type_count(dst) == 1;
    return true;
}

// Type::getPrimitiveSizeInBits (known minimum for scalable vectors)
vf_primitive_size_bits :: (t: Type_Id) -> u64 {
    k := type_kind(t);
    if k == .VECTOR || k == .SVECTOR return type_count(t) * vf_primitive_size_bits(type_elem(t));
    if k == .X86_AMX return 8192;
    return type_bits(t);
}
// Type::getScalarSizeInBits
vf_scalar_bits :: inline (t: Type_Id) -> u64 { return type_bits(scalar_type(t)); }

// Type::isSized(Visited) with the recursion guard for self-containing named structs
vf_type_is_sized :: (t: Type_Id) -> bool {
    visited: [..] Type_Id; visited.allocator = temp;
    return vf_type_is_sized_rec(t, *visited);
}
vf_type_is_sized_rec :: (t: Type_Id, visited: *[..] Type_Id) -> bool {
    k := type_kind(t);
    if k == .INT || k == .BYTE || is_fp_kind(k) || k == .PTR || k == .X86_AMX return true;
    if k == .ARRAY || k == .VECTOR || k == .SVECTOR return vf_type_is_sized_rec(type_elem(t), visited);
    if k == .STRUCT {
        if ir.types[t].flags & TYF_OPAQUE return false;
        // StructType::isSized: sized structs are cached (SCDB_IsSized), so the Visited set only stops a struct that
        // is being computed (one that contains itself)
        for visited.* if it == t return false;
        array_add(visited, t);
        defer visited.count -= 1;
        n := type_nsub(t);
        if n > 0 for i: 0..n-1 if !vf_type_is_sized_rec(type_sub(t, i), visited) return false;
        return true;
    }
    if k == .TARGET_EXT return type_kind(target_ext_layout_type(t)) != .VOID;
    return false;
}

// Type::containsNonGlobalTargetExtType / containsNonLocalTargetExtType (TargetExtType::CanBeGlobal / CanBeLocal)
type_contains_non_global_target_ext :: (t: Type_Id) -> bool { return vf_contains_target_ext(t, true); }
type_contains_non_local_target_ext :: (t: Type_Id) -> bool { return vf_contains_target_ext(t, false); }
vf_contains_target_ext :: (t: Type_Id, global: bool) -> bool {
    k := type_kind(t);
    if k == .TARGET_EXT {
        p := target_ext_properties(t);
        return (p & (ifx global then TEP_CAN_BE_GLOBAL else TEP_CAN_BE_LOCAL)) == 0;
    }
    if k == .ARRAY || k == .VECTOR || k == .SVECTOR return vf_contains_target_ext(type_elem(t), global);
    if k == .STRUCT {
        n := type_nsub(t);
        if n > 0 for i: 0..n-1 if vf_contains_target_ext(type_sub(t, i), global) return true;
    }
    return false;
}

// getTargetTypeInfo(TargetExtType) properties (lib/IR/Type.cpp)
TEP_HAS_ZERO_INIT :: 1; TEP_CAN_BE_GLOBAL :: 2; TEP_CAN_BE_LOCAL :: 4; TEP_IS_TOKEN_LIKE :: 8; TEP_CAN_BE_VECTOR_ELEMENT :: 16;
target_ext_properties :: (t: Type_Id) -> u32 {
    name := ir.types[t].name;
    if name == "spirv.Image" || name == "spirv.SignedImage" return TEP_CAN_BE_GLOBAL | TEP_CAN_BE_LOCAL;
    if name == "spirv.Type" return TEP_CAN_BE_GLOBAL | TEP_CAN_BE_LOCAL;
    if name == "spirv.IntegralConstant" || name == "spirv.Literal" return 0;
    if name == "spirv.Padding" return TEP_CAN_BE_GLOBAL;
    if begins_with(name, "spirv.") return TEP_HAS_ZERO_INIT | TEP_CAN_BE_GLOBAL | TEP_CAN_BE_LOCAL;
    if name == "aarch64.svcount" return TEP_HAS_ZERO_INIT | TEP_CAN_BE_LOCAL;
    if name == "riscv.vector.tuple" return TEP_CAN_BE_LOCAL | TEP_HAS_ZERO_INIT;
    if name == "dx.Padding" return TEP_CAN_BE_GLOBAL;
    if begins_with(name, "dx.") return TEP_CAN_BE_GLOBAL | TEP_CAN_BE_LOCAL | TEP_IS_TOKEN_LIKE;
    if name == "amdgcn.named.barrier" return TEP_CAN_BE_GLOBAL;
    if name == "amdgpu.stridemark" return TEP_IS_TOKEN_LIKE;
    if name == "llvm.test.vectorelement" return TEP_CAN_BE_LOCAL | TEP_CAN_BE_VECTOR_ELEMENT;
    if name == "wasm.funcref" || name == "wasm.externref" return TEP_HAS_ZERO_INIT | TEP_CAN_BE_GLOBAL | TEP_CAN_BE_LOCAL;
    return 0;
}

// Type::isTokenLikeTy: token, or a target extension type with the IsTokenLike property
type_is_token_like :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .TOKEN return true;
    if k == .TARGET_EXT return (target_ext_properties(t) & TEP_IS_TOKEN_LIKE) != 0;
    return false;
}

// ---------------------------------------------------------------- functions

vf_visit_function :: (f: Value_Id) {
    vf_visit_global_value(f);
    g := glob(f);
    ft := g.value_type;
    nargs := g.nargs;
    vcheck(g.linkage != .COMMON, "Functions may not have common linkage", vq_val(f));
    vcheck(func_nparams(ft) == nargs, "# formal arguments must match # of arguments for function type!", vq_val(f), vq_ty(ft));
    rt := func_ret(ft);
    vcheck(is_first_class(rt) || type_kind(rt) == .VOID || type_kind(rt) == .STRUCT, "Functions cannot return aggregate values!", vq_val(f));
    attrs := g.attrs;
    vcheck(!vf_has_param_attr_somewhere(attrs, .StructRet, true) || type_kind(rt) == .VOID, "Invalid struct return type!", vq_val(f));
    if g.align vcheck(g.align <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(f));
    vcheck(vf_attr_count_ok(attrs, func_nparams(ft)), "Attribute after last parameter!", vq_val(f));
    is_intrinsic := g.intrinsic;
    vf_verify_function_attrs(ft, attrs, f, is_intrinsic, false);
    vcheck(!attr_set_has(attr_list_fn(attrs), .Builtin), "Attribute 'builtin' can only be applied to a callsite.", vq_val(f));
    vcheck(!vf_attr_somewhere(attrs, .ElementType), "Attribute 'elementtype' can only be applied to a callsite.", vq_val(f));
    if attr_set_has(attr_list_fn(attrs), .Naked) {
        for i: 0..cast(s64) nargs - 1 {
            a := fn_arg(f, cast(u32) i);
            vcheck(ir.v_first_use[a] == NONE, "cannot use argument of naked function", vq_val(a));
        }
    }
    cc := g.cc;
    if cc == {
      case VCC_X86_INTR;
        vcheck(nargs == 0 || attr_set_has(attr_list_param(attrs, 0), .ByVal), "Calling convention parameter requires byval", vq_val(f));
      case VCC_AMDGPU_KERNEL; #through;
      case VCC_SPIR_KERNEL; #through;
      case VCC_AMDGPU_CS_CHAIN; #through;
      case VCC_AMDGPU_CS_CHAIN_PRESERVE;
        vcheck(type_kind(rt) == .VOID, "Calling convention requires void return type", vq_val(f));
        vf_check_amdgpu_cc_args(f, attrs);
        if vf.cc_failed { vf.cc_failed = false; return; }
        vcheck(!func_vararg(ft), "Calling convention does not support varargs or perfect forwarding!", vq_val(f));
      case VCC_AMDGPU_VS; #through;
      case VCC_AMDGPU_HS; #through;
      case VCC_AMDGPU_GS; #through;
      case VCC_AMDGPU_PS; #through;
      case VCC_AMDGPU_CS;
        vf_check_amdgpu_cc_args(f, attrs);
        if vf.cc_failed { vf.cc_failed = false; return; }
        vcheck(!func_vararg(ft), "Calling convention does not support varargs or perfect forwarding!", vq_val(f));
      case VCC_FAST; #through;
      case VCC_COLD; #through;
      case VCC_INTEL_OCL_BI; #through;
      case VCC_PTX_KERNEL; #through;
      case VCC_PTX_DEVICE;
        vcheck(!func_vararg(ft), "Calling convention does not support varargs or perfect forwarding!", vq_val(f));
      case VCC_AMDGPU_GFX_WHOLE_WAVE;
        vcheck(nargs > 0 && type_kind(vtype(fn_arg(f, 0))) == .INT && type_int_width(vtype(fn_arg(f, 0))) == 1, "Calling convention requires first argument to be i1", vq_val(f));
        vcheck(!attr_set_has(attr_list_param(attrs, 0), .InReg), "Calling convention requires first argument to not be inreg", vq_val(f));
        vcheck(!func_vararg(ft), "Calling convention does not support varargs or perfect forwarding!", vq_val(f));
    }
    for i: 0..cast(s64) nargs - 1 {
        a := fn_arg(f, cast(u32) i);
        at := vtype(a);
        vcheck(at == func_param(ft, cast(u32) i), "Argument value does not match function argument type!", vq_val(a), vq_ty(func_param(ft, cast(u32) i)));
        vcheck(is_first_class(at), "Function arguments must have first-class types!", vq_val(a));
        if !is_intrinsic {
            vcheck(type_kind(at) != .METADATA, "Function takes metadata but isn't an intrinsic", vq_val(a), vq_val(f));
            vcheck(!type_is_token_like(at), "Function takes token but isn't an intrinsic", vq_val(a), vq_val(f));
            vcheck(type_kind(at) != .X86_AMX, "Function takes x86_amx but isn't an intrinsic", vq_val(a), vq_val(f));
        }
        if attr_set_has(attr_list_param(attrs, cast(u32) i), .SwiftError) {
            vf_verify_swift_error_value(a);
        }
    }
    if !is_intrinsic {
        vcheck(!type_is_token_like(rt), "Function returns a token but isn't an intrinsic", vq_val(f));
        vcheck(type_kind(rt) != .X86_AMX, "Function returns a x86_amx but isn't an intrinsic", vq_val(f));
    }
    mds := vf_all_attachments(f);
    vf_verify_function_metadata(mds);
    // (AMDGPU function metadata checks only apply to amdgcn triples)
    // personality functions in another module can't exist

    if is_declaration(f) {
        for mds {
            vcheck_di(it.kind != 0 || !ir.mds[it.md].distinct, "function declaration may only have a unique !dbg attachment", vq_val(f));
            vcheck(it.kind != MDV_PROF, "function declaration may not have a !prof attachment", vq_val(f));
            vf_visit_md_node(it.md, true);
        }
        vcheck(!g.has_personality, "Function declaration shouldn't have a personality routine", vq_val(f));
    } else {
        vcheck(!is_intrinsic, "llvm intrinsics cannot be defined!", vq_val(f));
        entry := g.first_block;
        vcheck(!block_has_predecessors(entry), "Entry block to function must not have predecessors!", vq_val(entry));
        ba := vf_block_address_of(entry);
        if ba != NONE vcheck(!vf_constant_is_used(ba), "blockaddress may not be used with the entry block!", vq_val(entry));
        n_dbg := 0; n_prof := 0; n_kcfi := 0;
        kcfi_kind: u32 = MDV_KCFI_TYPE;
        for mds {
            allow_locs := false;
            if it.kind == 0 {
                n_dbg += 1;
                vcheck_di(n_dbg == 1, "function must have a single !dbg attachment", vq_val(f), vq_md(it.md));
                vcheck_di(is_di(it.md, .SUBPROGRAM), "function !dbg attachment must be a subprogram", vq_val(f), vq_md(it.md));
                vcheck_di(ir.mds[it.md].distinct, "function definition may only have a distinct !dbg attachment", vq_val(f));
                found, attached := table_find(*vf.sp_attach, it.md);
                vcheck_di(!found || attached == f, "DISubprogram attached to more than one function", vq_md(it.md), vq_val(f));
                table_set(*vf.sp_attach, it.md, f);
                allow_locs = true;
            } else if it.kind == MDV_PROF {
                n_prof += 1;
                vcheck(n_prof == 1, "function must have a single !prof attachment", vq_val(f), vq_md(it.md));
            } else if it.kind == kcfi_kind {
                n_kcfi += 1;
                vcheck(n_kcfi == 1, "function must have a single !kcfi_type attachment", vq_val(f), vq_md(it.md));
            }
            vf_visit_md_node(it.md, allow_locs);
        }
    }

    // an intrinsic may only be called directly
    if is_intrinsic {
        u := vf_intrinsic_address_taken_user(f);
        vcheck(u == NONE, "Invalid user of intrinsic instruction!", vq_val(u));
    }

    iid := vf_iid(f);
    if iid != NOT_INTRINSIC {
        otys: [..] Type_Id; otys.allocator = temp;
        msg: String_Builder; msg.allocator = temp;
        valid := intrinsic_signature_valid_msg(iid, ft, *otys, *msg);
        if !valid { m := builder_to_string(*msg,, allocator = temp); check_failed(m, vq_fn_decl(f)); return; }
        expected := vf_intrinsic_expected_name(iid, otys, f);
        vcheck(expected == vname(f), tprint("Intrinsic name not mangled correctly for type arguments! Should be: %", expected), vq_fn_decl(f));
    }

    sp := get_metadata(f, 0);
    vf.has_debug_info = sp != NONE && is_di(sp, .SUBPROGRAM);   // Function::getSubprogram: dyn_cast_or_null
    if !vf.has_debug_info return;
    vf_check_dbg_attachments_lead_to(f, sp);
}

vf_check_dbg_attachments_lead_to :: (f: Value_Id, sp_n: Md_Id) {
    seen: Table(Md_Id, bool); seen.allocator = temp;
    loop_kind: u32 = MDV_LOOP;
    visit :: (f: Value_Id, i: Value_Id, node: Md_Id, n: Md_Id, seen: *Table(Md_Id, bool)) {
        if node == NONE || !is_di(node, .LOCATION) return;
        if table_contains(seen, node) return;
        table_add(seen, node, true);
        parent := di_op(node, 0);
        vcheck_di(parent != NONE && di_is_local_scope(parent), "DILocation's scope must be a DILocalScope", vq_md(n), vq_val(f), vq_val(i), vq_md(node), vq_md(parent));
        scope := di_location_inlined_at_scope(node);
        vcheck(scope != NONE, "Failed to find DILocalScope", vq_md(node));
        if table_contains(seen, scope) return;
        table_add(seen, scope, true);
        sp := vf_di_local_scope_subprogram(scope);
        if scope != sp {
            if table_contains(seen, sp) return;
            table_add(seen, sp, true);
        }
        vcheck_di(di_subprogram_describes(sp, f), "!dbg attachment points at wrong subprogram for function", vq_md(n), vq_val(f), vq_val(i), vq_md(node), vq_md(scope), vq_md(sp));
    }
    for b: fn_blocks(f) for i: block_insts(b) {
        visit(f, i, get_metadata(i, 0), sp_n, *seen);
        lm := get_metadata(i, loop_kind);
        if lm != NONE for k: 1..cast(s64) ir.mds[lm].nops - 1 {
            o := md_op(lm, cast(u32) k);
            if is_md_node(o) visit(f, i, o, sp_n, *seen);
        }
        if vf.broken_di return;
    }
}

vf_check_amdgpu_cc_args :: (f: Value_Id, attrs: u32) {
    g := glob(f);
    if vf_has_param_attr_somewhere(attrs, .StructRet, true) { check_failed("Calling convention does not allow sret", vq_val(f)); vf.cc_failed = true; return; }
    if g.cc == VCC_SPIR_KERNEL return;
    stack_as := dl.alloca_as;
    for i: 0..cast(s64) g.nargs - 1 {
        pa := attr_list_param(attrs, cast(u32) i);
        if attr_set_has(pa, .ByVal) { check_failed("Calling convention disallows byval", vq_val(f)); vf.cc_failed = true; return; }
        if attr_set_has(pa, .Preallocated) { check_failed("Calling convention disallows preallocated", vq_val(f)); vf.cc_failed = true; return; }
        if attr_set_has(pa, .InAlloca) { check_failed("Calling convention disallows inalloca", vq_val(f)); vf.cc_failed = true; return; }
        if attr_set_has(pa, .ByRef) {
            if ir.types[vtype(fn_arg(f, cast(u32) i))].a == stack_as { check_failed("Calling convention disallows stack byref", vq_val(f)); vf.cc_failed = true; return; }
        }
    }
}

// The BlockAddress constant of a block, if one exists (BlockAddress::lookup)
vf_block_address_of :: (b: Value_Id) -> Value_Id {
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        if vkind(user) == .C_BLOCKADDR return user;
        u = ir.u_next[u];
    }
    return NONE;
}
// Constant::isConstantUsed: a use that is not a dead constant
vf_constant_is_used :: (c: Value_Id) -> bool {
    u := ir.v_first_use[c];
    while u != NONE {
        user := ir.u_user[u];
        if !is_constant_kind(vkind(user)) return true;
        if vf_constant_is_used(user) return true;
        u = ir.u_next[u];
    }
    return false;
}

// F.hasAddressTaken(&U, IgnoreCallbackUses=false, IgnoreAssumeLikeCalls=true, IgnoreLLVMUsed=false,
// IgnoreARCAttachedCall=true): the first user (in use-list order) that is not a direct call
vf_intrinsic_address_taken_user :: (f: Value_Id) -> Value_Id {
    u := ir.v_first_use[f];
    while u != NONE {
        user := ir.u_user[u];
        nu := ir.u_next[u];
        defer u = nu;
        if vkind(user) != .INST || !is_call_base(user) {
            // IgnoreAssumeLikeCalls: bitcasts / addrspace casts whose users are all assume-like calls
            if is_constant_kind(vkind(user)) && vkind(user) == .C_EXPR && (cexpr(user).op == .BITCAST || cexpr(user).op == .ADDRSPACECAST) {
                all_assume := true;
                v := ir.v_first_use[user];
                while v != NONE {
                    cu := ir.u_user[v];
                    if !(is_inst(cu) && inst_op(cu) == .CALL && is_assume_like_call(cu)) { all_assume = false; break; }
                    v = ir.u_next[v];
                }
                if all_assume continue;
            }
            return user;
        }
        // IgnoreARCAttachedCall: the function is the operand of a clang.arc.attachedcall bundle
        if vf_is_attached_call_operand(user, u) continue;
        // a use as an argument (not the callee) is an address-taking use
        if u != op_use(user, nops(user) - 1) return user;
        if inst(user).ty2 != glob(f).value_type return user;
    }
    return NONE;
}
is_assume_like_call :: (c: Value_Id) -> bool {
    f := call_called_function(c);
    if f == NONE return false;
    n := vname(f);
    return n == "llvm.assume" || begins_with(n, "llvm.lifetime.") || begins_with(n, "llvm.dbg.") || n == "llvm.experimental.noalias.scope.decl" ||
        n == "llvm.sideeffect" || n == "llvm.pseudoprobe" || begins_with(n, "llvm.invariant.") || begins_with(n, "llvm.var.annotation") ||
        begins_with(n, "llvm.ptr.annotation") || n == "llvm.donothing" || begins_with(n, "llvm.allow.");
}
vf_is_attached_call_operand :: (call: Value_Id, u: Use_Id) -> bool {
    nb := call_num_bundles(call);
    if nb == 0 return false;
    for k: 0..nb-1 {
        if call_bundle_tag(call, k) != "clang.arc.attachedcall" continue;
        b := ir.u32_pool[inst(call).idx + 3 * k + 1];
        e := ir.u32_pool[inst(call).idx + 3 * k + 2];
        idx := u - ir.v_ops[call];
        if idx >= b && idx < e return true;
    }
    return false;
}

// ---------------------------------------------------------------- blocks

vf_visit_basic_block :: (b: Value_Id) {
    vf.bb_gen += 1;
    if vf.bb_gen == 0 { vf.bb_gen = 1; memset(vf.in_block.data, 0, vf.in_block.count * 4); }
    vf.conv_seen_first = false;   // ConvergenceVerifyHelper.visit(BB)
    vcheck(block_terminator(b) != NONE, "Basic Block does not have terminator!", vq_val(b));
    first := block(b).first;
    if first != NONE && inst_op(first) == .PHI {
        preds: [..] Value_Id; preds.allocator = temp;
        block_predecessors(b, *preds);
        // llvm::sort(Preds) sorts by pointer; only the pairing with the sorted incoming blocks matters, and every
        // order is the same as long as both sides use it: sort by value id
        quick_sort(preds, (a: Value_Id, b: Value_Id) -> s64 { return cast(s64) a - cast(s64) b; });
        Pair :: struct { bb: Value_Id; v: Value_Id; }
        vals: [..] Pair; vals.allocator = temp;
        for pn: block_insts(b) {
            if inst_op(pn) != .PHI break;
            n := phi_num_incoming(pn);
            vcheck(n == preds.count, "PHINode should have one entry for each predecessor of its parent basic block!", vq_val(pn));
            vals.count = 0;
            for k: 0..cast(s64) n - 1 array_add(*vals, .{phi_block(pn, cast(u32) k), phi_value(pn, cast(u32) k)});
            // std::sort of (block, value) pairs (pointer order); value order among equal blocks only decides which
            // of two different values is printed first
            quick_sort(vals, (a: Pair, b: Pair) -> s64 {
                if a.bb != b.bb return cast(s64) a.bb - cast(s64) b.bb;
                return cast(s64) a.v - cast(s64) b.v;
            });
            for k: 0..vals.count - 1 {
                vcheck(k == 0 || vals[k].bb != vals[k - 1].bb || vals[k].v == vals[k - 1].v,
                    "PHI node has multiple entries for the same basic block with different incoming values!",
                    vq_val(pn), vq_val(vals[k].bb), vq_val(vals[k].v), vq_val(vals[k - 1].v));
                vcheck(vals[k].bb == preds[k], "PHI node entries do not match predecessors!", vq_val(pn), vq_val(vals[k].bb), vq_val(preds[k]));
            }
        }
    }
    // parent pointers are always consistent here; trailing debug records can't be parsed
}

// ---------------------------------------------------------------- instructions

vf_visit :: (i: Value_Id) {
    vf_visit_dbg_records(i);
    // "Operand is null": the parser never produces null operands
    r := inst(i);
    if r.op == {
      case .RET; vf_visit_return(i);
      case .BR; vf_visit_terminator(i);
      case .CONDBR;
        vcheck(vtype(op(i, 0)) == ir.t_i1, "Branch condition is not 'i1' type!", vq_val(i), vq_val(op(i, 0)));
        vf_visit_terminator(i);
      case .SWITCH; vf_visit_switch(i);
      case .INDIRECTBR; vf_visit_indirectbr(i);
      case .INVOKE; vf_visit_invoke(i);
      case .RESUME; vf_visit_resume(i);
      case .UNREACHABLE; vf_visit_terminator(i);
      case .CLEANUPRET; vf_visit_cleanup_return(i);
      case .CATCHRET; vf_visit_catch_return(i);
      case .CATCHSWITCH; vf_visit_catch_switch(i);
      case .CALLBR; vf_visit_callbr(i);
      case .FNEG; vf_visit_unary(i);
      case .ADD; #through; case .FADD; #through; case .SUB; #through; case .FSUB; #through; case .MUL; #through;
      case .FMUL; #through; case .UDIV; #through; case .SDIV; #through; case .FDIV; #through; case .UREM; #through;
      case .SREM; #through; case .FREM; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through;
      case .AND; #through; case .OR; #through; case .XOR;
        vf_visit_binary(i);
      case .ALLOCA; vf_visit_alloca(i);
      case .LOAD; vf_visit_load(i);
      case .STORE; vf_visit_store(i);
      case .GEP; vf_visit_gep(i);
      case .FENCE; vf_visit_fence(i);
      case .CMPXCHG; vf_visit_cmpxchg(i);
      case .ATOMICRMW; vf_visit_atomicrmw(i);
      case .TRUNC; #through; case .ZEXT; #through; case .SEXT; #through; case .FPTOUI; #through; case .FPTOSI; #through;
      case .UITOFP; #through; case .SITOFP; #through; case .FPTRUNC; #through; case .FPEXT; #through;
      case .PTRTOINT; #through; case .PTRTOADDR; #through; case .INTTOPTR; #through; case .BITCAST; #through;
      case .ADDRSPACECAST;
        vf_visit_cast(i);
      case .CLEANUPPAD; vf_visit_cleanup_pad(i);
      case .CATCHPAD; vf_visit_catch_pad(i);
      case .ICMP; vf_visit_icmp(i);
      case .FCMP; vf_visit_fcmp(i);
      case .PHI; vf_visit_phi(i);
      case .CALL; vf_visit_call(i);
      case .SELECT; vf_visit_select(i);
      case .USEROP1; #through; case .USEROP2;
        vcheck(false, "User-defined operators should not live outside of a pass!", vq_val(i));
      case .VAARG; vf_visit_instruction(i);
      case .EXTRACTELEMENT;
        vcheck(is_vector_type(vtype(op(i, 0))) && is_int_type(vtype(op(i, 1))), "Invalid extractelement operands!", vq_val(i));
        vf_visit_instruction(i);
      case .INSERTELEMENT;
        v := vtype(op(i, 0));
        vcheck(is_vector_type(v) && type_elem(v) == vtype(op(i, 1)) && is_int_type(vtype(op(i, 2))), "Invalid insertelement operands!", vq_val(i));
        vf_visit_instruction(i);
      case .SHUFFLEVECTOR;
        vcheck(vf_shuffle_operands_valid(i), "Invalid shufflevector operands!", vq_val(i));
        vf_visit_instruction(i);
      case .EXTRACTVALUE;
        vcheck(vf_indexed_aggregate_type(vtype(op(i, 0)), i) == vtype(i), "Invalid ExtractValueInst operands!", vq_val(i));
        vf_visit_instruction(i);
      case .INSERTVALUE;
        vcheck(vf_indexed_aggregate_type(vtype(op(i, 0)), i) == vtype(op(i, 1)), "Invalid InsertValueInst operands!", vq_val(i));
        vf_visit_instruction(i);
      case .LANDINGPAD; vf_visit_landing_pad(i);
      case .FREEZE; vf_visit_instruction(i);
      case; vf_visit_instruction(i);
    }
}

// ShuffleVectorInst::isValidOperands(V1, V2, Mask)
vf_shuffle_operands_valid :: (i: Value_Id) -> bool {
    t1 := vtype(op(i, 0)); t2 := vtype(op(i, 1));
    if !is_vector_type(t1) || t1 != t2 return false;
    n := type_count(t1);
    r := inst(i);
    scalable := type_kind(t1) == .SVECTOR;
    for k: 0..cast(s64) r.nidx - 1 {
        m := cast,no_check(s32) ir.u32_pool[r.idx + cast(u32) k];
        if m == -1 continue;
        if scalable && m != 0 return false;
        if m < 0 || cast(u64) m >= n * 2 return false;
    }
    return true;
}

// ExtractValueInst::getIndexedType(Agg, Idxs): NONE if the indices are invalid
vf_indexed_aggregate_type :: (agg: Type_Id, i: Value_Id) -> Type_Id {
    t := agg;
    r := inst(i);
    for k: 0..cast(s64) r.nidx - 1 {
        x := ir.u32_pool[r.idx + cast(u32) k];
        tk := type_kind(t);
        if tk == .ARRAY { if x >= type_count(t) return NONE; t = type_elem(t); }
        else if tk == .STRUCT { if x >= type_nsub(t) return NONE; t = type_sub(t, x); }
        else return NONE;
    }
    return t;
}

vf_visit_terminator :: (i: Value_Id) {
    vcheck(i == block_terminator(inst(i).parent), "Terminator found in the middle of a basic block!", vq_val(inst(i).parent));
    vf_visit_instruction(i);
}

vf_visit_return :: (i: Value_Id) {
    f := block(inst(i).parent).parent;
    rt := func_ret(glob(f).value_type);
    n := nops(i);
    if type_kind(rt) == .VOID
        vcheck(n == 0, "Found return instr that returns non-void in Function of void return type!", vq_val(i), vq_ty(rt));
    else
        vcheck(n == 1 && rt == vtype(op(i, 0)), "Function return type does not match operand type of return inst!", vq_val(i), vq_ty(rt));
    vf_visit_terminator(i);
}

vf_visit_switch :: (i: Value_Id) {
    vcheck(vtype(i) == ir.t_void, "Switch must have void result type!", vq_val(i));
    st := vtype(op(i, 0));
    n := nops(i);
    seen: [..] Value_Id; seen.allocator = temp;
    for k: 2..cast(s64) n - 1 {
        c := ir.u_aux[ir.v_ops[i] + cast(u32) k];
        vcheck(vkind(c) == .C_INT, "Case value is not a constant integer.", vq_val(i));
        vcheck(vtype(c) == st, "Switch constants must all be same type as switch value!", vq_val(i));
        dup := false;
        for seen if it == c { dup = true; break; }
        vcheck(!dup, "Duplicate integer as switch case", vq_val(i), vq_val(c));
        array_add(*seen, c);
    }
    vf_visit_terminator(i);
}

vf_visit_indirectbr :: (i: Value_Id) {
    vcheck(is_ptr_type(vtype(op(i, 0))), "Indirectbr operand must have pointer type!", vq_val(i));
    for k: 1..cast(s64) nops(i) - 1 vcheck(type_kind(vtype(op(i, cast(u32) k))) == .LABEL, "Indirectbr destinations must all have pointer type!", vq_val(i));
    vf_visit_terminator(i);
}

vf_visit_select :: (i: Value_Id) {
    c := vtype(op(i, 0)); t := vtype(op(i, 1)); f := vtype(op(i, 2));
    // SelectInst::areInvalidOperands
    invalid := false;
    if t != f invalid = true;
    else if type_kind(t) == .TOKEN invalid = true;
    else if is_vector_type(c) {
        if type_elem(c) != ir.t_i1 || !is_vector_type(t) || !(type_count(c) == type_count(t) && type_kind(c) == type_kind(t)) invalid = true;
    } else if c != ir.t_i1 invalid = true;
    vcheck(!invalid, "Invalid operands for select instruction!", vq_val(i));
    vcheck(t == vtype(i), "Select values must have same type as select instruction!", vq_val(i));
    vf_visit_instruction(i);
}

vf_same_ec :: inline (a: Type_Id, b: Type_Id) -> bool { return type_count(a) == type_count(b) && type_kind(a) == type_kind(b); }
is_fp_or_fp_vector :: inline (t: Type_Id) -> bool { return is_fp_type(scalar_type(t)); }
vf_is_ptr_or_ptr_vector :: inline (t: Type_Id) -> bool { return is_ptr_type(scalar_type(t)); }

vf_visit_cast :: (i: Value_Id) {
    src := vtype(op(i, 0)); dst := vtype(i);
    sv := is_vector_type(src); dv := is_vector_type(dst);
    sb := vf_scalar_bits(src); db := vf_scalar_bits(dst);
    o := inst_op(i);
    if o == {
      case .TRUNC;
        vcheck(is_int_or_int_vector(src), "Trunc only operates on integer", vq_val(i));
        vcheck(is_int_or_int_vector(dst), "Trunc only produces integer", vq_val(i));
        vcheck(sv == dv, "trunc source and destination must both be a vector or neither", vq_val(i));
        vcheck(sb > db, "DestTy too big for Trunc", vq_val(i));
      case .ZEXT;
        vcheck(is_int_or_int_vector(src), "ZExt only operates on integer", vq_val(i));
        vcheck(is_int_or_int_vector(dst), "ZExt only produces an integer", vq_val(i));
        vcheck(sv == dv, "zext source and destination must both be a vector or neither", vq_val(i));
        vcheck(sb < db, "Type too small for ZExt", vq_val(i));
      case .SEXT;
        vcheck(is_int_or_int_vector(src), "SExt only operates on integer", vq_val(i));
        vcheck(is_int_or_int_vector(dst), "SExt only produces an integer", vq_val(i));
        vcheck(sv == dv, "sext source and destination must both be a vector or neither", vq_val(i));
        vcheck(sb < db, "Type too small for SExt", vq_val(i));
      case .FPTRUNC;
        vcheck(is_fp_or_fp_vector(src), "FPTrunc only operates on FP", vq_val(i));
        vcheck(is_fp_or_fp_vector(dst), "FPTrunc only produces an FP", vq_val(i));
        vcheck(sv == dv, "fptrunc source and destination must both be a vector or neither", vq_val(i));
        vcheck(sb > db, "DestTy too big for FPTrunc", vq_val(i));
      case .FPEXT;
        vcheck(is_fp_or_fp_vector(src), "FPExt only operates on FP", vq_val(i));
        vcheck(is_fp_or_fp_vector(dst), "FPExt only produces an FP", vq_val(i));
        vcheck(sv == dv, "fpext source and destination must both be a vector or neither", vq_val(i));
        vcheck(sb < db, "DestTy too small for FPExt", vq_val(i));
      case .UITOFP; #through;
      case .SITOFP;
        P :: string.["UIToFP", "SIToFP"];
        n := P[ifx o == .UITOFP then 0 else 1];
        vcheck(sv == dv, tprint("% source and dest must both be vector or scalar", n), vq_val(i));
        vcheck(is_int_or_int_vector(src), tprint("% source must be integer or integer vector", n), vq_val(i));
        vcheck(is_fp_or_fp_vector(dst), tprint("% result must be FP or FP vector", n), vq_val(i));
        if sv && dv vcheck(vf_same_ec(src, dst), tprint("% source and dest vector length mismatch", n), vq_val(i));
      case .FPTOUI; #through;
      case .FPTOSI;
        P :: string.["FPToUI", "FPToSI"];
        n := P[ifx o == .FPTOUI then 0 else 1];
        vcheck(sv == dv, tprint("% source and dest must both be vector or scalar", n), vq_val(i));
        vcheck(is_fp_or_fp_vector(src), tprint("% source must be FP or FP vector", n), vq_val(i));
        vcheck(is_int_or_int_vector(dst), tprint("% result must be integer or integer vector", n), vq_val(i));
        if sv && dv vcheck(vf_same_ec(src, dst), tprint("% source and dest vector length mismatch", n), vq_val(i));
      case .PTRTOADDR;
        vf_check_ptr_to_addr(src, dst, i);
      case .PTRTOINT;
        vcheck(vf_is_ptr_or_ptr_vector(src), "PtrToInt source must be pointer", vq_val(i));
        vcheck(is_int_or_int_vector(dst), "PtrToInt result must be integral", vq_val(i));
        vcheck(sv == dv, "PtrToInt type mismatch", vq_val(i));
        if sv vcheck(vf_same_ec(src, dst), "PtrToInt Vector length mismatch", vq_val(i));
      case .INTTOPTR;
        vcheck(is_int_or_int_vector(src), "IntToPtr source must be an integral", vq_val(i));
        vcheck(vf_is_ptr_or_ptr_vector(dst), "IntToPtr result must be a pointer", vq_val(i));
        vcheck(sv == dv, "IntToPtr type mismatch", vq_val(i));
        if sv vcheck(vf_same_ec(src, dst), "IntToPtr Vector length mismatch", vq_val(i));
      case .BITCAST;
        vcheck(cast_is_valid_bitcast(src, dst), "Invalid bitcast", vq_val(i));
      case .ADDRSPACECAST;
        vcheck(vf_is_ptr_or_ptr_vector(src), "AddrSpaceCast source must be a pointer", vq_val(i));
        vcheck(vf_is_ptr_or_ptr_vector(dst), "AddrSpaceCast result must be a pointer", vq_val(i));
        vcheck(ir.types[scalar_type(src)].a != ir.types[scalar_type(dst)].a, "AddrSpaceCast must be between different address spaces", vq_val(i));
        if sv vcheck(vf_same_ec(src, dst), "AddrSpaceCast vector pointer number of elements mismatch", vq_val(i));
    }
    vf_visit_instruction(i);
}

// checkPtrToAddr (Check returns from it, not from the caller: the caller continues with visitInstruction)
vf_check_ptr_to_addr :: (src: Type_Id, dst: Type_Id, v: Value_Id) {
    vcheck(vf_is_ptr_or_ptr_vector(src), "PtrToAddr source must be pointer", vq_val(v));
    vcheck(is_int_or_int_vector(dst), "PtrToAddr result must be integral", vq_val(v));
    vcheck(is_vector_type(src) == is_vector_type(dst), "PtrToAddr type mismatch", vq_val(v));
    if is_vector_type(src) vcheck(vf_same_ec(src, dst), "PtrToAddr vector length mismatch", vq_val(v));
    // DataLayout::getAddressType: the index width of the address space
    as := cast(u32) ir.types[scalar_type(src)].a;
    at := type_int(cast(u32) dl_ptr_spec(as).idx_bits);
    if is_vector_type(src) at = type_vector(type_count(src), at, type_kind(src) == .SVECTOR);
    vcheck(at == dst, "PtrToAddr result must be address width", vq_val(v));
}

vf_visit_phi :: (i: Value_Id) {
    b := inst(i).parent;
    vcheck(i == block(b).first || inst_op(inst(i).prev) == .PHI, "PHI nodes not grouped at top of basic block!", vq_val(i), vq_val(b));
    vcheck(!type_is_token_like(vtype(i)), "PHI nodes cannot have token type!");
    for k: 0..cast(s64) nops(i) - 1 vcheck(vtype(i) == vtype(op(i, cast(u32) k)), "PHI node operands are not the same type as the result!", vq_val(i));
    vf_visit_instruction(i);
}

vf_visit_unary :: (i: Value_Id) {
    vcheck(vtype(i) == vtype(op(i, 0)), "Unary operators must have same type foroperands and result!", vq_val(i));
    vcheck(is_fp_or_fp_vector(vtype(i)), "FNeg operator only works with float types!", vq_val(i));
    vf_visit_instruction(i);
}

vf_visit_binary :: (i: Value_Id) {
    t0 := vtype(op(i, 0));
    vcheck(t0 == vtype(op(i, 1)), "Both operands to a binary operator are not of the same type!", vq_val(i));
    t := vtype(i);
    o := inst_op(i);
    if o == {
      case .ADD; #through; case .SUB; #through; case .MUL; #through; case .SDIV; #through; case .UDIV; #through;
      case .SREM; #through; case .UREM;
        vcheck(is_int_or_int_vector(t), "Integer arithmetic operators only work with integral types!", vq_val(i));
        vcheck(t == t0, "Integer arithmetic operators must have same type for operands and result!", vq_val(i));
      case .FADD; #through; case .FSUB; #through; case .FMUL; #through; case .FDIV; #through; case .FREM;
        vcheck(is_fp_or_fp_vector(t), "Floating-point arithmetic operators only work with floating-point types!", vq_val(i));
        vcheck(t == t0, "Floating-point arithmetic operators must have same type for operands and result!", vq_val(i));
      case .AND; #through; case .OR; #through; case .XOR;
        vcheck(is_int_or_int_vector(t), "Logical operators only work with integral types!", vq_val(i));
        vcheck(t == t0, "Logical operators must have same type for operands and result!", vq_val(i));
      case .SHL; #through; case .LSHR; #through; case .ASHR;
        vcheck(is_int_or_int_vector(t), "Shifts only work with integral types!", vq_val(i));
        vcheck(t == t0, "Shift return type must be same as operands!", vq_val(i));
    }
    vf_visit_instruction(i);
}

vf_visit_icmp :: (i: Value_Id) {
    t0 := vtype(op(i, 0));
    vcheck(t0 == vtype(op(i, 1)), "Both operands to ICmp instruction are not of the same type!", vq_val(i));
    vcheck(is_int_or_int_vector(t0) || vf_is_ptr_or_ptr_vector(t0), "Invalid operand types for ICmp instruction", vq_val(i));
    p := inst(i).pred;
    vcheck(p >= 32 && p <= 41, "Invalid predicate in ICmp instruction!", vq_val(i));
    vf_visit_instruction(i);
}
vf_visit_fcmp :: (i: Value_Id) {
    t0 := vtype(op(i, 0));
    vcheck(t0 == vtype(op(i, 1)), "Both operands to FCmp instruction are not of the same type!", vq_val(i));
    vcheck(is_fp_or_fp_vector(t0), "Invalid operand types for FCmp instruction", vq_val(i));
    vcheck(inst(i).pred <= 15, "Invalid predicate in FCmp instruction!", vq_val(i));
    vf_visit_instruction(i);
}

vf_module_flag_int :: (name: string) -> (bool, u64) {
    for nm: ir.named_md {
        if nm.name != "llvm.module.flags" continue;
        for f: nm.ops {
            if f == NONE || ir.mds[f].nops < 3 continue;
            k := md_op(f, 1);
            if k == NONE || ir.mds[k].kind != .STRING || ir.mds[k].str != name continue;
            v := md_op(f, 2);
            if v != NONE && ir.mds[v].kind == .VALUE && vkind(ir.mds[v].value) == .C_INT return true, const_int_zext(ir.mds[v].value);
            return false, 0;
        }
    }
    return false, 0;
}

vf_visit_gep :: (i: Value_Id) {
    if vf.have_logical_ptr_flag vcheck(vf.logical_ptr_flag == 0, "Non-logical getelementptr disallowed for this module.");
    pt := vtype(op(i, 0));
    vcheck(is_ptr_type(scalar_type(pt)), "GEP base pointer is not a vector or a vector of pointers", vq_val(i));
    src := inst(i).ty2;
    vcheck(vf_type_is_sized(src), "GEP into unsized type!", vq_val(i));
    if type_kind(src) == .STRUCT vcheck(!type_is_scalable(src), "getelementptr cannot target structure that contains scalable vectortype", vq_val(i));
    n := nops(i);
    all_int := true;
    for k: 1..cast(s64) n - 1 if !is_int_or_int_vector(vtype(op(i, cast(u32) k))) { all_int = false; break; }
    vcheck(all_int, "GEP indexes must be integers", vq_val(i));
    // GetElementPtrInst::getIndexedType (getTypeAtIndex per index after the first)
    el := src;
    for k: 2..cast(s64) n - 1 {
        idx := op(i, cast(u32) k);
        el = vf_type_at_index(el, idx);
        if el == NONE break;
    }
    vcheck(el != NONE, "Invalid indices for GEP pointer type!", vq_val(i));
    rt := vtype(i);
    vcheck(is_ptr_type(scalar_type(rt)), "GEP is not of right type for indices!", vq_val(i), vq_ty(el));
    if is_vector_type(rt) {
        if is_vector_type(pt) vcheck(vf_same_ec(rt, pt), "Vector GEP result width doesn't match operand's", vq_val(i));
        for k: 1..cast(s64) n - 1 {
            it := vtype(op(i, cast(u32) k));
            if is_vector_type(it) vcheck(vf_same_ec(it, rt), "Invalid GEP index vector width", vq_val(i));
            vcheck(is_int_or_int_vector(it), "All GEP indices should be of integer type");
        }
    }
    // gep_type_iterator: an index whose container is a vector indexes its elements, which must be byte-addressable
    cur := src;
    for k: 2..cast(s64) n - 1 {
        if is_vector_type(cur) {
            et := type_elem(cur);
            vcheck(dl_type_size_bits(et) == dl_type_store_size(et) * 8, "GEP into vector with non-byte-addressable element type", vq_val(i));
            cur = et;
        } else {
            cur = vf_type_at_index(cur, op(i, cast(u32) k));
        }
    }
    vcheck(ir.types[scalar_type(pt)].a == ir.types[scalar_type(rt)].a, "GEP address space doesn't match type", vq_val(i));
    vf_visit_instruction(i);
}
// getTypeAtIndex(Type *, Value *) of GetElementPtrInst::getIndexedType
vf_type_at_index :: (t: Type_Id, idx: Value_Id) -> Type_Id {
    tk := type_kind(t);
    it := vtype(idx);
    if tk == .STRUCT {
        // StructType::indexValid: (vectors of) i32 constants, a vector index must be a splat
        if !(is_int_type(scalar_type(it)) && type_int_width(scalar_type(it)) == 32) return NONE;
        if type_kind(it) == .SVECTOR return NONE;
        c := idx;
        if is_vector_type(it) { if !is_constant_kind(vkind(idx)) return NONE; c = get_splat_value(idx); }
        if c == NONE || vkind(c) != .C_INT return NONE;
        x := const_int_zext(c);
        if x >= type_nsub(t) return NONE;
        return type_sub(t, cast(u32) x);
    }
    if !is_int_or_int_vector(it) return NONE;
    if tk == .ARRAY || tk == .VECTOR || tk == .SVECTOR return type_elem(t);
    return NONE;
}
// a splat ConstantInt of a vector index (ConstantDataVector / ConstantVector splat)
get_splat_int :: (v: Value_Id) -> Value_Id {
    s := get_splat_value(v);
    if s != NONE && vkind(s) == .C_INT return s;
    return NONE;
}

vf_check_atomic_mem_access_size :: (ty: Type_Id, i: Value_Id) {
    size := dl_type_size_bits(ty);
    vcheck(size >= 8, "atomic memory access' size must be byte-sized", vq_ty(ty), vq_val(i));
    vcheck((size & (size - 1)) == 0, "atomic memory access' operand must have a power-of-two size", vq_ty(ty), vq_val(i));
}

vf_visit_load :: (i: Value_Id) {
    vcheck(is_ptr_type(vtype(op(i, 0))), "Load operand must be a pointer.", vq_val(i));
    el := vtype(i);
    r := inst(i);
    if r.align vcheck(r.align <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(i));
    vcheck(vf_type_is_sized(el), "loading unsized types is not allowed", vq_val(i));
    if r.ord1 != 0 {
        vcheck(r.ord1 != ORD_RELEASE && r.ord1 != ORD_ACQ_REL, "Load cannot have Release ordering", vq_val(i));
        st := scalar_type(el);
        vcheck(is_int_type(st) || is_ptr_type(st) || type_kind(st) == .BYTE || is_fp_type(st),
            "atomic load operand must have integer, byte, pointer, floating point, or vector type!", vq_ty(el), vq_val(i));
        vf_check_atomic_mem_access_size(el, i);
    } else {
        vcheck(r.sync == 0, "Non-atomic load cannot have SynchronizationScope specified", vq_val(i));
    }
    vf_visit_instruction(i);
}

vf_visit_store :: (i: Value_Id) {
    vcheck(is_ptr_type(vtype(op(i, 1))), "Store operand must be a pointer.", vq_val(i));
    el := vtype(op(i, 0));
    r := inst(i);
    if r.align vcheck(r.align <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(i));
    vcheck(vf_type_is_sized(el), "storing unsized types is not allowed", vq_val(i));
    if r.ord1 != 0 {
        vcheck(r.ord1 != ORD_ACQUIRE && r.ord1 != ORD_ACQ_REL, "Store cannot have Acquire ordering", vq_val(i));
        st := scalar_type(el);
        vcheck(is_int_type(st) || is_ptr_type(st) || type_kind(st) == .BYTE || is_fp_type(st),
            "atomic store operand must have integer, byte, pointer, floating point, or vector type!", vq_ty(el), vq_val(i));
        vf_check_atomic_mem_access_size(el, i);
    } else {
        vcheck(r.sync == 0, "Non-atomic store cannot have SynchronizationScope specified", vq_val(i));
    }
    vf_visit_instruction(i);
}

// AtomicOrdering numbering (llvm/Support/AtomicOrdering.h; ORD_UNORDERED .. ORD_RELEASE are in inst_props.jai / aa.jai)
ORD_ACQ_REL :: 6; ORD_SEQ_CST :: 7;

vf_verify_swift_error_call :: (call: Value_Id, sv: Value_Id) {
    na := call_num_args(call);
    for k: 0..cast(s64) na - 1 {
        if op(call, cast(u32) k) == sv
            vcheck(vf_call_param_has_attr(call, cast(u32) k, .SwiftError), "swifterror value when used in a callsite should be marked with swifterror attribute", vq_val(sv), vq_val(call));
    }
}

vf_verify_swift_error_value :: (sv: Value_Id) {
    u := ir.v_first_use[sv];
    while u != NONE {
        user := ir.u_user[u];
        u = ir.u_next[u];
        o := ifx is_inst(user) then inst_op(user) else Opcode.NONE_OP;
        vcheck(o == .LOAD || o == .STORE || o == .CALL || o == .INVOKE,
            "swifterror value can only be loaded and stored from, or as a swifterror argument!", vq_val(sv), vq_val(user));
        if o == .STORE vcheck(op(user, 1) == sv, "swifterror value should be the second operand when used by stores", vq_val(sv), vq_val(user));
        if o == .CALL || o == .INVOKE || o == .CALLBR vf_verify_swift_error_call(user, sv);
    }
}

vf_visit_alloca :: (i: Value_Id) {
    if vf.have_logical_ptr_flag vcheck(vf.logical_ptr_flag == 0, "Non-logical alloca disallowed for this module.");
    r := inst(i);
    ty := r.ty2;
    vcheck(vf_type_is_sized(ty), "Cannot allocate unsized type", vq_val(i));
    vcheck(!type_contains_non_local_target_ext(ty), "Alloca has illegal target extension type", vq_val(i));
    vcheck(is_int_type(vtype(op(i, 0))), "Alloca array size must have integer type", vq_val(i));
    if r.align vcheck(r.align <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(i));
    if r.flags & F_SWIFTERR {
        vcheck(is_ptr_type(ty), "swifterror alloca must have pointer type", vq_val(i));
        sz := op(i, 0);
        vcheck(vkind(sz) == .C_INT && const_int_zext(sz) == 1, "swifterror alloca must not be array allocation", vq_val(i));
        vf_verify_swift_error_value(i);
    }
    vf_visit_instruction(i);
}

vf_visit_cmpxchg :: (i: Value_Id) {
    el := vtype(op(i, 1));
    vcheck(is_int_type(el) || is_ptr_type(el), "cmpxchg operand must have integer or pointer type", vq_ty(el), vq_val(i));
    vf_check_atomic_mem_access_size(el, i);
    vf_visit_instruction(i);
}

RMW_NAMES :: string.["xchg", "add", "sub", "and", "nand", "or", "xor", "max", "min", "umax", "umin", "fadd", "fsub", "fmax", "fmin",
    "fmaximum", "fminimum", "fmaximumnum", "fminimumnum", "uinc_wrap", "udec_wrap", "usub_cond", "usub_sat"];

vf_visit_atomicrmw :: (i: Value_Id) {
    r := inst(i);
    vcheck(r.ord1 != ORD_UNORDERED, "atomicrmw instructions cannot be unordered.", vq_val(i));
    o := r.ord2;
    el := vtype(op(i, 1));
    sc := el;
    if r.flags & F_ELEMENTWISE {
        vcheck(r.ord1 != ORD_SEQ_CST, "atomicrmw elementwise cannot be sequentially consistent.", vq_val(i));
        vcheck(type_kind(el) == .VECTOR, "atomicrmw elementwise operand must have fixed vector type!", vq_val(i), vq_ty(el));
        sc = type_elem(el);
    }
    name := ifx o < RMW_NAMES.count then RMW_NAMES[o] else "<invalid operation>";
    is_fp_op := o >= 11 && o <= 18;
    if o == 0 {
        vcheck(is_int_type(sc) || is_fp_type(sc) || is_ptr_type(sc), tprint("atomicrmw % operand must have integer or floating point type!", name), vq_val(i), vq_ty(el));
    } else if is_fp_op {
        vcheck(is_fp_or_fp_vector(el) && type_kind(el) != .SVECTOR, tprint("atomicrmw % operand must have floating-point or fixed vector of floating-point type!", name), vq_val(i), vq_ty(el));
    } else {
        vcheck(is_int_or_int_vector(el) && type_kind(el) != .SVECTOR, tprint("atomicrmw % operand must have integer or fixed vector of integer type!", name), vq_val(i), vq_ty(el));
    }
    vf_check_atomic_mem_access_size(el, i);
    vcheck(o < RMW_NAMES.count, "Invalid binary operation!", vq_val(i));
    vf_visit_instruction(i);
}

vf_visit_fence :: (i: Value_Id) {
    o := inst(i).ord1;
    vcheck(o == ORD_ACQUIRE || o == ORD_RELEASE || o == ORD_ACQ_REL || o == ORD_SEQ_CST,
        "fence instructions may only have acquire, release, acq_rel, or seq_cst ordering.", vq_val(i));
    vf_visit_instruction(i);
}

// ---------------------------------------------------------------- EH

// getParentPad: a FuncletPadInst keeps its parent pad as the last operand, a CatchSwitchInst as operand 0
vf_parent_pad :: inline (pad: Value_Id) -> Value_Id {
    if inst_op(pad) == .CATCHSWITCH return op(pad, 0);
    return op(pad, nops(pad) - 1);
}
is_funclet_pad :: inline (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .CLEANUPPAD || inst_op(v) == .CATCHPAD); }
// CatchSwitchInst / CleanupReturnInst unwind destinations
vf_catchswitch_unwind_dest :: (cs: Value_Id) -> Value_Id { if inst(cs).flags & F_HAS_UNWIND return op(cs, 1); return NONE; }
vf_cleanupret_unwind_dest :: (cr: Value_Id) -> Value_Id { if nops(cr) > 1 return op(cr, 1); return NONE; }
vf_invoke_normal_dest :: (ii: Value_Id) -> Value_Id { return get_successor(ii, 0); }
vf_invoke_unwind_dest :: (ii: Value_Id) -> Value_Id { return get_successor(ii, 1); }

vf_unique_predecessor :: (b: Value_Id) -> Value_Id {
    p: Value_Id = NONE;
    u := ir.v_first_use[b];
    while u != NONE {
        user := ir.u_user[u];
        if is_inst(user) && is_terminator(inst_op(user)) {
            pb := inst(user).parent;
            if p != NONE && pb != p return NONE;
            p = pb;
        }
        u = ir.u_next[u];
    }
    return p;
}

vf_visit_eh_pad_predecessors :: (i: Value_Id) {
    bb := inst(i).parent;
    f := block(bb).parent;
    vcheck(bb != glob(f).first_block, "EH pad cannot be in entry block.", vq_val(i));
    preds: [..] Value_Id; preds.allocator = temp;
    block_predecessors(bb, *preds);
    o := inst_op(i);
    if o == .LANDINGPAD {
        for pb: preds {
            t := block_terminator(pb);
            vcheck(t != NONE && inst_op(t) == .INVOKE && vf_invoke_unwind_dest(t) == bb && vf_invoke_normal_dest(t) != bb,
                "Block containing LandingPadInst must be jumped to only by the unwind edge of an invoke.", vq_val(i));
        }
        return;
    }
    if o == .CATCHPAD {
        cs := vf_parent_pad(i);
        if preds.count
            vcheck(vf_unique_predecessor(bb) == inst(cs).parent, "Block containg CatchPadInst must be jumped to only by its catchswitch.", vq_val(i));
        vcheck(bb != vf_catchswitch_unwind_dest(cs), "Catchswitch cannot unwind to one of its catchpads", vq_val(cs), vq_val(i));
        return;
    }
    to_pad := i;
    to_parent := vf_parent_pad(to_pad);
    for pb: preds {
        t := block_terminator(pb);
        from: Value_Id = NONE;
        to := inst_op(t);
        if to == .INVOKE {
            vcheck(vf_invoke_unwind_dest(t) == bb && vf_invoke_normal_dest(t) != bb, "EH pad must be jumped to via an unwind edge", vq_val(to_pad), vq_val(t));
            cf := call_called_operand_fn(t);
            cf2 := strip_pointer_casts(call_callee(t));
            if vkind(cf2) == .FUNCTION && glob(cf2).intrinsic && call_does_not_throw(t) && !intrinsic_may_lower_to_function_call(vf_iid(cf2))
                continue;
            fb := vf_bundle_input(t, "funclet");
            from = ifx fb != NONE then fb else vf_const_token_none();
        } else if to == .CLEANUPRET {
            from = op(t, 0);
            vcheck(from != to_parent, "A cleanupret must exit its cleanup", vq_val(t));
        } else if to == .CATCHSWITCH {
            from = t;
        } else {
            vcheck(false, "EH pad must be jumped to via an unwind edge", vq_val(to_pad), vq_val(t));
        }
        seen: [..] Value_Id; seen.allocator = temp;
        while true {
            vcheck(from != to_pad, "EH pad cannot handle exceptions raised within it", vq_val(from), vq_val(t));
            if from == to_parent break;
            vcheck(vkind(from) != .C_TOKEN_NONE, "A single unwind edge may only enter one EH pad", vq_val(t));
            dup := false;
            for seen if it == from { dup = true; break; }
            vcheck(!dup, "EH pad jumps through a cycle of pads", vq_val(from));
            array_add(*seen, from);
            vcheck(is_funclet_pad(from) || (is_inst(from) && inst_op(from) == .CATCHSWITCH), "Parent pad must be catchpad/cleanuppad/catchswitch", vq_val(t));
            from = vf_parent_pad(from);
        }
    }
}

// the single input of a call's operand bundle `tag`, NONE if there is none
vf_bundle_input :: (call: Value_Id, tag: string) -> Value_Id {
    nb := call_num_bundles(call);
    if nb == 0 return NONE;
    for k: 0..nb-1 {
        if call_bundle_tag(call, k) != tag continue;
        b := ir.u32_pool[inst(call).idx + 3 * k + 1];
        return op(call, b);
    }
    return NONE;
}

vf_const_token_none :: () -> Value_Id {
    k := const_key_begin(.C_TOKEN_NONE, ir.t_token);
    return const_lookup_or_create(k, .C_TOKEN_NONE, ir.t_token, .[], 0);
}

vf_visit_landing_pad :: (i: Value_Id) {
    r := inst(i);
    vcheck(nops(i) > 0 || (r.flags & F_CLEANUP) != 0, "LandingPadInst needs at least one clause or to be a cleanup.", vq_val(i));
    vf_visit_eh_pad_predecessors(i);
    if vf.landing_pad_ty == NONE vf.landing_pad_ty = vtype(i);
    else vcheck(vf.landing_pad_ty == vtype(i), "The landingpad instruction should have a consistent result type inside a function.", vq_val(i));
    f := block(r.parent).parent;
    vcheck(glob(f).has_personality, "LandingPadInst needs to be in a function with a personality.", vq_val(i));
    vcheck(block_first_non_phi(r.parent) == i, "LandingPadInst not the first non-PHI instruction in the block.", vq_val(i));
    for k: 0..cast(s64) nops(i) - 1 {
        c := op(i, cast(u32) k);
        if !vf_landingpad_clause_is_filter(i, cast(u32) k) {
            vcheck(is_ptr_type(vtype(c)), "Catch operand does not have pointer type!", vq_val(i));
        } else {
            vcheck(vkind(c) == .C_ARRAY || vkind(c) == .C_ZERO || vkind(c) == .C_NULL, "Filter operand is not an array of constants!", vq_val(i));
        }
    }
    vf_visit_instruction(i);
}
// LandingPadInst::isFilter: the clause's type is an array
vf_landingpad_clause_is_filter :: (i: Value_Id, k: u32) -> bool { return type_kind(vtype(op(i, k))) == .ARRAY; }

vf_visit_resume :: (i: Value_Id) {
    f := block(inst(i).parent).parent;
    vcheck(glob(f).has_personality, "ResumeInst needs to be in a function with a personality.", vq_val(i));
    if vf.landing_pad_ty == NONE vf.landing_pad_ty = vtype(op(i, 0));
    else vcheck(vf.landing_pad_ty == vtype(op(i, 0)), "The resume instruction should have a consistent result type inside a function.", vq_val(i));
    vf_visit_terminator(i);
}

vf_visit_catch_pad :: (i: Value_Id) {
    bb := inst(i).parent;
    f := block(bb).parent;
    vcheck(glob(f).has_personality, "CatchPadInst needs to be in a function with a personality.", vq_val(i));
    parent := vf_parent_pad(i);
    vcheck(is_inst(parent) && inst_op(parent) == .CATCHSWITCH, "CatchPadInst needs to be directly nested in a CatchSwitchInst.", vq_val(parent));
    vcheck(block_first_non_phi(bb) == i, "CatchPadInst not the first non-PHI instruction in the block.", vq_val(i));
    ok := true;
    for k: 0..cast(s64) nops(i) - 2 {
        v := op(i, cast(u32) k);
        if !(is_constant_kind(vkind(v)) || (is_inst(v) && inst_op(v) == .ALLOCA)) { ok = false; break; }
    }
    vcheck(ok, "Argument operand must be alloca or constant.", vq_val(i));
    vf_visit_eh_pad_predecessors(i);
    vf_visit_funclet_pad(i);
}

vf_visit_catch_return :: (i: Value_Id) {
    p := op(i, 0);
    vcheck(is_inst(p) && inst_op(p) == .CATCHPAD, "CatchReturnInst needs to be provided a CatchPad", vq_val(i), vq_val(p));
    vf_visit_terminator(i);
}

vf_visit_cleanup_pad :: (i: Value_Id) {
    bb := inst(i).parent;
    f := block(bb).parent;
    vcheck(glob(f).has_personality, "CleanupPadInst needs to be in a function with a personality.", vq_val(i));
    vcheck(block_first_non_phi(bb) == i, "CleanupPadInst not the first non-PHI instruction in the block.", vq_val(i));
    p := vf_parent_pad(i);
    vcheck(vkind(p) == .C_TOKEN_NONE || is_funclet_pad(p), "CleanupPadInst has an invalid parent.", vq_val(i));
    vf_visit_eh_pad_predecessors(i);
    vf_visit_funclet_pad(i);
}

vf_first_non_phi_or_none :: (b: Value_Id) -> Value_Id { return block_first_non_phi(b); }

vf_visit_funclet_pad :: (fpi: Value_Id) {
    first_user: Value_Id = NONE;
    first_unwind_pad: Value_Id = NONE;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, fpi);
    seen: [..] Value_Id; seen.allocator = temp;
    while worklist.count {
        cur := pop(*worklist);
        dup := false;
        for seen if it == cur { dup = true; break; }
        vcheck(!dup, "FuncletPadInst must not be nested within itself", vq_val(cur));
        array_add(*seen, cur);
        unresolved: Value_Id = NONE;
        u := ir.v_first_use[cur];
        while u != NONE {
            user := ir.u_user[u];
            u = ir.u_next[u];
            unwind_dest: Value_Id = NONE;
            uo := ifx is_inst(user) then inst_op(user) else Opcode.NONE_OP;
            if uo == .CLEANUPRET {
                unwind_dest = vf_cleanupret_unwind_dest(user);
            } else if uo == .CATCHSWITCH {
                if vf_catchswitch_unwind_dest(user) == NONE continue;
                unwind_dest = vf_catchswitch_unwind_dest(user);
            } else if uo == .INVOKE {
                unwind_dest = vf_invoke_unwind_dest(user);
            } else if uo == .CALL {
                continue;
            } else if uo == .CLEANUPPAD {
                array_add(*worklist, user);
                continue;
            } else {
                vcheck(uo == .CATCHRET, "Bogus funclet pad use", vq_val(user));
                continue;
            }
            unwind_pad: Value_Id;
            exits_fpi: bool;
            if unwind_dest != NONE {
                unwind_pad = block_first_non_phi(unwind_dest);
                if unwind_pad == NONE || !is_eh_pad(unwind_pad) continue;
                unwind_parent := vf_parent_pad(unwind_pad);
                if unwind_parent == cur continue;
                exited := cur;
                exits_fpi = false;
                while true {
                    if exited == fpi { exits_fpi = true; unresolved = fpi; break; }
                    exited_parent := vf_parent_pad(exited);
                    if exited_parent == unwind_parent { unresolved = exited_parent; break; }
                    exited = exited_parent;
                    if vkind(exited) == .C_TOKEN_NONE break;
                }
            } else {
                unwind_pad = vf_const_token_none();
                exits_fpi = true;
                unresolved = fpi;
            }
            if exits_fpi {
                if first_user != NONE {
                    vcheck(unwind_pad == first_unwind_pad, "Unwind edges out of a funclet pad must have the same unwind dest", vq_val(fpi), vq_val(user), vq_val(first_user));
                } else {
                    first_user = user;
                    first_unwind_pad = unwind_pad;
                    if inst_op(fpi) == .CLEANUPPAD && vkind(unwind_pad) != .C_TOKEN_NONE && vf_parent_pad(unwind_pad) == vf_parent_pad(fpi)
                        vf_sibling_set(fpi, user);
                }
            }
            if cur != fpi break;
        }
        if unresolved != NONE {
            if cur == unresolved continue;
            resolved := cur;
            while worklist.count {
                uncle := worklist[worklist.count - 1];
                ancestor := vf_parent_pad(uncle);
                while resolved != ancestor {
                    rp := vf_parent_pad(resolved);
                    if rp == unresolved break;
                    resolved = rp;
                }
                if resolved != ancestor break;
                worklist.count -= 1;
            }
        }
    }
    if first_unwind_pad != NONE {
        cs := vf_parent_pad(fpi);
        if is_inst(cs) && inst_op(cs) == .CATCHSWITCH {
            sd := vf_catchswitch_unwind_dest(cs);
            sp := ifx sd != NONE then block_first_non_phi(sd) else vf_const_token_none();
            vcheck(sp == first_unwind_pad, "Unwind edges out of a catch must have the same unwind dest as the parent catchswitch", vq_val(fpi), vq_val(first_user), vq_val(cs));
        }
    }
    vf_visit_instruction(fpi);
}

vf_sibling_set :: (pad: Value_Id, term: Value_Id) {
    for * vf.sibling_funclet if it.*[0] == pad { it.*[1] = term; return; }
    e: [2] Value_Id; e[0] = pad; e[1] = term;
    array_add(*vf.sibling_funclet, e);
}
vf_sibling_find :: (pad: Value_Id) -> Value_Id {
    for vf.sibling_funclet if it[0] == pad return it[1];
    return NONE;
}

vf_visit_catch_switch :: (i: Value_Id) {
    bb := inst(i).parent;
    f := block(bb).parent;
    vcheck(glob(f).has_personality, "CatchSwitchInst needs to be in a function with a personality.", vq_val(i));
    vcheck(block_first_non_phi(bb) == i, "CatchSwitchInst not the first non-PHI instruction in the block.", vq_val(i));
    parent := op(i, 0);
    vcheck(vkind(parent) == .C_TOKEN_NONE || is_funclet_pad(parent), "CatchSwitchInst has an invalid parent.", vq_val(parent));
    ud := vf_catchswitch_unwind_dest(i);
    if ud != NONE {
        fi := block_first_non_phi(ud);
        vcheck(fi != NONE && is_eh_pad(fi) && inst_op(fi) != .LANDINGPAD, "CatchSwitchInst must unwind to an EH block which is not a landingpad.", vq_val(i));
        if vf_parent_pad(fi) == parent vf_sibling_set(i, i);
    }
    first_handler: u32 = ifx ud != NONE then cast(u32) 2 else 1;
    vcheck(nops(i) > first_handler, "CatchSwitchInst cannot have empty handler list", vq_val(i));
    for k: first_handler..nops(i) - 1 {
        h := op(i, k);
        fi := block_first_non_phi(h);
        vcheck(fi != NONE && inst_op(fi) == .CATCHPAD, "CatchSwitchInst handlers must be catchpads", vq_val(i), vq_val(h));
    }
    vf_visit_eh_pad_predecessors(i);
    vf_visit_terminator(i);
}

vf_visit_cleanup_return :: (i: Value_Id) {
    p := op(i, 0);
    vcheck(is_inst(p) && inst_op(p) == .CLEANUPPAD, "CleanupReturnInst needs to be provided a CleanupPad", vq_val(i), vq_val(p));
    ud := vf_cleanupret_unwind_dest(i);
    if ud != NONE {
        fi := block_first_non_phi(ud);
        vcheck(fi != NONE && is_eh_pad(fi) && inst_op(fi) != .LANDINGPAD, "CleanupReturnInst must unwind to an EH block which is not a landingpad.", vq_val(i));
    }
    vf_visit_terminator(i);
}

// getSuccPad
vf_succ_pad :: (t: Value_Id) -> Value_Id {
    ud: Value_Id;
    o := inst_op(t);
    if o == .INVOKE ud = vf_invoke_unwind_dest(t);
    else if o == .CATCHSWITCH ud = vf_catchswitch_unwind_dest(t);
    else ud = vf_cleanupret_unwind_dest(t);
    return block_first_non_phi(ud);
}

vf_verify_sibling_funclet_unwinds :: () {
    visited: [..] Value_Id; visited.allocator = temp;
    active: [..] Value_Id; active.allocator = temp;
    contains :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }
    for pair: vf.sibling_funclet {
        pred := pair[0];
        if contains(visited, pred) continue;
        array_add(*active, pred);
        term := pair[1];
        while true {
            succ := vf_succ_pad(term);
            if contains(active, succ) {
                cycle_pad := succ;
                nodes: [..] VArg; nodes.allocator = temp;
                while true {
                    array_add(*nodes, vq_val(cycle_pad));
                    ct := vf_sibling_find(cycle_pad);
                    if ct != cycle_pad array_add(*nodes, vq_val(ct));
                    cycle_pad = vf_succ_pad(ct);
                    if cycle_pad == succ break;
                }
                check_failed("EH pads can't handle each other's exceptions", ..nodes);
                return;
            }
            if contains(visited, succ) break;
            array_add(*visited, succ);
            pred = succ;
            t2 := vf_sibling_find(pred);
            if t2 == NONE break;
            term = t2;
            array_add(*active, pred);
        }
        active.count = 0;
    }
}

// ---------------------------------------------------------------- visitInstruction

vf_visit_instruction :: (i: Value_Id) {
    r := inst(i);
    bb := r.parent;
    vcheck(bb != NONE, "Instruction not embedded in basic block!", vq_val(i));
    if r.op != .PHI {
        u := ir.v_first_use[i];
        while u != NONE {
            if ir.u_user[u] == i vcheck(!dt_is_reachable_from_entry(vf_dt(), bb), "Only PHI nodes may reference their own value!", vq_val(i));
            u = ir.u_next[u];
        }
    }
    vcheck(vtype(i) != ir.t_void || vname(i).count == 0, "Instruction has a name, but provides a void value!", vq_val(i));
    vcheck(vtype(i) == ir.t_void || is_first_class(vtype(i)), "Instruction returns a non-scalar type!", vq_val(i));
    vcheck(type_kind(vtype(i)) != .METADATA || r.op == .CALL || r.op == .INVOKE, "Invalid use of metadata!", vq_val(i));
    u := ir.v_first_use[i];
    while u != NONE {
        user := ir.u_user[u];
        if !is_inst(user) { check_failed("Use of instruction is not an instruction!", vq_val(user)); return; }
        u = ir.u_next[u];
    }
    is_cb := r.op == .CALL || r.op == .INVOKE || r.op == .CALLBR;
    n := nops(i);
    callee_idx := ifx is_cb then n - 1 else NONE;
    // the switch's case values are not operands
    for k: 0..cast(s64) n - 1 {
        ku := cast(u32) k;
        o := op(i, ku);
        vcheck(o != NONE, "Instruction has null operand!", vq_val(i));
        if !is_first_class(vtype(o)) vcheck(false, "Instruction operands must be first-class values!", vq_val(i));
        ok := vkind(o);
        if ok == .FUNCTION {
            is_attached := is_cb && vf_is_attached_call_operand(i, op_use(i, ku));
            if glob(o).intrinsic {
                vcheck(ku == callee_idx || is_attached, "Cannot take the address of an intrinsic!", vq_val(i));
                iid := vf_iid(o);
                vcheck(r.op == .CALL || r.op == .CALLBR || iid == VI_donothing || iid == VI_seh_try_begin || iid == VI_seh_try_end ||
                    iid == VI_seh_scope_begin || iid == VI_seh_scope_end || iid == VI_coro_resume || iid == VI_coro_destroy ||
                    iid == VI_coro_await_suspend_void || iid == VI_coro_await_suspend_bool || iid == VI_coro_await_suspend_handle ||
                    iid == VI_experimental_patchpoint_void || iid == VI_experimental_patchpoint || iid == VI_fake_use ||
                    iid == VI_experimental_gc_statepoint || iid == VI_wasm_throw || iid == VI_wasm_rethrow || is_attached,
                    "Cannot invoke an intrinsic other than donothing, patchpoint, statepoint, coro_resume, coro_destroy, clang.arc.attachedcall or wasm.(re)throw", vq_val(i));
            }
        } else if ok == .BLOCK {
            vcheck(block(o).parent == block(bb).parent, "Referring to a basic block in another function!", vq_val(i));
        } else if ok == .ARGUMENT {
            vcheck(arg_parent(o) == block(bb).parent, "Referring to an argument in another function!", vq_val(i));
        } else if is_global_value(ok) {
            // one module per process
        } else if ok == .INST {
            ob := inst(o).parent;
            vcheck(ob != NONE && block(ob).parent == block(bb).parent, "Referring to an instruction in another function!", vq_val(i));
            vf_verify_dominates_use(i, ku);
        } else if ok == .INLINE_ASM {
            vcheck(ku == callee_idx, "Cannot take the address of an inline asm!", vq_val(i));
        } else if is_constant_kind(ok) {
            vf_visit_constant_exprs_recursively(o);
        }
    }
    vf_visit_instruction_metadata(i);   // verifier_md.jai: !fpmath ... !dbg and all attachments
    if vf.inst_md_failed { vf.inst_md_failed = false; return; }
    stamp_set(*vf.in_block, i, vf.bb_gen);
}

vf_verify_dominates_use :: (i: Value_Id, k: u32) {
    o := op(i, k);
    if inst_op(o) == .INVOKE && vf_invoke_normal_dest(o) == vf_invoke_unwind_dest(o) return;
    if inst_op(i) != .PHI && stamp_get(*vf.in_block, o) == vf.bb_gen return;
    vcheck(vf_dominates_use(o, op_use(i, k)), "Instruction does not dominate all uses!", vq_val(o), vq_val(i));
}

// DominatorTree::dominates(const Value *Def, const Use &U)
vf_dominates_use :: (def: Value_Id, u: Use_Id) -> bool { return dt_dominates_use(vf_dt(), def, u); }
