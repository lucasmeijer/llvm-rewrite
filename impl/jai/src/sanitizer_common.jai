// Helpers shared by the sanitizer instrumentation passes. Ports of:
//   llvm/lib/Transforms/Utils/ModuleUtils.cpp      appendToGlobalCtors/Dtors (appendToGlobalArray), appendToUsed /
//                                                  appendToCompilerUsed (appendToUsedList), declareSanitizerInitFunction,
//                                                  createSanitizerCtor, createSanitizerCtorAndInitFunctions,
//                                                  getOrCreateSanitizerCtorAndInitFunctions, setKCFIType (fails loudly)
//   llvm/lib/Transforms/Utils/Instrumentation.cpp  checkIfAlreadyInstrumented, createPrivateGlobalForString,
//                                                  getOrCreateFunctionComdat, setGlobalVariableLargeSection,
//                                                  PrepareToSplitEntryBlock
//   llvm/include/llvm/Transforms/Utils/Instrumentation.h   InstrumentationIRBuilder (ensureDebugInfo)
//   llvm/lib/IR/Function.cpp                       Function::createWithDefaultAttr
//   llvm/lib/Transforms/Utils/BasicBlockUtils.cpp  SplitBlockAndInsertIfThen / IfThenElse (no DTU, no LoopInfo),
//                                                  SplitBlockAndInsertSimpleForLoop, SplitBlockAndInsertForEachLane
//   llvm/lib/Transforms/Utils/Local.cpp            maybeMarkSanitizerLibraryCallNoBuiltin, replaceDbgDeclare
//   llvm/lib/Transforms/Utils/ASanStackFrameLayout.cpp   the whole file

// ---------------------------------------------------------------- Module flags

// Module::addModuleFlag(Behavior, Key, i32 Val)
san_add_module_flag_int :: (behavior: u64, key: string, val: u64) {
    k := named_md_get_or_insert("llvm.module.flags");
    flag := md_tuple(.[md_value(const_int(ir.t_i32, behavior)), md_string(key), md_value(const_int(ir.t_i32, val))], false);
    array_add(*ir.named_md[k].ops, flag);
}

san_opts: struct {
    ignore_redundant_instrumentation: bool;   // -ignore-redundant-instrumentation
};

// checkIfAlreadyInstrumented(M, Flag)
check_if_already_instrumented :: (flag: string) -> bool {
    if module_flag(flag) == NONE {
        san_add_module_flag_int(4, flag, 1);   // Module::ModFlagBehavior::Override
        return false;
    }
    if san_opts.ignore_redundant_instrumentation return true;
    print_to_stderr("warning: Redundant instrumentation detected, with module flag: %\n", flag);
    return true;
}

print_to_stderr :: (fmt: string, args: ..Any) {
    s := tprint(fmt, ..args);
    write_string(s, to_standard_error = true);
}

// ---------------------------------------------------------------- functions and globals

// Module::getOrInsertFunction(Name, FT, AttributeList): an existing global of that name is returned as is
// (the FunctionCallee keeps FT; san_call uses it)
san_get_or_insert_function :: (name: string, ft: Type_Id, attrs: u32 = 0) -> Value_Id {
    f := lookup_global(name);
    if f != NONE return f;
    f = new_function(ft, name, dl.program_as);
    array_add(*ir.m_functions, f);
    id := function_intrinsic_id(f);
    if id != NOT_INTRINSIC set_intrinsic_attributes(f, id);
    else if begins_with(name, "llvm.") san_set_foreign_intrinsic_attributes(f);
    else glob(f).attrs = attrs;
    return f;
}

// A FunctionCallee: the callee and the function type calls through it use
San_Callee :: struct { fty: Type_Id = NONE; callee: Value_Id = NONE; }
san_callee :: (name: string, ret: Type_Id, params: [] Type_Id, attrs: u32 = 0) -> San_Callee {
    ft := type_func(ret, params, false);
    return .{ft, san_get_or_insert_function(name, ft, attrs)};
}

