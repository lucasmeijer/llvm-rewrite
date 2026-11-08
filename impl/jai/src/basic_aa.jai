// BasicAA: a port of llvm/lib/Analysis/BasicAliasAnalysis.cpp (DecomposeGEPExpression, GetLinearExpression,
// aliasCheck / aliasCheckRecursive / aliasGEP / aliasPHI / aliasSelect with the AAQueryInfo cache and its
// assumption tracking, getModRefInfo for calls, getModRefInfoMask, getMemoryEffects, aliasErrno) and of the
// object-size helpers it uses from llvm/lib/Analysis/MemoryBuiltins.cpp (getBaseObjectSize, getAllocSize).
//
// Stateless like LLVM's: everything it needs comes from the Aa_Query (cache, depth, MayBeCrossIteration, capture
// analysis) and its Aa_Results (function, DominatorTree, AssumptionCache). APInts are in `temp`.

BASIC_AA_MAX_LOOKUP :: 10;   // MaxLookupSearchDepth (ValueTracking.h)
basic_aa_opts: struct {
    rec_phi := true;            // -basic-aa-recphi
    separate_storage := true;   // -basic-aa-separate-storage
};

// ---------------------------------------------------------------- object sizes

// getAllocSize(CB, TLI) without a Mapper: (known, size in the index width)
get_alloc_size :: (cb: Value_Id) -> (bool, APInt) {
    bits := dl_index_type_size_bits(vtype(cb));
    fst: s32 = -1; snd: s32 = -1; strdup_like := false;
    callee := mb_called_function(cb);
    found := false;
    if callee != NONE {
        ft := glob(callee).value_type;
        if is_ptr_type(func_ret(ft)) && !glob(callee).intrinsic && tli_available(value_function(cb), vname(callee)) {
            for ALLOC_FNS {
                if it.name != vname(callee) continue;
                if func_nparams(ft) != cast(u32) it.nparams break;
                if it.fst >= 0 && !is_int32_or_64(func_param(ft, cast(u32) it.fst)) break;
                if it.snd >= 0 && !is_int32_or_64(func_param(ft, cast(u32) it.snd)) break;
                fst = it.fst; snd = it.snd; found = true;
                strdup_like = contains(it.name, "strdup") || contains(it.name, "strndup");
                break;
            }
        }
    }
    if !found {
        a := call_get_fn_attr(cb, .AllocSize);
        if !a return false, .{};
        // allocsize(ElemSizeArg[, NumElemsArg]): packed as (first << 32) | (second or 0xFFFFFFFF)
        fst = cast(s32)(a.ival >> 32);
        s := a.ival & 0xFFFF_FFFF;
        snd = ifx s == 0xFFFF_FFFF then -1 else cast(s32) s;
    }
    if strdup_like fatal("BasicAA: object size of strdup-like calls (GetStringLength) is not supported yet");
    arg := call_arg(cb, cast(u32) fst);
    if !is_scalar_const_int(arg) return false, .{};
    size := const_ap(arg);
    if size.bits > bits { if ap_active_bits(size) > bits return false, .{}; size = ap_trunc(size, bits); }
    else size = ap_zext(size, bits);
    if snd < 0 return true, size;
    arg2 := call_arg(cb, cast(u32) snd);
    if !is_scalar_const_int(arg2) return false, .{};
    ne := const_ap(arg2);
    if ne.bits > bits { if ap_active_bits(ne) > bits return false, .{}; ne = ap_trunc(ne, bits); }
    else ne = ap_zext(ne, bits);
    r, ov := ap_umul_ov(size, ne);
    if ov return false, .{};
    return true, r;
}

// getBaseObjectSize(Ptr, DL, TLI, Opts{RoundToAlign, NullIsUnknownSize}) (fixed sizes only: BasicAA's getObjectSize
// drops scalable ones)
get_base_object_size :: (v: Value_Id, round_to_align: bool, null_is_unknown: bool) -> (bool, u64) {
    al :: (size: u64, align: u64, round: bool) -> u64 {
        if round && align > 0 return align_to(size, align);
        return size;
    }
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return true, 0;
    if k == .C_NULL {
        if null_is_unknown || ir.types[vtype(v)].a != 0 return false, 0;
        return true, 0;
    }
    if k == .GLOBAL_VAR {
        g := glob(v);
        if !type_is_sized(g.value_type) || g.linkage == .EXTERN_WEAK || !g.has_init || gv_is_interposable(v) return false, 0;
        return true, al(dl_type_alloc_size(g.value_type), g.align, round_to_align);
    }
    if k == .ARGUMENT {
        mt := arg_pointee_in_memory_value_type(v);
        if mt == NONE || !type_is_sized(mt) return false, 0;
        if type_is_scalable(mt) return false, 0;
        pa := attr_set_find(arg_attrs(v), .Alignment);
        return true, al(dl_type_alloc_size(mt), ifx pa then pa.ival else 0, round_to_align);
    }
    if is_inst(v) && inst_op(v) == .ALLOCA {
        ok, sz := alloca_allocation_size(v);
        if !ok return false, 0;
        return true, al(sz, inst(v).align, round_to_align);
    }
    if is_inst(v) && is_call_base(v) {
        ok, sz := get_alloc_size(v);
        if ok && ap_active_bits(sz) <= 64 return true, ap_zext_value(sz);
        return false, 0;
    }
    return false, 0;
}

// isObjectSmallerThan(V, Size, DL, TLI, NullIsValidLoc)
is_object_smaller_than :: (v: Value_Id, size: u64, null_is_valid: bool) -> bool {
    if !is_identified_object(v) return false;
    ok, osz := get_base_object_size(v, true, null_is_valid);
    return ok && osz < size;
}
// getMinimalExtentFrom(V, LocSize, DL, NullIsValidLoc)
get_minimal_extent_from :: (v: Value_Id, loc_size: u64, null_is_valid: bool) -> u64 {
    can_be_null, deref := pointer_dereferenceable_bytes(v);
    if can_be_null && null_is_valid deref = 0;
    if ls_is_precise(loc_size) deref = max(deref, ls_value(loc_size));
    return deref;
}
// isObjectSize(V, Size, ...): Size is a precise LocationSize value (scalable sizes never match a fixed object)
is_object_size :: (v: Value_Id, size: u64, null_is_valid: bool) -> bool {
    if ls_is_scalable(size) return false;
    ok, osz := get_base_object_size(v, false, null_is_valid);
    return ok && osz == ls_value(size);
}
is_vscale_call :: (v: Value_Id) -> bool { return call_iid(v) == IID_VSCALE; }
are_both_vscale :: (a: Value_Id, b: Value_Id) -> bool { return is_vscale_call(a) && is_vscale_call(b); }

// ---------------------------------------------------------------- CastedValue / LinearExpression

