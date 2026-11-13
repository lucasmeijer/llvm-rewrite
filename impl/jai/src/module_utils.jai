// Module-level helpers used by the instrumentation passes (memprof, instrprof, pgo-instr-gen).
// Ported from llvm/lib/Transforms/Utils/ModuleUtils.cpp (appendToGlobalCtors, appendToUsed / appendToCompilerUsed,
// declareSanitizerInitFunction, createSanitizerCtor, createSanitizerCtorAndInitFunctions),
// Module::getOrInsertGlobal (llvm/lib/IR/Module.cpp) and
// SplitBlockAndInsertIfThen without a DomTreeUpdater (llvm/lib/Transforms/Utils/BasicBlockUtils.cpp).

// appendToGlobalArray (appendToGlobalCtors / appendToGlobalDtors)
mu_append_to_global_array :: (array_name: string, f: Value_Id, priority: s64, data: Value_Id) {
    current: [..] Value_Id; current.allocator = temp;
    elt_ty: Type_Id;
    gv := module_get_global_variable(array_name, true);
    if gv != NONE {
        elt_ty = type_elem(glob(gv).value_type);
        if glob(gv).has_init {
            init := gv_initializer(gv);   // Init->getNumOperands(): 0 for a zeroinitializer
            if vkind(init) == .C_ARRAY for k: 0..nops(init)-1 array_add(*current, op(init, k));
            else if vkind(init) != .C_ZERO && vkind(init) != .C_UNDEF && vkind(init) != .C_POISON fatal("appendToGlobalArray: unsupported % initializer", array_name);
        }
        gv_erase_from_parent(gv);
    } else {
        elt_ty = type_literal_struct(.[ir.t_i32, type_ptr(glob(f).addrspace), type_ptr(0)], false);
    }
    vals: [3] Value_Id;
    vals[0] = const_int(ir.t_i32, cast(u64) priority);
    vals[1] = f;
    vals[2] = ifx data != NONE then san_ce_pointer_cast(data, type_ptr(0)) else const_null_value(type_ptr(0));
    n := type_nsub(elt_ty);
    array_add(*current, const_aggregate(.C_STRUCT, elt_ty, array_view(vals, 0, n)));
    at := type_array(cast(u64) current.count, elt_ty);
    gv_create(at, false, .APPENDING, const_aggregate(.C_ARRAY, at, current), array_name, NONE, 0, dl.globals_as);
}
append_to_global_ctors :: (f: Value_Id, priority: s64, data: Value_Id = NONE) { mu_append_to_global_array("llvm.global_ctors", f, priority, data); }
append_to_global_dtors :: (f: Value_Id, priority: s64, data: Value_Id = NONE) { mu_append_to_global_array("llvm.global_dtors", f, priority, data); }

// appendToUsedList(M, Name, Values)
mu_append_to_used_list :: (name: string, values: [] Value_Id) {
    gv := module_get_global_variable(name);
    init: [..] Value_Id; init.allocator = temp;   // SmallSetVector<Constant *>
    if gv != NONE && glob(gv).has_init {
        ca := gv_initializer(gv);
        if vkind(ca) != .C_ARRAY fatal("% initializer that is not a ConstantArray is not supported", name);
        for k: 0..nops(ca)-1 { e := op(ca, k); if !array_find(init, e) array_add(*init, e); }
    }
    if gv != NONE gv_erase_from_parent(gv);
    pty := type_ptr(0);
    for values {
        e := ce_pointer_bitcast_or_addrspacecast(it, pty);
        if !array_find(init, e) array_add(*init, e);
    }
    if init.count == 0 return;
    aty := type_array(cast(u64) init.count, pty);
    nv := gv_create(aty, false, .APPENDING, const_aggregate(.C_ARRAY, aty, init), name, NONE, 0, dl.globals_as);
    glob(nv).section = "llvm.metadata";
}
append_to_used :: (v: Value_Id) { vs: [1] Value_Id; vs[0] = v; mu_append_to_used_list("llvm.used", vs); }
append_to_compiler_used :: (v: Value_Id) { vs: [1] Value_Id; vs[0] = v; mu_append_to_used_list("llvm.compiler.used", vs); }

// Module::getModuleFlag as a ConstantInt value (0 when absent or not an integer)
mu_module_flag_int :: (key: string) -> (bool, u64) {
    m := module_flag(key);
    if m == NONE || ir.mds[m].kind != .VALUE return false, 0;
    v := ir.mds[m].value;
    if v == NONE || vkind(v) != .C_INT return false, 0;
    return true, const_int_zext(v);
}

