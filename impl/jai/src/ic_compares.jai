// InstCombine for icmp and fcmp: a port of llvm/lib/Transforms/InstCombine/InstCombineCompares.cpp
// (visitICmpInst, visitFCmpInst and every helper of that file), in LLVM's order: helpers appear in the order of the
// C++ file, and each visitor tries its folds in exactly LLVM's sequence (the first fold that fires wins).

// ---------------------------------------------------------------- small helpers of the file

// hasBranchUse
ic_has_branch_use :: (i: Value_Id) -> bool {
    u := ir.v_first_use[i];
    while u != NONE {
        us := ir.u_user[u];
        if is_inst(us) && inst_op(us) == .CONDBR return true;
        u = ir.u_next[u];
    }
    return false;
}

// isSignTest: (ok, updated predicate)
ic_is_sign_test :: (pred: u8, c: APInt) -> (bool, u8) {
    if !icmp_is_signed(pred) return false, pred;
    if ap_is_zero(c) return icmp_is_relational(pred), pred;
    if ap_is_one(c) {
        if pred == ICMP_SLT return true, ICMP_SLE;
    } else if ap_is_all_ones(c) {
        if pred == ICMP_SGT return true, ICMP_SGE;
    }
    return false, pred;
}

// m_SpecificInt_ICMP / m_CheckedInt style matcher with an extra argument: every non-poison element satisfies pred
pm_int_pred_arg :: (v: Value_Id, pred: (APInt, APInt) -> bool, arg: APInt) -> bool {
    if v == NONE return false;
    k := vkind(v);
    if k == .C_INT return pred(const_ap(v), arg);
    t := vtype(v);
    if !is_vector_type(t) || !is_constant_kind(k) return false;
    s := get_splat_value(v);
    if s != NONE return vkind(s) == .C_INT && pred(const_ap(s), arg);
    if type_kind(t) != .VECTOR return false;
    n := type_count(t);
    has_non_poison := false;
    for e: 0..cast(s64) n - 1 {
        elt := cf_elt(v, cast(u64) e);
        if elt == NONE return false;
        if vkind(elt) == .C_POISON continue;
        if vkind(elt) != .C_INT || !pred(const_ap(elt), arg) return false;
        has_non_poison = true;
    }
    return has_non_poison;
}

// a binary-operator instruction with opcode `opc` (m_BinOp-style instruction match, keeping the instruction)
ic_is_binop :: (v: Value_Id, opc: Opcode) -> bool { return is_inst(v) && inst_op(v) == opc; }

ic_bool_const :: (t: Type_Id, b: bool) -> Value_Id { return ifx b then get_true(t) else get_false(t); }

// ---------------------------------------------------------------- foldCmpLoadFromIndexedGlobal

// llvm::decomposeLinearExpression (Analysis/Loads.cpp): (base, index, scale, offset, nw flags)
Linear_Expression :: struct {
    base: Value_Id;
    index: Value_Id = NONE;
    scale: APInt;
    offset: APInt;
    flags: u32 = F_INBOUNDS | F_NUSW | F_GEP_NUW;
}
ic_decompose_linear_expression :: (ptr: Value_Id) -> Linear_Expression {
    bw := dl_index_type_size_bits(vtype(ptr));
    e: Linear_Expression;
    e.base = ptr; e.scale = ap_zero(bw); e.offset = ap_zero(bw);
    while true {
        g := e.base;
        if !is_gep_operator(g) || type_has_scalable(opr_gep_source_type(g)) return e;
        var_index: Value_Id = NONE;
        n := nops(g);
        for k: 1..cast(s64) n - 1 {
            idx := op(g, cast(u32) k);
            if vkind(idx) == .C_INT continue;
            if e.index != NONE || var_index != NONE return e;
            var_index = idx;
        }
        if var_index != NONE && !(is_int_type(vtype(var_index)) && type_int_width(vtype(var_index)) == bw) return e;
        e.base = op(g, 0);
        e.flags = gep_nw_intersect_for_offset_add(e.flags, gep_nw_bits(g));
        cur := opr_gep_source_type(g);
        for k: 1..cast(s64) n - 1 {
            idx := op(g, cast(u32) k);
            is_struct := k > 1 && type_kind(cur) == .STRUCT;
            indexed := gep_indexed_type(cur, k, idx);
            defer cur = indexed;
            if vkind(idx) == .C_INT {
                ci := const_ap(idx);
                if ap_is_zero(ci) continue;
                if is_struct {
                    e.offset = ap_add(e.offset, ap_from_u64(bw, dl_struct_offset(cur, cast(u32) ap_zext_value(ci))));
                    continue;
                }
                size := ap_from_u64(bw, gep_seq_stride(cur, k, indexed));
                e.offset = ap_add(e.offset, ap_mul(ap_sext_or_trunc(ci, bw), size));
                continue;
            }
            e.index = idx;
            e.scale = ap_from_u64(bw, gep_seq_stride(cur, k, indexed));
        }
    }
    return e;
}

// DataLayout::getSmallestLegalIntType
ic_smallest_legal_int_type :: (width: u64) -> Type_Id {
    best: u64 = 0;
    for dl.legal_ints if it >= width && (best == 0 || it < best) best = it;
    if best == 0 return NONE;
    return type_int(cast(u32) best);
}

ic_fold_cmp_load_from_indexed_global :: (li: Value_Id, gep: Value_Id, ici: Value_Id, and_cst: Value_Id) -> Value_Id {
    gv := get_underlying_object(gep);
    if is_volatile(li) || vkind(gv) != .GLOBAL_VAR || !glob(gv).is_const || !gv_has_definitive_initializer(gv) return NONE;
    elt_ty := vtype(li);
    if type_is_scalable(elt_ty) return NONE;
    elt_size := dl_type_store_size(elt_ty);
    expr := ic_decompose_linear_expression(gep);
    if expr.index == NONE || expr.base != gv || expr.offset.bits > 64 return NONE;
    init := gv_initializer(gv);
    global_size := dl_type_alloc_size(vtype(init));
    idx := expr.index;
    stride := expr.scale;
    const_offset := expr.offset;
    if !ap_ult(const_offset, stride) return NONE;
    if !ap_uge_u64(stride, elt_size) return NONE;
    num := global_size - ap_zext_value(const_offset);
    sv := ap_zext_value(stride);
    array_element_count := (num + sv - 1) / sv;
    if array_element_count > ic.max_array_size return NONE;

    OVERDEFINED :: -3;
    UNDEFINED :: -2;
    first_true := UNDEFINED; second_true := UNDEFINED;
    first_false := UNDEFINED; second_false := UNDEFINED;
    true_range_end := UNDEFINED; false_range_end := UNDEFINED;
    magic: u64 = 0;
    compare_rhs := op(ici, 1);
    offset := const_offset;
    pred := inst_pred(ici);
    for i: 0..cast(s64) array_element_count - 1 {
        defer offset = ap_add(offset, stride);
        elt := cfo_load_from_const(init, elt_ty, offset);
        if elt == NONE return NONE;
        if and_cst != NONE {
            elt = cfo_binary_op_operands(.AND, elt, and_cst);
            if elt == NONE return NONE;
        }
        c := cfo_compare_inst_operands(pred, elt, compare_rhs);
        if c == NONE return NONE;
        if vkind(c) == .C_UNDEF || vkind(c) == .C_POISON {
            if true_range_end == i - 1 true_range_end = i;
            if false_range_end == i - 1 false_range_end = i;
            continue;
        }
        if vkind(c) != .C_INT return NONE;
        is_true := !ap_is_zero(const_ap(c));
        if is_true {
            if first_true == UNDEFINED { first_true = i; true_range_end = i; }
            else {
                if second_true == UNDEFINED second_true = i; else second_true = OVERDEFINED;
                if true_range_end == i - 1 true_range_end = i; else true_range_end = OVERDEFINED;
            }
        } else {
            if first_false == UNDEFINED { first_false = i; false_range_end = i; }
            else {
                if second_false == UNDEFINED second_false = i; else second_false = OVERDEFINED;
                if false_range_end == i - 1 false_range_end = i; else false_range_end = OVERDEFINED;
            }
        }
        if i < 64 && is_true magic |= (cast(u64) 1) << cast(u64) i;
        if (i & 8) == 0 && i >= 64 && second_true == OVERDEFINED && second_false == OVERDEFINED &&
           true_range_end == OVERDEFINED && false_range_end == OVERDEFINED return NONE;
    }
    mask_idx :: (idx: Value_Id, flags: u32, stride: APInt) -> Value_Id {
        if (flags & F_INBOUNDS) == 0 && ap_ctz(stride) != 0 {
            mask := const_all_ones_of(vtype(idx));
            mask = icb_lshr(mask, const_int_of(vtype(mask), ap_ctz(stride)));
            return icb_and(idx, mask);
        }
        return idx;
    }
    if second_true != OVERDEFINED {
        idx = mask_idx(idx, expr.flags, stride);
        if first_true == UNDEFINED return ic_replace_inst_uses_with(ici, get_false(ir.t_i1));
        first_idx := const_int_of(vtype(idx), cast(u64) first_true);
        if second_true == UNDEFINED return create_icmp(ICMP_EQ, idx, first_idx);
        c1 := icb_cmp(ICMP_EQ, idx, first_idx);
        second_idx := const_int_of(vtype(idx), cast(u64) second_true);
        c2 := icb_cmp(ICMP_EQ, idx, second_idx);
        return create_binop(.OR, c1, c2);
    }
    if second_false != OVERDEFINED {
        idx = mask_idx(idx, expr.flags, stride);
        if first_false == UNDEFINED return ic_replace_inst_uses_with(ici, get_true(ir.t_i1));
        first_idx := const_int_of(vtype(idx), cast(u64) first_false);
        if second_false == UNDEFINED return create_icmp(ICMP_NE, idx, first_idx);
        c1 := icb_cmp(ICMP_NE, idx, first_idx);
        second_idx := const_int_of(vtype(idx), cast(u64) second_false);
        c2 := icb_cmp(ICMP_NE, idx, second_idx);
        return create_binop(.AND, c1, c2);
    }
    if true_range_end != OVERDEFINED {
        idx = mask_idx(idx, expr.flags, stride);
        if first_true != 0 idx = icb_add(idx, const_int_signed(vtype(idx), -first_true));
        e := const_int_of(vtype(idx), cast(u64) (true_range_end - first_true + 1));
        return create_icmp(ICMP_ULT, idx, e);
    }
    if false_range_end != OVERDEFINED {
        idx = mask_idx(idx, expr.flags, stride);
        if first_false != 0 idx = icb_add(idx, const_int_signed(vtype(idx), -first_false));
        e := const_int_of(vtype(idx), cast(u64) (false_range_end - first_false));
        return create_icmp(ICMP_UGT, idx, e);
    }
    {
        ty: Type_Id = NONE;
        if array_element_count <= cast(u64) type_int_width(vtype(idx)) ty = vtype(idx);
        else ty = ic_smallest_legal_int_type(array_element_count);
        if ty != NONE {
            idx = mask_idx(idx, expr.flags, stride);
            v := icb_int_cast(idx, ty, false);
            v = icb_lshr(const_int_of(ty, magic), v);
            v = icb_and(const_int_of(ty, 1), v);
            return create_icmp(ICMP_NE, v, const_int_of(ty, 0));
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- GEP compares

// canRewriteGEPAsOffset. `explored` is the SetVector (insertion order, no duplicates).
ic_can_rewrite_gep_as_offset :: (start: Value_Id, base: Value_Id, nw: *u32, explored: *[..] Value_Id) -> bool {
    contains :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }
    insert :: (a: *[..] Value_Id, v: Value_Id) { for a.* if it == v return; array_add(a, v); }
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, start);
    insert(explored, base);
    while worklist.count {
        phis: [..] Value_Id; phis.allocator = temp;
        while worklist.count {
            if explored.count >= 100 return false;
            v := worklist[worklist.count - 1];
            if contains(explored.*, v) { worklist.count -= 1; continue; }
            if !(is_inst(v) && (inst_op(v) == .GEP || inst_op(v) == .PHI)) return false;
            if inst_op(v) == .GEP {
                if (inst(v).flags & F_INBOUNDS) == 0 return false;
                nonconst := 0;
                for k: 1..cast(s64) nops(v) - 1 if vkind(op(v, cast(u32) k)) != .C_INT nonconst += 1;
                if nonconst > 1 return false;
                nw.* = gep_nw_intersect_for_offset_add(nw.*, gep_nw_bits(v));
                if !contains(explored.*, op(v, 0)) array_add(*worklist, op(v, 0));
            }
            if worklist[worklist.count - 1] == v {
                worklist.count -= 1;
                insert(explored, v);
            }
            if inst_op(v) == .PHI {
                if inst_op(block_terminator(inst_block(v))) == .CATCHSWITCH return false;
                insert(explored, v);
                insert(*phis, v);
            }
        }
        for pn: phis {
            n := phi_num_incoming(pn);
            if n > 0 for k: 0..n-1 {
                o := phi_value(pn, cast(u32) k);
                if !contains(explored.*, o) array_add(*worklist, o);
            }
        }
    }
    for val: explored.* {
        u := ir.v_first_use[val];
        while u != NONE {
            defer u = ir.u_next[u];
            us := ir.u_user[u];
            phi := ifx is_inst(us) && inst_op(us) == .PHI then us else NONE;
            iv := ifx is_inst(val) then val else NONE;
            if iv == base || iv == phi || iv == NONE || phi == NONE || !contains(explored.*, phi) continue;
            if inst_block(phi) == inst_block(iv) return false;
        }
    }
    return true;
}

// setInsertionPoint (on a local IRBuilder<>)
ic_set_insertion_point :: (b: *Irb, v: Value_Id, before := true) {
    if is_inst(v) && inst_op(v) == .PHI {
        bb := inst_block(v);
        irb_set_at(b, bb, block_first_insertion_pt(bb), false);
        return;
    }
    if is_inst(v) {
        i := v;
        if !before {
            nx := inst(i).next;
            if nx == NONE { irb_set_end(b, inst_block(i)); return; }
            i = nx;
        }
        irb_set_before(b, i);
        return;
    }
    if vkind(v) == .ARGUMENT {
        entry := fn_entry(arg_parent(v));
        irb_set_at(b, entry, block_first_insertion_pt(entry), false);
        return;
    }
}

// llvm::emitGEPOffset with a plain IRBuilder<> (rewriteGEPAsOffset's local builder: nothing goes on the worklist)
ic_emit_gep_offset_irb :: (b: *Irb, g: Value_Id) -> Value_Id {
    idx_ty := dl_index_type(vtype(g));
    result: Value_Id = NONE;
    nw := gep_nw_bits(g);
    nsw := (nw & F_NUSW) != 0;
    nuw := (nw & F_GEP_NUW) != 0;
    flags := (ifx nuw then cast(u32) F_NUW else 0) | (ifx nsw then cast(u32) F_NSW else 0);
    cur := opr_gep_source_type(g);
    n := nops(g);
    for k: 1..cast(s64) n - 1 {
        o := op(g, cast(u32) k);
        is_struct := k > 1 && type_kind(cur) == .STRUCT;
        indexed := gep_indexed_type(cur, k, o);
        defer cur = indexed;
        if is_const(o) {
            if is_null_value(o) continue;
            if is_struct {
                c := o;
                if is_vector_type(vtype(c)) c = get_splat_value(c);
                size := dl_struct_offset(cur, cast(u32) ap_zext_value(const_ap(c)));
                if size == 0 continue;
                off := const_int_of(idx_ty, size);
                if result != NONE result = irb_binop(b, .ADD, result, off, tprint("%.offs", vname(g)), flags); else result = off;
                continue;
            }
        }
        if is_vector_type(idx_ty) && !is_vector_type(vtype(o)) fatal("instcombine: emitGEPOffset of a vector GEP with scalar indices is not supported yet");
        if vtype(o) != idx_ty o = irb_int_cast(b, o, idx_ty, true, tprint("%.c", vname(o)));
        if type_is_scalable(indexed) fatal("instcombine: emitGEPOffset with scalable strides is not supported yet");
        stride := gep_seq_stride(cur, k, indexed);
        if stride != 1 {
            scale := const_int_of(scalar_type(idx_ty), stride);
            if is_vector_type(idx_ty) scale = cf_get_splat(idx_ty, scale);
            o = irb_binop(b, .MUL, o, scale, tprint("%.idx", vname(g)), flags);
        }
        if result != NONE result = irb_binop(b, .ADD, result, o, tprint("%.offs", vname(g)), flags); else result = o;
    }
    if result == NONE return const_null_value(idx_ty);
    return result;
}
// IRBuilder::CreateIntCast on a plain builder
irb_int_cast :: (b: *Irb, v: Value_Id, dt: Type_Id, is_signed: bool, name: string = "") -> Value_Id {
    sb := type_bits(scalar_type(vtype(v))); db := type_bits(scalar_type(dt));
    if sb == db return v;
    opc: Opcode = ifx sb > db then Opcode.TRUNC else (ifx is_signed then Opcode.SEXT else Opcode.ZEXT);
    return irb_cast(b, opc, v, dt, name);
}

// rewriteGEPAsOffset
ic_rewrite_gep_as_offset :: (start: Value_Id, base: Value_Id, nw: u32, explored: [] Value_Id) -> Value_Id {
    index_type := type_int(dl_index_type_size_bits(vtype(start)));
    new_insts: Table(Value_Id, Value_Id); new_insts.allocator = temp;
    table_set(*new_insts, base, const_null_value(index_type));
    for val: explored {
        if val == base continue;
        if is_inst(val) && inst_op(val) == .PHI {
            p := create_phi(index_type, phi_num_incoming(val));
            inst_insert_before(p, val);
            ic_reinsert_name_with(p, tprint("%.idx", vname(val)));
            table_set(*new_insts, val, p);
        }
    }
    b: Irb;
    for val: explored {
        if table_find_pointer(*new_insts, val) continue;
        if is_gep_operator(val) {
            ic_set_insertion_point(*b, val);
            _, opv := table_find(*new_insts, op(val, 0));
            offv := ic_emit_gep_offset_irb(*b, val);
            if vkind(opv) == .C_INT && ap_is_zero(const_ap(opv)) table_set(*new_insts, val, offv);
            else {
                flags := (ifx (nw & F_GEP_NUW) != 0 then cast(u32) F_NUW else 0) | (ifx (nw & F_NUSW) != 0 then cast(u32) F_NSW else 0);
                table_set(*new_insts, val, irb_binop(*b, .ADD, opv, offv, tprint("%.add", vname(op(val, 0))), flags));
            }
            continue;
        }
        if is_inst(val) && inst_op(val) == .PHI continue;
        fatal("internal: rewriteGEPAsOffset: unexpected instruction type");
    }
    for val: explored {
        if val == base continue;
        if is_inst(val) && inst_op(val) == .PHI {
            _, np := table_find(*new_insts, val);
            n := phi_num_incoming(val);
            if n > 0 for k: 0..n-1 {
                inc := phi_value(val, cast(u32) k);
                found, nv := table_find(*new_insts, inc);
                if found inc = nv;
                phi_add_incoming(np, inc, phi_block(val, cast(u32) k));
            }
        }
    }
    for val: explored {
        if val == base continue;
        ic_set_insertion_point(*b, val, false);
        _, off := table_find(*new_insts, val);
        nv := irb_gep(*b, ir.t_i8, base, .[off], tprint("%.ptr", vname(val)), ic_gep_flags_from_nw(nw));
        ic_replace_inst_uses_with(val, nv);
        wl_push(val);
    }
    _, r := table_find(*new_insts, start);
    return r;
}
// GEPNoWrapFlags -> instruction flags (inbounds implies nusw: printed as inbounds only)
ic_gep_flags_from_nw :: (nw: u32) -> u32 {
    f := nw;
    if (f & F_INBOUNDS) != 0 f &= ~cast(u32) F_NUSW;
    return f;
}
// PHINode::Create(..., Name, InsertBefore): the name is uniqued when the phi is inserted
ic_reinsert_name_with :: (i: Value_Id, name: string) {
    if name.count set_name(i, name);
}

// transformToIndexedCompare
ic_transform_to_indexed_compare :: (gep_lhs: Value_Id, rhs: Value_Id, cond: u8) -> Value_Id {
    if is_vector_type(vtype(gep_lhs)) return NONE;
    if !ic_gep_has_all_constant_indices(gep_lhs) return NONE;
    offset := ap_zero(dl_index_type_size_bits(vtype(gep_lhs)));
    ptr_base: Value_Id;
    ptr_base, offset = strip_and_accumulate_constant_offsets(gep_lhs, offset, false);
    if vtype(ptr_base) != vtype(gep_lhs) return NONE;
    nodes: [..] Value_Id; nodes.allocator = temp;
    nw := gep_nw_bits(gep_lhs);
    if !ic_can_rewrite_gep_as_offset(rhs, ptr_base, *nw, *nodes) return NONE;
    new_rhs := ic_rewrite_gep_as_offset(rhs, ptr_base, nw, nodes);
    return create_icmp(icmp_signed_predicate(cond), const_int_ap(type_int(offset.bits), offset), new_rhs);
}
// GEPOperator::hasAllConstantIndices
ic_gep_has_all_constant_indices :: (g: Value_Id) -> bool {
    for k: 1..cast(s64) nops(g) - 1 if vkind(op(g, cast(u32) k)) != .C_INT return false;
    return true;
}

// CommonPointerBase::compute + isExpensive (InstCombineAddSub.cpp)
Common_Pointer_Base :: struct {
    ptr: Value_Id = NONE;
    lhs_geps: [..] Value_Id;
    rhs_geps: [..] Value_Id;
    lhs_nw: u32;
    rhs_nw: u32;
}
ic_common_pointer_base :: (lhs_in: Value_Id, rhs_in: Value_Id) -> Common_Pointer_Base {
    base: Common_Pointer_Base;
    base.lhs_geps.allocator = temp; base.rhs_geps.allocator = temp;
    lhs := lhs_in; rhs := rhs_in;
    if vtype(lhs) != vtype(rhs) return base;
    ptrs: [..] Value_Id; ptrs.allocator = temp;
    p := lhs;
    while true { array_add(*ptrs, p); if is_gep_operator(p) p = op(p, 0); else break; }
    contains :: (a: [] Value_Id, v: Value_Id) -> bool { for a if it == v return true; return false; }
    first := true;
    while true {
        if contains(ptrs, rhs) { base.ptr = rhs; break; }
        if is_gep_operator(rhs) {
            array_add(*base.rhs_geps, rhs);
            if first { first = false; base.rhs_nw = gep_nw_bits(rhs); } else base.rhs_nw = gep_nw_intersect_for_offset_add(base.rhs_nw, gep_nw_bits(rhs));
            rhs = op(rhs, 0);
        } else return base;
    }
    first = true;
    while lhs != base.ptr {
        array_add(*base.lhs_geps, lhs);
        if first { first = false; base.lhs_nw = gep_nw_bits(lhs); } else base.lhs_nw = gep_nw_intersect_for_offset_add(base.lhs_nw, gep_nw_bits(lhs));
        lhs = op(lhs, 0);
    }
    return base;
}
ic_common_pointer_base_is_expensive :: (b: *Common_Pointer_Base) -> bool {
    num := 0;
    process :: (geps: [] Value_Id, num: *int) {
        seen := false;
        for geps if !has_one_use(it) { if seen num.* += 1; seen = true; }
    }
    process(b.lhs_geps, *num); process(b.rhs_geps, *num);
    return num > 2;
}

// foldGEPICmp
ic_fold_gep_icmp :: (gep_lhs: Value_Id, rhs_in: Value_Id, cond: u8, i: Value_Id) -> Value_Id {
    if icmp_is_signed(cond) return NONE;
    rhs := rhs_in;
    if !(is_inst(rhs) && inst_op(rhs) == .GEP) rhs = strip_pointer_casts(rhs);
    can_fold :: (cond: u8, nw: u32) -> bool {
        if icmp_is_equality(cond) return true;
        return nw != 0;
    }
    new_icmp :: (cond: u8, nw: u32, op1: Value_Id, op2: Value_Id) -> Value_Id {
        if (nw & F_GEP_NUW) == 0 return create_icmp(icmp_signed_predicate(cond), op1, op2);
        r := create_icmp(cond, op1, op2);
        if (nw & F_NUSW) != 0 set_flag(r, F_EXACT, true);
        return r;
    }
    base := ic_common_pointer_base(gep_lhs, rhs);
    if base.ptr == rhs && can_fold(cond, base.lhs_nw) && !ic_common_pointer_base_is_expensive(*base) {
        idx_ty := dl_index_type(vtype(gep_lhs));
        offset := ic_emit_gep_offsets(base.lhs_geps, base.lhs_nw, idx_ty, true);
        return new_icmp(cond, base.lhs_nw, offset, const_null_value(vtype(offset)));
    }
    if (opr_flags(gep_lhs) & F_INBOUNDS) != 0 && icmp_is_equality(cond) && vkind(rhs) == .C_NULL &&
       !null_pointer_is_defined(inst_fn(i), type_addrspace(vtype(rhs))) {
        b := op(gep_lhs, 0);
        if is_vector_type(vtype(gep_lhs)) && is_ptr_type(vtype(b)) {
            b = icb_vector_splat(type_count(vtype(gep_lhs)), type_kind(vtype(gep_lhs)) == .SVECTOR, b);
        }
        return create_icmp(cond, b, ce_pointer_bitcast_or_addrspacecast(rhs, vtype(b)));
    } else if is_gep_operator(rhs) {
        gep_rhs := rhs;
        nw := gep_nw_bits(gep_lhs) & gep_nw_bits(gep_rhs);
        if op(gep_lhs, 0) != op(gep_rhs, 0) {
            same := nops(gep_lhs) == nops(gep_rhs) && vtype(op(gep_lhs, 0)) == vtype(op(gep_rhs, 0)) &&
                    opr_gep_source_type(gep_lhs) == opr_gep_source_type(gep_rhs);
            if same for k: 1..cast(s64) nops(gep_lhs) - 1 {
                if op(gep_lhs, cast(u32) k) != op(gep_rhs, cast(u32) k) { same = false; break; }
            }
            base_type := vtype(op(gep_lhs, 0));
            if same && make_cmp_result_type(base_type) == vtype(i) && can_fold(cond, nw)
                return create_icmp(cond, op(gep_lhs, 0), op(gep_rhs, 0));
            if (opr_flags(gep_lhs) & F_INBOUNDS) != 0 && (opr_flags(gep_rhs) & F_INBOUNDS) != 0 &&
               (ic_gep_has_all_constant_indices(gep_lhs) || has_one_use(gep_lhs)) &&
               (ic_gep_has_all_constant_indices(gep_rhs) || has_one_use(gep_rhs)) &&
               strip_pointer_casts(op(gep_lhs, 0)) == strip_pointer_casts(op(gep_rhs, 0)) &&
               !is_vector_type(vtype(gep_lhs)) {
                loff := ic_emit_gep_offset(gep_lhs);
                roff := ic_emit_gep_offset(gep_rhs);
                lt := vtype(loff); rt := vtype(roff);
                if lt != rt {
                    if type_bits(lt) < type_bits(rt) roff = icb_trunc(roff, lt);
                    else loff = icb_trunc(loff, rt);
                }
                c := icb_cmp(icmp_signed_predicate(cond), loff, roff);
                return ic_replace_inst_uses_with(i, c);
            }
        }
        if op(gep_lhs, 0) == op(gep_rhs, 0) && nops(gep_lhs) == nops(gep_rhs) &&
           opr_gep_source_type(gep_lhs) == opr_gep_source_type(gep_rhs) {
            num_diff := 0;
            diff_op: u32 = 0;
            for k: 1..cast(s64) nops(gep_rhs) - 1 {
                a := op(gep_lhs, cast(u32) k); bb := op(gep_rhs, cast(u32) k);
                if a != bb {
                    lt := vtype(a); rt := vtype(bb);
                    if ic_primitive_size_bits(lt) != ic_primitive_size_bits(rt) ||
                       (is_vector_type(vtype(gep_lhs)) && (!is_vector_type(lt) || !is_vector_type(rt))) {
                        num_diff = 2;
                        break;
                    }
                    num_diff += 1;
                    if num_diff > 1 break;
                    diff_op = cast(u32) k;
                }
            }
            if num_diff == 0 return ic_replace_inst_uses_with(i, cf_bool(vtype(i), cmp_is_true_when_equal(cond)));
            else if num_diff == 1 && nw != 0 return new_icmp(cond, nw, op(gep_lhs, diff_op), op(gep_rhs, diff_op));
        }
        if base.ptr != NONE && can_fold(cond, base.lhs_nw & base.rhs_nw) && !ic_common_pointer_base_is_expensive(*base) {
            idx_ty := dl_index_type(vtype(gep_lhs));
            l := ic_emit_gep_offsets(base.lhs_geps, base.lhs_nw, idx_ty, true);
            r := ic_emit_gep_offsets(base.rhs_geps, base.rhs_nw, idx_ty, true);
            return new_icmp(cond, base.lhs_nw & base.rhs_nw, l, r);
        }
    }
    return ic_transform_to_indexed_compare(gep_lhs, rhs, cond);
}
// Type::getPrimitiveSizeInBits (0 for pointers and aggregates)
ic_primitive_size_bits :: (t: Type_Id) -> u64 {
    st := scalar_type(t);
    if is_ptr_type(st) return 0;
    k := type_kind(st);
    if !(is_int_type(st) || is_fp_kind(k)) return 0;
    b := cast(u64) type_bits(st);
    if is_vector_type(t) b *= type_count(t);
    return b;
}
// ConstantExpr::getPointerBitCastOrAddrSpaceCast
ce_pointer_bitcast_or_addrspacecast :: (c: Value_Id, t: Type_Id) -> Value_Id {
    if vtype(c) == t return c;
    if type_addrspace(vtype(c)) != type_addrspace(t) return cfo_constant(ce_cast(.ADDRSPACECAST, c, t));
    return cfo_constant(ce_cast(.BITCAST, c, t));
}
// CreateVectorSplat on the combiner's builder
icb_vector_splat :: (n: u64, scalable: bool, v: Value_Id, name: string = "") -> Value_Id {
    vt := type_vector(n, vtype(v), scalable);
    if is_const(v) return cf_get_splat(vt, v);
    poison := const_poison(vt);
    ins := icb_insert_element(poison, v, const_int_of(ir.t_i64, 0), tprint("%.splatinsert", name));
    zeros := NewArray(cast(s64) n, u32,, allocator = temp);
    return icb_shuffle(ins, poison, zeros, tprint("%.splat", name));
}

// foldAllocaCmp
ic_fold_alloca_cmp :: (alloca: Value_Id) -> bool {
    t: Capture_Tracker; t.kind = .ALLOCA_CMP; t.alloca = alloca;
    t.icmps.allocator = temp; t.icmp_masks.allocator = temp;
    ct_run(alloca, *t);
    if t.captured return false;
    changed := false;
    for icmp, k: t.icmps {
        operands := t.icmp_masks[k];
        if operands == 1 || operands == 2 {
            res := cf_bool(vtype(icmp), inst_pred(icmp) == ICMP_NE);
            ic_replace_inst_uses_with(icmp, res);
            ic_erase_inst(icmp);
            changed = true;
        }
    }
    return changed;
}

// foldICmpAddOpConst: icmp pred (X+C), X
ic_fold_icmp_add_op_const :: (x: Value_Id, c: APInt, pred: u8) -> Value_Id {
    t := vtype(x);
    if pred == ICMP_ULT || pred == ICMP_ULE return create_icmp(ICMP_UGT, x, const_int_ap(t, ap_sub(ap_all_ones(c.bits), c)));
    if pred == ICMP_UGT || pred == ICMP_UGE return create_icmp(ICMP_ULT, x, const_int_ap(t, ap_neg(c)));
    smax := ap_signed_max(c.bits);
    if pred == ICMP_SLT || pred == ICMP_SLE return create_icmp(ICMP_SGT, x, const_int_ap(t, ap_sub(smax, c)));
    return create_icmp(ICMP_SLT, x, const_int_ap(t, ap_sub(smax, ap_sub_u64(c, 1))));
}

// foldICmpShrConstConst: icmp eq/ne (ashr/lshr AP2, A), AP1
ic_fold_icmp_shr_const_const :: (i: Value_Id, a: Value_Id, ap1: APInt, ap2: APInt) -> Value_Id {
    get_icmp :: (i: Value_Id, p: u8, l: Value_Id, r: Value_Id) -> Value_Id {
        pp := p;
        if inst_pred(i) == ICMP_NE pp = cmp_inverse(pp);
        return create_icmp(pp, l, r);
    }
    if ap_is_zero(ap2) return NONE;
    is_ashr := opr_code(op(i, 0)) == .ASHR;
    if is_ashr {
        if ap_is_all_ones(ap2) return NONE;
        if ap_sign_bit(ap2) != ap_sign_bit(ap1) return NONE;
        if ap_sgt(ap2, ap1) return NONE;
    }
    at := vtype(a);
    if ap_is_zero(ap1) return get_icmp(i, ICMP_UGT, a, const_int_of(at, ap_log2(ap2)));
    if ap_eq(ap1, ap2) return get_icmp(i, ICMP_EQ, a, const_null_value(at));
    shift: s64;
    if is_ashr && ap_sign_bit(ap1) shift = cast(s64) ap_clo(ap1) - cast(s64) ap_clo(ap2);
    else shift = cast(s64) ap_clz(ap1) - cast(s64) ap_clz(ap2);
    if shift > 0 {
        if is_ashr && ap_eq(ap1, ap_ashr(ap2, cast(u32) shift)) {
            if ap_is_all_ones(ap1) && !ap_is_power_of_2(ap2) return get_icmp(i, ICMP_UGE, a, const_int_of(at, cast(u64) shift));
            return get_icmp(i, ICMP_EQ, a, const_int_of(at, cast(u64) shift));
        } else if ap_eq(ap1, ap_lshr(ap2, cast(u32) shift)) {
            return get_icmp(i, ICMP_EQ, a, const_int_of(at, cast(u64) shift));
        }
    }
    return ic_replace_inst_uses_with(i, cf_bool(vtype(i), inst_pred(i) == ICMP_NE));
}

// foldICmpShlConstConst: icmp eq/ne (shl AP2, A), AP1
ic_fold_icmp_shl_const_const :: (i: Value_Id, a: Value_Id, ap1: APInt, ap2: APInt) -> Value_Id {
    get_icmp :: (i: Value_Id, p: u8, l: Value_Id, r: Value_Id) -> Value_Id {
        pp := p;
        if inst_pred(i) == ICMP_NE pp = cmp_inverse(pp);
        return create_icmp(pp, l, r);
    }
    if ap_is_zero(ap2) return NONE;
    tz := ap_ctz(ap2);
    at := vtype(a);
    if ap_is_zero(ap1) && tz != 0 return get_icmp(i, ICMP_UGE, a, const_int_of(at, cast(u64) (ap2.bits - tz)));
    if ap_eq(ap1, ap2) return get_icmp(i, ICMP_EQ, a, const_null_value(at));
    shift := cast(s64) ap_ctz(ap1) - cast(s64) tz;
    if shift > 0 && ap_eq(ap_shl(ap2, cast(u32) shift), ap1) return get_icmp(i, ICMP_EQ, a, const_int_of(at, cast(u64) shift));
    return ic_replace_inst_uses_with(i, cf_bool(vtype(i), inst_pred(i) == ICMP_NE));
}

// processUGT_ADDCST_ADD: icmp ugt (add (add A, B), CI2), CI1 -> sadd.with.overflow
ic_process_ugt_addcst_add :: (i: Value_Id, a: Value_Id, b: Value_Id, ci2: APInt, ci1: APInt) -> Value_Id {
    add_with_cst := op(i, 0);
    if !has_one_use(add_with_cst) return NONE;
    if !ap_is_power_of_2(ci2) return NONE;
    new_width := ap_ctz(ci2);
    if new_width != 7 && new_width != 15 && new_width != 31 return NONE;
    new_width += 1;
    if ci1.bits == new_width || !ap_eq(ci1, ap_low_bits_set(ci1.bits, new_width)) return NONE;
    if max_significant_bits(a, ic_q_no_dc(i)) > new_width || max_significant_bits(b, ic_q_no_dc(i)) > new_width return NONE;
    orig_add := op(add_with_cst, 0);
    u := ir.v_first_use[orig_add];
    while u != NONE {
        defer u = ir.u_next[u];
        us := ir.u_user[u];
        if us == add_with_cst continue;
        if !(is_inst(us) && inst_op(us) == .TRUNC) || ic_primitive_size_bits(vtype(us)) > new_width return NONE;
    }
    new_type := type_int(new_width);
    icb_set_insert_point(orig_add);
    ta := icb_trunc(a, new_type, tprint("%.trunc", vname(a)));
    tb := icb_trunc(b, new_type, tprint("%.trunc", vname(b)));
    call := icb_intrinsic(IID_SADD_WITH_OVERFLOW, .[new_type], .[ta, tb], "sadd");
    add := icb_extract_value(call, .[0], "sadd.result");
    zext := icb_zext(add, vtype(orig_add));
    ic_replace_inst_uses_with(orig_add, zext);
    ic_erase_inst(orig_add);
    return create_extract_value(call, .[1], "sadd.overflow");
}

// foldIRemByPowerOfTwoToBitTest
ic_fold_irem_by_power_of_two_to_bit_test :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    if !icmp_is_equality(pred) return NONE;
    o0 := op(i, 0); zero := op(i, 1);
    if !(is_inst(o0) && (inst_op(o0) == .UREM || inst_op(o0) == .SREM) && has_one_use(o0)) || !pm_zero(zero) return NONE;
    x := op(o0, 0); y := op(o0, 1);
    if !ic_is_known_to_be_power_of_two(y, true, i) return NONE;
    mask := icb_add(y, const_all_ones_of(vtype(y)));
    masked := icb_and(x, mask);
    return create_icmp(pred, masked, zero);
}

