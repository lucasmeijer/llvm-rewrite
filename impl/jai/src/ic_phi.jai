// InstCombine for phi nodes: a port of llvm/lib/Transforms/InstCombine/InstCombinePHI.cpp (visitPHINode and every
// helper of that file), in LLVM's order.

IC_MAX_NUM_PHIS :: 512;   // -instcombine-max-num-phis

// PHINode::Create(Ty, N, Name) (unlinked)
ic_create_phi_named :: (ty: Type_Id, n: u32, name: string) -> Value_Id {
    p := create_phi(ty, n);
    if name.count set_name(p, name);
    return p;
}

// PHIArgMergedDebugLoc
ic_phi_arg_merged_debug_loc :: (i: Value_Id, pn: Value_Id) {
    first := phi_value(pn, 0);
    loc := get_metadata(first, 0);
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        loc = merged_location(loc, get_metadata(phi_value(pn, k), 0));
    }
    set_metadata(i, 0, loc);
}

// foldDeadPhiWeb
ic_fold_dead_phi_web :: (pn: Value_Id) -> bool {
    stack: [..] Value_Id; stack.allocator = temp;
    visited: [..] Value_Id; visited.allocator = temp;
    array_add(*stack, pn);
    array_add(*visited, pn);
    while stack.count {
        phi := pop(*stack);
        u := ir.v_first_use[phi];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if is_phi(us) {
                seen := false;
                for visited if it == us { seen = true; break; }
                if seen continue;
                array_add(*visited, us);
                if visited.count >= 16 return false;
                array_add(*stack, us);
            } else return false;
        }
    }
    for visited ic_replace_inst_uses_with(it, const_poison(vtype(it)));
    for visited ic_erase_inst(it);
    return true;
}

// CastInst::CreateBitOrPointerCast (unlinked)
ic_create_bit_or_pointer_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    st := scalar_type(vtype(v)); dt := scalar_type(t);
    if is_ptr_type(st) && is_int_type(dt) return create_cast(.PTRTOINT, v, t);
    if is_int_type(st) && is_ptr_type(dt) return create_cast(.INTTOPTR, v, t);
    return create_cast(.BITCAST, v, t);
}
// CastInst::CreatePointerCast (unlinked)
ic_create_pointer_cast :: (v: Value_Id, t: Type_Id) -> Value_Id {
    if is_int_type(scalar_type(t)) return create_cast(.PTRTOINT, v, t);
    if type_addrspace(scalar_type(vtype(v))) != type_addrspace(scalar_type(t)) return create_cast(.ADDRSPACECAST, v, t);
    return create_cast(.BITCAST, v, t);
}

// foldIntegerTypedPHI
ic_fold_integer_typed_phi :: (pn: Value_Id) -> bool {
    if !is_int_type(vtype(pn)) return false;
    if !has_one_use(pn) return false;
    itp := first_user(pn);
    if !is_inst(itp) || inst_op(itp) != .INTTOPTR return false;
    has_pointer_use :: (iip: Value_Id) -> bool {
        u := ir.v_first_use[iip];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            ptr: Value_Id = NONE;
            if inst_op(us) == .LOAD ptr = op(us, 0);
            else if inst_op(us) == .STORE ptr = op(us, 1);
            else if inst_op(us) == .GEP ptr = op(us, 0);
            if ptr != NONE && ptr == iip return true;
        }
        return false;
    }
    if !has_pointer_use(itp) return false;
    if cast(u64) dl_ptr_spec(type_addrspace(vtype(itp))).bits != dl_type_size_bits(vtype(op(itp, 0))) return false;
    n := phi_num_incoming(pn);
    avail: [..] Value_Id; avail.allocator = temp;
    for k: 0..n - 1 {
        bb := phi_block(pn, k);
        arg := phi_value(pn, k);
        if !is_inst(arg) && !is_argument(arg) return false;
        if is_inst(arg) && inst_op(arg) == .PTRTOINT && vtype(op(arg, 0)) == vtype(itp) { array_add(*avail, op(arg, 0)); continue; }
        arg_itp: Value_Id = NONE;
        u := ir.v_first_use[arg];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if is_inst(us) && inst_op(us) == .INTTOPTR && vtype(us) == vtype(itp) &&
               (dt_dominates_inst_block(ic.dt, us, bb) || inst_block(us) == bb) { arg_itp = us; break; }
        }
        if arg_itp != NONE { array_add(*avail, arg_itp); continue; }
        if is_phi(arg) { array_add(*avail, arg); continue; }
        if !is_inst(arg) || inst_op(arg) != .LOAD return false;
        if !has_one_use(arg) return false;
        array_add(*avail, arg);
    }
    bb := inst_block(pn);
    matching: Value_Id = NONE;
    num_phis := 0;
    for p: block_insts(bb) {
        if inst_op(p) != .PHI break;
        num_phis += 1;
        if num_phis - 1 > IC_MAX_NUM_PHIS return false;
        if p == pn || vtype(p) != vtype(itp) continue;
        mismatch := false;
        for k: 0..n - 1 if phi_incoming_for_block(p, phi_block(pn, k)) != avail[k] { mismatch = true; break; }
        if mismatch continue;
        matching = p;
        break;
    }
    if matching != NONE {
        ic_replace_inst_uses_with(itp, matching);
        ic_erase_inst(itp);
        ic_erase_inst(pn);
        return true;
    }
    all_need := true;
    for avail if vtype(it) == vtype(itp) && !(is_inst(it) && inst_op(it) == .INTTOPTR) { all_need = false; break; }
    if all_need return false;
    for v: avail {
        if vtype(v) == vtype(itp) continue;
        if !is_inst(v) continue;
        if is_terminator(inst_op(v)) return false;
        if is_phi(v) && !block_has_insertion_pt(inst_block(v)) return false;
    }
    np := ic_create_phi_named(vtype(itp), n, tprint("%.ptr", vname(pn)));
    ic_insert_new_inst_before(np, pn);
    casts: [..] Value_Id; casts.allocator = temp;   // pairs (incoming value, cast)
    for k: 0..n - 1 {
        ibb := phi_block(pn, k);
        iv := avail[k];
        if vtype(iv) == vtype(itp) { phi_add_incoming(np, iv, ibb); continue; }
        ci: Value_Id = NONE;
        j := 0;
        while j < casts.count { if casts[j] == iv { ci = casts[j + 1]; break; } j += 2; }
        if ci == NONE {
            ci = ic_create_bit_or_pointer_cast(iv, vtype(itp));
            set_name(ci, tprint("%.ptr", vname(iv)));
            if is_inst(iv) {
                pos := inst(iv).next;
                if is_phi(iv) pos = block_first_insertion_pt(inst_block(iv));
                ic_insert_new_inst_before(ci, pos);
            } else {
                entry := fn_entry(inst_fn(pn));
                ic_insert_new_inst_before(ci, block_first_insertion_pt(entry));
            }
            array_add(*casts, iv); array_add(*casts, ci);
        }
        phi_add_incoming(np, ci, ibb);
    }
    ic_replace_inst_uses_with(itp, np);
    ic_erase_inst(itp);
    ic_erase_inst(pn);
    return true;
}

