// A port of llvm/lib/Transforms/Utils/SimplifyLibCalls.cpp (LibCallSimplifier and FortifiedLibCallSimplifier).
// This file: the helpers, the string and memory call optimizations; simplify_lib_calls2.jai: math, integer and
// formatting calls, optimizeCall and the fortified simplifier.
//
// The simplifier is only used by InstCombine (tryOptimizeCall), so it builds with InstCombine's IRBuilder (icb_*):
// the Replacer is ic_replace_inst_uses_with and the Eraser ic_erase_inst, like InstCombineRAUW / InstCombineErase.
// One LibCallSimplifier is constructed per call (lcs_begin), with UnsafeFPShrink = false.

Lcs_State :: struct {
    tli: *Tli;
    call: Value_Id;              // the call being simplified (for the operand-bundle guard of the builder)
    unsafe_fp_shrink: bool;
}
lcs: Lcs_State;

// -enable-double-float-shrink (cl::opt with getNumOccurrences): 0 = not given, 1 = false, 2 = true
lcs_enable_unsafe_fp_shrink_opt: u8 = 0;

// LibCallSimplifier::replaceAllUsesWith / eraseFromParent / substituteInParent (InstCombine's Replacer / Eraser)
lcs_replace_all_uses_with :: (i: Value_Id, with: Value_Id) { ic_replace_inst_uses_with(i, with); }
lcs_erase_from_parent :: (i: Value_Id) { ic_erase_inst(i); }
lcs_substitute_in_parent :: (i: Value_Id, with: Value_Id) { lcs_replace_all_uses_with(i, with); lcs_erase_from_parent(i); }

// ---------------------------------------------------------------- small IR helpers

// IRBuilder::CreateLoad(Ty, Ptr, Name) / CreateStore(V, Ptr): the ABI alignment of the type
lcs_load :: (ty: Type_Id, ptr: Value_Id, name: string = "") -> Value_Id { return icb_aligned_load(ty, ptr, dl_abi_align(ty), name); }
lcs_store :: (v: Value_Id, ptr: Value_Id) -> Value_Id { return icb_aligned_store(v, ptr, dl_abi_align(vtype(v))); }
// B.getInt8 / getInt32 / getInt64 / getIntN
lcs_i8 :: (v: u64) -> Value_Id { return const_int(ir.t_i8, v); }
lcs_i32 :: (v: u64) -> Value_Id { return const_int(ir.t_i32, v); }
lcs_i64 :: (v: u64) -> Value_Id { return const_int(ir.t_i64, v); }
lcs_int_n :: (bits: u32, v: u64) -> Value_Id { return const_int(type_int(bits), v); }
// ConstantFP::get(Ty, double)
lcs_const_fp_f64 :: (ty: Type_Id, x: float64) -> Value_Id {
    k := type_kind(scalar_type(ty));
    return ic_const_fp(ty, apf_make(k, fp_from_f64(k, x)));
}
// CallInst "is fast" / fast-math flag queries on an FPMathOperator call
lcs_fmf :: (i: Value_Id) -> u32 { if !is_inst(i) || !is_fp_math_inst(i) return 0; return get_fmf(i); }
lcs_is_fast :: (i: Value_Id) -> bool { return lcs_fmf(i) == FMF_ALL; }
lcs_has_no_nans :: (i: Value_Id) -> bool { return (lcs_fmf(i) & FMF_NNAN) != 0; }
lcs_has_no_infs :: (i: Value_Id) -> bool { return (lcs_fmf(i) & FMF_NINF) != 0; }
lcs_has_no_signed_zeros :: (i: Value_Id) -> bool { return (lcs_fmf(i) & FMF_NSZ) != 0; }
lcs_has_approx_func :: (i: Value_Id) -> bool { return (lcs_fmf(i) & FMF_AFN) != 0; }
lcs_has_allow_reassoc :: (i: Value_Id) -> bool { return (lcs_fmf(i) & FMF_REASSOC) != 0; }
// CallBase::doesNotAccessMemory
lcs_does_not_access_memory :: (c: Value_Id) -> bool { return call_memory_effects(c) == 0; }
// Value::takeName on a value that may be a constant (constants keep no name)
lcs_take_name :: (dst: Value_Id, src: Value_Id) { if is_inst(dst) ic_take_name(dst, src); }
// CallInst::getTailCallKind / setTailCallKind
call_tail_kind :: (c: Value_Id) -> u32 { return (inst(c).flags >> TAIL_SHIFT) & 3; }
call_set_tail_kind :: (c: Value_Id, k: u32) { inst(c).flags = (inst(c).flags & ~((cast(u32) 3) << TAIL_SHIFT)) | (k << TAIL_SHIFT); }
TCK_NONE :: 0; TCK_TAIL :: 1; TCK_MUSTTAIL :: 2; TCK_NOTAIL :: 3;
// AttributeList::getParamDereferenceableBytes / ...OrNullBytes / getParamAlignment (call-site attributes only)
lcs_param_attr_ival :: (c: Value_Id, k: u32, kind: Attr_Kind) -> u64 {
    a := attr_set_find(attr_list_param(inst(c).attrs, k), kind);
    if !a return 0;
    return a.ival;
}
call_param_deref_bytes_site :: (c: Value_Id, k: u32) -> u64 { return lcs_param_attr_ival(c, k, .Dereferenceable); }
call_param_deref_or_null_bytes_site :: (c: Value_Id, k: u32) -> u64 { return lcs_param_attr_ival(c, k, .DereferenceableOrNull); }
call_add_param_attr :: (c: Value_Id, k: u32, a: Attr) { call_set_param_attr_set(c, k, attr_set_with(call_param_attr_set(c, k), a)); }
call_add_param_attr_kind :: (c: Value_Id, k: u32, kind: Attr_Kind) { a: Attr; a.kind = kind; a.ty = NONE; call_add_param_attr(c, k, a); }
call_remove_param_attr :: (c: Value_Id, k: u32, kind: Attr_Kind) {
    s := call_param_attr_set(c, k);
    if attr_set_has(s, kind) call_set_param_attr_set(c, k, attr_set_remove(s, kind));
}
// isa<ConstantPointerNull>
lcs_is_null_ptr :: (v: Value_Id) -> bool { return vkind(v) == .C_NULL && is_ptr_type(vtype(v)); }
// isa<ConstantInt> (scalar or a vector-typed ConstantInt splat)
lcs_const_int :: (v: Value_Id) -> bool { return vkind(v) == .C_INT; }
lcs_cint_zext :: (v: Value_Id) -> u64 { return const_int_zext(v); }

// Builder.CreateCall(F, Args, FMFSource, Name): default operand bundles are the simplified call's (lcs_check_bundles)
icb_call_fn_fmf :: (f: Value_Id, args: [] Value_Id, fmf: u32, name: string = "") -> Value_Id {
    saved := ic.b_fmf;
    ic.b_fmf = fmf;
    ci := icb_call_fn(f, args, name);
    ic.b_fmf = saved;
    return ci;
}

// IRBuilder::CreateGlobalString(Str, Name, AddressSpace = 0, M, AddNull): a private unnamed_addr constant
icb_global_string :: (s: string, name: string, add_null := true) -> Value_Id {
    n := s.count + (ifx add_null then 1 else 0);
    ty := type_array(cast(u64) n, ir.t_i8);
    elts := NewArray(n, u64,, allocator = temp);
    all_zero := true;
    for i: 0..s.count-1 { elts[i] = s[i]; if s[i] != 0 all_zero = false; }
    init := ifx all_zero then const_zero(ty) else const_data(ty, elts);
    gv := new_global(.GLOBAL_VAR, ty, 0, 1);
    set_name(gv, name);
    array_add(*ir.m_globals, gv);
    g := glob(gv);
    set_op(gv, 0, init); g.has_init = true;
    g.is_const = true;
    g.linkage = .PRIVATE;
    g.dso_local = true;
    g.unnamed_addr = 2;
    g.align = dl_pref_align(ir.t_i8);
    return gv;
}

// IRBuilder::CreatePtrDiff(ElemTy = i8, LHS, RHS, Name): (ptrtoint LHS - ptrtoint RHS) exact sdiv 1 folds away
icb_ptr_diff :: (l: Value_Id, r: Value_Id, name: string = "") -> Value_Id {
    it := type_int(dl_index_type_size_bits(vtype(l)));
    lp := icb_cast(.PTRTOINT, l, it);
    rp := icb_cast(.PTRTOINT, r, it);
    diff := icb_sub(lp, rp);
    return icb_sdiv(diff, const_int(it, 1), name, true);
}

// ignoreCallingConv
ignore_calling_conv :: (f: Lib_Func) -> bool { return f == .abs || f == .labs || f == .llabs || f == .strlen; }