// Function::createWithDefaultAttr: fn_create_with_default_attr in pass_coro_cleanup.jai

// declareSanitizerInitFunction(M, InitName, InitArgTypes, Weak)
declare_sanitizer_init_function :: (init_name: string, arg_types: [] Type_Id, weak := false) -> Value_Id {
    ft := type_func(ir.t_void, arg_types, false);
    f := module_get_or_insert_function(init_name, ft);
    if vkind(f) != .FUNCTION fatal("declareSanitizerInitFunction: '%' is not a function", init_name);
    if weak && is_declaration(f) gv_set_linkage(f, .EXTERN_WEAK);
    return f;
}

// createSanitizerCtor(M, CtorName)
create_sanitizer_ctor :: (ctor_name: string) -> Value_Id {
    ctor := fn_create_with_default_attr(type_func(ir.t_void, .[], false), .INTERNAL, ctor_name, dl.program_as);
    fn_add_fn_attr_kind(ctor, .NoUnwind);
    san_set_kcfi_type(ctor, "_ZTSFvvE");   // sanitizer_common.jai
    bb := create_block(ctor, "");
    block_append_inst(bb, new_inst(.RET, ir.t_void, 0));
    append_to_used(ctor);
    return ctor;
}

// createSanitizerCtorAndInitFunctions(M, CtorName, InitName, InitArgTypes, InitArgs, VersionCheckName, Weak)
create_sanitizer_ctor_and_init_functions :: (ctor_name: string, init_name: string, arg_types: [] Type_Id, args: [] Value_Id, version_check_name: string, weak := false) -> (Value_Id, Value_Id) {
    init_fn := declare_sanitizer_init_function(init_name, arg_types, weak);
    ctor := create_sanitizer_ctor(ctor_name);
    b: Irb;
    ret_bb := fn_entry(ctor);
    if weak {
        set_name(ret_bb, "ret");
        entry := create_block(ctor, "entry", ret_bb);
        call_bb := create_block(ctor, "callfunc", ret_bb);
        irb_set_end(*b, entry);
        nn := irb_icmp(*b, ICMP_NE, init_fn, const_null_value(type_ptr(glob(init_fn).addrspace)));
        irb_cond_br(*b, nn, call_bb, ret_bb);
        irb_set_end(*b, call_bb);
    } else {
        irb_set_before(*b, block_terminator(ret_bb));
    }
    irb_call(*b, init_fn, args);
    if version_check_name.count {
        vc := module_get_or_insert_function(version_check_name, type_func(ir.t_void, .[], false));
        irb_call(*b, vc, .[]);
    }
    if weak irb_br(*b, ret_bb);
    return ctor, init_fn;
}

// Module::getOrInsertGlobal(Name, Ty): an existing GlobalVariable of that name, else a new external declaration
module_get_or_insert_global :: (name: string, ty: Type_Id) -> Value_Id {
    g := lookup_global(name);
    if g != NONE && vkind(g) == .GLOBAL_VAR return g;
    return gv_create(ty, false, .EXTERNAL, NONE, name, NONE, 0, dl.globals_as);
}

// Triple::supportsCOMDAT for the module's triple
triple_supports_comdat :: () -> bool {
    t := triple_parse(ir.triple);
    return !(t.obj == .MachO || t.obj == .XCOFF || t.obj == .DXContainer);
}

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable, BranchWeights) without DTU / LoopInfo: the new
// block's terminator
mu_split_block_and_insert_if_then :: (cond: Value_Id, split_before: Value_Id, unreachable: bool, weights: Md_Id = NONE) -> Value_Id {
    head := inst(split_before).parent;
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    dl_ := get_metadata(split_before, 0);
    then_bb := create_block(f, "", tail);
    term: Value_Id;
    if unreachable term = new_inst(.UNREACHABLE, ir.t_void, 0);
    else term = create_br(tail);
    block_append_inst(then_bb, term);
    if dl_ != NONE set_metadata(term, 0, dl_);
    old := block_terminator(head);
    nt := create_cond_br(cond, then_bb, tail);
    if weights != NONE set_metadata(nt, md_fixed("prof"), weights);
    // ReplaceInstWithInst
    if get_metadata(nt, 0) == NONE { d := get_metadata(old, 0); if d != NONE set_metadata(nt, 0, d); }
    insert_at_position(nt, head, old, false);
    drop_all_references(old);
    erase_inst(old);
    return term;
}
