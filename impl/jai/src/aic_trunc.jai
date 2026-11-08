// TruncInstCombine: port of llvm/lib/Transforms/AggressiveInstCombine/TruncInstCombine.cpp (and the class in
// AggressiveInstCombineInternal.h). InstInfoMap (a MapVector) is `Tic.keys` / `Tic.infos` in insertion order with
// an index table; erased entries keep their slot with `dead` set, so iteration order stays LLVM's.

Tic_Info :: struct { valid_bit_width: u32; min_bit_width: u32; new_value: Value_Id = NONE; dead: bool; }

Tic :: struct {
    f: Value_Id;
    ac: *Assumption_Cache;
    dt: *Dom_Tree;
    worklist: [..] Value_Id;          // TruncInsts
    current: Value_Id = NONE;         // CurrentTruncInst
    keys: [..] Value_Id;
    infos: [..] Tic_Info;
    index: Table(Value_Id, s64);
}

tic_map_clear :: (t: *Tic) { t.keys.count = 0; t.infos.count = 0; table_reset(*t.index); }
tic_map_count :: (t: *Tic, i: Value_Id) -> bool {
    p := table_find_pointer(*t.index, i);
    return p != null && !t.infos[p.*].dead;
}
// InstInfoMap[I] (inserts a default entry)
tic_map_get :: (t: *Tic, i: Value_Id) -> s64 {
    p := table_find_pointer(*t.index, i);
    if p && !t.infos[p.*].dead return p.*;
    array_add(*t.keys, i);
    array_add(*t.infos, .{});
    table_set(*t.index, i, t.keys.count - 1);
    return t.keys.count - 1;
}
// InstInfoMap.lookup(I) (default if absent)
tic_map_lookup :: (t: *Tic, i: Value_Id) -> Tic_Info {
    p := table_find_pointer(*t.index, i);
    if p && !t.infos[p.*].dead return t.infos[p.*];
    return .{};
}
tic_map_erase :: (t: *Tic, i: Value_Id) {
    p := table_find_pointer(*t.index, i);
    if !p return;
    t.infos[p.*].dead = true;
    table_remove(*t.index, i);
}

tic_known_bits :: (t: *Tic, v: Value_Id) -> Known_Bits { return known_bits_ctx(v, t.current, t.dt, t.ac); }
tic_num_sign_bits :: (t: *Tic, v: Value_Id) -> u32 { return num_sign_bits_ctx(v, t.current, t.dt, t.ac); }

// getRelevantOperands
tic_relevant_operands :: (i: Value_Id, ops: *[..] Value_Id) {
    o := inst_op(i);
    if o == {
        case .TRUNC; #through; case .ZEXT; #through; case .SEXT;
        case .ADD; #through; case .SUB; #through; case .MUL; #through; case .AND; #through; case .OR; #through;
        case .XOR; #through; case .SHL; #through; case .LSHR; #through; case .ASHR; #through; case .UDIV; #through;
        case .UREM; #through; case .INSERTELEMENT;
            array_add(ops, op(i, 0)); array_add(ops, op(i, 1));
        case .EXTRACTELEMENT;
            array_add(ops, op(i, 0));
        case .SELECT;
            array_add(ops, op(i, 1)); array_add(ops, op(i, 2));
        case .PHI;
            for k: 0..cast(s64) nops(i) - 1 array_add(ops, op(i, cast(u32) k));
        case;
            fatal("internal: TruncInstCombine getRelevantOperands on an unexpected instruction");
    }
}

tic_is_graph_op :: (o: Opcode) -> bool {
    return o == .ADD || o == .SUB || o == .MUL || o == .AND || o == .OR || o == .XOR || o == .SHL || o == .LSHR ||
           o == .ASHR || o == .UDIV || o == .UREM || o == .INSERTELEMENT || o == .EXTRACTELEMENT || o == .SELECT;
}