// isOnlyUsedInEqualityComparison(V, With)
is_only_used_in_equality_comparison :: (v: Value_Id, with: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) && inst_op(usr) == .ICMP && icmp_is_equality(inst_pred(usr)) && op(usr, 1) == with continue;
        return false;
    }
    return true;
}
// callHasFloatingPointArgument / callHasFP128Argument (all operands, including the callee)
call_has_floating_point_argument :: (ci: Value_Id) -> bool {
    for k: 0..cast(s64) nops(ci) - 1 if is_fp_type(vtype(op(ci, cast(u32) k))) return true;
    return false;
}
call_has_fp128_argument :: (ci: Value_Id) -> bool {
    for k: 0..cast(s64) nops(ci) - 1 if type_kind(vtype(op(ci, cast(u32) k))) == .FP128 return true;
    return false;
}

// SaturatingMultiplyAdd(X, Y, A, &Overflow) (MathExtras.h)
saturating_multiply_add :: (x: u64, y: u64, a: u64) -> (u64, bool) {
    hi, lo := mul_u64_full(x, y);
    if hi != 0 return 0xFFFF_FFFF_FFFF_FFFF, true;
    s := lo + a;
    if s < lo return 0xFFFF_FFFF_FFFF_FFFF, true;
    return s, false;
}
mul_u64_full :: (a: u64, b: u64) -> (hi: u64, lo: u64) {
    a_lo := a & 0xFFFF_FFFF; a_hi := a >> 32; b_lo := b & 0xFFFF_FFFF; b_hi := b >> 32;
    p0 := a_lo * b_lo; p1 := a_lo * b_hi; p2 := a_hi * b_lo; p3 := a_hi * b_hi;
    mid := (p0 >> 32) + (p1 & 0xFFFF_FFFF) + (p2 & 0xFFFF_FFFF);
    lo := (p0 & 0xFFFF_FFFF) | (mid << 32);
    hi := p3 + (p1 >> 32) + (p2 >> 32) + (mid >> 32);
    return hi, lo;
}
max_int_n :: (n: u32) -> u64 { if n >= 64 return 0x7FFF_FFFF_FFFF_FFFF; return ((cast(u64) 1) << (n - 1)) - 1; }
max_uint_n :: (n: u32) -> u64 { if n >= 64 return 0xFFFF_FFFF_FFFF_FFFF; return ((cast(u64) 1) << n) - 1; }
lcs_is_space :: (c: u8) -> bool { return c == #char " " || (c >= 9 && c <= 13); }
lcs_to_upper :: (c: u8) -> u8 { if c >= #char "a" && c <= #char "z" return c - 32; return c; }

// convertStrToInt(CI, Str, EndPtr, Base, AsSigned, B)
convert_str_to_int :: (ci: Value_Id, str_in: string, end_ptr: Value_Id, base_in: u64, as_signed: bool) -> Value_Id {
    str := str_in; base := base_in;
    if base < 2 || base > 36 if base != 0 return NONE;
    offset: u64 = 0;
    while offset != cast(u64) str.count {
        if !lcs_is_space(str[cast(s64) offset]) { str = slice(str, cast(s64) offset, str.count - cast(s64) offset); break; }
        offset += 1;
    }
    // (when the string is all whitespace LLVM leaves Str as is and fails below only if it is empty)
    if str.count == 0 return NONE;
    if offset == cast(u64) str_in.count && str.count == str_in.count && str_in.count > 0 {
        // every character was whitespace: Str is unchanged (non-empty) and parsing fails on the first digit
    }
    negate := str[0] == #char "-";
    if str[0] == #char "-" || str[0] == #char "+" {
        str = slice(str, 1, str.count - 1);
        if str.count == 0 return NONE;
        offset += 1;
    }
    ret_ty := vtype(ci);
    nbits := type_bits(ret_ty);
    mx: u64 = ifx as_signed && negate then cast(u64) 1 else 0;
    mx += ifx as_signed then max_int_n(nbits) else max_uint_n(nbits);
    if str.count > 1 {
        if str[0] == #char "0" {
            if lcs_to_upper(str[1]) == #char "X" {
                if str.count == 2 || (base != 0 && base != 16) return NONE;
                str = slice(str, 2, str.count - 2);
                offset += 2;
                base = 16;
            } else if base == 0 base = 8;
        } else if base == 0 base = 10;
    } else if base == 0 base = 10;
    result: u64 = 0;
    for i: 0..str.count-1 {
        dig := str[i];
        if c_isdigit(dig) dig = dig - #char "0";
        else {
            dig = lcs_to_upper(dig);
            if dig >= #char "A" && dig <= #char "Z" dig = dig - #char "A" + 10;
            else return NONE;
        }
        if cast(u64) dig >= base return NONE;
        r, vflow := saturating_multiply_add(result, base, cast(u64) dig);
        result = r;
        if vflow || result > mx return NONE;
    }
    if end_ptr != NONE {
        off := lcs_i64(offset + cast(u64) str.count);
        str_beg := call_arg(ci, 0);
        str_end := icb_gep(ir.t_i8, str_beg, .[off], "endptr", F_INBOUNDS);
        lcs_store(str_end, end_ptr);
    }
    if negate {
        result = ~result + 1;
        if !as_signed result &= max_uint_n(nbits);
    }
    return const_int(ret_ty, result);   // ConstantInt::get(RetTy, Result, AsSigned): the low NBits bits
}

// isOnlyUsedInComparisonWithZero (users are icmps against a null constant, any predicate)
is_only_used_in_comparison_with_zero :: (v: Value_Id) -> bool {
    u := ir.v_first_use[v];
    while u != NONE {
        usr := ir.u_user[u];
        u = ir.u_next[u];
        if is_inst(usr) && inst_op(usr) == .ICMP && is_const(op(usr, 1)) && is_null_value(op(usr, 1)) continue;
        return false;
    }
    return true;
}

// canTransformToMemCmp(CI, Str, Len, SQ)
can_transform_to_mem_cmp :: (ci: Value_Id, str: Value_Id, len: u64, q: Simplify_Query) -> bool {
    if !is_only_used_in_comparison_with_zero(ci) return false;
    if !is_dereferenceable_and_aligned_pointer(str, 1, ap_from_u64(64, len), q) return false;
    if fn_has_fn_attr(inst_fn(ci), .SanitizeMemory) return false;
    return true;
}
// The SimplifyQuery(DL) of `isKnownNonZero(V, DL)` and friends: no DT, AC, TLI or context
lcs_sq_dl :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }
// SimplifyQuery(DL, TLI, DT, AC, CI)
lcs_sq_full :: (cxt: Value_Id) -> Simplify_Query { q: Simplify_Query; q.dt = ic.dt; q.ac = ic.ac; q.cxt = cxt; return q; }
// SimplifyQuery(DL, TLI, DT, AC, CI, UseInstrInfo = true, CanUseUndef = true, DC)
lcs_sq_full_dc :: (cxt: Value_Id) -> Simplify_Query { q := lcs_sq_full(cxt); q.dc = *ic.dc; return q; }

// annotateDereferenceableBytes(CI, ArgNos, DereferenceableBytes)
annotate_dereferenceable_bytes :: (ci: Value_Id, arg_nos: [] u32, bytes: u64) {
    f := inst_fn(ci);
    if f == NONE return;
    for arg_no: arg_nos {
        deref := bytes;
        as := cast(u64) type_addrspace(vtype(call_arg(ci, arg_no)));
        if !null_pointer_is_defined(f, as) || call_param_has_attr(ci, arg_no, .NonNull)
            deref = max(call_param_deref_or_null_bytes_site(ci, arg_no), bytes);
        if call_param_deref_bytes_site(ci, arg_no) < deref {
            call_remove_param_attr(ci, arg_no, .Dereferenceable);
            if !null_pointer_is_defined(f, as) || call_param_has_attr(ci, arg_no, .NonNull)
                call_remove_param_attr(ci, arg_no, .DereferenceableOrNull);
            a: Attr; a.kind = .Dereferenceable; a.ty = NONE; a.ival = deref;
            call_add_param_attr(ci, arg_no, a);
        }
    }
}
// annotateNonNullNoUndefBasedOnAccess(CI, ArgNos)
annotate_non_null_no_undef_based_on_access :: (ci: Value_Id, arg_nos: [] u32) {
    f := inst_fn(ci);
    if f == NONE return;
    for arg_no: arg_nos {
        if !call_param_has_attr(ci, arg_no, .NoUndef) call_add_param_attr_kind(ci, arg_no, .NoUndef);
        if !call_param_has_attr(ci, arg_no, .NonNull) {
            as := cast(u64) type_addrspace(vtype(call_arg(ci, arg_no)));
            if null_pointer_is_defined(f, as) continue;
            call_add_param_attr_kind(ci, arg_no, .NonNull);
        }
        annotate_dereferenceable_bytes(ci, .[arg_no], 1);
    }
}
// annotateNonNullAndDereferenceable(CI, ArgNos, Size, DL)
annotate_non_null_and_dereferenceable :: (ci: Value_Id, arg_nos: [] u32, size: Value_Id) {
    if lcs_const_int(size) && !is_vector_type(vtype(size)) {
        annotate_non_null_no_undef_based_on_access(ci, arg_nos);
        annotate_dereferenceable_bytes(ci, arg_nos, lcs_cint_zext(size));
    } else if is_known_non_zero(size, lcs_sq_dl()) {
        annotate_non_null_no_undef_based_on_access(ci, arg_nos);
        // match(Size, m_Select(m_Value(), m_ConstantInt(X), m_ConstantInt(Y)))
        if is_inst(size) && inst_op(size) == .SELECT {
            okx, x := pm_constant_int_u64(op(size, 1));
            oky, y := pm_constant_int_u64(op(size, 2));
            if okx && oky annotate_dereferenceable_bytes(ci, arg_nos, min(x, y));
        }
    }
}
// copyFlags(Old, New): New gets Old's tail call kind
lcs_copy_flags :: (old: Value_Id, new: Value_Id) -> Value_Id {
    assert(call_tail_kind(old) != TCK_MUSTTAIL, "do not copy musttail call flags");
    assert(call_tail_kind(old) != TCK_NOTAIL, "do not copy notail call flags");
    if new != NONE && is_inst(new) && inst_op(new) == .CALL call_set_tail_kind(new, call_tail_kind(old));
    return new;
}

