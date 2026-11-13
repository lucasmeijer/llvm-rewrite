// Early lowering passes of llc's IR pipeline:
//   PreISelIntrinsicLowering   llvm/lib/CodeGen/PreISelIntrinsicLowering.cpp (lowerIntrinsics with the memory
//                              intrinsics (lower_mem_intrinsics.jai), memset.pattern, VP (vp_expand.jai) and ObjC
//                              ARC lowerings; the scalable-vector math loops, ptrauth and protected-field expansions
//                              are not ported and fail loudly where LLVM would expand)
//   ExpandIRInsts (guard)      llvm/lib/CodeGen/ExpandIRInsts.cpp: on x86-64 only integer div/rem and int<->fp
//                              conversions wider than 128 bits are expanded (frem is a libcall); those fail loudly
//   AtomicExpand               atomic_expand.jai (this file keeps the idempotent-RMW lowering and the guards)

// ---------------------------------------------------------------- PreISelIntrinsicLowering

pil_cl: struct { mem_intrinsic_expand_size: s64 = -1; mem_intrinsic_expand_size_given: bool; }

// forEachCall(Intrin, Callback): walk the uses of an intrinsic declaration, revisiting from the last kept use
pil_for_each_call :: (fn_v: Value_Id, callback: (ci: Value_Id) -> bool) -> bool {
    last_use: Use_Id = NONE;
    changed := false;
    while has_uses(fn_v) && (last_use == NONE || ir.u_next[last_use] != NONE) {
        u := ifx last_use != NONE then ir.u_next[last_use] else ir.v_first_use[fn_v];
        removed := false;
        user := ir.u_user[u];
        if is_inst(user) && inst_op(user) == .CALL { removed = callback(user); changed |= removed; }
        if !removed last_use = u;
    }
    return changed;
}

// lowerLoadRelative
pil_lower_load_relative :: (fn_v: Value_Id) -> bool {
    if !has_uses(fn_v) return false;
    changed := false;
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[fn_v];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for uu: uses {   // make_early_inc_range(F.uses())
        ci := ir.u_user[uu];
        if !is_inst(ci) || inst_op(ci) != .CALL || call_callee(ci) != fn_v continue;
        b: Irb;
        irb_set_before(*b, ci);
        i8 := type_int(8);
        offset_ptr := irb_gep(*b, i8, call_arg(ci, 0), .[call_arg(ci, 1)]);
        offset_i32 := irb_load(*b, type_int(32), offset_ptr, 4);
        result_ptr := irb_gep(*b, i8, call_arg(ci, 0), .[offset_i32]);
        replace_all_uses_with(ci, result_ptr);
        erase_inst(ci);
        changed = true;
    }
    return changed;
}

pil_lower_constant_intrinsic_call :: (ci: Value_Id) -> bool {
    // lowerConstantIntrinsics(*Parent, TLI, /*DT=*/nullptr)
    f := inst_fn(ci);
    pa := lower_constant_intrinsics_run(f, use_cached_dt = false);
    changed := !pa.all;
    if changed fam_invalidate(f, PRESERVE_NONE);
    return changed;
}

