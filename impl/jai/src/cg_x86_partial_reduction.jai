// X86PartialReduction (x86-partial-reduction): port of llvm/lib/Target/X86/X86PartialReduction.cpp.
// Looks for add reductions whose leaves are multiplies (rewritten into pmaddwd-shaped even/odd shuffles) or
// absolute differences of zero-extended bytes (rewritten into psadbw intrinsic calls).

xpr_st: *X86_Lowering;

// matchVPDPBUSDPattern
xpr_match_vpdpbusd_pattern :: (mul: Value_Id) -> bool {
    if !st_hasVNNI(xpr_st) && !xs_has(xpr_st, X86FLD_HasAVXVNNI) return false;
    lhs := op(mul, 0); rhs := op(mul, 1);
    if is_inst(lhs) && inst_op(lhs) == .SEXT { t := lhs; lhs = rhs; rhs = t; }
    is_free_truncation :: (v: Value_Id, mul: Value_Id) -> bool {
        if is_inst(v) && is_cast_op(inst_op(v)) {
            o := inst_op(v);
            if inst_block(v) == inst_block(mul) && (o == .SEXT || o == .ZEXT) && type_bits(scalar_type(vtype(op(v, 0)))) <= 8 return true;
        }
        return is_const(v);
    }
    q: Simplify_Query;
    if is_free_truncation(lhs, mul) && kb_count_max_active_bits(known_bits(lhs, q)) <= 8 &&
       is_free_truncation(rhs, mul) && max_significant_bits(rhs, q) <= 8 return true;
    return false;
}

// tryMAddReplacement
xpr_try_madd_replacement :: (opv: Value_Id, reduce_in_one_bb: bool) -> bool {
    if !st_hasSSE2(xpr_st) return false;
    ty := vtype(opv);
    if type_kind(ty) != .VECTOR return false;
    if cast(s64) vec_count(ty) < 8 return false;
    et := type_elem(ty);
    if !(type_kind(et) == .INT && type_bits(et) == 32) return false;
    if !is_binary_operator(opv) || inst_op(opv) != .MUL return false;
    mul := opv;
    lhs := op(mul, 0); rhs := op(mul, 1);
    if reduce_in_one_bb && xpr_match_vpdpbusd_pattern(mul) return false;
    if st_hasSSE41(xpr_st) {
        if lhs == rhs {
            if !is_const(lhs) && !has_n_uses(lhs, 2) return false;
        } else {
            if !is_const(lhs) && !has_one_use(lhs) return false;
            if !is_const(rhs) && !has_one_use(rhs) return false;
        }
    }
    can_shrink_op :: (v: Value_Id, mul: Value_Id) -> bool {
        is_free_truncation :: (v: Value_Id, mul: Value_Id) -> bool {
            if is_inst(v) && is_cast_op(inst_op(v)) {
                o := inst_op(v);
                if inst_block(v) == inst_block(mul) && (o == .SEXT || o == .ZEXT) && type_bits(scalar_type(vtype(op(v, 0)))) <= 16 return true;
            }
            return is_const(v);
        }
        if is_free_truncation(v, mul) && num_sign_bits_ctx(v, mul, null, null) > 16 return true;
        if is_binary_operator(v) {
            if inst_block(v) == inst_block(mul) && is_free_truncation(op(v, 0), mul) && is_free_truncation(op(v, 1), mul) &&
               num_sign_bits_ctx(v, mul, null, null) > 16 return true;
        }
        return false;
    }
    if !can_shrink_op(lhs, mul) && !can_shrink_op(rhs, mul) return false;
    b: Irb; irb_set_before(*b, mul);
    num_elts := cast(s64) vec_count(ty);
    even_mask: [..] u32; even_mask.allocator = temp;
    odd_mask: [..] u32; odd_mask.allocator = temp;
    for i: 0..num_elts/2-1 { array_add(*even_mask, cast(u32) (i * 2)); array_add(*odd_mask, cast(u32) (i * 2 + 1)); }
    new_mul := irb_binop(*b, .MUL, op(mul, 0), op(mul, 1));
    even_elts := irb_shuffle(*b, new_mul, new_mul, even_mask);
    odd_elts := irb_shuffle(*b, new_mul, new_mul, odd_mask);
    madd := irb_binop(*b, .ADD, even_elts, odd_elts);
    concat_mask: [..] u32; concat_mask.allocator = temp;
    for i: 0..num_elts-1 array_add(*concat_mask, cast(u32) i);
    zero := const_null_value(vtype(madd));
    concat := irb_shuffle(*b, madd, zero, concat_mask);
    rauw_with_metadata(mul, concat);
    erase_inst_with_metadata(mul);
    return true;
}

