// The abstract attributes AttributorLight allows: a port of their parts of
// llvm/lib/Transforms/IPO/AttributorAttributes.cpp (AANoUnwind, AANoSync, AANoFree, AANonNull, AAMustProgress,
// AANoRecurse, AAWillReturn, AAIntraFnReachability, AANoReturn, AANoCapture, AAMemoryBehavior, AAMemoryLocation,
// AADenormalFPMath, AANoFPClass, AACallEdges, AAInterFnReachability, AAUnderlyingObjects; the generic helpers
// clampReturnedValueStates, clampCallSiteArgumentStates, AACalleeToCallSite, followUsesInMBEC) and their
// isImpliedByIR from llvm/include/llvm/Transforms/IPO/Attributor.h. The framework is attributor.jai.
//
// The class of an AA (e.g. AANoFreeFloating vs. AANoFreeCallSiteArgument) is its (kind, position kind) pair; the
// virtual methods are the switches aa_initialize / aa_update_impl / aa_manifest below.

// AANoCapture
NC_NOT_CAPTURED_IN_MEM :: cast(u32) 1;
NC_NOT_CAPTURED_IN_INT :: cast(u32) 2;
NC_NOT_CAPTURED_IN_RET :: cast(u32) 4;
NC_NO_CAPTURE_MAYBE_RETURNED :: cast(u32) 3;
NC_NO_CAPTURE :: cast(u32) 7;
nc_maybe_returned :: (i: u32) -> bool { return bs_is_assumed(aa(i).s, NC_NO_CAPTURE_MAYBE_RETURNED); }

// AAMemoryBehavior
MB_NO_READS :: cast(u32) 1;
MB_NO_WRITES :: cast(u32) 2;
MB_NO_ACCESSES :: cast(u32) 3;

// AAMemoryLocation
ML_NO_LOCAL_MEM :: cast(u32) 1;
ML_NO_CONST_MEM :: cast(u32) 2;
ML_NO_GLOBAL_INTERNAL_MEM :: cast(u32) 4;
ML_NO_GLOBAL_EXTERNAL_MEM :: cast(u32) 8;
ML_NO_GLOBAL_MEM :: cast(u32) 12;
ML_NO_ARGUMENT_MEM :: cast(u32) 16;
ML_NO_INACCESSIBLE_MEM :: cast(u32) 32;
ML_NO_MALLOCED_MEM :: cast(u32) 64;
ML_NO_UNKOWN_MEM :: cast(u32) 128;
ML_NO_LOCATIONS :: cast(u32) 255;
ML_VALID_STATE :: cast(u32) 256;
ML_BEST_STATE :: cast(u32) 511;
ML_NONE :: cast(u8) 0; ML_READ :: cast(u8) 1; ML_WRITE :: cast(u8) 2; ML_READ_WRITE :: cast(u8) 3;

ml_inverse_location :: (loc: u32, and_local: bool, and_const: bool) -> u32 {
    m := loc;
    if and_local m |= ML_NO_LOCAL_MEM;
    if and_const m |= ML_NO_CONST_MEM;
    return ML_NO_LOCATIONS & ~m;
}
ml_is_assumed_stack_only :: (s: Bstate) -> bool { return bs_is_assumed(s, ml_inverse_location(ML_NO_LOCAL_MEM, true, true)); }
ml_is_assumed_read_none :: (s: Bstate) -> bool { return bs_is_assumed(s, ML_NO_LOCATIONS) || ml_is_assumed_stack_only(s); }
ml_is_known_read_none :: (s: Bstate) -> bool { return bs_is_known(s, ML_NO_LOCATIONS); }
ml_is_assumed_inaccessible_only :: (s: Bstate) -> bool { return bs_is_assumed(s, ml_inverse_location(ML_NO_INACCESSIBLE_MEM, true, true)); }
ml_is_assumed_arg_only :: (s: Bstate) -> bool { return bs_is_assumed(s, ml_inverse_location(ML_NO_ARGUMENT_MEM, true, true)); }
ml_is_assumed_inaccessible_or_arg_only :: (s: Bstate) -> bool {
    return bs_is_assumed(s, ml_inverse_location(ML_NO_INACCESSIBLE_MEM | ML_NO_ARGUMENT_MEM, true, true));
}

SYNC_SCOPE_SINGLE_THREAD :: 1;

// ---------------------------------------------------------------- isImpliedByIR

// AAWillReturn::isImpliedByMustprogressAndReadonly (the static one)
aa_implied_by_mustprogress_and_readonly :: (p: Irp) -> bool {
    if !atr_has_attr(p, .[.MustProgress]) return false;
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Memory], *attrs);
    me: u64 = MEM_UNKNOWN;
    for attrs me &= it.ival;
    return mem_only_reads(me);
}
// AAWillReturn::isImpliedByIR
aa_will_return_implied_by_ir :: (p: Irp, ign: bool) -> bool {
    if atr_default_implied_by_ir(p, .WillReturn, ign) return true;
    if !aa_implied_by_mustprogress_and_readonly(p) return false;
    atr_manifest_attrs(p, .[attr_enum(.WillReturn)]);
    return true;
}
// AANoSync::isImpliedByIR
aa_no_sync_implied_by_ir :: (p: Irp, ign: bool) -> bool {
    if atr_has_attr(p, .[.NoSync], ign, .NoSync) return true;
    f := irp_assoc_fn(p);
    if f == NONE || fn_has_fn_attr(f, .Convergent) return false;
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Memory], *attrs, ign);
    me: u64 = MEM_UNKNOWN;
    for attrs me &= it.ival;
    if !mem_only_reads(me) return false;
    atr_manifest_attrs(p, .[attr_enum(.NoSync)]);
    return true;
}
// AANoAlias::isImpliedByIR
aa_no_alias_implied_by_ir :: (p: Irp, ign_in: bool) -> bool {
    ign := ign_in;
    v := irp_assoc_value(p);
    if irp_kind(p) != .CALL_SITE_ARGUMENT {
        if is_inst(v) && inst_op(v) == .ALLOCA return true;
    } else {
        ign = true;
    }
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON return true;
    if k == .C_NULL && !null_pointer_is_defined(irp_anchor_scope(p), ptr_addrspace(vtype(v))) return true;
    return atr_has_attr(p, .[.ByVal, .NoAlias], ign, .NoAlias);
}
// AANonNull::isImpliedByIR
aa_non_null_implied_by_ir :: (p: Irp, ign: bool) -> bool {
    kinds: [2] Attr_Kind;
    kinds[0] = .NonNull;
    nk := 1;
    if !null_pointer_is_defined(irp_anchor_scope(p), ptr_addrspace(irp_assoc_type(p))) { kinds[1] = .Dereferenceable; nk = 2; }
    kv: [] Attr_Kind; kv.data = kinds.data; kv.count = nk;
    if atr_has_attr(p, kv, ign, .NonNull) return true;
    dt: *Dom_Tree = null;
    ac: *Assumption_Cache = null;
    f := irp_anchor_scope(p);
    if f != NONE && !is_declaration(f) { dt = atr_dt(f); ac = atr_ac(f); }
    vals: [..] Value_Id; vals.allocator = temp;
    ctxs: [..] Value_Id; ctxs.allocator = temp;
    if irp_kind(p) != .RETURNED {
        array_add(*vals, irp_assoc_value(p));
        array_add(*ctxs, irp_ctx_i(p));
    } else {
        ok, rets := atr_insts(irp_assoc_fn(p), .[.RET]);
        if !ok return false;
        for rets { array_add(*vals, op(it, 0)); array_add(*ctxs, it); }
    }
    for v: vals {
        q: Simplify_Query;
        q.dt = dt; q.ac = ac; q.cxt = ctxs[it_index]; q.have_tli = false;
        if !is_known_non_zero(v, q) return false;
    }
    atr_manifest_attrs(p, .[attr_enum(.NonNull)]);
    return true;
}
// AANoCapture::isImpliedByIR
aa_no_capture_implied_by_ir :: (p: Irp, ign: bool) -> bool {
    v := irp_assoc_value(p);
    k := vkind(v);
    if !is_constant_kind(k) && !irp_is_argument_position(p) return !has_uses(v);
    if k == .C_UNDEF || k == .C_POISON || (k == .C_NULL && ptr_addrspace(vtype(v)) == 0) return true;
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Captures], *attrs, true);
    for attrs if it.ival == 0 return true;
    if irp_kind(p) == .CALL_SITE_ARGUMENT {
        a := irp_assoc_arg(p);
        if a != NONE {
            attrs.count = 0;
            atr_get_attrs(irp_argument(a), .[.Captures, .ByVal], *attrs, true);
            no_capture := false;
            for attrs if it.kind == .ByVal || it.ival == 0 no_capture = true;
            if no_capture {
                atr_manifest_attrs(p, .[attr_enum(.Captures, 0)]);
                return true;
            }
        }
    }
    f := irp_assoc_fn(p);
    if f != NONE {
        st := bs_new(NC_NO_CAPTURE);
        nc_determine_function_capture_capabilities(p, f, *st);
        if bs_is_known(st, NC_NO_CAPTURE) {
            atr_manifest_attrs(p, .[attr_enum(.Captures, 0)]);
            return true;
        }
    }
    return false;
}
// AANoCapture::determineFunctionCaptureCapabilities
nc_determine_function_capture_capabilities :: (p: Irp, f: Value_Id, st: *Bstate) {
    read_only := mem_only_reads(fn_memory_effects(f));
    no_throw := fn_has_fn_attr(f, .NoUnwind);
    is_void := type_kind(fn_ret_type(f)) == .VOID;
    if read_only && no_throw && is_void { bs_add_known(st, NC_NO_CAPTURE); return; }
    if read_only bs_add_known(st, NC_NOT_CAPTURED_IN_MEM);
    if no_throw && is_void bs_add_known(st, NC_NOT_CAPTURED_IN_RET);
    argno := irp_callee_arg_no(p);
    if !no_throw || argno < 0 || !fn_has_attr_somewhere(f, .Returned) return;
    for u: 0..cast(s64) fn_nargs(f) - 1 {
        if !arg_has_attr(fn_arg(f, cast(u32) u), .Returned) continue;
        if u == argno bs_remove_assumed(st, NC_NOT_CAPTURED_IN_RET);
        else if read_only bs_add_known(st, NC_NO_CAPTURE);
        else bs_add_known(st, NC_NOT_CAPTURED_IN_RET);
        break;
    }
}