// foldSignBitTest
ic_fold_sign_bit_test :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    val := op(i, 0);
    if !icmp_is_equality(pred) || !is_inst(val) || !pm_zero(op(i, 1)) return NONE;
    x: Value_Id = NONE;
    xt: Type_Id;
    sh := trunc_or_self_i(val);
    if is_inst(sh) && is_shr_op(inst_op(sh)) && is_const(op(sh, 1)) {
        x = op(sh, 0);
        xt = vtype(x);
        xbw := scalar_bits(x);
        eq :: (a: APInt, b: APInt) -> bool { return ap_eq(a, b); }
        if !pm_int_pred_arg(op(sh, 1), eq, ap_from_u64(xbw, cast(u64) (xbw - 1))) return NONE;
    } else if is_binary_operator(val) {
        x = ic_reassociate_shift_amts_of_two_same_direction_shifts(val, ic_q(val), true);
        if x == NONE return NONE;
        xt = vtype(x);
    } else return NONE;
    return create_icmp(ifx pred == ICMP_EQ then cast(u8) ICMP_SGE else ICMP_SLT, x, const_null_value(xt));
}

// foldICmpWithZero: icmp pred X, 0
ic_fold_icmp_with_zero :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    if !pm_zero(op(cmp, 1)) return NONE;
    o0 := op(cmp, 0);
    if pred == ICMP_SGT {
        ok, a, b := pm_intrinsic2(o0, IID_SMIN);
        if ok {
            if is_known_positive(a, ic_q(cmp)) return create_icmp(pred, b, op(cmp, 1));
            if is_known_positive(b, ic_q(cmp)) return create_icmp(pred, a, op(cmp, 1));
        }
    }
    r := ic_fold_irem_by_power_of_two_to_bit_test(cmp); if r != NONE return r;
    {
        ok, x, y := pm_binop(o0, .UREM);
        if ok && icmp_is_equality(pred) {
            xk := ic_known_bits(x, cmp);
            yk := ic_known_bits(y, cmp);
            if kb_count_max_population(xk) == 1 && kb_count_min_population(yk) >= 2 return create_icmp(pred, x, op(cmp, 1));
        }
    }
    {
        ok, x, y := pm_binop(o0, .MUL);
        if ok && icmp_is_equality(pred) {
            xk := ic_known_bits(x, cmp);
            if kb_count_max_trailing_zeros(xk) == 0 return create_icmp(pred, y, op(cmp, 1));
            yk := ic_known_bits(y, cmp);
            if kb_count_max_trailing_zeros(yk) == 0 return create_icmp(pred, x, op(cmp, 1));
            if has_nuw(o0) || has_nsw(o0) {
                q := ic_q(cmp);
                if !ap_is_zero(xk.one) || is_known_non_zero(x, q) return create_icmp(pred, y, op(cmp, 1));
                if !ap_is_zero(yk.one) || is_known_non_zero(y, q) return create_icmp(pred, x, op(cmp, 1));
            }
        }
    }
    if icmp_is_equality(pred) {
        stripped := strip_null_test(o0);
        if stripped != NONE return create_icmp(pred, stripped, const_null_value(vtype(stripped)));
    }
    return NONE;
}

// foldIsMultipleOfAPowerOfTwo: icmp eq (num + mask) & ~mask, num -> icmp eq (and num, mask), 0
ic_fold_is_multiple_of_a_power_of_two :: (cmp: Value_Id) -> Value_Id {
    for side: 0..1 {
        pred := inst_pred(cmp);
        if side == 1 pred = cmp_swapped(pred);
        num := op(cmp, cast(u32) side);
        an := op(cmp, cast(u32) (1 - side));
        if !(ic_is_binop(an, .AND) && has_one_use(an)) continue;
        for s2: 0..1 {
            add := op(an, cast(u32) s2);
            negc := op(an, cast(u32) (1 - s2));
            if !(ic_is_binop(add, .ADD) && has_one_use(add)) continue;
            okm := false; mask: APInt;
            if op(add, 0) == num { okm, mask = pm_low_bit_mask_ap(op(add, 1)); }
            if !okm && op(add, 1) == num { okm, mask = pm_low_bit_mask_ap(op(add, 0)); }
            if !okm continue;
            okn, neg := pm_apint(negc);
            if !okn continue;
            if !ap_eq(neg, ap_not(mask)) return NONE;
            if !icmp_is_equality(pred) return NONE;
            na := icb_and(num, const_int_ap(vtype(num), mask));
            return create_icmp(pred, na, const_null_value(vtype(num)));
        }
    }
    return NONE;
}

// foldICmpWithConstant
ic_fold_icmp_with_constant :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    o0 := op(cmp, 0); o1 := op(cmp, 1);
    if pred == ICMP_UGT && vkind(o1) == .C_INT && ic_is_binop(o0, .ADD) && vkind(op(o0, 1)) == .C_INT {
        inner := op(o0, 0);
        if ic_is_binop(inner, .ADD) {
            r := ic_process_ugt_addcst_add(cmp, op(inner, 0), op(inner, 1), const_ap(op(o0, 1)), const_ap(o1));
            if r != NONE return r;
        }
    }
    if !is_const(o1) return NONE;
    c := o1;
    if is_inst(o0) && inst_op(o0) == .PHI {
        all_const := true;
        n := phi_num_incoming(o0);
        if n > 0 for k: 0..n-1 if !is_const(phi_value(o0, cast(u32) k)) { all_const = false; break; }
        if all_const {
            res: [..] Value_Id; res.allocator = temp;
            if n > 0 for k: 0..n-1 {
                r := cfo_compare_inst_operands(pred, phi_value(o0, cast(u32) k), c);
                if r == NONE return NONE;
                array_add(*res, r);
            }
            icb_set_insert_point(o0);
            np := icb_phi(vtype(cmp), n);
            if n > 0 for k: 0..n-1 phi_add_incoming(np, res[k], phi_block(o0, cast(u32) k));
            return ic_replace_inst_uses_with(cmp, np);
        }
    }
    r := ic_try_fold_inst_with_ctpop_with_not(cmp); if r != NONE return r;
    return NONE;
}

// foldICmpWithDominatingICmp
ic_fold_icmp_with_dominating_icmp :: (cmp: Value_Id) -> Value_Id {
    x := op(cmp, 0); y := op(cmp, 1);
    okc, c := pm_apint(y);
    if !okc return NONE;
    pred := inst_pred(cmp);
    cr := cr_exact_icmp_region(pred, c);
    handle :: (cmp: Value_Id, x: Value_Id, pred: u8, c: APInt, cr: Const_Range, dom_pred: u8, dom_c: APInt) -> Value_Id {
        dcr := cr_exact_icmp_region(dom_pred, dom_c);
        inter := cr_intersect(dcr, cr);
        diff := cr_difference(dcr, cr);
        if cr_is_empty_set(inter) return ic_replace_inst_uses_with(cmp, get_false(ir.t_i1));
        if cr_is_empty_set(diff) return ic_replace_inst_uses_with(cmp, get_true(ir.t_i1));
        is_sign_bit, _ := is_sign_bit_check(pred, c);
        if icmp_is_equality(pred) || (is_sign_bit && ic_has_branch_use(cmp)) return NONE;
        if has_one_use(cmp) && pm_max_or_min_any(first_user(cmp)) return NONE;
        oke, eqc := cr_single_element(inter);
        if oke return create_icmp(ICMP_EQ, x, const_int_ap(type_int(eqc.bits), eqc));
        okn, nec := cr_single_element(diff);
        if okn return create_icmp(ICMP_NE, x, const_int_ap(type_int(nec.bits), nec));
        return NONE;
    }
    conds := dc_conditions_for(*ic.dc, x);
    for bi: conds {
        okd, dp, _, dx, dcv := pm_icmp(op(bi, 0));
        if !okd || dx != x continue;
        okdc, dom_c := pm_apint(dcv);
        if !okdc continue;
        bb := inst_block(bi);
        if dt_dominates_edge_block(ic.dt, bb, get_successor(bi, 0), inst_block(cmp)) {
            v := handle(cmp, x, pred, c, cr, dp, dom_c);
            if v != NONE return v;
        } else if dt_dominates_edge_block(ic.dt, bb, get_successor(bi, 1), inst_block(cmp)) {
            v := handle(cmp, x, pred, c, cr, cmp_inverse(dp), dom_c);
            if v != NONE return v;
        }
    }
    return NONE;
}
// m_MaxOrMin(m_Value(), m_Value()): a min/max intrinsic call
pm_max_or_min_any :: (v: Value_Id) -> bool {
    id := call_iid(v);
    return id == IID_SMAX || id == IID_SMIN || id == IID_UMAX || id == IID_UMIN;
}

// foldICmpTruncConstant: icmp (trunc X), C
ic_fold_icmp_trunc_constant :: (cmp: Value_Id, trunc: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    x := op(trunc, 0);
    src_ty := vtype(x);
    dst_bits := scalar_bits(trunc); src_bits := scalar_bits(x);
    if ic_should_change_type(vtype(trunc), src_ty) {
        if has_nsw(trunc) return create_icmp(pred, x, const_int_ap(src_ty, ap_sext(c, src_bits)));
        if !icmp_is_signed(pred) && has_nuw(trunc) return create_icmp(pred, x, const_int_ap(src_ty, ap_zext(c, src_bits)));
    }
    if ap_is_one(c) && c.bits > 1 {
        if pred == ICMP_SLT {
            ok, v := pm_signum(x);
            if ok return create_icmp(ICMP_SLT, v, const_int_of(vtype(v), 1));
        }
    }
    if icmp_is_equality(pred) {
        oks, p2v, y := pm_binop(x, .SHL);
        okp, pow2 := pm_power2_ap(p2v);
        if oks && okp && dst_bits > ap_log2(pow2) {
            if ap_is_zero(c) {
                np := ifx pred == ICMP_EQ then cast(u8) ICMP_UGE else ICMP_ULT;
                return create_icmp(np, y, const_int_of(src_ty, cast(u64) (dst_bits - ap_log2(pow2))));
            }
            if ap_is_power_of_2(c) return create_icmp(pred, y, const_int_of(src_ty, cast(u64) (ap_log2(c) - ap_log2(pow2))));
        }
    }
    if icmp_is_equality(pred) && (has_one_use(trunc) || has_nuw(trunc)) {
        if !is_vector_type(src_ty) && ic_should_change_type_widths(dst_bits, src_bits) {
            mask := const_int_ap(src_ty, ap_low_bits_set(src_bits, dst_bits));
            a := ifx has_nuw(trunc) then x else icb_and(x, mask);
            wide_c := const_int_ap(src_ty, ap_zext(c, src_bits));
            return create_icmp(pred, a, wide_c);
        }
        known := ic_known_bits(x, cmp);
        if ap_clo(ap_or(known.zero, known.one)) >= src_bits - dst_bits {
            nrhs := ap_zext(c, src_bits);
            nrhs = ap_or(nrhs, ap_and(known.one, ap_high_bits_set(src_bits, src_bits - dst_bits)));
            return create_icmp(pred, x, const_int_ap(src_ty, nrhs));
        }
    }
    is_sb, true_if_signed := is_sign_bit_check(pred, c);
    if is_sb && is_inst(x) && is_shr_op(inst_op(x)) {
        oka, sh_amt := pm_constant_int_u64(op(x, 1));
        if oka && cast(u64) dst_bits == cast(u64) src_bits - sh_amt {
            sh_op := op(x, 0);
            if true_if_signed return create_icmp(ICMP_SLT, sh_op, const_null_value(src_ty));
            return create_icmp(ICMP_SGT, sh_op, const_all_ones_of(src_ty));
        }
    }
    return NONE;
}
// m_Signum(V): (V s>> (bw-1)) | zext(V != 0) ... PatternMatch.h Signum_match
pm_signum :: (v: Value_Id) -> (bool, Value_Id) {
    if !ic_is_binop(v, .OR) return false, NONE;
    for side: 0..1 {
        sh := op(v, cast(u32) side); lsh := op(v, cast(u32) (1 - side));
        if !ic_is_binop(sh, .ASHR) || !ic_is_binop(lsh, .LSHR) continue;
        x := op(sh, 0);
        bw := scalar_bits(x);
        if !pm_specific_int(op(sh, 1), cast(u64) (bw - 1)) continue;
        neg := op(lsh, 0);
        okn, nx := pm_neg(neg);
        if !okn || nx != x continue;
        if !pm_specific_int(op(lsh, 1), cast(u64) (bw - 1)) continue;
        return true, x;
    }
    return false, NONE;
}

// foldICmpXorConstant: icmp (xor X, Y), C
ic_fold_icmp_xor_constant :: (cmp: Value_Id, xor: Value_Id, c: APInt) -> Value_Id {
    r := ic_fold_icmp_xor_shift_const(cmp, xor, c); if r != NONE return r;
    x := op(xor, 0); y := op(xor, 1);
    okx, xorc := pm_apint(y);
    if !okx return NONE;
    pred := inst_pred(cmp);
    is_sb, true_if_signed := is_sign_bit_check(pred, c);
    if is_sb {
        if !ap_sign_bit(xorc) return ic_replace_operand(cmp, 0, x);
        if true_if_signed return create_icmp(ICMP_SGT, x, const_all_ones_of(vtype(x)));
        return create_icmp(ICMP_SLT, x, const_null_value(vtype(x)));
    }
    if has_one_use(xor) {
        if !icmp_is_equality(pred) && ap_is_sign_mask(xorc) {
            np := icmp_flipped_signedness(pred);
            return create_icmp(np, x, const_int_ap(vtype(x), ap_xor(c, xorc)));
        }
        if !icmp_is_equality(pred) && ap_is_max_signed(xorc) {
            np := icmp_swapped(icmp_flipped_signedness(pred));
            return create_icmp(np, x, const_int_ap(vtype(x), ap_xor(c, xorc)));
        }
    }
    if pred == ICMP_UGT {
        if ap_eq(xorc, ap_not(c)) && ap_is_power_of_2(ap_add_u64(c, 1)) return create_icmp(ICMP_ULT, x, y);
        if ap_eq(xorc, c) && ap_is_power_of_2(ap_add_u64(c, 1)) return create_icmp(ICMP_UGT, x, y);
    }
    if pred == ICMP_ULT {
        if ap_eq(xorc, ap_neg(c)) && ap_is_power_of_2(c) return create_icmp(ICMP_UGT, x, const_int_ap(vtype(x), ap_not(c)));
        if ap_eq(xorc, c) && ap_is_power_of_2(ap_neg(c)) return create_icmp(ICMP_UGT, x, const_int_ap(vtype(x), ap_not(c)));
    }
    return NONE;
}

// foldICmpXorShiftConst
ic_fold_icmp_xor_shift_const :: (cmp: Value_Id, xor: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    pow2: APInt;
    if pred == ICMP_ULT pow2 = c;
    else if pred == ICMP_UGT && !ap_is_max_value(c) pow2 = ap_add_u64(c, 1);
    else return NONE;
    if !ap_is_power_of_2(pow2) return NONE;
    if !has_one_use(xor) return NONE;
    x: Value_Id = NONE; shift_c: APInt;
    for side: 0..1 {
        xv := op(xor, cast(u32) side); sh := op(xor, cast(u32) (1 - side));
        if ic_is_binop(sh, .ASHR) && op(sh, 0) == xv {
            ok, sc := pm_apint(op(sh, 1));
            if ok { x = xv; shift_c = sc; break; }
        }
    }
    if x == NONE return NONE;
    shift := ap_limited(shift_c);
    xt := vtype(x);
    if shift == 0 || ap_is_min_signed(pow2) return NONE;
    add := icb_add(x, const_int_ap(xt, pow2));
    bound := ifx pred == ICMP_ULT then ap_shl(pow2, 1) else ap_sub_u64(ap_shl(pow2, 1), 1);
    return create_icmp(pred, add, const_int_ap(xt, bound));
}

// foldICmpAndShift: icmp (and (sh X, Y), C2), C1
ic_fold_icmp_and_shift :: (cmp: Value_Id, and: Value_Id, c1: APInt, c2: APInt) -> Value_Id {
    shift := op(and, 0);
    if !(is_inst(shift) && is_shift_op(inst_op(shift))) return NONE;
    sop := inst_op(shift);
    is_shl := sop == .SHL;
    pred := inst_pred(cmp);
    ok3, c3 := pm_apint(op(shift, 1));
    if ok3 {
        new_and, new_cmp: APInt;
        shifted_out: bool;
        if sop == .SHL {
            if icmp_is_signed(pred) && (ap_sign_bit(c2) || ap_sign_bit(c1)) return NONE;
            new_cmp = ap_lshr_ap(c1, c3);
            new_and = ap_lshr_ap(c2, c3);
            shifted_out = !ap_eq(ap_shl_ap(new_cmp, c3), c1);
        } else if sop == .LSHR {
            new_cmp = ap_shl_ap(c1, c3);
            new_and = ap_shl_ap(c2, c3);
            shifted_out = !ap_eq(ap_lshr_ap(new_cmp, c3), c1);
            if icmp_is_signed(pred) && (ap_sign_bit(new_and) || ap_sign_bit(new_cmp)) return NONE;
        } else {
            new_cmp = ap_shl_ap(c1, c3);
            new_and = ap_shl_ap(c2, c3);
            shifted_out = !ap_eq(ap_ashr_ap(new_cmp, c3), c1);
            if !ap_eq(ap_ashr_ap(new_and, c3), c2) return NONE;
        }
        if shifted_out {
            if pred == ICMP_EQ return ic_replace_inst_uses_with(cmp, get_false(vtype(cmp)));
            if pred == ICMP_NE return ic_replace_inst_uses_with(cmp, get_true(vtype(cmp)));
        } else {
            na := icb_and(op(shift, 0), const_int_ap(vtype(and), new_and));
            return create_icmp(pred, na, const_int_ap(vtype(and), new_cmp));
        }
    }
    if has_one_use(shift) && ap_is_zero(c1) && icmp_is_equality(pred) && sop != .ASHR &&
       ((!is_shl && ap_is_one(c2)) || !is_const(op(shift, 0))) {
        ns := ifx is_shl then icb_lshr(op(and, 1), op(shift, 1)) else icb_shl(op(and, 1), op(shift, 1));
        na := icb_and(op(shift, 0), ns);
        return create_icmp(pred, na, op(cmp, 1));
    }
    return NONE;
}

// foldICmpAndConstConst: icmp (and X, C2), C1
ic_fold_icmp_and_const_const :: (cmp: Value_Id, and: Value_Id, c1: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    is_ne := pred == ICMP_NE;
    if is_ne && ap_is_zero(c1) && pm_one(op(and, 1)) return create_cast(.TRUNC, op(and, 0), vtype(cmp));
    x := op(and, 0);
    ok2, c2 := pm_apint(op(and, 1));
    if !ok2 return NONE;
    if pred == ICMP_SGT && ap_ule(c1, ap_not(c2)) && ap_is_negated_power_of_2(c2)
        return create_icmp(ICMP_SGT, x, const_int_ap(vtype(x), ap_not(c2)));
    if pred == ICMP_SLT && !ap_is_sign_mask(c1) && ap_ule(ap_sub_u64(c1, 1), ap_not(c2)) && ap_is_negated_power_of_2(c2) && !ap_is_sign_mask(c2)
        return create_icmp(ICMP_SLT, x, const_int_ap(vtype(x), ap_neg(c2)));
    if !has_one_use(and) return NONE;
    if icmp_is_equality(pred) && ap_is_zero(c1) {
        if ap_is_sign_mask(c2) return create_icmp(ifx is_ne then cast(u8) ICMP_SLT else ICMP_SGE, x, const_null_value(vtype(x)));
        know := ic_known_bits(op(and, 0), and);
        nc2 := ap_or(c2, ap_high_bits_set(c2.bits, kb_count_min_leading_zeros(know)));
        if ap_is_negated_power_of_2(nc2) return create_icmp(ifx is_ne then cast(u8) ICMP_UGE else ICMP_ULT, x, const_int_ap(vtype(and), ap_neg(nc2)));
    }
    okw, w := pmi_cast(op(and, 0), .TRUNC);
    if okw && has_one_use(op(and, 0)) && (icmp_is_equality(pred) || (!ap_sign_bit(c1) && !ap_sign_bit(c2))) {
        if !is_vector_type(vtype(cmp)) {
            wt := vtype(w);
            wb := scalar_bits(w);
            zc1 := const_int_ap(wt, ap_zext(c1, wb));
            zc2 := const_int_ap(wt, ap_zext(c2, wb));
            na := icb_and(w, zc2, name_ref(vname(and)));
            return create_icmp(pred, na, zc1);
        }
    }
    r := ic_fold_icmp_and_shift(cmp, and, c1, c2); if r != NONE return r;
    if !icmp_is_signed(pred) && ap_is_zero(c1) && has_one_use(op(and, 0)) && pm_one(op(and, 1)) {
        one := op(and, 1);
        or := op(and, 0);
        if ic_is_binop(or, .OR) {
            lshr := op(or, 0); a := op(or, 1);
            if ic_is_binop(lshr, .LSHR) && op(lshr, 0) == a {
                b := op(lshr, 1);
                uses_removed := 0;
                if has_one_use(and) uses_removed += 1;
                if has_one_use(or) uses_removed += 1;
                if has_one_use(lshr) uses_removed += 1;
                required := ifx pm_imm_constant(b) then 1 else 3;
                if uses_removed >= required {
                    no := icb_or(icb_shl(one, b, name_ref(vname(lshr)), true), one, name_ref(vname(or)));
                    na := icb_and(a, no, name_ref(vname(and)));
                    return create_icmp(pred, na, op(cmp, 1));
                }
            }
        }
    }
    if !fn_has_fn_attr(inst_fn(cmp), .NoImplicitFloat) && icmp_is_equality(pred) {
        okb, v := pm_elementwise_bitcast(x);
        if okb && has_one_use(x) {
            fpt := scalar_type(vtype(v));
            if ic_is_ieee_like_fp_ty(fpt) && (ap_is_zero(c1) || ap_eq(c1, c2)) {
                exponent_mask := ic_fp_inf_bits(fpt);
                if ap_eq(c2, exponent_mask) {
                    mask: u32 = ifx ap_is_zero(c1) then cast(u32) (FC_ZERO | FC_SUBNORMAL) else cast(u32) (FC_NAN | FC_INF);
                    if is_ne mask = ~mask & FC_ALL_FLAGS;
                    return ic_replace_inst_uses_with(cmp, icb_is_fpclass(v, mask));
                }
            }
        }
    }
    return NONE;
}
// Type::isIEEELikeFPTy
ic_is_ieee_like_fp_ty :: (t: Type_Id) -> bool {
    k := type_kind(t);
    return k == .HALF || k == .BFLOAT || k == .FLOAT || k == .DOUBLE || k == .FP128;
}
// APFloat::getInf(Sem).bitcastToAPInt()
ic_fp_inf_bits :: (t: Type_Id) -> APInt {
    bits := type_bits(t);
    k := type_kind(t);
    mant: u32;
    if k == .HALF mant = 10; else if k == .BFLOAT mant = 7; else if k == .FLOAT mant = 23; else if k == .DOUBLE mant = 52; else mant = 112;
    return ap_bits_set(bits, mant, bits - 1);
}
// IRBuilder::createIsFPClass
icb_is_fpclass :: (v: Value_Id, mask: u32) -> Value_Id {
    return icb_intrinsic(IID_IS_FPCLASS, .[vtype(v)], .[v, const_int_of(ir.t_i32, cast(u64) mask)]);
}

// foldICmpAndConstant: icmp (and X, Y), C
ic_fold_icmp_and_constant :: (cmp: Value_Id, and: Value_Id, c: APInt) -> Value_Id {
    r := ic_fold_icmp_and_const_const(cmp, and, c); if r != NONE return r;
    pred := inst_pred(cmp);
    is_sb, true_if_neg := is_sign_bit_check(pred, c);
    if is_sb {
        a0 := op(and, 0); a1 := op(and, 1);
        oka, x, m1 := pm_binop(a0, .ADD);
        if oka && pm_all_ones(m1) {
            okn, nx := pm_not(a1);
            if okn && nx == x return create_icmp(ifx true_if_neg then cast(u8) ICMP_EQ else ICMP_NE, x, const_null_value(vtype(x)));
        }
        for side: 0..1 {
            okn, nx := pm_neg(op(and, cast(u32) side));
            if okn && op(and, cast(u32) (1 - side)) == nx {
                minc := const_int_ap(vtype(nx), ap_signed_min(scalar_bits(nx)));
                return create_icmp(ifx true_if_neg then cast(u8) ICMP_EQ else ICMP_NE, nx, minc);
            }
        }
    }
    x := op(and, 0); y := op(and, 1);
    if vkind(y) == .C_INT && !is_vector_type(vtype(y)) && is_inst(x) && inst_op(x) == .LOAD {
        g := op(x, 0);
        if is_inst(g) && inst_op(g) == .GEP {
            r = ic_fold_cmp_load_from_indexed_global(x, g, cmp, y); if r != NONE return r;
        }
    }
    if !icmp_is_equality(pred) return NONE;
    if op(cmp, 1) == y && ap_is_negated_power_of_2(c) {
        np := ifx pred == ICMP_EQ then cast(u8) ICMP_UGT else ICMP_ULE;
        return create_icmp(np, x, ic_sub_one(op(cmp, 1)));
    }
    if has_one_use(and) {
        for side: 0..1 {
            z := op(and, cast(u32) side); yy := op(and, cast(u32) (1 - side));
            okz, zx := pmi_cast(z, .ZEXT);
            if !okz || !has_one_use(z) continue;
            if is_int_or_int_vector_n(vtype(zx), 1) && (ap_is_zero(c) || ap_is_one(c)) {
                ty := icb_trunc(yy, vtype(zx));
                if ap_is_zero(c) != (pred == ICMP_NE) {
                    a := icb_and(ty, zx);
                    return create_not(a);
                }
                return create_binop(.AND, ty, zx);
            }
            break;
        }
    }
    if ap_is_zero(c) && has_one_use(and) {
        for side: 0..1 {
            sh := op(and, cast(u32) side); yy := op(and, cast(u32) (1 - side));
            if !ic_is_binop(sh, .SHL) || !has_one_use(sh) || !pm_all_ones(op(sh, 0)) continue;
            lshr := icb_lshr(yy, op(sh, 1));
            return create_icmp(pred, lshr, const_null_value(vtype(lshr)));
        }
    }
    if has_one_use(and) {
        add := op(and, 0);
        if ic_is_binop(add, .ADD) && has_one_use(add) {
            oka, addend := pm_apint(op(add, 1));
            okm, msk := pm_low_bit_mask_ap(op(and, 1));
            if oka && okm && ap_ule(c, msk) {
                a := op(add, 0);
                ncmp := ap_and(ap_sub(c, addend), msk);
                mask_a := icb_and(a, const_int_ap(vtype(a), msk));
                return create_icmp(pred, mask_a, const_int_ap(vtype(mask_a), ncmp));
            }
        }
    }
    return NONE;
}

// foldICmpOrXorSubChain
ic_fold_icmp_or_xor_sub_chain :: (cmp: Value_Id, or: Value_Id) -> Value_Id {
    Pair :: struct { a: Value_Id; b: Value_Id; }
    cmp_values: [..] Pair; cmp_values.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, or);
    match_arg :: (v: Value_Id, cmp_values: *[..] Pair, worklist: *[..] Value_Id) {
        if ic_is_binop(v, .XOR) && has_one_use(v) { array_add(cmp_values, .{op(v, 0), op(v, 1)}); return; }
        if ic_is_binop(v, .SUB) && has_one_use(v) { array_add(cmp_values, .{op(v, 0), op(v, 1)}); return; }
        array_add(worklist, v);
    }
    while worklist.count {
        cur := pop(*worklist);
        if !ic_is_binop(cur, .OR) return NONE;
        match_arg(op(cur, 1), *cmp_values, *worklist);
        match_arg(op(cur, 0), *cmp_values, *worklist);
    }
    pred := inst_pred(cmp);
    bopc: Opcode = ifx pred == ICMP_EQ then Opcode.AND else .OR;
    last := cmp_values[cmp_values.count - 1];
    lhs_cmp := icb_cmp(pred, last.a, last.b);
    for < k: 0..cmp_values.count - 2 {
        rc := icb_cmp(pred, cmp_values[k].a, cmp_values[k].b);
        lhs_cmp = icb_binop(bopc, lhs_cmp, rc);
    }
    return lhs_cmp;
}

// foldICmpOrConstant: icmp (or X, Y), C
ic_fold_icmp_or_constant :: (cmp: Value_Id, or: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    if ap_is_one(c) && pred == ICMP_SLT {
        ok, v := pm_signum(or);
        if ok return create_icmp(ICMP_SLT, v, const_int_of(vtype(v), 1));
    }
    o0 := op(or, 0); o1 := op(or, 1);
    if icmp_is_equality(pred) && pm_imm_constant(o1) && (inst(or).flags & F_EXACT) != 0 {
        nc := icb_xor(o1, const_int_ap(vtype(o1), c));
        return create_icmp(pred, o0, nc);
    }
    okm, maskc := pm_apint(o1);
    if okm && icmp_is_equality(pred) {
        if ap_eq(maskc, c) && ap_is_power_of_2(ap_add_u64(c, 1)) {
            np := ifx pred == ICMP_EQ then cast(u8) ICMP_ULE else ICMP_UGT;
            return create_icmp(np, o0, o1);
        }
        if has_one_use(or) {
            a := icb_and(o0, const_int_ap(vtype(o0), ap_not(maskc)));
            nc := const_int_ap(vtype(or), ap_xor(c, maskc));
            return create_icmp(pred, a, nc);
        }
    }
    is_sb, true_if_signed := is_sign_bit_check(pred, c);
    if is_sb {
        for side: 0..1 {
            add := op(or, cast(u32) side); xv_ := op(or, cast(u32) (1 - side));
            oka, ax, m1 := pm_binop(add, .ADD);
            if oka && pm_all_ones(m1) && ax == xv_ {
                np := ifx true_if_signed then cast(u8) ICMP_SLT else ICMP_SGT;
                return create_icmp(np, ax, const_int_of(vtype(ax), ifx true_if_signed then cast(u64) 1 else 0));
            }
        }
    }
    {
        okc, orc := pm_apint(o1);
        if !ap_sign_bit(c) && okc {
            x := o0;
            if pred == ICMP_SLT || pred == ICMP_SGE {
                if ap_sge(orc, c) return create_icmp(pred, x, const_null_value(vtype(x)));
            } else if pred == ICMP_SLE || pred == ICMP_SGT {
                if ap_sgt(orc, c) return create_icmp(icmp_flipped_strictness(pred), x, const_null_value(vtype(x)));
            }
        }
    }
    if !icmp_is_equality(pred) || !ap_is_zero(c) || !has_one_use(or) return NONE;
    okp, p := pm_cast(o0, .PTRTOINT);
    okq, q := pm_cast(o1, .PTRTOINT);
    if okp && okq {
        cp := icb_cmp(pred, p, const_null_value(vtype(p)));
        cq := icb_cmp(pred, q, const_null_value(vtype(q)));
        return create_binop(ifx pred == ICMP_EQ then Opcode.AND else .OR, cp, cq);
    }
    v := ic_fold_icmp_or_xor_sub_chain(cmp, or);
    if v != NONE return ic_replace_inst_uses_with(cmp, v);
    return NONE;
}

// foldICmpMulConstant: icmp (mul X, Y), C
ic_fold_icmp_mul_constant :: (cmp: Value_Id, mul: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    mt := vtype(mul);
    x := op(mul, 0);
    if x == op(mul, 1) && !icmp_is_signed(pred) {
        r := ap_sqrt(c);
        is_sqr := ap_eq(c, ap_mul(r, r));
        if icmp_is_equality(pred) && (has_nuw(mul) || (has_nsw(mul) && ap_is_zero(c))) {
            if !is_sqr return ic_replace_inst_uses_with(cmp, cf_bool(vtype(cmp), pred == ICMP_NE));
            return create_icmp(pred, x, const_int_ap(mt, r));
        }
        if has_nuw(mul) {
            if is_sqr return create_icmp(pred, x, const_int_ap(mt, r));
            if pred == ICMP_ULT || pred == ICMP_ULE || pred == ICMP_SLT || pred == ICMP_SLE r = ap_add_u64(r, 1);
            return create_icmp(cmp_strict(pred), x, const_int_ap(mt, r));
        }
    }
    okm, mulc := pm_apint(op(mul, 1));
    if !okm return NONE;
    ok_st, st_pred := ic_is_sign_test(pred, c);   // isSignTest updates Pred even when the nsw check below fails
    pred = st_pred;
    if ok_st && has_nsw(mul) {
        p := pred;
        if ap_sign_bit(mulc) p = icmp_swapped(p);
        return create_icmp(p, x, const_null_value(mt));
    }
    if ap_is_zero(mulc) return NONE;
    if icmp_is_equality(pred) {
        if has_nsw(mul) && ap_is_zero(ap_srem(c, mulc)) return create_icmp(pred, x, const_int_ap(mt, ap_sdiv(c, mulc)));
        if ap_is_zero(ap_urem(c, mulc)) {
            if (ap_zext_value(ap_and(mulc, ap_one(mulc.bits))) == 1) || has_nuw(mul)
                return create_icmp(pred, x, const_int_ap(mt, ap_udiv(c, mulc)));
        }
    }
    new_c: Value_Id = NONE;
    p := pred;
    if has_nsw(mul) && icmp_is_signed(p) {
        if ap_is_min_signed(c) && ap_is_all_ones(mulc) return NONE;
        if ap_sign_bit(mulc) p = icmp_swapped(p);
        if p == ICMP_SLT || p == ICMP_SGE new_c = const_int_ap(mt, ap_rounding_sdiv(c, mulc, .UP));
        else new_c = const_int_ap(mt, ap_rounding_sdiv(c, mulc, .DOWN));
    } else if has_nuw(mul) && icmp_is_unsigned(p) {
        if p == ICMP_ULT || p == ICMP_UGE new_c = const_int_ap(mt, ap_rounding_udiv(c, mulc, .UP));
        else new_c = const_int_ap(mt, ap_rounding_udiv(c, mulc, .DOWN));
    }
    if new_c != NONE return create_icmp(p, x, new_c);
    return NONE;
}

// foldICmpShlLHSC: icmp (shl nuw C2, Y), C
ic_fold_icmp_shl_lhsc :: (cmp: Value_Id, shl: Value_Id, c: APInt) -> Value_Id {
    if opr_code(shl) != .SHL || (opr_flags(shl) & F_NUW) == 0 return NONE;
    ok2, c2 := pm_apint(op(shl, 0));
    if !ok2 return NONE;
    y := op(shl, 1);
    st := vtype(shl);
    type_bits := c.bits;
    pred := inst_pred(cmp);
    if icmp_is_unsigned(pred) {
        if ap_is_zero(c2) || ap_ugt(c2, c) return NONE;
        div, rem := ap_udivrem(c, c2);
        is_pow2 := ap_is_zero(rem) && ap_is_power_of_2(div);
        if !is_pow2 {
            if pred == ICMP_ULT pred = ICMP_ULE;
            else if pred == ICMP_UGE pred = ICMP_UGT;
        }
        return create_icmp(pred, y, const_int_of(st, cast(u64) ap_log2(div)));
    } else if icmp_is_signed(pred) && ap_is_one(c2) {
        bwm1 := const_int_of(st, cast(u64) (type_bits - 1));
        if pred == ICMP_SGT && ap_sle(c, ap_zero(c.bits)) return create_icmp(ICMP_NE, y, bwm1);
        if pred == ICMP_SLT && ap_sle(ap_sub_u64(c, 1), ap_zero(c.bits)) return create_icmp(ICMP_EQ, y, bwm1);
    }
    return NONE;
}