// foldPHIArgIntToPtrToPHI
ic_fold_phi_arg_int_to_ptr_to_phi :: (pn: Value_Id) -> Value_Id {
    u := ir.v_first_use[pn];
    while u != NONE { us := ir.u_user[u]; if !is_inst(us) || inst_op(us) != .PTRTOINT return NONE; u = ir.u_next[u]; }
    changed := false;
    for k: 0..phi_num_incoming(pn) - 1 {
        nop := ic_simplify_int_to_ptr_round_trip_cast(phi_value(pn, k));
        if nop != NONE { ic_replace_operand(pn, k, nop); changed = true; }
    }
    if !changed return NONE;
    return pn;
}

indices_equal :: (a: [] u32, b: [] u32) -> bool {
    if a.count != b.count return false;
    for a if it != b[it_index] return false;
    return true;
}

// foldPHIArgInsertValueInstructionIntoPHI
ic_fold_phi_arg_insert_value_into_phi :: (pn: Value_Id) -> Value_Id {
    first := phi_value(pn, 0);
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        i := phi_value(pn, k);
        if !is_inst(i) || inst_op(i) != .INSERTVALUE || !has_one_user(i) || !indices_equal(inst_indices(i), inst_indices(first)) return NONE;
    }
    new_ops: [2] Value_Id;
    for opi: 0..1 {
        o := op(first, cast(u32) opi);
        np := ic_create_phi_named(vtype(o), n, tprint("%.pn", vname(o)));
        for k: 0..n - 1 phi_add_incoming(np, op(phi_value(pn, k), cast(u32) opi), phi_block(pn, k));
        ic_insert_new_inst_before(np, pn);
        new_ops[opi] = np;
    }
    idxs := inst_indices(first);
    nv := new_inst(.INSERTVALUE, vtype(new_ops[0]), 2);
    set_op(nv, 0, new_ops[0]); set_op(nv, 1, new_ops[1]);
    r := inst(nv);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idxs.count;
    copy := NewArray(idxs.count, u32,, allocator = temp);
    for idxs copy[it_index] = it;
    for copy array_add(*ir.u32_pool, it);
    set_name(nv, vname(pn));
    ic_phi_arg_merged_debug_loc(nv, pn);
    return nv;
}

// foldPHIArgExtractValueInstructionIntoPHI
ic_fold_phi_arg_extract_value_into_phi :: (pn: Value_Id) -> Value_Id {
    first := phi_value(pn, 0);
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        i := phi_value(pn, k);
        if !is_inst(i) || inst_op(i) != .EXTRACTVALUE || !has_one_user(i) || !indices_equal(inst_indices(i), inst_indices(first)) ||
           vtype(op(i, 0)) != vtype(op(first, 0)) return NONE;
    }
    agg := op(first, 0);
    np := ic_create_phi_named(vtype(agg), n, tprint("%.pn", vname(agg)));
    for k: 0..n - 1 phi_add_incoming(np, op(phi_value(pn, k), 0), phi_block(pn, k));
    ic_insert_new_inst_before(np, pn);
    idxs := inst_indices(first);
    copy := NewArray(idxs.count, u32,, allocator = temp);
    for idxs copy[it_index] = it;
    ne := create_extract_value(np, copy);
    set_name(ne, vname(pn));
    ic_phi_arg_merged_debug_loc(ne, pn);
    return ne;
}

// foldPHIArgBinOpIntoPHI
ic_fold_phi_arg_binop_into_phi :: (pn: Value_Id) -> Value_Id {
    first := phi_value(pn, 0);
    opc := inst_op(first);
    lhs_val := op(first, 0); rhs_val := op(first, 1);
    lt := vtype(lhs_val); rt := vtype(rhs_val);
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        i := phi_value(pn, k);
        if !is_inst(i) || inst_op(i) != opc || !has_one_user(i) || vtype(op(i, 0)) != lt || vtype(op(i, 1)) != rt return NONE;
        if is_cmp_inst(i) && inst_pred(i) != inst_pred(first) return NONE;
        if op(i, 0) != lhs_val lhs_val = NONE;
        if op(i, 1) != rhs_val rhs_val = NONE;
    }
    if lhs_val == NONE && rhs_val == NONE return NONE;
    in_lhs := op(first, 0); in_rhs := op(first, 1);
    new_lhs, new_rhs: Value_Id = NONE, NONE;
    if lhs_val == NONE {
        new_lhs = ic_create_phi_named(lt, n, tprint("%.pn", vname(op(first, 0))));
        phi_add_incoming(new_lhs, in_lhs, phi_block(pn, 0));
        ic_insert_new_inst_before(new_lhs, pn);
        lhs_val = new_lhs;
    }
    if rhs_val == NONE {
        new_rhs = ic_create_phi_named(rt, n, tprint("%.pn", vname(op(first, 1))));
        phi_add_incoming(new_rhs, in_rhs, phi_block(pn, 0));
        ic_insert_new_inst_before(new_rhs, pn);
        rhs_val = new_rhs;
    }
    if new_lhs != NONE || new_rhs != NONE {
        for k: 1..n - 1 {
            if n < 2 break;
            ibb := phi_block(pn, k);
            iv := phi_value(pn, k);
            if new_lhs != NONE phi_add_incoming(new_lhs, op(iv, 0), ibb);
            if new_rhs != NONE phi_add_incoming(new_rhs, op(iv, 1), ibb);
        }
    }
    if is_cmp_inst(first) {
        nc: Value_Id;
        if opc == .ICMP nc = create_icmp(inst_pred(first), lhs_val, rhs_val);
        else nc = create_fcmp(inst_pred(first), lhs_val, rhs_val);
        ic_phi_arg_merged_debug_loc(nc, pn);
        return nc;
    }
    nb := create_binop(opc, lhs_val, rhs_val);
    copy_ir_flags(nb, phi_value(pn, 0));
    for k: 1..n - 1 { if n < 2 break; and_ir_flags(nb, phi_value(pn, k)); }
    ic_phi_arg_merged_debug_loc(nb, pn);
    return nb;
}

