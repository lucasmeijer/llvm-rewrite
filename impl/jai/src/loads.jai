// Loads: a port of the parts of llvm/lib/Analysis/Loads.cpp InstCombine needs — isDereferenceableAndAlignedPointer
// (incl. the assume-bundle variant), isDereferenceablePointer, isSafeToLoadUnconditionally (both overloads),
// mustSuppressSpeculation, FindAvailableLoadedValue(Load, BatchAA, IsLoadCSE) with getAvailableLoadStore — plus
// the helpers they call from elsewhere: Value::canBeFreed (Value.cpp), willNotFreeBetween (ValueTracking.cpp),
// getKnowledgeForValue / getKnowledgeFromBundle (AssumeBundleQueries.cpp), CastInst::isBitOrNoopPointerCastable /
// isBitCastable (Instructions.cpp), GetPointerBaseWithConstantOffset (ValueTracking.h), Instruction::
// maySynchronize. (pass_sroa.jai has an older partial isSafeToLoadUnconditionally; new code should use these.)
// Not ported: isDereferenceableAndAlignedInLoop, findAvailablePtrLoadStore with a scan limit / ScanBB (JumpThreading's
// FindAvailableLoadedValue overload), canReplacePointersIfEqual, isReadOnlyLoop.

// Instruction::maySynchronize
may_synchronize :: (i: Value_Id) -> bool {
    o := inst_op(i);
    if o == {
        case .FENCE; return inst(i).sync != 1;   // SyncScope::SingleThread
        case .ATOMICRMW; #through;
        case .CMPXCHG; return true;
        case .STORE; #through;
        case .LOAD; return inst(i).ord1 > ORD_UNORDERED;
        case .CALL; #through;
        case .INVOKE; #through;
        case .CALLBR; return !call_has_fn_attr(i, .NoSync);
    }
    return false;
}

// willNotFreeBetween(Assume, CtxI)
will_not_free_between :: (assume: Value_Id, cxt: Value_Id) -> bool {
    MAX_INSTRS_TO_CHECK_FOR_FREE :: 32;
    num_checked := 0;
    // hasNoFreeInRange over [from, to) (to = NONE: to the end of the block)
    no_free_in_range :: (from: Value_Id, to: Value_Id, num_checked: *int) -> bool {
        i := from;
        while i != NONE && i != to {
            num_checked.* += 1;
            if num_checked.* - 1 > MAX_INSTRS_TO_CHECK_FOR_FREE return false;
            if is_call_base(i) { if !call_has_fn_attr(i, .NoFree) return false; }
            else if may_synchronize(i) return false;
            i = inst(i).next;
        }
        return true;
    }
    cbb := inst_block(cxt);
    abb := inst_block(assume);
    if cbb == abb {
        if assume != cxt && !comes_before(assume, cxt) return false;
        return no_free_in_range(assume, cxt, *num_checked);
    }
    cur := cbb;
    while true {
        if cur == abb return no_free_in_range(assume, NONE, *num_checked);
        pred := block_single_predecessor(cur);
        if pred == NONE return false;
        if !no_free_in_range(block_first(cur), ifx cur == cbb then cxt else NONE, *num_checked) return false;
        cur = pred;
    }
    return false;
}

// Value::canBeFreed
value_can_be_freed :: (v: Value_Id) -> bool {
    if is_constant_kind(vkind(v)) || is_global_value(vkind(v)) return false;
    if is_inst(v) && inst_op(v) == .ALLOCA return false;
    f: Value_Id = NONE;
    if vkind(v) == .ARGUMENT {
        if arg_pointee_in_memory_value_type(v) != NONE return false;
        f = arg_parent(v);
        if fn_does_not_free_memory(f) return false;
        s := arg_attrs(v);
        if (attr_set_has(s, .NoFree) || arg_only_reads_memory(v)) && attr_set_has(s, .NoAlias) return false;
    }
    if is_inst(v) && inst_op(v) == .INTTOPTR && get_metadata(v, md_kind_id("nofree")) != NONE return false;
    if is_inst(v) f = value_function(v);
    if f == NONE return true;
    if glob(f).gc.count == 0 return true;
    if glob(f).gc == "statepoint-example" {
        if ir.types[vtype(v)].a != 1 return true;
        for ir.m_functions if begins_with(vname(it), "llvm.experimental.gc.statepoint") return true;
        return false;
    }
    return true;
}
// Function::doesNotFreeMemory: onlyReadsMemory() || hasFnAttribute(NoFree)
fn_does_not_free_memory :: (f: Value_Id) -> bool {
    if fn_has_fn_attr(f, .NoFree) return true;
    return (me_mod_ref(fn_memory(f)) & MR_MOD) == 0;   // onlyReadsMemory
}

