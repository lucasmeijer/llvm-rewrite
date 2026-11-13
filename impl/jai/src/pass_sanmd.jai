// SanitizerBinaryMetadata: a port of llvm/lib/Transforms/Instrumentation/SanitizerBinaryMetadata.cpp
// (SanitizerBinaryMetadataPass "sanmd-module": covered / atomics / use-after-return PC sections, the weak
// ctor/dtor pairs, every cl::opt). No ignore list (constructor argument only).

sanmd_cl: struct {
    weak_callbacks := true;
    no_sanitize := true;
    emit_covered: bool;
    emit_atomics: bool;
    emit_uar: bool;
};

sanmd_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    pb :: (name: string, value: string, has_value: bool) -> bool {
        if !has_value || value == "true" || value == "1" || value == "TRUE" || value == "True" return true;
        if value == "false" || value == "0" || value == "FALSE" || value == "False" return false;
        fatal("opt: for the --% option: '%' is invalid value for boolean argument! Try 0 or 1", name, value);
        return false;
    }
    o := *sanmd_cl;
    if name == {
        case "sanitizer-metadata-weak-callbacks"; o.weak_callbacks = pb(name, value, has_value);
        case "sanitizer-metadata-nosanitize-attr"; o.no_sanitize = pb(name, value, has_value);
        case "sanitizer-metadata-covered"; o.emit_covered = pb(name, value, has_value);
        case "sanitizer-metadata-atomics"; o.emit_atomics = pb(name, value, has_value);
        case "sanitizer-metadata-uar"; o.emit_uar = pb(name, value, has_value);
        case; return false;
    }
    return true;
}

SANMD_ATOMICS :: cast(u64) 1;   // kSanitizerBinaryMetadataAtomics
SANMD_UAR :: cast(u64) 2;       // kSanitizerBinaryMetadataUAR

// MetadataInfo::Covered (0) / MetadataInfo::Atomics (1)
SANMD_FUNCTION_PREFIX :: string.["__sanitizer_metadata_covered", "__sanitizer_metadata_atomics"];
SANMD_SECTION_SUFFIX :: string.["sanmd_covered", "sanmd_atomics"];

Sanmd :: struct {
    covered, atomics, uar: bool;
    version: u32;
    mis: [..] s64;   // the MetadataInfoSet, in insertion order
}

sanmd_add_mi :: (s: *Sanmd, mi: s64) { for s.mis if it == mi return; array_add(*s.mis, mi); }
sanmd_section_name :: (s: *Sanmd, mi: s64) -> string { return tprint("%1%2!C", SANMD_SECTION_SUFFIX[mi], s.version); }

// isUARSafeCall / hasUseAfterReturnUnsafeUses / useAfterReturnUnsafe
sanmd_is_uar_safe_call :: (ci: Value_Id) -> bool {
    f := call_called_function(ci);
    if f == NONE return false;
    n := vname(f);
    return glob(f).intrinsic || fn_has_fn_attr(f, .NoReturn) || begins_with(n, "__asan_") || begins_with(n, "__hwsan_") ||
           begins_with(n, "__ubsan_") || begins_with(n, "__msan_") || begins_with(n, "__tsan_");
}
sanmd_has_uar_unsafe_uses :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) {
            if is_lifetime_start_or_end(usr) || sanmd_is_droppable(usr) continue;
            o := inst_op(usr);
            if o == .CALL && sanmd_is_uar_safe_call(usr) continue;
            if o == .LOAD continue;
            if o == .STORE && op(usr, 1) == v continue;
            if o == .GEP { if !sanmd_has_uar_unsafe_uses(usr) continue; }
            else if o == .BITCAST { if !sanmd_has_uar_unsafe_uses(usr) continue; }
        }
        return true;
    }
    return false;
}
// User::isDroppable: llvm.assume and llvm.pseudoprobe
sanmd_is_droppable :: (i: Value_Id) -> bool {
    if inst_op(i) != .CALL return false;
    id := call_iid(i);
    return id == IID_ASSUME || id == IID_PSEUDOPROBE;
}
sanmd_use_after_return_unsafe :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .ALLOCA return sanmd_has_uar_unsafe_uses(i);
    if o == .CALL {
        tk := call_tail_kind(i);
        return (tk == TCK_TAIL || tk == TCK_MUSTTAIL) && !sanmd_is_uar_safe_call(i);
    }
    return false;
}

// pretendAtomicAccess / maybeSharedMutable
sanmd_pretend_atomic_access :: (addr_in: Value_Id) -> bool {
    if addr_in == NONE return false;
    addr := strip_in_bounds_offsets(addr_in);
    if vkind(addr) != .GLOBAL_VAR return false;
    sec := glob(addr).section;
    if sec.count {
        cnts := ifx san_triple_is_coff() then ".lprfc$M" else "__llvm_prf_cnts";   // getInstrProfSectionName(IPSK_cnts, OF, false)
        if ends_with(sec, cnts) return true;
    }
    n := vname(addr);
    return begins_with(n, "__llvm_gcov") || begins_with(n, "__llvm_gcda");
}
sanmd_maybe_shared_mutable :: (addr_in: Value_Id) -> bool {
    if addr_in == NONE return true;
    ai := find_alloca_for_value(addr_in);
    if ai != NONE && !pointer_may_be_captured_bool(ai, true) return false;
    addr := strip_in_bounds_offsets(addr_in);
    if vkind(addr) == .GLOBAL_VAR && glob(addr).is_const return false;
    return true;
}

