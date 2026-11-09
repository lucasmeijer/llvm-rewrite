// DeadArgumentElimination: remove dead arguments and return values of internal functions, dead varargs, and pass
// poison for unused arguments of non-local functions.
// Ported from llvm/lib/Transforms/IPO/DeadArgumentElimination.cpp.
// A RetOrArg is a u64 key (function << 32 | index << 1 | is_arg); Uses (a std::multimap) is a table from the key to
// the keys that become live with it; liveness is a fixpoint, so the iteration order of these sets is irrelevant.

Dae_Liveness :: enum u8 { LIVE; MAYBE_LIVE; }

Dae :: struct {
    live_values: Table(u64, bool);
    uses: Table(u64, [..] u64);
    frozen: Table(Value_Id, bool);
    frozen_ret_ty: Table(Value_Id, bool);
}

dae_ret :: (f: Value_Id, idx: u32) -> u64 { return ((cast(u64) f) << 32) | ((cast(u64) idx) << 1); }
dae_arg :: (f: Value_Id, idx: u32) -> u64 { return ((cast(u64) f) << 32) | ((cast(u64) idx) << 1) | 1; }
dae_fn :: (ra: u64) -> Value_Id { return cast(Value_Id) (ra >> 32); }

// numRetVals
dae_num_ret_vals :: (f: Value_Id) -> u32 {
    rt := func_ret(glob(f).value_type);
    k := type_kind(rt);
    if k == .VOID return 0;
    if k == .STRUCT return type_nsub(rt);
    if k == .ARRAY return cast(u32) type_count(rt);
    return 1;
}
// getRetComponentType
dae_ret_component_type :: (f: Value_Id, idx: u32) -> Type_Id {
    rt := func_ret(glob(f).value_type);
    k := type_kind(rt);
    if k == .STRUCT return type_sub(rt, idx);
    if k == .ARRAY return type_elem(rt);
    return rt;
}

dae_is_live :: (s: *Dae, ra: u64) -> bool { return table_contains(*s.frozen, dae_fn(ra)) || table_contains(*s.live_values, ra); }

// markIfNotLive
dae_mark_if_not_live :: (s: *Dae, use: u64, maybe_live_uses: *[..] u64) -> Dae_Liveness {
    if dae_is_live(s, use) return .LIVE;
    array_add(maybe_live_uses, use);
    return .MAYBE_LIVE;
}

// surveyUse (ret_val_num = 0xFFFF_FFFF: -1U)
dae_survey_use :: (s: *Dae, u: Use_Id, maybe_live_uses: *[..] u64, ret_val_num_in: u32 = 0xFFFF_FFFF) -> Dae_Liveness {
    ret_val_num := ret_val_num_in;
    v := ir.u_user[u];
    if !is_inst(v) return .LIVE;
    o := inst_op(v);
    if o == .RET {
        f := inst_fn(v);
        if ret_val_num != 0xFFFF_FFFF return dae_mark_if_not_live(s, dae_ret(f, ret_val_num), maybe_live_uses);
        result := Dae_Liveness.MAYBE_LIVE;
        for ri: 0..cast(s64) dae_num_ret_vals(f) - 1 {
            sub := dae_mark_if_not_live(s, dae_ret(f, cast(u32) ri), maybe_live_uses);
            if result != .LIVE result = sub;
        }
        return result;
    }
    if o == .INSERTVALUE {
        if opno_of(u) != 0 && inst(v).nidx > 0 ret_val_num = ir.u32_pool[inst(v).idx];
        result := Dae_Liveness.MAYBE_LIVE;
        uu := ir.v_first_use[v];
        while uu != NONE {
            result = dae_survey_use(s, uu, maybe_live_uses, ret_val_num);
            if result == .LIVE break;
            uu = ir.u_next[uu];
        }
        return result;
    }
    if is_call_base(v) {
        f := call_called_function(v);
        if f != NONE {
            opno := opno_of(u);
            na := call_num_args(v);
            if opno >= na && opno < nops(v) - call_non_data_operands(v) return .LIVE;   // a bundle operand
            if opno >= func_nparams(glob(f).value_type) return .LIVE;   // passed through a vararg
            return dae_mark_if_not_live(s, dae_arg(f, opno), maybe_live_uses);
        }
    }
    return .LIVE;
}

