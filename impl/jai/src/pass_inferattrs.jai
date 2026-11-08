// InferFunctionAttrs: a port of llvm/lib/Transforms/IPO/InferFunctionAttrs.cpp (InferFunctionAttrsPass,
// inferAllPrototypeAttributes) and Local.cpp's inferAttributesFromOthers. The library function attributes come
// from build_lib_calls.jai (inferNonMandatoryLibFuncAttrs).

// inferAttributesFromOthers(F)
infer_attributes_from_others :: (f: Value_Id) -> bool {
    changed := false;
    me := fn_memory_effects(f);
    if !fn_has_fn_attr(f, .NoSync) && me == 0 && !fn_has_fn_attr(f, .Convergent) {
        fn_add_fn_attr_kind(f, .NoSync);
        changed = true;
    }
    if !fn_has_fn_attr(f, .NoFree) && mem_only_reads(me) {
        fn_add_fn_attr_kind(f, .NoFree);
        changed = true;
    }
    if !fn_has_fn_attr(f, .MustProgress) && fn_has_fn_attr(f, .WillReturn) {
        fn_add_fn_attr_kind(f, .MustProgress);
        changed = true;
    }
    return changed;
}

// InferFunctionAttrsPass::run
inferattrs_run_module :: () {
    changed := false;
    for f: ir.m_functions {
        if !is_declaration(f) || fn_has_fn_attr(f, .OptimizeNone) continue;
        if !fn_has_fn_attr(f, .NoBuiltin) changed |= infer_non_mandatory_lib_func_attrs(f, tli_for(f));
        changed |= infer_attributes_from_others(f);
    }
    if !changed return;
    // PreservedAnalyses::none(): every function analysis and the module analyses go
    printer_note_ir_changed();
    for f: ir.m_functions fam_invalidate(f, PRESERVE_NONE);
    globals_aa = null;
}