// expandMemIntrinsicUses for llvm.memcpy.inline / llvm.memset.inline (only non-constant lengths are expanded) and
// llvm.experimental.memset.pattern (memset_pattern16 where the target has it, else a loop)
pil_expand_mem_intrinsic_uses :: (f: Value_Id, id: Intrinsic_Id, cmap: *Table(Value_Id, Value_Id)) -> bool {
    changed := false;
    users: [..] Value_Id; users.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
    for mi: users {
        if !is_inst(mi) fatal("pre-isel-intrinsic-lowering: a non-call use of %", vname(f));
        if id == IID_MEMCPY_INLINE {
            if vkind(call_arg(mi, 2)) == .C_INT continue;
            lmi_expand_memcpy_unknown_size(mi);
            erase_inst(mi);
            changed = true;
        } else if id == IID_MEMSET_INLINE {
            if vkind(call_arg(mi, 2)) == .C_INT continue;
            lmi_expand_memset_unknown_size(mi);
            erase_inst(mi);
            changed = true;
        } else {
            t := tli_for(inst_fn(mi));
            pattern := pil_memset_pattern16_value(mi, t);
            if pattern == NONE {
                lmi_expand_memset_pattern(mi);
                erase_inst(mi);
                changed = true;
                continue;
            }
            b: Irb; irb_set_before(*b, mi);
            dest := call_arg(mi, 0);
            size_t := type_int(tli_size_t_bits());
            msp := get_or_insert_lib_func_types(t, .memset_pattern16, 0, ir.t_void, vtype(dest), ir.t_ptr, size_t);
            infer_non_mandatory_lib_func_attrs_name("memset_pattern16", t);
            found, gv := table_find(cmap, pattern);
            if !found {
                gv = gv_create(vtype(pattern), true, .PRIVATE, pattern, ".memset_pattern", NONE, 0, 0);
                glob(gv).unnamed_addr = 2;
                glob(gv).align = 16;
                table_set(cmap, pattern, gv);
            }
            len := call_arg(mi, 2);
            lz := irb_zext_or_trunc(*b, len, size_t);
            nbytes := irb_binop(*b, .MUL, const_int(size_t, dl_type_alloc_size(vtype(call_arg(mi, 1)))), lz);
            call := irb_call(*b, msp, .[dest, gv, nbytes]);
            set_aa_metadata(call, get_aa_metadata(mi));
            ps := attr_list_param(inst(mi).attrs, 0);
            if ps != 0 inst(call).attrs = attr_list_with_param(inst(call).attrs, 0, attr_set_merge(attr_list_param(inst(call).attrs, 0), ps));
            erase_inst(mi);
            changed = true;
        }
    }
    return changed;
}
// getMemSetPattern16Value
pil_memset_pattern16_value :: (mi: Value_Id, t: *Tli) -> Value_Id {
    if ptr_addrspace(vtype(call_arg(mi, 0))) != 0 return NONE;
    v := call_arg(mi, 1);
    vt := vtype(v);
    if !is_lib_func_emittable(t, .memset_pattern16) return NONE;
    k := vkind(v);
    if !is_constant_kind(k) || k == .C_EXPR return NONE;
    size := dl_type_size_bits(vt);
    if size != dl_type_store_size(vt) * 8 || (size & (size - 1)) != 0 || size == 0 return NONE;
    size /= 8;
    if size > 16 return NONE;
    if size == 16 return v;
    n := 16 / size;
    elts := NewArray(cast(s64) n, Value_Id,, temp);
    for * elts it.* = v;
    return const_array_of(type_array(n, vt), elts);
}