// AttributeFuncs::typeIncompatible(Ty, AS) (ASK_ALL): the attribute kinds a value of type `ty` can't carry
type_incompatible_kinds :: (ty: Type_Id, s: u32, out: *[..] Attr_Kind) {
    k := type_kind(ty);
    if k != .INT array_add(out, .AllocAlign);
    if k != .INT && k != .BYTE { array_add(out, .SExt); array_add(out, .ZExt); }
    if !is_int_or_int_vector(ty) array_add(out, .Range);
    else {
        r := attr_set_find(s, .Range);
        if r && cast(u32) r.ival != type_bits(scalar_type(ty)) array_add(out, .Range);
    }
    if k != .PTR {
        for Attr_Kind.[.NoAlias, .NonNull, .ReadNone, .ReadOnly, .Dereferenceable, .DereferenceableOrNull, .Writable,
                       .DeadOnUnwind, .Initializes, .Captures, .DeadOnReturn, .Nest, .SwiftError, .Preallocated,
                       .InAlloca, .ByVal, .StructRet, .ByRef, .ElementType, .AllocatedPointer] array_add(out, it);
    }
    if !is_ptr_or_ptr_vector(ty) array_add(out, .Alignment);
    if !fp_math_supported_type(ty) array_add(out, .NoFPClass);
    if k == .VOID array_add(out, .NoUndef);
}
// FPMathOperator::isSupportedFloatingPointType
fp_math_supported_type :: (t_in: Type_Id) -> bool {
    t := t_in;
    while type_kind(t) == .ARRAY t = type_elem(t);
    if type_kind(t) == .STRUCT {
        n := type_nsub(t);
        if n == 0 return false;
        e0 := type_sub(t, 0);
        for j: 1..cast(s64) n - 1 if type_sub(t, cast(u32) j) != e0 return false;
        t = e0;
    }
    return is_fp_type(scalar_type(t));
}
attr_set_remove_kinds :: (s: u32, kinds: [] Attr_Kind) -> u32 {
    r := s;
    for kinds r = attr_set_remove(r, it);
    return r;
}

// mergeAttributesAndFlags(NewCI, Old)
merge_attributes_and_flags :: (new_ci: Value_Id, old: Value_Id) -> Value_Id {
    nl := inst(new_ci).attrs; ol := inst(old).attrs;
    np := max(ifx nl == 0 then 0 else ir.attr_lists[nl].params.count, ifx ol == 0 then 0 else ir.attr_lists[ol].params.count);
    ps := NewArray(np, u32,, allocator = temp);
    for k: 0..np-1 ps[k] = attr_set_merge(attr_list_param(nl, cast(u32) k), attr_list_param(ol, cast(u32) k));
    fns := attr_set_merge(attr_list_fn(nl), attr_list_fn(ol));
    ret := attr_set_merge(attr_list_ret(nl), attr_list_ret(ol));
    kinds: [..] Attr_Kind; kinds.allocator = temp;
    type_incompatible_kinds(vtype(new_ci), ret, *kinds);
    ret = attr_set_remove_kinds(ret, kinds);
    na := call_arg_count(new_ci);
    for k: 0..cast(s64) na - 1 {
        if k >= np break;
        kinds.count = 0;
        type_incompatible_kinds(vtype(call_arg(new_ci, cast(u32) k)), ps[k], *kinds);
        ps[k] = attr_set_remove_kinds(ps[k], kinds);
    }
    inst(new_ci).attrs = attr_list_get(fns, ret, ps);
    return lcs_copy_flags(old, new_ci);
}

// substr(Str, Len): avoid truncating the length if size_t is 32 bits
lcs_substr :: (s: string, len: u64) -> string { if len >= cast(u64) s.count return s; return slice(s, 0, cast(s64) len); }
// StringRef::find(char, From) / rfind / find_first_of / find_first_not_of; NPOS = StringRef::npos
NPOS :: 0xFFFF_FFFF_FFFF_FFFF;
str_find_char :: (s: string, c: u8, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if s[cast(s64) i] == c return i; i += 1; }
    return NPOS;
}
str_rfind_char :: (s: string, c: u8, from: u64 = NPOS) -> u64 {
    i := min(from, cast(u64) s.count);
    while i != 0 { i -= 1; if s[cast(s64) i] == c return i; }
    return NPOS;
}
str_find_str :: (s: string, needle: string) -> u64 {
    if needle.count > s.count return NPOS;
    for i: 0..s.count - needle.count {
        if slice(s, i, needle.count) == needle return cast(u64) i;
    }
    return NPOS;
}
str_find_first_of :: (s: string, set: string, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if str_find_char(set, s[cast(s64) i]) != NPOS return i; i += 1; }
    return NPOS;
}
str_find_first_not_of :: (s: string, set: string, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if str_find_char(set, s[cast(s64) i]) == NPOS return i; i += 1; }
    return NPOS;
}
str_find_first_not_of_char :: (s: string, c: u8, from: u64 = 0) -> u64 {
    i := from;
    while i < cast(u64) s.count { if s[cast(s64) i] != c return i; i += 1; }
    return NPOS;
}
// StringRef::compare: -1, 0, 1 by unsigned bytes then length
str_compare :: (a: string, b: string) -> s64 {
    n := min(a.count, b.count);
    for i: 0..n-1 if a[i] != b[i] return ifx a[i] < b[i] then -1 else 1;
    if a.count == b.count return 0;
    return ifx a.count < b.count then -1 else 1;
}
lcs_char_str :: (c: u8) -> string { s := alloc_string(1,, allocator = temp); s[0] = c; return s; }

// ---------------------------------------------------------------- String and Memory Library Call Optimizations

// optimizeStrCat
lcs_optimize_str_cat :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1);
    annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    len := get_string_length(src);
    if len annotate_dereferenceable_bytes(ci, .[1], len);
    else return NONE;
    len -= 1;
    if len == 0 return dst;
    return lcs_copy_flags(ci, lcs_emit_str_len_mem_cpy(src, dst, len));
}
// emitStrLenMemCpy
lcs_emit_str_len_mem_cpy :: (src: Value_Id, dst: Value_Id, len: u64) -> Value_Id {
    dst_len := emit_str_len(dst, lcs.tli);
    if dst_len == NONE return NONE;
    cpy_dst := icb_gep(ir.t_i8, dst, .[dst_len], "endptr", F_INBOUNDS);
    icb_mem_transfer(IID_MEMCPY, cpy_dst, 1, src, 1, tli_as_size_t(len + 1), false);
    return dst;
}
// optimizeStrNCat
lcs_optimize_str_n_cat :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1); size := call_arg(ci, 2);
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    if is_known_non_zero(size, lcs_sq_dl()) annotate_non_null_no_undef_based_on_access(ci, .[1]);
    len: u64;
    if lcs_const_int(size) {
        len = lcs_cint_zext(size);
        if !len return dst;
    } else return NONE;
    src_len := get_string_length(src);
    if src_len {
        annotate_dereferenceable_bytes(ci, .[1], src_len);
        src_len -= 1;
    } else return NONE;
    if src_len == 0 return dst;
    if len < src_len return NONE;
    return lcs_copy_flags(ci, lcs_emit_str_len_mem_cpy(src, dst, src_len));
}

// memChrToCharCompare(CI, NBytes, B, DL)
mem_chr_to_char_compare :: (ci: Value_Id, nbytes: Value_Id) -> Value_Id {
    src := call_arg(ci, 0);
    char_val := call_arg(ci, 1);
    char0 := lcs_load(ir.t_i8, src);
    char_val = icb_trunc(char_val, ir.t_i8);
    cmp := icb_cmp(ICMP_EQ, char0, char_val, "char0cmp");
    if nbytes != NONE {
        zero := const_int(vtype(nbytes), 0);
        and := icb_cmp(ICMP_NE, nbytes, zero);
        cmp = icb_logical_and(and, cmp);
    }
    null_ptr := const_null_value(vtype(ci));
    return icb_select(cmp, src, null_ptr);
}

