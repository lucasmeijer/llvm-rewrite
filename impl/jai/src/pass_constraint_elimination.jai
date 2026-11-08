// ConstraintElimination: port of llvm/lib/Transforms/Scalar/ConstraintElimination.cpp.
// The constraint systems are constraint_system.jai (llvm/lib/Analysis/ConstraintSystem.cpp).
//
// FactOrCheck = `Ce_Fact` (the union is plain fields), ConstraintInfo = `Ce_Info` (unsigned and signed systems),
// StackEntry = `Ce_Stack_Entry`, ConstraintTy = `Ce_Constraint`, Decomposition = `Ce_Decomp`. CmpPredicate is a
// predicate plus its samesign bit (`Ce_Pred`). The reproducer (-constraint-elimination-dump-reproducers) and
// optimization remarks are not ported: the option fails loudly.

CE_BAD_PRED :: cast(u8) 42;   // CmpInst::BAD_ICMP_PREDICATE

Ce_Cond :: struct {          // ConditionTy (Pred is a CmpPredicate)
    pred: u8 = CE_BAD_PRED;
    samesign: bool;
    op0: Value_Id = NONE;
    op1: Value_Id = NONE;
}

Ce_Entry_Ty :: enum u8 { CONDITION_FACT; INST_FACT; INST_CHECK; USE_CHECK; }

Ce_Fact :: struct {          // FactOrCheck
    ty: Ce_Entry_Ty;
    inst: Value_Id = NONE;   // INST_FACT / INST_CHECK
    u: Use_Id = NONE;        // USE_CHECK
    cond: Ce_Cond;           // CONDITION_FACT
    does_hold: Ce_Cond;
    num_in: u32;
    num_out: u32;
}

Ce_Stack_Entry :: struct {
    num_in: u32;
    num_out: u32;
    is_signed: bool;
    values_to_release: [] Value_Id;
}

Ce_Constraint :: struct {    // ConstraintTy
    coeffs: [..] s64;
    preconds: [..] Ce_Cond;
    is_signed: bool;
    is_eq: bool;
    is_ne: bool;
}

Ce_Info :: struct {          // ConstraintInfo
    ucs: Constraint_System;
    scs: Constraint_System;
}

Ce_Decomp_Entry :: struct { coef: s64; v: Value_Id; }
Ce_Decomp :: struct { offset: s64; vars: [..] Ce_Decomp_Entry; }

ce_cl: struct {
    max_rows: s64 = 500;     // -constraint-elimination-max-rows
}

constraint_elimination_parse_cl_opt :: (name: string, value: string, has_value: bool) -> bool {
    if name == "constraint-elimination-max-rows" {
        if !has_value fatal("opt: -constraint-elimination-max-rows needs a value");
        n, ok := string_to_int(value);
        if !ok || n < 0 fatal(tprint("opt: invalid value '%' for -constraint-elimination-max-rows", value));
        ce_cl.max_rows = n;
        return true;
    }
    if name == "constraint-elimination-dump-reproducers" {
        if !has_value || value == "true" || value == "1" fatal("opt: -constraint-elimination-dump-reproducers is not supported yet");
        return true;
    }
    return false;
}

CE_MAX_CONSTRAINT_VALUE :: 0x7FFF_FFFF_FFFF_FFFF;

// isa<ConstantInt>: vector-typed ConstantInts exist only with -use-constant-int-for-{fixed-length,scalable}-splat
ce_isa_constant_int :: (v: Value_Id) -> bool {
    if v == NONE || vkind(v) != .C_INT return false;
    return !(type_kind(vtype(v)) == .SVECTOR && !opts.use_constant_int_for_scalable_splat);
}
ce_ci_ap :: (v: Value_Id) -> APInt { return const_ap(v); }

// canUseSExt
ce_can_use_sext :: (ci: Value_Id) -> bool {
    a := ce_ci_ap(ci);
    S64_MIN :: -0x7FFF_FFFF_FFFF_FFFF - 1;
    return ap_sgt_s64(a, S64_MIN) && ap_slt_s64(a, CE_MAX_CONSTRAINT_VALUE);
}

// getContextInstForUse
ce_context_inst_for_use :: (u: Use_Id) -> Value_Id {
    user := ir.u_user[u];
    if is_phi(user) return block_terminator(ir.u_aux[u]);
    return user;
}

ce_fact_context_inst :: (f: *Ce_Fact) -> Value_Id {
    assert(f.ty != .CONDITION_FACT);
    if f.ty == .USE_CHECK return ce_context_inst_for_use(f.u);
    return f.inst;
}
ce_fact_inst_to_simplify :: (f: *Ce_Fact) -> Value_Id {
    if f.ty == .INST_CHECK return f.inst;
    v := ir.u_val[f.u];
    if is_inst(v) return v;
    return NONE;
}
ce_is_check :: (f: *Ce_Fact) -> bool { return f.ty == .INST_CHECK || f.ty == .USE_CHECK; }

ce_dt_in :: (dt: *Dom_Tree, b: Value_Id) -> (u32, u32) {
    n := dt_node(dt, b);
    return dt.nodes[n].dfs_in, dt.nodes[n].dfs_out;
}
ce_condition_fact :: (dt: *Dom_Tree, b: Value_Id, pred: u8, samesign: bool, a: Value_Id, bb: Value_Id, pre: Ce_Cond = .{}) -> Ce_Fact {
    f: Ce_Fact;
    f.ty = .CONDITION_FACT;
    f.cond = .{pred, samesign, a, bb};
    f.does_hold = pre;
    f.num_in, f.num_out = ce_dt_in(dt, b);
    return f;
}
ce_inst_fact :: (dt: *Dom_Tree, b: Value_Id, i: Value_Id, ty: Ce_Entry_Ty) -> Ce_Fact {
    f: Ce_Fact;
    f.ty = ty;
    f.inst = i;
    f.num_in, f.num_out = ce_dt_in(dt, b);
    return f;
}

// ---------------------------------------------------------------- decomposition

ce_dec_const :: (c: s64) -> Ce_Decomp { d: Ce_Decomp; d.vars.allocator = temp; d.offset = c; return d; }
ce_dec_var :: (v: Value_Id) -> Ce_Decomp { d: Ce_Decomp; d.vars.allocator = temp; array_add(*d.vars, .{1, v}); return d; }
ce_dec_copy :: (o: Ce_Decomp) -> Ce_Decomp {
    d: Ce_Decomp; d.vars.allocator = temp; d.offset = o.offset;
    for o.vars array_add(*d.vars, it);
    return d;
}
// Decomposition::add(int64_t) / add(Decomposition) / sub / mul: true = overflow (invalid)
ce_dec_add_off :: (d: *Ce_Decomp, o: s64) -> bool { r, ov := add_ov_s64(d.offset, o); d.offset = r; return ov; }
ce_dec_add :: (d: *Ce_Decomp, o: Ce_Decomp) -> bool {
    if ce_dec_add_off(d, o.offset) return true;
    for o.vars array_add(*d.vars, it);
    return false;
}
ce_dec_mul :: (d: *Ce_Decomp, factor: s64) -> bool {
    r, ov := mul_ov_s64(d.offset, factor);
    d.offset = r;
    if ov return true;
    for * d.vars {
        c, ov2 := mul_ov_s64(it.coef, factor);
        it.coef = c;
        if ov2 return true;
    }
    return false;
}
ce_dec_sub :: (d: *Ce_Decomp, o: Ce_Decomp) -> bool {
    tmp := ce_dec_copy(o);
    if ce_dec_mul(*tmp, -1) return true;
    if ce_dec_add_off(d, tmp.offset) return true;
    for tmp.vars array_add(*d.vars, it);
    return false;
}