// The RTLIB::impl_objc_* runtime function of an llvm.objc.* intrinsic lowered by lowerIntrinsics, and whether it
// gets nonlazybind ("" for llvm.objc.clang.arc.use and the annotations, which are left alone)
pil_objc_runtime_function :: (name: string) -> (string, bool) {
    if name == {
        case "llvm.objc.autorelease"; return "objc_autorelease", false;
        case "llvm.objc.autoreleasePoolPop"; return "objc_autoreleasePoolPop", false;
        case "llvm.objc.autoreleasePoolPush"; return "objc_autoreleasePoolPush", false;
        case "llvm.objc.autoreleaseReturnValue"; return "objc_autoreleaseReturnValue", false;
        case "llvm.objc.copyWeak"; return "objc_copyWeak", false;
        case "llvm.objc.destroyWeak"; return "objc_destroyWeak", false;
        case "llvm.objc.initWeak"; return "objc_initWeak", false;
        case "llvm.objc.loadWeak"; return "objc_loadWeak", false;
        case "llvm.objc.loadWeakRetained"; return "objc_loadWeakRetained", false;
        case "llvm.objc.moveWeak"; return "objc_moveWeak", false;
        case "llvm.objc.release"; return "objc_release", true;
        case "llvm.objc.retain"; return "objc_retain", true;
        case "llvm.objc.retainAutorelease"; return "objc_retainAutorelease", false;
        case "llvm.objc.retainAutoreleaseReturnValue"; return "objc_retainAutoreleaseReturnValue", false;
        case "llvm.objc.retainAutoreleasedReturnValue"; return "objc_retainAutoreleasedReturnValue", false;
        case "llvm.objc.claimAutoreleasedReturnValue"; return "objc_claimAutoreleasedReturnValue", false;
        case "llvm.objc.retainBlock"; return "objc_retainBlock", false;
        case "llvm.objc.storeStrong"; return "objc_storeStrong", false;
        case "llvm.objc.storeWeak"; return "objc_storeWeak", false;
        case "llvm.objc.unsafeClaimAutoreleasedReturnValue"; return "objc_unsafeClaimAutoreleasedReturnValue", false;
        case "llvm.objc.retainedObject"; return "objc_retainedObject", false;
        case "llvm.objc.unretainedObject"; return "objc_unretainedObject", false;
        case "llvm.objc.unretainedPointer"; return "objc_unretainedPointer", false;
        case "llvm.objc.retain.autorelease"; return "objc_retain_autorelease", false;
        case "llvm.objc.sync.enter"; return "objc_sync_enter", false;
        case "llvm.objc.sync.exit"; return "objc_sync_exit", false;
    }
    return "", false;
}
// getOverridingTailCallKind: objcarc::GetFunctionClass, then IsAlwaysTail (tail) / IsNeverTail (notail)
pil_objc_overriding_tail_kind :: (name: string) -> u32 {
    if name == "llvm.objc.retain" || name == "llvm.objc.retainAutoreleasedReturnValue" ||
       name == "llvm.objc.unsafeClaimAutoreleasedReturnValue" || name == "llvm.objc.autoreleaseReturnValue" return 1;
    if name == "llvm.objc.autorelease" return 3;
    return 0;
}
// lowerObjCCall
pil_lower_objc_call :: (f: Value_Id, new_name: string, set_non_lazy_bind: bool, name: string) -> bool {
    if !has_uses(f) return false;
    ft := glob(f).value_type;
    nf := module_get_or_insert_function(new_name, ft);
    if vkind(nf) == .FUNCTION {
        gv_set_linkage(nf, glob(f).linkage);
        if set_non_lazy_bind && !gv_is_weak_for_linker(nf) fn_add_fn_attr_kind(nf, .NonLazyBind);
    }
    otck := pil_objc_overriding_tail_kind(name);
    returned_idx := -1;
    for k: 0..cast(s64) fn_nargs(f) - 1 if arg_has_attr(fn_arg(f, cast(u32) k), .Returned) { returned_idx = k; break; }
    uses: [..] Use_Id; uses.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { array_add(*uses, u); u = ir.u_next[u]; }
    for uu: uses {
        cb := ir.u_user[uu];
        if !is_inst(cb) || !is_call_base(cb) fatal("pre-isel-intrinsic-lowering: a non-call use of %", name);
        if call_called_function(cb) != f {
            // the argument of a "clang.arc.attachedcall" operand bundle
            use_set(uu, nf);
            continue;
        }
        if inst_op(cb) != .CALL fatal("pre-isel-intrinsic-lowering: an invoke of % is not supported", name);
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) call_num_args(cb) - 1 array_add(*args, call_arg(cb, cast(u32) k));
        nc := ipo_create_call_like(cb, ft, nf, args, cb);
        if vname(cb).count set_name(nc, vname(cb));
        tck := call_tail_kind(cb);
        call_set_tail_kind(nc, max(tck, otck));
        if returned_idx >= 0 add_param_attr_kind_call(nc, cast(u32) returned_idx, .Returned);
        if has_uses(cb) replace_all_uses_with(cb, nc);
        erase_inst(cb);
    }
    return true;
}
add_param_attr_kind_call :: (c: Value_Id, k: u32, kind: Attr_Kind) {
    l := inst(c).attrs;
    inst(c).attrs = attr_list_with_param(l, k, attr_set_add_kind(attr_list_param(l, k), kind));
}

// expandVectorPredicationIntrinsic through forEachCall: Changed tracks any IR change, the result whether the call was
// replaced
pil_vp_changed: bool;
pil_expand_vp_call :: (ci: Value_Id) -> bool {
    changed, removed := vp_expand_vector_predication(ci);
    pil_vp_changed |= changed;
    return removed;
}