// Type::getWithNewBitWidth
type_with_new_bit_width :: (t: Type_Id, bits: u32) -> Type_Id {
    if is_vector_type(t) return vector_with_elt(t, type_int(bits));
    return type_int(bits);
}

// foldICmpShlConstant: icmp (shl X, Y), C
ic_fold_icmp_shl_constant :: (cmp: Value_Id, shl: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    okv, shift_val := pm_apint(op(shl, 0));
    if icmp_is_equality(pred) && okv return ic_fold_icmp_shl_const_const(cmp, op(shl, 1), c, shift_val);
    if ap_sle(c, ap_zero(c.bits)) && has_nuw(shl) && has_nsw(shl) return create_icmp(pred, op(shl, 0), op(cmp, 1));
    if icmp_is_equality(pred) && ap_is_zero(c) && (has_nuw(shl) || has_nsw(shl)) return create_icmp(pred, op(shl, 0), op(cmp, 1));
    if has_nsw(shl) && (pred == ICMP_SGT || pred == ICMP_SLT) {
        if ap_is_zero(c) || (ifx pred == ICMP_SGT then ap_is_all_ones(c) else ap_is_one(c)) return create_icmp(pred, op(shl, 0), op(cmp, 1));
    }
    oka, shift_amt := pm_apint(op(shl, 1));
    if !oka return ic_fold_icmp_shl_lhsc(cmp, shl, c);
    type_bits := c.bits;
    if ap_uge_u64(shift_amt, type_bits) return NONE;
    x := op(shl, 0);
    sht := vtype(shl);
    sa := cast(u32) ap_zext_value(shift_amt);
    if has_nsw(shl) {
        if pred == ICMP_SGT return create_icmp(pred, x, const_int_ap(sht, ap_ashr(c, sa)));
        if (pred == ICMP_EQ || pred == ICMP_NE) && ap_eq(ap_shl(ap_ashr(c, sa), sa), c) return create_icmp(pred, x, const_int_ap(sht, ap_ashr(c, sa)));
        if pred == ICMP_SLT return create_icmp(pred, x, const_int_ap(sht, ap_add_u64(ap_ashr(ap_sub_u64(c, 1), sa), 1)));
    }
    if has_nuw(shl) {
        if pred == ICMP_UGT return create_icmp(pred, x, const_int_ap(sht, ap_lshr(c, sa)));
        if (pred == ICMP_EQ || pred == ICMP_NE) && ap_eq(ap_shl(ap_lshr(c, sa), sa), c) return create_icmp(pred, x, const_int_ap(sht, ap_lshr(c, sa)));
        if pred == ICMP_ULT return create_icmp(pred, x, const_int_ap(sht, ap_add_u64(ap_lshr(ap_sub_u64(c, 1), sa), 1)));
    }
    if icmp_is_equality(pred) && has_one_use(shl) {
        mask := const_int_ap(sht, ap_low_bits_set(type_bits, type_bits - sa));
        a := icb_and(x, mask, tprint("%.mask", vname(shl)));
        return create_icmp(pred, a, const_int_ap(sht, ap_lshr(c, sa)));
    }
    is_sb, true_if_signed := is_sign_bit_check(pred, c);
    if has_one_use(shl) && is_sb {
        mask := const_int_ap(sht, ap_one_bit_set(type_bits, type_bits - sa - 1));
        a := icb_and(x, mask, tprint("%.mask", vname(shl)));
        return create_icmp(ifx true_if_signed then cast(u8) ICMP_NE else ICMP_EQ, a, const_null_value(sht));
    }
    if icmp_is_unsigned(pred) && has_one_use(shl) {
        if ap_is_power_of_2(ap_add_u64(c, 1)) && (pred == ICMP_ULE || pred == ICMP_UGT) {
            a := icb_and(x, const_int_ap(sht, ap_lshr(ap_not(c), sa)));
            return create_icmp(ifx pred == ICMP_ULE then cast(u8) ICMP_EQ else ICMP_NE, a, const_null_value(sht));
        }
        if ap_is_power_of_2(c) && (pred == ICMP_ULT || pred == ICMP_UGE) {
            a := icb_and(x, const_int_ap(sht, ap_lshr(ap_not(ap_sub_u64(c, 1)), sa)));
            return create_icmp(ifx pred == ICMP_ULT then cast(u8) ICMP_EQ else ICMP_NE, a, const_null_value(sht));
        }
    }
    amt := cast(u32) ap_limited(shift_amt, cast(u64) (type_bits - 1));
    if has_one_use(shl) && amt != 0 && ic_should_change_type_widths(scalar_bits(shl), type_bits - amt) {
        cmp_pred := pred;
        rhsc := c;
        if ap_ctz(rhsc) < amt && cmp_is_strict(cmp_pred) {
            ok, np, nc := flipped_strictness_predicate_and_constant(pred, const_int_ap(type_int(c.bits), c));
            if ok { cmp_pred = np; rhsc = const_ap(nc); }
        }
        if ap_ctz(rhsc) >= amt {
            trunc_ty := type_with_new_bit_width(sht, type_bits - amt);
            nc := const_int_ap(trunc_ty, ap_trunc(ap_ashr_ap(rhsc, shift_amt), type_bits - amt));
            return create_icmp(cmp_pred, icb_trunc(x, trunc_ty, "", false, has_nsw(shl)), nc);
        }
    }
    return NONE;
}

// foldICmpShrConstant: icmp ({al}shr X, Y), C
ic_fold_icmp_shr_constant :: (cmp: Value_Id, shr: Value_Id, c: APInt) -> Value_Id {
    x := op(shr, 0);
    pred := inst_pred(cmp);
    if icmp_is_equality(pred) && is_exact(shr) && ap_is_zero(c) return create_icmp(pred, x, op(cmp, 1));
    is_ashr := inst_op(shr) == .ASHR;
    okv, shift_val_c := pm_apint(x);
    if okv {
        if icmp_is_equality(pred) return ic_fold_icmp_shr_const_const(cmp, op(shr, 1), c, shift_val_c);
        is_sb, true_if_signed := is_sign_bit_check(pred, c);
        if !is_ashr && ap_sign_bit(shift_val_c) && is_sb
            return create_icmp(ifx true_if_signed then cast(u8) ICMP_EQ else ICMP_NE, op(shr, 1), const_null_value(vtype(x)));
        if !is_ashr && ap_is_power_of_2(shift_val_c) && (pred == ICMP_UGT || pred == ICMP_ULT) {
            is_ugt := pred == ICMP_UGT;
            cmp_lz := ifx is_ugt then ap_clz(c) else ap_clz(ap_sub_u64(c, 1));
            shift_lz := ap_clz(shift_val_c);
            nc := const_int_of(vtype(shr), cast(u64) (cmp_lz - shift_lz));
            return create_icmp(ifx is_ugt then cast(u8) ICMP_ULT else ICMP_UGE, op(shr, 1), nc);
        }
    }
    oka, shift_amt_c := pm_apint(op(shr, 1));
    if !oka return NONE;
    type_bits := c.bits;
    sh := cast(u32) ap_limited(shift_amt_c, cast(u64) type_bits);
    if sh >= type_bits || sh == 0 return NONE;
    exact := is_exact(shr);
    st := vtype(shr);
    c1 := ap_add_u64(c, 1);
    if is_ashr && has_one_use(shr) {
        if exact && (pred == ICMP_SLT || pred == ICMP_ULT) && ap_is_power_of_2(ap_sub_u64(c, 1)) && ap_clz(c) > sh
            return create_icmp(pred, x, const_int_ap(st, ap_add_u64(ap_shl(ap_sub_u64(c, 1), sh), 1)));
        if exact || pred == ICMP_SLT || pred == ICMP_ULT {
            shifted := ap_shl(c, sh);
            if ap_eq(ap_ashr(shifted, sh), c) return create_icmp(pred, x, const_int_ap(st, shifted));
        }
        if pred == ICMP_SGT {
            shifted := ap_sub_u64(ap_shl(c1, sh), 1);
            if !ap_is_max_signed(c) && !ap_is_min_signed(ap_shl(c1, sh)) && ap_eq(ap_ashr(ap_add_u64(shifted, 1), sh), c1)
                return create_icmp(pred, x, const_int_ap(st, shifted));
        }
        if pred == ICMP_UGT {
            shifted := ap_sub_u64(ap_shl(c1, sh), 1);
            if ap_eq(ap_ashr(ap_add_u64(shifted, 1), sh), c1) || ap_is_min_signed(ap_shl(c1, sh))
                return create_icmp(pred, x, const_int_ap(st, shifted));
        }
        if c.bits > 2 && ap_num_sign_bits(c) <= sh {
            if pred == ICMP_UGT return create_icmp(ICMP_SLT, x, const_null_value(st));
            if pred == ICMP_ULT return create_icmp(ICMP_SGT, x, const_all_ones_of(st));
        }
    } else if !is_ashr {
        if pred == ICMP_ULT || (pred == ICMP_UGT && exact) {
            shifted := ap_shl(c, sh);
            if ap_eq(ap_lshr(shifted, sh), c) return create_icmp(pred, x, const_int_ap(st, shifted));
        }
        if pred == ICMP_UGT {
            shifted := ap_sub_u64(ap_shl(c1, sh), 1);
            if ap_eq(ap_lshr(ap_add_u64(shifted, 1), sh), c1) return create_icmp(pred, x, const_int_ap(st, shifted));
        }
    }
    if !icmp_is_equality(pred) return NONE;
    if is_exact(shr) return create_icmp(pred, x, const_int_ap(st, ap_shl(c, sh)));
    if has_one_use(shr) {
        mask := const_int_ap(st, ap_high_bits_set(type_bits, type_bits - sh));
        a := icb_and(x, mask, tprint("%.mask", vname(shr)));
        return create_icmp(pred, a, const_int_ap(st, ap_shl(c, sh)));
    }
    return NONE;
}

// foldICmpSRemConstant
ic_fold_icmp_srem_constant :: (cmp: Value_Id, srem: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    ty := vtype(srem);
    if pred == ICMP_UGT || pred == ICMP_ULT {
        okd, divisor := pm_apint(op(srem, 1));
        if !okd return NONE;
        if ap_is_zero(divisor) return NONE;
        norm := c;
        if pred == ICMP_ULT norm = ap_sub_u64(norm, 1);
        if ap_sign_bit(c) norm = ap_not(norm);
        if !ap_uge(norm, ap_sub_u64(ap_abs(divisor), 1)) return NONE;
        if pred == ICMP_UGT return create_icmp(ICMP_SLT, srem, const_null_value(ty));
        return create_icmp(ICMP_SGT, srem, const_all_ones_of(ty));
    }
    if pred != ICMP_SGT && pred != ICMP_SLT && pred != ICMP_EQ && pred != ICMP_NE return NONE;
    if !has_one_use(srem) return NONE;
    okp, divisor := pm_power2_ap(op(srem, 1));
    if !okp return NONE;
    if ((pred == ICMP_SGT || pred == ICMP_SLT) && !ap_is_zero(c)) || ((pred == ICMP_EQ || pred == ICMP_NE) && !ap_is_strictly_positive(c)) return NONE;
    sign_mask := ap_signed_min(scalar_bits(srem));
    mask_c := const_int_ap(ty, ap_or(sign_mask, ap_sub_u64(divisor, 1)));
    a := icb_and(op(srem, 0), mask_c);
    if pred == ICMP_EQ || pred == ICMP_NE return create_icmp(pred, a, const_int_ap(ty, c));
    if pred == ICMP_SGT return create_icmp(ICMP_SGT, a, const_null_value(ty));
    return create_icmp(ICMP_UGT, a, const_int_ap(ty, sign_mask));
}

// foldICmpUDivConstant: icmp (udiv C2, Y), C
ic_fold_icmp_udiv_constant :: (cmp: Value_Id, udiv: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    x := op(udiv, 0); y := op(udiv, 1);
    ty := vtype(udiv);
    ok2, c2 := pm_apint(x);
    if !ok2 return NONE;
    if pred == ICMP_UGT return create_icmp(ICMP_ULE, y, const_int_ap(ty, ap_udiv(c2, ap_add_u64(c, 1))));
    if pred == ICMP_ULT return create_icmp(ICMP_UGT, y, const_int_ap(ty, ap_udiv(c2, c)));
    return NONE;
}

// foldICmpDivConstant: icmp ({su}div X, Y), C
ic_fold_icmp_div_constant :: (cmp: Value_Id, div: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    x := op(div, 0); y := op(div, 1);
    ty := vtype(div);
    div_signed := inst_op(div) == .SDIV;
    if icmp_is_equality(pred) && has_one_use(div) && ap_sign_bit(c) && (!div_signed || ap_is_min_signed(c)) {
        xbig := icb_cmp(pred, x, const_int_ap(ty, c));
        yone := icb_cmp(pred, y, const_int_of(ty, 1));
        return create_binop(ifx pred == ICMP_EQ then Opcode.AND else .OR, xbig, yone);
    }
    ok2, c2 := pm_apint(y);
    if !ok2 return NONE;
    if !icmp_is_equality(pred) && div_signed != icmp_is_signed(pred) {
        if !div_signed || !ap_is_strictly_positive(c2) || !is_known_non_negative(x, ic_q(cmp)) return NONE;
        div_signed = false;
    }
    if ap_is_zero(c2) || ap_is_one(c2) || (div_signed && ap_is_all_ones(c2)) return NONE;
    prod := ap_mul(c, c2);
    prod_ov := !ap_eq(ifx div_signed then ap_sdiv(prod, c2) else ap_udiv(prod, c2), c);
    range_size := ifx is_exact(div) then ap_one(c2.bits) else c2;
    lo_ov := 0; hi_ov := 0;
    lo, hi: APInt;
    ov: bool;
    if !div_signed {
        lo = prod;
        lo_ov = ifx prod_ov then 1 else 0; hi_ov = lo_ov;
        if !hi_ov { hi, ov = ap_uadd_ov(lo, range_size); hi_ov = ifx ov then 1 else 0; }
    } else if ap_is_strictly_positive(c2) {
        if ap_is_zero(c) {
            lo = ap_neg(ap_sub_u64(range_size, 1));
            hi = range_size;
        } else if ap_is_strictly_positive(c) {
            lo = prod;
            lo_ov = ifx prod_ov then 1 else 0; hi_ov = lo_ov;
            if !hi_ov { hi, ov = ap_sadd_ov(prod, range_size); hi_ov = ifx ov then 1 else 0; }
        } else {
            hi = ap_add_u64(prod, 1);
            lo_ov = ifx prod_ov then -1 else 0; hi_ov = lo_ov;
            if !lo_ov { lo, ov = ap_sadd_ov(hi, ap_neg(range_size)); lo_ov = ifx ov then -1 else 0; }
        }
    } else if ap_sign_bit(c2) {
        if is_exact(div) range_size = ap_neg(range_size);
        if ap_is_zero(c) {
            lo = ap_add_u64(range_size, 1);
            hi = ap_neg(range_size);
            if ap_eq(hi, c2) { hi_ov = 1; }
        } else if ap_is_strictly_positive(c) {
            hi = ap_add_u64(prod, 1);
            lo_ov = ifx prod_ov then -1 else 0; hi_ov = lo_ov;
            if !lo_ov { lo, ov = ap_sadd_ov(hi, range_size); lo_ov = ifx ov then -1 else 0; }
        } else {
            lo = prod;
            lo_ov = ifx prod_ov then 1 else 0; hi_ov = lo_ov;
            if !hi_ov { hi, ov = ap_ssub_ov(prod, range_size); hi_ov = ifx ov then 1 else 0; }
        }
        pred = icmp_swapped(pred);
    }
    if pred == {
        case ICMP_EQ;
            if lo_ov && hi_ov return ic_replace_inst_uses_with(cmp, get_false(vtype(cmp)));
            if hi_ov return create_icmp(ifx div_signed then cast(u8) ICMP_SGE else ICMP_UGE, x, const_int_ap(ty, lo));
            if lo_ov return create_icmp(ifx div_signed then cast(u8) ICMP_SLT else ICMP_ULT, x, const_int_ap(ty, hi));
            return ic_replace_inst_uses_with(cmp, ic_insert_range_test(x, lo, hi, div_signed, true));
        case ICMP_NE;
            if lo_ov && hi_ov return ic_replace_inst_uses_with(cmp, get_true(vtype(cmp)));
            if hi_ov return create_icmp(ifx div_signed then cast(u8) ICMP_SLT else ICMP_ULT, x, const_int_ap(ty, lo));
            if lo_ov return create_icmp(ifx div_signed then cast(u8) ICMP_SGE else ICMP_UGE, x, const_int_ap(ty, hi));
            return ic_replace_inst_uses_with(cmp, ic_insert_range_test(x, lo, hi, div_signed, false));
        case ICMP_ULT; #through;
        case ICMP_SLT;
            if lo_ov == 1 return ic_replace_inst_uses_with(cmp, get_true(vtype(cmp)));
            if lo_ov == -1 return ic_replace_inst_uses_with(cmp, get_false(vtype(cmp)));
            return create_icmp(pred, x, const_int_ap(ty, lo));
        case ICMP_UGT; #through;
        case ICMP_SGT;
            if hi_ov == 1 return ic_replace_inst_uses_with(cmp, get_false(vtype(cmp)));
            if hi_ov == -1 return ic_replace_inst_uses_with(cmp, get_true(vtype(cmp)));
            if pred == ICMP_UGT return create_icmp(ICMP_UGE, x, const_int_ap(ty, hi));
            return create_icmp(ICMP_SGE, x, const_int_ap(ty, hi));
    }
    fatal("internal: Unhandled icmp predicate!");
    return NONE;
}

// foldICmpSubConstant: icmp (sub X, Y), C
ic_fold_icmp_sub_constant :: (cmp: Value_Id, sub: Value_Id, c: APInt) -> Value_Id {
    x := op(sub, 0); y := op(sub, 1);
    pred := inst_pred(cmp);
    ty := vtype(sub);
    if icmp_is_equality(pred) && pm_imm_constant(x)
        return create_icmp(pred, y, cfo_constant(ce_binop(.SUB, x, const_int_ap(ty, c), 0)));
    swapped := icmp_swapped(pred);
    nsw := has_nsw(sub); nuw := has_nuw(sub);
    ok2, c2 := pm_apint(x);
    if ok2 && ((icmp_is_unsigned(pred) && nuw) || (icmp_is_signed(pred) && nsw)) {
        res: APInt; ov: bool;
        if icmp_is_signed(pred) { res, ov = ap_ssub_ov(c2, c); } else { res, ov = ap_usub_ov(c2, c); }
        if !ov return create_icmp(swapped, y, const_int_ap(ty, res));
    }
    if icmp_is_equality(pred) && ap_is_zero(c) {
        any_phi := false;
        u := ir.v_first_use[sub];
        while u != NONE { us := ir.u_user[u]; if is_inst(us) && inst_op(us) == .PHI { any_phi = true; break; } u = ir.u_next[u]; }
        if !any_phi return create_icmp(pred, x, y);
    }
    if !has_one_use(sub) return NONE;
    if nsw {
        if pred == ICMP_SGT && ap_is_all_ones(c) return create_icmp(ICMP_SGE, x, y);
        if pred == ICMP_SGT && ap_is_zero(c) return create_icmp(ICMP_SGT, x, y);
        if pred == ICMP_SLT && ap_is_zero(c) return create_icmp(ICMP_SLT, x, y);
        if pred == ICMP_SLT && ap_is_one(c) return create_icmp(ICMP_SLE, x, y);
    }
    if !ok2 return NONE;
    cm1 := ap_sub_u64(c, 1);
    if pred == ICMP_ULT && ap_is_power_of_2(c) && ap_eq(ap_and(c2, cm1), cm1)
        return create_icmp(ICMP_EQ, icb_or(y, const_int_ap(ty, cm1)), x);
    if pred == ICMP_UGT && ap_is_power_of_2(ap_add_u64(c, 1)) && ap_eq(ap_and(c2, c), c)
        return create_icmp(ICMP_NE, icb_or(y, const_int_ap(ty, c)), x);
    add := icb_add(y, const_int_ap(ty, ap_not(c2)), "notsub", nuw, nsw);
    return create_icmp(swapped, add, const_int_ap(ty, ap_not(c)));
}

// createLogicFromTable
ic_create_logic_from_table :: (table: u32, op0: Value_Id, op1: Value_Id, has_one_use: bool) -> Value_Id {
    fold_constant :: (val: bool, t: Type_Id) -> Value_Id {
        r := ic_bool_const(ir.t_i1, val);
        if is_vector_type(t) r = cf_get_splat(make_cmp_result_type(t), r);
        return r;
    }
    if table == {
        case 0; return fold_constant(false, vtype(op0));
        case 1; return ifx has_one_use then icb_not(icb_or(op0, op1)) else NONE;
        case 2; return ifx has_one_use then icb_and(icb_not(op0), op1) else NONE;
        case 3; return icb_not(op0);
        case 4; return ifx has_one_use then icb_and(op0, icb_not(op1)) else NONE;
        case 5; return icb_not(op1);
        case 6; return icb_xor(op0, op1);
        case 7; return ifx has_one_use then icb_not(icb_and(op0, op1)) else NONE;
        case 8; return icb_and(op0, op1);
        case 9; return ifx has_one_use then icb_not(icb_xor(op0, op1)) else NONE;
        case 10; return op1;
        case 11; return ifx has_one_use then icb_or(icb_not(op0), op1) else NONE;
        case 12; return op0;
        case 13; return ifx has_one_use then icb_or(op0, icb_not(op1)) else NONE;
        case 14; return icb_or(op0, op1);
        case 15; return fold_constant(true, vtype(op0));
    }
    fatal("internal: Invalid Operation");
    return NONE;
}

// foldICmpBinOpWithConstantViaTruthTable
ic_fold_icmp_binop_with_constant_via_truth_table :: (cmp: Value_Id, bo: Value_Id, c: APInt) -> Value_Id {
    ok1, a, c1, c2 := pm_select_like_consts(op(bo, 0));
    if !ok1 return NONE;
    ok2, b, c3, c4 := pm_select_like_consts(op(bo, 1));
    if !ok2 || vtype(cmp) != vtype(a) || vtype(cmp) != vtype(b) return NONE;
    table: u32 = 0;
    for i: 0..3 {
        first := ((i >> 1) & 1) != 0;
        second := (i & 1) != 0;
        l := ifx first then c1 else c2;
        r := ifx second then c3 else c4;
        res := cfo_binary_op_operands(inst_op(bo), l, r);
        if res == NONE return NONE;
        val := res;
        if is_vector_type(vtype(res)) val = get_splat_value(res);
        if val == NONE || vkind(val) != .C_INT return NONE;
        if icmp_compare(const_ap(val), c, inst_pred(cmp)) table |= (cast(u32) 1) << cast(u32) i;
    }
    cond := ic_create_logic_from_table(table, a, b, has_one_use(bo));
    if cond != NONE return ic_replace_inst_uses_with(cmp, cond);
    return NONE;
}

// foldICmpAddConstant: icmp (add X, Y), C
ic_fold_icmp_add_constant :: (cmp: Value_Id, add: Value_Id, c: APInt) -> Value_Id {
    y := op(add, 1); x := op(add, 0);
    pred := inst_pred(cmp);
    samesign := (inst(cmp).flags & F_EXACT) != 0;
    bw := c.bits;
    if pred == ICMP_ULT && has_nuw(add) {
        for side: 0..1 {
            a := op(add, cast(u32) side); sh := op(add, cast(u32) (1 - side));
            if !(ic_is_binop(sh, .LSHR) && op(sh, 0) == a) continue;
            oks, sh_amt := pm_apint(op(sh, 1));
            if !oks continue;
            if ap_ult_u64(sh_amt, bw) && ap_ule(c, ap_one_bit_set(bw, cast(u32) ap_zext_value(sh_amt))) return create_icmp(pred, a, const_int_ap(vtype(a), c));
            break;
        }
    }
    ok2, c2 := pm_apint(y);
    if icmp_is_equality(pred) || !ok2 return NONE;
    ty := vtype(add);
    if has_nuw(add) && (pred == ICMP_UGT || pred == ICMP_ULT) {
        nc, ov := ap_usub_ov(c, c2);
        if !ov return create_icmp(pred, x, const_int_ap(ty, nc));
    }
    chosen := icmp_preferred_signed_predicate(pred, samesign);
    if has_nsw(add) && (chosen == ICMP_SGT || chosen == ICMP_SLT) {
        nc, ov := ap_ssub_ov(c, c2);
        if !ov return create_icmp(chosen, x, const_int_ap(ty, nc));
    }
    if icmp_is_unsigned(pred) && has_nsw(add) && !ap_sign_bit(c) && !ap_sign_bit(ap_sub(c, c2)) &&
       cr_is_all_non_negative(cr_add(compute_constant_range(x, true, ic_q(cmp)), cr_single(c2)))
        return create_icmp(icmp_signed_predicate(pred), x, const_int_ap(ty, ap_sub(c, c2)));
    cr := cr_subtract(cr_exact_icmp_region(pred, c), c2);
    upper := cr.hi; lower := cr.lo;
    if icmp_is_signed(pred) {
        if ap_is_sign_mask(lower) return create_icmp(ICMP_SLT, x, const_int_ap(ty, upper));
        if ap_is_sign_mask(upper) return create_icmp(ICMP_SGE, x, const_int_ap(ty, lower));
    } else {
        if ap_is_zero(lower) return create_icmp(ICMP_ULT, x, const_int_ap(ty, upper));
        if ap_is_zero(upper) return create_icmp(ICMP_UGE, x, const_int_ap(ty, lower));
    }
    smax := ap_signed_max(scalar_bits(add));
    smin := ap_signed_min(scalar_bits(add));
    if pred == ICMP_UGT && ap_eq(c, ap_add(c2, smax)) return create_icmp(ICMP_SLT, x, const_int_ap(ty, ap_neg(c2)));
    if pred == ICMP_ULT && ap_eq(c, ap_add(c2, smin)) return create_icmp(ICMP_SGT, x, const_int_ap(ty, ap_not(c2)));
    if pred == ICMP_SGT && ap_eq(c, ap_sub_u64(c2, 1)) return create_icmp(ICMP_ULT, x, const_int_ap(ty, ap_sub(smax, c)));
    if pred == ICMP_SLT && ap_eq(c, c2) return create_icmp(ICMP_UGT, x, const_int_ap(ty, ap_xor(c, smax)));
    if pred == ICMP_ULT && ap_is_all_ones(c2) {
        if is_known_non_zero(x, ic_q(cmp)) return create_icmp(ICMP_ULE, x, const_int_ap(ty, c));
    }
    if !has_one_use(add) return NONE;
    if pred == ICMP_ULT && ap_is_power_of_2(c) && ap_is_zero(ap_and(c2, ap_sub_u64(c, 1)))
        return create_icmp(ICMP_EQ, icb_and(x, const_int_ap(ty, ap_neg(c))), cfo_constant(ce_neg(y)));
    if pred == ICMP_ULT && ap_is_power_of_2(c2) && ap_eq(c, ap_neg(c2))
        return create_icmp(ICMP_NE, icb_and(x, const_int_ap(ty, c)), const_int_ap(ty, ap_shl(c, 1)));
    if pred == ICMP_UGT && ap_is_power_of_2(ap_add_u64(c, 1)) && ap_is_zero(ap_and(c2, c))
        return create_icmp(ICMP_NE, icb_and(x, const_int_ap(ty, ap_not(c))), cfo_constant(ce_neg(y)));
    if pred == ICMP_UGT
        return create_icmp(ICMP_ULT, icb_add(x, const_int_ap(ty, ap_sub_u64(ap_sub(c2, c), 1))), const_int_ap(ty, ap_not(c)));
    okz, v := pmi_cast(x, .ZEXT);
    if okz {
        nt := vtype(v);
        nbw := scalar_bits(v);
        if ic_should_change_type(ty, nt) {
            src_cr := cr_truncate(cr, nbw, true);
            ep, ei, eo := cr_equivalent_icmp(src_cr);
            lhs := ifx ap_is_zero(eo) then v else icb_add(v, const_int_ap(nt, eo));
            return create_icmp(ep, lhs, const_int_ap(nt, ei));
        }
    }
    return NONE;
}

// matchThreeWayIntCompare: (ok, lhs, rhs, less, equal, greater)
ic_match_three_way_int_compare :: (si: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id, Value_Id, Value_Id) {
    okc, pa, _, lhs, rhs := pm_icmp(op(si, 0));
    if !okc || !icmp_is_equality(pa) return false, NONE, NONE, NONE, NONE, NONE;
    eq_val := op(si, 1); ne_val := op(si, 2);
    if pa == ICMP_NE { t := eq_val; eq_val = ne_val; ne_val = t; }
    if vkind(eq_val) != .C_INT return false, NONE, NONE, NONE, NONE, NONE;
    equal := eq_val;
    oks, sc, less, greater := pm_select(ne_val);
    if !oks || vkind(less) != .C_INT || vkind(greater) != .C_INT return false, NONE, NONE, NONE, NONE, NONE;
    okb, pb, _, lhs2, rhs2 := pm_icmp(sc);
    if !okb return false, NONE, NONE, NONE, NONE, NONE;
    if lhs2 != lhs { t := lhs2; lhs2 = rhs2; rhs2 = t; pb = icmp_swapped(pb); }
    if lhs2 != lhs return false, NONE, NONE, NONE, NONE, NONE;
    if pb == ICMP_SGT && is_const(rhs2) {
        okf, np, nc := flipped_strictness_predicate_and_constant(pb, rhs2);
        if !okf return false, NONE, NONE, NONE, NONE, NONE;
        rhs2 = nc;
        t := less; less = greater; greater = t;
        pb = ICMP_SLT;
    }
    return pb == ICMP_SLT && rhs == rhs2, lhs, rhs, less, equal, greater;
}

// foldICmpSelectConstant
ic_fold_icmp_select_constant :: (cmp: Value_Id, sel: Value_Id, c: Value_Id) -> Value_Id {
    if !has_one_use(cmp) return NONE;
    ok, ol, orr, lt, eq, gt := ic_match_three_way_int_compare(sel);
    if !ok return NONE;
    pred := inst_pred(cmp);
    cv := const_ap(c);
    t_lt := icmp_compare(const_ap(lt), cv, pred);
    t_eq := icmp_compare(const_ap(eq), cv, pred);
    t_gt := icmp_compare(const_ap(gt), cv, pred);
    cond := get_false(ir.t_i1);
    if t_lt cond = icb_or(cond, icb_cmp(ICMP_SLT, ol, orr));
    if t_eq cond = icb_or(cond, icb_cmp(ICMP_EQ, ol, orr));
    if t_gt cond = icb_or(cond, icb_cmp(ICMP_SGT, ol, orr));
    return ic_replace_inst_uses_with(cmp, cond);
}

// APInt::isSplat(SplatSizeInBits)
ap_is_splat :: (a: APInt, n: u32) -> bool { return ap_eq(a, ap_rotl(a, n)); }

// foldICmpBitCast
ic_fold_icmp_bitcast :: (cmp: Value_Id) -> Value_Id {
    bc := op(cmp, 0);
    if !(is_inst(bc) && inst_op(bc) == .BITCAST) return NONE;
    pred := inst_pred(cmp);
    op1 := op(cmp, 1);
    src := op(bc, 0);
    src_ty := vtype(src); dst_ty := vtype(bc);
    if is_vector_type(src_ty) == is_vector_type(dst_ty) && type_bits(scalar_type(src_ty)) == type_bits(scalar_type(dst_ty)) {
        oks, x := pmi_cast(src, .SITOFP);
        if oks {
            if (pred == ICMP_EQ || pred == ICMP_SLT || pred == ICMP_NE || pred == ICMP_SGT) && pm_zero(op1)
                return create_icmp(pred, x, const_null_value(vtype(x)));
            if pred == ICMP_SLT && pm_one(op1) return create_icmp(pred, x, const_int_of(vtype(x), 1));
            if pred == ICMP_SGT && pm_all_ones(op1) return create_icmp(pred, x, const_all_ones_of(vtype(x)));
        }
        oku, ux := pmi_cast(src, .UITOFP);
        if oku && icmp_is_equality(pred) && pm_zero(op1) return create_icmp(pred, ux, const_null_value(vtype(ux)));
        okc, c := pm_apint(op1);
        if okc && has_one_use(bc) {
            is_sb, true_if_signed := is_sign_bit_check(pred, c);
            if is_sb {
                okx, fx := pmi_cast(src, .FPEXT);
                if !okx okx, fx = pmi_cast(src, .FPTRUNC);
                if okx {
                    xt := vtype(fx);
                    if !(type_kind(scalar_type(xt)) == .PPC_FP128 || type_kind(scalar_type(src_ty)) == .PPC_FP128) {
                        nt := type_int(type_bits(scalar_type(xt)));
                        if is_vector_type(xt) nt = vector_with_elt(xt, nt);
                        nb := icb_cast(.BITCAST, fx, nt);
                        if true_if_signed return create_icmp(ICMP_SLT, nb, const_null_value(nt));
                        return create_icmp(ICMP_SGT, nb, const_all_ones_of(nt));
                    }
                }
            }
            fpt := scalar_type(src_ty);
            if !fn_has_fn_attr(inst_fn(cmp), .NoImplicitFloat) && icmp_is_equality(pred) && ic_is_ieee_like_fp_ty(fpt) {
                mask := apf_classify(apf_from_words(type_kind(fpt), ap_words(c)));
                if (mask & cast(u32) (FC_INF | FC_ZERO)) != 0 {
                    if pred == ICMP_NE mask = ~mask & FC_ALL_FLAGS;
                    return ic_replace_inst_uses_with(cmp, icb_is_fpclass(src, mask));
                }
            }
        }
    }
    okc, c := pm_apint(op(cmp, 1));
    if !okc || !is_int_type(dst_ty) || !is_int_or_int_vector(src_ty) return NONE;
    if icmp_is_equality(pred) && ap_is_all_ones(c) && has_one_use(bc) {
        not_src := ic_get_freely_inverted(src, has_one_use(src), true);
        if not_src != NONE {
            cst := icb_cast(.BITCAST, not_src, dst_ty);
            return create_icmp(pred, cst, const_null_value(dst_ty));
        }
    }
    if icmp_is_equality(pred) && ap_is_zero(c) && has_one_use(bc) {
        okx, x := pmi_zext_or_sext(src);
        if okx && type_kind(vtype(x)) == .VECTOR {
            nt := type_int(cast(u32) ic_primitive_size_bits(vtype(x)));
            nc := icb_cast(.BITCAST, x, nt);
            return create_icmp(pred, nc, const_null_value(nt));
        }
    }
    oksh, vec, v2, mask := pm_shuffle(src);
    if oksh && pm_undef(v2) {
        all_eq := true;
        for mask if it != mask[0] { all_eq = false; break; }
        if all_eq {
            elt_ty := scalar_type(src_ty);
            eb := type_bits(elt_ty);
            if ap_is_splat(c, eb) {
                ext := icb_extract_element(vec, const_int_of(ir.t_i64, cast(u64) mask[0]));
                nc := const_int_ap(elt_ty, ap_trunc(c, eb));
                return create_icmp(pred, ext, nc);
            }
        }
    }
    return NONE;
}