Ce_Offset_Result :: struct {
    base: Value_Id = NONE;
    const_off: APInt;
    vars: [..] Gep_Var_Offset;
    nw: u32;                 // GEPNoWrapFlags: F_INBOUNDS implies F_NUSW here
}
ce_gep_nw :: (g: Value_Id) -> u32 {
    f := opr_flags(g) & (F_INBOUNDS | F_NUSW | F_GEP_NUW);
    if f & F_INBOUNDS f |= F_NUSW;
    return f;
}

// GEPOperator::collectOffset (Operator.cpp), for instructions and constant expressions
gep_operator_collect_offset :: (gep: Value_Id, bw: u32) -> (bool, [..] Gep_Var_Offset, APInt) {
    vars: [..] Gep_Var_Offset; vars.allocator = temp;
    const_off := ap_zero(bw);
    cur := opr_gep_source_type(gep);
    for k: 1..cast(s64) nops(gep) - 1 {
        idx := op(gep, cast(u32) k);
        container := cur;
        sty: Type_Id = NONE;
        indexed: Type_Id;
        if k == 1 indexed = cur;
        else if type_kind(cur) == .STRUCT { sty = cur; indexed = NONE; }
        else indexed = type_elem(cur);
        if sty != NONE {
            if vkind(idx) != .C_INT || is_vector_type(vtype(idx)) {
                // a struct index is a ConstantInt or a splat of one
                s := get_splat_value(idx);
                if s == NONE || vkind(s) != .C_INT return false, vars, const_off;
                indexed = type_sub(sty, cast(u32) const_int_zext(s));
            } else {
                indexed = type_sub(sty, cast(u32) const_int_zext(idx));
            }
        }
        scalable := type_is_scalable(indexed);
        is_ci := ce_isa_constant_int(idx) && is_int_type(vtype(idx));
        if is_ci {
            cur = indexed;
            if is_null_value(idx) continue;
            if scalable return false, vars, const_off;
            if sty != NONE {
                const_off = ap_add(const_off, ap_from_u64(bw, dl_struct_offset(sty, cast(u32) const_int_zext(idx))));
                continue;
            }
            stride := gep_seq_stride(container, k, indexed);
            iv := ap_sext_or_trunc(const_ap(idx), bw);
            const_off = ap_add(const_off, ap_mul(iv, ap_from_u64(bw, stride)));
            continue;
        }
        if sty != NONE || scalable return false, vars, const_off;
        cur = indexed;
        size := ap_from_u64(bw, gep_seq_stride(container, k, indexed));
        if !ap_is_zero(size) {
            found := false;
            for * vars if it.v == idx { it.scale = ap_add(it.scale, size); found = true; break; }
            if !found array_add(*vars, .{idx, size});
        }
    }
    return true, vars, const_off;
}

// collectOffsets
ce_collect_offsets :: (gep: Value_Id) -> Ce_Offset_Result {
    res: Ce_Offset_Result;
    res.vars.allocator = temp;
    res.base = op(gep, 0);
    res.nw = ce_gep_nw(gep);
    bw := dl_index_type_size_bits(vtype(res.base));
    ok, vars, off := gep_operator_collect_offset(gep, bw);
    if !ok { r: Ce_Offset_Result; r.vars.allocator = temp; r.const_off = ap_zero(1); return r; }
    res.vars = vars;
    res.const_off = off;
    inner := res.base;
    if is_inst(inner) && inst_op(inner) == .GEP {
        ok2, vars2, off2 := gep_operator_collect_offset(inner, bw);
        if !ok2 || res.vars.count > 1 || vars2.count > 1 || (res.vars.count >= 1 && vars2.count >= 1) return res;
        res.base = op(inner, 0);
        res.const_off = ap_add(res.const_off, off2);
        if res.vars.count == 0 && vars2.count == 1 res.vars = vars2;
        res.nw &= ce_gep_nw(inner);
    }
    return res;
}

// decomposeGEP
ce_decompose_gep :: (gep: Value_Id, preconds: *[..] Ce_Cond, is_signed: bool) -> Ce_Decomp {
    if dl_index_type_size_bits(vtype(op(gep, 0))) > 64 return ce_dec_var(gep);
    assert(!is_signed);
    r := ce_collect_offsets(gep);
    if r.base == NONE || r.nw == 0 return ce_dec_var(gep);
    if (r.nw & F_NUSW) == 0 && ap_is_negative(r.const_off) return ce_dec_var(gep);
    result := ce_dec_const(ap_sext_value(r.const_off));
    array_add(*result.vars, .{1, r.base});
    for r.vars {
        idx_res := ce_decompose(it.v, preconds, is_signed);
        if ce_dec_mul(*idx_res, ap_sext_value(it.scale)) return ce_dec_var(gep);
        if ce_dec_add(*result, idx_res) return ce_dec_var(gep);
        if (r.nw & F_GEP_NUW) == 0 {
            assert((r.nw & F_NUSW) != 0);
            q: Simplify_Query; q.have_tli = false;
            if !is_known_non_negative(it.v, q)
                array_add(preconds, .{ICMP_SGE, false, it.v, const_int(vtype(it.v), 0)});
        }
    }
    return result;
}

ce_known_non_negative_dl :: (v: Value_Id, depth: u32 = 0) -> bool {
    q: Simplify_Query; q.have_tli = false;
    return is_known_non_negative(v, q, depth);
}