Casted_Value :: struct {   // zext(sext(trunc(V)))
    v: Value_Id;
    zext_bits: u32;
    sext_bits: u32;
    trunc_bits: u32;
    is_non_negative: bool;
}
cv_of :: (v: Value_Id) -> Casted_Value { c: Casted_Value; c.v = v; return c; }
prim_bits :: (v: Value_Id) -> u32 { return type_bits(vtype(v)); }
cv_bit_width :: (c: Casted_Value) -> u32 { return prim_bits(c.v) - c.trunc_bits + c.zext_bits + c.sext_bits; }
cv_with_value :: (c: Casted_Value, nv: Value_Id, preserve_non_neg: bool) -> Casted_Value {
    r := c; r.v = nv; r.is_non_negative = c.is_non_negative && preserve_non_neg; return r;
}
cv_with_zext_of_value :: (c: Casted_Value, nv: Value_Id, zext_non_negative: bool) -> Casted_Value {
    extend_by := prim_bits(c.v) - prim_bits(nv);
    r: Casted_Value; r.v = nv;
    if extend_by <= c.trunc_bits {
        r.zext_bits = c.zext_bits; r.sext_bits = c.sext_bits; r.trunc_bits = c.trunc_bits - extend_by;
        r.is_non_negative = c.is_non_negative;
        return r;
    }
    extend_by -= c.trunc_bits;
    r.zext_bits = c.zext_bits + c.sext_bits + extend_by;
    r.is_non_negative = zext_non_negative;
    return r;
}
cv_with_sext_of_value :: (c: Casted_Value, nv: Value_Id) -> Casted_Value {
    extend_by := prim_bits(c.v) - prim_bits(nv);
    r: Casted_Value; r.v = nv;
    if extend_by <= c.trunc_bits {
        r.zext_bits = c.zext_bits; r.sext_bits = c.sext_bits; r.trunc_bits = c.trunc_bits - extend_by;
        r.is_non_negative = c.is_non_negative;
        return r;
    }
    extend_by -= c.trunc_bits;
    r.zext_bits = c.zext_bits; r.sext_bits = c.sext_bits + extend_by; r.is_non_negative = c.is_non_negative;
    return r;
}
cv_evaluate_ap :: (c: Casted_Value, n_in: APInt) -> APInt {
    n := n_in;
    if c.trunc_bits n = ap_trunc(n, n.bits - c.trunc_bits);
    if c.sext_bits n = ap_sext(n, n.bits + c.sext_bits);
    if c.zext_bits n = ap_zext(n, n.bits + c.zext_bits);
    return n;
}
cv_evaluate_cr :: (c: Casted_Value, n_in: Const_Range) -> Const_Range {
    n := n_in;
    if c.trunc_bits n = cr_truncate(n, cr_bits(n) - c.trunc_bits);
    if c.is_non_negative && !cr_is_all_non_negative(n) {
        bw := cr_bits(n);
        n = cr_intersect(n, cr_new(ap_zero(bw), ap_signed_min(bw)));
    }
    if c.sext_bits n = cr_sign_extend(n, cr_bits(n) + c.sext_bits);
    if c.zext_bits n = cr_zero_extend(n, cr_bits(n) + c.zext_bits);
    return n;
}
cv_can_distribute_over :: (c: Casted_Value, nuw: bool, nsw: bool) -> bool {
    return (c.zext_bits == 0 || nuw) && (c.sext_bits == 0 || nsw);
}
cv_has_same_casts_as :: (a: Casted_Value, b: Casted_Value) -> bool {
    if vtype(a.v) != vtype(b.v) return false;
    if a.zext_bits == b.zext_bits && a.sext_bits == b.sext_bits && a.trunc_bits == b.trunc_bits return true;
    if a.is_non_negative || b.is_non_negative
        return a.zext_bits + a.sext_bits == b.zext_bits + b.sext_bits && a.trunc_bits == b.trunc_bits;
    return false;
}

Linear_Expr :: struct {   // zext(sext(trunc(V))) * Scale + Offset
    val: Casted_Value;
    scale: APInt;
    offset: APInt;
    is_nuw: bool;
    is_nsw: bool;
}
le_of :: (c: Casted_Value) -> Linear_Expr {
    e: Linear_Expr; e.val = c; e.is_nuw = true; e.is_nsw = true;
    bw := cv_bit_width(c);
    e.scale = ap_one(bw); e.offset = ap_zero(bw);
    return e;
}
le_mul :: (e: Linear_Expr, other: APInt, mul_nuw: bool, mul_nsw: bool) -> Linear_Expr {
    nsw := e.is_nsw && (ap_is_one(other) || (mul_nsw && ap_is_zero(e.offset)));
    nuw := e.is_nuw && (ap_is_one(other) || mul_nuw);
    r: Linear_Expr; r.val = e.val; r.scale = ap_mul(e.scale, other); r.offset = ap_mul(e.offset, other);
    r.is_nuw = nuw; r.is_nsw = nsw;
    return r;
}

// GetLinearExpression(Val, DL, Depth, AC, DT)
get_linear_expression :: (val: Casted_Value, depth: u32) -> Linear_Expr {
    if depth == 6 return le_of(val);
    v := val.v;
    if is_scalar_const_int(v) {
        e: Linear_Expr; e.val = val; e.scale = ap_zero(cv_bit_width(val)); e.offset = cv_evaluate_ap(val, const_ap(v));
        e.is_nuw = true; e.is_nsw = true;
        return e;
    }
    if is_inst(v) && is_binary_op(inst_op(v)) && is_scalar_const_int(op(v, 1)) {
        rhs := cv_evaluate_ap(val, const_ap(op(v, 1)));
        nuw := true; nsw := true;
        if is_overflowing_binop(v) {
            nuw = nuw && (inst(v).flags & F_NUW) != 0;
            nsw = nsw && (inst(v).flags & F_NSW) != 0;
        }
        if !cv_can_distribute_over(val, nuw, nsw) return le_of(val);
        if val.trunc_bits { nuw = false; nsw = false; }
        e := le_of(val);
        o := inst_op(v);
        if o == {
            case .OR;
                if (inst(v).flags & F_EXACT) == 0 return le_of(val);   // disjoint
                #through;
            case .ADD;
                e = get_linear_expression(cv_with_value(val, op(v, 0), false), depth + 1);
                e.offset = ap_add(e.offset, rhs);
                e.is_nuw = e.is_nuw && nuw;
                e.is_nsw = e.is_nsw && nsw;
            case .SUB;
                e = get_linear_expression(cv_with_value(val, op(v, 0), false), depth + 1);
                e.offset = ap_sub(e.offset, rhs);
                e.is_nuw = false;
                e.is_nsw = e.is_nsw && nsw;
            case .MUL;
                e = le_mul(get_linear_expression(cv_with_value(val, op(v, 0), false), depth + 1), rhs, nuw, nsw);
            case .SHL;
                sh := ap_limited(rhs);
                if sh > cv_bit_width(val) return le_of(val);
                e = get_linear_expression(cv_with_value(val, op(v, 0), nsw), depth + 1);
                e.offset = ap_shl(e.offset, cast(u32) sh);
                e.scale = ap_shl(e.scale, cast(u32) sh);
                e.is_nuw = e.is_nuw && nuw;
                e.is_nsw = e.is_nsw && nsw;
            case;
                return le_of(val);
        }
        return e;
    }
    if is_inst(v) && inst_op(v) == .ZEXT
        return get_linear_expression(cv_with_zext_of_value(val, op(v, 0), (inst(v).flags & F_EXACT) != 0), depth + 1);
    if is_inst(v) && inst_op(v) == .SEXT
        return get_linear_expression(cv_with_sext_of_value(val, op(v, 0)), depth + 1);
    return le_of(val);
}