// ---------------------------------------------------------------- generic helpers

call_is_arg_operand :: (cb: Value_Id, u: Use_Id) -> bool { return (u - ir.v_ops[cb]) < call_num_args(cb); }
call_is_callee_use :: (cb: Value_Id, u: Use_Id) -> bool { return u == op_use(cb, nops(cb) - 1); }
call_is_bundle_operand :: (cb: Value_Id, u: Use_Id) -> bool {
    nb := call_num_bundles(cb);
    if nb == 0 return false;
    opno := u - ir.v_ops[cb];
    b0, _ := call_bundle_range(cb, 0);
    _, e1 := call_bundle_range(cb, nb - 1);
    return opno >= b0 && opno < e1;
}
use_arg_no :: inline (u: Use_Id) -> u32 { return u - ir.v_ops[ir.u_user[u]]; }

// AACalleeToCallSite::updateImpl; `ak` is the IR attribute kind (NONE_ATTR: not an enum attribute, clamp states)
aa_callee_to_call_site :: (i: u32, ak: Attr_Kind) -> bool {
    p := aa(i).pos;
    pk := aa(i).pk;
    kind := aa(i).kind;
    cb := irp_anchor(p);
    ok, callees := atr_callees(i, cb);
    if !ok return aa_pessimistic(i);
    changed := ATR_UNCHANGED;
    for callee: callees {
        fpos := ifx pk == .CALL_SITE_RETURNED then irp_returned(callee) else irp_function(callee);
        if ak != .NONE_ATTR {
            has, _ := atr_has_assumed_ir_attr(ak, i, fpos, DEP_REQUIRED);
            if !has return aa_pessimistic(i);
            continue;
        }
        o := atr_get_aa(kind, fpos, i, DEP_REQUIRED);
        if o == NONE return aa_pessimistic(i);
        changed |= bs_clamp_and_indicate(*aa(i).s, aa(o).s);
        if bs_is_fix(aa(i).s) {
            if bs_is_valid(aa(i).s) return changed;
            return aa_pessimistic(i);
        }
    }
    return changed;
}

// clampCallSiteArgumentStates into a fresh best state, then clampStateAndIndicateChange (AAArgumentFromCallSiteArguments)
aa_argument_from_call_site_arguments :: (i: u32, ak: Attr_Kind) -> bool {
    p := aa(i).pos;
    kind := aa(i).kind;
    s := bs_new(aa(i).s.best);
    t: Bstate;
    have_t := false;
    argno := cast(u32) irp_cs_arg_no(p);
    sites, complete := atr_call_sites(irp_assoc_fn(p), true);
    failed := !complete;
    for cb: sites {
        if call_num_args(cb) <= argno { failed = true; break; }
        cpos := irp_cs_argument(cb, argno);
        if ak != .NONE_ATTR {
            has, _ := atr_has_assumed_ir_attr(ak, i, cpos, DEP_REQUIRED);
            if !has { failed = true; break; }
            continue;
        }
        o := atr_get_aa(kind, cpos, i, DEP_REQUIRED);
        if o == NONE { failed = true; break; }
        if !have_t { t = bs_new(aa(o).s.best); have_t = true; }
        bs_join_and(*t, aa(o).s);
        if !bs_is_valid(t) { failed = true; break; }
    }
    if failed bs_pessimistic(*s);
    else if have_t bs_clamp(*s, t);
    return bs_clamp_and_indicate(*aa(i).s, s);
}

// AAReturnedFromReturnedValues: checkForAllReturnedValues fails without AAPotentialValues, so the clamped state is
// the pessimistic one
aa_returned_from_returned_values :: (i: u32) -> bool {
    s := bs_new(aa(i).s.best);
    bs_pessimistic(*s);
    return bs_clamp_and_indicate(*aa(i).s, s);
}

// followUsesInMBEC
Use_Set :: struct { list: [..] Use_Id; member: Table(Use_Id, bool); }
uset_insert :: (s: *Use_Set, u: Use_Id) { if table_contains(*s.member, u) return; table_set(*s.member, u, true); array_add(*s.list, u); }

aa_follow_uses_in_mbec :: (i: u32, ctx: Value_Id, st: *Bstate) {
    v := irp_assoc_value(aa(i).pos);
    if is_constant_data(v) return;
    uses: Use_Set;
    uses.list.allocator = temp; uses.member.allocator = temp;
    u := ir.v_first_use[v];
    while u != NONE { uset_insert(*uses, u); u = ir.u_next[u]; }
    aa_follow_uses_in_context(i, ctx, *uses, st);
    if bs_is_fix(st.*) return;
    brs: [..] Value_Id; brs.allocator = temp;
    it := mbe_begin(ctx);
    while !mbe_at_end(*it) {
        if inst_op(it.cur) == .CONDBR array_add(*brs, it.cur);
        mbe_advance(*it);
    }
    for br: brs {
        parent := bs_new(st.best);
        bs_optimistic(*parent);
        for k: 0..cast(s64) num_successors(br) - 1 {
            bb := get_successor(br, cast(u32) k);
            child := bs_new(st.best);
            before := uses.list.count;
            aa_follow_uses_in_context(i, block_first(bb), *uses, *child);
            for x: before..uses.list.count - 1 table_remove(*uses.member, uses.list[x]);
            uses.list.count = before;
            bs_join_and(*parent, child);
        }
        bs_add_known_of(st, parent);
    }
}
// followUsesInContext
aa_follow_uses_in_context :: (i: u32, ctx: Value_Id, uses: *Use_Set, st: *Bstate) {
    it := mbe_begin(ctx);
    u := 0;
    while u < uses.list.count {
        cu := uses.list[u];
        u += 1;
        user := ir.u_user[cu];
        if !is_inst(user) continue;
        found := mbe_find_in_context_of(user, *it);
        if found && aa_follow_use_in_mbec(i, cu, user, st) {
            x := ir.v_first_use[user];
            while x != NONE { uset_insert(uses, x); x = ir.u_next[x]; }
        }
    }
}
aa_follow_use_in_mbec :: (i: u32, u: Use_Id, user: Value_Id, st: *Bstate) -> bool {
    if aa(i).kind == .NON_NULL {
        _, non_null, track := nn_known_non_null_and_deref_bytes_for_use(i, irp_assoc_value(aa(i).pos), u, user);
        if non_null bs_add_known(st, 1);
        return track;
    }
    // AANoFPClassImpl::followUseInMBEC
    if !is_call_base(user) || !call_is_arg_operand(user, u) return false;
    o := atr_get_aa(.NO_FPCLASS, irp_cs_argument(user, use_arg_no(u)), i, DEP_NONE);
    if o != NONE bs_add_known(st, aa(o).s.known);
    return false;
}

// getKnownNonNullAndDerefBytesForUse: (deref bytes, IsNonNull, TrackUse)
nn_known_non_null_and_deref_bytes_for_use :: (q: u32, assoc: Value_Id, u: Use_Id, i: Value_Id) -> (s64, bool, bool) {
    use_v := ir.u_val[u];
    if !is_ptr_type(vtype(use_v)) return 0, false, false;
    o := inst_op(i);
    if is_cast_op(o) || o == .GEP return 0, false, true;
    npid := null_pointer_is_defined(inst_fn(i), ptr_addrspace(vtype(use_v)));
    if is_call_base(i) {
        if call_is_bundle_operand(i, u) {
            found, kind, arg := atr_knowledge_from_use(u);
            if found return cast(s64) arg, kind == .NonNull || !npid, false;
            return 0, false, false;
        }
        if call_is_callee_use(i, u) return 0, !npid, false;
        _, known := atr_has_assumed_ir_attr(.NonNull, q, irp_cs_argument(i, use_arg_no(u)), DEP_NONE);
        return 0, known, false;   // AADereferenceable is not allowed
    }
    ok, loc := mloc_get_or_none(i);
    if !ok || loc.ptr != use_v || !ls_has_value(loc.size) || !ls_is_precise(loc.size) || ls_is_scalable(loc.size) || is_volatile(i)
        return 0, false, false;
    // getMinimalBaseOfPointer (the AAValueConstantRange external analysis is not allowed)
    off := ap_zero(dl_index_type_size_bits(vtype(loc.ptr)));
    base, offset := strip_and_accumulate_constant_offsets(loc.ptr, off, false, true);
    if base != NONE && base == assoc {
        deref := cast(s64) ls_value(loc.size) + ap_sext_value(offset);
        return max(0, deref), !npid, false;
    }
    base2, off2 := get_pointer_base_with_constant_offset(loc.ptr);
    if base2 != NONE && base2 == assoc && off2 == 0 return cast(s64) ls_value(loc.size), !npid, false;
    return 0, false, false;
}

// ---------------------------------------------------------------- initialize