// surveyUses
dae_survey_uses :: (s: *Dae, v: Value_Id, maybe_live_uses: *[..] u64) -> Dae_Liveness {
    result := Dae_Liveness.MAYBE_LIVE;
    u := ir.v_first_use[v];
    while u != NONE {
        result = dae_survey_use(s, u, maybe_live_uses);
        if result == .LIVE break;
        u = ir.u_next[u];
    }
    return result;
}

// markFrozen
dae_mark_frozen :: (s: *Dae, f: Value_Id) {
    table_set(*s.frozen, f, true);
    for k: 0..cast(s64) glob(f).nargs - 1 dae_propagate_liveness(s, dae_arg(f, cast(u32) k));
    for k: 0..cast(s64) dae_num_ret_vals(f) - 1 dae_propagate_liveness(s, dae_ret(f, cast(u32) k));
}
// markFnOrRetTyFrozenOnMusttail (the condition is always true: CC != SwiftTail || CC != Tail)
dae_mark_fn_or_ret_ty_frozen_on_musttail :: (s: *Dae, f: Value_Id) -> bool {
    dae_mark_frozen(s, f);
    return true;
}
// markLive
dae_mark_live :: (s: *Dae, ra: u64) {
    if dae_is_live(s, ra) return;
    table_set(*s.live_values, ra, true);
    dae_propagate_liveness(s, ra);
}
// propagateLiveness
dae_propagate_liveness :: (s: *Dae, ra: u64) {
    p := table_find_pointer(*s.uses, ra);
    if !p return;
    list := p.*;
    table_remove(*s.uses, ra);
    for list dae_mark_live(s, it);
}
// markValue
dae_mark_value :: (s: *Dae, ra: u64, l: Dae_Liveness, maybe_live_uses: [] u64) {
    if l == .LIVE { dae_mark_live(s, ra); return; }
    for mlu: maybe_live_uses {
        if dae_is_live(s, mlu) { dae_mark_live(s, ra); break; }
        p := table_find_pointer(*s.uses, mlu);
        if !p { e: [..] u64; e.allocator = temp; table_set(*s.uses, mlu, e); p = table_find_pointer(*s.uses, mlu); }
        array_add(p, ra);
    }
}

dae_is_must_tail_call :: (c: Value_Id) -> bool { return inst_op(c) == .CALL && ((inst(c).flags >> 16) & 3) == 2; }