// ---------------------------------------------------------------- DecomposedGEP

Var_Gep_Index :: struct {   // VariableGEPIndex
    val: Casted_Value;
    scale: APInt;
    cxt: Value_Id;
    is_nsw: bool;
    is_negated: bool;
}
vgi_has_negated_scale_of :: (a: Var_Gep_Index, b: Var_Gep_Index) -> bool {
    if a.is_negated == b.is_negated return ap_eq(a.scale, ap_neg(b.scale));
    return ap_eq(a.scale, b.scale);
}

Decomposed_Gep :: struct {
    base: Value_Id;
    offset: APInt;
    var_indices: [..] Var_Gep_Index;
    // GEPNoWrapFlags (start as all())
    inbounds := true;
    nusw := true;
    nuw := true;
}

// GEPOperator::getNoWrapFlags of an instruction or constant expression
gep_nw_flags :: (g: Value_Id) -> (inbounds: bool, nusw: bool, nuw: bool) {
    f := opr_flags(g);
    ib := (f & F_INBOUNDS) != 0;
    return ib, ib || (f & F_NUSW) != 0, (f & F_GEP_NUW) != 0;
}
// gep_type_iterator::getSequentialElementStride
gep_sequential_stride :: (indexed: Type_Id, cur: Type_Id, k: s64) -> u64 {
    if k > 1 && is_vector_type(cur) return dl_type_store_size(indexed);
    return dl_type_alloc_size(indexed);
}

// BasicAAResult::DecomposeGEPExpression
decompose_gep :: (v_in: Value_Id) -> Decomposed_Gep {
    d: Decomposed_Gep;
    d.var_indices.allocator = temp;
    v := v_in;
    cxt: Value_Id = ifx is_inst(v) then v else NONE;
    index_size := dl_index_type_size_bits(vtype(v));
    d.offset = ap_zero(index_size);
    max_lookup := BASIC_AA_MAX_LOOKUP;
    while true {
        o := opr_code(v);
        if o == .NONE_OP {
            if vkind(v) == .ALIAS && !gv_is_interposable(v) {
                v = op(v, 0);
                max_lookup -= 1; if max_lookup == 0 break;
                continue;
            }
            d.base = v;
            return d;
        }
        if o == .BITCAST || o == .ADDRSPACECAST {
            nv := op(v, 0);
            nt := vtype(nv);
            if !is_ptr_type(nt) || dl_index_type_size_bits(nt) != index_size { d.base = v; return d; }
            v = nv;
            max_lookup -= 1; if max_lookup == 0 break;
            continue;
        }
        if o != .GEP {
            if o == .PHI {
                if nops(v) == 1 {
                    v = phi_value(v, 0);
                    max_lookup -= 1; if max_lookup == 0 break;
                    continue;
                }
            } else if is_inst(v) && is_call_base(v) {
                rp := argument_aliasing_to_returned_pointer_aa(v, true);
                if rp != NONE {
                    v = rp;
                    max_lookup -= 1; if max_lookup == 0 break;
                    continue;
                }
            }
            d.base = v;
            return d;
        }
        ib, nusw_g, nuw_g := gep_nw_flags(v);
        d.inbounds = d.inbounds && ib; d.nusw = d.nusw && nusw_g; d.nuw = d.nuw && nuw_g;

        cur := opr_gep_source_type(v);
        n := nops(v);
        for k: 1..cast(s64) n - 1 {
            index := op(v, cast(u32) k);
            indexed := gep_indexed_type(cur, k, index);
            prev := cur;
            cur = indexed;
            if k > 1 && type_kind(prev) == .STRUCT {
                field := ap_zext_value(const_ap(index));
                if field == 0 continue;
                d.offset = ap_add(d.offset, ap_from_u64(index_size, dl_struct_offset(prev, cast(u32) field)));
                continue;
            }
            if is_scalar_const_int(index) {
                ci := const_ap(index);
                if ap_is_zero(ci) continue;
                if type_is_scalable(indexed) { d.base = v; return d; }
                stride := gep_sequential_stride(indexed, prev, k);
                d.offset = ap_add(d.offset, ap_mul(ap_from_u64(index_size, stride), ap_sext_or_trunc(ci, index_size)));
                continue;
            }
            if type_is_scalable(indexed) { d.base = v; return d; }
            nusw := nusw_g; nuw := nuw_g;
            non_neg := nusw && nuw;
            width := type_int_width(vtype(index));
            c := cv_of(index);
            c.sext_bits = ifx index_size > width then index_size - width else 0;
            c.trunc_bits = ifx index_size < width then width - index_size else 0;
            c.is_non_negative = non_neg;
            le := get_linear_expression(c, 0);
            stride := gep_sequential_stride(indexed, prev, k);
            le = le_mul(le, ap_from_u64(index_size, stride), nuw, nusw);
            d.offset = ap_add(d.offset, le.offset);
            scale := le.scale;
            if !le.is_nuw d.nuw = false;
            for i: 0..d.var_indices.count-1 {
                vi := d.var_indices[i];
                if (vi.val.v == le.val.v || are_both_vscale(vi.val.v, le.val.v)) && cv_has_same_casts_as(vi.val, le.val) {
                    scale = ap_add(scale, vi.scale);
                    le.is_nsw = false; le.is_nuw = false;
                    array_ordered_remove_by_index(*d.var_indices, i);
                    break;
                }
            }
            if !ap_is_zero(scale) {
                e: Var_Gep_Index; e.val = le.val; e.scale = scale; e.cxt = cxt; e.is_nsw = le.is_nsw; e.is_negated = false;
                array_add(*d.var_indices, e);
            }
        }
        v = op(v, 0);
        max_lookup -= 1;
        if max_lookup == 0 break;
    }
    d.base = v;
    return d;
}

// getArgumentAliasingToReturnedPointer(Call, MustPreserveOffset)
argument_aliasing_to_returned_pointer_aa :: (c: Value_Id, must_preserve_offset: bool) -> Value_Id {
    rv := call_returned_arg(c);
    if rv != NONE return rv;
    if intrinsic_returns_aliasing_arg_without_capturing(c, must_preserve_offset) return call_arg(c, 0);
    return NONE;
}

// Value::stripPointerCastsForAliasAnalysis
strip_pointer_casts_for_alias_analysis :: (v_in: Value_Id) -> Value_Id {
    v := v_in;
    if !is_ptr_type(vtype(v)) return v;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*visited, v);
    while true {
        o := opr_code(v);
        if o == .GEP {
            if !gep_has_all_zero_indices_v(v) return v;
            v = op(v, 0);
        } else if o == .BITCAST {
            nv := op(v, 0);
            if !is_ptr_type(vtype(nv)) return v;
            v = nv;
        } else if o == .ADDRSPACECAST {
            v = op(v, 0);
        } else if o == .PHI && nops(v) == 1 {
            v = phi_value(v, 0);
        } else {
            if is_inst(v) && is_call_base(v) {
                rv := call_returned_arg(v);
                if rv != NONE { v = rv; }
                else {
                    id := call_iid_any(v);
                    if id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP v = call_arg(v, 0);
                    else return v;
                }
            } else return v;
        }
        for visited if it == v return v;
        array_add(*visited, v);
    }
    return v;
}