// foldICmpInstWithConstant: icmp Pred X, C where X is an instruction
ic_fold_icmp_inst_with_constant :: (cmp: Value_Id) -> Value_Id {
    okc, c := pm_apint(op(cmp, 1));
    o0 := op(cmp, 0);
    if okc {
        if is_inst(o0) && is_binary_operator(o0) {
            r := ic_fold_icmp_binop_with_constant(cmp, o0, c); if r != NONE return r;
        }
        if is_inst(o0) && inst_op(o0) == .SELECT && vkind(op(cmp, 1)) == .C_INT && !is_vector_type(vtype(op(cmp, 1))) {
            r := ic_fold_icmp_select_constant(cmp, o0, op(cmp, 1)); if r != NONE return r;
        }
        if is_inst(o0) && inst_op(o0) == .TRUNC {
            r := ic_fold_icmp_trunc_constant(cmp, o0, c); if r != NONE return r;
        }
        if call_iid(o0) != NOT_INTRINSIC {
            r := ic_fold_icmp_intrinsic_with_constant(cmp, o0, c); if r != NONE return r;
        }
        if ap_is_zero(c) && icmp_is_equality(inst_pred(cmp)) && has_one_use(o0) && is_inst(o0) && inst_op(o0) == .EXTRACTVALUE {
            idx := inst_indices(o0);
            agg := op(o0, 0);
            id := call_iid(agg);
            if idx.count == 1 && idx[0] == 0 && (id == IID_SSUB_WITH_OVERFLOW || id == IID_USUB_WITH_OVERFLOW)
                return create_icmp(inst_pred(cmp), op(agg, 0), op(agg, 1));
        }
    }
    okp, cp := pm_apint_ap(op(cmp, 1));
    if okp return ic_fold_icmp_inst_with_constant_allow_poison(cmp, cp);
    return NONE;
}

// foldICmpBinOpEqualityWithConstant: icmp eq/ne BO, C
ic_fold_icmp_binop_equality_with_constant :: (cmp: Value_Id, bo: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    if !icmp_is_equality(pred) return NONE;
    is_ne := pred == ICMP_NE;
    rhs := op(cmp, 1);
    b0 := op(bo, 0); b1 := op(bo, 1);
    ty := vtype(bo);
    o := inst_op(bo);
    if o == {
        case .SREM;
            if ap_is_zero(c) && has_one_use(bo) {
                okb, boc := pm_apint(b1);
                if okb && ap_sgt(boc, ap_one(boc.bits)) && ap_is_power_of_2(boc) {
                    nr := icb_binop(.UREM, b0, b1, name_ref(vname(bo)));
                    return create_icmp(pred, nr, const_null_value(ty));
                }
            }
        case .ADD;
            if is_const(b1) {
                if has_one_use(bo) return create_icmp(pred, b0, cfo_constant(ce_binop(.SUB, rhs, b1, 0)));
            } else if ap_is_zero(c) {
                nv := ic_dyn_cast_neg_val(b1);
                if nv != NONE return create_icmp(pred, b0, nv);
                nv = ic_dyn_cast_neg_val(b0);
                if nv != NONE return create_icmp(pred, nv, b1);
                if has_one_use(bo) {
                    if has_nuw(bo) {
                        or := icb_or(b0, b1);
                        return create_icmp(pred, or, const_null_value(ty));
                    }
                    neg := icb_neg(b1);
                    ic_take_name(neg, bo);
                    return create_icmp(pred, b0, neg);
                }
            }
        case .XOR;
            if is_const(b1) return create_icmp(pred, b0, cfo_constant(ce_binop(.XOR, rhs, b1, 0)));
            else if ap_is_zero(c) return create_icmp(pred, b0, b1);
        case .OR;
            okb, boc := pm_apint(b1);
            if okb && has_one_use(bo) && cf_is_all_ones(rhs) {
                not_boc := cfo_constant(ce_not(b1));
                a := icb_and(b0, not_boc);
                return create_icmp(pred, a, not_boc);
            }
            if ap_is_zero(c) && has_one_use(bo) {
                for side: 0..1 {
                    sel := op(bo, cast(u32) side); other := op(bo, cast(u32) (1 - side));
                    oks, cond, tv, fv := pm_select(sel);
                    if !oks continue;
                    if vtype(cond) != vtype(cmp) break;
                    q := ic_q(cmp);
                    if ifx pred == ICMP_EQ then (pm_zero(tv) && is_known_non_zero(fv, q)) else (pm_zero(fv) && is_known_non_zero(tv, q)) {
                        nc := icb_cmp(pred, other, const_null_value(vtype(other)));
                        return create_binop(ifx pred == ICMP_EQ then Opcode.AND else .OR, nc, cond);
                    }
                    if has_one_use(sel) && (ifx pred == ICMP_EQ then (pm_zero(fv) && is_known_non_zero(tv, q)) else (pm_zero(tv) && is_known_non_zero(fv, q))) {
                        not_cond := icb_not(cond);
                        nc := icb_cmp(pred, other, const_null_value(vtype(other)));
                        return create_binop(ifx pred == ICMP_EQ then Opcode.AND else .OR, nc, not_cond);
                    }
                    break;
                }
            }
        case .UDIV; #through;
        case .SDIV;
            if is_exact(bo) {
                if ap_is_zero(c) return create_icmp(pred, b0, const_null_value(ty));
                else if ap_is_one(c) return create_icmp(pred, b0, b1);
                else if has_one_use(bo) {
                    r := ic_compute_overflow(.MUL, o == .SDIV, b1, op(cmp, 1), bo);
                    if r == .NEVER_OVERFLOWS {
                        yc := icb_mul(b1, const_int_ap(ty, c));
                        return create_icmp(pred, yc, b0);
                    }
                }
            }
            if o == .UDIV && ap_is_zero(c) return create_icmp(ifx is_ne then cast(u8) ICMP_ULE else ICMP_UGT, b1, b0);
    }
    return NONE;
}

// foldCtpopPow2Test
ic_fold_ctpop_pow2_test :: (i: Value_Id, ctpop: Value_Id, crhs: APInt, q: Simplify_Query) -> Value_Id {
    if !has_one_use(ctpop) return NONE;
    pred := inst_pred(i);
    if ((icmp_is_equality(pred) || pred == ICMP_UGT) && ap_eq_u64(crhs, 1)) || (pred == ICMP_ULT && ap_eq_u64(crhs, 2)) {
        o := op(ctpop, 0);
        qq: Simplify_Query; qq.dt = q.dt; qq.ac = q.ac; qq.cxt = q.cxt;
        k := known_bits(o, qq);
        if kb_count_min_population(k) == 1 {
            a := icb_and(o, const_int_ap(vtype(o), ap_not(k.one)));
            return create_icmp(ifx pred == ICMP_EQ || pred == ICMP_ULT then cast(u8) ICMP_EQ else ICMP_NE, a, const_null_value(vtype(o)));
        }
    }
    return NONE;
}

// foldICmpEqIntrinsicWithConstant
ic_fold_icmp_eq_intrinsic_with_constant :: (cmp: Value_Id, ii: Value_Id, c: APInt) -> Value_Id {
    ty := vtype(ii);
    bw := c.bits;
    pred := inst_pred(cmp);
    id := call_iid(ii);
    a0 := op(ii, 0);
    if id == IID_ABS {
        if ap_is_zero(c) || ap_is_min_signed(c) return create_icmp(pred, a0, const_int_ap(ty, c));
    } else if id == IID_BSWAP {
        return create_icmp(pred, a0, const_int_ap(ty, ap_byte_swap(c)));
    } else if id == IID_BITREVERSE {
        return create_icmp(pred, a0, const_int_ap(ty, ap_reverse_bits(c)));
    } else if id == IID_CTLZ || id == IID_CTTZ {
        if ap_eq_u64(c, bw) return create_icmp(pred, a0, const_null_value(ty));
        num := cast(u32) ap_limited(c, cast(u64) bw);
        if num != bw && has_one_use(ii) {
            trailing := id == IID_CTTZ;
            mask1 := ifx trailing then ap_low_bits_set(bw, num + 1) else ap_high_bits_set(bw, num + 1);
            mask2 := ifx trailing then ap_one_bit_set(bw, num) else ap_one_bit_set(bw, bw - num - 1);
            return create_icmp(pred, icb_and(a0, const_int_ap(ty, mask1)), const_int_ap(ty, mask2));
        }
    } else if id == IID_CTPOP {
        is_zero := ap_is_zero(c);
        if is_zero || ap_eq_u64(c, bw) return create_icmp(pred, a0, ifx is_zero then const_null_value(ty) else const_all_ones_of(ty));
    } else if id == IID_FSHL || id == IID_FSHR {
        if a0 == op(ii, 1) {
            okr, rot := pm_apint(op(ii, 2));
            if okr {
                amt := cast(u32) ap_urem_u64(rot, cast(u64) bw);
                return create_icmp(pred, a0, const_int_ap(ty, ifx id == IID_FSHL then ap_rotr(c, amt) else ap_rotl(c, amt)));
            }
        }
    } else if id == IID_UMAX || id == IID_UADD_SAT {
        if ap_is_zero(c) && has_one_use(ii) {
            or := icb_or(a0, op(ii, 1));
            return create_icmp(pred, or, const_null_value(ty));
        }
    } else if id == IID_SSUB_SAT {
        if ap_is_zero(c) && scalar_bits(ii) > 1 return create_icmp(pred, a0, op(ii, 1));
    } else if id == IID_USUB_SAT {
        if ap_is_zero(c) return create_icmp(ifx pred == ICMP_EQ then cast(u8) ICMP_ULE else ICMP_UGT, a0, op(ii, 1));
    }
    return NONE;
}

// foldICmpIntrinsicWithIntrinsic
ic_fold_icmp_intrinsic_with_intrinsic :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    o0 := op(cmp, 0); o1 := op(cmp, 1);
    id0 := call_iid(o0); id1 := call_iid(o1);
    if id0 == NOT_INTRINSIC || id1 == NOT_INTRINSIC || id0 != id1 return NONE;
    if id0 == IID_BSWAP || id0 == IID_BITREVERSE return create_icmp(pred, op(o0, 0), op(o1, 0));
    if id0 == IID_FSHL || id0 == IID_FSHR {
        if op(o0, 0) != op(o0, 1) return NONE;
        if op(o1, 0) != op(o1, 1) return NONE;
        if op(o0, 2) == op(o1, 2) return create_icmp(pred, op(o0, 0), op(o1, 0));
        one_uses := cast(int) has_one_use(o0) + cast(int) has_one_use(o1);
        if one_uses == 2 || (one_uses == 1 && pm_imm_constant(op(o0, 2)) && pm_imm_constant(op(o1, 2))) {
            sub_amt := icb_sub(op(o0, 2), op(o1, 2));
            comb := icb_intrinsic(id0, .[vtype(o0)], .[op(o0, 0), op(o0, 0), sub_amt]);
            return create_icmp(pred, op(o1, 0), comb);
        }
    }
    return NONE;
}

// foldICmpInstWithConstantAllowPoison
ic_fold_icmp_inst_with_constant_allow_poison :: (cmp: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    ii := op(cmp, 0);
    id := call_iid(ii);
    if id == IID_FSHL || id == IID_FSHR {
        if icmp_is_equality(pred) && op(ii, 0) == op(ii, 1) {
            if ap_is_zero(c) || ap_is_all_ones(c) return create_icmp(pred, op(ii, 0), op(cmp, 1));
        }
    }
    return NONE;
}

// foldICmpBinOpWithConstant: icmp Pred BO, C
ic_fold_icmp_binop_with_constant :: (cmp: Value_Id, bo: Value_Id, c: APInt) -> Value_Id {
    r: Value_Id = NONE;
    o := inst_op(bo);
    if o == {
        case .XOR; r = ic_fold_icmp_xor_constant(cmp, bo, c);
        case .AND; r = ic_fold_icmp_and_constant(cmp, bo, c);
        case .OR; r = ic_fold_icmp_or_constant(cmp, bo, c);
        case .MUL; r = ic_fold_icmp_mul_constant(cmp, bo, c);
        case .SHL; r = ic_fold_icmp_shl_constant(cmp, bo, c);
        case .LSHR; #through;
        case .ASHR; r = ic_fold_icmp_shr_constant(cmp, bo, c);
        case .SREM; r = ic_fold_icmp_srem_constant(cmp, bo, c);
        case .UDIV;
            r = ic_fold_icmp_udiv_constant(cmp, bo, c);
            if r == NONE r = ic_fold_icmp_div_constant(cmp, bo, c);
        case .SDIV; r = ic_fold_icmp_div_constant(cmp, bo, c);
        case .SUB; r = ic_fold_icmp_sub_constant(cmp, bo, c);
        case .ADD; r = ic_fold_icmp_add_constant(cmp, bo, c);
    }
    if r != NONE return r;
    r = ic_fold_icmp_binop_equality_with_constant(cmp, bo, c); if r != NONE return r;
    return ic_fold_icmp_binop_with_constant_via_truth_table(cmp, bo, c);
}

// foldICmpUSubSatOrUAddSatWithConstant
ic_fold_icmp_usub_sat_or_uadd_sat_with_constant :: (pred: u8, ii: Value_Id, c: APInt) -> Value_Id {
    if !has_one_use(ii) return NONE;
    op0 := op(ii, 0); op1 := op(ii, 1);
    okc, cop1 := pm_apint(op1);
    if !okc return NONE;
    id := call_iid(ii);
    sat_val := ifx id == IID_UADD_SAT then ap_all_ones(c.bits) else ap_zero(c.bits);
    bin_op: Opcode = ifx id == IID_UADD_SAT then Opcode.ADD else .SUB;
    sat_check := icmp_compare(sat_val, c, pred);
    c1 := cr_guaranteed_no_wrap_region(bin_op, cr_single(cop1), true);
    if sat_check c1 = cr_inverse(c1);
    c2 := cr_exact_icmp_region(pred, c);
    if bin_op == .ADD c2 = cr_sub(c2, cr_single(cop1)); else c2 = cr_add(c2, cr_single(cop1));
    ok: bool; comb: Const_Range;
    if sat_check { ok, comb = cr_exact_union(c1, c2); }
    else { ok, comb = cr_exact_intersect(c1, c2); }
    if !ok return NONE;
    ep, ei, eo := cr_equivalent_icmp(comb);
    return create_icmp(ep, icb_add(op0, const_int_ap(vtype(op1), eo)), const_int_ap(vtype(op1), ei));
}

// foldICmpOfCmpIntrinsicWithConstant
ic_fold_icmp_of_cmp_intrinsic_with_constant :: (pred: u8, i: Value_Id, c: APInt) -> Value_Id {
    np: u8 = 255;
    if pred == {
        case ICMP_EQ; #through;
        case ICMP_NE;
            if ap_is_zero(c) np = pred;
            else if ap_is_one(c) np = ifx pred == ICMP_EQ then cast(u8) ICMP_UGT else ICMP_ULE;
            else if ap_is_all_ones(c) np = ifx pred == ICMP_EQ then cast(u8) ICMP_ULT else ICMP_UGE;
        case ICMP_SGT;
            if ap_is_all_ones(c) np = ICMP_UGE; else if ap_is_zero(c) np = ICMP_UGT;
        case ICMP_SLT;
            if ap_is_zero(c) np = ICMP_ULT; else if ap_is_one(c) np = ICMP_ULE;
        case ICMP_ULT;
            if ap_ugt_u64(c, 1) np = ICMP_UGE;
        case ICMP_UGT;
            if !ap_is_zero(c) && !ap_is_all_ones(c) np = ICMP_ULT;
    }
    if np == 255 return NONE;
    if call_iid(i) == IID_SCMP np = icmp_signed_predicate(np);
    return create_icmp(np, op(i, 0), op(i, 1));
}

// foldICmpIntrinsicWithConstant: icmp Pred II, C
ic_fold_icmp_intrinsic_with_constant :: (cmp: Value_Id, ii: Value_Id, c: APInt) -> Value_Id {
    pred := inst_pred(cmp);
    id := call_iid(ii);
    if id == IID_UADD_SAT || id == IID_USUB_SAT {
        r := ic_fold_icmp_usub_sat_or_uadd_sat_with_constant(pred, ii, c); if r != NONE return r;
    } else if id == IID_CTPOP {
        r := ic_fold_ctpop_pow2_test(cmp, ii, c, ic_q(cmp)); if r != NONE return r;
    } else if id == IID_SCMP || id == IID_UCMP {
        r := ic_fold_icmp_of_cmp_intrinsic_with_constant(pred, ii, c); if r != NONE return r;
    }
    if icmp_is_equality(pred) return ic_fold_icmp_eq_intrinsic_with_constant(cmp, ii, c);
    ty := vtype(ii);
    bw := c.bits;
    if id == IID_CTPOP {
        x := op(ii, 0);
        if ap_eq_u64(c, cast(u64) bw - 1) && pred == ICMP_UGT return create_icmp(ICMP_EQ, x, const_all_ones_of(ty));
        if ap_eq_u64(c, bw) && pred == ICMP_ULT return create_icmp(ICMP_NE, x, const_all_ones_of(ty));
    } else if id == IID_CTLZ {
        if pred == ICMP_UGT && ap_ult_u64(c, bw) {
            num := cast(u32) ap_limited(c);
            return create_icmp(ICMP_ULT, op(ii, 0), const_int_ap(ty, ap_one_bit_set(bw, bw - num - 1)));
        }
        if pred == ICMP_ULT && ap_uge_u64(c, 1) && ap_ule_u64(c, bw) {
            num := cast(u32) ap_limited(c);
            return create_icmp(ICMP_UGT, op(ii, 0), const_int_ap(ty, ap_low_bits_set(bw, bw - num)));
        }
    } else if id == IID_CTTZ {
        if !has_one_use(ii) return NONE;
        if pred == ICMP_UGT && ap_ult_u64(c, bw) {
            mask := ap_low_bits_set(bw, cast(u32) ap_limited(c) + 1);
            return create_icmp(ICMP_EQ, icb_and(op(ii, 0), const_int_ap(ty, mask)), const_null_value(ty));
        }
        if pred == ICMP_ULT && ap_uge_u64(c, 1) && ap_ule_u64(c, bw) {
            mask := ap_low_bits_set(bw, cast(u32) ap_limited(c));
            return create_icmp(ICMP_NE, icb_and(op(ii, 0), const_int_ap(ty, mask)), const_null_value(ty));
        }
    } else if id == IID_SSUB_SAT {
        if icmp_is_signed(pred) && c.bits > 1 {
            if ap_is_zero(c) return create_icmp(pred, op(ii, 0), op(ii, 1));
            if pred == ICMP_SLT && ap_is_one(c) return create_icmp(ICMP_SLE, op(ii, 0), op(ii, 1));
            if pred == ICMP_SGT && ap_is_all_ones(c) return create_icmp(ICMP_SGE, op(ii, 0), op(ii, 1));
        }
    } else if id == IID_ABS {
        if !has_one_use(ii) return NONE;
        x := op(ii, 0);
        int_min_poison := ap_is_one(const_ap(op(ii, 1)));
        if pred == ICMP_UGT && !ap_sign_bit(c)
            return create_icmp(ICMP_UGT, icb_add(x, const_int_ap(ty, c)), const_int_ap(ty, ap_shl(c, 1)));
        if int_min_poison && pred == ICMP_ULT && ap_sge(c, ap_one(c.bits)) {
            cm1 := ap_sub_u64(c, 1);
            return create_icmp(ICMP_ULE, icb_add(x, const_int_ap(ty, cm1)), const_int_ap(ty, ap_shl(cm1, 1)));
        }
    }
    return NONE;
}

// foldICmpInstWithConstantNotInt
ic_fold_icmp_inst_with_constant_not_int :: (i: Value_Id) -> Value_Id {
    o0 := op(i, 0); rhsc := op(i, 1);
    if !is_const(rhsc) || !is_inst(o0) return NONE;
    if inst_op(o0) == .INTTOPTR {
        if vkind(rhsc) == .C_NULL {
            ipt := dl_int_ptr_type(vtype(rhsc));
            if ipt == vtype(op(o0, 0)) {
                ps := dl_ptr_spec(type_addrspace(vtype(rhsc)));
                nv := ifx ps.null_all_ones then ap_all_ones(ps.bits) else ap_zero(ps.bits);
                return create_icmp(inst_pred(i), op(o0, 0), const_int_ap(ipt, nv));
            }
        }
    } else if inst_op(o0) == .LOAD {
        g := op(o0, 0);
        if is_inst(g) && inst_op(g) == .GEP {
            r := ic_fold_cmp_load_from_indexed_global(o0, g, i, NONE); if r != NONE return r;
        }
    }
    return NONE;
}

// foldSelectICmp
ic_fold_select_icmp :: (pred: u8, samesign: bool, si: Value_Id, rhs: Value_Id, i: Value_Id) -> Value_Id {
    simplify_op :: (pred: u8, samesign: bool, si: Value_Id, o: Value_Id, rhs: Value_Id, i: Value_Id, cond_true: bool) -> Value_Id {
        r := simplify_icmp_inst(pred, samesign, o, rhs, ic.sq);
        if r != NONE return r;
        impl := is_implied_condition_pred(op(si, 0), pred, samesign, o, rhs, cond_true);
        if impl >= 0 return cf_bool(vtype(i), impl == 1);
        return NONE;
    }
    ci: Value_Id = NONE;
    op1 := simplify_op(pred, samesign, si, op(si, 1), rhs, i, true);
    if op1 != NONE && vkind(op1) == .C_INT && !is_vector_type(vtype(op1)) ci = op1;
    op2 := simplify_op(pred, samesign, si, op(si, 2), rhs, i, false);
    if op2 != NONE { ci = ifx vkind(op2) == .C_INT && !is_vector_type(vtype(op2)) then op2 else NONE; }
    simplifies :: (o: Value_Id, si: Value_Id, idx: u32, rhs: Value_Id) -> bool {
        if o != NONE return true;
        a := op(si, idx);
        id := call_iid(a);
        okc, _ := pm_apint(rhs);
        return (id == IID_SCMP || id == IID_UCMP) && has_one_use(a) && okc;
    }
    transform := false;
    if op1 != NONE && op2 != NONE transform = true;
    else if simplifies(op1, si, 1, rhs) || simplifies(op2, si, 2, rhs) {
        if has_one_use(si) transform = true;
        else if ci != NONE && !ap_is_zero(const_ap(ci))
            transform = ic_replaced_select_with_operand(si, i, ifx op1 != NONE then cast(u32) 2 else 1);
    }
    if transform {
        if op1 == NONE op1 = icb_cmp(pred, op(si, 1), rhs, name_ref(vname(i)));
        if op2 == NONE op2 = icb_cmp(pred, op(si, 2), rhs, name_ref(vname(i)));
        r := create_select(op(si, 0), op1, op2);
        copy_metadata(r, si);   // SelectInst::Create(..., MDFrom = SI)
        return r;
    }
    return NONE;
}

// isMaskOrZero
pm_negated_power2_or_zero :: (v: Value_Id) -> bool { return pm_int_pred(v, (a: APInt) -> bool { return ap_is_zero(a) || ap_is_negated_power_of_2(a); }); }
ic_is_mask_or_zero :: (v: Value_Id, not: bool, q: Simplify_Query, depth_in: u32 = 0) -> bool {
    if ifx not then pm_negated_power2_or_zero(v) else pm_low_bit_mask_or_zero(v) return true;
    if scalar_bits(v) == 1 return true;
    depth := depth_in;
    if depth >= MAX_ANALYSIS_RECURSION_DEPTH return false;
    depth += 1;
    if !is_inst(v) return false;
    o := inst_op(v);
    if o == {
        case .ZEXT; return !not && ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .SEXT; return ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .AND; #through;
        case .OR; return ic_is_mask_or_zero(op(v, 1), not, q, depth) && ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .XOR;
            okn, x := pm_not(v);
            if okn return ic_is_mask_or_zero(x, !not, q, depth);
            for side: 0..1 {
                xv_ := op(v, cast(u32) side); other := op(v, cast(u32) (1 - side));
                if not {
                    okg, nx := pm_neg(other);
                    if okg && nx == xv_ return true;
                } else {
                    oka, ax, m1 := pm_binop(other, .ADD);
                    if oka && ax == xv_ && pm_all_ones(m1) return true;
                }
            }
            return false;
        case .SELECT; return ic_is_mask_or_zero(op(v, 1), not, q, depth) && ic_is_mask_or_zero(op(v, 2), not, q, depth);
        case .SHL; return not && ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .LSHR; return !not && ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .ASHR; return ic_is_mask_or_zero(op(v, 0), not, q, depth);
        case .ADD;
            if !not && pm_all_ones(op(v, 1)) return is_known_to_be_a_power_of_two_ctx(op(v, 0), true, q.cxt, q.dt, q.ac, true, depth);
        case .SUB;
            if not && pm_zero(op(v, 0)) return is_known_to_be_a_power_of_two_ctx(op(v, 1), true, q.cxt, q.dt, q.ac, true, depth);
        case .CALL;
            id := call_iid(v);
            if id == IID_UMAX || id == IID_SMAX || id == IID_UMIN || id == IID_SMIN
                return ic_is_mask_or_zero(op(v, 1), not, q, depth) && ic_is_mask_or_zero(op(v, 0), not, q, depth);
            if id == IID_BITREVERSE return ic_is_mask_or_zero(op(v, 0), !not, q, depth);
    }
    return false;
}

// foldICmpWithLowBitMaskedVal
ic_fold_icmp_with_low_bit_masked_val :: (pred: u8, op0: Value_Id, op1: Value_Id, q: Simplify_Query) -> Value_Id {
    dst: u8;
    if pred == {
        case ICMP_EQ; dst = ICMP_ULE;
        case ICMP_NE; dst = ICMP_UGT;
        case ICMP_ULT; dst = ICMP_UGT;
        case ICMP_UGE; dst = ICMP_ULE;
        case ICMP_SLT; dst = ICMP_SGT;
        case ICMP_SGE; dst = ICMP_SLE;
        case; return NONE;
    }
    x, m: Value_Id = NONE;
    is_low_bit_mask :: (pred: u8, op0: Value_Id, op1: Value_Id, q: Simplify_Query, x: *Value_Id, m: *Value_Id) -> bool {
        okc, mm := pm_c_binop_with(op0, .AND, op1);
        if okc && ic_is_binop(op0, .AND) {
            m.* = mm;
            x.* = op1;
            if ic_is_mask_or_zero(m.*, false, q) return !icmp_is_signed(pred) || (pm_non_negative(m.*) || is_known_non_negative(m.*, q));
            if ic_is_mask_or_zero(x.*, true, q) return !icmp_is_signed(pred) || is_known_non_zero(x.*, q);
            return false;
        }
        if icmp_is_equality(pred) && pm_all_ones(op1) && ic_is_binop(op0, .OR) && has_one_use(op0) {
            x.* = op(op0, 0); m.* = op(op0, 1);
            check :: (x: *Value_Id, m: *Value_Id, q: Simplify_Query) -> bool {
                if ic_is_mask_or_zero(m.*, false, q) {
                    nx := ic_get_freely_inverted(x.*, has_one_use(x.*), true);
                    if nx != NONE { x.* = nx; return true; }
                }
                return false;
            }
            if check(x, m, q) return true;
            t := x.*; x.* = m.*; m.* = t;
            return check(x, m, q);
        }
        if icmp_is_equality(pred) && pm_zero(op1) && ic_is_binop(op0, .AND) && has_one_use(op0) {
            x.* = op(op0, 0); m.* = op(op0, 1);
            check2 :: (x: *Value_Id, m: *Value_Id, q: Simplify_Query) -> bool {
                if ic_is_mask_or_zero(m.*, true, q) {
                    nm := ic_get_freely_inverted(m.*, has_one_use(m.*), true);
                    if nm != NONE { m.* = nm; return true; }
                }
                return false;
            }
            if check2(x, m, q) return true;
            t := x.*; x.* = m.*; m.* = t;
            return check2(x, m, q);
        }
        return false;
    }
    if !is_low_bit_mask(pred, op0, op1, q, *x, *m) return NONE;
    return icb_cmp(dst, x, m);
}

// foldICmpWithTruncSignExtendedVal
ic_fold_icmp_with_trunc_sign_extended_val :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        src_pred := inst_pred(i);
        if side == 1 src_pred = cmp_swapped(src_pred);
        a := op(i, cast(u32) side); xv_ := op(i, cast(u32) (1 - side));
        if !(ic_is_binop(a, .ASHR) && has_one_use(a)) continue;
        sh := op(a, 0);
        if !ic_is_binop(sh, .SHL) continue;
        x := op(sh, 0);
        ok0, c0 := pm_apint(op(sh, 1));
        ok1, c1 := pm_apint(op(a, 1));
        if !ok0 || !ok1 || xv_ != x continue;
        if !ap_eq(c0, c1) return NONE;
        masked := c0;
        dst: u8;
        if src_pred == ICMP_EQ dst = ICMP_ULT;
        else if src_pred == ICMP_NE dst = ICMP_UGE;
        else return NONE;
        xt := vtype(x);
        xbw := scalar_bits(x);
        kept := ap_sub(ap_from_u64(xbw, xbw), masked);
        icmp_cst := ap_shl_ap(ap_one(xbw), kept);
        add_cst := ap_lshr(icmp_cst, 1);
        t0 := icb_add(x, const_int_ap(xt, add_cst));
        return icb_cmp(dst, t0, const_int_ap(xt, icmp_cst));
    }
    return NONE;
}

// foldShiftIntoShiftInAnotherHandOfAndInICmp
ic_fold_shift_into_shift_in_another_hand_of_and_in_icmp :: (i: Value_Id, sq: Simplify_Query) -> Value_Id {
    if !icmp_is_equality(inst_pred(i)) || !pm_zero(op(i, 1)) || !has_one_use(op(i, 0)) return NONE;
    a := op(i, 0);
    if !ic_is_binop(a, .AND) return NONE;
    is_lshift :: (v: Value_Id) -> bool { return is_inst(v) && (inst_op(v) == .SHL || inst_op(v) == .LSHR); }
    x_shift, maybe_trunc, y_shift: Value_Id = NONE;
    for side: 0..1 {
        xs := op(a, cast(u32) side); mt := op(a, cast(u32) (1 - side));
        if !is_lshift(xs) || !is_inst(mt) continue;
        ys := trunc_or_self_i(mt);
        if !is_lshift(ys) continue;
        x_shift = xs; maybe_trunc = mt; y_shift = ys;
        break;
    }
    if x_shift == NONE return NONE;
    widest := y_shift; narrowest := x_shift;
    widest_ty := vtype(widest); narrowest_ty := vtype(narrowest);
    had_trunc := widest_ty != vtype(a);
    if inst_op(y_shift) == .LSHR { t := x_shift; x_shift = y_shift; y_shift = t; }
    xop := inst_op(x_shift);
    if xop == inst_op(y_shift) return NONE;
    x := op(x_shift, 0); x_sh_amt := zext_or_self_i(op(x_shift, 1));
    y := op(y_shift, 0); y_sh_amt := zext_or_self_i(op(y_shift, 1));
    if !is_const(x) && !is_const(y) {
        one_use_shift := (is_lshift(op(a, 0)) && has_one_use(op(a, 0))) || (is_lshift(op(a, 1)) && has_one_use(op(a, 1)));
        if !one_use_shift return NONE;
        if had_trunc {
            if !has_one_use(maybe_trunc) && !has_one_use(op(narrowest, 1)) return NONE;
        }
    }
    if vtype(x_sh_amt) != vtype(y_sh_amt) return NONE;
    max_total := cast(u64) (scalar_bits(widest) - 1) + cast(u64) (scalar_bits(narrowest) - 1);
    max_repr := ap_all_ones(scalar_bits(x_sh_amt));
    if ap_ult_u64(max_repr, max_total) return NONE;
    new_sh_amt := simplify_add_inst(x_sh_amt, y_sh_amt, false, false, sq_with_instruction(sq, i));
    if new_sh_amt == NONE || !is_const(new_sh_amt) return NONE;
    if vtype(new_sh_amt) != widest_ty {
        new_sh_amt = cfo_cast_operand(.ZEXT, new_sh_amt, widest_ty);
        if new_sh_amt == NONE return NONE;
    }
    wbw := scalar_bits(widest);
    ult :: (a: APInt, b: APInt) -> bool { return ap_ult(a, b); }
    if !pm_int_pred_arg(new_sh_amt, ult, ap_from_u64(wbw, wbw)) return NONE;
    if had_trunc && inst_op(widest) == .LSHR {
        can_fold :: (new_sh_amt: Value_Id, wbw: u32, narrowest: Value_Id, widest: Value_Id) -> bool {
            splat := ifx is_vector_type(vtype(new_sh_amt)) then get_splat_value(new_sh_amt) else new_sh_amt;
            if splat != NONE && (is_null_value(splat) || ap_eq_u64(const_ap(splat), cast(u64) wbw - 1)) return true;
            empty: Simplify_Query;
            c := op(narrowest, 0);
            if is_const(c) {
                k := known_bits(c, empty);
                mlz := kb_count_min_leading_zeros(k);
                if kb_bits(k) - mlz <= 1 return true;
                if splat != NONE && ap_ule_u64(const_ap(splat), cast(u64) mlz) return true;
            }
            c = op(widest, 0);
            if is_const(c) {
                k := known_bits(c, empty);
                mlz := kb_count_min_leading_zeros(k);
                if kb_bits(k) - mlz <= 1 return true;
                if splat != NONE {
                    adj := ap_sub(ap_from_u64(wbw, cast(u64) wbw - 1), const_ap(splat));
                    if ap_ule_u64(adj, cast(u64) mlz) return true;
                }
            }
            return false;
        }
        if !can_fold(new_sh_amt, wbw, narrowest, widest) return NONE;
    }
    x = icb_zext(x, widest_ty);
    y = icb_zext(y, widest_ty);
    t0 := ifx xop == .LSHR then icb_lshr(x, new_sh_amt) else icb_shl(x, new_sh_amt);
    t1 := icb_and(t0, y);
    return icb_cmp(inst_pred(i), t1, const_null_value(widest_ty));
}

// foldMultiplicationOverflowCheck
ic_fold_multiplication_overflow_check :: (i: Value_Id) -> Value_Id {
    pred: u8;
    x, y, mul, div: Value_Id = NONE;
    need_negation: bool;
    matched := false;
    if !icmp_is_equality(inst_pred(i)) {
        for side: 0..1 {
            d := op(i, cast(u32) side); yy := op(i, cast(u32) (1 - side));
            if !(ic_is_binop(d, .UDIV) && has_one_use(d) && pm_all_ones(op(d, 0))) continue;
            pred = inst_pred(i); if side == 1 pred = cmp_swapped(pred);
            x = op(d, 1); y = yy; div = d; matched = true;
            break;
        }
        if !matched return NONE;
        if pred == ICMP_ULT need_negation = false;
        else if pred == ICMP_UGE need_negation = true;
        else return NONE;
    } else {
        for side: 0..1 {
            yy := op(i, cast(u32) side); d := op(i, cast(u32) (1 - side));
            if !(is_inst(d) && (inst_op(d) == .UDIV || inst_op(d) == .SDIV) && has_one_use(d)) continue;
            m := op(d, 0);
            if !ic_is_binop(m, .MUL) continue;
            xv_: Value_Id = NONE;
            if op(m, 0) == yy xv_ = op(m, 1);
            else if op(m, 1) == yy xv_ = op(m, 0);
            if xv_ == NONE || op(d, 1) != xv_ continue;
            pred = inst_pred(i); if side == 1 pred = cmp_swapped(pred);
            x = xv_; y = yy; mul = m; div = d; matched = true;
            break;
        }
        if !matched return NONE;
        need_negation = pred == ICMP_EQ;
    }
    saved := ic.b;
    defer ic.b = saved;
    mul_had_other_uses := mul != NONE && !has_one_use(mul);
    if mul_had_other_uses icb_set_insert_point(mul);
    call := icb_intrinsic(ifx inst_op(div) == .UDIV then IID_UMUL_WITH_OVERFLOW else IID_SMUL_WITH_OVERFLOW, .[vtype(x)], .[x, y], "mul");
    if mul_had_other_uses ic_replace_inst_uses_with(mul, icb_extract_value(call, .[0], "mul.val"));
    res := icb_extract_value(call, .[1], "mul.ov");
    if need_negation res = icb_not(res, "mul.not.ov");
    if mul_had_other_uses ic_erase_inst(mul);
    return res;
}

// foldICmpXNegX
ic_fold_icmp_x_neg_x :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        n := op(i, cast(u32) side); xv_ := op(i, cast(u32) (1 - side));
        ok, x := pm_nsw_neg(n);
        if !ok || x != xv_ continue;
        pred := inst_pred(i); if side == 1 pred = cmp_swapped(pred);
        if icmp_is_signed(pred) pred = icmp_swapped(pred);
        else if icmp_is_unsigned(pred) pred = icmp_signed_predicate(pred);
        return create_icmp(pred, x, const_null_value(vtype(x)));
    }
    for side: 0..1 {
        n := op(i, cast(u32) side); xv_ := op(i, cast(u32) (1 - side));
        ok, x := pm_neg(n);
        if !ok || !has_one_use(n) || x != xv_ continue;
        pred := inst_pred(i); if side == 1 pred = cmp_swapped(pred);
        if !icmp_is_equality(pred) return NONE;
        ty := vtype(x);
        a := icb_and(x, const_int_ap(ty, ap_signed_max(scalar_bits(x))));
        return create_icmp(pred, a, const_null_value(ty));
    }
    return NONE;
}