aa_initialize :: (i: u32) {
    a := aa(i);
    p := a.pos;
    pk := a.pk;
    if a.kind == {
        case .WILL_RETURN;
            if pk == .FUNCTION {
                f := irp_anchor_scope(p);
                if is_declaration(f) || wr_may_contain_unbounded_cycle(f) aa_pessimistic(i);
            }
        case .NON_NULL;
            if pk == .RETURNED return;   // AANonNullReturned derives from AANonNull, not AANonNullImpl
            v := strip_pointer_casts(irp_assoc_value(p));
            if vkind(v) == .C_NULL { aa_pessimistic(i); return; }
            ctx := irp_ctx_i(p);
            if ctx != NONE aa_follow_uses_in_mbec(i, ctx, *aa(i).s);
        case .NO_CAPTURE;
            if pk == .CALL_SITE_RETURNED nc_determine_function_capture_capabilities(p, irp_anchor_scope(p), *aa(i).s);
        case .MEM_BEHAVIOR;
            if pk == .ARGUMENT { mb_argument_initialize(i); return; }
            if pk == .CALL_SITE_ARGUMENT {
                arg := irp_assoc_arg(p);
                if arg == NONE { aa_pessimistic(i); return; }
                if arg_has_attr(arg, .ByVal) {
                    bs_add_known(*aa(i).s, MB_NO_WRITES);
                    bs_remove_known(*aa(i).s, MB_NO_READS);
                    bs_remove_assumed(*aa(i).s, MB_NO_READS);
                }
                mb_argument_initialize(i);
                if is_declaration(irp_assoc_fn(p)) aa_pessimistic(i);
                return;
            }
            bs_intersect_assumed(*aa(i).s, MB_NO_ACCESSES);
            mb_known_state_from_value(p, i, false);
        case .MEM_LOCATION;
            bs_intersect_assumed(*aa(i).s, ML_BEST_STATE);
            ml_known_state_from_value(p, i);
        case .NO_FPCLASS;
            fpc_initialize(i);
        case .DENORMAL_FP;
            f := irp_anchor_scope(p);
            m: u32 = 0;
            at := fn_get_fn_attr(f, .DenormalFPEnv);
            if at m = cast(u32) at.ival;
            aa(i).dn_mode = m;
            if dn_is_mode_fixed(m) aa(i).dn_fix = true;
    }
}

// AAMemoryBehaviorImpl::getKnownStateFromValue
mb_known_state_from_value :: (p: Irp, i: u32, ign: bool) {
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.ReadNone, .ReadOnly, .WriteOnly], *attrs, ign);
    for attrs {
        if it.kind == .ReadNone bs_add_known(*aa(i).s, MB_NO_ACCESSES);
        else if it.kind == .ReadOnly bs_add_known(*aa(i).s, MB_NO_WRITES);
        else bs_add_known(*aa(i).s, MB_NO_READS);
    }
    anchor := irp_anchor(p);
    if is_inst(anchor) {
        if !may_read_from_memory(anchor) bs_add_known(*aa(i).s, MB_NO_READS);
        if !may_write_to_memory(anchor) bs_add_known(*aa(i).s, MB_NO_WRITES);
    }
}
// AAMemoryBehaviorArgument::initialize
mb_argument_initialize :: (i: u32) {
    bs_intersect_assumed(*aa(i).s, MB_NO_ACCESSES);
    p := aa(i).pos;
    has_byval := atr_has_attr(p, .[.ByVal], true);
    mb_known_state_from_value(p, i, has_byval);
}

// AAMemoryLocationImpl::getKnownStateFromValue
ml_known_state_from_value :: (p: Irp, i: u32) {
    use_arg_mem_only := true;
    anchor_fn := irp_anchor_scope(p);
    if anchor_fn != NONE && atr_is_run_on(anchor_fn) use_arg_mem_only = !gv_has_local_linkage(anchor_fn);
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.Memory], *attrs);
    for at: attrs {
        me := at.ival;
        if me == 0 { bs_add_known(*aa(i).s, ML_NO_LOCAL_MEM | ML_NO_CONST_MEM); continue; }
        if me_without_loc(me, LOC_INACCESSIBLE) == 0 {
            bs_add_known(*aa(i).s, ml_inverse_location(ML_NO_INACCESSIBLE_MEM, true, true));
            continue;
        }
        if me_without_loc(me, LOC_ARG) == 0 {
            if use_arg_mem_only bs_add_known(*aa(i).s, ml_inverse_location(ML_NO_ARGUMENT_MEM, true, true));
            else atr_manifest_attrs(p, .[attr_enum(.Memory, mem_all(me_mod_ref(me)))], true);
            continue;
        }
        if me_without_loc(me_without_loc(me, LOC_INACCESSIBLE), LOC_ARG) == 0 {
            if use_arg_mem_only bs_add_known(*aa(i).s, ml_inverse_location(ML_NO_INACCESSIBLE_MEM | ML_NO_ARGUMENT_MEM, true, true));
            else atr_manifest_attrs(p, .[attr_enum(.Memory, mem_all(me_mod_ref(me)))], true);
            continue;
        }
    }
}

// AANoFPClassImpl::initialize
fpc_initialize :: (i: u32) {
    p := aa(i).pos;
    v := irp_assoc_value(p);
    k := vkind(v);
    if k == .C_UNDEF || k == .C_POISON { aa_optimistic(i); return; }
    attrs: [..] Attr; attrs.allocator = temp;
    atr_get_attrs(p, .[.NoFPClass], *attrs);
    for attrs bs_add_known(*aa(i).s, cast(u32) it.ival);
    ctx := irp_ctx_i(p);
    if aa(i).pk != .RETURNED {
        q: Simplify_Query;
        q.have_tli = atr_have_tli();
        q.no_tli_libcalls = !atr_have_tli();
        q.cxt = ctx;
        f := irp_anchor_scope(p);
        if f != NONE && !is_declaration(f) { q.dt = atr_dt(f); q.ac = atr_ac(f); }
        kfc := compute_known_fp_class(v, FC_ALL_FLAGS, q);
        bs_add_known(*aa(i).s, (~cast(u32) kfc.known_fp_classes) & FC_ALL_FLAGS);   // FPClassTest operator~ masks to fcAllFlags
    }
    if ctx != NONE aa_follow_uses_in_mbec(i, ctx, *aa(i).s);
}

// mayContainUnboundedCycle
wr_may_contain_unbounded_cycle :: (f: Value_Id) -> bool {
    se := atr_se(f);
    li := atr_li(f);
    if !se || !li {
        sccs: [..] [..] Value_Id; sccs.allocator = temp;
        cfg_sccs(fn_entry(f), *sccs);
        succs: [..] Value_Id; succs.allocator = temp;
        for scc: sccs {
            if scc.count > 1 return true;
            succs.count = 0;
            block_successors(scc[0], *succs);
            for succs if it == scc[0] return true;
        }
        return false;
    }
    if mbe_may_contain_irreducible_control(f, li) return true;
    loops: [..] Loop_Id; loops.allocator = temp;
    li_loops_in_preorder(li, *loops);
    old_se := se_current_swap(se);
    defer se_current_swap(old_se);
    for l: loops if sc_get_small_constant_max_trip_count(l) == 0 return true;
    return false;
}
se_current_swap :: (s: *Scev_State) -> *Scev_State { old := se; se = s; return old; }

// ---------------------------------------------------------------- updateImpl

aa_update_impl :: (i: u32) -> bool {
    a := aa(i);
    pk := a.pk;
    if a.kind == {
        case .NO_UNWIND;
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NoUnwind);
            return nu_update(i);
        case .NO_SYNC;
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NoSync);
            return ns_update(i);
        case .NO_FREE;
            if pk == .FUNCTION return nf_function_update(i);
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NoFree);
            if pk == .CALL_SITE_ARGUMENT {
                arg := irp_assoc_arg(a.pos);
                if arg == NONE return aa_pessimistic(i);
                has, _ := atr_has_assumed_ir_attr(.NoFree, i, irp_argument(arg), DEP_REQUIRED);
                if has return ATR_UNCHANGED;
                return aa_pessimistic(i);
            }
            return nf_floating_update(i);
        case .NON_NULL;
            if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NonNull);
            if pk == .RETURNED return aa_returned_from_returned_values(i);
            if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NonNull);
            return nn_floating_update(i);
        case .MUST_PROGRESS;
            if pk == .FUNCTION return mp_function_update(i);
            has, _ := atr_has_assumed_ir_attr(.MustProgress, i, irp_function(irp_anchor_scope(a.pos)), DEP_REQUIRED);
            if !has return aa_pessimistic(i);
            return ATR_UNCHANGED;
        case .NO_RECURSE;
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NoRecurse);
            return nr_function_update(i);
        case .WILL_RETURN;
            if pk == .CALL_SITE {
                if wr_implied_by_mustprogress_and_readonly(i, false) return ATR_UNCHANGED;
                return aa_callee_to_call_site(i, .WillReturn);
            }
            return wr_update(i);
        case .NO_RETURN;
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NoReturn);
            ok, rets := atr_aa_insts(i, .[.RET]);
            if !ok || rets.count > 0 return aa_pessimistic(i);
            return ATR_UNCHANGED;
        case .NO_CAPTURE;
            if pk == .CALL_SITE_ARGUMENT {
                arg := irp_assoc_arg(a.pos);
                if arg == NONE return aa_pessimistic(i);
                has, _, arg_aa := atr_has_assumed_ir_attr(.Captures, i, irp_argument(arg), DEP_REQUIRED);
                if has return ATR_UNCHANGED;
                if arg_aa == NONE || !nc_maybe_returned(arg_aa) return aa_pessimistic(i);
                return bs_clamp_and_indicate(*aa(i).s, aa(arg_aa).s);
            }
            return nc_update(i);
        case .MEM_BEHAVIOR;
            if pk == .FUNCTION return mb_function_update(i);
            if pk == .CALL_SITE return aa_callee_to_call_site(i, .NONE_ATTR);
            if pk == .CALL_SITE_ARGUMENT {
                arg := irp_assoc_arg(a.pos);
                o := atr_get_aa(.MEM_BEHAVIOR, irp_argument(arg), i, DEP_REQUIRED);
                if o == NONE return aa_pessimistic(i);
                return bs_clamp_and_indicate(*aa(i).s, aa(o).s);
            }
            return mb_floating_update(i);
        case .MEM_LOCATION;
            if pk == .FUNCTION return ml_function_update(i);
            return ml_call_site_update(i);
        case .NO_FPCLASS;
            if pk == .RETURNED return aa_returned_from_returned_values(i);
            if pk == .ARGUMENT return aa_argument_from_call_site_arguments(i, .NONE_ATTR);
            if pk == .CALL_SITE_RETURNED return aa_callee_to_call_site(i, .NONE_ATTR);
            return fpc_floating_update(i);
        case .DENORMAL_FP;
            return dn_update(i);
        case .CALL_EDGES;
            if pk == .CALL_SITE return ce_call_site_update(i);
            return ce_function_update(i);
        case .INTRA_REACH; #through;
        case .INTER_REACH;
            // CachedReachabilityAA::updateImpl (AAIsDead is not allowed, so the intra-procedural one has no dead
            // edges or blocks to check first)
            changed := ATR_UNCHANGED;
            e := aa(i).queries.count;
            for u: 0..e - 1 {
                r := aa(i).queries[u];
                if aa(i).rq[r].reachable continue;
                res: bool;
                if aa(i).kind == .INTRA_REACH res = intra_is_reachable_impl(i, r, false);
                else res = inter_is_reachable_impl(i, r, false);
                if res changed = ATR_CHANGED;
            }
            return changed;
        case .UNDERLYING_OBJECTS;
            return uo_update(i);
    }
    return ATR_UNCHANGED;
}