// optimizeStrChr
lcs_optimize_str_chr :: (ci: Value_Id) -> Value_Id {
    src_str := call_arg(ci, 0); char_val := call_arg(ci, 1);
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    if is_only_used_in_equality_comparison(ci, src_str) return mem_chr_to_char_compare(ci, NONE);
    if !lcs_const_int(char_val) {
        len := get_string_length(src_str);
        if len annotate_dereferenceable_bytes(ci, .[0], len);
        else return NONE;
        ft := glob(call_called_function(ci)).value_type;
        p1 := func_param(ft, 1);
        if !(type_kind(p1) == .INT && type_int_width(p1) == tli_int_bits()) return NONE;
        return lcs_copy_flags(ci, emit_mem_chr(src_str, char_val, const_int(tli_size_t_type(), len), lcs.tli));
    }
    if is_null_value(char_val) {
        null_ptr := const_null_value(vtype(ci));
        if is_only_used_in_equality_comparison(ci, null_ptr) return icb_cast(.INTTOPTR, const_int(ir.t_i1, 1), vtype(ci));
    }
    ok, str := get_constant_string_info(src_str);
    if !ok {
        if is_null_value(char_val) {
            sl := emit_str_len(src_str, lcs.tli);
            if sl != NONE return icb_gep(ir.t_i8, src_str, .[sl], "strchr", F_INBOUNDS);
        }
        return NONE;
    }
    cs := const_int_sext(char_val);
    i: u64 = ifx (0xFF & cs) == 0 then cast(u64) str.count else str_find_char(str, cast(u8)(cs & 0xFF));
    if i == NPOS return const_null_value(vtype(ci));
    return icb_gep(ir.t_i8, src_str, .[lcs_i64(i)], "strchr", F_INBOUNDS);
}

// optimizeStrRChr
lcs_optimize_str_r_chr :: (ci: Value_Id) -> Value_Id {
    src_str := call_arg(ci, 0); char_val := call_arg(ci, 1);
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    ok, str := get_constant_string_info(src_str);
    if !ok {
        if lcs_const_int(char_val) && is_null_value(char_val) return lcs_copy_flags(ci, emit_str_chr(src_str, 0, lcs.tli));
        return NONE;
    }
    nbytes := cast(u64) str.count + 1;
    size := const_int(tli_size_t_type(), nbytes);
    return lcs_copy_flags(ci, emit_mem_r_chr(src_str, char_val, size, lcs.tli));
}

// optimizeStrCmp
lcs_optimize_str_cmp :: (ci: Value_Id) -> Value_Id {
    s1p := call_arg(ci, 0); s2p := call_arg(ci, 1);
    if s1p == s2p return const_int(vtype(ci), 0);
    has1, str1 := get_constant_string_info(s1p);
    has2, str2 := get_constant_string_info(s2p);
    if has1 && has2 return const_int_signed(vtype(ci), clamp(str_compare(str1, str2), -1, 1));
    if has1 && str1.count == 0
        return icb_neg(icb_zext(lcs_load(ir.t_i8, s2p, "strcmpload"), vtype(ci)));
    if has2 && str2.count == 0
        return icb_zext(lcs_load(ir.t_i8, s1p, "strcmpload"), vtype(ci));
    len1 := get_string_length(s1p);
    if len1 annotate_dereferenceable_bytes(ci, .[0], len1);
    len2 := get_string_length(s2p);
    if len2 annotate_dereferenceable_bytes(ci, .[1], len2);
    if len1 && len2 return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, tli_as_size_t(min(len1, len2)), lcs.tli));
    sq := lcs_sq_full(ci);
    if !has1 && has2 {
        if can_transform_to_mem_cmp(ci, s1p, len2, sq) return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, tli_as_size_t(len2), lcs.tli));
    } else if has1 && !has2 {
        if can_transform_to_mem_cmp(ci, s2p, len1, sq) return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, tli_as_size_t(len1), lcs.tli));
    }
    annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    return NONE;
}

// optimizeStrNCmp
lcs_optimize_str_n_cmp :: (ci: Value_Id) -> Value_Id {
    s1p := call_arg(ci, 0); s2p := call_arg(ci, 1); size := call_arg(ci, 2);
    if s1p == s2p return const_int(vtype(ci), 0);
    if is_known_non_zero(size, lcs_sq_dl()) annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    length: u64;
    if lcs_const_int(size) length = lcs_cint_zext(size);
    else return optimize_mem_cmp_var_size(ci, s1p, s2p, size, true);
    if length == 0 return const_int(vtype(ci), 0);
    if length == 1 return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, size, lcs.tli));
    has1, str1 := get_constant_string_info(s1p);
    has2, str2 := get_constant_string_info(s2p);
    if has1 && has2 {
        sub1 := lcs_substr(str1, length); sub2 := lcs_substr(str2, length);
        return const_int_signed(vtype(ci), clamp(str_compare(sub1, sub2), -1, 1));
    }
    if has1 && str1.count == 0
        return icb_neg(icb_zext(lcs_load(ir.t_i8, s2p, "strcmpload"), vtype(ci)));
    if has2 && str2.count == 0
        return icb_zext(lcs_load(ir.t_i8, s1p, "strcmpload"), vtype(ci));
    len1 := get_string_length(s1p);
    if len1 annotate_dereferenceable_bytes(ci, .[0], len1);
    len2 := get_string_length(s2p);
    if len2 annotate_dereferenceable_bytes(ci, .[1], len2);
    if !has1 && has2 {
        len2 = min(len2, length);
        if can_transform_to_mem_cmp(ci, s1p, len2, lcs_sq_dl()) return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, tli_as_size_t(len2), lcs.tli));
    } else if has1 && !has2 {
        len1 = min(len1, length);
        if can_transform_to_mem_cmp(ci, s2p, len1, lcs_sq_dl()) return lcs_copy_flags(ci, emit_mem_cmp(s1p, s2p, tli_as_size_t(len1), lcs.tli));
    }
    return NONE;
}

// optimizeStrNDup
lcs_optimize_str_n_dup :: (ci: Value_Id) -> Value_Id {
    src := call_arg(ci, 0);
    size := call_arg(ci, 1);
    src_len := get_string_length(src);
    if src_len && lcs_const_int(size) {
        annotate_dereferenceable_bytes(ci, .[0], src_len);
        if src_len <= lcs_cint_zext(size) + 1 return lcs_copy_flags(ci, emit_str_dup(src, lcs.tli));
    }
    return NONE;
}

// optimizeStrCpy
lcs_optimize_str_cpy :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1);
    if dst == src return src;
    annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    len := get_string_length(src);
    if len annotate_dereferenceable_bytes(ci, .[1], len);
    else return NONE;
    new_ci := icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, tli_as_size_t(len), false);
    merge_attributes_and_flags(new_ci, ci);
    return dst;
}

// optimizeStpCpy
lcs_optimize_stp_cpy :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1);
    if !has_uses(ci) return lcs_copy_flags(ci, emit_str_cpy(dst, src, lcs.tli));
    if dst == src {
        sl := emit_str_len(src, lcs.tli);
        return ifx sl != NONE then icb_gep(ir.t_i8, dst, .[sl], "", F_INBOUNDS) else NONE;
    }
    len := get_string_length(src);
    if len annotate_dereferenceable_bytes(ci, .[1], len);
    else return NONE;
    len_v := tli_as_size_t(len);
    dst_end := icb_gep(ir.t_i8, dst, .[tli_as_size_t(len - 1)], "", F_INBOUNDS);
    new_ci := icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, len_v, false);
    merge_attributes_and_flags(new_ci, ci);
    return dst_end;
}

// optimizeStrLCpy
lcs_optimize_str_l_cpy :: (ci: Value_Id) -> Value_Id {
    size := call_arg(ci, 2);
    if is_known_non_zero(size, lcs_sq_dl()) annotate_non_null_no_undef_based_on_access(ci, .[0]);
    annotate_non_null_no_undef_based_on_access(ci, .[1]);
    nbytes: u64;
    if lcs_const_int(size) nbytes = lcs_cint_zext(size);
    else return NONE;
    dst := call_arg(ci, 0); src := call_arg(ci, 1);
    if nbytes <= 1 {
        if nbytes == 1 lcs_store(lcs_i8(0), dst);
        return lcs_copy_flags(ci, emit_str_len(src, lcs.tli));
    }
    ok, str := get_constant_string_info(src, false);
    if !ok return NONE;
    src_len := str_find_char(str, 0);
    nul_term := src_len < nbytes;
    if nul_term nbytes = src_len + 1;
    else {
        src_len = min(src_len, cast(u64) str.count);
        nbytes = min(nbytes - 1, src_len);
    }
    if src_len == 0 {
        lcs_store(lcs_i8(0), dst);
        return const_int(vtype(ci), 0);
    }
    new_ci := icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, tli_as_size_t(nbytes), false);
    merge_attributes_and_flags(new_ci, ci);
    if !nul_term {
        end_off := const_int(vtype(ci), nbytes);
        end_ptr := icb_gep(ir.t_i8, dst, .[end_off], "", F_INBOUNDS);
        lcs_store(lcs_i8(0), end_ptr);
    }
    return const_int(vtype(ci), src_len);
}

