// VPlanTransforms::simplifyRecipes (simplifyRecipe, simplifyLogicalRecipe, tryToFoldLiveIns), removeDeadRecipes,
// recursivelyDeleteDeadRecipes, removeRedundantExpandSCEVRecipes, introduceMasksAndLinearize (VPlanPredicator.cpp).
// Ported from llvm/lib/Transforms/Vectorize/VPlanTransforms.cpp and VPlanPredicator.cpp (LLVM 23.1.5).

// getOpcodeOrIntrinsicID: (has, is_intrinsic, opcode-or-id)
vp_opcode_or_intrinsic_id :: (r: Vp_Rec) -> (bool, bool, u32) {
    id := vp_intrinsic_id(r);
    if id != NOT_INTRINSIC return true, true, cast(u32) id;
    k := vr(r).kind;
    if k == .INSTRUCTION || k == .WIDEN || k == .WIDEN_CAST return true, false, vr(r).opcode;
    if k == .WIDEN_GEP return true, false, vp_opc(.GEP);
    if k == .REPLICATE return true, false, vp_opc(inst_op(vp_underlying_instr(r)));
    if k == .WIDEN_PHI return true, false, vp_opc(.PHI);
    if k == .VECTOR_POINTER || k == .PRED_INST_PHI || k == .SCALAR_IV_STEPS return true, false, 1000 + cast(u32) k;
    return false, false, 0;
}

vp_isf_query :: () -> Simplify_Query { q: Simplify_Query; q.have_tli = false; return q; }

// tryToFoldLiveIns
vp_try_to_fold_live_ins :: (r: Vp_Rec, ops: [] Vp_Val) -> Vp_Val {
    has, is_iid, oc := vp_opcode_or_intrinsic_id(r);
    if !has return NONE;
    irs: [..] Value_Id; irs.allocator = temp;
    for o: ops {
        cand := o;
        okb, bx := vpm_vpi(o, VPI_BROADCAST, 1);
        if okb cand = vp_op(bx, 0);
        ck := vv(cand).kind;
        if ck != .IR && ck != .SYMBOLIC && ck != .REGION return NONE;   // m_LiveIn
        v := vp_uv(cand);
        if v == NONE return NONE;
        array_add(*irs, v);
    }
    q := vp_isf_query();
    folded: Value_Id = NONE;
    if is_iid {
        if vr(r).kind == .INSTRUCTION irs.count -= 1;
        fmf := ifx vp_is_with_ir_flags_kind(vr(r).kind) then vp_fmf_or_none(r) else 0;
        folded = isf_fold_intrinsic(cast(Intrinsic_Id) oc, irs, vp_scalar_type(vr(r).def), fmf, q);
    } else {
        o := cast(u16) oc;
        if vp_is_ir_opcode(o) && is_binary_op(vp_ir_opcode(o)) folded = simplify_binop(vp_ir_opcode(o), irs[0], irs[1], q);
        else if vp_opcode_is_cast(o) folded = simplify_cast_inst(vp_ir_opcode(o), irs[0], vp_scalar_type(vr(r).def), q);
        else if o == VPI_NOT folded = simplify_binop(.XOR, irs[0], const_all_ones_of(vtype(irs[0])), q);
        else if o == vp_opc(.SELECT) folded = simplify_select_inst(irs[0], irs[1], irs[2], 0, q);
        else if o == vp_opc(.ICMP) || o == vp_opc(.FCMP) folded = simplify_cmp_inst(vr(r).flags.pred, false, irs[0], irs[1], q);
        else if o == vp_opc(.GEP) {
            gep := vp_underlying_instr(r);
            idx: [..] Value_Id; idx.allocator = temp;
            for k: 1..irs.count-1 array_add(*idx, irs[k]);
            folded = simplify_gep_inst(gep_source_type(gep), irs[0], idx, vr(r).flags.gep, q);
        } else if o == VPI_PTR_ADD || o == VPI_WIDE_PTR_ADD {
            folded = simplify_gep_inst(type_int(8), irs[0], .[irs[1]], vr(r).flags.gep, q);
        } else if o == vp_opc(.EXTRACTELEMENT) folded = irs[0];
    }
    if folded != NONE return vp_live_in(folded);
    return NONE;
}
// InstSimplifyFolder::FoldIntrinsic
isf_fold_intrinsic :: (id: Intrinsic_Id, args: [] Value_Id, ty: Type_Id, fmf: u32, q: Simplify_Query) -> Value_Id {
    return simplify_intrinsic(id, ty, args, fmf, q, NONE, EB_IGNORE, RM_NEAREST_TIES_TO_EVEN);
}
// VPIRFlags::getFastMathFlagsOrNone
vp_fmf_or_none :: (r: Vp_Rec) -> u32 {
    t := vr(r).flags.optype;
    if t == .FP_MATH_OP || t == .FCMP || t == .REDUCTION_OP return vr(r).flags.fmf;
    return 0;
}