// decompose
ce_decompose :: (v_in: Value_Id, preconds: *[..] Ce_Cond, is_signed: bool) -> Ce_Decomp {
    v := v_in;
    merge :: (a: Value_Id, b: Value_Id, is_signed_a: bool, is_signed_b: bool, preconds: *[..] Ce_Cond) -> (bool, Ce_Decomp) {
        ra := ce_decompose(a, preconds, is_signed_a);
        rb := ce_decompose(b, preconds, is_signed_b);
        if ce_dec_add(*ra, rb) return false, ra;
        return true, ra;
    }
    ty := scalar_type(vtype(v));
    if is_ptr_type(ty) && !is_signed {
        if opr_code(v) == .GEP return ce_decompose_gep(v, preconds, is_signed);
        if vkind(v) == .C_NULL return ce_dec_const(0);
        return ce_dec_var(v);
    }
    if !is_int_type(ty) || type_int_width(ty) > 64 return ce_dec_var(v);

    if is_signed {
        if ce_isa_constant_int(v) && ce_can_use_sext(v) return ce_dec_const(ap_sext_value(ce_ci_ap(v)));
        if opr_code(v) == .SEXT v = op(v, 0);
        else if is_inst(v) && inst_op(v) == .ZEXT && (inst(v).flags & F_EXACT) != 0 v = op(v, 0);
        else if is_inst(v) && inst_op(v) == .TRUNC && (inst(v).flags & F_NSW) != 0 {
            if type_bits(scalar_type(vtype(op(v, 0)))) <= 64 v = op(v, 0);
        }
        ok, a, b := pm_ob(v, .ADD, F_NSW);
        if ok {
            okm, d := merge(a, b, is_signed, is_signed, preconds);
            if okm return d;
            return ce_dec_var(v);
        }
        ok, a, b = pm_ob(v, .SUB, F_NSW);
        if ok {
            ra := ce_decompose(a, preconds, is_signed);
            rb := ce_decompose(b, preconds, is_signed);
            if !ce_dec_sub(*ra, rb) return ra;
            return ce_dec_var(v);
        }
        ok, a, b = pm_ob(v, .MUL, F_NSW);
        if ok && ce_isa_constant_int(b) && ce_can_use_sext(b) {
            r := ce_decompose(a, preconds, is_signed);
            if !ce_dec_mul(*r, ap_sext_value(ce_ci_ap(b))) return r;
            return ce_dec_var(v);
        }
        ok, a, b = pm_ob(v, .SHL, F_NSW);
        if ok && ce_isa_constant_int(b) {
            shift := ap_limited(ce_ci_ap(b));
            if shift < cast(u64) type_int_width(ty) - 1 {
                assert(shift < 64);
                r := ce_decompose(a, preconds, is_signed);
                if !ce_dec_mul(*r, (cast(s64) 1) << shift) return r;
                return ce_dec_var(v);
            }
        }
        return ce_dec_var(v);
    }

    if ce_isa_constant_int(v) {
        a := ce_ci_ap(v);
        if ap_uge_u64(a, CE_MAX_CONSTRAINT_VALUE) return ce_dec_var(v);
        return ce_dec_const(cast,no_check(s64) ap_zext_value(a));
    }

    if opr_code(v) == .ZEXT {
        v = op(v, 0);
    } else if opr_code(v) == .SEXT {
        v = op(v, 0);
        array_add(preconds, .{ICMP_SGE, false, v, const_int(vtype(v), 0)});
    } else if is_inst(v) && inst_op(v) == .TRUNC {
        tr := v;
        if type_bits(scalar_type(vtype(op(tr, 0)))) <= 64 {
            fl := inst(tr).flags;
            if (fl & F_NUW) != 0 || (fl & F_NSW) != 0 {
                v = op(tr, 0);
                if (fl & F_NUW) == 0 array_add(preconds, .{ICMP_SGE, false, v, const_int(vtype(v), 0)});
            }
        }
    }

    ok, a, b := pm_ob(v, .ADD, F_NUW);
    if ok {
        okm, d := merge(a, b, is_signed, is_signed, preconds);
        if okm return d;
        return ce_dec_var(v);
    }
    if opr_code(v) == .ADD && ce_isa_constant_int(op(v, 1)) {
        a = op(v, 0);
        ci := op(v, 1);
        cap := ce_ci_ap(ci);
        if ap_is_negative(cap) && ce_can_use_sext(ci) {
            array_add(preconds, .{ICMP_UGE, false, a, const_int(vtype(a), cast,no_check(u64) (ap_sext_value(cap) * -1))});
            okm, d := merge(a, ci, is_signed, true, preconds);
            if okm return d;
            return ce_dec_var(v);
        }
    }
    ok, a, b = pm_ob(v, .ADD, F_NSW);
    if ok {
        if !ce_known_non_negative_dl(a) array_add(preconds, .{ICMP_SGE, false, a, const_int(vtype(a), 0)});
        if !ce_known_non_negative_dl(b) array_add(preconds, .{ICMP_SGE, false, b, const_int(vtype(b), 0)});
        okm, d := merge(a, b, is_signed, is_signed, preconds);
        if okm return d;
        return ce_dec_var(v);
    }
    ok, a, b = pm_disjoint_or(v);
    if ok && ce_isa_constant_int(b) {
        okm, d := merge(a, b, is_signed, is_signed, preconds);
        if okm return d;
        return ce_dec_var(v);
    }
    ok, a, b = pm_ob(v, .SHL, F_NUW);
    if ok && ce_isa_constant_int(b) && ce_can_use_sext(b) {
        sh := ap_sext_value(ce_ci_ap(b));
        if sh < 0 || sh >= 64 return ce_dec_var(v);
        r := ce_decompose(a, preconds, is_signed);
        if !ce_dec_mul(*r, (cast(s64) 1) << cast(u64) sh) return r;
        return ce_dec_var(v);
    }
    ok, a, b = pm_ob(v, .MUL, F_NUW);
    if ok && ce_isa_constant_int(b) && ce_can_use_sext(b) && !ap_is_negative(ce_ci_ap(b)) {
        r := ce_decompose(a, preconds, is_signed);
        if !ce_dec_mul(*r, ap_sext_value(ce_ci_ap(b))) return r;
        return ce_dec_var(v);
    }
    ok, a, b = pm_ob(v, .SUB, F_NUW);
    if ok {
        ra := ce_decompose(a, preconds, is_signed);
        rb := ce_decompose(b, preconds, is_signed);
        if !ce_dec_sub(*ra, rb) return ra;
        return ce_dec_var(v);
    }
    return ce_dec_var(v);
}

// ---------------------------------------------------------------- ConstraintInfo

ce_cs :: (info: *Ce_Info, signed: bool) -> *Constraint_System { return ifx signed then *info.scs else *info.ucs; }

ce_empty_constraint :: () -> Ce_Constraint {
    c: Ce_Constraint;
    c.coeffs.allocator = temp; c.preconds.allocator = temp;
    return c;
}

// getConstraint
ce_get_constraint :: (info: *Ce_Info, pred_in: u8, op0_in: Value_Id, op1_in: Value_Id, new_vars: *[..] Value_Id,
                      force_signed := false) -> Ce_Constraint {
    assert(new_vars.count == 0);
    pred := pred_in; op0 := op0_in; op1 := op1_in;
    is_eq := false; is_ne := false;
    if pred == {
        case ICMP_UGT; #through;
        case ICMP_UGE; #through;
        case ICMP_SGT; #through;
        case ICMP_SGE;
            pred = swapped_predicate(pred);
            t := op0; op0 = op1; op1 = t;
        case ICMP_EQ;
            if !force_signed && pm_zero(op1) pred = ICMP_ULE;
            else { is_eq = true; pred = ICMP_ULE; }
        case ICMP_NE;
            if !force_signed && pm_zero(op1) {
                pred = swapped_predicate(ICMP_UGT);
                t := op0; op0 = op1; op1 = t;
            } else { is_ne = true; pred = ICMP_ULE; }
    }
    if pred != ICMP_ULE && pred != ICMP_ULT && pred != ICMP_SLE && pred != ICMP_SLT return ce_empty_constraint();

    preconds: [..] Ce_Cond; preconds.allocator = temp;
    is_signed := force_signed || icmp_is_signed(pred);
    cs := ce_cs(info, is_signed);
    adec := ce_decompose(strip_pointer_casts_kind(op0, .ZERO_INDICES_SAME_REPRESENTATION), *preconds, is_signed);
    bdec := ce_decompose(strip_pointer_casts_kind(op1, .ZERO_INDICES_SAME_REPRESENTATION), *preconds, is_signed);
    offset1 := wrap_mul_s64(adec.offset, -1);
    offset2 := bdec.offset;

    new_index: Table(Value_Id, u32); new_index.allocator = temp;
    get_or_add :: (v: Value_Id, cs: *Constraint_System, new_vars: *[..] Value_Id, new_index: *Table(Value_Id, u32)) -> u32 {
        p := table_find_pointer(*cs.value2index, v);
        if p return p.*;
        q := table_find_pointer(new_index, v);
        if q return q.*;
        idx := cast(u32) (cs.value2index.count + new_vars.count + 1);
        table_set(new_index, v, idx);
        array_add(new_vars, v);
        return idx;
    }
    for adec.vars get_or_add(it.v, cs, new_vars, *new_index);
    for bdec.vars get_or_add(it.v, cs, new_vars, *new_index);

    res := ce_empty_constraint();
    res.is_signed = is_signed; res.is_eq = is_eq; res.is_ne = is_ne;
    array_resize(*res.coeffs, cs.value2index.count + new_vars.count + 1);
    for adec.vars {
        k := get_or_add(it.v, cs, new_vars, *new_index);
        res.coeffs[k] = wrap_add_s64(res.coeffs[k], it.coef);
    }
    for bdec.vars {
        k := get_or_add(it.v, cs, new_vars, *new_index);
        r, ov := sub_ov_s64(res.coeffs[k], it.coef);
        res.coeffs[k] = r;
        if ov return ce_empty_constraint();
    }
    sum, ov := add_ov_s64(offset1, offset2);
    if ov return ce_empty_constraint();
    if pred == ICMP_SLT || pred == ICMP_ULT {
        sum, ov = add_ov_s64(sum, -1);
        if ov return ce_empty_constraint();
    }
    res.coeffs[0] = sum;
    res.preconds = preconds;

    while new_vars.count > 0 {
        if res.coeffs[res.coeffs.count - 1] != 0 break;
        res.coeffs.count -= 1;
        removed := pop(new_vars);
        table_remove(*new_index, removed);
    }
    return res;
}