// buildTruncExpressionGraph
tic_build_graph :: (t: *Tic) -> bool {
    wl: [..] Value_Id; wl.allocator = temp;
    stack: [..] Value_Id; stack.allocator = temp;
    tic_map_clear(t);
    array_add(*wl, op(t.current, 0));
    while wl.count {
        curr := wl[wl.count - 1];
        if is_constant_kind(vkind(curr)) { wl.count -= 1; continue; }
        if !is_inst(curr) return false;
        i := curr;
        if stack.count && stack[stack.count - 1] == i {
            wl.count -= 1;
            stack.count -= 1;
            tic_map_get(t, i);
            continue;
        }
        if tic_map_count(t, i) { wl.count -= 1; continue; }
        array_add(*stack, i);
        o := inst_op(i);
        if o == .TRUNC || o == .ZEXT || o == .SEXT {
        } else if tic_is_graph_op(o) {
            ops: [..] Value_Id; ops.allocator = temp;
            tic_relevant_operands(i, *ops);
            for ops array_add(*wl, it);
        } else if o == .PHI {
            ops: [..] Value_Id; ops.allocator = temp;
            tic_relevant_operands(i, *ops);
            for x: ops {
                on_stack := false;
                for stack if it == x { on_stack = true; break; }
                if !on_stack array_add(*wl, x);
            }
        } else {
            return false;
        }
    }
    return true;
}

// DataLayout::getSmallestLegalIntType: 0 = none
dl_smallest_legal_int_width :: (width: u32) -> u32 {
    for dl.legal_ints if width <= it return it;
    return 0;
}

// getMinBitWidth
tic_min_bit_width :: (t: *Tic) -> u32 {
    wl: [..] Value_Id; wl.allocator = temp;
    stack: [..] Value_Id; stack.allocator = temp;
    src := op(t.current, 0);
    dst_ty := vtype(t.current);
    trunc_bw := type_bits(scalar_type(dst_ty));
    orig_bw := type_bits(scalar_type(vtype(src)));
    if is_constant_kind(vkind(src)) return trunc_bw;
    array_add(*wl, src);
    t.infos[tic_map_get(t, src)].valid_bit_width = trunc_bw;
    while wl.count {
        curr := wl[wl.count - 1];
        if is_constant_kind(vkind(curr)) { wl.count -= 1; continue; }
        i := curr;
        info_idx := tic_map_get(t, i);
        ops: [..] Value_Id; ops.allocator = temp;
        tic_relevant_operands(i, *ops);
        if stack.count && stack[stack.count - 1] == i {
            wl.count -= 1;
            stack.count -= 1;
            for x: ops if is_inst(x) {
                xi := tic_map_get(t, x);
                t.infos[info_idx].min_bit_width = max(t.infos[info_idx].min_bit_width, t.infos[xi].min_bit_width);
            }
            continue;
        }
        array_add(*stack, i);
        valid := t.infos[info_idx].valid_bit_width;
        t.infos[info_idx].min_bit_width = max(t.infos[info_idx].min_bit_width, t.infos[info_idx].valid_bit_width);
        for x: ops if is_inst(x) {
            if tic_map_lookup(t, x).valid_bit_width >= valid continue;
            t.infos[tic_map_get(t, x)].valid_bit_width = valid;
            array_add(*wl, x);
        }
    }
    min_bw := tic_map_lookup(t, src).min_bit_width;
    assert(min_bw >= trunc_bw);
    if min_bw > trunc_bw {
        if is_vector_type(dst_ty) return orig_bw;
        w := dl_smallest_legal_int_width(min_bw);
        min_bw = ifx w != 0 then w else orig_bw;
    } else {
        from_legal := min_bw == 1 || dl_is_legal_integer(orig_bw);
        to_legal := min_bw == 1 || dl_is_legal_integer(min_bw);
        if !is_vector_type(dst_ty) && from_legal && !to_legal return orig_bw;
    }
    return min_bw;
}