// ---------------------------------------------------------------- mod/ref

// BasicAAResult::getModRefInfoMask
basic_aa_mod_ref_mask :: (q: *Aa_Query, loc: Mem_Loc, ignore_locals: bool) -> u8 {
    max_lookup := 8;
    worklist: [..] Value_Id; worklist.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*worklist, loc.ptr);
    result := MR_NO;
    while true {
        v := get_underlying_object(pop(*worklist));
        seen := false;
        for visited if it == v { seen = true; break; }
        if !seen {
            array_add(*visited, v);
            handled := false;
            if ignore_locals && is_inst(v) && inst_op(v) == .ALLOCA handled = true;
            else if vkind(v) == .ARGUMENT && arg_has_attr(v, .NoAlias) && arg_only_reads_memory(v) {
                result |= MR_REF;
                handled = true;
            } else if vkind(v) == .GLOBAL_VAR {
                if !glob(v).is_const return MR_MODREF;
                handled = true;
            } else if is_inst(v) && inst_op(v) == .SELECT {
                array_add(*worklist, op(v, 1));
                array_add(*worklist, op(v, 2));
                handled = true;
            } else if is_phi(v) {
                if nops(v) > cast(u32) max_lookup return MR_MODREF;
                for k: 0..nops(v)-1 array_add(*worklist, phi_value(v, k));
                handled = true;
            }
            if !handled return MR_MODREF;
        }
        max_lookup -= 1;
        if worklist.count == 0 || max_lookup == 0 break;
    }
    if worklist.count return MR_MODREF;
    return result;
}
// Argument::onlyReadsMemory
arg_only_reads_memory :: (a: Value_Id) -> bool {
    s := arg_attrs(a);
    return attr_set_has(s, .ReadOnly) || attr_set_has(s, .ReadNone);
}

// BasicAAResult::getMemoryEffects(Call, AAQI)
basic_aa_memory_effects_call :: (q: *Aa_Query, call: Value_Id) -> u64 {
    mn := attr_set_memory(call_fn_attrs(call));
    f := call_called_operand_fn(call);
    if f != NONE {
        fme := aa_memory_effects_fn(q, f);
        if call_has_reading_bundles(call) fme |= me_read_only();
        if call_has_clobbering_bundles(call) fme |= me_write_only();
        if is_volatile(call) fme |= me_loc(LOC_INACCESSIBLE, MR_MODREF);
        mn &= fme;
    }
    return mn;
}
// BasicAAResult::getMemoryEffects(F)
basic_aa_memory_effects_fn :: (f: Value_Id) -> u64 {
    id := fn_iid(f);
    if id == IID_EXPERIMENTAL_GUARD || id == IID_EXPERIMENTAL_DEOPTIMIZE
        return me_read_only() | me_loc(LOC_INACCESSIBLE, MR_MODREF);
    return attr_set_memory(attr_list_fn(glob(f).attrs));
}
// BasicAAResult::getArgModRefInfo
basic_aa_arg_mod_ref :: (call: Value_Id, idx: u32) -> u8 {
    if call_data_operand_does_not_access(call, idx) return MR_NO;
    if call_data_operand_only_writes(call, idx) return MR_MOD;
    if call_data_operand_only_reads(call, idx) return MR_REF;
    return MR_MODREF;
}

// CallBase::maySynchronize? (Instruction::maySynchronize for calls: !nosync)
call_may_synchronize :: (c: Value_Id) -> bool { return !call_has_fn_attr(c, .NoSync); }
call_is_inline_asm :: (c: Value_Id) -> bool { return vkind(call_callee(c)) == .INLINE_ASM; }
call_has_attr_somewhere :: (c: Value_Id, k: Attr_Kind) -> bool {
    l := inst(c).attrs;
    if attr_set_has(attr_list_fn(l), k) || attr_set_has(attr_list_ret(l), k) return true;
    if l != 0 for ir.attr_lists[l].params if attr_set_has(it, k) return true;
    return false;
}

// BasicAAResult::getModRefInfo(const CallBase *Call, const MemoryLocation &Loc, AAQI)
basic_aa_mod_ref_call_loc :: (q: *Aa_Query, call: Value_Id, loc: Mem_Loc) -> u8 {
    object := get_underlying_object(loc.ptr);
    is_alloca := is_inst(object) && inst_op(object) == .ALLOCA;
    if is_alloca && inst_op(call) == .CALL {
        tail := (inst(call).flags >> TAIL_SHIFT) & 3;
        if (tail == 1 || tail == 2) && !call_has_attr_somewhere(call, .ByVal) return MR_NO;
    }
    if is_alloca && !is_static_alloca(object) && call_iid(call) == IID_STACKRESTORE return MR_MOD;

    me := me_without_loc(aa_memory_effects_call(q, call), LOC_INACCESSIBLE);
    if me == 0 return MR_NO;
    arg_mr := me_get(me, LOC_ARG);
    errno_mr := me_get(me, LOC_ERRNO);
    other_mr := me_get(me, LOC_OTHER);

    sync_mr := MR_NO;
    if other_mr == MR_MODREF && call_may_synchronize(call) && call_is_inline_asm(call) {
        sync_mr = aa_sync_effects(q, loc);
        if sync_mr == MR_MODREF return sync_mr;
    }

    if other_mr != MR_NO && !is_const(object) && call != object && (is_alloca || !call_has_fn_attr(call, .ReturnsTwice)) {
        cc := aa_captures_before(q, object, call, false, false);
        if cc == CC_NONE other_mr = MR_NO;
        else if cc_captures_read_provenance_only(cc) other_mr = MR_REF;
    }

    if (arg_mr | other_mr) != other_mr {
        new_arg_mr := MR_NO;
        nd := nops(call) - call_non_data_operands(call);
        na := call_num_args(call);
        if nd > 0 for k: 0..nd-1 {
            a := op(call, k);
            if !is_ptr_type(vtype(a)) continue;
            arg_loc := ifx k < na then mloc_for_argument(call, k, true) else mloc_before_or_after(a);
            if aa_alias(q, arg_loc, loc, call).kind != AR_NO new_arg_mr |= arg_mr & aa_arg_mod_ref(q, call, k);
            if new_arg_mr == arg_mr break;
        }
        arg_mr = new_arg_mr;
    }

    result := arg_mr | other_mr | sync_mr;
    if (errno_mr | result) != result {
        if aa_alias_errno(q, loc) != AR_NO result |= errno_mr;
    }
    if result != MR_MODREF return result;

    if is_malloc_or_calloc_like_fn(call) {
        if aa_alias(q, mloc_before_or_after(call), loc).kind == AR_NO return MR_NO;
    }
    if call_iid(call) == IID_INVARIANT_START return MR_REF;
    return MR_MODREF;
}

