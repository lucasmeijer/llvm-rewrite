// AtomicExpand: a port of llvm/lib/CodeGen/AtomicExpandPass.cpp (AtomicExpandImpl::run, processAtomicInstr,
// convertAtomicLoad/Store/Xchg/CmpXchgToIntegerType, tryExpandAtomicLoad/Store/RMW/CmpXchg,
// expandAtomicLoadToCmpXchg, expandAtomicStoreToXChg, insertRMWCmpXchgLoop with createCmpXchgInstFun,
// expandAtomicRMWToCmpXchg, expandAtomicOpToLibcall for loads, stores and cmpxchg) with the X86TargetLowering hooks
// of llvm/lib/Target/X86/X86ISelLowering.cpp (getMaxAtomicSizeInBitsSupported, needsCmpXchgNb,
// shouldExpandAtomicLoadInIR / StoreInIR / RMWInIR, lowerIdempotentRMWIntoFencedLoad in cg_lowering_passes.jai) and
// buildAtomicRMWValue from llvm/lib/Transforms/Utils/LowerAtomic.cpp.
//
// Not ported (fail loudly): the atomicrmw libcalls (__atomic_fetch_*), x86's bit-test and compare-arithmetic RMW
// intrinsics (emitBitTestAtomicRMWIntrinsic / emitCmpArithAtomicRMWIntrinsic), Windows' v2i64 i128 libcalls,
// !pcsections on an expanded instruction, strictfp FP RMW loops.

ae_ctx: struct {
    max_size: u64;       // getMaxAtomicSizeInBitsSupported / 8
    cx16: bool;          // canUseCMPXCHG16B
    avx_ok: bool;        // hasAVX && !NoImplicitFloat && !useSoftFloat (128-bit SSE accesses are atomic)
    st: *X86_Lowering;
};

// AtomicExpandPass::run (function pass) / AtomicExpandImpl::run
atomic_expand_run :: (f: Value_Id) -> Preserved {
    t := tti_get(f);
    if t.kind != .X86 return PRESERVE_ALL;
    ae_ctx.st = *t.xl;
    ae_ctx.cx16 = st_canUseCMPXCHG16B(*t.xl);
    ae_ctx.max_size = ifx ae_ctx.cx16 then cast(u64) 16 else 8;
    ae_ctx.avx_ok = st_hasAVX(*t.xl) && !fn_has_fn_attr(f, .NoImplicitFloat) && !st_useSoftFloat(*t.xl);
    changed := false;
    bb := fn_entry(f);
    while bb != NONE {
        i := block_last(bb);
        while i != NONE {
            prev := inst_prev(i);
            if ae_process(i) changed = true;
            i = prev;
        }
        bb = block(bb).next;
    }
    if changed { printer_note_ir_changed(); return PRESERVE_NONE; }
    return PRESERVE_ALL;
}

ae_op_size :: (i: Value_Id) -> u64 {
    o := inst_op(i);
    if o == .LOAD return dl_type_store_size(vtype(i));
    if o == .STORE || o == .ATOMICRMW return dl_type_store_size(vtype(op(i, 0 + ifx o == .ATOMICRMW then cast(u32) 1 else 0)));
    return dl_type_store_size(vtype(op(i, 1)));
}
ae_size_supported_x86 :: (i: Value_Id) -> bool {
    size := ae_op_size(i);
    return inst(i).align >= size && size <= ae_ctx.max_size;
}
// Type::getPrimitiveSizeInBits (0 for pointers and vectors of pointers)
ae_primitive_bits :: (t: Type_Id) -> u64 {
    if is_ptr_type(scalar_type(t)) return 0;
    return dl_type_size_bits(t);
}
// needsCmpXchgNb on x86-64
ae_needs_cmpxchg_nb :: (t: Type_Id) -> bool { return ae_primitive_bits(t) == 128 && ae_ctx.cx16; }
// ReplacementIRBuilder's inserter callback (addMD): every instruction it creates gets the replaced instruction's
// !pcsections, and !mmra when canInstructionHaveMMRAs. Instruction ids are allocated in increasing order, so
// ae_md_begin records a watermark and ae_md_end tags every live instruction created since.
Ae_Md :: struct { pcs: Md_Id = NONE; mmra: Md_Id = NONE; mark: Value_Id; }
ae_md_begin :: (i: Value_Id) -> Ae_Md {
    m: Ae_Md;
    m.pcs = get_metadata(i, MDK_PCSECTIONS);
    m.mmra = get_metadata(i, md_kind_id("mmra"));
    m.mark = cast(Value_Id) ir.v_kind.count;
    return m;
}
ae_md_end :: (m: *Ae_Md) {
    if m.pcs != NONE || m.mmra != NONE {
        k_mmra := md_kind_id("mmra");
        for v: m.mark..cast(Value_Id) ir.v_kind.count - 1 {
            if vkind(v) != .INST || inst(v).parent == NONE continue;
            o := inst_op(v);
            if m.mmra != NONE && (o == .LOAD || o == .STORE || o == .CMPXCHG || o == .ATOMICRMW || o == .FENCE)
                set_metadata(v, k_mmra, m.mmra);
            if m.pcs != NONE set_metadata(v, MDK_PCSECTIONS, m.pcs);
        }
    }
    m.mark = cast(Value_Id) ir.v_kind.count;
}

