// A port of llvm/lib/Transforms/Utils/BuildLibCalls.cpp: inferNonMandatoryLibFuncAttrs, getOrInsertLibFunc,
// isLibFuncEmittable, hasFloatFn / getFloatFn, markRegisterParameterAttributes and the emit* helpers.
// The emit* helpers build with InstCombine's IRBuilder (icb_*, ic_core.jai), which is the only IRBuilder
// LibCallSimplifier is used with here. Every helper takes the caller's TargetLibraryInfo (`t`, tli.jai).

// ---------------------------------------------------------------- Function attribute editing (Function.cpp)

fn_set_attr_list :: (f: Value_Id, l: u32) { glob(f).attrs = l; }
fn_param_attr_set :: (f: Value_Id, k: u32) -> u32 { return attr_list_param(glob(f).attrs, k); }
fn_has_param_attr :: (f: Value_Id, k: u32, kind: Attr_Kind) -> bool { return attr_set_has(fn_param_attr_set(f, k), kind); }
fn_has_ret_attr :: (f: Value_Id, kind: Attr_Kind) -> bool { return attr_set_has(attr_list_ret(glob(f).attrs), kind); }
// Function::addFnAttr(Attribute)
fn_add_fn_attr :: (f: Value_Id, a: Attr) {
    l := glob(f).attrs;
    fn_set_attr_list(f, attr_list_with_fn(l, attr_set_with(attr_list_fn(l), a)));
}
fn_add_fn_attr_kind :: (f: Value_Id, k: Attr_Kind) { a: Attr; a.kind = k; a.ty = NONE; fn_add_fn_attr(f, a); }
fn_add_fn_str_attr :: (f: Value_Id, key: string, val: string) {
    a: Attr; a.kind = .STRING_ATTR; a.ty = NONE; a.key = key; a.val = val;
    l := glob(f).attrs;
    items: [..] Attr; items.allocator = temp;
    for attr_set_items(attr_list_fn(l)) if !(it.kind == .STRING_ATTR && it.key == key) array_add(*items, it);
    array_add(*items, a);
    fn_set_attr_list(f, attr_list_with_fn(l, attr_set_get(items)));
}
// Function::addParamAttr(ArgNo, Attribute)
fn_add_param_attr :: (f: Value_Id, k: u32, a: Attr) {
    l := glob(f).attrs;
    fn_set_attr_list(f, attr_list_with_param(l, k, attr_set_with(attr_list_param(l, k), a)));
}
fn_add_param_attr_kind :: (f: Value_Id, k: u32, kind: Attr_Kind) { a: Attr; a.kind = kind; a.ty = NONE; fn_add_param_attr(f, k, a); }
// Function::addRetAttr
fn_add_ret_attr_kind :: (f: Value_Id, kind: Attr_Kind) {
    a: Attr; a.kind = kind; a.ty = NONE;
    l := glob(f).attrs;
    ps := ifx l == 0 then .[] else ir.attr_lists[l].params;
    fn_set_attr_list(f, attr_list_get(attr_list_fn(l), attr_set_with(attr_list_ret(l), a), ps));
}
// Function::getMemoryEffects / setMemoryEffects
fn_memory_effects :: (f: Value_Id) -> u64 { return fn_memory(f); }
fn_set_memory_effects :: (f: Value_Id, me: u64) { a: Attr; a.kind = .Memory; a.ty = NONE; a.ival = me; fn_add_fn_attr(f, a); }

// MemoryEffects constructors (ModRef.h); LOC_ARG = 0
me_none :: () -> u64 { return 0; }
me_arg_mem_only :: (mr: u64 = 3) -> u64 { return mem_set(0, LOC_ARG, mr); }
me_inaccessible_or_arg_mem_only :: (mr: u64 = 3) -> u64 { return mem_set(mem_set(0, LOC_ARG, mr), LOC_INACCESSIBLE, mr); }
me_inaccessible_or_errno_mem_only :: (inacc: u64, errno: u64) -> u64 { return mem_set(mem_set(0, LOC_INACCESSIBLE, inacc), LOC_ERRNO, errno); }
me_inaccessible_or_arg_or_errno_mem_only :: (ia: u64, errno: u64) -> u64 {
    return mem_set(mem_set(mem_set(0, LOC_INACCESSIBLE, ia), LOC_ARG, ia), LOC_ERRNO, errno);
}
me_errno_mem_only :: (mr: u64) -> u64 { return mem_set(0, LOC_ERRNO, mr); }
me_argument_or_errno_mem_only :: (arg: u64, errno: u64) -> u64 { return mem_set(mem_set(0, LOC_ARG, arg), LOC_ERRNO, errno); }

// ---------------------------------------------------------------- the set* helpers of BuildLibCalls.cpp

