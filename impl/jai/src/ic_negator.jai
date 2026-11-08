// Negator: a port of llvm/lib/Transforms/InstCombine/InstCombineNegator.cpp. Its IRBuilder<TargetFolder,
// IRBuilderCallbackInserter> inserts each new instruction right before the instruction being negated (with that
// instruction's debug location) and records it; on failure the recorded instructions are erased in reverse order,
// on success they are added to the combiner's worklist in creation order (IC.Builder.Insert with a cleared insertion
// point only does the worklist part).

Negator :: struct {
    is_truly_negation: bool;
    new_insts: [..] Value_Id;
    cache: Table(Value_Id, Value_Id);
}
negator: *Negator;   // non-null while a Negator runs: icb_insert records into it instead of the worklist

// getSortedOperandsOfBinOp
neg_sorted_ops :: (i: Value_Id) -> (Value_Id, Value_Id) {
    a := op(i, 0); b := op(i, 1);
    if is_commutative_op(inst_op(i)) && ic_complexity(a) < ic_complexity(b) return b, a;
    return a, b;
}

// m_AnyIntegralConstant
pm_any_integral_constant_v :: (v: Value_Id) -> bool { return pm_any_integral_constant(v); }

neg_visit_impl :: (n: *Negator, v: Value_Id, is_nsw_in: bool, depth: u32) -> Value_Id {
    is_nsw := is_nsw_in;
    if pm_undef(v) return v;
    if is_int_or_int_vector_n(vtype(v), 1) return v;
    okn, x := pm_neg(v);
    if okn return x;
    if pm_any_integral_constant(v) return ce_neg(v, false);
    if !is_inst(v) return NONE;
    if !has_one_use(v) && !n.is_truly_negation return NONE;
    i := v;
    bw := scalar_bits(i);
    saved := ic.b;
    defer ic.b = saved;
    irb_set_before(*ic.b, i);
    nm := tprint("%.neg", vname(i));
    o := inst_op(i);
    if o == {
        case .ADD;
            a, b := neg_sorted_ops(i);
            if pm_one(b) return icb_not(a, nm);
        case .XOR;
            okx, xv := pm_not(i);
            if okx return icb_add(xv, const_int_of(vtype(xv), 1), nm);
        case .ASHR; #through;
        case .LSHR;
            okc, c := pm_apint(op(i, 1));
            if okc && ap_eq_u64(c, bw - 1) {
                bo := ifx o == .ASHR then icb_lshr(op(i, 0), op(i, 1)) else icb_ashr(op(i, 0), op(i, 1));
                if is_inst(bo) { copy_ir_flags(bo, i); set_name(bo, nm); }
                return bo;
            }
        case .SEXT; #through;
        case .ZEXT;
            if is_int_or_int_vector_n(vtype(op(i, 0)), 1) {
                if o == .SEXT return icb_zext(op(i, 0), vtype(i), nm);
                return icb_sext(op(i, 0), vtype(i), nm);
            }
        case .SELECT;
            tc := op(i, 1); fc := op(i, 2);
            if pm_imm_constant(tc) && pm_imm_constant(fc)
                return icb_select(op(i, 0), ce_neg(tc), ce_neg(fc), nm, i);
        case .CALL;
            id := call_iid(i);
            if (id == IID_UCMP || id == IID_SCMP) && has_one_use(i)
                return icb_intrinsic(id, .[vtype(i), vtype(op(i, 0))], .[op(i, 1), op(i, 0)]);
    }
    if o == .SUB && (has_one_use(i) || pm_imm_constant(op(i, 0)))
        return icb_sub(op(i, 1), op(i, 0), nm, false, is_nsw && has_nsw(i));
    if !has_one_use(v) return NONE;
    if o == {
        case .ZEXT;
            src := op(i, 0);
            sw := scalar_bits(src);
            okl, lx, la := pm_binop(src, .LSHR);
            if n.is_truly_negation && okl && pm_specific_int(la, sw - 1, true) {
                ashr := icb_ashr(lx, const_int_of(vtype(lx), sw - 1));
                return icb_sext(ashr, vtype(i));
            }
        case .AND;
            oka, a0, a1 := pm_binop(i, .AND);
            if pm_one(a1) && has_one_use(a0) {
                t := trunc_or_self_i(a0);
                okl, lx, sh := pm_binop(t, .LSHR);
                if okl && pm_imm_constant(sh) {
                    bwx := scalar_bits(lx);
                    bwm1 := const_int_of(vtype(lx), bwx - 1);
                    r := icb_shl(lx, icb_sub(bwm1, sh));
                    r = icb_ashr(r, bwm1);
                    if type_bits(scalar_type(vtype(r))) == type_bits(scalar_type(vtype(i))) return icb_cast(.BITCAST, r, vtype(i));
                    return icb_trunc(r, vtype(i));
                }
            }
        case .SDIV;
            c := op(i, 1);
            if is_const(c) {
                if !contains_undef_or_poison_element(c) && const_is_not_min_signed_value(c) && const_is_not_one_value(c) {
                    bo := icb_sdiv(op(i, 0), ce_neg(c), nm);
                    if is_inst(bo) set_exact(bo, is_exact(i));
                    return bo;
                }
            }
    }
    // NegatorMaxDepth is ~0U: never reached
    if o == {
        case .FREEZE;
            nop := neg_negate(n, op(i, 0), is_nsw, depth + 1);
            if nop == NONE return NONE;
            fr := new_inst(.FREEZE, vtype(nop), 1);
            set_op(fr, 0, nop);
            return icb_insert(fr, nm);
        case .PHI;
            k := nops(i);
            vals: [..] Value_Id; vals.allocator = temp;
            for e: 0..cast(s64) k - 1 {
                iv := op(i, cast(u32) e);
                if dt_dominates(ic.dt, inst_block(i), phi_block(i, cast(u32) e)) return NONE;   // DT.dominates(BB, Use)
                nv := neg_negate(n, iv, is_nsw, depth + 1);
                if nv == NONE return NONE;
                array_add(*vals, nv);
            }
            np := icb_insert(create_phi(vtype(i), k), nm);
            for e: 0..cast(s64) k - 1 phi_add_incoming(np, vals[e], phi_block(i, cast(u32) e));
            return np;
        case .SELECT;
            if is_known_negation(op(i, 1), op(i, 2), false, false) {
                ns := ic_clone_inst(i);
                use_swap(op_use(ns, 1), op_use(ns, 2));
                tv := op(ns, 1); fv := op(ns, 2);
                okt, tn := pm_neg(tv);
                okf, fn := pm_neg(fv);
                if okt && tn == fv drop_poison_generating_flags(tv);
                else if okf && fn == tv drop_poison_generating_flags(fv);
                else { drop_poison_generating_flags(tv); drop_poison_generating_flags(fv); }
                // Builder.Insert(NewSelect): IRBuilderDefaultInserter::InsertHelper calls setName("") and so drops
                // the ".neg" name set on the unlinked clone
                ir.v_name[ns] = "";
                icb_insert(ns, "");
                return ns;
            }
            n1 := neg_negate(n, op(i, 1), is_nsw, depth + 1);
            if n1 == NONE return NONE;
            n2 := neg_negate(n, op(i, 2), is_nsw, depth + 1);
            if n2 == NONE return NONE;
            return icb_select(op(i, 0), n1, n2, nm, i);
        case .SHUFFLEVECTOR;
            n0 := neg_negate(n, op(i, 0), is_nsw, depth + 1);
            if n0 == NONE return NONE;
            n1 := neg_negate(n, op(i, 1), is_nsw, depth + 1);
            if n1 == NONE return NONE;
            return icb_shuffle(n0, n1, shuffle_mask(i), nm);
        case .EXTRACTELEMENT;
            nvec := neg_negate(n, op(i, 0), is_nsw, depth + 1);
            if nvec == NONE return NONE;
            return icb_extract_element(nvec, op(i, 1), nm);
        case .INSERTELEMENT;
            nvec := neg_negate(n, op(i, 0), is_nsw, depth + 1);
            if nvec == NONE return NONE;
            nelt := neg_negate(n, op(i, 1), is_nsw, depth + 1);
            if nelt == NONE return NONE;
            return icb_insert_element(nvec, nelt, op(i, 2), nm);
        case .TRUNC;
            nop := neg_negate(n, op(i, 0), false, depth + 1);
            if nop == NONE return NONE;
            return icb_trunc(nop, vtype(i), nm);
        case .SHL;
            is_nsw &= has_nsw(i);
            n0 := neg_negate(n, op(i, 0), is_nsw, depth + 1);
            if n0 != NONE return icb_shl(n0, op(i, 1), nm, false, is_nsw);
            c := op(i, 1);
            if !pm_imm_constant(c) || !n.is_truly_negation return NONE;
            return icb_mul(op(i, 0), icb_shl(const_all_ones_of(vtype(c)), c), nm, false, is_nsw);
        case .OR; #through;
        case .ADD;
            if o == .OR {
                if (inst(i).flags & F_EXACT) == 0 return NONE;
                a, b := neg_sorted_ops(i);
                if pm_one(b) return icb_not(a, nm);
            }
            negated: [2] Value_Id; nneg := 0;
            non_negated: [2] Value_Id; nnon := 0;
            for e: 0..1 {
                oo := op(i, cast(u32) e);
                nv := neg_negate(n, oo, false, depth + 1);
                if nv != NONE { negated[nneg] = nv; nneg += 1; continue; }
                if !n.is_truly_negation return NONE;
                non_negated[nnon] = oo; nnon += 1;
            }
            if nneg == 2 return icb_add(negated[0], negated[1], nm);
            if nnon == 2 return NONE;
            return icb_sub(negated[0], non_negated[0], nm);
        case .XOR;
            a, b := neg_sorted_ops(i);
            if is_const(b) && n.is_truly_negation {
                xr := icb_xor(a, ce_not(b));
                return icb_add(xr, const_int_of(vtype(xr), 1), nm);
            }
            return NONE;
        case .MUL;
            a, b := neg_sorted_ops(i);
            negated, other: Value_Id;
            n1 := neg_negate(n, b, false, depth + 1);
            if n1 != NONE { negated = n1; other = a; }
            else {
                n0 := neg_negate(n, a, false, depth + 1);
                if n0 != NONE { negated = n0; other = b; }
                else return NONE;
            }
            return icb_mul(negated, other, nm, false, is_nsw && has_nsw(i));
    }
    return NONE;
}
neg_negate :: (n: *Negator, v: Value_Id, is_nsw: bool, depth: u32) -> Value_Id {
    found, r := table_find(*n.cache, v);
    if found return r;
    nv := neg_visit_impl(n, v, is_nsw, depth);
    table_set(*n.cache, v, nv);
    return nv;
}

