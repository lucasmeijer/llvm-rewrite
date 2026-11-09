// Evaluator: a constant interpreter for static constructors (GlobalOpt's ctor evaluation).
// Ported from llvm/lib/Transforms/Utils/Evaluator.cpp and llvm/include/llvm/Transforms/Utils/Evaluator.h.
// MutableValue / MutableAggregate are rows of `ev.mvs` / `ev.aggs` (a MutableValue holds a constant or an aggregate
// row; an aggregate holds its element MutableValue rows).

Ev_Mv :: struct { c: Value_Id = NONE; agg: s32 = -1; }
Ev_Agg :: struct { ty: Type_Id; elems: [..] s32; }

Evaluator :: struct {
    mvs: [..] Ev_Mv;
    aggs: [..] Ev_Agg;
    value_stack: [..] Table(Value_Id, Value_Id);
    call_stack: [..] Value_Id;
    mutated: Table(Value_Id, s32);          // MutatedMemory: GV -> MutableValue row
    mutated_order: [..] Value_Id;
    alloca_tmps: [..] Value_Id;
    invariants: [..] Value_Id;
    simple_constants: Table(Value_Id, bool);
    failed: bool;
}

ev_init :: (ev: *Evaluator) {
    ev.mvs.allocator = temp; ev.aggs.allocator = temp; ev.value_stack.allocator = temp; ev.call_stack.allocator = temp;
    ev.mutated.allocator = temp; ev.mutated_order.allocator = temp; ev.alloca_tmps.allocator = temp;
    ev.invariants.allocator = temp; ev.simple_constants.allocator = temp;
    ev_push_frame(ev);
}
ev_push_frame :: (ev: *Evaluator) {
    t: Table(Value_Id, Value_Id); t.allocator = temp;
    array_add(*ev.value_stack, t);
}
// ~Evaluator: temporaries that are still used become null
ev_destroy :: (ev: *Evaluator) {
    for ev.alloca_tmps if has_uses(it) replace_all_uses_with(it, const_null_value(vtype(it)));
    // the unique_ptr<GlobalVariable>s are destroyed: their initializers stop being used
    for ev.alloca_tmps { drop_all_references(it); ir.v_kind[it] = .DEAD; }
}

ev_get_val :: (ev: *Evaluator, v: Value_Id) -> Value_Id {
    if is_const(v) return v;
    found, r := table_find(*ev.value_stack[ev.value_stack.count - 1], v);
    if !found fatal("globalopt: Evaluator: reference to an uncomputed value");
    return r;
}
ev_set_val :: (ev: *Evaluator, v: Value_Id, c: Value_Id) {
    table_set(*ev.value_stack[ev.value_stack.count - 1], v, c);
}

// isSimpleEnoughValueToCommit
ev_is_simple_enough_value_to_commit :: (ev: *Evaluator, c: Value_Id) -> bool {
    if table_contains(*ev.simple_constants, c) return true;
    table_add(*ev.simple_constants, c, true);
    return ev_is_simple_enough_helper(ev, c);
}
ev_is_simple_enough_helper :: (ev: *Evaluator, c: Value_Id) -> bool {
    k := vkind(c);
    if is_global_value(k) return glob(c).dll != 1 && glob(c).tls == 0;
    if k == .C_BLOCKADDR return true;
    if k == .C_ARRAY || k == .C_STRUCT || k == .C_VECTOR {
        for j: 0..cast(s64) nops(c) - 1 if !ev_is_simple_enough_value_to_commit(ev, op(c, cast(u32) j)) return false;
        return true;
    }
    if nops(c) == 0 return true;
    if k != .C_EXPR return false;
    o := cexpr(c).op;
    if o == .BITCAST return ev_is_simple_enough_value_to_commit(ev, op(c, 0));
    if o == .INTTOPTR || o == .PTRTOINT {
        if dl_type_size_bits(vtype(c)) != dl_type_size_bits(vtype(op(c, 0))) return false;
        return ev_is_simple_enough_value_to_commit(ev, op(c, 0));
    }
    if o == .GEP {
        for j: 1..cast(s64) nops(c) - 1 if vkind(op(c, cast(u32) j)) != .C_INT return false;
        return ev_is_simple_enough_value_to_commit(ev, op(c, 0));
    }
    if o == .ADD {
        if vkind(op(c, 1)) != .C_INT return false;
        return ev_is_simple_enough_value_to_commit(ev, op(c, 0));
    }
    return false;
}