// m_LogicalAnd: VPInstruction LogicalAnd (or a select i1 c, x, false)
vpm_logical_and :: (v: Vp_Val) -> (bool, Vp_Val, Vp_Val) {
    ok, r := vpm_vpi(v, VPI_LOGICAL_AND, 2);
    if ok return true, vp_op(r, 0), vp_op(r, 1);
    oks, c, t, f := vpm_select(v);
    if oks && vp_is_const_int_zero(f) && type_bits(vp_scalar_type(v)) == 1 return true, c, t;
    return false, NONE, NONE;
}
vpm_not :: (v: Vp_Val) -> (bool, Vp_Val) {
    ok, r := vpm_vpi(v, VPI_NOT, 1);
    if ok return true, vp_op(r, 0);
    // m_c_Binary<Xor>(m_AllOnes(), Op0)
    okx, a, b := vpm_c_binary(v, vp_opc(.XOR));
    if okx {
        if vpm_all_ones(a) return true, b;
        if vpm_all_ones(b) return true, a;
    }
    return false, NONE;
}
vpm_is_false :: (v_in: Vp_Val) -> bool { v := vpm_through_broadcast(v_in); return vp_is_constant_int(v) && type_bits(vp_scalar_type(v)) == 1 && ap_is_zero(vp_const_int_value(v)); }
vpm_is_true :: (v_in: Vp_Val) -> bool { v := vpm_through_broadcast(v_in); return vp_is_constant_int(v) && type_bits(vp_scalar_type(v)) == 1 && ap_is_one(vp_const_int_value(v)); }
// commuted binary (AllRecipe_commutative_match): both operand orders
vpm_c_binary :: (v: Vp_Val, opc: u16) -> (bool, Vp_Val, Vp_Val) {
    r := vp_def(v);
    ok, o := vpm_opcode(r, false);
    if !ok || o != opc || !vpm_arity_ok(r, 2) return false, NONE, NONE;
    return true, vp_op(r, 0), vp_op(r, 1);
}

vp_rauw_def :: (r: Vp_Rec, v: Vp_Val) { vp_rauw(vr(r).def, v); }