// getKnowledgeFromBundle for the "dereferenceable" / "align" tags: (kind found, was_on, arg value)
Retained_Knowledge :: struct { kind: Attr_Kind; was_on: Value_Id = NONE; arg: u64; ir_arg: Value_Id = NONE; }
knowledge_from_bundle :: (assume: Value_Id, k: u32) -> (bool, Retained_Knowledge) {
    rk: Retained_Knowledge;
    tag := call_bundle_tag(assume, k);
    begin := ir.u32_pool[inst(assume).idx + 3 * k + 1];
    end := ir.u32_pool[inst(assume).idx + 3 * k + 2];
    if tag == "dereferenceable" rk.kind = .Dereferenceable;
    else if tag == "align" rk.kind = .Alignment;
    else return false, rk;   // other kinds are never asked for here
    if end > begin rk.was_on = op(assume, begin);
    arg_or :: (assume: Value_Id, begin: u32, end: u32, idx: u32, default: u64) -> u64 {
        if begin + 1 + idx >= end return default;
        c := op(assume, begin + 1 + idx);
        if vkind(c) == .C_INT && !is_vector_type(vtype(c)) return ap_zext_value(const_ap(c));
        return default;
    }
    if end - begin > 1 {
        if rk.kind == .Alignment rk.arg = arg_or(assume, begin, end, 0, 1);
        else rk.arg = arg_or(assume, begin, end, 0, 0);
    }
    if end - begin > 1 rk.ir_arg = op(assume, begin + 1);   // IRArgValue
    if rk.kind == .Alignment && end - begin > 2 {
        a := rk.arg | arg_or(assume, begin, end, 1, 1);
        rk.arg = a & (~a + 1);   // MinAlign
    }
    return true, rk;
}

// isDereferenceableAndAlignedPointerViaAssumption
deref_aligned_via_assumption :: (ptr: Value_Id, align: u64, q: Simplify_Query, ignore_free: bool, size: APInt) -> bool {
    if q.cxt == NONE return false;
    can_be_freed := value_can_be_freed(ptr) && !ignore_free;
    is_aligned := pointer_alignment(ptr) >= align;
    is_derefable := false;
    for e: ac_assumptions_for(q.ac, ptr) {
        if vkind(e.assume) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
        ok, rk := knowledge_from_bundle(e.assume, e.index);
        if !ok || rk.was_on != ptr continue;
        if !is_valid_assume_for_context(e.assume, q.cxt, q.dt) continue;
        if rk.kind == .Alignment is_aligned |= rk.arg >= align;
        else if !is_derefable && (!can_be_freed || will_not_free_between(e.assume, q.cxt)) && rk.arg >= ap_zext_value(size)
            is_derefable = true;
        if is_aligned && is_derefable return true;
    }
    return false;
}