// optimizeStringNCpy(CI, RetEnd)
lcs_optimize_string_n_cpy :: (ci: Value_Id, ret_end: bool) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1); size := call_arg(ci, 2);
    if is_known_non_zero(size, lcs_sq_dl()) {
        annotate_non_null_no_undef_based_on_access(ci, .[0]);
        annotate_non_null_no_undef_based_on_access(ci, .[1]);
    }
    n: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    if lcs_const_int(size) n = lcs_cint_zext(size);
    if n == 0 return dst;
    if n == 1 {
        char_val := lcs_load(ir.t_i8, src, "stxncpy.char0");
        lcs_store(char_val, dst);
        if !ret_end return dst;
        zero_char := const_int(ir.t_i8, 0);
        cmp := icb_cmp(ICMP_EQ, char_val, zero_char, "stpncpy.char0cmp");
        end_ptr := icb_gep(ir.t_i8, dst, .[lcs_i32(1)], "stpncpy.end", F_INBOUNDS);
        return icb_select(cmp, dst, end_ptr, "stpncpy.sel");
    }
    src_len := get_string_length(src);
    if src_len annotate_dereferenceable_bytes(ci, .[1], src_len);
    else return NONE;
    src_len -= 1;
    if src_len == 0 {
        a := attr_set_find(call_param_attr_set(ci, 0), .Alignment);
        al: u64 = ifx a then a.ival else 1;
        new_ci := icb_memset(dst, lcs_i8(0), size, al);
        // NewCI->setAttributes(NewCI->getAttributes().addParamAttributes(Ctx, 0, ArgAttrs))
        call_set_param_attr_set(new_ci, 0, attr_set_merge(call_param_attr_set(new_ci, 0), call_param_attr_set(ci, 0)));
        lcs_copy_flags(ci, new_ci);
        return dst;
    }
    if n > src_len + 1 {
        if n > 128 return NONE;
        ok, str := get_constant_string_info(src);
        if !ok return NONE;
        padded := alloc_string(cast(s64) n,, allocator = temp);
        for i: 0..padded.count-1 padded[i] = ifx i < str.count then str[i] else 0;
        src = icb_global_string(padded, "str", false);
    }
    new_ci := icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, tli_as_size_t(n), false);
    merge_attributes_and_flags(new_ci, ci);
    if !ret_end return dst;
    off := lcs_i64(min(src_len, n));
    return icb_gep(ir.t_i8, dst, .[off], "endptr", F_INBOUNDS);
}

// optimizeStringLength(CI, B, CharSize, Bound)
lcs_optimize_string_length :: (ci: Value_Id, char_size: u32, bound: Value_Id = NONE) -> Value_Id {
    src := call_arg(ci, 0);
    char_ty := type_int(char_size);
    if is_only_used_in_zero_equality_comparison(ci) && (bound == NONE || is_known_non_zero(bound, lcs_sq_dl()))
        return icb_zext(lcs_load(char_ty, src, "char0"), vtype(ci));
    if bound != NONE && lcs_const_int(bound) {
        if is_null_value(bound) return const_int(vtype(ci), 0);
        if ap_is_one(const_ap(bound)) {
            char_val := lcs_load(char_ty, src, "strnlen.char0");
            zero_char := const_int(char_ty, 0);
            cmp := icb_cmp(ICMP_NE, char_val, zero_char, "strnlen.char0cmp");
            return icb_zext(cmp, vtype(ci));
        }
    }
    len := get_string_length(src, char_size);
    if len {
        len_c := const_int(vtype(ci), len - 1);
        if bound != NONE return icb_binary_intrinsic(IID_UMIN, len_c, bound);
        return len_c;
    }
    if bound != NONE return NONE;
    if opr_code(src) == .GEP {
        bw := dl_index_type_size_bits(vtype(src));
        okc, var_offs, const_off := gep_collect_offset_map(src, bw);
        if !okc || var_offs.count != 1 || !ap_is_zero(const_off) || !ap_eq_u64(var_offs[0].scale, char_size / 8) return NONE;
        ok, sl := get_constant_data_array_info(op(src, 0), char_size);
        if ok {
            null_term_idx: u64;
            if !sl.has_array null_term_idx = 0;
            else {
                null_term_idx = 0xFFFF_FFFF_FFFF_FFFF;
                for i: 0..cast(s64) sl.length - 1 {
                    if sl.elts[cast(s64) sl.offset + i] == 0 { null_term_idx = cast(u64) i; break; }
                }
                if null_term_idx == 0xFFFF_FFFF_FFFF_FFFF return NONE;
            }
            offset := var_offs[0].v;
            q: Simplify_Query; q.cxt = ci; q.have_tli = false;   // computeKnownBits(Offset, DL, AC = nullptr, CI, DT = nullptr)
            known := known_bits(offset, q);
            if (kb_is_non_negative(known) && ap_ule_u64(kb_max_value(known), null_term_idx)) ||
               (vkind(op(src, 0)) == .GLOBAL_VAR && null_term_idx == sl.length - 1) {
                offset = icb_sext_or_trunc(offset, vtype(ci));
                return icb_sub(const_int(vtype(ci), null_term_idx), offset);
            }
        }
    }
    if is_inst(src) && inst_op(src) == .SELECT {
        len_true := get_string_length(op(src, 1), char_size);
        len_false := get_string_length(op(src, 2), char_size);
        if len_true && len_false
            return icb_select(op(src, 0), const_int(vtype(ci), len_true - 1), const_int(vtype(ci), len_false - 1));
    }
    return NONE;
}

// GEPOperator::collectOffset(DL, BitWidth, VariableOffsets (SmallMapVector), ConstantOffset)
Gep_Var_Offset :: struct { v: Value_Id; scale: APInt; }
gep_collect_offset_map :: (gep: Value_Id, bw: u32) -> (bool, [..] Gep_Var_Offset, APInt) {
    vars: [..] Gep_Var_Offset; vars.allocator = temp;
    const_off := ap_zero(bw);
    cur := opr_gep_source_type(gep);
    add_var :: (vars: *[..] Gep_Var_Offset, v: Value_Id, scale: APInt) {
        for * vars.* if it.v == v { it.scale = ap_add(it.scale, scale); return; }
        array_add(vars, .{v, scale});
    }
    for k: 1..cast(s64) nops(gep) - 1 {
        idx := op(gep, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        if is_struct {
            if vkind(idx) != .C_INT return false, vars, const_off;
            fi := cast(u32) const_int_zext(idx);
            const_off = ap_add(const_off, ap_from_u64(bw, dl_struct_offset(cur, fi)));
            cur = type_sub(cur, fi);
            continue;
        }
        elt: Type_Id = ifx k == 1 then cur else type_elem(cur);
        if k > 1 cur = elt;
        if type_is_scalable(elt) return false, vars, const_off;
        size := dl_type_alloc_size(elt);
        if vkind(idx) == .C_INT || (is_vector_type(vtype(idx)) && is_const(idx) && get_splat_value(idx) != NONE) {
            ci := ifx vkind(idx) == .C_INT then idx else get_splat_value(idx);
            if vkind(ci) != .C_INT return false, vars, const_off;
            if is_null_value(ci) continue;
            iv := ap_sext_or_trunc(const_ap(ci), bw);
            const_off = ap_add(const_off, ap_mul(iv, ap_from_u64(bw, size)));
            continue;
        }
        if is_vector_type(vtype(idx)) return false, vars, const_off;
        add_var(*vars, idx, ap_from_u64(bw, size));
    }
    return true, vars, const_off;
}

// optimizeStrLen / optimizeStrNLen / optimizeWcslen
lcs_optimize_str_len :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_string_length(ci, 8);
    if v != NONE return v;
    annotate_non_null_no_undef_based_on_access(ci, .[0]);
    return NONE;
}
lcs_optimize_str_n_len :: (ci: Value_Id) -> Value_Id {
    bound := call_arg(ci, 1);
    v := lcs_optimize_string_length(ci, 8, bound);
    if v != NONE return v;
    if is_known_non_zero(bound, lcs_sq_dl()) annotate_non_null_no_undef_based_on_access(ci, .[0]);
    return NONE;
}
lcs_optimize_wcslen :: (ci: Value_Id) -> Value_Id {
    wbits := tli_wchar_size() * 8;
    if wbits == 0 return NONE;
    return lcs_optimize_string_length(ci, wbits);
}

