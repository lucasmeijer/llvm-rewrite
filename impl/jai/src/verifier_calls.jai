// The Verifier's call checks (part of the port of llvm/lib/IR/Verifier.cpp, see verifier.jai): visitCallBase and
// the attribute checks (verifyFunctionAttrs / verifyParameterAttrs / verifyAttributeTypes), invoke / callbr,
// musttail, inline asm constraints, visitIntrinsicCall (with the VP and constrained-FP intrinsics and
// gc.statepoint), the intrinsic signature check with LLVM's messages (Intrinsics.cpp matchIntrinsicType), and the
// convergence-control verifier (llvm/include/llvm/IR/GenericConvergenceVerifierImpl.h, ConvergenceVerifier.cpp).

// intrinsic ids; NOT_INTRINSIC for target intrinsics that our tables don't have (they can't be recognised then)
vi :: (name: string) -> Intrinsic_Id {
    for INTRINSIC_INFOS if it.name == name return cast(Intrinsic_Id)(it_index + 1);
    return NOT_INTRINSIC;
}
VI_experimental_deoptimize :: #run vi("llvm.experimental.deoptimize");
VI_donothing :: #run vi("llvm.donothing");
VI_seh_try_begin :: #run vi("llvm.seh.try.begin");
VI_seh_try_end :: #run vi("llvm.seh.try.end");
VI_seh_scope_begin :: #run vi("llvm.seh.scope.begin");
VI_seh_scope_end :: #run vi("llvm.seh.scope.end");
VI_coro_resume :: #run vi("llvm.coro.resume");
VI_coro_destroy :: #run vi("llvm.coro.destroy");
VI_coro_await_suspend_void :: #run vi("llvm.coro.await.suspend.void");
VI_coro_await_suspend_bool :: #run vi("llvm.coro.await.suspend.bool");
VI_coro_await_suspend_handle :: #run vi("llvm.coro.await.suspend.handle");
VI_experimental_patchpoint_void :: #run vi("llvm.experimental.patchpoint.void");
VI_experimental_patchpoint :: #run vi("llvm.experimental.patchpoint");
VI_fake_use :: #run vi("llvm.fake.use");
VI_experimental_gc_statepoint :: #run vi("llvm.experimental.gc.statepoint");
VI_experimental_gc_result :: #run vi("llvm.experimental.gc.result");
VI_experimental_gc_relocate :: #run vi("llvm.experimental.gc.relocate");
VI_wasm_throw :: #run vi("llvm.wasm.throw");
VI_wasm_rethrow :: #run vi("llvm.wasm.rethrow");
VI_call_preallocated_setup :: #run vi("llvm.call.preallocated.setup");
VI_call_preallocated_arg :: #run vi("llvm.call.preallocated.arg");
VI_call_preallocated_teardown :: #run vi("llvm.call.preallocated.teardown");
VI_assume :: #run vi("llvm.assume");
VI_ucmp :: #run vi("llvm.ucmp");
VI_scmp :: #run vi("llvm.scmp");
VI_coro_begin :: #run vi("llvm.coro.begin");
VI_coro_begin_custom_abi :: #run vi("llvm.coro.begin.custom.abi");
VI_coro_id :: #run vi("llvm.coro.id");
VI_is_fpclass :: #run vi("llvm.is.fpclass");
VI_fptrunc_round :: #run vi("llvm.fptrunc.round");
VI_convert_to_arbitrary_fp :: #run vi("llvm.convert.to.arbitrary.fp");
VI_convert_from_arbitrary_fp :: #run vi("llvm.convert.from.arbitrary.fp");
VI_experimental_memset_pattern :: #run vi("llvm.experimental.memset.pattern");
VI_memcpy_element_unordered_atomic :: #run vi("llvm.memcpy.element.unordered.atomic");
VI_memmove_element_unordered_atomic :: #run vi("llvm.memmove.element.unordered.atomic");
VI_memset_element_unordered_atomic :: #run vi("llvm.memset.element.unordered.atomic");
VI_gcroot :: #run vi("llvm.gcroot");
VI_gcwrite :: #run vi("llvm.gcwrite");
VI_gcread :: #run vi("llvm.gcread");
VI_init_trampoline :: #run vi("llvm.init.trampoline");
VI_reloc_none :: #run vi("llvm.reloc.none");
VI_stackprotector :: #run vi("llvm.stackprotector");
VI_localescape :: #run vi("llvm.localescape");
VI_localrecover :: #run vi("llvm.localrecover");
VI_eh_exceptioncode :: #run vi("llvm.eh.exceptioncode");
VI_eh_exceptionpointer :: #run vi("llvm.eh.exceptionpointer");
VI_get_active_lane_mask :: #run vi("llvm.get.active.lane.mask");
VI_experimental_get_vector_length :: #run vi("llvm.experimental.get.vector.length");
VI_experimental_guard :: #run vi("llvm.experimental.guard");
VI_vastart :: #run vi("llvm.va_start");
VI_get_dynamic_area_offset :: #run vi("llvm.get.dynamic.area.offset");
VI_smul_fix :: #run vi("llvm.smul.fix");
VI_smul_fix_sat :: #run vi("llvm.smul.fix.sat");
VI_umul_fix :: #run vi("llvm.umul.fix");
VI_umul_fix_sat :: #run vi("llvm.umul.fix.sat");
VI_sdiv_fix :: #run vi("llvm.sdiv.fix");
VI_sdiv_fix_sat :: #run vi("llvm.sdiv.fix.sat");
VI_udiv_fix :: #run vi("llvm.udiv.fix");
VI_udiv_fix_sat :: #run vi("llvm.udiv.fix.sat");
VI_lrint :: #run vi("llvm.lrint");
VI_llrint :: #run vi("llvm.llrint");
VI_lround :: #run vi("llvm.lround");
VI_llround :: #run vi("llvm.llround");
VI_bswap :: #run vi("llvm.bswap");
VI_invariant_start :: #run vi("llvm.invariant.start");
VI_matrix_multiply :: #run vi("llvm.matrix.multiply");
VI_matrix_transpose :: #run vi("llvm.matrix.transpose");
VI_matrix_column_major_load :: #run vi("llvm.matrix.column.major.load");
VI_matrix_column_major_store :: #run vi("llvm.matrix.column.major.store");
VI_stepvector :: #run vi("llvm.stepvector");
VI_experimental_vector_match :: #run vi("llvm.experimental.vector.match");
VI_vector_insert :: #run vi("llvm.vector.insert");
VI_vector_extract :: #run vi("llvm.vector.extract");
VI_vector_partial_reduce_fadd :: #run vi("llvm.vector.partial.reduce.fadd");
VI_vector_partial_reduce_add :: #run vi("llvm.vector.partial.reduce.add");
VI_experimental_noalias_scope_decl :: #run vi("llvm.experimental.noalias.scope.decl");
VI_preserve_array_access_index :: #run vi("llvm.preserve.array.access.index");
VI_preserve_struct_access_index :: #run vi("llvm.preserve.struct.access.index");
VI_callbr_landingpad :: #run vi("llvm.callbr.landingpad");
VI_structured_gep :: #run vi("llvm.structured.gep");
VI_structured_alloca :: #run vi("llvm.structured.alloca");
VI_experimental_convergence_entry :: #run vi("llvm.experimental.convergence.entry");
VI_experimental_convergence_anchor :: #run vi("llvm.experimental.convergence.anchor");
VI_experimental_convergence_loop :: #run vi("llvm.experimental.convergence.loop");
VI_ptrmask :: #run vi("llvm.ptrmask");
VI_thread_pointer :: #run vi("llvm.thread.pointer");
VI_threadlocal_address :: #run vi("llvm.threadlocal.address");
VI_lifetime_start :: #run vi("llvm.lifetime.start");
VI_lifetime_end :: #run vi("llvm.lifetime.end");
VI_sponentry :: #run vi("llvm.sponentry");
VI_write_volatile_register :: #run vi("llvm.write_volatile_register");
VI_ptrauth_auth_with_pc_and_resign :: #run vi("llvm.ptrauth.auth.with.pc.and.resign");
VI_objc_retainAutoreleasedReturnValue :: #run vi("llvm.objc.retainAutoreleasedReturnValue");
VI_objc_claimAutoreleasedReturnValue :: #run vi("llvm.objc.claimAutoreleasedReturnValue");
VI_objc_unsafeClaimAutoreleasedReturnValue :: #run vi("llvm.objc.unsafeClaimAutoreleasedReturnValue");
VI_experimental_constrained_fcmp :: #run vi("llvm.experimental.constrained.fcmp");
VI_experimental_constrained_fcmps :: #run vi("llvm.experimental.constrained.fcmps");
VI_experimental_constrained_fptosi :: #run vi("llvm.experimental.constrained.fptosi");
VI_experimental_constrained_fptoui :: #run vi("llvm.experimental.constrained.fptoui");
VI_experimental_constrained_sitofp :: #run vi("llvm.experimental.constrained.sitofp");
VI_experimental_constrained_uitofp :: #run vi("llvm.experimental.constrained.uitofp");
VI_experimental_constrained_fptrunc :: #run vi("llvm.experimental.constrained.fptrunc");
VI_experimental_constrained_fpext :: #run vi("llvm.experimental.constrained.fpext");
VI_vp_fcmp :: #run vi("llvm.vp.fcmp");
VI_vp_icmp :: #run vi("llvm.vp.icmp");
VI_vp_is_fpclass :: #run vi("llvm.vp.is.fpclass");
VI_experimental_vp_splice :: #run vi("llvm.experimental.vp.splice");
VI_vp_trunc :: #run vi("llvm.vp.trunc");
VI_vp_zext :: #run vi("llvm.vp.zext");
VI_vp_sext :: #run vi("llvm.vp.sext");
VI_vp_fptrunc :: #run vi("llvm.vp.fptrunc");
VI_vp_fpext :: #run vi("llvm.vp.fpext");