// processAtomicInstr
ae_process :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == .LOAD {
        if !inst_is_atomic(i) return false;
        if !ae_size_supported_x86(i) { ae_load_to_libcall(i); return true; }
        changed := false;
        li := i;
        if is_fp_type(vtype(li)) { li = ae_convert_load_to_int(li); changed = true; }
        // tryExpandAtomicLoad
        mt := vtype(li);
        if !(ae_primitive_bits(mt) == 128 && ae_ctx.avx_ok) && ae_needs_cmpxchg_nb(mt) { ae_load_to_cmpxchg(li); changed = true; }
        return changed;
    }
    if o == .STORE {
        if !inst_is_atomic(i) return false;
        if !ae_size_supported_x86(i) { ae_store_to_libcall(i); return true; }
        changed := false;
        si := i;
        if is_fp_type(vtype(op(si, 0))) { si = ae_convert_store_to_int(si); changed = true; }
        mt := vtype(op(si, 0));
        if !(ae_primitive_bits(mt) == 128 && ae_ctx.avx_ok) && ae_needs_cmpxchg_nb(mt) { ae_store_to_xchg(si); changed = true; }
        return changed;
    }
    if o == .ATOMICRMW {
        if !ae_size_supported_x86(i) { ae_rmw_to_libcall(i); return true; }
        changed := false;
        ai := i;
        vt := vtype(op(ai, 1));
        if inst(ai).ord2 == RMW_XCHG && (is_fp_type(vt) || is_ptr_type(vt)) { ai = ae_convert_xchg_to_int(ai); changed = true; }
        if ae_is_idempotent(ai) && ae_lower_idempotent_rmw_into_fenced_load(ai, ae_ctx.st) return true;
        changed |= ae_try_expand_rmw(ai);
        return changed;
    }
    if o == .CMPXCHG {
        if !ae_size_supported_x86(i) { ae_cas_to_libcall(i); return true; }
        changed := false;
        if is_ptr_type(vtype(op(i, 1))) { ae_convert_cmpxchg_to_int(i); changed = true; }
        // x86: no fences, no trailing seq_cst fence, no cmpxchg expansion (MinCmpXchgSizeInBits is 8)
        return changed;
    }
    return false;
}

// getCorrespondingIntegerType: iN of the store size
ae_int_type :: (t: Type_Id) -> Type_Id { return type_int(cast(u32) (dl_type_store_size(t) * 8)); }


// ReplacementIRBuilder's InstSimplifyFolder(DL): every Create* first tries InstSimplify (no TLI, DT, AC or context)
ae_q :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }
ae_binop :: (b: *Irb, opc: Opcode, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    f := simplify_binop(opc, l, r, ae_q());
    if f != NONE return f;
    i := new_inst(opc, vtype(l), 2);
    set_op(i, 0, l); set_op(i, 1, r);
    return irb_insert(b, i, name);
}
ae_icmp :: (b: *Irb, pred: u8, l: Value_Id, r: Value_Id, name := "") -> Value_Id {
    f := simplify_cmp_inst(pred, false, l, r, ae_q());
    if f != NONE return f;
    return irb_insert(b, create_icmp(pred, l, r), name);
}
ae_select :: (b: *Irb, c: Value_Id, t: Value_Id, fv: Value_Id, name := "") -> Value_Id {
    f := simplify_select_inst(c, t, fv, 0, ae_q());
    if f != NONE return f;
    i := new_inst(.SELECT, vtype(t), 3);
    set_op(i, 0, c); set_op(i, 1, t); set_op(i, 2, fv);
    return irb_insert(b, i, name);
}
ae_cast :: (b: *Irb, opc: Opcode, v: Value_Id, dt: Type_Id, name := "") -> Value_Id {
    if vtype(v) == dt return v;
    f := simplify_cast_inst(opc, v, dt, ae_q());
    if f != NONE return f;
    i := new_inst(opc, dt, 1);
    set_op(i, 0, v);
    return irb_insert(b, i, name);
}
ae_extract_value :: (b: *Irb, agg: Value_Id, idxs: [] u32, name := "") -> Value_Id {
    f := simplify_extract_value_inst(agg, idxs, ae_q());
    if f != NONE return f;
    return irb_extract_value(b, agg, idxs, name);
}
ae_insert_value :: (b: *Irb, agg: Value_Id, v: Value_Id, idxs: [] u32, name := "") -> Value_Id {
    f := simplify_insert_value_inst(agg, v, idxs, ae_q());
    if f != NONE return f;
    return irb_insert_value(b, agg, v, idxs, name);
}
ae_intrinsic :: (b: *Irb, id: Intrinsic_Id, ty: Type_Id, args: [] Value_Id, name := "") -> Value_Id {
    f := simplify_intrinsic(id, ty, args, 0, ae_q(), block_fn(b.bb), EB_IGNORE, RM_NEAREST_TIES_TO_EVEN);
    if f != NONE return f;
    return vp_intrinsic(b, id, .[ty], args, name);
}