blc_set_memory_effects :: (f: Value_Id, me: u64) -> bool {
    orig := fn_memory_effects(f);
    nme := orig & me;
    if orig == nme return false;
    fn_set_memory_effects(f, nme);
    return true;
}
blc_set_does_not_access_memory :: (f: Value_Id) -> bool {
    if fn_memory_effects(f) == 0 return false;
    fn_set_memory_effects(f, 0);
    return true;
}
blc_set_fn_kind :: (f: Value_Id, k: Attr_Kind) -> bool {
    if fn_has_fn_attr(f, k) return false;
    fn_add_fn_attr_kind(f, k);
    return true;
}
blc_set_is_cold :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .Cold); }
blc_set_no_return :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NoReturn); }
blc_set_only_reads_memory :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, mem_all(1)); }
blc_set_only_writes_memory :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, mem_all(2)); }
blc_set_only_accesses_arg_memory :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_arg_mem_only()); }
blc_set_only_accesses_inaccessible_mem_or_arg_mem :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_inaccessible_or_arg_mem_only()); }
blc_set_only_accesses_inaccessible_mem_or_errno_mem :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_inaccessible_or_errno_mem_only(3, 2)); }
blc_set_only_accesses_inaccessible_mem_or_arg_mem_or_errno_mem :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_inaccessible_or_arg_or_errno_mem_only(3, 2)); }
blc_set_only_writes_errno_memory :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_errno_mem_only(2)); }
blc_set_only_writes_arg_mem_or_errno_mem :: (f: Value_Id) -> bool { return blc_set_memory_effects(f, me_argument_or_errno_mem_only(2, 2)); }
// Function::doesNotThrow / setDoesNotThrow
blc_set_does_not_throw :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NoUnwind); }
blc_set_does_not_callback :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NoCallback); }
blc_set_ret_does_not_alias :: (f: Value_Id) -> bool {
    if fn_has_ret_attr(f, .NoAlias) return false;
    fn_add_ret_attr_kind(f, .NoAlias);
    return true;
}
blc_set_does_not_capture :: (f: Value_Id, k: u32) -> bool {
    if fn_has_param_attr(f, k, .Captures) return false;
    a: Attr; a.kind = .Captures; a.ty = NONE; a.ival = 0;   // CaptureInfo::none()
    fn_add_param_attr(f, k, a);
    return true;
}
blc_set_param_kind :: (f: Value_Id, k: u32, kind: Attr_Kind) -> bool {
    if fn_has_param_attr(f, k, kind) return false;
    fn_add_param_attr_kind(f, k, kind);
    return true;
}
blc_set_does_not_alias :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .NoAlias); }
blc_set_does_not_sync :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NoSync); }
blc_set_only_reads_memory_arg :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .ReadOnly); }
blc_set_only_writes_memory_arg :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .WriteOnly); }
blc_set_ret_no_undef :: (f: Value_Id) -> bool {
    if func_ret(glob(f).value_type) != ir.t_void && !fn_has_ret_attr(f, .NoUndef) {
        fn_add_ret_attr_kind(f, .NoUndef);
        return true;
    }
    return false;
}
blc_set_args_no_undef :: (f: Value_Id) -> bool {
    changed := false;
    n := func_nparams(glob(f).value_type);
    for k: 0..cast(s64) n - 1 {
        if !fn_has_param_attr(f, cast(u32) k, .NoUndef) { fn_add_param_attr_kind(f, cast(u32) k, .NoUndef); changed = true; }
    }
    return changed;
}
blc_set_arg_no_undef :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .NoUndef); }
blc_set_ret_and_args_no_undef :: (f: Value_Id) -> bool {
    a := blc_set_ret_no_undef(f);
    b := blc_set_args_no_undef(f);
    return a || b;
}
blc_set_returned_arg :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .Returned); }
blc_set_non_lazy_bind :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NonLazyBind); }
blc_set_does_not_free_memory :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .NoFree); }
blc_set_will_return :: (f: Value_Id) -> bool { return blc_set_fn_kind(f, .WillReturn); }
blc_set_aligned_alloc_param :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .AllocAlign); }
blc_set_allocated_pointer_param :: (f: Value_Id, k: u32) -> bool { return blc_set_param_kind(f, k, .AllocatedPointer); }
// setAllocSize(F, ElemSizeArg, NumElemsArg): AllocSize packs (ElemSizeArg << 32) | NumElemsArg (0xFFFFFFFF = none)
blc_set_alloc_size :: (f: Value_Id, elem: u32, num: u32 = 0xFFFF_FFFF) -> bool {
    if fn_has_fn_attr(f, .AllocSize) return false;
    a: Attr; a.kind = .AllocSize; a.ty = NONE; a.ival = ((cast(u64) elem) << 32) | cast(u64) num;
    fn_add_fn_attr(f, a);
    return true;
}
blc_set_alloc_family :: (f: Value_Id, family: string) -> bool {
    if fn_has_str_attr(f, "alloc-family") return false;
    fn_add_fn_str_attr(f, "alloc-family", family);
    return true;
}
AFK_ALIGNED :: 32;
blc_set_alloc_kind :: (f: Value_Id, k: u64) -> bool {
    if fn_has_fn_attr(f, .AllocKind) return false;
    a: Attr; a.kind = .AllocKind; a.ty = NONE; a.ival = k;
    fn_add_fn_attr(f, a);
    return true;
}

// isLibFreeFunction(F, TLIFn) (MemoryBuiltins.cpp)
is_lib_free_function :: (f: Value_Id, lf: Lib_Func) -> bool {
    name := tli_standard_name(lf);
    found := false; nparams: s32;
    for FREE_FNS if it.name == name { found = true; nparams = it.nparams; break; }
    if !found return (fn_alloc_kind(f) & AFK_FREE) != 0;
    ft := glob(f).value_type;
    if func_ret(ft) != ir.t_void return false;
    if func_nparams(ft) != cast(u32) nparams return false;
    if !is_ptr_type(func_param(ft, 0)) return false;
    return true;
}
// isReallocLikeFn(F)
is_realloc_like_fn :: (f: Value_Id) -> bool { return (fn_alloc_kind(f) & AFK_REALLOC) != 0; }

// inferNonMandatoryLibFuncAttrs(M, Name, TLI)
infer_non_mandatory_lib_func_attrs_name :: (name: string, t: *Tli) -> bool {
    f := lookup_global(name);
    if f == NONE || vkind(f) != .FUNCTION return false;
    return infer_non_mandatory_lib_func_attrs(f, t);
}