// isDereferenceableAndAlignedPointer (the recursive static one)
deref_aligned_rec :: (v: Value_Id, align: u64, size: APInt, q: Simplify_Query, ignore_free: bool, visited: *[..] Value_Id, max_depth: *u32) -> bool {
    if max_depth.* == 0 return false;
    max_depth.* -= 1;
    for visited.* if it == v return false;
    array_add(visited, v);
    o := opr_code(v);
    if o == .GEP {
        base := op(v, 0);
        ok, offset := gep_accumulate_constant_offset(v, ap_zero(dl_index_type_size_bits(vtype(v))));
        if !ok || ap_is_negative(offset) || !ap_is_zero(ap_urem(offset, ap_from_u64(offset.bits, align))) return false;
        return deref_aligned_rec(base, align, ap_add(offset, ap_sext_or_trunc(size, offset.bits)), q, ignore_free, visited, max_depth);
    }
    if o == .BITCAST && is_ptr_type(vtype(op(v, 0)))
        return deref_aligned_rec(op(v, 0), align, size, q, ignore_free, visited, max_depth);
    if is_inst(v) && inst_op(v) == .SELECT
        return deref_aligned_rec(op(v, 1), align, size, q, ignore_free, visited, max_depth) &&
               deref_aligned_rec(op(v, 2), align, size, q, ignore_free, visited, max_depth);
    is_known_deref :: (v: Value_Id, size: APInt, q: Simplify_Query, ignore_free: bool) -> bool {
        check_for_non_null, bytes := pointer_dereferenceable_bytes(v);
        if ap_active_bits(size) > 64 || ap_zext_value(size) > bytes return false;   // !Size.ule(DerefBytes)
        check_for_freed := false;
        if bytes != 0 && !pointer_can_not_be_freed_kind(v) check_for_freed = use_deref_at_point_semantics && value_can_be_freed(v);
        if check_for_non_null && !is_known_non_zero(v, q) return false;
        if check_for_freed && !ignore_free {
            def_i: Value_Id;
            if is_inst(v) {
                if inst_op(v) == .INVOKE def_i = block_first(op(v, nops(v) - 3));
                else if !is_terminator(inst_op(v)) def_i = inst(v).next;
                else def_i = v;
            } else def_i = block_first(fn_entry(arg_parent(v)));
            if q.cxt == NONE || !will_not_free_between(def_i, q.cxt) return false;
        }
        if is_inst(v) && inst_op(v) != .ALLOCA return q.cxt != NONE && is_valid_assume_for_context(v, q.cxt, q.dt);
        return true;
    }
    if is_known_deref(v, size, q, ignore_free) return pointer_alignment(v) >= align;
    if is_inst(v) && is_call_base(v) {
        rp := argument_aliasing_to_returned_pointer(v, true);
        if rp != NONE return deref_aligned_rec(rp, align, size, q, ignore_free, visited, max_depth);
        opts: Os_Opts;
        opts.round_to_align = false;
        opts.null_is_unknown_size = true;
        ok, obj_size := get_object_size(v, opts);
        if ok {
            known := ap_from_u64(size.bits, obj_size);
            if !ap_is_zero(known) && ap_uge(known, size) && is_known_non_zero(v, q) && !value_can_be_freed(v)
                return pointer_alignment(v) >= align;
        }
    }
    if call_iid(v) == IID_EXPERIMENTAL_GC_RELOCATE {   // look through relocations: getDerivedPtr
        d := gc_relocate_ptr(v, 2);
        if d == NONE fatal("isDereferenceableAndAlignedPointer: gc.relocate with an invalid derived pointer index");
        return deref_aligned_rec(d, align, size, q, ignore_free, visited, max_depth);
    }
    if o == .ADDRSPACECAST return deref_aligned_rec(op(v, 0), align, size, q, ignore_free, visited, max_depth);
    return q.ac != null && deref_aligned_via_assumption(v, align, q, ignore_free, size);
}
// The cases of getPointerDereferenceableBytes that set CanNotBeFreed (allocas with a known size, sized globals)
pointer_can_not_be_freed_kind :: (v: Value_Id) -> bool {
    if is_inst(v) && inst_op(v) == .ALLOCA { ok := alloca_allocation_size(v); return ok; }
    if vkind(v) == .GLOBAL_VAR { g := glob(v); return type_is_sized(g.value_type) && g.linkage != .EXTERN_WEAK; }
    return false;
}

// llvm::isDereferenceableAndAlignedPointer(V, Alignment, Size, SQ, IgnoreFree)
is_dereferenceable_and_aligned_pointer :: (v: Value_Id, align: u64, size: APInt, q: Simplify_Query, ignore_free := false) -> bool {
    visited: [..] Value_Id; visited.allocator = temp;
    depth: u32 = 16;
    return deref_aligned_rec(v, max(align, 1), size, q, ignore_free, *visited, *depth);
}
// isDereferenceableAndAlignedPointer(V, Ty, Alignment, SQ, IgnoreFree)
is_dereferenceable_and_aligned_pointer_ty :: (v: Value_Id, ty: Type_Id, align: u64, q: Simplify_Query, ignore_free := false) -> bool {
    if !type_is_sized(ty) || type_is_scalable(ty) return false;
    size := ap_from_u64(cast(u32) dl_pointer_type_size_bits(vtype(v)), dl_type_store_size(ty));
    return is_dereferenceable_and_aligned_pointer(v, align, size, q, ignore_free);
}
is_dereferenceable_pointer_ty :: (v: Value_Id, ty: Type_Id, q: Simplify_Query, ignore_free := false) -> bool {
    return is_dereferenceable_and_aligned_pointer_ty(v, ty, 1, q, ignore_free);
}