// IRBuilder::CreateCall(FunctionCallee, Args, Name)
san_call :: (b: *Irb, c: San_Callee, args: [] Value_Id, name: string = "") -> Value_Id {
    i := new_inst(.CALL, func_ret(c.fty), cast(u32)(args.count + 1));
    inst(i).ty2 = c.fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, c.callee);
    return irb_insert(b, i, name);
}

// CallInst::Create(FunctionCallee, Args, "", InsertBefore) (not through an IRBuilder: no debug location)
san_call_before :: (c: San_Callee, args: [] Value_Id, before: Value_Id) -> Value_Id {
    i := new_inst(.CALL, func_ret(c.fty), cast(u32)(args.count + 1));
    inst(i).ty2 = c.fty;
    for args set_op(i, cast(u32) it_index, it);
    set_op(i, cast(u32) args.count, c.callee);
    insert_at_position(i, inst(before).parent, before, false);
    return i;
}

// IRBuilder::CreateAlloca(Ty, ArraySize, Name): the DataLayout's alloca address space, preferred alignment
// (CreateAlloca(Ty, AddrSpace, ArraySize, Name) with `as`)
irb_alloca :: (b: *Irb, ty: Type_Id, size: Value_Id, name: string = "", as_in: s64 = -1) -> Value_Id {
    as := ifx as_in >= 0 then cast(u32) as_in else dl.alloca_as;
    a := new_inst(.ALLOCA, type_ptr(as), 1);
    set_op(a, 0, ifx size == NONE then const_int(ir.t_i32, 1) else size);
    inst(a).ty2 = ty;
    inst(a).addrspace = as;
    inst(a).align = dl_pref_align(ty);
    return irb_insert(b, a, name);
}

// IRBuilder::CreatePointerCast
irb_pointer_cast :: (b: *Irb, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    st := vtype(v);
    if st == dt return v;
    if is_int_type(scalar_type(dt)) return irb_cast(b, .PTRTOINT, v, dt, name);
    if ir.types[scalar_type(st)].a != ir.types[scalar_type(dt)].a return irb_cast(b, .ADDRSPACECAST, v, dt, name);
    return irb_cast(b, .BITCAST, v, dt, name);
}
// IRBuilder::CreateAddrSpaceCast (no-op when the types match)
irb_addrspace_cast :: (b: *Irb, v: Value_Id, dt: Type_Id, name: string = "") -> Value_Id {
    return irb_cast(b, .ADDRSPACECAST, v, dt, name);
}
// IRBuilder::CreatePtrAdd(Ptr, Offset, Name) (GEP i8, no flags)
irb_ptr_add :: (b: *Irb, ptr: Value_Id, off: Value_Id, name: string = "") -> Value_Id {
    return irb_gep(b, ir.t_i8, ptr, .[off], name);
}

// InstrumentationIRBuilder(IP) / (BB, It): ensureDebugInfo gives a line-0 location in the subprogram when there is none
irb_instr_before :: (b: *Irb, i: Value_Id) {
    irb_set_before(b, i);
    san_ensure_debug_info(b, block_fn(inst(i).parent));
}
san_ensure_debug_info :: (b: *Irb, f: Value_Id) {
    if b.dbg != NONE return;
    sp := fn_subprogram(f);
    if sp != NONE b.dbg = di_location_get(0, 0, sp, NONE);
}

// createPrivateGlobalForString(M, Str, AllowMerging, NamePrefix)
create_private_global_for_string :: (s: string, allow_merging: bool, name_prefix: string) -> Value_Id {
    elts := NewArray(s.count + 1, u64,, temp);
    for 0..s.count-1 elts[it] = s[it];
    elts[s.count] = 0;
    c := const_data(type_array(cast(u64) s.count + 1, ir.t_i8), elts);
    gv := gv_create(vtype(c), true, .PRIVATE, c, name_prefix, NONE, 0, dl.globals_as);
    if allow_merging glob(gv).unnamed_addr = 2;
    glob(gv).align = 1;
    return gv;
}