// surveyFunction
dae_survey_function :: (s: *Dae, f: Value_Id) {
    if !gv_has_local_linkage(f) { dae_mark_frozen(s, f); return; }
    if fn_has_attr_somewhere(f, .InAlloca) || fn_has_attr_somewhere(f, .Preallocated) { dae_mark_frozen(s, f); return; }
    if fn_has_fn_attr(f, .Naked) { dae_mark_frozen(s, f); return; }
    if !gv_is_definition_exact(f) { dae_mark_frozen(s, f); return; }
    ret_count := dae_num_ret_vals(f);
    ret_liveness := NewArray(ret_count, Dae_Liveness,, allocator = temp);
    for * ret_liveness it.* = .MAYBE_LIVE;
    maybe_live_ret_uses := NewArray(ret_count, [..] u64,, allocator = temp);
    for * maybe_live_ret_uses it.allocator = temp;
    for b: fn_blocks(f) {
        if block_terminating_must_tail_call(b) != NONE {
            if dae_mark_fn_or_ret_ty_frozen_on_musttail(s, f) return;
        }
    }
    num_live_ret_vals: u32 = 0;
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        cb := ir.u_user[u];
        if vkind(cb) == .C_BLOCKADDR continue;   // not a use of the function in LLVM 23
        if !(is_inst(cb) && is_call_base(cb)) || opno_of(u) != nops(cb) - 1 || inst(cb).ty2 != glob(f).value_type {
            dae_mark_frozen(s, f);
            return;
        }
        if dae_is_must_tail_call(cb) {
            if dae_mark_fn_or_ret_ty_frozen_on_musttail(s, f) return;
        }
        if num_live_ret_vals == ret_count continue;
        uu := ir.v_first_use[cb];
        while uu != NONE {
            defer uu = ir.u_next[uu];
            usr := ir.u_user[uu];
            if is_inst(usr) && inst_op(usr) == .EXTRACTVALUE {
                idx := ir.u32_pool[inst(usr).idx];
                if ret_liveness[idx] != .LIVE {
                    ret_liveness[idx] = dae_survey_uses(s, usr, *maybe_live_ret_uses[idx]);
                    if ret_liveness[idx] == .LIVE num_live_ret_vals += 1;
                }
            } else {
                agg_uses: [..] u64; agg_uses.allocator = temp;
                if dae_survey_use(s, uu, *agg_uses) == .LIVE {
                    num_live_ret_vals = ret_count;
                    for * ret_liveness it.* = .LIVE;
                    break;
                }
                for ri: 0..cast(s64) ret_count - 1 {
                    if ret_liveness[ri] != .LIVE for agg_uses array_add(*maybe_live_ret_uses[ri], it);
                }
            }
        }
    }
    for ri: 0..cast(s64) ret_count - 1 dae_mark_value(s, dae_ret(f, cast(u32) ri), ret_liveness[ri], maybe_live_ret_uses[ri]);
    vararg := func_vararg(glob(f).value_type);
    for k: 0..cast(s64) glob(f).nargs - 1 {
        uses: [..] u64; uses.allocator = temp;
        result: Dae_Liveness;
        if vararg result = .LIVE;
        else result = dae_survey_uses(s, fn_arg(f, cast(u32) k), *uses);
        dae_mark_value(s, dae_arg(f, cast(u32) k), result, uses);
    }
}

// the call sites of f (Value::users() of a function whose uses are all calls; blockaddresses are not uses)
dae_call_users :: (f: Value_Id) -> [..] Value_Id {
    out: [..] Value_Id; out.allocator = temp;
    u := ir.v_first_use[f];
    while u != NONE { usr := ir.u_user[u]; if vkind(usr) != .C_BLOCKADDR array_add(*out, usr); u = ir.u_next[u]; }
    return out;
}
dae_first_call_user :: (f: Value_Id) -> Value_Id {
    u := ir.v_first_use[f];
    while u != NONE { usr := ir.u_user[u]; if vkind(usr) != .C_BLOCKADDR return usr; u = ir.u_next[u]; }
    return NONE;
}

// moving the arguments and the remaining (blockaddress) uses of the old function to the new one
dae_finish_function_move :: (nf: Value_Id, f: Value_Id) {
    // Clone metadata from the old function, including debug info descriptor
    mds: [..] Kind_Md; mds.allocator = temp;
    get_all_metadata(f, *mds);
    for mds add_metadata(nf, it.kind, it.md);
}