// AreEquivalentAddressValues (Loads.cpp)
ld_equivalent_address_values :: (a: Value_Id, b: Value_Id) -> bool {
    if a == b return true;
    if is_inst(a) && (is_cast_op(inst_op(a)) || inst_op(a) == .PHI || inst_op(a) == .GEP) && is_inst(b)
        if is_identical_to_when_defined(a, b) return true;
    return false;
}

// suppressSpeculativeLoadForSanitizers / mustSuppressSpeculation
suppress_speculative_load_for_sanitizers :: (cxt: Value_Id) -> bool {
    f := value_function(cxt);
    return fn_has_fn_attr(f, .SanitizeThread) || fn_has_fn_attr(f, .SanitizeAddress) || fn_has_fn_attr(f, .SanitizeHWAddress);
}
must_suppress_speculation :: (li: Value_Id) -> bool { return !is_unordered(li) || suppress_speculative_load_for_sanitizers(li); }

// isSafeToLoadUnconditionally(V, Alignment, Size, DL, ScanFrom, AC, DT, TLI)
ld_is_safe_to_load_unconditionally :: (v_in: Value_Id, align: u64, size: APInt, scan_from: Value_Id, ac: *Assumption_Cache = null, dt: *Dom_Tree = null) -> bool {
    q: Simplify_Query; q.dt = dt; q.ac = ac; q.cxt = scan_from;
    if is_dereferenceable_and_aligned_pointer(v_in, align, size, q) {
        if scan_from == NONE || !suppress_speculative_load_for_sanitizers(scan_from) return true;
    }
    if scan_from == NONE return false;
    if size.bits > 64 return false;
    load_size := ap_zext_value(size);
    v := strip_pointer_casts(v_in);
    x := inst(scan_from).prev;
    while x != NONE {
        cur := x;
        x = inst(x).prev;
        o := inst_op(cur);
        if o == .CALL && may_write_to_memory(cur) && !is_lifetime_start_or_end(cur) return false;
        ptr: Value_Id; ty: Type_Id; al: u64;
        if o == .LOAD {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 0); ty = vtype(cur); al = inst(cur).align;
        } else if o == .STORE {
            if inst(cur).flags & F_VOLATILE continue;
            ptr = op(cur, 1); ty = vtype(op(cur, 0)); al = inst(cur).align;
        } else continue;
        if al < align continue;
        // TypeSize::isKnownLE(fixed LoadSize, StoreSize): a scalable store size is known >= its minimum
        if ptr == v && load_size <= dl_type_store_size(ty) return true;
        if ld_equivalent_address_values(strip_pointer_casts(ptr), v) && load_size <= dl_type_store_size(ty) return true;
    }
    return false;
}
// isSafeToLoadUnconditionally(V, Ty, Alignment, DL, ScanFrom, AC, DT, TLI)
ld_is_safe_to_load_unconditionally_ty :: (v: Value_Id, ty: Type_Id, align: u64, scan_from: Value_Id, ac: *Assumption_Cache = null, dt: *Dom_Tree = null) -> bool {
    if type_is_scalable(ty) return false;
    size := ap_from_u64(dl_index_type_size_bits(vtype(v)), dl_type_store_size(ty));
    return ld_is_safe_to_load_unconditionally(v, align, size, scan_from, ac, dt);
}