// setKCFIType(M, F, MangledType) (ModuleUtils.cpp) with getKCFITypeID (llvm/lib/Transforms/Utils/KCFIHash.cpp)
san_set_kcfi_type :: (f: Value_Id, mangled: string) {
    if module_flag("kcfi") == NONE return;
    ty := mangled;
    if module_flag("cfi-normalize-integers") != NONE ty = tconcat(ty, ".normalized");
    hm := module_flag("kcfi-hash");
    fnv := hm != NONE && ir.mds[hm].kind == .STRING && ir.mds[hm].str == "FNV-1a";
    id: u32;
    if fnv {
        h: u32 = 2166136261;
        for c: cast([] u8) ty { h ^= c; h *= 16777619; }
        id = h;
    } else id = cast,no_check(u32) kcfi_xxhash64(ty);
    set_metadata(f, md_kind_id("kcfi_type"), md_tuple(.[md_value(const_int(ir.t_i32, id))], false));
    ho, off := mu_module_flag_int("kcfi-offset");
    if ho && off != 0 fn_add_fn_str_attr(f, "patchable-function-prefix", tprint("%", off));
}

// xxHash64 of KCFIHash.cpp
kcfi_xxhash64 :: (s: string) -> u64 {
    P1 :: cast(u64) 11400714785074694791; P2 :: cast(u64) 14029467366897019727; P3 :: cast(u64) 1609587929392839161;
    P4 :: cast(u64) 9650029242287828579; P5 :: cast(u64) 2870177450012600261;
    rotl :: (x: u64, r: u64) -> u64 { return (x << r) | (x >> (64 - r)); }
    rnd :: (acc_in: u64, input: u64) -> u64 { acc := acc_in; acc += input * P2; acc = rotl(acc, 31); acc *= P1; return acc; }
    merge :: (acc_in: u64, val_in: u64) -> u64 { val := rnd(0, val_in); acc := acc_in ^ val; acc = acc * P1 + P4; return acc; }
    r64 :: (s: string, p: s64) -> u64 { v: u64; for k: 0..7 v |= (cast(u64) s[p + k]) << cast(u64)(8 * k); return v; }
    r32 :: (s: string, p: s64) -> u64 { v: u64; for k: 0..3 v |= (cast(u64) s[p + k]) << cast(u64)(8 * k); return v; }
    n := s.count;
    p := 0;
    h: u64;
    if n >= 32 {
        v1 := P1 + P2; v2 := P2; v3: u64 = 0; v4 := 0 - P1;
        while p <= n - 32 {
            v1 = rnd(v1, r64(s, p)); p += 8;
            v2 = rnd(v2, r64(s, p)); p += 8;
            v3 = rnd(v3, r64(s, p)); p += 8;
            v4 = rnd(v4, r64(s, p)); p += 8;
        }
        h = rotl(v1, 1) + rotl(v2, 7) + rotl(v3, 12) + rotl(v4, 18);
        h = merge(h, v1); h = merge(h, v2); h = merge(h, v3); h = merge(h, v4);
    } else h = P5;
    h += cast(u64) n;
    while p + 8 <= n { h ^= rnd(0, r64(s, p)); h = rotl(h, 27) * P1 + P4; p += 8; }
    if p + 4 <= n { h ^= r32(s, p) * P1; h = rotl(h, 23) * P2 + P3; p += 4; }
    while p < n { h ^= (cast(u64) s[p]) * P5; h = rotl(h, 11) * P1; p += 1; }
    h ^= h >> 33; h *= P2; h ^= h >> 29; h *= P3; h ^= h >> 32;
    return h;
}