ev_new_mv :: (ev: *Evaluator, c: Value_Id) -> s32 {
    array_add(*ev.mvs, .{c = c});
    return cast(s32) (ev.mvs.count - 1);
}
ev_mv_type :: (ev: *Evaluator, mv: s32) -> Type_Id {
    m := ev.mvs[mv];
    if m.agg < 0 return vtype(m.c);
    return ev.aggs[m.agg].ty;
}
ev_mv_to_constant :: (ev: *Evaluator, mv: s32) -> Value_Id {
    m := ev.mvs[mv];
    if m.agg < 0 return m.c;
    a := *ev.aggs[m.agg];
    consts: [..] Value_Id; consts.allocator = temp;
    for a.elems array_add(*consts, ev_mv_to_constant(ev, it));
    tk := type_kind(a.ty);
    if tk == .STRUCT return const_aggregate(.C_STRUCT, a.ty, consts);
    if tk == .ARRAY return const_aggregate(.C_ARRAY, a.ty, consts);
    return const_aggregate(.C_VECTOR, a.ty, consts);
}
// MutableValue::makeMutable
ev_make_mutable :: (ev: *Evaluator, mv: s32) -> bool {
    c := ev.mvs[mv].c;
    ty := vtype(c);
    tk := type_kind(ty);
    n: u64;
    if tk == .VECTOR n = type_count(ty);
    else if tk == .ARRAY n = type_count(ty);
    else if tk == .STRUCT n = type_nsub(ty);
    else return false;
    agg: Ev_Agg;
    agg.ty = ty;
    agg.elems.allocator = temp;
    for i: 0..cast(s64) n - 1 {
        e := cf_elt(c, cast(u64) i);
        if e == NONE fatal("globalopt: Evaluator: aggregate element of a constant expression");
        array_add(*agg.elems, ev_new_mv(ev, e));
    }
    array_add(*ev.aggs, agg);
    ev.mvs[mv].agg = cast(s32) (ev.aggs.count - 1);
    ev.mvs[mv].c = NONE;
    return true;
}
// DataLayout::getGEPIndexForOffset: (ok, index); elem_ty and offset are updated
dl_gep_index_for_offset :: (elem_ty: *Type_Id, offset: *APInt) -> bool, APInt {
    t := elem_ty.*;
    k := type_kind(t);
    if k == .ARRAY {
        elem_ty.* = type_elem(t);
        return true, dl_element_index(dl_type_alloc_size(elem_ty.*), offset);
    }
    if k == .VECTOR || k == .SVECTOR return false, ap_zero(32);
    if k == .STRUCT {
        io := ap_zext_value(offset.*);
        sz, al := dl_struct_layout(t);
        if io >= sz return false, ap_zero(32);
        idx := dl_struct_element_containing_offset(t, io);
        offset.* = ap_sub(offset.*, ap_from_u64(offset.bits, dl_struct_offset(t, idx)));
        elem_ty.* = type_sub(t, idx);
        return true, ap_from_u64(32, idx);
    }
    return false, ap_zero(32);
}
// MutableValue::read
ev_mv_read :: (ev: *Evaluator, mv_in: s32, ty: Type_Id, offset_in: APInt) -> Value_Id {
    offset := offset_in;
    ty_size := dl_type_store_size(ty);
    mv := mv_in;
    while ev.mvs[mv].agg >= 0 {
        a := *ev.aggs[ev.mvs[mv].agg];
        agg_ty := a.ty;
        ok, index := dl_gep_index_for_offset(*agg_ty, *offset);
        if !ok || ap_uge_u64(index, cast(u64) a.elems.count) || ty_size > dl_type_store_size(agg_ty) return NONE;
        mv = a.elems[ap_zext_value(index)];
    }
    return cfo_load_from_const(ev.mvs[mv].c, ty, offset);
}
// MutableValue::write
ev_mv_write :: (ev: *Evaluator, mv_in: s32, v: Value_Id, offset_in: APInt) -> bool {
    offset := offset_in;
    ty := vtype(v);
    ty_size := dl_type_store_size(ty);
    mv := mv_in;
    while !ap_is_zero(offset) || !is_bit_or_noop_pointer_castable(ty, ev_mv_type(ev, mv)) {
        if ev.mvs[mv].agg < 0 && !ev_make_mutable(ev, mv) return false;
        a := *ev.aggs[ev.mvs[mv].agg];
        agg_ty := a.ty;
        ok, index := dl_gep_index_for_offset(*agg_ty, *offset);
        if !ok || ap_uge_u64(index, cast(u64) a.elems.count) || ty_size > dl_type_store_size(agg_ty) return false;
        mv = a.elems[ap_zext_value(index)];
    }
    mv_ty := ev_mv_type(ev, mv);
    ev.mvs[mv].agg = -1;   // clear()
    if is_int_type(ty) && is_ptr_type(mv_ty) ev.mvs[mv].c = ce_cast(.INTTOPTR, v, mv_ty);
    else if is_ptr_type(ty) && is_int_type(mv_ty) ev.mvs[mv].c = ce_cast(.PTRTOINT, v, mv_ty);
    else if ty != mv_ty ev.mvs[mv].c = ce_cast(.BITCAST, v, mv_ty);
    else ev.mvs[mv].c = v;
    return true;
}