// BasicAAResult::getModRefInfo(const CallBase *Call1, const CallBase *Call2, AAQI)
basic_aa_mod_ref_call_call :: (q: *Aa_Query, call1: Value_Id, call2: Value_Id) -> u8 {
    if call_iid(call1) == IID_EXPERIMENTAL_GUARD
        return ifx (me_mod_ref(basic_aa_memory_effects_call(q, call2)) & MR_MOD) != 0 then MR_REF else MR_NO;
    if call_iid(call2) == IID_EXPERIMENTAL_GUARD
        return ifx (me_mod_ref(basic_aa_memory_effects_call(q, call1)) & MR_MOD) != 0 then MR_MOD else MR_NO;
    return MR_MODREF;
}

// BasicAAResult::aliasErrno
basic_aa_alias_errno :: (loc: Mem_Loc) -> u8 {
    if ls_has_value(loc.size) && ls_value(loc.size) * 8 > TLI_INT_SIZE return AR_NO;
    if is_identified_function_local(get_underlying_object(loc.ptr)) return AR_NO;
    return AR_MAY;
}

// ---------------------------------------------------------------- alias

basic_aa_dt :: (q: *Aa_Query) -> *Dom_Tree { return ifx q.use_dominator_tree then q.aar.dt else null; }

// BasicAAResult::alias
basic_aa_alias :: (q: *Aa_Query, a: Mem_Loc, b: Mem_Loc, ctx: Value_Id) -> Alias_Result {
    return basic_alias_check(q, a.ptr, a.size, b.ptr, b.size, ctx);
}

// isValueEqualInPotentialCycles
is_value_equal_in_potential_cycles :: (q: *Aa_Query, v: Value_Id, v2: Value_Id) -> bool {
    if v != v2 return false;
    if !q.may_be_cross_iteration return true;
    if !is_inst(v) || inst_block(v) == fn_entry(inst_fn(v)) return true;
    return aa_is_not_in_cycle(v, basic_aa_dt(q));
}

is_argument_or_argument_like :: (v: Value_Id) -> bool {
    if vkind(v) == .ARGUMENT return true;
    return is_inst(v) && inst_op(v) == .EXTRACTVALUE && vkind(op(v, 0)) == .ARGUMENT;
}

// BasicAAResult::aliasCheck
basic_alias_check :: (q: *Aa_Query, v1_in: Value_Id, v1_size_in: u64, v2_in: Value_Id, v2_size_in: u64, ctx: Value_Id) -> Alias_Result {
    v1_size := v1_size_in; v2_size := v2_size_in;
    if ls_is_zero(v1_size) || ls_is_zero(v2_size) return ar(AR_NO);
    v1 := strip_pointer_casts_for_alias_analysis(v1_in);
    v2 := strip_pointer_casts_for_alias_analysis(v2_in);
    k1 := vkind(v1); k2 := vkind(v2);
    if k1 == .C_UNDEF || k1 == .C_POISON || k2 == .C_UNDEF || k2 == .C_POISON return ar(AR_NO);
    if is_value_equal_in_potential_cycles(q, v1, v2) return ar(AR_MUST);

    o1 := get_underlying_object(v1, BASIC_AA_MAX_LOOKUP);
    o2 := get_underlying_object(v2, BASIC_AA_MAX_LOOKUP);
    f := q.aar.f;
    if vkind(o1) == .C_NULL && !null_pointer_is_defined(f, ir.types[vtype(o1)].a) return ar(AR_NO);
    if vkind(o2) == .C_NULL && !null_pointer_is_defined(f, ir.types[vtype(o2)].a) return ar(AR_NO);

    if o1 != o2 {
        if is_identified_object(o1) && is_identified_object(o2) return ar(AR_NO);
        if (is_argument_or_argument_like(o1) && is_identified_function_local(o2)) ||
           (is_argument_or_argument_like(o2) && is_identified_function_local(o1)) return ar(AR_NO);
        if is_escape_source(o1) && aa_captures_before(q, o2, ifx is_inst(o1) then o1 else NONE, true, false) == CC_NONE return ar(AR_NO);
        if is_escape_source(o2) && aa_captures_before(q, o1, ifx is_inst(o2) then o2 else NONE, true, false) == CC_NONE return ar(AR_NO);
    }

    null_is_valid := null_pointer_is_defined(f);
    if is_object_smaller_than(o2, get_minimal_extent_from(v1, v1_size, null_is_valid), null_is_valid) ||
       is_object_smaller_than(o1, get_minimal_extent_from(v2, v2_size, null_is_valid), null_is_valid) return ar(AR_NO);

    if basic_aa_opts.separate_storage && q.aar.ac {
        for e: ac_assumptions_for(q.aar.ac, o1) {
            if vkind(e.assume) == .DEAD || e.index == AC_EXPR_RESULT_IDX continue;
            assume := e.assume;
            if call_bundle_tag(assume, e.index) != "separate_storage" continue;
            b := ir.u32_pool[inst(assume).idx + 3 * e.index + 1];
            hint1 := op(assume, b); hint2 := op(assume, b + 1);
            ho1 := get_underlying_object(hint1); ho2 := get_underlying_object(hint2);
            dt := basic_aa_dt(q);
            valid_for_ptr :: (assume: Value_Id, p: Value_Id, dt: *Dom_Tree) -> bool {
                if is_inst(p) return is_valid_assume_for_context(assume, p, dt, true);
                if vkind(p) == .ARGUMENT return is_valid_assume_for_context(assume, block(fn_entry(arg_parent(p))).first, dt, true);
                return false;
            }
            if (o1 == ho1 && o2 == ho2) || (o1 == ho2 && o2 == ho1) {
                if (ctx != NONE && is_valid_assume_for_context(assume, ctx, dt, true)) || valid_for_ptr(assume, v1, dt) || valid_for_ptr(assume, v2, dt)
                    return ar(AR_NO);
            }
        }
    }

    if ls_may_be_before_pointer(v1_size) || ls_may_be_before_pointer(v2_size) {
        v1_size = LS_AFTER; v2_size = LS_AFTER;
    }
    if q.depth >= 512 return ar(AR_MAY);

    mbci: u32 = ifx q.may_be_cross_iteration then cast(u32) 1 else 0;
    key: Aa_Pair;
    swapped := v1 > v2;
    if !swapped { key.v1 = v1; key.s1 = v1_size; key.c1 = mbci; key.v2 = v2; key.s2 = v2_size; key.c2 = mbci; }
    else { key.v1 = v2; key.s1 = v2_size; key.c1 = mbci; key.v2 = v1; key.s2 = v1_size; key.c2 = mbci; }
    e := table_find_pointer(*q.cache, key);
    if e {
        if e.num_assumption_uses != AA_CACHE_DEFINITIVE {
            q.num_assumption_uses += 1;
            if e.num_assumption_uses >= 0 e.num_assumption_uses += 1;
        }
        r := e.result;
        ar_swap(*r, swapped);
        return r;
    }
    ne: Aa_Cache_Entry; ne.result = ar(AR_NO); ne.num_assumption_uses = 0;
    table_set(*q.cache, key, ne);

    orig_num_assumption_uses := q.num_assumption_uses;
    orig_num_assumption_based := q.assumption_based.count;
    result := basic_alias_check_recursive(q, v1, v1_size, v2, v2_size, o1, o2);

    e = table_find_pointer(*q.cache, key);
    assert(e != null, "BasicAA: cache entry vanished");
    assumption_disproven := e.num_assumption_uses > 0 && result.kind != AR_NO;
    if assumption_disproven result = ar(AR_MAY);
    q.num_assumption_uses -= e.num_assumption_uses;
    e.result = result;
    ar_swap(*e.result, swapped);
    if assumption_disproven {
        while q.assumption_based.count > orig_num_assumption_based {
            k := pop(*q.assumption_based);
            table_remove(*q.cache, k);
        }
        e = table_find_pointer(*q.cache, key);
    }
    if orig_num_assumption_uses != q.num_assumption_uses && result.kind != AR_MAY {
        array_add(*q.assumption_based, key);
        e.num_assumption_uses = AA_CACHE_ASSUMPTION_BASED;
    } else {
        e.num_assumption_uses = AA_CACHE_DEFINITIVE;
    }
    if q.depth == 1 {
        for q.assumption_based {
            x := table_find_pointer(*q.cache, it);
            if x x.num_assumption_uses = AA_CACHE_DEFINITIVE;
        }
        q.assumption_based.count = 0;
        q.num_assumption_uses = 0;
    }
    return result;
}