// inferNonMandatoryLibFuncAttrs(F, TLI)
infer_non_mandatory_lib_func_attrs :: (F: Value_Id, t: *Tli) -> bool {
    ok, lf := tli_lookup_fn(F);
    if !(ok && tli_func_has(t, lf)) return false;
    Changed := false;
    C :: (b: bool) #expand { if b `Changed = true; }
    if module_get_flag("RtLibUseGOT") != NONE {
        okf, v := md_const_int_value(module_get_flag("RtLibUseGOT"));
        if okf && v != 0 C(blc_set_non_lazy_bind(F));
    }
    if lf == {
        case .nan; #through; case .nanf; #through; case .nanl; #through;
        case .strlen; #through; case .strnlen; #through; case .wcslen;
            C(blc_set_only_reads_memory(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F));
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_sync(F));
        case .strchr; #through; case .strrchr;
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_reads_memory(F)); C(blc_set_does_not_throw(F));
            C(blc_set_does_not_callback(F)); C(blc_set_will_return(F)); C(blc_set_does_not_sync(F));
        case .strtol; #through; case .strtod; #through; case .strtof; #through; case .strtoul; #through;
        case .strtoll; #through; case .strtold; #through; case .strtoull;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .strcat; #through; case .strncat;
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F));
            C(blc_set_will_return(F)); C(blc_set_returned_arg(F, 0)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_only_reads_memory_arg(F, 1)); C(blc_set_does_not_alias(F, 0)); C(blc_set_does_not_alias(F, 1));
            C(blc_set_does_not_sync(F));
        case .strcpy; #through; case .strncpy; #through; case .stpcpy; #through; case .stpncpy;
            if lf == .strcpy || lf == .strncpy C(blc_set_returned_arg(F, 0));
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_writes_memory_arg(F, 0));
            C(blc_set_only_reads_memory_arg(F, 1)); C(blc_set_does_not_alias(F, 0)); C(blc_set_does_not_alias(F, 1));
            C(blc_set_does_not_sync(F));
        case .strxfrm;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .strcmp; #through; case .strspn; #through; case .strncmp; #through; case .strcspn;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_will_return(F)); C(blc_set_only_reads_memory(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_does_not_sync(F));
        case .strcoll; #through; case .strcasecmp; #through; case .strncasecmp;
            C(blc_set_only_reads_memory(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1));
        case .strstr; #through; case .strpbrk;
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_reads_memory(F)); C(blc_set_does_not_throw(F));
            C(blc_set_does_not_callback(F)); C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_does_not_sync(F));
        case .strtok; #through; case .strtok_r;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .scanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .setbuf; #through; case .setvbuf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .strndup; #through; case .strdup;
            if lf == .strndup C(blc_set_arg_no_undef(F, 1));
            C(blc_set_alloc_family(F, "malloc")); C(blc_set_only_accesses_inaccessible_mem_or_arg_mem_or_errno_mem(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .stat; #through; case .statvfs;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .sscanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0)); C(blc_set_only_reads_memory_arg(F, 1));
        case .sprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_alias(F, 0)); C(blc_set_only_writes_memory_arg(F, 0)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_only_reads_memory_arg(F, 1));
        case .snprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_alias(F, 0)); C(blc_set_only_writes_memory_arg(F, 0)); C(blc_set_does_not_capture(F, 2));
            C(blc_set_only_reads_memory_arg(F, 2));
        case .setitimer;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_does_not_capture(F, 2)); C(blc_set_only_reads_memory_arg(F, 1));
        case .system;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .aligned_alloc; #through; case .valloc; #through; case .malloc; #through; case .vec_malloc; #through;
        case .pvalloc;
            if lf == .aligned_alloc {
                C(blc_set_aligned_alloc_param(F, 0)); C(blc_set_alloc_size(F, 1));
                C(blc_set_alloc_kind(F, AFK_ALLOC | AFK_UNINITIALIZED | AFK_ALIGNED));
            }
            if lf != .pvalloc C(blc_set_alloc_size(F, 0));
            C(blc_set_alloc_family(F, ifx lf == .vec_malloc then "vec_malloc" else "malloc"));
            C(blc_set_alloc_kind(F, AFK_ALLOC | AFK_UNINITIALIZED));
            C(blc_set_only_accesses_inaccessible_mem_or_errno_mem(F)); C(blc_set_ret_and_args_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
        case .memcmp;
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_reads_memory(F)); C(blc_set_does_not_throw(F));
            C(blc_set_does_not_callback(F)); C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_does_not_sync(F));
        case .memchr; #through; case .memrchr;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_only_reads_memory(F)); C(blc_set_will_return(F)); C(blc_set_does_not_sync(F));
        case .modf; #through; case .modff; #through; case .modfl;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_will_return(F));
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_writes_memory(F)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_does_not_sync(F));
        case .memcpy;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_alias(F, 0)); C(blc_set_returned_arg(F, 0));
            C(blc_set_only_writes_memory_arg(F, 0)); C(blc_set_does_not_alias(F, 1)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_only_reads_memory_arg(F, 1)); C(blc_set_does_not_sync(F));
        case .memmove;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_will_return(F)); C(blc_set_returned_arg(F, 0)); C(blc_set_only_writes_memory_arg(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1)); C(blc_set_does_not_sync(F));
        case .mempcpy; #through; case .memccpy; #through; case .memcpy_chk;
            if lf != .memcpy_chk C(blc_set_will_return(F));
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_does_not_alias(F, 0)); C(blc_set_only_writes_memory_arg(F, 0)); C(blc_set_does_not_alias(F, 1));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1)); C(blc_set_does_not_sync(F));
        case .memalign;
            C(blc_set_alloc_family(F, "malloc")); C(blc_set_alloc_kind(F, AFK_ALLOC | AFK_ALIGNED | AFK_UNINITIALIZED));
            C(blc_set_alloc_size(F, 1)); C(blc_set_aligned_alloc_param(F, 0));
            C(blc_set_only_accesses_inaccessible_mem_or_errno_mem(F)); C(blc_set_ret_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
        case .mkdir;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .mktime;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0));
        case .realloc; #through; case .reallocf; #through; case .vec_realloc;
            C(blc_set_alloc_family(F, ifx lf == .vec_realloc then "vec_malloc" else "malloc"));
            C(blc_set_alloc_kind(F, AFK_REALLOC)); C(blc_set_allocated_pointer_param(F, 0)); C(blc_set_alloc_size(F, 1));
            C(blc_set_only_accesses_inaccessible_mem_or_arg_mem_or_errno_mem(F)); C(blc_set_ret_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_arg_no_undef(F, 1));
        case .reallocarray;
            C(blc_set_alloc_family(F, "malloc")); C(blc_set_alloc_kind(F, AFK_REALLOC));
            C(blc_set_allocated_pointer_param(F, 0)); C(blc_set_alloc_size(F, 1, 2));
            C(blc_set_only_accesses_inaccessible_mem_or_arg_mem_or_errno_mem(F)); C(blc_set_ret_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_arg_no_undef(F, 1)); C(blc_set_arg_no_undef(F, 2));
        case .read;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 1));
        case .rewind;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .rmdir; #through; case .remove_; #through; case .realpath;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .rename;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0)); C(blc_set_only_reads_memory_arg(F, 1));
        case .readlink;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .write;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .bcopy;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
            C(blc_set_only_writes_memory_arg(F, 1)); C(blc_set_does_not_capture(F, 1)); C(blc_set_does_not_sync(F));
        case .bcmp;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_only_reads_memory(F)); C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_does_not_sync(F));
        case .bzero;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_accesses_arg_memory(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_only_writes_memory_arg(F, 0));
            C(blc_set_does_not_sync(F));
        case .calloc; #through; case .vec_calloc;
            C(blc_set_alloc_family(F, ifx lf == .vec_calloc then "vec_malloc" else "malloc"));
            C(blc_set_alloc_kind(F, AFK_ALLOC | AFK_ZEROED)); C(blc_set_alloc_size(F, 0, 1));
            C(blc_set_only_accesses_inaccessible_mem_or_errno_mem(F)); C(blc_set_ret_and_args_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
        case .chmod; #through; case .chown;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .ctermid; #through; case .clearerr; #through; case .closedir;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .atoi; #through; case .atol; #through; case .atof; #through; case .atoll;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_only_reads_memory(F));
            C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_sync(F));
        case .access;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .fopen;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
            C(blc_set_only_reads_memory_arg(F, 1));
        case .fdopen;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .feof;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .free; #through; case .vec_free;
            C(blc_set_alloc_family(F, ifx lf == .vec_free then "vec_malloc" else "malloc"));
            C(blc_set_alloc_kind(F, AFK_FREE)); C(blc_set_allocated_pointer_param(F, 0));
            C(blc_set_only_accesses_inaccessible_mem_or_arg_mem(F)); C(blc_set_args_no_undef(F));
            C(blc_set_does_not_throw(F)); C(blc_set_will_return(F)); C(blc_set_does_not_capture(F, 0));
        case .fseek; #through; case .ftell; #through; case .fgetc; #through; case .fgetc_unlocked; #through;
        case .fseeko; #through; case .ftello; #through; case .fileno; #through; case .fflush; #through;
        case .fclose; #through; case .fsetpos; #through; case .flockfile; #through; case .funlockfile; #through;
        case .ftrylockfile;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .ferror;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory(F));
        case .fputc; #through; case .fputc_unlocked; #through; case .fstat;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .frexp; #through; case .frexpf; #through; case .frexpl;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_will_return(F));
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_writes_memory(F)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_does_not_sync(F));
        case .fstatvfs;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .fgets; #through; case .fgets_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 2));
            C(blc_set_only_writes_memory_arg(F, 0));
        case .fread; #through; case .fread_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 3)); C(blc_set_only_writes_memory_arg(F, 0));
        case .fwrite; #through; case .fwrite_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 3)); C(blc_set_only_reads_memory_arg(F, 0));
        case .fputs; #through; case .fputs_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .fscanf; #through; case .fprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .fgetpos;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1));
        case .getc; #through; case .getlogin_r; #through; case .getc_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .getenv;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_only_reads_memory(F));
            C(blc_set_does_not_capture(F, 0));
        case .gets; #through; case .getchar; #through; case .getchar_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F));
        case .getitimer;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .getpwnam;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .ungetc;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .uname;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .unlink; #through; case .unsetenv;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .utime; #through; case .utimes;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0)); C(blc_set_only_reads_memory_arg(F, 1));
        case .putc; #through; case .putc_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .puts; #through; case .printf; #through; case .perror;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .pread;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 1));
        case .pwrite;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .putchar; #through; case .putchar_unlocked;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F));
        case .popen;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
            C(blc_set_only_reads_memory_arg(F, 1));
        case .pclose;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .vscanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .vsscanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0)); C(blc_set_only_reads_memory_arg(F, 1));
        case .vfscanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .vprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .vfprintf; #through; case .vsprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
        case .vsnprintf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 2)); C(blc_set_only_reads_memory_arg(F, 2));
        case .open;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .opendir;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .tmpfile;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
        case .times;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .htonl; #through; case .htons; #through; case .ntohl; #through; case .ntohs;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_does_not_access_memory(F));
        case .lstat;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .lchown;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .qsort;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 3));
        case .dunder_strndup; #through; case .dunder_strdup;
            if lf == .dunder_strndup C(blc_set_arg_no_undef(F, 1));
            C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F)); C(blc_set_will_return(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .dunder_strtok_r;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_does_not_capture(F, 1));
            C(blc_set_only_reads_memory_arg(F, 1));
        case .under_IO_getc;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .under_IO_putc;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .dunder_isoc99_scanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_only_reads_memory_arg(F, 0));
        case .stat64; #through; case .lstat64; #through; case .statvfs64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
        case .dunder_isoc99_sscanf;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0)); C(blc_set_only_reads_memory_arg(F, 1));
        case .fopen64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
            C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 0));
            C(blc_set_only_reads_memory_arg(F, 1));
        case .fseeko64; #through; case .ftello64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
        case .tmpfile64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_ret_does_not_alias(F));
        case .fstat64; #through; case .fstatvfs64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 1));
        case .open64;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_capture(F, 0)); C(blc_set_only_reads_memory_arg(F, 0));
        case .gettimeofday;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_throw(F)); C(blc_set_does_not_capture(F, 0));
            C(blc_set_does_not_capture(F, 1));
        case .memset_pattern4; #through; case .memset_pattern8; #through; case .memset_pattern16; #through;
        case .memset; #through; case .memset_chk;
            if lf == .memset_pattern4 || lf == .memset_pattern8 || lf == .memset_pattern16 {
                C(blc_set_does_not_capture(F, 0)); C(blc_set_does_not_capture(F, 1)); C(blc_set_only_reads_memory_arg(F, 1));
            }
            if lf != .memset_chk C(blc_set_will_return(F));
            C(blc_set_only_accesses_arg_memory(F)); C(blc_set_only_writes_memory_arg(F, 0)); C(blc_set_does_not_throw(F));
            C(blc_set_does_not_callback(F)); C(blc_set_does_not_sync(F));
        case .abort;
            C(blc_set_is_cold(F)); C(blc_set_no_return(F)); C(blc_set_does_not_throw(F));
        case .terminate;
            C(blc_set_is_cold(F)); C(blc_set_no_return(F));
        case .cxa_throw;
            C(blc_set_is_cold(F)); C(blc_set_no_return(F));
            return Changed;   // no `nofree` on __cxa_throw
        case .nvvm_reflect;
            C(blc_set_ret_and_args_no_undef(F)); C(blc_set_does_not_access_memory(F)); C(blc_set_does_not_throw(F));
        case .acos; #through; case .acosf; #through; case .acosh; #through; case .acoshf; #through;
        case .acoshl; #through; case .acosl; #through; case .asin; #through; case .asinf; #through;
        case .asinh; #through; case .asinhf; #through; case .asinhl; #through; case .asinl; #through;
        case .atan; #through; case .atan2; #through; case .atan2f; #through; case .atan2l; #through;
        case .atanf; #through; case .atanh; #through; case .atanhf; #through; case .atanhl; #through;
        case .atanl; #through; case .cos; #through; case .cosh; #through; case .coshf; #through;
        case .coshl; #through; case .cosf; #through; case .cosl; #through; case .cospi; #through;
        case .cospif; #through; case .erf; #through; case .erff; #through; case .erfl; #through;
        case .tgamma; #through; case .tgammaf; #through; case .tgammal; #through; case .exp; #through;
        case .expf; #through; case .expl; #through; case .exp2; #through; case .exp2f; #through;
        case .exp2l; #through; case .expm1; #through; case .expm1f; #through; case .expm1l; #through;
        case .fdim; #through; case .fdiml; #through; case .fdimf; #through; case .fmod; #through;
        case .fmodf; #through; case .fmodl; #through; case .hypot; #through; case .hypotf; #through;
        case .hypotl; #through; case .ldexp; #through; case .ldexpf; #through; case .ldexpl; #through;
        case .log; #through; case .log10; #through; case .log10f; #through; case .log10l; #through;
        case .log1p; #through; case .log1pf; #through; case .log1pl; #through; case .log2; #through;
        case .log2f; #through; case .log2l; #through; case .logb; #through; case .logbf; #through;
        case .logbl; #through; case .ilogb; #through; case .ilogbf; #through; case .ilogbl; #through;
        case .logf; #through; case .logl; #through; case .nextafter; #through; case .nextafterf; #through;
        case .nextafterl; #through; case .nexttoward; #through; case .nexttowardf; #through;
        case .nexttowardl; #through; case .pow; #through; case .powf; #through; case .powl; #through;
        case .remainder; #through; case .remainderf; #through; case .remainderl; #through; case .rint; #through;
        case .rintf; #through; case .rintl; #through; case .scalbln; #through; case .scalblnf; #through;
        case .scalblnl; #through; case .scalbn; #through; case .scalbnf; #through; case .scalbnl; #through;
        case .sin; #through; case .sincospif_stret; #through; case .sinf; #through; case .sinh; #through;
        case .sinhf; #through; case .sinhl; #through; case .sinl; #through; case .sinpi; #through;
        case .sinpif; #through; case .sqrt; #through; case .sqrtf; #through; case .sqrtl; #through;
        case .tan; #through; case .tanf; #through; case .tanh; #through; case .tanhf; #through;
        case .tanhl; #through; case .tanl;
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_does_not_free_memory(F));
            C(blc_set_will_return(F)); C(blc_set_only_writes_errno_memory(F)); C(blc_set_does_not_sync(F));
        case .abs; #through; case .cbrt; #through; case .cbrtf; #through; case .cbrtl; #through;
        case .copysign; #through; case .copysignf; #through; case .copysignl; #through; case .ceil; #through;
        case .ceilf; #through; case .ceill; #through; case .fabs; #through; case .fabsf; #through;
        case .fabsl; #through; case .ffs; #through; case .ffsl; #through; case .ffsll; #through;
        case .floor; #through; case .floorf; #through; case .floorl; #through; case .fls; #through;
        case .flsl; #through; case .flsll; #through; case .fmax; #through; case .fmaxf; #through;
        case .fmaxl; #through; case .fmin; #through; case .fminf; #through; case .fminl; #through;
        case .fmaximum_num; #through; case .fmaximum_numf; #through; case .fmaximum_numl; #through;
        case .fminimum_num; #through; case .fminimum_numf; #through; case .fminimum_numl; #through;
        case .labs; #through; case .llabs; #through; case .nearbyint; #through; case .nearbyintf; #through;
        case .nearbyintl; #through; case .round; #through; case .roundf; #through; case .roundl; #through;
        case .roundeven; #through; case .roundevenf; #through; case .roundevenl; #through;
        case .toascii; #through; case .trunc; #through; case .truncf; #through; case .truncl; #through;
        case .isascii; #through; case .isdigit;
            if lf != .isascii && lf != .isdigit C(blc_set_does_not_access_memory(F));
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_does_not_free_memory(F));
            C(blc_set_will_return(F));
        case .sincos; #through; case .sincosf; #through; case .sincosl; #through;
        case .remquo; #through; case .remquof; #through; case .remquol;
            if lf == .sincos || lf == .sincosf || lf == .sincosl {
                C(blc_set_does_not_capture(F, 1)); C(blc_set_only_writes_memory_arg(F, 1));
            }
            C(blc_set_does_not_throw(F)); C(blc_set_does_not_callback(F)); C(blc_set_does_not_free_memory(F));
            C(blc_set_only_writes_memory_arg(F, 2)); C(blc_set_does_not_capture(F, 2)); C(blc_set_will_return(F));
            C(blc_set_only_writes_arg_mem_or_errno_mem(F)); C(blc_set_does_not_sync(F));
    }
    // after AllocKind has been inferred, so free-like and realloc-like functions are recognized
    if !is_lib_free_function(F, lf) && !is_realloc_like_fn(F) C(blc_set_does_not_free_memory(F));
    return Changed;
}