// Type::getPrimitiveSizeInBits as (known minimum, scalable)
prim_size_bits :: (t: Type_Id) -> (u64, bool) {
    k := type_kind(t);
    if k == .VECTOR || k == .SVECTOR return type_count(t) * cast(u64) type_bits(type_elem(t)), k == .SVECTOR;
    if k == .X86_AMX return 8192, false;
    return cast(u64) type_bits(t), false;
}
// CastInst::isBitCastable
is_bit_castable :: (src_in: Type_Id, dst_in: Type_Id) -> bool {
    src := src_in; dst := dst_in;
    if !is_first_class(src) || !is_first_class(dst) return false;
    if src == dst return true;
    if is_vector_type(src) && is_vector_type(dst) && type_count(src) == type_count(dst) && type_kind(src) == type_kind(dst) {
        src = type_elem(src); dst = type_elem(dst);
    }
    if is_ptr_type(dst) && is_ptr_type(src) return ir.types[src].a == ir.types[dst].a;
    sb, ss := prim_size_bits(src);
    db, ds := prim_size_bits(dst);
    if sb == 0 || db == 0 return false;
    return sb == db && ss == ds;
}
// CastInst::isBitOrNoopPointerCastable
is_bit_or_noop_pointer_castable :: (src: Type_Id, dst: Type_Id) -> bool {
    if is_ptr_type(src) && is_int_type(dst) return cast(u64) type_int_width(dst) == dl_pointer_type_size_bits(src) && !dl_ni_ptr_type(src);
    if is_ptr_type(dst) && is_int_type(src) return cast(u64) type_int_width(src) == dl_pointer_type_size_bits(dst) && !dl_ni_ptr_type(dst);
    return is_bit_castable(src, dst);
}

// GetPointerBaseWithConstantOffset(Ptr, Offset, DL, AllowNonInbounds = true)
get_pointer_base_with_constant_offset :: (ptr: Value_Id) -> (Value_Id, s64) {
    off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
    base, o := strip_and_accumulate_constant_offsets(ptr, off, true);
    return base, ap_sext_value(o);
}

// getAvailableLoadStore (Loads.cpp)
get_available_load_store :: (i: Value_Id, ptr: Value_Id, access_ty: Type_Id, at_least_atomic: bool, is_load_cse: *bool) -> Value_Id {
    o := inst_op(i);
    if o == .LOAD {
        if inst(i).ord1 == 0 && at_least_atomic return NONE;
        lp := strip_pointer_casts(op(i, 0));
        if !ld_equivalent_address_values(lp, ptr) return NONE;
        if is_bit_or_noop_pointer_castable(vtype(i), access_ty) {
            if is_load_cse is_load_cse.* = true;
            return i;
        }
    }
    if o == .STORE {
        if inst(i).ord1 == 0 && at_least_atomic return NONE;
        sp := strip_pointer_casts(op(i, 1));
        if !ld_equivalent_address_values(sp, ptr) return NONE;
        if is_load_cse is_load_cse.* = false;
        val := op(i, 0);
        if is_bit_or_noop_pointer_castable(vtype(val), access_ty) return val;
        ssz := dl_type_size_bits(vtype(val)); lsz := dl_type_size_bits(access_ty);
        sscal := type_is_scalable(vtype(val)); lscal := type_is_scalable(access_ty);
        // TypeSize::isKnownLE(LoadSize, StoreSize)
        known_le := lsz <= ssz && (!lscal || sscal);
        if known_le && is_const(val) return cfo_load_from_const(val, access_ty, ap_zero(64));
    }
    if is_mem_set_inst(i) {
        if at_least_atomic return NONE;
        val := call_arg(i, 1); len := call_arg(i, 2);
        if vkind(val) != .C_INT || is_vector_type(vtype(val)) || vkind(len) != .C_INT || is_vector_type(vtype(len)) return NONE;
        store_base, store_off := get_pointer_base_with_constant_offset(call_arg(i, 0));
        load_base, load_off := get_pointer_base_with_constant_offset(ptr);
        if store_base != load_base || load_off < store_off return NONE;
        if is_load_cse is_load_cse.* = false;
        if type_is_scalable(access_ty) return NONE;
        load_size := dl_type_size_bits(access_ty);
        lenv := const_ap(len);
        lhs := ap_mul(lenv, ap_from_u64(lenv.bits, 8));
        // APInt::ult(uint64_t): the right side is not truncated to the length's width
        rhs := load_size + cast(u64)(load_off - store_off) * 8;
        if ap_active_bits(lhs) <= 64 && ap_zext_value(lhs) < rhs return NONE;
        vv := const_ap(val);
        splat: APInt;
        if load_size >= 8 splat = ap_get_splat(cast(u32) load_size, vv);
        else splat = ap_trunc(vv, cast(u32) load_size);
        sc := const_int_ap(type_int(cast(u32) load_size), splat);
        if is_bit_or_noop_pointer_castable(vtype(sc), access_ty) return sc;
        return NONE;
    }
    return NONE;
}
// APInt::getSplat(NewLen, V)
ap_get_splat :: (new_len: u32, v: APInt) -> APInt {
    r := ap_zero(new_len);
    i: u32 = 0;
    while i < new_len {
        r = ap_insert_bits_trunc(r, v, i);
        i += v.bits;
    }
    return r;
}
// r |= zext(v) << pos, truncated to r's width
ap_insert_bits_trunc :: (r: APInt, v: APInt, pos: u32) -> APInt {
    w := ap_shl(ap_zext_or_trunc(v, r.bits), pos);
    return ap_or(r, w);
}
is_mem_set_inst :: (i: Value_Id) -> bool { id := call_iid(i); return id == IID_MEMSET || id == IID_MEMSET_INLINE; }