// AANoUnwindImpl::updateImpl
nu_update :: (i: u32) -> bool {
    ok, insts := atr_aa_insts(i, .[.INVOKE, .CALLBR, .CALL, .CLEANUPRET, .CATCHSWITCH, .RESUME]);
    if !ok return aa_pessimistic(i);
    for x: insts {
        if !may_throw(x, true) continue;
        if is_call_base(x) {
            has, _ := atr_has_assumed_ir_attr(.NoUnwind, i, irp_cs_function(x), DEP_REQUIRED);
            if has continue;
        }
        return aa_pessimistic(i);
    }
    return ATR_UNCHANGED;
}

// AANoSyncImpl::updateImpl
ns_update :: (i: u32) -> bool {
    ok, rw := atr_rw_insts(i);
    if !ok return aa_pessimistic(i);
    for x: rw if !atr_is_no_sync_inst(x, i) return aa_pessimistic(i);
    ok2, calls := atr_call_like_insts(i);
    if !ok2 return aa_pessimistic(i);
    for cb: calls {
        if may_read_or_write_memory(cb) continue;
        has, _ := atr_has_assumed_ir_attr(.NoSync, i, irp_cs_function(cb), DEP_OPTIONAL);
        if has continue;
        if call_has_fn_attr(cb, .Convergent) return aa_pessimistic(i);
    }
    return ATR_UNCHANGED;
}

// AANoFreeImpl::updateImpl
nf_function_update :: (i: u32) -> bool {
    check :: (i: u32, x: Value_Id) -> bool {
        if is_call_base(x) {
            has, _ := atr_has_assumed_ir_attr(.NoFree, i, irp_cs_function(x), DEP_REQUIRED);
            return has;
        }
        return atr_is_no_sync_inst(x, i);
    }
    ok, rw := atr_rw_insts(i);
    if !ok return aa_pessimistic(i);
    for x: rw if !check(i, x) return aa_pessimistic(i);
    ok2, calls := atr_call_like_insts(i);
    if !ok2 return aa_pessimistic(i);
    for x: calls if !check(i, x) return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

// AANoFreeFloating::updateImpl
nf_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    has, _ := atr_has_assumed_ir_attr(.NoFree, i, irp_function_scope(p), DEP_OPTIONAL);
    if has return ATR_UNCHANGED;
    ok, w := atr_uses_begin(i, irp_assoc_value(p));
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        follow := false;
        user := ir.u_user[u];
        good := false;
        if is_call_base(user) {
            if call_is_bundle_operand(user, u) good = false;
            else if !call_is_arg_operand(user, u) good = true;
            else {
                cpos := irp_cs_argument(user, use_arg_no(u));
                h1, _ := atr_has_assumed_ir_attr(.NoFree, i, cpos, DEP_REQUIRED);
                if !h1 good = false;
                else {
                    h2, _, nc := atr_has_assumed_ir_attr(.Captures, i, cpos, DEP_REQUIRED);
                    if !h2 {
                        if nc != NONE && nc_maybe_returned(nc) { follow = true; good = true; }
                        else good = false;
                    } else good = true;
                }
            }
        } else {
            ucc, rcc := ct_use_capture_kind(u, NONE);
            if ((ucc | rcc) & CC_PROVENANCE) == 0 good = true;
            else if (rcc & CC_PROVENANCE) != 0 { follow = true; good = true; }
            else if is_inst(user) && inst_op(user) == .RET && irp_is_argument_position(p) good = true;
        }
        if !good return aa_pessimistic(i);
        if follow atr_uses_follow(*w, u);
    }
    return ATR_UNCHANGED;
}

// AANonNullFloating::updateImpl (getAssumedSimplifiedValues yields the value itself: nothing is stripped)
nn_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    v := irp_assoc_value(p);
    if is_phi(v) {
        all := true;
        for k: 0..cast(s64) nops(v) - 1 {
            has, _ := atr_has_assumed_ir_attr(.NonNull, i, irp_value(op(v, cast(u32) k)), DEP_OPTIONAL);
            if !has { all = false; break; }
        }
        if all return ATR_UNCHANGED;
    }
    if is_inst(v) && inst_op(v) == .SELECT {
        h1, _ := atr_has_assumed_ir_attr(.NonNull, i, irp_value(op(v, 2)), DEP_OPTIONAL);
        if h1 {
            h2, _ := atr_has_assumed_ir_attr(.NonNull, i, irp_value(op(v, 1)), DEP_OPTIONAL);
            if h2 return ATR_UNCHANGED;
        }
    }
    av := irp_value(v);
    if irp_eq(av, p) return aa_pessimistic(i);
    has, _ := atr_has_assumed_ir_attr(.NonNull, i, av, DEP_OPTIONAL);
    if !has return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