// foldPHIArgGEPIntoPHI
ic_fold_phi_arg_gep_into_phi :: (pn: Value_Id) -> Value_Id {
    first := phi_value(pn, 0);
    nfo := nops(first);
    fixed := NewArray(cast(s64) nfo, Value_Id,, allocator = temp);
    for k: 0..nfo - 1 fixed[k] = op(first, k);
    all_allocas := true;
    needed_phi := false;
    nw_norm :: (g: Value_Id) -> u32 {
        f := inst(g).flags & cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        if f & F_INBOUNDS f |= F_NUSW;
        return f;
    }
    nw := nw_norm(first);
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        g := phi_value(pn, k);
        if !is_inst(g) || inst_op(g) != .GEP || !has_one_user(g) || inst(g).ty2 != inst(first).ty2 || nops(g) != nfo return NONE;
        nw &= nw_norm(g);
        if all_allocas && (!(is_inst(op(g, 0)) && inst_op(op(g, 0)) == .ALLOCA) || !gep_has_all_constant_indices(g)) all_allocas = false;
        for o: 0..nfo - 1 {
            if op(first, o) == op(g, o) continue;
            if is_const(op(first, o)) || is_const(op(g, o)) return NONE;
            if vtype(op(first, o)) != vtype(op(g, o)) return NONE;
            if needed_phi return NONE;
            fixed[o] = NONE;
            needed_phi = true;
        }
    }
    if all_allocas return NONE;
    operand_phis := NewArray(cast(s64) nfo, Value_Id,, allocator = temp);
    for * operand_phis it.* = NONE;
    has_any := false;
    for k: 0..nfo - 1 {
        if fixed[k] != NONE continue;
        fo := op(first, k);
        np := ic_create_phi_named(vtype(fo), nfo, tprint("%.pn", vname(fo)));
        ic_insert_new_inst_before(np, pn);
        phi_add_incoming(np, fo, phi_block(pn, 0));
        operand_phis[k] = np;
        fixed[k] = np;
        has_any = true;
    }
    if has_any {
        for k: 1..n - 1 {
            if n < 2 break;
            g := phi_value(pn, k);
            for o: 0..nfo - 1 if operand_phis[o] != NONE phi_add_incoming(operand_phis[o], op(g, o), phi_block(pn, k));
        }
    }
    if nw & F_INBOUNDS nw &= ~cast(u32) F_NUSW;
    idxs: [..] Value_Id; idxs.allocator = temp;
    for k: 1..nfo - 1 array_add(*idxs, fixed[k]);
    g := new_inst(.GEP, irb_gep_result_type(fixed[0], idxs), nfo);
    inst(g).flags = nw; inst(g).ty2 = inst(first).ty2;
    for k: 0..nfo - 1 set_op(g, k, fixed[k]);
    ic_phi_arg_merged_debug_loc(g, pn);
    return g;
}

// isSafeAndProfitableToSinkLoad
ic_is_safe_and_profitable_to_sink_load :: (l: Value_Id) -> bool {
    i := inst(l).next;
    while i != NONE {
        if may_write_to_memory(i) {
            if !(is_call_base(i) && me_without_loc(call_memory_effects(i), LOC_INACCESSIBLE) == 0) return false;
        }
        i = inst(i).next;
    }
    p := op(l, 0);
    if is_inst(p) && inst_op(p) == .ALLOCA {
        taken := false;
        u := ir.v_first_use[p];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            if inst_op(us) == .LOAD continue;
            if inst_op(us) == .STORE && op(us, 1) == p continue;
            taken = true;
            break;
        }
        if !taken && is_static_alloca(p) return false;
    }
    if is_inst(p) && inst_op(p) == .GEP {
        a := op(p, 0);
        if is_inst(a) && inst_op(a) == .ALLOCA && is_static_alloca(a) && gep_has_all_constant_indices(p) return false;
    }
    return true;
}

// canReplaceOperandWithVariable(LoadInst, 0) (Transforms/Utils/Local.cpp)
ic_can_replace_load_pointer_with_variable :: (li: Value_Id) -> bool {
    p := op(li, 0);
    if is_argument(p) && attr_set_has(arg_attrs(p), .SwiftError) return false;
    if is_inst(p) && inst_op(p) == .ALLOCA && (inst(p).flags & F_SWIFTERR) != 0 return false;
    return true;
}
load_is_simple :: (l: Value_Id) -> bool { return inst(l).ord1 == 0 && (inst(l).flags & F_VOLATILE) == 0; }

// foldPHIArgLoadIntoPHI
ic_fold_phi_arg_load_into_phi :: (pn: Value_Id) -> Value_Id {
    first := phi_value(pn, 0);
    if !ic_can_replace_load_pointer_with_variable(first) return NONE;
    if !load_is_simple(first) return NONE;
    align := inst(first).align;
    as := type_addrspace(vtype(op(first, 0)));
    if inst_block(first) != phi_block(pn, 0) || !ic_is_safe_and_profitable_to_sink_load(first) return NONE;
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        ibb := phi_block(pn, k);
        li := phi_value(pn, k);
        if !is_inst(li) || inst_op(li) != .LOAD || !has_one_user(li) || !load_is_simple(li) return NONE;
        if type_addrspace(vtype(op(li, 0))) != as return NONE;
        if !ic_can_replace_load_pointer_with_variable(li) return NONE;
        if inst_block(li) != ibb || !ic_is_safe_and_profitable_to_sink_load(li) return NONE;
        align = min(align, inst(li).align);
    }
    np := ic_create_phi_named(vtype(op(first, 0)), n, tprint("%.in", vname(pn)));
    in_val := op(first, 0);
    phi_add_incoming(np, in_val, phi_block(pn, 0));
    nl := new_inst(.LOAD, vtype(first), 1);
    set_op(nl, 0, np);
    inst(nl).align = align;
    copy_metadata(nl, first);
    for k: 1..n - 1 {
        if n < 2 break;
        li := phi_value(pn, k);
        combine_metadata_for_cse(nl, li, true);
        nv := op(li, 0);
        if nv != in_val in_val = NONE;
        phi_add_incoming(np, nv, phi_block(pn, k));
    }
    if in_val != NONE {
        set_op(nl, 0, in_val);
        drop_all_references(np);
        erase_unlinked_inst(np);
    } else {
        ic_insert_new_inst_before(np, pn);
    }
    ic_phi_arg_merged_debug_loc(nl, pn);
    return nl;
}

// foldPHIArgZextsIntoPHI
ic_fold_phi_arg_zexts_into_phi :: (phi: Value_Id) -> Value_Id {
    ti := block_terminator(inst_block(phi));
    if ti != NONE && is_eh_pad(ti) return NONE;
    n := phi_num_incoming(phi);
    if n < 3 return NONE;
    narrow: Type_Id = NONE;
    for k: 0..n - 1 { v := phi_value(phi, k); if is_inst(v) && inst_op(v) == .ZEXT { narrow = vtype(op(v, 0)); break; } }
    if narrow == NONE return NONE;
    new_in: [..] Value_Id; new_in.allocator = temp;
    num_zexts := 0; num_consts := 0;
    for k: 0..n - 1 {
        v := phi_value(phi, k);
        if is_inst(v) && inst_op(v) == .ZEXT {
            if vtype(op(v, 0)) != narrow || !has_one_user(v) return NONE;
            array_add(*new_in, op(v, 0));
            num_zexts += 1;
        } else if is_const(v) {
            t := get_lossless_unsigned_trunc(v, narrow);
            if t == NONE return NONE;
            array_add(*new_in, t);
            num_consts += 1;
        } else return NONE;
    }
    if num_consts == 0 || num_zexts < 2 return NONE;
    np := ic_create_phi_named(narrow, n, tprint("%.shrunk", vname(phi)));
    for k: 0..n - 1 phi_add_incoming(np, new_in[k], phi_block(phi, k));
    ic_insert_new_inst_before(np, phi);
    return create_zext_or_bitcast(np, vtype(phi));
}