ae_builder :: (i: Value_Id) -> Irb { b: Irb; irb_set_before(*b, i); return b; }

new_atomic_load :: (b: *Irb, t: Type_Id, ptr: Value_Id, align: u64, ord: u8, sync: u32, volatile: bool, name := "") -> Value_Id {
    ld := new_inst(.LOAD, t, 1);
    set_op(ld, 0, ptr);
    inst(ld).align = align; inst(ld).ord1 = ord; inst(ld).sync = sync;
    if volatile inst(ld).flags |= F_VOLATILE;
    return irb_insert(b, ld, name);
}
new_atomic_store :: (b: *Irb, v: Value_Id, ptr: Value_Id, align: u64, ord: u8, sync: u32, volatile: bool) -> Value_Id {
    st := new_inst(.STORE, ir.t_void, 2);
    set_op(st, 0, v); set_op(st, 1, ptr);
    inst(st).align = align; inst(st).ord1 = ord; inst(st).sync = sync;
    if volatile inst(st).flags |= F_VOLATILE;
    return irb_insert(b, st);
}
new_cmpxchg :: (b: *Irb, ptr: Value_Id, cmp: Value_Id, nv: Value_Id, align: u64, succ: u8, fail: u8, sync: u32, name := "") -> Value_Id {
    rt := type_literal_struct(.[vtype(cmp), ir.t_i1], false);
    c := new_inst(.CMPXCHG, rt, 3);
    set_op(c, 0, ptr); set_op(c, 1, cmp); set_op(c, 2, nv);
    inst(c).align = align; inst(c).ord1 = succ; inst(c).ord2 = fail; inst(c).sync = sync;
    return irb_insert(b, c, name);
}
new_atomicrmw :: (b: *Irb, rop: u8, ptr: Value_Id, v: Value_Id, align: u64, ord: u8, sync: u32) -> Value_Id {
    a := new_inst(.ATOMICRMW, vtype(v), 2);
    set_op(a, 0, ptr); set_op(a, 1, v);
    inst(a).align = align; inst(a).ord1 = ord; inst(a).ord2 = rop; inst(a).sync = sync;
    return irb_insert(b, a);
}
// AtomicCmpXchgInst::getStrongestFailureOrdering
ae_strongest_failure_ordering :: (o: u8) -> u8 {
    if o == ORD_RELEASE || o == ORD_MONOTONIC return ORD_MONOTONIC;
    if o == AE_ORD_ACQ_REL || o == ORD_ACQUIRE return ORD_ACQUIRE;
    if o == AE_ORD_SEQ_CST return AE_ORD_SEQ_CST;
    fatal("internal: atomic-expand: bad cmpxchg ordering");
    return 0;
}
// copyMetadataForAtomic
ae_copy_metadata_for_atomic :: (dst: Value_Id, src: Value_Id) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(src, *all);
    for all {
        k := it.kind;
        if k == MDK_DBG || k == MDK_TBAA || k == MDK_TBAA_STRUCT || k == MDK_ALIAS_SCOPE || k == MDK_NOALIAS ||
           k == MDK_NOALIAS_ADDRSPACE || k == md_kind_id("llvm.access.group") || k == md_kind_id("mmra") ||
           k == md_kind_id("amdgpu.no.remote.memory") || k == md_kind_id("amdgpu.no.fine.grained.memory")
            set_metadata(dst, k, it.md);
    }
}