// AAMustProgressFunction::updateImpl
mp_function_update :: (i: u32) -> bool {
    p := aa(i).pos;
    has, known := atr_has_assumed_ir_attr(.WillReturn, i, p, DEP_OPTIONAL);
    if has {
        if known return aa_optimistic(i);
        return ATR_UNCHANGED;
    }
    sites, complete := atr_call_sites(irp_assoc_fn(p), true);
    for cb: sites {
        h, _ := atr_has_assumed_ir_attr(.MustProgress, i, irp_cs_function(cb), DEP_REQUIRED, true);
        if !h return aa_pessimistic(i);
    }
    if !complete return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

// AANoRecurseFunction::updateImpl
nr_function_update :: (i: u32) -> bool {
    p := aa(i).pos;
    sites, complete := atr_call_sites(irp_assoc_fn(p), true);
    all := complete;
    for cb: sites {
        has, known := atr_has_assumed_ir_attr(.NoRecurse, i, irp_function(inst_fn(cb)), DEP_NONE);
        if !has || !known { all = false; break; }
    }
    if all {
        aa_optimistic(i);   // liveness is off: no assumed information was used
        return ATR_UNCHANGED;
    }
    er := atr_get_aa(.INTER_REACH, p, i, DEP_REQUIRED);
    if er != NONE && inter_can_reach(er, irp_anchor_scope(p)) return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

// AAWillReturnImpl::isImpliedByMustprogressAndReadonly
wr_implied_by_mustprogress_and_readonly :: (i: u32, known_only: bool) -> bool {
    p := aa(i).pos;
    if !atr_has_attr(p, .[.MustProgress]) return false;
    ok, known := atr_is_assumed_read_only(p, i);
    if ok return known || !known_only;
    return false;
}
// AAWillReturnImpl::updateImpl
wr_update :: (i: u32) -> bool {
    if wr_implied_by_mustprogress_and_readonly(i, false) return ATR_UNCHANGED;
    ok, calls := atr_call_like_insts(i);
    if !ok return aa_pessimistic(i);
    for cb: calls {
        ipos := irp_cs_function(cb);
        has, known := atr_has_assumed_ir_attr(.WillReturn, i, ipos, DEP_REQUIRED);
        if !has return aa_pessimistic(i);
        if known continue;
        h2, _ := atr_has_assumed_ir_attr(.NoRecurse, i, ipos, DEP_REQUIRED);
        if !h2 return aa_pessimistic(i);
    }
    ok2, mem := atr_aa_insts(i, .[.LOAD, .STORE, .CMPXCHG, .ATOMICRMW]);
    if !ok2 return aa_pessimistic(i);
    for mem if is_volatile(it) return aa_pessimistic(i);
    return ATR_UNCHANGED;
}

// AANoCaptureImpl::updateImpl
nc_update :: (i: u32) -> bool {
    p := aa(i).pos;
    is_arg := irp_is_argument_position(p);
    v := ifx is_arg then irp_assoc_arg(p) else irp_assoc_value(p);
    if v == NONE return aa_pessimistic(i);
    f := ifx is_arg then irp_assoc_fn(p) else irp_anchor_scope(p);
    if f == NONE return aa_pessimistic(i);
    t := bs_new(NC_NO_CAPTURE);
    fpos := irp_function(f);
    ro, ro_known := atr_is_assumed_read_only(fpos, i);
    if ro {
        bs_add_known(*t, NC_NOT_CAPTURED_IN_MEM);
        if ro_known bs_add_known(*aa(i).s, NC_NOT_CAPTURED_IN_MEM);
    }
    nu, nu_known := atr_has_assumed_ir_attr(.NoUnwind, i, fpos, DEP_OPTIONAL);
    if nu {
        is_void := type_kind(fn_ret_type(f)) == .VOID;
        // CheckReturnedArgs: getAssumedSimplifiedValues of the returned position fails
        if is_void {
            bs_add_known(*t, NC_NOT_CAPTURED_IN_RET);
            if bs_is_known(t, NC_NOT_CAPTURED_IN_MEM) return ATR_UNCHANGED;
            if nu_known {
                bs_add_known(*aa(i).s, NC_NOT_CAPTURED_IN_RET);
                if bs_is_known(aa(i).s, NC_NOT_CAPTURED_IN_MEM) return aa_optimistic(i);
            }
        }
    }
    ok, w := atr_uses_begin(i, v);
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        follow := false;
        ucc, rcc := ct_use_capture_kind(u, NONE);
        good := true;
        if (ucc | rcc) == CC_NONE good = true;
        else if ucc == CC_NONE && rcc != CC_NONE follow = true;
        else good = nc_check_use(i, *t, u, *follow);
        if !good return aa_pessimistic(i);
        if follow atr_uses_follow(*w, u);
    }
    old := aa(i).s.assumed;
    bs_intersect_assumed(*aa(i).s, t.assumed);
    if !nc_maybe_returned(i) return aa_pessimistic(i);
    return old != aa(i).s.assumed;
}
// AANoCaptureImpl::checkUse
nc_check_use :: (i: u32, t: *Bstate, u: Use_Id, follow: *bool) -> bool {
    captured_in :: (t: *Bstate, mem: bool, in_int: bool, ret: bool) -> bool {
        if mem bs_remove_assumed(t, NC_NOT_CAPTURED_IN_MEM);
        if in_int bs_remove_assumed(t, NC_NOT_CAPTURED_IN_INT);
        if ret bs_remove_assumed(t, NC_NOT_CAPTURED_IN_RET);
        return bs_is_assumed(t.*, NC_NO_CAPTURE_MAYBE_RETURNED);
    }
    user := ir.u_user[u];
    o := inst_op(user);
    if o == .PTRTOINT return captured_in(t, true, true, true);
    if o == .STORE return captured_in(t, true, true, true);
    if o == .RET {
        if inst_fn(user) == irp_anchor_scope(aa(i).pos) return captured_in(t, false, false, true);
        return captured_in(t, true, true, true);
    }
    if !is_call_base(user) || !call_is_arg_operand(user, u) return captured_in(t, true, true, true);
    cpos := irp_cs_argument(user, use_arg_no(u));
    has, _, nc := atr_has_assumed_ir_attr(.Captures, i, cpos, DEP_REQUIRED);
    if has return captured_in(t, false, false, false);
    if nc != NONE && nc_maybe_returned(nc) {
        follow.* = true;
        return captured_in(t, false, false, false);
    }
    return captured_in(t, true, true, true);
}

// AAMemoryBehaviorFunction::updateImpl
mb_function_update :: (i: u32) -> bool {
    old := aa(i).s.assumed;
    ok, rw := atr_rw_insts(i);
    if !ok return aa_pessimistic(i);
    for x: rw {
        if is_call_base(x) {
            o := atr_get_aa(.MEM_BEHAVIOR, irp_cs_function(x), i, DEP_REQUIRED);
            if o != NONE {
                bs_intersect_assumed(*aa(i).s, aa(o).s.assumed);
                if bs_is_fix(aa(i).s) return aa_pessimistic(i);
                continue;
            }
        }
        if may_read_from_memory(x) bs_remove_assumed(*aa(i).s, MB_NO_READS);
        if may_write_to_memory(x) bs_remove_assumed(*aa(i).s, MB_NO_WRITES);
        if bs_is_fix(aa(i).s) return aa_pessimistic(i);
    }
    return old != aa(i).s.assumed;
}

// AAMemoryBehaviorFloating::updateImpl
mb_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    fpos := irp_function_scope(p);
    arg := irp_assoc_arg(p);
    fn_assumed: u32 = 0;
    if arg == NONE || !arg_has_attr(arg, .ByVal) {
        fm := atr_get_aa(.MEM_BEHAVIOR, fpos, i, DEP_OPTIONAL);
        if fm != NONE {
            fn_assumed = aa(fm).s.assumed;
            bs_add_known(*aa(i).s, aa(fm).s.known);
            if (aa(i).s.assumed & aa(fm).s.assumed) == aa(i).s.assumed return ATR_UNCHANGED;
        }
    }
    old := aa(i).s.assumed;
    has, _, nc := atr_has_assumed_ir_attr(.Captures, i, p, DEP_OPTIONAL);
    if !has && (nc == NONE || !nc_maybe_returned(nc)) {
        bs_intersect_assumed(*aa(i).s, fn_assumed);
        return old != aa(i).s.assumed;
    }
    ok, w := atr_uses_begin(i, irp_assoc_value(p));
    if !ok return aa_pessimistic(i);
    while true {
        u := atr_uses_next(*w);
        if u == NONE break;
        user := ir.u_user[u];
        if is_droppable_user(user) continue;
        follow := mb_follow_users_of_use_in(i, u, user);
        if may_read_or_write_memory(user) mb_analyze_use_in(i, u, user);
        if bs_is_fix(aa(i).s) return aa_pessimistic(i);
        if follow atr_uses_follow(*w, u);
    }
    return old != aa(i).s.assumed;
}
mb_follow_users_of_use_in :: (i: u32, u: Use_Id, user: Value_Id) -> bool {
    o := inst_op(user);
    if o == .LOAD || o == .RET return false;
    if !is_call_base(user) || !call_is_arg_operand(user, u) return true;
    if is_ptr_type(vtype(ir.u_val[u])) {
        has, _ := atr_has_assumed_ir_attr(.Captures, i, irp_cs_argument(user, use_arg_no(u)), DEP_OPTIONAL);
        return !has;
    }
    return true;
}
mb_analyze_use_in :: (i: u32, u: Use_Id, user: Value_Id) {
    o := inst_op(user);
    if o == .LOAD { bs_remove_assumed(*aa(i).s, MB_NO_READS); return; }
    if o == .STORE {
        if op(user, 1) == ir.u_val[u] bs_remove_assumed(*aa(i).s, MB_NO_WRITES);
        else aa_pessimistic(i);
        return;
    }
    if o == .CALL || o == .CALLBR || o == .INVOKE {
        generic := false;
        if call_is_bundle_operand(user, u) { aa_pessimistic(i); return; }
        if call_is_callee_use(user, u) {
            bs_remove_assumed(*aa(i).s, MB_NO_READS);
            generic = true;
        } else {
            pos: Irp;
            if is_ptr_type(vtype(ir.u_val[u])) pos = irp_cs_argument(user, use_arg_no(u));
            else pos = irp_cs_function(user);
            mb := atr_get_aa(.MEM_BEHAVIOR, pos, i, DEP_OPTIONAL);
            if mb == NONE generic = true;
            else { bs_intersect_assumed(*aa(i).s, aa(mb).s.assumed); return; }
        }
    }
    if may_read_from_memory(user) bs_remove_assumed(*aa(i).s, MB_NO_READS);
    if may_write_to_memory(user) bs_remove_assumed(*aa(i).s, MB_NO_WRITES);
}

// ---------------------------------------------------------------- AAMemoryLocation

ml_access_kind_from_inst :: (x: Value_Id) -> u8 {
    if x == NONE || !is_inst(x) return ML_READ_WRITE;
    k := ML_NONE;
    if may_read_from_memory(x) k |= ML_READ;
    if may_write_to_memory(x) k |= ML_WRITE;
    return k;
}
// updateStateAndAccessesMap (the accesses map is always i's; the state may be a local)
ml_update_state_and_accesses :: (i: u32, st: *Bstate, mlk_in: u32, x: Value_Id, ptr: Value_Id, changed: *bool, kind: u8) {
    mlk := mlk_in;
    list := *aa(i).accesses[log2_u32(mlk)];
    found := false;
    for list.* if it.i == x && it.ptr == ptr && it.kind == kind { found = true; break; }
    if !found { array_add(list, .{x, ptr, kind}); changed.* = true; }
    if mlk == ML_NO_UNKOWN_MEM mlk = ML_NO_LOCATIONS;
    bs_remove_assumed(st, mlk);
}
// AAMemoryLocationImpl::indicatePessimisticFixpoint (the access part)
ml_pessimistic_accesses :: (i: u32) {
    changed := false;
    known := aa(i).s.known;
    v := irp_assoc_value(aa(i).pos);
    x := ifx is_inst(v) then v else NONE;
    mlk: u32 = 1;
    while mlk < ML_NO_LOCATIONS {
        if !(mlk & known) ml_update_state_and_accesses(i, *aa(i).s, mlk, x, NONE, *changed, ml_access_kind_from_inst(x));
        mlk *= 2;
    }
}
// checkForAllAccessesToMemoryKind: the accesses (with their location kind) not in `requested`; false if invalid
Ml_Access_Loc :: struct { a: Ml_Access; mlk: u32; }
ml_accesses :: (i: u32, requested: u32, out: *[..] Ml_Access_Loc) -> bool {
    if !aa_is_valid(i) return false;
    if aa(i).s.assumed == ML_NO_LOCATIONS return true;
    idx := 0;
    mlk: u32 = 1;
    while mlk < ML_NO_LOCATIONS {
        if !(mlk & requested) for aa(i).accesses[idx] array_add(out, .{it, mlk});
        mlk *= 2;
        idx += 1;
    }
    return true;
}