// calling conventions (llvm/IR/CallingConv.h)
VCC_C :: 0; VCC_FAST :: 8; VCC_COLD :: 9; VCC_ANYREG :: 13; VCC_TAIL :: 18; VCC_SWIFTTAIL :: 20; VCC_PTX_KERNEL :: 71;
VCC_PTX_DEVICE :: 72; VCC_SPIR_KERNEL :: 76; VCC_INTEL_OCL_BI :: 77; VCC_X86_INTR :: 83; VCC_AMDGPU_VS :: 87;
VCC_AMDGPU_GS :: 88; VCC_AMDGPU_PS :: 89; VCC_AMDGPU_CS :: 90; VCC_AMDGPU_KERNEL :: 91; VCC_AMDGPU_HS :: 93;
VCC_AMDGPU_LS :: 95; VCC_AMDGPU_ES :: 96; VCC_AMDGPU_CS_CHAIN :: 104; VCC_AMDGPU_CS_CHAIN_PRESERVE :: 105;
VCC_AMDGPU_GFX_WHOLE_WAVE :: 124;

// isCallableCC
vf_is_callable_cc :: (cc: u32) -> bool {
    return !(cc == VCC_AMDGPU_CS_CHAIN || cc == VCC_AMDGPU_CS_CHAIN_PRESERVE || cc == VCC_AMDGPU_GFX_WHOLE_WAVE || cc == VCC_AMDGPU_CS ||
        cc == VCC_AMDGPU_ES || cc == VCC_AMDGPU_GS || cc == VCC_AMDGPU_HS || cc == VCC_AMDGPU_KERNEL || cc == VCC_AMDGPU_LS ||
        cc == VCC_AMDGPU_PS || cc == VCC_AMDGPU_VS || cc == VCC_SPIR_KERNEL || cc == VCC_PTX_KERNEL);
}

// IntrinsicInst::mayLowerToFunctionCall
intrinsic_may_lower_to_function_call :: (iid: Intrinsic_Id) -> bool {
    if iid == NOT_INTRINSIC return false;
    n := intrinsic_name(iid);
    if begins_with(n, "llvm.objc.") return true;
    for string.["llvm.memcpy", "llvm.memmove", "llvm.memset", "llvm.memcpy.inline", "llvm.memset.inline",
        "llvm.memcpy.element.unordered.atomic", "llvm.memmove.element.unordered.atomic", "llvm.memset.element.unordered.atomic",
        "llvm.experimental.memset.pattern"]
        if n == it return true;
    return false;
}

// ---------------------------------------------------------------- attribute helpers

vf_attr_string :: (a: *Attr) -> string {
    start := W.buf.count;
    write_attribute(a, false);
    s := copy_string(slice_of_buf(start),, allocator = temp);
    W.buf.count = start;
    return s;
}

// AttributeList::getNumAttrSets <= Params + 2
vf_attr_count_ok :: (l: u32, nparams: u32) -> bool {
    if l == 0 return true;
    r := ir.attr_lists[l];
    n: s64 = 0;
    if r.params.count n = 2 + r.params.count;
    else if r.ret n = 2;
    else if r.fn n = 1;
    return n <= cast(s64) nparams + 2;
}
// AttributeList::hasAttrSomewhere(Kind)
vf_attr_somewhere :: (l: u32, k: Attr_Kind) -> bool {
    if l == 0 return false;
    r := ir.attr_lists[l];
    if attr_set_has(r.fn, k) || attr_set_has(r.ret, k) return true;
    for r.params if attr_set_has(it, k) return true;
    return false;
}
// Function::hasStructRetAttr (params 0 and 1) when only_first_two, else any parameter
vf_has_param_attr_somewhere :: (l: u32, k: Attr_Kind, only_first_two: bool) -> bool {
    if l == 0 return false;
    r := ir.attr_lists[l];
    for r.params {
        if only_first_two && it_index > 1 break;
        if attr_set_has(it, k) return true;
    }
    return false;
}
vf_call_param_has_attr :: (call: Value_Id, k: u32, kind: Attr_Kind) -> bool { return call_param_has_attr(call, k, kind); }

// AttributeFuncs::typeIncompatible(Ty, AS)
vf_type_incompatible :: (ty: Type_Id, set: u32, k: Attr_Kind) -> bool {
    if k == .AllocAlign return !is_int_type(ty);
    if k == .SExt || k == .ZExt return !(is_int_type(ty) || type_kind(ty) == .BYTE);
    if k == .Range {
        if !is_int_or_int_vector(ty) return true;
        a := attr_set_find(set, .Range);
        return a && cast(u32) a.ival != type_int_width(scalar_type(ty));
    }
    if !is_ptr_type(ty) {
        if k == .NoAlias || k == .NonNull || k == .ReadNone || k == .ReadOnly || k == .Dereferenceable || k == .DereferenceableOrNull ||
           k == .Writable || k == .DeadOnUnwind || k == .Initializes || k == .Captures || k == .DeadOnReturn return true;
        if k == .Nest || k == .SwiftError || k == .Preallocated || k == .InAlloca || k == .ByVal || k == .StructRet || k == .ByRef ||
           k == .ElementType || k == .AllocatedPointer return true;
    }
    if k == .Alignment return !vf_is_ptr_or_ptr_vector(ty);
    if k == .NoFPClass return !attr_nofpclass_compatible_type(ty);
    if k == .NoUndef return type_kind(ty) == .VOID;
    return false;
}