// convertAtomicLoadToIntegerType
ae_convert_load_to_int :: (li: Value_Id) -> Value_Id {
    md := ae_md_begin(li);
    b := ae_builder(li);
    nt := ae_int_type(vtype(li));
    nl := new_atomic_load(*b, nt, op(li, 0), inst(li).align, inst(li).ord1, inst(li).sync, is_volatile(li));
    nv := ifx is_ptr_or_ptr_vector(vtype(li)) then ae_cast(*b, .INTTOPTR, nl, vtype(li)) else ae_cast(*b, .BITCAST, nl, vtype(li));
    ae_md_end(*md);
    replace_all_uses_with(li, nv);
    erase_inst(li);
    return nl;
}
// convertAtomicStoreToIntegerType
ae_convert_store_to_int :: (si: Value_Id) -> Value_Id {
    md := ae_md_begin(si);
    b := ae_builder(si);
    v := op(si, 0);
    nt := ae_int_type(vtype(v));
    nv := ifx is_ptr_or_ptr_vector(vtype(v)) then ae_cast(*b, .PTRTOINT, v, nt) else ae_cast(*b, .BITCAST, v, nt);
    ns := new_atomic_store(*b, nv, op(si, 1), inst(si).align, inst(si).ord1, inst(si).sync, is_volatile(si));
    ae_md_end(*md);
    erase_inst(si);
    return ns;
}
// convertAtomicXchgToIntegerType
ae_convert_xchg_to_int :: (ai: Value_Id) -> Value_Id {
    md := ae_md_begin(ai);
    b := ae_builder(ai);
    nt := ae_int_type(vtype(ai));
    v := op(ai, 1);
    nv := ifx is_ptr_type(vtype(v)) then ae_cast(*b, .PTRTOINT, v, nt) else ae_cast(*b, .BITCAST, v, nt);
    na := new_atomicrmw(*b, RMW_XCHG, op(ai, 0), nv, inst(ai).align, inst(ai).ord1, inst(ai).sync);
    if is_volatile(ai) inst(na).flags |= F_VOLATILE;
    ae_copy_metadata_for_atomic(na, ai);
    r := ifx is_ptr_type(vtype(ai)) then ae_cast(*b, .INTTOPTR, na, vtype(ai)) else ae_cast(*b, .BITCAST, na, vtype(ai));
    ae_md_end(*md);
    replace_all_uses_with(ai, r);
    erase_inst(ai);
    return na;
}
// convertCmpXchgToIntegerType
ae_convert_cmpxchg_to_int :: (ci: Value_Id) -> Value_Id {
    md := ae_md_begin(ci);
    b := ae_builder(ci);
    ct := vtype(op(ci, 1));
    nt := ae_int_type(ct);
    nc := ae_cast(*b, .PTRTOINT, op(ci, 1), nt);
    nn := ae_cast(*b, .PTRTOINT, op(ci, 2), nt);
    x := new_cmpxchg(*b, op(ci, 0), nc, nn, inst(ci).align, inst(ci).ord1, inst(ci).ord2, inst(ci).sync);
    inst(x).flags |= inst(ci).flags & (F_VOLATILE | F_WEAK);
    old := ae_extract_value(*b, x, .[0]);
    succ := ae_extract_value(*b, x, .[1]);
    old = ae_cast(*b, .INTTOPTR, old, ct);
    res := const_poison(vtype(ci));
    res = ae_insert_value(*b, res, old, .[0]);
    res = ae_insert_value(*b, res, succ, .[1]);
    ae_md_end(*md);
    replace_all_uses_with(ci, res);
    erase_inst(ci);
    return x;
}

// expandAtomicLoadToCmpXchg
ae_load_to_cmpxchg :: (li: Value_Id) {
    md := ae_md_begin(li);
    b := ae_builder(li);
    order := inst(li).ord1;
    if order == ORD_UNORDERED order = ORD_MONOTONIC;
    t := vtype(li);
    need_bitcast := is_fp_type(t) || is_vector_type(t);
    ct := ifx need_bitcast then type_int(cast(u32) ae_primitive_bits(t)) else t;
    dummy := const_null_value(ct);
    pair := new_cmpxchg(*b, op(li, 0), dummy, dummy, inst(li).align, order, ae_strongest_failure_ordering(order), inst(li).sync);
    if is_volatile(li) inst(pair).flags |= F_VOLATILE;
    loaded := ae_extract_value(*b, pair, .[0], "loaded");
    if need_bitcast loaded = ae_cast(*b, .BITCAST, loaded, t);
    ae_md_end(*md);
    replace_all_uses_with(li, loaded);
    erase_inst(li);
}