// foldPHIArgOpIntoPHI
ic_fold_phi_arg_op_into_phi :: (pn: Value_Id) -> Value_Id {
    ti := block_terminator(inst_block(pn));
    if ti != NONE && is_eh_pad(ti) return NONE;
    first := phi_value(pn, 0);
    fo := inst_op(first);
    if fo == .GEP return ic_fold_phi_arg_gep_into_phi(pn);
    if fo == .LOAD return ic_fold_phi_arg_load_into_phi(pn);
    if fo == .INSERTVALUE return ic_fold_phi_arg_insert_value_into_phi(pn);
    if fo == .EXTRACTVALUE return ic_fold_phi_arg_extract_value_into_phi(pn);
    constant_op: Value_Id = NONE;
    cast_src: Type_Id = NONE;
    if is_cast_op(fo) {
        cast_src = vtype(op(first, 0));
        if is_int_type(vtype(pn)) && is_int_type(cast_src) {
            if !ic_should_change_type(vtype(pn), cast_src) return NONE;
        }
    } else if is_binary_operator(first) || is_cmp_inst(first) {
        if !is_const(op(first, 1)) return ic_fold_phi_arg_binop_into_phi(pn);
        constant_op = op(first, 1);
    } else return NONE;
    n := phi_num_incoming(pn);
    for k: 1..n - 1 {
        if n < 2 break;
        i := phi_value(pn, k);
        if !is_inst(i) || !has_one_user(i) || !ic_is_same_operation_as(i, first) return NONE;
        if cast_src != NONE { if vtype(op(i, 0)) != cast_src return NONE; }
        else if op(i, 1) != constant_op return NONE;
    }
    np := ic_create_phi_named(vtype(op(first, 0)), n, tprint("%.in", vname(pn)));
    in_val := op(first, 0);
    phi_add_incoming(np, in_val, phi_block(pn, 0));
    for k: 1..n - 1 {
        if n < 2 break;
        nv := op(phi_value(pn, k), 0);
        if nv != in_val in_val = NONE;
        phi_add_incoming(np, nv, phi_block(pn, k));
    }
    phi_val: Value_Id;
    if in_val != NONE {
        phi_val = in_val;
        drop_all_references(np);
        erase_unlinked_inst(np);
    } else {
        ic_insert_new_inst_before(np, pn);
        phi_val = np;
    }
    if is_cast_op(fo) {
        nc := create_cast(fo, phi_val, vtype(pn));
        ic_phi_arg_merged_debug_loc(nc, pn);
        return nc;
    }
    if is_binary_operator(first) {
        bo := create_binop(fo, phi_val, constant_op);
        copy_ir_flags(bo, phi_value(pn, 0));
        for k: 1..n - 1 { if n < 2 break; and_ir_flags(bo, phi_value(pn, k)); }
        ic_phi_arg_merged_debug_loc(bo, pn);
        return bo;
    }
    nc: Value_Id;
    if fo == .ICMP nc = create_icmp(inst_pred(first), phi_val, constant_op);
    else nc = create_fcmp(inst_pred(first), phi_val, constant_op);
    ic_phi_arg_merged_debug_loc(nc, pn);
    return nc;
}

// PHIsEqualValue
ic_phis_equal_value :: (pn: Value_Id, non_phi_in_val: *Value_Id, value_equal_phis: *[..] Value_Id) -> bool {
    for value_equal_phis.* if it == pn return true;
    array_add(value_equal_phis, pn);
    if value_equal_phis.count >= 16 return false;
    for k: 0..phi_num_incoming(pn) - 1 {
        o := phi_value(pn, k);
        if is_phi(o) {
            if !ic_phis_equal_value(o, non_phi_in_val, value_equal_phis) {
                if non_phi_in_val.* != NONE return false;
                non_phi_in_val.* = o;
            }
        } else if o != non_phi_in_val.* return false;
    }
    return true;
}

// getAnyNonZeroConstInt
ic_get_any_non_zero_const_int :: (pn: Value_Id) -> Value_Id {
    for k: 0..nops(pn) - 1 {
        v := op(pn, k);
        if vkind(v) == .C_INT && !ap_is_zero(const_ap(v)) return v;
    }
    return const_int(vtype(pn), 1);
}

// SliceUpIllegalIntegerPHI
Phi_Usage_Record :: struct { phi_id: u32; shift: u32; inst: Value_Id; }
Lowered_Phi_Record :: struct { pn: Value_Id; shift: u32; width: u32; phi: Value_Id; }

ic_slice_up_illegal_integer_phi :: (first_phi: Value_Id) -> Value_Id {
    users: [..] Phi_Usage_Record; users.allocator = temp;
    to_slice: [..] Value_Id; to_slice.allocator = temp;
    array_add(*to_slice, first_phi);
    inspected :: (to_slice: [] Value_Id, p: Value_Id) -> bool { for to_slice if it == p return true; return false; }
    phi_id: u32 = 0;
    while phi_id < cast(u32) to_slice.count {
        pn := to_slice[phi_id];
        u := ir.v_first_use[pn];
        while u != NONE {
            ui := ir.u_user[u];
            u = ir.u_next[u];
            if is_phi(ui) {
                if !inspected(to_slice, ui) array_add(*to_slice, ui);
                continue;
            }
            if inst_op(ui) == .TRUNC { array_add(*users, .{phi_id, 0, ui}); continue; }
            if inst_op(ui) != .LSHR || !has_one_use(ui) || !(is_inst(first_user(ui)) && inst_op(first_user(ui)) == .TRUNC) || vkind(op(ui, 1)) != .C_INT return NONE;
            size := scalar_bits(ui);
            sh := const_ap(op(ui, 1));
            if ap_uge_u64(sh, cast(u64) size) return NONE;
            array_add(*users, .{phi_id, cast(u32) ap_zext_value(sh), first_user(ui)});
        }
        phi_id += 1;
    }
    for pn: to_slice {
        for k: 0..phi_num_incoming(pn) - 1 {
            v := phi_value(pn, k);
            if is_inst(v) && inst_op(v) == .INVOKE && inst_block(v) == phi_block(pn, k) return NONE;
        }
        for k: 0..phi_num_incoming(pn) - 1 if !block_has_insertion_pt(phi_block(pn, k)) return NONE;
    }
    if users.count == 0 return ic_replace_inst_uses_with(first_phi, const_poison(vtype(first_phi)));
    // array_pod_sort by (PHIId, Shift, width) (std::qsort; glibc sorts small arrays by insertion sort, i.e. stably)
    less :: (a: Phi_Usage_Record, b: Phi_Usage_Record) -> bool {
        if a.phi_id != b.phi_id return a.phi_id < b.phi_id;
        if a.shift != b.shift return a.shift < b.shift;
        return type_bits(vtype(a.inst)) < type_bits(vtype(b.inst));
    }
    for i: 1..users.count - 1 {
        if users.count < 2 break;
        x := users[i]; j := i - 1;
        while j >= 0 && less(x, users[j]) { users[j + 1] = users[j]; j -= 1; }
        users[j + 1] = x;
    }
    extracted: [..] Lowered_Phi_Record; extracted.allocator = temp;
    find_extracted :: (ex: [] Lowered_Phi_Record, pn: Value_Id, sh: u32, w: u32) -> Value_Id {
        for ex if it.pn == pn && it.shift == sh && it.width == w return it.phi;
        return NONE;
    }
    user_i := 0;
    while user_i < users.count {
        rec := users[user_i];
        pn := to_slice[rec.phi_id];
        offset := rec.shift;
        ty := vtype(rec.inst);
        w := type_bits(ty);
        elt_phi := find_extracted(extracted, pn, offset, w);
        if elt_phi == NONE {
            np := phi_num_incoming(pn);
            elt_phi = create_phi(ty, np);
            set_name(elt_phi, tprint("%.off%", vname(pn), offset));
            ic_link_before(elt_phi, pn);
            pred_values: [..] Value_Id; pred_values.allocator = temp;   // pairs (pred, value)
            for k: 0..np - 1 {
                pred := phi_block(pn, k);
                in_val := phi_value(pn, k);
                pv: Value_Id = NONE;
                j := 0;
                while j < pred_values.count { if pred_values[j] == pred { pv = pred_values[j + 1]; break; } j += 2; }
                if pv != NONE { phi_add_incoming(elt_phi, pv, pred); continue; }
                if in_val == pn {
                    array_add(*pred_values, pred); array_add(*pred_values, elt_phi);
                    phi_add_incoming(elt_phi, elt_phi, pred);
                    continue;
                }
                res := find_extracted(extracted, pn, offset, w);
                if res != NONE {
                    array_add(*pred_values, pred); array_add(*pred_values, res);
                    phi_add_incoming(elt_phi, res, pred);
                    continue;
                }
                icb_set_insert_point(block_terminator(pred));
                r := in_val;
                if offset r = icb_lshr(r, const_int(vtype(in_val), cast(u64) offset), "extract");
                r = icb_trunc(r, ty, "extract.t");
                array_add(*pred_values, pred); array_add(*pred_values, r);
                phi_add_incoming(elt_phi, r, pred);
                if is_phi(in_val) && inspected(to_slice, in_val) {
                    ref_id: u32 = 0;
                    for to_slice if it == in_val { ref_id = cast(u32) it_index; break; }
                    array_add(*users, .{ref_id, offset, r});
                }
            }
            array_add(*extracted, .{pn, offset, w, elt_phi});
        }
        ic_replace_inst_uses_with(users[user_i].inst, elt_phi);
        user_i += 1;
    }
    poison := const_poison(vtype(first_phi));
    for k: 1..to_slice.count - 1 { if to_slice.count < 2 break; ic_replace_inst_uses_with(to_slice[k], poison); }
    return ic_replace_inst_uses_with(first_phi, poison);
}