// ComputeLoadResult(Constant *P, Type *Ty)
ev_compute_load_result_ptr :: (ev: *Evaluator, p_in: Value_Id, ty: Type_Id) -> Value_Id {
    offset := ap_zero(dl_index_type_size_bits(vtype(p_in)));
    p, off := strip_and_accumulate_constant_offsets(p_in, offset, true);
    off = ap_sext_or_trunc(off, dl_index_type_size_bits(vtype(p)));
    if vkind(p) == .GLOBAL_VAR return ev_compute_load_result(ev, p, ty, off);
    return NONE;
}
// ComputeLoadResult(GlobalVariable *GV, Type *Ty, const APInt &Offset)
ev_compute_load_result :: (ev: *Evaluator, gv: Value_Id, ty: Type_Id, offset: APInt) -> Value_Id {
    found, mv := table_find(*ev.mutated, gv);
    if found return ev_mv_read(ev, mv, ty, offset);
    if !gv_has_definitive_initializer(gv) return NONE;
    return cfo_load_from_const(gv_initializer(gv), ty, offset);
}

// getFunction(Constant *C)
ev_get_function :: (c: Value_Id) -> Value_Id {
    if vkind(c) == .FUNCTION return c;
    if vkind(c) == .ALIAS { a := op(c, 0); if vkind(a) == .FUNCTION return a; }
    return NONE;
}

// getCalleeWithFormalArgs / getFormalParams
ev_get_callee_with_formal_args :: (ev: *Evaluator, cb: Value_Id, formals: *[..] Value_Id) -> Value_Id {
    v := strip_pointer_casts(call_callee(cb));
    f := ev_get_function(ev_get_val(ev, v));
    if f == NONE return NONE;
    if glob(f).value_type != inst(cb).ty2 return NONE;
    n := call_num_args(cb);
    for k: 0..cast(s64) n - 1 array_add(formals, ev_get_val(ev, call_arg(cb, cast(u32) k)));
    return f;
}