// optimizeStrPBrk
lcs_optimize_str_p_brk :: (ci: Value_Id) -> Value_Id {
    has1, s1 := get_constant_string_info(call_arg(ci, 0));
    has2, s2 := get_constant_string_info(call_arg(ci, 1));
    if (has1 && s1.count == 0) || (has2 && s2.count == 0) return const_null_value(vtype(ci));
    if has1 && has2 {
        i := str_find_first_of(s1, s2);
        if i == NPOS return const_null_value(vtype(ci));
        return icb_gep(ir.t_i8, call_arg(ci, 0), .[lcs_i64(i)], "strpbrk", F_INBOUNDS);
    }
    if has2 && s2.count == 1 return lcs_copy_flags(ci, emit_str_chr(call_arg(ci, 0), s2[0], lcs.tli));
    return NONE;
}
// optimizeStrTo
lcs_optimize_str_to :: (ci: Value_Id) -> Value_Id {
    if lcs_is_null_ptr(call_arg(ci, 1)) {
        a: Attr; a.kind = .Captures; a.ty = NONE; a.ival = 0;
        call_add_param_attr(ci, 0, a);
    }
    return NONE;
}
// optimizeStrSpn
lcs_optimize_str_spn :: (ci: Value_Id) -> Value_Id {
    has1, s1 := get_constant_string_info(call_arg(ci, 0));
    has2, s2 := get_constant_string_info(call_arg(ci, 1));
    if (has1 && s1.count == 0) || (has2 && s2.count == 0) return const_null_value(vtype(ci));
    if has1 && has2 {
        pos := str_find_first_not_of(s1, s2);
        if pos == NPOS pos = cast(u64) s1.count;
        return const_int(vtype(ci), pos);
    }
    return NONE;
}
// optimizeStrCSpn
lcs_optimize_str_c_spn :: (ci: Value_Id) -> Value_Id {
    has1, s1 := get_constant_string_info(call_arg(ci, 0));
    has2, s2 := get_constant_string_info(call_arg(ci, 1));
    if has1 && s1.count == 0 return const_null_value(vtype(ci));
    if has1 && has2 {
        pos := str_find_first_of(s1, s2);
        if pos == NPOS pos = cast(u64) s1.count;
        return const_int(vtype(ci), pos);
    }
    if has2 && s2.count == 0 return lcs_copy_flags(ci, emit_str_len(call_arg(ci, 0), lcs.tli));
    return NONE;
}
// optimizeStrStr
lcs_optimize_str_str :: (ci: Value_Id) -> Value_Id {
    a0 := call_arg(ci, 0); a1 := call_arg(ci, 1);
    if a0 == a1 return a0;
    if is_only_used_in_equality_comparison(ci, a0) {
        sl := emit_str_len(a1, lcs.tli);
        if sl == NONE return NONE;
        sncmp := emit_str_n_cmp(a0, a1, sl, lcs.tli);
        if sncmp == NONE return NONE;
        u := ir.v_first_use[ci];
        while u != NONE {
            old := ir.u_user[u];
            u = ir.u_next[u];   // early-inc
            cmp := icb_cmp(inst_pred(old), sncmp, const_null_value(vtype(sncmp)), "cmp");
            lcs_replace_all_uses_with(old, cmp);
        }
        return ci;
    }
    has1, search := get_constant_string_info(a0);
    has2, to_find := get_constant_string_info(a1);
    if has2 && to_find.count == 0 return a0;
    if has1 && has2 {
        offset := str_find_str(search, to_find);
        if offset == NPOS return const_null_value(vtype(ci));
        return icb_gep(ir.t_i8, a0, .[lcs_i64(offset)], "strstr", F_INBOUNDS);   // CreateConstInBoundsGEP1_64
    }
    if has2 && to_find.count == 1 return emit_str_chr(a0, to_find[0], lcs.tli);
    annotate_non_null_no_undef_based_on_access(ci, .[0, 1]);
    return NONE;
}

// optimizeMemRChr
lcs_optimize_mem_r_chr :: (ci: Value_Id) -> Value_Id {
    src_str := call_arg(ci, 0); size := call_arg(ci, 2);
    annotate_non_null_and_dereferenceable(ci, .[0], size);
    char_val := call_arg(ci, 1);
    len_c := lcs_const_int(size);
    null_ptr := const_null_value(vtype(ci));
    if len_c {
        if is_null_value(size) return null_ptr;
        if ap_is_one(const_ap(size)) {
            val := lcs_load(ir.t_i8, src_str, "memrchr.char0");
            char_val = icb_trunc(char_val, ir.t_i8);
            cmp := icb_cmp(ICMP_EQ, val, char_val, "memrchr.char0cmp");
            return icb_select(cmp, src_str, null_ptr, "memrchr.sel");
        }
    }
    ok, str := get_constant_string_info(src_str, false);
    if !ok return NONE;
    if str.count == 0 return null_ptr;
    end_off: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    if len_c {
        end_off = lcs_cint_zext(size);
        if cast(u64) str.count < end_off return NONE;
    }
    if lcs_const_int(char_val) {
        pos := str_rfind_char(str, cast(u8)(lcs_cint_zext(char_val) & 0xFF), end_off);   // rfind(char): truncated
        if pos == NPOS return null_ptr;
        if len_c return icb_gep(ir.t_i8, src_str, .[lcs_i64(pos)], "", F_INBOUNDS);
        if str_find_char(str, str[cast(s64) pos]) == pos {
            cmp := icb_cmp(ICMP_ULE, size, const_int(vtype(size), pos), "memrchr.cmp");
            src_plus := icb_gep(ir.t_i8, src_str, .[lcs_i64(pos)], "memrchr.ptr_plus", F_INBOUNDS);
            return icb_select(cmp, null_ptr, src_plus, "memrchr.sel");
        }
    }
    str = lcs_substr(str, end_off);
    if str_find_first_not_of_char(str, str[0]) != NPOS return NONE;
    size_ty := vtype(size);
    nne_z := icb_cmp(ICMP_NE, size, const_int(size_ty, 0));
    char_val = icb_trunc(char_val, ir.t_i8);
    ceq_s0 := icb_cmp(ICMP_EQ, const_int(ir.t_i8, str[0]), char_val);
    and := icb_logical_and(nne_z, ceq_s0);
    size_m1 := icb_sub(size, const_int(size_ty, 1));
    src_plus := icb_gep(ir.t_i8, src_str, .[size_m1], "memrchr.ptr_plus", F_INBOUNDS);
    return icb_select(and, src_plus, null_ptr, "memrchr.sel");
}

