// InstCombine: pointer authentication. Ported from llvm/lib/Transforms/InstCombine/InstCombineCalls.cpp
// (visitCallInst's ptrauth_auth / ptrauth_resign case, foldPtrAuthIntrinsicCallee, foldPtrAuthConstantCallee) and
// ConstantPtrAuth::isKnownCompatibleWith (llvm/lib/IR/Constants.cpp).
// ConstantPtrAuth operands: (ptr, i32 key, i64 disc, ptr addrdisc, ptr deactivation symbol).

IID_PTRAUTH_BLEND :: #run iid_by_name("llvm.ptrauth.blend");

cpa_pointer :: inline (c: Value_Id) -> Value_Id { return op(c, 0); }
cpa_key :: inline (c: Value_Id) -> Value_Id { return op(c, 1); }
cpa_disc :: inline (c: Value_Id) -> Value_Id { return op(c, 2); }
cpa_addr_disc :: inline (c: Value_Id) -> Value_Id { return op(c, 3); }
cpa_deactivation_symbol :: inline (c: Value_Id) -> Value_Id { return op(c, 4); }

// ConstantPtrAuth::get(Ptr, Key, Disc, AddrDisc, DeactivationSymbol)
const_ptrauth :: (p: Value_Id, key: Value_Id, disc: Value_Id, addr: Value_Id, ds: Value_Id) -> Value_Id {
    ops := Value_Id.[p, key, disc, addr, ds];
    k := const_key_begin(.C_PTRAUTH, vtype(p));
    for ops key_u32(k, it);
    c := const_lookup_or_create(k, .C_PTRAUTH, vtype(p), ops, 0);
    return c;
}

// ConstantPtrAuth::isKnownCompatibleWith(Key, Discriminator, DL)
cpa_is_known_compatible_with :: (c: Value_Id, key: Value_Id, disc: Value_Id) -> bool {
    if vkind(cpa_deactivation_symbol(c)) != .C_NULL return false;
    if cpa_key(c) != key return false;
    if vkind(cpa_addr_disc(c)) == .C_NULL return cpa_disc(c) == disc;   // !hasAddressDiscriminator()
    addr: Value_Id = NONE;
    if !is_null_value(cpa_disc(c)) {
        // an implicit blend: the provided discriminator must be a matching llvm.ptrauth.blend
        if !is_inst(disc) || call_iid(disc) != IID_PTRAUTH_BLEND || call_arg(disc, 1) != cpa_disc(c) return false;
        addr = call_arg(disc, 0);
    } else addr = disc;
    if opr_code(addr) == .PTRTOINT addr = op(addr, 0);   // PtrToIntOperator
    ca := cpa_addr_disc(c);
    if vtype(ca) != vtype(addr) return false;
    if ca == addr return true;
    bits := dl_index_bits(vtype(ca));
    b1, o1 := strip_and_accumulate_constant_offsets(ca, ap_zero(bits), true);
    b2, o2 := strip_and_accumulate_constant_offsets(addr, ap_zero(dl_index_bits(vtype(addr))), true);
    return b1 == b2 && ap_eq(o1, o2);
}

// the inputs of the deactivation-symbol bundle of `c` (NONE if absent)
ptrauth_ds_input :: (c: Value_Id) -> Value_Id {
    ds := ic_deactivation_symbol_bundle(c);
    if ds.count return ds[0];
    return NONE;
}

// CallInst::Create(F, Args, {OperandBundleDef(Tag, Inputs)}) (unlinked; no bundle when Inputs is empty)
create_call_fn_bundle :: (f: Value_Id, args: [] Value_Id, tag: string, inputs: [] Value_Id, empty_bundle := false) -> Value_Id {
    fty := glob(f).value_type;
    i := new_inst(.CALL, func_ret(fty), cast(u32)(args.count + inputs.count + 1));
    r := inst(i);
    r.ty2 = fty;
    if inputs.count || empty_bundle {
        r.idx = cast(u32) ir.u32_pool.count; r.nidx = 1;
        array_add(*ir.u32_pool, bundle_tag_id(tag));
        array_add(*ir.u32_pool, cast(u32) args.count);
        array_add(*ir.u32_pool, cast(u32)(args.count + inputs.count));
    }
    for args set_op(i, cast(u32) it_index, it);
    for inputs set_op(i, cast(u32)(args.count + it_index), it);
    set_op(i, cast(u32)(args.count + inputs.count), f);
    return i;
}