// EvaluateBlock: (ok, next block (NONE = returned), stripped pointer casts for alias analysis)
ev_evaluate_block :: (ev: *Evaluator, cur_in: Value_Id, stripped: *bool) -> bool, Value_Id {
    cur := cur_in;
    while true {
        inst_result: Value_Id = NONE;
        o := inst_op(cur);
        if o == .STORE {
            if (inst(cur).flags & F_VOLATILE) != 0 return false, NONE;
            ptr := ev_get_val(ev, op(cur, 1));
            ptr = cfo_constant(ptr);
            off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
            ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
            off = ap_sext_or_trunc(off, dl_index_type_size_bits(vtype(ptr)));
            if vkind(ptr) != .GLOBAL_VAR || !gv_has_unique_initializer(ptr) return false, NONE;
            val := ev_get_val(ev, op(cur, 0));
            if !ev_is_simple_enough_value_to_commit(ev, val) return false, NONE;
            found, mv := table_find(*ev.mutated, ptr);
            if !found {
                mv = ev_new_mv(ev, gv_initializer(ptr));
                table_add(*ev.mutated, ptr, mv);
                array_add(*ev.mutated_order, ptr);
            }
            if !ev_mv_write(ev, mv, val, off) return false, NONE;
        } else if o == .LOAD {
            if (inst(cur).flags & F_VOLATILE) != 0 return false, NONE;
            ptr := ev_get_val(ev, op(cur, 0));
            ptr = cfo_constant(ptr);
            inst_result = ev_compute_load_result_ptr(ev, ptr, vtype(cur));
            if inst_result == NONE return false, NONE;
        } else if o == .ALLOCA {
            if alloca_is_array_allocation(cur) return false, NONE;
            ty := inst(cur).ty2;
            tmp := gv_create_detached(ty, false, .INTERNAL, const_undef(ty), 0, cast(u32) ir.types[vtype(cur)].a);
            array_add(*ev.alloca_tmps, tmp);
            inst_result = tmp;
        } else if o == .CALL || o == .INVOKE {
            cb := cur;
            if vkind(call_callee(cb)) == .INLINE_ASM return false, NONE;
            callee_fn := call_called_function(cb);
            if callee_fn != NONE && glob(callee_fn).intrinsic {
                id := call_iid(cb);
                if is_mem_set_inst(cb) {
                    if mi_is_volatile(cb) return false, NONE;
                    len_c := ev_get_val(ev, call_arg(cb, 2));
                    if vkind(len_c) != .C_INT return false, NONE;
                    ptr := ev_get_val(ev, call_arg(cb, 0));
                    off := ap_zero(dl_index_type_size_bits(vtype(ptr)));
                    ptr, off = strip_and_accumulate_constant_offsets(ptr, off, true);
                    if vkind(ptr) != .GLOBAL_VAR return false, NONE;
                    val := ev_get_val(ev, call_arg(cb, 1));
                    if !is_null_value(val) || table_contains(*ev.mutated, ptr) || !gv_has_definitive_initializer(ptr) || !is_null_value(gv_initializer(ptr)) {
                        len := const_ap(len_c);
                        if ap_ugt_u64(len, 64 * 1024) return false, NONE;
                        while !ap_is_zero(len) {
                            dest := ev_compute_load_result(ev, ptr, vtype(val), off);
                            if dest != val return false, NONE;
                            off = ap_add_u64(off, 1);
                            len = ap_sub_u64(len, 1);
                        }
                    }
                    cur = inst_next(cur);
                    continue;
                }
                if id == IID_LIFETIME_START || id == IID_LIFETIME_END { cur = inst_next(cur); continue; }
                if id == IID_INVARIANT_START {
                    if has_uses(cb) return false, NONE;
                    size := call_arg(cb, 0);
                    p := strip_pointer_casts(ev_get_val(ev, call_arg(cb, 1)));
                    if vkind(p) == .GLOBAL_VAR {
                        min_size := dl_type_alloc_size(glob(p).value_type);
                        if !ap_is_all_ones(const_ap(size)) {
                            sv := const_ap(size);
                            lim := ifx ap_active_bits(sv) > 64 then 0xFFFF_FFFF_FFFF_FFFF else ap_zext_value(sv);
                            if lim >= min_size gdce_set_insert(*ev.invariants, p);
                        }
                    }
                    cur = inst_next(cur);
                    continue;
                } else if id == IID_ASSUME || id == IID_SIDEEFFECT || id == IID_PSEUDOPROBE {
                    cur = inst_next(cur);
                    continue;
                } else {
                    s := strip_pointer_casts_for_alias_analysis(cur);
                    if s != cur inst_result = ev_get_val(ev, s);
                    if inst_result != NONE {
                        stripped.* = true;
                        inst_result = ce_cast(.BITCAST, inst_result, vtype(cur));
                    } else return false, NONE;
                }
            }
            if inst_result == NONE {
                formals: [..] Value_Id; formals.allocator = temp;
                callee := ev_get_callee_with_formal_args(ev, cb, *formals);
                if callee == NONE || gv_is_interposable(callee) return false, NONE;
                if is_declaration(callee) {
                    c := cfo_call(cb, callee, formals);
                    if c == NONE return false, NONE;
                    inst_result = c;
                } else {
                    if func_vararg(glob(callee).value_type) return false, NONE;
                    ev_push_frame(ev);
                    ok, ret := ev_evaluate_function(ev, callee, formals);
                    if !ok return false, NONE;
                    pop(*ev.value_stack);
                    inst_result = ret;
                }
            }
        } else if is_terminator(o) {
            next: Value_Id = NONE;
            if o == .BR next = get_successor(cur, 0);
            else if o == .CONDBR {
                c := ev_get_val(ev, op(cur, 0));
                if vkind(c) != .C_INT return false, NONE;
                next = get_successor(cur, ifx const_int_zext(c) != 0 then cast(u32) 0 else 1);
            } else if o == .SWITCH {
                v := ev_get_val(ev, op(cur, 0));
                if vkind(v) != .C_INT return false, NONE;
                next = switch_find_case_dest(cur, v);
            } else if o == .INDIRECTBR {
                v := strip_pointer_casts(ev_get_val(ev, op(cur, 0)));
                if vkind(v) != .C_BLOCKADDR return false, NONE;
                next = op(v, 1);   // BlockAddress::getBasicBlock
            } else if o == .RET {
                next = NONE;
            } else return false, NONE;
            return true, next;
        } else {
            ops: [..] Value_Id; ops.allocator = temp;
            for k: 0..cast(s64) nops(cur) - 1 array_add(*ops, ev_get_val(ev, op(cur, cast(u32) k)));
            inst_result = cfo_inst_operands(cur, ops);
            if inst_result == NONE return false, NONE;
        }
        if has_uses(cur) {
            inst_result = cfo_constant(inst_result);
            ev_set_val(ev, cur, inst_result);
        }
        if o == .INVOKE return true, get_successor(cur, 0);
        cur = inst_next(cur);
    }
    return false, NONE;
}

