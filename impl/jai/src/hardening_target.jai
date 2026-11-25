// The x86 target hooks of the stack protector and SafeStack: a port of
//   llvm/lib/Target/X86/X86ISelLoweringCall.cpp   getAddressSpace, hasStackGuardSlotTLS, SegmentOffset,
//                                                 getIRStackGuard, insertSSPDeclarations, getSafeStackPointerLocation
//   llvm/lib/Target/X86/X86ISelLowering.cpp       useStackGuardMixFP
//   llvm/lib/CodeGen/TargetLoweringBase.cpp       getDefaultSafeStackPointerLocation, getSafeStackPointerLocation,
//                                                 getIRStackGuard, insertSSPDeclarations, getSSPStackGuardCheck
// and the stack-protector / safestack entries of the x86 runtime libcall table (llvm/include/llvm/IR/RuntimeLibcalls.td:
// DefaultStackProtector, DefaultSafeStackGlobals, LibcSafestackPointerAddress, SecurityCheckCookieIfWinMSVC).
// Only x86 and x86-64 are modelled (the passes need a TargetMachine; other targets fail loudly).

Hd_Target :: struct {
    t: Triple;
    is64: bool;
}
hd_target :: (pass: string) -> Hd_Target {
    r: Hd_Target;
    r.t = triple_parse(ir.triple);
    if r.t.arch == .UnknownArch fatal(tprint("pass '%' requires TargetMachine", pass));
    if r.t.arch != .x86_64 && r.t.arch != .x86 fatal(tprint("%: only x86 targets are supported (the pass needs a TargetMachine)", pass));
    r.is64 = r.t.arch == .x86_64;
    return r;
}
hd_is_android :: (h: *Hd_Target) -> bool { return h.t.env == .Android; }
hd_is_musl :: (h: *Hd_Target) -> bool {
    e := h.t.env;
    return e == .Musl || e == .MuslABIN32 || e == .MuslABI64 || e == .MuslEABI || e == .MuslEABIHF || e == .MuslF32 || e == .MuslSF ||
           e == .MuslX32 || e == .MuslWALI || e == .OpenHOS || h.t.os == .LiteOS;
}
hd_is_glibc :: (h: *Hd_Target) -> bool {
    os := h.t.os;
    return (os == .Linux || os == .KFreeBSD || os == .Hurd) && !hd_is_android(h) && !hd_is_musl(h) && h.t.env != .PAuthTest;
}
hd_is_fuchsia :: (h: *Hd_Target) -> bool { return h.t.os == .Fuchsia; }
hd_is_openbsd :: (h: *Hd_Target) -> bool { return h.t.os == .OpenBSD; }
hd_is_windows :: (h: *Hd_Target) -> bool { return h.t.os == .Win32; }
hd_is_windows_msvc_env :: (h: *Hd_Target) -> bool {
    return hd_is_windows(h) && (h.t.env == .MSVC || h.t.env == .UnknownEnvironment);
}
hd_is_windows_itanium_env :: (h: *Hd_Target) -> bool { return hd_is_windows(h) && h.t.env == .Itanium; }
hd_is_windows_gnu_env :: (h: *Hd_Target) -> bool { return hd_is_windows(h) && h.t.env == .GNU; }
hd_is_os_msvcrt :: (h: *Hd_Target) -> bool { return hd_is_windows_msvc_env(h) || hd_is_windows_gnu_env(h) || hd_is_windows_itanium_env(h); }
hd_is_macho :: (h: *Hd_Target) -> bool { return h.t.obj == .MachO; }

