// Early lowering passes of llc's IR pipeline:
//   PreISelIntrinsicLowering   llvm/lib/CodeGen/PreISelIntrinsicLowering.cpp (lowerIntrinsics; the memory-intrinsic,
//                              VP, ObjC, scalable-vector math, ptrauth, protected-field and memset.pattern
//                              expansions are not ported and fail loudly where LLVM would expand)
//   ExpandIRInsts (guard)      llvm/lib/CodeGen/ExpandIRInsts.cpp: on x86-64 only integer div/rem and int<->fp
//                              conversions wider than 128 bits are expanded (frem is a libcall); those fail loudly
//   AtomicExpand (guard)       llvm/lib/CodeGen/AtomicExpandPass.cpp with the X86TargetLowering hooks
//                              (X86ISelLowering.cpp shouldExpandAtomic*InIR): atomics LLVM leaves alone pass, every
//                              instruction it would rewrite fails loudly

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

// PreISelIntrinsicLowering::lowerIntrinsics (module pass)
pre_isel_intrinsic_lowering_run :: () -> bool {
    changed := false;
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
        if id == IID_MEMCPY_INLINE || id == IID_MEMSET_INLINE {
            u := ir.v_first_use[f];
            while u != NONE {
                c := ir.u_user[u];
                if is_inst(c) && vkind(call_arg(c, 2)) != .C_INT fatal("pre-isel-intrinsic-lowering: expanding % with a non-constant length is not supported yet", name);
                u = ir.u_next[u];
            }
            continue;
        }
        if id == IID_EXPERIMENTAL_MEMSET_PATTERN {
            if has_uses(f) fatal("pre-isel-intrinsic-lowering: llvm.experimental.memset.pattern is not supported yet");
            continue;
        }
        if id == IID_LOAD_RELATIVE { changed |= pil_lower_load_relative(f); continue; }
        if id == IID_IS_CONSTANT || id == IID_OBJECTSIZE {
            changed |= pil_for_each_call(f, pil_lower_constant_intrinsic_call);
            continue;
        }
        if begins_with(name, "llvm.vp.") || begins_with(name, "llvm.experimental.vp.") {
            if has_uses(f) fatal("pre-isel-intrinsic-lowering: vector-predication intrinsics (%) are not supported yet", name);
            continue;
        }
        if begins_with(name, "llvm.objc.") {
            if has_uses(f) fatal("pre-isel-intrinsic-lowering: ObjC ARC intrinsics (%) are not supported yet", name);
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

atomic_expand_run :: (f: Value_Id) -> Preserved {
    t := tti_get(f);
    cx16 := t.kind == .X86 && st_canUseCMPXCHG16B(*t.xl);
    avx := t.kind == .X86 && st_hasAVX(*t.xl);
    noimplicitfloat := fn_has_fn_attr(f, .NoImplicitFloat);
    changed := false;
    insts: [..] Value_Id; insts.allocator = temp;
    for i: fn_insts(f) array_add(*insts, i);
    for i: insts {
        o := inst_op(i);
        if o == .LOAD || o == .STORE {
            if !inst_is_atomic(i) continue;
            ty := ifx o == .LOAD then vtype(i) else vtype(op(i, 0));
            size := dl_type_store_size(ty);
            if !ae_size_supported(i, size, inst(i).align) ae_fail(i, "an atomic access of an unsupported size or alignment (libcall)");
            if is_fp_type(ty) ae_fail(i, "an atomic floating-point load/store (cast to integer)");
            bits := dl_type_size_bits(ty);
            if bits == 128 && !(avx && !noimplicitfloat) && cx16 ae_fail(i, "a 128-bit atomic load/store (cmpxchg16b)");
        } else if o == .ATOMICRMW {
            ty := vtype(i);
            size := dl_type_store_size(ty);
            if !ae_size_supported(i, size, inst(i).align) ae_fail(i, "an atomicrmw of an unsupported size or alignment (libcall)");
            rop := inst(i).ord2;
            vt := vtype(op(i, 1));
            if rop == RMW_XCHG && (is_fp_type(vt) || type_kind(vt) == .PTR) ae_fail(i, "a floating-point / pointer atomicrmw xchg (cast to integer)");
            if ae_is_idempotent(i) && t.kind == .X86 && ae_lower_idempotent_rmw_into_fenced_load(i, *t.xl) { changed = true; continue; }
            if dl_type_size_bits(ty) > 64 { if cx16 ae_fail(i, "a 128-bit atomicrmw (cmpxchg16b loop)"); continue; }
            if rop == {
                case RMW_XCHG;
                case RMW_ADD; #through;
                case RMW_SUB;
                    if ae_cmp_arith_user(i) ae_fail(i, "an atomicrmw whose result is only compared (x86 cc intrinsic)");
                case RMW_OR; #through;
                case RMW_AND; #through;
                case RMW_XOR;
                    if ae_cmp_arith_user(i) ae_fail(i, "an atomicrmw whose result is only compared (x86 cc intrinsic)");
                    if !has_uses(i) continue;
                    if rop == RMW_XOR && vkind(op(i, 1)) == .C_INT && ap_is_sign_mask(const_ap(op(i, 1))) continue;
                    ae_fail(i, "an atomic or/and/xor with a used result (cmpxchg loop or bit-test intrinsic)");
                case;
                    ae_fail(i, "this atomicrmw operation (cmpxchg loop)");
            }
        } else if o == .CMPXCHG {
            ty := vtype(op(i, 1));
            size := dl_type_store_size(ty);
            if !ae_size_supported(i, size, inst(i).align) ae_fail(i, "a cmpxchg of an unsupported size or alignment (libcall)");
            if type_kind(ty) == .PTR ae_fail(i, "a pointer cmpxchg (cast to integer)");
        }
    }
    if changed return PRESERVE_NONE;
    return PRESERVE_ALL;
}

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