// trySADReplacement
xpr_try_sad_replacement :: (opv: Value_Id) -> bool {
    if !st_hasSSE2(xpr_st) return false;
    ty := vtype(opv);
    if type_kind(ty) != .VECTOR return false;
    et := type_elem(ty);
    if !(type_kind(et) == .INT && type_bits(et) == 32) return false;
    lhs: Value_Id;
    if is_inst(opv) && inst_op(opv) == .CALL && call_iid(opv) == IID_ABS {
        lhs = op(opv, 0);
    } else {
        if !is_inst(opv) || inst_op(opv) != .SELECT return false;
        spr, l, r := match_select_pattern(opv);
        if spr.flavor != .ABS return false;
        lhs = l;
    }
    if !is_binary_operator(lhs) || inst_op(lhs) != .SUB return false;
    sub := lhs;
    get_zero_extended_val :: (v: Value_Id) -> Value_Id {
        if is_inst(v) && inst_op(v) == .ZEXT {
            st := vtype(op(v, 0));
            if type_kind(st) == .VECTOR && type_kind(type_elem(st)) == .INT && type_bits(type_elem(st)) == 8 return op(v, 0);
        }
        return NONE;
    }
    op0 := get_zero_extended_val(op(sub, 0));
    op1 := get_zero_extended_val(op(sub, 1));
    if op0 == NONE || op1 == NONE return false;
    b: Irb; irb_set_before(*b, opv);
    num_elts := cast(s64) vec_count(ty);
    intrinsic_num_elts: s64;
    iid_name: string;
    if st_useBWIRegs(xpr_st) && num_elts >= 64 { iid_name = "llvm.x86.avx512.psad.bw.512"; intrinsic_num_elts = 64; }
    else if st_hasAVX2(xpr_st) && num_elts >= 32 { iid_name = "llvm.x86.avx2.psad.bw"; intrinsic_num_elts = 32; }
    else { iid_name = "llvm.x86.sse2.psad.bw"; intrinsic_num_elts = 16; }
    psadbw_fn := get_or_insert_intrinsic_declaration(intrinsic_id_by_name(iid_name));
    if num_elts < 16 {
        concat_mask: [..] u32; concat_mask.allocator = temp;
        for i: 0..num_elts-1 array_add(*concat_mask, cast(u32) i);
        for i: num_elts..15 array_add(*concat_mask, cast(u32) ((i % num_elts) + num_elts));
        zero := const_null_value(vtype(op0));
        op0 = irb_shuffle(*b, op0, zero, concat_mask);
        op1 = irb_shuffle(*b, op1, zero, concat_mask);
        num_elts = 16;
    }
    i32_ty := type_vector(cast(u64) (intrinsic_num_elts / 4), ir.t_i32, false);
    num_splits := num_elts / intrinsic_num_elts;
    ops: [..] Value_Id; ops.allocator = temp;
    for i: 0..num_splits-1 {
        extract_mask: [..] u32; extract_mask.allocator = temp;
        for k: 0..intrinsic_num_elts-1 array_add(*extract_mask, cast(u32) (i * intrinsic_num_elts + k));
        e0 := irb_shuffle(*b, op0, op0, extract_mask);
        e1 := irb_shuffle(*b, op1, op0, extract_mask);
        c := irb_call(*b, psadbw_fn, .[e0, e1]);
        array_add(*ops, irb_bitcast(*b, c, i32_ty));
    }
    stages: s64 = 0;
    { x := num_splits; while x > 1 { x >>= 1; stages += 1; } }
    s := stages;
    while s > 0 {
        num_concat_elts := cast(s64) vec_count(vtype(ops[0])) * 2;
        for i: 0..(1 << (s - 1)) - 1 {
            concat_mask: [..] u32; concat_mask.allocator = temp;
            for k: 0..num_concat_elts-1 array_add(*concat_mask, cast(u32) k);
            ops[i] = irb_shuffle(*b, ops[i * 2], ops[i * 2 + 1], concat_mask);
        }
        s -= 1;
    }
    num_elts = cast(s64) vec_count(ty);
    if num_elts == 2 {
        ops[0] = irb_shuffle(*b, ops[0], ops[0], .[0, 1]);
    } else if num_elts >= 8 {
        concat_mask: [..] u32; concat_mask.allocator = temp;
        sub_elts := cast(s64) vec_count(vtype(ops[0]));
        for i: 0..sub_elts-1 array_add(*concat_mask, cast(u32) i);
        for i: sub_elts..num_elts-1 array_add(*concat_mask, cast(u32) ((i % sub_elts) + sub_elts));
        zero := const_null_value(vtype(ops[0]));
        ops[0] = irb_shuffle(*b, ops[0], zero, concat_mask);
    }
    rauw_with_metadata(opv, ops[0]);
    erase_inst_with_metadata(opv);
    return true;
}