// expandAtomicStoreToXChg
ae_store_to_xchg :: (si: Value_Id) {
    md := ae_md_begin(si);
    b := ae_builder(si);
    ord := inst(si).ord1;
    rord := ifx ord == ORD_UNORDERED then cast(u8) ORD_MONOTONIC else ord;
    ai := new_atomicrmw(*b, RMW_XCHG, op(si, 1), op(si, 0), inst(si).align, rord, inst(si).sync);
    if is_volatile(si) inst(ai).flags |= F_VOLATILE;
    ae_md_end(*md);
    erase_inst(si);
    ae_try_expand_rmw(ai);
}

// tryExpandAtomicRMW with X86TargetLowering::shouldExpandAtomicRMWInIR
ae_try_expand_rmw :: (ai: Value_Id) -> bool {
    mt := vtype(ai);
    rop := inst(ai).ord2;
    if ae_primitive_bits(mt) > 64 {
        if !ae_needs_cmpxchg_nb(mt) return false;
        ae_rmw_to_cmpxchg(ai);
        return true;
    }
    if rop == {
        case RMW_XCHG; return false;
        case RMW_ADD; #through;
        case RMW_SUB;
            if ae_cmp_arith_user(ai) ae_fail(ai, "an atomicrmw whose result is only compared (x86 cc intrinsic)");
            return false;
        case RMW_OR; #through;
        case RMW_AND; #through;
        case RMW_XOR;
            if ae_cmp_arith_user(ai) ae_fail(ai, "an atomicrmw whose result is only compared (x86 cc intrinsic)");
            // shouldExpandLogicAtomicRMWInIR: no uses -> None; the bit-test forms and cmpxchg loops are not ported
            if !has_uses(ai) return false;
            if rop == RMW_XOR && vkind(op(ai, 1)) == .C_INT && ap_is_sign_mask(const_ap(op(ai, 1))) return false;
            if ae_logic_rmw_bit_test(ai) ae_fail(ai, "an atomic or/and/xor single-bit test (x86 bit-test intrinsic)");
    }
    ae_rmw_to_cmpxchg(ai);
    return true;
}

// shouldExpandLogicAtomicRMWInIR after the use_empty / xor-sign-mask checks: true when it may return
// BitTestIntrinsic (decided exactly for a constant mask; any non-constant FindSingleBitChange candidate is treated as
// a possible bit test), false for CmpXChg.
ae_logic_rmw_bit_test :: (ai: Value_Id) -> bool {
    v := op(ai, 1);
    u := ir.u_user[ir.v_first_use[ai]];
    if !has_one_use(ai) || !is_inst(u) || inst_op(u) != .AND || ae_primitive_bits(vtype(ai)) == 8 || inst_block(ai) != inst_block(u) return false;
    other := ifx op(u, 0) == ai then op(u, 1) else op(u, 0);
    if other == ai return false;
    if vkind(v) != .C_INT return is_inst(v);
    c1 := const_ap(v);
    bits := ap_zext_value(c1);
    nbits := ap_zext_value(ap_not(c1));
    is_pow2 :: (x: u64) -> bool { return x != 0 && (x & (x - 1)) == 0; }
    if !is_pow2(bits) && !is_pow2(nbits) return false;   // UndefBit
    if vkind(other) != .C_INT return false;
    c2 := const_ap(other);
    if !is_pow2(ap_zext_value(c2)) return false;
    if inst(ai).ord2 == RMW_AND return ap_eq(ap_not(c1), c2);
    return v == other;
}