// optimizeMemChr
lcs_optimize_mem_chr :: (ci: Value_Id) -> Value_Id {
    src_str := call_arg(ci, 0); size := call_arg(ci, 2);
    if is_known_non_zero(size, lcs_sq_dl()) {
        annotate_non_null_no_undef_based_on_access(ci, .[0]);
        if is_only_used_in_equality_comparison(ci, src_str) return mem_chr_to_char_compare(ci, size);
    }
    char_val := call_arg(ci, 1);
    char_c := lcs_const_int(char_val);
    len_c := lcs_const_int(size);
    null_ptr := const_null_value(vtype(ci));
    if len_c {
        if is_null_value(size) return null_ptr;
        if ap_is_one(const_ap(size)) {
            val := lcs_load(ir.t_i8, src_str, "memchr.char0");
            char_val = icb_trunc(char_val, ir.t_i8);
            cmp := icb_cmp(ICMP_EQ, val, char_val, "memchr.char0cmp");
            return icb_select(cmp, src_str, null_ptr, "memchr.sel");
        }
    }
    ok, str := get_constant_string_info(src_str, false);
    if !ok return NONE;
    if char_c {
        pos := str_find_char(str, cast(u8)(lcs_cint_zext(char_val) & 0xFF));   // StringRef::find(char): truncated
        if pos == NPOS return null_ptr;
        cmp := icb_cmp(ICMP_ULE, size, const_int(vtype(size), pos), "memchr.cmp");
        src_plus := icb_gep(ir.t_i8, src_str, .[lcs_i64(pos)], "memchr.ptr", F_INBOUNDS);
        return icb_select(cmp, null_ptr, src_plus);
    }
    if str.count == 0 return null_ptr;
    if len_c str = lcs_substr(str, lcs_cint_zext(size));
    pos := str_find_first_not_of_char(str, str[0]);
    if pos == NPOS || str_find_first_not_of_char(str, str[cast(s64) pos], pos) == NPOS {
        size_ty := vtype(size);
        char_val = icb_trunc(char_val, ir.t_i8);
        sel1 := null_ptr;
        if pos != NPOS {
            pos_val := const_int(size_ty, pos);
            str_pos := const_int(ir.t_i8, str[cast(s64) pos]);
            ceq_spos := icb_cmp(ICMP_EQ, char_val, str_pos);
            ngt_pos := icb_cmp(ICMP_UGT, size, pos_val);
            and := icb_and(ceq_spos, ngt_pos);
            src_plus := icb_gep(ir.t_i8, src_str, .[pos_val], "", F_INBOUNDS);
            sel1 = icb_select(and, src_plus, null_ptr, "memchr.sel1");
        }
        str0 := const_int(ir.t_i8, str[0]);
        ceq_s0 := icb_cmp(ICMP_EQ, str0, char_val);
        nne_z := icb_cmp(ICMP_NE, size, const_int(size_ty, 0));
        and := icb_and(nne_z, ceq_s0);
        return icb_select(and, src_str, sel1, "memchr.sel2");
    }
    if !len_c {
        if is_only_used_in_equality_comparison(ci, src_str) return mem_chr_to_char_compare(ci, size);
        return NONE;
    }
    opt_for_size := lcs_should_optimize_for_size(inst(ci).parent);
    if opt_for_size || str.count == 0 || !is_only_used_in_zero_equality_comparison(ci) return NONE;
    mx: u8 = 0;
    for i: 0..str.count-1 if str[i] > mx mx = str[i];
    if !dl_fits_in_legal_integer(cast(u64) mx + 1) {
        sorted := copy_string(str,, allocator = temp);
        for i: 1..sorted.count-1 {   // llvm::sort (any order of equal bytes gives the same string)
            x := sorted[i]; j := i - 1;
            while j >= 0 && sorted[j] > x { sorted[j + 1] = sorted[j]; j -= 1; }
            sorted[j + 1] = x;
        }
        non_cont_ranges: u32 = 1;
        for i: 1..sorted.count-1 if cast(s64) sorted[i] > cast(s64) sorted[i - 1] + 1 non_cont_ranges += 1;
        if non_cont_ranges > 2 return NONE;
        char_val = icb_trunc(char_val, ir.t_i8);
        cmps: [..] Value_Id; cmps.allocator = temp;
        for i: 0..sorted.count-1 array_add(*cmps, icb_cmp(ICMP_EQ, char_val, lcs_i8(sorted[i])));
        return icb_cast(.INTTOPTR, icb_or_list(cmps), vtype(ci));
    }
    width := next_power_of_2_u8(max(cast(u8) 7, mx));
    bitfield := ap_zero(width);
    for i: 0..str.count-1 ap_set_bit(*bitfield, cast(u32) str[i]);
    bitfield_c := const_int_ap(type_int(width), bitfield);
    c := icb_zext_or_trunc(char_val, vtype(bitfield_c));
    c = icb_and(c, lcs_int_n(width, 0xFF));
    bounds := icb_cmp(ICMP_ULT, c, lcs_int_n(width, width), "memchr.bounds");
    shl := icb_shl(lcs_int_n(width, 1), c);
    bits := icb_is_not_null(icb_and(shl, bitfield_c), "memchr.bits");
    return icb_cast(.INTTOPTR, icb_logical_and(bounds, bits, "memchr"), vtype(ci));
}
// NextPowerOf2 on an unsigned char (Width = NextPowerOf2(max(7, Max)) truncated to unsigned char)
next_power_of_2_u8 :: (x: u8) -> u32 {
    v := cast(u64) x;
    v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16; v |= v >> 32;
    return cast(u32)((v + 1) & 0xFF);
}
// IRBuilder::CreateOr(ArrayRef<Value*>)
icb_or_list :: (ops: [] Value_Id) -> Value_Id {
    accum := ops[0];
    for i: 1..ops.count-1 accum = icb_or(accum, ops[i]);
    return accum;
}
// shouldOptimizeForSize(BB, PSI, BFI, PGSOQueryType::IRPass): InstCombine has no ProfileSummaryInfo unless it
// was computed (not ported: a module with a profile summary fails loudly)
lcs_should_optimize_for_size :: (bb: Value_Id) -> bool {
    f := block_fn(bb);
    if fn_has_opt_size(f) return true;
    if module_get_flag("ProfileSummary") != NONE fatal("LibCallSimplifier: shouldOptimizeForSize with a profile summary (PGSO) is not supported yet");
    return false;
}

// optimizeMemCmpVarSize(CI, LHS, RHS, Size, StrNCmp, B, DL)
optimize_mem_cmp_var_size :: (ci: Value_Id, lhs: Value_Id, rhs: Value_Id, size: Value_Id, str_n_cmp: bool) -> Value_Id {
    if lhs == rhs return const_null_value(vtype(ci));
    okl, lstr := get_constant_string_info(lhs, false);
    if !okl return NONE;
    okr, rstr := get_constant_string_info(rhs, false);
    if !okr return NONE;
    pos: u64 = 0;
    zero := const_int(vtype(ci), 0);
    min_size := cast(u64) min(lstr.count, rstr.count);
    while true {
        if pos == min_size || (str_n_cmp && (lstr[cast(s64) pos] == 0 && rstr[cast(s64) pos] == 0)) return zero;
        if lstr[cast(s64) pos] != rstr[cast(s64) pos] break;
        pos += 1;
    }
    ires: s64 = ifx lstr[cast(s64) pos] < rstr[cast(s64) pos] then -1 else 1;
    max_size := const_int(vtype(size), pos);
    cmp := icb_cmp(ICMP_ULE, size, max_size);
    res := const_int_signed(vtype(ci), ires);
    return icb_select(cmp, zero, res);
}

// optimizeMemCmpConstantSize(CI, LHS, RHS, Len, B, DL)
optimize_mem_cmp_constant_size :: (ci: Value_Id, lhs: Value_Id, rhs: Value_Id, len: u64) -> Value_Id {
    if len == 0 return const_null_value(vtype(ci));
    if len == 1 {
        lhsv := icb_zext(lcs_load(ir.t_i8, lhs, "lhsc"), vtype(ci), "lhsv");
        rhsv := icb_zext(lcs_load(ir.t_i8, rhs, "rhsc"), vtype(ci), "rhsv");
        return icb_sub(lhsv, rhsv, "chardiff");
    }
    if dl_is_legal_integer(len * 8) && is_only_used_in_zero_equality_comparison(ci) {
        int_type := type_int(cast(u32)(len * 8));
        pref_align := dl_pref_align(int_type);
        lhsv: Value_Id = NONE;
        if is_const(lhs) lhsv = cfo_load_from_const_ptr(lhs, int_type);
        rhsv: Value_Id = NONE;
        if is_const(rhs) rhsv = cfo_load_from_const_ptr(rhs, int_type);
        if (lhsv != NONE || get_or_enforce_known_alignment(lhs, 0, ci, null, null) >= pref_align) &&
           (rhsv != NONE || get_or_enforce_known_alignment(rhs, 0, ci, null, null) >= pref_align) {
            if lhsv == NONE lhsv = lcs_load(int_type, lhs, "lhsv");
            if rhsv == NONE rhsv = lcs_load(int_type, rhs, "rhsv");
            return icb_zext(icb_cmp(ICMP_NE, lhsv, rhsv), vtype(ci), "memcmp");
        }
    }
    return NONE;
}

// optimizeMemCmpBCmpCommon
lcs_optimize_mem_cmp_b_cmp_common :: (ci: Value_Id) -> Value_Id {
    lhs := call_arg(ci, 0); rhs := call_arg(ci, 1); size := call_arg(ci, 2);
    annotate_non_null_and_dereferenceable(ci, .[0, 1], size);
    res := optimize_mem_cmp_var_size(ci, lhs, rhs, size, false);
    if res != NONE return res;
    if !lcs_const_int(size) return NONE;
    return optimize_mem_cmp_constant_size(ci, lhs, rhs, lcs_cint_zext(size));
}
// optimizeMemCmp
lcs_optimize_mem_cmp :: (ci: Value_Id) -> Value_Id {
    v := lcs_optimize_mem_cmp_b_cmp_common(ci);
    if v != NONE return v;
    if is_lib_func_emittable(lcs.tli, .bcmp) && is_only_used_in_zero_equality_comparison(ci)
        return lcs_copy_flags(ci, emit_b_cmp(call_arg(ci, 0), call_arg(ci, 1), call_arg(ci, 2), lcs.tli));
    return NONE;
}
lcs_optimize_b_cmp :: (ci: Value_Id) -> Value_Id { return lcs_optimize_mem_cmp_b_cmp_common(ci); }