// setArgExtAttr / setRetExtAttr
blc_set_arg_ext_attr :: (f: Value_Id, k: u32, signed := true) {
    ext := tli_ext_attr_for_i32_param(signed);
    if ext != .NONE_ATTR && !fn_has_param_attr(f, k, ext) fn_add_param_attr_kind(f, k, ext);
}
blc_set_ret_ext_attr :: (f: Value_Id, signed := true) {
    ext := tli_ext_attr_for_i32_return(signed);
    if ext != .NONE_ATTR && !fn_has_ret_attr(f, ext) fn_add_ret_attr_kind(f, ext);
}

// markRegisterParameterAttributes(F) (modeled after X86TargetLowering::markLibCallAttributes)
mark_register_parameter_attributes :: (f: Value_Id) {
    ft := glob(f).value_type;
    if func_nparams(ft) == 0 || func_vararg(ft) return;
    cc := glob(f).cc;
    CC_X86_STDCALL :: 64;
    if cc != 0 && cc != CC_X86_STDCALL return;
    m := module_get_flag("NumRegisterParameters");
    if m == NONE return;
    ok, n := md_const_int_value(m);
    if !ok || n == 0 return;
    for k: 0..cast(s64) func_nparams(ft) - 1 {
        t := func_param(ft, cast(u32) k);
        if !is_int_type(t) && !is_ptr_type(t) continue;
        ts := dl_type_alloc_size(t);
        if ts > 8 continue;
        num_regs: u64 = ifx ts > 4 then cast(u64) 2 else 1;
        if n < num_regs return;
        n -= num_regs;
        fn_add_param_attr_kind(f, cast(u32) k, .InReg);
    }
}