// deleteDeadVarargs
dae_delete_dead_varargs :: (f: Value_Id) -> bool {
    if is_declaration(f) || !gv_has_local_linkage(f) return false;
    if fn_has_address_taken(f) return false;
    if fn_has_fn_attr(f, .Naked) return false;
    for i: fn_insts(f) {
        if inst_op(i) != .CALL continue;
        if dae_is_must_tail_call(i) return false;
        if call_iid(i) == IID_VASTART return false;
    }
    fty := glob(f).value_type;
    num_args := func_nparams(fty);
    params: [..] Type_Id; params.allocator = temp;
    for k: 0..cast(s64) num_args - 1 array_add(*params, func_param(fty, cast(u32) k));
    nfty := type_func(func_ret(fty), params, false);
    nf := ipo_fn_create(nfty, glob(f).linkage, glob(f).addrspace);
    ipo_fn_copy_attributes_from(nf, f);
    glob(nf).comdat = glob(f).comdat;
    ipo_fn_insert_before(nf, f);
    gv_take_name(nf, f);
    for cb: dae_call_users(f) {
        if !(is_inst(cb) && is_call_base(cb)) continue;
        args: [..] Value_Id; args.allocator = temp;
        for k: 0..cast(s64) num_args - 1 array_add(*args, call_arg(cb, cast(u32) k));
        pal := inst(cb).attrs;
        if pal != 0 pal = attr_list_get(attr_list_fn(pal), attr_list_ret(pal), ipo_param_attrs(pal, num_args));
        ncb := ipo_create_call_like(cb, nfty, nf, args, cb);
        if inst_op(cb) == .CALL inst(ncb).flags = inst(cb).flags & ((cast(u32) 3) << 16);   // setTailCallKind
        inst(ncb).cc = inst(cb).cc;
        inst(ncb).attrs = pal;
        ipo_copy_prof_dbg(ncb, cb);
        if has_uses(cb) rauw_with_metadata(cb, ncb);
        ic_take_name(ncb, cb);
        erase_inst_with_metadata(cb);
    }
    ipo_fn_splice_body(nf, f);
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k); a2 := fn_arg(nf, cast(u32) k);
        rauw_with_metadata(a, a2);
        ic_take_name(a2, a);
    }
    dae_finish_function_move(nf, f);
    ipo_rauw(f, nf);   // F.replaceAllUsesWith(NF): blockaddresses, and metadata follows
    remove_dead_constant_users(nf);
    gv_erase_from_parent(f);
    return true;
}

// removeDeadArgumentsFromCallers
dae_remove_dead_arguments_from_callers :: (s: *Dae, f: Value_Id) -> bool {
    if is_declaration(f) || !gv_is_definition_exact(f) return false;   // hasExactDefinition
    if gv_has_local_linkage(f) && !table_contains(*s.frozen, f) && !func_vararg(glob(f).value_type) return false;
    if fn_has_fn_attr(f, .Naked) return false;
    if fn_use_empty(f) return false;
    unused: [..] u32; unused.allocator = temp;
    changed := false;
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        at := arg_attrs(a);
        if !attr_set_has(at, .SwiftError) && !has_uses(a) &&
           !(attr_set_has(at, .ByVal) || attr_set_has(at, .InAlloca) || attr_set_has(at, .Preallocated)) {
            if value_is_used_by_metadata(a) {
                rauw_with_metadata(a, const_poison(vtype(a)));
                changed = true;
            }
            array_add(*unused, cast(u32) k);
            fn_set_param_attrs(f, cast(u32) k, dae_remove_ub_implying(attr_list_param(glob(f).attrs, cast(u32) k)));
        }
    }
    if unused.count == 0 return false;
    u := ir.v_first_use[f];
    while u != NONE {
        defer u = ir.u_next[u];
        cb := ir.u_user[u];
        if !(is_inst(cb) && is_call_base(cb)) || opno_of(u) != nops(cb) - 1 || inst(cb).ty2 != glob(f).value_type continue;
        for argno: unused {
            set_op(cb, argno, const_poison(vtype(call_arg(cb, argno))));
            l := inst(cb).attrs;
            if l != 0 inst(cb).attrs = attr_list_with_param(l, argno, dae_remove_ub_implying(attr_list_param(l, argno)));
            changed = true;
        }
    }
    return changed;
}
// AttributeFuncs::getUBImplyingAttributes: noundef, dereferenceable, dereferenceable_or_null
dae_remove_ub_implying :: (s: u32) -> u32 {
    r := attr_set_remove(s, .NoUndef);
    r = attr_set_remove(r, .Dereferenceable);
    r = attr_set_remove(r, .DereferenceableOrNull);
    return r;
}
fn_set_param_attrs :: (f: Value_Id, k: u32, s: u32) {
    l := glob(f).attrs;
    if attr_list_param(l, k) == s return;
    glob(f).attrs = attr_list_with_param(l, k, s);
}
// Value::isUsedByMetadata: a ValueAsMetadata exists for it
value_is_used_by_metadata :: (v: Value_Id) -> bool {
    k := *md_key; key_reset(k); key_u8(k, 1); key_u32(k, v);
    return table_contains(*ir.md_map, key_view(k));
}