// categorizePtrValue
ml_categorize_ptr_value :: (i: u32, x: Value_Id, ptr: Value_Id, st: *Bstate, changed: *bool, access_as: u32 = 0) {
    uo := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(ptr), i, DEP_OPTIONAL);
    if uo == NONE {
        ml_update_state_and_accesses(i, st, ML_NO_UNKOWN_MEM, x, NONE, changed, ml_access_kind_from_inst(x));
        return;
    }
    objs: [..] Value_Id; objs.allocator = temp;
    uo_objects(uo, true, *objs);
    afn := irp_assoc_fn(aa(i).pos);
    for obj: objs {
        obj_as := ptr_addrspace(vtype(obj));
        mlk := ML_NO_LOCATIONS;
        k := vkind(obj);
        if k == .C_UNDEF || k == .C_POISON continue;
        if k == .ARGUMENT mlk = ML_NO_ARGUMENT_MEM;
        else if is_global_value(k) {
            if k == .GLOBAL_VAR && glob(obj).is_const continue;
            mlk = ifx gv_has_local_linkage(obj) then ML_NO_GLOBAL_INTERNAL_MEM else ML_NO_GLOBAL_EXTERNAL_MEM;
        } else if k == .C_NULL && (!null_pointer_is_defined(afn, access_as) || !null_pointer_is_defined(afn, obj_as)) {
            continue;
        } else if is_inst(obj) && inst_op(obj) == .ALLOCA {
            mlk = ML_NO_LOCAL_MEM;
        } else if irp_is_call(obj) {
            has, _ := atr_has_assumed_ir_attr(.NoAlias, i, irp_cs_returned(obj), DEP_OPTIONAL);
            mlk = ifx has then ML_NO_MALLOCED_MEM else ML_NO_UNKOWN_MEM;
        } else {
            mlk = ML_NO_UNKOWN_MEM;
        }
        ml_update_state_and_accesses(i, st, mlk, x, obj, changed, ml_access_kind_from_inst(x));
    }
}
// categorizeArgumentPointerLocations
ml_categorize_argument_pointer_locations :: (i: u32, cb: Value_Id, st: *Bstate, changed: *bool) {
    for k: 0..cast(s64) call_num_args(cb) - 1 {
        arg := call_arg(cb, cast(u32) k);
        if !is_ptr_or_ptr_vector(vtype(arg)) continue;
        mb := atr_get_aa(.MEM_BEHAVIOR, irp_cs_argument(cb, cast(u32) k), i, DEP_OPTIONAL);
        if mb != NONE && bs_is_assumed(aa(mb).s, MB_NO_ACCESSES) continue;
        ml_categorize_ptr_value(i, cb, arg, st, changed);
    }
}
// categorizeAccessedLocations
ml_categorize_accessed_locations :: (i: u32, x: Value_Id, changed: *bool) -> u32 {
    accessed := bs_new(ML_BEST_STATE);
    bs_intersect_assumed(*accessed, ML_NO_LOCATIONS);
    if is_call_base(x) {
        cbml := atr_get_aa(.MEM_LOCATION, irp_cs_function(x), i, DEP_OPTIONAL);
        if cbml == NONE {
            ml_update_state_and_accesses(i, *accessed, ML_NO_UNKOWN_MEM, x, NONE, changed, ml_access_kind_from_inst(x));
            return ML_NO_UNKOWN_MEM;
        }
        cs := aa(cbml).s;
        if ml_is_assumed_read_none(cs) return ML_NO_LOCATIONS;
        if ml_is_assumed_inaccessible_only(cs) {
            ml_update_state_and_accesses(i, *accessed, ML_NO_INACCESSIBLE_MEM, x, NONE, changed, ml_access_kind_from_inst(x));
            return accessed.assumed;
        }
        cb_not := cs.assumed;
        cb_not_no_arg := cb_not | ML_NO_ARGUMENT_MEM | ML_NO_GLOBAL_MEM;
        mlk: u32 = 1;
        while mlk < ML_NO_LOCATIONS {
            if !(cb_not_no_arg & mlk) ml_update_state_and_accesses(i, *accessed, mlk, x, NONE, changed, ml_access_kind_from_inst(x));
            mlk *= 2;
        }
        if (~cb_not) & ML_NO_GLOBAL_MEM {
            accs: [..] Ml_Access_Loc; accs.allocator = temp;
            if !ml_accesses(cbml, ml_inverse_location(ML_NO_GLOBAL_MEM, false, false), *accs) return 0;
            for accs ml_update_state_and_accesses(i, *accessed, it.mlk, x, it.a.ptr, changed, ml_access_kind_from_inst(x));
        }
        if (~cb_not) & ML_NO_ARGUMENT_MEM ml_categorize_argument_pointer_locations(i, x, *accessed, changed);
        return accessed.assumed;
    }
    o := inst_op(x);
    if o == .LOAD || o == .CMPXCHG || o == .ATOMICRMW || o == .STORE {
        ptr := ifx o == .STORE then op(x, 1) else op(x, 0);
        ml_categorize_ptr_value(i, x, ptr, *accessed, changed, ptr_addrspace(vtype(ptr)));
        return accessed.assumed;
    }
    ml_update_state_and_accesses(i, *accessed, ML_NO_UNKOWN_MEM, x, NONE, changed, ml_access_kind_from_inst(x));
    return accessed.assumed;
}
// AAMemoryLocationFunction::updateImpl
ml_function_update :: (i: u32) -> bool {
    p := aa(i).pos;
    mb := atr_get_aa(.MEM_BEHAVIOR, p, i, DEP_NONE);
    if mb != NONE && bs_is_assumed(aa(mb).s, MB_NO_ACCESSES) {
        if bs_is_known(aa(mb).s, MB_NO_ACCESSES) return aa_optimistic(i);
        atr_record_dependence(mb, i, DEP_OPTIONAL);
        return ATR_UNCHANGED;
    }
    old := aa(i).s.assumed;
    changed := false;
    ok, rw := atr_rw_insts(i);
    if !ok return aa_pessimistic(i);
    for x: rw {
        mlk := ml_categorize_accessed_locations(i, x, *changed);
        bs_remove_assumed(*aa(i).s, ml_inverse_location(mlk, false, false));
        if aa(i).s.assumed == ML_VALID_STATE return aa_pessimistic(i);
    }
    changed |= old != aa(i).s.assumed;
    return changed;
}
// AAMemoryLocationCallSite::updateImpl
ml_call_site_update :: (i: u32) -> bool {
    f := irp_assoc_fn(aa(i).pos);
    fa := atr_get_aa(.MEM_LOCATION, irp_function(f), i, DEP_REQUIRED);
    if fa == NONE return aa_pessimistic(i);
    changed := false;
    accs: [..] Ml_Access_Loc; accs.allocator = temp;
    if !ml_accesses(fa, 0, *accs) return aa_pessimistic(i);
    for accs ml_update_state_and_accesses(i, *aa(i).s, it.mlk, it.a.i, it.a.ptr, *changed, ml_access_kind_from_inst(it.a.i));
    return changed;
}

// ---------------------------------------------------------------- AANoFPClass, AADenormalFPMath

// AANoFPClassFloating::updateImpl
fpc_floating_update :: (i: u32) -> bool {
    p := aa(i).pos;
    v := irp_assoc_value(p);
    t := bs_new(FC_ALL_FLAGS);
    o := atr_get_aa(.NO_FPCLASS, irp_value(v), i, DEP_REQUIRED);
    if o == NONE || o == i bs_pessimistic(*t);
    else bs_clamp(*t, aa(o).s);
    if !bs_is_valid(t) return aa_pessimistic(i);
    return bs_clamp_and_indicate(*aa(i).s, t);
}

DN_INVALID :: cast(u32) 0xF;
dn_nibble :: inline (m: u32, k: u32) -> u32 { return (m >> (4 * k)) & 0xF; }
dn_state_is_valid :: (m: u32) -> bool { for k: 0..3 if dn_nibble(m, cast(u32) k) == DN_INVALID return false; return true; }
dn_is_mode_fixed :: (m: u32) -> bool { for k: 0..3 if dn_nibble(m, cast(u32) k) == DENORMAL_DYNAMIC return false; return true; }
// F.getDenormalMode(IEEEsingle()) has a dynamic input or output
dn_f32_mode_is_dynamic :: (f: Value_Id) -> bool {
    at := fn_get_fn_attr(f, .DenormalFPEnv);
    if !at return false;
    m := cast(u32) at.ival;
    return dn_nibble(m, 2) == DENORMAL_DYNAMIC || dn_nibble(m, 3) == DENORMAL_DYNAMIC;
}
// DenormalState::unionWith (per nibble unionDenormalKind)
dn_union :: (callee: u32, caller: u32) -> u32 {
    r: u32 = 0;
    for k: 0..3 {
        a := dn_nibble(callee, cast(u32) k);
        b := dn_nibble(caller, cast(u32) k);
        x: u32;
        if b == a x = b;
        else if a == DENORMAL_DYNAMIC x = b;
        else if b == DENORMAL_DYNAMIC x = a;
        else x = DN_INVALID;
        r |= x << (4 * cast(u32) k);
    }
    return r;
}
// AADenormalFPMathFunction::updateImpl
dn_update :: (i: u32) -> bool {
    change := ATR_UNCHANGED;
    sites, complete := atr_call_sites(irp_assoc_fn(aa(i).pos), true);
    for cb: sites {
        ci := atr_get_aa(.DENORMAL_FP, irp_function(inst_fn(cb)), i, DEP_REQUIRED);
        if ci == NONE return aa_pessimistic(i);
        old := aa(i).dn_mode;
        aa(i).dn_mode = dn_union(aa(i).dn_mode, aa(ci).dn_mode);
        if old != aa(i).dn_mode change = ATR_CHANGED;
    }
    if !complete return aa_pessimistic(i);
    if change && dn_is_mode_fixed(aa(i).dn_mode) aa(i).dn_fix = true;
    return change;
}