// Module::getOrInsertFunction(Name, T, AttributeList): an existing global of that name is returned as is
module_get_or_insert_function :: (name: string, ft: Type_Id, attrs: u32 = 0) -> Value_Id {
    f := lookup_global(name);
    if f != NONE return f;
    f = new_function(ft, name, 0);
    array_add(*ir.m_functions, f);
    id := function_intrinsic_id(f);
    if id != NOT_INTRINSIC set_intrinsic_attributes(f, id);
    else if attrs != 0 glob(f).attrs = attrs;
    return f;
}

// getOrInsertLibFunc(M, TLI, TheLibFunc, T, AttributeList)
get_or_insert_lib_func :: (t: *Tli, lf: Lib_Func, ft: Type_Id, attrs: u32 = 0) -> Value_Id {
    assert(tli_func_has(t, lf), "Creating call to non-existing library function.");
    name := tli_func_name(t, lf);
    f := module_get_or_insert_function(name, ft, attrs);
    if vkind(f) != .FUNCTION fatal("getOrInsertLibFunc: '%' is not a function", name);
    if lf == {
        case .fputc; #through; case .putchar;
            blc_set_arg_ext_attr(f, 0);
        case .ldexp; #through; case .ldexpf; #through; case .ldexpl; #through; case .memchr; #through;
        case .memrchr; #through; case .strchr;
            blc_set_arg_ext_attr(f, 1);
        case .memccpy;
            blc_set_arg_ext_attr(f, 2);
        case .bcmp;
            blc_set_ret_ext_attr(f);
    }
    mark_register_parameter_attributes(f);
    return f;
}
get_or_insert_lib_func_types :: (t: *Tli, lf: Lib_Func, attrs: u32, ret: Type_Id, params: ..Type_Id) -> Value_Id {
    return get_or_insert_lib_func(t, lf, type_func(ret, params, false), attrs);
}