// declareSanitizerInitFunction as a FunctionCallee (module_utils.jai declares it)
san_declare_sanitizer_init_function :: (name: string, arg_types: [] Type_Id, weak := false) -> San_Callee {
    f := declare_sanitizer_init_function(name, arg_types, weak);
    return .{type_func(ir.t_void, arg_types, false), f};
}

// getOrCreateSanitizerCtorAndInitFunctions: `created` tells the caller to run its FunctionsCreatedCallback
get_or_create_sanitizer_ctor_and_init_functions :: (ctor_name: string, init_name: string, arg_types: [] Type_Id, args: [] Value_Id,
                                                    version_check: string, weak := false) -> (Value_Id, San_Callee, created: bool) {
    c := module_get_function(ctor_name);
    if c != NONE {
        ft := glob(c).value_type;
        if func_nparams(ft) == 0 || func_ret(ft) == ir.t_void
            return c, san_declare_sanitizer_init_function(init_name, arg_types, weak), false;
    }
    ctor, init := create_sanitizer_ctor_and_init_functions(ctor_name, init_name, arg_types, args, version_check, weak);
    return ctor, .{type_func(ir.t_void, arg_types, false), init}, true;
}

// Module::getOrInsertComdat
san_get_or_insert_comdat :: (name: string) -> s32 { return get_comdat(name); }

// getOrCreateFunctionComdat(F, T)
get_or_create_function_comdat :: (f: Value_Id) -> s32 {
    c := glob(f).comdat;
    if c >= 0 return c;
    if vname(f).count == 0 return -1;
    c = get_comdat(vname(f));
    // ELF (and COFF for non-weak symbols): NoDeduplicate
    if san_triple_is_elf() || (san_triple_is_coff() && !gv_is_weak_for_linker(f)) ir.comdats[c].kind = 3;
    glob(f).comdat = c;
    return c;
}

// Module::getCodeModel: the "Code Model" module flag (0 tiny .. 4 large as CodeModel::Model), -1 = none
san_module_code_model :: () -> s64 {
    h, v := mu_module_flag_int("Code Model");
    if !h return -1;
    return cast(s64) v;
}
// setGlobalVariableLargeSection(TargetTriple, GV)
set_global_variable_large_section :: (gv: Value_Id) {
    if !san_triple_is_x86_64() || !san_triple_is_elf() return;
    cm := san_module_code_model();
    if cm != 3 && cm != 4 return;   // CodeModel::Medium / Large
    glob(gv).code_model = 5;        // large
}

// ---------------------------------------------------------------- triple queries (llvm/TargetParser/Triple.h)

san_triple :: () -> Triple { return triple_parse(ir.triple); }
san_triple_is_x86_64 :: () -> bool { return san_triple().arch == .x86_64; }
san_triple_is_elf :: () -> bool { return san_triple().obj == .ELF; }
san_triple_is_coff :: () -> bool { return san_triple().obj == .COFF; }
san_triple_is_macho :: () -> bool { return san_triple().obj == .MachO; }
san_triple_is_wasm :: () -> bool { return san_triple().obj == .Wasm; }
san_triple_is_linux :: () -> bool { return san_triple().os == .Linux; }
san_triple_is_os_windows :: () -> bool { return san_triple().os == .Win32; }

// ---------------------------------------------------------------- SplitBlockAndInsertIfThen (BasicBlockUtils.cpp)