// simplifyUsingControlFlow
ic_simplify_using_control_flow :: (pn: Value_Id) -> Value_Id {
    n := nops(pn);
    for k: 0..n - 1 if vkind(op(pn, k)) != .C_INT return NONE;
    bb := inst_block(pn);
    dt := ic.dt;
    if !dt_is_reachable_from_entry(dt, bb) return NONE;
    idom := dt_idom_block(dt, bb);
    term := block_terminator(idom);
    cond: Value_Id;
    succ_vals: [..] Value_Id; succ_vals.allocator = temp;   // SuccForValue: pairs (constant, block), last write wins
    succ_count: [..] Value_Id; succ_count.allocator = temp; // blocks with multiplicity
    add_succ :: (sv: *[..] Value_Id, sc: *[..] Value_Id, c: Value_Id, s: Value_Id) {
        found := false;
        j := 0;
        while j < sv.count { if sv.*[j] == c { sv.*[j + 1] = s; found = true; break; } j += 2; }
        if !found { array_add(sv, c); array_add(sv, s); }
        array_add(sc, s);
    }
    if inst_op(term) == .CONDBR {
        cond = op(term, 0);
        add_succ(*succ_vals, *succ_count, get_true(ir.t_i1), get_successor(term, 0));
        add_succ(*succ_vals, *succ_count, get_false(ir.t_i1), get_successor(term, 1));
    } else if inst_op(term) == .SWITCH {
        cond = op(term, 0);
        array_add(*succ_count, op(term, 1));
        k: u32 = 2;
        while k < nops(term) { add_succ(*succ_vals, *succ_count, ir.u_aux[ir.v_ops[term] + k], op(term, k)); k += 1; }
    } else return NONE;
    if vtype(cond) != vtype(pn) return NONE;
    invert: s8 = -1;
    for k: 0..n - 1 {
        input := op(pn, k);
        pred := phi_block(pn, k);
        is_correct :: (c: Value_Id, sv: [] Value_Id, sc: [] Value_Id, idom: Value_Id, pred: Value_Id, bb: Value_Id) -> bool {
            s: Value_Id = NONE;
            j := 0;
            while j < sv.count { if sv[j] == c { s = sv[j + 1]; break; } j += 2; }
            if s == NONE return false;
            cnt := 0;
            for sc if it == s cnt += 1;
            return cnt == 1 && dt_dominates_edge_edge(ic.dt, idom, s, pred, bb);
        }
        needs: s8;
        if is_correct(input, succ_vals, succ_count, idom, pred, bb) needs = 0;
        else if is_correct(cf_int(vtype(input), ap_not(const_ap(input))), succ_vals, succ_count, idom, pred, bb) needs = 1;
        else return NONE;
        if invert >= 0 && invert != needs return NONE;
        invert = needs;
    }
    if invert == 0 return cond;
    ip := block_first_insertion_pt(bb);
    if ip != NONE {
        irb_set_at(*ic.b, bb, ip, false);
        return icb_not(cond);
    }
    return NONE;
}

// foldDependentIVs
ic_fold_dependent_ivs :: (pn: Value_Id) -> Value_Id {
    bb := inst_block(pn);
    if phi_num_incoming(pn) != 2 return NONE;
    start, iv_next, iv2_next: Value_Id = NONE, NONE, NONE;
    match_outer :: (v1: Value_Id, v2: Value_Id, start: *Value_Id, iv_next: *Value_Id, iv2_next: *Value_Id) -> bool {
        if ic_is_any_binop(v2) {
            for side: 0..1 {
                a := op(v2, cast(u32) side); b := op(v2, cast(u32) (1 - side));
                if a == v1 && ic_is_any_binop(b) { start.* = v1; iv_next.* = v2; iv2_next.* = b; return true; }
            }
        }
        if is_inst(v2) && inst_op(v2) == .GEP && nops(v2) == 2 && op(v2, 0) == v1 && ic_is_any_binop(op(v2, 1)) {
            start.* = v1; iv_next.* = v2; iv2_next.* = op(v2, 1); return true;
        }
        return false;
    }
    if !match_outer(phi_value(pn, 0), phi_value(pn, 1), *start, *iv_next, *iv2_next) &&
       !match_outer(phi_value(pn, 1), phi_value(pn, 0), *start, *iv_next, *iv2_next) return NONE;
    ok, iv2, iv2_start, iv2_step := match_simple_recurrence_bo(iv2_next);
    if !ok || inst_block(iv2) != bb return NONE;
    is_bo := ic_is_any_binop(iv_next);
    identity := ifx is_bo then cf_binop_identity(inst_op(iv_next), vtype(iv2_start), false) else const_null_value(vtype(iv2_start));
    if iv2_start != identity return NONE;
    irb_set_at(*ic.b, bb, block_first_insertion_pt(bb), false);
    if !is_bo {
        flags := inst(iv_next).flags & cast(u32) (F_INBOUNDS | F_NUSW | F_GEP_NUW);
        if is_const(start) && is_const(iv2) fatal("internal: foldDependentIVs constant GEP");
        g := new_inst(.GEP, irb_gep_result_type(start, .[iv2]), 2);
        inst(g).flags = flags; inst(g).ty2 = inst(iv_next).ty2;
        set_op(g, 0, start); set_op(g, 1, iv2);
        return icb_insert(g);
    }
    res := icb_binop(inst_op(iv_next), iv2, start);
    copy_ir_flags(res, iv_next);
    return res;
}