// SanitizerBinaryMetadata::runOn(Instruction)
sanmd_run_on_inst :: (s: *Sanmd, i: Value_Id, mask: *u64) -> bool {
    requires_covered := false;
    atomic_md := false;
    if s.uar && (mask.* & SANMD_UAR) == 0 && sanmd_use_after_return_unsafe(i) mask.* |= SANMD_UAR;
    if s.atomics {
        addr: Value_Id = NONE;
        o := inst_op(i);
        if o == .STORE addr = op(i, 1);
        else if o == .LOAD addr = op(i, 0);
        if may_read_or_write_memory(i) && sanmd_maybe_shared_mutable(addr) {
            // getAtomicSyncScopeID: a value only for atomic instructions
            has_ssid := inst_is_atomic(i);
            if (has_ssid && inst(i).sync != SYNC_SCOPE_SINGLE_THREAD) || sanmd_pretend_atomic_access(addr) atomic_md = true;
            mask.* |= SANMD_ATOMICS;
            requires_covered = true;
        }
    }
    if atomic_md {
        sanmd_add_mi(s, 1);
        set_metadata(i, md_kind_id("pcsections"), md_tuple(.[md_string(sanmd_section_name(s, 1))], false));
    }
    return requires_covered;
}

// SanitizerBinaryMetadata::runOn(Function)
sanmd_run_on_function :: (s: *Sanmd, f: Value_Id) {
    if is_declaration(f) return;
    if fn_has_fn_attr(f, .Naked) || fn_has_fn_attr(f, .DisableSanitizerInstrumentation) return;
    if glob(f).linkage == .AVAILABLE_EXTERNALLY return;
    mask: u64 = 0;
    requires_covered := false;
    if s.atomics || s.uar for i: fn_insts(f) if sanmd_run_on_inst(s, i, *mask) requires_covered = true;
    if sanmd_cl.no_sanitize && fn_find_str_attr(f, "no_sanitize_thread") != null mask &= ~SANMD_ATOMICS;
    if func_vararg(glob(f).value_type) mask &= ~SANMD_UAR;
    if (mask & SANMD_UAR) != 0 requires_covered = true;
    if s.covered || (mask != 0 && requires_covered) {
        sanmd_add_mi(s, 0);
        md := md_tuple(.[md_string(sanmd_section_name(s, 0)), md_tuple(.[md_value(const_int(ir.t_i64, mask))], false)], false);
        set_metadata(f, md_kind_id("pcsections"), md);
    }
}

// SanitizerBinaryMetadataPass::run / SanitizerBinaryMetadata::run
sanmd_run :: () -> Preserved {
    s: Sanmd;
    s.mis.allocator = temp;
    s.covered = sanmd_cl.emit_covered; s.atomics = sanmd_cl.emit_atomics; s.uar = sanmd_cl.emit_uar;
    s.version = 2;
    cm := san_module_code_model();
    if cm == 3 || cm == 4 s.version |= 1 << 16;   // CodeModel::Medium / Large: kVersionPtrSizeRel
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns sanmd_run_on_function(*s, f);
    if s.mis.count == 0 return PRESERVE_ALL;
    p := type_ptr(0);
    for mi: s.mis {
        marker :: (name: string) -> Value_Id {
            g := gv_create(type_ptr(0), false, .EXTERN_WEAK, NONE, name, NONE, 0, dl.globals_as);
            glob(g).visibility = 1;
            return g;
        }
        st := marker(tprint("__start_%1%2", SANMD_SECTION_SUFFIX[mi], s.version));
        en := marker(tprint("__stop_%1%2", SANMD_SECTION_SUFFIX[mi], s.version));
        args := Value_Id.[const_int(ir.t_i32, s.version), st, en];
        prefix := tprint("%1%2", SANMD_FUNCTION_PREFIX[mi], s.version);
        types := Type_Id.[ir.t_i32, p, p];
        ctor := create_sanitizer_ctor_and_init_functions(tconcat(prefix, ".module_ctor"), tconcat(SANMD_FUNCTION_PREFIX[mi], "_add"), types, args, "", sanmd_cl.weak_callbacks);
        dtor := create_sanitizer_ctor_and_init_functions(tconcat(prefix, ".module_dtor"), tconcat(SANMD_FUNCTION_PREFIX[mi], "_del"), types, args, "", sanmd_cl.weak_callbacks);
        ck: Value_Id = NONE; dk: Value_Id = NONE;
        if triple_supports_comdat() {
            glob(ctor).comdat = get_comdat(vname(ctor));
            glob(dtor).comdat = get_comdat(vname(dtor));
            gv_set_linkage(ctor, .EXTERNAL);
            gv_set_linkage(dtor, .EXTERNAL);
            glob(ctor).visibility = 1;
            glob(dtor).visibility = 1;
            ck = ctor; dk = dtor;
        }
        append_to_global_ctors(ctor, 2, ck);
        append_to_global_dtors(dtor, 2, dk);
    }
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