// ---------------------------------------------------------------- AACallEdges

ce_add_called_function :: (i: u32, f: Value_Id, change: *bool) {
    for aa(i).callees if it == f return;
    array_add(*aa(i).callees, f);
    change.* = true;
}
ce_set_has_unknown_callee :: (i: u32, non_asm: bool, change: *bool) {
    a := aa(i);
    if !a.unknown_callee change.* = true;
    if non_asm && !a.unknown_callee_non_asm change.* = true;
    a.unknown_callee_non_asm |= non_asm;
    a.unknown_callee = true;
}
// hasAssumption(F or CB, Name): the "llvm.assume" string attribute lists it
atr_has_assumption :: (s: u32, name: string) -> bool {
    for attr_set_items(s) if it.kind == .STRING_ATTR && it.key == "llvm.assume" {
        parts := split(it.val, ",");
        for parts if it == name return true;
    }
    return false;
}
// AACallEdgesCallSite::updateImpl
ce_call_site_update :: (i: u32) -> bool {
    change := false;
    cb := irp_ctx_i(aa(i).pos);
    callee := call_callee(cb);
    if vkind(callee) == .INLINE_ASM {
        side_effects := (inline_asms[ir.v_aux[callee]].flags & 1) != 0;
        has_no_call_asm := atr_has_assumption(attr_list_fn(glob(inst_fn(cb)).attrs), "ompx_no_call_asm") ||
                           atr_has_assumption(call_fn_attrs(cb), "ompx_no_call_asm");
        if !has_no_call_asm {
            f := call_called_operand_fn(cb);
            if f != NONE && atr_has_assumption(attr_list_fn(glob(f).attrs), "ompx_no_call_asm") has_no_call_asm = true;
        }
        if side_effects && !has_no_call_asm ce_set_has_unknown_callee(i, false, *change);
        return change;
    }
    // AAIndirectCallInfo is not allowed; getAssumedSimplifiedValues yields the called operand itself
    if vkind(callee) == .FUNCTION ce_add_called_function(i, callee, *change);
    else ce_set_has_unknown_callee(i, true, *change);
    return change;
}
// AACallEdgesFunction::updateImpl
ce_function_update :: (i: u32) -> bool {
    change := false;
    ok, calls := atr_call_like_insts(i);
    if !ok { ce_set_has_unknown_callee(i, true, *change); return change; }
    for cb: calls {
        e := atr_get_aa(.CALL_EDGES, irp_cs_function(cb), i, DEP_REQUIRED);
        if e == NONE { ce_set_has_unknown_callee(i, true, *change); return change; }
        if aa(e).unknown_callee_non_asm ce_set_has_unknown_callee(i, true, *change);
        if aa(e).unknown_callee ce_set_has_unknown_callee(i, false, *change);
        for f: aa(e).callees ce_add_called_function(i, f, *change);
    }
    return change;
}

// ---------------------------------------------------------------- reachability (CachedReachabilityAA)

rq_key :: inline (from: Value_Id, to: Value_Id) -> u64 { return ((cast(u64) from) << 32) | cast(u64) to; }
rq_new :: (i: u32, from: Value_Id, to: Value_Id, reachable: bool) -> s32 {
    r := cast(s32) aa(i).rq.count;
    array_add(*aa(i).rq, .{from, to, reachable});
    return r;
}
// checkQueryCache: (answered, reachable, stack RQI index if not answered)
rq_check_query_cache :: (i: u32, from: Value_Id, to: Value_Id) -> (bool, bool, s32) {
    if !aa_is_valid(i) return true, true, -1;
    found, r := table_find(*aa(i).rq_cache, rq_key(from, to));
    if found return true, aa(i).rq[r].reachable, -1;
    s := rq_new(i, from, to, false);   // the temporary (stack) RQI
    table_set(*aa(i).rq_cache, rq_key(from, to), s);
    return false, false, s;
}
// rememberResult
rq_remember_result :: (i: u32, r: s32, reachable: bool, used_exclusion_set: bool, temporary: bool) -> bool {
    aa(i).rq[r].reachable = reachable;
    from := aa(i).rq[r].from;
    to := aa(i).rq[r].to;
    key := rq_key(from, to);
    if temporary table_remove(*aa(i).rq_cache, key);
    if reachable || !used_exclusion_set {
        if !table_contains(*aa(i).rq_cache, key) {
            n := rq_new(i, from, to, reachable);
            array_add(*aa(i).queries, n);
            table_set(*aa(i).rq_cache, key, n);
        }
    }
    if temporary && !reachable && used_exclusion_set {
        n := rq_new(i, from, to, reachable);
        array_add(*aa(i).queries, n);
        table_set(*aa(i).rq_cache, key, n);
    }
    if !reachable && temporary atr_register_for_update(i);
    return reachable;
}
// AAIntraFnReachabilityFunction::isAssumedReachable
intra_is_assumed_reachable :: (i: u32, from: Value_Id, to: Value_Id) -> bool {
    if from == to return true;
    answered, res, s := rq_check_query_cache(i, from, to);
    if answered return res;
    return intra_is_reachable_impl(i, s, true);
}
intra_will_reach_in_block :: (from: Value_Id, to: Value_Id) -> bool {
    ip := from;
    while ip != NONE && ip != to ip = inst_next(ip);
    return ip == to;
}
// AAIntraFnReachabilityFunction::isReachableImpl (no exclusion sets, no liveness)
intra_is_reachable_impl :: (i: u32, r: s32, temporary: bool) -> bool {
    from := aa(i).rq[r].from;
    to := aa(i).rq[r].to;
    from_bb := inst_block(from);
    to_bb := inst_block(to);
    if from_bb == to_bb && intra_will_reach_in_block(from, to) return rq_remember_result(i, r, true, false, temporary);
    if !intra_will_reach_in_block(block_first(to_bb), to) return rq_remember_result(i, r, false, false, temporary);
    dt := atr_dt(irp_assoc_fn(aa(i).pos));
    visited: Table(Value_Id, bool); visited.allocator = temp;
    work: [..] Value_Id; work.allocator = temp;
    succs: [..] Value_Id; succs.allocator = temp;
    array_add(*work, from_bb);
    while work.count {
        bb := pop(*work);
        if table_contains(*visited, bb) continue;
        table_set(*visited, bb, true);
        succs.count = 0;
        block_successors(bb, *succs);
        for s: succs {
            if s == to_bb return rq_remember_result(i, r, true, false, temporary);
            if dt && dt_dominates(dt, bb, to_bb) return rq_remember_result(i, r, true, false, temporary);
            array_add(*work, s);
        }
    }
    return rq_remember_result(i, r, false, false, temporary);
}

// AAInterFnReachability::canReach
inter_can_reach :: (i: u32, f: Value_Id) -> bool {
    scope := irp_anchor_scope(aa(i).pos);
    if scope == NONE || is_declaration(scope) return true;
    return inter_instruction_can_reach(i, block_first(fn_entry(scope)), f);
}
// AAInterFnReachabilityFunction::instructionCanReach
inter_instruction_can_reach :: (i: u32, from: Value_Id, to: Value_Id) -> bool {
    answered, res, s := rq_check_query_cache(i, from, to);
    if answered return res;
    return inter_is_reachable_impl(i, s, true);
}
// AAInterFnReachabilityFunction::isReachableImpl
inter_is_reachable_impl :: (i: u32, r: s32, temporary: bool) -> bool {
    from := aa(i).rq[r].from;
    to := aa(i).rq[r].to;
    entry := block_first(fn_entry(inst_fn(from)));
    if entry != from && !inter_instruction_can_reach(i, entry, to) return rq_remember_result(i, r, false, false, temporary);
    intra := atr_get_aa(.INTRA_REACH, irp_function(inst_fn(from)), i, DEP_OPTIONAL);
    ok, calls := atr_call_like_insts(i);
    if !ok return rq_remember_result(i, r, true, true, temporary);
    for cb: calls {
        if inter_check_reachable_call_base(i, cb, from, to, entry) continue;
        if intra != NONE && !intra_is_assumed_reachable(intra, from, cb) continue;
        return rq_remember_result(i, r, true, true, temporary);
    }
    return rq_remember_result(i, r, false, true, temporary);
}
// CheckReachableCallBase: true if the call cannot reach `to`
inter_check_reachable_call_base :: (i: u32, cb: Value_Id, from: Value_Id, to: Value_Id, entry: Value_Id) -> bool {
    e := atr_get_aa(.CALL_EDGES, irp_cs_function(cb), i, DEP_OPTIONAL);
    if e == NONE || !aa_is_valid(e) return false;
    if aa(e).unknown_callee return false;
    callees: [..] Value_Id; callees.allocator = temp;
    for aa(e).callees array_add(*callees, it);
    for fnv: callees {
        if fnv == to return false;
        if is_declaration(fnv) {
            if fn_has_fn_attr(fnv, .NoCallback) continue;
            return false;
        }
        if fnv == irp_anchor_scope(aa(i).pos) {
            if entry == from continue;
            return false;
        }
        ir2 := atr_get_aa(.INTER_REACH, irp_function(fnv), i, DEP_OPTIONAL);
        first := block_first(fn_entry(fnv));
        if ir2 == NONE || inter_instruction_can_reach(ir2, first, to) return false;
    }
    return true;
}

// ---------------------------------------------------------------- AAUnderlyingObjects