// PHINode::isIdenticalToWhenDefined
phi_is_identical_to_when_defined :: (a: Value_Id, b: Value_Id) -> bool {
    if vtype(a) != vtype(b) || nops(a) != nops(b) return false;
    for k: 0..nops(a) - 1 if op(a, k) != op(b, k) || phi_block(a, k) != phi_block(b, k) return false;
    return true;
}

// ---------------------------------------------------------------- visitPHINode

ic_visit_phi :: (pn: Value_Id) -> Value_Id {
    v := simplify_instruction(pn, ic_q(pn));
    if v != NONE return ic_replace_inst_uses_with(pn, v);
    r := ic_fold_phi_arg_zexts_into_phi(pn); if r != NONE return r;
    r = ic_fold_phi_arg_int_to_ptr_to_phi(pn); if r != NONE return r;
    n := phi_num_incoming(pn);
    i0 := phi_value(pn, 0);
    i1 := ifx n > 1 then phi_value(pn, 1) else NONE;
    if is_inst(i0) && i1 != NONE && is_inst(i1) && inst_op(i0) == inst_op(i1) && has_one_user(i0) {
        r = ic_fold_phi_arg_op_into_phi(pn); if r != NONE return r;
    }
    if is_ptr_type(vtype(pn)) && block_has_insertion_pt(inst_block(pn)) {
        iv0 := phi_value(pn, 0);
        s0 := strip_pointer_casts(iv0);
        if iv0 != s0 {
            checked: [..] Value_Id; checked.allocator = temp;
            array_add(*checked, iv0);
            all := true;
            for k: 0..n - 1 {
                iv := phi_value(pn, k);
                seen := false;
                for checked if it == iv { seen = true; break; }
                if seen continue;
                array_add(*checked, iv);
                if s0 != strip_pointer_casts(iv) { all = false; break; }
            }
            if all return ic_create_pointer_cast(s0, vtype(pn));
        }
    }
    if ic_fold_dead_phi_web(pn) return NONE;
    if has_one_use(pn) {
        if ic_fold_integer_typed_phi(pn) return NONE;
        user := first_user(pn);
        if has_one_use(user) && (is_binary_operator(user) || inst_op(user) == .FNEG || inst_op(user) == .GEP) && first_user(user) == pn
            return ic_replace_inst_uses_with(pn, const_poison(vtype(pn)));
    }
    if !has_n_uses_or_more(pn, 3) {
        drop_flags: [..] Value_Id; drop_flags.allocator = temp;
        all_cmp := true;
        u := ir.v_first_use[pn];
        while u != NONE {
            us := ir.u_user[u];
            u = ir.u_next[u];
            cmp: Value_Id = ifx is_inst(us) && inst_op(us) == .ICMP then us else NONE;
            if cmp == NONE {
                if has_one_use(us) && is_inst(us) && inst_op(us) == .OR && (op(us, 0) == pn || op(us, 1) == pn) {
                    array_add(*drop_flags, us);
                    fu := first_user(us);
                    cmp = ifx is_inst(fu) && inst_op(fu) == .ICMP then fu else NONE;
                }
            }
            if cmp == NONE || !is_int_type(vtype(pn)) || !icmp_is_equality(inst_pred(cmp)) || !pm_zero(op(cmp, 1)) { all_cmp = false; break; }
        }
        if all_cmp {
            nzc: Value_Id = NONE;
            changed := false;
            for k: 0..n - 1 {
                cxt := block_terminator(phi_block(pn, k));
                va := phi_value(pn, k);
                if is_known_non_zero(va, sq_with_instruction(ic.sq, cxt)) {
                    if nzc == NONE nzc = ic_get_any_non_zero_const_int(pn);
                    if nzc != va {
                        ic_replace_operand(pn, k, nzc);
                        for drop_flags drop_poison_generating_flags(it);
                        changed = true;
                    }
                }
            }
            if changed return pn;
        }
    }
    {
        in_no: u32 = 0;
        while in_no != n && is_phi(phi_value(pn, in_no)) in_no += 1;
        non_phi: Value_Id = ifx in_no != n then phi_value(pn, in_no) else NONE;
        if non_phi != NONE {
            in_no += 1;
            while in_no != n {
                ov := phi_value(pn, in_no);
                if ov != non_phi && !is_phi(ov) break;
                in_no += 1;
            }
        }
        if in_no == n {
            eq: [..] Value_Id; eq.allocator = temp;
            if ic_phis_equal_value(pn, *non_phi, *eq) return ic_replace_inst_uses_with(pn, non_phi);
        }
    }
    bb := inst_block(pn);
    found, preds := table_find(*ic.pred_order, bb);
    if found {
        for k: 0..n - 1 {
            bba := phi_block(pn, k);
            bbb := preds[k];
            if bba != bbb {
                va := phi_value(pn, k);
                j := cast(u32) phi_block_index(pn, bbb);
                vb := phi_value(pn, j);
                phi_set_block(pn, k, bbb);
                phi_set_value(pn, k, vb);
                phi_set_block(pn, j, bba);
                phi_set_value(pn, j, va);
            }
        }
    } else {
        ord: [..] Value_Id; ord.allocator = temp;
        for k: 0..n - 1 array_add(*ord, phi_block(pn, k));
        table_set(*ic.pred_order, bb, ord);
    }
    for p: block_insts(bb) {
        if inst_op(p) != .PHI break;
        if p == pn continue;
        if !phi_is_identical_to_when_defined(pn, p) continue;
        return ic_replace_inst_uses_with(pn, p);
    }
    if is_int_type(vtype(pn)) && !dl_is_legal_integer(cast(u64) type_bits(vtype(pn))) {
        r = ic_slice_up_illegal_integer_phi(pn); if r != NONE return r;
    }
    v = ic_simplify_using_control_flow(pn);
    if v != NONE return ic_replace_inst_uses_with(pn, v);
    v = ic_fold_dependent_ivs(pn);
    if v != NONE return ic_replace_inst_uses_with(pn, v);
    return NONE;
}

// `delete I` of an instruction that was never inserted
erase_unlinked_inst :: (i: Value_Id) {
    drop_all_references(i);
    ir.v_name[i] = "";
    ir.v_kind[i] = .DEAD;
}