// visitCallInst: case ptrauth_auth / ptrauth_resign
ic_visit_ptrauth_auth :: (ii: Value_Id) -> Ic_Switch_Result {
    need_sign := call_iid(ii) == IID_PTRAUTH_RESIGN;
    p := call_arg(ii, 0);
    key := call_arg(ii, 1);
    disc := call_arg(ii, 2);
    ds := ptrauth_ds_input(ii);
    auth_key: Value_Id = NONE; auth_disc: Value_Id = NONE; base_ptr: Value_Id = NONE;
    if is_inst(p) && is_call_base(p) {
        if ptrauth_ds_input(p) != ds return brk();
        ciid := call_iid(p);
        if ciid == IID_PTRAUTH_SIGN {
            if call_arg(p, 1) != key || call_arg(p, 2) != disc return brk();
        } else if ciid == IID_PTRAUTH_RESIGN {
            assert(ds == NONE, "The resign intrinsic does not support deactivation symbols");
            if call_arg(p, 3) != key || call_arg(p, 4) != disc return brk();
            auth_key = call_arg(p, 1);
            auth_disc = call_arg(p, 2);
        } else return brk();
        base_ptr = call_arg(p, 0);
    } else if opr_code(p) == .PTRTOINT {
        cpa := op(p, 0);
        if vkind(cpa) != .C_PTRAUTH || ds != NONE || !cpa_is_known_compatible_with(cpa, key, disc) return brk();
        // resign(ptrauth(p,ks,ds),ks,ds,kr,dr) -> ptrauth(p,kr,dr)
        if need_sign && vkind(call_arg(ii, 4)) == .C_INT {
            nullp := const_null(type_ptr_as(0));
            ncpa := const_ptrauth(cpa_pointer(cpa), call_arg(ii, 3), call_arg(ii, 4), nullp, nullp);
            ic_replace_inst_uses_with(ii, ce_pointer_cast(ncpa, vtype(ii)));
            return sw_done(ic_erase_inst(ii));
        }
        // auth(ptrauth(p,k,d),k,d) -> p
        base_ptr = icb_cast(.PTRTOINT, cpa_pointer(cpa), vtype(ii));
    } else return brk();

    new_intrin: Intrinsic_Id;
    if auth_key != NONE && need_sign new_intrin = IID_PTRAUTH_RESIGN;      // resign(0,1) + resign(1,2) = resign(0, 2)
    else if auth_key != NONE new_intrin = IID_PTRAUTH_AUTH;                // resign(0,1) + auth(1) = auth(0)
    else if need_sign new_intrin = IID_PTRAUTH_SIGN;                       // sign(0) + resign(0, 1) = sign(1)
    else {                                                                  // sign(0) + auth(0) = nop
        ic_replace_inst_uses_with(ii, base_ptr);
        return sw_done(ic_erase_inst(ii));
    }
    args: [..] Value_Id; args.allocator = temp;
    array_add(*args, base_ptr);
    if auth_key != NONE { array_add(*args, auth_key); array_add(*args, auth_disc); }
    if need_sign { array_add(*args, call_arg(ii, 3)); array_add(*args, call_arg(ii, 4)); }
    bundle: [..] Value_Id; bundle.allocator = temp;
    if ds != NONE array_add(*bundle, ds);
    nf := get_or_insert_intrinsic_declaration(new_intrin);
    return sw_done(create_call_fn_bundle(nf, args, "deactivation-symbol", bundle));
}
// ConstantExpr::getPointerCast(C, Ty)
ce_pointer_cast :: (c: Value_Id, t: Type_Id) -> Value_Id {
    if is_int_type(scalar_type(t)) return ce_cast(.PTRTOINT, c, t);
    if vtype(c) == t return c;
    return ce_cast(.BITCAST, c, t);
}