// forallUnderlyingObjects: the objects of the given scope (the associated value if the state is invalid)
uo_objects :: (i: u32, intra: bool, out: *[..] Value_Id) {
    if !aa_is_valid(i) { array_add(out, irp_assoc_value(aa(i).pos)); return; }
    l := ifx intra then aa(i).intra_objs else aa(i).inter_objs;
    for l array_add(out, it);
}
uo_insert :: (i: u32, intra: bool, v: Value_Id) -> bool {
    l := ifx intra then *aa(i).intra_objs else *aa(i).inter_objs;
    for l.* if it == v return false;
    array_add(l, v);
    return true;
}
// AAUnderlyingObjectsImpl::updateImpl
uo_update :: (i: u32) -> bool {
    used_assumed := false;
    changed := uo_do_update(i, true, *used_assumed);
    changed |= uo_do_update(i, false, *used_assumed);
    if !used_assumed aa_optimistic(i);
    return changed;
}
uo_do_update :: (i: u32, intra: bool, used_assumed: *bool) -> bool {
    ptr := irp_assoc_value(aa(i).pos);
    seen: Table(Value_Id, bool); seen.allocator = temp;
    values: [..] Value_Id; values.allocator = temp;
    array_add(*values, ptr);
    changed := false;
    k := 0;
    while k < values.count {
        obj := values[k];
        k += 1;
        uo := get_underlying_object(obj);
        key := ifx uo != NONE then uo else obj;
        if table_contains(*seen, key) continue;
        table_set(*seen, key, true);
        if uo != NONE && uo != obj {
            if (is_inst(uo) && inst_op(uo) == .ALLOCA) || is_global_value(vkind(uo)) {
                changed |= uo_insert(i, intra, uo);
                continue;
            }
            other := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(uo), i, DEP_OPTIONAL);
            if other == NONE fatal("internal: attributor: no AAUnderlyingObjects for an underlying object");
            objs: [..] Value_Id; objs.allocator = temp;
            uo_objects(other, intra, *objs);
            for v: objs {
                if v == uo changed |= uo_insert(i, intra, uo);
                else array_add(*values, v);
            }
            used_assumed.* |= !aa_is_fix(other);
            continue;
        }
        if is_inst(obj) && inst_op(obj) == .SELECT {
            changed |= uo_handle_indirect(i, obj, intra, used_assumed);
            continue;
        }
        if is_phi(obj) {
            for x: 0..cast(s64) nops(obj) - 1 changed |= uo_handle_indirect(i, op(obj, cast(u32) x), intra, used_assumed);
            continue;
        }
        changed |= uo_insert(i, intra, obj);
    }
    return changed;
}
uo_handle_indirect :: (i: u32, v: Value_Id, intra: bool, used_assumed: *bool) -> bool {
    changed := false;
    o := atr_get_aa(.UNDERLYING_OBJECTS, irp_value(v), i, DEP_OPTIONAL);
    if o == NONE fatal("internal: attributor: no AAUnderlyingObjects for an indirect value");
    objs: [..] Value_Id; objs.allocator = temp;
    uo_objects(o, intra, *objs);
    for objs changed |= uo_insert(i, intra, it);
    used_assumed.* |= !aa_is_fix(o);
    return changed;
}

// ---------------------------------------------------------------- manifest

aa_manifest :: (i: u32) -> bool {
    a := aa(i);
    p := a.pos;
    pk := a.pk;
    if a.kind == {
        case .CALL_EDGES; #through;
        case .INTRA_REACH; #through;
        case .INTER_REACH; #through;
        case .UNDERLYING_OBJECTS;
            return ATR_UNCHANGED;
        case .NO_FREE;
            if pk == .CALL_SITE_RETURNED return ATR_UNCHANGED;
        case .MEM_BEHAVIOR;
            return mb_manifest(i);
        case .MEM_LOCATION;
            return ml_manifest(i);
        case .DENORMAL_FP;
            return dn_manifest(i);
    }
    return aa_ir_attribute_manifest(i);
}

// IRAttribute::manifest with getDeducedAttributes
aa_ir_attribute_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    v := irp_assoc_value(p);
    if vkind(v) == .C_UNDEF || vkind(v) == .C_POISON return ATR_UNCHANGED;
    attrs: [..] Attr; attrs.allocator = temp;
    aa_deduced_attributes(i, *attrs);
    if attrs.count == 0 return ATR_UNCHANGED;
    return atr_manifest_attrs(p, attrs);
}
aa_deduced_attributes :: (i: u32, out: *[..] Attr) {
    a := aa(i);
    if a.kind == {
        case .NO_UNWIND; array_add(out, attr_enum(.NoUnwind));
        case .NO_SYNC; array_add(out, attr_enum(.NoSync));
        case .NO_FREE; array_add(out, attr_enum(.NoFree));
        case .NON_NULL; array_add(out, attr_enum(.NonNull));
        case .MUST_PROGRESS; array_add(out, attr_enum(.MustProgress));
        case .NO_RECURSE; array_add(out, attr_enum(.NoRecurse));
        case .WILL_RETURN; array_add(out, attr_enum(.WillReturn));
        case .NO_RETURN; array_add(out, attr_enum(.NoReturn));
        case .NO_CAPTURE;
            if !nc_maybe_returned(i) return;
            if irp_is_argument_position(a.pos) && bs_is_assumed(a.s, NC_NO_CAPTURE) array_add(out, attr_enum(.Captures, 0));
            // -attributor-manifest-internal is off: no "no-capture-maybe-returned"
        case .NO_FPCLASS; array_add(out, attr_enum(.NoFPClass, a.s.assumed));
        case .MEM_BEHAVIOR;
            if bs_is_assumed(a.s, MB_NO_ACCESSES) array_add(out, attr_enum(.ReadNone));
            else if bs_is_assumed(a.s, MB_NO_WRITES) array_add(out, attr_enum(.ReadOnly));
            else if bs_is_assumed(a.s, MB_NO_READS) array_add(out, attr_enum(.WriteOnly));
        case .MEM_LOCATION;
            if a.pk == .FUNCTION {
                if ml_is_assumed_read_none(a.s) array_add(out, attr_enum(.Memory, 0));
                else if ml_is_assumed_inaccessible_only(a.s) array_add(out, attr_enum(.Memory, me_loc(LOC_INACCESSIBLE, MR_MODREF)));
                else if ml_is_assumed_arg_only(a.s) array_add(out, attr_enum(.Memory, me_loc(LOC_ARG, MR_MODREF)));
                else if ml_is_assumed_inaccessible_or_arg_only(a.s) array_add(out, attr_enum(.Memory, me_loc(LOC_ARG, MR_MODREF) | me_loc(LOC_INACCESSIBLE, MR_MODREF)));
            }
    }
}

MB_ATTR_KINDS :: Attr_Kind.[.ReadNone, .ReadOnly, .WriteOnly];
// the MemoryEffects of the assumed memory behavior (unknown / none / readOnly / writeOnly)
mb_memory_effects :: (s: Bstate) -> u64 {
    if bs_is_assumed(s, MB_NO_ACCESSES) return 0;
    if bs_is_assumed(s, MB_NO_WRITES) return mem_all(MR_REF);
    if bs_is_assumed(s, MB_NO_READS) return mem_all(MR_MOD);
    return MEM_UNKNOWN;
}
mb_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    pk := aa(i).pk;
    if pk == .CALL_SITE_RETURNED return ATR_UNCHANGED;
    if pk == .FUNCTION || pk == .CALL_SITE {
        me := mb_memory_effects(aa(i).s);
        atr_remove_attrs(p, MB_ATTR_KINDS);
        if mem_only_reads(me) {
            if pk == .FUNCTION {
                f := irp_anchor(p);
                for k: 0..cast(s64) fn_nargs(f) - 1 atr_remove_attrs(irp_argument(fn_arg(f, cast(u32) k)), .[.Writable]);
            } else {
                cb := irp_anchor(p);
                for k: 0..cast(s64) call_num_args(cb) - 1 atr_remove_attrs(irp_cs_argument(cb, cast(u32) k), .[.Writable]);
            }
        }
        return atr_manifest_attrs(p, .[attr_enum(.Memory, me)]);
    }
    if pk == .ARGUMENT || pk == .CALL_SITE_ARGUMENT {
        // AAMemoryBehaviorArgument::manifest
        if !is_ptr_type(vtype(irp_assoc_value(p))) return ATR_UNCHANGED;
        if atr_has_attr(p, .[.InAlloca, .Preallocated]) {
            bs_remove_known(*aa(i).s, MB_NO_WRITES);
            bs_remove_assumed(*aa(i).s, MB_NO_WRITES);
        }
        atr_remove_attrs(p, MB_ATTR_KINDS);
    }
    // AAMemoryBehaviorImpl::manifest
    if atr_has_attr(p, .[.ReadNone], true) return ATR_UNCHANGED;
    attrs: [..] Attr; attrs.allocator = temp;
    aa_deduced_attributes(i, *attrs);
    all := true;
    for attrs if !atr_has_attr(p, .[it.kind], true) { all = false; break; }
    if all return ATR_UNCHANGED;
    atr_remove_attrs(p, MB_ATTR_KINDS);
    if bs_is_assumed(aa(i).s, MB_NO_WRITES) atr_remove_attrs(p, .[.Writable]);
    return aa_ir_attribute_manifest(i);
}
// AAMemoryLocationImpl::manifest
ml_manifest :: (i: u32) -> bool {
    attrs: [..] Attr; attrs.allocator = temp;
    aa_deduced_attributes(i, *attrs);
    if attrs.count != 1 return ATR_UNCHANGED;
    return atr_manifest_attrs(aa(i).pos, attrs);
}
// AADenormalFPMathFunction::manifest
dn_manifest :: (i: u32) -> bool {
    p := aa(i).pos;
    m := aa(i).dn_mode;
    if m == 0 return atr_remove_attrs(p, .[.DenormalFPEnv]);
    return atr_manifest_attrs(p, .[attr_enum(.DenormalFPEnv, m)], true);
}