// getBestTruncatedType: 0 = none (the result is an integer bit width)
tic_best_truncated_width :: (t: *Tic) -> u32 {
    if !tic_build_graph(t) return 0;
    desired: u32 = 0;
    for i, k: t.keys {
        if t.infos[k].dead continue;
        if value_has_one_use(i) continue;
        is_ext := inst_op(i) == .ZEXT || inst_op(i) == .SEXT;
        u := ir.v_first_use[i];
        while u != NONE {
            defer u = ir.u_next[u];
            ui := ir.u_user[u];
            if !is_inst(ui) continue;
            if ui != t.current && !tic_map_count(t, ui) {
                if !is_ext return 0;
                ext_bw := type_bits(scalar_type(vtype(op(i, 0))));
                if desired && desired != ext_bw return 0;
                desired = ext_bw;
            }
        }
    }
    orig_bw := type_bits(scalar_type(vtype(op(t.current, 0))));
    for i, k: t.keys {
        if t.infos[k].dead continue;
        o := inst_op(i);
        if o == .SHL || o == .LSHR || o == .ASHR {
            known_rhs := tic_known_bits(t, op(i, 1));
            mbw := cast(u32) ap_limited(ap_uadd_sat(kb_max_value(known_rhs), ap_from_u64(orig_bw, 1)), orig_bw);
            if mbw == orig_bw return 0;
            if o == .LSHR {
                known_lhs := tic_known_bits(t, op(i, 0));
                mbw = max(mbw, ap_active_bits(kb_max_value(known_lhs)));
            }
            if o == .ASHR {
                nsb := tic_num_sign_bits(t, op(i, 0));
                mbw = max(mbw, orig_bw - nsb + 1);
            }
            if mbw >= orig_bw return 0;
            t.infos[k].min_bit_width = mbw;
        }
        if o == .UDIV || o == .UREM {
            mbw: u32 = 0;
            for j: 0..cast(s64) nops(i) - 1 {
                known := tic_known_bits(t, op(i, cast(u32) j));
                mbw = max(ap_active_bits(kb_max_value(known)), mbw);
                if mbw >= orig_bw return 0;
            }
            t.infos[k].min_bit_width = mbw;
        }
    }
    min_bw := tic_min_bit_width(t);
    if min_bw >= orig_bw || (desired && desired != min_bw) return 0;
    return min_bw;
}

// getReducedType
tic_reduced_type :: (v: Value_Id, bits: u32) -> Type_Id {
    st := type_int(bits);
    vt := vtype(v);
    if is_vector_type(vt) return type_vector(type_count(vt), st, type_kind(vt) == .SVECTOR);
    return st;
}

// getReducedOperand
tic_reduced_operand :: (t: *Tic, v: Value_Id, bits: u32) -> Value_Id {
    ty := tic_reduced_type(v, bits);
    if is_constant_kind(vkind(v)) {
        c := ce_cast(.TRUNC, v, ty);
        return cfo_constant(c);
    }
    e := tic_map_lookup(t, v);
    assert(e.new_value != NONE);
    return e.new_value;
}

// IRBuilder::CreateExtractElement(Vec, Idx) / CreateInsertElement(Vec, NewElt, Idx) with a Value index
tic_extract_element :: (b: *Irb, v: Value_Id, idx: Value_Id) -> Value_Id {
    if irb_is_const(v) && irb_is_const(idx) { x := cf_extract_element(v, idx); if x != NONE return x; }
    i := new_inst(.EXTRACTELEMENT, type_elem(vtype(v)), 2);
    set_op(i, 0, v); set_op(i, 1, idx);
    return irb_insert(b, i);
}
tic_insert_element :: (b: *Irb, v: Value_Id, e: Value_Id, idx: Value_Id) -> Value_Id {
    if irb_is_const(v) && irb_is_const(e) && irb_is_const(idx) { x := cf_insert_element(v, e, idx); if x != NONE return x; }
    i := new_inst(.INSERTELEMENT, vtype(v), 3);
    set_op(i, 0, v); set_op(i, 1, e); set_op(i, 2, idx);
    return irb_insert(b, i);
}