// CallBase::Create(&Call, Bundles): a copy of `call` (unlinked) with the bundles `keep` (indices, in order) plus
// an optional new bundle at the end, and the called operand `callee`. Like CallInst::Create(CI, OpB) it copies the
// tail call kind, calling convention, flags, attributes and the debug location, and no other metadata.
ic_call_with_bundles :: (call: Value_Id, keep: [] u32, add_tag: string, add_inputs: [] Value_Id, callee: Value_Id) -> Value_Id {
    na := call_arg_count(call);
    tail := call_non_data_operands(call);
    total := na;
    for keep { b, e := call_bundle_range(call, it); total += e - b; }
    if add_tag.count total += cast(u32) add_inputs.count;
    c := new_inst(inst_op(call), vtype(call), total + tail);
    src := inst(call).*;
    r := inst(c);
    r.* = src;
    r.parent = NONE; r.prev = NONE; r.next = NONE; r.records = 0;
    k: u32 = 0;
    for x: 0..cast(s64) na - 1 { set_op(c, k, op(call, cast(u32) x)); k += 1; }
    r.idx = cast(u32) ir.u32_pool.count;
    r.nidx = cast(u32) keep.count + (ifx add_tag.count then cast(u32) 1 else 0);
    for bi: keep {
        b, e := call_bundle_range(call, bi);
        tag := ir.u32_pool[src.idx + 3 * bi];
        start := k;
        for x: b..e-1 { set_op(c, k, op(call, x)); k += 1; }
        array_add(*ir.u32_pool, tag); array_add(*ir.u32_pool, start); array_add(*ir.u32_pool, k);
    }
    if add_tag.count {
        start := k;
        for add_inputs { set_op(c, k, it); k += 1; }
        array_add(*ir.u32_pool, bundle_tag_id(add_tag)); array_add(*ir.u32_pool, start); array_add(*ir.u32_pool, k);
    }
    n := nops(call);
    for x: 0..cast(s64) tail - 1 { set_op(c, k, op(call, n - tail + cast(u32) x)); k += 1; }
    set_op(c, nops(c) - 1, callee);
    set_metadata(c, 0, get_metadata(call, 0));
    return c;
}

// foldPtrAuthIntrinsicCallee
ic_fold_ptrauth_intrinsic_callee :: (call: Value_Id) -> Value_Id {
    callee := call_callee(call);
    if !is_inst(callee) || inst_op(callee) != .INTTOPTR || !cast_is_noop(callee) return NONE;
    ii := op(callee, 0);
    if !is_inst(ii) return NONE;
    iid := call_iid(ii);
    if iid != IID_PTRAUTH_RESIGN && iid != IID_PTRAUTH_SIGN return NONE;
    keep: [..] u32; keep.allocator = temp;
    pab: s64 = -1;
    nb := call_num_bundles(call);
    if nb > 0 for x: 0..nb-1 {
        if call_bundle_tag(call, x) == "ptrauth" pab = x;
        else array_add(*keep, x);
    }
    if pab < 0 return NONE;
    b, e := call_bundle_range(call, cast(u32) pab);
    in0 := op(call, b); in1 := op(call, b + 1);
    new_callee: Value_Id = NONE;
    add_tag := "";
    add: [..] Value_Id; add.allocator = temp;
    if iid == IID_PTRAUTH_RESIGN {
        // call(ptrauth.resign(p)), ["ptrauth"()] -> call p, ["ptrauth"()]
        if call_arg(ii, 3) != in0 || call_arg(ii, 4) != in1 || call_arg(ii, 1) != in0 return NONE;
        add_tag = "ptrauth";
        array_add(*add, call_arg(ii, 1)); array_add(*add, call_arg(ii, 2));
        new_callee = call_arg(ii, 0);
    } else {
        // call(ptrauth.sign(p)), ["ptrauth"()] -> call p
        if call_arg(ii, 1) != in0 || call_arg(ii, 2) != in1 return NONE;
        new_callee = call_arg(ii, 0);
    }
    new_callee = icb_bit_or_pointer_cast(new_callee, vtype(callee));
    return ic_call_with_bundles(call, keep, add_tag, add, new_callee);
}
// foldPtrAuthConstantCallee
ic_fold_ptrauth_constant_callee :: (call: Value_Id) -> Value_Id {
    cpa := call_callee(call);
    if vkind(cpa) != .C_PTRAUTH return NONE;
    callee_f := cpa_pointer(cpa);
    if vkind(callee_f) != .FUNCTION return NONE;
    pab: s64 = -1;
    nb := call_num_bundles(call);
    keep: [..] u32; keep.allocator = temp;
    if nb > 0 for x: 0..nb-1 {
        if call_bundle_tag(call, x) == "ptrauth" && pab < 0 pab = x;   // getOperandBundle: the first
        else array_add(*keep, x);
    }
    if pab < 0 return NONE;
    b, e := call_bundle_range(call, cast(u32) pab);
    if !cpa_is_known_compatible_with(cpa, op(call, b), op(call, b + 1)) return NONE;
    // CallBase::removeOperandBundle(&Call, OB_ptrauth): every other bundle stays
    return ic_call_with_bundles(call, keep, "", .[], callee_f);
}