// isLibFuncEmittable(M, TLI, TheLibFunc)
is_lib_func_emittable :: (t: *Tli, lf: Lib_Func) -> bool {
    name := tli_func_name(t, lf);
    if !tli_func_has(t, lf) return false;
    gv := lookup_global(name);
    if gv != NONE {
        if vkind(gv) == .FUNCTION return tli_valid_proto_for(glob(gv).value_type, lf);
        return false;
    }
    return true;
}
// isLibFuncEmittable(M, TLI, Name)
is_lib_func_emittable_name :: (t: *Tli, name: string) -> bool {
    ok, lf := tli_lookup_name(name);
    return ok && is_lib_func_emittable(t, lf);
}

// hasFloatFn(M, TLI, Ty, DoubleFn, FloatFn, LongDoubleFn)
has_float_fn :: (t: *Tli, ty: Type_Id, dfn: Lib_Func, ffn: Lib_Func, lfn: Lib_Func) -> bool {
    k := type_kind(ty);
    if k == .HALF return false;
    if k == .FLOAT return is_lib_func_emittable(t, ffn);
    if k == .DOUBLE return is_lib_func_emittable(t, dfn);
    return is_lib_func_emittable(t, lfn);
}
// getFloatFn
get_float_fn :: (t: *Tli, ty: Type_Id, dfn: Lib_Func, ffn: Lib_Func, lfn: Lib_Func) -> (string, Lib_Func) {
    assert(has_float_fn(t, ty, dfn, ffn, lfn), "Cannot get name for unavailable function!");
    k := type_kind(ty);
    if k == .HALF fatal("No name for HalfTy!");
    if k == .FLOAT return tli_func_name(t, ffn), ffn;
    if k == .DOUBLE return tli_func_name(t, dfn), dfn;
    return tli_func_name(t, lfn), lfn;
}

// ---------------------------------------------------------------- Emit LibCalls

blc_int_ty :: () -> Type_Id { return type_int(tli_int_bits()); }
blc_size_t_ty :: () -> Type_Id { return tli_size_t_type(); }

// B.CreateCall(Callee, Ops, Name) followed by CI->setCallingConv(F->getCallingConv())
blc_create_call :: (f: Value_Id, args: [] Value_Id, name: string) -> Value_Id {
    ci := icb_call_fn(f, args, ifx func_ret(glob(f).value_type) == ir.t_void then "" else name);
    inst(ci).cc = glob(f).cc;
    return ci;
}

// emitLibCall
emit_lib_call :: (t: *Tli, lf: Lib_Func, ret: Type_Id, params: [] Type_Id, ops: [] Value_Id, is_va_args := false) -> Value_Id {
    if !is_lib_func_emittable(t, lf) return NONE;
    name := tli_func_name(t, lf);
    ft := type_func(ret, params, is_va_args);
    f := get_or_insert_lib_func(t, lf, ft);
    infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, ops, name);
}