// AttrBuilder::remove(AttributeFuncs::typeIncompatible(Ty, AS)) on an attribute set
dae_remove_type_incompatible :: (s: u32, ty: Type_Id) -> u32 {
    kinds: [..] Attr_Kind; kinds.allocator = temp;
    ic_type_incompatible(ty, s, ASK_ALL, *kinds);
    r := s;
    for kinds r = attr_set_remove(r, it);
    return r;
}

// IRBuilder<NoFolder>::CreateExtractValue / CreateInsertValue before `pos`
dae_create_extract_value :: (agg: Value_Id, idx: u32, name: string, pos: Value_Id) -> Value_Id {
    t := vtype(agg);
    et := ifx type_kind(t) == .STRUCT then type_sub(t, idx) else type_elem(t);
    i := new_inst(.EXTRACTVALUE, et, 1);
    set_op(i, 0, agg);
    inst(i).idx = cast(u32) ir.u32_pool.count; inst(i).nidx = 1;
    array_add(*ir.u32_pool, idx);
    insert_at_position(i, inst_block(pos), pos, false);
    i_copy_builder_debug_loc(i, pos);
    set_name(i, name);
    return i;
}
dae_create_insert_value :: (agg: Value_Id, v: Value_Id, idx: u32, name: string, pos: Value_Id) -> Value_Id {
    i := new_inst(.INSERTVALUE, vtype(agg), 2);
    set_op(i, 0, agg); set_op(i, 1, v);
    inst(i).idx = cast(u32) ir.u32_pool.count; inst(i).nidx = 1;
    array_add(*ir.u32_pool, idx);
    insert_at_position(i, inst_block(pos), pos, false);
    i_copy_builder_debug_loc(i, pos);
    set_name(i, name);
    return i;
}
// IRBuilder(InsertPt): the debug location of the insertion point
i_copy_builder_debug_loc :: (i: Value_Id, pos: Value_Id) {
    d := get_metadata(pos, MDK_DBG);
    if d != NONE set_metadata(i, MDK_DBG, d);
}