// EvaluateFunction: (ok, return value or NONE)
ev_evaluate_function :: (ev: *Evaluator, f: Value_Id, actual_args: [] Value_Id) -> bool, Value_Id {
    for ev.call_stack if it == f return false, NONE;
    array_add(*ev.call_stack, f);
    for k: 0..cast(s64) glob(f).nargs - 1 ev_set_val(ev, fn_arg(f, cast(u32) k), actual_args[k]);
    executed: Table(Value_Id, bool); executed.allocator = temp;
    cur_bb := fn_entry(f);
    cur := block_first(cur_bb);
    while true {
        stripped := false;
        ok, next := ev_evaluate_block(ev, cur, *stripped);
        if !ok return false, NONE;
        if next == NONE {
            ri := block_terminator(cur_bb);
            ret: Value_Id = NONE;
            if nops(ri) {
                if stripped && type_kind(vtype(op(ri, 0))) != .VOID return false, NONE;
                ret = ev_get_val(ev, op(ri, 0));
            }
            pop(*ev.call_stack);
            return true, ret;
        }
        if table_contains(*executed, next) return false, NONE;
        table_add(*executed, next, true);
        cur = block_first(next);
        while cur != NONE && inst_op(cur) == .PHI {
            ev_set_val(ev, cur, ev_get_val(ev, phi_incoming_value_for_block(cur, cur_bb)));
            cur = inst_next(cur);
        }
        cur_bb = next;
    }
    return false, NONE;
}