// optimizeMemCpy
lcs_optimize_mem_cpy :: (ci: Value_Id) -> Value_Id {
    size := call_arg(ci, 2);
    annotate_non_null_and_dereferenceable(ci, .[0, 1], size);
    if call_iid(ci) != NOT_INTRINSIC return NONE;
    new_ci := icb_mem_transfer(IID_MEMCPY, call_arg(ci, 0), 1, call_arg(ci, 1), 1, size, false);
    merge_attributes_and_flags(new_ci, ci);
    return call_arg(ci, 0);
}
// optimizeMemCCpy
lcs_optimize_mem_c_cpy :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); src := call_arg(ci, 1);
    stop := call_arg(ci, 2); n := call_arg(ci, 3);
    stop_c := lcs_const_int(stop); n_c := lcs_const_int(n);
    if !has_uses(ci) && dst == src return dst;
    src_str: string;
    if n_c {
        if is_null_value(n) return const_null_value(vtype(ci));
        ok, s := get_constant_string_info(src, false);
        if !ok || !stop_c return NONE;
        src_str = s;
    } else return NONE;
    pos := str_find_char(src_str, cast(u8)(const_int_sext(stop) & 0xFF));
    nz := lcs_cint_zext(n);
    if pos == NPOS {
        if nz <= cast(u64) src_str.count {
            lcs_copy_flags(ci, icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, n, false));
            return const_null_value(vtype(ci));
        }
        return NONE;
    }
    new_n := const_int(vtype(n), min(pos + 1, nz));
    lcs_copy_flags(ci, icb_mem_transfer(IID_MEMCPY, dst, 1, src, 1, new_n, false));
    if pos + 1 <= nz return icb_gep(ir.t_i8, dst, .[new_n], "", F_INBOUNDS);
    return const_null_value(vtype(ci));
}
// optimizeMemPCpy
lcs_optimize_mem_p_cpy :: (ci: Value_Id) -> Value_Id {
    dst := call_arg(ci, 0); n := call_arg(ci, 2);
    new_ci := icb_mem_transfer(IID_MEMCPY, dst, 1, call_arg(ci, 1), 1, n, false);
    merge_attributes_and_flags(new_ci, ci);
    return icb_gep(ir.t_i8, dst, .[n], "", F_INBOUNDS);
}
// optimizeMemMove
lcs_optimize_mem_move :: (ci: Value_Id) -> Value_Id {
    size := call_arg(ci, 2);
    annotate_non_null_and_dereferenceable(ci, .[0, 1], size);
    if call_iid(ci) != NOT_INTRINSIC return NONE;
    new_ci := icb_mem_transfer(IID_MEMMOVE, call_arg(ci, 0), 1, call_arg(ci, 1), 1, size, false);
    merge_attributes_and_flags(new_ci, ci);
    return call_arg(ci, 0);
}
// optimizeMemSet
lcs_optimize_mem_set :: (ci: Value_Id) -> Value_Id {
    size := call_arg(ci, 2);
    annotate_non_null_and_dereferenceable(ci, .[0], size);
    if call_iid(ci) != NOT_INTRINSIC return NONE;
    val := icb_int_cast(call_arg(ci, 1), ir.t_i8, false);
    new_ci := icb_memset(call_arg(ci, 0), val, size, 1);
    merge_attributes_and_flags(new_ci, ci);
    return call_arg(ci, 0);
}
// optimizeRealloc
lcs_optimize_realloc :: (ci: Value_Id) -> Value_Id {
    if lcs_is_null_ptr(call_arg(ci, 0)) return lcs_copy_flags(ci, emit_malloc(call_arg(ci, 1), lcs.tli));
    return NONE;
}

// -optimize-hot-cold-new and friends (SimplifyLibCalls.cpp cl::opts)
lcs_optimize_hot_cold_new := false;
lcs_optimize_existing_hot_cold_new := false;
lcs_optimize_nobuiltin_hot_cold_new := false;
lcs_cold_new_hint_value: u64 = 1;
lcs_notcold_new_hint_value: u64 = 128;
lcs_hot_new_hint_value: u64 = 254;
lcs_ambiguous_new_hint_value: u64 = 222;

// maybeOptimizeNoBuiltinOperatorNew
lcs_maybe_optimize_no_builtin_operator_new :: (ci: Value_Id) -> Value_Id {
    if !lcs_optimize_hot_cold_new return NONE;
    callee := call_called_function(ci);
    if callee == NONE return NONE;
    ok, f := tli_lookup_fn(callee);
    if !ok return NONE;
    if f == {
        case .Znwm; #through; case .ZnwmRKSt9nothrow_t; #through; case .ZnwmSt11align_val_t; #through;
        case .ZnwmSt11align_val_tRKSt9nothrow_t; #through; case .Znam; #through; case .ZnamRKSt9nothrow_t; #through;
        case .ZnamSt11align_val_t; #through; case .ZnamSt11align_val_tRKSt9nothrow_t; #through;
        case .size_returning_new; #through; case .size_returning_new_aligned;
            if !lcs_optimize_nobuiltin_hot_cold_new return NONE;
        case .Znwm12__hot_cold_t; #through; case .ZnwmRKSt9nothrow_t12__hot_cold_t; #through;
        case .ZnwmSt11align_val_t12__hot_cold_t; #through; case .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t; #through;
        case .Znam12__hot_cold_t; #through; case .ZnamRKSt9nothrow_t12__hot_cold_t; #through;
        case .ZnamSt11align_val_t12__hot_cold_t; #through; case .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t; #through;
        case .size_returning_new_hot_cold; #through; case .size_returning_new_aligned_hot_cold;
            if !lcs_optimize_existing_hot_cold_new return NONE;
        case; return NONE;
    }
    return lcs_optimize_new(ci, f);
}

// optimizeNew(CI, B, Func)
lcs_optimize_new :: (ci: Value_Id, f: Lib_Func) -> Value_Id {
    if !lcs_optimize_hot_cold_new return NONE;
    hot_cold: u64;
    mp := ""; has_mp := false;
    for attr_set_items(attr_list_fn(inst(ci).attrs)) if it.kind == .STRING_ATTR && it.key == "memprof" { mp = it.val; has_mp = true; }
    if mp == "cold" hot_cold = lcs_cold_new_hint_value;
    else if mp == "notcold" hot_cold = lcs_notcold_new_hint_value;
    else if mp == "hot" hot_cold = lcs_hot_new_hint_value;
    else if mp == "ambiguous" hot_cold = lcs_ambiguous_new_hint_value;
    else return NONE;
    t := lcs.tli;
    hc := lcs_i8(hot_cold);
    a0 := call_arg(ci, 0);
    existing := lcs_optimize_existing_hot_cold_new;
    new_call: Value_Id = NONE;
    // emitHotColdNew (Num, hint) / NoThrow (Num, NoThrow, hint) / Aligned (Num, Align, hint) /
    // AlignedNoThrow (Num, Align, NoThrow, hint); emitHotColdSizeReturningNew[Aligned] return {ptr, size_t}
    plain :: (t: *Tli, lf: Lib_Func, args: [] Value_Id) -> Value_Id { return emit_hot_cold_new_any(t, lf, ir.t_ptr, args, ""); }
    sized :: (t: *Tli, lf: Lib_Func, args: [] Value_Id) -> Value_Id {
        ret := type_literal_struct(.[ir.t_ptr, vtype(args[0])], false);
        return emit_hot_cold_new_any(t, lf, ret, args, "sized_ptr");
    }
    if f == {
        case .Znwm12__hot_cold_t; if existing new_call = plain(t, .Znwm12__hot_cold_t, .[a0, hc]);
        case .Znwm; new_call = plain(t, .Znwm12__hot_cold_t, .[a0, hc]);
        case .Znam12__hot_cold_t; if existing new_call = plain(t, .Znam12__hot_cold_t, .[a0, hc]);
        case .Znam; new_call = plain(t, .Znam12__hot_cold_t, .[a0, hc]);
        case .ZnwmRKSt9nothrow_t12__hot_cold_t; if existing new_call = plain(t, .ZnwmRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnwmRKSt9nothrow_t; new_call = plain(t, .ZnwmRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnamRKSt9nothrow_t12__hot_cold_t; if existing new_call = plain(t, .ZnamRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnamRKSt9nothrow_t; new_call = plain(t, .ZnamRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnwmSt11align_val_t12__hot_cold_t; if existing new_call = plain(t, .ZnwmSt11align_val_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnwmSt11align_val_t; new_call = plain(t, .ZnwmSt11align_val_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnamSt11align_val_t12__hot_cold_t; if existing new_call = plain(t, .ZnamSt11align_val_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnamSt11align_val_t; new_call = plain(t, .ZnamSt11align_val_t12__hot_cold_t, .[a0, call_arg(ci, 1), hc]);
        case .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t;
            if existing new_call = plain(t, .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), call_arg(ci, 2), hc]);
        case .ZnwmSt11align_val_tRKSt9nothrow_t;
            new_call = plain(t, .ZnwmSt11align_val_tRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), call_arg(ci, 2), hc]);
        case .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t;
            if existing new_call = plain(t, .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), call_arg(ci, 2), hc]);
        case .ZnamSt11align_val_tRKSt9nothrow_t;
            new_call = plain(t, .ZnamSt11align_val_tRKSt9nothrow_t12__hot_cold_t, .[a0, call_arg(ci, 1), call_arg(ci, 2), hc]);
        case .size_returning_new; new_call = sized(t, .size_returning_new_hot_cold, .[a0, hc]);
        case .size_returning_new_hot_cold; if existing new_call = sized(t, .size_returning_new_hot_cold, .[a0, hc]);
        case .size_returning_new_aligned; new_call = sized(t, .size_returning_new_aligned_hot_cold, .[a0, call_arg(ci, 1), hc]);
        case .size_returning_new_aligned_hot_cold; if existing new_call = sized(t, .size_returning_new_aligned_hot_cold, .[a0, call_arg(ci, 1), hc]);
        case; return NONE;
    }
    if new_call != NONE && is_inst(new_call) copy_metadata(new_call, ci);
    return new_call;
}