// BasicAAResult::aliasCheckRecursive
basic_alias_check_recursive :: (q: *Aa_Query, v1: Value_Id, v1_size: u64, v2: Value_Id, v2_size: u64, o1: Value_Id, o2: Value_Id) -> Alias_Result {
    if opr_code(v1) == .GEP {
        r := basic_alias_gep(q, v1, v1_size, v2, v2_size, o1, o2);
        if r.kind != AR_MAY return r;
    } else if opr_code(v2) == .GEP {
        r := basic_alias_gep(q, v2, v2_size, v1, v1_size, o2, o1);
        ar_swap(*r);
        if r.kind != AR_MAY return r;
    }
    if is_phi(v1) {
        r := basic_alias_phi(q, v1, v1_size, v2, v2_size);
        if r.kind != AR_MAY return r;
    } else if is_phi(v2) {
        r := basic_alias_phi(q, v2, v2_size, v1, v1_size);
        ar_swap(*r);
        if r.kind != AR_MAY return r;
    }
    if is_inst(v1) && inst_op(v1) == .SELECT {
        r := basic_alias_select(q, v1, v1_size, v2, v2_size);
        if r.kind != AR_MAY return r;
    } else if is_inst(v2) && inst_op(v2) == .SELECT {
        r := basic_alias_select(q, v2, v2_size, v1, v1_size);
        ar_swap(*r);
        if r.kind != AR_MAY return r;
    }
    if o1 == o2 {
        null_is_valid := null_pointer_is_defined(q.aar.f);
        if ls_is_precise(v1_size) && ls_is_precise(v2_size) &&
           (is_object_size(o1, v1_size, null_is_valid) || is_object_size(o2, v2_size, null_is_valid))
            return ar(AR_PARTIAL);
    }
    return ar(AR_MAY);
}

// MergeAliasResults
merge_alias_results :: (a: Alias_Result, b: Alias_Result) -> Alias_Result {
    if ar_eq(a, b) return a;
    if (a.kind == AR_PARTIAL && b.kind == AR_MUST) || (b.kind == AR_PARTIAL && a.kind == AR_MUST) return ar(AR_PARTIAL);
    return ar(AR_MAY);
}

// BasicAAResult::aliasSelect
basic_alias_select :: (q: *Aa_Query, si: Value_Id, si_size: u64, v2: Value_Id, v2_size: u64) -> Alias_Result {
    if is_inst(v2) && inst_op(v2) == .SELECT && is_value_equal_in_potential_cycles(q, op(si, 0), op(v2, 0)) {
        a := aa_alias(q, mloc(op(si, 1), si_size), mloc(op(v2, 1), v2_size));
        if a.kind == AR_MAY return ar(AR_MAY);
        t := aa_alias(q, mloc(op(si, 2), si_size), mloc(op(v2, 2), v2_size));
        return merge_alias_results(t, a);
    }
    a := aa_alias(q, mloc(op(si, 1), si_size), mloc(v2, v2_size));
    if a.kind == AR_MAY return ar(AR_MAY);
    t := aa_alias(q, mloc(op(si, 2), si_size), mloc(v2, v2_size));
    return merge_alias_results(t, a);
}

// PHINode::getIncomingValueForBlock
phi_incoming_value_for_block :: (p: Value_Id, b: Value_Id) -> Value_Id {
    idx := phi_block_index(p, b);
    assert(idx >= 0, "phi has no incoming value for the block");
    return phi_value(p, cast(u32) idx);
}

// BasicAAResult::aliasPHI
basic_alias_phi :: (q: *Aa_Query, pn: Value_Id, pn_size_in: u64, v2: Value_Id, v2_size: u64) -> Alias_Result {
    pn_size := pn_size_in;
    n := nops(pn);
    if n == 0 return ar(AR_NO);
    if is_phi(v2) && inst_block(v2) == inst_block(pn) && !q.may_be_cross_iteration {
        alias: Alias_Result; have := false;
        for i: 0..n-1 {
            this := aa_alias(q, mloc(phi_value(pn, i), pn_size), mloc(phi_incoming_value_for_block(v2, phi_block(pn, i)), v2_size));
            if have alias = merge_alias_results(alias, this);
            else { alias = this; have = true; }
            if alias.kind == AR_MAY break;
        }
        return alias;
    }
    v1_srcs: [..] Value_Id; v1_srcs.allocator = temp;
    is_recursive := false;
    one_phi: Value_Id = NONE;
    for i: 0..n-1 {
        pv1 := phi_value(pn, i);
        if pv1 == pn continue;
        if is_phi(pv1) {
            if one_phi != NONE && one_phi != pv1 return ar(AR_MAY);
            one_phi = pv1;
        }
        if basic_aa_opts.rec_phi && get_underlying_object(pv1) == pn { is_recursive = true; continue; }
        seen := false;
        for v1_srcs if it == pv1 { seen = true; break; }
        if !seen array_add(*v1_srcs, pv1);
    }
    if one_phi != NONE && v1_srcs.count > 1 return ar(AR_MAY);
    if v1_srcs.count == 0 return ar(AR_MAY);
    if is_recursive pn_size = LS_BEFORE_OR_AFTER;

    saved := q.may_be_cross_iteration;
    q.may_be_cross_iteration = true;
    defer q.may_be_cross_iteration = saved;

    alias := aa_alias(q, mloc(v1_srcs[0], pn_size), mloc(v2, v2_size));
    if alias.kind == AR_MAY return ar(AR_MAY);
    if is_recursive && alias.kind != AR_NO return ar(AR_MAY);
    for i: 1..v1_srcs.count-1 {
        this := aa_alias(q, mloc(v1_srcs[i], pn_size), mloc(v2, v2_size));
        alias = merge_alias_results(this, alias);
        if alias.kind == AR_MAY break;
    }
    return alias;
}