// m_c_BinOp(opc, m_Specific(s), m_Value(A)) on an instruction: returns A
ic_c_binop_specific :: (v: Value_Id, opc: Opcode, s: Value_Id) -> (bool, Value_Id) {
    if !ic_is_binop(v, opc) return false, NONE;
    if op(v, 0) == s return true, op(v, 1);
    if op(v, 1) == s return true, op(v, 0);
    return false, NONE;
}

// foldICmpAndXX
ic_fold_icmp_and_xx :: (i: Value_Id, q: Simplify_Query) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    pred := inst_pred(i);
    oks, _ := ic_c_binop_specific(op1, .AND, op0);
    if oks { t := op0; op0 = op1; op1 = t; pred = icmp_swapped(pred); }
    ok, a := ic_c_binop_specific(op0, .AND, op1);
    if !ok return NONE;
    if pred == ICMP_ULT return create_icmp(ICMP_NE, op0, op1);
    if pred == ICMP_UGE return create_icmp(ICMP_EQ, op0, op1);
    if icmp_is_equality(pred) && has_one_use(op0) {
        if !pm_imm_constant(op1) {
            n1 := ic_get_freely_inverted(op1, !has_n_uses_or_more(op1, 3), true);
            if n1 != NONE return create_icmp(pred, icb_or(a, n1), const_all_ones_of(vtype(op1)));
        }
        na := ic_get_freely_inverted(a, has_one_use(a), true);
        if na != NONE return create_icmp(pred, icb_and(op1, na), const_null_value(vtype(op1)));
    }
    if !icmp_is_signed(pred) return NONE;
    ky := ic_known_bits(a, i);
    if kb_is_negative(ky) return create_icmp(icmp_unsigned_predicate(pred), op0, op1);
    if pred != ICMP_SLE && pred != ICMP_SGT return NONE;
    if kb_is_non_negative(ky) return create_icmp(icmp_swapped(pred), op1, const_null_value(vtype(op1)));
    if is_known_negative(op1, ic_q(i)) return create_icmp(icmp_flipped_strictness(pred), a, const_null_value(vtype(a)));
    return NONE;
}

// foldICmpOrXX
ic_fold_icmp_or_xx :: (i: Value_Id, q: Simplify_Query) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    pred := inst_pred(i);
    a: Value_Id;
    ok1, a1 := ic_c_binop_specific(op1, .OR, op0);
    if ok1 { t := op0; op0 = op1; op1 = t; pred = icmp_swapped(pred); a = a1; }
    else {
        ok0, a0 := ic_c_binop_specific(op0, .OR, op1);
        if !ok0 return NONE;
        a = a0;
    }
    if pred == ICMP_ULE return create_icmp(ICMP_EQ, op0, op1);
    if pred == ICMP_UGT return create_icmp(ICMP_NE, op0, op1);
    if icmp_is_equality(pred) && has_one_use(op0) {
        n1 := ic_get_freely_inverted(op1, !is_const(op1) && !has_n_uses_or_more(op1, 3), true);
        if n1 != NONE return create_icmp(pred, icb_and(a, n1), const_null_value(vtype(op1)));
        na := ic_get_freely_inverted(a, has_one_use(a), true);
        if na != NONE return create_icmp(pred, icb_or(op1, na), const_all_ones_of(vtype(op1)));
    }
    return NONE;
}

// foldICmpXorXX
ic_fold_icmp_xor_xx :: (i: Value_Id, q: Simplify_Query) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    pred := inst_pred(i);
    oks, _ := ic_c_binop_specific(op1, .XOR, op0);
    if oks { t := op0; op0 = op1; op1 = t; pred = icmp_swapped(pred); }
    ok, a := ic_c_binop_specific(op0, .XOR, op1);
    if !ok return NONE;
    pred_out := cmp_strict(pred);
    if pred_out != pred && is_known_non_zero(a, q) return create_icmp(pred_out, op0, op1);
    if pm_negative(a) {
        np: u8;
        sp := cmp_strict(pred);
        if sp == ICMP_SLT || sp == ICMP_UGT np = ICMP_SLT;
        else if sp == ICMP_SGT || sp == ICMP_ULT np = ICMP_SGE;
        else return NONE;
        return create_icmp(np, op0, const_null_value(vtype(op0)));
    }
    return NONE;
}

// isMultipleOf
ic_is_multiple_of :: (x: Value_Id, c: APInt, q: Simplify_Query) -> bool {
    if ap_is_one(c) return true;
    if !ap_is_power_of_2(c) return false;
    return masked_value_is_zero(x, ap_sub_u64(c, 1), q);
}

// foldICmpBinOp: icmp (binop), X or icmp X, (binop)
ic_fold_icmp_binop :: (i: Value_Id, sq: Simplify_Query) -> Value_Id {
    q := sq_with_instruction(sq, i);
    op0 := op(i, 0); op1 := op(i, 1);
    bo0 := ifx is_inst(op0) && is_binary_operator(op0) then op0 else NONE;
    bo1 := ifx is_inst(op1) && is_binary_operator(op1) then op1 else NONE;
    if bo0 == NONE && bo1 == NONE return NONE;
    r := ic_fold_icmp_x_neg_x(i); if r != NONE return r;
    pred := inst_pred(i);
    {
        ok, x := ic_c_binop_specific(op0, .ADD, op1);
        if ok && has_one_use(op0) && (pred == ICMP_ULT || pred == ICMP_UGE) return create_icmp(pred, icb_not(op1), x);
        ok, x = ic_c_binop_specific(op1, .ADD, op0);
        if ok && has_one_use(op1) && (pred == ICMP_UGT || pred == ICMP_ULE) return create_icmp(pred, x, icb_not(op0));
    }
    {
        if ic_is_binop(op0, .ADD) && has_one_use(op0) && pm_imm_constant(op(op0, 1)) && (pred == ICMP_ULT || pred == ICMP_UGE) {
            ok, x := ic_c_binop_specific(op(op0, 0), .ADD, op1);
            if ok {
                c2 := cfo_constant(ce_not(op(op0, 1)));
                return create_icmp(pred, icb_sub(c2, x), op1);
            }
        }
        if ic_is_binop(op1, .ADD) && has_one_use(op1) && pm_imm_constant(op(op1, 1)) && (pred == ICMP_UGT || pred == ICMP_ULE) {
            ok, x := ic_c_binop_specific(op(op1, 0), .ADD, op0);
            if ok {
                c2 := cfo_constant(ce_not(op(op1, 1)));
                return create_icmp(pred, op0, icb_sub(c2, x));
            }
        }
    }
    if icmp_is_equality(pred) && bo0 != NONE && pm_sign_mask(op(i, 1)) && inst_op(bo0) == .AND && pm_negated_power2_or_zero(op(bo0, 1)) {
        nc := icb_sub(op(i, 1), op(bo0, 1));
        return create_icmp(ifx pred == ICMP_EQ then cast(u8) ICMP_SLT else ICMP_SGE, op(bo0, 0), nc);
    }
    {
        if (pred == ICMP_ULT || pred == ICMP_UGE) && ic_is_binop(op0, .AND) && is_binary_operator(op(op0, 0)) {
            okm, c := pm_low_bit_mask_ap(op(op0, 1));
            bo := op(op0, 0);
            if okm && ic_is_binop(bo, .ADD) && op(bo, 0) == op1 && pm_specific_int_ap(op(bo, 1), c)
                return create_icmp(ifx pred == ICMP_ULT then cast(u8) ICMP_NE else ICMP_EQ, op1, const_null_value(vtype(op1)));
        }
        if (pred == ICMP_UGT || pred == ICMP_ULE) && ic_is_binop(op1, .AND) && is_binary_operator(op(op1, 0)) {
            okm, c := pm_low_bit_mask_ap(op(op1, 1));
            bo := op(op1, 0);
            if okm && ic_is_binop(bo, .ADD) && op(bo, 0) == op0 && pm_specific_int_ap(op(bo, 1), c)
                return create_icmp(ifx pred == ICMP_UGT then cast(u8) ICMP_NE else ICMP_EQ, op0, const_null_value(vtype(op1)));
        }
    }
    no_op0_wrap, no_op1_wrap := false, false;
    op0_nuw, op1_nuw, op0_nsw, op1_nsw := false, false, false, false;
    has_no_wrap_problem :: (bo: Value_Id, pred: u8, nsw: *bool, nuw: *bool) -> bool {
        if is_overflowing_binop(bo) {
            nuw.* = has_nuw(bo); nsw.* = has_nsw(bo);
            return icmp_is_equality(pred) || (icmp_is_unsigned(pred) && nuw.*) || (icmp_is_signed(pred) && nsw.*);
        } else if inst_op(bo) == .OR {
            nuw.* = true; nsw.* = true;
            return true;
        }
        return false;
    }
    a, b, c, d: Value_Id = NONE;
    if bo0 != NONE {
        ok, aa, bb := pm_add_like(bo0);
        if ok { a = aa; b = bb; }
        no_op0_wrap = has_no_wrap_problem(bo0, pred, *op0_nsw, *op0_nuw);
    }
    if bo1 != NONE {
        ok, cc, dd := pm_add_like(bo1);
        if ok { c = cc; d = dd; }
        no_op1_wrap = has_no_wrap_problem(bo1, pred, *op1_nsw, *op1_nuw);
    }
    if a != NONE && (a == op1 || b == op1) && no_op0_wrap
        return create_icmp(pred, ifx a == op1 then b else a, const_null_value(vtype(op1)));
    if c != NONE && (c == op0 || d == op0) && no_op1_wrap
        return create_icmp(pred, const_null_value(vtype(op0)), ifx c == op0 then d else c);
    if a != NONE && c != NONE && (a == c || a == d || b == c || b == d) && no_op0_wrap && no_op1_wrap {
        y, z: Value_Id;
        if a == c { y = b; z = d; }
        else if a == d { y = b; z = c; }
        else if b == c { y = a; z = d; }
        else { y = a; z = c; }
        return create_icmp(pred, y, z);
    }
    if icmp_is_relational(pred) {
        share_common_divisor :: (x: Value_Id, y: Value_Id, z: Value_Id, is_negative: bool, q: Simplify_Query) -> bool {
            okc, off := pm_apint(z);
            if !okc return false;
            if ifx is_negative then ap_is_all_ones(off) else ap_is_one(off) return true;
            cc := off;
            if is_negative cc = ap_neg(cc);
            if !ap_is_strictly_positive(cc) return false;
            return ic_is_multiple_of(x, cc, q) && ic_is_multiple_of(y, cc, q);
        }
        is_lt := pred == ICMP_ULT || pred == ICMP_SLT;
        is_ge := pred == ICMP_UGE || pred == ICMP_SGE;
        is_gt := pred == ICMP_UGT || pred == ICMP_SGT;
        is_le := pred == ICMP_ULE || pred == ICMP_SLE;
        if a != NONE && no_op0_wrap && share_common_divisor(a, op1, b, is_lt || is_ge, q)
            return create_icmp(icmp_flipped_strictness(pred), a, op1);
        if c != NONE && no_op1_wrap && share_common_divisor(op0, c, d, is_gt || is_le, q)
            return create_icmp(icmp_flipped_strictness(pred), op0, c);
    }
    if a != NONE && c != NONE && no_op0_wrap && no_op1_wrap && (has_one_use(bo0) || has_one_use(bo1)) && !icmp_is_unsigned(pred) {
        ok1, ap1 := pm_apint_ap(b);
        ok2, ap2 := pm_apint_ap(d);
        if ok1 && ok2 && ap_sign_bit(ap1) == ap_sign_bit(ap2) {
            a1 := ap_abs(ap1); a2 := ap_abs(ap2);
            if ap_uge(a1, a2) {
                diff := ap_sub(ap1, ap2);
                c3 := const_int_ap(vtype(bo0), diff);
                na := icb_add(a, c3, "", op0_nuw && ap_ule(diff, ap1), op0_nsw);
                return create_icmp(pred, na, c);
            } else {
                diff := ap_sub(ap2, ap1);
                c3 := const_int_ap(vtype(bo0), diff);
                na := icb_add(c, c3, "", op1_nuw && ap_ule(diff, ap2), op1_nsw);
                return create_icmp(pred, a, na);
            }
        }
        if pm_imm_constant(b) && pm_imm_constant(d) && icmp_is_equality(pred) {
            diff := cfo_constant(ce_binop(.SUB, d, b, 0));
            na := icb_add(c, diff);
            return create_icmp(pred, a, na);
        }
    }
    a = NONE; b = NONE; c = NONE; d = NONE;
    if bo0 != NONE && inst_op(bo0) == .SUB { a = op(bo0, 0); b = op(bo0, 1); }
    if bo1 != NONE && inst_op(bo1) == .SUB { c = op(bo1, 0); d = op(bo1, 1); }
    if a != NONE && a == op1 && no_op0_wrap return create_icmp(pred, const_null_value(vtype(op1)), b);
    if c != NONE && c == op0 && no_op1_wrap return create_icmp(pred, d, const_null_value(vtype(op0)));
    if a != NONE && a == op1 && (pred == ICMP_UGT || pred == ICMP_ULE) return create_icmp(pred, b, a);
    if c != NONE && c == op0 && (pred == ICMP_ULT || pred == ICMP_UGE) return create_icmp(pred, c, d);
    if a != NONE && a == op1 && (pred == ICMP_UGE || pred == ICMP_ULT) && is_known_non_zero(b, q)
        return create_icmp(icmp_flipped_strictness(pred), b, a);
    if c != NONE && c == op0 && (pred == ICMP_ULE || pred == ICMP_UGT) && is_known_non_zero(d, q)
        return create_icmp(icmp_flipped_strictness(pred), c, d);
    if b != NONE && d != NONE && b == d && no_op0_wrap && no_op1_wrap return create_icmp(pred, a, c);
    if a != NONE && c != NONE && a == c && no_op0_wrap && no_op1_wrap return create_icmp(pred, d, b);
    if no_op0_wrap && icmp_is_signed(pred) {
        okn, x := pm_neg(bo0);
        if okn && is_const(op1) && const_is_not_min_signed_value(op1)
            return create_icmp(icmp_swapped(pred), x, cfo_constant(ce_neg(op1)));
    }
    r = ic_fold_icmp_xor_xx(i, q); if r != NONE return r;
    r = ic_fold_icmp_or_xx(i, q); if r != NONE return r;
    {
        x, y, z: Value_Id = NONE;
        matched := false;
        if ic_is_binop(op0, .MUL) {
            for k: 0..1 {
                zz := op(op0, cast(u32) (1 - k)); xv_ := op(op0, cast(u32) k);
                ok, yy := ic_c_binop_specific(op1, .MUL, zz);
                if ok { x = xv_; y = yy; z = zz; matched = true; break; }
            }
        }
        if matched {
            if icmp_is_signed(pred) {
                if op0_nsw && op1_nsw {
                    zk := ic_known_bits(z, i);
                    if kb_is_strictly_positive(zk) return create_icmp(pred, x, y);
                    if kb_is_negative(zk) return create_icmp(icmp_swapped(pred), x, y);
                    lt := simplify_icmp_inst(ICMP_SLT, false, x, y, sq_with_instruction(ic.sq, i));
                    if lt != NONE && pm_one(lt) return create_icmp(icmp_swapped(pred), z, const_null_value(vtype(z)));
                    gt := simplify_icmp_inst(ICMP_SGT, false, x, y, sq_with_instruction(ic.sq, i));
                    if gt != NONE && pm_one(gt) return create_icmp(pred, z, const_null_value(vtype(z)));
                }
            } else {
                non_zero: bool;
                if icmp_is_equality(pred) {
                    if ((op0_nsw && op1_nsw) || (op0_nuw && op1_nuw)) && is_known_non_equal(x, y, ic.sq)
                        return create_icmp(pred, z, const_null_value(vtype(z)));
                    zk := ic_known_bits(z, i);
                    if kb_count_max_trailing_zeros(zk) == 0 return create_icmp(pred, x, y);
                    non_zero = !ap_is_zero(zk.one) || is_known_non_zero(z, q);
                    if non_zero && bo0 != NONE && bo1 != NONE && op0_nsw && op1_nsw return create_icmp(pred, x, y);
                } else non_zero = is_known_non_zero(z, q);
                if non_zero && bo0 != NONE && bo1 != NONE && op0_nuw && op1_nuw return create_icmp(pred, x, y);
            }
        }
    }
    srem: Value_Id = NONE;
    if bo0 != NONE && inst_op(bo0) == .SREM && op1 == op(bo0, 1) srem = bo0;
    else if bo1 != NONE && inst_op(bo1) == .SREM && op0 == op(bo1, 1) srem = bo1;
    if srem != NONE {
        p := ifx srem == bo0 then icmp_swapped(pred) else pred;
        if p == {
            case ICMP_EQ; return ic_replace_inst_uses_with(i, get_false(vtype(i)));
            case ICMP_NE; return ic_replace_inst_uses_with(i, get_true(vtype(i)));
            case ICMP_SGT; #through;
            case ICMP_SGE; return create_icmp(ICMP_SGT, op(srem, 1), const_all_ones_of(vtype(srem)));
            case ICMP_SLT; #through;
            case ICMP_SLE; return create_icmp(ICMP_SLT, op(srem, 1), const_null_value(vtype(srem)));
        }
    }
    if bo0 != NONE && bo1 != NONE && inst_op(bo0) == inst_op(bo1) && (has_one_use(bo0) || has_one_use(bo1)) && op(bo0, 1) == op(bo1, 1) {
        o := inst_op(bo0);
        if o == .ADD || o == .SUB || o == .XOR {
            if icmp_is_equality(pred) return create_icmp(pred, op(bo0, 0), op(bo1, 0));
            okc, cc := pm_apint(op(bo0, 1));
            if okc {
                if ap_is_sign_mask(cc) return create_icmp(icmp_flipped_signedness(pred), op(bo0, 0), op(bo1, 0));
                if o == .XOR && ap_is_max_signed(cc) return create_icmp(icmp_swapped(icmp_flipped_signedness(pred)), op(bo0, 0), op(bo1, 0));
            }
        } else if o == .MUL {
            if icmp_is_equality(pred) {
                okc, cc := pm_apint(op(bo0, 1));
                if okc && !ap_is_zero(cc) && !ap_is_one(cc) {
                    tzs := ap_ctz(cc);
                    if tzs {
                        mask := const_int_ap(vtype(bo0), ap_low_bits_set(cc.bits, cc.bits - tzs));
                        a1 := icb_and(op(bo0, 0), mask);
                        a2 := icb_and(op(bo1, 0), mask);
                        return create_icmp(pred, a1, a2);
                    }
                }
            }
        } else if o == .UDIV || o == .LSHR {
            if !(icmp_is_signed(pred) || !is_exact(bo0) || !is_exact(bo1)) return create_icmp(pred, op(bo0, 0), op(bo1, 0));
        } else if o == .SDIV {
            if !(!(icmp_is_equality(pred) || pm_non_negative(op(bo0, 1))) || !is_exact(bo0) || !is_exact(bo1))
                return create_icmp(pred, op(bo0, 0), op(bo1, 0));
        } else if o == .ASHR {
            if is_exact(bo0) && is_exact(bo1) return create_icmp(pred, op(bo0, 0), op(bo1, 0));
        } else if o == .SHL {
            nuw := op0_nuw && op1_nuw;
            nsw := op0_nsw && op1_nsw;
            if !(!nuw && !nsw) && !(!nsw && icmp_is_signed(pred)) return create_icmp(pred, op(bo0, 0), op(bo1, 0));
        }
    }
    if bo0 != NONE {
        for side: 0..1 {
            if !ic_is_binop(bo0, .AND) break;
            ls := op(bo0, cast(u32) side);
            oka, l, m1 := pm_binop(ls, .ADD);
            if oka && l == op1 && pm_all_ones(m1) && pred == ICMP_ULT return create_icmp(ICMP_NE, op1, const_null_value(vtype(bo0)));
        }
    }
    if !icmp_is_signed(pred) {
        if ic_is_binop(op0, .SHL) && op(op0, 0) == op1 && pm_one(op(op0, 1))
            return create_icmp(icmp_signed_predicate(pred), op1, const_null_value(vtype(op1)));
        else if ic_is_binop(op1, .SHL) && op(op1, 0) == op0 && pm_one(op(op1, 1))
            return create_icmp(icmp_signed_predicate(pred), const_null_value(vtype(op0)), op0);
    }
    v := ic_fold_multiplication_overflow_check(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    r = ic_fold_icmp_and_xx(i, q); if r != NONE return r;
    v = ic_fold_icmp_with_trunc_sign_extended_val(i);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    v = ic_fold_shift_into_shift_in_another_hand_of_and_in_icmp(i, sq);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    return NONE;
}

// foldICmpWithMinMax: icmp Pred min|max(X, Y), Z
ic_fold_icmp_with_min_max :: (i: Value_Id, mm: Value_Id, z: Value_Id, pred_in: u8) -> Value_Id {
    pred := pred_in;
    x := op(mm, 0); y := op(mm, 1);
    id := call_iid(mm);
    mm_signed := id == IID_SMAX || id == IID_SMIN;
    if icmp_is_signed(pred) && !mm_signed return NONE;
    if icmp_is_unsigned(pred) && mm_signed {
        if is_known_non_negative(z, ic_q(i)) && is_known_non_negative(mm, ic_q(i)) pred = icmp_flipped_signedness(pred);
        else return NONE;
    }
    q := ic_q(i);
    known :: (v: Value_Id) -> s8 {
        if v == NONE return -1;
        if pm_one(v) return 1;
        if pm_zero(v) return 0;
        return -1;
    }
    cmp_xz := known(simplify_icmp_inst(pred, false, x, z, q));
    cmp_yz := known(simplify_icmp_inst(pred, false, y, z, q));
    if cmp_xz < 0 && cmp_yz < 0 return NONE;
    if cmp_xz < 0 { t := x; x = y; y = t; t2 := cmp_xz; cmp_xz = cmp_yz; cmp_yz = t2; }
    fold_into_cmp_yz :: (i: Value_Id, cmp_yz: s8, pred: u8, y: Value_Id, z: Value_Id) -> Value_Id {
        if cmp_yz >= 0 return ic_replace_inst_uses_with(i, cf_bool(vtype(i), cmp_yz == 1));
        return create_icmp(pred, y, z);
    }
    mm_pred := min_max_intrinsic_pred(id);
    if pred == ICMP_EQ || pred == ICMP_NE {
        if (pred == ICMP_EQ) == (cmp_xz == 1) {
            np := cmp_non_strict(mm_pred);
            if pred == ICMP_NE np = cmp_inverse(np);
            return create_icmp(np, x, y);
        }
        np := mm_pred;
        mm_xz := known(simplify_icmp_inst(np, false, x, z, q));
        if mm_xz < 0 {
            t := x; x = y; y = t; t2 := cmp_xz; cmp_xz = cmp_yz; cmp_yz = t2;
            if cmp_xz < 0 || (pred == ICMP_EQ) == (cmp_xz == 1) return NONE;
            mm_xz = known(simplify_icmp_inst(np, false, x, z, q));
        }
        if mm_xz < 0 return NONE;
        if mm_xz == 1 return ic_replace_inst_uses_with(i, cf_bool(vtype(i), pred == ICMP_NE));
        return fold_into_cmp_yz(i, cmp_yz, pred, y, z);
    }
    if icmp_is_relational(pred) {
        is_same := mm_pred == cmp_strict(pred);
        if cmp_xz == 1 {
            if is_same return ic_replace_inst_uses_with(i, get_true(vtype(i)));
            return fold_into_cmp_yz(i, cmp_yz, pred, y, z);
        } else {
            if is_same return fold_into_cmp_yz(i, cmp_yz, pred, y, z);
            return ic_replace_inst_uses_with(i, get_false(vtype(i)));
        }
    }
    return NONE;
}

// foldICmpWithClamp: icmp eq/ne X, min(max(X, Lo), Hi)
ic_fold_icmp_with_clamp :: (i: Value_Id, x_in: Value_Id, mn: Value_Id) -> Value_Id {
    x := x_in;
    id := call_iid(mn);
    if !icmp_is_equality(inst_pred(i)) || !has_one_use(mn) || !(id == IID_SMIN || id == IID_UMIN) return NONE;
    lhs := op(mn, 0); rhs := op(mn, 1);
    lo, hi: APInt;
    if id == IID_SMIN {
        okm, mx, loc := pm_intrinsic2(lhs, IID_SMAX);
        if !okm || !has_one_use(lhs) || mx != x return NONE;
        okl, l := pm_apint(loc); okh, h := pm_apint(rhs);
        if !okl || !okh || !ap_slt(l, h) return NONE;
        lo = l; hi = h;
    } else {
        okm, mx, loc := pm_intrinsic2(lhs, IID_UMAX);
        if !okm || !has_one_use(lhs) || mx != x return NONE;
        okl, l := pm_apint(loc); okh, h := pm_apint(rhs);
        if !okl || !okh || !ap_ult(l, h) return NONE;
        lo = l; hi = h;
    }
    cr := cr_non_empty(lo, ap_add_u64(hi, 1));
    if inst_pred(i) != ICMP_EQ cr = cr_inverse(cr);
    p, c, off := cr_equivalent_icmp(cr);
    if !ap_is_zero(off) x = icb_add(x, const_int_ap(vtype(x), off));
    return ic_replace_inst_uses_with(i, icb_cmp(p, x, const_int_ap(vtype(x), c)));
}

// foldICmpPow2Test
ic_fold_icmp_pow2_test :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    pred := inst_pred(i);
    a: Value_Id = NONE;
    check_is: bool;
    if icmp_is_equality(pred) {
        if ic_is_binop(op0, .AND) && has_one_use(op0) && pm_zero_int(op1) {
            for side: 0..1 {
                ad := op(op0, cast(u32) side); aa := op(op0, cast(u32) (1 - side));
                oka, x, m1 := pm_binop(ad, .ADD);
                if oka && pm_all_ones(m1) { if x == aa a = x; break; }
            }
        }
        neg_and :: (v: Value_Id, s: Value_Id) -> bool {
            if !ic_is_binop(v, .AND) || !has_one_use(v) return false;
            for side: 0..1 {
                okn, nx := pm_neg(op(v, cast(u32) side));
                if okn && nx == s && op(v, cast(u32) (1 - side)) == s return true;
            }
            return false;
        }
        if neg_and(op0, op1) a = op1;
        else if neg_and(op1, op0) a = op0;
        check_is = pred == ICMP_EQ;
    } else if icmp_is_unsigned(pred) {
        xor_dec :: (v: Value_Id, s: Value_Id) -> bool {
            if !ic_is_binop(v, .XOR) || !has_one_use(v) return false;
            for side: 0..1 {
                oka, x, m1 := pm_binop(op(v, cast(u32) side), .ADD);
                if oka && x == s && pm_all_ones(m1) && op(v, cast(u32) (1 - side)) == s return true;
            }
            return false;
        }
        if (pred == ICMP_UGE || pred == ICMP_ULT) && xor_dec(op0, op1) { a = op1; check_is = pred == ICMP_UGE; }
        else if (pred == ICMP_UGT || pred == ICMP_ULE) && xor_dec(op1, op0) { a = op0; check_is = pred == ICMP_ULE; }
    }
    if a != NONE {
        ty := vtype(a);
        ctpop := icb_unary_intrinsic(IID_CTPOP, a);
        if check_is return create_icmp(ICMP_ULT, ctpop, const_int_of(ty, 2));
        return create_icmp(ICMP_UGT, ctpop, const_int_of(ty, 1));
    }
    return NONE;
}

// collectOffsetOp
Offset_Op :: struct { opc: Opcode; rhs: Value_Id; }
ic_collect_offset_op :: (v: Value_Id, offsets: *[..] Offset_Op, allow_recursion: bool) {
    if !is_inst(v) || !has_one_use(v) return;
    o := inst_op(v);
    if o == {
        case .ADD; array_add(offsets, .{.SUB, op(v, 1)}); array_add(offsets, .{.SUB, op(v, 0)});
        case .SUB; array_add(offsets, .{.ADD, op(v, 1)});
        case .XOR; array_add(offsets, .{.XOR, op(v, 1)}); array_add(offsets, .{.XOR, op(v, 0)});
        case .SHL;
            if has_nsw(v) array_add(offsets, .{.ASHR, op(v, 1)});
            if has_nuw(v) array_add(offsets, .{.LSHR, op(v, 1)});
        case .SELECT;
            if allow_recursion {
                ic_collect_offset_op(op(v, 1), offsets, false);
                ic_collect_offset_op(op(v, 2), offsets, false);
            }
    }
}

// foldICmpEqualityWithOffset
ic_fold_icmp_equality_with_offset :: (i: Value_Id, sq: Simplify_Query) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    if !is_int_or_int_vector(vtype(op0)) return NONE;
    offs: [..] Offset_Op; offs.allocator = temp;
    ic_collect_offset_op(op0, *offs, true);
    ic_collect_offset_op(op1, *offs, true);
    apply_impl :: (v: Value_Id, opc: Opcode, rhs: Value_Id, sq: Simplify_Query) -> Value_Id {
        if opc == .ASHR {
            okv, cv := pm_apint(v); okr, cr := pm_apint(rhs);
            if !(okv && okr && ap_eq(ap_shl_ap(ap_ashr_ap(cv, cr), cr), cv)) && !(opr_code(v) == .SHL && (opr_flags(v) & F_NSW) != 0 && op(v, 1) == rhs) return NONE;
        } else if opc == .LSHR {
            okv, cv := pm_apint(v); okr, cr := pm_apint(rhs);
            if !(okv && okr && ap_eq(ap_shl_ap(ap_lshr_ap(cv, cr), cr), cv)) && !(opr_code(v) == .SHL && (opr_flags(v) & F_NUW) != 0 && op(v, 1) == rhs) return NONE;
        }
        s := simplify_binop(opc, v, rhs, sq);
        if s == NONE return NONE;
        if is_const(s) && !pm_imm_constant(s) return NONE;
        return ifx implies_poison(rhs, v) then s else NONE;
    }
    Offset_Result :: struct { kind: u8; v0: Value_Id; v1: Value_Id; v2: Value_Id; md_from: Value_Id; }
    apply :: (v: Value_Id, opc: Opcode, rhs: Value_Id, sq: Simplify_Query) -> Offset_Result {
        r: Offset_Result;
        if is_inst(v) && inst_op(v) == .SELECT {
            if !has_one_use(v) return r;
            tv := apply_impl(op(v, 1), opc, rhs, sq);
            if tv == NONE return r;
            fv := apply_impl(op(v, 2), opc, rhs, sq);
            if fv == NONE return r;
            r.kind = 2; r.v0 = op(v, 0); r.v1 = tv; r.v2 = fv; r.md_from = v;
            return r;
        }
        s := apply_impl(v, opc, rhs, sq);
        if s != NONE { r.kind = 1; r.v0 = s; }
        return r;
    }
    materialize :: (r: Offset_Result) -> Value_Id {
        if r.kind == 1 return r.v0;
        return icb_select(r.v0, r.v1, r.v2, "", r.md_from);
    }
    for offs {
        r0 := apply(op0, it.opc, it.rhs, sq);
        if r0.kind == 0 continue;
        r1 := apply(op1, it.opc, it.rhs, sq);
        if r1.kind == 0 continue;
        nl := materialize(r0);
        nr := materialize(r1);
        return create_icmp(inst_pred(i), nl, nr);
    }
    return NONE;
}

// foldICmpEquality
ic_fold_icmp_equality :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    if !icmp_is_equality(pred) return NONE;
    op0 := op(i, 0); op1 := op(i, 1);
    if ic_is_binop(op0, .XOR) {
        a := op(op0, 0); b := op(op0, 1);
        if a == op1 || b == op1 {
            other := ifx a == op1 then b else a;
            return create_icmp(pred, other, const_null_value(vtype(a)));
        }
        if ic_is_binop(op1, .XOR) {
            c := op(op1, 0); d := op(op1, 1);
            if vkind(b) == .C_INT && vkind(d) == .C_INT && has_one_use(op1) {
                nc := const_int_ap(type_int(scalar_bits(b)), ap_xor(const_ap(b), const_ap(d)));
                if is_vector_type(vtype(b)) nc = const_int_ap(vtype(b), ap_xor(const_ap(b), const_ap(d)));
                x := icb_xor(c, nc);
                return create_icmp(pred, a, x);
            }
            if a == c return create_icmp(pred, b, d);
            if a == d return create_icmp(pred, b, c);
            if b == c return create_icmp(pred, a, d);
            if b == d return create_icmp(pred, a, c);
        }
    }
    if ic_is_binop(op1, .XOR) && (op(op1, 0) == op0 || op(op1, 1) == op0) {
        a := op(op1, 0); b := op(op1, 1);
        other := ifx a == op0 then b else a;
        return create_icmp(pred, other, const_null_value(vtype(a)));
    }
    if ic_is_binop(op0, .AND) && ic_is_binop(op1, .AND) {
        a := op(op0, 0); b := op(op0, 1); c := op(op1, 0); d := op(op1, 1);
        x, y, z: Value_Id = NONE;
        if a == c { x = b; y = d; z = a; }
        else if a == d { x = b; y = c; z = a; }
        else if b == c { x = a; y = d; z = b; }
        else if b == d { x = a; y = c; z = b; }
        if x != NONE {
            ok0, c0 := pm_apint(x); ok1, c1 := pm_apint(y);
            xor_neg_p2 := ok0 && ok1 && ap_is_negated_power_of_2(ap_xor(c0, c1));
            use_cnt := cast(int) has_one_use(op0) + cast(int) has_one_use(op1) + cast(int) (pm_imm_constant(x) && pm_imm_constant(y));
            if xor_neg_p2 || use_cnt >= 2 {
                n1 := icb_xor(x, y);
                n1 = icb_and(n1, z);
                return create_icmp(pred, n1, const_null_value(vtype(n1)));
            }
        }
    }
    {
        if ic_is_binop(op0, .OR) && has_one_use(op0) && is_const(op(op0, 1)) && ic_is_binop(op1, .OR) && has_one_use(op1) && op(op1, 1) == op(op0, 1) {
            c := op(op0, 1);
            xor := icb_xor(op(op0, 0), op(op1, 0));
            a := icb_and(xor, cfo_constant(ce_not(c)));
            return create_icmp(pred, a, const_null_value(vtype(a)));
        }
    }
    okz, za := pmi_cast(op1, .ZEXT);
    if okz && (has_one_use(op0) || has_one_use(op1)) {
        if ic_is_binop(op0, .AND) {
            okm, maskc := pm_low_bit_mask_ap(op(op0, 1));
            if okm && ap_cto(maskc) == scalar_bits(za) return create_icmp(pred, za, icb_trunc(op(op0, 0), vtype(za)));
        }
    }
    {
        matched := false;
        a, b: Value_Id; ap1, ap2: APInt;
        for opc: Opcode.[.LSHR, .ASHR] {
            if ic_is_binop(op0, opc) && has_one_use(op0) && ic_is_binop(op1, opc) && has_one_use(op1) {
                ok1, x1 := pm_apint_ap(op(op0, 1));
                ok2, x2 := pm_apint_ap(op(op1, 1));
                if ok1 && ok2 { a = op(op0, 0); b = op(op1, 0); ap1 = x1; ap2 = x2; matched = true; break; }
            }
        }
        if matched {
            if !ap_eq(ap1, ap2) return NONE;
            type_bits := ap1.bits;
            sh := cast(u32) ap_limited(ap1, cast(u64) type_bits);
            if sh < type_bits && sh != 0 {
                np := ifx pred == ICMP_NE then cast(u8) ICMP_UGE else ICMP_ULT;
                xor := icb_xor(a, b, tprint("%.unshifted", vname(i)));
                return create_icmp(np, xor, const_int_ap(vtype(a), ap_one_bit_set(type_bits, sh)));
            }
        }
    }
    if ic_is_binop(op0, .SHL) && has_one_use(op0) && vkind(op(op0, 1)) == .C_INT && ic_is_binop(op1, .SHL) && has_one_use(op1) && op(op1, 1) == op(op0, 1) {
        cst1 := op(op0, 1);
        a := op(op0, 0); b := op(op1, 0);
        type_bits := scalar_bits(cst1);
        sh := cast(u32) ap_limited(const_ap(cst1), cast(u64) type_bits);
        if sh < type_bits && sh != 0 {
            xor := icb_xor(a, b, tprint("%.unshifted", vname(i)));
            and_val := ap_low_bits_set(type_bits, type_bits - sh);
            a2 := icb_and(xor, const_int_ap(type_int(type_bits), and_val), tprint("%.mask", vname(i)));
            return create_icmp(pred, a2, const_null_value(vtype(cst1)));
        }
    }
    if has_one_use(op0) {
        okt, t := pmi_cast(op0, .TRUNC);
        if okt && ic_is_binop(t, .LSHR) && has_one_use(t) && vkind(op1) == .C_INT {
            oka, sh_amt := pm_constant_int_u64(op(t, 1));
            a := op(t, 0);
            if oka && !has_one_use(a) {
                asize := type_bits(vtype(a));
                if sh_amt < cast(u64) asize {
                    mask_v := ap_shl(ap_low_bits_set(asize, type_bits(vtype(op0))), cast(u32) sh_amt);
                    cmp_v := ap_shl(ap_zext(const_ap(op1), asize), cast(u32) sh_amt);
                    m := icb_and(a, const_int_ap(type_int(asize), mask_v));
                    return create_icmp(pred, m, const_int_ap(type_int(asize), cmp_v));
                }
            }
        }
    }
    r := ic_fold_icmp_intrinsic_with_intrinsic(i); if r != NONE return r;
    bw := scalar_bits(op0);
    if ic_is_binop(op0, .ASHR) && pm_specific_int(op(op0, 1), cast(u64) (bw - 1)) {
        okt, a := pmi_cast(op(op0, 0), .TRUNC);
        okt2, l := pmi_cast(op1, .TRUNC);
        if okt && okt2 && ic_is_binop(l, .LSHR) && op(l, 0) == a && pm_specific_int(op(l, 1), cast(u64) bw) &&
           scalar_bits(a) == bw * 2 && (has_one_use(op(i, 0)) || has_one_use(op(i, 1))) {
            c := ap_one_bit_set(bw * 2, bw - 1);
            add := icb_add(a, const_int_ap(vtype(a), c));
            return create_icmp(ifx pred == ICMP_EQ then cast(u8) ICMP_ULT else ICMP_UGE, add, const_int_ap(vtype(a), ap_shl(c, 1)));
        }
    }
    {
        ok, _ := ic_c_binop_specific(op0, .AND, op1);
        if ok && ic_is_known_to_be_power_of_two(op1, false, i) return create_icmp(cmp_inverse(pred), op0, const_null_value(vtype(op0)));
        ok, _ = ic_c_binop_specific(op1, .AND, op0);
        if ok && ic_is_known_to_be_power_of_two(op0, false, i) return create_icmp(cmp_inverse(pred), op1, const_null_value(vtype(op1)));
    }
    for side: 0..1 {
        a := op(i, cast(u32) side); f := op(i, cast(u32) (1 - side));
        if call_iid(f) == IID_FSHR && has_one_use(f) && op(f, 0) == a && op(f, 1) == a {
            b := op(f, 2);
            return create_icmp(pred, a, icb_intrinsic(IID_FSHL, .[vtype(op0)], .[a, a, b]));
        }
    }
    for side: 0..1 {
        x := op(i, cast(u32) side); b := op(i, cast(u32) (1 - side));
        if ic_is_binop(x, .XOR) && has_one_use(x) && pm_imm_constant(op(x, 1)) && !pm_imm_constant(b)
            return create_icmp(pred, icb_xor(op(x, 0), b), op(x, 1));
    }
    {
        // (icmp eq/ne (and (add/sub/xor X, P2), P2), P2|0)
        match_and :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
            if !ic_is_binop(v, .AND) || !has_one_use(v) return false, NONE, NONE;
            for side: 0..1 {
                a := op(v, cast(u32) side); m := op(v, cast(u32) (1 - side));
                ok, b := ic_c_binop_specific(m, .ADD, a);
                if ok return true, a, b;
                ok, b = ic_c_binop_specific(m, .XOR, a);
                if ok return true, a, b;
                if ic_is_binop(m, .SUB) && op(m, 1) == a return true, a, op(m, 0);
            }
            return false, NONE, NONE;
        }
        is_zero: s8 = -1;
        a, b: Value_Id = NONE;
        for side: 0..1 {
            ok, aa, bb := match_and(op(i, cast(u32) side));
            if ok && op(i, cast(u32) (1 - side)) == aa { is_zero = 0; a = aa; b = bb; break; }
        }
        if is_zero < 0 {
            ok, aa, bb := match_and(op0);
            if ok && pm_zero(op1) { is_zero = 1; a = aa; b = bb; }
        }
        if is_zero >= 0 && ic_is_known_to_be_power_of_two(a, true, i)
            return create_icmp(pred, icb_and(b, a), ifx is_zero == 1 then a else const_null_value(vtype(a)));
    }
    r = ic_fold_icmp_equality_with_offset(i, ic_q(i)); if r != NONE return r;
    return NONE;
}