// ReduceExpressionGraph
tic_reduce_graph :: (t: *Tic, bits: u32) {
    Phi_Pair :: struct { old: Value_Id; new: Value_Id; }
    phis: [..] Phi_Pair; phis.allocator = temp;
    for k: 0..t.keys.count - 1 {
        if t.infos[k].dead continue;
        i := t.keys[k];
        assert(t.infos[k].new_value == NONE);
        b: Irb;
        irb_set_before(*b, i);
        res: Value_Id = NONE;
        o := inst_op(i);
        if o == .TRUNC || o == .ZEXT || o == .SEXT {
            ty := tic_reduced_type(i, bits);
            if vtype(op(i, 0)) == ty {
                assert(o != .TRUNC);
                t.infos[k].new_value = op(i, 0);
                continue;
            }
            res = irb_int_cast(*b, op(i, 0), ty, o == .SEXT);
            entry := -1;
            for t.worklist if it == i { entry = it_index; break; }
            new_is_trunc := is_inst(res) && inst_op(res) == .TRUNC;
            if entry >= 0 {
                if new_is_trunc t.worklist[entry] = res;
                else array_ordered_remove_by_index(*t.worklist, entry);
            } else if new_is_trunc array_add(*t.worklist, res);
        } else if o == .ADD || o == .SUB || o == .MUL || o == .AND || o == .OR || o == .XOR || o == .SHL ||
                  o == .LSHR || o == .ASHR || o == .UDIV || o == .UREM {
            lhs := tic_reduced_operand(t, op(i, 0), bits);
            rhs := tic_reduced_operand(t, op(i, 1), bits);
            res = irb_binop(*b, o, lhs, rhs);
            if (o == .UDIV || o == .LSHR || o == .ASHR) && is_inst(res) {
                if (inst(i).flags & F_EXACT) != 0 inst(res).flags |= F_EXACT;
                else inst(res).flags &= ~cast(u32) F_EXACT;
            }
        } else if o == .EXTRACTELEMENT {
            vec := tic_reduced_operand(t, op(i, 0), bits);
            res = tic_extract_element(*b, vec, op(i, 1));
        } else if o == .INSERTELEMENT {
            vec := tic_reduced_operand(t, op(i, 0), bits);
            elt := tic_reduced_operand(t, op(i, 1), bits);
            res = tic_insert_element(*b, vec, elt, op(i, 2));
        } else if o == .SELECT {
            lhs := tic_reduced_operand(t, op(i, 1), bits);
            rhs := tic_reduced_operand(t, op(i, 2), bits);
            res = irb_select(*b, op(i, 0), lhs, rhs, "", i);
        } else if o == .PHI {
            res = irb_phi(*b, tic_reduced_type(i, bits), nops(i));
            array_add(*phis, .{i, res});
        } else {
            fatal("internal: TruncInstCombine: unhandled instruction");
        }
        t.infos[k].new_value = res;
        if is_inst(res) ic_take_name(res, i);
    }

    for phis {
        for j: 0..cast(s64) nops(it.old) - 1 {
            phi_add_incoming(it.new, tic_reduced_operand(t, op(it.old, cast(u32) j), bits), phi_block(it.old, cast(u32) j));
        }
    }

    res := tic_reduced_operand(t, op(t.current, 0), bits);
    dst_ty := vtype(t.current);
    if vtype(res) != dst_ty {
        b: Irb;
        irb_set_before(*b, t.current);
        res = irb_int_cast(*b, res, dst_ty, false);
        if is_inst(res) ic_take_name(res, t.current);
    }
    rauw_with_metadata(t.current, res);
    erase_inst_with_metadata(t.current);
    for phis {
        rauw_with_metadata(it.old, const_poison(vtype(it.old)));
        tic_map_erase(t, it.old);
        erase_inst_with_metadata(it.old);
    }
    for < k: 0..t.keys.count - 1 {
        if t.infos[k].dead continue;
        i := t.keys[k];
        if !has_uses(i) erase_inst_with_metadata(i);
        else assert(inst_op(i) == .SEXT || inst_op(i) == .ZEXT);
    }
}

// TruncInstCombine::run
tic_run :: (f: Value_Id, ac: *Assumption_Cache, dt: *Dom_Tree) -> bool {
    t: Tic;
    t.f = f; t.ac = ac; t.dt = dt;
    t.worklist.allocator = temp; t.keys.allocator = temp; t.infos.allocator = temp; t.index.allocator = temp;
    changed := false;
    for bb: fn_blocks(f) {
        if !dt_is_reachable_from_entry(dt, bb) continue;
        for i: block_insts(bb) if inst_op(i) == .TRUNC array_add(*t.worklist, i);
    }
    while t.worklist.count {
        t.current = pop(*t.worklist);
        w := tic_best_truncated_width(*t);
        if w != 0 {
            tic_reduce_graph(*t, w);
            changed = true;
        }
    }
    return changed;
}