// getConstraintForSolving
ce_get_constraint_for_solving :: (info: *Ce_Info, pred_in: u8, op0: Value_Id, op1: Value_Id) -> Ce_Constraint {
    pred := pred_in;
    null_c := const_null_value(vtype(op0));
    if (pred == ICMP_ULE && op0 == null_c) || (pred == ICMP_UGE && op1 == null_c) {
        r := ce_empty_constraint();
        array_resize(*r.coeffs, info.ucs.value2index.count);
        return r;
    }
    if icmp_is_signed(pred) && ce_known_non_negative_dl(op0, MAX_ANALYSIS_RECURSION_DEPTH - 1) &&
       ce_known_non_negative_dl(op1, MAX_ANALYSIS_RECURSION_DEPTH - 1)
        pred = icmp_unsigned_predicate(pred);
    new_vars: [..] Value_Id; new_vars.allocator = temp;
    r := ce_get_constraint(info, pred, op0, op1, *new_vars);
    if new_vars.count > 0 return ce_empty_constraint();
    return r;
}

// ConstraintTy::isValid
ce_is_valid :: (c: *Ce_Constraint, info: *Ce_Info) -> bool {
    if c.coeffs.count == 0 return false;
    for c.preconds if !ce_does_hold(info, it.pred, it.op0, it.op1) return false;
    return true;
}

// ConstraintTy::isImpliedBy: 0 = unknown, 1 = true, 2 = false
ce_is_implied_by :: (c: *Ce_Constraint, cs: *Constraint_System) -> u8 {
    implied := cs_is_condition_implied(cs, c.coeffs);
    if c.is_eq || c.is_ne {
        neg_or_eq := cs_negate_or_equal(c.coeffs);
        neg_or_eq_implied := neg_or_eq.count > 0 && cs_is_condition_implied(cs, neg_or_eq);
        if implied && neg_or_eq_implied return ifx c.is_eq then cast(u8) 1 else 2;
        negated := cs_negate(c.coeffs);
        negated_implied := negated.count > 0 && cs_is_condition_implied(cs, negated);
        strict := cs_to_strict_less_than(c.coeffs);
        strict_implied := strict.count > 0 && cs_is_condition_implied(cs, strict);
        if negated_implied || strict_implied return ifx c.is_ne then cast(u8) 1 else 2;
        return 0;
    }
    if implied return 1;
    negated := cs_negate(c.coeffs);
    if negated.count > 0 && cs_is_condition_implied(cs, negated) return 2;
    return 0;
}

// doesHold
ce_does_hold :: (info: *Ce_Info, pred: u8, a: Value_Id, b: Value_Id) -> bool {
    r := ce_get_constraint_for_solving(info, pred, a, b);
    return ce_is_valid(*r, info) && cs_is_condition_implied(ce_cs(info, r.is_signed), r.coeffs);
}

ce_push_entry :: (stack: *[..] Ce_Stack_Entry, num_in: u32, num_out: u32, is_signed: bool, release: [] Value_Id = .[]) {
    e: Ce_Stack_Entry;
    e.num_in = num_in; e.num_out = num_out; e.is_signed = is_signed; e.values_to_release = release;
    array_add(stack, e);
}

// addFact
ce_add_fact :: (info: *Ce_Info, pred: u8, a: Value_Id, b: Value_Id, num_in: u32, num_out: u32, stack: *[..] Ce_Stack_Entry) {
    ce_add_fact_impl(info, pred, a, b, num_in, num_out, stack, false);
    if icmp_is_equality(pred) ce_add_fact_impl(info, pred, a, b, num_in, num_out, stack, true);
}

// addFactImpl
ce_add_fact_impl :: (info: *Ce_Info, pred: u8, a: Value_Id, b: Value_Id, num_in: u32, num_out: u32,
                     stack: *[..] Ce_Stack_Entry, force_signed: bool) {
    new_vars: [..] Value_Id; new_vars.allocator = temp;
    r := ce_get_constraint(info, pred, a, b, *new_vars, force_signed);
    if !ce_is_valid(*r, info) || r.is_ne return;
    cs := ce_cs(info, r.is_signed);
    if r.coeffs.count == 0 return;
    if !cs_add_variable_row_fill(cs, r.coeffs) return;

    release := NewArray(new_vars.count, Value_Id,, allocator = temp);
    for new_vars {
        if !table_contains(*cs.value2index, it) table_set(*cs.value2index, it, cast(u32) cs.value2index.count + 1);
        release[it_index] = it;
    }
    ce_push_entry(stack, num_in, num_out, r.is_signed, release);

    if !r.is_signed {
        for v: new_vars {
            var_pos := NewArray(cs.value2index.count + 1, s64,, allocator = temp);
            found, idx := table_find(*cs.value2index, v);
            var_pos[idx] = -1;
            cs_add_variable_row(cs, var_pos);
            ce_push_entry(stack, num_in, num_out, r.is_signed);
        }
    }

    if r.is_eq {
        for * r.coeffs it.* = wrap_mul_s64(it.*, -1);
        cs_add_variable_row_fill(cs, r.coeffs);
        ce_push_entry(stack, num_in, num_out, r.is_signed);
    }
}

// transferToOtherSystem
ce_transfer_to_other_system :: (info: *Ce_Info, pred: u8, a: Value_Id, b: Value_Id, num_in: u32, num_out: u32,
                                stack: *[..] Ce_Stack_Entry) {
    known_non_negative :: (info: *Ce_Info, v: Value_Id) -> bool {
        return ce_does_hold(info, ICMP_SGE, v, const_int(vtype(v), 0)) ||
               ce_known_non_negative_dl(v, MAX_ANALYSIS_RECURSION_DEPTH - 1);
    }
    if !is_int_type(vtype(a)) return;
    if pred == {
        case ICMP_ULT; #through;
        case ICMP_ULE;
            if known_non_negative(info, b) {
                ce_add_fact(info, ICMP_SGE, a, const_int(vtype(b), 0), num_in, num_out, stack);
                ce_add_fact(info, icmp_signed_predicate(pred), a, b, num_in, num_out, stack);
            }
        case ICMP_UGE; #through;
        case ICMP_UGT;
            if known_non_negative(info, a) {
                ce_add_fact(info, ICMP_SGE, b, const_int(vtype(b), 0), num_in, num_out, stack);
                ce_add_fact(info, icmp_signed_predicate(pred), a, b, num_in, num_out, stack);
            }
        case ICMP_SLT;
            if known_non_negative(info, a) ce_add_fact(info, ICMP_ULT, a, b, num_in, num_out, stack);
        case ICMP_SGT;
            if ce_does_hold(info, ICMP_SGE, b, cf_all_ones(vtype(b)))
                ce_add_fact(info, ICMP_UGE, a, const_int(vtype(b), 0), num_in, num_out, stack);
            if known_non_negative(info, b) ce_add_fact(info, ICMP_UGT, a, b, num_in, num_out, stack);
        case ICMP_SGE;
            if known_non_negative(info, b) ce_add_fact(info, ICMP_UGE, a, b, num_in, num_out, stack);
    }
}

// ---------------------------------------------------------------- collecting facts

Ce_State :: struct {
    f: Value_Id;
    dt: *Dom_Tree;
    li: *Loop_Info;
    worklist: [..] Ce_Fact;
}