// removeDeadStuffFromFunction
dae_remove_dead_stuff_from_function :: (s: *Dae, f: Value_Id) -> bool {
    if table_contains(*s.frozen, f) return false;
    fty := glob(f).value_type;
    params: [..] Type_Id; params.allocator = temp;
    has_live_returned_arg := false;
    arg_attr_vec: [..] u32; arg_attr_vec.allocator = temp;
    pal := glob(f).attrs;
    nparams := func_nparams(fty);
    arg_alive := NewArray(nparams, bool,, allocator = temp);
    for k: 0..cast(s64) glob(f).nargs - 1 {
        ra := dae_arg(f, cast(u32) k);
        if table_contains(*s.live_values, ra) {
            table_remove(*s.live_values, ra);
            array_add(*params, vtype(fn_arg(f, cast(u32) k)));
            arg_alive[k] = true;
            array_add(*arg_attr_vec, attr_list_param(pal, cast(u32) k));
            if attr_set_has(attr_list_param(pal, cast(u32) k), .Returned) has_live_returned_arg = true;
        }
    }
    ret_ty := func_ret(fty);
    nret_ty: Type_Id = NONE;
    ret_count := dae_num_ret_vals(f);
    new_ret_idxs := NewArray(ret_count, s32,, allocator = temp);
    for * new_ret_idxs it.* = -1;
    ret_types: [..] Type_Id; ret_types.allocator = temp;
    if type_kind(ret_ty) == .VOID || has_live_returned_arg || table_contains(*s.frozen_ret_ty, f) {
        nret_ty = ret_ty;
    } else {
        for ri: 0..cast(s64) ret_count - 1 {
            ra := dae_ret(f, cast(u32) ri);
            if table_contains(*s.live_values, ra) {
                table_remove(*s.live_values, ra);
                array_add(*ret_types, dae_ret_component_type(f, cast(u32) ri));
                new_ret_idxs[ri] = cast(s32) (ret_types.count - 1);
            }
        }
        if ret_types.count > 1 {
            if type_kind(ret_ty) == .STRUCT nret_ty = type_literal_struct(ret_types, (ir.types[ret_ty].flags & TYF_PACKED) != 0);
            else nret_ty = type_array(cast(u64) ret_types.count, ret_types[0]);
        } else if ret_types.count == 1 nret_ty = ret_types[0];
        else nret_ty = ir.t_void;
    }
    ret_attrs := attr_list_ret(pal);
    if type_kind(nret_ty) == .VOID ret_attrs = dae_remove_type_incompatible(ret_attrs, nret_ty);
    fn_attrs := attr_set_remove(attr_list_fn(pal), .AllocSize);
    new_pal := attr_list_get(fn_attrs, ret_attrs, arg_attr_vec);
    nfty := type_func(nret_ty, params, func_vararg(fty));
    if nfty == fty return false;

    nf := ipo_fn_create(nfty, glob(f).linkage, glob(f).addrspace);
    ipo_fn_copy_attributes_from(nf, f);
    glob(nf).comdat = glob(f).comdat;
    glob(nf).attrs = new_pal;
    ipo_fn_insert_before(nf, f);
    gv_take_name(nf, f);

    while true {
        cb := dae_first_call_user(f);
        if cb == NONE break;
        if !(is_inst(cb) && is_call_base(cb)) fatal("deadargelim: a use of the function that is not a call");
        call_pal := inst(cb).attrs;
        rattrs := dae_remove_type_incompatible(attr_list_ret(call_pal), nret_ty);
        args: [..] Value_Id; args.allocator = temp;
        av: [..] u32; av.allocator = temp;
        pi: u32 = 0;
        while pi < nparams {
            if arg_alive[pi] {
                array_add(*args, call_arg(cb, pi));
                at := attr_list_param(call_pal, pi);
                if nret_ty != ret_ty && attr_set_has(at, .Returned) array_add(*av, attr_set_remove(at, .Returned));
                else array_add(*av, at);
            }
            pi += 1;
        }
        na := call_num_args(cb);
        while pi < na {
            array_add(*args, call_arg(cb, pi));
            array_add(*av, attr_list_param(call_pal, pi));
            pi += 1;
        }
        cfn := attr_set_remove(attr_list_fn(call_pal), .AllocSize);
        new_call_pal := attr_list_get(cfn, rattrs, av);
        ncb: Value_Id;
        if inst_op(cb) == .INVOKE ncb = ipo_create_call_like(cb, nfty, nf, args, NONE, inst_block(cb));
        else {
            ncb = ipo_create_call_like(cb, nfty, nf, args, cb);
            inst(ncb).flags = inst(cb).flags & ((cast(u32) 3) << 16);
        }
        inst(ncb).cc = inst(cb).cc;
        inst(ncb).attrs = new_call_pal;
        ipo_copy_prof_dbg(ncb, cb);
        if has_uses(cb) || value_is_used_by_metadata(cb) {
            if vtype(ncb) == vtype(cb) {
                rauw_with_metadata(cb, ncb);
                ic_take_name(ncb, cb);
            } else if type_kind(vtype(ncb)) == .VOID {
                rauw_with_metadata(cb, const_poison(vtype(cb)));
            } else {
                insert_pt := cb;
                if inst_op(cb) == .INVOKE {
                    new_edge := split_edge(inst_block(ncb), get_successor(ncb, 0), null, null);
                    insert_pt = block_first_insertion_pt(new_edge);
                }
                ret_val := const_poison(ret_ty);
                for ri: 0..cast(s64) ret_count - 1 {
                    if new_ret_idxs[ri] == -1 continue;
                    v: Value_Id;
                    if ret_types.count > 1 v = dae_create_extract_value(ncb, cast(u32) new_ret_idxs[ri], "newret", insert_pt);
                    else v = ncb;
                    ret_val = dae_create_insert_value(ret_val, v, cast(u32) ri, "oldret", insert_pt);
                }
                rauw_with_metadata(cb, ret_val);
                ic_take_name(ncb, cb);
            }
        }
        erase_inst_with_metadata(cb);
    }
    ipo_fn_splice_body(nf, f);
    k2: u32 = 0;
    for k: 0..cast(s64) glob(f).nargs - 1 {
        a := fn_arg(f, cast(u32) k);
        if arg_alive[k] {
            a2 := fn_arg(nf, k2);
            rauw_with_metadata(a, a2);
            ic_take_name(a2, a);
            k2 += 1;
        } else {
            rauw_with_metadata(a, const_poison(vtype(a)));
        }
    }
    if ret_ty != nret_ty {
        for bb: fn_blocks(nf) {
            ri := block_terminator(bb);
            if ri == NONE || inst_op(ri) != .RET continue;
            ret_val: Value_Id = NONE;
            if type_kind(nret_ty) != .VOID {
                old_ret := op(ri, 0);
                ret_val = const_poison(nret_ty);
                for k: 0..cast(s64) ret_count - 1 {
                    if new_ret_idxs[k] == -1 continue;
                    ev := dae_create_extract_value(old_ret, cast(u32) k, "oldret", ri);
                    if ret_types.count > 1 ret_val = dae_create_insert_value(ret_val, ev, cast(u32) new_ret_idxs[k], "newret", ri);
                    else ret_val = ev;
                }
            }
            nr := new_inst(.RET, ir.t_void, ifx ret_val != NONE then cast(u32) 1 else 0);
            if ret_val != NONE set_op(nr, 0, ret_val);
            insert_at_position(nr, bb, ri, false);
            d := get_metadata(ri, MDK_DBG);
            if d != NONE set_metadata(nr, MDK_DBG, d);
            erase_inst_with_metadata(ri);
        }
    }
    dae_finish_function_move(nf, f);
    if nfty != fty ipo_mark_subprogram_nocall(nf);
    if has_uses(f) replace_all_uses_with(f, nf);   // blockaddresses of the moved blocks (BlockAddress::getFunction)
    gv_erase_from_parent(f);
    return true;
}