// buildAtomicRMWValue
ae_build_rmw_value :: (b: *Irb, rop: u8, loaded: Value_Id, v: Value_Id) -> Value_Id {
    if rop == {
        case RMW_XCHG; return v;
        case RMW_ADD; return ae_binop(b, .ADD, loaded, v, "new");
        case RMW_SUB; return ae_binop(b, .SUB, loaded, v, "new");
        case RMW_AND; return ae_binop(b, .AND, loaded, v, "new");
        case RMW_NAND;
            a := ae_binop(b, .AND, loaded, v);
            return ae_binop(b, .XOR, a, const_all_ones_of(vtype(a)), "new");
        case RMW_OR; return ae_binop(b, .OR, loaded, v, "new");
        case RMW_XOR; return ae_binop(b, .XOR, loaded, v, "new");
        case RMW_MAX; return ae_select(b, ae_icmp(b, ICMP_SGT, loaded, v), loaded, v, "new");
        case RMW_MIN; return ae_select(b, ae_icmp(b, ICMP_SLE, loaded, v), loaded, v, "new");
        case RMW_UMAX; return ae_select(b, ae_icmp(b, ICMP_UGT, loaded, v), loaded, v, "new");
        case RMW_UMIN; return ae_select(b, ae_icmp(b, ICMP_ULE, loaded, v), loaded, v, "new");
        case RMW_FADD; return ae_binop(b, .FADD, loaded, v, "new");
        case RMW_FSUB; return ae_binop(b, .FSUB, loaded, v, "new");
        case RMW_FMAX; return ae_intrinsic(b, intrinsic_id_by_name("llvm.maxnum"), vtype(loaded), .[loaded, v]);
        case RMW_FMIN; return ae_intrinsic(b, intrinsic_id_by_name("llvm.minnum"), vtype(loaded), .[loaded, v]);
    }
    name := RMW_OPS[rop];
    if name == "fmaximum" return ae_intrinsic(b, intrinsic_id_by_name("llvm.maximum"), vtype(loaded), .[loaded, v]);
    if name == "fminimum" return ae_intrinsic(b, intrinsic_id_by_name("llvm.minimum"), vtype(loaded), .[loaded, v]);
    if name == "fmaximumnum" return ae_intrinsic(b, intrinsic_id_by_name("llvm.maximumnum"), vtype(loaded), .[loaded, v]);
    if name == "fminimumnum" return ae_intrinsic(b, intrinsic_id_by_name("llvm.minimumnum"), vtype(loaded), .[loaded, v]);
    t := vtype(loaded);
    if name == "uinc_wrap" {
        inc := ae_binop(b, .ADD, loaded, const_int(t, 1));
        c := ae_icmp(b, ICMP_UGE, loaded, v);
        return ae_select(b, c, const_int(t, 0), inc, "new");
    }
    if name == "udec_wrap" {
        dec := ae_binop(b, .SUB, loaded, const_int(t, 1));
        c0 := ae_icmp(b, ICMP_EQ, loaded, const_int(t, 0));
        c1 := ae_icmp(b, ICMP_UGT, loaded, v);
        o := ae_binop(b, .OR, c0, c1);
        return ae_select(b, o, v, dec, "new");
    }
    if name == "usub_cond" {
        c := ae_icmp(b, ICMP_UGE, loaded, v);
        s := ae_binop(b, .SUB, loaded, v);
        return ae_select(b, c, s, loaded, "new");
    }
    if name == "usub_sat" return ae_intrinsic(b, intrinsic_id_by_name("llvm.usub.sat"), t, .[loaded, v], "new");
    fatal("internal: atomic-expand: unknown atomicrmw operation");
    return NONE;
}

// expandAtomicRMWToCmpXchg with insertRMWCmpXchgLoop and createCmpXchgInstFun
ae_rmw_to_cmpxchg :: (ai: Value_Id, cas_libcall := false) {
    md := ae_md_begin(ai);
    if is_fp_type(scalar_type(vtype(ai))) && fn_has_fn_attr(inst_fn(ai), .StrictFP) ae_fail(ai, "a strictfp floating-point atomicrmw loop");
    rt := vtype(ai);
    addr := op(ai, 0);
    align := inst(ai).align;
    ord := inst(ai).ord1;
    sync := inst(ai).sync;
    volatile := is_volatile(ai);
    rop := inst(ai).ord2;
    val := op(ai, 1);
    bb := inst_block(ai);
    f := block_fn(bb);
    dbg := get_metadata(ai, MDK_DBG);
    exit_bb := split_basic_block(bb, ai, "atomicrmw.end");
    loop_bb := create_block(f, "atomicrmw.start", exit_bb);
    erase_inst(block_last(bb));
    b: Irb; irb_set_end(*b, bb); b.dbg = dbg;
    init := new_atomic_load(*b, rt, addr, align, 0, 0, false);
    irb_insert(*b, create_br(loop_bb));
    irb_set_end(*b, loop_bb);
    loaded := irb_phi(*b, rt, 2, "loaded");
    phi_add_incoming(loaded, init, bb);
    if volatile inst(init).flags |= F_VOLATILE;
    nv := ae_build_rmw_value(*b, rop, loaded, val);
    // createCmpXchgInstFun
    orig := vtype(nv);
    need_bitcast := !cas_libcall && (is_fp_type(orig) || is_vector_type(orig));
    cmp_v := loaded; new_v := nv;
    if need_bitcast {
        it := type_int(cast(u32) ae_primitive_bits(orig));
        new_v = ae_cast(*b, .BITCAST, nv, it);
        cmp_v = ae_cast(*b, .BITCAST, loaded, it);
    }
    mo := ifx ord == ORD_UNORDERED then cast(u8) ORD_MONOTONIC else ord;
    pair := new_cmpxchg(*b, addr, cmp_v, new_v, align, mo, ae_strongest_failure_ordering(mo), sync);
    if volatile inst(pair).flags |= F_VOLATILE;
    ae_copy_metadata_for_atomic(pair, ai);
    success := ae_extract_value(*b, pair, .[1], "success");
    new_loaded := ae_extract_value(*b, pair, .[0], "newloaded");
    if cas_libcall { ae_md_end(*md); ae_cas_to_libcall(pair); md.mark = cast(Value_Id) ir.v_kind.count; }
    if need_bitcast new_loaded = ae_cast(*b, .BITCAST, new_loaded, orig);
    phi_add_incoming(loaded, new_loaded, loop_bb);
    br := irb_insert(*b, create_cond_br(success, exit_bb, loop_bb));
    set_explicitly_unknown_branch_weights_if_profiled(br, "atomic-expand");
    ae_md_end(*md);
    replace_all_uses_with(ai, new_loaded);
    erase_inst(ai);
}