// ---------------------------------------------------------------- trampolines
// findInitTrampolineFromAlloca, findInitTrampolineFromBB, findInitTrampoline, transformCallThroughTrampoline
// (InstCombineCalls.cpp)

// isa<IntrinsicInst>
ic_is_intrinsic_inst :: (v: Value_Id) -> bool { return is_inst(v) && inst_op(v) == .CALL && call_iid(v) != NOT_INTRINSIC; }

ic_find_init_trampoline_from_alloca :: (tramp_mem: Value_Id) -> Value_Id {
    underlying := strip_pointer_casts(tramp_mem);
    if underlying != tramp_mem && (!has_one_use(underlying) || ir.u_user[ir.v_first_use[underlying]] != tramp_mem) return NONE;
    if !is_inst(underlying) || inst_op(underlying) != .ALLOCA return NONE;
    init: Value_Id = NONE;
    u := ir.v_first_use[tramp_mem];
    while u != NONE {
        us := ir.u_user[u];
        u = ir.u_next[u];
        if !is_inst(us) || !ic_is_intrinsic_inst(us) return NONE;
        id := call_iid(us);
        if id == IID_INIT_TRAMPOLINE {
            if init != NONE return NONE;   // more than one init_trampoline writes to this value
            init = us;
            continue;
        }
        if id == IID_ADJUST_TRAMPOLINE continue;
        return NONE;
    }
    if init == NONE return NONE;
    if op(init, 0) != tramp_mem return NONE;
    return init;
}
ic_find_init_trampoline_from_bb :: (adjust: Value_Id, tramp_mem: Value_Id) -> Value_Id {
    x := inst_prev(adjust);
    while x != NONE {
        if ic_is_intrinsic_inst(x) && call_iid(x) == IID_INIT_TRAMPOLINE && op(x, 0) == tramp_mem return x;
        if may_write_to_memory(x) return NONE;
        x = inst_prev(x);
    }
    return NONE;
}
ic_find_init_trampoline :: (callee_in: Value_Id) -> Value_Id {
    callee := strip_pointer_casts(callee_in);
    if !is_inst(callee) || !ic_is_intrinsic_inst(callee) || call_iid(callee) != IID_ADJUST_TRAMPOLINE return NONE;
    tramp_mem := op(callee, 0);
    it := ic_find_init_trampoline_from_alloca(tramp_mem);
    if it != NONE return it;
    return ic_find_init_trampoline_from_bb(callee, tramp_mem);
}

