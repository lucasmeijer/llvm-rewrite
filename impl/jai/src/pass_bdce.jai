// BDCE: port of llvm/lib/Transforms/Scalar/BDCE.cpp (bitTrackingDCE, clearAssumptionsOfUsers).

bdce_clear_assumptions_of_users :: (i: Value_Id, db: *Demanded_Bits) {
    if ap_is_all_ones(db_demanded_bits(db, i)) return;
    visited: Table(Value_Id, bool); visited.allocator = temp;
    wl: [..] Value_Id; wl.allocator = temp;
    u := ir.v_first_use[i];
    while u != NONE {
        j := ir.u_user[u];
        if is_int_or_int_vector(vtype(j)) {
            table_set(*visited, j, true);
            array_add(*wl, j);
        }
        u = ir.u_next[u];
    }
    while wl.count {
        j := pop(*wl);
        drop_poison_generating_annotations(j);
        if ap_is_all_ones(db_demanded_bits(db, j)) continue;
        u = ir.v_first_use[j];
        while u != NONE {
            k := ir.u_user[u];
            if !table_contains(*visited, k) {
                table_set(*visited, k, true);
                if is_int_or_int_vector(vtype(k)) array_add(*wl, k);
            }
            u = ir.u_next[u];
        }
    }
}

bdce_run :: (f: Value_Id) -> Preserved {
    db := get_demanded_bits(f);
    wl: [..] Value_Id; wl.allocator = temp;
    changed := false;
    for i: fn_insts(f) {
        if may_have_side_effects(i) && !has_uses(i) continue;
        t := vtype(i);
        if db_is_instruction_dead(db, i) ||
           (is_int_or_int_vector(t) && ap_is_zero(db_demanded_bits(db, i)) && would_instruction_be_trivially_dead(i, use_tli = false)) {
            array_add(*wl, i);
            changed = true;
            continue;
        }
        if inst_op(i) == .SEXT {
            demanded := db_demanded_bits(db, i);
            src_bits := type_bits(scalar_type(vtype(op(i, 0))));
            dst_ty := t;
            dst_bits := type_bits(scalar_type(dst_ty));
            if i != op(i, 0) && ap_clz(demanded) >= dst_bits - src_bits {
                bdce_clear_assumptions_of_users(i, db);
                // IRBuilder<> Builder(SE); Builder.CreateZExt(Op, DstTy, SE->getName())
                src := op(i, 0);
                z: Value_Id;
                if vkind(src) == .C_INT {
                    // ConstantFolder::FoldCast
                    z = const_int_words(dst_ty, ap_words(ap_zext(ap_from_words(type_int_width(vtype(src)), const_int_value(src)), dst_bits)));
                } else {
                    if is_constant_kind(vkind(src)) fatal("bdce: constant-folding a zext of a non-integer constant is not supported yet");
                    z = create_cast(.ZEXT, src, dst_ty);
                    insert_before_named(z, i, vname(i));
                    copy_debug_loc(z, i);
                }
                replace_all_uses_with(i, z);
                array_add(*wl, i);
                changed = true;
                continue;
            }
        }
        if is_binary_op(inst_op(i)) {
            demanded := db_demanded_bits(db, i);
            if !ap_is_all_ones(demanded) {
                ok, mask := match_apint(op(i, 1));
                if ok {
                    can := false;
                    o := inst_op(i);
                    if o == .OR || o == .XOR can = !ap_intersects(demanded, mask);
                    else if o == .AND can = ap_is_subset_of(demanded, mask);
                    if can && i != op(i, 0) {
                        bdce_clear_assumptions_of_users(i, db);
                        replace_all_uses_with(i, op(i, 0));
                        array_add(*wl, i);
                        changed = true;
                        continue;
                    }
                }
            }
        }
        n := nops(i);
        if n > 0 for k: 0..n-1 {
            u := op_use(i, k);
            v := ir.u_val[u];
            if v == NONE || !is_int_or_int_vector(vtype(v)) continue;
            if !is_inst(v) && vkind(v) != .ARGUMENT continue;
            if !db_is_use_dead(db, u) continue;
            bdce_clear_assumptions_of_users(i, db);
            use_set(u, const_int_or_splat_zero(vtype(v)));
            changed = true;
        }
    }
    k := wl.count;
    while k > 0 { k -= 1; drop_all_references(wl[k]); }
    for wl erase_inst(it);
    if !changed return PRESERVE_ALL;
    return preserved_cfg();
}

// ConstantInt::get(Ty, 0): for vectors the splat (zeroinitializer)
const_int_or_splat_zero :: (t: Type_Id) -> Value_Id {
    if is_vector_type(t) return const_null_value(t);
    return const_int(t, 0);
}