// foldICmpWithTrunc
ic_fold_icmp_with_trunc :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    op0 := op(cmp, 0); op1 := op(cmp, 1);
    okt, x := pmi_cast(op0, .TRUNC);
    okc, c := pm_apint(op1);
    if !okt || !has_one_use(op0) || !okc return NONE;
    okd, res := decompose_bit_test_icmp(op0, op1, pred, true, true);
    if okd {
        a := icb_and(res.x, const_int_ap(vtype(res.x), res.mask));
        cc := const_int_ap(vtype(res.x), res.c);
        return create_icmp(res.pred, a, cc);
    }
    src_bits := scalar_bits(x);
    id := call_iid(x);
    if id == IID_CTTZ || id == IID_CTLZ {
        max_ret := src_bits;
        if pm_one(op(x, 1)) max_ret -= 1;
        // Log2_32(MaxRet) + 1 in unsigned arithmetic: 0 for MaxRet == 0
        lg := ifx max_ret == 0 then cast(u32) 0 else (63 - clz64(cast(u64) max_ret)) + 1;
        if lg <= scalar_bits(op0) {
            r := ic_fold_icmp_intrinsic_with_constant(cmp, x, ap_zext(c, src_bits)); if r != NONE return r;
        }
    }
    return NONE;
}

// foldICmpWithZextOrSext
ic_fold_icmp_with_zext_or_sext :: (cmp: Value_Id) -> Value_Id {
    c0 := op(cmp, 0);
    okx, x := pmi_zext_or_sext(c0);
    if !okx return NONE;
    pred := inst_pred(cmp);
    signed_ext := inst_op(c0) == .SEXT;
    signed_cmp := icmp_is_signed(pred);
    c1 := op(cmp, 1);
    oky, y := pmi_zext_or_sext(c1);
    if oky {
        z0 := inst_op(c0) == .ZEXT; z1 := inst_op(c1) == .ZEXT;
        if z0 != z1 {
            if icmp_is_equality(pred) && is_int_or_int_vector_n(vtype(x), 1) && is_int_or_int_vector_n(vtype(y), 1)
                return create_icmp(pred, icb_or(x, y), const_null_value(vtype(x)));
            nn0 := z0 && (inst(c0).flags & F_EXACT) != 0;
            nn1 := z1 && (inst(c1).flags & F_EXACT) != 0;
            if nn0 || nn1 signed_ext = true;
            else return NONE;
        }
        xt := vtype(x); yt := vtype(y);
        if xt != yt {
            if !has_one_use(c0) && !has_one_use(c1) return NONE;
            opc: Opcode = ifx signed_ext then Opcode.SEXT else .ZEXT;
            if scalar_bits(x) < scalar_bits(y) x = icb_cast(opc, x, yt);
            else if scalar_bits(y) < scalar_bits(x) y = icb_cast(opc, y, xt);
            else return NONE;
        }
        if icmp_is_equality(pred) return create_icmp(pred, x, y);
        if signed_cmp && signed_ext return create_icmp(pred, x, y);
        return create_icmp(icmp_unsigned_predicate(pred), x, y);
    }
    if !is_const(c1) return NONE;
    src_ty := vtype(x);
    res := get_lossless_inv_cast(c1, src_ty, inst_op(c0));
    if res != NONE {
        if icmp_is_equality(pred) return create_icmp(pred, x, res);
        if signed_ext && signed_cmp return create_icmp(pred, x, res);
        return create_icmp(icmp_unsigned_predicate(pred), x, res);
    }
    if signed_cmp || !signed_ext || vkind(c1) != .C_INT return NONE;
    if pred == ICMP_ULT return create_icmp(ICMP_SGT, x, const_all_ones_of(src_ty));
    return create_icmp(ICMP_SLT, x, const_null_value(src_ty));
}

// simplifyIntToPtrRoundTripCast (InstructionCombining.cpp)
ic_simplify_int_to_ptr_round_trip_cast :: (v: Value_Id) -> Value_Id {
    if !(is_inst(v) && inst_op(v) == .INTTOPTR) return NONE;
    if dl_type_size_bits(vtype(v)) != dl_type_size_bits(vtype(op(v, 0))) return NONE;
    p := op(v, 0);
    if !(is_inst(p) && inst_op(p) == .PTRTOINT) return NONE;
    if type_addrspace(vtype(v)) == type_addrspace(vtype(op(p, 0))) && dl_type_size_bits(vtype(op(p, 0))) == dl_type_size_bits(vtype(p))
        return op(p, 0);
    return NONE;
}

// foldICmpWithCastOp: icmp (cast x), (cast or constant)
ic_fold_icmp_with_cast_op :: (cmp: Value_Id) -> Value_Id {
    s0 := ic_simplify_int_to_ptr_round_trip_cast(op(cmp, 0));
    s1 := ic_simplify_int_to_ptr_round_trip_cast(op(cmp, 1));
    if s0 != NONE || s1 != NONE
        return create_icmp(inst_pred(cmp), ifx s0 != NONE then s0 else op(cmp, 0), ifx s1 != NONE then s1 else op(cmp, 1));
    c0 := op(cmp, 0);
    if !is_cast_inst(c0) return NONE;
    o1 := op(cmp, 1);
    if !is_const(o1) && !is_cast_inst(o1) return NONE;
    src := op(c0, 0);
    src_ty := vtype(src); dst_ty := vtype(c0);
    compatible :: (ptr_ty: Type_Id, int_ty: Type_Id) -> bool {
        return dl_pointer_type_size_bits(scalar_type(ptr_ty)) == cast(u64) type_bits(scalar_type(int_ty));
    }
    if inst_op(c0) == .PTRTOINT && compatible(src_ty, dst_ty) {
        nop1: Value_Id = NONE;
        if opr_code(o1) == .PTRTOINT {
            if vtype(op(o1, 0)) == vtype(src) nop1 = op(o1, 0);
        } else if is_const(o1) {
            nop1 = cfo_constant(ce_cast(.INTTOPTR, o1, src_ty));
        }
        if nop1 != NONE return create_icmp(inst_pred(cmp), src, nop1);
    }
    if inst_op(c0) == .INTTOPTR && compatible(dst_ty, src_ty) {
        nop1: Value_Id = NONE;
        if is_inst(o1) && inst_op(o1) == .INTTOPTR {
            if vtype(op(o1, 0)) == vtype(src) nop1 = op(o1, 0);
        } else if is_const(o1) {
            nop1 = cfo_constant(ce_cast(.PTRTOINT, o1, src_ty));
        }
        if nop1 != NONE return create_icmp(inst_pred(cmp), src, nop1);
    }
    r := ic_fold_icmp_with_trunc(cmp); if r != NONE return r;
    return ic_fold_icmp_with_zext_or_sext(cmp);
}
// DataLayout::getPointerTypeSizeInBits
dl_pointer_type_size_bits :: (t: Type_Id) -> u64 { return cast(u64) dl_ptr_spec(type_addrspace(t)).bits; }

// isNeutralValue
ic_is_neutral_value :: (opc: Opcode, rhs: Value_Id, is_signed: bool) -> bool {
    if opc == .ADD || opc == .SUB return pm_zero(rhs);
    return !(is_int_or_int_vector_n(vtype(rhs), 1) && is_signed) && pm_one(rhs);
}

// computeOverflow
ic_compute_overflow :: (opc: Opcode, is_signed: bool, lhs: Value_Id, rhs: Value_Id, cxt: Value_Id) -> Overflow_Result {
    q := ic_q(cxt);
    if opc == {
        case .ADD; return ifx is_signed then compute_overflow_for_signed_add(lhs, rhs, q) else compute_overflow_for_unsigned_add(lhs, rhs, q);
        case .SUB; return ifx is_signed then compute_overflow_for_signed_sub(lhs, rhs, q) else compute_overflow_for_unsigned_sub(lhs, rhs, q);
        case .MUL; return ifx is_signed then compute_overflow_for_signed_mul(lhs, rhs, q) else compute_overflow_for_unsigned_mul(lhs, rhs, q);
    }
    fatal("internal: Unsupported binary op");
    return .MAY_OVERFLOW;
}

// OptimizeOverflowCheck: (ok, result, overflow)
ic_optimize_overflow_check :: (opc: Opcode, is_signed: bool, lhs_in: Value_Id, rhs_in: Value_Id, orig: Value_Id) -> (bool, Value_Id, Value_Id) {
    lhs := lhs_in; rhs := rhs_in;
    if ic_inst_is_commutative(orig) && is_const(lhs) && !is_const(rhs) { t := lhs; lhs = rhs; rhs = t; }
    icb_set_insert_point(orig);
    ov_ty := ir.t_i1;
    if is_vector_type(vtype(lhs)) ov_ty = vector_with_elt(vtype(lhs), ir.t_i1);
    if ic_is_neutral_value(opc, rhs, is_signed) return true, lhs, get_false(ov_ty);
    r := ic_compute_overflow(opc, is_signed, lhs, rhs, orig);
    if r == .MAY_OVERFLOW return false, NONE, NONE;
    res := icb_binop(opc, lhs, rhs);
    ic_take_name(res, orig);
    if r == .ALWAYS_OVERFLOWS_LOW || r == .ALWAYS_OVERFLOWS_HIGH return true, res, get_true(ov_ty);
    if is_inst(res) { if is_signed set_nsw(res); else set_nuw(res); }
    return true, res, get_false(ov_ty);
}
// Instruction::isCommutative (IntrinsicInst::isCommutative for intrinsic calls, else by opcode)
ic_inst_is_commutative :: (i: Value_Id) -> bool {
    id := call_iid(i);
    if id != NOT_INTRINSIC {
        for IC_COMMUTATIVE_IIDS if it == id return true;
        return false;
    }
    return is_commutative_op(inst_op(i));
}
IC_COMMUTATIVE_IIDS :: Intrinsic_Id.[IID_MAXNUM, IID_MINNUM, IID_MAXIMUM, IID_MINIMUM, IID_MAXIMUMNUM, IID_MINIMUMNUM, IID_SMAX, IID_SMIN, IID_UMAX, IID_UMIN,
    IID_SADD_SAT, IID_UADD_SAT, IID_SADD_WITH_OVERFLOW, IID_UADD_WITH_OVERFLOW, IID_SMUL_WITH_OVERFLOW, IID_UMUL_WITH_OVERFLOW,
    IID_SMUL_FIX, IID_UMUL_FIX, IID_SMUL_FIX_SAT, IID_UMUL_FIX_SAT, IID_FMA, IID_FMULADD];

// processUMulZExtIdiom
ic_process_umul_zext_idiom :: (i: Value_Id, mul_val: Value_Id, other_val: APInt) -> Value_Id {
    if !is_int_type(vtype(mul_val)) return NONE;
    if !is_inst(mul_val) return NONE;
    lhs := op(mul_val, 0); rhs := op(mul_val, 1);
    a := op(lhs, 0); b := op(rhs, 0);
    ta := vtype(a); tb := vtype(b);
    wa := type_bits(ta); wb := type_bits(tb);
    mul_width: u32; mul_type: Type_Id;
    if wb > wa { mul_width = wb; mul_type = tb; } else { mul_width = wa; mul_type = ta; }
    if has_n_uses_or_more(mul_val, 2) {
        u := ir.v_first_use[mul_val];
        while u != NONE {
            defer u = ir.u_next[u];
            us := ir.u_user[u];
            if us == i continue;
            if is_inst(us) && inst_op(us) == .TRUNC {
                if ic_primitive_size_bits(vtype(us)) > mul_width return NONE;
            } else if is_inst(us) && is_binary_operator(us) {
                if inst_op(us) != .AND return NONE;
                ci := op(us, 1);
                if vkind(ci) == .C_INT && !is_vector_type(vtype(ci)) {
                    cv := const_ap(ci);
                    if cv.bits - ap_clz(cv) > mul_width return NONE;
                } else return NONE;
            } else return NONE;
        }
    }
    pred := inst_pred(i);
    if pred == ICMP_UGT {
        max_val := ap_zext(ap_all_ones(mul_width), other_val.bits);
        if !ap_eq(max_val, other_val) return NONE;
    } else if pred == ICMP_ULT {
        max_val := ap_one_bit_set(other_val.bits, mul_width);
        if !ap_eq(max_val, other_val) return NONE;
    } else return NONE;
    icb_set_insert_point(mul_val);
    mul_a := a; mul_b := b;
    if wa < mul_width mul_a = icb_zext(a, mul_type);
    if wb < mul_width mul_b = icb_zext(b, mul_type);
    call := icb_intrinsic(IID_UMUL_WITH_OVERFLOW, .[mul_type], .[mul_a, mul_b], "umul");
    wl_push(mul_val);
    if has_n_uses_or_more(mul_val, 2) {
        mul := icb_extract_value(call, .[0], "umul.value");
        users: [..] Value_Id; users.allocator = temp;
        u := ir.v_first_use[mul_val];
        while u != NONE { array_add(*users, ir.u_user[u]); u = ir.u_next[u]; }
        for us: users {
            if us == i continue;
            if inst_op(us) == .TRUNC {
                if ic_primitive_size_bits(vtype(us)) == mul_width ic_replace_inst_uses_with(us, mul);
                else set_op(us, 0, mul);
            } else {
                short_mask := ap_trunc(const_ap(op(us, 1)), mul_width);
                short_and := icb_and(mul, const_int_ap(mul_type, short_mask));
                zext := icb_zext(short_and, vtype(us));
                ic_replace_inst_uses_with(us, zext);
            }
            wl_push(us);
        }
    }
    if pred == ICMP_ULT {
        res := icb_extract_value(call, .[1]);
        return create_not(res);
    }
    return create_extract_value(call, .[1]);
}

// getDemandedBitsLHSMask
ic_get_demanded_bits_lhs_mask :: (i: Value_Id, bw: u32) -> APInt {
    ok, rhs := pm_apint(op(i, 1));
    if !ok return ap_all_ones(bw);
    is_sb, _ := is_sign_bit_check(inst_pred(i), rhs);
    if is_sb return ap_signed_min(bw);
    p := inst_pred(i);
    if p == ICMP_UGT return ap_bits_set_from(bw, ap_cto(rhs));
    if p == ICMP_ULT return ap_bits_set_from(bw, ap_ctz(rhs));
    return ap_all_ones(bw);
}

// dominatesAllUses
ic_dominates_all_uses :: (di: Value_Id, ui: Value_Id, db: Value_Id) -> bool {
    if inst_block(di) == NONE return false;
    if inst_block(di) != inst_block(ui) return false;
    if inst_block(di) == db return false;
    u := ir.v_first_use[di];
    while u != NONE {
        us := ir.u_user[u];
        if us != ui && !dt_dominates(ic.dt, db, inst_block(us)) return false;
        u = ir.u_next[u];
    }
    return true;
}

// isChainSelectCmpBranch
ic_is_chain_select_cmp_branch :: (si: Value_Id) -> bool {
    bb := inst_block(si);
    if bb == NONE return false;
    bi := block_terminator(bb);
    if bi == NONE || inst_op(bi) != .CONDBR return false;
    c := op(bi, 0);
    if !(is_inst(c) && inst_op(c) == .ICMP) || (op(c, 0) != si && op(c, 1) != si) return false;
    return true;
}

// replacedSelectWithOperand
ic_replaced_select_with_operand :: (si: Value_Id, icmp: Value_Id, si_opd: u32) -> bool {
    if ic_is_chain_select_cmp_branch(si) && inst_pred(icmp) == ICMP_EQ {
        succ := get_successor(block_terminator(inst_block(si)), 1);
        if block_single_predecessor(succ) != NONE && ic_dominates_all_uses(si, icmp, succ) {
            nv := op(si, si_opd);
            bb := inst_block(si);
            u := ir.v_first_use[si];
            while u != NONE {
                nx := ir.u_next[u];
                us := ir.u_user[u];
                if !is_inst(us) || inst_block(us) != bb use_set(u, nv);
                u = nx;
            }
            return true;
        }
    }
    return false;
}


// foldICmpUsingKnownBits
ic_fold_icmp_using_known_bits :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    ty := vtype(op0);
    pred := inst_pred(i);
    bw: u32 = ifx is_int_or_int_vector(ty) then scalar_bits(op0) else cast(u32) dl_pointer_type_size_bits(scalar_type(ty));
    if bw == 0 return NONE;
    k0 := kb_new(bw); k1 := kb_new(bw);
    {
        q := sq_with_instruction(ic.sq, i);
        q.dc = null;
        if ic_simplify_demanded_bits(i, 0, ic_get_demanded_bits_lhs_mask(i, bw), *k0, q, 0) return i;
        if ic_simplify_demanded_bits(i, 1, ap_all_ones(bw), *k1, q, 0) return i;
    }
    op0 = op(i, 0); op1 = op(i, 1);
    if !is_const(op0) && kb_is_constant(k0) return create_icmp(pred, const_integer_value(ty, kb_constant(k0)), op1);
    if !is_const(op1) && kb_is_constant(k1) return create_icmp(pred, op0, const_integer_value(ty, kb_constant(k1)));
    res := icmp_compare_known(k0, k1, pred);
    if res >= 0 return ic_replace_inst_uses_with(i, cf_bool(vtype(i), res == 1));
    min0, max0, min1, max1: APInt;
    if icmp_is_signed(pred) {
        min0 = kb_signed_min_value(k0); max0 = kb_signed_max_value(k0);
        min1 = kb_signed_min_value(k1); max1 = kb_signed_max_value(k1);
    } else {
        min0 = kb_min_value(k0); max0 = kb_max_value(k0);
        min1 = kb_min_value(k1); max1 = kb_max_value(k1);
    }
    is_min_max_cmp :: (cmp: Value_Id, op0: Value_Id, op1: Value_Id) -> bool {
        if !has_one_use(cmp) return false;
        sp, _, _ := match_select_pattern(first_user(cmp));
        if !spf_is_min_or_max(sp.flavor) return false;
        return pm_max_or_min_any(op0) || pm_max_or_min_any(op1);
    }
    if !is_min_max_cmp(i, op0, op1) {
        okc, cmpc := pm_apint(op1);
        if pred == {
            case ICMP_ULT;
                if ap_eq(min1, max0) return create_icmp(ICMP_NE, op0, op1);
                if okc {
                    if ap_eq(cmpc, ap_add_u64(min0, 1)) return create_icmp(ICMP_EQ, op0, const_int_ap(vtype(op1), ap_sub_u64(cmpc, 1)));
                    if kb_count_min_trailing_zeros(k0) >= ap_ceil_log2(cmpc) return create_icmp(ICMP_EQ, op0, const_null_value(vtype(op1)));
                }
            case ICMP_UGT;
                if ap_eq(max1, min0) return create_icmp(ICMP_NE, op0, op1);
                if okc {
                    if ap_eq(cmpc, ap_sub_u64(max0, 1)) return create_icmp(ICMP_EQ, op0, const_int_ap(vtype(op1), ap_add_u64(cmpc, 1)));
                    if kb_count_min_trailing_zeros(k0) >= ap_active_bits(cmpc) return create_icmp(ICMP_NE, op0, const_null_value(vtype(op1)));
                }
            case ICMP_SLT;
                if ap_eq(min1, max0) return create_icmp(ICMP_NE, op0, op1);
                if okc && ap_eq(cmpc, ap_add_u64(min0, 1)) return create_icmp(ICMP_EQ, op0, const_int_ap(vtype(op1), ap_sub_u64(cmpc, 1)));
            case ICMP_SGT;
                if ap_eq(max1, min0) return create_icmp(ICMP_NE, op0, op1);
                if okc && ap_eq(cmpc, ap_sub_u64(max0, 1)) return create_icmp(ICMP_EQ, op0, const_int_ap(vtype(op1), ap_add_u64(cmpc, 1)));
        }
    }
    if pred == {
        case ICMP_EQ; #through;
        case ICMP_NE;
            kzi := ap_not(k0.zero);
            if kb_is_zero(k1) {
                lhs := op0;
                oka, _, andc := pm_binop(op0, .AND);
                okl, lhsc := pm_apint(andc);
                if !(oka && okl) || !ap_eq(lhsc, kzi) lhs = op0;
                else lhs = op(op0, 0);
                if ic_is_binop(lhs, .SHL) {
                    okp, c1 := pm_power2_ap(op(lhs, 0));
                    if okp {
                        x := op(lhs, 1);
                        log2c1 := ap_ctz(c1);
                        c2 := kzi;
                        c2p2 := ap_add(ap_and(c2, ap_not(ap_sub_u64(c1, 1))), c1);
                        if ap_is_power_of_2(c2p2) {
                            log2c2 := ap_ctz(c2p2);
                            cmpc := const_int_of(vtype(x), cast(u64) (log2c2 - log2c1));
                            return create_icmp(ifx pred == ICMP_EQ then cast(u8) ICMP_UGE else ICMP_ULT, x, cmpc);
                        }
                    }
                }
            }
            if kb_is_constant(k1) && ap_is_power_of_2(kb_constant(k1)) && kb_eq_kb(kb_and(k0, k1), k0)
                return create_icmp(cmp_inverse(pred), op0, const_null_value(vtype(op1)));
        case ICMP_SGE; if ap_eq(min1, max0) return create_icmp(ICMP_EQ, op0, op1);
        case ICMP_SLE; if ap_eq(max1, min0) return create_icmp(ICMP_EQ, op0, op1);
        case ICMP_UGE; if ap_eq(min1, max0) return create_icmp(ICMP_EQ, op0, op1);
        case ICMP_ULE; if ap_eq(max1, min0) return create_icmp(ICMP_EQ, op0, op1);
    }
    samesign := (inst(i).flags & F_EXACT) != 0;
    if (icmp_is_signed(pred) || (icmp_is_unsigned(pred) && !samesign)) &&
       ((ap_sign_bit(k0.zero) && ap_sign_bit(k1.zero)) || (ap_sign_bit(k0.one) && ap_sign_bit(k1.one))) {
        inst(i).pred = icmp_unsigned_predicate(pred);
        set_flag(i, F_EXACT, true);
        return i;
    }
    return NONE;
}

// foldICmpUsingBoolRange
ic_fold_icmp_using_bool_range :: (i: Value_Id) -> Value_Id {
    for side: 0..1 {
        pred := inst_pred(i); if side == 1 pred = cmp_swapped(pred);
        x := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        okz, y := pmi_cast(z, .ZEXT);
        if okz && has_one_use(z) {
            if is_int_or_int_vector_n(vtype(y), 1) && pred == ICMP_ULT return create_binop(.AND, icb_is_null(x), y);
            break;
        }
    }
    for side: 0..1 {
        pred := inst_pred(i); if side == 1 pred = cmp_swapped(pred);
        x := op(i, cast(u32) side); z := op(i, cast(u32) (1 - side));
        oks, y := pmi_cast(z, .SEXT);
        if oks && has_one_use(z) {
            if is_int_or_int_vector_n(vtype(y), 1) && pred == ICMP_ULE return create_binop(.OR, icb_is_null(x), y);
            break;
        }
    }
    for side: 0..1 {
        pred1 := inst_pred(i); if side == 1 pred1 = cmp_swapped(pred1);
        x := op(i, cast(u32) side); ext := op(i, cast(u32) (1 - side));
        oke, ic2 := pmi_zext_or_sext(ext);
        if !oke continue;
        okc, pred2, _, cx, cc := pm_icmp(ic2);
        if !okc || cx != x continue;
        okk, c := pm_apint(cc);
        if !okk continue;
        if !icmp_is_equality(pred1) || !icmp_is_equality(pred2) return NONE;
        is_sext := inst_op(ext) == .SEXT;
        one_use := has_one_use(ext) && has_one_use(op(ext, 0));
        create_range_check :: (pred1: u8, x: Value_Id, is_sext: bool) -> Value_Id {
            v1 := icb_cmp(pred1, x, const_null_value(vtype(x)));
            v2 := icb_cmp(pred1, x, const_int_signed(vtype(x), ifx is_sext then -1 else 1));
            return create_binop(ifx pred1 == ICMP_EQ then Opcode.OR else .AND, v1, v2);
        }
        if ap_is_zero(c) {
            if pred2 == ICMP_EQ return ic_replace_inst_uses_with(i, cf_bool(vtype(i), pred1 == ICMP_NE));
            else if !is_sext || one_use return create_range_check(pred1, x, is_sext);
        } else if ifx is_sext then ap_is_all_ones(c) else ap_is_one(c) {
            if pred2 == ICMP_NE return ic_replace_inst_uses_with(i, cf_bool(vtype(i), pred1 == ICMP_NE));
            else if !is_sext || one_use return create_range_check(pred1, x, is_sext);
        } else {
            return create_icmp(pred1, x, const_int_signed(vtype(x), ifx pred2 == ICMP_NE then (ifx is_sext then -1 else 1) else 0));
        }
        return NONE;
    }
    return NONE;
}

// ---------------------------------------------------------------- canonicalizations (moved here from ic_misc.jai)

// foldICmpTruncWithTruncOrExt
ic_fold_icmp_trunc_with_trunc_or_ext :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    o0 := op(cmp, 0); o1 := op(cmp, 1);
    x, y: Value_Id = NONE;
    y_is_sext := false;
    ok0, x0 := pmi_cast(o0, .TRUNC);
    ok1, y1 := pmi_cast(o1, .TRUNC);
    if ok0 && ok1 {
        nw := inst(o0).flags & inst(o1).flags & cast(u32)(F_NUW | F_NSW);
        if icmp_is_signed(pred) { if (nw & F_NSW) == 0 return NONE; }
        else if nw == 0 return NONE;
        x = x0; y = y1;
        if vtype(x) != vtype(y) && (!has_one_use(o0) || !has_one_use(o1)) return NONE;
        if !ic_is_desirable_int_type(scalar_bits(x)) && ic_is_desirable_int_type(scalar_bits(y)) {
            t := x; x = y; y = t;
            pred = swapped_predicate(pred);
        }
        y_is_sext = (nw & F_NUW) == 0;
    } else {
        found := false;
        if !icmp_is_signed(pred) {
            for side: 0..1 {
                t := op(cmp, cast(u32) side); z := op(cmp, cast(u32) (1 - side));
                okt, tx := pmi_cast(t, .TRUNC);
                okz, zy := pmi_cast(z, .ZEXT);
                if okt && has_nuw(t) && okz && has_one_use(z) {
                    x = tx; y = zy; found = true;
                    if side == 1 pred = swapped_predicate(pred);
                    break;
                }
            }
        }
        if !found {
            for side: 0..1 {
                t := op(cmp, cast(u32) side); z := op(cmp, cast(u32) (1 - side));
                okt, tx := pmi_cast(t, .TRUNC);
                okz, zy := pmi_zext_or_sext(z);
                if okt && has_nsw(t) && okz && has_one_use(z) {
                    x = tx; y = zy; found = true;
                    if side == 1 pred = swapped_predicate(pred);
                    y_is_sext = inst_op(o0) == .SEXT || inst_op(o1) == .SEXT;
                    break;
                }
            }
        }
        if !found return NONE;
    }
    tbits := scalar_bits(o0);
    if ic_is_desirable_int_type(tbits) && !ic_is_desirable_int_type(scalar_bits(x)) return NONE;
    ny := icb_int_cast(y, vtype(x), y_is_sext);
    return create_icmp(pred, x, ny);
}

// canonicalizeICmpBool
ic_canonicalize_icmp_bool :: (i: Value_Id) -> Value_Id {
    a := op(i, 0); b := op(i, 1);
    p := inst_pred(i);
    if pm_zero(b) {
        if p == ICMP_EQ || p == ICMP_ULE || p == ICMP_SGE return create_not(a);
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    } else if pm_one(b) {
        if p == ICMP_NE || p == ICMP_ULT || p == ICMP_SGT return create_not(a);
        fatal("internal: ICmp i1 X, C not simplified as expected.");
    }
    if p == {
        case ICMP_EQ; return create_not(icb_xor(a, b));
        case ICMP_NE; return create_binop(.XOR, a, b);
        case ICMP_UGT; return create_binop(.AND, icb_not(b), a);
        case ICMP_ULT; return create_binop(.AND, icb_not(a), b);
        case ICMP_SGT; return create_binop(.AND, icb_not(a), b);
        case ICMP_SLT; return create_binop(.AND, icb_not(b), a);
        case ICMP_UGE; return create_binop(.OR, icb_not(b), a);
        case ICMP_ULE; return create_binop(.OR, icb_not(a), b);
        case ICMP_SGE; return create_binop(.OR, icb_not(a), b);
        case ICMP_SLE; return create_binop(.OR, icb_not(b), a);
    }
    fatal("internal: Invalid icmp instruction!");
    return NONE;
}

// canonicalizeCmpWithConstant
ic_canonicalize_cmp_with_constant :: (i: Value_Id) -> Value_Id {
    p := inst_pred(i);
    if icmp_is_equality(p) || !is_int_predicate(p) || is_canonical_predicate(p) return NONE;
    c := op(i, 1);
    if !is_const(c) return NONE;
    ok, np, nc := flipped_strictness_predicate_and_constant(p, c);
    if !ok return NONE;
    return create_icmp(np, op(i, 0), nc);
}
// canonicalizeICmpPredicate
ic_canonicalize_icmp_predicate :: (i: Value_Id) -> Value_Id {
    p := inst_pred(i);
    if is_canonical_predicate(p) return NONE;
    if !can_freely_invert_all_users_of(i, NONE) return NONE;
    inst(i).pred = cmp_inverse(p);
    set_name(i, tprint("%.not", vname(i)));
    ic_freely_invert_all_users_of(i);
    return i;
}
// ---------------------------------------------------------------- the remaining icmp folds

// foldICmpWithHighBitMask
ic_fold_icmp_with_high_bit_mask :: (cmp: Value_Id) -> Value_Id {
    pred, new_pred: u8;
    x, y: Value_Id = NONE;
    found := false;
    for side: 0..1 {
        sh := op(cmp, cast(u32) side);
        if ic_is_binop(sh, .SHL) && has_one_use(sh) && pm_one(op(sh, 0)) {
            y = op(sh, 1); x = op(cmp, cast(u32) (1 - side));
            pred = inst_pred(cmp); if side == 1 pred = cmp_swapped(pred);
            found = true; break;
        }
    }
    if found {
        if pred == ICMP_ULE new_pred = ICMP_NE;
        else if pred == ICMP_UGT new_pred = ICMP_EQ;
        else return NONE;
    } else {
        for side: 0..1 {
            m := op(cmp, cast(u32) side);
            if !has_one_use(m) continue;
            okn, ns := pm_not(m);
            if okn && ic_is_binop(ns, .SHL) && pm_all_ones(op(ns, 0)) { y = op(ns, 1); found = true; }
            if !found && ic_is_binop(m, .ADD) && pm_all_ones(op(m, 1)) {
                s := op(m, 0);
                if ic_is_binop(s, .SHL) && pm_one(op(s, 0)) { y = op(s, 1); found = true; }
            }
            if found {
                x = op(cmp, cast(u32) (1 - side));
                pred = inst_pred(cmp); if side == 1 pred = cmp_swapped(pred);
                break;
            }
        }
        if !found return NONE;
        if pred == ICMP_ULT new_pred = ICMP_NE;
        else if pred == ICMP_UGE new_pred = ICMP_EQ;
        else return NONE;
    }
    nx := icb_lshr(x, y, tprint("%.highbits", vname(x)));
    return create_icmp(new_pred, nx, const_null_value(vtype(nx)));
}