ce_can_add_successor :: (s: *Ce_State, bb: Value_Id, succ: Value_Id) -> bool {
    return dt_dominates_edge_block(s.dt, bb, succ, succ);
}

// m_ICmpLike(Pred, m_Value(A), m_Value(B)): (ok, pred, samesign, a, b)
ce_match_icmp_like :: (v: Value_Id) -> (bool, u8, bool, Value_Id, Value_Id) {
    ok, p, ss, a, b := pm_icmp(v);
    if ok return true, p, ss, a, b;
    if is_int_or_int_vector_n(vtype(v), 1) && is_inst(v) && inst_op(v) == .TRUNC && (inst(v).flags & F_NUW) != 0 {
        x := op(v, 0);
        return true, ICMP_NE, false, x, const_null_value(vtype(x));
    }
    return false, 0, false, NONE, NONE;
}

// addInfoForInductions
ce_add_info_for_inductions :: (s: *Ce_State, bb: Value_Id) {
    l := li_loop_for(s.li, bb);
    if l == NONE || li_header(s.li, l) != bb return;
    term := block_terminator(bb);
    if inst_op(term) != .CONDBR return;
    cmp := op(term, 0);
    okc, pred0, ss0, c0, c1 := pm_icmp(cmp);
    if !okc return;
    // IndValue = m_Value(A, m_CombineOr(m_Phi(PN), m_c_Add(m_Phi(PN), m_APInt(IncStep))))
    ind_value :: (v: Value_Id, pn: *Value_Id, inc_step: *APInt, has_inc: *bool) -> bool {
        if is_phi(v) { pn.* = v; return true; }
        if opr_code(v) == .ADD {
            for side: 0..1 {
                x := op(v, cast(u32) side);
                y := op(v, cast(u32) (1 - side));
                if is_phi(x) {
                    pn.* = x;
                    ok, c := pm_apint(y);
                    if ok { inc_step.* = c; has_inc.* = true; return true; }
                }
            }
        }
        return false;
    }
    a: Value_Id; b: Value_Id; pn: Value_Id = NONE; inc_step: APInt; has_inc := false;
    pred := pred0;
    if ind_value(c0, *pn, *inc_step, *has_inc) { a = c0; b = c1; }
    else if ind_value(c1, *pn, *inc_step, *has_inc) { a = c1; b = c0; pred = swapped_predicate(pred0); }
    else return;
    if inst_block(pn) != bb || nops(pn) != 2 || !sc_is_scevable(vtype(pn)) return;

    in_loop_succ: Value_Id = NONE;
    if pred == ICMP_NE in_loop_succ = get_successor(term, 0);
    else if pred == ICMP_EQ in_loop_succ = get_successor(term, 1);
    else return;
    if !li_contains(s.li, l, in_loop_succ) || !li_is_loop_exiting(s.li, l, bb) || in_loop_succ == bb return;

    loop_pred := li_loop_predecessor(s.li, l);
    if loop_pred == NONE || !li_is_loop_invariant(s.li, l, b) return;

    ar := sc_get_scev(pn);
    if !sc_is_addrec(ar) || sc_loop(ar) != l return;

    start_scev := sc_start(ar);
    start_value: Value_Id;
    if sc_is_const(start_scev) start_value = sc_value(start_scev);
    else start_value = phi_incoming_for_block(pn, loop_pred);

    dtn := in_loop_succ;
    inc_u := sc_get_monotonic_predicate_type(ar, ICMP_UGT);
    inc_s := sc_get_monotonic_predicate_type(ar, ICMP_SGT);
    mono_u := inc_u == .INCREASING;
    mono_s := inc_s == .INCREASING;
    if mono_u array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_UGE, false, pn, start_value));
    if mono_s array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_SGE, false, pn, start_value));

    step := sc_step_recurrence(ar);
    if !sc_is_const(step) return;
    step_off := sc_ap(step);

    if has_inc && (!ap_eq(inc_step, step_off) || ap_is_negative(step_off)) return;

    if ap_is_negative(step_off) {
        if !ap_is_one(ap_neg(step_off)) return;
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_UGE, false, start_value, pn, .{ICMP_ULE, false, b, start_value}));
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_SGE, false, start_value, pn, .{ICMP_SLE, false, b, start_value}));
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_UGT, false, pn, b, .{ICMP_ULE, false, b, start_value}));
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_SGT, false, pn, b, .{ICMP_SLE, false, b, start_value}));
        return;
    }

    if ap_is_zero(step_off) || ap_is_negative(step_off) return;

    if !ap_is_one(step_off) {
        bms := sc_get_minus(sc_get_scev(b), start_scev);
        if sc_is_cnc(bms) || !ap_is_zero(ap_urem(sc_get_constant_multiple(bms), step_off)) return;
    }

    lower_bound := start_value;
    if has_inc {
        if !ce_isa_constant_int(start_value) return;
        sum, ov := ap_uadd_ov(const_ap(start_value), step_off);
        if ov return;
        lower_bound = const_int_ap(vtype(start_value), sum);
    }

    if !mono_u
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_UGE, false, pn, start_value, .{ICMP_ULE, false, lower_bound, b}));
    if !mono_s && !has_inc
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_SGE, false, pn, start_value, .{ICMP_SLE, false, start_value, b}));
    array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_ULT, false, pn, b, .{ICMP_ULE, false, lower_bound, b}));
    if !has_inc
        array_add(*s.worklist, ce_condition_fact(s.dt, dtn, ICMP_SLT, false, pn, b, .{ICMP_SLE, false, start_value, b}));

    precond := Ce_Cond.{ICMP_ULE, false, lower_bound, b};
    exits: [..] Value_Id; exits.allocator = temp;
    li_exit_blocks(s.li, l, *exits);
    for eb: exits {
        if dt_dominates(s.dt, bb, eb)
            array_add(*s.worklist, ce_condition_fact(s.dt, eb, ICMP_ULE, false, a, b, precond));
    }
}

// getConstraintFromMemoryAccess: (ok, pred, a, b)
ce_constraint_from_memory_access :: (gep: Value_Id, access_size: u64) -> (bool, u8, Value_Id, Value_Id) {
    off := ce_collect_offsets(gep);
    if (off.nw & F_GEP_NUW) == 0 return false, 0, NONE, NONE;
    if off.vars.count != 1 return false, 0, NONE, NONE;
    bw := off.const_off.bits;
    index := off.vars[0].v;
    scale := off.vars[0].scale;
    if type_bits(scalar_type(vtype(index))) != bw return false, 0, NONE, NONE;
    ok, size := get_base_object_size(off.base, true, true);
    if !ok return false, 0, NONE, NONE;
    max_index := ap_udiv(ap_sub(ap_zext_or_trunc(ap_from_u64(64, size - access_size), bw), off.const_off), scale);
    return true, ICMP_ULE, index, const_int_ap(vtype(index), max_index);
}