ic_transform_call_through_trampoline :: (call: Value_Id, tramp: Value_Id) -> Value_Id {
    fty := inst(call).ty2;
    attrs := inst(call).attrs;
    if call_has_attr_somewhere(call, .Nest) return NONE;
    nest_f := strip_pointer_casts(call_arg(tramp, 1));
    assert(vkind(nest_f) == .FUNCTION, "init.trampoline of a non-function");
    nest_fty := glob(nest_f).value_type;
    nest_attrs := glob(nest_f).attrs;
    if nest_attrs != 0 {
        nest_arg_no: u32 = 0;
        nest_ty: Type_Id = NONE;
        nest_attr: u32 = 0;
        np := func_nparams(nest_fty);
        while nest_arg_no < np {
            as := attr_list_param(nest_attrs, nest_arg_no);
            if attr_set_has(as, .Nest) { nest_ty = func_param(nest_fty, nest_arg_no); nest_attr = as; break; }
            nest_arg_no += 1;
        }
        if nest_ty != NONE {
            if inst_op(call) == .CALLBR fatal("instcombine: transformCallThroughTrampoline of a callbr is not supported yet");
            new_args: [..] Value_Id; new_args.allocator = temp;
            new_arg_attrs: [..] u32; new_arg_attrs.allocator = temp;
            na := call_arg_count(call);
            arg_no: u32 = 0;
            while true {
                if arg_no == nest_arg_no {
                    nest_val := call_arg(tramp, 2);
                    if vtype(nest_val) != nest_ty nest_val = icb_cast(.BITCAST, nest_val, nest_ty, "nest");
                    array_add(*new_args, nest_val);
                    array_add(*new_arg_attrs, nest_attr);
                }
                if arg_no == na break;
                array_add(*new_args, call_arg(call, arg_no));
                array_add(*new_arg_attrs, attr_list_param(attrs, arg_no));
                arg_no += 1;
            }
            new_types: [..] Type_Id; new_types.allocator = temp;
            fnp := func_nparams(fty);
            k: u32 = 0;
            while true {
                if k == nest_arg_no array_add(*new_types, nest_ty);
                if k == fnp break;
                array_add(*new_types, func_param(fty, k));
                k += 1;
            }
            new_fty := type_func(func_ret(fty), new_types, func_vararg(fty));
            new_pal := attr_list_get(attr_list_fn(attrs), attr_list_ret(attrs), new_arg_attrs);
            // the operand bundles of the call, unchanged
            nb := call_num_bundles(call);
            tail := call_non_data_operands(call);
            nbo := nops(call) - tail - na;
            c := new_inst(inst_op(call), vtype(call), cast(u32)(new_args.count) + nbo + tail);
            src := inst(call);
            r := inst(c);
            r.ty2 = new_fty;
            r.attrs = new_pal;
            r.cc = src.cc;
            if inst_op(call) == .CALL r.flags = src.flags & ((cast(u32) 3) << TAIL_SHIFT);   // setTailCallKind
            for new_args set_op(c, cast(u32) it_index, it);
            kk := cast(u32) new_args.count;
            if nbo > 0 for x: 0..nbo-1 { set_op(c, kk, op(call, na + x)); kk += 1; }
            if nb > 0 {
                r.idx = cast(u32) ir.u32_pool.count; r.nidx = nb;
                shift := cast(u32) new_args.count - na;
                for x: 0..nb-1 {
                    array_add(*ir.u32_pool, ir.u32_pool[src.idx + 3 * x]);
                    array_add(*ir.u32_pool, ir.u32_pool[src.idx + 3 * x + 1] + shift);
                    array_add(*ir.u32_pool, ir.u32_pool[src.idx + 3 * x + 2] + shift);
                }
            }
            // invoke: normal and unwind destinations, then the callee
            if tail > 1 for x: 0..tail-2 { set_op(c, kk, op(call, nops(call) - tail + x)); kk += 1; }
            set_op(c, kk, nest_f);
            set_metadata(c, 0, get_metadata(call, 0));
            return c;
        }
    }
    // no 'nest' parameter: call the function directly with the call's function type (setCalledFunction)
    set_op(call, nops(call) - 1, nest_f);
    return call;
}

// ---------------------------------------------------------------- gc.statepoint (visitCallBase)