// Negator::Negate
negator_negate :: (lhs_is_zero: bool, is_nsw: bool, root: Value_Id) -> Value_Id {
    if !opts.instcombine_negator_enabled return NONE;
    n: Negator;
    n.is_truly_negation = lhs_is_zero;
    n.new_insts.allocator = temp;
    n.cache.allocator = temp;
    saved_neg := negator;
    negator = *n;
    negated := neg_negate(*n, root, is_nsw, 0);
    negator = saved_neg;
    if negated == NONE {
        for < k: 0..n.new_insts.count-1 {
            x := n.new_insts[k];
            if has_uses(x) fatal("internal: Negator cleanup of a used instruction");
            erase_inst_with_metadata(x);
        }
        return NONE;
    }
    for n.new_insts wl_add(it);
    return negated;
}

// Constant::containsUndefOrPoisonElement / isNotMinSignedValue / isNotOneValue
contains_undef_or_poison_element :: (c: Value_Id) -> bool {
    if pm_undef_value(c) return true;
    t := vtype(c);
    if !is_vector_type(t) return false;
    if type_kind(t) == .SVECTOR return false;
    n := type_count(t);
    for k: 0..cast(s64) n - 1 { e := cf_elt(c, cast(u64) k); if e != NONE && pm_undef_value(e) return true; }
    return false;
}
const_is_not_min_signed_value :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT return !ap_is_min_signed(const_ap(c));
    if k == .C_FP && !is_vector_type(vtype(c)) return !ap_is_min_signed(ap_from_words(type_bits(vtype(c)), const_fp_value(c)));
    t := vtype(c);
    if is_vector_type(t) {
        if type_kind(t) == .VECTOR {
            n := type_count(t);
            for e: 0..cast(s64) n - 1 {
                elt := cf_elt(c, cast(u64) e);
                if elt == NONE || !const_is_not_min_signed_value(elt) return false;
            }
            return true;
        }
        s := get_splat_value(c);
        if s != NONE return const_is_not_min_signed_value(s);
    }
    if k == .C_FP return !ap_is_min_signed(ap_from_words(type_bits(scalar_type(vtype(c))), const_fp_value(c)));
    return false;
}
const_is_not_one_value :: (c: Value_Id) -> bool {
    k := vkind(c);
    if k == .C_INT return !ap_is_one(const_ap(c));
    if k == .C_FP && !is_vector_type(vtype(c)) return !ap_is_one(ap_from_words(type_bits(vtype(c)), const_fp_value(c)));
    t := vtype(c);
    if is_vector_type(t) {
        if type_kind(t) == .VECTOR {
            n := type_count(t);
            for e: 0..cast(s64) n - 1 {
                elt := cf_elt(c, cast(u64) e);
                if elt == NONE || !const_is_not_one_value(elt) return false;
            }
            return true;
        }
        s := get_splat_value(c);
        if s != NONE return const_is_not_one_value(s);
    }
    return false;
}