// addInfoFor
ce_add_info_for :: (s: *Ce_State, bb: Value_Id) {
    ce_add_info_for_inductions(s, bb);
    guaranteed := true;
    for i: block_insts(bb) {
        if inst_op(i) == .ICMP {
            u := ir.v_first_use[i];
            while u != NONE {
                defer u = ir.u_next[u];
                user_i := ce_context_inst_for_use(u);
                if dt_node(s.dt, inst_block(user_i)) < 0 continue;
                f: Ce_Fact;
                f.ty = .USE_CHECK;
                f.u = u;
                f.num_in, f.num_out = ce_dt_in(s.dt, inst_block(user_i));
                array_add(*s.worklist, f);
            }
            continue;
        }

        add_fact_from_memory_access :: (s: *Ce_State, i: Value_Id, ptr: Value_Id, access_ty: Type_Id, guaranteed: bool) {
            if !is_inst(ptr) || inst_op(ptr) != .GEP return;
            if type_is_scalable(access_ty) return;
            access_size := dl_type_store_size(access_ty);
            if guaranteed {
                ok, pred, a, b := ce_constraint_from_memory_access(ptr, access_size);
                if ok array_add(*s.worklist, ce_condition_fact(s.dt, inst_block(i), pred, false, a, b));
            } else {
                array_add(*s.worklist, ce_inst_fact(s.dt, inst_block(i), i, .INST_FACT));
            }
        }
        if inst_op(i) == .LOAD && (inst(i).flags & F_VOLATILE) == 0 add_fact_from_memory_access(s, i, op(i, 0), vtype(i), guaranteed);
        if inst_op(i) == .STORE && (inst(i).flags & F_VOLATILE) == 0 add_fact_from_memory_access(s, i, op(i, 1), vtype(op(i, 0)), guaranteed);

        id := call_iid(i);
        if id == IID_ASSUME {
            ok := ce_match_icmp_like(op(i, 0));
            if ok {
                if guaranteed {
                    okm, p, ss, a, b := ce_match_icmp_like(op(i, 0));
                    array_add(*s.worklist, ce_condition_fact(s.dt, inst_block(i), p, ss, a, b));
                } else {
                    array_add(*s.worklist, ce_inst_fact(s.dt, inst_block(i), i, .INST_FACT));
                }
            }
        } else if id == IID_SSUB_WITH_OVERFLOW || id == IID_UCMP || id == IID_SCMP {
            array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_CHECK));
        } else if id == IID_UMIN || id == IID_UMAX || id == IID_SMIN || id == IID_SMAX {
            array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_CHECK));
            if is_guaranteed_not_to_be_poison(i) array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_FACT));
        } else if id == IID_UADD_SAT || id == IID_USUB_SAT {
            if is_guaranteed_not_to_be_poison(i) array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_FACT));
        } else if id == IID_ABS {
            array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_FACT));
        }

        if is_binary_operator(i) && (inst_op(i) == .UREM || inst_op(i) == .UDIV) && is_guaranteed_not_to_be_poison(i)
            array_add(*s.worklist, ce_inst_fact(s.dt, bb, i, .INST_FACT));

        guaranteed = guaranteed && is_guaranteed_to_transfer_execution(i);
    }

    term := block_terminator(bb);
    if inst_op(term) == .SWITCH {
        cond := op(term, 0);
        n := nops(term);
        // operands: [cond, default, dest...]; case values in u_aux
        k: u32 = 2;
        while k < n {
            defer k += 1;
            succ := op(term, k);
            v := ir.u_aux[ir.v_ops[term] + k];
            if !ce_can_add_successor(s, bb, succ) continue;
            array_add(*s.worklist, ce_condition_fact(s.dt, succ, ICMP_EQ, false, cond, v));
        }
        return;
    }
    if inst_op(term) != .CONDBR return;
    cond := op(term, 0);

    oko, o0, o1 := pm_logical_or(cond);
    oka, a0, a1 := pm_logical_and(cond);
    if oko || oka {
        op0 := ifx oko then o0 else a0;
        op1 := ifx oko then o1 else a1;
        is_or := oko;
        is_and := oka;
        if is_or && is_and is_and = false;
        succ := get_successor(term, ifx is_or then cast(u32) 1 else 0);
        if ce_can_add_successor(s, bb, succ) {
            wl: [..] Value_Id; wl.allocator = temp;
            seen: Table(Value_Id, bool); seen.allocator = temp;
            queue :: (v: Value_Id, wl: *[..] Value_Id, seen: *Table(Value_Id, bool)) {
                if table_contains(seen, v) return;
                table_set(seen, v, true);
                array_add(wl, v);
            }
            queue(op1, *wl, *seen);
            queue(op0, *wl, *seen);
            while wl.count {
                cur := pop(*wl);
                okc, p, ss, a, b := ce_match_icmp_like(cur);
                if okc {
                    array_add(*s.worklist, ce_condition_fact(s.dt, succ, ifx is_or then icmp_inverse(p) else p, ss, a, b));
                    continue;
                }
                if is_or {
                    ok2, x, y := pm_logical_or(cur);
                    if ok2 { queue(y, *wl, *seen); queue(x, *wl, *seen); continue; }
                }
                if is_and {
                    ok2, x, y := pm_logical_and(cur);
                    if ok2 { queue(y, *wl, *seen); queue(x, *wl, *seen); continue; }
                }
            }
        }
        return;
    }

    okc, p, ss, a, b := ce_match_icmp_like(cond);
    if !okc return;
    if ce_can_add_successor(s, bb, get_successor(term, 0))
        array_add(*s.worklist, ce_condition_fact(s.dt, get_successor(term, 0), p, ss, a, b));
    if ce_can_add_successor(s, bb, get_successor(term, 1))
        array_add(*s.worklist, ce_condition_fact(s.dt, get_successor(term, 1), icmp_inverse(p), ss, a, b));
}

// ---------------------------------------------------------------- checks

// checkCondition: 0 = unknown, 1 = true, 2 = false
ce_check_condition :: (pred: u8, a: Value_Id, b: Value_Id, check_inst: Value_Id, info: *Ce_Info) -> u8 {
    r := ce_get_constraint_for_solving(info, pred, a, b);
    if r.coeffs.count == 0 || !ce_is_valid(*r, info) return 0;
    return ce_is_implied_by(*r, ce_cs(info, r.is_signed));
}

// checkAndReplaceCondition
ce_check_and_replace_condition :: (cmp: Value_Id, info: *Ce_Info, num_in: u32, num_out: u32, ctx: Value_Id,
                                   dt: *Dom_Tree, to_remove: *[..] Value_Id) -> bool {
    replace :: (cmp: Value_Id, is_true: bool, num_in: u32, num_out: u32, ctx: Value_Id, dt: *Dom_Tree,
                to_remove: *[..] Value_Id) -> bool {
        c := cf_bool(vtype(cmp), is_true);
        changed := false;
        u := ir.v_first_use[cmp];
        while u != NONE {
            nx := ir.u_next[u];
            defer u = nx;
            user_i := ce_context_inst_for_use(u);
            n := dt_node(dt, inst_block(user_i));
            if n < 0 || dt.nodes[n].dfs_in < num_in || dt.nodes[n].dfs_out > num_out continue;
            if inst_block(user_i) == inst_block(ctx) && comes_before(user_i, ctx) continue;
            usr := ir.u_user[u];
            if call_iid(usr) == IID_ASSUME continue;
            use_set(u, c);
            changed = true;
        }
        users: [..] u32; users.allocator = temp;
        find_dbg_users(inst_fn(cmp), cmp, *users);
        for r: users {
            owner := dbgr(r).owner;
            n := dt_node(dt, inst_block(owner));
            if n < 0 || dt.nodes[n].dfs_in < num_in || dt.nodes[n].dfs_out > num_out continue;
            if inst_block(owner) == inst_block(ctx) && comes_before(owner, ctx) continue;
            dbgr_replace_variable_location_op(r, cmp, c);
        }
        if !has_uses(cmp) array_add(to_remove, cmp);
        return changed;
    }
    implied := ce_check_condition(inst_pred(cmp), op(cmp, 0), op(cmp, 1), cmp, info);
    if implied != 0 return replace(cmp, implied == 1, num_in, num_out, ctx, dt, to_remove);
    if (inst(cmp).flags & F_EXACT) != 0 && icmp_is_unsigned(inst_pred(cmp)) {
        implied = ce_check_condition(icmp_signed_predicate(inst_pred(cmp)), op(cmp, 0), op(cmp, 1), cmp, info);
        if implied != 0 return replace(cmp, implied == 1, num_in, num_out, ctx, dt, to_remove);
    }
    return false;
}