// simplifyLogicalRecipe
vp_simplify_logical_recipe :: (def: Vp_Rec, b: *Vp_Builder, can_create: bool) -> bool {
    d := vr(def).def;
    // (X && Y) | (X && !Y) -> X
    ok, a0, a1 := vpm_c_binary(d, vp_opc(.OR));
    if ok {
        for side: 0..1 {
            l := ifx side == 0 then a0 else a1; rr := ifx side == 0 then a1 else a0;
            okl, x, y := vpm_logical_and(l);
            if !okl continue;
            okr, x2, ny := vpm_logical_and(rr);
            if !okr || x2 != x continue;
            okn, y2 := vpm_not(ny);
            if !okn || y2 != y continue;
            vp_rauw_def(def, x); vp_erase_recipe(def); return true;
        }
        for side: 0..1 {
            o := ifx side == 0 then a1 else a0;
            if vpm_all_ones(o) { vp_rauw_def(def, vp_live_in(const_all_ones_of(vp_scalar_type(d)))); return true; }
        }
        for side: 0..1 {
            o := ifx side == 0 then a1 else a0; x := ifx side == 0 then a0 else a1;
            if vpm_zero_int(o) { vp_rauw_def(def, x); return true; }
        }
        for side: 0..1 {
            x := ifx side == 0 then a0 else a1; o := ifx side == 0 then a1 else a0;
            okn, nx := vpm_not(o);
            if okn && nx == x { vp_rauw_def(def, vp_live_in(const_all_ones_of(vp_scalar_type(d)))); return true; }
        }
    }
    ok, a0, a1 = vpm_c_binary(d, vp_opc(.AND));
    if ok {
        for side: 0..1 { o := ifx side == 0 then a1 else a0; if vpm_zero_int(o) { vp_rauw_def(def, vp_zero(vp_scalar_type(d))); return true; } }
        for side: 0..1 { x := ifx side == 0 then a0 else a1; o := ifx side == 0 then a1 else a0; if vpm_all_ones(o) { vp_rauw_def(def, x); return true; } }
    }
    // m_c_LogicalAnd(X, Y): the VPInstruction (either operand order) or m_c_Select(X, Y, false), i.e.
    // select(X, Y, false) or select(not X, false, Y)
    c_logical_and :: (d: Vp_Val, want_true: bool) -> (bool, Vp_Val) {
        is_y :: (v: Vp_Val, want_true: bool) -> bool { return ifx want_true then vpm_is_true(v) else vpm_is_false(v); }
        okla, lr := vpm_vpi(d, VPI_LOGICAL_AND, 2);
        if okla {
            if is_y(vp_op(lr, 1), want_true) return true, vp_op(lr, 0);
            if is_y(vp_op(lr, 0), want_true) return true, vp_op(lr, 1);
        }
        oks, c, t, f := vpm_select(d);
        if oks {
            if is_y(t, want_true) && vpm_is_false(f) return true, c;
            okn, nc := vpm_not(c);
            if okn && vpm_is_false(t) && is_y(f, want_true) return true, nc;
        }
        return false, NONE;
    }
    {
        okf, _ := c_logical_and(d, false);
        if okf { vp_rauw_def(def, vp_false()); return true; }
        okt, x := c_logical_and(d, true);
        if okt { vp_rauw_def(def, x); return true; }
    }
    ok, a0, a1 = vpm_c_binary(d, vp_opc(.OR));
    if can_create && ok {
        for side: 0..1 {
            l := ifx side == 0 then a0 else a1; rr := ifx side == 0 then a1 else a0;
            okl, x, y := vpm_logical_and(l);
            if !okl continue;
            okr, x2, z := vpm_logical_and(rr);
            if !okr || x2 != x continue;
            if !vp_has_more_than_one_unique_user(vp_op(def, 0)) || !vp_has_more_than_one_unique_user(vp_op(def, 1)) {
                or_r := vpb_or(b, y, z);
                vp_rauw_def(def, vr(vpb_logical_and(b, x, vr(or_r).def)).def);
                return true;
            }
            break;
        }
    }
    okl, x, la := vpm_logical_and(d);
    if okl {
        okl2, x2, _ := vpm_logical_and(la);
        if okl2 && x2 == x { vp_rauw_def(def, vp_op(def, 1)); return true; }
        okl3, y3, x3 := vpm_logical_and(la);
        if okl3 && x3 == x { vp_rauw_def(def, vr(vpb_logical_and(b, x, y3)).def); return true; }
        okn, nx := vpm_not(la);
        if okn && nx == x { vp_rauw_def(def, vp_false()); return true; }
    }
    oks, sc, st, sf := vpm_select(d);
    if oks {
        if st == sf { vp_rauw_def(def, st); return true; }
        if can_create && vpm_is_false(st) && vpm_is_true(sf) { vp_rauw_def(def, vr(vpb_not(b, sc)).def); return true; }
        okn, c := vpm_not(sc);
        if okn {
            vp_set_operand(def, 0, c); vp_set_operand(def, 1, sf); vp_set_operand(def, 2, st);
            return true;
        }
        if can_create && vp_has_one_use(st) {
            oko, y, z := vpm_c_binary(st, vp_opc(.OR));
            if oko {
                for side: 0..1 {
                    yy := ifx side == 0 then y else z; zz := ifx side == 0 then z else y;
                    if sf == yy && type_bits(vp_scalar_type(yy)) == 1 && type_kind(vp_scalar_type(yy)) == .INT {
                        la2 := vpb_logical_and(b, sc, zz);
                        vp_rauw_def(def, vr(vpb_or(b, yy, vr(la2).def)).def);
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

// simplifyRecipe
vp_simplify_recipe :: (def: Vp_Rec) {
    d := vr(def).def;
    f := vp_try_to_fold_live_ins(def, vr(def).ops);
    if f != NONE { vp_rauw(d, f); return; }
    k := vr(def).kind;
    if k == .PRED_INST_PHI { o := vp_op(def, 0); if vp_is_ir_value(o) vp_rauw(d, o); }
    if k == .REPLICATE && vr(def).predicated && inst_op(vp_underlying_instr(def)) == .STORE {
        all := true;
        for i: 0..vpm_num_ops_without_mask(def)-1 if !vp_is_uniform_across_vfs_and_ufs(vp_op(def, i)) all = false;
        if all && vp_is_header_mask(vp_op(def, vp_nops(def) - 1)) {
            ops: [..] Vp_Val; ops.allocator = temp;
            for i: 0..vpm_num_ops_without_mask(def)-1 array_add(*ops, vp_op(def, i));
            un := vp_new_replicate(vp_underlying_instr(def), ops, vr(def).single_scalar, NONE, vr(def).flags, vr(def).md, vr(def).dl);
            vp_insert_before(un, def);
            if d != NONE && vr(un).def != NONE vp_rauw(d, vr(un).def);
            vp_erase_recipe(def);
            return;
        }
    }
    b := vpb_before(def);
    can_create := k != .INSTRUCTION || vv(d).uv == NONE;
    // trunc (zext|sext A)
    okt, t0 := vpm_unary(d, vp_opc(.TRUNC));
    if okt {
        oke, a := vpm_unary(t0, vp_opc(.ZEXT));
        if !oke { oke, a = vpm_unary(t0, vp_opc(.SEXT)); }
        if oke {
            tt := vp_scalar_type(d); at := vp_scalar_type(a);
            if tt == at vp_rauw(d, a);
            else {
                if k != .WIDEN_CAST return;
                if type_bits(scalar_type(at)) < type_bits(scalar_type(tt)) {
                    oks, _ := vpm_unary(t0, vp_opc(.SEXT));
                    ext_opc := ifx oks then Opcode.SEXT else .ZEXT;
                    ext := vpb_widen_cast(*b, ext_opc, a, tt);
                    ue := vp_uv(t0);
                    if ue != NONE vp_set_underlying(vr(ext).def, ue);
                    vp_rauw(d, vr(ext).def);
                } else if type_bits(scalar_type(at)) > type_bits(scalar_type(tt)) {
                    tr := vpb_widen_cast(*b, .TRUNC, a, tt);
                    vp_rauw(d, vr(tr).def);
                }
            }
        }
    }
    if vp_simplify_logical_recipe(def, *b, can_create) return;
    d = vr(def).def;
    ok, a0, a1 := vpm_c_binary(d, vp_opc(.ADD));
    if ok {
        if vpm_zero_int(a1) { vp_rauw(d, a0); return; }
        if vpm_zero_int(a0) { vp_rauw(d, a1); return; }
    }
    ok, a0, a1 = vpm_c_binary(d, vp_opc(.MUL));
    if ok {
        if vpm_one(a1) { vp_rauw(d, a0); return; }
        if vpm_one(a0) { vp_rauw(d, a1); return; }
        if vpm_zero_int(a1) || vpm_zero_int(a0) { vp_rauw(d, vp_zero(vp_scalar_type(d))); return; }
        if can_create && (vpm_all_ones(a1) || vpm_all_ones(a0)) {
            a := ifx vpm_all_ones(a1) then a0 else a1;
            s := vpb_sub(*b, vp_zero(vp_scalar_type(a)), a, vr(def).dl, "", false, vr(def).flags.nsw);
            vp_rauw(d, vr(s).def); return;
        }
    }
    ok, a0, a1 = vpm_c_binary(d, vp_opc(.ADD));
    if can_create && ok {
        for side: 0..1 {
            x := ifx side == 0 then a0 else a1; o := ifx side == 0 then a1 else a0;
            oks, z, y := vpm_binary(o, vp_opc(.SUB));
            if oks && vpm_zero_int(z) {
                other := vp_def(vp_op(def, ifx vp_op(def, 0) == x then 1 else 0));
                nsw := vr(def).flags.nsw && vr(other).flags.nsw;
                s := vpb_sub(*b, x, y, vr(def).dl, "", false, nsw);
                vp_rauw(d, vr(s).def); return;
            }
        }
    }
    ok, a0, a1 = vpm_c_binary(d, vp_opc(.MUL));
    if can_create && ok {
        for side: 0..1 {
            a := ifx side == 0 then a0 else a1; c := ifx side == 0 then a1 else a0;
            if !vp_is_constant_int(c) continue;
            ap := vp_const_int_value(c);
            if !ap_is_power_of_2(ap) continue;
            sh := cast(u64) ap_exact_log2(ap);
            nsw := vr(def).flags.nsw && sh != cast(u64) (ap.bits - 1);
            r := vpb_nary(*b, vp_opc(.SHL), .[a, vp_const_int(type_int(ap.bits), sh)], vpf_wrap(vr(def).flags.nuw, nsw), .[], vr(def).dl);
            vp_rauw(d, vr(r).def); return;
        }
    }
    ok, a0, a1 = vpm_binary(d, vp_opc(.UDIV));
    if can_create && ok && vp_is_constant_int(a1) && ap_is_power_of_2(vp_const_int_value(a1)) {
        ap := vp_const_int_value(a1);
        r := vpb_nary(*b, vp_opc(.LSHR), .[a0, vp_const_int(type_int(ap.bits), cast(u64) ap_exact_log2(ap))], vr(def).flags, .[], vr(def).dl);
        vp_rauw(d, vr(r).def); return;
    }
    okn, na := vpm_not(d);
    if okn {
        okn2, nna := vpm_not(na);
        if okn2 { vp_rauw(d, nna); return; }
        okc, _, _ := vpm_cmp(na);
        if okc {
            cmp := vp_def(na);
            all := true;
            for u: vv(na).users {
                if vpm_vpi_r(u, VPI_NOT, 1) && vp_op(u, 0) == na continue;
                oks, sc, _, _ := vpm_select(vr(u).def);
                if oks && sc == na continue;
                all = false;
            }
            if all {
                vr(cmp).flags.pred = cmp_inverse(vr(cmp).flags.pred);
                users: [..] Vp_Rec; users.allocator = temp;
                for vv(na).users array_add(*users, it);
                for u: users {
                    oks, sc, sx, sy := vpm_select(vr(u).def);
                    if oks && sc == na { vp_set_operand(u, 1, sy); vp_set_operand(u, 2, sx); }
                    else vp_rauw(vr(u).def, na);
                }
                if vr(cmp).dl == NONE && vr(def).dl != NONE vr(cmp).dl = vr(def).dl;
            }
        }
    }
    if vp_is_vpi(def, VPI_ANY_OF) vp_simplify_any_of(def, *b);
    if vr(def).dead return;
    d = vr(def).def;
    // (x uno x) | (y uno y) -> x uno y
    ok, a0, a1 = vpm_binary(d, vp_opc(.OR));
    if can_create && ok && vp_is_uno_self(a0) && vp_is_uno_self(a1) {
        x := vp_op(vp_def(a0), 0); y := vp_op(vp_def(a1), 0);
        vp_rauw(d, vr(vpb_fcmp(*b, FCMP_UNO, x, y)).def); return;
    }
    if k == .DERIVED_IV {
        if ((vpm_zero_int(vp_op(def, 0)) && vpm_one(vp_op(def, 2))) || (vpm_zero_int(vp_op(def, 0)) && vpm_zero_int(vp_op(def, 1)))) &&
           vp_scalar_type(vp_op(def, 1)) == vp_scalar_type(d) {
            vp_rauw(d, vp_op(def, 1)); return;
        }
    }
    if vpm_vpi_r(def, VPI_WIDE_IV_STEP, 2) && vpm_one(vp_op(def, 1)) {
        x := vp_op(def, 0);
        wty := vp_scalar_type(d);
        if vp_scalar_type(x) != wty x = vr(vpb_widen_cast(*b, .TRUNC, x, wty)).def;
        vp_rauw(d, x); return;
    }
    if vp_intrinsic_id(def) == iid_by_name("llvm.vp.merge") vp_unported("vp.merge simplification");
    if vp_is_vpi(def, VPI_MASKED_COND) && !vp_is_masked(def) { vp_rauw(d, vp_op(def, 0)); return; }
    if vpm_vpi_r(def, VPI_EXTRACT_LAST_LANE, 1) {
        a := vp_op(def, 0);
        if vp_val_is_vpi(a, VPI_BUILD_VECTOR) { bv := vp_def(a); vp_rauw(d, vp_op(bv, vp_nops(bv) - 1)); return; }
        okb, br := vpm_vpi(a, VPI_BROADCAST, 1);
        if okb { vp_rauw(d, vp_op(br, 0)); return; }
        ar := vp_def(a);
        if ar != NONE && (vr(ar).kind == .INSTRUCTION || vr(ar).kind == .REPLICATE) && vp_is_single_scalar(a) { vp_rauw(d, a); return; }
        if vp_has_scalar_vf_only() { vp_rauw(d, a); return; }
    }
    if vpm_vpi_r(def, VPI_EXTRACT_PENULTIMATE_ELEMENT, 1) && vp_val_is_vpi(vp_op(def, 0), VPI_BUILD_VECTOR) {
        bv := vp_def(vp_op(def, 0)); vp_rauw(d, vp_op(bv, vp_nops(bv) - 2)); return;
    }
    if vpm_vpi_r(def, vp_opc(.EXTRACTELEMENT), 2) && vp_val_is_vpi(vp_op(def, 0), VPI_BUILD_VECTOR) {
        okc, idx := vpm_constant_int(vp_op(def, 1));
        if okc { bv := vp_def(vp_op(def, 0)); vp_rauw(d, vp_op(bv, cast(s64) idx)); return; }
    }
    if vp_is_vpi(def, VPI_BUILD_VECTOR) {
        all_eq := true;
        for vr(def).ops if it != vp_op(def, 0) all_eq = false;
        if all_eq { vp_rauw(d, vr(vpb_nary(*b, VPI_BROADCAST, .[vp_op(def, 0)])).def); return; }
        first_lane :: (r: Vp_Rec, idx: s64, data: *void) -> bool { return vp_uses_first_lane_only(r, << cast(*Vp_Val) data); }
        vp_replace_uses_with_if(d, vp_op(def, 0), first_lane, *d);
    }
    {
        oks, sc, _, _ := vpm_select(d);
        if oks {
            okb, br := vpm_vpi(sc, VPI_BROADCAST, 1);
            if okb { vp_set_operand(def, 0, vp_op(br, 0)); return; }
        }
    }
    okb, br := vpm_vpi(d, VPI_BROADCAST, 1);
    if okb {
        scalars :: (r: Vp_Rec, idx: s64, data: *void) -> bool { return vp_uses_scalars(r, << cast(*Vp_Val) data); }
        vp_replace_uses_with_if(d, vp_op(br, 0), scalars, *d);
        return;
    }
    if vp_is_vp_phi(def) || k == .WIDEN_PHI || vp_is_header_phi_kind(k) {
        if vp_nops(def) == 1 { vp_rauw(d, vp_op(def, 0)); return; }
        if k == .FIRST_ORDER_RECURRENCE_PHI {
            if vp_op(def, 0) == vp_op(def, 1) vp_rauw(d, vp_op(def, 0));
        }
        return;
    }
    if vp_nops(def) == 1 && vp_is_vpi(def, VPI_COMPUTE_REDUCTION_RESULT) && vp_is_ir_value(vp_op(def, 0)) { vp_rauw(d, vp_op(def, 0)); return; }
    if !vp_is_unrolled() return;
    // extract-lane(%lane, %src) after unrolling
    if vpm_vpi_r(def, VPI_EXTRACT_LANE, 2) {
        lane := vp_op(def, 0); a := vp_op(def, 1);
        if vp_is_single_scalar(a) { vp_rauw(d, a); return; }
        ar := vp_def(a);
        if vpm_zero_int(lane) && vp_is_canonical_widen_iv(ar) { vp_rauw(d, vb(vp_recipe_region(ar)).can_iv); return; }
        vp_rauw(d, vr(vpb_nary(*b, vp_opc(.EXTRACTELEMENT), .[a, lane], .{}, .[], vr(def).dl)).def);
        return;
    }
    // Def = (X + _) + Y with X = phi(0, Def.op0), Y a live-in: fold Y into the phi's start value
    {
        ok1, inc, y := vpm_binary(d, vp_opc(.ADD));
        if ok1 && vp_is_ir_value(y) {
            ok2, x, _ := vpm_binary(inc, vp_opc(.ADD));
            xr := vp_def(x);
            if ok2 && vp_is_vp_phi(xr) && vp_nops(xr) == 2 && vpm_zero_int(vp_op(xr, 0)) && vp_op(xr, 1) == vp_op(def, 0) {
                iv_inc := vp_op(def, 0);
                if vp_num_users(iv_inc) == 2 {
                    xd := vr(xr).def;
                    inc2: Vp_Rec = NONE;
                    for u: vv(xd).users {
                        oka, p, q := vpm_binary(vr(u).def, vp_opc(.ADD));
                        if vr(u).def != NONE && oka && p == xd && q == y { inc2 = u; break; }
                    }
                    if vp_num_users(xd) == 1 || (vp_num_users(xd) == 2 && inc2 != NONE) {
                        vp_rauw(d, iv_inc);
                        if inc2 != NONE vp_rauw(vr(inc2).def, xd);
                        vp_set_operand(xr, 0, y);
                        return;
                    }
                }
            }
        }
    }
    if k == .VECTOR_POINTER {
        if vp_nops(def) <= 2 || vpm_zero_int(vp_op(def, 2)) { vp_rauw(d, vp_op(def, 0)); return; }
    }
    if k == .SCALAR_IV_STEPS {
        if vp_steps_start_index(def) == NONE && vp_only_first_lane_used(d) { vp_rauw(d, vp_op(def, 0)); return; }
    }
    if vpm_vpi_r(def, VPI_REDUCTION_START_VECTOR, 3) {
        start_v := vp_op(def, 0);
        in_loop :: (u: Vp_Rec, idx: s64, data: *void) -> bool { return vr(u).kind == .REDUCTION_PHI && vr(u).rdx_style != .UNORDERED; }
        vp_replace_uses_with_if(d, start_v, in_loop, null);
        return;
    }
    if vpl.ufs[0] == 1 && vpm_vpi_r(def, VPI_EXTRACT_LAST_PART, 1) { vp_rauw(d, vp_op(def, 0)); return; }
}
vp_is_uno_self :: (v: Vp_Val) -> bool {
    r := vp_def(v);
    ok, o := vpm_opcode(r);
    if !ok || o != vp_opc(.FCMP) || !vpm_arity_ok(r, 2) return false;
    return vr(r).flags.pred == FCMP_UNO && vp_op(r, 0) == vp_op(r, 1);
}
// simplifyRecipe's AnyOf case
vp_simplify_any_of :: (def: Vp_Rec, b: *Vp_Builder) {
    new_ops: [..] Vp_Val; new_ops.allocator = temp;
    unpaired: Vp_Rec = NONE;
    for o: vr(def).ops {
        if vp_num_users(o) > 1 || !vp_is_uno_self(o) { array_add(*new_ops, o); continue; }
        x := vp_op(vp_def(o), 0);
        if unpaired == NONE { unpaired = vp_def(o); continue; }
        array_add(*new_ops, vr(vpb_fcmp(b, FCMP_UNO, vp_op(unpaired, 0), x)).def);
        unpaired = NONE;
    }
    if unpaired != NONE array_add(*new_ops, vr(unpaired).def);
    if new_ops.count < vp_nops(def) {
        n := vpb_nary(b, VPI_ANY_OF, new_ops);
        vp_rauw(vr(def).def, vr(n).def);
    }
}
// m_HeaderMask
vp_is_header_mask :: (v: Vp_Val) -> bool {
    // header_mask_match: only the abstract VPRegionValue matches; a materialized mask (icmp, active-lane-mask, ...)
    // is an ordinary recipe value and does not
    if vv(v).kind == .REGION { return v == vb(vv(v).region).header_mask; }
    return false;
}
// VPBuilder::createWidenCast
vpb_widen_cast :: (b: *Vp_Builder, opc: Opcode, v: Vp_Val, ty: Type_Id) -> Vp_Rec {
    r := vp_new_widen_cast(opc, v, ty, NONE, vp_default_flags(vp_opc(opc)));
    return vpb_insert(b, r);
}
vp_new_widen_cast :: (opc: Opcode, v: Vp_Val, ty: Type_Id, ci: Value_Id, flags: Vp_Flags, md: [] Vp_Md = .[], dl: Md_Id = NONE) -> Vp_Rec {
    r := vp_new_single_def(.WIDEN_CAST, .[v], ty, ci, dl);
    vr(r).opcode = vp_opc(opc); vr(r).flags = flags;
    for md array_add(*vr(r).md, it);
    return r;
}

// VPlanTransforms::simplifyRecipes
vp_simplify_recipes :: () {
    for bb: vp_blocks_only_basic(vp_rpo(vpl.entry, true)) {
        for r: vp_block_recipes(bb) {
            if vr(r).dead || vr(r).parent != bb continue;
            if vp_is_single_def_kind(vr(r).kind) vp_simplify_recipe(r);
        }
    }
}

// VPlanTransforms::removeDeadRecipes
vp_remove_dead_recipes :: () {
    rpo := vp_rpo(vpl.entry, true);
    for < bb: rpo {
        if !vp_is_basic(bb) continue;
        r := vb(bb).last;
        while r != NONE {
            prev := vr(r).prev;
            defer r = prev;
            if vp_is_dead_recipe(r) { vp_erase_recipe(r); continue; }
            if !vp_is_vp_phi(r) || vp_nops(r) != 2 continue;
            start := vp_op(r, 0); incoming := vp_op(r, 1);
            pu := vp_single_user(vr(r).def);
            if pu == NONE continue;
            if pu != vp_def(incoming) || vp_num_users(incoming) != 1 continue;
            inc_r := vp_def(incoming);
            vp_rauw(vr(r).def, start);
            vp_erase_recipe(r);
            if prev == inc_r prev = vr(inc_r).prev;
            vp_erase_recipe(inc_r);
        }
    }
}
// recursivelyDeleteDeadRecipes
vp_recursively_delete_dead_recipes :: (v: Vp_Val) {
    wl: [..] Vp_Val; wl.allocator = temp;
    seen: Table(Vp_Val, bool); seen.allocator = temp;
    array_add(*wl, v);
    while wl.count {
        cur := pop(*wl);
        if table_contains(*seen, cur) continue;
        table_set(*seen, cur, true);
        r := vp_def(cur);
        if r == NONE || !vp_is_dead_recipe(r) continue;
        for vr(r).ops array_add(*wl, it);
        vp_erase_recipe(r);
    }
}

// VPlanTransforms::introduceMasksAndLinearize: only single-block loop bodies are ported (no masks needed)