emit_str_len :: (ptr: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strlen, blc_size_t_ty(), .[ir.t_ptr], .[ptr]);
}
emit_wcs_len :: (ptr: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .wcslen, blc_size_t_ty(), .[ir.t_ptr], .[ptr]);
}
emit_str_dup :: (ptr: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strdup, ir.t_ptr, .[ir.t_ptr], .[ptr]);
}
emit_str_chr :: (ptr: Value_Id, c: u8, t: *Tli) -> Value_Id {
    it := blc_int_ty();
    return emit_lib_call(t, .strchr, ir.t_ptr, .[ir.t_ptr, it], .[ptr, const_int(it, c)]);
}
emit_str_n_cmp :: (p1: Value_Id, p2: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strncmp, blc_int_ty(), .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[p1, p2, len]);
}
emit_str_cpy :: (dst: Value_Id, src: Value_Id, t: *Tli) -> Value_Id {
    pt := vtype(dst);
    return emit_lib_call(t, .strcpy, pt, .[pt, pt], .[dst, src]);
}
emit_stp_cpy :: (dst: Value_Id, src: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .stpcpy, ir.t_ptr, .[ir.t_ptr, ir.t_ptr], .[dst, src]);
}
emit_str_n_cpy :: (dst: Value_Id, src: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strncpy, ir.t_ptr, .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[dst, src, len]);
}
emit_stp_n_cpy :: (dst: Value_Id, src: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .stpncpy, ir.t_ptr, .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[dst, src, len]);
}
// emitMemCpyChk: the declaration gets `nounwind` as its attribute list
emit_mem_cpy_chk :: (dst: Value_Id, src: Value_Id, len: Value_Id, obj_size: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .memcpy_chk) return NONE;
    nu: Attr; nu.kind = .NoUnwind; nu.ty = NONE;
    attrs := attr_list_get(attr_set_get(.[nu]), 0, .[]);
    st := blc_size_t_ty();
    f := get_or_insert_lib_func(t, .memcpy_chk, type_func(ir.t_ptr, .[ir.t_ptr, ir.t_ptr, st, st], false), attrs);
    ci := icb_call_fn(f, .[dst, src, len, obj_size]);
    inst(ci).cc = glob(f).cc;
    return ci;
}
emit_mem_p_cpy :: (dst: Value_Id, src: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .mempcpy, ir.t_ptr, .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[dst, src, len]);
}
emit_mem_chr :: (ptr: Value_Id, val: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .memchr, ir.t_ptr, .[ir.t_ptr, blc_int_ty(), blc_size_t_ty()], .[ptr, val, len]);
}
emit_mem_r_chr :: (ptr: Value_Id, val: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .memrchr, ir.t_ptr, .[ir.t_ptr, blc_int_ty(), blc_size_t_ty()], .[ptr, val, len]);
}
emit_mem_cmp :: (p1: Value_Id, p2: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .memcmp, blc_int_ty(), .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[p1, p2, len]);
}
emit_b_cmp :: (p1: Value_Id, p2: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .bcmp, blc_int_ty(), .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[p1, p2, len]);
}
emit_mem_c_cpy :: (p1: Value_Id, p2: Value_Id, val: Value_Id, len: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .memccpy, ir.t_ptr, .[ir.t_ptr, ir.t_ptr, blc_int_ty(), blc_size_t_ty()], .[p1, p2, val, len]);
}
emit_sn_printf :: (dest: Value_Id, size: Value_Id, fmt: Value_Id, va: [] Value_Id, t: *Tli) -> Value_Id {
    args: [..] Value_Id; args.allocator = temp;
    array_add(*args, dest, size, fmt);
    for va array_add(*args, it);
    return emit_lib_call(t, .snprintf, blc_int_ty(), .[ir.t_ptr, blc_size_t_ty(), ir.t_ptr], args, true);
}
emit_s_printf :: (dest: Value_Id, fmt: Value_Id, va: [] Value_Id, t: *Tli) -> Value_Id {
    args: [..] Value_Id; args.allocator = temp;
    array_add(*args, dest, fmt);
    for va array_add(*args, it);
    return emit_lib_call(t, .sprintf, blc_int_ty(), .[ir.t_ptr, ir.t_ptr], args, true);
}
emit_str_cat :: (dest: Value_Id, src: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strcat, ir.t_ptr, .[ir.t_ptr, ir.t_ptr], .[dest, src]);
}
emit_str_l_cpy :: (dest: Value_Id, src: Value_Id, size: Value_Id, t: *Tli) -> Value_Id {
    st := blc_size_t_ty();
    return emit_lib_call(t, .strlcpy, st, .[ir.t_ptr, ir.t_ptr, st], .[dest, src, size]);
}
emit_str_l_cat :: (dest: Value_Id, src: Value_Id, size: Value_Id, t: *Tli) -> Value_Id {
    st := blc_size_t_ty();
    return emit_lib_call(t, .strlcat, st, .[ir.t_ptr, ir.t_ptr, st], .[dest, src, size]);
}
emit_str_n_cat :: (dest: Value_Id, src: Value_Id, size: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .strncat, ir.t_ptr, .[ir.t_ptr, ir.t_ptr, blc_size_t_ty()], .[dest, src, size]);
}
emit_vsn_printf :: (dest: Value_Id, size: Value_Id, fmt: Value_Id, va_list: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .vsnprintf, blc_int_ty(), .[ir.t_ptr, blc_size_t_ty(), ir.t_ptr, vtype(va_list)], .[dest, size, fmt, va_list]);
}
emit_vs_printf :: (dest: Value_Id, fmt: Value_Id, va_list: Value_Id, t: *Tli) -> Value_Id {
    return emit_lib_call(t, .vsprintf, blc_int_ty(), .[ir.t_ptr, ir.t_ptr, vtype(va_list)], .[dest, fmt, va_list]);
}

// appendTypeSuffix
append_type_suffix :: (op: Value_Id, name: string) -> string {
    k := type_kind(vtype(op));
    if k == .DOUBLE return name;
    return tprint("%1%2", name, ifx k == .FLOAT then "f" else "l");
}

// AttributeList::removeFnAttribute(Speculatable)
attr_list_without_fn_attr :: (l: u32, k: Attr_Kind) -> u32 {
    if l == 0 return 0;
    return attr_list_with_fn(l, attr_set_remove(attr_list_fn(l), k));
}