ce_min_max_pred :: (id: Intrinsic_Id) -> u8 {
    if id == IID_SMAX return ICMP_SGT;
    if id == IID_SMIN return ICMP_SLT;
    if id == IID_UMAX return ICMP_UGT;
    return ICMP_ULT;
}

// checkAndReplaceMinMax
ce_check_and_replace_min_max :: (mm: Value_Id, info: *Ce_Info, to_remove: *[..] Value_Id) -> bool {
    pred := icmp_non_strict(ce_min_max_pred(call_iid(mm)));
    l := call_arg(mm, 0); r := call_arg(mm, 1);
    implied := ce_check_condition(pred, l, r, mm, info);
    if implied != 0 {
        rauw_with_metadata(mm, ifx implied == 1 then l else r);
        array_add(to_remove, mm);
        return true;
    }
    implied = ce_check_condition(pred, r, l, mm, info);
    if implied != 0 {
        rauw_with_metadata(mm, ifx implied != 1 then l else r);
        array_add(to_remove, mm);
        return true;
    }
    return false;
}

// checkAndReplaceCmp
ce_check_and_replace_cmp :: (i: Value_Id, info: *Ce_Info, to_remove: *[..] Value_Id) -> bool {
    l := call_arg(i, 0); r := call_arg(i, 1);
    signed := call_iid(i) == IID_SCMP;
    gt := ifx signed then ICMP_SGT else ICMP_UGT;
    lt := ifx signed then ICMP_SLT else ICMP_ULT;
    if ce_check_condition(cast(u8) gt, l, r, i, info) == 1 {
        rauw_with_metadata(i, const_int(vtype(i), 1));
        array_add(to_remove, i);
        return true;
    }
    if ce_check_condition(cast(u8) lt, l, r, i, info) == 1 {
        rauw_with_metadata(i, cf_all_ones(vtype(i)));
        array_add(to_remove, i);
        return true;
    }
    if ce_check_condition(ICMP_EQ, l, r, i, info) == 1 {
        rauw_with_metadata(i, const_int(vtype(i), 0));
        array_add(to_remove, i);
        return true;
    }
    return false;
}

// removeEntryFromStack
ce_remove_entry_from_stack :: (e: Ce_Stack_Entry, info: *Ce_Info, stack: *[..] Ce_Stack_Entry) {
    cs := ce_cs(info, e.is_signed);
    cs_pop_last_constraint(cs);
    for e.values_to_release table_remove(*cs.value2index, it);
    cs_pop_last_n_variables(cs, e.values_to_release.count);
    stack.count -= 1;
}

// checkOrAndOpImpliedByOther
ce_check_or_and_op_implied_by_other :: (cb: *Ce_Fact, info: *Ce_Info, stack: *[..] Ce_Stack_Entry, to_remove: *[..] Value_Id) -> bool {
    join := ce_fact_context_inst(cb);
    if !has_uses(join) return false;
    cmp := ce_fact_inst_to_simplify(cb);
    other_idx: u32 = ifx op(join, 0) == cmp then cast(u32) 1 else 0;
    if other_idx != 0 && inst_op(join) == .SELECT return false;

    old_size := stack.count;
    defer { while old_size < stack.count ce_remove_entry_from_stack(stack.*[stack.count - 1], info, stack); }

    is_or := pm_logical_or(join);
    wl: [..] Value_Id; wl.allocator = temp;
    array_add(*wl, op(join, other_idx));
    while wl.count {
        val := pop(*wl);
        okc, p, ss, l, r := pm_icmp(val);
        if okc {
            pp := p;
            if is_or pp = icmp_inverse(pp);
            ce_add_fact(info, pp, l, r, cb.num_in, cb.num_out, stack);
            continue;
        }
        if is_or {
            ok2, x, y := pm_logical_or(val);
            if ok2 { array_add(*wl, x); array_add(*wl, y); }
        } else {
            ok2, x, y := pm_logical_and(val);
            if ok2 { array_add(*wl, x); array_add(*wl, y); }
        }
    }
    if old_size == stack.count return false;

    implied := ce_check_condition(inst_pred(cmp), op(cmp, 0), op(cmp, 1), cmp, info);
    if implied != 0 {
        if is_or == (implied == 1) rauw_with_metadata(join, cf_bool(vtype(join), implied == 1));
        else rauw_with_metadata(join, op(join, other_idx));
        array_add(to_remove, join);
        return true;
    }
    return false;
}

// replaceSubOverflowUses
ce_replace_sub_overflow_uses :: (ii: Value_Id, a: Value_Id, b: Value_Id, to_remove: *[..] Value_Id) -> bool {
    changed := false;
    bld: Irb;
    irb_set_at(*bld, inst_block(ii), ii, false);
    sub: Value_Id = NONE;
    u := ir.v_first_use[ii];
    while u != NONE {
        nx := ir.u_next[u];
        defer u = nx;
        usr := ir.u_user[u];
        is_ev := is_inst(usr) && inst_op(usr) == .EXTRACTVALUE && inst(usr).nidx == 1;
        idx0 := is_ev && ir.u32_pool[inst(usr).idx] == 0;
        idx1 := is_ev && ir.u32_pool[inst(usr).idx] == 1;
        if idx0 {
            if sub == NONE sub = irb_binop(*bld, .SUB, a, b);
            // the next use may belong to `usr` itself (it can't: an extractvalue has one operand)
            rauw_with_metadata(usr, sub);
            changed = true;
        } else if idx1 {
            rauw_with_metadata(usr, const_int(ir.t_i1, 0));
            changed = true;
        } else continue;
        if !has_uses(usr) {
            array_add(to_remove, usr);
            set_op(usr, 0, const_poison(vtype(ii)));
            changed = true;
        }
    }
    if !has_uses(ii) {
        erase_inst_with_metadata(ii);
        changed = true;
    }
    return changed;
}

// tryToSimplifyOverflowMath
ce_try_to_simplify_overflow_math :: (ii: Value_Id, info: *Ce_Info, to_remove: *[..] Value_Id) -> bool {
    does_condition_hold :: (pred: u8, a: Value_Id, b: Value_Id, info: *Ce_Info) -> bool {
        r := ce_get_constraint_for_solving(info, pred, a, b);
        if r.coeffs.count < 2 || !ce_is_valid(*r, info) return false;
        return cs_is_condition_implied(ce_cs(info, r.is_signed), r.coeffs);
    }
    changed := false;
    if call_iid(ii) == IID_SSUB_WITH_OVERFLOW {
        a := call_arg(ii, 0); b := call_arg(ii, 1);
        if !does_condition_hold(ICMP_SGE, a, b, info) || !does_condition_hold(ICMP_SGE, b, const_int(vtype(a), 0), info)
            return false;
        changed = ce_replace_sub_overflow_uses(ii, a, b, to_remove);
    }
    return changed;
}

// ---------------------------------------------------------------- driver

// the AddFact lambda of eliminateConstraints
ce_add_fact_cb :: (info: *Ce_Info, cb: *Ce_Fact, stack: *[..] Ce_Stack_Entry, pred: u8, samesign: bool, a: Value_Id, b: Value_Id) {
    if cs_size(ce_cs(info, icmp_is_signed(pred))) > ce_cl.max_rows return;
    ce_add_fact(info, pred, a, b, cb.num_in, cb.num_out, stack);
    if icmp_is_relational(pred) {
        if samesign ce_add_fact(info, icmp_flipped_signedness(pred), a, b, cb.num_in, cb.num_out, stack);
        else ce_transfer_to_other_system(info, pred, a, b, cb.num_in, cb.num_out, stack);
    }
}