// FindAvailableLoadedValue(Load, BatchAA, IsLoadCSE, MaxInstsToScan = DefMaxInstsToScan)
find_available_loaded_value :: (load: Value_Id, aaq: *Aa_Query, is_load_cse: *bool, max_insts_to_scan: u32 = 6) -> Value_Id {
    stripped := strip_pointer_casts(op(load, 0));
    access_ty := vtype(load);
    at_least_atomic := inst(load).ord1 != 0;
    if !is_unordered(load) return NONE;
    available: Value_Id = NONE;
    must_not_alias: [..] Value_Id; must_not_alias.allocator = temp;
    left := max_insts_to_scan;
    i := inst(load).prev;
    while i != NONE {
        defer i = inst(i).prev;
        if is_debug_or_pseudo_inst(i) continue;
        if left == 0 return NONE;
        left -= 1;
        available = get_available_load_store(i, stripped, access_ty, at_least_atomic, is_load_cse);
        if available != NONE break;
        if may_write_to_memory(i) array_add(*must_not_alias, i);
    }
    if available != NONE {
        loc := mloc_get(load);
        for must_not_alias if mr_is_mod_set(aa_mod_ref_inst_loc(aaq, it, loc)) return NONE;
    }
    return available;
}
mr_is_mod_set :: inline (mr: u8) -> bool { return (mr & MR_MOD) != 0; }

// Instruction::isIdenticalToWhenDefined: isIdenticalTo without SubclassOptionalData (wrap/exact/disjoint/nneg/
// samesign, GEP no-wrap flags, fast-math flags)
is_identical_to_when_defined :: (a: Value_Id, b: Value_Id) -> bool {
    if inst_op(a) != inst_op(b) || vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    for k: 0..cast(s64) nops(a) - 1 if op(a, cast(u32) k) != op(b, cast(u32) k) return false;
    if inst_op(a) == .PHI {
        for k: 0..cast(s64) nops(a) - 1 if phi_block(a, cast(u32) k) != phi_block(b, cast(u32) k) return false;
        return true;
    }
    OPTIONAL :: cast(u32)(F_NUW | F_NSW | F_EXACT | F_INBOUNDS | F_NUSW | F_GEP_NUW) | (cast(u32) FMF_ALL << FMF_SHIFT);
    ra := inst(a); rb := inst(b);
    if (ra.flags & ~OPTIONAL) != (rb.flags & ~OPTIONAL) || ra.pred != rb.pred || ra.ty2 != rb.ty2 || ra.align != rb.align ||
       ra.attrs != rb.attrs || ra.cc != rb.cc || ra.ord1 != rb.ord1 || ra.ord2 != rb.ord2 || ra.nidx != rb.nidx || ra.sync != rb.sync return false;
    if ra.nidx > 0 for k: 0..ra.nidx-1 if ir.u32_pool[ra.idx + k] != ir.u32_pool[rb.idx + k] return false;
    return true;
}