// emitUnaryFloatFnCallHelper
emit_unary_float_fn_call_helper :: (op: Value_Id, lf: Lib_Func, name: string, attrs: u32, t: *Tli) -> Value_Id {
    assert(name.count > 0, "Must specify Name to emitUnaryFloatFnCall");
    ty := vtype(op);
    f := get_or_insert_lib_func(t, lf, type_func(ty, .[ty], false));
    ci := icb_call_fn(f, .[op], name);
    inst(ci).attrs = attr_list_without_fn_attr(attrs, .Speculatable);
    inst(ci).cc = glob(f).cc;
    return ci;
}
// emitUnaryFloatFnCall(Op, TLI, Name, B, Attrs)
emit_unary_float_fn_call_name :: (op: Value_Id, t: *Tli, name_in: string, attrs: u32) -> Value_Id {
    name := append_type_suffix(op, name_in);
    ok, lf := tli_lookup_name(name);
    if !ok fatal("emitUnaryFloatFnCall: '%' is not a library function", name);
    return emit_unary_float_fn_call_helper(op, lf, name, attrs, t);
}
// emitUnaryFloatFnCall(Op, TLI, DoubleFn, FloatFn, LongDoubleFn, B, Attrs)
emit_unary_float_fn_call :: (op: Value_Id, t: *Tli, dfn: Lib_Func, ffn: Lib_Func, lfn: Lib_Func, attrs: u32) -> Value_Id {
    name, lf := get_float_fn(t, vtype(op), dfn, ffn, lfn);
    return emit_unary_float_fn_call_helper(op, lf, name, attrs, t);
}
// emitBinaryFloatFnCallHelper
emit_binary_float_fn_call_helper :: (op1: Value_Id, op2: Value_Id, lf: Lib_Func, name: string, attrs: u32, t: *Tli) -> Value_Id {
    assert(name.count > 0, "Must specify Name to emitBinaryFloatFnCall");
    f := get_or_insert_lib_func(t, lf, type_func(vtype(op1), .[vtype(op1), vtype(op2)], false));
    infer_non_mandatory_lib_func_attrs_name(name, t);
    ci := icb_call_fn(f, .[op1, op2], name);
    inst(ci).attrs = attr_list_without_fn_attr(attrs, .Speculatable);
    inst(ci).cc = glob(f).cc;
    return ci;
}
emit_binary_float_fn_call_name :: (op1: Value_Id, op2: Value_Id, t: *Tli, name_in: string, attrs: u32) -> Value_Id {
    name := append_type_suffix(op1, name_in);
    ok, lf := tli_lookup_name(name);
    if !ok fatal("emitBinaryFloatFnCall: '%' is not a library function", name);
    return emit_binary_float_fn_call_helper(op1, op2, lf, name, attrs, t);
}
emit_binary_float_fn_call :: (op1: Value_Id, op2: Value_Id, t: *Tli, dfn: Lib_Func, ffn: Lib_Func, lfn: Lib_Func, attrs: u32) -> Value_Id {
    name, lf := get_float_fn(t, vtype(op1), dfn, ffn, lfn);
    return emit_binary_float_fn_call_helper(op1, op2, lf, name, attrs, t);
}

// emitPutChar
emit_put_char :: (ch: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .putchar) return NONE;
    it := blc_int_ty();
    name := tli_func_name(t, .putchar);
    f := get_or_insert_lib_func_types(t, .putchar, 0, it, it);
    infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[ch], name);
}
// emitPutS
emit_put_s :: (str: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .puts) return NONE;
    name := tli_func_name(t, .puts);
    f := get_or_insert_lib_func_types(t, .puts, 0, blc_int_ty(), ir.t_ptr);
    infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[str], name);
}
// emitFPutC
emit_f_put_c :: (ch: Value_Id, file: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .fputc) return NONE;
    it := blc_int_ty();
    name := tli_func_name(t, .fputc);
    f := get_or_insert_lib_func_types(t, .fputc, 0, it, it, vtype(file));
    if is_ptr_type(vtype(file)) infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[ch, file], name);
}
// emitFPutS
emit_f_put_s :: (str: Value_Id, file: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .fputs) return NONE;
    name := tli_func_name(t, .fputs);
    f := get_or_insert_lib_func_types(t, .fputs, 0, blc_int_ty(), ir.t_ptr, vtype(file));
    if is_ptr_type(vtype(file)) infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[str, file], name);
}
// emitFWrite (unnamed call)
emit_f_write :: (ptr: Value_Id, size: Value_Id, file: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .fwrite) return NONE;
    st := blc_size_t_ty();
    name := tli_func_name(t, .fwrite);
    f := get_or_insert_lib_func_types(t, .fwrite, 0, st, ir.t_ptr, st, st, vtype(file));
    if is_ptr_type(vtype(file)) infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[ptr, size, const_int(st, 1), file], "");
}
// emitMalloc
emit_malloc :: (num: Value_Id, t: *Tli) -> Value_Id {
    if !is_lib_func_emittable(t, .malloc) return NONE;
    name := tli_func_name(t, .malloc);
    f := get_or_insert_lib_func_types(t, .malloc, 0, ir.t_ptr, blc_size_t_ty());
    infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[num], name);
}
// emitCalloc
emit_calloc :: (num: Value_Id, size: Value_Id, t: *Tli, addrspace: u32 = 0) -> Value_Id {
    if !is_lib_func_emittable(t, .calloc) return NONE;
    name := tli_func_name(t, .calloc);
    st := blc_size_t_ty();
    f := get_or_insert_lib_func_types(t, .calloc, 0, type_ptr(addrspace), st, st);
    infer_non_mandatory_lib_func_attrs_name(name, t);
    return blc_create_call(f, .[num, size], name);
}
// emitHotColdNew* / emitHotColdSizeReturningNew*: only reached with -optimize-hot-cold-new
emit_hot_cold_new_any :: (t: *Tli, lf: Lib_Func, ret: Type_Id, args: [] Value_Id, call_name: string) -> Value_Id {
    if !is_lib_func_emittable(t, lf) return NONE;
    name := tli_func_name(t, lf);
    ps: [..] Type_Id; ps.allocator = temp;
    for args array_add(*ps, vtype(it));
    f := module_get_or_insert_function(name, type_func(ret, ps, false));
    infer_non_mandatory_lib_func_attrs_name(name, t);
    nm := ifx call_name.count then call_name else name;
    ci := icb_call_fn(f, args, nm);
    if vkind(f) == .FUNCTION inst(ci).cc = glob(f).cc;
    return ci;
}