ce_fact_less :: (a: *Ce_Fact, b: *Ce_Fact) -> bool {
    has_no_const_op :: (f: *Ce_Fact) -> bool {
        return !ce_isa_constant_int(f.cond.op0) && !ce_isa_constant_int(f.cond.op1);
    }
    if a.num_in == b.num_in {
        if a.ty == .CONDITION_FACT && b.ty == .CONDITION_FACT {
            na := has_no_const_op(a); nb := has_no_const_op(b);
            return !na && nb;
        }
        if a.ty == .CONDITION_FACT return true;
        if b.ty == .CONDITION_FACT return false;
        return comes_before(ce_fact_context_inst(a), ce_fact_context_inst(b));
    }
    return a.num_in < b.num_in;
}

ce_stable_sort :: (items: [] Ce_Fact) {
    n := items.count;
    if n < 2 return;
    buf := NewArray(n, Ce_Fact,, allocator = temp);
    src := items; dst := buf;
    width := 1;
    while width < n {
        lo := 0;
        while lo < n {
            mid := min(lo + width, n);
            hi := min(lo + 2 * width, n);
            i := lo; j := mid; k := lo;
            while i < mid && j < hi {
                if ce_fact_less(*src[j], *src[i]) { dst[k] = src[j]; j += 1; }
                else { dst[k] = src[i]; i += 1; }
                k += 1;
            }
            while i < mid { dst[k] = src[i]; i += 1; k += 1; }
            while j < hi { dst[k] = src[j]; j += 1; k += 1; }
            lo = hi;
        }
        t := src; src = dst; dst = t;
        width *= 2;
    }
    if src.data != items.data for k: 0..n - 1 items[k] = src[k];
}

// eliminateConstraints
ce_eliminate_constraints :: (f: Value_Id, dt: *Dom_Tree, li: *Loop_Info) -> bool {
    changed := false;
    dt_update_dfs_numbers(dt);
    g := glob(f);
    args := NewArray(g.nargs, Value_Id,, allocator = temp);
    for k: 0..cast(s64) g.nargs - 1 args[k] = g.arg_start + cast(u32) k;

    info: Ce_Info;
    cs_init(*info.ucs, args);
    cs_init(*info.scs, args);
    for a: args {
        var_pos := NewArray(info.ucs.value2index.count + 1, s64,, allocator = temp);
        found, idx := table_find(*info.ucs.value2index, a);
        var_pos[idx] = -1;
        cs_add_variable_row(*info.ucs, var_pos);
    }

    s: Ce_State;
    s.f = f; s.dt = dt; s.li = li;
    s.worklist.allocator = temp;
    for bb: fn_blocks(f) {
        if dt_node(dt, bb) < 0 continue;
        ce_add_info_for(*s, bb);
    }

    ce_stable_sort(s.worklist);

    to_remove: [..] Value_Id; to_remove.allocator = temp;
    stack: [..] Ce_Stack_Entry; stack.allocator = temp;

    for * cb: s.worklist {
        while stack.count {
            e := stack[stack.count - 1];
            assert(e.num_in <= cb.num_in);
            if cb.num_out <= e.num_out break;
            ce_remove_entry_from_stack(e, *info, *stack);
        }

        if ce_is_check(cb) {
            i := ce_fact_inst_to_simplify(cb);
            if i == NONE continue;
            id := call_iid(i);
            if is_with_overflow_inst(i) {
                if ce_try_to_simplify_overflow_math(i, *info, *to_remove) changed = true;
            } else if inst_op(i) == .ICMP {
                simplified := ce_check_and_replace_condition(i, *info, cb.num_in, cb.num_out, ce_fact_context_inst(cb), dt, *to_remove);
                if !simplified {
                    okl := pm_logical_op(ce_fact_context_inst(cb));
                    if okl simplified = ce_check_or_and_op_implied_by_other(cb, *info, *stack, *to_remove);
                }
                if simplified changed = true;
            } else if id == IID_UMIN || id == IID_UMAX || id == IID_SMIN || id == IID_SMAX {
                if ce_check_and_replace_min_max(i, *info, *to_remove) changed = true;
            } else if id == IID_UCMP || id == IID_SCMP {
                if ce_check_and_replace_cmp(i, *info, *to_remove) changed = true;
            }
            continue;
        }

        if cb.ty != .CONDITION_FACT {
            ci := cb.inst;
            id := call_iid(ci);
            if id == IID_ABS {
                x := call_arg(ci, 0);
                if ap_is_one(const_ap(call_arg(ci, 1)))
                    ce_add_fact_cb(*info, cb, *stack, ICMP_SGE, false, ci, const_int(vtype(ci), 0));
                ce_add_fact_cb(*info, cb, *stack, ICMP_SGE, false, ci, x);
                continue;
            }
            if id == IID_UMIN || id == IID_UMAX || id == IID_SMIN || id == IID_SMAX {
                p := icmp_non_strict(ce_min_max_pred(id));
                ce_add_fact_cb(*info, cb, *stack, p, false, ci, call_arg(ci, 0));
                ce_add_fact_cb(*info, cb, *stack, p, false, ci, call_arg(ci, 1));
                continue;
            }
            if id == IID_UADD_SAT {
                ce_add_fact_cb(*info, cb, *stack, ICMP_UGE, false, ci, call_arg(ci, 0));
                ce_add_fact_cb(*info, cb, *stack, ICMP_UGE, false, ci, call_arg(ci, 1));
                continue;
            }
            if id == IID_USUB_SAT {
                ce_add_fact_cb(*info, cb, *stack, ICMP_ULE, false, ci, call_arg(ci, 0));
                continue;
            }
            if is_binary_operator(ci) {
                if inst_op(ci) == .UREM {
                    ce_add_fact_cb(*info, cb, *stack, ICMP_ULT, false, ci, op(ci, 1));
                    ce_add_fact_cb(*info, cb, *stack, ICMP_ULE, false, ci, op(ci, 0));
                    continue;
                }
                if inst_op(ci) == .UDIV {
                    ce_add_fact_cb(*info, cb, *stack, ICMP_ULE, false, ci, op(ci, 0));
                    continue;
                }
            }
            if inst_op(ci) == .LOAD || inst_op(ci) == .STORE {
                ptr := ifx inst_op(ci) == .LOAD then op(ci, 0) else op(ci, 1);
                aty := ifx inst_op(ci) == .LOAD then vtype(ci) else vtype(op(ci, 0));
                ok, p, a, b := ce_constraint_from_memory_access(ptr, dl_type_store_size(aty));
                if ok ce_add_fact_cb(*info, cb, *stack, p, false, a, b);
                continue;
            }
        }

        pred: u8; samesign: bool; a: Value_Id; b: Value_Id;
        if cb.ty == .CONDITION_FACT {
            pred = cb.cond.pred; samesign = cb.cond.samesign; a = cb.cond.op0; b = cb.cond.op1;
            if cb.does_hold.pred != CE_BAD_PRED && !ce_does_hold(*info, cb.does_hold.pred, cb.does_hold.op0, cb.does_hold.op1)
                continue;
        } else {
            assert(call_iid(cb.inst) == IID_ASSUME);
            ok: bool;
            ok, pred, samesign, a, b = ce_match_icmp_like(op(cb.inst, 0));
            assert(ok);
        }
        ce_add_fact_cb(*info, cb, *stack, pred, samesign, a, b);
    }

    for to_remove {
        if has_uses(it) fatal("constraint-elimination: erasing an instruction that still has uses");
        erase_inst_with_metadata(it);
    }
    return changed;
}

constraint_elimination_run :: (f: Value_Id) -> Preserved {
    dt := get_domtree(f);
    li := get_loop_info(f);
    get_scev(f);
    if !ce_eliminate_constraints(f, dt, li) return PRESERVE_ALL;
    pa := preserved_cfg();
    preserve(*pa, .DOMTREE);
    preserve(*pa, .LOOPS);
    preserve(*pa, .SCEV);
    return pa;
}