// expandAtomicRMWToLibcall with GetRMWLibcall
ae_rmw_to_libcall :: (i: Value_Id) {
    rop := inst(i).ord2;
    names: [6] string;
    base := "";
    if rop == {
        case RMW_XCHG; base = "exchange";
        case RMW_ADD; base = "fetch_add";
        case RMW_SUB; base = "fetch_sub";
        case RMW_AND; base = "fetch_and";
        case RMW_OR; base = "fetch_or";
        case RMW_XOR; base = "fetch_xor";
        case RMW_NAND; base = "fetch_nand";
    }
    ok := false;
    if base {
        if rop == RMW_XCHG names[0] = "__atomic_exchange";
        sizes :: string.["1", "2", "4", "8", "16"];
        for sizes names[it_index + 1] = tprint("__atomic_%_%", base, it);
        ok = ae_op_to_libcall(i, ae_op_size(i), inst(i).align, op(i, 0), op(i, 1), NONE, inst(i).ord1, 0, names);
    }
    if !ok ae_rmw_to_cmpxchg(i, cas_libcall = true);
}

// toCABI
ae_to_cabi :: (o: u8) -> u64 {
    if o == ORD_UNORDERED || o == ORD_MONOTONIC return 0;
    if o == ORD_ACQUIRE return 2;
    if o == ORD_RELEASE return 3;
    if o == AE_ORD_ACQ_REL return 4;
    if o == AE_ORD_SEQ_CST return 5;
    return 1;   // consume
}

ae_load_to_libcall :: (i: Value_Id) {
    names :: string.["__atomic_load", "__atomic_load_1", "__atomic_load_2", "__atomic_load_4", "__atomic_load_8", "__atomic_load_16"];
    if !ae_op_to_libcall(i, ae_op_size(i), inst(i).align, op(i, 0), NONE, NONE, inst(i).ord1, 0, names) ae_fail(i, "an unsupported atomic load");
}
ae_store_to_libcall :: (i: Value_Id) {
    names :: string.["__atomic_store", "__atomic_store_1", "__atomic_store_2", "__atomic_store_4", "__atomic_store_8", "__atomic_store_16"];
    if !ae_op_to_libcall(i, ae_op_size(i), inst(i).align, op(i, 1), op(i, 0), NONE, inst(i).ord1, 0, names) ae_fail(i, "an unsupported atomic store");
}
ae_cas_to_libcall :: (i: Value_Id) {
    names :: string.["__atomic_compare_exchange", "__atomic_compare_exchange_1", "__atomic_compare_exchange_2",
                     "__atomic_compare_exchange_4", "__atomic_compare_exchange_8", "__atomic_compare_exchange_16"];
    if !ae_op_to_libcall(i, ae_op_size(i), inst(i).align, op(i, 0), op(i, 2), op(i, 1), inst(i).ord1, inst(i).ord2, names) ae_fail(i, "an unsupported cmpxchg");
}