// PreISelIntrinsicLowering::lowerIntrinsics (module pass)
pre_isel_intrinsic_lowering_run :: () -> bool {
    changed := false;
    pattern_globals: Table(Value_Id, Value_Id); pattern_globals.allocator = temp;   // CMap
    fns: [..] Value_Id; fns.allocator = temp;
    for ir.m_functions array_add(*fns, it);
    for f: fns {
        if vkind(f) != .FUNCTION continue;
        id := fn_iid(f);
        if id == NOT_INTRINSIC continue;
        name := iid_name(id);
        if id == IID_MEMCPY || id == IID_MEMMOVE || id == IID_MEMSET {
            // shouldExpandMemIntrinsicWithSize, then canEmitMemcpy / canEmitLibcall: x86-64 Linux has memcpy,
            // memmove and memset, so every call that should be expanded is left for the libcall
            continue;
        }
        if id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE || id == IID_EXPERIMENTAL_MEMSET_PATTERN {
            changed |= pil_expand_mem_intrinsic_uses(f, id, *pattern_globals);
            continue;
        }
        if id == IID_LOAD_RELATIVE { changed |= pil_lower_load_relative(f); continue; }
        if id == IID_IS_CONSTANT || id == IID_OBJECTSIZE {
            changed |= pil_for_each_call(f, pil_lower_constant_intrinsic_call);
            continue;
        }
        if begins_with(name, "llvm.vp.") || begins_with(name, "llvm.experimental.vp.") {
            pil_vp_changed = false;
            pil_for_each_call(f, pil_expand_vp_call);
            changed |= pil_vp_changed;
            continue;
        }
        if begins_with(name, "llvm.objc.") {
            lib, set_non_lazy_bind := pil_objc_runtime_function(name);
            if lib.count == 0 continue;   // llvm.objc.clang.arc.use / noop.use / the annotations are not lowered
            changed |= pil_lower_objc_call(f, lib, set_non_lazy_bind, name);
            continue;
        }
        if name == "llvm.acos" || name == "llvm.asin" || name == "llvm.atan" || name == "llvm.cos" || name == "llvm.cosh" ||
           name == "llvm.exp" || name == "llvm.exp2" || name == "llvm.exp10" || name == "llvm.log" || name == "llvm.log2" ||
           name == "llvm.log10" || name == "llvm.sin" || name == "llvm.sinh" || name == "llvm.tan" || name == "llvm.tanh" {
            // only scalable vectors are lowered as loops
            u := ir.v_first_use[f];
            while u != NONE {
                c := ir.u_user[u];
                if is_inst(c) && inst_op(c) == .CALL && type_kind(vtype(call_arg(c, 0))) == .SVECTOR
                    fatal("pre-isel-intrinsic-lowering: % on scalable vectors is not supported yet", name);
                u = ir.u_next[u];
            }
            continue;
        }
        if name == "llvm.ptrauth.sign" || name == "llvm.ptrauth.auth" || name == "llvm.protected.field.ptr" || name == "llvm.looptrap" {
            if has_uses(f) || name == "llvm.ptrauth.sign" || name == "llvm.ptrauth.auth" || name == "llvm.looptrap"
                fatal("pre-isel-intrinsic-lowering: % is not supported yet", name);
            continue;
        }
        // llvm.cond.loop: X86TargetMachine::canLowerCondLoop() is true, nothing to do
    }
    return changed;
}

// ---------------------------------------------------------------- ExpandIRInsts (guard)

expand_ir_insts_run :: (f: Value_Id) -> Preserved {
    // X86TargetLowering: setMaxDivRemBitWidthSupported(128) on x86-64, setMaxLargeFPConvertBitWidthSupported(128);
    // FREM is a libcall for every ExpandableTypes type, so DisableFrem.
    max_bits :: 128;
    for i: fn_insts(f) {
        o := inst_op(i);
        t := vtype(i);
        if type_kind(t) == .SVECTOR continue;
        st := ifx is_vector_type(t) then type_elem(t) else t;
        if o == .UDIV || o == .SDIV || o == .UREM || o == .SREM || o == .FPTOUI || o == .FPTOSI {
            if type_kind(st) == .INT && type_bits(st) > max_bits fatal("expand-ir-insts: expanding % on i% is not supported yet", opcode_name(o), type_bits(st));
        } else if o == .UITOFP || o == .SITOFP {
            s := vtype(op(i, 0));
            ss := ifx is_vector_type(s) then type_elem(s) else s;
            if type_bits(ss) > max_bits fatal("expand-ir-insts: expanding % from i% is not supported yet", opcode_name(o), type_bits(ss));
        } else if o == .CALL {
            id := call_iid(i);
            if (id == IID_FPTOUI_SAT || id == IID_FPTOSI_SAT) && type_kind(st) == .INT && type_bits(st) > max_bits
                fatal("expand-ir-insts: expanding % to i% is not supported yet", iid_name(id), type_bits(st));
        }
    }
    return PRESERVE_ALL;
}