// the libcall implementations (RuntimeLibcalls.td, X86CommonLibcalls)
hd_has_stack_chk_fail :: (h: *Hd_Target) -> bool { return !hd_is_openbsd(h) && !hd_is_windows_msvc_env(h) && !hd_is_windows_itanium_env(h); }
// RTLIB::STACK_CHECK_GUARD
hd_stack_check_guard_name :: (h: *Hd_Target) -> string {
    if hd_has_stack_chk_fail(h) return "__stack_chk_guard";
    if hd_is_openbsd(h) return "__guard_local";
    if hd_is_windows_msvc_env(h) || hd_is_windows_itanium_env(h) return "__security_cookie";
    return "";
}
// RTLIB::STACKPROTECTOR_CHECK_FAIL / STACK_SMASH_HANDLER / SECURITY_CHECK_COOKIE / SAFESTACK_POINTER_ADDRESS
hd_stack_chk_fail_name :: (h: *Hd_Target) -> string { return ifx hd_has_stack_chk_fail(h) then "__stack_chk_fail" else ""; }
hd_stack_smash_handler_name :: (h: *Hd_Target) -> string { return ifx hd_is_openbsd(h) then "__stack_smash_handler" else ""; }
hd_security_check_cookie_name :: (h: *Hd_Target) -> string {
    return ifx hd_is_windows_msvc_env(h) || hd_is_windows_itanium_env(h) then "__security_check_cookie" else "";
}
hd_safestack_pointer_address_name :: (h: *Hd_Target) -> string { return ifx hd_is_android(h) then "__safestack_pointer_address" else ""; }

// X86TargetLowering::getAddressSpace (the code model is never Kernel here)
hd_address_space :: (h: *Hd_Target) -> u32 {
    if h.is64 {
        if module_code_model_is_kernel() return X86AS_GS;
        return X86AS_FS;
    }
    return X86AS_GS;
}
X86AS_GS :: 256; X86AS_FS :: 257;
module_code_model_is_kernel :: () -> bool {
    m := module_flag("Code Model");
    if m == NONE return false;
    v := md_value_of(m);
    return v != NONE && vkind(v) == .C_INT && const_int_zext(v) == 4;   // CodeModel::Kernel
}
hd_has_stack_guard_slot_tls :: (h: *Hd_Target) -> bool { return hd_is_glibc(h) || hd_is_musl(h) || hd_is_fuchsia(h) || hd_is_android(h); }
// SegmentOffset: inttoptr (i32 Offset to ptr addrspace(AS))
hd_segment_offset :: (offset: s64, as: u32) -> Value_Id {
    return ce_cast(.INTTOPTR, const_int(ir.t_i32, cast,no_check(u64) offset), type_ptr(as));
}
module_flag_string :: (key: string) -> string {
    m := module_flag(key);
    if m != NONE && ir.mds[m].kind == .STRING return ir.mds[m].str;
    return "";
}
module_flag_int :: (key: string, def: s64) -> s64 {
    m := module_flag(key);
    if m == NONE return def;
    v := md_value_of(m);
    if v == NONE || vkind(v) != .C_INT return def;
    return cast,no_check(s64) const_int_zext(v);
}

