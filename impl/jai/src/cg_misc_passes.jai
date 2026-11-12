// Small codegen IR passes of llc's pipeline (codegen_pipeline.jai), and the guards of passes that are not ported:
// those detect exactly the IR the LLVM pass would change and fail loudly there (the pass is a no-op elsewhere).
//
//   UnreachableBlockElim        llvm/lib/CodeGen/UnreachableBlockElim.cpp (EliminateUnreachableBlocks,
//                               llvm/lib/Transforms/Utils/BasicBlockUtils.cpp)
//   ObjCARCContract (guard)     llvm/lib/Transforms/ObjCARC/ObjCARCContract.cpp: a no-op unless ModuleHasARC
//   X86LowerAMXIntrinsics / X86LowerAMXType (guard)   llvm/lib/Target/X86/X86LowerAMXIntrinsics.cpp, X86LowerAMXType.cpp
//   GCLowering / ShadowStackGCLowering (guard)  llvm/lib/CodeGen/GCRootLowering.cpp, ShadowStackGCLowering.cpp
//   InlineAsmPrepare (guard)    llvm/lib/CodeGen/InlineAsmPrepare.cpp: only callbr with a used result
//   SafeStack / StackProtector (guards)  llvm/lib/CodeGen/SafeStack.cpp, StackProtector.cpp
//   IndirectBrExpand (guard)    llvm/lib/CodeGen/IndirectBrExpandPass.cpp: only with retpoline features
//   ReplaceWithVeclib           llvm/lib/CodeGen/ReplaceWithVeclib.cpp: a no-op without -vector-library
//   DwarfEHPrepare (guard)      llvm/lib/CodeGen/DwarfEHPrepare.cpp: only functions with `resume`

// ---------------------------------------------------------------- UnreachableBlockElim

// EliminateUnreachableBlocks(F) (no DTU, KeepOneInputPHIs = false)
unreachable_block_elim_run :: (f: Value_Id) -> Preserved {
    reachable: Table(Value_Id, bool); reachable.allocator = temp;
    stack: [..] Value_Id; stack.allocator = temp;
    entry := fn_entry(f);
    table_set(*reachable, entry, true);
    array_add(*stack, entry);
    while stack.count {
        b := pop(*stack);
        t := block_terminator(b);
        if t == NONE continue;
        n := num_successors(t);
        for k: 0..cast(s64) n - 1 {
            s := get_successor(t, cast(u32) k);
            if !table_contains(*reachable, s) { table_set(*reachable, s, true); array_add(*stack, s); }
        }
    }
    dead: [..] Value_Id; dead.allocator = temp;
    for b: fn_blocks(f) if !table_contains(*reachable, b) array_add(*dead, b);
    if dead.count == 0 return PRESERVE_ALL;
    delete_dead_blocks(dead, null, false);
    // the legacy pass preserves the DominatorTree (stale but unchanged on the reachable part)
    pa: Preserved;
    preserve(*pa, .DOMTREE);
    return pa;
}

// ---------------------------------------------------------------- guards

cg_module_has_function :: (name: string) -> bool {
    for ir.m_functions if vkind(it) == .FUNCTION && vname(it) == name return true;
    return false;
}

// ObjCARCContract::run: `if (!ModuleHasARC(M)) return false`
objc_arc_contract_check :: (f: Value_Id) -> Preserved {
    names :: string.["llvm.objc.retain", "llvm.objc.release", "llvm.objc.autorelease",
        "llvm.objc.retainAutoreleasedReturnValue", "llvm.objc.retainBlock", "llvm.objc.autoreleaseReturnValue",
        "llvm.objc.autoreleasePoolPush", "llvm.objc.loadWeakRetained", "llvm.objc.loadWeak", "llvm.objc.destroyWeak",
        "llvm.objc.initWeak", "llvm.objc.copyWeak", "llvm.objc.retainedObject", "llvm.objc.unretainedObject",
        "llvm.objc.unretainedPointer", "llvm.objc.clang.arc.noop.use", "llvm.objc.clang.arc.use"];
    for names if cg_module_has_function(it) fatal("objc-arc-contract: modules using ObjC ARC intrinsics (%) are not supported yet", it);
    return PRESERVE_ALL;
}