// SplitBlockAndInsertIfThenElse(Cond, SplitBefore, &Then?, &Else?, UnreachableThen, UnreachableElse, BranchWeights)
// without DTU/LoopInfo. Returns the terminators of the new then/else blocks (NONE when not created).
sbi_if_then_else :: (cond: Value_Id, split_before: Value_Id, want_then: bool, unreach_then: bool, want_else: bool, unreach_else: bool,
                     weights: Md_Id = NONE) -> (Value_Id, Value_Id) {
    head := inst(split_before).parent;
    f := block_fn(head);
    tail := split_basic_block(head, split_before, "");
    tb := tail; fb := tail;
    dl_loc := get_metadata(split_before, 0);
    mk :: (f: Value_Id, tail: Value_Id, unreachable: bool, dl_loc: Md_Id) -> Value_Id {
        bb := create_block(f, "", tail);
        t: Value_Id;
        if unreachable t = new_inst(.UNREACHABLE, ir.t_void, 0);
        else t = create_br(tail);
        block_append_inst(bb, t);
        set_metadata(t, 0, dl_loc);
        return bb;
    }
    then_term: Value_Id = NONE; else_term: Value_Id = NONE;
    if want_then { tb = mk(f, tail, unreach_then, dl_loc); then_term = block_terminator(tb); }
    if want_else { fb = mk(f, tail, unreach_else, dl_loc); else_term = block_terminator(fb); }
    old := block_terminator(head);
    nt := create_cond_br(cond, tb, fb);
    if weights != NONE set_metadata(nt, MDK_PROF, weights);
    replace_inst_with_inst(old, nt);
    return then_term, else_term;
}
MDK_PROF :: 2;

// SplitBlockAndInsertIfThen(Cond, SplitBefore, Unreachable, BranchWeights): the new block's terminator
sbi_if_then :: (cond: Value_Id, split_before: Value_Id, unreachable: bool, weights: Md_Id = NONE) -> Value_Id {
    t, e := sbi_if_then_else(cond, split_before, true, unreachable, false, false, weights);
    return t;
}

// ReplaceInstWithInst(From, To): To takes From's place (and its debug location if it has none)
replace_inst_with_inst :: (from: Value_Id, to: Value_Id) {
    bb := inst(from).parent;
    insert_at_position(to, bb, from, false);
    if get_metadata(to, 0) == NONE { d := get_metadata(from, 0); if d != NONE set_metadata(to, 0, d); }
    rauw_with_metadata(from, to);
    erase_inst(from);
}

// MDBuilder::createUnlikelyBranchWeights: !{!"branch_weights", i32 1, i32 1048575}
create_unlikely_branch_weights :: () -> Md_Id {
    return md_tuple(.[md_string("branch_weights"), md_value(const_int(ir.t_i32, 1)), md_value(const_int(ir.t_i32, 1048575))], false);
}

// SplitBlock(Old, SplitPt) without DTU/LoopInfo: the new block is named Old.getName() + ".split"
sbu_split_block :: (old: Value_Id, split_pt: Value_Id) -> Value_Id {
    at := split_pt;
    while inst_op(at) == .PHI || inst_is_eh_pad(at) at = inst(at).next;
    return split_basic_block(old, at, tconcat(vname(old), ".split"));
}

// SplitBlockAndInsertSimpleForLoop(End, SplitBefore): (body insertion point, the index phi)
sbi_simple_for_loop :: (end: Value_Id, split_before: Value_Id) -> (Value_Id, Value_Id) {
    loop_pred := inst(split_before).parent;
    loop_body := sbu_split_block(loop_pred, split_before);
    loop_exit := sbu_split_block(loop_body, split_before);
    ty := vtype(end);
    bits := dl_type_size_bits(ty);
    b: Irb;
    irb_set_before(*b, block_terminator(loop_body));
    iv := irb_phi(*b, ty, 2, "iv");
    ivnext := irb_binop(*b, .ADD, iv, const_int(ty, 1), tconcat(vname(iv), ".next"), cast(u32)(F_NUW | (ifx bits != 2 then F_NSW else 0)));
    ivcheck := irb_icmp(*b, ICMP_EQ, ivnext, end, tconcat(vname(iv), ".check"));
    irb_cond_br(*b, ivcheck, loop_exit, loop_body);
    t := block_terminator(loop_body);
    drop_all_references(t); erase_inst(t);
    phi_add_incoming(iv, const_int(ty, 0), loop_pred);
    phi_add_incoming(iv, ivnext, loop_body);
    return block_first_non_phi(loop_body), iv;
}