// X86TargetLowering::getIRStackGuard (NONE = SelectionDAG handles the guard)
hd_ir_stack_guard :: (h: *Hd_Target) -> Value_Id {
    if hd_has_stack_guard_slot_tls(h) {
        as := hd_address_space(h);
        if hd_is_fuchsia(h) return hd_segment_offset(0x10, as);
        offset := module_flag_int("stack-protector-guard-offset", 0x7FFF_FFFF);
        if offset == 0x7FFF_FFFF offset = ifx h.is64 then 0x28 else 0x14;
        reg := module_flag_string("stack-protector-guard-reg");
        if reg == "fs" as = X86AS_FS;
        else if reg == "gs" as = X86AS_GS;
        sym := module_flag_string("stack-protector-guard-symbol");
        if sym.count fatal("stack-protector: -stack-protector-guard-symbol is not supported yet");
        return hd_segment_offset(offset, as);
    }
    // TargetLoweringBase::getIRStackGuard: OpenBSD's __guard_local
    if hd_stack_check_guard_name(h) != "__guard_local" return NONE;
    g := lookup_global("__guard_local");
    if g == NONE {
        g = new_global(.GLOBAL_VAR, type_ptr(dl.globals_as), 0, 0);
        set_name(g, "__guard_local");
        array_add(*ir.m_globals, g);
        glob(g).linkage = .EXTERNAL;
    }
    glob(g).visibility = 1;   // hidden
    return g;
}
// X86TargetLowering::insertSSPDeclarations
hd_insert_ssp_declarations :: (h: *Hd_Target) {
    cookie_fn := hd_security_check_cookie_name(h);
    guard := hd_stack_check_guard_name(h);
    if cookie_fn.count && guard.count fatal("stack-protector: the MSVC security cookie is not supported yet");
    mode := module_flag_string("stack-protector-guard");
    if (mode == "tls" || mode.count == 0) && hd_has_stack_guard_slot_tls(h) return;
    // TargetLoweringBase::insertSSPDeclarations
    if guard.count == 0 return;
    if lookup_global(guard) != NONE return;   // getOrInsertGlobal: an existing global is kept
    g := new_global(.GLOBAL_VAR, type_ptr(0), 0, 0);
    set_name(g, guard);
    array_add(*ir.m_globals, g);
    glob(g).linkage = .EXTERNAL;
    if module_direct_access_external_data() && !(hd_is_windows(h) && (h.t.env == .Cygnus || h.t.env == .GNU)) &&
       !(triple_is_os_darwin(*h.t) && hd_reloc_model(h) != RELOC_STATIC)
        glob(g).dso_local = true;
}
// Module::getDirectAccessExternalData
module_direct_access_external_data :: () -> bool {
    m := module_flag("direct-access-external-data");
    if m != NONE { v := md_value_of(m); if v != NONE && vkind(v) == .C_INT return const_int_zext(v) > 0; }
    return module_flag_int("PIC Level", 0) == 0;
}
// TargetMachine::getRelocationModel (X86's getEffectiveRelocModel, as tti_x86.jai's x86_reloc_model)
hd_reloc_model :: (h: *Hd_Target) -> s64 {
    rm := reloc_model_cl.model;
    darwin := triple_is_os_darwin(*h.t);
    if rm < 0 {
        if darwin return ifx h.is64 then RELOC_PIC else RELOC_DYNAMIC_NO_PIC;
        if hd_is_windows(h) && h.is64 return RELOC_PIC;
        return RELOC_STATIC;
    }
    if rm == RELOC_DYNAMIC_NO_PIC {
        if h.is64 return RELOC_PIC;
        if !darwin return RELOC_STATIC;
    }
    if rm == RELOC_STATIC && darwin && h.is64 return RELOC_PIC;
    return rm;
}
// TargetLoweringBase::getSSPStackGuardCheck
hd_ssp_stack_guard_check :: (h: *Hd_Target) -> Value_Id {
    n := hd_security_check_cookie_name(h);
    if n.count == 0 return NONE;
    f := lookup_global(n);
    if f != NONE && vkind(f) == .FUNCTION fatal("stack-protector: the MSVC __security_check_cookie is not supported yet");
    return NONE;
}
// X86TargetLowering::useStackGuardMixFP
hd_use_stack_guard_mix_fp :: (h: *Hd_Target) -> bool { return hd_is_os_msvcrt(h) && !hd_is_macho(h); }

// X86TargetLowering::getSafeStackPointerLocation (the value the unsafe stack pointer is loaded from)
hd_safe_stack_pointer_location :: (h: *Hd_Target, b: *Irb) -> Value_Id {
    if hd_is_android(h) return hd_segment_offset(ifx h.is64 then cast(s64) 0x48 else 0x24, hd_address_space(h));
    if hd_is_fuchsia(h) return hd_segment_offset(0x18, hd_address_space(h));
    // TargetLoweringBase::getSafeStackPointerLocation
    addr := hd_safestack_pointer_address_name(h);
    if addr.count {
        fn := get_or_insert_function(addr, type_func(type_ptr(0), .[], false));
        return irb_call(b, fn, .[]);
    }
    // getDefaultSafeStackPointerLocation(IRB, UseTLS = true)
    name := "__safestack_unsafe_stack_ptr";
    sp_ty := type_ptr(dl.alloca_as);
    g := lookup_global(name);
    if g != NONE && vkind(g) != .GLOBAL_VAR g = NONE;
    if g == NONE {
        g = new_global(.GLOBAL_VAR, sp_ty, 0, 0);
        set_name(g, name);
        array_add(*ir.m_globals, g);
        glob(g).linkage = .EXTERNAL;
        glob(g).tls = 3;   // initialexec
    } else {
        if glob(g).value_type != sp_ty fatal(tprint("% must have void* type", name));
        if glob(g).tls == 0 fatal(tprint("% must be thread-local", name));
    }
    return g;
}