// foldVectorCmp
ic_fold_vector_cmp :: (cmp: Value_Id) -> Value_Id {
    pred := inst_pred(cmp);
    lhs := op(cmp, 0); rhs := op(cmp, 1);
    create_cmp_reverse :: (cmp: Value_Id, pred: u8, x: Value_Id, y: Value_Id) -> Value_Id {
        v := icb_cmp(pred, x, y, name_ref(vname(cmp)));
        if is_inst(v) copy_ir_flags(v, cmp);
        return create_intrinsic_call(IID_VECTOR_REVERSE, .[vtype(v)], .[v]);
    }
    okl, v1 := pm_intrinsic1(lhs, IID_VECTOR_REVERSE);
    if okl {
        okr, v2 := pm_intrinsic1(rhs, IID_VECTOR_REVERSE);
        if okr && (has_one_use(lhs) || has_one_use(rhs)) return create_cmp_reverse(cmp, pred, v1, v2);
        if has_one_use(lhs) && is_splat_value(rhs) return create_cmp_reverse(cmp, pred, v1, rhs);
    } else if is_splat_value(lhs) {
        okr, v2 := pm_intrinsic1(rhs, IID_VECTOR_REVERSE);
        if okr && has_one_use(rhs) return create_cmp_reverse(cmp, pred, lhs, v2);
    }
    oks, sv1, su, m := pm_shuffle(lhs);
    if !oks || !pm_undef(su) return NONE;
    v1t := vtype(sv1);
    oks2, sv2, su2, m2 := pm_shuffle(rhs);
    if oks2 && pm_undef(su2) && masks_equal(m, m2) && v1t == vtype(sv2) && (has_one_use(lhs) || has_one_use(rhs)) {
        nc := icb_cmp(pred, sv1, sv2);
        return create_shuffle(nc, NONE, m);
    }
    if !has_one_use(lhs) || !is_const(rhs) return NONE;
    scalar_c := get_splat_value(rhs, true);
    if scalar_c != NONE {
        first: s64 = -1;
        for m if it != 0xFFFF_FFFF { first = it; break; }
        if first >= 0 {
            all := true;
            for m if it != 0xFFFF_FFFF && cast(s64) it != first { all = false; break; }
            if all {
                c := cf_get_splat(v1t, scalar_c);
                nm := NewArray(m.count, u32,, allocator = temp);
                for * nm it.* = cast(u32) first;
                nc := icb_cmp(pred, sv1, c);
                return create_shuffle(nc, NONE, nm);
            }
        }
    }
    return NONE;
}

// foldICmpOfUAddOv
ic_fold_icmp_of_uadd_ov :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    op0 := op(i, 0); op1 := op(i, 1);
    uadd_res :: (v: Value_Id) -> (bool, Value_Id, Value_Id) {
        if !(is_inst(v) && inst_op(v) == .EXTRACTVALUE) return false, NONE, NONE;
        idx := inst_indices(v);
        if idx.count != 1 || idx[0] != 0 return false, NONE, NONE;
        agg := op(v, 0);
        if call_iid(agg) != IID_UADD_WITH_OVERFLOW return false, NONE, NONE;
        return true, op(agg, 0), op(agg, 1);
    }
    uadd_ov: Value_Id = NONE;
    ok0, a, b := uadd_res(op0);
    if ok0 && ((pred == ICMP_ULT && (op1 == a || op1 == b)) ||
               (pred == ICMP_EQ && pm_zero_int(op1) && (pm_one(a) || pm_one(b))) ||
               (pred == ICMP_NE && pm_all_ones(op1) && (pm_all_ones(a) || pm_all_ones(b)))) {
        uadd_ov = op(op0, 0);
    } else {
        ok1, a1, b1 := uadd_res(op1);
        if ok1 && pred == ICMP_UGT && (op0 == a1 || op0 == b1) uadd_ov = op(op1, 0);
        else return NONE;
    }
    return create_extract_value(uadd_ov, .[1]);
}

// foldICmpInvariantGroup
ic_fold_icmp_invariant_group :: (i: Value_Id) -> Value_Id {
    o0 := op(i, 0);
    if !is_ptr_type(vtype(o0)) || null_pointer_is_defined(inst_fn(i), type_addrspace(vtype(o0))) return NONE;
    id := call_iid(o0);
    if is_inst(o0) && pm_zero(op(i, 1)) && (id == IID_LAUNDER_INVARIANT_GROUP || id == IID_STRIP_INVARIANT_GROUP)
        return create_icmp(inst_pred(i), op(o0, 0), op(i, 1));
    return NONE;
}

// DataLayout::fitsInLegalInteger
dl_fits_in_legal_integer :: (width: u64) -> bool {
    for dl.legal_ints if it >= width return true;
    return false;
}

// foldICmpOfVectorReduce
ic_fold_icmp_of_vector_reduce :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    if !icmp_is_equality(pred) return NONE;
    o := op(i, 0); cst := op(i, 1);
    vec: Value_Id = NONE;
    if pm_zero_int(cst) && call_iid(o) == IID_VECTOR_REDUCE_OR && has_one_use(o) vec = op(o, 0);
    else if pm_all_ones(cst) && call_iid(o) == IID_VECTOR_REDUCE_AND && has_one_use(o) vec = op(o, 0);
    if vec == NONE return NONE;
    vt := vtype(vec);
    if type_kind(vt) != .VECTOR return NONE;
    sbw := dl_type_size_bits(type_elem(vt)) * type_count(vt);
    if !dl_fits_in_legal_integer(sbw) return NONE;
    st := type_int(cast(u32) sbw);
    nc := ifx pm_zero_int(cst) then const_int_of(st, 0) else const_all_ones_of(st);
    return create_icmp(pred, icb_cast(.BITCAST, vec, st), nc);
}

// foldReductionIdiom
ic_fold_reduction_idiom :: (i: Value_Id) -> Value_Id {
    if is_vector_type(vtype(i)) return NONE;
    outer := inst_pred(i);
    bc := op(i, 0);
    if !(is_inst(bc) && inst_op(bc) == .BITCAST && has_one_use(bc)) || !pm_zero(op(i, 1)) return NONE;
    inner_cmp := op(bc, 0);
    okc, inner, _, lhs, rhs := pm_icmp(inner_cmp);
    if !okc || !has_one_use(inner_cmp) return NONE;
    lt := vtype(lhs);
    if type_kind(lt) != .VECTOR || !is_int_type(type_elem(lt)) return NONE;
    num_bits := type_count(lt) * cast(u64) type_int_width(type_elem(lt));
    if !dl_is_legal_integer(num_bits) return NONE;
    if icmp_is_equality(outer) && inner == ICMP_NE {
        st := type_int(cast(u32) num_bits);
        l := icb_cast(.BITCAST, lhs, st, tprint("%.scalar", vname(lhs)));
        r := icb_cast(.BITCAST, rhs, st, tprint("%.scalar", vname(rhs)));
        return create_icmp(outer, l, r);
    }
    return NONE;
}

// foldICmpCommutative (called with the operands in both orders)
ic_fold_icmp_commutative :: (pred: u8, samesign: bool, op0: Value_Id, op1: Value_Id, cxt: Value_Id) -> Value_Id {
    if is_gep_operator(op0) {
        r := ic_fold_gep_icmp(op0, op1, pred, cxt); if r != NONE return r;
    }
    if is_inst(op0) && inst_op(op0) == .SELECT {
        r := ic_fold_select_icmp(pred, samesign, op0, op1, cxt); if r != NONE return r;
    }
    if pm_max_or_min_any(op0) {
        r := ic_fold_icmp_with_min_max(cxt, op0, op1, pred); if r != NONE return r;
        r = ic_fold_icmp_with_clamp(cxt, op1, op0); if r != NONE return r;
    }
    {
        if ic_is_binop(op0, .ADD) {
            okc, c := pm_apint(op(op0, 1));
            if okc && op1 == op(op0, 0) return ic_fold_icmp_add_op_const(op(op0, 0), c, pred);
        }
    }
    {
        okab, x, c := pm_intrinsic2(op0, IID_ABS);
        if okab && is_const(c) && op1 == x {
            xt := vtype(x);
            smin := ap_signed_min(scalar_bits(x));
            int_min_poison := cf_is_all_ones(c);
            if pred == {
                case ICMP_ULE; #through;
                case ICMP_SGE; return ic_replace_inst_uses_with(cxt, get_true(vtype(cxt)));
                case ICMP_UGT; #through;
                case ICMP_SLT; return ic_replace_inst_uses_with(cxt, get_false(vtype(cxt)));
                case ICMP_UGE; #through;
                case ICMP_SLE; #through;
                case ICMP_EQ;
                    return ic_replace_inst_uses_with(cxt, ifx int_min_poison then icb_cmp(ICMP_SGT, x, const_all_ones_of(xt))
                                                                            else icb_cmp(ICMP_ULT, x, const_int_ap(xt, ap_add_u64(smin, 1))));
                case ICMP_ULT; #through;
                case ICMP_SGT; #through;
                case ICMP_NE;
                    return ic_replace_inst_uses_with(cxt, ifx int_min_poison then icb_cmp(ICMP_SLT, x, const_null_value(xt))
                                                                            else icb_cmp(ICMP_UGT, x, const_int_ap(xt, smin)));
            }
            fatal("internal: Invalid predicate!");
        }
    }
    q := ic_q(cxt);
    v := ic_fold_icmp_with_low_bit_masked_val(pred, op0, op1, q);
    if v != NONE return ic_replace_inst_uses_with(cxt, v);
    ugt1 :: (a: APInt, unused: APInt) -> bool { return ap_ugt_u64(a, 1); }
    dummy := ap_zero(1);
    if ic_is_binop(op0, .UDIV) && op(op0, 0) == op1 && pm_int_pred_arg(op(op0, 1), ugt1, dummy)
        return create_icmp(icmp_swapped(pred), op1, const_null_value(vtype(op1)));
    if !icmp_is_unsigned(pred) && ic_is_binop(op0, .SDIV) && op(op0, 0) == op1 && pm_int_pred_arg(op(op0, 1), ugt1, dummy)
        return create_icmp(icmp_swapped(pred), op1, const_null_value(vtype(op1)));
    ne0 :: (a: APInt, unused: APInt) -> bool { return !ap_is_zero(a); }
    if ic_is_binop(op0, .LSHR) && op(op0, 0) == op1 && pm_int_pred_arg(op(op0, 1), ne0, dummy)
        return create_icmp(icmp_swapped(pred), op1, const_null_value(vtype(op1)));
    if (pred == ICMP_SLT || pred == ICMP_SGE) && ic_is_binop(op0, .ASHR) && op(op0, 0) == op1 && pm_int_pred_arg(op(op0, 1), ne0, dummy)
        return create_icmp(icmp_swapped(pred), op1, const_null_value(vtype(op1)));
    {
        oks, x, sh := pm_ob(op0, .SHL, F_NUW);
        oka, sh_amt := pm_constant_int_u64(sh);
        if oks && oka && !icmp_is_signed(inst_pred(cxt)) {
            if sh_amt >= cast(u64) scalar_bits(x) return NONE;
            if ic_can_evaluate_shifted(op1, cast(u32) sh_amt, false, .UNSIGNED, cxt) {
                nop1 := ic_get_shifted_value(op1, cast(u32) sh_amt, false, .UNSIGNED);
                return create_icmp(pred, x, nop1);
            }
        }
    }
    {
        oks, x, sh := pm_ob(op0, .SHL, F_NSW);
        oka, sh_amt := pm_constant_int_u64(sh);
        if oks && oka && !icmp_is_unsigned(inst_pred(cxt)) {
            if sh_amt >= cast(u64) scalar_bits(x) return NONE;
            if ic_can_evaluate_shifted(op1, cast(u32) sh_amt, false, .SIGNED, cxt) {
                nop1 := ic_get_shifted_value(op1, cast(u32) sh_amt, false, .SIGNED);
                return create_icmp(pred, x, nop1);
            }
        }
    }
    return NONE;
}

// ---------------------------------------------------------------- visitICmpInst

ic_visit_icmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    q := ic_q(i);
    op0 := op(i, 0); op1 := op(i, 1);
    if ic_complexity(op0) < ic_complexity(op1) {
        cmp_swap_operands(i);
        t := op0; op0 = op1; op1 = t;
        changed = true;
    }
    v := simplify_icmp_inst(inst_pred(i), (inst(i).flags & F_EXACT) != 0, op0, op1, q);
    if v != NONE return ic_replace_inst_uses_with(i, v);
    if inst_pred(i) == ICMP_NE && pm_zero(op1) {
        ok, cond, st, sf := pm_select(op0);
        if ok {
            nv := ic_dyn_cast_neg_val(st);
            if nv != NONE { if nv == sf return create_icmp(inst_pred(i), nv, op1); }
            else {
                nv = ic_dyn_cast_neg_val(sf);
                if nv != NONE && nv == st return create_icmp(inst_pred(i), nv, op1);
            }
        }
    }
    r := ic_fold_icmp_trunc_with_trunc_or_ext(i); if r != NONE return r;
    if is_int_or_int_vector_n(vtype(op0), 1) { r = ic_canonicalize_icmp_bool(i); if r != NONE return r; }
    r = ic_canonicalize_cmp_with_constant(i); if r != NONE return r;
    r = ic_canonicalize_icmp_predicate(i); if r != NONE return r;
    r = ic_fold_icmp_with_constant(i); if r != NONE return r;
    r = ic_fold_icmp_with_dominating_icmp(i); if r != NONE return r;
    r = ic_fold_icmp_using_bool_range(i); if r != NONE return r;
    r = ic_fold_icmp_using_known_bits(i); if r != NONE return r;
    r = ic_fold_is_multiple_of_a_power_of_two(i); if r != NONE return r;
    op0 = op(i, 0); op1 = op(i, 1);
    if has_one_use(i) {
        us := first_user(i);
        if is_inst(us) && inst_op(us) == .SELECT {
            sp, _, _ := match_select_pattern(us);
            if sp.flavor != .UNKNOWN return NONE;
        }
    }
    r = ic_fold_icmp_with_zero(i); if r != NONE return r;
    {
        okm, x, cv := pm_intrinsic2(op0, IID_UMAX);
        okc, c := pm_apint(cv);
        if okm && okc {
            okn, nx := pm_not(op1);
            if okn && nx == x {
                if inst_pred(i) == ICMP_UGT {
                    if !ap_sign_bit(c) return create_icmp(ICMP_SLT, x, const_null_value(vtype(x)));
                    return create_icmp(ICMP_UGT, x, const_int_ap(vtype(x), ap_not(c)));
                }
                if inst_pred(i) == ICMP_ULT {
                    if !ap_sign_bit(c) return create_icmp(ICMP_SGT, x, const_all_ones_of(vtype(x)));
                    return create_icmp(ICMP_ULT, x, const_int_ap(vtype(x), ap_not(c)));
                }
            }
        }
    }
    pred := inst_pred(i);
    {
        okc, c := pm_apint(op1);
        if okc {
            if pred == ICMP_UGT && ap_is_max_signed(c) return create_icmp(ICMP_SLT, op0, const_null_value(vtype(op0)));
            if pred == ICMP_ULT && ap_is_min_signed(c) return create_icmp(ICMP_SGT, op0, const_all_ones_of(vtype(op0)));
        }
    }
    r = ic_fold_icmp_binop(i, ic.sq); if r != NONE return r;
    r = ic_fold_icmp_inst_with_constant(i); if r != NONE return r;
    r = ic_fold_sign_bit_test(i); if r != NONE return r;
    if is_inst(op0) && inst_op(op0) == .PHI { r = ic_fold_op_into_phi(i, op0); if r != NONE return r; }
    if is_inst(op1) && inst_op(op1) == .PHI { r = ic_fold_op_into_phi(i, op1); if r != NONE return r; }
    r = ic_fold_icmp_inst_with_constant_not_int(i); if r != NONE return r;
    samesign := (inst(i).flags & F_EXACT) != 0;
    r = ic_fold_icmp_commutative(inst_pred(i), samesign, op0, op1, i); if r != NONE return r;
    r = ic_fold_icmp_commutative(cmp_swapped(inst_pred(i)), samesign, op1, op0, i); if r != NONE return r;
    if icmp_is_equality(inst_pred(i)) {
        ok, a, b := ic_match_symmetric_pair(op(i, 0), op(i, 1));
        if ok {
            ic_replace_operand(i, 0, a);
            ic_replace_operand(i, 1, b);
            return i;
        }
    }
    r = ic_fold_cmp_select_of_constants(i); if r != NONE return r;
    {
        oka, cond, a, b := pm_select(op0);
        okb, cond2, c, d := pm_select(op1);
        if oka && okb && cond2 == cond && (has_one_use(op0) || has_one_use(op1)) {
            res := simplify_icmp_inst(pred, false, a, c, ic.sq);
            if res != NONE {
                nc := icb_cmp(pred, b, d);
                s := create_select(cond, res, nc);
                copy_metadata(s, op0);
                return s;
            }
            res = simplify_icmp_inst(pred, false, b, d, ic.sq);
            if res != NONE {
                nc := icb_cmp(pred, a, c);
                s := create_select(cond, nc, res);
                copy_metadata(s, op0);
                return s;
            }
        }
    }
    {
        for side: 0..1 {
            s := op(i, cast(u32) side); ad := op(i, cast(u32) (1 - side));
            if !ic_is_binop(s, .SUB) || !ic_is_binop(ad, .ADD) continue;
            a := op(s, 0); b := op(s, 1);
            if !((op(ad, 0) == a && op(ad, 1) == b) || (op(ad, 1) == a && op(ad, 0) == b)) continue;
            cmp_pred := inst_pred(i); if side == 1 cmp_pred = cmp_swapped(cmp_pred);
            i0nuw := has_nuw(op0); i1nuw := has_nuw(op1);
            i0nsw := has_nsw(op0); i1nsw := has_nsw(op1);
            if (icmp_is_unsigned(pred) && i0nuw && i1nuw) || (icmp_is_signed(pred) && i0nsw && i1nsw) ||
               (icmp_is_equality(pred) && ((i0nuw || i0nsw) && (i1nuw || i1nsw)))
                return create_icmp(cmp_swapped(cmp_pred), b, const_int_of(vtype(op0), 0));
            break;
        }
    }
    if is_ptr_type(vtype(op0)) && icmp_is_equality(inst_pred(i)) {
        a := get_underlying_object(op0);
        if is_inst(a) && inst_op(a) == .ALLOCA && ic_fold_alloca_cmp(a) return NONE;
        a = get_underlying_object(op1);
        if is_inst(a) && inst_op(a) == .ALLOCA && ic_fold_alloca_cmp(a) return NONE;
    }
    r = ic_fold_icmp_bitcast(i); if r != NONE return r;
    r = ic_fold_icmp_with_cast_op(i); if r != NONE return r;
    {
        if ic_is_binop(op0, .AND) && pm_zero(op1) && icmp_is_equality(inst_pred(i)) {
            x := op(op0, 0);
            okn, y := pm_not(op(op0, 1));
            if okn && ic_is_known_to_be_power_of_two(x, false, i)
                return create_icmp(cmp_inverse(inst_pred(i)), icb_and(x, y), op1);
        }
        if is_int_or_int_vector(vtype(op0)) {
            free0, cons0 := ic_is_free_to_invert(op0, has_one_use(op0));
            free1, cons1 := ic_is_free_to_invert(op1, has_one_use(op1));
            if free0 && free1 && (cons0 || cons1) {
                inv0 := ic_get_freely_inverted(op0, has_one_use(op0), true);
                inv1 := ic_get_freely_inverted(op1, has_one_use(op1), true);
                return create_icmp(cmp_swapped(inst_pred(i)), inv0, inv1);
            }
        }
        okov, x, y, add_i := ic_match_uadd_with_overflow(i);
        if okov && is_int_type(vtype(x)) {
            if inst_op(add_i) == .ADD {
                ok, result, overflow := ic_optimize_overflow_check(.ADD, false, x, y, add_i);
                if ok {
                    ic_replace_inst_uses_with(add_i, result);
                    ic_erase_inst(add_i);
                    return ic_replace_inst_uses_with(i, overflow);
                }
            }
        }
        if opr_code(op0) == .MUL && (opr_flags(op0) & F_NUW) != 0 {
            okx, zx := pmi_cast(op(op0, 0), .ZEXT);
            oky, zy := pmi_cast(op(op0, 1), .ZEXT);
            okc, c := pm_apint(op1);
            if okx && oky && okc {
                r = ic_process_umul_zext_idiom(i, op0, c); if r != NONE return r;
            }
        }
        if icmp_is_unsigned(pred) || icmp_is_equality(pred) {
            oke, yy := pmi_zext_or_sext(op1);
            if oke && scalar_bits(yy) == 1 && (has_one_use(op0) || has_one_use(op1)) {
                w := scalar_bits(op0);
                if is_inst(op0) && is_shr_op(inst_op(op0)) && pm_specific_int(op(op0, 1), cast(u64) (w - 1)) {
                    xv_ := op(op0, 0);
                    ext_opc := inst_op(op1); sh_opc := inst_op(op0);
                    if (ext_opc == .ZEXT && sh_opc == .LSHR) || (ext_opc == .SEXT && sh_opc == .ASHR) {
                        slt := icb_cmp(ICMP_SLT, xv_, const_null_value(vtype(xv_)));
                        nc := icb_cmp(pred, slt, yy, name_ref(vname(i)));
                        return ic_replace_inst_uses_with(i, nc);
                    }
                }
            }
        }
    }
    r = ic_fold_icmp_equality(i); if r != NONE return r;
    r = ic_fold_icmp_pow2_test(i); if r != NONE return r;
    r = ic_fold_icmp_of_uadd_ov(i); if r != NONE return r;
    r = ic_fold_icmp_of_vector_reduce(i); if r != NONE return r;
    if inst_pred(i) == ICMP_EQ && is_inst(op0) && inst_op(op0) == .EXTRACTVALUE {
        acxi := op(op0, 0);
        if is_inst(acxi) && inst_op(acxi) == .CMPXCHG {
            idx := inst_indices(op0);
            if idx[0] == 0 && op(acxi, 1) == op1 && (inst(acxi).flags & F_WEAK) == 0
                return create_extract_value(acxi, .[1]);
        }
    }
    r = ic_fold_icmp_with_high_bit_mask(i); if r != NONE return r;
    if is_vector_type(vtype(i)) { r = ic_fold_vector_cmp(i); if r != NONE return r; }
    r = ic_fold_icmp_invariant_group(i); if r != NONE return r;
    r = ic_fold_reduction_idiom(i); if r != NONE return r;
    {
        p := inst_pred(i);
        if icmp_is_equality(p) {
            if ic_is_binop(op0, .AND) {
                oks, a := pmi_cast(op(op0, 0), .SEXT);
                ok1, c1 := pm_apint(op(op0, 1));
                ok2, c2 := pm_apint(op1);
                if oks && ok1 && ok2 {
                    in_ty := vtype(a);
                    ibw := scalar_bits(a);
                    if ap_active_bits(c2) < ibw {
                        tc1 := ap_trunc(c1, ibw);
                        if ap_uge(c1, ap_one_bit_set(c1.bits, ibw)) ap_set_bit_val(*tc1, ibw - 1, true);
                        and_inst := icb_and(a, const_int_ap(in_ty, tc1));
                        return create_icmp(p, and_inst, const_int_ap(in_ty, ap_trunc(c2, ibw)));
                    }
                }
            }
        }
    }
    if changed return i;
    return NONE;
}

// m_UAddWithOverflow(m_Value(X), m_Value(Y), m_Instruction(AddI))
ic_match_uadd_with_overflow :: (cmp: Value_Id) -> (bool, Value_Id, Value_Id, Value_Id) {
    pred := inst_pred(cmp);
    l := op(cmp, 0); r := op(cmp, 1);
    if pred == ICMP_ULT && ic_is_binop(l, .ADD) && (r == op(l, 0) || r == op(l, 1)) return true, op(l, 0), op(l, 1), l;
    if pred == ICMP_UGT && ic_is_binop(r, .ADD) && (l == op(r, 0) || l == op(r, 1)) return true, op(r, 0), op(r, 1), r;
    if pred == ICMP_ULT {
        okn, x := pm_not(l);
        if okn && has_one_use(l) return true, x, r, l;
    }
    if pred == ICMP_UGT {
        okn, x := pm_not(r);
        if okn && has_one_use(r) return true, x, l, r;
    }
    if pred == ICMP_EQ {
        if ic_is_binop(l, .ADD) && pm_zero_int(r) && (pm_one(op(l, 0)) || pm_one(op(l, 1))) return true, op(l, 0), op(l, 1), l;
        if pm_zero_int(l) && ic_is_binop(r, .ADD) && (pm_one(op(r, 0)) || pm_one(op(r, 1))) return true, op(r, 0), op(r, 1), r;
    }
    return false, NONE, NONE, NONE;
}

// ---------------------------------------------------------------- helpers of other InstCombine files
// Used by the compare folds; they keep LLVM's names so the owner of the other file can move them there.

// insertRangeTest (InstCombineAndOrXor.cpp)
ic_insert_range_test :: (v: Value_Id, lo: APInt, hi: APInt, is_signed: bool, inside: bool) -> Value_Id {
    ty := vtype(v);
    pred := ifx inside then cast(u8) ICMP_ULT else ICMP_UGE;
    if ifx is_signed then ap_is_min_signed(lo) else ap_is_zero(lo) {
        p := ifx is_signed then icmp_signed_predicate(pred) else pred;
        return icb_cmp(p, v, const_int_ap(ty, hi));
    }
    v_minus_lo := icb_sub(v, const_int_ap(ty, lo), tprint("%.off", vname(v)));
    return icb_cmp(pred, v_minus_lo, const_int_ap(ty, ap_sub(hi, lo)));
}

// canTryToConstantAddTwoShiftAmounts (InstCombineShifts.cpp)
ic_can_try_to_constant_add_two_shift_amounts :: (sh0: Value_Id, sh_amt0: Value_Id, sh1: Value_Id, sh_amt1: Value_Id) -> bool {
    if vtype(sh_amt0) != vtype(sh_amt1) return false;
    max_total := cast(u64) (scalar_bits(sh0) - 1) + cast(u64) (scalar_bits(sh1) - 1);
    return ap_uge_u64(ap_all_ones(scalar_bits(sh_amt0)), max_total);
}

// reassociateShiftAmtsOfTwoSameDirectionShifts (InstCombineShifts.cpp)
ic_reassociate_shift_amts_of_two_same_direction_shifts :: (sh0: Value_Id, sq: Simplify_Query, analyze_for_sign_bit_extraction := false) -> Value_Id {
    if !(is_inst(sh0) && is_shift_op(inst_op(sh0))) return NONE;
    sh0_op0 := op(sh0, 0);
    if !is_inst(sh0_op0) return NONE;
    sh_amt0 := zext_or_self_i(op(sh0, 1));
    sh1: Value_Id = NONE; trunc: Value_Id = NONE;
    okt, t := pmi_cast(sh0_op0, .TRUNC);
    if okt && is_inst(t) { sh1 = t; trunc = sh0_op0; }
    else sh1 = sh0_op0;
    if !(is_inst(sh1) && is_shift_op(inst_op(sh1))) return NONE;
    x := op(sh1, 0);
    sh_amt1 := zext_or_self_i(op(sh1, 1));
    if !ic_can_try_to_constant_add_two_shift_amounts(sh0, sh_amt0, sh1, sh_amt1) return NONE;
    had_two_right := is_shr_op(inst_op(sh0)) && is_shr_op(inst_op(sh1));
    if analyze_for_sign_bit_extraction && !had_two_right return NONE;
    shift_opc := inst_op(sh0);
    identical := inst_op(sh0) == inst_op(sh1);
    if !identical && !analyze_for_sign_bit_extraction return NONE;
    if trunc != NONE && !analyze_for_sign_bit_extraction && !(has_one_use(op(sh0, 0)) || has_one_use(op(sh0, 1))) return NONE;
    new_sh_amt := simplify_add_inst(sh_amt0, sh_amt1, false, false, sq_with_instruction(sq, sh0));
    if new_sh_amt == NONE || !is_const(new_sh_amt) return NONE;
    nbw := scalar_bits(new_sh_amt);
    xbw := scalar_bits(x);
    ult :: (a: APInt, b: APInt) -> bool { return ap_ult(a, b); }
    eq :: (a: APInt, b: APInt) -> bool { return ap_eq(a, b); }
    if !pm_int_pred_arg(new_sh_amt, ult, ap_from_u64(nbw, cast(u64) xbw)) return NONE;
    if had_two_right && (trunc != NONE || analyze_for_sign_bit_extraction) {
        if !pm_int_pred_arg(new_sh_amt, eq, ap_from_u64(nbw, cast(u64) (xbw - 1))) return NONE;
        if analyze_for_sign_bit_extraction return x;
    }
    if vtype(new_sh_amt) != vtype(x) {
        new_sh_amt = cfo_cast_operand(.ZEXT, new_sh_amt, vtype(x));
        if new_sh_amt == NONE return NONE;
    }
    new_shift := create_binop(shift_opc, x, new_sh_amt);
    if trunc == NONE {
        if shift_opc == .SHL {
            set_nuw(new_shift, has_nuw(sh0) && has_nuw(sh1));
            set_nsw(new_shift, has_nsw(sh0) && has_nsw(sh1));
        } else set_exact(new_shift, is_exact(sh0) && is_exact(sh1));
    }
    ret := new_shift;
    if trunc != NONE {
        icb_insert(new_shift);
        ret = create_cast(.TRUNC, new_shift, vtype(sh0));
    }
    return ret;
}

// ShiftSemantics (InstCombineInternal.h)
Shift_Semantics :: enum u8 { LOSSY; SIGNED; UNSIGNED; }

// canEvaluateShiftedShift (InstCombineShifts.cpp)
ic_can_evaluate_shifted_shift :: (outer_sh_amt: u32, is_outer_shl: bool, sem: Shift_Semantics, inner: Value_Id, cxt: Value_Id) -> bool {
    ok, inner_c := pm_apint(op(inner, 1));
    if !ok return false;
    is_inner_shl := inst_op(inner) == .SHL;
    if !is_outer_shl && sem == .SIGNED return is_inner_shl && has_nsw(inner) && ap_eq_u64(inner_c, outer_sh_amt);
    if is_inner_shl == is_outer_shl return sem == .LOSSY;
    if ap_eq_u64(inner_c, outer_sh_amt) return true;
    tw := scalar_bits(inner);
    if ap_ugt_u64(inner_c, outer_sh_amt) && ap_ult_u64(inner_c, tw) {
        inner_sh_amt := cast(u32) ap_zext_value(inner_c);
        mask_shift := ifx is_inner_shl then tw - inner_sh_amt else inner_sh_amt - outer_sh_amt;
        mask := ap_shl(ap_low_bits_set(tw, outer_sh_amt), mask_shift);
        if ic_masked_value_is_zero(op(inner, 0), mask, cxt) return true;
    }
    return false;
}

// canEvaluateShifted (InstCombineShifts.cpp)
ic_can_evaluate_shifted :: (v: Value_Id, num_bits: u32, is_left_shift: bool, sem: Shift_Semantics, cxt: Value_Id) -> bool {
    if pm_imm_constant(v) {
        if sem == .LOSSY return true;
        ok, c := pm_apint_ap(v);
        if ok && !is_left_shift return ap_ctz(c) >= num_bits;
        return false;
    }
    if !is_inst(v) return false;
    if !has_one_use(v) return false;
    o := inst_op(v);
    if o == {
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            return ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
        case .SHL; #through;
        case .LSHR;
            return ic_can_evaluate_shifted_shift(num_bits, is_left_shift, sem, v, cxt);
        case .SELECT;
            return ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 2), num_bits, is_left_shift, sem, v);
        case .PHI;
            n := phi_num_incoming(v);
            if n > 0 for k: 0..n-1 if !ic_can_evaluate_shifted(phi_value(v, cast(u32) k), num_bits, is_left_shift, sem, v) return false;
            return true;
        case .MUL;
            ok, mc := pm_apint(op(v, 1));
            return !is_left_shift && sem == .UNSIGNED && ok && ap_is_negated_power_of_2(mc) && ap_ctz(mc) == num_bits;
        case .ADD;
            if is_left_shift {
                if sem == .LOSSY return ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
                return false;
            }
            if sem == .LOSSY return false;
            wrap := (sem == .SIGNED && has_nsw(v)) || (sem == .UNSIGNED && has_nuw(v));
            return wrap && ic_can_evaluate_shifted(op(v, 0), num_bits, is_left_shift, sem, v) && ic_can_evaluate_shifted(op(v, 1), num_bits, is_left_shift, sem, v);
    }
    return false;
}

// foldShiftedShift (InstCombineShifts.cpp)
ic_fold_shifted_shift :: (inner: Value_Id, outer_sh_amt: u32, is_outer_shl: bool, sem: Shift_Semantics) -> Value_Id {
    is_inner_shl := inst_op(inner) == .SHL;
    sht := vtype(inner);
    tw := scalar_bits(inner);
    _, c1 := pm_apint(op(inner, 1));
    inner_sh_amt := cast(u32) ap_zext_value(c1);
    new_inner_shift :: (inner: Value_Id, sh_amt: u32, is_inner_shl: bool) -> Value_Id {
        set_op(inner, 1, const_int_of(vtype(inner), cast(u64) sh_amt));
        if is_inner_shl { set_nuw(inner, false); set_nsw(inner, false); }
        else set_exact(inner, false);
        return inner;
    }
    if is_inner_shl == is_outer_shl {
        if inner_sh_amt + outer_sh_amt >= tw return const_null_value(sht);
        return new_inner_shift(inner, inner_sh_amt + outer_sh_amt, is_inner_shl);
    }
    if inner_sh_amt == outer_sh_amt {
        if !is_outer_shl && sem == .SIGNED return op(inner, 0);
        if !is_outer_shl && sem == .UNSIGNED && is_inner_shl && has_nuw(inner) return op(inner, 0);
        mask := ifx is_inner_shl then ap_low_bits_set(tw, tw - outer_sh_amt) else ap_high_bits_set(tw, tw - outer_sh_amt);
        a := icb_and(op(inner, 0), const_int_ap(sht, mask));
        if is_inst(a) {
            inst_move_before(a, inner);
            ic_take_name(a, inner);
        }
        return a;
    }
    return new_inner_shift(inner, inner_sh_amt - outer_sh_amt, is_inner_shl);
}

// getShiftedValue (InstCombineShifts.cpp)
ic_get_shifted_value :: (v: Value_Id, num_bits: u32, is_left_shift: bool, sem: Shift_Semantics) -> Value_Id {
    if is_const(v) {
        opc: Opcode = ifx is_left_shift then Opcode.SHL else (ifx sem == .SIGNED then Opcode.ASHR else .LSHR);
        return icb_binop(opc, v, const_int_of(vtype(v), cast(u64) num_bits));
    }
    wl_push(v);
    o := inst_op(v);
    if o == {
        case .AND; #through;
        case .OR; #through;
        case .XOR;
            set_op(v, 0, ic_get_shifted_value(op(v, 0), num_bits, is_left_shift, sem));
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            return v;
        case .SHL; #through;
        case .LSHR;
            return ic_fold_shifted_shift(v, num_bits, is_left_shift, sem);
        case .SELECT;
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            set_op(v, 2, ic_get_shifted_value(op(v, 2), num_bits, is_left_shift, sem));
            return v;
        case .PHI;
            n := phi_num_incoming(v);
            if n > 0 for k: 0..n-1 phi_set_value(v, k, ic_get_shifted_value(phi_value(v, cast(u32) k), num_bits, is_left_shift, sem));
            return v;
        case .MUL;
            neg := create_neg(op(v, 0));
            ic_insert_new_inst_with(neg, v);
            tw := scalar_bits(v);
            mask := ap_low_bits_set(tw, tw - num_bits);
            a := create_binop(.AND, neg, const_int_ap(vtype(v), mask));
            ic_take_name(a, v);
            return ic_insert_new_inst_with(a, v);
        case .ADD;
            if is_left_shift drop_poison_generating_flags(v);
            set_op(v, 0, ic_get_shifted_value(op(v, 0), num_bits, is_left_shift, sem));
            set_op(v, 1, ic_get_shifted_value(op(v, 1), num_bits, is_left_shift, sem));
            return v;
    }
    fatal("internal: Inconsistency with CanEvaluateShifted");
    return NONE;
}

// ---------------------------------------------------------------- small IR/builder helpers