// combineMetadataForCSE (Transforms/Utils/Local.cpp combineMetadata, AAOnly = false). The merges that need
// MDNode::getMostGeneric* of two *different* non-null nodes (other than TBAA) fail loudly.
combine_metadata_for_cse :: (k: Value_Id, j: Value_Id, does_k_move: bool) {
    all: [..] Kind_Md; all.allocator = temp;
    get_all_metadata(k, *all);
    kid :: (n: string) -> u32 { found, id := table_find(*ir.md_kind_map, n); if found return id; return NONE; }
    nu := kid("noundef");
    has_noundef := nu != NONE && get_metadata(k, nu) != NONE;
    generic :: (kmd: Md_Id, jmd: Md_Id, what: string) -> Md_Id {
        if kmd == jmd return kmd;
        if kmd == NONE || jmd == NONE return NONE;
        fatal(tprint("combineMetadata: merging two different !% nodes is not supported yet", what));
        return NONE;
    }
    for all {
        kind := it.kind; kmd := it.md;
        if kind == 0 continue;
        jmd := get_metadata(j, kind);
        name := ir.md_kind_names[kind];
        if name == {
            case "DIAssignID"; fatal("combineMetadata: DIAssignID merging is not supported yet");
            case "tbaa"; if does_k_move set_metadata(k, kind, tbaa_most_generic(jmd, kmd));
            case "alias.scope"; if does_k_move set_metadata(k, kind, md_most_generic_alias_scope(jmd, kmd));
            case "noalias"; #through; case "llvm.mem.parallel_loop_access";
                if does_k_move set_metadata(k, kind, md_intersect(jmd, kmd));
            case "llvm.access.group"; if does_k_move set_metadata(k, kind, intersect_access_groups(k, j));
            case "range";
                if does_k_move || !has_noundef set_metadata(k, kind, md_most_generic_range(jmd, kmd));
            case "align";
                if does_k_move || !has_noundef set_metadata(k, kind, md_most_generic_align_or_deref(jmd, kmd));
            case "nofpclass";
                if does_k_move || !has_noundef set_metadata(k, kind, md_most_generic_nofpclass(jmd, kmd));
            case "nonnull";
                if does_k_move || !has_noundef set_metadata(k, kind, jmd);
            case "fpmath"; set_metadata(k, kind, md_most_generic_fpmath(jmd, kmd));
            case "invariant.load"; #through; case "invariant.group"; if does_k_move set_metadata(k, kind, jmd);
            case "prof"; #through; case "mmra"; #through; case "memprof"; #through; case "callsite";
            case "callee_type"; set_metadata(k, kind, md_merged_callee_type(kmd, jmd));
            case "dereferenceable"; #through; case "dereferenceable_or_null";
                if does_k_move set_metadata(k, kind, md_most_generic_align_or_deref(jmd, kmd));
            case "llvm.preserve.access.index";
            case "noundef"; if does_k_move set_metadata(k, kind, jmd);
            case "nontemporal"; set_metadata(k, kind, jmd);
            case "mem.cache_hint"; if kmd != jmd set_metadata(k, kind, NONE);
            case "noalias.addrspace"; if does_k_move set_metadata(k, kind, md_most_generic_noalias_addrspace(jmd, kmd));
            case "nosanitize"; set_metadata(k, kind, jmd);
            case "captures"; if kmd != jmd fatal("combineMetadata: !captures merging is not supported yet");
            case "alloc_token"; if kmd != jmd set_metadata(k, kind, NONE);
            case; set_metadata(k, kind, NONE);
        }
    }
    {
        id := kid("mmra");
        if id != NONE {
            a := get_metadata(j, id); b := get_metadata(k, id);
            if (a != NONE || b != NONE) && a != b fatal("combineMetadata: merging !mmra is not supported yet");
        }
    }
    // getMergedMemProfMetadata / getMergedCallsiteMetadata: keep K's, else J's
    for n: string.["memprof", "callsite"] {
        id := kid(n);
        if id == NONE continue;
        jm := get_metadata(j, id); km := get_metadata(k, id);
        if jm != NONE || km != NONE set_metadata(k, id, ifx km != NONE then km else jm);
    }
    {
        id := kid("prof");
        if id != NONE {
            jm := get_metadata(j, id); km := get_metadata(k, id);
            if jm != NONE || km != NONE set_metadata(k, id, md_merged_prof(km, jm, k, j));
        }
    }
}

// MDNode::getMostGenericAlignmentOrDereferenceable
md_most_generic_align_or_deref :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    av := const_int_zext(md_const_int_op(a, 0));
    bv := const_int_zext(md_const_int_op(b, 0));
    if av < bv return a;
    return b;
}
// MDNode::getMostGenericRange
md_most_generic_range :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    if a == b return a;
    ep: [..] Value_Id; ep.allocator = temp;
    try_merge :: (ep: *[..] Value_Id, lo: Value_Id, hi: Value_Id) -> bool {
        nr := cr_new(const_ap(lo), const_ap(hi));
        sz := ep.count;
        last := cr_new(const_ap(ep.*[sz - 2]), const_ap(ep.*[sz - 1]));
        can := !cr_is_empty_set(cr_intersect(nr, last)) || ap_eq(last.hi, nr.lo) || ap_eq(last.lo, nr.hi);
        if can {
            u := cr_union(last, nr);
            t := vtype(hi);
            ep.*[sz - 2] = cf_int(t, u.lo);
            ep.*[sz - 1] = cf_int(t, u.hi);
            return true;
        }
        return false;
    }
    add_range :: (ep: *[..] Value_Id, lo: Value_Id, hi: Value_Id) {
        if ep.count && try_merge(ep, lo, hi) return;
        array_add(ep, lo); array_add(ep, hi);
    }
    ai: u32 = 0; bi: u32 = 0;
    an := ir.mds[a].nops / 2; bn := ir.mds[b].nops / 2;
    while ai < an && bi < bn {
        alo := md_const_int_op(a, 2 * ai); blo := md_const_int_op(b, 2 * bi);
        if ap_slt(const_ap(alo), const_ap(blo)) { add_range(*ep, alo, md_const_int_op(a, 2 * ai + 1)); ai += 1; }
        else { add_range(*ep, blo, md_const_int_op(b, 2 * bi + 1)); bi += 1; }
    }
    while ai < an { add_range(*ep, md_const_int_op(a, 2 * ai), md_const_int_op(a, 2 * ai + 1)); ai += 1; }
    while bi < bn { add_range(*ep, md_const_int_op(b, 2 * bi), md_const_int_op(b, 2 * bi + 1)); bi += 1; }
    size := ep.count;
    if size > 2 {
        fb := ep[0]; fe := ep[1];
        if try_merge(*ep, fb, fe) {
            for i: 0..size - 3 ep[i] = ep[i + 2];
            ep.count = size - 2;
        }
    }
    if ep.count == 2 {
        r := cr_new(const_ap(ep[0]), const_ap(ep[1]));
        if cr_is_full_set(r) return NONE;
    }
    ops := NewArray(ep.count, Md_Id,, allocator = temp);
    for ep ops[it_index] = md_value(it);
    return md_tuple(ops, false);
}