// Instruction::isEHPad
inst_is_eh_pad :: (i: Value_Id) -> bool {
    o := inst_op(i);
    return o == .LANDINGPAD || o == .CATCHPAD || o == .CLEANUPPAD || o == .CATCHSWITCH;
}

// ---------------------------------------------------------------- Local.cpp

// maybeMarkSanitizerLibraryCallNoBuiltin(CI, TLI)
maybe_mark_sanitizer_library_call_no_builtin :: (ci: Value_Id, t: *Tli) {
    f := call_called_function(ci);
    if f == NONE || gv_has_local_linkage(f) || vname(f).count == 0 return;
    found, lf := tli_lookup_name(vname(f));
    if !found || !tli_has_optimized_code_gen(t, lf) return;
    if mem_does_not_access(fn_memory_effects(f)) return;
    call_add_fn_attr(ci, Attr_Kind.NoBuiltin);
}

// DIExpression flags (DIExpression::PrependOps)
// (DIEXPR_DEREF_BEFORE = 1 and DIEXPR_ENTRY_VALUE = 8 are in coro_frame.jai)
DIEXPR_APPLY_OFFSET :: 0;
DIEXPR_DEREF_AFTER  :: 2;
DIEXPR_STACK_VALUE  :: 4;

// DIExpression::prepend(Expr, Flags, Offset)
diexpr_prepend :: (expr: Md_Id, flags: u32, offset: s64) -> Md_Id {
    ops: [..] u64; ops.allocator = temp;
    if flags & DIEXPR_DEREF_BEFORE array_add(*ops, DW_OP_DEREF_);
    diexpr_append_offset(*ops, offset);
    if flags & DIEXPR_DEREF_AFTER array_add(*ops, DW_OP_DEREF_);
    return diexpr_prepend_opcodes(expr, *ops, (flags & DIEXPR_STACK_VALUE) != 0, (flags & DIEXPR_ENTRY_VALUE) != 0);
}

// replaceDbgDeclare(Address, NewAddress, Builder, DIExprFlags, Offset)
replace_dbg_declare :: (f: Value_Id, address: Value_Id, new_address: Value_Id, flags: u32, offset: s64) -> bool {
    users: [..] u32; users.allocator = temp;
    find_dbg_users(f, address, *users);
    any := false;
    for r: users {
        if dbgr(r).kind != .DECLARE continue;
        dbgr(r).expr = diexpr_prepend(dbgr(r).expr, flags, offset);
        dbgr_replace_variable_location_op(r, address, new_address);
        any = true;
    }
    return any;
}

// ---------------------------------------------------------------- ASanStackFrameLayout.cpp

ASAN_STACK_LEFT_REDZONE_MAGIC :: cast(u8) 0xf1;
ASAN_STACK_MID_REDZONE_MAGIC :: cast(u8) 0xf2;
ASAN_STACK_RIGHT_REDZONE_MAGIC :: cast(u8) 0xf3;
ASAN_STACK_USE_AFTER_RETURN_MAGIC :: cast(u8) 0xf5;
ASAN_STACK_USE_AFTER_SCOPE_MAGIC :: cast(u8) 0xf8;

Asan_Stack_Var :: struct {
    name: string;
    size: u64;
    lifetime_size: u64;
    alignment: u64;
    ai: Value_Id;
    offset: u64;
    line: u32;
}
Asan_Frame_Layout :: struct { granularity: u64; frame_alignment: u64; frame_size: u64; }