cg_type_has_amx :: (t: Type_Id) -> bool {
    k := type_kind(t);
    if k == .X86_AMX return true;
    if k == .VECTOR || k == .ARRAY return cg_type_has_amx(type_elem(t));
    return false;
}
// X86LowerAMXIntrinsics (O0 / optnone only) lowers the llvm.x86.t*.internal intrinsics; X86LowerAMXType rewrites
// x86_amx loads, stores, bitcasts and phis. Both are no-ops on functions without AMX values or tile intrinsics.
x86_lower_amx_check :: (f: Value_Id, intrinsics: bool) -> Preserved {
    nargs := func_nparams(glob(f).value_type);
    for k: 0..cast(s64) nargs - 1 if cg_type_has_amx(vtype(fn_arg(f, cast(u32) k))) fatal("% : x86_amx values are not supported yet", ifx intrinsics then "x86-lower-amx-intrinsics" else "x86-lower-amx-type");
    for i: fn_insts(f) {
        if cg_type_has_amx(vtype(i)) fatal("% : x86_amx values are not supported yet", ifx intrinsics then "x86-lower-amx-intrinsics" else "x86-lower-amx-type");
        if inst_op(i) == .CALL {
            c := call_called_function(i);
            if c != NONE && begins_with(vname(c), "llvm.x86.") && (contains(vname(c), "tile") || contains(vname(c), ".amx."))
                fatal("x86-lower-amx: AMX intrinsics are not supported yet (%)", vname(c));
        }
    }
    return PRESERVE_ALL;
}

// GCLowering::runOnFunction: `if (!F.hasGC()) return false`; ShadowStackGCLowering only acts on gc "shadow-stack".
gc_lowering_check :: (f: Value_Id) -> Preserved {
    if glob(f).gc.count fatal("gc-lowering: functions with a garbage collector (gc \"%\") are not supported yet", glob(f).gc);
    return PRESERVE_ALL;
}

// InlineAsmPrepare: findCallBrs (callbr with a non-void, used result)
inline_asm_prepare_run :: (f: Value_Id) -> Preserved {
    for b: fn_blocks(f) {
        t := block_terminator(b);
        if t != NONE && inst_op(t) == .CALLBR && type_kind(vtype(t)) != .VOID && has_uses(t)
            fatal("inline-asm-prepare: callbr with a used result is not supported yet");
    }
    return PRESERVE_ALL;
}

// SafeStack::run: only functions with the safestack attribute
safe_stack_check :: (f: Value_Id) -> Preserved {
    if fn_has_fn_attr(f, .SafeStack) fatal("safe-stack: functions with the safestack attribute are not supported yet");
    return PRESERVE_ALL;
}

// StackProtector::runOnFunction: SSPLayoutAnalysis::requiresStackProtector needs ssp / sspstrong / sspreq
// (the stack-protector-guard options only act through those)
stack_protector_check :: (f: Value_Id) -> Preserved {
    if fn_has_fn_attr(f, .StackProtect) || fn_has_fn_attr(f, .StackProtectStrong) || fn_has_fn_attr(f, .StackProtectReq)
        fatal("stack-protector: functions with ssp / sspstrong / sspreq are not supported yet");
    return PRESERVE_ALL;
}

// IndirectBrExpandPass: `if (!STI.enableIndirectBrExpand()) return false` (X86: useIndirectThunkBranches, i.e. the
// retpoline / lvi-cfi features), then nothing to do without indirectbr.
indirectbr_expand_run :: (f: Value_Id) -> Preserved {
    has_ibr := false;
    for b: fn_blocks(f) { t := block_terminator(b); if t != NONE && inst_op(t) == .INDIRECTBR has_ibr = true; }
    if !has_ibr return PRESERVE_ALL;
    feats := "";
    for attr_set_items(attr_list_fn(glob(f).attrs)) if it.kind == .STRING_ATTR && it.key == "target-features" feats = it.val;
    if contains(feats, "+retpoline") || contains(feats, "+lvi-cfi") || contains(tti_opts.mattr, "retpoline") || contains(tti_opts.mattr, "lvi-cfi")
        fatal("indirectbr-expand: indirectbr with retpoline / lvi-cfi is not supported yet");
    return PRESERVE_ALL;
}

// ReplaceWithVeclib::runImpl: `if (TLI.getVectorizationLibrary() == NoLibrary) return false` (llc has no
// -vector-library here: TargetOptions::VecLib defaults to NoLibrary)
replace_with_veclib_run :: (f: Value_Id) -> Preserved { return PRESERVE_ALL; }

// DwarfEHPrepare::InsertUnwindResumeCalls: nothing to do without `resume`
dwarf_eh_prepare_run :: (f: Value_Id) -> Preserved {
    for b: fn_blocks(f) {
        t := block_terminator(b);
        if t != NONE && inst_op(t) == .RESUME fatal("dwarf-eh-prepare: lowering `resume` is not supported yet");
    }
    return PRESERVE_ALL;
}