// ---------------------------------------------------------------- AtomicExpand (guard)

ae_fail :: (i: Value_Id, what: string) {
    fatal("atomic-expand: % is not supported yet (in function '%')", what, vname(inst_fn(i)));
}

// getAtomicOpSize / atomicSizeSupported: x86-64 supports up to 16 bytes, naturally aligned
ae_size_supported :: (i: Value_Id, size: u64, align: u64) -> bool { return align >= size && size <= 16; }

AE_ORD_ACQ_REL :: 6; AE_ORD_SEQ_CST :: 7;
MDK_PCSECTIONS :: 37;
// X86TargetLowering::lowerIdempotentRMWIntoFencedLoad (llvm/lib/Target/X86/X86ISelLowering.cpp); the resulting
// atomic load needs no further expansion (tryExpandAtomicLoad: shouldExpandAtomicLoadInIR is None up to the
// native width)
ae_lower_idempotent_rmw_into_fenced_load :: (ai: Value_Id, st: *X86_Lowering) -> bool {
    native_width: u64 = ifx st_is64Bit(st) then cast(u64) 64 else 32;
    mem_ty := vtype(ai);
    if type_kind(mem_ty) != .INT || cast(u64) type_bits(mem_ty) > native_width return false;
    c := op(ai, 1);
    if vkind(c) == .C_INT && inst(ai).ord2 == RMW_OR && ap_is_zero(const_ap(c)) && !has_uses(ai) return false;
    ssid := inst(ai).sync;
    // AtomicCmpXchgInst::getStrongestFailureOrdering
    order := inst(ai).ord1;
    if order == ORD_RELEASE order = ORD_MONOTONIC;
    else if order == AE_ORD_ACQ_REL order = ORD_ACQUIRE;
    pcs := get_metadata(ai, MDK_PCSECTIONS);
    fence := new_inst(.FENCE, ir.t_void, 0);
    inst(fence).ord1 = AE_ORD_SEQ_CST; inst(fence).sync = ssid;
    insert_at_position(fence, inst_block(ai), ai, false);
    if pcs != NONE set_metadata(fence, MDK_PCSECTIONS, pcs);
    ld := new_inst(.LOAD, mem_ty, 1);
    set_op(ld, 0, op(ai, 0));
    inst(ld).align = inst(ai).align;
    inst(ld).ord1 = order; inst(ld).sync = ssid;
    insert_at_position(ld, inst_block(ai), ai, false);
    if pcs != NONE set_metadata(ld, MDK_PCSECTIONS, pcs);
    rauw_with_metadata(ai, ld);
    erase_inst_with_metadata(ai);
    return true;
}

// isIdempotentRMW (integer only: "TODO: Add floating point support")
ae_is_idempotent :: (i: Value_Id) -> bool {
    if is_volatile(i) return false;
    if vkind(op(i, 1)) != .C_INT return false;
    return ic_rmw_is_idempotent(i);
}

// getCmpArithCC != COND_INVALID needs the result's only user to be an icmp (possibly through one and/trunc-like
// instruction); being conservative: any atomicrmw with a single user that is an icmp, or whose single user has a
// single icmp user, fails loudly.
ae_cmp_arith_user :: (i: Value_Id) -> bool {
    if !has_one_use(i) return false;
    u := ir.u_user[ir.v_first_use[i]];
    if !is_inst(u) return false;
    if inst_op(u) == .ICMP return true;
    if !has_one_use(u) return false;
    u2 := ir.u_user[ir.v_first_use[u]];
    return is_inst(u2) && inst_op(u2) == .ICMP;
}