// ComputeASanStackFrameLayout(Vars, Granularity, MinHeaderSize); sorts `vars` (stable, by alignment, largest first)
compute_asan_stack_frame_layout :: (vars: *[..] Asan_Stack_Var, granularity: u64, min_header_size: u64) -> Asan_Frame_Layout {
    K_MIN_ALIGNMENT :: cast(u64) 16;
    for * vars.* it.alignment = max(it.alignment, K_MIN_ALIGNMENT);
    // llvm::stable_sort by a.Alignment > b.Alignment (insertion sort is stable)
    for i: 1..vars.count-1 {
        x := vars.*[i];
        j := i - 1;
        while j >= 0 && x.alignment > vars.*[j].alignment { vars.*[j + 1] = vars.*[j]; j -= 1; }
        vars.*[j + 1] = x;
    }
    var_and_redzone_size :: (size: u64, granularity: u64, alignment: u64) -> u64 {
        res: u64;
        if size <= 4 res = 16;
        else if size <= 16 res = 32;
        else if size <= 128 res = size + 32;
        else if size <= 512 res = size + 64;
        else if size <= 4096 res = size + 128;
        else res = size + 256;
        return align_to(max(res, 2 * granularity), alignment);
    }
    l: Asan_Frame_Layout;
    l.granularity = granularity;
    l.frame_alignment = max(granularity, vars.*[0].alignment);
    offset := max(max(min_header_size, granularity), vars.*[0].alignment);
    n := vars.count;
    for i: 0..n-1 {
        is_last := i == n - 1;
        next_alignment := ifx is_last then granularity else max(granularity, vars.*[i + 1].alignment);
        sz := var_and_redzone_size(vars.*[i].size, granularity, next_alignment);
        vars.*[i].offset = offset;
        offset += sz;
    }
    if offset % min_header_size offset += min_header_size - (offset % min_header_size);
    l.frame_size = offset;
    return l;
}

// ComputeASanStackFrameDescription(Vars)
compute_asan_stack_frame_description :: (vars: [] Asan_Stack_Var) -> string {
    sb: String_Builder; sb.allocator = temp;
    print_to_builder(*sb, "%", vars.count);
    for vars {
        name := it.name;
        if it.line name = tprint("%:%", name, it.line);
        print_to_builder(*sb, " % % % %", it.offset, it.size, name.count, name);
    }
    return builder_to_string(*sb,, allocator = temp);
}

// GetShadowBytes(Vars, Layout)
get_shadow_bytes :: (vars: [] Asan_Stack_Var, l: Asan_Frame_Layout) -> [..] u8 {
    sb: [..] u8; sb.allocator = temp;
    resize :: (sb: *[..] u8, n: u64, v: u8) {
        if cast(u64) sb.count >= n { sb.count = cast(s64) n; return; }
        while cast(u64) sb.count < n array_add(sb, v);
    }
    g := l.granularity;
    resize(*sb, vars[0].offset / g, ASAN_STACK_LEFT_REDZONE_MAGIC);
    for vars {
        resize(*sb, it.offset / g, ASAN_STACK_MID_REDZONE_MAGIC);
        resize(*sb, cast(u64) sb.count + it.size / g, 0);
        if it.size % g array_add(*sb, cast(u8)(it.size % g));
    }
    resize(*sb, l.frame_size / g, ASAN_STACK_RIGHT_REDZONE_MAGIC);
    return sb;
}

// GetShadowBytesAfterScope(Vars, Layout)
get_shadow_bytes_after_scope :: (vars: [] Asan_Stack_Var, l: Asan_Frame_Layout) -> [..] u8 {
    sb := get_shadow_bytes(vars, l);
    g := l.granularity;
    for vars {
        lss := (it.lifetime_size + g - 1) / g;
        off := it.offset / g;
        for k: 0..cast(s64) lss - 1 sb[cast(s64) off + k] = ASAN_STACK_USE_AFTER_SCOPE_MAGIC;
    }
    return sb;
}

// Value::stripPointerCastsAndAliases
strip_pointer_casts_and_aliases :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    visited: [..] Value_Id; visited.allocator = temp;
    while true {
        for visited if it == v return v;
        array_add(*visited, v);
        s := strip_pointer_casts(v);
        if vkind(s) == .ALIAS { v = op(s, 0); continue; }
        return s;
    }
    return v;
}