// ConstantRange::smul_fast
cr_smul_fast :: (a: Const_Range, b: Const_Range) -> Const_Range {
    bw := cr_bits(a);
    if cr_is_empty_set(a) || cr_is_empty_set(b) return cr_empty(bw);
    mn := cr_smin(a); mx := cr_smax(a);
    omn := cr_smin(b); omx := cr_smax(b);
    m1, ov1 := ap_smul_ov(mn, omn);
    m2, ov2 := ap_smul_ov(mn, omx);
    m3, ov3 := ap_smul_ov(mx, omn);
    m4, ov4 := ap_smul_ov(mx, omx);
    if ov1 || ov2 || ov3 || ov4 return cr_full(bw);
    lo := m1; hi := m1;
    for x: APInt.[m2, m3, m4] { if ap_slt(x, lo) lo = x; if ap_sgt(x, hi) hi = x; }
    return cr_non_empty(lo, ap_add_u64(hi, 1));
}

// BasicAAResult::subtractDecomposedGEPs
subtract_decomposed_geps :: (q: *Aa_Query, dest: *Decomposed_Gep, src: *Decomposed_Gep) {
    if ap_ult(dest.offset, src.offset) dest.nuw = false;
    dest.offset = ap_sub(dest.offset, src.offset);
    for s: src.var_indices {
        found := false;
        for i: 0..dest.var_indices.count-1 {
            d := *dest.var_indices[i];
            if (!is_value_equal_in_potential_cycles(q, d.val.v, s.val.v) && !are_both_vscale(d.val.v, s.val.v)) ||
               !cv_has_same_casts_as(d.val, s.val) continue;
            if d.is_negated {
                d.scale = ap_neg(d.scale);
                d.is_negated = false;
                d.is_nsw = false;
            }
            if !ap_eq(d.scale, s.scale) {
                if ap_ult(d.scale, s.scale) dest.nuw = false;
                d.scale = ap_sub(d.scale, s.scale);
                d.is_nsw = false;
            } else {
                array_ordered_remove_by_index(*dest.var_indices, i);
            }
            found = true;
            break;
        }
        if !found {
            e: Var_Gep_Index; e.val = s.val; e.scale = s.scale; e.cxt = s.cxt; e.is_nsw = s.is_nsw; e.is_negated = true;
            array_add(*dest.var_indices, e);
            dest.nuw = false;
        }
    }
}

// BasicAAResult::constantOffsetHeuristic
constant_offset_heuristic :: (q: *Aa_Query, g: *Decomposed_Gep, v1s: u64, v2s: u64) -> bool {
    if g.var_indices.count != 2 || !ls_has_value(v1s) || !ls_has_value(v2s) return false;
    s1 := ls_value(v1s); s2 := ls_value(v2s);
    var0 := g.var_indices[0]; var1 := g.var_indices[1];
    if var0.val.trunc_bits != 0 || !cv_has_same_casts_as(var0.val, var1.val) || !vgi_has_negated_scale_of(var0, var1) ||
       vtype(var0.val.v) != vtype(var1.val.v) return false;
    e0 := get_linear_expression(cv_of(var0.val.v), 0);
    e1 := get_linear_expression(cv_of(var1.val.v), 0);
    if !ap_eq(e0.scale, e1.scale) || !cv_has_same_casts_as(e0.val, e1.val) || !is_value_equal_in_potential_cycles(q, e0.val.v, e1.val.v)
        return false;
    min_diff := ap_sub(e0.offset, e1.offset);
    wrapped := ap_neg(min_diff);
    min_diff = ap_umin(min_diff, wrapped);
    bw := var0.scale.bits;
    min_diff_bytes := ap_mul(ap_zext_or_trunc(min_diff, bw), ap_abs(var0.scale));
    goff := ap_abs(g.offset);
    return ap_uge(min_diff_bytes, ap_add(ap_from_u64(bw, s1), goff)) && ap_uge(min_diff_bytes, ap_add(ap_from_u64(bw, s2), goff));
}