// expandAtomicOpToLibcall (Linux x86-64: every __atomic_* libcall exists)
ae_op_to_libcall :: (i: Value_Id, size: u64, align: u64, ptr: Value_Id, val: Value_Id, cas_expected: Value_Id, ord: u8, ord2: u8, names: [] string) -> bool {
    if st_isOSWindows(ae_ctx.st) && size == 16 ae_fail(i, "an i128 atomic libcall on Windows");
    f := inst_fn(i);
    ab: Irb; irb_set_before(*ab, block_first(fn_entry(f)));
    largest := ifx dl_largest_legal_int_bits() >= 64 then cast(u64) 16 else 8;
    sized := align >= size && (size == 1 || size == 2 || size == 4 || size == 8 || size == 16) && size <= largest;
    sized_t := type_int(cast(u32) (size * 8));
    alloca_align := dl_pref_align(sized_t);
    ord_v := const_int(ir.t_i32, ae_to_cabi(ord));
    has_result := type_kind(vtype(i)) != .VOID;
    name: string;
    if sized {
        if size == 1 name = names[1]; else if size == 2 name = names[2]; else if size == 4 name = names[3];
        else if size == 8 name = names[4]; else name = names[5];
    } else name = names[0];
    if !name return false;   // RTLIB::UNKNOWN_LIBCALL
    b := ae_builder(i);
    args: [..] Value_Id; args.allocator = temp;
    if !sized array_add(*args, const_int(irb_int_ptr_type(ir.t_ptr), size));
    array_add(*args, irb_pointer_bitcast_or_addrspacecast(*b, ptr, ir.t_ptr));
    a_cas, a_val, a_res: Value_Id = NONE;
    if cas_expected != NONE {
        a_cas = ae_alloca(*ab, vtype(cas_expected), alloca_align);
        irb_lifetime(*b, IID_LIFETIME_START, a_cas);
        irb_store(*b, cas_expected, a_cas, alloca_align);
        array_add(*args, a_cas);
    }
    if val != NONE {
        if sized array_add(*args, irb_bit_preserving_cast_chain(*b, val, sized_t));
        else {
            a_val = ae_alloca(*ab, vtype(val), alloca_align);
            irb_lifetime(*b, IID_LIFETIME_START, a_val);
            irb_store(*b, val, a_val, alloca_align);
            array_add(*args, a_val);
        }
    }
    if cas_expected == NONE && has_result && !sized {
        a_res = ae_alloca(*ab, vtype(i), alloca_align);
        irb_lifetime(*b, IID_LIFETIME_START, a_res);
        array_add(*args, a_res);
    }
    array_add(*args, ord_v);
    if cas_expected != NONE array_add(*args, const_int(ir.t_i32, ae_to_cabi(ord2)));
    ret: Type_Id;
    ret_attrs: u32 = 0;
    if cas_expected != NONE {
        ret = ir.t_i1;
        ret_attrs = attr_set_get(.[attr_enum(.ZExt)]);
    } else if has_result && sized ret = sized_t;
    else ret = ir.t_void;
    tys: [..] Type_Id; tys.allocator = temp;
    for args array_add(*tys, vtype(it));
    ft := type_func(ret, tys, false);
    al := ifx ret_attrs then attr_list_get(0, ret_attrs, .[]) else cast(u32) 0;
    fn := module_get_or_insert_function(name, ft, al);
    call := irb_call(*b, fn, args);
    inst(call).attrs = al;
    if val != NONE && !sized irb_lifetime(*b, IID_LIFETIME_END, a_val);
    if cas_expected != NONE {
        v := const_poison(vtype(i));
        out := irb_load(*b, vtype(cas_expected), a_cas, alloca_align);
        irb_lifetime(*b, IID_LIFETIME_END, a_cas);
        v = irb_insert_value(*b, v, out, .[0]);
        v = irb_insert_value(*b, v, call, .[1]);
        replace_all_uses_with(i, v);
    } else if has_result {
        v: Value_Id;
        if sized {
            it := vtype(i);
            if is_vector_type(it) && is_ptr_type(scalar_type(it)) && !is_vector_type(vtype(call)) {
                bc := irb_bitcast(*b, call, irb_int_ptr_type(it));
                v = irb_cast(*b, .INTTOPTR, bc, it);
            } else v = irb_bit_or_pointer_cast(*b, call, it);
        } else {
            v = irb_load(*b, vtype(i), a_res, alloca_align);
            irb_lifetime(*b, IID_LIFETIME_END, a_res);
        }
        replace_all_uses_with(i, v);
    }
    erase_inst(i);
    return true;
}
ae_alloca :: (b: *Irb, t: Type_Id, align: u64) -> Value_Id {
    a := create_alloca_unlinked(t, dl_alloca_addrspace(), align);
    return irb_insert(b, a);
}
// CreateBitOrPointerCast
irb_bit_or_pointer_cast :: (b: *Irb, v: Value_Id, t: Type_Id) -> Value_Id {
    vt := vtype(v);
    if vt == t return v;
    if is_ptr_or_ptr_vector(vt) && is_int_type(scalar_type(t)) return irb_cast(b, .PTRTOINT, v, t);
    if is_int_type(scalar_type(vt)) && is_ptr_or_ptr_vector(t) return irb_cast(b, .INTTOPTR, v, t);
    return irb_bitcast(b, v, t);
}
libcall_lowering_info_cached := false;   // require<libcall-lowering-info> ran (the module analysis is cached)