// Intrinsic declarations of targets gen_iit.jai doesn't cover, with the attributes LLVM gives them
san_set_foreign_intrinsic_attributes :: (f: Value_Id) {
    n := vname(f);
    if n == "llvm.amdgcn.is.shared" || n == "llvm.amdgcn.is.private" {
        items: [..] Attr; items.allocator = temp;
        for k: Attr_Kind.[.NoCallback, .NoCreateUndefOrPoison, .NoFree, .NoSync, .NoUnwind, .Speculatable, .WillReturn] {
            a: Attr; a.kind = k; a.ty = NONE; array_add(*items, a);
        }
        m: Attr; m.kind = .Memory; m.ty = NONE; m.ival = 0; array_add(*items, m);
        glob(f).attrs = attr_list_get(attr_set_get(items), 0, .[]);
        return;
    }
    fatal("sanitizer: the intrinsic '%' is unknown to this port", n);
}
// Intrinsics of other targets that LLVM knows (no "; Unknown intrinsic" comment) but gen_iit.jai doesn't list
san_is_foreign_known_intrinsic :: (n: string) -> bool {
    return n == "llvm.amdgcn.is.shared" || n == "llvm.amdgcn.is.private";
}

// ConstantExpr::getPointerCast(C, Ty): ptrtoint to an integer, addrspacecast across address spaces, else bitcast
san_ce_pointer_cast :: (c: Value_Id, t: Type_Id) -> Value_Id {
    if is_int_type(scalar_type(t)) return ce_cast(.PTRTOINT, c, t);
    if vtype(c) == t return c;
    if type_addrspace(vtype(c)) != type_addrspace(t) return ce_cast(.ADDRSPACECAST, c, t);
    return ce_cast(.BITCAST, c, t);
}

// cl::opts of the sanitizer passes that take a value (so `-name value` consumes the next argument)
SAN_VALUED_OPTS :: string.[
    "asan-shadow-addr-space", "asan-max-ins-per-bb", "asan-max-inline-poisoning-size", "asan-use-after-return",
    "asan-realign-stack", "asan-instrumentation-with-call-threshold", "asan-memory-access-callback-prefix",
    "asan-constructor-kind", "asan-mapping-scale", "asan-mapping-offset", "asan-force-experiment",
    "asan-destructor-kind", "asan-instrument-address-spaces", "asan-debug", "asan-debug-stack", "asan-debug-func",
    "asan-debug-min", "asan-debug-max",
    "msan-track-origins", "msan-poison-stack-pattern", "msan-switch-precision", "msan-instrumentation-with-call-threshold",
    "msan-and-mask", "msan-xor-mask", "msan-shadow-base", "msan-origin-base", "msan-disambiguate-warning-threshold",
];
san_takes_value :: (a: string) -> bool {
    n := a;
    if begins_with(n, "--") n = slice(n, 2, n.count - 2); else if begins_with(n, "-") n = slice(n, 1, n.count - 1); else return false;
    for SAN_VALUED_OPTS if it == n return true;
    return false;
}

// An intrinsic declaration the generated attribute table has no entry for (no test declares it), with the
// attributes LLVM's Intrinsic::getAttributes gives it (checked against opt's output)
san_intrinsic_with_attrs :: (name: string, ret: Type_Id, params: [] Type_Id, fn_attrs: string, param_attrs: [] string) -> San_Callee {
    ft := type_func(ret, params, false);
    f := lookup_global(name);
    if f != NONE return .{ft, f};
    f = new_function(ft, name, dl.program_as);
    array_add(*ir.m_functions, f);
    ps: [..] u32; ps.allocator = temp;
    for params array_add(*ps, ifx it_index < param_attrs.count then parse_attr_text(param_attrs[it_index], false) else 0);
    glob(f).attrs = attr_list_get(parse_attr_text(fn_attrs, true), 0, ps);
    return .{ft, f};
}