vf_verify_attribute_types :: (set: u32, v: Value_Id) {
    for * a: attr_set_items(set) {
        if a.kind == .STRING_ATTR {
            for STRBOOL_ATTRS if a.key == it {
                if !(a.val.count == 0 || a.val == "true" || a.val == "false")
                    check_failed(tprint("invalid value for '%' attribute: %", it, a.val));
            }
            continue;
        }
        // (an int attribute always carries its argument: the parser enforces it)
    }
}

vf_verify_parameter_attrs :: (set: u32, ty: Type_Id, v: Value_Id) {
    if set == 0 return;
    vf_verify_attribute_types(set, v);
    for * a: attr_set_items(set)
        vcheck(a.kind == .STRING_ATTR || (attr_kind_props(a.kind) & ATTR_PROP_PARAM) != 0, tprint("Attribute '%' does not apply to parameters", vf_attr_string(a)), vq_val(v));
    has :: (k: Attr_Kind) -> bool #expand { return attr_set_has(`set, k); }
    if has(.ImmArg) {
        n := attr_set_items(set).count - (ifx has(.Range) then 1 else 0);
        vcheck(n == 1, "Attribute 'immarg' is incompatible with other attributes except the 'range' attribute", vq_val(v));
    }
    cnt := 0;
    if has(.ByVal) cnt += 1;
    if has(.InAlloca) cnt += 1;
    if has(.Preallocated) cnt += 1;
    if has(.StructRet) || has(.InReg) cnt += 1;
    if has(.Nest) cnt += 1;
    if has(.ByRef) cnt += 1;
    vcheck(cnt <= 1, "Attributes 'byval', 'inalloca', 'preallocated', 'inreg', 'nest', 'byref', and 'sret' are incompatible!", vq_val(v));
    vcheck(!(has(.InAlloca) && has(.ReadOnly)), "Attributes 'inalloca and readonly' are incompatible!", vq_val(v));
    vcheck(!(has(.StructRet) && has(.Returned)), "Attributes 'sret and returned' are incompatible!", vq_val(v));
    vcheck(!(has(.ZExt) && has(.SExt)), "Attributes 'zeroext and signext' are incompatible!", vq_val(v));
    vcheck(!(has(.ReadNone) && has(.ReadOnly)), "Attributes 'readnone and readonly' are incompatible!", vq_val(v));
    vcheck(!(has(.ReadNone) && has(.WriteOnly)), "Attributes 'readnone and writeonly' are incompatible!", vq_val(v));
    vcheck(!(has(.ReadOnly) && has(.WriteOnly)), "Attributes 'readonly and writeonly' are incompatible!", vq_val(v));
    vcheck(!(has(.NoInline) && has(.AlwaysInline)), "Attributes 'noinline and alwaysinline' are incompatible!", vq_val(v));
    vcheck(!(has(.Writable) && has(.ReadNone)), "Attributes writable and readnone are incompatible!", vq_val(v));
    vcheck(!(has(.Writable) && has(.ReadOnly)), "Attributes writable and readonly are incompatible!", vq_val(v));
    for * a: attr_set_items(set) {
        if a.kind != .STRING_ATTR && vf_type_incompatible(ty, set, a.kind) {
            check_failed(tprint("Attribute '%' applied to incompatible type!", vf_attr_string(a)), vq_val(v));
            return;
        }
    }
    if is_ptr_type(ty) {
        al := attr_set_find(set, .Alignment);
        if al vcheck(al.ival <= MAXIMUM_ALIGNMENT, "huge alignment values are unsupported", vq_val(v));
        bv := attr_set_find(set, .ByVal);
        if bv {
            vcheck(vf_type_is_sized(bv.ty), "Attribute 'byval' does not support unsized types!", vq_val(v));
            vcheck(!type_contains_non_local_target_ext(bv.ty), "'byval' argument has illegal target extension type", vq_val(v));
            vcheck(dl_type_alloc_size(bv.ty) < (cast(u64) 1 << 32), "huge 'byval' arguments are unsupported", vq_val(v));
        }
        br := attr_set_find(set, .ByRef);
        if br {
            vcheck(vf_type_is_sized(br.ty), "Attribute 'byref' does not support unsized types!", vq_val(v));
            vcheck(dl_type_alloc_size(br.ty) < (cast(u64) 1 << 32), "huge 'byref' arguments are unsupported", vq_val(v));
        }
        ia := attr_set_find(set, .InAlloca);
        if ia {
            vcheck(vf_type_is_sized(ia.ty), "Attribute 'inalloca' does not support unsized types!", vq_val(v));
            vcheck(dl_type_alloc_size(ia.ty) < (cast(u64) 1 << 32), "huge 'inalloca' arguments are unsupported", vq_val(v));
        }
        pa := attr_set_find(set, .Preallocated);
        if pa {
            vcheck(vf_type_is_sized(pa.ty), "Attribute 'preallocated' does not support unsized types!", vq_val(v));
            vcheck(dl_type_alloc_size(pa.ty) < (cast(u64) 1 << 32), "huge 'preallocated' arguments are unsupported", vq_val(v));
        }
    }
    ini := attr_set_find(set, .Initializes);
    if ini {
        vcheck(ini.lo.count > 0, "Attribute 'initializes' does not support empty list", vq_val(v));
        // ConstantRangeList::isOrderedRanges: each range non-empty, sorted, and not overlapping or touching
        ordered := true;
        for k: 0..ini.lo.count - 1 {
            lo := cast,no_check(s64) ini.lo[k]; hi := cast,no_check(s64) ini.hi[k];
            if lo >= hi { ordered = false; break; }
            if k > 0 && lo <= cast,no_check(s64) ini.hi[k - 1] { ordered = false; break; }
        }
        vcheck(ordered, "Attribute 'initializes' does not support unordered ranges", vq_val(v));
    }
    nf := attr_set_find(set, .NoFPClass);
    if nf {
        vcheck(nf.ival != 0, "Attribute 'nofpclass' must have at least one test bit set", vq_val(v));
        vcheck((nf.ival & ~cast(u64) FC_ALL_FLAGS) == 0, "Invalid value for 'nofpclass' test mask", vq_val(v));
    }
    rg := attr_set_find(set, .Range);
    if rg vcheck(is_int_or_int_vector(ty) && type_int_width(scalar_type(ty)) == cast(u32) rg.ival, "Range bit width must match type bit width!", vq_val(v));
}

vf_fn_str_attr :: (set: u32, key: string) -> *Attr {
    for * attr_set_items(set) if it.kind == .STRING_ATTR && it.key == key return it;
    return null;
}