type_addrspace :: (t: Type_Id) -> u32 { return cast(u32) ir.types[scalar_type(t)].a; }
// Builder.CreatePHI
icb_phi :: (ty: Type_Id, reserved: u32, name: string = "") -> Value_Id { return icb_insert(create_phi(ty, reserved), name); }
// ExtractValueInst::Create (unlinked)
create_extract_value :: (agg: Value_Id, idxs: [] u32, name: string = "") -> Value_Id {
    rt := vtype(agg);
    for idxs rt = type_sub(rt, ifx type_kind(rt) == .STRUCT then it else 0);
    i := new_inst(.EXTRACTVALUE, rt, 1);
    set_op(i, 0, agg);
    r := inst(i);
    r.idx = cast(u32) ir.u32_pool.count; r.nidx = cast(u32) idxs.count;
    for idxs array_add(*ir.u32_pool, it);
    return i;
}
// Builder.CreateExtractValue
icb_extract_value :: (agg: Value_Id, idxs: [] u32, name: string = "") -> Value_Id {
    if is_const(agg) { f := cf_extract_value(agg, idxs); if f != NONE return f; }
    return icb_insert(create_extract_value(agg, idxs), name);
}

// foldCmpSelectOfConstants
ic_fold_cmp_select_of_constants :: (i: Value_Id) -> Value_Id {
    op0 := op(i, 0); op1 := op(i, 1);
    ok1, c1, tv1, fv1 := pm_select(op0);
    ok2, c2, tv2, fv2 := pm_select(op1);
    if !ok1 || !ok2 || !is_const(tv1) || !is_const(fv1) || !is_const(tv2) || !is_const(fv2) return NONE;
    if vtype(i) != vtype(c1) || vtype(i) != vtype(c2) return NONE;
    pred := inst_pred(i);
    r00 := cfo_compare_inst_operands(pred, fv1, fv2);
    r01 := cfo_compare_inst_operands(pred, fv1, tv2);
    r10 := cfo_compare_inst_operands(pred, tv1, fv2);
    r11 := cfo_compare_inst_operands(pred, tv1, tv2);
    if r00 == NONE || r01 == NONE || r10 == NONE || r11 == NONE return NONE;
    for r: Value_Id.[r00, r01, r10, r11] if !is_null_value(r) && !cf_is_all_ones(r) return NONE;
    table: u32 = 0;
    if !is_null_value(r00) table |= 1;
    if !is_null_value(r01) table |= 2;
    if !is_null_value(r10) table |= 4;
    if !is_null_value(r11) table |= 8;
    res := ic_create_logic_from_table(table, c1, c2, has_one_use(op0) && has_one_use(op1));
    if res == NONE return NONE;
    return ic_replace_inst_uses_with(i, res);
}


// ================================================================ fcmp

// Type::getFPMantissaWidth (-1 for ppc_fp128)
ic_fp_mantissa_width :: (t: Type_Id) -> s64 {
    k := type_kind(scalar_type(t));
    if k == {
        case .HALF; return 11; case .BFLOAT; return 8; case .FLOAT; return 24; case .DOUBLE; return 53;
        case .X86_FP80; return 64; case .FP128; return 113;
    }
    return -1;
}
apf_make :: (k: Type_Kind, w: [] u64) -> APFloat { return apf_from_words(k, w); }
apf_cmp :: (a: APFloat, b: APFloat) -> Fp_Cmp { x := a; y := b; return fp_compare(a.k, apf_words(*x), apf_words(*y)); }
// ConstantFP::get(Ty, APFloat) (splat for vectors)
ic_const_fp :: (t: Type_Id, f: APFloat) -> Value_Id {
    g := f;
    c := const_fp_words(scalar_type(t), apf_words(*g));
    if is_vector_type(t) return cf_get_splat(t, c);
    return c;
}
// ConstantFP::getZero(Ty)
ic_fp_zero :: (t: Type_Id) -> Value_Id { return const_null_value(t); }

// isKnownNeverNaN / isKnownNeverInfinity
ic_is_known_never_nan :: (v: Value_Id, q: Simplify_Query) -> bool { return kfpc_is_known_never_nan(compute_known_fp_class(v, FC_NAN, q)); }
ic_is_known_never_infinity :: (v: Value_Id, q: Simplify_Query) -> bool { return kfpc_is_known_never_infinity(compute_known_fp_class(v, FC_INF, q)); }

// foldFCmpIntToFPConst: fcmp ([us]itofp x, cst)
ic_fold_fcmp_int_to_fp_const :: (i: Value_Id, lhsi: Value_Id, rhsc: Value_Id) -> Value_Id {
    okf, rhs := pm_apfloat(rhsc);
    if !okf return NONE;
    mw := ic_fp_mantissa_width(vtype(lhsi));
    if mw == -1 return NONE;
    int_ty := vtype(op(lhsi, 0));
    iw := scalar_bits(op(lhsi, 0));
    unsigned := inst_op(lhsi) == .UITOFP;
    rk := rhs.k;
    rw := rhs; rws := apf_words(*rw);
    if fcmp_is_equality(inst_pred(i)) {
        p := inst_pred(i);
        _, _, exact := fp_to_integer_rm(rk, rws, iw, !unsigned, RM_NEAREST_TIES_TO_EVEN);
        if !exact {
            rint, _ := fp_round_to_integral(rk, rws, RM_NEAREST_TIES_TO_EVEN);
            if fp_compare(rk, rws, rint) != .EQUAL {
                if p == FCMP_OEQ || p == FCMP_UEQ return ic_replace_inst_uses_with(i, get_false(vtype(i)));
                return ic_replace_inst_uses_with(i, get_true(vtype(i)));
            }
        }
    }
    if cast(s64) iw > mw {
        exp := fp_ilogb(rk, rws);
        um: s64 = ifx unsigned then 0 else 1;
        if exp == IEK_INF {
            max_exp := fp_ilogb(rk, fp_largest(rk, false));
            if max_exp < cast(s64) iw - um return NONE;
        } else {
            if mw <= exp && exp <= cast(s64) iw - um return NONE;
        }
    }
    pred: u8;
    p := inst_pred(i);
    if p == {
        case FCMP_UEQ; #through; case FCMP_OEQ; pred = ICMP_EQ;
        case FCMP_UGT; #through; case FCMP_OGT; pred = ifx unsigned then cast(u8) ICMP_UGT else ICMP_SGT;
        case FCMP_UGE; #through; case FCMP_OGE; pred = ifx unsigned then cast(u8) ICMP_UGE else ICMP_SGE;
        case FCMP_ULT; #through; case FCMP_OLT; pred = ifx unsigned then cast(u8) ICMP_ULT else ICMP_SLT;
        case FCMP_ULE; #through; case FCMP_OLE; pred = ifx unsigned then cast(u8) ICMP_ULE else ICMP_SLE;
        case FCMP_UNE; #through; case FCMP_ONE; pred = ICMP_NE;
        case FCMP_ORD; return ic_replace_inst_uses_with(i, get_true(vtype(i)));
        case FCMP_UNO; return ic_replace_inst_uses_with(i, get_false(vtype(i)));
        case; fatal("internal: Unexpected predicate!");
    }
    t := get_true(vtype(i)); f := get_false(vtype(i));
    if !unsigned {
        smax := fp_from_integer(rk, ap_words(ap_signed_max(iw)), iw, true);
        if fp_compare(rk, smax, rws) == .LESS {
            if pred == ICMP_NE || pred == ICMP_SLT || pred == ICMP_SLE return ic_replace_inst_uses_with(i, t);
            return ic_replace_inst_uses_with(i, f);
        }
    } else {
        umax := fp_from_integer(rk, ap_words(ap_all_ones(iw)), iw, false);
        if fp_compare(rk, umax, rws) == .LESS {
            if pred == ICMP_NE || pred == ICMP_ULT || pred == ICMP_ULE return ic_replace_inst_uses_with(i, t);
            return ic_replace_inst_uses_with(i, f);
        }
    }
    if !unsigned {
        smin := fp_from_integer(rk, ap_words(ap_signed_min(iw)), iw, true);
        if fp_compare(rk, smin, rws) == .GREATER {
            if pred == ICMP_NE || pred == ICMP_SGT || pred == ICMP_SGE return ic_replace_inst_uses_with(i, t);
            return ic_replace_inst_uses_with(i, f);
        }
    } else {
        umin := fp_from_integer(rk, ap_words(ap_zero(iw)), iw, false);
        if fp_compare(rk, umin, rws) == .GREATER {
            if pred == ICMP_NE || pred == ICMP_UGT || pred == ICMP_UGE return ic_replace_inst_uses_with(i, t);
            return ic_replace_inst_uses_with(i, f);
        }
    }
    iwords, _, exact := fp_to_integer_rm(rk, rws, iw, !unsigned, RM_TOWARD_ZERO);
    rhs_int := ap_from_words(iw, iwords);
    if !apf_is_zero(rhs) {
        if !exact {
            neg := apf_is_negative(rhs);
            if pred == {
                case ICMP_NE; return ic_replace_inst_uses_with(i, t);
                case ICMP_EQ; return ic_replace_inst_uses_with(i, f);
                case ICMP_ULE; if neg return ic_replace_inst_uses_with(i, f);
                case ICMP_SLE; if neg pred = ICMP_SLT;
                case ICMP_ULT; if neg return ic_replace_inst_uses_with(i, f); pred = ICMP_ULE;
                case ICMP_SLT; if !neg pred = ICMP_SLE;
                case ICMP_UGT; if neg return ic_replace_inst_uses_with(i, t);
                case ICMP_SGT; if neg pred = ICMP_SGE;
                case ICMP_UGE; if neg return ic_replace_inst_uses_with(i, t); pred = ICMP_UGT;
                case ICMP_SGE; if !neg pred = ICMP_SGT;
            }
        }
    }
    return create_icmp(pred, op(lhsi, 0), const_int_ap(int_ty, rhs_int));
}

// foldFCmpReciprocalAndZero: (C / X) < 0.0 --> X < 0.0
ic_fold_fcmp_reciprocal_and_zero :: (i: Value_Id, lhsi: Value_Id, rhsc: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    if pred != FCMP_OGT && pred != FCMP_OLT && pred != FCMP_OGE && pred != FCMP_OLE return NONE;
    if !pm_any_zero_fp(rhsc) return NONE;
    if (get_fmf(lhsi) & FMF_NINF) == 0 || (get_fmf(i) & FMF_NINF) == 0 return NONE;
    okc, c := pm_apfloat(op(lhsi, 0));
    if !okc return NONE;
    if apf_is_zero(c) return NONE;
    if apf_is_negative(c) pred = cmp_swapped(inst_pred(i));
    return create_fcmp(pred, op(lhsi, 1), rhsc, get_fmf(i));
}

// foldFCmpFpTrunc: fptrunc(x) cmp C --> x cmp ext(C)
ic_fold_fcmp_fp_trunc :: (i: Value_Id, fptrunc: Value_Id, c: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    dest_ty := vtype(op(fptrunc, 0));
    okc, cv := pm_apfloat(c);
    if !okc return NONE;
    if pred == FCMP_ORD || pred == FCMP_UNO return create_fcmp(pred, op(fptrunc, 0), ic_fp_zero(dest_ty), get_fmf(i));
    round_down: bool;
    if pred == FCMP_OGE || pred == FCMP_UGE || pred == FCMP_OLT || pred == FCMP_ULT round_down = true;
    else if pred == FCMP_OGT || pred == FCMP_UGT || pred == FCMP_OLE || pred == FCMP_ULE round_down = false;
    else return NONE;
    if apf_is_nan(cv) || apf_is_inf(cv) return NONE;
    sk := cv.k;
    dk := type_kind(scalar_type(dest_ty));
    conv :: (src: APFloat, k: Type_Kind) -> APFloat {
        s := src;
        w, _ := fp_convert(src.k, k, apf_words(*s));
        return apf_make(k, w);
    }
    next :: (v: APFloat, down: bool) -> APFloat {
        s := v;
        w, _ := fp_next(v.k, apf_words(*s), down);
        return apf_make(v.k, w);
    }
    add :: (a: APFloat, b: APFloat) -> APFloat {
        x := a; y := b;
        w, _ := fp_add_sub(a.k, apf_words(*x), apf_words(*y), false);
        return apf_make(a.k, w);
    }
    sub :: (a: APFloat, b: APFloat) -> APFloat {
        x := a; y := b;
        w, _ := fp_add_sub(a.k, apf_words(*x), apf_words(*y), true);
        return apf_make(a.k, w);
    }
    next_c := next(cv, round_down);
    ext_c := conv(cv, dk);
    ext_next_c := conv(next_c, dk);
    if apf_is_inf(next_c) {
        prev_c := next(cv, !round_down);
        bias := conv(sub(cv, prev_c), dk);
        ext_next_c = add(ext_c, bias);
    }
    sm := add(ext_c, ext_next_c);
    ext_mid := apf_make(dk, fp_scalbn(dk, apf_words(*sm), -1, RM_NEAREST_TIES_TO_EVEN));
    mid := conv(ext_mid, sk);
    if apf_cmp(mid, cv) != .EQUAL ext_mid = next(ext_mid, !round_down);
    if apf_is_inf(next_c) {
        if apf_is_inf(conv(ext_mid, sk)) return NONE;
        next_ext_mid := next(ext_mid, round_down);
        if apf_is_finite(conv(next_ext_mid, sk)) return NONE;
    }
    return create_fcmp(pred, op(fptrunc, 0), ic_const_fp(dest_ty, ext_mid), get_fmf(i));
}

// foldFabsWithFcmpZero
ic_fold_fabs_with_fcmp_zero :: (i: Value_Id) -> Value_Id {
    okf, x := pm_fabs(op(i, 0));
    if !okf return NONE;
    okc, c := pm_apfloat(op(i, 1));
    if !okc return NONE;
    if !apf_is_pos_zero(c) {
        if !apf_is_smallest_normalized(c) return NONE;
        _, inm := fn_denormal_mode(inst_fn(i), vtype(op(i, 1)));
        if inm == DENORMAL_PRESERVE_SIGN || inm == DENORMAL_POSITIVE_ZERO {
            replace :: (i: Value_Id, p: u8, x: Value_Id) -> Value_Id { return create_fcmp(p, x, ic_fp_zero(vtype(x)), get_fmf(i)); }
            if inst_pred(i) == {
                case FCMP_OLT; return replace(i, FCMP_OEQ, x);
                case FCMP_UGE; return replace(i, FCMP_UNE, x);
                case FCMP_OGE; return replace(i, FCMP_ONE, x);
                case FCMP_ULT; return replace(i, FCMP_UEQ, x);
            }
        }
        return NONE;
    }
    replace_pred_and_op0 :: (i: Value_Id, p: u8, x: Value_Id) -> Value_Id {
        inst(i).pred = p;
        return ic_replace_operand(i, 0, x);
    }
    p := inst_pred(i);
    if p == {
        case FCMP_UGE; #through;
        case FCMP_OLT; fatal("internal: fcmp should have simplified");
        case FCMP_OGT; return replace_pred_and_op0(i, FCMP_ONE, x);
        case FCMP_UGT; return replace_pred_and_op0(i, FCMP_UNE, x);
        case FCMP_OLE; return replace_pred_and_op0(i, FCMP_OEQ, x);
        case FCMP_ULE; return replace_pred_and_op0(i, FCMP_UEQ, x);
        case FCMP_OGE; return replace_pred_and_op0(i, FCMP_ORD, x);
        case FCMP_ULT; return replace_pred_and_op0(i, FCMP_UNO, x);
        case FCMP_OEQ; #through; case FCMP_UEQ; #through; case FCMP_ONE; #through;
        case FCMP_UNE; #through; case FCMP_ORD; #through; case FCMP_UNO;
            return replace_pred_and_op0(i, p, x);
    }
    return NONE;
}

// foldSqrtWithFcmpZero
ic_fold_sqrt_with_fcmp_zero :: (i: Value_Id) -> Value_Id {
    oks, x := pm_intrinsic1(op(i, 0), IID_SQRT);
    if !oks return NONE;
    if !pm_pos_zero_fp(op(i, 1)) return NONE;
    if (get_fmf(op(i, 0)) & FMF_NINF) == 0 set_fmf(i, get_fmf(i) & ~cast(u32) FMF_NINF);
    rp :: (i: Value_Id, p: u8, x: Value_Id) -> Value_Id { inst(i).pred = p; return ic_replace_operand(i, 0, x); }
    p := inst_pred(i);
    if p == {
        case FCMP_OLT; #through;
        case FCMP_UGE; fatal("internal: fcmp should have simplified");
        case FCMP_ULT; #through; case FCMP_ULE; #through; case FCMP_OGT; #through;
        case FCMP_OGE; #through; case FCMP_OEQ; #through; case FCMP_UNE;
            return ic_replace_operand(i, 0, x);
        case FCMP_OLE; return rp(i, FCMP_OEQ, x);
        case FCMP_UGT; return rp(i, FCMP_UNE, x);
        case FCMP_UEQ; return rp(i, FCMP_ULE, x);
        case FCMP_ONE; return rp(i, FCMP_OGT, x);
        case FCMP_ORD; return rp(i, FCMP_OGE, x);
        case FCMP_UNO; return rp(i, FCMP_ULT, x);
    }
    fatal("internal: Unexpected predicate!");
    return NONE;
}

// foldFCmpFNegCommonOp
ic_fold_fcmp_fneg_common_op :: (i: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    op0 := op(i, 0); op1 := op(i, 1);
    ok0, _ := pm_fneg(op0); ok1, _ := pm_fneg(op1);
    if ok0 && !ok1 { t := op0; op0 = op1; op1 = t; pred = cmp_swapped(inst_pred(i)); }
    okn, nx := pm_fneg(op1);
    if !okn || nx != op0 return NONE;
    return create_fcmp(pred, op0, ic_fp_zero(vtype(op0)), get_fmf(i));
}

// foldFCmpFSubIntoFCmp
ic_fold_fcmp_fsub_into_fcmp :: (i: Value_Id, lhsi: Value_Id, rhsc: Value_Id) -> Value_Id {
    pred := inst_pred(i);
    x := op(lhsi, 0); y := op(lhsi, 1);
    first_group := pred == FCMP_UGT || pred == FCMP_ULT || pred == FCMP_UNE || pred == FCMP_OEQ || pred == FCMP_OGE || pred == FCMP_OLE;
    second_group := pred == FCMP_OGT || pred == FCMP_OLT || pred == FCMP_ONE || pred == FCMP_UEQ || pred == FCMP_UGE || pred == FCMP_ULE;
    if !first_group && !second_group return NONE;
    lf := get_fmf(lhsi);
    if first_group {
        q := ic_q(i);
        if (lf & FMF_NNAN) == 0 && (lf & FMF_NINF) == 0 && !ic_is_known_never_infinity(y, q) && !ic_is_known_never_infinity(x, q) return NONE;
    }
    if pm_any_zero_fp(rhsc) {
        outm, inm := fn_denormal_mode(inst_fn(i), vtype(lhsi));
        if outm == DENORMAL_IEEE && inm == DENORMAL_IEEE {
            ic_replace_operand(i, 0, x);
            ic_replace_operand(i, 1, y);
            fm := get_fmf(i);
            fm = (fm & ~cast(u32) FMF_NINF) | (lf & FMF_NINF);
            if (lf & FMF_NNAN) != 0 fm |= FMF_NNAN;
            set_fmf(i, fm);
            return i;
        }
    }
    okc, c := pm_apfloat(rhsc);
    if okc && is_inst(lhsi) && inst_op(lhsi) == .FSUB && op(lhsi, 0) == rhsc && is_inst(y) && (inst_op(y) == .UITOFP || inst_op(y) == .SITOFP) &&
       apf_category(c) == .NORMAL && !apf_is_denormal(c) {
        mw := ic_fp_mantissa_width(vtype(lhsi));
        cc := c;
        if mw != -1 && fp_ilogb(c.k, apf_words(*cc)) < mw {
            inst(i).pred = cmp_swapped(inst_pred(i));
            ic_replace_operand(i, 0, y);
            ic_replace_operand(i, 1, ic_fp_zero(vtype(lhsi)));
            return i;
        }
    }
    return NONE;
}

// canBeCastedExactlyIntToFP (InstCombineCasts.cpp)
ic_can_be_casted_exactly_int_to_fp :: (v: Value_Id, fp_ty: Type_Id, is_signed: bool, cxt: Value_Id) -> bool {
    src_size := cast(s64) scalar_bits(v) - (ifx is_signed then 1 else 0);
    dest_sig := ic_fp_mantissa_width(fp_ty);
    if src_size <= dest_sig return true;
    if is_inst(v) && (inst_op(v) == .FPTOSI || inst_op(v) == .FPTOUI) {
        src_sig := ic_fp_mantissa_width(vtype(op(v, 0)));
        if !is_signed && inst_op(v) == .FPTOSI src_sig += 1;
        if src_sig > 0 && dest_sig > 0 && src_sig <= dest_sig return true;
    }
    k := ic_known_bits(v, cxt);
    sig := cast(s64) scalar_bits(v) - cast(s64) kb_count_min_leading_zeros(k) - cast(s64) kb_count_min_trailing_zeros(k);
    if sig <= dest_sig return true;
    if is_signed {
        sig = cast(s64) scalar_bits(v) - cast(s64) ic_num_sign_bits(v, cxt);
        if sig <= dest_sig return true;
    }
    return false;
}

// foldFCmpFAbsFSubIntToFP
ic_fold_fcmp_fabs_fsub_int_to_fp :: (i: Value_Id) -> Value_Id {
    okf, arg := pm_fabs(op(i, 0));
    if !okf return NONE;
    okc, c := pm_apfloat(op(i, 1));
    if !okc || !apf_is_finite_non_zero(c) return NONE;
    pred := inst_pred(i);
    strict_lt := pred == FCMP_OLT || pred == FCMP_ULT;
    le := pred == FCMP_OLE || pred == FCMP_ULE;
    strict_gt := pred == FCMP_OGT || pred == FCMP_UGT;
    ge := pred == FCMP_OGE || pred == FCMP_UGE;
    if !strict_lt && !strict_gt && !ge return NONE;
    one := apf_make(c.k, fp_from_integer(c.k, ap_words(ap_one(2)), 2, false));
    cmp := apf_cmp(c, one);
    if strict_lt && cmp == .GREATER return NONE;
    if ge && cmp == .GREATER return NONE;
    if le && cmp != .GREATER return NONE;
    if strict_gt && cmp != .LESS return NONE;
    if !(is_inst(arg) && inst_op(arg) == .FSUB) return NONE;
    a := op(arg, 0); b := op(arg, 1);
    is_signed: bool;
    if is_inst(a) && inst_op(a) == .UITOFP && is_inst(b) && inst_op(b) == .UITOFP is_signed = false;
    else if is_inst(a) && inst_op(a) == .SITOFP && is_inst(b) && inst_op(b) == .SITOFP is_signed = true;
    else return NONE;
    a = op(a, 0); b = op(b, 0);
    if vtype(a) != vtype(b) return NONE;
    fpt := vtype(arg);
    if !ic_can_be_casted_exactly_int_to_fp(a, fpt, is_signed, i) || !ic_can_be_casted_exactly_int_to_fp(b, fpt, is_signed, i) return NONE;
    return create_icmp(ifx strict_lt || le then cast(u8) ICMP_EQ else ICMP_NE, a, b);
}

// foldFCmpWithFloorAndCeil
ic_fold_fcmp_with_floor_and_ceil :: (i: Value_Id) -> Value_Id {
    lhs := op(i, 0); rhs := op(i, 1);
    op_type := vtype(lhs);
    pred := inst_pred(i);
    is_of :: (v: Value_Id, id: Intrinsic_Id, x: Value_Id) -> bool { ok, a := pm_intrinsic1(v, id); return ok && a == x; }
    floor_x := is_of(lhs, IID_FLOOR, rhs);
    ceil_x := is_of(lhs, IID_CEIL, rhs);
    if !floor_x && !ceil_x {
        floor_x = is_of(rhs, IID_FLOOR, lhs);
        if !floor_x ceil_x = is_of(rhs, IID_CEIL, lhs);
        if floor_x || ceil_x { t := lhs; lhs = rhs; rhs = t; pred = cmp_swapped(inst_pred(i)); }
    }
    if (floor_x || ceil_x) && fcmp_is_commutative(pred) && has_one_use(lhs) {
        tx := icb_unary_intrinsic(IID_TRUNC, rhs);
        return create_fcmp(pred, tx, rhs, get_fmf(i));
    }
    if pred == {
        case FCMP_OLE; if floor_x return create_fcmp(FCMP_ORD, rhs, ic_fp_zero(op_type), get_fmf(i));
        case FCMP_OGT; if floor_x return ic_replace_inst_uses_with(i, get_false(vtype(i)));
        case FCMP_OGE; if ceil_x return create_fcmp(FCMP_ORD, rhs, ic_fp_zero(op_type), get_fmf(i));
        case FCMP_OLT; if ceil_x return ic_replace_inst_uses_with(i, get_false(vtype(i)));
        case FCMP_ULE; if floor_x return ic_replace_inst_uses_with(i, get_true(vtype(i)));
        case FCMP_UGT; if floor_x return create_fcmp(FCMP_UNO, rhs, ic_fp_zero(op_type), get_fmf(i));
        case FCMP_UGE; if ceil_x return ic_replace_inst_uses_with(i, get_true(vtype(i)));
        case FCMP_ULT; if ceil_x return create_fcmp(FCMP_UNO, rhs, ic_fp_zero(op_type), get_fmf(i));
    }
    return NONE;
}

// isMinMaxCmpSelectEliminable
ic_is_min_max_cmp_select_eliminable :: (flavor: Select_Flavor, a: Value_Id, b: Value_Id) -> bool {
    okf, apf := pm_apfloat(b);
    if !okf return false;
    if !(is_inst(a) && (inst_op(a) == .SITOFP || inst_op(a) == .UITOFP)) return false;
    unsigned := inst_op(a) == .UITOFP;
    bw := scalar_bits(op(a, 0));
    boundary: APInt;
    if flavor == .FMAXNUM boundary = ifx unsigned then ap_zero(bw) else ap_signed_min(bw);
    else boundary = ifx unsigned then ap_all_ones(bw) else ap_signed_max(bw);
    f := apf;
    w, st, exact := fp_to_integer_rm(apf.k, apf_words(*f), bw, !unsigned, RM_TOWARD_ZERO);
    return st == 0 && exact && ap_eq(ap_from_words(bw, w), boundary);
}

// ---------------------------------------------------------------- visitFCmpInst

ic_visit_fcmp :: (i: Value_Id) -> Value_Id {
    changed := false;
    if ic_complexity(op(i, 0)) < ic_complexity(op(i, 1)) { cmp_swap_operands(i); changed = true; }
    pred := inst_pred(i);
    op0 := op(i, 0); op1 := op(i, 1);
    v := simplify_fcmp_inst(pred, op0, op1, get_fmf(i), ic_q(i));
    if v != NONE return ic_replace_inst_uses_with(i, v);
    op_type := vtype(op0);
    if op0 == op1 {
        if pred == FCMP_UNO || pred == FCMP_ULT || pred == FCMP_UGT || pred == FCMP_UNE {
            inst(i).pred = FCMP_UNO;
            set_op(i, 1, const_null_value(op_type));
            return i;
        }
        if pred == FCMP_ORD || pred == FCMP_OEQ || pred == FCMP_OGE || pred == FCMP_OLE {
            inst(i).pred = FCMP_ORD;
            set_op(i, 1, const_null_value(op_type));
            return i;
        }
    }
    if fcmp_is_commutative(pred) {
        ok, a, b := ic_match_symmetric_pair(op(i, 0), op(i, 1));
        if ok {
            ic_replace_operand(i, 0, a);
            ic_replace_operand(i, 1, b);
            return i;
        }
    }
    if pred == FCMP_ORD || pred == FCMP_UNO {
        if !pm_pos_zero_fp(op0) && ic_is_known_never_nan(op0, ic_q(i)) return ic_replace_operand(i, 0, ic_fp_zero(op_type));
        if !pm_pos_zero_fp(op1) && ic_is_known_never_nan(op1, ic_q(i)) return ic_replace_operand(i, 1, ic_fp_zero(op_type));
    }
    {
        okx, x := pm_fneg(op0);
        oky, y := pm_fneg(op1);
        if okx && oky return create_fcmp(cmp_swapped(pred), x, y, get_fmf(i));
    }
    r := ic_fold_fcmp_fneg_common_op(i); if r != NONE return r;
    if has_one_use(i) {
        si := first_user(i);
        if is_inst(si) && inst_op(si) == .SELECT {
            spr, a, b := match_select_pattern(si);
            redundant := (spr.flavor == .FMAXNUM || spr.flavor == .FMINNUM) && ic_is_min_max_cmp_select_eliminable(spr.flavor, a, b);
            if spr.flavor != .UNKNOWN && !redundant return NONE;
        }
    }
    if pm_any_zero_fp(op1) && !pm_pos_zero_fp(op1) return ic_replace_operand(i, 1, ic_fp_zero(op_type));
    {
        okc, c := pm_apfloat(op1);
        if okc && apf_is_inf(c) {
            p := ifx apf_is_negative(c) then cmp_swapped(pred) else pred;
            if p == {
                case FCMP_ORD; #through; case FCMP_UNO; #through; case FCMP_TRUE; #through;
                case FCMP_FALSE; #through; case FCMP_OGT; #through; case FCMP_ULE;
                    fatal("internal: Should be simplified by InstSimplify");
                case FCMP_OLT; return create_fcmp(FCMP_ONE, op0, op1, get_fmf(i));
                case FCMP_OLE; return create_fcmp(FCMP_ORD, op0, ic_fp_zero(op_type), get_fmf(i));
                case FCMP_OGE; return create_fcmp(FCMP_OEQ, op0, op1, get_fmf(i));
                case FCMP_ULT; return create_fcmp(FCMP_UNE, op0, op1, get_fmf(i));
                case FCMP_UGT; return create_fcmp(FCMP_UNO, op0, ic_fp_zero(op_type), get_fmf(i));
                case FCMP_UGE; return create_fcmp(FCMP_UEQ, op0, op1, get_fmf(i));
            }
        }
    }
    if pm_pos_zero_fp(op1) && has_one_use(op0) {
        okb, x := pm_elementwise_bitcast(op0);
        _, inm := fn_denormal_mode(inst_fn(i), vtype(op1));
        if okb && is_int_or_int_vector(vtype(x)) && inm == DENORMAL_IEEE {
            int_pred: u8 = BAD_ICMP_PREDICATE;
            if pred == FCMP_OEQ int_pred = ICMP_EQ;
            else if pred == FCMP_UNE int_pred = ICMP_NE;
            if int_pred != BAD_ICMP_PREDICATE {
                it := vtype(x);
                sign_mask := ap_not(ap_signed_min(scalar_bits(x)));
                mask_x := icb_and(x, const_int_ap(it, sign_mask));
                return create_icmp(int_pred, mask_x, const_null_value(it));
            }
        }
    }
    if is_inst(op0) && is_const(op1) {
        lhsi := op0; rhsc := op1;
        o := inst_op(lhsi);
        if o == {
            case .SELECT;
                if fcmp_is_equality(pred) && pm_any_zero_fp(rhsc) {
                    for side: 0..1 {
                        okn, x := pm_fneg(op(lhsi, cast(u32) (1 + side)));
                        if okn && op(lhsi, cast(u32) (2 - side)) == x return ic_replace_operand(i, 0, x);
                    }
                }
                r = ic_fold_op_into_select(i, lhsi); if r != NONE return r;
            case .FSUB;
                if has_one_use(lhsi) { r = ic_fold_fcmp_fsub_into_fcmp(i, lhsi, rhsc); if r != NONE return r; }
            case .PHI;
                r = ic_fold_op_into_phi(i, lhsi); if r != NONE return r;
            case .SITOFP; #through;
            case .UITOFP;
                r = ic_fold_fcmp_int_to_fp_const(i, lhsi, rhsc); if r != NONE return r;
            case .FDIV;
                r = ic_fold_fcmp_reciprocal_and_zero(i, lhsi, rhsc); if r != NONE return r;
            case .LOAD;
                g := op(lhsi, 0);
                if is_inst(g) && inst_op(g) == .GEP { r = ic_fold_cmp_load_from_indexed_global(lhsi, g, i, NONE); if r != NONE return r; }
            case .FPTRUNC;
                r = ic_fold_fcmp_fp_trunc(i, lhsi, rhsc); if r != NONE return r;
        }
    }
    r = ic_fold_fabs_with_fcmp_zero(i); if r != NONE return r;
    r = ic_fold_fcmp_fabs_fsub_int_to_fp(i); if r != NONE return r;
    r = ic_fold_sqrt_with_fcmp_zero(i); if r != NONE return r;
    r = ic_fold_fcmp_with_floor_and_ceil(i); if r != NONE return r;
    r = ic_fold_cmp_select_of_constants(i); if r != NONE return r;
    {
        okx, x := pm_fneg(op0);
        if okx && is_const(op1) {
            neg_c := cfo_unary_op_operand(.FNEG, op1);
            if neg_c != NONE return create_fcmp(cmp_swapped(pred), x, neg_c, get_fmf(i));
        }
    }
    if ic_is_binop(op0, .FADD) && pm_any_zero_fp(op(op0, 1)) return create_fcmp(pred, op(op0, 0), op1, get_fmf(i));
    if ic_is_binop(op1, .FADD) && pm_any_zero_fp(op(op1, 1)) return create_fcmp(pred, op0, op(op1, 0), get_fmf(i));
    if pred == FCMP_ORD || pred == FCMP_UNO {
        okx, x := pmi_cast(op0, .FPTRUNC);
        oky, y := pmi_cast(op1, .FPTRUNC);
        if okx && oky && vtype(x) == vtype(y) return create_fcmp(pred, x, y, get_fmf(i));
    }
    okx, x := pmi_cast(op0, .FPEXT);
    if okx {
        oky, y := pmi_cast(op1, .FPEXT);
        if oky && vtype(x) == vtype(y) return create_fcmp(pred, x, y, get_fmf(i));
        okc, c := pm_apfloat(op1);
        if okc {
            xk := type_kind(scalar_type(vtype(x)));
            cc := c;
            tw, exact := fp_convert(c.k, xk, apf_words(*cc));
            lossy := !exact;
            trunc_c := apf_make(xk, tw);
            if lossy {
                if pred == {
                    case FCMP_OEQ; return ic_replace_inst_uses_with(i, get_false(vtype(i)));
                    case FCMP_ONE; return create_fcmp(FCMP_ORD, x, ic_fp_zero(vtype(x)));
                    case FCMP_UEQ; return create_fcmp(FCMP_UNO, x, ic_fp_zero(vtype(x)));
                    case FCMP_UNE; return ic_replace_inst_uses_with(i, get_true(vtype(i)));
                }
            }
            fabs := trunc_c;
            fabs = apf_make(xk, fp_with_sign(xk, apf_words(*fabs), false));
            if !lossy && (apf_is_zero(fabs) || !apf_lt(fabs, apf_smallest_normalized(xk))) {
                return create_fcmp(pred, x, ic_const_fp(vtype(x), trunc_c), get_fmf(i));
            }
        }
    }
    {
        okcs, cv, x := pm_intrinsic2(op0, IID_COPYSIGN);
        okc, c := pm_apfloat(cv);
        if okcs && okc && has_one_use(op0) && pm_any_zero_fp(op1) && !apf_is_zero(c) && !apf_is_nan(c) {
            int_ty := type_int(scalar_bits(x));
            if is_vector_type(op_type) int_ty = vector_with_elt(op_type, int_ty);
            if pred == FCMP_OLT {
                ix := icb_cast(.BITCAST, x, int_ty);
                return create_icmp(ICMP_SLT, ix, const_null_value(int_ty));
            }
        }
    }
    {
        okl, canon_lhs := pm_intrinsic1(op0, IID_CANONICALIZE);
        if !okl canon_lhs = NONE;
        if canon_lhs != NONE && canon_lhs == op1 return create_fcmp(pred, op1, op1, get_fmf(i));
        okr, canon_rhs := pm_intrinsic1(op1, IID_CANONICALIZE);
        if !okr canon_rhs = NONE;
        if canon_rhs != NONE && canon_rhs == op0 return create_fcmp(pred, op0, op0, get_fmf(i));
        if canon_lhs != NONE && canon_rhs != NONE return create_fcmp(pred, canon_lhs, canon_rhs, get_fmf(i));
    }
    if is_vector_type(vtype(i)) { r = ic_fold_vector_cmp(i); if r != NONE return r; }
    if changed return i;
    return NONE;
}
// APFloat::getSmallestNormalized(Sem)
apf_smallest_normalized :: (k: Type_Kind) -> APFloat {
    p, emax, emin, bits := fp_semantics(k);
    // smallest normal = 2^emin
    one := fp_from_integer(k, ap_words(ap_one(2)), 2, false);
    return apf_make(k, fp_scalbn(k, one, emin, RM_NEAREST_TIES_TO_EVEN));
}