// GCStatepointInst::getGCRelocates: the gc.relocate users of the statepoint, then (for an invoke) those of its
// landing pad
gc_relocates_of :: (sp: Value_Id) -> [..] Value_Id {
    r: [..] Value_Id; r.allocator = temp;
    add_users :: (v: Value_Id, r: *[..] Value_Id) {
        u := ir.v_first_use[v];
        while u != NONE {
            us := ir.u_user[u];
            if is_inst(us) && inst_op(us) == .CALL && call_iid(us) == IID_EXPERIMENTAL_GC_RELOCATE array_add(r, us);
            u = ir.u_next[u];
        }
    }
    add_users(sp, *r);
    if inst_op(sp) != .INVOKE return r;
    lp := block_first_non_phi(get_successor(sp, 1));
    add_users(lp, *r);
    return r;
}

ic_visit_gc_statepoint :: (call: Value_Id, changed: bool) -> Value_Id {
    live: [..] Value_Id; live.allocator = temp;   // LiveGcValues (only its size is used)
    for gcr: gc_relocates_of(call) {
        if !has_uses(gcr) { ic_erase_inst(gcr); continue; }
        derived := gc_relocate_ptr(gcr, 2);
        base := gc_relocate_ptr(gcr, 1);
        if derived == NONE || base == NONE fatal("instcombine: gc.relocate with an invalid base or derived pointer index");
        dk := vkind(derived); bk := vkind(base);
        if dk == .C_UNDEF || dk == .C_POISON || bk == .C_UNDEF || bk == .C_POISON {
            ic_replace_inst_uses_with(gcr, const_undef(vtype(gcr)));
            ic_erase_inst(gcr);
            continue;
        }
        if is_ptr_type(vtype(gcr)) {
            if dk == .C_NULL {
                ic_replace_inst_uses_with(gcr, const_null(vtype(gcr)));
                ic_erase_inst(gcr);
                continue;
            }
            if !call_has_ret_attr(gcr, .NonNull) && is_known_non_zero(derived, ic_q(call)) {
                call_add_ret_attr_kind(gcr, .NonNull);
                wl_push_users(gcr);
            }
        }
        // two copies of the same pointer in the statepoint argument list: canonicalize to one
        if gc_relocate_ptr(gcr, 1) == gc_relocate_ptr(gcr, 2) && const_int_zext(op(gcr, 1)) != const_int_zext(op(gcr, 2))
            set_op(gcr, 2, const_int(vtype(op(gcr, 2)), const_int_zext(op(gcr, 1))));
        array_add_if_unique(*live, base);
        array_add_if_unique(*live, derived);
    }
    gl: s64 = -1;
    nb := call_num_bundles(call);
    if nb > 0 for x: 0..nb-1 if call_bundle_tag(call, x) == "gc-live" { gl = x; break; }
    if gl < 0 return ifx changed then call else NONE;
    b, e := call_bundle_range(call, cast(u32) gl);
    if cast(u32) live.count == e - b return ifx changed then call else NONE;
    // reduce the size of the gc-live bundle
    num_live := cast(u32) live.count;
    val2idx: Table(Value_Id, u32); val2idx.allocator = temp;
    new_live: [..] Value_Id; new_live.allocator = temp;
    for x: b..e-1 {
        v := op(call, x);
        if table_contains(*val2idx, v) continue;
        found := false; for live if it == v found = true;
        if found { table_set(*val2idx, v, cast(u32) new_live.count); array_add(*new_live, v); }
        else table_set(*val2idx, v, num_live);
    }
    for gcr: gc_relocates_of(call) {
        bp := gc_relocate_ptr(gcr, 1);
        okb, bi := table_find(*val2idx, bp);
        assert(okb && bi != num_live, "Missed live gc for base pointer");
        set_op(gcr, 1, const_int(vtype(op(gcr, 1)), bi));
        dp := gc_relocate_ptr(gcr, 2);
        okd, di := table_find(*val2idx, dp);
        assert(okd && di != num_live, "Missed live gc for derived pointer");
        set_op(gcr, 2, const_int(vtype(op(gcr, 2)), di));
    }
    keep: [..] u32; keep.allocator = temp;
    for x: 0..nb-1 if call_bundle_tag(call, x) != "gc-live" array_add(*keep, x);
    return ic_call_with_bundles(call, keep, "gc-live", new_live, call_callee(call));
}