vf_check_unsigned_base_ten_fn_attr :: (fnset: u32, name: string, v: Value_Id) {
    a := vf_fn_str_attr(fnset, name);
    if !a return;
    ok := a.val.count > 0 && a.val.count <= 10;
    n: u64 = 0;
    for c: cast([] u8) a.val { if c < #char "0" || c > #char "9" { ok = false; break; } n = n * 10 + (c - #char "0"); }
    if n > 0xFFFF_FFFF ok = false;
    if !ok check_failed(tprint("\"%\" takes an unsigned integer: %", name, a.val), vq_val(v));
}

// MemoryEffects bits (parser.jai): 2 bits per location, ArgMem is location 0
vf_memory_argmem_mod :: (fnset: u32) -> bool {
    a := attr_set_find(fnset, .Memory);
    if !a return true;   // no memory attribute: unknown
    return ((a.ival >> 0) & 2) != 0;
}

vf_verify_function_attrs :: (ft: Type_Id, attrs: u32, v: Value_Id, is_intrinsic: bool, is_inline_asm: bool) {
    if attrs == 0 return;
    saw_nest, saw_returned, saw_sret, saw_swiftself, saw_swiftasync, saw_swifterror := false;
    ret := attr_list_ret(attrs);
    for * a: attr_set_items(ret)
        vcheck(a.kind == .STRING_ATTR || (attr_kind_props(a.kind) & ATTR_PROP_RET) != 0, tprint("Attribute '%' does not apply to function return values", vf_attr_string(a)), vq_val(v));
    vf_verify_parameter_attrs(ret, func_ret(ft), v);
    np := func_nparams(ft);
    for i: 0..cast(s64) np - 1 {
        ty := func_param(ft, cast(u32) i);
        pa := attr_list_param(attrs, cast(u32) i);
        if !is_intrinsic {
            vcheck(!attr_set_has(pa, .ImmArg), "immarg attribute only applies to intrinsics", vq_val(v));
            if !is_inline_asm vcheck(!attr_set_has(pa, .ElementType), "Attribute 'elementtype' can only be applied to intrinsics and inline asm.", vq_val(v));
        }
        vf_verify_parameter_attrs(pa, ty, v);
        if attr_set_has(pa, .Nest) { vcheck(!saw_nest, "More than one parameter has attribute nest!", vq_val(v)); saw_nest = true; }
        if attr_set_has(pa, .Returned) {
            vcheck(!saw_returned, "More than one parameter has attribute returned!", vq_val(v));
            vcheck(vf_can_losslessly_bitcast(ty, func_ret(ft)), "Incompatible argument and return types for 'returned' attribute", vq_val(v));
            saw_returned = true;
        }
        if attr_set_has(pa, .StructRet) {
            vcheck(!saw_sret, "Cannot have multiple 'sret' parameters!", vq_val(v));
            vcheck(i == 0 || i == 1, "Attribute 'sret' is not on first or second parameter!", vq_val(v));
            saw_sret = true;
        }
        if attr_set_has(pa, .SwiftSelf) { vcheck(!saw_swiftself, "Cannot have multiple 'swiftself' parameters!", vq_val(v)); saw_swiftself = true; }
        if attr_set_has(pa, .SwiftAsync) { vcheck(!saw_swiftasync, "Cannot have multiple 'swiftasync' parameters!", vq_val(v)); saw_swiftasync = true; }
        if attr_set_has(pa, .SwiftError) { vcheck(!saw_swifterror, "Cannot have multiple 'swifterror' parameters!", vq_val(v)); saw_swifterror = true; }
        if attr_set_has(pa, .InAlloca) vcheck(i == cast(s64) np - 1, "inalloca isn't on the last parameter!", vq_val(v));
    }
    fns := attr_list_fn(attrs);
    if fns == 0 return;
    vf_verify_attribute_types(fns, v);
    for * a: attr_set_items(fns)
        vcheck(a.kind == .STRING_ATTR || (attr_kind_props(a.kind) & ATTR_PROP_FN) != 0, tprint("Attribute '%' does not apply to functions!", vf_attr_string(a)), vq_val(v));
    has :: (k: Attr_Kind) -> bool #expand { return attr_set_has(`fns, k); }
    hass :: (k: string) -> bool #expand { return vf_fn_str_attr(`fns, k) != null; }
    vcheck(!(has(.NoInline) && has(.AlwaysInline)), "Attributes 'noinline and alwaysinline' are incompatible!", vq_val(v));
    if has(.OptimizeNone) {
        vcheck(has(.NoInline), "Attribute 'optnone' requires 'noinline'!", vq_val(v));
        vcheck(!has(.OptimizeForSize), "Attributes 'optsize and optnone' are incompatible!", vq_val(v));
        vcheck(!has(.MinSize), "Attributes 'minsize and optnone' are incompatible!", vq_val(v));
        vcheck(!has(.OptimizeForDebugging), "Attributes 'optdebug and optnone' are incompatible!", vq_val(v));
    }
    vcheck(!(has(.SanitizeRealtime) && has(.SanitizeRealtimeBlocking)), "Attributes 'sanitize_realtime and sanitize_realtime_blocking' are incompatible!", vq_val(v));
    if has(.OptimizeForDebugging) {
        vcheck(!has(.OptimizeForSize), "Attributes 'optsize and optdebug' are incompatible!", vq_val(v));
        vcheck(!has(.MinSize), "Attributes 'minsize and optdebug' are incompatible!", vq_val(v));
    }
    vcheck(!vf_attr_somewhere(attrs, .Writable) || vf_memory_argmem_mod(fns), "Attribute writable and memory without argmem: write are incompatible!", vq_val(v));
    if hass("aarch64_pstate_sm_enabled") vcheck(!hass("aarch64_pstate_sm_compatible"), "Attributes 'aarch64_pstate_sm_enabled and aarch64_pstate_sm_compatible' are incompatible!", vq_val(v));
    za := 0;
    for string.["aarch64_new_za", "aarch64_in_za", "aarch64_inout_za", "aarch64_out_za", "aarch64_preserves_za", "aarch64_za_state_agnostic"] if hass(it) za += 1;
    vcheck(za <= 1, "Attributes 'aarch64_new_za', 'aarch64_in_za', 'aarch64_out_za', 'aarch64_inout_za', 'aarch64_preserves_za' and 'aarch64_za_state_agnostic' are mutually exclusive", vq_val(v));
    zt := 0;
    for string.["aarch64_new_zt0", "aarch64_in_zt0", "aarch64_inout_zt0", "aarch64_out_zt0", "aarch64_preserves_zt0", "aarch64_za_state_agnostic"] if hass(it) zt += 1;
    vcheck(zt <= 1, "Attributes 'aarch64_new_zt0', 'aarch64_in_zt0', 'aarch64_out_zt0', 'aarch64_inout_zt0', 'aarch64_preserves_zt0' and 'aarch64_za_state_agnostic' are mutually exclusive", vq_val(v));
    if has(.JumpTable) vcheck(is_global_value(vkind(v)) && glob(v).unnamed_addr == 2, "Attribute 'jumptable' requires 'unnamed_addr'", vq_val(v));
    asz := attr_set_find(fns, .AllocSize);
    if asz {
        check_param :: (name: string, pno: u64, ft: Type_Id, v: Value_Id) -> bool {
            if pno >= func_nparams(ft) { check_failed(tprint("'allocsize' % argument is out of bounds", name), vq_val(v)); return false; }
            if !is_int_type(func_param(ft, cast(u32) pno)) { check_failed(tprint("'allocsize' % argument must refer to an integer parameter", name), vq_val(v)); return false; }
            return true;
        }
        if !check_param("element size", asz.ival >> 32, ft, v) return;
        n := asz.ival & 0xFFFF_FFFF;
        if n != 0xFFFF_FFFF && !check_param("number of elements", n, ft, v) return;
    }
    ak := attr_set_find(fns, .AllocKind);
    if ak {
        // AllocFnKind: Alloc 1, Realloc 2, Free 4, Uninitialized 8, Zeroed 16, Aligned 32
        k := ak.ival;
        t := k & 7;
        if !(t == 1 || t == 2 || t == 4) check_failed("'allockind()' requires exactly one of alloc, realloc, and free");
        if t == 4 && (k & (8 | 16 | 32)) != 0 check_failed("'allockind(\"free\")' doesn't allow uninitialized, zeroed, or aligned modifiers.");
        if (k & 24) == 24 check_failed("'allockind()' can't be both zeroed and uninitialized");
    }
    avz := vf_fn_str_attr(fns, "alloc-variant-zeroed");
    if avz {
        vcheck(avz.val.count > 0, "'alloc-variant-zeroed' must not be empty");
        found, variant := table_find(*ir.m_symtab, avz.val);
        if found && vkind(variant) == .FUNCTION {
            vfns := attr_list_fn(glob(variant).attrs);
            fam := vf_fn_str_attr(fns, "alloc-family");
            vfam := vf_fn_str_attr(vfns, "alloc-family");
            if fam vcheck(vfam != null && vfam.val == fam.val, "'alloc-variant-zeroed' must name a function belonging to the same 'alloc-family'");
            vak := attr_set_find(vfns, .AllocKind);
            vcheck(vak != null && (vak.ival & 16) != 0, "'alloc-variant-zeroed' must name a function with 'allockind(\"zeroed\")'");
            vcheck(ft == glob(variant).value_type, "'alloc-variant-zeroed' must name a function with the same signature");
            if vkind(v) == .FUNCTION vcheck(glob(v).cc == glob(variant).cc, "'alloc-variant-zeroed' must name a function with the same calling convention");
        }
    }
    vs := attr_set_find(fns, .VScaleRange);
    if vs {
        // VScaleRange: min in the high 32 bits, max in the low (0 = unbounded)
        mn := vs.ival >> 32;
        mx := vs.ival & 0xFFFF_FFFF;
        pow2 :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
        if mn == 0 check_failed("'vscale_range' minimum must be greater than 0", vq_val(v));
        else if !pow2(mn) check_failed("'vscale_range' minimum must be power-of-two value", vq_val(v));
        if mx != 0 && mn > mx check_failed("'vscale_range' minimum cannot be greater than maximum", vq_val(v));
        else if mx != 0 && !pow2(mx) check_failed("'vscale_range' maximum must be power-of-two value", vq_val(v));
    }
    fp := vf_fn_str_attr(fns, "frame-pointer");
    if fp {
        s := fp.val;
        if s != "all" && s != "non-leaf" && s != "none" && s != "reserved" && s != "non-leaf-no-reserve"
            check_failed(tprint("invalid value for 'frame-pointer' attribute: %", s), vq_val(v));
    }
    vf_check_unsigned_base_ten_fn_attr(fns, "patchable-function-prefix", v);
    vf_check_unsigned_base_ten_fn_attr(fns, "patchable-function-entry", v);
    pfes := vf_fn_str_attr(fns, "patchable-function-entry-section");
    if pfes vcheck(pfes.val.count > 0, "\"patchable-function-entry-section\" must not be empty");
    vf_check_unsigned_base_ten_fn_attr(fns, "warn-stack-size", v);
    sra := vf_fn_str_attr(fns, "sign-return-address");
    if sra {
        s := sra.val;
        if s != "none" && s != "all" && s != "non-leaf" check_failed(tprint("invalid value for 'sign-return-address' attribute: %", s), vq_val(v));
    }
    srak := vf_fn_str_attr(fns, "sign-return-address-key");
    if srak {
        s := srak.val;
        if s != "a_key" && s != "b_key" check_failed(tprint("invalid value for 'sign-return-address-key' attribute: %", s), vq_val(v));
        if !sra check_failed("'sign-return-address-key' present without `sign-return-address`");
    }
    for string.["branch-target-enforcement", "branch-protection-pauth-lr", "guarded-control-stack"] {
        a := vf_fn_str_attr(fns, it);
        if a && a.val.count && a.val != "true" && a.val != "false" check_failed(tprint("invalid value for '%' attribute: %", it, a.val), vq_val(v));
    }
    vfa := vf_fn_str_attr(fns, "vector-function-abi-variant");
    if vfa {
        ok := vfabi_try_demangle_ok(vfa.val, ft);
        if !ok check_failed(tprint("invalid name for a VFABI variant: %", vfa.val), vq_val(v));
    }
    mf := vf_fn_str_attr(fns, "modular-format");
    if mf {
        args := split(mf.val, ",",, allocator = temp);
        vcheck(args.count >= 5, "modular-format attribute requires at least 5 arguments", vq_val(v));
        upper := cast(u64) func_nparams(ft) + (ifx func_vararg(ft) then cast(u64) 1 else 0);
        ok1, fi := vf_parse_unsigned(args[1]);
        vcheck(ok1, "modular-format attribute format string index is not an integer", vq_val(v));
        vcheck(fi > 0, "modular-format attribute format string index must be greater than 0", vq_val(v));
        vcheck(fi <= upper, "modular-format attribute format string index is out of bounds", vq_val(v));
        ok2, fa := vf_parse_unsigned(args[2]);
        vcheck(ok2, "modular-format attribute first arg index is not an integer", vq_val(v));
        vcheck(fa <= upper, "modular-format attribute first arg index is out of bounds", vq_val(v));
        vcheck(args[3].count > 0, "modular-format attribute modular implementation function name cannot be empty", vq_val(v));
        vcheck(args[4].count > 0, "modular-format attribute implementation name cannot be empty", vq_val(v));
    }
    tf := vf_fn_str_attr(fns, "target-features");
    if tf && tf.val.count {
        for f: split(tf.val, ",",, allocator = temp) {
            if f.count == 0 check_failed("target-features attribute should not contain an empty string");
            else vcheck(f[0] == #char "+" || f[0] == #char "-", tprint("target feature '%' must start with a '+' or '-'", f), vq_val(v));
        }
    }
}

vf_parse_unsigned :: (s: string) -> (bool, u64) {
    if s.count == 0 return false, 0;
    n: u64 = 0;
    for c: cast([] u8) s { if c < #char "0" || c > #char "9" return false, 0; n = n * 10 + (c - #char "0"); if n > 0xFFFF_FFFF return false, 0; }
    return true, n;
}

// VFABI::tryDemangleForVFABI(S, FT).has_value()
vfabi_try_demangle_ok :: (s: string, ft: Type_Id) -> bool {
    ok, info := vfabi_try_demangle(s, ft);
    return ok;
}

// Type::canLosslesslyBitCastTo
vf_can_losslessly_bitcast :: (a: Type_Id, b: Type_Id) -> bool {
    if a == b return true;
    if !is_first_class(a) || !is_first_class(b) return false;
    if is_vector_type(a) && is_vector_type(b) return vf_primitive_size_bits(a) == vf_primitive_size_bits(b) && (type_kind(a) == .SVECTOR) == (type_kind(b) == .SVECTOR);
    if type_kind(a) == .VECTOR && type_kind(b) == .X86_AMX && vf_primitive_size_bits(a) == 8192 return true;
    if type_kind(a) == .X86_AMX && type_kind(b) == .VECTOR && vf_primitive_size_bits(b) == 8192 return true;
    return false;
}

// ---------------------------------------------------------------- calls

vf_bundle_count :: (call: Value_Id, tag: string) -> u32 {
    n: u32 = 0;
    nb := call_num_bundles(call);
    if nb > 0 for k: 0..nb-1 if call_bundle_tag(call, k) == tag n += 1;
    return n;
}
vf_bundle_inputs :: (call: Value_Id, k: u32) -> (u32, u32) {
    b := ir.u32_pool[inst(call).idx + 3 * k + 1];
    e := ir.u32_pool[inst(call).idx + 3 * k + 2];
    return b, e;
}

vf_visit_call :: (i: Value_Id) {
    vf_visit_call_base(i);
    if ((inst(i).flags >> TAIL_SHIFT) & 3) == 2 vf_verify_must_tail_call(i);
}

vf_visit_invoke :: (i: Value_Id) {
    vf_visit_call_base(i);
    vcheck(block_is_eh_pad(vf_invoke_unwind_dest(i)), "The unwind destination does not have an exception handling instruction!", vq_val(i));
    vf_visit_terminator(i);
}

vf_visit_callbr :: (i: Value_Id) {
    callee := call_callee(i);
    if vkind(callee) != .INLINE_ASM {
        vcheck(call_called_function(i) != NONE, "callbr: indirect function / invalid signature");
        vcheck(call_num_bundles(i) == 0, "callbr for intrinsics currently doesn't support operand bundles");
        iid := vf_iid(call_called_function(i));
        // isSupportedCallBrIntrinsic: only amdgcn.kill (not in our tables)
        check_failed("callbr currently only supports asm-goto and selected intrinsics");
        vf_visit_intrinsic_call(iid, i);
    } else {
        a := inline_asms[ir.v_aux[callee]];
        vcheck((a.flags & 8) == 0, "Unwinding from Callbr is not allowed");
        vf_verify_inline_asm_call(i);
    }
    vf_visit_terminator(i);
}

vf_visit_call_base :: (call: Value_Id) {
    r := inst(call);
    callee := call_callee(call);
    vcheck(is_ptr_type(vtype(callee)), "Called function must be a pointer!", vq_val(call));
    fty := r.ty2;
    na := call_num_args(call);
    np := func_nparams(fty);
    if func_vararg(fty) vcheck(na >= np, "Called function requires more parameters than were provided!", vq_val(call));
    else vcheck(na == np, "Incorrect number of arguments passed to called function!", vq_val(call));
    for k: 0..cast(s64) np - 1
        vcheck(vtype(op(call, cast(u32) k)) == func_param(fty, cast(u32) k), "Call parameter type does not match function signature!",
            vq_val(op(call, cast(u32) k)), vq_ty(func_param(fty, cast(u32) k)), vq_val(call));
    attrs := r.attrs;
    vcheck(vf_attr_count_ok(attrs, na), "Attribute after last parameter!", vq_val(call));
    sc := strip_pointer_casts(callee);
    callee_fn := ifx vkind(sc) == .FUNCTION then sc else NONE;
    is_intrinsic := callee_fn != NONE && glob(callee_fn).intrinsic;
    if is_intrinsic vcheck(glob(callee_fn).value_type == fty, "Intrinsic called with incompatible signature", vq_val(call));
    vcheck(vf_is_callable_cc(r.cc), "calling convention does not permit calls", vq_val(call));
    if !is_intrinsic {
        vf_verify_type_align(func_ret(fty), "return type", call);
        for k: 0..cast(s64) np - 1 vf_verify_type_align(func_param(fty, cast(u32) k), "argument passed", call);
    }
    fns := attr_list_fn(attrs);
    if attr_set_has(fns, .Speculatable)
        vcheck(callee_fn != NONE && attr_set_has(attr_list_fn(glob(callee_fn).attrs), .Speculatable), "speculatable attribute may not apply to call sites", vq_val(call));
    called := call_called_function(call);
    iid := intrinsic_id_of_call_iid(call);   // CallBase::getIntrinsicID: of the callee operand, whatever its type
    if attr_set_has(fns, .Preallocated)
        vcheck(iid == VI_call_preallocated_arg, "preallocated as a call site attribute can only be on llvm.call.preallocated.arg");
    vcheck(!attr_set_has(fns, .DenormalFPEnv), "denormal_fpenv attribute may not apply to call sites", vq_val(call));
    is_inline_asm := vkind(callee) == .INLINE_ASM;
    // verifyFunctionAttrs depends on the call only for its messages: a (list, type, kind) that passed once passes again
    akey := (cast(u64) attrs << 34) | (cast(u64) fty << 2) | (ifx is_intrinsic then cast(u64) 1 else 0) | (ifx is_inline_asm then cast(u64) 2 else 0);
    if attrs != 0 && !table_contains(*vf.attrs_ok, akey) {
        before := vf.fail_count;
        vf_verify_function_attrs(fty, attrs, call, is_intrinsic, is_inline_asm);
        if vf.fail_count == before table_add(*vf.attrs_ok, akey, true);
    }
    // hasInAllocaArgument: the last parameter has inalloca
    if np > 0 && attr_set_has(attr_list_param(attrs, np - 1), .InAlloca) {
        a := sv_strip_in_bounds_offsets(op(call, np - 1));
        if is_inst(a) && inst_op(a) == .ALLOCA vcheck((inst(a).flags & F_INALLOCA) != 0, "inalloca argument for call has mismatched alloca", vq_val(a), vq_val(call));
    }
    for k: 0..cast(s64) np - 1 {
        ku := cast(u32) k;
        if vf_call_param_has_attr(call, ku, .SwiftError) {
            sea := op(call, ku);
            a := sv_strip_in_bounds_offsets(sea);
            if is_inst(a) && inst_op(a) == .ALLOCA {
                vcheck((inst(a).flags & F_SWIFTERR) != 0, "swifterror argument for call has mismatched alloca", vq_val(a), vq_val(call));
                continue;
            }
            vcheck(vkind(sea) == .ARGUMENT, "swifterror argument should come from an alloca or parameter", vq_val(sea), vq_val(call));
            vcheck(arg_has_attr(sea, .SwiftError), "swifterror argument for call has mismatched parameter", vq_val(sea), vq_val(call));
        }
        if attr_set_has(attr_list_param(attrs, ku), .ImmArg)
            vcheck(callee_fn != NONE && attr_set_has(attr_list_param(glob(callee_fn).attrs, ku), .ImmArg), "immarg may not apply only to call sites", vq_val(op(call, ku)), vq_val(call));
        if vf_call_param_has_attr(call, ku, .ImmArg) {
            av := op(call, ku);
            vcheck((vkind(av) == .C_INT || vkind(av) == .C_FP) && !is_vector_type(vtype(av)), "immarg operand has non-immediate parameter", vq_val(av), vq_val(call));
            if vf_call_param_has_attr(call, ku, .Range) && vkind(av) == .C_INT {
                ra := call_param_attr(call, ku, .Range);
                cr := attr_range(ra);
                v := const_ap(av);
                vcheck(cr_contains(cr, v), tprint("immarg value % for arg % out of range [%,%)", ap_to_string_signed(v), k, ap_to_string_signed(cr.lo), ap_to_string_signed(cr.hi)), vq_val(call));
            }
        }
        if vf_call_param_has_attr(call, ku, .Preallocated) {
            av := op(call, ku);
            has_ob := vf_bundle_count(call, "preallocated") != 0;
            is_mt := r.op == .CALL && ((r.flags >> TAIL_SHIFT) & 3) == 2;
            vcheck(has_ob != is_mt, "preallocated operand either requires a preallocated bundle or the call to be musttail (but not both)", vq_val(av), vq_val(call));
        }
    }
    if func_vararg(fty) {
        saw_nest := false; saw_returned := false;
        for k: 0..cast(s64) np - 1 {
            if attr_set_has(attr_list_param(attrs, cast(u32) k), .Nest) saw_nest = true;
            if attr_set_has(attr_list_param(attrs, cast(u32) k), .Returned) saw_returned = true;
        }
        for k: cast(s64) np..cast(s64) na - 1 {
            ty := vtype(op(call, cast(u32) k));
            pa := attr_list_param(attrs, cast(u32) k);
            vf_verify_parameter_attrs(pa, ty, call);
            if attr_set_has(pa, .Nest) { vcheck(!saw_nest, "More than one parameter has attribute nest!", vq_val(call)); saw_nest = true; }
            if attr_set_has(pa, .Returned) {
                vcheck(!saw_returned, "More than one parameter has attribute returned!", vq_val(call));
                vcheck(vf_can_losslessly_bitcast(ty, func_ret(fty)), "Incompatible argument and return types for 'returned' attribute", vq_val(call));
                saw_returned = true;
            }
            if iid != VI_experimental_gc_statepoint vcheck(!attr_set_has(pa, .StructRet), "Attribute 'sret' cannot be used for vararg call arguments!", vq_val(call));
            if attr_set_has(pa, .InAlloca) vcheck(k == na - 1, "inalloca isn't on the last argument!", vq_val(call));
        }
    }
    if !is_intrinsic {
        for k: 0..cast(s64) np - 1 {
            pt := func_param(fty, cast(u32) k);
            vcheck(type_kind(pt) != .METADATA, "Function has metadata parameter but isn't an intrinsic", vq_val(call));
            vcheck(!type_is_token_like(pt), "Function has token parameter but isn't an intrinsic", vq_val(call));
        }
    }
    if called == NONE {
        vcheck(!type_is_token_like(func_ret(fty)), "Return type cannot be token for indirect call!");
        vcheck(type_kind(func_ret(fty)) != .X86_AMX, "Return type cannot be x86_amx for indirect call!");
    }
    if iid != NOT_INTRINSIC {
        vf_visit_intrinsic_call(iid, call);
    }
    found_deopt, found_funclet, found_gct, found_cfg, found_prealloc, found_gclive, found_ptrauth, found_kcfi, found_attached := false;
    nb := call_num_bundles(call);
    for k: 0..cast(s64) nb - 1 {
        tag := call_bundle_tag(call, cast(u32) k);
        b, e := vf_bundle_inputs(call, cast(u32) k);
        n := e - b;
        if tag == "deopt" {
            vcheck(!found_deopt, "Multiple deopt operand bundles", vq_val(call)); found_deopt = true;
        } else if tag == "gc-transition" {
            vcheck(!found_gct, "Multiple gc-transition operand bundles", vq_val(call)); found_gct = true;
        } else if tag == "funclet" {
            vcheck(!found_funclet, "Multiple funclet operand bundles", vq_val(call)); found_funclet = true;
            vcheck(n == 1, "Expected exactly one funclet bundle operand", vq_val(call));
            vcheck(is_funclet_pad(op(call, b)), "Funclet bundle operands should correspond to a FuncletPadInst", vq_val(call));
        } else if tag == "cfguardtarget" {
            vcheck(!found_cfg, "Multiple CFGuardTarget operand bundles", vq_val(call)); found_cfg = true;
            vcheck(n == 1, "Expected exactly one cfguardtarget bundle operand", vq_val(call));
        } else if tag == "ptrauth" {
            vcheck(!found_ptrauth, "Multiple ptrauth operand bundles", vq_val(call)); found_ptrauth = true;
            vcheck(n == 2, "Expected exactly two ptrauth bundle operands", vq_val(call));
            k0 := op(call, b);
            vcheck(vkind(k0) == .C_INT && type_int_width(vtype(k0)) == 32, "Ptrauth bundle key operand must be an i32 constant", vq_val(call));
            d := vtype(op(call, b + 1));
            vcheck(is_int_type(d) && type_int_width(d) == 64, "Ptrauth bundle discriminator operand must be an i64", vq_val(call));
        } else if tag == "kcfi" {
            vcheck(!found_kcfi, "Multiple kcfi operand bundles", vq_val(call)); found_kcfi = true;
            vcheck(n == 1, "Expected exactly one kcfi bundle operand", vq_val(call));
            k0 := op(call, b);
            vcheck(vkind(k0) == .C_INT && type_int_width(vtype(k0)) == 32, "Kcfi bundle operand must be an i32 constant", vq_val(call));
        } else if tag == "preallocated" {
            vcheck(!found_prealloc, "Multiple preallocated operand bundles", vq_val(call)); found_prealloc = true;
            vcheck(n == 1, "Expected exactly one preallocated bundle operand", vq_val(call));
            inp := op(call, b);
            vcheck(is_inst(inp) && is_call_base(inp) && vf_intrinsic_inst_iid(inp) == VI_call_preallocated_setup,
                "\"preallocated\" argument must be a token from llvm.call.preallocated.setup", vq_val(call));
        } else if tag == "gc-live" {
            vcheck(!found_gclive, "Multiple gc-live operand bundles", vq_val(call)); found_gclive = true;
        } else if tag == "clang.arc.attachedcall" {
            vcheck(!found_attached, "Multiple \"clang.arc.attachedcall\" operand bundles", vq_val(call)); found_attached = true;
            vf_verify_attached_call_bundle(call, b, e);
        }
    }
    vcheck(!(called != NONE && found_ptrauth), "Direct call cannot have a ptrauth bundle", vq_val(call));
    f := block(r.parent).parent;
    if called != NONE && vf_fn_subprogram(f) != NONE && !gv_is_interposable(called) && !is_declaration(called) && vf_fn_subprogram(called) != NONE
        vcheck_di(get_metadata(call, 0) != NONE, "inlinable function call in a function with debug info must have a !dbg location", vq_val(call));
    if is_inline_asm vf_verify_inline_asm_call(call);
    vf_conv_visit(call);
    vf_visit_instruction(call);
}

// Function::getSubprogram
vf_fn_subprogram :: (f: Value_Id) -> Md_Id {
    m := get_metadata(f, 0);
    if is_di(m, .SUBPROGRAM) return m;
    return NONE;
}

// CallBase::getIntrinsicID: the intrinsic of the callee operand (even if the call's type differs)
intrinsic_id_of_call_iid :: (c: Value_Id) -> Intrinsic_Id {
    f := call_called_operand_fn(c);
    if f == NONE return NOT_INTRINSIC;
    return vf_iid(f);
}
// isa<IntrinsicInst> / isa<GCRelocateInst> ...: a call whose getCalledFunction() (callee of the call's type) is an
// intrinsic, and its id
vf_intrinsic_inst_iid :: (c: Value_Id, any_call_base := false) -> Intrinsic_Id {
    if !is_inst(c) || !is_call_base(c) || (!any_call_base && inst_op(c) != .CALL) return NOT_INTRINSIC;
    f := call_called_function(c);
    if f == NONE return NOT_INTRINSIC;
    return vf_iid(f);
}

// Function::getIntrinsicID, cached per value id for the run (the name lookup is the expensive part)
vf_iid :: (f: Value_Id) -> Intrinsic_Id {
    if vkind(f) != .FUNCTION || !glob(f).intrinsic return NOT_INTRINSIC;
    if f < vf.iid_cache.count && vf.iid_cache[f] != -1 return vf.iid_cache[f];
    while vf.iid_cache.count <= f array_add(*vf.iid_cache, -1);
    id := function_intrinsic_id(f);
    vf.iid_cache[f] = id;
    return id;
}

vf_verify_type_align :: (ty: Type_Id, what: string, call: Value_Id) {
    if !vf_type_is_sized(ty) return;
    al := dl_abi_align(ty);
    if !(al <= MAXIMUM_ALIGNMENT) check_failed(tprint("Incorrect alignment of % to called function!", what), vq_val(call));
}

vf_verify_attached_call_bundle :: (call: Value_Id, b: u32, e: u32) {
    fty := inst(call).ty2;
    rt := func_ret(fty);
    vcheck(is_ptr_type(rt) || (call_has_fn_attr(call, .NoReturn) && type_kind(rt) == .VOID),
        "a call with operand bundle \"clang.arc.attachedcall\" must call a function returning a pointer or a non-returning function that has a void return type", vq_val(call));
    vcheck(e - b == 1 && vkind(op(call, b)) == .FUNCTION, "operand bundle \"clang.arc.attachedcall\" requires one function as an argument", vq_val(call));
    fnv := op(call, b);
    iid := vf_iid(fnv);
    if iid != NOT_INTRINSIC {
        vcheck(iid == VI_objc_retainAutoreleasedReturnValue || iid == VI_objc_claimAutoreleasedReturnValue || iid == VI_objc_unsafeClaimAutoreleasedReturnValue, "invalid function argument", vq_val(call));
    } else {
        n := vname(fnv);
        vcheck(n == "objc_retainAutoreleasedReturnValue" || n == "objc_claimAutoreleasedReturnValue" || n == "objc_unsafeClaimAutoreleasedReturnValue", "invalid function argument", vq_val(call));
    }
}

// getParameterABIAttributes: the ABI-affecting attributes of parameter I (sorted, so they compare as sets)
vf_param_abi_attrs :: (attrs: u32, i: u32) -> [..] Attr {
    out: [..] Attr; out.allocator = temp;
    pa := attr_list_param(attrs, i);
    for k: Attr_Kind.[.StructRet, .ByVal, .InAlloca, .InReg, .StackAlignment, .SwiftSelf, .SwiftAsync, .SwiftError, .Preallocated, .ByRef] {
        a := attr_set_find(pa, k);
        if a array_add(*out, a.*);
    }
    al := attr_set_find(pa, .Alignment);
    if al && (attr_set_has(pa, .ByVal) || attr_set_has(pa, .ByRef)) array_add(*out, al.*);
    return out;
}
vf_attrs_equal :: (a: [] Attr, b: [] Attr) -> bool {
    if a.count != b.count return false;
    for x: a {
        found := false;
        for y: b if x.kind == y.kind && x.ival == y.ival && x.ty == y.ty { found = true; break; }
        if !found return false;
    }
    return true;
}

vf_verify_tail_cc_must_tail_attrs :: (abi: [] Attr, ctx: string) {
    has :: (k: Attr_Kind) -> bool #expand { for `abi if it.kind == k return true; return false; }
    vcheck(!has(.InAlloca), tprint("inalloca attribute not allowed in %", ctx));
    vcheck(!has(.InReg), tprint("inreg attribute not allowed in %", ctx));
    vcheck(!has(.SwiftError), tprint("swifterror attribute not allowed in %", ctx));
    vcheck(!has(.Preallocated), tprint("preallocated attribute not allowed in %", ctx));
    vcheck(!has(.ByRef), tprint("byref attribute not allowed in %", ctx));
}

vf_verify_must_tail_call :: (ci: Value_Id) {
    vcheck(vkind(call_callee(ci)) != .INLINE_ASM, "cannot use musttail call with inline asm", vq_val(ci));
    f := block(inst(ci).parent).parent;
    caller_ty := glob(f).value_type;
    callee_ty := inst(ci).ty2;
    vcheck(func_vararg(caller_ty) == func_vararg(callee_ty), "cannot guarantee tail call due to mismatched varargs", vq_val(ci));
    vcheck(func_ret(caller_ty) == func_ret(callee_ty), "cannot guarantee tail call due to mismatched return types", vq_val(ci));
    vcheck(glob(f).cc == inst(ci).cc, "cannot guarantee tail call due to mismatched calling conv", vq_val(ci));
    next := inst(ci).next;
    vcheck(next != NONE && inst_op(next) == .RET, "musttail call must precede a ret", vq_val(ci));
    rv := ifx nops(next) > 0 then op(next, 0) else NONE;
    vcheck(rv == NONE || rv == ci || vkind(rv) == .C_UNDEF || vkind(rv) == .C_POISON, "musttail call result must be returned", vq_val(next));
    caller_attrs := glob(f).attrs;
    callee_attrs := inst(ci).attrs;
    cc := inst(ci).cc;
    if cc == VCC_SWIFTTAIL || cc == VCC_TAIL {
        name := ifx cc == VCC_TAIL then "tailcc" else "swifttailcc";
        for k: 0..cast(s64) func_nparams(caller_ty) - 1 {
            vf_verify_tail_cc_must_tail_attrs(vf_param_abi_attrs(caller_attrs, cast(u32) k), tprint("% musttail caller", name));
        }
        for k: 0..cast(s64) func_nparams(callee_ty) - 1 {
            vf_verify_tail_cc_must_tail_attrs(vf_param_abi_attrs(callee_attrs, cast(u32) k), tprint("% musttail callee", name));
        }
        vcheck(!func_vararg(caller_ty), tprint("cannot guarantee % tail call for varargs function", name));
        return;
    }
    if intrinsic_id_of_call_iid(ci) == NOT_INTRINSIC {
        vcheck(func_nparams(caller_ty) == func_nparams(callee_ty), "cannot guarantee tail call due to mismatched parameter counts", vq_val(ci));
        for k: 0..cast(s64) func_nparams(caller_ty) - 1
            vcheck(func_param(caller_ty, cast(u32) k) == func_param(callee_ty, cast(u32) k), "cannot guarantee tail call due to mismatched parameter types", vq_val(ci));
    }
    for k: 0..cast(s64) func_nparams(caller_ty) - 1 {
        a := vf_param_abi_attrs(caller_attrs, cast(u32) k);
        b := vf_param_abi_attrs(callee_attrs, cast(u32) k);
        vcheck(vf_attrs_equal(a, b), "cannot guarantee tail call due to mismatched ABI impacting function attributes", vq_val(ci), vq_val(op(ci, cast(u32) k)));
    }
}

// InlineAsm::ParseConstraints, the parts the verifier reads: type (0 input, 1 output, 2 clobber, 3 label) and
// indirection per constraint; an unparsable string gives no constraints
Asm_Constraint :: struct { kind: u8; indirect: bool; }
vf_parse_asm_constraints :: (s: string) -> [..] Asm_Constraint {
    out: [..] Asm_Constraint; out.allocator = temp;
    if s.count == 0 return out;
    parts := split(s, ",",, allocator = temp);
    for p: parts {
        if p.count == 0 { out.count = 0; return out; }
        c: Asm_Constraint;
        i := 0;
        if p[0] == #char "~" { c.kind = 2; i = 1; }
        else if p[0] == #char "=" { c.kind = 1; i = 1; }
        else if p[0] == #char "!" { c.kind = 3; i = 1; }
        if i < p.count && p[i] == #char "*" { c.indirect = true; i += 1; }
        if i >= p.count { out.count = 0; return out; }
        array_add(*out, c);
    }
    return out;
}

vf_verify_inline_asm_call :: (call: Value_Id) {
    a := inline_asms[ir.v_aux[call_callee(call)]];
    argno: u32 = 0;
    labelno: u32 = 0;
    for c: vf_parse_asm_constraints(a.constraints) {
        if c.kind == 3 { labelno += 1; continue; }
        has_arg := c.kind == 0 || (c.kind == 1 && c.indirect);
        if !has_arg continue;
        if c.indirect {
            arg := op(call, argno);
            vcheck(is_ptr_type(vtype(arg)), "Operand for indirect constraint must have pointer type", vq_val(call));
            vcheck(attr_set_find(attr_list_param(inst(call).attrs, argno), .ElementType) != null, "Operand for indirect constraint must have elementtype attribute", vq_val(call));
        } else {
            vcheck(!vf_call_param_has_attr(call, argno, .ElementType), "Elementtype attribute can only be applied for indirect constraints", vq_val(call));
        }
        argno += 1;
    }
    if inst_op(call) == .CALLBR vcheck(labelno == inst(call).addrspace, "Number of label constraints does not match number of callbr dests", vq_val(call));
    else vcheck(labelno == 0, "Label constraints can only be used with callbr", vq_val(call));
}