// getOrSelfReference (Metadata.cpp)
md_get_or_self_reference :: (ops: [] Md_Id) -> Md_Id {
    if ops.count {
        n := ops[0];
        if md_is_node(n) && md_nops(n) == cast(u32) ops.count && md_op(n, 0) == n {
            same := true;
            for i: 1..ops.count - 1 if ops[i] != md_op(n, cast(u32) i) { same = false; break; }
            if same return n;
        }
    }
    return md_tuple(ops, false);
}
// MDNode::intersect
md_intersect :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    out: [..] Md_Id; out.allocator = temp;
    for i: 0..md_nops(a) - 1 {
        if md_nops(a) == 0 break;
        x := md_op(a, i);
        inb := false;
        for j: 0..md_nops(b) - 1 { if md_nops(b) == 0 break; if md_op(b, j) == x { inb = true; break; } }
        if !inb continue;
        array_add_if_unique(*out, x);
    }
    return md_get_or_self_reference(out);
}
// MDNode::getMostGenericAliasScope
md_most_generic_alias_scope :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    domain :: (n: Md_Id) -> Md_Id {
        if !md_is_node(n) return NONE;
        if md_nops(n) < 2 return NONE;
        d := md_op(n, 1);
        if !md_is_node(d) return NONE;
        return d;
    }
    adom: [..] Md_Id; adom.allocator = temp;
    idom: [..] Md_Id; idom.allocator = temp;
    out: [..] Md_Id; out.allocator = temp;
    na := md_nops(a); nb := md_nops(b);
    for i: 0..cast(s64) na - 1 { d := domain(md_op(a, cast(u32) i)); if d != NONE array_add_if_unique(*adom, d); }
    for i: 0..cast(s64) nb - 1 {
        o := md_op(b, cast(u32) i);
        d := domain(o);
        if d == NONE continue;
        found := false; for adom if it == d { found = true; break; }
        if found { array_add_if_unique(*idom, d); array_add_if_unique(*out, o); }
    }
    for i: 0..cast(s64) na - 1 {
        o := md_op(a, cast(u32) i);
        d := domain(o);
        if d == NONE continue;
        found := false; for idom if it == d { found = true; break; }
        if found array_add_if_unique(*out, o);
    }
    if out.count == 0 return NONE;
    return md_get_or_self_reference(out);
}

// MDNode::getMostGenericNoFPClass
md_most_generic_nofpclass :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    if a == b return a;
    av := md_const_int_op(a, 0); bv := md_const_int_op(b, 0);
    x := const_int_zext(av) & const_int_zext(bv);
    if x == 0 return NONE;
    ops: [1] Md_Id;
    ops[0] = md_value(const_int(vtype(av), x));
    return md_tuple(ops, false);
}

// MDNode::getMostGenericFPMath
md_most_generic_fpmath :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    av, _ := fp_const_as_f64(md_value_of(md_op(a, 0)));
    bv, _ := fp_const_as_f64(md_value_of(md_op(b, 0)));
    if av < bv return a;
    return b;
}
md_value_of :: (m: Md_Id) -> Value_Id { return ir.mds[m].value; }
// MDNode::getMergedCalleeTypeMetadata
md_merged_callee_type :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    ab: [..] Md_Id; ab.allocator = temp;
    for n: Md_Id.[a, b] for k: 0..cast(s64) md_nops(n) - 1 {
        o := md_op(n, cast(u32) k);
        seen := false; for ab if it == o seen = true;
        if !seen array_add(*ab, o);
    }
    return md_tuple(ab, false);
}
// MDNode::getMergedProfMetadata (+ mergeDirectCallProfMetadata)
md_merged_prof :: (a: Md_Id, b: Md_Id, ai: Value_Id, bi: Value_Id) -> Md_Id {
    legal :: (i: Value_Id) -> bool {
        o := inst_op(i);
        return o == .INVOKE || o == .CONDBR || o == .SWITCH || o == .CALL || o == .INDIRECTBR || o == .SELECT || o == .CALLBR;
    }
    if ai != NONE && !legal(ai) return NONE;
    if bi != NONE && !legal(bi) return NONE;
    if a == NONE || b == NONE return ifx a != NONE then a else b;
    if inst_op(ai) == .CALL && inst_op(bi) == .CALL && call_called_function(ai) != NONE && call_called_function(bi) != NONE {
        an := md_op(a, 0); bn := md_op(b, 0);
        if ir.mds[an].str == "branch_weights" && ir.mds[bn].str == "branch_weights" {
            ao: u32 = ifx prof_has_branch_weight_origin(a) then cast(u32) 2 else 1;
            bo: u32 = ifx prof_has_branch_weight_origin(b) then cast(u32) 2 else 1;
            aw := const_int_zext(md_const_int_op(a, ao));
            bw := const_int_zext(md_const_int_op(b, bo));
            sum := aw + bw;
            if sum < aw sum = U64_MAX;   // SaturatingAdd
            ops := Md_Id.[md_string("branch_weights"), md_value(const_int(type_int(cast(u64) 64), sum))];
            return md_tuple(ops, false);
        }
        return NONE;
    }
    if a == b return a;
    return NONE;
}
// intersectAccessGroups (VectorUtils.cpp)
intersect_access_groups :: (i1: Value_Id, i2: Value_Id) -> Md_Id {
    m1 := may_read_or_write_memory(i1); m2 := may_read_or_write_memory(i2);
    ag := md_kind_id("llvm.access.group");
    if !m1 && !m2 return NONE;
    if !m1 return get_metadata(i2, ag);
    if !m2 return get_metadata(i1, ag);
    a := get_metadata(i1, ag); b := get_metadata(i2, ag);
    if a == NONE || b == NONE return NONE;
    if a == b return a;
    set2: [..] Md_Id; set2.allocator = temp;
    if md_nops(b) == 0 array_add(*set2, b); else for k: 0..cast(s64) md_nops(b) - 1 array_add(*set2, md_op(b, cast(u32) k));
    inter: [..] Md_Id; inter.allocator = temp;
    contains :: (s: [] Md_Id, x: Md_Id) -> bool { for s if it == x return true; return false; }
    if md_nops(a) == 0 { if contains(set2, a) array_add(*inter, a); }
    else for k: 0..cast(s64) md_nops(a) - 1 { x := md_op(a, cast(u32) k); if contains(set2, x) array_add(*inter, x); }
    if inter.count == 0 return NONE;
    if inter.count == 1 return inter[0];
    return md_tuple(inter, false);
}

// MDNode::getMostGenericNoaliasAddrspace (ConstantRangeList::intersectWith)
md_most_generic_noalias_addrspace :: (a: Md_Id, b: Md_Id) -> Md_Id {
    if a == NONE || b == NONE return NONE;
    if a == b return a;
    ranges :: (m: Md_Id) -> [..] Const_Range {
        r: [..] Const_Range; r.allocator = temp;
        for i: 0..cast(s64) md_nops(m) / 2 - 1 array_add(*r, cr_new(const_ap(md_const_int_op(m, cast(u32) (2 * i))), const_ap(md_const_int_op(m, cast(u32) (2 * i + 1)))));
        return r;
    }
    ra := ranges(a); rb := ranges(b);
    res: [..] Const_Range; res.allocator = temp;
    if ra.count == 0 res = ra; else if rb.count == 0 res = rb;
    else {
        i := 0; j := 0;
        while i < ra.count && j < rb.count {
            st := ifx ap_sgt(ra[i].lo, rb[j].lo) then ra[i].lo else rb[j].lo;
            en := ifx ap_slt(ra[i].hi, rb[j].hi) then ra[i].hi else rb[j].hi;
            if ap_slt(st, en) array_add(*res, cr_new(st, en));
            if ap_slt(ra[i].hi, rb[j].hi) i += 1; else j += 1;
        }
    }
    if res.count == 0 return NONE;
    ops: [..] Md_Id; ops.allocator = temp;
    for res {
        t := type_int(cast(u64) it.lo.bits);
        array_add(*ops, md_value(const_int_words(t, ap_words(it.lo))));
        array_add(*ops, md_value(const_int_words(t, ap_words(it.hi))));
    }
    return md_tuple(ops, false);
}