// matchAddReduction: (root or NONE, ReduceInOneBB)
xpr_match_add_reduction :: (ee: Value_Id) -> (Value_Id, bool) {
    reduce_in_one_bb := true;
    idx := op(ee, 1);
    if vkind(idx) != .C_INT || !ap_is_zero(const_ap(idx)) return NONE, reduce_in_one_bb;
    bo := op(ee, 0);
    if !is_binary_operator(bo) || inst_op(bo) != .ADD || !has_one_use(bo) return NONE, reduce_in_one_bb;
    if inst_block(ee) != inst_block(bo) reduce_in_one_bb = false;
    num_elems := cast(s64) vec_count(vtype(bo));
    if num_elems == 0 || (num_elems & (num_elems - 1)) != 0 return NONE, reduce_in_one_bb;
    v := bo;
    stages: s64 = 0;
    { x := num_elems; while x > 1 { x >>= 1; stages += 1; } }
    for i: 0..stages - 1 {
        if !is_binary_operator(v) || inst_op(v) != .ADD return NONE, reduce_in_one_bb;
        if inst_block(ee) != inst_block(v) reduce_in_one_bb = false;
        if i != 0 && !has_n_uses(v, 2) return NONE, reduce_in_one_bb;
        l := op(v, 0); r := op(v, 1);
        shuffle: Value_Id = NONE;
        if is_inst(l) && inst_op(l) == .SHUFFLEVECTOR { shuffle = l; v = r; }
        else { if is_inst(r) && inst_op(r) == .SHUFFLEVECTOR shuffle = r; v = l; }
        if shuffle == NONE || op(shuffle, 0) != v return NONE, reduce_in_one_bb;
        mask_end := 1 << i;
        mask := shuf_mask(shuffle);
        for index: 0..mask_end-1 if cast(s64) mask[index] != mask_end + index return NONE, reduce_in_one_bb;
    }
    return v, reduce_in_one_bb;
}

// isReachableFromPHI
xpr_is_reachable_from_phi :: (phi: Value_Id, bo: Value_Id) -> bool {
    if !has_one_use(phi) return false;
    u := ir.u_user[ir.v_first_use[phi]];
    if u == bo return true;
    while has_one_use(u) && inst_op(u) == inst_op(bo) u = ir.u_user[ir.v_first_use[u]];
    return u == bo;
}

// collectLeaves
xpr_collect_leaves :: (root: Value_Id, leaves: *[..] Value_Id) {
    visited: Table(Value_Id, bool); visited.allocator = temp;
    worklist: [..] Value_Id; worklist.allocator = temp;
    array_add(*worklist, root);
    while worklist.count {
        v := pop(*worklist);
        if table_contains(*visited, v) continue;
        table_set(*visited, v, true);
        if is_phi(v) {
            if !has_n_uses(v, ifx v == root then 2 else 1) break;
            for k: 0..phi_num_incoming(v)-1 array_add(*worklist, phi_value(v, k));
            continue;
        }
        if is_binary_operator(v) && inst_op(v) == .ADD {
            if has_n_uses(v, ifx v == root then 2 else 1) {
                array_add(*worklist, op(v, 0)); array_add(*worklist, op(v, 1));
                continue;
            }
            if has_n_uses(v, ifx v == root then 3 else 2) {
                pn: Value_Id = NONE;
                for u: sx_users(v) if is_phi(u) && !table_contains(*visited, u) pn = u;
                if pn == NONE || phi_num_incoming(pn) != 2 continue;
                if !xpr_is_reachable_from_phi(pn, v) continue;
                array_add(*worklist, op(v, 0)); array_add(*worklist, op(v, 1));
            }
        }
        if is_inst(v) {
            if !has_n_uses(v, ifx v == root then 2 else 1) continue;
            array_add(leaves, v);
        }
    }
}

// X86PartialReductionLegacy::runOnFunction / X86PartialReduction::run
x86_partial_reduction_run :: (f: Value_Id) -> Preserved {
    if cg_skip_function(f) return PRESERVE_ALL;
    xpr_st = *tti_get(f).xl;
    made_change := false;
    for bb: fn_blocks(f) {
        i := block_first(bb);
        while i != NONE {
            if inst_op(i) == .EXTRACTELEMENT {
                root, reduce_in_one_bb := xpr_match_add_reduction(i);
                if root != NONE {
                    leaves: [..] Value_Id; leaves.allocator = temp;
                    xpr_collect_leaves(root, *leaves);
                    for l: leaves {
                        if xpr_try_madd_replacement(l, reduce_in_one_bb) { made_change = true; continue; }
                        if l != root && xpr_try_sad_replacement(l) made_change = true;
                    }
                }
            }
            i = inst_next(i);
        }
    }
    if !made_change return PRESERVE_ALL;
    return preserved_cfg();
}