dead_arg_elim_run :: () -> Preserved {
    s: Dae;
    s.live_values.allocator = temp; s.uses.allocator = temp; s.frozen.allocator = temp; s.frozen_ret_ty.allocator = temp;
    changed := false;
    // make_early_inc_range(M): each function's successor is fixed before it is processed
    run_early_inc :: (s: *Dae, phase: int) -> bool {
        changed := false;
        next_f: Value_Id = ifx ir.m_functions.count then ir.m_functions[0] else NONE;
        pos := 0;
        while next_f != NONE {
            f := next_f;
            pos = list_index_of_hint(ir.m_functions, f, pos);
            next_f = ifx pos + 1 < ir.m_functions.count then ir.m_functions[pos + 1] else NONE;
            if phase == 0 { if func_vararg(glob(f).value_type) changed |= dae_delete_dead_varargs(f); }
            else changed |= dae_remove_dead_stuff_from_function(s, f);
        }
        return changed;
    }
    changed |= run_early_inc(*s, 0);
    for f: ir.m_functions dae_survey_function(*s, f);
    changed |= run_early_inc(*s, 1);
    for f: ir.m_functions changed |= dae_remove_dead_arguments_from_callers(*s, f);
    if !changed return PRESERVE_ALL;
    printer_note_ir_changed();
    return PRESERVE_NONE;
}