// BasicAAResult::aliasGEP (V1 is a GEP; UnderlyingV1/V2 are the underlying objects)
basic_alias_gep :: (q: *Aa_Query, gep1: Value_Id, v1_size_in: u64, v2: Value_Id, v2_size_in: u64, u1_in: Value_Id, u2_in: Value_Id) -> Alias_Result {
    v1_size := v1_size_in; v2_size := v2_size_in; u1 := u1_in; u2 := u2_in;
    base_objects_alias :: (q: *Aa_Query, u1: Value_Id, u2: Value_Id) -> Alias_Result {
        r := aa_alias(q, mloc_before_or_after(u1), mloc_before_or_after(u2));
        return ifx r.kind == AR_NO then ar(AR_NO) else ar(AR_MAY);
    }
    is_gep_phi_select :: (v: Value_Id) -> bool {
        o := opr_code(v);
        return o == .GEP || (is_inst(v) && (o == .PHI || o == .SELECT));
    }
    if !ls_has_value(v1_size) && !ls_has_value(v2_size) {
        if is_inst(v2) && (inst_op(v2) == .PHI || inst_op(v2) == .SELECT) return ar(AR_MAY);
        if opr_code(v2) == .GEP || is_gep_phi_select(u1) || is_gep_phi_select(u2) return base_objects_alias(q, u1, u2);
        return ar(AR_MAY);
    }
    dt := basic_aa_dt(q);
    d1 := decompose_gep(gep1);
    d2 := decompose_gep(v2);
    if d1.base == gep1 && d2.base == v2 return ar(AR_MAY);
    if d1.offset.bits != d2.offset.bits return base_objects_alias(q, u1, u2);
    if d1.var_indices.count < d2.var_indices.count {
        d1, d2 = d2, d1;
        v1_size, v2_size = v2_size, v1_size;
        u1, u2 = u2, u1;
    }
    subtract_decomposed_geps(q, *d1, *d2);

    if d1.inbounds && d1.var_indices.count == 0 && ls_has_value(v2_size) && !ls_is_scalable(v2_size) &&
       ap_sge(d1.offset, ap_from_u64(d1.offset.bits, ls_value(v2_size))) && is_base_of_object(d2.base)
        return ar(AR_NO);
    if d2.inbounds && d1.var_indices.count == 0 && ls_has_value(v1_size) && !ls_is_scalable(v1_size) &&
       ap_sle(d1.offset, ap_neg(ap_from_u64(d1.offset.bits, ls_value(v1_size)))) && is_base_of_object(d1.base)
        return ar(AR_NO);

    if ap_is_zero(d1.offset) && d1.var_indices.count == 0
        return aa_alias(q, mloc(d1.base, v1_size), mloc(d2.base, v2_size));

    base_alias := aa_alias(q, mloc_before_or_after(d1.base), mloc_before_or_after(d2.base));
    if base_alias.kind != AR_MUST return base_alias;

    bw := d1.offset.bits;
    if d1.var_indices.count == 0 {
        off := d1.offset;
        vleft := v2_size; vright := v1_size;
        swapped := ap_is_negative(off);
        if swapped { vleft, vright = vright, vleft; off = ap_neg(off); }
        if !ls_has_value(vleft) return ar(AR_MAY);
        lsize := ls_value(vleft);
        if !ls_is_scalable(vleft) {
            if ap_ult(off, ap_from_u64(bw, lsize)) {
                r := ar(AR_PARTIAL);
                if ls_has_value(vright) && !ls_is_scalable(vright) && ap_ule(off, ap_from_u64(bw, 0x7FFF_FFFF)) &&
                   ap_ule(ap_add(off, ap_from_u64(bw, ls_value(vright))), ap_from_u64(bw, lsize)) {
                    ar_set_offset(*r, -ap_sext_value(off));
                    ar_swap(*r, swapped);
                }
                return r;
            }
            return ar(AR_NO);
        } else {
            cr := get_vscale_range(q.aar.f, bw);
            upper, ov := ap_umul_ov(cr_umax(cr), ap_from_u64(bw, lsize));
            if !ov && ap_uge(off, upper) return ar(AR_NO);
        }
    }

    if d1.var_indices.count == 1 && d1.var_indices[0].val.trunc_bits == 0 && ap_is_zero(d1.offset) &&
       is_vscale_call(d1.var_indices[0].val.v) {
        sv := d1.var_indices[0];
        scale := ifx sv.is_negated then ap_neg(sv.scale) else sv.scale;
        vleft := ifx ap_is_negative(scale) then v1_size else v2_size;
        overflows := !sv.is_nsw;
        if overflows {
            cr := get_vscale_range(q.aar.f, scale.bits);
            _, overflows = ap_smul_ov(cr_smax(cr), scale);
        }
        if !overflows {
            if ls_has_value(vleft) && ap_uge(ap_abs(scale), ap_from_u64(scale.bits, ls_value(vleft))) return ar(AR_NO);
        }
    }

    if d1.var_indices.count > 0 && d1.nuw && ls_has_value(v2_size) && !ls_is_scalable(v2_size) &&
       ap_uge(d1.offset, ap_from_u64(bw, ls_value(v2_size)))
        return ar(AR_NO);

    if ls_is_scalable(v1_size) || ls_is_scalable(v2_size) return ar(AR_MAY);
    fits :: (bw: u32, v: u64) -> bool { return bw >= 64 || v < ((cast(u64) 1) << bw); }
    if !ls_has_value(v1_size) || !ls_has_value(v2_size) || !fits(bw, ls_value(v1_size)) || !fits(bw, ls_value(v2_size))
        return ar(AR_MAY);
    s1 := ls_value(v1_size); s2 := ls_value(v2_size);

    gcd: APInt;
    offset_range := cr_single(d1.offset);
    for i: 0..d1.var_indices.count-1 {
        index := d1.var_indices[i];
        scale := index.scale;
        sq: Simplify_Query; sq.dt = dt; sq.ac = q.aar.ac; sq.cxt = index.cxt;
        known := known_bits(index.val.v, sq);
        scale_for_gcd := scale;
        if !index.is_nsw scale_for_gcd = ap_one_bit_set(scale.bits, ap_ctz(scale));
        var_tz := kb_count_min_trailing_zeros(known);
        if var_tz > 0 {
            max_shift := scale.bits - ap_significant_bits(scale_for_gcd);
            scale_for_gcd = ap_shl(scale_for_gcd, min(var_tz, max_shift));
        }
        if i == 0 gcd = ap_abs(scale_for_gcd);
        else gcd = ap_gcd(gcd, ap_abs(scale_for_gcd));

        cr := compute_constant_range(index.val.v, false, sq);
        cr = cr_intersect(cr, cr_from_known_bits(known, true), .SIGNED);
        cr = cr_sext_or_trunc(cv_evaluate_cr(index.val, cr), cr_bits(offset_range));
        if index.is_nsw cr = cr_smul_sat(cr, cr_single(scale));
        else cr = cr_smul_fast(cr, cr_single(scale));
        if index.is_negated offset_range = cr_sub(offset_range, cr);
        else offset_range = cr_add(offset_range, cr);
    }

    mod_offset := ap_srem(d1.offset, gcd);
    if ap_is_negative(mod_offset) mod_offset = ap_add(mod_offset, gcd);
    if ap_uge(mod_offset, ap_from_u64(bw, s2)) && ap_uge(ap_sub(gcd, mod_offset), ap_from_u64(bw, s1)) return ar(AR_NO);

    range1 := cr_add(offset_range, cr_new(ap_zero(bw), ap_from_u64(bw, s1)));
    range2 := cr_new(ap_zero(bw), ap_from_u64(bw, s2));
    if cr_is_empty_set(cr_intersect(range1, range2)) return ar(AR_NO);

    multiply_by_scale_no_wrap :: (v: Var_Gep_Index) -> bool {
        if v.is_nsw return true;
        orig_bw := cast(s64) prim_bits(v.val.v);
        max_scale_bw := cast(s64) cv_bit_width(v.val) - orig_bw;
        if max_scale_bw <= 0 return false;
        return ap_ule(v.scale, ap_zext(ap_all_ones(cast(u32) max_scale_bw), v.scale.bits));
    }
    has_min_abs := false;
    min_abs_var_index: APInt;
    if d1.var_indices.count == 1 {
        v := d1.var_indices[0];
        sq: Simplify_Query; sq.dt = dt; sq.ac = q.aar.ac; sq.cxt = v.cxt;
        if v.val.trunc_bits == 0 && is_known_non_zero(v.val.v, sq) {
            if multiply_by_scale_no_wrap(v) { min_abs_var_index = ap_abs(v.scale); has_min_abs = true; }
        }
    } else if d1.var_indices.count == 2 {
        v0 := d1.var_indices[0]; v1 := d1.var_indices[1];
        if vgi_has_negated_scale_of(v0, v1) && v0.val.trunc_bits == 0 && cv_has_same_casts_as(v0.val, v1.val) &&
           !q.may_be_cross_iteration && multiply_by_scale_no_wrap(v0) && multiply_by_scale_no_wrap(v1) {
            sq: Simplify_Query; sq.dt = dt; sq.ac = q.aar.ac; sq.cxt = ifx v0.cxt != NONE then v0.cxt else v1.cxt;
            if is_known_non_equal(v0.val.v, v1.val.v, sq) { min_abs_var_index = ap_abs(v0.scale); has_min_abs = true; }
        }
    }
    if has_min_abs {
        lo := ap_sub(d1.offset, min_abs_var_index);
        hi := ap_add(d1.offset, min_abs_var_index);
        if ap_is_negative(lo) && ap_uge(ap_neg(lo), ap_from_u64(bw, s1)) && ap_is_non_negative(hi) && ap_uge(hi, ap_from_u64(bw, s2))
            return ar(AR_NO);
    }
    if constant_offset_heuristic(q, *d1, v1_size, v2_size) return ar(AR_NO);
    return ar(AR_MAY);
}
